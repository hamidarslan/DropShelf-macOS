import AppKit
import ApplicationServices

struct MenuBarControlExpectedIDs: Equatable, Sendable {
    let arrow: String
    let divider: String
}

enum MenuBarControlTrust: Equatable, Sendable {
    case trusted
    case denied
    case unavailable
}

enum MenuBarControlInspectionMode: Equatable, Sendable {
    case expanded
    case collapsed
}

enum MenuBarControlReachability: Equatable, Sendable {
    case reachable
    case temporarilyObscured
    case indeterminate
    case unreachable
    case unauthorized
}

enum MenuBarControlInspectionStage: String, Equatable, Sendable {
    case authorization
    case menuBarAgent
    case entryRoots
    case tree
    case arrowFrame
    case dividerFrame
    case geometry
    case applicationHitTest
    case systemHitTest
    case ancestry
    case deadline
    case cancelled
}

enum MenuBarControlOverlay: Equatable, Sendable {
    case helpTag
    case menu
}

struct MenuBarControlInspectionDiagnostic: Equatable, Sendable {
    let stage: MenuBarControlInspectionStage
    let axError: Int32?
    let elapsedMilliseconds: Int
    let hitProcessID: pid_t?
    let overlay: MenuBarControlOverlay?
}

enum MenuBarControlTreeEvidence: Equatable, Sendable {
    case complete(arrowCount: Int, dividerCount: Int)
    case partial
}

enum MenuBarControlGeometryEvidence: Equatable, Sendable {
    case valid
    case outsideMenuBar
    case invalidOrder
    case invalid
    case unavailable
}

enum MenuBarControlHitEvidence: Equatable, Sendable {
    case ownControl
    case differentHostControl
    case overlay
    case foreignOverlay
    case otherControl
    case unavailable
}

struct MenuBarControlClassificationEvidence: Equatable, Sendable {
    let authorized: Bool
    let tree: MenuBarControlTreeEvidence
    let geometry: MenuBarControlGeometryEvidence
    let applicationHit: MenuBarControlHitEvidence
    let systemHit: MenuBarControlHitEvidence
}

enum MenuBarControlClassifier {
    static func classify(_ evidence: MenuBarControlClassificationEvidence,
                         mode: MenuBarControlInspectionMode) -> MenuBarControlReachability {
        guard evidence.authorized else { return .unauthorized }
        guard case .complete(let arrowCount, let dividerCount) = evidence.tree else { return .indeterminate }
        if arrowCount == 0 { return .unreachable }
        guard arrowCount == 1 else { return .indeterminate }
        if mode == .expanded {
            if dividerCount == 0 { return .unreachable }
            guard dividerCount == 1 else { return .indeterminate }
        }
        switch evidence.geometry {
        case .outsideMenuBar, .invalidOrder, .invalid: return .unreachable
        case .unavailable: return .indeterminate
        case .valid: break
        }
        switch evidence.systemHit {
        case .ownControl: return .reachable
        case .overlay, .foreignOverlay: return .temporarilyObscured
        case .differentHostControl: return .unreachable
        case .otherControl, .unavailable: break
        }
        switch evidence.applicationHit {
        case .overlay, .foreignOverlay: return .temporarilyObscured
        case .differentHostControl: return .unreachable
        case .ownControl, .otherControl, .unavailable: return .indeterminate
        }
    }
}

enum MenuBarControlInspectionReason: Equatable, Sendable {
    case verified
    case accessibilityUnavailable
    case menuBarAgentUnavailable
    case timedOut
    case treeLimitReached
    case identifierMissing
    case identifierDuplicated
    case invalidFrame
    case outsideMenuBar
    case ambiguousScreen
    case invalidOrder
    case hitTestFailed
    case temporarilyObscured
    case partialRead
    case cancelled
}

struct MenuBarControlInspectionResult: Equatable, Sendable {
    let requestID: UInt64
    let arrowFrame: CGRect?
    let dividerFrame: CGRect?
    let menuBarFrame: CGRect?
    let reachability: MenuBarControlReachability
    let reason: MenuBarControlInspectionReason
    let diagnostic: MenuBarControlInspectionDiagnostic

