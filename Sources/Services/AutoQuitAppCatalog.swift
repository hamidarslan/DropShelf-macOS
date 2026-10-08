import AppKit
import Combine

struct AutoQuitAppEntry: Identifiable {
    let id: String
    let name: String
    let url: URL?
    let running: Bool
}

@MainActor
final class AutoQuitAppCatalog: ObservableObject {
    @Published private(set) var apps: [AutoQuitAppEntry] = []
    @Published private(set) var loading = false
    private var generation: UInt64 = 0
    private let queue = DispatchQueue(label: "com.dropshelf.auto-quit.catalog", qos: .utility)

    func refresh(keepRunning: Set<String>, ownIdentifier: String) {
        generation &+= 1
        let epoch = generation
        loading = true
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> AutoQuitAppEntry? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  !AutoQuitProtection.isProtected(bundleIdentifier: id, ownIdentifier: ownIdentifier) else { return nil }
            return AutoQuitAppEntry(id: id, name: app.localizedName ?? id, url: app.bundleURL, running: true)
        }
        queue.async { [weak self] in
            let installed = Self.installedApps(ownIdentifier: ownIdentifier)
            var merged = Dictionary(installed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for app in running { merged[app.id] = app }
            for id in keepRunning where merged[id] == nil {
                merged[id] = AutoQuitAppEntry(id: id, name: id, url: nil, running: false)
            }
            let apps = merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                guard let self, self.generation == epoch else { return }
                self.apps = apps
                self.loading = false
            }
        }
    }

    nonisolated private static func installedApps(ownIdentifier: String) -> [AutoQuitAppEntry] {
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var results: [AutoQuitAppEntry] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let id = info["CFBundleIdentifier"] as? String, !id.isEmpty, id.count <= 512,
                      ((info["LSUIElement"] as? NSNumber)?.boolValue ?? false) == false,
                      ((info["LSBackgroundOnly"] as? NSNumber)?.boolValue ?? false) == false,
                      !AutoQuitProtection.isProtected(bundleIdentifier: id, ownIdentifier: ownIdentifier) else { continue }
                let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
                results.append(AutoQuitAppEntry(id: id, name: name, url: url, running: false))
            }
        }
        return results
    }
}
