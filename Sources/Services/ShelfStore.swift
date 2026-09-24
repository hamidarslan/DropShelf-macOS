import Cocoa
import SwiftUI
import Combine

public enum DockEdge: String, CaseIterable {
    case right = "Right"
    case left = "Left"
}

public enum DragTransferMode: String, CaseIterable {
    case copy = "Copy"
    case cut = "Cut"
}

public enum AppearanceTheme: String, CaseIterable {
    case auto = "Auto"
    case dark = "Dark"
    case light = "Light"

    public var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

public enum GlassDensity: String, CaseIterable {
    case hud = "HUD Glass"
    case regular = "Sidebar"
    case ultraThin = "Ultra-Thin"

    public var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .hud: return .hudWindow
        case .regular: return .sidebar
        case .ultraThin: return .underWindowBackground
        }
    }
}

public enum ShelfSection { case files, clipboard }

public class ShelfStore: ObservableObject {
    public static let shared = ShelfStore()

    public var shelfWidth: CGFloat { useRefinedClassic ? 210 : 310 }

    @Published public var section: ShelfSection = .files
    @Published public var pendingFilePromises: Int = 0
    @Published public var items: [ShelfItem] = []
    @Published public var historyItems: [ShelfItem] = []
    @Published public var isHistoryOpen: Bool = false
    @Published public var isPanelVisible: Bool = false
    @Published public var isCollapsed: Bool = false
    @Published public var dockEdge: DockEdge = .right
    @Published public var autoShowOnDrag: Bool = true
    @Published public var shakeOnlyToShow: Bool = false
    @Published public var autoStackMultiple: Bool = false
    @Published public var useRefinedClassic: Bool = true
    @Published public var showActionGrid: Bool = true
    @Published public var transferMode: DragTransferMode = .copy
    @Published public var statusMessage: String? = nil
    @Published public var selectedItemIDs: Set<UUID> = []
    @Published public var lastSelectedID: UUID? = nil
    @Published public var isContentDragActive: Bool = false
    @Published public var isDraggingOverShelf: Bool = false
    @Published public var targetedAction: ActionType? = nil
    @Published public var actionTileFrames: [ActionType: CGRect] = [:]
    @Published public var autoCollapseAfterDrop: Bool = false
    @Published public var isPeekingFromEdgeTab: Bool = false
    @Published public var launchAtLogin: Bool = false
    @Published public var enableSoundEffects: Bool = true
    @Published public var appearanceTheme: AppearanceTheme = .auto
    @Published public var glassOpacity: Double = 0.85
    @Published public var glassDensity: GlassDensity = .hud

    private var statusDismissTimer: Timer?
    public weak var panelController: FloatingPanelController?

    private init() {
        // Load default preferences
        let defaults = UserDefaults.standard
        if let edgeStr = defaults.string(forKey: "dockEdge"), let edge = DockEdge(rawValue: edgeStr) {
            self.dockEdge = edge
        }
        if defaults.object(forKey: "autoShowOnDrag") != nil {
            self.autoShowOnDrag = defaults.bool(forKey: "autoShowOnDrag")
        }
        self.shakeOnlyToShow = defaults.bool(forKey: "shakeOnlyToShow")
        if defaults.object(forKey: "useRefinedClassic") != nil {
            self.useRefinedClassic = defaults.bool(forKey: "useRefinedClassic")
        }
        if defaults.object(forKey: "autoStackMultiple") != nil {
            self.autoStackMultiple = defaults.bool(forKey: "autoStackMultiple")
        }
        if defaults.object(forKey: "showActionGrid") != nil {
            self.showActionGrid = defaults.bool(forKey: "showActionGrid")
        }
        if let modeStr = defaults.string(forKey: "transferMode"), let mode = DragTransferMode(rawValue: modeStr) {
            self.transferMode = mode
        }
        if defaults.object(forKey: "enableSoundEffects") != nil {
            self.enableSoundEffects = defaults.bool(forKey: "enableSoundEffects")
        }
        if let themeStr = defaults.string(forKey: "appearanceTheme"), let theme = AppearanceTheme(rawValue: themeStr) {
            self.appearanceTheme = theme
        }
        if defaults.object(forKey: "glassOpacity") != nil {
            self.glassOpacity = defaults.double(forKey: "glassOpacity")
        }
        if let densityStr = defaults.string(forKey: "glassDensity"), let density = GlassDensity(rawValue: densityStr) {
            self.glassDensity = density
        }
        self.launchAtLogin = LaunchAtLoginManager.shared.isEnabled
    }

