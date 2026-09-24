import Foundation
import PDFKit
import ImageIO
import CoreGraphics

public enum PDFProcessingError: LocalizedError, Equatable {
    case noInput
    case invalidOutputDirectory
    case inputUnavailable(String)
    case unreadablePDF(String)
    case encryptedPDF(String)
    case emptyPDF(String)
    case invalidPageNumber(Int, available: Int)
    case unreadableImage(String)
    case multiFrameImage(String, frames: Int)
    case outputFailed

    public var errorDescription: String? {
        switch self {
        case .noInput:
            return "Choose at least one file."
        case .invalidOutputDirectory:
            return "The private output folder is unavailable or not writable."
        case .inputUnavailable(let name):
            return "\(name) is unavailable or cannot be read."
        case .unreadablePDF(let name):
            return "\(name) is not a readable PDF."
        case .encryptedPDF(let name):
            return "\(name) is encrypted or locked. Remove its password before processing."
        case .emptyPDF(let name):
            return "\(name) has no pages."
        case .invalidPageNumber(let page, let available):
            return "Page \(page) is outside the available range of 1 through \(available)."
        case .unreadableImage(let name):
            return "\(name) is not an image format supported by this Mac."
        case .multiFrameImage(let name, let frames):
            return "\(name) contains \(frames) frames or pages. Convert it to a still image before creating a PDF."
        case .outputFailed:
            return "The PDF could not be created."
        }
    }
}

public final class PDFProcessingService {
    public static let shared = PDFProcessingService()

    public init() {}

