import Cocoa
import SwiftUI
import UniformTypeIdentifiers

public enum MediaToolKind: String, CaseIterable { case images = "Images", pdf = "PDF" }

public final class MediaToolsModel: ObservableObject {
    @Published var kind: MediaToolKind = .images
    @Published var urls: [URL] = []
    @Published var selection: Int? = nil
    @Published var error = ""
    @Published private(set) var compressionKinds: [URL: CompressionMediaKind] = [:]
    private let compressionDetector: (URL) -> CompressionMediaKind?
    private var canonicalKeys: Set<URL> = []
    private var canonicalKeyByLexicalKey: [URL: URL] = [:]

    public init(compressionDetector: @escaping (URL) -> CompressionMediaKind? = LosslessCompressionService.detectKind) {
        self.compressionDetector = compressionDetector
    }

    func add(_ incoming: [URL]) {
        for url in incoming where url.isFileURL {
            let lexicalKey = Self.lexicalKey(for: url)
            let canonicalKey = lexicalKey.resolvingSymlinksInPath()
            guard !canonicalKeys.contains(canonicalKey) else { continue }
            urls.append(url)
            canonicalKeys.insert(canonicalKey)
            canonicalKeyByLexicalKey[lexicalKey] = canonicalKey
            if let kind = compressionDetector(url) { compressionKinds[lexicalKey] = kind }
        }
    }

    func replace(with incoming: [URL]) {
        urls = []; selection = nil; compressionKinds = [:]
        canonicalKeys = []; canonicalKeyByLexicalKey = [:]
        add(incoming)
    }

    func remove(at index: Int) {
        guard urls.indices.contains(index) else { return }
        let lexicalKey = Self.lexicalKey(for: urls[index])
        compressionKinds.removeValue(forKey: lexicalKey)
        if let canonicalKey = canonicalKeyByLexicalKey.removeValue(forKey: lexicalKey) {
            canonicalKeys.remove(canonicalKey)
        }
        urls.remove(at: index)
        selection = nil
    }

    func clear() {
        urls = []; selection = nil; compressionKinds = [:]
        canonicalKeys = []; canonicalKeyByLexicalKey = [:]
    }

    func compressionEligibleURLs(for kind: MediaToolKind) -> [URL] {
        urls.filter { url in
            guard let detected = compressionKinds[Self.lexicalKey(for: url)] else { return false }
            return kind == .pdf ? detected == .pdf : detected == .jpeg || detected == .png
        }
    }

    func isLosslessCompressionAvailable(for kind: MediaToolKind) -> Bool {
        !compressionEligibleURLs(for: kind).isEmpty
    }

    func compressionKind(for url: URL) -> CompressionMediaKind? { compressionKinds[Self.lexicalKey(for: url)] }

    private static func lexicalKey(for url: URL) -> URL { url.standardizedFileURL }
    func move(_ delta: Int) {
        guard let index = selection, urls.indices.contains(index), urls.indices.contains(index + delta) else { return }
        urls.swapAt(index, index + delta); selection = index + delta
    }
}

public final class MediaToolsWindowController: NSObject, NSWindowDelegate {
    public static let shared = MediaToolsWindowController()
    public let model = MediaToolsModel()
    private var window: NSWindow?
    public func show(kind: MediaToolKind, urls: [URL]) {
        if !OperationCoordinator.shared.isRunning {
            model.kind = kind
            if window == nil || !urls.isEmpty { model.replace(with: urls) }
            model.error = ""
        }
        if let window = window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 710),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "DropShelf Tools"
        window.contentView = NSHostingView(rootView: MediaToolsView(model: model))
        window.isReleasedWhenClosed = false; window.delegate = self
        window.center(); self.window = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    public func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    public func windowWillClose(_ notification: Notification) { window = nil }
}

public struct OperationProgressView: View {
    @ObservedObject var operation = OperationCoordinator.shared
    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(operation.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if operation.isCancellable {
                    Button { operation.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).disabled(operation.isCancelling)
                        .help("Cancel operation").accessibilityLabel("Cancel operation")
                }
            }
            if let fraction = operation.fraction { ProgressView(value: fraction) }
            else { ProgressView().controlSize(.small) }
            Text(operation.detail).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
        }.padding(9).background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.08)))
    }
}

