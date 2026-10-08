import SwiftUI

enum PreferencesSection: String, CaseIterable {
    case general = "General"
    case menuBar = "Menu Bar"
    case autoQuit = "Auto Quit"

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .menuBar: return "menubar.rectangle"
        case .autoQuit: return "power"
        }
    }
}

@MainActor final class PreferencesNavigation: ObservableObject {
    @Published var selection: PreferencesSection = .general
}

struct PreferencesRootView: View {
    @ObservedObject var navigation: PreferencesNavigation
    @ObservedObject private var shelf = ShelfStore.shared
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ClassicPalette { ClassicPalette(light: colorScheme == .light) }
    private var preferredScheme: ColorScheme? {
        switch shelf.appearanceTheme {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    AppIconView(size: 26)
                    Text("DropShelf").font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.top, 20)

                VStack(spacing: 4) {
                    ForEach(PreferencesSection.allCases, id: \.self) { section in
                        Button {
                            navigation.selection = section
                        } label: {
                            Label(section.rawValue, systemImage: section.symbol)
                                .font(.system(size: 12, weight: navigation.selection == section ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .foregroundColor(navigation.selection == section ? palette.accent : palette.text)
                                .background(RoundedRectangle(cornerRadius: 7).fill(navigation.selection == section ? palette.selected : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(navigation.selection == section ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 8)
                Spacer()
                Text("Files. Clipboard.\nA quieter menu bar.")
                    .font(.system(size: 10))
                    .foregroundColor(palette.muted)
                    .lineSpacing(3)
                    .padding(16)
            }
            .frame(width: 136)
            .background(palette.subtle)
            Rectangle().fill(palette.border).frame(width: 1)
            Group {
                if navigation.selection == .general {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("General").font(.system(size: 20, weight: .semibold))
                            .padding(.horizontal, 18).padding(.top, 22)
                        Text("Make DropShelf feel at home.")
                            .font(.system(size: 11)).foregroundColor(palette.muted)
                            .padding(.horizontal, 18)
                        SettingsView(embedded: true)
                    }
                } else if navigation.selection == .menuBar {
                    MenuBarOrganizerSettingsView()
                } else {
                    AutoQuitSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundColor(palette.text)
        .background(palette.surface)
        .preferredColorScheme(preferredScheme)
        .onChange(of: navigation.selection) { selection in
            if selection != .menuBar {
                MenuBarOrganizerController.shared.endArranging()
                MenuBarOrganizerController.shared.cancelShortcutRecording()
            }
        }
    }
}
