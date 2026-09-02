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

/// Decision returned by the swap-boundary gate, evaluated inside the swap critical
/// section (no await between it and `activateReleasePayload`). This is the SINGLE
/// authoritative precedence/trust gate for the swap:
/// - `.proceed`: swap (non-accepted signed rail — no gate);
/// - `.ensureTrust`: run `ensureEligible(.swap)` then swap (primary rail — throws
///   `AutoUpdateError.trustStateLost` on degradation, preserving its rollback path);
/// - `.abort(reason:)`: do not swap; throw `AutoUpdateSwapPrecedenceAborted` so the
///   caller records the reason (the accepted-session R005 rail: trust/precedence).
enum AutoUpdateSwapBoundaryDecision: Sendable, Equatable {
    case proceed
    case ensureTrust
    case abort(reason: String)
}

struct AutoUpdateSwapPrecedenceAborted: Error {
    let reason: String
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
    /// True when this node is a headless_fleet / system-domain provider whose
    /// updates flow through the signed operator installer acceptance bundle
    /// (SPEC-020 R-4.13), not the consumer autoupdate path. Used to report the
    /// actionable `headless_operator_update_required` skip instead of a bare
    /// `unsupported_install_topology` forward-progress failure.
    let headlessOperatorManagedTopology: Availability
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
        headlessOperatorManagedTopology: Availability? = nil,
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
        self.headlessOperatorManagedTopology = headlessOperatorManagedTopology
            ?? { AutoUpdater.defaultHeadlessOperatorManagedTopology(config: config) }
        self.lifecycleLeaseStore = lifecycleLeaseStore
        self.evictStaleLocalStatusOwner = evictStaleLocalStatusOwner
    }

    /// Lightweight outcome of a single coordinator-recommendation cycle, used by
    /// the caller (CoordinatorClient) to drive SPEC-020-R005 accepted-session
    /// recovery. The mapping to exit points is:
    /// - `.notAttempted`: trust-skip, autoupdate-disabled, a headless operator-update
    ///   handoff (`headless_operator_update_required`), an invalid/unparseable
    ///   recommended version, or `target_not_newer`. Not counted, not reset — the
    ///   recommendation never engaged a real target and recorded no failure.
    /// - `.missingTarget`: the coordinator advertised a `recommended_binary_version`
    ///   with no installable compatibility-set target
    ///   (`coordinator_compatibility_target_missing`).
    /// - `.cooldownActive`: an active discovery/target cooldown skipped the attempt.
    /// - `.forwardProgressFailure`: any `fail(...)` for a present target before the
    ///   compatibility-target gate is cleared (target-revoked/below-minimum,
    ///   topology/observer, release-not-found, prepare/download failure,
    ///   compatibility-set mismatch).
    /// - `.forwardProgress`: execution reached past the compatibility-target gate
    ///   (a successful detect→prepare with a matching compatibility set), or the
    ///   update succeeded. Later transient failures past the gate still count as
    ///   forward progress because the stuck condition has been cleared.
    enum RecommendationOutcome: Sendable, Equatable {
        case notAttempted
        case missingTarget
        case cooldownActive
        case forwardProgressFailure
        case forwardProgress
    }

    @discardableResult
    func handleCoordinatorRecommendation(_ rawRecommended: String) async -> RecommendationOutcome {
        let updateID = UUID().uuidString.lowercased()
        let entryTrust = await trustProvider()
        guard !SessionAutoupdateGate.shared.isDisabled else {
            await record(updateID: updateID, target: "<session-disabled>", phase: .eligibility, outcome: .skipped, reason: "signed_policy_persist_failed", attempt: 1)
            return .notAttempted
        }
        guard entryTrust.isEligible else {
            await record(updateID: updateID, target: "<notify-only>", phase: .eligibility, outcome: .skipped, reason: entryTrust.lossReason, attempt: 1)
            return .notAttempted
        }
        let validated: AutoUpdateRecommendation
        do {
            validated = try AutoUpdateRecommendation.validate(rawRecommended)
        } catch let AutoUpdateValidationError.versionTooLong(sha) {
            await record(updateID: updateID, target: "<redacted>", phase: .eligibility, outcome: .failure, reason: "version_too_long", attempt: 1, failure: .recommendedVersionInvalid, sha: sha)
            return .notAttempted
        } catch AutoUpdateValidationError.componentTooLong {
            await record(updateID: updateID, target: "<invalid>", phase: .eligibility, outcome: .failure, reason: "version_component_too_long", attempt: 1, failure: .recommendedVersionInvalid)
            return .notAttempted
        } catch {
            await record(updateID: updateID, target: "<invalid>", phase: .eligibility, outcome: .failure, reason: "recommended_version_invalid", attempt: 1, failure: .recommendedVersionInvalid)
            return .notAttempted
        }

        let target = validated.normalized
        await record(updateID: updateID, target: target, phase: .detection, outcome: .inProgress, reason: "recommended_binary_version_detected", attempt: 1)
        let commitTracker = AutoUpdateCommitTracker()
        // Set once execution clears the compatibility-target gate; from that point
        // any later failure is still forward progress for R005 accounting because
        // the stuck condition (cannot get an installable target past the gate) is
        // resolved.
        var forwardProgressReached = false
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
            return .notAttempted
        }
        guard AutoUpdateConfig.enabled(config) else {
            print("A newer version is available (v\(target)), but autoupdate is disabled.")
            await record(updateID: updateID, target: target, phase: .eligibility, outcome: .skipped, reason: "autoupdate_disabled", attempt: 1)
            return .notAttempted
        }
        do {
            let policy = markerStore.effectivePolicy()
            if let minimum = policy.minimum, SelfUpdate.compareSemver(target, minimum) == .orderedAscending || policy.revoked.contains(target) {
                // fail(...) records a cooldown/failure for this target, so per
                // SPEC-020-R005 this is a recorded forward-progress failure cycle
                // and MUST increment the counter (not .notAttempted). A revoked or
                // below-minimum target is refused for every profile, so it wins
                // ahead of the headless handoff.
                await fail(updateID: updateID, target: target, phase: .eligibility, failure: .targetRevokedOrBelowMinimum, reason: "target_revoked_or_below_minimum")
                return .forwardProgressFailure
            }
            // A headless_fleet / system-domain provider is operator-managed: SPEC-020
            // R-4.13 forbids the consumer autoupdate path from driving it. Divert
            // BEFORE the install-topology gate and every later mutating gate
            // (cooldown/download/swap) so it is never driven even when a stale or
            // loaded consumer LaunchAgent would make launchdProviderAvailable()
            // true, and so it never records a topology forward-progress failure
            // that would strand it into the R005 signed recovery rail (which hits
            // the same operator boundary). Placed after the revoked/minimum policy
            // check, which is non-mutating and still wins.
            guard !headlessOperatorManagedTopology() else {
                print("A newer version is available (v\(target)), but headless_fleet providers update through the signed operator installer acceptance bundle, not consumer autoupdate.")
                await record(updateID: updateID, target: target, phase: .eligibility, outcome: .skipped, reason: "headless_operator_update_required", attempt: 1)
                return .notAttempted
            }
            guard launchdProviderAvailable() else {
                await fail(updateID: updateID, target: target, phase: .eligibility, failure: .other, reason: "unsupported_install_topology")
                return .forwardProgressFailure
            }
            guard rollbackObserverAvailable() else {
                await fail(updateID: updateID, target: target, phase: .eligibility, failure: .rollbackObserverUnavailable, reason: "rollback_observer_unavailable")
                return .forwardProgressFailure
            }
            try markerStore.ensureTrustedRoot()
            if let activeCooldown = markerStore.activeCooldown(target: target) {
                await record(updateID: updateID, target: target, phase: .cooldown, outcome: .skipped, reason: "cooldown_\(activeCooldown.failureClass.rawValue)_until_\(ISO8601DateFormatter.autoupdate.string(from: activeCooldown.until))", attempt: activeCooldown.attempt)
                return .cooldownActive
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
                return .forwardProgressFailure
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
                return .missingTarget
            }
            let prepared: PreparedSelfUpdate
            do {
                prepared = try await update.prepareValidatedUpdate(from: release)
            } catch {
                let failure = Self.failureClass(for: error)
                await fail(updateID: updateID, target: target, phase: Self.phase(for: error), failure: failure, reason: Self.redactedReason(for: error))
                return .forwardProgressFailure
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
                return .forwardProgressFailure
            }
            // Past the compatibility-target gate: a matching installable target was
            // resolved and prepared, so R005 treats this recommendation as making
            // forward progress even if a later transient (drain/restart) fails.
            forwardProgressReached = true
            if try markerStore.preflightInstalledMalibuAppReplacement() != nil,
               prepared.stagedMalibuApp == nil {
                await fail(
                    updateID: updateID,
                    target: target,
                    phase: .eligibility,
                    failure: .other,
                    reason: "signed_malibu_bundle_missing"
                )
                return .forwardProgress
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
                return .forwardProgress
            }
            try await ensureEligible(phase: .backup)
            try await preserveMarkerAndSwap(
                updateID: updateID,
                target: target,
                prepared: prepared,
                tracker: commitTracker,
                authorityMode: "coordinator_recommendation",
                discoveryHead: nil,
                swapBoundaryGate: { .ensureTrust },
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
                return .forwardProgress
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
        // Success path falls through here (forwardProgressReached == true). Every
        // caught failure also reaches here: forward progress if it happened past
        // the compatibility-target gate, otherwise a forward-progress failure.
        return forwardProgressReached ? .forwardProgress : .forwardProgressFailure
    }

    func handleSignedReleaseDiscovery(
        attribution: [String: String] = [:],
        preSwapGuard: (@Sendable () async -> String?)? = nil,
        swapBoundaryGate: (@Sendable () async -> AutoUpdateSwapBoundaryDecision)? = nil
    ) async {
        let updateID = UUID().uuidString.lowercased()
        // SPEC-020-R005 / R-6.8 (round-4 MEDIUM-2): the coordinator only ever sees
        // `last_autoupdate_event`, so if any terminal event on an R005-triggered
        // invocation dropped the attribution, a later plain `github_poll` event
        // would overwrite the R005 marker and the invocation would be
        // indistinguishable from an ordinary poll. These helpers stamp the R005
        // `attribution` (empty for the non-accepted path, i.e. unchanged) onto
        // EVERY record/fail in this invocation so whichever event lands last still
        // carries the marker.
        func recordR005(target: String, phase: AutoUpdatePhase, outcome: AutoUpdateOutcome, reason: String, attempt: Int = 1) async {
            await record(updateID: updateID, target: target, source: .githubPoll, phase: phase, outcome: outcome, reason: reason, attempt: attempt, extraMetadata: attribution)
        }
        func failR005(target: String, phase: AutoUpdatePhase, failure: AutoUpdateFailureClass, reason: String) async {
            await fail(updateID: updateID, target: target, source: .githubPoll, phase: phase, failure: failure, reason: reason, extraMetadata: attribution)
        }

        // When invoked to recover an accepted-but-stuck session, emit a distinct,
        // attributable marker up front.
        if !attribution.isEmpty {
            await recordR005(target: "<discovery>", phase: .eligibility, outcome: .inProgress, reason: "accepted_session_recovery_signed_rail_invoked")
        }
        guard !SessionAutoupdateGate.shared.isDisabled else {
            await recordR005(target: "<session-disabled>", phase: .eligibility, outcome: .skipped, reason: "signed_policy_persist_failed")
            return
        }
        guard AutoUpdateConfig.enabled(config) else {
            await recordR005(target: "<disabled>", phase: .eligibility, outcome: .skipped, reason: "autoupdate_disabled")
            return
        }
        // Same operator-managed boundary as the coordinator path: the signed
        // recovery rail cannot converge a headless_fleet / system-domain provider
        // either, so divert to the actionable skip before any mutating gate rather
        // than emitting a topology failure. See SPEC-020 R-4.13.
        guard !headlessOperatorManagedTopology() else {
            await recordR005(target: "<headless-operator-update>", phase: .eligibility, outcome: .skipped, reason: "headless_operator_update_required")
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
                await failR005(target: "<unknown>", phase: .eligibility, failure: .other, reason: "unsupported_install_topology")
                return
            }
            guard rollbackObserverAvailable() else {
                await failR005(target: "<unknown>", phase: .eligibility, failure: .rollbackObserverUnavailable, reason: "rollback_observer_unavailable")
                return
            }
            try markerStore.ensureTrustedRoot()
            if let activeCooldown = markerStore.activeCooldown(target: "<discovery>") {
                await recordR005(target: "<discovery>", phase: .cooldown, outcome: .skipped, reason: "cooldown_\(activeCooldown.failureClass.rawValue)_until_\(ISO8601DateFormatter.autoupdate.string(from: activeCooldown.until))", attempt: activeCooldown.attempt)
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
                await failR005(target: "<discovery>", phase: .eligibility, failure: .discoveryHeadReplay, reason: "discovery_head_replay")
                return
            } catch UpdateError.discoveryHeadEquivocation {
                await failR005(target: "<discovery>", phase: .eligibility, failure: .discoveryHeadEquivocation, reason: "discovery_head_equivocation")
                return
            } catch UpdateError.discoveryHeadExpired {
                await failR005(target: "<discovery>", phase: .eligibility, failure: .discoveryHeadExpired, reason: "discovery_head_expired")
                return
            }
            let target = head.targetVersion
            await recordR005(target: target, phase: .detection, outcome: .inProgress, reason: "signed_release_discovery_detected")
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
                await recordR005(target: target, phase: .eligibility, outcome: .noop, reason: "target_not_newer")
                return
            }
            let policy = markerStore.effectivePolicy()
            if let minimum = policy.minimum, SelfUpdate.compareSemver(target, minimum) == .orderedAscending || policy.revoked.contains(target) {
                await failR005(target: target, phase: .eligibility, failure: .targetRevokedOrBelowMinimum, reason: "target_revoked_or_below_minimum")
                return
            }
            if let activeCooldown = markerStore.activeCooldown(target: target) {
                await recordR005(target: target, phase: .cooldown, outcome: .skipped, reason: "cooldown_\(activeCooldown.failureClass.rawValue)_until_\(ISO8601DateFormatter.autoupdate.string(from: activeCooldown.until))", attempt: activeCooldown.attempt)
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
                await failR005(target: target, phase: .eligibility, failure: .other, reason: "discovery_compatibility_target_mismatch")
                return
            }
            if try markerStore.preflightInstalledMalibuAppReplacement() != nil,
               prepared.stagedMalibuApp == nil {
                await failR005(target: target, phase: .eligibility, failure: .other, reason: "signed_malibu_bundle_missing")
                return
            }
            // round-4 HIGH-1(b): re-validate the accepted-session invariants after
            // the suspending discovery/prepare awaits and BEFORE any coordinator-
            // visible drain or the swap. Trust-loss or primary-rail forward progress
            // in the interim aborts the cycle (a later re-observation retries).
            if let preSwapGuard, let abortReason = await preSwapGuard() {
                await recordR005(target: providerTarget, phase: .eligibility, outcome: .skipped, reason: abortReason)
                return
            }
            maintenanceLease = try lifecycleLeaseStore.acquire(
                kind: .maintenance,
                operationID: "autoupdate:\(updateID)",
                duration: TimeInterval(prepared.compatibilityManifest.maintenanceLeaseSeconds)
            )
            let drained = try await drain(providerTarget)
            guard drained else {
                await failR005(target: providerTarget, phase: .drain, failure: .drainTimeout, reason: "drain_timeout")
                try? await sendReady()
                return
            }
            do {
                try await preserveMarkerAndSwap(
                    updateID: updateID,
                    target: providerTarget,
                    prepared: prepared,
                    tracker: commitTracker,
                    authorityMode: "signed_release",
                    discoveryHead: head,
                    // round-6 HIGH: the swap-boundary gate is the SINGLE authoritative
                    // precedence/trust check, evaluated inside the swap critical
                    // section with no await before activateReleasePayload. For the
                    // accepted-session rail it re-runs the FULL trust + generation +
                    // identity + eligibility decision AT the swap boundary, so a
                    // context change during the drain await aborts the swap. The
                    // non-accepted rail passes nil → { .proceed }, unchanged.
                    swapBoundaryGate: swapBoundaryGate ?? { .proceed },
                    whileHolding: lock
                )
            } catch let abort as AutoUpdateSwapPrecedenceAborted {
                // Accepted-session precedence/trust abort AT the swap boundary: the
                // marker/backup were already unwound by preserveMarkerAndSwap; record
                // the R005-attributed skip and do not proceed.
                await recordR005(target: providerTarget, phase: .swap, outcome: .skipped, reason: abort.reason)
                return
            }
            await recordR005(target: providerTarget, phase: .swap, outcome: .success, reason: "binary_swap_complete")
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
                await failR005(target: providerTarget, phase: .restart, failure: .other, reason: Self.redactedReason(for: error))
                return
            }
            await recordR005(target: providerTarget, phase: .restart, outcome: .inProgress, reason: "launchctl_restart_invoked")
        } catch AutoUpdateMarkerError.lockContended {
            await failR005(target: "<unknown>", phase: .eligibility, failure: .autoupdateAlreadyPending, reason: "provider_mutation_in_progress")
        } catch AutoUpdateMarkerError.transactionPending {
            await failR005(target: "<unknown>", phase: .eligibility, failure: .autoupdateAlreadyPending, reason: "autoupdate_already_pending")
        } catch {
            let failure = Self.failureClass(for: error)
            await failR005(target: "<unknown>", phase: Self.phase(for: error), failure: failure, reason: Self.redactedReason(for: error))
        }
    }

    private func preserveMarkerAndSwap(
        updateID: String,
        target: String,
        prepared: PreparedSelfUpdate,
        tracker: AutoUpdateCommitTracker,
        authorityMode: String,
        discoveryHead: SignedReleaseDiscoveryHead?,
        swapBoundaryGate: @Sendable () async -> AutoUpdateSwapBoundaryDecision,
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
            // Swap-boundary gate: the authoritative precedence/trust check. There is
            // NO await between this decision and activateReleasePayload below (the
            // `.abort` and `.proceed` arms are synchronous, and the single await in
            // `.ensureTrust` is the primary rail's own trust check under its own held
            // lock), so nothing can interleave between the decision and the swap.
            switch await swapBoundaryGate() {
            case .proceed:
                break
            case .ensureTrust:
                try await ensureEligible(phase: .swap)
            case let .abort(reason):
                throw AutoUpdateSwapPrecedenceAborted(reason: reason)
            }
            try markerStore.activateReleasePayload(
                from: prepared.newBinary.deletingLastPathComponent(),
                newBinary: prepared.newBinary,
                to: current,
                stagedMalibuApp: prepared.stagedMalibuApp,
                rollbackMarker: marker
            )
            tracker.committedSwap = true
        } catch let abort as AutoUpdateSwapPrecedenceAborted where !tracker.committedSwap {
            // round-7 HIGH: a swap-boundary precedence/trust abort is a PRE-activation
            // abort — nothing was swapped (committedSwap == false; activateReleasePayload
            // never ran, the live binary is unchanged). Fully roll back the pending
            // transaction: clear the pending marker AND release the lock, leaving NO
            // durable pending state. Otherwise the primary rail that SUPERSEDED this
            // recovery would be locked out by the leftover `awaiting_previous_readiness`
            // pending marker (acquireLock rejects any pending marker) — inverting the
            // precedence the abort was meant to enforce. This is deliberately NOT the
            // restoreBackupAfterFencing preserve-for-startup path, which exists only for
            // genuine mid/post-activation fencing failures where partial state must
            // survive; the discrimination is strictly on the abort error type with no
            // activation side effect, never broadened to arbitrary thrown errors.
            markerStore.removeRollbackBackups(marker)
            markerStore.clearPendingAndLock(target: nil)
            throw abort
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
        let decision: AutoUpdateSwapBoundaryDecision = requireCurrentTrustAtSwap ? .ensureTrust : .proceed
        try await preserveMarkerAndSwap(
            updateID: updateID,
            target: target,
            prepared: prepared,
            tracker: AutoUpdateCommitTracker(),
            authorityMode: authorityMode,
            discoveryHead: discoveryHead,
            swapBoundaryGate: { decision },
            whileHolding: lock
        )
    }

    func preserveMarkerAndSwapForTest(
        updateID: String,
        target: String,
        prepared: PreparedSelfUpdate,
        authorityMode: String,
        discoveryHead: SignedReleaseDiscoveryHead?,
        swapBoundaryGate: @escaping @Sendable () async -> AutoUpdateSwapBoundaryDecision
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
            swapBoundaryGate: swapBoundaryGate,
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

    private func fail(updateID: String, target: String, source: AutoUpdateSource = .coordinator, phase: AutoUpdatePhase, failure: AutoUpdateFailureClass, reason: String, extraMetadata: [String: String] = [:]) async {
        markerStore.recordCooldown(target: target, failureClass: failure)
        await record(updateID: updateID, target: target, source: source, phase: phase, outcome: .failure, reason: reason, attempt: 1, failure: failure, extraMetadata: extraMetadata)
    }

    private func record(updateID: String, target: String, source: AutoUpdateSource = .coordinator, phase: AutoUpdatePhase, outcome: AutoUpdateOutcome, reason: String, attempt: Int, failure: AutoUpdateFailureClass? = nil, sha: String? = nil, extraMetadata: [String: String] = [:]) async {
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
            recommendedBinaryVersionSHA256: sha,
            extraMetadata: extraMetadata
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

    /// Positive determination that this node is a headless_fleet / system-domain
    /// provider whose updates are operator-managed through the signed installer
    /// acceptance bundle rather than the consumer autoupdate path (SPEC-020
    /// R-4.13). Grounded in the same authorities the mutating-update gate uses
    /// (`MacProviderCLI.validateHeadlessUpdateMode`): `protected_file` credential
    /// custody, an install manifest declaring the `headless_fleet` profile or
    /// `system` launchd domain, or a managed system LaunchDaemon present on disk,
    /// loaded in launchd, or in an indeterminate launchd state. Read-only and
    /// non-mutating, but NOT free: reaching the system-artifact check runs
    /// `launchctl print` (via `validateNoHeadlessSystemArtifactsPresent`), so keep
    /// it off hot paths. The cheap `protected_file` and manifest signals
    /// short-circuit before any `launchctl` call.
    static func defaultHeadlessOperatorManagedTopology(
        config: AppConfig,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        loadInstallManifest: () -> UninstallCommand.ManifestLoadResult? = {
            try? UninstallCommand.loadManifest(home: FileManager.default.homeDirectoryForCurrentUser)
        },
        runLaunchctl: ([String]) throws -> Int32 = { arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    ) -> Bool {
        // Canonical headless custody marker (same as validateHeadlessUpdateMode).
        if config.credentialStore == .protectedFile {
            return true
        }
        // Install manifest declaring the headless profile / system domain. A
        // manifest that fails to load (nil) is invalid/indeterminate — fail closed
        // to headless so an unprovable topology is never driven by the consumer
        // path (SPEC-020 R-4.13).
        switch loadInstallManifest() {
        case .some(.loaded(let manifest)):
            if manifest.installProfile == "headless_fleet" || manifest.launchdDomain == "system" {
                return true
            }
        case .some(.missing):
            break
        case .none:
            return true
        }
        // Managed system-domain LaunchDaemon present on disk, loaded in launchd, or
        // in an indeterminate launchd state: validateNoHeadlessSystemArtifactsPresent
        // throws for any of these (parity with validateHeadlessUpdateMode), so a
        // throw means headless / fail closed and a clean return means a proven
        // consumer topology.
        do {
            try UninstallCommand.validateNoHeadlessSystemArtifactsPresent(
                fileExists: fileExists,
                run: runLaunchctl
            )
            return false
        } catch {
            return true
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
