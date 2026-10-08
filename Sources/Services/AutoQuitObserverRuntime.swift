import AppKit
import ApplicationServices
import OSLog

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
            let eligible = (subrole as! CFString) as String == kAXStandardWindowSubrole as String
            windows.append(AutoQuitAXWindowInfo(element: window, closeEligible: eligible))
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
    var registeredWindows: Set<UInt64> = []
    var windowAttempts: [UInt64: Int] = [:]
    var retryScheduled = false
    var creationHints: [AXUIElement] = []
    var creationRetry = 0
    var creationOverflow = false
    var registered = false

    init(process: AutoQuitProcess, app: AXUIElement, observer: AXObserver, bridge: AutoQuitObserverBridge) {
        self.process = process
        self.app = app
        self.observer = observer
        self.bridge = bridge
    }
}

private final class AutoQuitAXWorker {
    private let logger = Logger(subsystem: "com.dropshelf.macos", category: "AutoQuit")
    private let queue = DispatchQueue(label: "com.dropshelf.auto-quit.windows", qos: .utility)
    private var records: [Int32: AutoQuitAXRecord] = [:]
    private var token: UUID?
    private var event: ((AutoQuitWorkerEvent, UInt64) -> Void)?
    private var deliveryGeneration: UInt64 = 0
    private var suspended = false

    func reset(token: UUID?, generation: UInt64 = 0, event: ((AutoQuitWorkerEvent, UInt64) -> Void)? = nil) {
        queue.async { [self] in
            for record in records.values { removeSource(record) }
            records.removeAll()
            self.token = token
            self.deliveryGeneration = generation
            self.suspended = false
            self.event = event
        }
    }

    func attach(_ process: AutoQuitProcess, token: UUID, attempt: Int = 0, created: @escaping @MainActor () -> Void, generation: @escaping @MainActor () -> UInt64?) {
        queue.async { [weak self] in
            guard let self, !self.suspended, self.token == token, self.records[process.pid] == nil else { return }
            guard let appIdentity = NSRunningApplication(processIdentifier: process.pid),
                  process.matches(pid: appIdentity.processIdentifier, bundleIdentifier: appIdentity.bundleIdentifier,
                                  launchDate: appIdentity.launchDate), !appIdentity.isTerminated else { return }
            let app = AXUIElementCreateApplication(process.pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            let bridge = AutoQuitObserverBridge { [weak self] observer, element, notification in
                guard let eventGeneration = MainActor.assumeIsolated({ generation() }) else { return }
                self?.logger.notice("Window notification pid=\(process.pid, privacy: .public), kind=\(notification as String, privacy: .public)")
                if notification as String == kAXWindowCreatedNotification as String {
                    // The observer source runs on the main run loop. Cancel the
                    // deadline here, before any asynchronous AX query can lag.
                    MainActor.assumeIsolated { created() }
                }
                self?.received(observer, element: element, notification: notification, process: process, token: token, generation: eventGeneration)
            }
            var observerResult: AXObserver?
            let result = AXObserverCreate(process.pid, { observer, element, notification, context in
                guard let context else { return }
                let bridge = Unmanaged<AutoQuitObserverBridge>.fromOpaque(context).takeUnretainedValue()
                bridge.receive(observer, element, notification)
            }, &observerResult)
            guard result == .success, let observer = observerResult else {
                self.retryAttachment(process, token: token, attempt: attempt, created: created, generation: generation,
                                     error: result, reason: "Window notifications are unavailable; this app is left running.")
                return
            }
            let record = AutoQuitAXRecord(process: process, app: app, observer: observer, bridge: bridge)
            self.records[process.pid] = record
            DispatchQueue.main.async { [weak self] in
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(record.observer), .commonModes)
                self?.register(record, token: token, attempt: attempt, created: created, generation: generation)
            }
        }
    }

    private func register(_ record: AutoQuitAXRecord, token: UUID, attempt: Int,
                          created: @escaping @MainActor () -> Void, generation: @escaping @MainActor () -> UInt64?) {
        queue.async { [weak self] in
            guard let self, self.token == token, self.records[record.process.pid] === record else { return }
            let registration = AXObserverAddNotification(record.observer, record.app, kAXWindowCreatedNotification as CFString,
                                                         Unmanaged.passUnretained(record.bridge).toOpaque())
            guard registration == .success || registration == .notificationAlreadyRegistered else {
                self.records.removeValue(forKey: record.process.pid)
                self.removeSource(record)
                self.retryAttachment(record.process, token: token, attempt: attempt, created: created, generation: generation,
                                     error: registration, reason: "Window creation notifications are unavailable; this app is left running.")
                return
            }
            for notification in [kAXMainWindowChangedNotification, kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification] {
                _ = AXObserverAddNotification(record.observer, record.app, notification as CFString,
                                              Unmanaged.passUnretained(record.bridge).toOpaque())
            }
            record.registered = true
            self.emit(.snapshot(record.process, self.sample(record)))
        }
    }

