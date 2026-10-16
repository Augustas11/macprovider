import Foundation
import XCTest
@testable import macprovider_cli

final class LocalResponsesAdapterTests: XCTestCase {
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func adapter(_ extra: [String: Any] = [:]) throws -> LocalResponsesAdapter {
        try LocalResponsesAdapter(body: data(["model": "test-model", "input": "hello"].merging(extra) { _, new in new }))
    }
    private func fixtures() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("test/fixtures/local-responses-contract.json"))) as! [String: Any]
    }
    private func payloads(_ frames: [String]) throws -> [[String: Any]] {
        try frames.flatMap { $0.components(separatedBy: "\n") }.filter { $0.hasPrefix("data: ") && $0 != "data: [DONE]" }.map {
            try JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as! [String: Any]
        }
    }
    /// Generated IDs/timestamps are deliberately absent from fixture subsets.
    /// Arrays still compare exact length/order so extra or reordered output fails.
    private func assertSubset(_ expected: Any, actual: Any?, path: String) throws {
        if let expected = expected as? [String: Any] {
            XCTAssertEqual(actual is [String: Any], true, path)
            guard let actual = actual as? [String: Any] else { return }
            for (key, value) in expected {
                XCTAssertEqual(actual.keys.contains(key), true, "\(path).\(key) missing")
                try assertSubset(value, actual: actual[key], path: "\(path).\(key)")
            }
        } else if let expected = expected as? [Any] {
            XCTAssertEqual(actual is [Any], true, path)
            guard let actual = actual as? [Any] else { return }
            XCTAssertEqual(actual.count, expected.count, path)
            for (index, pair) in zip(expected, actual).enumerated() {
                try assertSubset(pair.0, actual: pair.1, path: "\(path)[\(index)]")
            }
        } else {
            XCTAssertEqual(try data(["value": actual ?? NSNull()]), try data(["value": expected]), path)
        }
    }
    func testSharedRequestContracts() throws {
        for fixture in try fixtures()["requests"] as! [[String: Any]] {
            let name = fixture["name"] as! String
            if let code = fixture["error_code"] as? String {
                XCTAssertThrowsError(try LocalResponsesAdapter(body: data(fixture["request"]!)), name) { XCTAssertEqual(($0 as? LocalResponsesError)?.code, code, name) }
            } else {
                let translated = try LocalResponsesAdapter(body: data(fixture["request"]!))
                let chat = try JSONSerialization.jsonObject(with: translated.chatRequestBody) as! [String: Any]
                for (key, value) in fixture["chat"] as! [String: Any] {
                    XCTAssertEqual(try data([key: chat[key]!]), try data([key: value]), "\(name):\(key)")
                }
            }
        }
    }
    func testSharedStreamContracts() throws {
        for fixture in try fixtures()["streams"] as! [[String: Any]] {
            let adapter = try adapter(["stream": true])
            var frames = adapter.startStream()
            for chunk in fixture["chunks"] as! [[String: Any]] {
                let frame = "data: \(String(decoding: try data(chunk), as: UTF8.self))\n\n"
                // Fragment transport writes inside JSON to exercise buffering.
                let split = frame.index(frame.startIndex, offsetBy: frame.count / 2)
                frames += adapter.consumeStream(String(frame[..<split]))
                frames += adapter.consumeStream(String(frame[split...]))
            }
            frames += adapter.consumeStream("data: [DONE]\n\n")
            frames += adapter.finishStream()
            let events = try payloads(frames)
            let terminals = events.filter { ["response.completed", "response.failed", "response.incomplete"].contains($0["type"] as? String ?? "") }
            XCTAssertEqual(terminals.count, 1, fixture["name"] as! String)
            XCTAssertEqual(terminals.first?["type"] as? String, fixture["terminal"] as? String)
            XCTAssertEqual(events.compactMap { $0["type"] as? String }, fixture["event_types"] as? [String], fixture["name"] as! String)
            try assertSubset(fixture["response"]!, actual: terminals.first?["response"], path: fixture["name"] as! String)
            XCTAssertEqual(events.filter { $0["type"] as? String == fixture["delta_type"] as? String }.compactMap { $0["delta"] as? String }.joined(), fixture["delta"] as? String)
            XCTAssertEqual(events.compactMap { $0["sequence_number"] as? Int }, Array(1...events.count))
            XCTAssertEqual(frames.filter { $0 == "data: [DONE]\n\n" }.count, 1)
        }
    }
    func testSharedNonStreamingContracts() throws {
        for fixture in try fixtures()["nonstream"] as! [[String: Any]] {
            let adapter = try LocalResponsesAdapter(body: data(fixture["request"]!))
            let result = try JSONSerialization.jsonObject(with: adapter.translateResponse(data(fixture["chat_response"]!)))
            try assertSubset(fixture["response"]!, actual: result, path: fixture["name"] as! String)
        }
    }
    func testRejectsMalformedUnsupportedAndAmbiguousRequests() throws {
        for body in [#"{"model":"m","input":"x","store":true,"store":false}"#, #"{"model":"m","input":"x","stream":1}"#, #"{"model":"m","input":"x","unknown":true}"#, #"{"model":"m","input":[{"type":"input_image","image_url":"secret"}]}"#, #"{"model":"m","input":"x","text":{"format":{"type":"bogus"}}}"#] {
            XCTAssertThrowsError(try LocalResponsesAdapter(body: Data(body.utf8)))
        }
        XCTAssertThrowsError(try adapter(["input": [["role": "user", "content": [["type": "input_image", "image_url": "x"]]]]]))
        for field in ["input_image", "image_url", "input_audio", "input_file"] {
            XCTAssertThrowsError(try adapter(["input": [["role": "user", "content": [["type": "input_text", "text": "hello", field: "unsupported"]]]]]))
        }
        XCTAssertThrowsError(try adapter(["text": ["format": ["type": "text", "verbosity": "high"]]]))
        XCTAssertThrowsError(try adapter(["tools": [["type": "web_search"]]]))
        XCTAssertThrowsError(try adapter(["tool_choice": "required"]))
        XCTAssertThrowsError(try adapter(["tools": [["type": "function", "name": "weather"]], "tool_choice": ["type": "function", "name": "weather", "namespace": "other"]]))
        XCTAssertThrowsError(try adapter(["reasoning": ["effort": "high"]]))
        for metadata in [42, "string", ["array"]] as [Any] {
            XCTAssertThrowsError(try adapter(["metadata": metadata]))
        }
        for field in ["type", "role"] {
            for value in [42, true, NSNull(), ["array"]] as [Any] {
                XCTAssertThrowsError(try adapter(["input": [[field: value, "content": "hello"]]]))
            }
        }
        _ = try adapter(["metadata": ["trace": "test"]])
        _ = try adapter(["metadata": NSNull()])
    }
    func testEOFAndMalformedStreamFailExactlyOnce() throws {
        for tail in ["", "data: [DONE]\n\n", "data: broken\n\n"] {
            let adapter = try adapter(["stream": true])
            var frames = adapter.consumeStream("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n")
            frames += adapter.consumeStream(tail)
            frames += adapter.finishStream()
            frames += adapter.finishStream()
            let events = try payloads(frames)
            XCTAssertEqual(events.filter { $0["type"] as? String == "response.failed" }.count, 1)
            XCTAssertFalse(events.contains { $0["type"] as? String == "response.completed" })
        }
    }
    func testThinkTagsSplitAcrossChunksStayPrivate() throws {
        let adapter = try adapter(["stream": true])
        var frames: [String] = []
        for text in ["hello<th", "ink>secret", "</thi", "nk> world"] {
            frames += adapter.consumeStream("data: \(String(decoding: try data(["choices": [["delta": ["content": text]]]]), as: UTF8.self))\n\n")
        }
        frames += adapter.consumeStream("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
        let events = try payloads(frames)
        XCTAssertEqual(events.filter { $0["type"] as? String == "response.output_text.delta" }.compactMap { $0["delta"] as? String }.joined(), "hello world")
        XCTAssertFalse(frames.joined().contains("secret"))
    }
    func testNonStreamingToolsUsageAndIncomplete() throws {
        let adapter = try adapter()
        let body: [String: Any] = ["choices": [["message": ["content": "<think>private</think>hello", "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "weather", "arguments": "{}"]]]], "finish_reason": "length"]], "usage": ["prompt_tokens": 4, "completion_tokens": 2, "total_tokens": 6]]
        let result = try JSONSerialization.jsonObject(with: adapter.translateResponse(data(body))) as! [String: Any]
        XCTAssertEqual(result["status"] as? String, "incomplete")
        let output = result["output"] as! [[String: Any]]
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual((output[0]["content"] as? [[String: Any]])?.first?["text"] as? String, "hello")
        XCTAssertEqual(output[1]["call_id"] as? String, "call_1")
        XCTAssertEqual((result["usage"] as? [String: Any])?["input_tokens"] as? Int, 4)
    }
}
