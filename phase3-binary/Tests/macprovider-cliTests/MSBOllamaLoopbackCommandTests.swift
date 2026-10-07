import XCTest
@testable import macprovider_cli

final class MSBOllamaLoopbackCommandTests: XCTestCase {
    func testEndpointUsesSharedClosedLoopbackOriginRules() {
        XCTAssertEqual(msbLoopbackEndpointURL("http://127.0.0.1:11434")?.absoluteString, "http://127.0.0.1:11434")
        XCTAssertNotNil(msbLoopbackEndpointURL("http://[::1]:11434"))
        XCTAssertNil(msbLoopbackEndpointURL("http://localhost:11434"))
        XCTAssertNil(msbLoopbackEndpointURL("http://127.0.0.1:11434/api/generate"))
        XCTAssertNil(msbLoopbackEndpointURL("http://127.0.0.1:11434?model=x"))
        XCTAssertNil(msbLoopbackEndpointURL("http://user:pw@127.0.0.1:11434"))
        XCTAssertNil(msbLoopbackEndpointURL("https://127.0.0.1:11434"))
        XCTAssertNil(msbLoopbackEndpointURL("http://10.0.0.2:11434"))
    }

    func testParseOllamaStreamEvents() throws {
        XCTAssertNil(try msbOllamaParseStreamLine(""))
        XCTAssertEqual(try msbOllamaParseStreamLine(#"{"model":"m","response":"x","done":false}"#), .token)
        XCTAssertEqual(
            try msbOllamaParseStreamLine(#"{"model":"m","response":"","done":true,"eval_count":257,"prompt_eval_count":1024}"#),
            .final(evalCount: 257, promptEvalCount: 1024, promptEvalCachedCount: nil)
        )
        XCTAssertEqual(
            try msbOllamaParseStreamLine(#"{"model":"m","response":"","done":false}"#),
            nil
        )
        XCTAssertEqual(
            try msbOllamaParseStreamLine(#"{"model":"m","response":"","done":true}"#),
            .final(evalCount: nil, promptEvalCount: nil, promptEvalCachedCount: nil)
        )
        XCTAssertEqual(
            try msbOllamaParseStreamLine(#"{"model":"m","response":"","done":true,"eval_count":257,"prompt_eval_count":1024,"prompt_eval_cached_count":0}"#),
            .final(evalCount: 257, promptEvalCount: 1024, promptEvalCachedCount: 0)
        )
    }

    func testRejectsMalformedOrErrorStreamEvents() {
        XCTAssertThrowsError(try msbOllamaParseStreamLine("{not json"))
        XCTAssertThrowsError(try msbOllamaParseStreamLine(#"{"error":"model not found"}"#)) { error in
            XCTAssertEqual(String(describing: error), "Ollama error: model not found")
        }
        XCTAssertThrowsError(try msbOllamaParseStreamLine(#"{"model":"m","done":false}"#))
    }

    func testSummaryExcludesTTFTBoundaryEvalToken() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let samples = [
            MSBOllamaLoopbackRequestSample(
                requestStartedAt: t0,
                firstTokenAt: t0.addingTimeInterval(0.25),
            endedAt: t0.addingTimeInterval(2.25),
            evalCount: 257,
            promptEvalCount: 1024,
            promptEvalCachedCount: nil
        ),
            MSBOllamaLoopbackRequestSample(
                requestStartedAt: t0,
                firstTokenAt: t0.addingTimeInterval(0.50),
            endedAt: t0.addingTimeInterval(4.25),
            evalCount: 257,
            promptEvalCount: 1024,
            promptEvalCachedCount: nil
        ),
        ]
        let summary = try msbOllamaLoopbackSummarizeRound(samples)
        XCTAssertEqual(summary.aggregateTokensPerSecond, 128, accuracy: 1e-9)
        XCTAssertEqual(summary.ttftSeconds, [0.25, 0.50])
    }

    func testQualifiedCountsFailClosed() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let sample = MSBOllamaLoopbackRequestSample(
            requestStartedAt: t0,
            firstTokenAt: t0.addingTimeInterval(0.1),
            endedAt: t0.addingTimeInterval(1),
            evalCount: 257,
            promptEvalCount: 1024,
            promptEvalCachedCount: nil
        )
        try msbOllamaRequireQualifiedCounts(sample, promptTokens: 1024, evalTokens: 257)
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(sample, promptTokens: 1023, evalTokens: 257))
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(sample, promptTokens: 1024, evalTokens: 256))
        let cached = MSBOllamaLoopbackRequestSample(
            requestStartedAt: t0,
            firstTokenAt: t0.addingTimeInterval(0.1),
            endedAt: t0.addingTimeInterval(1),
            evalCount: 257,
            promptEvalCount: 1024,
            promptEvalCachedCount: 1
        )
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(cached, promptTokens: 1024, evalTokens: 257))
    }

    func testPromptCacheVerificationNamesUnknownVsReportedZero() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let unknown = MSBOllamaLoopbackRequestSample(
            requestStartedAt: t0,
            firstTokenAt: t0,
            endedAt: t0,
            evalCount: 257,
            promptEvalCount: 1024,
            promptEvalCachedCount: nil
        )
        let reported = MSBOllamaLoopbackRequestSample(
            requestStartedAt: t0,
            firstTokenAt: t0,
            endedAt: t0,
            evalCount: 257,
            promptEvalCount: 1024,
            promptEvalCachedCount: 0
        )
        XCTAssertEqual(msbOllamaPromptCacheVerification([unknown]), "not_reported_by_ollama")
        XCTAssertEqual(msbOllamaPromptCacheVerification([reported]), "reported_zero")
        XCTAssertEqual(msbOllamaPromptCacheVerification([unknown, reported]), "mixed_reported_zero_and_not_reported")
    }

    func testReportRedactsPromptModelAndPaths() throws {
        let report = MSBOllamaLoopbackReport(
            schemaVersion: 1,
            runtime: "ollama_loopback",
            originClass: "loopback_http",
            modelNameSHA256: String(repeating: "a", count: 64),
            artifactHashAlgorithm: ModelArtifactIdentity.ggufFileV1,
            artifactSHA256: String(repeating: "b", count: 64),
            promptTokensPerRow: 1024,
            evalTokensPerRow: 257,
            timedDecodeTokensPerRow: 256,
            runs: 5,
            promptSHA256: [String(repeating: "c", count: 64)],
            levels: [],
            countSource: "ollama_reported_operator_benchmark_only",
            nativeIdenticalTokenSequences: false,
            canonical1690Profile: true,
            billingEvidence: false,
            timestamp: "2026-10-07T00:00:00Z"
        )
        let text = String(data: try MSBOllamaLoopbackReport.encode(report), encoding: .utf8)!
        XCTAssertFalse(text.contains("qwen25-05b-ollama"))
        XCTAssertFalse(text.contains("Tell me"))
        XCTAssertFalse(text.contains("/Users/"))
        XCTAssertFalse(text.contains("127.0.0.1"))
        XCTAssertFalse(text.contains("Authorization"))
        XCTAssertTrue(text.contains(#""countSource" : "ollama_reported_operator_benchmark_only""#))
        XCTAssertTrue(text.contains(#""nativeIdenticalTokenSequences" : false"#))
        XCTAssertTrue(text.contains(#""billingEvidence" : false"#))
    }

    func testSHA256HelperIsStable() {
        XCTAssertEqual(
            msbOllamaSHA256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
