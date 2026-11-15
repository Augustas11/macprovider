import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-001-R016 `warm_models` entries and the per-member request
/// accounting that keeps the primary's top-level slots its own.
final class WarmModelsWireTests: XCTestCase {
    private func view(
        _ modelID: String,
        state: WarmModelState = .warm,
        primary: Bool = false,
        pinned: Bool = false,
        inFlight: Int = 0,
        info: WarmModelMemberInfo? = nil
    ) -> WarmModelMemberView {
        WarmModelMemberView(
            modelID: modelID, key: modelID.lowercased(), state: state, primary: primary, pinned: pinned,
            inFlight: inFlight, info: info)
    }

    func testAWarmSetOfOneRepeatsTheTopLevelPrimaryFields() {
        let fields: [String: Any] = [
            "type": "heartbeat",
            "model_id": "catalog/model-a",
            "max_context_tokens": 32_000,
            "throughput_tps_estimate": 40.5,
            "model_hash": "aa",
            "model_hash_algorithm": "sha256",
            "weights_manifest_sha256": NSNull(),
            "model_params_b": 30.0,
            "cb_self_check": ["state": "passed"],
            "engine_profile": ["chip": "M5"],
            "ram_gb": 128,
        ]
        let entries = WarmModelsWire.entries(
            primaryFields: fields, primarySlotsTotal: 4, primarySlotsFree: 3,
            views: [view("model-a", primary: true, pinned: true)])
        XCTAssertEqual(entries.count, 1)
        let primary = entries[0]
        XCTAssertEqual(Set(primary.keys), [
            "model_id", "state", "primary", "pinned", "slots_total", "slots_free", "max_context_tokens",
            "throughput_tps_estimate", "model_hash", "model_hash_algorithm", "model_params_b", "cb_self_check",
            "engine_profile",
        ])
        XCTAssertEqual(primary["model_id"] as? String, "catalog/model-a")
        XCTAssertEqual(primary["state"] as? String, "warm")
        XCTAssertEqual(primary["primary"] as? Bool, true)
        XCTAssertEqual(primary["pinned"] as? Bool, true)
        XCTAssertEqual(primary["slots_total"] as? Int, 4)
        XCTAssertEqual(primary["slots_free"] as? Int, 3)
        XCTAssertEqual(primary["throughput_tps_estimate"] as? Double, 40.5)
        XCTAssertEqual((primary["cb_self_check"] as? [String: String])?["state"], "passed")
    }

