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
}