    public func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(dockEdge.rawValue, forKey: "dockEdge")
        defaults.set(autoShowOnDrag, forKey: "autoShowOnDrag")
        defaults.set(shakeOnlyToShow, forKey: "shakeOnlyToShow")
        defaults.set(autoStackMultiple, forKey: "autoStackMultiple")
        defaults.set(showActionGrid, forKey: "showActionGrid")
        defaults.set(useRefinedClassic, forKey: "useRefinedClassic")
        defaults.set(transferMode.rawValue, forKey: "transferMode")
        defaults.set(enableSoundEffects, forKey: "enableSoundEffects")
        defaults.set(appearanceTheme.rawValue, forKey: "appearanceTheme")
        defaults.set(glassOpacity, forKey: "glassOpacity")
        defaults.set(glassDensity.rawValue, forKey: "glassDensity")
    }

    public func setRefinedClassic(_ enabled: Bool) {
        useRefinedClassic = enabled
        targetedAction = nil
        actionTileFrames.removeAll()
        savePreferences()
        panelController?.updatePosition()
    }

    public func setAppearance(_ theme: AppearanceTheme) {
        self.appearanceTheme = theme
        savePreferences()
        panelController?.updateAppearance()
    }

    public var isEffectiveLightMode: Bool {
        switch appearanceTheme {
        case .light:
            return true
        case .dark:
            return false
        case .auto:
            if let app = NSApp {
                return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            }
            return false
        }
    }

    public func setGlassOpacity(_ opacity: Double) {
        self.glassOpacity = opacity
        savePreferences()
    }

    public func setGlassDensity(_ density: GlassDensity) {
        self.glassDensity = density
        savePreferences()
    }

    // MARK: - History Management

    private func availableItem(_ item: ShelfItem) -> ShelfItem? {
        guard !item.fileURLs.isEmpty else { return item }
        let urls = item.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return nil }
        return urls.count == item.fileURLs.count ? item : item.retaining(urls: urls)
    }

    private func cleanUnreferencedGeneratedFiles(from candidates: [ShelfItem]) {
        let referenced = Set((items + historyItems).flatMap { $0.fileURLs }.map { $0.standardizedFileURL })
        for url in Set(candidates.flatMap { $0.generatedURLs }) where !referenced.contains(url) {
            guard ActionExecutor.isStagedFile(url), !OperationCoordinator.shared.heldURLs.contains(url.standardizedFileURL) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func releaseOperationFiles(_ urls: Set<URL>) {
        let referenced = Set((items + historyItems).flatMap { $0.fileURLs }.map { $0.standardizedFileURL })
        for url in urls where !referenced.contains(url.standardizedFileURL) && ActionExecutor.isStagedFile(url) {
            try? FileManager.default.removeItem(at: url)
            let parent = url.deletingLastPathComponent()
            if ActionExecutor.isStagedFile(parent), (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: parent)
            }
        }
    }

    public func recordHistory(itemsToRecord: [ShelfItem]) {
        var updated = historyItems
        for item in itemsToRecord {
            if let available = availableItem(item), !updated.contains(where: { $0.id == available.id }) {
                updated.insert(available, at: 0)
            }
        }
        historyItems = updated
    }

    public func restoreFromHistory(item: ShelfItem) {
        historyItems.removeAll { $0.id == item.id }
        guard let available = availableItem(item) else {
            showStatus(message: "Original file is no longer available")
            return
        }
        let existing = Set(items.flatMap { $0.fileURLs }.map { $0.standardizedFileURL })
        if available.fileURLs.isEmpty {
            if !items.contains(where: { $0.id == available.id }) { items.insert(available, at: 0) }
        } else {
            let urls = available.fileURLs.filter { !existing.contains($0.standardizedFileURL) }
            if !urls.isEmpty { items.insert(available.retaining(urls: urls), at: 0) }
        }
        showPanel(animated: true)
        playSound("Pop")
        showStatus(message: "Restored available items")
    }

    public func restoreAllHistory() {
        for item in historyItems.reversed() { restoreFromHistory(item: item) }
    }

    public func clearHistory() {
        let removed = historyItems
        historyItems.removeAll()
        cleanUnreferencedGeneratedFiles(from: removed)
        isHistoryOpen = false
        playSound("Basso")
        showStatus(message: "History cleared")
    }

    public func playSound(_ name: String) {
        guard enableSoundEffects else { return }
        NSSound(named: name)?.play()
    }

    // MARK: - Multi-Selection Management

    public func isSelected(_ id: UUID) -> Bool {
        selectedItemIDs.contains(id)
    }

    public func toggleSelection(id: UUID) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
            if lastSelectedID == id { lastSelectedID = nil }
        } else {
            selectedItemIDs.insert(id)
            lastSelectedID = id
        }
    }

    public func selectOnly(id: UUID) {
        if selectedItemIDs.count == 1 && selectedItemIDs.contains(id) {
            selectedItemIDs.removeAll()
            lastSelectedID = nil
        } else {
            selectedItemIDs = [id]
            lastSelectedID = id
        }
    }

    public func selectRange(to id: UUID) {
        guard let last = lastSelectedID,
              let fromIdx = items.firstIndex(where: { $0.id == last }),
              let toIdx = items.firstIndex(where: { $0.id == id }) else {
            selectOnly(id: id)
            return
        }

        let start = min(fromIdx, toIdx)
        let end = max(fromIdx, toIdx)
        for i in start...end {
            selectedItemIDs.insert(items[i].id)
        }
        lastSelectedID = id
    }

    public func selectAll() {
        selectedItemIDs = Set(items.map { $0.id })
    }

    public func deselectAll() {
        selectedItemIDs.removeAll()
        lastSelectedID = nil
    }

    public func allSelectedURLs() -> [URL] {
        if selectedItemIDs.isEmpty {
            return []
        }
        return items.filter { selectedItemIDs.contains($0.id) }.flatMap { $0.fileURLs }
    }

    // MARK: - Stacking Modes

    public var hasStackedItems: Bool {
        items.contains(where: { $0.isStack })
    }

    public var isSingleStack: Bool {
        items.count == 1 && (items.first?.isStack ?? false)
    }

    public var totalFileCount: Int {
        items.reduce(0) { $0 + max($1.fileURLs.count, 1) }
    }

    public var canStackOrUnstack: Bool {
        items.count > 1 || isSingleStack
    }

    public func toggleStackAll() {
        if hasStackedItems {
            separateAll()
        } else {
            combineAllIntoStack()
        }
    }

    public func stackAll() {
        self.autoStackMultiple = true
        savePreferences()
        combineAllIntoStack()
    }

    public func separateAll() {
        DispatchQueue.main.async {
            var newItems: [ShelfItem] = []
            for item in self.items {
                if item.fileURLs.count > 1 {
                    for url in item.fileURLs.reversed() {
                        newItems.append(item.retaining(urls: [url]))
                    }
                } else {
                    newItems.append(item)
                }
            }
            guard newItems.count != self.items.count else { return }
            self.items = newItems
            self.selectedItemIDs.removeAll()
            self.playSound("Pop")
            self.showStatus(message: "Separated into individual files")
        }
    }

    public func stackSelected() {
        let selected = items.filter { selectedItemIDs.contains($0.id) && !$0.fileURLs.isEmpty && !$0.isLocked }
        guard selected.flatMap({ $0.fileURLs }).count > 1 else { return }
        let ids = Set(selected.map { $0.id })
        let stackItem = ShelfItem.combining(selected)
        items.removeAll { ids.contains($0.id) }
        items.insert(stackItem, at: 0)
        selectedItemIDs = [stackItem.id]
        lastSelectedID = stackItem.id
        playSound("Pop")
    }

    // MARK: - Item Management

    public func addItems(from urls: [URL], autoStack: Bool? = nil, isGenerated: Bool = false) {
        guard !urls.isEmpty else { return }

        DispatchQueue.main.async {
            self.panelController?.cancelMenuBarAutoDismissTimer()
            let existingPaths = Set(self.items.flatMap { $0.fileURLs.map { $0.standardizedFileURL.path } })
            let newURLs = urls.filter { !existingPaths.contains($0.standardizedFileURL.path) }

            self.showPanel(animated: true)
            if !self.autoCollapseAfterDrop {
                self.isCollapsed = false
            }

            if newURLs.isEmpty {
                return
            }

            let shouldStack = autoStack ?? self.autoStackMultiple
            if shouldStack && newURLs.count > 1 {
                let stackItem = ShelfItem.from(urls: newURLs, isGenerated: isGenerated)
                self.items.insert(stackItem, at: 0)
            } else {
                for url in newURLs.reversed() {
                    let item = ShelfItem.from(urls: [url], isGenerated: isGenerated)
                    self.items.insert(item, at: 0)
                }
            }
            self.playSound("Purr")
            self.showStatus(message: "Added \(newURLs.count) item(s)")
        }
    }

    public func addTextSnippet(text: String) {
        let item = ShelfItem.from(text: text)
        DispatchQueue.main.async {
            self.panelController?.cancelMenuBarAutoDismissTimer()
            self.items.insert(item, at: 0)
            self.playSound("Purr")
            self.showPanel(animated: true)
            if !self.autoCollapseAfterDrop {
                self.isCollapsed = false
            }
            self.showStatus(message: "Added text snippet")
        }
    }

    public func removeItem(id: UUID) {
        DispatchQueue.main.async {
            let removed = self.items.filter { $0.id == id }
            self.recordHistory(itemsToRecord: removed)
            self.items.removeAll { $0.id == id }
            self.cleanUnreferencedGeneratedFiles(from: removed)
            self.selectedItemIDs.remove(id)
            if self.items.isEmpty {
                self.isCollapsed = false
                self.isPeekingFromEdgeTab = false
                self.autoCollapseAfterDrop = false
                self.hidePanel(animated: true)
            }
        }
    }

    public func clearAll() {
        DispatchQueue.main.async {
            let toRemove = self.items.filter { !$0.isLocked }
            self.recordHistory(itemsToRecord: toRemove)

            // Keep locked items, remove unlocked
            let kept = self.items.filter { $0.isLocked }
            let removedCount = self.items.count - kept.count
            self.items = kept
            self.cleanUnreferencedGeneratedFiles(from: toRemove)
            self.selectedItemIDs.removeAll()
            self.lastSelectedID = nil

            if removedCount > 0 {
                self.playSound("Basso")
                self.showStatus(message: "Cleared \(removedCount) item(s) • Saved to History")
            }
            if self.items.isEmpty {
                self.isCollapsed = false
                self.isPeekingFromEdgeTab = false
                self.autoCollapseAfterDrop = false
                self.hidePanel(animated: true)
            }
        }
    }

    public func combineAllIntoStack() {
        DispatchQueue.main.async {
            let candidates = self.items.filter { !$0.fileURLs.isEmpty && !$0.isLocked }
            guard candidates.flatMap({ $0.fileURLs }).count > 1 else { return }
            let ids = Set(candidates.map { $0.id })
            let stackItem = ShelfItem.combining(candidates)
            self.items.removeAll { ids.contains($0.id) }
            self.items.insert(stackItem, at: 0)
            self.selectedItemIDs = [stackItem.id]
            self.playSound("Pop")
            self.showStatus(message: "Combined all into 1 stack")
        }
    }

    public func splitStack(item: ShelfItem) {
        DispatchQueue.main.async {
            guard let index = self.items.firstIndex(where: { $0.id == item.id }),
                  item.fileURLs.count > 1 else { return }

            self.items.remove(at: index)
            for url in item.fileURLs.reversed() {
                let singleItem = item.retaining(urls: [url])
                self.items.insert(singleItem, at: index)
            }
            self.playSound("Pop")
            self.showStatus(message: "Split into \(item.fileURLs.count) items")
        }
    }

    public func forgetFiles(_ urls: [URL]) {
        let removed = Set(urls.map { $0.standardizedFileURL })
        items = items.compactMap { item in
            guard !item.fileURLs.isEmpty else { return item }
            let remaining = item.fileURLs.filter { !removed.contains($0.standardizedFileURL) }
            if remaining.count == item.fileURLs.count { return item }
            return remaining.isEmpty ? nil : item.retaining(urls: remaining)
        }
        selectedItemIDs.formIntersection(Set(items.map { $0.id }))
        if items.isEmpty { hidePanel(animated: true) }
    }

    public func toggleLock(item: ShelfItem) {
        DispatchQueue.main.async {
            item.isLocked.toggle()
            self.playSound("Tink")
            self.showStatus(message: item.isLocked ? "Item locked (won't remove on drag-out)" : "Item unlocked")
        }
    }

    public func showStatus(message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusMessage = message
            self.statusDismissTimer?.invalidate()
            self.statusDismissTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.statusMessage = nil
                }
            }
        }
    }

    // MARK: - Launch at Login Management

    public func refreshLaunchAtLogin() {
        LaunchAtLoginManager.shared.refreshStatus()
        self.launchAtLogin = LaunchAtLoginManager.shared.isEnabled
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        let success = LaunchAtLoginManager.shared.setEnabled(enabled)
        self.launchAtLogin = LaunchAtLoginManager.shared.isEnabled
        if !success {
            showStatus(message: "Could not update login settings")
        }
    }

    // MARK: - Collapse & Uncollapse Management

    public func uncollapse(playSound: Bool = true, notify: Bool = true) {
        DispatchQueue.main.async {
            self.isPeekingFromEdgeTab = false
            self.isCollapsed = false
            self.autoCollapseAfterDrop = false
            if playSound {
                self.playSound("Pop")
            }
            if notify {
                self.showStatus(message: "Shelf expanded")
            }
        }
    }

    public func collapseToEdgeTab() {
        DispatchQueue.main.async {
            guard !self.items.isEmpty else {
                self.isCollapsed = false
                self.isPeekingFromEdgeTab = false
                self.autoCollapseAfterDrop = false
                self.hidePanel(animated: true)
                return
            }
            self.isPeekingFromEdgeTab = false
            self.isCollapsed = true
            self.playSound("Pop")
            self.showStatus(message: "Collapsed to edge tab")
        }
    }

    public func toggleCollapse() {
        if isCollapsed || isPeekingFromEdgeTab {
            uncollapse()
        } else {
            collapseToEdgeTab()
        }
    }

    // MARK: - Panel Control

    public func showPanel(animated: Bool = true) {
        panelController?.show(animated: animated)
    }

    public func hidePanel(animated: Bool = true) {
        panelController?.hide(animated: animated)
    }

    public func togglePanel() {
        panelController?.toggle()
    }
}
