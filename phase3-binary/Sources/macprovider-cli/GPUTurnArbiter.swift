import Foundation
import MLX

// SPEC-001-R018 (#2338): one process-wide arbiter for the GPU turns of every
// warm model. Each `ModelRuntime` registers one participant; its decode and
// prefill loops bracket every unit of GPU work (one decode step, one prefill
// chunk) with `beginTurn` / `endTurn`. A `GPUTurnPolicy` decides, before each
// unit, whether the caller proceeds or waits until another participant has had
// its turn.
//
// Under a sharing policy (anything but passthrough, with two or more
// participants registered) turns are exclusive: nobody starts while another
// participant holds a turn, unless that turn has run past the policy's stall
// bound (a hung peer never deadlocks its sibling). The policy's drain mode
// decides whether a turn there ends only once the GPU work it queued has been
// realised (`drainQueuedWork`), so work a loop pipelined with `asyncEval` is
// charged to the loop that queued it, not absorbed by the peer's next turn.
// With `always` (the default) every turn drains. With `handoff` a turn drains
// only when a waiting participant would be admitted the moment it ends, so a
// participant that keeps the GPU keeps its asyncEval overlap. With `never` no
// turn drains. With one participant, or under passthrough, every call proceeds
// at once, nothing drains and prefill chunks keep their full size: asyncEval
// pipelining is untouched.
//
// The compiled-in policy is `alternate` with `drain=never` (#2397): while two
// models are busy they take single turns in alternation and no turn drains.
// Measured on an M3 Ultra, GLM-5.3-Flash beside a 27B model on one serial row:
// under passthrough the main model kept 0.21 of its solo rate and the second
// 0.87; alternating gives 0.44 and 0.67 (0.61 and 0.46 with the main model at
// three rows, the same rate per stream), with identical tokens. A provider
// with one model, or with one busy model, never waits. Lab builds
// (`DEBUG || MACPROVIDER_LAB_HARNESS`) may select another registered policy by
// name to compare candidates.

/// One unit of GPU work a participant asks a turn for.
enum GPUWorkKind: Sendable, Equatable {
    /// One forward that decodes (or verifies) `rows` rows of one model.
    case decodeStep(rows: Int)
    /// One prefill forward of `tokens` prompt tokens (summed over its rows).
    case prefillChunk(tokens: Int)

    var isDecode: Bool {
        if case .decodeStep = self { return true }
        return false
    }

    var prefillTokens: Int? {
        if case .prefillChunk(let tokens) = self { return tokens }
        return nil
    }
}

/// A registered model runtime. Handles are stable for a runtime's lifetime and
/// may be unregistered and registered again across unload / reload. Turn calls
/// on an unregistered handle proceed at once and record nothing.
final class GPUTurnParticipant: Sendable, Hashable {
    let id: Int
    let arbiter: GPUTurnArbiter

    fileprivate init(id: Int, arbiter: GPUTurnArbiter) {
        self.id = id
        self.arbiter = arbiter
    }

    /// Blocks until the policy lets this participant run one unit of `kind`.
    /// Returns false, holding no turn, when `isCancelled` turns true while it
    /// waits; the caller then must not call `endTurn` for this unit.
    @discardableResult
    func beginTurn(_ kind: GPUWorkKind, isCancelled: () -> Bool = { Task.isCancelled }) -> Bool {
        arbiter.beginTurn(self, kind: kind, isCancelled: isCancelled)
    }

    func endTurn() { arbiter.endTurn(self) }

    func withTurn<R>(_ kind: GPUWorkKind, _ body: () throws -> R) rethrows -> R {
        let held = beginTurn(kind)
        defer { if held { endTurn() } }
        return try body()
    }

    /// Marks an interval in which this participant has work pending and will
    /// ask for turns (a serial request, a scheduler pump with rows).
    func beginWork() { arbiter.beginWork(self) }
    func endWork() { arbiter.endWork(self) }

    /// Tokens for this participant's next prefill chunk: `fullSize` unless a
    /// sharing policy wants short chunks while another participant is active.
    func prefillChunkTokens(fullSize: Int) -> Int { arbiter.prefillChunkTokens(self, fullSize: fullSize) }

