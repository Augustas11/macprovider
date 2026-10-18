import Foundation

// #2029 Phase 1: copy for the lean, truthful dashboard (SPEC-025 §3.2).
//
// Rules this file keeps:
// - one status pill describes customer serving only; rewards live in the
//   Earnings card;
// - held MALIBU is described as held, not released, and not withdrawable,
//   with no implication that it will be released (SPEC-021 §3);
// - an unreported value renders as absent, never as an invented zero;
// - no machine reason codes, no $/time projections (SPEC-044-R004).
extension AgentSnapshotPresenter {
    struct StatusPill: Equatable {
        let label: String
        let tone: ConsolidatedStatus.Tone

        var accessibilityLabel: String { "Malibu status: \(label)" }
    }

    struct EarningsCard: Equatable {
        /// Lifetime, week, and UTC-day USDC, or why they are unavailable.
        let usdcSummary: String
        /// The payout state, from a fresh earnings read only. It carries no
        /// amount: the pending figure is not net of past payouts.
        let payoutLine: String?
        let malibuLines: [String]
        let trustLine: String?
        /// Shown only while MALIBU emission runs and the coordinator reports
        /// no verified hardware evidence for this Mac.
        let hardwareBlocker: String?
    }

    static func statusPill(_ s: AgentSnapshot) -> StatusPill {
        let status = consolidatedStatus(s)
        switch s.state {
        case .paused: return StatusPill(label: "Paused", tone: .neutral)
        case .idle: return StatusPill(label: "Not running", tone: .neutral)
        case .error: return StatusPill(label: "Needs attention", tone: .attention)
        default: break
        }
        switch status.phase {
        case .live:
            return StatusPill(label: "Serving", tone: .positive)
        case .settingUp:
            return StatusPill(label: "Setting up", tone: .neutral)
        case .needsAttention:
            return status.tone == .attention
                ? StatusPill(label: "Needs attention", tone: .attention)
                : StatusPill(label: "Not receiving work", tone: .neutral)
        }
    }

    static func earningsCard(_ s: AgentSnapshot, now: Date = Date()) -> EarningsCard {
        let verdict = rewardVerdict(s)
        return EarningsCard(
            usdcSummary: usdcSummary(s, verdict: verdict),
            payoutLine: payoutLine(s, verdict: verdict),
            malibuLines: malibuLines(s, verdict: verdict),
            trustLine: trustLine(s, verdict: verdict, now: now),
            hardwareBlocker: s.malibuEmission?.active == true && verdict.earningNeedsHardwareEvidence
                ? "New MALIBU needs verified hardware evidence for this Mac. Export diagnostics for support."
                : nil
        )
    }

    private static func usdcSummary(_ s: AgentSnapshot, verdict: RewardVerdict) -> String {
        guard canShowLastKnownUSDC(s, verdict: verdict) else {
            return isActive(s) ? "USDC earnings are unavailable right now." : "Start the provider to see earnings."
        }
        let parts = [
            s.earningsUsdcLifetime.map { "\(formatUSDC($0)) lifetime" },
            s.earningsUsdcWeek.map { "\(formatUSDC($0)) this week" },
            s.earningsUsdcToday.map { "\(formatUSDC($0)) today (UTC)" },
        ].compactMap { $0 }
        guard !parts.isEmpty else { return "USDC earnings are unavailable right now." }
        let line = parts.joined(separator: " · ")
        return isShowingLastKnownUSDC(s, verdict: verdict) ? "Last known: \(line)" : line
    }

    private static func payoutLine(_ s: AgentSnapshot, verdict: RewardVerdict) -> String? {
        guard verdict.providerEarningsFresh, s.payoutsEnabled == false else { return nil }
        return "Payouts are not enabled yet in beta. USDC earnings stay recorded."
    }

    private static func malibuLines(_ s: AgentSnapshot, verdict: RewardVerdict) -> [String] {
        if verdict.malibuWithdrawal == .unavailable {
            return ["MALIBU status can't be reached right now. USDC earnings are unaffected."]
        }
        guard verdict.malibuProjectionFresh else {
            if let total = s.malibuAccruedAllTime {
                return [String(format: "MALIBU balance: %.2f (beta points, last known).", total)]
            }
            return ["MALIBU status is unavailable right now."]
        }
        if case .unknown = verdict.malibuWithdrawal {
            return ["MALIBU status is unavailable right now."]
        }
        var lines: [String] = []
        if let emission = s.malibuEmission, !emission.active {
            var line = "MALIBU rewards are paused network-wide."
            if let last = emission.lastAccrualAt {
                line += " No new MALIBU since \(shortDate(last))."
            }
            lines.append(line)
        }
        let held = max(0, verdict.malibuHeld ?? 0)
        if let total = s.malibuAccruedAllTime {
            if held > 0 {
                // Not held = total minus held; stake locks are not holds.
                let notHeld = max(0, total - held)
                lines.append(String(format: "MALIBU balance: %.2f (beta points) · %.2f held · %.2f not held.", total, held, notHeld))
            } else {
                lines.append(String(format: "MALIBU balance: %.2f (beta points).", total))
            }
        }
        lines.append(held > 0
            ? "Held MALIBU is not released and not withdrawable. MALIBU has no withdrawals yet."
            : "MALIBU has no withdrawals yet.")
        switch verdict.malibuWithdrawal {
        case .capped(let reason), .epochDisposition(let reason):
            lines.append(sentence(rewardReasonCopy(reason)))
        default:
            break
        }
        if s.malibuEmission?.active == true, verdict.reasonCode == .walletMissing || !verdict.walletBound {
            lines.append(held > 0
                ? "Add a payout wallet to be eligible for new MALIBU. It does not release held MALIBU."
                : "Add a payout wallet to be eligible for MALIBU.")
        }
        return lines
    }

