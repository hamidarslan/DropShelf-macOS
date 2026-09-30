import AppKit
import Carbon

func check(_ condition: Bool, _ label: String) {
    precondition(condition, label)
    print("PASS: \(label)")
}

@MainActor final class TestRuntime: MenuBarOrganizerRuntime {
    var starts = 0
    var stops = 0
    var layouts: [Bool] = []
    var activeShortcut: MenuBarShortcut?
    var rejectShortcut = false
    var canHide = true
    var acceptLayout = true
    var displaySignature = "first"
    var conflictMessage = ""
    var requiresVisibilityConfirmation = false
    var allowsVisibilityTrial = true
    var platformSignature = "27.0"
    var conflictingOrganizerRunning = false
    var quitRequests = 0
    var quitAccepted = true
    func quitConflictingOrganizer() -> Bool { quitRequests += 1; return quitAccepted }
    func start(anchor: NSStatusItem, controller: MenuBarOrganizerController) { starts += 1 }
    func stop() { stops += 1; activeShortcut = nil }
    func apply(hidden: Bool, separateToggle: Bool) -> Bool { layouts.append(hidden); return hidden && acceptLayout }
    func registerShortcut(_ shortcut: MenuBarShortcut) -> Bool {
        guard !rejectShortcut else { return false }
        activeShortcut = shortcut
        return true
    }
    func unregisterShortcut() { activeShortcut = nil }
    func allowsHiding() -> Bool { canHide }
}

@MainActor final class TestScheduler {
    struct Entry { let seconds: Double; let action: @MainActor () -> Void }
    var entries: [Entry] = []
    func schedule(_ seconds: Double, _ action: @escaping @MainActor () -> Void) -> MenuBarOrganizerTask {
        entries.append(Entry(seconds: seconds, action: action))
        return MenuBarOrganizerTask(cancel: {})
    }
    func fireLast() { entries.last!.action() }
}

