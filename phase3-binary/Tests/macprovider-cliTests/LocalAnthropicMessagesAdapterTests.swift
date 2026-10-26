import Foundation
import XCTest
@testable import macprovider_cli

final class LocalAnthropicMessagesAdapterTests: XCTestCase {
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func adapter(_ extra: [String: Any] = [:]) throws -> LocalAnthropicMessagesAdapter {
        try LocalAnthropicMessagesAdapter(body: data(["model": "glm", "max_tokens": 64, "messages": [["role": "user", "content": "pick"]]].merging(extra) { _, new in new }))
    }
    private func object(_ value: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: value) as! [String: Any] }
    private func events(_ frames: [String]) throws -> [[String: Any]] {
        try frames.flatMap { $0.components(separatedBy: "\n") }.filter { $0.hasPrefix("data: ") }.map { try object(Data($0.dropFirst(6).utf8)) }
    }
    private func chunk(_ value: [String: Any]) throws -> String { "data: \(String(decoding: try data(value), as: UTF8.self))\n\n" }
    private func delta(_ value: [String: Any]) throws -> String { try chunk(["choices": [["delta": value, "finish_reason": NSNull()]]]) }

    // Golden values from gateway TestAnthropicMessagesAcceptsBetaThinkingAndUnknownKeys (#2107).
    func testGatewayThinkingAndToolHistoryGolden() throws {
        let adapter = try adapter([
            "container": "c", "context_management": ["edits": []],
            "system": [["type": "text", "text": "system", "cache_control": ["type": "ephemeral"]]],
            "thinking": ["type": "enabled", "budget_tokens": 2048],
            "messages": [
                ["role": "user", "content": "pick"],
                ["role": "assistant", "content": [["type": "thinking", "thinking": "earlier", "signature": "sig"], ["type": "tool_use", "id": "toolu_a", "name": "lookup", "input": ["q": "x"], "cache_control": ["type": "ephemeral"]]]],
                ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_a", "content": "r", "cache_control": ["type": "ephemeral"]]]]
            ]
        ])
        let chat = try object(adapter.chatRequestBody)
        XCTAssertEqual(chat["reasoning_effort"] as? String, "medium")
        XCTAssertNil(chat["container"]); XCTAssertNil(chat["thinking"])
        let messages = chat["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.map { $0["role"] as! String }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(messages[2]["reasoning_content"] as? String, "earlier")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "toolu_a")
        XCTAssertEqual(messages[3]["content"] as? String, "r")
        let calls = messages[2]["tool_calls"] as! [[String: Any]]
        XCTAssertEqual((calls[0]["function"] as! [String: Any])["arguments"] as? String, #"{"q":"x"}"#)
    }
    func testThinkingBudgetGoldenMapping() throws {
        for (config, effort) in [(["type": "enabled", "budget_tokens": 2048] as [String: Any], "medium"), (["type": "enabled", "budget_tokens": 16384], "high"), (["type": "adaptive"], "medium"), (["type": "disabled"], "low")] {
            XCTAssertEqual(try object(adapter(["thinking": config]).chatRequestBody)["reasoning_effort"] as? String, effort)
        }
    }
    func testToolsChoiceStopsAndErrorResults() throws {
        let chat = try object(adapter([
            "tools": [["name": "lookup", "description": "Find", "input_schema": ["type": "object"]]],
            "tool_choice": ["type": "tool", "name": "lookup", "disable_parallel_tool_use": true], "stop_sequences": ["END"],
            "messages": [["role": "user", "content": [["type": "text", "text": "before"], ["type": "tool_result", "tool_use_id": "t", "content": [["type": "text", "text": "failed"]], "is_error": true], ["type": "text", "text": "after"]]]]
        ]).chatRequestBody)
        XCTAssertEqual(chat["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(chat["stop"] as? [String], ["END"])
        XCTAssertEqual((chat["messages"] as! [[String: Any]]).map { $0["content"] as! String }, ["before", "Tool error: failed", "after"])
        XCTAssertEqual(((chat["tool_choice"] as! [String: Any])["function"] as! [String: Any])["name"] as? String, "lookup")
    }
    func testRejectsInvalidAndUnsupportedShapes() throws {
        for extra: [String: Any] in [
            ["stream": 1], ["max_tokens": true], ["max_tokens": -1], ["max_tokens": 1.5], ["Model": "other"], ["top_k": 1],
            ["stop_sequences": "END"], ["thinking": ["type": "enabled", "budget_tokens": true]], ["tool_choice": ["type": "any"]],
            ["messages": [["role": "user", "content": [["type": "image", "source": [:]]]]]],
            ["messages": [["role": "user", "content": [["type": "text", "text": "safe", "image_url": "lost"]]]]],
            ["messages": [["role": "assistant", "content": [["type": "tool_use", "id": "t", "name": "f", "input": []]]]]]
        ] { XCTAssertThrowsError(try adapter(extra)) }
        XCTAssertThrowsError(try LocalAnthropicMessagesAdapter(body: Data(#"{"model":"m","model":"x","max_tokens":1,"messages":[]}"#.utf8)))
    }
    func testNonstreamGatewayThinkingGoldenAndReasoningPrivacy() throws {
        let response: [String: Any] = ["choices": [["message": ["content": "Blue.", "reasoning_content": "The user asks for a colour."], "finish_reason": "stop"]], "usage": ["prompt_tokens": 4, "completion_tokens": 9]]
        let thinking = try object(adapter(["thinking": ["type": "enabled", "budget_tokens": 2048]]).translateResponse(data(response)))
        let content = thinking["content"] as! [[String: Any]]
        XCTAssertEqual(content.map { $0["type"] as! String }, ["thinking", "text"])
        XCTAssertEqual(content[0]["thinking"] as? String, "The user asks for a colour.")
        XCTAssertEqual(content[1]["text"] as? String, "Blue.")
        XCTAssertEqual((thinking["usage"] as! [String: Any])["input_tokens"] as? Int, 4)
        let plain = try adapter().translateResponse(data(response))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("colour"))
    }
    func testNonstreamToolValidationAndStopSuffix() throws {
        let tool: [String: Any] = ["id": "t", "type": "function", "function": ["name": "f", "arguments": "{}"]]
        let result = try object(adapter().translateResponse(data(["choices": [["message": ["content": NSNull(), "tool_calls": [tool]], "finish_reason": "tool_calls"]]])))
        XCTAssertEqual(result["stop_reason"] as? String, "tool_use")
        XCTAssertEqual((result["content"] as! [[String: Any]])[0]["id"] as? String, "t")
        for args in ["[]", "{", #"{"x":1,"x":2}"#] {
            XCTAssertThrowsError(try adapter().translateResponse(data(["choices": [["message": ["tool_calls": [["id": "t", "function": ["name": "f", "arguments": args]]]], "finish_reason": "tool_calls"]]])))
        }
        let stop = try object(adapter(["stop_sequences": ["END"]]).translateResponse(data(["choices": [["message": ["content": "helloEND"], "finish_reason": "stop"]]])))
        XCTAssertEqual(stop["stop_reason"] as? String, "stop_sequence")
        XCTAssertEqual(stop["stop_sequence"] as? String, "END")
        XCTAssertEqual((stop["content"] as! [[String: Any]])[0]["text"] as? String, "hello")
    }
    func testFragmentedStreamThinkingToolUsageAndTerminal() throws {
        let adapter = try adapter(["thinking": ["type": "enabled"], "stream": true])
        var frames = adapter.startStream()
        let chunks = [
            try delta(["reasoning_content": "think "]), try delta(["reasoning_content": "more"]),
            try delta(["content": "Blue."]),
            try delta(["tool_calls": [["index": 0, "id": "t", "type": "function", "function": ["name": "lookup", "arguments": "{\"q\":"]]]]),
            try delta(["tool_calls": [["index": 0, "function": ["arguments": "\"x\"}"]]]]),
            try chunk(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]),
            try chunk(["choices": [], "usage": ["prompt_tokens": 3, "completion_tokens": 4]]), "data: [DONE]\n\n"
        ]
        for chunk in chunks {
            let split = chunk.index(chunk.startIndex, offsetBy: chunk.count / 2)
            frames += adapter.consumeStream(String(chunk[..<split])); frames += adapter.consumeStream(String(chunk[split...]))
        }
        frames += adapter.finishStream()
        let payloads = try events(frames)
        XCTAssertEqual(payloads.filter { $0["type"] as? String == "message_start" }.count, 1)
        XCTAssertEqual(payloads.filter { $0["type"] as? String == "message_stop" }.count, 1)
        XCTAssertFalse(frames.joined().contains("[DONE]"))
        let starts = payloads.filter { $0["type"] as? String == "content_block_start" }
        XCTAssertEqual(starts.compactMap { ($0["content_block"] as? [String: Any])?["type"] as? String }, ["thinking", "text", "tool_use"])
        XCTAssertEqual(starts.compactMap { $0["index"] as? Int }, [0, 1, 2])
        let terminal = payloads.first { $0["type"] as? String == "message_delta" }!
        XCTAssertEqual((terminal["delta"] as! [String: Any])["stop_reason"] as? String, "tool_use")
        XCTAssertEqual((terminal["usage"] as! [String: Any])["output_tokens"] as? Int, 4)
    }
    func testSplitThinkTagsAndStopsDoNotLeak() throws {
        let adapter = try adapter(["stream": true, "stop_sequences": ["END"]])
        var frames: [String] = []
        for text in ["hi<th", "ink>private", "</thi", "nk>EN", "D"] { frames += adapter.consumeStream(try delta(["content": text])) }
        frames += adapter.consumeStream(try chunk(["choices": [["delta": [:], "finish_reason": "stop"]]]))
        frames += adapter.consumeStream("data: [DONE]\n\n")
        let payloads = try events(frames)
        let text = payloads.compactMap { $0["delta"] as? [String: Any] }.filter { $0["type"] as? String == "text_delta" }.compactMap { $0["text"] as? String }.joined()
        XCTAssertEqual(text, "hi"); XCTAssertFalse(frames.joined().contains("private"))
        XCTAssertEqual((payloads.first { $0["type"] as? String == "message_delta" }!["delta"] as! [String: Any])["stop_sequence"] as? String, "END")
    }
    func testErrorsEOFAndMalformedToolsNeverCompleteOrExposeTools() throws {
        for tail in ["", "data: [DONE]\n\n", "data: broken\n\n", try chunk(["error": ["code": "local_preempted", "message": "Customer priority", "retryable": true]])] {
            let adapter = try adapter(["stream": true])
            var frames = adapter.consumeStream(try delta(["content": "partial"]))
            frames += adapter.consumeStream(tail); frames += adapter.finishStream(); frames += adapter.finishStream()
            let payloads = try events(frames)
            XCTAssertEqual(payloads.filter { $0["type"] as? String == "error" }.count, 1)
            XCTAssertFalse(payloads.contains { $0["type"] as? String == "message_stop" })
        }
        let adapter = try adapter(["stream": true])
        var frames = adapter.consumeStream(try delta(["tool_calls": [["index": 0, "id": "t", "function": ["name": "f", "arguments": "{bad"]]]]))
        frames += adapter.consumeStream(try chunk(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]))
        frames += adapter.consumeStream("data: [DONE]\n\n")
        XCTAssertFalse(frames.joined().contains("tool_use")); XCTAssertTrue(frames.joined().contains("invalid_provider_response"))
    }
    func testAnthropicPreemptionEnvelopeKeepsRetryGuidance() throws {
        let result = try object(LocalAnthropicMessagesAdapter.translateError(data(["error": ["type": "server_error", "code": "local_preempted", "message": "Customer priority", "retryable": true, "inference_ran": true]])))
        XCTAssertEqual(result["type"] as? String, "error")
        let error = result["error"] as! [String: Any]
        XCTAssertEqual(error["type"] as? String, "overloaded_error"); XCTAssertEqual(error["code"] as? String, "local_preempted")
        XCTAssertEqual(error["retryable"] as? Bool, true); XCTAssertEqual(error["inference_ran"] as? Bool, true)
    }
}
