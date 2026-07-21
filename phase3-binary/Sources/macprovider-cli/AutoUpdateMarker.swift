import CryptoKit
import Darwin
import Foundation

/// Canonical auto-update state machine shared with
/// ops/macprovider-watchdog/watchdog.sh:
///
/// no_update -> download -> pending_install -> committed
///                                      \-> restoring_previous
///                                            \-> awaiting_previous_readiness
///                                                  \-> rolled_back
///
/// State is represented by durable filesystem markers. The CLI writes
/// pending.json only after the binary and owned-release rollback snapshots are
/// fsynced, then swaps the complete release payload while holding update.lock.
/// Legacy pending markers without a release snapshot remain binary-only. The
/// restarted provider commits by writing
/// a success sentinel and clearing pending.json. If a crash, sleep, or restart
/// leaves pending.json behind past marker_deadline, both the CLI recovery path
/// and watchdog treat that as pending_install requiring rollback, not as an
/// invalid marker. Malformed markers are quarantined; expired but otherwise
/// valid markers are restored from their backup.
struct AutoUpdatePendingMarker: Codable, Equatable {
    let updateID: String
    let targetVersion: String
    let targetPath: String
    let backupPath: String
    let size: Int
    let mode: Int
    let sha256: String
    let markerDeadline: String
    let releaseBackupPath: String?
    let releaseBackupSHA256: String?
    let commitOwner: String?
    let targetCompatibilitySetID: String?
    let targetCompatibilitySetSHA256: String?
    let previousVersion: String?
    let previousCompatibilitySetID: String?
    let previousCompatibilitySetSHA256: String?
    let discoveryHeadSequence: UInt64?
    let discoveryHeadSHA256: String?
    let updateAuthorityMode: String?
    let transactionState: CompatibilitySetTransactionState?

    init(
        updateID: String,
        targetVersion: String,
        targetPath: String,
        backupPath: String,
        size: Int,
        mode: Int,
        sha256: String,
        markerDeadline: String,
        releaseBackupPath: String? = nil,
        releaseBackupSHA256: String? = nil,
        commitOwner: String? = nil,
        targetCompatibilitySetID: String? = nil,
        targetCompatibilitySetSHA256: String? = nil,
        previousVersion: String? = nil,
        previousCompatibilitySetID: String? = nil,
        previousCompatibilitySetSHA256: String? = nil,
        discoveryHeadSequence: UInt64? = nil,
        discoveryHeadSHA256: String? = nil,
        updateAuthorityMode: String? = nil,
        transactionState: CompatibilitySetTransactionState? = nil
    ) {
        self.updateID = updateID
        self.targetVersion = targetVersion
        self.targetPath = targetPath
        self.backupPath = backupPath
        self.size = size
        self.mode = mode
        self.sha256 = sha256
        self.markerDeadline = markerDeadline
        self.releaseBackupPath = releaseBackupPath
        self.releaseBackupSHA256 = releaseBackupSHA256
        self.commitOwner = commitOwner
        self.targetCompatibilitySetID = targetCompatibilitySetID
        self.targetCompatibilitySetSHA256 = targetCompatibilitySetSHA256
        self.previousVersion = previousVersion
        self.previousCompatibilitySetID = previousCompatibilitySetID
        self.previousCompatibilitySetSHA256 = previousCompatibilitySetSHA256
        self.discoveryHeadSequence = discoveryHeadSequence
        self.discoveryHeadSHA256 = discoveryHeadSHA256
        self.updateAuthorityMode = updateAuthorityMode
        self.transactionState = transactionState
    }

    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case targetVersion = "target_version"
        case targetPath = "target_path"
        case backupPath = "backup_path"
        case size
        case mode
        case sha256
        case markerDeadline = "marker_deadline"
        case releaseBackupPath = "release_backup_path"
        case releaseBackupSHA256 = "release_backup_sha256"
        case commitOwner = "commit_owner"
        case targetCompatibilitySetID = "target_compatibility_set_id"
        case targetCompatibilitySetSHA256 = "target_compatibility_set_sha256"
        case previousVersion = "previous_version"
        case previousCompatibilitySetID = "previous_compatibility_set_id"
        case previousCompatibilitySetSHA256 = "previous_compatibility_set_sha256"
        case discoveryHeadSequence = "discovery_head_sequence"
        case discoveryHeadSHA256 = "discovery_head_sha256"
        case updateAuthorityMode = "update_authority_mode"
        case transactionState = "transaction_state"
    }

    func withTransactionState(
        _ state: CompatibilitySetTransactionState,
        markerDeadline: String? = nil
    ) -> AutoUpdatePendingMarker {
        AutoUpdatePendingMarker(
            updateID: updateID,
            targetVersion: targetVersion,
            targetPath: targetPath,
            backupPath: backupPath,
            size: size,
            mode: mode,
            sha256: sha256,
            markerDeadline: markerDeadline ?? self.markerDeadline,
            releaseBackupPath: releaseBackupPath,
            releaseBackupSHA256: releaseBackupSHA256,
            commitOwner: commitOwner,
            targetCompatibilitySetID: targetCompatibilitySetID,
            targetCompatibilitySetSHA256: targetCompatibilitySetSHA256,
            previousVersion: previousVersion,
            previousCompatibilitySetID: previousCompatibilitySetID,
            previousCompatibilitySetSHA256: previousCompatibilitySetSHA256,
            discoveryHeadSequence: discoveryHeadSequence,
            discoveryHeadSHA256: discoveryHeadSHA256,
            updateAuthorityMode: updateAuthorityMode,
            transactionState: state
        )
    }
}

enum CompatibilitySetTransactionState: String, Codable, Equatable, Sendable {
    case activatingTarget = "activating_target"
    case restoringPrevious = "restoring_previous"
    case awaitingPreviousReadiness = "awaiting_previous_readiness"
}

struct CoordinatorCompatibilityAdmissionRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let acceptedCompatibilitySetID: String
    let recommendedCompatibilitySetID: String
    let observedAt: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case acceptedCompatibilitySetID = "accepted_compatibility_set_id"
        case recommendedCompatibilitySetID = "recommended_compatibility_set_id"
        case observedAt = "observed_at"
        case expiresAt = "expires_at"
    }
}

enum AutoUpdateMarkerError: Error, CustomStringConvertible, Equatable {
    case trustedRootInvalid(String)
    case lockContended
    case transactionPending
    case openFailed(String, Int32)
    case writeFailed(String, Int32)
    case invalidMarker
    case backupCorrupt
    case rollbackTargetDisallowed
    case compatibilityAdmissionRequired(String)
    case pathEntrypointUnsafe(String)

    var description: String {
        switch self {
        case let .trustedRootInvalid(reason): return "trusted autoupdate root invalid: \(reason)"
        case .lockContended: return "provider mutation lock is held by another process"
        case .transactionPending: return "a provider mutation transaction is still pending recovery or admission"
        case let .openFailed(path, errnoValue): return "open failed for \(path): errno \(errnoValue)"
        case let .writeFailed(path, errnoValue): return "write failed for \(path): errno \(errnoValue)"
        case .invalidMarker: return "pending marker is invalid"
        case .backupCorrupt: return "rollback backup is missing or hash-mismatched"
        case .rollbackTargetDisallowed: return "rollback target is revoked or below the effective minimum"
        case let .compatibilityAdmissionRequired(reason):
            return "fresh coordinator compatibility-set admission required: \(reason)"
        case let .pathEntrypointUnsafe(reason):
            return "PATH entrypoint convergence refused: \(reason)"
        }
    }
}

struct AutoUpdateSignedPolicyPersistError: Error, CustomStringConvertible {
    let underlying: String

    var description: String {
        "signed policy persist failed: \(underlying)"
    }
}

final class SessionAutoupdateGate: @unchecked Sendable {
    static let shared = SessionAutoupdateGate()

    private let lock = NSLock()
    private var disabledReason: String?

    var isDisabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disabledReason != nil
    }

    func disable(reason: String) {
        lock.lock()
        disabledReason = reason
        lock.unlock()
    }

    func resetForTest() {
        lock.lock()
        disabledReason = nil
        lock.unlock()
    }
}

enum AutoUpdateOrphanRecoveryOutcome: Equatable {
    case restored(AutoUpdatePendingMarker)
    case restoredAwaitingReadiness(AutoUpdatePendingMarker)
    case markerInvalid
    case backupCorrupt(AutoUpdatePendingMarker, String)
    case rollbackTargetDisallowed(AutoUpdatePendingMarker)
}

enum CompatibilitySetCutoverPhase: String, CaseIterable, Sendable {
    case ownedResourcesRemoved = "owned_resources_removed"
    case ownedResourcesActivated = "owned_resources_activated"
    case watchdogScriptActivated = "watchdog_script_activated"
    case providerPlistActivated = "provider_plist_activated"
    case watchdogPlistActivated = "watchdog_plist_activated"
    case binaryActivated = "binary_activated"
    case malibuAppActivated = "malibu_app_activated"
}

final class AutoUpdateLock: @unchecked Sendable {
    let fd: Int32
    let outerFD: Int32
    let path: URL

    init(fd: Int32, outerFD: Int32, path: URL) {
        self.fd = fd
        self.outerFD = outerFD
        self.path = path
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
        flock(outerFD, LOCK_UN)
        close(outerFD)
    }
}

private struct CompatibilityExternalMemberBackup: Codable, Equatable {
    let schemaVersion: Int
    let members: [CompatibilityExternalMemberRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case members
    }
}

private struct CompatibilityExternalMemberRecord: Codable, Equatable {
    let member: String
    let wasPresent: Bool
    let mode: Int?
    let sha256: String?

    enum CodingKeys: String, CodingKey {
        case member
        case wasPresent = "was_present"
        case mode
        case sha256
    }
}

private struct MalibuAppRollbackRecord: Codable, Equatable {
    let schemaVersion: Int
    let targetPath: String
    let archiveSHA256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case targetPath = "target_path"
        case archiveSHA256 = "archive_sha256"
    }
}

// FileManager is thread-safe for independent filesystem operations. The store
// carries no mutable shared state beyond that Foundation reference.
struct AutoUpdateMarkerStore: @unchecked Sendable {
    private static let localArtifactDirectoryName = CompatibilitySetManifest.localArtifactDirectoryName
    private static let externalBackupDirectoryName = "external-local-members"
    private static let externalBackupStateName = "state.json"
    private static let providerPlistName = "provider.plist"
    private static let watchdogScriptName = "watchdog.sh"
    private static let watchdogPlistName = "watchdog.plist"
    private static let malibuAppBackupName = "Malibu.app.zip"
    private static let malibuAppStateName = "malibu-app-state.json"
    static let compatibilityAdmissionValiditySeconds: TimeInterval = 90
    private static let compatibilityAdmissionMaximumBytes = 4_096

