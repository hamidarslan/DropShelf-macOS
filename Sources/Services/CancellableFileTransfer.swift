import Foundation
import Darwin

enum FileTransferKind: Equatable {
    case copy
    case move
}

struct FileTransferOutcome {
    let destination: URL
    let sourceRemoved: Bool
}

private final class CopyfileCallbackBox {
    let context: OperationContext
    let totalBytes: Int64?
    let progress: (Double?) -> Void

    init(context: OperationContext, totalBytes: Int64?, progress: @escaping (Double?) -> Void) {
        self.context = context
        self.totalBytes = totalBytes
        self.progress = progress
    }
}

private let dropShelfCopyfileCallback: copyfile_callback_t = { what, stage, state, _, _, opaque in
    guard let opaque else { return COPYFILE_CONTINUE }
    let box = Unmanaged<CopyfileCallbackBox>.fromOpaque(opaque).takeUnretainedValue()
    if box.context.isCancelled { return COPYFILE_QUIT }
    guard what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS else { return COPYFILE_CONTINUE }
    var copied: off_t = 0
    if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0,
       let total = box.totalBytes, total > 0 {
        box.progress(min(1, Double(copied) / Double(total)))
    } else {
        box.progress(nil)
    }
    return COPYFILE_CONTINUE
}

enum CancellableFileTransfer {
    static func uniqueDestination(for source: URL, in directory: URL, fileManager: FileManager = .default) -> URL {
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        while fileManager.fileExists(atPath: destination.path) {
            let name = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            let candidate = ext.isEmpty ? "\(name) \(counter)" : "\(name) \(counter).\(ext)"
            destination = directory.appendingPathComponent(candidate)
            counter += 1
        }
        return destination
    }

    static func transfer(
        source: URL,
        destination: URL,
        kind: FileTransferKind,
        context: OperationContext,
        progress: @escaping (Double?) -> Void = { _ in }
    ) throws -> FileTransferOutcome {
        let fm = FileManager.default
        try context.checkCancellation()
        guard source.isFileURL, destination.isFileURL, fm.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }

        if kind == .move, sameVolume(source, destination.deletingLastPathComponent()) {
            try context.checkCancellation()
            try fm.moveItem(at: source, to: destination)
            return FileTransferOutcome(destination: destination, sourceRemoved: true)
        }

        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".dropshelf-\(UUID().uuidString).partial", isDirectory: false)
        var committed = false
        defer {
            if !committed { try? fm.removeItem(at: partial) }
        }

        try copy(source: source, destination: partial, context: context, progress: progress)
        try context.checkCancellation()
        try fm.moveItem(at: partial, to: destination)
        committed = true

        if kind == .move {
            // The destination is fully committed before the source is removed. A failed removal
            // leaves two complete copies and is surfaced to the caller without risking data loss.
            if context.isCancelled {
                do {
                    try fm.removeItem(at: destination)
                    committed = false
                } catch {
                    throw CommittedTransferError(destination: destination, underlying: error)
                }
                throw CancellationError()
            }
            do {
                try fm.removeItem(at: source)
                return FileTransferOutcome(destination: destination, sourceRemoved: true)
            } catch {
                throw CommittedTransferError(destination: destination, underlying: error)
            }
        }
        return FileTransferOutcome(destination: destination, sourceRemoved: false)
    }

    private static func copy(
        source: URL,
        destination: URL,
        context: OperationContext,
        progress: @escaping (Double?) -> Void
    ) throws {
        guard let state = copyfile_state_alloc() else { throw CocoaError(.fileWriteUnknown) }
        defer { copyfile_state_free(state) }

        let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let totalBytes = values?.isRegularFile == true ? values?.fileSize.map(Int64.init) : nil
        let box = CopyfileCallbackBox(context: context, totalBytes: totalBytes, progress: progress)
        let opaque = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<CopyfileCallbackBox>.fromOpaque(opaque).release() }
        let callbackPointer = unsafeBitCast(dropShelfCopyfileCallback, to: UnsafeRawPointer.self)
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callbackPointer) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), opaque) == 0 else {
            throw POSIXError(.EINVAL)
        }

        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, state, flags)
            }
        }
        if status != 0 {
            if context.isCancelled || errno == ECANCELED { throw CancellationError() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try context.checkCancellation()
        progress(1)
    }

    private static func sameVolume(_ source: URL, _ destinationDirectory: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let sourceID = try? source.resourceValues(forKeys: keys).volumeIdentifier
        let destinationID = try? destinationDirectory.resourceValues(forKeys: keys).volumeIdentifier
        guard let sourceID, let destinationID else { return false }
        return String(describing: sourceID) == String(describing: destinationID)
    }
}

struct CommittedTransferError: LocalizedError {
    let destination: URL
    let underlying: Error
    var errorDescription: String? {
        "Created \(destination.lastPathComponent), but could not remove the source: \(underlying.localizedDescription)"
    }
}
