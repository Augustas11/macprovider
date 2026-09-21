import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class SerialToolTurnTests: XCTestCase {
    private let twoCalls = #"""
    <tool_call>{"name":"find_definition","arguments":{"symbol":"ToolCallParser"}}</tool_call>
    leftover junk
    <tool_call>{"name":"list_references","arguments":{"symbol":"ToolCallParser"}}</tool_call>
    """#

    func testOmittedParallelKeepsOnlyFirstTool() throws {
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: twoCalls,
            generatedTokenIDs: [],
            decode: { _ in "" },
            request: try request(parallelToolCalls: nil),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: 12
        )
        XCTAssertEqual(parsed.toolCalls.map(\.functionName), ["find_definition"])
        XCTAssertEqual(parsed.generatedCompletionTokens, 12)
        XCTAssertEqual(parsed.content, "")
    }

    func testParallelTruePreservesBothToolsInOrder() throws {
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: twoCalls,
            generatedTokenIDs: [],
            decode: { _ in "" },
            request: try request(parallelToolCalls: true),
            mode: .complete(finishReason: "stop"),
            defaultCompletionTokens: 12
        )
        XCTAssertEqual(
            parsed.toolCalls.map(\.functionName),
            ["find_definition", "list_references"]
        )
    }

    func testSerialStopPredicateRequiresCompletedCall() throws {
        var emitter = NativeToolCallStreamEmitter(
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: ["read"]
        )
        let serial = try request(parallelToolCalls: nil)
        XCTAssertFalse(serial.stopsAfterFirstCompleteToolCall && emitter.hasCompletedValidToolCall)
        _ = emitter.observe(#"<tool_call>{"name":"read","arguments":{"path":"Makefile"}}"#)
        XCTAssertTrue(serial.stopsAfterFirstCompleteToolCall && emitter.hasCompletedValidToolCall)
        let parallel = try request(parallelToolCalls: true)
        XCTAssertFalse(parallel.stopsAfterFirstCompleteToolCall && emitter.hasCompletedValidToolCall)
    }

    private func request(parallelToolCalls: Bool?) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                functionTool("find_definition"),
                functionTool("list_references"),
                functionTool("read"),
            ],
        ]
        if let parallelToolCalls {
            body["parallel_tool_calls"] = parallelToolCalls
        }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    private func functionTool(_ name: String) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "parameters": ["type": "object", "properties": [:] as [String: Any]],
            ],
        ]
    }
}
