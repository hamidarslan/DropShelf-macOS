import Cocoa
import CoreGraphics
import SwiftUI

// Tracks pasteboard revisions so ordinary window movement cannot start a content drag.
struct ContentDragSession {
    var lastChangeCount: Int
    private(set) var isActive = false
    private(set) var suppressesActivationUntilMouseUp = false

    mutating func observe(changeCount: Int, hasContent: Bool, mouseDown: Bool, enabled: Bool) -> Bool {
        guard mouseDown else {
            lastChangeCount = changeCount
            isActive = false
            suppressesActivationUntilMouseUp = false
            return false
        }
        guard !suppressesActivationUntilMouseUp else {
            isActive = false
            return false
        }
        guard enabled else {
            lastChangeCount = changeCount
            isActive = false
            return false
        }
        guard changeCount != lastChangeCount, hasContent else { return false }
        lastChangeCount = changeCount
        guard !isActive else { return false }
        isActive = true
        return true
    }

    mutating func end(suppressUntilMouseUp: Bool = false) {
        isActive = false
        suppressesActivationUntilMouseUp = suppressUntilMouseUp
    }

    static func shouldSummonOnStart(enabled: Bool, shakeOnly: Bool) -> Bool {
        enabled && !shakeOnly
    }
}

public class GlobalDragMonitor {
    public static let shared = GlobalDragMonitor()

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var pollTimer: Timer?

    private var session = ContentDragSession(lastChangeCount: -1)
    private var lastDragLocation: NSPoint?
    private var lastDragMovementTime: TimeInterval = 0
    private let dragIdleInterval: TimeInterval = 0.8
    private var dragHistory: [(point: NSPoint, time: TimeInterval)] = []
    private var lastShakeSummonTime: TimeInterval = 0

    private init() {}

    public func start() {
        stop()

        session = ContentDragSession(lastChangeCount: NSPasteboard(name: .drag).changeCount)

        // 1. High-frequency, permissionless pasteboard and cursor polling timer (~30 Hz)
        // Works across all apps (Finder, Safari, etc.) without requiring Accessibility TCC permissions
        let timer = Timer(timeInterval: 0.035, repeats: true) { [weak self] _ in
            self?.pollDragState()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // 2. Global event monitors for non-modal drag states
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleMouseEvent(event)
        }

        // 3. Local monitor for within-app interactions
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        if let global = globalMouseMonitor {
            NSEvent.removeMonitor(global)
            globalMouseMonitor = nil
        }
        if let local = localMouseMonitor {
            NSEvent.removeMonitor(local)
            localMouseMonitor = nil
        }

        session.end()
        ShelfStore.shared.isContentDragActive = false
        lastDragLocation = nil
        lastDragMovementTime = 0
        dragHistory.removeAll()
        lastShakeSummonTime = 0
    }

    // MARK: - Polling Engine (Cross-App System Drag Detection)

    private func pollDragState(mouseDownOverride: Bool? = nil) {
        let pasteboard = NSPasteboard(name: .drag)
        let mouseDown = mouseDownOverride ?? (
            CGEventSource.buttonState(.combinedSessionState, button: .left)
                || (NSEvent.pressedMouseButtons & 1) != 0
        )
        processDragSample(changeCount: pasteboard.changeCount,
                          hasContent: Self.hasDraggableContent(pasteboard: pasteboard),
                          mouseDown: mouseDown, location: NSEvent.mouseLocation,
                          time: ProcessInfo.processInfo.systemUptime)
    }

    func processDragSample(changeCount: Int, hasContent: Bool, mouseDown: Bool,
                           location: NSPoint, time: TimeInterval) {
        let store = ShelfStore.shared
        let wasActive = session.isActive
        let started = session.observe(changeCount: changeCount, hasContent: hasContent,
                                      mouseDown: mouseDown, enabled: store.autoShowOnDrag)
        if store.isContentDragActive != session.isActive {
            store.isContentDragActive = session.isActive
        }
        if wasActive && !session.isActive {
            handleDragEnded(wasDragging: true)
            return
        }
        guard session.isActive else { return }
        if started {
            store.section = .files
            lastDragLocation = location
            lastDragMovementTime = time
            dragHistory.removeAll()
            if ContentDragSession.shouldSummonOnStart(enabled: store.autoShowOnDrag, shakeOnly: store.shakeOnlyToShow) {
                triggerSummon(reason: "start")
            }
        }

        // A drag keeps its pasteboard revision while leaving and re-entering the shelf.
        // Track movement for its whole lifetime, including while the panel is hidden.
        let moved = lastDragLocation.map { hypot(location.x - $0.x, location.y - $0.y) >= 1 } ?? false
        if moved {
            lastDragLocation = location
            lastDragMovementTime = time
            if !store.shakeOnlyToShow && !store.isPanelVisible {
                triggerSummon(reason: "motion")
            }
        }

        let pointerInsidePanel = store.panelController?.panel.frame.contains(location) ?? false
        if time - lastDragMovementTime >= dragIdleInterval,
           store.section == .files, store.isPanelVisible, store.items.isEmpty,
           !store.isDraggingOverShelf, !pointerInsidePanel,
           store.pendingFilePromises == 0, !OperationCoordinator.shared.isRunning {
            store.isCollapsed = false
            store.isPeekingFromEdgeTab = false
            store.autoCollapseAfterDrop = false
            store.hidePanel(animated: true)
        }

        guard store.shakeOnlyToShow else { return }
        let now = time
        dragHistory.append((point: location, time: now))
        dragHistory.removeAll { now - $0.time >= 0.40 }
        if detectShakeGesture(), now - lastShakeSummonTime > 1.2 {
            lastShakeSummonTime = now
            triggerSummon(reason: "shake")
        }
    }

