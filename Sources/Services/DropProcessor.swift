import Cocoa
import SwiftUI

public class DropProcessor {
    public static func handleDrop(sender: NSDraggingInfo, view: NSView? = nil) -> Bool {
        let pboard = sender.draggingPasteboard
        // Private clipboard exports must never enter file staging or file actions.
        guard pboard.types?.contains(ClipboardPasteboard.privateType) != true else { return false }
        if ShelfStore.shared.section == .clipboard {
            ShelfStore.shared.section = .files
            ShelfStore.shared.targetedAction = nil
            ShelfStore.shared.actionTileFrames.removeAll()
        }
        // Archive apps and attachment providers materialize these only after a drop.
        if let receivers = pboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            return receivePromises(receivers, action: ShelfStore.shared.targetedAction ?? detectActionTarget(sender: sender, view: view), view: view)
        }
        var urls: [URL] = []

        // 1. NSFilenamesPboardType (Classic Finder Drag format - most direct and reliable)
        if let paths = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String], !paths.isEmpty {
            for path in paths {
                let u = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: u.path) {
                    urls.append(u)
                }
            }
        }

        // 2. Read NSURLs directly
        if urls.isEmpty, let fileURLs = pboard.readObjects(forClasses: [NSURL.self], options: nil) {
            for item in fileURLs {
                if let u = item as? URL, u.isFileURL {
                    urls.append(u)
                } else if let ns = item as? NSURL, let u = ns as URL?, u.isFileURL {
                    urls.append(u)
                }
            }
        }

        // 3. Extract from NSPasteboardItems for .fileURL or "public.file-url"
        if urls.isEmpty {
            for item in pboard.pasteboardItems ?? [] {
                if let str = item.string(forType: .fileURL), let u = URL(string: str), u.isFileURL {
                    urls.append(u)
                } else if let str = item.string(forType: NSPasteboard.PasteboardType("public.file-url")), let u = URL(string: str), u.isFileURL {
                    urls.append(u)
                }
            }
        }

        // 4. Check if string in pasteboard is an existing file path
        if urls.isEmpty, let str = pboard.string(forType: .string) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.fileExists(atPath: trimmed) {
                urls.append(URL(fileURLWithPath: trimmed))
            } else if trimmed.hasPrefix("file://"), let u = URL(string: trimmed), FileManager.default.fileExists(atPath: u.path) {
                urls.append(u)
            }
        }

        // 5. Web URLs (non-file URLs)
        if urls.isEmpty, let urlStr = pboard.string(forType: .URL), let u = URL(string: urlStr) {
            if u.isFileURL {
                urls.append(u)
            } else {
                ShelfStore.shared.addItems(from: [u])
                if ShelfStore.shared.autoCollapseAfterDrop {
                    ShelfStore.shared.autoCollapseAfterDrop = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if !ShelfStore.shared.items.isEmpty {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                ShelfStore.shared.isCollapsed = true
                            }
                        } else {
                            ShelfStore.shared.hidePanel(animated: true)
                        }
                    }
                }
                return true
            }
        }

        // IF WE FOUND FILE URLS (100% authentic files from Finder, Desktop, etc.):
        if !urls.isEmpty {
            let action = ShelfStore.shared.targetedAction ?? detectActionTarget(sender: sender, view: view)

            if let action = action {
                ActionExecutor.shared.execute(action: action, urls: urls, sourceView: view) { success, msg in
                    ShelfStore.shared.showStatus(message: msg)
                }
            } else {
                ShelfStore.shared.addItems(from: urls)
            }
            ShelfStore.shared.targetedAction = nil

            if ShelfStore.shared.autoCollapseAfterDrop {
                ShelfStore.shared.autoCollapseAfterDrop = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if !ShelfStore.shared.items.isEmpty {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            ShelfStore.shared.isCollapsed = true
                        }
                    } else {
                        ShelfStore.shared.hidePanel(animated: true)
                    }
                }
            }
            return true
        }

        // 6. ONLY if no files exist anywhere, handle as text snippet
        if let text = pboard.string(forType: .string), !text.isEmpty {
            ShelfStore.shared.addTextSnippet(text: text)
            if ShelfStore.shared.autoCollapseAfterDrop {
                ShelfStore.shared.autoCollapseAfterDrop = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if !ShelfStore.shared.items.isEmpty {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            ShelfStore.shared.isCollapsed = true
                        }
                    } else {
                        ShelfStore.shared.hidePanel(animated: true)
                    }
                }
            }
            return true
        }

        return false
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "DropShelf.FilePromises"
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func receivePromises(_ receivers: [NSFilePromiseReceiver], action: ActionType?, view: NSView?) -> Bool {
        let destination = ActionExecutor.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            ShelfStore.shared.showStatus(message: "Cannot receive files: \(error.localizedDescription)")
            return false
        }
        let store = ShelfStore.shared
        store.pendingFilePromises += 1
        store.autoCollapseAfterDrop = false
        store.panelController?.cancelMenuBarAutoDismissTimer()
        store.showPanel(animated: true)
        store.showStatus(message: "Preparing files from source app…")
        let batch = PromiseBatch(receivers: receivers, destination: destination, action: action, view: view)
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) { url, error in
                DispatchQueue.main.async { batch.received(url, error: error) }
            }
        }
        return true
    }

    private final class PromiseBatch {
        let receivers: [NSFilePromiseReceiver]
        let destination: URL
        let action: ActionType?
        weak var view: NSView?
        var urls: [URL] = []
        var errors: [String] = []
        var completed = 0
        init(receivers: [NSFilePromiseReceiver], destination: URL, action: ActionType?, view: NSView?) {
            self.receivers = receivers
            self.destination = destination
            self.action = action
            self.view = view
        }
        func received(_ url: URL, error: Error?) {
            completed += 1
            if let error = error {
                errors.append(error.localizedDescription)
            } else if ActionExecutor.isStagedFile(url), FileManager.default.fileExists(atPath: url.path) {
                urls.append(url)
            } else {
                errors.append("The source app did not deliver a readable file")
            }
            // Legacy promises may contain several files per advertised type.
            let expected = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }
            guard completed >= expected else { return }
            let store = ShelfStore.shared
            // Queue additions before releasing the keep-open guard.
            if !urls.isEmpty { store.addItems(from: urls, isGenerated: true) }
            DispatchQueue.main.async {
                store.pendingFilePromises = max(0, store.pendingFilePromises - 1)
                if !self.errors.isEmpty {
                    store.showStatus(message: "Received \(self.urls.count); failed \(self.errors.count): \(self.errors.joined(separator: "; "))")
                } else if let action = self.action, !self.urls.isEmpty {
                    ActionExecutor.shared.execute(action: action, urls: self.urls, sourceView: self.view) { _, message in
                        store.showStatus(message: message)
                    }
                }
                if self.urls.isEmpty { try? FileManager.default.removeItem(at: self.destination) }
            }
        }
    }

    public static func updateDraggingHover(sender: NSDraggingInfo, view: NSView? = nil) {
        ShelfStore.shared.isDraggingOverShelf = true
        ShelfStore.shared.targetedAction = detectActionTarget(sender: sender, view: view)
    }

    public static func detectActionTarget(sender: NSDraggingInfo, view: NSView? = nil) -> ActionType? {
        guard ShelfStore.shared.section == .files, ShelfStore.shared.showActionGrid else { return nil }

        let targetView = view ?? sender.draggingDestinationWindow?.contentView
        guard let hostingView = targetView else { return nil }

        let localPoint = hostingView.convert(sender.draggingLocation, from: nil)

        return actionTarget(at: localPoint, frames: ShelfStore.shared.actionTileFrames)
    }

    static func actionTarget(at point: CGPoint, frames: [ActionType: CGRect]) -> ActionType? {
        for (action, frame) in frames {
            if frame.contains(point) {
                return action
            }
        }

        return nil
    }
}
