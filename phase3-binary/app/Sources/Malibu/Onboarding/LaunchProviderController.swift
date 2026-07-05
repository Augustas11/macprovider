import Foundation
import CryptoKit

// SPEC-026 v0.11 §7.2 LaunchProviderController.
//
// Owns the click-and-earn state machine: identityReady → registering →
// autotuning → downloadingModel → startingAgent → live. Sit behind the
// MALIBU_ONBOARD_V2 flag (§8). See SPEC-026 §6.1 for the user-flow
// walkthrough that the state machine implements.
//
@MainActor
final class LaunchProviderController: ObservableObject {

    enum TrustTier: String, Equatable, Codable {
        case provisional
        case trusted
    }

    enum Stage: Equatable {
        case idle
        case identityReady
        case registering
        case autotuning
        case downloadingCLI(progressPct: Double)     // no-op in v1: SPEC-025 bundles the CLI
        case downloadingModel(name: String, progressPct: Double)
        case startingAgent
        case authenticating
        case live(model: String, tier: TrustTier)
        case failed(stage: String, retryable: Bool, message: String)
    }

    // MARK: - Published state (drives the SwiftUI onboarding view)

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var currentEarningsEstimate: EarningsEstimateRange?

    // MARK: - Config

    /// Coordinator base URL. Comes from build config — production is
    /// `https://coordinator.streamvc.live` per SPEC-026 canonical domain.
    let coordinatorBaseURL: URL

    /// Path to `macprovider-cli` inside the App bundle (SPEC-025 bundles
    /// it, so this is not a fresh download in v1 — see SPEC-026 §6.1
    /// step 7e).
    let bundledCLIPath: URL
    private let registerClient: RegisterClient
    private let dependencies: Dependencies

    struct ModelDownloadPlan: Equatable {
        let modelName: String
        let state: OnboardingState.ModelDownloadState?
        let earningsEstimate: EarningsEstimateRange?

        static let recommended = ModelDownloadPlan(modelName: "recommended", state: nil, earningsEstimate: nil)
    }

    struct Dependencies {
        var isConfigured: () async -> Bool
        var loadState: () throws -> OnboardingState?
        var loadOrGenerateIdentity: () async throws -> Curve25519.Signing.PrivateKey
        var loadExistingIdentity: () async throws -> Curve25519.Signing.PrivateKey
        var providerID: (Curve25519.Signing.PrivateKey) -> String
        var currentProviderToken: (String) async -> String?
        var registerProvider: (Curve25519.Signing.PrivateKey, String?) async throws -> RegisterResponse
        var saveProviderIdentity: (String, String) async throws -> Void
        var repairMarkerlessAppConfig: (String) async throws -> Void
        var saveState: (OnboardingState) throws -> Void
        var updateState: (String, String, Date?, OnboardingState.ModelDownloadState?) throws -> Void
        var markLinkState: (ProviderConfig.LinkState) throws -> Void
        var runAutotune: (String) async throws -> ModelDownloadPlan
        var ensureCLIReady: () throws -> Void
        var downloadModel: (ModelDownloadPlan) async throws -> OnboardingState.ModelDownloadState?
        var registerLoginItem: @MainActor () async throws -> Void
        var startAgent: @MainActor () async -> Void
        var waitForFirstServing: @MainActor () async throws -> Date
        var readProviderID: () -> String?

