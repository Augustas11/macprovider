import Darwin
import CryptoKit
import Foundation
import MacProviderCore
import Yams

enum ConfigApplierError: Error, Equatable, CustomStringConvertible {
    case backupCollisionsExhausted
    case invalidYAML(String)
    case atomicRenameFailed(source: String, destination: String, errno: Int32)
    case atomicWriteFailed(destination: String, errno: Int32)
    case backupWriteFailed(destination: String, errno: Int32)
    case configReadFailed(String)
    case unsafeConfigPath(String)
    case stringEncodingFailed(String)

    var description: String {
        switch self {
        case .backupCollisionsExhausted:
            return "backup collisions exhausted"
        case .invalidYAML(let message):
            return "invalid YAML: \(message)"
        case .atomicRenameFailed(let source, let destination, let errno):
            return "atomic rename failed from \(source) to \(destination): errno \(errno)"
        case .atomicWriteFailed(let destination, let errno):
            return "atomic write failed for \(destination): errno \(errno)"
        case .backupWriteFailed(let destination, let errno):
            return "backup write failed for \(destination): errno \(errno)"
        case .configReadFailed(let path):
            return "failed to read config at \(path)"
        case .unsafeConfigPath(let path):
            return "unsafe config path at \(path)"
        case .stringEncodingFailed(let path):
            return "failed to encode YAML for \(path)"
        }
    }
}

struct ConfigApplier {
    let configPath: URL
    let maxBackupCounter: Int
    let tempFileNamer: (URL, Int) -> URL
    let readData: (URL) throws -> Data

    init(
        configPath: URL,
        maxBackupCounter: Int = 65_535,
        tempFileNamer: @escaping (URL, Int) -> URL = ConfigApplier.defaultTempFileName,
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.configPath = configPath.standardizedFileURL.resolvingSymlinksInPath()
        self.maxBackupCounter = maxBackupCounter
        self.tempFileNamer = tempFileNamer
        self.readData = readData
    }

    func apply(
        recommendation: RecommendationCore,
        now: Date,
        donorMode: Bool = false,
        beforeMutation: ((_ originalOwnedValues: [String: String], _ targetOwnedValues: [String: String], _ backupPath: URL, _ preApplySHA256: String, _ postApplySHA256: String) throws -> Void)? = nil
    ) throws -> AppliedConfig {
        let fileManager = FileManager.default
        let directory = configPath.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try validateConfigPathSafety()
        return try ProviderConfigMutationLock.withExclusiveLock(configPath: configPath.path) {
            let originalData = try readConfigDataAllowingMissing()
            let originalText = String(decoding: originalData, as: UTF8.self)
            try validateYAML(originalText)

            let unixTS = Int(now.timeIntervalSince1970)
            // Autotune backups are model/config rollback artifacts, never
            // credential stores. The live file retains its compatibility token
            // until admission-gated cleanup; durable `.bak-*` copies omit it.
            let backupText = ProviderTokenPersist.removingProviderTokenLines(in: originalText)
            let backupPath = try writeBackupExclusively(Data(backupText.utf8), unixTS: unixTS)

            let updatedText = try updatedConfigText(originalText, recommendation: recommendation, donorMode: donorMode)
            try validateYAML(updatedText)
            guard let updatedData = updatedText.data(using: .utf8) else {
                throw ConfigApplierError.stringEncodingFailed(configPath.path)
            }
            try beforeMutation?(
                Self.extractOwnedValues(from: originalText),
                Self.extractOwnedValues(from: updatedText),
                backupPath,
                Self.sha256Hex(originalData),
                Self.sha256Hex(updatedData)
            )
            try atomicWrite(updatedData, to: configPath, unixTS: unixTS)

            return AppliedConfig(
                backupPath: backupPath,
                summary: Self.summary(recommendation: recommendation, backupPath: backupPath, donorMode: donorMode)
            )
        }
    }

    @discardableResult
    func restoreRecommendationOwnedFields(from backupPath: URL, now: Date) throws -> [String: String] {
        let backupText = try String(contentsOf: backupPath, encoding: .utf8)
        try validateYAML(backupText)
        let restoreValues = Self.extractOwnedValues(from: backupText)
        try validateConfigPathSafety()
        try ProviderConfigMutationLock.withExclusiveLock(configPath: configPath.path) {
            let originalData = try readConfigDataAllowingMissing()
            let originalText = String(decoding: originalData, as: UTF8.self)
            try validateYAML(originalText)
            let restoredText = try replacingOwnedFields(in: originalText, with: restoreValues)
            guard let restoredData = restoredText.data(using: .utf8) else {
                throw ConfigApplierError.stringEncodingFailed(configPath.path)
            }
            try atomicWrite(restoredData, to: configPath, unixTS: Int(now.timeIntervalSince1970))
        }
        return restoreValues
    }

