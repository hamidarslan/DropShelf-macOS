import Cocoa
import Foundation

let app = NSApplication.shared
let store = ShelfStore.shared
store.enableSoundEffects = false
store.autoStackMultiple = false
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("DropShelf-tests-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: " + message) }
    checks += 1
    print("PASS: " + message)
}
func drain() {
    let pending = DispatchGroup()
    pending.enter()
    DispatchQueue.main.async { pending.leave() }
    let deadline = Date().addingTimeInterval(5)
    while pending.wait(timeout: .now()) != .success {
        precondition(Date() < deadline, "Main-queue work did not finish")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}
func file(_ relative: String, _ content: String) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
    return url
}
var drag = ContentDragSession(lastChangeCount: 10)
check(!drag.observe(changeCount: 10, hasContent: true, mouseDown: true, enabled: true), "Window movement with unchanged pasteboard does not start content drag")
check(drag.observe(changeCount: 11, hasContent: true, mouseDown: true, enabled: true), "Fresh content drag starts immediately without shake or edge movement")
check(ContentDragSession.shouldSummonOnStart(enabled: true, shakeOnly: false), "Default mode summons shelf on drag start")
check(!ContentDragSession.shouldSummonOnStart(enabled: true, shakeOnly: true), "Shake-only mode suppresses immediate summon")
check(!ContentDragSession.shouldSummonOnStart(enabled: false, shakeOnly: false), "Disabled automatic showing stays disabled")
check(!drag.observe(changeCount: 12, hasContent: true, mouseDown: true, enabled: true), "Pasteboard updates within active drag do not repeatedly summon")
_ = drag.observe(changeCount: 12, hasContent: true, mouseDown: false, enabled: true)
check(!drag.isActive, "Mouse release ends content drag")
check(!drag.observe(changeCount: 12, hasContent: true, mouseDown: true, enabled: true), "Stale payload after release cannot trigger window movement")
check(drag.observe(changeCount: 13, hasContent: true, mouseDown: true, enabled: true), "Next fresh drag triggers again")
_ = drag.observe(changeCount: 14, hasContent: true, mouseDown: true, enabled: false)
check(!drag.isActive, "Disabling auto-show resets active drag detection")
check(!drag.observe(changeCount: 14, hasContent: true, mouseDown: true, enabled: true), "Re-enabling does not replay a drag observed while disabled")
check(!drag.observe(changeCount: 15, hasContent: false, mouseDown: true, enabled: true), "Unsupported payload cannot summon shelf")

// Exercise the real monitor and panel with deterministic native input samples.
// No events are posted to Finder and the user's drag pasteboard is untouched.
let dragController = FloatingPanelController()
final class DragTestPanel: FloatingPanel {
    var orderOutCount = 0
    override func orderOut(_ sender: Any?) {
        orderOutCount += 1
        super.orderOut(sender)
    }
}
final class DragInfoStub: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions,
                                for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
let dragPanel = DragTestPanel(contentRect: dragController.panel.frame)
dragPanel.contentView = dragController.panel.contentView
dragPanel.alphaValue = 0
dragController.panel = dragPanel
let dragHost = dragController.panel.contentView as! ShelfDropHostingView
let monitor = GlobalDragMonitor.shared
store.autoShowOnDrag = true
store.shakeOnlyToShow = false
store.section = .files
let away = NSPoint(x: -10_000, y: -10_000)
var dragFailures: [String] = []
func dragCheck(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { check(true, message) }
    else { dragFailures.append(message); print("FAIL: " + message) }
}
func sample(_ x: CGFloat, time: TimeInterval, down: Bool = true, revision: Int = 501) {
    monitor.processDragSample(changeCount: revision, hasContent: true, mouseDown: down,
                              location: NSPoint(x: away.x + x, y: away.y), time: time)
}
sample(0, time: 0, down: false, revision: 500)
sample(0, time: 1)
dragCheck(store.isPanelVisible, "Content drag reveals the real panel immediately")
store.isDraggingOverShelf = true
dragHost.draggingExited(nil)
dragCheck(store.isPanelVisible, "Leaving the shelf while still dragging does not dismiss it")
dragController.show(animated: false)
store.isDraggingOverShelf = true
dragController.panel.draggingExited(nil)
dragCheck(store.isPanelVisible, "Window fallback also keeps an ongoing drag visible on exit")
sample(20, time: 1.1)
sample(20, time: 3)
dragCheck(!store.isPanelVisible, "An empty shelf hides when the held drag pauses outside")
dragCheck(store.isContentDragActive, "Hiding on pause preserves the held drag session")
sample(20, time: 3.1)
dragCheck(!store.isPanelVisible, "Stationary held drag does not reopen the shelf")
sample(40, time: 3.2)
dragCheck(store.isPanelVisible, "Resumed movement reopens the shelf without a new pasteboard revision")
sample(40, time: 5)
sample(60, time: 5.1)
dragCheck(store.isPanelVisible, "Repeated pause and resume works within the same held drag")
let orderOutCountBeforeCallbacks = dragPanel.orderOutCount
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
dragCheck(store.isPanelVisible && dragPanel.orderOutCount == orderOutCountBeforeCallbacks,
          "A previous hide animation cannot remove a resumed shelf")
