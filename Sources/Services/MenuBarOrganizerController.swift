import AppKit
import ApplicationServices
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
    var hidingUnavailableReason: String? { get }
    var requiresAccessibilityVerification: Bool { get }
    var requiresDedicatedArrow: Bool { get }
    var requiresVisibilityConfirmation: Bool { get }
    var allowsVisibilityTrial: Bool { get }
    var platformSignature: String { get }
    var conflictingOrganizerRunning: Bool { get }
    func quitConflictingOrganizer() -> Bool
    func refreshCapabilities()
    func start(anchor: NSStatusItem, controller: MenuBarOrganizerController)
    func stop()
    func apply(hidden: Bool, separateToggle: Bool, completion: @escaping @MainActor (Bool) -> Void)
    func registerShortcut(_ shortcut: MenuBarShortcut) -> Bool
    func unregisterShortcut()
    func allowsHiding() -> Bool
}

extension MenuBarOrganizerRuntime {
    var requiresAccessibilityVerification: Bool { false }
    var requiresDedicatedArrow: Bool { false }
    func refreshCapabilities() {}
}

@MainActor
final class MenuBarOrganizerController: NSObject, ObservableObject {
    static let shared = MenuBarOrganizerController(defaults: .standard)
    var hidingUnavailableReason: String? { runtime.hidingUnavailableReason }
    var hidingAvailable: Bool { hidingUnavailableReason == nil }
    var requiresAccessibilityVerification: Bool { runtime.requiresAccessibilityVerification }
    var requiresDedicatedArrow: Bool { runtime.requiresDedicatedArrow }
    @Published private(set) var enabled: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var hidden = false
    @Published private(set) var isApplying = false
    @Published private(set) var pendingHiddenTarget: Bool?
    @Published private(set) var isArranging = false
    @Published private(set) var settingsOpen = false
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
                } else { applyLayout(hidden: hidden, resumeAutoHideWhenVisible: !hidden) }
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
    private var applyEpoch: UInt64 = 0
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
        if runtime.requiresDedicatedArrow && !showSeparateToggle { showSeparateToggle = true }
        generation &+= 1
        isRunning = true; hidden = false
        runtime.start(anchor: anchor, controller: self)
        applyLayout(hidden: false, resumeAutoHideWhenVisible: true)
        displaySignature = runtime.displaySignature
        refreshVisibilityRequirement()
        installObservers()
        if !hidingAvailable { shortcutMessage = runtime.requiresAccessibilityVerification ? "Enable menu bar verification to use the shortcut" : "Menu bar hiding is unavailable on this macOS version" }
        else if shortcutEnabled { setShortcut(shortcut) }
        else { shortcutMessage = "Shortcut is turned off" }
        updateStatus()
        if hasCompletedSetup && startHidden { startupDeadline = now().addingTimeInterval(15) }
        scheduleAutoHide()
    }
    func shutdown() {
        if let conflictExitObserver { NSWorkspace.shared.notificationCenter.removeObserver(conflictExitObserver) }
        conflictExitObserver = nil
        settingsOpen = false
        guard isRunning else { return }
        generation &+= 1
        cancelHide()
        pauseTask?.cancel(); pauseTask = nil
        observers.forEach { $0.0.removeObserver($0.1) }; observers.removeAll()
        applyLayout(hidden: false)
        invalidatePendingApply()
        runtime.stop()
        isRunning = false; hidden = false; isArranging = false; menuOpen = false; startupDeadline = nil
        pause = .none; updatePause()
        recordingShortcut = false; shortcutAvailable = false; hasVisibilityTrial = false
        updateStatus()
    }
    func toggleHiddenItems() {
        guard enabled && isRunning else { return }
        guard hidingAvailable else { reveal(); showSettings?(); return }
        if isApplying { reveal(); return }
        if hidden {
            reveal()
        } else {
            if isArranging { endArranging() }
            hide()
        }
    }
    func reveal() {
        reveal(confirmingVisibilityTrial: false)
    }
    private func reveal(confirmingVisibilityTrial: Bool) {
        guard enabled && isRunning else { return }
        startupDeadline = nil; cancelHide()
        applyLayout(hidden: false, resumeAutoHideWhenVisible: true,
                    confirmsVisibilityTrial: confirmingVisibilityTrial)
    }
    func hide() {
        guard enabled && isRunning, !isArranging, !isApplying else { return }
        guard hidingAvailable else { reveal(); updateStatus(); return }
        refreshConflictingOrganizerState()
        guard !conflictingOrganizerRunning else { updateStatus(); return }
        refreshVisibilityRequirement()
        guard !hidden else { return }
        guard !requiresVisibilityConfirmation || runtime.allowsVisibilityTrial else {
            showSettings?(); return
        }
        startupDeadline = nil; cancelHide(); pauseTask?.cancel(); pauseTask = nil
        pause = .none; updatePause()
        applyLayout(hidden: true)
    }
    func toggleFromMenuBarControl() {
        guard enabled && isRunning else { return }
        guard hidingAvailable else { reveal(); showSettings?(); return }
        if isApplying { reveal(); return }
        if hidden {
            reveal(confirmingVisibilityTrial: requiresVisibilityConfirmation)
        } else {
            if isArranging { endArranging() }
            hide()
        }
    }
    func beginArranging() {
        guard enabled && isRunning && hidingAvailable else { return }
        isArranging = true; reveal(); updateStatus()
    }
    func endArranging() {
        guard enabled && isRunning else { return }
        isArranging = false; cancelShortcutRecording(); updateStatus(); scheduleAutoHide()
    }
    func setSettingsOpen(_ value: Bool) {
        if value {
            settingsOpen = true
            startupDeadline = nil
            if enabled && isRunning { reveal() }
            else { cancelHide() }
        } else {
            guard settingsOpen else { return }
            settingsOpen = false
            scheduleAutoHide()
        }
    }
    func refreshCapabilities() {
        guard enabled && isRunning else { return }
        runtime.refreshCapabilities()
        if !hidingAvailable {
            if hidden || isApplying { reveal() }
            runtime.unregisterShortcut(); shortcutAvailable = false
            shortcutMessage = "Enable menu bar verification to use the shortcut"
        } else if shortcutEnabled && !shortcutAvailable && !conflictingOrganizerRunning {
            setShortcut(shortcut)
        }
        refreshVisibilityRequirement()
        updateStatus()
    }
    func requestAccessibilityVerification() {
        guard runtime.requiresAccessibilityVerification else { return }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        updateStatus()
    }
    func completeSetup() {
        guard enabled && isRunning && hidingAvailable else { return }
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
    private func invalidatePendingApply() {
        applyEpoch &+= 1
        isApplying = false
        pendingHiddenTarget = nil
        hidden = false
    }
    private func applyLayout(hidden target: Bool, resumeAutoHideWhenVisible: Bool = false,
                             confirmsVisibilityTrial: Bool = false) {
        applyEpoch &+= 1
        let epoch = applyEpoch
        isApplying = true
        pendingHiddenTarget = target
        hidden = false
        updateStatus()
        runtime.apply(hidden: target, separateToggle: showSeparateToggle) { [weak self] actualHidden in
            guard let self, self.applyEpoch == epoch else { return }
            self.isApplying = false
            self.pendingHiddenTarget = nil
            self.hidden = target && actualHidden
            if confirmsVisibilityTrial && !target && !actualHidden && self.requiresVisibilityConfirmation {
                self.hasVisibilityTrial = true
            }
            self.updateStatus()
            if resumeAutoHideWhenVisible && !self.hidden { self.scheduleAutoHide() }
        }
    }
    private func scheduleAutoHide() {
        cancelHide()
        guard enabled, isRunning, hidingAvailable, hasCompletedSetup, !requiresVisibilityConfirmation, !hidden, !isArranging,
              !isApplying, !settingsOpen, !pause.isActive(at: now()) else { return }
        if let startupDeadline {
            scheduleHide(after: max(0.1, startupDeadline.timeIntervalSince(now())), startup: true)
        } else if autoHide { scheduleHide(after: delay, startup: false) }
    }
    private func scheduleHide(after seconds: Double, startup: Bool) {
        cancelHide()
        let epoch = generation, layoutEpoch = layoutGeneration
        hideTask = schedule(seconds) { [weak self] in
            guard let self, self.enabled, self.isRunning, self.hidingAvailable, self.generation == epoch,
                  self.layoutGeneration == layoutEpoch, self.hasCompletedSetup,
                  !self.hidden, !self.isApplying, !self.isArranging, !self.settingsOpen,
                  !self.pause.isActive(at: self.now()),
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
            self?.refreshConflictingOrganizerState(); self?.refreshCapabilities(); self?.refreshPause()
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
        "\(runtime.platformSignature)|\(runtime.displaySignature)|toggle=\(showSeparateToggle)|verification=native-single-divider-v3"
    }
    func refreshVisibilityRequirement(requestSettings: Bool = false) {
        guard enabled && isRunning else { return }
        guard hidingAvailable else {
            requiresVisibilityConfirmation = false; hasVisibilityTrial = false
            updateStatus(); return
        }
        let scope = visibilityScope
        if runtime.requiresVisibilityConfirmation { usesVisibilityConfirmation = true }
        let pending = usesVisibilityConfirmation && defaults.string(forKey: "organizer.visibilityConfirmation") != scope
        let invalidated = pending && (!requiresVisibilityConfirmation || activeVisibilityScope != scope)
        activeVisibilityScope = scope
        requiresVisibilityConfirmation = pending
        if invalidated {
            hasVisibilityTrial = false; hasCompletedSetup = false
            defaults.set(false, forKey: "organizer.hasCompletedSetup")
            startupDeadline = nil; cancelHide()
            applyLayout(hidden: false)
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
        if let reason = hidingUnavailableReason { statusMessage = reason }
        else if !runtime.conflictMessage.isEmpty { statusMessage = runtime.conflictMessage }
        else if isApplying { statusMessage = "Checking menu bar controls…" }
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
        if enabled && hidingAvailable {
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
    @objc func dividerAction() { showSettings?() }
    @objc func separateToggleAction() {
        if NSApp.currentEvent?.type == .rightMouseUp { showSettings?() }
        else { toggleFromMenuBarControl() }
    }
}
