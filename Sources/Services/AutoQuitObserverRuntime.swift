import AppKit
import ApplicationServices

struct AutoQuitAXWindowInfo {
    let element: AXUIElement
    let closeEligible: Bool
}

enum AutoQuitWindowReader {
    typealias Query = (AXUIElement, CFString) -> (AXError, CFTypeRef?)

    static func windows(of app: AXUIElement, query: Query = copyAttribute) -> [AutoQuitAXWindowInfo]? {
        let (error, value) = query(app, kAXWindowsAttribute as CFString)
        guard error == .success, let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        let array = value as! CFArray
        guard CFArrayGetCount(array) <= 128 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        var windows: [AutoQuitAXWindowInfo] = []
        for index in 0..<CFArrayGetCount(array) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let object = unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: CFTypeRef.self)
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            let window = object as! AXUIElement
            let (roleError, role) = query(window, kAXRoleAttribute as CFString)
            guard roleError == .success, let role, CFGetTypeID(role) == CFStringGetTypeID(),
                  (role as! CFString) as String == kAXWindowRole as String else { return nil }
            let (subroleError, subrole) = query(window, kAXSubroleAttribute as CFString)
            guard subroleError == .success, let subrole, CFGetTypeID(subrole) == CFStringGetTypeID() else { return nil }
            guard !windows.contains(where: { CFEqual($0.element, window) }) else { return nil }
            windows.append(AutoQuitAXWindowInfo(element: window,
                                               closeEligible: (subrole as! CFString) as String == kAXStandardWindowSubrole as String))
        }
        return windows
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (error, value)
    }
}

private enum AutoQuitWorkerEvent {
    case snapshot(AutoQuitProcess, AutoQuitWindowSnapshot)
    case created(AutoQuitProcess)
    case closed(AutoQuitProcess, UInt64)
    case unsupported(AutoQuitProcess, String)
}

private final class AutoQuitObserverBridge {
    let receive: (AXObserver, AXUIElement, CFString) -> Void
    init(receive: @escaping (AXObserver, AXUIElement, CFString) -> Void) { self.receive = receive }
}

private final class AutoQuitAXRecord {
    let process: AutoQuitProcess
    let app: AXUIElement
    let observer: AXObserver
    let bridge: AutoQuitObserverBridge
    var windows: [UInt64: AutoQuitAXWindowInfo] = [:]
    var nextWindow: UInt64 = 0
    var unsupportedWindow = false

    init(process: AutoQuitProcess, app: AXUIElement, observer: AXObserver, bridge: AutoQuitObserverBridge) {
        self.process = process
        self.app = app
        self.observer = observer
        self.bridge = bridge
    }
}

private final class AutoQuitAXWorker {
    private let queue = DispatchQueue(label: "com.dropshelf.auto-quit.windows", qos: .utility)
    private var records: [Int32: AutoQuitAXRecord] = [:]
    private var token: UUID?
    private var event: ((AutoQuitWorkerEvent) -> Void)?

    func reset(token: UUID?, event: ((AutoQuitWorkerEvent) -> Void)? = nil) {
        queue.async { [self] in
            for record in records.values { removeSource(record) }
            records.removeAll()
            self.token = token
            self.event = event
        }
    }

