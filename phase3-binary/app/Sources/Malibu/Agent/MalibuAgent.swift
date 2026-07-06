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

    private var child: CLIChildProcess?
    private var control: ControlSocketClient?
    private var metricsPoller: Task<Void, Never>?
    private var eventStreamTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var logTailReader: LogTailReader?
    private var reconnect = ReconnectPolicy()
    private let earningsClient = EarningsClient()
    private let thermalMonitor = ThermalMonitor()
    private var cancellables: Set<AnyCancellable> = []
    private var logTailCancellable: AnyCancellable?
    // AUDIT R2 CODE H3 fix: once shutdown begins, refuse any subsequent start()
    // — including a reconnect Task that already slept past its cancellation
    // check but hadn't yet re-entered the MainActor.
    private var isShuttingDown: Bool = false
    private var healthPollTask: Task<Void, Never>?
    private var monitorsLaunchdProvider = false

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
        // AUDIT R2 CODE H3 fix.
        guard !isShuttingDown else { return }
        guard child == nil else { return }

        // Option A: when install.sh owns the provider via launchd, monitor it
        // instead of spawning a second macprovider-cli child.
        if await monitorInstalledProviderIfPresent() {
            return
        }

        // AUDIT R2 CODE H4 fix: refuse to spawn the CLI without a validated
        // app-owned config + keychain token. Onboarding must complete the
        // deep-link callback first.
        guard await ProviderConfig.isConfigured else {
            snapshot.state = .error
            snapshot.lastError = "Not set up yet. Click Launch Provider to activate."
            return
        }
        // Re-check after the await, since we suspended.
        guard !isShuttingDown else { return }

        snapshot.state = .starting

        let paths = ProviderPaths.current
        let cliURL: URL
        do { cliURL = try Self.resolveCLIExecutable() } catch {
            snapshot.state = .error; snapshot.lastError = "CLI binary not found"; return
        }

        var extraEnv: [String: String] = [:]
        if let providerID = ProviderConfig.readProviderID(),
           let token = await KeychainStore.readProviderToken(providerID: providerID) {
            extraEnv["MACPROVIDER_PROVIDER_TOKEN"] = token
        }
        guard !isShuttingDown else { return }

        // FreePortProbe: ask the kernel for a free 127.0.0.1 TCP port so the
        // CLI's local HTTP inference endpoint doesn't collide with whatever
        // else may be on port 8080 (Node dev server, Rails, jaeger). Falling
        // back to nil lets the CLI use its default 8080; the CLI's own bind
        // error surfaces the failure with the same context as before, so
        // this cannot regress.
        let probedPort = try? FreePortProbe.probe()

        let launch = CLIChildProcess.Launch(
            executable: cliURL,
            configPath: paths.configFile,
            controlSocketPath: paths.controlSocket,
            httpPort: probedPort,
            logFileURL: paths.cliLogFile,
            extraEnvironment: extraEnv
        )
        let child = CLIChildProcess(launch: launch)
        let startInstant = Date()
        child.onUnexpectedExit = { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                // AUDIT R1 CODE H1: nil the wrapper BEFORE scheduling reconnect
                // so start()'s `guard child == nil` doesn't short-circuit.
                self.child = nil
                // AUDIT R1 ARCHITECT A7: fast-fail on flag/compat rejection.
                let elapsed = Date().timeIntervalSince(startInstant)
                if elapsed < 3 && code != 0 {
                    self.snapshot.state = .error
                    self.snapshot.lastError = "The bundled macprovider-cli is incompatible with this Malibu.app version (exit \(code) in \(String(format: "%.1f", elapsed))s). Please reinstall Malibu.app or file a bug."
                    return
                }
                // AUDIT R2 CODE H3: do not schedule a reconnect during shutdown.
                guard !self.isShuttingDown else { return }
                self.snapshot.state = .reconnecting
                self.snapshot.lastError = "CLI exited (\(code))"
                await self.scheduleReconnect()
            }
        }
        self.child = child

        do {
            try child.start()
            startLogTail(fileURL: paths.cliLogFile)
        } catch {
            snapshot.state = .error; snapshot.lastError = "Failed to launch: \(error)"
            self.child = nil
            return
        }

        await connectControl(socketPath: paths.controlSocket.path)
    }

    // AUDIT R1 ARCHITECT A1: don't flip state until the CLI acks. If the CLI
    // returns accepted:false (current stub does), leave state where it was
    // and surface the reason in snapshot.lastError.
    func pause() async {
        snapshot.pauseAcknowledged = false
        try? await control?.send(.pauseRequest)
    }

    func resume() async {
        try? await control?.send(.resumeRequest)
    }

    // AUDIT R2 CODE H2/H3: shutdown is the single termination path. Called from
    // both Quit-and-Uninstall and applicationShouldTerminate for plain Quit.
    // Cancels reconnect BEFORE marking child as stopping so nothing sneaks a
    // start() past the isShuttingDown gate.
    func shutdown(gracefulSeconds: Int) async {
        isShuttingDown = true
        reconnectTask?.cancel(); reconnectTask = nil
        healthPollTask?.cancel(); healthPollTask = nil
        monitorsLaunchdProvider = false
        child?.markStopping()

        try? await control?.send(.shutdownRequest(graceSeconds: gracefulSeconds))
        await child?.stop(gracePeriod: TimeInterval(gracefulSeconds))
        await control?.close()
        metricsPoller?.cancel(); metricsPoller = nil
        eventStreamTask?.cancel(); eventStreamTask = nil
        logTailCancellable?.cancel(); logTailCancellable = nil
        logTailReader?.stop(); logTailReader = nil
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
    func monitorInstalledProviderIfPresent(timeout: TimeInterval = 120) async -> Bool {
        guard let port = ProviderConfig.readHTTPPort(),
              ProviderConfig.readProviderID() != nil else {
            return false
        }
        let deadline = Date().addingTimeInterval(max(1, timeout))
        guard await InstalledProviderMonitor.waitForHealthy(port: port, deadline: deadline) else {
            return false
        }
        monitorsLaunchdProvider = true
        await applyHealthSnapshot(port: port)
        snapshot.state = .serving
        snapshot.lastError = nil
        startHealthPolling(port: port)
        await refreshEarnings()
        return true
    }

    private func applyHealthSnapshot(port: Int) async {
        guard let health = await InstalledProviderMonitor.fetchHealth(port: port) else { return }
        if let model = health.model, !model.isEmpty {
            snapshot.currentModelID = model
        }
        if let total = health.requestsTotal {
            snapshot.requestsServedAllTime = total
        }
        if let uptime = health.uptimeSeconds {
            snapshot.uptimeSec = uptime
        }
        if health.ready {
            snapshot.state = .serving
        }
    }

    private func startHealthPolling(port: Int) {
        healthPollTask?.cancel()
        healthPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                if await InstalledProviderMonitor.isHealthy(port: port) {
                    await self.applyHealthSnapshot(port: port)
                    await MainActor.run {
                        if self.snapshot.state != .serving && self.snapshot.state != .paused {
                            self.snapshot.state = .serving
                        }
                    }
                    await self.refreshEarnings()
                } else if self.monitorsLaunchdProvider {
                    await MainActor.run {
                        self.snapshot.state = .reconnecting
                        self.snapshot.lastError = "Background provider is not responding on port \(port)."
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
            if state == "ready" || state == "serving" { snapshot.state = .serving }
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
                snapshot.state = .serving
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
        do {
            let earnings = try await earningsClient.fetch(providerID: providerID, bearerToken: token)
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
        } catch {
            // Earnings is not part of the daemon liveness path. Keep existing
            // metrics visible and retry on the next poll without logging bearer
            // material or the request payload.
        }
    }

    private func startLogTail(fileURL: URL) {
        logTailCancellable?.cancel()
        logTailReader?.stop()
        let reader = LogTailReader(fileURL: fileURL)
        logTailCancellable = reader.$lines
            .sink { [weak self] lines in
                self?.logLines = lines
            }
        logTailReader = reader
        reader.start()
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
