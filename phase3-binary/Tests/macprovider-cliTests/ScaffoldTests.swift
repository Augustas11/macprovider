import XCTest
@testable import macprovider_cli

/// Unit tests for `CompiledDecode` env-flag parsing.
/// Ported from `perf/mlx-compile-bf16` as part of T2-01 (T2-01-compiled-decode-wire-in).
///
/// Live `CompiledDecodeStep` correctness (greedy token-ID equality) requires
/// a real loaded model and is covered by the manual bench in
/// `beta/throughput-engineering/T2-01-compiled-decode-wire-in.md`.
final class CompiledDecodeFlagTests: XCTestCase {
    func testEnvFlagAcceptsCommonTruthyForms() {
        XCTAssertTrue(CompiledDecode.isEnabledByEnvironment(["MACPROVIDER_COMPILED_DECODE": "1"]))
        XCTAssertTrue(CompiledDecode.isEnabledByEnvironment(["MACPROVIDER_COMPILED_DECODE": "true"]))
        XCTAssertTrue(CompiledDecode.isEnabledByEnvironment(["MACPROVIDER_COMPILED_DECODE": "TRUE"]))
        XCTAssertTrue(CompiledDecode.isEnabledByEnvironment(["MACPROVIDER_COMPILED_DECODE": "yes"]))
        XCTAssertTrue(CompiledDecode.isEnabledByEnvironment(["MACPROVIDER_COMPILED_DECODE": " 1 "]))
    }

    func testEnvFlagDefaultsOff() {
        XCTAssertFalse(CompiledDecode.isEnabledByEnvironment([:]))
        XCTAssertFalse(CompiledDecode.isEnabledByEnvironment(["MACPROVIDER_COMPILED_DECODE": "0"]))
        XCTAssertFalse(CompiledDecode.isEnabledByEnvironment(["MACPROVIDER_COMPILED_DECODE": "false"]))
        XCTAssertFalse(CompiledDecode.isEnabledByEnvironment(["MACPROVIDER_COMPILED_DECODE": ""]))
        XCTAssertFalse(CompiledDecode.isEnabledByEnvironment(["MACPROVIDER_COMPILED_DECODE": "maybe"]))
    }

    func testEnvFlagIsDefaultOff_LiveEnvironment() {
        // Verify the env-flag lookup in the live process environment defaults to false
        // when the variable is not set. This is the safety check that ensures production
        // serve starts without compiled decode unless the operator explicitly opts in.
        let env = ProcessInfo.processInfo.environment
        if env[CompiledDecode.envFlag] == nil {
            XCTAssertFalse(CompiledDecode.isEnabledByEnvironment())
        }
    }
}

/// Unit tests for `DecodeBench` helper functions.
final class DecodeBenchHelperTests: XCTestCase {
    func testPercentileP50OnThreeRunsReturnsMiddle() {
        XCTAssertEqual(decodeBenchPercentileTPS([10.0, 30.0, 20.0], p: 0.5), 20.0)
    }

    func testPercentileP50OnEmptyReturnsZero() {
        XCTAssertEqual(decodeBenchPercentileTPS([], p: 0.5), 0.0)
    }

    func testPercentileP100OnFourRunsReturnsMax() {
        XCTAssertEqual(decodeBenchPercentileTPS([1.0, 2.0, 3.0, 4.0], p: 1.0), 4.0)
    }

    func testPinTagIsNonEmpty() {
        XCTAssertFalse(decodeBenchMLXPinTag().isEmpty)
    }

    func testSanitizeFilenameComponentRejectsPathTraversal() {
        XCTAssertEqual(decodeBenchSanitizeFilenameComponent("../etc/passwd"), "etc_passwd")
        XCTAssertEqual(decodeBenchSanitizeFilenameComponent("..\\windows"), "windows")
        XCTAssertEqual(decodeBenchSanitizeFilenameComponent("a/b/c"), "a_b_c")
    }

    func testSanitizeFilenameComponentKeepsSafeChars() {
        XCTAssertEqual(decodeBenchSanitizeFilenameComponent("baseline"), "baseline")
        XCTAssertEqual(
            decodeBenchSanitizeFilenameComponent("Qwen2.5-32B-Instruct-4bit"),
            "Qwen2.5-32B-Instruct-4bit"
        )
        XCTAssertEqual(decodeBenchSanitizeFilenameComponent("compiled_on"), "compiled_on")
    }

