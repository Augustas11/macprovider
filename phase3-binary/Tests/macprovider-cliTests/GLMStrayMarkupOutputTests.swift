import Foundation
import MacProviderCore
@testable import macprovider_cli
import XCTest

/// #2189: the abliterated GLM-5.3-Flash build sometimes writes a `<tool_call>`
/// that opens no call, prose, a second `</think>`, and only then its real
/// calls. The fixtures are the model output of two captured agent turns
/// (reasoning, then the text after the first `</think>`). Before the fix the
/// whole text reached `content` with no `tool_calls`.
final class GLMStrayMarkupOutputTests: XCTestCase {
    private static let model = "grant-ai/GLM-5.3-Flash-Abliterated-MLX-4bit"

    private struct Fixture {
        let reasoning: String
        let answer: String
        let leadingProse: String
        let offset: Int
    }

    private static let fixtures = [
        Fixture(
            reasoning: "I need to continue reading. ModelRuntime.swift has 16399 more lines (total ~17100), ContinuousBatchScheduler.swift has 6505 more. That's a lot of chunks — 700-line chunks: ~17200/700 = 25 chunks, 7205/700 = ~11 chunks. The user explicitly asked to read all chunks. Proceed.",
            answer: "Continuing with the next chunks of both files.<tool_call>Let me continue reading both files. ModelRuntime.swift has ~17100 lines and ContinuousBatchScheduler.swift has ~7205 lines. This will take many chunks. Let me proceed through them systematically.</think><tool_call>I've read lines 701–2100 of both files. Now let me continue with the next chunks.</think><tool_call>Continuing with chunks covering lines 2101–3500 of both files.<tool_call>read<arg_key>limit</arg_key><arg_value>700</arg_value><arg_key>offset</arg_key><arg_value>2101</arg_value><arg_key>path</arg_key><arg_value>phase3-binary/Sources/macprovider-cli/ModelRuntime.swift</arg_value></tool_call><tool_call>read<arg_key>limit</arg_key><arg_value>700</arg_value><arg_key>offset</arg_key><arg_value>2101</arg_value><arg_key>path</arg_key><arg_value>phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift</arg_value></tool_call>",
            leadingProse: "Continuing with the next chunks of both files.",
            offset: 2101
        ),
        Fixture(
            reasoning: "Continue with offset 701 for both files.",
            answer: "Continuing with the next chunks.<tool_call>Patient: Continuing with the next chunks.</think><tool_call>read<arg_key>limit</arg_key><arg_value>700</arg_value><arg_key>offset</arg_key><arg_value>701</arg_value><arg_key>path</arg_key><arg_value>phase3-binary/Sources/macprovider-cli/ModelRuntime.swift</arg_value></tool_call><tool_call>read<arg_key>limit</arg_key><arg_value>700</arg_value><arg_key>offset</arg_key><arg_value>701</arg_value><arg_key>path</arg_key><arg_value>phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift</arg_value></tool_call>",
            leadingProse: "Continuing with the next chunks.",
            offset: 701
        ),
    ]

    private static func expectedArguments(_ offset: Int) -> [String] {
        ["ModelRuntime.swift", "ContinuousBatchScheduler.swift"].map {
            #"{"limit":700,"offset":\#(offset),"path":"phase3-binary/Sources/macprovider-cli/\#($0)"}"#
        }
    }

