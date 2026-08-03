import Combine
import Foundation

// AUDIT R1 + R2 fixes wired into this file:
//   - H1 (R1): crash reconnect used to re-enter start() while `child` was still
//         non-nil, so the guard returned immediately and the daemon never
//         restarted. We now nil `child` before scheduling reconnect.
//   - H2 (R1): intentional stop paths must NOT fire onUnexpectedExit; a flag on
//         CLIChildProcess suppresses the callback and MalibuAgent cancels
//         any pending reconnect task before setting child = nil.
//   - H3 (R2): reconnect task could complete `start()` AFTER shutdown() returned.
//         We now gate `start()` on an isShuttingDown flag and re-check it after
//         every suspension.
//   - H4 (R2): `start()` refuses to launch when ProviderConfig.isConfigured
//         is false. Onboarding "Start earning" no longer bypasses the deep-
//         link + Keychain gate.
//   - A1 (R1+R2): pause/resume no longer optimistically flip snapshot.state.
//         A legacy all-zero metrics tuple is treated as unavailable so older
//         supported CLI peers cannot misreport "no earnings" as authoritative.

@MainActor
final class MalibuAgent: ObservableObject {
    @Published private(set) var snapshot: AgentSnapshot = .empty
    @Published private(set) var logLines: [String] = []
    @Published private(set) var providerStartFailure: String?

    private var child: CLIChildProcess?
    private var control: ControlSocketClient?
    private var metricsPoller: Task<Void, Never>?
    private var eventStreamTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var providerLogTail: ProviderLogTail?
    private var providerLogTailCancellable: AnyCancellable?
    private var reconnect = ReconnectPolicy()
    private let thermalMonitor = ThermalMonitor()
    private var cancellables: Set<AnyCancellable> = []
    // AUDIT R2 CODE H3 fix: once shutdown begins, refuse any subsequent start()
    // — including a reconnect Task that already slept past its cancellation
    // check but hadn't yet re-entered the MainActor.
    private var isShuttingDown: Bool = false
    private var healthPollTask: Task<Void, Never>?
    private var monitorsLaunchdProvider = false
    private var lastRequestsRateSample: (total: Int, date: Date)?
    private var latestReleaseFetchedAt: Date?
    private var cliUpdateTask: Task<Void, Never>?
    private var hardwareVerificationRetryTask: Task<Void, Never>?
    /// Set while corrective `--recover-hardware-admission` may have drained
    /// launchd and therefore owes a restore/bootstrap. Cleared on success.
    private var hardwareRecoveryOwnsLaunchdRestore = false
    private var credentialRepairTask: Task<Void, Never>?
    private var admissionIdentityRecoveryTask: Task<Void, Never>?
    private var referralStatusExpiryTask: Task<Void, Never>?
    private let referralActionWatchdog = ReferralActionWatchdog()
    private var lastReferralRefreshRequestedAt: Date?
    private let latestReleaseTTL: TimeInterval = 3600

    init(initialSnapshot: AgentSnapshot = .empty) {
        snapshot = initialSnapshot
        thermalMonitor.$state
            .sink { [weak self] state in
                self?.snapshot.thermalState = state
            }
            .store(in: &cancellables)
        snapshot.thermalState = thermalMonitor.state
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isShuttingDown else { return }

        guard ProviderConfig.readProviderID() != nil else {
            snapshot.state = .error
            snapshot.lastError = "Not set up yet. Click Launch Provider to activate."
            return
        }
        guard StartupState.launchdInstallEvidenceExists() else {
            snapshot.state = .error
            snapshot.lastError = "Not set up yet. Click Launch Provider to run the installer."
            return
        }
        guard await ProviderConfig.isConfigured else {
            snapshot.state = .error
            snapshot.lastError = "Not set up yet. Click Launch Provider to activate."
            return
        }

        // Release any Malibu-spawned CLI from older builds before attaching to launchd.
        await releaseSpawnedChildForLaunchdMonitor()

        snapshot.state = .starting
        startProviderLogTail()
        if await monitorInstalledProviderIfPresent() {
            return
        }

        if let failure = providerStartFailure {
            snapshot.state = .error
            snapshot.lastError = failure
            return
        }
        guard !isShuttingDown else { return }

        if let failure = diagnosedProviderFailure() {
            providerStartFailure = failure
            snapshot.state = .error
            snapshot.lastError = failure
            return
        }

        snapshot.state = .reconnecting
        snapshot.lastError = ProviderLogDiagnostics.timeoutMessage(
            logHint: ProviderLogDiagnostics.logHint()
        )
        await scheduleReconnect()
    }

    // Do not flip state until the CLI persists and acknowledges the lifecycle
    // transition. Malibu requests the transaction but never owns pause state.
    func pause() async {
        guard let control else {
            snapshot.lastError = "Provider control is unavailable. Malibu will retry the local connection."
            return
        }
        snapshot.pauseAcknowledged = false
        do {
            try await control.send(.pauseRequest)
        } catch {
            snapshot.lastError = "Could not request provider pause: \(error.localizedDescription)"
        }
    }

    func resume() async {
        guard let control else {
            snapshot.lastError = "Provider control is unavailable. Malibu will retry the local connection."
            return
        }
        do {
            try await control.send(.resumeRequest)
        } catch {
            snapshot.lastError = "Could not request provider resume: \(error.localizedDescription)"
        }
    }

    func refreshReferralStatus() async {
        guard snapshot.hasTrustedReferralBoundary() else {
            snapshot.referralAvailability = .unsupported
            snapshot.referralStatus = nil
            snapshot.referralLastError = nil
            return
        }
        guard control != nil else {
            snapshot.referralAvailability = .unavailable
            snapshot.referralLastError = "The provider control connection is unavailable."
            return
        }
        snapshot.referralLastError = nil
        _ = await requestReferralStatusIfDue()
    }

    func startReferralChallenge() async {
        guard snapshot.hasTrustedReferralBoundary(),
              snapshot.localStatusCapabilities.contains("referral_advocacy_v1"),
              snapshot.referralStatus?.isCurrent() == true,
              snapshot.referralStatus?.canStartSocialChallenge == true,
              let control else { return }
        beginReferralAction()
        snapshot.referralLastError = nil
        do {
            try await control.send(.referralChallengeRequest)
        } catch {
            finishReferralAction()
            resumeReferralStatusExpiryOrRefresh()
            snapshot.referralLastError = "The X verification request could not reach the provider."
        }
    }

    func reopenReferralChallenge() async {
        guard snapshot.hasTrustedReferralBoundary(),
              snapshot.localStatusCapabilities.contains("referral_advocacy_v1"),
              let pending = snapshot.referralStatus?.pendingChallenge,
              pending.expiresAt > Date(),
              let control else { return }
        beginReferralAction()
        snapshot.referralLastError = nil
        do {
            try await control.send(.referralChallengeReopenRequest)
        } catch {
            finishReferralAction()
            resumeReferralStatusExpiryOrRefresh()
            snapshot.referralLastError = "The X composer could not be reopened by the provider."
        }
    }

