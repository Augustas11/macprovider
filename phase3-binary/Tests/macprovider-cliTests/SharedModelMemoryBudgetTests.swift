import Foundation
import MLX
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-001-R017: the shared memory budget's decisions.
final class SharedModelMemoryBudgetTests: XCTestCase {
    private let gib = 1024 * 1024 * 1024
    private let margin = SharedModelMemoryRules.perMemberMarginBytes

    private func member(
        _ label: String, loaded: Bool = true, resident: Int = 0, wires: Bool = false, perToken: Int = 0,
        committed: Int = 0, inFlight: Int = 0, pinned: Bool = false, lastUsed: UInt64 = 0, cacheLimit: Int? = nil
    ) -> SharedModelMemoryMember {
        var m = SharedModelMemoryMember(label: label)
        m.loaded = loaded
        m.residentBytes = resident
        m.wiresResidentWeights = wires
        m.kvBytesPerToken = perToken
        m.committedKVBytes = committed
        m.inFlightRows = inFlight
        m.pinned = pinned
        m.lastAdmissionAt = lastUsed
        m.cacheLimitRequirementBytes = cacheLimit
        return m
    }

    // MARK: Row admission

    /// One loaded runtime: the shared decision is the pre-R017 live check on
    /// every input, never held when idle, never over a shared budget, even
    /// when the runtime's own committed KV and the row would not fit, and
    /// when an unloaded member (a runtime still loading) is registered.
    func testSingleRuntimeRowDecisionEqualsLegacyCheck() {
        let values = [0, 1, gib, 10 * gib, 199 * gib, 200 * gib, 201 * gib, Int.max / 2, Int.max]
        let lone = [1: member("a", resident: 150 * gib, perToken: 1_000_000, committed: 40 * gib, inFlight: 3)]
        var withLoading = lone
        withLoading[2] = member("b", loaded: false, cacheLimit: gib)
        for active in values {
            for requested in values {
                for limit in [gib, 200 * gib, Int.max] {
                    let legacy = MLXMemoryBudget.admits(activeBytes: active, requestedBytes: requested, limitBytes: limit)
                    for members in [lone, withLoading] {
                        let decision = SharedModelMemoryRules.rowDecision(
                            legacyAdmits: legacy, limitBytes: limit, members: members, requesterID: 1,
                            requesterCommittedBytes: 60 * gib, rowBytes: requested)
                        XCTAssertEqual(decision, .init(admitted: legacy, holdWhenIdle: false, overSharedBudget: false, requiredBytes: 0),
                                       "active=\(active) requested=\(requested) limit=\(limit)")
                    }
                }
            }
        }
    }

    /// The process-wide instance gives an unregistered member the live check.
    func testUnknownMemberGetsLegacyDecision() {
        let budget = SharedModelMemoryBudget()
        for legacy in [true, false] {
            let decision = budget.admitRow(memberID: 7, legacyAdmits: legacy, limitBytes: 1, committedTokens: 10, rowTokens: 10)
            XCTAssertEqual(decision.admitted, legacy)
            XCTAssertFalse(decision.holdWhenIdle)
        }
    }

