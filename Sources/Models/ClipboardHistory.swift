import Cocoa

enum ClipboardRetention: Int, CaseIterable, Identifiable {
    case fiveMinutes = 300, fifteenMinutes = 900, oneHour = 3600, fourHours = 14400, oneDay = 86400
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .oneHour: return "1 hour"
        case .fourHours: return "4 hours"
        case .oneDay: return "24 hours"
        }
    }
}

struct ClipboardPayload: Equatable {
    static let supportedTypes = [NSPasteboard.PasteboardType.string.rawValue,
                                 "public.utf16-external-plain-text", "public.utf16-plain-text",
                                 NSPasteboard.PasteboardType.URL.rawValue]
    let items: [[String: Data]]
    let byteCount: Int
    let preview: String
    let isURL: Bool

    init?(items: [[String: Data]]) {
        guard !items.isEmpty, items.allSatisfy({ !$0.isEmpty && Set($0.keys).isSubset(of: Set(Self.supportedTypes)) && Self.text($0) != nil }) else { return nil }
        self.items = items
        byteCount = items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
        let firstText = Self.text(items[0]) ?? ""
        preview = String(firstText.prefix(240))
        let prefix = firstText.prefix(8).lowercased()
        isURL = items.count == 1 && (items[0][NSPasteboard.PasteboardType.URL.rawValue] != nil ||
            ((prefix.hasPrefix("http://") || prefix.hasPrefix("https://")) && !firstText.contains(where: { $0.isWhitespace })))
    }

    var displayText: String { items.compactMap(Self.text).joined(separator: "\n\n") }

    private static func text(_ item: [String: Data]) -> String? {
        for type in supportedTypes {
            guard let data = item[type] else { continue }
            let encoding: String.Encoding = type.contains("utf16") ? .utf16 : .utf8
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.items == rhs.items }
}

struct ClipboardEntry: Identifiable {
    let id: UUID
    let payload: ClipboardPayload
    let capturedAt: Date
    let capturedUptime: TimeInterval
    var lifetime: TimeInterval
    var isPinned: Bool

    func expired(at date: Date, uptime: TimeInterval) -> Bool {
        date.timeIntervalSince(capturedAt) >= lifetime || uptime - capturedUptime >= lifetime || uptime < capturedUptime
    }
}

struct ClipboardHistory {
    enum CaptureResult: Equatable { case stored, tooLarge, full }
    private(set) var entries: [ClipboardEntry] = []
    var retention: ClipboardRetention = .oneHour
    var maximumEntries = 50
    var maximumEntryBytes = 32 * 1024 * 1024
    var maximumTotalBytes = 128 * 1024 * 1024

    mutating func capture(_ payload: ClipboardPayload, at date: Date, uptime: TimeInterval) -> CaptureResult {
        prune(at: date, uptime: uptime)
        guard payload.byteCount <= maximumEntryBytes && payload.byteCount <= maximumTotalBytes else { return .tooLarge }
        var updated = entries
        let duplicate = updated.first { $0.payload == payload }
        updated.removeAll { $0.payload == payload }
        while updated.count >= maximumEntries || updated.reduce(payload.byteCount, { $0 + $1.payload.byteCount }) > maximumTotalBytes {
            guard let index = updated.lastIndex(where: { !$0.isPinned }) else { return .full }
            updated.remove(at: index)
        }
        updated.insert(ClipboardEntry(id: duplicate?.id ?? UUID(), payload: payload, capturedAt: date,
                                      capturedUptime: uptime, lifetime: TimeInterval(retention.rawValue),
                                      isPinned: duplicate?.isPinned ?? false), at: 0)
        entries = updated
        return .stored
    }

    mutating func prune(at date: Date, uptime: TimeInterval) {
        for index in entries.indices { entries[index].lifetime = min(entries[index].lifetime, TimeInterval(retention.rawValue)) }
        entries.removeAll { $0.expired(at: date, uptime: uptime) }
    }
    mutating func togglePin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned.toggle()
    }
    mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }
    mutating func clear() { entries.removeAll(keepingCapacity: false) }
}
