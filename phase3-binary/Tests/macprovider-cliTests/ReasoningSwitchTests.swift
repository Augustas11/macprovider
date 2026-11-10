import Foundation
import Jinja
import MLXLMCommon
import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-018 v0.3.16 (SPEC-018-R010, #2269): an explicit `reasoning_effort`
/// turns thinking on for a template with a thinking switch whose output
/// splits; omitted effort keeps the thinking-off prompt it had before.
final class ReasoningSwitchTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/tests/fixtures/chat-templates-2107/")

    private struct Family {
        let name: String
        let model: String
        let template: String
    }

    /// Thinking-on prompts that leave `<think>` open.
    private static let splitting = [
        Family(name: "Qwen3.5", model: "qwen/qwen3.5-27b", template: "qwen3.5-27b.jinja"),
        Family(name: "Qwen3.6", model: "qwen/qwen3.6-27b", template: "qwen3.6-27b.jinja"),
        Family(name: "Qwen3.8", model: "qwen/qwen3.8-27b", template: "qwen3.8-27b.jinja"),
        Family(name: "Nemotron-3", model: "nvidia/nemotron-3-nano-30b-a3b", template: "nemotron-3-nano-30b-a3b.jinja"),
    ]

    /// Thinking-on prompts with no `<think>` opener (Qwen3-8B, GLM-4.5) or a
    /// thought channel the provider does not parse (Gemma-4).
    private static let nonSplitting = [
        Family(name: "Qwen3-8B", model: "qwen3-8b", template: "qwen3-8b.jinja"),
        Family(name: "GLM-4.5", model: "z-ai/glm-4.5-air", template: "glm-4.5-air.jinja"),
        Family(name: "Gemma-4", model: "google-gemma-4-26b-a4b-it", template: "gemma-4-26b-a4b-it.jinja"),
    ]

    private static let explicitEfforts = ["minimal", "low", "medium", "high", "xhigh", "max"]

    private static let tool: [String: Any] = ["type": "function", "function": [
        "name": "lookup", "description": "Look up a city",
        "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]],
    ]]

    private func request(model: String, effort: String? = nil, extra: [String: Any] = [:]) throws -> ChatCompletionRequest {
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "Look up Paris."]]]
        if let effort { body["reasoning_effort"] = effort }
        body.merge(extra) { _, new in new }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    private func render(_ family: Family, _ input: UserInput) throws -> String {
        let source = try String(contentsOf: Self.fixtures.appendingPathComponent(family.template), encoding: .utf8)
        let template = try Template(ChatTemplateCompatibility.rewrite(source).template,
                                    with: .init(lstripBlocks: true, trimBlocks: true))
        let messages = DefaultMessageGenerator().generate(from: input)
        var context: [String: Value] = [
            "messages": try Value(any: messages.map { $0 as [String: Any] }),
            "add_generation_prompt": .boolean(true), "bos_token": .string(""), "eos_token": .string(""),
        ]
        if let tools = input.tools { context["tools"] = try Value(any: tools) }
        for (key, value) in input.additionalContext ?? [:] { context[key] = try Value(any: value) }
        return try template.render(context)
    }

    /// The provider's preparation: the shared decision and fallback, with
    /// the fixture template standing in for the tokenizer.
    private func prepared(_ family: Family, _ request: ChatCompletionRequest,
                          supportsBonsaiThinking: Bool = false) async throws -> (prompt: String, input: UserInput) {
        try await ModelRuntime.renderingRequestedThinking(
            for: request, templateSupportsThinkingToggle: true, supportsBonsaiThinking: supportsBonsaiThinking,
            render: { thinking in
                let input = try ModelRuntime.userInput(
                    for: request, templateSupportsThinkingToggle: true, toolSelectionModelID: family.model,
                    requestedThinking: thinking)
                return (try self.render(family, input), input)
            },
            promptTail: { String($0.prompt.suffix(64)) }
        )
    }

    /// The prompt every request rendered before v0.3.16.
    private func thinkingOff(_ family: Family, _ request: ChatCompletionRequest) throws -> String {
        try render(family, ModelRuntime.userInput(
            for: request, templateSupportsThinkingToggle: true, toolSelectionModelID: family.model))
    }

    // MARK: - Decision

    func testDecisionReadsTheRawBuyerEffort() throws {
        let model = "qwen/qwen3.8-27b"
        XCTAssertFalse(try ModelRuntime.explicitThinkingRequested(request(model: model)))
        XCTAssertFalse(try ModelRuntime.explicitThinkingRequested(request(model: model, extra: ["reasoning_effort": NSNull()])))
        XCTAssertFalse(try ModelRuntime.explicitThinkingRequested(request(model: model, effort: "none")))
        for effort in Self.explicitEfforts {
            XCTAssertTrue(try ModelRuntime.explicitThinkingRequested(request(model: model, effort: effort)), effort)
            // Tools auto (explicit or implied) and tool_choice none think.
            for extra: [String: Any] in [["tools": [Self.tool]], ["tools": [Self.tool], "tool_choice": "auto"],
                                         ["tools": [Self.tool], "tool_choice": "none"]] {
                XCTAssertTrue(try ModelRuntime.explicitThinkingRequested(request(model: model, effort: effort, extra: extra)))
            }
            // Guaranteed selection and structured output never think.
            for extra: [String: Any] in [
                ["tools": [Self.tool], "tool_choice": "required"],
                ["tools": [Self.tool], "tool_choice": ["type": "function", "function": ["name": "lookup"]]],
                ["response_format": ["type": "json_object"]],
                ["response_format": ["type": "json_schema", "json_schema": ["name": "a", "schema": ["type": "object"]]]],
            ] {
                XCTAssertFalse(try ModelRuntime.explicitThinkingRequested(request(model: model, effort: effort, extra: extra)),
                               "\(effort) \(extra.keys.sorted())")
            }
        }
        // Omitted effort with tools: the normalized template effort is `low`,
        // yet the raw buyer effort decides, and it is absent.
        let tools = try request(model: model, extra: ["tools": [Self.tool]])
        XCTAssertEqual(tools.templateReasoningEffort, "low")
        XCTAssertFalse(try ModelRuntime.explicitThinkingRequested(tools))
    }

    // MARK: - Render conformance

    func testOmittedEffortNoneStructuredAndGuaranteedSelectionKeepTheThinkingOffPrompt() async throws {
        let offCases: [(String?, [String: Any])] = [
            (nil, [:]), (nil, ["tools": [Self.tool]]), ("none", [:]), ("none", ["tools": [Self.tool]]),
            ("high", ["response_format": ["type": "json_object"]]),
            ("high", ["response_format": ["type": "json_schema", "json_schema": ["name": "a", "schema": ["type": "object"]]]]),
            ("high", ["tools": [Self.tool], "tool_choice": "required"]),
            ("high", ["tools": [Self.tool], "tool_choice": ["type": "function", "function": ["name": "lookup"]]]),
        ]
        for family in Self.splitting + Self.nonSplitting {
            for (effort, extra) in offCases {
                let request = try request(model: family.model, effort: effort, extra: extra)
                let (prompt, input) = try await prepared(family, request)
                let label = "\(family.name) \(effort ?? "omitted") \(extra.keys.sorted())"
                XCTAssertEqual(input.additionalContext?["enable_thinking"] as? Bool, false, label)
                XCTAssertEqual(prompt, try thinkingOff(family, request), label)
                XCTAssertFalse(ReasoningOutput.promptLeavesThinkOpen(String(prompt.suffix(64))), label)
            }
        }
    }

    func testOmittedEffortGoldenPromptTailsAreUnchanged() async throws {
        let tails = [
            "Qwen3.5": "<|im_start|>assistant\n<think>\n\n</think>\n\n",
            "Qwen3.6": "<|im_start|>assistant\n<think>\n\n</think>\n\n",
            "Qwen3.8": "<|im_start|>assistant\n<think>\n\n</think>\n\n",
            "Nemotron-3": "<|im_start|>assistant\n<think></think>",
            "Qwen3-8B": "<|im_start|>assistant\n<think>\n\n</think>\n\n",
            "GLM-4.5": "<|assistant|>\n<think></think>",
        ]
        for family in Self.splitting + Self.nonSplitting {
            let (prompt, _) = try await prepared(family, request(model: family.model))
            if let tail = tails[family.name] {
                XCTAssertTrue(prompt.hasSuffix(tail), "\(family.name): \(prompt.suffix(80))")
            }
            XCTAssertFalse(prompt.contains("Reasoning effort is set to"), family.name)
        }
    }

    func testExplicitEffortTurnsThinkingOnWhereTheOutputSplits() async throws {
        for family in Self.splitting {
            for effort in Self.explicitEfforts {
                for extra: [String: Any] in [[:], ["tools": [Self.tool]], ["tools": [Self.tool], "tool_choice": "none"]] {
                    let request = try request(model: family.model, effort: effort, extra: extra)
                    let (prompt, input) = try await prepared(family, request)
                    let label = "\(family.name) \(effort) \(extra.keys.sorted())"
                    XCTAssertEqual(input.additionalContext?["enable_thinking"] as? Bool, true, label)
                    XCTAssertTrue(ReasoningOutput.promptLeavesThinkOpen(String(prompt.suffix(64))), label)
                    XCTAssertNotEqual(prompt, try thinkingOff(family, request), label)
                    if family.name == "Qwen3.8" {
                        // high/max map to xhigh, minimal to low: the levels the
                        // template accepts with thinking on.
                        let level = ["high", "max"].contains(effort) ? "xhigh" : (effort == "minimal" ? "low" : effort)
                        XCTAssertEqual(input.additionalContext?["reasoning_effort"] as? String, level, label)
                        if level != "medium" {
                            XCTAssertTrue(prompt.contains("Reasoning effort is set to \(level)."), label)
                        }
                    }
                }
            }
        }
    }

    func testFamiliesWhoseOutputCannotSplitStayOff() async throws {
        for family in Self.nonSplitting {
            for effort in Self.explicitEfforts {
                for extra: [String: Any] in [[:], ["tools": [Self.tool]]] {
                    let request = try request(model: family.model, effort: effort, extra: extra)
                    // The thinking-on render opens no `<think>` for the provider to split.
                    let on = try render(family, ModelRuntime.userInput(
                        for: request, templateSupportsThinkingToggle: true, toolSelectionModelID: family.model,
                        requestedThinking: true))
                    XCTAssertFalse(ReasoningOutput.promptLeavesThinkOpen(String(on.suffix(64))), family.name)
                    let (prompt, input) = try await prepared(family, request)
                    XCTAssertEqual(input.additionalContext?["enable_thinking"] as? Bool, false, family.name)
                    XCTAssertEqual(prompt, try thinkingOff(family, request), "\(family.name) \(effort)")
                }
            }
        }
    }

    func testRejectedThinkingRenderFallsBackToTheThinkingOffPrompt() async throws {
        let request = try request(model: "qwen/qwen3.8-27b", effort: "high")
        var renders: [Bool] = []
        let prompt = try await ModelRuntime.renderingRequestedThinking(
            for: request, templateSupportsThinkingToggle: true, supportsBonsaiThinking: false,
            render: { thinking -> String in
                renders.append(thinking)
                if thinking { throw APIError(status: 400, message: "Unexpected reasoning effort", code: "chat_template_error") }
                return "<|im_start|>assistant\n<think>\n\n</think>\n\n"
            },
            promptTail: { $0 }
        )
        XCTAssertEqual(renders, [true, false])
        XCTAssertEqual(prompt, "<|im_start|>assistant\n<think>\n\n</think>\n\n")
    }

    func testNoSwitchOrBonsaiCapabilityNeverRendersTheGeneralRule() async throws {
        let request = try request(model: "qwen/qwen3.6-27b", effort: "medium")
        for (toggle, bonsai) in [(false, false), (true, true)] {
            var renders: [Bool] = []
            _ = try await ModelRuntime.renderingRequestedThinking(
                for: request, templateSupportsThinkingToggle: toggle, supportsBonsaiThinking: bonsai,
                render: { thinking -> String in renders.append(thinking); return "<think>\n" },
                promptTail: { $0 }
            )
            XCTAssertEqual(renders, [false], "toggle \(toggle) bonsai \(bonsai)")
        }
    }

    // MARK: - Parse conformance

    private func thinkingRequest(effort: String = "high", tools: Bool = false) throws -> ChatCompletionRequest {
        let request = try request(model: "qwen/qwen3.6-27b", effort: effort, extra: tools ? ["tools": [Self.tool]] : [:])
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .qwen, reasoningOpen: true))
        return request
    }

    private func parse(_ output: String, _ request: ChatCompletionRequest,
                       finishReason: String? = nil) throws -> ModelRuntime.ParsedGeneratedOutput {
        try ModelRuntime.parseGeneratedOutput(
            filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request,
            mode: .complete(finishReason: finishReason), defaultCompletionTokens: 64, toolCallPrefill: nil)
    }

    private func stream(_ output: String, _ request: ChatCompletionRequest) throws -> (reasoning: String, content: String, calls: [String]) {
        var emitter = SerialStreamingTextEmitter(request: request)
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        var reasoning = ""
        var content = ""
        for end in 1...output.count {
            _ = emitter.step(
                candidate: (String(output.prefix(end)), false), structuredAccumulator: accumulator, idleState: idle,
                onChunk: { chunk in
                    if case .reasoning(let text) = chunk { reasoning += text }
                    if case .content(let text) = chunk { content += text }
                })
        }
        try emitter.finish(finalText: output, parsed: try parse(output, request), structuredAccumulator: accumulator,
                           idleState: idle, onChunk: { chunk in
            if case .reasoning(let text) = chunk { reasoning += text }
            if case .content(let text) = chunk { content += text }
        })
        return (reasoning, content, emitter.reconciledToolCalls.map(\.functionName))
    }

    func testThinkingOutputSplitsNonStreamingAndStreaming() throws {
        let output = "The user wants a greeting.</think>\n\nHello!"
        let parsed = try parse(output, thinkingRequest())
        XCTAssertEqual(parsed.reasoningContent, "The user wants a greeting.")
        XCTAssertEqual(parsed.content, "Hello!")
        let streamed = try stream(output, thinkingRequest())
        XCTAssertEqual(streamed.reasoning, "The user wants a greeting.")
        XCTAssertEqual(streamed.content, "Hello!")
    }

    func testThinkingOutputWithToolsParsesTheCallAfterTheSplit() throws {
        let output = "I should look it up.</think>\n\n<tool_call>\n<function=lookup>\n<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>"
        let parsed = try parse(output, thinkingRequest(tools: true))
        XCTAssertEqual(parsed.reasoningContent, "I should look it up.")
        XCTAssertEqual(parsed.toolCalls.map(\.functionName), ["lookup"])
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"city":"Paris"}"#])
        XCTAssertEqual(parsed.content, "")
        let streamed = try stream(output, thinkingRequest(tools: true))
        XCTAssertEqual(streamed.reasoning, "I should look it up.")
        XCTAssertEqual(streamed.calls, ["lookup"])
        XCTAssertFalse(streamed.content.contains("<tool_call>"))
    }

    func testTruncatedThinkingIsAllReasoningWithEmptyContent() throws {
        let output = "Let me think about every city in"
        let parsed = try parse(output, thinkingRequest(), finishReason: "length")
        XCTAssertEqual(parsed.reasoningContent, output)
        XCTAssertEqual(parsed.content, "")
        XCTAssertTrue(parsed.toolCalls.isEmpty)
        let streamed = try stream(output, thinkingRequest())
        XCTAssertEqual(streamed.reasoning, output)
        XCTAssertEqual(streamed.content, "")
    }
}
