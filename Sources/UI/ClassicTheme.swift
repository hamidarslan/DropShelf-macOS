import SwiftUI
import AppKit

// Classic Refined tokens, using the project's direct Swift build.
struct ClassicPalette {
    let light: Bool
    private func color(_ day: UInt32, _ night: UInt32) -> Color {
        let value = light ? day : night
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
    var surface: Color { color(0xF4F6FA, 0x202630) }
    var card: Color { color(0xFFFFFF, 0x2C3441) }
    var text: Color { color(0x202C40, 0xEFF4FC) }
    var muted: Color { color(0x596A80, 0xACB9CA) }
    var border: Color { color(0xD9E1EC, 0x424E60) }
    var accent: Color { color(0x2563D6, 0x8BB4FF) }
    var selected: Color { color(0xE8F0FF, 0x2D4364) }
    var subtle: Color { color(0xE9EEF5, 0x252D39) }
    var onAccent: Color { color(0xFFFFFF, 0x152840) }
    var danger: Color { color(0xBD3542, 0xFF929C) }
    var warm: Color { color(0x966514, 0xEBC077) }
}

// PNG exports from the approved vector components.
enum RefinedAssets {
    static let names = ["history", "grid", "settings", "collapse", "copy", "cut", "zip", "airdrop", "desktop", "download", "image", "trash", "pin", "eye", "close", "stack", "split", "file", "link", "check"]
    private static let images: [String: NSImage] = Dictionary(uniqueKeysWithValues: names.compactMap { name in
        guard let image = BrandAssets.template(named: name, subdirectory: "RefinedIcons", pointSize: 12) else { return nil }
        return (name, image)
    })
    static func image(_ name: String) -> NSImage? { images[name] }
    static let symbols = [
        "square.grid.2x2.fill": "grid", "square.grid.2x2": "grid",
        "chevron.right.2": "collapse", "chevron.left.2": "collapse", "scissors": "cut",
        "archivebox.fill": "zip", "doc.on.doc.fill": "copy", "paperplane.circle.fill": "airdrop",
        "menubar.dock.rectangle": "desktop", "arrow.down.circle.fill": "download",
        "photo.fill.on.rectangle.fill": "image", "trash.fill": "trash",
        "eye.fill": "eye", "xmark": "close", "xmark.circle.fill": "close",
        "square.split.2x1": "split", "doc.fill": "file", "arrow.up.right.square": "link",
        "checkmark": "check", "checkmark.circle.fill": "check", "arrow.uturn.backward": "history"
    ]
    static func brand(_ icon: BrandIcon) -> String {
        switch icon {
        case .history: return "history"
        case .settings: return "settings"
        case .moveCopy: return "copy"
        case .multiple: return "stack"
        case .pin: return "pin"
        case .clear: return "trash"
        case .drop, .mark, .shelf: return "download"
        }
    }
}

struct ShelfSymbol: View {
    let systemName: String
    @ObservedObject private var store = ShelfStore.shared
    var body: some View {
        Group {
            if store.useRefinedClassic, let name = RefinedAssets.symbols[systemName], let image = RefinedAssets.image(name) {
                Image(nsImage: image).renderingMode(.template)
                    .rotationEffect(.degrees(systemName == "chevron.left.2" ? 180 : 0))
            } else { Image(systemName: systemName) }
        }
    }
}
