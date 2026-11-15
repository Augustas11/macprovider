import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-001-R019: each warm member's continuous-batching self-check and
/// admission are its own, and another member's load, eviction, promotion or
/// swap never touches them. Fixture runtimes: no model is loaded.
final class WarmMemberPolicyTests: XCTestCase {
    private static let hashA = String(repeating: "a", count: 64)
    private static let hashB = String(repeating: "b", count: 64)
    private static let hashC = String(repeating: "c", count: 64)

    private struct UnexpectedLoad: Error {}

    private static func fixture(_ modelID: String, hash: String, warmSwapEnabled: Bool = false) -> ModelRuntime {
        ModelRuntime(
            modelID: modelID, modelHash: hash, maxBatch: 4, warmSwapEnabled: warmSwapEnabled,
            loader: { _ in throw UnexpectedLoad() },
            testLoader: { target in (target, Self.hashC) })
    }

    /// Records which member's background work was stopped, as `serve` wires it.
    private final class Harness: @unchecked Sendable {
        let table = WarmModelTable<ModelRuntime>()
        let services = WarmSetMemberServices()
        let gate = AsyncGate()
        private let lock = NSLock()
        private var gatedModels: Set<String> = []
        var loader: WarmModelLoader<ModelRuntime>!
        var boot: WarmSetBoot<ModelRuntime>!
        var stopped: [Int] = []

        var gated: Set<String> {
            get { lock.lock(); defer { lock.unlock() }; return gatedModels }
            set { lock.lock(); gatedModels = newValue; lock.unlock() }
        }

        init() {
            let hashes = ["model-b": WarmMemberPolicyTests.hashB, "model-c": WarmMemberPolicyTests.hashC]
            loader = WarmModelLoader(
                table: table, budget: SharedModelMemoryBudget(), limitBytes: { Int.max / 4 }, idlePollNanoseconds: 1_000_000,
                factory: { [unowned self] spec in
                    if self.gated.contains(spec.modelID) { await self.gate.wait() }
                    return WarmMemberPolicyTests.fixture(spec.modelID, hash: hashes[spec.modelID] ?? WarmMemberPolicyTests.hashC)
                },
                beforeUnload: { [unowned self] runtime in
                    self.record(runtime.memoryBudgetMemberID)
                    await self.services.stop(memberID: runtime.memoryBudgetMemberID)
                })
            boot = WarmSetBoot(
                table: table, loader: loader, supportedModels: ["model-a", "model-b", "model-c"],
                loadSpec: { WarmModelLoadSpec(modelID: $0, estimatedResidentBytes: 1, minimumRowKVBytes: 0) },
                memberInfo: { runtime in
                    let rows = await runtime.warmSetRowReservation()
                    let snapshot = await runtime.currentSnapshot()
                    return WarmModelMemberInfo(
                        maxContextTokens: rows.tokensPerRow, slotsTotal: rows.rows,
                        modelHash: await runtime.loadedModelHash,
                        cbSelfCheck: snapshot.continuousBatching?.selfCheck,
                        engine: WarmModelEngineState(snapshot: snapshot))
                },
                log: { _ in })
            services.gate = boot
        }

        private func record(_ memberID: Int) {
            lock.lock(); stopped.append(memberID); lock.unlock()
        }

        var stoppedMembers: [Int] { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    /// Opens once; every waiter before and after proceeds.
    private actor AsyncGate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    /// A stand-in for a member's self-check: runs until cancelled.
    private final class Worker: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelledFlag = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }
        func task() -> Task<Void, Never> {
            Task {
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
                self.lock.lock(); self.cancelledFlag = true; self.lock.unlock()
            }
        }
    }

    private struct MemberState: Equatable {
        let selfCheck: ContinuousBatchingSelfCheckState
        let continuousBatching: RuntimeContinuousBatchingSnapshot?
        let servedSlots: Int
        let modelHash: String?
    }

