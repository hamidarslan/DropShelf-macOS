import AppKit
import Carbon
import Combine

@MainActor
final class MenuBarOrganizerTask {
    private var cancellation: (() -> Void)?
    init(cancel: @escaping () -> Void) { cancellation = cancel }
    func cancel() { cancellation?(); cancellation = nil }
    static func schedule(seconds: TimeInterval, action: @escaping @MainActor () -> Void) -> MenuBarOrganizerTask {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return MenuBarOrganizerTask { timer.invalidate() }
    }
}

@MainActor
protocol MenuBarOrganizerRuntime: AnyObject {
    var displaySignature: String { get }
    var conflictMessage: String { get }
    var requiresVisibilityConfirmation: Bool { get }
    var allowsVisibilityTrial: Bool { get }
    var platformSignature: String { get }
    var conflictingOrganizerRunning: Bool { get }
    func quitConflictingOrganizer() -> Bool
    func start(anchor: NSStatusItem, controller: MenuBarOrganizerController)
    func stop()
    @discardableResult func apply(hidden: Bool, separateToggle: Bool) -> Bool
    func registerShortcut(_ shortcut: MenuBarShortcut) -> Bool
    func unregisterShortcut()
    func allowsHiding() -> Bool
}

@MainActor
final class MenuBarOrganizerController: NSObject, ObservableObject {
    static let shared = MenuBarOrganizerController(defaults: .standard)
    @Published private(set) var enabled: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var hidden = false
    @Published private(set) var isArranging = false
    @Published private(set) var hasCompletedSetup: Bool
    @Published private(set) var requiresVisibilityConfirmation = false
    @Published private(set) var hasVisibilityTrial = false
    @Published private(set) var conflictingOrganizerRunning = false
    @Published private(set) var pauseDescription = "Auto-hide follows your settings"
    @Published private(set) var isPaused = false
    @Published private(set) var shortcut: MenuBarShortcut = .standard
    @Published private(set) var shortcutEnabled: Bool
    @Published private(set) var shortcutAvailable = false
    @Published private(set) var shortcutMessage = ""
    @Published private(set) var statusMessage = "Menu bar organizer is off"
    @Published var autoHide: Bool { didSet { defaults.set(autoHide, forKey: "organizer.autoHide"); scheduleAutoHide() } }
    @Published var delay: Double {
        didSet {
            if !Self.delays.contains(delay) { delay = 10 }
            defaults.set(delay, forKey: "organizer.delay")
            scheduleAutoHide()
        }
    }
    @Published var startHidden: Bool {
        didSet {
            defaults.set(startHidden, forKey: "organizer.startHidden")
            if !startHidden && startupDeadline != nil {
                startupDeadline = nil
                scheduleAutoHide()
            }
        }
    }
    @Published var showSeparateToggle: Bool {
        didSet {
            defaults.set(showSeparateToggle, forKey: "organizer.showSeparateToggle")
            if isRunning && oldValue != showSeparateToggle {
                hasVisibilityTrial = false
                if usesVisibilityConfirmation || runtime.requiresVisibilityConfirmation || requiresVisibilityConfirmation {
                    defaults.removeObject(forKey: "organizer.visibilityConfirmation")
                    reveal()
                    refreshVisibilityRequirement(requestSettings: true)
                } else { hidden = runtime.apply(hidden: hidden, separateToggle: showSeparateToggle); updateStatus() }
            }
        }
    }
    @Published var recordingShortcut = false
    private static let delays: [Double] = [5, 10, 15, 30, 60]
    private let defaults: UserDefaults
    private let runtime: MenuBarOrganizerRuntime
    private let now: () -> Date
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> MenuBarOrganizerTask
    private var anchor: NSStatusItem?
    private var showSettings: (() -> Void)?
    private var hideTask: MenuBarOrganizerTask?
    private var pauseTask: MenuBarOrganizerTask?
    private var pause: MenuBarPause = .none
    private var menuOpen = false
    private var startupDeadline: Date?
    private var generation: UInt64 = 0
    private var layoutGeneration: UInt64 = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var displaySignature = ""
    private var activeVisibilityScope = ""
    private var usesVisibilityConfirmation = false
    private var conflictExitObserver: NSObjectProtocol?
    private var conflictQuitMessage = ""

