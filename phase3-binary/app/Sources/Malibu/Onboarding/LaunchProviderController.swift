import Foundation

struct ReferralPreflightResult: Decodable, Equatable {
    let valid: Bool
    let reason: String
    let required: Bool
    let requestAccessURL: URL?

    private enum CodingKeys: String, CodingKey {
        case valid
        case reason
        case required
        case requestAccessURL = "request_access_url"
    }

    init(valid: Bool, reason: String, required: Bool = true, requestAccessURL: URL? = nil) {
        self.valid = valid
        self.reason = reason
        self.required = required
        self.requestAccessURL = Self.validRequestAccessURL(requestAccessURL?.absoluteString)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        valid = try values.decode(Bool.self, forKey: .valid)
        reason = try values.decode(String.self, forKey: .reason)
        required = try values.decode(Bool.self, forKey: .required)
        requestAccessURL = Self.validRequestAccessURL(
            try values.decodeIfPresent(String.self, forKey: .requestAccessURL)
        )
    }

    private static func validRequestAccessURL(_ raw: String?) -> URL? {
        guard let raw,
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
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
        // PROD-H6: an app-owned identity exists but its Keychain bearer is
        // gone. Offer recovery or an explicit destructive "start fresh"
        // instead of silently asking for a new invite.
        case existingIdentityMissingBearer(providerID: String)
    }

    // PROD-M3: three-valued referral policy. `.unknown` (policy discovery in
    // flight or unavailable) must NOT masquerade as `.required`: it lets the
    // authoritative registration decide and only re-gates if the server
    // rejects with `referral_required`.
    enum ReferralPolicy: Equatable {
        case required
        case optional
        case unknown
    }

    // PROD-M6: details of an identity just retired via "Start New", surfaced so
    // the UI can name what was archived, where, and offer a session-scoped
    // local-file restore without promising credential or serving recovery.
    struct RetiredIdentity: Equatable {
        let providerID: String
        let archiveURL: URL
        let retiredAt: Date
        var archivePath: String { archiveURL.path }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var installLogLines: [String] = []
    @Published private(set) var installProgressHint: String?
    @Published private(set) var installStartedAt: Date?
    @Published var referralCode = ""
    @Published private(set) var referralPolicy: ReferralPolicy = .unknown
    @Published private(set) var isDiscoveringReferralPolicy = false
    @Published private(set) var requestAccessURL: URL?
    @Published private(set) var retiredIdentity: RetiredIdentity?

    /// True only when an invite is known to be mandatory. `.unknown` and
    /// `.optional` are both non-blocking at the UI — the server enforces.
    var referralRequired: Bool { referralPolicy == .required }

    /// Show the invite field whenever an invite may still be needed, i.e. when
    /// required or when policy discovery hasn't confirmed it is optional.
    var showsReferralField: Bool { referralPolicy != .optional }

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
        // PROD-H6: detect an app-owned identity whose Keychain bearer is gone,
        // read its provider_id, and move the app-owned config aside for an
        // explicit "start fresh". Defaulted so existing callers/tests compile.
        var existingIdentityMissingBearer: @MainActor () async -> Bool = {
            await ProviderConfig.existingIdentityMissingBearer()
        }
        var readProviderID: @MainActor () -> String? = { ProviderConfig.readProviderID() }
        // PROD-M6: returns the archive directory so the UI can show where the
        // retired identity went and offer a local-file restore.
        var moveAppOwnedConfigAside: @MainActor () async throws -> URL? = {
            try ProviderConfig.startFreshMovingCLIConfigAside()
        }
        var restoreArchivedFiles: @MainActor (URL) async throws -> Void = { archive in
            try ProviderConfig.restoreArchivedIdentity(from: archive)
        }

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
                    // Policy discovery is advisory and must never hold the
                    // onboarding screen indefinitely. These URLSession bounds
                    // cover connection establishment and the complete request.
                    configuration.timeoutIntervalForRequest = LaunchProviderController.referralPolicyRequestTimeout
                    configuration.timeoutIntervalForResource = LaunchProviderController.referralPolicyResourceTimeout
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
        Self.extractReferralCode(referralCode)
    }

    var referralCodeIsValid: Bool {
        Self.isValidReferralCode(normalizedReferralCode)
    }

