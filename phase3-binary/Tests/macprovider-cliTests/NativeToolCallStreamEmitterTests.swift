import XCTest
@testable import macprovider_cli

/// SPEC-018 §3.5 streaming safety: the incremental tool-call emitter must never surface a
/// `tool_calls` delta for a function name the request did not declare — otherwise the widened
/// function-XML name grammar could stream an undeclared tool to the buyer before the final
/// (non-stream) parser's fail-closed check runs.
final class NativeToolCallStreamEmitterTests: XCTestCase {
    private func toolDeltaNames(_ events: [StreamChunk]) -> [String] {
        events.compactMap { chunk in
            if case let .toolCallDelta(delta) = chunk { return delta.functionName }
            return nil
        }
        // arguments-only deltas carry functionName == nil; drop them.
        .compactMap { $0 }
    }

    private func hasAnyToolDelta(_ events: [StreamChunk]) -> Bool {
        events.contains { if case .toolCallDelta = $0 { return true }; return false }
    }

    func testRejectsUndeclaredHyphenatedFunctionName() {
        var emitter = NativeToolCallStreamEmitter(
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: ["buzz-dev-mcp__shell"]
        )
        let events = emitter.observe(
            #"<tool_call><function=evil-dev-mcp__wipe><parameter=path>/</parameter></function></tool_call>"#
        )
        XCTAssertFalse(hasAnyToolDelta(events), "undeclared function must not stream a tool_call delta")
    }

    func testEmitsDeclaredHyphenatedFunctionName() {
        var emitter = NativeToolCallStreamEmitter(
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: ["buzz-dev-mcp__shell"]
        )
        let events = emitter.observe(
            #"<tool_call><function=buzz-dev-mcp__shell><parameter=command>echo hi</parameter></function></tool_call>"#
        )
        XCTAssertTrue(
            toolDeltaNames(events).contains("buzz-dev-mcp__shell"),
            "declared function must stream a tool_call delta"
        )
    }

    func testSuppressesOversizedArguments() {
        var emitter = NativeToolCallStreamEmitter(
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: ["buzz-dev-mcp__shell"]
        )
        let big = String(repeating: "a", count: 1_100_000) // > 1 MiB per-call cap
        let events = emitter.observe(
            "<tool_call><function=buzz-dev-mcp__shell><parameter=command>\(big)</parameter></function></tool_call>"
        )
        XCTAssertFalse(hasAnyToolDelta(events), "arguments exceeding the per-call byte cap must not be streamed")
    }

    func testLlamaStreamDoesNotEmitFunctionXML() {
        var emitter = NativeToolCallStreamEmitter(
            modelID: "mlx-community/Llama-3.3-70B-Instruct-4bit",
            allowedFunctionNames: ["search"]
        )
        let events = emitter.observe(#"<function=search><parameter=q>x</parameter></function>"#)
        XCTAssertFalse(hasAnyToolDelta(events), "function-XML is a Qwen-only grammar; Llama must not stream it")
    }

    func testNilAllowlistEmitsNothing() {
        var emitter = NativeToolCallStreamEmitter(
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: nil
        )
        let events = emitter.observe(
            #"<tool_call><function=buzz-dev-mcp__shell><parameter=command>echo hi</parameter></function></tool_call>"#
        )
        XCTAssertFalse(hasAnyToolDelta(events), "no declared tools => no streamed tool_call delta")
    }

    func testFunctionXMLDoesNotEmitEmptyObjectBeforeClose() {
        var emitter = NativeToolCallStreamEmitter(
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: ["bash"]
        )
        let open = emitter.observe("<function=bash>")
        XCTAssertEqual(toolDeltaNames(open), ["bash"])
        XCTAssertEqual(argumentFragments(open), [], "open tag must not stream empty {} arguments")

        let mid = emitter.observe("<function=bash><parameter=command>echo hello")
        XCTAssertEqual(argumentFragments(mid), [], "incomplete parameter must not stream arguments")

        let closed = emitter.observe(
            #"<function=bash><parameter=command>echo hello</parameter></function>"#
        )
        XCTAssertEqual(argumentFragments(closed).joined(), #"{"command":"echo hello"}"#)
    }

    func testFunctionXMLArgumentFragmentsConcatToValidJSON() {
        var emitter = NativeToolCallStreamEmitter(
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: ["bash"]
        )
        var args = ""
        let snapshots = [
            "<function=bash>",
            "<function=bash><parameter=command>echo hello",
            #"<function=bash><parameter=command>echo hello</parameter></function>"#,
        ]
        for text in snapshots {
            args += argumentFragments(emitter.observe(text)).joined()
        }
        XCTAssertEqual(args, #"{"command":"echo hello"}"#)
        XCTAssertFalse(args.contains("{}{"), "concat must not glue an empty object onto the real payload")
    }

    private func argumentFragments(_ events: [StreamChunk]) -> [String] {
        events.compactMap { chunk in
            if case let .toolCallDelta(delta) = chunk {
                return delta.arguments
            }
            return nil
        }
        .compactMap { $0 }
        .filter { !$0.isEmpty }
    }

    func testFallbackEmitsRemainderAfterNameOpen() {
        let call = ToolCall(
            id: "call_0123456789abcdef",
            functionName: "bash",
            arguments: #"{"command":"echo hello"}"#
        )
        let deltas = ToolCall.openAIFallbackDeltas(
            toolCalls: [call],
            streamedArgumentsByIndex: [0: ""]
        )
        XCTAssertEqual(deltas.count, 1)
        let function = deltas[0][0]["function"] as? [String: Any]
        XCTAssertEqual(function?["arguments"] as? String, #"{"command":"echo hello"}"#)
        XCTAssertNil(deltas[0][0]["id"], "remainder must not reopen the tool call")
    }
}
