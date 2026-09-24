import XCTest
@testable import macprovider_cli

/// Pure-logic coverage for the #1690 `msb-loopback` harness. The live
/// llama-server run is lab evidence, not a unit test.
final class MSBLoopbackCommandTests: XCTestCase {
    func testEndpointAcceptsOnlyHTTPLoopback() {
        XCTAssertEqual(msbLoopbackEndpointURL("http://127.0.0.1:8181")?.absoluteString, "http://127.0.0.1:8181")
        XCTAssertEqual(msbLoopbackEndpointURL("http://127.0.0.1:8181/")?.absoluteString, "http://127.0.0.1:8181")
        XCTAssertNotNil(msbLoopbackEndpointURL("http://[::1]:8181"))
        // Loopback literals only, origin only (#1690 freeze audit R1 SEC-6).
        XCTAssertNil(msbLoopbackEndpointURL("http://localhost:8181"))
        XCTAssertNil(msbLoopbackEndpointURL("http://127.0.0.1"))
        XCTAssertNil(msbLoopbackEndpointURL("http://127.0.0.1:8181/v1"))
        XCTAssertNil(msbLoopbackEndpointURL("http://127.0.0.1:8181?x=1"))
        XCTAssertNil(msbLoopbackEndpointURL("http://127.0.0.1:8181#frag"))
        XCTAssertNil(msbLoopbackEndpointURL("http://user:pw@127.0.0.1:8181"))
        XCTAssertNil(msbLoopbackEndpointURL("http://10.0.0.5:8181"))
        XCTAssertNil(msbLoopbackEndpointURL("http://127.0.0.1.example.com:8181"))
        XCTAssertNil(msbLoopbackEndpointURL("https://127.0.0.1:8181"))
        XCTAssertNil(msbLoopbackEndpointURL("not a url"))
    }

    func testParseStreamLineTokenAndFinalEvents() throws {
        XCTAssertNil(try msbLoopbackParseStreamLine(""))
        XCTAssertNil(try msbLoopbackParseStreamLine(": keepalive"))
        XCTAssertNil(try msbLoopbackParseStreamLine("data: [DONE]"))
        XCTAssertEqual(try msbLoopbackParseStreamLine(#"data: {"content":"hi","stop":false}"#), .token)
        // Empty content is still one sampled token (held-back partial UTF-8).
        XCTAssertEqual(try msbLoopbackParseStreamLine(#"data: {"content":"","stop":false}"#), .token)
        XCTAssertEqual(
            try msbLoopbackParseStreamLine(
                #"data: {"content":"","stop":true,"tokens_predicted":257,"tokens_evaluated":1024,"timings":{"prompt_n":1024,"predicted_n":257}}"#
            ),
            .final(predictedTokens: 257, promptTokens: 1024)
        )
        XCTAssertEqual(
            try msbLoopbackParseStreamLine(#"data: {"stop":true,"timings":{"predicted_n":9}}"#),
            .final(predictedTokens: 9, promptTokens: nil)
        )
    }

    func testParseStreamLineSurfacesServerErrorsAndGarbage() {
        XCTAssertThrowsError(try msbLoopbackParseStreamLine(#"data: {"error":{"message":"context full"}}"#)) { error in
            XCTAssertEqual(String(describing: error), "llama-server error: context full")
        }
        XCTAssertThrowsError(try msbLoopbackParseStreamLine("data: {not json"))
    }

    func testSummarizeRoundExcludesTTFTBoundaryTokenAndUsesCommonWall() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let samples = [
            MSBLoopbackRequestSample(
                requestStartedAt: t0,
                firstTokenAt: t0.addingTimeInterval(0.5),
                endedAt: t0.addingTimeInterval(2.5),
                predictedTokens: 101,
                promptTokens: 1024
            ),
            MSBLoopbackRequestSample(
                requestStartedAt: t0,
                firstTokenAt: t0.addingTimeInterval(1.0),
                endedAt: t0.addingTimeInterval(4.5),
                predictedTokens: 101,
                promptTokens: 1024
            ),
        ]
        let summary = try msbLoopbackSummarizeRound(samples)
        // 200 decoded tokens over the common window 0.5s..4.5s.
        XCTAssertEqual(summary.aggregateTokensPerSecond, 50, accuracy: 1e-9)
        XCTAssertEqual(summary.ttftSeconds, [0.5, 1.0])
        // Per-row rates 50 and ~28.6; p50 rank rounds to the upper value.
        XCTAssertEqual(summary.perRowTokensPerSecondP50, 50, accuracy: 1e-9)
    }

    func testSharedPromptTextIsDeterministicAndDistinctPerRow() {
        let a = MSBThroughputCommand.buildPromptText(index: 0, targetTokens: 64)
        XCTAssertEqual(a, MSBThroughputCommand.buildPromptText(index: 0, targetTokens: 64))
        XCTAssertNotEqual(a, MSBThroughputCommand.buildPromptText(index: 1, targetTokens: 64))
        XCTAssertGreaterThanOrEqual(a.count, 64 * 5)
    }
}