    convenience init(defaults: UserDefaults) {
        self.init(defaults: defaults, runtime: AppKitMenuBarOrganizerRuntime(), now: Date.init,
                  schedule: { MenuBarOrganizerTask.schedule(seconds: $0, action: $1) })
    }
    init(defaults: UserDefaults, runtime: MenuBarOrganizerRuntime, now: @escaping () -> Date,
         schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> MenuBarOrganizerTask) {
        self.defaults = defaults; self.runtime = runtime; self.now = now; self.schedule = schedule
        defaults.register(defaults: ["organizer.enabled": false, "organizer.autoHide": true,
            "organizer.delay": 10.0, "organizer.startHidden": true,
            "organizer.showSeparateToggle": false, "organizer.shortcutEnabled": true])
        enabled = defaults.bool(forKey: "organizer.enabled")
        autoHide = defaults.bool(forKey: "organizer.autoHide")
        let storedDelay = defaults.double(forKey: "organizer.delay")
        delay = Self.delays.contains(storedDelay) ? storedDelay : 10
        startHidden = defaults.bool(forKey: "organizer.startHidden")
        showSeparateToggle = defaults.bool(forKey: "organizer.showSeparateToggle")
        hasCompletedSetup = defaults.bool(forKey: "organizer.hasCompletedSetup")
        shortcutEnabled = defaults.bool(forKey: "organizer.shortcutEnabled")
        super.init()
        usesVisibilityConfirmation = defaults.string(forKey: "organizer.visibilityConfirmation") != nil
        conflictingOrganizerRunning = runtime.conflictingOrganizerRunning
        if let key = defaults.object(forKey: "organizer.shortcutKey") as? NSNumber,
           let mask = defaults.object(forKey: "organizer.shortcutModifiers") as? NSNumber,
           let keyCode = UInt32(exactly: key.int64Value), let modifiers = UInt32(exactly: mask.int64Value) {
            let candidate = MenuBarShortcut(keyCode: keyCode, modifiers: modifiers,
                                           label: defaults.string(forKey: "organizer.shortcutLabel") ?? "")
            if candidate.isValid { shortcut = candidate }
        }
    }
    func configure(anchor: NSStatusItem, showSettings: @escaping () -> Void) {
        self.anchor = anchor; self.showSettings = showSettings
        conflictingOrganizerRunning = runtime.conflictingOrganizerRunning
        if enabled { activate() }
    }
    func setEnabled(_ value: Bool) {
        let changed = enabled != value
        enabled = value
        defaults.set(value, forKey: "organizer.enabled")
        if value {
            activate()
            if changed && !hasCompletedSetup { showSettings?() }
        } else { shutdown() }
    }
    private func activate() {
        guard enabled, !isRunning, let anchor else { return }
        generation &+= 1
        isRunning = true; hidden = false
        runtime.start(anchor: anchor, controller: self)
        runtime.apply(hidden: false, separateToggle: showSeparateToggle)
        displaySignature = runtime.displaySignature
        refreshVisibilityRequirement()
        installObservers()
        if shortcutEnabled { setShortcut(shortcut) }
        else { shortcutMessage = "Shortcut is turned off" }
        updateStatus()
        if hasCompletedSetup && startHidden { startupDeadline = now().addingTimeInterval(15) }
        scheduleAutoHide()
    }
    func shutdown() {
        if let conflictExitObserver { NSWorkspace.shared.notificationCenter.removeObserver(conflictExitObserver) }
        conflictExitObserver = nil
        guard isRunning else { return }
        generation &+= 1
        cancelHide()
        pauseTask?.cancel(); pauseTask = nil
        observers.forEach { $0.0.removeObserver($0.1) }; observers.removeAll()
        runtime.stop()
        isRunning = false; hidden = false; isArranging = false; menuOpen = false; startupDeadline = nil
        pause = .none; updatePause()
        recordingShortcut = false; shortcutAvailable = false; hasVisibilityTrial = false
        updateStatus()
    }
    func toggleHiddenItems() {
        guard enabled && isRunning else { return }
        if hidden {
            reveal()
        } else {
            if isArranging { endArranging() }
            hide()
        }
    }
    func reveal() {
        guard enabled && isRunning else { return }
        startupDeadline = nil; cancelHide(); hidden = false
        runtime.apply(hidden: false, separateToggle: showSeparateToggle)
        updateStatus(); scheduleAutoHide()
    }
    func hide() {
        guard enabled && isRunning, !isArranging else { return }
        refreshConflictingOrganizerState()
        guard !conflictingOrganizerRunning else { updateStatus(); return }
        refreshVisibilityRequirement()
        guard !hidden else { return }
        guard !requiresVisibilityConfirmation || runtime.allowsVisibilityTrial else {
            showSettings?(); return
        }
        startupDeadline = nil; cancelHide(); pauseTask?.cancel(); pauseTask = nil
        pause = .none; updatePause(); hidden = true
        hidden = runtime.apply(hidden: true, separateToggle: showSeparateToggle)
        if hidden && requiresVisibilityConfirmation { hasVisibilityTrial = true }
        updateStatus()
    }
    func beginArranging() {
        guard enabled && isRunning else { return }
        isArranging = true; reveal(); updateStatus()
    }
    func endArranging() {
        guard enabled && isRunning else { return }
        isArranging = false; cancelShortcutRecording(); updateStatus(); scheduleAutoHide()
    }
    func completeSetup() {
        guard enabled && isRunning else { return }
        refreshVisibilityRequirement()
        guard !requiresVisibilityConfirmation || hasVisibilityTrial else { updateStatus(); return }
        if requiresVisibilityConfirmation {
            defaults.set(visibilityScope, forKey: "organizer.visibilityConfirmation")
            requiresVisibilityConfirmation = false
        }
        hasCompletedSetup = true
        defaults.set(true, forKey: "organizer.hasCompletedSetup")
        endArranging()
    }
    func pauseHiding(seconds: TimeInterval?) {
        guard enabled && isRunning else { return }
        if let seconds, !seconds.isFinite || seconds <= 0 { return }
        pauseTask?.cancel(); pauseTask = nil
        if let seconds {
            pause = .until(now().addingTimeInterval(seconds))
            let epoch = generation
            pauseTask = schedule(seconds) { [weak self] in
                guard let self, self.isRunning, self.generation == epoch else { return }
                self.refreshPause()
            }
        } else { pause = .untilResumed }
        updatePause(); reveal()
    }
    func resumeHiding() {
        guard enabled && isRunning else { return }
        pauseTask?.cancel(); pauseTask = nil; pause = .none
        updatePause(); updateStatus(); scheduleAutoHide()
    }
    func refreshPause() {
        guard enabled && isRunning else { return }
        pause.expire(at: now()); updatePause(); updateStatus(); scheduleAutoHide()
    }
    private func updatePause() {
        isPaused = pause.isActive(at: now())
        switch pause {
        case .none: pauseDescription = "Auto-hide follows your settings"
        case .until(let date): pauseDescription = "Visible until \(date.formatted(date: .omitted, time: .shortened))"
        case .untilResumed: pauseDescription = "Visible until resumed or DropShelf quits"
        }
    }
    func setMenuOpen(_ value: Bool) {
        menuOpen = value
        if !value { scheduleAutoHide() }
    }
    private func cancelHide() { layoutGeneration &+= 1; hideTask?.cancel(); hideTask = nil }
    private func scheduleAutoHide() {
        cancelHide()
        guard enabled, isRunning, hasCompletedSetup, !requiresVisibilityConfirmation, !hidden, !isArranging,
              !pause.isActive(at: now()) else { return }
        if let startupDeadline {
            scheduleHide(after: max(0.1, startupDeadline.timeIntervalSince(now())), startup: true)
        } else if autoHide { scheduleHide(after: delay, startup: false) }
    }
    private func scheduleHide(after seconds: Double, startup: Bool) {
        cancelHide()
        let epoch = generation, layoutEpoch = layoutGeneration
        hideTask = schedule(seconds) { [weak self] in
            guard let self, self.enabled, self.isRunning, self.generation == epoch,
                  self.layoutGeneration == layoutEpoch, self.hasCompletedSetup,
                  !self.hidden, !self.isArranging, !self.pause.isActive(at: self.now()),
                  startup || self.autoHide else { return }
            self.refreshVisibilityRequirement(requestSettings: true)
            guard !self.requiresVisibilityConfirmation else { return }
            if self.menuOpen || !self.runtime.allowsHiding() {
                self.scheduleHide(after: self.delay, startup: startup)
            } else { self.hide() }
        }
    }
    private func installObservers() {
        let epoch = generation
        func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRunning, self.generation == epoch else { return }
                    action()
                }
            }
            observers.append((center, token))
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self else { return }
            let signature = self.runtime.displaySignature
            guard signature != self.displaySignature else { return }
            self.displaySignature = signature
            self.hasVisibilityTrial = false
            self.recoverAfterDisplayChange()
            self.refreshVisibilityRequirement(requestSettings: true)
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in
            self?.refreshPause(); self?.recoverAfterDisplayChange()
        }
        observe(.default, NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.refreshConflictingOrganizerState(); self?.refreshVisibilityRequirement(); self?.refreshPause()
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let center = NSWorkspace.shared.notificationCenter
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "local.hidebar.app" else { return }
                Task { @MainActor in
                    guard let self, self.isRunning, self.generation == epoch else { return }
                    self.refreshConflictingOrganizerState()
                }
            }
            observers.append((center, token))
        }
    }
    private func recoverAfterDisplayChange() {
        reveal()
        if hasCompletedSetup && startHidden && !isPaused && !isArranging {
            startupDeadline = now().addingTimeInterval(15)
            scheduleAutoHide()
        }
    }
    private var visibilityScope: String {
        "\(runtime.platformSignature)|\(runtime.displaySignature)|toggle=\(showSeparateToggle)|verification=native-segments-v2"
    }
    func refreshVisibilityRequirement(requestSettings: Bool = false) {
        guard enabled && isRunning else { return }
        let scope = visibilityScope
        if runtime.requiresVisibilityConfirmation { usesVisibilityConfirmation = true }
        let pending = usesVisibilityConfirmation && defaults.string(forKey: "organizer.visibilityConfirmation") != scope
        let invalidated = pending && (!requiresVisibilityConfirmation || activeVisibilityScope != scope)
        activeVisibilityScope = scope
        requiresVisibilityConfirmation = pending
        if invalidated {
            hasVisibilityTrial = false; hasCompletedSetup = false
            defaults.set(false, forKey: "organizer.hasCompletedSetup")
            startupDeadline = nil; cancelHide(); hidden = false
            runtime.apply(hidden: false, separateToggle: showSeparateToggle)
        }
        updateStatus()
        if invalidated && requestSettings { showSettings?() }
    }
    func rejectVisibilityTrial() {
        hasVisibilityTrial = false
        if usesVisibilityConfirmation { defaults.removeObject(forKey: "organizer.visibilityConfirmation") }
        reveal()
        refreshVisibilityRequirement(requestSettings: true)
    }
    func refreshConflictingOrganizerState() {
        let wasConflicting = conflictingOrganizerRunning
        conflictingOrganizerRunning = runtime.conflictingOrganizerRunning
        if conflictingOrganizerRunning {
            runtime.unregisterShortcut(); shortcutAvailable = false
            shortcutMessage = "Shortcut held while Hidebar is running"
            if hidden { reveal() }
        } else {
            conflictQuitMessage = ""
            if wasConflicting && enabled && isRunning {
                refreshVisibilityRequirement(requestSettings: true)
                if shortcutEnabled { setShortcut(shortcut) }
                if startupDeadline != nil && startHidden { startupDeadline = now().addingTimeInterval(15) }
                scheduleAutoHide()
            }
        }
        updateStatus()
    }
    func quitConflictingOrganizer() {
        guard runtime.conflictingOrganizerRunning else { return }
        if let conflictExitObserver { NSWorkspace.shared.notificationCenter.removeObserver(conflictExitObserver) }
        conflictExitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "local.hidebar.app" else { return }
                Task { @MainActor in
                    guard let self else { return }
                    if let token = self.conflictExitObserver { NSWorkspace.shared.notificationCenter.removeObserver(token) }
                    self.conflictExitObserver = nil
                    self.refreshConflictingOrganizerState()
                }
            }
        let accepted = runtime.quitConflictingOrganizer()
        if accepted {
            conflictQuitMessage = "Waiting for Hidebar to quit. If it stays open, quit it from its menu bar, then return here."
        } else {
            conflictQuitMessage = "Could not quit Hidebar. Quit it from its menu bar, then return here."
            if let conflictExitObserver { NSWorkspace.shared.notificationCenter.removeObserver(conflictExitObserver) }
            conflictExitObserver = nil
        }
        refreshConflictingOrganizerState()
    }
    private func updateStatus() {
        if conflictingOrganizerRunning {
            statusMessage = conflictQuitMessage.isEmpty ? "Hidebar is running. Use one organizer at a time." : conflictQuitMessage
            return
        }
        guard enabled && isRunning else { statusMessage = enabled ? "Organizer starts when DropShelf is ready" : "Menu bar organizer is off"; return }
        if !runtime.conflictMessage.isEmpty { statusMessage = runtime.conflictMessage }
        else if requiresVisibilityConfirmation {
            statusMessage = hasVisibilityTrial ? "Check that icons hide and the menu bar control stays visible" : "Try hiding, then check your menu bar control"
        }
        else if isArranging { statusMessage = "Hold Command and drag icons to the left of the divider" }
        else if !hasCompletedSetup { statusMessage = "Arrange your icons, then finish setup" }
        else if isPaused { statusMessage = pauseDescription }
        else {
            statusMessage = hidden
                ? (showSeparateToggle ? "Icons hidden. Click the menu bar arrow to reveal" : "Icons hidden. Option-click DropShelf to reveal")
                : "Menu bar icons are visible"
        }
    }
    func setShortcut(_ candidate: MenuBarShortcut) {
        guard candidate.isValid else {
            recordingShortcut = false
            shortcutMessage = "Use Control or Command with a key. Command Shift Y is reserved for the shelf."
            return
        }
        if isRunning {
            conflictingOrganizerRunning = runtime.conflictingOrganizerRunning
            guard !conflictingOrganizerRunning else {
                runtime.unregisterShortcut()
                shortcutAvailable = false; recordingShortcut = false
                shortcutMessage = "Shortcut held while Hidebar is running"
                return
            }
            if shortcutAvailable && candidate.keyCode == shortcut.keyCode && candidate.modifiers == shortcut.modifiers {
                recordingShortcut = false; shortcutMessage = "This shortcut is already active"; return
            }
            guard runtime.registerShortcut(candidate) else {
                recordingShortcut = false
                shortcutMessage = "Shortcut unavailable or in use. Your previous shortcut is unchanged."
                return
            }
        }
        shortcut = candidate; shortcutEnabled = true; shortcutAvailable = isRunning
        recordingShortcut = false
        defaults.set(Int(candidate.keyCode), forKey: "organizer.shortcutKey")
        defaults.set(Int(candidate.modifiers), forKey: "organizer.shortcutModifiers")
        defaults.set(candidate.label, forKey: "organizer.shortcutLabel")
        defaults.set(true, forKey: "organizer.shortcutEnabled")
        shortcutMessage = isRunning ? "Press \(candidate.display) to show or hide icons" : "Shortcut saved. Enable the organizer to use it."
    }
    func disableShortcut() {
        runtime.unregisterShortcut(); shortcutEnabled = false; shortcutAvailable = false; recordingShortcut = false
        defaults.set(false, forKey: "organizer.shortcutEnabled")
        shortcutMessage = "Shortcut is turned off"
    }
    func cancelShortcutRecording() {
        guard recordingShortcut else { return }
        recordingShortcut = false; shortcutMessage = "Recording cancelled. Your shortcut is unchanged."
    }
    func makeContextMenuItems() -> [NSMenuItem] {
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        var items = [item("Menu Bar Organizer", #selector(toggleEnabledAction))]
        items[0].state = enabled ? .on : .off
        if enabled {
            items.append(item(hidden ? "Reveal Menu Bar Icons" : "Hide Menu Bar Icons", #selector(toggleAction)))
            items.append(item("Keep Icons Visible", #selector(keepVisibleAction)))
            for (title, seconds) in [("Pause Hiding for 5 Minutes", 300), ("Pause Hiding for 1 Hour", 3600)] {
                let pause = item(title, #selector(timedPauseAction(_:))); pause.tag = seconds; items.append(pause)
            }
            if isPaused { items.append(item("Resume Auto-hide", #selector(resumeAction))) }
        }
        items.append(item("Menu Bar Settings…", #selector(settingsAction)))
        return items
    }
    @objc private func toggleEnabledAction() { setEnabled(!enabled) }
    @objc private func toggleAction() { toggleHiddenItems() }
    @objc private func keepVisibleAction() { pauseHiding(seconds: nil) }
    @objc private func timedPauseAction(_ item: NSMenuItem) { pauseHiding(seconds: Double(item.tag)) }
    @objc private func resumeAction() { resumeHiding() }
    @objc private func settingsAction() { showSettings?() }
    @objc fileprivate func dividerAction() { showSettings?() }
    @objc fileprivate func separateToggleAction() {
        if NSApp.currentEvent?.type == .rightMouseUp { showSettings?() }
        else { toggleHiddenItems() }
    }
}

@MainActor
private final class AppKitMenuBarOrganizerRuntime: MenuBarOrganizerRuntime {
    private var divider: NSStatusItem?
    private var spacers: [NSStatusItem] = []
    private var separateToggle: NSStatusItem?
    private weak var controller: MenuBarOrganizerController?
    private weak var anchor: NSStatusItem?
    private var layoutMessage = ""
    private var layoutEpoch: UInt64 = 0
    private var runEpoch: UInt64 = 0
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x44534D42
    private var modern: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }
    var conflictingOrganizerRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "local.hidebar.app").isEmpty
    }
    var conflictMessage: String {
        if conflictingOrganizerRunning { return "Hidebar is running. Use one organizer at a time." }
        return layoutMessage
    }
    var platformSignature: String { ProcessInfo.processInfo.operatingSystemVersionString }
    var requiresVisibilityConfirmation: Bool { syntheticHostCapability() }
    var allowsVisibilityTrial: Bool {
        NSApp.windows.contains { $0.isVisible && $0.title == "DropShelf Settings" }
    }
    func quitConflictingOrganizer() -> Bool {
        var accepted = true
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "local.hidebar.app") {
            if !app.terminate() { accepted = false }
        }
        return accepted
    }
    var displaySignature: String {
        NSScreen.screens.map {
            let displayID = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let identity = CGDisplayCreateUUIDFromDisplayID(displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "unknown"
            return "\(identity):\($0.frame):\($0.visibleFrame):\($0.auxiliaryTopRightArea ?? .zero):\($0.auxiliaryTopLeftArea ?? .zero)"
        }.sorted().joined(separator: "|")
    }
    func start(anchor: NSStatusItem, controller: MenuBarOrganizerController) {
        runEpoch &+= 1
        let epoch = runEpoch
        self.controller = controller; self.anchor = anchor
        layoutMessage = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.runEpoch == epoch, let controller = self.controller, controller.isRunning else { return }
                controller.refreshVisibilityRequirement(requestSettings: true)
            }
        }
        createSeparateToggle()
        if modern {
            // Reserve the bounded pool before the divider to keep its ordering across display changes.
            ensureSpacers(15)
        }
        let item = NSStatusBar.system.statusItem(withLength: 16)
        item.autosaveName = "DropShelf.Organizer.Divider"
        item.button?.title = "│"
        item.button?.font = .systemFont(ofSize: 15, weight: .light)
        item.button?.target = controller
        item.button?.action = #selector(MenuBarOrganizerController.dividerAction)
        item.button?.toolTip = "Hold Command and drag icons to the left of this divider"
        item.button?.setAccessibilityLabel("Menu bar organizer divider")
        divider = item
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var keyID = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &keyID) == noErr,
                keyID.signature == 0x44534D42 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let runtime = Unmanaged<AppKitMenuBarOrganizerRuntime>.fromOpaque(userData).takeUnretainedValue()
                guard let controller = runtime.controller, controller.enabled, controller.isRunning else { return }
                if controller.recordingShortcut { controller.cancelShortcutRecording() }
                else { controller.toggleHiddenItems() }
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func stop() {
        runEpoch &+= 1
        layoutEpoch &+= 1
        unregisterShortcut()
        if let handler { RemoveEventHandler(handler) }; handler = nil
        if let divider { NSStatusBar.system.removeStatusItem(divider) }; divider = nil
        spacers.forEach { NSStatusBar.system.removeStatusItem($0) }; spacers.removeAll()
        if let separateToggle { NSStatusBar.system.removeStatusItem(separateToggle) }; separateToggle = nil
        controller = nil; anchor = nil; layoutMessage = ""
    }
    @discardableResult func apply(hidden: Bool, separateToggle: Bool) -> Bool {
        layoutEpoch &+= 1
        let epoch = layoutEpoch
        if let item = self.separateToggle {
            let length: CGFloat = separateToggle ? 24 : 0
            if item.length != length { item.length = length }
            if item.isVisible != separateToggle { item.isVisible = separateToggle }
        }
        var hidden = hidden
        let synthetic = syntheticHostCapability()
        if hidden && conflictingOrganizerRunning {
            hidden = false
            layoutMessage = "Hidebar is running. Use one organizer at a time."
        } else if hidden && !synthetic && !canHide(requiresToggle: separateToggle) {
            hidden = false
            layoutMessage = "Keep DropShelf and the optional toggle to the right of the divider. Hold Command to rearrange them."
        } else if hidden { layoutMessage = "" }
        let lengths = spacerLengths()
        if hidden && lengths.isEmpty {
            hidden = false
            layoutMessage = "Menu bar space is unavailable for this display setup. Your icons remain visible."
        }
        if modern { ensureSpacers(max(0, lengths.count - 1)) }
        divider?.length = hidden ? lengths[0] : 16
        divider?.button?.title = hidden ? "" : "│"
        for (index, item) in spacers.enumerated() {
            let slot = index + 1
            let length: CGFloat = hidden && slot < lengths.count ? lengths[slot] : 0
            let visible = hidden && slot < lengths.count
            if item.length != length { item.length = length }
            if item.isVisible != visible { item.isVisible = visible }
        }
        let image = NSImage(systemSymbolName: hidden ? "chevron.left" : "chevron.right", accessibilityDescription: hidden ? "Reveal menu bar icons" : "Hide menu bar icons")
        image?.isTemplate = true
        self.separateToggle?.button?.image = image
        self.separateToggle?.button?.toolTip = hidden ? "Reveal menu bar icons" : "Hide menu bar icons"
        if hidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.layoutEpoch == epoch,
                          let controller = self.controller, controller.isRunning, controller.hidden else { return }
                    let ready = synthetic || self.recoveryIsReachable(requiresToggle: separateToggle)
                    if self.conflictingOrganizerRunning || !ready {
                        self.layoutMessage = "Icons were revealed to keep DropShelf reachable. Move the divider to the left of DropShelf."
                        controller.rejectVisibilityTrial()
                    }
                }
            }
        }
        return hidden
    }
    private func spacerLengths() -> [Double] {
        MenuBarSpacerLayout.lengths(displays: NSScreen.screens.map {
            MenuBarDisplayWidth(width: Double($0.frame.width),
                usableRightWidth: $0.auxiliaryTopRightArea.map { Double($0.width) })
        }, modern: modern)
    }
    private func ensureSpacers(_ count: Int) {
        while spacers.count < min(count, 15) {
            let item = NSStatusBar.system.statusItem(withLength: 0)
            item.autosaveName = "DropShelf.Organizer.Spacer.\(spacers.count + 1)"
            item.button?.setAccessibilityElement(false)
            item.isVisible = false
            spacers.append(item)
        }
    }
    private func screenRect(_ item: NSStatusItem?) -> CGRect? {
        guard let button = item?.button, let window = button.window, item?.isVisible == true else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    private func recoveryScreen() -> NSScreen? {
        guard let rect = screenRect(anchor) else { return nil }
        return NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
    }
    private func canHide(requiresToggle: Bool) -> Bool {
        guard let screen = recoveryScreen() else { return false }
        return MenuBarOrganizerGeometry.canHide(anchor: screenRect(anchor), divider: screenRect(divider),
            toggle: screenRect(separateToggle), screen: screen.frame, requiresToggle: requiresToggle)
    }
    private func syntheticHostCapability() -> Bool {
        guard let anchor, let divider, anchor !== divider,
              let anchorWindow = anchor.button?.window, let dividerWindow = divider.button?.window else { return false }
        return MenuBarOrganizerGeometry.hasSyntheticHosts(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            windowIDs: [anchorWindow.windowNumber, dividerWindow.windowNumber], distinctItems: true)
    }
    private func recoveryIsReachable(requiresToggle: Bool) -> Bool {
        guard let screen = recoveryScreen() else { return false }
        let usable = screen.auxiliaryTopRightArea ?? screen.frame
        let anchorRect = screenRect(anchor)
        guard MenuBarOrganizerGeometry.isReachable(anchorRect, in: screen.frame), let anchorRect,
              anchorRect.minX >= usable.minX - 1 else { return false }
        if requiresToggle {
            guard let toggle = screenRect(separateToggle),
                  MenuBarOrganizerGeometry.isReachable(toggle, in: screen.frame),
                  toggle.minX >= usable.minX - 1, abs(toggle.midY - anchorRect.midY) <= 4 else { return false }
        }
        return true
    }
    private func createSeparateToggle() {
        let visible = controller?.showSeparateToggle == true
        let item = NSStatusBar.system.statusItem(withLength: visible ? 24 : 0)
        item.autosaveName = "DropShelf.Organizer.Toggle"
        item.isVisible = visible
        item.button?.target = controller
        item.button?.action = #selector(MenuBarOrganizerController.separateToggleAction)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        separateToggle = item
    }
    func registerShortcut(_ shortcut: MenuBarShortcut) -> Bool {
        guard handler != nil, !conflictingOrganizerRunning else { return false }
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: signature, id: 1), GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive), &replacement)
        guard status == noErr, let replacement else { return false }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        return true
    }
    func unregisterShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
    }
    func allowsHiding() -> Bool {
        let point = NSEvent.mouseLocation
        let nearMenu = NSScreen.screens.contains { $0.frame.contains(point) && point.y > $0.frame.maxY - 80 }
        return !nearMenu && NSEvent.pressedMouseButtons == 0
    }
}
