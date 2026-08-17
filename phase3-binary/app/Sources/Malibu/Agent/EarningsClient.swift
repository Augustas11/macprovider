import Foundation

/// Provider-visible last-hour idle-prewarm projection. Mirrors
/// `ProviderIdlePrewarmSummary` in
/// `Sources/macprovider-cli/ProviderEarningsClient.swift` — duplicated for P0
/// (see the ControlSocketFrame note above on consolidating the wire mirrors).
struct ProviderIdlePrewarmSummary: Codable, Equatable {
    let eventsLast1h: [String: Int64]
    let skipsByReasonLast1h: [String: Int64]

    static let empty = ProviderIdlePrewarmSummary(eventsLast1h: [:], skipsByReasonLast1h: [:])

    enum CodingKeys: String, CodingKey {
        case eventsLast1h = "events_last_1h"
        case skipsByReasonLast1h = "skips_by_reason_last_1h"
    }

    init(eventsLast1h: [String: Int64] = [:], skipsByReasonLast1h: [String: Int64] = [:]) {
        self.eventsLast1h = eventsLast1h
        self.skipsByReasonLast1h = skipsByReasonLast1h
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventsLast1h = try c.decodeIfPresent([String: Int64].self, forKey: .eventsLast1h) ?? [:]
        skipsByReasonLast1h = try c.decodeIfPresent([String: Int64].self, forKey: .skipsByReasonLast1h) ?? [:]
    }
}

/// Coordinator-owned MALIBU reward eligibility reason model.
struct MalibuRewardEligibility: Codable, Equatable {
    static let schemaV1 = "malibu_reward_eligibility.v1"

    let schemaVersion: String
    let earningState: String
    let withdrawalState: String
    let primaryReason: String
    let reasons: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case earningState = "earning_state"
        case withdrawalState = "withdrawal_state"
        case primaryReason = "primary_reason"
        case reasons
    }

    init(
        schemaVersion: String = schemaV1,
        earningState: String,
        withdrawalState: String,
        primaryReason: String,
        reasons: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.earningState = earningState
        self.withdrawalState = withdrawalState
        self.primaryReason = primaryReason
        self.reasons = reasons
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawSchema = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? ""
        guard rawSchema == Self.schemaV1 else {
            self = .unavailable(schemaVersion: rawSchema)
            return
        }
        let rawEarningState = try c.decodeIfPresent(String.self, forKey: .earningState) ?? ""
        let rawWithdrawalState = try c.decodeIfPresent(String.self, forKey: .withdrawalState) ?? ""
        let rawPrimaryReason = try c.decodeIfPresent(String.self, forKey: .primaryReason) ?? ""
        let rawReasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        guard Self.allowedEarningStates.contains(rawEarningState),
              Self.allowedWithdrawalStates.contains(rawWithdrawalState),
              Self.allowedReasons.contains(rawPrimaryReason),
              rawReasons.allSatisfy({ Self.allowedReasons.contains($0) }) else {
            self = .unavailable(schemaVersion: rawSchema)
            return
        }
        self.init(
            schemaVersion: rawSchema,
            earningState: rawEarningState,
            withdrawalState: rawWithdrawalState,
            primaryReason: rawPrimaryReason,
            reasons: rawReasons
        )
    }

    private static func unavailable(schemaVersion: String) -> MalibuRewardEligibility {
        MalibuRewardEligibility(
            schemaVersion: schemaVersion.isEmpty ? schemaV1 : schemaVersion,
            earningState: "unavailable",
            withdrawalState: "unavailable",
            primaryReason: "telemetry_unavailable",
            reasons: ["telemetry_unavailable"]
        )
    }

    private static let allowedEarningStates: Set<String> = [
        "earning", "eligible_idle", "held", "capped", "ineligible", "unavailable"
    ]
    private static let allowedWithdrawalStates: Set<String> = [
        "withdrawable", "held", "capped", "ineligible", "unavailable"
    ]
    private static let allowedReasons: Set<String> = [
        "earning_verified_work",
        "eligible_idle_no_work",
        "held_provisional_trust_tier",
        "held_wallet_daily_cap",
        "held_demotion_cooldown",
        "withdrawable_balance_available",
        "withdrawable_no_balance",
        "missing_wallet_binding",
        "insufficient_verified_receipts",
        "app_attestation_missing",
        "hardware_evidence_unavailable",
        "hardware_evidence_missing_or_expired",
        "compute_integrity_unavailable",
        "compute_integrity_pending",
        "compute_integrity_blocked",
        "provider_token_untrusted",
        "local_on_battery",
        "local_thermal_pressure",
        "model_not_ready",
        "telemetry_unavailable",
    ]
}

