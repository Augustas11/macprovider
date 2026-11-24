import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

/// #2467: Inkling 2 Mini output. Every message is a frame of special tokens
/// (`<|message_model|>[NAME]<|content_…|>BODY<|end_message|>`), as the
/// publisher's chat template and Ollama's `inkling2` parser read it:
/// thinking frames are reasoning, text frames are content, and a call is
/// `<|message_model|>NAME<|content_invoke_tool_json|>{"name":…,"args":{…}}`.
final class Inkling2OutputTests: XCTestCase {
    private typealias Inkling = ReasoningOutput.Inkling
    private static let model = "mlx-community/Inkling-2-Mini-oQ4e-mtp"

    private static func thinking(_ text: String) -> String { "<|message_model|><|content_thinking|>" + text + "<|end_message|>" }
    private static func text(_ text: String) -> String { "<|message_model|><|content_text|>" + text + "<|end_message|>" }
    private static func call(_ name: String, _ args: String, header: String? = nil) -> String {
        "<|message_model|>" + (header ?? name) + "<|content_invoke_tool_json|>{\"name\":\"" + name + "\",\"args\":" + args + "}<|end_message|>"
    }

    private static let readHosts = call("read_file", #"{"path":"/etc/hosts"}"#)
    private static let readPasswd = call("read_file", #"{"path":"/etc/passwd"}"#)

    private static let tools: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "read_file", "description": "Read a file from disk",
            "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]],
        ]],
        ["type": "function", "function": [
            "name": "search", "parameters": ["type": "object", "properties": [
                "query": ["type": "string"], "limit": ["type": "integer"],
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
        if resolve { request.outputState.resolve(RequestOutputTraits(toolGrammar: .inkling2)) }
        return request
    }

    private func parse(_ output: String, allowed: Set<String>? = ["read_file", "search"]) -> ToolCallParser.ParsedToolCalls {
        let schemas: [String: JSONValue] = [
            "read_file": .object(["type": .string("object"), "properties": .object(["path": .object(["type": .string("string")])])]),
            "search": .object(["type": .string("object"), "properties": .object([
                "query": .object(["type": .string("string")]), "limit": .object(["type": .string("integer")]),
            ])]),
        ]
        return ToolCallParser.parseToolCalls(rawOutput: output, grammar: .inkling2, modelID: Self.model,
                                             allowedFunctionNames: allowed, schemas: schemas)
    }

    // MARK: Family

    func testFamilyResolvesForEveryInklingID() {
        for id in [Self.model, "thinkingmachines/Inkling-2-Mini", "openuncensored/inkling-2-mini-uncensored",
                   "aug11/Inkling-2-Mini-oQ4e-mtp-uncensored"] {
            XCTAssertEqual(ToolCallGrammar.family(modelID: id), .inkling2, id)
            XCTAssertEqual(ToolCallGrammar.resolved(templateFormat: "json", modelID: id), .inkling2, id)
        }
    }

    // MARK: Reasoning

    /// (output, reasoning, answer, closed, reasoned)
    private static let reasoningCases: [(String, String, String, Bool, Bool)] = [
        (thinking("17*23: 340+51=391.") + text("391"), "17*23: 340+51=391.", "391", true, true),
        (text("391"), "", "391", true, false),
        ("391", "", "391", true, false),
        (thinking("a") + thinking("b") + text("c"), "ab", "c", true, true),
        (text("Hi ") + text("there"), "", "Hi there", true, false),
        // Cut inside the thinking frame (finish_reason length).
        ("<|message_model|><|content_thinking|>17*23 is", "17*23 is", "", false, true),
        // A header that never reached its opener is dropped.
        (text("ok") + "<|message_model|>read_fi", "", "ok", true, false),
    ]

    func testFinalSplit() {
        for (output, reasoning, answer, closed, reasoned) in Self.reasoningCases {
            XCTAssertEqual(Inkling.split(output), ReasoningOutput.Split(reasoning: reasoning, answer: answer, closed: closed), output)
            XCTAssertEqual(Inkling.reasoned(output), reasoned, output)
        }
    }

    func testCallFramesStayWholeForTheToolParser() {
        let output = Self.thinking("need the file") + Self.readHosts
        let split = Inkling.split(output)
        XCTAssertEqual(split.reasoning, "need the file")
        XCTAssertEqual(split.answer, Self.readHosts)
        XCTAssertTrue(split.closed)
        // Marker spellings inside the call's JSON are the call's.
        let literal = Self.call("search", #"{"query":"<|end_message|>"}"#)
        XCTAssertEqual(Inkling.split(literal).answer, literal)
    }

    func testNonStreamingSplitsReasoningOffContent() throws {
        let request = try makeRequest(tools: false, stream: false)
        for (output, reasoning, answer, _, reasoned) in Self.reasoningCases {
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request,
                mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
            XCTAssertEqual(parsed.content, answer, output)
            XCTAssertEqual(parsed.reasoningContent, reasoned ? reasoning : nil, output)
            XCTAssertFalse(parsed.content.contains("<|"), output)
        }
        // Family fallback when the template grammar was not recorded.
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: Self.reasoningCases[0].0, generatedTokenIDs: [], decode: { _ in "" },
            request: makeRequest(tools: false, stream: false, resolve: false),
            mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
        XCTAssertEqual(parsed.content, "391")
        XCTAssertEqual(ModelRuntime.reasoningStopScope(request), .afterInklingThink)
    }

    func testReasoningTokenCount() {
        // One token per Character: the count runs from the thinking opener
        // through the `<|end_message|>` that closes it.
        func count(_ text: String) -> Int {
            let tokens = Array(text).map(String.init)
            return Inkling.reasoningTokenCount(tokenIDs: Array(tokens.indices), decode: { $0.map { tokens[$0] }.joined() })
        }
        let opener = "<|content_thinking|>".count, end = "<|end_message|>".count
        XCTAssertEqual(count(Self.thinking("ab") + Self.text("cd")), opener + 2 + end)
        XCTAssertEqual(count(Self.text("cd")), 0)
        XCTAssertEqual(count("<|message_model|><|content_thinking|>abc"), opener + 3)
        XCTAssertEqual(count(Self.thinking("a") + Self.text("xyz") + Self.thinking("b")), 2 * (opener + 1 + end))
        // A thinking marker inside a call's JSON is no frame.
        XCTAssertEqual(count(Self.call("search", #"{"query":"<|content_thinking|>x"}"#)), 0)
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
            case .reasoning(let text):
                reasoning += text
                if reasoning.contains("<|") { sawMarkup = true }
            case .content(let text):
                content += text
                // Markup and held tool names may not stream, even partially.
                if content.contains("<|") || content.contains("read_fi") { sawMarkup = true }
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
            // Chunks of 1, 3 and 7 Characters cut every marker at every offset.
            for chunk in [1, 3, 7, output.count] {
                for reference in [false, true] {
                    let streamed = try stream(output, request: request, chunk: chunk, reference: reference)
                    XCTAssertEqual(streamed.reasoning, reasoning, "\(output) chunk \(chunk)")
                    XCTAssertEqual(streamed.content, answer, "\(output) chunk \(chunk)")
                    XCTAssertFalse(streamed.sawMarkup, "\(output) chunk \(chunk)")
                }
            }
        }
    }

    func testStreamingCallsNeverLeakFrameMarkup() throws {
        let request = try makeRequest(tools: true)
        let output = Self.thinking("need both") + Self.text("Reading both.") + Self.readHosts + Self.readPasswd
        for chunk in [1, 3, 7, output.count] {
            for reference in [false, true] {
                let streamed = try stream(output, request: request, chunk: chunk, reference: reference)
                XCTAssertEqual(streamed.reasoning, "need both", "chunk \(chunk)")
                XCTAssertEqual(streamed.content, "Reading both.", "chunk \(chunk)")
                XCTAssertEqual(streamed.calls, [#"{"path":"/etc/hosts"}"#, #"{"path":"/etc/passwd"}"#], "chunk \(chunk)")
                XCTAssertFalse(streamed.sawMarkup, "chunk \(chunk)")
            }
        }
    }

    func testStreamingPrefixHoldsUndecidedMarkersAndHeaders() {
        for prefix in ["", "<", "<|message_mo", "<|message_model|>", "<|message_model|><|content_th", "<|message_model|>read_fi"] {
            XCTAssertEqual(Inkling.splitStreamingPrefix(prefix), ReasoningOutput.Split(reasoning: "", answer: "", closed: true), prefix)
        }
        XCTAssertEqual(Inkling.splitStreamingPrefix("<|message_model|><|content_thinking|>abc<|end_mes"),
                       ReasoningOutput.Split(reasoning: "abc", answer: "", closed: false))
        XCTAssertEqual(Inkling.splitStreamingPrefix(Self.text("Hi") + "<|mess"), ReasoningOutput.Split(reasoning: "", answer: "Hi", closed: true))
        XCTAssertEqual(Inkling.lead(""), .undecided)
        XCTAssertEqual(Inkling.lead("<|message_model|><|content_thinking|>x"), .thinking)
        XCTAssertEqual(Inkling.lead("<|message_model|><|content_text|>x"), .answer)
        XCTAssertEqual(Inkling.lead("plain"), .answer)
        // The incremental split equals the whole-text one at every prefix,
        // and both only grow.
        let long = Self.thinking(String(repeating: "plan step; ", count: 30)) + Self.text("Answer " + String(repeating: "x", count: 90))
            + Self.thinking("more") + Self.text("Done.")
        for output in Self.reasoningCases.map(\.0) + [long, Self.thinking("t") + Self.readHosts] {
            var incremental = IncrementalInklingReasoningSplit()
            var previous = ReasoningOutput.Split(reasoning: "", answer: "", closed: true)
            for end in 0...output.count {
                let prefix = String(output.prefix(end))
                let split = Inkling.splitStreamingPrefix(prefix)
                XCTAssertEqual(incremental.splitStreamingPrefix(prefix), split, prefix)
                XCTAssertTrue(split.reasoning.hasPrefix(previous.reasoning) && split.answer.hasPrefix(previous.answer), prefix)
                previous = split
            }
            XCTAssertEqual(previous, Inkling.split(output), output)
            XCTAssertEqual(incremental.restartCount, 0, output)
        }
    }

    func testOtherFamiliesKeepTheirOutput() throws {
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "mlx-community/Qwen3-8B-4bit", "messages": [["role": "user", "content": "hi"]],
        ]))
        let output = Self.text("y")
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request,
            mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
        XCTAssertEqual(parsed.content, output)
        XCTAssertNil(parsed.reasoningContent)
    }

    // MARK: Tool calls

    func testSingleAndMultipleCalls() {
        let one = parse(Self.readHosts)
        XCTAssertEqual(one.toolCalls.map(\.functionName), ["read_file"])
        XCTAssertEqual(one.toolCalls.map(\.arguments), [#"{"path":"/etc/hosts"}"#])
        XCTAssertNil(one.leadingContent)

        let two = parse(Self.text("I'll read both.") + Self.readHosts + Self.readPasswd)
        XCTAssertEqual(two.toolCalls.map(\.arguments), [#"{"path":"/etc/hosts"}"#, #"{"path":"/etc/passwd"}"#])
        XCTAssertEqual(two.leadingContent, "I'll read both.")
        XCTAssertNotEqual(two.toolCalls[0].id, two.toolCalls[1].id)

        // An empty header takes the JSON name, as Ollama's parser does.
        XCTAssertEqual(parse(Self.call("read_file", #"{"path":"/a"}"#, header: "")).toolCalls.map(\.functionName), ["read_file"])
    }

    func testTypedArgumentsAndLiteralMarkersSurvive() throws {
        let call = try XCTUnwrap(parse(Self.call("search", #"{"query":"<|end_message|> x","limit":5}"#)).toolCalls.first)
        XCTAssertEqual(try StrictJSONParser.parse(call.arguments), .object(["query": .string("<|end_message|> x"), "limit": .int(5)]))
    }

    func testMalformedCallsAreDroppedAndOthersKept() {
        // Header and JSON name disagree.
        XCTAssertEqual(parse(Self.call("read_file", #"{"path":"/a"}"#, header: "search") + Self.readPasswd).toolCalls.map(\.arguments),
                       [#"{"path":"/etc/passwd"}"#])
        // Arguments that are not an object.
        XCTAssertTrue(parse(Self.call("read_file", #""/etc/hosts""#)).toolCalls.isEmpty)
        // Undeclared names are dropped; none surviving leaves only prose.
        let undeclared = parse(Self.text("Sure.") + Self.call("rm_rf", #"{"path":"/"}"#))
        XCTAssertTrue(undeclared.toolCalls.isEmpty)
        XCTAssertTrue(undeclared.droppedMalformedCalls)
        XCTAssertEqual(undeclared.cleanedContent, "Sure.")
        XCTAssertFalse(undeclared.cleanedContent?.contains("<|") ?? false)
    }

    func testCutCallKeepsOnlyCompleteCalls() {
        // finish_reason length inside the second call.
        let cut = parse(Self.readHosts + "<|message_model|>read_file<|content_invoke_tool_json|>{\"name\":\"read_file\",\"args\":{\"path\":\"/etc/pa")
        XCTAssertEqual(cut.toolCalls.map(\.arguments), [#"{"path":"/etc/hosts"}"#])
    }

    func testFinalOutputCarriesReasoningAndCalls() throws {
        let request = try makeRequest(tools: true, stream: false)
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: Self.thinking("need it") + Self.readHosts, generatedTokenIDs: [], decode: { _ in "" }, request: request,
            mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil)
        XCTAssertEqual(parsed.reasoningContent, "need it")
        XCTAssertEqual(parsed.toolCalls.map(\.functionName), ["read_file"])
        XCTAssertEqual(parsed.content, "")
    }

    func testFrameMarkersSurviveTheToolAwareStopFilter() {
        let all = Inkling.tags + [Inkling.endSampling, "<|message_user|>"]
        let filter = ModelRuntime.toolAwareStopTokenFilter(StopTokenFilter(tokens: all), grammar: .inkling2)
        XCTAssertEqual(Set(filter.tokens), [Inkling.endSampling, "<|message_user|>"])
        XCTAssertEqual(ToolCallParser.callStartMarkers(.inkling2), [Inkling.messageModel])
    }
}
