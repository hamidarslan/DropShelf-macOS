import Foundation
import CryptoKit
import Darwin

final class CompressionToolRunner {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let tools: [Entry]
        struct Entry: Decodable { let name: String; let path: String; let sha256: String }
    }
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func executable(_ name: String, checkCancellation: () throws -> Void) throws -> URL {
        let allowed = ["qpdf", "jpegtran", "oxipng", "pdf-verify", "image-verify"]
        guard allowed.contains(name),
              let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.schemaVersion == 1,
              let entry = manifest.tools.first(where: { $0.name == name }), entry.path == "bin/\(name)" else {
            throw LosslessCompressionError.helperUnavailable(name)
        }
        let url = directory.appendingPathComponent(entry.path)
        let prefix = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(prefix),
              FileManager.default.isExecutableFile(atPath: url.path),
              try Self.hash(url, checkCancellation: checkCancellation) == entry.sha256 else {
            throw LosslessCompressionError.helperUnavailable(name)
        }
        return url
    }

    static func hash(_ url: URL, checkCancellation: () throws -> Void) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func run(_ name: String, arguments: [String], work: URL, deadline: TimeInterval,
             zopfli: Bool = false, checkCancellation: () throws -> Void) throws -> Data {
        try checkCancellation()
        let tool = try executable(name, checkCancellation: checkCancellation)
        let fm = FileManager.default
        let output = work.appendingPathComponent(".stdout-\(UUID().uuidString)")
        let errors = work.appendingPathComponent(".stderr-\(UUID().uuidString)")
        guard fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw LosslessCompressionError.invalidOutputDirectory
        }
        defer { try? fm.removeItem(at: output); try? fm.removeItem(at: errors) }
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = work
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "TMPDIR": work.path]
        if zopfli { process.environment?["QPDF_ZOPFLI"] = "force" }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        do {
            while process.isRunning {
                try checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw LosslessCompressionError.timedOut }
                let size = [output, errors].reduce(Int64(0)) { total, url in
                    total + ((try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
                }
                guard size <= 2_097_152 else {
                    throw LosslessCompressionError.helperFailed("The file produced too many diagnostics to process safely.")
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            process.waitUntilExit()
            try checkCancellation()
        } catch {
            if process.isRunning {
                process.terminate()
                let stopBy = ProcessInfo.processInfo.systemUptime + 0.4
                while process.isRunning && ProcessInfo.processInfo.systemUptime < stopBy { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            throw error
        }
        try stdout.synchronize()
        try stderr.synchronize()
        let finalSize = try [output, errors].reduce(Int64(0)) { total, url in
            total + ((try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        guard finalSize <= 2_097_152 else {
            throw LosslessCompressionError.helperFailed("The file produced too many diagnostics to process safely.")
        }
        func boundedRead(_ url: URL) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 2_097_153) ?? Data()
            guard data.count <= 2_097_152 else {
                throw LosslessCompressionError.helperFailed("The file produced too many diagnostics to process safely.")
            }
            return data
        }
        let result = try boundedRead(output)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            if let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
               let reason = object["reason"] as? String, !reason.isEmpty {
                let explanations = [
                    "signed": "This PDF contains signature information. Rewriting it could invalidate a signature, so the original was kept.",
                    "provenance": "This PDF contains content credentials. Rewriting it could invalidate them, so the original was kept.",
                    "encrypted": "Encrypted PDFs are not supported for verified lossless compression. The original was kept.",
                    "xfa": "This PDF contains XFA forms that cannot be verified safely. The original was kept.",
                    "malformed": "The PDF is damaged or requires repair. It was left unchanged.",
                    "unsupported-stream": "This PDF contains an unsupported or external data stream. It was left unchanged.",
                    "content-mismatch": "The smaller file did not preserve all content and metadata. It was discarded.",
                    "resource-limit": "The file exceeds the safe verification limits. The original was kept.",
                    "io-error": "The file could not be read safely. The original was kept."
                ]
                throw LosslessCompressionError.helperFailed(explanations[reason] ?? String(reason.prefix(500)))
            }
            let diagnostic = String(decoding: try boundedRead(errors), as: UTF8.self)
            let detail = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LosslessCompressionError.helperFailed(detail.isEmpty ? "The file could not be safely compressed." : String(detail.prefix(500)))
        }
        return result
    }
}
