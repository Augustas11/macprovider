import Foundation

/// Issue #2364: bounds for the first-token stall watchdog.
///
/// A request may wait for its first token as long as its prefill legitimately
/// takes: `floor + slack * pendingPromptTokens / prefillRate`, capped. The
/// prefill rate is the provider's own measured rate (uncached prompt tokens
/// over prefill wall time of finished requests), so a 128K prompt gets a bound
/// sized for a 128K prefill instead of one fixed constant.
struct FirstTokenStallPolicy: Sendable, Equatable {
    /// Shortest bound: covers queue exit, prompt preparation and a cold
    /// page-in of resident weights for a short prompt.
    var floorSeconds: Double = 60
    /// Longest bound, whatever the prompt length.
    var capSeconds: Double = 600
    /// Headroom over the measured prefill time.
    var prefillSlack: Double = 3
    /// Prefill rate assumed before any request has been measured.
    var defaultPrefillTokensPerSecond: Double = 250
    var minimumPrefillTokensPerSecond: Double = 50
    var maximumPrefillTokensPerSecond: Double = 20_000
    /// Shorter prefills are dominated by fixed overhead and are not rate samples.
    var minimumRateSampleTokens = 512
    var rateSmoothing: Double = 0.3
    /// Wait before the first recovery probe after a trip; doubles on each
    /// failed probe and on a re-trip soon after recovery.
    var initialBackoffSeconds: Double = 15
    var maximumBackoffSeconds: Double = 300
    /// A recovered provider that stays healthy this long trips with the
    /// initial backoff again.
    var stableResetSeconds: Double = 600
    /// A recovery probe that produces no token within this bound fails.
    var probeTimeoutSeconds: Double = 60

    func boundSeconds(pendingPromptTokens: Int, prefillTokensPerSecond: Double) -> Double {
        let rate = min(max(prefillTokensPerSecond, minimumPrefillTokensPerSecond), maximumPrefillTokensPerSecond)
        let prefill = Double(max(0, pendingPromptTokens)) / rate * prefillSlack
        return min(capSeconds, floorSeconds + prefill)
    }

    /// Prompt tokens estimated from the request body before tokenization:
    /// one token per three bytes over-counts typical text, so the bound errs long.
    static func estimatedPromptTokens(bodyBytes: Int) -> Int {
        max(0, bodyBytes) / 3
    }
}

/// Issue #2364: notices a provider whose admitted requests produce no first
/// token within a prompt-sized bound, while the model makes no forward
/// progress at all, and holds it out of routing until a recovery probe (a
/// real one-token forward on the loaded model) succeeds.
///
/// Pure state machine: the caller supplies the model-progress token
/// (`ModelLivenessTracker`), runs the probe and publishes the hold. Any model
/// forward progress (another request decoding) restarts the stall clock, so a
/// request that is merely queued behind working rows never trips it, and a
/// request whose first token has arrived is never counted.
final class FirstTokenStallWatchdog: @unchecked Sendable {
    static let shared = FirstTokenStallWatchdog()

    enum Phase: Sendable, Equatable {
        case healthy
        case tripped
        case probing
    }

    struct Trip: Sendable, Equatable {
        let stalledSeconds: Double
        let boundSeconds: Double
        let pendingRequests: Int
        let pendingPromptTokens: Int
        let prefillTokensPerSecond: Double
        let backoffSeconds: Double
    }

    enum Decision: Sendable, Equatable {
        case none
        case trip(Trip)
        case probe(timeoutSeconds: Double)
    }

    enum ProbeOutcome: Sendable, Equatable {
        case recovered(degradedSeconds: Double)
        case stillStalled(nextProbeInSeconds: Double)
        case ignored
    }

    private struct Entry {
        let admittedAt: Double
        let promptTokens: Int
        let firstTokenObserved: @Sendable () -> Bool
    }

    let policy: FirstTokenStallPolicy
    private let clock: @Sendable () -> Double
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var prefillRate: Double?
    private var lastProgressToken: UInt64?
    private var lastProgressAt: Double
    private var phase = Phase.healthy
    private var trippedAt: Double?
    private var nextProbeAt: Double?
    private var backoffSeconds: Double
    private var lastRecoveredAt: Double?

    /// `clock` returns monotonic seconds.
    init(
        policy: FirstTokenStallPolicy = FirstTokenStallPolicy(),
        clock: @escaping @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    ) {
        self.policy = policy
        self.clock = clock
        self.lastProgressAt = clock()
        self.backoffSeconds = policy.initialBackoffSeconds
    }

    var currentPhase: Phase {
        lock.lock(); defer { lock.unlock() }
        return phase
    }

