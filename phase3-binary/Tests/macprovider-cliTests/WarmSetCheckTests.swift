import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// A running warm set for `warm_set check`: a real loader and shared memory
/// budget, the main model `model-a` recorded with `primaryActiveBytes` of
/// measured resident memory and its rows reserved, and a factory that fails
/// the test if anything loads. No model is loaded.
final class WarmSetCheckRig: @unchecked Sendable {
    static let gib = 1 << 30
    let table = WarmModelTable<WarmFakeRuntime>()
    let budget = SharedModelMemoryBudget()
    let boot: WarmSetBoot<WarmFakeRuntime>
    private let factoryCalls = FactoryCalls()
    /// The process's MLX active memory once the main model is loaded.
    private let primaryActiveBytes: Int

    private final class FactoryCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func add() { lock.lock(); count += 1; lock.unlock() }
    }

    /// `memberGiB` and `memberKV` are what `serve`'s load spec says about the
    /// model asked about.
    /// `limit`, when given, is read for every decision instead of `limitBytes`.
    init(limitBytes: Int, primaryActiveBytes: Int, primaryKV: Int = 100_000,
         primaryContext: Int = 32_768, primarySlots: Int = 2, memberGiB: Int = 4, memberKV: Int = 50_000,
         limit: (@Sendable () -> Int?)? = nil) throws {
        self.primaryActiveBytes = primaryActiveBytes
        let loader = WarmModelLoader(
            table: table, budget: budget, limitBytes: limit ?? { limitBytes }, idlePollNanoseconds: 1_000_000
        ) { [factoryCalls] spec in
            factoryCalls.add()
            return WarmFakeRuntime(memberID: 99, modelID: spec.modelID, hash: "x")
        }
        boot = WarmSetBoot(
            table: table, loader: loader, supportedModels: ["model-a", "org/second", "model-c"],
            loadSpec: { modelID in
                WarmModelLoadSpec(
                    modelID: modelID, estimatedResidentBytes: memberGiB * Self.gib,
                    minimumRowKVBytes: MLXMemoryBudget.kvBytes(tokens: SharedModelMemoryRules.minimumRowTokens, bytesPerToken: memberKV),
                    modelFamily: "llama")
            },
            memberInfo: { _ in WarmModelMemberInfo(maxContextTokens: 4_096, slotsTotal: 1) },
            log: { _ in })
        try table.insertPrimary(modelID: "model-a", runtime: WarmFakeRuntime(memberID: 1, modelID: "model-a", hash: "a"))
        _ = budget.recordLoaded(
            memberID: 1, label: "model-a", modelFamily: "qwen3", wires: false, activeBytes: primaryActiveBytes,
            weightBytes: nil, kvBytesPerToken: primaryKV, pinned: true)
        budget.reserveRows(memberID: 1, rows: primarySlots, tokensPerRow: primaryContext)
    }

    /// A further member `model-c` of `gib` resident GiB, already warm. MLX
    /// active memory is process-wide, so its load records the sum.
    @discardableResult
    func addThirdMember(gib: Int, pinned: Bool) throws -> UInt64 {
        let token = try table.beginLoading(modelID: "model-c", pinned: pinned)
        try table.finishLoading(token: token, runtime: WarmFakeRuntime(memberID: 3, modelID: "model-c", hash: "c"))
        _ = budget.recordLoaded(
            memberID: 3, label: "model-c", modelFamily: "llama", wires: false, activeBytes: primaryActiveBytes + gib * Self.gib,
            weightBytes: nil, kvBytesPerToken: 10_000, pinned: pinned)
        return token
    }

    var loads: Int { factoryCalls.value }

    func check(_ modelID: String = "org/second") async -> WarmSetControlReply {
        await ControlSocketServer.handleWarmSetRequest(action: "check", modelID: modelID, warmSet: boot)
    }

    /// What must not change under a check.
    func state() -> [String] {
        table.entries().map { "\($0.modelID):\($0.state.rawValue):\($0.leases)" } + ["pending=\(budget.pendingLoadBytes)"]
    }
}

