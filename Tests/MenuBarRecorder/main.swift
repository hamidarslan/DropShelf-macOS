import AppKit

// Controlled key state exercises the recorder's real AppKit notification binding.
// This fixture does not activate an application or verify foreground window switching.
@MainActor final class ControlledKeyWindow: NSWindow {
    private var keyState = false
    override var isKeyWindow: Bool { keyState }
    override func makeKey() { keyState = true }
    override func resignKey() {
        keyState = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: self)
    }
    override func miniaturize(_ sender: Any?) { resignKey() }
}

func check(_ condition: Bool, _ label: String) {
    precondition(condition, label)
    print("PASS: \(label)")
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let suite = "DropShelf.Recorder.Tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "organizer.enabled")
    defer { defaults.removePersistentDomain(forName: suite) }
    let organizer = MenuBarOrganizerController(defaults: defaults)
    let button = MenuBarShortcutRecorder.RecorderButton(frame: NSRect(x: 20, y: 20, width: 150, height: 28))
    button.organizer = organizer
    button.isEnabled = true

    let window = ControlledKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 100),
        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView!.addSubview(button)
    window.makeKey()
    _ = button.accessibilityPerformPress()
    check(organizer.recordingShortcut && window.firstResponder === button,
          "focused recorder starts in the controlled key window")

    window.resignKey()
    check(window.firstResponder === button && !organizer.recordingShortcut,
          "resign-key notification cancels recording with first responder retained")
    _ = button.accessibilityPerformPress()
    check(!organizer.recordingShortcut, "non-key window cannot start recording")

    window.makeKey()
    _ = button.accessibilityPerformPress()
    precondition(organizer.recordingShortcut)
    window.miniaturize(nil)
    check(!organizer.recordingShortcut, "miniaturization fixture resignation cancels recording")

    window.makeKey()
    _ = button.accessibilityPerformPress()
    precondition(organizer.recordingShortcut)
    button.removeFromSuperview()
    check(!organizer.recordingShortcut, "detaching the recorder cancels recording")

    let replacement = ControlledKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 100),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    replacement.isReleasedWhenClosed = false
    defer { replacement.close() }
    replacement.contentView!.addSubview(button)
    replacement.makeKey()
    _ = button.accessibilityPerformPress()
    precondition(organizer.recordingShortcut)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    check(organizer.recordingShortcut, "moving windows removes the former window observation")
    replacement.resignKey()
    check(!organizer.recordingShortcut, "replacement window cancellation is bound")
    print("All 7 controlled-key recorder lifetime checks passed")
}
