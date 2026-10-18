import Foundation

/// Provider-visible last-hour idle-prewarm projection, mirrored from
/// `statsprewarm.Summary` (phase4-coordinator/internal/stats/prewarm/reader.go)
/// as returned under `idle_prewarm` on GET /providers/{provider_id}/earnings.
public struct ProviderIdlePrewarmSummary: Codable, Equatable, Sendable {
    public let eventsLast1h: [String: Int64]
    public let skipsByReasonLast1h: [String: Int64]

    public static let empty = ProviderIdlePrewarmSummary(eventsLast1h: [:], skipsByReasonLast1h: [:])

    enum CodingKeys: String, CodingKey {
        case eventsLast1h = "events_last_1h"
        case skipsByReasonLast1h = "skips_by_reason_last_1h"
    }

    public init(eventsLast1h: [String: Int64] = [:], skipsByReasonLast1h: [String: Int64] = [:]) {
        self.eventsLast1h = eventsLast1h
        self.skipsByReasonLast1h = skipsByReasonLast1h
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventsLast1h = try container.decodeIfPresent([String: Int64].self, forKey: .eventsLast1h) ?? [:]
        skipsByReasonLast1h = try container.decodeIfPresent(
            [String: Int64].self,
            forKey: .skipsByReasonLast1h
        ) ?? [:]
    }
}

/// Live trust progress from the coordinator reward projection (SPEC-021
/// §5.3). Timestamps stay RFC3339 text; readers parse and validate them.
public struct ProviderTrustProgressSummary: Codable, Equatable, Sendable {
    public let tier: String
    public let demotionCooldownUntil: String?
    public let demotionCooldownActive: Bool
    public let requalificationRequired: Bool
    public let uptimeOKSince: String?
    public let uptimeRequiredSeconds: Int64
    public let unlockPairOKSince: String?
    public let requalificationWindowSeconds: Int64
    public let verifiedReceiptCount: Int
    public let requiredReceiptCount: Int
    public let criteriaMet: [String]
    public let earliestPromotionAt: String?

    enum CodingKeys: String, CodingKey {
        case tier
        case demotionCooldownUntil = "demotion_cooldown_until"
        case demotionCooldownActive = "demotion_cooldown_active"
        case requalificationRequired = "requalification_required"
        case uptimeOKSince = "uptime_ok_since"
        case uptimeRequiredSeconds = "uptime_required_seconds"
        case unlockPairOKSince = "unlock_pair_ok_since"
        case requalificationWindowSeconds = "requalification_window_seconds"
        case verifiedReceiptCount = "verified_receipt_count"
        case requiredReceiptCount = "required_receipt_count"
        case criteriaMet = "criteria_met"
        case earliestPromotionAt = "earliest_promotion_at"
    }