    private func state(_ runtime: ModelRuntime) async -> MemberState {
        let snapshot = await runtime.currentSnapshot()
        return MemberState(
            selfCheck: await runtime.continuousBatchingSelfCheckState(),
            continuousBatching: snapshot.continuousBatching,
            servedSlots: await runtime.servedSlotLimitForTest(),
            modelHash: snapshot.modelHash)
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not reached")
    }

    // MARK: R019 invariant

    func testAnotherMembersLoadEvictionAndPromotionLeaveAMembersSelfCheckAndAdmissionAlone() async throws {
        let h = Harness()
        let primary = Self.fixture("model-a", hash: Self.hashA)
        try await h.boot.adoptPrimary(modelID: "model-a", runtime: primary)
        let loadedB = await h.boot.load("model-b")
        XCTAssertEqual(loadedB, .loaded)
        let memberB = try XCTUnwrap(h.table.entry(modelID: "model-b")?.runtime)
        let keyB = ContinuousBatchingSelfCheckKey(
            modelSHA256: Self.hashB, metallibSHA256: "m", kernelIdentifier: "k", hardwareClass: "h",
            osBuild: "o", runtimeBuild: "r", decodeWindow: 1)
        let report = ContinuousBatchingSelfCheckReport(decision: "granted", servedSlots: 2, verifiedSlots: 2, key: keyB)
        let applied = await memberB.applyContinuousBatchingSelfCheck(.granted(slots: 2), servedSlots: 2, report: report)
        XCTAssertTrue(applied)
        let workerB = Worker()
        h.services.add(memberID: memberB.memoryBudgetMemberID, workerB.task())
        let before = await state(memberB)
        XCTAssertEqual(before.selfCheck, .granted(slots: 2))
        XCTAssertEqual(before.servedSlots, 2)

        // Another member loads and is evicted.
        let loadedC = await h.boot.load("model-c")
        XCTAssertEqual(loadedC, .loaded)
        let memberC = try XCTUnwrap(h.table.entry(modelID: "model-c")?.runtime)
        let workerC = Worker()
        h.services.add(memberID: memberC.memoryBudgetMemberID, workerC.task())
        let afterLoad = await state(memberB)
        XCTAssertEqual(afterLoad, before)
        try await h.loader.evict("model-c")
        await eventually { workerC.cancelled }
        XCTAssertEqual(h.stoppedMembers, [memberC.memoryBudgetMemberID], "only the evicted member's work stops")
        let afterEvict = await state(memberB)
        XCTAssertEqual(afterEvict, before)

        // The member is promoted, then the old primary is evicted.
        await h.boot.runSwapTurn { try? await h.boot.promoteInSwapTurn("model-b") }
        XCTAssertTrue(h.table.primaryRuntime() === memberB)
        let afterPromotion = await state(memberB)
        XCTAssertEqual(afterPromotion, before, "the promoted primary keeps its own admission and self-check")
        try await h.loader.evict("model-a")
        XCTAssertEqual(h.stoppedMembers, [memberC.memoryBudgetMemberID, primary.memoryBudgetMemberID])
        let afterOldPrimaryEvicted = await state(memberB)
        XCTAssertEqual(afterOldPrimaryEvicted, before)
        XCTAssertFalse(workerB.cancelled, "another member's load, eviction or promotion never stops a member's self-check")
        XCTAssertEqual(h.services.memberIDs(), [memberB.memoryBudgetMemberID])
        await h.services.stop(memberID: memberB.memoryBudgetMemberID)
        XCTAssertTrue(workerB.cancelled)
    }

