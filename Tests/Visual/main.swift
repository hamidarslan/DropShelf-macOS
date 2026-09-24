import Cocoa
import SwiftUI

let app = NSApplication.shared
let store = ShelfStore.shared
store.enableSoundEffects = false
store.autoStackMultiple = false
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let inputs = [root.appendingPathComponent("Resources/icon.png"), root.appendingPathComponent("README.md"), root.appendingPathComponent("LICENSE")]
for name in RefinedAssets.names { precondition(RefinedAssets.image(name) != nil, "Missing Refined icon: \(name)") }
let items = inputs.map { ShelfItem.from(urls: [$0]) }
store.items = items
store.selectedItemIDs = [items[0].id]
store.useRefinedClassic = true
let controller = FloatingPanelController()
store.panelController = controller
let host = controller.panel.contentView!

func snapshot(_ name: String, light: Bool, empty: Bool = false, many: Bool = false, history: Bool = false) throws {
    store.appearanceTheme = light ? .light : .dark
    store.items = empty ? [] : many ? (0..<12).map { ShelfItem.from(urls: [inputs[$0 % inputs.count]]) } : items
    store.selectedItemIDs = empty ? [] : [store.items[0].id]
    store.isHistoryOpen = history
    store.historyItems = history ? items : []
    controller.updateAppearance()
    controller.panel.setContentSize(NSSize(width: store.shelfWidth, height: 520))
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot render view") }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("Cannot encode render") }
    try data.write(to: output.appendingPathComponent(name + ".png"))
    print("Rendered \(name): \(host.bounds.size)")
}
try snapshot("refined-light", light: true)
func cardBridges(in view: NSView) -> [InteractiveCardDragView] {
    (view as? InteractiveCardDragView).map { [$0] } ?? view.subviews.flatMap { cardBridges(in: $0) }
}
guard let renderedCard = cardBridges(in: host).first else { fatalError("Missing rendered card drag surface") }
precondition(renderedCard.bounds.height >= 90, "Drag surface must include the lower action row")
for local in [NSPoint(x: 5, y: 10), NSPoint(x: 5, y: renderedCard.bounds.height - 10)] {
    let point = renderedCard.convert(local, to: host.superview)
    precondition(host.hitTest(point) === renderedCard, "Rendered card upper and lower blank areas must route to native dragging")
}
let buttonPoint = renderedCard.convert(NSPoint(x: renderedCard.bounds.width - 24, y: 21), to: host.superview)
precondition(host.hitTest(buttonPoint) !== renderedCard, "Card action buttons must remain clickable")
print("PASS: rendered full-card drag surface and button hit regions")
let frames = store.actionTileFrames
precondition(frames.count == ActionType.allCases.count, "Every action registers a drop target")
precondition(Set(frames.values.map { Int($0.midY.rounded()) }).count == 2, "Compact actions use two rows")
for (action, frame) in frames {
    precondition(frame.minX >= 0 && frame.maxX <= store.shelfWidth, "Action remains within narrow panel")
    precondition(DropProcessor.actionTarget(at: CGPoint(x: frame.midX, y: frame.midY), frames: frames) == action, "Both action rows route drops correctly")
}
precondition(DropProcessor.actionTarget(at: CGPoint(x: 100, y: 500), frames: frames) == nil, "Dropping below actions only stages the file")
print("PASS: compact action layout and drop routing")
try snapshot("refined-dark", light: false)
try snapshot("refined-empty", light: true, empty: true)
try snapshot("refined-many-history", light: true, many: true, history: true)
store.useRefinedClassic = false
try snapshot("original", light: false)
store.useRefinedClassic = true

let bridge = InteractiveCardDragView(frame: NSRect(x: 0, y: 0, width: 132, height: 158))
for point in [NSPoint(x: 2, y: 2), NSPoint(x: 120, y: 70), NSPoint(x: 2, y: 150), NSPoint(x: 120, y: 150)] {
    precondition(bridge.hitTest(point) != nil, "Card edges and lower space must accept dragging")
}
precondition(InteractiveCardDragView.shouldBeginDrag(from: .zero, to: NSPoint(x: 3, y: 0)))
precondition(!InteractiveCardDragView.shouldBeginDrag(from: .zero, to: NSPoint(x: 1, y: 1)))
let dragURLs = (0..<1000).map { URL(fileURLWithPath: "/tmp/drag-test-\($0)") }
let dragItems = ShelfDragPreview.makeItems(urls: dragURLs)
precondition(dragItems.count == dragURLs.count, "Large drags must preserve every file")

