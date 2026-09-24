import Cocoa
import SwiftUI
import Combine

public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: FloatingPanelController!
    private var hotKeyMonitor: Any?
    private var statusIconObservation: AnyCancellable?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Clean up any stale staging artifacts from prior runs
        ActionExecutor.purgeStagingDirectory()

        // Initialize Panel Controller
        panelController = FloatingPanelController()

        // Set up Menu Bar Status Item
        setupStatusItem()

        ClipboardStore.shared.start()

        // Start Global Drag Monitor
        GlobalDragMonitor.shared.start()

        // Setup Local Hotkey (Cmd + Shift + Y)
        setupHotKey()

        // Setup Distributed Notification for external control / automation
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(toggleShelf),
            name: NSNotification.Name("com.dropshelf.toggle"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalAdd(_:)),
            name: NSNotification.Name("com.dropshelf.addFiles"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalAction(_:)),
            name: NSNotification.Name("com.dropshelf.executeAction"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(collapseShelf),
            name: NSNotification.Name("com.dropshelf.collapse"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(uncollapseShelf),
            name: NSNotification.Name("com.dropshelf.uncollapse"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(combineStack),
            name: NSNotification.Name("com.dropshelf.toggleStack"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // Register Apple Event handler for dropshelf:// URLs
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    // MARK: - External URL & File Open Handling (CLI / Quick Actions / URL Schemes)

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        handleIncomingURL(url)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func showPanelAndUncollapse() {
        ShelfStore.shared.section = .files
        ShelfStore.shared.isCollapsed = false
        panelController.show()
    }

    func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            ShelfStore.shared.addItems(from: [url])
            showPanelAndUncollapse()
            return
        }

        guard url.scheme == "dropshelf" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = url.host ?? (url.pathComponents.dropFirst().first ?? "")

        switch host {
        case "add":
            if let components = components {
                if let text = components.queryItems?.first(where: { $0.name == "text" || $0.name == "snippet" })?.value {
                    // Impose a 64KB safe bound on URL text snippets to prevent memory exhaustion DOS
                    let safeText = String(text.prefix(65536))
                    ShelfStore.shared.addTextSnippet(text: safeText)
                    showPanelAndUncollapse()
                } else if let fileQuery = components.queryItems?.first(where: { $0.name == "files" || $0.name == "file" || $0.name == "path" })?.value {
                    let paths = fileQuery.components(separatedBy: ",")
                    let fileURLs = paths.compactMap { path -> URL? in
                        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return nil }
                        let expanded = (trimmed as NSString).expandingTildeInPath
                        let u = URL(fileURLWithPath: expanded).standardizedFileURL
                        return FileManager.default.fileExists(atPath: u.path) ? u : nil
                    }
                    if !fileURLs.isEmpty {
                        ShelfStore.shared.addItems(from: fileURLs)
                        showPanelAndUncollapse()
                    }
                }
            }
        case "toggle":
            toggleShelf()
        case "collapse":
            collapseShelf()
        case "uncollapse", "expand":
            uncollapseShelf()
        case "theme":
            if let val = components?.queryItems?.first(where: { $0.name == "name" })?.value {
                let cap = val.prefix(1).uppercased() + val.dropFirst().lowercased()
                if let theme = AppearanceTheme(rawValue: cap) {
                    DispatchQueue.main.async {
                        ShelfStore.shared.setAppearance(theme)
                    }
                }
            }
        case "mode":
            if let val = components?.queryItems?.first(where: { $0.name == "name" })?.value {
                let cap = val.prefix(1).uppercased() + val.dropFirst().lowercased()
                if let mode = DragTransferMode(rawValue: cap) {
                    DispatchQueue.main.async {
                        ShelfStore.shared.transferMode = mode
                        ShelfStore.shared.savePreferences()
                    }
                }
            }
        case "grid":
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    ShelfStore.shared.showActionGrid.toggle()
                    ShelfStore.shared.savePreferences()
                }
            }
        case "stack":
            ShelfStore.shared.combineAllIntoStack()
        case "unstack":
            ShelfStore.shared.separateAll()
        case "clear":
            clearShelf()
        case "history":
            ShelfStore.shared.isHistoryOpen = true
            showPanelAndUncollapse()
        default:
            break
        }
    }

    @objc private func handleExternalAdd(_ notification: Notification) {
        if let paths = notification.userInfo?["paths"] as? [String] {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            ShelfStore.shared.addItems(from: urls)
            showPanelAndUncollapse()
        }
    }

    @objc private func handleExternalAction(_ notification: Notification) {
        if let actionStr = notification.userInfo?["action"] as? String,
           let action = ActionType(rawValue: actionStr) {
            let urls = ShelfStore.shared.items.flatMap { $0.fileURLs }
            ActionExecutor.shared.execute(action: action, urls: urls, sourceView: nil) { success, msg in
                ShelfStore.shared.showStatus(message: msg)
            }
        }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard OperationCoordinator.shared.isRunning else { return .terminateNow }
        OperationCoordinator.shared.cancelAndWhenIdle { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        GlobalDragMonitor.shared.stop()
        ClipboardStore.shared.stop()
        ClipboardDetailWindowController.shared.close()
        if let monitor = hotKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        // Purge temporary staging files
        ActionExecutor.purgeStagingDirectory()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = BrandAssets.menuBar(isDragging: false)
            button.imagePosition = .imageOnly
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            button.toolTip = "DropShelf"
        }
        statusIconObservation = Publishers.CombineLatest(ShelfStore.shared.$isContentDragActive, ShelfStore.shared.$isDraggingOverShelf)
            .map { $0 || $1 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isDragging in
                self?.statusItem.button?.image = BrandAssets.menuBar(isDragging: isDragging)
            }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            panelController.toggleFromMenuBar()
        }
    }

    private func showContextMenu() {
        panelController.cancelMenuBarAutoDismissTimer()
        let menu = NSMenu()

        let clipboardItem = NSMenuItem(title: "Show Clipboard", action: #selector(showClipboard), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)
        menu.addItem(.separator())

        // 1. Shelf Visibility & Operations
        let showItem = NSMenuItem(title: "Toggle Shelf", action: #selector(toggleShelf), keyEquivalent: "")
        menu.addItem(showItem)

        if !ShelfStore.shared.items.isEmpty {
            if ShelfStore.shared.isCollapsed {
                let uncollapseItem = NSMenuItem(title: "Uncollapse Shelf", action: #selector(uncollapseShelf), keyEquivalent: "")
                menu.addItem(uncollapseItem)
            } else {
                let collapseItem = NSMenuItem(title: "Collapse to Edge Tab", action: #selector(collapseShelf), keyEquivalent: "")
                menu.addItem(collapseItem)
            }
        }

        let clearItem = NSMenuItem(title: "Clear Shelf", action: #selector(clearShelf), keyEquivalent: "")
        clearItem.isEnabled = !ShelfStore.shared.items.isEmpty
        menu.addItem(clearItem)

        let historyItem = NSMenuItem(
            title: "Recent Drops History (\(ShelfStore.shared.historyItems.count))",
            action: #selector(toggleHistory),
            keyEquivalent: ""
        )
        menu.addItem(historyItem)

        let isStacked = ShelfStore.shared.hasStackedItems
        let combineItem = NSMenuItem(
            title: isStacked ? "Unstack Files (Separate)" : "Combine All into Stack",
            action: #selector(combineStack),
            keyEquivalent: ""
        )
        combineItem.isEnabled = ShelfStore.shared.canStackOrUnstack
        menu.addItem(combineItem)

        menu.addItem(NSMenuItem.separator())

        // 2. Preferences Window
        let prefItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(prefItem)

        menu.addItem(NSMenuItem.separator())

        // 3. Appearance Theme Submenu
        let appearanceMenu = NSMenu()
        for theme in AppearanceTheme.allCases {
            let themeItem = NSMenuItem(title: theme.rawValue, action: #selector(selectAppearanceTheme(_:)), keyEquivalent: "")
            themeItem.representedObject = theme
            themeItem.state = (ShelfStore.shared.appearanceTheme == theme) ? .on : .off
            appearanceMenu.addItem(themeItem)
        }
        let appearanceSubmenuItem = NSMenuItem(title: "Appearance Theme", action: nil, keyEquivalent: "")
        appearanceSubmenuItem.submenu = appearanceMenu
        menu.addItem(appearanceSubmenuItem)

        // 4. Dock Position Submenu
        let dockMenu = NSMenu()
        for edge in DockEdge.allCases {
            let edgeItem = NSMenuItem(title: "\(edge.rawValue) Screen Edge", action: #selector(selectDockEdge(_:)), keyEquivalent: "")
            edgeItem.representedObject = edge
            edgeItem.state = (ShelfStore.shared.dockEdge == edge) ? .on : .off
            dockMenu.addItem(edgeItem)
        }
        let dockSubmenuItem = NSMenuItem(title: "Dock Position", action: nil, keyEquivalent: "")
        dockSubmenuItem.submenu = dockMenu
        menu.addItem(dockSubmenuItem)

        // 5. Transfer Mode Submenu
        let transferMenu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy (Keep originals)", action: #selector(selectTransferMode(_:)), keyEquivalent: "")
        copyItem.representedObject = DragTransferMode.copy
        copyItem.state = (ShelfStore.shared.transferMode == .copy) ? .on : .off
        transferMenu.addItem(copyItem)

        let cutItem = NSMenuItem(title: "Cut (Move to destination)", action: #selector(selectTransferMode(_:)), keyEquivalent: "")
        cutItem.representedObject = DragTransferMode.cut
        cutItem.state = (ShelfStore.shared.transferMode == .cut) ? .on : .off
        transferMenu.addItem(cutItem)

        let transferSubmenuItem = NSMenuItem(title: "Transfer Mode", action: nil, keyEquivalent: "")
        transferSubmenuItem.submenu = transferMenu
        menu.addItem(transferSubmenuItem)

        menu.addItem(NSMenuItem.separator())

        // 6. Behavior Toggles
        let soundItem = NSMenuItem(title: "Play Sound Effects", action: #selector(toggleSoundEffects), keyEquivalent: "")
        soundItem.state = ShelfStore.shared.enableSoundEffects ? .on : .off
        menu.addItem(soundItem)

        let autoShowItem = NSMenuItem(title: "Show Shelf on Drag", action: #selector(toggleAutoShow), keyEquivalent: "")
        autoShowItem.state = ShelfStore.shared.autoShowOnDrag ? .on : .off
        menu.addItem(autoShowItem)

        let shakeItem = NSMenuItem(title: "Require Shake to Show", action: #selector(toggleShakeOnly), keyEquivalent: "")
        shakeItem.state = ShelfStore.shared.shakeOnlyToShow ? .on : .off
        shakeItem.isEnabled = ShelfStore.shared.autoShowOnDrag
        menu.addItem(shakeItem)

        let actionGridItem = NSMenuItem(title: "Quick Action Grid", action: #selector(toggleActionGrid), keyEquivalent: "")
        actionGridItem.state = ShelfStore.shared.showActionGrid ? .on : .off
        menu.addItem(actionGridItem)

        let autoStackItem = NSMenuItem(title: "Auto-Stack Multiple Files", action: #selector(toggleAutoStack), keyEquivalent: "")
        autoStackItem.state = ShelfStore.shared.autoStackMultiple ? .on : .off
        menu.addItem(autoStackItem)

        let launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())
        let aboutItem = NSMenuItem(title: "DropShelf v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown") by Arslan Hamid", action: nil, keyEquivalent: "")
        aboutItem.isEnabled = false
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit DropShelf", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Reset so subsequent clicks toggle panel directly
        statusItem.menu = nil
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.show()
    }

    @objc private func selectAppearanceTheme(_ sender: NSMenuItem) {
        guard let theme = sender.representedObject as? AppearanceTheme else { return }
        ShelfStore.shared.appearanceTheme = theme
        ShelfStore.shared.savePreferences()
        ShelfStore.shared.panelController?.updateAppearance()
    }

    @objc private func toggleHistory() {
        ShelfStore.shared.isHistoryOpen.toggle()
        showPanelAndUncollapse()
    }

    @objc private func selectDockEdge(_ sender: NSMenuItem) {
        guard let edge = sender.representedObject as? DockEdge else { return }
        ShelfStore.shared.dockEdge = edge
        ShelfStore.shared.savePreferences()
        ShelfStore.shared.panelController?.updatePosition()
    }

    @objc private func selectTransferMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? DragTransferMode else { return }
        ShelfStore.shared.transferMode = mode
        ShelfStore.shared.savePreferences()
        ShelfStore.shared.playSound("Pop")
    }

    @objc private func toggleSoundEffects() {
        ShelfStore.shared.enableSoundEffects.toggle()
        ShelfStore.shared.savePreferences()
        if ShelfStore.shared.enableSoundEffects {
            ShelfStore.shared.playSound("Pop")
        }
    }

    @objc private func toggleAutoShow() {
        ShelfStore.shared.autoShowOnDrag.toggle()
        ShelfStore.shared.savePreferences()
    }

    @objc private func toggleShakeOnly() {
        ShelfStore.shared.shakeOnlyToShow.toggle()
        ShelfStore.shared.savePreferences()
    }

    @objc private func toggleActionGrid() {
        ShelfStore.shared.showActionGrid.toggle()
        ShelfStore.shared.savePreferences()
    }

    @objc private func toggleAutoStack() {
        ShelfStore.shared.autoStackMultiple.toggle()
        ShelfStore.shared.savePreferences()
    }

    @objc private func toggleLaunchAtLogin() {
        ShelfStore.shared.setLaunchAtLogin(!LaunchAtLoginManager.shared.isEnabled)
    }

    @objc private func uncollapseShelf() {
        ShelfStore.shared.uncollapse()
        panelController.show(animated: true)
    }

    @objc private func collapseShelf() {
        ShelfStore.shared.collapseToEdgeTab()
    }

    @objc private func showClipboard() {
        ClipboardStore.shared.prune()
        ShelfStore.shared.section = .clipboard
        ShelfStore.shared.uncollapse(playSound: false, notify: false)
        panelController.show()
    }

    @objc private func toggleShelf() {
        if ShelfStore.shared.isCollapsed {
            ShelfStore.shared.uncollapse(playSound: true, notify: false)
        }
        panelController.toggle()
    }

    @objc private func clearShelf() {
        ShelfStore.shared.clearAll()
    }

    @objc private func combineStack() {
        ShelfStore.shared.toggleStackAll()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func setupHotKey() {
        // Global monitor for Cmd + Shift + Y
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.charactersIgnoringModifiers?.lowercased() == "y" {
                self?.panelController.toggle()
            }
        }
    }
}
