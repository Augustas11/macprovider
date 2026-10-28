import Foundation
import Jinja
import MLXLMCommon
import MacProviderCore
@testable import macprovider_cli
import XCTest

/// #2107: every catalog tool grammar parses the calls its own chat template
/// renders, tool history goes through each template natively, and GLM-5.3's
/// open `<think>` is split into reasoning before stops, JSON mode and tools.
final class CatalogToolGrammarTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/tests/fixtures/")

    private struct Family {
        let name: String
        let template: String
        let grammar: ToolCallGrammar
        /// The start of the call the template renders in assistant history.
        let callStart: String
        /// The end of that call (inclusive).
        let callEnd: String
    }

    private static let families: [Family] = [
        Family(name: "GLM-5.3", template: "glm53-chat-template/chat_template.jinja", grammar: .glm, callStart: "<tool_call>", callEnd: "</tool_call>"),
        Family(name: "GLM-4.5", template: "chat-templates-2107/glm-4.5-air.jinja", grammar: .glm, callStart: "<tool_call>", callEnd: "</tool_call>"),
        Family(name: "Llama-3.1", template: "chat-templates-2107/llama-3.1-8b-instruct.jinja", grammar: .llama3, callStart: "{\"name\"", callEnd: "}}"),
        Family(name: "Llama-3.2", template: "chat-templates-2107/llama-3.2-3b-instruct.jinja", grammar: .llama3, callStart: "{\"name\"", callEnd: "}}"),
        Family(name: "Nemotron-3", template: "chat-templates-2107/nemotron-3-nano-30b-a3b.jinja", grammar: .qwen, callStart: "<tool_call>", callEnd: "</tool_call>"),
        Family(name: "Gemma-4", template: "chat-templates-2107/gemma-4-26b-a4b-it.jinja", grammar: .gemma4, callStart: "<|tool_call>", callEnd: "<tool_call|>"),
        Family(name: "Qwen3-8B", template: "chat-templates-2107/qwen3-8b.jinja", grammar: .qwen, callStart: "<tool_call>", callEnd: "</tool_call>"),
        Family(name: "Qwen3-Coder", template: "chat-templates-2107/qwen3-coder-30b-a3b-instruct.jinja", grammar: .qwen, callStart: "<tool_call>", callEnd: "</tool_call>"),
        Family(name: "Qwen3.8-27B official", template: "qwen38-27b-official/chat_template.jinja", grammar: .qwen, callStart: "<tool_call>", callEnd: "</tool_call>"),
    ]

    private static let callID = "call_0123456789abcdef"
    private static let arguments = #"{"city":"Paris","count":2,"enabled":true}"#
    private static let toolResult = "PROFILE_HISTORY_OK"

    private static let tools: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": "lookup",
            "description": "Look up a city",
            "parameters": [
                "type": "object",
                "properties": [
                    "city": ["type": "string"],
                    "count": ["type": "integer"],
                    "enabled": ["type": "boolean"],
                ],
                "required": ["city"],
            ],
        ],
    ]]

    private static var schemas: [String: MacProviderCore.JSONValue] {
        get throws {
            ["lookup": try MacProviderCore.JSONValue.parse(((tools[0]["function"] as! [String: Any])["parameters"])!)]
        }
    }

    private func historyRequest(model: String = "test-model") throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": model,
            "tools": Self.tools,
            "messages": [
                ["role": "system", "content": "You are helpful."],
                ["role": "user", "content": "Look up Paris."],
                ["role": "assistant", "content": "", "tool_calls": [[
                    "id": Self.callID, "type": "function",
                    "function": ["name": "lookup", "arguments": Self.arguments],
                ]]],
                ["role": "tool", "tool_call_id": Self.callID, "content": Self.toolResult],
            ],
        ]))
    }

    private func render(_ family: Family, messages: [ChatMessage]) throws -> String {
        let source = try String(contentsOf: Self.fixtures.appendingPathComponent(family.template), encoding: .utf8)
        let template = try Template(
            ChatTemplateCompatibility.rewrite(source).template,
            with: .init(lstripBlocks: true, trimBlocks: true)
        )
        let chat = try ToolPromptRenderer.renderMessages(messages, grammar: family.grammar)
        let raw = DefaultMessageGenerator().generate(messages: chat)
        var context: [String: Value] = [
            "messages": try Value(any: raw.map { $0 as [String: Any] }),
            "tools": try Value(any: Self.tools),
            "add_generation_prompt": .boolean(true),
            "bos_token": .string(""),
            "eos_token": .string(""),
            "date_string": .string("26 Jul 2024"),
        ]
        if source.contains("enable_thinking") {
            // As the provider renders (templateAdditionalContext).
            context["enable_thinking"] = .boolean(false)
        }
        return try template.render(context)
    }

    /// The template renders history natively: one structured call, one tool
    /// result wrapped by the template only, and no transport-only envelope.
    func testEveryCatalogTemplateRendersToolHistoryNatively() throws {
        let request = try historyRequest()
        for family in Self.families {
            let rendered = try render(family, messages: request.messages)
            XCTAssertTrue(rendered.contains(Self.toolResult), "\(family.name) lost the tool result:\n\(rendered)")
            XCTAssertEqual(rendered.components(separatedBy: Self.toolResult).count, 2, "\(family.name) rendered the result more than once")
            XCTAssertFalse(rendered.contains("<tool_response id="), "\(family.name) must not see a hand-rendered result envelope")
            XCTAssertTrue(rendered.contains(family.callStart), "\(family.name) did not render the assistant call:\n\(rendered)")
        }
    }

    /// Each grammar's parser reads back the call its own template rendered,
    /// with values typed by the declared schema.
    func testEachGrammarParsesItsTemplateRenderedCall() throws {
        let request = try historyRequest()
        for family in Self.families {
            let rendered = try render(family, messages: request.messages)
            // The history call is the last one before the tool result (the
            // system prompt's format instructions come first).
            guard let result = rendered.range(of: Self.toolResult),
                  let start = rendered.range(of: family.callStart, options: .backwards, range: rendered.startIndex..<result.lowerBound),
                  let end = rendered.range(of: family.callEnd, range: start.upperBound..<rendered.endIndex) else {
                XCTFail("\(family.name): no rendered call in\n\(rendered)")
                continue
            }
            let call = String(rendered[start.lowerBound..<end.upperBound])
            let parsed = ToolCallParser.parseToolCalls(
                rawOutput: call,
                grammar: family.grammar,
                modelID: family.name,
                allowedFunctionNames: ["lookup"],
                schemas: try Self.schemas
            )
            XCTAssertEqual(parsed.toolCalls.count, 1, "\(family.name) did not parse \(call)")
            XCTAssertEqual(parsed.toolCalls.first?.functionName, "lookup", family.name)
            XCTAssertEqual(parsed.toolCalls.first?.arguments, Self.arguments, "\(family.name) arguments from \(call)")
        }
    }

    func testTemplateWithoutToolGrammarRefusesToolHistory() throws {
        let request = try historyRequest(model: "mlx-community/Qwen2-VL-2B-Instruct-4bit")
        XCTAssertThrowsError(try ToolPromptRenderer.renderMessages(request.messages, modelID: request.model)) { error in
            XCTAssertEqual((error as? APIError)?.code, "unsupported_modelID_for_multi_turn")
        }
        XCTAssertNil(ToolCallGrammar.family(modelID: request.model))
        XCTAssertThrowsError(try ModelRuntime.resolvedToolGrammar(for: request, templateToolFormat: "json")) { error in
            XCTAssertEqual((error as? APIError)?.status, 400)
            XCTAssertEqual((error as? APIError)?.code, "tools_unsupported_for_model")
        }
    }

    func testTemplateFormatSelectsTheGrammarOverTheModelID() {
        XCTAssertEqual(ToolCallGrammar.resolved(templateFormat: "glm4", modelID: "local/alias"), .glm)
        XCTAssertEqual(ToolCallGrammar.resolved(templateFormat: "gemma4", modelID: "local/alias"), .gemma4)
        XCTAssertEqual(ToolCallGrammar.resolved(templateFormat: "llama3", modelID: "local/alias"), .llama3)
        XCTAssertEqual(ToolCallGrammar.resolved(templateFormat: "xml_function", modelID: "local/alias"), .qwen)
        XCTAssertEqual(ToolCallGrammar.resolved(templateFormat: nil, modelID: "Jundot/GLM-5.3-Flash-oQ4e-mtp"), .glm)
        XCTAssertNil(ToolCallGrammar.resolved(templateFormat: "json", modelID: "mlx-community/Qwen2-VL-2B-Instruct-4bit"))
    }

    // MARK: - Live output shapes (#2107 probes)

    func testGLMLiveOutputParsesAfterTheReasoningSplit() throws {
        let raw = "The user wants me to read the file /etc/hosts using the read_file tool. Let me do that.</think><tool_call>read_file<arg_key>path</arg_key><arg_value>/etc/hosts</arg_value></tool_call>"
        let request = try toolRequest(model: "Jundot/GLM-5.3-Flash-oQ4e-mtp", tool: "read_file", property: "path")
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .glm, reasoningOpen: true))
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: raw, generatedTokenIDs: Array(0..<36), decode: { ids in String(raw.prefix(ids.count * 6)) },
            request: request, mode: .complete(), defaultCompletionTokens: 36, toolCallPrefill: nil
        )
        XCTAssertEqual(parsed.toolCalls.map(\.functionName), ["read_file"])
        XCTAssertEqual(parsed.toolCalls.first?.arguments, #"{"path":"/etc/hosts"}"#)
        XCTAssertEqual(parsed.content, "")
        XCTAssertEqual(parsed.reasoningContent, "The user wants me to read the file /etc/hosts using the read_file tool. Let me do that.")
        XCTAssertGreaterThan(parsed.reasoningTokens, 0)
        XCTAssertLessThanOrEqual(parsed.reasoningTokens, 36)
    }

    func testLlamaBareJSONLiveOutputParses() throws {
        let raw = #"{"name": "read_file", "parameters": {"path": "/etc/hosts"}}"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw, grammar: .llama3, modelID: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
            allowedFunctionNames: ["read_file"], schemas: nil
        )
        XCTAssertEqual(parsed.toolCalls.first?.arguments, #"{"path":"/etc/hosts"}"#)
        // Llama 3.3 python_tag form and a `;`-separated parallel pair.
        let tagged = ToolCallParser.parseToolCalls(
            rawOutput: #"<|python_tag|>{"name": "read_file", "parameters": {"path": "a"}}; {"name": "read_file", "parameters": {"path": "b"}}<|eom_id|>"#,
            grammar: .llama3, modelID: "m", allowedFunctionNames: ["read_file"], schemas: nil
        )
        XCTAssertEqual(tagged.toolCalls.map(\.arguments), [#"{"path":"a"}"#, #"{"path":"b"}"#])
        // An ordinary JSON answer is not a call.
        let answer = ToolCallParser.parseToolCalls(
            rawOutput: #"{"color": "blue"}"#, grammar: .llama3, modelID: "m", allowedFunctionNames: ["read_file"], schemas: nil
        )
        XCTAssertTrue(answer.toolCalls.isEmpty)
    }

    func testProseBeforeACallIsKeptAsContent() throws {
        let request = try toolRequest(model: "mlx-community/Qwen3-8B-4bit", tool: "read_file", property: "path")
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: "Let me check that file.\n<tool_call>\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"a\"}}\n</tool_call>",
            generatedTokenIDs: [], decode: { _ in "" }, request: request, mode: .complete(),
            defaultCompletionTokens: 9, toolCallPrefill: nil
        )
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(parsed.content, "Let me check that file.")
    }

    func testGLMParallelCallsAndTypedValues() throws {
        let raw = "<tool_call>lookup<arg_key>city</arg_key><arg_value>Paris</arg_value><arg_key>count</arg_key><arg_value>2</arg_value></tool_call>"
            + "<tool_call>lookup<arg_key>city</arg_key><arg_value>42</arg_value><arg_key>enabled</arg_key><arg_value>false</arg_value></tool_call>"
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw, grammar: .glm, modelID: "glm", allowedFunctionNames: ["lookup"], schemas: try Self.schemas
        )
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"city":"Paris","count":2}"#, #"{"city":"42","enabled":false}"#])
        // A declared integer that is not an integer is malformed, never coerced.
        let bad = ToolCallParser.parseToolCalls(
            rawOutput: "<tool_call>lookup<arg_key>count</arg_key><arg_value>two</arg_value></tool_call>",
            grammar: .glm, modelID: "glm", allowedFunctionNames: ["lookup"], schemas: try Self.schemas
        )
        XCTAssertTrue(bad.toolCalls.isEmpty)
        // An undeclared function never becomes a call.
        let undeclared = ToolCallParser.parseToolCalls(
            rawOutput: "<tool_call>rm<arg_key>path</arg_key><arg_value>/</arg_value></tool_call>",
            grammar: .glm, modelID: "glm", allowedFunctionNames: ["lookup"], schemas: try Self.schemas
        )
        XCTAssertTrue(undeclared.toolCalls.isEmpty)
    }

    func testGemmaCallsParse() throws {
        let raw = #"<|tool_call>call:lookup{city:<|"|>Paris, France<|"|>,count:2,enabled:true}<tool_call|>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw, grammar: .gemma4, modelID: "gemma", allowedFunctionNames: ["lookup"], schemas: try Self.schemas
        )
        XCTAssertEqual(parsed.toolCalls.first?.arguments, #"{"city":"Paris, France","count":2,"enabled":true}"#)
    }

    /// Audit r1: the Gemma dialect parser fails closed on duplicates, trailing
    /// text and type mismatches, and decodes marker strings inside composites.
    func testGemmaParserIsStrictAndRecursive() throws {
        let schemas: [String: MacProviderCore.JSONValue] = [
            "edit": try MacProviderCore.JSONValue.parse([
                "type": "object",
                "properties": ["paths": ["type": "array"], "opts": ["type": "object"], "n": ["type": "integer"]],
            ]),
        ]
        func parse(_ body: String) -> [macprovider_cli.ToolCall] {
            ToolCallParser.parseToolCalls(
                rawOutput: "<|tool_call>" + body + "<tool_call|>", grammar: .gemma4, modelID: "gemma",
                allowedFunctionNames: ["edit"], schemas: schemas
            ).toolCalls
        }
        XCTAssertEqual(parse(#"call:edit{paths:[<|"|>a, b<|"|>,<|"|>c<|"|>],opts:{mode:<|"|>x:y<|"|>},n:3}"#).first?.arguments,
                       #"{"n":3,"opts":{"mode":"x:y"},"paths":["a, b","c"]}"#)
        XCTAssertTrue(parse(#"call:edit{n:1,n:2}"#).isEmpty, "duplicate key")
        XCTAssertTrue(parse(#"call:edit{opts:{a:1,a:2}}"#).isEmpty, "nested duplicate key")
        XCTAssertTrue(parse(#"call:edit{n:1} trailing"#).isEmpty, "trailing text")
        XCTAssertTrue(parse(#"call:edit{n:<|"|>3<|"|>}"#).isEmpty, "declared integer given a string")
        XCTAssertTrue(parse(#"call:edit{paths:<|"|>a<|"|>}"#).isEmpty, "declared array given a string")
        XCTAssertTrue(parse("call:edit{n}").isEmpty, "field without a value")
        XCTAssertTrue(parse("call:edit{opts:" + String(repeating: "{a:", count: 40) + "1" + String(repeating: "}", count: 41)).isEmpty, "depth")
    }

    func testGLMCallsSurviveProseBetweenAndAfterEnvelopes() throws {
        let raw = "<tool_call>lookup<arg_key>city</arg_key><arg_value>A</arg_value></tool_call>\nand then\n"
            + "<tool_call>lookup<arg_key>city</arg_key><arg_value>B</arg_value></tool_call>\ndone."
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw, grammar: .glm, modelID: "glm", allowedFunctionNames: ["lookup"], schemas: try Self.schemas
        )
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"city":"A"}"#, #"{"city":"B"}"#])
    }

    /// Audit r1: a stream whose final parse finds no call releases the held
    /// text as content (here a Llama brace that is not a call).
    func testStreamReleasesHeldTextWhenNoCallParses() throws {
        let request = try toolRequest(model: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit", tool: "lookup", property: "city")
        let output = #"Use {"color": "blue"} as the value."#
        var emitter = SerialStreamingTextEmitter(request: request)
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        var content = ""
        for end in 1...output.count {
            _ = emitter.step(candidate: (String(output.prefix(end)), false), structuredAccumulator: accumulator, idleState: idle) {
                if case .content(let text) = $0 { content += text }
            }
        }
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request, mode: .complete(),
            defaultCompletionTokens: 9, toolCallPrefill: nil
        )
        try emitter.finish(finalText: output, parsed: parsed, structuredAccumulator: accumulator, idleState: idle) {
            if case .content(let text) = $0 { content += text }
        }
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(content, output)
        XCTAssertEqual(emitter.emittedContent, output)
    }

    /// Audit r1: a reasoning CB row stops canonically at a post-think stop
    /// string (it has no request stop-token sequences), not inside reasoning.
    func testReasoningRowCanonicalStopObserverStopsAfterThink() throws {
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "Jundot/GLM-5.3-Flash-oQ4e-mtp", "messages": [["role": "user", "content": "count"]], "stop": ["4"],
        ]))
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .glm, reasoningOpen: true))
        let pieces = ["1 2 3 4", "</think>", "1, ", "2, ", "3, ", "4", ", 5"]
        let observer = try XCTUnwrap(ModelRuntime.continuousBatchSerialToolStopObserver(
            request: request,
            detokenizer: ModelRuntime.StreamingDetokenizer(decode: { $0.map { pieces[$0] }.joined() }, tokenPiece: { pieces[$0] }),
            stopTokenFilter: StopTokenFilter(tokens: [])
        ))
        var stoppedAt: Int?
        for token in pieces.indices where stoppedAt == nil {
            if observer.observe([token]) { stoppedAt = token }
        }
        XCTAssertEqual(stoppedAt, 5, "the stop inside the reasoning must not end the row")
        XCTAssertEqual(observer.stopTokenCount, 6)
    }

    /// Audit r2: leading prose reaches the stream before the call deltas,
    /// whether it arrives in one delivery with the call or only at finish
    /// (terminal replay without token events).
    func testLeadingProsePrecedesQwenCallDeltas() throws {
        let request = try toolRequest(model: "mlx-community/Qwen3-8B-4bit", tool: "read_file", property: "path")
        let output = "Let me check.\n<tool_call>\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"a\"}}\n</tool_call>"
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request, mode: .complete(),
            defaultCompletionTokens: 9, toolCallPrefill: nil
        )
        for grouped in [true, false] {
            var emitter = SerialStreamingTextEmitter(request: request)
            let accumulator = StructuredStreamingContentAccumulator(enabled: false)
            let idle = StructuredStreamingIdleState(enabled: false)
            var order: [String] = []
            let record: (StreamChunk) -> Void = { chunk in
                switch chunk {
                case .content(let text) where !text.isEmpty: order.append("content")
                case .toolCallDelta: order.append("tool")
                default: break
                }
            }
            if grouped {
                _ = emitter.step(candidate: (output, false), structuredAccumulator: accumulator, idleState: idle, onChunk: record)
            }
            try emitter.finish(finalText: output, parsed: parsed, structuredAccumulator: accumulator, idleState: idle, onChunk: record)
            XCTAssertEqual(order.first, "content", "grouped=\(grouped) order=\(order)")
            XCTAssertTrue(order.contains("tool"), "grouped=\(grouped)")
            XCTAssertTrue(emitter.emittedContent.hasPrefix("Let me check."), "grouped=\(grouped)")
        }
    }

    func testLlamaDetectionIgnoresBracesThatDoNotOpenACall() {
        let noisy = String(repeating: "{ ", count: 20_000) + #"{"name": "read_file", "parameters": {"path": "a"}}"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: noisy, grammar: .llama3, modelID: "llama", allowedFunctionNames: ["read_file"], schemas: nil
        )
        // Only `{"name"` openings are scanned, so 20,000 stray braces cost one
        // pass; the call after them still parses, the braces stay prose.
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertNotNil(ToolCallParser.llama3CallStart(in: noisy))
        XCTAssertNil(ToolCallParser.llama3CallStart(in: String(repeating: "{\"name\" ", count: 100)))
    }

    func testLlamaCallMemberOrderIsFree() {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"{"parameters": {"path": "a"}, "name": "read_file"}"#, grammar: .llama3, modelID: "llama",
            allowedFunctionNames: ["read_file"], schemas: nil
        )
        XCTAssertEqual(parsed.toolCalls.first?.arguments, #"{"path":"a"}"#)
    }

    /// Audit r3: a reasoning prefix that ends inside a multi-byte character
    /// (decoded as U+FFFD) is held back, so the completed character and the
    /// rest of the reasoning still stream.
    func testStreamedReasoningHoldsIncompleteUTF8() throws {
        let request = try toolRequest(model: "Jundot/GLM-5.3-Flash-oQ4e-mtp", tool: "lookup", property: "city")
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .glm, reasoningOpen: true))
        var emitter = SerialStreamingTextEmitter(request: request)
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        var reasoning = ""
        for prefix in ["Caf", "Caf\u{FFFD}", "Café", "Café ok", "Café ok</think>Done"] {
            _ = emitter.step(candidate: (prefix, false), structuredAccumulator: accumulator, idleState: idle) {
                if case .reasoning(let text) = $0 { reasoning += text }
            }
        }
        XCTAssertEqual(reasoning, "Café ok")
        XCTAssertEqual(emitter.emittedReasoning, "Café ok")
    }

    // MARK: - Reasoning split (SPEC-018 §3.12)

    func testReasoningSplitAppliesStopsAndJSONModeToTheAnswerOnly() throws {
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "Jundot/GLM-5.3-Flash-oQ4e-mtp",
            "messages": [["role": "user", "content": "count"]],
            "stop": ["4"],
        ]))
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .glm, reasoningOpen: true))
        // The stop string inside the reasoning does not end the turn.
        let raw = "Count 1, 2, 3, 4 and stop.</think>1, 2, 3, 4, 5"
        let filtered = ModelRuntime.applyOutputFilters(raw, stopTokenFilter: StopTokenFilter(tokens: []), requestStops: request.stop, reasoningOpen: true)
        XCTAssertTrue(filtered.hitStop)
        let split = ReasoningOutput.split(filtered.text)
        XCTAssertEqual(split.reasoning, "Count 1, 2, 3, 4 and stop.")
        XCTAssertEqual(split.answer, "1, 2, 3, ")
        // A reasoning-only prefix never hits a stop.
        XCTAssertFalse(ModelRuntime.streamingSafePrefix("Count 1, 2, 3, 4", stopTokenFilter: StopTokenFilter(tokens: []), requestStops: ["4"], reasoningOpen: true).hitStop)
    }

    func testGLMJSONModeValidatesThePostThinkAnswer() throws {
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "Jundot/GLM-5.3-Flash-oQ4e-mtp",
            "messages": [["role": "user", "content": "json"]],
            "response_format": ["type": "json_object"],
            "temperature": 0,
        ]))
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .glm, reasoningOpen: true))
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: #"I should answer with JSON.</think>{"color":"blue"}"#, generatedTokenIDs: [], decode: { _ in "" },
            request: request, mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: nil
        )
        let completion = CompletionResult(
            content: parsed.content, finishReason: "stop", promptTokens: 1, completionTokens: 9,
            settlementDisposition: .eligibleOwner, reasoningContent: parsed.reasoningContent, reasoningTokens: 6
        )
        XCTAssertEqual(try ModelRuntime.validateStructuredCompletion(completion, request: request).content, #"{"color":"blue"}"#)
        // A reasoning turn that never closed is a non-retryable budget error.
        let exhausted = CompletionResult(
            content: "", finishReason: "length", promptTokens: 1, completionTokens: 9,
            settlementDisposition: .eligibleOwner, reasoningContent: "still thinking", reasoningTokens: 9
        )
        XCTAssertThrowsError(try ModelRuntime.validateStructuredCompletion(exhausted, request: request)) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.code, "malformed_json_response")
            XCTAssertEqual(apiError?.envelope["error"].flatMap { ($0 as? [String: Any])?["retryable"] as? Bool }, false)
            XCTAssertTrue(apiError?.message.contains("reasoning") == true)
        }
    }

    func testPromptTailDetectsAnOpenThinkBlock() {
        XCTAssertTrue(ReasoningOutput.promptLeavesThinkOpen("<|assistant|><think>"))
        XCTAssertTrue(ReasoningOutput.promptLeavesThinkOpen("<|im_start|>assistant\n<think>\n"))
        XCTAssertFalse(ReasoningOutput.promptLeavesThinkOpen("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        XCTAssertFalse(ReasoningOutput.promptLeavesThinkOpen("<|assistant|>"))
        XCTAssertFalse(ReasoningOutput.promptLeavesThinkOpen("<think>x</think>\n<|assistant|>"))
    }

    func testReasoningTokenCountFindsTheClosingToken() {
        let pieces = ["a", "b", "</th", "ink>", "c"]
        XCTAssertEqual(ReasoningOutput.reasoningTokenCount(tokenIDs: Array(0..<5)) { ids in ids.map { pieces[$0] }.joined() }, 4)
        XCTAssertEqual(ReasoningOutput.reasoningTokenCount(tokenIDs: [0, 1]) { ids in ids.map { pieces[$0] }.joined() }, 2)
    }

    /// Streaming: reasoning deltas first, then the GLM calls with one OpenAI
    /// index each (D12), no reasoning or call markup in content.
    func testStreamingEmitsReasoningThenIndexedCalls() throws {
        let request = try toolRequest(model: "Jundot/GLM-5.3-Flash-oQ4e-mtp", tool: "lookup", property: "city")
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .glm, reasoningOpen: true))
        let output = "Two lookups.</think><tool_call>lookup<arg_key>city</arg_key><arg_value>A</arg_value></tool_call><tool_call>lookup<arg_key>city</arg_key><arg_value>B</arg_value></tool_call>"
        var emitter = SerialStreamingTextEmitter(request: request)
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        var reasoning = ""
        var content = ""
        for end in 1...output.count {
            _ = emitter.step(
                candidate: (String(output.prefix(end)), false), structuredAccumulator: accumulator, idleState: idle,
                onChunk: { chunk in
                    switch chunk {
                    case .reasoning(let text): reasoning += text
                    case .content(let text): content += text
                    case .toolCallDelta: XCTFail("GLM calls are emitted whole by the final parser")
                    }
                }
            )
        }
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request, mode: .complete(),
            defaultCompletionTokens: 20, toolCallPrefill: nil
        )
        try emitter.finish(finalText: output, parsed: parsed, structuredAccumulator: accumulator, idleState: idle, onChunk: { chunk in
            if case .reasoning(let text) = chunk { reasoning += text }
            if case .content(let text) = chunk { content += text }
        })
        XCTAssertEqual(reasoning, "Two lookups.")
        XCTAssertEqual(content, "")
        let deltas = try StreamedToolCallArgs().finalDeltas(for: emitter.reconciledToolCalls)
        let indexes = deltas.flatMap { $0 }.compactMap { $0["index"] as? Int }
        XCTAssertEqual(Set(indexes), [0, 1])
    }

    func testOmittedParallelToolCallsKeepsEveryCall() throws {
        let request = try toolRequest(model: "Jundot/GLM-5.3-Flash-oQ4e-mtp", tool: "lookup", property: "city")
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: "<tool_call>lookup<arg_key>city</arg_key><arg_value>A</arg_value></tool_call><tool_call>lookup<arg_key>city</arg_key><arg_value>B</arg_value></tool_call>",
            generatedTokenIDs: [], decode: { _ in "" }, request: request, mode: .complete(),
            defaultCompletionTokens: 9, toolCallPrefill: nil
        )
        XCTAssertEqual(parsed.toolCalls.count, 2)
    }

    func testReasoningEffortReachesTheTemplateContext() throws {
        let withTools = try toolRequest(model: "Jundot/GLM-5.3-Flash-oQ4e-mtp", tool: "lookup", property: "city")
        XCTAssertEqual(withTools.templateReasoningEffort, "low")
        let explicit = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "m", "messages": [["role": "user", "content": "x"]], "reasoning_effort": "high",
        ]))
        XCTAssertEqual(explicit.templateReasoningEffort, "high")
        let plain = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "m", "messages": [["role": "user", "content": "x"]],
        ]))
        XCTAssertNil(plain.templateReasoningEffort)
        XCTAssertThrowsError(try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "m", "messages": [["role": "user", "content": "x"]], "reasoning_effort": "ultra",
        ])))
        let input = try ModelRuntime.userInput(for: withTools)
        XCTAssertEqual(input.additionalContext?["reasoning_effort"] as? String, "low")
    }

    private func toolRequest(model: String, tool: String, property: String) throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "go"]],
            "tools": [["type": "function", "function": [
                "name": tool,
                "parameters": ["type": "object", "properties": [property: ["type": "string"]]],
            ]]],
        ]))
    }
}
