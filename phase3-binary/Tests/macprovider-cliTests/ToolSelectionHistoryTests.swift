import Foundation
import MacProviderCore
import MLXLMCommon
import XCTest
@testable import macprovider_cli

final class ToolSelectionHistoryTests: XCTestCase {
    private let coder = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
    private let instruct = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"

    private func history(id: String = "call_0123456789abcdef", name: String = "lookup", arguments: String = #"{"city":"Paris","count":2,"enabled":true}"#) throws -> [ChatMessage] {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": coder,
            "messages": [
                ["role": "user", "content": "Look up Paris."],
                ["role": "assistant", "content": "", "tool_calls": [[
                    "id": id, "type": "function", "function": ["name": name, "arguments": arguments],
                ]]],
                ["role": "tool", "tool_call_id": id, "content": "PROFILE_HISTORY_OK"],
            ],
        ])).messages
    }

    /// #2107 D4/D8: history reaches the chat template as structured data; the
    /// template (CatalogToolGrammarTests renders the real ones) owns the call
    /// and result grammar, so nothing is pre-wrapped here.
    func testHistoryIsStructuredForTheTemplate() throws {
        for model in [coder, instruct, ToolSelectionPolicy.supportedNativeModel] {
            let rendered = DefaultMessageGenerator().generate(messages: try ToolPromptRenderer.renderMessages(history(), modelID: model))
            let calls = try XCTUnwrap(rendered[1]["tool_calls"] as? [[String: any Sendable]], model)
            let function = try XCTUnwrap(calls.first?["function"] as? [String: any Sendable])
            XCTAssertEqual(function["name"] as? String, "lookup")
            let arguments = try XCTUnwrap(function["arguments"] as? [String: any Sendable])
            XCTAssertEqual(arguments["city"] as? String, "Paris")
            XCTAssertEqual(arguments["count"] as? Int, 2)
            XCTAssertEqual(arguments["enabled"] as? Bool, true)
            XCTAssertEqual(rendered[2]["role"] as? String, "tool")
            XCTAssertEqual(rendered[2]["content"] as? String, "PROFILE_HISTORY_OK", "the template owns the single tool-response wrapper")
            XCTAssertEqual(rendered[2]["tool_call_id"] as? String, "call_0123456789abcdef")
            XCTAssertEqual(rendered[2]["name"] as? String, "lookup")
        }
    }

    func testXMLHistoryRejectsNamesThatCanBreakTheEnvelope() throws {
        for name in ["bad>name", "bad\nname"] {
            XCTAssertThrowsError(try ToolPromptRenderer.renderMessages(history(name: name), modelID: coder))
        }
        XCTAssertThrowsError(try ToolPromptRenderer.renderMessages(history(arguments: #"{"bad>key":"Paris"}"#), modelID: coder))
    }

    func testInvalidHistoryArgumentsFailAsRequestErrorsBeforeInference() throws {
        for model in [coder, instruct] {
            let messages = try history(arguments: #"{"city":"Paris","city":"London"}"#)
            XCTAssertThrowsError(try ToolPromptRenderer.renderMessages(messages, modelID: model)) { error in
                XCTAssertEqual((error as? APIError)?.status, 400)
                XCTAssertEqual((error as? APIError)?.code, "invalid_tools")
                XCTAssertEqual((error as? APIError)?.inferenceRan, false)
            }
        }
    }
}
