import Foundation
import MacProviderCore

/// What a load needs before any weights are read.
struct WarmModelLoadSpec: Sendable, Equatable {
    let modelID: String
    /// The weights' bytes (`SharedModelMemoryRules.estimatedResidentBytes`).
    let estimatedResidentBytes: Int
    /// One minimum row of the new model's KV.
    let minimumRowKVBytes: Int
    /// The model's family (`config.json` `model_type`), nil when unknown:
    /// decides whether its command-buffer budget matches the device's.
    var modelFamily: String? = nil
    /// The member's own context and slots (`warm_model_limits`, or the
    /// limits a control-socket load names); nil takes the primary's.
    var limits: WarmModelLimits? = nil
}

enum WarmModelLoaderError: Error, Equatable, CustomStringConvertible {
    /// R017 *Load*: the weights do not fit, even after evicting every idle
    /// unpinned member. `reason` is the load decision's reason.
    case insufficientMemory(modelID: String, reason: String, requiredBytes: Int, limitBytes: Int?)
    /// R017: MLX's command-buffer budget is set once per process; this
    /// model's family needs another value than the loaded members run with.
    case commandBufferBudgetConflict(modelID: String, detail: String)
    /// The loader was stopped (process shutdown): no further load starts,
    /// and a load that finishes afterwards is unloaded again.
    case stopped(modelID: String)

    var reason: String {
        switch self {
        case .insufficientMemory: return "insufficient_memory"
        case .commandBufferBudgetConflict: return "command_buffer_budget_conflict"
        case .stopped: return "stopping"
        }
    }

    var description: String {
        switch self {
        case let .insufficientMemory(modelID, reason, required, limit):
            return "insufficient_memory model=\(modelID) decision=\(reason) required_bytes=\(required) limit_bytes=\(limit.map(String.init) ?? "nil")"
        case let .commandBufferBudgetConflict(modelID, detail):
            return "command_buffer_budget_conflict model=\(modelID) \(detail)"
        case let .stopped(modelID):
            return "stopping model=\(modelID)"
        }
    }
}

