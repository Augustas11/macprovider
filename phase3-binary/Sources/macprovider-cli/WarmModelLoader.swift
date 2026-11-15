import Foundation

/// What a load needs before any weights are read.
struct WarmModelLoadSpec: Sendable, Equatable {
    let modelID: String
    /// The weights' bytes (`SharedModelMemoryRules.estimatedResidentBytes`).
    let estimatedResidentBytes: Int
    /// One minimum row of the new model's KV.
    let minimumRowKVBytes: Int
}

enum WarmModelLoaderError: Error, Equatable, CustomStringConvertible {
    /// R017 *Load*: the weights do not fit, even after evicting every idle
    /// unpinned member. `reason` is the load decision's reason.
    case insufficientMemory(modelID: String, reason: String, requiredBytes: Int, limitBytes: Int?)

    var reason: String {
        switch self {
        case .insufficientMemory: return "insufficient_memory"
        }
    }

    var description: String {
        switch self {
        case let .insufficientMemory(modelID, reason, required, limit):
            return "insufficient_memory model=\(modelID) decision=\(reason) required_bytes=\(required) limit_bytes=\(limit.map(String.init) ?? "nil")"
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
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        table: WarmModelTable<Runtime>,
        budget: SharedModelMemoryBudget = .shared,
        limitBytes: @escaping @Sendable () -> Int? = { SharedModelMemoryBudget.processLimitBytes() },
        idlePollNanoseconds: UInt64 = 10_000_000,
        factory: @escaping Factory
    ) {
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
        if table.entry(modelID: spec.modelID) != nil {
            throw WarmModelTableError.duplicate(modelID: spec.modelID)
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
        await runtime.unloadForWarmSet()
        table.finishEvicting(token: entry.token)
    }
}