    static func == (lhs: GPUTurnParticipant, rhs: GPUTurnParticipant) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Cumulative counters of one participant. Times are wall-clock nanoseconds on
/// the arbiter's monotonic clock.
struct GPUTurnParticipantCounters: Sendable, Equatable {
    var turns = 0
    var decodeSteps = 0
    var decodeRows = 0
    var prefillChunks = 0
    var prefillTokens = 0
    /// Wall time inside turns (overlapping turns of one participant count
    /// once), including the drain of the work a turn queued.
    var busyNanoseconds: UInt64 = 0
    /// Wall time spent blocked in `beginTurn` waiting for the policy.
    var waitNanoseconds: UInt64 = 0
    /// Turns that had to wait at least once.
    var waitedTurns = 0
    /// Longest single wait since the last `snapshot(resettingMaxWait: true)`.
    var maxWaitNanoseconds: UInt64 = 0
    /// Turns that started beside another participant's turn held past the
    /// stall bound, or after the policy alone kept the caller waiting a whole
    /// stall bound. Zero in a healthy run: every other turn is exclusive.
    var stallOverrides = 0
    /// Waits the caller left because it was cancelled (no turn taken).
    var cancelledWaits = 0
}

/// What a policy sees about one participant.
struct GPUTurnParticipantState: Sendable, Equatable {
    let id: Int
    var modelID: String
    /// Open `beginWork` intervals: the participant has work pending.
    var pendingWork = 0
    /// Set while the participant is blocked in `beginTurn`.
    var waitingSince: UInt64?
    var waitingKind: GPUWorkKind?
    /// Turns currently held (more than one only when one runtime runs two
    /// loops at once, e.g. a warmup beside a request).
    var turnsHeld = 0
    var turnStartedAt: UInt64?
    var lastTurnBeganAt: UInt64?
    var lastTurnEndedAt: UInt64?
    var lastTurnKind: GPUWorkKind?
    /// Turns this participant has begun since another participant last began
    /// one (0 once another participant takes a turn).
    var consecutiveTurns = 0
    /// GPU nanoseconds per prefill token, measured on drained (exclusive)
    /// prefill turns; nil until one was measured.
    var prefillNanosecondsPerToken: Double?
    var counters = GPUTurnParticipantCounters()

    var isWaiting: Bool { waitingSince != nil }
    var inTurn: Bool { turnsHeld > 0 }
    /// Wants the GPU now or soon: blocked in `beginTurn` or inside a work interval.
    var wantsTurn: Bool { isWaiting || pendingWork > 0 }
}

/// The arbiter state a policy decides on. `participants` is the arbiter's own
/// array, passed without copying.
struct GPUTurnArbiterState: Sendable {
    let now: UInt64
    let participants: [GPUTurnParticipantState]
    /// The participant whose turn began most recently.
    let lastTurnParticipantID: Int?

    func participant(_ id: Int) -> GPUTurnParticipantState? {
        participants.first { $0.id == id }
    }

    func others(than id: Int) -> [GPUTurnParticipantState] {
        participants.filter { $0.id != id }
    }
}

struct GPUTurnRequest: Sendable, Equatable {
    let participantID: Int
    let kind: GPUWorkKind
    /// When this caller started waiting for this turn.
    let waitingSince: UInt64
}

enum GPUTurnDecision: Sendable, Equatable {
    case proceed
    /// Wait until the arbiter state changes (a turn ends, a participant
    /// registers, unregisters, starts waiting or ends its work) or
    /// `maxNanoseconds` pass, whichever comes first, then ask again. `nil`
    /// waits for a state change only (the arbiter still bounds every wait by
    /// the policy's stall bound).
    case wait(maxNanoseconds: UInt64?)
}

/// What the arbiter does with one waiting caller: the policy's decision behind
/// the exclusivity and stall rules every sharing policy gets.
enum GPUTurnAdmission: Sendable, Equatable {
    case proceed
    /// Proceeds although the turn is not exclusive or the policy said wait:
    /// another participant's turn ran past the stall bound, or the policy kept
    /// the caller waiting for a whole stall bound with nobody holding a turn.
    case proceedStalled
    /// Wait at most this long (or until a state change), then ask again.
    case wait(maxNanoseconds: UInt64)
}

/// A pure decision object: no MLX calls, no clocks of its own, no mutable
/// state. The arbiter calls `decide` under its lock for every turn a caller
/// asks for while at least two participants are registered and nobody else
/// holds a turn, and again after every state change while the caller waits.
protocol GPUTurnPolicy: Sendable {
    var name: String { get }
    var parameters: [String: String] { get }
    /// True only for a policy that proceeds unconditionally; the arbiter then
    /// never calls `decide`, never waits and never drains.
    var alwaysProceeds: Bool { get }
    /// A turn held this long is stalled: a waiter then proceeds beside it.
    /// Also the longest the policy alone can keep a caller waiting while
    /// nobody holds a turn. Well above any legitimate turn.
    var stallNanoseconds: UInt64 { get }
    /// While another participant is active, a prefill chunk is sized to take
    /// about this long on the GPU; nil keeps full-size chunks.
    var prefillChunkTargetNanoseconds: UInt64? { get }
    /// Smallest hinted prefill chunk, so prefill throughput survives the split.
    var prefillChunkMinimumTokens: Int { get }
    /// When a sharing turn realises its queued GPU work before it ends.
    var drain: GPUTurnDrain { get }
    func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision
}

/// When a turn under a sharing policy drains the GPU work it queued.
enum GPUTurnDrain: String, Sendable, Equatable, CaseIterable {
    /// Every turn drains before it ends.
    case always
    /// A turn drains only if another participant waiting in `beginTurn` would
    /// be admitted as soon as it ends (the GPU actually changes hands).
    case handoff
    /// No turn drains; the next turn may start on a busy GPU.
    case never
}

extension GPUTurnPolicy {
    var alwaysProceeds: Bool { false }
    var drain: GPUTurnDrain { .always }
    var parameters: [String: String] { [:] }
    var stallNanoseconds: UInt64 { GPUTurnPolicyDefaults.stallMilliseconds * 1_000_000 }
    var prefillChunkTargetNanoseconds: UInt64? { nil }
    var prefillChunkMinimumTokens: Int { GPUTurnPolicyDefaults.prefillChunkMinimumTokens }
}

enum GPUTurnPolicyDefaults {
    /// Real turns on the M3 Ultra: decode steps 26-75 ms, prefill chunks about
    /// 1.2 s; a turn ten seconds long is a hang, not work.
    static let stallMilliseconds: UInt64 = 10_000
    /// 0 = full-size chunks, the hint is off. Measured: a 150 ms target
    /// shortened GLM's prefill chunks and changed its greedy output (token-id
    /// mismatch against the unchunked reference). A lab run may still set
    /// `prefill_chunk_ms`; about one sibling decode step (59-75 ms for a 2-row
    /// 27B worker) plus headroom is the value that was tried.
    static let prefillChunkTargetMilliseconds: UInt64 = 0
    static let prefillChunkMinimumTokens = 256
}

/// Shared parsing of policy parameters.
enum GPUTurnPolicyParameters {
    /// Removes `key` from `rest`; whole milliseconds in `minimum...60_000`.
    static func milliseconds(
        _ rest: inout [String: String], _ key: String, policy: String, default fallback: UInt64, minimum: UInt64 = 1
    ) throws -> UInt64 {
        guard let raw = rest.removeValue(forKey: key) else { return fallback }
        guard let value = UInt64(raw), value >= minimum, value <= 60_000 else {
            throw GPUTurnPolicyError.invalidParameter(policy: policy, name: key, value: raw)
        }
        return value
    }

