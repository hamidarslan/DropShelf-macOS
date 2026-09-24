import SwiftUI

public struct EdgeTabView: View {
    @ObservedObject var store = ShelfStore.shared
    @State private var isHovering = false
    private var palette: ClassicPalette { ClassicPalette(light: store.isEffectiveLightMode) }

    public var body: some View {
        if store.items.isEmpty {
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear {
                    store.isCollapsed = false
                    store.isPeekingFromEdgeTab = false
                    store.autoCollapseAfterDrop = false
                    store.hidePanel(animated: false)
                }
        } else {
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    store.uncollapse()
                }
            }) {
                HStack(spacing: 6) {
                    contentBody
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(store.useRefinedClassic ? palette.surface : Color.black.opacity(0.75))
                        .overlay(
                            Capsule()
                                .stroke(store.useRefinedClassic ? palette.border : Color.white.opacity(isHovering ? 0.35 : 0.15), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 3)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
                if hovering && !store.items.isEmpty {
                    store.isPeekingFromEdgeTab = true
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        store.isCollapsed = false
                    }
                }
            }
        }
    }

    private var contentBody: some View {
        VStack(spacing: 4) {
            AppIconView(size: 20)

            if !store.items.isEmpty {
                Text("\(store.totalFileCount)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(store.useRefinedClassic ? palette.onAccent : .white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(store.useRefinedClassic ? palette.accent : .blue)
                    )
            }
        }
    }
}
