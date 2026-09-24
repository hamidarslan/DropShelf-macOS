import Cocoa
import SwiftUI
import Combine

final class ClipboardDetailWindowController: NSObject, NSWindowDelegate {
    static let shared = ClipboardDetailWindowController()
    private var window: NSWindow?
    private var textView: NSTextView?
    private var observation: AnyCancellable?
    private weak var detailStore: ClipboardStore?
    private var entryID: UUID?

    func show(_ id: UUID, store: ClipboardStore) {
        guard let payload = store.payload(for: id) else { return }
        close()
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = false
        text.isRichText = false
        text.importsGraphics = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.string = payload.displayText
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 440))
        scroll.frame = NSRect(x: 0, y: 44, width: 600, height: 396)
        scroll.autoresizingMask = [.width, .height]
        text.frame = scroll.contentView.bounds
        text.minSize = NSSize(width: 0, height: scroll.contentView.bounds.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        content.addSubview(scroll)
        detailStore = store
        entryID = id
        let button = NSButton(title: "Copy Exact Original", target: self, action: #selector(copyOriginal))
        button.bezelStyle = .rounded
        button.keyEquivalent = "c"
        button.keyEquivalentModifierMask = .command
        button.frame = NSRect(x: 10, y: 4, width: 180, height: 36)
        content.addSubview(button)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Clipboard Text"
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        self.textView = text
        observation = store.$entries.sink { [weak self] entries in
            if !entries.contains(where: { $0.id == id }) { self?.close() }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyOriginal() {
        guard let id = entryID else { return }
        detailStore?.copy(id)
    }

    func close() {
        detailStore = nil
        entryID = nil
        textView?.string = ""
        textView = nil
        observation?.cancel()
        observation = nil
        let oldWindow = window
        window = nil
        oldWindow?.close()
    }
    func windowWillClose(_ notification: Notification) { close() }
}
