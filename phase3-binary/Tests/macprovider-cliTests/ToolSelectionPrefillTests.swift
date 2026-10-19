import Foundation
import MacProviderCore
import MLXLMCommon
import XCTest
@testable import macprovider_cli

/// #2014: guaranteed selection starts generation inside the call (SPEC-018
/// §3.11 call prefill) instead of relying on an instruction alone.
final class ToolSelectionPrefillTests: XCTestCase {
    private let qwen = ToolSelectionPolicy.supportedNativeModel
    private let generationPrompt = "<|im_start|>assistant\n<think>\n\n</think>\n\n"

    private func request(choice: Any, model: String = ToolSelectionPolicy.supportedNativeModel) throws -> ChatCompletionRequest {
        let schema: [String: Any] = [
            "type": "object", "properties": ["city": ["type": "string"]],
            "required": ["city"], "additionalProperties": false,
        ]
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "What's the weather in Paris?"]],
            "tool_choice": choice, "max_tokens": 100,
            "tools": [
                ["type": "function", "function": ["name": "get_weather", "parameters": schema]],
                ["type": "function", "function": ["name": "get_time", "parameters": schema]],
            ],
        ]))
    }

    private func named(_ name: String) -> [String: Any] {
        ["type": "function", "function": ["name": name]]
    }

    private func renderedToolNames(_ input: UserInput) -> [String]? {
        input.tools?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    }

    // MARK: Per-model format table

    func testPrefillFollowsEachModelsCallFormat() {
        let xml = ToolSelectionPolicy.GuaranteedCallProfile(format: .functionXML, generationPromptSuffix: "")
        let json = ToolSelectionPolicy.GuaranteedCallProfile(format: .jsonEnvelope, generationPromptSuffix: "")
        XCTAssertEqual(xml.prefill(for: .required), "<tool_call>\n")
        XCTAssertEqual(xml.prefill(for: .named("get_time")), "<tool_call>\n<function=get_time>\n")
        XCTAssertEqual(json.prefill(for: .required), "<tool_call>\n")
        XCTAssertEqual(json.prefill(for: .named("get_time")), "<tool_call>\n{\"name\": \"get_time\", \"arguments\": ")
        for profile in [xml, json] {
            XCTAssertNil(profile.prefill(for: .auto))
            XCTAssertNil(profile.prefill(for: .none))
        }
        let qwen = ToolSelectionPolicy.guaranteedCallProfile(modelID: self.qwen)
        XCTAssertEqual(qwen?.format, .functionXML)
        XCTAssertEqual(qwen?.generationPromptSuffix, generationPrompt)
        XCTAssertNil(ToolSelectionPolicy.guaranteedCallProfile(modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"))
        XCTAssertNil(ToolSelectionPolicy.guaranteedCallProfile(modelID: nil))
        // Guaranteed modes are advertised exactly for models with a profile.
        XCTAssertEqual(ToolSelectionPolicy.modes(modelID: self.qwen, runtime: "mlx_cache"), ["auto", "none", "required", "named"])
        XCTAssertEqual(ToolSelectionPolicy.modes(modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit", runtime: "mlx_cache"), ["auto", "none"])
    }

    // MARK: Prompt assembly per mode

    func testCatalogProfilesUseTheirPinnedTemplateGrammarAndSuffix() throws {
        let candidates: [(String, ToolSelectionPolicy.CallFormat, String, String)] = [
            ("mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", .functionXML,
             "<tool_call>\n<function=get_time>\n", "<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>"),
            ("mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit", .jsonEnvelope,
             "<tool_call>\n{\"name\": \"get_time\", \"arguments\": ", "{\"city\":\"Paris\"}}\n</tool_call>"),
        ]
        let tokenizer = PrefillFixtureTokenizer()
        let suffix = "<|im_start|>assistant\n"
        for (model, format, namedPrefill, continuation) in candidates {
            let profile = try XCTUnwrap(ToolSelectionPolicy.guaranteedCallProfile(modelID: model))
            XCTAssertEqual(profile.format, format)
            XCTAssertEqual(profile.generationPromptSuffix, suffix)
            for choice in ["required", named("get_time")] as [Any] {
                let request = try request(choice: choice, model: model)
                let plan = try XCTUnwrap(ModelRuntime.toolCallPrefill(for: request, toolSelectionModelID: model))
                let selection = try ToolSelectionPolicy.selection(request.promptSource.toolChoice)
                XCTAssertEqual(plan.prefill, selection == .required ? "<tool_call>\n" : namedPrefill)
                let prompt = tokenizer.encode(text: "<|im_start|>user\nHi<|im_end|>\n" + suffix, addSpecialTokens: false)
                XCTAssertEqual(ModelRuntime.appendingToolCallPrefill(plan.prefill, generationPromptSuffix: plan.generationPromptSuffix,
                    to: prompt, tokenizer: tokenizer), prompt + tokenizer.encode(text: plan.prefill, addSpecialTokens: false))
                for mismatch in [suffix + "<think>\n", generationPrompt, "<|im_start|>assistant "] {
                    XCTAssertNil(ModelRuntime.appendingToolCallPrefill(plan.prefill, generationPromptSuffix: plan.generationPromptSuffix,
                        to: tokenizer.encode(text: mismatch, addSpecialTokens: false), tokenizer: tokenizer))
                }
                let generated = String(namedPrefill.dropFirst(plan.prefill.count)) + continuation
                let parsed = try ModelRuntime.parseGeneratedOutput(filteredText: generated, generatedTokenIDs: [], decode: { _ in "" },
                    request: request, mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: plan.prefill)
                XCTAssertEqual(parsed.content, "")
                XCTAssertEqual(parsed.toolCalls.map(\.functionName), ["get_time"])
                XCTAssertEqual(parsed.toolCalls.first?.arguments, #"{"city":"Paris"}"#)
                XCTAssertNoThrow(try ModelRuntime.validateStructuredCompletion(CompletionResult(content: parsed.content, finishReason: "stop",
                    promptTokens: 1, completionTokens: 9, toolCalls: parsed.toolCalls, settlementDisposition: .eligibleOwner), request: request))
                for invalid in [String(generated.dropLast()), generated + " trailing prose"] {
                    XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(filteredText: invalid, generatedTokenIDs: [], decode: { _ in "" },
                        request: request, mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: plan.prefill))
                }
                XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: parsed.toolCalls, finishReason: "length", generatedTokens: 100, request: request))
            }
        }
    }

    func testNamedChoiceRendersOnlyTheSelectedFunction() throws {
        XCTAssertEqual(renderedToolNames(try ModelRuntime.userInput(for: request(choice: named("get_time")))), ["get_time"])
        XCTAssertEqual(renderedToolNames(try ModelRuntime.userInput(for: request(choice: "required"))), ["get_weather", "get_time"])
        XCTAssertEqual(renderedToolNames(try ModelRuntime.userInput(for: request(choice: "auto"))), ["get_weather", "get_time"])
        XCTAssertNil(try ModelRuntime.userInput(for: request(choice: "none")).tools)
    }

    func testPrefillPlanPerModeAndModel() throws {
        let required = try ModelRuntime.toolCallPrefill(for: request(choice: "required"), toolSelectionModelID: qwen)
        XCTAssertEqual(required?.prefill, "<tool_call>\n")
        XCTAssertEqual(required?.generationPromptSuffix, generationPrompt)
        let namedPlan = try ModelRuntime.toolCallPrefill(for: request(choice: named("get_time")), toolSelectionModelID: qwen)
        XCTAssertEqual(namedPlan?.prefill, "<tool_call>\n<function=get_time>\n")
        XCTAssertNil(try ModelRuntime.toolCallPrefill(for: request(choice: "auto"), toolSelectionModelID: qwen))
        XCTAssertNil(try ModelRuntime.toolCallPrefill(for: request(choice: "none"), toolSelectionModelID: qwen))
        // The plan keys on the loaded tool-selection identity, not on the
        // buyer's model string: an alias request resolves through the runtime.
        XCTAssertNotNil(try ModelRuntime.toolCallPrefill(for: request(choice: "required", model: "qwen/qwen3.6-35b-a3b"), toolSelectionModelID: qwen))
        XCTAssertNil(try ModelRuntime.toolCallPrefill(for: request(choice: "required"), toolSelectionModelID: "local/other"))
        XCTAssertNil(try ModelRuntime.toolCallPrefill(for: request(choice: "required"), toolSelectionModelID: nil))
        // An undeclared name never reaches the prompt.
        XCTAssertThrowsError(try ModelRuntime.toolCallPrefill(for: request(choice: named("rm_rf")), toolSelectionModelID: qwen))
    }

    func testPrefillIsAppendedOnlyAfterAClosedThinkBlock() throws {
        let tokenizer = PrefillFixtureTokenizer()
        let closed = tokenizer.encode(text: "<|im_start|>user\nhi<|im_end|>\n" + generationPrompt, addSpecialTokens: false)
        let prefill = "<tool_call>\n<function=get_time>\n"
        let appended = ModelRuntime.appendingToolCallPrefill(
            prefill, generationPromptSuffix: generationPrompt, to: closed, tokenizer: tokenizer
        )
        XCTAssertEqual(appended, closed + tokenizer.encode(text: prefill, addSpecialTokens: false))
        XCTAssertEqual(tokenizer.decode(tokenIds: appended ?? [], skipSpecialTokens: false).hasSuffix("</think>\n\n" + prefill), true)
        // Thinking on: the generation prompt leaves `<think>` open, so a call
        // prefill would cut the reasoning block; the turn keeps validation only.
        let thinking = tokenizer.encode(text: "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n<think>\n", addSpecialTokens: false)
        XCTAssertNil(ModelRuntime.appendingToolCallPrefill(
            prefill, generationPromptSuffix: generationPrompt, to: thinking, tokenizer: tokenizer
        ))
        XCTAssertNil(ModelRuntime.appendingToolCallPrefill(
            prefill, generationPromptSuffix: generationPrompt, to: [], tokenizer: tokenizer
        ))
    }

    /// Token-keyed caches (conversation cache, batched prefix reuse) key on the
    /// prompt token IDs. The prefill is part of those tokens, so two turns that
    /// differ only in the selection never share a cache key.
    func testPrefillIsPartOfThePromptTokensThatKeyTheCache() throws {
        let tokenizer = PrefillFixtureTokenizer()
        let base = tokenizer.encode(text: "<|im_start|>user\nhi<|im_end|>\n" + generationPrompt, addSpecialTokens: false)
        func prompt(_ choice: Any) throws -> [Int] {
            guard let plan = try ModelRuntime.toolCallPrefill(for: request(choice: choice), toolSelectionModelID: qwen) else {
                return base
            }
            return try XCTUnwrap(ModelRuntime.appendingToolCallPrefill(
                plan.prefill, generationPromptSuffix: plan.generationPromptSuffix, to: base, tokenizer: tokenizer
            ))
        }
        let keys = try [prompt("auto"), prompt("required"), prompt(named("get_time")), prompt(named("get_weather"))]
        XCTAssertEqual(Set(keys).count, keys.count)
        for key in keys.dropFirst() {
            XCTAssertEqual(Array(key.prefix(base.count)), base, "the rendered conversation stays a reusable prefix")
            XCTAssertGreaterThan(key.count, base.count)
        }
    }

    // MARK: Parser on prefill + continuation

    func testParserReadsPrefillPlusContinuation() throws {
        let continuation = "<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>"
        let named = try request(choice: self.named("get_time"))
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: continuation, generatedTokenIDs: [], decode: { _ in "" }, request: named,
            mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: "<tool_call>\n<function=get_time>\n"
        )
        XCTAssertEqual(parsed.toolCalls.map(\.functionName), ["get_time"])
        XCTAssertEqual(parsed.toolCalls.first?.arguments, #"{"city":"Paris"}"#)
        XCTAssertNoThrow(try ModelRuntime.validateStructuredCompletion(CompletionResult(
            content: parsed.content, finishReason: "stop", promptTokens: 1, completionTokens: 9,
            toolCalls: parsed.toolCalls, settlementDisposition: .eligibleOwner
        ), request: named))

        let required = try request(choice: "required")
        let requiredParsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: "<function=get_weather>\n" + continuation, generatedTokenIDs: [], decode: { _ in "" },
            request: required, mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: "<tool_call>\n"
        )
        XCTAssertEqual(requiredParsed.toolCalls.map(\.functionName), ["get_weather"])

        // The JSON-envelope prefill for a named choice continues as its arguments.
        let jsonParsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: #"{"city": "Paris"}}"# + "\n</tool_call>", generatedTokenIDs: [], decode: { _ in "" },
            request: named, mode: .complete(), defaultCompletionTokens: 9,
            toolCallPrefill: "<tool_call>\n{\"name\": \"get_time\", \"arguments\": "
        )
        XCTAssertEqual(jsonParsed.toolCalls.map(\.functionName), ["get_time"])
        XCTAssertEqual(jsonParsed.toolCalls.first?.arguments, #"{"city":"Paris"}"#)

        // The continuation alone is not a call; without the prefill it fails.
        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: continuation, generatedTokenIDs: [], decode: { _ in "" }, request: named,
            mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: nil
        ))
    }

    func testPrefilledParallelCallsAndWrongFunctionAfterNamedPrefill() throws {
        let call = "<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>"
        var body = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: [
            "model": qwen, "messages": [["role": "user", "content": "x"]], "max_tokens": 100,
            "tool_choice": "required", "parallel_tool_calls": true,
            "tools": [["type": "function", "function": ["name": "get_time", "parameters": [
                "type": "object", "properties": ["city": ["type": "string"]],
                "required": ["city"], "additionalProperties": false,
            ]]]],
        ])) as! [String: Any]
        let required = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
        let two = try ModelRuntime.parseGeneratedOutput(
            filteredText: "<function=get_time>\n" + call + "\n<tool_call>\n<function=get_time>\n" + call,
            generatedTokenIDs: [], decode: { _ in "" }, request: required, mode: .complete(),
            defaultCompletionTokens: 9, toolCallPrefill: "<tool_call>\n"
        )
        XCTAssertEqual(two.toolCalls.map(\.functionName), ["get_time", "get_time"])
        XCTAssertNoThrow(try ModelRuntime.validateStructuredCompletion(CompletionResult(
            content: two.content, finishReason: "stop", promptTokens: 1, completionTokens: 9,
            toolCalls: two.toolCalls, settlementDisposition: .eligibleOwner
        ), request: required))

        // Named prefill fixes the first call; a second call to another
        // function still fails validation and exposes nothing.
        body["tool_choice"] = named("get_time")
        body["tools"] = (body["tools"] as! [[String: Any]]) + [["type": "function", "function": ["name": "get_weather", "parameters": [
            "type": "object", "properties": ["city": ["type": "string"]],
            "required": ["city"], "additionalProperties": false,
        ]]]]
        let named = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
        let mixed = try ModelRuntime.parseGeneratedOutput(
            filteredText: call + "\n<tool_call>\n<function=get_weather>\n" + call,
            generatedTokenIDs: [], decode: { _ in "" }, request: named, mode: .complete(),
            defaultCompletionTokens: 9, toolCallPrefill: "<tool_call>\n<function=get_time>\n"
        )
        XCTAssertThrowsError(try ModelRuntime.validateStructuredCompletion(CompletionResult(
            content: mixed.content, finishReason: "stop", promptTokens: 1, completionTokens: 9,
            toolCalls: mixed.toolCalls, settlementDisposition: .eligibleOwner
        ), request: named)) { error in
            XCTAssertEqual((error as? APIError)?.code, "tool_selection_validation_failed")
        }
        // Trailing text after the prefilled call is not a successful call.
        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: call + " done", generatedTokenIDs: [], decode: { _ in "" }, request: named,
            mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: "<tool_call>\n<function=get_time>\n"
        ))
    }

    /// SPEC-038 AC-6c batched rows parse the prefill they were prompted with.
    func testBatchedRowFinalizeParsesItsPrefill() throws {
        let pieces = ["<parameter=city>", "\nParis\n", "</parameter>", "\n</function>", "\n</tool_call>"]
        let ids = Array(pieces.indices)
        let request = try request(choice: named("get_time"))
        let result = ContinuousBatchSchedulerResult(
            requestID: "r", conversationKey: "", generatedTokens: ids, outputTokens: ids,
            promptTokens: 3, completionTokens: ids.count, emittedTokens: ids.count, cachedPromptTokens: 0,
            terminalStatus: .stop, errorCode: nil, snapshot: nil, settlementDisposition: .eligibleOwner,
            retainedCache: nil, stopCause: nil
        )
        func finalize(_ prefill: String?) throws -> ModelRuntime.ContinuousBatchFinalizedRow {
            try ModelRuntime.finalizeContinuousBatchRow(
                request: request, result: result, modelStopTokenIDs: [], promptTokenIDs: [1, 2, 3],
                decode: { $0.map { pieces[$0] }.joined() }, stopTokenFilter: StopTokenFilter(tokens: []),
                generationMilliseconds: 0, modelHash: nil, toolCallPrefill: prefill
            )
        }
        let row = try finalize("<tool_call>\n<function=get_time>\n")
        XCTAssertEqual(row.completion.toolCalls?.map(\.functionName), ["get_time"])
        XCTAssertEqual(row.completion.content, "")
        XCTAssertEqual(row.completion.finishReason, "tool_calls")
        XCTAssertThrowsError(try finalize(nil), "a row that loses its prefill must fail, not succeed")
    }

    func testPrefillRequiresTheSameTokensAsJointEncoding() {
        // A tokenizer that merges across the boundary would change the token
        // sequence; the prefill is then skipped (validation only).
        struct MergingTokenizer: MLXLMCommon.Tokenizer {
            let base = PrefillFixtureTokenizer()
            var bosToken: String? { nil }
            var eosToken: String? { base.eosToken }
            var unknownToken: String? { nil }
            func encode(text: String, addSpecialTokens: Bool) -> [Int] {
                text.hasSuffix("</think>\n\n<tool_call>\n") ? [9_999] : base.encode(text: text, addSpecialTokens: addSpecialTokens)
            }
            func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { base.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens) }
            func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
            func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
            func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
        }
        let tokenizer = MergingTokenizer()
        let prompt = tokenizer.encode(text: generationPrompt, addSpecialTokens: false)
        XCTAssertNil(ModelRuntime.appendingToolCallPrefill(
            "<tool_call>\n", generationPromptSuffix: generationPrompt, to: prompt, tokenizer: tokenizer
        ))
    }

    /// A profiled model served under a local alias renders tool history in its
    /// own template format.
    func testAliasRequestRendersHistoryWithTheProfiledIdentity() throws {
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "local/served-name", "max_tokens": 100, "tool_choice": named("get_time"),
            "messages": [
                ["role": "user", "content": "Weather?"],
                ["role": "assistant", "content": "", "tool_calls": [["id": "call_0123456789abcdef", "type": "function",
                    "function": ["name": "get_weather", "arguments": #"{"city":"Paris"}"#]]]],
                ["role": "tool", "tool_call_id": "call_0123456789abcdef", "content": "sunny"],
                ["role": "user", "content": "And the time?"],
            ],
            "tools": [["type": "function", "function": ["name": "get_weather", "parameters": [
                "type": "object", "properties": ["city": ["type": "string"]],
                "required": ["city"], "additionalProperties": false,
            ]]], ["type": "function", "function": ["name": "get_time", "parameters": [
                "type": "object", "properties": ["city": ["type": "string"]],
                "required": ["city"], "additionalProperties": false,
            ]]]],
        ]))
        XCTAssertThrowsError(try ModelRuntime.userInput(for: request), "unchanged without a profiled identity")
        let input = try ModelRuntime.userInput(for: request, toolSelectionModelID: qwen)
        XCTAssertEqual(renderedToolNames(input), ["get_time"])
    }

    // MARK: Buyer-visible output

    func testPrefillIsNeverBuyerVisible() throws {
        let prefill = "<tool_call>\n<function=get_time>\n"
        let named = try request(choice: self.named("get_time"))
        let success = try ModelRuntime.parseGeneratedOutput(
            filteredText: "<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>",
            generatedTokenIDs: [], decode: { _ in "" }, request: named,
            mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: prefill
        )
        XCTAssertEqual(success.content, "")
        XCTAssertFalse(success.toolCalls.contains { $0.arguments.contains("<tool_call>") || $0.arguments.contains("<function=") })
        // A continuation that never closes the call fails validation; neither
        // the error nor any content carries the internal prefill.
        for continuation in ["", "Sure, here is the time.", "<parameter=city>\nParis\n</parameter>\n</function>"] {
            do {
                let parsed = try ModelRuntime.parseGeneratedOutput(
                    filteredText: continuation, generatedTokenIDs: [], decode: { _ in "" }, request: named,
                    mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: prefill
                )
                XCTAssertFalse(parsed.content.contains("<function="))
                XCTAssertThrowsError(try ModelRuntime.validateStructuredCompletion(CompletionResult(
                    content: parsed.content, finishReason: "stop", promptTokens: 1, completionTokens: 9,
                    toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls, settlementDisposition: .eligibleOwner
                ), request: named))
            } catch let error as APIError {
                XCTAssertEqual(error.code, "tool_selection_validation_failed")
                XCTAssertFalse(error.message.contains("<function="))
            }
        }
    }
}

