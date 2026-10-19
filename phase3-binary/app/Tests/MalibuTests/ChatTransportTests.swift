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
    func testPreemptionAndTruncationNeverBecomeSuccess() throws {
        var stream = ChatStreamAccumulator()
        _ = try stream.accept(Self.chunk(content: "Partial"))
        XCTAssertThrowsError(try stream.accept("{\"error\":{\"code\":\"local_preempted\"}}")) {
            XCTAssertEqual($0 as? ChatFailure, .preempted)
        }
        XCTAssertThrowsError(try stream.accept(Self.chunk(reason: "length"))) {
            XCTAssertEqual($0 as? ChatFailure, .limit)
        }
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
    func testEndpointCannotBecomeRemoteOrInventDefaultPort() throws {
        XCTAssertEqual(try ChatEndpoint(port: 9042).url("/v1/capabilities").absoluteString,
                       "http://127.0.0.1:9042/v1/capabilities")
        XCTAssertThrowsError(try ChatEndpoint(port: 0))
        XCTAssertThrowsError(try ChatEndpoint(port: 65536))
    }
    static func chunk(content: String = "", reason: String? = nil) -> String {
        let value: [String: Any] = ["choices": [["index": 0, "delta": ["content": content], "finish_reason": reason as Any? ?? NSNull()]]]
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
