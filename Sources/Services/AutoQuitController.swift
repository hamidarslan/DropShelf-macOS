import AppKit
import ApplicationServices
import Combine
import OSLog

@MainActor
final class AutoQuitTask {
    private var cancellation: (() -> Void)?
    init(cancel: @escaping () -> Void) { cancellation = cancel }
    func cancel() { cancellation?(); cancellation = nil }

    static func schedule(seconds: TimeInterval, action: @escaping @MainActor () -> Void) -> AutoQuitTask {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return AutoQuitTask { timer.invalidate() }
    }
}

@MainActor
protocol AutoQuitRuntime: AnyObject {
    var permissionGranted: Bool { get }
    func start(controller: AutoQuitController)
    func stop()
    func snapshot(for process: AutoQuitProcess, completion: @escaping @MainActor (AutoQuitWindowSnapshot) -> Void)
    func requestQuit(_ process: AutoQuitProcess) -> Bool
}

@MainActor
final class AutoQuitController: ObservableObject {
    private let logger = Logger(subsystem: "com.dropshelf.macos", category: "AutoQuit")
    static let shared = AutoQuitController(defaults: .standard, runtime: AutoQuitObserverRuntime())
    @Published private(set) var enabled: Bool
    @Published private(set) var keepRunning: Set<String>
    @Published private(set) var isRunning = false
    @Published private(set) var permissionGranted = false
    @Published private(set) var monitoringCount = 0
    @Published private(set) var unsupportedApps: [String: String] = [:]
    @Published private(set) var lastOutcome = ""
    @Published private(set) var hasReviewedWindowMonitoring: Bool

    var status: String { !enabled ? "Off" : (isRunning ? "On" : "Permission needed") }
    var eventGeneration: UInt64 { generation }
    let ownIdentifier: String
    private let defaults: UserDefaults
    private let runtime: AutoQuitRuntime
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AutoQuitTask
    private var states: [AutoQuitProcess: AutoQuitDecisionState] = [:]
    private var pending: [AutoQuitProcess: AutoQuitTask] = [:]
    private var generation: UInt64 = 0
    private var started = false
    private var permissionTimer: Timer?

    init(defaults: UserDefaults, runtime: AutoQuitRuntime,
         ownIdentifier: String = Bundle.main.bundleIdentifier ?? "com.dropshelf.macos",
         schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AutoQuitTask = AutoQuitTask.schedule) {
        self.defaults = defaults
        self.runtime = runtime
        self.ownIdentifier = ownIdentifier
        self.schedule = schedule
        enabled = defaults.bool(forKey: "autoQuit.enabled")
        keepRunning = Set((defaults.stringArray(forKey: "autoQuit.keepRunning") ?? []).filter { !$0.isEmpty && $0.count <= 512 })
        permissionGranted = runtime.permissionGranted
        hasReviewedWindowMonitoring = defaults.bool(forKey: "autoQuit.didReviewWindowMonitoring")
    }

