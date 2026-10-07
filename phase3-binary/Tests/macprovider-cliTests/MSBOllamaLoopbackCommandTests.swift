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
            .final(evalCount: 257, promptEvalCount: 1024, promptEvalCachedCount: nil, doneReason: nil)
        )
        XCTAssertEqual(
            try msbOllamaParseStreamLine(#"{"model":"m","response":"","done":false}"#),
            nil
        )
        XCTAssertEqual(
            try msbOllamaParseStreamLine(#"{"model":"m","response":"","done":true}"#),
            .final(evalCount: nil, promptEvalCount: nil, promptEvalCachedCount: nil, doneReason: nil)
        )
        XCTAssertEqual(
            try msbOllamaParseStreamLine(#"{"model":"m","response":"","done":true,"eval_count":257,"prompt_eval_count":1024,"prompt_eval_cached_count":0,"done_reason":"length"}"#),
            .final(evalCount: 257, promptEvalCount: 1024, promptEvalCachedCount: 0, doneReason: "length")
        )
    }

    func testRejectsMalformedOrErrorStreamEvents() {
        XCTAssertThrowsError(try msbOllamaParseStreamLine("{not json"))
        XCTAssertThrowsError(try msbOllamaParseStreamLine(#"{"error":"model not found"}"#)) { error in
            XCTAssertEqual(String(describing: error), "Ollama error: model not found")
        }
        XCTAssertThrowsError(try msbOllamaParseStreamLine(#"{"model":"m","done":false}"#))
    }

    func testRejectsMalformedFinalMetadataInsteadOfTreatingItAsUnknown() {
        for value in ["0", "1", "null", "\"true\""] {
            XCTAssertThrowsError(try msbOllamaParseStreamLine(
                "{\"done\":\(value),\"response\":\"x\"}"
            ))
        }
        XCTAssertThrowsError(try msbOllamaParseStreamLine(#"{"done":true,"response":1}"#))
        for key in ["eval_count", "prompt_eval_count", "prompt_eval_cached_count"] {
            for value in ["true", "false", "1.5", "null", "\"1023\"", "{}", "[]"] {
                XCTAssertThrowsError(try msbOllamaParseStreamLine(
                    "{\"done\":true,\"\(key)\":\(value)}"
                ), "\(key)=\(value)")
            }
        }
        for value in ["true", "1", "null", "{}", "[]"] {
            XCTAssertThrowsError(try msbOllamaParseStreamLine(
                "{\"done\":true,\"done_reason\":\(value)}"
            ), "done_reason=\(value)")
        }
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
                promptEvalCachedCount: nil,
                doneReason: nil
            ),
            MSBOllamaLoopbackRequestSample(
                requestStartedAt: t0,
                firstTokenAt: t0.addingTimeInterval(0.50),
                endedAt: t0.addingTimeInterval(4.25),
                evalCount: 257,
                promptEvalCount: 1024,
                promptEvalCachedCount: nil,
                doneReason: nil
            ),
        ]
        let summary = try msbOllamaLoopbackSummarizeRound(samples)
        XCTAssertEqual(summary.aggregateTokensPerSecond, 128, accuracy: 1e-9)
        XCTAssertEqual(summary.endToEndEvalTokensPerSecond, 514 / 4.25, accuracy: 1e-9)
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
            promptEvalCachedCount: nil,
            doneReason: nil
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
            promptEvalCachedCount: 1,
            doneReason: nil
        )
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(cached, promptTokens: 1024, evalTokens: 257))
        let negativeCached = MSBOllamaLoopbackRequestSample(
            requestStartedAt: t0,
            firstTokenAt: t0.addingTimeInterval(0.1),
            endedAt: t0.addingTimeInterval(1),
            evalCount: 257,
            promptEvalCount: 1024,
            promptEvalCachedCount: -1,
            doneReason: nil
        )
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(negativeCached, promptTokens: 1024, evalTokens: 257))
    }

    func testCapabilityAwareAcceptsEOSAndCachedCountsAndRecordsThem() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let sample = MSBOllamaLoopbackRequestSample(
            requestStartedAt: t0,
            firstTokenAt: t0.addingTimeInterval(0.2),
            endedAt: t0.addingTimeInterval(1.2),
            evalCount: 42,
            promptEvalCount: 1024,
            promptEvalCachedCount: 128,
            doneReason: "stop"
        )
        try msbOllamaRequireQualifiedCounts(sample, promptTokens: 1024, evalTokens: 257, mode: .capabilityAware)
        let report = MSBOllamaLoopbackRequestReport(sample: sample)
        XCTAssertEqual(report.evalCount, 42)
        XCTAssertEqual(report.promptEvalCount, 1024)
        XCTAssertEqual(report.promptEvalCachedCount, 128)
        XCTAssertEqual(report.doneReason, "stop")
        XCTAssertEqual(report.ttftSeconds, 0.2, accuracy: 1e-9)
        XCTAssertEqual(report.requestSeconds, 1.2, accuracy: 1e-9)
        XCTAssertEqual(msbOllamaPromptCacheVerification([sample]), "reported_cached_prompt_eval")
    }

    func testCapabilityAwareRejectsInvalidCountsRangesReasonsAndTimings() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        func sample(
            evalCount: Int = 42,
            promptEvalCount: Int = 1024,
            cached: Int? = 0,
            doneReason: String? = "length",
            firstTokenOffset: TimeInterval = 0.2,
            endedOffset: TimeInterval = 1.2
        ) -> MSBOllamaLoopbackRequestSample {
            MSBOllamaLoopbackRequestSample(
                requestStartedAt: t0,
                firstTokenAt: t0.addingTimeInterval(firstTokenOffset),
                endedAt: t0.addingTimeInterval(endedOffset),
                evalCount: evalCount,
                promptEvalCount: promptEvalCount,
                promptEvalCachedCount: cached,
                doneReason: doneReason
            )
        }

        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(sample(evalCount: 1), promptTokens: 1024, evalTokens: 257, mode: .capabilityAware))
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(sample(evalCount: 258), promptTokens: 1024, evalTokens: 257, mode: .capabilityAware))
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(sample(promptEvalCount: 1023), promptTokens: 1024, evalTokens: 257, mode: .capabilityAware))
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(sample(cached: -1), promptTokens: 1024, evalTokens: 257, mode: .capabilityAware))
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(sample(cached: 1025), promptTokens: 1024, evalTokens: 257, mode: .capabilityAware))
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(sample(doneReason: "unload"), promptTokens: 1024, evalTokens: 257, mode: .capabilityAware))
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(sample(firstTokenOffset: -0.1), promptTokens: 1024, evalTokens: 257, mode: .capabilityAware))
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(sample(firstTokenOffset: .nan), promptTokens: 1024, evalTokens: 257, mode: .capabilityAware))
        XCTAssertThrowsError(try msbOllamaRequireQualifiedCounts(sample(endedOffset: 0.2), promptTokens: 1024, evalTokens: 257, mode: .capabilityAware))
    }

    func testPromptCacheVerificationNamesUnknownVsReportedZero() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let unknown = MSBOllamaLoopbackRequestSample(
            requestStartedAt: t0,
            firstTokenAt: t0,
            endedAt: t0,
            evalCount: 257,
            promptEvalCount: 1024,
            promptEvalCachedCount: nil,
            doneReason: nil
        )
        let reported = MSBOllamaLoopbackRequestSample(
            requestStartedAt: t0,
            firstTokenAt: t0,
            endedAt: t0,
            evalCount: 257,
            promptEvalCount: 1024,
            promptEvalCachedCount: 0,
            doneReason: nil
        )
        let cached = MSBOllamaLoopbackRequestSample(
            requestStartedAt: t0,
            firstTokenAt: t0,
            endedAt: t0,
            evalCount: 257,
            promptEvalCount: 1024,
            promptEvalCachedCount: 5,
            doneReason: nil
        )
        XCTAssertEqual(msbOllamaPromptCacheVerification([unknown]), "not_reported_by_ollama")
        XCTAssertEqual(msbOllamaPromptCacheVerification([reported]), "reported_zero")
        XCTAssertEqual(msbOllamaPromptCacheVerification([unknown, reported]), "mixed_reported_zero_and_not_reported")
        XCTAssertEqual(msbOllamaPromptCacheVerification([cached]), "reported_cached_prompt_eval")
        XCTAssertEqual(msbOllamaPromptCacheVerification([unknown, cached]), "mixed_reported_cached_and_not_reported")
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
            operatorBenchmarkMode: "capability_aware",
            requestedCanonical1690Profile: true,
            strictM0Qualified: false,
            forcedDecodeTokensExact: false,
            promptCacheDisabled: false,
            nativeIdenticalTokenSequences: false,
            runtimePerplexityEvidence: false,
            canonical1690Profile: false,
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
        XCTAssertTrue(text.contains(#""operatorBenchmarkMode" : "capability_aware""#))
        XCTAssertTrue(text.contains(#""forcedDecodeTokensExact" : false"#))
        XCTAssertTrue(text.contains(#""promptCacheDisabled" : false"#))
        XCTAssertTrue(text.contains(#""nativeIdenticalTokenSequences" : false"#))
        XCTAssertTrue(text.contains(#""runtimePerplexityEvidence" : false"#))
        XCTAssertTrue(text.contains(#""canonical1690Profile" : false"#))
        XCTAssertTrue(text.contains(#""billingEvidence" : false"#))
    }

    func testHistoricalReportDecodesWithoutNewFields() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "runtime": "ollama_loopback",
          "originClass": "loopback_http",
          "modelNameSHA256": "\(String(repeating: "a", count: 64))",
          "artifactHashAlgorithm": "\(ModelArtifactIdentity.ggufFileV1)",
          "artifactSHA256": "\(String(repeating: "b", count: 64))",
          "promptTokensPerRow": 1024,
          "evalTokensPerRow": 257,
          "timedDecodeTokensPerRow": 256,
          "runs": 5,
          "promptSHA256": ["\(String(repeating: "c", count: 64))"],
          "levels": [
            {
              "concurrency": 1,
              "aggregateTPSRuns": [128.0],
              "aggregateTPSp50": 128.0,
              "aggregateCVPct": 0.0,
              "perRowTPSp50": 128.0,
              "ttftSecondsP50": 0.2,
              "ttftSecondsP95": 0.2,
              "ttftSamples": 1,
              "promptCacheVerification": "reported_zero"
            }
          ],
          "countSource": "ollama_reported_operator_benchmark_only",
          "nativeIdenticalTokenSequences": false,
          "canonical1690Profile": true,
          "billingEvidence": false,
          "timestamp": "2026-10-07T00:00:00Z"
        }
        """.utf8)
        let report = try JSONDecoder().decode(MSBOllamaLoopbackReport.self, from: data)
        XCTAssertNil(report.operatorBenchmarkMode)
        XCTAssertNil(report.requestedCanonical1690Profile)
        XCTAssertNil(report.levels[0].requestSamples)
        XCTAssertNil(report.levels[0].endToEndEvalTPSp50)
        XCTAssertEqual(report.levels[0].promptCacheVerification, "reported_zero")
    }

    func testRequestReportEncodesNilCachedCountExplicitly() throws {
        let report = MSBOllamaLoopbackRequestReport(
            evalCount: 42,
            promptEvalCount: 1024,
            promptEvalCachedCount: nil,
            doneReason: nil,
            ttftSeconds: 0.2,
            requestSeconds: 1.2
        )
        let text = String(data: try JSONEncoder().encode(report), encoding: .utf8)!
        XCTAssertTrue(text.contains(#""promptEvalCachedCount":null"#))
    }

    func testSHA256HelperIsStable() {
        XCTAssertEqual(
            msbOllamaSHA256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
