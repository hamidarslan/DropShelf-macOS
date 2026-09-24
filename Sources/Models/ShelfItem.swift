import Cocoa
import QuickLookThumbnailing

public enum ShelfItemType: Equatable {
    case file(URL)
    case folder(URL)
    case stack([URL])
    case webLink(URL)
    case color(hex: String, color: NSColor)
    case textSnippet(String)
    case image(NSImage, originalURL: URL?)
}

public class ShelfItem: Identifiable, ObservableObject, Equatable {
    public let id: UUID
    @Published public var title: String
    @Published public var subtitle: String
    @Published public var itemType: ShelfItemType
    @Published public var fileURLs: [URL]
    @Published public var dateAdded: Date
    @Published public var isLocked: Bool
    public var generatedURLs: Set<URL> = []
    public var isGenerated: Bool { !generatedURLs.isEmpty }
    // Generated ownership is tracked per file, never inherited by an entire stack.
    @Published public var thumbnail: NSImage?
    @Published public var isHovered: Bool = false

    public var isStack: Bool {
        if case .stack = itemType { return true }
        return fileURLs.count > 1
    }

    public var count: Int {
        if case .stack(let urls) = itemType {
            return urls.count
        }
        return fileURLs.isEmpty ? 1 : fileURLs.count
    }

    public static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool {
        lhs.id == rhs.id && lhs.isLocked == rhs.isLocked && lhs.title == rhs.title
    }

    public init(
        id: UUID = UUID(),
        title: String,
        subtitle: String = "",
        itemType: ShelfItemType,
        fileURLs: [URL] = [],
        isLocked: Bool = false,
        isGenerated: Bool = false,
        thumbnail: NSImage? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.itemType = itemType
        self.fileURLs = fileURLs
        self.dateAdded = Date()
        self.isLocked = isLocked
        self.generatedURLs = isGenerated ? Set(fileURLs.filter { ActionExecutor.isStagedFile($0) }.map { $0.standardizedFileURL }) : []
        self.thumbnail = thumbnail

        if thumbnail == nil {
            generateThumbnail()
        }
    }

    public static func from(urls: [URL], isGenerated: Bool = false) -> ShelfItem {
        guard !urls.isEmpty else {
            return ShelfItem(title: "Empty", itemType: .textSnippet(""))
        }

        if urls.count == 1 {
            let url = urls[0]
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

            let title = url.lastPathComponent
            let subtitle = formattedFileSize(url: url, isDir: isDir.boolValue)

            if isDir.boolValue {
                return ShelfItem(title: title, subtitle: subtitle, itemType: .folder(url), fileURLs: [url], isGenerated: isGenerated)
            } else {
                return ShelfItem(title: title, subtitle: subtitle, itemType: .file(url), fileURLs: [url], isGenerated: isGenerated)
            }
        } else {
            let title = "\(urls.count) Items"
            let totalSize = urls.reduce(Int64(0)) { sum, url in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                return sum + size
            }
            let subtitle = "\(urls.count) files • \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))"
            return ShelfItem(title: title, subtitle: subtitle, itemType: .stack(urls), fileURLs: urls, isGenerated: isGenerated)
        }
    }

    public static func combining(_ items: [ShelfItem]) -> ShelfItem {
        let result = from(urls: items.flatMap { $0.fileURLs })
        result.generatedURLs = items.reduce(into: Set<URL>()) { $0.formUnion($1.generatedURLs) }
        result.isLocked = items.contains { $0.isLocked }
        return result
    }

    public func retaining(urls: [URL]) -> ShelfItem {
        let result = ShelfItem.from(urls: urls)
        result.generatedURLs = generatedURLs.intersection(urls.map { $0.standardizedFileURL })
        result.isLocked = isLocked
        return result
    }

    public static func from(text: String) -> ShelfItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Detect Hex or RGB Color Code
        if let parsedColor = parseColor(text: trimmed) {
            return ShelfItem(
                title: parsedColor.hex,
                subtitle: parsedColor.rgbString,
                itemType: .color(hex: parsedColor.hex, color: parsedColor.color),
                fileURLs: []
            )
        }

        // 2. Detect Web URLs
        var urlCandidate = trimmed
        if urlCandidate.lowercased().hasPrefix("www.") {
            urlCandidate = "https://" + urlCandidate
        }
        if let url = URL(string: urlCandidate), (url.scheme == "http" || url.scheme == "https"), let host = url.host {
            let pathLast = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/").last
            let titleText = (pathLast != nil && !pathLast!.isEmpty) ? pathLast! : host
            return ShelfItem(
                title: titleText,
                subtitle: host,
                itemType: .webLink(url),
                fileURLs: []
            )
        }

