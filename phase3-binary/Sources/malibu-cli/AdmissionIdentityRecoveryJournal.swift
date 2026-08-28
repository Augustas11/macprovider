import Darwin
import Foundation
import MacProviderCore

struct AdmissionIdentityRecoveryJournalRecord: Codable, Equatable, Sendable {
    static let contractVersion = 1

    let contractVersion: Int
    let providerID: String
    let candidatePublicKeySHA256: String
    let requestedUntil: String
    let reason: String
    let incidentID: String

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case providerID = "provider_id"
        case candidatePublicKeySHA256 = "candidate_public_key_sha256"
        case requestedUntil = "requested_until"
        case reason
        case incidentID = "incident_id"
    }

    init(
        providerID: String,
        candidatePublicKeySHA256: String,
        requestedUntil: Date,
        reason: String,
        incidentID: String
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.contractVersion = Self.contractVersion
        self.providerID = providerID
        self.candidatePublicKeySHA256 = candidatePublicKeySHA256
        self.requestedUntil = formatter.string(from: requestedUntil)
        self.reason = reason
        self.incidentID = incidentID
    }

    var requestedUntilDate: Date? {
        CredentialRestartProver.parseISO8601(requestedUntil)
    }

    func validate() throws {
        guard contractVersion == Self.contractVersion,
              !providerID.isEmpty, providerID.count <= 256,
              Self.isSHA256(candidatePublicKeySHA256),
              requestedUntilDate != nil,
              !reason.isEmpty, reason.count <= 1_024,
              !incidentID.isEmpty, incidentID.count <= 256 else {
            throw AdmissionIdentityRecoveryJournalError.invalidRecord
        }
    }

    func jsonObject(
        operation: String,
        state: String,
        publicKeySHA256: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "contract_version": Self.contractVersion,
            "operation": operation,
            "provider_id": providerID,
            "owner": "malibu_cli",
            "state": state,
            "candidate_public_key_sha256": candidatePublicKeySHA256,
            "restart_safe": true,
        ]
        if let publicKeySHA256 {
            payload["public_key_sha256"] = publicKeySHA256
        }
        if state != "committed" {
            payload["admin_request"] = [
                "method": "POST",
                "path": "/admin/provider-admission-identity/recover",
                "body": [
                    "provider_id": providerID,
                    "candidate_public_key_sha256": candidatePublicKeySHA256,
                    "requested_until": requestedUntil,
                    "reason": reason,
                    "incident_id": incidentID,
                ],
                "approval_path_template": "/admin/provider-admission-identity/recover/{pending_id}/approve",
            ]
        }
        switch state {
        case "approval_required":
            payload["next_action"] = "submit the exact admin request, obtain approval from a second operator, then activate the staged recovery"
        case "committed_cleanup":
            payload["next_action"] = "finalize the already committed local recovery journal"
        case "expired":
            payload["next_action"] = "stage a new bounded recovery request"
        default:
            break
        }
        return payload
    }

    func printJSON(
        operation: String,
        state: String,
        publicKeySHA256: String? = nil
    ) throws {
        var data = try JSONSerialization.data(
            withJSONObject: jsonObject(
                operation: operation,
                state: state,
                publicKeySHA256: publicKeySHA256
            ),
            options: [.sortedKeys]
        )
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character)
        }
    }
}

enum AdmissionIdentityRecoveryJournalError: Error, LocalizedError, Equatable {
    case missing
    case unavailable
    case insecureFile
    case tooLarge
    case invalidRecord
    case providerMismatch
    case candidateMismatch
    case expired

    var errorDescription: String? {
        switch self {
        case .missing:
            return "no staged admission identity recovery journal exists"
        case .unavailable:
            return "the admission identity recovery journal is unavailable"
        case .insecureFile:
            return "the admission identity recovery journal requires trusted owner-only storage"
        case .tooLarge:
            return "the admission identity recovery journal exceeds 64 KiB"
        case .invalidRecord:
            return "the admission identity recovery journal is invalid"
        case .providerMismatch:
            return "the admission identity recovery journal belongs to a different provider"
        case .candidateMismatch:
            return "the admission identity recovery journal does not match the staged Keychain candidate"
        case .expired:
            return "the staged admission identity recovery request has expired; stage a new request"
        }
    }
}

struct AdmissionIdentityRecoveryJournalStore: Sendable {
    static let fileName = ".admission-identity-recovery-v1.json"
    private static let maximumBytes = 64 * 1_024

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct JournalSnapshot {
        let record: AdmissionIdentityRecoveryJournalRecord
        let identity: FileIdentity
    }

    private let explicitURL: URL?

    init(url: URL? = nil) {
        self.explicitURL = url
    }

    func load(configPath: String) throws -> AdmissionIdentityRecoveryJournalRecord? {
        try withLock(configPath: configPath) {
            try readSnapshotIfPresent(from: journalURL(configPath: configPath))?.record
        }
    }

