import Darwin
import Foundation
import MacProviderCore

enum AutoUpdateError: Error, CustomStringConvertible {
    case trustStateLost(String)
    case drainTimeout
    case observerUnavailable
    case unsupportedInstallTopology
    case currentBinaryUnknown

    var description: String {
        switch self {
        case let .trustStateLost(reason): return "autoupdate trust state lost: \(reason)"
        case .drainTimeout: return "autoupdate drain timed out"
        case .observerUnavailable: return "rollback observer unavailable"
        case .unsupportedInstallTopology: return "unsupported install topology"
        case .currentBinaryUnknown: return "current binary unknown"
        }
    }
}

private final class AutoUpdateCommitTracker {
    var marker: AutoUpdatePendingMarker?
    var committedMarker = false
    var committedBackup = false
    var committedSwap = false
}

struct AutoUpdater: Sendable {
    typealias TrustProvider = @Sendable () async -> AutoUpdateTrustState
    typealias Drain = @Sendable (_ target: String) async throws -> Bool
    typealias SendReady = @Sendable () async throws -> Void
    typealias Restart = @Sendable () throws -> Void
    typealias Availability = @Sendable () -> Bool

    let config: AppConfig
    let currentVersion: String
    let providerStatus: ProviderStatus
    let releasesAPIURL: String?
    let markerStore: AutoUpdateMarkerStore
    let session: URLSession
    let trustProvider: TrustProvider
    let drain: Drain
    let sendReady: SendReady
    let restartLaunchd: Restart
    let currentBinaryURL: @Sendable () -> URL?
    let rollbackObserverAvailable: Availability
    let launchdProviderAvailable: Availability

    init(
        config: AppConfig,
        currentVersion: String,
        providerStatus: ProviderStatus,
        releasesAPIURL: String? = nil,
        markerStore: AutoUpdateMarkerStore = AutoUpdateMarkerStore(),
        session: URLSession = .shared,
        trustProvider: @escaping TrustProvider,
        drain: @escaping Drain,
        sendReady: @escaping SendReady,
        restartLaunchd: @escaping Restart = { try AutoUpdater.restartLaunchdIfInstalled() },
        currentBinaryURL: @escaping @Sendable () -> URL? = { Bundle.main.executableURL },
        rollbackObserverAvailable: @escaping Availability = { AutoUpdater.defaultRollbackObserverAvailable() },
        launchdProviderAvailable: @escaping Availability = { AutoUpdater.defaultLaunchdProviderAvailable() }
    ) {
        self.config = config
        self.currentVersion = currentVersion
        self.providerStatus = providerStatus
        self.releasesAPIURL = releasesAPIURL
        self.markerStore = markerStore
        self.session = session
        self.trustProvider = trustProvider
        self.drain = drain
        self.sendReady = sendReady
        self.restartLaunchd = restartLaunchd
        self.currentBinaryURL = currentBinaryURL
        self.rollbackObserverAvailable = rollbackObserverAvailable
        self.launchdProviderAvailable = launchdProviderAvailable
    }

