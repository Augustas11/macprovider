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

    var cliVersion: String?
    /// Whether macprovider-cli reports an active coordinator WebSocket session.
    /// Distinct from verified buyer-serving readiness.
    var coordinatorConnected: Bool?
    /// Canonical provider state reported by /v1/status. `buyer_serving` is the
    /// only state that proves local readiness, catalog trust, and admission.
    var networkState: String?
    var catalogState: String?
    var catalogReleaseID: String?
    var catalogDigest: String?
    var catalogSignerKeyID: String?
    var catalogSource: String?
    var coordinatorRecommendedVersion: String?
    var latestReleaseVersion: String?
    var cliUpdateInProgress: Bool
    var cliUpdateLastError: String?

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
        cliVersion: nil,
        coordinatorConnected: nil,
        networkState: nil,
        catalogState: nil,
        catalogReleaseID: nil,
        catalogDigest: nil,
        catalogSignerKeyID: nil,
        catalogSource: nil,
        coordinatorRecommendedVersion: nil,
        latestReleaseVersion: nil,
        cliUpdateInProgress: false,
        cliUpdateLastError: nil,
        pauseAcknowledged: false
    )
}

enum AgentSnapshotPresenter {
    private static func isActive(_ s: AgentSnapshot) -> Bool {
        s.state == .serving || s.state == .paused || isLocalOnly(s)
    }

    private static func isNetworkReady(_ s: AgentSnapshot) -> Bool {
        guard s.state == .serving else { return false }
        if let networkState = s.networkState {
            return networkState == "buyer_serving"
        }
        return s.coordinatorConnected == true
    }

    private static func isLocalOnly(_ s: AgentSnapshot) -> Bool {
        s.state == .reconnecting && s.currentModelID != nil
    }

    static func short(_ s: AgentSnapshot) -> String {
        switch s.state {
        case .idle, .starting: return "Idle"
        case .serving:
            if let usdc = s.earningsUsdcToday { return String(format: "$%.2f", usdc) }
            return "Serving"
        case .paused:         return "Paused"
        case .reconnecting:   return "Sync"
        case .error:          return "!"
        }
    }

    static func dashboardHeadline(_ s: AgentSnapshot) -> String {
        switch s.state {
        case .idle:         return "Not running"
        case .starting:     return "Starting…"
        case .serving:      return "Serving"
        case .paused:       return "Paused"
        case .reconnecting:
            return isLocalOnly(s) ? "Local only" : "Reconnecting…"
        case .error:        return "Error"
        }
    }

    static func dashboardSubtitle(_ s: AgentSnapshot) -> String? {
        switch s.state {
        case .serving where s.earningsUsdcToday == nil:
            return "Connected to coordinator · waiting for first paid job"
        case .serving:
            return s.currentModelID
        case .reconnecting where isLocalOnly(s):
            return s.lastError ?? "Model loaded locally · reconnecting to coordinator"
        case .reconnecting:
            return s.lastError ?? "Checking background provider…"
        case .starting:
            return s.lastError ?? "Waiting for the background provider to respond…"
        case .error:
            return s.lastError
        default:
            return nil
        }
    }

    static func stateLine(_ s: AgentSnapshot) -> String {
        switch s.state {
        case .idle:         return "Not running"
        case .starting:     return "Starting…"
        case .serving:      return "Serving " + (s.currentModelID ?? "model")
        case .paused:       return "Paused"
        case .reconnecting:
            if isLocalOnly(s) {
                return "Local only · " + (s.currentModelID ?? "model loaded")
            }
            return "Reconnecting…"
        case .error:        return s.lastError ?? "Error"
        }
    }

    static func earningsLine(_ s: AgentSnapshot) -> String {
        switch (s.earningsUsdcToday, s.malibuAccruedToday) {
        case (nil, nil):
            if isActive(s) {
                return "Today: $0.00 USDC · 0.00 MALIBU (no jobs yet)"
            }
            return "Today: not running"
        case let (usdc?, malibu?):
            return String(format: "Today: $%.2f USDC · %@", usdc, malibuDisplay(malibu, tier: s.trustTier))
        case let (usdc?, nil):
            return String(format: "Today: $%.2f USDC · 0.00 MALIBU", usdc)
        case let (nil, malibu?):
            return "Today: $0.00 USDC · \(malibuDisplay(malibu, tier: s.trustTier))"
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
        if let model = s.currentModelID { return model }
        if isNetworkReady(s) { return "Connected" }
        if isLocalOnly(s) { return "Local only" }
        return isActive(s) ? "Connected" : "Not running"
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
        let unset = isActive(s) ? "$0.00" : "n/a"
        return [
            s.earningsUsdcToday.map { String(format: "$%.2f today", $0) } ?? "\(unset) today",
            s.earningsUsdcWeek.map { String(format: "$%.2f wk", $0) } ?? "\(unset) wk",
            s.earningsUsdcPending.map { String(format: "$%.2f pending", $0) } ?? "\(unset) pending",
            s.earningsUsdcLifetime.map { String(format: "$%.2f life", $0) } ?? "\(unset) life"
        ].joined(separator: " · ")
    }

    static func usdcTodayDisplay(_ s: AgentSnapshot) -> String {
        s.earningsUsdcToday.map { String(format: "$%.2f", $0) } ?? (isActive(s) ? "$0.00" : "n/a")
    }

    static func malibuFullLine(_ s: AgentSnapshot) -> String {
        let today = s.malibuAccruedToday.map { malibuDisplay($0, tier: s.trustTier, compact: true) }
            ?? (isActive(s) ? "0.00 MALIBU today" : "n/a MALIBU today")
        let allTime = s.malibuAccruedAllTime.map { String(format: "%.2f all-time", $0) }
            ?? (isActive(s) ? "0.00 all-time" : "n/a all-time")
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
        var parts: [String] = []
        if let sec = s.uptimeSec, isActive(s) {
            parts.append("\(formatDuration(sec)) up")
        } else if isActive(s) {
            parts.append("uptime n/a")
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
        guard s.walletBound == false else { return nil }
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
        updateTargetVersion(s) != nil
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
        } else if let latest = s.latestReleaseVersion {
            parts.append("latest v\(latest)")
        } else if let recommended = s.coordinatorRecommendedVersion {
            parts.append("coordinator v\(recommended)")
        } else {
            parts.append("up to date")
        }
        return parts.joined(separator: " · ")
    }

    static func cliUpdateStatusLine(_ s: AgentSnapshot) -> String? {
        if s.cliUpdateInProgress {
            return "Updating provider CLI…"
        }
        if let error = s.cliUpdateLastError {
            return error
        }
        return nil
    }

    static func cliVersionMenuLine(_ s: AgentSnapshot) -> String? {
        guard let current = s.cliVersion else { return nil }
        if let target = updateTargetVersion(s) {
            return "CLI v\(current) · v\(target) available"
        }
        return "CLI v\(current) · up to date"
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