    private func retryAttachment(_ process: AutoQuitProcess, token: UUID, attempt: Int,
                                 created: @escaping @MainActor () -> Void, generation: @escaping @MainActor () -> UInt64?, error: AXError, reason: String) {
        logger.notice("Window registration pid=\(process.pid, privacy: .public), attempt=\(attempt, privacy: .public), error=\(error.rawValue, privacy: .public)")
        guard let delay = AutoQuitAttachmentRetry.delay(after: attempt), error != .illegalArgument else {
            emit(.unsupported(process, reason))
            return
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attach(process, token: token, attempt: attempt + 1, created: created, generation: generation)
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
            if result.windowIDs != [] { self.emit(.snapshot(process, result)) }
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
                          process: AutoQuitProcess, token: UUID, generation: UInt64) {
        queue.async { [weak self] in
            guard let self, self.token == token, let record = self.records[process.pid],
                  record.process == process, CFEqual(observer, record.observer) else { return }
            if notification as String == kAXWindowCreatedNotification as String {
                if !record.creationHints.contains(where: { CFEqual($0, element) }) {
                    if record.creationHints.count < 128 { record.creationHints.append(element); record.creationRetry = 0 }
                    else { record.creationOverflow = true }
                }
            }
            guard !self.suspended, self.deliveryGeneration == generation else { return }
            if notification as String == kAXUIElementDestroyedNotification as String {
                record.creationHints.removeAll { CFEqual($0, element) }
                guard let id = record.windows.first(where: { CFEqual($0.value.element, element) })?.key else { return }
                record.windows.removeValue(forKey: id)
                record.registeredWindows.remove(id)
                record.windowAttempts.removeValue(forKey: id)
                self.emit(.closed(process, id))
            } else if notification as String == kAXWindowCreatedNotification as String {
                self.emit(.created(process))
                self.emit(.snapshot(process, self.sample(record)))
            } else if notification as String == kAXMainWindowChangedNotification as String
                        || notification as String == kAXFocusedWindowChangedNotification as String {
                self.emit(.snapshot(process, self.sample(record)))
            }
        }
    }

    private func sample(_ record: AutoQuitAXRecord) -> AutoQuitWindowSnapshot {
        guard !suspended, record.registered else { return .uncertain }
        guard !record.creationOverflow else { return .uncertain }
        guard let current = AutoQuitWindowReader.windows(of: record.app) else {
            logger.notice("Window state uncertain pid=\(record.process.pid, privacy: .public)")
            emit(.unsupported(record.process, "Window state is uncertain; this app is left running."))
            return .uncertain
        }
        // Do not drop an old identity merely because a query omitted it. A real
        // destruction notification must remove it before zero can be trusted.
        var retryDelay: TimeInterval?
        for window in current {
            let id: UInt64
            if let existing = record.windows.first(where: { CFEqual($0.value.element, window.element) })?.key { id = existing }
            else { record.nextWindow &+= 1; id = record.nextWindow }
            record.windows[id] = window
            if record.registeredWindows.contains(id) { continue }
            let registration = AXObserverAddNotification(record.observer, window.element, kAXUIElementDestroyedNotification as CFString,
                                                         Unmanaged.passUnretained(record.bridge).toOpaque())
            logger.notice("Close registration pid=\(record.process.pid, privacy: .public), window=\(id, privacy: .public), error=\(registration.rawValue, privacy: .public)")
            if registration != .success && registration != .notificationAlreadyRegistered {
                emit(.unsupported(record.process, "Window close notifications are unavailable; this app is left running."))
                let attempt = record.windowAttempts[id] ?? 0
                record.windowAttempts[id] = attempt + 1
                if let delay = AutoQuitAttachmentRetry.delay(after: attempt), registration != .illegalArgument {
                    retryDelay = min(retryDelay ?? delay, delay)
                }
            } else {
                record.registeredWindows.insert(id)
            }
        }
        if let retryDelay { scheduleWindowRetry(record, seconds: retryDelay) }
        record.creationHints.removeAll { hint in current.contains { CFEqual($0.element, hint) } }
        guard record.creationHints.isEmpty else {
            if let delay = AutoQuitAttachmentRetry.delay(after: record.creationRetry) {
                record.creationRetry += 1
                scheduleWindowRetry(record, seconds: delay)
            }
            emit(.unsupported(record.process, "A new window is not ready for verification; this app is left running."))
            return .uncertain
        }
        record.creationRetry = 0
        for (id, window) in record.windows where !window.closeEligible && !current.contains(where: { CFEqual($0.element, window.element) }) {
            var role: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &role)
            let validity: AutoQuitElementValidity = error == .invalidUIElement ? .invalid : (error == .success ? .valid : .uncertain)
            logger.notice("Absent dialog pid=\(record.process.pid, privacy: .public), window=\(id, privacy: .public), roleError=\(error.rawValue, privacy: .public)")
            if AutoQuitStaleWindowPolicy.mayRetireDialog(closeEligible: window.closeEligible, validity: validity) {
                record.windows.removeValue(forKey: id)
                record.registeredWindows.remove(id)
                record.windowAttempts.removeValue(forKey: id)
            }
        }
        guard Set(record.windows.keys).isSubset(of: record.registeredWindows) else {
            logger.notice("Close observation incomplete pid=\(record.process.pid, privacy: .public), retained=\(record.windows.count, privacy: .public), subscribed=\(record.registeredWindows.count, privacy: .public)")
            return .uncertain
        }
        let visibleIDs = Set(record.windows.compactMap { entry in
            current.contains(where: { CFEqual($0.element, entry.value.element) }) ? entry.key : nil
        })
        // A window disappearing from an AX array alone is insufficient evidence
        // that it closed. This also preserves minimized and other-Space windows.
        guard visibleIDs.count == record.windows.count else {
            logger.notice("Window list incomplete pid=\(record.process.pid, privacy: .public), current=\(visibleIDs.count, privacy: .public), retained=\(record.windows.count, privacy: .public)")
            return .uncertain
        }
        logger.notice("Window state pid=\(record.process.pid, privacy: .public), count=\(visibleIDs.count, privacy: .public), eligible=\(record.windows.values.filter { $0.closeEligible }.count, privacy: .public)")
        return .known(visibleIDs, eligible: Set(record.windows.filter { $0.value.closeEligible }.keys))
    }

