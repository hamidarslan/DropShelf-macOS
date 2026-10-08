import Foundation
import AppKit
import ApplicationServices

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
    checks += 1
}

let process = AutoQuitProcess(pid: 123, bundleIdentifier: "test.desktop", launchDate: Date(timeIntervalSince1970: 10))
var policy = AutoQuitDecisionState()
check(policy.closed(window: 1) == nil, "a no-window launch never arms quitting")
policy.observe(.known([1, 2]))
check(policy.closed(window: 1) == nil, "closing one of two windows does not quit")
let token = policy.closed(window: 2)!
check(!policy.consume(token: token, snapshot: .uncertain), "uncertain AX data prevents quitting")
policy.observe(.known([3]))
let second = policy.closed(window: 3)!
check(policy.consume(token: second, snapshot: .known([])), "last verified window qualifies")
check(!policy.consume(token: second, snapshot: .known([])), "each close permits only one request")
policy.observe(.known([4]))
let third = policy.closed(window: 4)!
policy.observe(.known([5]))
check(!policy.consume(token: third, snapshot: .known([])), "new windows cancel a pending close")
check(policy.closed(window: 999) == nil, "stale or unrelated destruction is ignored")
policy.observe(.uncertain)
let afterUncertainty = policy.closed(window: 5)!
check(!policy.consume(token: afterUncertainty, snapshot: .uncertain), "genuine close after uncertainty still requires a fresh successful check")
policy.observe(.known([6]))
let fourth = policy.closed(window: 6)!
check(!policy.consume(token: fourth, snapshot: .known([7])), "fresh window at deadline cancels quitting")
check(AutoQuitProtection.isProtected(bundleIdentifier: "com.apple.finder", ownIdentifier: "com.dropshelf.macos"), "Finder is protected")
check(AutoQuitProtection.isProtected(bundleIdentifier: "com.apple.dock", ownIdentifier: "com.dropshelf.macos"), "Dock is protected")
check(AutoQuitProtection.isProtected(bundleIdentifier: "com.apple.loginwindow", ownIdentifier: "com.dropshelf.macos"), "login process is protected")
check(AutoQuitProtection.isProtected(bundleIdentifier: "com.dropshelf.macos", ownIdentifier: "com.dropshelf.macos"), "DropShelf is protected")
check(!AutoQuitProtection.isProtected(bundleIdentifier: "test.desktop", ownIdentifier: "com.dropshelf.macos"), "regular desktop app is eligible")
var dialogPolicy = AutoQuitDecisionState()
dialogPolicy.observe(.known([30], eligible: []))
check(dialogPolicy.closed(window: 30) == nil, "closing a cancellation dialog never arms another quit")
dialogPolicy.observe(.known([31, 32], eligible: [31]))
check(dialogPolicy.closed(window: 31) == nil, "remaining dialog blocks a document close")
check(dialogPolicy.closed(window: 32) == nil, "closing the remaining dialog does not become a document close")
check(process.matches(pid: 123, bundleIdentifier: "test.desktop", launchDate: process.launchDate), "exact lifetime identity matches")
check(!process.matches(pid: 123, bundleIdentifier: "test.desktop", launchDate: Date(timeIntervalSince1970: 20)), "old termination cannot match a replacement lifetime")
check(!process.matches(pid: 123, bundleIdentifier: "test.desktop", launchDate: nil), "missing lifetime identity is uncertain")
check(AutoQuitAttachmentRetry.delay(after: 0) == 0.5, "initial readiness failure retries after half a second")
check(AutoQuitAttachmentRetry.delay(after: 1) == 1, "second readiness retry backs off")
check(AutoQuitAttachmentRetry.delay(after: 2) == 2, "last readiness retry backs off")
check(AutoQuitAttachmentRetry.delay(after: 3) == nil, "registration retries are bounded")
check(AutoQuitAttachmentRetry.delay(after: -1) == nil, "invalid readiness attempt does not retry")
check(AutoQuitStaleWindowPolicy.mayRetireDialog(closeEligible: false, validity: .invalid), "disposed dialog can be retired without a close event")
check(!AutoQuitStaleWindowPolicy.mayRetireDialog(closeEligible: true, validity: .invalid), "absent genuine windows remain protected")
check(!AutoQuitStaleWindowPolicy.mayRetireDialog(closeEligible: false, validity: .valid), "valid absent dialog remains a blocker")
check(!AutoQuitStaleWindowPolicy.mayRetireDialog(closeEligible: false, validity: .uncertain), "uncertain absent dialog remains a blocker")