    /// Two loaded runtimes: a row the live check admits is refused when the
    /// weights of both, their committed KV and this row exceed the limit,
    /// and it waits even on an idle scheduler while the sibling holds rows.
    func testTwoRuntimeAdmissionRefusedPastSharedBudget() {
        let limit = 200 * gib
        let members = [
            1: member("glm", resident: 172 * gib, committed: 6 * gib, inFlight: 2),
            2: member("qwen", resident: 16 * gib),
        ]
        let fits = SharedModelMemoryRules.rowDecision(
            legacyAdmits: true, limitBytes: limit, members: members, requesterID: 2,
            requesterCommittedBytes: 0, rowBytes: 4 * gib)
        XCTAssertTrue(fits.admitted)
        XCTAssertEqual(fits.requiredBytes, 172 * gib + 6 * gib + 16 * gib + 4 * gib + 2 * margin)

        let tooBig = SharedModelMemoryRules.rowDecision(
            legacyAdmits: true, limitBytes: limit, members: members, requesterID: 2,
            requesterCommittedBytes: 0, rowBytes: 6 * gib)
        XCTAssertFalse(tooBig.admitted)
        XCTAssertTrue(tooBig.overSharedBudget)
        XCTAssertTrue(tooBig.holdWhenIdle, "the sibling's rows will free the budget")

        // The requester's fresh committed value replaces its stale one.
        var stale = members
        stale[2]!.committedKVBytes = 50 * gib
        XCTAssertTrue(SharedModelMemoryRules.rowDecision(
            legacyAdmits: true, limitBytes: limit, members: stale, requesterID: 2,
            requesterCommittedBytes: 0, rowBytes: 4 * gib).admitted)

        // The live check still refuses on its own.
        let live = SharedModelMemoryRules.rowDecision(
            legacyAdmits: false, limitBytes: limit, members: members, requesterID: 2,
            requesterCommittedBytes: 0, rowBytes: 0)
        XCTAssertFalse(live.admitted)
        XCTAssertFalse(live.overSharedBudget)
        XCTAssertTrue(live.holdWhenIdle)

        // An idle sibling holds nothing: an idle requester is not held.
        var idleSibling = members
        idleSibling[1]!.committedKVBytes = 0
        idleSibling[1]!.inFlightRows = 0
        let lone = SharedModelMemoryRules.rowDecision(
            legacyAdmits: true, limitBytes: limit, members: idleSibling, requesterID: 2,
            requesterCommittedBytes: 0, rowBytes: 20 * gib)
        XCTAssertFalse(lone.admitted)
        XCTAssertFalse(lone.holdWhenIdle)
    }

    // MARK: Wired limit

    func testWiredLimitIsSumOfWiringResidents() {
        let members = [
            1: member("glm", resident: 120 * gib, wires: true),
            2: member("ds", resident: 60 * gib, wires: true),
            3: member("qwen", resident: 16 * gib),
            4: member("loading", loaded: false, resident: 50 * gib, wires: true),
        ]
        XCTAssertEqual(SharedModelMemoryRules.wiredLimitBytes(members: members, workingSetBytes: 239 * gib), 180 * gib)
        XCTAssertEqual(SharedModelMemoryRules.wiredLimitBytes(members: members, workingSetBytes: 150 * gib), 150 * gib)
        // One wiring runtime: its own resident bytes, as the per-runtime ticket was.
        XCTAssertEqual(SharedModelMemoryRules.wiredLimitBytes(members: [1: members[1]!], workingSetBytes: 239 * gib), 120 * gib)
        XCTAssertNil(SharedModelMemoryRules.wiredLimitBytes(members: [3: members[3]!], workingSetBytes: 239 * gib))
        XCTAssertNil(SharedModelMemoryRules.wiredLimitBytes(members: members, workingSetBytes: nil))
    }

    // MARK: Cache limit

    func testCacheLimitIsSmallestRequirement() {
        let members = [
            1: member("lfm", cacheLimit: 512 * 1024 * 1024),
            2: member("qwen", cacheLimit: 2 * gib),
            3: member("none"),
        ]
        XCTAssertEqual(SharedModelMemoryRules.cacheLimitBytes(members: members), 512 * 1024 * 1024)
        XCTAssertEqual(SharedModelMemoryRules.cacheLimitBytes(members: [2: members[2]!, 3: members[3]!]), 2 * gib)
        XCTAssertNil(SharedModelMemoryRules.cacheLimitBytes(members: [3: members[3]!]))
    }