/// SPEC-001-R017 `warm_set check`: the running provider's own load
/// decision, from what it holds now, which the arithmetic estimate cannot
/// see. Nothing is loaded, evicted or reserved.
final class WarmSetCheckTests: XCTestCase {
    private let gib = WarmSetCheckRig.gib

    /// The estimate for `org/second` beside the main model as files describe
    /// it, and the limit it assumes.
    private func estimate() throws -> (plan: AutotuneWarmSetPlan, limit: Int) {
        let plan = AutotuneWarmSetPlan.compute(AutotuneWarmSetPlan.Inputs(
            physicalMemoryBytes: UInt64(64) * UInt64(gib), recommendedWorkingSetBytes: 48 * gib,
            primary: .init(modelID: "model-a", artifactBytes: 16 * gib, kvBytesPerToken: 100_000,
                           declaredMaxContextTokens: 262_144, family: "qwen3", catalogMinRAMGB: 32),
            primaryContextTokens: 32_768, primarySlots: 2, primaryVerified: true,
            member: .init(modelID: "org/second", artifactBytes: 4 * gib, kvBytesPerToken: 50_000,
                          declaredMaxContextTokens: 131_072, family: "llama", catalogMinRAMGB: 8),
            operatorCommandBufferMB: nil))
        return (plan, try XCTUnwrap(plan.limitBytes))
    }

    func testWithTheEstimatesInputsTheRunningProviderAlsoFitsAndChangesNothing() async throws {
        let (plan, limit) = try estimate()
        XCTAssertEqual(plan.decision, .fits)
        let rig = try WarmSetCheckRig(limitBytes: limit, primaryActiveBytes: 16 * gib)
        let before = rig.state()
        let reply = await rig.check()
        XCTAssertEqual(reply.action, "check")
        XCTAssertEqual(reply.status, "fits")
        let report = try XCTUnwrap(reply.check)
        XCTAssertEqual(report.decision, "fits")
        XCTAssertEqual(report.limitBytes, limit)
        XCTAssertEqual(report.loadedResidentBytes, 16 * gib)
        XCTAssertEqual(report.estimatedResidentBytes, 4 * gib)
        XCTAssertEqual(report.evict, [])
        XCTAssertEqual(rig.state(), before)
        XCTAssertEqual(rig.loads, 0)
        XCTAssertEqual(reply.entries.map(\.modelID), ["model-a"])
    }

    /// The main model holds more than its weights (a draft model or a
    /// native-MTP drafter is MLX active memory too): the estimate still says
    /// fits, the running provider says it would refuse, as `load` would.
    func testExtraResidentMemoryTheEstimateCannotSeeMakesTheProviderRefuse() async throws {
        let (plan, limit) = try estimate()
        XCTAssertEqual(plan.decision, .fits)
        let rig = try WarmSetCheckRig(limitBytes: limit, primaryActiveBytes: 16 * gib + 24 * gib)
        let before = rig.state()
        let reply = await rig.check()
        XCTAssertEqual(reply.status, "insufficient_memory")
        XCTAssertEqual(reply.check?.decision, "insufficient_memory")
        XCTAssertEqual(reply.check?.loadedResidentBytes, 40 * gib)
        XCTAssertGreaterThan(try XCTUnwrap(reply.check?.requiredBytes), limit)
        XCTAssertTrue(reply.detail?.hasPrefix("insufficient_memory model=org/second") == true, reply.detail ?? "")
        XCTAssertEqual(rig.state(), before)
        XCTAssertEqual(rig.loads, 0)
        // A load now gets the same answer.
        let load = await ControlSocketServer.handleWarmSetRequest(action: "load", modelID: "org/second", warmSet: rig.boot)
        XCTAssertEqual(load.status, reply.status)
        XCTAssertEqual(load.detail, reply.detail)
        XCTAssertEqual(rig.loads, 0)
    }

