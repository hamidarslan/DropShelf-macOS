import Cocoa
import ImageIO
import UniformTypeIdentifiers

struct ImageFormat: Hashable, Identifiable {
    let identifier: String
    let name: String
    let fileExtension: String
    let supportsAlpha: Bool
    let maximumBitsPerComponent: Int

    var id: String { identifier }
}

enum ImageResizeMode: Equatable {
    case original
    case fit(width: Int, height: Int)
    /// A value of 100 keeps the original size; 50 halves both dimensions.
    case percentage(Double)
}

enum ImageMetadataPolicy: Equatable {
    case remove
    case preserve
}

enum ImageAnimationPolicy: Equatable {
    case reject
    case firstFrame
}

struct ImageMatteColor: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    static let white = ImageMatteColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = ImageMatteColor(red: 0, green: 0, blue: 0, alpha: 1)
}

enum ImageAlphaPolicy: Equatable {
    case preserveOrReject
    case flatten(ImageMatteColor)
}

enum ImageBitDepthPolicy: Equatable {
    case preserveOrReject
    case allowReduction
}

struct ImageConversionOptions: Equatable {
    let outputType: String
    var resizeMode: ImageResizeMode = .original
    var quality: Double = 0.92
    var allowUpscaling = false
    var metadataPolicy: ImageMetadataPolicy = .remove
    var animationPolicy: ImageAnimationPolicy = .reject
    var alphaPolicy: ImageAlphaPolicy = .preserveOrReject
    var bitDepthPolicy: ImageBitDepthPolicy = .preserveOrReject
}

enum ImageProcessingError: LocalizedError, Equatable {
    case noImages
    case unsupportedOutputFormat(String)
    case invalidResize
    case invalidQuality
    case cannotRead(String)
    case unsupportedInput(String)
    case multiFrame(String, Int)
    case imageTooLarge(String)
    case decodeFailed(String)
    case alphaWouldBeLost(String, String)
    case bitDepthWouldBeReduced(String, Int, Int)
    case cannotCreateOutputDirectory(String)
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noImages: return "Choose at least one image."
        case .unsupportedOutputFormat(let type): return "This Mac cannot encode the requested image format (\(type))."
        case .invalidResize: return "Resize dimensions and percentage must be positive."
        case .invalidQuality: return "Image quality must be between 0 and 1."
        case .cannotRead(let name): return "Could not read \(name)."
        case .unsupportedInput(let name): return "\(name) is not an image format this Mac can decode."
        case .multiFrame(let name, let count): return "\(name) contains \(count) frames or pages. Choose First Frame explicitly to convert it."
        case .imageTooLarge(let name): return "\(name) is too large to process safely in memory."
        case .decodeFailed(let name): return "Could not decode \(name). The file may be damaged or unsupported."
        case .alphaWouldBeLost(let name, let format): return "\(name) contains transparency, but \(format) cannot preserve it. Choose a matte color or another format."
        case .bitDepthWouldBeReduced(let name, let source, let target): return "\(name) uses \(source)-bit color, but this operation would reduce it to \(target)-bit. Explicitly allow bit-depth reduction or choose a compatible format."
        case .cannotCreateOutputDirectory(let reason): return "Could not create the output folder: \(reason)"
        case .encodeFailed(let name): return "Could not write \(name)."
        }
    }
}

enum ImageProcessingService {
    // This prevents a malformed or exceptionally large image from exhausting the app.
    private static let maximumDecodedBytes = 512 * 1024 * 1024

    static let supportedInputFormats: [ImageFormat] =
        formats(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [], determineAlpha: false)

    static let supportedOutputFormats: [ImageFormat] =
        formats(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [], determineAlpha: true)

    static func convert(
        urls: [URL],
        options: ImageConversionOptions,
        outputDirectory: URL,
        checkCancellation: () throws -> Void = {},
        progress: (Double, String) -> Void = { _, _ in }
    ) throws -> [URL] {
        guard !urls.isEmpty else { throw ImageProcessingError.noImages }
        guard options.quality.isFinite, (0...1).contains(options.quality) else {
            throw ImageProcessingError.invalidQuality
        }
        try validate(options.resizeMode)
        guard let outputFormat = supportedOutputFormats.first(where: { $0.identifier == options.outputType }) else {
            throw ImageProcessingError.unsupportedOutputFormat(options.outputType)
        }

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw ImageProcessingError.cannotCreateOutputDirectory(error.localizedDescription)
        }