    private func scheduleWindowRetry(_ record: AutoQuitAXRecord, seconds: TimeInterval) {
        guard !record.retryScheduled, let epoch = token else { return }
        record.retryScheduled = true
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.token == epoch, self.records[record.process.pid] === record else { return }
            record.retryScheduled = false
            self.emit(.snapshot(record.process, self.sample(record)))
        }
    }

    private func emit(_ event: AutoQuitWorkerEvent) {
        self.event?(event, deliveryGeneration)
    }

    func setDeliveryGeneration(_ generation: UInt64, suspended: Bool) {
        queue.async { [self] in
            deliveryGeneration = generation
            self.suspended = suspended
        }
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
                self.controller?.cancelPendingDecisions()
                self.worker.setDeliveryGeneration(self.controller?.eventGeneration ?? 0, suspended: self.sleeping)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                self.controller?.cancelPendingDecisions()
                self.worker.setDeliveryGeneration(self.controller?.eventGeneration ?? 0, suspended: self.sleeping)
                NSWorkspace.shared.runningApplications.forEach { self.attach($0) }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.sleeping else { return }
                self.controller?.cancelPendingDecisions()
                self.worker.setDeliveryGeneration(self.controller?.eventGeneration ?? 0, suspended: self.sleeping)
                for process in self.tracked.values { self.worker.refresh(process, token: self.token) }
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
        worker.reset(token: epoch, generation: controller?.eventGeneration ?? 0) { [weak self] event, generation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.sleeping, self.token == epoch, let controller = self.controller, controller.eventGeneration == generation else { return }
                    switch event {
                case .snapshot(let process, let snapshot):
                    guard self.tracked[process.pid] == process else { return }
                    controller.observe(process, snapshot: snapshot)
                    if case .known = snapshot { controller.reportSupported(bundleIdentifier: process.bundleIdentifier) }
                case .closed(let process, let window):
                    guard self.tracked[process.pid] == process else { return }
                    controller.windowClosed(process, window: window, eventGeneration: generation)
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
            let epoch = token
            worker.attach(existing, token: epoch, created: { [weak self] in
                guard let self, self.token == epoch, self.tracked[existing.pid] == existing else { return }
                self.controller?.windowCreated(existing)
            }, generation: { [weak self] in
                guard let self, !self.sleeping, self.token == epoch else { return nil }
                return self.controller?.eventGeneration
            })
            return
        }
        let process = AutoQuitProcess(pid: app.processIdentifier, bundleIdentifier: identifier, launchDate: launchDate)
        tracked[process.pid] = process
        let epoch = token
        worker.attach(process, token: epoch, created: { [weak self] in
            guard let self, self.token == epoch, self.tracked[process.pid] == process else { return }
            self.controller?.windowCreated(process)
        }, generation: { [weak self] in
            guard let self, !self.sleeping, self.token == epoch else { return nil }
            return self.controller?.eventGeneration
        })
    }
}
