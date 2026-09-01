import Foundation

// AUDIT R1 ARCHITECT A1 / A5 fix.
//
// AgentSnapshot is now a pure domain type — no localized/formatted strings.
// - Earnings/metrics are Optional so "not reported yet" is distinct from "0".
//   Supported legacy CLI peers returned an all-zero tuple; rendering that as
//   authoritative "$0.00" would mask missing telemetry as actual earnings.
// - View strings (menu-bar label, status line, earnings line) live in
//   AgentSnapshotPresenter so future locale/currency work touches one place.

struct AgentSnapshot: Equatable {
    enum State: String { case idle, starting, serving, paused, reconnecting, error }
    enum TrustTier: String, Codable {
        case provisional
        case trusted

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self).lowercased()
            self = raw == "trusted" ? .trusted : .provisional
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
    var state: State
    var currentModelID: String?
    var currentModelIDFromStatus: Bool = false
    var currentModelLoaded: Bool?
    var modelHash: String?
    var modelHashAlgorithm: String?
    var weightsManifestSHA256: String?
    var weightsManifestAlgorithm: String?
    var earningsUsdcToday: Double?
    var malibuAccruedToday: Double?
    var unpaidLedgerBacklogUSDC: Double?
    var unpaidLedgerBacklogMALIBU: Double?
    var walletBound: Bool
    var trustTier: TrustTier
    var uptimeSec: Int?
    var requestsServedToday: Int?
    var requestsServedAllTime: Int?
    var requestsPerMinute: Double?
    var inputTokensToday: Int64?
    var outputTokensToday: Int64?
    var inputTokensAllTime: Int64?
    var outputTokensAllTime: Int64?
    var earningsUsdcWeek: Double?
    var earningsUsdcPending: Double?
    var earningsUsdcLifetime: Double?
    var malibuAccruedAllTime: Double?
    var malibuWithdrawable: Double?
    var malibuHeld: Double?
    var malibuHoldReasons: [String]
    var malibuDailyCap: Double?
    var malibuWalletDailyCap: Double?
    var malibuRewardEligibility: MalibuRewardEligibility?
    /// Last-hour idle-prewarm event/skip counts from the provider earnings
    /// endpoint. Gated by `providerEarningsFresh`, same as the other fields
    /// sourced from that projection.
    var idlePrewarmSummary: ProviderIdlePrewarmSummary = .empty
    /// Freshness for the provider earnings endpoint.
    var providerEarningsFresh: Bool
    /// Reward-specific freshness. It is separate so a partial earnings frame
    /// cannot authorize held/withdrawable/trust copy.
    var malibuProjectionFresh: Bool
    var gpuUtilizationPct: Double?
    var gpuTemperatureC: Double?
    var latencyP50Ms: Int?
    var latencyP99Ms: Int?
    var queueDepth: Int?
    var uptime7dPct: Double?
    var declinedRequests: Int?
    var restartCount: Int?
    var weightsPath: String?
    var trustCriteriaMet: Int?
    var trustCriteriaRequired: Int?
    /// Satisfied economic/additional trust-criterion IDs (SPEC-026 §5.2),
    /// plus supporting counters. Coordinator-served, threaded through the CLI
    /// earnings frame. Display-only — used to name which Trusted criteria are
    /// done vs pending.
    var economicCriteria: [String] = []
    var additionalCriteria: [String] = []
    var verifiedReceiptCount: Int? = nil
    var appAttested: Bool? = nil
    /// True when reward/wallet telemetry was reached but FAILED (outage), as
    /// distinct from a benign first-run absence. Keeps a genuine outage from
    /// being softened into the calm "warming up" first-run status.
    var rewardTelemetryUnavailable: Bool = false
    /// True when the earnings frame actually carried granular trust-criteria
    /// fields. False for legacy frames, where the app falls back to the raw
    /// trust_criteria_met/required counters instead of an empty-array "0 of 2".
    var hasGranularTrustCriteria: Bool = false
    var thermalState: MalibuThermalState?
    var lastError: String?

    var cliVersion: String?
    var compatibilitySetID: String?
    var compatibilitySetSHA256: String?
    var localStatusContractVersion: Int?
    var localStatusMinimumReaderVersion: Int?
    var localStatusContractCompatible: Bool?
    var localStatusLifecycleOwner: String?
    var localStatusCapabilities: Set<String>
    var localProviderID: String?
    var statusObservationID: String?
    var statusObservedAt: Date?
    var statusObservationValidForMS: Int?
    var statusObservationFresh: Bool?
    var serviceInstanceID: String?
    var servicePID: Int?
    var serviceBootSession: String?
    var serviceStartedAt: Date?
    var serviceRole: String?
    var lifecycleRecordState: String?
    var lifecycleSequence: Int64?
    var lifecycleTransitionID: String?
    var lifecycleTransitionAt: Date?
    var lifecycleState: String?
    var lifecycleReason: String?
    var lifecycleAuthority: String?
    var lifecycleWriter: String?
    var lifecycleOperationID: String?
    var lifecycleOperatorPaused: Bool?
    var lifecycleLastRestart: ProviderLifecycleEventSnapshot?
    var lifecycleLastRejection: ProviderLifecycleEventSnapshot?
    var lifecycleLastUpdate: ProviderLifecycleEventSnapshot?
    var lifecycleLastWatchdog: ProviderLifecycleEventSnapshot?
    var lifecycleLeaseState: String?
    var lifecycleLeaseKind: String?
    var lifecycleLeaseOperationID: String?
    var lifecycleLeaseExpiresWallMS: Int64?
    var credentialSource: String?
    var credentialState: String?
    var credentialRestartSafe: Bool?
    var credentialMigrationPending: Bool?
    var credentialRecoveryAction: String?
    var credentialStatusObservedAt: Date?
    var credentialStatusFromDiagnostic: Bool
    var credentialRepairInProgress: Bool
    var credentialRepairLastError: String?
    var admissionIdentitySource: String?
    var admissionIdentityState: String?
    var admissionIdentityPublicKeySHA256: String?
    var admissionIdentityPendingPublicKeySHA256: String? = nil
    var admissionIdentityPreviousPublicKeySHA256: String? = nil
    var admissionIdentityPreviousValidUntil: Date? = nil
    var admissionIdentityCoordinatorGeneration: Int? = nil
    var admissionIdentityCoordinatorPublicKeySHA256: String? = nil
    var admissionIdentityCoordinatorKeyRole: String? = nil
    var admissionIdentityTransitionError: String? = nil
    var admissionIdentityRecoveryAction: String? = nil
    var admissionIdentityRecoveryInProgress: Bool = false
    var admissionIdentityRecoveryLastError: String? = nil
    var admissionIdentityRecoveryApprovalInstruction: String? = nil
    var admissionIdentityRecoveryOperatorRequest: String? = nil
    var admissionIdentityRecoveryJournalState: String? = nil
    var coordinatorIdentityAdmissionMode: String?
    /// Whether macprovider-cli reports an active coordinator WebSocket session.
    /// Distinct from verified buyer-serving readiness.
    var coordinatorConnected: Bool?
    /// Canonical provider state reported by /v1/status. `buyer_serving` is the
    /// only state backed by the coordinator's routing-readiness verdict.
    var networkState: String?
    /// Last time Malibu observed a current `buyer_serving` verdict. Holds the
    /// dashboard on "Provider is ready" across WebSocket blips that rewrite
    /// `network_state` to `live_verified` / `buyer_serving_unknown`.
    var lastBuyerServingAt: Date? = nil
    /// Last-known USDC/MALIBU values may be shown across a Malibu relaunch
    /// until a fresh projection arrives. Distinct from `providerEarningsFresh`.
    var hasObservedProviderEarnings: Bool = false
    var advertisedMaxConcurrency: Int?
    var catalogState: String?
    var catalogReleaseID: String?
    var catalogDigest: String?
    var catalogSignerKeyID: String?
    var catalogSource: String?
    var coordinatorRecommendedVersion: String?
    var latestReleaseVersion: String?
    var cliUpdateInProgress: Bool
    var cliUpdateLastError: String?
    var providerSoftwareRepairRecommended: Bool
    var providerSoftwareRepairInProgress: Bool
    var providerSoftwareRepairLastError: String?
    var diagnosticFindings: [ProviderDiagnosticFinding] = []
    /// Dashboard-triggered online recommend/apply/submit for #582 hello-gate recovery.
    var hardwareVerificationRetryInProgress: Bool = false
    var hardwareVerificationRetryLastError: String? = nil

    // Coordinator-authoritative referral projection received only through the
    // launchd CLI's owner-only control socket. Malibu never receives the
    // provider bearer or the X challenge cleartext.
    var referralAvailability: ReferralAvailability = .unsupported
    var referralStatus: ReferralStatusProjection? = nil
    var referralLastError: String? = nil
    var referralActionInProgress: Bool = false

    // SPEC-016 §3 payout-address registration (Add wallet). Display-only;
    // private keys never enter Malibu. Address is public EIP-55 material.
    var payoutRegisteredAddress: String? = nil
    var payoutPendingUntilUTC: String? = nil
    var payoutRegistrationInProgress: Bool = false
    var payoutRegistrationCanCancel: Bool = false
    var payoutLastError: String? = nil
    var payoutLastStatus: String? = nil

    // Whether the CLI has explicitly acknowledged a pause; distinct from
    // "we optimistically flipped the UI" — pauseAck accepted:false must NOT
    // leave the UI showing Paused.
    var pauseAcknowledged: Bool

    mutating func markCoordinatorReadinessUnknown() {
        networkState = "buyer_serving_unknown"
    }

    mutating func updateBuyerServingHold(at now: Date = Date()) {
        if isLocalStatusObservationCurrent(at: now), networkState == "buyer_serving" {
            if lastBuyerServingAt == nil {
                lastBuyerServingAt = now
            }
            return
        }
        if isLocalStatusObservationCurrent(at: now),
           lastBuyerServingAt == nil,
           hasIncumbentBuyerServingEvidence,
           networkState == "live_verified" || networkState == "buyer_serving_unknown" {
            lastBuyerServingAt = now
            return
        }
        if shouldClearBuyerServingHold {
            lastBuyerServingAt = nil
        }
    }

    var shouldClearBuyerServingHold: Bool {
        if state == .paused || state == .idle || state == .error {
            return true
        }
        switch networkState {
        case "not_buyer_serving",
             "catalog_update_required",
             "compatibility_update_required",
             "catalog_integrity_failure",
             "safe_offline_fallback",
             "local_donor",
             "network_offline":
            return true
        default:
            break
        }
        switch lifecycleReason {
        case "autotune_evidence_required",
             "autotune_evidence_invalid",
             "autotune_evidence_binary_version_mismatch",
             "autotune_model_cap_exceeded",
             "autotune_model_uncatalogued":
            return true
        default:
            return lifecycleState == "catalog_incompatible"
        }
    }

    func isHoldingBuyerServingReady(at now: Date = Date()) -> Bool {
        guard !shouldClearBuyerServingHold else { return false }
        guard isLocalStatusObservationCurrent(at: now) else { return false }
        switch networkState {
        case "buyer_serving_unknown", "live_verified":
            return lastBuyerServingAt != nil || hasIncumbentBuyerServingEvidence
        default:
            return false
        }
    }

    var hasIncumbentBuyerServingEvidence: Bool {
        (requestsServedAllTime ?? 0) > 0
            || (requestsServedToday ?? 0) > 0
            || (earningsUsdcLifetime ?? 0) > 0
    }

    func isLocalStatusObservationCurrent(at now: Date = Date()) -> Bool {
        guard localStatusCapabilities.contains("status_observation_v1") else { return true }
        guard statusObservationFresh != false,
              let observationID = statusObservationID,
              !observationID.isEmpty,
              let observedAt = statusObservedAt,
              let validForMS = statusObservationValidForMS,
              (1...60_000).contains(validForMS) else {
            return false
        }
        // Retain a trusted observation across Malibu's ~15s poll cadence so a
        // healthy buyer_serving provider does not demote to Connected solely
        // because the CLI's shorter valid_for_ms lease elapsed between polls.
        // Hard failures still clear freshness via invalidateLocalStatusObservation().
        let validForSeconds = LocalStatusObservationPolicy.effectiveValidForSeconds(
            reportedValidForMS: validForMS
        )
        return observedAt <= now.addingTimeInterval(1)
            && observedAt.addingTimeInterval(validForSeconds) >= now
    }

    func isCredentialStatusCurrent(at now: Date = Date()) -> Bool {
        if credentialStatusFromDiagnostic {
            guard let credentialStatusObservedAt else { return false }
            let age = now.timeIntervalSince(credentialStatusObservedAt)
            return age >= -1 && age <= 60
        }
        return isLocalStatusObservationCurrent(at: now)
    }

    func hasFreshContractValidatedStatusObservation(at now: Date = Date()) -> Bool {
        localStatusContractCompatible == true
            && localStatusCapabilities.contains("status_observation_v1")
            && rawStatusObservationFresh(at: now)
    }

    func hasFreshServeOwnedCredentialState(at now: Date = Date()) -> Bool {
        hasFreshContractValidatedStatusObservation(at: now)
            && !credentialStatusFromDiagnostic
            && credentialState != nil
    }

    func hasFreshServeOwnedModelStatus(at now: Date = Date()) -> Bool {
        hasFreshContractValidatedStatusObservation(at: now)
            && localStatusCapabilities.contains("model_status_v1")
            && currentModelIDFromStatus
    }

    private func rawStatusObservationFresh(at now: Date) -> Bool {
        guard statusObservationFresh != false,
              let observationID = statusObservationID,
              !observationID.isEmpty,
              let observedAt = statusObservedAt,
              let validForMS = statusObservationValidForMS,
              (1...60_000).contains(validForMS) else {
            return false
        }
        return observedAt <= now.addingTimeInterval(1)
            && observedAt.addingTimeInterval(Double(validForMS) / 1_000) >= now
    }

    func hasTrustedReferralBoundary() -> Bool {
        localStatusContractCompatible == true
            && localStatusLifecycleOwner == "macprovider_cli"
            && localStatusCapabilities.contains("referral_status_v1")
            && localStatusCapabilities.contains("referral_fragment_links_v1")
            && localStatusCapabilities.contains("service_instance_v1")
            && serviceRole == "serve"
            && localProviderID != nil
    }