let before = store.items.map { $0.id }
store.setRefinedClassic(false)
precondition(store.items.map { $0.id } == before, "Changing layout must preserve staged items")
store.setRefinedClassic(true)
precondition(store.items.map { $0.id } == before, "Returning to Refined must preserve staged items")
print("PASS: drag hit regions and layout switching preserve behavior")

let retainedItems = store.items
store.items = []
controller.show(animated: false)
controller.hide(animated: true)
controller.show(animated: true)
let animationDeadline = Date().addingTimeInterval(3)
// Let the earlier hide completion run before accepting the resumed window.
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
while Date() < animationDeadline && (!controller.panel.isVisible || controller.panel.alphaValue <= 0.99) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
precondition(controller.panel.isVisible && controller.panel.alphaValue > 0.99,
             "A resumed shelf remains on screen after a previous hide animation finishes")
controller.hide(animated: false)
store.items = retainedItems
print("PASS: native shelf animation resumes without stale dismissal")

QuickLookController.shared.show(inputs[0])
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
let preview = app.windows.first { $0.title == inputs[0].lastPathComponent } as! NSPanel
precondition(preview.isVisible && preview.canBecomeKey, "Quick Look must open a focusable preview")
precondition(!preview.hidesOnDeactivate, "Quick Look must remain visible when another app gains focus")
precondition(preview.collectionBehavior.contains(.canJoinAllSpaces), "Preview must follow the shelf across Spaces")
preview.close()
QuickLookController.shared.show(inputs[1])
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
let reopened = app.windows.first { $0.title == inputs[1].lastPathComponent }!
precondition(reopened.isVisible, "Quick Look must reopen after closing a previous preview")
reopened.close()
print("PASS: Quick Look presentation, focus policy, and reopening")

// Use a private test pasteboard, never the user's clipboard, for these fixtures.
let clipboardBoard = NSPasteboard.withUniqueName()
let clipboardSuite = "com.dropshelf.clipboard.visual.\(UUID().uuidString)"
let clipboardDefaults = UserDefaults(suiteName: clipboardSuite)!
let testClipboard = ClipboardStore(pasteboard: clipboardBoard, defaults: clipboardDefaults)
defer {
    testClipboard.stop()
    clipboardBoard.releaseGlobally()
    clipboardDefaults.removePersistentDomain(forName: clipboardSuite)
    store.section = .files
}
let clipboardPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 210, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
let clipboardHost = NSHostingView(rootView: DropShelfView(clipboard: testClipboard))
clipboardPanel.contentView = clipboardHost
store.section = .clipboard
func clipboardSnapshot(_ name: String, light: Bool) throws {
    store.appearanceTheme = light ? .light : .dark
    clipboardPanel.setContentSize(NSSize(width: 210, height: 520))
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    clipboardHost.layoutSubtreeIfNeeded()
    let rep = clipboardHost.bitmapImageRepForCachingDisplay(in: clipboardHost.bounds)!
    clipboardHost.cacheDisplay(in: clipboardHost.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    print("Rendered \(name): \(clipboardHost.bounds.size)")
}
try clipboardSnapshot("clipboard-opt-in", light: true)
testClipboard.setEnabled(true)
try clipboardSnapshot("clipboard-empty", light: true)
for content in ["  Long passages stay exactly as copied.\r\n\tSpaces, tabs and line breaks stay intact.  ", "https://EXAMPLE.com/a%2Fb?q=hello+world#Section", "e\u{301} · 日本語 · 👩🏽‍💻"] {
    clipboardBoard.clearContents()
    clipboardBoard.setData(Data(content.utf8), forType: .string)
    testClipboard.poll()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
}
precondition(testClipboard.entries.count == 3, "Clipboard fixtures captured")
testClipboard.togglePin(testClipboard.entries[0].id)
try clipboardSnapshot("clipboard-light", light: true)
try clipboardSnapshot("clipboard-dark", light: false)
let longText = "  \t" + String(repeating: "Long passage word ", count: 10_000) + "\r\n  End\t "
clipboardBoard.clearContents()
clipboardBoard.setData(Data(longText.utf8), forType: .string)
testClipboard.poll()
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
ClipboardDetailWindowController.shared.show(testClipboard.entries[0].id, store: testClipboard)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
let detail = app.windows.first { $0.title == "Clipboard Text" && $0.isVisible }!
precondition(detail.isVisible, "Full-text detail opens")
func textViews(in view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
}
let detailText = textViews(in: detail.contentView!).first!
precondition(Data(detailText.string.utf8) == Data(longText.utf8), "Full-text viewer retains the entire 30,000-word passage")
precondition(!detailText.isEditable && !detailText.isAutomaticLinkDetectionEnabled, "Detail is read-only plain text")
let detailRep = detail.contentView!.bitmapImageRepForCachingDisplay(in: detail.contentView!.bounds)!
detail.contentView!.cacheDisplay(in: detail.contentView!.bounds, to: detailRep)
try detailRep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("clipboard-detail.png"))
testClipboard.clear()
precondition(!detail.isVisible, "Clearing history closes full-text detail")
precondition(detailText.string.isEmpty, "Clearing history empties the native text view")
print("PASS: clipboard detail does not retain cleared entries")

let settingsPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
let settingsHost = NSHostingView(rootView: ClipboardSettingsSection(clipboard: testClipboard).padding(18).frame(width: 360).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light))
settingsPanel.contentView = settingsHost
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
settingsHost.layoutSubtreeIfNeeded()
let settingsRep = settingsHost.bitmapImageRepForCachingDisplay(in: settingsHost.bounds)!
settingsHost.cacheDisplay(in: settingsHost.bounds, to: settingsRep)
try settingsRep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("clipboard-settings.png"))
print("PASS: clipboard settings rendered")

// Render optional-model controls without touching the user's installed model.
let absentModelRoot = FileManager.default.temporaryDirectory.appendingPathComponent("dropshelf-model-ui-\(UUID().uuidString)")
let absentModel = BackgroundModelStore(modelRoot: absentModelRoot)
for light in [true, false] {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
    let modelHost = NSHostingView(rootView: BackgroundModelStatusView(store: absentModel, allowsRemoval: true)
        .padding(18).frame(width: 360, height: 220, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(light ? .light : .dark))
    panel.contentView = modelHost
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    modelHost.layoutSubtreeIfNeeded()
    let rep = modelHost.bitmapImageRepForCachingDisplay(in: modelHost.bounds)!
    modelHost.cacheDisplay(in: modelHost.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("model-download-\(light ? "light" : "dark").png"))
}
precondition(!FileManager.default.fileExists(atPath: absentModelRoot.path), "Showing model controls must not install or create storage")
print("PASS: optional-model controls render without installing anything")

// Render both media tool panes at their actual window dimensions.
for kind in MediaToolKind.allCases {
    let mediaModel = MediaToolsModel()
    mediaModel.kind = kind
    mediaModel.urls = [inputs[0]]
    let mediaPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 710), styleMask: [.borderless], backing: .buffered, defer: false)
    let mediaHost = NSHostingView(rootView: MediaToolsView(model: mediaModel).preferredColorScheme(.light))
    mediaPanel.contentView = mediaHost
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    mediaHost.layoutSubtreeIfNeeded()
    let rep = mediaHost.bitmapImageRepForCachingDisplay(in: mediaHost.bounds)!
    mediaHost.cacheDisplay(in: mediaHost.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("tools-" + kind.rawValue.lowercased() + ".png"))
}
precondition(try! MediaToolsView.parsePages("3, 1, 5-8") == [3, 1, 5, 6, 7, 8])
for value in ["", "1,", "0", "-1", "4-2", "1-999999999999", "x"] {
    do { _ = try MediaToolsView.parsePages(value); fatalError("Invalid page order accepted") } catch { }
}
print("PASS: media windows render and page selection parser rejects invalid input")

let progressGate = DispatchSemaphore(value: 0)
OperationCoordinator.shared.start(title: "Converting images", inputs: []) { context in
    context.progress(0.4, "Image 2 of 5")
    progressGate.wait()
    try context.checkCancellation()
    return OperationResult(message: "Done")
}
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
store.section = .files
try snapshot("refined-progress", light: true)
OperationCoordinator.shared.cancel()
progressGate.signal()
while OperationCoordinator.shared.isRunning { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
print("PASS: compact operation progress rendered and cancellation completed")
