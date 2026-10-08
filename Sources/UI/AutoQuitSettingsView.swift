import SwiftUI
import AppKit

struct AutoQuitSettingsView: View {
    @ObservedObject private var controller = AutoQuitController.shared
    @StateObject private var catalog = AutoQuitAppCatalog()
    @State private var search = ""
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ClassicPalette { ClassicPalette(light: colorScheme == .light) }
    private var filteredApps: [AutoQuitAppEntry] {
        catalog.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        GeometryReader { _ in
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Auto Quit").font(.system(size: 20, weight: .semibold))
                Spacer()
                Text(controller.status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(controller.isRunning ? palette.accent : palette.muted)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(palette.subtle))
            }
            Text("Finish with a window. Finish with the app.")
                .font(.system(size: 11)).foregroundColor(palette.muted)

            VStack(alignment: .leading, spacing: 9) {
                Toggle("Quit apps after the last window closes", isOn: Binding(
                    get: { controller.enabled }, set: { if $0 { controller.enableFromSettings() } else { controller.setEnabled(false) } }
                ))
                .toggleStyle(.switch)
                .font(.system(size: 12, weight: .semibold))
                Text("Other supported apps receive a normal quit request after a short delay. Minimizing or hiding a window keeps the app open.")
                    .font(.system(size: 11)).foregroundColor(palette.muted).fixedSize(horizontal: false, vertical: true)
                Text("Uses Accessibility to check window state locally, without reading window titles or document contents.")
                    .font(.system(size: 10)).foregroundColor(palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.subtle))

            if !controller.permissionGranted {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "hand.raised.fill").foregroundColor(palette.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Accessibility permission needed").font(.system(size: 12, weight: .semibold))
                        Text("Auto Quit checks window state locally. It does not read window titles or document contents.")
                            .font(.system(size: 11)).foregroundColor(palette.muted)
                        Button("Allow Accessibility…") { controller.requestAccessibility() }
                            .font(.system(size: 11))
                    }
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep running").font(.system(size: 13, weight: .semibold))
                    Text("Select apps that should stay open after their windows close.")
                        .font(.system(size: 11)).foregroundColor(palette.muted)
                }
                Spacer()
                Button { refreshCatalog() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh app list")
                    .accessibilityLabel("Refresh app list")
            }
            TextField("Search apps", text: $search).textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Button("Keep all") { controller.setKeepRunning(controller.keepRunning.union(catalog.apps.map(\.id))) }
                    .disabled(catalog.loading)
                Button("Clear selections") { controller.setKeepRunning([]) }
                    .disabled(controller.keepRunning.isEmpty)
                Spacer()
                Text("\(controller.keepRunning.count) selected").foregroundColor(palette.muted)
            }
            .font(.system(size: 10))
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredApps) { app in appRow(app) }
                    if catalog.loading { ProgressView().controlSize(.small).padding(12) }
                    else if filteredApps.isEmpty {
                        Text("No matching apps").font(.system(size: 11)).foregroundColor(palette.muted).padding(18)
                    }
                }
                .padding(5)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.subtle))

            VStack(alignment: .leading, spacing: 5) {
                Text("Keep music, calls, downloads, and background work in your exception list. Apps can ask to save or cancel quitting. Finder and system services are protected.")
                Text("Pinned Dock shortcuts and recent-app icons can remain after quitting.")
                if controller.isRunning {
                    Text("Window tracking active for \(controller.monitoringCount) apps.")
                }
                if !controller.lastOutcome.isEmpty { Text(controller.lastOutcome) }
            }
            .font(.system(size: 10)).foregroundColor(palette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        }
        .foregroundColor(palette.text)
        .onAppear { controller.refreshPermission(); refreshCatalog() }
    }

    private func refreshCatalog() {
        catalog.refresh(keepRunning: controller.keepRunning, ownIdentifier: controller.ownIdentifier)
    }

    private func appRow(_ app: AutoQuitAppEntry) -> some View {
        let selected = controller.keepRunning.contains(app.id)
        return Button {
            controller.setKeepRunning(!selected, bundleIdentifier: app.id)
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let url = app.url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable() }
                    else { Image(systemName: "app").resizable() }
                }
                .scaledToFit().frame(width: 25, height: 25)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.system(size: 12, weight: .medium)).foregroundColor(palette.text)
                    if let reason = controller.unsupportedApps[app.id] {
                        Text(reason).font(.system(size: 10)).foregroundColor(palette.muted)
                    } else {
                        Text(selected ? "Keeps running" : (app.running ? "Running" : "Installed"))
                            .font(.system(size: 10)).foregroundColor(palette.muted)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17)).foregroundColor(selected ? palette.accent : palette.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? palette.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Keep \(app.name) running")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
