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

struct TestRGB {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

let red = TestRGB(red: 235, green: 35, blue: 35)
let green = TestRGB(red: 35, green: 210, blue: 55)
let blue = TestRGB(red: 35, green: 70, blue: 235)
let yellow = TestRGB(red: 235, green: 215, blue: 35)

func makeRGBAImage(
    width: Int,
    height: Int,
    colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB(),
    pixel: (Int, Int) -> (TestRGB, UInt8)
) -> CGImage {
    var bytes = Data(count: width * height * 4)
    bytes.withUnsafeMutableBytes { rawBuffer in
        let buffer = rawBuffer.bindMemory(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let (color, alpha) = pixel(x, y)
                let offset = (y * width + x) * 4
                buffer[offset] = color.red
                buffer[offset + 1] = color.green
                buffer[offset + 2] = color.blue
                buffer[offset + 3] = alpha
            }
        }
    }
    let provider = CGDataProvider(data: bytes as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

func makeQuadrantJPEG(_ url: URL, orientation: Int, dpiX: Int = 72, dpiY: Int = 72) {
    let image = makeRGBAImage(width: 120, height: 80) { x, y in
        if y < 40 { return (x < 60 ? red : green, 255) }
        return (x < 60 ? blue : yellow, 255)
    }
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.95,
        kCGImagePropertyOrientation: orientation,
        kCGImagePropertyDPIWidth: dpiX,
        kCGImagePropertyDPIHeight: dpiY
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
}

func makeTexturedJPEG(_ url: URL) {
    var state: UInt32 = 0x6d2b79f5
    func randomByte() -> UInt8 {
        state = 1664525 &* state &+ 1013904223
        return UInt8(truncatingIfNeeded: state >> 16)
    }
    let image = makeRGBAImage(
        width: 1_600,
        height: 1_000,
        colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!
    ) { x, y in
        let texture = Int(randomByte())
        let wave = (x * 17 + y * 31) & 255
        return (TestRGB(
            red: UInt8((texture + wave) & 255),
            green: UInt8((texture * 3 + x / 3) & 255),
            blue: UInt8((texture * 5 + y / 2) & 255)
        ), 255)
    }
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [
        kCGImageDestinationLossyCompressionQuality: 0.78,
        kCGImagePropertyOrientation: 1,
        kCGImagePropertyDPIWidth: 144,
        kCGImagePropertyDPIHeight: 144,
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFArtist: "PRIVATE_ARTIST_SENTINEL",
            kCGImagePropertyTIFFDocumentName: "PRIVATE_DOCUMENT_SENTINEL"
        ],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 52.520008,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 13.404954,
            kCGImagePropertyGPSLongitudeRef: "E"
        ]
    ] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    injectPrivateJPEGSegments(into: url)
}

func injectPrivateJPEGSegments(into url: URL) {
    func segment(marker: UInt8, payload: Data) -> Data {
        precondition(payload.count <= Int(UInt16.max) - 2)
        let length = UInt16(payload.count + 2)
        var data = Data([0xff, marker, UInt8(length >> 8), UInt8(length & 0xff)])
        data.append(payload)
        return data
    }

    var jpeg = try! Data(contentsOf: url)
    precondition(jpeg.count > 2 && jpeg[0] == 0xff && jpeg[1] == 0xd8)
    let injected = [
        segment(marker: 0xe1, payload: Data("http://ns.adobe.com/xap/1.0/\0PRIVATE_XMP_SENTINEL".utf8)),
        segment(marker: 0xfe, payload: Data("PRIVATE_COM_SENTINEL".utf8)),
        segment(marker: 0xef, payload: Data("PRIVATE_APP15_SENTINEL".utf8))
    ].reduce(into: Data(), { $0.append($1) })
    jpeg.insert(contentsOf: injected, at: 2)
    try! jpeg.write(to: url, options: .atomic)
}