    /// The process value follows the rule; each runtime reads back its own
    /// value (never a sibling's), and an unload restores the survivors'.
    func testCacheLimitAppliesMinimumAndRestoresOnUnload() {
        let previous = Memory.cacheLimit
        defer { Memory.cacheLimit = previous }
        let budget = SharedModelMemoryBudget()
        let small = 512 * 1024 * 1024
        let large = 2 * gib
        // One runtime: what it sets is what MLX gets.
        XCTAssertEqual(budget.applyCacheLimit(memberID: 2, label: "qwen", bytes: large), large)
        XCTAssertEqual(Memory.cacheLimit, large)
        XCTAssertEqual(budget.cacheLimit(for: 2), large)
        budget.applyCacheLimit(memberID: 1, label: "lfm", bytes: small)
        XCTAssertEqual(Memory.cacheLimit, small)
        XCTAssertEqual(budget.cacheLimit(for: 2), large, "a runtime saves its own value, not the sibling's")
        XCTAssertEqual(budget.cacheLimit(for: 1), small)
        XCTAssertTrue(budget.forget(memberID: 1))
        XCTAssertEqual(Memory.cacheLimit, large)
        // The last runtime leaves the value as it set it.
        XCTAssertTrue(budget.forget(memberID: 2))
        XCTAssertEqual(Memory.cacheLimit, large)
        XCTAssertFalse(budget.forget(memberID: 2))
    }

    // MARK: Cache clears

    func testClearCacheDecision() {
        let limit = gib
        let callerBusy = member("a", inFlight: 1)
        let siblingBusy = member("b", inFlight: 2)
        let siblingIdle = member("b")
        func decide(_ members: [Int: SharedModelMemoryMember], caller: Int?, cache: Int = 0, legacy: Bool = false) -> Bool {
            SharedModelMemoryRules.shouldClearCache(
                members: members, callerID: caller, cacheBytes: cache, cacheLimitBytes: limit, forceLegacy: legacy)
        }
        // One loaded runtime: always, as before.
        XCTAssertTrue(decide([1: callerBusy], caller: 1))
        XCTAssertTrue(decide([1: callerBusy, 2: member("loading", loaded: false, inFlight: 1)], caller: 1))
        // A busy sibling and a cache within its limit: skipped.
        XCTAssertFalse(decide([1: callerBusy, 2: siblingBusy], caller: 1))
        XCTAssertFalse(decide([1: member("a"), 2: siblingBusy], caller: 1))
        // Over the cache limit, an idle sibling, or the lab override: performed.
        XCTAssertTrue(decide([1: callerBusy, 2: siblingBusy], caller: 1, cache: limit + 1))
        XCTAssertTrue(decide([1: callerBusy, 2: siblingIdle], caller: 1))
        XCTAssertTrue(decide([1: callerBusy, 2: siblingBusy], caller: 1, legacy: true))
        // Unknown caller: the caller is one of the busy members.
        XCTAssertTrue(decide([1: callerBusy, 2: siblingIdle], caller: nil))
        XCTAssertFalse(decide([1: callerBusy, 2: siblingBusy], caller: nil))
    }

    // MARK: Eviction

    func testEvictionPicksIdleUnpinnedLeastRecentlyUsed() {
        typealias C = SharedModelMemoryRules.EvictionCandidate
        let candidates = [
            C(id: 1, residentBytes: 10 * gib, inFlightRows: 0, pinned: false, lastUsedAt: 300),
            C(id: 2, residentBytes: 20 * gib, inFlightRows: 0, pinned: false, lastUsedAt: 100),
            C(id: 3, residentBytes: 90 * gib, inFlightRows: 1, pinned: false, lastUsedAt: 0),
            C(id: 4, residentBytes: 90 * gib, inFlightRows: 0, pinned: true, lastUsedAt: 0),
            C(id: 5, residentBytes: 5 * gib, inFlightRows: 0, pinned: false, lastUsedAt: 100),
        ]
        XCTAssertEqual(SharedModelMemoryRules.evictionPlan(candidates, bytesNeeded: 15 * gib),
                       .init(evict: [2], freedBytes: 20 * gib, satisfied: true))
        XCTAssertEqual(SharedModelMemoryRules.evictionPlan(candidates, bytesNeeded: 25 * gib),
                       .init(evict: [2, 5], freedBytes: 25 * gib, satisfied: true))
        XCTAssertEqual(SharedModelMemoryRules.evictionPlan(candidates, bytesNeeded: 30 * gib).evict, [2, 5, 1])
        // In-flight and pinned members are never chosen, even when nothing else frees enough.
        XCTAssertEqual(SharedModelMemoryRules.evictionPlan(candidates, bytesNeeded: 40 * gib),
                       .init(evict: [], freedBytes: 0, satisfied: false))
        XCTAssertEqual(SharedModelMemoryRules.evictionPlan(candidates, bytesNeeded: 0),
                       .init(evict: [], freedBytes: 0, satisfied: true))
    }