    func handleCoordinatorRecommendation(_ rawRecommended: String) async {
        let updateID = UUID().uuidString.lowercased()
        let entryTrust = await trustProvider()
        guard entryTrust.isEligible else {
            await record(updateID: updateID, target: "<notify-only>", phase: .eligibility, outcome: .skipped, reason: entryTrust.lossReason, attempt: 1)
            return
        }
        let validated: AutoUpdateRecommendation
        do {
            validated = try AutoUpdateRecommendation.validate(rawRecommended)
        } catch let AutoUpdateValidationError.versionTooLong(sha) {
            await record(updateID: updateID, target: "<redacted>", phase: .eligibility, outcome: .failure, reason: "version_too_long", attempt: 1, failure: .recommendedVersionInvalid, sha: sha)
            return
        } catch AutoUpdateValidationError.componentTooLong {
            await record(updateID: updateID, target: "<invalid>", phase: .eligibility, outcome: .failure, reason: "version_component_too_long", attempt: 1, failure: .recommendedVersionInvalid)
            return
        } catch {
            await record(updateID: updateID, target: "<invalid>", phase: .eligibility, outcome: .failure, reason: "recommended_version_invalid", attempt: 1, failure: .recommendedVersionInvalid)
            return
        }

        let target = validated.normalized
        await record(updateID: updateID, target: target, phase: .detection, outcome: .inProgress, reason: "recommended_binary_version_detected", attempt: 1)
        let commitTracker = AutoUpdateCommitTracker()

        guard SelfUpdate.compareSemver(currentVersion, target) == .orderedAscending else {
            await record(updateID: updateID, target: target, phase: .eligibility, outcome: .noop, reason: "target_not_newer", attempt: 1)
            return
        }
        guard AutoUpdateConfig.enabled(config) else {
            print("A newer version is available (v\(target)), but autoupdate is disabled.")
            await record(updateID: updateID, target: target, phase: .eligibility, outcome: .skipped, reason: "autoupdate_disabled", attempt: 1)
            return
        }
        do {
            let policy = markerStore.effectivePolicy()
            if let minimum = policy.minimum, SelfUpdate.compareSemver(target, minimum) == .orderedAscending || policy.revoked.contains(target) {
                await fail(updateID: updateID, target: target, phase: .eligibility, failure: .targetRevokedOrBelowMinimum, reason: "target_revoked_or_below_minimum")
                return
            }
            guard launchdProviderAvailable() else {
                await fail(updateID: updateID, target: target, phase: .eligibility, failure: .unsupportedInstallTopology, reason: "unsupported_install_topology")
                return
            }
            guard rollbackObserverAvailable() else {
                await fail(updateID: updateID, target: target, phase: .eligibility, failure: .rollbackObserverUnavailable, reason: "rollback_observer_unavailable")
                return
            }
            try markerStore.ensureTrustedRoot()
            if let activeCooldown = markerStore.activeCooldown(target: target) {
                await record(updateID: updateID, target: target, phase: .cooldown, outcome: .skipped, reason: "cooldown_\(activeCooldown.failureClass.rawValue)_until_\(ISO8601DateFormatter.autoupdate.string(from: activeCooldown.until))", attempt: activeCooldown.attempt)
                return
            }
            try await ensureEligible(phase: .eligibility)
            let lock = try markerStore.acquireLock()
            _ = lock
            let update = SelfUpdate(currentVersion: currentVersion, releasesAPIURL: releasesAPIURL, session: session)
            let release: GitHubRelease
            do {
                try await ensureEligible(phase: .download)
                release = try await update.resolveReleaseByTags(normalizedTarget: target)
            } catch UpdateError.releaseNotFound {
                await fail(updateID: updateID, target: target, phase: .download, failure: .targetReleaseNotFound, reason: "target_release_not_found")
                return
            }
            let prepared: PreparedSelfUpdate
            do {
                prepared = try await update.prepareValidatedUpdate(from: release)
            } catch {
                let failure = Self.failureClass(for: error)
                await fail(updateID: updateID, target: target, phase: Self.phase(for: error), failure: failure, reason: Self.redactedReason(for: error))
                return
            }
            defer { prepared.cleanup() }
            try await ensureEligible(phase: .drain)
            let drained = try await drain(target)
            guard drained else {
                await fail(updateID: updateID, target: target, phase: .drain, failure: .drainTimeout, reason: "drain_timeout")
                try? await sendReady()
                return
            }
            try await ensureEligible(phase: .backup)
            try await preserveMarkerAndSwap(updateID: updateID, target: target, newBinary: prepared.newBinary, tracker: commitTracker)
            await record(updateID: updateID, target: target, phase: .swap, outcome: .success, reason: "binary_swap_complete", attempt: 1)
            try await ensureEligible(phase: .restart)
            try restartLaunchd()
            await record(updateID: updateID, target: target, phase: .restart, outcome: .inProgress, reason: "launchctl_bootstrap_invoked", attempt: 1)
        } catch AutoUpdateMarkerError.lockContended {
            await fail(updateID: updateID, target: target, phase: .eligibility, failure: .autoupdateAlreadyPending, reason: "autoupdate_already_pending")
        } catch AutoUpdateError.trustStateLost(let reason) {
            if let marker = commitTracker.marker ?? (try? markerStore.readPending()) {
                if commitTracker.committedSwap,
                   FileManager.default.fileExists(atPath: marker.targetPath),
                   (try? AutoUpdateMarkerStore.sha256(file: URL(fileURLWithPath: marker.targetPath))) != marker.sha256
                {
                    try? markerStore.restoreBackup(marker)
                }
                if commitTracker.committedMarker || commitTracker.committedBackup {
                    markerStore.orphanPendingMarker(target: nil)
                    try? FileManager.default.removeItem(atPath: marker.backupPath)
                }
            }
            await fail(updateID: updateID, target: target, phase: .eligibility, failure: .trustStateLost, reason: reason)
        } catch {
            await fail(updateID: updateID, target: target, phase: .eligibility, failure: .other, reason: Self.redactedReason(for: error))
        }
    }

