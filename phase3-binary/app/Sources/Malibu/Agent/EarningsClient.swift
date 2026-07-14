import Foundation

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
        trustCriteriaRequired: Int?
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