    func testSanitizeFilenameComponentHandlesEdgeCases() {
        XCTAssertEqual(decodeBenchSanitizeFilenameComponent(""), "unlabeled")
        XCTAssertEqual(decodeBenchSanitizeFilenameComponent("///"), "unlabeled")
        XCTAssertEqual(decodeBenchSanitizeFilenameComponent("..."), "unlabeled")
        // 100-char input gets capped to 80.
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(decodeBenchSanitizeFilenameComponent(long).count, 80)
    }

    func testMSBThroughputEngineParsesKnownValues() {
        XCTAssertEqual(MSBThroughputEngine(rawValue: "contiguous"), .contiguous)
        XCTAssertEqual(MSBThroughputEngine(rawValue: "paged"), .paged)
        XCTAssertEqual(MSBThroughputEngine(rawValue: "scheduler"), .scheduler)
        XCTAssertEqual(MSBThroughputEngine(rawValue: "serial-parallel"), .serialParallel)
        XCTAssertNil(MSBThroughputEngine(rawValue: "fused"))
        XCTAssertEqual(MSBThroughputEngine.allCases.count, 4)
    }

    func testMSBThroughputScenarioParsesKnownValues() {
        XCTAssertEqual(MSBThroughputScenario(rawValue: "throughput"), .throughput)
        XCTAssertEqual(MSBThroughputScenario(rawValue: "msb03"), .msb03)
        XCTAssertEqual(MSBThroughputScenario(rawValue: "msb05"), .msb05)
        XCTAssertEqual(MSBThroughputScenario(rawValue: "parity"), .parity)
        XCTAssertEqual(MSBThroughputScenario(rawValue: "isolation"), .isolation)
        XCTAssertEqual(MSBThroughputScenario(rawValue: "replay"), .replay)
        XCTAssertEqual(MSBThroughputScenario(rawValue: "drain"), .drain)
        XCTAssertEqual(MSBThroughputScenario(rawValue: "leftovers"), .leftovers)
        XCTAssertEqual(MSBThroughputScenario.allCases.count, 8)
    }

    func testMSB03PromptLengthsAndGates() {
        XCTAssertEqual(msb03PromptLengths(), [512, 1024, 1536, 2048])
        XCTAssertTrue(msb03AggregatePass(aggregateVsSerial: 1.21))
        XCTAssertFalse(msb03AggregatePass(aggregateVsSerial: 1.2))
        XCTAssertTrue(msb03ShortRequestTTFTPass(ratio: 2.0))
        XCTAssertFalse(msb03ShortRequestTTFTPass(ratio: 2.01))
        XCTAssertFalse(msb03ShortRequestTTFTPass(ratio: 0))
    }

    func testMSBTemp0ParityAndUsageAttribution() {
        let match = msbTemp0ParityMatch(serial: [1, 2, 3, 4], batched: [1, 2, 3, 9], comparedTokens: 4)
        XCTAssertFalse(match.match)
        XCTAssertEqual(match.firstDivergence, 3)
        XCTAssertTrue(msbTemp0ParityMatch(serial: [1, 2], batched: [1, 2, 3], comparedTokens: 2).match)
        XCTAssertEqual(
            msbTokenSequenceSHA256([1, 2]),
            msbTokenSequenceSHA256([1, 2])
        )
        XCTAssertNotEqual(
            msbTokenSequenceSHA256([1, 2]),
            msbTokenSequenceSHA256([2, 1])
        )
        let usage = [
            MSBUsageRow(
                requestID: "a",
                promptTokens: 512,
                completionTokens: 256,
                emittedTokens: 256,
                cachedPromptTokens: 0,
                terminalStatus: "length",
                settlementDisposition: "eligible_owner"
            ),
            MSBUsageRow(
                requestID: "b",
                promptTokens: 1024,
                completionTokens: 256,
                emittedTokens: 256,
                cachedPromptTokens: 0,
                terminalStatus: "length",
                settlementDisposition: "eligible_owner"
            ),
        ]
        XCTAssertTrue(msbUsageAttributionPass(
            rows: usage,
            expectedPromptTokens: [512, 1024],
            expectedCompletionTokens: 256
        ))
        XCTAssertFalse(msbUsageAttributionPass(
            rows: usage,
            expectedPromptTokens: [512, 512],
            expectedCompletionTokens: 256
        ))
        var badSettlement = usage
        badSettlement[0] = MSBUsageRow(
            requestID: "a",
            promptTokens: 512,
            completionTokens: 256,
            emittedTokens: 256,
            cachedPromptTokens: 0,
            terminalStatus: "length",
            settlementDisposition: "not_eligible"
        )
        XCTAssertFalse(msbUsageAttributionPass(
            rows: badSettlement,
            expectedPromptTokens: [512, 1024],
            expectedCompletionTokens: 256
        ))
    }

