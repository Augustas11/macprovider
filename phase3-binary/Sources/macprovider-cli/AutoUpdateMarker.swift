import CryptoKit
import Darwin
import Foundation

struct AutoUpdatePendingMarker: Codable, Equatable {
    let updateID: String
    let targetVersion: String
    let targetPath: String
    let backupPath: String
    let size: Int
    let mode: Int
    let sha256: String
    let markerDeadline: String

    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case targetVersion = "target_version"
        case targetPath = "target_path"
        case backupPath = "backup_path"
        case size
        case mode
        case sha256
        case markerDeadline = "marker_deadline"
    }
}

enum AutoUpdateMarkerError: Error, CustomStringConvertible, Equatable {
    case trustedRootInvalid(String)
    case lockContended
    case openFailed(String, Int32)
    case writeFailed(String, Int32)
    case invalidMarker
    case backupCorrupt

    var description: String {
        switch self {
        case let .trustedRootInvalid(reason): return "trusted autoupdate root invalid: \(reason)"
        case .lockContended: return "autoupdate lock is held by another process"
        case let .openFailed(path, errnoValue): return "open failed for \(path): errno \(errnoValue)"
        case let .writeFailed(path, errnoValue): return "write failed for \(path): errno \(errnoValue)"
        case .invalidMarker: return "pending marker is invalid"
        case .backupCorrupt: return "rollback backup is missing or hash-mismatched"
        }
    }
}

final class AutoUpdateLock: @unchecked Sendable {
    let fd: Int32
    let path: URL

