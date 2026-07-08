import Foundation

/// Wire payload for metrics_response (SPEC-025 §5.2 / Session C3).
public struct ControlMetricsSnapshot: Equatable, Sendable {
    public var earningsUsdc: Double = 0
    public var malibuAccrued: Double = 0
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
        earningsUsdc: Double = 0,
        malibuAccrued: Double = 0,
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

    static func from(provider snapshot: ProviderSnapshot, malibuAccrued: Double) -> ControlMetricsSnapshot {
        let rpm: Double?
        if let tps = snapshot.throughputTPSSinceLast, tps > 0 {
            rpm = tps * 60
        } else {
            rpm = nil
        }
        return ControlMetricsSnapshot(
            earningsUsdc: 0,
            malibuAccrued: malibuAccrued,
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
        malibuAccrualClient: MalibuAccrualClient?,
        providerToken: String?
    ) async -> ControlMetricsSnapshot {
        guard let providerStatus else {
            return ControlMetricsSnapshot()
        }
        let snapshot = await providerStatus.snapshot(resetWindow: true)
        var malibu = 0.0
        if let malibuAccrualClient,
           let token = providerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            malibu = (try? await malibuAccrualClient.fetch(bearerToken: token).accruedMALIBU) ?? 0
        }
        return .from(provider: snapshot, malibuAccrued: malibu)
    }
}

extension ControlSocketCodec {
    static func encodeMetrics(_ metrics: ControlMetricsSnapshot) throws -> Data {
        try encode(.metricsResponse(metrics))
    }
}
