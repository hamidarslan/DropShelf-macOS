import Cocoa
import ServiceManagement

public final class LaunchAtLoginManager: ObservableObject {
    public static let shared = LaunchAtLoginManager()

    @Published public private(set) var isEnabled: Bool = false

    private init() {
        refreshStatus()
    }

    public func refreshStatus() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            self.isEnabled = (status == .enabled)
        } else {
            self.isEnabled = false
        }
    }

    @discardableResult
    public func setEnabled(_ enable: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
                refreshStatus()
                return true
            } catch {
                NSLog("[DropShelf] Failed to update launch at login status: \(error.localizedDescription)")
                refreshStatus()
                return false
            }
        }
        return false
    }

    @discardableResult
    public func toggle() -> Bool {
        return setEnabled(!isEnabled)
    }
}
