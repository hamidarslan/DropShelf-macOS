import Foundation

public final class LosslessCompressionService {
    private let tools: CompressionToolRunner

    public init(toolsDirectory: URL? = nil) {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        tools = CompressionToolRunner(directory: toolsDirectory ?? resources.appendingPathComponent("CompressionTools"))
    }

    public static func detectKind(at url: URL) -> CompressionMediaKind? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_024) else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return .png }
        if data.starts(with: [0xff, 0xd8, 0xff]) { return .jpeg }
        if data.range(of: Data("%PDF-".utf8)) != nil { return .pdf }
        return nil
    }

    public static func compress(urls: [URL], options: LosslessCompressionOptions, outputDirectory: URL,
                                checkCancellation: () throws -> Void = {},
                                progress: (Double, String) -> Void = { _, _ in }) throws -> CompressionBatchResult {
        try LosslessCompressionService().compressFiles(urls: urls, options: options, outputDirectory: outputDirectory,
                                                       checkCancellation: checkCancellation, progress: progress)
    }

    public func compressFiles(urls: [URL], options: LosslessCompressionOptions, outputDirectory: URL,
                              checkCancellation: () throws -> Void = {},
                              progress: (Double, String) -> Void = { _, _ in }) throws -> CompressionBatchResult {
        guard !urls.isEmpty else { throw LosslessCompressionError.noInput }
        let options = try options.resolved()
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard outputDirectory.isFileURL, fm.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue, fm.isWritableFile(atPath: outputDirectory.path),
              let permissions = try fm.attributesOfItem(atPath: outputDirectory.path)[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else { throw LosslessCompressionError.invalidOutputDirectory }

        var files: [CompressionFileResult] = []
        var completed = false
        defer {
            if !completed { for url in files.compactMap(\.outputURL) { try? fm.removeItem(at: url) } }
        }
        for (index, url) in urls.enumerated() {
            try checkCancellation()
            progress(Double(index) / Double(urls.count), "Checking \(url.lastPathComponent)")
            var originalBytes = Self.size(url)
            guard let kind = Self.detectKind(at: url), originalBytes > 0 else {
                files.append(CompressionFileResult(inputURL: url, outputURL: nil, originalBytes: originalBytes, resultBytes: nil,
                                                  disposition: .rejected, detail: "Strict lossless compression supports PDF, JPEG, and PNG files. The original was kept."))
                continue
            }
            let work = outputDirectory.appendingPathComponent(".compression-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: work) }
            do {
                let deadline = ProcessInfo.processInfo.systemUptime + options.timeoutSeconds
                func checkActive() throws {
                    try checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw LosslessCompressionError.timedOut }
                }
                let originalHash = try CompressionToolRunner.hash(url, checkCancellation: checkActive)
                let snapshot = work.appendingPathComponent("source.\(kind.fileExtension)")
                try Self.snapshot(url, to: snapshot, checkCancellation: checkActive)
                guard try CompressionToolRunner.hash(snapshot, checkCancellation: checkActive) == originalHash else {
                    throw LosslessCompressionError.sourceChanged
                }
                originalBytes = Self.size(snapshot)
                let verifier = kind == .pdf ? "pdf-verify" : "image-verify"
                try verify(verifier, arguments: ["inspect", snapshot.path], work: work, deadline: deadline, checkCancellation: checkCancellation)
                progress(Double(index) / Double(urls.count), "Optimizing \(url.lastPathComponent)")
                var best: URL?
                var bestSize = originalBytes
                try candidates(for: snapshot, kind: kind, options: options, work: work, deadline: deadline,
                               checkCancellation: checkCancellation,
                               progress: { detail in progress(Double(index) / Double(urls.count), detail) }) { candidate, candidateDeadline in
                    try checkCancellation()
                    let bytes = Self.size(candidate)
                    guard bytes > 0, bytes < bestSize else { return }
                    progress(Double(index) / Double(urls.count), "Verifying lossless content in \(url.lastPathComponent)")
                    try verify(verifier, arguments: ["compare", snapshot.path, candidate.path], work: work, deadline: candidateDeadline,
                               checkCancellation: checkCancellation)
                    best = candidate
                    bestSize = bytes
                }
                guard try CompressionToolRunner.hash(url, checkCancellation: checkActive) == originalHash else {
                    throw LosslessCompressionError.sourceChanged
                }
                try checkCancellation()
                if let best {
                    let output = Self.outputURL(for: url, kind: kind, directory: outputDirectory)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: best.path)
                    try fm.moveItem(at: best, to: output)
                    files.append(CompressionFileResult(inputURL: url, outputURL: output, originalBytes: originalBytes,
                                                      resultBytes: bestSize, disposition: .compressed,
                                                      detail: "Content and metadata verified. Original kept."))
                } else {
                    files.append(CompressionFileResult(inputURL: url, outputURL: nil, originalBytes: originalBytes,
                                                      resultBytes: originalBytes, disposition: .unchanged,
                                                      detail: "No smaller lossless result was found. Original kept."))
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try checkCancellation()
                files.append(CompressionFileResult(inputURL: url, outputURL: nil, originalBytes: originalBytes, resultBytes: nil,
                                                  disposition: .rejected, detail: error.localizedDescription))
            }
        }
        try checkCancellation()
        completed = true
        let result = CompressionBatchResult(files: files)
        progress(1, result.message)
        return result
    }

    private func verify(_ tool: String, arguments: [String], work: URL, deadline: TimeInterval,
                        checkCancellation: () throws -> Void) throws {
        let data = try tools.run(tool, arguments: arguments, work: work, deadline: deadline, checkCancellation: checkCancellation)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == true else {
            throw LosslessCompressionError.helperFailed("Lossless preservation could not be verified. The original was kept.")
        }
    }

    private func candidates(for input: URL, kind: CompressionMediaKind, options: LosslessCompressionOptions,
                            work: URL, deadline: TimeInterval, checkCancellation: () throws -> Void,
                            progress: (String) -> Void, accept: (URL, TimeInterval) throws -> Void) throws {
        switch kind {
        case .pdf:
            func create(_ name: String, recompress: Bool, limit: TimeInterval) throws {
                let output = work.appendingPathComponent("\(name).pdf")
                var arguments = ["--suppress-recovery", "--compress-streams=y", "--decode-level=generalized",
                                 "--preserve-unreferenced", "--remove-unreferenced-resources=no", "--newline-before-endstream",
                                 "--object-streams=\(options.pdfGenerateObjectStreams ? "generate" : "preserve")",
                                 "--compression-level=\(options.pdfCompressionLevel)"]
                if recompress { arguments.append("--recompress-flate") }
                arguments += [input.path, output.path]
                try tools.run("qpdf", arguments: arguments, work: work, deadline: limit, zopfli: options.pdfUseZopfli,
                              checkCancellation: checkCancellation)
                try accept(output, limit)
            }
            let strong = options.preset == .strong
            if strong { progress("Optimizing PDF (1 of 2)") }
            try create("candidate", recompress: options.pdfRecompressStreams, limit: deadline)
            guard strong else { return }

            // Reserve time for the final source-integrity check after optional search.
            let searchDeadline = deadline - min(10, max(1, options.timeoutSeconds * 0.1))
            try checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < searchDeadline else { return }
            progress("Optimizing PDF (2 of 2)")
            do {
                try create("preserved", recompress: false, limit: searchDeadline)
            } catch LosslessCompressionError.timedOut {
                // Earlier candidates have already passed full preservation verification.
                return
            } catch LosslessCompressionError.helperFailed {
                // A failed optional encoding cannot replace an independently verified copy.
                return
            }
        case .jpeg:
            guard options.jpegTrySequential || options.jpegTryProgressive else {
                throw LosslessCompressionError.helperFailed("Choose at least one JPEG optimization method.")
            }
            let modes = [(options.jpegTrySequential, "sequential", "-optimize"),
                         (options.jpegTryProgressive, "progressive", "-progressive")]
            for (enabled, name, flag) in modes where enabled {
                let output = work.appendingPathComponent("\(name).jpg")
                try tools.run("jpegtran", arguments: ["-copy", "all", "-strict", "-maxscans", "100", "-maxmemory", "262144",
                                                      flag, "-outfile", output.path, input.path],
                              work: work, deadline: deadline, checkCancellation: checkCancellation)
                try accept(output, deadline)
            }
        case .png:
            let optimized = work.appendingPathComponent("optimized.png")
            let output = work.appendingPathComponent("candidate.png")
            var arguments = ["--nx", "--interlace", "keep", "--force", "--threads", "2", "--max-raw-size", "512MiB",
                             "-o", String(options.pngOptimizationLevel), "--out", optimized.path]
            if options.pngUseZopfli { arguments += ["--zopfli", "--zi", "15", "--ziwi", "5", "--fast"] }
            arguments.append(input.path)
            try tools.run("oxipng", arguments: arguments, work: work, deadline: deadline, checkCancellation: checkCancellation)
            try verify("image-verify", arguments: ["restore-png", input.path, optimized.path, output.path],
                       work: work, deadline: deadline, checkCancellation: checkCancellation)
            try accept(output, deadline)
        }
    }

    private static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func snapshot(_ input: URL, to output: URL, checkCancellation: () throws -> Void) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw LosslessCompressionError.invalidOutputDirectory
        }
        let source = try FileHandle(forReadingFrom: input)
        let destination = try FileHandle(forWritingTo: output)
        defer { try? source.close(); try? destination.close() }
        while true {
            try checkCancellation()
            let data = try source.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            try destination.write(contentsOf: data)
        }
        try destination.synchronize()
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: output.path)
    }

    private static func outputURL(for input: URL, kind: CompressionMediaKind, directory: URL) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        let suffix = kind == .jpeg && input.pathExtension.lowercased() == "jpeg" ? "jpeg" : kind.fileExtension
        var counter = 1
        while true {
            let name = counter == 1 ? "\(base)-compressed.\(suffix)" : "\(base)-compressed \(counter).\(suffix)"
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            counter += 1
        }
    }
}
