import Cocoa
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

private func digest(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func makePDF(_ url: URL) {
    var box = CGRect(x: 0, y: 0, width: 100, height: 100)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil); context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 20, y: 20, width: 60, height: 60)); context.endPDFPage(); context.closePDF()
}

private func makeP3SixteenBit(_ url: URL) throws {
    let width = 96, height = 64
    var values = [UInt16](repeating: UInt16.max, count: width * height * 4)
    for y in 10..<54 { for x in 22..<74 {
        let i = (y * width + x) * 4
        values[i] = UInt16.max; values[i + 1] = 5_000; values[i + 2] = 12_000; values[i + 3] = UInt16.max
    }}
    let data = values.withUnsafeBytes { Data($0) }
    let provider = CGDataProvider(data: data as CFData)!
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let info = CGBitmapInfo.byteOrder16Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                        space: p3, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil); expect(CGImageDestinationFinalize(destination), "write P3 16-bit fixture")
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dropshelf-bg-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temporary) }

expect(BackgroundRemovalEngine.quality.title.contains("BiRefNet"), "quality engine is explicit")
expect(BackgroundRemovalEngine.native.title.contains("Apple Vision"), "native engine is explicit")
expect(BackgroundRemovalEngine.quality.explanation.contains("never uploaded"), "quality privacy copy")

let pdf = temporary.appendingPathComponent("single-page.pdf")
makePDF(pdf)
do {
    _ = try BackgroundRemovalService.remove(urls: [pdf], engine: .native, outputDirectory: temporary, context: OperationContext())
    expect(false, "one-page PDF must not be rasterized as an image")
} catch let error as BackgroundRemovalError {
    if case .unreadableImage = error {} else { expect(false, "PDF rejected with explicit image error") }
}

let cancelledDirectory = temporary.appendingPathComponent("cancelled")
try FileManager.default.createDirectory(at: cancelledDirectory, withIntermediateDirectories: false)
let cancelled = OperationContext(); cancelled.cancel()
do {
    _ = try BackgroundRemovalService.remove(urls: [root.appendingPathComponent("Resources/icon.png")], engine: .native,
                                                 outputDirectory: cancelledDirectory, context: cancelled)
    expect(false, "cancelled operation must throw")
} catch is CancellationError {}
let cancelledContents = try FileManager.default.contentsOfDirectory(atPath: cancelledDirectory.path)
expect(cancelledContents.isEmpty, "cancellation leaves no output")

let missingModelRoot = temporary.appendingPathComponent("missing-model", isDirectory: true)
let missingStore = BackgroundModelStore(modelRoot: missingModelRoot)
do {
    _ = try BackgroundRemovalService.remove(urls: [root.appendingPathComponent("Resources/icon.png")], engine: .quality,
                                             outputDirectory: temporary, context: OperationContext(), modelStore: missingStore)
    expect(false, "quality processing must reject an uninstalled model")
} catch BackgroundModelStoreError.notInstalled {}
expect(!FileManager.default.fileExists(atPath: missingModelRoot.path), "missing-model processing creates no model storage")

let corruptModelRoot = temporary.appendingPathComponent("corrupt-model", isDirectory: true)
let corruptPackage = corruptModelRoot.appendingPathComponent("BiRefNet-1024-FP16.mlpackage", isDirectory: true)
try FileManager.default.createDirectory(at: corruptPackage, withIntermediateDirectories: true)
let corruptManifest = corruptPackage.appendingPathComponent("Manifest.json")
try Data("damaged".utf8).write(to: corruptManifest)
let corruptHash = try digest(corruptManifest)
let corruptStore = BackgroundModelStore(modelRoot: corruptModelRoot)
do {
    _ = try BackgroundRemovalService.remove(urls: [root.appendingPathComponent("Resources/icon.png")], engine: .quality,
                                             outputDirectory: temporary, context: OperationContext(), modelStore: corruptStore)
    expect(false, "quality processing must reject a corrupt model")
} catch BackgroundModelStoreError.integrityFailed {}
let corruptHashAfter = try digest(corruptManifest)
expect(corruptHashAfter == corruptHash, "processing does not mutate a corrupt installation")
expect(!FileManager.default.fileExists(atPath: corruptStore.compiledModelURL.path), "processing does not compile a corrupt installation")

let cancelledInstallRoot = temporary.appendingPathComponent("cancelled-install", isDirectory: true)
let cancelledInstallStore = BackgroundModelStore(modelRoot: cancelledInstallRoot)
let cancelledInstall = OperationContext(); cancelledInstall.cancel()
do {
    _ = try cancelledInstallStore.installModel(context: cancelledInstall)
    expect(false, "cancelled explicit install must throw")
} catch is CancellationError {}
expect(!FileManager.default.fileExists(atPath: cancelledInstallRoot.path), "cancelled install creates no storage before network")

