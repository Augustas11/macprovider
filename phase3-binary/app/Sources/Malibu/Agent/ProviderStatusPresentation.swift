import Foundation

// Provider status lines shared by the Dashboard, Provider and Diagnostics
// screens. Reported values only; absent values are omitted, never zero.
extension AgentSnapshotPresenter {
    static func requestsLine(_ s: AgentSnapshot) -> String {
        [
            "\(s.requestsServedToday.map(formatCount) ?? "—") \(todayLabel(s))",
            "\(s.requestsServedAllTime.map(formatCount) ?? "—") all-time",
            s.requestsPerMinute.map { String(format: "%.1f req/min", $0) },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    static func tokenLine(_ s: AgentSnapshot) -> String {
        func pair(_ input: Int64?, _ output: Int64?, _ suffix: String) -> String {
            guard input != nil || output != nil else { return "— \(suffix)" }
            return "\(input.map { formatTokens($0) } ?? "—") in / \(output.map { formatTokens($0) } ?? "—") out \(suffix)"
        }
        return pair(s.inputTokensToday, s.outputTokensToday, todayLabel(s))
            + "\n" + pair(s.inputTokensAllTime, s.outputTokensAllTime, "all-time")
    }

    /// Current run plus restarts, with the lifetime count labelled as such.
    static func runLine(_ s: AgentSnapshot) -> String {
        var parts: [String] = []
        if let sec = s.uptimeSec, isActive(s) { parts.append("\(formatDuration(sec)) current run") }
        if let recent = s.restartCount7d { parts.append("\(recent) restart\(recent == 1 ? "" : "s") in 7 days") }
        if let lifetime = s.restartCount { parts.append("\(formatCount(lifetime)) restarts lifetime") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// Chips for values the provider actually reported; absent values are
    /// omitted rather than shown as "n/a" or an invented zero.
    static func diagnosticChips(_ s: AgentSnapshot) -> [String] {
        [
            s.queueDepth.map { "\($0) queued" },
            s.thermalState.map { "Thermal \($0.label.lowercased())" },
            s.gpuUtilizationPct.map { String(format: "GPU %.0f%%", $0) },
            s.latencyP50Ms.map { "avg latency \($0) ms" },
        ].compactMap { $0 }
    }

    /// A setup failure is current only while the provider has not returned to
    /// serving since it happened.
    static func currentSetupFailure(_ s: AgentSnapshot) -> ProviderLifecycleEventSnapshot? {
        guard let event = s.lifecycleLastRejection else { return nil }
        if s.lifecycleState == "serving_buyers",
           let servingSince = s.lifecycleTransitionAt,
           servingSince >= event.transitionAt {
            return nil
        }
        return event
    }

    /// The last software change, hidden when it names software that is no
    /// longer installed (an older CLI that recorded only self-updates).
    static func currentLastUpdate(_ s: AgentSnapshot) -> ProviderLifecycleEventSnapshot? {
        guard let event = s.lifecycleLastUpdate else { return nil }
        if let recorded = event.compatibilitySetID,
           let current = s.compatibilitySetID,
           recorded != current {
            return nil
        }
        return event
    }

    static func lifecycleEventDisplay(_ event: ProviderLifecycleEventSnapshot) -> String {
        "\(lifecycleEventSummary(event)) · \(event.transitionAt.formatted(date: .abbreviated, time: .shortened))"
    }

    static func lastUpdateDisplay(_ event: ProviderLifecycleEventSnapshot) -> String {
        let summary = event.state == "rollback_in_progress"
            ? "Rolled back provider software"
            : "Provider software updated"
        return "\(summary) · \(event.transitionAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private static func lifecycleEventSummary(_ event: ProviderLifecycleEventSnapshot) -> String {
        switch event.reason {
        case "launchd_service_started": return "Provider service started"
        case "serve_invoked": return "Provider start requested"
        case "maintenance_handoff_restart": return "Restarted after a software update"
        case "watchdog_recovery_restart": return "Restarted by provider recovery"
        case "catalog_incompatible": return "Catalog refresh needed"
        default: return lifecycleStateLabel(event.state, reason: event.reason)
        }
    }
}
