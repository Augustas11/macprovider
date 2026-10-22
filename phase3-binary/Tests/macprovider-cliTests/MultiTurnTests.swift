import Foundation
import MLXLMCommon
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class MultiTurnTests: XCTestCase {
    func testToolMessageAcceptsAndRendersQwenHistory() throws {
        let request = try Self.request(messages: Self.validMultiTurnMessages())

        XCTAssertEqual(request.messages[1].toolCalls?.first?.id, "call_0123456789abcdef")
        XCTAssertEqual(request.messages[2].toolCallID, "call_0123456789abcdef")

        let rendered = DefaultMessageGenerator().generate(
            messages: try ToolPromptRenderer.renderMessages(request.messages, modelID: "mlx-community/Qwen3-32B-4bit")
        )
        XCTAssertEqual(rendered[1]["role"] as? String, "assistant")
        let call = try XCTUnwrap((rendered[1]["tool_calls"] as? [[String: any Sendable]])?.first)
        XCTAssertEqual((call["function"] as? [String: any Sendable])?["name"] as? String, "lookup")
        XCTAssertEqual(rendered[2]["tool_call_id"] as? String, "call_0123456789abcdef")
        XCTAssertEqual(rendered[2]["content"] as? String, #"{"temperature_c":21}"#)
    }

    /// #2107 D4: every family with a template tool grammar renders history,
    /// Llama 3.x included.
    func testAssistantHistoryRendersLlamaToolTemplate() throws {
        let request = try Self.request(messages: Self.validMultiTurnMessages())
        for model in ["mlx-community/Llama-3.3-70B-Instruct", "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit", "mlx-community/Llama-3.2-3B-Instruct-4bit"] {
            let rendered = DefaultMessageGenerator().generate(messages: try ToolPromptRenderer.renderMessages(request.messages, modelID: model))
            let call = try XCTUnwrap((rendered[1]["tool_calls"] as? [[String: any Sendable]])?.first, model)
            let arguments = (call["function"] as? [String: any Sendable])?["arguments"] as? [String: any Sendable]
            XCTAssertEqual(arguments?["city"] as? String, "Vilnius", model)
        }
    }

    func testUnsupportedModelForMultiTurnFailsBeforeInference() throws {
        let request = try Self.request(messages: Self.validMultiTurnMessages())

        XCTAssertThrowsError(try ToolPromptRenderer.renderMessages(request.messages, modelID: "fixture-model")) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 400)
            XCTAssertEqual(apiError?.code, "unsupported_modelID_for_multi_turn")
        }
    }

    func testSpec018RetryableEnvelopeMap() throws {
        let cases: [(code: String, retryable: Bool)] = [
            ("malformed_tool_call_final_json", true),
            ("provider_stream_downgraded", true),
            ("byte_cap_exceeded", false),
            ("tool_result_too_large", false),
            ("tool_call_arguments_aggregate_too_large", false),
            ("unsupported_modelID_for_multi_turn", false),
        ]

        for tc in cases {
            let error = APIError(status: 400, message: tc.code, code: tc.code)
            let envelope = try XCTUnwrap(error.envelope["error"] as? [String: Any])
            XCTAssertEqual(envelope["retryable"] as? Bool, tc.retryable, tc.code)
            XCTAssertNotNil(envelope["request_id"], tc.code)
            XCTAssertEqual(envelope["inference_ran"] as? Bool, false, tc.code)
            XCTAssertEqual(envelope["settlement_ran"] as? Bool, false, tc.code)
        }
    }

    func testLongCodingAgentSessionIsNotRejectedByMessageCount() throws {
        let messages = (0..<300).map { _ in
            ["role": "user", "content": "hello"]
        }

        XCTAssertNoThrow(try Self.request(messages: messages))
    }

    func testToolResultPerMessageCap() throws {
        var messages = Self.validMultiTurnMessages()
        messages[2]["content"] = String(repeating: "x", count: 256 * 1024 + 1)

        XCTAssertAPIError(try Self.request(messages: messages), status: 413, code: "tool_result_too_large")
    }

    func testToolCallIDValidationMatrix() throws {
        var missingID = Self.validMultiTurnMessages()
        missingID[2].removeValue(forKey: "tool_call_id")
        XCTAssertAPIError(try Self.request(messages: missingID), status: 400, code: "invalid_tool_call_id")

        var invalidID = Self.validMultiTurnMessages()
        invalidID[2]["tool_call_id"] = "call_short"
        XCTAssertAPIError(try Self.request(messages: invalidID), status: 400, code: "invalid_tool_call_id")

        var notFound = Self.validMultiTurnMessages()
        notFound[2]["tool_call_id"] = "call_missing123456789"
        XCTAssertAPIError(try Self.request(messages: notFound), status: 400, code: "tool_call_id_not_found")

        var duplicate = Self.validMultiTurnMessages()
        duplicate.append(duplicate[2])
        XCTAssertAPIError(try Self.request(messages: duplicate), status: 400, code: "duplicate_tool_call_id")

        let outOfOrder = [Self.validMultiTurnMessages()[2], Self.validMultiTurnMessages()[1]]
        XCTAssertAPIError(try Self.request(messages: outOfOrder), status: 400, code: "tool_call_result_out_of_order")
    }

    func testAssistantArgumentsAggregateAndPerCallCaps() throws {
        var perCall = Self.validMultiTurnMessages()
        perCall[1]["tool_calls"] = [[
            "id": "call_0123456789abcdef",
            "type": "function",
            "function": [
                "name": "lookup",
                "arguments": #"{"blob":""# + String(repeating: "x", count: 1024 * 1024) + #""}"#,
            ],
        ]]
        XCTAssertAPIError(try Self.request(messages: perCall), status: 413, code: "tool_call_arguments_too_large")

        var aggregate = Self.validMultiTurnMessages()
        aggregate[1]["tool_calls"] = (0 ..< 3).map { index in
            [
                "id": "call_" + String(format: "%016d", index),
                "type": "function",
                "function": [
                    "name": "lookup",
                    "arguments": #"{"blob":""# + String(repeating: "x", count: 700 * 1024) + #""}"#,
                ],
            ]
        }
        XCTAssertAPIError(try Self.request(messages: aggregate), status: 413, code: "tool_call_arguments_aggregate_too_large")
    }

    func testPromptHashBindsToolCallIDAndAssistantHistory() throws {
        let base = try Self.request(messages: Self.validMultiTurnMessages())
        var changed = Self.validMultiTurnMessages()
        changed[2]["tool_call_id"] = "call_abcdefabcdefabcd"
        if var calls = changed[1]["tool_calls"] as? [[String: Any]] {
            calls[0]["id"] = "call_abcdefabcdefabcd"
            changed[1]["tool_calls"] = calls
        }
        let changedRequest = try Self.request(messages: changed)

        XCTAssertNotEqual(
            try PromptCanonicalizer.promptHash(for: base),
            try PromptCanonicalizer.promptHash(for: changedRequest)
        )
    }

    private static func validMultiTurnMessages() -> [[String: Any]] {
        [
            ["role": "user", "content": "What is the weather in Vilnius?"],
            [
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": [[
                    "id": "call_0123456789abcdef",
                    "type": "function",
                    "function": [
                        "name": "lookup",
                        "arguments": #"{"city":"Vilnius"}"#,
                    ],
                ]],
            ],
            [
                "role": "tool",
                "tool_call_id": "call_0123456789abcdef",
                "content": #"{"temperature_c":21}"#,
            ],
        ]
    }

    private static func request(messages: [[String: Any]]) throws -> ChatCompletionRequest {
        let data = try JSONSerialization.data(withJSONObject: [
            "model": "mlx-community/Qwen3-32B-4bit",
            "messages": messages,
        ])
        return try ChatCompletionRequest.parse(data: data)
    }

    private func XCTAssertAPIError(
        _ expression: @autoclosure () throws -> ChatCompletionRequest,
        status: Int,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, status, file: file, line: line)
            XCTAssertEqual(apiError?.code, code, file: file, line: line)
        }
    }
}
