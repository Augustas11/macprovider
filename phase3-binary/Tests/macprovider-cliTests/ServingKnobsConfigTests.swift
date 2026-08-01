import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

// SPEC-013 autoresearch serving knobs: covers --kv-bits / --max-context
// / --max-batch end-to-end — config resolution (CLI > env > YAML),
// defaults preserved when omitted, preflight rejects invalid values,
// runtime threading reaches the actor, and the existing
// context_length_exceeded gate honors the new override.

final class ServingKnobsConfigTests: XCTestCase {
    // MARK: - Defaults preserved

    func testDefaultsUnchangedWhenAllKnobsOmitted() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in false },
            readFile: { _ in "" }
        )
        XCTAssertNil(config.kvBitsOverride)
        XCTAssertNil(config.maxContextOverride)
        XCTAssertNil(config.maxConcurrencyOverride)
        XCTAssertFalse(config.enableReceipts)
    }

    func testEnableReceiptsCLIOverridesEnvironmentOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(enableReceipts: false),
            environment: ["MACPROVIDER_ENABLE_RECEIPTS": "true"],
            fileExists: { _ in true },
            readFile: { _ in "enable_receipts: true\n" }
        )
        XCTAssertFalse(config.enableReceipts)
    }

    func testEnableReceiptsEnvironmentOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_ENABLE_RECEIPTS": "true"],
            fileExists: { _ in true },
            readFile: { _ in "enable_receipts: false\n" }
        )
        XCTAssertTrue(config.enableReceipts)
    }

    func testEnableReceiptsYAMLApplied() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "enable_receipts: true\n" }
        )
        XCTAssertTrue(config.enableReceipts)
    }

    // MARK: - --kv-bits

    func testKvBitsCLIOverridesEnvironmentOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(kvBits: 8),
            environment: ["MACPROVIDER_KV_BITS": "4"],
            fileExists: { _ in true },
            readFile: { _ in "kv_bits: 4\n" }
        )
        XCTAssertEqual(config.kvBitsOverride, 8)
    }

    func testKvBitsEnvironmentOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_KV_BITS": "4"],
            fileExists: { _ in true },
            readFile: { _ in "kv_bits: 8\n" }
        )
        XCTAssertEqual(config.kvBitsOverride, 4)
    }

    func testKvBitsYAMLApplied() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "kv_bits: 4\n" }
        )
        XCTAssertEqual(config.kvBitsOverride, 4)
    }

    // MARK: - --max-context

    func testMaxContextCLIOverridesEnvironmentOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(maxContext: 8192),
            environment: ["MACPROVIDER_MAX_CONTEXT_OVERRIDE": "16384"],
            fileExists: { _ in true },
            readFile: { _ in "max_context_override: 4096\n" }
        )
        XCTAssertEqual(config.maxContextOverride, 8192)
    }

    func testMaxContextYAMLApplied() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "max_context_override: 4096\n" }
        )
        XCTAssertEqual(config.maxContextOverride, 4096)
    }

    // MARK: - --max-batch

    func testMaxBatchCLIOverridesEnvironmentOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(maxBatch: 4),
            environment: ["MACPROVIDER_MAX_CONCURRENCY_OVERRIDE": "2"],
            fileExists: { _ in true },
            readFile: { _ in "max_concurrency_override: 1\n" }
        )
        XCTAssertEqual(config.maxConcurrencyOverride, 4)
    }

    func testMaxBatchYAMLApplied() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "max_concurrency_override: 2\n" }
        )
        XCTAssertEqual(config.maxConcurrencyOverride, 2)
    }

    // MARK: - Preflight validation

    func testKvBitsPreflightRejectsInvalidValue() throws {
        var config = AppConfig.defaults()
        config.kvBitsOverride = 5
        XCTAssertThrowsError(try ServeCommand.runServingKnobsPreflight(config))
    }

    func testKvBitsPreflightAcceptsFour() throws {
        var config = AppConfig.defaults()
        config.kvBitsOverride = 4
        XCTAssertNoThrow(try ServeCommand.runServingKnobsPreflight(config))
    }

    func testKvBitsPreflightAcceptsEight() throws {
        var config = AppConfig.defaults()
        config.kvBitsOverride = 8
        XCTAssertNoThrow(try ServeCommand.runServingKnobsPreflight(config))
    }

    func testKvBitsPreflightAcceptsNil() throws {
        let config = AppConfig.defaults()
        XCTAssertNoThrow(try ServeCommand.runServingKnobsPreflight(config))
    }

    func testMaxContextPreflightRejectsZero() throws {
        var config = AppConfig.defaults()
        config.maxContextOverride = 0
        XCTAssertThrowsError(try ServeCommand.runServingKnobsPreflight(config))
    }

    func testMaxBatchPreflightRejectsZero() throws {
        var config = AppConfig.defaults()
        config.maxConcurrencyOverride = 0
        XCTAssertThrowsError(try ServeCommand.runServingKnobsPreflight(config))
    }

    func testMaxBatchPreflightRejectsAboveThreadLimit() throws {
        var config = AppConfig.defaults()
        config.maxConcurrencyOverride = ProviderCapacity.maxConcurrencyOverrideLimit + 1
        XCTAssertThrowsError(try ServeCommand.runServingKnobsPreflight(config))
    }

    // MARK: - Runtime threading

    func testRuntimeReceivesKvBitsOverride() async throws {
        let runtime = ModelRuntime(
            modelID: "test-model",
            kvBitsOverride: 4,
            warmSwapEnabled: false,
            loader: { _ in throw TestRuntimeError.notExpected }
        )
        let observed = await runtime.kvBitsOverrideForTest()
        XCTAssertEqual(observed, 4)
    }

    func testRuntimeDefaultKvBitsIsNil() async throws {
        let runtime = ModelRuntime(
            modelID: "test-model",
            warmSwapEnabled: false,
            loader: { _ in throw TestRuntimeError.notExpected }
        )
        let observed = await runtime.kvBitsOverrideForTest()
        XCTAssertNil(observed)
    }

    func testRuntimeReceivesMaxBatch() async throws {
        let runtime = ModelRuntime(
            modelID: "test-model",
            maxBatch: 3,
            warmSwapEnabled: false,
            loader: { _ in throw TestRuntimeError.notExpected }
        )
        let observed = await runtime.maxBatchForTest()
        XCTAssertEqual(observed, 3)
    }

    func testRuntimeCapsMaxBatchAtThreadLimit() async throws {
        let runtime = ModelRuntime(
            modelID: "test-model",
            maxBatch: ProviderCapacity.maxConcurrencyOverrideLimit + 100,
            warmSwapEnabled: false,
            loader: { _ in throw TestRuntimeError.notExpected }
        )
        let observed = await runtime.maxBatchForTest()
        XCTAssertEqual(observed, ProviderCapacity.maxConcurrencyOverrideLimit)
    }

    func testRuntimeDefaultMaxBatchIsOne() async throws {
        let runtime = ModelRuntime(
            modelID: "test-model",
            warmSwapEnabled: false,
            loader: { _ in throw TestRuntimeError.notExpected }
        )
        let observed = await runtime.maxBatchForTest()
        XCTAssertEqual(observed, 1)
    }

    func testRuntimeReceivesMaxContext() async throws {
        let runtime = ModelRuntime(
            modelID: "test-model",
            maxContextTokensOverride: 4096,
            warmSwapEnabled: false,
            loader: { _ in throw TestRuntimeError.notExpected }
        )
        let observed = await runtime.maxContextTokensForTest()
        XCTAssertEqual(observed, 4096)
    }

    // MARK: - --max-context gates prompts at the documented boundary

    func testValidatePromptTokenCountRejectsOversize() throws {
        XCTAssertThrowsError(try ModelRuntime.validatePromptTokenCount(4097, maxContextTokens: 4096)) { error in
            guard let apiError = error as? APIError else {
                XCTFail("expected APIError, got \(error)")
                return
            }
            XCTAssertEqual(apiError.status, 413)
            XCTAssertEqual(apiError.code, "context_length_exceeded")
            XCTAssertEqual(apiError.type, "context_length_exceeded")
        }
    }

    func testValidatePromptTokenCountAcceptsAtBoundary() throws {
        XCTAssertNoThrow(try ModelRuntime.validatePromptTokenCount(4096, maxContextTokens: 4096))
    }
}

private enum TestRuntimeError: Error {
    case notExpected
}