let axApp = AXUIElementCreateApplication(123)
let axWindow = AXUIElementCreateApplication(124)
let windowArray = [axWindow] as CFArray
check(AutoQuitWindowReader.windows(of: axApp, query: { _, _ in (.cannotComplete, nil) }) == nil, "AX errors never mean zero windows")
check(AutoQuitWindowReader.windows(of: axApp, query: { _, _ in (.success, nil) }) == nil, "missing AX value is uncertain")
check(AutoQuitWindowReader.windows(of: axApp, query: { _, _ in (.success, "wrong type" as CFString) }) == nil, "wrong window-list type is uncertain")
check(AutoQuitWindowReader.windows(of: axApp, query: { _, _ in (.success, ["not a window"] as CFArray) }) == nil, "non-element list contents are uncertain")
check(AutoQuitWindowReader.windows(of: axApp, query: { _, attribute in
    attribute as String == kAXWindowsAttribute ? (.success, windowArray) : (.success, kAXButtonRole as CFString)
}) == nil, "unexpected element role prevents quitting")
check(AutoQuitWindowReader.windows(of: axApp, query: { _, attribute in
    attribute as String == kAXWindowsAttribute ? (.success, windowArray) : (.cannotComplete, nil)
}) == nil, "failed window-role query prevents quitting")
check(AutoQuitWindowReader.windows(of: axApp, query: { _, attribute in
    attribute as String == kAXWindowsAttribute ? (.success, [axWindow, axWindow] as CFArray) : (.success, kAXWindowRole as CFString)
}) == nil, "duplicate AX windows are uncertain")
check(AutoQuitWindowReader.windows(of: axApp, query: { _, attribute in
    if attribute as String == kAXWindowsAttribute { return (.success, windowArray) }
    if attribute as String == kAXSubroleAttribute { return (.success, kAXStandardWindowSubrole as CFString) }
    return (.success, kAXWindowRole as CFString)
})?.count == 1, "valid windows remain counted without filtering visibility")
let dialogWindow = AutoQuitWindowReader.windows(of: axApp, query: { _, attribute in
    if attribute as String == kAXWindowsAttribute { return (.success, windowArray) }
    if attribute as String == kAXSubroleAttribute { return (.success, kAXDialogSubrole as CFString) }
    return (.success, kAXWindowRole as CFString)
})
check(dialogWindow?.count == 1 && dialogWindow?.first?.closeEligible == false, "AX dialogs are counted as blockers without becoming eligible closes")
check(AutoQuitWindowReader.windows(of: axApp, query: { _, attribute in
    if attribute as String == kAXWindowsAttribute { return (.success, windowArray) }
    if attribute as String == kAXSubroleAttribute { return (.noValue, nil) }
    return (.success, kAXWindowRole as CFString)
}) == nil, "missing window classification is uncertain")
check(AutoQuitWindowReader.windows(of: axApp, query: { _, _ in (.success, [] as CFArray) })?.isEmpty == true, "successful typed empty list is distinguished from errors")
let excessiveWindows = (200..<329).map { AXUIElementCreateApplication(Int32($0)) } as CFArray
check(AutoQuitWindowReader.windows(of: axApp, query: { _, attribute in
    attribute as String == kAXWindowsAttribute ? (.success, excessiveWindows) : (.success, kAXWindowRole as CFString)
}) == nil, "oversized AX window lists fail closed")

@MainActor final class FakeRuntime: AutoQuitRuntime {
    var permissionGranted = true
    var startCount = 0
    var stopCount = 0
    var samples: [AutoQuitProcess: AutoQuitWindowSnapshot] = [:]
    var quitRequests: [AutoQuitProcess] = []
    var acceptsQuit = true
    var delayedSnapshot: (@MainActor (AutoQuitWindowSnapshot) -> Void)?
    var holdSnapshot = false
    func start(controller: AutoQuitController) { startCount += 1 }
    func stop() { stopCount += 1 }
    func snapshot(for process: AutoQuitProcess, completion: @escaping @MainActor (AutoQuitWindowSnapshot) -> Void) {
        if holdSnapshot { delayedSnapshot = completion }
        else { completion(samples[process] ?? .uncertain) }
    }
    func requestQuit(_ process: AutoQuitProcess) -> Bool {
        quitRequests.append(process)
        return acceptsQuit
    }
}

@MainActor final class Scheduled {
    var canceled = false
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func fire(evenIfCanceled: Bool = false) { if !canceled || evenIfCanceled { action() } }
}