    mutating func invalidateLocalStatusObservation() {
        lastBuyerServingAt = nil
        if localStatusCapabilities.contains("status_observation_v1") {
            statusObservationFresh = false
        }
        serviceInstanceID = nil
        servicePID = nil
        serviceBootSession = nil
        serviceStartedAt = nil
        serviceRole = nil
        lifecycleRecordState = nil
        lifecycleSequence = nil
        lifecycleTransitionID = nil
        lifecycleTransitionAt = nil
        lifecycleState = nil
        lifecycleReason = nil
        lifecycleAuthority = nil
        lifecycleWriter = nil
        lifecycleOperationID = nil
        lifecycleOperatorPaused = nil
        lifecycleLastRestart = nil
        lifecycleLastRejection = nil
        lifecycleLastUpdate = nil
        lifecycleLastWatchdog = nil
        lifecycleLeaseState = nil
        lifecycleLeaseKind = nil
        lifecycleLeaseOperationID = nil
        lifecycleLeaseExpiresWallMS = nil
        if currentModelIDFromStatus {
            currentModelID = nil
        }
        currentModelIDFromStatus = false
        currentModelLoaded = nil
        modelHash = nil
        modelHashAlgorithm = nil
        weightsManifestSHA256 = nil
        weightsManifestAlgorithm = nil
        credentialSource = nil
        credentialState = nil
        credentialRestartSafe = nil
        credentialMigrationPending = nil
        credentialRecoveryAction = nil
        credentialStatusObservedAt = nil
        credentialStatusFromDiagnostic = false
        admissionIdentitySource = nil
        admissionIdentityState = nil
        admissionIdentityPublicKeySHA256 = nil
        admissionIdentityPendingPublicKeySHA256 = nil
        admissionIdentityPreviousPublicKeySHA256 = nil
        admissionIdentityPreviousValidUntil = nil
        admissionIdentityCoordinatorGeneration = nil
        admissionIdentityCoordinatorPublicKeySHA256 = nil
        admissionIdentityCoordinatorKeyRole = nil
        admissionIdentityTransitionError = nil
        admissionIdentityRecoveryAction = nil
        coordinatorIdentityAdmissionMode = nil
        coordinatorConnected = nil
        networkState = "buyer_serving_unknown"
        catalogState = nil
        catalogReleaseID = nil
        catalogDigest = nil
        catalogSignerKeyID = nil
        catalogSource = nil
        compatibilitySetID = nil
        compatibilitySetSHA256 = nil
        coordinatorRecommendedVersion = nil
        latestReleaseVersion = nil
        referralAvailability = .unsupported
        referralStatus = nil
        referralLastError = nil
        referralActionInProgress = false
        payoutRegisteredAddress = nil
        payoutPendingUntilUTC = nil
        payoutRegistrationInProgress = false
        payoutRegistrationCanCancel = false
        payoutLastError = nil
        payoutLastStatus = nil
    }

    static let empty = AgentSnapshot(
        state: .idle,
        currentModelID: nil,
        earningsUsdcToday: nil,
        malibuAccruedToday: nil,
        unpaidLedgerBacklogUSDC: nil,
        unpaidLedgerBacklogMALIBU: nil,
        walletBound: false,
        trustTier: .provisional,
        uptimeSec: nil,
        requestsServedToday: nil,
        requestsServedAllTime: nil,
        requestsPerMinute: nil,
        inputTokensToday: nil,
        outputTokensToday: nil,
        inputTokensAllTime: nil,
        outputTokensAllTime: nil,
        earningsUsdcWeek: nil,
        earningsUsdcPending: nil,
        earningsUsdcLifetime: nil,
        malibuAccruedAllTime: nil,
        malibuWithdrawable: nil,
        malibuHeld: nil,
        malibuHoldReasons: [],
        malibuDailyCap: nil,
        malibuWalletDailyCap: nil,
        malibuRewardEligibility: nil,
        providerEarningsFresh: false,
        malibuProjectionFresh: false,
        gpuUtilizationPct: nil,
        gpuTemperatureC: nil,
        latencyP50Ms: nil,
        latencyP99Ms: nil,
        queueDepth: nil,
        uptime7dPct: nil,
        declinedRequests: nil,
        restartCount: nil,
        weightsPath: nil,
        trustCriteriaMet: nil,
        trustCriteriaRequired: nil,
        thermalState: nil,
        lastError: nil,
        cliVersion: nil,
        compatibilitySetID: nil,
        compatibilitySetSHA256: nil,
        localStatusContractVersion: nil,
        localStatusMinimumReaderVersion: nil,
        localStatusContractCompatible: nil,
        localStatusLifecycleOwner: nil,
        localStatusCapabilities: [],
        localProviderID: nil,
        statusObservationID: nil,
        statusObservedAt: nil,
        statusObservationValidForMS: nil,
        statusObservationFresh: nil,
        serviceInstanceID: nil,
        servicePID: nil,
        serviceBootSession: nil,
        serviceStartedAt: nil,
        serviceRole: nil,
        lifecycleRecordState: nil,
        lifecycleSequence: nil,
        lifecycleTransitionID: nil,
        lifecycleTransitionAt: nil,
        lifecycleState: nil,
        lifecycleReason: nil,
        lifecycleAuthority: nil,
        lifecycleWriter: nil,
        lifecycleOperationID: nil,
        lifecycleOperatorPaused: nil,
        lifecycleLastRestart: nil,
        lifecycleLastRejection: nil,
        lifecycleLastUpdate: nil,
        lifecycleLastWatchdog: nil,
        lifecycleLeaseState: nil,
        lifecycleLeaseKind: nil,
        lifecycleLeaseOperationID: nil,
        lifecycleLeaseExpiresWallMS: nil,
        credentialSource: nil,
        credentialState: nil,
        credentialRestartSafe: nil,
        credentialMigrationPending: nil,
        credentialRecoveryAction: nil,
        credentialStatusObservedAt: nil,
        credentialStatusFromDiagnostic: false,
        credentialRepairInProgress: false,
        credentialRepairLastError: nil,
        admissionIdentitySource: nil,
        admissionIdentityState: nil,
        admissionIdentityPublicKeySHA256: nil,
        coordinatorIdentityAdmissionMode: nil,
        coordinatorConnected: nil,
        networkState: nil,
        advertisedMaxConcurrency: nil,
        catalogState: nil,
        catalogReleaseID: nil,
        catalogDigest: nil,
        catalogSignerKeyID: nil,
        catalogSource: nil,
        coordinatorRecommendedVersion: nil,
        latestReleaseVersion: nil,
        cliUpdateInProgress: false,
        cliUpdateLastError: nil,
        providerSoftwareRepairRecommended: false,
        providerSoftwareRepairInProgress: false,
        providerSoftwareRepairLastError: nil,
        diagnosticFindings: [],
        pauseAcknowledged: false
    )
}

enum ProviderSoftwareRepairCapabilityGate {
    static let repairFromProtectedSource = "provider_software_repair_from_protected_source_v1"

    static func allowsProtectedSourceRepair(_ s: AgentSnapshot, at now: Date = Date()) -> Bool {
        s.hasFreshContractValidatedStatusObservation(at: now)
            && s.localStatusCapabilities.contains(repairFromProtectedSource)
    }
}

enum AgentSnapshotPresenter {
    /// Dashboard-executable recovery. Presentation copy stays in `safeNextAction`;
    /// buttons must key off this enum so #582 guidance cannot advertise a
    /// non-wired action.
    enum ExecutableRecoveryAction: Equatable {
        case retryHardwareVerification
        case updateProviderSoftware
        case repairProviderSoftware
        case repairCredential
        case repairAdmissionIdentity
        case exportDiagnostics
    }

    struct PublicStatus: Equatable {
        let title: String
        let detail: String?
        let safeNextAction: String?
        let executableAction: ExecutableRecoveryAction?

        init(
            title: String,
            detail: String?,
            safeNextAction: String?,
            executableAction: ExecutableRecoveryAction? = nil
        ) {
            self.title = title
            self.detail = detail
            self.safeNextAction = safeNextAction
            self.executableAction = executableAction
        }
    }

    struct MiningHealth: Equatable {
        let status: String
        let reasonCode: String
        let reason: String
        let nextAction: String
        let rewardSummary: String
        let trustSummary: String
    }

    /// A fresh authoritative reward verdict whose primary reason the generic
    /// wallet-missing / provisional-tier branches would misrepresent — a compute
    /// integrity block, untrusted provider token, missing/expired hardware
    /// evidence, unavailable/pending integrity, or a past-epoch disposition.
    /// Returns the honest MiningHealth for such a verdict, or nil to fall
    /// through to the normal wallet/tier/cap logic.
    private static func authoritativeBlockingRewardHealth(_ s: AgentSnapshot) -> MiningHealth? {
        guard let eligibility = authoritativeRewardEligibility(s) else { return nil }
        func health(_ status: String, _ code: String) -> MiningHealth {
            MiningHealth(
                status: status,
                reasonCode: code,
                reason: sentence(rewardReasonCopy(eligibility.primaryReason)),
                nextAction: rewardReasonNextAction(eligibility.primaryReason),
                rewardSummary: miningRewardSummary(s),
                trustSummary: miningTrustSummary(s)
            )
        }
        switch eligibility.primaryReason {
        case "compute_integrity_blocked", "provider_token_untrusted":
            return health("Reward eligibility needs review", "reward_eligibility_review")
        case "hardware_evidence_unavailable",
             "hardware_evidence_missing_or_expired",
             "compute_integrity_unavailable",
             "compute_integrity_pending":
            return health("Reward status unavailable", "reward_projection_unavailable")
        case "excluded_epoch_disposition", "burned_or_retired_epoch_disposition":
            return health("Reward epoch update", "reward_epoch_disposition")
        case "held_epoch_disposition":
            // An active epoch hold outranks raw tier/amount: SPEC-021 makes the
            // authoritative reward_eligibility verdict win over raw withdrawable
            // fields, so this must surface as held before the trusted-withdrawable
            // branch can claim withdrawals are unlocked.
            return health("Rewards held", "rewards_held")
        default:
            return nil
        }
    }

    static func miningHealth(_ s: AgentSnapshot) -> MiningHealth {
        func result(
            status: String,
            code: String,
            reason: String,
            action: String
        ) -> MiningHealth {
            MiningHealth(
                status: status,
                reasonCode: code,
                reason: reason,
                nextAction: action,
                rewardSummary: miningRewardSummary(s),
                trustSummary: miningTrustSummary(s)
            )
        }

        if s.state == .idle {
            return result(
                status: "Not running",
                code: "not_running",
                reason: "The provider service is stopped.",
                action: "Start provider setup."
            )
        }
        if s.state == .paused {
            return result(
                status: "Paused",
                code: "provider_paused",
                reason: "This Mac will not receive customer work while paused.",
                action: "Choose Resume when ready."
            )
        }
        if s.state == .error {
            return result(
                status: "Needs attention",
                code: "provider_error",
                reason: publicErrorDetail(s.lastError) ?? "The provider reported an error.",
                action: publicStatus(s).safeNextAction ?? "Export diagnostics for support."
            )
        }
        if miningSkipCount(s, "on_battery") > 0 {
            return result(
                status: "Blocked locally",
                code: "local_on_battery",
                reason: "This Mac is on battery.",
                action: "Plug in power to earn."
            )
        }
        if miningSkipCount(s, "thermal_pressure") > 0 {
            return result(
                status: "Blocked locally",
                code: "local_thermal_pressure",
                reason: "Thermal pressure is limiting local work.",
                action: "Let this Mac cool before earning resumes."
            )
        }
        if miningSkipCount(s, "model_not_loaded") > 0 || isModelPreparing(s) {
            return result(
                status: "Preparing",
                code: "local_model_preparing",
                reason: "The model is still loading or checking local setup.",
                action: "Keep Malibu open while setup continues."
            )
        }
        if s.rewardTelemetryUnavailable {
            // The CLI reached reward/wallet telemetry but it FAILED (outage),
            // which is NOT benign first-run absence. A genuine fault reads as
            // needs-attention — never calm "warming up" or plain "earning".
            // USDC earnings are shown separately and stay truthful.
            return result(
                status: "Reward status unavailable",
                code: "reward_telemetry_outage",
                reason: "MALIBU reward status can't be reached right now. Your USDC earnings are unaffected.",
                action: "Nothing to do — this refreshes on its own."
            )
        }
        if !s.providerEarningsFresh && !s.hasObservedProviderEarnings && !s.malibuProjectionFresh {
            // A fresh MALIBU verdict (malibuProjectionFresh) is an independent
            // source from the provider-earnings projection: an accrual-only frame
            // (MALIBU fresh, earnings not) must fall through to the authoritative
            // reward-eligibility handling below, not be masked as "unavailable".
            // Reframe only when the provider is genuinely buyer-serving-admitted
            // (isNetworkReady) AND has no fresh MALIBU projection that a later
            // branch would report as held/withdrawable/locked. This keeps the
            // forward-looking "No earnings yet" copy off not-yet-admitted,
            // reconnecting, or reward-bearing states — those keep the
            // conservative wording below. For such a clean fresh-provider state
            // this is normal, not a fault: frame it forward and name the one real
            // next step (bind a payout wallet, or the trust-unlock path).
            if isNetworkReady(s) && !s.malibuProjectionFresh {
                let action: String
                if s.walletBound == false {
                    action = "Add a payout wallet so your earnings can be paid out."
                } else if let criteria = trustCriteriaAction(s) {
                    action = criteria
                } else {
                    action = "Stay online — you'll start earning as customer jobs arrive."
                }
                return result(
                    status: "No earnings yet",
                    code: "reward_projection_warming_up",
                    reason: "You're live and building trust. Earnings appear after your first paid job.",
                    action: action
                )
            }
            return result(
                status: "Reward status unavailable",
                code: "reward_projection_unavailable",
                reason: "Fresh earnings or MALIBU reward telemetry is not available yet.",
                action: isActive(s) ? "Keep Malibu open while reward status refreshes." : "Start the provider to refresh reward status."
            )
        }
        // An authoritative BLOCKING/ineligible/excluded reward verdict must
        // surface its real reason BEFORE the wallet-missing and provisional-tier
        // branches, so a compute-integrity block, untrusted provider token,
        // missing hardware evidence, or epoch exclusion is not mislabeled as
        // "No payout wallet yet" or a routine "Locked until Trusted".
        if let blocked = authoritativeBlockingRewardHealth(s) {
            return blocked
        }
        if s.walletBound == false {
            return result(
                status: "No payout wallet yet",
                code: "wallet_missing",
                reason: "You're set up to earn — you just need somewhere to be paid.",
                action: "Add a payout wallet to receive earnings."
            )
        }
        if s.malibuProjectionFresh {
            if isRewardTelemetryUnavailable(s) {
                // A fresh frame that could not compute a verdict is a telemetry
                // fault, not "accruing but locked" — surface it as needs-attention.
                return result(
                    status: "Reward status unavailable",
                    code: "reward_telemetry_outage",
                    reason: "MALIBU reward status could not be determined right now.",
                    action: "Nothing to do — this refreshes on its own."
                )
            }
            if let eligibility = authoritativeRewardEligibility(s), eligibility.primaryReason == "held_provider_daily_cap" {
                return result(
                    status: "Provider cap held",
                    code: "provider_daily_cap_held",
                    reason: "MALIBU above the provider daily cap is held.",
                    action: "Wait for the next UTC day."
                )
            }
            if let eligibility = authoritativeRewardEligibility(s), eligibility.primaryReason == "held_wallet_daily_cap" {
                return result(
                    status: "Wallet cap held",
                    code: "wallet_daily_cap_held",
                    reason: "MALIBU above the wallet daily cap is held.",
                    action: "Wait for the next UTC day or use a wallet below the cap."
                )
            }
            if s.malibuHoldReasons.contains("per_wallet_daily_cap") {
                return result(
                    status: "Wallet cap held",
                    code: "wallet_daily_cap_held",
                    reason: "MALIBU above the wallet daily cap is held.",
                    action: "Wait for the next UTC day or use a wallet below the cap."
                )
            }
            if s.trustTier == .provisional {
                return result(
                    status: "Locked until Trusted",
                    code: "trust_tier_provisional",
                    reason: "MALIBU is accruing, but withdrawals are locked until Trusted.",
                    action: trustCriteriaAction(s) ?? "Complete trust criteria to unlock withdrawals."
                )
            }
            if !shouldIgnoreLeftoverProvisionalLock(s),
               !displayMalibuHoldReasons(s).isEmpty || (s.malibuHeld ?? 0) > 0 {
                return result(
                    status: "Rewards held",
                    code: "rewards_held",
                    reason: "Some MALIBU is held while payout eligibility is being verified.",
                    action: "Review the hold reason before withdrawing."
                )
            }
            if s.trustTier == .trusted, let withdrawable = s.malibuWithdrawable, withdrawable > 0 {
                // Raw withdrawable amount never overrides an authoritative
                // eligibility verdict (SPEC-021). If a display-relevant verdict
                // exists and is not "withdrawable" (held/unavailable/etc.), surface
                // that honestly instead of claiming withdrawals are unlocked from
                // raw amount>0. displayRewardEligibility exempts leftover-provisional
                // holds so a Trusted earner is not falsely shown as held.
                if let eligibility = displayRewardEligibility(s),
                   eligibility.withdrawalState != "withdrawable" {
                    return result(
                        status: "Rewards held",
                        code: "rewards_held",
                        reason: sentence(rewardReasonCopy(eligibility.primaryReason)),
                        action: rewardReasonNextAction(eligibility.primaryReason)
                    )
                }
                return result(
                    status: "Withdrawable",
                    code: "trusted_withdrawable",
                    reason: "Trusted reward projection reports withdrawable MALIBU.",
                    action: "No local action needed."
                )
            }
        }
        if hasMiningEarningsActivity(s) {
            return result(
                status: "Earning",
                code: "earning",
                reason: "Paid work or rewards have settled in the current window.",
                action: "No local action needed."
            )
        }
        if (s.requestsServedToday ?? 0) > 0 {
            return result(
                status: "Waiting for settlement",
                code: "eligible_waiting_settlement",
                reason: "Work ran today; paid credits appear when jobs settle.",
                action: "No local action needed."
            )
        }
        if isNetworkReady(s) {
            return result(
                status: "Eligible, idle",
                code: "idle_no_work",
                reason: "This Mac is eligible, but the network is quiet right now.",
                action: "Keep Malibu online."
            )
        }
        return result(
            status: publicStatus(s).title,
            code: "customer_availability_pending",
            reason: publicStatus(s).detail ?? "Customer availability is still being checked.",
            action: publicStatus(s).safeNextAction ?? "Keep Malibu open while status updates."
        )
    }