    public init(
        tier: String,
        demotionCooldownUntil: String? = nil,
        demotionCooldownActive: Bool = false,
        requalificationRequired: Bool = false,
        uptimeOKSince: String? = nil,
        uptimeRequiredSeconds: Int64 = 259_200,
        unlockPairOKSince: String? = nil,
        requalificationWindowSeconds: Int64 = 259_200,
        verifiedReceiptCount: Int = 0,
        requiredReceiptCount: Int = 100,
        criteriaMet: [String] = [],
        earliestPromotionAt: String? = nil
    ) {
        self.tier = tier
        self.demotionCooldownUntil = demotionCooldownUntil
        self.demotionCooldownActive = demotionCooldownActive
        self.requalificationRequired = requalificationRequired
        self.uptimeOKSince = uptimeOKSince
        self.uptimeRequiredSeconds = uptimeRequiredSeconds
        self.unlockPairOKSince = unlockPairOKSince
        self.requalificationWindowSeconds = requalificationWindowSeconds
        self.verifiedReceiptCount = verifiedReceiptCount
        self.requiredReceiptCount = requiredReceiptCount
        self.criteriaMet = criteriaMet
        self.earliestPromotionAt = earliestPromotionAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawTier = try c.decode(String.self, forKey: .tier).lowercased()
        guard rawTier == "provisional" || rawTier == "trusted" else {
            throw DecodingError.dataCorruptedError(forKey: .tier, in: c, debugDescription: "Invalid trust tier")
        }
        tier = rawTier
        demotionCooldownUntil = try c.decodeIfPresent(String.self, forKey: .demotionCooldownUntil)
        demotionCooldownActive = try c.decodeIfPresent(Bool.self, forKey: .demotionCooldownActive) ?? false
        requalificationRequired = try c.decodeIfPresent(Bool.self, forKey: .requalificationRequired) ?? false
        uptimeOKSince = try c.decodeIfPresent(String.self, forKey: .uptimeOKSince)
        uptimeRequiredSeconds = max(0, try c.decodeIfPresent(Int64.self, forKey: .uptimeRequiredSeconds) ?? 0)
        unlockPairOKSince = try c.decodeIfPresent(String.self, forKey: .unlockPairOKSince)
        requalificationWindowSeconds = max(0, try c.decodeIfPresent(Int64.self, forKey: .requalificationWindowSeconds) ?? 0)
        verifiedReceiptCount = max(0, try c.decodeIfPresent(Int.self, forKey: .verifiedReceiptCount) ?? 0)
        requiredReceiptCount = max(0, try c.decodeIfPresent(Int.self, forKey: .requiredReceiptCount) ?? 0)
        criteriaMet = Array((try c.decodeIfPresent([String].self, forKey: .criteriaMet) ?? []).prefix(16))
        earliestPromotionAt = try c.decodeIfPresent(String.self, forKey: .earliestPromotionAt)
    }
}

/// Network MALIBU emission state from the coordinator reward projection.
public struct ProviderEmissionSummary: Codable, Equatable, Sendable {
    public let active: Bool
    public let lastAccrualAt: String?

    enum CodingKeys: String, CodingKey {
        case active
        case lastAccrualAt = "last_accrual_at"
    }

    public init(active: Bool, lastAccrualAt: String? = nil) {
        self.active = active
        self.lastAccrualAt = lastAccrualAt
    }
}

