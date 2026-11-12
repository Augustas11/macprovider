import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// #2317: `SerialStreamingTextEmitter` on its incremental text steps (the
/// reasoning split, stray-tag removal and tool-streamer input reduction)
/// against the same emitter on the whole-text functions, end to end: every
/// chunk, every step result, then `finish`. Seeded random streams.
final class IncrementalOutputFilterEmitterTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A chunk with the random tool-call id reduced to its presence.
    private enum Event: Equatable {
        case content(String)
        case reasoning(String)
        case toolCall(index: Int, hasID: Bool, type: String?, name: String?, arguments: String?)
        case progress
    }

    private static func event(_ chunk: StreamChunk) -> Event {
        switch chunk {
        case .content(let text): return .content(text)
        case .reasoning(let text): return .reasoning(text)
        case .progress: return .progress
        case .toolCallDelta(let delta):
            return .toolCall(index: delta.index, hasID: delta.id != nil, type: delta.type, name: delta.functionName, arguments: delta.arguments)
        }
    }

    /// A clock that advances one second per reading, so both emitters see
    /// the same held-progress decisions.
    private final class StepClock: @unchecked Sendable {
        private var seconds = 0.0
        func now() -> Date {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
    }

    private func request(
        model: String, grammar: ToolCallGrammar, reasoningOpen: Bool, tool: String?, parallelToolCalls: Bool = true
    ) throws -> ChatCompletionRequest {
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "go"]]]
        if let tool {
            body["tools"] = [["type": "function", "function": [
                "name": tool,
                "parameters": ["type": "object", "properties": ["q": ["type": "string"], "path": ["type": "string"]]],
            ]]]
            if !parallelToolCalls { body["parallel_tool_calls"] = false }
        }
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
        request.outputState.resolve(RequestOutputTraits(toolGrammar: grammar, reasoningOpen: reasoningOpen))
        return request
    }

    private let prose = ["the", " cat", " sat", " on", " a", " mat", ",", ".", "\n", " 42", " und", " 中文", " ok", " 안녕하세요", " 반갑습니다."]

    private func randomStream(_ rng: inout SeededGenerator, count: Int, markup: [String], insert: [[String]]) -> [String] {
        var stream = (0..<count).map { _ -> String in
            if Int.random(in: 0..<4, using: &rng) == 0 { return markup.randomElement(using: &rng)! }
            return prose.randomElement(using: &rng)!
        }
        for pieces in insert {
            stream.insert(contentsOf: pieces, at: Int.random(in: 0...stream.count, using: &rng))
        }
        return stream
    }

    /// Candidates as the stream filter hands them on: the joined pieces,
    /// sometimes with a few Characters still held back, now and then with
    /// over 64 bytes taken back (a rewrite that restarts the steps), and on
    /// some streams a request stop on the last one.
    private func candidates(of stream: [String], stopsAtEnd: Bool, _ rng: inout SeededGenerator) -> [(String, Bool)] {
        var joined = ""
        var result: [(String, Bool)] = []
        for piece in stream {
            joined += piece
            switch Int.random(in: 0..<60, using: &rng) {
            case 0..<6 where joined.count > 3:
                result.append((String(joined.dropLast(Int.random(in: 1...3, using: &rng))), false))
            case 6 where joined.utf8.count > 200:
                result.append((String(joined.dropLast(80)), false))
            default:
                break
            }
            result.append((joined, false))
        }
        if stopsAtEnd, let last = result.popLast() { result.append((last.0, true)) }
        return result
    }

    private struct Run {
        var steps = 0
        var restarts = 0
        var toolScannedUTF8 = 0
    }

    /// Both emitters over `candidates`, then `finish` on the last text.
    @discardableResult
    private func assertSameEmission(
        _ request: ChatCompletionRequest,
        _ candidates: [(String, Bool)],
        holdsCleanupPatternPrefixes: Bool = true,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Run {
        var run = Run()
        let incrementalClock = StepClock()
        let referenceClock = StepClock()
        var incremental = SerialStreamingTextEmitter(
            request: request, holdsCleanupPatternPrefixes: holdsCleanupPatternPrefixes,
            heldProgress: HeldOutputProgress(clock: { incrementalClock.now() }))
        var reference = SerialStreamingTextEmitter(
            request: request, holdsCleanupPatternPrefixes: holdsCleanupPatternPrefixes,
            heldProgress: HeldOutputProgress(clock: { referenceClock.now() }))
            .usingReferenceText()
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        var finalText = ""
        for (step, candidate) in candidates.enumerated() {
            finalText = candidate.0
            var expected: [Event] = []
            var actual: [Event] = []
            let expectedStep = reference.step(
                candidate: candidate, structuredAccumulator: accumulator, idleState: idle,
                onChunk: { expected.append(Self.event($0)) })
            let actualStep = incremental.step(
                candidate: candidate, structuredAccumulator: accumulator, idleState: idle,
                onChunk: { actual.append(Self.event($0)) })
            run.steps += 1
            guard actual == expected, actualStep == expectedStep else {
                XCTFail(
                    "\(label) step \(step): \(actual) / \(actualStep) != \(expected) / \(expectedStep) "
                        + "for \(candidate.0.suffix(160).debugDescription)",
                    file: file, line: line)
                return run
            }
            if expectedStep != .more { break }
        }
        run.restarts = incremental.incrementalRestartCount
        run.toolScannedUTF8 = incremental.incrementalToolScannedUTF8
        let parsed = try? ModelRuntime.parseGeneratedOutput(
            filteredText: finalText, generatedTokenIDs: [], decode: { _ in "" }, request: request, mode: .complete(),
            defaultCompletionTokens: 64, toolCallPrefill: nil)
        guard let parsed else { return run }
        var expected: [Event] = []
        var actual: [Event] = []
        let expectedError = Result { try reference.finish(
            finalText: finalText, parsed: parsed, structuredAccumulator: accumulator, idleState: idle,
            onChunk: { expected.append(Self.event($0)) }) }
        let actualError = Result { try incremental.finish(
            finalText: finalText, parsed: parsed, structuredAccumulator: accumulator, idleState: idle,
            onChunk: { actual.append(Self.event($0)) }) }
        XCTAssertEqual(actual, expected, "\(label): finish", file: file, line: line)
        XCTAssertEqual((try? actualError.get()) == nil, (try? expectedError.get()) == nil, label, file: file, line: line)
        XCTAssertEqual(incremental.emittedContent, reference.emittedContent, label, file: file, line: line)
        XCTAssertEqual(incremental.emittedReasoning, reference.emittedReasoning, label, file: file, line: line)
        XCTAssertEqual(
            incremental.reconciledToolCalls.map { [$0.functionName, $0.arguments] },
            reference.reconciledToolCalls.map { [$0.functionName, $0.arguments] }, label, file: file, line: line)
        return run
    }

    private func assertEmitterDifferential(
        _ request: ChatCompletionRequest,
        seed: UInt64,
        streams: Int,
        length: Int,
        markup: [String],
        insert: [[String]] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var rng = SeededGenerator(state: seed)
        var steps = 0
        var restarts = 0
        for streamIndex in 0..<streams {
            let stream = randomStream(&rng, count: length, markup: markup, insert: streamIndex % 2 == 0 ? insert : [])
            let run = try assertSameEmission(
                request, candidates(of: stream, stopsAtEnd: streamIndex % 3 == 1, &rng),
                holdsCleanupPatternPrefixes: streamIndex % 4 != 3,
                label: "seed \(seed) stream \(streamIndex)", file: file, line: line)
            steps += run.steps
            restarts += run.restarts
        }
        // Restarts follow the held-back candidates, not every step.
        XCTAssertLessThan(restarts, steps / 4, file: file, line: line)
    }

    private let qwenCall = ["<tool", "_call>", "\n{\"name\": \"lookup\", ", "\"arguments\": {\"q\": \"x\"}}", "\n</tool_call>"]
    private let glmCall = ["<tool_call>", "read", "<arg_key>", "path", "</arg_key>", "<arg_value>", "a.txt", "</arg_value>", "</tool_call>"]

    func testReasoningRowsMatchReference() throws {
        try assertEmitterDifferential(
            request(model: "mlx-community/Qwen3-8B-4bit", grammar: .qwen, reasoningOpen: true, tool: nil),
            seed: 4_2317, streams: 16, length: 500,
            markup: ["<", "</", "</th", "ink>", "</think>", "<think>", "\u{301}", "é", "\u{1100}", "\u{1161}", " ", "\u{113D1}"],
            insert: [["</th", "ink>"]])
    }

    func testGLMStrayTagRowsMatchReference() throws {
        for parallelToolCalls in [true, false] {
            try assertEmitterDifferential(
                request(model: "grant-ai/GLM-5.3-Flash-Abliterated-MLX-4bit", grammar: .glm, reasoningOpen: true, tool: "read",
                        parallelToolCalls: parallelToolCalls),
                seed: parallelToolCalls ? 4_2318 : 4_2328, streams: 16, length: 500,
                markup: ["<think>", "</think>", "</th", "ink>", "<thi", "nk>", "<", "<tool_ca", "\u{301}", "Patient: ", " ", "\u{113D1}"],
                insert: [["</think>"], glmCall, glmCall])
        }
    }

    func testQwenToolRowsWithStreamedCallsMatchReference() throws {
        for reasoningOpen in [false, true] {
            try assertEmitterDifferential(
                request(model: "mlx-community/Qwen3-8B-4bit", grammar: .qwen, reasoningOpen: reasoningOpen, tool: "lookup",
                        parallelToolCalls: reasoningOpen),
                seed: reasoningOpen ? 4_2320 : 4_2319, streams: 16, length: 500,
                markup: ["<", "<tool", "{", "}", "\u{301}", "<tools>", " "],
                insert: reasoningOpen ? [["</think>"], qwenCall] : [qwenCall])
        }
    }

    /// Function-XML calls, inside `<tool_call>` and bare.
    func testQwenFunctionXMLRowsMatchReference() throws {
        let xml = ["<function=lookup>", "\n<parameter=q>", "\nx\n", "</parameter>", "\n</function>"]
        try assertEmitterDifferential(
            request(model: "mlx-community/Qwen3-Coder-30B-A3B-4bit", grammar: .qwen, reasoningOpen: false, tool: "lookup",
                    parallelToolCalls: false),
            seed: 4_2322, streams: 16, length: 400,
            markup: ["<", "<func", "tion=", "</function>", " "],
            insert: [xml])
        try assertEmitterDifferential(
            request(model: "mlx-community/Qwen3-Coder-30B-A3B-4bit", grammar: .qwen, reasoningOpen: false, tool: "lookup"),
            seed: 4_2323, streams: 16, length: 400,
            markup: ["<", " "],
            insert: [["<tool_call>\n"] + xml + ["\n</tool_call>"]])
    }

    func testLlama3ToolRowsMatchReference() throws {
        try assertEmitterDifferential(
            request(model: "mlx-community/Llama-3.3-70B-Instruct-4bit", grammar: .llama3, reasoningOpen: false, tool: "lookup",
                    parallelToolCalls: false),
            seed: 4_2321, streams: 16, length: 500,
            markup: ["<", "{", "}", "<|python_tag|>", " "],
            insert: [["{\"name\": \"lookup\", ", "\"parameters\": {\"q\": \"x\"}}"]])
    }

    func testGemma4LFM2AndDSMLRowsMatchReference() throws {
        let dsml = DeepseekV4Encoding.dsmlToken
        let cases: [(String, ToolCallGrammar, [String], UInt64)] = [
            ("mlx-community/gemma-4-12b-it-4bit", .gemma4,
             ["<|tool_call>", "call:lookup", "{q:<|\"|>x<|\"|>}", "<tool_call|>"], 4_2324),
            ("LiquidAI/LFM2-8B-A1B-MLX-4bit", .lfm2,
             ["<|tool_call_start|>", "[lookup(q=\"x\")]", "<|tool_call_end|>"], 4_2325),
            ("mlx-community/DeepSeek-V4-Flash-4bit", .dsml,
             ["<\(dsml)tool_calls>", "\n<\(dsml)invoke name=\"lookup\">", "\n<\(dsml)parameter name=\"q\" string=\"true\">x</\(dsml)parameter>",
              "\n</\(dsml)invoke>", "\n</\(dsml)tool_calls>"], 4_2326),
        ]
        for (model, grammar, call, seed) in cases {
            for parallelToolCalls in [true, false] {
                try assertEmitterDifferential(
                    request(model: model, grammar: grammar, reasoningOpen: false, tool: "lookup", parallelToolCalls: parallelToolCalls),
                    seed: seed + (parallelToolCalls ? 0 : 100), streams: 8, length: 400,
                    markup: ["<", "<|", "|>", "{", "}", " ", call[0]],
                    insert: [call])
            }
        }
    }

    /// Above the response byte cap the tool text is not reduced.
    func testOverTheResponseByteCapMatchesReference() throws {
        let cap = ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP
        let line = "the cat sat on a mat, 42 und ok.\n"
        let base = String(repeating: line, count: (cap - 4_096) / line.utf8.count)
        var candidates: [(String, Bool)] = [("the cat", false), (base, false)]
        var text = base
        for _ in 0..<6 {
            text += String(repeating: line, count: 40)
            candidates.append((text, false))
        }
        XCTAssertGreaterThan(text.utf8.count, cap)
        candidates.append((text + "<tool_call>\n{\"name\": \"lookup\", \"arguments\": {\"q\": \"x\"}}\n</tool_call>", false))
        try assertSameEmission(
            request(model: "mlx-community/Qwen3-8B-4bit", grammar: .qwen, reasoningOpen: false, tool: "lookup"),
            candidates, label: "over cap")
    }

    // MARK: - Long GLM tool call

    /// A GLM call whose argument value is `bodyBytes` long, written 64 bytes
    /// per step after prose and reasoning, then closed.
    private func longGLMCallCandidates(bodyBytes: Int) -> [(String, Bool)] {
        let unit = "if a < b { x = \"</s\" + y } // tool <call>\n"
        var text = String(repeating: "thinking about the files. ", count: 40) + "</think>"
            + String(repeating: "Reading the file now. ", count: 30) + "<tool_call>read<arg_key>path</arg_key><arg_value>"
        var candidates: [(String, Bool)] = [(text, false)]
        let body = String(repeating: unit, count: bodyBytes / unit.utf8.count + 1)
        var index = body.startIndex
        while index < body.endIndex {
            let next = body.index(index, offsetBy: 64, limitedBy: body.endIndex) ?? body.endIndex
            text += body[index..<next]
            candidates.append((text, false))
            index = next
        }
        for piece in ["</arg_value>", "</tool_call>", " trailing prose"] {
            text += piece
            candidates.append((text, false))
        }
        return candidates
    }

    func testLongGLMToolCallMatchesReference() throws {
        for parallelToolCalls in [true, false] {
            let request = try request(
                model: "grant-ai/GLM-5.3-Flash-Abliterated-MLX-4bit", grammar: .glm, reasoningOpen: true, tool: "read",
                parallelToolCalls: parallelToolCalls)
            try assertSameEmission(request, longGLMCallCandidates(bodyBytes: 120_000), label: "parallel \(parallelToolCalls)")
        }
    }

    /// The cut search and the end-delimiter search read a bounded amount per
    /// step however long the call body grows (the whole-text steps read the
    /// whole body every step).
    func testLongGLMToolCallWorkPerStepIsBounded() throws {
        let request = try request(
            model: "grant-ai/GLM-5.3-Flash-Abliterated-MLX-4bit", grammar: .glm, reasoningOpen: true, tool: "read",
            parallelToolCalls: false)
        func perStep(bodyBytes: Int) -> Double {
            var emitter = SerialStreamingTextEmitter(request: request)
            let accumulator = StructuredStreamingContentAccumulator(enabled: false)
            let idle = StructuredStreamingIdleState(enabled: false)
            let candidates = longGLMCallCandidates(bodyBytes: bodyBytes)
            for candidate in candidates {
                _ = emitter.step(candidate: candidate, structuredAccumulator: accumulator, idleState: idle, onChunk: { _ in })
            }
            return Double(emitter.incrementalToolScannedUTF8) / Double(candidates.count)
        }
        let short = perStep(bodyBytes: 100_000)
        let long = perStep(bodyBytes: 400_000)
        XCTAssertLessThan(long, 512)
        XCTAssertLessThan(long, short * 1.25 + 16)
    }
}
