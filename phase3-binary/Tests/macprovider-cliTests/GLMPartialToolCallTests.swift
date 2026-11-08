import Foundation
import MacProviderCore
@testable import macprovider_cli
import XCTest

/// #2259: GLM-5.3-Flash sometimes writes one malformed call in a multi-call
/// turn. Before the fix the whole output, call markup included, reached
/// `content` with no `tool_calls`. Calls are now parsed one by one, the two
/// observed malformations are repaired, any other is dropped, and markup
/// never reaches content.
final class GLMPartialToolCallTests: XCTestCase {
    private static let model = "Jundot/GLM-5.3-Flash-oQ4e-mtp"
    private static let markup = ["<tool_call>", "</tool_call>", "<arg_key>", "</arg_key>", "<arg_value>", "</arg_value>"]

    /// Buyer output from the issue. The first is cut at `…` in the issue
    /// after the second call's `path` key; its tail here completes that call.
    private static let missingKeyClose = "<tool_call>read<arg_key>limit</arg_key><arg_value>90</arg_value><arg_key>offset</arg_key><arg_value>2350</arg_value><arg_key>path</arg_key><arg_value>…/relay.go</arg_value></tool_call><tool_call>grep<arg_key>head=100</arg_value><arg_key>path</arg_key><arg_value>phase5-gateway</arg_value><arg_key>pattern</arg_key><arg_value>func relay</arg_value></tool_call>"
    private static let strayCloseAfterName = "<tool_call>ls</arg_value><arg_key>path</arg_key><arg_value>…</arg_value></tool_call><tool_call>find<arg_key>pattern</arg_key><arg_value>**/*.md</arg_value></tool_call>"

    private static func property(_ type: String) -> [String: Any] { ["type": type] }

