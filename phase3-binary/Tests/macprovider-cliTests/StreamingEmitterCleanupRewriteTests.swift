import XCTest
import MacProviderCore
@testable import macprovider_cli

final class StreamingEmitterCleanupRewriteTests: XCTestCase {
    func testEveryCleanupRuleAndSplitMatchesWholeStringOracleWithoutContentLoss() throws {
        let patterns = [" .", " ?", " !", " ,", " ' ", " n't", " 'm", " 's", " 've", " 're"]
        let inputs = patterns.map { "A\($0)B" } + ["A 's .B", "A n't ?B"]

        for input in inputs {
            let expected = Self.cleanupReference(input)
            for pieces in Self.twoAndThreeWaySplits(input) {
                let detokenizer = ModelRuntime.StreamingDetokenizer(
                    decode: { ids in ids.map { pieces[$0] }.joined() },
                    tokenPiece: { pieces[$0] },
                    cleanUpTokenizationSpaces: true
                )
                let decoder = detokenizer.makeIncremental()
                let request = try makeRequest(stops: [])
                let accumulator = StructuredStreamingContentAccumulator(enabled: false)
                let idle = StructuredStreamingIdleState(enabled: false)
                var emitter = SerialStreamingTextEmitter(request: request)
                var chunks: [String] = []

                for token in pieces.indices {
                    let cumulative = decoder.append(token)
                    _ = emitter.step(
                        candidate: (text: cumulative, hitStop: false),
                        structuredAccumulator: accumulator,
                        idleState: idle,
                        onChunk: { if case .content(let text) = $0 { chunks.append(text) } }
                    )
                }

                XCTAssertEqual(decoder.appendedText, expected, "input=\(input) pieces=\(pieces)")
                let delivered = chunks.joined()
                XCTAssertTrue(
                    Self.differsOnlyByRetainingCleanupDeletedSpaces(
                        delivered,
                        original: input,
                        cleaned: expected
                    ),
                    "stream duplicated, reordered, or dropped non-cleanup content; input=\(input) pieces=\(pieces) delivered=\(delivered)"
                )
            }
        }
    }

    func testPrefixExtendingDecodesKeepExistingChunkBoundaries() throws {
        let chunks = try stream(decodes: ["a", "ab", "abc"])

        XCTAssertEqual(chunks, ["a", "b", "c"])
        XCTAssertEqual(chunks.joined(), "abc")
    }

    func testIndentationCleanupRewriteDoesNotStallLaterContent() throws {
        let chunks = try stream(decodes: ["    ", "   .", "   .later"])

        XCTAssertEqual(chunks, ["    ", ".", "later"])
        XCTAssertEqual(chunks.joined(), "    .later")
    }

    func testApostropheCleanupRewriteDoesNotStallLaterContent() throws {
        let chunks = try stream(decodes: ["it ", "it's", "it's fine"])

        XCTAssertEqual(chunks, ["it ", "'s", " fine"])
        XCTAssertEqual(chunks.joined(), "it 's fine")
    }

    func testCleanupRewriteWhileStopCandidateIsHeldBack() throws {
        let chunks = try stream(
            decodes: ["    <", "   .</", "   .later"],
            stops: ["</stop>"]
        )

        XCTAssertEqual(chunks, ["    ", ".", "later"])
        XCTAssertEqual(chunks.joined(), "    .later")
    }

    func testFinishFlushesTailAfterCleanupRewrite() throws {
        let chunks = try stream(decodes: ["    ", "   ."], final: "   .tail")

        XCTAssertEqual(chunks, ["    ", ".", "tail"])
        XCTAssertEqual(chunks.joined(), "    .tail")
    }

    func testCleanupRewriteCompletionContentIsExactDeliveredConcatenation() throws {
        let result = try streamResult(
            decodes: ["It ", "It 's", "It's fine"],
            final: "It's fine"
        )

        XCTAssertEqual(result.chunks, ["It ", "'s", " fine"])
        XCTAssertEqual(result.chunks.joined(), "It 's fine")
        XCTAssertEqual(result.emittedContent, result.chunks.joined())
        XCTAssertEqual(result.completion.content, result.chunks.joined())
        XCTAssertNotEqual(result.completion.content, "It's fine")
    }

