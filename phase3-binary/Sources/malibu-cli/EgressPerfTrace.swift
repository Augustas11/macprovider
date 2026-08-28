import Foundation

// MARK: - Feature flag

/// Set MACPROVIDER_PERF_TRACE=1 to enable per-request egress timing on stderr.
/// Evaluated once at process launch; changing the env var at runtime has no effect.
let perfTraceEnabled: Bool =
    ProcessInfo.processInfo.environment["MACPROVIDER_PERF_TRACE"] == "1"

// MARK: - Task-local storage

enum EgressPerfTraceKey {
    @TaskLocal static var current: EgressPerfTrace? = nil
}

// MARK: - EgressPerfTrace

/// Accumulates lightweight per-request egress timing samples.
///
/// Instrumentation sites:
///   1. `ModelRuntime.stream` generate callback — inter-token interval (decode hot path)
///   2. `InferenceRelay.sendChunk` — Tier-2 seal duration
///   3. `CoordinatorClient.send(_:to:)` — URLSessionWebSocketTask.send duration
///
/// All `record*` methods and `printSummary` are no-ops when `enabled == false`.
/// Create one instance per streaming request via `EgressPerfTraceKey.$current.withValue(trace)`.
final class EgressPerfTrace: @unchecked Sendable {
    let enabled: Bool
    private let lock = NSLock()

    private var decodeCallbackTimestamps: [UInt64] = []
    private var sealSamples: [UInt64] = []
    private var wsSendSamples: [UInt64] = []

    init(enabled: Bool = perfTraceEnabled) {
        self.enabled = enabled
    }

    /// Record a decode-callback entry timestamp for inter-token interval measurement.
    /// Call at the top of the MLX generate callback closure.
    func recordDecodeCallbackEntry() {
        guard enabled else { return }
        let ts = clockMonotonicMicros()
        lock.lock()
        decodeCallbackTimestamps.append(ts)
        lock.unlock()
    }

    /// Record duration of a Tier-2 `sealResponseChunk` call in microseconds.
    /// Pass 0 for plaintext (non-Tier-2) paths.
    func recordSeal(durationMicros: UInt64) {
        guard enabled else { return }
        lock.lock()
        sealSamples.append(durationMicros)
        lock.unlock()
    }

    /// Record duration of a `URLSessionWebSocketTask.send` call in microseconds.
    func recordWSSend(durationMicros: UInt64) {
        guard enabled else { return }
        lock.lock()
        wsSendSamples.append(durationMicros)
        lock.unlock()
    }

    /// Number of samples recorded so far (for tests and assertions).
    func sampleCounts() -> (decode: Int, seal: Int, wsSend: Int) {
        lock.lock()
        let counts = (decodeCallbackTimestamps.count, sealSamples.count, wsSendSamples.count)
        lock.unlock()
        return counts
    }

    /// Inject synthetic timing samples for unit testing without requiring a real clock loop.
    ///
    /// Synthesizes `tokenCount` decode-callback timestamps spaced `tokenPeriodUs` apart,
    /// plus `tokenCount` uniform seal and WS-send samples. Only available in DEBUG builds;
    /// call only from test code.
    #if DEBUG
    func injectSamplesForTesting(
        tokenPeriodUs: UInt64,
        sealUs: UInt64,
        wsSendUs: UInt64,
        tokenCount: Int
    ) {
        guard enabled, tokenCount > 0 else { return }
        lock.lock()
        var ts: UInt64 = 1_000_000
        decodeCallbackTimestamps.append(ts)
        for _ in 0..<tokenCount {
            ts &+= tokenPeriodUs
            decodeCallbackTimestamps.append(ts)
            if sealUs > 0 { sealSamples.append(sealUs) }
            wsSendSamples.append(wsSendUs)
        }
        lock.unlock()
    }
    #endif

    /// Print a per-request egress profile to stderr and return the verdict string.
    /// No-op when `enabled == false`; returns "DISABLED".
    @discardableResult
    func printSummary(requestID: String, completionTokens: Int) -> String {
        guard enabled else { return "DISABLED" }
        lock.lock()
        let timestamps = decodeCallbackTimestamps
        let seals = sealSamples
        let wsSends = wsSendSamples
        lock.unlock()

        // Inter-token intervals from consecutive decode-callback timestamps
        var intervals: [UInt64] = []
        if timestamps.count >= 2 {
            intervals.reserveCapacity(timestamps.count - 1)
            for i in 1..<timestamps.count {
                intervals.append(timestamps[i] &- timestamps[i - 1])
            }
        }

        let decodeIntervalMeanUs = meanUs(intervals)
        let decodeIntervalP95Us = p95Us(intervals)
        let observedTPS: Double = decodeIntervalMeanUs > 0
            ? 1_000_000.0 / Double(decodeIntervalMeanUs) : 0

        let sealMeanUs = meanUs(seals)
        let sealP95Us = p95Us(seals)

        let wsMeanUs = meanUs(wsSends)
        let wsP95Us = p95Us(wsSends)

        // Egress = seal + WS-send; conservative worst-case sum for verdict.
        let egressMeanUs = sealMeanUs &+ wsMeanUs
        let egressP95Us = sealP95Us &+ wsP95Us

        let pctMean: Double = decodeIntervalMeanUs > 0
            ? Double(egressMeanUs) / Double(decodeIntervalMeanUs) * 100 : 0
        let pctP95: Double = decodeIntervalP95Us > 0
            ? Double(egressP95Us) / Double(decodeIntervalP95Us) * 100 : 0

        let verdict: String
        switch pctP95 {
        case ..<5:  verdict = "GREEN"
        case ..<15: verdict = "YELLOW"
        default:    verdict = "RED"
        }

        let lines = [
            "[PERF_TRACE] request_id=\(requestID) tokens=\(completionTokens) decode_callbacks=\(timestamps.count)",
            "[PERF_TRACE] decode_interval  mean=\(decodeIntervalMeanUs)µs  p95=\(decodeIntervalP95Us)µs  tps=\(String(format: "%.1f", observedTPS))",
            "[PERF_TRACE] seal             mean=\(sealMeanUs)µs  p95=\(sealP95Us)µs  n=\(seals.count)",
            "[PERF_TRACE] ws_send          mean=\(wsMeanUs)µs  p95=\(wsP95Us)µs  n=\(wsSends.count)",
            "[PERF_TRACE] egress_total     mean=\(egressMeanUs)µs  p95=\(egressP95Us)µs  pct_of_token_period mean=\(String(format:"%.1f",pctMean))%  p95=\(String(format:"%.1f",pctP95))%",
            "[PERF_TRACE] VERDICT=\(verdict)",
        ]
        fputs(lines.joined(separator: "\n") + "\n", stderr)
        return verdict
    }
}

// MARK: - Monotonic clock helper (module-internal)

/// Returns current monotonic time in microseconds.
func clockMonotonicMicros() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000 &+ UInt64(ts.tv_nsec) / 1_000
}

// MARK: - Statistics helpers (file-private)

private func meanUs(_ samples: [UInt64]) -> UInt64 {
    guard !samples.isEmpty else { return 0 }
    return samples.reduce(0, &+) / UInt64(samples.count)
}

private func p95Us(_ samples: [UInt64]) -> UInt64 {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let idx = max(0, Int(Double(sorted.count - 1) * 0.95))
    return sorted[idx]
}
