import Foundation
import CryptoKit

// SPEC-026 v0.11 §7.2 LaunchProviderController.
//
// Owns the click-and-earn state machine: identityReady → registering →
// autotuning → downloadingModel → startingAgent → live. Sit behind the
// MALIBU_ONBOARD_V2 flag (§8). See SPEC-026 §6.1 for the user-flow
// walkthrough that the state machine implements.
//
// The bulk of this file is intentionally scaffold — codex fills in the
// concrete state-transition impl via the audit-loop pass. See
// specs/BUILD_SPEC_026_IMPL_STEP_2_APP_BUNDLE_PROMPT.md for the ordered
// contract.

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

    /// Feature-flag guard from §8: env var MALIBU_ONBOARD_V2 wins over
    /// UserDefaults `onboardingFlow == "v2"`. IMPLEMENTER wires this in
    /// via a small helper that consults both.
    static var isOnboardingV2Enabled: Bool {
        // IMPLEMENTER: env var wins per SPEC-026 §8 precedence rule.
        // Return true when either signal enables v2.
        false
    }

    // MARK: - Init

    init(coordinatorBaseURL: URL, bundledCLIPath: URL) {
        self.coordinatorBaseURL = coordinatorBaseURL
        self.bundledCLIPath = bundledCLIPath
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
        // IMPLEMENTER: fill in the ordered state transitions per
        // SPEC-026 §6.1. Persist non-secret state at
        // ~/Library/Application Support/Malibu/onboarding.json
        // per §7.5 (schema below).
        stage = .failed(stage: "launch",
                        retryable: false,
                        message: "SPEC-026 §7.2 launch flow not yet implemented; see BUILD prompt")
    }

    /// Retries from the last-failed stage. Preserves partial-download
    /// state and identity Keychain slot.
    func retry() async {
        // IMPLEMENTER: resume from `stage` if it's `.failed`, otherwise
        // no-op (or transition to `.idle` → `launch()`).
    }

    /// Sets a payout wallet POST-onboarding. Wraps the SPEC-016 §3
    /// EIP-712 signing flow. §1.1 forbids opening this UI during the
    /// onboarding launch window; success-card + dashboard "Add wallet"
    /// affordance is the correct entry point.
    func setPayoutWallet(_ address: String) async throws {
        // IMPLEMENTER: SPEC-016 §3 wallet binding — this is a plug-in
        // point, not new coordinator surface. The SPEC-016 EIP-712
        // domain + typed data are unchanged.
        throw NSError(domain: "SPEC-026", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "SPEC-016 §3 wallet-binding UI wiring not yet implemented; see BUILD prompt"])
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
    let modelDownload: ModelDownloadState?

    struct ModelDownloadState: Codable {
        let modelID: String
        let targetURL: URL
        let targetSHA256: String
        let partialBytes: Int64
    }
}
