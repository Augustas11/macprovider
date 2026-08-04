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
