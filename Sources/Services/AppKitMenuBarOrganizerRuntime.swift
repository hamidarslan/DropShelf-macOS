import AppKit
import Carbon
import OSLog

@MainActor
final class AppKitMenuBarOrganizerRuntime: MenuBarOrganizerRuntime {
    private var divider: NSStatusItem?
    private var separateToggle: NSStatusItem?
    private weak var controller: MenuBarOrganizerController?
    private weak var anchor: NSStatusItem?
    private var layoutMessage = ""
    private var layoutEpoch: UInt64 = 0
    private var runEpoch: UInt64 = 0
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x44534D42
    private let monitor = MenuBarControlMonitor()
    private let controlIDs = MenuBarControlExpectedIDs(arrow: "dropshelf.organizer.arrow.v3", divider: "dropshelf.organizer.divider.v3")
    private var inspection: MenuBarControlInspectionRequest?
    private var pendingCompletion: (@MainActor (Bool) -> Void)?
    private var guardTimer: Timer?
    private var requestTimeout: DispatchWorkItem?
    private var arrangementMonitor: Any?
    private var guardPolicy = MenuBarGuardPolicy()
    private var lastGuardDiagnostic: String?
    private let logger = Logger(subsystem: "com.dropshelf.macos", category: "MenuBar")
    var requiresAccessibilityVerification: Bool { modern }
    var requiresDedicatedArrow: Bool { modern }
    private var modern: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }
    var hidingUnavailableReason: String? {
        guard modern else { return nil }
        switch monitor.trust {
        case .trusted: return nil
        case .denied: return "Enable Accessibility verification so DropShelf can check that its menu bar arrow stays reachable."
        case .unavailable: return "The system menu bar is not available. Your icons remain visible."
        }
    }
    var conflictingOrganizerRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "local.hidebar.app").isEmpty
    }
    var conflictMessage: String {
        if conflictingOrganizerRunning { return "Hidebar is running. Use one organizer at a time." }
        return layoutMessage
    }
    var platformSignature: String { ProcessInfo.processInfo.operatingSystemVersionString }
    var requiresVisibilityConfirmation: Bool { modern }
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
        let item = NSStatusBar.system.statusItem(withLength: 16)
        item.autosaveName = modern ? "DropShelf.Organizer.Divider.NativeV3" : "DropShelf.Organizer.Divider"
        item.button?.setAccessibilityIdentifier(controlIDs.divider)
        item.button?.title = "│"
        item.button?.font = .systemFont(ofSize: 15, weight: .light)
        item.button?.target = controller
        item.button?.action = #selector(MenuBarOrganizerController.dividerAction)
        item.button?.toolTip = "Hold Command and drag icons to the left of this divider"
        item.button?.setAccessibilityLabel("Menu bar organizer divider")
        divider = item
        refreshCapabilities()
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
    func refreshCapabilities() {
        guard modern else { return }
        if let arrangementMonitor { NSEvent.removeMonitor(arrangementMonitor) }; arrangementMonitor = nil
        guard monitor.trust == .trusted else { return }
            arrangementMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard event.modifierFlags.contains(.command) else { return }
                Task { @MainActor in
                    guard let self, self.controller?.isRunning == true else { return }
                    let point = NSEvent.mouseLocation
                    guard NSScreen.screens.contains(where: { $0.frame.contains(point) && point.y >= $0.frame.maxY - 44 }) else { return }
                    self.controller?.rejectVisibilityTrial()
                }
            }
    }
    func stop() {
        runEpoch &+= 1
        layoutEpoch &+= 1
        cancelPending()
        guardPolicy.reset(); lastGuardDiagnostic = nil
        guardTimer?.invalidate(); guardTimer = nil
        if let arrangementMonitor { NSEvent.removeMonitor(arrangementMonitor) }; arrangementMonitor = nil
        unregisterShortcut()
        if let handler { RemoveEventHandler(handler) }; handler = nil
        if let divider { NSStatusBar.system.removeStatusItem(divider) }; divider = nil
        if let separateToggle { NSStatusBar.system.removeStatusItem(separateToggle) }; separateToggle = nil
        controller = nil; anchor = nil; layoutMessage = ""
    }
    func apply(hidden: Bool, separateToggle: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        layoutEpoch &+= 1
        let epoch = layoutEpoch
        cancelPending()
        guardPolicy.reset(); lastGuardDiagnostic = nil
        guardTimer?.invalidate(); guardTimer = nil
        guard modern else { completion(applyLegacy(hidden: hidden, separateToggle: separateToggle)); return }
        if self.separateToggle?.isVisible == false { self.separateToggle?.isVisible = true }
        if self.separateToggle?.length != 24 { self.separateToggle?.length = 24 }
        guard hidden else {
            revealNative()
            completion(false)
            return
        }
        guard hidingUnavailableReason == nil, !conflictingOrganizerRunning else {
            layoutMessage = hidingUnavailableReason ?? "Hidebar is running. Use one organizer at a time."
            revealNative(); completion(false); return
        }
        guard NSMenu.menuBarVisible() else {
            layoutMessage = "Show the macOS menu bar before hiding icons."
            revealNative(); completion(false); return
        }
        pendingCompletion = completion
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.layoutEpoch == epoch else { return }
            self.finishNativeFailure("The menu bar check timed out. Click the arrow to retry.", invalidateSetup: false)
        }
        requestTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        inspection = monitor.inspect(expected: controlIDs, mode: .expanded) { [weak self] result in
            guard let self, self.layoutEpoch == epoch, self.controller?.isRunning == true else { return }
            self.inspection = nil
            guard result.reliable, let region = result.menuBarFrame,
                  let width = MenuBarNativeLayout.width(usableWidth: region.width) else {
                self.logInspection(result, context: "before-hide")
                let moved = result.reachability == .unreachable
                self.finishNativeFailure(moved
                    ? "Keep the arrow visible to the right of the divider. Your icons remain visible."
                    : "The menu bar check is temporarily unavailable. Click the arrow to retry.", invalidateSetup: moved)
                return
            }
            self.divider?.button?.title = ""
            self.divider?.length = width
            self.setArrow(hidden: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.verifyCollapsed(epoch: epoch)
            }
        }
    }

    private func verifyCollapsed(epoch: UInt64) {
        guard layoutEpoch == epoch, pendingCompletion != nil else { return }
        guard NSMenu.menuBarVisible() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.verifyCollapsed(epoch: epoch) }
            return
        }
        inspection = monitor.inspect(expected: controlIDs, mode: .collapsed) { [weak self] result in
            guard let self, self.layoutEpoch == epoch else { return }
            self.inspection = nil
            if !NSMenu.menuBarVisible() { self.verifyCollapsed(epoch: epoch); return }
            guard result.reachability == .reachable || result.reachability == .temporarilyObscured else {
                self.logInspection(result, context: "after-hide")
                self.finishNativeFailure("Icons were restored because their control could not be verified. Click the arrow to retry.",
                    invalidateSetup: result.reachability == .unreachable)
                return
            }
            self.requestTimeout?.cancel(); self.requestTimeout = nil
            self.layoutMessage = ""
            let callback = self.pendingCompletion; self.pendingCompletion = nil
            callback?(true)
            guard self.layoutEpoch == epoch else { return }
            self.startGuard(epoch: epoch)
            if self.controller?.requiresVisibilityConfirmation == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, self.layoutEpoch == epoch, self.controller?.hidden == true,
                          self.controller?.requiresVisibilityConfirmation == true else { return }
                    self.layoutMessage = "The test ended. Click the menu bar arrow to hide, then click it again to reveal."
                    self.controller?.expireVisibilityTrial()
                }
            }
        }
    }

    private func cancelPending() {
        requestTimeout?.cancel(); requestTimeout = nil
        if let inspection { monitor.cancel(inspection) }; inspection = nil
        let callback = pendingCompletion; pendingCompletion = nil
        callback?(false)
    }

    private func revealNative() {
        if divider?.length != 16 { divider?.length = 16 }
        if divider?.button?.title != "│" { divider?.button?.title = "│" }
        setArrow(hidden: false)
    }

    private func setArrow(hidden: Bool) {
        let label = hidden ? "Reveal menu bar icons" : "Hide menu bar icons"
        guard let button = separateToggle?.button, button.toolTip != label || button.image == nil else { return }
        let image = NSImage(systemSymbolName: hidden ? "chevron.left" : "chevron.right", accessibilityDescription: label)
        image?.isTemplate = true
        button.image = image
        button.toolTip = label
    }

    private func finishNativeFailure(_ message: String, invalidateSetup: Bool = true) {
        logger.notice("Restoring menu bar icons; invalidateSetup=\(invalidateSetup, privacy: .public)")
        layoutMessage = message
        guardTimer?.invalidate(); guardTimer = nil
        revealNative()
        cancelPending()
        guardPolicy.reset()
        if invalidateSetup { controller?.rejectVisibilityTrial() }
        else { controller?.pauseHiding(seconds: nil) }
    }

    private func logInspection(_ result: MenuBarControlInspectionResult, context: String) {
        let reason = String(describing: result.reason)
        let reachability = String(describing: result.reachability)
        logger.info("Menu bar check \(context, privacy: .public): \(reachability, privacy: .public), reason=\(reason, privacy: .public), stage=\(result.diagnostic.stage.rawValue, privacy: .public), error=\(result.diagnostic.axError ?? 0, privacy: .public), ms=\(result.diagnostic.elapsedMilliseconds, privacy: .public)")
    }

    private func startGuard(epoch: UInt64) {
        guardPolicy.reset(); lastGuardDiagnostic = nil
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.layoutEpoch == epoch, self.controller?.hidden == true,
                      self.inspection == nil else { return }
                guard NSMenu.menuBarVisible() else { self.guardPolicy.reset(); return }
                self.inspection = self.monitor.inspect(expected: self.controlIDs, mode: .collapsed) { [weak self] result in
                    guard let self, self.layoutEpoch == epoch else { return }
                    self.inspection = nil
                    guard NSMenu.menuBarVisible() else { self.guardPolicy.reset(); return }
                    let diagnostic = "\(result.reachability)|\(result.reason)|\(result.diagnostic.stage.rawValue)|\(result.diagnostic.axError ?? 0)"
                    if diagnostic != self.lastGuardDiagnostic {
                        if result.reachability != .reachable || self.lastGuardDiagnostic != nil {
                            self.logInspection(result, context: "while-hidden")
                        }
                        self.lastGuardDiagnostic = diagnostic
                    }
                    let observation: MenuBarGuardObservation
                    switch result.reachability {
                    case .reachable: observation = .reachable
                    case .temporarilyObscured: observation = .obscured
                    case .indeterminate: observation = .indeterminate
                    case .unreachable: observation = .unreachable
                    case .unauthorized: observation = .unauthorized
                    }
                    switch self.guardPolicy.observe(observation, at: ProcessInfo.processInfo.systemUptime) {
                    case .keepHidden: break
                    case .revealPreservingSetup:
                        self.finishNativeFailure("Menu bar verification is temporarily unavailable. Your layout is saved; click the arrow to retry.", invalidateSetup: false)
                    case .revealAndInvalidateSetup:
                        self.finishNativeFailure("Icons were restored after the arrow was confirmed unreachable. Check the divider position.")
                    }
                }
            }
        }
        guardTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyLegacy(hidden: Bool, separateToggle: Bool) -> Bool {
        let epoch = layoutEpoch
        guard hidingUnavailableReason == nil else { return false }
        if let item = self.separateToggle {
            let length: CGFloat = separateToggle ? 24 : 0
            if item.length != length { item.length = length }
            if item.isVisible != separateToggle { item.isVisible = separateToggle }
        }
        var hidden = hidden
        if hidden && conflictingOrganizerRunning {
            hidden = false
            layoutMessage = "Hidebar is running. Use one organizer at a time."
        } else if hidden && !canHide(requiresToggle: separateToggle) {
            hidden = false
            layoutMessage = "Keep DropShelf and the optional toggle to the right of the divider. Hold Command to rearrange them."
        } else if hidden { layoutMessage = "" }
        let lengths = spacerLengths()
        if hidden && lengths.isEmpty {
            hidden = false
            layoutMessage = "Menu bar space is unavailable for this display setup. Your icons remain visible."
        }
        divider?.length = hidden ? lengths[0] : 16
        divider?.button?.title = hidden ? "" : "│"
        let image = NSImage(systemSymbolName: hidden ? "chevron.left" : "chevron.right", accessibilityDescription: hidden ? "Reveal menu bar icons" : "Hide menu bar icons")
        image?.isTemplate = true
        self.separateToggle?.button?.image = image
        self.separateToggle?.button?.toolTip = hidden ? "Reveal menu bar icons" : "Hide menu bar icons"
        if hidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.layoutEpoch == epoch,
                          let controller = self.controller, controller.isRunning, controller.hidden else { return }
                    let ready = self.recoveryIsReachable(requiresToggle: separateToggle)
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
        let visible = modern || controller?.showSeparateToggle == true
        let item = NSStatusBar.system.statusItem(withLength: visible ? 24 : 0)
        item.autosaveName = modern ? "DropShelf.Organizer.Toggle.NativeV3" : "DropShelf.Organizer.Toggle"
        item.button?.setAccessibilityIdentifier(controlIDs.arrow)
        item.isVisible = visible
        item.button?.target = controller
        item.button?.action = #selector(MenuBarOrganizerController.separateToggleAction)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        separateToggle = item
    }
    func registerShortcut(_ shortcut: MenuBarShortcut) -> Bool {
        guard hidingUnavailableReason == nil, handler != nil, !conflictingOrganizerRunning else { return false }
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
        if modern && !NSMenu.menuBarVisible() { return false }
        let point = NSEvent.mouseLocation
        let nearMenu = NSScreen.screens.contains { $0.frame.contains(point) && point.y > $0.frame.maxY - 80 }
        return !nearMenu && NSEvent.pressedMouseButtons == 0
    }
}