    func verifyReferralPost(_ postURL: String) async {
        guard snapshot.hasTrustedReferralBoundary(),
              snapshot.localStatusCapabilities.contains("referral_advocacy_v1"),
              snapshot.referralStatus?.isCurrent() == true,
              snapshot.referralStatus?.pendingChallenge != nil,
              let control else { return }
        beginReferralAction()
        snapshot.referralLastError = nil
        do {
            try await control.send(.referralVerifyRequest(postURL: postURL))
        } catch {
            finishReferralAction()
            resumeReferralStatusExpiryOrRefresh()
            snapshot.referralLastError = "The X post could not be submitted to the provider."
        }
    }

    func cancelReferralChallenge() async {
        guard snapshot.hasTrustedReferralBoundary(),
              snapshot.localStatusCapabilities.contains("referral_advocacy_v1"),
              snapshot.referralStatus?.isCurrent() == true,
              let control else { return }
        beginReferralAction()
        snapshot.referralLastError = nil
        do {
            try await control.send(.referralChallengeCancelRequest)
        } catch {
            finishReferralAction()
            resumeReferralStatusExpiryOrRefresh()
            snapshot.referralLastError = "The pending X verification could not be cleared."
        }
    }

    /// Online #582 recovery without reinstalling provider identity.
    /// Pending trust resubmits stored evidence; corrective paths use the CLI
    /// `--recover-hardware-admission` drain/recommend/restore transaction.
    func retryHardwareVerification() async {
        guard !isShuttingDown else { return }
        guard AgentSnapshotPresenter.publicStatus(snapshot).executableAction == .retryHardwareVerification else {
            return
        }
        guard !snapshot.hardwareVerificationRetryInProgress else { return }
        if let previous = hardwareVerificationRetryTask {
            previous.cancel()
            await previous.value
        }
        guard !isShuttingDown, !Task.isCancelled else { return }
        let pendingTrust = snapshot.lifecycleReason == "autotune_evidence_required"
        snapshot.hardwareVerificationRetryInProgress = true
        snapshot.hardwareVerificationRetryLastError = nil
        hardwareVerificationRetryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !self.isShuttingDown {
                    self.snapshot.hardwareVerificationRetryInProgress = false
                }
            }
            var attemptedCorrectiveRecovery = !pendingTrust
            do {
                let cliURL = URL(fileURLWithPath: CLIUpdateRunner.installedCLIPath())
                if pendingTrust {
                    do {
                        try await AutotuneRecommendationRunner.runPendingEvidenceResubmit(cliURL: cliURL)
                    } catch let AutotuneRecommendationError.nonZeroExit(code, _) where code == 10 {
                        // Stored recommendation/evidence missing or stale —
                        // fall through to corrective drain/restore recovery.
                        attemptedCorrectiveRecovery = true
                        self.hardwareRecoveryOwnsLaunchdRestore = true
                        try await AutotuneRecommendationRunner.runHardwareAdmissionRecovery(cliURL: cliURL)
                    }
                } else {
                    self.hardwareRecoveryOwnsLaunchdRestore = true
                    try await AutotuneRecommendationRunner.runHardwareAdmissionRecovery(cliURL: cliURL)
                }
                guard !Task.isCancelled, !self.isShuttingDown else {
                    self.restoreLaunchdIfCorrectiveRecoveryOwned(attemptedCorrectiveRecovery)
                    return
                }
                self.hardwareRecoveryOwnsLaunchdRestore = false
                self.snapshot.hardwareVerificationRetryLastError = nil
                if let port = ProviderConfig.readHTTPPort() {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await self.applyProviderSnapshot(port: port)
                }
            } catch is CancellationError {
                self.restoreLaunchdIfCorrectiveRecoveryOwned(attemptedCorrectiveRecovery)
                return
            } catch {
                self.restoreLaunchdIfCorrectiveRecoveryOwned(attemptedCorrectiveRecovery)
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                self.snapshot.hardwareVerificationRetryLastError =
                    AgentSnapshotPresenter.publicErrorDetail(error.localizedDescription)
                    ?? "Provider setup could not be completed. Export diagnostics for support."
            }
        }
        await hardwareVerificationRetryTask?.value
    }

    private func restoreLaunchdIfCorrectiveRecoveryOwned(_ attemptedCorrectiveRecovery: Bool) {
        guard AutotuneRecommendationRunner.shouldBestEffortBootstrapLaunchd(
            attemptedCorrectiveRecovery: attemptedCorrectiveRecovery
        ) || hardwareRecoveryOwnsLaunchdRestore else {
            return
        }
        AutotuneRecommendationRunner.bestEffortBootstrapLaunchdProvider()
        hardwareRecoveryOwnsLaunchdRestore = false
    }

    func updateCLINow() async {
        guard !snapshot.cliUpdateInProgress else { return }
        guard AgentSnapshotPresenter.updateAvailable(snapshot) else { return }
        cliUpdateTask?.cancel()
        snapshot.cliUpdateInProgress = true
        let installedVersion = snapshot.cliVersion
        let compatibilitySetID = snapshot.compatibilitySetID
        cliUpdateTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await CLIUpdateRunner.run(
                    installedVersion: installedVersion,
                    compatibilitySetID: compatibilitySetID
                ) { line in
                    self.logLines.append(LogTailBuffer.redacted(line))
                    if self.logLines.count > 400 {
                        self.logLines.removeFirst(self.logLines.count - 400)
                    }
                }
                self.snapshot.cliUpdateLastError = nil
                if let port = ProviderConfig.readHTTPPort() {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await self.applyProviderSnapshot(port: port)
                }
            } catch {
                self.snapshot.cliUpdateLastError = error.localizedDescription
            }
            self.snapshot.cliUpdateInProgress = false
        }
        await cliUpdateTask?.value
    }

    func repairProviderCredential() async {
        guard !isShuttingDown,
              AgentSnapshotPresenter.canRepairCredential(snapshot),
              let expectedProviderID = snapshot.localProviderID,
              ProviderConfig.readProviderID() == expectedProviderID else { return }
        if let previous = credentialRepairTask {
            previous.cancel()
            await previous.value
        }
        guard !isShuttingDown, !Task.isCancelled else { return }
        snapshot.credentialRepairInProgress = true
        snapshot.credentialRepairLastError = nil
        credentialRepairTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await ProviderCredentialHandoffRunner.repairCredential(
                    configURL: ProviderPaths.current.configFile,
                    expectedProviderID: expectedProviderID,
                    previousServiceInstanceID: self.snapshot.serviceInstanceID
                )
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                self.applyCredentialSnapshot(result)
                if let port = ProviderConfig.readHTTPPort() {
                    await self.applyProviderSnapshot(port: port)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                self.snapshot.credentialRepairLastError = error.localizedDescription
                await self.refreshCredentialDiagnosis()
            }
            if !self.isShuttingDown {
                self.snapshot.credentialRepairInProgress = false
            }
        }
        await credentialRepairTask?.value
    }

    func repairAdmissionIdentity() async {
        guard !isShuttingDown,
              AgentSnapshotPresenter.canRepairAdmissionIdentity(snapshot) else { return }
        let expectedProviderID = snapshot.localProviderID
        if let configError = AgentSnapshotPresenter.admissionIdentityRecoveryConfigError(
            expectedProviderID: expectedProviderID,
            configuredProviderID: ProviderConfig.readProviderID()
        ) {
            snapshot.admissionIdentityRecoveryLastError = configError
            return
        }
        guard let expectedProviderID else { return }
        if let previous = admissionIdentityRecoveryTask {
            previous.cancel()
            await previous.value
        }
        guard !isShuttingDown, !Task.isCancelled else { return }
        let activate = ["approval_required", "committed_cleanup"]
            .contains(snapshot.admissionIdentityRecoveryJournalState)
            || snapshot.admissionIdentityState == "recovery_pending"
        snapshot.admissionIdentityRecoveryInProgress = true
        snapshot.admissionIdentityRecoveryLastError = nil
        admissionIdentityRecoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                if activate {
                    let result = try await ProviderCredentialHandoffRunner.activateAdmissionIdentityRecovery(
                        configURL: ProviderPaths.current.configFile,
                        expectedProviderID: expectedProviderID,
                        previousServiceInstanceID: self.snapshot.serviceInstanceID
                    )
                    guard !Task.isCancelled, !self.isShuttingDown else { return }
                    self.snapshot.applyAdmissionIdentityRecoveryJournal(result)
                    self.snapshot.admissionIdentityState = "ready"
                    self.snapshot.admissionIdentityPublicKeySHA256 = result.publicKeySHA256
                    self.snapshot.admissionIdentityPendingPublicKeySHA256 = nil
                    self.snapshot.admissionIdentityTransitionError = nil
                    self.snapshot.admissionIdentityRecoveryAction = "none"
                    if let port = ProviderConfig.readHTTPPort() {
                        await self.applyProviderSnapshot(port: port)
                    }
                } else {
                    let incidentID = "malibu-\(UUID().uuidString.lowercased())"
                    let result = try await ProviderCredentialHandoffRunner.stageAdmissionIdentityRecovery(
                        configURL: ProviderPaths.current.configFile,
                        expectedProviderID: expectedProviderID,
                        incidentID: incidentID,
                        reason: "Malibu network verification repair"
                    )
                    guard !Task.isCancelled, !self.isShuttingDown else { return }
                    self.snapshot.applyAdmissionIdentityRecoveryJournal(result)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                self.snapshot.admissionIdentityRecoveryLastError = error.localizedDescription
            }
            if !self.isShuttingDown {
                self.snapshot.admissionIdentityRecoveryInProgress = false
            }
        }
        await admissionIdentityRecoveryTask?.value
    }

    // Detach Malibu from the standalone launchd provider. Option 2 makes the
    // CLI the lifecycle owner, so quitting or updating the read-only app must
    // never drain, stop, or restart a healthy provider. Explicit uninstall is
    // performed separately by the CLI-owned teardown transaction.
    func shutdown(gracefulSeconds: Int) async {
        _ = gracefulSeconds
        isShuttingDown = true
        reconnectTask?.cancel(); reconnectTask = nil
        healthPollTask?.cancel(); healthPollTask = nil
        cliUpdateTask?.cancel(); cliUpdateTask = nil
        referralStatusExpiryTask?.cancel(); referralStatusExpiryTask = nil
        let hardwareRetryTask = hardwareVerificationRetryTask
        hardwareVerificationRetryTask = nil
        hardwareRetryTask?.cancel()
        await hardwareRetryTask?.value
        // Only restore when corrective recovery may have drained launchd.
        // Ordinary quit must not re-bootstrap an intentionally unloaded job.
        if hardwareRecoveryOwnsLaunchdRestore {
            AutotuneRecommendationRunner.bestEffortBootstrapLaunchdProvider()
            hardwareRecoveryOwnsLaunchdRestore = false
        }
        let admissionRecoveryTask = admissionIdentityRecoveryTask
        admissionIdentityRecoveryTask = nil
        admissionRecoveryTask?.cancel()
        await admissionRecoveryTask?.value
        let repairTask = credentialRepairTask
        credentialRepairTask = nil
        repairTask?.cancel()
        await repairTask?.value
        monitorsLaunchdProvider = false
        lastRequestsRateSample = nil
        await control?.close()
        metricsPoller?.cancel(); metricsPoller = nil
        eventStreamTask?.cancel(); eventStreamTask = nil
        stopProviderLogTail()
        logLines = []
        child = nil
        control = nil
        snapshot = .empty
        snapshot.thermalState = thermalMonitor.state
    }

    // MARK: - Private

    /// Attach to an existing launchd-managed provider (CLI install track).
    /// Returns true when local /v1/health is reachable on the configured port.
    @discardableResult
    func monitorInstalledProviderIfPresent(
        timeout: TimeInterval = MalibuOnboardingTimeouts.firstServingFrameSec
    ) async -> Bool {
        guard let port = ProviderConfig.readHTTPPort(),
              ProviderConfig.readProviderID() != nil else {
            return false
        }
        providerStartFailure = nil
        await releaseSpawnedChildForLaunchdMonitor()
        startProviderLogTail()
        let deadline = Date().addingTimeInterval(max(1, timeout))
        let pollInterval: TimeInterval = 2
        while Date() < deadline {
            if await InstalledProviderMonitor.isHealthy(port: port) {
                monitorsLaunchdProvider = true
                providerStartFailure = nil
                await applyProviderSnapshot(port: port)
                await refreshAdmissionIdentityRecoveryDiagnosis()
                await attachInstalledProviderControlIfAvailable()
                startHealthPolling(port: port)
                return snapshot.state == .serving
            }
            if let failure = diagnosedProviderFailure() {
                providerStartFailure = failure
                snapshot.state = .error
                snapshot.lastError = failure
                await refreshCredentialDiagnosis()
                return false
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let sleep = min(pollInterval, remaining)
            try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
        }
        let failure = diagnosedProviderFailure()
            ?? ProviderLogDiagnostics.timeoutMessage(logHint: ProviderLogDiagnostics.logHint())
        providerStartFailure = failure
        snapshot.state = .error
        snapshot.lastError = failure
        await refreshCredentialDiagnosis()
        return false
    }

    /// Stop a Malibu-spawned CLI child before attaching to launchd. Without
    /// this, onboarding can leave two macprovider-cli processes (different
    /// ports, same provider_id) running concurrently.
    private func releaseSpawnedChildForLaunchdMonitor() async {
        guard child != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        child?.markStopping()
        try? await control?.send(.shutdownRequest(graceSeconds: 5))
        await child?.stop(gracePeriod: 5)
        metricsPoller?.cancel()
        metricsPoller = nil
        eventStreamTask?.cancel()
        eventStreamTask = nil
        await control?.close()
        child = nil
        control = nil
    }

    private func applyProviderSnapshot(port: Int) async {
        let localReady = await applyHealthSnapshot(port: port)
        if let status = await InstalledProviderMonitor.fetchStatus(port: port),
           let expectedProviderID = ProviderConfig.readProviderID(),
           InstalledProviderMonitor.serviceIdentityMatches(
               status,
               expectedProviderID: expectedProviderID,
               launchdPID: InstalledProviderMonitor.launchdServicePID(),
               liveCodeMatches: ProviderCredentialHandoffRunner.validatedInstalledProcessMatches(pid:)
           ) {
            snapshot.localProviderID = expectedProviderID
            snapshot.localStatusContractVersion = status.contractVersion
            snapshot.localStatusMinimumReaderVersion = status.minimumReaderVersion
            snapshot.localStatusContractCompatible = status.contractCompatible
            snapshot.localStatusLifecycleOwner = status.lifecycleOwner
            snapshot.localStatusCapabilities = status.capabilities
            snapshot.statusObservationID = status.observationID
            snapshot.statusObservedAt = status.observedAt
            snapshot.statusObservationValidForMS = status.observationValidForMS
            snapshot.statusObservationFresh = status.observationFresh
            snapshot.serviceInstanceID = status.serviceInstanceID
            snapshot.servicePID = status.servicePID
            snapshot.serviceBootSession = status.serviceBootSession
            snapshot.serviceStartedAt = status.serviceStartedAt
            snapshot.serviceRole = status.serviceRole
            snapshot.lifecycleRecordState = status.transitionRecordState
            snapshot.lifecycleSequence = status.transitionSequence
            snapshot.lifecycleTransitionID = status.transitionID
            snapshot.lifecycleTransitionAt = status.transitionAt
            snapshot.lifecycleState = status.transitionState
            snapshot.lifecycleReason = status.transitionReason
            snapshot.lifecycleAuthority = status.transitionAuthority
            snapshot.lifecycleWriter = status.transitionWriter
            snapshot.lifecycleOperationID = status.transitionOperationID
            snapshot.lifecycleOperatorPaused = status.operatorPaused
            snapshot.lifecycleLastRestart = status.lastRestart
            snapshot.lifecycleLastRejection = status.lastRejection
            snapshot.lifecycleLastUpdate = status.lastUpdate
            snapshot.lifecycleLastWatchdog = status.lastWatchdog
            snapshot.lifecycleLeaseState = status.lifecycleLeaseState
            snapshot.lifecycleLeaseKind = status.lifecycleLeaseKind
            snapshot.lifecycleLeaseOperationID = status.lifecycleLeaseOperationID
            snapshot.lifecycleLeaseExpiresWallMS = status.lifecycleLeaseExpiresWallMS
            snapshot.credentialSource = status.credentialSource
            snapshot.credentialState = status.credentialState
            snapshot.credentialRestartSafe = status.credentialRestartSafe
            snapshot.credentialMigrationPending = status.credentialMigrationPending
            snapshot.credentialRecoveryAction = status.credentialRecoveryAction
            snapshot.credentialStatusObservedAt = status.observedAt
            snapshot.credentialStatusFromDiagnostic = false
            snapshot.admissionIdentitySource = status.admissionIdentitySource
            snapshot.admissionIdentityState = status.admissionIdentityState
            snapshot.admissionIdentityPublicKeySHA256 = status.admissionIdentityPublicKeySHA256
            snapshot.admissionIdentityPendingPublicKeySHA256 = status.admissionIdentityPendingPublicKeySHA256
            snapshot.admissionIdentityPreviousPublicKeySHA256 = status.admissionIdentityPreviousPublicKeySHA256
            snapshot.admissionIdentityPreviousValidUntil = status.admissionIdentityPreviousValidUntil
            snapshot.admissionIdentityCoordinatorGeneration = status.admissionIdentityCoordinatorGeneration
            snapshot.admissionIdentityCoordinatorPublicKeySHA256 = status.admissionIdentityCoordinatorPublicKeySHA256
            snapshot.admissionIdentityCoordinatorKeyRole = status.admissionIdentityCoordinatorKeyRole
            snapshot.admissionIdentityTransitionError = status.admissionIdentityTransitionError
            snapshot.admissionIdentityRecoveryAction = status.admissionIdentityRecoveryAction
            snapshot.coordinatorIdentityAdmissionMode = status.coordinatorIdentityAdmissionMode
            snapshot.coordinatorConnected = status.coordinatorConnected
            snapshot.networkState = status.networkState
            snapshot.advertisedMaxConcurrency = status.advertisedMaxConcurrency
            snapshot.catalogState = status.catalogState
            snapshot.catalogReleaseID = status.catalogReleaseID
            snapshot.catalogDigest = status.catalogDigest
            snapshot.catalogSignerKeyID = status.catalogSignerKeyID
            snapshot.catalogSource = status.catalogSource
            snapshot.compatibilitySetID = status.compatibilitySetID
            snapshot.compatibilitySetSHA256 = status.compatibilitySetSHA256
            if let version = status.binaryVersion {
                snapshot.cliVersion = ProviderCLIVersion.normalize(version)
            }
            if let recommended = status.recommendedVersion {
                snapshot.coordinatorRecommendedVersion = ProviderCLIVersion.normalize(recommended)
            }
            if snapshot.hasTrustedReferralBoundary() {
                if snapshot.referralAvailability == .unsupported {
                    snapshot.referralAvailability = .unavailable
                }
            } else {
                referralStatusExpiryTask?.cancel()
                referralStatusExpiryTask = nil
                snapshot.referralAvailability = .unsupported
                snapshot.referralStatus = nil
                snapshot.referralLastError = nil
                finishReferralAction()
            }
        } else {
            // Never carry a prior authoritative serving verdict across a
            // failed status/readiness refresh.
            snapshot.invalidateLocalStatusObservation()
        }
        reconcileNetworkState(localReady: localReady)
        await refreshLatestReleaseIfNeeded()
    }

    private func refreshCredentialDiagnosis() async {
        guard FileManager.default.fileExists(atPath: ProviderPaths.current.configFile.path),
              let expectedProviderID = ProviderConfig.readProviderID() else { return }
        do {
            let result = try await ProviderCredentialHandoffRunner.credentialStatus(
                configURL: ProviderPaths.current.configFile,
                expectedProviderID: expectedProviderID
            )
            applyCredentialSnapshot(result)
        } catch {
            snapshot.credentialRepairLastError = snapshot.credentialRepairLastError
                ?? error.localizedDescription
        }
        await refreshAdmissionIdentityRecoveryDiagnosis()
    }

    private func refreshAdmissionIdentityRecoveryDiagnosis() async {
        guard FileManager.default.fileExists(atPath: ProviderPaths.current.configFile.path),
              let expectedProviderID = ProviderConfig.readProviderID() else {
            if snapshot.admissionIdentityRecoveryJournalState != nil {
                snapshot.admissionIdentityRecoveryLastError =
                    "Network verification repair requires the current provider setup."
            }
            return
        }
        do {
            let result = try await ProviderCredentialHandoffRunner.admissionIdentityRecoveryStatus(
                configURL: ProviderPaths.current.configFile,
                expectedProviderID: expectedProviderID
            )
            snapshot.applyAdmissionIdentityRecoveryJournal(result)
        } catch {
            snapshot.admissionIdentityRecoveryLastError = error.localizedDescription
        }
    }

    private func applyCredentialSnapshot(_ credential: ProviderCredentialHandoffRunner.CredentialSnapshot) {
        snapshot.localProviderID = credential.providerID
        snapshot.credentialSource = credential.source
        snapshot.credentialState = credential.condition
        snapshot.credentialRestartSafe = credential.restartSafe
        snapshot.credentialMigrationPending = credential.migrationPending
        snapshot.credentialRecoveryAction = credential.action
        snapshot.credentialStatusObservedAt = Date()
        snapshot.credentialStatusFromDiagnostic = true
    }

    /// Local /v1/health readiness only — coordinator session is reconciled separately.
    @discardableResult
    private func applyHealthSnapshot(port: Int) async -> Bool {
        guard let health = await InstalledProviderMonitor.fetchHealth(port: port) else { return false }
        if let model = health.model, !model.isEmpty {
            snapshot.currentModelID = model
        }
        if let total = health.requestsTotal {
            snapshot.requestsServedAllTime = total
            updateRequestsPerMinute(from: total)
        }
        if let today = health.requestsToday {
            snapshot.requestsServedToday = today
        }
        if let inputToday = health.inputTokensToday {
            snapshot.inputTokensToday = inputToday
        }
        if let outputToday = health.outputTokensToday {
            snapshot.outputTokensToday = outputToday
        }
        if let inputAllTime = health.inputTokensAllTime {
            snapshot.inputTokensAllTime = inputAllTime
        }
        if let outputAllTime = health.outputTokensAllTime {
            snapshot.outputTokensAllTime = outputAllTime
        }
        if let uptime = health.uptimeSeconds {
            snapshot.uptimeSec = uptime
        }
        if let restarts = health.restartCount {
            snapshot.restartCount = restarts
        }
        return health.ready
    }

    /// Serving requires the CLI's coordinator-authoritative buyer-serving
    /// state. A WebSocket connection proves transport only, not admission.
    private func reconcileNetworkState(localReady: Bool) {
        if snapshot.lifecycleRecordState == "valid",
           (snapshot.lifecycleState == "paused_by_operator" || snapshot.lifecycleOperatorPaused == true) {
            snapshot.state = .paused
            snapshot.pauseAcknowledged = true
            snapshot.lastError = nil
            return
        }
        if snapshot.state == .paused {
            // The persisted CLI transition, not an old UI acknowledgement, is
            // authoritative. Once it advances, clear the local paused view.
            snapshot.state = localReady ? .reconnecting : .starting
            snapshot.pauseAcknowledged = false
        }
        let observationCurrent = snapshot.isLocalStatusObservationCurrent()
        let buyerServing = observationCurrent && snapshot.networkState == "buyer_serving"
        if localReady && buyerServing {
            snapshot.state = .serving
            snapshot.lastError = nil
            return
        }
        if localReady {
            snapshot.state = .reconnecting
            snapshot.lastError = coordinatorDisconnectMessage()
            return
        }
    }

    private func coordinatorDisconnectMessage() -> String {
        if snapshot.localStatusContractCompatible == false {
            return "Provider running · Malibu needs an update to read its status"
        }
        if !snapshot.isLocalStatusObservationCurrent() {
            return "Provider running · checking status again"
        }
        switch snapshot.networkState {
        case "safe_offline_fallback":
            return "Model loaded locally · provider software is using an offline fallback"
        case "catalog_update_required":
            return "Model loaded locally · provider software update required"
        case "catalog_integrity_failure":
            return "Model loaded locally · provider software check failed"
        case "local_donor":
            return "Model loaded locally · this mode does not receive customer work"
        case "not_buyer_serving":
            return "Model loaded locally · this Mac is not currently eligible for customer work"
        case "buyer_serving_unknown":
            return "Model loaded locally · checking customer availability"
        case "live_verified":
            return snapshot.coordinatorConnected == true
                ? "Model loaded locally · waiting for network approval"
                : "Model loaded locally · provider software verified; reconnecting to the network"
        default:
            break
        }
        switch snapshot.coordinatorConnected {
        case .some(false):
            return "Model loaded locally · not connected to the network"
        case .none:
            return "Model loaded locally · checking network connection…"
        case .some(true):
            return snapshot.networkState == nil
                ? "Model loaded locally · checking customer availability"
                : "Checking background provider…"
        }
    }

    private func refreshLatestReleaseIfNeeded() async {
        if let fetchedAt = latestReleaseFetchedAt,
           Date().timeIntervalSince(fetchedAt) < latestReleaseTTL,
           snapshot.latestReleaseVersion != nil {
            return
        }
        if let tag = await GitHubLatestReleaseClient.fetchTag() {
            latestReleaseFetchedAt = Date()
            snapshot.latestReleaseVersion = tag
        }
    }

    private func updateRequestsPerMinute(from total: Int) {
        let now = Date()
        if let last = lastRequestsRateSample {
            let elapsedMinutes = now.timeIntervalSince(last.date) / 60.0
            if elapsedMinutes > 0 {
                let delta = max(0, total - last.total)
                snapshot.requestsPerMinute = Double(delta) / elapsedMinutes
            }
        }
        lastRequestsRateSample = (total, now)
    }

    private func startHealthPolling(port: Int) {
        lastRequestsRateSample = nil
        healthPollTask?.cancel()
        healthPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: LocalStatusObservationPolicy.pollIntervalNanoseconds)
                guard let self else { return }
                if await InstalledProviderMonitor.isHealthy(port: port) {
                    await self.applyProviderSnapshot(port: port)
                    await self.attachInstalledProviderControlIfAvailable()
                    try? await self.control?.send(.metricsRequest)
                    try? await self.control?.send(.statusRequest)
                    await self.requestReferralStatusIfDue()
                } else if self.monitorsLaunchdProvider {
                    await MainActor.run {
                        self.snapshot.invalidateLocalStatusObservation()
                        if let failure = self.diagnosedProviderFailure() {
                            self.providerStartFailure = failure
                            self.snapshot.state = .error
                            self.snapshot.lastError = failure
                        } else {
                            self.snapshot.state = .reconnecting
                            self.snapshot.lastError = ProviderLogDiagnostics.timeoutMessage(
                                logHint: ProviderLogDiagnostics.logHint()
                            )
                        }
                    }
                }
            }
        }
    }

    private func connectControl(socketPath: String) async {
        metricsPoller?.cancel(); metricsPoller = nil
        eventStreamTask?.cancel(); eventStreamTask = nil
        if let control {
            await control.close()
            self.control = nil
        }

        let client = ControlSocketClient(socketPath: socketPath)
        do {
            try await client.connect(timeout: MalibuOnboardingTimeouts.controlSocketConnectSec)
        } catch {
            // AUDIT R6 CODE M-connect fix: previously we set .error and returned,
            // leaving `self.child` pointing at a running CLI. `start()`'s
            // `guard child == nil` then blocked every subsequent restart, and
            // the orphan kept holding the model in memory. Stop the child
            // cleanly and route through the same reconnect backoff as an
            // unexpected exit so the user (or model-load recovery) can retry.
            snapshot.state = .error
            snapshot.lastError = "Control socket: \(error)"
            child?.markStopping()
            await child?.stop(gracePeriod: 5)
            child = nil
            guard !isShuttingDown else { return }
            snapshot.state = .reconnecting
            await scheduleReconnect()
            return
        }
        guard !isShuttingDown else { await client.close(); return }
        self.control = client
        reconnect.reset()
        snapshot.state = .starting

        eventStreamTask = Task { [weak self] in
            for await frame in client.stream {
                self?.consume(frame)
            }
            await client.close()
            guard let self, self.control === client else { return }
            if self.monitorsLaunchdProvider { self.control = nil }
            self.markReferralControlDisconnected()
        }

        metricsPoller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: LocalStatusObservationPolicy.pollIntervalNanoseconds)
                try? await client.send(.metricsRequest)
                try? await client.send(.statusRequest)
                if let port = ProviderConfig.readHTTPPort() {
                    await self?.applyProviderSnapshot(port: port)
                }
                await self?.requestReferralStatusIfDue()
            }
        }

        try? await client.send(.statusRequest)
        try? await client.send(.metricsRequest)
        await requestReferralStatusIfDue()
    }

    /// Attach a strictly read-only Malibu client to the launchd-owned CLI.
    /// Failure is non-fatal because HTTP health/status remains the lifecycle
    /// source; the control socket adds the CLI-authenticated earnings view.
    private func attachInstalledProviderControlIfAvailable() async {
        guard monitorsLaunchdProvider, control == nil else { return }
        let client = ControlSocketClient(socketPath: ProviderPaths.current.controlSocket.path)
        do {
            try await client.connect(timeout: 2)
        } catch {
            await client.close()
            return
        }
        guard monitorsLaunchdProvider, !isShuttingDown else {
            await client.close()
            return
        }
        control = client
        eventStreamTask?.cancel()
        eventStreamTask = Task { [weak self] in
            for await frame in client.stream {
                self?.consume(frame)
            }
            await client.close()
            guard let self, self.control === client else { return }
            if self.monitorsLaunchdProvider { self.control = nil }
            self.markReferralControlDisconnected()
        }
        try? await client.send(.statusRequest)
        try? await client.send(.metricsRequest)
        await requestReferralStatusIfDue()
    }

    @discardableResult
    private func requestReferralStatusIfDue() async -> Bool {
        guard snapshot.hasTrustedReferralBoundary(), let control else { return false }
        let now = Date()
        guard ReferralRefreshPolicy.shouldRequest(
            now: now,
            lastRequestedAt: lastReferralRefreshRequestedAt
        ) else { return false }
        lastReferralRefreshRequestedAt = now
        beginReferralAction()
        do {
            try await control.send(.referralStatusRequest)
            return true
        } catch {
            markReferralControlDisconnected()
            return false
        }
    }

    func beginReferralAction() {
        referralStatusExpiryTask?.cancel()
        referralStatusExpiryTask = nil
        snapshot.referralActionInProgress = true
        referralActionWatchdog.arm { [weak self] in
            guard let self else { return }
            self.snapshot.referralActionInProgress = false
            self.referralStatusExpiryTask?.cancel()
            self.referralStatusExpiryTask = nil
            self.snapshot.referralStatus = nil
            self.snapshot.referralAvailability = self.snapshot.hasTrustedReferralBoundary()
                ? .unavailable
                : .unsupported
            self.snapshot.referralLastError =
                "The provider did not return a supported invite response in time."
        }
    }

    // MARK: - Payout address (Add wallet)

    /// Refresh registered payout address via CLI challenge GET (read-only).
    func refreshPayoutRegistration() async {
        guard !snapshot.payoutRegistrationInProgress else { return }
        // Seed from local display cache before network.
        if snapshot.payoutRegisteredAddress == nil,
           let stored = PayoutRegistrationStore.load() {
            snapshot.payoutRegisteredAddress = stored.address
            snapshot.payoutPendingUntilUTC = stored.pendingUntilUTC
        }
        do {
            let challenge = try await PayoutWalletFlow.fetchChallenge()
            snapshot.payoutRegisteredAddress = challenge.registeredAddress
            snapshot.payoutPendingUntilUTC = challenge.pendingUntilUTC
            snapshot.payoutLastError = nil
            if let addr = challenge.registeredAddress {
                PayoutRegistrationStore.save(
                    address: addr,
                    pendingUntilUTC: challenge.pendingUntilUTC
                )
            }
        } catch {
            // Soft-fail on dashboard load; keep any locally remembered address.
        }
    }

    /// Full non-custodial register flow: challenge → browser sign → register.
    /// Optional `pasted` skips the browser when the provider copy-pasted.
    func registerPayoutWallet(pasted: PayoutSignedPayload? = nil) async {
        guard !snapshot.payoutRegistrationInProgress else { return }
        snapshot.payoutRegistrationInProgress = true
        snapshot.payoutLastError = nil
        snapshot.payoutLastStatus = nil
        defer { snapshot.payoutRegistrationInProgress = false }

        do {
            let challenge = try await PayoutWalletFlow.fetchChallenge()
            if let existing = challenge.registeredAddress {
                snapshot.payoutRegisteredAddress = existing
                snapshot.payoutPendingUntilUTC = challenge.pendingUntilUTC
            }

            let nonce = try PayoutWalletFlow.randomNonceHex()
            let ts = PayoutWalletFlow.tsUtc(serverTsUTC: challenge.serverTsUTC)
            let state = try PayoutWalletFlow.randomState()

            let signed: PayoutSignedPayload
            if let pasted {
                // Paste path: provider supplies address+signature (+nonce/ts)
                // from the signer fallback UI. Shape-check only; coordinator
                // EIP-712 verify is the trust boundary.
                guard PayoutWalletFlow.validateCallback(
                    payload: pasted,
                    expectedState: pasted.state,
                    expectedNonce: pasted.nonce,
                    expectedTsUtc: pasted.tsUtc
                ) else {
                    throw PayoutWalletFlowError.invalidCallback
                }
                signed = pasted
            } else {
                signed = try await PayoutWalletFlow.captureSignature(
                    challenge: challenge,
                    nonce: nonce,
                    tsUtc: ts,
                    state: state
                )
            }

            let result = try await PayoutWalletFlow.register(
                address: signed.address,
                nonce: signed.nonce,
                tsUtc: signed.tsUtc,
                signature: signed.signature
            )
            snapshot.payoutRegisteredAddress = result.address
            snapshot.payoutPendingUntilUTC = result.pendingUntilUTC
            snapshot.payoutLastStatus = result.status
            snapshot.payoutLastError = nil
            snapshot.walletBound = true
            PayoutRegistrationStore.save(
                address: result.address,
                pendingUntilUTC: result.pendingUntilUTC
            )
        } catch let error as PayoutWalletFlowError {
            snapshot.payoutLastError = Self.payoutErrorMessage(error)
        } catch {
            snapshot.payoutLastError = "Wallet registration failed. Try again."
        }
    }

    private static func payoutErrorMessage(_ error: PayoutWalletFlowError) -> String {
        switch error {
        case .cliNotFound:
            return "Provider software is not installed."
        case let .challengeFailed(msg), let .registerFailed(msg), let .loopbackFailed(msg):
            return msg
        case .timedOut:
            return "Wallet signing timed out. Open Add wallet and try again."
        case .cancelled:
            return "Wallet registration was cancelled."
        case .invalidCallback:
            return "The signature from the browser was incomplete or mismatched."
        case .missingResources:
            return "The bundled wallet signer page is missing from this app build."
        case .missingProviderID:
            return "Provider identity is not configured on this Mac."
        case .rngFailure:
            return "Secure random generation failed. Please try again."
        }
    }

    private func finishReferralAction() {
        referralActionWatchdog.cancel()
        snapshot.referralActionInProgress = false
    }

    private func markReferralControlDisconnected() {
        finishReferralAction()
        referralStatusExpiryTask?.cancel()
        referralStatusExpiryTask = nil
        lastReferralRefreshRequestedAt = nil
        snapshot.referralAvailability = snapshot.hasTrustedReferralBoundary() ? .unavailable : .unsupported
        snapshot.referralStatus = nil
        if snapshot.hasTrustedReferralBoundary() {
            snapshot.referralLastError = "Invite status is unavailable while Malibu reconnects to the provider."
        }
    }

    func consume(_ frame: ControlFrame) {
        switch frame {
        case let .statusResponse(model, state):
            snapshot.currentModelID = model
            // CLI's `SwapState` (`RuntimeStateMachine.swift:public enum SwapState`)
            // has only `.loading` / `.ready` / `.draining`; there is no
            // `.serving`. `.ready` = model loaded + accepting requests, which
            // matches what SPEC-026 §6.1 j and coordinator heartbeats
            // (`state:"ready"`) call the "serving" transition. Accept
            // either spelling so the state contract survives a rename on
            // either side.
            if state == "ready" || state == "serving" {
                reconcileNetworkState(localReady: true)
            }
        case let .metricsResponse(
            usdc,
            malibu,
            providerEarnings,
            gpuTemperature,
            gpuUtilization,
            latencyP50,
            latencyP99,
            queueDepth,
            requestsToday,
            requestsAllTime,
            requestsPerMinute,
            inputTokensToday,
            outputTokensToday,
            inputTokensAllTime,
            outputTokensAllTime,
            uptime
        ):
            // Supported legacy CLI peers emitted an all-zero tuple before the
            // operational metrics contract existed. Rendering that tuple as
            // authoritative "$0.00" masks "not reported" as "you earned
            // nothing." Suppress only that legacy shape; current peers report
            // uptime and the CLI-owned provider earnings projection.
            let looksLikeStub = usdc == 0 && malibu == 0 && uptime == 0
                                 && gpuTemperature == nil && gpuUtilization == nil
                                 && latencyP50 == nil && latencyP99 == nil
                                 && queueDepth == nil && requestsToday == nil
                                 && requestsAllTime == nil && requestsPerMinute == nil
                                 && inputTokensToday == nil && outputTokensToday == nil
                                 && inputTokensAllTime == nil && outputTokensAllTime == nil
            if looksLikeStub {
                clearRuntimeMetrics()
            } else {
                snapshot.earningsUsdcToday = usdc
                snapshot.malibuAccruedToday = malibu
                snapshot.uptimeSec = uptime
                snapshot.gpuTemperatureC = gpuTemperature
                snapshot.gpuUtilizationPct = gpuUtilization
                snapshot.latencyP50Ms = latencyP50
                snapshot.latencyP99Ms = latencyP99
                snapshot.queueDepth = queueDepth
                snapshot.requestsServedToday = requestsToday
                snapshot.requestsServedAllTime = requestsAllTime
                snapshot.requestsPerMinute = requestsPerMinute
                snapshot.inputTokensToday = inputTokensToday
                snapshot.outputTokensToday = outputTokensToday
                snapshot.inputTokensAllTime = inputTokensAllTime
                snapshot.outputTokensAllTime = outputTokensAllTime
            }
            if let providerEarnings {
                snapshot.walletBound = providerEarnings.walletBound
                snapshot.trustTier = providerEarnings.trustTier
                snapshot.unpaidLedgerBacklogUSDC = providerEarnings.unpaidLedgerBacklogUSDC
                snapshot.unpaidLedgerBacklogMALIBU = providerEarnings.unpaidLedgerBacklogMALIBU
                snapshot.earningsUsdcToday = providerEarnings.usdcToday
                snapshot.earningsUsdcWeek = providerEarnings.usdcWeek
                snapshot.earningsUsdcPending = providerEarnings.usdcPending
                snapshot.earningsUsdcLifetime = providerEarnings.usdcLifetime
                snapshot.malibuAccruedToday = providerEarnings.malibuToday
                snapshot.malibuAccruedAllTime = providerEarnings.malibuAllTime
                snapshot.trustCriteriaMet = providerEarnings.trustCriteriaMet
                snapshot.trustCriteriaRequired = providerEarnings.trustCriteriaRequired
            }
        case let .pauseAck(accepted, reason):
            if accepted {
                snapshot.state = .paused
                snapshot.pauseAcknowledged = true
            } else {
                snapshot.lastError = reason ?? "Pause was refused"
            }
        case let .resumeAck(accepted, reason):
            if accepted {
                snapshot.state = .reconnecting
                reconcileNetworkState(localReady: true)
                snapshot.pauseAcknowledged = false
            } else {
                snapshot.lastError = reason ?? "Resume was refused"
            }
        case let .referralStatusResponse(status):
            finishReferralAction()
            guard snapshot.hasTrustedReferralBoundary() else {
                referralStatusExpiryTask?.cancel()
                referralStatusExpiryTask = nil
                snapshot.referralAvailability = .unsupported
                snapshot.referralStatus = nil
                return
            }
            snapshot.referralAvailability = .available
            snapshot.referralStatus = status
            scheduleReferralStatusExpiry(for: status)
            snapshot.referralLastError = nil
        case let .referralChallengeResponse(expiresAt):
            finishReferralAction()
            defer { resumeReferralStatusExpiryOrRefresh() }
            guard snapshot.hasTrustedReferralBoundary(),
                  let expiry = ReferralWireDate.parse(expiresAt),
                  let current = snapshot.referralStatus,
                  let next = current.withPendingChallenge(
                      ReferralPendingChallengeProjection(expiresAt: expiry)
                  ),
                  expiry > Date() else {
                snapshot.referralLastError = "The provider returned an invalid X verification expiry."
                return
            }
            snapshot.referralStatus = next
            snapshot.referralAvailability = .available
            snapshot.referralLastError = nil
        case let .referralChallengeReopenAck(expiresAt):
            finishReferralAction()
            defer { resumeReferralStatusExpiryOrRefresh() }
            guard ReferralWireDate.parse(expiresAt).map({ $0 > Date() }) == true else {
                snapshot.referralLastError = "The provider could not reopen an active X verification."
                return
            }
            snapshot.referralLastError = nil
        case let .referralChallengeCancelAck(status):
            finishReferralAction()
            if let status {
                snapshot.referralStatus = status
                snapshot.referralAvailability = .available
                scheduleReferralStatusExpiry(for: status)
            } else {
                snapshot.referralStatus = snapshot.referralStatus?.withPendingChallenge(nil)
                resumeReferralStatusExpiryOrRefresh()
            }
            snapshot.referralLastError = nil
        case let .referralError(operation, code, retryAfterSeconds):
            finishReferralAction()
            let staleStatusRequestFailed = operation == .status
                && snapshot.referralStatus?.isCurrent() == false
            if code == .featureUnavailable, operation == .status {
                referralStatusExpiryTask?.cancel()
                referralStatusExpiryTask = nil
                snapshot.referralAvailability = .disabled
                snapshot.referralStatus = nil
            } else if code == .featureUnavailable {
                snapshot.referralStatus = snapshot.referralStatus?.withSocialBonusEnabled(false)
            } else if [.temporarilyUnavailable, .invalidResponse, .authenticationRequired].contains(code) {
                referralStatusExpiryTask?.cancel()
                referralStatusExpiryTask = nil
                snapshot.referralAvailability = .unavailable
                snapshot.referralStatus = nil
            }
            if [.challengeInvalid, .postNotVerified].contains(code) {
                snapshot.referralStatus = snapshot.referralStatus?.withPendingChallenge(nil)
            }
            if staleStatusRequestFailed, code != .featureUnavailable {
                referralStatusExpiryTask?.cancel()
                referralStatusExpiryTask = nil
                snapshot.referralStatus = nil
                snapshot.referralAvailability = snapshot.hasTrustedReferralBoundary()
                    ? .unavailable
                    : .unsupported
            } else {
                resumeReferralStatusExpiryOrRefresh()
            }
            snapshot.referralLastError = referralErrorMessage(
                operation,
                code,
                retryAfterSeconds: retryAfterSeconds
            )
        default:
            break
        }
    }

    private func scheduleReferralStatusExpiry(for status: ReferralStatusProjection) {
        referralStatusExpiryTask?.cancel()
        let observedAt = status.observedAt
        let delay = max(
            0,
            observedAt.addingTimeInterval(ReferralRefreshPolicy.statusLifetime)
                .timeIntervalSinceNow
        )
        referralStatusExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  self.snapshot.referralStatus?.observedAt == observedAt,
                  self.snapshot.referralStatus?.isCurrent() != true else { return }
            self.snapshot.referralStatus = nil
            self.snapshot.referralAvailability = self.snapshot.hasTrustedReferralBoundary()
                ? .unavailable
                : .unsupported
            self.snapshot.referralLastError = "Invite status expired while Malibu waited for the provider."
            self.referralStatusExpiryTask = nil
        }
    }

    private func resumeReferralStatusExpiryOrRefresh() {
        guard let status = snapshot.referralStatus else { return }
        if status.isCurrent() {
            scheduleReferralStatusExpiry(for: status)
            return
        }
        referralStatusExpiryTask?.cancel()
        referralStatusExpiryTask = nil
        lastReferralRefreshRequestedAt = nil
        Task { [weak self] in
            _ = await self?.requestReferralStatusIfDue()
        }
    }

    private func referralErrorMessage(
        _ operation: ReferralControlOperation,
        _ code: ReferralControlErrorCode,
        retryAfterSeconds: Int?
    ) -> String {
        switch code {
        case .authenticationRequired:
            return "Saved provider access needs repair before invite status can be read."
        case .featureUnavailable:
            return operation == .status
                ? "Invite actions are not enabled yet."
                : "X rewards are not enabled. Existing invite capacity remains available."
        case .rateLimited:
            if let retryAfterSeconds { return "Too many referral requests. Retry in \(retryAfterSeconds) seconds." }
            return "Too many referral requests. Wait before retrying."
        case .temporarilyUnavailable:
            return "Referral status is temporarily unavailable."
        case .invalidResponse:
            return "The provider rejected an invalid invite response."
        case .invalidPostURL:
            return "Enter a public x.com post URL."
        case .firstServingRequired:
            return "Complete one network-verified customer job before sharing."
        case .challengeUnavailable:
            return "A new X verification link is not available yet."
        case .challengeInvalid:
            return "The X verification link expired or was already used. Start over."
        case .postNotVerified:
            return "The post is unavailable or does not contain the exact invite link."
        case .referralLocked:
            return "The network has not unlocked this provider's invite yet."
        }
    }

    private func clearRuntimeMetrics() {
        snapshot.earningsUsdcToday = nil
        snapshot.malibuAccruedToday = nil
        snapshot.uptimeSec = nil
        snapshot.gpuTemperatureC = nil
        snapshot.gpuUtilizationPct = nil
        snapshot.latencyP50Ms = nil
        snapshot.latencyP99Ms = nil
        snapshot.queueDepth = nil
        snapshot.requestsServedToday = nil
        snapshot.requestsServedAllTime = nil
        snapshot.requestsPerMinute = nil
        snapshot.inputTokensToday = nil
        snapshot.outputTokensToday = nil
        snapshot.inputTokensAllTime = nil
        snapshot.outputTokensAllTime = nil
    }

    private func startProviderLogTail(paths: ProviderPaths = .current) {
        providerLogTailCancellable?.cancel()
        providerLogTail?.stop()
        let tail = ProviderLogTail()
        providerLogTailCancellable = tail.$lines
            .sink { [weak self] lines in
                self?.logLines = lines
            }
        providerLogTail = tail
        tail.start(paths: paths)
    }

    private func stopProviderLogTail() {
        providerLogTailCancellable?.cancel()
        providerLogTailCancellable = nil
        providerLogTail?.stop()
        providerLogTail = nil
    }

    private func diagnosedProviderFailure() -> String? {
        ProviderLogDiagnostics.diagnose(lines: logLines)?.userMessage
    }

    private func scheduleReconnect() async {
        reconnectTask?.cancel()
        let delay = reconnect.nextDelay()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.start()
        }
    }

    static func resolveCLIExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL
    ) throws -> URL {
        if let override = environment["MALIBU_CLI_PATH"], !override.isEmpty {
            #if DEBUG
            return URL(fileURLWithPath: override)
            #endif
        }
        let bundled = bundleURL
            .appendingPathComponent("Contents/MacOS/macprovider-cli")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        throw POSIXError(.ENOENT)
    }
}

struct ReconnectPolicy {
    private var attempt = 0
    private let backoff: [TimeInterval] = [1, 2, 5, 15, 60]

    mutating func nextDelay() -> TimeInterval {
        defer { attempt += 1 }
        return backoff[min(attempt, backoff.count - 1)]
    }

    mutating func reset() { attempt = 0 }
}