    private func preserveMarkerAndSwap(updateID: String, target: String, newBinary: URL, tracker: AutoUpdateCommitTracker) async throws {
        guard let current = currentBinaryURL() else {
            throw AutoUpdateError.currentBinaryUnknown
        }
        let backup = markerStore.rollbackBackupPath(binaryURL: current, updateID: updateID)
        let attrs = try FileManager.default.attributesOfItem(atPath: current.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let sha = try AutoUpdateMarkerStore.sha256(file: current)
        try markerStore.atomicCopyNoFollow(from: current, to: backup, mode: mode)
        tracker.committedBackup = true
        let deadline = ISO8601DateFormatter.autoupdate.string(from: Date().addingTimeInterval(60 + 300))
        let marker = AutoUpdatePendingMarker(
            updateID: updateID,
            targetVersion: target,
            targetPath: current.path,
            backupPath: backup.path,
            size: size,
            mode: mode,
            sha256: sha,
            markerDeadline: deadline
        )
        try markerStore.writePending(marker)
        tracker.marker = marker
        tracker.committedMarker = true
        try await ensureEligible(phase: .swap)
        let staged = current.deletingLastPathComponent()
            .appendingPathComponent(".\(current.lastPathComponent).update-\(UUID().uuidString)")
        try markerStore.atomicCopyNoFollow(from: newBinary, to: staged, mode: 0o755)
        if rename(staged.path, current.path) != 0 {
            let errnoValue = errno
            try? FileManager.default.removeItem(at: staged)
            try? markerStore.restoreBackup(marker)
            throw UpdateError.renameFailed(errnoValue)
        }
        tracker.committedSwap = true
    }

    private func ensureEligible(phase: AutoUpdatePhase) async throws {
        let trust = await trustProvider()
        guard trust.isEligible else {
            throw AutoUpdateError.trustStateLost(trust.lossReason)
        }
        _ = phase
    }

    private func fail(updateID: String, target: String, phase: AutoUpdatePhase, failure: AutoUpdateFailureClass, reason: String) async {
        markerStore.recordCooldown(target: target, failureClass: failure)
        await record(updateID: updateID, target: target, phase: phase, outcome: .failure, reason: reason, attempt: 1, failure: failure)
    }

    private func record(updateID: String, target: String, phase: AutoUpdatePhase, outcome: AutoUpdateOutcome, reason: String, attempt: Int, failure: AutoUpdateFailureClass? = nil, sha: String? = nil) async {
        let inflight = await providerStatus.snapshot().requestsInFlight
        await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
            updateID: updateID,
            currentVersion: currentVersion,
            targetVersion: target,
            phase: phase,
            outcome: outcome,
            reason: reason,
            attempt: attempt,
            failureClass: failure,
            inflightRequests: phase == .drain ? inflight : nil,
            recommendedBinaryVersionSHA256: sha
        ))
    }

    private static func failureClass(for error: Error) -> AutoUpdateFailureClass {
        switch error {
        case UpdateError.missingAsset, UpdateError.checksumMissing:
            return .releaseAssetMissing
        case UpdateError.checksumSignatureInvalid:
            return .signatureInvalid
        case UpdateError.checksumMismatch:
            return .checksumMismatch
        case UpdateError.processFailed:
            return .selfTestFailed
        case UpdateError.insufficientDiskSpace:
            return .insufficientDiskSpace
        default:
            return .other
        }
    }

    static func redactedReason(for error: Error) -> String {
        switch error {
        case UpdateError.invalidURL:
            return "invalid_release_api_url"
        case UpdateError.httpStatus:
            return "release_api_http_status"
        case UpdateError.releaseNotFound:
            return "target_release_not_found"
        case UpdateError.missingAsset:
            return "release_asset_missing"
        case UpdateError.checksumMissing:
            return "checksum_missing"
        case UpdateError.checksumMismatch:
            return "checksum_mismatch"
        case UpdateError.checksumSignatureInvalid:
            return "signature_invalid"
        case UpdateError.missingExtractedBinary:
            return "missing_extracted_binary"
        case UpdateError.currentBinaryUnknown:
            return "current_binary_unknown"
        case UpdateError.processFailed:
            return "process_failed"
        case UpdateError.renameFailed:
            return "rename_failed"
        case UpdateError.untrustedDownloadURL:
            return "untrusted_download_url"
        case UpdateError.untrustedReleaseAPIURL:
            return "untrusted_release_api_url"
        case UpdateError.unsafeArchiveEntry:
            return "unsafe_archive_entry"
        case UpdateError.insufficientDiskSpace:
            return "insufficient_disk_space"
        case AutoUpdateError.trustStateLost(let reason):
            return reason
        case AutoUpdateError.observerUnavailable:
            return "rollback_observer_unavailable"
        case AutoUpdateError.unsupportedInstallTopology:
            return "unsupported_install_topology"
        default:
            return String(describing: error).prefix(64).description
        }
    }

    private static func phase(for error: Error) -> AutoUpdatePhase {
        switch error {
        case UpdateError.checksumSignatureInvalid:
            return .signature
        case UpdateError.checksumMismatch, UpdateError.checksumMissing:
            return .checksum
        case UpdateError.unsafeArchiveEntry, UpdateError.missingExtractedBinary:
            return .archive
        case UpdateError.processFailed:
            return .selfTest
        case UpdateError.insufficientDiskSpace:
            return .freeSpace
        default:
            return .download
        }
    }

    static func defaultRollbackObserverAvailable() -> Bool {
        if ProcessInfo.processInfo.environment["MACPROVIDER_ROLLBACK_OBSERVER_TEST_AVAILABLE"] == "1" {
            return true
        }
        return launchctlServiceLoaded(label: "live.streamvc.macprovider-watchdog")
    }

    static func defaultLaunchdProviderAvailable() -> Bool {
        if ProcessInfo.processInfo.environment["MACPROVIDER_LAUNCHD_PROVIDER_TEST_AVAILABLE"] == "1" {
            return true
        }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist")
        return FileManager.default.fileExists(atPath: plist.path)
            && launchctlServiceLoaded(label: "live.streamvc.macprovider")
    }

    static func restartLaunchdIfInstalled() throws {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            throw AutoUpdateError.unsupportedInstallTopology
        }
        let domain = "gui/\(getuid())"
        try runProcess("/bin/launchctl", arguments: ["bootout", domain, "live.streamvc.macprovider"], allowFailure: true)
        try runProcess("/bin/launchctl", arguments: ["bootstrap", domain, plist.path])
    }

    private static func launchctlServiceLoaded(label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return !output.lowercased().contains("disabled = true")
    }

    private static func runProcess(_ executable: String, arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if !allowFailure, process.terminationStatus != 0 {
            throw UpdateError.processFailed(executable, process.terminationStatus)
        }
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