    func testPrimaryFirstAndOnlyWarmEntriesCarrySlotsFree() {
        let info = WarmModelMemberInfo(
            maxContextTokens: 8_000, slotsTotal: 3, throughputTPSEstimate: 12, modelHash: "bb",
            modelHashAlgorithm: "sha256", weightsManifestSHA256: "ww", modelParamsB: 4)
        let entries = WarmModelsWire.entries(
            primaryFields: ["model_id": "model-a", "loading": true], primarySlotsTotal: 2, primarySlotsFree: 2,
            views: [
                view("model-b", inFlight: 1, info: info),
                view("model-a", primary: true, pinned: true),
                view("model-c", state: .loading, pinned: true),
                view("model-d", state: .evicting, info: info),
            ])
        XCTAssertEqual(entries.map { $0["model_id"] as? String }, ["model-a", "model-b", "model-c", "model-d"])
        XCTAssertEqual(entries.filter { $0["primary"] as? Bool == true }.count, 1)
        // A primary mid-swap is `loading` and advertises no free rows.
        XCTAssertEqual(entries[0]["state"] as? String, "loading")
        XCTAssertNil(entries[0]["slots_free"])
        let member = entries[1]
        XCTAssertEqual(member["state"] as? String, "warm")
        XCTAssertEqual(member["pinned"] as? Bool, false)
        XCTAssertEqual(member["slots_total"] as? Int, 3)
        XCTAssertEqual(member["slots_free"] as? Int, 2)
        XCTAssertEqual(member["max_context_tokens"] as? Int, 8_000)
        XCTAssertEqual(member["throughput_tps_estimate"] as? Double, 12)
        XCTAssertEqual(member["model_params_b"] as? Double, 4)
        XCTAssertEqual(member["model_hash"] as? String, "bb")
        XCTAssertEqual(member["model_hash_algorithm"] as? String, "sha256")
        XCTAssertEqual(member["weights_manifest_sha256"] as? String, "ww")
        XCTAssertEqual(member["weights_manifest_algorithm"] as? String, ModelArtifactIdentity.safetensorsManifestV1)
        XCTAssertEqual(Set(entries[2].keys), ["model_id", "state", "primary", "pinned", "slots_total"])
        XCTAssertEqual(entries[2]["slots_total"] as? Int, 0)
        XCTAssertEqual(entries[3]["state"] as? String, "evicting")
        XCTAssertNil(entries[3]["slots_free"])
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: entries))
    }

    func testLocalStatusCarriesWarmModelsOnlyWithAWarmSet() async {
        let snapshot = await status().snapshot()
        let plain = RouterHandler.statusResponse(snapshot, providerID: nil, coordinatorURL: nil)
        XCTAssertNil(plain["warm_models"])
        let body = RouterHandler.statusResponse(
            snapshot, providerID: nil, coordinatorURL: nil,
            warmModels: [view("model-a", primary: true, pinned: true), view("model-b", state: .loading)])
        let entries = try? XCTUnwrap(body["warm_models"] as? [[String: Any]])
        XCTAssertEqual(entries?.map { $0["model_id"] as? String }, ["model-a", "model-b"])
        XCTAssertEqual(entries?.first?["slots_free"] as? Int, snapshot.slotsFree)
        XCTAssertEqual(entries?.first?["max_context_tokens"] as? Int, 20_000)
        XCTAssertNil(entries?.first?["model_hash"])
    }

    // MARK: ProviderStatus per-member accounting

    private func status(slots: Int = 2) -> ProviderStatus {
        ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: slots)
        )
    }

    private func admit(_ status: ProviderStatus, _ id: String, _ member: String?) async throws -> Date {
        guard case .admitted(let startedAt) = await status.admitRequest(requestID: id, warmMember: member) else {
            XCTFail("\(id) not admitted")
            throw CancellationError()
        }
        return startedAt
    }

    func testSecondaryTrafficNeverMovesThePrimarysSlotsOrState() async throws {
        let status = status()
        final class Transitions: @unchecked Sendable {
            let lock = NSLock()
            var slots: [Int] = []
            func append(_ value: Int) { lock.lock(); slots.append(value); lock.unlock() }
            var all: [Int] { lock.lock(); defer { lock.unlock() }; return slots }
        }
        let transitions = Transitions()
        await status.setRequestCapacityChangeHandler { transitions.append($0.slotsFree) }
        await status.markRequestCapacitySnapshotPublished(slotsFree: 2, slotsTotal: 2)

        _ = try await admit(status, "b1", "model-b")
        _ = try await admit(status, "b2", "model-b")
        _ = try await admit(status, "c1", "model-c")
        var snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.slotsFree, 2)
        XCTAssertEqual(snapshot.slotsTotal, 2)
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.requestsInFlight, 3)
        XCTAssertEqual(snapshot.primaryRequestsInFlight, 0)
        XCTAssertEqual(snapshot.requestsQueued, 0)
        XCTAssertEqual(snapshot.secondaryRequestsInFlight, ["model-b": 2, "model-c": 1])
        XCTAssertTrue(transitions.all.isEmpty, "secondary admissions must not publish a primary capacity change")
        let busy = await status.hasInferenceWork()
        XCTAssertTrue(busy)
        let drained = await status.waitUntilDrained(timeoutSeconds: 0)
        XCTAssertFalse(drained, "a drain waits for every warm member's requests")

        _ = try await admit(status, "p1", nil)
        _ = try await admit(status, "p2", nil)
        snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.slotsFree, 0)
        XCTAssertEqual(snapshot.status, .busy)
        XCTAssertEqual(transitions.all, [1, 0])
    }

    func testTotalsAreRightAfterReleasesInAnyOrder() async throws {
        let status = status(slots: 3)
        let admitted: [(String, String?)] = [("p1", nil), ("b1", "model-b"), ("c1", "model-c"), ("b2", "model-b"), ("p2", nil)]
        var started: [String: Date] = [:]
        for (id, member) in admitted { started[id] = try await admit(status, id, member) }
        let order = ["b1", "p2", "c1", "p1", "b2"]
        var remaining = Dictionary(uniqueKeysWithValues: admitted.map { ($0.0, $0.1) })
        for id in order {
            let member = remaining.removeValue(forKey: id)!
            await status.finishRequest(startedAt: started[id]!, completion: nil, failed: false, requestID: id, warmMember: member)
            let snapshot = await status.snapshot()
            let primaryLeft = remaining.values.filter { $0 == nil }.count
            var secondaryLeft: [String: Int] = [:]
            for case let member? in remaining.values { secondaryLeft[member, default: 0] += 1 }
            XCTAssertEqual(snapshot.requestsInFlight, remaining.count, id)
            XCTAssertEqual(snapshot.primaryRequestsInFlight, primaryLeft, id)
            XCTAssertEqual(snapshot.secondaryRequestsInFlight, secondaryLeft, id)
            XCTAssertEqual(snapshot.slotsFree, 3 - primaryLeft, id)
        }
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.requestsTotal, 5)
        XCTAssertTrue(snapshot.secondaryRequestsInFlight.isEmpty)
        let drained = await status.waitUntilDrained(timeoutSeconds: 0)
        XCTAssertTrue(drained)
    }

    func testSecondaryCompletionsStayOutOfThePrimarysEngineTelemetry() async throws {
        let status = status()
        let startedAt = try await admit(status, "b1", "model-b")
        let completion = CompletionResult(
            content: "x", finishReason: "stop", promptTokens: 5, completionTokens: 3,
            settlementDisposition: .eligibleOwner, nativeMTPProposedTokens: 4, nativeMTPAcceptedTokens: 3)
        await status.finishRequest(startedAt: startedAt, completion: completion, failed: false, requestID: "b1", warmMember: "model-b")
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.requestsTotal, 1)
        XCTAssertEqual(snapshot.outputTokensToday, 3)
        XCTAssertEqual(snapshot.nativeMTPProposedTokensSinceLast, 0)
        XCTAssertEqual(snapshot.nativeMTPAcceptedTokensSinceLast, 0)
    }

    // MARK: Promotion (SPEC-011 R-3.10.3)

    /// Requests in flight on both members when the primary role moves end
    /// up on the side their member is now on, and stay right as they end.
    func testPromotionMovesInFlightRequestsToTheRightSide() async throws {
        let status = status(slots: 4)
        await status.setPrimaryWarmMember("member-a")
        let a1 = try await admit(status, "a1", "member-a")
        let a2 = try await admit(status, "a2", "member-a")
        let b1 = try await admit(status, "b1", "member-b")
        var snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.primaryRequestsInFlight, 2)
        XCTAssertEqual(snapshot.secondaryRequestsInFlight, ["member-b": 1])
        XCTAssertEqual(snapshot.slotsFree, 2)

        await status.promoteWarmPrimary(
            memberKey: "member-b", modelID: "model-b", modelHash: "bb", modelHashAlgorithm: "sha256",
            weightsManifestSHA256: "ww", maxContextTokens: 8_000, maxConcurrency: 3)
        snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.modelID, "model-b")
        XCTAssertEqual(snapshot.modelHash, "bb")
        XCTAssertEqual(snapshot.capacity.maxContextTokens, 8_000)
        XCTAssertEqual(snapshot.capacity.maxConcurrency, 3)
        XCTAssertEqual(snapshot.requestsInFlight, 3)
        XCTAssertEqual(snapshot.primaryRequestsInFlight, 1, "the new primary's request counts on the primary")
        XCTAssertEqual(snapshot.secondaryRequestsInFlight, ["member-a": 2])
        XCTAssertEqual(snapshot.slotsFree, 2)
        XCTAssertEqual(status.preflightCell.value.maxContextTokens, 8_000)

        await status.finishRequest(startedAt: a1, completion: nil, failed: false, requestID: "a1", warmMember: "member-a")
        snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.primaryRequestsInFlight, 1)
        XCTAssertEqual(snapshot.secondaryRequestsInFlight, ["member-a": 1])
        await status.finishRequest(startedAt: b1, completion: nil, failed: false, requestID: "b1", warmMember: "member-b")
        snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.primaryRequestsInFlight, 0)
        XCTAssertEqual(snapshot.slotsFree, 3)
        await status.finishRequest(startedAt: a2, completion: nil, failed: false, requestID: "a2", warmMember: "member-a")
        snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.requestsInFlight, 0)
        XCTAssertTrue(snapshot.secondaryRequestsInFlight.isEmpty)
    }

    /// The new primary's served-slot counts apply even though its runtime
    /// stamps them lower than the old primary's.
    func testPromotionRestartsTheServedSlotStamp() async throws {
        let status = status(slots: 4)
        await status.updateServedSlots(4, stamp: 9)
        await status.promoteWarmPrimary(
            memberKey: "member-b", modelID: "model-b", modelHash: nil, modelHashAlgorithm: nil,
            weightsManifestSHA256: nil, maxContextTokens: 8_000, maxConcurrency: 2)
        await status.updateServedSlots(1, stamp: 1)
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.capacity.maxConcurrency, 1)
    }

    /// After a promotion the new primary's entry comes first, carrying the
    /// top-level fields; the demoted member is an unpinned warm secondary.
    func testWireEntriesArePrimaryFirstAfterPromotion() throws {
        let table = WarmModelTable<WarmFakeRuntime>()
        try table.insertPrimary(modelID: "model-a", runtime: WarmFakeRuntime(memberID: 1, modelID: "model-a", hash: "aa"))
        let token = try table.beginLoading(modelID: "model-b", pinned: false)
        try table.finishLoading(token: token, runtime: WarmFakeRuntime(memberID: 2, modelID: "model-b", hash: "bb"))
        let promoted = try table.promote(modelID: "model-b")
        table.updateInfo(token: promoted.old.token, WarmModelMemberInfo(maxContextTokens: 4_000, slotsTotal: 2, modelHash: "aa"))
        let entries = WarmModelsWire.entries(
            primaryFields: ["model_id": "model-b", "model_hash": "bb"], primarySlotsTotal: 3, primarySlotsFree: 3,
            views: table.views.value)
        XCTAssertEqual(entries.map { $0["model_id"] as? String }, ["model-b", "model-a"])
        XCTAssertEqual(entries.map { $0["primary"] as? Bool }, [true, false])
        XCTAssertEqual(entries.map { $0["pinned"] as? Bool }, [true, false])
        XCTAssertEqual(entries.map { $0["model_hash"] as? String }, ["bb", "aa"])
        XCTAssertEqual(entries[1]["slots_free"] as? Int, 2)
    }
}
