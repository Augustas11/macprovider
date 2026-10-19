import Foundation
import MacProviderCore
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

    func testCoderHistoryUsesTemplateXMLWithStrictTypedValues() throws {
        let rendered = try ToolPromptRenderer.renderMessages(history(), modelID: coder)
        XCTAssertEqual(rendered[1].content, "<tool_call>\n<function=lookup>\n<parameter=city>\nParis\n</parameter>\n<parameter=count>\n2\n</parameter>\n<parameter=enabled>\ntrue\n</parameter>\n</function>\n</tool_call>")
        XCTAssertEqual(rendered[2].role.rawValue, "tool")
        XCTAssertEqual(rendered[2].content, "PROFILE_HISTORY_OK", "the native template owns the single tool-response wrapper")
    }

    func testInstructHistoryUsesNativeJSONEnvelopeWithoutTransportFields() throws {
        let rendered = try ToolPromptRenderer.renderMessages(history(), modelID: instruct)
        XCTAssertEqual(rendered[1].content, "<tool_call>\n{\"name\": \"lookup\", \"arguments\": {\"city\":\"Paris\",\"count\":2,\"enabled\":true}}\n</tool_call>")
        XCTAssertEqual(rendered[2].content, "PROFILE_HISTORY_OK")
    }

    func testTransportCallIDDoesNotChangeNativeRenderedHistory() throws {
        for model in [coder, instruct] {
            let first = try ToolPromptRenderer.renderMessages(history(), modelID: model)
            let second = try ToolPromptRenderer.renderMessages(history(id: "call_9026fb38e701423cad3735d32af405b4"), modelID: model)
            XCTAssertEqual(first.map(\.content), second.map(\.content))
        }
    }

    func testLegacyQwen36AndUnqualifiedCopiesRetainTheirHistoryContract() throws {
        for model in [ToolSelectionPolicy.supportedNativeModel, coder + "-copy", instruct.lowercased()] {
            let rendered = try ToolPromptRenderer.renderMessages(history(), modelID: model)
            XCTAssertTrue(rendered[1].content.contains(#""id":"call_0123456789abcdef""#))
            XCTAssertTrue(rendered[2].content.contains("<tool_response id="))
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
