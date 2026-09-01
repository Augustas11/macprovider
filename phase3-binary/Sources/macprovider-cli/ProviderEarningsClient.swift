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
    /// Satisfied economic/additional trust-criterion IDs (SPEC-026 §5.2) and
    /// supporting counters, sourced from the wallet-status eligibility inputs.
    /// Forwarded so Malibu can name which Trusted criteria are done vs pending.
    public let economicCriteria: [String]
    public let additionalCriteria: [String]
    public let verifiedReceiptCount: Int?
    public let appAttested: Bool?
    public let malibuWithdrawable: Double?
    public let malibuHeld: Double?
    public let malibuHoldReasons: [String]
    public let malibuDailyCap: Double?
    public let malibuWalletDailyCap: Double?
    public let malibuRewardEligibility: MalibuRewardEligibility?
    /// Last-hour idle-prewarm event/skip counts, used to explain why a
    /// serving provider is not currently earning (on battery, thermal
    /// throttle, model not loaded). Display-only.
    public let idlePrewarm: ProviderIdlePrewarmSummary
    /// True only when GET /providers/{id}/earnings returned this projection.
    public let earningsProjectionFresh: Bool
    /// True only when the companion MALIBU accrual projection was fetched in
    /// the same metrics cycle. A provider-earnings response alone must not
    /// authorize reward availability or trust copy.
    public let malibuProjectionFresh: Bool
    /// True when the CLI reached the reward/wallet telemetry but it FAILED
    /// (schema/decode outage), as distinct from a benign first-run absence.
    /// The app uses this to surface an honest "reward status unavailable"
    /// instead of the calm "warming up" first-run copy. Default false.
    public let rewardTelemetryUnavailable: Bool

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
        case verifiedReceiptCount = "verified_receipt_count"
        case appAttested = "app_attested"
        case malibuWithdrawable = "malibu_withdrawable"
        case malibuHeld = "malibu_held"
        case malibuHoldReasons = "malibu_hold_reasons"
        case malibuDailyCap = "malibu_daily_cap"
        case malibuWalletDailyCap = "malibu_wallet_daily_cap"
        case malibuRewardEligibility = "malibu_reward_eligibility"
        case idlePrewarm = "idle_prewarm"
        case malibuProjectionFresh = "malibu_projection_fresh"
        case earningsProjectionFresh = "earnings_projection_fresh"
        case rewardTelemetryUnavailable = "reward_telemetry_unavailable"
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
        economicCriteria = try container.decodeIfPresent([String].self, forKey: .economicCriteria) ?? []
        additionalCriteria = try container.decodeIfPresent([String].self, forKey: .additionalCriteria) ?? []
        verifiedReceiptCount = try container.decodeIfPresent(Int.self, forKey: .verifiedReceiptCount)
        appAttested = try container.decodeIfPresent(Bool.self, forKey: .appAttested)
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
        rewardTelemetryUnavailable = try container.decodeIfPresent(
            Bool.self,
            forKey: .rewardTelemetryUnavailable
        ) ?? false
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
        economicCriteria: [String] = [],
        additionalCriteria: [String] = [],
        verifiedReceiptCount: Int? = nil,
        appAttested: Bool? = nil,
        malibuWithdrawable: Double? = nil,
        malibuHeld: Double? = nil,
        malibuHoldReasons: [String] = [],
        malibuDailyCap: Double? = nil,
        malibuWalletDailyCap: Double? = nil,
        malibuRewardEligibility: MalibuRewardEligibility? = nil,
        idlePrewarm: ProviderIdlePrewarmSummary = .empty,
        malibuProjectionFresh: Bool = false,
        earningsProjectionFresh: Bool = false,
        rewardTelemetryUnavailable: Bool = false
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
        self.verifiedReceiptCount = verifiedReceiptCount
        self.appAttested = appAttested
        self.malibuWithdrawable = malibuWithdrawable
        self.malibuHeld = malibuHeld
        self.malibuHoldReasons = malibuHoldReasons
        self.malibuDailyCap = malibuDailyCap
        self.malibuWalletDailyCap = malibuWalletDailyCap
        self.malibuRewardEligibility = malibuRewardEligibility
        self.idlePrewarm = idlePrewarm
        self.malibuProjectionFresh = malibuProjectionFresh
        self.earningsProjectionFresh = earningsProjectionFresh
        self.rewardTelemetryUnavailable = rewardTelemetryUnavailable
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
            verifiedReceiptCount: verifiedReceiptCount,
            appAttested: appAttested,
            malibuWithdrawable: malibuWithdrawable,
            malibuHeld: malibuHeld,
            malibuHoldReasons: malibuHoldReasons,
            malibuDailyCap: malibuDailyCap,
            malibuWalletDailyCap: malibuWalletDailyCap,
            malibuRewardEligibility: nil,
            idlePrewarm: idlePrewarm,
            malibuProjectionFresh: false,
            earningsProjectionFresh: true
        )
    }

    func merging(accrual: MalibuAccrualSummary) -> ProviderEarningsSummary {
        ProviderEarningsSummary(
            walletBound: accrual.walletBound ?? walletBound,
            trustTier: accrual.trustTier,
            unpaidLedgerBacklogUSDC: unpaidLedgerBacklogUSDC,
            unpaidLedgerBacklogMALIBU: unpaidLedgerBacklogMALIBU,
            usdcToday: usdcToday,
            usdcWeek: usdcWeek,
            usdcPending: usdcPending,
            usdcLifetime: usdcLifetime,
            malibuToday: malibuToday,
            malibuAllTime: accrual.accruedMALIBU,
            trustCriteriaMet: accrual.trustCriteriaMet ?? trustCriteriaMet,
            trustCriteriaRequired: accrual.trustCriteriaRequired ?? trustCriteriaRequired,
            economicCriteria: accrual.economicCriteria.isEmpty ? economicCriteria : accrual.economicCriteria,
            additionalCriteria: accrual.additionalCriteria.isEmpty ? additionalCriteria : accrual.additionalCriteria,
            verifiedReceiptCount: accrual.verifiedReceiptCount ?? verifiedReceiptCount,
            appAttested: accrual.appAttested ?? appAttested,
            malibuWithdrawable: accrual.withdrawableMALIBU,
            malibuHeld: accrual.heldMALIBU,
            malibuHoldReasons: accrual.withdrawalHoldReasons,
            malibuDailyCap: accrual.dailyCapMALIBU,
            malibuWalletDailyCap: accrual.walletDailyCapMALIBU,
            malibuRewardEligibility: accrual.rewardEligibility,
            idlePrewarm: idlePrewarm,
            malibuProjectionFresh: true,
            earningsProjectionFresh: earningsProjectionFresh
        )
    }

    func merging(walletStatus: ProviderWalletStatusSummary) -> ProviderEarningsSummary {
        if walletStatus.unavailable {
            return markingWalletStatusUnavailable()
        }
        return ProviderEarningsSummary(
            walletBound: walletStatus.walletBound,
            trustTier: walletStatus.eligibilityInputs?.trustTier ?? trustTier,
            unpaidLedgerBacklogUSDC: unpaidLedgerBacklogUSDC,
            unpaidLedgerBacklogMALIBU: unpaidLedgerBacklogMALIBU,
            usdcToday: usdcToday,
            usdcWeek: usdcWeek,
            usdcPending: usdcPending,
            usdcLifetime: usdcLifetime,
            malibuToday: malibuToday,
            malibuAllTime: walletStatus.rewardAmounts?.accruedMALIBU ?? malibuAllTime,
            trustCriteriaMet: walletStatus.eligibilityInputs?.criteriaMet ?? trustCriteriaMet,
            trustCriteriaRequired: walletStatus.eligibilityInputs?.criteriaRequired ?? trustCriteriaRequired,
            economicCriteria: walletStatus.eligibilityInputs?.economicCriteria ?? economicCriteria,
            additionalCriteria: walletStatus.eligibilityInputs?.additionalCriteria ?? additionalCriteria,
            verifiedReceiptCount: walletStatus.eligibilityInputs?.verifiedReceiptCount ?? verifiedReceiptCount,
            appAttested: walletStatus.eligibilityInputs?.appAttested ?? appAttested,
            malibuWithdrawable: walletStatus.rewardAmounts?.withdrawableMALIBU ?? malibuWithdrawable,
            malibuHeld: walletStatus.rewardAmounts?.heldMALIBU ?? malibuHeld,
            malibuHoldReasons: malibuHoldReasons,
            malibuDailyCap: walletStatus.rewardAmounts?.providerDailyCapMALIBU ?? malibuDailyCap,
            malibuWalletDailyCap: walletStatus.rewardAmounts?.walletDailyCapMALIBU ?? malibuWalletDailyCap,
            malibuRewardEligibility: walletStatus.rewardEligibility,
            idlePrewarm: idlePrewarm,
            malibuProjectionFresh: true,
            earningsProjectionFresh: earningsProjectionFresh
        )
    }

    func markingWalletStatusUnavailable() -> ProviderEarningsSummary {
        // A wallet-status schema/decode failure is a genuine telemetry outage,
        // NOT a fresh benign projection. Preserve the earnings-frame walletBound
        // (do not fabricate walletBound=false → false "No payout wallet yet"),
        // and mark the MALIBU projection NOT fresh so the app reads it as
        // "reward status not available", never first-run "warming up".
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
            malibuAllTime: nil,
            trustCriteriaMet: nil,
            trustCriteriaRequired: nil,
            economicCriteria: [],
            additionalCriteria: [],
            verifiedReceiptCount: nil,
            appAttested: nil,
            malibuWithdrawable: nil,
            malibuHeld: nil,
            malibuHoldReasons: [],
            malibuDailyCap: nil,
            malibuWalletDailyCap: nil,
            malibuRewardEligibility: nil,
            idlePrewarm: idlePrewarm,
            malibuProjectionFresh: false,
            earningsProjectionFresh: earningsProjectionFresh,
            // A wallet-status decode/schema failure is a genuine telemetry
            // outage, not benign first-run absence. Signal it explicitly so the
            // app does not soften it into calm "warming up" copy.
            rewardTelemetryUnavailable: true
        )
    }

    static func from(accrual: MalibuAccrualSummary) -> ProviderEarningsSummary {
        ProviderEarningsSummary(
            walletBound: accrual.walletBound ?? false,
            trustTier: accrual.trustTier,
            unpaidLedgerBacklogUSDC: 0,
            unpaidLedgerBacklogMALIBU: 0,
            usdcToday: nil,
            usdcWeek: nil,
            usdcPending: nil,
            usdcLifetime: nil,
            malibuToday: nil,
            malibuAllTime: accrual.accruedMALIBU,
            trustCriteriaMet: accrual.trustCriteriaMet,
            trustCriteriaRequired: accrual.trustCriteriaRequired,
            economicCriteria: accrual.economicCriteria,
            additionalCriteria: accrual.additionalCriteria,
            verifiedReceiptCount: accrual.verifiedReceiptCount,
            appAttested: accrual.appAttested,
            malibuWithdrawable: accrual.withdrawableMALIBU,
            malibuHeld: accrual.heldMALIBU,
            malibuHoldReasons: accrual.withdrawalHoldReasons,
            malibuDailyCap: accrual.dailyCapMALIBU,
            malibuWalletDailyCap: accrual.walletDailyCapMALIBU,
            malibuRewardEligibility: accrual.rewardEligibility,
            idlePrewarm: .empty,
            malibuProjectionFresh: true,
            earningsProjectionFresh: false
        )
    }

    static func unavailableWalletStatus() -> ProviderEarningsSummary {
        // No earnings frame and wallet-status unavailable: a telemetry outage,
        // not a fresh benign projection. Keep the MALIBU projection NOT fresh
        // and signal the outage explicitly so the app never softens this
        // no-base wallet-status failure into calm first-run "warming up" copy.
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
            malibuWithdrawable: nil,
            malibuHeld: nil,
            malibuHoldReasons: [],
            malibuDailyCap: nil,
            malibuWalletDailyCap: nil,
            malibuRewardEligibility: nil,
            idlePrewarm: .empty,
            malibuProjectionFresh: false,
            earningsProjectionFresh: false,
            rewardTelemetryUnavailable: true
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