    func loadRequired(
        configPath: String,
        expectedProviderID: String,
        now: Date,
        allowExpired: Bool = false
    ) throws -> AdmissionIdentityRecoveryJournalRecord {
        guard let record = try load(configPath: configPath) else {
            throw AdmissionIdentityRecoveryJournalError.missing
        }
        guard record.providerID == expectedProviderID else {
            throw AdmissionIdentityRecoveryJournalError.providerMismatch
        }
        guard allowExpired || (record.requestedUntilDate?.timeIntervalSince(now) ?? -1) > 0 else {
            throw AdmissionIdentityRecoveryJournalError.expired
        }
        return record
    }

    func persistOrReuse(
        _ proposed: AdmissionIdentityRecoveryJournalRecord,
        configPath: String,
        now: Date
    ) throws -> AdmissionIdentityRecoveryJournalRecord {
        try proposed.validate()
        return try withLock(configPath: configPath) {
            let url = journalURL(configPath: configPath)
            let existing = try readSnapshotIfPresent(from: url)
            if let existingRecord = existing?.record {
                guard existingRecord.providerID == proposed.providerID else {
                    throw AdmissionIdentityRecoveryJournalError.providerMismatch
                }
                guard existingRecord.candidatePublicKeySHA256 == proposed.candidatePublicKeySHA256 else {
                    throw AdmissionIdentityRecoveryJournalError.candidateMismatch
                }
                if (existingRecord.requestedUntilDate?.timeIntervalSince(now) ?? -1) > 0 {
                    return existingRecord
                }
            }
            try writeUnlocked(proposed, to: url, replacing: existing?.identity)
            return proposed
        }
    }

    @discardableResult
    func clearIfMatches(
        _ expected: AdmissionIdentityRecoveryJournalRecord,
        configPath: String
    ) throws -> Bool {
        try withLock(configPath: configPath) {
            let url = journalURL(configPath: configPath)
            guard let current = try readSnapshotIfPresent(from: url) else { return false }
            guard current.record == expected else { return false }
            try validateTarget(url, matches: current.identity)
            guard unlink(url.path) == 0 else {
                if errno == ENOENT { return false }
                throw AdmissionIdentityRecoveryJournalError.unavailable
            }
            try syncDirectory(containing: url)
            return true
        }
    }

    private func journalURL(configPath: String) -> URL {
        if let explicitURL { return explicitURL }
        let resolved = ConfigLoader.expandTilde(configPath)
        return URL(fileURLWithPath: resolved)
            .deletingLastPathComponent()
            .appendingPathComponent(Self.fileName)
    }

    private func lockURL(configPath: String) -> URL {
        let journal = journalURL(configPath: configPath)
        return journal.deletingLastPathComponent()
            .appendingPathComponent(".\(journal.lastPathComponent).lock")
    }