    func testOnlyTheUnloadedMembersOwnWorkStopsBeforeItsRuntimeUnloads() async throws {
        let h = Harness()
        try await h.boot.adoptPrimary(modelID: "model-a", runtime: Self.fixture("model-a", hash: Self.hashA))
        _ = await h.boot.load("model-b")
        _ = await h.boot.load("model-c")
        let memberB = try XCTUnwrap(h.table.entry(modelID: "model-b")?.runtime)
        let memberC = try XCTUnwrap(h.table.entry(modelID: "model-c")?.runtime)
        let workerB = Worker()
        let workerC = Worker()
        h.services.add(memberID: memberB.memoryBudgetMemberID, workerB.task())
        h.services.add(memberID: memberC.memoryBudgetMemberID, workerC.task())

        let outcome = await h.boot.unload("model-b")
        XCTAssertEqual(outcome, .unloaded)
        XCTAssertTrue(workerB.cancelled, "stopped and awaited before the runtime unloaded")
        XCTAssertFalse(workerC.cancelled)
        XCTAssertEqual(h.stoppedMembers, [memberB.memoryBudgetMemberID])
        XCTAssertEqual(h.services.memberIDs(), [memberC.memoryBudgetMemberID])
        await h.services.stop(memberID: memberC.memoryBudgetMemberID)
    }

    /// A member's check starts only while it is warm and no load, eviction
    /// or swap runs; a load never waits for a check.
    func testAMembersSelfCheckWaitsWhileAnotherMemberLoads() async throws {
        let h = Harness()
        try await h.boot.adoptPrimary(modelID: "model-a", runtime: Self.fixture("model-a", hash: Self.hashA))
        _ = await h.boot.load("model-b")
        let memberB = try XCTUnwrap(h.table.entry(modelID: "model-b")?.runtime).memoryBudgetMemberID
        let idle = await h.services.stepAllowed(memberID: memberB)
        XCTAssertTrue(idle)

        h.gated = ["model-c"]
        let load = Task { await h.boot.load("model-c") }
        await eventually { h.table.entry(modelID: "model-c")?.state == .loading }
        let duringLoad = await h.services.stepAllowed(memberID: memberB)
        XCTAssertFalse(duringLoad)
        await h.gate.release()
        let loaded = await load.value
        XCTAssertEqual(loaded, .loaded)
        let afterLoad = await h.services.stepAllowed(memberID: memberB)
        XCTAssertTrue(afterLoad)

        // During a swap turn, and for a member that is not warm.
        let inTurn = await h.loader.exclusive { await h.services.stepAllowed(memberID: memberB) }
        XCTAssertFalse(inTurn)
        let unknown = await h.services.stepAllowed(memberID: -1)
        XCTAssertFalse(unknown)
        let detached = await WarmSetMemberServices().stepAllowed(memberID: memberB)
        XCTAssertFalse(detached, "no member work acts before the warm set exists")
    }

    func testAMembersWireEntryCarriesItsOwnSelfCheckAndEngine() async throws {
        let h = Harness()
        try await h.boot.adoptPrimary(modelID: "model-a", runtime: Self.fixture("model-a", hash: Self.hashA))
        _ = await h.boot.load("model-b")
        let memberB = try XCTUnwrap(h.table.entry(modelID: "model-b")?.runtime)
        let report = ContinuousBatchingSelfCheckReport(decision: "deferred", servedSlots: 1, verifiedSlots: 1, key: nil)
        await memberB.setContinuousBatchingSelfCheckReport(report)
        await h.services.published(memberID: memberB.memoryBudgetMemberID)

        let views = h.table.views.value
        XCTAssertEqual(views.last?.info?.cbSelfCheck, report)
        let entries = WarmModelsWire.entries(
            primaryFields: [
                "model_id": "model-a",
                "cb_self_check": ["decision": "granted"],
                "engine_profile": ["chip_class": "m5_max", "ram_class_gb": 128, "engine_family": "native_mtp"],
            ],
            primarySlotsTotal: 4, primarySlotsFree: 4, views: views)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual((entries[0]["cb_self_check"] as? [String: String])?["decision"], "granted", "top-level is the primary's")
        let member = entries[1]
        XCTAssertEqual((member["cb_self_check"] as? [String: Any])?["decision"] as? String, "deferred")
        let profile = try XCTUnwrap(member["engine_profile"] as? [String: Any])
        XCTAssertEqual(profile["chip_class"] as? String, "m5_max")
        XCTAssertEqual(profile["ram_class_gb"] as? Int, 128)
        XCTAssertEqual(profile["engine_family"] as? String, "general_mlx", "the member's own engine, not the primary's")
        XCTAssertEqual(profile["native_mtp_active"] as? Bool, false)
        XCTAssertEqual(profile["max_stable_context_tokens"] as? Int, views.last?.info?.maxContextTokens)

        // Without a primary engine profile no member profile is sent.
        let bare = WarmModelsWire.entries(
            primaryFields: ["model_id": "model-a"], primarySlotsTotal: 4, primarySlotsFree: 4, views: views)
        XCTAssertNil(bare[1]["engine_profile"])
    }

