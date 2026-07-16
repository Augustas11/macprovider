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
    private var credentialRepairTask: Task<Void, Never>?
    private var admissionIdentityRecoveryTask: Task<Void, Never>?
    private var referralStatusExpiryTask: Task<Void, Never>?
    private var lastReferralRefreshRequestedAt: Date?
    private let latestReleaseTTL: TimeInterval = 3600

    init() {
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
        snapshot.referralActionInProgress = true
        if !(await requestReferralStatusIfDue()) {
            snapshot.referralActionInProgress = false
        }
    }

    func startReferralChallenge() async {
        guard snapshot.hasTrustedReferralBoundary(),
              snapshot.localStatusCapabilities.contains("referral_advocacy_v1"),
              snapshot.referralStatus?.isCurrent() == true,
              snapshot.referralStatus?.canStartSocialChallenge == true,
              let control else { return }
        snapshot.referralActionInProgress = true
        snapshot.referralLastError = nil
        do {
            try await control.send(.referralChallengeRequest)
        } catch {
            snapshot.referralActionInProgress = false
            snapshot.referralLastError = "The X verification request could not reach the provider CLI."
        }
    }

    func reopenReferralChallenge() async {
        guard snapshot.hasTrustedReferralBoundary(),
              snapshot.localStatusCapabilities.contains("referral_advocacy_v1"),
              let pending = snapshot.referralStatus?.pendingChallenge,
              pending.expiresAt > Date(),
              let control else { return }
        snapshot.referralActionInProgress = true
        snapshot.referralLastError = nil
        do {
            try await control.send(.referralChallengeReopenRequest)
        } catch {
            snapshot.referralActionInProgress = false
            snapshot.referralLastError = "The X composer could not be reopened by the provider CLI."
        }
    }

    func verifyReferralPost(_ postURL: String) async {
        guard snapshot.hasTrustedReferralBoundary(),
              snapshot.localStatusCapabilities.contains("referral_advocacy_v1"),
              snapshot.referralStatus?.isCurrent() == true,
              snapshot.referralStatus?.pendingChallenge != nil,
              let control else { return }
        snapshot.referralActionInProgress = true
        snapshot.referralLastError = nil
        do {
            try await control.send(.referralVerifyRequest(postURL: postURL))
        } catch {
            snapshot.referralActionInProgress = false
            snapshot.referralLastError = "The X post could not be submitted to the provider CLI."
        }
    }

    func cancelReferralChallenge() async {
        guard snapshot.hasTrustedReferralBoundary(),
              snapshot.localStatusCapabilities.contains("referral_advocacy_v1"),
              snapshot.referralStatus?.isCurrent() == true,
              let control else { return }
        snapshot.referralActionInProgress = true
        snapshot.referralLastError = nil
        do {
            try await control.send(.referralChallengeCancelRequest)
        } catch {
            snapshot.referralActionInProgress = false
            snapshot.referralLastError = "The pending X verification could not be cleared."
        }
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
                        reason: "Malibu admission identity recovery"
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
                snapshot.referralActionInProgress = false
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
                    "Admission identity recovery requires the canonical provider config."
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
        let buyerServing = snapshot.isLocalStatusObservationCurrent()
            && snapshot.networkState == "buyer_serving"
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
            return "Provider running · status contract requires a newer Malibu version"
        }
        if !snapshot.isLocalStatusObservationCurrent() {
            return "Provider running · local status observation expired; retrying"
        }
        switch snapshot.networkState {
        case "safe_offline_fallback":
            return "Model loaded locally · signed catalog is offline fallback; not serving buyers"
        case "catalog_update_required":
            return "Model loaded locally · provider update required for the current catalog"
        case "catalog_integrity_failure":
            return "Model loaded locally · catalog integrity check failed; not serving buyers"
        case "local_donor":
            return "Model loaded locally · local donor mode does not serve buyer traffic"
        case "not_buyer_serving":
            return "Model loaded locally · coordinator has not admitted this provider for buyer traffic"
        case "buyer_serving_unknown":
            return "Model loaded locally · coordinator buyer-serving status is temporarily unknown"
        case "live_verified":
            return snapshot.coordinatorConnected == true
                ? "Model loaded locally · waiting for buyer-serving admission"
                : "Model loaded locally · catalog verified; reconnecting to coordinator"
        default:
            break
        }
        switch snapshot.coordinatorConnected {
        case .some(false):
            return "Model loaded locally · not connected to coordinator"
        case .none:
            return "Model loaded locally · checking coordinator connection…"
        case .some(true):
            return snapshot.networkState == nil
                ? "Model loaded locally · coordinator connected; buyer-serving status unknown"
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
                try? await Task.sleep(nanoseconds: 15_000_000_000)
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
            guard let self, self.control === client else { return }
            if self.monitorsLaunchdProvider { self.control = nil }
            self.markReferralControlDisconnected()
        }

        metricsPoller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
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
        do {
            try await control.send(.referralStatusRequest)
            return true
        } catch {
            markReferralControlDisconnected()
            return false
        }
    }

    private func markReferralControlDisconnected() {
        referralStatusExpiryTask?.cancel()
        referralStatusExpiryTask = nil
        lastReferralRefreshRequestedAt = nil
        snapshot.referralAvailability = snapshot.hasTrustedReferralBoundary() ? .unavailable : .unsupported
        snapshot.referralStatus = nil
        snapshot.referralActionInProgress = false
        if snapshot.hasTrustedReferralBoundary() {
            snapshot.referralLastError = "Referral status is unavailable while Malibu reconnects to the provider CLI."
        }
    }

    private func consume(_ frame: ControlFrame) {
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
            guard snapshot.hasTrustedReferralBoundary() else {
                referralStatusExpiryTask?.cancel()
                referralStatusExpiryTask = nil
                snapshot.referralAvailability = .unsupported
                snapshot.referralStatus = nil
                snapshot.referralActionInProgress = false
                return
            }
            snapshot.referralAvailability = .available
            snapshot.referralStatus = status
            scheduleReferralStatusExpiry(for: status)
            snapshot.referralLastError = nil
            snapshot.referralActionInProgress = false
        case let .referralChallengeResponse(expiresAt):
            snapshot.referralActionInProgress = false
            guard snapshot.hasTrustedReferralBoundary(),
                  let expiry = ReferralWireDate.parse(expiresAt),
                  let current = snapshot.referralStatus,
                  let next = current.withPendingChallenge(
                      ReferralPendingChallengeProjection(expiresAt: expiry)
                  ),
                  expiry > Date() else {
                snapshot.referralLastError = "The provider CLI returned an invalid X verification expiry."
                return
            }
            snapshot.referralStatus = next
            snapshot.referralAvailability = .available
            snapshot.referralLastError = nil
        case let .referralChallengeReopenAck(expiresAt):
            snapshot.referralActionInProgress = false
            guard ReferralWireDate.parse(expiresAt).map({ $0 > Date() }) == true else {
                snapshot.referralLastError = "The provider CLI could not reopen an active X verification."
                return
            }
            snapshot.referralLastError = nil
        case let .referralChallengeCancelAck(status):
            snapshot.referralActionInProgress = false
            if let status {
                snapshot.referralStatus = status
                snapshot.referralAvailability = .available
                scheduleReferralStatusExpiry(for: status)
            } else {
                snapshot.referralStatus = snapshot.referralStatus?.withPendingChallenge(nil)
            }
            snapshot.referralLastError = nil
        case let .referralError(operation, code, retryAfterSeconds):
            snapshot.referralActionInProgress = false
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
            self.snapshot.referralActionInProgress = false
            self.snapshot.referralLastError = "Referral status expired while Malibu waited for the provider CLI."
            self.referralStatusExpiryTask = nil
        }
    }

    private func referralErrorMessage(
        _ operation: ReferralControlOperation,
        _ code: ReferralControlErrorCode,
        retryAfterSeconds: Int?
    ) -> String {
        switch code {
        case .authenticationRequired:
            return "The CLI-owned provider credential needs repair before referral status can be read."
        case .featureUnavailable:
            return operation == .status
                ? "Referral actions are not enabled by the coordinator."
                : "X rewards are not enabled. Existing invite capacity remains available."
        case .rateLimited:
            if let retryAfterSeconds { return "Too many referral requests. Retry in \(retryAfterSeconds) seconds." }
            return "Too many referral requests. Wait before retrying."
        case .temporarilyUnavailable:
            return "Referral status is temporarily unavailable."
        case .invalidResponse:
            return "The provider CLI rejected an invalid referral response."
        case .invalidPostURL:
            return "Enter a public x.com post URL."
        case .firstServingRequired:
            return "Complete one coordinator-verified serving receipt before sharing."
        case .challengeUnavailable:
            return "A new X verification link is not available yet."
        case .challengeInvalid:
            return "The X verification link expired or was already used. Start over."
        case .postNotVerified:
            return "The post is unavailable or does not contain the exact invite link."
        case .referralLocked:
            return "The coordinator has not unlocked this provider's invite yet."
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
