import Cocoa

func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
    print("PASS: \(label)")
}

@discardableResult
func waitUntil(_ label: String, timeout: TimeInterval = 4, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    check(condition(), label)
    return true
}

func makeStagedFile(name: String = UUID().uuidString + ".tmp", contents: String = "fixture") throws -> URL {
    let directory = ActionExecutor.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
    return url
}

func cleanStagedFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

let coordinator = OperationCoordinator.shared
let shelf = ShelfStore.shared
shelf.enableSoundEffects = false
shelf.items = []
shelf.historyItems = []
check(Thread.isMainThread, "coordinator tests run on the main thread")
check(!coordinator.isRunning, "coordinator begins idle")

// A running operation owns the single execution slot. Both accepted and rejected
// completions are delivered exactly once on the main thread.
let firstStarted = DispatchSemaphore(value: 0)
let finishFirst = DispatchSemaphore(value: 0)
var firstCallbacks = 0
var firstCallbackOnMain = false
let accepted = coordinator.start(title: "First", inputs: []) { _ in
    firstStarted.signal()
    finishFirst.wait()
    return OperationResult(message: "First complete")
} completion: { success, _ in
    firstCallbacks += 1
    firstCallbackOnMain = Thread.isMainThread
    check(success, "first operation succeeds")
}
check(accepted, "first operation is accepted")
check(firstStarted.wait(timeout: .now() + 2) == .success, "first operation starts")
var rejectedCallbacks = 0
var rejectedCallbackOnMain = false
let rejected = coordinator.start(title: "Second", inputs: []) { _ in
    preconditionFailure("rejected work must never run")
} completion: { success, message in
    rejectedCallbacks += 1
    rejectedCallbackOnMain = Thread.isMainThread
    check(!success && message.contains("current operation"), "second operation reports the active-job conflict")
}
check(!rejected, "second operation is rejected while one is running")
check(rejectedCallbacks == 1 && rejectedCallbackOnMain, "rejected completion runs once on the main thread")
finishFirst.signal()
waitUntil("accepted completion runs") { !coordinator.isRunning }
check(firstCallbacks == 1 && firstCallbackOnMain, "accepted completion runs once on the main thread")

// Cancellation wins even when non-cooperative work returns a nominal success.
let cancelledOutput = try makeStagedFile(name: "cancelled-output.txt")
let cancelWorkStarted = DispatchSemaphore(value: 0)
let letCancelledWorkReturn = DispatchSemaphore(value: 0)
var cancelledCallbacks = 0
let cancelAccepted = coordinator.start(title: "Cancellation", inputs: []) { _ in
    cancelWorkStarted.signal()
    letCancelledWorkReturn.wait()
    return OperationResult(generatedURLs: [cancelledOutput], message: "Should not publish")
} completion: { success, message in
    cancelledCallbacks += 1
    check(!success && message == "Cancelled", "cancelled nominal success is reported as cancelled")
}
check(cancelAccepted, "cancellable operation is accepted")
check(cancelWorkStarted.wait(timeout: .now() + 2) == .success, "cancellable work starts")
coordinator.cancel()
check(coordinator.isCancelling, "cancellation state is visible immediately")
letCancelledWorkReturn.signal()
waitUntil("cancelled operation returns to idle") { !coordinator.isRunning }
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
check(cancelledCallbacks == 1, "cancelled completion runs once")
check(!FileManager.default.fileExists(atPath: cancelledOutput.path), "cancelled generated output is removed")
check(!shelf.items.contains { $0.fileURLs.contains(cancelledOutput) }, "cancelled generated output is never published")

// A destructive operation that cannot be rolled back ignores cancellation. Quit-style
// waiting still waits for the operation to finish and reports the real successful result.
let removalStarted = DispatchSemaphore(value: 0)
let finishRemoval = DispatchSemaphore(value: 0)
var removalCompletion = false
var removalSucceeded = false
var idleAfterRemoval = false
check(coordinator.start(title: "Non-cancellable removal", inputs: [], cancellable: false) { context in
    removalStarted.signal()
    finishRemoval.wait()
    check(!context.isCancelled, "non-cancellable work context is never marked cancelled")
    return OperationResult(message: "Downloaded model removed")
} completion: { success, message in
    removalCompletion = true
    removalSucceeded = success && message == "Downloaded model removed"
}, "non-cancellable removal starts")
check(removalStarted.wait(timeout: .now() + 2) == .success, "non-cancellable removal work starts")
check(coordinator.isRunning && !coordinator.isCancellable, "non-cancellable state is published")
coordinator.cancel()
check(coordinator.isRunning && !coordinator.isCancelling, "direct cancellation is ignored for non-cancellable work")
coordinator.cancelAndWhenIdle { idleAfterRemoval = true }
check(!idleAfterRemoval, "quit-style callback waits while non-cancellable work runs")
finishRemoval.signal()
waitUntil("non-cancellable removal reaches idle") { removalCompletion && idleAfterRemoval && !coordinator.isRunning }
check(removalSucceeded, "non-cancellable removal reports its truthful successful result")
check(coordinator.lastSucceeded && coordinator.lastMessage == "Downloaded model removed", "non-cancellable success remains the last result")
check(coordinator.isCancellable, "idle coordinator restores the default cancellable state")