        var created: [URL] = []
        do {
            for (index, sourceURL) in urls.enumerated() {
                try checkCancellation()
                let name = sourceURL.lastPathComponent
                progress(Double(index) / Double(urls.count), "Preparing \(name)")
                let outputURL = try convertOne(
                    sourceURL,
                    options: options,
                    format: outputFormat,
                    outputDirectory: outputDirectory,
                    checkCancellation: checkCancellation
                )
                created.append(outputURL)
                progress(Double(index + 1) / Double(urls.count), "Finished \(name)")
            }
            return created
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func convertOne(
        _ sourceURL: URL,
        options: ImageConversionOptions,
        format: ImageFormat,
        outputDirectory: URL,
        checkCancellation: () throws -> Void
    ) throws -> URL {
        let name = sourceURL.lastPathComponent
        guard sourceURL.isFileURL,
              let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageProcessingError.cannotRead(name)
        }
        guard let sourceType = CGImageSourceGetType(source) as String?,
              (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).contains(sourceType) else {
            throw ImageProcessingError.unsupportedInput(name)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ImageProcessingError.decodeFailed(name) }
        if count > 1 && options.animationPolicy == .reject {
            throw ImageProcessingError.multiFrame(name, count)
        }

        guard let rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let storedWidth = integer(rawProperties[kCGImagePropertyPixelWidth]),
              let storedHeight = integer(rawProperties[kCGImagePropertyPixelHeight]),
              storedWidth > 0, storedHeight > 0 else {
            throw ImageProcessingError.decodeFailed(name)
        }
        let orientation = integer(rawProperties[kCGImagePropertyOrientation]) ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let orientedWidth = swapsAxes ? storedHeight : storedWidth
        let orientedHeight = swapsAxes ? storedWidth : storedHeight
        let target = try targetSize(
            width: orientedWidth,
            height: orientedHeight,
            resizeMode: options.resizeMode,
            allowUpscaling: options.allowUpscaling,
            name: name
        )
        try validateMemory(width: target.width, height: target.height, name: name)
        try checkCancellation()

        let thumbnailMax = max(target.width, target.height)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMax
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImageProcessingError.decodeFailed(name)
        }
        try checkCancellation()

