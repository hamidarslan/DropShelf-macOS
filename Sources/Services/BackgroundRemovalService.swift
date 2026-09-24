import Cocoa
import CoreImage
import CoreML
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum BackgroundRemovalEngine: String, CaseIterable {
    case quality
    case native

    public var title: String {
        switch self { case .quality: return "Quality · BiRefNet"; case .native: return "Fast · Apple Vision" }
    }
    public var explanation: String {
        switch self {
        case .quality: return "Full BiRefNet at 1024 px, processed locally. Install the optional verified model once (about 496 MB); processing never downloads it, and images are never uploaded. Requires macOS 15."
        case .native: return "Apple’s on-device subject isolation. No model download. Requires macOS 14."
        }
    }
}

public enum BackgroundRemovalError: LocalizedError {
    case unsupportedSystem(String)
    case noImages
    case unreadableImage(String)
    case noSubject(String)
    case modelOutput
    case imageTooLarge(String)
    case highBitDepth(String, Int)
    case unsupportedHDR(String)
    case outputFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSystem(let message): return message
        case .noImages: return "Choose at least one image."
        case .unreadableImage(let name): return "Could not read \(name) as a still image."
        case .noSubject(let name): return "No clear foreground subject was found in \(name)."
        case .modelOutput: return "The background model returned an invalid mask."
        case .imageTooLarge(let name): return "\(name) is too large to process safely in memory."
        case .highBitDepth(let name, let bits): return "\(name) uses \(bits)-bit color. Background removal currently preserves integer color up to 16 bits, so this file was not changed."
        case .unsupportedHDR(let name): return "\(name) uses floating-point HDR pixels, which background removal cannot preserve yet. The file was not changed."
        case .outputFailed(let name): return "Could not create the transparent PNG for \(name)."
        }
    }
}

public enum BackgroundRemovalService {
    private static let inputSize = 1024
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    public static func validateAvailability(engine: BackgroundRemovalEngine) throws {
        switch engine {
        case .quality:
            guard #available(macOS 15.0, *) else { throw BackgroundRemovalError.unsupportedSystem("Quality background removal requires macOS 15 or later. Choose Apple Vision on macOS 14.") }
        case .native:
            guard #available(macOS 14.0, *) else { throw BackgroundRemovalError.unsupportedSystem("Apple Vision background removal requires macOS 14 or later.") }
        }
    }

