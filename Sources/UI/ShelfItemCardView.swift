import SwiftUI
import QuickLook
import Quartz

public struct ShelfItemCardView: View {
    @ObservedObject var item: ShelfItem
    @ObservedObject var store = ShelfStore.shared
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var refined: Bool { store.useRefinedClassic }
    private var palette: ClassicPalette { ClassicPalette(light: isLight) }
    private var accent: Color { refined ? palette.accent : .blue }

    private var isSelected: Bool {
        store.selectedItemIDs.contains(item.id)
    }

    private var isLight: Bool {
        store.isEffectiveLightMode
    }

    public var body: some View {
        ZStack {
            cardBackground

            if refined {
                VStack(spacing: 0) {
                    contentRow
                    Color.clear.frame(height: 35)
                }
                .allowsHitTesting(false)
                dragLayer
                    .overlay(alignment: .bottomTrailing) {
                        cardActionButtons
                            .padding(.horizontal, 10)
                            .padding(.bottom, 7)
                    }
            } else {
                contentRow.allowsHitTesting(false)
                dragLayer
                HStack {
                    Spacer()
                    cardActionButtons
                }
                .padding(.trailing, 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .scaleEffect(refined && isHovering && !reduceMotion ? 1.008 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private var dragLayer: some View {
        InteractiveCardDragRepresentable(
            urlsProvider: {
                if isSelected {
                    return store.allSelectedURLs()
                } else {
                    return item.fileURLs
                }
            },
            previewProvider: { item.thumbnail },
            onClicked: { isCommand, isShift in
                if store.isPeekingFromEdgeTab {
                    store.uncollapse(playSound: false, notify: true)
                }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    if isCommand {
                        store.toggleSelection(id: item.id)
                    } else if isShift {
                        store.selectRange(to: item.id)
                    } else {
                        store.selectOnly(id: item.id)
                    }
                }
            },
            onDragEnded: { operation in
                handleDragOutCompleted(operation: operation)
            }
        )
    }

    private var contentRow: some View {
        HStack(spacing: refined ? 8 : 12) {
            thumbnailView
            infoColumn
            Spacer()
            if !refined {
                Color.clear.frame(width: 76, height: 28)
            }
        }
        .padding(.horizontal, refined ? 10 : 12)
        .padding(.vertical, 8)
    }

    private var thumbnailView: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .cornerRadius(6)
                    .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 2)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                    .frame(width: 44, height: 44)
                    .overlay(
                        AppIconView(size: 28)
                    )
            }

            if item.isStack {
                Text("\(item.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(accent)
                            .shadow(radius: 2)
                    )
                    .offset(x: 4, y: 4)
            }

            if isSelected {
                VStack {
                    HStack {
                        ShelfSymbol(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(accent)
                            .background(Circle().fill(Color.white))
                            .offset(x: -4, y: -4)
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
        .frame(width: 48, height: 48)
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.system(size: refined ? 12 : 13, weight: refined ? .semibold : .medium))
                .foregroundColor(refined ? palette.text : (isLight ? Color.black.opacity(0.88) : .white))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 5) {
                if store.transferMode == .cut {
                    HStack(spacing: 2) {
                        ShelfSymbol(systemName: "scissors")
                            .font(.system(size: 8, weight: .bold))
                        Text("Cut")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                }

                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(refined ? palette.muted : (isLight ? Color.black.opacity(0.6) : Color.white.opacity(0.6)))
                    .lineLimit(1)
            }
        }
    }

    private var cardActionButtons: some View {
        HStack(spacing: 6) {
            let btnFg = refined ? palette.muted : (isLight ? Color.black.opacity(0.8) : Color.white.opacity(0.8))
            let btnBg = refined ? palette.subtle : (isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.12))

            if refined || item.isLocked || isHovering {
                Button(action: {
                    store.toggleLock(item: item)
                }) {
                    BrandIconView(.pin, size: 14)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(item.isLocked ? (refined ? palette.warm : .yellow) : (isLight ? Color.black.opacity(0.6) : Color.white.opacity(0.7)))
                        .frame(width: refined ? 28 : 22, height: refined ? 28 : 22)
                        .contentShape(Rectangle())
                        .background(
                            Circle()
                                .fill(item.isLocked ? (refined ? palette.warm.opacity(0.15) : Color.yellow.opacity(0.25)) : btnBg)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.isLocked ? "Unpin item" : "Pin item")
                .help(item.isLocked ? "Pinned (Won't remove when dragged out)" : "Pin to keep on shelf")
            }

            if refined || isHovering {
                // Specialized Smart Card Action Buttons
                switch item.itemType {
                case .webLink(let url):
                    Button(action: {
                        NSWorkspace.shared.open(url)
                    }) {
                        ShelfSymbol(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                            .foregroundColor(btnFg)
                            .frame(width: refined ? 28 : 22, height: refined ? 28 : 22)
                            .contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: refined ? 7 : 11).fill(btnBg))
                    }
                    .buttonStyle(.plain)
                    .help("Open in Browser")

                case .color(let hex, _):
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hex, forType: .string)
                        store.playSound("Tink")
                        store.showStatus(message: "Copied \(hex)")
                    }) {
                        BrandIconView(.moveCopy, size: 13)
                            .font(.system(size: 10))
                            .foregroundColor(btnFg)
                            .frame(width: refined ? 28 : 22, height: refined ? 28 : 22)
                            .contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: refined ? 7 : 11).fill(btnBg))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy color hex")
                    .help("Copy Color Hex")

                case .textSnippet(let text):
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        store.playSound("Tink")
                        store.showStatus(message: "Copied text snippet")
                    }) {
                        BrandIconView(.moveCopy, size: 13)
                            .font(.system(size: 10))
                            .foregroundColor(btnFg)
                            .frame(width: refined ? 28 : 22, height: refined ? 28 : 22)
                            .contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: refined ? 7 : 11).fill(btnBg))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy text snippet")
                    .help("Copy Text Snippet")

                case .file(let url), .folder(let url):
                    Button(action: {
                        openQuickLook(for: url)
                    }) {
                        ShelfSymbol(systemName: "eye.fill")
                            .font(.system(size: 11))
                            .foregroundColor(btnFg)
                            .frame(width: refined ? 28 : 22, height: refined ? 28 : 22)
                            .contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: refined ? 7 : 11).fill(btnBg))
                    }
                    .buttonStyle(.plain)
                    .help("Quick Look preview (Space)")
                    .accessibilityLabel("Quick Look preview")

                case .stack:
                    Button(action: {
                        store.splitStack(item: item)
                    }) {
                        ShelfSymbol(systemName: "square.split.2x1")
                            .font(.system(size: 10))
                            .foregroundColor(btnFg)
                            .frame(width: refined ? 28 : 22, height: refined ? 28 : 22)
                            .contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: refined ? 7 : 11).fill(btnBg))
                    }
                    .buttonStyle(.plain)
                    .help("Split stack into separate items")

                default:
                    EmptyView()
                }

                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        store.removeItem(id: item.id)
                    }
                }) {
                    ShelfSymbol(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(btnFg)
                        .frame(width: refined ? 28 : 22, height: refined ? 28 : 22)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: refined ? 7 : 11).fill(btnBg))
                }
                .buttonStyle(.plain)
                .help("Remove from shelf (Saved to History)")
            }
        }
    }

    private var fillColor: Color {
        if refined { return isSelected ? palette.selected : (isHovering ? palette.subtle : palette.card) }
        if isSelected {
            return accent.opacity(isLight ? 0.35 : 0.25)
        } else if isHovering {
            return isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.14)
        } else {
            return isLight ? Color.black.opacity(0.04) : Color.white.opacity(0.07)
        }
    }

    private var strokeColor: Color {
        if refined { return isSelected ? palette.accent : (item.isLocked ? palette.warm : palette.border) }
        if isSelected {
            return accent
        } else if item.isLocked {
            return Color.yellow.opacity(0.6)
        } else if isHovering {
            return isLight ? Color.black.opacity(0.18) : Color.white.opacity(0.25)
        } else {
            return isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(strokeColor, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? accent.opacity(refined ? 0.08 : 0.4) : Color.clear, radius: 6)
    }

    private func handleDragOutCompleted(operation: NSDragOperation) {
        guard operation != [] else { return }

        let itemsToRemove = isSelected
            ? store.items.filter { store.selectedItemIDs.contains($0.id) }
            : [item]

        for itm in itemsToRemove where !itm.isLocked {
            store.removeItem(id: itm.id)
        }

        if isSelected {
            store.deselectAll()
        }
    }

    private func openQuickLook(for url: URL) {
        QuickLookController.shared.show(url)
    }
}

