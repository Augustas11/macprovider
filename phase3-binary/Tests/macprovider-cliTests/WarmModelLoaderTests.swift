import Foundation
import XCTest
@testable import macprovider_cli

private final class LoaderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

private final class FakeLoadedRuntime: WarmModelRuntime, @unchecked Sendable {
    let memoryBudgetMemberID: Int
    let modelID: String
    let reservation: WarmModelRowReservation
    private let budget: SharedModelMemoryBudget
    private let log: LoaderLog

    init(memberID: Int, modelID: String, budget: SharedModelMemoryBudget, log: LoaderLog,
         reservation: WarmModelRowReservation = .init(rows: 0, tokensPerRow: 0)) {
        self.memoryBudgetMemberID = memberID
        self.modelID = modelID
        self.budget = budget
        self.log = log
        self.reservation = reservation
    }

    func warmSetRowReservation() async -> WarmModelRowReservation { reservation }

    func unloadForWarmSet() async {
        log.append("unload \(modelID)")
        budget.forget(memberID: memoryBudgetMemberID)
    }
}

private struct FactoryFailure: Error {}

/// SPEC-001-R017 load, eviction and unload through the warm-set loader, on
/// a private budget with fake runtimes: no model is loaded.
final class WarmModelLoaderTests: XCTestCase {
    private let gib = 1024 * 1024 * 1024
    private let margin = SharedModelMemoryRules.perMemberMarginBytes

    private final class Harness: @unchecked Sendable {
        let budget = SharedModelMemoryBudget()
        let table = WarmModelTable<FakeLoadedRuntime>()
        let log = LoaderLog()
        let lock = NSLock()
        var nextMemberID = 9_000
        var failNext = false
        var loader: WarmModelLoader<FakeLoadedRuntime>!

        init(limitBytes: Int) {
            loader = WarmModelLoader(
                table: table, budget: budget, limitBytes: { limitBytes }, idlePollNanoseconds: 1_000_000
            ) { [unowned self] spec in try self.make(spec) }
        }

        func make(_ spec: WarmModelLoadSpec) throws -> FakeLoadedRuntime {
            lock.lock()
            let fail = failNext
            failNext = false
            nextMemberID += 1
            let id = nextMemberID
            lock.unlock()
            if fail { throw FactoryFailure() }
            // As `ModelRuntime`'s load registers its measured weights.
            _ = budget.recordLoaded(
                memberID: id, label: spec.modelID, modelFamily: "fake", wires: false,
                activeBytes: spec.estimatedResidentBytes, weightBytes: spec.estimatedResidentBytes,
                kvBytesPerToken: 0, pinned: true)
            log.append("load \(spec.modelID)")
            return FakeLoadedRuntime(memberID: id, modelID: spec.modelID, budget: budget, log: log)
        }

        func adoptPrimary(_ modelID: String, bytes: Int, perToken: Int = 0,
                          reservation: WarmModelRowReservation = .init(rows: 0, tokensPerRow: 0)) async throws -> FakeLoadedRuntime {
            _ = budget.recordLoaded(
                memberID: 1, label: modelID, modelFamily: "fake", wires: false, activeBytes: bytes,
                weightBytes: bytes, kvBytesPerToken: perToken, pinned: true)
            let runtime = FakeLoadedRuntime(memberID: 1, modelID: modelID, budget: budget, log: log, reservation: reservation)
            try await loader.adoptPrimary(modelID: modelID, runtime: runtime)
            return runtime
        }

        func spec(_ modelID: String, _ bytes: Int) -> WarmModelLoadSpec {
            WarmModelLoadSpec(modelID: modelID, estimatedResidentBytes: bytes, minimumRowKVBytes: 0)
        }

        func memberID(_ modelID: String) -> Int { table.entry(modelID: modelID)!.memberID! }

        var state: [String] { table.entries().map { "\($0.modelID):\($0.state.rawValue)" } }
    }

