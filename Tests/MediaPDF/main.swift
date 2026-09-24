import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit

func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
    print("PASS: \(label)")
}

func makePDF(_ url: URL, labels: [String]) {
    var box = CGRect(x: 0, y: 0, width: 300, height: 200)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    for label in labels {
        context.beginPDFPage(nil)
        let attributes = [kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 24, nil)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, label as CFString, attributes))
        context.textPosition = CGPoint(x: 30, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
}

func sha256(_ url: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", url.path]
    let output = Pipe()
    process.standardOutput = output
    try! process.run()
    process.waitUntilExit()
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ")[0].description
}

func makeOrientedJPEG(_ url: URL) {
    let color = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.red.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
}

func makeAnimatedGIF(_ url: URL) {
    let color = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 2, nil)!
    context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("dropshelf-pdf-tests-\(UUID().uuidString)", isDirectory: true)
let output = root.appendingPathComponent("private", isDirectory: true)
try fm.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(at: root) }

let first = root.appendingPathComponent("first.pdf")
let second = root.appendingPathComponent("second.pdf")
makePDF(first, labels: ["ALPHA", "BRAVO"])
makePDF(second, labels: ["CHARLIE"])
let firstHash = sha256(first)
let service = PDFProcessingService()

let merged = try service.mergePDFs(inputURLs: [first, second], outputDirectory: output)
let mergedDocument = PDFDocument(url: merged)!
check(mergedDocument.pageCount == 3, "merge keeps every page")
check(mergedDocument.page(at: 0)!.string!.contains("ALPHA") && mergedDocument.page(at: 2)!.string!.contains("CHARLIE"), "merge preserves page order and searchable text")
check(sha256(first) == firstHash, "merge does not modify its input")
let collision = try service.mergePDFs(inputURLs: [first], outputDirectory: output)
check(collision.lastPathComponent == "Merged 2.pdf", "output names are collision safe")

let reordered = try service.extractOrReorderPages(sourceURL: first, pageNumbers: [2, 1, 2], outputDirectory: output)
let reorderedDocument = PDFDocument(url: reordered)!
check(reorderedDocument.pageCount == 3, "ordered selection permits extraction and duplication")
check(reorderedDocument.page(at: 0)!.string!.contains("BRAVO") && reorderedDocument.page(at: 1)!.string!.contains("ALPHA"), "ordered selection preserves requested order and text")

do {
    _ = try service.extractOrReorderPages(sourceURL: first, pageNumbers: [0], outputDirectory: output)
    fatalError("Invalid page index was accepted")
} catch PDFProcessingError.invalidPageNumber(0, available: 2) {
    print("PASS: invalid 1-based page index is rejected")
}

let corrupt = root.appendingPathComponent("corrupt.pdf")
try Data("not a pdf".utf8).write(to: corrupt)
do {
    _ = try service.mergePDFs(inputURLs: [corrupt], outputDirectory: output)
    fatalError("Corrupt PDF was accepted")
} catch PDFProcessingError.unreadablePDF {
    print("PASS: corrupt PDF is rejected")
}

let readOnlyOutput = root.appendingPathComponent("read-only", isDirectory: true)
try fm.createDirectory(at: readOnlyOutput, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o500])
defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyOutput.path) }
do {
    _ = try service.mergePDFs(inputURLs: [first], outputDirectory: readOnlyOutput)
    fatalError("Read-only output folder was accepted")
} catch PDFProcessingError.invalidOutputDirectory {
    print("PASS: read-only output folder is rejected")
}

let encrypted = root.appendingPathComponent("encrypted.pdf")
let encryptSource = PDFDocument(url: first)!
let encryptedOK = encryptSource.write(to: encrypted, withOptions: [
    PDFDocumentWriteOption.userPasswordOption: "secret",
    PDFDocumentWriteOption.ownerPasswordOption: "owner"
])
check(encryptedOK, "encrypted fixture was created")
do {
    _ = try service.mergePDFs(inputURLs: [encrypted], outputDirectory: output)
    fatalError("Encrypted PDF was accepted")
} catch PDFProcessingError.encryptedPDF {
    print("PASS: encrypted PDF is rejected")
}

let cancelOutput = root.appendingPathComponent("cancel", isDirectory: true)
try fm.createDirectory(at: cancelOutput, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
var checks = 0
do {
    _ = try service.mergePDFs(inputURLs: [first, second], outputDirectory: cancelOutput, checkCancellation: {
        checks += 1
        if checks >= 4 { throw CancellationError() }
    })
    fatalError("Cancellation was ignored")
} catch is CancellationError {
    let leftovers = try fm.contentsOfDirectory(atPath: cancelOutput.path)
    check(leftovers.isEmpty, "cancellation removes incomplete output")
}

let image = root.appendingPathComponent("oriented.jpg")
makeOrientedJPEG(image)
let imagePDF = try service.imagesToPDF(imageURLs: [image], outputDirectory: output)
let imageDocument = PDFDocument(url: imagePDF)!
let imageBounds = imageDocument.page(at: 0)!.bounds(for: .mediaBox)
check(imageDocument.pageCount == 1, "image conversion creates one page per image")
check(imageBounds.height > imageBounds.width, "EXIF orientation is applied to PDF page geometry")

let animated = root.appendingPathComponent("animated.gif")
makeAnimatedGIF(animated)
let multiFrameOutput = root.appendingPathComponent("multi-frame", isDirectory: true)
try fm.createDirectory(at: multiFrameOutput, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
do {
    _ = try service.imagesToPDF(imageURLs: [image, animated], outputDirectory: multiFrameOutput)
    fatalError("Animated image was silently reduced to its first frame")
} catch PDFProcessingError.multiFrameImage("animated.gif", frames: 2) {
    let leftovers = try fm.contentsOfDirectory(atPath: multiFrameOutput.path)
    check(leftovers.isEmpty, "multi-frame input is refused and partial PDF is removed")
}
do {
    _ = try service.imagesToPDF(imageURLs: [first], outputDirectory: multiFrameOutput)
    fatalError("A PDF was accepted as an image and rasterized")
} catch PDFProcessingError.unreadableImage("first.pdf") {
    let leftovers = try fm.contentsOfDirectory(atPath: multiFrameOutput.path)
    check(leftovers.isEmpty, "non-image input is not silently rasterized")
}

let outputPermissions = (try fm.attributesOfItem(atPath: merged.path)[.posixPermissions] as! NSNumber).intValue
check(outputPermissions & 0o077 == 0, "generated PDF is owner-only")
print("PASS: PDF processing suite complete")
