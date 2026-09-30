import Foundation

struct MenuBarShortcut: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String
    static let command: UInt32 = 256
    static let shift: UInt32 = 512
    static let option: UInt32 = 2048
    static let control: UInt32 = 4096
    static let standard = MenuBarShortcut(keyCode: 4, modifiers: control | option, label: "H")

    var isValid: Bool {
        let allowed = Self.command | Self.shift | Self.option | Self.control
        let reserved = keyCode == 16 && modifiers == Self.command | Self.shift
        return keyCode < 128 && keyCode != 53 && !reserved && modifiers & ~allowed == 0
            && modifiers & (Self.command | Self.control) != 0
            && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && label.count <= 12
            && !label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    var display: String {
        [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined() + label
    }
}

enum MenuBarPause: Equatable {
    case none
    case until(Date)
    case untilResumed
    func isActive(at now: Date) -> Bool {
        switch self {
        case .none: return false
        case .until(let end): return end > now
        case .untilResumed: return true
        }
    }
    mutating func expire(at now: Date) {
        if case .until(let end) = self, end <= now { self = .none }
    }
}

struct MenuBarDisplayWidth {
    let width: Double
    let usableRightWidth: Double?

    init(width: Double, usableRightWidth: Double? = nil) {
        self.width = width
        self.usableRightWidth = usableRightWidth
    }
}

enum MenuBarSpacerLayout {
    static func lengths(displays: [MenuBarDisplayWidth], modern: Bool) -> [Double] {
        if !modern {
            let widths = displays.map(\.width).filter { $0.isFinite && $0 > 0 }
            let widest = widths.max() ?? 1440
            return [min(10_000, max(500, widest * 2))]
        }
        guard !displays.isEmpty else { return [] }
        var smallestCliff = Double.infinity
        var widestStatusArea = 0.0
        for display in displays {
            guard display.width.isFinite, display.width > 0 else { return [] }
            let statusWidth = display.usableRightWidth ?? display.width
            guard statusWidth.isFinite, statusWidth > 0, statusWidth <= display.width else { return [] }
            let cliff = statusWidth < display.width ? statusWidth * 0.75 : display.width * 0.5
            smallestCliff = min(smallestCliff, cliff)
            widestStatusArea = max(widestStatusArea, statusWidth)
        }
        let unit = floor(smallestCliff - 64)
        guard unit.isFinite, unit >= 40, unit < smallestCliff else { return [] }
        let required = ceil(widestStatusArea / unit)
        guard required.isFinite, required >= 1, required <= 16 else { return [] }
        return Array(repeating: unit, count: Int(required))
    }
}

enum MenuBarOrganizerGeometry {
    static func isReachable(_ rect: CGRect?, in screen: CGRect) -> Bool {
        guard let rect, [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
              rect.width > 0, rect.height > 0 else { return false }
        return screen.insetBy(dx: -1, dy: -1).contains(rect)
    }
    static func hasSyntheticHosts(majorVersion: Int, windowIDs: [Int], distinctItems: Bool) -> Bool {
        majorVersion == 27 && distinctItems && windowIDs.count >= 2 && windowIDs.count <= 3
            && Set(windowIDs).count == windowIDs.count
            && windowIDs.allSatisfy { $0 > Int(UInt32.max) && $0 & 0xFFFF_FFFF == 0 }
    }
    static func canHide(anchor: CGRect?, divider: CGRect?, toggle: CGRect?, screen: CGRect,
                        requiresToggle: Bool) -> Bool {
        guard isReachable(anchor, in: screen), isReachable(divider, in: screen),
              let anchor, let divider, abs(anchor.midY - divider.midY) <= 4,
              divider.maxX <= anchor.minX + 1 else { return false }
        if requiresToggle {
            guard isReachable(toggle, in: screen), let toggle,
                  abs(toggle.midY - anchor.midY) <= 4,
                  toggle.minX + 1 >= divider.maxX else { return false }
        }
        return true
    }
}
