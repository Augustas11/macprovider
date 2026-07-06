import Foundation

// Malibu is a CLI wrapper: onboarding runs install.sh, then Malibu monitors
// the launchd-managed macprovider-cli. No in-app register/autotune/spawn path.

@MainActor
final class LaunchProviderController: ObservableObject {

    enum TrustTier: String, Equatable, Codable {
        case provisional
        case trusted
    }

    enum Stage: Equatable {
        case idle
        case runningCLIInstall
        case startingAgent
        case live(model: String, tier: TrustTier)
        case failed(stage: String, retryable: Bool, message: String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var installLogLines: [String] = []
    @Published private(set) var installProgressHint: String?
    @Published private(set) var installStartedAt: Date?

    private var installProgressTask: Task<Void, Never>?
    private let dependencies: Dependencies

    struct Dependencies {
        var localInstallSucceeded: @MainActor () async -> Bool
        var registerLoginItem: @MainActor () async throws -> Void
        var runCLIInstall: @MainActor (@escaping @MainActor (String) -> Void) async throws -> Void
        var importCLIConfigAfterInstall: @MainActor () async throws -> Void
        var monitorInstalledProvider: @MainActor () async -> Bool
        var readConfigModel: () -> String?

        static func live(agent: MalibuAgent?) -> Dependencies {
            Dependencies(
                localInstallSucceeded: { await CLIInstallRunner.localInstallSucceeded() },
                registerLoginItem: { try AppLoginItem.register() },
                runCLIInstall: { onLogLine in
                    try await CLIInstallRunner.run(onLogLine: onLogLine)
                },
                importCLIConfigAfterInstall: {
                    try await ProviderConfig.importExistingCLIConfig()
                },
                monitorInstalledProvider: {
                    guard let agent else { return false }
                    return await agent.monitorInstalledProviderIfPresent(
                        timeout: MalibuOnboardingTimeouts.firstServingFrameSec
                    )
                },
                readConfigModel: { ProviderConfig.readModel() }
            )
        }
    }

    init(agent: MalibuAgent? = nil, dependencies: Dependencies? = nil) {
        self.dependencies = dependencies ?? .live(agent: agent)
    }

    func launch() async {
        if await dependencies.localInstallSucceeded() {
            installLogLines = ["Background provider is already running locally. Connecting Malibu to it."]
            await finalizeInstall()
            return
        }
        await launchViaCLIInstall()
    }

    func retry() async {
        guard case .failed(_, let retryable, _) = stage, retryable else { return }
        await launch()
    }

    func setPayoutWallet(_ address: String) async throws {
        throw NSError(
            domain: "SPEC-027",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Wallet binding is a guarded SPEC-027 follow-up route."]
        )
    }

    func refreshFromExistingInstall() async {
        switch stage {
        case .idle, .failed(stage: "cliInstall", _, _):
            break
        default:
            return
        }
        guard await dependencies.localInstallSucceeded() else { return }
        installLogLines = ["Background provider is already running locally."]
        await finalizeInstall()
    }

    private func launchViaCLIInstall() async {
        beginInstallProgressWatch()
        defer { endInstallProgressWatch() }
        do {
            stage = .runningCLIInstall
            installLogLines = []
            try await dependencies.runCLIInstall { [weak self] line in
                guard let self else { return }
                self.installLogLines.append(line)
                if self.installLogLines.count > 200 {
                    self.installLogLines.removeFirst(self.installLogLines.count - 200)
                }
            }
            do {
                try await dependencies.importCLIConfigAfterInstall()
            } catch {
                if await dependencies.localInstallSucceeded() {
                    installLogLines.append(
                        "Provider token not in config yet; Malibu will monitor the background provider without Keychain import."
                    )
                } else {
                    throw error
                }
            }
            await finalizeInstall()
        } catch {
            stage = .failed(stage: "cliInstall", retryable: true, message: error.localizedDescription)
        }
    }

    private func finalizeInstall() async {
        do {
            try await dependencies.registerLoginItem()
            stage = .startingAgent
            guard await dependencies.monitorInstalledProvider() else {
                throw launchdMonitorUnavailableError()
            }
            let model = dependencies.readConfigModel() ?? "installed"
            stage = .live(model: model, tier: .provisional)
        } catch {
            stage = .failed(stage: "cliInstall", retryable: true, message: error.localizedDescription)
        }
    }

    private func launchdMonitorUnavailableError() -> NSError {
        NSError(
            domain: "Malibu.LaunchProviderController",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Background provider did not become healthy in time. Check ~/Library/Logs/macprovider/ and try again."
            ]
        )
    }