print("INFO: native drag window visible=\(dragPanel.isVisible), alpha=\(dragPanel.alphaValue)")
store.isDraggingOverShelf = true
sample(60, time: 7)
dragCheck(store.isPanelVisible, "Pausing over the drop target keeps it available")
store.isDraggingOverShelf = false
let insidePanel = NSPoint(x: dragController.panel.frame.midX, y: dragController.panel.frame.midY)
monitor.processDragSample(changeCount: 501, hasContent: true, mouseDown: true, location: insidePanel, time: 7.1)
monitor.processDragSample(changeCount: 501, hasContent: true, mouseDown: true, location: insidePanel, time: 7.95)
dragCheck(store.isPanelVisible, "Pointer inside the panel prevents idle dismissal even before hover callbacks arrive")
sample(60, time: 8, down: false)
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
dragCheck(!store.isPanelVisible && !store.isContentDragActive, "Releasing the drag dismisses the empty shelf")
sample(80, time: 9)
dragCheck(!store.isPanelVisible && !store.isContentDragActive, "Moving with a stale payload after release cannot reopen the shelf")

store.shakeOnlyToShow = true
sample(0, time: 10, revision: 502)
sample(30, time: 10.05, revision: 502)
dragCheck(!store.isPanelVisible, "Shake-only mode does not reveal on ordinary held-drag movement")
sample(0, time: 10.10, revision: 502)
sample(30, time: 10.15, revision: 502)
sample(0, time: 10.20, revision: 502)
dragCheck(store.isPanelVisible, "Shake-only mode still reveals after a deliberate shake")
sample(0, time: 12, revision: 502)
sample(30, time: 12.1, revision: 502)
dragCheck(!store.isPanelVisible, "Shake-only mode still requires a shake after an idle dismissal")
store.autoShowOnDrag = false
sample(60, time: 13, revision: 503)
dragCheck(!store.isPanelVisible && !store.isContentDragActive, "Disabling automatic reveal stops held-drag tracking")
store.autoShowOnDrag = true
store.shakeOnlyToShow = false
sample(80, time: 14, revision: 503)
dragCheck(!store.isPanelVisible, "Re-enabling does not revive a payload observed while disabled")
sample(0, time: 15, revision: 504)
dragCheck(store.isPanelVisible, "The next genuine drag reveals normally after re-enabling")
store.items = [ShelfItem.from(text: "Retained shelf item")]
sample(0, time: 17, revision: 504)
dragCheck(store.isPanelVisible, "Idle drag does not dismiss a populated shelf")
sample(0, time: 17.1, down: false, revision: 504)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
dragCheck(store.isPanelVisible, "Releasing a drag preserves a populated shelf")
store.items = []
store.pendingFilePromises = 1
sample(0, time: 19, revision: 505)
sample(0, time: 21, revision: 505)
dragCheck(store.isPanelVisible, "Pending promised files protect an empty shelf from idle dismissal")
sample(0, time: 21.1, down: false, revision: 505)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
dragCheck(store.isPanelVisible, "Pending promised files protect the shelf after mouse release")
store.pendingFilePromises = 0
store.items = [ShelfItem.from(text: "Collapsed shelf item")]
store.isCollapsed = true
store.autoCollapseAfterDrop = false
sample(0, time: 23, revision: 506)
dragCheck(!store.isCollapsed && store.autoCollapseAfterDrop, "A new drag temporarily expands a populated collapsed shelf")
dragHost.draggingExited(nil)
dragCheck(!store.isCollapsed && store.autoCollapseAfterDrop, "Leaving a populated shelf defers collapse until the held drag ends")
store.isCollapsed = false
store.autoCollapseAfterDrop = true
dragController.panel.draggingExited(nil)
dragCheck(!store.isCollapsed && store.autoCollapseAfterDrop, "Window fallback also defers collapse during a held drag")
sample(0, time: 25, revision: 506)
dragCheck(!store.isCollapsed, "Pausing with retained items keeps the drag-expanded shelf available")
sample(0, time: 25.1, down: false, revision: 506)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
dragCheck(store.isCollapsed && !store.autoCollapseAfterDrop, "Temporarily expanded shelf returns to its tab after mouse release")
store.isCollapsed = false
store.isPeekingFromEdgeTab = true
sample(0, time: 27, revision: 507)
dragCheck(!store.isPeekingFromEdgeTab && !store.isCollapsed && store.autoCollapseAfterDrop,
          "A held drag takes over a temporary hover expansion")
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
dragCheck(!store.isCollapsed, "Hover dismissal cannot fold away a drag-owned expansion")
sample(0, time: 28, down: false, revision: 507)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
dragCheck(store.isCollapsed && !store.autoCollapseAfterDrop, "Hover-origin expansion returns to its tab only after release")
store.items = []
store.isCollapsed = false
let dragInfo = DragInfoStub()
defer { dragInfo.draggingPasteboard.releaseGlobally() }
sample(0, time: 30, revision: 508)
dragCheck(store.isPanelVisible && store.isContentDragActive, "Cancellation fixture starts an ordinary tracked drag")
dragHost.draggingEnded(dragInfo)
dragCheck(!store.isPanelVisible && !store.isContentDragActive, "Hosting destination cancellation ends the tracked drag while the mouse remains held")
sample(30, time: 30.1, revision: 508)
dragCheck(!store.isPanelVisible && !store.isContentDragActive, "Held movement after hosting cancellation cannot reopen the shelf")
sample(60, time: 30.2, revision: 509)
dragCheck(!store.isPanelVisible && !store.isContentDragActive, "A pasteboard revision change during the held cancellation cannot restart tracking")
sample(60, time: 30.3, down: false, revision: 509)
sample(0, time: 31, revision: 510)
dragCheck(store.isPanelVisible && store.isContentDragActive, "Mouse release clears cancellation suppression for the next genuine drag")
dragController.panel.draggingEnded(dragInfo)
dragCheck(!store.isPanelVisible && !store.isContentDragActive, "Window destination cancellation also ends the tracked drag")
sample(30, time: 31.1, revision: 511)
dragCheck(!store.isPanelVisible && !store.isContentDragActive, "Window cancellation also suppresses held movement and revision changes")
sample(30, time: 31.2, down: false, revision: 511)
sample(0, time: 32, revision: 512)
dragCheck(store.isPanelVisible && store.isContentDragActive, "A genuine drag starts after window cancellation is released")
sample(0, time: 32.1, down: false, revision: 512)
monitor.stop()
dragController.hide(animated: false)
store.panelController = nil
precondition(dragFailures.isEmpty, "Drag lifecycle failures: " + dragFailures.joined(separator: "; "))

