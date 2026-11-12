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

    private func request(model: String, grammar: ToolCallGrammar, reasoningOpen: Bool, tool: String?) throws -> ChatCompletionRequest {
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "go"]]]
        if let tool {
            body["tools"] = [["type": "function", "function": [
                "name": tool,
                "parameters": ["type": "object", "properties": ["q": ["type": "string"], "path": ["type": "string"]]],
            ]]]
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
    /// sometimes with a few Characters still held back.
    private func candidates(of stream: [String], _ rng: inout SeededGenerator) -> [String] {
        var joined = ""
        var result: [String] = []
        for piece in stream {
            joined += piece
            if Int.random(in: 0..<10, using: &rng) == 0, joined.count > 3 {
                result.append(String(joined.dropLast(Int.random(in: 1...3, using: &rng))))
            }
            result.append(joined)
        }
        return result
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
            let incrementalClock = StepClock()
            let referenceClock = StepClock()
            var incremental = SerialStreamingTextEmitter(request: request, heldProgress: HeldOutputProgress(clock: { incrementalClock.now() }))
            var reference = SerialStreamingTextEmitter(request: request, heldProgress: HeldOutputProgress(clock: { referenceClock.now() }))
                .usingReferenceText()
            let accumulator = StructuredStreamingContentAccumulator(enabled: false)
            let idle = StructuredStreamingIdleState(enabled: false)
            var finalText = ""
            for (step, text) in candidates(of: stream, &rng).enumerated() {
                finalText = text
                var expected: [Event] = []
                var actual: [Event] = []
                let expectedStep = reference.step(
                    candidate: (text, false), structuredAccumulator: accumulator, idleState: idle,
                    onChunk: { expected.append(Self.event($0)) })
                let actualStep = incremental.step(
                    candidate: (text, false), structuredAccumulator: accumulator, idleState: idle,
                    onChunk: { actual.append(Self.event($0)) })
                steps += 1
                guard actual == expected, actualStep == expectedStep else {
                    return XCTFail(
                        "seed \(seed) stream \(streamIndex) step \(step): \(actual) / \(actualStep) != \(expected) / \(expectedStep) "
                            + "for \(text.suffix(160).debugDescription)",
                        file: file, line: line)
                }
                if expectedStep != .more { break }
            }
            restarts += incremental.incrementalRestartCount
            let parsed = try? ModelRuntime.parseGeneratedOutput(
                filteredText: finalText, generatedTokenIDs: [], decode: { _ in "" }, request: request, mode: .complete(),
                defaultCompletionTokens: 64, toolCallPrefill: nil)
            guard let parsed else { continue }
            var expected: [Event] = []
            var actual: [Event] = []
            let expectedError = Result { try reference.finish(
                finalText: finalText, parsed: parsed, structuredAccumulator: accumulator, idleState: idle,
                onChunk: { expected.append(Self.event($0)) }) }
            let actualError = Result { try incremental.finish(
                finalText: finalText, parsed: parsed, structuredAccumulator: accumulator, idleState: idle,
                onChunk: { actual.append(Self.event($0)) }) }
            XCTAssertEqual(actual, expected, "seed \(seed) stream \(streamIndex): finish", file: file, line: line)
            XCTAssertEqual((try? actualError.get()) == nil, (try? expectedError.get()) == nil, "seed \(seed) stream \(streamIndex)", file: file, line: line)
            XCTAssertEqual(incremental.emittedContent, reference.emittedContent, file: file, line: line)
            XCTAssertEqual(incremental.emittedReasoning, reference.emittedReasoning, file: file, line: line)
            XCTAssertEqual(
                incremental.reconciledToolCalls.map { [$0.functionName, $0.arguments] },
                reference.reconciledToolCalls.map { [$0.functionName, $0.arguments] }, file: file, line: line)
        }
        // Restarts follow the held-back candidates, not every step.
        XCTAssertLessThan(restarts, steps / 4, file: file, line: line)
    }

    private let qwenCall = ["<tool", "_call>", "\n{\"name\": \"lookup\", ", "\"arguments\": {\"q\": \"x\"}}", "\n</tool_call>"]

    func testReasoningRowsMatchReference() throws {
        try assertEmitterDifferential(
            request(model: "mlx-community/Qwen3-8B-4bit", grammar: .qwen, reasoningOpen: true, tool: nil),
            seed: 4_2317, streams: 16, length: 500,
            markup: ["<", "</", "</th", "ink>", "</think>", "<think>", "\u{301}", "é", "\u{1100}", "\u{1161}", " "],
            insert: [["</th", "ink>"]])
    }

    func testGLMStrayTagRowsMatchReference() throws {
        let call = ["<tool_call>", "read", "<arg_key>", "path", "</arg_key>", "<arg_value>", "a.txt", "</arg_value>", "</tool_call>"]
        try assertEmitterDifferential(
            request(model: "grant-ai/GLM-5.3-Flash-Abliterated-MLX-4bit", grammar: .glm, reasoningOpen: true, tool: "read"),
            seed: 4_2318, streams: 16, length: 500,
            markup: ["<think>", "</think>", "</th", "ink>", "<thi", "nk>", "<", "<tool_ca", "\u{301}", "Patient: ", " "],
            insert: [["</think>"], call])
    }

    func testQwenToolRowsWithStreamedCallsMatchReference() throws {
        for reasoningOpen in [false, true] {
            try assertEmitterDifferential(
                request(model: "mlx-community/Qwen3-8B-4bit", grammar: .qwen, reasoningOpen: reasoningOpen, tool: "lookup"),
                seed: reasoningOpen ? 4_2320 : 4_2319, streams: 16, length: 500,
                markup: ["<", "<tool", "{", "}", "\u{301}", "<tools>", " "],
                insert: reasoningOpen ? [["</think>"], qwenCall] : [qwenCall])
        }
    }

    func testLlama3ToolRowsMatchReference() throws {
        try assertEmitterDifferential(
            request(model: "mlx-community/Llama-3.3-70B-Instruct-4bit", grammar: .llama3, reasoningOpen: false, tool: "lookup"),
            seed: 4_2321, streams: 16, length: 500,
            markup: ["<", "{", "}", "<|python_tag|>", " "],
            insert: [["{\"name\": \"lookup\", ", "\"parameters\": {\"q\": \"x\"}}"]])
    }
}
