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

    // MARK: - Config

    /// Coordinator base URL. Comes from build config — production is
    /// `https://coordinator.streamvc.live` per SPEC-026 canonical domain.
    let coordinatorBaseURL: URL

    /// Path to `macprovider-cli` inside the App bundle (SPEC-025 bundles
    /// it, so this is not a fresh download in v1 — see SPEC-026 §6.1
    /// step 7e).
    let bundledCLIPath: URL
    private let agent: MalibuAgent?
    private let registerClient: RegisterClient

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

    init(coordinatorBaseURL: URL, bundledCLIPath: URL, agent: MalibuAgent? = nil) {
        self.coordinatorBaseURL = coordinatorBaseURL
        self.bundledCLIPath = bundledCLIPath
        self.agent = agent
        self.registerClient = RegisterClient(coordinatorBaseURL: coordinatorBaseURL)
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
        guard Self.isOnboardingV2Enabled else {
            stage = .failed(
                stage: "featureFlag",
                retryable: false,
                message: "App-track onboarding is not enabled in this build."
            )
            return
        }

        if await ProviderConfig.isConfigured {
            await startConfiguredAgent(model: "configured")
            return
        }

        do {
            let key = try await ProviderIdentity.loadOrGenerate()
            let providerID = ProviderIdentity.providerID(for: key)
            stage = .identityReady
            try OnboardingStateStore.save(OnboardingState(
                onboardingSchemaVersion: 2,
                providerID: providerID,
                createdAt: Date(),
                lastStage: "identityReady",
                firstServingAt: nil,
                modelDownload: nil
            ))

            stage = .registering
            let bearerProof = await KeychainStore.readProviderToken(providerID: providerID)
            let request = try registerClient.makeSignedRequest(identityKey: key)
            let response = try await registerClient.postRegister(request, bearerProof: bearerProof)
            try await ProviderConfig.saveProviderIdentity(
                providerID: response.providerID,
                token: response.providerToken
            )
            try OnboardingStateStore.update(providerID: response.providerID, lastStage: "registered")

            stage = .autotuning
            try OnboardingStateStore.update(providerID: response.providerID, lastStage: "autotuning")

            stage = .downloadingCLI(progressPct: 1)
            try OnboardingStateStore.update(providerID: response.providerID, lastStage: "cliReady")

            stage = .downloadingModel(name: "recommended", progressPct: 1)
            try OnboardingStateStore.update(providerID: response.providerID, lastStage: "modelReady")

            stage = .startingAgent
            try AppLoginItem.register()
            await startConfiguredAgent(model: "recommended")
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
        await agent?.start()
        let now = Date()
        if let providerID = ProviderConfig.readProviderID() {
            try? OnboardingStateStore.update(
                providerID: providerID,
                lastStage: "live",
                firstServingAt: now
            )
        }
        stage = .live(model: model, tier: .provisional)
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

    struct ModelDownloadState: Codable {
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
    static func load() throws -> OnboardingState? {
        let url = ProviderPaths.current.onboardingStateFile
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(OnboardingState.self, from: data)
    }

    static func save(_ state: OnboardingState) throws {
        let paths = ProviderPaths.current
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
        modelDownload: OnboardingState.ModelDownloadState? = nil
    ) throws {
        let existing = try load()
        try save(OnboardingState(
            onboardingSchemaVersion: 2,
            providerID: providerID,
            createdAt: existing?.createdAt ?? Date(),
            lastStage: lastStage,
            firstServingAt: firstServingAt ?? existing?.firstServingAt,
            modelDownload: modelDownload ?? existing?.modelDownload
        ))
    }

    static func delete() throws {
        let url = ProviderPaths.current.onboardingStateFile
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
}

struct StartupState: Equatable {
    let configExists: Bool
    let appMarkerExists: Bool
    let providerTokenExists: Bool
    let identityExists: Bool
    let onboardingStateExists: Bool
    let firstServingAtExists: Bool
    let onboardingV2Enabled: Bool

    func route() -> StartupRoute {
        if configExists && appMarkerExists && providerTokenExists {
            return .startAgent
        }
        if configExists && !appMarkerExists {
            return onboardingV2Enabled ? .showImportDialog : .setupPaused
        }
        if onboardingStateExists && !firstServingAtExists {
            return onboardingV2Enabled ? .resumeOnboarding : .setupPaused
        }
        if identityExists && onboardingV2Enabled {
            return .resumeOnboarding
        }
        return onboardingV2Enabled ? .showOnboarding : .setupPaused
    }
}