    func testAPrimaryNeverPublishesIntoTheMemberInfo() async throws {
        let h = Harness()
        let primary = Self.fixture("model-a", hash: Self.hashA)
        try await h.boot.adoptPrimary(modelID: "model-a", runtime: primary)
        await h.services.published(memberID: primary.memoryBudgetMemberID)
        XCTAssertNil(h.table.views.value.first?.info, "the primary's values are the top-level fields")
    }

    // MARK: Served slots, as for a single-model provider of the member's model

    func testAMembersServedSlotsAreSetUpLikeTheBootModels() async throws {
        let store = ContinuousBatchingSelfCheckStore(
            configPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("warm-member-policy-\(UUID().uuidString)").appendingPathComponent("config.yaml").path)
        let plan = AutoServedSlots.Plan(rows: 4, initialServed: 3, ownerPinned: nil, reason: "self_check_pending")
        var made = 0
        let runtime = Self.fixture("model-b", hash: Self.hashB)
        let driver = await WarmSetMemberServices.configureMemberSelfCheck(
            runtime: runtime, plan: plan, serialOnlyRoute: false, store: store, provisional: nil,
            makeDriver: { _ in
                made += 1
                return ContinuousBatchingSelfCheckDriver(
                    runtime: runtime, providerStatus: ProviderStatus(modelID: "model-a", modelLoaded: true, capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1)),
                    store: store, ownerPinnedSlots: nil, log: { _ in })
            },
            log: { _ in })
        XCTAssertNotNil(driver)
        XCTAssertEqual(made, 1)
        // A tuple that cannot batch serves one slot, as the boot model would.
        let served = await runtime.servedSlotLimitForTest()
        XCTAssertEqual(served, 1)

        for (plan, serialOnly) in [
            (nil, false),
            (plan, true),
            (AutoServedSlots.Plan(rows: 4, initialServed: 1, ownerPinned: nil, reason: "emergency_off"), false),
        ] as [(AutoServedSlots.Plan?, Bool)] {
            let other = Self.fixture("model-c", hash: Self.hashC)
            let none = await WarmSetMemberServices.configureMemberSelfCheck(
                runtime: other, plan: plan, serialOnlyRoute: serialOnly, store: store, provisional: nil,
                makeDriver: { _ in XCTFail("no driver expected"); return driver! }, log: { _ in })
            XCTAssertNil(none)
        }
    }

    // MARK: One check at a time

    func testSelfCheckTurnIsExclusiveFIFOAndACancelledWaiterLeaves() async throws {
        let turn = ContinuousBatchingSelfCheckTurn()
        let first = await turn.acquire()
        XCTAssertTrue(first)
        let order = OrderLog()
        let second = Task { if await turn.acquire() { order.append("second") } }
        await eventually { await turn.waiterCount == 1 }
        let cancelled = Task { await turn.acquire() }
        await eventually { await turn.waiterCount == 2 }
        let third = Task { if await turn.acquire() { order.append("third") } }
        await eventually { await turn.waiterCount == 3 }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult)
        let waiting = await turn.waiterCount
        XCTAssertEqual(waiting, 2, "the cancelled waiter left the queue")
        XCTAssertEqual(order.all, [])
        await turn.release()
        await second.value
        XCTAssertEqual(order.all, ["second"])
        await turn.release()
        await third.value
        XCTAssertEqual(order.all, ["second", "third"])
        await turn.release()
        let held = await turn.isHeld
        XCTAssertFalse(held)
    }

    private final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }
}
