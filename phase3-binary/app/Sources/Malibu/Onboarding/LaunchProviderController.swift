import Foundation

struct ReferralPreflightResult: Decodable, Equatable {
    let valid: Bool
    let reason: String
    let required: Bool

    init(valid: Bool, reason: String, required: Bool = true) {
        self.valid = valid
        self.reason = reason
        self.required = required
    }
}

private enum ReferralPreflightError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Malibu could not check this invite. Check your connection and try again."
    }
}

// Malibu is a CLI wrapper: onboarding runs install.sh. Fresh installs use the
// launchd bootstrap long enough to import the issued identity; app-owned
// identities then run as a Malibu child so their bearer remains in Keychain.

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
        case importingProviderIdentity
        case live(model: String, tier: TrustTier)
        case failed(stage: String, retryable: Bool, message: String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var installLogLines: [String] = []
    @Published private(set) var installProgressHint: String?
    @Published private(set) var installStartedAt: Date?
    @Published var referralCode = ""
    @Published private(set) var referralRequired = true

    private var installProgressTask: Task<Void, Never>?
    private let dependencies: Dependencies

    struct Dependencies {
        var localInstallSucceeded: @MainActor () async -> Bool
        var validateReferralCode: @MainActor (String) async throws -> ReferralPreflightResult
        var registerLoginItem: @MainActor () async throws -> Void
        var runCLIInstall: @MainActor (String, @escaping @MainActor (String) -> Void) async throws -> Void
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
                validateReferralCode: { code in
                    guard let baseURL = ProviderConfig.readCoordinatorBaseURL()
                        ?? URL(string: "https://coordinator.streamvc.live") else {
                        throw ReferralPreflightError.unavailable
                    }
                    var request = URLRequest(url: baseURL.appendingPathComponent("v1/referrals/validate"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(["code": code])
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 6
                    configuration.timeoutIntervalForResource = 8
                    let session = URLSession(configuration: configuration)
                    defer { session.finishTasksAndInvalidate() }
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw ReferralPreflightError.unavailable
                    }
                    return try JSONDecoder().decode(ReferralPreflightResult.self, from: data)
                },
                registerLoginItem: { try AppLoginItem.register() },
                runCLIInstall: { referralCode, onLogLine in
                    try await CLIInstallRunner.run(referralCode: referralCode, onLogLine: onLogLine)
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
                    await agent?.startManagedProvider(
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

    init(agent: MalibuAgent? = nil, dependencies: Dependencies? = nil) {
        self.dependencies = dependencies ?? .live(agent: agent)
    }

    var normalizedReferralCode: String {
        referralCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var referralCodeIsValid: Bool {
        Self.isValidReferralCode(normalizedReferralCode)
    }

    static func isValidReferralCode(_ raw: String) -> Bool {
        raw.range(
            of: #"^MAL1-[SP]-[A-Za-z0-9_]{1,32}-[A-Za-z0-9_]{1,32}-[A-Z2-7]{26}$"#,
            options: .regularExpression
        ) != nil
    }

    func launch() async {
        if await dependencies.localInstallSucceeded() {
            await finalizeExistingInstall(
                logLine: "Background provider is already running locally. Connecting Malibu to it."
            )
            return
        }
        let existingIdentity = await dependencies.appIdentityConfigured()
        await launchViaCLIInstall(existingIdentity: existingIdentity)
    }

    func refreshReferralPolicy() async {
        if await dependencies.appIdentityConfigured() {
            referralRequired = false
            return
        }
        do {
            let result = try await dependencies.validateReferralCode("")
            referralRequired = result.required
        } catch {
            // Fail closed until policy discovery succeeds. Existing installs
            // bypass this UI and are never re-gated.
            referralRequired = true
        }
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
        case .idle, .failed(stage: "cliInstall", _, _), .failed(stage: "identityImport", _, _):
            break
        default:
            return
        }
        guard await dependencies.localInstallSucceeded() else { return }
        await finalizeExistingInstall(logLine: "Background provider is already running locally.")
    }

    private func launchViaCLIInstall(existingIdentity: Bool = false) async {
        guard existingIdentity || !referralRequired || referralCodeIsValid else {
            stage = .failed(
                stage: "referral",
                retryable: true,
                message: "Enter a valid Malibu pre-beta invite code."
            )
            return
        }
        var preflightWarning: String?
        if referralRequired && !existingIdentity {
            do {
                let result = try await dependencies.validateReferralCode(normalizedReferralCode)
                guard result.valid else {
                    stage = .failed(stage: "referral", retryable: true, message: Self.referralFailureMessage(result.reason))
                    return
                }
            } catch {
                preflightWarning = "Invite pre-check unavailable; final validation will happen securely during registration."
            }
        }
        beginInstallProgressWatch()
        defer { endInstallProgressWatch() }
        do {
            stage = .runningCLIInstall
            installLogLines = preflightWarning.map { [$0] } ?? []
            try await dependencies.runCLIInstall(existingIdentity ? "" : normalizedReferralCode) { [weak self] line in
                guard let self else { return }
                self.installLogLines.append(line)
                if self.installLogLines.count > 200 {
                    self.installLogLines.removeFirst(self.installLogLines.count - 200)
                }
            }
            var importError: Error?
            if !existingIdentity {
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
            }
            await finalizeInstall(
                pendingImportError: importError,
                startWithAppCredential: existingIdentity
            )
        } catch {
            stage = .failed(stage: "cliInstall", retryable: true, message: error.localizedDescription)
        }
    }

    private static func referralFailureMessage(_ reason: String) -> String {
        switch reason {
        case "expired": return "This invite has expired. Use a different invite."
        case "revoked": return "This invite is no longer available. Use a different invite."
        case "exhausted": return "This invite has already been used. Use a different invite."
        default: return "This invite is not valid. Check the code or use a different invite."
        }
    }

    private func finalizeExistingInstall(logLine: String) async {
        installLogLines = [logLine]
        guard !Task.isCancelled else { return }
        if await dependencies.appIdentityConfigured() {
            await finalizeInstall(startWithAppCredential: true)
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

    private func finalizeInstall(
        pendingImportError: Error? = nil,
        startWithAppCredential: Bool = false
    ) async {
        do {
            stage = .startingAgent
            if !startWithAppCredential {
                guard await dependencies.waitForInstalledProviderHealth() else {
                    let message = dependencies.providerStartFailure()
                        ?? ProviderLogDiagnostics.timeoutMessage(logHint: ProviderLogDiagnostics.logHint())
                    throw launchdMonitorUnavailableError(message: message)
                }
                if let pendingImportError {
                    stage = .importingProviderIdentity
                    do {
                        try await retryPendingImportAfterProviderStart(initialError: pendingImportError)
                    } catch {
                        stage = .failed(stage: "identityImport", retryable: true, message: error.localizedDescription)
                        return
                    }
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
                NSLocalizedDescriptionKey: "Provider identity was not fully imported after the background provider became healthy. Retry setup once the provider token is available.",
                NSUnderlyingErrorKey: underlying,
            ]
        )
    }

    private func deferredImportMessage(for error: Error) -> String {
        if isMissingProviderToken(error) {
            return "Provider token not in config yet; waiting for the background provider before Keychain import."
        }
        return "Provider identity import failed; waiting for the background provider before retrying Keychain import."
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
