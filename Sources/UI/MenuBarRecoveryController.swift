import AppKit

enum MenuBarRecoveryPlacement {
    static let size = NSSize(width: 124, height: 32)

    private static func valid(_ rect: NSRect) -> Bool {
        [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.size.width > 0 && rect.size.height > 0
    }

    static func usableBand(visibleFrame: NSRect, screenFrame: NSRect, topInset: CGFloat) -> NSRect? {
        guard valid(visibleFrame), valid(screenFrame), topInset.isFinite, topInset >= 0 else { return nil }
        let visible = visibleFrame.intersection(screenFrame)
        let ceiling = min(visible.maxY, screenFrame.maxY - topInset)
        let band = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: ceiling - visible.minY)
        return valid(band) ? band : nil
    }

    static func frame(in usableRect: NSRect) -> NSRect? {
        guard valid(usableRect), usableRect.width >= size.width + 12,
              usableRect.height >= size.height + 10 else { return nil }
        let frame = NSRect(x: usableRect.maxX - size.width - 12,
                           y: usableRect.maxY - size.height - 10,
                           width: size.width, height: size.height)
        return valid(frame) && usableRect.contains(frame) ? frame : nil
    }
}

@MainActor final class MenuBarRecoveryController: NSObject {
    private var panel: RecoveryPanel?
    private var revealAction: (() -> Void)?

    var isPresented: Bool {
        guard let panel, panel.isVisible, !panel.isMiniaturized, panel.alphaValue > 0 else { return false }
        return NSScreen.screens.contains { screen in
            guard let band = usableBand(on: screen) else { return false }
            return band.contains(panel.frame)
        }
    }

    @discardableResult
    func show(on screen: NSScreen, reveal: @escaping () -> Void) -> Bool {
        guard let band = usableBand(on: screen), let frame = MenuBarRecoveryPlacement.frame(in: band) else {
            hide()
            return false
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        revealAction = reveal
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        guard isPresented else { hide(); return false }
        return true
    }

    func hide() {
        panel?.orderOut(nil)
        revealAction = nil
    }

    private func usableBand(on screen: NSScreen) -> NSRect? {
        MenuBarRecoveryPlacement.usableBand(visibleFrame: screen.visibleFrame, screenFrame: screen.frame,
            topInset: max(NSStatusBar.system.thickness, screen.safeAreaInsets.top))
    }

    private func makePanel() -> RecoveryPanel {
        let panel = RecoveryPanel(contentRect: NSRect(origin: .zero, size: MenuBarRecoveryPlacement.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Menu Bar Recovery"
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none

        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: MenuBarRecoveryPlacement.size))
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 16
        material.layer?.masksToBounds = true

        let button = RecoveryButton(frame: material.bounds)
        button.title = "Show icons"
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        button.imagePosition = .imageLeft
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .labelColor
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.focusRingType = .none
        button.autoresizingMask = [.width, .height]
        button.target = self
        button.action = #selector(revealIcons)
        button.setAccessibilityLabel("Show menu bar icons")
        button.setAccessibilityHelp("Reveal icons hidden by DropShelf")
        material.addSubview(button)
        panel.contentView = material
        return panel
    }

    @objc private func revealIcons() {
        revealAction?()
    }

    private final class RecoveryPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class RecoveryButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