    /// The agent's `read` tool: path string, offset and limit numbers.
    private func readRequest(model: String = model, reasoningOpen: Bool = true, tools: Bool = true) throws -> ChatCompletionRequest {
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "read both files"]]]
        if tools {
            body["tools"] = [["type": "function", "function": [
                "name": "read",
                "parameters": ["type": "object", "properties": [
                    "path": ["type": "string"], "offset": ["type": "number"], "limit": ["type": "number"],
                ], "required": ["path"]],
            ]]]
        }
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
        var reasoning = ""
        var content = ""
        var midStreamToolDeltas = 0
        var calls: [macprovider_cli.ToolCall] = []
    }

    /// Feeds the output as growing prefixes cut at `ends`, then finishes.
    private func stream(_ output: String, ends: [Int], _ request: ChatCompletionRequest) throws -> Streamed {
        var emitter = SerialStreamingTextEmitter(request: request)
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        var result = Streamed()
        for end in ends {
            _ = emitter.step(
                candidate: (String(output.prefix(end)), false), structuredAccumulator: accumulator, idleState: idle,
                onChunk: { chunk in
                    switch chunk {
                    case .reasoning(let text): result.reasoning += text
                    case .content(let text): result.content += text
                    case .toolCallDelta: result.midStreamToolDeltas += 1
                    case .progress: break
                    }
                }
            )
        }
        try emitter.finish(finalText: output, parsed: try parse(output, request), structuredAccumulator: accumulator, idleState: idle, onChunk: { chunk in
            if case .reasoning(let text) = chunk { result.reasoning += text }
            if case .content(let text) = chunk { result.content += text }
        })
        result.calls = emitter.reconciledToolCalls
        return result
    }

    /// Chunk ends: every character, a fixed odd stride, and cuts inside each
    /// tag (`<`, `</thi`, `<tool_ca`, `<arg_`), where a token boundary can fall.
    private func chunkings(_ output: String) -> [[Int]] {
        var tagCuts: [Int] = []
        for tag in ["</think>", "<tool_call>", "</tool_call>", "<arg_key>", "</arg_value>"] {
            var from = output.startIndex
            while let range = output.range(of: tag, range: from..<output.endIndex) {
                let at = output.distance(from: output.startIndex, to: range.lowerBound)
                tagCuts += [at + 1, at + tag.count / 2, at + tag.count - 1]
                from = range.upperBound
            }
        }
        let cuts = Set(tagCuts.filter { $0 > 0 && $0 < output.count })
        return [
            Array(1...output.count),
            Array(stride(from: 7, to: output.count, by: 7)) + [output.count],
            cuts.sorted() + [output.count],
        ]
    }

    // MARK: - Captured fixtures

    func testCapturedOutputParsesNonStreaming() throws {
        for fixture in Self.fixtures {
            let parsed = try parse(fixture.reasoning + "</think>" + fixture.answer, try readRequest())
            XCTAssertEqual(parsed.toolCalls.map(\.functionName), ["read", "read"])
            XCTAssertEqual(parsed.toolCalls.map(\.arguments), Self.expectedArguments(fixture.offset))
            XCTAssertEqual(parsed.content, fixture.leadingProse)
            XCTAssertEqual(parsed.reasoningContent, fixture.reasoning)
        }
    }

    func testCapturedOutputParsesWhenStreamedInAwkwardChunks() throws {
        for fixture in Self.fixtures {
            let output = fixture.reasoning + "</think>" + fixture.answer
            for ends in chunkings(output) {
                let streamed = try stream(output, ends: ends, try readRequest())
                XCTAssertEqual(streamed.reasoning, fixture.reasoning)
                XCTAssertEqual(streamed.content, fixture.leadingProse)
                XCTAssertEqual(streamed.midStreamToolDeltas, 0, "GLM calls are emitted whole by the final parser")
                XCTAssertEqual(streamed.calls.map(\.arguments), Self.expectedArguments(fixture.offset))
                let deltas = try StreamedToolCallArgs().finalDeltas(for: streamed.calls)
                XCTAssertEqual(Set(deltas.flatMap { $0 }.compactMap { $0["index"] as? Int }), [0, 1])
            }
        }
    }

    func testStrayOpenerBeforeTheOnlyCallIsProse() {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: "Reading.<tool_call>thinking aloud</think><tool_call>read<arg_key>path</arg_key><arg_value>a.txt</arg_value>",
            grammar: .glm, modelID: Self.model, allowedFunctionNames: ["read"], schemas: nil
        )
        // The final envelope may end at the end of output; the stray opener does not void it.
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"path":"a.txt"}"#])
        XCTAssertEqual(parsed.leadingContent, "Reading.")
    }

    // MARK: - Reasoning markup

    /// The template opens `<think>` in the prompt: reasoning starts at the
    /// first generated token and the first `</think>` closes it, with no
    /// `<think>` in the output.
    func testUnopenedCloseEndsImplicitReasoning() throws {
        let parsed = try parse("Plan the answer.</think>The answer.", try readRequest(tools: false))
        XCTAssertEqual(parsed.reasoningContent, "Plan the answer.")
        XCTAssertEqual(parsed.content, "The answer.")
    }

    func testStrayThinkTagsNeverReachContent() throws {
        let output = "Plan.</think>First part.</think> Second<think> part."
        let request = try readRequest(tools: false)
        XCTAssertEqual(try parse(output, request).content, "First part. Second part.")
        for ends in chunkings(output) {
            let streamed = try stream(output, ends: ends, request)
            XCTAssertEqual(streamed.reasoning, "Plan.")
            XCTAssertEqual(streamed.content, "First part. Second part.")
        }
        XCTAssertEqual(ReasoningOutput.removingStrayTags("a</thi", streaming: true), "a")
        XCTAssertEqual(ReasoningOutput.removingStrayTags("a</thi", streaming: false), "a</thi")
        XCTAssertEqual(ReasoningOutput.removingStrayTags("a</thi</think>nk>b", streaming: false), "ab")
    }

    /// A prompt that leaves no `<think>` open (the model writes the pair
    /// itself): nothing was split off as reasoning, so the tags are not
    /// stray and the output reaches `content` byte-for-byte, as before #2189.
    func testThinkTagsAreKeptWhenThePromptLeftNoThinkOpen() throws {
        let output = "<think>plan</think>Do the task."
        let request = try readRequest(reasoningOpen: false, tools: false)
        let parsed = try parse(output, request)
        XCTAssertNil(parsed.reasoningContent)
        XCTAssertEqual(parsed.content, output)
        for ends in chunkings(output) {
            let streamed = try stream(output, ends: ends, request)
            XCTAssertEqual(streamed.reasoning, "")
            XCTAssertEqual(streamed.content, output)
        }
    }

    /// Text after the first `<tool_call>` is left to the tool parser, so a
    /// call argument that contains a think tag stays byte-exact.
    func testThinkTagInsideCallArgumentIsKept() throws {
        let parsed = try parse(
            "Plan.</think><tool_call>read<arg_key>path</arg_key><arg_value>notes/</think>.md</arg_value></tool_call>",
            try readRequest()
        )
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"path":"notes/</think>.md"}"#])
        XCTAssertEqual(parsed.content, "")
    }

    // MARK: - Unchanged paths

    func testBaseBuildOutputIsUnchanged() throws {
        let output = "Two reads.</think>Reading both.<tool_call>read<arg_key>path</arg_key><arg_value>a</arg_value></tool_call><tool_call>read<arg_key>path</arg_key><arg_value>b</arg_value></tool_call>"
        let request = try readRequest(model: "zai-org/GLM-5.3-Flash")
        let parsed = try parse(output, request)
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"path":"a"}"#, #"{"path":"b"}"#])
        XCTAssertEqual(parsed.content, "Reading both.")
        XCTAssertEqual(parsed.reasoningContent, "Two reads.")
        for ends in chunkings(output) {
            let streamed = try stream(output, ends: ends, request)
            XCTAssertEqual(streamed.content, "Reading both.")
            XCTAssertEqual(streamed.calls.map(\.arguments), [#"{"path":"a"}"#, #"{"path":"b"}"#])
        }
    }

    func testMalformedGLMEnvelopesStillFailClosed() {
        for raw in [
            "<tool_call>Done.</tool_call>",
            "<tool_call>read<arg_key>path</arg_key><arg_value>a</arg_value></tool_call><tool_call>more prose",
            "<tool_call>read<arg_key>path</arg_key><arg_value>a<tool_call>b</arg_value></tool_call>",
        ] {
            let parsed = ToolCallParser.parseToolCalls(
                rawOutput: raw, grammar: .glm, modelID: Self.model, allowedFunctionNames: ["read"], schemas: nil
            )
            XCTAssertTrue(parsed.toolCalls.isEmpty, raw)
            XCTAssertEqual(parsed.cleanedContent, raw)
        }
    }

    func testOtherFamiliesAreUnchanged() throws {
        // Gemma keeps whole-envelope parsing: a repeated opener still fails.
        let gemma = ToolCallParser.parseToolCalls(
            rawOutput: #"<|tool_call>prose<|tool_call>call:read{path:<|"|>a<|"|>}<tool_call|>"#,
            grammar: .gemma4, modelID: "gemma", allowedFunctionNames: ["read"], schemas: nil
        )
        XCTAssertTrue(gemma.toolCalls.isEmpty)
        // Think tags in another family's content are left alone.
        let qwen = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "mlx-community/Qwen3-8B-4bit", "messages": [["role": "user", "content": "x"]],
        ]))
        XCTAssertEqual(try parse("a</think>b<think>c", qwen).content, "a</think>b<think>c")
    }
}
