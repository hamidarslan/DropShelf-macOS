import Cocoa
import ImageIO
import UniformTypeIdentifiers

func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
    print("PASS: \(label)")
}

func image(width: Int, height: Int, alpha: UInt8 = 255,
           colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        pixels[offset] = 45
        pixels[offset + 1] = 120
        pixels[offset + 2] = 220
        pixels[offset + 3] = alpha
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
}

func image16(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    var pixels = [UInt16](repeating: 0, count: width * height * 4)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        pixels[offset] = UInt16.max
        pixels[offset + 1] = 32_768
        pixels[offset + 2] = 4_096
        pixels[offset + 3] = UInt16.max
    }
    let data = pixels.withUnsafeBytes { Data($0) }
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
        bytesPerRow: width * 8, space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder16Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
}

func write(_ image: CGImage, to url: URL, type: String, properties: [CFString: Any] = [:], frames: Int = 1) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil)!
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
    precondition(CGImageDestinationFinalize(destination), "fixture encoding")
}

func dimensions(_ url: URL) -> (Int, Int) {
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
    return ((properties[kCGImagePropertyPixelWidth] as! NSNumber).intValue,
            (properties[kCGImagePropertyPixelHeight] as! NSNumber).intValue)
}

func expectedError(_ label: String, _ body: () throws -> Void, matching: (Error) -> Bool) {
    do {
        try body()
        preconditionFailure("Expected error: \(label)")
    } catch {
        check(matching(error), label)
    }
}

let fileManager = FileManager.default
let root = fileManager.temporaryDirectory.appendingPathComponent("dropshelf-images-\(UUID().uuidString)")
let input = root.appendingPathComponent("input")
let output = root.appendingPathComponent("output")
try fileManager.createDirectory(at: input, withIntermediateDirectories: true)
try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: root) }

let inputs = ImageProcessingService.supportedInputFormats
let outputs = ImageProcessingService.supportedOutputFormats
check(!inputs.isEmpty, "runtime decoder format list is available")
check(!outputs.isEmpty, "runtime encoder format list is available")
check(Set(inputs.map(\.identifier)).count == inputs.count, "decoder format identifiers are unique")
check(Set(outputs.map(\.identifier)).count == outputs.count, "encoder format identifiers are unique")

let pngType = UTType.png.identifier
let jpegType = UTType.jpeg.identifier
let tiffType = UTType.tiff.identifier
let pngFormat = outputs.first { $0.identifier == pngType }!
let jpegFormat = outputs.first { $0.identifier == jpegType }!
check(pngFormat.supportsAlpha, "PNG encoder reports alpha preservation")
check(!jpegFormat.supportsAlpha, "JPEG encoder reports no alpha preservation")
check(pngFormat.maximumBitsPerComponent >= 16, "PNG encoder reports 16-bit component support")
check(jpegFormat.maximumBitsPerComponent == 8, "JPEG encoder reports 8-bit component support")

let landscape = input.appendingPathComponent("landscape.png")
write(image(width: 400, height: 200), to: landscape, type: pngType)
var progressValues: [Double] = []
let fitted = try ImageProcessingService.convert(
    urls: [landscape],
    options: ImageConversionOptions(outputType: pngType, resizeMode: .fit(width: 100, height: 100)),
    outputDirectory: output,
    progress: { value, _ in progressValues.append(value) }
)
check(dimensions(fitted[0]) == (100, 50), "fit resize preserves aspect ratio")
check(progressValues == [0, 1], "conversion reports deterministic progress")

let percentage = try ImageProcessingService.convert(
    urls: [landscape],
    options: ImageConversionOptions(outputType: pngType, resizeMode: .percentage(25)),
    outputDirectory: output
)
check(dimensions(percentage[0]) == (100, 50), "percentage resize uses 100 as original size")
check(fitted[0] != percentage[0], "existing output is not overwritten")
check(fileManager.fileExists(atPath: fitted[0].path), "first colliding output remains intact")

let noUpscale = try ImageProcessingService.convert(
    urls: [landscape],
    options: ImageConversionOptions(outputType: pngType, resizeMode: .fit(width: 800, height: 800)),
    outputDirectory: output
)
check(dimensions(noUpscale[0]) == (400, 200), "upscaling is disabled by default")