    var reliable: Bool { reachability == .reachable }
    var placementVerified: Bool { reachability == .reachable || reachability == .temporarilyObscured }
}

struct MenuBarControlInspectionRequest: Equatable, Sendable {
    fileprivate let id: UInt64
}

@MainActor
final class MenuBarControlMonitor {
    private enum AXRead<Value> {
        case value(Value)
        case absent
        case failure(AXError)
    }

    private enum FrameRead {
        case value(CGRect)
        case invalid
        case failure(AXError)
    }

    private struct HitRead {
        let evidence: MenuBarControlHitEvidence
        let error: AXError?
        let processID: pid_t?
        let overlay: MenuBarControlOverlay?
        let ancestryExhausted: Bool
        let deadlineExceeded: Bool
    }

    private struct MenuBarRegion: Sendable {
        let frame: CGRect

        func contains(_ control: CGRect) -> Bool {
            frame.insetBy(dx: -1, dy: -1).contains(control)
        }
    }

    private struct Work: Sendable {
        let requestID: UInt64
        let processID: pid_t
        let expected: MenuBarControlExpectedIDs
        let mode: MenuBarControlInspectionMode
        let regions: [MenuBarRegion]
        let startedAt: TimeInterval
    }

    private final class RequestState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private let queue = DispatchQueue(label: "com.dropshelf.menu-bar-control-monitor", qos: .userInitiated)
    private var generation: UInt64 = 0
    private var current: (id: UInt64, state: RequestState)?

    var trust: MenuBarControlTrust {
        guard NSWorkspace.shared.runningApplications.contains(where: Self.isMenuBarAgent) else {
            return .unavailable
        }
        return AXIsProcessTrusted() ? .trusted : .denied
    }

