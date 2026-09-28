import XCTest
import MacProviderCore
@testable import macprovider_cli

final class StreamingEmitterCleanupRewriteTests: XCTestCase {
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

    private func stream(
        decodes: [String],
        stops: [String] = [],
        final: String? = nil
    ) throws -> [String] {
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
        return chunks
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
}