    let homeDirectory: URL
    let fileManager: FileManager
    let compatibilityManifestPublicKeyPEM: String
    private let installerOwnerLiveOverride: (@Sendable () -> Bool)?
    private let malibuAppCandidateOverride: [URL]?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        compatibilityManifestPublicKeyPEM: String = SelfUpdate.checksumPublicKeyPEM,
        installerOwnerLiveOverride: (@Sendable () -> Bool)? = nil,
        malibuAppCandidateOverride: [URL]? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.compatibilityManifestPublicKeyPEM = compatibilityManifestPublicKeyPEM
        self.installerOwnerLiveOverride = installerOwnerLiveOverride
        self.malibuAppCandidateOverride = malibuAppCandidateOverride
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

    var installerLockURL: URL {
        homeDirectory.appendingPathComponent(".config/macprovider/install.lock")
    }

    var cooldownURL: URL {
        root.appendingPathComponent("cooldowns.json")
    }

    var policyURL: URL {
        root.appendingPathComponent("signed-policy.json")
    }

    var compatibilityAdmissionURL: URL {
        root.appendingPathComponent("compatibility-admission.json")
    }

    var discoveryStateURL: URL {
        root.appendingPathComponent("release-discovery-state.json")
    }

    private var providerPlistURL: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist")
    }

    private var watchdogScriptURL: URL {
        homeDirectory.appendingPathComponent(".local/share/macprovider-watchdog/macprovider-health-monitor")
    }

    private var watchdogPlistURL: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist")
    }

    /// Canonical PATH entrypoint (SPEC-003 FR-C2). `install.sh` always
    /// places a symlink here so PATH users and the launchd plist resolve
    /// into the same live install directory. Self-update activation must
    /// keep it converged or a stale pre-symlink copy can drift to a
    /// different version with no sibling `compatibility-set.json` (#616).
    var pathEntrypointURL: URL {
        homeDirectory.appendingPathComponent(".local/bin/macprovider-cli")
    }

    func ensureTrustedRoot() throws {
        try ensureTrustedDirectory(homeDirectory.appendingPathComponent(".local", isDirectory: true))
        try ensureTrustedDirectory(homeDirectory.appendingPathComponent(".local/share", isDirectory: true))
        try ensureTrustedDirectory(homeDirectory.appendingPathComponent(".local/share/macprovider", isDirectory: true))
        try ensureTrustedDirectory(root)
        try rejectUnexpectedMountCrossing()
    }

    func persistCompatibilityAdmission(
        acceptedCompatibilitySetID: String,
        recommendedCompatibilitySetID: String,
        now: Date = Date(),
        validitySeconds: TimeInterval = Self.compatibilityAdmissionValiditySeconds
    ) throws {
        guard CompatibilitySetManifest.isCanonicalCompatibilitySetID(acceptedCompatibilitySetID),
              CompatibilitySetManifest.isCanonicalCompatibilitySetID(recommendedCompatibilitySetID),
              validitySeconds >= 30,
              validitySeconds <= 300 else {
            throw AutoUpdateMarkerError.compatibilityAdmissionRequired("invalid_admission_record")
        }
        try ensureTrustedRoot()
        let record = CoordinatorCompatibilityAdmissionRecord(
            schemaVersion: 1,
            acceptedCompatibilitySetID: acceptedCompatibilitySetID,
            recommendedCompatibilitySetID: recommendedCompatibilitySetID,
            observedAt: ISO8601DateFormatter.autoupdate.string(from: now),
            expiresAt: ISO8601DateFormatter.autoupdate.string(from: now.addingTimeInterval(validitySeconds))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try atomicWrite(
            data: data,
            finalURL: compatibilityAdmissionURL,
            mode: S_IRUSR | S_IWUSR
        )
    }

    func clearCompatibilityAdmission() throws {
        guard fileManager.fileExists(atPath: compatibilityAdmissionURL.path) else { return }
        try ensureTrustedRoot()
        guard unlink(compatibilityAdmissionURL.path) == 0 || errno == ENOENT else {
            throw AutoUpdateMarkerError.writeFailed(compatibilityAdmissionURL.path, errno)
        }
        fsyncDirectory(root)
    }

    func requireCoordinatorCompatibilityTarget(
        _ targetCompatibilitySetID: String,
        currentCompatibilitySetID: String?,
        now: Date = Date()
    ) throws {
        guard CompatibilitySetManifest.isCanonicalCompatibilitySetID(targetCompatibilitySetID),
              let currentCompatibilitySetID,
              CompatibilitySetManifest.isCanonicalCompatibilitySetID(currentCompatibilitySetID) else {
            throw AutoUpdateMarkerError.compatibilityAdmissionRequired("invalid_current_or_target_set")
        }
        let record = try readCompatibilityAdmission()
        guard record.acceptedCompatibilitySetID == currentCompatibilitySetID else {
            throw AutoUpdateMarkerError.compatibilityAdmissionRequired("accepted_set_mismatch")
        }
        guard record.recommendedCompatibilitySetID == targetCompatibilitySetID else {
            throw AutoUpdateMarkerError.compatibilityAdmissionRequired("recommended_set_mismatch")
        }
        guard let observedAt = ISO8601DateFormatter.autoupdate.date(from: record.observedAt),
              let expiresAt = ISO8601DateFormatter.autoupdate.date(from: record.expiresAt),
              observedAt <= now.addingTimeInterval(5),
              expiresAt > now,
              expiresAt.timeIntervalSince(observedAt) >= 30,
              expiresAt.timeIntervalSince(observedAt) <= 300 else {
            throw AutoUpdateMarkerError.compatibilityAdmissionRequired("admission_expired_or_invalid")
        }
    }

    func readCompatibilityAdmissionForTest() throws -> CoordinatorCompatibilityAdmissionRecord {
        try readCompatibilityAdmission()
    }

    func acceptDiscoveryHead(_ head: SignedReleaseDiscoveryHead) throws {
        try ensureTrustedRoot()
        if let existing = try readDiscoveryState() {
            if head.releaseSequence < existing.releaseSequence {
                throw UpdateError.discoveryHeadReplay
            }
            if head.releaseSequence == existing.releaseSequence,
               head.digest != existing.headSHA256 {
                throw UpdateError.discoveryHeadEquivocation
            }
        }
        let record = SignedReleaseDiscoveryState(
            schemaVersion: 1,
            releaseSequence: head.releaseSequence,
            headSHA256: head.digest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomicWrite(
            data: try encoder.encode(record),
            finalURL: discoveryStateURL,
            mode: S_IRUSR | S_IWUSR
        )
    }

    func readDiscoveryStateForTest() throws -> SignedReleaseDiscoveryState? {
        try readDiscoveryState()
    }

    private func readDiscoveryState() throws -> SignedReleaseDiscoveryState? {
        guard fileManager.fileExists(atPath: discoveryStateURL.path) else { return nil }
        let data = try readRegularFileNoFollow(discoveryStateURL)
        guard data.count <= 4096 else { throw UpdateError.discoveryHeadInvalid("state_too_large") }
        let record = try JSONDecoder().decode(SignedReleaseDiscoveryState.self, from: data)
        guard record.schemaVersion == 1,
              record.releaseSequence > 0,
              record.headSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        else {
            throw UpdateError.discoveryHeadInvalid("state_invalid")
        }
        return record
    }

    private func readCompatibilityAdmission() throws -> CoordinatorCompatibilityAdmissionRecord {
        guard fileManager.fileExists(atPath: compatibilityAdmissionURL.path) else {
            throw AutoUpdateMarkerError.compatibilityAdmissionRequired("admission_missing")
        }
        let data = try readRegularFileNoFollow(compatibilityAdmissionURL)
        guard data.count <= Self.compatibilityAdmissionMaximumBytes else {
            throw AutoUpdateMarkerError.compatibilityAdmissionRequired("admission_too_large")
        }
        do {
            try AutotuneStrictJSON.rejectDuplicateKeys(data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set([
                      "accepted_compatibility_set_id",
                      "expires_at",
                      "observed_at",
                      "recommended_compatibility_set_id",
                      "schema_version",
                  ]) else {
                throw AutoUpdateMarkerError.compatibilityAdmissionRequired("admission_fields")
            }
            let record = try JSONDecoder().decode(CoordinatorCompatibilityAdmissionRecord.self, from: data)
            guard record.schemaVersion == 1,
                  CompatibilitySetManifest.isCanonicalCompatibilitySetID(record.acceptedCompatibilitySetID),
                  CompatibilitySetManifest.isCanonicalCompatibilitySetID(record.recommendedCompatibilitySetID) else {
                throw AutoUpdateMarkerError.compatibilityAdmissionRequired("admission_values")
            }
            return record
        } catch let error as AutoUpdateMarkerError {
            throw error
        } catch {
            throw AutoUpdateMarkerError.compatibilityAdmissionRequired("admission_invalid")
        }
    }

    func acquireLock() throws -> AutoUpdateLock {
        try acquireLock(allowPending: false)
    }

    /// Recovery and authoritative commit must serialize with installers,
    /// updater activation, and the independent watchdog while an existing
    /// pending marker remains armed.
    func acquireRecoveryLock() throws -> AutoUpdateLock {
        try acquireLock(allowPending: true)
    }

    private func acquireLock(allowPending: Bool) throws -> AutoUpdateLock {
        try ensureTrustedRoot()
        try ensureTrustedDirectory(homeDirectory.appendingPathComponent(".config", isDirectory: true))
        try ensureTrustedDirectory(homeDirectory.appendingPathComponent(".config/macprovider", isDirectory: true))
        let outerFD = open(installerLockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard outerFD >= 0 else {
            throw AutoUpdateMarkerError.openFailed(installerLockURL.path, errno)
        }
        var outerInfo = stat()
        guard fstat(outerFD, &outerInfo) == 0,
              (outerInfo.st_mode & S_IFMT) == S_IFREG,
              outerInfo.st_uid == getuid(),
              outerInfo.st_nlink == 1,
              outerInfo.st_mode & (S_IRWXG | S_IRWXO) == 0
        else {
            close(outerFD)
            throw AutoUpdateMarkerError.trustedRootInvalid("provider_mutation_outer_lock_invalid")
        }
        guard fchmod(outerFD, S_IRUSR | S_IWUSR) == 0 else {
            close(outerFD)
            throw AutoUpdateMarkerError.trustedRootInvalid("provider_mutation_outer_lock_mode_invalid")
        }
        guard flock(outerFD, LOCK_EX | LOCK_NB) == 0 else {
            let errnoValue = errno
            close(outerFD)
            if errnoValue == EWOULDBLOCK {
                throw AutoUpdateMarkerError.lockContended
            }
            throw AutoUpdateMarkerError.openFailed(installerLockURL.path, errnoValue)
        }
        guard !installerOwnerIsLive() else {
            flock(outerFD, LOCK_UN)
            close(outerFD)
            throw AutoUpdateMarkerError.lockContended
        }
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            flock(outerFD, LOCK_UN)
            close(outerFD)
            throw AutoUpdateMarkerError.openFailed(lockURL.path, errno)
        }
        var innerInfo = stat()
        guard fstat(fd, &innerInfo) == 0,
              (innerInfo.st_mode & S_IFMT) == S_IFREG,
              innerInfo.st_uid == getuid(),
              innerInfo.st_nlink == 1,
              innerInfo.st_mode & (S_IRWXG | S_IRWXO) == 0
        else {
            close(fd)
            flock(outerFD, LOCK_UN)
            close(outerFD)
            throw AutoUpdateMarkerError.trustedRootInvalid("provider_mutation_inner_lock_invalid")
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            close(fd)
            flock(outerFD, LOCK_UN)
            close(outerFD)
            throw AutoUpdateMarkerError.trustedRootInvalid("provider_mutation_inner_lock_mode_invalid")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let errnoValue = errno
            close(fd)
            flock(outerFD, LOCK_UN)
            close(outerFD)
            if errnoValue == EWOULDBLOCK {
                throw AutoUpdateMarkerError.lockContended
            }
            throw AutoUpdateMarkerError.openFailed(lockURL.path, errnoValue)
        }
        guard !installerOwnerIsLive() else {
            flock(fd, LOCK_UN)
            close(fd)
            flock(outerFD, LOCK_UN)
            close(outerFD)
            throw AutoUpdateMarkerError.lockContended
        }
        if !allowPending, fileManager.fileExists(atPath: pendingURL.path) {
            flock(fd, LOCK_UN)
            close(fd)
            flock(outerFD, LOCK_UN)
            close(outerFD)
            throw AutoUpdateMarkerError.transactionPending
        }
        return AutoUpdateLock(fd: fd, outerFD: outerFD, path: lockURL)
    }

    func updateLockIsLive() -> Bool {
        if installerOwnerIsLive() {
            return true
        }
        let fd = open(lockURL.path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_mode & (S_IRWXG | S_IRWXO) == 0
        else {
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// The shell installer holds the same kernel lock as Swift mutators. Its
    /// durable owner record is an additional fence for the narrow case where
    /// the helper holding `update.lock` is SIGKILLed while the installer shell
    /// remains alive. Refuse mutation/recovery until that exact owner identity
    /// disappears so a killed helper cannot create an overlapping writer.
    private func installerOwnerIsLive() -> Bool {
        if let installerOwnerLiveOverride {
            return installerOwnerLiveOverride()
        }
        let fd = open(installerLockURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              info.st_size > 0,
              info.st_size <= 4096
        else {
            return false
        }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidNumber = object["pid"] as? NSNumber,
              let recordedStart = object["process_start"] as? String,
              !recordedStart.isEmpty,
              let recordedBoot = object["boot_session"] as? String,
              !recordedBoot.isEmpty,
              currentBootSession() == recordedBoot
        else {
            return false
        }
        return processStart(pid: pid_t(pidNumber.int32Value)) == recordedStart
    }

    private func currentBootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func processStart(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart="]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func rollbackBackupPath(binaryURL: URL, updateID: String) -> URL {
        binaryURL.deletingLastPathComponent()
            .appendingPathComponent(".macprovider-cli.rollback-\(updateID)")
    }

    func releaseRollbackBackupPath(binaryURL: URL, updateID: String) -> URL {
        binaryURL.deletingLastPathComponent()
            .appendingPathComponent(".macprovider-cli.release-rollback-\(updateID)", isDirectory: true)
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

    func preserveReleaseRollbackBackup(
        binaryURL: URL,
        updateID: String,
        targetVersion: String,
        previousVersion: String? = nil,
        commitOwner: String = "coordinator",
        targetCompatibilitySetID: String? = nil,
        targetCompatibilitySetSHA256: String? = nil,
        discoveryHeadSequence: UInt64? = nil,
        discoveryHeadSHA256: String? = nil,
        updateAuthorityMode: String? = nil,
        readinessTimeoutSeconds: Int = 300
    ) throws -> AutoUpdatePendingMarker {
        let installDirectory = binaryURL.deletingLastPathComponent()
        try validateTrustedBinaryDirectory(installDirectory)
        let attrs = try fileManager.attributesOfItem(atPath: binaryURL.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let sha = try Self.sha256(file: binaryURL)
        let binaryBackup = rollbackBackupPath(binaryURL: binaryURL, updateID: updateID)
        let releaseBackup = releaseRollbackBackupPath(binaryURL: binaryURL, updateID: updateID)

        let previousCompatibilityManifest: CompatibilitySetManifest?
        switch (targetCompatibilitySetID, targetCompatibilitySetSHA256) {
        case (nil, nil):
            previousCompatibilityManifest = nil
        case (.some, .some):
            guard let previousVersion else {
                throw AutoUpdateMarkerError.invalidMarker
            }
            previousCompatibilityManifest = try CompatibilitySetManifest.loadValidated(
                from: installDirectory,
                expectedProviderVersion: previousVersion,
                publicKeyPEM: compatibilityManifestPublicKeyPEM
            )
        default:
            throw AutoUpdateMarkerError.invalidMarker
        }

        try atomicCopyNoFollow(from: binaryURL, to: binaryBackup, mode: mode)
        do {
            try fileManager.createDirectory(
                at: releaseBackup,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            for entry in try ownedReleaseResourceEntries(in: installDirectory) {
                try validateReleaseEntry(entry)
                try fileManager.copyItem(
                    at: entry,
                    to: releaseBackup.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
                )
            }
            try preserveExternalLocalMembers(
                into: releaseBackup.appendingPathComponent(Self.externalBackupDirectoryName, isDirectory: true)
            )
            try preserveInstalledMalibuApp(into: releaseBackup)
            try fsyncTree(releaseBackup)
            let releaseSHA = try releaseTreeSHA256(releaseBackup)
            guard (60...1_200).contains(readinessTimeoutSeconds) else {
                throw AutoUpdateMarkerError.invalidMarker
            }
            let deadline = ISO8601DateFormatter.autoupdate.string(
                from: Date().addingTimeInterval(60 + TimeInterval(readinessTimeoutSeconds))
            )
            return AutoUpdatePendingMarker(
                updateID: updateID,
                targetVersion: targetVersion,
                targetPath: binaryURL.path,
                backupPath: binaryBackup.path,
                size: size,
                mode: mode,
                sha256: sha,
                markerDeadline: deadline,
                releaseBackupPath: releaseBackup.path,
                releaseBackupSHA256: releaseSHA,
                commitOwner: commitOwner,
                targetCompatibilitySetID: targetCompatibilitySetID,
                targetCompatibilitySetSHA256: targetCompatibilitySetSHA256,
                previousVersion: previousCompatibilityManifest?.providerCLIVersion,
                previousCompatibilitySetID: previousCompatibilityManifest?.compatibilitySetID,
                previousCompatibilitySetSHA256: previousCompatibilityManifest?.envelopeSHA256,
                discoveryHeadSequence: discoveryHeadSequence,
                discoveryHeadSHA256: discoveryHeadSHA256,
                updateAuthorityMode: updateAuthorityMode,
                transactionState: previousCompatibilityManifest == nil ? nil : .activatingTarget
            )
        } catch {
            try? fileManager.removeItem(at: releaseBackup)
            try? fileManager.removeItem(at: binaryBackup)
            throw error
        }
    }

    func writePending(_ marker: AutoUpdatePendingMarker) throws {
        try validateMarker(marker)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(marker)
        try atomicWrite(data: data, finalURL: pendingURL, mode: S_IRUSR | S_IWUSR)
    }

    func readPending() throws -> AutoUpdatePendingMarker? {
        guard fileManager.fileExists(atPath: pendingURL.path) else { return nil }
        let data = try readRegularFileNoFollow(pendingURL)
        let marker = try JSONDecoder().decode(AutoUpdatePendingMarker.self, from: data)
        try validateMarker(marker)
        return marker
    }

    func clearPending() {
        try? fileManager.removeItem(at: pendingURL)
    }

    func writeSuccessSentinel(binaryURL: URL, marker: AutoUpdatePendingMarker) throws {
        let payload: [String: String] = [
            "update_id": marker.updateID,
            "binary_version": marker.targetVersion,
            "target_compatibility_set_id": marker.targetCompatibilitySetID ?? "",
            "target_compatibility_set_sha256": marker.targetCompatibilitySetSHA256 ?? "",
            "success_at": ISO8601DateFormatter.autoupdate.string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try atomicWrite(data: data, finalURL: successSentinelPath(binaryURL: binaryURL, updateID: marker.updateID), mode: S_IRUSR | S_IWUSR)
    }

    func writeSuccessSentinel(binaryURL: URL, updateID: String, targetVersion: String) throws {
        let marker = AutoUpdatePendingMarker(
            updateID: updateID,
            targetVersion: targetVersion,
            targetPath: binaryURL.path,
            backupPath: rollbackBackupPath(binaryURL: binaryURL, updateID: updateID).path,
            size: 0,
            mode: 0o755,
            sha256: String(repeating: "0", count: 64),
            markerDeadline: ISO8601DateFormatter.autoupdate.string(from: Date().addingTimeInterval(300))
        )
        try writeSuccessSentinel(binaryURL: binaryURL, marker: marker)
    }

    func validateBackup(_ marker: AutoUpdatePendingMarker) throws {
        try validateMarker(marker)
        try validateRollbackTopology(marker)
        let backupURL = URL(fileURLWithPath: marker.backupPath)
        let st = try regularFileStatNoFollow(backupURL)
        guard st.st_size == marker.size,
              try Self.sha256(file: backupURL) == marker.sha256
        else {
            throw AutoUpdateMarkerError.backupCorrupt
        }
        try validateReleaseBackup(marker)
    }

    func restoreBackup(_ marker: AutoUpdatePendingMarker) throws {
        try ensureRollbackTargetAllowed(marker)
        try validateBackup(marker)
        let backupURL = URL(fileURLWithPath: marker.backupPath)
        let targetURL = URL(fileURLWithPath: marker.targetPath)
        if let releaseBackupPath = marker.releaseBackupPath {
            let releaseBackup = URL(fileURLWithPath: releaseBackupPath, isDirectory: true)
            let staging = targetURL.deletingLastPathComponent()
                .appendingPathComponent(".macprovider-cli.release-restore-\(UUID().uuidString.lowercased())", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fileManager.removeItem(at: staging) }
            for entry in try ownedReleaseResourceEntries(in: releaseBackup) {
                try fileManager.copyItem(
                    at: entry,
                    to: staging.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
                )
            }
            try fsyncTree(staging)
            try removeOwnedReleaseResources(in: targetURL.deletingLastPathComponent())
            for entry in try ownedReleaseResourceEntries(in: staging) {
                try fileManager.moveItem(
                    at: entry,
                    to: targetURL.deletingLastPathComponent()
                        .appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
                )
            }
            try restoreExternalLocalMembersIfPresent(from: releaseBackup)
            try restoreMalibuAppIfPresent(from: releaseBackup)
            fsyncDirectory(targetURL.deletingLastPathComponent())
        }
        try atomicCopyNoFollow(from: backupURL, to: targetURL, mode: marker.mode)
    }

    /// Moves an exact compatibility-set rollback through durable phases. The
    /// pending marker and both snapshots remain until the restored provider
    /// proves exact coordinator admission and buyer-serving readiness.
    @discardableResult
    func restoreBackupAwaitingPreviousReadiness(
        _ marker: AutoUpdatePendingMarker,
        readinessTimeoutSeconds: Int = 300
    ) throws -> AutoUpdatePendingMarker {
        guard marker.transactionState != nil else {
            try restoreBackup(marker)
            return marker
        }
        guard (60...1_200).contains(readinessTimeoutSeconds) else {
            throw AutoUpdateMarkerError.invalidMarker
        }
        let restoring = marker.withTransactionState(.restoringPrevious)
        try writePending(restoring)
        try restoreBackup(restoring)
        return try markPreviousRestoredAwaitingReadiness(
            restoring,
            readinessTimeoutSeconds: readinessTimeoutSeconds
        )
    }

    @discardableResult
    func markPreviousRestoredAwaitingReadiness(
        _ marker: AutoUpdatePendingMarker,
        readinessTimeoutSeconds: Int = 300
    ) throws -> AutoUpdatePendingMarker {
        guard marker.transactionState == .restoringPrevious,
              (60...1_200).contains(readinessTimeoutSeconds)
        else {
            throw AutoUpdateMarkerError.invalidMarker
        }
        let deadline = ISO8601DateFormatter.autoupdate.string(
            from: Date().addingTimeInterval(TimeInterval(readinessTimeoutSeconds))
        )
        let awaiting = marker.withTransactionState(
            .awaitingPreviousReadiness,
            markerDeadline: deadline
        )
        try writePending(awaiting)
        return awaiting
    }

    func completeRestoredPreviousSet(_ marker: AutoUpdatePendingMarker) throws {
        guard marker.transactionState == .awaitingPreviousReadiness else {
            throw AutoUpdateMarkerError.invalidMarker
        }
        try validateBackup(marker)
        clearPending()
        removeRollbackBackups(marker)
    }

    func activateReleasePayload(
        from payloadDirectory: URL,
        newBinary: URL,
        to currentBinary: URL,
        stagedMalibuApp: URL? = nil,
        rollbackMarker: AutoUpdatePendingMarker? = nil,
        cutoverCheckpoint: ((CompatibilitySetCutoverPhase) throws -> Void)? = nil
    ) throws {
        try validateReleasePayload(at: payloadDirectory, newBinary: newBinary)
        let liveDirectory = currentBinary.deletingLastPathComponent()
        try validateTrustedBinaryDirectory(liveDirectory)
        let staging = liveDirectory.appendingPathComponent(
            ".macprovider-cli.release-activation-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: staging) }

        for entry in try ownedReleaseResourceEntries(in: payloadDirectory) {
            try fileManager.copyItem(
                at: entry,
                to: staging.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
            )
        }
        try fsyncTree(staging)
        try removeOwnedReleaseResources(in: liveDirectory)
        fsyncDirectory(liveDirectory)
        try cutoverCheckpoint?(.ownedResourcesRemoved)
        for entry in try ownedReleaseResourceEntries(in: staging) {
            try fileManager.moveItem(
                at: entry,
                to: liveDirectory.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
            )
        }
        fsyncDirectory(liveDirectory)
        try cutoverCheckpoint?(.ownedResourcesActivated)
        try activateExternalLocalMembers(
            from: liveDirectory.appendingPathComponent(Self.localArtifactDirectoryName, isDirectory: true),
            installDirectory: liveDirectory,
            cutoverCheckpoint: cutoverCheckpoint
        )
        try atomicCopyNoFollow(from: newBinary, to: currentBinary, mode: 0o755)
        try cutoverCheckpoint?(.binaryActivated)
        try convergePathEntrypoint(to: currentBinary)
        if try activateMalibuAppIfInstalled(
            stagedMalibuApp,
            from: liveDirectory,
            rollbackMarker: rollbackMarker
        ) {
            try cutoverCheckpoint?(.malibuAppActivated)
        }
    }

    /// Converges the user PATH entrypoint to a symlink at `canonicalBinary`
    /// so every supported entrypoint resolves into the one just-activated
    /// compatibility set (#616). Because it is a symlink rather than a copy,
    /// it stays correct across future updates and rollbacks with no
    /// additional bookkeeping: it always resolves to whatever is currently
    /// live at `canonicalBinary`.
    ///
    /// Returns `true` if a repair was performed, `false` if the entrypoint
    /// was already converged or there is no PATH entrypoint to converge
    /// (no `~/.local/bin` directory, or nothing installed at that path --
    /// out of scope here; see #610). Throws rather than silently leaving a
    /// divergent entrypoint if the existing entrypoint or its directory is
    /// unsafe to repair.
    @discardableResult
    func convergePathEntrypoint(to canonicalBinary: URL) throws -> Bool {
        let entrypoint = pathEntrypointURL
        let binDirectory = entrypoint.deletingLastPathComponent()

        var binInfo = stat()
        guard lstat(binDirectory.path, &binInfo) == 0 else {
            return false
        }
        try validateTrustedBinaryDirectory(binDirectory)

        var entrypointInfo = stat()
        guard lstat(entrypoint.path, &entrypointInfo) == 0 else {
            return false
        }
        guard entrypointInfo.st_uid == getuid() else {
            throw AutoUpdateMarkerError.pathEntrypointUnsafe("owner")
        }

        let canonicalPath = canonicalBinary.standardizedFileURL.path
        switch entrypointInfo.st_mode & S_IFMT {
        case S_IFLNK:
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(entrypoint.path, &buffer, buffer.count - 1)
            guard length > 0 else {
                throw AutoUpdateMarkerError.pathEntrypointUnsafe("readlink_failed")
            }
            buffer[length] = 0
            let target = String(cString: buffer)
            let resolvedTarget = target.hasPrefix("/")
                ? URL(fileURLWithPath: target).standardizedFileURL.path
                : binDirectory.appendingPathComponent(target).standardizedFileURL.path
            if resolvedTarget == canonicalPath {
                return false
            }
        case S_IFREG:
            break
        default:
            throw AutoUpdateMarkerError.pathEntrypointUnsafe("unexpected_type")
        }

        let temporaryLink = binDirectory.appendingPathComponent(
            ".macprovider-cli.entrypoint-\(UUID().uuidString.lowercased())"
        )
        guard symlink(canonicalPath, temporaryLink.path) == 0 else {
            throw AutoUpdateMarkerError.pathEntrypointUnsafe("symlink_create_failed")
        }
        guard rename(temporaryLink.path, entrypoint.path) == 0 else {
            unlink(temporaryLink.path)
            throw AutoUpdateMarkerError.pathEntrypointUnsafe("symlink_swap_failed")
        }
        fsyncDirectory(binDirectory)
        return true
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
        try validateBackup(marker)
        let binaryURL = URL(fileURLWithPath: marker.targetPath)
        try writeSuccessSentinel(
            binaryURL: binaryURL,
            marker: marker
        )
        clearPending()
        removeRollbackBackups(marker)
    }

    func finalizeSuccessfulUpdate(_ marker: AutoUpdatePendingMarker) throws {
        try validateMarker(marker)
        finalizeSuccessfulUpdate(
            updateID: marker.updateID,
            binaryURL: URL(fileURLWithPath: marker.targetPath)
        )
    }

    func finalizeSuccessfulUpdate(updateID: String, binaryURL: URL) {
        try? fileManager.removeItem(at: successSentinelPath(binaryURL: binaryURL, updateID: updateID))
    }

    func clearPendingAndLock(target: String?, failureClass: AutoUpdateFailureClass = .orphanedPendingMarker) {
        clearPending()
        if let target {
            recordCooldown(target: target, failureClass: failureClass)
        }
    }

    func recoverOrphanedMarker(_ marker: AutoUpdatePendingMarker) -> AutoUpdateOrphanRecoveryOutcome {
        do {
            try validateMarker(marker)
        } catch {
            quarantinePendingMarker()
            removeBackupIfSafe(marker.backupPath)
            return .markerInvalid
        }
        do {
            try validateBackup(marker)
        } catch {
            quarantinePendingMarker()
            return .backupCorrupt(marker, "backup_missing_or_hash_mismatch")
        }
        do {
            let restored = try restoreBackupAwaitingPreviousReadiness(marker)
            if restored.transactionState == .awaitingPreviousReadiness {
                recordCooldown(target: marker.targetVersion, failureClass: .orphanedPendingMarker)
                return .restoredAwaitingReadiness(restored)
            }
            clearPending()
            removeRollbackBackups(marker)
            recordCooldown(target: marker.targetVersion, failureClass: .orphanedPendingMarker)
            return .restored(marker)
        } catch AutoUpdateMarkerError.rollbackTargetDisallowed {
            recordCooldown(target: marker.targetVersion, failureClass: .rollbackTargetDisallowed)
            return .rollbackTargetDisallowed(marker)
        } catch {
            quarantinePendingMarker()
            return .backupCorrupt(marker, String(describing: error))
        }
    }

    func recoverInvalidPendingMarker() {
        quarantinePendingMarker()
    }

    private func quarantinePendingMarker() {
        guard fileManager.fileExists(atPath: pendingURL.path) else { return }
        let stamp = ISO8601DateFormatter.autoupdate
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let destination = root.appendingPathComponent("pending-quarantined-\(stamp).json")
        if fileManager.fileExists(atPath: destination.path) {
            let fallback = root.appendingPathComponent("pending-quarantined-\(stamp)-\(UUID().uuidString).json")
            try? fileManager.moveItem(at: pendingURL, to: fallback)
        } else {
            try? fileManager.moveItem(at: pendingURL, to: destination)
        }
        fsyncDirectory(root)
    }

    private func removeBackupIfSafe(_ path: String) {
        guard isCanonicalAbsolutePath(path) else { return }
        let url = URL(fileURLWithPath: path)
        do {
            _ = try regularFileStatNoFollow(url)
            try fileManager.removeItem(at: url)
        } catch {
            return
        }
    }

    func validateRollbackTopology(_ marker: AutoUpdatePendingMarker) throws {
        let targetURL = URL(fileURLWithPath: marker.targetPath)
        let expectedBackup = rollbackBackupPath(binaryURL: targetURL, updateID: marker.updateID)
        guard marker.backupPath == expectedBackup.path else {
            throw AutoUpdateMarkerError.trustedRootInvalid("backup_path_derivation_mismatch")
        }
        let targetDir = targetURL.deletingLastPathComponent()
        guard expectedBackup.deletingLastPathComponent().path == targetDir.path else {
            throw AutoUpdateMarkerError.trustedRootInvalid("backup_dir_mismatch")
        }
        switch (marker.releaseBackupPath, marker.releaseBackupSHA256) {
        case (nil, nil):
            break
        case let (.some(path), .some(_)):
            let expectedReleaseBackup = releaseRollbackBackupPath(binaryURL: targetURL, updateID: marker.updateID)
            guard path == expectedReleaseBackup.path,
                  expectedReleaseBackup.deletingLastPathComponent().path == targetDir.path
            else {
                throw AutoUpdateMarkerError.trustedRootInvalid("release_backup_path_derivation_mismatch")
            }
        default:
            throw AutoUpdateMarkerError.invalidMarker
        }
        try validateTrustedBinaryDirectory(targetDir)
    }

    private func validateReleaseBackup(_ marker: AutoUpdatePendingMarker) throws {
        guard let path = marker.releaseBackupPath,
              let expectedSHA = marker.releaseBackupSHA256
        else {
            if marker.releaseBackupPath != nil || marker.releaseBackupSHA256 != nil {
                throw AutoUpdateMarkerError.invalidMarker
            }
            return
        }
        let backup = URL(fileURLWithPath: path, isDirectory: true)
        try validateReleaseTree(backup)
        guard try releaseTreeSHA256(backup) == expectedSHA else {
            throw AutoUpdateMarkerError.backupCorrupt
        }
        for entry in try fileManager.contentsOfDirectory(
            at: backup,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) where !isOwnedReleaseResource(entry)
            && entry.lastPathComponent != Self.externalBackupDirectoryName
            && entry.lastPathComponent != Self.malibuAppBackupName
            && entry.lastPathComponent != Self.malibuAppStateName {
            throw AutoUpdateMarkerError.backupCorrupt
        }
        try validateExternalLocalMemberBackupIfPresent(in: backup)
        try validateMalibuAppBackupIfPresent(in: backup)
    }

    private func validateReleasePayload(at directory: URL, newBinary: URL) throws {
        try validateReleaseTree(directory)
        let binaryValues = try newBinary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard newBinary.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              newBinary.lastPathComponent == "macprovider-cli",
              binaryValues.isRegularFile == true,
              binaryValues.isSymbolicLink != true
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("release_binary_invalid")
        }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        func isRegular(_ entry: URL) -> Bool {
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }
        func isDirectory(_ entry: URL) -> Bool {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        guard entries.contains(where: { $0.lastPathComponent == "mlx.metallib" && isRegular($0) }),
              entries.contains(where: { $0.lastPathComponent == "THIRD-PARTY-NOTICES.txt" && isRegular($0) }),
              entries.contains(where: { $0.lastPathComponent == CompatibilitySetManifest.fileName && isRegular($0) }),
              entries.contains(where: { $0.pathExtension == "bundle" && isDirectory($0) }),
              let catalog = entries.first(where: { $0.lastPathComponent == "catalog-release" && isDirectory($0) }),
              let localArtifacts = entries.first(where: {
                  $0.lastPathComponent == Self.localArtifactDirectoryName && isDirectory($0)
              })
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("release_payload_incomplete")
        }
        for required in [
            "release.json",
            "trusted-keys.json",
            "autotune-candidates.json",
            "autotune-candidates.json.sig",
            "demand-rank.json",
            "demand-rank.json.sig",
        ] {
            let values = try catalog.appendingPathComponent(required)
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AutoUpdateMarkerError.trustedRootInvalid("release_catalog_incomplete")
            }
        }
        let requiredLocalArtifacts = Set([
            "install.sh",
            "provider-launch-agent.plist.template",
            "updater-rollback.json",
            "watchdog-launch-agent.plist.template",
            "watchdog.sh",
        ])
        let localEntries = try fileManager.contentsOfDirectory(
            at: localArtifacts,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard Set(localEntries.map(\.lastPathComponent)) == requiredLocalArtifacts else {
            throw AutoUpdateMarkerError.trustedRootInvalid("release_local_artifact_members_invalid")
        }
        for entry in localEntries {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AutoUpdateMarkerError.trustedRootInvalid("release_local_artifact_invalid")
            }
        }
        do {
            _ = try CompatibilitySetRollbackPlan.loadValidated(
                from: localArtifacts.appendingPathComponent("updater-rollback.json")
            )
        } catch {
            throw AutoUpdateMarkerError.trustedRootInvalid("release_rollback_plan_invalid")
        }
    }

    private func ownedReleaseResourceEntries(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter(isOwnedReleaseResource)
    }

    private func isOwnedReleaseResource(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "mlx.metallib"
            || name == "THIRD-PARTY-NOTICES.txt"
            || name == CompatibilitySetManifest.fileName
            || name == "catalog-release"
            || name == Self.localArtifactDirectoryName
            || url.pathExtension == "bundle"
    }

    private func removeOwnedReleaseResources(in directory: URL) throws {
        for entry in try ownedReleaseResourceEntries(in: directory) {
            try fileManager.removeItem(at: entry)
        }
    }

    private func preserveExternalLocalMembers(into backupDirectory: URL) throws {
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var records: [CompatibilityExternalMemberRecord] = []
        for member in externalLocalMembers() {
            var info = stat()
            if lstat(member.target.path, &info) != 0 {
                guard errno == ENOENT else {
                    throw AutoUpdateMarkerError.openFailed(member.target.path, errno)
                }
                records.append(.init(member: member.identifier, wasPresent: false, mode: nil, sha256: nil))
                continue
            }
            let opened = try regularFileStatNoFollow(member.target)
            guard (opened.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
                throw AutoUpdateMarkerError.trustedRootInvalid("external_member_writable")
            }
            let mode = Int(opened.st_mode & 0o7777)
            let destination = backupDirectory.appendingPathComponent(member.backupName)
            try fileManager.copyItem(at: member.target, to: destination)
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
            records.append(.init(
                member: member.identifier,
                wasPresent: true,
                mode: mode,
                sha256: try Self.sha256(file: destination)
            ))
        }
        let payload = CompatibilityExternalMemberBackup(schemaVersion: 1, members: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomicWrite(
            data: try encoder.encode(payload),
            finalURL: backupDirectory.appendingPathComponent(Self.externalBackupStateName),
            mode: S_IRUSR | S_IWUSR
        )
    }

    @discardableResult
    func preflightInstalledMalibuAppReplacement() throws -> URL? {
        guard let app = try installedMalibuAppURL() else { return nil }
        try validateMalibuInstallTarget(app, requireWritableParent: true)
        try validateMalibuBundle(app, requireCurrentOwner: false)
        return app
    }

    private func preserveInstalledMalibuApp(into releaseBackup: URL) throws {
        guard let app = try preflightInstalledMalibuAppReplacement() else { return }
        let archive = releaseBackup.appendingPathComponent(Self.malibuAppBackupName)
        try runProcess(
            "/usr/bin/ditto",
            arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, archive.path]
        )
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        let record = MalibuAppRollbackRecord(
            schemaVersion: 1,
            targetPath: app.standardizedFileURL.path,
            archiveSHA256: try Self.sha256(file: archive)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomicWrite(
            data: try encoder.encode(record),
            finalURL: releaseBackup.appendingPathComponent(Self.malibuAppStateName),
            mode: S_IRUSR | S_IWUSR
        )
    }

    private func validateMalibuAppBackupIfPresent(in releaseBackup: URL) throws {
        _ = try validatedMalibuAppRollbackRecord(in: releaseBackup)
    }

    private func validatedMalibuAppRollbackRecord(
        in releaseBackup: URL
    ) throws -> MalibuAppRollbackRecord? {
        let archive = releaseBackup.appendingPathComponent(Self.malibuAppBackupName)
        let stateURL = releaseBackup.appendingPathComponent(Self.malibuAppStateName)
        let archiveExists = fileManager.fileExists(atPath: archive.path)
        let stateExists = fileManager.fileExists(atPath: stateURL.path)
        guard archiveExists == stateExists else { throw AutoUpdateMarkerError.backupCorrupt }
        guard stateExists else { return nil }

        let data = try readRegularFileNoFollow(stateURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["archive_sha256", "schema_version", "target_path"]
        else { throw AutoUpdateMarkerError.backupCorrupt }
        let record = try JSONDecoder().decode(MalibuAppRollbackRecord.self, from: data)
        guard record.schemaVersion == 1,
              record.archiveSHA256.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
              ) != nil,
              malibuAppCandidates().contains(where: {
                  $0.standardizedFileURL.path == record.targetPath
              })
        else { throw AutoUpdateMarkerError.backupCorrupt }
        let archiveInfo = try regularFileStatNoFollow(archive)
        guard (archiveInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              try Self.sha256(file: archive) == record.archiveSHA256
        else { throw AutoUpdateMarkerError.backupCorrupt }
        return record
    }

    private func restoreMalibuAppIfPresent(from releaseBackup: URL) throws {
        guard let record = try validatedMalibuAppRollbackRecord(in: releaseBackup) else { return }
        let target = URL(fileURLWithPath: record.targetPath, isDirectory: true)
        try validateMalibuInstallTarget(target, requireWritableParent: true, requireExistingApp: false)
        let extractionRoot = target.deletingLastPathComponent().appendingPathComponent(
            ".malibu-rollback-extract-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: extractionRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: extractionRoot) }
        try runProcess(
            "/usr/bin/ditto",
            arguments: [
                "-x", "-k",
                releaseBackup.appendingPathComponent(Self.malibuAppBackupName).path,
                extractionRoot.path,
            ]
        )
        let entries = try fileManager.contentsOfDirectory(
            at: extractionRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard entries.count == 1, entries[0].lastPathComponent == "Malibu.app" else {
            throw AutoUpdateMarkerError.backupCorrupt
        }
        let restored = entries[0]
        try validateMalibuBundle(restored, requireCurrentOwner: true)
        try atomicReplaceMalibuApp(staged: restored, target: target)
    }

    @discardableResult
    private func activateMalibuAppIfInstalled(
        _ stagedMalibuApp: URL?,
        from liveDirectory: URL,
        rollbackMarker: AutoUpdatePendingMarker?
    ) throws -> Bool {
        guard let releaseBackupPath = rollbackMarker?.releaseBackupPath else {
            guard stagedMalibuApp == nil else {
                throw AutoUpdateMarkerError.trustedRootInvalid("malibu_rollback_snapshot_missing")
            }
            return false
        }
        let releaseBackup = URL(fileURLWithPath: releaseBackupPath, isDirectory: true)
        guard let record = try validatedMalibuAppRollbackRecord(in: releaseBackup) else {
            guard try installedMalibuAppURL() == nil else {
                throw AutoUpdateMarkerError.trustedRootInvalid("malibu_install_raced_snapshot")
            }
            return false
        }
        guard let stagedMalibuApp else {
            throw AutoUpdateMarkerError.trustedRootInvalid("malibu_staged_bundle_missing")
        }
        guard let targetProviderVersion = rollbackMarker?.targetVersion else {
            throw AutoUpdateMarkerError.invalidMarker
        }
        let targetManifest = try CompatibilitySetManifest.loadValidated(
            from: liveDirectory,
            expectedProviderVersion: targetProviderVersion,
            publicKeyPEM: compatibilityManifestPublicKeyPEM
        )
        let target = URL(fileURLWithPath: record.targetPath, isDirectory: true)
        guard try installedMalibuAppURL()?.standardizedFileURL == target.standardizedFileURL else {
            throw AutoUpdateMarkerError.trustedRootInvalid("malibu_install_changed_after_snapshot")
        }
        try validateMalibuInstallTarget(target, requireWritableParent: true)
        try validateMalibuBundle(
            stagedMalibuApp,
            requireCurrentOwner: true,
            expectedVersion: targetManifest.malibuAppVersion,
            expectedManifest: liveDirectory.appendingPathComponent(CompatibilitySetManifest.fileName)
        )

        let staging = target.deletingLastPathComponent().appendingPathComponent(
            ".Malibu.app.activation-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        try runProcess("/usr/bin/ditto", arguments: [stagedMalibuApp.path, staging.path])
        try validateMalibuBundle(
            staging,
            requireCurrentOwner: true,
            expectedVersion: targetManifest.malibuAppVersion,
            expectedManifest: liveDirectory.appendingPathComponent(CompatibilitySetManifest.fileName)
        )
        try atomicReplaceMalibuApp(staged: staging, target: target)
        return true
    }

    private func installedMalibuAppURL() throws -> URL? {
        var installed: [URL] = []
        for candidate in malibuAppCandidates() {
            var info = stat()
            if lstat(candidate.path, &info) != 0 {
                guard errno == ENOENT else {
                    throw AutoUpdateMarkerError.openFailed(candidate.path, errno)
                }
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw AutoUpdateMarkerError.trustedRootInvalid("malibu_install_not_directory")
            }
            installed.append(candidate)
        }
        guard installed.count <= 1 else {
            throw AutoUpdateMarkerError.trustedRootInvalid("multiple_malibu_installations")
        }
        return installed.first
    }

    private func malibuAppCandidates() -> [URL] {
        if let malibuAppCandidateOverride {
            return malibuAppCandidateOverride
        }
        let perUser = homeDirectory.appendingPathComponent("Applications/Malibu.app", isDirectory: true)
        guard homeDirectory.standardizedFileURL
            == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        else {
            return [perUser]
        }
        return [URL(fileURLWithPath: "/Applications/Malibu.app", isDirectory: true), perUser]
    }

    private func validateMalibuInstallTarget(
        _ target: URL,
        requireWritableParent: Bool,
        requireExistingApp: Bool = true
    ) throws {
        let canonicalTarget = target.standardizedFileURL
        guard canonicalTarget.path == target.path,
              canonicalTarget.lastPathComponent == "Malibu.app",
              malibuAppCandidates().contains(where: {
                  $0.standardizedFileURL == canonicalTarget
              })
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("malibu_install_path_invalid")
        }
        let parent = canonicalTarget.deletingLastPathComponent()
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              (parentInfo.st_mode & S_IFMT) != S_IFLNK,
              (parentInfo.st_mode & S_IWOTH) == 0
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("malibu_install_parent_untrusted")
        }
        if parent.path == "/Applications" {
            guard parentInfo.st_uid == 0 else {
                throw AutoUpdateMarkerError.trustedRootInvalid("applications_owner_invalid")
            }
        } else {
            guard parentInfo.st_uid == getuid(),
                  (parentInfo.st_mode & S_IWGRP) == 0
            else {
                throw AutoUpdateMarkerError.trustedRootInvalid("malibu_install_parent_untrusted")
            }
        }
        if requireWritableParent, access(parent.path, W_OK) != 0 {
            throw AutoUpdateMarkerError.trustedRootInvalid("malibu_app_requires_authorized_installer")
        }
        guard requireExistingApp else { return }
        var appInfo = stat()
        guard lstat(canonicalTarget.path, &appInfo) == 0,
              (appInfo.st_mode & S_IFMT) == S_IFDIR,
              (appInfo.st_mode & S_IFMT) != S_IFLNK,
              (appInfo.st_mode & S_IWOTH) == 0
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("malibu_install_untrusted")
        }
    }

    private func validateMalibuBundle(
        _ app: URL,
        requireCurrentOwner: Bool,
        expectedVersion: String? = nil,
        expectedManifest: URL? = nil
    ) throws {
        var rootInfo = stat()
        guard lstat(app.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              (rootInfo.st_mode & S_IFMT) != S_IFLNK,
              (rootInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              !requireCurrentOwner || rootInfo.st_uid == getuid()
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("malibu_bundle_root_invalid")
        }
        let resolvedRoot = app.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard let enumerator = fileManager.enumerator(at: app, includingPropertiesForKeys: nil) else {
            throw AutoUpdateMarkerError.trustedRootInvalid("malibu_bundle_enumeration_failed")
        }
        for case let entry as URL in enumerator {
            var info = stat()
            guard lstat(entry.path, &info) == 0,
                  (info.st_mode & (S_IWGRP | S_IWOTH)) == 0,
                  !requireCurrentOwner || info.st_uid == getuid()
            else {
                throw AutoUpdateMarkerError.trustedRootInvalid("malibu_bundle_entry_invalid")
            }
            let type = info.st_mode & S_IFMT
            switch type {
            case S_IFDIR:
                break
            case S_IFREG:
                guard info.st_nlink == 1 else {
                    throw AutoUpdateMarkerError.trustedRootInvalid("malibu_bundle_hardlink")
                }
            case S_IFLNK:
                let resolved = entry.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved.hasPrefix(rootPrefix) else {
                    throw AutoUpdateMarkerError.trustedRootInvalid("malibu_bundle_symlink_escape")
                }
            default:
                throw AutoUpdateMarkerError.trustedRootInvalid("malibu_bundle_entry_type")
            }
        }

        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL),
            format: nil
        ) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "tech.malibu.app"
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("malibu_bundle_identity_invalid")
        }
        if let expectedVersion {
            guard info["CFBundleShortVersionString"] as? String == expectedVersion else {
                throw AutoUpdateMarkerError.trustedRootInvalid("malibu_bundle_version_mismatch")
            }
        }
        if let expectedManifest {
            let embedded = app.appendingPathComponent(
                "Contents/Resources/\(CompatibilitySetManifest.fileName)"
            )
            guard try Data(contentsOf: embedded) == Data(contentsOf: expectedManifest) else {
                throw AutoUpdateMarkerError.trustedRootInvalid("malibu_manifest_mismatch")
            }
        }
    }

    private func atomicReplaceMalibuApp(staged: URL, target: URL) throws {
        try fsyncTree(staged)
        let parent = target.deletingLastPathComponent()
        var targetInfo = stat()
        if lstat(target.path, &targetInfo) == 0 {
            guard (targetInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw AutoUpdateMarkerError.trustedRootInvalid("malibu_install_not_directory")
            }
            if renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) != 0 {
                throw AutoUpdateMarkerError.writeFailed(target.path, errno)
            }
            fsyncDirectory(parent)
            do {
                try fileManager.removeItem(at: staged)
            } catch {
                throw AutoUpdateMarkerError.writeFailed(staged.path, EIO)
            }
        } else {
            guard errno == ENOENT else {
                throw AutoUpdateMarkerError.openFailed(target.path, errno)
            }
            if rename(staged.path, target.path) != 0 {
                throw AutoUpdateMarkerError.writeFailed(target.path, errno)
            }
        }
        fsyncDirectory(parent)
    }

    private func runProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AutoUpdateMarkerError.trustedRootInvalid("malibu_archive_process_failed")
        }
        guard process.terminationStatus == 0 else {
            throw AutoUpdateMarkerError.trustedRootInvalid("malibu_archive_process_failed")
        }
    }

    private func validateExternalLocalMemberBackupIfPresent(in releaseBackup: URL) throws {
        let backupDirectory = releaseBackup.appendingPathComponent(
            Self.externalBackupDirectoryName,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: backupDirectory.path) else { return }
        _ = try validatedExternalLocalMemberBackup(in: backupDirectory)
    }

    private func validatedExternalLocalMemberBackup(
        in backupDirectory: URL
    ) throws -> CompatibilityExternalMemberBackup {
        let stateURL = backupDirectory.appendingPathComponent(Self.externalBackupStateName)
        let data = try readRegularFileNoFollow(stateURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["members", "schema_version"],
              object["schema_version"] as? Int == 1,
              let rawMembers = object["members"] as? [[String: Any]]
        else { throw AutoUpdateMarkerError.backupCorrupt }
        for record in rawMembers {
            let keys = Set(record.keys)
            guard keys == ["member", "was_present"]
                    || keys == ["member", "mode", "sha256", "was_present"]
            else {
                throw AutoUpdateMarkerError.backupCorrupt
            }
        }
        let state = try JSONDecoder().decode(CompatibilityExternalMemberBackup.self, from: data)
        let members = externalLocalMembers()
        guard state.schemaVersion == 1,
              state.members.map(\.member) == members.map(\.identifier)
        else { throw AutoUpdateMarkerError.backupCorrupt }

        var expectedNames: Set<String> = [Self.externalBackupStateName]
        for (record, member) in zip(state.members, members) {
            let backup = backupDirectory.appendingPathComponent(member.backupName)
            if record.wasPresent {
                guard let mode = record.mode, (0...0o7777).contains(mode),
                      let digest = record.sha256,
                      digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
                else { throw AutoUpdateMarkerError.backupCorrupt }
                let info = try regularFileStatNoFollow(backup)
                guard Int(info.st_mode & 0o7777) == mode,
                      try Self.sha256(file: backup) == digest
                else { throw AutoUpdateMarkerError.backupCorrupt }
                expectedNames.insert(member.backupName)
            } else {
                guard record.mode == nil, record.sha256 == nil,
                      !fileManager.fileExists(atPath: backup.path)
                else { throw AutoUpdateMarkerError.backupCorrupt }
            }
        }
        let actualNames = try Set(fileManager.contentsOfDirectory(atPath: backupDirectory.path))
        guard actualNames == expectedNames else { throw AutoUpdateMarkerError.backupCorrupt }
        return state
    }

    private func restoreExternalLocalMembersIfPresent(from releaseBackup: URL) throws {
        let backupDirectory = releaseBackup.appendingPathComponent(
            Self.externalBackupDirectoryName,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: backupDirectory.path) else { return }
        let state = try validatedExternalLocalMemberBackup(in: backupDirectory)
        for (record, member) in zip(state.members, externalLocalMembers()) {
            try ensureExternalMemberParent(member.target.deletingLastPathComponent())
            if record.wasPresent {
                guard let mode = record.mode else { throw AutoUpdateMarkerError.backupCorrupt }
                try atomicCopyNoFollow(
                    from: backupDirectory.appendingPathComponent(member.backupName),
                    to: member.target,
                    mode: mode
                )
            } else if fileManager.fileExists(atPath: member.target.path) {
                _ = try regularFileStatNoFollow(member.target)
                try fileManager.removeItem(at: member.target)
                fsyncDirectory(member.target.deletingLastPathComponent())
            }
        }
    }

    private func activateExternalLocalMembers(
        from artifactDirectory: URL,
        installDirectory: URL,
        cutoverCheckpoint: ((CompatibilitySetCutoverPhase) throws -> Void)?
    ) throws {
        let coordinatorHost = try installedWatchdogCoordinatorHost()
        let staging = installDirectory.appendingPathComponent(
            ".macprovider-cli.external-activation-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: staging) }

        let replacements = [
            "__HOME__": xmlEscape(homeDirectory.path),
            "__INSTALL_DIR__": xmlEscape(installDirectory.path),
            "__COORDINATOR_HOST__": xmlEscape(coordinatorHost),
        ]
        let providerPlist = try renderPlistTemplate(
            artifactDirectory.appendingPathComponent("provider-launch-agent.plist.template"),
            replacements: replacements
        )
        try validateProviderPlist(providerPlist, installDirectory: installDirectory)
        let watchdogPlist = try renderPlistTemplate(
            artifactDirectory.appendingPathComponent("watchdog-launch-agent.plist.template"),
            replacements: replacements
        )
        try validateWatchdogPlist(watchdogPlist, installDirectory: installDirectory, coordinatorHost: coordinatorHost)

        let stagedProviderPlist = staging.appendingPathComponent(Self.providerPlistName)
        let stagedWatchdogPlist = staging.appendingPathComponent(Self.watchdogPlistName)
        try providerPlist.write(to: stagedProviderPlist)
        try watchdogPlist.write(to: stagedWatchdogPlist)
        let stagedWatchdog = artifactDirectory.appendingPathComponent("watchdog.sh")

        for target in [providerPlistURL, watchdogScriptURL, watchdogPlistURL] {
            try ensureExternalMemberParent(target.deletingLastPathComponent())
        }
        try atomicCopyNoFollow(from: stagedWatchdog, to: watchdogScriptURL, mode: 0o755)
        try cutoverCheckpoint?(.watchdogScriptActivated)
        try atomicCopyNoFollow(from: stagedProviderPlist, to: providerPlistURL, mode: 0o644)
        try cutoverCheckpoint?(.providerPlistActivated)
        try atomicCopyNoFollow(from: stagedWatchdogPlist, to: watchdogPlistURL, mode: 0o644)
        try cutoverCheckpoint?(.watchdogPlistActivated)
    }

    private func renderPlistTemplate(_ url: URL, replacements: [String: String]) throws -> Data {
        guard var rendered = String(data: try readRegularFileNoFollow(url), encoding: .utf8) else {
            throw AutoUpdateMarkerError.trustedRootInvalid("plist_template_utf8_invalid")
        }
        for (token, replacement) in replacements {
            guard rendered.contains(token) else {
                if token == "__COORDINATOR_HOST__", url.lastPathComponent == "provider-launch-agent.plist.template" {
                    continue
                }
                throw AutoUpdateMarkerError.trustedRootInvalid("plist_template_token_missing")
            }
            rendered = rendered.replacingOccurrences(of: token, with: replacement)
        }
        guard !rendered.contains("__") else {
            throw AutoUpdateMarkerError.trustedRootInvalid("plist_template_token_unresolved")
        }
        return Data(rendered.utf8)
    }

    private func installedWatchdogCoordinatorHost() throws -> String {
        guard fileManager.fileExists(atPath: watchdogPlistURL.path) else {
            return "coordinator.streamvc.live"
        }
        let data = try readRegularFileNoFollow(watchdogPlistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let environment = plist["EnvironmentVariables"] as? [String: Any],
              let host = environment["MACPROVIDER_COORDINATOR_HOST"] as? String,
              host.range(of: #"^[A-Za-z0-9.-]{1,253}$"#, options: .regularExpression) != nil
        else { throw AutoUpdateMarkerError.trustedRootInvalid("installed_watchdog_plist_invalid") }
        return host
    }

    private func validateProviderPlist(_ data: Data, installDirectory: URL) throws {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == "live.streamvc.macprovider",
              plist["ProgramArguments"] as? [String] == [
                  installDirectory.appendingPathComponent("macprovider-cli").path,
                  "serve", "--config", homeDirectory.appendingPathComponent(".config/macprovider/config.yaml").path,
              ],
              plist["WorkingDirectory"] as? String == installDirectory.path
        else { throw AutoUpdateMarkerError.trustedRootInvalid("rendered_provider_plist_invalid") }
    }

    private func validateWatchdogPlist(_ data: Data, installDirectory: URL, coordinatorHost: String) throws {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == "live.streamvc.macprovider-watchdog",
              plist["ProgramArguments"] as? [String] == [watchdogScriptURL.path],
              let environment = plist["EnvironmentVariables"] as? [String: Any],
              environment["MACPROVIDER_BINARY_PATH"] as? String == installDirectory.appendingPathComponent("macprovider-cli").path,
              environment["MACPROVIDER_COORDINATOR_HOST"] as? String == coordinatorHost
        else { throw AutoUpdateMarkerError.trustedRootInvalid("rendered_watchdog_plist_invalid") }
    }

    private func externalLocalMembers() -> [(identifier: String, target: URL, backupName: String)] {
        [
            ("launchd", providerPlistURL, Self.providerPlistName),
            ("watchdog_script", watchdogScriptURL, Self.watchdogScriptName),
            ("watchdog_plist", watchdogPlistURL, Self.watchdogPlistName),
        ]
    }

    private func ensureExternalMemberParent(_ directory: URL) throws {
        let homePath = homeDirectory.standardizedFileURL.path
        let targetPath = directory.standardizedFileURL.path
        guard targetPath.hasPrefix(homePath + "/") else {
            throw AutoUpdateMarkerError.trustedRootInvalid("external_member_outside_home")
        }
        var current = homeDirectory
        let suffix = String(targetPath.dropFirst(homePath.count + 1))
        for component in suffix.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            try ensureTrustedDirectory(current)
        }
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    func removeRollbackBackups(_ marker: AutoUpdatePendingMarker) {
        try? fileManager.removeItem(atPath: marker.backupPath)
        if let releaseBackupPath = marker.releaseBackupPath {
            try? fileManager.removeItem(atPath: releaseBackupPath)
        }
    }

    private func validateReleaseTree(_ rootURL: URL) throws {
        var rootStat = stat()
        guard lstat(rootURL.path, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR,
              rootStat.st_uid == getuid(),
              (rootStat.st_mode & (S_IWGRP | S_IWOTH)) == 0
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("release_tree_root_invalid")
        }
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw AutoUpdateMarkerError.trustedRootInvalid("release_tree_enumeration_failed")
        }
        for case let entry as URL in enumerator {
            var st = stat()
            guard lstat(entry.path, &st) == 0 else {
                throw AutoUpdateMarkerError.trustedRootInvalid("release_tree_entry_lstat_failed")
            }
            guard (st.st_mode & S_IFMT) != S_IFLNK else {
                throw AutoUpdateMarkerError.trustedRootInvalid("release_tree_symlink")
            }
            guard st.st_uid == getuid() else {
                throw AutoUpdateMarkerError.trustedRootInvalid("release_tree_wrong_owner")
            }
            guard (st.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
                throw AutoUpdateMarkerError.trustedRootInvalid("release_tree_writable")
            }
            guard (st.st_mode & S_IFMT) == S_IFDIR
                    || ((st.st_mode & S_IFMT) == S_IFREG && st.st_nlink == 1)
            else {
                throw AutoUpdateMarkerError.trustedRootInvalid("release_tree_type_or_link_invalid")
            }
        }
    }

    private func validateReleaseEntry(_ entry: URL) throws {
        var st = stat()
        guard lstat(entry.path, &st) == 0,
              (st.st_mode & S_IFMT) != S_IFLNK,
              st.st_uid == getuid(),
              (st.st_mode & (S_IWGRP | S_IWOTH)) == 0
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("release_entry_invalid")
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            try validateReleaseTree(entry)
        } else if (st.st_mode & S_IFMT) != S_IFREG || st.st_nlink != 1 {
            throw AutoUpdateMarkerError.trustedRootInvalid("release_entry_invalid")
        }
    }

    private func releaseTreeSHA256(_ rootURL: URL) throws -> String {
        try validateReleaseTree(rootURL)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw AutoUpdateMarkerError.trustedRootInvalid("release_tree_enumeration_failed")
        }
        var records: [(String, Data)] = []
        let resolvedRootPath = rootURL.resolvingSymlinksInPath().path
        let prefix = resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/"
        for case let entry as URL in enumerator {
            var st = stat()
            let resolvedEntryPath = entry.resolvingSymlinksInPath().path
            guard lstat(entry.path, &st) == 0, resolvedEntryPath.hasPrefix(prefix) else {
                throw AutoUpdateMarkerError.trustedRootInvalid("release_tree_entry_invalid")
            }
            let relative = String(resolvedEntryPath.dropFirst(prefix.count))
            guard !relative.isEmpty, !relative.contains("\0"), !relative.contains("\n") else {
                throw AutoUpdateMarkerError.trustedRootInvalid("release_tree_path_invalid")
            }
            let mode = Int(st.st_mode & 0o7777)
            let record: String
            if (st.st_mode & S_IFMT) == S_IFDIR {
                record = "d\0\(relative)\0\(mode)\0"
            } else if (st.st_mode & S_IFMT) == S_IFREG {
                record = "f\0\(relative)\0\(mode)\0\(st.st_size)\0\(try Self.sha256(file: entry))\0"
            } else {
                throw AutoUpdateMarkerError.trustedRootInvalid("release_tree_entry_invalid")
            }
            records.append((relative, Data(record.utf8)))
        }
        var canonical = Data()
        for record in records.sorted(by: { $0.0 < $1.0 }) {
            canonical.append(record.1)
        }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    private func fsyncTree(_ rootURL: URL) throws {
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            throw AutoUpdateMarkerError.trustedRootInvalid("release_tree_enumeration_failed")
        }
        var directories = [rootURL]
        for case let entry as URL in enumerator {
            var st = stat()
            guard lstat(entry.path, &st) == 0 else {
                throw AutoUpdateMarkerError.openFailed(entry.path, errno)
            }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                directories.append(entry)
            } else if (st.st_mode & S_IFMT) == S_IFREG {
                let fd = open(entry.path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw AutoUpdateMarkerError.openFailed(entry.path, errno) }
                fsync(fd)
                close(fd)
            }
        }
        for directory in directories.reversed() {
            fsyncDirectory(directory)
        }
    }

    func updateSignedPolicy(minimum: String?, revoked: [String]) async throws {
        var policy = (try? readPolicy()) ?? SignedPolicy()
        if let minimum, !minimum.isEmpty,
           policy.persistedMinimum.isEmpty || SelfUpdate.compareSemver(policy.persistedMinimum, minimum) == .orderedAscending {
            policy.persistedMinimum = minimum
        }
        policy.persistedRevoked.formUnion(revoked)
        do {
            let data = try JSONEncoder().encode(policy)
            try atomicWrite(data: data, finalURL: policyURL, mode: S_IRUSR | S_IWUSR)
        } catch {
            let marker = try? readPending()
            await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
                updateID: marker?.updateID ?? UUID().uuidString.lowercased(),
                currentVersion: "",
                targetVersion: marker?.targetVersion ?? "<unknown>",
                phase: .swap,
                outcome: .failure,
                reason: "signed_policy_persist_failed",
                attempt: 1,
                failureClass: .other
            ))
            SessionAutoupdateGate.shared.disable(reason: "signed_policy_persist_failed")
            throw AutoUpdateSignedPolicyPersistError(underlying: String(describing: error).prefix(128).description)
        }
    }

    func effectivePolicy(localMinimum: String? = nil, localRevoked: [String] = []) -> (minimum: String?, revoked: Set<String>) {
        let policy = (try? readPolicy()) ?? SignedPolicy()
        let minimum = [localMinimum, policy.persistedMinimum].compactMap { value in
            value?.isEmpty == false ? value : nil
        }.max { SelfUpdate.compareSemver($0, $1) == .orderedAscending }
        return (minimum, policy.persistedRevoked.union(localRevoked))
    }

    func ensureRollbackTargetAllowed(_ marker: AutoUpdatePendingMarker) throws {
        guard let previousVersion = marker.previousVersion else { return }
        let policy = effectivePolicy()
        if let minimum = policy.minimum,
           SelfUpdate.compareSemver(previousVersion, minimum) == .orderedAscending {
            throw AutoUpdateMarkerError.rollbackTargetDisallowed
        }
        if policy.revoked.contains(previousVersion) {
            throw AutoUpdateMarkerError.rollbackTargetDisallowed
        }
    }

    func validateMarker(_ pending: AutoUpdatePendingMarker) throws {
        let uuidV4 = #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#
        guard pending.updateID.range(of: uuidV4, options: .regularExpression) != nil else {
            throw AutoUpdateMarkerError.invalidMarker
        }
        if let commitOwner = pending.commitOwner,
           commitOwner != "coordinator", commitOwner != "self_update" {
            throw AutoUpdateMarkerError.invalidMarker
        }
        switch (pending.targetCompatibilitySetID, pending.targetCompatibilitySetSHA256) {
        case (nil, nil):
            break
        case let (.some(identifier), .some(digest)):
            guard CompatibilitySetManifest.isCanonicalCompatibilitySetID(identifier),
                  digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
            else { throw AutoUpdateMarkerError.invalidMarker }
        default:
            throw AutoUpdateMarkerError.invalidMarker
        }
        switch (pending.discoveryHeadSequence, pending.discoveryHeadSHA256) {
        case (nil, nil):
            break
        case let (.some(sequence), .some(digest)):
            guard sequence > 0,
                  digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
            else { throw AutoUpdateMarkerError.invalidMarker }
        default:
            throw AutoUpdateMarkerError.invalidMarker
        }
        if let mode = pending.updateAuthorityMode,
           mode != "coordinator_recommendation", mode != "signed_release" {
            throw AutoUpdateMarkerError.invalidMarker
        }
        if pending.updateAuthorityMode == "signed_release" {
            guard pending.discoveryHeadSequence != nil,
                  pending.discoveryHeadSHA256 != nil,
                  pending.targetCompatibilitySetID != nil,
                  pending.targetCompatibilitySetSHA256 != nil
            else { throw AutoUpdateMarkerError.invalidMarker }
        }
        switch (
            pending.previousVersion,
            pending.previousCompatibilitySetID,
            pending.previousCompatibilitySetSHA256,
            pending.transactionState
        ) {
        case (nil, nil, nil, nil):
            break
        case let (.some(version), .some(identifier), .some(digest), .some(state)):
            guard pending.targetCompatibilitySetID != nil,
                  pending.releaseBackupPath != nil,
                  (try? AutoUpdateRecommendation.validate(version).normalized) == version,
                  CompatibilitySetManifest.isCanonicalCompatibilitySetID(identifier),
                  digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  CompatibilitySetTransactionState(rawValue: state.rawValue) != nil
            else { throw AutoUpdateMarkerError.invalidMarker }
        default:
            throw AutoUpdateMarkerError.invalidMarker
        }
        guard let normalized = try? AutoUpdateRecommendation.validate(pending.targetVersion).normalized,
              normalized == pending.targetVersion
        else {
            throw AutoUpdateMarkerError.invalidMarker
        }
        guard isCanonicalAbsolutePath(pending.targetPath),
              isCanonicalAbsolutePath(pending.backupPath)
        else {
            throw AutoUpdateMarkerError.invalidMarker
        }
        guard pending.size >= 0, pending.size <= 1024 * 1024 * 1024 else {
            throw AutoUpdateMarkerError.invalidMarker
        }
        guard (0 ... 0o7777).contains(pending.mode) else {
            throw AutoUpdateMarkerError.invalidMarker
        }
        guard pending.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw AutoUpdateMarkerError.invalidMarker
        }
        switch (pending.releaseBackupPath, pending.releaseBackupSHA256) {
        case (nil, nil):
            break
        case let (.some(path), .some(sha)):
            guard isCanonicalAbsolutePath(path),
                  sha.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
            else {
                throw AutoUpdateMarkerError.invalidMarker
            }
        default:
            throw AutoUpdateMarkerError.invalidMarker
        }
        guard let deadline = ISO8601DateFormatter.autoupdate.date(from: pending.markerDeadline),
              pending.markerDeadline.hasSuffix("Z")
        else {
            throw AutoUpdateMarkerError.invalidMarker
        }
        let now = Date()
        let postStartWindowSeconds: TimeInterval = 60
        let futureToleranceSeconds: TimeInterval = postStartWindowSeconds + 30 * 60
        guard deadline <= now.addingTimeInterval(futureToleranceSeconds)
        else {
            throw AutoUpdateMarkerError.invalidMarker
        }
    }

    func successSentinels(in binaryDirectory: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(at: binaryDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return contents.filter { $0.lastPathComponent.hasPrefix(".macprovider-cli.success-") }
    }

    func rollbackBackups(in binaryDirectory: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(at: binaryDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return contents.filter {
            $0.lastPathComponent.hasPrefix(".macprovider-cli.rollback-")
                || $0.lastPathComponent.hasPrefix(".macprovider-cli.release-rollback-")
        }
    }

    func readSuccessSentinel(_ url: URL) throws -> (
        updateID: String,
        binaryVersion: String,
        targetCompatibilitySetID: String?,
        targetCompatibilitySetSHA256: String?
    ) {
        let data = try readRegularFileNoFollow(url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updateID = object["update_id"] as? String,
              let binaryVersion = object["binary_version"] as? String,
              updateID.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
        else {
            throw AutoUpdateMarkerError.invalidMarker
        }
        let setID = object["target_compatibility_set_id"] as? String
        let setSHA = object["target_compatibility_set_sha256"] as? String
        if let setID, !setID.isEmpty,
           !CompatibilitySetManifest.isCanonicalCompatibilitySetID(setID) {
            throw AutoUpdateMarkerError.invalidMarker
        }
        if let setSHA, !setSHA.isEmpty,
           setSHA.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) == nil {
            throw AutoUpdateMarkerError.invalidMarker
        }
        return (
            updateID,
            binaryVersion,
            setID?.isEmpty == true ? nil : setID,
            setSHA?.isEmpty == true ? nil : setSHA
        )
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
        try rejectWritableACL(url)
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

    func atomicCopyNoFollow(from source: URL, to finalURL: URL, mode: Int) throws {
        try validateTrustedBinaryDirectory(finalURL.deletingLastPathComponent())
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

    func validateTrustedBinaryDirectory(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw AutoUpdateMarkerError.trustedRootInvalid("binary_dir_lstat_failed")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR,
              (st.st_mode & S_IFMT) != S_IFLNK,
              st.st_uid == getuid(),
              (st.st_mode & (S_IWGRP | S_IWOTH)) == 0
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("binary_dir_untrusted")
        }
        try rejectWritableACL(url)
    }

    private func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasSuffix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0 == "." || $0 == ".." }
    }

    private func regularFileStatNoFollow(_ url: URL) throws -> stat {
        var st = stat()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AutoUpdateMarkerError.openFailed(url.path, errno) }
        defer { close(fd) }
        guard fstat(fd, &st) == 0 else {
            throw AutoUpdateMarkerError.openFailed(url.path, errno)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              st.st_nlink == 1
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("regular_file_invalid")
        }
        return st
    }

    private func readRegularFileNoFollow(_ url: URL) throws -> Data {
        var st = stat()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AutoUpdateMarkerError.openFailed(url.path, errno) }
        defer { close(fd) }
        guard fstat(fd, &st) == 0 else {
            throw AutoUpdateMarkerError.openFailed(url.path, errno)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              st.st_nlink == 1
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("regular_file_invalid")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                throw AutoUpdateMarkerError.openFailed(url.path, errno)
            }
            if n == 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private func rejectWritableACL(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ls")
        process.arguments = ["-led", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let currentUser = NSUserName()
        for line in output.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.range(of: #"^[0-9]+:"#, options: .regularExpression) != nil else { continue }
            let lower = trimmed.lowercased()
            guard lower.contains("write") || lower.contains("append") || lower.contains("add_file") else { continue }
            guard lower.contains("user:\(currentUser.lowercased()) ") || lower.contains("user:\(currentUser.lowercased()):") else {
                throw AutoUpdateMarkerError.trustedRootInvalid("acl_write_grant")
            }
        }
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
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AutoUpdateMarkerError.openFailed(file.path, errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_nlink == 1
        else {
            throw AutoUpdateMarkerError.trustedRootInvalid("regular_file_invalid")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                throw AutoUpdateMarkerError.openFailed(file.path, errno)
            }
            if n == 0 { break }
            data.append(buffer, count: n)
        }
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
    static var autoupdate: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
