import Darwin
import Foundation

/// F3 (#1363): a failed self-update can leave the provider wedged with no
/// in-CLI escape. The failure leaves `pending.json` in a `restoring_previous`
/// transaction *and* an updater-owned `rollback_in_progress` lifecycle record.
/// Two fences then lock the provider, and the only path that clears them runs
/// inside `serve`, which is itself fenced:
///
///  1. `serve`'s `starting_provider` transition is fenced because
///     `ProviderLifecycleState.validateTransition` only lets `serve` leave an
///     *updater*-owned rollback/update state when it presents the exact
///     `operation_id` from that record. A fresh launchd child has no such
///     handoff lease, so `serve` exits before it can run marker recovery.
///  2. `pending.json` makes `update` refuse with `.transactionPending`, and the
///     expired-`marker_deadline` self-clear (`recoverOrphanedMarker`) only runs
///     from `CoordinatorClient.runStartupAutoupdateRecovery`, reachable only
///     after `serve` passes fence #1.
///
/// This routine recovers exactly that wedge without depending on `serve` being
/// up. It is driven both from a first-class `macprovider-cli recover-update`
/// subcommand and from `serve` startup itself (so the launchd respawn loop
/// self-heals). It mirrors what `install.sh`'s rollback recovery already does:
/// recover the expired pending marker, then translate the dead updater-owned
/// `rollback_in_progress` record into an *installer*-owned one, which `serve`
/// is always permitted to leave.
///
/// Safety: a genuinely mid-rollback provider is never un-fenced. The routine
/// serializes with installers/updaters through the recovery lock (a live owner
/// refuses the whole operation) and only touches a transaction whose
/// `marker_deadline` has already expired (a future deadline means a real
/// update/rollback still owns the provider).
struct WedgedUpdateRecovery {
    struct Environment {
        var now: () -> Date = { Date() }
        var processID: () -> Int32 = { getpid() }
    }

    /// Reason code stamped on the translated installer-owned record. Distinct
    /// from install.sh's `install_rollback_restored_translated` so the CLI
    /// recovery path is attributable in the lifecycle journal.
    static let translationReasonCode = "updater_rollback_recovered_by_cli"

    let markerStore: AutoUpdateMarkerStore
    let lifecycleStore: ProviderLifecycleStateStore
    var environment = Environment()
    var leaseStore: ProviderLifecycleLeaseStore? = nil
    var fenceReloadJobs: () throws -> Void = { try AutoUpdater.fenceReloadJobsIfInstalled() }
    var expectedProviderID: String? = nil

    private var lifecycleLeaseStore: ProviderLifecycleLeaseStore {
        leaseStore ?? ProviderLifecycleLeaseStore(
            url: lifecycleStore.url.deletingLastPathComponent().appendingPathComponent("lease.json")
        )
    }

    enum Outcome: Equatable {
        /// No abandoned wedge was found; nothing changed.
        case noWedge
        /// A live installer/updater owner holds the mutation lock, so a genuine
        /// mutation may be in flight; refused without touching any state.
        case ownerLive
        /// A pending transaction whose `marker_deadline` is still in the future
        /// owns the provider; refused so a genuine in-progress update/rollback
        /// is never silently un-fenced.
        case transactionActive
        /// Authority, backup, storage, or rollback validation failed. No lease
        /// retirement or lifecycle translation is authorized by this outcome.
        case recoveryRefused(String)
        /// The abandoned wedge was recovered. `markerOutcome` is nil when there
        /// was no pending marker (only the lifecycle fence was cleared).
        case recovered(markerOutcome: AutoUpdateOrphanRecoveryOutcome?, lifecycleUnfenced: Bool)
    }

    /// A lifecycle record fences a fresh `serve` child only when it is an
    /// updater-owned rollback/update state; an installer-owned maintenance
    /// state is always leavable by `serve`.
    static func lifecycleIsFencedUpdaterState(_ record: ProviderLifecycleStateRecord?) -> Bool {
        guard let record else { return false }
        return record.writer == .updater
            && (record.state == .rollbackInProgress || record.state == .updateInProgress)
    }