    func attach(_ process: AutoQuitProcess, token: UUID, created: @escaping @MainActor () -> Void) {
        queue.async { [weak self] in
            guard let self, self.token == token, self.records[process.pid] == nil else { return }
            let app = AXUIElementCreateApplication(process.pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            let bridge = AutoQuitObserverBridge { [weak self] observer, element, notification in
                if notification as String == kAXWindowCreatedNotification as String {
                    // The observer source runs on the main run loop. Cancel the
                    // deadline here, before any asynchronous AX query can lag.
                    MainActor.assumeIsolated { created() }
                }
                self?.received(observer, element: element, notification: notification, process: process, token: token)
            }
            var created: AXObserver?
            let result = AXObserverCreate(process.pid, { observer, element, notification, context in
                guard let context else { return }
                let bridge = Unmanaged<AutoQuitObserverBridge>.fromOpaque(context).takeUnretainedValue()
                bridge.receive(observer, element, notification)
            }, &created)
            guard result == .success, let observer = created else {
                self.event?(.unsupported(process, "Window notifications are unavailable; this app is left running."))
                return
            }
            let record = AutoQuitAXRecord(process: process, app: app, observer: observer, bridge: bridge)
            let registration = AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString,
                                                         Unmanaged.passUnretained(bridge).toOpaque())
            guard registration == .success || registration == .notificationAlreadyRegistered else {
                self.event?(.unsupported(process, "Window creation notifications are unavailable; this app is left running."))
                return
            }
            self.records[process.pid] = record
            let initial = self.sample(record)
            self.event?(.snapshot(process, initial))
            DispatchQueue.main.async {
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(record.observer), .commonModes)
            }
        }
    }

    func detach(_ process: AutoQuitProcess, token: UUID) {
        queue.async { [weak self] in
            guard let self, self.token == token, let record = self.records[process.pid], record.process == process else { return }
            self.records.removeValue(forKey: process.pid)
            self.removeSource(record)
        }
    }

    func refresh(_ process: AutoQuitProcess, token: UUID) {
        queue.async { [weak self] in
            guard let self, self.token == token, let record = self.records[process.pid], record.process == process else { return }
            let result = self.sample(record)
            // A baseline refresh is not a close event. Keep the last known window
            // identities until their destruction notification or a fresh nonempty list.
            if result.windowIDs != [] { self.event?(.snapshot(process, result)) }
        }
    }

    func snapshot(_ process: AutoQuitProcess, token: UUID, completion: @escaping (AutoQuitWindowSnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self, self.token == token, let record = self.records[process.pid], record.process == process else {
                completion(.uncertain)
                return
            }
            completion(self.sample(record))
        }
    }

    private func received(_ observer: AXObserver, element: AXUIElement, notification: CFString,
                          process: AutoQuitProcess, token: UUID) {
        queue.async { [weak self] in
            guard let self, self.token == token, let record = self.records[process.pid],
                  record.process == process, CFEqual(observer, record.observer) else { return }
            if notification as String == kAXUIElementDestroyedNotification as String {
                guard let id = record.windows.first(where: { CFEqual($0.value.element, element) })?.key else { return }
                record.windows.removeValue(forKey: id)
                self.event?(.closed(process, id))
            } else if notification as String == kAXWindowCreatedNotification as String {
                self.event?(.created(process))
                self.event?(.snapshot(process, self.sample(record)))
            }
        }
    }

    private func sample(_ record: AutoQuitAXRecord) -> AutoQuitWindowSnapshot {
        guard let current = AutoQuitWindowReader.windows(of: record.app) else {
            event?(.unsupported(record.process, "Window state is uncertain; this app is left running."))
            return .uncertain
        }
        // Do not drop an old identity merely because a query omitted it. A real
        // destruction notification must remove it before zero can be trusted.
        for window in current {
            if let existing = record.windows.first(where: { CFEqual($0.value.element, window.element) })?.key {
                record.windows[existing] = window
                continue
            }
            record.nextWindow &+= 1
            let id = record.nextWindow
            let registration = AXObserverAddNotification(record.observer, window.element, kAXUIElementDestroyedNotification as CFString,
                                                         Unmanaged.passUnretained(record.bridge).toOpaque())
            if registration != .success && registration != .notificationAlreadyRegistered {
                record.unsupportedWindow = true
                event?(.unsupported(record.process, "Window close notifications are unavailable; this app is left running."))
            }
            record.windows[id] = window
        }
        guard !record.unsupportedWindow else { return .uncertain }
        let visibleIDs = Set(record.windows.compactMap { entry in
            current.contains(where: { CFEqual($0.element, entry.value.element) }) ? entry.key : nil
        })
        // A window disappearing from an AX array alone is insufficient evidence
        // that it closed. This also preserves minimized and other-Space windows.
        guard visibleIDs.count == record.windows.count else { return .uncertain }
        return .known(visibleIDs, eligible: Set(record.windows.filter { $0.value.closeEligible }.keys))
    }

    private func removeSource(_ record: AutoQuitAXRecord) {
        DispatchQueue.main.async {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(record.observer), .commonModes)
            // Keep the callback bridge alive through source removal on its run loop.
            withExtendedLifetime(record) {}
        }
    }
}

@MainActor
final class AutoQuitObserverRuntime: AutoQuitRuntime {
    var permissionGranted: Bool { AXIsProcessTrusted() }
    private weak var controller: AutoQuitController?
    private let worker = AutoQuitAXWorker()
    private var token = UUID()
    private var tracked: [Int32: AutoQuitProcess] = [:]
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false