    func recommendationOwnedFieldValues() throws -> [String: String] {
        try validateConfigPathSafety()
        let text = String(decoding: try readConfigDataAllowingMissing(), as: UTF8.self)
        try validateYAML(text)
        return Self.extractOwnedValues(from: text)
    }

    @discardableResult
    func restoreRecommendationOwnedFields(_ values: [String: String], now: Date) throws -> [String: String] {
        try validateConfigPathSafety()
        try ProviderConfigMutationLock.withExclusiveLock(configPath: configPath.path) {
            let originalData = try readConfigDataAllowingMissing()
            let originalText = String(decoding: originalData, as: UTF8.self)
            try validateYAML(originalText)
            let restoredText = try replacingOwnedFields(in: originalText, with: values)
            try validateYAML(restoredText)
            guard let restoredData = restoredText.data(using: .utf8) else {
                throw ConfigApplierError.stringEncodingFailed(configPath.path)
            }
            try atomicWrite(restoredData, to: configPath, unixTS: Int(now.timeIntervalSince1970))
        }
        return values
    }

    struct AppliedConfig {
        var backupPath: URL
        var summary: String
    }

    struct RecommendationOwnedSnapshot {
        let values: [String: String]
        let configSHA256: String
    }

    /// A capability that is valid only while `withExclusiveRecommendationMutation`
    /// holds the shared provider-config lock. Recovery uses this to keep its
    /// snapshot, decision, restore, verification, and journal commit in one
    /// cross-process transaction.
    struct LockedRecommendationMutation {
        fileprivate let applier: ConfigApplier

        func snapshot() throws -> RecommendationOwnedSnapshot {
            try applier.validateConfigPathSafety()
            let data = try applier.readConfigDataAllowingMissing()
            let text = String(decoding: data, as: UTF8.self)
            try applier.validateYAML(text)
            return RecommendationOwnedSnapshot(
                values: ConfigApplier.extractOwnedValues(from: text),
                configSHA256: ConfigApplier.sha256Hex(data)
            )
        }

        @discardableResult
        func restore(_ values: [String: String], now: Date) throws -> [String: String] {
            try applier.validateConfigPathSafety()
            let originalData = try applier.readConfigDataAllowingMissing()
            let originalText = String(decoding: originalData, as: UTF8.self)
            try applier.validateYAML(originalText)
            let restoredText = try applier.replacingOwnedFields(in: originalText, with: values)
            try applier.validateYAML(restoredText)
            guard let restoredData = restoredText.data(using: .utf8) else {
                throw ConfigApplierError.stringEncodingFailed(applier.configPath.path)
            }
            try applier.atomicWrite(
                restoredData,
                to: applier.configPath,
                unixTS: Int(now.timeIntervalSince1970)
            )
            return values
        }
    }

    func withExclusiveRecommendationMutation<T>(
        _ body: (LockedRecommendationMutation) throws -> T
    ) throws -> T {
        let handle = try acquireRecommendationMutationLock()
        defer { withExtendedLifetime(handle) {} }
        return try withLockedRecommendationMutation(handle, body)
    }

    func acquireRecommendationMutationLock(
        timeoutSeconds: TimeInterval? = nil
    ) throws -> ProviderConfigMutationLock.Handle {
        try ProviderConfigMutationLock.acquireExclusive(
            configPath: configPath.path,
            timeoutSeconds: timeoutSeconds
        )
    }