/// SPEC-001-R017 load, eviction and unload of warm-set members. One load,
/// evict, unload or swap runs at a time (`exclusive`); the table's lock is
/// never held across a load or an unload.
actor WarmModelLoader<Runtime: WarmModelRuntime> {
    typealias Factory = @Sendable (WarmModelLoadSpec) async throws -> Runtime

    let table: WarmModelTable<Runtime>
    private let budget: SharedModelMemoryBudget
    private let limitBytes: @Sendable () -> Int?
    private let idlePollNanoseconds: UInt64
    private let factory: Factory
    /// SPEC-001-R019: stops what runs on a member's runtime (its own
    /// self-check) right before that runtime unloads; never called for
    /// another member.
    private let beforeUnload: @Sendable (Runtime) async -> Void
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false

    init(
        table: WarmModelTable<Runtime>,
        budget: SharedModelMemoryBudget = .shared,
        limitBytes: @escaping @Sendable () -> Int? = { SharedModelMemoryBudget.processLimitBytes() },
        idlePollNanoseconds: UInt64 = 10_000_000,
        factory: @escaping Factory,
        beforeUnload: @escaping @Sendable (Runtime) async -> Void = { _ in }
    ) {
        self.beforeUnload = beforeUnload
        self.table = table
        self.budget = budget
        self.limitBytes = limitBytes
        self.idlePollNanoseconds = idlePollNanoseconds
        self.factory = factory
    }

    /// Runs `body` with no other load, evict, unload or swap in progress.
    /// Actor methods interleave at every await; this queue does not.
    func exclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquireTurn()
        defer { releaseTurn() }
        return try await body()
    }

    /// Adopts the boot model as the pinned primary and reserves its rows.
    @discardableResult
    func adoptPrimary(modelID: String, runtime: Runtime) async throws -> WarmModelTableEntry<Runtime> {
        await acquireTurn()
        defer { releaseTurn() }
        let token = try table.insertPrimary(modelID: modelID, runtime: runtime, pinned: true)
        await pinAndReserve(runtime, pinned: true)
        return table.entry(token: token)!
    }

    /// R017 *Load*. Fits: loads. Fits after eviction: evicts the planned
    /// members (idle, unpinned, least recently used first), then loads.
    /// Otherwise refuses with `insufficient_memory` and changes nothing.
    @discardableResult
    func load(_ spec: WarmModelLoadSpec, pinned: Bool) async throws -> WarmModelTableEntry<Runtime> {
        await acquireTurn()
        defer { releaseTurn() }
        return try await loadExclusive(spec, pinned: pinned)
    }

    /// R017 *Eviction* of one member by id: refused for the primary, a
    /// pinned member, a member that is not warm, or one holding a lease.
    func evict(_ modelID: String) async throws {
        await acquireTurn()
        defer { releaseTurn() }
        try await unloadMarked(table.beginEvicting(modelID: modelID, allowPinned: false))
    }

    /// Explicit unload: as `evict`, except a pinned non-primary member may go.
    func unload(_ modelID: String) async throws {
        await acquireTurn()
        defer { releaseTurn() }
        try await unloadMarked(table.beginEvicting(modelID: modelID, allowPinned: true))
    }

    /// SPEC-011 R-3.10.3 promotion of a `warm` secondary to primary, no
    /// load. The caller holds the turn (`exclusive`, the swap's turn). The
    /// new primary is pinned with its rows reserved; the old one is
    /// unpinned, so a later load may evict it once it is idle.
    func promoteInTurn(_ modelID: String) async throws -> (old: WarmModelTableEntry<Runtime>, new: WarmModelTableEntry<Runtime>) {
        let promoted = try table.promote(modelID: modelID)
        if let memberID = promoted.old.memberID { budget.setPinned(memberID: memberID, false) }
        if let runtime = promoted.new.runtime { await pinAndReserve(runtime, pinned: true) }
        return promoted
    }

    /// Process shutdown: refuses every later load and marks a load in
    /// flight to be unloaded when its factory returns. Never waits for the
    /// turn, so a load that is still reading weights cannot hold it up.
    func stop() {
        stopped = true
    }

    /// True while a load, evict, unload or swap holds the turn.
    var isBusy: Bool { busy }

    /// Process shutdown, after `stop()` and the relay drain: unloads every
    /// warm non-primary member without taking the turn (a load in flight may
    /// hold it). A member still holding a lease or a row is given until
    /// `idleTimeoutNanoseconds` to finish and is left to process exit after.
    func unloadSecondariesForShutdown(idleTimeoutNanoseconds: UInt64) async {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ idleTimeoutNanoseconds
        for entry in table.entries() where !entry.primary && entry.state == .warm {
            guard let memberID = entry.memberID else { continue }
            while (table.entry(token: entry.token)?.leases ?? 0) > 0 || budget.busyRows(memberID: memberID) > 0 {
                guard DispatchTime.now().uptimeNanoseconds < deadline,
                      (try? await Task.sleep(nanoseconds: idlePollNanoseconds)) != nil else { break }
            }
            guard budget.busyRows(memberID: memberID) == 0,
                  let marked = try? table.beginEvicting(modelID: entry.modelID, allowPinned: true),
                  let runtime = marked.runtime else { continue }
            await beforeUnload(runtime)
            await runtime.unloadForWarmSet()
            table.finishEvicting(token: marked.token)
        }
    }

    // MARK: Private

    /// The turn passes straight to the next waiter, so no caller that
    /// arrives meanwhile can take it.
    private func acquireTurn() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func releaseTurn() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    private func loadExclusive(_ spec: WarmModelLoadSpec, pinned: Bool) async throws -> WarmModelTableEntry<Runtime> {
        guard !stopped else { throw WarmModelLoaderError.stopped(modelID: spec.modelID) }
        if table.entry(modelID: spec.modelID) != nil {
            throw WarmModelTableError.duplicate(modelID: spec.modelID)
        }
        // Before any eviction: a refusal here must leave the set unchanged.
        if let family = spec.modelFamily, let detail = budget.commandBufferBudgetConflict(modelFamily: family) {
            throw WarmModelLoaderError.commandBufferBudgetConflict(modelID: spec.modelID, detail: detail)
        }
        let decision = decide(spec)
        guard decision.admitted else { throw refusal(spec, decision) }
        if let plan = decision.eviction, !plan.evict.isEmpty {
            // All planned members are marked before any is unloaded, so a
            // plan that a lease or a new row has overtaken changes nothing.
            let marked: [WarmModelTableEntry<Runtime>]
            do {
                marked = try table.beginEvicting(memberIDs: plan.evict)
            } catch {
                throw refusal(spec, decision)
            }
            if marked.contains(where: { budget.busyRows(memberID: $0.memberID!) > 0 }) {
                for entry in marked { table.cancelEvicting(token: entry.token) }
                throw refusal(spec, decision)
            }
            for entry in marked { try await unloadMarked(entry) }
            let after = decide(spec)
            guard after.admitted, after.eviction == nil else { throw refusal(spec, after) }
        }

        let reservation = budget.reserveLoad(estimatedResidentBytes: spec.estimatedResidentBytes)
        let token: UInt64
        do {
            token = try table.beginLoading(modelID: spec.modelID, pinned: pinned)
        } catch {
            budget.releaseLoad(reservation)
            throw error
        }
        let runtime: Runtime
        do {
            runtime = try await factory(spec)
        } catch {
            table.cancelLoading(token: token)
            budget.releaseLoad(reservation)
            throw error
        }
        budget.releaseLoad(reservation)
        if stopped {
            table.cancelLoading(token: token)
            await beforeUnload(runtime)
            await runtime.unloadForWarmSet()
            throw WarmModelLoaderError.stopped(modelID: spec.modelID)
        }
        await pinAndReserve(runtime, pinned: pinned)
        try table.finishLoading(token: token, runtime: runtime)
        return table.entry(token: token)!
    }

    private func decide(_ spec: WarmModelLoadSpec) -> SharedModelMemoryRules.LoadDecision {
        budget.canLoad(
            estimatedResidentBytes: spec.estimatedResidentBytes, minimumRowKVBytes: spec.minimumRowKVBytes,
            limitBytes: limitBytes())
    }

    private func refusal(_ spec: WarmModelLoadSpec, _ decision: SharedModelMemoryRules.LoadDecision) -> WarmModelLoaderError {
        .insufficientMemory(
            modelID: spec.modelID, reason: decision.admitted ? "insufficient_memory" : decision.reason,
            requiredBytes: decision.requiredBytes, limitBytes: decision.limitBytes)
    }

    /// Registration pins every budget member; the table's flag decides.
    private func pinAndReserve(_ runtime: Runtime, pinned: Bool) async {
        let memberID = runtime.memoryBudgetMemberID
        budget.setPinned(memberID: memberID, pinned)
        guard pinned else { return }
        let reservation = await runtime.warmSetRowReservation()
        budget.reserveRows(memberID: memberID, rows: reservation.rows, tokensPerRow: reservation.tokensPerRow)
    }

    /// Waits until the `evicting` member holds no lease and no row, then
    /// unloads it and removes its entry. Cancelled while waiting, the member
    /// returns to `warm`.
    private func unloadMarked(_ entry: WarmModelTableEntry<Runtime>) async throws {
        guard let runtime = entry.runtime, let memberID = entry.memberID else { return }
        while (table.entry(token: entry.token)?.leases ?? 0) > 0 || budget.busyRows(memberID: memberID) > 0 {
            do {
                try await Task.sleep(nanoseconds: idlePollNanoseconds)
            } catch {
                table.cancelEvicting(token: entry.token)
                throw error
            }
        }
        await beforeUnload(runtime)
        await runtime.unloadForWarmSet()
        table.finishEvicting(token: entry.token)
    }
}