func jpegCompressedScan(_ data: Data) -> Data {
    precondition(data.count > 4 && data[0] == 0xff && data[1] == 0xd8, "JPEG fixture must start with SOI")
    var index = 2
    while index + 3 < data.count {
        precondition(data[index] == 0xff, "Malformed JPEG marker sequence")
        while index < data.count && data[index] == 0xff { index += 1 }
        let marker = data[index]
        index += 1
        if marker == 0xd9 { break }
        if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
        let length = Int(data[index]) << 8 | Int(data[index + 1])
        precondition(length >= 2 && index + length <= data.count, "Malformed JPEG segment length")
        if marker == 0xda {
            let scanStart = index + length
            precondition(data.count >= scanStart + 2 && data[data.count - 2] == 0xff && data[data.count - 1] == 0xd9, "JPEG fixture must end with EOI")
            return data.subdata(in: scanStart..<(data.count - 2))
        }
        index += length
    }
    preconditionFailure("JPEG fixture has no compressed scan")
}

func firstPageImageXObjectData(_ pdfURL: URL) -> Data? {
    guard let document = CGPDFDocument(pdfURL as CFURL),
          let page = document.page(at: 1),
          let pageDictionary = page.dictionary else { return nil }
    var resources: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources),
          let resources else { return nil }
    var objects: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects),
          let objects else { return nil }

    var result: Data?
    withUnsafeMutablePointer(to: &result) { pointer in
        CGPDFDictionaryApplyFunction(objects, { _, object, rawPointer in
            guard let rawPointer else { return }
            let resultPointer = rawPointer.assumingMemoryBound(to: Data?.self)
            guard resultPointer.pointee == nil else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
            var format = CGPDFDataFormat.raw
            guard let copied = CGPDFStreamCopyData(stream, &format) else { return }
            resultPointer.pointee = copied as Data
        }, pointer)
    }
    return result
}

func makeAlphaPNG(_ url: URL) {
    let image = makeRGBAImage(width: 40, height: 40) { _, _ in (red, 128) }
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyDPIWidth: 72,
        kCGImagePropertyDPIHeight: 72
    ] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
}

func renderedBitmap(_ page: PDFPage, width: Int = 120, height: Int = 120, background: TestRGB = TestRGB(red: 255, green: 255, blue: 255)) -> NSBitmapImageRep {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: CGFloat(background.red) / 255, green: CGFloat(background.green) / 255, blue: CGFloat(background.blue) / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let bounds = page.bounds(for: .mediaBox)
    context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
    page.draw(with: .mediaBox, to: context)
    return NSBitmapImageRep(cgImage: context.makeImage()!)
}

func nearestSwatch(_ color: NSColor) -> String {
    let rgb = color.usingColorSpace(.deviceRGB)!
    let candidates: [(String, TestRGB)] = [("R", red), ("G", green), ("B", blue), ("Y", yellow)]
    return candidates.min { lhs, rhs in
        func distance(_ candidate: TestRGB) -> CGFloat {
            let dr = rgb.redComponent - CGFloat(candidate.red) / 255
            let dg = rgb.greenComponent - CGFloat(candidate.green) / 255
            let db = rgb.blueComponent - CGFloat(candidate.blue) / 255
            return dr * dr + dg * dg + db * db
        }
        return distance(lhs.1) < distance(rhs.1)
    }!.0
}

