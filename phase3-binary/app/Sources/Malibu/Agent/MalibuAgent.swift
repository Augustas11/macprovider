import Combine
import Foundation

struct AgentSnapshot: Equatable {
    enum State: String { case idle, starting, serving, paused, reconnecting, error }
    var state: State
    var currentModelID: String?
    var earningsUsdcToday: Double
    var malibuAccruedToday: Double
    var uptimeSec: Int
    var lastError: String?

    static let empty = AgentSnapshot(
        state: .idle, currentModelID: nil,
        earningsUsdcToday: 0, malibuAccruedToday: 0, uptimeSec: 0, lastError: nil
    )

    var short: String {
        switch state {
        case .idle, .starting: return "Idle"
        case .serving: return String(format: "$%.2f", earningsUsdcToday)
        case .paused: return "Paused"
        case .reconnecting: return "…"
        case .error: return "!"
        }
    }
    var stateLine: String {
        switch state {
        case .idle: return "Not running"
        case .starting: return "Starting…"
        case .serving: return "Serving " + (currentModelID ?? "model")
        case .paused: return "Paused"
        case .reconnecting: return "Reconnecting…"
        case .error: return lastError ?? "Error"
        }
    }
    var earningsLine: String {
        String(format: "Today: $%.2f USDC · %.2f MALIBU", earningsUsdcToday, malibuAccruedToday)
    }
}

@MainActor
final class MalibuAgent: ObservableObject {
    @Published private(set) var snapshot: AgentSnapshot = .empty

    private var child: CLIChildProcess?
    private var control: ControlSocketClient?
    private var metricsPoller: Task<Void, Never>?
    private var eventStreamTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() async {
        guard child == nil else { return }
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

        let launch = CLIChildProcess.Launch(
            executable: cliURL,
            configPath: paths.configFile,
            controlSocketPath: paths.controlSocket,
            httpPort: nil,
            logFileURL: paths.cliLogFile,
            extraEnvironment: extraEnv
        )
        let child = CLIChildProcess(launch: launch)
        child.onUnexpectedExit = { [weak self] code in
            Task { @MainActor in
                self?.snapshot.state = .reconnecting
                self?.snapshot.lastError = "CLI exited (\(code))"
                await self?.scheduleReconnect()
            }
        }
        self.child = child

        do {
            try child.start()
        } catch {
            snapshot.state = .error; snapshot.lastError = "Failed to launch: \(error)"; return
        }

        await connectControl(socketPath: paths.controlSocket.path)
    }

    func pause() async {
        try? await control?.send(.pauseRequest)
        snapshot.state = .paused
    }

    func resume() async {
        try? await control?.send(.resumeRequest)
        snapshot.state = .serving
    }

    func shutdown(gracefulSeconds: Int) async {
        try? await control?.send(.shutdownRequest(graceSeconds: gracefulSeconds))
        await child?.stop(gracePeriod: TimeInterval(gracefulSeconds))
        await control?.close()
        metricsPoller?.cancel()
        eventStreamTask?.cancel()
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
            snapshot.state = .error; snapshot.lastError = "Control socket: \(error)"; return
        }
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
        case let .metricsResponse(usdc, malibu, _, _, uptime):
            snapshot.earningsUsdcToday = usdc
            snapshot.malibuAccruedToday = malibu
            snapshot.uptimeSec = uptime
        default:
            break
        }
    }

    private func scheduleReconnect() async {
        await child?.scheduleRestartWithBackoff { [weak self] in
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
