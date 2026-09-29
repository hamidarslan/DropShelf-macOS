import AppKit
import Foundation
import ImageIO
import PDFKit

func check(_ condition: @autoclosure () throws -> Bool, _ label: String) {
    do {
        let passed = try condition()
        precondition(passed, label)
    } catch { fatalError("\(label): \(error)") }
    print("PASS: \(label)")
}

let fm = FileManager.default
let repository = URL(fileURLWithPath: CommandLine.arguments[1])
let tools = repository.appendingPathComponent("DropShelf.app/Contents/Resources/CompressionTools")
let service = LosslessCompressionService(toolsDirectory: tools)
let root = fm.temporaryDirectory.appendingPathComponent("dropshelf-compression-\(UUID().uuidString)")
let output = root.appendingPathComponent("outputs")
try fm.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(at: root) }

func makePDF(_ url: URL, title: String = "Preserved title") throws {
    let content = String(repeating: "0 0 m 10 10 l S\n", count: 8_000)
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << >> /Contents 4 0 R >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
        "<< /Title (\(title)) /Author (Fixture author) >>"
    ]
    var data = Data("%PDF-1.4\n".utf8)
    var offsets = [0]
    for (index, value) in objects.enumerated() {
        offsets.append(data.count)
        data.append(Data("\(index + 1) 0 obj\n\(value)\nendobj\n".utf8))
    }
    let xref = data.count
    data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
    for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
    data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 5 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
    try data.write(to: url)
}

func digest(_ url: URL) throws -> String { try CompressionToolRunner.hash(url, checkCancellation: {}) }
let pdf = root.appendingPathComponent("source.pdf")
try makePDF(pdf)
let originalHash = try digest(pdf)
check(LosslessCompressionService.detectKind(at: pdf) == .pdf, "PDF eligibility uses file content")
let mislabeled = root.appendingPathComponent("misnamed.bin")
try fm.copyItem(at: pdf, to: mislabeled)
check(LosslessCompressionService.detectKind(at: mislabeled) == .pdf, "PDF detection does not require a PDF extension")
let text = root.appendingPathComponent("not-a-document.pdf")
try Data("ordinary text".utf8).write(to: text)
check(LosslessCompressionService.detectKind(at: text) == nil, "unsupported content is not enabled by its extension")

do {
    _ = try service.compressFiles(urls: [], options: .init(), outputDirectory: output)
    fatalError("Empty compression input accepted")
} catch LosslessCompressionError.noInput { print("PASS: empty input is rejected") }
var invalid = LosslessCompressionOptions()
invalid.preset = .custom
invalid.pdfCompressionLevel = 10
do {
    _ = try service.compressFiles(urls: [pdf], options: invalid, outputDirectory: output)
    fatalError("Invalid compression options accepted")
} catch LosslessCompressionError.invalidOptions { print("PASS: invalid custom options are rejected") }