    // MARK: - Event Handler Fallback

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            pollDragState(mouseDownOverride: true)
        case .leftMouseUp:
            pollDragState(mouseDownOverride: false)
        default:
            break
        }
    }

    func handleAppKitDragEnded() {
        let wasDragging = session.isActive
        handleDragEnded(wasDragging: wasDragging, suppressUntilMouseUp: true)
        ShelfStore.shared.isContentDragActive = session.isActive
    }

    private func triggerSummon(reason: String) {
        let store = ShelfStore.shared
        store.panelController?.cancelMenuBarAutoDismissTimer()
        if store.isCollapsed || store.isPeekingFromEdgeTab {
            // A temporary drag expansion must return to the tab after the drop.
            store.autoCollapseAfterDrop = true
            store.isPeekingFromEdgeTab = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                store.isCollapsed = false
            }
        }
        if !store.isPanelVisible { store.playSound("Pop") }
        store.showPanel(animated: true)
    }

    private func handleDragEnded(wasDragging: Bool, suppressUntilMouseUp: Bool = false) {
        session.end(suppressUntilMouseUp: suppressUntilMouseUp)
        lastDragLocation = nil
        lastDragMovementTime = 0
        dragHistory.removeAll()
        guard wasDragging else { return }

        // Allow AppKit's drop callback to enqueue its items before hiding an empty shelf.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, !self.session.isActive else { return }
            let store = ShelfStore.shared
            guard store.section == .files else { return }
            if store.items.isEmpty && store.pendingFilePromises == 0 && !OperationCoordinator.shared.isRunning {
                store.isCollapsed = false
                store.isPeekingFromEdgeTab = false
                store.autoCollapseAfterDrop = false
                store.hidePanel(animated: true)
            } else if store.autoCollapseAfterDrop {
                store.autoCollapseAfterDrop = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    store.isCollapsed = true
                }
            }
        }
    }

    static func hasDraggableContent(pasteboard: NSPasteboard) -> Bool {
        if pasteboard.types?.contains(ClipboardPasteboard.privateType) == true { return false }
        guard let types = pasteboard.types, !types.isEmpty else { return false }
        let validTypes: Set<NSPasteboard.PasteboardType> = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .URL,
            .string,
            .rtf,
            .html,
            .tiff,
            .png,
            NSPasteboard.PasteboardType("public.data"),
            NSPasteboard.PasteboardType("public.item")
        ]
        return types.contains { validTypes.contains($0) || NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue) }
    }

    // MARK: - Gesture Detectors

    private func detectShakeGesture() -> Bool {
        guard dragHistory.count >= 4 else { return false }
        var xDirectionChanges = 0
        var yDirectionChanges = 0
        var lastDeltaX: CGFloat = 0
        var lastDeltaY: CGFloat = 0
        var totalTravel: CGFloat = 0

        for i in 1..<dragHistory.count {
            let deltaX = dragHistory[i].point.x - dragHistory[i-1].point.x
            let deltaY = dragHistory[i].point.y - dragHistory[i-1].point.y
            totalTravel += abs(deltaX) + abs(deltaY)

            // Horizontal reversals
            if (deltaX > 10 && lastDeltaX < -10) || (deltaX < -10 && lastDeltaX > 10) {
                xDirectionChanges += 1
            }
            if abs(deltaX) > 6 {
                lastDeltaX = deltaX
            }

            // Vertical reversals
            if (deltaY > 10 && lastDeltaY < -10) || (deltaY < -10 && lastDeltaY > 10) {
                yDirectionChanges += 1
            }
            if abs(deltaY) > 6 {
                lastDeltaY = deltaY
            }
        }

        // Must have at least 3 distinct direction reversals and significant movement
        return (xDirectionChanges >= 3 || yDirectionChanges >= 3) && totalTravel > 55
    }

}