        static func live(registerClient: RegisterClient, bundledCLIPath: URL, agent: MalibuAgent?) -> Dependencies {
            Dependencies(
                isConfigured: { await ProviderConfig.isConfigured },
                loadState: { try OnboardingStateStore.load() },
                loadOrGenerateIdentity: { try await ProviderIdentity.loadOrGenerate() },
                loadExistingIdentity: { try await ProviderIdentity.loadExisting() },
                providerID: { ProviderIdentity.providerID(for: $0) },
                currentProviderToken: { providerID in await KeychainStore.readProviderToken(providerID: providerID) },
                registerProvider: { key, bearerProof in
                    let request = try registerClient.makeSignedRequest(identityKey: key)
                    return try await registerClient.postRegister(request, bearerProof: bearerProof)
                },
                saveProviderIdentity: { providerID, token in
                    try await ProviderConfig.saveProviderIdentity(providerID: providerID, token: token)
                },
                repairMarkerlessAppConfig: { providerID in
                    try await ProviderConfig.repairMarkerlessAppOwnedConfig(providerID: providerID)
                },
                saveState: { try OnboardingStateStore.save($0) },
                updateState: { providerID, lastStage, firstServingAt, modelDownload in
                    try OnboardingStateStore.update(
                        providerID: providerID,
                        lastStage: lastStage,
                        firstServingAt: firstServingAt,
                        modelDownload: modelDownload
                    )
                },
                markLinkState: { state in try ProviderConfig.writeLinkState(state) },
                runAutotune: { _ in
                    (try? await AutotuneRecommendationRunner.run(cliURL: bundledCLIPath)) ?? .recommended
                },
                ensureCLIReady: {
                    guard FileManager.default.isExecutableFile(atPath: bundledCLIPath.path) else {
                        throw POSIXError(.ENOENT)
                    }
                },
                downloadModel: { plan in plan.state },
                registerLoginItem: { try AppLoginItem.register() },
                startAgent: { await agent?.start() },
                waitForFirstServing: {
                    guard let agent else { return Date() }
                    for _ in 0..<60 {
                        switch agent.snapshot.state {
                        case .serving:
                            return Date()
                        case .error:
                            throw NSError(
                                domain: "Malibu.LaunchProviderController",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: agent.snapshot.lastError ?? "Provider failed to start."]
                            )
                        default:
                            try await Task.sleep(nanoseconds: 500_000_000)
                        }
                    }
                    throw NSError(
                        domain: "Malibu.LaunchProviderController",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the first serving frame."]
                    )
                },
                readProviderID: { ProviderConfig.readProviderID() }
            )
        }
    }

    /// Feature-flag guard from §8: env var MALIBU_ONBOARD_V2 wins over
    /// UserDefaults `onboardingFlow == "v2"`.
    static var isOnboardingV2Enabled: Bool {
        isOnboardingV2Enabled(
            environment: ProcessInfo.processInfo.environment,
            userDefaults: .standard
        )
    }

    static func isOnboardingV2Enabled(
        environment: [String: String],
        userDefaults: UserDefaults
    ) -> Bool {
        if let value = environment["MALIBU_ONBOARD_V2"]?.lowercased() {
            if ["1", "true", "yes", "on", "v2"].contains(value) { return true }
            if ["0", "false", "no", "off", "v1"].contains(value) { return false }
        }
        return userDefaults.string(forKey: "onboardingFlow") == "v2"
    }

    // MARK: - Init

    init(
        coordinatorBaseURL: URL,
        bundledCLIPath: URL,
        agent: MalibuAgent? = nil,
        dependencies: Dependencies? = nil
    ) {
        self.coordinatorBaseURL = coordinatorBaseURL
        self.bundledCLIPath = bundledCLIPath
        let registerClient = RegisterClient(coordinatorBaseURL: coordinatorBaseURL)
        self.registerClient = registerClient
        self.dependencies = dependencies ?? .live(
            registerClient: registerClient,
            bundledCLIPath: bundledCLIPath,
            agent: agent
        )
    }

    // MARK: - Public API

    /// Fire the state machine. Safe to re-invoke; each call resumes from
    /// the persisted `onboardingSchemaVersion == 2` state if present, else
    /// starts from `.idle`.
    ///
    /// State transitions per SPEC-026 §6.1 step 7 sub-steps a-j:
    ///   a. Generate Ed25519 identity keypair → Keychain
    ///   b. POST /v1/providers/register → receive provider_token
    ///   c. Run macprovider-cli autotune --recommend --json locally
    ///   d. Persist provider_id + provider_token + onboardingSchemaVersion=2
    ///   e. Download macprovider-cli if not bundled (no-op in v1)
    ///   f. Download model weights per autotune output (resumable)
    ///   g. Register SMAppService login item
    ///   h. Start MalibuAgent (existing code) which spawns CLI child
    ///   i. Wait for first .serving control-socket frame
    ///   j. Show success card (owned by the SwiftUI view; controller
    ///      transitions to .live)
    func launch() async {
        let existingState = try? dependencies.loadState()
        if await dependencies.isConfigured() {
            if let existing = existingState,
               existing.onboardingSchemaVersion == 2,
               existing.firstServingAt == nil {
                await resumePartialOnboarding(existing)
            } else {
                await startConfiguredAgent(model: "configured")
            }
            return
        }

        if let existing = existingState,
           existing.onboardingSchemaVersion == 2,
           existing.firstServingAt == nil {
            await resumePartialOnboarding(existing)
            return
        }

        guard Self.isOnboardingV2Enabled else {
            stage = .failed(
                stage: "featureFlag",
                retryable: false,
                message: "App-track onboarding is not enabled in this build."
            )
            return
        }

        do {
            let key = try await dependencies.loadOrGenerateIdentity()
            let providerID = dependencies.providerID(key)
            stage = .identityReady
            try dependencies.saveState(OnboardingState(
                onboardingSchemaVersion: 2,
                providerID: providerID,
                createdAt: Date(),
                lastStage: "identityReady",
                firstServingAt: nil,
                modelDownload: nil
            ))

            stage = .registering
            let bearerProof = await dependencies.currentProviderToken(providerID)
            let response = try await dependencies.registerProvider(key, bearerProof)
            try await dependencies.saveProviderIdentity(response.providerID, response.providerToken)
            try dependencies.updateState(response.providerID, "registered", nil, nil)

            try await finishLaunch(providerID: response.providerID, from: .autotune, plan: nil)
        } catch {
            stage = .failed(stage: stageName(stage), retryable: true, message: error.localizedDescription)
        }
    }

    /// Retries from the last-failed stage. Preserves partial-download
    /// state and identity Keychain slot.
    func retry() async {
        guard case .failed(_, let retryable, _) = stage, retryable else { return }
        await launch()
    }

    /// Sets a payout wallet POST-onboarding. Wraps the SPEC-016 §3
    /// EIP-712 signing flow. §1.1 forbids opening this UI during the
    /// onboarding launch window; success-card + dashboard "Add wallet"
    /// affordance is the correct entry point.
    func setPayoutWallet(_ address: String) async throws {
        throw NSError(domain: "SPEC-026", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "Wallet binding is a guarded SPEC-016/SPEC-027 follow-up route."])
    }

    private func startConfiguredAgent(model: String) async {
        await dependencies.startAgent()
        stage = .live(model: model, tier: .provisional)
    }

    private enum ResumePoint {
        case autotune
        case cliReady
        case downloadingModel
        case modelReady
    }

    private func resumePartialOnboarding(_ existing: OnboardingState) async {
        do {
            let point: ResumePoint
            switch existing.lastStage {
            case "identityReady", "registering":
                try await resumeRegistration(existing)
                return
            case "registered", "autotuning":
                point = .autotune
            case "cliReady":
                point = .cliReady
            case "downloadingModel":
                point = .downloadingModel
            case "modelReady", "startingAgent":
                point = .modelReady
            default:
                point = .autotune
            }
            let configurationReady = try await recoverResumeConfigurationIfNeeded(existing)
            if !configurationReady {
                try await resumeRegistration(existing)
                return
            }
            let plan = existing.modelDownload.map {
                ModelDownloadPlan(modelName: $0.modelID, state: $0, earningsEstimate: nil)
            }
            try await finishLaunch(providerID: existing.providerID, from: point, plan: plan)
        } catch {
            stage = .failed(stage: stageName(stage), retryable: true, message: error.localizedDescription)
        }
    }

    private func recoverResumeConfigurationIfNeeded(_ existing: OnboardingState) async throws -> Bool {
        if await dependencies.isConfigured() { return true }
        guard let configProviderID = dependencies.readProviderID() else { return false }
        guard configProviderID == existing.providerID else {
            throw NSError(
                domain: "SPEC-026",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Stored provider config does not match the onboarding state."]
            )
        }

        let key = try await dependencies.loadExistingIdentity()
        guard dependencies.providerID(key) == existing.providerID else {
            throw NSError(
                domain: "SPEC-026",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Stored provider identity does not match the onboarding state."]
            )
        }
        guard await dependencies.currentProviderToken(existing.providerID) != nil else {
            throw ProviderConfig.SaveError.missingProviderToken
        }

        try await dependencies.repairMarkerlessAppConfig(existing.providerID)
        guard await dependencies.isConfigured() else {
            throw ProviderConfig.SaveError.savedIdentityNotConfigured
        }
        return true
    }

    private func resumeRegistration(_ existing: OnboardingState) async throws {
        let key = try await dependencies.loadOrGenerateIdentity()
        let providerID = dependencies.providerID(key)
        guard providerID == existing.providerID else {
            throw NSError(
                domain: "SPEC-026",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Stored provider identity does not match the onboarding state."]
            )
        }

        stage = .registering
        let bearerProof = await dependencies.currentProviderToken(providerID)
        let response = try await dependencies.registerProvider(key, bearerProof)
        try await dependencies.saveProviderIdentity(response.providerID, response.providerToken)
        try dependencies.updateState(response.providerID, "registered", nil, nil)
        try await finishLaunch(providerID: response.providerID, from: .autotune, plan: existing.modelDownload.map {
            ModelDownloadPlan(modelName: $0.modelID, state: $0, earningsEstimate: nil)
        })
    }

    private func finishLaunch(
        providerID: String,
        from resumePoint: ResumePoint,
        plan resumePlan: ModelDownloadPlan?
    ) async throws {
        var plan = resumePlan ?? .recommended

        if resumePoint == .autotune {
            stage = .autotuning
            try dependencies.updateState(providerID, "autotuning", nil, nil)
            plan = try await dependencies.runAutotune(providerID)

            stage = .downloadingCLI(progressPct: 1)
            try dependencies.ensureCLIReady()
            try dependencies.updateState(providerID, "cliReady", nil, nil)
        }

        if resumePoint == .cliReady || resumePoint == .downloadingModel || resumePoint == .autotune {
            let progress = plan.state.map { $0.partialBytes > 0 ? 0.5 : 0 } ?? 0
            stage = .downloadingModel(name: plan.modelName, progressPct: progress)
            currentEarningsEstimate = plan.earningsEstimate
            try dependencies.updateState(providerID, "downloadingModel", nil, plan.state)
            let completedDownload = try await dependencies.downloadModel(plan)
            stage = .downloadingModel(name: plan.modelName, progressPct: 1)
            try dependencies.updateState(providerID, "modelReady", nil, completedDownload)
        }

        stage = .startingAgent
        try dependencies.updateState(providerID, "startingAgent", nil, nil)
        try dependencies.markLinkState(.pendingLink)
        try await dependencies.registerLoginItem()
        try dependencies.markLinkState(.linked)
        await dependencies.startAgent()

        stage = .authenticating
        let firstServingAt = try await dependencies.waitForFirstServing()
        try dependencies.updateState(providerID, "live", firstServingAt, nil)
        stage = .live(model: plan.modelName, tier: .provisional)
    }

    private func stageName(_ stage: Stage) -> String {
        switch stage {
        case .idle: return "idle"
        case .identityReady: return "identityReady"
        case .registering: return "registering"
        case .autotuning: return "autotuning"
        case .downloadingCLI: return "downloadingCLI"
        case .downloadingModel: return "downloadingModel"
        case .startingAgent: return "startingAgent"
        case .authenticating: return "authenticating"
        case .live: return "live"
        case let .failed(stage, _, _): return stage
        }
    }
}

