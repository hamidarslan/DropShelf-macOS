import SwiftUI

public struct SettingsView: View {
    @ObservedObject var store = ShelfStore.shared
    @ObservedObject var clipboard = ClipboardStore.shared
    @Environment(\.presentationMode) var presentationMode
    public var onDismiss: (() -> Void)? = nil

    @State private var quickActionStatus: String? = nil
    @State private var cliStatus: String? = nil

    public init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }

    init(clipboard: ClipboardStore) {
        self.clipboard = clipboard
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                BrandIconView(.settings, size: 20)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.blue)

                Text("DropShelf Preferences")
                    .font(.system(size: 15, weight: .semibold))

                Spacer()

                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                    onDismiss?()
                }) {
                    ShelfSymbol(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 12)

            Divider()

            // Scrollable Settings Content
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    // Appearance Theme
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Appearance")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)

                        Picker("", selection: $store.appearanceTheme) {
                            ForEach(AppearanceTheme.allCases, id: \.self) { theme in
                                Text(theme.rawValue).tag(theme)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: store.appearanceTheme) { _ in
                            store.savePreferences()
                            store.panelController?.updateAppearance()
                        }
                    }

                    // Glass Density & Opacity
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Glass Opacity")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(store.glassOpacity * 100))%")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.blue)
                        }

                        Slider(value: $store.glassOpacity, in: 0.40...1.0, step: 0.05)
                            .onChange(of: store.glassOpacity) { _ in
                                store.savePreferences()
                            }

                        HStack {
                            Text("Glass Material")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Picker("", selection: $store.glassDensity) {
                                ForEach(GlassDensity.allCases, id: \.self) { density in
                                    Text(density.rawValue).tag(density)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 140)
                            .onChange(of: store.glassDensity) { _ in
                                store.savePreferences()
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shelf Design").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                        Picker("Shelf Design", selection: Binding(get: { store.useRefinedClassic }, set: { store.setRefinedClassic($0) })) {
                            Text("Original").tag(false)
                            Text("Classic Refined").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    Divider()

                    // Screen Edge Dock
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dock Position")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)

                        Picker("", selection: $store.dockEdge) {
                            ForEach(DockEdge.allCases, id: \.self) { edge in
                                Text(edge.rawValue).tag(edge)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: store.dockEdge) { _ in
                            store.savePreferences()
                            store.panelController?.updatePosition()
                        }
                    }

                    Divider()

                    // Behaviors
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Behaviors")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)

                        Toggle("Automatically show shelf when dragging", isOn: $store.autoShowOnDrag)
                            .toggleStyle(.checkbox)
                            .onChange(of: store.autoShowOnDrag) { _ in store.savePreferences() }

                        Toggle("Require a shake to show the shelf", isOn: $store.shakeOnlyToShow)
                            .toggleStyle(.checkbox)
                            .disabled(!store.autoShowOnDrag)
                            .help("Off by default: the shelf appears as soon as a content drag starts. Turn on to summon it by shaking while dragging.")
                            .onChange(of: store.shakeOnlyToShow) { _ in store.savePreferences() }

                        Toggle("Automatically combine multiple files into a stack", isOn: $store.autoStackMultiple)
                            .toggleStyle(.checkbox)
                            .onChange(of: store.autoStackMultiple) { _ in store.savePreferences() }

                        Toggle("Show Quick Action Grid (Zip, Path, Share, etc.)", isOn: $store.showActionGrid)
                            .toggleStyle(.checkbox)
                            .onChange(of: store.showActionGrid) { _ in store.savePreferences() }

                        Toggle("Play sound effects on drag & drop", isOn: $store.enableSoundEffects)
                            .toggleStyle(.checkbox)
                            .onChange(of: store.enableSoundEffects) { _ in store.savePreferences() }

                        Toggle("Launch DropShelf at login", isOn: Binding(
                            get: { store.launchAtLogin },
                            set: { store.setLaunchAtLogin($0) }
                        ))
                        .toggleStyle(.checkbox)
                    }

                    Divider()

                    ClipboardSettingsSection(clipboard: clipboard)

                    Divider()

                    BackgroundModelStatusView(allowsRemoval: true)

                    Divider()

                    // Integrations & Shortcuts
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Integrations & CLI")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)

                        // Finder Quick Action
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Finder Context Menu")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Right-click files in Finder > Send to DropShelf")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: {
                                let res = IntegrationManager.shared.installQuickAction()
                                quickActionStatus = res.message
                            }) {
                                Text(IntegrationManager.shared.isQuickActionInstalled ? "Reinstall" : "Install")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }

                        if let status = quickActionStatus {
                            Text(status)
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                        }

                        // CLI Utility
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Terminal CLI (dropshelf)")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Add files directly with `dropshelf file.pdf`")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: {
                                let res = IntegrationManager.shared.installCLITool()
                                cliStatus = res.message
                            }) {
                                Text(IntegrationManager.shared.isCLIInstalled ? "Reinstall" : "Install")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }

                        if let status = cliStatus {
                            Text(status)
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                        }

                        // Hotkey info
                        HStack {
                            Text("Keyboard Shortcut")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("⌘⇧Y")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                        }
                    }

                    Divider()

                    // Developer & About Info
                    HStack(spacing: 12) {
                        AppIconView(size: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("DropShelf")
                                    .font(.system(size: 12, weight: .bold))
                                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            Text("Developer: Arslan Hamid")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.blue)
                        }

                        Spacer()

                        Button(action: {
                            if let url = URL(string: "https://github.com/hamidarslan/DropShelf-macOS") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            Text("GitHub")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .frame(height: 440)
        }
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(store.useRefinedClassic ? ClassicPalette(light: store.isEffectiveLightMode).surface : Color(nsColor: .windowBackgroundColor).opacity(0.95))
        )
        .onAppear {
            store.refreshLaunchAtLogin()
        }
    }
}