    func testNoRewriteCompletionContentIsByteIdenticalToParsedContent() throws {
        let parsedContent = "café \u{1F642}"
        let result = try streamResult(
            decodes: ["caf", "café "],
            final: parsedContent
        )

        XCTAssertEqual(Data(result.emittedContent.utf8), Data(parsedContent.utf8))
        XCTAssertEqual(Data(result.completion.content.utf8), Data(parsedContent.utf8))
        XCTAssertEqual(result.emittedContent, result.chunks.joined())
        XCTAssertEqual(result.completion.content, parsedContent)
    }

    private func stream(
        decodes: [String],
        stops: [String] = [],
        final: String? = nil
    ) throws -> [String] {
        try streamResult(decodes: decodes, stops: stops, final: final).chunks
    }

    private func streamResult(
        decodes: [String],
        stops: [String] = [],
        final: String? = nil
    ) throws -> (chunks: [String], emittedContent: String, completion: CompletionResult) {
        let request = try makeRequest(stops: stops)
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idleState = StructuredStreamingIdleState(enabled: false)
        var emitter = SerialStreamingTextEmitter(request: request)
        var chunks: [String] = []

        for decoded in decodes {
            let candidate = ModelRuntime.streamingSafePrefix(
                decoded,
                stopTokenFilter: StopTokenFilter(tokens: []),
                requestStops: stops
            )
            XCTAssertEqual(emitter.step(
                candidate: candidate,
                structuredAccumulator: accumulator,
                idleState: idleState,
                onChunk: { chunk in
                    if case .content(let text) = chunk {
                        chunks.append(text)
                    }
                }
            ), .more)
        }

        if let final {
            try emitter.finish(
                finalText: final,
                parsed: ModelRuntime.ParsedGeneratedOutput(
                    content: final,
                    toolCalls: [],
                    completionTokens: 0,
                    generatedCompletionTokens: 0,
                    hitStop: false,
                    isTerminal: true
                ),
                structuredAccumulator: accumulator,
                idleState: idleState,
                onChunk: { chunk in
                    if case .content(let text) = chunk {
                        chunks.append(text)
                    }
                }
            )
        }
        let completion = CompletionResult(
            content: emitter.emittedContent,
            finishReason: "stop",
            promptTokens: 1,
            completionTokens: chunks.count,
            settlementDisposition: .eligibleOwner
        )
        return (chunks, emitter.emittedContent, completion)
    }

    private func makeRequest(stops: [String]) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": "mlx-community/test-model",
            "messages": [["role": "user", "content": "test"]],
        ]
        if !stops.isEmpty {
            body["stop"] = stops
        }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    private static func cleanupReference(_ input: String) -> String {
        input
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " ' ", with: "'")
            .replacingOccurrences(of: " n't", with: "n't")
            .replacingOccurrences(of: " 'm", with: "'m")
            .replacingOccurrences(of: " 's", with: "'s")
            .replacingOccurrences(of: " 've", with: "'ve")
            .replacingOccurrences(of: " 're", with: "'re")
    }

    private static func twoAndThreeWaySplits(_ input: String) -> [[String]] {
        let characters = Array(input)
        var result: [[String]] = []
        for first in 1..<characters.count {
            result.append([
                String(characters[..<first]),
                String(characters[first...]),
            ])
            for second in (first + 1)..<characters.count {
                result.append([
                    String(characters[..<first]),
                    String(characters[first..<second]),
                    String(characters[second...]),
                ])
            }
        }
        return result
    }

    private static func differsOnlyByRetainingCleanupDeletedSpaces(
        _ delivered: String,
        original: String,
        cleaned: String
    ) -> Bool {
        let originalCharacters = Array(original)
        let cleanedCharacters = Array(cleaned)
        let deliveredCharacters = Array(delivered)
        var cleanupDeletedIndices = Set<Int>()
        var cleanedIndex = 0

        for (originalIndex, character) in originalCharacters.enumerated() {
            if cleanedIndex < cleanedCharacters.count,
               character == cleanedCharacters[cleanedIndex] {
                cleanedIndex += 1
            } else if character == " " {
                cleanupDeletedIndices.insert(originalIndex)
            } else {
                return false
            }
        }
        guard cleanedIndex == cleanedCharacters.count else { return false }

        var deliveredIndex = 0
        for (originalIndex, character) in originalCharacters.enumerated() {
            if deliveredIndex < deliveredCharacters.count,
               character == deliveredCharacters[deliveredIndex] {
                deliveredIndex += 1
            } else if !cleanupDeletedIndices.contains(originalIndex) {
                return false
            }
        }
        return deliveredIndex == deliveredCharacters.count
    }
}