    var prefillTokensPerSecond: Double {
        lock.lock(); defer { lock.unlock() }
        return prefillRate ?? policy.defaultPrefillTokensPerSecond
    }

    /// An admitted buyer request starts waiting for its first token.
    func register(id: String, promptTokens: Int, firstTokenObserved: @escaping @Sendable () -> Bool) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = Entry(admittedAt: clock(), promptTokens: max(0, promptTokens), firstTokenObserved: firstTokenObserved)
    }

    func finish(id: String) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = nil
    }

    /// A finished request's prefill: uncached prompt tokens over the wall
    /// time from queue exit to first token.
    func recordPrefillSample(uncachedPromptTokens: Int, prefillSeconds: Double) {
        guard uncachedPromptTokens >= policy.minimumRateSampleTokens, prefillSeconds > 0 else { return }
        let sample = Double(uncachedPromptTokens) / prefillSeconds
        lock.lock(); defer { lock.unlock() }
        if let rate = prefillRate {
            prefillRate = rate + policy.rateSmoothing * (sample - rate)
        } else {
            prefillRate = sample
        }
    }

    /// The provider is paused, draining or has no model: time spent so does
    /// not count toward a stall.
    func noteIneligible() {
        lock.lock(); defer { lock.unlock() }
        if phase == .healthy { lastProgressAt = clock() }
    }

    /// One watchdog tick. `progressToken` advances on every model forward
    /// that produced tokens.
    func evaluate(progressToken: UInt64) -> Decision {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        // The first observed token is a baseline, not progress.
        if let last = lastProgressToken, last != progressToken {
            lastProgressAt = now
        }
        lastProgressToken = progressToken
        switch phase {
        case .probing:
            return .none
        case .tripped:
            guard let nextProbeAt, now >= nextProbeAt else { return .none }
            phase = .probing
            return .probe(timeoutSeconds: policy.probeTimeoutSeconds)
        case .healthy:
            var oldest: Double?
            var pendingTokens = 0
            var pendingCount = 0
            for entry in entries.values where !entry.firstTokenObserved() {
                pendingCount += 1
                pendingTokens += entry.promptTokens
                oldest = min(oldest ?? entry.admittedAt, entry.admittedAt)
            }
            guard let oldest else { return .none }
            let rate = prefillRate ?? policy.defaultPrefillTokensPerSecond
            let bound = policy.boundSeconds(pendingPromptTokens: pendingTokens, prefillTokensPerSecond: rate)
            let stalled = now - max(oldest, lastProgressAt)
            guard stalled > bound else { return .none }
            if let lastRecoveredAt, now - lastRecoveredAt < policy.stableResetSeconds {
                backoffSeconds = min(backoffSeconds * 2, policy.maximumBackoffSeconds)
            } else {
                backoffSeconds = policy.initialBackoffSeconds
            }
            phase = .tripped
            trippedAt = now
            nextProbeAt = now + backoffSeconds
            return .trip(Trip(
                stalledSeconds: stalled,
                boundSeconds: bound,
                pendingRequests: pendingCount,
                pendingPromptTokens: pendingTokens,
                prefillTokensPerSecond: rate,
                backoffSeconds: backoffSeconds
            ))
        }
    }

    /// The recovery probe returned (`success`: it produced a token) or timed out.
    func probeFinished(success: Bool) -> ProbeOutcome {
        lock.lock(); defer { lock.unlock() }
        guard phase == .probing else { return .ignored }
        let now = clock()
        if success {
            phase = .healthy
            lastRecoveredAt = now
            // Requests still waiting get a fresh bound from the recovery.
            lastProgressAt = now
            let degraded = now - (trippedAt ?? now)
            trippedAt = nil
            nextProbeAt = nil
            return .recovered(degradedSeconds: degraded)
        }
        backoffSeconds = min(backoffSeconds * 2, policy.maximumBackoffSeconds)
        phase = .tripped
        nextProbeAt = now + backoffSeconds
        return .stillStalled(nextProbeInSeconds: backoffSeconds)
    }
}

private final class FirstTokenStallProbeRun: @unchecked Sendable {
    let startedAt: Date
    private let lock = NSLock()
    private var cancelled = false
    private var outcome: Result<Double, Error>?
    private var timedOut = false

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func complete(_ result: Result<Double, Error>) {
        lock.lock(); outcome = result; lock.unlock()
    }

    var result: Result<Double, Error>? {
        lock.lock(); defer { lock.unlock() }
        return outcome
    }

    /// Marks the run timed out once; true only for the first call.
    func markTimedOut() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if timedOut { return false }
        timedOut = true
        return true
    }

    var hasTimedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }
}

