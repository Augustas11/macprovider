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
    /// Whether malibu-cli reports an active coordinator WebSocket session.
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

    func hasTrustedReferralBoundary() -> Bool {
        localStatusContractCompatible == true
            && ProviderLifecycleAuthority.isAccepted(localStatusLifecycleOwner)
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
        pauseAcknowledged: false
    )
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
        if !s.providerEarningsFresh && !s.hasObservedProviderEarnings {
            return result(
                status: "Reward status unavailable",
                code: "reward_projection_unavailable",
                reason: "Fresh earnings or MALIBU reward telemetry is not available yet.",
                action: isActive(s) ? "Keep Malibu open while reward status refreshes." : "Start the provider to refresh reward status."
            )
        }
        if s.walletBound == false {
            return result(
                status: "Missing wallet",
                code: "wallet_missing",
                reason: "Rewards are visible, but no payout wallet is bound.",
                action: "Add a payout wallet."
            )
        }
        if s.malibuProjectionFresh {
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
        (s.requestsPerMinute ?? 0) > 0
            || (s.earningsUsdcToday ?? 0) > 0
            || (s.malibuAccruedToday ?? 0) > 0
    }

    private static func miningRewardSummary(_ s: AgentSnapshot) -> String {
        let usdc = canShowLastKnownUSDC(s)
            ? s.earningsUsdcToday.map { "\(formatUSDC($0)) USDC today" } ?? "n/a USDC today"
            : "USDC unavailable"
        let malibu: String
        if s.malibuProjectionFresh {
            let withdrawable = s.malibuWithdrawable.map { String(format: "%.2f withdrawable", $0) }
                ?? "n/a withdrawable"
            let held = s.malibuHeld.map { String(format: "%.2f held", $0) }
                ?? "n/a held"
            malibu = "MALIBU \(withdrawable) / \(held)"
        } else {
            malibu = "MALIBU unavailable"
        }
        return "\(usdc) · \(malibu)"
    }

    private static func miningTrustSummary(_ s: AgentSnapshot) -> String {
        guard s.malibuProjectionFresh else {
            return "MALIBU trust telemetry not published yet"
        }
        let tier = s.trustTier.rawValue.capitalized
        if hasDemotionCooldown(s) {
            return "Trust: \(tier) · Trust review in progress"
        }
        if s.trustTier == .trusted {
            return "Trust: Trusted"
        }
        if let met = s.trustCriteriaMet, let required = s.trustCriteriaRequired {
            return "Trust: \(tier) · \(met) of \(required) criteria met"
        }
        return "Trust: \(tier)"
    }

    private static func trustCriteriaAction(_ s: AgentSnapshot) -> String? {
        if hasDemotionCooldown(s) {
            return "Keep Malibu online; withdrawals unlock automatically when Trusted."
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

    static func dashboardHeadline(_ s: AgentSnapshot) -> String {
        switch s.state {
        case .idle:         return publicStatus(s).title
        case .starting:     return publicStatus(s).title
        case .serving:
            return publicStatus(s).title
        case .paused:       return "Paused"
        case .reconnecting:
            return publicStatus(s).title
        case .error:        return publicStatus(s).title
        }
    }

    static func dashboardSubtitle(_ s: AgentSnapshot) -> String? {
        let status = publicStatus(s)
        switch s.state {
        case .serving where !isNetworkReady(s):
            return status.detail
        case .serving where !s.providerEarningsFresh && !s.hasObservedProviderEarnings:
            return "Ready for customer work · earnings unavailable"
        case .serving where idleEarningsAreZero(s):
            return idleHonestySubtitle(s)
        case .serving:
            return s.currentModelID
        case .reconnecting where isLocalOnly(s):
            return publicErrorDetail(s.lastError) ?? status.detail
        case .reconnecting:
            return publicErrorDetail(s.lastError) ?? status.detail
        case .starting:
            return publicErrorDetail(s.lastError) ?? status.detail
        case .error:
            return status.detail
        default:
            return nil
        }
    }

    /// Ready + $0 is usually a quiet network, not a broken Mac. Queue depth
    /// and today's request count distinguish those cases from work waiting
    /// locally or unpaid work that has not settled.
    private static func idleHonestySubtitle(_ s: AgentSnapshot) -> String {
        if (s.queueDepth ?? 0) > 0 {
            return "Ready · work is queued on this Mac"
        }
        if (s.requestsServedToday ?? 0) > 0 {
            return "Ready · work ran; paid credits appear when a job settles"
        }
        return "Ready for customer work · network is quiet"
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

    static func usdcFullLine(_ s: AgentSnapshot) -> String {
        if !canShowLastKnownUSDC(s) {
            let today = "n/a today"
            return "\(today) · n/a wk · n/a accrued · n/a life"
        }
        return [
            s.earningsUsdcToday.map { "\(formatUSDC($0)) today" } ?? "n/a today",
            s.earningsUsdcWeek.map { "\(formatUSDC($0)) wk" } ?? "n/a wk",
            s.earningsUsdcPending.map { "\(formatUSDC($0)) accrued" } ?? "n/a accrued",
            s.earningsUsdcLifetime.map { "\(formatUSDC($0)) life" } ?? "n/a life"
        ].joined(separator: " · ")
    }

    /// Caption for the accrued amount in `usdcFullLine`, kept on its own line
    /// so the full line stays scannable.
    static func usdcAccrualCaption(_ s: AgentSnapshot) -> String? {
        guard s.providerEarningsFresh, s.earningsUsdcPending != nil else { return nil }
        return "Accrued — payouts open in beta"
    }

    static func usdcTodayDisplay(_ s: AgentSnapshot) -> String {
        guard canShowLastKnownUSDC(s) else {
            return "n/a"
        }
        return s.earningsUsdcToday.map { formatUSDC($0) } ?? "n/a"
    }

    static func malibuFullLine(_ s: AgentSnapshot) -> String {
        if !s.malibuProjectionFresh {
            let today = "n/a MALIBU today"
            return "\(today) · n/a all-time"
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
            return "MALIBU status: \(rewardReasonCopy(eligibility.primaryReason)) Next: \(rewardReasonNextAction(eligibility.primaryReason))"
        }
        let holdReasons = displayMalibuHoldReasons(s)
        guard s.malibuProjectionFresh, !holdReasons.isEmpty else { return nil }
        let reasons = holdReasons.map { malibuHoldReasonCopy($0) }
        let nextAction: String
        if holdReasons.contains("trust_tier_provisional"),
           let met = s.trustCriteriaMet,
           let required = s.trustCriteriaRequired,
           required > met {
            nextAction = "Complete \(required - met) more trust criteria to unlock withdrawals."
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
        let tier = s.trustTier.rawValue.capitalized
        if hasDemotionCooldown(s) {
            return "\(tier) — Trust review in progress"
        }
        if s.trustTier == .trusted {
            return "Trusted"
        }
        if let met = s.trustCriteriaMet, let required = s.trustCriteriaRequired {
            return "\(tier) — \(met) of \(required) criteria met · Unlock Trusted →"
        }
        return tier
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
            && !s.providerSoftwareRepairInProgress
            && !s.cliUpdateInProgress
    }

    private static func isLiveProviderVisibleDuringSoftwareRepair(_ s: AgentSnapshot) -> Bool {
        s.state == .paused || isNetworkReady(s, at: Date())
    }

    private static func withHomeACLRepairIfNeeded(
        _ status: PublicStatus,
        _ s: AgentSnapshot
    ) -> PublicStatus {
        guard canRepairProviderSoftware(s) else { return status }
        return PublicStatus(
            title: status.title,
            detail: status.detail,
            safeNextAction:
                "Repair provider software. Malibu will reinstall the bundled provider software and watchdog. Your provider identity and downloaded models will be kept.",
            executableAction: .repairProviderSoftware
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
            "malibu-cli",
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
        case "missing_wallet_binding":
            return "Add a payout wallet."
        case "insufficient_verified_receipts":
            return "Keep serving verified work."
        case "app_attestation_missing", "compute_integrity_pending":
            return "Wait for verification to complete."
        case "compute_integrity_blocked", "provider_token_untrusted":
            return "Review Advanced diagnostics."
        default:
            return "Try again when reward status refreshes."
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