    public func mergePDFs(
        inputURLs: [URL],
        outputDirectory: URL,
        preferredFilename: String = "Merged.pdf",
        checkCancellation: () throws -> Void = {},
        progress: (Double, String) -> Void = { _, _ in }
    ) throws -> URL {
        guard !inputURLs.isEmpty else { throw PDFProcessingError.noInput }
        let prepared = try prepareOutput(directory: outputDirectory, preferredFilename: preferredFilename)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: prepared.temporary) } }

        var inputs: [(URL, PDFDocument)] = []
        var totalPages = 0
        for url in inputURLs {
            try checkCancellation()
            let document = try loadPDF(url)
            inputs.append((url, document))
            totalPages += document.pageCount
        }

        let output = PDFDocument()
        var writtenPages = 0
        progress(0, "Preparing PDFs")
        for (url, document) in inputs {
            for index in 0..<document.pageCount {
                try checkCancellation()
                guard let page = document.page(at: index)?.copy() as? PDFPage else {
                    throw PDFProcessingError.unreadablePDF(url.lastPathComponent)
                }
                output.insert(page, at: output.pageCount)
                writtenPages += 1
                progress(Double(writtenPages) / Double(totalPages), "Merging page \(writtenPages) of \(totalPages)")
            }
        }
        try checkCancellation()
        try write(output, to: prepared)
        completed = true
        progress(1, "PDF ready")
        return prepared.final
    }

    public func extractOrReorderPages(
        sourceURL: URL,
        pageNumbers: [Int],
        outputDirectory: URL,
        preferredFilename: String = "Pages.pdf",
        checkCancellation: () throws -> Void = {},
        progress: (Double, String) -> Void = { _, _ in }
    ) throws -> URL {
        guard !pageNumbers.isEmpty else { throw PDFProcessingError.noInput }
        let source = try loadPDF(sourceURL)
        for number in pageNumbers where !(1...source.pageCount).contains(number) {
            throw PDFProcessingError.invalidPageNumber(number, available: source.pageCount)
        }
        let prepared = try prepareOutput(directory: outputDirectory, preferredFilename: preferredFilename)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: prepared.temporary) } }

        let output = PDFDocument()
        progress(0, "Preparing pages")
        for (index, number) in pageNumbers.enumerated() {
            try checkCancellation()
            guard let page = source.page(at: number - 1)?.copy() as? PDFPage else {
                throw PDFProcessingError.unreadablePDF(sourceURL.lastPathComponent)
            }
            output.insert(page, at: output.pageCount)
            progress(Double(index + 1) / Double(pageNumbers.count), "Adding page \(index + 1) of \(pageNumbers.count)")
        }
        try checkCancellation()
        try write(output, to: prepared)
        completed = true
        progress(1, "PDF ready")
        return prepared.final
    }

    public func imagesToPDF(
        imageURLs: [URL],
        outputDirectory: URL,
        preferredFilename: String = "Images.pdf",
        checkCancellation: () throws -> Void = {},
        progress: (Double, String) -> Void = { _, _ in }
    ) throws -> URL {
        guard !imageURLs.isEmpty else { throw PDFProcessingError.noInput }
        let prepared = try prepareOutput(directory: outputDirectory, preferredFilename: preferredFilename)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: prepared.temporary) } }

        guard let consumer = CGDataConsumer(url: prepared.temporary as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PDFProcessingError.outputFailed
        }

        progress(0, "Preparing images")
        for (index, url) in imageURLs.enumerated() {
            try checkCancellation()
            try autoreleasepool {
                let image = try decodedOrientedImage(at: url)
                let pageSize = pdfPageSize(for: image.image, properties: image.properties)
                var mediaBox = CGRect(origin: .zero, size: pageSize)
                context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary)
                context.interpolationQuality = .high
                context.draw(image.image, in: mediaBox)
                context.endPDFPage()
            }
            progress(Double(index + 1) / Double(imageURLs.count), "Adding image \(index + 1) of \(imageURLs.count)")
        }
        try checkCancellation()
        context.closePDF()
        guard FileManager.default.fileExists(atPath: prepared.temporary.path) else {
            throw PDFProcessingError.outputFailed
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prepared.temporary.path)
        try FileManager.default.moveItem(at: prepared.temporary, to: prepared.final)
        completed = true
        progress(1, "PDF ready")
        return prepared.final
    }

    // A generated PDF never promises to retain the validity of source signatures.
    // This conservative scan is for presenting that warning before processing.
    public func documentHasDigitalSignatures(_ url: URL) throws -> Bool {
        try validateReadableFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let signatures = [Data("/FT/Sig".utf8), Data("/FT /Sig".utf8), Data("/Type/Sig".utf8), Data("/Type /Sig".utf8)]
        var tail = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { return false }
            let data = tail + chunk
            if signatures.contains(where: { data.range(of: $0) != nil }) { return true }
            tail = Data(data.suffix(16))
        }
    }

    private typealias PreparedOutput = (temporary: URL, final: URL)

    private func prepareOutput(directory: URL, preferredFilename: String) throws -> PreparedOutput {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
              fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.isWritableFile(atPath: directory.path) else {
            throw PDFProcessingError.invalidOutputDirectory
        }
        let rawName = URL(fileURLWithPath: preferredFilename).lastPathComponent
        let baseName = rawName.isEmpty ? "Output" : URL(fileURLWithPath: rawName).deletingPathExtension().lastPathComponent
        var final = directory.appendingPathComponent(baseName + ".pdf", isDirectory: false)
        var suffix = 2
        while fm.fileExists(atPath: final.path) {
            final = directory.appendingPathComponent("\(baseName) \(suffix).pdf", isDirectory: false)
            suffix += 1
        }
        let temporary = directory.appendingPathComponent(".dropshelf-\(UUID().uuidString).pdf", isDirectory: false)
        return (temporary, final)
    }

    private func validateReadableFile(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw PDFProcessingError.inputUnavailable(url.lastPathComponent)
        }
    }

    private func loadPDF(_ url: URL) throws -> PDFDocument {
        try validateReadableFile(url)
        guard let document = PDFDocument(url: url) else {
            throw PDFProcessingError.unreadablePDF(url.lastPathComponent)
        }
        guard !document.isEncrypted, !document.isLocked else {
            throw PDFProcessingError.encryptedPDF(url.lastPathComponent)
        }
        guard document.pageCount > 0 else {
            throw PDFProcessingError.emptyPDF(url.lastPathComponent)
        }
        return document
    }

    private func write(_ document: PDFDocument, to output: PreparedOutput) throws {
        guard document.pageCount > 0, document.write(to: output.temporary) else {
            throw PDFProcessingError.outputFailed
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.temporary.path)
        try FileManager.default.moveItem(at: output.temporary, to: output.final)
    }

    private func decodedOrientedImage(at url: URL) throws -> (image: CGImage, properties: [CFString: Any]) {
        try validateReadableFile(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw PDFProcessingError.unreadableImage(url.lastPathComponent)
        }
        // ImageIO also exposes PDF pages through CGImageSource. Keep this API image-only
        // so a one-page PDF cannot be silently rasterized.
        guard let sourceIdentifier = CGImageSourceGetType(source),
              sourceIdentifier as String != "com.adobe.pdf" else {
            throw PDFProcessingError.unreadableImage(url.lastPathComponent)
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount == 1 else {
            throw PDFProcessingError.multiFrameImage(url.lastPathComponent, frames: frameCount)
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maximum = max(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximum),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PDFProcessingError.unreadableImage(url.lastPathComponent)
        }
        return (image, properties)
    }

    private func pdfPageSize(for image: CGImage, properties: [CFString: Any]) -> CGSize {
        func usableDPI(_ value: Any?) -> CGFloat? {
            guard let number = value as? NSNumber else { return nil }
            let dpi = CGFloat(truncating: number)
            return (36...600).contains(dpi) ? dpi : nil
        }
        let dpiX = usableDPI(properties[kCGImagePropertyDPIWidth]) ?? 72
        let dpiY = usableDPI(properties[kCGImagePropertyDPIHeight]) ?? 72
        let width = min(14_400, max(1, CGFloat(image.width) * 72 / dpiX))
        let height = min(14_400, max(1, CGFloat(image.height) * 72 / dpiY))
        return CGSize(width: width, height: height)
    }
}
