import Cocoa
import SwiftUI

public class PreferencesWindowController: NSObject, NSWindowDelegate {
    public static let shared = PreferencesWindowController()
    private var window: NSWindow?

    public func show() {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(onDismiss: { [weak self] in
            self?.window?.close()
        })

        let hostingView = NSHostingView(rootView: settingsView)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "DropShelf Preferences"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
