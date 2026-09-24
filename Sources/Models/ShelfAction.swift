import SwiftUI

public enum ActionType: String, CaseIterable, Identifiable {
    case zip = "zip"
    case copyPath = "copyPath"
    case airDrop = "airDrop"
    case desktop = "desktop"
    case downloads = "downloads"
    case convertImage = "convertImage"
    case pdfTools = "pdfTools"
    case trash = "trash"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .zip: return "Zip Archive"
        case .copyPath: return "Copy Path"
        case .airDrop: return "AirDrop"
        case .desktop: return "Desktop"
        case .downloads: return "Downloads"
        case .convertImage: return "Image Tools"
        case .pdfTools: return "PDF Tools"
        case .trash: return "Trash"
        }
    }

    public var shortTitle: String {
        switch self {
        case .zip: return "Zip"
        case .copyPath: return "Copy"
        case .airDrop: return "AirDrop"
        case .desktop: return "Desktop"
        case .downloads: return "Downloads"
        case .convertImage: return "Images"
        case .pdfTools: return "PDF"
        case .trash: return "Trash"
        }
    }

    public var tooltip: String {
        switch self {
        case .zip: return "Zip Archive (Maximum -9 compression, staged for dragging)"
        case .copyPath: return "Copy file paths to clipboard"
        case .airDrop: return "Share files via AirDrop"
        case .desktop: return "Send/copy files to Desktop (~/Desktop)"
        case .downloads: return "Send/copy files to Downloads (~/Downloads)"
        case .convertImage: return "Resize, convert images or remove backgrounds"
        case .pdfTools: return "Merge PDFs, reorder pages or create a PDF from images"
        case .trash: return "Move files to Trash"
        }
    }

    public var icon: String {
        switch self {
        case .zip: return "archivebox.fill"
        case .copyPath: return "doc.on.doc.fill"
        case .airDrop: return "paperplane.circle.fill"
        case .desktop: return "menubar.dock.rectangle"
        case .downloads: return "arrow.down.circle.fill"
        case .convertImage: return "photo.fill.on.rectangle.fill"
        case .pdfTools: return "doc.richtext"
        case .trash: return "trash.fill"
        }
    }

    public var tintColor: Color {
        switch self {
        case .zip: return Color.orange
        case .copyPath: return Color.blue
        case .airDrop: return Color.cyan
        case .desktop: return Color.indigo
        case .downloads: return Color.green
        case .convertImage: return Color.purple
        case .pdfTools: return Color.teal
        case .trash: return Color.red
        }
    }
}