    private static func miningSkipCount(_ s: AgentSnapshot, _ reason: String) -> Int64 {
        guard s.providerEarningsFresh else { return 0 }
        return s.idlePrewarmSummary.skipsByReasonLast1h[reason] ?? 0
    }

    private static func hasMiningEarningsActivity(_ s: AgentSnapshot) -> Bool {
        // Never infer "earning" from stale amounts. When the provider-earnings
        // projection is not fresh (e.g. after a legacy stub frame demoted it),
        // preserved last-known amounts must not drive an Earning / withdrawals-
        // unlocked status.
        guard s.providerEarningsFresh else { return false }
        return (s.requestsPerMinute ?? 0) > 0
            || (s.earningsUsdcToday ?? 0) > 0
            || (s.malibuAccruedToday ?? 0) > 0
    }

    private static func miningRewardSummary(_ s: AgentSnapshot) -> String {
        let usdc: String
        if !canShowLastKnownUSDC(s) {
            usdc = "USDC unavailable"
        } else if let today = s.earningsUsdcToday {
            usdc = "\(formatUSDC(today)) USDC today"
        } else {
            // Missing today: real $0.00 only for a brand-new all-zero fresh
            // frame; otherwise a non-authoritative placeholder, matching the
            // hero number and full line rather than a bare "n/a".
            usdc = usdcFreshZeroAllowed(s) ? "\(formatUSDC(0)) USDC today" : "USDC today not reported"
        }
        let malibu: String
        if s.malibuProjectionFresh {
            if isRewardTelemetryUnavailable(s) {
                malibu = "MALIBU reward status unavailable"
            } else {
                let withdrawable = s.malibuWithdrawable.map { String(format: "%.2f withdrawable", $0) }
                    ?? "n/a withdrawable"
                let held = s.malibuHeld.map { String(format: "%.2f held", $0) }
                    ?? "n/a held"
                malibu = "MALIBU \(withdrawable) / \(held)"
            }
        } else {
            malibu = "MALIBU unavailable"
        }
        return "\(usdc) · \(malibu)"
    }

    private static func miningTrustSummary(_ s: AgentSnapshot) -> String {
        guard s.malibuProjectionFresh else {
            return "MALIBU trust telemetry not published yet"
        }
        if isRewardTelemetryUnavailable(s) {
            return "Trust status temporarily unavailable"
        }
        let tier = s.trustTier.rawValue.capitalized
        if hasDemotionCooldown(s) {
            return "Trust: \(tier) · Trust review in progress"
        }
        if s.trustTier == .trusted {
            return "Trust: Trusted"
        }
        let progress = distinctPairProgress(s)
        return "Trust: \(tier) · \(progress.met) of \(progress.required) criteria met"
    }

    private static func trustCriteriaAction(_ s: AgentSnapshot) -> String? {
        if hasDemotionCooldown(s) {
            return "Keep Malibu online; withdrawals unlock automatically when Trusted."
        }
        // Base the remaining-criteria count on distinct-pair truth when a fresh
        // projection is available; fall back to the raw aggregate only when the
        // granular arrays are not.
        if s.malibuProjectionFresh, !isRewardTelemetryUnavailable(s) {
            let progress = distinctPairProgress(s)
            guard progress.required > progress.met else { return nil }
            return "Complete \(progress.required - progress.met) more trust criteria to unlock withdrawals."
        }
        guard let met = s.trustCriteriaMet,
              let required = s.trustCriteriaRequired,
              required > met else { return nil }
        return "Complete \(required - met) more trust criteria to unlock withdrawals."
    }

    private static func isActive(_ s: AgentSnapshot) -> Bool {
        s.state == .serving || s.state == .paused || isLocalOnly(s)
    }

    static func isNetworkReady(_ s: AgentSnapshot, at now: Date = Date()) -> Bool {
        guard s.state == .serving else { return false }
        if s.isLocalStatusObservationCurrent(at: now) && s.networkState == "buyer_serving" {
            return true
        }
        return s.isHoldingBuyerServingReady(at: now)
    }

    private static func isLocalOnly(_ s: AgentSnapshot) -> Bool {
        s.state == .reconnecting && s.currentModelID != nil
    }

    /// A genuine post-setup connectivity OUTAGE (local internet down, or the
    /// coordinator unreachable). This is NOT first-run setup: it must not read
    /// "Setting up / keep Malibu open", but surface honestly with a
    /// restore-connection (or auto-reconnect) action.
    static func isNetworkOutage(_ s: AgentSnapshot) -> Bool {
        s.networkState == "network_offline"
            || s.networkState == "coordinator_unavailable"
            || s.lifecycleState == "network_offline"
            || s.lifecycleState == "coordinator_unavailable"
    }

    /// True when the outage is the local link being down (user can act), vs the
    /// coordinator being unreachable (reconnect is automatic).
    private static func isLocalLinkOffline(_ s: AgentSnapshot) -> Bool {
        s.networkState == "network_offline" || s.lifecycleState == "network_offline"
    }

    /// True when a fresh MALIBU projection reports a genuine "cannot determine"
    /// verdict — a telemetry outage or schema-drift sentinel — rather than a
    /// real reward state. There is NO benign "warming up" unavailable state:
    /// the coordinator emits a concrete verdict (held / withdrawable / …) for a
    /// brand-new provider, so an "unavailable" withdrawal state is always a
    /// problem and must read as one, not as first-run calm.
    static func isRewardTelemetryUnavailable(_ s: AgentSnapshot) -> Bool {
        // An explicit CLI-signalled telemetry outage (wallet-status decode
        // failure) is authoritative even when the MALIBU projection is not
        // fresh, so the fail-closed frame is never read as first-run calm.
        if s.rewardTelemetryUnavailable { return true }
        guard s.malibuProjectionFresh else { return false }
        // A fresh verdict whose withdrawal state is "unavailable" is a genuine
        // "cannot determine" telemetry sentinel and is authoritative regardless
        // of any amount fields the frame may still carry — stale/partial
        // amounts must not mask an unavailable verdict.
        guard let eligibility = authoritativeRewardEligibility(s) else { return false }
        return eligibility.withdrawalState == "unavailable"
    }

    private static func authoritativeLifecycleLabel(_ s: AgentSnapshot) -> String? {
        guard s.isLocalStatusObservationCurrent(), let state = s.lifecycleState else { return nil }
        return lifecycleStateLabel(state)
    }

    static func publicStatus(_ s: AgentSnapshot) -> PublicStatus {
        // A still-serving (or paused) CLI must keep earnings/traffic/USDC and
        // the ready/paused truth. HOME-ACL repair is a software update, not a
        // stop — including while auto-repair is running.
        if s.providerSoftwareRepairInProgress, isLiveProviderVisibleDuringSoftwareRepair(s) {
            if s.state == .paused {
                return PublicStatus(
                    title: "Provider is paused",
                    detail: "Installing a software update in the background. This Mac will not receive customer work until it is resumed. Your identity stays on this Mac.",
                    safeNextAction: "Keep Malibu open. You do not need a new invite."
                )
            }
            return PublicStatus(
                title: "Provider is ready",
                detail: "This Mac is approved and available for customer work. Installing a software update in the background. Your identity, models, and payout stay on this Mac.",
                safeNextAction: "Keep Malibu open. You do not need a new invite."
            )
        }
        if s.providerSoftwareRepairInProgress {
            return PublicStatus(
                title: "Repairing provider software",
                detail: "Malibu is reinstalling the bundled provider software and watchdog. Keep Malibu open. Your identity, models, and payout stay on this Mac.",
                safeNextAction: "Keep Malibu open. You do not need a new invite."
            )
        }
        if let diagnostic = publicStatusForTopDiagnosticFinding(s) {
            return diagnostic
        }
        // A still-serving (or paused) CLI must keep earnings/traffic/USDC and
        // the ready/paused truth. HOME-ACL repair is a software update, not a
        // stop. Only hide that live state when the provider is not currently
        // usable for customer work.
        if canRepairProviderSoftware(s), !isLiveProviderVisibleDuringSoftwareRepair(s) {
            return PublicStatus(
                title: "Provider software repair available",
                detail: "A permission on your home folder blocked automatic update recovery.",
                safeNextAction: "Repair provider software. Malibu will reinstall the bundled provider software and watchdog. Your provider identity and downloaded models will be kept.",
                executableAction: .repairProviderSoftware
            )
        }
        if s.state == .paused {
            return withHomeACLRepairIfNeeded(
                PublicStatus(
                    title: "Provider is paused",
                    detail: "This Mac will not receive customer work until it is resumed.",
                    safeNextAction: "Choose Resume when ready."
                ),
                s
            )
        }
        if isNetworkReady(s, at: Date()) {
            return withHomeACLRepairIfNeeded(
                PublicStatus(
                    title: "Provider is ready",
                    detail: "This Mac is approved and available for customer work.",
                    safeNextAction: nil
                ),
                s
            )
        }
        if isPendingHardwareVerification(s) {
            return PublicStatus(
                title: "Pending hardware verification",
                detail: "Hardware verification pending — usually under an hour. Stay online so fresh evidence can be submitted; recently submitted evidence may still be awaiting network approval.",
                safeNextAction: "Keep Malibu online · retry setup if this lasts more than an hour.",
                executableAction: .retryHardwareVerification
            )
        }
        if isHardwareEvidenceRejected(s) {
            let capExceeded = s.lifecycleReason == "autotune_model_cap_exceeded"
            return PublicStatus(
                title: "Not eligible: admission evidence failed",
                detail: capExceeded
                    ? "This Mac's verified capacity is below the selected model. Retry setup while online to apply a smaller admitted model and resubmit evidence."
                    : "Hardware evidence was rejected. Retry provider setup while online to generate and submit fresh evidence.",
                safeNextAction: "Retry provider setup while online.",
                executableAction: .retryHardwareVerification
            )
        }
        if isUncataloguedModel(s) {
            return PublicStatus(
                title: "This Mac is not currently eligible",
                detail: "The selected model is not in the current signed catalog. Retry setup while online to apply a supported model and resubmit evidence.",
                safeNextAction: "Retry provider setup while online.",
                executableAction: .retryHardwareVerification
            )
        }
        if isSoftwareUpdateRequired(s) {
            return PublicStatus(
                title: "This Mac is not currently eligible",
                detail: "Provider software must be updated before this Mac can receive customer work.",
                safeNextAction: "Install latest provider software.",
                executableAction: updateAvailable(s) ? .updateProviderSoftware : nil
            )
        }
        if isTemporarilyNotBuyerServing(s) {
            return PublicStatus(
                title: "Customer availability is temporarily interrupted",
                detail: "The coordinator is not routing customer work to this Mac right now, often during reconnect or maintenance windows.",
                safeNextAction: "Keep Malibu open while status updates."
            )
        }
        if isIneligibleForCustomerWork(s) {
            return PublicStatus(
                title: "This Mac is not currently eligible",
                detail: "This Mac cannot receive customer work in its current state.",
                safeNextAction: "Export diagnostics for support.",
                executableAction: .exportDiagnostics
            )
        }
        // A connectivity OUTAGE (local link down or coordinator unreachable) is
        // not benign setup and must be surfaced before the "waiting / preparing"
        // copy, so a provider in a real outage is told to restore the connection
        // (or that reconnect is automatic) rather than "keep Malibu open while
        // setup continues".
        if isNetworkOutage(s) {
            if isLocalLinkOffline(s) {
                return PublicStatus(
                    title: "Network offline",
                    detail: "This Mac lost its internet connection, so it can't reach the network.",
                    safeNextAction: "Check this Mac's internet connection. Reconnect is automatic once it's back."
                )
            }
            return PublicStatus(
                title: "Network unavailable",
                detail: "Malibu can't reach the network right now. This is on the network side, not your Mac.",
                safeNextAction: "No action needed — reconnect is automatic. Keep Malibu open."
            )
        }
        if isWaitingForNetworkApproval(s) {
            return PublicStatus(
                title: "Waiting for network approval",
                detail: "The model is loaded. Network verification is still in progress.",
                safeNextAction: "Keep Malibu open while verification finishes."
            )
        }
        if isCheckingCustomerAvailability(s) {
            return PublicStatus(
                title: "Checking customer availability",
                detail: "Malibu has not received a current network approval status yet.",
                safeNextAction: "Keep Malibu open while status updates."
            )
        }
        if isModelPreparing(s) {
            return PublicStatus(
                title: "Model is preparing",
                detail: "The provider is starting locally before network verification.",
                safeNextAction: "Keep Malibu open while setup continues."
            )
        }
        switch s.state {
        case .error:
            let action: String
            if canRepairProviderSoftware(s) {
                action = "Repair provider software."
            } else if canRepairCredential(s) {
                action = "Repair saved access."
            } else if canRepairAdmissionIdentity(s) {
                action = "\(admissionIdentityRepairButtonTitle(s))."
            } else if updateAvailable(s) {
                action = "Install latest provider software."
            } else {
                action = "Export diagnostics for support."
            }
            let executable: ExecutableRecoveryAction?
            if canRepairProviderSoftware(s) {
                executable = .repairProviderSoftware
            } else if canRepairCredential(s) {
                executable = .repairCredential
            } else if canRepairAdmissionIdentity(s) {
                executable = .repairAdmissionIdentity
            } else if updateAvailable(s) {
                executable = .updateProviderSoftware
            } else {
                executable = .exportDiagnostics
            }
            return PublicStatus(
                title: "Provider needs attention",
                detail: publicErrorDetail(s.lastError),
                safeNextAction: action,
                executableAction: executable
            )
        case .paused:
            return PublicStatus(
                title: "Provider is paused",
                detail: "This Mac will not receive customer work until it is resumed.",
                safeNextAction: "Choose Resume when ready."
            )
        case .idle:
            return PublicStatus(
                title: "Provider stopped",
                detail: nil,
                safeNextAction: "Start provider setup."
            )
        default:
            return PublicStatus(
                title: "Model is preparing",
                detail: "Malibu is checking the local provider.",
                safeNextAction: "Keep Malibu open while setup continues."
            )
        }
    }