    // MARK: Load admission

    func testLoadDecision() {
        let rowTokens = SharedModelMemoryRules.minimumRowTokens
        let loaded = [1: member("glm", resident: 172 * gib, perToken: 100_000, pinned: true)]
        let existingRow = rowTokens * 100_000
        let fits = SharedModelMemoryRules.loadDecision(
            limitBytes: 200 * gib, members: loaded, estimatedResidentBytes: 16 * gib, newMinimumRowKVBytes: gib)
        XCTAssertTrue(fits.admitted)
        XCTAssertEqual(fits.reason, "fits")
        XCTAssertEqual(fits.requiredBytes, 172 * gib + 16 * gib + existingRow + gib + 2 * margin)

        let refused = SharedModelMemoryRules.loadDecision(
            limitBytes: 200 * gib, members: loaded, estimatedResidentBytes: 30 * gib, newMinimumRowKVBytes: gib)
        XCTAssertFalse(refused.admitted)
        XCTAssertEqual(refused.reason, "insufficient_memory")

        var idle = loaded
        idle[2] = member("old", resident: 20 * gib, pinned: false, lastUsed: 5)
        let evicting = SharedModelMemoryRules.loadDecision(
            limitBytes: 200 * gib, members: idle, estimatedResidentBytes: 16 * gib, newMinimumRowKVBytes: gib)
        XCTAssertTrue(evicting.admitted)
        XCTAssertEqual(evicting.reason, "fits_after_eviction")
        XCTAssertEqual(evicting.eviction?.evict, [2])

        var busy = idle
        busy[2]!.inFlightRows = 1
        XCTAssertEqual(SharedModelMemoryRules.loadDecision(
            limitBytes: 200 * gib, members: busy, estimatedResidentBytes: 16 * gib, newMinimumRowKVBytes: gib).reason,
            "insufficient_memory")
        XCTAssertEqual(SharedModelMemoryRules.loadDecision(
            limitBytes: nil, members: loaded, estimatedResidentBytes: gib, newMinimumRowKVBytes: 0).reason,
            "limit_unavailable")
    }

