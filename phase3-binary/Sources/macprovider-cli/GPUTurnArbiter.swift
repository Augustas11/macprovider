import Foundation

// SPEC-001-R018 (#2338): one process-wide arbiter for the GPU turns of every
// warm model. Each `ModelRuntime` registers one participant; its decode and
// prefill loops bracket every unit of GPU work (one decode step, one prefill
// chunk) with `beginTurn` / `endTurn`. A `GPUTurnPolicy` decides, before each
// unit, whether the caller proceeds or waits until another participant has had
// its turn. The arbiter orders submission only: MLX still runs whatever was
// submitted on the process GPU stream, so a turn ends when its work is queued
// and read back, not when the GPU has drained it.
//
// The compiled-in policy is `PassthroughGPUTurnPolicy` (always proceed), so
// serving behaviour is unchanged. Lab builds (`DEBUG || MACPROVIDER_LAB_HARNESS`)
// may select another registered policy by name to compare candidates.

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
    func beginTurn(_ kind: GPUWorkKind) { arbiter.beginTurn(self, kind: kind) }
    func endTurn() { arbiter.endTurn(self) }
    func withTurn<R>(_ kind: GPUWorkKind, _ body: () throws -> R) rethrows -> R {
        beginTurn(kind)
        defer { endTurn() }
        return try body()
    }
    /// Marks an interval in which this participant has work pending and will
    /// ask for turns (a serial request, a scheduler pump with rows).
    func beginWork() { arbiter.beginWork(self) }
    func endWork() { arbiter.endWork(self) }

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
    /// Wall time inside turns (overlapping turns of one participant count once).
    var busyNanoseconds: UInt64 = 0
    /// Wall time spent blocked in `beginTurn` waiting for the policy.
    var waitNanoseconds: UInt64 = 0
    /// Turns that had to wait at least once.
    var waitedTurns = 0
    /// Longest single wait since the last `snapshot(resettingMaxWait: true)`.
    var maxWaitNanoseconds: UInt64 = 0
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
    /// registers, unregisters or ends its work) or `maxNanoseconds` pass,
    /// whichever comes first, then ask again. `nil` waits for a state change
    /// only.
    case wait(maxNanoseconds: UInt64?)
}

/// A pure decision object: no MLX calls, no clocks of its own, no mutable
/// state. The arbiter calls `decide` under its lock for every turn a caller
/// asks for while at least two participants are registered, and again after
/// every state change while the caller waits.
protocol GPUTurnPolicy: Sendable {
    var name: String { get }
    var parameters: [String: String] { get }
    /// True only for a policy that proceeds unconditionally; the arbiter then
    /// never calls `decide`.
    var alwaysProceeds: Bool { get }
    func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision
}

extension GPUTurnPolicy {
    var alwaysProceeds: Bool { false }
    var parameters: [String: String] { [:] }
}

/// Default: every caller proceeds at once (today's behaviour).
struct PassthroughGPUTurnPolicy: GPUTurnPolicy {
    static let name = "passthrough"
    static let factory = GPUTurnPolicyFactory(
        name: name,
        summary: "Always proceed; the GPU is shared as MLX submission order leaves it."
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

    /// The policy every build serves with.
    static let compiledDefault: any GPUTurnPolicy = PassthroughGPUTurnPolicy()

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
            waitedTurns: c.waitedTurns, maxWaitSeconds: Double(c.maxWaitNanoseconds) / 1e9)
    }
}

/// Process-wide GPU turn arbiter. Thread-safe; every call is synchronous.
/// `beginTurn` may block the calling thread while the policy says wait, so it
/// is called from the inference threads that already block on MLX evaluation,
/// never while holding a lock another participant's turn needs.
final class GPUTurnArbiter: @unchecked Sendable {
    static let shared = GPUTurnArbiter(policy: GPUTurnPolicyRegistry.processDefault())

    private let condition = NSCondition()
    private let clock: @Sendable () -> UInt64
    private var policy: any GPUTurnPolicy
    private var participants: [GPUTurnParticipantState] = []
    private var lastTurnParticipantID: Int?
    private var nextID = 1
    private var waiters = 0

    init(
        policy: any GPUTurnPolicy = GPUTurnPolicyRegistry.compiledDefault,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.policy = policy
        self.clock = clock
    }

    // MARK: Registration

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

    func beginTurn(_ participant: GPUTurnParticipant, kind: GPUWorkKind) {
        condition.lock()
        defer { condition.unlock() }
        guard var index = indexLocked(participant.id) else { return }
        // Fast path: a single participant, or a policy that always proceeds,
        // never consults the policy and never waits. A participant already
        // inside a turn (a nested bracket, or a second loop of the same
        // runtime) never waits either: it would wait on itself.
        if !policy.alwaysProceeds && participants.count > 1 && participants[index].turnsHeld == 0 {
            let waitStart = clock()
            participants[index].waitingSince = waitStart
            participants[index].waitingKind = kind
            let request = GPUTurnRequest(participantID: participant.id, kind: kind, waitingSince: waitStart)
            var waited = false
            while true {
                let decision = policy.decide(request, state: GPUTurnArbiterState(
                    now: clock(), participants: participants, lastTurnParticipantID: lastTurnParticipantID))
                guard case .wait(let maxNanoseconds) = decision else { break }
                waited = true
                waiters += 1
                if let maxNanoseconds {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: Double(maxNanoseconds) / 1e9))
                } else {
                    condition.wait()
                }
                waiters -= 1
                // Unregistered while waiting: nothing left to account to.
                guard let current = indexLocked(participant.id) else { return }
                index = current
                // A single participant left: nobody to share with.
                if policy.alwaysProceeds || participants.count < 2 { break }
            }
            let waitedFor = clock() &- waitStart
            participants[index].waitingSince = nil
            participants[index].waitingKind = nil
            if waited {
                participants[index].counters.waitNanoseconds &+= waitedFor
                participants[index].counters.waitedTurns += 1
                participants[index].counters.maxWaitNanoseconds = max(participants[index].counters.maxWaitNanoseconds, waitedFor)
            }
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
        lastTurnParticipantID = participant.id
    }

    func endTurn(_ participant: GPUTurnParticipant) {
        condition.lock()
        defer { condition.unlock() }
        guard let index = indexLocked(participant.id), participants[index].turnsHeld > 0 else { return }
        participants[index].turnsHeld -= 1
        if participants[index].turnsHeld == 0 {
            let now = clock()
            if let started = participants[index].turnStartedAt {
                participants[index].counters.busyNanoseconds &+= now &- started
            }
            participants[index].turnStartedAt = nil
            participants[index].lastTurnEndedAt = now
        }
        wakeWaitersLocked()
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

    init(_ participant: GPUTurnParticipant) {
        self.participant = participant
    }

    /// Starts the work interval (the participant wants turns until `close`).
    func open() {
        guard !working, !closed else { return }
        working = true
        participant.beginWork()
    }

    func begin(_ kind: GPUWorkKind) {
        guard !holding, !closed else { return }
        participant.beginTurn(kind)
        holding = true
    }

    func end() {
        guard holding else { return }
        holding = false
        participant.endTurn()
    }

    /// Ends the current turn and asks for the next one.
    func yield(_ kind: GPUWorkKind) {
        end()
        begin(kind)
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