for preset in [CompressionPreset.low, .medium, .strong, .custom] {
    var options = LosslessCompressionOptions()
    options.preset = preset
    options.timeoutSeconds = 60
    let result = try service.compressFiles(urls: [pdf], options: options, outputDirectory: output)
    check(result.files.count == 1 && result.files[0].disposition == .compressed, "\(preset.title) compresses a reducible PDF: \(result.files.first?.detail ?? "missing result")")
    let file = result.files[0]
    check(file.resultBytes! < file.originalBytes, "\(preset.title) publishes only a smaller file")
    let document = PDFDocument(url: file.outputURL!)!
    check(document.pageCount == 1 && document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Preserved title", "\(preset.title) preserves PDF pages and metadata")
    check(try digest(pdf) == originalHash, "\(preset.title) leaves original PDF bytes unchanged")
}

let batch = try service.compressFiles(urls: [pdf, text, mislabeled], options: .init(), outputDirectory: output)
check(batch.files.map(\.disposition) == [.compressed, .rejected, .compressed], "mixed batch preserves order and reports rejected files")
check(batch.succeeded && batch.generatedURLs.count == 2, "partial batches retain validated outputs")
check(Set(batch.generatedURLs).count == 2, "batch output names remain unique")
let optimized = batch.generatedURLs[0]
let optimizedHash = try digest(optimized)
let unchanged = try service.compressFiles(urls: [optimized], options: .init(), outputDirectory: output)
check(unchanged.files[0].disposition == .unchanged && unchanged.generatedURLs.isEmpty, "already optimized files create no redundant output")
check(try digest(optimized) == optimizedHash, "unchanged results leave source bytes intact")
var pdfOnlyOptions = LosslessCompressionOptions()
pdfOnlyOptions.preset = .custom
pdfOnlyOptions.jpegTrySequential = false
pdfOnlyOptions.jpegTryProgressive = false
let pdfOnly = try service.compressFiles(urls: [pdf], options: pdfOnlyOptions, outputDirectory: output)
check(pdfOnly.files[0].disposition == .compressed, "JPEG-only options cannot disable PDF compression")
for url in batch.generatedURLs {
    let permissions = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    check(permissions & 0o077 == 0, "compressed outputs are owner-only")
}

let cancelOutput = root.appendingPathComponent("cancel")
try fm.createDirectory(at: cancelOutput, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
var cancelled = false
do {
    _ = try service.compressFiles(urls: [pdf, mislabeled], options: .init(), outputDirectory: cancelOutput,
                                 checkCancellation: { if cancelled { throw CancellationError() } },
                                 progress: { fraction, _ in if fraction >= 0.5 { cancelled = true } })
    fatalError("Compression cancellation was ignored")
} catch is CancellationError {
    check(try fm.contentsOfDirectory(atPath: cancelOutput.path).isEmpty, "cancellation removes completed and partial unpublished outputs")
}

let png = root.appendingPathComponent("image.png")
try fm.copyItem(at: repository.appendingPathComponent("Resources/icon.png"), to: png)
let pngHash = try digest(png)
let pngBatch = try service.compressFiles(urls: [png], options: .init(), outputDirectory: output)
check(pngBatch.files[0].disposition != .rejected, "strict PNG optimization is available")
check(try digest(png) == pngHash, "PNG source remains byte-identical")
if let compressed = pngBatch.generatedURLs.first {
    let imageSource = CGImageSourceCreateWithURL(compressed as CFURL, nil)!
    check(CGImageSourceGetCount(imageSource) == 1, "compressed PNG remains readable")
}

let jpeg = root.appendingPathComponent("photo.jpg")
let imageSource = CGImageSourceCreateWithURL(png as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
check(CGImageDestinationFinalize(destination), "JPEG test fixture is created")
let jpegHash = try digest(jpeg)
let jpegBatch = try service.compressFiles(urls: [jpeg], options: .init(), outputDirectory: output)
check(jpegBatch.files[0].disposition != .rejected, "strict JPEG optimization is available")
check(try digest(jpeg) == jpegHash, "JPEG source remains byte-identical")

let absentTools = LosslessCompressionService(toolsDirectory: root.appendingPathComponent("missing-tools"))
let unavailable = try absentTools.compressFiles(urls: [pdf], options: .init(), outputDirectory: output)
check(unavailable.files[0].disposition == .rejected && unavailable.generatedURLs.isEmpty, "missing bundled helpers never fall back to an untrusted executable")

// A wrapper performs the real comparison, then simulates another writer restoring A after B.
let raceTools = root.appendingPathComponent("race-tools")
try fm.copyItem(at: tools, to: raceTools)
let wrappedVerifier = raceTools.appendingPathComponent("bin/pdf-verify")
let realVerifier = raceTools.appendingPathComponent("bin/pdf-verify-real")
try fm.moveItem(at: wrappedVerifier, to: realVerifier)
let savedOriginal = root.appendingPathComponent("saved-original.pdf")
try fm.copyItem(at: pdf, to: savedOriginal)
let raceState = ["real": realVerifier.path, "restore": savedOriginal.path, "live": pdf.path]
try JSONSerialization.data(withJSONObject: raceState).write(to: raceTools.appendingPathComponent("bin/race-state.json"))
let wrapper = """
#!/usr/bin/python3
import json, os, shutil, subprocess, sys
with open(os.path.join(os.path.dirname(__file__), 'race-state.json')) as handle:
    state = json.load(handle)
status = subprocess.run([state['real']] + sys.argv[1:]).returncode
if len(sys.argv) > 1 and sys.argv[1] == 'compare':
    shutil.copyfile(state['restore'], state['live'])
sys.exit(status)
"""
try Data(wrapper.utf8).write(to: wrappedVerifier)
try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrappedVerifier.path)
var raceManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: raceTools.appendingPathComponent("manifest.json"))) as! [String: Any]
var entries = raceManifest["tools"] as! [[String: Any]]
for index in entries.indices where entries[index]["name"] as? String == "pdf-verify" {
    entries[index]["sha256"] = try digest(wrappedVerifier)
}
raceManifest["tools"] = entries
try JSONSerialization.data(withJSONObject: raceManifest).write(to: raceTools.appendingPathComponent("manifest.json"))
let raceService = LosslessCompressionService(toolsDirectory: raceTools)
var replaced = false
let raceResult = try raceService.compressFiles(urls: [pdf], options: .init(), outputDirectory: output, progress: { _, detail in
    if !replaced && detail.hasPrefix("Optimizing") {
        try! makePDF(pdf, title: "Concurrent replacement")
        replaced = true
    }
})
check(raceResult.files[0].disposition == .compressed, "source replacement race still yields a verified snapshot result")
let raceDocument = PDFDocument(url: raceResult.generatedURLs[0])!
check(raceDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Preserved title", "A to B to A source replacement cannot publish B as A")
check(try digest(pdf) == originalHash, "source race fixture restores the original bytes")

var changed = false
let changedResult = try service.compressFiles(urls: [pdf], options: .init(), outputDirectory: output, progress: { _, detail in
    if !changed && detail.hasPrefix("Optimizing") { try! makePDF(pdf, title: "New user edit"); changed = true }
})
check(changedResult.generatedURLs.isEmpty && changedResult.files[0].disposition == .rejected, "source changes prevent publication of a stale result")
check(PDFDocument(url: pdf)!.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "New user edit", "compression never overwrites a concurrent source edit")
try Data(contentsOf: savedOriginal).write(to: pdf)

let runnerTools = root.appendingPathComponent("runner-tools")
try fm.createDirectory(at: runnerTools.appendingPathComponent("bin"), withIntermediateDirectories: true)
let testTool = runnerTools.appendingPathComponent("bin/qpdf")
func configureRunner(_ script: String) throws -> CompressionToolRunner {
    try Data(script.utf8).write(to: testTool)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: testTool.path)
    let manifest: [String: Any] = ["schemaVersion": 1, "tools": [["name": "qpdf", "path": "bin/qpdf", "sha256": try digest(testTool)]]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: runnerTools.appendingPathComponent("manifest.json"))
    return CompressionToolRunner(directory: runnerTools)
}
let noisyRunner = try configureRunner("#!/bin/sh\nexec /usr/bin/head -c 2200000 /dev/zero\n")
do {
    _ = try noisyRunner.run("qpdf", arguments: [], work: root, deadline: ProcessInfo.processInfo.systemUptime + 5, checkCancellation: {})
    fatalError("Oversized diagnostics were accepted")
} catch LosslessCompressionError.helperFailed(let reason) {
    check(reason.contains("diagnostics"), "fast-exiting helpers cannot bypass the diagnostic size limit")
}
let slowRunner = try configureRunner("#!/bin/sh\nexec /bin/sleep 2\n")
do {
    _ = try slowRunner.run("qpdf", arguments: [], work: root, deadline: ProcessInfo.processInfo.systemUptime + 0.1, checkCancellation: {})
    fatalError("Helper timeout was ignored")
} catch LosslessCompressionError.timedOut { print("PASS: helper time limits terminate the running process") }

check(try fm.contentsOfDirectory(atPath: output.path).allSatisfy { !$0.hasPrefix(".compression-") }, "temporary operation directories are removed")
print("PASS: lossless compression integration suite complete")
