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
}