    // PROD-M1: the dashboard "Copy private invite" puts a canonical
    // https://…/j/<code> URL on the clipboard, so a recipient will often paste
    // the whole URL here. Accept either a canonical invite URL (take the path
    // segment after "/j/") or a bare code.
    static func extractReferralCode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme != nil else {
            return trimmed
        }
        guard components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              !components.path.hasSuffix("//") else {
            return trimmed
        }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count >= 2, path[path.count - 2] == "j" else {
            return trimmed
        }
        return String(path[path.count - 1])
    }

    static let referralPolicyRequestTimeout: TimeInterval = 6
    static let referralPolicyResourceTimeout: TimeInterval = 8

    static func isValidReferralCode(_ raw: String) -> Bool {
        raw.range(
            of: #"^MAL1-[SP]-[A-Za-z0-9_]{1,32}-[A-Za-z0-9_]{1,32}-[A-Z2-7]{26}$"#,
            options: .regularExpression
        ) != nil
    }

    func launch() async {
        if await dependencies.existingIdentityMissingBearer() {
            stage = .existingIdentityMissingBearer(providerID: dependencies.readProviderID() ?? "")
            return
        }
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
            referralPolicy = .optional
            requestAccessURL = nil
            return
        }
        isDiscoveringReferralPolicy = true
        defer { isDiscoveringReferralPolicy = false }
        do {
            let result = try await dependencies.validateReferralCode("")
            referralPolicy = result.required ? .required : .optional
            requestAccessURL = result.requestAccessURL
        } catch {
            // PROD-M3: policy discovery failed → UNKNOWN, not required. Let the
            // authoritative registration decide; B8 re-gates only if the server
            // rejects with referral_required. Mirrors the installer's advisory
            // treatment of /v1/referrals/validate.
            referralPolicy = .unknown
            requestAccessURL = nil
        }
    }

    func retry() async {
        guard case .failed(_, let retryable, _) = stage, retryable else { return }
        await launch()
    }

    // PROD-H6: if an app-owned identity exists without its Keychain bearer,
    // claim the dedicated recovery/start-fresh stage instead of falling through
    // to the invite flow. Returns true when it took over the stage.
    @discardableResult
    func evaluateExistingIdentityState() async -> Bool {
        guard case .idle = stage else { return false }
        guard await dependencies.existingIdentityMissingBearer() else { return false }
        stage = .existingIdentityMissingBearer(providerID: dependencies.readProviderID() ?? "")
        return true
    }

    // PROD-H6 (b): explicit destructive escape hatch. Move the app-owned
    // config aside so a genuinely fresh provider can be created, then return to
    // the normal invite flow. PROD-M6: capture the archive location and provider
    // id so the UI can name what was retired and offer a local-file restore —
    // the caller is expected to have confirmed the destructive action first.
    func startAsNewProvider() async {
        let providerID = dependencies.readProviderID() ?? ""
        do {
            let archive = try await dependencies.moveAppOwnedConfigAside()
            if let archive {
                retiredIdentity = RetiredIdentity(
                    providerID: providerID,
                    archiveURL: archive,
                    retiredAt: Date()
                )
            }
        } catch {
            stage = .failed(
                stage: "startFresh",
                retryable: true,
                message: "Could not move the existing provider aside: \(error.localizedDescription)"
            )
            return
        }
        referralCode = ""
        stage = .idle
        await refreshReferralPolicy()
    }

    // PROD-M6: restore local files from a just-performed "Start New" while the
    // archive still exists. This cannot recreate a missing Keychain bearer,
    // restore coordinator authority, or resume serving. Refuses (surfaces the
    // error) if a replacement identity was already created over the files.
    func restoreRetiredProviderFiles() async {
        guard let retired = retiredIdentity else { return }
        do {
            try await dependencies.restoreArchivedFiles(retired.archiveURL)
        } catch {
            stage = .failed(
                stage: "startFresh",
                retryable: true,
                message: "Could not restore the archived provider files: \(error.localizedDescription)"
            )
            return
        }
        retiredIdentity = nil
        stage = .idle
        // Re-detect the restored (missing-bearer) identity so the user lands
        // back on the recover/start-new choice rather than a blank invite.
        if await evaluateExistingIdentityState() { return }
        await refreshReferralPolicy()
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
        // PROD-M1: validate the invite BEFORE any expensive install work
        // whenever the policy is not known-optional — i.e. required OR still
        // unknown (policy discovery failed). This stops a user from spending
        // 10–30 min downloading and tuning only to discover at the mint that an
        // invite was mandatory. An authoritative `required` + missing/invalid
        // code re-gates to the EDITABLE invite step now with reason-specific
        // copy; an unavailable pre-check degrades to a warning and lets the
        // install-log rejection re-gate as before (mirrors install.sh's
        // advisory /v1/referrals/validate treatment).
        if !existingIdentity && referralPolicy != .optional {
            do {
                let result = try await dependencies.validateReferralCode(normalizedReferralCode)
                requestAccessURL = result.requestAccessURL
                if result.required {
                    referralPolicy = .required
                }
                if result.required && !result.valid {
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
            // PROD-M2: if the authoritative registration rejected the invite,
            // route back to the referral step (required) with the specific
            // reason rather than a generic install failure.
            if let reason = referralRejectionFromInstallLog() {
                referralPolicy = .required
                stage = .failed(stage: "referral", retryable: true, message: Self.referralFailureMessage(reason))
                return
            }
            stage = .failed(stage: "cliInstall", retryable: true, message: error.localizedDescription)
        }
    }

    // PROD-M2: install.sh surfaces a referral rejection from the authoritative
    // mint as `referral_<token>` (token ∈ missing|invalid|expired|revoked|
    // exhausted|required), both as a MACPROVIDER_REFERRAL_REJECTED marker and in
    // the fatal message. Scan the captured install log for it.
    private func referralRejectionFromInstallLog() -> String? {
        let pattern = #"referral_(missing|invalid|expired|revoked|exhausted|required)"#
        for line in installLogLines.reversed() {
            if let range = line.range(of: pattern, options: .regularExpression) {
                let token = String(line[range].dropFirst("referral_".count))
                // PROD-M4: the server's authoritative `referral_required`
                // rejection means an invite is mandatory. Normalize it to the
                // `missing` case so the failure copy and mandatory-invite routing
                // match the other required-invite rejections.
                return token == "required" ? "missing" : token
            }
        }
        return nil
    }

    private static func referralFailureMessage(_ reason: String) -> String {
        switch reason {
        // PROD-M1: reason-specific copy that matches the installer's own wording
        // ("use a different invite") so the same rejection reads identically
        // whether it surfaces at preflight or from the install log. A code that
        // exists but cannot be used routes the user to swap it.
        case "expired": return "This invite has expired. Use a different invite."
        case "revoked": return "This invite is no longer available. Use a different invite."
        case "exhausted": return "All spots on this invite are taken. Use a different invite."
        // PROD-M4: `required` is normalized to `missing` upstream, but map it
        // here too so any direct preflight `required` reason renders the same
        // mandatory-invite copy rather than the generic fallback. There is no
        // code to swap, so the copy asks for one instead.
        case "missing", "required": return "An invite is required. Enter an invite code or link."
        default: return "This invite is not valid. Use a different invite."
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
