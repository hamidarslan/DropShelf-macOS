import Cocoa
import SwiftUI

public class ActionExecutor {
    public static let shared = ActionExecutor()

    public static var stagingDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DropShelf_Staging", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            // Guarantee 0700 owner-only permissions across app sessions
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        return dir
    }

    public static func isStagedFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DropShelf_Staging", isDirectory: true)
        let lexicalRoot = root.standardizedFileURL.path + "/"
        let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
        return url.standardizedFileURL.path.hasPrefix(lexicalRoot)
            && url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot)
    }

    public static func purgeStagingDirectory() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DropShelf_Staging", isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in contents {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    public func execute(action: ActionType, urls: [URL], sourceView: NSView?, completion: @escaping (Bool, String) -> Void) {
        guard !urls.isEmpty else {
            completion(false, "No files selected")
            return
        }

        switch action {
        case .zip:
            compressFiles(urls: urls, completion: completion)
        case .copyPath:
            copyPaths(urls: urls, completion: completion)
        case .airDrop:
            shareAirDrop(urls: urls, sourceView: sourceView, completion: completion)
        case .desktop:
            moveToSpecialFolder(urls: urls, folder: .desktopDirectory, completion: completion)
        case .downloads:
            moveToSpecialFolder(urls: urls, folder: .downloadsDirectory, completion: completion)
        case .convertImage:
            MediaToolsWindowController.shared.show(kind: .images, urls: urls)
            completion(true, "Opened Image Tools")
        case .pdfTools:
            MediaToolsWindowController.shared.show(kind: .pdf, urls: urls)
            completion(true, "Opened PDF Tools")
        case .trash:
            moveToTrash(urls: urls, completion: completion)
        }
    }

    // Runs synchronously off the main thread; throws rather than accepting a partial archive.
    public func createArchive(urls: [URL], context: OperationContext? = nil) throws -> URL {
        let fm = FileManager.default
        let operation = context ?? OperationContext()
        try operation.checkCancellation()
        guard !urls.isEmpty, urls.allSatisfy({ $0.isFileURL && fm.fileExists(atPath: $0.path) }) else {
            throw NSError(domain: "DropShelf", code: 1, userInfo: [NSLocalizedDescriptionKey: "One or more source files are unavailable"])
        }
        let job = ActionExecutor.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: job) } }
        let input = job.appendingPathComponent("input", isDirectory: true)
        try fm.createDirectory(at: input, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: input) }
        let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let destination = job.appendingPathComponent(name + ".zip")
        let parent = urls[0].deletingLastPathComponent().standardizedFileURL
        let sameParent = urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == parent }
        var entries: [String] = []
        if sameParent {
            entries = urls.map { "./" + $0.lastPathComponent }
        } else {
            // Separate source directories preserve identical filenames without collisions.
            for (index, url) in urls.enumerated() {
                try operation.checkCancellation()
                let sourceDir = input.appendingPathComponent("Source-\(index + 1)", isDirectory: true)
                try fm.createDirectory(at: sourceDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                _ = try CancellableFileTransfer.transfer(
                    source: url,
                    destination: sourceDir.appendingPathComponent(url.lastPathComponent),
                    kind: .copy,
                    context: operation
                ) { fraction in
                    operation.progress(fraction.map { (Double(index) + $0) / Double(urls.count) }, "Preparing \(url.lastPathComponent)")
                }
                entries.append("./Source-\(index + 1)/" + url.lastPathComponent)
            }
        }
        try operation.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = sameParent ? parent : input
        process.arguments = ["-q", "-9", "-r", "-y", "-X", destination.path, "--"] + entries
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        operation.progress(nil, "Compressing \(urls.count) item(s)")
        try process.run()
        operation.setInterrupt {
            if process.isRunning { process.terminate() }
        }
        defer { operation.setInterrupt(nil) }
        process.waitUntilExit()
        try operation.checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              fm.fileExists(atPath: destination.path) else {
            throw NSError(domain: "DropShelf", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "ZIP failed; no archive was added (exit \(process.terminationStatus))"])
        }
        succeeded = true
        return destination
    }

    private func compressFiles(urls: [URL], completion: @escaping (Bool, String) -> Void) {
        OperationCoordinator.shared.start(title: "Creating ZIP", inputs: urls, work: { context in
            let destination = try self.createArchive(urls: urls, context: context)
            return OperationResult(generatedURLs: [destination], message: "ZIP ready to drag")
        }, completion: { success, message in
            if success { ShelfStore.shared.playSound("Glass") }
            completion(success, message)
        })
    }

    func transferResult(
        urls: [URL],
        targetFolder: URL,
        folderName: String,
        kind: FileTransferKind,
        context: OperationContext
    ) -> OperationResult {
        let fm = FileManager.default
        var added: [URL] = []
        var forgotten: [URL] = []
        var completed = 0
        var failures: [String] = []

        for (index, url) in urls.enumerated() {
            do {
                try context.checkCancellation()
                if url.deletingLastPathComponent().standardizedFileURL == targetFolder.standardizedFileURL {
                    added.append(url)
                    completed += 1
                    context.progress(Double(index + 1) / Double(urls.count), "Already in \(folderName): \(url.lastPathComponent)")
                    continue
                }
                let destination = CancellableFileTransfer.uniqueDestination(for: url, in: targetFolder, fileManager: fm)
                let outcome = try CancellableFileTransfer.transfer(
                    source: url,
                    destination: destination,
                    kind: kind,
                    context: context
                ) { fraction in
                    let overall = fraction.map { (Double(index) + $0) / Double(urls.count) }
                    context.progress(overall, "\(kind == .move ? "Moving" : "Copying") \(url.lastPathComponent)")
                }
                added.append(outcome.destination)
                if outcome.sourceRemoved { forgotten.append(url) }
                completed += 1
                context.progress(Double(index + 1) / Double(urls.count), "Finished \(url.lastPathComponent)")
            } catch is CancellationError {
                break
            } catch let error as CommittedTransferError {
                added.append(error.destination)
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let verb = kind == .move ? "Moved" : "Copied"
        let message: String
        if context.isCancelled {
            message = "Cancelled after \(verb.lowercased()) \(completed)/\(urls.count) item(s) to \(folderName)"
        } else if failures.isEmpty {
            message = "\(verb) \(completed)/\(urls.count) item(s) to \(folderName)"
        } else {
            message = "\(verb) \(completed)/\(urls.count) item(s) to \(folderName). Failed: \(failures.joined(separator: "; "))"
        }
        return OperationResult(
            addedURLs: added,
            forgottenURLs: forgotten,
            message: message,
            succeeded: !context.isCancelled && failures.isEmpty && completed == urls.count
        )
    }

    private func copyPaths(urls: [URL], completion: @escaping (Bool, String) -> Void) {
        let paths = urls.map { $0.path }.joined(separator: "\n")
        let pboard = NSPasteboard.general
        pboard.clearContents()
        pboard.setString(paths, forType: .string)
        pboard.writeObjects(urls as [NSURL])

        ShelfStore.shared.playSound("Tink")
        let countStr = urls.count == 1 ? "Path" : "\(urls.count) paths"

        // Keep items on shelf as requested by user
        ShelfStore.shared.addItems(from: urls)
        completion(true, "\(countStr) copied to clipboard")
    }

    private func shareAirDrop(urls: [URL], sourceView: NSView?, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.main.async {
            ShelfStore.shared.addItems(from: urls)
            if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) {
                service.perform(withItems: urls)
                completion(true, "Opened AirDrop")
                return
            }

            let view = sourceView ?? ShelfStore.shared.panelController?.panel.contentView
            guard let targetView = view else {
                completion(false, "Cannot show share sheet")
                return
            }
            let picker = NSSharingServicePicker(items: urls)
            picker.show(relativeTo: targetView.bounds, of: targetView, preferredEdge: .minY)
            completion(true, "Opened sharing options")
        }
    }

    private func moveToSpecialFolder(urls: [URL], folder: FileManager.SearchPathDirectory, completion: @escaping (Bool, String) -> Void) {
        let isCutMode = ShelfStore.shared.transferMode == .cut
        let folderName = folder == .desktopDirectory ? "Desktop" : "Downloads"
        let kind: FileTransferKind = isCutMode ? .move : .copy
        OperationCoordinator.shared.start(title: "\(isCutMode ? "Moving" : "Copying") to \(folderName)", inputs: urls, work: { context in
            guard let target = FileManager.default.urls(for: folder, in: .userDomainMask).first else {
                throw NSError(domain: "DropShelf", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(folderName) directory not found"])
            }
            return self.transferResult(urls: urls, targetFolder: target, folderName: folderName, kind: kind, context: context)
        }, completion: { success, message in
            if success { ShelfStore.shared.playSound("Glass") }
            completion(success, message)
        })
    }

    private func moveToTrash(urls: [URL], completion: @escaping (Bool, String) -> Void) {
        OperationCoordinator.shared.start(title: "Moving to Trash", inputs: urls, work: { context in
            var trashed = 0
            var trashedURLs: [URL] = []
            var failures: [String] = []
            for (index, url) in urls.enumerated() {
                do {
                    try context.checkCancellation()
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    trashed += 1
                    trashedURLs.append(url)
                    context.progress(Double(index + 1) / Double(urls.count), "Moved \(url.lastPathComponent) to Trash")
                } catch is CancellationError {
                    break
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let message: String
            if context.isCancelled {
                message = "Cancelled after moving \(trashed)/\(urls.count) item(s) to Trash"
            } else if failures.isEmpty {
                message = "Moved \(trashed)/\(urls.count) item(s) to Trash"
            } else {
                message = "Moved \(trashed)/\(urls.count) item(s) to Trash. Failed: \(failures.joined(separator: "; "))"
            }
            return OperationResult(
                forgottenURLs: trashedURLs,
                message: message,
                succeeded: !context.isCancelled && failures.isEmpty && trashed == urls.count
            )
        }, completion: { success, message in
            if success { ShelfStore.shared.playSound("Basso") }
            completion(success, message)
        })
    }
}
