import Foundation

public enum CompressionPreset: String, CaseIterable, Identifiable {
    case low, medium, strong, custom
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum CompressionMediaKind: String {
    case pdf, jpeg, png
    public var title: String { rawValue.uppercased() }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

public struct LosslessCompressionOptions: Equatable {
    public var preset: CompressionPreset = .medium
    public var pdfCompressionLevel = 6
    public var pdfRecompressStreams = true
    public var pdfGenerateObjectStreams = true
    public var pdfUseZopfli = false
    public var pngOptimizationLevel = 3
    public var pngUseZopfli = false
    public var jpegTrySequential = true
    public var jpegTryProgressive = true
    public var timeoutSeconds: Double = 120

    public init() {}

    public func resolved() throws -> LosslessCompressionOptions {
        var result = self
        switch preset {
        case .low:
            result.pdfCompressionLevel = 3
            result.pdfRecompressStreams = false
            result.pdfGenerateObjectStreams = false
            result.pdfUseZopfli = false
            result.pngOptimizationLevel = 1
            result.pngUseZopfli = false
            result.jpegTrySequential = true
            result.jpegTryProgressive = false
        case .medium:
            result.pdfCompressionLevel = 6
            result.pdfRecompressStreams = true
            result.pdfGenerateObjectStreams = true
            result.pdfUseZopfli = false
            result.pngOptimizationLevel = 3
            result.pngUseZopfli = false
            result.jpegTrySequential = false
            result.jpegTryProgressive = true
        case .strong:
            result.pdfCompressionLevel = 9
            result.pdfRecompressStreams = true
            result.pdfGenerateObjectStreams = true
            result.pdfUseZopfli = true
            result.pngOptimizationLevel = 6
            result.pngUseZopfli = true
            result.jpegTrySequential = true
            result.jpegTryProgressive = true
        case .custom: break
        }
        guard (1...9).contains(result.pdfCompressionLevel),
              (0...6).contains(result.pngOptimizationLevel),
              result.timeoutSeconds.isFinite, (5...600).contains(result.timeoutSeconds) else {
            throw LosslessCompressionError.invalidOptions
        }
        return result
    }
}

public enum CompressionFileDisposition: String {
    case compressed, unchanged, rejected
}

public struct CompressionFileResult: Identifiable {
    public let inputURL: URL
    public let outputURL: URL?
    public let originalBytes: Int64
    public let resultBytes: Int64?
    public let disposition: CompressionFileDisposition
    public let detail: String
    public var id: URL { inputURL }
    public var savedBytes: Int64 { max(0, originalBytes - (resultBytes ?? originalBytes)) }
    public var savingsPercent: Double { originalBytes > 0 ? Double(savedBytes) * 100 / Double(originalBytes) : 0 }

    public init(inputURL: URL, outputURL: URL?, originalBytes: Int64, resultBytes: Int64?,
                disposition: CompressionFileDisposition, detail: String) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.originalBytes = originalBytes
        self.resultBytes = resultBytes
        self.disposition = disposition
        self.detail = detail
    }
}

public struct CompressionBatchResult {
    public let files: [CompressionFileResult]
    public var generatedURLs: [URL] { files.compactMap(\.outputURL) }
    public var succeeded: Bool { files.contains { $0.disposition != .rejected } }
    public var message: String {
        let reduced = files.filter { $0.disposition == .compressed }.count
        let unchanged = files.filter { $0.disposition == .unchanged }.count
        let rejected = files.filter { $0.disposition == .rejected }.count
        var parts: [String] = []
        if reduced > 0 { parts.append("\(reduced) smaller") }
        if unchanged > 0 { parts.append("\(unchanged) unchanged") }
        if rejected > 0 { parts.append("\(rejected) not compressed") }
        return parts.joined(separator: ", ") + ". Originals kept."
    }
}

public enum LosslessCompressionError: LocalizedError {
    case noInput
    case invalidOptions
    case invalidOutputDirectory
    case helperUnavailable(String)
    case helperFailed(String)
    case timedOut
    case sourceChanged

    public var errorDescription: String? {
        switch self {
        case .noInput: return "Add a PDF, JPEG, or PNG to compress."
        case .invalidOptions: return "Choose valid compression settings."
        case .invalidOutputDirectory: return "The private output folder is unavailable."
        case .helperUnavailable(let name): return "The bundled \(name) compression tool is missing or damaged. Reinstall DropShelf."
        case .helperFailed(let reason): return reason
        case .timedOut: return "The time limit was reached. The original was kept; try a faster preset or a longer limit."
        case .sourceChanged: return "The source changed while processing. No compressed copy was kept."
        }
    }
}