func renderedCorners(_ page: PDFPage) -> [String] {
    let bitmap = renderedBitmap(page)
    let insetX = bitmap.pixelsWide / 4
    let insetY = bitmap.pixelsHigh / 4
    let points = [
        (insetX, insetY),
        (bitmap.pixelsWide - 1 - insetX, insetY),
        (insetX, bitmap.pixelsHigh - 1 - insetY),
        (bitmap.pixelsWide - 1 - insetX, bitmap.pixelsHigh - 1 - insetY)
    ]
    return points.map { nearestSwatch(bitmap.colorAt(x: $0.0, y: $0.1)!) }
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

let texturedJPEG = root.appendingPathComponent("textured.jpg")
makeTexturedJPEG(texturedJPEG)
let texturedHash = sha256(texturedJPEG)
let texturedSourceData = try Data(contentsOf: texturedJPEG)
let privateMetadataMarkers = [
    "PRIVATE_ARTIST_SENTINEL",
    "PRIVATE_DOCUMENT_SENTINEL",
    "PRIVATE_XMP_SENTINEL",
    "PRIVATE_COM_SENTINEL",
    "PRIVATE_APP15_SENTINEL"
]
for marker in privateMetadataMarkers {
    check(texturedSourceData.range(of: Data(marker.utf8)) != nil, "JPEG privacy fixture contains \(marker)")
}
let texturedSource = CGImageSourceCreateWithURL(texturedJPEG as CFURL, nil)!
let texturedProperties = CGImageSourceCopyPropertiesAtIndex(texturedSource, 0, nil) as! [CFString: Any]
check(texturedProperties[kCGImagePropertyProfileName] != nil, "JPEG fixture contains an ICC color profile")
check(texturedProperties[kCGImagePropertyGPSDictionary] != nil, "JPEG privacy fixture contains GPS metadata")
let originalCompressedScan = jpegCompressedScan(texturedSourceData)
check(originalCompressedScan.count > 1_000_000, "JPEG fixture has a substantial compressed image scan")
let compactPDF = try service.imagesToPDF(
    imageURLs: [texturedJPEG],
    outputDirectory: output,
    preferredFilename: "Compact.pdf"
)
let compactPDFData = try Data(contentsOf: compactPDF)
for marker in privateMetadataMarkers {
    check(compactPDFData.range(of: Data(marker.utf8)) == nil, "PDF excludes private JPEG metadata \(marker)")
}
check(compactPDFData.range(of: Data("/ICCBased".utf8)) != nil, "PDF preserves the JPEG ICC color profile")
let embeddedImageData = firstPageImageXObjectData(compactPDF)
check(embeddedImageData != nil, "PDF exposes its JPEG image XObject for metadata inspection")
let embeddedImageSource = CGImageSourceCreateWithData(embeddedImageData! as CFData, nil)
check(embeddedImageSource != nil, "PDF image XObject remains a readable JPEG")
let embeddedProperties = CGImageSourceCopyPropertiesAtIndex(embeddedImageSource!, 0, nil) as? [CFString: Any]
check(embeddedProperties != nil, "PDF image XObject exposes readable image properties")
let embeddedTIFF = embeddedProperties![kCGImagePropertyTIFFDictionary] as? [CFString: Any]
check(embeddedTIFF?[kCGImagePropertyTIFFArtist] == nil, "PDF image excludes JPEG Artist metadata")
check(embeddedTIFF?[kCGImagePropertyTIFFDocumentName] == nil, "PDF image excludes JPEG DocumentName metadata")
check(embeddedProperties![kCGImagePropertyGPSDictionary] == nil, "PDF image excludes JPEG GPS metadata")
check(sha256(texturedJPEG) == texturedHash, "image conversion does not modify its JPEG input")
let compactDocument = PDFDocument(url: compactPDF)!
let compactBounds = compactDocument.page(at: 0)!.bounds(for: .mediaBox)
check(abs(compactBounds.width - 800) < 0.01 && abs(compactBounds.height - 500) < 0.01, "JPEG DPI controls PDF page dimensions")

let orientationExpectations: [(Int, [String], CGSize)] = [
    (1, ["R", "G", "B", "Y"], CGSize(width: 120, height: 80)),
    (2, ["G", "R", "Y", "B"], CGSize(width: 120, height: 80)),
    (3, ["Y", "B", "G", "R"], CGSize(width: 120, height: 80)),
    (4, ["B", "Y", "R", "G"], CGSize(width: 120, height: 80)),
    (5, ["R", "B", "G", "Y"], CGSize(width: 80, height: 120)),
    (6, ["B", "R", "Y", "G"], CGSize(width: 80, height: 120)),
    (7, ["Y", "G", "B", "R"], CGSize(width: 80, height: 120)),
    (8, ["G", "Y", "R", "B"], CGSize(width: 80, height: 120))
]
let orientedImages = orientationExpectations.map { orientation, _, _ -> URL in
    let url = root.appendingPathComponent("orientation-\(orientation).jpg")
    makeQuadrantJPEG(url, orientation: orientation)
    return url
}
let orientationsPDF = try service.imagesToPDF(
    imageURLs: orientedImages,
    outputDirectory: output,
    preferredFilename: "Orientations.pdf"
)
let orientationsDocument = PDFDocument(url: orientationsPDF)!
check(orientationsDocument.pageCount == 8, "multiple images keep their input page count and order")
for (index, expectation) in orientationExpectations.enumerated() {
    let page = orientationsDocument.page(at: index)!
    let bounds = page.bounds(for: .mediaBox)
    check(
        abs(bounds.width - expectation.2.width) < 0.01 && abs(bounds.height - expectation.2.height) < 0.01,
        "EXIF orientation \(expectation.0) has the expected page geometry"
    )
    let actualCorners = renderedCorners(page)
    check(
        actualCorners == expectation.1,
        "EXIF orientation \(expectation.0) maps TL, TR, BL, BR to \(expectation.1.joined()) (got \(actualCorners.joined()))"
    )
}

let unequalDPIImages = [6, 8].map { orientation -> URL in
    let url = root.appendingPathComponent("orientation-\(orientation)-unequal-dpi.jpg")
    makeQuadrantJPEG(url, orientation: orientation, dpiX: 300, dpiY: 150)
    return url
}
let unequalDPIPDF = try service.imagesToPDF(
    imageURLs: unequalDPIImages,
    outputDirectory: output,
    preferredFilename: "Unequal DPI.pdf"
)
let unequalDPIDocument = PDFDocument(url: unequalDPIPDF)!
for (index, orientation) in [6, 8].enumerated() {
    let bounds = unequalDPIDocument.page(at: index)!.bounds(for: .mediaBox)
    check(
        abs(bounds.width - 38.4) < 0.01 && abs(bounds.height - 28.8) < 0.01,
        "EXIF orientation \(orientation) swaps unequal DPI axes to a 38.4 by 28.8 point page (got \(bounds.width) by \(bounds.height))"
    )
}

let alphaPNG = root.appendingPathComponent("alpha.png")
makeAlphaPNG(alphaPNG)
let alphaPDF = try service.imagesToPDF(imageURLs: [alphaPNG], outputDirectory: output, preferredFilename: "Alpha.pdf")
let alphaDocument = PDFDocument(url: alphaPDF)!
let alphaPage = alphaDocument.page(at: 0)!
let alphaBitmap = renderedBitmap(alphaPage, width: 40, height: 40, background: TestRGB(red: 0, green: 0, blue: 230))
let alphaColor = alphaBitmap.colorAt(x: 20, y: 20)!.usingColorSpace(.deviceRGB)!
check(
    alphaColor.redComponent > 0.35 && alphaColor.blueComponent > 0.35 && alphaColor.greenComponent < 0.2,
    "PNG fallback preserves source alpha when embedded in a PDF"
)

let imageCancelOutput = root.appendingPathComponent("image-cancel", isDirectory: true)
try fm.createDirectory(at: imageCancelOutput, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
var imageCancellationChecks = 0
do {
    _ = try service.imagesToPDF(
        imageURLs: [orientedImages[0], orientedImages[1]],
        outputDirectory: imageCancelOutput,
        checkCancellation: {
            imageCancellationChecks += 1
            if imageCancellationChecks >= 2 { throw CancellationError() }
        }
    )
    fatalError("Image conversion cancellation was ignored")
} catch is CancellationError {
    let leftovers = try fm.contentsOfDirectory(atPath: imageCancelOutput.path)
    check(leftovers.isEmpty, "image conversion cancellation removes its partial PDF")
}

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

check(
    compactPDFData.count <= texturedSourceData.count + 64 * 1024,
    "JPEG-backed PDF adds no more than 64 KiB of container overhead (JPEG \(texturedSourceData.count) bytes, PDF \(compactPDFData.count) bytes)"
)
check(
    compactPDFData.range(of: originalCompressedScan) != nil,
    "JPEG image XObject preserves the original compressed image scan"
)

let outputPermissions = (try fm.attributesOfItem(atPath: merged.path)[.posixPermissions] as! NSNumber).intValue
check(outputPermissions & 0o077 == 0, "generated PDF is owner-only")
print("PASS: PDF processing suite complete")
