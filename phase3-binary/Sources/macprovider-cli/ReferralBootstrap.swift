import CryptoKit
import Darwin
import Foundation

struct ReferralBootstrapFailure: Error, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case required = "referral_required"
        case invalid = "referral_invalid"
        case expired = "referral_expired"
        case revoked = "referral_revoked"
        case exhausted = "referral_exhausted"
        case conflict = "referral_conflict"
        case rateLimited = "referral_rate_limited"
        case unavailable = "referral_unavailable"
    }

    let kind: Kind

    var exitCode: Int32 {
        switch kind {
        case .required: 20
        case .invalid: 21
        case .expired: 22
        case .revoked: 23
        case .exhausted: 24
        case .conflict: 25
        case .rateLimited: 26
        case .unavailable: 27
        }
    }

    static func coordinatorCode(_ code: String) -> ReferralBootstrapFailure? {
        switch code.lowercased() {
        case "referral_required": ReferralBootstrapFailure(kind: .required)
        case "referral_invalid": ReferralBootstrapFailure(kind: .invalid)
        case "referral_expired": ReferralBootstrapFailure(kind: .expired)
        case "referral_revoked": ReferralBootstrapFailure(kind: .revoked)
        case "referral_exhausted": ReferralBootstrapFailure(kind: .exhausted)
        case "referral_conflict": ReferralBootstrapFailure(kind: .conflict)
        case "credential_bootstrap_rate_limited": ReferralBootstrapFailure(kind: .rateLimited)
        default: nil
        }
    }
}

struct ReferralCodeInput: Equatable, Sendable {
    let code: String
    let digestSHA256: String
    let sourceFileSHA256: String
    let path: String
    let fileIdentity: ReferralFileIdentity
}

struct ReferralFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        modifiedSeconds = Int(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int(value.st_mtimespec.tv_nsec)
        changedSeconds = Int(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int(value.st_ctimespec.tv_nsec)
    }
}

enum ReferralCodeFile {
    static let maximumBytes = 256

    static func read(path: String) throws -> ReferralCodeInput {
        var pathStat = stat()
        guard lstat(path, &pathStat) == 0 else {
            throw ReferralBootstrapFailure(kind: errno == ENOENT ? .required : .unavailable)
        }
        try validate(pathStat)

        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ReferralBootstrapFailure(kind: errno == ELOOP ? .invalid : .unavailable)
        }
        defer { _ = close(descriptor) }

        var openStat = stat()
        guard fstat(descriptor, &openStat) == 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        try validate(openStat)
        try validateNoExtendedACL(descriptor)
        guard pathStat.st_dev == openStat.st_dev, pathStat.st_ino == openStat.st_ino else {
            throw ReferralBootstrapFailure(kind: .invalid)
        }
        let initialIdentity = ReferralFileIdentity(openStat)

        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        var count = 0
        while count < bytes.count {
            let remaining = bytes.count - count
            let received = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, base.advanced(by: count), remaining)
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw ReferralBootstrapFailure(kind: .unavailable)
            }
            if received == 0 { break }
            count += received
        }
        guard count > 0, count <= maximumBytes else {
            throw ReferralBootstrapFailure(kind: .invalid)
        }
        let raw = Data(bytes.prefix(count))
        guard var code = String(data: raw, encoding: .utf8) else {
            throw ReferralBootstrapFailure(kind: .invalid)
        }
        code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty,
              code.utf8.count <= maximumBytes,
              code.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
            throw ReferralBootstrapFailure(kind: .invalid)
        }
        var finalStat = stat()
        guard fstat(descriptor, &finalStat) == 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        try validate(finalStat)
        try validateNoExtendedACL(descriptor)
        guard ReferralFileIdentity(finalStat) == initialIdentity else {
            throw ReferralBootstrapFailure(kind: .invalid)
        }
        return ReferralCodeInput(
            code: code,
            digestSHA256: sha256Hex(Data(code.utf8)),
            sourceFileSHA256: sha256Hex(raw),
            path: path,
            fileIdentity: ReferralFileIdentity(openStat)
        )
    }

    static func removeIfUnchanged(_ input: ReferralCodeInput) throws {
        var pathStat = stat()
        guard lstat(input.path, &pathStat) == 0 else {
            if errno == ENOENT { return }
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        try validate(pathStat)
        guard ReferralFileIdentity(pathStat) == input.fileIdentity else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }

        let descriptor = open(input.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        defer { _ = close(descriptor) }
        var openStat = stat()
        guard fstat(descriptor, &openStat) == 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        try validate(openStat)
        try validateNoExtendedACL(descriptor)
        guard ReferralFileIdentity(openStat) == input.fileIdentity else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: maximumBytes + 1)
        while data.count <= maximumBytes {
            let received = Darwin.read(descriptor, &buffer, buffer.count)
            if received < 0 {
                if errno == EINTR { continue }
                throw ReferralBootstrapFailure(kind: .unavailable)
            }
            if received == 0 { break }
            data.append(contentsOf: buffer.prefix(received))
        }
        var finalOpenStat = stat()
        guard !data.isEmpty,
              data.count <= maximumBytes,
              sha256Hex(data) == input.sourceFileSHA256,
              fstat(descriptor, &finalOpenStat) == 0,
              ReferralFileIdentity(finalOpenStat) == input.fileIdentity else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        var finalPathStat = stat()
        guard lstat(input.path, &finalPathStat) == 0,
              ReferralFileIdentity(finalPathStat) == input.fileIdentity else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        guard unlink(input.path) == 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
    }

    private static func validate(_ value: stat) throws {
        guard (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == geteuid(),
              (value.st_mode & 0o777) == 0o600,
              value.st_nlink == 1,
              value.st_size >= 0,
              value.st_size <= maximumBytes else {
            throw ReferralBootstrapFailure(kind: .invalid)
        }
    }

    fileprivate static func validateNoExtendedACL(_ descriptor: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == 0 || errno == ENOENT else {
                throw ReferralBootstrapFailure(kind: .unavailable)
            }
            return
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        guard result == 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        guard entry == nil else { throw ReferralBootstrapFailure(kind: .invalid) }
    }
}

