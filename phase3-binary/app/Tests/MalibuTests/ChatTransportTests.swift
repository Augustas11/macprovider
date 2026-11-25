import XCTest
@testable import Malibu

final class ChatTransportTests: XCTestCase {
    func testSSEPreservesFragmentedUTF8AndCRLF() throws {
        var decoder = ChatSSEDecoder(); var events: [String] = []
        let wire = ": heartbeat\r\ndata: {\"text\":\"🌴 café\"}\r\n\r\ndata: first\ndata: second\n\n"
        for byte in wire.utf8 { if let event = try decoder.feed(byte) { events.append(event) } }
        XCTAssertEqual(events, ["{\"text\":\"🌴 café\"}", "first\nsecond"])
    }
    func testSSERejectsInvalidUTF8AndOversizedLine() throws {
        var invalid = ChatSSEDecoder()
        for byte in Data("data: ".utf8) + Data([0xff, 10]) { _ = try invalid.feed(byte) }
        XCTAssertThrowsError(try invalid.feed(10))
        var oversized = ChatSSEDecoder()
        for _ in 0..<(64 * 1024) { _ = try oversized.feed(65) }
        XCTAssertThrowsError(try oversized.feed(65))
    }
    func testIncrementalContentRequiresFinishAndDone() throws {
        var stream = ChatStreamAccumulator()
        XCTAssertEqual(try stream.accept(Self.chunk(content: "Hel")), "Hel")
        XCTAssertEqual(try stream.accept(Self.chunk(content: "lo")), "lo")
        XCTAssertThrowsError(try stream.result())
        _ = try stream.accept(Self.chunk(reason: "stop"))
        _ = try stream.accept("[DONE]")
        XCTAssertEqual(try stream.result().text, "Hello")
        XCTAssertThrowsError(try stream.accept("[DONE]"))
        var unfinished = ChatStreamAccumulator()
        XCTAssertThrowsError(try unfinished.accept("[DONE]"))
    }
    func testPreemptionFailsAndOtherEarlyStopsStillFail() throws {
        var stream = ChatStreamAccumulator()
        _ = try stream.accept(Self.chunk(content: "Partial"))
        XCTAssertThrowsError(try stream.accept("{\"error\":{\"code\":\"local_preempted\"}}")) {
            XCTAssertEqual($0 as? ChatFailure, .preempted)
        }
        var filtered = ChatStreamAccumulator()
        XCTAssertThrowsError(try filtered.accept(Self.chunk(reason: "content_filter"))) {
            XCTAssertEqual($0 as? ChatFailure, .limit)
        }
    }
    func testLengthFinishKeepsPartialText() throws {
        var stream = ChatStreamAccumulator()
        XCTAssertEqual(try stream.accept(Self.chunk(content: "Partial")), "Partial")
        _ = try stream.accept(Self.chunk(content: " reply", reason: "length"))
        _ = try stream.accept("[DONE]")
        let result = try stream.result()
        XCTAssertEqual(result.text, "Partial reply")
        XCTAssertTrue(result.truncated)
    }
    func testTextPastTheCapIsKeptNotDiscarded() throws {
        var stream = ChatStreamAccumulator()
        let block = String(repeating: "a", count: 40 * 1024)
        XCTAssertEqual(try stream.accept(Self.chunk(content: block)), block)
        XCTAssertNil(try stream.accept(Self.chunk(content: block)))
        _ = try stream.accept(Self.chunk(reason: "stop"))
        _ = try stream.accept("[DONE]")
        let result = try stream.result()
        XCTAssertEqual(result.text, block)
        XCTAssertTrue(result.truncated)
    }
    func testReasoningAccumulatesSeparatelyFromTheAnswer() throws {
        var stream = ChatStreamAccumulator()
        XCTAssertNil(try stream.accept(Self.chunk(reasoning: "Let me ")))
        XCTAssertEqual(stream.lastReasoning, "Let me ")
        XCTAssertNil(try stream.accept(Self.chunk(reasoning: "think.")))
        XCTAssertEqual(try stream.accept(Self.chunk(content: "Answer")), "Answer")
        XCTAssertNil(stream.lastReasoning)
        _ = try stream.accept(Self.chunk(reason: "stop"))
        _ = try stream.accept("[DONE]")
        let result = try stream.result()
        XCTAssertEqual(result.reasoning, "Let me think.")
        XCTAssertEqual(result.text, "Answer")
        XCTAssertFalse(result.truncated)
    }
    func testReasoningOnlyReplyCompletes() throws {
        var stream = ChatStreamAccumulator()
        _ = try stream.accept(Self.chunk(reasoning: "Only thoughts"))
        _ = try stream.accept(Self.chunk(reason: "stop"))
        _ = try stream.accept("[DONE]")
        let result = try stream.result()
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.reasoning, "Only thoughts")
    }
    func testToolArgumentsAccumulateAndRequireUniqueCompleteCalls() throws {
        var stream = ChatStreamAccumulator()
        for part in [
            "{\"index\":0,\"id\":\"call1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}",
            "{\"index\":0,\"function\":{\"arguments\":\"\\\"a.txt\\\"}\"}}"
        ] {
            _ = try stream.accept("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[\(part)]},\"finish_reason\":null}]}")
        }
        _ = try stream.accept(Self.chunk(reason: "tool_calls")); _ = try stream.accept("[DONE]")
        XCTAssertEqual(try stream.result().calls, [ChatToolCall(id: "call1", name: "read_file", arguments: "{\"path\":\"a.txt\"}")])
    }
    func testCapabilityRequiresFreshLocalAccountingAndLoadedModel() throws {
        let cap = Self.capability()
        let status = Self.status()
        let parsed = try ChatCapability.parse(capabilities: cap, status: status)
        XCTAssertEqual(parsed.model, "fixture-model")
        XCTAssertTrue(parsed.guaranteedTools)
        XCTAssertFalse(try ChatCapability.parse(capabilities: Self.capability(modes: ["auto"]), status: status).guaranteedTools)
        XCTAssertThrowsError(try ChatCapability.parse(capabilities: cap, status: Self.status(localUsage: false)))
        XCTAssertThrowsError(try ChatCapability.parse(capabilities: cap, status: Self.status(loaded: false)))
        XCTAssertThrowsError(try ChatCapability.parse(capabilities: cap, status: Self.status(model: "different")))
        XCTAssertThrowsError(try ChatCapability.parse(capabilities: Data("{}".utf8), status: status))
    }
    func testCompletionRequestCarriesExplicitLocalOriginMarker() throws {
        let request = LocalChatTransport.completionRequest(at: try ChatEndpoint(port: 9042), body: Data("{}".utf8))
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9042/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        // The provider treats an unmarked loopback request as a paying buyer.
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-MacProvider-Origin"), "local-app")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-MacProvider-Settlement-Metadata"))
    }
    func testCompletionRequestCarriesAFreshRequestID() throws {
        let endpoint = try ChatEndpoint(port: 9042)
        let first = LocalChatTransport.completionRequest(at: endpoint, body: Data("{}".utf8)).value(forHTTPHeaderField: "X-Request-ID")
        let second = LocalChatTransport.completionRequest(at: endpoint, body: Data("{}".utf8)).value(forHTTPHeaderField: "X-Request-ID")
        XCTAssertFalse(first?.isEmpty ?? true)
        XCTAssertFalse(second?.isEmpty ?? true)
        XCTAssertNotEqual(first, second)
    }
    func testSessionWaitsOutAQuietToolCallAndHasNoShortTotalLimit() {
        // A provider buffering a tool call sends nothing for 39-79 s.
        let config = LocalChatTransport.sessionConfiguration()
        XCTAssertEqual(config.timeoutIntervalForRequest, 300)
        XCTAssertEqual(config.timeoutIntervalForResource, 3600)
    }
    func testAFullLengthReplyOfSmallChunksFitsTheStreamAndEndsWithLength() throws {
        var decoder = ChatSSEDecoder(); var stream = ChatStreamAccumulator()
        var wire = ""
        for _ in 0..<8192 { wire += "data: " + Self.chunk(content: "a") + "\n\n" }
        wire += "data: " + Self.chunk(reason: "length") + "\n\n"
        wire += "data: {\"choices\":[],\"usage\":{\"completion_tokens\":8192}}\n\n"
        wire += "data: [DONE]\n\n"
        XCTAssertGreaterThan(wire.utf8.count, 512 * 1024, "The old 512 KB cap would have cut this reply off")
        for byte in wire.utf8 { if let event = try decoder.feed(byte) { _ = try stream.accept(event) } }
        let result = try stream.result()
        XCTAssertEqual(result.text.count, 8192)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.completionTokens, 8192)
    }
    func testStallGuardCountsOnlyDataEventsNotKeepalives() throws {
        let start = ContinuousClock.now
        var guardrail = ChatDataStallGuard(limit: .seconds(300), now: start)
        var decoder = ChatSSEDecoder()
        // Keepalives for six minutes: bytes arrive, but no data event.
        for _ in 0..<36 {
            for byte in ": keepalive\n\n".utf8 { if let event = try decoder.feed(byte) { XCTFail("unexpected \(event)") } }
        }
        XCTAssertNoThrow(try guardrail.check(at: start.advanced(by: .seconds(299))))
        XCTAssertThrowsError(try guardrail.check(at: start.advanced(by: .seconds(301)))) {
            XCTAssertEqual($0 as? ChatFailure, .timeout)
        }
        guardrail.noteData(at: start.advanced(by: .seconds(301)))
        XCTAssertNoThrow(try guardrail.check(at: start.advanced(by: .seconds(400))))
    }
    func testContextOverflowGetsItsOwnMessage() throws {
        var stream = ChatStreamAccumulator()
        XCTAssertThrowsError(try stream.accept("{\"error\":{\"code\":\"context_length_exceeded\"}}")) {
            XCTAssertEqual($0 as? ChatFailure, .contextTooLong)
        }
        XCTAssertEqual(ChatFailure.contextTooLong.localizedDescription,
                       "This chat is longer than the model's context; start a new chat or continue with fewer turns.")
    }
    func testCapabilityReadsTheModelContextSize() throws {
        var status = try XCTUnwrap(try JSONSerialization.jsonObject(with: Self.status()) as? [String: Any])
        status["capacity"] = ["max_context_tokens": 32768]
        let parsed = try ChatCapability.parse(capabilities: Self.capability(),
                                              status: try JSONSerialization.data(withJSONObject: status))
        XCTAssertEqual(parsed.maxContextTokens, 32768)
        XCTAssertNil(try ChatCapability.parse(capabilities: Self.capability(), status: Self.status()).maxContextTokens)
    }
    func testKeepaliveCommentIsIgnoredByTheDecoder() throws {
        var decoder = ChatSSEDecoder(); var events: [String] = []
        for byte in ": keepalive\n\ndata: {}\n\n".utf8 { if let event = try decoder.feed(byte) { events.append(event) } }
        XCTAssertEqual(events, ["{}"])
    }
    func testEndpointCannotBecomeRemoteOrInventDefaultPort() throws {
        XCTAssertEqual(try ChatEndpoint(port: 9042).url("/v1/capabilities").absoluteString,
                       "http://127.0.0.1:9042/v1/capabilities")
        XCTAssertThrowsError(try ChatEndpoint(port: 0))
        XCTAssertThrowsError(try ChatEndpoint(port: 65536))
    }
    static func chunk(content: String = "", reasoning: String? = nil, reason: String? = nil) -> String {
        var delta: [String: Any] = ["content": content]
        if let reasoning { delta["reasoning_content"] = reasoning }
        let value: [String: Any] = ["choices": [["index": 0, "delta": delta, "finish_reason": reason as Any? ?? NSNull()]]]
        return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }
    static func capability(modes: [String] = ["auto", "none", "required", "named"]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "local_priority": ["capability": "local_chat_priority_v1", "billable": false, "heartbeat_counted": false, "priority": "customers_first", "preempted_error_code": "local_preempted"],
            "responses": ["available": true, "model": "fixture-model", "generation": 2, "tool_choice_modes": modes]
        ])
    }
    static func status(localUsage: Bool = true, loaded: Bool = true, model: String = "fixture-model") -> Data {
        var value: [String: Any] = ["model": model, "model_loaded": loaded,
                                   "local_status_contract": ["capabilities": ["local_chat_priority_v1"]]]
        if localUsage { value["local_usage"] = ["requests_total": 0, "billable": false, "heartbeat_counted": false, "priority": "customers_first"] }
        return try! JSONSerialization.data(withJSONObject: value)
    }
}
