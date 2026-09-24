import Foundation
import CoreML
import CryptoKit
import Combine

public enum BackgroundModelStoreError: LocalizedError {
    case unsupportedSystem
    case notInstalled
    case integrityFailed
    case needsPreparation
    case cannotCreateStorage(String)
    case downloadFailed(String)
    case invalidDownload(String)
    case compilationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            return "The Quality model requires macOS 15 or later. Choose Apple Vision on macOS 14."
        case .notInstalled:
            return "The Quality model is not installed. Download it from Image Tools or Settings first."
        case .integrityFailed:
            return "The installed Quality model is damaged or incomplete. Choose Retry model installation in Settings or Image Tools."
        case .needsPreparation:
            return "The Quality model needs preparation for this Mac. Finish installation in Image Tools or Settings."
        case .cannotCreateStorage(let detail): return "Could not prepare private model storage: \(detail)"
        case .downloadFailed(let detail): return "Could not download the Quality model: \(detail)"
        case .invalidDownload(let file): return "The downloaded Quality model failed verification (\(file)). Nothing was installed."
        case .compilationFailed(let detail): return "Could not prepare the Quality model: \(detail)"
        }
    }
}

/// Owns the optional, pinned Core ML model. Only model files are downloaded; user images never leave the Mac.
public final class BackgroundModelStore: ObservableObject {
    public static let shared = BackgroundModelStore()

    public enum Status: Equatable {
        case checking
        case notInstalled
        case downloading(Double)
        case compiling
        case needsPreparation
        case ready
        case failed(String)
    }

    @Published public private(set) var status: Status = .checking

    public static let modelRevision = "be1968e77e87f67299736468a399f0149cc6d283"
    public static let upstreamRevision = "e2bf8e4460fc8fa32bba5ea4d94b3233d367b0e4"
    public static let downloadBytes: Int64 = 496_147_208