@MainActor func runTests() async {
_ = NSApplication.shared
let suite = "DropShelf.Organizer.Tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let runtime = TestRuntime()
let scheduler = TestScheduler()
var now = Date(timeIntervalSince1970: 1_000)
let controller = MenuBarOrganizerController(defaults: defaults, runtime: runtime,
    now: { now }, schedule: scheduler.schedule)
check(!controller.enabled && !controller.isRunning, "fresh organizer is opt-in")
check(controller.autoHide && controller.delay == 10 && controller.startHidden,
      "fresh preferences support automatic startup hiding")
controller.delay = .nan
check(controller.delay == 10 && defaults.double(forKey: "organizer.delay") == 10,
      "invalid delay cannot create an invalid timer or preference")
controller.delay = 30
controller.showSeparateToggle = true
controller.autoHide = false
let anchor = NSStatusBar.system.statusItem(withLength: 0)
defer { NSStatusBar.system.removeStatusItem(anchor) }
anchor.button?.title = "Recovery"
let originalAction = anchor.button?.action
var setupRequests = 0
controller.configure(anchor: anchor) { setupRequests += 1 }
check(runtime.starts == 0, "configuration never starts a disabled organizer")
controller.setEnabled(true)
check(controller.isRunning && !controller.hidden && setupRequests == 1,
      "first enable starts revealed and requests setup")
check(defaults.bool(forKey: "organizer.enabled"), "enabled preference persists immediately")
controller.configure(anchor: anchor) { setupRequests += 1 }
controller.setEnabled(true)
check(runtime.starts == 1 && setupRequests == 1, "repeated configuration and enable create no duplicate resources")
check(anchor.button?.title == "Recovery" && anchor.button?.action == originalAction,
      "organizer preserves the recovery anchor")
controller.autoHide = true
check(scheduler.entries.isEmpty, "first setup withholds automatic hiding")
controller.hide()
check(controller.hidden, "setup allows explicit hiding")
let layoutsAfterHiding = runtime.layouts.count
runtime.acceptLayout = false
controller.hide()
check(controller.hidden && runtime.layouts.count == layoutsAfterHiding,
      "repeated hide does not recheck an expanded divider or reveal the icons")
runtime.acceptLayout = true
controller.reveal()
controller.beginArranging()
controller.completeSetup()
check(controller.hasCompletedSetup && !controller.isArranging && !controller.hidden,
      "completing setup persists and releases arrangement")
check(defaults.bool(forKey: "organizer.hasCompletedSetup"), "setup completion survives relaunch")
check(scheduler.entries.last?.seconds == 30, "automatic hiding follows the chosen delay")
controller.setMenuOpen(true)
scheduler.fireLast()
check(!controller.hidden, "an open menu holds icons visible")
controller.setMenuOpen(false)
runtime.canHide = false
scheduler.fireLast()
check(!controller.hidden, "held mouse or menu-area pointer postpones hiding")
runtime.canHide = true
scheduler.fireLast()
check(controller.hidden, "idle icons hide after interaction ends")
runtime.acceptLayout = false
controller.reveal(); controller.hide()
check(!controller.hidden, "refused layout reports revealed state")
runtime.acceptLayout = true
controller.pauseHiding(seconds: 300)
check(controller.isPaused && !controller.hidden && controller.enabled && controller.autoHide,
      "pause reveals without changing enabled or automatic preference")
now = now.addingTimeInterval(301)
controller.refreshPause()
check(!controller.isPaused, "timed pause expires after sleep using wall clock")
controller.pauseHiding(seconds: nil)
now = now.addingTimeInterval(100_000)
controller.refreshPause()
check(controller.isPaused, "until-resumed pause survives elapsed time")
controller.hide()
check(controller.hidden && !controller.isPaused, "explicit hide ends pause")
let queuedBeforeArranging = scheduler.entries.last!.action
controller.beginArranging()
queuedBeforeArranging()
check(!controller.hidden && controller.isArranging,
      "queued automatic hiding cannot leave arrangement mode")
controller.hide()
check(!controller.hidden && controller.isArranging, "arrangement holds icons visible even on a hide request")
controller.toggleHiddenItems()
check(controller.hidden && !controller.isArranging,
      "manual arrow or shortcut ends arrangement and hides icons")
controller.toggleHiddenItems()
check(!controller.hidden && !controller.isArranging,
      "manual arrow reveals icons again after leaving arrangement")
controller.endArranging()
controller.reveal()
let stale = scheduler.entries.last!.action
controller.shutdown()
check(controller.enabled && !controller.isRunning && !controller.hidden, "shutdown clears resources and retains enabled preference")
controller.shutdown()
check(runtime.stops == 1, "shutdown is idempotent")
stale()
check(!controller.isRunning && !controller.hidden && runtime.starts == 1,
      "delayed callbacks cannot restart a stopped organizer")
controller.configure(anchor: anchor) {}
check(controller.isRunning && runtime.starts == 2, "persisted enabled organizer starts when configured again")
check(scheduler.entries.last?.seconds == 15, "relaunch waits the safe startup delay")
stale()
check(controller.isRunning && !controller.hidden && runtime.starts == 2,
      "old lifetime callback cannot hide a newly activated organizer")
controller.delay = 5
controller.refreshPause()
check(scheduler.entries.last!.seconds >= 15, "activation refresh cannot shorten the startup grace period")
controller.delay = 30
controller.autoHide = false
let pendingStartup = scheduler.entries.last!.action
for value in [false, true, false, true] { controller.showSeparateToggle = value }
check(controller.isRunning && !controller.hidden && runtime.starts == 2,
      "separate toggle changes leave the running lifecycle and anchor intact")
controller.startHidden = false
pendingStartup()
check(!controller.hidden, "turning off startup hiding cancels its pending request")
controller.autoHide = true
controller.startHidden = true
let replacement = MenuBarShortcut(keyCode: 8, modifiers: MenuBarShortcut.control | MenuBarShortcut.option, label: "C")
controller.setShortcut(replacement)
check(controller.shortcut == replacement && controller.shortcutAvailable, "valid replacement shortcut activates")
runtime.rejectShortcut = true
controller.setShortcut(.standard)
check(controller.shortcut == replacement && runtime.activeShortcut == replacement,
      "shortcut registration failure retains the active previous choice")
controller.setEnabled(false)
check(!controller.enabled && !controller.isRunning && runtime.stops == 2 && !controller.shortcutAvailable,
      "disabling immediately releases owned resources")
check(controller.delay == 30 && controller.autoHide && controller.showSeparateToggle,
      "disabling retains other settings")
stale()
controller.toggleHiddenItems()
controller.pauseHiding(seconds: nil)
controller.beginArranging()
check(!controller.hidden && !controller.isPaused && !controller.isArranging,
      "disabled organizer ignores all layout and pause actions")
let disabledMenu = controller.makeContextMenuItems()
check(disabledMenu.count == 2 && disabledMenu.allSatisfy { !$0.isSeparatorItem && $0.target === controller },
      "disabled context menu owns only enable and settings actions")
check(disabledMenu[0].state == .off, "context menu reflects persisted disabled state")
check(NSApp.sendAction(disabledMenu[0].action!, to: disabledMenu[0].target, from: disabledMenu[0]) && controller.enabled,
      "context menu enable action activates the controller")
let enabledMenu = controller.makeContextMenuItems()
check(enabledMenu[0].state == .on && enabledMenu.allSatisfy { $0.target === controller },
      "enabled context menu reflects state and retains own targets")
let timedPause = enabledMenu.first { $0.tag == 300 }!
check(NSApp.sendAction(timedPause.action!, to: timedPause.target, from: timedPause) && controller.isPaused && !controller.hidden,
      "context menu timed pause reveals icons")
controller.recordingShortcut = true
controller.cancelShortcutRecording()
check(!controller.recordingShortcut && controller.shortcut == replacement, "cancelled shortcut recording retains the active preference")
controller.disableShortcut()
check(!controller.shortcutEnabled && !controller.shortcutAvailable && !defaults.bool(forKey: "organizer.shortcutEnabled"),
      "shortcut disabling unregisters and persists off")
controller.setEnabled(false)
let persisted = MenuBarOrganizerController(defaults: defaults, runtime: TestRuntime(), now: { now }, schedule: scheduler.schedule)
check(!persisted.enabled && persisted.delay == 30 && persisted.shortcut == replacement,
      "off state and customized settings survive a fresh controller")
check(!MenuBarShortcut(keyCode: 16, modifiers: MenuBarShortcut.command | MenuBarShortcut.shift, label: "Y").isValid,
      "shelf shortcut Command Shift Y is reserved")
for candidate in [MenuBarShortcut(keyCode: 53, modifiers: MenuBarShortcut.control, label: "Esc"),
                  MenuBarShortcut(keyCode: 4, modifiers: MenuBarShortcut.option, label: "H"),
                  MenuBarShortcut(keyCode: 4, modifiers: MenuBarShortcut.control, label: "\n"),
                  MenuBarShortcut(keyCode: 200, modifiers: MenuBarShortcut.control, label: "H")] {
    check(!candidate.isValid, "invalid focused shortcut is rejected")
}
check(MenuBarShortcut.standard.display == "⌃⌥H", "shortcut display reflects Carbon modifiers")
check(MenuBarSpacerLayout.lengths(displays: [MenuBarDisplayWidth(width: 1710, usableRightWidth: 762.5)], modern: true) == [507, 507],
      "actual notched display uses two segments below its reported discard cliff")
check(MenuBarSpacerLayout.lengths(displays: [MenuBarDisplayWidth(width: 1512, usableRightWidth: 663.5)], modern: true) == [433, 433],
      "smaller notched display preserves both cliff margin and status-area coverage")
check(MenuBarSpacerLayout.lengths(displays: [MenuBarDisplayWidth(width: 2056)], modern: true) == [964, 964, 964],
      "non-notched display uses half-width cliff and enough bounded segments")
check(MenuBarSpacerLayout.lengths(displays: [MenuBarDisplayWidth(width: 3480)], modern: true) == [1676, 1676, 1676],
      "wide non-notched display receives complete coverage")
let mixedDisplays = [MenuBarDisplayWidth(width: 1710, usableRightWidth: 762.5), MenuBarDisplayWidth(width: 7680)]
let mixedLengths = MenuBarSpacerLayout.lengths(displays: mixedDisplays, modern: true)
check(mixedLengths == Array(repeating: 507, count: 16),
      "notched and 8K display pair uses sixteen complete bounded segments")
check(MenuBarSpacerLayout.lengths(displays: [MenuBarDisplayWidth(width: 1710, usableRightWidth: 762.5), MenuBarDisplayWidth(width: 3840)], modern: true) == Array(repeating: 507, count: 8),
      "mixed display calculation keeps right-area widths paired to the correct full display")
for invalid in [MenuBarDisplayWidth(width: .nan), MenuBarDisplayWidth(width: .infinity),
                MenuBarDisplayWidth(width: 0), MenuBarDisplayWidth(width: -1),
                MenuBarDisplayWidth(width: 1710, usableRightWidth: 0),
                MenuBarDisplayWidth(width: 1710, usableRightWidth: 1800),
                MenuBarDisplayWidth(width: 1710, usableRightWidth: .nan),
                MenuBarDisplayWidth(width: 1710, usableRightWidth: .infinity)] {
    check(MenuBarSpacerLayout.lengths(displays: [MenuBarDisplayWidth(width: 1710, usableRightWidth: 762.5), invalid], modern: true).isEmpty,
          "invalid paired display refuses the complete modern layout")
}
check(MenuBarSpacerLayout.lengths(displays: [], modern: true).isEmpty,
      "modern geometry never invents an absent screen")
check(MenuBarSpacerLayout.lengths(displays: [MenuBarDisplayWidth(width: 200, usableRightWidth: 100)], modern: true).isEmpty,
      "a unit below forty points refuses hiding instead of crossing the discard cliff")
check(MenuBarSpacerLayout.lengths(displays: [MenuBarDisplayWidth(width: 208)], modern: true) == Array(repeating: 40, count: 6),
      "minimum safe forty-point unit covers the status area completely")
check(MenuBarSpacerLayout.lengths(displays: [MenuBarDisplayWidth(width: 1710, usableRightWidth: 762.5), MenuBarDisplayWidth(width: 8192)], modern: true).isEmpty,
      "coverage beyond sixteen items refuses instead of silently truncating")
check(MenuBarSpacerLayout.lengths(displays: [MenuBarDisplayWidth(width: .nan), MenuBarDisplayWidth(width: -1)], modern: false) == [2880],
      "legacy geometry preserves a bounded safe fallback")
check(MenuBarSpacerLayout.lengths(displays: [MenuBarDisplayWidth(width: 6000)], modern: false) == [10000],
      "legacy wide-screen displacement remains capped at ten thousand")
check(MenuBarSpacerLayout.lengths(displays: [MenuBarDisplayWidth(width: 1e100)], modern: true).isEmpty,
      "unrepresentable cliff margin refuses extreme geometry")
defaults.set(true, forKey: "organizer.enabled")
let launchRuntime = TestRuntime()
let launched = MenuBarOrganizerController(defaults: defaults, runtime: launchRuntime, now: { now }, schedule: scheduler.schedule)
check(launched.enabled && !launched.isRunning, "persisted enabled state waits for an anchor")
launched.configure(anchor: anchor) {}
check(launched.isRunning && launchRuntime.starts == 1 && !launched.shortcutAvailable,
      "fresh launch starts the enabled organizer and honors shortcut off")
launched.hide()
launchRuntime.displaySignature = "second"
NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
try? await Task.sleep(nanoseconds: 20_000_000)
check(launched.isRunning && !launched.hidden,
      "queued live display and wake notifications run and reveal icons")
let launchPending = scheduler.entries.last!.action
launchRuntime.displaySignature = "third"
NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
launched.setEnabled(false)
let stoppedLayouts = launchRuntime.layouts.count
let stoppedSchedules = scheduler.entries.count
launchPending()
try? await Task.sleep(nanoseconds: 20_000_000)
check(!launched.isRunning && !launched.hidden && launchRuntime.starts == 1 &&
      launchRuntime.layouts.count == stoppedLayouts && scheduler.entries.count == stoppedSchedules,
      "queued old timer and wake/display callbacks stay inert after disable")
launched.setEnabled(true)
launchRuntime.displaySignature = "fourth"
NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
launched.setEnabled(false)
launched.setEnabled(true)
launched.hide()
let restartedLayouts = launchRuntime.layouts.count
let restartedSchedules = scheduler.entries.count
try? await Task.sleep(nanoseconds: 20_000_000)
check(launched.isRunning && launched.hidden && launchRuntime.starts == 3 &&
      launchRuntime.layouts.count == restartedLayouts && scheduler.entries.count == restartedSchedules,
      "queued old wake/display callbacks cannot reveal a newly enabled generation")
launched.setEnabled(false)
let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
let recovery = CGRect(x: 1300, y: 875, width: 24, height: 25)
let boundary = CGRect(x: 1200, y: 875, width: 16, height: 25)
check(MenuBarOrganizerGeometry.canHide(anchor: recovery, divider: boundary, toggle: nil, screen: screen, requiresToggle: false),
      "legacy divider-before-anchor geometry passes the placement guard")
check(!MenuBarOrganizerGeometry.canHide(anchor: recovery, divider: CGRect(x: 1350, y: 875, width: 16, height: 25), toggle: nil, screen: screen, requiresToggle: false),
      "legacy placement guard rejects a divider to the right of the anchor")
check(!MenuBarOrganizerGeometry.canHide(anchor: nil, divider: boundary, toggle: nil, screen: screen, requiresToggle: false),
      "unavailable anchor geometry refuses hiding")
check(!MenuBarOrganizerGeometry.canHide(anchor: recovery, divider: boundary, toggle: CGRect(x: 1100, y: 875, width: 24, height: 25), screen: screen, requiresToggle: true),
      "separate recovery toggle must remain to the right of the divider")
check(!MenuBarOrganizerGeometry.canHide(anchor: CGRect(x: 1300, y: -20, width: 24, height: 25), divider: boundary, toggle: nil, screen: screen, requiresToggle: false),
      "different menu bars refuse displacement")
check(!MenuBarOrganizerGeometry.isReachable(CGRect(x: -50, y: 875, width: 24, height: 25), in: screen),
      "offscreen recovery rectangle fails the legacy reachability check")
let measuredScreen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
let knownIDs = [Int(1) << 32, Int(9) << 32, Int(2) << 32]
check(MenuBarOrganizerGeometry.hasSyntheticHosts(majorVersion: 27, windowIDs: knownIDs, distinctItems: true),
      "exact macOS27 distinct synthetic hosts require manual verification")
for (major, ids, distinct) in [(26, knownIDs, true), (28, knownIDs, true),
                              (27, [1, 9, 2], true), (27, [knownIDs[0],knownIDs[0]], true),
                              (27, knownIDs, false)] {
    check(!MenuBarOrganizerGeometry.hasSyntheticHosts(majorVersion: major, windowIDs: ids, distinctItems: distinct),
          "other OS real-window duplicate and non-distinct hosts retain strict geometry")
}
let legacyAnchorButton = CGRect(x: 954, y: 1079, width: 34, height: 22)
let legacyDividerButton = CGRect(x: 1070, y: 1079, width: 16, height: 22)
let legacyToggleButton = CGRect(x: 956, y: 1077, width: 24, height: 27)
check(!MenuBarOrganizerGeometry.canHide(anchor: legacyAnchorButton, divider: legacyDividerButton,
      toggle: legacyToggleButton, screen: measuredScreen, requiresToggle: true),
      "legacy strict geometry rejects a divider to the right")
let confirmationSuite = suite + ".confirmation"
let confirmationDefaults = UserDefaults(suiteName: confirmationSuite)!
defer { confirmationDefaults.removePersistentDomain(forName: confirmationSuite) }
let confirmationRuntime = TestRuntime()
confirmationRuntime.requiresVisibilityConfirmation = true
let confirmationScheduler = TestScheduler()
var confirmationSettings = 0
let confirmation = MenuBarOrganizerController(defaults: confirmationDefaults, runtime: confirmationRuntime,
    now: { now }, schedule: confirmationScheduler.schedule)
confirmation.configure(anchor: anchor) { confirmationSettings += 1 }
confirmation.setEnabled(true)
check(confirmation.requiresVisibilityConfirmation && !confirmation.hasVisibilityTrial && confirmation.isRunning,
      "remote-host capability holds the enabled organizer revealed pending manual verification")
confirmation.completeSetup()
check(!confirmation.hasCompletedSetup && confirmationScheduler.entries.isEmpty,
      "confirmation before a trial cannot start automatic hiding")
confirmationRuntime.acceptLayout = false
confirmation.hide()
check(confirmation.requiresVisibilityConfirmation && !confirmation.hidden && !confirmation.hasVisibilityTrial && confirmation.enabled,
      "refused remote-host request stays pending without recording a trial")
confirmationRuntime.acceptLayout = true
confirmationRuntime.allowsVisibilityTrial = false
confirmation.hide()
check(!confirmation.hidden && !confirmation.hasVisibilityTrial,
      "unconfirmed trial requires the settings recovery window")
confirmationRuntime.allowsVisibilityTrial = true
confirmation.hide()
check(confirmation.hidden && confirmation.hasVisibilityTrial, "accepted remote-host request records a trial awaiting manual verification")
confirmation.rejectVisibilityTrial()
check(!confirmation.hidden && !confirmation.hasVisibilityTrial && confirmation.requiresVisibilityConfirmation,
      "failed post-layout recovery invalidates the trial before confirmation")
confirmation.hide()
confirmationRuntime.requiresVisibilityConfirmation = false
confirmation.refreshVisibilityRequirement()
check(confirmation.requiresVisibilityConfirmation && confirmation.hasVisibilityTrial,
      "temporary remote-host capability changes preserve pending manual confirmation and the trial")
confirmationRuntime.requiresVisibilityConfirmation = true
confirmation.reveal(); confirmation.completeSetup()
check(confirmation.hasCompletedSetup && !confirmation.requiresVisibilityConfirmation && !confirmationScheduler.entries.isEmpty,
      "explicit confirmation after trial unlocks automatic hiding")
confirmation.shutdown()
let restoredConfirmation = MenuBarOrganizerController(defaults: confirmationDefaults, runtime: confirmationRuntime,
    now: { now }, schedule: confirmationScheduler.schedule)
restoredConfirmation.configure(anchor: anchor) { confirmationSettings += 1 }
check(!restoredConfirmation.requiresVisibilityConfirmation && restoredConfirmation.hasCompletedSetup,
      "same OS display and toggle context restores manual confirmation")
restoredConfirmation.showSeparateToggle = true
check(restoredConfirmation.requiresVisibilityConfirmation && !restoredConfirmation.hasVisibilityTrial && !restoredConfirmation.hidden,
      "toggle topology changes reveal and invalidate confirmation")
restoredConfirmation.completeSetup()
check(!restoredConfirmation.hasCompletedSetup, "previous generic setup cannot bypass a changed-layout trial")
restoredConfirmation.hide(); restoredConfirmation.reveal(); restoredConfirmation.completeSetup()
confirmationRuntime.displaySignature = "changed-display"
NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
try? await Task.sleep(nanoseconds: 20_000_000)
check(restoredConfirmation.requiresVisibilityConfirmation && !restoredConfirmation.hasVisibilityTrial && !restoredConfirmation.hidden,
      "display topology changes reveal and require confirmation again")
check(confirmationSettings >= 3, "invalidated layouts reopen the recovery settings")
confirmationRuntime.conflictingOrganizerRunning = true
restoredConfirmation.refreshConflictingOrganizerState()
check(restoredConfirmation.conflictingOrganizerRunning && !restoredConfirmation.shortcutAvailable,
      "active organizer conflict never claims a usable shortcut")
restoredConfirmation.quitConflictingOrganizer()
check(confirmationRuntime.quitRequests == 1 && restoredConfirmation.conflictingOrganizerRunning,
      "explicit quit requests graceful termination and waits for observed exit")
check(restoredConfirmation.statusMessage.contains("Waiting for Hidebar to quit"),
      "accepted quit reports waiting rather than successful exit")
confirmationRuntime.quitAccepted = false
restoredConfirmation.quitConflictingOrganizer()
check(restoredConfirmation.statusMessage == "Could not quit Hidebar. Quit it from its menu bar, then return here." &&
      restoredConfirmation.conflictingOrganizerRunning && restoredConfirmation.enabled,
      "declined graceful quit preserves enabled conflict and provides manual recovery")
restoredConfirmation.hide()
check(!restoredConfirmation.hidden, "active organizer conflict refuses even an explicit trial")
restoredConfirmation.shutdown()
confirmationRuntime.conflictingOrganizerRunning = false
confirmationRuntime.platformSignature = "27.1"
let changedOS = MenuBarOrganizerController(defaults: confirmationDefaults, runtime: confirmationRuntime,
    now: { now }, schedule: confirmationScheduler.schedule)
changedOS.configure(anchor: anchor) {}
check(changedOS.requiresVisibilityConfirmation && !changedOS.hasVisibilityTrial,
      "changed OS invalidates the saved visibility confirmation")
changedOS.setEnabled(false)
confirmationRuntime.conflictingOrganizerRunning = true
changedOS.refreshConflictingOrganizerState()
changedOS.quitConflictingOrganizer()
check(confirmationRuntime.quitRequests == 3 && !changedOS.enabled && !changedOS.isRunning,
      "explicit conflict action while off never enables the organizer")
changedOS.shutdown()
let resumeSuite = suite + ".conflict-resume"
let resumeDefaults = UserDefaults(suiteName: resumeSuite)!
defer { resumeDefaults.removePersistentDomain(forName: resumeSuite) }
resumeDefaults.set(true, forKey: "organizer.enabled")
resumeDefaults.set(true, forKey: "organizer.hasCompletedSetup")
resumeDefaults.set(false, forKey: "organizer.startHidden")
let resumeRuntime = TestRuntime()
let resumeScheduler = TestScheduler()
let resumeController = MenuBarOrganizerController(defaults: resumeDefaults, runtime: resumeRuntime,
    now: { now }, schedule: resumeScheduler.schedule)
resumeController.configure(anchor: anchor) {}
resumeRuntime.conflictingOrganizerRunning = true
resumeScheduler.fireLast()
check(!resumeController.hidden && resumeController.conflictingOrganizerRunning && resumeController.enabled,
      "automatic timer during conflict holds the enabled organizer revealed")
let pendingBeforeExit = resumeScheduler.entries.count
resumeRuntime.conflictingOrganizerRunning = false
resumeController.refreshConflictingOrganizerState()
check(resumeScheduler.entries.count > pendingBeforeExit && resumeScheduler.entries.last?.seconds == 10,
      "observed conflict exit resumes the normal automatic hide delay")
resumeScheduler.fireLast()
check(resumeController.hidden, "resumed post-conflict automatic timer hides normally")
resumeController.pauseHiding(seconds: nil)
resumeRuntime.conflictingOrganizerRunning = true
resumeController.refreshConflictingOrganizerState()
let pausedBeforeExit = resumeScheduler.entries.count
resumeRuntime.conflictingOrganizerRunning = false
resumeController.refreshConflictingOrganizerState()
check(resumeController.isPaused && !resumeController.hidden && resumeScheduler.entries.count == pausedBeforeExit,
      "conflict exit respects until-resumed pause")
resumeController.resumeHiding(); resumeController.beginArranging()
resumeRuntime.conflictingOrganizerRunning = true
resumeController.refreshConflictingOrganizerState()
let arrangingBeforeExit = resumeScheduler.entries.count
resumeRuntime.conflictingOrganizerRunning = false
resumeController.refreshConflictingOrganizerState()
check(resumeController.isArranging && !resumeController.hidden && resumeScheduler.entries.count == arrangingBeforeExit,
      "conflict exit respects arrangement hold")
resumeController.endArranging(); resumeController.shutdown()
resumeDefaults.set(false, forKey: "organizer.autoHide")
resumeDefaults.set(true, forKey: "organizer.startHidden")
let startupRuntime = TestRuntime()
let startupScheduler = TestScheduler()
let startupController = MenuBarOrganizerController(defaults: resumeDefaults, runtime: startupRuntime,
    now: { now }, schedule: startupScheduler.schedule)
startupController.configure(anchor: anchor) {}
startupRuntime.conflictingOrganizerRunning = true
now = now.addingTimeInterval(20)
startupScheduler.fireLast()
startupRuntime.conflictingOrganizerRunning = false
startupController.refreshConflictingOrganizerState()
check(startupScheduler.entries.last?.seconds == 15 && !startupController.hidden,
      "pending startup hide receives a fresh safety grace after conflict exit")
startupController.shutdown()
print("PASS: menu bar organizer regression suite")

}
Task { @MainActor in
    await runTests()
    exit(0)
}
RunLoop.main.run()
