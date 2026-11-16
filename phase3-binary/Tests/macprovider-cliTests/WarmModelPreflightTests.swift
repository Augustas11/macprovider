import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-001-R016 preflight per warm member, answered from the table's
/// lock-protected member views.
final class WarmModelPreflightTests: XCTestCase {
    private let ready = ProviderPreflightView(status: .ready, modelLoaded: true, maxContextTokens: 32_000)

    private func table(memberState: WarmModelState? = .warm, info: WarmModelMemberInfo? = .init(maxContextTokens: 8_000, slotsTotal: 2)) throws -> WarmModelTable<WarmFakeRuntime> {
        let table = WarmModelTable<WarmFakeRuntime>()
        try table.insertPrimary(modelID: "model-a", runtime: WarmFakeRuntime(memberID: 7_201, modelID: "model-a", hash: "a"))
        guard let memberState else { return table }
        let token = try table.beginLoading(modelID: "Model-B", pinned: false)
        if memberState == .loading { return table }
        try table.finishLoading(token: token, runtime: WarmFakeRuntime(memberID: 7_202, modelID: "Model-B", hash: "b"))
        if let info { table.updateInfo(token: token, info) }
        if memberState == .evicting { _ = try table.beginEvicting(modelID: "model-b", allowPinned: false) }
        return table
    }

    private func ack(
        _ table: WarmModelTable<WarmFakeRuntime>?,
        served: String??,
        tokens: Int = 100,
        view: ProviderPreflightView? = nil
    ) -> [String: Any] {
        CoordinatorClient.preflightAck(
            requestID: "r", estimatedTokens: tokens, view: view ?? ready, servedModelID: served,
            warmModels: table?.views.value, primaryNames: ["model-a", "catalog/model-a"]
        )
    }

    func testWarmMemberIsAnsweredForItsOwnContextCapacity() throws {
        let table = try table()
        XCTAssertEqual(ack(table, served: "model-b")["accepted"] as? Bool, true)
        XCTAssertEqual(ack(table, served: "MODEL-B")["estimated_wait_ms"] as? Int, 0)
        let tooLong = ack(table, served: "model-b", tokens: 8_001)
        XCTAssertEqual(tooLong["reason"] as? String, "context_exceeds_capacity")
        XCTAssertEqual(tooLong["max_context_tokens"] as? Int, 8_000)
        // The process health still applies to the member.
        let draining = ProviderPreflightView(status: .draining, modelLoaded: true, maxContextTokens: 32_000)
        XCTAssertEqual(ack(table, served: "model-b", view: draining)["reason"] as? String, "draining")
        let paused = ProviderPreflightView(status: .unavailable, modelLoaded: true, maxContextTokens: 32_000)
        XCTAssertEqual(ack(table, served: "model-b", view: paused)["reason"] as? String, "unhealthy")
        // A primary that is mid-swap does not stop a warm secondary.
        let swapping = ProviderPreflightView(status: .ready, modelLoaded: false, maxContextTokens: 32_000)
        XCTAssertEqual(ack(table, served: "model-b", view: swapping)["accepted"] as? Bool, true)
    }

    func testAModelWithNoWarmMemberIsNotLoaded() throws {
        for state in [nil, WarmModelState.loading, .evicting] {
            let table = try table(memberState: state)
            let refused = ack(table, served: "model-b")
            XCTAssertEqual(refused["accepted"] as? Bool, false, String(describing: state))
            XCTAssertEqual(refused["reason"] as? String, "model_not_loaded", String(describing: state))
        }
        XCTAssertEqual(ack(try table(), served: "model-z")["reason"] as? String, "model_not_loaded")
        // A non-string id names no member.
        XCTAssertEqual(ack(try table(), served: .none)["reason"] as? String, "model_not_loaded")
        // Warm but nothing published yet: not servable.
        XCTAssertEqual(ack(try table(info: nil), served: "model-b")["reason"] as? String, "model_not_loaded")
    }

    func testNoServedIdOrThePrimaryIsTodaysAnswer() throws {
        let table = try table()
        for served: String?? in [.some(nil), "", "model-a", "CATALOG/model-a"] {
            XCTAssertEqual(
                NSDictionary(dictionary: ack(table, served: served, tokens: 20_000)),
                NSDictionary(dictionary: CoordinatorClient.preflightAck(requestID: "r", estimatedTokens: 20_000, view: ready)),
                String(describing: served)
            )
        }
        let unloaded = ProviderPreflightView(status: .ready, modelLoaded: false, maxContextTokens: 32_000)
        XCTAssertEqual(ack(table, served: "model-a", view: unloaded)["reason"] as? String, "model_not_loaded")
    }

    func testNoTableIgnoresTheServedIdExactlyAsToday() {
        for served: String?? in ["model-b", .none, .some(nil)] {
            XCTAssertEqual(
                NSDictionary(dictionary: ack(nil, served: served)),
                NSDictionary(dictionary: CoordinatorClient.preflightAck(requestID: "r", estimatedTokens: 100, view: ready))
            )
        }
    }

    func testInboundPreflightCarriesTheServedModelID() throws {
        let named = CoordinatorClient.inboundPreflight(.string(#"{"type":"preflight","request_id":"x","estimated_tokens":7,"served_model_id":"model-b"}"#))
        XCTAssertEqual(try XCTUnwrap(named).servedModelID, .some("model-b"))
        let absent = CoordinatorClient.inboundPreflight(.string(#"{"type":"preflight","request_id":"x","estimated_tokens":7}"#))
        XCTAssertEqual(try XCTUnwrap(absent).servedModelID, .some(nil))
        let malformed = CoordinatorClient.inboundPreflight(.string(#"{"type":"preflight","request_id":"x","estimated_tokens":7,"served_model_id":3}"#))
        XCTAssertEqual(try XCTUnwrap(malformed).servedModelID, .none)
    }

    func testViewsFollowStateLeasesAndPublishedInfo() throws {
        let table = try table(memberState: nil)
        let token = try table.beginLoading(modelID: "model-b", pinned: true)
        XCTAssertEqual(table.views.value.map(\.state), [.warm, .loading])
        XCTAssertNil(table.views.value[1].slotsFree)
        try table.finishLoading(token: token, runtime: WarmFakeRuntime(memberID: 7_203, modelID: "model-b", hash: "b"))
        table.updateInfo(token: token, .init(maxContextTokens: 4_096, slotsTotal: 3, modelHash: "b"))
        let lease = try table.lease(servedModelID: "model-b")
        var member = table.views.value[1]
        XCTAssertEqual(member.state, .warm)
        XCTAssertTrue(member.pinned)
        XCTAssertFalse(member.primary)
        XCTAssertEqual(member.inFlight, 1)
        XCTAssertEqual(member.slotsFree, 2)
        XCTAssertEqual(member.info?.modelHash, "b")
        lease.release()
        member = table.views.value[1]
        XCTAssertEqual(member.slotsFree, 3)
        XCTAssertEqual(table.views.value, table.memberViews())
        XCTAssertTrue(table.views.value[0].primary)
    }
}