    func start(controller: AutoQuitController) {
        stop()
        self.controller = controller
        resetWorker()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor in self?.attach(app) }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            let identifier = app.bundleIdentifier
            let launchDate = app.launchDate
            Task { @MainActor in
                guard let self, let process = self.tracked[pid] else { return }
                if launchDate != nil {
                    guard process.matches(pid: pid, bundleIdentifier: identifier, launchDate: launchDate) else { return }
                } else if NSRunningApplication(processIdentifier: pid)?.isTerminated == false {
                    return
                }
                self.tracked.removeValue(forKey: pid)
                self.worker.detach(process, token: self.token)
                self.controller?.processTerminated(process)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.controller?.resetTracking()
                self.resetWorker()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                self.controller?.resetTracking()
                self.resetWorker()
                NSWorkspace.shared.runningApplications.forEach { self.attach($0) }
            }
        })
        NSWorkspace.shared.runningApplications.forEach { attach($0) }
    }

    func stop() {
        token = UUID()
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        tracked.removeAll()
        controller = nil
        sleeping = false
        worker.reset(token: nil)
    }

    func snapshot(for process: AutoQuitProcess, completion: @escaping @MainActor (AutoQuitWindowSnapshot) -> Void) {
        guard validated(process) != nil else { completion(.uncertain); return }
        let epoch = token
        worker.snapshot(process, token: epoch) { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.token == epoch, self.validated(process) != nil else {
                    completion(.uncertain)
                    return
                }
                completion(snapshot)
            }
        }
    }

    func requestQuit(_ process: AutoQuitProcess) -> Bool {
        guard let app = validated(process), controller?.isEligible(process) == true else { return false }
        return app.terminate()
    }

    private func validated(_ process: AutoQuitProcess) -> NSRunningApplication? {
        guard !sleeping, permissionGranted, tracked[process.pid] == process,
              let app = NSRunningApplication(processIdentifier: process.pid), !app.isTerminated,
              app.activationPolicy == .regular, app.bundleIdentifier == process.bundleIdentifier,
              app.launchDate == process.launchDate else { return nil }
        return app
    }

    private func resetWorker() {
        token = UUID()
        tracked.removeAll()
        let epoch = token
        worker.reset(token: epoch) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.token == epoch, let controller = self.controller else { return }
                    switch event {
                case .snapshot(let process, let snapshot):
                    guard self.tracked[process.pid] == process else { return }
                    controller.observe(process, snapshot: snapshot)
                    if case .known = snapshot { controller.reportSupported(bundleIdentifier: process.bundleIdentifier) }
                case .closed(let process, let window):
                    guard self.tracked[process.pid] == process else { return }
                    controller.windowClosed(process, window: window)
                case .created(let process):
                    guard self.tracked[process.pid] == process else { return }
                    controller.windowCreated(process)
                case .unsupported(let process, let reason):
                    guard self.tracked[process.pid] == process else { return }
                    controller.reportUnsupported(bundleIdentifier: process.bundleIdentifier, reason: reason)
                    }
                }
            }
        }
    }

    private func attach(_ app: NSRunningApplication) {
        guard !sleeping, let controller, controller.isRunning, permissionGranted,
              app.activationPolicy == .regular, !app.isTerminated, let identifier = app.bundleIdentifier,
              !controller.keepRunning.contains(identifier),
              !AutoQuitProtection.isProtected(bundleIdentifier: identifier, ownIdentifier: controller.ownIdentifier) else { return }
        guard let launchDate = app.launchDate else {
            controller.reportUnsupported(bundleIdentifier: identifier, reason: "Process identity is unavailable; this app is left running.")
            return
        }
        if let existing = tracked[app.processIdentifier] {
            guard existing.bundleIdentifier == identifier, existing.launchDate == launchDate else {
                worker.detach(existing, token: token)
                controller.processTerminated(existing)
                tracked.removeValue(forKey: app.processIdentifier)
                attach(app)
                return
            }
            worker.refresh(existing, token: token)
            return
        }
        let process = AutoQuitProcess(pid: app.processIdentifier, bundleIdentifier: identifier, launchDate: launchDate)
        tracked[process.pid] = process
        let epoch = token
        worker.attach(process, token: epoch) { [weak self] in
            guard let self, self.token == epoch, self.tracked[process.pid] == process else { return }
            self.controller?.windowCreated(process)
        }
    }
}