let permissions = try fileManager.attributesOfItem(atPath: noUpscale[0].path)[.posixPermissions] as! NSNumber
check(permissions.intValue & 0o777 == 0o600, "generated image has private file permissions")

let upscaled = try ImageProcessingService.convert(
    urls: [landscape],
    options: ImageConversionOptions(outputType: pngType, resizeMode: .percentage(200), allowUpscaling: true),
    outputDirectory: output
)
check(dimensions(upscaled[0]) == (800, 400), "explicit upscaling is honored")

let deepColor = input.appendingPathComponent("deep-color.png")
write(image16(width: 24, height: 12), to: deepColor, type: pngType)
let deepColorOutput = try ImageProcessingService.convert(
    urls: [deepColor], options: ImageConversionOptions(outputType: pngType), outputDirectory: output
)
let deepSource = CGImageSourceCreateWithURL(deepColorOutput[0] as CFURL, nil)!
let deepImage = CGImageSourceCreateImageAtIndex(deepSource, 0, nil)!
check(deepImage.bitsPerComponent == 16, "16-bit component depth is preserved without resizing")
let deepColorResized = try ImageProcessingService.convert(
    urls: [deepColor],
    options: ImageConversionOptions(outputType: pngType, resizeMode: .fit(width: 12, height: 6)),
    outputDirectory: output
)
let deepResizedSource = CGImageSourceCreateWithURL(deepColorResized[0] as CFURL, nil)!
let deepResizedImage = CGImageSourceCreateImageAtIndex(deepResizedSource, 0, nil)!
check(deepResizedImage.bitsPerComponent == 16, "16-bit component depth is preserved while downscaling")
expectedError("silent bit-depth reduction is refused", {
    _ = try ImageProcessingService.convert(
        urls: [deepColor], options: ImageConversionOptions(outputType: jpegType), outputDirectory: output
    )
}, matching: { if case ImageProcessingError.bitDepthWouldBeReduced(_, 16, 8) = $0 { return true }; return false })
let reducedDepth = try ImageProcessingService.convert(
    urls: [deepColor],
    options: ImageConversionOptions(outputType: jpegType, alphaPolicy: .flatten(.white), bitDepthPolicy: .allowReduction),
    outputDirectory: output
)
let reducedSource = CGImageSourceCreateWithURL(reducedDepth[0] as CFURL, nil)!
let reducedImage = CGImageSourceCreateImageAtIndex(reducedSource, 0, nil)!
check(reducedImage.bitsPerComponent == 8, "bit-depth reduction requires explicit opt-in")

let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let wideColor = input.appendingPathComponent("display-p3.png")
write(image(width: 18, height: 9, colorSpace: p3), to: wideColor, type: pngType)
let wideColorOutput = try ImageProcessingService.convert(
    urls: [wideColor], options: ImageConversionOptions(outputType: pngType), outputDirectory: output
)
let wideSource = CGImageSourceCreateWithURL(wideColorOutput[0] as CFURL, nil)!
let wideImage = CGImageSourceCreateImageAtIndex(wideSource, 0, nil)!
check(wideImage.colorSpace?.name == CGColorSpace.displayP3, "ICC color profile is preserved when metadata is removed")

let rotated = input.appendingPathComponent("rotated.jpg")
write(image(width: 40, height: 20), to: rotated, type: jpegType,
      properties: [kCGImagePropertyOrientation: 6])
