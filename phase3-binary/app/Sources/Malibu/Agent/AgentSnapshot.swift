import Foundation

// AUDIT R1 ARCHITECT A1 / A5 fix.
//
// AgentSnapshot is now a pure domain type — no localized/formatted strings.
// - Earnings/metrics are Optional so "not reported yet" is distinct from "0".
//   The CLI stub returns 0/0/0 today; rendering that as authoritative "$0.00"
//   masked the "unimplemented" reality to the user.
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

    // Whether the CLI has explicitly acknowledged a pause; distinct from
    // "we optimistically flipped the UI" — pauseAck accepted:false must NOT
    // leave the UI showing Paused.
    var pauseAcknowledged: Bool

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
        pauseAcknowledged: false
    )
}

enum AgentSnapshotPresenter {
    static func short(_ s: AgentSnapshot) -> String {
        switch s.state {
        case .idle, .starting: return "Idle"
        case .serving:
            if let usdc = s.earningsUsdcToday { return String(format: "$%.2f", usdc) }
            return "—"
        case .paused:         return "Paused"
        case .reconnecting:   return "…"
        case .error:          return "!"
        }
    }

    static func stateLine(_ s: AgentSnapshot) -> String {
        switch s.state {
        case .idle:         return "Not running"
        case .starting:     return "Starting…"
        case .serving:      return "Serving " + (s.currentModelID ?? "model")
        case .paused:       return "Paused"
        case .reconnecting: return "Reconnecting…"
        case .error:        return s.lastError ?? "Error"
        }
    }

    static func earningsLine(_ s: AgentSnapshot) -> String {
        // AUDIT R1 ARCHITECT A1: distinguish "no data yet" from "$0.00".
        switch (s.earningsUsdcToday, s.malibuAccruedToday) {
        case (nil, nil):
            return "Today: — USDC · — MALIBU (metrics not implemented)"
        case let (usdc?, malibu?):
            return String(format: "Today: $%.2f USDC · %@", usdc, malibuDisplay(malibu, tier: s.trustTier))
        case let (usdc?, nil):
            return String(format: "Today: $%.2f USDC · — MALIBU", usdc)
        case let (nil, malibu?):
            return "Today: — USDC · \(malibuDisplay(malibu, tier: s.trustTier))"
        }
    }

    static func backlogLine(_ s: AgentSnapshot) -> String? {
        guard s.walletBound == false,
              let usdc = s.unpaidLedgerBacklogUSDC,
              let malibu = s.unpaidLedgerBacklogMALIBU,
              usdc + malibu > 0 else {
            return nil
        }
        return String(format: "Unclaimed: $%.2f USDC · %@", usdc, malibuDisplay(malibu, tier: s.trustTier))
    }

    static func modelLine(_ s: AgentSnapshot) -> String {
        s.currentModelID ?? "—"
    }

    static func requestsLine(_ s: AgentSnapshot) -> String {
        [
            s.requestsServedToday.map { "\(formatCount($0)) today" } ?? "— today",
            s.requestsServedAllTime.map { "\(formatCount($0)) all-time" } ?? "— all-time",
            s.requestsPerMinute.map { String(format: "%.1f req/min", $0) } ?? "— req/min"
        ].joined(separator: " · ")
    }

    static func tokenLine(_ s: AgentSnapshot) -> String {
        let today = tokenPair(input: s.inputTokensToday, output: s.outputTokensToday, suffix: "today")
        let allTime = tokenPair(input: s.inputTokensAllTime, output: s.outputTokensAllTime, suffix: "all-time")
        return "\(today)\n\(allTime)"
    }

    static func usdcFullLine(_ s: AgentSnapshot) -> String {
        [
            s.earningsUsdcToday.map { String(format: "$%.2f today", $0) } ?? "$— today",
            s.earningsUsdcWeek.map { String(format: "$%.2f wk", $0) } ?? "$— wk",
            s.earningsUsdcPending.map { String(format: "$%.2f pending", $0) } ?? "$— pending",
            s.earningsUsdcLifetime.map { String(format: "$%.2f life", $0) } ?? "$— life"
        ].joined(separator: " · ")
    }

    static func malibuFullLine(_ s: AgentSnapshot) -> String {
        let today = s.malibuAccruedToday.map { malibuDisplay($0, tier: s.trustTier, compact: true) } ?? "— MALIBU today"
        let allTime = s.malibuAccruedAllTime.map { String(format: "%.2f all-time", $0) } ?? "— all-time"
        switch s.trustTier {
        case .trusted:
            return "\(today) · \(allTime)"
        case .provisional:
            return "\(today) · \(allTime) · [locked] unlocks at Trusted"
        }
    }

    static func trustLine(_ s: AgentSnapshot) -> String {
        let tier = s.trustTier.rawValue.capitalized
        if let met = s.trustCriteriaMet, let required = s.trustCriteriaRequired {
            return "\(tier) — \(met) of \(required) criteria met · Unlock Trusted →"
        }
        return tier
    }

    static func uptimeLine(_ s: AgentSnapshot) -> String {
        [
            s.uptime7dPct.map { String(format: "%.1f%% uptime (7d)", $0) } ?? "— uptime (7d)",
            s.declinedRequests.map { "\($0) declined" } ?? "— declined",
            s.restartCount.map { "\($0) restarts" } ?? "— restarts"
        ].joined(separator: " · ")
    }

    static func gpuChip(_ s: AgentSnapshot) -> String {
        if let util = s.gpuUtilizationPct {
            return String(format: "GPU %.0f%%", util)
        }
        if let temp = s.gpuTemperatureC {
            return String(format: "GPU %.0f°C", temp)
        }
        return "GPU —"
    }

    static func latencyChip(_ s: AgentSnapshot) -> String {
        switch (s.latencyP50Ms, s.latencyP99Ms) {
        case let (p50?, p99?):
            return "p50 \(p50)ms · p99 \(p99)ms"
        case let (p50?, nil):
            return "p50 \(p50)ms · p99 —"
        case let (nil, p99?):
            return "p50 — · p99 \(p99)ms"
        case (nil, nil):
            return "Latency —"
        }
    }

    static func queueChip(_ s: AgentSnapshot) -> String {
        guard let depth = s.queueDepth else { return "— queued" }
        return "\(depth) queued"
    }

    static func thermalChip(_ s: AgentSnapshot) -> String {
        s.thermalState?.label ?? "Thermal —"
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
        guard s.walletBound == false else { return nil }
        let total = (s.unpaidLedgerBacklogUSDC ?? 0) + (s.unpaidLedgerBacklogMALIBU ?? 0)
        return total > 0 ? total : nil
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

    private static func tokenPair(input: Int64?, output: Int64?, suffix: String) -> String {
        "\(formatTokens(input)) in / \(formatTokens(output)) out \(suffix)"
    }

    private static func formatTokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
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
}