    /// Removes `key` from `rest`; an integer in `minimum...maximum`.
    static func integer(
        _ rest: inout [String: String], _ key: String, policy: String, default fallback: Int,
        minimum: Int = 1, maximum: Int = Int.max
    ) throws -> Int {
        guard let raw = rest.removeValue(forKey: key) else { return fallback }
        guard let value = Int(raw), value >= minimum, value <= maximum else {
            throw GPUTurnPolicyError.invalidParameter(policy: policy, name: key, value: raw)
        }
        return value
    }

    /// Removes `key` from `rest`; one of `T`'s raw values.
    static func enumerated<T: RawRepresentable>(
        _ rest: inout [String: String], _ key: String, policy: String, default fallback: T
    ) throws -> T where T.RawValue == String {
        guard let raw = rest.removeValue(forKey: key) else { return fallback }
        guard let value = T(rawValue: raw) else {
            throw GPUTurnPolicyError.invalidParameter(policy: policy, name: key, value: raw)
        }
        return value
    }
}

/// Default: every caller proceeds at once (today's behaviour).
struct PassthroughGPUTurnPolicy: GPUTurnPolicy {
    static let name = "passthrough"
    static let factory = GPUTurnPolicyFactory(
        name: name,
        summary: "Always proceed; the GPU is shared as MLX submission order leaves it. No waits, no drains, full prefill chunks."
    ) { parameters in
        guard parameters.isEmpty else {
            throw GPUTurnPolicyError.unknownParameters(policy: name, names: parameters.keys.sorted())
        }
        return PassthroughGPUTurnPolicy()
    }

    var name: String { Self.name }
    var alwaysProceeds: Bool { true }
    func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision { .proceed }
}

enum GPUTurnPolicyError: Error, Equatable, CustomStringConvertible {
    case emptySpec
    case unknownPolicy(String, known: [String])
    case malformedParameter(String)
    case unknownParameters(policy: String, names: [String])
    case invalidParameter(policy: String, name: String, value: String)

    var description: String {
        switch self {
        case .emptySpec:
            "gpu turn policy spec is empty"
        case .unknownPolicy(let name, let known):
            "unknown gpu turn policy '\(name)'; known: \(known.joined(separator: ","))"
        case .malformedParameter(let raw):
            "malformed gpu turn policy parameter '\(raw)'; expected k=v"
        case .unknownParameters(let policy, let names):
            "gpu turn policy '\(policy)' has no parameter(s) \(names.joined(separator: ","))"
        case .invalidParameter(let policy, let name, let value):
            "gpu turn policy '\(policy)' parameter \(name)=\(value) is invalid"
        }
    }
}

struct GPUTurnPolicyFactory: Sendable {
    let name: String
    let summary: String
    let make: @Sendable ([String: String]) throws -> any GPUTurnPolicy
}

/// Policies by name. A new policy lives in its own file and adds its factory
/// to `factories`.
enum GPUTurnPolicyRegistry {
    static let factories: [GPUTurnPolicyFactory] = [
        PassthroughGPUTurnPolicy.factory,
        AlternateGPUTurnPolicy.factory,
        TimeSliceGPUTurnPolicy.factory,
        FairShareGPUTurnPolicy.factory,
    ]