/// Non-secret earnings projection received from the CLI over the same-user
/// control socket. Malibu never receives or stores the provider bearer.
struct ProviderEarnings: Codable, Equatable {
    let walletBound: Bool
    let trustTier: AgentSnapshot.TrustTier
    let unpaidLedgerBacklogUSDC: Double
    let unpaidLedgerBacklogMALIBU: Double
    let usdcToday: Double?
    let usdcWeek: Double?
    let usdcPending: Double?
    let usdcLifetime: Double?
    let malibuToday: Double?
    let malibuAllTime: Double?
    let trustCriteriaMet: Int?
    let trustCriteriaRequired: Int?
    let malibuWithdrawable: Double?
    let malibuHeld: Double?
    let malibuHoldReasons: [String]
    let malibuDailyCap: Double?
    let malibuWalletDailyCap: Double?
    let malibuRewardEligibility: MalibuRewardEligibility?
    /// Last-hour idle-prewarm event/skip counts, used to explain why a
    /// serving provider is not currently earning. Display-only.
    let idlePrewarm: ProviderIdlePrewarmSummary
    /// Set only when the CLI fetched the companion MALIBU accrual projection.
    /// Missing/legacy wire data is intentionally not treated as fresh.
    let malibuProjectionFresh: Bool
    /// True only when the CLI fetched the provider earnings endpoint.
    let earningsProjectionFresh: Bool

    enum CodingKeys: String, CodingKey {
        case walletBound = "wallet_bound"
        case trustTier = "trust_tier"
        case unpaidLedgerBacklogUSDC = "unpaid_ledger_backlog_usdc"
        case unpaidLedgerBacklogMALIBU = "unpaid_ledger_backlog_malibu"
        case usdcToday = "usdc_today"
        case usdcWeek = "usdc_week"
        case usdcPending = "usdc_pending"
        case usdcLifetime = "usdc_lifetime"
        case malibuToday = "malibu_today"
        case malibuAllTime = "malibu_all_time"
        case trustCriteriaMet = "trust_criteria_met"
        case trustCriteriaRequired = "trust_criteria_required"
        case malibuWithdrawable = "malibu_withdrawable"
        case malibuHeld = "malibu_held"
        case malibuHoldReasons = "malibu_hold_reasons"
        case malibuDailyCap = "malibu_daily_cap"
        case malibuWalletDailyCap = "malibu_wallet_daily_cap"
        case malibuRewardEligibility = "malibu_reward_eligibility"
        case idlePrewarm = "idle_prewarm"
        case malibuProjectionFresh = "malibu_projection_fresh"
        case earningsProjectionFresh = "earnings_projection_fresh"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        walletBound = try c.decodeIfPresent(Bool.self, forKey: .walletBound) ?? false
        trustTier = try c.decodeIfPresent(AgentSnapshot.TrustTier.self, forKey: .trustTier) ?? .provisional
        unpaidLedgerBacklogUSDC = try c.decodeIfPresent(Double.self, forKey: .unpaidLedgerBacklogUSDC) ?? 0
        unpaidLedgerBacklogMALIBU = try c.decodeIfPresent(Double.self, forKey: .unpaidLedgerBacklogMALIBU) ?? 0
        usdcToday = try c.decodeIfPresent(Double.self, forKey: .usdcToday)
        usdcWeek = try c.decodeIfPresent(Double.self, forKey: .usdcWeek)
        usdcPending = try c.decodeIfPresent(Double.self, forKey: .usdcPending)
        usdcLifetime = try c.decodeIfPresent(Double.self, forKey: .usdcLifetime)
        malibuToday = try c.decodeIfPresent(Double.self, forKey: .malibuToday)
        malibuAllTime = try c.decodeIfPresent(Double.self, forKey: .malibuAllTime)
        trustCriteriaMet = try c.decodeIfPresent(Int.self, forKey: .trustCriteriaMet)
        trustCriteriaRequired = try c.decodeIfPresent(Int.self, forKey: .trustCriteriaRequired)
        malibuWithdrawable = try c.decodeIfPresent(Double.self, forKey: .malibuWithdrawable)
        malibuHeld = try c.decodeIfPresent(Double.self, forKey: .malibuHeld)
        malibuHoldReasons = try c.decodeIfPresent([String].self, forKey: .malibuHoldReasons) ?? []
        malibuDailyCap = try c.decodeIfPresent(Double.self, forKey: .malibuDailyCap)
        malibuWalletDailyCap = try c.decodeIfPresent(Double.self, forKey: .malibuWalletDailyCap)
        malibuRewardEligibility = try c.decodeIfPresent(MalibuRewardEligibility.self, forKey: .malibuRewardEligibility)
        idlePrewarm = try c.decodeIfPresent(ProviderIdlePrewarmSummary.self, forKey: .idlePrewarm) ?? .empty
        malibuProjectionFresh = try c.decodeIfPresent(Bool.self, forKey: .malibuProjectionFresh) ?? false
        earningsProjectionFresh = try c.decodeIfPresent(Bool.self, forKey: .earningsProjectionFresh) ?? false
    }