let removableRoot = temporary.appendingPathComponent("removable-model", isDirectory: true)
let removableStore = BackgroundModelStore(modelRoot: removableRoot)
try FileManager.default.createDirectory(at: removableStore.packageURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: removableStore.compiledModelURL, withIntermediateDirectories: true)
let removableMarker = removableRoot.appendingPathComponent("BiRefNet-1024-FP16.compiled-source")
try Data("old marker".utf8).write(to: removableMarker)
let unrelated = removableRoot.appendingPathComponent("keep-me.txt")
try Data("unrelated".utf8).write(to: unrelated)
let abandoned = removableRoot.appendingPathComponent(".download-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
try Data("partial model".utf8).write(to: abandoned.appendingPathComponent("weight.bin"))
let lookalike = removableRoot.appendingPathComponent(".download-user-notes")
try Data("unrelated".utf8).write(to: lookalike)
let outside = temporary.appendingPathComponent("keep-outside-model-storage")
try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
try Data("unrelated".utf8).write(to: outside.appendingPathComponent("sentinel"))
let abandonedLink = removableRoot.appendingPathComponent(".download-\(UUID().uuidString)")
try FileManager.default.createSymbolicLink(at: abandonedLink, withDestinationURL: outside)
try removableStore.removeInstalledModel(context: OperationContext())
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
expect(!FileManager.default.fileExists(atPath: removableStore.packageURL.path), "remove deletes the managed package")
expect(!FileManager.default.fileExists(atPath: removableStore.compiledModelURL.path), "remove deletes the managed compiled model")
expect(!FileManager.default.fileExists(atPath: removableMarker.path), "remove deletes the managed marker")
expect(FileManager.default.fileExists(atPath: unrelated.path), "remove preserves unrelated files")
expect(!FileManager.default.fileExists(atPath: abandoned.path), "remove clears abandoned download stages")
expect(FileManager.default.fileExists(atPath: lookalike.path), "remove preserves names outside the reserved UUID stage pattern")
expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("sentinel").path), "cleanup does not follow staged symlinks")
expect(!FileManager.default.fileExists(atPath: abandonedLink.path), "cleanup removes the staged symlink itself")
expect(removableStore.status == .notInstalled, "remove reports not installed")

let cancelledRemovalRoot = temporary.appendingPathComponent("cancelled-removal", isDirectory: true)
let cancelledRemovalStore = BackgroundModelStore(modelRoot: cancelledRemovalRoot)
try FileManager.default.createDirectory(at: cancelledRemovalStore.packageURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: cancelledRemovalStore.compiledModelURL, withIntermediateDirectories: true)
let cancelledRemoval = OperationContext(); cancelledRemoval.cancel()
do {
    try cancelledRemovalStore.removeInstalledModel(context: cancelledRemoval)
    expect(false, "cancelled removal must throw")
} catch is CancellationError {}
expect(FileManager.default.fileExists(atPath: cancelledRemovalStore.packageURL.path), "cancelled removal preserves package")
expect(FileManager.default.fileExists(atPath: cancelledRemovalStore.compiledModelURL.path), "cancelled removal preserves compiled model")

let failedLoadRoot = temporary.appendingPathComponent("failed-load", isDirectory: true)
let failedLoadStore = BackgroundModelStore(modelRoot: failedLoadRoot)
failedLoadStore.reportCompiledModelLoadFailure()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
expect(failedLoadStore.status == .needsPreparation, "compiled-model load failure requests explicit preparation")
expect(!FileManager.default.fileExists(atPath: failedLoadRoot.path), "reporting a load failure creates no storage")

guard CommandLine.arguments.contains("--model") else {
    print("Background removal offline checks passed (model smoke skipped)")
    exit(0)
}

_ = try BackgroundModelStore.shared.installedModel(context: OperationContext())
let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let marker = support.appendingPathComponent("DropShelf/Models/BiRefNet-1024-FP16.compiled-source")
let markerText = try String(contentsOf: marker, encoding: .utf8)
expect(markerText.contains(BackgroundModelStore.modelRevision), "compiled cache is bound to artifact revision")
expect(markerText.contains(BackgroundModelStore.upstreamRevision), "compiled cache is bound to upstream revision")