    /// A third model already loaded, which the estimate does not count: idle
    /// and unpinned, the provider would unload it first; pinned or serving,
    /// it would refuse. The check unloads nothing.
    func testAThirdLoadedModelDecidesEvictionOrRefusal() async throws {
        let (plan, limit) = try estimate()
        XCTAssertEqual(plan.decision, .fits)

        let idle = try WarmSetCheckRig(limitBytes: limit, primaryActiveBytes: 16 * gib)
        try idle.addThirdMember(gib: 26, pinned: false)
        let before = idle.state()
        let evicting = await idle.check()
        XCTAssertEqual(evicting.status, "fits_after_eviction")
        XCTAssertEqual(evicting.check?.evict, ["model-c"])
        XCTAssertEqual(evicting.check?.decision, "fits_after_eviction")
        XCTAssertEqual(idle.state(), before, "model-c is still warm")
        XCTAssertEqual(idle.loads, 0)

        let serving = try WarmSetCheckRig(limitBytes: limit, primaryActiveBytes: 16 * gib)
        try serving.addThirdMember(gib: 26, pinned: false)
        let lease = try serving.table.lease(servedModelID: "model-c")
        let busy = await serving.check()
        XCTAssertEqual(busy.status, "insufficient_memory")
        lease.release()

        let pinned = try WarmSetCheckRig(limitBytes: limit, primaryActiveBytes: 16 * gib)
        try pinned.addThirdMember(gib: 26, pinned: true)
        let refused = await pinned.check()
        XCTAssertEqual(refused.status, "insufficient_memory")
        XCTAssertEqual(refused.check?.evict, [])
    }