    /// The policy every build serves with: single turns in alternation while
    /// two or more models are busy, no per-turn drain (#2397).
    static let compiledDefault: any GPUTurnPolicy = AlternateGPUTurnPolicy(drain: .never)

    static var names: [String] { factories.map(\.name) }

    /// Parses `name[:k=v,...]`.
    static func parse(_ spec: String) throws -> (name: String, parameters: [String: String]) {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard !name.isEmpty else { throw GPUTurnPolicyError.emptySpec }
        var parameters: [String: String] = [:]
        if parts.count == 2 {
            for raw in parts[1].split(separator: ",", omittingEmptySubsequences: true) {
                let pair = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = pair.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                guard pair.count == 2, !key.isEmpty, parameters[key] == nil else {
                    throw GPUTurnPolicyError.malformedParameter(String(raw))
                }
                parameters[key] = String(pair[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return (name, parameters)
    }

    static func make(_ spec: String) throws -> any GPUTurnPolicy {
        let (name, parameters) = try parse(spec)
        guard let factory = factories.first(where: { $0.name == name }) else {
            throw GPUTurnPolicyError.unknownPolicy(name, known: names)
        }
        return try factory.make(parameters)
    }

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    /// Lab-only selector: the policy one lab build runs with, so candidates can
    /// be compared without a rebuild. A plain release build has no selector.
    static let labEnvironmentKey = "MACPROVIDER_LAB_GPU_TURN_POLICY"

    /// The flag wins over the environment; neither gives nil.
    static func labSelection(flag: String?, environment: [String: String]) throws -> (policy: any GPUTurnPolicy, source: String)? {
        if let flag { return (try make(flag), "flag") }
        if let value = environment[labEnvironmentKey], !value.isEmpty {
            return (try make(value), "env")
        }
        return nil
    }
    #endif

    /// The policy the process-wide arbiter starts with.
    static func processDefault() -> any GPUTurnPolicy {
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        do {
            if let selection = try labSelection(flag: nil, environment: ProcessInfo.processInfo.environment) {
                return selection.policy
            }
        } catch {
            FileHandle.standardError.write(Data("event=gpu_turn_policy_invalid source=env error=\"\(error)\" using=\(compiledDefault.name)\n".utf8))
        }
        #endif
        return compiledDefault
    }
}

/// Per-participant statistics, in seconds, for reports.
struct GPUTurnParticipantSnapshot: Sendable, Equatable, Encodable {
    let id: Int
    let modelID: String
    let turns: Int
    let decodeSteps: Int
    let decodeRows: Int
    let prefillChunks: Int
    let prefillTokens: Int
    let busySeconds: Double
    let waitSeconds: Double
    let waitedTurns: Int
    let maxWaitSeconds: Double
    let stallOverrides: Int
    let cancelledWaits: Int
}

struct GPUTurnArbiterSnapshot: Sendable, Equatable, Encodable {
    let policy: String
    let policyParameters: [String: String]
    let participants: [GPUTurnParticipantSnapshot]
    /// Raw counters behind `participants`, for `delta(since:)`.
    let counters: [Int: GPUTurnParticipantCounters]

    enum CodingKeys: String, CodingKey { case policy, policyParameters, participants }

    /// Counters accumulated since `earlier`; the max wait is the one carried
    /// by this snapshot (reset at `earlier` by the caller).
    func delta(since earlier: GPUTurnArbiterSnapshot) -> GPUTurnArbiterSnapshot {
        var deltaCounters: [Int: GPUTurnParticipantCounters] = [:]
        let rows = participants.map { current -> GPUTurnParticipantSnapshot in
            let now = counters[current.id] ?? GPUTurnParticipantCounters()
            let before = earlier.counters[current.id] ?? GPUTurnParticipantCounters()
            var d = GPUTurnParticipantCounters()
            d.turns = now.turns - before.turns
            d.decodeSteps = now.decodeSteps - before.decodeSteps
            d.decodeRows = now.decodeRows - before.decodeRows
            d.prefillChunks = now.prefillChunks - before.prefillChunks
            d.prefillTokens = now.prefillTokens - before.prefillTokens
            d.busyNanoseconds = now.busyNanoseconds &- before.busyNanoseconds
            d.waitNanoseconds = now.waitNanoseconds &- before.waitNanoseconds
            d.waitedTurns = now.waitedTurns - before.waitedTurns
            d.maxWaitNanoseconds = now.maxWaitNanoseconds
            d.stallOverrides = now.stallOverrides - before.stallOverrides
            d.cancelledWaits = now.cancelledWaits - before.cancelledWaits
            deltaCounters[current.id] = d
            return GPUTurnArbiterSnapshot.row(id: current.id, modelID: current.modelID, d)
        }
        return GPUTurnArbiterSnapshot(policy: policy, policyParameters: policyParameters, participants: rows, counters: deltaCounters)
    }

    static func row(id: Int, modelID: String, _ c: GPUTurnParticipantCounters) -> GPUTurnParticipantSnapshot {
        GPUTurnParticipantSnapshot(
            id: id, modelID: modelID, turns: c.turns, decodeSteps: c.decodeSteps, decodeRows: c.decodeRows,
            prefillChunks: c.prefillChunks, prefillTokens: c.prefillTokens,
            busySeconds: Double(c.busyNanoseconds) / 1e9, waitSeconds: Double(c.waitNanoseconds) / 1e9,
            waitedTurns: c.waitedTurns, maxWaitSeconds: Double(c.maxWaitNanoseconds) / 1e9,
            stallOverrides: c.stallOverrides, cancelledWaits: c.cancelledWaits)
    }
}

/// Process-wide GPU turn arbiter. Thread-safe; every call is synchronous.
/// `beginTurn` may block the calling thread while the policy says wait, so it
/// is called from the inference threads that already block on MLX evaluation.
/// Every wait is bounded by the policy's stall bound and leaves early when the
/// caller is cancelled.
final class GPUTurnArbiter: @unchecked Sendable {
    /// Under a sharing policy a turn realises the GPU work it queued before it
    /// ends, so the next participant's turn starts on an idle GPU.
    static let shared = GPUTurnArbiter(
        policy: GPUTurnPolicyRegistry.processDefault(),
        drainQueuedWork: { MLX.Stream.defaultStream.synchronize() })

    /// How often a waiter checks its caller's cancellation flag. Only a
    /// backstop: every state change wakes waiters at once.
    static let cancellationCheckNanoseconds: UInt64 = 20_000_000
    /// Prefill turns shorter than this many tokens (a final remainder forward)
    /// do not update the measured prefill rate.
    static let prefillRateMinimumTokens = 32
    /// Hinted prefill chunks are rounded down to a multiple of this.
    static let prefillChunkAlignment = 64

    private let condition = NSCondition()
    private let clock: @Sendable () -> UInt64
    private let drainQueuedWork: @Sendable () -> Void
    private var policy: any GPUTurnPolicy
    private var participants: [GPUTurnParticipantState] = []
    private var lastTurnParticipantID: Int?
    private var nextID = 1
    private var waiters = 0

    init(
        policy: any GPUTurnPolicy = GPUTurnPolicyRegistry.compiledDefault,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        drainQueuedWork: @escaping @Sendable () -> Void = {}
    ) {
        self.policy = policy
        self.clock = clock
        self.drainQueuedWork = drainQueuedWork
    }

    // MARK: Pure rules (shared with the test simulator)

    /// The arbiter's rule for one waiting caller. Turns are exclusive: while
    /// another participant holds a turn that has not run past the stall bound,
    /// the caller waits for it to end, whatever the policy says. A holder past
    /// the stall bound is stalled and the caller proceeds beside it. With no
    /// holder the policy decides, but never keeps the caller waiting longer
    /// than one stall bound in total.
    static func admit(_ request: GPUTurnRequest, state: GPUTurnArbiterState, policy: any GPUTurnPolicy) -> GPUTurnAdmission {
        if policy.alwaysProceeds { return .proceed }
        let stall = max(policy.stallNanoseconds, 1)
        var liveHolderRemaining: UInt64?
        var stalledHolder = false
        for other in state.participants where other.id != request.participantID && other.inTurn {
            let started = other.turnStartedAt ?? state.now
            let held = state.now >= started ? state.now - started : 0
            if held < stall {
                liveHolderRemaining = min(liveHolderRemaining ?? .max, stall - held)
            } else {
                stalledHolder = true
            }
        }
        if let liveHolderRemaining { return .wait(maxNanoseconds: liveHolderRemaining) }
        if stalledHolder { return .proceedStalled }
        let waited = state.now >= request.waitingSince ? state.now - request.waitingSince : 0
        if waited >= stall { return .proceedStalled }
        switch policy.decide(request, state: state) {
        case .proceed:
            return .proceed
        case .wait(let maxNanoseconds):
            return .wait(maxNanoseconds: max(1, min(maxNanoseconds ?? .max, stall - waited)))
        }
    }

    /// Prefill chunk tokens for `participantID`: `fullSize` with one
    /// participant, under a policy without a chunk target, or while no other
    /// participant is active. Otherwise the tokens the participant's measured
    /// prefill rate fits in the policy's target (the minimum before a rate is
    /// measured), never below the policy's minimum and never above `fullSize`.
    static func prefillChunkTokens(
        participantID: Int, fullSize: Int, state: GPUTurnArbiterState, policy: any GPUTurnPolicy
    ) -> Int {
        guard fullSize > 1, !policy.alwaysProceeds, state.participants.count > 1,
              let target = policy.prefillChunkTargetNanoseconds, target > 0,
              let me = state.participant(participantID),
              state.participants.contains(where: { $0.id != participantID && ($0.wantsTurn || $0.inTurn) })
        else { return fullSize }
        let floor = min(fullSize, max(1, policy.prefillChunkMinimumTokens))
        guard let perToken = me.prefillNanosecondsPerToken, perToken > 0 else { return floor }
        let fitting = Double(target) / perToken
        guard fitting < Double(fullSize) else { return fullSize }
        var tokens = Int(fitting)
        if tokens > prefillChunkAlignment { tokens -= tokens % prefillChunkAlignment }
        return min(fullSize, max(floor, tokens))
    }

    /// The prefill rate after one drained prefill turn of `tokens` that took
    /// `nanoseconds`: an even blend of the old rate and the new sample.
    static func updatedPrefillRate(_ previous: Double?, tokens: Int, nanoseconds: UInt64) -> Double? {
        guard tokens >= prefillRateMinimumTokens, nanoseconds > 0 else { return previous }
        let sample = Double(nanoseconds) / Double(tokens)
        guard let previous else { return sample }
        return 0.5 * previous + 0.5 * sample
    }

    // MARK: Registration

    /// A handle that is not registered yet: turn calls on it proceed at once
    /// and record nothing until `register(_:modelID:)`. A runtime takes one
    /// while it is constructed and registers it only once its initializer can
    /// no longer throw, so a failed construction never leaves a participant
    /// behind (Swift runs no `deinit` for a partially initialized object).
    func makeParticipant() -> GPUTurnParticipant {
        condition.lock()
        defer { condition.unlock() }
        let participant = GPUTurnParticipant(id: nextID, arbiter: self)
        nextID += 1
        return participant
    }

    func register(modelID: String) -> GPUTurnParticipant {
        condition.lock()
        let participant = GPUTurnParticipant(id: nextID, arbiter: self)
        nextID += 1
        participants.append(GPUTurnParticipantState(id: participant.id, modelID: modelID))
        wakeWaitersLocked()
        condition.unlock()
        return participant
    }

    /// Registers an existing handle again (reload after unload). A handle that
    /// is still registered keeps its counters and takes the new model id.
    func register(_ participant: GPUTurnParticipant, modelID: String) {
        precondition(participant.arbiter === self, "participant belongs to another arbiter")
        condition.lock()
        if let index = indexLocked(participant.id) {
            participants[index].modelID = modelID
        } else {
            participants.append(GPUTurnParticipantState(id: participant.id, modelID: modelID))
        }
        wakeWaitersLocked()
        condition.unlock()
    }

    /// Removes the participant; a caller of this participant still waiting in
    /// `beginTurn` returns at once, and the other participants' waiters
    /// re-ask the policy.
    func unregister(_ participant: GPUTurnParticipant) {
        condition.lock()
        if let index = indexLocked(participant.id) {
            participants.remove(at: index)
            if lastTurnParticipantID == participant.id { lastTurnParticipantID = nil }
        }
        wakeWaitersLocked()
        condition.unlock()
    }

    func isRegistered(_ participant: GPUTurnParticipant) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return indexLocked(participant.id) != nil
    }

    // MARK: Policy

    var currentPolicy: any GPUTurnPolicy {
        condition.lock(); defer { condition.unlock() }
        return policy
    }

    /// Replaces the policy (lab selector and tests). Waiters re-ask the new one.
    func setPolicy(_ newPolicy: any GPUTurnPolicy) {
        condition.lock()
        policy = newPolicy
        wakeWaitersLocked()
        condition.unlock()
    }

    // MARK: Work intervals

    func beginWork(_ participant: GPUTurnParticipant) {
        condition.lock()
        if let index = indexLocked(participant.id) {
            participants[index].pendingWork += 1
        }
        condition.unlock()
    }

    func endWork(_ participant: GPUTurnParticipant) {
        condition.lock()
        if let index = indexLocked(participant.id), participants[index].pendingWork > 0 {
            participants[index].pendingWork -= 1
        }
        wakeWaitersLocked()
        condition.unlock()
    }

    // MARK: Turns

    /// Returns false, holding no turn, only when `isCancelled` reported true
    /// while the caller waited. An unregistered handle proceeds untracked.
    @discardableResult
    func beginTurn(_ participant: GPUTurnParticipant, kind: GPUWorkKind, isCancelled: () -> Bool = { Task.isCancelled }) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard var index = indexLocked(participant.id) else { return true }
        // Fast path: a single participant, or a policy that always proceeds,
        // never consults the policy and never waits. A participant already
        // inside a turn (a nested bracket, or a second loop of the same
        // runtime) never waits either: it would wait on itself.
        if sharingLocked && participants[index].turnsHeld == 0 {
            let waitStart = clock()
            participants[index].waitingSince = waitStart
            participants[index].waitingKind = kind
            // A new waiter can change the decisions of the others.
            wakeWaitersLocked()
            let request = GPUTurnRequest(participantID: participant.id, kind: kind, waitingSince: waitStart)
            var waited = false
            var stalled = false
            while true {
                let admission = Self.admit(request, state: GPUTurnArbiterState(
                    now: clock(), participants: participants, lastTurnParticipantID: lastTurnParticipantID), policy: policy)
                if admission == .proceedStalled { stalled = true; break }
                guard case .wait(let maxNanoseconds) = admission else { break }
                waited = true
                waiters += 1
                let slice = min(maxNanoseconds, Self.cancellationCheckNanoseconds)
                _ = condition.wait(until: Date(timeIntervalSinceNow: Double(slice) / 1e9))
                waiters -= 1
                // Unregistered while waiting: nothing left to account to.
                guard let current = indexLocked(participant.id) else { return true }
                index = current
                // A single participant left, or passthrough: nobody to share with.
                if !sharingLocked { break }
                // The caller's flag may take its own locks: read it unlocked.
                // The loop re-asks with fresh state, so a wake-up here is not lost.
                condition.unlock()
                let cancelled = isCancelled()
                condition.lock()
                guard let afterCheck = indexLocked(participant.id) else { return true }
                index = afterCheck
                if cancelled {
                    recordWaitLocked(index, since: waitStart, waited: true)
                    participants[index].counters.cancelledWaits += 1
                    wakeWaitersLocked()
                    return false
                }
            }
            recordWaitLocked(index, since: waitStart, waited: waited)
            if stalled { participants[index].counters.stallOverrides += 1 }
        }
        let now = clock()
        if participants[index].turnsHeld == 0 { participants[index].turnStartedAt = now }
        participants[index].turnsHeld += 1
        participants[index].lastTurnBeganAt = now
        participants[index].lastTurnKind = kind
        participants[index].counters.turns += 1
        switch kind {
        case .decodeStep(let rows):
            participants[index].counters.decodeSteps += 1
            participants[index].counters.decodeRows += rows
        case .prefillChunk(let tokens):
            participants[index].counters.prefillChunks += 1
            participants[index].counters.prefillTokens += tokens
        }
        if lastTurnParticipantID != participant.id {
            for other in participants.indices { participants[other].consecutiveTurns = 0 }
        }
        participants[index].consecutiveTurns += 1
        lastTurnParticipantID = participant.id
        return true
    }

    func endTurn(_ participant: GPUTurnParticipant) {
        condition.lock()
        guard let first = indexLocked(participant.id), participants[first].turnsHeld > 0 else {
            condition.unlock()
            return
        }
        // Under a sharing policy the last turn held may realise its queued
        // GPU work before it ends: the drain is busy time of the participant
        // that queued it, and the next turn starts on an idle GPU. The
        // policy's drain mode decides: `always` drains every such turn,
        // `never` none, and `handoff` only when another participant waiting
        // in `beginTurn` would be admitted once this turn ends. The decision
        // is taken here, under the lock; the drain runs outside it, with the
        // turn still held, so nobody starts beside it.
        var drains = participants[first].turnsHeld == 1 && sharingLocked
        if drains {
            switch policy.drain {
            case .always: break
            case .never: drains = false
            case .handoff: drains = handoffLocked(after: first)
            }
        }
        condition.unlock()
        if drains { drainQueuedWork() }
        condition.lock()
        defer { condition.unlock() }
        guard let index = indexLocked(participant.id), participants[index].turnsHeld > 0 else { return }
        participants[index].turnsHeld -= 1
        if participants[index].turnsHeld == 0 {
            let now = clock()
            if let started = participants[index].turnStartedAt {
                let held = now &- started
                participants[index].counters.busyNanoseconds &+= held
                // Only a drained turn's held time includes its GPU work.
                if drains, let tokens = participants[index].lastTurnKind?.prefillTokens {
                    participants[index].prefillNanosecondsPerToken = Self.updatedPrefillRate(
                        participants[index].prefillNanosecondsPerToken, tokens: tokens, nanoseconds: held)
                }
            }
            participants[index].turnStartedAt = nil
            participants[index].lastTurnEndedAt = now
        }
        wakeWaitersLocked()
    }

    /// See `GPUTurnParticipant.prefillChunkTokens(fullSize:)`.
    func prefillChunkTokens(_ participant: GPUTurnParticipant, fullSize: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        guard sharingLocked, indexLocked(participant.id) != nil else { return fullSize }
        return Self.prefillChunkTokens(
            participantID: participant.id, fullSize: fullSize,
            state: GPUTurnArbiterState(now: clock(), participants: participants, lastTurnParticipantID: lastTurnParticipantID),
            policy: policy)
    }

    // MARK: Statistics

    func snapshot(resettingMaxWait: Bool = false) -> GPUTurnArbiterSnapshot {
        condition.lock()
        defer { condition.unlock() }
        let now = clock()
        var counters: [Int: GPUTurnParticipantCounters] = [:]
        let rows = participants.map { state -> GPUTurnParticipantSnapshot in
            var c = state.counters
            // A turn in progress counts its time so far.
            if let started = state.turnStartedAt { c.busyNanoseconds &+= now &- started }
            counters[state.id] = c
            return GPUTurnArbiterSnapshot.row(id: state.id, modelID: state.modelID, c)
        }
        if resettingMaxWait {
            for index in participants.indices { participants[index].counters.maxWaitNanoseconds = 0 }
        }
        return GPUTurnArbiterSnapshot(policy: policy.name, policyParameters: policy.parameters, participants: rows, counters: counters)
    }

    /// The state a policy would see now (tests and diagnostics).
    func stateForTest() -> GPUTurnArbiterState {
        condition.lock(); defer { condition.unlock() }
        return GPUTurnArbiterState(now: clock(), participants: participants, lastTurnParticipantID: lastTurnParticipantID)
    }

    /// True when a participant other than the one at `holder` waits in
    /// `beginTurn` and would be admitted once `holder`'s last turn ends.
    private func handoffLocked(after holder: Int) -> Bool {
        var after = participants
        after[holder].turnsHeld = 0
        after[holder].turnStartedAt = nil
        let state = GPUTurnArbiterState(now: clock(), participants: after, lastTurnParticipantID: lastTurnParticipantID)
        for other in after where other.id != after[holder].id {
            guard let since = other.waitingSince, let kind = other.waitingKind else { continue }
            let request = GPUTurnRequest(participantID: other.id, kind: kind, waitingSince: since)
            if case .wait = Self.admit(request, state: state, policy: policy) { continue }
            return true
        }
        return false
    }

    /// Two or more participants under a policy that may wait.
    private var sharingLocked: Bool {
        !policy.alwaysProceeds && participants.count > 1
    }

    private func recordWaitLocked(_ index: Int, since waitStart: UInt64, waited: Bool) {
        let waitedFor = clock() &- waitStart
        participants[index].waitingSince = nil
        participants[index].waitingKind = nil
        if waited {
            participants[index].counters.waitNanoseconds &+= waitedFor
            participants[index].counters.waitedTurns += 1
            participants[index].counters.maxWaitNanoseconds = max(participants[index].counters.maxWaitNanoseconds, waitedFor)
        }
    }

    private func indexLocked(_ id: Int) -> Int? {
        participants.firstIndex { $0.id == id }
    }

    private func wakeWaitersLocked() {
        if waiters > 0 { condition.broadcast() }
    }
}

/// One loop's view of its turn when `begin` and `end` cannot sit in one lexical
/// scope (a token callback ends the turn, the next step begins it). `begin`
/// and `end` are idempotent, so every exit path can call `end`/`close`.
/// Used by one thread at a time; the loops hand it between threads only
/// across awaits, which order the accesses.
final class GPUTurnScope: @unchecked Sendable {
    private let participant: GPUTurnParticipant
    private var holding = false
    private var working = false
    private var closed = false
    /// Read while a `begin` waits; true leaves the wait without a turn. Unset,
    /// the calling task's cancellation is used (a plain inference thread has
    /// none, so loops on one set the request's own flag here).
    var isCancelled: (() -> Bool)?

    init(_ participant: GPUTurnParticipant) {
        self.participant = participant
    }

    /// Starts the work interval (the participant wants turns until `close`).
    func open() {
        guard !working, !closed else { return }
        working = true
        participant.beginWork()
    }

    /// Takes a turn unless one is held. False when the scope is closed or the
    /// wait was cancelled; no turn is held then.
    @discardableResult
    func begin(_ kind: GPUWorkKind) -> Bool {
        guard !closed else { return false }
        guard !holding else { return true }
        holding = participant.beginTurn(kind, isCancelled: isCancelled ?? { Task.isCancelled })
        return holding
    }

    func end() {
        guard holding else { return }
        holding = false
        participant.endTurn()
    }

    /// Ends the current turn and asks for the next one.
    @discardableResult
    func yield(_ kind: GPUWorkKind) -> Bool {
        end()
        return begin(kind)
    }

    /// See `GPUTurnParticipant.prefillChunkTokens(fullSize:)`.
    func prefillChunkTokens(fullSize: Int) -> Int {
        participant.prefillChunkTokens(fullSize: fullSize)
    }

    /// `PrefillParameters.progress` for a chunked prefill whose first chunk
    /// runs in the turn the caller took: after each chunk is queued the turn
    /// passes to the next one (at most `stepSize` tokens, the last being the
    /// iterator's own first forward); the terminal `(total, total)` report
    /// takes no turn.
    func prefillProgress(stepSize: Int) -> @Sendable (Int, Int) -> Void {
        { processed, total in
            let remaining = total - processed
            if remaining > 0 { self.yield(.prefillChunk(tokens: min(stepSize, remaining))) }
        }
    }

    /// Ends any turn and the work interval; later calls do nothing.
    func close() {
        end()
        if working {
            working = false
            participant.endWork()
        }
        closed = true
    }

    deinit {
        // A scope dropped on an error path never leaves its turn held.
        close()
    }
}