    static func markerDeadlineExpired(_ raw: String, now: Date) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let deadline = formatter.date(from: raw) else {
            // An unparseable deadline is treated as expired, matching
            // CoordinatorClient.autoupdateMarkerDeadlineExpired.
            return true
        }
        return now >= deadline
    }

    func recover(requirePreparedHandoff: Bool = false) -> Outcome {
        // Serialize with installers/updaters and prove no live owner. The
        // recovery lock is refused (lockContended) whenever an installer or
        // updater is alive, so a genuine mutation in flight can never be
        // clobbered by recovery.
        let lock: AutoUpdateLock
        do {
            lock = try markerStore.acquireRecoveryLock()
        } catch {
            return .ownerLive
        }
        defer { withExtendedLifetime(lock) {} }

        let pending: AutoUpdatePendingMarker?
        do { pending = try markerStore.readPending() }
        catch { return .recoveryRefused("pending marker is invalid or unreadable") }
        if requirePreparedHandoff, pending == nil { return .noWedge }
        let inspection = lifecycleLeaseStore.inspect()
        let record: ProviderLifecycleLeaseRecord?
        switch inspection {
        case .missing: record = nil
        case .valid(let value): record = value
        case .invalidOrExpired(let value, _):
            guard let value else { return .recoveryRefused("lifecycle lease is invalid or unreadable") }
            record = value
        }
        if let record, record.startupHandoff?.state == .prepared {
            if requirePreparedHandoff,
               !record.operationID.hasPrefix("self-update:"),
               !record.operationID.hasPrefix("autoupdate:") { return .noWedge }
            return recoverPreparedHandoff(record, pending: pending)
        }
        if requirePreparedHandoff {
            // Recover the interruption between retirement and marker cleanup.
            // Adopted and other unrelated leases keep their existing startup path.
            guard record == nil,
                  let lifecycle = try? lifecycleStore.current(),
                  Self.lifecycleIsFencedUpdaterState(lifecycle)
                    || (lifecycle.writer == .installer && lifecycle.state == .rollbackInProgress
                        && lifecycle.reasonCode == Self.translationReasonCode) else { return .noWedge }
            guard let pending,
                  (try? markerStore.validateMarker(pending)) != nil,
                  (try? markerStore.validateBackup(pending)) != nil,
                  (try? AutoUpdateMarkerStore.sha256(file: URL(fileURLWithPath: pending.targetPath)))
                    == pending.sha256 else { return .noWedge }
        }
        if let record {
            do {
                return try lifecycleLeaseStore.withAbandonedLease(matching: record) {
                    recoverLegacyWedge(pending: pending)
                }
            } catch { return .recoveryRefused("lifecycle lease still owns recovery: \(error)") }
        }
        return recoverLegacyWedge(pending: pending)
    }

    private func recoverLegacyWedge(pending: AutoUpdatePendingMarker?) -> Outcome {
        var markerOutcome: AutoUpdateOrphanRecoveryOutcome?
        if let marker = pending {
            // Only an abandoned (expired-deadline) transaction may be recovered.
            // A future deadline means a genuine in-progress update/rollback owns
            // the provider; leave every fence intact.
            guard Self.markerDeadlineExpired(marker.markerDeadline, now: environment.now()) else {
                return .transactionActive
            }
            do { try fenceReloadJobs() }
            catch { return .recoveryRefused("reload helpers could not be fenced") }
            markerOutcome = markerStore.recoverOrphanedMarker(marker)
            switch markerOutcome {
            case .restored, .restoredAwaitingReadiness: break
            default: return .recoveryRefused("rollback could not safely restore the previous release")
            }
        }

        // Clear the lifecycle fence only for a dead updater-owned maintenance
        // state, translating it into an installer-owned rollback_in_progress
        // record so a fresh serve child can leave it. serve is always allowed
        // to leave an installer-written maintenance state; it is only fenced on
        // an updater-owned one whose operation id it cannot match.
        var lifecycleUnfenced = false
        if let current = try? lifecycleStore.current(),
           Self.lifecycleIsFencedUpdaterState(current) {
            let operationID = "install-rollback:\(environment.processID())"
            if (try? lifecycleStore.transition(
                to: .rollbackInProgress,
                reasonCode: Self.translationReasonCode,
                writer: .installer,
                providerID: current.providerID,
                modelID: current.modelID,
                compatibilitySetID: current.compatibilitySetID,
                operationID: operationID,
                operatorPaused: current.operatorPauseRequested,
                now: environment.now()
            )) != nil {
                lifecycleUnfenced = true
            }
        }

        if markerOutcome == nil, !lifecycleUnfenced {
            return .noWedge
        }
        return .recovered(markerOutcome: markerOutcome, lifecycleUnfenced: lifecycleUnfenced)
    }

    private func recoverPreparedHandoff(
        _ record: ProviderLifecycleLeaseRecord,
        pending: AutoUpdatePendingMarker?
    ) -> Outcome {
        guard let marker = pending else {
            return .recoveryRefused("prepared startup handoff has no matching pending marker")
        }
        guard Self.markerDeadlineExpired(marker.markerDeadline, now: environment.now()) else {
            return .transactionActive
        }
        do {
            try markerStore.validateMarker(marker)
            try markerStore.validateBackup(marker)
            try markerStore.ensureRollbackTargetAllowed(marker)
            guard let handoff = record.startupHandoff,
                  let lifecycle = try lifecycleStore.current(),
                  lifecycle.operationID == record.operationID
                    // An operator command may supersede the updater's lifecycle
                    // operation without retiring its prepared lease. Authority
                    // still comes from the matching marker/handoff below and
                    // the expiry + dead-owner checks under the lease lock.
                    || lifecycle.writer == .operatorCommand
                    || (marker.transactionState == .awaitingPreviousReadiness
                        && lifecycle.writer == .installer
                        && lifecycle.state == .rollbackInProgress
                        && lifecycle.reasonCode == Self.translationReasonCode),
                  lifecycle.providerID == nil || lifecycle.providerID == handoff.providerID,
                  (expectedProviderID ?? lifecycle.providerID) == handoff.providerID,
                  handoff.operationID == record.operationID,
                  handoff.serviceIdentity == ServeCommand.providerLaunchdServiceIdentity,
                  marker.targetPath == handoff.targetExecutablePath,
                  lifecycle.compatibilitySetID == nil
                    || marker.targetCompatibilitySetID == lifecycle.compatibilitySetID,
                  (marker.commitOwner == "coordinator"
                    && record.operationID == "autoupdate:\(marker.updateID)")
                    || (marker.commitOwner == "self_update"
                        && record.operationID.hasPrefix("self-update:")) else {
                return .recoveryRefused("pending marker, lifecycle, and prepared handoff do not match")
            }
            let digest = try AutoUpdateMarkerStore.sha256(file: URL(fileURLWithPath: marker.targetPath))
            guard digest == handoff.targetExecutableSHA256
                    || digest == marker.sha256 else {
                return .recoveryRefused("installed executable does not match the abandoned transaction")
            }
            var outcome: AutoUpdateOrphanRecoveryOutcome?
            try lifecycleLeaseStore.retireExpiredPreparedStartupHandoff(matching: record) {
                try fenceReloadJobs()
                // Retain the marker and backup on any restoration refusal. In
                // particular, a signed-policy denial must never un-fence serve.
                let recovered = try markerStore.restoreBackupAwaitingPreviousReadiness(marker)
                if recovered.transactionState == .awaitingPreviousReadiness {
                    outcome = .restoredAwaitingReadiness(recovered)
                } else {
                    outcome = .restored(marker)
                }
            }
            // Retire first: a crash here leaves the existing generic rollback
            // recovery able to translate the lifecycle on the next startup.
            _ = try lifecycleStore.transition(
                to: .rollbackInProgress,
                reasonCode: Self.translationReasonCode,
                writer: .installer,
                providerID: handoff.providerID,
                modelID: lifecycle.modelID,
                compatibilitySetID: lifecycle.compatibilitySetID,
                operationID: "install-rollback:\(environment.processID())",
                operatorPaused: lifecycle.operatorPauseRequested,
                now: environment.now()
            )
            if case .restored = outcome {
                markerStore.clearPending()
                markerStore.removeRollbackBackups(marker)
            }
            markerStore.recordCooldown(target: marker.targetVersion, failureClass: .orphanedPendingMarker)
            return .recovered(markerOutcome: outcome, lifecycleUnfenced: true)
        } catch {
            return .recoveryRefused("abandoned handoff recovery refused: \(error)")
        }
    }

}
