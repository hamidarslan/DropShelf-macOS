enum MenuBarGuardObservation: Equatable {
    case reachable
    case obscured
    case indeterminate
    case unreachable
    case unauthorized
}

enum MenuBarGuardDecision: Equatable {
    case keepHidden
    case revealPreservingSetup
    case revealAndInvalidateSetup
}

struct MenuBarGuardPolicy {
    private static let unknownGrace: Double = 8
    private var consecutiveUnreachable = 0
    private var unverifiedSince: Double?
    private var lastObservedTime: Double?

    mutating func observe(_ observation: MenuBarGuardObservation, at monotonicTime: Double) -> MenuBarGuardDecision {
        switch observation {
        case .reachable, .obscured:
            clearFailures(recording: monotonicTime)
            return .keepHidden
        case .unauthorized:
            clearFailures(recording: monotonicTime)
            return .revealPreservingSetup
        case .indeterminate, .unreachable:
            guard isValid(monotonicTime) else {
                reset()
                return .revealPreservingSetup
            }
        }

        lastObservedTime = monotonicTime
        if unverifiedSince == nil { unverifiedSince = monotonicTime }
        switch observation {
        case .indeterminate:
            consecutiveUnreachable = 0
            guard let unverifiedSince else { return .keepHidden }
            return monotonicTime - unverifiedSince >= Self.unknownGrace
                ? .revealPreservingSetup
                : .keepHidden
        case .unreachable:
            consecutiveUnreachable += 1
            if consecutiveUnreachable >= 2 { return .revealAndInvalidateSetup }
            guard let unverifiedSince else { return .keepHidden }
            return monotonicTime - unverifiedSince >= Self.unknownGrace
                ? .revealPreservingSetup
                : .keepHidden
        case .reachable, .obscured, .unauthorized:
            return .keepHidden
        }
    }

    mutating func reset() {
        consecutiveUnreachable = 0
        unverifiedSince = nil
        lastObservedTime = nil
    }

    private func isValid(_ time: Double) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        return lastObservedTime.map { time >= $0 } ?? true
    }

    private mutating func clearFailures(recording time: Double) {
        consecutiveUnreachable = 0
        unverifiedSince = nil
        lastObservedTime = time.isFinite && time >= 0 ? time : nil
    }
}