    private func withLock<T>(configPath: String, operation: () throws -> T) throws -> T {
        let journal = journalURL(configPath: configPath)
        try validateTrustedDirectory(containing: journal)
        let url = lockURL(configPath: configPath)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw openError() }
        defer { close(descriptor) }
        _ = try validateOpenFile(descriptor, allowEmpty: true)
        try validatePath(url, matchesOpenFile: descriptor)
        var result: Int32
        repeat {
            result = flock(descriptor, LOCK_EX)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            throw AdmissionIdentityRecoveryJournalError.unavailable
        }
        defer { flock(descriptor, LOCK_UN) }
        try validatePath(url, matchesOpenFile: descriptor)
        return try operation()
    }

    private func readSnapshotIfPresent(from url: URL) throws -> JournalSnapshot? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw openError()
        }
        defer { close(descriptor) }
        let info = try validateOpenFile(descriptor, allowEmpty: false)
        try validatePath(url, matchesOpenFile: descriptor)
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw AdmissionIdentityRecoveryJournalError.unavailable }
            guard count > 0 else { break }
            guard data.count + count <= Self.maximumBytes else {
                throw AdmissionIdentityRecoveryJournalError.tooLarge
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        try validatePath(url, matchesOpenFile: descriptor)
        let record: AdmissionIdentityRecoveryJournalRecord
        do {
            record = try JSONDecoder().decode(AdmissionIdentityRecoveryJournalRecord.self, from: data)
        } catch {
            throw AdmissionIdentityRecoveryJournalError.invalidRecord
        }
        try record.validate()
        return JournalSnapshot(
            record: record,
            identity: FileIdentity(device: info.st_dev, inode: info.st_ino)
        )
    }

    private func writeUnlocked(
        _ record: AdmissionIdentityRecoveryJournalRecord,
        to url: URL,
        replacing expectedIdentity: FileIdentity?
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0a)
        guard data.count <= Self.maximumBytes else {
            throw AdmissionIdentityRecoveryJournalError.tooLarge
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString.lowercased())")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw openError() }
        var installed = false
        defer {
            close(descriptor)
            if !installed { _ = unlink(temporary.path) }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw AdmissionIdentityRecoveryJournalError.unavailable
        }
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw AdmissionIdentityRecoveryJournalError.unavailable
                }
                offset += written
            }
        }
        _ = try validateOpenFile(descriptor, allowEmpty: false)
        try validatePath(temporary, matchesOpenFile: descriptor)
        guard fsync(descriptor) == 0 else {
            throw AdmissionIdentityRecoveryJournalError.unavailable
        }
        try validateTarget(url, matches: expectedIdentity)
        guard rename(temporary.path, url.path) == 0 else {
            throw AdmissionIdentityRecoveryJournalError.unavailable
        }
        installed = true
        try validatePath(url, matchesOpenFile: descriptor)
        try syncDirectory(containing: url)
    }

    private func validateTrustedDirectory(containing url: URL) throws {
        let descriptor = try openTrustedDirectory(containing: url)
        close(descriptor)
    }

    private func openTrustedDirectory(containing url: URL) throws -> Int32 {
        let directory = url.deletingLastPathComponent()
        var named = stat()
        guard lstat(directory.path, &named) == 0 else {
            throw AdmissionIdentityRecoveryJournalError.unavailable
        }
        guard (named.st_mode & S_IFMT) == S_IFDIR,
              named.st_uid == geteuid(),
              (named.st_mode & 0o777) == S_IRWXU else {
            throw AdmissionIdentityRecoveryJournalError.insecureFile
        }
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw openError() }
        do {
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  (opened.st_mode & S_IFMT) == S_IFDIR,
                  opened.st_uid == geteuid(),
                  (opened.st_mode & 0o777) == S_IRWXU,
                  opened.st_dev == named.st_dev,
                  opened.st_ino == named.st_ino else {
                throw AdmissionIdentityRecoveryJournalError.insecureFile
            }
            try rejectExtendedACL(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validateOpenFile(
        _ descriptor: Int32,
        allowEmpty: Bool
    ) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AdmissionIdentityRecoveryJournalError.unavailable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == (S_IRUSR | S_IWUSR),
              info.st_nlink == 1 else {
            throw AdmissionIdentityRecoveryJournalError.insecureFile
        }
        try rejectExtendedACL(descriptor)
        guard info.st_size >= (allowEmpty ? 0 : 1) else {
            throw AdmissionIdentityRecoveryJournalError.invalidRecord
        }
        guard info.st_size <= Self.maximumBytes else {
            throw AdmissionIdentityRecoveryJournalError.tooLarge
        }
        return info
    }

    private func validateExistingPath(_ url: URL) throws -> FileIdentity? {
        var named = stat()
        guard lstat(url.path, &named) == 0 else {
            if errno == ENOENT { return nil }
            throw AdmissionIdentityRecoveryJournalError.unavailable
        }
        guard (named.st_mode & S_IFMT) == S_IFREG else {
            throw AdmissionIdentityRecoveryJournalError.insecureFile
        }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw openError() }
        defer { close(descriptor) }
        let opened = try validateOpenFile(descriptor, allowEmpty: false)
        try validatePath(url, matchesOpenFile: descriptor)
        return FileIdentity(device: opened.st_dev, inode: opened.st_ino)
    }

    private func validateTarget(_ url: URL, matches expected: FileIdentity?) throws {
        guard try validateExistingPath(url) == expected else {
            throw AdmissionIdentityRecoveryJournalError.insecureFile
        }
    }

    private func validatePath(_ url: URL, matchesOpenFile descriptor: Int32) throws {
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            throw AdmissionIdentityRecoveryJournalError.unavailable
        }
        var named = stat()
        guard lstat(url.path, &named) == 0,
              (named.st_mode & S_IFMT) == S_IFREG,
              named.st_dev == opened.st_dev,
              named.st_ino == opened.st_ino else {
            throw AdmissionIdentityRecoveryJournalError.insecureFile
        }
    }

    private func syncDirectory(containing url: URL) throws {
        let descriptor = try openTrustedDirectory(containing: url)
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw AdmissionIdentityRecoveryJournalError.unavailable
        }
    }

    private func rejectExtendedACL(_ descriptor: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == 0 || errno == ENOENT { return }
            throw AdmissionIdentityRecoveryJournalError.unavailable
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0 else {
            throw AdmissionIdentityRecoveryJournalError.unavailable
        }
        guard entry == nil else {
            throw AdmissionIdentityRecoveryJournalError.insecureFile
        }
    }

    private func openError() -> AdmissionIdentityRecoveryJournalError {
        errno == ELOOP ? .insecureFile : .unavailable
    }
}
