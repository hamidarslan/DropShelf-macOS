import Cocoa
import SwiftUI

private let supportedDragTypes: [NSPasteboard.PasteboardType] = [
    .fileURL,
    NSPasteboard.PasteboardType("public.file-url"),
    NSPasteboard.PasteboardType("NSFilenamesPboardType"),
    .URL,
    .string,
    .html,
    .rtf,
    .tiff,
    .png
] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

public class ShelfDropHostingView: NSHostingView<DropShelfView> {
    public override var acceptsFirstResponder: Bool { true }

    public required init(rootView: DropShelfView) {
        super.init(rootView: rootView)
        registerForDraggedTypes(supportedDragTypes)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(supportedDragTypes)
    }

    private var trackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        ShelfStore.shared.panelController?.cancelMenuBarAutoDismissTimer()
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        ShelfStore.shared.panelController?.cancelMenuBarAutoDismissTimer()
    }

    public override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        ShelfStore.shared.panelController?.cancelMenuBarAutoDismissTimer()
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ShelfStore.shared.panelController?.cancelMenuBarAutoDismissTimer()
        checkExpandFromEdgeTab(sender: sender)
        DropProcessor.updateDraggingHover(sender: sender, view: self)
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        checkExpandFromEdgeTab(sender: sender)
        DropProcessor.updateDraggingHover(sender: sender, view: self)
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        ShelfStore.shared.isDraggingOverShelf = false
        ShelfStore.shared.targetedAction = nil
        // The monitor handles idle dismissal and restores temporary expansion at drag end.
        guard !ShelfStore.shared.isContentDragActive else { return }

        if ShelfStore.shared.section == .files && ShelfStore.shared.items.isEmpty && ShelfStore.shared.pendingFilePromises == 0 && !OperationCoordinator.shared.isRunning {
            ShelfStore.shared.isCollapsed = false
            ShelfStore.shared.isPeekingFromEdgeTab = false
            ShelfStore.shared.autoCollapseAfterDrop = false
            ShelfStore.shared.hidePanel(animated: true)
        } else if ShelfStore.shared.autoCollapseAfterDrop {
            ShelfStore.shared.autoCollapseAfterDrop = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                ShelfStore.shared.isCollapsed = true
            }
        }
    }

    func checkExpandFromEdgeTab(sender: NSDraggingInfo) {
        guard ShelfStore.shared.isCollapsed else { return }
        let loc = self.convert(sender.draggingLocation, from: nil)
        let isNearTab: Bool
        if ShelfStore.shared.dockEdge == .right {
            isNearTab = loc.x >= bounds.maxX - 110
        } else {
            isNearTab = loc.x <= bounds.minX + 110
        }

        if isNearTab {
            ShelfStore.shared.autoCollapseAfterDrop = true
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                ShelfStore.shared.isCollapsed = false
            }
            ShelfStore.shared.playSound("Pop")
        }
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ShelfStore.shared.isDraggingOverShelf = false
        ShelfStore.shared.targetedAction = nil
        let handled = DropProcessor.handleDrop(sender: sender, view: self)
        if !handled && ShelfStore.shared.section == .files && ShelfStore.shared.items.isEmpty && ShelfStore.shared.pendingFilePromises == 0 && !OperationCoordinator.shared.isRunning {
            ShelfStore.shared.isCollapsed = false
            ShelfStore.shared.isPeekingFromEdgeTab = false
            ShelfStore.shared.autoCollapseAfterDrop = false
            ShelfStore.shared.hidePanel(animated: true)
        }
        return handled
    }

    public override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        ShelfStore.shared.isDraggingOverShelf = false
        ShelfStore.shared.targetedAction = nil
        if ShelfStore.shared.section == .files && ShelfStore.shared.items.isEmpty && ShelfStore.shared.pendingFilePromises == 0 && !OperationCoordinator.shared.isRunning {
            ShelfStore.shared.isCollapsed = false
            ShelfStore.shared.isPeekingFromEdgeTab = false
            ShelfStore.shared.autoCollapseAfterDrop = false
            ShelfStore.shared.hidePanel(animated: true)
        }
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        GlobalDragMonitor.shared.handleAppKitDragEnded()
        ShelfStore.shared.isDraggingOverShelf = false
        ShelfStore.shared.targetedAction = nil
        if ShelfStore.shared.section == .files && ShelfStore.shared.items.isEmpty && ShelfStore.shared.pendingFilePromises == 0 && !OperationCoordinator.shared.isRunning {
            ShelfStore.shared.isCollapsed = false
            ShelfStore.shared.isPeekingFromEdgeTab = false
            ShelfStore.shared.autoCollapseAfterDrop = false
            ShelfStore.shared.hidePanel(animated: true)
        }
    }
}

public class FloatingPanel: NSPanel, NSDraggingDestination {
    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = true