    /// One authoritative status following a three-state model (Setting up /
    /// Live · Provisional / Earning · Trusted) plus a needs-attention fallback.
    /// The reward/blocker dimension (meaning, next action, tone) is derived from
    /// the SAME `miningHealth` reason model the card and header both consume, so
    /// caps/holds/telemetry/local-block states surface with their one concrete
    /// action rather than a generic "Earning · Trusted / withdrawals unlocked".
    struct ConsolidatedStatus: Equatable {
        enum Phase: String { case settingUp, live, earning, needsAttention }
        enum Tone: String { case positive, neutral, attention }
        let phase: Phase
        let tone: Tone
        let label: String
        let meaning: String
        let nextAction: String?
    }

    /// The diagnostic finding, if any, that `publicStatus` actually surfaced as the
    /// primary status. nil when a repair-in-progress override precedes diagnostics
    /// in `publicStatus`, or when no finding qualifies as primary. Lets
    /// `consolidatedStatus` classify diagnostic severity explicitly rather than
    /// inferring it from whether a tappable action happens to exist.
    private static func primaryDiagnosticFinding(_ s: AgentSnapshot) -> ProviderDiagnosticFinding? {
        guard !s.providerSoftwareRepairInProgress,
              publicStatusForTopDiagnosticFinding(s) != nil,
              let finding = s.diagnosticFindings.first(where: { canUseAsPrimaryDiagnosticStatus($0, snapshot: s) })
        else { return nil }
        return finding
    }

    static func consolidatedStatus(_ s: AgentSnapshot) -> ConsolidatedStatus {
        let publicS = publicStatus(s)
        // A repair-available CTA on an otherwise ready/live provider is a
        // nonblocking capability, not a problem: it must not demote a live earner
        // to needs-attention. A blocking recovery action (credential/admission/
        // hardware/update/export) or a stopped/paused state still is.
        let isNonblockingRepairOnReady =
            publicS.executableAction == .repairProviderSoftware && isNetworkReady(s)
        let hasBlockingAction = publicS.executableAction != nil && !isNonblockingRepairOnReady
        // A diagnostic finding owns the primary status. Only an in-progress software
        // update is benign; every other surfaced diagnostic is a problem and reads
        // needs-attention even when it carries no tappable action (e.g. a credential
        // store that is unavailable without a repair path).
        let primaryDiag = primaryDiagnosticFinding(s)
        let hasBlockingDiagnostic = primaryDiag != nil && primaryDiag?.signatureID != .autoupdateInProgress
        if s.state == .error || s.state == .idle || s.state == .paused
            || hasBlockingAction || hasBlockingDiagnostic {
            let tone: ConsolidatedStatus.Tone =
                (s.state == .paused || s.state == .idle) ? .neutral : .attention
            return ConsolidatedStatus(
                phase: .needsAttention,
                tone: tone,
                label: publicS.title,
                meaning: publicS.detail ?? "",
                nextAction: publicS.safeNextAction
            )
        }
        guard isNetworkReady(s) else {
            // A connectivity outage is not first-run setup. Classify it as
            // needs-attention (never .settingUp) and carry publicStatus's honest
            // outage copy + restore-connection action. A local-link outage is the
            // user's to fix (attention tone); a coordinator-side outage recovers
            // automatically (neutral tone), but neither is "Setting up".
            if isNetworkOutage(s) {
                return ConsolidatedStatus(
                    phase: .needsAttention,
                    tone: isLocalLinkOffline(s) ? .attention : .neutral,
                    label: publicS.title,
                    meaning: publicS.detail ?? "Malibu can't reach the network right now.",
                    nextAction: publicS.safeNextAction
                )
            }
            // Only genuine first-run/startup reads "Setting up" (phase .settingUp).
            if s.state == .starting {
                return ConsolidatedStatus(
                    phase: .settingUp,
                    tone: .neutral,
                    label: "Setting up",
                    meaning: publicS.detail ?? "Getting this Mac ready for customer work.",
                    nextAction: publicS.safeNextAction ?? "Keep Malibu open while setup finishes."
                )
            }
            // A post-setup interruption (was buyer-serving, now temporarily not)
            // is NOT first-run setup — its phase must not read as .settingUp to any
            // badge/analytics consumer. Genuine initial-admission / not-yet-connected
            // states below remain .settingUp.
            if isTemporarilyNotBuyerServing(s) {
                return ConsolidatedStatus(
                    phase: .needsAttention,
                    tone: .neutral,
                    label: publicS.title,
                    meaning: publicS.detail ?? "Customer availability is temporarily interrupted.",
                    nextAction: publicS.safeNextAction ?? "Keep Malibu open while status updates."
                )
            }
            return ConsolidatedStatus(
                phase: .settingUp,
                tone: .neutral,
                label: publicS.title,
                meaning: publicS.detail ?? "Reconnecting to the network.",
                nextAction: publicS.safeNextAction ?? "Keep Malibu open while it reconnects."
            )
        }
        // A benign in-progress diagnostic (software update) owns the truthful
        // status even on a network-ready provider: surface it (.live/neutral)
        // instead of letting the earning display overwrite it. Blocking diagnostics
        // were already handled by the needs-attention gate above.
        if primaryDiag?.signatureID == .autoupdateInProgress {
            return ConsolidatedStatus(
                phase: .live,
                tone: .neutral,
                label: publicS.title,
                meaning: publicS.detail ?? "",
                nextAction: publicS.safeNextAction
            )
        }
        // Network-ready: fold in the reward/blocker reason model so the card and
        // header agree with the Mining/reward truth, not just the trust tier.
        let mining = miningHealth(s)
        let tierPhase: ConsolidatedStatus.Phase = s.trustTier == .trusted ? .earning : .live
        let tierLabel = s.trustTier == .trusted ? "Earning · Trusted" : "Live · Provisional"

        switch mining.reasonCode {
        case "earning", "trusted_withdrawable":
            // Only claim withdrawals unlocked for a Trusted provider with no
            // blocking verdict (this branch); caps/holds fall through below.
            let meaning = s.trustTier == .trusted
                ? "This Mac is approved and earning. MALIBU withdrawals are unlocked."
                : "This Mac is live and earning. MALIBU withdrawals unlock once you reach Trusted."
            return ConsolidatedStatus(
                phase: tierPhase, tone: .positive, label: tierLabel,
                meaning: meaning, nextAction: liveNextAction(s)
            )
        case "idle_no_work", "eligible_waiting_settlement", "customer_availability_pending":
            return ConsolidatedStatus(
                phase: tierPhase, tone: .neutral, label: tierLabel,
                meaning: mining.reason, nextAction: liveNextAction(s)
            )
        case "wallet_missing":
            return ConsolidatedStatus(
                phase: tierPhase, tone: .neutral, label: tierLabel,
                meaning: mining.reason, nextAction: mining.nextAction
            )
        case "reward_projection_warming_up", "trust_tier_provisional":
            return ConsolidatedStatus(
                phase: .live, tone: .neutral, label: "Live · Provisional",
                meaning: mining.reason, nextAction: mining.nextAction
            )
        case "wallet_daily_cap_held", "provider_daily_cap_held", "rewards_held":
            // A hold/cap: keep the tier label but never claim "unlocked"; carry
            // the specific reason and its one next action.
            return ConsolidatedStatus(
                phase: tierPhase, tone: .neutral, label: tierLabel,
                meaning: mining.reason, nextAction: mining.nextAction
            )
        case "reward_projection_unavailable", "reward_epoch_disposition":
            // A reward-telemetry outage or a past-epoch disposition is not the
            // provider's fault and needs no action. Surface it honestly with a
            // neutral tone — never a false-positive "earning", never a red
            // alarm. The USDC earnings display stays truthful separately.
            return ConsolidatedStatus(
                phase: .live, tone: .neutral, label: mining.status,
                meaning: mining.reason, nextAction: mining.nextAction
            )
        default:
            // Local blocks (battery/thermal/preparing), telemetry unavailable,
            // compute-integrity / untrusted-token, ineligible, and any future
            // blocker read as needs-attention with the concrete recovery action.
            return ConsolidatedStatus(
                phase: .needsAttention, tone: .attention, label: mining.status,
                meaning: mining.reason, nextAction: mining.nextAction
            )
        }
    }

    private static func liveNextAction(_ s: AgentSnapshot) -> String? {
        if s.walletBound == false {
            return "Add a payout wallet to receive earnings."
        }
        if s.trustTier == .provisional {
            return trustCriteriaAction(s) ?? "Stay online to reach Trusted and unlock withdrawals."
        }
        return nil
    }

    private static func isModelPreparing(_ s: AgentSnapshot) -> Bool {
        switch s.lifecycleState {
        case "installing", "importing_credentials", "starting_provider",
             "validating_catalog", "loading_model", "locally_ready_connecting",
             "update_in_progress", "rollback_in_progress":
            return true
        default:
            break
        }
        return s.state == .starting
    }

    private static func isWaitingForNetworkApproval(_ s: AgentSnapshot) -> Bool {
        guard !s.isHoldingBuyerServingReady() else { return false }
        guard s.isLocalStatusObservationCurrent() else { return false }
        guard s.currentModelID != nil || s.state == .serving || s.state == .reconnecting else {
            return false
        }
        switch s.networkState {
        case "live_verified":
            return true
        case "buyer_serving_unknown":
            return s.statusObservationFresh != false
        default:
            return false
        }
    }

    private static func isCheckingCustomerAvailability(_ s: AgentSnapshot) -> Bool {
        guard !s.isHoldingBuyerServingReady() else { return false }
        guard s.state == .serving || s.state == .reconnecting else { return false }
        if s.networkState == nil { return true }
        return s.networkState == "buyer_serving_unknown"
            && (s.statusObservationFresh == false || !s.isLocalStatusObservationCurrent())
    }

    private static func isTemporarilyNotBuyerServing(_ s: AgentSnapshot) -> Bool {
        guard s.state == .serving || s.state == .reconnecting else { return false }
        return s.networkState == "not_buyer_serving"
    }

    private static func isSoftwareUpdateRequired(_ s: AgentSnapshot) -> Bool {
        // Reason-specific #582 outcomes reuse catalog_incompatible on the v1
        // wire; do not collapse them into generic software-update guidance.
        if isHardwareEvidenceRejected(s) || isUncataloguedModel(s) {
            return false
        }
        if s.networkState == "catalog_update_required" || compatibilityRepairAvailable(s) {
            return true
        }
        return s.lifecycleState == "catalog_incompatible" && s.isLocalStatusObservationCurrent()
    }

    private static func isPendingHardwareVerification(_ s: AgentSnapshot) -> Bool {
        guard s.isLocalStatusObservationCurrent() else { return false }
        return s.lifecycleReason == "autotune_evidence_required"
    }

    private static func isHardwareEvidenceRejected(_ s: AgentSnapshot) -> Bool {
        guard s.isLocalStatusObservationCurrent() else { return false }
        switch s.lifecycleReason {
        case "autotune_evidence_invalid", "autotune_evidence_binary_version_mismatch", "autotune_model_cap_exceeded":
            return true
        default:
            return false
        }
    }

    private static func isUncataloguedModel(_ s: AgentSnapshot) -> Bool {
        guard s.isLocalStatusObservationCurrent() else { return false }
        return s.lifecycleReason == "autotune_model_uncatalogued"
    }

    private static func isIneligibleForCustomerWork(_ s: AgentSnapshot) -> Bool {
        switch s.networkState {
        case "local_donor", "safe_offline_fallback", "catalog_integrity_failure":
            return true
        default:
            return false
        }
    }

    static func short(_ s: AgentSnapshot, at now: Date = Date()) -> String {
        switch s.state {
        case .idle: return s.lifecycleState == "uninstalled" ? "Uninstalled" : "Stopped"
        case .starting: return "Starting"
        case .serving:
            guard isNetworkReady(s, at: now) else { return "Connected" }
            if let usdc = s.earningsUsdcToday { return formatUSDC(usdc) }
            return "Serving"
        case .paused:         return "Paused"
        case .reconnecting:
            if isPendingHardwareVerification(s) { return "Pending" }
            if isHardwareEvidenceRejected(s) { return "Ineligible" }
            return s.networkState == "network_offline" || s.lifecycleState == "network_offline"
                ? "Offline" : "Reconnect"
        case .error:
            if isPendingHardwareVerification(s) { return "Pending" }
            if isHardwareEvidenceRejected(s) { return "Ineligible" }
            switch s.lifecycleState {
            case "authentication_required": return "Auth"
            case "keychain_unavailable": return "Keychain"
            case "identity_migration_required": return "Identity"
            case "catalog_incompatible": return "Catalog"
            default: return "Failed"
            }
        }
    }

    private static func idleEarningsAreZero(_ s: AgentSnapshot) -> Bool {
        (s.earningsUsdcToday ?? 0) == 0
    }