/// Provider-facing read model returned by GET /providers/{provider_id}/earnings.
/// The CLI owns the provider bearer and exposes this non-secret projection to
/// same-user local clients over the 0600 control socket.
public struct ProviderEarningsSummary: Codable, Equatable, Sendable {
    public let walletBound: Bool
    public let trustTier: String
    public let unpaidLedgerBacklogUSDC: Double
    public let unpaidLedgerBacklogMALIBU: Double
    public let usdcToday: Double?
    public let usdcWeek: Double?
    public let usdcPending: Double?
    public let usdcLifetime: Double?
    public let malibuToday: Double?
    public let malibuAllTime: Double?
    public let trustCriteriaMet: Int?
    public let trustCriteriaRequired: Int?
    public let economicCriteria: [String]?
    public let additionalCriteria: [String]?
    public let malibuWithdrawable: Double?
    public let malibuHeld: Double?
    public let malibuHoldReasons: [String]
    public let malibuDailyCap: Double?
    public let malibuWalletDailyCap: Double?
    public let malibuRewardEligibility: MalibuRewardEligibility?
    /// Capability advertised by this CLI's local control transport. Older CLI
    /// frames omit it and app clients decode that absence as unsupported.
    public let rewardAuditSupported: Bool
    /// Last-hour idle-prewarm event/skip counts, used to explain why a
    /// serving provider is not currently earning (on battery, thermal
    /// throttle, model not loaded). Display-only.
    public let idlePrewarm: ProviderIdlePrewarmSummary
    /// True only when GET /providers/{id}/earnings returned this projection.
    public let earningsProjectionFresh: Bool
    /// True only when a coherent MALIBU reward projection endpoint supplied
    /// this bundle in the current metrics cycle. A provider-earnings response
    /// alone must not authorize reward availability or trust copy.
    public let malibuProjectionFresh: Bool
    /// payout.enabled from the earnings endpoint; nil from older coordinators.
    public let payoutsEnabled: Bool?
    /// Newest payable request time (RFC3339 UTC) from the earnings endpoint.
    public let lastPaidJobAtUTC: String?
    /// Trust holds kept from an earlier trust state (SPEC-021 §5.2).
    public let malibuRetainedHoldReasons: [String]?
    public let trustProgress: ProviderTrustProgressSummary?
    public let emission: ProviderEmissionSummary?

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
        case economicCriteria = "economic_criteria"
        case additionalCriteria = "additional_criteria"
        case malibuWithdrawable = "malibu_withdrawable"
        case malibuHeld = "malibu_held"
        case malibuHoldReasons = "malibu_hold_reasons"
        case malibuDailyCap = "malibu_daily_cap"
        case malibuWalletDailyCap = "malibu_wallet_daily_cap"
        case malibuRewardEligibility = "malibu_reward_eligibility"
        case rewardAuditSupported = "reward_audit_supported"
        case idlePrewarm = "idle_prewarm"
        case malibuProjectionFresh = "malibu_projection_fresh"
        case earningsProjectionFresh = "earnings_projection_fresh"
        case payoutsEnabled = "payouts_enabled"
        case lastPaidJobAtUTC = "last_paid_job_at_utc"
        case malibuRetainedHoldReasons = "malibu_retained_hold_reasons"
        case trustProgress = "trust_progress"
        case emission
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        walletBound = try container.decodeIfPresent(Bool.self, forKey: .walletBound) ?? false
        trustTier = try container.decodeIfPresent(String.self, forKey: .trustTier) ?? "provisional"
        unpaidLedgerBacklogUSDC = try container.decodeIfPresent(
            Double.self,
            forKey: .unpaidLedgerBacklogUSDC
        ) ?? 0
        unpaidLedgerBacklogMALIBU = try container.decodeIfPresent(
            Double.self,
            forKey: .unpaidLedgerBacklogMALIBU
        ) ?? 0
        usdcToday = try container.decodeIfPresent(Double.self, forKey: .usdcToday)
        usdcWeek = try container.decodeIfPresent(Double.self, forKey: .usdcWeek)
        usdcPending = try container.decodeIfPresent(Double.self, forKey: .usdcPending)
        usdcLifetime = try container.decodeIfPresent(Double.self, forKey: .usdcLifetime)
        malibuToday = try container.decodeIfPresent(Double.self, forKey: .malibuToday)
        malibuAllTime = try container.decodeIfPresent(Double.self, forKey: .malibuAllTime)
        trustCriteriaMet = try container.decodeIfPresent(Int.self, forKey: .trustCriteriaMet)
        trustCriteriaRequired = try container.decodeIfPresent(Int.self, forKey: .trustCriteriaRequired)
        economicCriteria = try Self.decodePresencePreservingCriteria(container, forKey: .economicCriteria)
        additionalCriteria = try Self.decodePresencePreservingCriteria(container, forKey: .additionalCriteria)
        malibuWithdrawable = try container.decodeIfPresent(Double.self, forKey: .malibuWithdrawable)
        malibuHeld = try container.decodeIfPresent(Double.self, forKey: .malibuHeld)
        malibuHoldReasons = try container.decodeIfPresent([String].self, forKey: .malibuHoldReasons) ?? []
        malibuDailyCap = try container.decodeIfPresent(Double.self, forKey: .malibuDailyCap)
        malibuWalletDailyCap = try container.decodeIfPresent(Double.self, forKey: .malibuWalletDailyCap)
        idlePrewarm = try container.decodeIfPresent(
            ProviderIdlePrewarmSummary.self,
            forKey: .idlePrewarm
        ) ?? .empty
        let decodedMalibuProjectionFresh = try container.decodeIfPresent(
            Bool.self,
            forKey: .malibuProjectionFresh
        ) ?? false
        malibuProjectionFresh = decodedMalibuProjectionFresh
        if let decodedRewardEligibility = try container.decodeIfPresent(
            MalibuRewardEligibility.self,
            forKey: .malibuRewardEligibility
        ) {
            malibuRewardEligibility = decodedRewardEligibility
        } else if decodedMalibuProjectionFresh {
            malibuRewardEligibility = MalibuRewardEligibility.unavailableForMissingObject()
        } else {
            malibuRewardEligibility = nil
        }
        earningsProjectionFresh = try container.decodeIfPresent(Bool.self, forKey: .earningsProjectionFresh) ?? false
        rewardAuditSupported = try container.decodeIfPresent(Bool.self, forKey: .rewardAuditSupported) ?? false
        payoutsEnabled = try container.decodeIfPresent(Bool.self, forKey: .payoutsEnabled)
        lastPaidJobAtUTC = try container.decodeIfPresent(String.self, forKey: .lastPaidJobAtUTC)
        malibuRetainedHoldReasons = try container.decodeIfPresent([String].self, forKey: .malibuRetainedHoldReasons)
        trustProgress = try? container.decodeIfPresent(ProviderTrustProgressSummary.self, forKey: .trustProgress)
        emission = try? container.decodeIfPresent(ProviderEmissionSummary.self, forKey: .emission)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(walletBound, forKey: .walletBound)
        try container.encode(trustTier, forKey: .trustTier)
        try container.encode(unpaidLedgerBacklogUSDC, forKey: .unpaidLedgerBacklogUSDC)
        try container.encode(unpaidLedgerBacklogMALIBU, forKey: .unpaidLedgerBacklogMALIBU)
        try container.encodeIfPresent(usdcToday, forKey: .usdcToday)
        try container.encodeIfPresent(usdcWeek, forKey: .usdcWeek)
        try container.encodeIfPresent(usdcPending, forKey: .usdcPending)
        try container.encodeIfPresent(usdcLifetime, forKey: .usdcLifetime)
        try container.encodeIfPresent(malibuToday, forKey: .malibuToday)
        try container.encodeIfPresent(malibuAllTime, forKey: .malibuAllTime)
        try container.encodeIfPresent(trustCriteriaMet, forKey: .trustCriteriaMet)
        try container.encodeIfPresent(trustCriteriaRequired, forKey: .trustCriteriaRequired)
        try container.encodeIfPresent(economicCriteria, forKey: .economicCriteria)
        try container.encodeIfPresent(additionalCriteria, forKey: .additionalCriteria)
        try container.encodeIfPresent(malibuWithdrawable, forKey: .malibuWithdrawable)
        try container.encodeIfPresent(malibuHeld, forKey: .malibuHeld)
        try container.encode(malibuHoldReasons, forKey: .malibuHoldReasons)
        try container.encodeIfPresent(malibuDailyCap, forKey: .malibuDailyCap)
        try container.encodeIfPresent(malibuWalletDailyCap, forKey: .malibuWalletDailyCap)
        try container.encodeIfPresent(malibuRewardEligibility, forKey: .malibuRewardEligibility)
        if rewardAuditSupported {
            try container.encode(true, forKey: .rewardAuditSupported)
        }
        try container.encode(idlePrewarm, forKey: .idlePrewarm)
        try container.encode(malibuProjectionFresh, forKey: .malibuProjectionFresh)
        try container.encode(earningsProjectionFresh, forKey: .earningsProjectionFresh)
        try container.encodeIfPresent(payoutsEnabled, forKey: .payoutsEnabled)
        try container.encodeIfPresent(lastPaidJobAtUTC, forKey: .lastPaidJobAtUTC)
        try container.encodeIfPresent(malibuRetainedHoldReasons, forKey: .malibuRetainedHoldReasons)
        try container.encodeIfPresent(trustProgress, forKey: .trustProgress)
        try container.encodeIfPresent(emission, forKey: .emission)
    }

    private static func decodePresencePreservingCriteria(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> [String]? {
        guard container.contains(key) else { return nil }
        return try container.decodeIfPresent([String].self, forKey: key) ?? []
    }

    public init(
        walletBound: Bool,
        trustTier: String,
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
        economicCriteria: [String]? = nil,
        additionalCriteria: [String]? = nil,
        malibuWithdrawable: Double? = nil,
        malibuHeld: Double? = nil,
        malibuHoldReasons: [String] = [],
        malibuDailyCap: Double? = nil,
        malibuWalletDailyCap: Double? = nil,
        malibuRewardEligibility: MalibuRewardEligibility? = nil,
        rewardAuditSupported: Bool = false,
        idlePrewarm: ProviderIdlePrewarmSummary = .empty,
        malibuProjectionFresh: Bool = false,
        earningsProjectionFresh: Bool = false,
        payoutsEnabled: Bool? = nil,
        lastPaidJobAtUTC: String? = nil,
        malibuRetainedHoldReasons: [String]? = nil,
        trustProgress: ProviderTrustProgressSummary? = nil,
        emission: ProviderEmissionSummary? = nil
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
        self.economicCriteria = economicCriteria
        self.additionalCriteria = additionalCriteria
        self.malibuWithdrawable = malibuWithdrawable
        self.malibuHeld = malibuHeld
        self.malibuHoldReasons = malibuHoldReasons
        self.malibuDailyCap = malibuDailyCap
        self.malibuWalletDailyCap = malibuWalletDailyCap
        self.malibuRewardEligibility = malibuRewardEligibility
        self.rewardAuditSupported = rewardAuditSupported
        self.idlePrewarm = idlePrewarm
        self.malibuProjectionFresh = malibuProjectionFresh
        self.earningsProjectionFresh = earningsProjectionFresh
        self.payoutsEnabled = payoutsEnabled
        self.lastPaidJobAtUTC = lastPaidJobAtUTC
        self.malibuRetainedHoldReasons = malibuRetainedHoldReasons
        self.trustProgress = trustProgress
        self.emission = emission
    }

    func markingEarningsProjectionFresh() -> ProviderEarningsSummary {
        ProviderEarningsSummary(
            walletBound: walletBound,
            trustTier: trustTier,
            unpaidLedgerBacklogUSDC: unpaidLedgerBacklogUSDC,
            unpaidLedgerBacklogMALIBU: unpaidLedgerBacklogMALIBU,
            usdcToday: usdcToday,
            usdcWeek: usdcWeek,
            usdcPending: usdcPending,
            usdcLifetime: usdcLifetime,
            malibuToday: malibuToday,
            malibuAllTime: malibuAllTime,
            trustCriteriaMet: trustCriteriaMet,
            trustCriteriaRequired: trustCriteriaRequired,
            economicCriteria: economicCriteria,
            additionalCriteria: additionalCriteria,
            malibuWithdrawable: malibuWithdrawable,
            malibuHeld: malibuHeld,
            malibuHoldReasons: malibuHoldReasons,
            malibuDailyCap: malibuDailyCap,
            malibuWalletDailyCap: malibuWalletDailyCap,
            malibuRewardEligibility: nil,
            rewardAuditSupported: rewardAuditSupported,
            idlePrewarm: idlePrewarm,
            malibuProjectionFresh: false,
            earningsProjectionFresh: true,
            payoutsEnabled: payoutsEnabled,
            lastPaidJobAtUTC: lastPaidJobAtUTC
        )
    }

    func merging(accrual: MalibuAccrualSummary) -> ProviderEarningsSummary {
        ProviderEarningsSummary(
            walletBound: accrual.walletBound ?? false,
            trustTier: accrual.trustTier,
            unpaidLedgerBacklogUSDC: unpaidLedgerBacklogUSDC,
            unpaidLedgerBacklogMALIBU: unpaidLedgerBacklogMALIBU,
            usdcToday: usdcToday,
            usdcWeek: usdcWeek,
            usdcPending: usdcPending,
            usdcLifetime: usdcLifetime,
            malibuToday: nil,
            malibuAllTime: accrual.accruedMALIBU,
            trustCriteriaMet: accrual.trustCriteriaMet,
            trustCriteriaRequired: accrual.trustCriteriaRequired,
            economicCriteria: accrual.economicCriteria,
            additionalCriteria: accrual.additionalCriteria,
            malibuWithdrawable: accrual.withdrawableMALIBU,
            malibuHeld: accrual.heldMALIBU,
            malibuHoldReasons: accrual.withdrawalHoldReasons,
            malibuDailyCap: accrual.dailyCapMALIBU,
            malibuWalletDailyCap: accrual.walletDailyCapMALIBU,
            malibuRewardEligibility: accrual.rewardEligibility,
            rewardAuditSupported: rewardAuditSupported,
            idlePrewarm: idlePrewarm,
            malibuProjectionFresh: true,
            earningsProjectionFresh: earningsProjectionFresh,
            payoutsEnabled: payoutsEnabled,
            lastPaidJobAtUTC: lastPaidJobAtUTC,
            malibuRetainedHoldReasons: accrual.retainedHoldReasons,
            trustProgress: accrual.trustProgress,
            emission: accrual.emission
        )
    }

    func merging(walletStatus: ProviderWalletStatusSummary) -> ProviderEarningsSummary {
        guard !walletStatus.unavailable,
              let amounts = walletStatus.rewardAmounts,
              let inputs = walletStatus.eligibilityInputs,
              let eligibility = walletStatus.rewardEligibility else {
            return malibuProjectionFresh ? self : markingWalletStatusUnavailable()
        }
        return ProviderEarningsSummary(
            walletBound: walletStatus.walletBound,
            trustTier: inputs.trustTier,
            unpaidLedgerBacklogUSDC: unpaidLedgerBacklogUSDC,
            unpaidLedgerBacklogMALIBU: unpaidLedgerBacklogMALIBU,
            usdcToday: usdcToday,
            usdcWeek: usdcWeek,
            usdcPending: usdcPending,
            usdcLifetime: usdcLifetime,
            malibuToday: nil,
            malibuAllTime: amounts.accruedMALIBU,
            trustCriteriaMet: inputs.criteriaMet,
            trustCriteriaRequired: inputs.criteriaRequired,
            economicCriteria: inputs.economicCriteria,
            additionalCriteria: inputs.additionalCriteria,
            malibuWithdrawable: amounts.withdrawableMALIBU,
            malibuHeld: amounts.heldMALIBU,
            malibuHoldReasons: [],
            malibuDailyCap: amounts.providerDailyCapMALIBU,
            malibuWalletDailyCap: amounts.walletDailyCapMALIBU,
            malibuRewardEligibility: eligibility,
            rewardAuditSupported: rewardAuditSupported,
            idlePrewarm: idlePrewarm,
            malibuProjectionFresh: true,
            earningsProjectionFresh: earningsProjectionFresh,
            payoutsEnabled: payoutsEnabled,
            lastPaidJobAtUTC: lastPaidJobAtUTC,
            trustProgress: walletStatus.trustProgress,
            emission: walletStatus.emission
        )
    }

    func markingWalletStatusUnavailable() -> ProviderEarningsSummary {
        ProviderEarningsSummary(
            walletBound: false,
            trustTier: "provisional",
            unpaidLedgerBacklogUSDC: unpaidLedgerBacklogUSDC,
            unpaidLedgerBacklogMALIBU: unpaidLedgerBacklogMALIBU,
            usdcToday: usdcToday,
            usdcWeek: usdcWeek,
            usdcPending: usdcPending,
            usdcLifetime: usdcLifetime,
            malibuToday: nil,
            malibuAllTime: nil,
            trustCriteriaMet: nil,
            trustCriteriaRequired: nil,
            economicCriteria: nil,
            additionalCriteria: nil,
            malibuWithdrawable: nil,
            malibuHeld: nil,
            malibuHoldReasons: [],
            malibuDailyCap: nil,
            malibuWalletDailyCap: nil,
            malibuRewardEligibility: nil,
            rewardAuditSupported: rewardAuditSupported,
            idlePrewarm: idlePrewarm,
            malibuProjectionFresh: false,
            earningsProjectionFresh: earningsProjectionFresh,
            payoutsEnabled: payoutsEnabled,
            lastPaidJobAtUTC: lastPaidJobAtUTC
        )
    }

    static func from(accrual: MalibuAccrualSummary) -> ProviderEarningsSummary {
        unavailableWalletStatus().merging(accrual: accrual)
    }

    static func unavailableWalletStatus() -> ProviderEarningsSummary {
        ProviderEarningsSummary(
            walletBound: false,
            trustTier: "provisional",
            unpaidLedgerBacklogUSDC: 0,
            unpaidLedgerBacklogMALIBU: 0,
            usdcToday: nil,
            usdcWeek: nil,
            usdcPending: nil,
            usdcLifetime: nil,
            malibuToday: nil,
            malibuAllTime: nil,
            trustCriteriaMet: nil,
            trustCriteriaRequired: nil,
            economicCriteria: nil,
            additionalCriteria: nil,
            malibuWithdrawable: nil,
            malibuHeld: nil,
            malibuHoldReasons: [],
            malibuDailyCap: nil,
            malibuWalletDailyCap: nil,
            malibuRewardEligibility: nil,
            rewardAuditSupported: false,
            idlePrewarm: .empty,
            malibuProjectionFresh: false,
            earningsProjectionFresh: false
        )
    }

    func markingRewardAuditSupported() -> ProviderEarningsSummary {
        ProviderEarningsSummary(
            walletBound: walletBound,
            trustTier: trustTier,
            unpaidLedgerBacklogUSDC: unpaidLedgerBacklogUSDC,
            unpaidLedgerBacklogMALIBU: unpaidLedgerBacklogMALIBU,
            usdcToday: usdcToday,
            usdcWeek: usdcWeek,
            usdcPending: usdcPending,
            usdcLifetime: usdcLifetime,
            malibuToday: malibuToday,
            malibuAllTime: malibuAllTime,
            trustCriteriaMet: trustCriteriaMet,
            trustCriteriaRequired: trustCriteriaRequired,
            economicCriteria: economicCriteria,
            additionalCriteria: additionalCriteria,
            malibuWithdrawable: malibuWithdrawable,
            malibuHeld: malibuHeld,
            malibuHoldReasons: malibuHoldReasons,
            malibuDailyCap: malibuDailyCap,
            malibuWalletDailyCap: malibuWalletDailyCap,
            malibuRewardEligibility: malibuRewardEligibility,
            rewardAuditSupported: true,
            idlePrewarm: idlePrewarm,
            malibuProjectionFresh: malibuProjectionFresh,
            earningsProjectionFresh: earningsProjectionFresh,
            payoutsEnabled: payoutsEnabled,
            lastPaidJobAtUTC: lastPaidJobAtUTC,
            malibuRetainedHoldReasons: malibuRetainedHoldReasons,
            trustProgress: trustProgress,
            emission: emission
        )
    }
}

