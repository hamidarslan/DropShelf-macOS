import SwiftUI
import AppKit

public enum BrandIcon: String, CaseIterable {
    case shelf = "Shelf", drop = "Drop", moveCopy = "MoveCopy", multiple = "Multiple"
    case history = "History", settings = "Settings", pin = "Pin", clear = "Clear", mark = "Mark"

    var fallback: String {
        switch self {
        case .shelf: return "tray"
        case .drop: return "tray.and.arrow.down"
        case .moveCopy: return "doc.on.doc"
        case .multiple: return "square.stack"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        case .pin: return "pin"
        case .clear: return "trash"
        case .mark: return "tray.and.arrow.down"
        }
    }
}

public enum BrandAssets {
    public static let appIcon: NSImage? = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
    private static let icons = Dictionary(uniqueKeysWithValues: BrandIcon.allCases.map { icon in
        (icon, template(named: icon.rawValue, subdirectory: "BrandIcons", pointSize: 32)
            ?? NSImage(systemSymbolName: icon.fallback, accessibilityDescription: nil))
    })
    private static let menuNormal = template(named: "menubar_icon", pointSize: 18)
    private static let menuDrop = template(named: "menubar_icon_drop", pointSize: 18)

    public static func icon(_ icon: BrandIcon) -> NSImage? { icons[icon] ?? nil }
    public static func menuBar(isDragging: Bool) -> NSImage? {
        (isDragging ? menuDrop : menuNormal) ?? icon(.shelf)
    }

    public static func template(named: String, subdirectory: String? = nil, pointSize: CGFloat,
                                bundle: Bundle = .main) -> NSImage? {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        for suffix in ["", "@2x"] {
            guard let url = bundle.url(forResource: named + suffix, withExtension: "png", subdirectory: subdirectory),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = image.size
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        return image
    }
}

public struct BrandIconView: View {
    @ObservedObject private var store = ShelfStore.shared
    let icon: BrandIcon
    let size: CGFloat
    public init(_ icon: BrandIcon, size: CGFloat = 12) { self.icon = icon; self.size = size }
    public var body: some View {
        Group {
            if store.useRefinedClassic, let image = RefinedAssets.image(RefinedAssets.brand(icon)) {
                Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
            } else if let image = BrandAssets.icon(icon) {
                Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: icon.fallback).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

public struct AppIconView: View {
    public var size: CGFloat
    public init(size: CGFloat = 18) { self.size = size }
    public var body: some View {
        Group {
            if let image = BrandAssets.appIcon {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                BrandIconView(.mark, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
