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
//         Metrics stubs (usdc==0 && malibu==0 && uptime==0 && no gpu/latency)
//         are dropped as "not implemented" — the presenter shows "—".

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
    private let earningsClient = EarningsClient()
    private let malibuAccrualClient = MalibuAccrualClient()
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

    // AUDIT R1 ARCHITECT A1: don't flip state until the CLI acks. If the CLI
    // returns accepted:false (current stub does), leave state where it was
    // and surface the reason in snapshot.lastError.
    func pause() async {
        if monitorsLaunchdProvider {
            snapshot.lastError = "Pause is not available while Malibu monitors the background provider."
            return
        }
        snapshot.pauseAcknowledged = false
        try? await control?.send(.pauseRequest)
    }

    func resume() async {
        if monitorsLaunchdProvider {
            snapshot.lastError = "Resume is not available while Malibu monitors the background provider."
            return
        }
        try? await control?.send(.resumeRequest)
    }

    func updateCLINow() async {
        guard !snapshot.cliUpdateInProgress else { return }
        guard AgentSnapshotPresenter.updateAvailable(snapshot) else { return }
        cliUpdateTask?.cancel()
        snapshot.cliUpdateInProgress = true
        cliUpdateTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await CLIUpdateRunner.run { line in
                    self.logLines.append(line)
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

    // AUDIT R2 CODE H2/H3: shutdown is the single termination path. Called from
    // both Quit-and-Uninstall and applicationShouldTerminate for plain Quit.
    // Cancels reconnect BEFORE marking child as stopping so nothing sneaks a
    // start() past the isShuttingDown gate.
    func shutdown(gracefulSeconds: Int) async {
        isShuttingDown = true
        reconnectTask?.cancel(); reconnectTask = nil
        healthPollTask?.cancel(); healthPollTask = nil
        cliUpdateTask?.cancel(); cliUpdateTask = nil
        monitorsLaunchdProvider = false
        lastRequestsRateSample = nil
        child?.markStopping()

        try? await control?.send(.shutdownRequest(graceSeconds: gracefulSeconds))
        await child?.stop(gracePeriod: TimeInterval(gracefulSeconds))
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
                startHealthPolling(port: port)
                await refreshEarnings()
                return snapshot.state == .serving
            }
            if let failure = diagnosedProviderFailure() {
                providerStartFailure = failure
                snapshot.state = .error
                snapshot.lastError = failure
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
        if let status = await InstalledProviderMonitor.fetchStatus(port: port) {
            snapshot.coordinatorConnected = status.coordinatorConnected
            snapshot.networkState = status.networkState
            snapshot.catalogState = status.catalogState
            snapshot.catalogReleaseID = status.catalogReleaseID
            snapshot.catalogDigest = status.catalogDigest
            snapshot.catalogSignerKeyID = status.catalogSignerKeyID
            snapshot.catalogSource = status.catalogSource
            if let version = status.binaryVersion {
                snapshot.cliVersion = ProviderCLIVersion.normalize(version)
            }
            if let recommended = status.recommendedVersion {
                snapshot.coordinatorRecommendedVersion = ProviderCLIVersion.normalize(recommended)
            }
        }
        reconcileNetworkState(localReady: localReady)
        await refreshLatestReleaseIfNeeded()
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

    /// Serving requires the CLI's explicit buyer-serving state. Older installed
    /// CLIs remain readable through the coordinator-connected compatibility path.
    private func reconcileNetworkState(localReady: Bool) {
        guard snapshot.state != .paused else { return }
        let buyerServing = snapshot.networkState == "buyer_serving"
            || (snapshot.networkState == nil && snapshot.coordinatorConnected == true)
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
        switch snapshot.networkState {
        case "safe_offline_fallback":
            return "Model loaded locally · signed catalog is offline fallback; not serving buyers"
        case "catalog_update_required":
            return "Model loaded locally · provider update required for the current catalog"
        case "catalog_integrity_failure":
            return "Model loaded locally · catalog integrity check failed; not serving buyers"
        case "local_donor":
            return "Model loaded locally · local donor mode does not serve buyer traffic"
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
            return "Checking background provider…"
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
                    await self.refreshEarnings()
                } else if self.monitorsLaunchdProvider {
                    await MainActor.run {
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
        }

        metricsPoller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                try? await client.send(.metricsRequest)
                try? await client.send(.statusRequest)
                if let port = ProviderConfig.readHTTPPort() {
                    await self?.applyProviderSnapshot(port: port)
                }
                await self?.refreshEarnings()
            }
        }

        try? await client.send(.statusRequest)
        try? await client.send(.metricsRequest)
        await refreshEarnings()
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
            // AUDIT R2 ARCHITECT A1 fix: the CLI stub emits earnings_usdc=0,
            // malibu_accrued=0, uptime_sec=0 with no gpu/latency until real
            // metrics land in SPEC-025 §11 P1. Rendering this tuple as
            // authoritative "$0.00" masked "unimplemented" as "you earned
            // nothing." Suppress the stub-shaped tuple to `nil` so the
            // presenter shows "—" instead. Real metric responses populate
            // at least uptime > 0 within seconds of the daemon coming up.
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
        case let .pauseAck(accepted, reason):
            if accepted {
                snapshot.state = .paused
                snapshot.pauseAcknowledged = true
            } else {
                snapshot.lastError = reason ?? "Pause was refused"
            }
        case let .resumeAck(accepted, reason):
            if accepted {
                reconcileNetworkState(localReady: true)
                snapshot.pauseAcknowledged = false
            } else {
                snapshot.lastError = reason ?? "Resume was refused"
            }
        case let .identitySignatureRequest(authAttemptID, providerID, binaryVersion, ecdhKey, transcriptSHA256):
            Task { [weak self] in
                await self?.handleIdentitySignatureRequest(
                    authAttemptID: authAttemptID,
                    providerID: providerID,
                    binaryVersion: binaryVersion,
                    providerECDHPublicKey: ecdhKey,
                    transcriptSHA256: transcriptSHA256
                )
            }
        default:
            break
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

    private func refreshEarnings() async {
        guard let providerID = ProviderConfig.readProviderID(),
              let token = await KeychainStore.readProviderToken(providerID: providerID) else {
            return
        }
        if let earnings = try? await earningsClient.fetch(providerID: providerID, bearerToken: token) {
            snapshot.walletBound = earnings.walletBound
            snapshot.trustTier = earnings.trustTier
            snapshot.unpaidLedgerBacklogUSDC = earnings.unpaidLedgerBacklogUSDC
            snapshot.unpaidLedgerBacklogMALIBU = earnings.unpaidLedgerBacklogMALIBU
            snapshot.earningsUsdcToday = earnings.usdcToday
            snapshot.earningsUsdcWeek = earnings.usdcWeek
            snapshot.earningsUsdcPending = earnings.usdcPending
            snapshot.earningsUsdcLifetime = earnings.usdcLifetime
            snapshot.malibuAccruedToday = earnings.malibuToday
            snapshot.malibuAccruedAllTime = earnings.malibuAllTime
            snapshot.trustCriteriaMet = earnings.trustCriteriaMet
            snapshot.trustCriteriaRequired = earnings.trustCriteriaRequired
        }
        if let accrual = try? await malibuAccrualClient.fetch(bearerToken: token) {
            snapshot.malibuAccruedAllTime = accrual.accruedMALIBU
            snapshot.trustTier = accrual.trustTier
            snapshot.trustCriteriaMet = accrual.trustCriteriaMet
            snapshot.trustCriteriaRequired = accrual.trustCriteriaRequired
            if let walletBound = accrual.walletBound {
                snapshot.walletBound = walletBound
            }
        }
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

    private func handleIdentitySignatureRequest(
        authAttemptID: String,
        providerID: String,
        binaryVersion: String,
        providerECDHPublicKey: String,
        transcriptSHA256: String
    ) async {
        guard ProviderConfig.readProviderID() == providerID else {
            try? await control?.send(.identitySignatureResponse(
                accepted: false,
                identitySignature: nil,
                transcriptSHA256: nil,
                reason: "provider_id_mismatch"
            ))
            return
        }

        do {
            let key = try await ProviderIdentity.loadExisting()
            guard ProviderIdentity.providerID(for: key) == providerID else {
                try? await control?.send(.identitySignatureResponse(
                    accepted: false,
                    identitySignature: nil,
                    transcriptSHA256: nil,
                    reason: "provider_identity_mismatch"
                ))
                return
            }
            let payload = try RegisterClient.identitySignaturePayload(
                authAttemptID: authAttemptID,
                providerID: providerID,
                binaryVersion: binaryVersion,
                providerECDHPublicKey: providerECDHPublicKey,
                transcriptSHA256: transcriptSHA256
            )
            let signature = try ProviderIdentity.sign(payload, using: key).base64EncodedString()
            try await control?.send(.identitySignatureResponse(
                accepted: true,
                identitySignature: signature,
                transcriptSHA256: transcriptSHA256,
                reason: nil
            ))
        } catch {
            try? await control?.send(.identitySignatureResponse(
                accepted: false,
                identitySignature: nil,
                transcriptSHA256: nil,
                reason: "identity_signature_failed"
            ))
        }
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
