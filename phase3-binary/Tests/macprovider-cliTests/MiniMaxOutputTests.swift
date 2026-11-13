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
        // A block wherever it occurs is reasoning, as the template reads a
        // turn; the text outside the blocks is the answer.
        ("Use <mm:think> tags.", " tags.", "Use ", false, true),
        ("Let me check.\n<mm:think>plan</mm:think>Answer", "plan", "Let me check.\nAnswer", true, true),
        ("<mm:think>a</mm:think>Mid <mm:think>b<mm:think></mm:think> End</mm:think>.", "ab", "Mid End.", true, true),
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
        // A block after prose counts from its open tag.
        let later = Array("xy<mm:think>ab</mm:think>cd").map(String.init)
        XCTAssertEqual(ReasoningOutput.MiniMax.reasoningTokenCount(tokenIDs: Array(later.indices), decode: { $0.map { later[$0] }.joined() }), 23)
        // Two blocks count their own spans, not the answer between them.
        let twice = Array("<mm:think>a</mm:think>" + String(repeating: "x", count: 50) + "<mm:think>b</mm:think>").map(String.init)
        XCTAssertEqual(ReasoningOutput.MiniMax.reasoningTokenCount(tokenIDs: Array(twice.indices), decode: { $0.map { twice[$0] }.joined() }), 44)
        // A tag inside a tool call is no block.
        let call = Array(Self.ns + "<tool_call><mm:think>ab</mm:think>").map(String.init)
        XCTAssertEqual(ReasoningOutput.MiniMax.reasoningTokenCount(tokenIDs: Array(call.indices), decode: { $0.map { call[$0] }.joined() }), 0)
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
            XCTAssertEqual(ReasoningOutput.MiniMax.splitStreamingPrefix(prefix), ReasoningOutput.Split(reasoning: "", answer: "", closed: true), prefix)
        }
        XCTAssertEqual(ReasoningOutput.MiniMax.splitStreamingPrefix("<mm:think>abc</mm:th"),
                       ReasoningOutput.Split(reasoning: "abc", answer: "", closed: false))
        XCTAssertEqual(ReasoningOutput.MiniMax.splitStreamingPrefix("<b>bold"), ReasoningOutput.Split(reasoning: "", answer: "<b>bold", closed: true))
        XCTAssertEqual(ReasoningOutput.MiniMax.splitStreamingPrefix("Hi <mm:th"), ReasoningOutput.Split(reasoning: "", answer: "Hi ", closed: true))
        // The incremental split equals the whole-text one at every prefix,
        // and both only grow.
        let long = "Let me check " + String(repeating: "the file, ", count: 20) + "<mm:think>"
            + String(repeating: "plan step; ", count: 30) + "</mm:think>  Answer " + String(repeating: "x", count: 90)
            + "<mm:think>more</mm:think>\nDone."
        for output in Self.reasoningCases.map(\.0) + ["<mm:think>abc</mm:think> answer", long] {
            var incremental = IncrementalMiniMaxReasoningSplit()
            var previous = ReasoningOutput.Split(reasoning: "", answer: "", closed: true)
            for end in 0...output.count {
                let prefix = String(output.prefix(end))
                let split = ReasoningOutput.MiniMax.splitStreamingPrefix(prefix)
                XCTAssertEqual(incremental.splitStreamingPrefix(prefix), split, prefix)
                XCTAssertTrue(split.reasoning.hasPrefix(previous.reasoning) && split.answer.hasPrefix(previous.answer), prefix)
                previous = split
            }
            XCTAssertEqual(previous, ReasoningOutput.MiniMax.split(output), output)
            XCTAssertEqual(incremental.restartCount, 0, output)
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

    func testProseBetweenInvokesDropsOnlyTheProse() {
        let parsed = parse(Self.wrapper(Self.readHosts, "Now the other one.\n", Self.readPasswd))
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"path":"/etc/hosts"}"#, #"{"path":"/etc/passwd"}"#])
        // Namespaced markup after a close is not prose: that call is malformed.
        let stray = Self.ns + "<invoke name=\"read_file\">" + Self.ns + "<path>/a" + Self.ns + "</path>" + Self.ns + "</invoke>"
            + Self.ns + "<path>/b" + Self.ns + "</path>\n"
        XCTAssertEqual(parse(Self.wrapper(stray, Self.readPasswd)).toolCalls.map(\.arguments), [#"{"path":"/etc/passwd"}"#])
    }

    func testTypeArraysWithStringKeepTextValues() {
        let schemas: [String: JSONValue] = ["f": .object(["type": .string("object"), "properties": .object([
            "code": .object(["type": .array([.string("string"), .string("null")])]),
            "n": .object(["type": .array([.string("integer"), .string("null")])]),
        ])])]
        let output = Self.wrapper(Self.invoke("f", [("code", "42"), ("n", "7")]))
        let parsed = ToolCallParser.parseToolCalls(rawOutput: output, grammar: .minimax, modelID: Self.model,
                                                   allowedFunctionNames: ["f"], schemas: schemas)
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"code":"42","n":7}"#])
        // A nullable type's null is null, for either type.
        let nulls = ToolCallParser.parseToolCalls(rawOutput: Self.wrapper(Self.invoke("f", [("code", "null"), ("n", "null")])), grammar: .minimax,
                                                  modelID: Self.model, allowedFunctionNames: ["f"], schemas: schemas)
        XCTAssertEqual(nulls.toolCalls.map(\.arguments), [#"{"code":null,"n":null}"#])
    }

    /// The speculative collectors do not split MiniMax reasoning: a MiniMax
    /// request decodes on the token iterator.
    func testMiniMaxRequestsNeverTakeTheSpeculativeRoute() throws {
        let body: [String: Any] = ["model": Self.model, "messages": [["role": "user", "content": "hi"]], "temperature": 0.0, "top_p": 1.0]
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(ModelRuntime.speculativeRoute(for: request, draftLoaded: true, numDraftTokens: 3), .tokenIterator)
        // A family the catalog resolved counts too; another family is speculative.
        var other = body
        other["model"] = "target"
        let resolved = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: other))
        XCTAssertEqual(ModelRuntime.speculativeRoute(for: resolved, draftLoaded: true, numDraftTokens: 3), .speculative)
        resolved.outputState.resolve(RequestOutputTraits(toolGrammar: .minimax))
        XCTAssertEqual(ModelRuntime.speculativeRoute(for: resolved, draftLoaded: true, numDraftTokens: 3), .tokenIterator)
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

    func testLongProseBeforeABareInvokeStreamsOnce() throws {
        // Past the incremental cut's hold, the namespace's leading `]` must
        // not be committed apart from the rest of the token.
        let prose = "I will now look at the hosts file to see which names resolve locally, then report back to you."
        XCTAssertGreaterThan(prose.count, 70)
        let request = try makeRequest(tools: true)
        for output in [prose + Self.readHosts, prose + "]" + Self.readHosts, prose + " " + Self.wrapper(Self.readHosts)] {
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request,
                mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
            for chunk in [1, 2, 3, 7] {
                for reference in [false, true] {
                    let streamed = try stream(output, request: request, chunk: chunk, reference: reference)
                    XCTAssertFalse(streamed.sawMarkup, "chunk \(chunk) reference \(reference)")
                    XCTAssertEqual(streamed.content, parsed.content, "chunk \(chunk) reference \(reference)")
                }
            }
        }
        // Every prose length puts the namespace token at every cut offset.
        let letters = String(repeating: "abcdefghij", count: 21)
        for length in 64...200 {
            let output = String(letters.prefix(length)) + Self.readHosts
            let streamed = try stream(output, request: request, chunk: 1, reference: false)
            XCTAssertEqual(streamed.content, String(letters.prefix(length)) + "/etc/hosts\n", "prose \(length)")
        }
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

    /// Round-2 audit A: once a call starts, both tags in a value are text.
    func testReasoningTagsInsideAToolArgumentStayInTheArgument() throws {
        let code = "s = \"<mm:think>x</mm:think>\"; t = \"</mm:think>\""
        let call = Self.wrapper(Self.invoke("read_file", [("path", code)]))
        let expected = try String(data: JSONSerialization.data(withJSONObject: ["path": code], options: .withoutEscapingSlashes), encoding: .utf8)!
        for output in [call, "<mm:think>plan</mm:think>\n" + call, "Writing it.\n" + call] {
            XCTAssertFalse(ReasoningOutput.MiniMax.reasoned(output) && !output.hasPrefix("<mm:think>"), output)
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: makeRequest(tools: true, stream: false),
                mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
            XCTAssertEqual(parsed.toolCalls.map(\.arguments), [expected], output)
            XCTAssertEqual(parsed.reasoningContent ?? "", output.hasPrefix("<mm:think>") ? "plan" : "", output)
            let request = try makeRequest(tools: true)
            for chunk in [1, 5, output.count] {
                for reference in [false, true] {
                    let streamed = try stream(output, request: request, chunk: chunk, reference: reference)
                    XCTAssertEqual(streamed.calls, [expected], "\(output) chunk \(chunk) reference \(reference)")
                    XCTAssertEqual(streamed.reasoning, output.hasPrefix("<mm:think>") ? "plan" : "", "\(output) chunk \(chunk)")
                    XCTAssertEqual(streamed.content, output.hasPrefix("Writing") ? "Writing it.\n" : "", "\(output) chunk \(chunk)")
                }
            }
            // The incremental split equals the whole-text one at every prefix.
            var incremental = IncrementalMiniMaxReasoningSplit()
            for end in 0...output.count {
                let prefix = String(output.prefix(end))
                XCTAssertEqual(incremental.splitStreamingPrefix(prefix), ReasoningOutput.MiniMax.splitStreamingPrefix(prefix), prefix)
            }
            XCTAssertEqual(incremental.restartCount, 0)
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
        let filter = ModelRuntime.IncrementalStreamFilter(stopTokenFilter: StopTokenFilter(tokens: []), requestStops: [], reasoningOpen: .afterMiniMaxThink)
        for end in 1...output.count {
            let prefix = String(output.prefix(end))
            XCTAssertFalse(ModelRuntime.observeSerialToolStop(&observer, decoded: prefix, stopTokenFilter: StopTokenFilter(tokens: []), requestStops: [], reasoningOpen: .afterMiniMaxThink), prefix)
            XCTAssertFalse(ModelRuntime.observeSerialToolStop(&incrementalObserver, decoded: prefix, filter: filter, stopText: &stopText, reasoningOpen: .afterMiniMaxThink), prefix)
        }
        // After the reasoning, a complete call stops the turn.
        let calling = "<mm:think>x</mm:think>" + Self.wrapper(Self.readHosts)
        var stopper = NativeToolCallStreamEmitter(modelID: Self.model, grammar: .minimax, allowedFunctionNames: ["read_file"])
        XCTAssertTrue(ModelRuntime.observeSerialToolStop(&stopper, decoded: calling, stopTokenFilter: StopTokenFilter(tokens: []), requestStops: [], reasoningOpen: .afterMiniMaxThink))
    }

    // MARK: Special-token parameter keys

    /// Added tokens of `MiniMaxAI/MiniMax-M3.1-Flash` `tokenizer_config.json`
    /// (ids and `special` flags as published): code-pretraining tags that are
    /// special, and the call markup that is not.
    private static let addedTokens: [(id: Int, content: String, special: Bool)] = [
        (200005, "<reponame>", true), (200006, "<filename>", true), (200017, "<commit_msg>", true),
        (200019, "]~b]", true), (200020, "[e~[", true), (200022, "<function_call>", true),
        (200023, "<code_interpreter>", true), (200036, "<add_file>", true), (200037, "<delete_file>", true),
        (200038, "<rename_file>", true), (200039, "<edit_file>", true), (200040, "<commit_message>", true),
        (200044, "<file_content>", true), (200045, "<source_files>", true), (200048, "<filepath>", true),
        (200050, "<think>", false), (200051, "</think>", false), (200052, "<tool_call>", false),
        (200053, "</tool_call>", false), (200058, "]<]minimax[>[", false), (200059, "<mm:think>", false),
        (200060, "</mm:think>", false),
    ]

    /// The served row's filters: the tokenizer config's stop tokens with the
    /// MiniMax tool-aware exemption, and the control-token table.
    private func servedFilters() throws -> (stop: StopTokenFilter, control: ControlTokenTable) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minimax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var decoder: [String: Any] = [:]
        for token in Self.addedTokens {
            decoder[String(token.id)] = ["content": token.content, "special": token.special, "lstrip": false, "rstrip": false,
                                         "normalized": false, "single_word": false]
        }
        let url = directory.appendingPathComponent("tokenizer_config.json")
        try JSONSerialization.data(withJSONObject: [
            "added_tokens_decoder": decoder, "bos_token": "]~b]", "eos_token": "[e~[",
        ]).write(to: url)
        let stop = ModelRuntime.toolAwareStopTokenFilter(try StopTokenConfigExtractor.extract(fromTokenizerConfigAt: url), grammar: .minimax)
        let control = ControlTokenTable(
            addedTokens: Self.addedTokens.map { .init(content: $0.content, id: $0.id, special: $0.special, lstrip: false, rstrip: false) },
            structuralSources: [])
        return (stop, control)
    }

    /// Decodes `pieces` as the runtime does: added tokens by id (real control
    /// tokens), everything else as ordinary text tokens, through the shield.
    private func shieldedDecode(_ pieces: [String], control: ControlTokenTable, spelled: Set<String> = []) -> String {
        var vocabulary: [Int: String] = [:]
        var ids: [Int] = []
        for piece in pieces {
            if !spelled.contains(piece), let id = control.idsByText[piece] {
                ids.append(id)
                vocabulary[id] = piece
            } else {
                // Ordinary tokens, one per Character.
                for character in piece {
                    let id = 1_000 + vocabulary.count
                    vocabulary[id] = String(character)
                    ids.append(id)
                }
            }
        }
        return ControlTextShield.decode(tokenIds: ids, skipSpecialTokens: false, control: control) { ids, _ in
            ids.map { vocabulary[$0] ?? "" }.joined()
        }
    }

    func testSpecialTokenParameterKeysParseThroughShieldAndStopFilter() throws {
        let (stop, control) = try servedFilters()
        let ns = Self.ns
        // `write_file(filename, file_content, meta: {commit_msg, filepath})`:
        // every key is a special added token of this vocabulary.
        let pieces = [
            "Writing.\n", ns, "<tool_call>", "\n", ns, "<invoke name=\"write_file\">",
            ns, "<filename>", "a.txt", ns, "</filename>",
            ns, "<file_content>", "hi ", "<filename>", " x", ns, "</file_content>",
            ns, "<meta>", ns, "<commit_msg>", "init", ns, "</commit_msg>", ns, "<filepath>", "src/a.txt", ns, "</filepath>", ns, "</meta>",
            ns, "</invoke>", "\n", ns, "</tool_call>",
        ]
        let schemas: [String: JSONValue] = ["write_file": .object(["type": .string("object"), "properties": .object([
            "filename": .object(["type": .string("string")]), "file_content": .object(["type": .string("string")]),
            "meta": .object(["type": .string("object")]),
        ])])]
        let expected = #"{"file_content":"hi  x","filename":"a.txt","meta":{"commit_msg":"init","filepath":"src/a.txt"}}"#
        // Path A: the keys are real special tokens; path B: the model spelled
        // them with ordinary tokens, so the shield marks them.
        for spelled in [Set<String>(), ["<filename>", "<file_content>", "<commit_msg>", "<filepath>"]] {
            let decoded = shieldedDecode(pieces, control: control, spelled: spelled)
            XCTAssertEqual(decoded.unicodeScalars.contains(ControlTextShield.mark), !spelled.isEmpty)
            let filtered = ModelRuntime.applyOutputFilters(decoded, stopTokenFilter: stop, requestStops: [], reasoningOpen: false)
            let parsed = ToolCallParser.parseToolCalls(rawOutput: filtered.text, grammar: .minimax, modelID: Self.model,
                                                       allowedFunctionNames: ["write_file"], schemas: schemas)
            let call = try XCTUnwrap(parsed.toolCalls.first, "\(spelled)")
            XCTAssertEqual(ControlTextShield.strip(call.arguments),
                           spelled.isEmpty ? expected : expected.replacingOccurrences(of: "hi  x", with: "hi <filename> x"), "\(spelled)")
            XCTAssertEqual(parsed.leadingContent, "Writing.\n")
            // The incremental stream filter agrees with the whole-text filter
            // at every prefix: no cut separates a kept tag from its namespace.
            let incremental = ModelRuntime.IncrementalStreamFilter(stopTokenFilter: stop, requestStops: [], reasoningOpen: false)
            for end in stride(from: 1, through: decoded.unicodeScalars.count, by: 2) {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: decoded.unicodeScalars.prefix(end))
                let prefix = String(view)
                XCTAssertEqual(incremental.update(prefix).text,
                               ModelRuntime.streamingSafePrefix(prefix, stopTokenFilter: stop, requestStops: [], reasoningOpen: false).text,
                               "\(spelled) \(end)")
            }
        }
        // A special tag outside namespaced markup is still stripped.
        let prose = shieldedDecode(["See ", "<filename>", " here", "]~b]"], control: control)
        XCTAssertEqual(ControlTextShield.strip(ModelRuntime.applyOutputFilters(prose, stopTokenFilter: stop, requestStops: [], reasoningOpen: false).text),
                       "See  here")
        // Other families keep stripping every special token.
        XCTAssertEqual(ModelRuntime.toolAwareStopTokenFilter(StopTokenFilter(tokens: ["<filename>"]), grammar: .glm)
                        .stripping(from: ns + "<filename>"), ns)
    }

    func testCallInsideALaterBlockIsNotACall() throws {
        let request = try makeRequest(tools: true, stream: false)
        let output = "Let me check.\n<mm:think>maybe " + Self.wrapper(Self.readHosts) + "</mm:think>No call needed."
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request,
            mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.content, "Let me check.\nNo call needed.")
        XCTAssertEqual(parsed.reasoningContent, "maybe " + Self.wrapper(Self.readHosts))
        for reference in [false, true] {
            for chunk in [1, 5, output.count] {
                let streamed = try stream(output, request: try makeRequest(tools: true), chunk: chunk, reference: reference)
                XCTAssertTrue(streamed.calls.isEmpty, "chunk \(chunk)")
                XCTAssertEqual(streamed.content, "Let me check.\nNo call needed.", "chunk \(chunk)")
                XCTAssertEqual(streamed.reasoning, "maybe " + Self.wrapper(Self.readHosts), "chunk \(chunk)")
            }
        }
        var observer = NativeToolCallStreamEmitter(modelID: Self.model, grammar: .minimax, allowedFunctionNames: ["read_file"])
        var incrementalObserver = observer
        var stopText = IncrementalToolStopText(observer: incrementalObserver)
        let filter = ModelRuntime.IncrementalStreamFilter(stopTokenFilter: StopTokenFilter(tokens: []), requestStops: [], reasoningOpen: .afterMiniMaxThink)
        for end in 1...output.count {
            let prefix = String(output.prefix(end))
            XCTAssertFalse(ModelRuntime.observeSerialToolStop(&observer, decoded: prefix, stopTokenFilter: StopTokenFilter(tokens: []), requestStops: [], reasoningOpen: .afterMiniMaxThink), prefix)
            XCTAssertFalse(ModelRuntime.observeSerialToolStop(&incrementalObserver, decoded: prefix, filter: filter, stopText: &stopText, reasoningOpen: .afterMiniMaxThink), prefix)
        }
    }

    // MARK: Request stops

    func testRequestStopsRunAfterTheFirstReasoningClose() throws {
        let request = try makeRequest(tools: false)
        XCTAssertEqual(ModelRuntime.reasoningStopScope(request), .afterMiniMaxThink)
        let stop = StopTokenFilter(tokens: [])
        let thinking = "<mm:think>Count: 1, 2, ... 7, 8, 9, 10.</mm:think>\n1, 2, 3, 4, 5, 6, 7, 8, 9, 10"
        let full = ModelRuntime.applyOutputFilters(thinking, stopTokenFilter: stop, requestStops: ["7"], reasoningOpen: .afterMiniMaxThink)
        XCTAssertTrue(full.hitStop)
        XCTAssertEqual(ReasoningOutput.MiniMax.split(full.text).answer, "1, 2, 3, 4, 5, 6, ")
        XCTAssertEqual(ModelRuntime.matchedRequestStop(in: thinking, stopTokenFilter: stop, requestStops: ["7"], reasoningOpen: .afterMiniMaxThink), "7")
        // A reply that leads with answer text: stops run over all of it.
        let answerFirst = "1, 2, <mm:think>7</mm:think> 3"
        let cut = ModelRuntime.applyOutputFilters(answerFirst, stopTokenFilter: stop, requestStops: ["7"], reasoningOpen: .afterMiniMaxThink)
        XCTAssertEqual(cut.text, "1, 2, <mm:think>")
        XCTAssertTrue(cut.hitStop)
        // Every prefix: no stop while the reasoning is open; the incremental
        // filter equals the whole-text one; the emitter ends the row on the
        // stop with the answer before it.
        for output in [thinking, answerFirst, "  " + thinking] {
            let filter = ModelRuntime.IncrementalStreamFilter(stopTokenFilter: stop, requestStops: ["7"], reasoningOpen: .afterMiniMaxThink)
            for reference in [false, true] {
                var emitter = SerialStreamingTextEmitter(request: request)
                if reference { emitter = emitter.usingReferenceText() }
                let accumulator = StructuredStreamingContentAccumulator(enabled: false)
                let idle = StructuredStreamingIdleState(enabled: false)
                var content = ""
                var stopped = false
                for end in 1...output.count where !stopped {
                    let prefix = String(output.prefix(end))
                    let expected = ModelRuntime.streamingSafePrefix(prefix, stopTokenFilter: stop, requestStops: ["7"], reasoningOpen: .afterMiniMaxThink)
                    if !reference {
                        let incremental = filter.update(prefix)
                        XCTAssertEqual(incremental.text, expected.text, prefix)
                        XCTAssertEqual(incremental.hitStop, expected.hitStop, prefix)
                    }
                    let inReasoning = output.hasPrefix("1") ? false : !prefix.contains("</mm:think>")
                    XCTAssertFalse(expected.hitStop && inReasoning, prefix)
                    let step = emitter.step(candidate: expected, structuredAccumulator: accumulator, idleState: idle) {
                        if case .content(let text) = $0 { content += text }
                    }
                    if case .requestStop = step { stopped = true }
                    XCTAssertEqual(stopped, expected.hitStop, prefix)
                }
                XCTAssertTrue(stopped, output)
                // The emitter's cleanup hold keeps the trailing space until finish.
                XCTAssertEqual(content, output.hasPrefix("1") ? "1, 2," : "1, 2, 3, 4, 5, 6,", output)
            }
        }
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