// MARK: - Native AppKit Multi-File Drag & Selection Bridge

public struct InteractiveCardDragRepresentable: NSViewRepresentable {
    var urlsProvider: () -> [URL]
    var previewProvider: (() -> NSImage?)?
    var onClicked: (_ isCommand: Bool, _ isShift: Bool) -> Void
    var onDragEnded: (NSDragOperation) -> Void

    public func makeNSView(context: Context) -> InteractiveCardDragView {
        let view = InteractiveCardDragView()
        view.previewProvider = previewProvider
        view.urlsProvider = urlsProvider
        view.onClicked = onClicked
        view.onDragEnded = onDragEnded
        return view
    }

    public func updateNSView(_ nsView: InteractiveCardDragView, context: Context) {
        nsView.previewProvider = previewProvider
        nsView.urlsProvider = urlsProvider
        nsView.onClicked = onClicked
        nsView.onDragEnded = onDragEnded
    }
}

public class InteractiveCardDragView: NSView, NSDraggingSource {
    var previewProvider: (() -> NSImage?)?
    var urlsProvider: (() -> [URL])?
    var onClicked: ((_ isCommand: Bool, _ isShift: Bool) -> Void)?
    var onDragEnded: ((NSDragOperation) -> Void)?

    private var downEvent: NSEvent?
    private var downLocation: NSPoint?
    private var isDragging = false

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func shouldBeginDrag(from start: NSPoint, to current: NSPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= 3
    }

