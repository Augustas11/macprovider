import Foundation
import MLXLMCommon
import MacProviderCore
import Tokenizers
@testable import macprovider_cli
import XCTest

/// DeepSeek-V4 prompt encoding and DSML output parsing against the model's own
/// Python reference (`encoding/encoding_dsv4.py`). The goldens in
/// `scripts/tests/fixtures/dsv4-encoding/cases.json` are written by
/// `scripts/lab/dsv4/make_encoding_fixtures.py` from that file.
final class DeepseekV4EncodingTests: XCTestCase {
    private typealias Encoding = DeepseekV4Encoding

    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/tests/fixtures/dsv4-encoding/cases.json")

    private func cases() throws -> Encoding.Value {
        // Order-keeping parse: the reference cases are byte-exact only with
        // their keys in file order, as Python reads them.
        try Encoding.parseJSON(String(contentsOf: Self.fixture, encoding: .utf8))
    }

    private static let model = "deepseek/deepseek-v4-flash"

    /// The reference's own four golden prompts, byte for byte.
    func testReferenceGoldenPromptsMatchByteForByte() throws {
        let fixtures = try cases()
        XCTAssertEqual(fixtures["reference_sha256"]?.string, "abc0d26120250dda0ae077dc64aa28836026e61e970854aaeb792445e6a0dde6")
        let reference = try XCTUnwrap(fixtures["reference"]?.array)
        XCTAssertEqual(reference.count, 4)
        for item in reference {
            let mode = try XCTUnwrap(Encoding.ThinkingMode(rawValue: item["thinking_mode"]?.string ?? ""))
            let prompt = try Encoding.encodeMessages(try XCTUnwrap(item["messages"]?.array), thinkingMode: mode)
            XCTAssertEqual(prompt, item["prompt"]?.string, item["name"]?.string ?? "")
        }
    }

    /// Buyer requests through the provider's own prompt path (tool-history
    /// rendering, message generator, the DSV4 tokenizer's encoder) render
    /// exactly what the reference renders for them.
    func testProviderRequestsRenderTheReferencePrompt() throws {
        let requests = try XCTUnwrap(cases()["requests"]?.array)
        XCTAssertGreaterThanOrEqual(requests.count, 14)
        for item in requests {
            let name = item["name"]?.string ?? ""
            let body = try XCTUnwrap(item["request"])
            let request = try ChatCompletionRequest.parse(data: Data(Encoding.toJSON(body).utf8))
            XCTAssertEqual(ModelRuntime.toolGrammar(for: request), .dsml, name)
            let input = try ModelRuntime.userInput(for: request)
            let prompt = try Encoding.renderPrompt(
                messages: DefaultMessageGenerator().generate(from: input),
                tools: input.tools,
                additionalContext: input.additionalContext
            )
            XCTAssertEqual(prompt, item["prompt"]?.string, name)
        }
    }

    /// The prompt leaves `<think>` open in thinking mode and closes it in chat
    /// mode, which is what the runtime's reasoning split keys on.
    func testThinkingModeOpensTheReasoningBlock() throws {
        let thinking = try Encoding.renderPrompt(messages: [["role": "user", "content": "hi"]], tools: nil, additionalContext: nil)
        XCTAssertTrue(thinking.hasSuffix("<｜Assistant｜><think>"))
        XCTAssertTrue(ReasoningOutput.promptLeavesThinkOpen(String(thinking.suffix(40))))
        let chat = try Encoding.renderPrompt(
            messages: [["role": "user", "content": "hi"]], tools: nil, additionalContext: ["reasoning_effort": "none"]
        )
        XCTAssertTrue(chat.hasSuffix("<｜Assistant｜></think>"))
        XCTAssertFalse(ReasoningOutput.promptLeavesThinkOpen(String(chat.suffix(40))))
        let disabled = try Encoding.renderPrompt(
            messages: [["role": "user", "content": "hi"]], tools: nil, additionalContext: ["enable_thinking": false]
        )
        XCTAssertEqual(disabled, chat)
    }