let original = try file("a/report.txt", "original A")
let second = try file("b/report.txt", "original B")
let flaggedOriginal = ShelfItem.from(urls: [original], isGenerated: true)
check(!flaggedOriginal.isGenerated, "External original cannot acquire generated ownership")
let archive = try ActionExecutor.shared.createArchive(urls: [original, second])
defer { try? fm.removeItem(at: archive.deletingLastPathComponent()) }
let extracted = root.appendingPathComponent("extracted")
let unzip = Process()
unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
unzip.arguments = ["-q", archive.path, "-d", extracted.path]
try unzip.run(); unzip.waitUntilExit()
check(unzip.terminationStatus == 0, "Archive extracts successfully")
let a = try String(contentsOf: extracted.appendingPathComponent("Source-1/report.txt"), encoding: .utf8)
let b = try String(contentsOf: extracted.appendingPathComponent("Source-2/report.txt"), encoding: .utf8)
check(a == "original A" && b == "original B", "Duplicate filenames preserve both original contents")
let dash = try file("a/-option.txt", "dash file")
let dashArchive = try ActionExecutor.shared.createArchive(urls: [dash])
defer { try? fm.removeItem(at: dashArchive.deletingLastPathComponent()) }
check(fm.fileExists(atPath: dashArchive.path), "Leading hyphen filename is not treated as ZIP option")
do {
    _ = try ActionExecutor.shared.createArchive(urls: [original, root.appendingPathComponent("missing")])
    fatalError("Missing input should fail")
} catch { check(true, "Missing ZIP input fails instead of creating partial archive") }
let generated = ShelfItem.from(urls: [archive], isGenerated: true)
store.items = [ShelfItem.from(urls: [original]), generated]
store.combineAllIntoStack(); drain()
check(store.items.count == 1, "Original and generated file stack together (count: \(store.items.count))")
check(store.items[0].generatedURLs == Set([archive.standardizedFileURL]), "Mixed stack owns only generated archive")
store.separateAll(); drain()
check(store.items.first(where: { $0.fileURLs.contains(original) })?.isGenerated == false, "Unstack preserves original ownership")
check(store.items.first(where: { $0.fileURLs.contains(archive) })?.isGenerated == true, "Unstack preserves generated ownership")
store.combineAllIntoStack(); drain()
store.clearAll(); drain()
check(fm.fileExists(atPath: original.path), "Clearing mixed stack preserves original on disk")
check(fm.fileExists(atPath: archive.path), "Generated archive remains recoverable in history")
store.restoreAllHistory(); drain()
check(store.items.flatMap { $0.fileURLs }.count == 2, "History restores both existing files")
store.clearAll(); drain(); store.clearHistory(); drain()
check(fm.fileExists(atPath: original.path), "Clearing history preserves original")
check(!fm.fileExists(atPath: archive.path), "Clearing history cleans unreferenced generated archive")
let text = ShelfItem.from(text: "keep this note")
let locked = ShelfItem.from(urls: [dash]); locked.isLocked = true
store.items = [ShelfItem.from(urls: [original]), ShelfItem.from(urls: [second]), text, locked]
store.combineAllIntoStack(); drain()
check(store.items.contains { $0.id == text.id }, "Stack all preserves non-file content")
check(store.items.contains { $0.id == locked.id && $0.isLocked }, "Stack all preserves pinned items")
let delegate = AppDelegate()
delegate.handleIncomingURL(URL(string: "dropshelf://unstack")!); drain()
let separatedCount = store.items.count
delegate.handleIncomingURL(URL(string: "dropshelf://unstack")!); drain()
check(store.items.count == separatedCount, "Repeated unstack is idempotent")
delegate.handleIncomingURL(URL(string: "dropshelf://stack")!); drain()
let stackedCount = store.items.count
delegate.handleIncomingURL(URL(string: "dropshelf://stack")!); drain()
check(store.items.count == stackedCount && store.items.contains { $0.isStack }, "Repeated stack is idempotent")
store.items = [ShelfItem.combining([ShelfItem.from(urls: [original]), ShelfItem.from(urls: [second])])]
store.forgetFiles([original])
check(store.items.flatMap { $0.fileURLs } == [second], "Partial action retains unprocessed stack member")
store.items = []
let vanished = try file("vanished.txt", "gone")
let stale = ShelfItem.from(urls: [vanished])
store.historyItems = [stale]
try fm.removeItem(at: vanished)
store.restoreFromHistory(item: stale)
check(store.items.isEmpty, "History does not restore missing file references")
let promiseBoard = NSPasteboard.withUniqueName()
for type in NSFilePromiseReceiver.readableDraggedTypes {
    promiseBoard.declareTypes([NSPasteboard.PasteboardType(type)], owner: nil)
    check(GlobalDragMonitor.hasDraggableContent(pasteboard: promiseBoard), "Promise drag recognized immediately: \(type)")
}
promiseBoard.releaseGlobally()
let many = try (0..<256).map { try file("capacity/file-\($0).txt", "capacity") }
store.items = []
store.historyItems = []
store.addItems(from: many, autoStack: true); drain()
check(store.items.flatMap { $0.fileURLs }.count == 256, "Shelf retains every file in a large incoming batch")
store.recordHistory(itemsToRecord: many.map { ShelfItem.from(urls: [$0]) })
check(store.historyItems.count == 256, "History no longer silently evicts items beyond 20")
final class TestPromiseReceiver: NSFilePromiseReceiver {
    override var fileNames: [String] { ["one.txt", "two.txt"] }
    override func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any] = [:], operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        operationQueue.addOperation {
            for name in self.fileNames {
                let url = destinationDir.appendingPathComponent(name)
                do { try Data(name.utf8).write(to: url); reader(url, nil) }
                catch { reader(url, error) }
            }
        }
    }
}
store.items = []
store.historyItems = []
check(DropProcessor.receivePromises([TestPromiseReceiver()], action: nil, view: nil), "Accepts deferred archive extraction")
check(store.pendingFilePromises == 1, "Shelf stays open during deferred extraction")
let deadline = Date().addingTimeInterval(5)
while store.pendingFilePromises > 0 && Date() < deadline { drain() }
check(store.pendingFilePromises == 0, "Receiving state completes")
check(store.items.flatMap { $0.fileURLs }.count == 2, "Legacy multi-file promise retains every extracted file")
check(store.items.allSatisfy { $0.isGenerated }, "Extracted files have managed staging ownership")
for url in store.items.flatMap({ $0.fileURLs }) {
    check(try! String(contentsOf: url, encoding: .utf8) == url.lastPathComponent, "Extracted content is intact")
    try? fm.removeItem(at: url)
}
print("All \(checks) regression checks passed")
