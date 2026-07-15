import Darwin
import Foundation
import MacProviderCore

enum AutoUpdateError: Error, CustomStringConvertible {
    case trustStateLost(String)
    case drainTimeout
    case observerUnavailable
    case currentBinaryUnknown
    case other(String)

    var description: String {
        switch self {
        case let .trustStateLost(reason): return "autoupdate trust state lost: \(reason)"
        case .drainTimeout: return "autoupdate drain timed out"
        case .observerUnavailable: return "rollback observer unavailable"
        case .currentBinaryUnknown: return "current binary unknown"
        case let .other(reason): return reason
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
    let expectedCompatibilitySetID: String?
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
    let lifecycleLeaseStore: ProviderLifecycleLeaseStore

    init(
        config: AppConfig,
        currentVersion: String,
        providerStatus: ProviderStatus,
        expectedCompatibilitySetID: String? = nil,
        releasesAPIURL: String? = nil,
        markerStore: AutoUpdateMarkerStore = AutoUpdateMarkerStore(),
        session: URLSession = .shared,
        trustProvider: @escaping TrustProvider,
        drain: @escaping Drain,
        sendReady: @escaping SendReady,
        restartLaunchd: @escaping Restart = { try AutoUpdater.restartLaunchdIfInstalled() },
        currentBinaryURL: @escaping @Sendable () -> URL? = { Bundle.main.executableURL },
        rollbackObserverAvailable: @escaping Availability = { AutoUpdater.defaultRollbackObserverAvailable() },
        launchdProviderAvailable: @escaping Availability = { AutoUpdater.defaultLaunchdProviderAvailable() },
        lifecycleLeaseStore: ProviderLifecycleLeaseStore = ProviderLifecycleLeaseStore()
    ) {
        self.config = config
        self.currentVersion = currentVersion
        self.providerStatus = providerStatus
        self.expectedCompatibilitySetID = expectedCompatibilitySetID
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
        self.lifecycleLeaseStore = lifecycleLeaseStore
    }

    func handleCoordinatorRecommendation(_ rawRecommended: String) async {
        let updateID = UUID().uuidString.lowercased()
        let entryTrust = await trustProvider()
        guard !SessionAutoupdateGate.shared.isDisabled else {
            await record(updateID: updateID, target: "<session-disabled>", phase: .eligibility, outcome: .skipped, reason: "signed_policy_persist_failed", attempt: 1)
            return
        }
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
        var maintenanceLease: ProviderLifecycleLeaseRecord?
        var startupHandoffPrepared = false
        defer {
            if let maintenanceLease, !startupHandoffPrepared {
                _ = try? lifecycleLeaseStore.clear(ifLeaseID: maintenanceLease.leaseID)
            }
        }

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
                await fail(updateID: updateID, target: target, phase: .eligibility, failure: .other, reason: "unsupported_install_topology")
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
            defer { withExtendedLifetime(lock) {} }
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
            guard let expectedCompatibilitySetID else {
                await fail(
                    updateID: updateID,
                    target: target,
                    phase: .eligibility,
                    failure: .other,
                    reason: "coordinator_compatibility_target_missing"
                )
                return
            }
            guard prepared.compatibilityManifest.compatibilitySetID == expectedCompatibilitySetID else {
                await fail(
                    updateID: updateID,
                    target: target,
                    phase: .eligibility,
                    failure: .other,
                    reason: "coordinator_compatibility_target_mismatch"
                )
                return
            }
            if try markerStore.preflightInstalledMalibuAppReplacement() != nil,
               prepared.stagedMalibuApp == nil {
                await fail(
                    updateID: updateID,
                    target: target,
                    phase: .eligibility,
                    failure: .other,
                    reason: "signed_malibu_bundle_missing"
                )
                return
            }
            maintenanceLease = try lifecycleLeaseStore.acquire(
                kind: .maintenance,
                operationID: "autoupdate:\(updateID)",
                duration: TimeInterval(prepared.compatibilityManifest.maintenanceLeaseSeconds)
            )
            try await ensureEligible(phase: .drain)
            let drained = try await drain(target)
            guard drained else {
                await fail(updateID: updateID, target: target, phase: .drain, failure: .drainTimeout, reason: "drain_timeout")
                try? await sendReady()
                return
            }
            try await ensureEligible(phase: .backup)
            try await preserveMarkerAndSwap(
                updateID: updateID,
                target: target,
                prepared: prepared,
                tracker: commitTracker
            )
            if let signedPolicy = prepared.signedPolicy {
                try await markerStore.updateSignedPolicy(minimum: signedPolicy.minimum, revoked: signedPolicy.revoked)
            }
            await record(updateID: updateID, target: target, phase: .swap, outcome: .success, reason: "binary_swap_complete", attempt: 1)
            try await ensureEligible(phase: .restart)
            do {
                guard let lease = maintenanceLease,
                      let providerID = config.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !providerID.isEmpty,
                      let current = currentBinaryURL()
                else {
                    throw ProviderLifecycleLeaseError.invalidHandoffField("provider_id")
                }
                _ = try lifecycleLeaseStore.prepareStartupHandoff(
                    maintenanceLeaseID: lease.leaseID,
                    operationID: "autoupdate:\(updateID)",
                    providerID: providerID,
                    serviceIdentity: SelfUpdate.launchdLabel,
                    targetExecutablePath: current.path,
                    targetExecutableSHA256: try AutoUpdateMarkerStore.sha256(file: current),
                    handoffDuration: 60,
                    startupLeaseDuration: TimeInterval(prepared.compatibilityManifest.readinessTimeoutSeconds)
                )
                startupHandoffPrepared = true
                try restartLaunchd()
            } catch {
                try? rollbackCommittedSwapAfterRestartFailure(commitTracker)
                if let maintenanceLease {
                    _ = try? lifecycleLeaseStore.clear(ifLeaseID: maintenanceLease.leaseID)
                }
                startupHandoffPrepared = false
                await fail(updateID: updateID, target: target, phase: .restart, failure: .other, reason: Self.redactedReason(for: error))
                return
            }
            await record(updateID: updateID, target: target, phase: .restart, outcome: .inProgress, reason: "launchctl_restart_invoked", attempt: 1)
        } catch AutoUpdateMarkerError.lockContended {
            await fail(updateID: updateID, target: target, phase: .eligibility, failure: .autoupdateAlreadyPending, reason: "provider_mutation_in_progress")
        } catch AutoUpdateMarkerError.transactionPending {
            await fail(updateID: updateID, target: target, phase: .eligibility, failure: .autoupdateAlreadyPending, reason: "autoupdate_already_pending")
        } catch AutoUpdateError.trustStateLost(let reason) {
            if let marker = commitTracker.marker ?? (try? markerStore.readPending()) {
                var rollbackSafeToClean = !commitTracker.committedSwap
                if commitTracker.committedSwap {
                    do {
                        let restored = try markerStore.restoreBackupAwaitingPreviousReadiness(marker)
                        rollbackSafeToClean = restored.transactionState == nil
                    } catch {
                        // Keep the pending marker and both backups durable so
                        // the watchdog can retry a failed in-process restore.
                    }
                }
                if rollbackSafeToClean,
                   commitTracker.committedMarker || commitTracker.committedBackup
                {
                    markerStore.clearPendingAndLock(target: nil)
                    markerStore.removeRollbackBackups(marker)
                }
            }
            await fail(updateID: updateID, target: target, phase: .eligibility, failure: .trustStateLost, reason: reason)
        } catch is AutoUpdateSignedPolicyPersistError {
            markerStore.recordCooldown(target: target, failureClass: .other)
        } catch {
            await fail(updateID: updateID, target: target, phase: .eligibility, failure: .other, reason: Self.redactedReason(for: error))
        }
    }

    private func preserveMarkerAndSwap(
        updateID: String,
        target: String,
        prepared: PreparedSelfUpdate,
        tracker: AutoUpdateCommitTracker
    ) async throws {
        guard let current = currentBinaryURL() else {
            throw AutoUpdateError.currentBinaryUnknown
        }
        let marker = try markerStore.preserveReleaseRollbackBackup(
            binaryURL: current,
            updateID: updateID,
            targetVersion: target,
            previousVersion: currentVersion,
            targetCompatibilitySetID: prepared.compatibilityManifest.compatibilitySetID,
            targetCompatibilitySetSHA256: prepared.compatibilityManifest.envelopeSHA256,
            readinessTimeoutSeconds: prepared.compatibilityManifest.readinessTimeoutSeconds
        )
        tracker.marker = marker
        tracker.committedBackup = true
        do {
            try markerStore.writePending(marker)
            tracker.committedMarker = true
            try await ensureEligible(phase: .swap)
            try markerStore.activateReleasePayload(
                from: prepared.newBinary.deletingLastPathComponent(),
                newBinary: prepared.newBinary,
                to: current,
                stagedMalibuApp: prepared.stagedMalibuApp,
                rollbackMarker: marker
            )
            tracker.committedSwap = true
        } catch {
            if tracker.committedMarker {
                do {
                    let restored = try markerStore.restoreBackupAwaitingPreviousReadiness(marker)
                    if restored.transactionState == nil {
                        markerStore.clearPendingAndLock(target: nil)
                        markerStore.removeRollbackBackups(marker)
                    }
                } catch {
                    // Leave the durable marker and both snapshots intact so
                    // the independent watchdog can retry the same restore.
                }
            } else {
                markerStore.removeRollbackBackups(marker)
                markerStore.clearPendingAndLock(target: nil)
            }
            throw error
        }
    }

    func rollbackCommittedSwapAfterRestartFailureForTest(_ marker: AutoUpdatePendingMarker) {
        let tracker = AutoUpdateCommitTracker()
        tracker.marker = marker
        tracker.committedMarker = true
        tracker.committedBackup = true
        tracker.committedSwap = true
        try? rollbackCommittedSwapAfterRestartFailure(tracker)
    }

    private func rollbackCommittedSwapAfterRestartFailure(_ tracker: AutoUpdateCommitTracker) throws {
        guard tracker.committedSwap, let marker = tracker.marker ?? (try? markerStore.readPending()) else {
            return
        }
        let restored = try markerStore.restoreBackupAwaitingPreviousReadiness(marker)
        try restartLaunchd()
        if restored.transactionState == nil {
            markerStore.clearPendingAndLock(target: nil)
            markerStore.removeRollbackBackups(marker)
        }
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
        case UpdateError.missingReleaseResource:
            return "release_resource_missing"
        case UpdateError.compatibilityManifestInvalid:
            return "compatibility_set_invalid"
        case UpdateError.compatibilityManifestVersionMismatch:
            return "compatibility_set_version_mismatch"
        case UpdateError.rollbackUnavailable:
            return "rollback_unavailable"
        case UpdateError.activationFailedRollbackFailed:
            return "activation_failed_rollback_failed"
        case UpdateError.restartFailedRollbackRestored:
            return "rollback_restored"
        case UpdateError.restartFailedRollbackFailed:
            return "restart_failed_rollback_failed"
        case AutoUpdateError.trustStateLost(let reason):
            return reason
        case is AutoUpdateSignedPolicyPersistError:
            return "signed_policy_persist_failed"
        case AutoUpdateError.observerUnavailable:
            return "rollback_observer_unavailable"
        case AutoUpdateError.other(let reason):
            return reason
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
        case UpdateError.unsafeArchiveEntry, UpdateError.missingExtractedBinary,
             UpdateError.compatibilityManifestInvalid, UpdateError.compatibilityManifestVersionMismatch:
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
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let plist = homeDirectory
            .appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            throw AutoUpdateError.other("unsupported_install_topology")
        }
        try SelfUpdate.reloadCompatibilityLaunchdJobs(
            homeDirectory: homeDirectory,
            serviceLoaded: launchctlServiceLoaded,
            runLaunchctl: { arguments in
                try runProcess("/bin/launchctl", arguments: arguments)
            }
        )
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
    static var autoupdate: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