    public override func mouseDown(with event: NSEvent) {
        self.downEvent = event
        self.downLocation = event.locationInWindow
        self.isDragging = false
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let start = downLocation, !isDragging else { return }
        guard Self.shouldBeginDrag(from: start, to: event.locationInWindow) else { return }

        guard let urls = urlsProvider?(), !urls.isEmpty else { return }
        isDragging = true

        let items = ShelfDragPreview.makeItems(urls: urls, preview: previewProvider?())
        self.beginDraggingSession(with: items, event: event, source: self)
    }

    public override func mouseUp(with event: NSEvent) {
        if downEvent != nil && !isDragging {
            let cgFlags = CGEventSource.flagsState(.combinedSessionState)
            let downFlags = downEvent?.modifierFlags ?? []
            let upFlags = event.modifierFlags
            let sysFlags = NSEvent.modifierFlags

            let isCommand = cgFlags.contains(.maskCommand) ||
                            downFlags.contains(.command) ||
                            upFlags.contains(.command) ||
                            sysFlags.contains(.command)

            let isShift = cgFlags.contains(.maskShift) ||
                          downFlags.contains(.shift) ||
                          upFlags.contains(.shift) ||
                          sysFlags.contains(.shift)

            onClicked?(isCommand, isShift)
        }
        isDragging = false
        downEvent = nil
        downLocation = nil
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if context == .outsideApplication {
            return ShelfStore.shared.transferMode == .cut ? [.move, .copy] : [.copy]
        } else {
            return [.copy]
        }
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        onDragEnded?(operation)
    }
}

// Reuse rendered previews instead of reading each file's icon during mouse tracking.
enum ShelfDragPreview {
    private static let document = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: "File") ?? NSImage(size: NSSize(width: 44, height: 44))
    private static let stack = NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: "Files") ?? document

    static func makeItems(urls: [URL], preview: NSImage? = nil) -> [NSDraggingItem] {
        let image = urls.count == 1 ? (preview ?? document) : stack
        return urls.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: 0, y: 0, width: 44, height: 44), contents: image)
            return item
        }
    }
}