    init(fd: Int32, path: URL) {
        self.fd = fd
        self.path = path
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

struct AutoUpdateMarkerStore: Sendable {
    let homeDirectory: URL
    let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    var root: URL {
        homeDirectory.appendingPathComponent(".local/share/macprovider/autoupdate", isDirectory: true)
    }

    var pendingURL: URL {
        root.appendingPathComponent("pending.json")
    }

    var lockURL: URL {
        root.appendingPathComponent("update.lock")
    }

    var cooldownURL: URL {
        root.appendingPathComponent("cooldowns.json")
    }

    var policyURL: URL {
        root.appendingPathComponent("signed-policy.json")
    }

    func ensureTrustedRoot() throws {
        try ensureTrustedDirectory(homeDirectory.appendingPathComponent(".local", isDirectory: true))
        try ensureTrustedDirectory(homeDirectory.appendingPathComponent(".local/share", isDirectory: true))
        try ensureTrustedDirectory(homeDirectory.appendingPathComponent(".local/share/macprovider", isDirectory: true))
        try ensureTrustedDirectory(root)
        try rejectUnexpectedMountCrossing()
    }

    func acquireLock() throws -> AutoUpdateLock {
        try ensureTrustedRoot()
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw AutoUpdateMarkerError.openFailed(lockURL.path, errno)
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let errnoValue = errno
            close(fd)
            if errnoValue == EWOULDBLOCK {
                throw AutoUpdateMarkerError.lockContended
            }
            throw AutoUpdateMarkerError.openFailed(lockURL.path, errnoValue)
        }
        fchmod(fd, S_IRUSR | S_IWUSR)
        return AutoUpdateLock(fd: fd, path: lockURL)
    }

    func rollbackBackupPath(binaryURL: URL, updateID: String) -> URL {
        binaryURL.deletingLastPathComponent()
            .appendingPathComponent(".macprovider-cli.rollback-\(updateID)")
    }

    func successSentinelPath(binaryURL: URL, updateID: String) -> URL {
        binaryURL.deletingLastPathComponent()
            .appendingPathComponent(".macprovider-cli.success-\(updateID)")
    }

    func preserveRollbackBackup(binaryURL: URL, updateID: String) throws -> AutoUpdatePendingMarker {
        let attrs = try fileManager.attributesOfItem(atPath: binaryURL.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let sha = try Self.sha256(file: binaryURL)
        let backup = rollbackBackupPath(binaryURL: binaryURL, updateID: updateID)
        try atomicCopyNoFollow(from: binaryURL, to: backup, mode: mode)
        let deadline = ISO8601DateFormatter.autoupdate.string(from: Date().addingTimeInterval(60 + 300))
        return AutoUpdatePendingMarker(
            updateID: updateID,
            targetVersion: "",
            targetPath: binaryURL.path,
            backupPath: backup.path,
            size: size,
            mode: mode,
            sha256: sha,
            markerDeadline: deadline
        )
    }

    func writePending(_ marker: AutoUpdatePendingMarker) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(marker)
        try atomicWrite(data: data, finalURL: pendingURL, mode: S_IRUSR | S_IWUSR)
    }

    func readPending() throws -> AutoUpdatePendingMarker? {
        guard fileManager.fileExists(atPath: pendingURL.path) else { return nil }
        try rejectSymlinkOrHardLink(pendingURL)
        let data = try Data(contentsOf: pendingURL)
        return try JSONDecoder().decode(AutoUpdatePendingMarker.self, from: data)
    }

    func clearPending() {
        try? fileManager.removeItem(at: pendingURL)
    }

    func writeSuccessSentinel(binaryURL: URL, updateID: String, targetVersion: String) throws {
        let payload: [String: String] = [
            "update_id": updateID,
            "binary_version": targetVersion,
            "success_at": ISO8601DateFormatter.autoupdate.string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try atomicWrite(data: data, finalURL: successSentinelPath(binaryURL: binaryURL, updateID: updateID), mode: S_IRUSR | S_IWUSR)
    }

    func validateBackup(_ marker: AutoUpdatePendingMarker) throws {
        let backupURL = URL(fileURLWithPath: marker.backupPath)
        try rejectSymlinkOrHardLink(backupURL)
        let attrs = try fileManager.attributesOfItem(atPath: backupURL.path)
        guard (attrs[.size] as? NSNumber)?.intValue == marker.size,
              try Self.sha256(file: backupURL).lowercased() == marker.sha256.lowercased()
        else {
            throw AutoUpdateMarkerError.backupCorrupt
        }
    }

    func restoreBackup(_ marker: AutoUpdatePendingMarker) throws {
        try validateBackup(marker)
        let backupURL = URL(fileURLWithPath: marker.backupPath)
        let targetURL = URL(fileURLWithPath: marker.targetPath)
        let staged = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).rollback-\(UUID().uuidString)")
        try atomicCopyNoFollow(from: backupURL, to: staged, mode: marker.mode)
        if rename(staged.path, targetURL.path) != 0 {
            let errnoValue = errno
            try? fileManager.removeItem(at: staged)
            throw AutoUpdateMarkerError.writeFailed(targetURL.path, errnoValue)
        }
        fsyncDirectory(targetURL.deletingLastPathComponent())
    }

    func cooldown(target: String, failureClass: AutoUpdateFailureClass) -> (attempt: Int, until: Date)? {
        guard let object = readCooldowns()["\(target)|\(failureClass.rawValue)"] as? [String: Any],
              let attempt = object["attempt"] as? Int,
              let untilRaw = object["until"] as? String,
              let until = ISO8601DateFormatter.autoupdate.date(from: untilRaw),
              until > Date()
        else {
            return nil
        }
        return (attempt, until)
    }

    func activeCooldown(target: String) -> (failureClass: AutoUpdateFailureClass, attempt: Int, until: Date)? {
        for failureClass in AutoUpdateFailureClass.allCases {
            if let cooldown = cooldown(target: target, failureClass: failureClass) {
                return (failureClass, cooldown.attempt, cooldown.until)
            }
        }
        return nil
    }

    func recordCooldown(target: String, failureClass: AutoUpdateFailureClass) {
        var cooldowns = readCooldowns()
        let key = "\(target)|\(failureClass.rawValue)"
        let existing = cooldowns[key] as? [String: Any]
        let attempt = (existing?["attempt"] as? Int ?? 0) + 1
        let seconds = min(300 * (1 << min(max(attempt - 1, 0), 8)), 3600)
        cooldowns[key] = [
            "attempt": attempt,
            "until": ISO8601DateFormatter.autoupdate.string(from: Date().addingTimeInterval(TimeInterval(seconds))),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: cooldowns, options: [.sortedKeys]) {
            try? atomicWrite(data: data, finalURL: cooldownURL, mode: S_IRUSR | S_IWUSR)
        }
    }

    func completeSuccessfulUpdate(_ marker: AutoUpdatePendingMarker) throws {
        let binaryURL = URL(fileURLWithPath: marker.targetPath)
        try writeSuccessSentinel(
            binaryURL: binaryURL,
            updateID: marker.updateID,
            targetVersion: marker.targetVersion
        )
        clearPending()
        try? fileManager.removeItem(atPath: marker.backupPath)
        try? fileManager.removeItem(at: lockURL)
        try? fileManager.removeItem(at: successSentinelPath(binaryURL: binaryURL, updateID: marker.updateID))
    }

    func updateSignedPolicy(minimum: String?, revoked: [String]) {
        var policy = (try? readPolicy()) ?? SignedPolicy()
        if let minimum, !minimum.isEmpty,
           policy.persistedMinimum.isEmpty || SelfUpdate.compareSemver(policy.persistedMinimum, minimum) == .orderedAscending {
            policy.persistedMinimum = minimum
        }
        policy.persistedRevoked.formUnion(revoked)
        if let data = try? JSONEncoder().encode(policy) {
            try? atomicWrite(data: data, finalURL: policyURL, mode: S_IRUSR | S_IWUSR)
        }
    }

    func effectivePolicy(localMinimum: String? = nil, localRevoked: [String] = []) -> (minimum: String?, revoked: Set<String>) {
        let policy = (try? readPolicy()) ?? SignedPolicy()
        let minimum = [localMinimum, policy.persistedMinimum].compactMap { value in
            value?.isEmpty == false ? value : nil
        }.max { SelfUpdate.compareSemver($0, $1) == .orderedAscending }
        return (minimum, policy.persistedRevoked.union(localRevoked))
    }

    private func ensureTrustedDirectory(_ url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            if lstat(url.path, &st) != 0 {
                throw AutoUpdateMarkerError.trustedRootInvalid("lstat_failed")
            }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw AutoUpdateMarkerError.trustedRootInvalid("not_directory")
        }
        guard st.st_uid == getuid() else {
            throw AutoUpdateMarkerError.trustedRootInvalid("wrong_owner")
        }
        if (st.st_mode & (S_IWGRP | S_IWOTH)) != 0 {
            chmod(url.path, S_IRWXU)
        }
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        if (attrs[.posixPermissions] as? NSNumber)?.intValue != 0o700 {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    private func rejectUnexpectedMountCrossing() throws {
        var home = stat()
        var rootStat = stat()
        guard lstat(homeDirectory.path, &home) == 0, lstat(root.path, &rootStat) == 0 else {
            throw AutoUpdateMarkerError.trustedRootInvalid("stat_failed")
        }
        guard home.st_dev == rootStat.st_dev else {
            throw AutoUpdateMarkerError.trustedRootInvalid("mount_crossing")
        }
    }

    private func rejectSymlinkOrHardLink(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw AutoUpdateMarkerError.openFailed(url.path, errno)
        }
        guard (st.st_mode & S_IFMT) != S_IFLNK, st.st_nlink == 1 else {
            throw AutoUpdateMarkerError.trustedRootInvalid("symlink_or_hardlink")
        }
    }

    private func atomicCopyNoFollow(from source: URL, to finalURL: URL, mode: Int) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw AutoUpdateMarkerError.openFailed(source.path, errno) }
        defer { close(input) }
        let tempURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(finalURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let output = open(tempURL.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(mode))
        guard output >= 0 else { throw AutoUpdateMarkerError.openFailed(tempURL.path, errno) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(input, &buffer, buffer.count)
            if n < 0 {
                let errnoValue = errno
                close(output)
                try? fileManager.removeItem(at: tempURL)
                throw AutoUpdateMarkerError.writeFailed(tempURL.path, errnoValue)
            }
            if n == 0 { break }
            try buffer.withUnsafeBytes { raw in
                var written = 0
                while written < n {
                    let m = write(output, raw.baseAddress!.advanced(by: written), n - written)
                    if m <= 0 {
                        let errnoValue = errno
                        close(output)
                        try? fileManager.removeItem(at: tempURL)
                        throw AutoUpdateMarkerError.writeFailed(tempURL.path, errnoValue)
                    }
                    written += m
                }
            }
        }
        fchmod(output, mode_t(mode))
        fsync(output)
        close(output)
        if rename(tempURL.path, finalURL.path) != 0 {
            let errnoValue = errno
            try? fileManager.removeItem(at: tempURL)
            throw AutoUpdateMarkerError.writeFailed(finalURL.path, errnoValue)
        }
        fsyncDirectory(finalURL.deletingLastPathComponent())
    }

