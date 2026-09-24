import Cocoa

let app = NSApplication.shared
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("DropShelf-operation-tests-\(UUID().uuidString)", isDirectory: true)
let sources = root.appendingPathComponent("sources", isDirectory: true)
let destinations = root.appendingPathComponent("destinations", isDirectory: true)
try fm.createDirectory(at: sources, withIntermediateDirectories: true)
try fm.createDirectory(at: destinations, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: " + message) }
    checks += 1
    print("PASS: " + message)
}

func writeLargeFile(_ url: URL, megabytes: Int) throws {
    fm.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var state: UInt64 = 0x9E3779B97F4A7C15
    var bytes = [UInt8](repeating: 0, count: 1024 * 1024)
    for _ in 0..<megabytes {
        for index in bytes.indices {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            bytes[index] = UInt8(truncatingIfNeeded: state)
        }
        try handle.write(contentsOf: Data(bytes))
    }
}

let cancelledSource = sources.appendingPathComponent("cancelled.bin")
try writeLargeFile(cancelledSource, megabytes: 12)
let cancelledOriginal = try Data(contentsOf: cancelledSource)
let cancelledDestination = destinations.appendingPathComponent("cancelled.bin")
let cancelledContext = OperationContext()
var observedByteProgress = false
do {
    _ = try CancellableFileTransfer.transfer(
        source: cancelledSource,
        destination: cancelledDestination,
        kind: .copy,
        context: cancelledContext
    ) { fraction in
        if fraction != nil { observedByteProgress = true }
        cancelledContext.cancel()
    }
    fatalError("Cancelled copy unexpectedly completed")
} catch is CancellationError {
    check(true, "Cancellation interrupts an in-flight byte copy")
}
check(observedByteProgress, "Regular-file copy reports byte progress")
check(fm.fileExists(atPath: cancelledSource.path), "Cancelled copy preserves its source")
let cancelledAfter = try Data(contentsOf: cancelledSource)
check(cancelledAfter == cancelledOriginal, "Cancelled copy leaves every source byte unchanged")
check(!fm.fileExists(atPath: cancelledDestination.path), "Cancelled copy does not publish a destination")
let partials = try fm.contentsOfDirectory(at: destinations, includingPropertiesForKeys: nil)
    .filter { $0.lastPathComponent.hasSuffix(".partial") }
check(partials.isEmpty, "Cancelled copy removes its private partial file")

let copiedSource = sources.appendingPathComponent("copy.txt")
try Data("exact copy contents".utf8).write(to: copiedSource)
let copiedDestination = destinations.appendingPathComponent("copy.txt")
let copyOutcome = try CancellableFileTransfer.transfer(
    source: copiedSource,
    destination: copiedDestination,
    kind: .copy,
    context: OperationContext()
)
check(!copyOutcome.sourceRemoved, "Copy reports that the source remains")
let copiedBytes = try Data(contentsOf: copiedDestination)
check(copiedBytes == Data("exact copy contents".utf8), "Completed copy preserves file bytes")

let linkTarget = sources.appendingPathComponent("link-target.txt")
try Data("do not dereference".utf8).write(to: linkTarget)
let linkSource = sources.appendingPathComponent("source-link")
try fm.createSymbolicLink(atPath: linkSource.path, withDestinationPath: linkTarget.lastPathComponent)
let linkDestination = destinations.appendingPathComponent("copied-link")
_ = try CancellableFileTransfer.transfer(
    source: linkSource,
    destination: linkDestination,
    kind: .copy,
    context: OperationContext()
)
let linkValues = try linkDestination.resourceValues(forKeys: [.isSymbolicLinkKey])
check(linkValues.isSymbolicLink == true, "Copy preserves a symbolic link instead of following it")
let copiedLinkTarget = try fm.destinationOfSymbolicLink(atPath: linkDestination.path)
check(copiedLinkTarget == linkTarget.lastPathComponent, "Copied symbolic link preserves its original target")

let movedSource = sources.appendingPathComponent("move.txt")
try Data("move contents".utf8).write(to: movedSource)
let movedDestination = destinations.appendingPathComponent("move.txt")
let moveOutcome = try CancellableFileTransfer.transfer(
    source: movedSource,
    destination: movedDestination,
    kind: .move,
    context: OperationContext()
)
check(moveOutcome.sourceRemoved, "Same-volume move reports source removal")
check(!fm.fileExists(atPath: movedSource.path), "Completed move removes its source")
let movedBytes = try Data(contentsOf: movedDestination)
check(movedBytes == Data("move contents".utf8), "Completed move preserves file bytes")

let partialSources = root.appendingPathComponent("partial-sources", isDirectory: true)
let partialDestinations = root.appendingPathComponent("partial-destinations", isDirectory: true)
try fm.createDirectory(at: partialSources, withIntermediateDirectories: true)
try fm.createDirectory(at: partialDestinations, withIntermediateDirectories: true)
let partialFirst = partialSources.appendingPathComponent("first.txt")
let partialSecond = partialSources.appendingPathComponent("second.txt")
try Data("first".utf8).write(to: partialFirst)
try Data("second".utf8).write(to: partialSecond)
var partialContext: OperationContext!
partialContext = OperationContext { update in
    if update.message == "Finished first.txt" { partialContext.cancel() }
}
let partialResult = ActionExecutor.shared.transferResult(
    urls: [partialFirst, partialSecond],
    targetFolder: partialDestinations,
    folderName: "Test destination",
    kind: .copy,
    context: partialContext
)
check(!partialResult.succeeded, "Partially cancelled transfer is not reported as successful")
check(partialResult.addedURLs.count == 1, "Partial transfer reports its one committed destination for reconciliation")
check(partialResult.message.hasPrefix("Cancelled after copied 1/2"), "Partial transfer reports an honest completed count")
check(fm.fileExists(atPath: partialFirst.path) && fm.fileExists(atPath: partialSecond.path), "Partially cancelled copy preserves every source")
check(fm.fileExists(atPath: partialDestinations.appendingPathComponent("first.txt").path), "Partial transfer keeps its completed copy")
check(!fm.fileExists(atPath: partialDestinations.appendingPathComponent("second.txt").path), "Partial transfer does not start the next item after cancellation")

let stagingBefore = Set((try? fm.contentsOfDirectory(at: ActionExecutor.stagingDirectory, includingPropertiesForKeys: nil)) ?? [])
let zipSource = sources.appendingPathComponent("zip-cancel.bin")
try writeLargeFile(zipSource, megabytes: 8)
var zipContext: OperationContext!
zipContext = OperationContext { update in
    if update.message.hasPrefix("Compressing") { zipContext.cancel() }
}
do {
    _ = try ActionExecutor.shared.createArchive(urls: [zipSource], context: zipContext)
    fatalError("Cancelled ZIP unexpectedly completed")
} catch is CancellationError {
    check(true, "Cancellation terminates an active ZIP process")
}
let stagingAfter = Set((try? fm.contentsOfDirectory(at: ActionExecutor.stagingDirectory, includingPropertiesForKeys: nil)) ?? [])
check(stagingAfter == stagingBefore, "Cancelled ZIP removes its job directory and partial archive")
check(fm.fileExists(atPath: zipSource.path), "Cancelled ZIP preserves its input")

print("All \(checks) operation checks passed")
