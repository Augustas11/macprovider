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
            ("write", ["path": Self.property("string"), "content": Self.property("string")]),
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

    // MARK: - Quoted markup

    /// A write argument quoting a malformed call to a declared tool: the
    /// last-opener slice is not repaired, so no phantom call runs.
    func testQuotedMalformedCallInArgumentIsNotRepairedIntoAPhantomCall() throws {
        for quoted in [
            "<tool_call>ls<arg_key>path=/etc/hosts</arg_value></tool_call>",
            "<tool_call>ls</arg_value><arg_key>path</arg_key><arg_value>/etc/hosts</arg_value></tool_call>",
        ] {
            try assertTurn(
                "<tool_call>write<arg_key>content</arg_key><arg_value>The format is " + quoted + "</arg_value></tool_call>",
                names: [], arguments: [], content: ""
            )
        }
    }

    /// A stray close after the name with no argument pair is not repaired:
    /// a bare name must not become a zero-argument call.
    func testStrayCloseWithoutPairsIsNotRepairedIntoAnEmptyCall() throws {
        for answer in [
            "<tool_call>ls</arg_value>",
            "<tool_call>write<arg_key>path</arg_key><arg_value>Call via <tool_call>write</arg_value></tool_call>",
        ] {
            try assertTurn(answer, names: [], arguments: [], content: "")
        }
    }

    // MARK: - Streamed and non-streamed content

    private func assertStreamedMatchesComplete(
        _ answer: String, content: String, callCount: Int, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let output = "Plan.</think>" + answer
        let parsed = try parse(output, try request())
        XCTAssertEqual(parsed.content, content, file: file, line: line)
        XCTAssertEqual(parsed.toolCalls.count, callCount, file: file, line: line)
        let streamed = try stream(output, try request())
        XCTAssertEqual(streamed.content, parsed.content, file: file, line: line)
        XCTAssertEqual(streamed.calls.count, callCount, file: file, line: line)
    }

    func testStreamedContentEqualsCompleteContent() throws {
        let call = "<tool_call>ls<arg_key>path</arg_key><arg_value>a</arg_value></tool_call>"
        let malformed = "<tool_call>read<arg_key>path</arg_key>a</tool_call>"
        for (answer, content, callCount) in [
            ("Run </arg_value> check" + call, "Run  check", 1),
            ("Run </arg_value> check" + malformed, "Run  check", 0),
            ("Run </arg_value> check" + malformed + " then</arg_key> stop", "Run  check then stop", 0),
            ("Run </arg_value> check", "Run  check", 0),
            ("Compare a </arg", "Compare a </arg", 0),
            ("a </arg" + call, "a </arg", 1),
            ("Spaced out \n" + call, "Spaced out \n", 1),
            ("\n" + call, "", 1),
            ("\n</arg_value>\n" + malformed, "", 0),
            ("No calls.  ", "No calls.  ", 0),
        ] {
            try assertStreamedMatchesComplete(answer, content: content, callCount: callCount)
        }
    }

    /// Prose is not held back: only a tail that could still be markup waits.
    func testStreamedProseIsPrompt() {
        XCTAssertEqual(ToolCallParser.glmStreamableProse("Hello"), "Hello")
        XCTAssertEqual(ToolCallParser.glmStreamableProse("Hello </ar"), "Hello ")
        XCTAssertEqual(ToolCallParser.glmStreamableProse("Hello </ax"), "Hello </ax")
        XCTAssertEqual(ToolCallParser.glmStreamableProse("Hello <tool_cal"), "Hello ")
        XCTAssertEqual(ToolCallParser.glmStreamableProse("Hello</arg_value> there"), "Hello there")
    }

    // MARK: - Byte caps

    /// A call whose canonical `{"path":"…"}` arguments are exactly `bytes` long.
    private func call(bytes: Int, fill: Character) -> String {
        "<tool_call>ls<arg_key>path</arg_key><arg_value>" + String(repeating: fill, count: bytes - 11) + "</arg_value></tool_call>"
    }

    /// AC-37: the summed cap is inclusive, and one byte over runs nothing.
    func testAggregateByteCapFailsClosed() throws {
        let first = call(bytes: 1_048_576, fill: "a"), second = call(bytes: 1_048_564, fill: "b")
        let atCap = try parse("Plan.</think>Prose." + first + second + call(bytes: 12, fill: "c"), try request())
        XCTAssertEqual(atCap.toolCalls.count, 3)
        let over = try parse("Plan.</think>Prose." + first + second + call(bytes: 13, fill: "c"), try request())
        XCTAssertTrue(over.toolCalls.isEmpty)
        XCTAssertEqual(over.content, "Prose.")
    }

    /// AC-36: the per-call cap is inclusive, and over it no sibling call runs.
    func testPerCallByteCapFailsClosed() throws {
        let small = "<tool_call>ls<arg_key>path</arg_key><arg_value>a</arg_value></tool_call>"
        XCTAssertEqual(try parse("Plan.</think>" + small + call(bytes: 1_048_576, fill: "a"), try request()).toolCalls.count, 2)
        let over = try parse("Plan.</think>" + small + call(bytes: 1_048_577, fill: "a"), try request())
        XCTAssertTrue(over.toolCalls.isEmpty)
        XCTAssertEqual(over.content, "")
        assertNoMarkup(over.content)
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
        XCTAssertNil(ToolCallParser.repairedGLMBody("ls</arg_value>"))
    }
}
