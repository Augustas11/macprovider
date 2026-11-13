import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

/// #2189: MiniMax M3.1-Flash output. The outputs follow the served
/// `chat_template.jinja` (byte-identical to `MiniMaxAI/MiniMax-M3.1-Flash`):
/// adaptive `<mm:think>…</mm:think>` reasoning and namespaced tool calls.
final class MiniMaxOutputTests: XCTestCase {
    private static let model = "mlx-community/MiniMax-M3.1-Flash-oQ3e-mtp"
    private static let ns = "]<]minimax[>["

    private static func invoke(_ name: String, _ arguments: [(String, String)]) -> String {
        ns + "<invoke name=\"" + name + "\">"
            + arguments.map { ns + "<" + $0.0 + ">" + $0.1 + ns + "</" + $0.0 + ">" }.joined()
            + ns + "</invoke>\n"
    }

    private static func wrapper(_ invokes: String...) -> String {
        ns + "<tool_call>\n" + invokes.joined() + ns + "</tool_call>"
    }

    private static let readHosts = invoke("read_file", [("path", "/etc/hosts")])
    private static let readPasswd = invoke("read_file", [("path", "/etc/passwd")])

    private static let tools: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "read_file", "description": "Read a file from disk",
            "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]],
        ]],
        ["type": "function", "function": [
            "name": "search", "parameters": ["type": "object", "properties": [
                "query": ["type": "string"], "limit": ["type": "integer"], "exact": ["type": "boolean"],
                "filters": ["type": "object", "properties": ["lang": ["type": "string"], "tags": ["type": "array", "items": ["type": "string"]]]],
            ]],
        ]],
    ]

    private func makeRequest(tools: Bool, stream: Bool = true, resolve: Bool = true) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": Self.model,
            "messages": [["role": "user", "content": "Read /etc/hosts and /etc/passwd."]],
            "stream": stream,
        ]
        if tools { body["tools"] = Self.tools }
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
        if resolve { request.outputState.resolve(RequestOutputTraits(toolGrammar: .minimax)) }
        return request
    }

    private func parse(_ output: String, allowed: Set<String>? = ["read_file", "search"]) -> ToolCallParser.ParsedToolCalls {
        let schemas: [String: JSONValue] = [
            "read_file": .object(["type": .string("object"), "properties": .object(["path": .object(["type": .string("string")])])]),
            "search": .object(["type": .string("object"), "properties": .object([
                "query": .object(["type": .string("string")]), "limit": .object(["type": .string("integer")]),
                "exact": .object(["type": .string("boolean")]),
                "filters": .object(["type": .string("object"), "properties": .object([
                    "lang": .object(["type": .string("string")]),
                    "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                ])]),
            ])]),
        ]
        return ToolCallParser.parseToolCalls(rawOutput: output, grammar: .minimax, modelID: Self.model,
                                             allowedFunctionNames: allowed, schemas: schemas)
    }

    // MARK: Family

    func testFamilyWinsOverTheGuessedTemplateFormat() {
        // The fork infers `json` from this template (`<tool_call>` and
        // `tool_call.name`); the MiniMax family decides.
        for id in [Self.model, "minimaxai/minimax-m3.1-flash", "minimax/minimax-m3.1-flash"] {
            XCTAssertEqual(ToolCallGrammar.family(modelID: id), .minimax, id)
            XCTAssertEqual(ToolCallGrammar.resolved(templateFormat: "json", modelID: id), .minimax, id)
        }
        XCTAssertNil(ToolCallGrammar.family(modelID: "MiniMaxAI/MiniMax-M2.5"))
        XCTAssertEqual(ToolSelectionPolicy.modes(modelID: Self.model, runtime: "mlx_cache"), ["auto", "none", "required", "named"])
    }

    // MARK: Reasoning

    /// (output, reasoning, answer, closed, reasoned)
    private static let reasoningCases: [(String, String, String, Bool, Bool)] = [
        ("<mm:think>17*23: 17*20=340, 17*3=51, 391.</mm:think>\n\n391", "17*23: 17*20=340, 17*3=51, 391.", "391", true, true),
        ("</mm:think>391", "", "391", true, false),
        ("391", "", "391", true, false),
        ("\n<mm:think>\nOK\n</mm:think>Done.", "\nOK\n", "Done.", true, true),
        ("<mm:think>17*23 is 17*20 plus", "17*23 is 17*20 plus", "", false, true),
        ("Use <mm:think> tags.", "", "Use <mm:think> tags.", true, false),
    ]

    func testFinalSplit() {
        for (output, reasoning, answer, closed, reasoned) in Self.reasoningCases {
            let split = ReasoningOutput.MiniMax.split(output)
            XCTAssertEqual(split, ReasoningOutput.Split(reasoning: reasoning, answer: answer, closed: closed), output)
            XCTAssertEqual(ReasoningOutput.MiniMax.reasoned(output), reasoned, output)
        }
    }

    func testNonStreamingSplitsReasoningOffContent() throws {
        let request = try makeRequest(tools: false, stream: false)
        for (output, reasoning, answer, _, reasoned) in Self.reasoningCases {
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request,
                mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
            XCTAssertEqual(parsed.content, answer, output)
            XCTAssertEqual(parsed.reasoningContent, reasoned ? reasoning : nil, output)
            XCTAssertFalse(parsed.content.contains("mm:think>") && reasoned, output)
        }
        // Family fallback when the template grammar was not recorded.
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: Self.reasoningCases[0].0, generatedTokenIDs: [], decode: { _ in "" },
            request: makeRequest(tools: false, stream: false, resolve: false),
            mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
        XCTAssertEqual(parsed.content, "391")
    }

    func testReasoningTokenCount() {
        // One token per Character: the count runs through `</mm:think>`.
        let think = Array("<mm:think>ab</mm:think>cd").map(String.init)
        let decode: ([Int]) -> String = { ids in ids.map { think[$0] }.joined() }
        XCTAssertEqual(ReasoningOutput.MiniMax.reasoningTokenCount(tokenIDs: Array(think.indices), decode: decode), 23)
        let noThink = Array("</mm:think>cd").map(String.init)
        XCTAssertEqual(ReasoningOutput.MiniMax.reasoningTokenCount(tokenIDs: Array(noThink.indices), decode: { $0.map { noThink[$0] }.joined() }), 0)
        let open = Array("<mm:think>abc").map(String.init)
        XCTAssertEqual(ReasoningOutput.MiniMax.reasoningTokenCount(tokenIDs: Array(open.indices), decode: { $0.map { open[$0] }.joined() }), 13)
    }

    /// Streams `output` in `chunk`-Character steps through the emitter (its
    /// incremental and whole-text forms) and returns what reached the buyer.
    private func stream(_ output: String, request: ChatCompletionRequest, chunk: Int, reference: Bool)
        throws -> (reasoning: String, content: String, calls: [String], sawMarkup: Bool) {
        var emitter = SerialStreamingTextEmitter(request: request)
        if reference { emitter = emitter.usingReferenceText() }
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        var reasoning = "", content = "", sawMarkup = false
        let collect: (StreamChunk) -> Void = {
            switch $0 {
            case .reasoning(let text): reasoning += text
            case .content(let text):
                content += text
                // Markup may not stream, even partially.
                if content.contains("mm:think>") || content.contains("]<]") { sawMarkup = true }
            default: break
            }
        }
        var end = 0
        while end < output.count {
            end = min(output.count, end + chunk)
            _ = emitter.step(candidate: (String(output.prefix(end)), false), structuredAccumulator: accumulator, idleState: idle, onChunk: collect)
        }
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request,
            mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
        try emitter.finish(finalText: output, parsed: parsed, structuredAccumulator: accumulator, idleState: idle, onChunk: collect)
        return (reasoning, content, emitter.reconciledToolCalls.map(\.arguments), sawMarkup)
    }

    func testStreamingSplitsReasoningWithMarkersAcrossChunks() throws {
        let request = try makeRequest(tools: false)
        for (output, reasoning, answer, _, _) in Self.reasoningCases {
            // Chunks of 1, 3 and 7 Characters cut both tags at every offset.
            for chunk in [1, 3, 7, output.count] {
                for reference in [false, true] {
                    let streamed = try stream(output, request: request, chunk: chunk, reference: reference)
                    XCTAssertEqual(streamed.reasoning, reasoning, "\(output) chunk \(chunk)")
                    XCTAssertEqual(streamed.content, answer, "\(output) chunk \(chunk)")
                    XCTAssertFalse(streamed.sawMarkup && !output.hasPrefix("Use"), "\(output) chunk \(chunk)")
                }
            }
        }
    }

    func testStreamingPrefixHoldsAnUndecidedLead() {
        for prefix in ["", " \n", "<", "<mm:th", "</mm:thi"] {
            XCTAssertEqual(ReasoningOutput.MiniMax.splitStreamingPrefix(prefix), ReasoningOutput.Split(reasoning: "", answer: "", closed: false), prefix)
        }
        XCTAssertEqual(ReasoningOutput.MiniMax.splitStreamingPrefix("<mm:think>abc</mm:th"),
                       ReasoningOutput.Split(reasoning: "abc", answer: "", closed: false))
        XCTAssertEqual(ReasoningOutput.MiniMax.splitStreamingPrefix("<b>bold"), ReasoningOutput.Split(reasoning: "", answer: "<b>bold", closed: true))
        var incremental = IncrementalMiniMaxReasoningSplit()
        let output = "<mm:think>abc</mm:think> answer"
        for end in 0...output.count {
            let prefix = String(output.prefix(end))
            XCTAssertEqual(incremental.splitStreamingPrefix(prefix), ReasoningOutput.MiniMax.splitStreamingPrefix(prefix), prefix)
        }
    }

    func testOtherFamiliesKeepTheirSplit() throws {
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "mlx-community/Qwen3-8B-4bit", "messages": [["role": "user", "content": "hi"]],
        ]))
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: "<mm:think>x</mm:think>y", generatedTokenIDs: [], decode: { _ in "" }, request: request,
            mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
        XCTAssertEqual(parsed.content, "<mm:think>x</mm:think>y")
        XCTAssertNil(parsed.reasoningContent)
    }

    // MARK: Tool calls

    func testSingleAndMultipleCalls() {
        let one = parse(Self.wrapper(Self.readHosts))
        XCTAssertEqual(one.toolCalls.map(\.functionName), ["read_file"])
        XCTAssertEqual(one.toolCalls.map(\.arguments), [#"{"path":"/etc/hosts"}"#])
        XCTAssertNil(one.leadingContent)

        let two = parse("I'll read both.\n" + Self.wrapper(Self.readHosts, Self.readPasswd))
        XCTAssertEqual(two.toolCalls.map(\.arguments), [#"{"path":"/etc/hosts"}"#, #"{"path":"/etc/passwd"}"#])
        XCTAssertEqual(two.leadingContent, "I'll read both.\n")
        XCTAssertNotEqual(two.toolCalls[0].id, two.toolCalls[1].id)

        // Two wrappers, prose between them dropped.
        let wrappers = parse(Self.wrapper(Self.readHosts) + "\nand\n" + Self.wrapper(Self.readPasswd))
        XCTAssertEqual(wrappers.toolCalls.count, 2)
    }

    func testValuesAreTypedAndNestedElementsExpand() throws {
        let filters = Self.ns + "<lang>swift" + Self.ns + "</lang>" + Self.ns + "<tags>"
            + Self.ns + "<item>a" + Self.ns + "</item>" + Self.ns + "<item>b" + Self.ns + "</item>" + Self.ns + "</tags>"
        let output = Self.wrapper(Self.invoke("search", [("query", "42"), ("limit", "5"), ("exact", "true"), ("filters", filters)]))
        let call = try XCTUnwrap(parse(output).toolCalls.first)
        XCTAssertEqual(call.arguments, #"{"exact":true,"filters":{"lang":"swift","tags":["a","b"]},"limit":5,"query":"42"}"#)
        // Undeclared: JSON when it parses, items as an array, else text.
        let loose = parse(Self.wrapper(Self.invoke("other", [("n", "3"), ("list", Self.ns + "<item>x" + Self.ns + "</item>"), ("s", "hi")])),
                          allowed: ["other"])
        XCTAssertEqual(loose.toolCalls.first?.arguments, #"{"list":["x"],"n":3,"s":"hi"}"#)
        // A declared integer that is not one drops the call.
        XCTAssertTrue(parse(Self.wrapper(Self.invoke("search", [("limit", "five")]))).toolCalls.isEmpty)
    }

    func testMalformedInvokeIsDroppedAndOthersKept() {
        let broken = Self.ns + "<invoke name=\"read_file\">" + Self.ns + "<path>/etc/hosts" + Self.ns + "</invoke>\n"
        let parsed = parse(Self.wrapper(broken, Self.readPasswd))
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"path":"/etc/passwd"}"#])
        // Undeclared names are dropped; none surviving leaves only prose.
        let undeclared = parse("Sure. " + Self.wrapper(Self.invoke("rm_rf", [("path", "/")])))
        XCTAssertTrue(undeclared.toolCalls.isEmpty)
        XCTAssertTrue(undeclared.droppedMalformedCalls)
        XCTAssertEqual(undeclared.cleanedContent, "Sure. ")
    }

    func testUnclosedWrapperKeepsOnlyCompleteInvokes() {
        // The end-of-turn token replaced the wrapper close.
        let complete = parse(Self.ns + "<tool_call>\n" + Self.readHosts)
        XCTAssertEqual(complete.toolCalls.map(\.arguments), [#"{"path":"/etc/hosts"}"#])
        // Cut inside the second invoke (finish_reason length).
        let cut = parse(Self.ns + "<tool_call>\n" + Self.readHosts + Self.ns + "<invoke name=\"read_file\">" + Self.ns + "<path>/etc/pa")
        XCTAssertEqual(cut.toolCalls.map(\.arguments), [#"{"path":"/etc/hosts"}"#])
        // A repeated opener in an unclosed wrapper drops it whole.
        let reopened = parse(Self.ns + "<tool_call>\n" + Self.readHosts + Self.ns + "<tool_call>\n")
        XCTAssertTrue(reopened.toolCalls.isEmpty)
        XCTAssertNil(reopened.cleanedContent)
    }

    func testMarkupNeverReachesContent() {
        // An invoke without its wrapper: no call, and no markup as content.
        let bare = parse("Reading. " + Self.readHosts)
        XCTAssertTrue(bare.toolCalls.isEmpty)
        XCTAssertEqual(bare.cleanedContent, "Reading. /etc/hosts\n")
        XCTAssertFalse(bare.cleanedContent?.contains("]<]") ?? false)
        XCTAssertEqual(ToolCallParser.miniMaxStreamableProse("Hello ]<]mini"), "Hello ")
        XCTAssertEqual(ToolCallParser.miniMaxStreamableProse("Hello ]<]minimax[>[<tool_call>"), "Hello ")
        XCTAssertEqual(ToolCallParser.miniMaxStreamableProse("  "), "")
    }

    func testThinkThenToolCallsNonStreamingAndStreaming() throws {
        let reasoning = "The user wants two files. I can call read_file twice."
        let output = "<mm:think>" + reasoning + "</mm:think>\n" + Self.wrapper(Self.readHosts, Self.readPasswd)
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: makeRequest(tools: true, stream: false),
            mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
        XCTAssertEqual(parsed.reasoningContent, reasoning)
        XCTAssertEqual(parsed.content, "")
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"path":"/etc/hosts"}"#, #"{"path":"/etc/passwd"}"#])

        let request = try makeRequest(tools: true)
        for output in [output, "</mm:think>" + Self.wrapper(Self.readHosts), "Reading it now.\n" + Self.wrapper(Self.readHosts)] {
            for chunk in [1, 4, output.count] {
                for reference in [false, true] {
                    let streamed = try stream(output, request: request, chunk: chunk, reference: reference)
                    XCTAssertFalse(streamed.sawMarkup, "\(output) chunk \(chunk)")
                    XCTAssertEqual(streamed.calls.first, #"{"path":"/etc/hosts"}"#, "\(output) chunk \(chunk)")
                    XCTAssertEqual(streamed.content, output.hasPrefix("Reading") ? "Reading it now.\n" : "", "\(output) chunk \(chunk)")
                    XCTAssertEqual(streamed.reasoning, output.hasPrefix("<mm:think>") ? reasoning : "", "\(output) chunk \(chunk)")
                }
            }
        }
    }

    func testCallInsideReasoningIsNotACall() throws {
        let request = try makeRequest(tools: true, stream: false)
        let output = "<mm:think>I could write " + Self.wrapper(Self.readHosts) + " but no.</mm:think>No call needed."
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request,
            mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.content, "No call needed.")
        // The serial tool stop ignores it too, whole-text and incremental.
        var observer = NativeToolCallStreamEmitter(modelID: Self.model, grammar: .minimax, allowedFunctionNames: ["read_file"])
        var incrementalObserver = observer
        var stopText = IncrementalToolStopText(observer: incrementalObserver)
        let filter = ModelRuntime.IncrementalStreamFilter(stopTokenFilter: StopTokenFilter(tokens: []), requestStops: [], reasoningOpen: false)
        for end in 1...output.count {
            let prefix = String(output.prefix(end))
            XCTAssertFalse(ModelRuntime.observeSerialToolStop(&observer, decoded: prefix, stopTokenFilter: StopTokenFilter(tokens: []), requestStops: []), prefix)
            XCTAssertFalse(ModelRuntime.observeSerialToolStop(&incrementalObserver, decoded: prefix, filter: filter, stopText: &stopText), prefix)
        }
        // After the reasoning, a complete call stops the turn.
        let calling = "<mm:think>x</mm:think>" + Self.wrapper(Self.readHosts)
        var stopper = NativeToolCallStreamEmitter(modelID: Self.model, grammar: .minimax, allowedFunctionNames: ["read_file"])
        XCTAssertTrue(ModelRuntime.observeSerialToolStop(&stopper, decoded: calling, stopTokenFilter: StopTokenFilter(tokens: []), requestStops: []))
    }

    func testGuaranteedGrammarAcceptsTheTemplateShape() throws {
        let parameters = JSONValue.object(["type": .string("object"), "properties": .object(["path": .object(["type": .string("string")])]),
                                           "required": .array([.string("path")])])
        let automaton = try GrammarTemplates.toolCall(name: "read_file", parameters: parameters, family: .minimax).compile()
        let output = Self.wrapper(Self.readHosts)
        let terminal = try XCTUnwrap(automaton.transition(state: 0, bytes: Array(output.utf8)))
        XCTAssertTrue(automaton.accepting(state: terminal))
        let calls = try ToolCallParser.parseGuaranteedToolCalls(output, grammar: .minimax, modelID: Self.model,
                                                                schemas: ["read_file": parameters])
        XCTAssertEqual(calls.map(\.arguments), [#"{"path":"/etc/hosts"}"#])
    }
}