    static func stateLine(_ s: AgentSnapshot) -> String {
        // Prefer reason-first public titles for #582 onboarding outcomes so the
        // reused v1 lifecycle state labels do not override them in the menu.
        if isPendingHardwareVerification(s)
            || isHardwareEvidenceRejected(s)
            || isUncataloguedModel(s) {
            return publicStatus(s).title
        }
        switch s.state {
        case .idle:         return authoritativeLifecycleLabel(s) ?? "Provider stopped"
        case .starting:     return authoritativeLifecycleLabel(s) ?? "Starting provider…"
        case .serving:
            if isNetworkReady(s) {
                return "Provider is ready" + (s.currentModelID.map { " · \($0)" } ?? "")
            }
            return publicStatus(s).title
        case .paused:       return "Paused"
        case .reconnecting:
            if let label = authoritativeLifecycleLabel(s) {
                return label
            }
            if isLocalOnly(s) {
                return publicStatus(s).title + " · " + (s.currentModelID ?? "model loaded")
            }
            return "Reconnecting…"
        case .error:        return authoritativeLifecycleLabel(s) ?? publicErrorDetail(s.lastError) ?? "Provider failed"
        }
    }

    static func earningsLine(_ s: AgentSnapshot) -> String {
        if !s.providerEarningsFresh || !s.malibuProjectionFresh {
            if !canShowLastKnownUSDC(s), s.malibuAccruedToday == nil {
                return isActive(s) ? "Today: reward status unavailable" : "Today: not running"
            }
            let usdc = canShowLastKnownUSDC(s)
                ? s.earningsUsdcToday.map { formatUSDC($0) } ?? "n/a"
                : "n/a"
            let malibu = s.malibuProjectionFresh
                ? malibuTodayLine(s, compact: false)
                : "MALIBU reward status unavailable"
            return "Today: \(usdc) USDC · \(malibu)"
        }
        switch (s.earningsUsdcToday, s.malibuAccruedToday) {
        case (nil, nil):
            return isActive(s) ? "Today: reward status unavailable" : "Today: not running"
        case let (usdc?, malibu?):
            return "Today: \(formatUSDC(usdc)) USDC · \(malibuDisplay(malibu, snapshot: s))"
        case let (usdc?, nil):
            return "Today: \(formatUSDC(usdc)) USDC · \(malibuTodayLine(s, compact: false))"
        case let (nil, malibu?):
            return "Today: n/a USDC · \(malibuDisplay(malibu, snapshot: s))"
        }
    }

    /// Priority-ordered explanation for why a serving provider is not
    /// currently earning, sourced from the last-hour idle-prewarm skip
    /// counts. Gated by `providerEarningsFresh` since idle-prewarm data
    /// arrives on the same projection as the other earnings fields.
    static func eligibilityLine(_ s: AgentSnapshot) -> String? {
        if let eligibility = displayRewardEligibility(s) {
            return rewardEligibilityLine(eligibility)
        }
        guard s.providerEarningsFresh else { return nil }
        let skips = s.idlePrewarmSummary.skipsByReasonLast1h
        if (skips["on_battery"] ?? 0) > 0 {
            return "On battery — plug in to earn"
        }
        if (skips["thermal_pressure"] ?? 0) > 0 {
            return "Thermal throttle — waiting to cool before earning"
        }
        if (skips["model_not_loaded"] ?? 0) > 0 {
            return "Model is preparing — earning starts when ready"
        }
        if (s.queueDepth ?? 0) > 0 {
            return "Work is queued on this Mac"
        }
        if isNetworkReady(s) || s.state == .serving {
            if (s.requestsServedToday ?? 0) > 0, idleEarningsAreZero(s) {
                return "Work ran today · paid credits show when a job settles"
            }
            return "Eligible · network is quiet"
        }
        return nil
    }

    static func backlogLine(_ s: AgentSnapshot) -> String? {
        guard s.providerEarningsFresh,
              s.malibuProjectionFresh,
              s.walletBound == false,
              let usdc = s.unpaidLedgerBacklogUSDC,
              let malibu = s.unpaidLedgerBacklogMALIBU,
              usdc + malibu > 0 else {
            return nil
        }
        return String(format: "Unclaimed: $%.2f USDC · %@", usdc, malibuDisplay(malibu, snapshot: s))
    }

    static func modelLine(_ s: AgentSnapshot) -> String {
        if let model = s.currentModelID { return model }
        if isNetworkReady(s) { return "Connected" }
        if isPendingHardwareVerification(s) { return "Waiting for verification" }
        if isHardwareEvidenceRejected(s) { return "Evidence rejected" }
        if isLocalOnly(s) { return "Local only" }
        return isActive(s) ? "Connected" : "Not running"
    }

    static func credentialLine(_ s: AgentSnapshot) -> String {
        guard s.isCredentialStatusCurrent() else {
            return "Provider access expired · checking again"
        }
        switch s.credentialState {
        case "ready":
            return s.credentialRestartSafe == true
                ? "Ready · safe after restart"
                : "Ready · restart safety not confirmed"
        case "missing":
            return s.credentialRecoveryAction == "repair_from_protected_source"
                ? "Missing · recovery available"
                : "Missing · restore access or set up again"
        case "locked":
            return "Login Keychain locked · unlock and retry"
        case "not_logged_in":
            return "Login Keychain unavailable · sign in and retry"
        case "permission_denied":
            return "Keychain access denied · authorize the provider"
        case "corrupt":
            return s.credentialRecoveryAction == "repair_from_protected_source"
                ? "Damaged · recovery available"
                : "Damaged · restore access or set up again"
        case "conflict":
            return "Provider access conflict · automatic repair refused"
        case "keychain_failure":
            return "Keychain database failure · repair Keychain before retrying"
        case "incompatible":
            return "Provider software lacks Keychain access · update or reinstall"
        case "degraded":
            return "Degraded · using a compatibility source"
        case "unavailable":
            return "Keychain unavailable · retry"
        case "unconfigured":
            return "Not configured"
        case .some(let state):
            return "Unknown provider access condition (\(state))"
        case nil:
            return "Not reported by this provider version"
        }
    }

    static func canRepairCredential(_ s: AgentSnapshot) -> Bool {
        s.isCredentialStatusCurrent()
            && s.credentialRecoveryAction == "repair_from_protected_source"
            && !s.credentialRepairInProgress
    }

    static func admissionIdentityLine(_ s: AgentSnapshot) -> String {
        if s.admissionIdentityRecoveryJournalState == "approval_required" {
            let candidate = abbreviatedDigest(
                s.admissionIdentityPendingPublicKeySHA256 ?? s.admissionIdentityPublicKeySHA256
            )
            return "Approval required · candidate \(candidate) · ask support to approve, then activate in Malibu"
        }
        if s.admissionIdentityRecoveryJournalState == "committed_cleanup" {
            return "Recovery approved · finish activation in Malibu"
        }
        guard s.isLocalStatusObservationCurrent() else {
            return "Network verification expired · checking again"
        }
        switch (s.admissionIdentityState, s.coordinatorIdentityAdmissionMode) {
        case ("ready", "signature"):
            return "Ready · verified by this Mac"
        case ("ready", "exemption"):
            return "Ready locally · temporary network approval active"
        case ("ready", _):
            return "Ready locally · network approval pending"
        case ("missing", _):
            return "Missing · restore verification or set up again"
        case ("recovery_pending", _):
            let candidate = abbreviatedDigest(s.admissionIdentityPendingPublicKeySHA256 ?? s.admissionIdentityPublicKeySHA256)
            return "Approval required · candidate \(candidate) · ask support to approve, then activate in Malibu"
        case ("degraded_previous_key", _):
            let deadline = s.admissionIdentityPreviousValidUntil.map(ISO8601DateFormatter().string(from:))
                ?? "expiry unknown"
            return "Using previous verification until \(deadline) · repair network verification"
        case ("recovery_required", _):
            return "Recovery required · repair network verification"
        case ("unconfigured", _), (nil, _):
            return "Not reported by this provider version"
        case (.some(let state), _):
            return "Network verification condition: \(state)"
        }
    }

    static func canRepairAdmissionIdentity(_ s: AgentSnapshot) -> Bool {
        guard !s.admissionIdentityRecoveryInProgress else { return false }
        if ["approval_required", "committed_cleanup"]
            .contains(s.admissionIdentityRecoveryJournalState) {
            return true
        }
        guard s.isLocalStatusObservationCurrent() else { return false }
        return ["degraded_previous_key", "missing", "recovery_required", "recovery_pending"]
            .contains(s.admissionIdentityState)
    }

    static func admissionIdentityRepairButtonTitle(_ s: AgentSnapshot) -> String {
        if ["approval_required", "committed_cleanup"]
            .contains(s.admissionIdentityRecoveryJournalState)
            || s.admissionIdentityState == "recovery_pending" {
            return "Activate approved verification"
        }
        return "Repair network verification"
    }

    static func admissionIdentityRecoveryConfigError(
        expectedProviderID: String?,
        configuredProviderID: String?
    ) -> String? {
        guard let expectedProviderID, !expectedProviderID.isEmpty else {
            return "Network verification repair requires the current provider ID."
        }
        guard let configuredProviderID, !configuredProviderID.isEmpty else {
            return "Network verification repair requires provider_id \(expectedProviderID) in ~/.config/macprovider/config.yaml."
        }
        guard configuredProviderID == expectedProviderID else {
            return "Network verification repair refused because config provider_id \(configuredProviderID) does not match the active provider \(expectedProviderID)."
        }
        return nil
    }

    private static func abbreviatedDigest(_ digest: String?) -> String {
        guard let digest, digest.count >= 12 else { return digest ?? "unknown" }
        return String(digest.prefix(12)) + "…"
    }

    static func statusContractLine(_ s: AgentSnapshot) -> String {
        if s.localStatusContractCompatible == false {
            return "Incompatible · update Malibu"
        }
        if !s.isLocalStatusObservationCurrent() {
            return "Compatible · checking again"
        }
        guard let version = s.localStatusContractVersion else {
            return "Older provider status"
        }
        let owner = s.localStatusLifecycleOwner ?? "owner not reported"
        return "v\(version) · \(owner)"
    }

    static func serviceInstanceLine(_ s: AgentSnapshot) -> String? {
        guard s.isLocalStatusObservationCurrent() else { return nil }
        guard let instanceID = s.serviceInstanceID else { return nil }
        let shortID = String(instanceID.prefix(8))
        var parts = [s.serviceRole ?? "serve"]
        if let pid = s.servicePID {
            parts.append("PID \(pid)")
        }
        parts.append(shortID)
        return parts.joined(separator: " · ")
    }

    static func lifecycleLine(_ s: AgentSnapshot) -> String? {
        guard s.isLocalStatusObservationCurrent() else { return nil }
        if s.lifecycleLeaseState == "active" {
            let label = s.lifecycleLeaseKind == "maintenance" ? "Update or repair in progress" : "Starting provider"
            if let operation = s.lifecycleLeaseOperationID {
                return "\(label) · \(operation.replacingOccurrences(of: "_", with: " "))"
            }
            return label
        }
        if s.lifecycleLeaseState == "invalid" {
            return "Provider recovery status needs a restart"
        }
        if s.lifecycleRecordState == "missing" {
            return "Provider history missing · restart required"
        }
        if s.lifecycleRecordState == "invalid" {
            return "Provider history invalid · restart required"
        }
        // Keep Advanced diagnostics aligned with public #582 titles/actions.
        if let outcome = hardwareOnboardingLifecycleLine(s) {
            return outcome
        }
        guard let state = s.lifecycleState else { return nil }
        let label = lifecycleStateLabel(state)
        var parts = [label]
        if let reason = s.lifecycleReason {
            parts.append(publicReason(reason))
        }
        if let guidance = lifecycleGuidance(state) {
            parts.append(guidance)
        }
        return parts.joined(separator: " · ")
    }

    private static func hardwareOnboardingLifecycleLine(_ s: AgentSnapshot) -> String? {
        if isPendingHardwareVerification(s) {
            return "Pending hardware verification · Usually under an hour · keep online"
        }
        if isHardwareEvidenceRejected(s) {
            if s.lifecycleReason == "autotune_model_cap_exceeded" {
                return "Not eligible: admission evidence failed · Retry setup to apply a smaller admitted model"
            }
            return "Not eligible: admission evidence failed · Retry provider setup while online"
        }
        if isUncataloguedModel(s) {
            return "This Mac is not currently eligible · Retry setup to apply a supported model"
        }
        return nil
    }

    static func lifecycleEventLine(_ event: ProviderLifecycleEventSnapshot) -> String {
        var parts = [publicReason(event.reason)]
        parts.append(lifecycleStateLabel(event.state))
        return parts.joined(separator: " · ")
    }

    static func lifecycleEventDisplay(_ event: ProviderLifecycleEventSnapshot) -> String {
        "\(lifecycleEventLine(event)) · \(event.transitionAt.formatted(date: .abbreviated, time: .shortened))"
    }

    static func advertisedCapacityLine(_ s: AgentSnapshot) -> String {
        let capacity = s.advertisedMaxConcurrency.map { value in
            "\(value) buyer slot\(value == 1 ? "" : "s")"
        } ?? "Capacity not reported"
        switch s.networkState {
        case "buyer_serving":
            return "\(capacity) · available to customers"
        case "buyer_serving_unknown", nil:
            return "\(capacity) · availability unconfirmed"
        default:
            return "\(capacity) · not available to customers"
        }
    }

    private static func lifecycleStateLabel(_ state: String) -> String {
        switch state {
        case "installing": return "Installing provider"
        case "importing_credentials": return "Importing credentials"
        case "starting_provider": return "Starting provider"
        case "validating_catalog": return "Checking provider software"
        case "loading_model": return "Model is preparing"
        case "locally_ready_connecting": return "Waiting for network approval"
        case "authentication_required": return "Authentication missing or expired"
        case "keychain_unavailable": return "Keychain locked or permission denied"
        case "identity_migration_required": return "Network verification needs repair"
        case "catalog_incompatible": return "Provider software update required"
        case "serving_buyers": return "Provider is ready"
        case "update_in_progress": return "Update in progress"
        case "rollback_in_progress": return "Rollback in progress"
        case "paused_by_operator": return "Paused by operator"
        case "watchdog_recovery": return "Provider recovery"
        case "network_offline": return "Network offline"
        case "coordinator_unavailable": return "Network unavailable"
        case "degraded_serving": return "Provider ready with limited capacity"
        case "busy": return "busy"
        case "failed": return "Failed"
        case "uninstalled": return "Uninstalled"
        default: return "Provider status update"
        }
    }

    private static func lifecycleGuidance(_ state: String) -> String? {
        switch state {
        case "authentication_required":
            return "Use Repair credential"
        case "keychain_unavailable":
            return "Unlock or authorize Keychain, then retry Repair credential"
        case "identity_migration_required":
            return "Use Repair network verification"
        case "catalog_incompatible":
            return "Install latest provider software, then retry"
        case "paused_by_operator":
            return "Choose Resume when ready"
        case "network_offline":
            return "Restore network; reconnect is automatic"
        case "coordinator_unavailable":
            return "Reconnect is automatic"
        case "watchdog_recovery", "update_in_progress", "rollback_in_progress":
            return "No action required while this completes"
        case "failed":
            return "Use the offered Repair action or export redacted diagnostics"
        default:
            return nil
        }
    }