@MainActor func controllerChecks() {
    let suite = "DropShelf.AutoQuit.Tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let runtime = FakeRuntime()
    var scheduled: [Scheduled] = []
    let controller = AutoQuitController(defaults: defaults, runtime: runtime, ownIdentifier: "com.dropshelf.macos") { delay, action in
        check(delay == 1, "settling delay is exactly one second")
        let entry = Scheduled(action)
        scheduled.append(entry)
        return AutoQuitTask { entry.canceled = true }
    }
    controller.start()
    check(!controller.enabled && !controller.isRunning && runtime.startCount == 0, "off by default")
    controller.observe(process, snapshot: .known([1]))
    controller.windowClosed(process, window: 1)
    check(scheduled.isEmpty, "disabled controller never schedules")
    controller.setEnabled(true)
    check(controller.enabled && controller.isRunning && runtime.startCount == 1, "enabled controller starts runtime")
    controller.observe(process, snapshot: .known([]))
    check(scheduled.isEmpty, "baseline with zero windows never quits")
    controller.observe(process, snapshot: .known([1, 2]))
    controller.windowClosed(process, window: 1)
    check(scheduled.isEmpty, "remaining window prevents scheduling")
    controller.windowClosed(process, window: 2)
    check(scheduled.count == 1, "last observed close schedules once")
    runtime.samples[process] = .known([])
    scheduled.last!.fire()
    check(runtime.quitRequests == [process], "verified empty state sends normal quit request")
    scheduled.last!.fire(evenIfCanceled: true)
    check(runtime.quitRequests.count == 1, "repeated timer firing does not retry")

    controller.observe(process, snapshot: .known([3]))
    controller.windowClosed(process, window: 3)
    let stale = scheduled.last!
    controller.setKeepRunning(true, bundleIdentifier: process.bundleIdentifier)
    stale.fire(evenIfCanceled: true)
    check(runtime.quitRequests.count == 1, "exception change cancels pending quit")
    check(controller.keepRunning.contains(process.bundleIdentifier), "exception persisted")
    controller.observe(process, snapshot: .known([4]))
    controller.windowClosed(process, window: 4)
    check(scheduled.last === stale, "excluded app does not schedule")
    controller.setKeepRunning(false, bundleIdentifier: process.bundleIdentifier)
    controller.observe(process, snapshot: .known([5]))
    controller.windowClosed(process, window: 5)
    let disabled = scheduled.last!
    controller.setEnabled(false)
    disabled.fire(evenIfCanceled: true)
    check(runtime.quitRequests.count == 1, "switching off cancels pending work")

    controller.setEnabled(true)
    controller.observe(process, snapshot: .known([6]))
    controller.windowClosed(process, window: 6)
    runtime.permissionGranted = false
    scheduled.last!.fire()
    check(runtime.quitRequests.count == 1, "permission loss prevents termination")
    controller.refreshPermission()
    check(!controller.isRunning, "permission loss stops observers")
    runtime.permissionGranted = true
    controller.refreshPermission()
    check(controller.isRunning, "restored permission rebuilds baseline")

    controller.observe(process, snapshot: .known([7]))
    controller.windowClosed(process, window: 7)
    runtime.samples[process] = .known([8])
    scheduled.last!.fire()
    check(runtime.quitRequests.count == 1, "new window before deadline prevents termination")
    controller.observe(process, snapshot: .known([9]))
    controller.windowClosed(process, window: 9)
    runtime.samples[process] = .uncertain
    scheduled.last!.fire()
    check(runtime.quitRequests.count == 1, "failed query prevents termination")

    controller.observe(process, snapshot: .known([10]))
    controller.windowClosed(process, window: 10)
    runtime.holdSnapshot = true
    scheduled.last!.fire()
    controller.setEnabled(false)
    runtime.delayedSnapshot?(.known([]))
    check(runtime.quitRequests.count == 1, "disable while query is in flight prevents termination")
    runtime.holdSnapshot = false

    controller.setEnabled(true)
    controller.observe(process, snapshot: .known([20]))
    controller.windowClosed(process, window: 20)
    runtime.holdSnapshot = true
    scheduled.last!.fire()
    let oldReply = runtime.delayedSnapshot!
    controller.observe(process, snapshot: .known([21]))
    controller.windowClosed(process, window: 21)
    let freshClose = scheduled.last!
    oldReply(.known([]))
    check(!freshClose.canceled, "an old snapshot reply cannot cancel a newer close")
    runtime.holdSnapshot = false
    runtime.samples[process] = .known([])
    freshClose.fire()
    check(runtime.quitRequests.count == 2, "newer close still receives its own request")
    runtime.quitRequests.removeLast()
    controller.setEnabled(true)
    controller.observe(process, snapshot: .known([11]))
    controller.windowClosed(process, window: 11)
    runtime.holdSnapshot = true
    scheduled.last!.fire()
    controller.observe(process, snapshot: .known([12]))
    runtime.delayedSnapshot?(.known([]))
    check(runtime.quitRequests.count == 1, "window creation during in-flight query invalidates old close")
    runtime.holdSnapshot = false

    controller.observe(process, snapshot: .known([40]))
    controller.windowClosed(process, window: 40)
    let beforeCreation = scheduled.last!
    controller.windowCreated(process)
    controller.observe(process, snapshot: .known([]))
    runtime.samples[process] = .known([])
    beforeCreation.fire(evenIfCanceled: true)
    check(runtime.quitRequests.count == 1, "creation notification cancels even with stale empty reads")
    controller.observe(process, snapshot: .known([41], eligible: []))
    controller.windowClosed(process, window: 41)
    check(scheduled.last === beforeCreation, "quit-cancellation dialog does not schedule a retry")
    controller.observe(process, snapshot: .known([42]))
    let beforeReordered = scheduled.count
    controller.windowCreated(process)
    controller.windowClosed(process, window: 42)
    controller.observe(process, snapshot: .known([]))
    check(scheduled.count == beforeReordered, "queued old destruction cannot arm after immediate creation invalidation")

    controller.observe(process, snapshot: .known([13]))
    controller.windowClosed(process, window: 13)
    let oldProcessTimer = scheduled.last!
    controller.processTerminated(process)
    let reused = AutoQuitProcess(pid: process.pid, bundleIdentifier: process.bundleIdentifier, launchDate: Date(timeIntervalSince1970: 20))
    controller.observe(reused, snapshot: .known([14]))
    oldProcessTimer.fire(evenIfCanceled: true)
    check(runtime.quitRequests.count == 1, "PID reuse cannot receive a stale quit")

    let finder = AutoQuitProcess(pid: 90, bundleIdentifier: "com.apple.finder", launchDate: Date())
    controller.observe(finder, snapshot: .known([1]))
    let previousCount = scheduled.count
    controller.windowClosed(finder, window: 1)
    check(scheduled.count == previousCount, "protected app never schedules")

    runtime.samples[reused] = .known([])
    runtime.acceptsQuit = false
    controller.windowClosed(reused, window: 14)
    scheduled.last!.fire()
    let rejectedCount = runtime.quitRequests.count
    scheduled.last!.fire(evenIfCanceled: true)
    controller.windowClosed(reused, window: 14)
    check(runtime.quitRequests.count == rejectedCount, "refused quit is not retried for the same close")
    runtime.acceptsQuit = true
    controller.observe(reused, snapshot: .known([15]))
    controller.windowClosed(reused, window: 15)
    scheduled.last!.fire()
    check(runtime.quitRequests.count == rejectedCount + 1, "a new window-close cycle permits another request")
    controller.observe(reused, snapshot: .known([60, 61]))
    let beforeSpace = scheduled.count
    controller.cancelPendingDecisions()
    controller.windowClosed(reused, window: 61)
    check(scheduled.count == beforeSpace, "Space change keeps the remembered other-Space window")
    controller.observe(reused, snapshot: .uncertain)
    controller.windowClosed(reused, window: 61)
    check(scheduled.count == beforeSpace, "partial Space window reads prevent quitting")
    controller.observe(reused, snapshot: .known([16]))
    controller.windowClosed(reused, window: 16)
    let beforeSleep = scheduled.last!
    let beforeSleepGeneration = controller.eventGeneration
    controller.cancelPendingDecisions()
    beforeSleep.fire(evenIfCanceled: true)
    check(runtime.quitRequests.count == rejectedCount + 1, "sleep or baseline reset cancels pending quit")
    controller.observe(reused, snapshot: .known([17]))
    let beforeDelayedSleepEvent = scheduled.count
    controller.windowClosed(reused, window: 17, eventGeneration: beforeSleepGeneration)
    check(scheduled.count == beforeDelayedSleepEvent, "pre-sleep destruction delivered after wake cannot rearm quitting")
    controller.observe(reused, snapshot: .known([]))
    check(runtime.quitRequests.count == rejectedCount + 1, "wake baseline never treats missing windows as closure")
    controller.observe(reused, snapshot: .known([18]))
    controller.observe(reused, snapshot: .uncertain)
    runtime.samples[reused] = .known([])
    controller.windowClosed(reused, window: 18)
    scheduled.last!.fire()
    check(runtime.quitRequests.count == rejectedCount + 2, "focus read before actual destruction can recover with fresh empty verification")
    controller.setKeepRunning(true, bundleIdentifier: "test.persisted")
    controller.enableFromSettings()
    check(controller.hasReviewedWindowMonitoring, "first Settings enable records the visible permission explanation")
    controller.shutdown()
    check(!controller.isRunning, "shutdown tears down observers")
    let restored = AutoQuitController(defaults: defaults, runtime: FakeRuntime(), ownIdentifier: "com.dropshelf.macos")
    check(restored.enabled && restored.keepRunning.contains("test.persisted"), "settings survive controller recreation")
    check(restored.hasReviewedWindowMonitoring, "window-monitoring explanation acknowledgement persists")
    print("All \(checks) Auto Quit checks passed")
}

MainActor.assumeIsolated { controllerChecks() }
