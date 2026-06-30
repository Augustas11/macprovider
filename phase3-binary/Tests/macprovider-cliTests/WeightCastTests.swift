import XCTest
@testable import macprovider_cli

final class WeightCastTests: XCTestCase {
    func testEnvFlagAcceptsCommonTruthyForms() {
        XCTAssertTrue(WeightCast.isEnabledByEnvironment(["MACPROVIDER_BF16_WEIGHTS": "1"]))
        XCTAssertTrue(WeightCast.isEnabledByEnvironment(["MACPROVIDER_BF16_WEIGHTS": "true"]))
        XCTAssertTrue(WeightCast.isEnabledByEnvironment(["MACPROVIDER_BF16_WEIGHTS": "TRUE"]))
        XCTAssertTrue(WeightCast.isEnabledByEnvironment(["MACPROVIDER_BF16_WEIGHTS": "yes"]))
        XCTAssertTrue(WeightCast.isEnabledByEnvironment(["MACPROVIDER_BF16_WEIGHTS": " 1 "]))
    }

    func testEnvFlagRejectsOffAndUnsetForms() {
        XCTAssertFalse(WeightCast.isEnabledByEnvironment([:]))
        XCTAssertFalse(WeightCast.isEnabledByEnvironment(["MACPROVIDER_BF16_WEIGHTS": "0"]))
        XCTAssertFalse(WeightCast.isEnabledByEnvironment(["MACPROVIDER_BF16_WEIGHTS": "false"]))
        XCTAssertFalse(WeightCast.isEnabledByEnvironment(["MACPROVIDER_BF16_WEIGHTS": ""]))
        XCTAssertFalse(WeightCast.isEnabledByEnvironment(["MACPROVIDER_BF16_WEIGHTS": "maybe"]))
    }

    // Live `applyIfEnabled` exercise is deferred to a Mac with a real loaded
    // model — wiring a mock LanguageModel here would add maintenance cost
    // without buying confidence in the cast itself. The env-flag short-circuit
    // is covered above; the cast call site is covered by the integration run
    // documented in `audits/2026-06-30/perf-mlx-engine.md`.
}

final class CompiledDecodeFlagTests: XCTestCase {
    func testEnvFlagAcceptsCommonTruthyForms() {
        XCTAssertTrue(CompiledDecode.isEnabledByEnvironment(["MACPROVIDER_COMPILED_DECODE": "1"]))
        XCTAssertTrue(CompiledDecode.isEnabledByEnvironment(["MACPROVIDER_COMPILED_DECODE": "yes"]))
    }

    func testEnvFlagDefaultsOff() {
        XCTAssertFalse(CompiledDecode.isEnabledByEnvironment([:]))
        XCTAssertFalse(CompiledDecode.isEnabledByEnvironment(["MACPROVIDER_COMPILED_DECODE": "0"]))
    }
}

final class DecodeBenchHelperTests: XCTestCase {
    func testPercentileP50OnThreeRunsReturnsMiddle() {
        XCTAssertEqual(percentileTPS([10.0, 30.0, 20.0], p: 0.5), 20.0)
    }

    func testPercentileP50OnEmptyReturnsZero() {
        XCTAssertEqual(percentileTPS([], p: 0.5), 0.0)
    }

    func testPercentileP100OnFourRunsReturnsMax() {
        XCTAssertEqual(percentileTPS([1.0, 2.0, 3.0, 4.0], p: 1.0), 4.0)
    }

    func testPinTagMatchesPackageSwiftPin() {
        XCTAssertEqual(mlxSwiftExamplesPinTag(), "mlxsx-2.29.1")
    }

    func testSanitizeFilenameComponentRejectsPathTraversal() {
        XCTAssertEqual(sanitizeFilenameComponent("../etc/passwd"), "etc_passwd")
        XCTAssertEqual(sanitizeFilenameComponent("..\\windows"), "windows")
        XCTAssertEqual(sanitizeFilenameComponent("a/b/c"), "a_b_c")
    }

    func testSanitizeFilenameComponentKeepsSafeChars() {
        XCTAssertEqual(sanitizeFilenameComponent("baseline"), "baseline")
        XCTAssertEqual(sanitizeFilenameComponent("Qwen2.5-32B-Instruct-4bit"), "Qwen2.5-32B-Instruct-4bit")
        XCTAssertEqual(sanitizeFilenameComponent("bf16_on"), "bf16_on")
    }

    func testSanitizeFilenameComponentHandlesEdgeCases() {
        XCTAssertEqual(sanitizeFilenameComponent(""), "unlabeled")
        XCTAssertEqual(sanitizeFilenameComponent("///"), "unlabeled")
        XCTAssertEqual(sanitizeFilenameComponent("..."), "unlabeled")
        // 100-char input gets capped to 80.
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(sanitizeFilenameComponent(long).count, 80)
    }
}