    static func compatibilitySetLine(_ s: AgentSnapshot) -> String {
        if let target = updateTargetVersion(s) {
            return "Update to v\(target) available"
        }
        if compatibilityRepairAvailable(s) {
            return "Update required"
        }
        guard let current = s.cliVersion else {
            return "Status not reported"
        }
        return "v\(current) · up to date"
    }

    static func requestsLine(_ s: AgentSnapshot) -> String {
        [
            s.requestsServedToday.map { "\(formatCount($0)) today" }
                ?? (isActive(s) ? "0 today" : "n/a today"),
            s.requestsServedAllTime.map { "\(formatCount($0)) all-time" }
                ?? (isActive(s) ? "0 all-time" : "n/a all-time"),
            s.requestsPerMinute.map { String(format: "%.1f req/min", $0) }
                ?? (isActive(s) ? "0.0 req/min" : "n/a req/min")
        ].joined(separator: " · ")
    }

    static func tokenLine(_ s: AgentSnapshot) -> String {
        let today = tokenPair(input: s.inputTokensToday, output: s.outputTokensToday, suffix: "today")
        let allTime = tokenPair(input: s.inputTokensAllTime, output: s.outputTokensAllTime, suffix: "all-time")
        return "\(today)\n\(allTime)"
    }

    /// Whether a MISSING USDC sub-total may be rendered as an authoritative
    /// $0.00. Only a brand-new fresh frame reporting NONE of the four totals is a
    /// real all-zero state; a fresh frame reporting some-but-not-all is anomalous
    /// (partial), and a stale/last-known frame did not report the field. In
    /// those cases missing fields are shown as non-authoritative, never $0.00 —
    /// so no surface prints a fabricated zero (or an impossible "life < today").
    /// Shared by usdcFullLine, usdcTodayDisplay, and miningRewardSummary so the
    /// three USDC surfaces always agree.
    private static func usdcFreshZeroAllowed(_ s: AgentSnapshot) -> Bool {
        guard s.providerEarningsFresh else { return false }
        let totals = [s.earningsUsdcToday, s.earningsUsdcWeek, s.earningsUsdcPending, s.earningsUsdcLifetime]
        let presentCount = totals.filter { $0 != nil }.count
        return presentCount == 0 || presentCount == totals.count
    }

    static func usdcFullLine(_ s: AgentSnapshot) -> String {
        // Genuine telemetry failure: keep it small and calm, not four "n/a"s.
        if !canShowLastKnownUSDC(s) {
            return "Earnings not available yet"
        }
        let zerosWhenMissing = usdcFreshZeroAllowed(s)
        func field(_ value: Double?, _ suffix: String) -> String {
            if let value { return "\(formatUSDC(value)) \(suffix)" }
            return zerosWhenMissing ? "\(formatUSDC(0)) \(suffix)" : "not reported \(suffix)"
        }
        return [
            field(s.earningsUsdcToday, "today"),
            field(s.earningsUsdcWeek, "wk"),
            field(s.earningsUsdcPending, "accrued"),
            field(s.earningsUsdcLifetime, "life")
        ].joined(separator: " · ")
    }

    /// Caption for the accrued amount in `usdcFullLine`, kept on its own line
    /// so the full line stays scannable.
    static func usdcAccrualCaption(_ s: AgentSnapshot) -> String? {
        guard s.providerEarningsFresh, s.earningsUsdcPending != nil else { return nil }
        return "Accrued — payouts open in beta"
    }

    static func usdcTodayDisplay(_ s: AgentSnapshot) -> String {
        // Non-hero placeholder for genuine unavailability; the hero number must
        // never fabricate an authoritative "$0.00" from missing telemetry.
        guard canShowLastKnownUSDC(s) else {
            return "—"
        }
        if let today = s.earningsUsdcToday {
            return formatUSDC(today)
        }
        // Today missing: only a brand-new all-zero fresh frame is a real $0.00;
        // a partial/stale frame shows the non-authoritative placeholder so the
        // hero, full line, and reward summary agree.
        return usdcFreshZeroAllowed(s) ? formatUSDC(0) : "—"
    }

    static func malibuFullLine(_ s: AgentSnapshot) -> String {
        if !s.malibuProjectionFresh {
            return "MALIBU rewards not available yet"
        }
        // A fresh-but-unavailable verdict with NO concrete amounts must not
        // render "n/a MALIBU today · n/a all-time · …" — that is the exact
        // failure copy this rework removes. Collapse it to one calm line. When
        // real amounts ARE present, keep showing them below with an honest
        // "reward status unavailable" suffix rather than hiding known data.
        if isRewardTelemetryUnavailable(s) {
            let hasAmounts = s.malibuAccruedToday != nil
                || (s.malibuAccruedAllTime ?? 0) != 0
                || s.malibuWithdrawable != nil
                || s.malibuHeld != nil
            if !hasAmounts {
                return "MALIBU reward status unavailable"
            }
        }
        let today = malibuTodayLine(s, compact: true)
        let allTime = s.malibuAccruedAllTime.map { String(format: "%.2f all-time", $0) }
            ?? "n/a all-time"
        if let eligibility = displayRewardEligibility(s) {
            switch eligibility.withdrawalState {
            case "withdrawable":
                return "\(today) · \(allTime)"
            default:
                return "\(today) · \(allTime) · \(rewardEligibilityShortCopy(eligibility))"
            }
        }
        switch s.trustTier {
        case .trusted:
            return "\(today) · \(allTime)"
        case .provisional:
            return "\(today) · \(allTime) · [locked] unlocks at Trusted"
        }
    }

    private static func malibuTodayLine(_ s: AgentSnapshot, compact: Bool) -> String {
        if let malibu = s.malibuAccruedToday {
            return malibuDisplay(malibu, snapshot: s, compact: compact)
        }
        if s.malibuAccruedAllTime != nil || s.malibuWithdrawable != nil || s.malibuHeld != nil {
            return "MALIBU daily not reported yet"
        }
        return compact ? "n/a MALIBU today" : "n/a MALIBU"
    }

    static func malibuAvailabilityLine(_ s: AgentSnapshot) -> String? {
        guard s.malibuProjectionFresh,
              s.malibuWithdrawable != nil || s.malibuHeld != nil else { return nil }
        let withdrawable: String
        if let eligibility = displayRewardEligibility(s) {
            withdrawable = malibuWithdrawableDisplay(s.malibuWithdrawable, eligibility: eligibility)
        } else {
            withdrawable = s.malibuWithdrawable.map { String(format: "%.2f available", $0) } ?? "n/a available"
        }
        let held = s.malibuHeld.map { String(format: "%.2f held", $0) } ?? "n/a held"
        return "MALIBU: \(withdrawable) · \(held)"
    }

    private static func malibuWithdrawableDisplay(_ amount: Double?, eligibility: MalibuRewardEligibility) -> String {
        switch eligibility.withdrawalState {
        case "withdrawable":
            return amount.map { String(format: "%.2f available", $0) } ?? "n/a available"
        case "held":
            return "not withdrawable"
        case "capped":
            return "withdrawal capped"
        case "ineligible":
            return "not eligible"
        case "unavailable":
            return "status unavailable"
        default:
            return "status unavailable"
        }
    }

    static func malibuHoldLine(_ s: AgentSnapshot) -> String? {
        if let eligibility = displayRewardEligibility(s),
           eligibility.withdrawalState != "withdrawable" {
            return "MALIBU status: \(rewardReasonCopy(eligibility.primaryReason)). Next: \(rewardReasonNextAction(eligibility.primaryReason))"
        }
        let holdReasons = displayMalibuHoldReasons(s)
        guard s.malibuProjectionFresh, !holdReasons.isEmpty else { return nil }
        let reasons = holdReasons.map { malibuHoldReasonCopy($0) }
        let nextAction: String
        let trustProgress = distinctPairProgress(s)
        if holdReasons.contains("trust_tier_provisional"), trustProgress.required > trustProgress.met {
            // Use the same distinct-pair progress as trustLine (SPEC-026 §5.2):
            // overlapping E2/A3 or duplicate criteria must not read as complete via
            // raw met/required counters.
            nextAction = "Complete \(trustProgress.required - trustProgress.met) more trust criteria to unlock withdrawals."
        } else if holdReasons.contains("per_wallet_daily_cap") {
            nextAction = "The wallet cap resets at the next UTC day."
        } else if holdReasons.contains("demotion_cooldown") {
            nextAction = "Keep Malibu online; withdrawals unlock automatically when Trusted."
        } else {
            nextAction = "Review the hold reason above before withdrawing."
        }
        return "Held because: \(reasons.joined(separator: "; ")) Next: \(nextAction)"
    }

    static func trustLine(_ s: AgentSnapshot) -> String {
        guard s.malibuProjectionFresh else { return "MALIBU trust telemetry not published yet" }
        if isRewardTelemetryUnavailable(s) { return "Trust status temporarily unavailable" }
        let tier = s.trustTier.rawValue.capitalized
        if hasDemotionCooldown(s) {
            return "\(tier) — Trust review in progress"
        }
        if s.trustTier == .trusted {
            return "Trusted"
        }
        let progress = distinctPairProgress(s)
        return "\(tier) — \(progress.met) of \(progress.required) criteria met"
    }

    /// What reaching Trusted grants, in plain language. Used by the trust-tier
    /// disclosure so "Unlock Trusted" leads somewhere concrete.
    static func trustUnlockSummary(_ s: AgentSnapshot) -> String {
        if s.trustTier == .trusted {
            // Trusted tier is reached, but withdrawals still follow the current
            // authoritative reward status: a cap/hold/epoch disposition must not be
            // hidden behind a blanket "unlocked". Only claim unlocked when the
            // eligibility verdict is withdrawable (or absent).
            if let eligibility = displayRewardEligibility(s),
               eligibility.withdrawalState != "withdrawable" {
                return "Trusted — withdrawals follow current reward status: \(sentence(rewardReasonCopy(eligibility.primaryReason)))"
            }
            return "Trusted — MALIBU withdrawals are unlocked."
        }
        return "Reaching Trusted unlocks MALIBU reward withdrawals. USDC earnings are unaffected."
    }

    /// A single trust criterion rendered with a done/pending state and a plain
    /// next step. Kept view-agnostic so the disclosure and tests share one
    /// source of truth.
    struct TrustCriterion: Equatable {
        let title: String
        let done: Bool
        let detail: String
    }

    // Criterion IDs mirror SPEC-026 §5.2 (see phase4-coordinator/internal/
    // rewards/unlock.go). E1 verified receipts / E2 wallet balance 72h /
    // E3 operator promotion are economic; A1 time online / A3 wallet balance
    // 72h / A4 App Attest are additional.
    private static func criterionName(_ id: String) -> String {
        switch id {
        case "E1": return "100 verified customer jobs"
        case "E2": return "wallet balance held 72h"
        case "E3": return "operator promotion"
        case "A1": return "72 hours online"
        case "A3": return "wallet balance held 72h"
        case "A4": return "App Attest verification"
        // Never render an unknown/crafted criterion ID raw: a malformed control
        // frame could smuggle a token/path/host string into dashboard text.
        default: return "additional requirement"
        }
    }

    // Port of the coordinator's overlap rule (unlock.go criteriaOverlap):
    // identical IDs, or the E2/A3 wallet-balance pair, do NOT count as two
    // distinct unlock slots.
    private static func criteriaOverlap(_ economic: String, _ additional: String) -> Bool {
        if economic == additional { return true }
        if (economic == "E2" && additional == "A3") || (economic == "A3" && additional == "E2") {
            return true
        }
        return false
    }

    // Port of unlock.go distinctUnlockPair: a valid Trusted unlock needs one
    // economic and one additional criterion that do not overlap. This is an
    // EXISTENCE check over pairs — not "additional distinct from every economic"
    // — so E1,E2 economic + E1,A3 additional pairs E1+A3 (or E2+A?) and counts.
    private static func hasDistinctUnlockPair(_ economic: [String], _ additional: [String]) -> Bool {
        for e in economic {
            for a in additional where !criteriaOverlap(e, a) {
                return true
            }
        }
        return false
    }

    /// True when the additional slot is satisfied in its own right. With at
    /// least one economic criterion present, this mirrors the coordinator's
    /// distinct-pair EXISTENCE rule (there exists an economic+additional pair
    /// that does not overlap). With no economic criterion yet, any additional
    /// criterion (e.g. A4 App Attest alone) counts as done for its row — the
    /// provider genuinely completed one of the two displayed slots.
    private static func additionalSlotDone(_ s: AgentSnapshot) -> Bool {
        if s.economicCriteria.isEmpty { return !s.additionalCriteria.isEmpty }
        return hasDistinctUnlockPair(s.economicCriteria, s.additionalCriteria)
    }

    /// Progress across the two displayed unlock slots (economic + distinct
    /// additional). Deliberately ignores the raw `trust_criteria_met` unique-ID
    /// count, which can read "2 of 2" for an overlapping E2/A3 or a duplicate E1
    /// that does NOT satisfy two distinct slots. For a legacy frame that carried
    /// no granular criterion IDs, the by-name model cannot be computed, so it
    /// falls back to the raw coordinator counters rather than an empty "0 of 2".
    static func distinctPairProgress(_ s: AgentSnapshot) -> (met: Int, required: Int) {
        guard s.hasGranularTrustCriteria else {
            let required = s.trustCriteriaRequired ?? 2
            let met = min(max(s.trustCriteriaMet ?? 0, 0), required)
            return (met, required)
        }
        let economicDone = !s.economicCriteria.isEmpty
        return ((economicDone ? 1 : 0) + (additionalSlotDone(s) ? 1 : 0), 2)
    }

    private static func distinctAdditionalName(_ s: AgentSnapshot) -> String {
        // Name the additional criterion that forms the distinct pair (pairs with
        // some economic criterion), or, when no economic criterion is present
        // yet, the first satisfied additional criterion.
        for a in s.additionalCriteria
        where s.economicCriteria.isEmpty
            || s.economicCriteria.contains(where: { !criteriaOverlap($0, a) }) {
            return criterionName(a)
        }
        return "an additional criterion"
    }