    private struct ModelFile {
        let relativePath: String
        let bytes: Int64
        let sha256: String
        var remoteURL: URL {
            let escaped = relativePath.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }.joined(separator: "/")
            return URL(string: "https://huggingface.co/avencera/birefnet-coreml-gpu/resolve/\(BackgroundModelStore.modelRevision)/BiRefNet_1024_fp16.mlpackage/\(escaped)")!
        }
    }

    private static let files = [
        ModelFile(relativePath: "Manifest.json", bytes: 617,
                  sha256: "0f522249c250021c824e3599fe9dd828eb6aec08f975c63baa6a2c34fa5e9a13"),
        ModelFile(relativePath: "Data/com.apple.CoreML/model.mlmodel", bytes: 3_386_367,
                  sha256: "ac7298614fbc0af03f675f166b878feb371827732ec2219a426636c0e50b449e"),
        ModelFile(relativePath: "Data/com.apple.CoreML/weights/weight.bin", bytes: 492_760_224,
                  sha256: "b3c815201e41044b3fec8d7a9dd68cd0844e670ee0157cac5c92c326d9db7d1d")
    ]

    private let fileManager: FileManager
    private let installLock = NSLock()
    private let activityLock = NSLock()
    private var activeOperation = false
    private var compiledLoadFailed = false
    public let modelRootURL: URL

    public convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.init(modelRoot: base.appendingPathComponent("DropShelf/Models", isDirectory: true))
    }

    /// Allows tests to prove no model storage or network activity occurs during processing.
    public init(modelRoot: URL, fileManager: FileManager = .default) {
        self.modelRootURL = modelRoot
        self.fileManager = fileManager
        refreshStatus()
    }

    public var packageURL: URL { modelRootURL.appendingPathComponent("BiRefNet-1024-FP16.mlpackage", isDirectory: true) }
    public var compiledModelURL: URL { modelRootURL.appendingPathComponent("BiRefNet-1024-FP16.mlmodelc", isDirectory: true) }
    private var compiledMarkerURL: URL { modelRootURL.appendingPathComponent("BiRefNet-1024-FP16.compiled-source") }
    private var compiledMarker: String {
        "artifact=\(Self.modelRevision)\nupstream=\(Self.upstreamRevision)\nmanifest=\(Self.files[0].sha256)\nmodel=\(Self.files[1].sha256)\nweights=\(Self.files[2].sha256)\n"
    }

    public func refreshStatus() {
        guard !isActive else { return }
        guard #available(macOS 15.0, *) else { publishIfIdle(.failed("Quality requires macOS 15 or later")); return }
        if packageFilesLookComplete(), compiledCacheIsCurrent(), !hasCompiledLoadFailure { publishIfIdle(.ready) }
        else if packageFilesLookComplete() { publishIfIdle(.needsPreparation) }
        else if fileManager.fileExists(atPath: packageURL.path) { publishIfIdle(.failed("Quality model files are damaged. Retry model installation.")) }
        else { publishIfIdle(.notInstalled) }
    }

    /// Returns a verified, prepared local model. This method never creates storage or uses the network.
    public func installedModel(context: OperationContext) throws -> URL {
        guard #available(macOS 15.0, *) else { throw BackgroundModelStoreError.unsupportedSystem }
        try context.checkCancellation()
        installLock.lock(); defer { installLock.unlock() }
        try context.checkCancellation()
        switch try packageState() {
        case .missing:
            publish(.notInstalled)
            throw BackgroundModelStoreError.notInstalled
        case .invalid:
            publish(.failed(BackgroundModelStoreError.integrityFailed.localizedDescription))
            throw BackgroundModelStoreError.integrityFailed
        case .valid:
            guard compiledCacheIsCurrent() else {
                publish(.needsPreparation)
                throw BackgroundModelStoreError.needsPreparation
            }
            publish(.ready)
            return compiledModelURL
        }
    }

    /// Explicitly downloads, verifies, and compiles the pinned package after a user chooses Download.
    public func installModel(context: OperationContext) throws -> URL {
        guard #available(macOS 15.0, *) else { throw BackgroundModelStoreError.unsupportedSystem }
        try context.checkCancellation()
        installLock.lock(); defer { installLock.unlock() }
        try context.checkCancellation()
        beginActivity(); defer { endActivity() }

        do {
            try removeAbandonedDownloads()
            let state = try packageState()
            if case .valid = state, compiledCacheIsCurrent(), !hasCompiledLoadFailure {
                do {
                    let configuration = MLModelConfiguration()
                    configuration.computeUnits = .cpuAndGPU
                    _ = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
                    publish(.ready)
                    return compiledModelURL
                } catch {
                    setCompiledLoadFailure(true)
                }
            }
            try context.checkCancellation()
            try createPrivateDirectory(modelRootURL)
            if case .valid = state {
                // A verified package can be prepared again without another download.
            } else {
                try removeManagedArtifacts(includePackage: true)
                try context.checkCancellation()
                try downloadPackage(context: context)
            }
            try context.checkCancellation()
            publish(.compiling); context.progress(nil, "Preparing Quality model for this Mac…")
            var temporaryCompiled: URL? = try MLModel.compileModel(at: packageURL)
            defer { if let temporaryCompiled { try? fileManager.removeItem(at: temporaryCompiled) } }
            try context.checkCancellation()
            if fileManager.fileExists(atPath: compiledModelURL.path) { try fileManager.removeItem(at: compiledModelURL) }
            try fileManager.moveItem(at: temporaryCompiled!, to: compiledModelURL)
            temporaryCompiled = nil
            try setPrivatePermissions(compiledModelURL)
            try Data(compiledMarker.utf8).write(to: compiledMarkerURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: compiledMarkerURL.path)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndGPU
            do { _ = try MLModel(contentsOf: compiledModelURL, configuration: configuration) }
            catch {
                setCompiledLoadFailure(true)
                throw BackgroundModelStoreError.compilationFailed("The prepared model could not be opened: \(error.localizedDescription)")
            }
            setCompiledLoadFailure(false)
            publish(.ready)
            return compiledModelURL
        } catch is CancellationError {
            publishStatusFromDisk()
            throw CancellationError()
        } catch {
            publish(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Removes only DropShelf's pinned model artifacts. Calls are serialized with install and use.
    public func removeInstalledModel(context: OperationContext) throws {
        try context.checkCancellation()
        installLock.lock(); defer { installLock.unlock() }
        try context.checkCancellation()
        beginActivity(); defer { endActivity() }
        do {
            try removeManagedArtifacts(includePackage: true)
            setCompiledLoadFailure(false)
            publish(.notInstalled)
        } catch {
            publish(.failed("Could not remove the Quality model: \(error.localizedDescription)"))
            throw error
        }
    }

    /// Records a failed Core ML load without modifying model files or initiating repair.
    public func reportCompiledModelLoadFailure() {
        setCompiledLoadFailure(true)
        publish(.needsPreparation)
    }

    private enum PackageState { case missing, valid, invalid }

    private func packageState() throws -> PackageState {
        guard fileManager.fileExists(atPath: packageURL.path) else { return .missing }
        for file in Self.files {
            let url = packageURL.appendingPathComponent(file.relativePath)
            guard fileManager.fileExists(atPath: url.path) else { return .invalid }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard Int64(values.fileSize ?? -1) == file.bytes, try sha256(url) == file.sha256 else { return .invalid }
        }
        return .valid
    }

    private func downloadPackage(context: OperationContext) throws {
        try context.checkCancellation()
        let stage = modelRootURL.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try createPrivateDirectory(stage)
        defer { try? fileManager.removeItem(at: stage); context.setInterrupt(nil) }
        var completed: Int64 = 0
        for file in Self.files {
            try context.checkCancellation()
            let destination = stage.appendingPathComponent(file.relativePath)
            try createPrivateDirectory(destination.deletingLastPathComponent())
            try download(file: file, to: destination, completedBytes: completed, context: context)
            let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard Int64(size) == file.bytes, try sha256(destination) == file.sha256 else {
                throw BackgroundModelStoreError.invalidDownload(file.relativePath)
            }
            completed += file.bytes
        }
        try context.checkCancellation()
        if fileManager.fileExists(atPath: packageURL.path) { try fileManager.removeItem(at: packageURL) }
        try fileManager.moveItem(at: stage, to: packageURL)
        try setPrivatePermissions(packageURL)
    }

    private func download(file: ModelFile, to destination: URL, completedBytes: Int64, context: OperationContext) throws {
        try context.checkCancellation()
        let semaphore = DispatchSemaphore(value: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 30
        let session = URLSession(configuration: configuration)
        var result: Result<Void, Error>?
        var exceededExpectedSize = false
        let task = session.downloadTask(with: file.remoteURL) { temporaryURL, response, error in
            defer { semaphore.signal() }
            if let error = error { result = .failure(error); return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let temporaryURL = temporaryURL else {
                result = .failure(BackgroundModelStoreError.downloadFailed("The model host returned an invalid response.")); return
            }
            if response?.expectedContentLength ?? -1 > 0, response!.expectedContentLength != file.bytes {
                result = .failure(BackgroundModelStoreError.invalidDownload(file.relativePath)); return
            }
            do {
                if self.fileManager.fileExists(atPath: destination.path) { try self.fileManager.removeItem(at: destination) }
                try self.fileManager.moveItem(at: temporaryURL, to: destination)
                result = .success(())
            } catch { result = .failure(error) }
        }
        context.setInterrupt { task.cancel() }
        task.resume()
        while semaphore.wait(timeout: .now() + 0.15) == .timedOut {
            if context.isCancelled { task.cancel() }
            let received = max(0, task.countOfBytesReceived)
            if received > file.bytes { exceededExpectedSize = true; task.cancel() }
            let fraction = Double(completedBytes + min(received, file.bytes)) / Double(Self.downloadBytes)
            publish(.downloading(fraction))
            context.progress(fraction * 0.86, "Downloading Quality model… \(Int(fraction * 100))%")
        }
        context.setInterrupt(nil); session.finishTasksAndInvalidate()
        if exceededExpectedSize { throw BackgroundModelStoreError.invalidDownload(file.relativePath) }
        switch result {
        case .success?: return
        case .failure(let error)?:
            if context.isCancelled { throw CancellationError() }
            throw BackgroundModelStoreError.downloadFailed(error.localizedDescription)
        case nil: throw BackgroundModelStoreError.downloadFailed("The transfer ended unexpectedly.")
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        do { try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw BackgroundModelStoreError.cannotCreateStorage(error.localizedDescription) }
    }

    private func compiledCacheIsCurrent() -> Bool {
        guard fileManager.fileExists(atPath: compiledModelURL.path),
              let marker = try? String(contentsOf: compiledMarkerURL, encoding: .utf8) else { return false }
        return marker == compiledMarker
    }

    private var isActive: Bool {
        activityLock.lock(); defer { activityLock.unlock() }
        return activeOperation
    }

    private var hasCompiledLoadFailure: Bool {
        activityLock.lock(); defer { activityLock.unlock() }
        return compiledLoadFailed
    }

    private func setCompiledLoadFailure(_ value: Bool) {
        activityLock.lock(); compiledLoadFailed = value; activityLock.unlock()
    }

    private func beginActivity() {
        activityLock.lock(); activeOperation = true; activityLock.unlock()
    }

    private func endActivity() {
        activityLock.lock(); activeOperation = false; activityLock.unlock()
    }

    private func publishStatusFromDisk() {
        if packageFilesLookComplete(), compiledCacheIsCurrent(), !hasCompiledLoadFailure { publish(.ready) }
        else if packageFilesLookComplete() { publish(.needsPreparation) }
        else if fileManager.fileExists(atPath: packageURL.path) { publish(.failed("Quality model files are damaged. Remove and download again.")) }
        else { publish(.notInstalled) }
    }

    private func packageFilesLookComplete() -> Bool {
        Self.files.allSatisfy { file in
            let url = packageURL.appendingPathComponent(file.relativePath)
            guard fileManager.fileExists(atPath: url.path),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
            return Int64(size) == file.bytes
        }
    }

    private func removeManagedArtifacts(includePackage: Bool) throws {
        if fileManager.fileExists(atPath: compiledModelURL.path) { try fileManager.removeItem(at: compiledModelURL) }
        if fileManager.fileExists(atPath: compiledMarkerURL.path) { try fileManager.removeItem(at: compiledMarkerURL) }
        if includePackage, fileManager.fileExists(atPath: packageURL.path) { try fileManager.removeItem(at: packageURL) }
        try removeAbandonedDownloads()
    }

    private func removeAbandonedDownloads() throws {
        guard fileManager.fileExists(atPath: modelRootURL.path) else { return }
        let prefix = ".download-"
        for url in try fileManager.contentsOfDirectory(at: modelRootURL, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            // Removing this exact child also removes a symlink itself, never its target.
            try fileManager.removeItem(at: url)
        }
    }

    private func setPrivatePermissions(_ root: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if let iterator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in iterator {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                try fileManager.setAttributes([.posixPermissions: isDirectory ? 0o700 : 0o600], ofItemAtPath: url.path)
            }
        }
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func publish(_ value: Status) { DispatchQueue.main.async { self.status = value } }

    private func publishIfIdle(_ value: Status) {
        activityLock.lock()
        guard !activeOperation else { activityLock.unlock(); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isActive else { return }
            self.status = value
        }
        activityLock.unlock()
    }
}
