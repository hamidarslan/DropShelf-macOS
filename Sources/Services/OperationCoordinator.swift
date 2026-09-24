import Cocoa
import Combine

public struct OperationUpdate {
    public let fraction: Double?
    public let message: String
}

/// The worker owns its files until it returns successfully. Cancellation never publishes them.
public final class OperationContext {
    private let lock = NSLock()
    private var cancelled = false
    private var interrupt: (() -> Void)?
    private var lastReportTime: TimeInterval = 0
    private var lastReportMessage = ""
    private let report: (OperationUpdate) -> Void
    public init(report: @escaping (OperationUpdate) -> Void = { _ in }) { self.report = report }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func checkCancellation() throws { if isCancelled { throw CancellationError() } }
    public func cancel() {
        lock.lock(); cancelled = true; let callback = interrupt; lock.unlock()
        callback?()
    }
    public func setInterrupt(_ callback: (() -> Void)?) {
        lock.lock(); interrupt = callback; let callNow = cancelled; lock.unlock()
        if callNow { callback?() }
    }
    public func progress(_ fraction: Double?, _ message: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldReport = now - lastReportTime >= 0.08 || message != lastReportMessage || fraction == 1
        if shouldReport { lastReportTime = now; lastReportMessage = message }
        lock.unlock()
        guard shouldReport else { return }
        report(OperationUpdate(fraction: fraction.map { min(1, max(0, $0)) }, message: message))
    }
}

public struct OperationResult {
    public var generatedURLs: [URL] = []
    public var addedURLs: [URL] = []
    public var forgottenURLs: [URL] = []
    public var message: String
    public var succeeded: Bool
    public init(generatedURLs: [URL] = [], addedURLs: [URL] = [], forgottenURLs: [URL] = [], message: String, succeeded: Bool = true) {
        self.generatedURLs = generatedURLs; self.addedURLs = addedURLs
        self.forgottenURLs = forgottenURLs; self.message = message; self.succeeded = succeeded
    }
}

public final class OperationCoordinator: ObservableObject {
    public static let shared = OperationCoordinator()
    @Published public private(set) var isRunning = false
    @Published public private(set) var isCancelling = false
    @Published public private(set) var isCancellable = true
    @Published public private(set) var title = ""
    @Published public private(set) var fraction: Double? = nil
    @Published public private(set) var detail = ""
    @Published public private(set) var lastMessage = ""
    @Published public private(set) var lastSucceeded = false
    @Published public private(set) var lastOutputURLs: [URL] = []
    public private(set) var heldURLs: Set<URL> = []
    private var heldGeneratedURLs: Set<URL> = []
    private var context: OperationContext?
    private var activeID: UUID?
    private var idleCallbacks: [() -> Void] = []
    private let queue = DispatchQueue(label: "com.dropshelf.operations", qos: .userInitiated)

    /// Main-thread entry. A single job avoids races with generated-file ownership and actions.
    @discardableResult public func start(title: String, inputs: [URL], cancellable: Bool = true,
                                       work: @escaping (OperationContext) throws -> OperationResult,
                                       completion: @escaping (Bool, String) -> Void = { _, _ in }) -> Bool {
        precondition(Thread.isMainThread)
        guard !isRunning else { completion(false, "Finish or cancel the current operation first"); return false }
        let id = UUID()
        activeID = id; isRunning = true; isCancelling = false; isCancellable = cancellable; self.title = title
        fraction = nil; detail = "Preparing…"; lastMessage = ""; lastSucceeded = false; lastOutputURLs = []
        heldURLs = Set(inputs.map { $0.standardizedFileURL })
        heldGeneratedURLs = Set((ShelfStore.shared.items + ShelfStore.shared.historyItems).flatMap { $0.generatedURLs }.map { $0.standardizedFileURL }).intersection(heldURLs)
        let context = OperationContext { [weak self] update in
            DispatchQueue.main.async {
                guard let self = self, self.activeID == id else { return }
                if !self.isCancelling { self.fraction = update.fraction; self.detail = update.message }
            }
        }
        self.context = context
        queue.async {
            let result: Result<OperationResult, Error>
            do { try context.checkCancellation(); result = .success(try work(context)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard self.activeID == id else { return }
                var success = false
                let message: String
                switch result {
                case .success(let output):
                    // File transfers may have completed before cancellation. Always reconcile them.
                    if !output.forgottenURLs.isEmpty { ShelfStore.shared.forgetFiles(output.forgottenURLs) }
                    if !output.addedURLs.isEmpty { ShelfStore.shared.addItems(from: output.addedURLs) }
                    if context.isCancelled {
                        ShelfStore.shared.releaseOperationFiles(Set(output.generatedURLs))
                        message = output.addedURLs.isEmpty && output.forgottenURLs.isEmpty ? "Cancelled" : output.message
                    } else {
                        if output.succeeded {
                            if !output.generatedURLs.isEmpty { ShelfStore.shared.addItems(from: output.generatedURLs, isGenerated: true) }
                        } else { ShelfStore.shared.releaseOperationFiles(Set(output.generatedURLs)) }
                        self.lastOutputURLs = (output.succeeded ? output.generatedURLs : []) + output.addedURLs
                        success = output.succeeded; message = output.message
                    }
                case .failure(let error):
                    message = (context.isCancelled || error is CancellationError) ? "Cancelled. Incomplete outputs removed." : error.localizedDescription
                }
                ShelfStore.shared.releaseOperationFiles(self.heldGeneratedURLs)
                self.heldGeneratedURLs.removeAll()
                self.heldURLs.removeAll(); self.activeID = nil; self.context = nil
                self.isRunning = false; self.isCancelling = false; self.isCancellable = true; self.fraction = success ? 1 : nil
                self.detail = message; self.lastMessage = message; self.lastSucceeded = success
                ShelfStore.shared.showStatus(message: message)
                completion(success, message)
                let callbacks = self.idleCallbacks; self.idleCallbacks.removeAll()
                callbacks.forEach { $0() }
            }
        }
        return true
    }

    public func cancel() {
        precondition(Thread.isMainThread)
        guard isRunning, isCancellable else { return }
        isCancelling = true; detail = "Cancelling after the current step…"
        context?.cancel()
    }

    public func cancelAndWhenIdle(_ callback: @escaping () -> Void) {
        if !isRunning { callback(); return }
        idleCallbacks.append(callback); cancel()
    }

    /// All generated media operations use a private directory, removed on failure/cancellation.
    public static func withOutputDirectory(context: OperationContext, body: (URL) throws -> [URL]) throws -> [URL] {
        let fm = FileManager.default
        let directory = ActionExecutor.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let urls = try body(directory)
            try context.checkCancellation()
            let lexical = directory.standardizedFileURL.path + "/"
            let resolved = directory.resolvingSymlinksInPath().path + "/"
            guard !urls.isEmpty, urls.allSatisfy({ $0.isFileURL && $0.standardizedFileURL.path.hasPrefix(lexical) && $0.resolvingSymlinksInPath().path.hasPrefix(resolved) && fm.fileExists(atPath: $0.path) }) else {
                throw NSError(domain: "DropShelf.Operations", code: 1, userInfo: [NSLocalizedDescriptionKey: "The operation did not produce valid private output files."])
            }
            return urls
        } catch { try? fm.removeItem(at: directory); throw error }
    }
}
