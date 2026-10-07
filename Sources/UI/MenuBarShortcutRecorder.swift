import AppKit
import Carbon
import SwiftUI

struct MenuBarShortcutRecorder: NSViewRepresentable {
    @ObservedObject var organizer: MenuBarOrganizerController

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.organizer = organizer
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.setAccessibilityLabel("Record menu bar shortcut")
        button.setAccessibilityHelp("Press a key with Control or Command. Escape cancels. Command Shift Y is reserved for the shelf.")
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.title = organizer.recordingShortcut ? "Press keys…" : organizer.shortcutEnabled ? organizer.shortcut.display : "Record shortcut…"
        button.isEnabled = organizer.enabled && organizer.hidingAvailable
        button.toolTip = organizer.recordingShortcut ? "Escape cancels recording" : "Click to change the menu bar shortcut"
        button.setAccessibilityValue(organizer.recordingShortcut ? "Recording" : organizer.shortcutEnabled ? organizer.shortcut.display : "Off")
    }

    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) {
        button.stopObservingWindow()
    }

    @MainActor final class RecorderButton: NSButton {
        weak var organizer: MenuBarOrganizerController?
        private weak var observedWindow: NSWindow?
        override var acceptsFirstResponder: Bool { true }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            stopObservingWindow()
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            observedWindow = window
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                name: NSWindow.didResignKeyNotification, object: window)
        }

        func stopObservingWindow() {
            if let observedWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
            }
            observedWindow = nil
            cancelRecording()
        }

        @objc private func windowResignedKey(_ notification: Notification) {
            cancelRecording()
        }

        private func cancelRecording() {
            if organizer?.recordingShortcut == true { organizer?.cancelShortcutRecording() }
        }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            startRecording()
        }

        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            startRecording()
            return true
        }

        private func startRecording() {
            guard window?.isKeyWindow == true, window?.makeFirstResponder(self) == true else { return }
            organizer?.recordingShortcut = true
        }

        override func resignFirstResponder() -> Bool {
            cancelRecording()
            return super.resignFirstResponder()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard organizer?.recordingShortcut == true, window?.isKeyWindow == true,
                  window?.firstResponder === self else { return false }
            capture(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            if organizer?.recordingShortcut == true, window?.isKeyWindow == true,
               window?.firstResponder === self { capture(event) }
            else if isEnabled && (event.keyCode == 49 || event.keyCode == 36) { startRecording() }
            else { super.keyDown(with: event) }
        }

        private func capture(_ event: NSEvent) {
            guard !event.isARepeat else { return }
            if event.keyCode == 53 { organizer?.cancelShortcutRecording(); return }
            if event.keyCode == 48 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                organizer?.cancelShortcutRecording()
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
                return
            }
            var modifiers: UInt32 = 0
            if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
            if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            let special: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 117: "Forward Del",
                123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
                96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
            let label = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
            organizer?.setShortcut(MenuBarShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label))
        }
    }
}