    /// `load` decides again after it unloads the planned members and refuses
    /// unless that decision fits outright; the check makes the same second
    /// decision, so a budget that refuses it gets `insufficient_memory`, not
    /// `fits_after_eviction`.
    func testTheCheckRefusesWhenThePostEvictionDecisionRefuses() async throws {
        let (_, limit) = try estimate()
        final class Reads: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        }
        let reads = Reads()
        // Every read after the first is half the limit: what the eviction
        // plan freed no longer covers the load.
        let gib = self.gib
        let rig = try WarmSetCheckRig(
            limitBytes: limit, primaryActiveBytes: 16 * gib,
            limit: { reads.next() == 1 ? limit : limit / 2 })
        try rig.addThirdMember(gib: 26, pinned: false)
        let before = rig.state()
        let reply = await rig.check()
        XCTAssertEqual(reply.status, "insufficient_memory")
        XCTAssertEqual(reply.check?.evict, [])
        XCTAssertEqual(reply.check?.limitBytes, limit / 2, "the reply reports the post-eviction decision")
        XCTAssertTrue(reply.detail?.hasPrefix("insufficient_memory model=org/second") == true, reply.detail ?? "")
        XCTAssertEqual(rig.state(), before, "model-c is still warm")
        XCTAssertEqual(rig.loads, 0)
    }

    /// No injected limit: the pinned main model's reserved rows leave no room
    /// for the load even once the idle member is gone. With 8 reserved rows
    /// the check plans that eviction and its post-eviction decision fits; with
    /// 10 the same eviction no longer covers the load and the check refuses,
    /// as `load` does, unloading nothing.
    func testReservedRowsOfThePinnedMainModelRefuseEvenAfterThePlannedEviction() async throws {
        let limit = 48 * gib
        let fitting = try WarmSetCheckRig(limitBytes: limit, primaryActiveBytes: 16 * gib, primarySlots: 8)
        try fitting.addThirdMember(gib: 4, pinned: false)
        let evicting = await fitting.check()
        XCTAssertEqual(evicting.status, "fits_after_eviction")
        XCTAssertEqual(evicting.check?.evict, ["model-c"])
        XCTAssertEqual(evicting.check?.limitBytes, limit)

        let rig = try WarmSetCheckRig(limitBytes: limit, primaryActiveBytes: 16 * gib, primarySlots: 10)
        try rig.addThirdMember(gib: 4, pinned: false)
        let before = rig.state()
        let reply = await rig.check()
        XCTAssertEqual(reply.status, "insufficient_memory")
        XCTAssertEqual(reply.check?.evict, [])
        XCTAssertEqual(reply.check?.limitBytes, limit)
        XCTAssertGreaterThan(try XCTUnwrap(reply.check?.requiredBytes), limit)
        XCTAssertEqual(rig.state(), before, "model-c is still warm")
        let load = await ControlSocketServer.handleWarmSetRequest(action: "load", modelID: "org/second", warmSet: rig.boot)
        XCTAssertEqual(load.status, reply.status)
        XCTAssertEqual(load.detail, reply.detail)
        XCTAssertEqual(rig.state(), before, "load evicted nothing for a refused load")
        XCTAssertEqual(rig.loads, 0)
    }

    /// The second decision on its natural path: whenever the first plans an
    /// eviction, the decision with those members gone fits without a further
    /// eviction (each evicted member frees exactly its weights, minimum row
    /// and margin, which the decision charged). Over a grid of loaded sets,
    /// reserved rows and limits the simulation never disagrees with the plan,
    /// so a post-eviction refusal needs the state or limit to change between
    /// the decisions (the injected-limit test above).
    func testThePostEvictionDecisionFitsWheneverThePlanIsSatisfied() {
        typealias Rules = SharedModelMemoryRules
        var planned = 0
        for limitGiB in [24, 32, 48, 64] {
            for reservedRows in [0, 2, 8, 10] {
                for idleGiB in [1, 4, 12] {
                    for secondIdleGiB in [0, 2, 6] {
                        var primary = SharedModelMemoryMember(label: "model-a")
                        primary.loaded = true
                        primary.residentBytes = 16 * gib
                        primary.kvBytesPerToken = 100_000
                        primary.pinned = true
                        primary.reservedRowKVBytes = MLXMemoryBudget.kvBytes(tokens: reservedRows * 32_768, bytesPerToken: 100_000)
                        var members = [1: primary]
                        for (id, size) in [(3, idleGiB), (4, secondIdleGiB)] where size > 0 {
                            var idle = SharedModelMemoryMember(label: "m\(id)")
                            idle.loaded = true
                            idle.residentBytes = size * gib
                            idle.kvBytesPerToken = 10_000
                            idle.lastAdmissionAt = UInt64(id)
                            members[id] = idle
                        }
                        let newRow = MLXMemoryBudget.kvBytes(tokens: Rules.minimumRowTokens, bytesPerToken: 50_000)
                        let first = Rules.loadDecision(
                            limitBytes: limitGiB * gib, members: members, estimatedResidentBytes: 4 * gib, newMinimumRowKVBytes: newRow)
                        guard let plan = first.eviction, !plan.evict.isEmpty else { continue }
                        planned += 1
                        let after = Rules.loadDecision(
                            limitBytes: limitGiB * gib, members: members.filter { !plan.evict.contains($0.key) },
                            estimatedResidentBytes: 4 * gib, newMinimumRowKVBytes: newRow)
                        XCTAssertTrue(after.admitted && after.eviction == nil,
                                      "limit=\(limitGiB) reserved=\(reservedRows) idle=\(idleGiB)+\(secondIdleGiB): \(after)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(planned, 0, "the grid plans evictions")
    }

    /// SPEC-001-R016: status names the member the wire names primary. At a
    /// promotion the provider status switches first; status follows it, not
    /// the table's flag, and lists that member first.
    func testControlStatusNamesTheWirePrimaryAtThePromotionInstant() async throws {
        let rig = try WarmSetCheckRig(limitBytes: 64 * gib, primaryActiveBytes: 16 * gib)
        let token = try rig.addThirdMember(gib: 4, pinned: false)
        let wireKey = WarmModelTable<WarmFakeRuntime>.memberKey(token: token)
        let boot = WarmSetBoot(
            table: rig.table, loader: rig.boot.loader, supportedModels: ["model-a", "model-c"],
            loadSpec: { _ in throw CocoaError(.featureUnsupported) },
            memberInfo: { _ in WarmModelMemberInfo(maxContextTokens: 4_096, slotsTotal: 1) },
            primaryMemberKeySource: { wireKey },
            log: { _ in })
        XCTAssertEqual(rig.table.entries().first(where: \.primary)?.modelID, "model-a", "the table has not promoted yet")
        let entries = await boot.controlEntries()
        XCTAssertEqual(entries.map(\.modelID), ["model-c", "model-a"])
        XCTAssertEqual(entries.map(\.primary), [true, false])

        // No wire key, or one naming no member: the table's flag decides.
        let unnamed = WarmSetBoot(
            table: rig.table, loader: rig.boot.loader, supportedModels: ["model-a", "model-c"],
            loadSpec: { _ in throw CocoaError(.featureUnsupported) },
            memberInfo: { _ in WarmModelMemberInfo(maxContextTokens: 4_096, slotsTotal: 1) },
            primaryMemberKeySource: { "warm-member-0" },
            log: { _ in })
        let tableOrder = await unnamed.controlEntries()
        XCTAssertEqual(tableOrder.map(\.modelID), ["model-a", "model-c"])
        XCTAssertEqual(tableOrder.map(\.primary), [true, false])
    }

    func testRefusalsBeforeTheMemoryDecisionMatchLoad() async throws {
        let rig = try WarmSetCheckRig(limitBytes: 64 * gib, primaryActiveBytes: 16 * gib)
        let unsupported = await rig.check("org/unknown")
        XCTAssertEqual(unsupported.status, "unsupported_model")
        XCTAssertEqual(unsupported.detail, "not_in_supported_models")
        XCTAssertNil(unsupported.check)
        let primary = await rig.check("MODEL-A")
        XCTAssertEqual(primary.status, "already_warm")
        let missing = await ControlSocketServer.handleWarmSetRequest(action: "check", modelID: " ", warmSet: rig.boot)
        XCTAssertEqual(missing.status, "invalid_request")
        let badLimits = await ControlSocketServer.handleWarmSetRequest(
            action: "check", modelID: "org/second", warmSet: rig.boot, contextTokens: 0)
        XCTAssertEqual(badLimits.detail, "invalid_limits")
        let none = await ControlSocketServer.handleWarmSetRequest(action: "check", modelID: "org/second", warmSet: nil)
        XCTAssertEqual(none.status, "unavailable")
    }

    func testTheCheckReplyRoundTripsAndOlderRepliesStillDecode() throws {
        let reply = WarmSetControlReply(
            action: "check", status: "fits_after_eviction", modelID: "org/second", detail: nil, entries: [],
            check: WarmSetCheckReport(decision: "fits_after_eviction", limitBytes: 10, requiredBytes: 9,
                                      loadedResidentBytes: 7, estimatedResidentBytes: 2, evict: ["model-c"]))
        let data = try ControlSocketCodec.encode(.warmSetResponse(reply))
        XCTAssertEqual(try ControlSocketCodec.decode(data), .warmSetResponse(reply))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"loaded_resident_bytes\":7") && text.contains("\"evict\":[\"model-c\"]"), text)
        let older = Data(#"{"type":"warm_set_response","action":"status","status":"ok","entries":[]}"#.utf8)
        XCTAssertEqual(try ControlSocketCodec.decode(older),
                       .warmSetResponse(WarmSetControlReply(action: "status", status: "ok", modelID: nil, detail: nil, entries: [])))
        XCTAssertFalse(String(decoding: try ControlSocketCodec.encode(.warmSetResponse(
            WarmSetControlReply(action: "status", status: "ok", entries: []))), as: UTF8.self).contains("check"))
    }
}
