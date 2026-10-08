import Cocoa
import SwiftUI

@MainActor public class PreferencesWindowController: NSObject, NSWindowDelegate {
    public static let shared = PreferencesWindowController()
    private var window: NSWindow?
    private let navigation = PreferencesNavigation()

    public func show() {
        present(section: .general)
    }

    public func showMenuBar() {
        MenuBarOrganizerController.shared.setSettingsOpen(true)
        present(section: .menuBar)
    }

    public func showAutoQuit() {
        present(section: .autoQuit)
    }

    private func present(section: PreferencesSection) {
        navigation.selection = section
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: PreferencesRootView(navigation: navigation))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "DropShelf Settings"
        win.isMovableByWindowBackground = false
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        MenuBarOrganizerController.shared.endArranging()
        MenuBarOrganizerController.shared.setSettingsOpen(false)
        MenuBarOrganizerController.shared.cancelShortcutRecording()
        window = nil
    }
}