    /// Trust progress from the coordinator's own evaluator windows. Without
    /// that block (an older coordinator) only the tier is shown; there is no
    /// "in progress" claim either way.
    static func trustLine(_ s: AgentSnapshot, verdict: RewardVerdict, now: Date = Date()) -> String? {
        let suffix = " Trust affects MALIBU only, not USDC."
        let tier: AgentSnapshot.TrustTier
        switch verdict.trustDisplay {
        case .trustedAuthoritative: tier = .trusted
        case .provisional: tier = .provisional
        case .trustedStaleNeutral, .unknown: return nil
        }
        guard tier == .provisional else { return "Trust: Trusted." + suffix }
        guard let progress = s.malibuTrustProgress, progress.tier == .provisional else {
            return "Trust: Provisional." + suffix
        }
        var parts = ["Trust: Provisional"]
        if progress.demotionCooldownActive, let until = progress.demotionCooldownUntil {
            parts.append("demotion cooldown until \(until.formatted(date: .abbreviated, time: .shortened))")
        }
        if progress.verifiedReceiptCount < progress.requiredReceiptCount {
            parts.append("verified jobs \(formatCount(progress.verifiedReceiptCount)) of \(formatCount(progress.requiredReceiptCount))")
        }
        // A distinct pair can be E1 with A1 (uptime) or with A4 (app
        // attestation); only show the uptime window when the pair still
        // needs it.
        let met = Set(progress.criteriaMet)
        let pairMet = progress.unlockPairOKSince != nil
            || (met.contains("E1") && (met.contains("A1") || met.contains("A4")))
        let window = Int(progress.requalificationWindowSeconds / 3_600)
        if !pairMet {
            let uptimeRequired = Int(progress.uptimeRequiredSeconds / 3_600)
            if let since = progress.uptimeOKSince, uptimeRequired > 0 {
                let hours = min(uptimeRequired, max(0, Int(now.timeIntervalSince(since) / 3_600)))
                parts.append("online without a gap \(hours) of \(uptimeRequired) h")
            } else if uptimeRequired > 0 {
                parts.append("needs \(uptimeRequired) h online without a gap")
            }
            if progress.requalificationRequired {
                parts.append("then \(window) h of requalification")
            }
        } else if progress.requalificationRequired {
            if let pairSince = progress.unlockPairOKSince {
                let hours = min(window, max(0, Int(now.timeIntervalSince(pairSince) / 3_600)))
                parts.append("requalifying \(hours) of \(window) h")
            } else {
                parts.append("\(window) h of requalification starts at the next hourly check")
            }
        }
        if let earliest = progress.earliestPromotionAt {
            let date = shortDate(earliest)
            parts.append(earliest <= now ? "Trusted at the next hourly check" : "earliest Trusted \(date) if online without a gap")
        }
        return parts.joined(separator: " · ") + "." + suffix
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "today (UTC)" only for CLIs whose counters roll at the UTC day
    /// (#2029, shipped with `metrics_request_rate_v1`); older CLIs roll at
    /// local midnight.
    static func todayLabel(_ s: AgentSnapshot) -> String {
        s.localStatusCapabilities.contains("metrics_request_rate_v1") ? "today (UTC)" : "today"
    }

    /// One line for the Mac's health, from reported values only.
    static func macHealthLine(_ s: AgentSnapshot) -> String? {
        guard s.state == .serving || s.state == .paused || s.state == .reconnecting else { return nil }
        var parts: [String] = []
        if let thermal = s.thermalState {
            switch thermal {
            case .nominal: parts.append("Cool")
            case .fair: parts.append("Warm")
            case .serious: parts.append("Hot")
            case .critical: parts.append("Throttled by heat")
            }
        }
        if let uptime = s.uptimeSec { parts.append("up \(formatDuration(uptime))") }
        if let recent = s.restartCount7d {
            parts.append("\(recent) restart\(recent == 1 ? "" : "s") in 7 days")
        }
        if let slots = s.advertisedMaxConcurrency {
            parts.append("\(slots) customer slot\(slots == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Advanced diagnostics

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