if CommandLine.arguments.contains("--repair") {
    let repairRoot = temporary.appendingPathComponent("repair-model", isDirectory: true)
    let repairStore = BackgroundModelStore(modelRoot: repairRoot)
    try FileManager.default.createDirectory(at: repairRoot, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: BackgroundModelStore.shared.packageURL, to: repairStore.packageURL)
    try FileManager.default.copyItem(at: marker, to: repairRoot.appendingPathComponent("BiRefNet-1024-FP16.compiled-source"))
    try FileManager.default.createDirectory(at: repairStore.compiledModelURL, withIntermediateDirectories: true)
    let repairManifest = repairStore.packageURL.appendingPathComponent("Manifest.json")
    let repairManifestHash = try digest(repairManifest)
    let repairOutput = temporary.appendingPathComponent("repair-output", isDirectory: true)
    try FileManager.default.createDirectory(at: repairOutput, withIntermediateDirectories: true)
    do {
        _ = try BackgroundRemovalService.remove(urls: [root.appendingPathComponent("Resources/icon.png")], engine: .quality,
                                                 outputDirectory: repairOutput, context: OperationContext(), modelStore: repairStore)
        expect(false, "corrupt compiled cache must not process an image")
    } catch BackgroundModelStoreError.needsPreparation {}
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    expect(repairStore.status == .needsPreparation, "corrupt compiled cache requests explicit repair")
    let compiledContents = try FileManager.default.contentsOfDirectory(atPath: repairStore.compiledModelURL.path)
    expect(compiledContents.isEmpty, "processing does not mutate corrupt compiled cache")
    let afterProcessingHash = try digest(repairManifest)
    expect(afterProcessingHash == repairManifestHash, "processing does not mutate verified source package")
    repairStore.refreshStatus()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    expect(repairStore.status == .needsPreparation, "refresh retains the preparation request")
    _ = try repairStore.installModel(context: OperationContext())
    _ = try repairStore.installedModel(context: OperationContext())
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    expect(repairStore.status == .ready, "explicit installation repairs and becomes ready")
    let afterRepairHash = try digest(repairManifest)
    expect(afterRepairHash == repairManifestHash, "explicit repair reuses verified package without redownload")
    print("PASS: damaged compiled cache requires explicit local repair")
}

let icon = root.appendingPathComponent("Resources/icon.png")
let iconHash = try digest(icon)
let qualityDirectory = temporary.appendingPathComponent("quality")
try FileManager.default.createDirectory(at: qualityDirectory, withIntermediateDirectories: false)
let iconOutputs = try BackgroundRemovalService.remove(urls: [icon], engine: .quality, outputDirectory: qualityDirectory, context: OperationContext())
expect(iconOutputs.count == 1, "quality creates one output")
let iconHashAfter = try digest(icon)
expect(iconHashAfter == iconHash, "quality never changes original")
let iconSource = CGImageSourceCreateWithURL(iconOutputs[0] as CFURL, nil)!
let iconResult = CGImageSourceCreateImageAtIndex(iconSource, 0, nil)!
expect(iconResult.width == 1024 && iconResult.height == 1024, "quality retains original dimensions")
expect([.premultipliedFirst, .premultipliedLast, .first, .last].contains(iconResult.alphaInfo), "quality output has alpha")

let p3 = temporary.appendingPathComponent("p3-16.png")
try makeP3SixteenBit(p3)
let p3Hash = try digest(p3)
let p3Outputs = try BackgroundRemovalService.remove(urls: [p3], engine: .quality, outputDirectory: qualityDirectory, context: OperationContext())
let p3HashAfter = try digest(p3)
expect(p3HashAfter == p3Hash, "16-bit P3 original unchanged")
let p3Source = CGImageSourceCreateWithURL(p3Outputs[0] as CFURL, nil)!
let p3Result = CGImageSourceCreateImageAtIndex(p3Source, 0, nil)!
expect(p3Result.width == 96 && p3Result.height == 64, "16-bit P3 dimensions retained")
expect(p3Result.bitsPerComponent == 16, "16-bit depth retained")
expect(p3Result.colorSpace?.name == CGColorSpace.displayP3, "Display P3 profile retained")

if let previewFlag = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > previewFlag + 2 {
    let input = URL(fileURLWithPath: CommandLine.arguments[previewFlag + 1])
    let directory = URL(fileURLWithPath: CommandLine.arguments[previewFlag + 2])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let preview = try BackgroundRemovalService.remove(urls: [input], engine: .quality, outputDirectory: directory, context: OperationContext())
    print("preview=\(preview[0].path)")
}

if let previewFlag = CommandLine.arguments.firstIndex(of: "--native-preview"), CommandLine.arguments.count > previewFlag + 2 {
    let input = URL(fileURLWithPath: CommandLine.arguments[previewFlag + 1])
    let directory = URL(fileURLWithPath: CommandLine.arguments[previewFlag + 2])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let preview = try BackgroundRemovalService.remove(urls: [input], engine: .native, outputDirectory: directory, context: OperationContext())
    print("native_preview=\(preview[0].path)")
}

print("Background removal model checks passed")
