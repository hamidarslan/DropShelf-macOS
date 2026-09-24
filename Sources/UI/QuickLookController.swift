import Cocoa
import Quartz

private final class PreviewWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 53 { close() }
        else { super.keyDown(with: event) }
    }
}

public final class QuickLookController: NSObject, NSWindowDelegate {
    public static let shared = QuickLookController()
    private var window: NSPanel?

    public func show(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            ShelfStore.shared.showStatus(message: "File is no longer available")
            return
        }
        window?.close()
        let panel = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        guard let preview = QLPreviewView(frame: panel.contentView!.bounds, style: .normal) else { return }
        preview.autoresizingMask = [.width, .height]
        preview.autostarts = false
        preview.shouldCloseWithWindow = true
        preview.previewItem = url as NSURL
        panel.contentView = preview
        panel.title = url.lastPathComponent
        panel.level = .floating
        // The shelf is nonactivating; previews must survive focus returning to Finder.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
