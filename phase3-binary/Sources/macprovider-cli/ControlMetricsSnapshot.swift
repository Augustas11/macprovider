import Foundation

/// Wire payload for metrics_response (SPEC-025 §5.2 / Session C3).
public struct ControlMetricsSnapshot: Equatable, Sendable {
    public var earningsUsdc: Double?
    public var malibuAccrued: Double?
    public var providerEarnings: ProviderEarningsSummary?
    public var gpuC: Double?
    public var latencyP50Ms: Int?
    public var uptimeSec: Int = 0
    public var requestsServedToday: Int?
    public var requestsServedAllTime: Int?
    public var requestsPerMinute: Double?
    public var inputTokensToday: Int64?
    public var outputTokensToday: Int64?
    public var inputTokensAllTime: Int64?
    public var outputTokensAllTime: Int64?
    public var queueDepth: Int?

    public init(
        earningsUsdc: Double? = nil,
        malibuAccrued: Double? = nil,
        providerEarnings: ProviderEarningsSummary? = nil,
        gpuC: Double? = nil,
        latencyP50Ms: Int? = nil,
        uptimeSec: Int = 0,
        requestsServedToday: Int? = nil,
        requestsServedAllTime: Int? = nil,
        requestsPerMinute: Double? = nil,
        inputTokensToday: Int64? = nil,
        outputTokensToday: Int64? = nil,
        inputTokensAllTime: Int64? = nil,
        outputTokensAllTime: Int64? = nil,
        queueDepth: Int? = nil
    ) {
        self.earningsUsdc = earningsUsdc
        self.malibuAccrued = malibuAccrued
        self.providerEarnings = providerEarnings
        self.gpuC = gpuC
        self.latencyP50Ms = latencyP50Ms
        self.uptimeSec = uptimeSec
        self.requestsServedToday = requestsServedToday
        self.requestsServedAllTime = requestsServedAllTime
        self.requestsPerMinute = requestsPerMinute
        self.inputTokensToday = inputTokensToday
        self.outputTokensToday = outputTokensToday
        self.inputTokensAllTime = inputTokensAllTime
        self.outputTokensAllTime = outputTokensAllTime
        self.queueDepth = queueDepth
    }

    static func from(
        provider snapshot: ProviderSnapshot,
        providerEarnings: ProviderEarningsSummary?
    ) -> ControlMetricsSnapshot {
        let rpm: Double?
        if let tps = snapshot.throughputTPSSinceLast, tps > 0 {
            rpm = tps * 60
        } else {
            rpm = nil
        }
        return ControlMetricsSnapshot(
            earningsUsdc: providerEarnings?.usdcToday,
            malibuAccrued: providerEarnings?.malibuToday,
            providerEarnings: providerEarnings,
            gpuC: nil,
            latencyP50Ms: snapshot.avgLatencyMSSinceLast.map { Int($0.rounded()) },
            uptimeSec: snapshot.uptimeSeconds,
            requestsServedToday: snapshot.requestsToday,
            requestsServedAllTime: snapshot.requestsTotal,
            requestsPerMinute: rpm,
            inputTokensToday: snapshot.inputTokensToday,
            outputTokensToday: snapshot.outputTokensToday,
            inputTokensAllTime: snapshot.inputTokensAllTime,
            outputTokensAllTime: snapshot.outputTokensAllTime,
            queueDepth: snapshot.requestsQueued
        )
    }
}

enum ControlMetricsBuilder {
    static func build(
        providerStatus: ProviderStatus?,
        providerEarningsClient: ProviderEarningsClient?,
        malibuAccrualClient: MalibuAccrualClient?,
        providerToken: String?
    ) async -> ControlMetricsSnapshot {
        guard let providerStatus else {
            return ControlMetricsSnapshot()
        }
        // CS-3: the control-socket metrics poll (Malibu.app UI cadence) must NOT
        // reset the since-last window. That window is owned by the coordinator
        // heartbeat (CoordinatorClient.sendHeartbeat), whose since-last deltas feed
        // autotune demand ranking and SPEC-023 payout-first scoring. Draining it
        // here — the two share one ProviderStatus instance — truncated the next
        // heartbeat's window to the post-poll sliver. Read without resetting.
        let snapshot = await providerStatus.snapshot(resetWindow: false)
        var earnings: ProviderEarningsSummary?
        var accrual: MalibuAccrualSummary?
        if let token = providerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            if let providerEarningsClient {
                earnings = try? await providerEarningsClient.fetch(bearerToken: token)
            }
            if let malibuAccrualClient {
                accrual = try? await malibuAccrualClient.fetch(bearerToken: token)
            }
        }
        if let accrual {
            earnings = earnings?.merging(accrual: accrual) ?? .from(accrual: accrual)
        }
        return .from(
            provider: snapshot,
            providerEarnings: earnings
        )
    }
}

extension ControlSocketCodec {
    static func encodeMetrics(_ metrics: ControlMetricsSnapshot) throws -> Data {
        try encode(.metricsResponse(metrics))
    }
}
