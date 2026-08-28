import CryptoKit
import Darwin
import Foundation

enum RecommendationAdoptionJournalError: Error, Equatable {
    case busy
    case invalidJournal
    case ioFailure
}

struct RecommendationAdoptionJournalRecord: Codable, Equatable {
    enum Phase: String, Codable {
        case configPrepared = "config_prepared"
        case switchIssued = "switch_issued"
        case runtimeCommitted = "runtime_committed"
        case finalizePending = "finalize_pending"
        case cancelPending = "cancel_pending"
    }

    enum RollbackState: String, Codable {
        case notNeeded = "not_needed"
        case pending
        case rolledBack = "rolled_back"
        case rollbackFailed = "rollback_failed"
    }

    let schemaVersion: String
    let transactionID: String
    var phase: Phase
    let fromModelID: String
    let targetModelID: String
    let recommendationSHA256: String
    let configPath: String
    let preApplyConfigSHA256: String
    let postApplyConfigSHA256: String
    let redactedBackupPath: String
    let recommendationOwnedFieldsBefore: [String: String]
    let recommendationOwnedFieldsAfter: [String: String]
    var runtimeCommitObserved: Bool
    var rollbackState: RollbackState
    var updatedAt: Date

    init(
        transactionID: String,
        fromModelID: String,
        targetModelID: String,
        recommendationSHA256: String,
        configPath: String,
        preApplyConfigSHA256: String,
        postApplyConfigSHA256: String,
        redactedBackupPath: String,
        recommendationOwnedFieldsBefore: [String: String],
        recommendationOwnedFieldsAfter: [String: String],
        now: Date
    ) {
        schemaVersion = "model_adoption_transaction.v1"
        self.transactionID = transactionID
        phase = .configPrepared
        self.fromModelID = fromModelID
        self.targetModelID = targetModelID
        self.recommendationSHA256 = recommendationSHA256
        self.configPath = configPath
        self.preApplyConfigSHA256 = preApplyConfigSHA256
        self.postApplyConfigSHA256 = postApplyConfigSHA256
        self.redactedBackupPath = redactedBackupPath
        self.recommendationOwnedFieldsBefore = recommendationOwnedFieldsBefore
        self.recommendationOwnedFieldsAfter = recommendationOwnedFieldsAfter
        runtimeCommitObserved = false
        rollbackState = .pending
        updatedAt = now
    }

    func validated() throws -> Self {
        guard schemaVersion == "model_adoption_transaction.v1",
              UUID(uuidString: transactionID) != nil,
              ModelSwitchingWireCodec.safeID(fromModelID),
              ModelSwitchingWireCodec.safeID(targetModelID),
              Self.isLowerHex(recommendationSHA256),
              Self.isLowerHex(preApplyConfigSHA256),
              Self.isLowerHex(postApplyConfigSHA256),
              configPath.hasPrefix("/"),
              redactedBackupPath == "redacted",
              Set(recommendationOwnedFieldsBefore.keys).isSubset(of: Set(ConfigApplier.recommendationOwnedKeys)),
              Set(recommendationOwnedFieldsAfter.keys).isSubset(of: Set(ConfigApplier.recommendationOwnedKeys)) else {
            throw RecommendationAdoptionJournalError.invalidJournal
        }
        return self
    }

    private static func isLowerHex(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }
}

final class RecommendationAdoptionLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    static func acquire(configPath: URL, root: URL = RecommendationAdoptionJournalStore.defaultRoot) throws -> RecommendationAdoptionLock {
        try RecommendationAdoptionJournalStore.secureDirectory(root)
        let canonicalConfigPath = configPath.standardizedFileURL.resolvingSymlinksInPath()
        let digest = SHA256.hash(data: Data(canonicalConfigPath.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let path = root.appendingPathComponent(".lock-\(digest)").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RecommendationAdoptionJournalError.ioFailure }
        guard fchmod(descriptor, 0o600) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            throw RecommendationAdoptionJournalError.busy
        }
        return RecommendationAdoptionLock(descriptor: descriptor)
    }
}

struct RecommendationAdoptionJournalStore {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/macprovider/model-adoption-transactions", isDirectory: true)

    let root: URL

    init(root: URL = Self.defaultRoot) {
        self.root = root
    }

    func write(_ record: RecommendationAdoptionJournalRecord) throws {
        _ = try record.validated()
        try Self.secureDirectory(root)
        var data = try JSONEncoder.journal.encode(record)
        data.append(0x0A)
        let destination = url(transactionID: record.transactionID)
        let temp = root.appendingPathComponent(".tmp-\(record.transactionID)-\(UUID().uuidString.lowercased())")
        let descriptor = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RecommendationAdoptionJournalError.ioFailure }
        var descriptorOpen = true
        do {
            try Self.writeAll(data, descriptor: descriptor)
            guard fsync(descriptor) == 0 else { throw RecommendationAdoptionJournalError.ioFailure }
            guard close(descriptor) == 0 else {
                descriptorOpen = false
                throw RecommendationAdoptionJournalError.ioFailure
            }
            descriptorOpen = false
            guard rename(temp.path, destination.path) == 0 else {
                throw RecommendationAdoptionJournalError.ioFailure
            }
            try Self.syncDirectory(root)
        } catch {
            if descriptorOpen {
                _ = close(descriptor)
            }
            _ = unlink(temp.path)
            throw error
        }
    }

    func records(for configPath: URL) throws -> [(URL, RecommendationAdoptionJournalRecord)] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try Self.secureDirectory(root)
        let canonical = configPath.standardizedFileURL.path
        let candidates = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        guard candidates.count <= 1_024 else {
            throw RecommendationAdoptionJournalError.invalidJournal
        }
        let matching = try candidates.compactMap { url in
            let record = try load(url)
            return record.configPath == canonical ? (url, record) : nil
        }
        guard matching.count <= 64 else {
            throw RecommendationAdoptionJournalError.invalidJournal
        }
        return matching.sorted { $0.1.updatedAt < $1.1.updatedAt }
    }

    func remove(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              url.pathExtension == "json" else {
            throw RecommendationAdoptionJournalError.invalidJournal
        }
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw RecommendationAdoptionJournalError.ioFailure
        }
        try Self.syncDirectory(root)
    }

    func url(transactionID: String) -> URL {
        root.appendingPathComponent("\(transactionID).json")
    }

    private func load(_ url: URL) throws -> RecommendationAdoptionJournalRecord {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RecommendationAdoptionJournalError.invalidJournal
        }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_mode & (S_IRWXG | S_IRWXO) == 0,
              info.st_size > 0,
              info.st_size <= 65_536 else {
            throw RecommendationAdoptionJournalError.invalidJournal
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            RecommendationAdoptionJournalRecord.self,
            from: Self.readAll(descriptor: descriptor, count: Int(info.st_size))
        ).validated()
    }

    private static func readAll(descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        let bytesRead = try data.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var offset = 0
            while offset < count {
                let result = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw RecommendationAdoptionJournalError.ioFailure
                }
                if result == 0 { break }
                offset += result
            }
            return offset
        }
        guard bytesRead == count else {
            throw RecommendationAdoptionJournalError.invalidJournal
        }
        return data
    }

    static func secureDirectory(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var info = stat()
        guard lstat(root.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              chmod(root.path, 0o700) == 0 else {
            throw RecommendationAdoptionJournalError.ioFailure
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw RecommendationAdoptionJournalError.ioFailure
                }
                offset += count
            }
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RecommendationAdoptionJournalError.ioFailure }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw RecommendationAdoptionJournalError.ioFailure }
    }
}

private extension JSONEncoder {
    static let journal: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
