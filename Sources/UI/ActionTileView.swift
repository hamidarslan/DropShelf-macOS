import SwiftUI
import UniformTypeIdentifiers

final class CompressionEligibilityCache {
    static let shared = CompressionEligibilityCache()
    private struct FileFingerprint: Equatable {
        let size: UInt64?
        let modificationDate: Date?
        let inode: UInt64?
        let device: UInt64?
    }
    private struct Entry {
        let fingerprint: FileFingerprint?
        let kind: CompressionMediaKind?
    }
    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]
    private let detector: (URL) -> CompressionMediaKind?

    init(detector: @escaping (URL) -> CompressionMediaKind? = LosslessCompressionService.detectKind) {
        self.detector = detector
    }

    func eligibleCount(for action: ActionType, urls: [URL]) -> Int {
        guard action == .convertImage || action == .pdfTools else { return 0 }
        return urls.reduce(into: 0) { count, url in
            let kind = cachedKind(for: url)
            if action == .pdfTools ? kind == .pdf : kind == .jpeg || kind == .png { count += 1 }
        }
    }

    private func cachedKind(for url: URL) -> CompressionMediaKind? {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        let fingerprint = Self.fingerprint(for: key)
        lock.lock()
        if let entry = entries[key], entry.fingerprint == fingerprint { lock.unlock(); return entry.kind }
        lock.unlock()
        let kind = detector(url)
        lock.lock(); entries[key] = Entry(fingerprint: fingerprint, kind: kind); lock.unlock()
        return kind
    }

    private static func fingerprint(for url: URL) -> FileFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileFingerprint(
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            device: (attributes[.systemNumber] as? NSNumber)?.uint64Value
        )
    }
}

public struct ActionTileView: View {
    let action: ActionType
    @ObservedObject var store = ShelfStore.shared
    @State private var isHovering = false
    @State private var showSuccess = false
    @State private var losslessCompressionCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var refined: Bool { store.useRefinedClassic }
    private var palette: ClassicPalette { ClassicPalette(light: isLight) }
    private var actionColor: Color { refined ? (action == .trash ? palette.danger : palette.accent) : action.tintColor }

    private var isTargeted: Bool {
        store.targetedAction == action
    }

    private var isLight: Bool {
        store.isEffectiveLightMode
    }

    public var body: some View {
        Button(action: {
            handleActionClick()
        }) {
            VStack(spacing: 3) {
                ZStack {
                    tileCircle

                    if showSuccess {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Group {
                            if refined, let name = RefinedAssets.symbols[action.icon], let image = RefinedAssets.image(name) {
                                Image(nsImage: image).renderingMode(.template).resizable().frame(width: 17, height: 17)
                            } else if action == .copyPath { BrandIconView(.moveCopy, size: 20) }
                            else if action == .trash { BrandIconView(.clear, size: 20) }
                            else { Image(systemName: action.icon) }
                        }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(
                                isTargeted || isHovering
                                ? actionColor
                                : (refined ? actionColor : (isLight ? actionColor : Color.white.opacity(0.85)))
                            )
                    }

                    if losslessCompressionCount > 0 && (action == .convertImage || action == .pdfTools) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.green)
                            .background(Circle().fill(refined ? palette.card : (isLight ? Color.white : Color.black)).padding(-1))
                            .offset(x: 13, y: -13)
                            .help("Lossless compression is available for \(losslessCompressionCount) compatible file\(losslessCompressionCount == 1 ? "" : "s")")
                            .accessibilityLabel("Lossless compression available for \(losslessCompressionCount) file\(losslessCompressionCount == 1 ? "" : "s")")
                    }
                }
                .scaleEffect(reduceMotion ? 1 : (isTargeted ? 1.10 : (isHovering ? 1.04 : 1.0)))
                .animation(.spring(response: 0.28, dampingFraction: 0.65), value: isTargeted)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovering)

