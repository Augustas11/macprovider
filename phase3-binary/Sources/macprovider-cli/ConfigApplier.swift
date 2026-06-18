import Darwin
import Foundation
import Yams

enum ConfigApplierError: Error, Equatable, CustomStringConvertible {
    case backupCollisionsExhausted
    case invalidYAML(String)
    case atomicRenameFailed(source: String, destination: String, errno: Int32)
    case stringEncodingFailed(String)

    var description: String {
        switch self {
        case .backupCollisionsExhausted:
            return "backup collisions exhausted"
        case .invalidYAML(let message):
            return "invalid YAML: \(message)"
        case .atomicRenameFailed(let source, let destination, let errno):
            return "atomic rename failed from \(source) to \(destination): errno \(errno)"
        case .stringEncodingFailed(let path):
            return "failed to encode YAML for \(path)"
        }
    }
}

struct ConfigApplier {
    let configPath: URL
    let maxBackupCounter: Int
    let tempFileNamer: (URL, Int) -> URL

    init(
        configPath: URL,
        maxBackupCounter: Int = 65_535,
        tempFileNamer: @escaping (URL, Int) -> URL = ConfigApplier.defaultTempFileName
    ) {
        self.configPath = configPath
        self.maxBackupCounter = maxBackupCounter
        self.tempFileNamer = tempFileNamer
    }

    func apply(
        recommendation: RecommendationCore,
        now: Date
    ) throws -> AppliedConfig {
        let fileManager = FileManager.default
        let directory = configPath.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let originalData = (try? Data(contentsOf: configPath)) ?? Data()
        let originalText = String(decoding: originalData, as: UTF8.self)
        try validateYAML(originalText)

        let unixTS = Int(now.timeIntervalSince1970)
        let backupPath = try firstAvailableBackupPath(unixTS: unixTS, fileManager: fileManager)
        try atomicWrite(originalData, to: backupPath, unixTS: unixTS)

        let updatedText = try updatedConfigText(originalText, recommendation: recommendation)
        guard let updatedData = updatedText.data(using: .utf8) else {
            throw ConfigApplierError.stringEncodingFailed(configPath.path)
        }
        try atomicWrite(updatedData, to: configPath, unixTS: unixTS)

        return AppliedConfig(
            backupPath: backupPath,
            summary: Self.summary(recommendation: recommendation, backupPath: backupPath)
        )
    }

    struct AppliedConfig {
        var backupPath: URL
        var summary: String
    }

    private func validateYAML(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        do {
            _ = try Yams.load(yaml: text)
        } catch {
            throw ConfigApplierError.invalidYAML(String(describing: error))
        }
    }

    private func firstAvailableBackupPath(
        unixTS: Int,
        fileManager: FileManager
    ) throws -> URL {
        guard maxBackupCounter >= 0 else {
            throw ConfigApplierError.backupCollisionsExhausted
        }
        for counter in 0...maxBackupCounter {
            let candidate = configPath.deletingLastPathComponent()
                .appendingPathComponent("\(configPath.lastPathComponent).bak-\(unixTS)-\(counter)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw ConfigApplierError.backupCollisionsExhausted
    }

    private func atomicWrite(_ data: Data, to destination: URL, unixTS: Int) throws {
        let tempURL = tempFileNamer(destination, unixTS)
        try data.write(to: tempURL, options: [])
        if rename(tempURL.path, destination.path) != 0 {
            let renameErrno = errno
            try? FileManager.default.removeItem(at: tempURL)
            throw ConfigApplierError.atomicRenameFailed(
                source: tempURL.path,
                destination: destination.path,
                errno: renameErrno
            )
        }
    }

    private func updatedConfigText(
        _ original: String,
        recommendation: RecommendationCore
    ) throws -> String {
        let values: [String: String?] = [
            "model": recommendation.model,
            "kv_bits": recommendation.knobs.kvBits.map(String.init),
            "max_context_override": String(recommendation.knobs.maxContext),
            "max_concurrency_override": String(recommendation.knobs.maxBatch),
        ]
        let ownedKeys = ["model", "kv_bits", "max_context_override", "max_concurrency_override"]

        if original.isEmpty {
            return renderOwnedConfig(values: values)
        }

        var seen = Set<String>()
        var output = ""
        original.enumerateSubstrings(in: original.startIndex..<original.endIndex, options: .byLines) {
            line, _, enclosingRange, _ in
            guard let line else {
                return
            }
            let rawLine = String(original[enclosingRange])
            guard let key = Self.ownedTopLevelKey(in: line, ownedKeys: ownedKeys) else {
                output += rawLine
                return
            }
            seen.insert(key)
            guard let value = values[key] ?? nil else {
                return
            }
            output += "\(key): \(value)\(Self.lineTerminator(from: rawLine))"
        }

        let missingLines = ownedKeys.compactMap { key -> String? in
            guard !seen.contains(key), let value = values[key] ?? nil else {
                return nil
            }
            return "\(key): \(value)"
        }
        guard !missingLines.isEmpty else {
            return output
        }
        if !output.isEmpty, !output.hasSuffix("\n"), !output.hasSuffix("\r\n") {
            output += "\n"
        }
        output += missingLines.joined(separator: "\n")
        output += "\n"
        return output
    }

    private func renderOwnedConfig(values: [String: String?]) -> String {
        var lines = [
            "model: \(values["model"]!!)",
            "max_context_override: \(values["max_context_override"]!!)",
            "max_concurrency_override: \(values["max_concurrency_override"]!!)",
        ]
        if let kvBits = values["kv_bits"] ?? nil {
            lines.insert("kv_bits: \(kvBits)", at: 1)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func ownedTopLevelKey(in line: String, ownedKeys: [String]) -> String? {
        guard line.first?.isWhitespace != true else {
            return nil
        }
        return ownedKeys.first { key in
            line == "\(key):" || line.hasPrefix("\(key): ")
        }
    }

    private static func lineTerminator(from rawLine: String) -> String {
        if rawLine.hasSuffix("\r\n") {
            return "\r\n"
        }
        if rawLine.hasSuffix("\n") {
            return "\n"
        }
        return ""
    }

    private static func summary(recommendation: RecommendationCore, backupPath: URL) -> String {
        let kvBits = recommendation.knobs.kvBits.map(String.init) ?? "unset"
        return "applied: model=\(recommendation.model) kv_bits=\(kvBits) max_concurrency_override=\(recommendation.knobs.maxBatch) max_context_override=\(recommendation.knobs.maxContext) (backup at \(backupPath.path))"
    }

    private static func defaultTempFileName(destination: URL, unixTS: Int) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).tmp.\(unixTS).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)")
    }
}
