import SwiftUI
import UniformTypeIdentifiers

public struct DropShelfView: View {
    @ObservedObject var store = ShelfStore.shared
    @ObservedObject var clipboard = ClipboardStore.shared
    @ObservedObject var operations = OperationCoordinator.shared
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var isShelfTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var refined: Bool { store.useRefinedClassic }
    private var palette: ClassicPalette { ClassicPalette(light: isLight) }
    private var accent: Color { refined ? palette.accent : .blue }

    private var isLight: Bool {
        store.isEffectiveLightMode
    }

    public var body: some View {
        ZStack {
            if store.isCollapsed && !store.items.isEmpty {
                EdgeTabView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: store.dockEdge == .left ? .leading : .trailing)
            } else {
                mainShelfContent
            }
        }
        .frame(width: store.shelfWidth, height: 520)
        .tint(refined ? palette.accent : .blue)
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .preferredColorScheme(store.appearanceTheme == .auto ? nil : (store.appearanceTheme == .light ? .light : .dark))
    }

    private var mainShelfContent: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            if clipboard.enabled || store.section == .clipboard {
                HStack(spacing: 3) {
                    sectionButton("Files", section: .files)
                    sectionButton("Clipboard", section: .clipboard)
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 9).fill(palette.subtle))
                .padding(.horizontal, 10).padding(.bottom, 7)
            }

            if store.section == .clipboard {
                ClipboardHistoryView(clipboard: clipboard)
            } else {
            // Transfer Mode Toggle (Copy vs Cut)
            transferModeToggle

            // Quick Action Grid (Optional / Toggleable)
            if store.showActionGrid {
                actionGridSection
                Divider()
                    .background(isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.12))
                    .padding(.horizontal, 10)
            }

            if operations.isRunning {
                OperationProgressView().padding(.horizontal, 10).padding(.bottom, 6)
            }

            // Recent Drops History Drawer (Toggleable)
            if store.isHistoryOpen {
                historyDrawerSection
                    .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
                    .background(isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.12))
                    .padding(.horizontal, 10)
            }

            // Shelf Items Area / Drop Destination
            shelfItemsSection

            Spacer(minLength: 0)

            // Footer Bar
            footerBar
            }
        }
        .frame(width: store.shelfWidth)
        .frame(maxHeight: 520)
        .background(
            ZStack {
                // Glassmorphic translucent background with density and opacity controls
                VisualEffectBlur(material: store.glassDensity.nsMaterial, blendingMode: .behindWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .opacity(store.glassOpacity)

                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        refined ? palette.surface.opacity(reduceTransparency ? 1 : max(0.88, store.glassOpacity)) : (isLight
                            ? Color.white.opacity(0.72 * store.glassOpacity)
                            : Color.black.opacity(0.48 * store.glassOpacity))
                    )

                // Ambient glow when dragging over shelf
                if isShelfTargeted || store.isDraggingOverShelf {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(
                            LinearGradient(
                                colors: refined ? [palette.accent.opacity(0.9), palette.accent.opacity(0.5)] : [accent.opacity(0.85), Color.purple.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2.5
                        )
                        .shadow(color: accent.opacity(0.5), radius: 10)
                } else {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(
                            refined ? palette.border : (isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.14)),
                            lineWidth: 1
                        )
                }
            }
        )
        .onChange(of: store.section) { section in
            store.targetedAction = nil
            if section == .clipboard { store.actionTileFrames.removeAll() }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                if store.isPeekingFromEdgeTab {
                    store.uncollapse(playSound: false, notify: true)
                }
            }
        )
        .onHover { hovering in
            if !hovering && store.isPeekingFromEdgeTab {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if store.isPeekingFromEdgeTab && !store.isDraggingOverShelf {
                        if store.items.isEmpty {
                            store.isCollapsed = false
                            store.isPeekingFromEdgeTab = false
                            store.autoCollapseAfterDrop = false
                            store.hidePanel(animated: true)
                        } else if let panel = store.panelController?.panel {
                            let mouseLoc = NSEvent.mouseLocation
                            if !NSMouseInRect(mouseLoc, panel.frame, false) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    store.isCollapsed = true
                                    store.isPeekingFromEdgeTab = false
                                }
                            }
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                store.isCollapsed = true
                                store.isPeekingFromEdgeTab = false
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionButton(_ title: String, section: ShelfSection) -> some View {
        Button {
            clipboard.prune()
            store.section = section
        } label: {
            Text(title).font(.system(size: 10, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(store.section == section ? palette.selected : Color.clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: - Header
    private var headerBar: some View {
        let layout = refined ? AnyLayout(VStackLayout(spacing: 7)) : AnyLayout(HStackLayout(spacing: 5))
        return layout {
            HStack(spacing: 5) {
            AppIconView(size: 18)
                .rotationEffect(.degrees(refined && !reduceMotion && store.isDraggingOverShelf ? -5 : 0))
                .animation(.spring(response: 0.28, dampingFraction: 0.65), value: store.isDraggingOverShelf)

            Text("DropShelf")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(refined ? palette.text : (isLight ? Color.black.opacity(0.88) : .white))
                .lineLimit(1)
                .fixedSize()

            if (store.section == .clipboard ? !clipboard.entries.isEmpty : !store.items.isEmpty) {
                Text("\(store.section == .clipboard ? clipboard.entries.count : store.totalFileCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(refined ? palette.accent : .white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(refined ? palette.selected : accent.opacity(0.8))
                    )
            }

            Spacer(minLength: 0)
            }

            HStack(spacing: refined ? 12 : 4) {
                if store.section == .files {
                // Recent Drops History Drawer Toggle
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        store.section = .files
                        store.isHistoryOpen.toggle()
                    }
                }) {
                    ZStack(alignment: .topTrailing) {
                        BrandIconView(.history, size: 14)
                            .font(.system(size: 11))
                            .foregroundColor(store.isHistoryOpen ? accent : (refined ? palette.muted : (isLight ? Color.black.opacity(0.7) : Color.white.opacity(0.7))))
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: refined ? 7 : 11).fill(
                                    store.isHistoryOpen
                                        ? accent.opacity(0.18)
                                        : (refined ? palette.subtle : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.1)))
                                )
                            )

                        if !store.historyItems.isEmpty {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                                .offset(x: 1, y: -1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isHistoryOpen ? "Hide recent drops" : "Show recent drops")
                .help(store.isHistoryOpen ? "Hide Recent Drops History" : "Recent Drops History (\(store.historyItems.count) items)")

                // Toggle Action Grid
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        store.showActionGrid.toggle()
                        store.savePreferences()
                    }
                }) {
                    ShelfSymbol(systemName: store.showActionGrid ? "square.grid.2x2.fill" : "square.grid.2x2")
                        .font(.system(size: 11))
                        .foregroundColor(store.showActionGrid ? (refined ? palette.onAccent : .blue) : (refined ? palette.muted : (isLight ? Color.black.opacity(0.7) : Color.white.opacity(0.7))))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: refined ? 7 : 11).fill(refined ? (store.showActionGrid ? palette.accent : palette.subtle) : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.1))))
                }
                .buttonStyle(.plain)
                .help("Toggle Quick Action Grid")

                }

                // Settings
                Button(action: {
                    PreferencesWindowController.shared.show()
                }) {
                    BrandIconView(.settings, size: 14)
                        .font(.system(size: 11))
                        .foregroundColor(refined ? palette.muted : (isLight ? Color.black.opacity(0.7) : Color.white.opacity(0.7)))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: refined ? 7 : 11).fill(refined ? palette.subtle : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.1))))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preferences")
                .help("Preferences")

                // Single Collapse / Uncollapse Toggle Button
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        if store.isPeekingFromEdgeTab {
                            store.uncollapse()
                        } else {
                            store.collapseToEdgeTab()
                        }
                    }
                }) {
                    ShelfSymbol(systemName: store.isPeekingFromEdgeTab
                          ? (store.dockEdge == .right ? "chevron.left.2" : "chevron.right.2")
                          : (store.dockEdge == .right ? "chevron.right.2" : "chevron.left.2"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(store.isPeekingFromEdgeTab ? accent : (refined ? palette.muted : (isLight ? Color.black.opacity(0.7) : Color.white.opacity(0.7))))
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: refined ? 7 : 11).fill(store.isPeekingFromEdgeTab ? accent.opacity(0.18) : (refined ? palette.subtle : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.1))))
                        )
                }
                .buttonStyle(.plain)
                .help(store.isPeekingFromEdgeTab ? "Keep uncollapsed" : "Collapse to edge tab")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Transfer Mode Toggle (Copy vs Cut)
    private var transferModeToggle: some View {
        HStack(spacing: 0) {
            // Copy Mode Button
            Button(action: {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                    store.transferMode = .copy
                    store.savePreferences()
                    store.playSound("Pop")
                    store.showStatus(message: "Copy Mode: files will be duplicated")
                }
            }) {
                HStack(spacing: 5) {
                    BrandIconView(.moveCopy, size: 14)
                        .font(.system(size: 10, weight: .bold))
                    Text("Copy")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(store.transferMode == .copy ? (refined ? palette.onAccent : .white) : (isLight ? Color.black.opacity(0.6) : Color.white.opacity(0.55)))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(
                    ZStack {
                        if store.transferMode == .copy {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: refined ? [palette.accent, palette.accent] : [accent, Color.cyan],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .shadow(color: accent.opacity(refined ? 0 : 0.4), radius: 6, x: 0, y: 2)
                        }
                    }
                )
            }
            .buttonStyle(.plain)

            // Cut / Move Mode Button
            Button(action: {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                    store.transferMode = .cut
                    store.savePreferences()
                    store.playSound("Pop")
                    store.showStatus(message: "Cut Mode: files will be moved from source")
                }
            }) {
                HStack(spacing: 5) {
                    ShelfSymbol(systemName: "scissors")
                        .font(.system(size: 10, weight: .bold))
                    Text("Cut")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(store.transferMode == .cut ? (refined ? palette.onAccent : .white) : (isLight ? Color.black.opacity(0.6) : Color.white.opacity(0.55)))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(
                    ZStack {
                        if store.transferMode == .cut {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: refined ? [palette.warm, palette.warm] : [Color.orange, Color.pink],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .shadow(color: Color.orange.opacity(refined ? 0 : 0.4), radius: 6, x: 0, y: 2)
                        }
                    }
                )
            }
            .buttonStyle(.plain)
        }
        .padding(3)
        .background(
            Capsule()
                .fill(refined ? palette.subtle : (isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.08)))
                .overlay(
                    Capsule()
                        .stroke(
                            refined ? palette.border : (store.transferMode == .cut ? Color.orange.opacity(0.3) : accent.opacity(0.3)),
                            lineWidth: 1
                        )
                )
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Quick Action Grid
    private var actionGridSection: some View {
        VStack(spacing: refined ? 10 : 0) {
            HStack(spacing: 4) {
                ForEach(refined ? Array(ActionType.allCases.prefix(4)) : ActionType.allCases) { action in
                    ActionTileView(action: action)
                }
            }
            if refined {
                HStack(spacing: 4) {
                    ForEach(Array(ActionType.allCases.dropFirst(4))) { action in
                        ActionTileView(action: action)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(refined ? palette.subtle : (isLight ? Color.black.opacity(0.04) : Color.white.opacity(0.05)))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Recent Drops History Drawer
    private var historyDrawerSection: some View {
        VStack(spacing: 8) {
            // History Header
            HStack {
                HStack(spacing: 5) {
                    BrandIconView(.history, size: 14)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.orange)
                    Text(refined ? "Recent" : "Recent Drops")
                        .lineLimit(1)
                        .fixedSize()
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isLight ? Color.black.opacity(0.85) : .white)

                    if !refined && !store.historyItems.isEmpty {
                        Text("\(store.historyItems.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange))
                    }
                }

                Spacer()

                if !store.historyItems.isEmpty {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            store.restoreAllHistory()
                        }
                    }) {
                        Text(refined ? "All" : "Restore All")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Restore all recently removed items back to shelf")

                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            store.clearHistory()
                        }
                    }) {
                        BrandIconView(.clear, size: 13)
                            .font(.system(size: 10))
                            .foregroundColor(isLight ? Color.black.opacity(0.5) : Color.white.opacity(0.5))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear history")
                    .help("Clear history")
                }

                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        store.isHistoryOpen = false
                    }
                }) {
                    ShelfSymbol(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isLight ? Color.black.opacity(0.5) : Color.white.opacity(0.5))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Close history drawer")
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)

            Divider()
                .background(isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.1))

            if store.historyItems.isEmpty {
                VStack(spacing: 5) {
                    BrandIconView(.shelf, size: 24)
                        .font(.system(size: 20))
                        .foregroundColor(isLight ? Color.black.opacity(0.3) : Color.white.opacity(0.3))
                    Text("No recent drops")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isLight ? Color.black.opacity(0.5) : Color.white.opacity(0.5))
                    Text("Cleared or dropped items appear here for instant recovery.")
                        .font(.system(size: 10))
                        .foregroundColor(isLight ? Color.black.opacity(0.4) : Color.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 6) {
                        ForEach(store.historyItems) { item in
                            HStack(spacing: 8) {
                                if let img = item.thumbnail {
                                    Image(nsImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 26, height: 26)
                                        .cornerRadius(4)
                                } else {
                                    ShelfSymbol(systemName: "doc.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(accent)
                                        .frame(width: 26, height: 26)
                                }

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(isLight ? Color.black.opacity(0.85) : .white)
                                        .lineLimit(1)
                                    Text(item.subtitle)
                                        .font(.system(size: 9))
                                        .foregroundColor(isLight ? Color.black.opacity(0.5) : Color.white.opacity(0.5))
                                        .lineLimit(1)
                                }

                                Spacer()

                                Button(action: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        store.restoreFromHistory(item: item)
                                    }
                                }) {
                                    HStack(spacing: 3) {
                                        ShelfSymbol(systemName: "arrow.uturn.backward")
                                            .font(.system(size: 8, weight: .bold))
                                        Text(refined ? "" : "Restore")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(accent))
                                }
                                .buttonStyle(.plain)
                                .help("Restore this item back onto shelf")
                            }
                            .padding(5)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isLight ? Color.black.opacity(0.04) : Color.white.opacity(0.06))
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: refined ? 115 : 180)
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(refined ? palette.subtle : (isLight ? Color.black.opacity(0.03) : Color.white.opacity(0.04)))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Shelf Items
    private var shelfItemsSection: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                emptyStateDropTarget
            } else {
                // Show controls bar when multiple items exist, or when stacked, or when active selections exist
                if store.canStackOrUnstack || !store.selectedItemIDs.isEmpty {
                    stackAndSelectionControls
                }

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        ForEach(store.items) { item in
                            ShelfItemCardView(item: item)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 240)
            }
        }
    }

    // MARK: - Toolbar Controls Bar
    private var stackAndSelectionControls: some View {
        let layout = refined ? AnyLayout(VStackLayout(spacing: 5)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            HStack(spacing: 8) {
            // Drag All Handle (when multiple items exist on shelf or single stack)
            if store.items.count > 1 || store.isSingleStack {
                DragAllPillRepresentable()
                    .frame(width: 78, height: 22)
                    .help("Click and drag to drop all files on the shelf together")
            }

            Spacer()

            // Stack / Unstack All Button (between Drag All and Select All)
            if store.canStackOrUnstack {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        store.toggleStackAll()
                    }
                }) {
                    HStack(spacing: 4) {
                        Group {
                            if store.hasStackedItems { ShelfSymbol(systemName: "square.split.2x1") }
                            else { BrandIconView(.multiple, size: 14) }
                        }
                            .font(.system(size: 10))
                        Text(store.hasStackedItems ? "Unstack" : (refined ? "Stack" : "Stack All"))
                            .lineLimit(1)
                            .fixedSize()
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(store.hasStackedItems ? .white : (isLight ? Color.black.opacity(0.75) : Color.white.opacity(0.85)))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        Capsule().fill(store.hasStackedItems ? accent : (refined ? palette.subtle : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.1))))
                    )
                    .overlay(
                        Capsule().stroke(
                            store.hasStackedItems ? accent.opacity(0.5) : (isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.12)),
                            lineWidth: 0.5
                        )
                    )
                }
                .buttonStyle(.plain)
                .help(store.hasStackedItems ? "Unstack files into individual items" : "Combine all files into 1 stack")
            }

            Spacer()

            }
            // Selection Controls
            if !store.selectedItemIDs.isEmpty {
                HStack(spacing: 6) {
                    Text("\(store.selectedItemIDs.count) selected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isLight ? Color.black.opacity(0.6) : Color.white.opacity(0.6))
                        .lineLimit(1)

                    if store.selectedItemIDs.count > 1 {
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                store.stackSelected()
                            }
                        }) {
                            HStack(spacing: 3) {
                                BrandIconView(.multiple, size: 13)
                                    .font(.system(size: 9))
                                Text("Stack")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(accent))
                        }
                        .buttonStyle(.plain)
                        .help("Stack selected files together")
                    }

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            store.deselectAll()
                        }
                    }) {
                        ShelfSymbol(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(isLight ? Color.black.opacity(0.6) : Color.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Deselect all")
                }
            } else if store.items.count > 1 {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        store.selectAll()
                    }
                }) {
                    Text("Select All")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isLight ? Color.black.opacity(0.65) : Color.white.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule().fill(isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                        )
                        .overlay(
                            Capsule().stroke(
                                isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.12),
                                lineWidth: 0.5
                            )
                        )
                }
                .buttonStyle(.plain)
                .help("Select all items (Cmd+A)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var emptyStateDropTarget: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isShelfTargeted ? accent.opacity(0.25) : (isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.06)))
                    .frame(width: 60, height: 60)

                BrandIconView(.drop, size: 32)
                    .font(.system(size: 26))
                    .foregroundColor(isShelfTargeted ? .blue : (isLight ? Color.black.opacity(0.6) : Color.white.opacity(0.6)))
                    .scaleEffect(isShelfTargeted ? 1.2 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isShelfTargeted)
            }

            VStack(spacing: 4) {
                Text(isShelfTargeted ? "Release to Shelf" : "Drop anything here")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isLight ? Color.black.opacity(0.88) : Color.white.opacity(0.9))

                Text(refined ? "Files, images, links,\ncolors, or text" : "Files, images, links, color hexes, or text")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11))
                    .foregroundColor(isLight ? Color.black.opacity(0.5) : Color.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, refined ? 24 : 36)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .foregroundColor(isShelfTargeted ? accent.opacity(0.8) : (isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.15)))
                .padding(10)
        )
    }

    // MARK: - Footer
    private var footerBar: some View {
        HStack {
            if store.pendingFilePromises > 0 {
                ProgressView().controlSize(.small)
                Text("Receiving files…").font(.system(size: 10))
            } else if let status = store.statusMessage {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)

                    Text(status)
                        .lineLimit(2)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isLight ? Color.black.opacity(0.88) : Color.white.opacity(0.9))
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Text(refined ? "Drag to any app" : "Drag out to any app or Finder")
                    .font(.system(size: 10))
                    .foregroundColor(isLight ? Color.black.opacity(0.45) : Color.white.opacity(0.4))
            }

            Spacer()

            if !store.items.isEmpty {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        store.clearAll()
                    }
                }) {
                    HStack(spacing: 4) {
                        BrandIconView(.clear, size: 13)
                            .font(.system(size: 10))
                        Text("Clear")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(isLight ? Color.black.opacity(0.65) : Color.white.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .help("Clear unlocked items (saved to Recent Drops)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(refined ? palette.subtle : (isLight ? Color.black.opacity(0.02) : Color.white.opacity(0.03)))
    }
}

// Visual Effect Blur Helper
public struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Drag All Toolbar Handle

public struct DragAllPillRepresentable: NSViewRepresentable {
    public func makeNSView(context: Context) -> DragAllPillView {
        return DragAllPillView()
    }
    public func updateNSView(_ nsView: DragAllPillView, context: Context) {
        nsView.needsDisplay = true
    }
}

public class DragAllPillView: NSView, NSDraggingSource {
    private var downEvent: NSEvent?
    private var isDragging = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 72, height: 20))
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isLight = ShelfStore.shared.isEffectiveLightMode
        let refined = ShelfStore.shared.useRefinedClassic
        let palette = ClassicPalette(light: isLight)
        let path = NSBezierPath(roundedRect: bounds, xRadius: refined ? 7 : 10, yRadius: refined ? 7 : 10)
        (refined ? NSColor(palette.subtle) : NSColor(calibratedWhite: isLight ? 0.0 : 1.0, alpha: isLight ? 0.08 : 0.12)).setFill()
        path.fill()

        let stroke = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5)
        (refined ? NSColor(palette.border) : NSColor(calibratedWhite: isLight ? 0.0 : 1.0, alpha: isLight ? 0.16 : 0.22)).setStroke()
        stroke.lineWidth = 1
        stroke.stroke()

        let text = "Drag All"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(calibratedWhite: isLight ? 0.1 : 1.0, alpha: isLight ? 0.85 : 0.88),
            .font: NSFont.systemFont(ofSize: 9.5, weight: .bold)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let rect = NSRect(
            x: 24,
            y: (bounds.height - size.height) / 2 - 0.5,
            width: size.width,
            height: size.height
        )
        if let image = refined ? RefinedAssets.image("stack") : BrandAssets.icon(.multiple) {
            let glyphSize = NSSize(width: 15, height: 15)
            let tinted = NSImage(size: glyphSize, flipped: false) { bounds in
                image.draw(in: bounds)
                NSColor(calibratedWhite: isLight ? 0.1 : 1.0, alpha: 0.88).setFill()
                bounds.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: NSRect(x: 7, y: (bounds.height - 15) / 2, width: 15, height: 15))
        }
        str.draw(in: rect)
    }

    public override func mouseDown(with event: NSEvent) {
        self.downEvent = event
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let start = downEvent, !isDragging else { return }
        let dx = abs(event.locationInWindow.x - start.locationInWindow.x)
        let dy = abs(event.locationInWindow.y - start.locationInWindow.y)
        guard dx > 3 || dy > 3 else { return }

        let allURLs = ShelfStore.shared.items.flatMap { $0.fileURLs }
        guard !allURLs.isEmpty else { return }
        isDragging = true
        downEvent = nil

        let items = ShelfDragPreview.makeItems(urls: allURLs)
        self.beginDraggingSession(with: items, event: event, source: self)
    }

    public override func mouseUp(with event: NSEvent) {
        isDragging = false
        downEvent = nil
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
        guard operation != [] else { return }
        DispatchQueue.main.async {
            for itm in ShelfStore.shared.items where !itm.isLocked {
                ShelfStore.shared.removeItem(id: itm.id)
            }
        }
    }
}

