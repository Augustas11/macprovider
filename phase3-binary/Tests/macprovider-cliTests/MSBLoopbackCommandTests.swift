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

    func testPromptBuilderKeepsBoundedNativeTailAfterExtendedHead() {
        let prompt = MSBThroughputCommand.msbBuildPromptTokens(index: 0, targetTokens: 8) { text, addSpecial in
            if addSpecial {
                XCTAssertTrue(text.hasPrefix("Document 0 revision 3:"))
                return [10, 11, 12]
            }
            if text == MSBThroughputCommand.promptBoundedTailText(index: 0) {
                return [90, 91]
            }
            if text == MSBThroughputCommand.promptExtensionText(index: 0, salt: 0) {
                return [20, 30]
            }
            if text == MSBThroughputCommand.promptExtensionText(index: 0, salt: 1) {
                return [21, 31]
            }
            XCTFail("unexpected prompt fragment: \(text)")
            return []
        }

        XCTAssertEqual(prompt, [10, 11, 12, 20, 30, 21, 90, 91])
    }

    func testPromptBuilderUsesBoundedTailWhenTailFillsTarget() {
        let prompt = MSBThroughputCommand.msbBuildPromptTokens(index: 2, targetTokens: 4) { text, addSpecial in
            if addSpecial {
                return [10, 11, 12]
            }
            if text == MSBThroughputCommand.promptBoundedTailText(index: 2) {
                return [1, 2, 3, 4, 5, 6]
            }
            XCTFail("extension should not be requested when bounded tail fills target")
            return []
        }

        XCTAssertEqual(prompt, [3, 4, 5, 6])
    }

    func testPromptBuilderTruncatesLongHeadBeforeBoundedTail() {
        let prompt = MSBThroughputCommand.msbBuildPromptTokens(index: 1, targetTokens: 5) { text, addSpecial in
            if addSpecial {
                return [1, 2, 3, 4, 5, 6]
            }
            if text == MSBThroughputCommand.promptBoundedTailText(index: 1) {
                return [88, 89]
            }
            XCTFail("extension should not be requested when the initial head is long enough")
            return []
        }

        XCTAssertEqual(prompt, [1, 2, 3, 88, 89])
    }

    func testAsyncPromptBuilderFailsImmediatelyOnZeroProgressExtension() async {
        var extensionCalls = 0
        let encode: (String, Bool) async throws -> [Int] = { text, addSpecial in
            if addSpecial {
                return [10]
            }
            if text == MSBThroughputCommand.promptBoundedTailText(index: 0) {
                return [90]
            }
            extensionCalls += 1
            return []
        }
        do {
            _ = try await MSBThroughputCommand.msbBuildPromptTokens(
                index: 0,
                targetTokens: 6,
                encode: encode
            )
            XCTFail("empty extension tokens should fail")
        } catch let error as MSBPromptBuildError {
            XCTAssertEqual(
                error,
                .zeroProgressExtension(index: 0, salt: 0, targetTokens: 6)
            )
            XCTAssertEqual(extensionCalls, 1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReportsDecodeHistoricalArtifactsMissingPromptTokenHashes() throws {
        let hash = String(repeating: "a", count: 64)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let throughput = MSBThroughputReport(
            schemaVersion: 4,
            modelID: "model",
            modelTag: "model",
            mlxSwiftLMPin: "pin",
            engine: "contiguous",
            compiled: true,
            scenario: "throughput",
            rows: 1,
            promptTokensPerRow: 2,
            promptTokenLengths: [2],
            decodeTokensPerRow: 1,
            productionSerialPromptTokens: 2,
            layerCount: 1,
            blockSizeTokens: 1,
            maxPhysicalBlocks: 1,
            runs: 1,
            productionSerialTPSRuns: [1],
            productionSerialTPSp50: 1,
            productionSerialCVPct: 0,
            pagedSingleRowTPSRuns: [1],
            pagedSingleRowTPSp50: 1,
            pagedSingleRowCVPct: 0,
            aggregateTPSRuns: [1],
            aggregateTPSp50: 1,
            aggregateCVPct: 0,
            perRowTPSp50: 1,
            aggregateUpliftVsPagedSingleRow: 1,
            aggregateVsProductionSerial: 1,
            perRowFractionOfPagedSingleRow: 1,
            peakRSSMB: 1,
            leftovers: nil,
            timestamp: "2026-10-07T00:00:00Z",
            promptTokenSHA256: [hash]
        )
        let historicalThroughput = try decoder.decode(
            MSBThroughputReport.self,
            from: Self.removingPromptHashKey(from: encoder.encode(throughput))
        )
        XCTAssertNil(historicalThroughput.promptTokenSHA256)

        let level = MSBLoopbackLevelReport(
            concurrency: 1,
            aggregateTPSRuns: [1],
            aggregateTPSp50: 1,
            aggregateCVPct: 0,
            perRowTPSp50: 1,
            ttftSecondsP50: 0.1,
            ttftSecondsP95: 0.2,
            ttftSamples: 1,
            promptTokenSHA256: [hash]
        )
        let historicalLevel = try decoder.decode(
            MSBLoopbackLevelReport.self,
            from: Self.removingPromptHashKey(from: encoder.encode(level))
        )
        XCTAssertNil(historicalLevel.promptTokenSHA256)

        let report = MSBLoopbackReport(
            schemaVersion: 1,
            runtime: "llama-server",
            endpoint: "http://127.0.0.1:8181",
            label: nil,
            serverModelPath: nil,
            serverBuildInfo: nil,
            serverTotalSlots: 1,
            promptTokensPerRow: 2,
            decodeTokensPerRow: 1,
            runs: 1,
            levels: [level],
            serverPeakPhysFootprintMB: nil,
            timestamp: "2026-10-07T00:00:00Z",
            promptTokenSHA256: [hash]
        )
        let historicalReport = try decoder.decode(
            MSBLoopbackReport.self,
            from: Self.removingPromptHashKey(from: encoder.encode(report))
        )
        XCTAssertNil(historicalReport.promptTokenSHA256)
    }

    func testPromptTokenHashIsDeterministicAndOpaque() {
        let hash = msbPromptTokenSHA256([1, 2, 3])

        XCTAssertEqual(hash, msbPromptTokenSHA256([1, 2, 3]))
        XCTAssertNotEqual(hash, msbPromptTokenSHA256([1, 2, 4]))
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { Set("0123456789abcdef").contains($0) })
    }

    private static func removingPromptHashKey(from data: Data) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "promptTokenSHA256")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