// A completed result marked unsuccessful cannot publish or retain generated files.
let failedOutput = try makeStagedFile(name: "failed-output.txt")
var failedCallback = false
check(coordinator.start(title: "Failed result", inputs: []) { _ in
    OperationResult(generatedURLs: [failedOutput], message: "Validation failed", succeeded: false)
} completion: { success, message in
    failedCallback = true
    check(!success && message == "Validation failed", "failed result keeps its diagnostic")
}, "failed-result operation starts")
waitUntil("failed-result completion runs") { failedCallback && !coordinator.isRunning }
check(!FileManager.default.fileExists(atPath: failedOutput.path), "failed generated output is removed")
check(!shelf.items.contains { $0.fileURLs.contains(failedOutput) }, "failed generated output is not published")
check(!coordinator.lastSucceeded && coordinator.lastOutputURLs.isEmpty, "failed result does not become the last successful output")

// Staged source ownership survives history clearing while work is active, then
// is released once the operation is idle and no shelf item references it.
let heldInput = try makeStagedFile(name: "held-input.txt")
let historyItem = ShelfItem(title: heldInput.lastPathComponent, itemType: .file(heldInput),
                            fileURLs: [heldInput], isGenerated: true, thumbnail: NSImage(size: NSSize(width: 1, height: 1)))
shelf.historyItems = [historyItem]
let holdStarted = DispatchSemaphore(value: 0)
let releaseHold = DispatchSemaphore(value: 0)
var holdCompleted = false
check(coordinator.start(title: "Held source", inputs: [heldInput]) { _ in
    holdStarted.signal()
    releaseHold.wait()
    return OperationResult(message: "Held source complete")
} completion: { success, _ in
    holdCompleted = true
    check(success, "held-source operation succeeds")
}, "held-source operation starts")
check(holdStarted.wait(timeout: .now() + 2) == .success, "held-source work starts")
shelf.clearHistory()
check(shelf.historyItems.isEmpty, "history clears during the operation")
check(FileManager.default.fileExists(atPath: heldInput.path), "active staged input survives history clearing")
releaseHold.signal()
waitUntil("held-source operation becomes idle") { holdCompleted && !coordinator.isRunning }
check(!FileManager.default.fileExists(atPath: heldInput.path), "unreferenced staged input is removed after idle")

// The private-output wrapper accepts only existing files that stay inside its
// newly created directory, both lexically and after symlink resolution.
let wrapperContext = OperationContext()
let valid = try OperationCoordinator.withOutputDirectory(context: wrapperContext) { directory in
    let output = directory.appendingPathComponent("valid.txt")
    try Data("valid".utf8).write(to: output)
    return [output]
}
check(valid.count == 1 && FileManager.default.fileExists(atPath: valid[0].path), "private output wrapper accepts an existing contained file")
let validDirectory = valid[0].deletingLastPathComponent()
try? FileManager.default.removeItem(at: validDirectory)

let outsideRoot = FileManager.default.temporaryDirectory.appendingPathComponent("dropshelf-coordinator-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: outsideRoot) }
let outsideFile = outsideRoot.appendingPathComponent("outside.txt")
try Data("outside".utf8).write(to: outsideFile)

func expectInvalidPrivateOutput(_ label: String, body: (URL) throws -> [URL]) {
    do {
        _ = try OperationCoordinator.withOutputDirectory(context: OperationContext(), body: body)
        preconditionFailure("Expected invalid private output: \(label)")
    } catch {
        check(error.localizedDescription.contains("valid private output"), label)
    }
}

expectInvalidPrivateOutput("outside output is rejected") { _ in [outsideFile] }
expectInvalidPrivateOutput("missing output is rejected") { directory in
    [directory.appendingPathComponent("missing.txt")]
}
expectInvalidPrivateOutput("escaped symlink output is rejected") { directory in
    let link = directory.appendingPathComponent("escape.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
    return [link]
}

// A successful result becomes the last result and its callback is delivered once.
var successCallbacks = 0
check(coordinator.start(title: "Successful result", inputs: []) { _ in
    OperationResult(message: "Operation ready")
} completion: { success, message in
    successCallbacks += 1
    check(success && message == "Operation ready", "successful result reports success")
}, "successful-result operation starts")
waitUntil("successful-result completion runs") { successCallbacks == 1 && !coordinator.isRunning }
check(coordinator.lastSucceeded, "last result records success")
check(coordinator.lastMessage == "Operation ready", "last result retains its success message")
check(coordinator.lastOutputURLs.isEmpty, "successful operation without files reports no outputs")
check(successCallbacks == 1, "successful completion runs once")

print("PASS: operation coordinator regression suite")