                Text(action.shortTitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(
                        refined ? palette.muted : (isLight
                        ? Color.black.opacity(isTargeted || isHovering ? 0.95 : 0.72)
                        : Color.white.opacity(isTargeted || isHovering ? 1.0 : 0.7))
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .help(action.tooltip)
        .onAppear { refreshCompressionBadge() }
        .onChange(of: compressionSourceFingerprint) { _ in refreshCompressionBadge() }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        store.actionTileFrames[action] = geo.frame(in: .global)
                    }
                    .onChange(of: geo.frame(in: .global)) { newFrame in
                        store.actionTileFrames[action] = newFrame
                    }
            }
        )
    }

    private var compressionSourceURLs: [URL] {
        store.selectedItemIDs.isEmpty ? store.items.flatMap { $0.fileURLs } : store.allSelectedURLs()
    }

    private var compressionSourceFingerprint: String {
        guard action == .convertImage || action == .pdfTools else { return "" }
        return compressionSourceURLs.map { $0.standardizedFileURL.path }.joined(separator: "|")
    }

    private func refreshCompressionBadge() {
        guard action == .convertImage || action == .pdfTools else { losslessCompressionCount = 0; return }
        let urls = compressionSourceURLs
        let fingerprint = compressionSourceFingerprint
        DispatchQueue.global(qos: .utility).async {
            let count = CompressionEligibilityCache.shared.eligibleCount(for: action, urls: urls)
            DispatchQueue.main.async {
                guard fingerprint == compressionSourceFingerprint else { return }
                losslessCompressionCount = count
            }
        }
    }

    private var tileFill: Color {
        if refined { return isTargeted || isHovering ? palette.selected : palette.card }
        if isTargeted { return actionColor.opacity(0.45) }
        if isHovering { return actionColor.opacity(isLight ? 0.22 : 0.25) }
        return isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.09)
    }

    private var tileBorder: Color {
        if refined { return isTargeted || isHovering ? actionColor : palette.border }
        if isTargeted { return actionColor }
        if isHovering { return actionColor.opacity(0.6) }
        return isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.12)
    }

    private var tileShadow: Color {
        if isTargeted { return actionColor.opacity(0.7) }
        return isHovering ? actionColor.opacity(0.3) : .clear
    }

    private var tileCircle: some View {
        RoundedRectangle(cornerRadius: refined ? 10 : 18)
            .fill(tileFill)
            .overlay(RoundedRectangle(cornerRadius: refined ? 10 : 18).stroke(tileBorder, lineWidth: isTargeted ? 2 : 1))
            .frame(width: refined ? 30 : 36, height: refined ? 30 : 36)
            .shadow(color: tileShadow, radius: isTargeted ? 8 : 4)
    }

    private func handleActionClick() {
        if action == .convertImage || action == .pdfTools {
            let urls = store.selectedItemIDs.isEmpty ? store.items.flatMap { $0.fileURLs } : store.allSelectedURLs()
            MediaToolsWindowController.shared.show(kind: action == .convertImage ? .images : .pdf, urls: urls)
            return
        }
        store.playSound("Pop")
        let allURLs = store.selectedItemIDs.isEmpty ? store.items.flatMap { $0.fileURLs } : store.allSelectedURLs()

        if !allURLs.isEmpty {
            // Act directly on files currently on the shelf!
            executeWith(urls: allURLs)
        } else {
            // If shelf is empty, open file picker to let user select files to act on
            promptFilePicker()
        }
    }

    private func executeWith(urls: [URL]) {
        ActionExecutor.shared.execute(action: action, urls: urls, sourceView: nil) { success, message in
            if success {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    self.showSuccess = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation {
                        self.showSuccess = false
                    }
                }
            }
            self.store.showStatus(message: message)
        }
    }

    private func promptFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = (action != .convertImage)
        panel.prompt = action.title
        panel.message = "Select items to \(action.title.lowercased())"

        if action == .convertImage {
            panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .webP]
        }

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            let selectedURLs = panel.urls
            guard !selectedURLs.isEmpty else { return }
            executeWith(urls: selectedURLs)
        }
    }
}