struct ReferralBootstrapAttempt: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case pending
        case terminal
        case committed
    }

    let version: Int
    let attemptID: String
    let providerID: String
    let receiptPublicKeySHA256: String
    let referralCodeSHA256: String
    let createdAt: String
    var updatedAt: String
    var state: State
    var terminalCode: String?
}

enum ReferralBootstrapReconciliation: Equatable, Sendable {
    case committedPendingAttempt
    case alreadyCommitted
}

struct ReferralBootstrapJournal: Sendable {
    let url: URL

    static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".config/macprovider/onboarding", isDirectory: true)
            .appendingPathComponent("referral-attempt-v1.json", isDirectory: false)
    }

    static func replacementJournal(
        providerID: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ReferralBootstrapJournal {
        ReferralBootstrapJournal(
            url: home.appendingPathComponent(".config/macprovider/onboarding", isDirectory: true)
                .appendingPathComponent("referral-attempt-v1.replacement-\(providerID).json", isDirectory: false)
        )
    }

    func prepare(
        providerID: String,
        receiptPublicKey: String,
        input: ReferralCodeInput,
        now: Date = Date()
    ) throws -> ReferralBootstrapAttempt {
        try withLock {
            let receiptDigest = sha256Hex(Data(receiptPublicKey.utf8))
            let attemptID = sha256Hex(Data(
                "referral-bootstrap/v1\0\(providerID)\0\(receiptDigest)\0\(input.digestSHA256)".utf8
            ))
            if var existing = try loadUnlocked() {
                let sameBinding = existing.providerID == providerID
                    && existing.receiptPublicKeySHA256 == receiptDigest
                    && existing.referralCodeSHA256 == input.digestSHA256
                if sameBinding {
                    if existing.state == .committed {
                        throw ReferralBootstrapFailure(kind: .conflict)
                    }
                    existing.state = .pending
                    existing.terminalCode = nil
                    existing.updatedAt = Self.timestamp(now)
                    try persistUnlocked(existing)
                    return existing
                }
                guard existing.state == .terminal else {
                    throw ReferralBootstrapFailure(kind: .conflict)
                }
            }
            let timestamp = Self.timestamp(now)
            let attempt = ReferralBootstrapAttempt(
                version: 1,
                attemptID: attemptID,
                providerID: providerID,
                receiptPublicKeySHA256: receiptDigest,
                referralCodeSHA256: input.digestSHA256,
                createdAt: timestamp,
                updatedAt: timestamp,
                state: .pending,
                terminalCode: nil
            )
            try persistUnlocked(attempt)
            return attempt
        }
    }

    func markTerminal(attemptID: String, failure: ReferralBootstrapFailure, now: Date = Date()) throws {
        try update(attemptID: attemptID, state: .terminal, terminalCode: failure.kind.rawValue, now: now)
    }

    func markCommitted(attemptID: String, now: Date = Date()) throws {
        try update(attemptID: attemptID, state: .committed, terminalCode: nil, now: now)
    }

    func reconcilePersistedCredential(
        providerID: String,
        receiptPublicKey: String,
        input: ReferralCodeInput,
        now: Date = Date()
    ) throws -> ReferralBootstrapReconciliation? {
        try withLock {
            let receiptDigest = sha256Hex(Data(receiptPublicKey.utf8))
            guard var attempt = try loadUnlocked(),
                  attempt.providerID == providerID,
                  attempt.receiptPublicKeySHA256 == receiptDigest,
                  attempt.referralCodeSHA256 == input.digestSHA256,
                  attempt.state == .pending || attempt.state == .committed else {
                return nil
            }
            if attempt.state == .committed {
                return .alreadyCommitted
            }
            attempt.state = .committed
            attempt.terminalCode = nil
            attempt.updatedAt = Self.timestamp(now)
            try persistUnlocked(attempt)
            return .committedPendingAttempt
        }
    }

    func load() throws -> ReferralBootstrapAttempt? {
        try withLock { try loadUnlocked() }
    }

    private func update(
        attemptID: String,
        state: ReferralBootstrapAttempt.State,
        terminalCode: String?,
        now: Date
    ) throws {
        try withLock {
            guard var attempt = try loadUnlocked(), attempt.attemptID == attemptID else {
                throw ReferralBootstrapFailure(kind: .conflict)
            }
            attempt.state = state
            attempt.terminalCode = terminalCode
            attempt.updatedAt = Self.timestamp(now)
            try persistUnlocked(attempt)
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try ensureJournalDirectory()
        let lockPath = url.path + ".lock"
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        defer { _ = close(descriptor) }
        var lockStat = stat()
        guard fstat(descriptor, &lockStat) == 0,
              (lockStat.st_mode & S_IFMT) == S_IFREG,
              lockStat.st_uid == geteuid(),
              (lockStat.st_mode & 0o777) == 0o600,
              lockStat.st_nlink == 1,
              flock(descriptor, LOCK_EX) == 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        try ReferralCodeFile.validateNoExtendedACL(descriptor)
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func ensureJournalDirectory() throws {
        let path = url.deletingLastPathComponent().path
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & 0o077) == 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        try ReferralCodeFile.validateNoExtendedACL(descriptor)
    }

    private func loadUnlocked() throws -> ReferralBootstrapAttempt? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        guard (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == geteuid(),
              (value.st_mode & 0o777) == 0o600,
              value.st_nlink == 1,
              value.st_size >= 0,
              value.st_size <= 16_384 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        defer { _ = close(descriptor) }
        var openValue = stat()
        guard fstat(descriptor, &openValue) == 0,
              (openValue.st_mode & S_IFMT) == S_IFREG,
              openValue.st_uid == geteuid(),
              (openValue.st_mode & 0o777) == 0o600,
              openValue.st_size >= 0,
              openValue.st_size <= 16_384,
              ReferralFileIdentity(openValue) == ReferralFileIdentity(value) else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        try ReferralCodeFile.validateNoExtendedACL(descriptor)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= 16_384 {
            let received = Darwin.read(descriptor, &buffer, buffer.count)
            if received < 0 {
                if errno == EINTR { continue }
                throw ReferralBootstrapFailure(kind: .unavailable)
            }
            if received == 0 { break }
            data.append(contentsOf: buffer.prefix(received))
        }
        guard !data.isEmpty, data.count <= 16_384,
              let attempt = try? JSONDecoder().decode(ReferralBootstrapAttempt.self, from: data),
              attempt.version == 1 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        return attempt
    }

    private func persistUnlocked(_ attempt: ReferralBootstrapAttempt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(attempt), data.count <= 16_384 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        let temporaryPath = url.path + ".tmp.\(getpid()).\(UUID().uuidString.lowercased())"
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        var shouldRemove = true
        defer {
            _ = close(descriptor)
            if shouldRemove { _ = unlink(temporaryPath) }
        }
        var temporaryInfo = stat()
        guard fstat(descriptor, &temporaryInfo) == 0,
              (temporaryInfo.st_mode & S_IFMT) == S_IFREG,
              temporaryInfo.st_uid == geteuid(),
              (temporaryInfo.st_mode & 0o777) == 0o600,
              temporaryInfo.st_nlink == 1 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        try ReferralCodeFile.validateNoExtendedACL(descriptor)
        var written = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while written < data.count {
                let result = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw ReferralBootstrapFailure(kind: .unavailable)
                }
                written += result
            }
        }
        guard fsync(descriptor) == 0, rename(temporaryPath, url.path) == 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        let directoryDescriptor = open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        defer { _ = close(directoryDescriptor) }
        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & 0o077) == 0,
              fsync(directoryDescriptor) == 0 else {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        shouldRemove = false
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
