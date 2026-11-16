#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPJourneyRequestInventoryTests: XCTestCase {
    private func body(_ text: String = "Hello", stream: Bool = false) throws -> Data {
        try NativeMTPJourneyRequestInventory.canonical([
            "model": "zai-org/glm-5.3-flash", "messages": [["role": "user", "content": text]],
            "max_tokens": 16, "temperature": 0, "top_p": 1, "seed": 8516, "stream": stream])
    }
    func testFrozenBodyAndConversationKeysAreExact() throws {
        let recording = NativeMTPJourneyRequestInventory()
        try recording.check(id: "row", body: body(), conversationKey: "conv:row")
        try recording.checkControl(id: "row", conversationKey: "conv:row")
        let frozen = try NativeMTPJourneyRequestInventory(data: recording.data())
        XCTAssertEqual(frozen.rows.count, 2)
        try frozen.check(id: "row", body: body(), conversationKey: "conv:row")
        try frozen.checkControl(id: "row", conversationKey: "conv:row")
        XCTAssertThrowsError(try frozen.check(id: "row", body: body("Changed"), conversationKey: "conv:row"))
        XCTAssertThrowsError(try frozen.check(id: "row", body: body(), conversationKey: nil))
        XCTAssertThrowsError(try frozen.check(id: "row", body: body(stream: true), conversationKey: "conv:row"))
        XCTAssertThrowsError(try frozen.check(id: "new", body: body(), conversationKey: "conv:row"))
    }
    func testProductionParserRejectsEveryFrozenBody() throws {
        let bad = Data(#"{"model":"zai-org/glm-5.3-flash","messages":[{"role":"invalid","content":"hello"}]}"#.utf8)
        let inventory = try NativeMTPJourneyRequestInventory.canonical([
            "schema": NativeMTPJourneyRequestInventory.schema,
            "requests": [["id": "bad", "body_base64": bad.base64EncodedString(), "conversation_key": NSNull()]]])
        XCTAssertThrowsError(try NativeMTPJourneyRequestInventory(data: inventory))
        XCTAssertThrowsError(try NativeMTPJourneyRequestInventory().check(id: "bad", body: bad, conversationKey: nil))
    }
    func testEveryExistingGLMRequestFactoryIsFrozenWithoutInference() throws {
        let runner = NativeMTPJourneyRunner(root: "/unused", modelID: "zai-org/glm-5.3-flash", qualifiedSlots: 4,
            maxNativeActiveRows: 1, maxPromptTokens: 4096, signedAdmissionInputs: "/unused", selectedSteps: ["07"])
        let recording = NativeMTPJourneyRequestInventory()
        runner.requestInventory = recording
        try runner.enumerateFrozenRequests(capPrompt: "Frozen tokenizer-only cap prompt")
        XCTAssertGreaterThan(recording.rows.count, 50)
        let frozen = try NativeMTPJourneyRequestInventory(data: recording.data())
        runner.requestInventory = frozen
        try runner.enumerateFrozenRequests(capPrompt: "Frozen tokenizer-only cap prompt")
        XCTAssertThrowsError(try runner.enumerateFrozenRequests(capPrompt: "Different cap prompt"))
        let ids = Set(frozen.rows.compactMap { $0["id"] as? String })
        XCTAssertTrue(ids.contains("journey-profile-history"))
        XCTAssertTrue(ids.contains("journey-mixed-2-control"))
        XCTAssertTrue(ids.contains("journey-warm-swap-new-ordinary"))
    }

    func testWarmSwapNewRequestCountsReasoningButKeepsHashAndTerminal() {
        let hash = String(repeating: "a", count: 64)
        let done = { (content: String, reasoning: String?, finish: String, observed: String?) in
            NativeMTPJourneyRunner.warmSwapNewRequestCompleted(
                content: content, reasoningContent: reasoning, finishReason: finish,
                modelHashObserved: observed, expectedModelHash: hash)
        }
        XCTAssertTrue(done("Gulf Stream", nil, "length", hash))
        XCTAssertTrue(done("", "The user asks for currents", "length", hash))
        XCTAssertTrue(done("", "thinking", "stop", hash))
        XCTAssertFalse(done("", nil, "length", hash))
        XCTAssertFalse(done("", "", "stop", hash))
        XCTAssertFalse(done("Gulf Stream", nil, "length", String(repeating: "b", count: 64)))
        XCTAssertFalse(done("Gulf Stream", nil, "length", nil))
        XCTAssertFalse(done("Gulf Stream", nil, "error", hash))
        XCTAssertFalse(done("", "thinking", "cancelled", hash))
    }
}
#endif