enum ProviderEarningsClientError: Error, Equatable {
    case invalidCoordinatorURL
    case httpStatus(Int)
    case unavailable
}

struct ProviderEarningsClient: Sendable {
    let earningsURL: URL
    private let session: URLSession?

    init(coordinatorURL: String?, providerID: String, session: URLSession? = nil) throws {
        guard let url = Self.earningsURL(from: coordinatorURL, providerID: providerID) else {
            throw ProviderEarningsClientError.invalidCoordinatorURL
        }
        self.earningsURL = url
        self.session = session
    }

    init(earningsURL: URL, session: URLSession? = nil) {
        self.earningsURL = earningsURL
        self.session = session
    }

    static func earningsURL(from coordinatorURL: String?, providerID: String) -> URL? {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty,
              let coordinatorURL,
              var components = URLComponents(string: coordinatorURL) else {
            return nil
        }
        switch components.scheme {
        case "wss":
            components.scheme = "https"
        case "https":
            break
        default:
            return nil
        }
        let pathSegmentAllowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )
        guard let escapedProviderID = trimmedProviderID.addingPercentEncoding(
            withAllowedCharacters: pathSegmentAllowed
        ) else {
            return nil
        }
        components.percentEncodedPath = "/providers/\(escapedProviderID)/earnings"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func fetch(bearerToken: String) async throws -> ProviderEarningsSummary {
        var request = URLRequest(url: earningsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        if let session {
            (data, response) = try await session.data(for: request)
        } else {
            let ephemeral = URLSession(
                configuration: .ephemeral,
                delegate: NoRedirectURLSessionDelegate(),
                delegateQueue: nil
            )
            defer { ephemeral.finishTasksAndInvalidate() }
            (data, response) = try await ephemeral.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderEarningsClientError.unavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderEarningsClientError.httpStatus(http.statusCode)
        }
        return try JSONDecoder()
            .decode(ProviderEarningsSummary.self, from: data)
            .markingEarningsProjectionFresh()
    }
}