/// Issue #2364: drives `FirstTokenStallWatchdog` in the serve process. It
/// publishes the hold (provider `degraded`, no free slot) on a trip, and
/// clears it only after a one-token forward on the loaded model succeeds.
/// It never changes continuous batching or native MTP configuration.
actor FirstTokenStallMonitor {
    typealias Probe = @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) async throws -> Double

    private let watchdog: FirstTokenStallWatchdog
    private let tickSeconds: Double
    private let isEligible: @Sendable () async -> Bool
    private let progressToken: @Sendable () -> UInt64
    private let setHeld: @Sendable (Bool) async -> Void
    private let probe: Probe
    private let logger: IdlePrewarmLogger
    private var loopTask: Task<Void, Never>?
    private var probeRun: FirstTokenStallProbeRun?
    private var probeTask: Task<Void, Never>?

    init(
        watchdog: FirstTokenStallWatchdog = .shared,
        tickSeconds: Double = 2,
        isEligible: @escaping @Sendable () async -> Bool,
        progressToken: @escaping @Sendable () -> UInt64 = { ModelLivenessTracker.shared.snapshot().token },
        setHeld: @escaping @Sendable (Bool) async -> Void,
        probe: @escaping Probe,
        logger: IdlePrewarmLogger = .stdout
    ) {
        self.watchdog = watchdog
        self.tickSeconds = tickSeconds
        self.isEligible = isEligible
        self.progressToken = progressToken
        self.setHeld = setHeld
        self.probe = probe
        self.logger = logger
    }

    func start() {
        guard loopTask == nil else { return }
        let nanoseconds = UInt64(max(0.1, tickSeconds) * 1_000_000_000)
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    break
                }
                await self?.tick()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        probeRun?.cancel()
        probeTask?.cancel()
    }

    func tick() async {
        if let run = probeRun {
            if let result = run.result {
                probeRun = nil
                probeTask = nil
                if !run.hasTimedOut { await finishProbe(result, startedAt: run.startedAt) }
                return
            }
            if Date().timeIntervalSince(run.startedAt) > watchdog.policy.probeTimeoutSeconds, run.markTimedOut() {
                run.cancel()
                await finishProbe(.failure(CancellationError()), startedAt: run.startedAt, reason: "timeout")
            }
            // A timed-out probe still holds the model; no second probe
            // starts until it returns.
            return
        }
        if watchdog.currentPhase == .healthy, !(await isEligible()) {
            watchdog.noteIneligible()
            return
        }
        switch watchdog.evaluate(progressToken: progressToken()) {
        case .none:
            return
        case .trip(let trip):
            log([
                "event": "first_token_stall_tripped",
                "at": Self.timestamp(),
                "stalled_seconds": trip.stalledSeconds,
                "bound_seconds": trip.boundSeconds,
                "pending_requests": trip.pendingRequests,
                "pending_prompt_tokens_estimate": trip.pendingPromptTokens,
                "prefill_tokens_per_second": trip.prefillTokensPerSecond,
                "next_probe_in_seconds": trip.backoffSeconds,
            ])
            await setHeld(true)
        case .probe:
            startProbe()
        }
    }

    private func startProbe() {
        let run = FirstTokenStallProbeRun(startedAt: Date())
        probeRun = run
        log(["event": "first_token_stall_probe_started", "at": Self.timestamp()])
        let probe = probe
        probeTask = Task {
            do {
                let firstTokenMS = try await probe { run.isCancelled }
                run.complete(.success(firstTokenMS))
            } catch {
                run.complete(.failure(error))
            }
        }
    }

    private func finishProbe(_ result: Result<Double, Error>, startedAt: Date, reason: String? = nil) async {
        let elapsedMS = max(0, Date().timeIntervalSince(startedAt) * 1000)
        switch result {
        case .success(let firstTokenMS):
            guard case .recovered(let degradedSeconds) = watchdog.probeFinished(success: true) else { return }
            log([
                "event": "first_token_stall_recovered",
                "at": Self.timestamp(),
                "probe_first_token_ms": firstTokenMS,
                "probe_elapsed_ms": elapsedMS,
                "degraded_seconds": degradedSeconds,
            ])
            await setHeld(false)
        case .failure(let error):
            let outcome = watchdog.probeFinished(success: false)
            var object: [String: Any] = [
                "event": "first_token_stall_probe_failed",
                "at": Self.timestamp(),
                "probe_elapsed_ms": elapsedMS,
                "reason": reason ?? String(describing: type(of: error)),
            ]
            if case .stillStalled(let next) = outcome { object["next_probe_in_seconds"] = next }
            log(object)
        }
    }

    private func log(_ object: [String: Any]) {
        logger.emit(object)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
