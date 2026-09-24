import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var clipboard = ClipboardStore.shared
    @ObservedObject var shelf = ShelfStore.shared
    private var palette: ClassicPalette { ClassicPalette(light: shelf.isEffectiveLightMode) }

    var body: some View {
        VStack(spacing: 10) {
            if !clipboard.enabled {
                Spacer(minLength: 10)
                Image(systemName: "doc.on.clipboard").font(.system(size: 28)).foregroundColor(palette.accent)
                Text("Your clipboard, nearby").font(.system(size: 12, weight: .semibold))
                Text("Save copied text and links on this Mac. History stays in memory and expires after \(clipboard.retention.title).")
                    .font(.system(size: 11)).foregroundColor(palette.muted).multilineTextAlignment(.center)
                Button { clipboard.setEnabled(true) } label: {
                    Text("Enable Clipboard History").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(palette.onAccent).frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.accent)).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Text("Known sensitive copies are skipped. Quit, disable or lock clears history.")
                    .font(.system(size: 9)).foregroundColor(palette.muted).multilineTextAlignment(.center)
                Spacer(minLength: 10)
            } else {
                HStack {
                    Text(clipboard.paused ? "Paused" : "Recent copies").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button { clipboard.setPaused(!clipboard.paused) } label: {
                        Image(systemName: clipboard.paused ? "play.fill" : "pause.fill").frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(clipboard.paused ? "Resume clipboard history" : "Pause capture; existing entries still expire")
                }
                Text("Expires after \(clipboard.retention.title), including pins")
                    .font(.system(size: 9)).foregroundColor(palette.muted).frame(maxWidth: .infinity, alignment: .leading)
                if clipboard.entries.isEmpty {
                    Spacer(minLength: 0)
                    Text(clipboard.paused ? "Capture is paused" : "Copy text with ⌘C")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New copies appear here quietly. Your files stay in Files.")
                        .font(.system(size: 10)).foregroundColor(palette.muted).multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(clipboard.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
                if let status = clipboard.status {
                    Text(verbatim: status).font(.system(size: 9)).foregroundColor(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("\(clipboard.entries.count) / 50").font(.system(size: 10)).foregroundColor(palette.muted)
                    Spacer()
                    Button("Clear History") { clipboard.clear() }
                        .font(.system(size: 10)).disabled(clipboard.entries.isEmpty)
                }
            }
        }
        .foregroundColor(palette.text)
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: entry.payload.isURL ? "link" : "text.alignleft").foregroundColor(palette.accent)
                    Text(entry.payload.isURL ? "Link" : "Text").font(.system(size: 9, weight: .semibold))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.payload.byteCount), countStyle: .memory))
                        .font(.system(size: 9)).foregroundColor(palette.muted)
                }
                Text(verbatim: entry.payload.preview.isEmpty ? "Empty text" : entry.payload.preview)
                    .font(.system(size: 11)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .allowsHitTesting(false)
            .overlay(ClipboardDragRepresentable(entryID: entry.id, clipboard: clipboard))
            HStack(spacing: 7) {
                Button { clipboard.copy(entry.id) } label: { Image(systemName: "doc.on.doc").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .help("Copy exact original text")
                Button { ClipboardDetailWindowController.shared.show(entry.id, store: clipboard) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .help("Read the full text")
                Spacer(minLength: 0)
                Button { clipboard.togglePin(entry.id) } label: { Image(systemName: entry.isPinned ? "pin.fill" : "pin").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .foregroundColor(entry.isPinned ? palette.accent : palette.muted).help("Pin until expiry")
                Button { clipboard.remove(entry.id) } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }.help("Remove entry")
            }.buttonStyle(.plain).padding(.horizontal, 6).padding(.bottom, 5)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border))
    }
}

struct ClipboardSettingsSection: View {
    @ObservedObject var clipboard = ClipboardStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clipboard Privacy").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            Toggle("Keep local clipboard history", isOn: Binding(get: { clipboard.enabled }, set: clipboard.setEnabled))
                .toggleStyle(.checkbox)
            Picker("Automatically expire after", selection: Binding(get: { clipboard.retention }, set: clipboard.setRetention)) {
                ForEach(ClipboardRetention.allCases) { value in Text(value.title).tag(value) }
            }.pickerStyle(.menu)
            Text("Text and links stay in memory only. Pins also expire. Disabling, quitting, locking or sleeping clears history.")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Sensitive markers are respected, but apps may copy unmarked passwords. Pause before copying secrets. Saved copies are restored for this Mac only.")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(clipboard.paused ? "Resume Capture" : "Pause Capture") { clipboard.setPaused(!clipboard.paused) }.disabled(!clipboard.enabled)
                Spacer()
                Button("Clear History") { clipboard.clear() }.disabled(clipboard.entries.isEmpty)
            }.font(.system(size: 10))
        }
    }
}

private struct ClipboardDragRepresentable: NSViewRepresentable {
    let entryID: UUID
    let clipboard: ClipboardStore
    func makeNSView(context: Context) -> ClipboardDragView {
        let view = ClipboardDragView()
        configure(view)
        return view
    }
    func updateNSView(_ view: ClipboardDragView, context: Context) { configure(view) }
    private func configure(_ view: ClipboardDragView) {
        view.payloadProvider = { [weak clipboard] in clipboard?.payload(for: entryID) }
        view.copyEntry = { [weak clipboard] in clipboard?.copy(entryID) }
    }
}

private final class ClipboardDragView: NSView, NSDraggingSource {
    var payloadProvider: (() -> ClipboardPayload?)?
    var copyEntry: (() -> Void)?
    private var start: NSPoint?
    private var dragging = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow; dragging = false }
    override func mouseDragged(with event: NSEvent) {
        guard let start = start, !dragging,
              InteractiveCardDragView.shouldBeginDrag(from: start, to: event.locationInWindow),
              let payload = payloadProvider?() else { return }
        dragging = true
        let marker = Data(UUID().uuidString.utf8)
        let items = ClipboardPasteboard.items(payload, marker: marker).map { item -> NSDraggingItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            draggingItem.setDraggingFrame(NSRect(x: 0, y: 0, width: 36, height: 36), contents: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil))
            return draggingItem
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        if start != nil && !dragging { copyEntry?() }
        start = nil; dragging = false
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? [] : .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { start = nil; dragging = false }
}