    /// The two Trusted unlock slots (one economic + one DISTINCT additional per
    /// SPEC-026 §5.2), rendered by their real satisfied criteria. `nil` until a
    /// fresh MALIBU projection with a real verdict is available. An overlapping
    /// E2/A3 or a duplicate E1 leaves the second slot PENDING, matching the
    /// coordinator's unlock rule. No granular uptime countdown exists
    /// end-to-end yet, so the pending additional slot says "just stay online".
    // TODO: render an "Nh of 72h" countdown once the coordinator exposes a
    // granular uptime-progress field on the reward projection.
    static func trustCriteria(_ s: AgentSnapshot) -> [TrustCriterion]? {
        guard s.malibuProjectionFresh, !isRewardTelemetryUnavailable(s) else { return nil }
        // The by-name disclosure needs the granular criterion IDs. A legacy
        // frame that predates them cannot be rendered faithfully, so hide the
        // per-criterion sheet; the aggregate "N of M" line (distinctPairProgress)
        // still shows via the raw counters.
        guard s.hasGranularTrustCriteria else { return nil }
        let economicDone = !s.economicCriteria.isEmpty
        let additionalDone = additionalSlotDone(s)

        let economicDetail: String
        if economicDone {
            economicDetail = "Done — \(s.economicCriteria.map(criterionName).joined(separator: ", "))."
        } else if let count = s.verifiedReceiptCount, count > 0 {
            economicDetail = "Serve verified customer jobs (\(formatCount(count)) so far), keep a funded wallet 72h, or get operator promotion."
        } else {
            economicDetail = "Serve verified customer jobs, keep a funded wallet 72h, or get operator promotion."
        }

        let additionalDetail: String
        if additionalDone {
            additionalDetail = "Done — \(distinctAdditionalName(s))."
        } else if !s.additionalCriteria.isEmpty {
            // A criterion is satisfied but it overlaps the economic slot (E2/A3)
            // or duplicates E1 — a distinct second criterion is still needed.
            additionalDetail = "Add a criterion distinct from your economic one — stay online 72h or complete App Attest."
        } else {
            additionalDetail = "Nothing to do — just stay online (72h)."
        }

        return [
            TrustCriterion(title: "Economic criterion", done: economicDone, detail: economicDetail),
            TrustCriterion(title: "Distinct additional criterion", done: additionalDone, detail: additionalDetail),
        ]
    }

    static func uptimeLine(_ s: AgentSnapshot) -> String {
        var parts: [String] = []
        if let sec = s.uptimeSec, isActive(s) {
            parts.append("\(formatDuration(sec)) current run")
        } else if isActive(s) {
            parts.append("current run n/a")
        }
        if let pct = s.uptime7dPct {
            parts.append(String(format: "%.1f%% uptime (7d)", pct))
        } else if isActive(s) {
            parts.append("7d uptime n/a")
        }
        parts.append(s.declinedRequests.map { "\($0) declined" } ?? (isActive(s) ? "0 declined" : "n/a declined"))
        parts.append(s.restartCount.map { "\($0) restarts" } ?? (isActive(s) ? "0 restarts" : "n/a restarts"))
        return parts.joined(separator: " · ")
    }

    static func gpuChip(_ s: AgentSnapshot) -> String {
        if let util = s.gpuUtilizationPct {
            return String(format: "GPU %.0f%%", util)
        }
        if let temp = s.gpuTemperatureC {
            return String(format: "GPU %.0f°C", temp)
        }
        return "GPU n/a"
    }

    static func latencyChip(_ s: AgentSnapshot) -> String {
        switch (s.latencyP50Ms, s.latencyP99Ms) {
        case let (p50?, p99?):
            return "p50 \(p50)ms · p99 \(p99)ms"
        case let (p50?, nil):
            return "p50 \(p50)ms · p99 n/a"
        case let (nil, p99?):
            return "p50 n/a · p99 \(p99)ms"
        case (nil, nil):
            return isActive(s) ? "Latency n/a" : "Latency n/a"
        }
    }

    static func queueChip(_ s: AgentSnapshot) -> String {
        if let depth = s.queueDepth { return "\(depth) queued" }
        return isActive(s) ? "0 queued" : "Queue n/a"
    }

    static func thermalChip(_ s: AgentSnapshot) -> String {
        s.thermalState?.label ?? (isActive(s) ? "Thermal OK" : "Thermal n/a")
    }

    static func unclaimedBadge(_ s: AgentSnapshot, dismissedThreshold: Double?) -> String? {
        guard let total = unclaimedBacklogTotal(s),
              let threshold = UnclaimedBadgePolicy.visibleThreshold(
                totalBacklog: total,
                dismissedThreshold: dismissedThreshold
              ) else {
            return nil
        }
        return threshold >= 100 ? "$100+" : String(format: "$%.0f+", threshold)
    }

    static func unclaimedBacklogTotal(_ s: AgentSnapshot) -> Double? {
        guard s.providerEarningsFresh, s.malibuProjectionFresh, s.walletBound == false else { return nil }
        let total = (s.unpaidLedgerBacklogUSDC ?? 0) + (s.unpaidLedgerBacklogMALIBU ?? 0)
        return total > 0 ? total : nil
    }

    static func updateTargetVersion(_ s: AgentSnapshot) -> String? {
        ProviderCLIVersion.updateTarget(
            current: s.cliVersion,
            recommended: s.coordinatorRecommendedVersion,
            latestRelease: s.latestReleaseVersion
        )
    }

    static func updateAvailable(_ s: AgentSnapshot) -> Bool {
        updateTargetVersion(s) != nil || compatibilityRepairAvailable(s)
    }

    static func canRepairProviderSoftware(_ s: AgentSnapshot) -> Bool {
        s.providerSoftwareRepairRecommended
            && ProviderSoftwareRepairCapabilityGate.allowsProtectedSourceRepair(s)
            && !s.providerSoftwareRepairInProgress
            && !s.cliUpdateInProgress
    }

    static func diagnosticFindingLines(_ s: AgentSnapshot) -> [String] {
        s.diagnosticFindings.map { finding in
            let title = diagnosticTitle(finding)
            let cause = diagnosticCause(finding)
            let context = diagnosticContext(finding, snapshot: s)
            return ([title, LogTailBuffer.redacted(finding.userMessage), "Cause: \(cause)"] + context)
                .joined(separator: " · ")
        }
    }

    private static func publicStatusForTopDiagnosticFinding(_ s: AgentSnapshot) -> PublicStatus? {
        guard let finding = s.diagnosticFindings.first(where: { canUseAsPrimaryDiagnosticStatus($0, snapshot: s) }) else {
            return nil
        }
        switch finding.signatureID {
        case .credentialStoreUnavailable:
            return PublicStatus(
                title: "Provider access needs attention",
                detail: LogTailBuffer.redacted(finding.userMessage),
                safeNextAction: canRepairCredential(s)
                    ? "Repair saved access."
                    : "Unlock or authorize saved access, then retry. Your provider identity stays on this Mac.",
                executableAction: canRepairCredential(s) ? .repairCredential : nil
            )
        case .admissionIdentityBlocked:
            return PublicStatus(
                title: "Network verification needs attention",
                detail: LogTailBuffer.redacted(finding.userMessage),
                safeNextAction: canRepairAdmissionIdentity(s)
                    ? "\(admissionIdentityRepairButtonTitle(s))."
                    : "Keep the current provider identity and export diagnostics for support.",
                executableAction: canRepairAdmissionIdentity(s) ? .repairAdmissionIdentity : .exportDiagnostics
            )
        case .autoupdateInProgress:
            return PublicStatus(
                title: "Provider software update in progress",
                detail: LogTailBuffer.redacted(finding.userMessage),
                safeNextAction: "Keep Malibu open. You do not need a new invite."
            )
        case .serveUnresponsive:
            return PublicStatus(
                title: serveUnresponsiveTitle(finding),
                detail: serveUnresponsiveDetail(finding),
                safeNextAction: "Keep Malibu open while status updates. Export diagnostics if this persists.",
                executableAction: .exportDiagnostics
            )
        case .autoupdateHomeACLRejected:
            if canRepairProviderSoftware(s) {
                return PublicStatus(
                    title: "Provider software repair available",
                    detail: "A permission on your home folder blocked automatic update recovery.",
                    safeNextAction: "Repair provider software. Malibu will reinstall the bundled provider software and watchdog. Your provider identity and downloaded models will be kept.",
                    executableAction: .repairProviderSoftware
                )
            }
            return PublicStatus(
                title: "Provider software repair pending",
                detail: "A macOS folder permission blocked automatic update recovery.",
                safeNextAction: "Repair is pending protected delivery. Export diagnostics for support; your provider identity and downloaded models stay on this Mac.",
                executableAction: .exportDiagnostics
            )
        case .staleLaunchAgent:
            return PublicStatus(
                title: "Provider setup needs attention",
                detail: LogTailBuffer.redacted(finding.userMessage),
                safeNextAction: "Use Launch Provider or export diagnostics. Your provider identity and downloaded models stay on this Mac.",
                executableAction: .exportDiagnostics
            )
        case .staleModelCatalog, .catalogAdmission, .rateCardAdmission, .catalogKeyMismatch,
             .missingCatalogProvenance, .missingArtifactSHA, .snapshotPathMismatch:
            return PublicStatus(
                title: "Provider software update needed",
                detail: LogTailBuffer.redacted(finding.userMessage),
                safeNextAction: updateAvailable(s)
                    ? "Install latest provider software. Your provider identity and downloaded models stay on this Mac."
                    : "Export diagnostics for support. Your provider identity and downloaded models stay on this Mac.",
                executableAction: updateAvailable(s) ? .updateProviderSoftware : .exportDiagnostics
            )
        case .artifactHashMismatch, .artifactVerificationFailed:
            return PublicStatus(
                title: "Model verification needs attention",
                detail: LogTailBuffer.redacted(finding.userMessage),
                safeNextAction: "Pick the recommended model again or export diagnostics. Your provider identity stays on this Mac.",
                executableAction: .exportDiagnostics
            )
        case .autoupdateDisabled:
            return PublicStatus(
                title: "Provider automatic updates are disabled",
                detail: LogTailBuffer.redacted(finding.userMessage),
                safeNextAction: "Enable provider software updates, then retry. Your provider identity stays on this Mac.",
                executableAction: .exportDiagnostics
            )
        }
    }

    private static func canUseAsPrimaryDiagnosticStatus(
        _ finding: ProviderDiagnosticFinding,
        snapshot s: AgentSnapshot
    ) -> Bool {
        switch finding.source {
        case .status:
            return true
        case .credentialsStatus:
            return !s.hasFreshServeOwnedCredentialState()
        case .doctorReport, .appPollingHistory, .providerLogDiagnostics:
            return !s.hasFreshContractValidatedStatusObservation()
        }
    }

    private static func diagnosticTitle(_ finding: ProviderDiagnosticFinding) -> String {
        switch finding.signatureID {
        case .credentialStoreUnavailable: return "Provider access"
        case .admissionIdentityBlocked: return "Network verification"
        case .serveUnresponsive: return "Customer availability"
        case .autoupdateInProgress: return "Provider software update"
        case .autoupdateHomeACLRejected: return "Provider software repair pending"
        case .staleLaunchAgent: return "Background service"
        case .staleModelCatalog, .catalogAdmission, .rateCardAdmission, .catalogKeyMismatch,
             .missingCatalogProvenance, .missingArtifactSHA, .snapshotPathMismatch:
            return "Provider software"
        case .artifactHashMismatch, .artifactVerificationFailed:
            return "Model verification"
        case .autoupdateDisabled:
            return "Automatic updates"
        }
    }

    private static func diagnosticCause(_ finding: ProviderDiagnosticFinding) -> String {
        switch finding.signatureID {
        case .serveUnresponsive:
            return hasNetworkStateEvidence(finding) ? "status_context" : "unknown_cause"
        case .autoupdateHomeACLRejected:
            return "repair_delivery_pending"
        default:
            return finding.signatureID.rawValue
        }
    }

    private static func diagnosticContext(
        _ finding: ProviderDiagnosticFinding,
        snapshot s: AgentSnapshot
    ) -> [String] {
        guard finding.signatureID == .serveUnresponsive,
              hasNetworkStateEvidence(finding) else { return [] }
        if let networkState = s.networkState {
            return ["Network context: \(networkStateLabel(networkState))"]
        }
        return []
    }

    private static func serveUnresponsiveTitle(_ finding: ProviderDiagnosticFinding) -> String {
        hasNetworkStateEvidence(finding)
            ? "Customer availability is interrupted"
            : "Provider status is unavailable"
    }

    private static func serveUnresponsiveDetail(_ finding: ProviderDiagnosticFinding) -> String {
        if hasNetworkStateEvidence(finding) {
            return "Provider local status is current, but customer availability is not confirmed. This is context, not a diagnosed root cause."
        }
        return "Malibu cannot confirm current provider status. Cause unknown."
    }

    private static func hasNetworkStateEvidence(_ finding: ProviderDiagnosticFinding) -> Bool {
        finding.evidence?.hasPrefix("network_state=") == true
    }

