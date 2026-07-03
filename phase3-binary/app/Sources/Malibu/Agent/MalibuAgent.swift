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

    private var child: CLIChildProcess?
    private var control: ControlSocketClient?
    private var metricsPoller: Task<Void, Never>?
    private var eventStreamTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnect = ReconnectPolicy()
    // AUDIT R2 CODE H3 fix: once shutdown begins, refuse any subsequent start()
    // — including a reconnect Task that already slept past its cancellation
    // check but hadn't yet re-entered the MainActor.
    private var isShuttingDown: Bool = false

    // MARK: - Lifecycle

    func start() async {
        // AUDIT R2 CODE H3 fix.
        guard !isShuttingDown else { return }
        guard child == nil else { return }

        // AUDIT R2 CODE H4 fix: refuse to spawn the CLI without a validated
        // app-owned config + keychain token. Onboarding must complete the
        // deep-link callback first.
        guard await ProviderConfig.isConfigured else {
            snapshot.state = .error
            snapshot.lastError = "Not linked yet. Open Set up… and link your node."
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

        let launch = CLIChildProcess.Launch(
            executable: cliURL,
            configPath: paths.configFile,
            controlSocketPath: paths.controlSocket,
            httpPort: nil,
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
        child?.markStopping()

        try? await control?.send(.shutdownRequest(graceSeconds: gracefulSeconds))
        await child?.stop(gracePeriod: TimeInterval(gracefulSeconds))
        await control?.close()
        metricsPoller?.cancel(); metricsPoller = nil
        eventStreamTask?.cancel(); eventStreamTask = nil
        child = nil
        control = nil
        snapshot = .empty
    }

    // MARK: - Private

    private func connectControl(socketPath: String) async {
        let client = ControlSocketClient(socketPath: socketPath)
        do {
            try await client.connect(timeout: 10)
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
        snapshot.state = .serving

        eventStreamTask = Task { [weak self] in
            guard let client = await self?.control else { return }
            for await frame in client.stream {
                await self?.consume(frame)
            }
        }

        metricsPoller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                try? await self?.control?.send(.metricsRequest)
                try? await self?.control?.send(.statusRequest)
            }
        }

        try? await control?.send(.statusRequest)
        try? await control?.send(.metricsRequest)
    }

    private func consume(_ frame: ControlFrame) {
        switch frame {
        case let .statusResponse(model, state):
            snapshot.currentModelID = model
            if state == "serving" { snapshot.state = .serving }
        case let .metricsResponse(usdc, malibu, gpu, latency, uptime):
            // AUDIT R2 ARCHITECT A1 fix: the CLI stub emits earnings_usdc=0,
            // malibu_accrued=0, uptime_sec=0 with no gpu/latency until real
            // metrics land in SPEC-025 §11 P1. Rendering this tuple as
            // authoritative "$0.00" masked "unimplemented" as "you earned
            // nothing." Suppress the stub-shaped tuple to `nil` so the
            // presenter shows "—" instead. Real metric responses populate
            // at least uptime > 0 within seconds of the daemon coming up.
            let looksLikeStub = usdc == 0 && malibu == 0 && uptime == 0
                                 && gpu == nil && latency == nil
            if looksLikeStub {
                snapshot.earningsUsdcToday = nil
                snapshot.malibuAccruedToday = nil
                snapshot.uptimeSec = nil
            } else {
                snapshot.earningsUsdcToday = usdc
                snapshot.malibuAccruedToday = malibu
                snapshot.uptimeSec = uptime
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
        default:
            break
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

    private static func resolveCLIExecutable() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MALIBU_CLI_PATH"] {
            return URL(fileURLWithPath: override)
        }
        let bundled = Bundle.main.bundleURL
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
