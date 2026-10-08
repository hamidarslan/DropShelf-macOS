import Foundation

struct AutoQuitProcess: Hashable {
    let pid: Int32
    let bundleIdentifier: String
    let launchDate: Date
    let session: UUID

    init(pid: Int32, bundleIdentifier: String, launchDate: Date, session: UUID = UUID()) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
        self.session = session
    }

    func matches(pid: Int32, bundleIdentifier: String?, launchDate: Date?) -> Bool {
        self.pid == pid && self.bundleIdentifier == bundleIdentifier && self.launchDate == launchDate
    }
}

enum AutoQuitWindowSnapshot: Equatable {
    case known(Set<UInt64>, eligible: Set<UInt64>? = nil)
    case uncertain

    var windowIDs: Set<UInt64>? {
        if case .known(let windows, _) = self { return windows }
        return nil
    }
}

struct AutoQuitDecisionState {
    private(set) var windows: Set<UInt64>?
    private(set) var pendingToken: UInt64?
    private var generation: UInt64 = 0
    private var eligibleWindows: Set<UInt64> = []

    mutating func observe(_ snapshot: AutoQuitWindowSnapshot) {
        switch snapshot {
        case .known(let current, let eligible):
            let eligible = eligible ?? current
            guard eligible.isSubset(of: current) else {
                observe(.uncertain)
                return
            }
            if windows != current || eligibleWindows != eligible { invalidate() }
            windows = current
            eligibleWindows = eligible
        case .uncertain:
            invalidate()
            windows = nil
            eligibleWindows.removeAll()
        }
    }

    mutating func closed(window: UInt64) -> UInt64? {
        guard var current = windows, current.remove(window) != nil else { return nil }
        let wasEligible = eligibleWindows.remove(window) != nil
        invalidate()
        windows = current
        guard current.isEmpty, wasEligible else { return nil }
        pendingToken = generation
        return generation
    }

    mutating func consume(token: UInt64, snapshot: AutoQuitWindowSnapshot) -> Bool {
        guard pendingToken == token else { return false }
        let allowed = windows == [] && snapshot.windowIDs == []
        invalidate()
        observe(snapshot)
        return allowed
    }

    mutating func invalidate() {
        generation &+= 1
        pendingToken = nil
    }
}

enum AutoQuitProtection {
    private static let protectedIdentifiers: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.windowmanager",
        "com.apple.securityagent", "com.apple.notificationcenterui"
    ]

    static func isProtected(bundleIdentifier: String, ownIdentifier: String) -> Bool {
        let identifier = bundleIdentifier.lowercased()
        return identifier.isEmpty || identifier == ownIdentifier.lowercased()
            || protectedIdentifiers.contains(identifier)
    }
}