        // Register window itself as a fallback dragging destination
        registerForDraggedTypes(supportedDragTypes)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ShelfStore.shared.section == .clipboard { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "a" {
                ShelfStore.shared.selectAll()
                return true
            }
        }
        if event.keyCode == 49 { // Space
            let store = ShelfStore.shared
            let candidates = store.selectedItemIDs.isEmpty ? store.items : store.items.filter { store.selectedItemIDs.contains($0.id) }
            if let url = candidates.first?.fileURLs.first {
                QuickLookController.shared.show(url)
                return true
            }
        }
        if event.keyCode == 53 { // ESC
            ShelfStore.shared.deselectAll()
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete or Forward Delete
            if !ShelfStore.shared.selectedItemIDs.isEmpty {
                for id in ShelfStore.shared.selectedItemIDs {
                    ShelfStore.shared.removeItem(id: id)
                }
                ShelfStore.shared.deselectAll()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - NSDraggingDestination on NSPanel
    public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        (self.contentView as? ShelfDropHostingView)?.checkExpandFromEdgeTab(sender: sender)
        DropProcessor.updateDraggingHover(sender: sender, view: self.contentView)
        return .copy
    }

    public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        (self.contentView as? ShelfDropHostingView)?.checkExpandFromEdgeTab(sender: sender)
        DropProcessor.updateDraggingHover(sender: sender, view: self.contentView)
        return .copy
    }

    public func draggingExited(_ sender: NSDraggingInfo?) {
        ShelfStore.shared.isDraggingOverShelf = false
        ShelfStore.shared.targetedAction = nil
        guard !ShelfStore.shared.isContentDragActive else { return }
        if ShelfStore.shared.section == .files && ShelfStore.shared.items.isEmpty && ShelfStore.shared.pendingFilePromises == 0 && !OperationCoordinator.shared.isRunning {
            ShelfStore.shared.isCollapsed = false
            ShelfStore.shared.isPeekingFromEdgeTab = false
            ShelfStore.shared.autoCollapseAfterDrop = false
            ShelfStore.shared.hidePanel(animated: true)
        } else if ShelfStore.shared.autoCollapseAfterDrop {
            ShelfStore.shared.autoCollapseAfterDrop = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                ShelfStore.shared.isCollapsed = true
            }
        }
    }

    public func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ShelfStore.shared.isDraggingOverShelf = false
        ShelfStore.shared.targetedAction = nil
        let handled = DropProcessor.handleDrop(sender: sender, view: self.contentView)
        if !handled && ShelfStore.shared.section == .files && ShelfStore.shared.items.isEmpty && ShelfStore.shared.pendingFilePromises == 0 && !OperationCoordinator.shared.isRunning {
            ShelfStore.shared.isCollapsed = false
            ShelfStore.shared.isPeekingFromEdgeTab = false
            ShelfStore.shared.autoCollapseAfterDrop = false
            ShelfStore.shared.hidePanel(animated: true)
        }
        return handled
    }

    public func concludeDragOperation(_ sender: NSDraggingInfo?) {
        ShelfStore.shared.isDraggingOverShelf = false
        ShelfStore.shared.targetedAction = nil
        if ShelfStore.shared.section == .files && ShelfStore.shared.items.isEmpty && ShelfStore.shared.pendingFilePromises == 0 && !OperationCoordinator.shared.isRunning {
            ShelfStore.shared.isCollapsed = false
            ShelfStore.shared.isPeekingFromEdgeTab = false
            ShelfStore.shared.autoCollapseAfterDrop = false
            ShelfStore.shared.hidePanel(animated: true)
        }
    }

    public func draggingEnded(_ sender: NSDraggingInfo) {
        GlobalDragMonitor.shared.handleAppKitDragEnded()
        ShelfStore.shared.isDraggingOverShelf = false
        ShelfStore.shared.targetedAction = nil
        if ShelfStore.shared.section == .files && ShelfStore.shared.items.isEmpty && ShelfStore.shared.pendingFilePromises == 0 && !OperationCoordinator.shared.isRunning {
            ShelfStore.shared.isCollapsed = false
            ShelfStore.shared.isPeekingFromEdgeTab = false
            ShelfStore.shared.autoCollapseAfterDrop = false
            ShelfStore.shared.hidePanel(animated: true)
        }
    }
}

public class FloatingPanelController: NSObject {
    public var panel: FloatingPanel!
    private var isVisible: Bool = false
    private var panelWidth: CGFloat { ShelfStore.shared.shelfWidth }
    private var panelHeight: CGFloat { 520 }
    private var menuBarAutoDismissTimer: Timer?

    public override init() {
        super.init()
        setupPanel()
    }

    private func setupPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let initialRect = calculateHiddenFrame(screen: screen)

        panel = FloatingPanel(contentRect: initialRect)
        let hostingView = ShelfDropHostingView(rootView: DropShelfView())
        panel.contentView = hostingView
        panel.alphaValue = 0

