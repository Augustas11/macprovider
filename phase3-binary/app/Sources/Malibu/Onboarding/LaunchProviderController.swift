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
        case importingProviderCredential
        case live(model: String, tier: TrustTier)
        case failed(stage: String, retryable: Bool, message: String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var installLogLines: [String] = []
    @Published private(set) var installProgressHint: String?
    @Published private(set) var installStartedAt: Date?
    @Published var referralInput = ""
    @Published private(set) var referralInputAvailable = false
    @Published private(set) var referralAvailabilityChecked = false

    private var installProgressTask: Task<Void, Never>?
    private let replacementConfirmed: Bool
    private let dependencies: Dependencies

    struct Dependencies {
        var localInstallSucceeded: @MainActor () async -> Bool
        var restartSafeIncumbentPresent: @MainActor () async -> Bool
        var referralInputAvailable: @MainActor () async -> Bool
        var registerLoginItem: @MainActor () async throws -> Void
        var runCLIInstall: @MainActor (
            String?,
            Bool,
            @escaping @Sendable @MainActor (String) -> Void
        ) async throws -> Void
        var importCLIConfigAfterInstall: @MainActor () async throws -> Void
        var waitForInstalledProviderHealth: @MainActor () async -> Bool
        var attachInstalledProviderAfterInstall: @MainActor () async -> Bool
        var readConfigModel: () -> String?
        var providerStartFailure: @MainActor () -> String?
        var appIdentityConfigured: @MainActor () async -> Bool
        var waitBeforeImportRetry: @MainActor () async throws -> Void

        static func live(agent: MalibuAgent?) -> Dependencies {
            Dependencies(
                localInstallSucceeded: { await CLIInstallRunner.localInstallSucceeded() },
                restartSafeIncumbentPresent: {
                    await LaunchProviderController.restartSafeIncumbentPresent()
                },
                referralInputAvailable: {
                    await LaunchProviderController.referralInputAvailableForCurrentInstall()
                },
                registerLoginItem: { try AppLoginItem.register() },
                runCLIInstall: { referralCode, replacingIncumbentProvider, onLogLine in
                    try await CLIInstallRunner.run(
                        referralCode: referralCode,
                        replacingIncumbentProvider: replacingIncumbentProvider,
                        onLogLine: onLogLine
                    )
                },
                importCLIConfigAfterInstall: {
                    try await ProviderConfig.importExistingCLIConfig()
                },
                waitForInstalledProviderHealth: {
                    await LaunchProviderController.waitForInstalledProviderHealth(
                        timeout: MalibuOnboardingTimeouts.firstServingFrameSec
                    )
                },
                attachInstalledProviderAfterInstall: {
                    await agent?.monitorInstalledProviderIfPresent(
                        timeout: MalibuOnboardingTimeouts.firstServingFrameSec
                    ) ?? false
                },
                readConfigModel: { ProviderConfig.readModel() },
                providerStartFailure: { agent?.providerStartFailure },
                appIdentityConfigured: { await ProviderConfig.isConfigured },
                waitBeforeImportRetry: {
                    try await Task.sleep(
                        nanoseconds: UInt64(MalibuOnboardingTimeouts.providerTokenImportRetryIntervalSec * 1_000_000_000)
                    )
                }
            )
        }
    }

    init(
        agent: MalibuAgent? = nil,
        replacementConfirmed: Bool = false,
        dependencies: Dependencies? = nil
    ) {
        self.replacementConfirmed = replacementConfirmed
        self.dependencies = dependencies ?? .live(agent: agent)
    }

    func launch() async {
        let referralCode: String?
        do {
            referralCode = try ReferralOnboardingInput.normalize(referralInput)
        } catch {
            stage = .failed(stage: "referral", retryable: true, message: error.localizedDescription)
            return
        }

        if let referralCode {
            if !(await dependencies.referralInputAvailable()) {
                stage = .failed(
                    stage: "referral",
                    retryable: true,
                    message: "Invite entry is unavailable with the currently installed provider software. Update Malibu and provider software, then retry."
                )
                return
            }
            if replacementConfirmed {
                await launchViaCLIInstall(
                    referralCode: referralCode,
                    replacingIncumbentProvider: true
                )
                return
            }
            if await dependencies.localInstallSucceeded() {
                await finalizeExistingInstall(
                    logLine: "Background provider is already running locally. Connecting Malibu to it."
                )
                return
            }
            if await dependencies.restartSafeIncumbentPresent() {
                await launchViaCLIInstall(referralCode: nil, replacingIncumbentProvider: false)
                return
            }
            await launchViaCLIInstall(referralCode: referralCode, replacingIncumbentProvider: false)
            return
        }

        if replacementConfirmed {
            stage = .failed(
                stage: "referral",
                retryable: true,
                message: CLIInstallRunner.Error.ReferralFailure.required.message
            )
            return
        }

        if await dependencies.localInstallSucceeded() {
            await finalizeExistingInstall(
                logLine: "Background provider is already running locally. Connecting Malibu to it."
            )
            return
        }
        if await dependencies.restartSafeIncumbentPresent() {
            await launchViaCLIInstall(referralCode: nil, replacingIncumbentProvider: false)
            return
        }
        stage = .failed(
            stage: "referral",
            retryable: true,
            message: CLIInstallRunner.Error.ReferralFailure.required.message
        )
    }

    func refreshReferralInputAvailability() async {
        referralInputAvailable = await dependencies.referralInputAvailable()
        referralAvailabilityChecked = true
    }

    func retry() async {
        guard case .failed(_, let retryable, _) = stage, retryable else { return }
        await launch()
    }

    func setPayoutWallet(_ address: String) async throws {
        throw NSError(
            domain: "Malibu.WalletBinding",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Wallet setup is not available in this Malibu build."]
        )
    }

    func refreshFromExistingInstall() async {
        guard !replacementConfirmed else { return }
        switch stage {
        case .idle, .failed(stage: "cliInstall", _, _), .failed(stage: "identityImport", _, _):
            break
        default:
            return
        }
        guard await dependencies.localInstallSucceeded() else { return }
        await finalizeExistingInstall(logLine: "Background provider is already running locally.")
    }

    private func launchViaCLIInstall(referralCode: String?, replacingIncumbentProvider: Bool) async {
        beginInstallProgressWatch()
        defer { endInstallProgressWatch() }
        do {
            stage = .runningCLIInstall
            installLogLines = []
            try await dependencies.runCLIInstall(referralCode, replacingIncumbentProvider) { [weak self] line in
                guard let self else { return }
                self.installLogLines.append(LogTailBuffer.redacted(line))
                if self.installLogLines.count > 200 {
                    self.installLogLines.removeFirst(self.installLogLines.count - 200)
                }
            }
            var importError: Error?
            do {
                try await dependencies.importCLIConfigAfterInstall()
            } catch {
                if isRetriableImportError(error) {
                    importError = error
                    installLogLines.append(deferredImportMessage(for: error))
                } else {
                    stage = .failed(stage: "identityImport", retryable: true, message: error.localizedDescription)
                    return
                }
            }
            await finalizeInstall(pendingImportError: importError)
        } catch let CLIInstallRunner.Error.referralFailure(failure) {
            await refreshReferralInputAvailability()
            stage = .failed(
                stage: "referral",
                retryable: true,
                message: failure.message
            )
        } catch {
            stage = .failed(stage: "cliInstall", retryable: true, message: error.localizedDescription)
        }
    }

    private func finalizeExistingInstall(logLine: String) async {
        installLogLines = [logLine]
        guard !Task.isCancelled else { return }
        if await dependencies.appIdentityConfigured() {
            await finalizeInstall()
            return
        }
        var importError: Error?
        do {
            try await dependencies.importCLIConfigAfterInstall()
        } catch {
            guard isRetriableImportError(error) else {
                stage = .failed(stage: "identityImport", retryable: true, message: error.localizedDescription)
                return
            }
            importError = error
            installLogLines.append(deferredImportMessage(for: error))
        }
        await finalizeInstall(pendingImportError: importError)
    }

    private func finalizeInstall(pendingImportError: Error? = nil) async {
        do {
            stage = .startingAgent
            guard await dependencies.waitForInstalledProviderHealth() else {
                let message = dependencies.providerStartFailure()
                    ?? ProviderLogDiagnostics.timeoutMessage(logHint: ProviderLogDiagnostics.logHint())
                throw launchdMonitorUnavailableError(message: message)
            }
            if let pendingImportError {
                stage = .importingProviderCredential
                do {
                    try await retryPendingImportAfterProviderStart(initialError: pendingImportError)
                } catch {
                    stage = .failed(stage: "identityImport", retryable: true, message: error.localizedDescription)
                    return
                }
            }
            guard await dependencies.appIdentityConfigured() else {
                stage = .failed(
                    stage: "identityImport",
                    retryable: true,
                    message: providerIdentityImportUnavailableError(
                        underlying: ProviderConfig.SaveError.savedIdentityNotConfigured
                    ).localizedDescription
                )
                return
            }
            guard await dependencies.attachInstalledProviderAfterInstall() else {
                let message = dependencies.providerStartFailure()
                    ?? ProviderLogDiagnostics.timeoutMessage(logHint: ProviderLogDiagnostics.logHint())
                throw launchdMonitorUnavailableError(message: message)
            }
            try await dependencies.registerLoginItem()
            let model = dependencies.readConfigModel() ?? "installed"
            stage = .live(model: model, tier: .provisional)
        } catch {
            stage = .failed(stage: "cliInstall", retryable: true, message: error.localizedDescription)
        }
    }

    private func retryPendingImportAfterProviderStart(initialError: Error) async throws {
        var lastError = initialError
        for attempt in 1...MalibuOnboardingTimeouts.providerTokenImportRetryAttempts {
            try Task.checkCancellation()
            do {
                try await dependencies.importCLIConfigAfterInstall()
                return
            } catch {
                guard isRetriableImportError(error) else {
                    throw error
                }
                lastError = error
                if attempt < MalibuOnboardingTimeouts.providerTokenImportRetryAttempts {
                    try await dependencies.waitBeforeImportRetry()
                }
            }
        }
        throw providerIdentityImportUnavailableError(underlying: lastError)
    }

    private func launchdMonitorUnavailableError(message: String) -> NSError {
        NSError(
            domain: "Malibu.LaunchProviderController",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func isMissingProviderToken(_ error: Error) -> Bool {
        if case ProviderConfig.SaveError.missingProviderToken = error {
            return true
        }
        return false
    }

    private func isRetriableImportError(_ error: Error) -> Bool {
        isMissingProviderToken(error)
    }

    private func providerIdentityImportUnavailableError(underlying: Error) -> NSError {
        NSError(
            domain: "Malibu.LaunchProviderController",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey: "The existing provider was not fully imported after the background provider became healthy. Retry setup once saved provider access is available.",
                NSUnderlyingErrorKey: underlying,
            ]
        )
    }

    private func deferredImportMessage(for error: Error) -> String {
        if isMissingProviderToken(error) {
            return "Saved provider access is not available yet; waiting for the background provider before import."
        }
        return "Provider import failed; waiting for the background provider before retrying."
    }

    private static func waitForInstalledProviderHealth(timeout: TimeInterval) async -> Bool {
        guard let port = ProviderConfig.readHTTPPort(),
              ProviderConfig.readProviderID() != nil,
              StartupState.launchdInstallEvidenceExists() else {
            return false
        }
        let deadline = Date().addingTimeInterval(max(1, timeout))
        while Date() < deadline {
            if Task.isCancelled {
                return false
            }
            if await InstalledProviderMonitor.isHealthy(port: port) {
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    private static func referralInputAvailableForCurrentInstall() async -> Bool {
        let bundledHandoffEnabled = Bundle.main.object(
            forInfoDictionaryKey: "MalibuBundledReferralBootstrapV1"
        ) as? Bool == true
        // Malibu executes its separately bundled, signed installer. Fresh or
        // partial installs therefore use that verified capability rather than
        // requiring a possibly stopped installed provider to negotiate it.
        return bundledHandoffEnabled
    }

    private static func restartSafeIncumbentPresent(
        paths: ProviderPaths = .current,
        fileManager: FileManager = .default
    ) async -> Bool {
        guard let providerID = ProviderConfig.readProviderID(paths: paths),
              (try? ProviderCredentialHandoffRunner.resolveInstalledExecutable(
                  home: fileManager.homeDirectoryForCurrentUser,
                  fileManager: fileManager
              )) != nil else {
            return false
        }
        if ProviderConfig.hasProviderToken(paths: paths) {
            return true
        }
        if await ProviderConfig.isConfigured(paths: paths) {
            return true
        }
        if let credential = try? await ProviderCredentialHandoffRunner.credentialStatus(
            configURL: paths.configFile,
            expectedProviderID: providerID
        ), credential.restartSafe {
            return true
        }
        let manifest = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        )
        let launchd = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/LaunchAgents/live.streamvc.macprovider.plist"
        )
        return fileManager.isReadableFile(atPath: manifest.path)
            && fileManager.isReadableFile(atPath: launchd.path)
    }

    static func referralHandoffAvailable(
        bundledHandoffEnabled: Bool,
        installedCLIAdvertisesReferralBootstrapV1: Bool?
    ) -> Bool {
        guard bundledHandoffEnabled else { return false }
        return installedCLIAdvertisesReferralBootstrapV1 ?? true
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
    let appIdentityConfigured: Bool
    let launchdInstallEvidenceExists: Bool
    let backgroundProviderHealthy: Bool

    @MainActor
    static func detect(paths: ProviderPaths = .current) async -> StartupState {
        let fm = FileManager.default
        try? await ProviderConfig.recoverPendingImportIfNeeded(paths: paths)
        let configExists = fm.fileExists(atPath: paths.configFile.path)
        let markerExists = fm.fileExists(atPath: paths.appMarkerFile.path)
        let identityConfigured = await ProviderConfig.isConfigured(paths: paths)
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
            appIdentityConfigured: identityConfigured,
            launchdInstallEvidenceExists: launchdInstallEvidenceExists,
            backgroundProviderHealthy: backgroundProviderHealthy
        )
    }

    func route() -> StartupRoute {
        if configExists && !appMarkerExists {
            return .showImportDialog
        }
        if configExists && appMarkerExists && !appIdentityConfigured {
            return .showOnboarding
        }
        if backgroundProviderHealthy {
            return .startAgent
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
        now: Date = Date(),
        deferStartFreshBackup: Bool = false,
        importCredentialIntoCLI: (@Sendable (URL) async throws -> Void)? = nil
    ) async throws -> MigrationResult {
        switch decision {
        case .importExisting:
            if let importCredentialIntoCLI {
                try await ProviderConfig.importExistingCLIConfig(
                    paths: paths,
                    importCredentialIntoCLI: importCredentialIntoCLI
                )
            } else {
                try await ProviderConfig.importExistingCLIConfig(paths: paths)
            }
            let state = await StartupState.detect(paths: paths)
            return MigrationResult(route: state.route(), backupPath: nil)
        case .startFresh:
            if deferStartFreshBackup {
                return MigrationResult(route: .showOnboarding, backupPath: nil)
            }
            let backup = try ProviderConfig.startFreshMovingCLIConfigAside(now: now, paths: paths)
            return MigrationResult(route: .showOnboarding, backupPath: backup?.path)
        case .cancel:
            return MigrationResult(route: .quit, backupPath: nil)
        }
    }
}