    /// The agent's read/grep/find/ls tools.
    private func request(reasoningOpen: Bool = true) throws -> ChatCompletionRequest {
        let tools: [(String, [String: Any])] = [
            ("read", ["path": Self.property("string"), "offset": Self.property("number"), "limit": Self.property("number")]),
            ("grep", ["pattern": Self.property("string"), "path": Self.property("string"), "head": Self.property("number")]),
            ("find", ["pattern": Self.property("string")]),
            ("ls", ["path": Self.property("string")]),
        ]
        let body: [String: Any] = [
            "model": Self.model,
            "messages": [["role": "user", "content": "look around"]],
            "tools": tools.map { name, properties in
                ["type": "function", "function": ["name": name, "parameters": ["type": "object", "properties": properties]]]
            },
        ]
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .glm, reasoningOpen: reasoningOpen))
        return request
    }

    private func parse(_ output: String, _ request: ChatCompletionRequest) throws -> ModelRuntime.ParsedGeneratedOutput {
        try ModelRuntime.parseGeneratedOutput(
            filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request, mode: .complete(),
            defaultCompletionTokens: 64, toolCallPrefill: nil
        )
    }

    private struct Streamed {
        var content = ""
        var calls: [macprovider_cli.ToolCall] = []
    }

    /// Feeds the output one character at a time, then finishes.
    private func stream(_ output: String, _ request: ChatCompletionRequest) throws -> Streamed {
        var emitter = SerialStreamingTextEmitter(request: request)
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        var result = Streamed()
        for end in 1...output.count {
            _ = emitter.step(
                candidate: (String(output.prefix(end)), false), structuredAccumulator: accumulator, idleState: idle,
                onChunk: { if case .content(let text) = $0 { result.content += text } }
            )
        }
        try emitter.finish(finalText: output, parsed: try parse(output, request), structuredAccumulator: accumulator, idleState: idle, onChunk: {
            if case .content(let text) = $0 { result.content += text }
        })
        result.calls = emitter.reconciledToolCalls
        return result
    }

    private func assertNoMarkup(_ content: String, file: StaticString = #filePath, line: UInt = #line) {
        for marker in Self.markup {
            XCTAssertFalse(content.contains(marker), "\(marker) leaked into \(content)", file: file, line: line)
        }
    }

    private func assertTurn(
        _ answer: String, names: [String], arguments: [String], content: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let output = "Plan the calls.</think>" + answer
        let parsed = try parse(output, try request())
        XCTAssertEqual(parsed.toolCalls.map(\.functionName), names, file: file, line: line)
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), arguments, file: file, line: line)
        XCTAssertEqual(parsed.content, content, file: file, line: line)
        XCTAssertEqual(parsed.reasoningContent, "Plan the calls.", file: file, line: line)
        assertNoMarkup(parsed.content, file: file, line: line)
        let streamed = try stream(output, try request())
        XCTAssertEqual(streamed.calls.map(\.arguments), arguments, file: file, line: line)
        XCTAssertEqual(streamed.content, content, file: file, line: line)
        assertNoMarkup(streamed.content, file: file, line: line)
    }

    // MARK: - Captured buyer output

    /// `<arg_key>head=100</arg_value>`: the key is `head` and its value is
    /// typed by the schema (number).
    func testMissingKeyCloseIsRepairedAndBothCallsReturn() throws {
        try assertTurn(
            Self.missingKeyClose,
            names: ["read", "grep"],
            arguments: [
                #"{"limit":90,"offset":2350,"path":"…/relay.go"}"#,
                #"{"head":100,"path":"phase5-gateway","pattern":"func relay"}"#,
            ],
            content: ""
        )
    }

    /// `<tool_call>ls</arg_value>`: the stray close after the name is dropped.
    func testStrayCloseAfterNameIsRepairedAndBothCallsReturn() throws {
        try assertTurn(
            Self.strayCloseAfterName,
            names: ["ls", "find"],
            arguments: [#"{"path":"…"}"#, #"{"pattern":"**/*.md"}"#],
            content: ""
        )
    }

    func testLeadingProseStaysContent() throws {
        try assertTurn(
            "Listing first." + Self.strayCloseAfterName,
            names: ["ls", "find"],
            arguments: [#"{"path":"…"}"#, #"{"pattern":"**/*.md"}"#],
            content: "Listing first."
        )
    }

    // MARK: - Dropped calls

    /// Every call malformed and unrepairable: no call is made up and content
    /// is the prose outside the call envelopes.
    func testTurnWithOnlyMalformedCallsKeepsOnlyProse() throws {
        try assertTurn(
            "Checking both.<tool_call>read<arg_key>path</arg_key>a.txt</tool_call><tool_call>grep<arg_key>pattern<arg_value>x</arg_value></tool_call>",
            names: [], arguments: [], content: "Checking both."
        )
        try assertTurn(
            "<tool_call>read<arg_key>path</arg_key>a.txt</tool_call><tool_call>grep<arg_key>pattern<arg_value>x</arg_value></tool_call>",
            names: [], arguments: [], content: ""
        )
    }

    func testUnrepairableCallIsDroppedAndTheOthersKeptInOrder() throws {
        try assertTurn(
            "<tool_call>ls<arg_key>path</arg_key><arg_value>a</arg_value></tool_call><tool_call>read<arg_key>path</arg_key>b</tool_call><tool_call>find<arg_key>pattern</arg_key><arg_value>*.go</arg_value></tool_call>",
            names: ["ls", "find"],
            arguments: [#"{"path":"a"}"#, #"{"pattern":"*.go"}"#],
            content: ""
        )
    }

    /// The declared-function check is per call.
    func testUndeclaredCallIsDroppedAlone() throws {
        try assertTurn(
            "<tool_call>rm<arg_key>path</arg_key><arg_value>a</arg_value></tool_call><tool_call>ls<arg_key>path</arg_key><arg_value>b</arg_value></tool_call>",
            names: ["ls"], arguments: [#"{"path":"b"}"#], content: ""
        )
    }

    /// A repaired value is still typed by its schema: `head` is a number.
    func testRepairedValueMustMatchItsSchema() throws {
        try assertTurn(
            "<tool_call>grep<arg_key>head=many</arg_value><arg_key>pattern</arg_key><arg_value>x</arg_value></tool_call><tool_call>ls<arg_key>path</arg_key><arg_value>b</arg_value></tool_call>",
            names: ["ls"], arguments: [#"{"path":"b"}"#], content: ""
        )
    }

    // MARK: - Unchanged paths

    /// A well-formed value holding `=` is not rewritten.
    func testWellFormedValueWithEqualsIsUnchanged() throws {
        try assertTurn(
            "<tool_call>grep<arg_key>pattern</arg_key><arg_value>a=b</arg_value></tool_call>",
            names: ["grep"], arguments: [#"{"pattern":"a=b"}"#], content: ""
        )
    }

    func testOutputWithoutCallsIsUnchanged() throws {
        let parsed = try parse("Plan.</think>The answer.  ", try request())
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.content, "The answer.  ")
    }

    func testRepairs() {
        XCTAssertEqual(
            ToolCallParser.repairedGLMBody("ls</arg_value><arg_key>path</arg_key><arg_value>X</arg_value>"),
            "ls<arg_key>path</arg_key><arg_value>X</arg_value>"
        )
        XCTAssertEqual(
            ToolCallParser.repairedGLMBody("grep<arg_key>head=100</arg_value>"),
            "grep<arg_key>head</arg_key><arg_value>100</arg_value>"
        )
        XCTAssertNil(ToolCallParser.repairedGLMBody("grep<arg_key>pattern</arg_key><arg_value>a=b</arg_value>"))
        XCTAssertNil(ToolCallParser.repairedGLMBody("grep<arg_key>pattern<arg_value>x</arg_value>"))
        XCTAssertNil(ToolCallParser.repairedGLMBody("my tool</arg_value>"))
    }
}