        ShelfStore.shared.panelController = self
        updateAppearance()
    }

    public func updateAppearance() {
        switch ShelfStore.shared.appearanceTheme {
        case .auto:
            panel.appearance = nil
        case .dark:
            panel.appearance = NSAppearance(named: .darkAqua)
        case .light:
            panel.appearance = NSAppearance(named: .aqua)
        }
    }

    public func show(animated: Bool = true) {
        guard !isVisible else { return }
        isVisible = true

        let screen = currentScreen()
        let visibleFrame = calculateVisibleFrame(screen: screen)
        let hiddenFrame = calculateHiddenFrame(screen: screen)

        panel.setFrame(hiddenFrame, display: false)
        panel.orderFrontRegardless()

        ShelfStore.shared.isPanelVisible = true

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(visibleFrame, display: true)
                panel.animator().alphaValue = 1.0
            }
        } else {
            panel.setFrame(visibleFrame, display: true)
            panel.alphaValue = 1.0
        }
    }

    public func hide(animated: Bool = true) {
        cancelMenuBarAutoDismissTimer()
        // Never hide if there are items stored on the shelf
        guard isVisible && ShelfStore.shared.items.isEmpty && ShelfStore.shared.pendingFilePromises == 0 && !OperationCoordinator.shared.isRunning else { return }
        isVisible = false

        let screen = currentScreen()
        let hiddenFrame = calculateHiddenFrame(screen: screen)

        ShelfStore.shared.isPanelVisible = false

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(hiddenFrame, display: true)
                panel.animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                if self?.isVisible == false {
                    self?.panel.orderOut(nil)
                }
            })
        } else {
            panel.setFrame(hiddenFrame, display: true)
            panel.alphaValue = 0.0
            panel.orderOut(nil)
        }
    }

    public func toggle() {
        cancelMenuBarAutoDismissTimer()
        if isVisible {
            // Force hide on manual toggle
            isVisible = false
            let screen = currentScreen()
            let hiddenFrame = calculateHiddenFrame(screen: screen)
            ShelfStore.shared.isPanelVisible = false
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(hiddenFrame, display: true)
                panel.animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                self?.panel.orderOut(nil)
            })
        } else {
            show(animated: true)
        }
    }

    public func toggleFromMenuBar() {
        if isVisible {
            cancelMenuBarAutoDismissTimer()
            toggle()
        } else {
            show(animated: true)
            startMenuBarAutoDismissTimerIfNeeded()
        }
    }

    public func startMenuBarAutoDismissTimerIfNeeded() {
        cancelMenuBarAutoDismissTimer()
        // Only start timer if shelf has no items
        guard ShelfStore.shared.section == .files && ShelfStore.shared.items.isEmpty else { return }

        menuBarAutoDismissTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Do not dismiss if the cursor is currently over the shelf window
            let mouseLoc = NSEvent.mouseLocation
            if NSMouseInRect(mouseLoc, self.panel.frame, false) {
                return
            }
            if ShelfStore.shared.section == .files && ShelfStore.shared.items.isEmpty && !ShelfStore.shared.isDraggingOverShelf {
                self.hide(animated: true)
            }
        }
    }

    public func cancelMenuBarAutoDismissTimer() {
        menuBarAutoDismissTimer?.invalidate()
        menuBarAutoDismissTimer = nil
    }

    public func updatePosition() {
        guard isVisible else { return }
        let screen = currentScreen()
        let visibleFrame = calculateVisibleFrame(screen: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(visibleFrame, display: true)
        }
    }

    private func currentScreen() -> NSScreen {
        let mouseLoc = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if NSMouseInRect(mouseLoc, screen.frame, false) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }

    private func calculateVisibleFrame(screen: NSScreen) -> NSRect {
        let edge = ShelfStore.shared.dockEdge
        let margin: CGFloat = 16
        let x: CGFloat

        switch edge {
        case .right:
            x = screen.visibleFrame.maxX - panelWidth - margin
        case .left:
            x = screen.visibleFrame.minX + margin
        }

        let effectiveHeight = min(panelHeight, screen.visibleFrame.height - 40)
        let y = screen.visibleFrame.midY - (effectiveHeight / 2)
        return NSRect(x: x, y: y, width: panelWidth, height: effectiveHeight)
    }

    private func calculateHiddenFrame(screen: NSScreen) -> NSRect {
        let edge = ShelfStore.shared.dockEdge
        let x: CGFloat

        switch edge {
        case .right:
            x = screen.frame.maxX + 20
        case .left:
            x = screen.frame.minX - panelWidth - 20
        }

        let effectiveHeight = min(panelHeight, screen.visibleFrame.height - 40)
        let y = screen.visibleFrame.midY - (effectiveHeight / 2)
        return NSRect(x: x, y: y, width: panelWidth, height: effectiveHeight)
    }
}