    func testPythonJSONSerialization() throws {
        let value = try Encoding.parseJSON(#"{"b": [1, 2.5, 1e-05, 1e16, true, null], "a": "é\t\u0001\"\\/</x>"}"#)
        XCTAssertEqual(Encoding.toJSON(value), #"{"b": [1, 2.5, 1e-05, 1e+16, true, null], "a": "é\t\u0001\"\\/</x>"}"#)
    }

    // MARK: - DSML output parsing

    private static let tools: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "read_file",
            "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]],
        ]],
        ["type": "function", "function": [
            "name": "search",
            "parameters": ["type": "object", "properties": [
                "query": ["type": "string"], "limit": ["type": "integer"], "score": ["type": "number"],
                "filters": ["type": "object"], "tags": ["type": "array"],
            ]],
        ]],
        ["type": "function", "function": ["name": "no_description", "parameters": ["type": "object", "properties": [:]]]],
    ]

    private func toolRequest(reasoningEffort: String? = nil) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": Self.model,
            "messages": [["role": "user", "content": "go"]],
            "tools": Self.tools,
        ]
        body["reasoning_effort"] = reasoningEffort
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    private func jsonValue(_ value: Encoding.Value) throws -> MacProviderCore.JSONValue {
        try StrictJSONParser.parse(Encoding.toJSON(value))
    }

    /// Every completion the reference parses yields the same reasoning,
    /// content and calls through the runtime's reasoning split and DSML
    /// parser (arguments compared as JSON values; the runtime writes them
    /// canonically).
    func testCompletionsParseAsTheReferenceParsesThem() throws {
        let completions = try XCTUnwrap(cases()["completions"]?.array)
        XCTAssertEqual(completions.count, 7)
        for item in completions {
            let name = item["name"]?.string ?? ""
            let thinking = item["thinking_mode"]?.string == "thinking"
            let request = try toolRequest(reasoningEffort: thinking ? nil : "none")
            request.outputState.resolve(RequestOutputTraits(toolGrammar: .dsml, reasoningOpen: thinking))
            // The runtime's stop filter removes the end-of-sentence token.
            let text = try XCTUnwrap(item["text"]?.string).replacingOccurrences(of: Encoding.eosToken, with: "")
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: text, generatedTokenIDs: Array(0..<8), decode: { ids in String(text.prefix(ids.count * 8)) },
                request: request, mode: .complete(), defaultCompletionTokens: 8, toolCallPrefill: nil
            )
            XCTAssertEqual(parsed.reasoningContent ?? "", item["reasoning_content"]?.string, name)
            // The reference keeps the separator before the call block in
            // `content`; the runtime trims it.
            XCTAssertEqual(
                parsed.content.trimmingCharacters(in: .whitespacesAndNewlines),
                item["content"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), name
            )
            let expected = try XCTUnwrap(item["tool_calls"]?.array)
            XCTAssertEqual(parsed.toolCalls.map(\.functionName), expected.map { $0["name"]?.string ?? "" }, name)
            for (call, want) in zip(parsed.toolCalls, expected) {
                XCTAssertEqual(try StrictJSONParser.parse(call.arguments), try jsonValue(try XCTUnwrap(want["arguments"])), name)
            }
            XCTAssertEqual(Set(parsed.toolCalls.map(\.id)).count, parsed.toolCalls.count, name)
        }
    }

    private func parse(_ raw: String, schemas: [String: MacProviderCore.JSONValue]? = nil) -> [macprovider_cli.ToolCall] {
        ToolCallParser.parseToolCalls(
            rawOutput: raw, grammar: .dsml, modelID: Self.model,
            allowedFunctionNames: ["read_file", "search", "no_description"], schemas: schemas
        ).toolCalls
    }

    private func invoke(_ name: String, _ parameters: String) -> String {
        "<｜DSML｜invoke name=\"\(name)\">\n\(parameters)\n</｜DSML｜invoke>"
    }

    private func parameter(_ name: String, _ value: String, string: Bool = true) -> String {
        "<｜DSML｜parameter name=\"\(name)\" string=\"\(string)\">\(value)</｜DSML｜parameter>"
    }

    func testDSMLParserTypesValuesAndFailsClosed() throws {
        let schemas: [String: MacProviderCore.JSONValue] = [
            "search": try MacProviderCore.JSONValue.parse([
                "type": "object",
                "properties": ["query": ["type": "string"], "limit": ["type": "integer"]],
            ]),
        ]
        func block(_ body: String) -> String { "<｜DSML｜tool_calls>\n\(body)\n</｜DSML｜tool_calls>" }
        // A string-flagged value for a declared integer that parses as one is typed;
        // a JSON-flagged value for a declared string stays text.
        XCTAssertEqual(
            parse(block(invoke("search", parameter("limit", "5") + "\n" + parameter("query", "42", string: false))), schemas: schemas)
                .first?.arguments,
            #"{"limit":5,"query":"42"}"#
        )
        // A declared integer that is not one is malformed, never coerced.
        XCTAssertTrue(parse(block(invoke("search", parameter("limit", "five", string: false))), schemas: schemas).isEmpty)
        // An undeclared JSON-flagged value that is not JSON stays text.
        XCTAssertEqual(parse(block(invoke("read_file", parameter("path", "a b", string: false)))).first?.arguments, #"{"path":"a b"}"#)
        // Duplicate parameter, undeclared function, bad flag, unclosed parameter.
        XCTAssertTrue(parse(block(invoke("read_file", parameter("path", "a") + parameter("path", "b")))).isEmpty)
        XCTAssertTrue(parse(block(invoke("rm", parameter("path", "/")))).isEmpty)
        XCTAssertTrue(parse(block(invoke("read_file", "<｜DSML｜parameter name=\"path\" string=\"yes\">a</｜DSML｜parameter>"))).isEmpty)
        XCTAssertTrue(parse("<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"read_file\">\n<｜DSML｜parameter name=\"path\" string=\"true\">a").isEmpty)
        // The final block may end at the end of output (the EOS token replaced its close).
        XCTAssertEqual(parse("<｜DSML｜tool_calls>\n" + invoke("read_file", parameter("path", "a"))).count, 1)
        // Markup text inside a value is data.
        XCTAssertEqual(
            parse(block(invoke("read_file", parameter("path", "<｜DSML｜invoke name=\"x\">")))).first?.arguments,
            #"{"path":"<｜DSML｜invoke name=\"x\">"}"#
        )
        // Two blocks and two invokes in one block give three calls, in order.
        let three = parse(block(invoke("read_file", parameter("path", "a")) + "\n" + invoke("read_file", parameter("path", "b")))
            + "\n\n" + block(invoke("read_file", parameter("path", "c"))))
        XCTAssertEqual(three.map(\.arguments), [#"{"path":"a"}"#, #"{"path":"b"}"#, #"{"path":"c"}"#])
    }

    /// SPEC-018 v0.3.2 per-reply call set applies to DSML: a repeated call
    /// (same name, same canonical arguments) is dropped and at most 128 unique
    /// calls are kept, in generated order.
    func testDSMLCallsAreDeduplicatedAndCappedPerReply() {
        func block(_ body: String) -> String { "<｜DSML｜tool_calls>\n\(body)\n</｜DSML｜tool_calls>" }
        let repeated = parse(block([
            invoke("read_file", parameter("path", "a")),
            invoke("search", parameter("query", "a")),
            invoke("read_file", parameter("path", "a")),
        ].joined(separator: "\n")) + "\n" + block(invoke("read_file", parameter("path", "a"))))
        XCTAssertEqual(repeated.map(\.functionName), ["read_file", "search"])
        let many = parse(block((0..<130).map { invoke("read_file", parameter("path", "/tmp/\($0)")) }.joined(separator: "\n")))
        XCTAssertEqual(many.count, ToolSelectionPolicy.maxCalls)
        XCTAssertEqual(many.first?.arguments, #"{"path":"/tmp/0"}"#)
        XCTAssertEqual(many.last?.arguments, #"{"path":"/tmp/127"}"#)
    }

    /// The stream emitter suppresses content once the call block opens, holds
    /// a partial opening marker, and completes the serial-turn stop only on a
    /// closed, valid block.
    func testStreamEmitterSuppressesAndCompletesOnTheDSMLBlock() {
        var emitter = NativeToolCallStreamEmitter(
            modelID: Self.model, grammar: .dsml, allowedFunctionNames: ["read_file"], schemas: nil
        )
        XCTAssertTrue(NativeToolCallStreamEmitter.supports(grammar: .dsml))
        XCTAssertEqual(emitter.visibleContentPrefix(of: "Let me check.\n\n<｜DSML｜tool"), "Let me check.\n\n")
        let open = "Let me check.\n\n<｜DSML｜tool_calls>\n" + invoke("read_file", parameter("path", "a"))
        XCTAssertTrue(emitter.observe(open).isEmpty)
        XCTAssertTrue(emitter.suppressesAssistantContent)
        XCTAssertFalse(emitter.hasCompletedValidToolCall)
        _ = emitter.observe(open + "\n</｜DSML｜tool_calls>")
        XCTAssertTrue(emitter.hasCompletedValidToolCall)
    }

    func testGrammarIsSelectedForTheFamily() {
        XCTAssertEqual(ToolCallGrammar.family(modelID: "deepseek/deepseek-v4-flash"), .dsml)
        XCTAssertEqual(ToolCallGrammar.family(modelID: "TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX"), .dsml)
        XCTAssertEqual(ToolCallParser.callStartMarkers(.dsml), ["<｜DSML｜tool_calls>"])
    }

    /// The tokenizer wrapper applies to a template-less `deepseek_v4`
    /// artifact only.
    func testTokenizerAppliesToTemplateLessDeepseekV4Artifacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        try Data(#"{"model_type": "deepseek_v4"}"#.utf8).write(to: config)
        XCTAssertTrue(DeepseekV4ChatTokenizer.applies(to: directory))
        try Data(#"{"model_type": "deepseek_v3"}"#.utf8).write(to: config)
        XCTAssertFalse(DeepseekV4ChatTokenizer.applies(to: directory))
        try Data(#"{"model_type": "deepseek_v4"}"#.utf8).write(to: config)
        try Data("{{ messages }}".utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        XCTAssertFalse(DeepseekV4ChatTokenizer.applies(to: directory))
    }

    /// A tiny BPE vocabulary keeps the literal-newline regression running in
    /// CI even when the full artifact is unavailable. Other families retain
    /// exactly the stock tokenizer behavior for the same configuration.
    func testLiteralNewlineRegexIsRewrittenOnlyForDeepseekV4() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data: [String: Any] = [
            "model": ["type": "BPE", "vocab": [".": 16, "Ċ": 201, "ĊĊ": 271, ".Ċ": 603, ".ĊĊ": 339],
                      "merges": ["Ċ Ċ", ". Ċ", ". ĊĊ"]],
            "added_tokens": [],
            "pre_tokenizer": ["type": "Sequence", "pretokenizers": [
                ["type": "Split", "pattern": ["Regex": "[.]+[\r\n]*|\\s*[\r\n]+"],
                 "behavior": "Isolated", "invert": false],
                ["type": "ByteLevel", "add_prefix_space": false, "use_regex": false],
            ]],
        ]
        let tokenizerData = try JSONSerialization.data(withJSONObject: data)
        try tokenizerData.write(to: directory.appendingPathComponent("tokenizer.json"))
        try Data(#"{"tokenizer_class":"PreTrainedTokenizerFast","clean_up_tokenization_spaces":false}"#.utf8)
            .write(to: directory.appendingPathComponent("tokenizer_config.json"))
        for family in ["deepseek_v4", "deepseek_v41", "deepseek_v3", "qwen2", "llama", "glm5_next"] {
            try JSONSerialization.data(withJSONObject: ["model_type": family])
                .write(to: directory.appendingPathComponent("config.json"))
            let tokenizer = try await ChatTemplateCompatTokenizerLoader().load(from: directory)
            if DeepseekV4ChatTokenizer.modelTypes.contains(family) {
                XCTAssertTrue(tokenizer is DeepseekV4ChatTokenizer)
                for (text, expected) in [(".\n", [603]), (".\n\n", [339]), ("\n\n", [271])] {
                    XCTAssertEqual(tokenizer.encode(text: text, addSpecialTokens: false), expected, family)
                }
            } else {
                XCTAssertFalse(tokenizer is DeepseekV4ChatTokenizer)
                let stock = try await AutoTokenizer.from(modelFolder: directory)
                for text in [".\n", ".\n\n", "\n\n"] {
                    XCTAssertEqual(tokenizer.encode(text: text, addSpecialTokens: false),
                                   stock.encode(text: text, addSpecialTokens: false), family)
                }
            }
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("tokenizer.json")), tokenizerData)
        }
    }

    /// Exact Rust-tokenizers IDs from the pinned artifact, including the
    /// punctuation/newline merges that a text round-trip cannot detect.
    func testRealTokenizerMatchesAllReferenceTokenIDs() async throws {
        guard let path = ProcessInfo.processInfo.environment["DSV4_TOKENIZER_DIR"] else {
            throw XCTSkip("DSV4_TOKENIZER_DIR not set")
        }
        let tokenizer = try await ChatTemplateCompatTokenizerLoader().load(from: URL(fileURLWithPath: path))
        XCTAssertTrue(tokenizer is DeepseekV4ChatTokenizer)
        for (marker, id) in [("<｜begin▁of▁sentence｜>", 0), ("<｜User｜>", 128803), ("<｜Assistant｜>", 128804),
                             ("<think>", 128821), ("</think>", 128822), ("｜DSML｜", 128825)] {
            XCTAssertEqual(tokenizer.encode(text: marker, addSpecialTokens: false), [id], marker)
        }
        let idsURL = Self.fixture.deletingLastPathComponent().appendingPathComponent("token-ids.json")
        let ids = try JSONDecoder().decode(TokenIDs.self, from: Data(contentsOf: idsURL))
        let fixtures = try cases()
        let goldens = try XCTUnwrap(fixtures["reference"]?.array)
        let requests = try XCTUnwrap(fixtures["requests"]?.array)
        XCTAssertEqual(goldens.count, 4)
        XCTAssertEqual(requests.count, 14)
        XCTAssertEqual(ids.reference.count, goldens.count)
        XCTAssertEqual(ids.requests.count, requests.count)
        for (items, expectedIDs) in [(goldens, ids.reference), (requests, ids.requests)] {
            for item in items {
                let name = try XCTUnwrap(item["name"]?.string)
                let prompt = try XCTUnwrap(item["prompt"]?.string)
                let expected = try XCTUnwrap(expectedIDs[name])
                XCTAssertEqual(tokenizer.encode(text: prompt, addSpecialTokens: false), expected, name)
                XCTAssertEqual(tokenizer.encode(text: prompt, addSpecialTokens: true), expected, name)
                XCTAssertEqual(tokenizer.decode(tokenIds: expected, skipSpecialTokens: false), prompt, name)
                if let body = item["request"] {
                    let request = try ChatCompletionRequest.parse(data: Data(Encoding.toJSON(body).utf8))
                    let input = try ModelRuntime.userInput(for: request)
                    XCTAssertEqual(try tokenizer.applyChatTemplate(
                        messages: DefaultMessageGenerator().generate(from: input),
                        tools: input.tools, additionalContext: input.additionalContext
                    ), expected, name)
                }
            }
        }
    }

    private struct TokenIDs: Decodable {
        let reference: [String: [Int]]
        let requests: [String: [Int]]
    }
}