/// Splits on the Qwen special tokens the generation prompt uses; every other
/// character is one token. Enough to check token-level suffix matching.
private struct PrefillFixtureTokenizer: MLXLMCommon.Tokenizer {
    private static let specials = ["<|im_start|>", "<|im_end|>", "<think>", "</think>", "<tool_call>", "</tool_call>"]

    let bosToken: String? = nil
    let eosToken: String? = "<|im_end|>"
    let unknownToken: String? = nil

    func encode(text: String, addSpecialTokens _: Bool) -> [Int] {
        var tokens: [Int] = []
        var rest = Substring(text)
        outer: while !rest.isEmpty {
            for (index, special) in Self.specials.enumerated() where rest.hasPrefix(special) {
                tokens.append(index)
                rest = rest.dropFirst(special.count)
                continue outer
            }
            tokens.append(1000 + Int(rest.unicodeScalars.first!.value))
            rest = rest.dropFirst()
        }
        return tokens
    }

    func decode(tokenIds: [Int], skipSpecialTokens _: Bool) -> String {
        tokenIds.map { id in
            id < Self.specials.count ? Self.specials[id] : String(UnicodeScalar(UInt32(id - 1000))!)
        }.joined()
    }

    func convertTokenToId(_ token: String) -> Int? {
        Self.specials.firstIndex(of: token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        id < Self.specials.count ? Self.specials[id] : nil
    }

    func applyChatTemplate(
        messages _: [[String: any Sendable]],
        tools _: [[String: any Sendable]]?,
        additionalContext _: [String: any Sendable]?
    ) throws -> [Int] {
        []
    }
}