// MARK: - Persistent onboarding state (SPEC-026 §7.5)

/// Persisted at `~/Library/Application Support/Malibu/onboarding.json`
/// with file mode 0600. Never contains the private key or bearer token
/// — those live in Keychain.
struct OnboardingState: Codable {
    /// SPEC-026 §7.5 + §8 migration disambiguator. Fresh v0.11 installs
    /// write 2; v1 SPEC-025 installs have no such file.
    let onboardingSchemaVersion: Int
    let providerID: String
    let createdAt: Date
    let lastStage: String
    let firstServingAt: Date?
    let modelDownload: ModelDownloadState?

    enum CodingKeys: String, CodingKey {
        case onboardingSchemaVersion = "onboarding_schema_version"
        case providerID = "provider_id"
        case createdAt = "created_at"
        case lastStage = "last_stage"
        case firstServingAt = "first_serving_at"
        case modelDownload = "model_download"
    }

    struct ModelDownloadState: Codable, Equatable {
        let modelID: String
        let targetURL: URL
        let targetSHA256: String
        let partialBytes: Int64

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case targetURL = "target_url"
            case targetSHA256 = "target_sha256"
            case partialBytes = "partial_bytes"
        }
    }
}

enum OnboardingStateStore {
    static func load(paths: ProviderPaths = .current) throws -> OnboardingState? {
        let url = paths.onboardingStateFile
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(OnboardingState.self, from: data)
    }