    private func assertInsufficient(_ body: () async throws -> Any, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("load admitted", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? WarmModelLoaderError)?.reason, "insufficient_memory", "\(error)", file: file, line: line)
        }
    }

    // MARK: Load decisions

    func testFitsLoadsWithoutEviction() async throws {
        let h = Harness(limitBytes: 100 * gib + 3 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        try await h.loader.load(h.spec("A", 30 * gib), pinned: false)
        let entry = try await h.loader.load(h.spec("B", 30 * gib), pinned: true)
        XCTAssertEqual(entry.state, .warm)
        XCTAssertEqual(h.state, ["P:warm", "A:warm", "B:warm"])
        XCTAssertEqual(h.log.all, ["load A", "load B"])
        XCTAssertEqual(h.budget.member(h.memberID("A"))?.pinned, false, "the table's flag reaches the budget")
        XCTAssertEqual(h.budget.member(h.memberID("B"))?.pinned, true)
        XCTAssertEqual(h.budget.pendingLoadBytes, 0)
        do {
            _ = try await h.loader.load(h.spec("a", gib), pinned: false)
            XCTFail("duplicate load admitted")
        } catch {
            XCTAssertEqual(error as? WarmModelTableError, .duplicate(modelID: "a"))
        }
    }

    func testFitsAfterEvictionEvictsTheIdleUnpinnedMember() async throws {
        let h = Harness(limitBytes: 100 * gib + 3 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        try await h.loader.load(h.spec("A", 30 * gib), pinned: false)
        let evictedID = h.memberID("A")
        try await h.loader.load(h.spec("B", 31 * gib), pinned: false)
        XCTAssertEqual(h.state, ["P:warm", "B:warm"])
        XCTAssertEqual(h.log.all, ["load A", "unload A", "load B"])
        XCTAssertNil(h.budget.member(evictedID))
    }

    func testRefusedWhenNothingCanBeEvicted() async throws {
        let h = Harness(limitBytes: 100 * gib + 3 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        try await h.loader.load(h.spec("A", 30 * gib), pinned: true)
        let before = h.budget.member(h.memberID("A"))
        await assertInsufficient { try await h.loader.load(h.spec("B", 31 * gib), pinned: false) }
        XCTAssertEqual(h.state, ["P:warm", "A:warm"])
        XCTAssertEqual(h.budget.member(h.memberID("A")), before)
        XCTAssertEqual(h.log.all, ["load A"])
    }

    func testLeasedMemberIsNeverEvicted() async throws {
        let h = Harness(limitBytes: 100 * gib + 3 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        try await h.loader.load(h.spec("A", 30 * gib), pinned: false)
        let lease = try h.table.lease(servedModelID: "A")
        await assertInsufficient { try await h.loader.load(h.spec("B", 31 * gib), pinned: false) }
        XCTAssertEqual(h.state, ["P:warm", "A:warm"], "a refused load changes nothing")
        XCTAssertEqual(h.table.entry(modelID: "A")?.leases, 1)
        do {
            try await h.loader.evict("A")
            XCTFail("leased member evicted")
        } catch {
            XCTAssertEqual((error as? WarmModelTableError)?.reason, "busy")
        }
        lease.release()
        try await h.loader.load(h.spec("B", 31 * gib), pinned: false)
        XCTAssertEqual(h.state, ["P:warm", "B:warm"])
    }

    func testMemberWithInFlightRowsIsNeverEvicted() async throws {
        let h = Harness(limitBytes: 100 * gib + 3 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        try await h.loader.load(h.spec("A", 30 * gib), pinned: false)
        h.budget.setInFlightRows(memberID: h.memberID("A"), 1)
        await assertInsufficient { try await h.loader.load(h.spec("B", 31 * gib), pinned: false) }
        XCTAssertEqual(h.state, ["P:warm", "A:warm"])
        XCTAssertEqual(h.budget.busyRows(memberID: h.memberID("A")), 1)
        h.budget.setInFlightRows(memberID: h.memberID("A"), 0)
        XCTAssertEqual(h.budget.busyRows(memberID: h.memberID("A")), 0)
    }

    func testPinnedMemberRowsAreReserved() async throws {
        let perToken = 1024 * 1024
        let reservation = WarmModelRowReservation(rows: 4, tokensPerRow: 4096)
        let reserved = 4 * 4096 * perToken
        let limit = 100 * gib + 2 * margin
        // Without the reservation a 55 GiB load fits beside one 4 GiB minimum row.
        let unreserved = Harness(limitBytes: limit)
        _ = try await unreserved.adoptPrimary("P", bytes: 40 * gib, perToken: perToken)
        XCTAssertEqual(unreserved.budget.member(1)?.reservedRowKVBytes, 0)
        try await unreserved.loader.load(unreserved.spec("A", 55 * gib), pinned: false)

        let h = Harness(limitBytes: limit)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib, perToken: perToken, reservation: reservation)
        XCTAssertEqual(h.budget.member(1)?.reservedRowKVBytes, reserved)
        await assertInsufficient { try await h.loader.load(h.spec("A", 55 * gib), pinned: false) }
        XCTAssertEqual(h.state, ["P:warm"])
        try await h.loader.load(h.spec("A", 100 * gib - 40 * gib - reserved), pinned: false)
        XCTAssertEqual(h.state, ["P:warm", "A:warm"])
    }

    func testFailedLoadLeavesTableAndBudgetAsBefore() async throws {
        let h = Harness(limitBytes: 100 * gib + 3 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        let primaryBefore = h.budget.member(1)
        h.failNext = true
        do {
            _ = try await h.loader.load(h.spec("A", 30 * gib), pinned: false)
            XCTFail("failed factory reported success")
        } catch {
            XCTAssertTrue(error is FactoryFailure)
        }
        XCTAssertEqual(h.state, ["P:warm"])
        XCTAssertNil(h.table.entry(modelID: "A"))
        XCTAssertEqual(h.budget.pendingLoadBytes, 0)
        XCTAssertEqual(h.budget.member(1), primaryBefore)
        XCTAssertNil(h.budget.member(h.nextMemberID))
        try await h.loader.load(h.spec("A", 30 * gib), pinned: false)
        XCTAssertEqual(h.state, ["P:warm", "A:warm"])
    }

    func testLoadingModelIsChargedUntilItRegisters() async throws {
        let h = Harness(limitBytes: 100 * gib + 3 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        let reservation = h.budget.reserveLoad(estimatedResidentBytes: 30 * gib)
        XCTAssertEqual(h.budget.pendingLoadBytes, 30 * gib + margin)
        XCTAssertEqual(h.budget.canLoad(estimatedResidentBytes: 31 * gib, limitBytes: 100 * gib + 3 * margin).reason,
                       "insufficient_memory")
        h.budget.releaseLoad(reservation)
        XCTAssertEqual(h.budget.canLoad(estimatedResidentBytes: 31 * gib, limitBytes: 100 * gib + 3 * margin).reason, "fits")
    }

    func testEvictionIsLeastRecentlyUsedFirst() async throws {
        let h = Harness(limitBytes: 100 * gib + 4 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        for id in ["A", "B", "C"] { try await h.loader.load(h.spec(id, 20 * gib), pinned: false) }
        // Row admissions stamp recency: C oldest, then A, then B.
        for id in ["C", "A", "B"] {
            h.budget.releaseSerialRow(h.budget.chargeSerialRow(memberID: h.memberID(id), tokens: 0, limitBytes: nil))
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await h.loader.load(h.spec("D", 40 * gib), pinned: false)
        XCTAssertEqual(h.log.all.suffix(3), ["unload C", "unload A", "load D"])
        XCTAssertEqual(h.state, ["P:warm", "B:warm", "D:warm"])
    }

    // MARK: Evict and unload

    func testEvictingMemberRefusesLeasesAndUnloadsOnceIdle() async throws {
        let h = Harness(limitBytes: 100 * gib + 3 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        try await h.loader.load(h.spec("A", 30 * gib), pinned: false)
        let memberID = h.memberID("A")
        h.budget.setInFlightRows(memberID: memberID, 1)
        let eviction = Task { try await h.loader.evict("A") }
        while h.table.entry(modelID: "A")?.state != .evicting { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertThrowsError(try h.table.lease(servedModelID: "A")) { error in
            XCTAssertEqual((error as? WarmModelTableError)?.reason, "model_not_loaded")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(h.log.all.contains("unload A"), "a member with an in-flight row is not unloaded")
        h.budget.setInFlightRows(memberID: memberID, 0)
        try await eviction.value
        XCTAssertEqual(h.state, ["P:warm"])
        XCTAssertNil(h.budget.member(memberID))
    }

    func testCancelledEvictionReturnsMemberToWarm() async throws {
        let h = Harness(limitBytes: 100 * gib + 3 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        try await h.loader.load(h.spec("A", 30 * gib), pinned: false)
        h.budget.setInFlightRows(memberID: h.memberID("A"), 1)
        let eviction = Task { try await h.loader.evict("A") }
        while h.table.entry(modelID: "A")?.state != .evicting { try await Task.sleep(nanoseconds: 1_000_000) }
        eviction.cancel()
        do {
            try await eviction.value
            XCTFail("cancelled eviction completed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(h.state, ["P:warm", "A:warm"])
        XCTAssertNotNil(try h.table.lease(servedModelID: "A"))
    }

    func testEvictAndUnloadRules() async throws {
        let h = Harness(limitBytes: 100 * gib + 3 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        try await h.loader.load(h.spec("Pinned", 30 * gib), pinned: true)
        func reason(_ body: () async throws -> Void) async -> String? {
            do { try await body(); return nil } catch { return (error as? WarmModelTableError)?.reason }
        }
        let primaryReason = await reason { try await h.loader.unload("P") }
        XCTAssertEqual(primaryReason, "primary")
        let pinnedReason = await reason { try await h.loader.evict("pinned") }
        XCTAssertEqual(pinnedReason, "pinned")
        let absentReason = await reason { try await h.loader.unload("absent") }
        XCTAssertEqual(absentReason, "model_not_loaded")
        try await h.loader.unload("pinned")
        XCTAssertEqual(h.state, ["P:warm"])
        XCTAssertEqual(h.log.all, ["load Pinned", "unload Pinned"])
    }

    func testOneOperationAtATime() async throws {
        let h = Harness(limitBytes: 100 * gib + 3 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        let order = LoaderLog()
        let first = Task {
            try await h.loader.exclusive {
                order.append("first start")
                try await Task.sleep(nanoseconds: 20_000_000)
                order.append("first end")
            }
        }
        while order.all.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        try await h.loader.load(h.spec("A", 10 * gib), pinned: false)
        order.append("load done")
        try await first.value
        XCTAssertEqual(order.all, ["first start", "first end", "load done"])
    }

    // MARK: ModelRuntime

    /// SPEC-011 R-3.10.3: a promotion loads nothing; the budget's pins
    /// follow the table, so the old primary becomes evictable and the new
    /// one keeps its rows reserved.
    func testPromotionLoadsNothingAndMovesThePins() async throws {
        let h = Harness(limitBytes: 100 * gib + 3 * margin)
        _ = try await h.adoptPrimary("P", bytes: 40 * gib)
        try await h.loader.load(h.spec("A", 30 * gib), pinned: false)
        let promoted = try await h.loader.exclusive { try await h.loader.promoteInTurn("a") }
        XCTAssertEqual(promoted.new.modelID, "A")
        XCTAssertEqual(h.log.all, ["load A"], "no load and no unload")
        XCTAssertEqual(h.budget.member(1)?.pinned, false)
        XCTAssertEqual(h.budget.member(h.memberID("A"))?.pinned, true)
        XCTAssertEqual(h.state, ["A:warm", "P:warm"])

        // The old primary is now the idle unpinned member a load evicts.
        try await h.loader.load(h.spec("B", 31 * gib), pinned: false)
        XCTAssertEqual(h.state, ["A:warm", "B:warm"])
        XCTAssertEqual(h.log.all, ["load A", "unload P", "load B"])
    }

    func testModelRuntimeUnloadForWarmSetReleasesArbiterAndBudgetMember() async throws {
        let status = ProviderStatus(
            modelID: "fixture-model", modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1), modelHash: "fixture-hash")
        let runtime = ModelRuntime(
            modelID: "fixture-model", modelHash: "fixture-hash", warmSwapEnabled: false, providerStatus: status,
            loader: { _ in throw FactoryFailure() })
        let memberID = runtime.memoryBudgetMemberID
        _ = SharedModelMemoryBudget.shared.recordLoaded(
            memberID: memberID, label: "fixture-model", modelFamily: "fixture", wires: false, activeBytes: gib,
            weightBytes: nil, kvBytesPerToken: 0, pinned: false)
        XCTAssertTrue(GPUTurnArbiter.shared.isRegistered(runtime.gpuTurnParticipant))
        XCTAssertNotNil(SharedModelMemoryBudget.shared.member(memberID))
        let statusBefore = await status.snapshot()

        await runtime.unloadForWarmSet()

        XCTAssertFalse(GPUTurnArbiter.shared.isRegistered(runtime.gpuTurnParticipant))
        XCTAssertNil(SharedModelMemoryBudget.shared.member(memberID))
        let isLoaded = await runtime.isLoaded
        XCTAssertFalse(isLoaded)
        let statusAfter = await status.snapshot()
        XCTAssertEqual(statusAfter.modelLoaded, statusBefore.modelLoaded, "the provider status describes the primary")
        XCTAssertEqual(statusAfter.status, statusBefore.status)
    }
}