    @discardableResult
    func inspect(expected: MenuBarControlExpectedIDs, mode: MenuBarControlInspectionMode,
                 completion: @escaping @MainActor @Sendable (MenuBarControlInspectionResult) -> Void) -> MenuBarControlInspectionRequest {
        generation &+= 1
        let requestID = generation
        current?.state.cancel()
        let state = RequestState()
        current = (requestID, state)

        guard AXIsProcessTrusted() else {
            deliver(MenuBarControlInspectionResult(requestID: requestID, arrowFrame: nil, dividerFrame: nil,
                menuBarFrame: nil, reachability: .unauthorized, reason: .accessibilityUnavailable,
                diagnostic: MenuBarControlInspectionDiagnostic(stage: .authorization, axError: nil,
                    elapsedMilliseconds: 0, hitProcessID: nil, overlay: nil)),
                state: state, completion: completion)
            return MenuBarControlInspectionRequest(id: requestID)
        }
        let agents = NSWorkspace.shared.runningApplications.filter(Self.isMenuBarAgent)
        guard agents.count == 1 else {
            deliver(MenuBarControlInspectionResult(requestID: requestID, arrowFrame: nil, dividerFrame: nil,
                menuBarFrame: nil, reachability: .indeterminate, reason: .menuBarAgentUnavailable,
                diagnostic: MenuBarControlInspectionDiagnostic(stage: .menuBarAgent, axError: nil,
                    elapsedMilliseconds: 0, hitProcessID: nil, overlay: nil)),
                state: state, completion: completion)
            return MenuBarControlInspectionRequest(id: requestID)
        }
        let work = Work(requestID: requestID, processID: agents[0].processIdentifier,
            expected: expected, mode: mode, regions: Self.menuBarRegions(),
            startedAt: ProcessInfo.processInfo.systemUptime)
        queue.async { [weak self] in
            let result = Self.perform(work: work, state: state)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.current?.id == requestID, !state.isCancelled else { return }
                self.current = nil
                completion(result)
            }
        }
        return MenuBarControlInspectionRequest(id: requestID)
    }

    func cancel(_ request: MenuBarControlInspectionRequest) {
        guard current?.id == request.id else { return }
        current?.state.cancel()
        current = nil
    }

    private func deliver(_ result: MenuBarControlInspectionResult, state: RequestState,
                         completion: @escaping @MainActor @Sendable (MenuBarControlInspectionResult) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.current?.id == result.requestID, !state.isCancelled else { return }
            self.current = nil
            completion(result)
        }
    }

    private static func isMenuBarAgent(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.bundleIdentifier == "com.apple.MenuBarAgent",
              let bundleURL = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL else { return false }
        let systemURL = URL(fileURLWithPath: "/System/Library/CoreServices/MenuBarAgent.app", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        return bundleURL == systemURL && Bundle(url: bundleURL)?.bundleIdentifier == "com.apple.MenuBarAgent"
    }

    private static func menuBarRegions() -> [MenuBarRegion] {
        NSScreen.screens.compactMap { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard displayBounds.width.isFinite, displayBounds.height.isFinite,
                  displayBounds.width > 0, displayBounds.height > 0,
                  screen.frame.width > 0, screen.frame.height > 0 else { return nil }

            let appKitRegion: CGRect
            if let trailing = screen.auxiliaryTopRightArea, trailing.width > 0, trailing.height > 0 {
                appKitRegion = trailing
            } else {
                let height = max(1, screen.frame.maxY - screen.visibleFrame.maxY)
                appKitRegion = CGRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                    width: screen.frame.width, height: height)
            }
            let scaleX = displayBounds.width / screen.frame.width
            let scaleY = displayBounds.height / screen.frame.height
            let localX = appKitRegion.minX - screen.frame.minX
            let distanceFromTop = screen.frame.maxY - appKitRegion.maxY
            let converted = CGRect(x: displayBounds.minX + localX * scaleX,
                y: displayBounds.minY + distanceFromTop * scaleY,
                width: appKitRegion.width * scaleX, height: appKitRegion.height * scaleY)
            return MenuBarRegion(frame: converted)
        }
    }

    nonisolated private static func perform(work: Work, state: RequestState) -> MenuBarControlInspectionResult {
        let deadline = work.startedAt + 0.45
        let application = AXUIElementCreateApplication(work.processID)
        let applicationTimeout = AXUIElementSetMessagingTimeout(application, 0.2)
        guard applicationTimeout == .success else {
            return uncertain(work, reason: .partialRead, stage: .entryRoots, error: applicationTimeout)
        }
        let systemWide = AXUIElementCreateSystemWide()
        let systemTimeout = AXUIElementSetMessagingTimeout(systemWide, 0.2)
        guard systemTimeout == .success else {
            return uncertain(work, reason: .partialRead, stage: .systemHitTest, error: systemTimeout)
        }

        var entryRoots: [AXUIElement] = [application]
        switch elementAttribute(kAXExtrasMenuBarAttribute as String, element: application) {
        case .value(let extras): appendIfUnique(extras, to: &entryRoots)
        case .absent: break
        case .failure(let error):
            return uncertain(work, reason: .partialRead, stage: .entryRoots, error: error)
        }
        let windows: [AXUIElement]
        switch elementsAttribute(kAXWindowsAttribute as String, element: application) {
        case .value(let value): windows = value
        case .absent: windows = []
        case .failure(let error):
            return uncertain(work, reason: .partialRead, stage: .entryRoots, error: error)
        }
        let maxEntryRoots = 16
        for window in windows {
            appendIfUnique(window, to: &entryRoots)
            guard entryRoots.count <= maxEntryRoots else {
                return uncertain(work, reason: .treeLimitReached, stage: .entryRoots)
            }
        }
        if state.isCancelled { return uncertain(work, reason: .cancelled, stage: .cancelled) }
        if ProcessInfo.processInfo.systemUptime > deadline {
            return uncertain(work, reason: .timedOut, stage: .deadline)
        }

        var queue: [(AXUIElement, Int)] = entryRoots.map { ($0, 0) }
        var scheduled = entryRoots
        var cursor = 0
        var visited = 0
        var arrowMatches: [AXUIElement] = []
        var dividerMatches: [AXUIElement] = []
        let maxNodes = 256
        let maxDepth = 8

        while cursor < queue.count {
            if state.isCancelled { return uncertain(work, reason: .cancelled, stage: .cancelled) }
            if ProcessInfo.processInfo.systemUptime > deadline {
                return uncertain(work, reason: .timedOut, stage: .deadline)
            }
            guard visited < maxNodes else { return uncertain(work, reason: .treeLimitReached, stage: .tree) }
            let (element, depth) = queue[cursor]
            cursor += 1
            visited += 1

            switch stringAttribute(kAXIdentifierAttribute as String, element: element) {
            case .value(let identifier):
                if identifier == work.expected.arrow { arrowMatches.append(element) }
                if identifier == work.expected.divider { dividerMatches.append(element) }
            case .absent: break
            case .failure(let error):
                return uncertain(work, reason: .partialRead, stage: .tree, error: error)
            }
            if arrowMatches.count > 1 || dividerMatches.count > 1 {
                return result(work, reachability: .indeterminate, reason: .identifierDuplicated, stage: .tree)
            }
            let children: [AXUIElement]
            switch elementsAttribute(kAXChildrenAttribute as String, element: element) {
            case .value(let value): children = value
            case .absent: children = []
            case .failure(let error):
                return uncertain(work, reason: .partialRead, stage: .tree, error: error)
            }
            if depth >= maxDepth {
                guard children.isEmpty else { return uncertain(work, reason: .treeLimitReached, stage: .tree) }
                continue
            }
            var unseenChildren: [AXUIElement] = []
            for child in children where !contains(child, in: scheduled) {
                appendIfUnique(child, to: &unseenChildren)
            }
            for child in unseenChildren {
                scheduled.append(child)
                queue.append((child, depth + 1))
            }
        }

        let tree = MenuBarControlTreeEvidence.complete(arrowCount: arrowMatches.count,
            dividerCount: dividerMatches.count)
        let countClassification = MenuBarControlClassifier.classify(
            MenuBarControlClassificationEvidence(authorized: true, tree: tree, geometry: .unavailable,
                applicationHit: .unavailable, systemHit: .unavailable), mode: work.mode)
        if arrowMatches.isEmpty || (work.mode == .expanded && dividerMatches.isEmpty) {
            return result(work, reachability: countClassification, reason: .identifierMissing, stage: .tree)
        }
        guard arrowMatches.count == 1,
              work.mode == .collapsed || dividerMatches.count == 1 else {
            return result(work, reachability: .indeterminate, reason: .identifierDuplicated, stage: .tree)
        }
        let arrowFrame: CGRect
        switch frame(of: arrowMatches[0]) {
        case .value(let value): arrowFrame = value
        case .invalid:
            return result(work, reachability: .unreachable, reason: .invalidFrame, stage: .arrowFrame)
        case .failure(let error):
            return uncertain(work, reason: .partialRead, stage: .arrowFrame, error: error)
        }
        let matchingRegions = work.regions.filter { $0.contains(arrowFrame) }
        if matchingRegions.isEmpty {
            return result(work, arrowFrame: arrowFrame, reachability: .unreachable,
                reason: .outsideMenuBar, stage: .geometry)
        }
        guard matchingRegions.count == 1 else {
            return result(work, arrowFrame: arrowFrame, reachability: .indeterminate,
                reason: .ambiguousScreen, stage: .geometry)
        }
        let menuBarFrame = matchingRegions[0].frame
        var dividerFrame: CGRect?
        if work.mode == .expanded {
            switch frame(of: dividerMatches[0]) {
            case .value(let value): dividerFrame = value
            case .invalid:
                return result(work, arrowFrame: arrowFrame, menuBarFrame: menuBarFrame,
                    reachability: .unreachable, reason: .invalidFrame, stage: .dividerFrame)
            case .failure(let error):
                return uncertain(work, arrowFrame: arrowFrame, menuBarFrame: menuBarFrame,
                    reason: .partialRead, stage: .dividerFrame, error: error)
            }
            guard let dividerFrame else { preconditionFailure("expanded divider frame was not assigned") }
            guard matchingRegions[0].contains(dividerFrame) else {
                return result(work, arrowFrame: arrowFrame, dividerFrame: dividerFrame,
                    menuBarFrame: menuBarFrame, reachability: .unreachable,
                    reason: .outsideMenuBar, stage: .geometry)
            }
            guard dividerFrame.maxX <= arrowFrame.minX + 1 else {
                return result(work, arrowFrame: arrowFrame, dividerFrame: dividerFrame,
                    menuBarFrame: menuBarFrame, reachability: .unreachable,
                    reason: .invalidOrder, stage: .geometry)
            }
        }
        if state.isCancelled { return uncertain(work, reason: .cancelled, stage: .cancelled) }
        if ProcessInfo.processInfo.systemUptime > deadline {
            return uncertain(work, reason: .timedOut, stage: .deadline)
        }

        let point = CGPoint(x: arrowFrame.midX, y: arrowFrame.midY)
        let applicationHit = hitTest(root: application, point: point, expectedID: work.expected.arrow,
            differentControlID: work.expected.divider, hostProcessID: work.processID,
            deadline: deadline, detectOverlay: true)
        let systemHit = hitTest(root: systemWide, point: point, expectedID: work.expected.arrow,
            differentControlID: work.expected.divider, hostProcessID: work.processID,
            deadline: deadline, detectOverlay: true)
        let evidence = MenuBarControlClassificationEvidence(authorized: true, tree: tree, geometry: .valid,
            applicationHit: applicationHit.evidence, systemHit: systemHit.evidence)
        let reachability = MenuBarControlClassifier.classify(evidence, mode: work.mode)
        switch reachability {
        case .reachable:
            return result(work, arrowFrame: arrowFrame, dividerFrame: dividerFrame,
                menuBarFrame: menuBarFrame, reachability: .reachable, reason: .verified,
                stage: .systemHitTest, hitProcessID: systemHit.processID)
        case .temporarilyObscured:
            let systemObstruction = systemHit.evidence == .overlay || systemHit.evidence == .foreignOverlay
            let obstruction = systemObstruction ? systemHit : applicationHit
            return result(work, arrowFrame: arrowFrame, dividerFrame: dividerFrame,
                menuBarFrame: menuBarFrame, reachability: .temporarilyObscured,
                reason: .temporarilyObscured,
                stage: systemObstruction ? .systemHitTest : .applicationHitTest,
                hitProcessID: obstruction.processID, overlay: obstruction.overlay)
        case .indeterminate:
            let systemUnresolved = systemHit.evidence == .unavailable
            let unresolved = systemUnresolved ? systemHit : applicationHit
            let unresolvedStage: MenuBarControlInspectionStage = systemUnresolved
                ? .systemHitTest : .applicationHitTest
            return uncertain(work, arrowFrame: arrowFrame, dividerFrame: dividerFrame,
                menuBarFrame: menuBarFrame, reason: .hitTestFailed,
                stage: unresolved.deadlineExceeded ? .deadline
                    : (unresolved.ancestryExhausted ? .ancestry : unresolvedStage),
                error: unresolved.error, hitProcessID: unresolved.processID, overlay: unresolved.overlay)
        case .unreachable, .unauthorized:
            let evidenceHit = applicationHit.evidence == .differentHostControl ? applicationHit : systemHit
            return result(work, arrowFrame: arrowFrame, dividerFrame: dividerFrame,
                menuBarFrame: menuBarFrame, reachability: reachability, reason: .hitTestFailed,
                stage: applicationHit.evidence == .differentHostControl ? .applicationHitTest : .systemHitTest,
                hitProcessID: evidenceHit.processID, overlay: evidenceHit.overlay)
        }
    }

    nonisolated private static func result(_ work: Work, arrowFrame: CGRect? = nil,
        dividerFrame: CGRect? = nil, menuBarFrame: CGRect? = nil,
        reachability: MenuBarControlReachability, reason: MenuBarControlInspectionReason,
        stage: MenuBarControlInspectionStage, error: AXError? = nil, hitProcessID: pid_t? = nil,
        overlay: MenuBarControlOverlay? = nil) -> MenuBarControlInspectionResult {
        let elapsed = max(0, Int((ProcessInfo.processInfo.systemUptime - work.startedAt) * 1_000))
        return MenuBarControlInspectionResult(requestID: work.requestID, arrowFrame: arrowFrame,
            dividerFrame: dividerFrame, menuBarFrame: menuBarFrame, reachability: reachability,
            reason: reason, diagnostic: MenuBarControlInspectionDiagnostic(stage: stage,
                axError: error.map { Int32($0.rawValue) }, elapsedMilliseconds: elapsed,
                hitProcessID: hitProcessID, overlay: overlay))
    }

    nonisolated private static func uncertain(_ work: Work, arrowFrame: CGRect? = nil,
        dividerFrame: CGRect? = nil, menuBarFrame: CGRect? = nil,
        reason: MenuBarControlInspectionReason, stage: MenuBarControlInspectionStage,
        error: AXError? = nil, hitProcessID: pid_t? = nil,
        overlay: MenuBarControlOverlay? = nil) -> MenuBarControlInspectionResult {
        if !AXIsProcessTrusted() {
            return result(work, arrowFrame: arrowFrame, dividerFrame: dividerFrame,
                menuBarFrame: menuBarFrame, reachability: .unauthorized,
                reason: .accessibilityUnavailable, stage: .authorization,
                error: error, hitProcessID: hitProcessID, overlay: overlay)
        }
        return result(work, arrowFrame: arrowFrame, dividerFrame: dividerFrame,
            menuBarFrame: menuBarFrame, reachability: .indeterminate, reason: reason,
            stage: stage, error: error, hitProcessID: hitProcessID, overlay: overlay)
    }

    nonisolated private static func attribute(_ name: String, element: AXUIElement) -> AXRead<CFTypeRef> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if error == .noValue || error == .attributeUnsupported { return .absent }
        guard error == .success else { return .failure(error) }
        guard let value else { return .absent }
        return .value(value)
    }

    nonisolated private static func stringAttribute(_ name: String, element: AXUIElement) -> AXRead<String> {
        switch attribute(name, element: element) {
        case .value(let value):
            guard let string = value as? String else { return .failure(.illegalArgument) }
            return .value(string)
        case .absent: return .absent
        case .failure(let error): return .failure(error)
        }
    }

    nonisolated private static func elementsAttribute(_ name: String, element: AXUIElement) -> AXRead<[AXUIElement]> {
        switch attribute(name, element: element) {
        case .value(let value):
            guard let values = value as? [AXUIElement] else { return .failure(.illegalArgument) }
            return .value(values)
        case .absent: return .absent
        case .failure(let error): return .failure(error)
        }
    }

    nonisolated private static func elementAttribute(_ name: String, element: AXUIElement) -> AXRead<AXUIElement> {
        switch attribute(name, element: element) {
        case .value(let value):
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return .failure(.illegalArgument) }
            return .value(unsafeBitCast(value, to: AXUIElement.self))
        case .absent: return .absent
        case .failure(let error): return .failure(error)
        }
    }

    nonisolated private static func contains(_ element: AXUIElement, in elements: [AXUIElement]) -> Bool {
        elements.contains { CFEqual($0, element) }
    }

    nonisolated private static func appendIfUnique(_ element: AXUIElement, to elements: inout [AXUIElement]) {
        if !contains(element, in: elements) { elements.append(element) }
    }

    nonisolated private static func frame(of element: AXUIElement) -> FrameRead {
        let positionValue: CFTypeRef
        switch attribute(kAXPositionAttribute as String, element: element) {
        case .value(let value): positionValue = value
        case .absent: return .failure(.noValue)
        case .failure(let error): return .failure(error)
        }
        let sizeValue: CFTypeRef
        switch attribute(kAXSizeAttribute as String, element: element) {
        case .value(let value): sizeValue = value
        case .absent: return .failure(.noValue)
        case .failure(let error): return .failure(error)
        }
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return .invalid }
        var point = CGPoint.zero
        var size = CGSize.zero
        let position = unsafeBitCast(positionValue, to: AXValue.self)
        let dimensions = unsafeBitCast(sizeValue, to: AXValue.self)
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(dimensions, .cgSize, &size) else { return .invalid }
        let frame = CGRect(origin: point, size: size)
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return .invalid }
        return .value(frame)
    }

    nonisolated private static func hitTest(root: AXUIElement, point: CGPoint, expectedID: String,
        differentControlID: String, hostProcessID: pid_t, deadline: TimeInterval,
        detectOverlay: Bool) -> HitRead {
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit)
        guard error == .success else {
            return HitRead(evidence: .unavailable, error: error, processID: nil,
                overlay: nil, ancestryExhausted: false, deadlineExceeded: false)
        }
        guard var element = hit else {
            return HitRead(evidence: .unavailable, error: nil, processID: nil,
                overlay: nil, ancestryExhausted: false, deadlineExceeded: false)
        }
        var processID: pid_t = 0
        let pidError = AXUIElementGetPid(element, &processID)
        let resolvedPID: pid_t? = pidError == .success ? processID : nil
        if detectOverlay, let resolvedPID, resolvedPID != hostProcessID {
            return HitRead(evidence: .foreignOverlay, error: nil, processID: resolvedPID,
                overlay: nil, ancestryExhausted: false, deadlineExceeded: false)
        }
        var overlay: MenuBarControlOverlay?
        var matchedDifferentHostControl = false
        let maxParents = 8
        for depth in 0...maxParents {
            if ProcessInfo.processInfo.systemUptime > deadline {
                return HitRead(evidence: .unavailable, error: nil,
                    processID: resolvedPID, overlay: overlay, ancestryExhausted: false,
                    deadlineExceeded: true)
            }
            switch stringAttribute(kAXIdentifierAttribute as String, element: element) {
            case .value(let identifier) where identifier == expectedID && resolvedPID == hostProcessID:
                return HitRead(evidence: .ownControl, error: nil, processID: resolvedPID,
                    overlay: overlay, ancestryExhausted: false, deadlineExceeded: false)
            case .value(let identifier) where identifier == differentControlID && resolvedPID == hostProcessID:
                matchedDifferentHostControl = true
            case .value, .absent: break
            case .failure(let error):
                return HitRead(evidence: .unavailable, error: error, processID: resolvedPID,
                    overlay: overlay, ancestryExhausted: false, deadlineExceeded: false)
            }
            if detectOverlay, overlay == nil,
               case .value(let role) = stringAttribute(kAXRoleAttribute as String, element: element) {
                if role == (kAXHelpTagRole as String) { overlay = .helpTag }
                else if role == (kAXMenuRole as String) { overlay = .menu }
            }
            if let overlay {
                return HitRead(evidence: .overlay, error: nil, processID: resolvedPID,
                    overlay: overlay, ancestryExhausted: false, deadlineExceeded: false)
            }
            switch elementAttribute(kAXParentAttribute as String, element: element) {
            case .absent:
                return HitRead(evidence: matchedDifferentHostControl ? .differentHostControl : .otherControl,
                    error: nil, processID: resolvedPID,
                    overlay: overlay, ancestryExhausted: false, deadlineExceeded: false)
            case .failure(let error):
                return HitRead(evidence: .unavailable, error: error, processID: resolvedPID,
                    overlay: overlay, ancestryExhausted: false, deadlineExceeded: false)
            case .value(let parent):
                if depth == maxParents {
                    return HitRead(evidence: .unavailable, error: nil, processID: resolvedPID,
                        overlay: overlay, ancestryExhausted: true, deadlineExceeded: false)
                }
                element = parent
            }
        }
        return HitRead(evidence: .unavailable, error: nil, processID: resolvedPID,
            overlay: overlay, ancestryExhausted: true, deadlineExceeded: false)
    }
}
