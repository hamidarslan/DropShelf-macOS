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
    case cancelled
}

struct MenuBarControlInspectionResult: Equatable, Sendable {
    let requestID: UInt64
    let arrowFrame: CGRect?
    let dividerFrame: CGRect?
    let menuBarFrame: CGRect?
    let reliable: Bool
    let reason: MenuBarControlInspectionReason
}

struct MenuBarControlInspectionRequest: Equatable, Sendable {
    fileprivate let id: UInt64
}

@MainActor
final class MenuBarControlMonitor {
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
                menuBarFrame: nil,
                reliable: false, reason: .accessibilityUnavailable), state: state, completion: completion)
            return MenuBarControlInspectionRequest(id: requestID)
        }
        let agents = NSWorkspace.shared.runningApplications.filter(Self.isMenuBarAgent)
        guard agents.count == 1 else {
            deliver(MenuBarControlInspectionResult(requestID: requestID, arrowFrame: nil, dividerFrame: nil,
                menuBarFrame: nil,
                reliable: false, reason: .menuBarAgentUnavailable), state: state, completion: completion)
            return MenuBarControlInspectionRequest(id: requestID)
        }
        let work = Work(requestID: requestID, processID: agents[0].processIdentifier,
            expected: expected, mode: mode, regions: Self.menuBarRegions())
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
        let deadline = CFAbsoluteTimeGetCurrent() + 0.45
        let application = AXUIElementCreateApplication(work.processID)
        guard AXUIElementSetMessagingTimeout(application, 0.2) == .success else {
            return failure(work, .accessibilityUnavailable)
        }
        let systemWide = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(systemWide, 0.2)

        var entryRoots: [AXUIElement] = [application]
        if let extras = elementAttribute(kAXExtrasMenuBarAttribute as String, element: application) {
            appendIfUnique(extras, to: &entryRoots)
        }
        let windows = elementsAttribute(kAXWindowsAttribute as String, element: application)
        let maxEntryRoots = 16
        for window in windows {
            appendIfUnique(window, to: &entryRoots)
            guard entryRoots.count <= maxEntryRoots else { return failure(work, .treeLimitReached) }
        }
        if state.isCancelled { return failure(work, .cancelled) }
        if CFAbsoluteTimeGetCurrent() > deadline { return failure(work, .timedOut) }

        var queue: [(AXUIElement, Int)] = entryRoots.map { ($0, 0) }
        var scheduled = entryRoots
        var cursor = 0
        var visited = 0
        var arrowMatches: [AXUIElement] = []
        var dividerMatches: [AXUIElement] = []
        let maxNodes = 256
        let maxDepth = 8

        while cursor < queue.count {
            if state.isCancelled { return failure(work, .cancelled) }
            if CFAbsoluteTimeGetCurrent() > deadline { return failure(work, .timedOut) }
            guard visited < maxNodes else { return failure(work, .treeLimitReached) }
            let (element, depth) = queue[cursor]
            cursor += 1
            visited += 1

            if let identifier = stringAttribute(kAXIdentifierAttribute as String, element: element) {
                if identifier == work.expected.arrow { arrowMatches.append(element) }
                if identifier == work.expected.divider { dividerMatches.append(element) }
            }
            if arrowMatches.count > 1 || dividerMatches.count > 1 {
                return failure(work, .identifierDuplicated)
            }
            let children = elementsAttribute(kAXChildrenAttribute as String, element: element)
            if depth >= maxDepth {
                guard children.isEmpty else { return failure(work, .treeLimitReached) }
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

        guard arrowMatches.count == 1,
              work.mode == .collapsed || dividerMatches.count == 1 else {
            return failure(work, .identifierMissing)
        }
        guard let arrowFrame = frame(of: arrowMatches[0]) else {
            return failure(work, .invalidFrame)
        }
        let matchingRegions = work.regions.filter { $0.contains(arrowFrame) }
        guard matchingRegions.count == 1 else {
            return MenuBarControlInspectionResult(requestID: work.requestID, arrowFrame: arrowFrame,
                dividerFrame: nil, menuBarFrame: nil, reliable: false,
                reason: matchingRegions.isEmpty ? .outsideMenuBar : .ambiguousScreen)
        }
        let menuBarFrame = matchingRegions[0].frame
        let dividerFrame = dividerMatches.first.flatMap(frame(of:))
        if work.mode == .expanded {
            guard let dividerFrame else {
                return MenuBarControlInspectionResult(requestID: work.requestID, arrowFrame: arrowFrame,
                    dividerFrame: nil, menuBarFrame: menuBarFrame, reliable: false, reason: .invalidFrame)
            }
            guard matchingRegions[0].contains(dividerFrame) else {
                return MenuBarControlInspectionResult(requestID: work.requestID, arrowFrame: arrowFrame,
                    dividerFrame: dividerFrame, menuBarFrame: menuBarFrame, reliable: false, reason: .outsideMenuBar)
            }
            guard dividerFrame.maxX <= arrowFrame.minX + 1 else {
                return MenuBarControlInspectionResult(requestID: work.requestID, arrowFrame: arrowFrame,
                    dividerFrame: dividerFrame, menuBarFrame: menuBarFrame, reliable: false, reason: .invalidOrder)
            }
        }
        if state.isCancelled { return failure(work, .cancelled) }
        if CFAbsoluteTimeGetCurrent() > deadline { return failure(work, .timedOut) }
        guard hitTestMatches(systemWide: systemWide, point: CGPoint(x: arrowFrame.midX, y: arrowFrame.midY),
                             expectedID: work.expected.arrow, deadline: deadline) else {
            return MenuBarControlInspectionResult(requestID: work.requestID, arrowFrame: arrowFrame,
                dividerFrame: dividerFrame, menuBarFrame: menuBarFrame, reliable: false, reason: .hitTestFailed)
        }
        return MenuBarControlInspectionResult(requestID: work.requestID, arrowFrame: arrowFrame,
            dividerFrame: dividerFrame, menuBarFrame: menuBarFrame, reliable: true, reason: .verified)
    }

    nonisolated private static func failure(_ work: Work, _ reason: MenuBarControlInspectionReason) -> MenuBarControlInspectionResult {
        MenuBarControlInspectionResult(requestID: work.requestID, arrowFrame: nil, dividerFrame: nil,
            menuBarFrame: nil, reliable: false, reason: reason)
    }

    nonisolated private static func stringAttribute(_ name: String, element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated private static func elementsAttribute(_ name: String, element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let values = value as? [AXUIElement] else { return [] }
        return values
    }

    nonisolated private static func elementAttribute(_ name: String, element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    nonisolated private static func contains(_ element: AXUIElement, in elements: [AXUIElement]) -> Bool {
        elements.contains { CFEqual($0, element) }
    }

    nonisolated private static func appendIfUnique(_ element: AXUIElement, to elements: inout [AXUIElement]) {
        if !contains(element, in: elements) { elements.append(element) }
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        let position = unsafeBitCast(positionValue, to: AXValue.self)
        let dimensions = unsafeBitCast(sizeValue, to: AXValue.self)
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(dimensions, .cgSize, &size) else { return nil }
        let frame = CGRect(origin: point, size: size)
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    nonisolated private static func hitTestMatches(systemWide: AXUIElement, point: CGPoint, expectedID: String,
                                       deadline: CFAbsoluteTime) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return false }
        for _ in 0...4 {
            if CFAbsoluteTimeGetCurrent() > deadline { return false }
            if stringAttribute(kAXIdentifierAttribute as String, element: element) == expectedID { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            element = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return false
    }
}