    func testMSBIsolationReplayDrainPredicates() {
        XCTAssertTrue(msbIsolationPass(MSBIsolationEvidence(
            cancelledRequestID: "cancel",
            healthyRequestID: "healthy",
            cancelledStatus: "cancelled",
            healthyStatus: "length",
            cancelledCompletionTokens: 1,
            healthyCompletionTokens: 32,
            pass: false
        )))
        XCTAssertFalse(msbIsolationPass(MSBIsolationEvidence(
            cancelledRequestID: "cancel",
            healthyRequestID: "healthy",
            cancelledStatus: "cancelled",
            healthyStatus: "cancelled",
            cancelledCompletionTokens: 1,
            healthyCompletionTokens: 1,
            pass: false
        )))
        XCTAssertTrue(msbReplayPass(MSBReplayEvidence(
            requestID: "owner",
            firstDisposition: "eligible_owner",
            replayDisposition: "non_settling_replay",
            tokensMatch: true,
            pass: false
        )))
        XCTAssertFalse(msbReplayPass(MSBReplayEvidence(
            requestID: "owner",
            firstDisposition: "eligible_owner",
            replayDisposition: "eligible_owner",
            tokensMatch: true,
            pass: false
        )))
        XCTAssertTrue(msbDrainPass(MSBDrainEvidence(
            queuedRejected: true,
            permitIssued: true,
            permitValid: true,
            postDrainRejected: true,
            activeStatuses: ["length", "length"],
            activeSettlements: ["eligible_owner", "eligible_owner"],
            activeRowsCompleted: true,
            pass: false
        )))
        XCTAssertFalse(msbDrainPass(MSBDrainEvidence(
            queuedRejected: true,
            permitIssued: true,
            permitValid: true,
            postDrainRejected: true,
            activeStatuses: ["batch_failed", "length"],
            activeSettlements: ["not_eligible", "eligible_owner"],
            activeRowsCompleted: false,
            pass: false
        )))
        XCTAssertFalse(msbOMLXSidecarUnavailableReason().isEmpty)
    }

    func testContiguousBatchedDecodeErrorCasesExist() {
        XCTAssertNotEqual(
            ContiguousBatchedDecodeError.invalidArguments,
            ContiguousBatchedDecodeError.raggedPrompts
        )
    }

    func testMSBAggregateThroughputUsesCommonWallClock() throws {
        let base = Date(timeIntervalSince1970: 100)
        let report = try msbAggregateThroughput([
            MSBAggregateThroughputInput(
                decodedTokens: 100,
                decodeStartedAt: base,
                decodeEndedAt: base.addingTimeInterval(10)
            ),
            MSBAggregateThroughputInput(
                decodedTokens: 100,
                decodeStartedAt: base.addingTimeInterval(2),
                decodeEndedAt: base.addingTimeInterval(12)
            ),
        ])

        XCTAssertEqual(report.totalDecodedTokens, 200)
        XCTAssertEqual(report.commonWallSeconds, 12, accuracy: 0.001)
        XCTAssertEqual(report.aggregateTokensPerSecond, 200.0 / 12.0, accuracy: 0.001)
    }

    func testMSBAggregateThroughputRejectsInvalidSamples() {
        XCTAssertThrowsError(try msbAggregateThroughput([])) { error in
            XCTAssertEqual(error as? MSBAggregateThroughputError, .emptySamples)
        }
        let now = Date()
        XCTAssertThrowsError(try msbAggregateThroughput([
            MSBAggregateThroughputInput(decodedTokens: 1, decodeStartedAt: now, decodeEndedAt: now),
        ])) { error in
            XCTAssertEqual(error as? MSBAggregateThroughputError, .invalidSample)
        }
    }

    func testMSBAggregateThroughputRejectsTokenCountOverflow() {
        let base = Date(timeIntervalSince1970: 100)
        XCTAssertThrowsError(try msbAggregateThroughput([
            MSBAggregateThroughputInput(
                decodedTokens: Int.max,
                decodeStartedAt: base,
                decodeEndedAt: base.addingTimeInterval(1)
            ),
            MSBAggregateThroughputInput(
                decodedTokens: 1,
                decodeStartedAt: base,
                decodeEndedAt: base.addingTimeInterval(1)
            ),
        ])) { error in
            XCTAssertEqual(error as? MSBAggregateThroughputError, .tokenCountOverflow)
        }
    }
}
