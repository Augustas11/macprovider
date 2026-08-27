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
    typealias FenceReloadJobs = @Sendable () throws -> Void
    typealias Availability = @Sendable () -> Bool
    typealias EvictStaleLocalStatusOwner = @Sendable (_ targetVersion: String, _ expectedExecutablePath: String) async -> Void

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
    let fenceReloadJobs: FenceReloadJobs
    let currentBinaryURL: @Sendable () -> URL?
    let rollbackObserverAvailable: Availability
    let launchdProviderAvailable: Availability
    let lifecycleLeaseStore: ProviderLifecycleLeaseStore
    let evictStaleLocalStatusOwner: EvictStaleLocalStatusOwner

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
        fenceReloadJobs: @escaping FenceReloadJobs = { try AutoUpdater.fenceReloadJobsIfInstalled() },
        currentBinaryURL: @escaping @Sendable () -> URL? = {
            AutoUpdateMarkerStore().resolveCanonicalInstallBinary(
                launchedExecutableURL: Bundle.main.executableURL
            )
        },
        rollbackObserverAvailable: @escaping Availability = { AutoUpdater.defaultRollbackObserverAvailable() },
        launchdProviderAvailable: @escaping Availability = { AutoUpdater.defaultLaunchdProviderAvailable() },
        lifecycleLeaseStore: ProviderLifecycleLeaseStore = ProviderLifecycleLeaseStore(),
        evictStaleLocalStatusOwner: @escaping EvictStaleLocalStatusOwner = { targetVersion, expectedExecutablePath in
            await SelfUpdate.evictStaleLocalStatusOwnerIfManaged(
                targetVersion: targetVersion,
                expectedExecutablePath: expectedExecutablePath
            )
        }
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
        self.fenceReloadJobs = fenceReloadJobs
        self.currentBinaryURL = currentBinaryURL
        self.rollbackObserverAvailable = rollbackObserverAvailable
        self.launchdProviderAvailable = launchdProviderAvailable
        self.lifecycleLeaseStore = lifecycleLeaseStore
        self.evictStaleLocalStatusOwner = evictStaleLocalStatusOwner
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
        var mutationLock: AutoUpdateLock?
        defer { withExtendedLifetime(mutationLock) {} }
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
            let heldMutationLock = try acquireUpdateLockAndFenceReloadJobs()
            mutationLock = heldMutationLock
            let update = SelfUpdate(currentVersion: currentVersion, releasesAPIURL: releasesAPIURL, session: session)
            let release: GitHubRelease
            do {
                try await ensureEligible(phase: .download)
                release = try await update.resolveReleaseByTags(normalizedTarget: target)
            } catch UpdateError.releaseNotFound {
                await fail(updateID: updateID, target: target, phase: .download, failure: .targetReleaseNotFound, reason: "target_release_not_found")
                return
            }
            // The coordinator's recommended compatibility-set target is a precondition
            // known without downloading the release payload. Check it here — after the
            // eligibility/trust re-checks and release resolution, but before the full
            // download+extract in prepareValidatedUpdate — so a node the coordinator
            // advertised a binary version to without a compatibility-set target fails
            // fast with coordinator_compatibility_target_missing instead of downloading
            // and extracting a release it will only reject at the guard below. Placed
            // after the trust re-checks so trust-loss failures keep precedence.
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
            let prepared: PreparedSelfUpdate
            do {
                prepared = try await update.prepareValidatedUpdate(from: release)
            } catch {
                let failure = Self.failureClass(for: error)
                await fail(updateID: updateID, target: target, phase: Self.phase(for: error), failure: failure, reason: Self.redactedReason(for: error))
                return
            }
            defer { prepared.cleanup() }
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
                tracker: commitTracker,
                authorityMode: "coordinator_recommendation",
                discoveryHead: nil,
                requireCurrentTrustAtSwap: true,
                whileHolding: heldMutationLock
            )
            if let signedPolicy = prepared.signedPolicy {
                try await markerStore.updateSignedPolicy(minimum: signedPolicy.minimum, revoked: signedPolicy.revoked)
            }
            await record(updateID: updateID, target: target, phase: .swap, outcome: .success, reason: "binary_swap_complete", attempt: 1)
            try await ensureEligible(phase: .restart)
            do {
                try await prepareStartupHandoffEvictAndRestart(
                    maintenanceLease: maintenanceLease,
                    operationID: "autoupdate:\(updateID)",
                    targetVersion: target,
                    readinessTimeoutSeconds: prepared.compatibilityManifest.readinessTimeoutSeconds
                )
                startupHandoffPrepared = true
            } catch {
                try? rollbackCommittedSwapAfterRestartFailure(
                    commitTracker,
                    whileHolding: heldMutationLock
                )
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
            if let mutationLock {
                rollbackCommittedMutationAfterGuardFailure(
                    commitTracker,
                    whileHolding: mutationLock
                )
            }
            await fail(updateID: updateID, target: target, phase: .eligibility, failure: .trustStateLost, reason: reason)
        } catch is AutoUpdateSignedPolicyPersistError {
            if let mutationLock {
                rollbackCommittedMutationAfterGuardFailure(
                    commitTracker,
                    whileHolding: mutationLock
                )
            }
            markerStore.recordCooldown(target: target, failureClass: .other)
        } catch {
            await fail(updateID: updateID, target: target, phase: .eligibility, failure: .other, reason: Self.redactedReason(for: error))
        }
    }

    func handleSignedReleaseDiscovery() async {
        let updateID = UUID().uuidString.lowercased()
        guard !SessionAutoupdateGate.shared.isDisabled else {
            await record(updateID: updateID, target: "<session-disabled>", source: .githubPoll, phase: .eligibility, outcome: .skipped, reason: "signed_policy_persist_failed", attempt: 1)
            return
        }
        guard AutoUpdateConfig.enabled(config) else {
            await record(updateID: updateID, target: "<disabled>", source: .githubPoll, phase: .eligibility, outcome: .skipped, reason: "autoupdate_disabled", attempt: 1)
            return
        }
        let commitTracker = AutoUpdateCommitTracker()
        var maintenanceLease: ProviderLifecycleLeaseRecord?
        var startupHandoffPrepared = false
        defer {
            if let maintenanceLease, !startupHandoffPrepared {
                _ = try? lifecycleLeaseStore.clear(ifLeaseID: maintenanceLease.leaseID)
            }
        }

        do {
            guard launchdProviderAvailable() else {
                await fail(updateID: updateID, target: "<unknown>", source: .githubPoll, phase: .eligibility, failure: .other, reason: "unsupported_install_topology")
                return
            }
            guard rollbackObserverAvailable() else {
                await fail(updateID: updateID, target: "<unknown>", source: .githubPoll, phase: .eligibility, failure: .rollbackObserverUnavailable, reason: "rollback_observer_unavailable")
                return
            }
            try markerStore.ensureTrustedRoot()
            if let activeCooldown = markerStore.activeCooldown(target: "<discovery>") {
                await record(updateID: updateID, target: "<discovery>", source: .githubPoll, phase: .cooldown, outcome: .skipped, reason: "cooldown_\(activeCooldown.failureClass.rawValue)_until_\(ISO8601DateFormatter.autoupdate.string(from: activeCooldown.until))", attempt: activeCooldown.attempt)
                return
            }
            let update = SelfUpdate(currentVersion: currentVersion, releasesAPIURL: releasesAPIURL, session: session)
            let head: SignedReleaseDiscoveryHead
            do {
                head = try await update.discoverSignedReleaseHead()
                try await markerStore.updateSignedPolicy(
                    minimum: head.signedPolicyMinimum,
                    revoked: head.signedPolicyRevoked
                )
            } catch UpdateError.discoveryHeadReplay {
                await fail(updateID: updateID, target: "<discovery>", source: .githubPoll, phase: .eligibility, failure: .discoveryHeadReplay, reason: "discovery_head_replay")
                return
            } catch UpdateError.discoveryHeadEquivocation {
                await fail(updateID: updateID, target: "<discovery>", source: .githubPoll, phase: .eligibility, failure: .discoveryHeadEquivocation, reason: "discovery_head_equivocation")
                return
            } catch UpdateError.discoveryHeadExpired {
                await fail(updateID: updateID, target: "<discovery>", source: .githubPoll, phase: .eligibility, failure: .discoveryHeadExpired, reason: "discovery_head_expired")
                return
            }
            let target = head.targetVersion
            await record(updateID: updateID, target: target, source: .githubPoll, phase: .detection, outcome: .inProgress, reason: "signed_release_discovery_detected", attempt: 1)
            let canonicalBinary = currentBinaryURL()
            let installedReleaseVersion = CompatibilitySetManifest.loadInstalledPreferringInstallAuthority(
                launchedExecutableURL: Bundle.main.executableURL,
                canonicalBinaryURL: canonicalBinary,
                expectedVersion: currentVersion,
                allowProviderVersionMismatch: true
            )?.version ?? currentVersion
            guard SelfUpdate.compareSemver(installedReleaseVersion, target) == .orderedAscending else {
                // Keep PATH converged even on noop polls so mixed regular-file
                // PATH installs heal without waiting for the next activation.
                _ = try? markerStore.ensurePathEntrypointMatchesInstallAuthority(
                    launchedExecutableURL: Bundle.main.executableURL
                )
                await record(updateID: updateID, target: target, source: .githubPoll, phase: .eligibility, outcome: .noop, reason: "target_not_newer", attempt: 1)
                return
            }
            let policy = markerStore.effectivePolicy()
            if let minimum = policy.minimum, SelfUpdate.compareSemver(target, minimum) == .orderedAscending || policy.revoked.contains(target) {
                await fail(updateID: updateID, target: target, source: .githubPoll, phase: .eligibility, failure: .targetRevokedOrBelowMinimum, reason: "target_revoked_or_below_minimum")
                return
            }
            if let activeCooldown = markerStore.activeCooldown(target: target) {
                await record(updateID: updateID, target: target, source: .githubPoll, phase: .cooldown, outcome: .skipped, reason: "cooldown_\(activeCooldown.failureClass.rawValue)_until_\(ISO8601DateFormatter.autoupdate.string(from: activeCooldown.until))", attempt: activeCooldown.attempt)
                return
            }
            let lock = try acquireUpdateLockAndFenceReloadJobs()
            defer { withExtendedLifetime(lock) {} }
            let release = try await update.resolveReleaseByTags(normalizedTarget: target)
            let prepared = try await update.prepareValidatedUpdate(
                from: release,
                expectedArtifactIndexSHA256: head.targetArtifactIndexSHA256
            )
            defer { prepared.cleanup() }
            try SelfUpdate.requireDiscoveryHead(head, matches: prepared)
            let providerTarget = prepared.compatibilityManifest.providerCLIVersion
            guard prepared.compatibilityManifest.compatibilitySetID == head.targetCompatibilitySetID else {
                await fail(updateID: updateID, target: target, source: .githubPoll, phase: .eligibility, failure: .other, reason: "discovery_compatibility_target_mismatch")
                return
            }
            if try markerStore.preflightInstalledMalibuAppReplacement() != nil,
               prepared.stagedMalibuApp == nil {
                await fail(updateID: updateID, target: target, source: .githubPoll, phase: .eligibility, failure: .other, reason: "signed_malibu_bundle_missing")
                return
            }
            maintenanceLease = try lifecycleLeaseStore.acquire(
                kind: .maintenance,
                operationID: "autoupdate:\(updateID)",
                duration: TimeInterval(prepared.compatibilityManifest.maintenanceLeaseSeconds)
            )
            let drained = try await drain(providerTarget)
            guard drained else {
                await fail(updateID: updateID, target: providerTarget, source: .githubPoll, phase: .drain, failure: .drainTimeout, reason: "drain_timeout")
                try? await sendReady()
                return
            }
            try await preserveMarkerAndSwap(
                updateID: updateID,
                target: providerTarget,
                prepared: prepared,
                tracker: commitTracker,
                authorityMode: "signed_release",
                discoveryHead: head,
                requireCurrentTrustAtSwap: false,
                whileHolding: lock
            )
            await record(updateID: updateID, target: providerTarget, source: .githubPoll, phase: .swap, outcome: .success, reason: "binary_swap_complete", attempt: 1)
            do {
                try await prepareStartupHandoffEvictAndRestart(
                    maintenanceLease: maintenanceLease,
                    operationID: "autoupdate:\(updateID)",
                    targetVersion: providerTarget,
                    readinessTimeoutSeconds: prepared.compatibilityManifest.readinessTimeoutSeconds
                )
                startupHandoffPrepared = true
            } catch {
                try? rollbackCommittedSwapAfterRestartFailure(
                    commitTracker,
                    whileHolding: lock
                )
                if let maintenanceLease {
                    _ = try? lifecycleLeaseStore.clear(ifLeaseID: maintenanceLease.leaseID)
                }
                startupHandoffPrepared = false
                await fail(updateID: updateID, target: providerTarget, source: .githubPoll, phase: .restart, failure: .other, reason: Self.redactedReason(for: error))
                return
            }
            await record(updateID: updateID, target: providerTarget, source: .githubPoll, phase: .restart, outcome: .inProgress, reason: "launchctl_restart_invoked", attempt: 1)
        } catch AutoUpdateMarkerError.lockContended {
            await fail(updateID: updateID, target: "<unknown>", source: .githubPoll, phase: .eligibility, failure: .autoupdateAlreadyPending, reason: "provider_mutation_in_progress")
        } catch AutoUpdateMarkerError.transactionPending {
            await fail(updateID: updateID, target: "<unknown>", source: .githubPoll, phase: .eligibility, failure: .autoupdateAlreadyPending, reason: "autoupdate_already_pending")
        } catch {
            let failure = Self.failureClass(for: error)
            await fail(updateID: updateID, target: "<unknown>", source: .githubPoll, phase: Self.phase(for: error), failure: failure, reason: Self.redactedReason(for: error))
        }
    }

    private func preserveMarkerAndSwap(
        updateID: String,
        target: String,
        prepared: PreparedSelfUpdate,
        tracker: AutoUpdateCommitTracker,
        authorityMode: String,
        discoveryHead: SignedReleaseDiscoveryHead?,
        requireCurrentTrustAtSwap: Bool,
        whileHolding lock: AutoUpdateLock
    ) async throws {
        defer { withExtendedLifetime(lock) {} }
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
            discoveryHeadSequence: discoveryHead?.releaseSequence,
            discoveryHeadSHA256: discoveryHead?.digest,
            updateAuthorityMode: authorityMode,
            readinessTimeoutSeconds: prepared.compatibilityManifest.readinessTimeoutSeconds
        )
        tracker.marker = marker
        tracker.committedBackup = true
        do {
            try markerStore.writePending(marker)
            tracker.committedMarker = true
            if requireCurrentTrustAtSwap {
                try await ensureEligible(phase: .swap)
            }
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
                    if try restoreBackupAfterFencing(marker, whileHolding: lock) {
                        markerStore.clearPendingAndLock(target: nil)
                        markerStore.removeRollbackBackups(marker)
                    }
                } catch {
                    // Leave the durable marker and both snapshots intact so
                    // CLI startup recovery can retry the same restore.
                }
            } else {
                markerStore.removeRollbackBackups(marker)
                markerStore.clearPendingAndLock(target: nil)
            }
            throw error
        }
    }

    private func prepareStartupHandoffEvictAndRestart(
        maintenanceLease: ProviderLifecycleLeaseRecord?,
        operationID: String,
        targetVersion: String,
        readinessTimeoutSeconds: Int
    ) async throws {
        guard let lease = maintenanceLease,
              let providerID = config.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty,
              let current = currentBinaryURL()
        else {
            throw ProviderLifecycleLeaseError.invalidHandoffField("provider_id")
        }
        _ = try lifecycleLeaseStore.prepareStartupHandoff(
            maintenanceLeaseID: lease.leaseID,
            operationID: operationID,
            providerID: providerID,
            serviceIdentity: SelfUpdate.launchdLabel,
            targetExecutablePath: current.path,
            targetExecutableSHA256: try AutoUpdateMarkerStore.sha256(file: current),
            handoffDuration: 60,
            startupLeaseDuration: TimeInterval(readinessTimeoutSeconds)
        )
        await evictStaleLocalStatusOwner(targetVersion, current.path)
        try restartLaunchd()
    }

    func preserveMarkerAndSwapForTest(
        updateID: String,
        target: String,
        prepared: PreparedSelfUpdate,
        authorityMode: String,
        discoveryHead: SignedReleaseDiscoveryHead?,
        requireCurrentTrustAtSwap: Bool
    ) async throws {
        let lock = try acquireUpdateLockAndFenceReloadJobs()
        defer { withExtendedLifetime(lock) {} }
        try await preserveMarkerAndSwap(
            updateID: updateID,
            target: target,
            prepared: prepared,
            tracker: AutoUpdateCommitTracker(),
            authorityMode: authorityMode,
            discoveryHead: discoveryHead,
            requireCurrentTrustAtSwap: requireCurrentTrustAtSwap,
            whileHolding: lock
        )
    }

    func prepareStartupHandoffEvictAndRestartForTest(
        maintenanceLease: ProviderLifecycleLeaseRecord?,
        operationID: String,
        targetVersion: String,
        readinessTimeoutSeconds: Int
    ) async throws {
        try await prepareStartupHandoffEvictAndRestart(
            maintenanceLease: maintenanceLease,
            operationID: operationID,
            targetVersion: targetVersion,
            readinessTimeoutSeconds: readinessTimeoutSeconds
        )
    }

    func rollbackCommittedSwapAfterRestartFailureForTest(_ marker: AutoUpdatePendingMarker) {
        guard let lock = try? markerStore.acquireRecoveryLock() else { return }
        defer { withExtendedLifetime(lock) {} }
        let tracker = AutoUpdateCommitTracker()
        tracker.marker = marker
        tracker.committedMarker = true
        tracker.committedBackup = true
        tracker.committedSwap = true
        try? rollbackCommittedSwapAfterRestartFailure(tracker, whileHolding: lock)
    }

    func acquireUpdateLockAndFenceReloadJobsForTest() throws -> AutoUpdateLock {
        try acquireUpdateLockAndFenceReloadJobs()
    }

    func rollbackAfterTrustLossForTest(
        _ marker: AutoUpdatePendingMarker,
        whileHolding lock: AutoUpdateLock,
        cleanupObserver: () -> Void
    ) {
        let tracker = AutoUpdateCommitTracker()
        tracker.marker = marker
        tracker.committedMarker = true
        tracker.committedBackup = true
        tracker.committedSwap = true
        rollbackCommittedMutationAfterGuardFailure(
            tracker,
            whileHolding: lock,
            cleanupObserver: cleanupObserver
        )
    }

    func rollbackAfterActivationFailureForTest(
        _ marker: AutoUpdatePendingMarker,
        whileHolding lock: AutoUpdateLock
    ) throws {
        defer { withExtendedLifetime(lock) {} }
        if try restoreBackupAfterFencing(marker, whileHolding: lock) {
            markerStore.clearPendingAndLock(target: nil)
            markerStore.removeRollbackBackups(marker)
        }
    }

    func rollbackAfterSignedPolicyPersistFailureForTest(
        _ marker: AutoUpdatePendingMarker,
        whileHolding lock: AutoUpdateLock,
        cleanupObserver: () -> Void
    ) {
        let tracker = AutoUpdateCommitTracker()
        tracker.marker = marker
        tracker.committedMarker = true
        tracker.committedBackup = true
        tracker.committedSwap = true
        rollbackCommittedMutationAfterGuardFailure(
            tracker,
            whileHolding: lock,
            cleanupObserver: cleanupObserver
        )
    }

    private func acquireUpdateLockAndFenceReloadJobs() throws -> AutoUpdateLock {
        let lock = try markerStore.acquireLock()
        do {
            try fenceReloadJobs()
            return lock
        } catch {
            withExtendedLifetime(lock) {}
            throw error
        }
    }

    private func rollbackCommittedMutationAfterGuardFailure(
        _ tracker: AutoUpdateCommitTracker,
        whileHolding lock: AutoUpdateLock,
        cleanupObserver: () -> Void = {}
    ) {
        defer { withExtendedLifetime(lock) {} }
        guard let marker = tracker.marker ?? (try? markerStore.readPending()) else {
            cleanupObserver()
            return
        }
        var rollbackSafeToClean = !tracker.committedSwap
        if tracker.committedSwap {
            do {
                rollbackSafeToClean = try restoreBackupAfterFencing(
                    marker,
                    whileHolding: lock
                )
            } catch {
                // Keep the pending marker and both backups durable so
                // CLI startup recovery can retry a failed in-process restore.
            }
        }
        if rollbackSafeToClean,
           tracker.committedMarker || tracker.committedBackup
        {
            markerStore.clearPendingAndLock(target: nil)
            markerStore.removeRollbackBackups(marker)
        }
        cleanupObserver()
    }

    private func rollbackCommittedSwapAfterRestartFailure(
        _ tracker: AutoUpdateCommitTracker,
        whileHolding lock: AutoUpdateLock
    ) throws {
        defer { withExtendedLifetime(lock) {} }
        guard tracker.committedSwap, let marker = tracker.marker ?? (try? markerStore.readPending()) else {
            return
        }
        let rollbackSafeToClean = try restoreBackupAfterFencing(
            marker,
            whileHolding: lock
        )
        try restartLaunchd()
        if rollbackSafeToClean {
            markerStore.clearPendingAndLock(target: nil)
            markerStore.removeRollbackBackups(marker)
        }
    }

    private func restoreBackupAfterFencing(
        _ marker: AutoUpdatePendingMarker,
        whileHolding lock: AutoUpdateLock
    ) throws -> Bool {
        defer { withExtendedLifetime(lock) {} }
        try fenceReloadJobs()
        let restored = try markerStore.restoreBackupAwaitingPreviousReadiness(marker)
        return restored.transactionState == nil
    }

    private func ensureEligible(phase: AutoUpdatePhase) async throws {
        let trust = await trustProvider()
        guard trust.isEligible else {
            throw AutoUpdateError.trustStateLost(trust.lossReason)
        }
        _ = phase
    }

    private func fail(updateID: String, target: String, source: AutoUpdateSource = .coordinator, phase: AutoUpdatePhase, failure: AutoUpdateFailureClass, reason: String) async {
        markerStore.recordCooldown(target: target, failureClass: failure)
        await record(updateID: updateID, target: target, source: source, phase: phase, outcome: .failure, reason: reason, attempt: 1, failure: failure)
    }

    private func record(updateID: String, target: String, source: AutoUpdateSource = .coordinator, phase: AutoUpdatePhase, outcome: AutoUpdateOutcome, reason: String, attempt: Int, failure: AutoUpdateFailureClass? = nil, sha: String? = nil) async {
        let inflight = await providerStatus.snapshot().requestsInFlight
        await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
            updateID: updateID,
            currentVersion: currentVersion,
            targetVersion: target,
            source: source,
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
        case UpdateError.discoveryHeadReplay:
            return .discoveryHeadReplay
        case UpdateError.discoveryHeadEquivocation:
            return .discoveryHeadEquivocation
        case UpdateError.discoveryHeadExpired:
            return .discoveryHeadExpired
        case UpdateError.missingReleaseResource,
             UpdateError.compatibilityManifestInvalid,
             UpdateError.compatibilityArtifactIndexInvalid:
            return .releasePayloadIncomplete
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
        case UpdateError.compatibilityManifestInvalid(let label):
            // Surface the specific manifest-rejection sublabel (e.g. cli_identifier,
            // signature_invalid) instead of a generic string, so remote diagnosis can
            // tell an identifier/rebrand mismatch apart from a truncated payload. All
            // real throw sites use fixed internal slug labels. Append the label ONLY
            // when the WHOLE string already matches the strict internal slug shape;
            // an unexpected label is dropped to the bare code rather than partially
            // transformed, so no path/username/secret fragment can ever be emitted
            // (filtering out separators alone would leave sensitive words behind).
            // Cap 64 covers the longest current internal label
            // ("updater_rollback_plan_noncanonical_or_unsupported", 49) with margin
            // while still bounding log size against an unexpected long string.
            if label.range(of: #"^[a-z0-9_]{1,64}$"#, options: .regularExpression) != nil {
                return "compatibility_set_invalid:\(label)"
            }
            return "compatibility_set_invalid"
        case UpdateError.compatibilityManifestVersionMismatch:
            return "compatibility_set_version_mismatch"
        case UpdateError.compatibilityArtifactIndexInvalid:
            return "compatibility_artifact_index_invalid"
        case UpdateError.discoveryHeadInvalid:
            return "discovery_head_invalid"
        case UpdateError.discoveryHeadReplay:
            return "discovery_head_replay"
        case UpdateError.discoveryHeadEquivocation:
            return "discovery_head_equivocation"
        case UpdateError.discoveryHeadExpired:
            return "discovery_head_expired"
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
             UpdateError.compatibilityManifestInvalid, UpdateError.compatibilityManifestVersionMismatch,
             UpdateError.compatibilityArtifactIndexInvalid:
            return .archive
        case UpdateError.processFailed:
            return .selfTest
        case UpdateError.insufficientDiskSpace:
            return .freeSpace
        case UpdateError.discoveryHeadInvalid, UpdateError.discoveryHeadReplay,
             UpdateError.discoveryHeadEquivocation, UpdateError.discoveryHeadExpired:
            return .eligibility
        default:
            return .download
        }
    }

    static func defaultRollbackObserverAvailable(
        launchdProviderAvailable: Availability = { AutoUpdater.defaultLaunchdProviderAvailable() }
    ) -> Bool {
        if ProcessInfo.processInfo.environment["MACPROVIDER_ROLLBACK_OBSERVER_TEST_AVAILABLE"] == "1" {
            return true
        }
        return launchdProviderAvailable()
    }

    static func defaultLaunchdProviderAvailable() -> Bool {
        if ProcessInfo.processInfo.environment["MACPROVIDER_LAUNCHD_PROVIDER_TEST_AVAILABLE"] == "1" {
            return true
        }
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return [
            (SelfUpdate.launchdLabel, launchAgents.appendingPathComponent("\(SelfUpdate.launchdLabel).plist")),
            (SelfUpdate.legacyLaunchdLabel, launchAgents.appendingPathComponent("\(SelfUpdate.legacyLaunchdLabel).plist")),
        ].contains { label, plist in
            FileManager.default.fileExists(atPath: plist.path)
                && launchctlServiceLoaded(label: label)
        }
    }

    static func restartLaunchdIfInstalled() throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let launchAgents = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let hasProviderPlist = [
            SelfUpdate.launchdLabel,
            SelfUpdate.legacyLaunchdLabel,
        ].contains { label in
            FileManager.default.fileExists(
                atPath: launchAgents.appendingPathComponent("\(label).plist").path
            )
        }
        guard hasProviderPlist else {
            throw AutoUpdateError.other("unsupported_install_topology")
        }
        try SelfUpdate.reloadCompatibilityLaunchdJobs(
            homeDirectory: homeDirectory,
            serviceLoaded: { try SelfUpdate.launchctlServiceLoadedOrThrow(label: $0) },
            servicePresent: SelfUpdate.launchctlServicePresent,
            loadedServiceLabels: SelfUpdate.launchctlServiceLabels,
            runLaunchctl: { arguments, allowFailure in
                _ = try SelfUpdate.runLaunchctlCommand(
                    arguments: arguments,
                    allowFailure: allowFailure
                )
            }
        )
    }

    static func fenceReloadJobsIfInstalled() throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let launchAgents = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let hasProviderPlist = [
            SelfUpdate.launchdLabel,
            SelfUpdate.legacyLaunchdLabel,
        ].contains { label in
            FileManager.default.fileExists(
                atPath: launchAgents.appendingPathComponent("\(label).plist").path
            )
        }
        guard hasProviderPlist else {
            return
        }
        try SelfUpdate.fenceProviderReloadLaunchdJobs(
            homeDirectory: homeDirectory,
            servicePresent: SelfUpdate.launchctlServicePresent,
            loadedServiceLabels: SelfUpdate.launchctlServiceLabels,
            runLaunchctl: { arguments, allowFailure in
                _ = try SelfUpdate.runLaunchctlCommand(
                    arguments: arguments,
                    allowFailure: allowFailure
                )
            }
        )
    }

    static func launchctlServiceLoaded(
        label: String,
        executablePath: String = "/bin/launchctl",
        timeout: TimeInterval = 5
    ) -> Bool {
        SelfUpdate.launchctlServiceLoaded(
            label: label,
            executablePath: executablePath,
            timeout: timeout
        )
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