    static func save(_ state: OnboardingState, paths: ProviderPaths = .current) throws {
        try paths.ensureDirectories()
        let data = try encoder.encode(state)
        try data.write(to: paths.onboardingStateFile, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.onboardingStateFile.path
        )
    }

    static func update(
        providerID: String,
        lastStage: String,
        firstServingAt: Date? = nil,
        modelDownload: OnboardingState.ModelDownloadState? = nil,
        paths: ProviderPaths = .current
    ) throws {
        let existing = try load(paths: paths)
        try save(OnboardingState(
            onboardingSchemaVersion: 2,
            providerID: providerID,
            createdAt: existing?.createdAt ?? Date(),
            lastStage: lastStage,
            firstServingAt: firstServingAt ?? existing?.firstServingAt,
            modelDownload: modelDownload ?? existing?.modelDownload
        ), paths: paths)
    }

    static func delete(paths: ProviderPaths = .current) throws {
        let url = paths.onboardingStateFile
        do { try FileManager.default.removeItem(at: url) }
        catch {
            let ns = error as NSError
            if !(ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError) {
                throw error
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum StartupRoute: Equatable {
    case startAgent
    case showOnboarding
    case showImportDialog
    case setupPaused
    case resumeOnboarding
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
    let providerTokenExists: Bool
    let linkState: ProviderConfig.LinkState?
    let identityExists: Bool
    let onboardingStateExists: Bool
    let firstServingAtExists: Bool
    let onboardingV2Enabled: Bool

    @MainActor
    static func detect(paths: ProviderPaths = .current) async -> StartupState {
        let fm = FileManager.default
        try? await ProviderConfig.recoverPendingImportIfNeeded(paths: paths)
        let configExists = fm.fileExists(atPath: paths.configFile.path)
        let markerExists = fm.fileExists(atPath: paths.appMarkerFile.path)
        let providerID = ProviderConfig.readProviderID(paths: paths)
        let tokenExists: Bool
        if let providerID {
            tokenExists = await KeychainStore.readProviderToken(providerID: providerID) != nil
        } else {
            tokenExists = false
        }
        let identityExists = await ProviderIdentity.isReady()
        let onboarding = try? OnboardingStateStore.load(paths: paths)
        return StartupState(
            configExists: configExists,
            appMarkerExists: markerExists,
            providerTokenExists: tokenExists,
            linkState: ProviderConfig.readLinkState(paths: paths),
            identityExists: identityExists,
            onboardingStateExists: onboarding != nil,
            firstServingAtExists: onboarding?.firstServingAt != nil,
            onboardingV2Enabled: LaunchProviderController.isOnboardingV2Enabled
        )
    }

    func route() -> StartupRoute {
        if onboardingStateExists && !firstServingAtExists {
            return .resumeOnboarding
        }
        if configExists && appMarkerExists && providerTokenExists && linkState == .pendingLink {
            return .resumeOnboarding
        }
        if configExists && appMarkerExists && providerTokenExists {
            return .startAgent
        }
        if configExists && !appMarkerExists {
            return .showImportDialog
        }
        if identityExists && onboardingV2Enabled {
            return .resumeOnboarding
        }
        return onboardingV2Enabled ? .showOnboarding : .setupPaused
    }

    static func applyMigrationDecision(
        _ decision: MigrationDecision,
        paths: ProviderPaths = .current,
        now: Date = Date(),
        onboardingV2Enabled: Bool? = nil
    ) async throws -> MigrationResult {
        switch decision {
        case .importExisting:
            try await ProviderConfig.importExistingCLIConfig(paths: paths)
            return MigrationResult(route: .startAgent, backupPath: nil)
        case .startFresh:
            let backup = try ProviderConfig.startFreshMovingCLIConfigAside(now: now, paths: paths)
            let effectiveOnboardingV2Enabled: Bool
            if let onboardingV2Enabled {
                effectiveOnboardingV2Enabled = onboardingV2Enabled
            } else {
                effectiveOnboardingV2Enabled = await MainActor.run {
                    LaunchProviderController.isOnboardingV2Enabled
                }
            }
            let fresh = StartupState(
                configExists: false,
                appMarkerExists: false,
                providerTokenExists: false,
                linkState: nil,
                identityExists: false,
                onboardingStateExists: false,
                firstServingAtExists: false,
                onboardingV2Enabled: effectiveOnboardingV2Enabled
            )
            return MigrationResult(route: fresh.route(), backupPath: backup?.path)
        case .cancel:
            return MigrationResult(route: .quit, backupPath: nil)
        }
    }
}