let oriented = try ImageProcessingService.convert(
    urls: [rotated], options: ImageConversionOptions(outputType: pngType), outputDirectory: output
)
check(dimensions(oriented[0]) == (20, 40), "EXIF orientation is applied to pixels")
let orientedSource = CGImageSourceCreateWithURL(oriented[0] as CFURL, nil)!
let orientedProperties = CGImageSourceCopyPropertiesAtIndex(orientedSource, 0, nil)! as NSDictionary
check((orientedProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1,
      "output orientation is normalized")
for orientation in 1...8 {
    let fixture = input.appendingPathComponent("orientation-\(orientation).jpg")
    write(image(width: 40, height: 20), to: fixture, type: jpegType,
          properties: [kCGImagePropertyOrientation: orientation])
    let converted = try ImageProcessingService.convert(
        urls: [fixture], options: ImageConversionOptions(outputType: pngType), outputDirectory: output
    )
    let expected = orientation >= 5 ? (20, 40) : (40, 20)
    check(dimensions(converted[0]) == expected, "EXIF orientation \(orientation) produces normalized dimensions")
}

let transparent = input.appendingPathComponent("transparent.png")
write(image(width: 32, height: 16, alpha: 80), to: transparent, type: pngType)
let flattenedPNG = try ImageProcessingService.convert(
    urls: [transparent],
    options: ImageConversionOptions(outputType: pngType, alphaPolicy: .flatten(.white)),
    outputDirectory: output
)
let flattenedPNGSource = CGImageSourceCreateWithURL(flattenedPNG[0] as CFURL, nil)!
let flattenedPNGImage = CGImageSourceCreateImageAtIndex(flattenedPNGSource, 0, nil)!
check([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(flattenedPNGImage.alphaInfo),
      "explicit flatten applies even when the output format supports alpha")
expectedError("alpha loss is refused by default", {
    _ = try ImageProcessingService.convert(
        urls: [transparent], options: ImageConversionOptions(outputType: jpegType), outputDirectory: output
    )
}, matching: { if case ImageProcessingError.alphaWouldBeLost = $0 { return true }; return false })

let flattened = try ImageProcessingService.convert(
    urls: [transparent],
    options: ImageConversionOptions(outputType: jpegType, alphaPolicy: .flatten(.white)),
    outputDirectory: output
)
check(dimensions(flattened[0]) == (32, 16), "explicit matte allows conversion to a non-alpha format")

let animated = input.appendingPathComponent("two-pages.tiff")
write(image(width: 12, height: 8), to: animated, type: tiffType, frames: 2)
expectedError("multi-frame input is refused by default", {
    _ = try ImageProcessingService.convert(
        urls: [animated], options: ImageConversionOptions(outputType: pngType), outputDirectory: output
    )
}, matching: { if case ImageProcessingError.multiFrame(_, 2) = $0 { return true }; return false })
let firstFrame = try ImageProcessingService.convert(
    urls: [animated],
    options: ImageConversionOptions(outputType: pngType, animationPolicy: .firstFrame),
    outputDirectory: output
)
check(dimensions(firstFrame[0]) == (12, 8), "first frame conversion requires explicit opt-in")

let corrupt = input.appendingPathComponent("broken.png")
try Data("not an image".utf8).write(to: corrupt)
expectedError("corrupt input is refused", {
    _ = try ImageProcessingService.convert(
        urls: [corrupt], options: ImageConversionOptions(outputType: pngType), outputDirectory: output
    )
}, matching: {
    if case ImageProcessingError.cannotRead = $0 { return true }
    if case ImageProcessingError.unsupportedInput = $0 { return true }
    if case ImageProcessingError.decodeFailed = $0 { return true }
    return false
})

let cancellationOutput = root.appendingPathComponent("cancelled")
var checks = 0
enum TestCancellation: Error { case cancelled }
expectedError("cancellation propagates", {
    _ = try ImageProcessingService.convert(
        urls: [landscape, landscape],
        options: ImageConversionOptions(outputType: pngType),
        outputDirectory: cancellationOutput,
        checkCancellation: {
            checks += 1
            if checks >= 6 { throw TestCancellation.cancelled }
        }
    )
}, matching: { $0 is TestCancellation })
let leftovers = (try? fileManager.contentsOfDirectory(at: cancellationOutput, includingPropertiesForKeys: nil)) ?? []
check(leftovers.isEmpty, "cancellation removes completed outputs from the batch")

expectedError("invalid resize is refused", {
    _ = try ImageProcessingService.convert(
        urls: [landscape],
        options: ImageConversionOptions(outputType: pngType, resizeMode: .fit(width: 0, height: 20)),
        outputDirectory: output
    )
}, matching: { $0 as? ImageProcessingError == .invalidResize })

print("PASS: image conversion regression suite")