        // 3. Fallback: Formatted Text Snippet
        let lines = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let title = lines.first?.prefix(35).description ?? "Text Snippet"
        let lineCount = lines.count
        let charCount = text.count
        let subtitle = "\(charCount) chars • \(lineCount) line\(lineCount == 1 ? "" : "s")"
        return ShelfItem(
            title: title.isEmpty ? "Text Snippet" : title,
            subtitle: subtitle,
            itemType: .textSnippet(text),
            fileURLs: []
        )
    }

    public static func parseColor(text: String) -> (hex: String, rgbString: String, color: NSColor)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A. Hex color (#FFF, #FFFFFF, #FFFFFFFF, or without leading #)
        var hexStr = trimmed
        let hasHash = hexStr.hasPrefix("#")
        if hasHash {
            hexStr.removeFirst()
        }
        let hexChars = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        if (hexStr.count == 3 || hexStr.count == 6 || hexStr.count == 8) && CharacterSet(charactersIn: hexStr).isSubset(of: hexChars) && (hasHash || hexStr.count == 6) {
            var hexInt: UInt64 = 0
            Scanner(string: hexStr).scanHexInt64(&hexInt)
            let r, g, b, a: CGFloat
            if hexStr.count == 3 {
                r = CGFloat((hexInt >> 8) & 0xF) / 15.0
                g = CGFloat((hexInt >> 4) & 0xF) / 15.0
                b = CGFloat(hexInt & 0xF) / 15.0
                a = 1.0
            } else if hexStr.count == 6 {
                r = CGFloat((hexInt >> 16) & 0xFF) / 255.0
                g = CGFloat((hexInt >> 8) & 0xFF) / 255.0
                b = CGFloat(hexInt & 0xFF) / 255.0
                a = 1.0
            } else {
                r = CGFloat((hexInt >> 24) & 0xFF) / 255.0
                g = CGFloat((hexInt >> 16) & 0xFF) / 255.0
                b = CGFloat((hexInt >> 8) & 0xFF) / 255.0
                a = CGFloat(hexInt & 0xFF) / 255.0
            }
            let nsColor = NSColor(red: r, green: g, blue: b, alpha: a)
            let rgbText = "rgb(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)))"
            return ("#" + hexStr.uppercased(), rgbText, nsColor)
        }

        // B. RGB color rgb(r, g, b)
        if trimmed.lowercased().hasPrefix("rgb(") && trimmed.hasSuffix(")") {
            let inner = trimmed.dropFirst(4).dropLast()
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3,
               let rVal = Double(parts[0]), let gVal = Double(parts[1]), let bVal = Double(parts[2]) {
                let r = CGFloat(min(255, max(0, rVal))) / 255.0
                let g = CGFloat(min(255, max(0, gVal))) / 255.0
                let b = CGFloat(min(255, max(0, bVal))) / 255.0
                let hex = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
                let nsColor = NSColor(red: r, green: g, blue: b, alpha: 1.0)
                return (hex, "rgb(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)))", nsColor)
            }
        }
        return nil
    }

    public func generateThumbnail() {
        switch itemType {
        case .file(let url), .folder(let url):
            generateFileThumbnail(url: url)
        case .stack(let urls):
            if let first = urls.first {
                generateFileThumbnail(url: first)
            }
        case .webLink:
            self.thumbnail = NSImage(systemSymbolName: "globe", accessibilityDescription: "Web Link")
        case .color(_, let color):
            let img = NSImage(size: NSSize(width: 88, height: 88))
            img.lockFocus()
            let path = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 84, height: 84), xRadius: 16, yRadius: 16)
            color.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 2
            path.stroke()
            img.unlockFocus()
            self.thumbnail = img
        case .textSnippet:
            self.thumbnail = NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: "Text")
        case .image(let img, _):
            self.thumbnail = img
        }
    }

    private func generateFileThumbnail(url: URL) {
        let size = CGSize(width: 128, height: 128)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateRepresentations(for: request) { [weak self] representation, type, error in
            if let rep = representation {
                DispatchQueue.main.async {
                    self?.thumbnail = rep.nsImage
                }
            } else {
                DispatchQueue.main.async {
                    self?.thumbnail = NSWorkspace.shared.icon(forFile: url.path)
                }
            }
        }
    }

    private static func formattedFileSize(url: URL, isDir: Bool) -> String {
        if isDir {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
            return "\(count) items • Folder"
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            let ext = url.pathExtension.uppercased()
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            return ext.isEmpty ? sizeStr : "\(sizeStr) • \(ext)"
        }
        return url.pathExtension.uppercased()
    }
}