    func start() {
        guard !started else { return }
        started = true
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }
        refreshPermission()
    }

    func shutdown() {
        started = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        stopRuntime()
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        defaults.set(value, forKey: "autoQuit.enabled")
        refreshPermission()
    }

    func enableFromSettings() {
        hasReviewedWindowMonitoring = true
        defaults.set(true, forKey: "autoQuit.didReviewWindowMonitoring")
        setEnabled(true)
    }

    func setKeepRunning(_ value: Bool, bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty, bundleIdentifier.count <= 512 else { return }
        var updated = keepRunning
        if value { updated.insert(bundleIdentifier) } else { updated.remove(bundleIdentifier) }
        setKeepRunning(updated)
    }

    func setKeepRunning(_ identifiers: Set<String>) {
        let valid = Set(identifiers.filter { !$0.isEmpty && $0.count <= 512 })
        guard valid != keepRunning else { return }
        keepRunning = valid
        defaults.set(keepRunning.sorted(), forKey: "autoQuit.keepRunning")
        if isRunning {
            stopRuntime()
            refreshPermission()
        }
    }

    func refreshPermission() {
        permissionGranted = runtime.permissionGranted
        let shouldRun = started && enabled && permissionGranted
        if shouldRun && !isRunning {
            generation &+= 1
            isRunning = true
            unsupportedApps.removeAll()
            runtime.start(controller: self)
        } else if !shouldRun && isRunning {
            stopRuntime()
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refreshPermission()
    }

    func isEligible(_ process: AutoQuitProcess) -> Bool {
        isRunning && enabled && runtime.permissionGranted
            && !keepRunning.contains(process.bundleIdentifier)
            && !AutoQuitProtection.isProtected(bundleIdentifier: process.bundleIdentifier, ownIdentifier: ownIdentifier)
    }

    func observe(_ process: AutoQuitProcess, snapshot: AutoQuitWindowSnapshot) {
        guard isEligible(process) else { return }
        var state = states[process] ?? AutoQuitDecisionState()
        state.observe(snapshot)
        states[process] = state
        if state.pendingToken == nil { pending.removeValue(forKey: process)?.cancel() }
        monitoringCount = states.values.filter { $0.windows != nil }.count
    }

    func windowClosed(_ process: AutoQuitProcess, window: UInt64, eventGeneration: UInt64? = nil) {
        if let eventGeneration, eventGeneration != generation { return }
        guard isEligible(process), var state = states[process] else { return }
        let token = state.closed(window: window)
        logger.notice("Close received pid=\(process.pid, privacy: .public), remaining=\(state.windows?.count ?? -1, privacy: .public), candidate=\(token != nil, privacy: .public)")
        states[process] = state
        pending.removeValue(forKey: process)?.cancel()
        guard let token else { return }
        let epoch = generation
        pending[process] = schedule(1) { [weak self] in
            guard let self, self.generation == epoch, self.isEligible(process),
                  self.states[process]?.pendingToken == token else { return }
            self.runtime.snapshot(for: process) { [weak self] snapshot in
                guard let self, self.generation == epoch, self.isEligible(process),
                      var current = self.states[process], current.pendingToken == token else { return }
                let allowed = current.consume(token: token, snapshot: snapshot)
                self.logger.notice("Quit decision pid=\(process.pid, privacy: .public), freshWindows=\(snapshot.windowIDs?.count ?? -1, privacy: .public), allowed=\(allowed, privacy: .public)")
                self.states[process] = current
                self.pending.removeValue(forKey: process)?.cancel()
                guard allowed else { return }
                self.lastOutcome = self.runtime.requestQuit(process)
                    ? "Normal quit requested. The app may ask to save or remain open."
                    : "The app could not accept the quit request. It was left running."
            }
        }
    }

    func windowCreated(_ process: AutoQuitProcess) {
        guard isEligible(process), var state = states[process] else { return }
        // A creation proves the old baseline is incomplete even if AXWindows
        // has not caught up. Queued older destruction must not arm from it.
        state.created()
        states[process] = state
        pending.removeValue(forKey: process)?.cancel()
        monitoringCount = states.values.filter { $0.windows != nil }.count
    }

    func processTerminated(_ process: AutoQuitProcess) {
        let wasTracked = states.removeValue(forKey: process) != nil
        pending.removeValue(forKey: process)?.cancel()
        monitoringCount = states.values.filter { $0.windows != nil }.count
        if wasTracked { lastOutcome = "App exit confirmed." }
    }

    func reportUnsupported(bundleIdentifier: String, reason: String) {
        guard isRunning else { return }
        unsupportedApps[bundleIdentifier] = reason
    }

    func reportSupported(bundleIdentifier: String) {
        unsupportedApps.removeValue(forKey: bundleIdentifier)
    }

    func resetTracking() {
        generation &+= 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        states.removeAll()
        monitoringCount = 0
        unsupportedApps.removeAll()
    }

    func cancelPendingDecisions() {
        generation &+= 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        for process in states.keys { states[process]?.invalidate() }
    }

    func restartBaseline() {
        guard isRunning else { return }
        stopRuntime()
        refreshPermission()
    }

    private func stopRuntime() {
        generation &+= 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        states.removeAll()
        monitoringCount = 0
        isRunning = false
        runtime.stop()
    }
}