    init(
        walletBound: Bool,
        trustTier: AgentSnapshot.TrustTier,
        unpaidLedgerBacklogUSDC: Double,
        unpaidLedgerBacklogMALIBU: Double,
        usdcToday: Double?,
        usdcWeek: Double?,
        usdcPending: Double?,
        usdcLifetime: Double?,
        malibuToday: Double?,
        malibuAllTime: Double?,
        trustCriteriaMet: Int?,
        trustCriteriaRequired: Int?,
        malibuWithdrawable: Double? = nil,
        malibuHeld: Double? = nil,
        malibuHoldReasons: [String] = [],
        malibuDailyCap: Double? = nil,
        malibuWalletDailyCap: Double? = nil,
        malibuRewardEligibility: MalibuRewardEligibility? = nil,
        idlePrewarm: ProviderIdlePrewarmSummary = .empty,
        malibuProjectionFresh: Bool = false,
        earningsProjectionFresh: Bool = false
    ) {
        self.walletBound = walletBound
        self.trustTier = trustTier
        self.unpaidLedgerBacklogUSDC = unpaidLedgerBacklogUSDC
        self.unpaidLedgerBacklogMALIBU = unpaidLedgerBacklogMALIBU
        self.usdcToday = usdcToday
        self.usdcWeek = usdcWeek
        self.usdcPending = usdcPending
        self.usdcLifetime = usdcLifetime
        self.malibuToday = malibuToday
        self.malibuAllTime = malibuAllTime
        self.trustCriteriaMet = trustCriteriaMet
        self.trustCriteriaRequired = trustCriteriaRequired
        self.malibuWithdrawable = malibuWithdrawable
        self.malibuHeld = malibuHeld
        self.malibuHoldReasons = malibuHoldReasons
        self.malibuDailyCap = malibuDailyCap
        self.malibuWalletDailyCap = malibuWalletDailyCap
        self.malibuRewardEligibility = malibuRewardEligibility
        self.idlePrewarm = idlePrewarm
        self.malibuProjectionFresh = malibuProjectionFresh
        self.earningsProjectionFresh = earningsProjectionFresh
    }
}

enum UnclaimedBadgePolicy {
    static let thresholds: [Double] = [1, 10, 100]

    static func visibleThreshold(totalBacklog: Double, dismissedThreshold: Double?) -> Double? {
        thresholds.first { threshold in
            totalBacklog >= threshold && threshold > (dismissedThreshold ?? 0)
        }
    }

    static func nextDismissedThreshold(totalBacklog: Double) -> Double? {
        thresholds.last { totalBacklog >= $0 }
    }
}

struct UnclaimedBadgeDismissalStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "malibu.unclaimedBadge.dismissedThreshold") {
        self.defaults = defaults
        self.key = key
    }

    var dismissedThreshold: Double? {
        get {
            guard defaults.object(forKey: key) != nil else { return nil }
            return defaults.double(forKey: key)
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