    private func beginInstallProgressWatch() {
        installStartedAt = Date()
        installProgressHint = "Starting installer…"
        installProgressTask?.cancel()
        installProgressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.installProgressHint = CLIInstallRunner.ActivityMonitor.snapshot()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func endInstallProgressWatch() {
        installProgressTask?.cancel()
        installProgressTask = nil
        installStartedAt = nil
        installProgressHint = nil
    }
}

enum StartupRoute: Equatable {
    case startAgent
    case showOnboarding
    case showImportDialog
    case quit
}

enum MigrationDecision: Equatable {
    case importExisting
    case startFresh
    case cancel
}

struct MigrationResult: Equatable {
    let route: StartupRoute
    let backupPath: String?
}

struct StartupState: Equatable {
    let configExists: Bool
    let appMarkerExists: Bool
    let launchdInstallEvidenceExists: Bool
    let backgroundProviderHealthy: Bool

    @MainActor
    static func detect(paths: ProviderPaths = .current) async -> StartupState {
        let fm = FileManager.default
        try? await ProviderConfig.recoverPendingImportIfNeeded(paths: paths)
        let configExists = fm.fileExists(atPath: paths.configFile.path)
        let markerExists = fm.fileExists(atPath: paths.appMarkerFile.path)
        let launchdInstallEvidenceExists = Self.launchdInstallEvidenceExists(paths: paths)

        var backgroundProviderHealthy = false
        if ProviderConfig.readProviderID(paths: paths) != nil,
           let port = ProviderConfig.readHTTPPort(paths: paths),
           launchdInstallEvidenceExists {
            backgroundProviderHealthy = await InstalledProviderMonitor.isHealthy(port: port)
        }

        return StartupState(
            configExists: configExists,
            appMarkerExists: markerExists,
            launchdInstallEvidenceExists: launchdInstallEvidenceExists,
            backgroundProviderHealthy: backgroundProviderHealthy
        )
    }

    func route() -> StartupRoute {
        if backgroundProviderHealthy {
            return .startAgent
        }
        if configExists && !appMarkerExists {
            return .showImportDialog
        }
        // Launchd + config but provider still starting: attach and poll health.
        if launchdInstallEvidenceExists && configExists {
            return .startAgent
        }
        // Legacy app-track config without launchd, or launchd plist without config:
        // run install.sh via onboarding instead of a reconnect loop.
        if configExists || launchdInstallEvidenceExists {
            return .showOnboarding
        }
        return .showOnboarding
    }

    static func launchdInstallEvidenceExists(paths: ProviderPaths = .current) -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let manifest = home.appendingPathComponent("Library/Application Support/macprovider/install_manifest.json")
        let launchd = home.appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist")
        return fm.isReadableFile(atPath: manifest.path) || fm.isReadableFile(atPath: launchd.path)
    }

    static func applyMigrationDecision(
        _ decision: MigrationDecision,
        paths: ProviderPaths = .current,
        now: Date = Date()
    ) async throws -> MigrationResult {
        switch decision {
        case .importExisting:
            try await ProviderConfig.importExistingCLIConfig(paths: paths)
            let state = await StartupState.detect(paths: paths)
            return MigrationResult(route: state.route(), backupPath: nil)
        case .startFresh:
            let backup = try ProviderConfig.startFreshMovingCLIConfigAside(now: now, paths: paths)
            return MigrationResult(route: .showOnboarding, backupPath: backup?.path)
        case .cancel:
            return MigrationResult(route: .quit, backupPath: nil)
        }
    }
}