    func testEstimatedResidentBytesSumsSafetensorsThroughSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-budget-\(UUID().uuidString)")
        let blobs = root.appendingPathComponent("blobs")
        let snapshot = root.appendingPathComponent("snapshot")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 1000).write(to: blobs.appendingPathComponent("a"))
        try Data(count: 24).write(to: snapshot.appendingPathComponent("model-2.safetensors"))
        try Data(count: 7).write(to: snapshot.appendingPathComponent("config.json"))
        try FileManager.default.createSymbolicLink(
            at: snapshot.appendingPathComponent("model-1.safetensors"), withDestinationURL: blobs.appendingPathComponent("a"))
        XCTAssertEqual(SharedModelMemoryRules.estimatedResidentBytes(modelDirectory: snapshot), 1024)
    }

    // MARK: Round-2 verifier findings

    private let mib = 1024 * 1024

    /// Two members registered on a fresh budget: `main` (100 GiB alone) and
    /// `worker` (16 GiB of parameters), both at 1 MiB of KV per token.
    private func twoMemberBudget() -> SharedModelMemoryBudget {
        let budget = SharedModelMemoryBudget()
        _ = budget.recordLoaded(memberID: 1, label: "main", modelFamily: "glm", wires: false,
                                activeBytes: 100 * gib, weightBytes: 100 * gib, kvBytesPerToken: mib, pinned: true)
        _ = budget.recordLoaded(memberID: 2, label: "worker", modelFamily: "qwen", wires: false,
                                activeBytes: 116 * gib, weightBytes: 16 * gib, kvBytesPerToken: mib, pinned: true)
        return budget
    }

    /// Finding 1: a serial-path row's KV is charged, so the sibling's row
    /// waits for it instead of over-admitting, and the charge is released
    /// (once) when the serial row ends.
    func testSerialRowKVIsChargedAgainstSibling() {
        let budget = twoMemberBudget()
        let limit = 200 * gib
        func workerRow() -> SharedModelMemoryRules.RowDecision {
            budget.admitRow(memberID: 2, legacyAdmits: true, limitBytes: limit, committedTokens: 0, rowTokens: 4096)
        }
        XCTAssertTrue(workerRow().admitted, "116 GiB weights + 1 GiB margins + a 4 GiB row fit 200 GiB")

        // main runs one serial row: 80K tokens of worst-case KV (80 GiB).
        let charge = budget.chargeSerialRow(memberID: 1, tokens: 80 * 1024, limitBytes: limit)
        XCTAssertNotNil(charge)
        let held = workerRow()
        XCTAssertFalse(held.admitted, "the serial row's KV is charged")
        XCTAssertTrue(held.overSharedBudget)
        XCTAssertTrue(held.holdWhenIdle, "the serial row will free its KV")
        XCTAssertFalse(held.neverFits)

        budget.releaseSerialRow(charge)
        XCTAssertTrue(workerRow().admitted, "a finished, cancelled or failed serial row frees its charge")
        // A second release, a nil charge and an unknown member change nothing.
        budget.releaseSerialRow(charge)
        budget.releaseSerialRow(nil)
        XCTAssertNil(budget.chargeSerialRow(memberID: 9, tokens: 10, limitBytes: limit))
        XCTAssertTrue(workerRow().admitted)

        // Two serial rows release independently.
        let first = budget.chargeSerialRow(memberID: 1, tokens: 40 * 1024, limitBytes: limit)
        let second = budget.chargeSerialRow(memberID: 1, tokens: 40 * 1024, limitBytes: limit)
        XCTAssertFalse(workerRow().admitted)
        budget.releaseSerialRow(first)
        XCTAssertTrue(workerRow().admitted)
        budget.releaseSerialRow(second)

        // An unregistered member's charges go with it.
        let orphan = budget.chargeSerialRow(memberID: 1, tokens: 80 * 1024, limitBytes: limit)
        XCTAssertTrue(budget.forget(memberID: 1))
        budget.releaseSerialRow(orphan)
    }

    /// The serial row's KV bound: prompt plus output bound, the remaining
    /// context when the request sets none, never past the served context.
    func testSerialRowTokens() {
        XCTAssertEqual(SharedModelMemoryRules.serialRowTokens(promptTokens: 1000, maxOutputTokens: 500, maxContextTokens: 8192), 1500)
        XCTAssertEqual(SharedModelMemoryRules.serialRowTokens(promptTokens: 1000, maxOutputTokens: nil, maxContextTokens: 8192), 8192)
        XCTAssertEqual(SharedModelMemoryRules.serialRowTokens(promptTokens: 8000, maxOutputTokens: 4000, maxContextTokens: 8192), 8192)
        XCTAssertEqual(SharedModelMemoryRules.serialRowTokens(promptTokens: 10, maxOutputTokens: Int.max, maxContextTokens: 8192), 8192)
    }

    /// Finding 2: a row over the budget even with every member's rows
    /// finished is never held (it would starve to its queue timeout); a row
    /// that fits once the sibling's rows finish still waits.
    func testNeverFittingRowIsRefusedNotHeld() {
        let limit = 200 * gib
        let members = [
            1: member("glm", resident: 172 * gib, committed: 6 * gib, inFlight: 2),
            2: member("qwen", resident: 16 * gib),
        ]
        // 172 + 16 + 1 GiB margins + 20 = 209 GiB > 200 with glm idle.
        let never = SharedModelMemoryRules.rowDecision(
            legacyAdmits: true, limitBytes: limit, members: members, requesterID: 2,
            requesterCommittedBytes: 0, rowBytes: 20 * gib)
        XCTAssertFalse(never.admitted)
        XCTAssertTrue(never.neverFits)
        XCTAssertFalse(never.holdWhenIdle)
        // A serial charge on glm does not turn it into a wait either.
        var serialBusy = members
        serialBusy[1]!.committedKVBytes = 0
        serialBusy[1]!.serialKVBytes = 6 * gib
        let neverSerial = SharedModelMemoryRules.rowDecision(
            legacyAdmits: true, limitBytes: limit, members: serialBusy, requesterID: 2,
            requesterCommittedBytes: 0, rowBytes: 20 * gib)
        XCTAssertTrue(neverSerial.neverFits)
        XCTAssertFalse(neverSerial.holdWhenIdle)

        // 172 + 16 + 1 + 10 = 199 GiB fits once glm's 6 GiB finish: it waits.
        let later = SharedModelMemoryRules.rowDecision(
            legacyAdmits: true, limitBytes: limit, members: members, requesterID: 2,
            requesterCommittedBytes: 0, rowBytes: 10 * gib)
        XCTAssertFalse(later.admitted)
        XCTAssertFalse(later.neverFits)
        XCTAssertTrue(later.holdWhenIdle)
        // The requester's own rows finish too: they never make a row never-fit.
        let ownRows = SharedModelMemoryRules.rowDecision(
            legacyAdmits: true, limitBytes: limit, members: members, requesterID: 2,
            requesterCommittedBytes: 30 * gib, rowBytes: 10 * gib)
        XCTAssertFalse(ownRows.neverFits)
    }

    /// Finding 3: a model loaded while a sibling serves is charged its own
    /// weights, not the sibling's live KV, whatever the sibling is doing.
    func testResidentBytesExcludeSiblingLiveKV() {
        var busy = member("main", resident: 100 * gib, committed: 30 * gib)
        busy.serialKVBytes = 10 * gib
        let idle = member("main", resident: 100 * gib)
        // MLX active memory at registration: main's weights + its live KV + worker's 16 GiB.
        XCTAssertEqual(SharedModelMemoryRules.residentBytes(
            activeBytes: 156 * gib, siblings: [busy], weightBytes: 16 * gib), 16 * gib)
        XCTAssertEqual(SharedModelMemoryRules.residentBytes(
            activeBytes: 116 * gib, siblings: [idle], weightBytes: 16 * gib), 16 * gib)
        // Without parameter bytes the sibling's weights and row charges are
        // taken out of active memory.
        XCTAssertEqual(SharedModelMemoryRules.residentBytes(
            activeBytes: 156 * gib, siblings: [busy], weightBytes: nil), 16 * gib)

        // Through the budget: the same figure with the sibling busy or idle.
        let quiet = twoMemberBudget()
        let loud = SharedModelMemoryBudget()
        _ = loud.recordLoaded(memberID: 1, label: "main", modelFamily: "glm", wires: false,
                              activeBytes: 100 * gib, weightBytes: 100 * gib, kvBytesPerToken: mib, pinned: true)
        _ = loud.chargeSerialRow(memberID: 1, tokens: 40 * 1024, limitBytes: 200 * gib)
        let (worker, count) = loud.recordLoaded(memberID: 2, label: "worker", modelFamily: "qwen", wires: false,
                                                activeBytes: 156 * gib, weightBytes: 16 * gib, kvBytesPerToken: mib, pinned: true)
        XCTAssertEqual(worker.residentBytes, 16 * gib)
        XCTAssertEqual(count, 2)
        let quietWorker = quiet.recordLoaded(memberID: 2, label: "worker", modelFamily: "qwen", wires: false,
                                             activeBytes: 116 * gib, weightBytes: 16 * gib, kvBytesPerToken: mib, pinned: true).0
        XCTAssertEqual(quietWorker.residentBytes, worker.residentBytes)
    }

    /// Load admission and eviction see serial and batched live KV: a member
    /// with only a serial row is busy (never evicted) and its live KV counts
    /// when larger than one minimum row.
    func testLoadDecisionCountsLiveRowKV() {
        let rowTokens = SharedModelMemoryRules.minimumRowTokens
        var serving = member("glm", resident: 150 * gib, perToken: mib, pinned: true)
        serving.serialKVBytes = 35 * gib
        let decision = SharedModelMemoryRules.loadDecision(
            limitBytes: 200 * gib, members: [1: serving], estimatedResidentBytes: 16 * gib, newMinimumRowKVBytes: gib)
        XCTAssertEqual(decision.requiredBytes, 150 * gib + 16 * gib + 35 * gib + gib + 2 * margin)
        XCTAssertFalse(decision.admitted, "the serving row's KV is not free memory")
        // Idle: one minimum row, as before.
        let idle = SharedModelMemoryRules.loadDecision(
            limitBytes: 200 * gib, members: [1: member("glm", resident: 150 * gib, perToken: mib, pinned: true)],
            estimatedResidentBytes: 16 * gib, newMinimumRowKVBytes: gib)
        XCTAssertEqual(idle.requiredBytes, 150 * gib + 16 * gib + rowTokens * mib + gib + 2 * margin)

        var serialOnly = member("old", resident: 40 * gib, pinned: false)
        serialOnly.serialKVBytes = gib
        let members = [1: member("glm", resident: 150 * gib, pinned: true), 2: serialOnly]
        XCTAssertEqual(SharedModelMemoryRules.loadDecision(
            limitBytes: 200 * gib, members: members, estimatedResidentBytes: 16 * gib, newMinimumRowKVBytes: gib).reason,
            "insufficient_memory", "a member serving a serial row is not evicted")
    }

    /// One registered runtime behaves as before every change here: no hold,
    /// no never-fit refusal, the legacy decision, and the resident figure is
    /// MLX's active memory even with parameter bytes given.
    func testSingleRuntimeUnchangedBySerialChargesAndWeightBytes() {
        let budget = SharedModelMemoryBudget()
        let (lone, count) = budget.recordLoaded(
            memberID: 1, label: "main", modelFamily: "glm", wires: true,
            activeBytes: 101 * gib, weightBytes: 100 * gib, kvBytesPerToken: mib, pinned: true)
        XCTAssertEqual(lone.residentBytes, 101 * gib, "alone: the single-runtime active-memory figure")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(SharedModelMemoryRules.wiredLimitBytes(members: [1: lone], workingSetBytes: 239 * gib), 101 * gib)
        XCTAssertEqual(SharedModelMemoryRules.residentBytes(
            activeBytes: 101 * gib, siblings: [member("loading", loaded: false, resident: 9 * gib)], weightBytes: 100 * gib),
            101 * gib)

        // A huge serial row and a row that would never fit a shared budget.
        let charge = budget.chargeSerialRow(memberID: 1, tokens: 500 * 1024, limitBytes: gib)
        XCTAssertNotNil(charge)
        for legacy in [true, false] {
            let decision = budget.admitRow(
                memberID: 1, legacyAdmits: legacy, limitBytes: gib, committedTokens: 1 << 20, rowTokens: 1 << 20)
            XCTAssertEqual(decision, .init(admitted: legacy, holdWhenIdle: false, overSharedBudget: false, requiredBytes: 0))
            XCTAssertFalse(decision.neverFits)
        }
        budget.releaseSerialRow(charge)
    }
}