    public static func remove(urls: [URL], engine: BackgroundRemovalEngine, outputDirectory: URL,
                              context: OperationContext, modelStore: BackgroundModelStore = .shared) throws -> [URL] {
        guard !urls.isEmpty else { throw BackgroundRemovalError.noImages }
        try validateAvailability(engine: engine)
        try urls.forEach(preflightImage)
        let model: MLModel?
        if engine == .quality {
            let compiledURL = try modelStore.installedModel(context: context)
            let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndGPU
            do {
                model = try MLModel(contentsOf: compiledURL, configuration: configuration)
            } catch {
                modelStore.reportCompiledModelLoadFailure()
                throw BackgroundModelStoreError.needsPreparation
            }
        } else { model = nil }

        var outputs: [URL] = []
        do {
            for (index, url) in urls.enumerated() {
                let output: URL = try autoreleasepool {
                    try context.checkCancellation()
                    context.progress(Double(index) / Double(urls.count), "Removing background from \(url.lastPathComponent)…")
                    let image = try loadOrientedImage(url)
                    let mask: CGImage
                    switch engine {
                    case .quality: mask = try qualityMask(image: image, model: model!)
                    case .native: mask = try nativeMask(image: image, name: url.lastPathComponent)
                    }
                    try context.checkCancellation()
                    let output = uniqueOutput(for: url, directory: outputDirectory)
                    do {
                        try writeTransparentPNG(image: image, mask: mask, to: output, checkCancellation: context.checkCancellation)
                        try context.checkCancellation()
                        return output
                    } catch {
                        try? FileManager.default.removeItem(at: output)
                        throw error
                    }
                }
                outputs.append(output)
                context.progress(Double(index + 1) / Double(urls.count), "Finished \(url.lastPathComponent)")
            }
            return outputs
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output) }
            throw error
        }
    }

    /// Rejects unsupported containers before opening a locally installed model or decoding image pixels.
    private static func preflightImage(_ url: URL) throws {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, UTType(type)?.conforms(to: .pdf) != true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw BackgroundRemovalError.unreadableImage(url.lastPathComponent)
        }
    }

    private static func loadOrientedImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) == 1 else {
            throw BackgroundRemovalError.unreadableImage(url.lastPathComponent)
        }
        if let type = CGImageSourceGetType(source) as String?, UTType(type)?.conforms(to: .pdf) == true {
            throw BackgroundRemovalError.unreadableImage(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let storedWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let storedHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              storedWidth > 0, storedHeight > 0,
              storedWidth <= Int.max / max(storedHeight, 1), storedWidth * storedHeight <= (512 * 1024 * 1024) / 8 else {
            throw BackgroundRemovalError.imageTooLarge(url.lastPathComponent)
        }
        guard let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw BackgroundRemovalError.unreadableImage(url.lastPathComponent)
        }
        guard !raw.bitmapInfo.contains(.floatComponents) else { throw BackgroundRemovalError.unsupportedHDR(url.lastPathComponent) }
        guard raw.bitsPerComponent <= 16 else { throw BackgroundRemovalError.highBitDepth(url.lastPathComponent, raw.bitsPerComponent) }
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        var oriented = CIImage(cgImage: raw).oriented(orientation)
        oriented = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.origin.x, y: -oriented.extent.origin.y))
        let colorSpace = raw.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let format: CIFormat = raw.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let result = ciContext.createCGImage(oriented, from: oriented.extent.integral, format: format, colorSpace: colorSpace) else {
            throw BackgroundRemovalError.unreadableImage(url.lastPathComponent)
        }
        return result
    }

    private static func qualityMask(image: CGImage, model: MLModel) throws -> CGImage {
        let pixels = try rgbaPixels(image: image, width: inputSize, height: inputSize)
        let input = try MLMultiArray(shape: [1, 3, inputSize as NSNumber, inputSize as NSNumber], dataType: .float32)
        let plane = inputSize * inputSize
        input.withUnsafeMutableBytes { raw, _ in
            let values = raw.bindMemory(to: Float32.self)
            for pixel in 0..<plane {
                values[pixel] = (Float(pixels[pixel * 4]) / 255 - 0.485) / 0.229
                values[plane + pixel] = (Float(pixels[pixel * 4 + 1]) / 255 - 0.456) / 0.224
                values[2 * plane + pixel] = (Float(pixels[pixel * 4 + 2]) / 255 - 0.406) / 0.225
            }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
        let prediction = try model.prediction(from: provider)
        guard let logits = prediction.featureValue(for: "mask")?.multiArrayValue, logits.count == plane else {
            throw BackgroundRemovalError.modelOutput
        }
        var bytes = [UInt8](repeating: 0, count: plane)
        for i in 0..<plane {
            let value = logits[i].floatValue
            guard value.isFinite else { throw BackgroundRemovalError.modelOutput }
            let alpha = value >= 0 ? 1 / (1 + exp(-value)) : exp(value) / (1 + exp(value))
            bytes[i] = UInt8(clamping: Int((alpha * 255).rounded()))
        }
        guard let smallMask = grayImage(bytes: bytes, width: inputSize, height: inputSize),
              let scaled = resizeMask(smallMask, width: image.width, height: image.height) else { throw BackgroundRemovalError.modelOutput }
        return scaled
    }

    @available(macOS 14.0, *)
    private static func visionMask(image: CGImage, name: String) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw BackgroundRemovalError.noSubject(name) }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let mask = ciContext.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: image.width, height: image.height)) else {
            throw BackgroundRemovalError.modelOutput
        }
        return mask
    }

    private static func nativeMask(image: CGImage, name: String) throws -> CGImage {
        guard #available(macOS 14.0, *) else { throw BackgroundRemovalError.unsupportedSystem("Apple Vision background removal requires macOS 14 or later.") }
        return try visionMask(image: image, name: name)
    }

    private static func writeTransparentPNG(image: CGImage, mask: CGImage, to url: URL,
                                            checkCancellation: () throws -> Void) throws {
        let foreground = CIImage(cgImage: image)
        let matte = CIImage(cgImage: mask)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { throw BackgroundRemovalError.outputFailed(url.lastPathComponent) }
        filter.setValue(foreground, forKey: kCIInputImageKey)
        filter.setValue(CIImage(color: .clear).cropped(to: foreground.extent), forKey: kCIInputBackgroundImageKey)
        filter.setValue(matte, forKey: kCIInputMaskImageKey)
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let format: CIFormat = image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let output = filter.outputImage,
              let cgOutput = ciContext.createCGImage(output, from: foreground.extent, format: format, colorSpace: colorSpace) else {
            throw BackgroundRemovalError.outputFailed(url.lastPathComponent)
        }
        let partial = url.deletingLastPathComponent().appendingPathComponent(".partial-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: partial) }
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BackgroundRemovalError.outputFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, cgOutput, [kCGImagePropertyPNGDictionary: [:]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BackgroundRemovalError.outputFailed(url.lastPathComponent) }
        try checkCancellation()
        do {
            try FileManager.default.moveItem(at: partial, to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw BackgroundRemovalError.outputFailed(url.lastPathComponent)
        }
    }

    private static func rgbaPixels(image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BackgroundRemovalError.modelOutput
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func grayImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func resizeMask(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func uniqueOutput(for input: URL, directory: URL) -> URL {
        let stem = input.deletingPathExtension().lastPathComponent + "-no-background"
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension("png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension("png"); suffix += 1
        }
        return candidate
    }
}
