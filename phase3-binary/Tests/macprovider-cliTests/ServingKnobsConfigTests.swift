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
        XCTAssertEqual(config.continuousBatching, .off)
        XCTAssertNil(config.continuousBatchQueueLimit)
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

    // MARK: - continuous batching controls

    func testContinuousBatchingCLIOverridesEnvironmentOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(continuousBatching: "on", continuousBatchQueueLimit: 7),
            environment: [
                "MACPROVIDER_CONTINUOUS_BATCHING": "canary",
                "MACPROVIDER_CONTINUOUS_BATCH_QUEUE_LIMIT": "5",
            ],
            fileExists: { _ in true },
            readFile: { _ in "continuous_batching: off\ncontinuous_batch_queue_limit: 3\n" }
        )
        XCTAssertEqual(config.continuousBatching, .on)
        XCTAssertEqual(config.continuousBatchQueueLimit, 7)
    }

    func testContinuousBatchingEnvironmentOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [
                "MACPROVIDER_CONTINUOUS_BATCHING": "canary",
                "MACPROVIDER_CONTINUOUS_BATCH_QUEUE_LIMIT": "6",
            ],
            fileExists: { _ in true },
            readFile: { _ in "continuous_batching: off\ncontinuous_batch_queue_limit: 2\n" }
        )
        XCTAssertEqual(config.continuousBatching, .canary)
        XCTAssertEqual(config.continuousBatchQueueLimit, 6)
    }

    func testContinuousBatchingYAMLApplied() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "continuous_batching: canary\ncontinuous_batch_queue_limit: 4\n" }
        )
        XCTAssertEqual(config.continuousBatching, .canary)
        XCTAssertEqual(config.continuousBatchQueueLimit, 4)
    }

    func testContinuousBatchingRejectsInvalidMode() throws {
        XCTAssertThrowsError(try ConfigLoader.load(
            cli: CLIOverrides(continuousBatching: "maybe"),
            environment: [:],
            fileExists: { _ in false },
            readFile: { _ in "" }
        ))
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

    func testContinuousBatchQueueLimitPreflightRejectsZero() throws {
        var config = AppConfig.defaults()
        config.continuousBatchQueueLimit = 0
        XCTAssertThrowsError(try ServeCommand.runServingKnobsPreflight(config))
    }

    func testContinuousBatchingStrictOnFailsUntilUpstreamBatchAPIPinned() throws {
        var config = AppConfig.defaults()
        config.continuousBatching = .on
        config.maxConcurrencyOverride = 2
        XCTAssertThrowsError(try ServeCommand.runContinuousBatchingPreflight(config))
    }

    func testContinuousBatchingCanarySerialRoutesUnsupportedPin() throws {
        var config = AppConfig.defaults()
        config.continuousBatching = .canary
        config.maxConcurrencyOverride = 2
        XCTAssertNoThrow(try ServeCommand.runContinuousBatchingPreflight(config))
    }

    func testContinuousBatchingPolicyReportsKvBitsBeforeMissingPin() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: 4,
            draftConfigured: false
        )
        XCTAssertEqual(capability.queueLimit, 4)
        XCTAssertEqual(capability.unsupportedReason, .kvBitsUnsupported)
    }

    func testContinuousBatchingPolicyReportsDraftMutualExclusion() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: 9,
            kvBits: nil,
            draftConfigured: true
        )
        XCTAssertEqual(capability.queueLimit, 9)
        XCTAssertEqual(capability.unsupportedReason, .draftSpecDecodeMutualExclusion)
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

    func testRuntimeReceivesContinuousBatchingControls() async throws {
        let runtime = ModelRuntime(
            modelID: "test-model",
            maxBatch: 3,
            continuousBatchingMode: .canary,
            continuousBatchQueueLimit: 5,
            warmSwapEnabled: false,
            loader: { _ in throw TestRuntimeError.notExpected }
        )
        let observed = await runtime.continuousBatchingCapabilityForTest()
        XCTAssertEqual(observed.mode, .canary)
        XCTAssertEqual(observed.maxActiveRows, 3)
        XCTAssertEqual(observed.queueLimit, 5)
        XCTAssertEqual(observed.unsupportedReason, .upstreamBatchAPIUnpinned)
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
