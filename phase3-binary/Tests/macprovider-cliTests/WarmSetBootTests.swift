import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

private final class BootLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
    func contains(_ fragment: String) -> Bool { all.contains { $0.contains(fragment) } }
}

/// Holds a load until the test opens it.
private actor LoadGate {
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

private final class BootFakeRuntime: WarmModelRuntime, @unchecked Sendable {
    let memoryBudgetMemberID: Int
    let modelID: String
    private let budget: SharedModelMemoryBudget
    private let log: BootLog

    init(memberID: Int, modelID: String, budget: SharedModelMemoryBudget, log: BootLog) {
        self.memoryBudgetMemberID = memberID
        self.modelID = modelID
        self.budget = budget
        self.log = log
    }

    func warmSetRowReservation() async -> WarmModelRowReservation { .init(rows: 2, tokensPerRow: 8_192) }

    func unloadForWarmSet() async {
        log.append("unload \(modelID)")
        budget.forget(memberID: memoryBudgetMemberID)
    }
}

private struct BootFactoryFailure: Error {}
private struct BootUnexpectedContainerLoad: Error {}

/// SPEC-001-R016/R017 serve wiring through `WarmSetBoot`, with fake runtimes
/// and fixture `ModelRuntime`s on private budgets: no model is loaded.
final class WarmSetBootTests: XCTestCase {
    private let gib = 1024 * 1024 * 1024
    private let margin = SharedModelMemoryRules.perMemberMarginBytes

    private final class Harness: @unchecked Sendable {
        let budget = SharedModelMemoryBudget()
        let table = WarmModelTable<BootFakeRuntime>()
        let log = BootLog()
        let gate = LoadGate()
        let lock = NSLock()
        var nextMemberID = 12_000
        var failing: Set<String> = []
        var gated: Set<String> = []
        var factoryCalls: [String] = []
        let sizes: [String: Int]
        var families: [String: String] = [:]
        var loader: WarmModelLoader<BootFakeRuntime>!
        var boot: WarmSetBoot<BootFakeRuntime>!

        init(limitBytes: Int, sizes: [String: Int], supported: [String]?) {
            self.sizes = sizes
            loader = WarmModelLoader(
                table: table, budget: budget, limitBytes: { limitBytes }, idlePollNanoseconds: 1_000_000
            ) { [unowned self] spec in try await self.make(spec) }
            boot = WarmSetBoot(
                table: table, loader: loader, supportedModels: supported,
                loadSpec: { [unowned self] modelID in
                    guard let bytes = self.sizes[modelID] else { throw BootFactoryFailure() }
                    return WarmModelLoadSpec(
                        modelID: modelID, estimatedResidentBytes: bytes, minimumRowKVBytes: 0,
                        modelFamily: self.families[modelID])
                },
                memberInfo: { runtime in
                    let rows = await runtime.warmSetRowReservation()
                    return WarmModelMemberInfo(maxContextTokens: rows.tokensPerRow, slotsTotal: rows.rows)
                },
                log: { [log] line in log.append(line) }
            )
        }

        func make(_ spec: WarmModelLoadSpec) async throws -> BootFakeRuntime {
            lock.lock()
            factoryCalls.append(spec.modelID)
            let fail = failing.contains(spec.modelID)
            let wait = gated.contains(spec.modelID)
            nextMemberID += 1
            let id = nextMemberID
            lock.unlock()
            if wait { await gate.wait() }
            if fail { throw BootFactoryFailure() }
            _ = budget.recordLoaded(
                memberID: id, label: spec.modelID, modelFamily: "fake", wires: false,
                activeBytes: spec.estimatedResidentBytes, weightBytes: spec.estimatedResidentBytes,
                kvBytesPerToken: 0, pinned: true)
            log.append("load \(spec.modelID)")
            return BootFakeRuntime(memberID: id, modelID: spec.modelID, budget: budget, log: log)
        }

        func adoptPrimary(_ modelID: String, bytes: Int) async throws {
            _ = budget.recordLoaded(
                memberID: 1, label: modelID, modelFamily: "fake", wires: false, activeBytes: bytes,
                weightBytes: bytes, kvBytesPerToken: 0, pinned: true)
            try await boot.adoptPrimary(
                modelID: modelID, runtime: BootFakeRuntime(memberID: 1, modelID: modelID, budget: budget, log: log))
        }

        var state: [String] { table.entries().map { "\($0.modelID):\($0.state.rawValue)" } }
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return factoryCalls }
    }

    private func eventually(
        timeoutSeconds: Double = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not reached within \(timeoutSeconds) s", file: file, line: line)
    }

    // MARK: Boot loads

    func testBootLoadsInListOrderPinnedAndPublishesEachMember() async throws {
        let h = Harness(limitBytes: 200 * gib, sizes: ["A": 10 * gib, "B": 10 * gib, "C": 10 * gib], supported: ["P", "A", "B", "C"])
        try await h.adoptPrimary("P", bytes: 40 * gib)
        let outcomes = await h.boot.bootLoad(["A", "B", "C"])
        XCTAssertEqual(outcomes, [.loaded, .loaded, .loaded])
        XCTAssertEqual(h.state, ["P:warm", "A:warm", "B:warm", "C:warm"])
        XCTAssertEqual(h.calls, ["A", "B", "C"])
        XCTAssertTrue(h.table.entries().allSatisfy(\.pinned), "boot warm models are pinned")
        let views = h.table.views.value
        XCTAssertEqual(views.map(\.modelID), ["P", "A", "B", "C"])
        XCTAssertEqual(views.dropFirst().map { $0.info?.slotsTotal }, [2, 2, 2])
        XCTAssertEqual(views.dropFirst().map { $0.info?.maxContextTokens }, [8_192, 8_192, 8_192])
        let lines = h.log.all.filter { $0.hasPrefix("event=warm_model_load") }
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("action=loaded model=A outcome=loaded pinned=true source=boot"), lines[0])
        XCTAssertTrue(lines[2].contains("model=C"), lines[2])
    }

    func testStartBootLoadsRunsInTheBackground() async throws {
        let h = Harness(limitBytes: 200 * gib, sizes: ["A": gib], supported: ["P", "A"])
        try await h.adoptPrimary("P", bytes: gib)
        h.boot.startBootLoads(["A"])
        await eventually { h.table.entry(modelID: "A")?.state == .warm }
    }

    func testRefusalsAndFailuresAreLoggedAndLaterEntriesStillLoad() async throws {
        let h = Harness(
            limitBytes: 60 * gib + 4 * margin,
            sizes: ["Big": 50 * gib, "Broken": gib, "C": 5 * gib, "D": 5 * gib],
            supported: ["P", "Big", "Broken", "Missing", "C", "D"])
        h.failing = ["Broken"]
        try await h.adoptPrimary("P", bytes: 40 * gib)
        let outcomes = await h.boot.bootLoad(["Big", "Broken", "Missing", "Unlisted", "C", "C", "D"])
        XCTAssertEqual(outcomes.map(\.code), [
            "insufficient_memory", "load_failed", "unsupported_model", "unsupported_model", "loaded", "already_warm", "loaded",
        ])
        XCTAssertEqual(h.state, ["P:warm", "C:warm", "D:warm"])
        XCTAssertEqual(h.calls, ["Broken", "C", "D"], "a refused load never reaches the factory")
        XCTAssertTrue(h.log.contains("event=warm_model_load action=refused model=Big outcome=insufficient_memory"))
        XCTAssertTrue(h.log.contains("model=Broken outcome=load_failed"))
        XCTAssertTrue(h.log.contains("model=Missing outcome=unsupported_model pinned=true source=boot detail=model_unavailable"))
        XCTAssertTrue(h.log.contains("model=Unlisted outcome=unsupported_model pinned=true source=boot detail=not_in_supported_models"))
        XCTAssertFalse(h.log.all.contains { $0.contains("\n") })
        XCTAssertEqual(h.budget.pendingLoadBytes, 0)
    }

    func testWithoutSupportedModelsOnlyThePrimaryIsSupported() async throws {
        let h = Harness(limitBytes: 200 * gib, sizes: ["A": gib], supported: nil)
        try await h.adoptPrimary("P", bytes: gib)
        let outcome = await h.boot.load("A")
        XCTAssertEqual(outcome.code, "unsupported_model")
        let primary = await h.boot.load("p")
        XCTAssertEqual(primary, .alreadyWarm)
    }

    // MARK: Control socket

    private func warmSet(_ h: Harness, _ action: String, _ modelID: String? = nil) async -> WarmSetControlReply {
        await ControlSocketServer.handleWarmSetRequest(action: action, modelID: modelID, warmSet: h.boot)
    }

    func testControlLoadReportsEveryOutcomeAndStatusListsLeasesAndPinning() async throws {
        let h = Harness(
            limitBytes: 60 * gib + 4 * margin,
            sizes: ["A": 5 * gib, "Big": 50 * gib, "Broken": gib],
            supported: ["P", "A", "Big", "Broken"])
        h.failing = ["Broken"]
        try await h.adoptPrimary("P", bytes: 40 * gib)

        let loaded = await warmSet(h, "load", "A")
        XCTAssertEqual(loaded.status, "loaded")
        XCTAssertNil(loaded.detail)
        XCTAssertEqual(loaded.entries.map(\.modelID), ["P", "A"])
        let again = await warmSet(h, "load", "a")
        XCTAssertEqual(again.status, "already_warm")
        let big = await warmSet(h, "load", "Big")
        XCTAssertEqual(big.status, "insufficient_memory")
        XCTAssertNotNil(big.detail)
        let unlisted = await warmSet(h, "load", "Unlisted")
        XCTAssertEqual(unlisted.status, "unsupported_model")
        XCTAssertEqual(unlisted.detail, "not_in_supported_models")
        let broken = await warmSet(h, "load", "Broken")
        XCTAssertEqual(broken.status, "load_failed")
        XCTAssertTrue(h.log.contains("model=A outcome=loaded pinned=false source=request"))

        let lease = try h.table.lease(servedModelID: "A")
        let status = await warmSet(h, "status")
        lease.release()
        XCTAssertEqual(status.status, "ok")
        XCTAssertEqual(status.entries, [
            WarmSetControlEntry(
                modelID: "P", state: "warm", primary: true, pinned: true, leases: 0, slotsTotal: 2, slotsFree: 2,
                maxContextTokens: 8_192, throughputTPSEstimate: 0),
            WarmSetControlEntry(
                modelID: "A", state: "warm", primary: false, pinned: false, leases: 1, slotsTotal: 2, slotsFree: 1,
                maxContextTokens: 8_192, throughputTPSEstimate: 0),
        ])
    }

    func testControlUnloadRefusesThePrimaryAndABusyMember() async throws {
        let h = Harness(limitBytes: 200 * gib, sizes: ["A": gib], supported: ["P", "A"])
        try await h.adoptPrimary("P", bytes: gib)
        _ = await warmSet(h, "load", "A")

        let lease = try h.table.lease(servedModelID: "A")
        let busy = await warmSet(h, "unload", "A")
        XCTAssertEqual(busy.status, "busy")
        XCTAssertEqual(h.table.entry(modelID: "A")?.state, .warm)
        lease.release()

        let primary = await warmSet(h, "unload", "P")
        XCTAssertEqual(primary.status, "primary")
        XCTAssertEqual(h.table.entry(modelID: "P")?.state, .warm)

        let unloaded = await warmSet(h, "unload", "A")
        XCTAssertEqual(unloaded.status, "unloaded")
        XCTAssertEqual(unloaded.entries.map(\.modelID), ["P"])
        XCTAssertTrue(h.log.contains("unload A"))
        let absent = await warmSet(h, "unload", "A")
        XCTAssertEqual(absent.status, "not_loaded")
    }

    func testControlRefusesMalformedRequestsAndAnswersWithoutAWarmSet() async throws {
        let h = Harness(limitBytes: 200 * gib, sizes: [:], supported: ["P"])
        try await h.adoptPrimary("P", bytes: gib)
        let noModel = await warmSet(h, "load", "  ")
        XCTAssertEqual(noModel.status, "invalid_request")
        XCTAssertEqual(noModel.detail, "model_id_required")
        let unknown = await warmSet(h, "evict", "P")
        XCTAssertEqual(unknown.status, "invalid_request")
        XCTAssertEqual(unknown.detail, "unknown_action")
        let none = await ControlSocketServer.handleWarmSetRequest(action: "status", modelID: nil, warmSet: nil)
        XCTAssertEqual(none, WarmSetControlReply(action: "status", status: "unavailable", detail: "no_warm_set", entries: []))
    }

    // MARK: Configuration

    func testWarmModelsWithAnExternalPrimaryAreAConfigurationError() throws {
        XCTAssertThrowsError(try WarmSetBoot<BootFakeRuntime>.requireLocalPrimary(
            warmModels: ["other"], externalRuntime: "a shard group")) { error in
            XCTAssertEqual(error as? WarmSetConfigurationError, .externalPrimary(runtime: "a shard group"))
            XCTAssertTrue(String(describing: error).contains("warm_models needs --model to be a local MLX model"))
        }
        XCTAssertNoThrow(try WarmSetBoot<BootFakeRuntime>.requireLocalPrimary(warmModels: [], externalRuntime: "a shard group"))
        XCTAssertNoThrow(try WarmSetBoot<BootFakeRuntime>.requireLocalPrimary(warmModels: ["other"], externalRuntime: nil))

        var config = AppConfig.defaults()
        config.model = "primary-model"
        config.warmModels = ["other"]
        XCTAssertThrowsError(try ServeCommand.runWarmModelsRuntimePreflight(config, shardRole: true))
        XCTAssertNoThrow(try ServeCommand.runWarmModelsRuntimePreflight(config, shardRole: false))
        config.warmModels = []
        XCTAssertNoThrow(try ServeCommand.runWarmModelsRuntimePreflight(config, shardRole: true))
    }

    // MARK: Process-global memory state

    func testProcessLimitAndAdmissionSampleComeFromEveryLoadedMember() {
        var members: [Int: SharedModelMemoryMember] = [:]
        XCTAssertNil(SharedModelMemoryRules.processLimitResidentBytes(members: members))
        XCTAssertNil(SharedModelMemoryRules.soleLoadedKVBytesPerToken(members: members))

        var primary = SharedModelMemoryMember(label: "primary")
        primary.loaded = true
        primary.residentBytes = 40 * gib
        primary.kvBytesPerToken = 4_096
        members[1] = primary
        XCTAssertNil(SharedModelMemoryRules.processLimitResidentBytes(members: members),
                     "one model keeps the single-runtime limit (MLX's active memory)")
        XCTAssertEqual(SharedModelMemoryRules.soleLoadedKVBytesPerToken(members: members), 4_096)

        var loading = SharedModelMemoryMember(label: "registered, not loaded")
        loading.residentBytes = 99 * gib
        members[3] = loading
        XCTAssertNil(SharedModelMemoryRules.processLimitResidentBytes(members: members))

        var secondary = SharedModelMemoryMember(label: "secondary")
        secondary.loaded = true
        secondary.residentBytes = 20 * gib
        secondary.kvBytesPerToken = 512
        members[2] = secondary
        XCTAssertEqual(SharedModelMemoryRules.processLimitResidentBytes(members: members), 60 * gib + margin)
        XCTAssertNil(SharedModelMemoryRules.soleLoadedKVBytesPerToken(members: members),
                     "with two models each scheduler reads its own value")

        // A small Mac: the floor covers both members, not only the last load.
        let workingSet = 64 * gib
        let both = MLXMemoryBudget.limitBytes(
            recommendedWorkingSetBytes: workingSet, physicalMemoryBytes: UInt64(64 * gib),
            residentBytes: SharedModelMemoryRules.processLimitResidentBytes(members: members)!)
        let lastOnly = MLXMemoryBudget.limitBytes(
            recommendedWorkingSetBytes: workingSet, physicalMemoryBytes: UInt64(64 * gib), residentBytes: 20 * gib)
        XCTAssertEqual(both, 60 * gib + 2 * margin)
        XCTAssertLessThan(lastOnly!, both!)

        // The secondary leaves: the survivor's own KV figure, never the last load's.
        members.removeValue(forKey: 2)
        XCTAssertEqual(SharedModelMemoryRules.soleLoadedKVBytesPerToken(members: members), 4_096)
    }

    func testCommandBufferBudgetRule() {
        typealias Rules = SharedModelMemoryRules
        // A family that keeps MLX's default beside one that set 64 GiB buffers.
        XCTAssertTrue(Rules.commandBufferBudgetConflicts(
            family: "llama", wantedMB: nil, effective: ("glm5_next", 65_536), operatorMB: nil))
        // The device kept the default; a family that needs a budget cannot get it.
        XCTAssertTrue(Rules.commandBufferBudgetConflicts(
            family: "glm5_next", wantedMB: 65_536, effective: (nil, nil), operatorMB: nil))
        XCTAssertTrue(Rules.commandBufferBudgetConflicts(
            family: "glm5_next", wantedMB: 65_536, effective: nil, operatorMB: nil))
        // Same value, or the family that set it, or the operator's value: no conflict.
        XCTAssertFalse(Rules.commandBufferBudgetConflicts(
            family: "deepseek_v4", wantedMB: 65_536, effective: ("glm5_next", 65_536), operatorMB: nil))
        XCTAssertFalse(Rules.commandBufferBudgetConflicts(
            family: "glm5_next", wantedMB: 65_536, effective: ("glm5_next", 65_536), operatorMB: nil))
        XCTAssertFalse(Rules.commandBufferBudgetConflicts(
            family: "llama", wantedMB: nil, effective: ("environment", 1_024), operatorMB: 1_024))
        XCTAssertFalse(Rules.commandBufferBudgetConflicts(
            family: "llama", wantedMB: nil, effective: nil, operatorMB: 1_024))
        XCTAssertFalse(Rules.commandBufferBudgetConflicts(
            family: "llama", wantedMB: nil, effective: (nil, nil), operatorMB: nil))
    }

    func testCommandBufferBudgetConflictIsRefusedBeforeAnyEviction() async throws {
        let h = Harness(
            limitBytes: 60 * gib + 4 * margin, sizes: ["A": 15 * gib, "L": 15 * gib, "D": 5 * gib],
            supported: ["P", "A", "L", "D"])
        h.budget.recordCommandBufferBudget(modelFamily: "glm5_next", megabytes: 65_536)
        h.families = ["L": "llama", "D": "deepseek_v4"]
        try await h.adoptPrimary("P", bytes: 40 * gib)
        _ = await h.boot.load("A")
        let outcome = await h.boot.load("L")
        XCTAssertEqual(outcome.code, "unsupported_model")
        XCTAssertTrue(outcome.detail?.contains("command_buffer_budget_conflict") == true, "\(outcome)")
        XCTAssertTrue(outcome.detail?.contains("family=llama") == true, "\(outcome)")
        XCTAssertEqual(h.state, ["P:warm", "A:warm"], "the idle unpinned member was not evicted for a refused load")
        XCTAssertEqual(h.calls, ["A"])
        do {
            _ = try await h.loader.load(
                WarmModelLoadSpec(modelID: "L", estimatedResidentBytes: gib, minimumRowKVBytes: 0, modelFamily: "llama"),
                pinned: false)
            XCTFail("conflicting family loaded")
        } catch {
            XCTAssertEqual((error as? WarmModelLoaderError)?.reason, "command_buffer_budget_conflict")
        }
        let sameBudget = await h.boot.load("D")
        XCTAssertEqual(sameBudget, .loaded, "a family with the same budget loads")
    }

    // MARK: Shutdown

    func testShutdownWithALoadInFlightReturnsAndUnloadsTheSecondaries() async throws {
        let h = Harness(limitBytes: 200 * gib, sizes: ["A": gib, "B": gib, "C": gib], supported: ["P", "A", "B", "C"])
        h.gated = ["B"]
        try await h.adoptPrimary("P", bytes: gib)
        h.boot.startBootLoads(["A", "B", "C"])
        await eventually { h.table.entry(modelID: "B")?.state == .loading }

        let finished = BootLog()
        Task {
            await h.boot.shutdown(idleTimeoutSeconds: 1)
            finished.append("done")
        }
        await eventually { finished.contains("done") }
        XCTAssertTrue(h.log.contains("unload A"))
        XCTAssertNil(h.table.entry(modelID: "A"))
        XCTAssertEqual(h.table.entry(modelID: "P")?.state, .warm, "the primary is the caller's to tear down")

        // The load that was in flight finishes after shutdown: it is unloaded
        // again and never becomes a member; the boot list stops there.
        await h.gate.release()
        await eventually { h.log.contains("unload B") }
        await eventually { h.table.entry(modelID: "B") == nil }
        XCTAssertEqual(h.state, ["P:warm"])
        XCTAssertFalse(h.calls.contains("C"))
        let afterStop = await h.boot.load("C")
        XCTAssertEqual(afterStop, .loadFailed(detail: "stopping"))
    }

    func testShutdownLeavesAMemberThatStaysBusyPastTheIdleTimeout() async throws {
        let h = Harness(limitBytes: 200 * gib, sizes: ["A": gib], supported: ["P", "A"])
        try await h.adoptPrimary("P", bytes: gib)
        _ = await h.boot.load("A")
        let lease = try h.table.lease(servedModelID: "A")
        await h.boot.shutdown(idleTimeoutSeconds: 0)
        XCTAssertEqual(h.table.entry(modelID: "A")?.state, .warm)
        XCTAssertFalse(h.log.contains("unload A"))
        lease.release()
    }

    // MARK: ModelRuntime members

    private static func fixture(_ modelID: String, warmSwapEnabled: Bool = false, swapDrainTimeoutSeconds: Int = 30,
                         testLoader: (@Sendable (String) async throws -> (String, String?))? = nil) -> ModelRuntime {
        ModelRuntime(
            modelID: modelID, modelHash: String(repeating: "a", count: 64), warmSwapEnabled: warmSwapEnabled,
            swapDrainTimeoutSeconds: swapDrainTimeoutSeconds,
            loader: { _ in throw BootUnexpectedContainerLoad() },
            testLoader: testLoader ?? { target in (target, String(repeating: "c", count: 64)) })
    }

    private final class RuntimeHarness: @unchecked Sendable {
        let table = WarmModelTable<ModelRuntime>()
        let log = BootLog()
        let gate = LoadGate()
        var gated: Set<String> = []
        var loader: WarmModelLoader<ModelRuntime>!
        var boot: WarmSetBoot<ModelRuntime>!

        init(make: @escaping @Sendable (String) -> ModelRuntime) {
            loader = WarmModelLoader(
                table: table, budget: SharedModelMemoryBudget(), limitBytes: { Int.max / 4 }, idlePollNanoseconds: 1_000_000
            ) { [unowned self] spec in
                if self.gated.contains(spec.modelID) { await self.gate.wait() }
                self.log.append("load \(spec.modelID)")
                return make(spec.modelID)
            }
            boot = WarmSetBoot(
                table: table, loader: loader, supportedModels: ["model-a", "model-b", "model-c"],
                loadSpec: { WarmModelLoadSpec(modelID: $0, estimatedResidentBytes: 1, minimumRowKVBytes: 0) },
                memberInfo: { runtime in
                    let rows = await runtime.warmSetRowReservation()
                    return WarmModelMemberInfo(
                        maxContextTokens: rows.tokensPerRow, slotsTotal: rows.rows, modelHash: await runtime.loadedModelHash)
                },
                log: { [log] in log.append($0) }
            )
        }
    }

    func testAWarmMemberNeverReceivesTheProviderStatus() async throws {
        let h = RuntimeHarness { Self.fixture($0) }
        let primary = Self.fixture("model-a")
        let status = ProviderStatus(
            modelID: "model-a", modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 2))
        await primary.setProviderStatus(status)
        try await h.boot.adoptPrimary(modelID: "model-a", runtime: primary)
        let outcomes = await h.boot.bootLoad(["model-b"])
        XCTAssertEqual(outcomes, [.loaded])
        let member = try XCTUnwrap(h.table.entry(modelID: "model-b")?.runtime)
        let memberHasStatus = await member.hasProviderStatus()
        let primaryHasStatus = await primary.hasProviderStatus()
        XCTAssertFalse(memberHasStatus)
        XCTAssertTrue(primaryHasStatus)
        XCTAssertEqual(h.table.views.value.last?.info?.modelHash, String(repeating: "a", count: 64))
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.modelID, "model-a")
    }

    func testSwapToAWarmMemberIsRefusedAndAnotherTargetRekeysThePrimary() async throws {
        let h = RuntimeHarness { Self.fixture($0) }
        let primary = Self.fixture("model-a", warmSwapEnabled: true)
        try await h.boot.adoptPrimary(modelID: "model-a", runtime: primary)
        await primary.setWarmSetSwapHooks(h.boot)
        let loaded = await h.boot.load("model-b")
        XCTAssertEqual(loaded, .loaded)

        do {
            _ = try await primary.beginSwap(targetModelID: "MODEL-B")
            XCTFail("swap to a warm member began")
        } catch {
            XCTAssertEqual(error as? WarmSetSwapError, .targetAlreadyWarm(modelID: "MODEL-B"))
            XCTAssertTrue(String(describing: error).contains("unload it before switching"))
        }
        let refused = await primary.currentSnapshot()
        XCTAssertEqual(refused.state, .ready)
        XCTAssertEqual(refused.modelID, "model-a")

        try await primary.beginSwap(targetModelID: "model-c").value
        let swapped = await primary.currentSnapshot()
        XCTAssertEqual(swapped.modelID, "model-c")
        XCTAssertEqual(h.table.entries().map(\.modelID), ["model-c", "model-b"])
        XCTAssertTrue(h.table.entry(modelID: "model-c")?.primary == true)
        XCTAssertEqual(h.table.entry(modelID: "model-b")?.state, .warm, "the other member kept serving")
        XCTAssertNil(h.table.entry(modelID: "model-a"))
    }

    func testSwapAndWarmLoadAreSerialized() async throws {
        let h = RuntimeHarness { Self.fixture($0) }
        h.gated = ["model-b"]
        let swapLog = h.log
        let primary = Self.fixture("model-a", warmSwapEnabled: true) { target in
            swapLog.append("swap load \(target)")
            return (target, String(repeating: "c", count: 64))
        }
        try await h.boot.adoptPrimary(modelID: "model-a", runtime: primary)
        await primary.setWarmSetSwapHooks(h.boot)
        h.boot.startBootLoads(["model-b"])
        await eventually { h.table.entry(modelID: "model-b")?.state == .loading }

        let swap = try await primary.beginSwap(targetModelID: "model-c")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(h.log.contains("swap load"), "the swap waits for the warm load in progress")

        await h.gate.release()
        try await swap.value
        let order = h.log.all.filter { $0.hasPrefix("load ") || $0.hasPrefix("swap load ") }
        XCTAssertEqual(order, ["load model-b", "swap load model-c"])
        XCTAssertEqual(h.table.entries().map(\.modelID), ["model-c", "model-b"])
    }

    func testSwapDrainWaitsOnlyForThePrimarysRequests() async throws {
        let h = RuntimeHarness { Self.fixture($0) }
        let primary = Self.fixture("model-a", warmSwapEnabled: true, swapDrainTimeoutSeconds: 1)
        let status = ProviderStatus(
            modelID: "model-a", modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 4))
        await primary.setProviderStatus(status)
        try await h.boot.adoptPrimary(modelID: "model-a", runtime: primary)
        await primary.setWarmSetSwapHooks(h.boot)
        let loaded = await h.boot.load("model-b")
        XCTAssertEqual(loaded, .loaded)

        // A request on the other member stays in flight through the swap.
        guard case .admitted = await status.admitRequest(warmMember: "model-b") else {
            return XCTFail("request not admitted")
        }
        try await primary.beginSwap(targetModelID: "model-c").value
        let snapshot = await primary.currentSnapshot()
        XCTAssertEqual(snapshot.modelID, "model-c", "the drain did not time out on the other member's request")
        let inFlight = await status.requestsInFlightCount()
        XCTAssertEqual(inFlight, 1)
    }

    func testSwapDrainStillWaitsForThePrimarysRequests() async throws {
        let primary = Self.fixture("model-a", warmSwapEnabled: true, swapDrainTimeoutSeconds: 1)
        let status = ProviderStatus(
            modelID: "model-a", modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 4))
        await primary.setProviderStatus(status)
        guard case .admitted = await status.admitRequest() else { return XCTFail("request not admitted") }
        try await primary.beginSwap(targetModelID: "model-c").value
        let snapshot = await primary.currentSnapshot()
        XCTAssertEqual(snapshot.modelID, "model-a", "a primary request still holds the drain until its timeout")
    }
}