        if image.width != target.width || image.height != target.height {
            if image.bitsPerComponent > 8 && options.bitDepthPolicy == .preserveOrReject {
                throw ImageProcessingError.bitDepthWouldBeReduced(name, image.bitsPerComponent, 8)
            }
            guard let scaled = scale(image, width: target.width, height: target.height) else {
                throw ImageProcessingError.decodeFailed(name)
            }
            image = scaled
        }
        if image.bitsPerComponent > format.maximumBitsPerComponent && options.bitDepthPolicy == .preserveOrReject {
            throw ImageProcessingError.bitDepthWouldBeReduced(name, image.bitsPerComponent, format.maximumBitsPerComponent)
        }
        if hasAlpha(image) {
            switch options.alphaPolicy {
            case .preserveOrReject:
                if !format.supportsAlpha {
                    throw ImageProcessingError.alphaWouldBeLost(name, format.name)
                }
            case .flatten(let matte):
                if image.bitsPerComponent > 8 && options.bitDepthPolicy == .preserveOrReject {
                    throw ImageProcessingError.bitDepthWouldBeReduced(name, image.bitsPerComponent, 8)
                }
                guard let flattened = flatten(image, onto: matte) else {
                    throw ImageProcessingError.decodeFailed(name)
                }
                image = flattened
            }
        }
        try checkCancellation()

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, options.outputType as CFString, 1, nil) else {
            throw ImageProcessingError.encodeFailed(name)
        }
        var destinationProperties: [CFString: Any] = options.metadataPolicy == .preserve ? rawProperties : [:]
        destinationProperties[kCGImagePropertyOrientation] = 1
        destinationProperties[kCGImagePropertyPixelWidth] = image.width
        destinationProperties[kCGImagePropertyPixelHeight] = image.height
        destinationProperties[kCGImageDestinationLossyCompressionQuality] = options.quality
        CGImageDestinationAddImage(destination, image, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessingError.encodeFailed(name)
        }
        try checkCancellation()

        let outputURL = uniqueOutputURL(
            sourceURL: sourceURL,
            directory: outputDirectory,
            fileExtension: format.fileExtension
        )
        var wroteOutput = false
        do {
            try (encoded as Data).write(to: outputURL, options: .withoutOverwriting)
            wroteOutput = true
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        } catch {
            if wroteOutput { try? FileManager.default.removeItem(at: outputURL) }
            throw ImageProcessingError.encodeFailed(outputURL.lastPathComponent)
        }
        return outputURL
    }

    private static func formats(_ identifiers: [String], determineAlpha: Bool) -> [ImageFormat] {
        identifiers.compactMap { identifier -> ImageFormat? in
            guard let type = UTType(identifier), let ext = type.preferredFilenameExtension else { return nil }
            return ImageFormat(
                identifier: identifier,
                name: type.localizedDescription ?? ext.uppercased(),
                fileExtension: ext,
                supportsAlpha: determineAlpha ? encoderPreservesAlpha(identifier) : false,
                maximumBitsPerComponent: determineAlpha ? encoderMaximumBitsPerComponent(identifier) : 0
            )
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func encoderPreservesAlpha(_ identifier: String) -> Bool {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bytes: [UInt8] = [255, 0, 0, 0]
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return false }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              let decodedSource = CGImageSourceCreateWithData(data, nil),
              let decoded = CGImageSourceCreateImageAtIndex(decodedSource, 0, nil) else { return false }
        return hasAlpha(decoded)
    }

    private static func encoderMaximumBitsPerComponent(_ identifier: String) -> Int {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let samples = [UInt16.max, UInt16.max / 2, UInt16.max / 4, UInt16.max]
        let data = samples.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: 1, height: 1, bitsPerComponent: 16, bitsPerPixel: 64,
                bytesPerRow: 8, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder16Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return 8 }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, identifier as CFString, 1, nil) else { return 8 }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              let decodedSource = CGImageSourceCreateWithData(encoded, nil),
              let decoded = CGImageSourceCreateImageAtIndex(decodedSource, 0, nil) else { return 8 }
        return decoded.bitsPerComponent
    }

    private static func validate(_ mode: ImageResizeMode) throws {
        switch mode {
        case .original: return
        case .fit(let width, let height):
            guard width > 0, height > 0 else { throw ImageProcessingError.invalidResize }
        case .percentage(let percentage):
            guard percentage.isFinite, percentage > 0 else { throw ImageProcessingError.invalidResize }
        }
    }

    private static func targetSize(
        width: Int, height: Int, resizeMode: ImageResizeMode,
        allowUpscaling: Bool, name: String
    ) throws -> (width: Int, height: Int) {
        let scale: Double
        switch resizeMode {
        case .original:
            scale = 1
        case .fit(let maximumWidth, let maximumHeight):
            scale = min(Double(maximumWidth) / Double(width), Double(maximumHeight) / Double(height))
        case .percentage(let percentage):
            scale = percentage / 100
        }
        let effectiveScale = allowUpscaling ? scale : min(scale, 1)
        let newWidth = Double(width) * effectiveScale
        let newHeight = Double(height) * effectiveScale
        guard newWidth.isFinite, newHeight.isFinite,
              newWidth <= Double(Int.max), newHeight <= Double(Int.max) else {
            throw ImageProcessingError.imageTooLarge(name)
        }
        return (max(1, Int(newWidth.rounded())), max(1, Int(newHeight.rounded())))
    }

    private static func validateMemory(width: Int, height: Int, name: String) throws {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !overflow, !byteOverflow, bytes <= maximumDecodedBytes else {
            throw ImageProcessingError.imageTooLarge(name)
        }
    }

    private static func scale(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let alphaInfo: CGImageAlphaInfo = hasAlpha(image) ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alphaInfo.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func flatten(_ image: CGImage, onto matte: ImageMatteColor) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(red: matte.red, green: matte.green, blue: matte.blue, alpha: matte.alpha)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        case .premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly: return true
        @unknown default: return true
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static func uniqueOutputURL(sourceURL: URL, directory: URL, fileExtension: String) -> URL {
        let stem = sourceURL.deletingPathExtension().lastPathComponent + "-converted"
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) || candidate.standardizedFileURL == sourceURL.standardizedFileURL {
            candidate = directory.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }
}