public struct MediaToolsView: View {
    private static let imageEditAction = "Convert / Resize (changes pixels)"
    private static let compressionAction = "Compress losslessly"
    @ObservedObject var model: MediaToolsModel
    @ObservedObject var operation = OperationCoordinator.shared
    @State private var imageAction = Self.imageEditAction
    @ObservedObject private var backgroundModel = BackgroundModelStore.shared
    @State private var outputType = UTType.png.identifier
    @State private var resize = "Original size"
    @State private var width = "1920"
    @State private var height = "1080"
    @State private var percent = "50"
    @State private var quality = 0.92
    @State private var allowUpscaling = false
    @State private var preserveMetadata = false
    @State private var firstFrame = false
    @State private var flatten = false
    @State private var allowBitDepthReduction = false
    @State private var pdfAction = "Merge PDFs"
    @State private var pages = "1"
    @State private var showFormats = false
    @State private var backgroundEngine = BackgroundRemovalEngine.quality
    @State private var compressionPreset = CompressionPreset.medium
    @State private var pdfCompressionLevel = 6
    @State private var pdfRecompressStreams = true
    @State private var pdfGenerateObjectStreams = true
    @State private var pdfUseZopfli = false
    @State private var pngOptimizationLevel = 3
    @State private var pngUseZopfli = false
    @State private var jpegTrySequential = true
    @State private var jpegTryProgressive = true
    @State private var compressionTimeout = 120.0
    private var pdfActions: [String] {
        var actions = ["Merge PDFs", "Extract / reorder pages", "Images to PDF"]
        if model.isLosslessCompressionAvailable(for: .pdf) { actions.append(Self.compressionAction) }
        return actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Make it ready to share").font(.system(size: 21, weight: .semibold))
                    Text("Local processing. Your originals stay intact.").foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: model.kind == .images ? "photo.on.rectangle.angled" : "doc.richtext")
                    .font(.system(size: 29)).foregroundColor(.blue)
            }
            Picker("Tools", selection: $model.kind) {
                ForEach(MediaToolKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(operation.isRunning)
            sources
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.kind == .images {
                        imageOptions
                        if isQualityBackgroundRemoval { BackgroundModelStatusView(allowsRemoval: true) }
                    } else { pdfOptions }
                    if !operation.lastCompressionResults.isEmpty { compressionResults }
                }.padding(.trailing, 6)
            }
            Spacer(minLength: 0)
            if operation.isRunning { OperationProgressView() }
            else if !model.error.isEmpty { Text(model.error).foregroundColor(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            else if !operation.lastMessage.isEmpty {
                Label(operation.lastMessage, systemImage: operation.lastSucceeded ? "checkmark.circle.fill" : "info.circle")
                    .foregroundColor(operation.lastSucceeded ? .green : .secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Results appear on your shelf.").font(.caption).foregroundColor(.secondary)
                Spacer()
                if let result = operation.lastOutputURLs.first, FileManager.default.fileExists(atPath: result.path) {
                    Button("Preview result") { QuickLookController.shared.show(result) }
                }
                Button("Close") { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction)
                Button(primaryButtonTitle) { run() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(operation.isRunning || model.urls.isEmpty ||
                              (isCompressionAction && compressionEligibleURLs.isEmpty) ||
                              (isCompressionAction && !compressionSettingsValid) ||
                              (isQualityBackgroundRemoval && backgroundModel.status != .ready))
                    .help(isQualityBackgroundRemoval && backgroundModel.status != .ready ? "Download and install the Quality model first." : "Process the source files")
            }
        }.padding(22).frame(width: 600, height: 710)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.blue)
        .onChange(of: compressionEligibilityFingerprint) { _ in clearStaleCompressionActionIfNeeded() }
    }

    private var isQualityBackgroundRemoval: Bool {
        model.kind == .images && imageAction == "Remove background" && backgroundEngine == .quality
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(model.urls.count) source file\(model.urls.count == 1 ? "" : "s")").font(.headline)
                if model.isLosslessCompressionAvailable(for: model.kind) {
                    Label("Lossless available for \(compressionEligibleURLs.count)", systemImage: "arrow.down.circle.fill")
                        .font(.caption).foregroundColor(.green)
                        .help("Open the Action menu to compress compatible files without changing verified content or metadata.")
                }
                Spacer()
                Button("Add files…", action: chooseFiles)
                Button("Clear") { model.clear() }.disabled(model.urls.isEmpty)
            }
            List(selection: $model.selection) {
                ForEach(Array(model.urls.enumerated()), id: \.offset) { index, url in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").foregroundColor(.secondary).monospacedDigit().frame(width: 22)
                        Image(systemName: url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "photo")
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if isCompressionAction {
                            if compressionEligibleURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                                Label(model.compressionKind(for: url)?.title ?? "Lossless", systemImage: "checkmark.shield")
                                    .font(.caption2).foregroundColor(.green)
                            } else {
                                Label("Excluded", systemImage: "minus.circle")
                                    .font(.caption2).foregroundColor(.orange)
                            }
                        }
                    }.tag(index).help(url.path)
                }
            }.frame(height: 118).cornerRadius(8)
            HStack {
                Button { model.move(-1) } label: { Image(systemName: "arrow.up") }.help("Move selected source earlier")
                Button { model.move(1) } label: { Image(systemName: "arrow.down") }.help("Move selected source later")
                Button("Remove selected") { if let index = model.selection { model.remove(at: index) } }
                    .disabled(model.selection == nil)
                Spacer()
                Text("Order shown is output order").font(.caption).foregroundColor(.secondary)
            }
        }.disabled(operation.isRunning)
    }

    private var imageOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Action", selection: $imageAction) {
                Text(Self.imageEditAction).tag(Self.imageEditAction)
                if model.isLosslessCompressionAvailable(for: .images) { Text(Self.compressionAction).tag(Self.compressionAction) }
                Text("Remove background").tag("Remove background")
            }
            if imageAction == Self.compressionAction {
                compressionOptions
            } else if imageAction == "Remove background" {
                Picker("Model", selection: $backgroundEngine) {
                    ForEach(BackgroundRemovalEngine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(backgroundEngine.explanation).font(.caption).foregroundColor(.secondary)
                Text("Exports a transparent PNG at the original pixel dimensions. Review fine hair, glass and shadows before using the result.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("Resize is a separate pixel edit. Changing dimensions or format can change image data and file quality.")
                    .font(.caption).foregroundColor(.secondary)
                Picker("Output format", selection: $outputType) {
                    ForEach(ImageProcessingService.supportedOutputFormats, id: \.identifier) { format in
                        Text("\(format.name) (.\(format.fileExtension))").tag(format.identifier)
                    }
                }
                HStack {
                    Picker("Resize", selection: $resize) {
                        ForEach(["Original size", "Fit within pixels", "Percentage"], id: \.self) { Text($0) }
                    }
                    if resize == "Fit within pixels" {
                        TextField("Width", text: $width).frame(width: 64)
                        Text("×")
                        TextField("Height", text: $height).frame(width: 64)
                    } else if resize == "Percentage" {
                        TextField("Percent", text: $percent).frame(width: 64); Text("%")
                    }
                }
                if resize != "Original size" {
                    Toggle("Allow enlargement", isOn: $allowUpscaling)
                    Text("Aspect ratio is preserved. Fit uses the largest size inside your width and height.").font(.caption).foregroundColor(.secondary)
                }
                if ["public.jpeg", "public.jpeg-2000", "public.heic", "public.heif", "public.avif", "org.webmproject.webp", "public.jpeg-xl"].contains(outputType) {
                    HStack { Text("Lossy quality"); Slider(value: $quality, in: 0.1...1); Text("\(Int(quality * 100))%").monospacedDigit() }
                }
                Toggle("Flatten transparency onto white", isOn: $flatten)
                Toggle("Use only the first frame of animated or multi-page images", isOn: $firstFrame)
                Toggle("Allow bit-depth reduction when required by the output", isOn: $allowBitDepthReduction)
                Toggle("Keep source metadata, including location when present", isOn: $preserveMetadata)
                Button("Supported formats on this Mac…") { showFormats.toggle() }.buttonStyle(.link)
                if showFormats {
                    Text("Read: " + ImageProcessingService.supportedInputFormats.map { $0.name + " (." + $0.fileExtension + ")" }.joined(separator: ", "))
                        .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                    Text("Formats depend on the macOS codecs installed. Unsupported files are reported; they are never silently skipped. RAW decoding renders pixels and does not preserve editable RAW sensor data.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }.disabled(operation.isRunning)
    }

    private var pdfOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Action", selection: $pdfAction) { ForEach(pdfActions, id: \.self) { Text($0) } }
            if pdfAction == Self.compressionAction {
                compressionOptions
            } else if pdfAction == "Extract / reorder pages" {
                TextField("Page order, for example 3, 1, 5-8", text: $pages)
                Text("Choose one PDF. Page numbers start at 1; repeated pages are allowed.").font(.caption).foregroundColor(.secondary)
            } else if pdfAction == "Merge PDFs" {
                Text("Combines every page in source order while retaining text and vector content. Use the arrows above to change file order.").font(.caption).foregroundColor(.secondary)
            } else {
                Text("Creates one PDF page per image, in source order. Animated images must be converted to a still image first.").font(.caption).foregroundColor(.secondary)
            }
            if pdfAction != Self.compressionAction {
                Text("Creates a new PDF. Existing digital signatures do not transfer to the new document. Locked PDFs must be unlocked in another app first.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }.disabled(operation.isRunning)
    }

    private var isCompressionAction: Bool {
        model.kind == .images ? imageAction == Self.compressionAction : pdfAction == Self.compressionAction
    }

    private var compressionEligibleURLs: [URL] { model.compressionEligibleURLs(for: model.kind) }
    private var excludedCompressionCount: Int { max(0, model.urls.count - compressionEligibleURLs.count) }
    private var compressionEligibilityFingerprint: String {
        "\(model.kind.rawValue)|\(compressionEligibleURLs.map(\.path).joined(separator: "|"))"
    }

    private var primaryButtonTitle: String {
        if isCompressionAction { return "Compress losslessly" }
        if model.kind == .images && imageAction == "Remove background" { return "Remove background" }
        return "Create"
    }

    private var compressionOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Effort", selection: $compressionPreset) {
                ForEach(CompressionPreset.allCases) { preset in Text(preset.title).tag(preset) }
            }
            Text("Effort controls how long DropShelf searches for a smaller representation. It never lowers quality, and a smaller file is not guaranteed.")
                .font(.caption).foregroundColor(.secondary)
            Label("\(compressionEligibleURLs.count) compatible \(model.kind == .pdf ? "PDF" : "JPEG/PNG") file\(compressionEligibleURLs.count == 1 ? "" : "s")",
                  systemImage: compressionEligibleURLs.isEmpty ? "exclamationmark.circle" : "checkmark.shield")
                .font(.caption).foregroundColor(compressionEligibleURLs.isEmpty ? .orange : .green)
            if excludedCompressionCount > 0 {
                Text("\(excludedCompressionCount) source file\(excludedCompressionCount == 1 ? " is" : "s are") excluded because this tab accepts only \(model.kind == .pdf ? "PDF" : "JPEG and PNG") compression inputs. Nothing is silently converted.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if compressionPreset == .custom { customCompressionOptions }
            if !compressionSettingsValid {
                Text("Choose valid custom values and at least one JPEG layout.")
                    .font(.caption).foregroundColor(.red)
            }
        }
    }

    @ViewBuilder private var customCompressionOptions: some View {
        if model.kind == .pdf {
            Stepper("PDF stream level: \(pdfCompressionLevel)", value: $pdfCompressionLevel, in: 1...9)
            Toggle("Recompress eligible PDF streams", isOn: $pdfRecompressStreams)
            Toggle("Generate PDF object streams", isOn: $pdfGenerateObjectStreams)
            Toggle("Use Zopfli stream search", isOn: $pdfUseZopfli)
        } else {
            Stepper("PNG search effort: \(pngOptimizationLevel)", value: $pngOptimizationLevel, in: 0...6)
            Toggle("Use Zopfli for PNG candidates", isOn: $pngUseZopfli)
            Toggle("Try sequential JPEG layout", isOn: $jpegTrySequential)
            Toggle("Try progressive JPEG layout", isOn: $jpegTryProgressive)
        }
        HStack {
            Text("Time limit")
            TextField("Seconds", value: $compressionTimeout, format: .number).frame(width: 80)
            Text("seconds").foregroundColor(.secondary)
        }
    }

    private var compressionResults: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Lossless compression results").font(.headline)
            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(operation.lastCompressionResults) { result in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: result.disposition == .compressed ? "checkmark.circle.fill" :
                                (result.disposition == .unchanged ? "equal.circle.fill" : "xmark.octagon.fill"))
                            .foregroundColor(result.disposition == .compressed ? .green :
                                                (result.disposition == .unchanged ? .secondary : .orange))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.inputURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            if result.disposition == .compressed, let resultBytes = result.resultBytes {
                                Text("\(Self.byteCount(result.originalBytes)) → \(Self.byteCount(resultBytes)), saved \(result.savingsPercent, specifier: "%.1f")%")
                                    .font(.caption).monospacedDigit()
                            } else {
                                Text("\(Self.byteCount(result.originalBytes)) · \(result.disposition == .unchanged ? "Unchanged" : "Not compressed")")
                                    .font(.caption).monospacedDigit()
                            }
                            Text(result.detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }.padding(10).background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.08)))
    }

    private static func byteCount(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private func clearStaleCompressionActionIfNeeded() {
        guard compressionEligibleURLs.isEmpty else { return }
        if imageAction == Self.compressionAction { imageAction = Self.imageEditAction }
        if pdfAction == Self.compressionAction { pdfAction = "Merge PDFs" }
    }

    private var currentCompressionOptions: LosslessCompressionOptions {
        var options = LosslessCompressionOptions()
        options.preset = compressionPreset
        options.pdfCompressionLevel = pdfCompressionLevel
        options.pdfRecompressStreams = pdfRecompressStreams
        options.pdfGenerateObjectStreams = pdfGenerateObjectStreams
        options.pdfUseZopfli = pdfUseZopfli
        options.pngOptimizationLevel = pngOptimizationLevel
        options.pngUseZopfli = pngUseZopfli
        options.jpegTrySequential = jpegTrySequential
        options.jpegTryProgressive = jpegTryProgressive
        options.timeoutSeconds = compressionTimeout
        return options
    }

    private var compressionSettingsValid: Bool {
        guard let options = try? currentCompressionOptions.resolved() else { return false }
        let includesJPEG = model.kind == .images && compressionEligibleURLs.contains { model.compressionKind(for: $0) == .jpeg }
        return !includesJPEG || options.jpegTrySequential || options.jpegTryProgressive
    }

    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        // Do not filter by extension: codecs and camera RAW support vary by macOS.
        if let owner = NSApp.keyWindow {
            panel.beginSheetModal(for: owner) { response in
                if response == .OK { model.add(panel.urls) }
                MediaToolsWindowController.shared.bringToFront()
            }
        } else if panel.runModal() == .OK {
            model.add(panel.urls)
            MediaToolsWindowController.shared.bringToFront()
        }
    }

    public static func parsePages(_ value: String) throws -> [Int] {
        var result: [Int] = []
        for part in value.split(separator: ",", omittingEmptySubsequences: false) {
            let range = part.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
            guard range.count <= 2, let first = Int(range[0].trimmingCharacters(in: .whitespaces)), first > 0 else {
                throw toolError("Enter page numbers such as 3, 1, 5-8.")
            }
            if range.count == 2 {
                guard let last = Int(range[1].trimmingCharacters(in: .whitespaces)), last >= first, last - first < 10_000 else { throw toolError("Use ascending ranges such as 5-8.") }
                result.append(contentsOf: first...last)
            } else { result.append(first) }
            guard result.count <= 10_000 else { throw toolError("Choose no more than 10,000 output pages.") }
        }
        return result
    }
    private static func toolError(_ text: String) -> NSError { NSError(domain: "DropShelf.Tools", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    private func run() {
        model.error = ""
        let urls = model.urls
        do {
            if isCompressionAction {
                let eligible = compressionEligibleURLs
                guard !eligible.isEmpty else { throw Self.toolError("Add a compatible \(model.kind == .pdf ? "PDF" : "JPEG or PNG") file to compress.") }
                let options = currentCompressionOptions
                _ = try options.resolved()
                let excluded = excludedCompressionCount
                operation.start(title: "Lossless compression", inputs: eligible) { context in
                    var batchResult: CompressionBatchResult?
                    let outputs = try OperationCoordinator.withOutputDirectory(context: context, allowEmpty: true) { directory in
                        let batch = try LosslessCompressionService.compress(
                            urls: eligible, options: options, outputDirectory: directory,
                            checkCancellation: context.checkCancellation,
                            progress: { context.progress($0, $1) }
                        )
                        batchResult = batch
                        return batch.generatedURLs
                    }
                    guard let batch = batchResult else { throw Self.toolError("Compression did not return a result.") }
                    let exclusionMessage = excluded > 0 ? " \(excluded) incompatible source file\(excluded == 1 ? " was" : "s were") excluded." : ""
                    return OperationResult(generatedURLs: outputs, message: batch.message + exclusionMessage,
                                           succeeded: batch.succeeded, compressionResults: batch.files)
                }
            } else if model.kind == .images && imageAction == "Remove background" {
                let engine = backgroundEngine
                try BackgroundRemovalService.validateAvailability(engine: engine)
                operation.start(title: "Remove background", inputs: urls) { context in
                    let outputs = try OperationCoordinator.withOutputDirectory(context: context) { directory in
                        try BackgroundRemovalService.remove(urls: urls, engine: engine, outputDirectory: directory, context: context)
                    }
                    return OperationResult(generatedURLs: outputs, message: "\(outputs.count) transparent PNG(s) ready on the shelf")
                }
            } else if model.kind == .images {
                let resizeMode: ImageResizeMode
                if resize == "Fit within pixels" {
                    guard let w = Int(width), let h = Int(height), w > 0, h > 0 else { throw Self.toolError("Enter positive whole-pixel dimensions.") }
                    resizeMode = .fit(width: w, height: h)
                } else if resize == "Percentage" {
                    guard let p = Double(percent), p.isFinite, p > 0 else { throw Self.toolError("Enter a positive percentage.") }
                    resizeMode = .percentage(p)
                } else { resizeMode = .original }
                let options = ImageConversionOptions(outputType: outputType, resizeMode: resizeMode, quality: quality,
                    allowUpscaling: allowUpscaling, metadataPolicy: preserveMetadata ? .preserve : .remove,
                    animationPolicy: firstFrame ? .firstFrame : .reject, alphaPolicy: flatten ? .flatten(.white) : .preserveOrReject,
                    bitDepthPolicy: allowBitDepthReduction ? .allowReduction : .preserveOrReject)
                operation.start(title: "Convert images", inputs: urls) { context in
                    let outputs = try OperationCoordinator.withOutputDirectory(context: context) { directory in
                        try ImageProcessingService.convert(urls: urls, options: options, outputDirectory: directory,
                            checkCancellation: context.checkCancellation, progress: { context.progress($0, $1) })
                    }
                    return OperationResult(generatedURLs: outputs, message: "\(outputs.count) image(s) ready on the shelf")
                }
            } else {
                let action = pdfAction
                let selectedPages = action == "Extract / reorder pages" ? try Self.parsePages(pages) : []
                if action == "Extract / reorder pages" && urls.count != 1 { throw Self.toolError("Choose exactly one PDF to extract or reorder pages.") }
                operation.start(title: action, inputs: urls) { context in
                    let outputs = try OperationCoordinator.withOutputDirectory(context: context) { directory in
                        let service = PDFProcessingService.shared
                        let result: URL
                        if action == "Merge PDFs" {
                            result = try service.mergePDFs(inputURLs: urls, outputDirectory: directory, checkCancellation: context.checkCancellation, progress: { context.progress($0, $1) })
                        } else if action == "Extract / reorder pages" {
                            result = try service.extractOrReorderPages(sourceURL: urls[0], pageNumbers: selectedPages, outputDirectory: directory, checkCancellation: context.checkCancellation, progress: { context.progress($0, $1) })
                        } else {
                            result = try service.imagesToPDF(imageURLs: urls, outputDirectory: directory, checkCancellation: context.checkCancellation, progress: { context.progress($0, $1) })
                        }
                        return [result]
                    }
                    return OperationResult(generatedURLs: outputs, message: "PDF ready on the shelf")
                }
            }
        } catch { model.error = error.localizedDescription }
    }
}