    func withLockedRecommendationMutation<T>(
        _ handle: ProviderConfigMutationLock.Handle,
        _ body: (LockedRecommendationMutation) throws -> T
    ) throws -> T {
        guard handle.configPath == configPath.path else {
            throw ConfigApplierError.unsafeConfigPath(configPath.path)
        }
        try validateConfigPathSafety()
        return try body(LockedRecommendationMutation(applier: self))
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

    private func validateConfigPathSafety() throws {
        var info = stat()
        if lstat(configPath.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(),
                  info.st_nlink == 1 else {
                throw ConfigApplierError.unsafeConfigPath(configPath.path)
            }
            return
        }
        guard errno == ENOENT else {
            throw ConfigApplierError.configReadFailed(configPath.path)
        }
    }

    private func readConfigDataAllowingMissing() throws -> Data {
        do {
            return try readData(configPath)
        } catch {
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain,
               cocoa.code == NSFileReadNoSuchFileError {
                return Data()
            }
            throw ConfigApplierError.configReadFailed(configPath.path)
        }
    }

    private func writeBackupExclusively(_ data: Data, unixTS: Int) throws -> URL {
        guard maxBackupCounter >= 0 else {
            throw ConfigApplierError.backupCollisionsExhausted
        }
        let directory = configPath.deletingLastPathComponent()
        for counter in 0...maxBackupCounter {
            let candidate = directory
                .appendingPathComponent("\(configPath.lastPathComponent).bak-\(unixTS)-\(counter)")
            let fd = candidate.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600) }
            if fd >= 0 {
                defer { _ = close(fd) }
                try writeAll(fd: fd, data: data, destination: candidate.path)
                guard fsync(fd) == 0 else {
                    throw ConfigApplierError.backupWriteFailed(destination: candidate.path, errno: errno)
                }
                try syncDirectory(directory)
                return candidate
            }
            let openErrno = errno
            if openErrno != EEXIST {
                throw ConfigApplierError.backupWriteFailed(
                    destination: candidate.path,
                    errno: openErrno
                )
            }
        }
        throw ConfigApplierError.backupCollisionsExhausted
    }

    private func writeAll(fd: Int32, data: Data, destination: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            var written = 0
            while written < data.count {
                let n = write(fd, base.advanced(by: written), data.count - written)
                if n < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ConfigApplierError.backupWriteFailed(
                        destination: destination,
                        errno: errno
                    )
                }
                written += n
            }
        }
    }

    private func atomicWrite(_ data: Data, to destination: URL, unixTS: Int) throws {
        let tempURL = tempFileNamer(destination, unixTS)
        let fd = tempURL.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else {
            throw ConfigApplierError.backupWriteFailed(destination: tempURL.path, errno: errno)
        }
        var descriptorOpen = true
        do {
            try writeAll(fd: fd, data: data, destination: tempURL.path)
            guard fsync(fd) == 0 else {
                throw ConfigApplierError.atomicWriteFailed(destination: tempURL.path, errno: errno)
            }
            guard close(fd) == 0 else {
                descriptorOpen = false
                throw ConfigApplierError.atomicWriteFailed(destination: tempURL.path, errno: errno)
            }
            descriptorOpen = false
            if rename(tempURL.path, destination.path) != 0 {
                let renameErrno = errno
                throw ConfigApplierError.atomicRenameFailed(
                    source: tempURL.path,
                    destination: destination.path,
                    errno: renameErrno
                )
            }
            try syncDirectory(destination.deletingLastPathComponent())
        } catch {
            if descriptorOpen {
                _ = close(fd)
            }
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private func syncDirectory(_ directory: URL) throws {
        let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard fd >= 0 else {
            throw ConfigApplierError.atomicWriteFailed(destination: directory.path, errno: errno)
        }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else {
            throw ConfigApplierError.atomicWriteFailed(destination: directory.path, errno: errno)
        }
    }

    private func updatedConfigText(
        _ original: String,
        recommendation: RecommendationCore,
        donorMode: Bool
    ) throws -> String {
        let values: [String: String?] = [
            "model": Self.yamlScalar(recommendation.model),
            "model_artifact_path": recommendation.modelArtifactPath.map(Self.yamlScalar),
            "model_artifact_sha256": recommendation.modelArtifactSHA256.map(Self.yamlScalar),
            "model_catalog_key": recommendation.modelCatalogKey.map(Self.yamlScalar),
            "model_catalog_model_id": recommendation.modelCatalogModelID.map(Self.yamlScalar),
            "model_catalog_revision": recommendation.modelCatalogRevision.map(Self.yamlScalar),
            "model_catalog_sha256": recommendation.modelCatalogSHA256.map(Self.yamlScalar),
            "model_catalog_version": recommendation.modelCatalogVersion.map(Self.yamlScalar),
            "model_catalog_hash": recommendation.modelCatalogHash.map(Self.yamlScalar),
            "kv_bits": recommendation.knobs.kvBits.map(String.init),
            "max_context_override": String(recommendation.knobs.maxContext),
            "max_concurrency_override": String(recommendation.knobs.maxBatch),
            "donor_mode": donorMode ? "true" : nil,
        ]
        let ownedKeys = Self.recommendationOwnedKeys

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

    private func replacingOwnedFields(in original: String, with values: [String: String]) throws -> String {
        if original.isEmpty {
            return values.keys.sorted().map { "\($0): \(values[$0]!)" }.joined(separator: "\n") + "\n"
        }
        var seen = Set<String>()
        var output = ""
        original.enumerateSubstrings(in: original.startIndex..<original.endIndex, options: .byLines) {
            line, _, enclosingRange, _ in
            guard let line else { return }
            let rawLine = String(original[enclosingRange])
            guard let key = Self.ownedTopLevelKey(in: line, ownedKeys: Self.recommendationOwnedKeys) else {
                output += rawLine
                return
            }
            seen.insert(key)
            guard let value = values[key] else { return }
            output += "\(key): \(value)\(Self.lineTerminator(from: rawLine))"
        }
        let missing = Self.recommendationOwnedKeys.compactMap { key -> String? in
            guard !seen.contains(key), let value = values[key] else { return nil }
            return "\(key): \(value)"
        }
        if !missing.isEmpty {
            if !output.isEmpty, !output.hasSuffix("\n"), !output.hasSuffix("\r\n") {
                output += "\n"
            }
            output += missing.joined(separator: "\n")
            output += "\n"
        }
        return output
    }

    static let recommendationOwnedKeys = [
        "model",
        "model_artifact_path",
        "model_artifact_sha256",
        "model_catalog_key",
        "model_catalog_model_id",
        "model_catalog_revision",
        "model_catalog_sha256",
        "model_catalog_version",
        "model_catalog_hash",
        "kv_bits",
        "max_context_override",
        "max_concurrency_override",
        "donor_mode",
    ]

    private func renderOwnedConfig(values: [String: String?]) -> String {
        var lines = [
            "model: \(values["model"]!!)",
            "max_context_override: \(values["max_context_override"]!!)",
            "max_concurrency_override: \(values["max_concurrency_override"]!!)",
        ]
        if let artifactSHA = values["model_artifact_sha256"] ?? nil {
            lines.insert("model_artifact_sha256: \(artifactSHA)", at: 1)
        }
        if let artifactPath = values["model_artifact_path"] ?? nil {
            lines.insert("model_artifact_path: \(artifactPath)", at: 1)
        }
        for key in [
            "model_catalog_key",
            "model_catalog_model_id",
            "model_catalog_revision",
            "model_catalog_sha256",
            "model_catalog_version",
            "model_catalog_hash",
        ].reversed() {
            if let value = values[key] ?? nil {
                lines.insert("\(key): \(value)", at: 1)
            }
        }
        if let kvBits = values["kv_bits"] ?? nil {
            lines.insert("kv_bits: \(kvBits)", at: 1)
        }
        if let donorMode = values["donor_mode"] ?? nil {
            lines.append("donor_mode: \(donorMode)")
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

    private static func extractOwnedValues(from text: String) -> [String: String] {
        var values: [String: String] = [:]
        text.enumerateLines { line, _ in
            guard let key = ownedTopLevelKey(in: line, ownedKeys: recommendationOwnedKeys),
                  let colon = line.firstIndex(of: ":")
            else { return }
            values[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return values
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

    private static func yamlScalar(_ value: String) -> String {
        let plain = value.utf8.allSatisfy { byte in
            (0x61...0x7A).contains(byte)
                || (0x41...0x5A).contains(byte)
                || (0x30...0x39).contains(byte)
                || [0x2D, 0x5F, 0x2E, 0x2F].contains(byte)
        }
        guard !value.isEmpty, plain else {
            // Quote via JSON string encoding for values with spaces/specials
            // (e.g. a model artifact path under "…/Application Support/…").
            // withoutEscapingSlashes keeps forward slashes literal: an escaped
            // "\/Users\/…" is valid JSON but breaks install.sh's YAML read-back,
            // whose absolute-path check (`case "$p" in /*)`) then fails and the
            // installer wrongly concludes "no paid model cleared".
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let data = try? encoder.encode(value)
            return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }
        return value
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func summary(recommendation: RecommendationCore, backupPath: URL, donorMode: Bool) -> String {
        let kvBits = recommendation.knobs.kvBits.map(String.init) ?? "unset"
        let donorSuffix = donorMode ? " donor_mode=true" : ""
        return "applied: model=\(recommendation.model) kv_bits=\(kvBits) max_concurrency_override=\(recommendation.knobs.maxBatch) max_context_override=\(recommendation.knobs.maxContext)\(donorSuffix) (backup at \(backupPath.path))"
    }

    private static func defaultTempFileName(destination: URL, unixTS: Int) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).tmp.\(unixTS).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)")
    }
}