    private func atomicWrite(data: Data, finalURL: URL, mode: mode_t) throws {
        let tempURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(finalURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tempURL.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw AutoUpdateMarkerError.openFailed(tempURL.path, errno) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let wrote = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if wrote <= 0 {
                    let errnoValue = errno
                    close(fd)
                    try? fileManager.removeItem(at: tempURL)
                    throw AutoUpdateMarkerError.writeFailed(tempURL.path, errnoValue)
                }
                offset += wrote
            }
        }
        fchmod(fd, mode)
        fsync(fd)
        close(fd)
        if rename(tempURL.path, finalURL.path) != 0 {
            let errnoValue = errno
            try? fileManager.removeItem(at: tempURL)
            throw AutoUpdateMarkerError.writeFailed(finalURL.path, errnoValue)
        }
        fsyncDirectory(finalURL.deletingLastPathComponent())
    }

    private func fsyncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 {
            fsync(fd)
            close(fd)
        }
    }

    private func readCooldowns() -> [String: Any] {
        guard let data = try? Data(contentsOf: cooldownURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private func readPolicy() throws -> SignedPolicy {
        let data = try Data(contentsOf: policyURL)
        return try JSONDecoder().decode(SignedPolicy.self, from: data)
    }

    static func sha256(file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct SignedPolicy: Codable {
    var persistedMinimum: String = ""
    var persistedRevoked: Set<String> = []

    enum CodingKeys: String, CodingKey {
        case persistedMinimum = "persisted_signed_policy_minimum"
        case persistedRevoked = "persisted_signed_policy_revoked"
    }
}

private extension ISO8601DateFormatter {
    static let autoupdate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