    private static func networkStateLabel(_ state: String) -> String {
        switch state {
        case "not_buyer_serving": return "not receiving customer work"
        case "buyer_serving_unknown": return "customer availability unknown"
        case "network_offline": return "network offline"
        case "coordinator_unavailable": return "network unavailable"
        default: return state.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func isLiveProviderVisibleDuringSoftwareRepair(_ s: AgentSnapshot) -> Bool {
        s.state == .paused || isNetworkReady(s, at: Date())
    }

    private static func withHomeACLRepairIfNeeded(
        _ status: PublicStatus,
        _ s: AgentSnapshot
    ) -> PublicStatus {
        if canRepairProviderSoftware(s) {
            return PublicStatus(
                title: status.title,
                detail: status.detail,
                safeNextAction:
                    "Repair provider software. Malibu will reinstall the bundled provider software and watchdog. Your provider identity and downloaded models will be kept.",
                executableAction: .repairProviderSoftware
            )
        }
        guard s.diagnosticFindings.contains(where: { $0.signatureID == .autoupdateHomeACLRejected }) else {
            return status
        }
        return PublicStatus(
            title: status.title,
            detail: status.detail,
            safeNextAction: "Provider software repair pending. Export diagnostics for support; your provider identity and downloaded models stay on this Mac.",
            executableAction: .exportDiagnostics
        )
    }

    /// A binary-only legacy update can report the latest CLI version while
    /// still lacking the signed compatibility-set resources. Only a fresh
    /// versioned status observation may expose that repair action; a transient
    /// disconnect clears freshness and must not look like install damage.
    static func compatibilityRepairAvailable(_ s: AgentSnapshot) -> Bool {
        guard s.statusObservationFresh == true,
              let current = s.cliVersion,
              let normalized = ProviderCLIVersion.strictNormalize(current),
              ProviderCLIVersion.compare(
                normalized,
                ProviderCLIVersion.compatibilitySetReleaseFloor
              ) != .ascending else {
            return false
        }
        return s.compatibilitySetID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty != false
    }

    static func updateBadge(_ s: AgentSnapshot) -> String? {
        guard updateAvailable(s), !s.cliUpdateInProgress else { return nil }
        return "↑"
    }

    static func cliVersionLine(_ s: AgentSnapshot) -> String {
        guard let current = s.cliVersion else {
            return isActive(s) ? "Version unknown" : "Not running"
        }
        var parts = ["v\(current)"]
        if let target = updateTargetVersion(s) {
            parts.append("→ v\(target) available")
        } else if compatibilityRepairAvailable(s) {
            parts.append("provider software update required")
        } else if let latest = s.latestReleaseVersion {
            parts.append("latest v\(latest)")
        } else if let recommended = s.coordinatorRecommendedVersion {
            parts.append("network recommends v\(recommended)")
        } else {
            parts.append("up to date")
        }
        return parts.joined(separator: " · ")
    }

    static func cliUpdateStatusLine(_ s: AgentSnapshot) -> String? {
        if s.cliUpdateInProgress {
            return "Installing latest provider software…"
        }
        if s.providerSoftwareRepairInProgress {
            return "Repairing provider software…"
        }
        if let error = s.providerSoftwareRepairLastError {
            return publicErrorDetail(error)
        }
        if let error = s.cliUpdateLastError {
            return publicErrorDetail(error)
        }
        return nil
    }

    static func cliVersionMenuLine(_ s: AgentSnapshot) -> String? {
        guard let current = s.cliVersion else { return nil }
        if let target = updateTargetVersion(s) {
            return "Provider software v\(current) · v\(target) available"
        }
        if compatibilityRepairAvailable(s) {
            return "Provider software v\(current) · update required"
        }
        return "Provider software v\(current) · up to date"
    }

    private static func publicReason(_ reason: String) -> String {
        switch reason {
        case "launchd_service_started":
            return "Provider service started"
        case "serve_invoked":
            return "Provider start requested"
        default:
            return reason
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "watchdog", with: "provider recovery")
                .replacingOccurrences(of: "buyer serving", with: "customer availability")
                .replacingOccurrences(of: "coordinator", with: "network")
                .replacingOccurrences(of: "compatibility set", with: "provider software")
                .replacingOccurrences(of: "admission identity", with: "network verification")
        }
    }

    static func publicErrorDetail(_ error: String?) -> String? {
        guard let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let redacted = LogTailBuffer.redacted(error)
        guard redacted != "[redacted]" else {
            return "Details are available in Advanced diagnostics."
        }
        let lower = redacted.lowercased()
        let internalMarkers = [
            "compatibility set",
            "admission identity",
            "watchdog",
            "buyer-serving",
            "buyer serving",
            "spec-",
            "migration token",
            "credential custody",
            "coordinator admission",
            "coordinator",
            "provider cli",
            "macprovider-cli",
            "cli-owned",
            "terminal path",
            "referral_bootstrap_v1",
            "provider_token",
            "authorization:",
            "/users/",
            "/tmp/",
            ".log",
            "--",
        ]
        if internalMarkers.contains(where: { lower.contains($0) }) {
            return "Details are available in Advanced diagnostics."
        }
        let allowedPrefixes = [
            "Invite code",
            "Invite entry",
            "Invite setup",
            "A referral code",
            "This referral code",
            "Too many referral",
            "Invite actions",
            "Invite status",
            "X rewards",
            "A new X verification",
            "The X verification",
            "Enter a public x.com",
            "Complete one network-verified",
            "The network",
            "The post",
            "Provider software",
            "Provider setup",
            "Provider import",
            "Could not use existing provider",
            "Could not start provider import",
            "Saved provider access",
            "Network verification",
        ]
        if allowedPrefixes.contains(where: { redacted.hasPrefix($0) }) {
            return redacted
        }
        return "Details are available in Advanced diagnostics."
    }

    /// Adaptive USDC precision: sub-cent amounts (e.g. per-token accrual)
    /// render as `$0.00` at two decimals, hiding real earnings. Show 4
    /// decimals only for nonzero amounts under a cent; otherwise `$%.2f`.
    private static func formatUSDC(_ amount: Double) -> String {
        if amount != 0 && abs(amount) < 0.01 {
            return String(format: "$%.4f", amount)
        }
        return String(format: "$%.2f", amount)
    }

    private static func malibuDisplay(_ amount: Double, snapshot: AgentSnapshot, compact: Bool = false) -> String {
        if let eligibility = displayRewardEligibility(snapshot) {
            switch eligibility.withdrawalState {
            case "withdrawable":
                return String(format: "%.2f MALIBU", amount)
            case "capped":
                if compact {
                    return String(format: "%.2f MALIBU today (capped)", amount)
                }
                return String(format: "[capped] %.2f MALIBU", amount)
            case "unavailable":
                if compact {
                    return "MALIBU today unavailable"
                }
                return "MALIBU reward status unavailable"
            default:
                if compact {
                    return String(format: "%.2f MALIBU today (locked)", amount)
                }
                return String(format: "[locked] %.2f MALIBU", amount)
            }
        }
        return malibuDisplay(amount, tier: snapshot.trustTier, compact: compact)
    }

    private static func malibuDisplay(_ amount: Double, tier: AgentSnapshot.TrustTier, compact: Bool = false) -> String {
        switch tier {
        case .trusted:
            return String(format: "%.2f MALIBU", amount)
        case .provisional:
            if compact {
                return String(format: "%.2f MALIBU today (locked)", amount)
            }
            return String(format: "[locked] %.2f MALIBU (unlocks at Trusted)", amount)
        }
    }

    private static func malibuHoldReasonCopy(_ reason: String) -> String {
        switch reason {
        case "trust_tier_provisional":
            return "Trust verification is incomplete"
        case "per_wallet_daily_cap":
            return "the wallet's daily limit has been reached"
        case "demotion_cooldown":
            return "Trust verification is in progress"
        default:
            return "payout eligibility is still being verified"
        }
    }

    private static func authoritativeRewardEligibility(_ s: AgentSnapshot) -> MalibuRewardEligibility? {
        guard s.malibuProjectionFresh else { return nil }
        return s.malibuRewardEligibility ?? MalibuRewardEligibility.unavailableForMissingObject()
    }

    /// Current demotion cooldown only. A historical `demotion_cooldown` hold
    /// row on an already-Trusted snapshot must not hide Trusted or show
    /// requalification copy.
    private static func hasDemotionCooldown(_ s: AgentSnapshot) -> Bool {
        guard s.trustTier == .provisional else {
            return false
        }
        if s.malibuHoldReasons.contains("demotion_cooldown") {
            return true
        }
        return authoritativeRewardEligibility(s)?.primaryReason == "held_demotion_cooldown"
    }

    private static let leftoverProvisionalHoldReasons: Set<String> = [
        "trust_tier_provisional",
        "demotion_cooldown",
    ]
    private static let leftoverProvisionalEligibilityReasons: Set<String> = [
        "held_provisional_trust_tier",
        "held_demotion_cooldown",
    ]

    /// Trusted snapshots can still carry leftover provisional hold rows from
    /// 1.8.102. Those must not tell a Trusted earner they are locked.
    private static func displayMalibuHoldReasons(_ s: AgentSnapshot) -> [String] {
        guard s.trustTier == .trusted else { return s.malibuHoldReasons }
        return s.malibuHoldReasons.filter { !leftoverProvisionalHoldReasons.contains($0) }
    }

    private static func displayRewardEligibility(_ s: AgentSnapshot) -> MalibuRewardEligibility? {
        guard let eligibility = authoritativeRewardEligibility(s) else { return nil }
        guard s.trustTier == .trusted,
              leftoverProvisionalEligibilityReasons.contains(eligibility.primaryReason) else {
            return eligibility
        }
        return nil
    }

    private static func shouldIgnoreLeftoverProvisionalLock(_ s: AgentSnapshot) -> Bool {
        guard s.trustTier == .trusted, displayMalibuHoldReasons(s).isEmpty else {
            return false
        }
        if s.malibuHoldReasons.contains(where: leftoverProvisionalHoldReasons.contains) {
            return true
        }
        if let eligibility = authoritativeRewardEligibility(s),
           leftoverProvisionalEligibilityReasons.contains(eligibility.primaryReason) {
            return true
        }
        return false
    }

    private static func canShowLastKnownUSDC(_ s: AgentSnapshot) -> Bool {
        s.providerEarningsFresh || (s.hasObservedProviderEarnings && s.earningsUsdcToday != nil)
    }

    private static func rewardEligibilityLine(_ eligibility: MalibuRewardEligibility) -> String {
        switch eligibility.primaryReason {
        case "earning_verified_work":
            return "Earning MALIBU from verified work"
        case "eligible_idle_no_work":
            return "Eligible · network is quiet"
        case "held_provider_daily_cap":
            return "MALIBU provider daily cap reached"
        case "held_wallet_daily_cap":
            return "MALIBU wallet daily cap reached"
        case "held_provisional_trust_tier":
            return "MALIBU is locked until Trusted"
        case "held_demotion_cooldown":
            return "MALIBU is locked until Trusted"
        case "held_epoch_disposition":
            return "MALIBU is held pending epoch settlement"
        case "excluded_epoch_disposition":
            return "MALIBU was excluded from this epoch"
        case "burned_or_retired_epoch_disposition":
            return "MALIBU was retired for this epoch"
        case "withdrawable_balance_available":
            return "MALIBU is available to withdraw"
        case "withdrawable_no_balance":
            return "No MALIBU is available yet"
        case "missing_wallet_binding":
            return "Add a wallet to unlock MALIBU withdrawals"
        case "local_on_battery":
            return "On battery — plug in to earn"
        case "local_thermal_pressure":
            return "Thermal throttle — waiting to cool before earning"
        case "model_not_ready":
            return "Model is preparing — earning starts when ready"
        case "compute_integrity_pending", "insufficient_verified_receipts", "app_attestation_missing":
            return "Reward status is being verified"
        case "compute_integrity_blocked", "provider_token_untrusted":
            return "Reward eligibility needs review"
        case "hardware_evidence_unavailable",
             "hardware_evidence_missing_or_expired",
             "compute_integrity_unavailable",
             "telemetry_unavailable":
            return "Reward status unavailable"
        default:
            return "Reward status unavailable"
        }
    }

    private static func rewardEligibilityShortCopy(_ eligibility: MalibuRewardEligibility) -> String {
        switch eligibility.withdrawalState {
        case "capped":
            return "limited by daily cap"
        case "held":
            return "locked until eligible"
        case "ineligible":
            return "not eligible for withdrawal"
        case "unavailable":
            return "reward status unavailable"
        default:
            return rewardEligibilityLine(eligibility)
        }
    }

    /// Capitalize the first character and end with a period, turning a lowercase
    /// reason clause into a standalone sentence for status/reason copy.
    private static func sentence(_ clause: String) -> String {
        guard let first = clause.first else { return clause }
        let capitalized = first.uppercased() + clause.dropFirst()
        return capitalized.hasSuffix(".") ? capitalized : capitalized + "."
    }

    private static func rewardReasonCopy(_ reason: String) -> String {
        switch reason {
        case "held_provider_daily_cap":
            return "provider daily limit reached"
        case "held_wallet_daily_cap":
            return "wallet daily limit reached"
        case "held_provisional_trust_tier":
            return "Trust verification is incomplete"
        case "held_demotion_cooldown":
            return "Trust verification is in progress"
        case "held_epoch_disposition":
            return "MALIBU is held pending epoch settlement"
        case "excluded_epoch_disposition":
            return "MALIBU was excluded from this epoch"
        case "burned_or_retired_epoch_disposition":
            return "MALIBU was retired for this epoch"
        case "missing_wallet_binding":
            return "wallet binding is missing"
        case "insufficient_verified_receipts":
            return "more verified work is required"
        case "app_attestation_missing":
            return "app verification is incomplete"
        case "compute_integrity_pending":
            return "reward verification is pending"
        case "compute_integrity_blocked", "provider_token_untrusted":
            return "reward eligibility needs review"
        case "hardware_evidence_unavailable",
             "hardware_evidence_missing_or_expired",
             "compute_integrity_unavailable",
             "telemetry_unavailable":
            return "reward status is unavailable"
        default:
            return "reward eligibility is still being verified"
        }
    }

    private static func rewardReasonNextAction(_ reason: String) -> String {
        switch reason {
        case "held_provider_daily_cap":
            return "The provider cap resets at the next UTC day."
        case "held_wallet_daily_cap":
            return "The wallet cap resets at the next UTC day."
        case "held_provisional_trust_tier":
            return "Complete the remaining trust criteria to unlock withdrawals."
        case "held_demotion_cooldown":
            return "Keep Malibu online; withdrawals unlock automatically when Trusted."
        case "held_epoch_disposition":
            return "This settles at the next epoch."
        case "excluded_epoch_disposition", "burned_or_retired_epoch_disposition":
            return "Nothing to do — this reflects a past epoch."
        case "missing_wallet_binding":
            return "Add a payout wallet."
        case "insufficient_verified_receipts":
            return "Keep serving verified work."
        case "app_attestation_missing", "compute_integrity_pending":
            return "Wait for verification to complete."
        case "compute_integrity_blocked", "provider_token_untrusted":
            return "Review Advanced diagnostics."
        case "hardware_evidence_unavailable",
             "hardware_evidence_missing_or_expired",
             "compute_integrity_unavailable",
             "telemetry_unavailable":
            return "Nothing to do — this refreshes on its own."
        default:
            return "Nothing to do — this refreshes on its own."
        }
    }

    private static func tokenPair(input: Int64?, output: Int64?, suffix: String) -> String {
        "\(formatTokens(input)) in / \(formatTokens(output)) out \(suffix)"
    }

    private static func formatTokens(_ value: Int64?) -> String {
        guard let value else { return "0" }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private static func formatCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return String(format: "%dm", seconds / 60) }
        return String(format: "%dh %dm", seconds / 3600, (seconds % 3600) / 60)
    }
}

extension AgentSnapshot {
    mutating func applyAdmissionIdentityRecoveryJournal(
        _ recovery: ProviderCredentialHandoffRunner.AdmissionRecoverySnapshot
    ) {
        admissionIdentityRecoveryJournalState = recovery.state
        switch recovery.state {
        case "approval_required":
            admissionIdentityState = "recovery_pending"
            admissionIdentityPendingPublicKeySHA256 = recovery.candidatePublicKeySHA256
            admissionIdentityTransitionError = "approval_required"
            admissionIdentityRecoveryAction = "obtain_operator_recovery_approval_then_restart"
            admissionIdentityRecoveryApprovalInstruction = recovery.approvalInstruction
            admissionIdentityRecoveryOperatorRequest = recovery.operatorRequest
            admissionIdentityRecoveryLastError = nil
        case "committed_cleanup":
            admissionIdentityPendingPublicKeySHA256 = recovery.candidatePublicKeySHA256
            admissionIdentityRecoveryApprovalInstruction = "Finalize the already committed recovery journal."
            admissionIdentityRecoveryOperatorRequest = nil
            admissionIdentityRecoveryLastError = nil
        case "expired":
            admissionIdentityRecoveryApprovalInstruction = nil
            admissionIdentityRecoveryOperatorRequest = nil
            admissionIdentityRecoveryLastError = "The staged network verification repair request expired. Stage a new request."
        case "not_staged", "committed":
            admissionIdentityRecoveryApprovalInstruction = nil
            admissionIdentityRecoveryOperatorRequest = nil
            if recovery.state == "committed" {
                admissionIdentityRecoveryJournalState = nil
            }
        default:
            break
        }
    }
}
