import ArgumentParser
import Foundation
@testable import MacProviderCore
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
        XCTAssertFalse(config.pagedKV.enabled)
        XCTAssertFalse(config.pagedKV.effectiveEnabled)
        XCTAssertNil(config.modelArtifactRoot)
    }

    func testModelArtifactRootYAMLAndEnvironment() throws {
        let yaml = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "model_artifact_root: /tmp/macprovider-models\n" }
        )
        XCTAssertEqual(yaml.modelArtifactRoot, "/tmp/macprovider-models")

        let env = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_MODEL_ARTIFACT_ROOT": "/tmp/env-models"],
            fileExists: { _ in true },
            readFile: { _ in "model_artifact_root: /tmp/macprovider-models\n" }
        )
        XCTAssertEqual(env.modelArtifactRoot, "/tmp/env-models")
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

    // MARK: - SPEC-039 paged_kv

    func testPagedKVCLIOverridesEnvironmentOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(pagedKV: PagedKVCLIOverrides(
                maxPhysicalBlocks: 64,
                fallbackPolicy: "strict"
            )),
            environment: [
                "MACPROVIDER_PAGED_KV_ENABLED": "true",
                "MACPROVIDER_PAGED_KV_BLOCK_SIZE_TOKENS": "16",
                "MACPROVIDER_PAGED_KV_MAX_PHYSICAL_BLOCKS": "32",
                "MACPROVIDER_PAGED_KV_FALLBACK_POLICY": "permissive",
            ],
            fileExists: { _ in true },
            readFile: { _ in """
            paged_kv:
              enabled: false
              block_size_tokens: 8
              max_physical_blocks: 12
              fallback_policy: permissive
            """ }
        )
        XCTAssertTrue(config.pagedKV.enabled)
        XCTAssertEqual(config.pagedKV.blockSizeTokens, 16)
        XCTAssertEqual(config.pagedKV.maxPhysicalBlocks, 64)
        XCTAssertEqual(config.pagedKV.fallbackPolicy, .strict)
        XCTAssertTrue(config.pagedKV.errors.isEmpty)
    }

    func testPagedKVInvalidConfigDisablesInsteadOfThrowing() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_PAGED_KV_ENABLED": "true"],
            fileExists: { _ in true },
            readFile: { _ in """
            paged_kv:
              block_size_tokens: 0
            """ }
        )
        XCTAssertFalse(config.pagedKV.enabled)
        XCTAssertFalse(config.pagedKV.effectiveEnabled)
        XCTAssertEqual(config.pagedKV.errors.count, 1)
    }

    func testPagedKVInvalidTopLevelShapeDisablesWithoutHigherPrecedenceSource() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "paged_kv: true\n" }
        )
        XCTAssertFalse(config.pagedKV.enabled)
        XCTAssertFalse(config.pagedKV.effectiveEnabled)
        XCTAssertEqual(config.pagedKV.errors.count, 1)
    }

    func testPagedKVInvalidTopLevelShapeAlwaysDisablesEvenWithEnvironmentOrCLI() throws {
        // A malformed `paged_kv:` block (scalar/list where a map is required) is a config
        // SHAPE error: it must never be silently dropped. It always surfaces the warning and
        // fails closed (paged disabled), regardless of any env or CLI enable override.
        let envConfig = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_PAGED_KV_ENABLED": "true"],
            fileExists: { _ in true },
            readFile: { _ in "paged_kv: true\n" }
        )
        XCTAssertFalse(envConfig.pagedKV.enabled)
        XCTAssertFalse(envConfig.pagedKV.effectiveEnabled)
        XCTAssertEqual(envConfig.pagedKV.errors.count, 1)

        let cliConfig = try ConfigLoader.load(
            cli: CLIOverrides(pagedKV: PagedKVCLIOverrides(enabled: true)),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "paged_kv: true\n" }
        )
        XCTAssertFalse(cliConfig.pagedKV.enabled)
        XCTAssertFalse(cliConfig.pagedKV.effectiveEnabled)
        XCTAssertEqual(cliConfig.pagedKV.errors.count, 1)
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

    // SPEC-038 AC-25 bounded admission wait. Same triple source as the queue
    // limit: CLI over env over YAML, absent ⇒ the scheduler's 30s default.
    func testContinuousBatchQueueWaitTimeoutCLIOverridesEnvironmentOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(continuousBatchQueueWaitTimeoutMS: 9_000),
            environment: ["MACPROVIDER_CONTINUOUS_BATCH_QUEUE_WAIT_TIMEOUT_MS": "5000"],
            fileExists: { _ in true },
            readFile: { _ in "continuous_batch_queue_wait_timeout_ms: 3000\n" }
        )
        XCTAssertEqual(config.continuousBatchQueueWaitTimeoutMS, 9_000)
    }

    func testMLXCacheLimitReadsYAMLAndEnvironmentOverridesIt() throws {
        let fromYAML = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "mlx_cache_limit_mb: 4096\n" }
        )
        XCTAssertEqual(fromYAML.mlxCacheLimitMB, 4096)
        let fromEnvironment = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_MLX_CACHE_LIMIT_MB": "0"],
            fileExists: { _ in true },
            readFile: { _ in "mlx_cache_limit_mb: 4096\n" }
        )
        XCTAssertEqual(fromEnvironment.mlxCacheLimitMB, 0, "0 is valid: it disables the MLX cache")
        let unset = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "" }
        )
        XCTAssertNil(unset.mlxCacheLimitMB, "unset keeps MLX's own default")
    }

    func testApplyMLXCacheLimitIgnoresUnsetOrOutOfRange() {
        XCTAssertNil(ModelRuntime.applyMLXCacheLimit(megabytes: nil))
        XCTAssertNil(ModelRuntime.applyMLXCacheLimit(megabytes: -1))
        XCTAssertNil(ModelRuntime.applyMLXCacheLimit(megabytes: Int.max), "an overflowing value must not be converted")
    }

    func testMLXCacheLimitPreflightRejectsOutOfRangeWhateverTheBatchingMode() throws {
        for mode in [ContinuousBatchingMode.off, .canary] {
            var config = AppConfig.defaults()
            config.continuousBatching = mode
            for invalid in [-1, ModelRuntime.maximumMLXCacheLimitMB + 1, Int.max] {
                config.mlxCacheLimitMB = invalid
                XCTAssertThrowsError(try ServeCommand.runServingKnobsPreflight(config), "mode=\(mode) value=\(invalid)")
            }
            for valid in [0, 2048, ModelRuntime.maximumMLXCacheLimitMB] {
                config.mlxCacheLimitMB = valid
                XCTAssertNoThrow(try ServeCommand.runServingKnobsPreflight(config), "mode=\(mode) value=\(valid)")
            }
        }
    }

    func testApplyMLXCacheLimitConvertsMegabytes() throws {
        // Setting the limit initializes the Metal device.
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        XCTAssertEqual(ModelRuntime.applyMLXCacheLimit(megabytes: 2), 2 * 1024 * 1024)
    }

    func testContinuousBatchQueueWaitTimeoutEnvironmentOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_CONTINUOUS_BATCH_QUEUE_WAIT_TIMEOUT_MS": "5000"],
            fileExists: { _ in true },
            readFile: { _ in "continuous_batch_queue_wait_timeout_ms: 3000\n" }
        )
        XCTAssertEqual(config.continuousBatchQueueWaitTimeoutMS, 5_000)
    }

    func testContinuousBatchQueueWaitTimeoutYAMLAppliedAndDefaultsToUnset() throws {
        let yaml = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "continuous_batch_queue_wait_timeout_ms: 3000\n" }
        )
        XCTAssertEqual(yaml.continuousBatchQueueWaitTimeoutMS, 3_000)
        XCTAssertNil(AppConfig.defaults().continuousBatchQueueWaitTimeoutMS)
    }

    func testContinuousBatchQueueWaitTimeoutPreflightRejectsOutOfRangeWhateverTheBatchingMode() throws {
        let maximum = ContinuousBatchSchedulerConfiguration.maximumQueueWaitTimeoutMS
        for mode in [ContinuousBatchingMode.off, .canary] {
            var config = AppConfig.defaults()
            config.continuousBatching = mode
            for invalid in [0, -1, maximum + 1, Int.max] {
                config.continuousBatchQueueWaitTimeoutMS = invalid
                XCTAssertThrowsError(try ServeCommand.runServingKnobsPreflight(config), "mode=\(mode) value=\(invalid)")
            }
            for valid in [1, 600_000, maximum] {
                config.continuousBatchQueueWaitTimeoutMS = valid
                XCTAssertNoThrow(try ServeCommand.runServingKnobsPreflight(config), "mode=\(mode) value=\(valid)")
            }
        }
    }

    func testContinuousBatchingPlainYAMLOnAndOffPreserveRawThreeStateMode() throws {
        for (raw, expected) in [("on", ContinuousBatchingMode.on), ("off", .off)] {
            let config = try ConfigLoader.load(
                cli: CLIOverrides(),
                environment: [:],
                fileExists: { _ in true },
                readFile: { _ in "continuous_batching: \(raw)\n" }
            )
            XCTAssertEqual(config.continuousBatching, expected)
        }
    }

    func testContinuousBatchingRejectsInvalidMode() throws {
        XCTAssertThrowsError(try ConfigLoader.load(
            cli: CLIOverrides(continuousBatching: "maybe"),
            environment: [:],
            fileExists: { _ in false },
            readFile: { _ in "" }
        ))
    }

    func testContinuousBatchingRejectsInvalidModeFromEnvironment() throws {
        XCTAssertThrowsError(try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_CONTINUOUS_BATCHING": "maybe"],
            fileExists: { _ in false },
            readFile: { _ in "" }
        ))
    }

    func testContinuousBatchingRejectsInvalidModeFromYAML() throws {
        XCTAssertThrowsError(try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "continuous_batching: maybe\n" }
        ))
    }

    func testContinuousBatchingRejectsBooleanYAMLMode() throws {
        XCTAssertThrowsError(try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "continuous_batching: true\n" }
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

    func testPagedKVStrictModeRejectsAtServeStartupWhileRuntimeProofUnavailable() throws {
        var config = AppConfig.defaults()
        config.pagedKV = PagedKVConfig(enabled: true, fallbackPolicy: .strict)
        XCTAssertTrue(ServeCommand.pagedKVStrictStartupRejectEvent.contains("reason=paged_preflight_reject"))
        XCTAssertThrowsError(try ServeCommand.runServingKnobsPreflight(config)) { error in
            XCTAssertEqual(error as? ExitCode, ExitCode(2))
        }
    }

    func testPagedKVModelCapabilitiesDetectMoEFromConfigAndExpertIDPattern() {
        let config = Data("""
        {"model_type":"qwen3","architectures":["Qwen3ForCausalLM"],"num_experts":128}
        """.utf8)
        let metadata = ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/Qwen-Expert-Test",
            configJSONData: config
        )
        XCTAssertEqual(metadata.modelFamily, "qwen")
        XCTAssertTrue(metadata.requiresMoEDispatch)

        let patternFallback = ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            configJSONData: Data("{}".utf8)
        )
        XCTAssertTrue(patternFallback.requiresMoEDispatch)

        let dense = ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/Qwen3-8B-4bit",
            configJSONData: Data(#"{"model_type":"qwen3"}"#.utf8)
        )
        XCTAssertFalse(dense.requiresMoEDispatch)
    }

    func testPagedKVModelCapabilitiesDeriveAdmittedGPTOSSFamilyFromConfig() {
        let gptOSS = ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/gpt-oss-20b-MXFP4-Q8",
            configJSONData: Data("""
            {
              "model_type": "gpt_oss",
              "architectures": ["GptOssForCausalLM"],
              "num_local_experts": 32,
              "num_experts_per_tok": 4
            }
            """.utf8)
        )
        XCTAssertEqual(gptOSS.modelFamily, "gpt_oss")
        XCTAssertTrue(gptOSS.requiresMoEDispatch)

        let gemma4 = ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/gemma-4-26b-a4b-it-4bit",
            configJSONData: Data(#"{"model_type":"gemma4","architectures":["Gemma4ForConditionalGeneration"]}"#.utf8)
        )
        XCTAssertEqual(gemma4.modelFamily, "gemma4")
        XCTAssertFalse(PagedKVAttachGate.recognizedModelFamilies.contains(gemma4.modelFamily))

        let invalidJSONDoesNotFallBackToModelID = ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/Qwen3-8B-4bit",
            configJSONData: Data(#"{"model_type": Infinity}"#.utf8)
        )
        XCTAssertEqual(invalidJSONDoesNotFallBackToModelID.modelFamily, "unknown")
        XCTAssertFalse(PagedKVAttachGate.recognizedModelFamilies.contains(invalidJSONDoesNotFallBackToModelID.modelFamily))

        let unknownConfigDoesNotFallBackToModelID = ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            configJSONData: Data(#"{"model_type":"surprise","architectures":["SurpriseForCausalLM"]}"#.utf8)
        )
        XCTAssertEqual(unknownConfigDoesNotFallBackToModelID.modelFamily, "unknown")
        XCTAssertFalse(PagedKVAttachGate.recognizedModelFamilies.contains(unknownConfigDoesNotFallBackToModelID.modelFamily))
    }

    func testPagedKVAttachedDecisionPassesPreflightWhenRuntimeBridgeOwnsRequestReservation() throws {
        let proof = PagedKVHardwareSizingProof(
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelFamily: "qwen",
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            blockSizeTokens: 32,
            maxPhysicalBlocks: 64,
            maxResidentTokens: 2048,
            parityLabel: "sdpa-parity-v1"
        )
        let observedIdentity = PagedKVObservedRuntimeIdentity(
            hardwareClass: proof.hardwareClass,
            metallibSHA256: proof.metallibSHA256,
            kernelIdentifier: proof.kernelIdentifier,
            parityLabel: proof.parityLabel,
            moeDispatchProven: false,
            poolEpoch: proof.poolEpoch,
            source: .runtimeMeasurement
        )
        let decision = PagedKVAttachGate.decide(
            config: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            runtimeCacheClass: "KVCacheSimple",
            kvBits: nil,
            modelID: proof.modelID,
            modelSHA256: proof.modelSHA256,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelFamily: "qwen",
            requiresMoEDispatch: false,
            gates: PagedKVGates(
                identityAvailable: true,
                observedHardwareClass: proof.hardwareClass,
                metallibAvailable: true,
                kernelRegistered: true,
                parityEstablished: true,
                hardwareSizingProof: proof,
                observedMetallibSHA256: proof.metallibSHA256,
                observedKernelIdentifier: proof.kernelIdentifier,
                observedParityLabel: proof.parityLabel,
                engineBridgeAvailable: true,
                observedRuntimeIdentity: observedIdentity
            )
        )
        XCTAssertNotNil(decision.descriptor)
        XCTAssertNoThrow(try ModelRuntime.enforcePagedKVPreflight(decision))
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

    func testContinuousBatchQueueLimitPreflightRejectsZero() throws {
        var config = AppConfig.defaults()
        config.continuousBatching = .canary
        config.continuousBatchQueueLimit = 0
        XCTAssertThrowsError(try ServeCommand.runServingKnobsPreflight(config))
    }

    func testContinuousBatchQueueLimitPreflightRejectsExcessiveQueue() throws {
        var config = AppConfig.defaults()
        config.continuousBatching = .canary
        config.maxConcurrencyOverride = 2
        config.continuousBatchQueueLimit = 17
        XCTAssertThrowsError(try ServeCommand.runServingKnobsPreflight(config))
    }

    func testContinuousBatchQueueLimitIsInertWhenContinuousBatchingIsOff() throws {
        var config = AppConfig.defaults()
        config.continuousBatching = .off
        config.maxConcurrencyOverride = 2
        config.continuousBatchQueueLimit = 0
        XCTAssertNoThrow(try ServeCommand.runServingKnobsPreflight(config))

        config.continuousBatchQueueLimit = 17
        XCTAssertNoThrow(try ServeCommand.runServingKnobsPreflight(config))
    }

    func testContinuousBatchingPolicyBoundsConfiguredQueueToActiveRows() {
        XCTAssertEqual(
            ContinuousBatchingPolicy.queueLimit(configured: Int.max, maxActiveRows: 2),
            16
        )
    }

    func testContinuousBatchingStrictOnRejectsBeforeProviderReadinessWithoutRuntimeBridge() throws {
        var config = AppConfig.defaults()
        config.continuousBatching = .on
        config.maxConcurrencyOverride = 2
        XCTAssertThrowsError(try ServeCommand.runContinuousBatchingPreflight(config))
    }

    // Lock the fail-closed strict-mode error contract (status + code), not just
    // that it throws — a future regression could keep "throws" while silently
    // changing the client-visible status or reason code.
    func testValidateStrictStartupErrorContract() throws {
        func assertStrictError(
            kvBits: Int?,
            draftConfigured: Bool,
            expectedStatus: Int,
            expectedCode: String,
            line: UInt = #line
        ) {
            let capability = ContinuousBatchingPolicy.capability(
                mode: .on,
                maxBatch: 2,
                queueLimit: nil,
                kvBits: kvBits,
                draftConfigured: draftConfigured,
                schedulerBackendAvailable: false,
                pagedKVDecision: .disabled,
                requestedTuple: nil,
                acceptanceCoverage: .unrestrictedForTests
            )
            XCTAssertThrowsError(
                try ContinuousBatchingPolicy.validateStrictStartup(capability),
                line: line
            ) { error in
                guard let apiError = error as? APIError else {
                    return XCTFail("expected APIError, got \(error)", line: line)
                }
                XCTAssertEqual(apiError.status, expectedStatus, line: line)
                XCTAssertEqual(apiError.code, expectedCode, line: line)
                XCTAssertFalse(apiError.message.isEmpty, line: line)
            }
        }

        // Missing local engine capability => fail closed before inference.
        assertStrictError(
            kvBits: nil,
            draftConfigured: false,
            expectedStatus: 503,
            expectedCode: "continuous_batching_local_capability_unavailable"
        )
        // kv_bits requested => 400 continuous_batching_unsupported_kv_bits.
        assertStrictError(
            kvBits: 4,
            draftConfigured: false,
            expectedStatus: 400,
            expectedCode: "continuous_batching_unsupported_kv_bits"
        )
        // Draft model requested => 400 draft_model_capacity_shortfall (draft takes precedence).
        assertStrictError(
            kvBits: nil,
            draftConfigured: true,
            expectedStatus: 400,
            expectedCode: "draft_model_capacity_shortfall"
        )
    }

    // Off mode is inert: strict validation never throws regardless of otherwise-
    // unsupported inputs (FR-CB9 flag-off parity).
    func testValidateStrictStartupOffModeIsInert() throws {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .off,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: 4,
            draftConfigured: true,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil,
            acceptanceCoverage: .unrestrictedForTests
        )
        XCTAssertNil(capability.unsupportedReason)
        XCTAssertNoThrow(try ContinuousBatchingPolicy.validateStrictStartup(capability))
    }

    func testContinuousBatchingCanaryAllowsRuntimeReasonCodedSerialRouting() throws {
        var config = AppConfig.defaults()
        config.continuousBatching = .canary
        config.maxConcurrencyOverride = 2
        XCTAssertNoThrow(try ServeCommand.runContinuousBatchingPreflight(config))
    }

    func testCanarySerialRoutesCachedHitWithoutRetainedPagedHandoff() {
        XCTAssertTrue(ModelRuntime.canaryShouldSerialRouteCachedHitMissingRetainedHandoff(
            mode: .canary,
            cachedPromptTokens: 32,
            hasRetainedPagedKVHandoff: false
        ))
        XCTAssertTrue(ModelRuntime.canaryShouldSerialRouteCachedHitMissingRetainedHandoff(
            mode: .on,
            cachedPromptTokens: 32,
            hasRetainedPagedKVHandoff: false
        ))
        XCTAssertFalse(ModelRuntime.canaryShouldSerialRouteCachedHitMissingRetainedHandoff(
            mode: .canary,
            cachedPromptTokens: 0,
            hasRetainedPagedKVHandoff: false
        ))
        XCTAssertTrue(ModelRuntime.canaryShouldSerialRouteCachedHitMissingRetainedHandoff(
            mode: .canary,
            cachedPromptTokens: 32,
            hasRetainedPagedKVHandoff: true
        ))
        XCTAssertTrue(ModelRuntime.canaryShouldSerialRouteCachedHitMissingRetainedHandoff(
            mode: .on,
            cachedPromptTokens: 32,
            hasRetainedPagedKVHandoff: true
        ))
        XCTAssertFalse(ModelRuntime.canaryShouldSerialRouteCachedHitMissingRetainedHandoff(
            mode: .off,
            cachedPromptTokens: 32,
            hasRetainedPagedKVHandoff: false
        ))

        let capability = ContinuousBatchingCapability(
            mode: .canary,
            maxActiveRows: 2,
            queueLimit: 4,
            descriptor: nil,
            unsupportedReason: .stickyCacheHandoffUnavailable
        )
        XCTAssertEqual(
            ContinuousBatchingPolicy.serialRouteTelemetryLine(capability),
            "event=batching_unsupported action=serial_routed reason=sticky_cache_handoff_unavailable\n"
        )

        let strictBlocked = ContinuousBatchingCapability(
            mode: .on,
            maxActiveRows: 2,
            queueLimit: 4,
            descriptor: nil,
            unsupportedReason: .stickyCacheHandoffUnavailable
        )
        XCTAssertNil(ContinuousBatchingPolicy.serialRouteTelemetryLine(strictBlocked))
        XCTAssertThrowsError(try ContinuousBatchingPolicy.validateStrictStartup(strictBlocked)) { error in
            guard let api = error as? APIError else {
                XCTFail("expected APIError")
                return
            }
            XCTAssertEqual(api.code, "continuous_batching_paged_kv_handoff_unavailable")
            XCTAssertEqual(api.status, 400)
        }
    }

    func testPrefillFailureTelemetryIsReasonCodedAndDoesNotEchoErrorText() {
        XCTAssertEqual(
            ContinuousBatchingPolicy.prefillFailureTelemetryLine(
                ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
            ),
            "event=batching_prefill_failed action=fail_closed reason=continuous_batching_invalid_cache_layout\n"
        )
        XCTAssertEqual(
            ContinuousBatchingPolicy.prefillFailureReason(PagedKVContiguousCacheBridgeError.blockTableMismatch),
            "paged_kv_block_table_mismatch"
        )
        XCTAssertEqual(
            ContinuousBatchingPolicy.prefillFailureReason(PagedKVContiguousCacheBridgeError.invalidLayerState),
            "paged_kv_invalid_layer_state"
        )
        struct PromptBearingError: Error, LocalizedError {
            var errorDescription: String? { "prompt token dump sk-secret" }
        }
        let line = ContinuousBatchingPolicy.prefillFailureTelemetryLine(PromptBearingError())
        XCTAssertTrue(line.hasPrefix("event=batching_prefill_failed action=fail_closed reason="))
        XCTAssertFalse(line.contains("sk-secret"))
        XCTAssertFalse(line.contains("prompt token dump"))
        let forwardLine = ContinuousBatchingPolicy.forwardFailureTelemetryLine(
            PagedKVContiguousCacheBridgeError.unsupportedDType
        )
        XCTAssertEqual(
            forwardLine,
            "event=batching_forward_failed action=fail_closed reason=paged_kv_unsupported_dtype\n"
        )
        XCTAssertFalse(forwardLine.contains("sk-secret"))
    }

    func testRuntimePolicyAdmitsKeyedFirstTurnWhenSchedulerIsAttached() {
        let canaryCapability = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(Self.pagedKVDescriptor()),
            requestedTuple: Self.continuousBatchingTuple(),
            acceptanceCoverage: .unrestrictedForTests
        )
        XCTAssertNil(canaryCapability.unsupportedReason)
        XCTAssertFalse(canaryCapability.shouldUseSerialPath)
        XCTAssertNil(ContinuousBatchingPolicy.serialRouteTelemetryLine(canaryCapability))

        let strictCapability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(Self.pagedKVDescriptor()),
            requestedTuple: Self.continuousBatchingTuple(),
            acceptanceCoverage: .unrestrictedForTests
        )
        XCTAssertNil(strictCapability.unsupportedReason)
        XCTAssertFalse(strictCapability.shouldUseSerialPath)
        XCTAssertNoThrow(try ContinuousBatchingPolicy.validateStrictStartup(strictCapability))
    }

    func testContinuousBatchingPolicyReportsKvBitsBeforeLocalCapability() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: 4,
            draftConfigured: false,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil,
            acceptanceCoverage: .unrestrictedForTests
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
            draftConfigured: true,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil,
            acceptanceCoverage: .unrestrictedForTests
        )
        XCTAssertEqual(capability.queueLimit, 9)
        XCTAssertEqual(capability.unsupportedReason, .draftSpecDecodeMutualExclusion)
    }

    func testDraftEnabledDepthOneStrictOnUsesExistingSerialPath() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 1,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: true,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil,
            acceptanceCoverage: .unrestrictedForTests
        )

        XCTAssertEqual(capability.unsupportedReason, .draftSpecDecodeMutualExclusion)
        XCTAssertTrue(capability.shouldUseSerialPath)
        XCTAssertNoThrow(try ContinuousBatchingPolicy.validateStrictStartup(capability))
    }

    func testContinuousBatchingActivationIsDescriptorMembership() throws {
        let descriptor = PagedKVDescriptor(
            blockSizeTokens: 16,
            maxPhysicalBlocks: 32,
            modelID: "catalog/model",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: String(repeating: "b", count: 64),
            chatTemplateSHA256: String(repeating: "c", count: 64),
            supportedModelFamilies: ["qwen"],
            supportsMoEDispatch: false,
            hardwareClass: "m4-max-64gb",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged-attention-v1",
            parityLabel: "dense-greedy-parity"
        )
        let exact = ContinuousBatchingRequestedTuple(
            modelID: "catalog/model",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: String(repeating: "b", count: 64),
            chatTemplateSHA256: String(repeating: "c", count: 64),
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: false,
            hardwareClass: "m4-max-64gb",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged-attention-v1",
            parityLabel: "dense-greedy-parity",
            poolEpoch: 1
        )
        let supported = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: exact,
            acceptanceCoverage: Self.acceptanceCoverage(for: exact)
        )
        XCTAssertNil(supported.unsupportedReason)
        XCTAssertFalse(supported.shouldUseSerialPath)

        let mismatch = ContinuousBatchingRequestedTuple(
            modelID: exact.modelID,
            modelSHA256: String(repeating: "e", count: 64),
            tokenizerSHA256: exact.tokenizerSHA256,
            chatTemplateSHA256: exact.chatTemplateSHA256,
            cacheClass: exact.cacheClass,
            kvDType: exact.kvDType,
            requiresMoE: exact.requiresMoE,
            hardwareClass: exact.hardwareClass,
            metallibSHA256: exact.metallibSHA256,
            kernelIdentifier: exact.kernelIdentifier,
            parityLabel: exact.parityLabel,
            poolEpoch: exact.poolEpoch
        )
        let rejected = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: mismatch,
            acceptanceCoverage: Self.acceptanceCoverage(for: exact)
        )
        XCTAssertEqual(rejected.unsupportedReason, .tupleNotAdvertised)
        XCTAssertTrue(rejected.shouldUseSerialPath)
    }

    func testStickyCacheEligibleRequestUsesLocalCapabilityGateAfterFRPKV10() {
        let descriptor = PagedKVDescriptor(
            blockSizeTokens: 16,
            maxPhysicalBlocks: 32,
            modelID: "catalog/model",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: String(repeating: "b", count: 64),
            chatTemplateSHA256: String(repeating: "c", count: 64),
            supportedModelFamilies: ["qwen"],
            supportsMoEDispatch: false,
            hardwareClass: "m4-max-64gb",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged-attention-v1",
            parityLabel: "dense-greedy-parity"
        )
        let tuple = ContinuousBatchingRequestedTuple(
            modelID: descriptor.modelID,
            modelSHA256: descriptor.modelSHA256,
            tokenizerSHA256: descriptor.tokenizerSHA256,
            chatTemplateSHA256: descriptor.chatTemplateSHA256,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: false,
            hardwareClass: "m4-max-64gb",
            metallibSHA256: descriptor.metallibSHA256,
            kernelIdentifier: descriptor.kernelIdentifier,
            parityLabel: descriptor.parityLabel,
            poolEpoch: 1
        )
        let supported = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: tuple,
            acceptanceCoverage: Self.acceptanceCoverage(for: tuple)
        )
        XCTAssertNil(supported.unsupportedReason)
        XCTAssertFalse(supported.shouldUseSerialPath)

        let capability = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil,
            acceptanceCoverage: .unrestrictedForTests
        )
        XCTAssertEqual(capability.unsupportedReason, .pagedKVDisabled)
        XCTAssertTrue(capability.shouldUseSerialPath)
    }

    func testUnrepresentableRequestStateSerialRoutesInCanary() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            requestStateRepresentable: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .disabled,
            requestedTuple: nil,
            acceptanceCoverage: .unrestrictedForTests
        )
        XCTAssertEqual(capability.unsupportedReason, .requestStateUnrepresented)
        XCTAssertTrue(capability.shouldUseSerialPath)
    }

    func testUnrepresentableRequestStateFailsClosedInStrict() {
        // The gate must win even when the backend is available and the tuple
        // would otherwise be admitted: row-local generation state the shared
        // forward cannot represent must never enter a batch.
        let capability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 4,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            requestStateRepresentable: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .disabled,
            requestedTuple: nil,
            acceptanceCoverage: .unrestrictedForTests
        )
        XCTAssertEqual(capability.unsupportedReason, .requestStateUnrepresented)
        XCTAssertThrowsError(try ContinuousBatchingPolicy.validateStrictStartup(capability)) { error in
            guard let apiError = error as? APIError else {
                return XCTFail("expected APIError, got \(error)")
            }
            XCTAssertEqual(apiError.code, "continuous_batching_request_state_unsupported")
            XCTAssertEqual(apiError.status, 400)
        }
    }

    private func parsedRequest(_ body: [String: Any]) throws -> ChatCompletionRequest {
        var dict = body
        dict["model"] = dict["model"] ?? "catalog/model"
        dict["messages"] = dict["messages"] ?? [["role": "user", "content": "hi"]]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try ChatCompletionRequest.parse(data: data)
    }

    func testRequestStateRepresentableGateOnParsedRequests() throws {
        // SPEC-038 AC-6b: sampled rows batch with the serial path's sampler and a
        // row-local seed, so plain sampling parameters no longer force serial.
        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([:])))

        let greedy: [String: Any] = ["temperature": 0, "top_p": 1.0]
        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest(greedy)))
        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "temperature": 0.7, "top_p": 0.9
        ])))
        // The serial path ignores presence/frequency penalties, so they do not
        // change what a batched row must represent.
        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "temperature": 0.7, "presence_penalty": 0.5, "frequency_penalty": 0.5
        ])))

        // Structured output (json_schema) → not representable.
        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "temperature": 0,
            "top_p": 1.0,
            "response_format": ["type": "json_schema",
                                "json_schema": ["name": "s",
                                                "schema": ["type": "object",
                                                           "additionalProperties": false]]]
        ])))

        // Tools present WITHOUT tool_choice → not representable (the HIGH the gate missed).
        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "temperature": 0,
            "top_p": 1.0,
            "tools": [["type": "function",
                       "function": ["name": "f", "parameters": ["type": "object"]]]]
        ])))

        // Explicit JSON null tool_choice, no tools → representable (must NOT false-positive).
        var explicitNullToolChoice = greedy
        explicitNullToolChoice["tool_choice"] = NSNull()
        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest(explicitNullToolChoice)))

        // logit_bias → not representable; logprobs:false → representable.
        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "temperature": 0,
            "top_p": 1.0,
            "logit_bias": ["123": -100]
        ])))
        var logprobsFalse = greedy
        logprobsFalse["logprobs"] = false
        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest(logprobsFalse)))
        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "temperature": 0,
            "top_p": 1.0,
            "logprobs": true
        ])))
        // top_logprobs (response metadata) is rejected too so the gate is provably complete.
        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "temperature": 0,
            "top_p": 1.0,
            "logprobs": true, "top_logprobs": 5
        ])))
    }

    func testRepresentableRequestStateDoesNotTripTheGate() {
        // Default representable=true path must be unaffected by the new gate.
        let capability = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            requestStateRepresentable: true,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil,
            acceptanceCoverage: .unrestrictedForTests
        )
        XCTAssertNotEqual(capability.unsupportedReason, .requestStateUnrepresented)
    }

    func testStableRequestIDGateOnlyTripsWhenSchedulerWouldOtherwiseAttach() {
        let descriptor = Self.pagedKVDescriptor()
        let tuple = Self.continuousBatchingTuple()
        let canary = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            requestHasStableRequestID: false,
            schedulerBackendAvailable: true,
            durableReplayAuthorityAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: tuple,
            acceptanceCoverage: Self.acceptanceCoverage(for: tuple)
        )
        XCTAssertEqual(canary.unsupportedReason, .stableRequestIDUnavailable)
        XCTAssertTrue(canary.shouldUseSerialPath)
        XCTAssertEqual(
            ContinuousBatchingPolicy.serialRouteTelemetryLine(canary),
            "event=batching_unsupported action=serial_routed reason=stable_request_id_unavailable\n"
        )

        let strict = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            requestHasStableRequestID: false,
            schedulerBackendAvailable: true,
            durableReplayAuthorityAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: tuple,
            acceptanceCoverage: Self.acceptanceCoverage(for: tuple)
        )
        XCTAssertEqual(strict.unsupportedReason, .stableRequestIDUnavailable)
        XCTAssertThrowsError(try ContinuousBatchingPolicy.validateStrictStartup(strict)) { error in
            guard let apiError = error as? APIError else {
                return XCTFail("expected APIError, got \(error)")
            }
            XCTAssertEqual(apiError.status, 400)
            XCTAssertEqual(apiError.code, "continuous_batching_request_id_unavailable")
        }

        let missingLocalCapability = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            requestHasStableRequestID: false,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil,
            acceptanceCoverage: .unrestrictedForTests
        )
        XCTAssertEqual(missingLocalCapability.unsupportedReason, .pagedKVDisabled)
    }

    func testMoETupleRemainsUnsupportedWhenPromotionEvidenceIsExplicitlyFalse() {
        let descriptor = PagedKVDescriptor(
            blockSizeTokens: 16,
            maxPhysicalBlocks: 32,
            modelID: "catalog/moe-model",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: String(repeating: "b", count: 64),
            chatTemplateSHA256: String(repeating: "c", count: 64),
            supportedModelFamilies: ["qwen3_moe"],
            supportsMoEDispatch: true,
            hardwareClass: "m4-max-128gb",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged-attention-v1",
            parityLabel: "moe-greedy-parity"
        )
        let tuple = ContinuousBatchingRequestedTuple(
            modelID: descriptor.modelID,
            modelSHA256: descriptor.modelSHA256,
            tokenizerSHA256: descriptor.tokenizerSHA256,
            chatTemplateSHA256: descriptor.chatTemplateSHA256,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: true,
            hardwareClass: "m4-max-128gb",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged-attention-v1",
            parityLabel: "moe-greedy-parity",
            poolEpoch: 1
        )

        let canary = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: tuple,
            acceptanceCoverage: Self.acceptanceCoverage(for: tuple),
            moePromotionEvidenceAvailable: false
        )
        XCTAssertEqual(canary.unsupportedReason, .moePromotionEvidenceUnavailable)
        XCTAssertTrue(canary.shouldUseSerialPath)
        XCTAssertEqual(
            ContinuousBatchingPolicy.serialRouteTelemetryLine(canary),
            "event=batching_unsupported action=serial_routed reason=moe_promotion_evidence_unavailable\n"
        )

        let strict = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: tuple,
            acceptanceCoverage: Self.acceptanceCoverage(for: tuple),
            moePromotionEvidenceAvailable: false
        )
        XCTAssertEqual(strict.unsupportedReason, .moePromotionEvidenceUnavailable)
        XCTAssertFalse(strict.shouldUseSerialPath)
        XCTAssertThrowsError(try ContinuousBatchingPolicy.validateStrictStartup(strict)) { error in
            guard let apiError = error as? APIError else {
                return XCTFail("expected APIError, got \(error)")
            }
            XCTAssertEqual(apiError.status, 400)
            XCTAssertEqual(apiError.code, "continuous_batching_moe_promotion_evidence_unavailable")
        }
    }

    func testProductionMoEPromotionEvidenceOpensDescriptorAdmittedTuple() {
        XCTAssertTrue(ContinuousBatchingPolicy.productionMoEPromotionEvidenceAvailable)
        let descriptor = PagedKVDescriptor(
            blockSizeTokens: 16,
            maxPhysicalBlocks: 32,
            modelID: "catalog/moe-model",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: String(repeating: "b", count: 64),
            chatTemplateSHA256: String(repeating: "c", count: 64),
            supportedModelFamilies: ["qwen3_moe"],
            supportsMoEDispatch: true,
            hardwareClass: "m4-max-128gb",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged-attention-v1",
            parityLabel: "moe-greedy-parity"
        )
        let tuple = ContinuousBatchingRequestedTuple(
            modelID: descriptor.modelID,
            modelSHA256: descriptor.modelSHA256,
            tokenizerSHA256: descriptor.tokenizerSHA256,
            chatTemplateSHA256: descriptor.chatTemplateSHA256,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: true,
            hardwareClass: "m4-max-128gb",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged-attention-v1",
            parityLabel: "moe-greedy-parity",
            poolEpoch: 1
        )

        let canary = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: tuple,
            acceptanceCoverage: Self.acceptanceCoverage(for: tuple)
        )
        XCTAssertNil(canary.unsupportedReason)
        XCTAssertFalse(canary.shouldUseSerialPath)

        let strict = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: tuple,
            acceptanceCoverage: Self.acceptanceCoverage(for: tuple)
        )
        XCTAssertNil(strict.unsupportedReason)
        XCTAssertNoThrow(try ContinuousBatchingPolicy.validateStrictStartup(strict))
    }

    func testDescriptorMembershipAloneDoesNotPromoteMoETuple() {
        let descriptor = PagedKVDescriptor(
            blockSizeTokens: 16,
            maxPhysicalBlocks: 32,
            modelID: "catalog/moe-model",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: String(repeating: "b", count: 64),
            chatTemplateSHA256: String(repeating: "c", count: 64),
            supportedModelFamilies: ["qwen3_moe"],
            supportsMoEDispatch: true,
            hardwareClass: "m4-max-128gb",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged-attention-v1",
            parityLabel: "moe-greedy-parity"
        )
        let tuple = ContinuousBatchingRequestedTuple(
            modelID: descriptor.modelID,
            modelSHA256: String(repeating: "f", count: 64),
            tokenizerSHA256: descriptor.tokenizerSHA256,
            chatTemplateSHA256: descriptor.chatTemplateSHA256,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: true,
            hardwareClass: "m4-max-128gb",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged-attention-v1",
            parityLabel: "moe-greedy-parity",
            poolEpoch: 1
        )

        let canary = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: tuple,
            acceptanceCoverage: Self.acceptanceCoverage(for: tuple)
        )
        XCTAssertEqual(canary.unsupportedReason, .tupleNotAdvertised)
        XCTAssertTrue(canary.shouldUseSerialPath)
    }

    func testStrictOnRejectsStickyRequestWhenPagedKVUnavailable() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil,
            acceptanceCoverage: .unrestrictedForTests
        )
        XCTAssertEqual(capability.unsupportedReason, .pagedKVDisabled)
        XCTAssertFalse(capability.shouldUseSerialPath)
        XCTAssertThrowsError(try ContinuousBatchingPolicy.validateStrictStartup(capability)) { error in
            guard let apiError = error as? APIError else {
                return XCTFail("expected APIError, got \(error)")
            }
            XCTAssertEqual(apiError.status, 503)
            XCTAssertEqual(apiError.code, "continuous_batching_local_capability_unavailable")
        }
        XCTAssertNil(ContinuousBatchingPolicy.serialRouteTelemetryLine(capability))
    }

    func testStrictOnNeverSilentlySerialRoutesMissingLocalCapability() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil,
            acceptanceCoverage: .unrestrictedForTests
        )
        XCTAssertEqual(capability.unsupportedReason, .pagedKVDisabled)
        XCTAssertFalse(capability.shouldUseSerialPath)
        XCTAssertThrowsError(try ContinuousBatchingPolicy.validateStrictStartup(capability))
    }

    // MARK: - FR-CB10 per-tuple acceptance coverage

    func testCoveredTupleWithEveryOtherGateGreenIsSupported() {
        let descriptor = Self.pagedKVDescriptor()
        let tuple = Self.continuousBatchingTuple()
        let capability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: tuple,
            acceptanceCoverage: Self.acceptanceCoverage(for: tuple)
        )
        XCTAssertNil(capability.unsupportedReason)
        XCTAssertFalse(capability.shouldUseSerialPath)
        XCTAssertNoThrow(try ContinuousBatchingPolicy.validateStrictStartup(capability))
    }

    func testDescriptorAdmittedTupleWithoutAcceptanceCoverageIsUnsupported() {
        let descriptor = Self.pagedKVDescriptor()
        let tuple = Self.continuousBatchingTuple()
        let capability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: tuple,
            acceptanceCoverage: .empty
        )
        XCTAssertEqual(capability.unsupportedReason, .tupleAcceptanceCoverageUnavailable)
    }

    // A coverage entry that differs in exactly one evidence field must not
    // cover the request: acceptance evidence is tuple-bound, not approximate.
    func testAcceptanceCoverageRequiresEveryEvidenceFieldToMatch() {
        let descriptor = Self.pagedKVDescriptor()
        let tuple = Self.continuousBatchingTuple()
        let mutations: [(String, ContinuousBatchingAcceptedTuple)] = [
            ("model_id", ContinuousBatchingAcceptedTuple(
                modelID: "mlx-community/Other-Test",
                modelSHA256: tuple.modelSHA256,
                cacheClass: tuple.cacheClass,
                kvDType: tuple.kvDType,
                requiresMoE: tuple.requiresMoE,
                hardwareClass: tuple.hardwareClass,
                metallibSHA256: tuple.metallibSHA256,
                kernelIdentifier: tuple.kernelIdentifier
            )),
            ("model_sha256", ContinuousBatchingAcceptedTuple(
                modelID: tuple.modelID,
                modelSHA256: String(repeating: "e", count: 64),
                cacheClass: tuple.cacheClass,
                kvDType: tuple.kvDType,
                requiresMoE: tuple.requiresMoE,
                hardwareClass: tuple.hardwareClass,
                metallibSHA256: tuple.metallibSHA256,
                kernelIdentifier: tuple.kernelIdentifier
            )),
            ("cache_class", ContinuousBatchingAcceptedTuple(
                modelID: tuple.modelID,
                modelSHA256: tuple.modelSHA256,
                cacheClass: "KVCacheQuantized",
                kvDType: tuple.kvDType,
                requiresMoE: tuple.requiresMoE,
                hardwareClass: tuple.hardwareClass,
                metallibSHA256: tuple.metallibSHA256,
                kernelIdentifier: tuple.kernelIdentifier
            )),
            ("kv_dtype", ContinuousBatchingAcceptedTuple(
                modelID: tuple.modelID,
                modelSHA256: tuple.modelSHA256,
                cacheClass: tuple.cacheClass,
                kvDType: .bf16,
                requiresMoE: tuple.requiresMoE,
                hardwareClass: tuple.hardwareClass,
                metallibSHA256: tuple.metallibSHA256,
                kernelIdentifier: tuple.kernelIdentifier
            )),
            ("requires_moe", ContinuousBatchingAcceptedTuple(
                modelID: tuple.modelID,
                modelSHA256: tuple.modelSHA256,
                cacheClass: tuple.cacheClass,
                kvDType: tuple.kvDType,
                requiresMoE: !tuple.requiresMoE,
                hardwareClass: tuple.hardwareClass,
                metallibSHA256: tuple.metallibSHA256,
                kernelIdentifier: tuple.kernelIdentifier
            )),
            ("hardware_class", ContinuousBatchingAcceptedTuple(
                modelID: tuple.modelID,
                modelSHA256: tuple.modelSHA256,
                cacheClass: tuple.cacheClass,
                kvDType: tuple.kvDType,
                requiresMoE: tuple.requiresMoE,
                hardwareClass: "apple-silicon-other",
                metallibSHA256: tuple.metallibSHA256,
                kernelIdentifier: tuple.kernelIdentifier
            )),
            ("metallib_sha256", ContinuousBatchingAcceptedTuple(
                modelID: tuple.modelID,
                modelSHA256: tuple.modelSHA256,
                cacheClass: tuple.cacheClass,
                kvDType: tuple.kvDType,
                requiresMoE: tuple.requiresMoE,
                hardwareClass: tuple.hardwareClass,
                metallibSHA256: String(repeating: "c", count: 64),
                kernelIdentifier: tuple.kernelIdentifier
            )),
            ("kernel_identifier", ContinuousBatchingAcceptedTuple(
                modelID: tuple.modelID,
                modelSHA256: tuple.modelSHA256,
                cacheClass: tuple.cacheClass,
                kvDType: tuple.kvDType,
                requiresMoE: tuple.requiresMoE,
                hardwareClass: tuple.hardwareClass,
                metallibSHA256: tuple.metallibSHA256,
                kernelIdentifier: "macprovider_paged_kv_gather_v2"
            ))
        ]
        for (field, accepted) in mutations {
            let capability = ContinuousBatchingPolicy.capability(
                mode: .on,
                maxBatch: 2,
                queueLimit: nil,
                kvBits: nil,
                draftConfigured: false,
                schedulerBackendAvailable: true,
                pagedKVDecision: .attached(descriptor),
                requestedTuple: tuple,
                acceptanceCoverage: ContinuousBatchingAcceptanceCoverage(acceptedTuples: [accepted])
            )
            XCTAssertEqual(
                capability.unsupportedReason,
                .tupleAcceptanceCoverageUnavailable,
                "coverage differing in \(field) must not cover the requested tuple"
            )
        }
    }

    func testCanarySerialRoutesUncoveredTuple() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(Self.pagedKVDescriptor()),
            requestedTuple: Self.continuousBatchingTuple(),
            acceptanceCoverage: .empty
        )
        XCTAssertEqual(capability.unsupportedReason, .tupleAcceptanceCoverageUnavailable)
        XCTAssertTrue(capability.shouldUseSerialPath)
        XCTAssertEqual(
            ContinuousBatchingPolicy.serialRouteTelemetryLine(capability),
            "event=batching_unsupported action=serial_routed reason=tuple_acceptance_coverage_unavailable\n"
        )
    }

    func testStrictOnFailsClosedOnUncoveredTuple() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(Self.pagedKVDescriptor()),
            requestedTuple: Self.continuousBatchingTuple(),
            acceptanceCoverage: .empty
        )
        XCTAssertEqual(capability.unsupportedReason, .tupleAcceptanceCoverageUnavailable)
        XCTAssertFalse(capability.shouldUseSerialPath)
        XCTAssertThrowsError(try ContinuousBatchingPolicy.validateStrictStartup(capability)) { error in
            guard let apiError = error as? APIError else {
                return XCTFail("expected APIError, got \(error)")
            }
            XCTAssertEqual(apiError.status, 400)
            XCTAssertEqual(apiError.code, "continuous_batching_tuple_acceptance_coverage_unavailable")
            XCTAssertFalse(apiError.inferenceRan)
        }
    }

    // Gate ordering: the descriptor gate is evaluated first, so a tuple that is
    // both unadvertised and uncovered reports the descriptor reason.
    func testDescriptorGateIsReportedBeforeAcceptanceCoverage() {
        let descriptor = Self.pagedKVDescriptor()
        let base = Self.continuousBatchingTuple()
        let unadvertised = ContinuousBatchingRequestedTuple(
            modelID: base.modelID,
            modelSHA256: String(repeating: "e", count: 64),
            tokenizerSHA256: base.tokenizerSHA256,
            chatTemplateSHA256: base.chatTemplateSHA256,
            cacheClass: base.cacheClass,
            kvDType: base.kvDType,
            requiresMoE: base.requiresMoE,
            hardwareClass: base.hardwareClass,
            metallibSHA256: base.metallibSHA256,
            kernelIdentifier: base.kernelIdentifier,
            parityLabel: base.parityLabel,
            poolEpoch: base.poolEpoch
        )
        let capability = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: unadvertised,
            acceptanceCoverage: .empty
        )
        XCTAssertEqual(capability.unsupportedReason, .tupleNotAdvertised)
    }

    // The two gates are independent: FR-CB10 coverage does not substitute for
    // the AC-23 MoE promotion decision.
    func testCoveredMoETupleStillNeedsMoEPromotionEvidence() {
        let descriptor = PagedKVDescriptor(
            blockSizeTokens: 16,
            maxPhysicalBlocks: 32,
            modelID: "catalog/moe-model",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: String(repeating: "b", count: 64),
            chatTemplateSHA256: String(repeating: "c", count: 64),
            supportedModelFamilies: ["qwen3_moe"],
            supportsMoEDispatch: true,
            hardwareClass: "m4-max-128gb",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged-attention-v1",
            parityLabel: "moe-greedy-parity"
        )
        let tuple = ContinuousBatchingRequestedTuple(
            modelID: descriptor.modelID,
            modelSHA256: descriptor.modelSHA256,
            tokenizerSHA256: descriptor.tokenizerSHA256,
            chatTemplateSHA256: descriptor.chatTemplateSHA256,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: true,
            hardwareClass: "m4-max-128gb",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged-attention-v1",
            parityLabel: "moe-greedy-parity",
            poolEpoch: 1
        )
        let capability = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .attached(descriptor),
            requestedTuple: tuple,
            acceptanceCoverage: Self.acceptanceCoverage(for: tuple),
            moePromotionEvidenceAvailable: false
        )
        XCTAssertEqual(capability.unsupportedReason, .moePromotionEvidenceUnavailable)
    }

    // MARK: - FR-CB10 configuration parsing

    func testConfigLoaderReadsAcceptedTuplesFromYAML() throws {
        let yaml = """
        continuous_batching_accepted_tuples:
          - model_id: mlx-community/Qwen-Test
            model_sha256: \(String(repeating: "a", count: 64))
            cache_class: KVCacheSimple
            kv_dtype: fp16
            requires_moe: false
            hardware_class: apple-silicon-test
            metallib_sha256: \(String(repeating: "b", count: 64))
            kernel_identifier: macprovider_paged_kv_gather_v1
        """
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in yaml })
        XCTAssertEqual(config.continuousBatchingAcceptedTuples, [
            ContinuousBatchingAcceptedTuple(
                modelID: "mlx-community/Qwen-Test",
                modelSHA256: String(repeating: "a", count: 64),
                cacheClass: "KVCacheSimple",
                kvDType: .fp16,
                requiresMoE: false,
                hardwareClass: "apple-silicon-test",
                metallibSHA256: String(repeating: "b", count: 64),
                kernelIdentifier: "macprovider_paged_kv_gather_v1"
            )
        ])
    }

    func testConfigLoaderRejectsMalformedAcceptedTupleEntry() throws {
        let yaml = """
        continuous_batching_accepted_tuples:
          - model_id: mlx-community/Qwen-Test
            model_sha256: \(String(repeating: "a", count: 64))
            cache_class: KVCacheSimple
            kv_dtype: int4
            requires_moe: false
            hardware_class: apple-silicon-test
            metallib_sha256: \(String(repeating: "b", count: 64))
            kernel_identifier: macprovider_paged_kv_gather_v1
        """
        XCTAssertThrowsError(try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in yaml }))

        let missingField = """
        continuous_batching_accepted_tuples:
          - model_id: mlx-community/Qwen-Test
            model_sha256: \(String(repeating: "a", count: 64))
            cache_class: KVCacheSimple
            kv_dtype: fp16
            requires_moe: false
        """
        XCTAssertThrowsError(try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in missingField }))
    }

    /// A declaration that parses but can never match the exact coverage
    /// comparison is a silent false negative: the operator believes the tuple
    /// is qualified and the provider serial-routes anyway. These shapes must
    /// fail at load, not at first request.
    func testConfigLoaderRejectsNonCanonicalAcceptedTupleSHA() throws {
        func yaml(sha: String) -> String {
            """
            continuous_batching_accepted_tuples:
              - model_id: mlx-community/Qwen-Test
                model_sha256: \(sha)
                cache_class: KVCacheSimple
                kv_dtype: fp16
                requires_moe: false
                hardware_class: apple-silicon-test
                metallib_sha256: \(String(repeating: "b", count: 64))
                kernel_identifier: macprovider_paged_kv_gather_v1
            """
        }
        for sha in [
            String(repeating: "A", count: 64),
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "z", count: 64),
            // Unicode confusables: `Character.isHexDigit` is true for these and
            // they are not uppercase, so a Character-level test would admit a
            // digest that can never equal the ASCII runtime hash.
            String(repeating: "\u{FF41}", count: 64),
            String(repeating: "\u{FF11}", count: 64)
        ] {
            XCTAssertThrowsError(try ConfigLoader.load(
                cli: CLIOverrides(),
                environment: [:],
                fileExists: { _ in true },
                readFile: { _ in yaml(sha: sha) }), "expected rejection for sha \(sha.prefix(4))…\(sha.count)")
        }
    }

    func testConfigLoaderRejectsPaddedAcceptedTupleIdentityFields() throws {
        let yaml = """
        continuous_batching_accepted_tuples:
          - model_id: mlx-community/Qwen-Test
            model_sha256: \(String(repeating: "a", count: 64))
            cache_class: KVCacheSimple
            kv_dtype: fp16
            requires_moe: false
            hardware_class: "apple-silicon-test "
            metallib_sha256: \(String(repeating: "b", count: 64))
            kernel_identifier: macprovider_paged_kv_gather_v1
        """
        XCTAssertThrowsError(try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in yaml }))
    }

    /// Acceptance evidence is bound to the runtime revision it was measured
    /// on; an entry that omits it must not load as if it covered every build.
    func testConfigLoaderRequiresAcceptedTupleRuntimeRevision() throws {
        let base = """
        continuous_batching_accepted_tuples:
          - model_id: mlx-community/Qwen-Test
            model_sha256: \(String(repeating: "a", count: 64))
            cache_class: KVCacheSimple
            kv_dtype: fp16
            requires_moe: false
            hardware_class: apple-silicon-test
        """
        for yaml in [
            base + "\n    kernel_identifier: macprovider_paged_kv_gather_v1\n",
            base + "\n    metallib_sha256: \(String(repeating: "b", count: 64))\n",
            base + "\n    metallib_sha256: \(String(repeating: "B", count: 64))\n    kernel_identifier: macprovider_paged_kv_gather_v1\n"
        ] {
            XCTAssertThrowsError(try ConfigLoader.load(
                cli: CLIOverrides(),
                environment: [:],
                fileExists: { _ in true },
                readFile: { _ in yaml }))
        }
    }

    func testConfigLoaderDefaultsAcceptedTuplesToEmpty() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "port: 8080" })
        XCTAssertTrue(config.continuousBatchingAcceptedTuples.isEmpty)
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

    func testRuntimeKeepsPagedKVInertWhenGatesAreClosed() async throws {
        let runtime = ModelRuntime(
            modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            modelHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            pagedKVConfig: PagedKVConfig(enabled: true),
            warmSwapEnabled: false,
            loader: { _ in throw TestRuntimeError.notExpected }
        )
        let decision = await runtime.pagedKVDecisionForTest()
        XCTAssertEqual(decision, .fallback(.cacheClass))
    }

    func testRuntimeStrictPagedKVRejectsBeforeCompletionRuns() async throws {
        let runtime = ModelRuntime(
            modelID: "fixture-model",
            modelHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            pagedKVConfig: PagedKVConfig(enabled: true, fallbackPolicy: .strict),
            warmSwapEnabled: false,
            loader: { _ in throw TestRuntimeError.notExpected },
            testCompletion: { _, _ in
                XCTFail("strict paged KV rejection must happen before inference")
                return CompletionResult(content: "unexpected", finishReason: "stop", promptTokens: 1, completionTokens: 1, settlementDisposition: .eligibleOwner)
            }
        )
        let request = try Self.request(model: "fixture-model")
        do {
            _ = try await runtime.complete(request)
            XCTFail("expected paged KV strict preflight rejection")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 503)
            XCTAssertEqual(error.code, "internal_error")
            XCTAssertFalse(error.message.localizedCaseInsensitiveContains("paged"))
            XCTAssertFalse(error.message.localizedCaseInsensitiveContains("kv"))
        }
    }

    func testRuntimeStrictPagedKVRejectsDuringStreamingPreflight() async throws {
        let runtime = ModelRuntime(
            modelID: "fixture-model",
            modelHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            pagedKVConfig: PagedKVConfig(enabled: true, fallbackPolicy: .strict),
            warmSwapEnabled: false,
            loader: { _ in throw TestRuntimeError.notExpected },
            testCompletion: { _, _ in
                CompletionResult(content: "unexpected", finishReason: "stop", promptTokens: 1, completionTokens: 1, settlementDisposition: .eligibleOwner)
            }
        )
        let request = try Self.request(model: "fixture-model", stream: true)
        let handle = try await runtime.acquireRequestHandle(request)
        do {
            try await runtime.preflight(request, with: handle)
            await runtime.unregisterInFlight(handle.registrationID)
            XCTFail("expected paged KV strict preflight rejection")
        } catch let error as APIError {
            await runtime.unregisterInFlight(handle.registrationID)
            XCTAssertEqual(error.status, 503)
            XCTAssertEqual(error.code, "internal_error")
            XCTAssertFalse(error.message.localizedCaseInsensitiveContains("paged"))
            XCTAssertFalse(error.message.localizedCaseInsensitiveContains("kv"))
        }
    }

    func testRuntimeCanaryKeyedFirstTurnStillServesWhenSchedulerIsUnavailable() async throws {
        let runtime = ModelRuntime(
            modelID: "fixture-model",
            maxBatch: 2,
            continuousBatchingMode: .canary,
            warmSwapEnabled: false,
            loader: { _ in throw TestRuntimeError.notExpected },
            testCompletion: { _, _ in
                CompletionResult(content: "ok", finishReason: "stop", promptTokens: 1, completionTokens: 1, settlementDisposition: .eligibleOwner)
            }
        )
        let request = try Self.request(model: "fixture-model", conversationKey: "conv:first-rollout-scope")
        let handle = try await runtime.acquireRequestHandle(request)
        do {
            try await runtime.preflight(request, with: handle)
            await runtime.unregisterInFlight(handle.registrationID)
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
    }

    func testRuntimeStrictDoesNotRejectKeyedFirstTurnForRolloutScope() async throws {
        let runtime = ModelRuntime(
            modelID: "fixture-model",
            maxBatch: 2,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            loader: { _ in throw TestRuntimeError.notExpected },
            testCompletion: { _, _ in
                XCTFail("strict keyed continuous batching rejection must happen before inference")
                return CompletionResult(content: "unexpected", finishReason: "stop", promptTokens: 1, completionTokens: 1, settlementDisposition: .eligibleOwner)
            }
        )
        let request = try Self.request(model: "fixture-model", conversationKey: "conv:first-rollout-scope")
        let handle = try await runtime.acquireRequestHandle(request)
        do {
            try await runtime.preflight(request, with: handle)
            await runtime.unregisterInFlight(handle.registrationID)
            XCTFail("expected fail-closed local-capability rejection, not conversation-key rollout")
        } catch let error as APIError {
            await runtime.unregisterInFlight(handle.registrationID)
            XCTAssertNotEqual(error.code, "continuous_batching_conversation_key_rollout_unavailable")
            // A default (sampled) request is representable since SPEC-038 AC-6b,
            // so strict `on` now fails closed on the missing local capability
            // (503) rather than on request representability (400).
            XCTAssertEqual(error.status, 503)
        }
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
         XCTAssertEqual(observed.unsupportedReason, .pagedKVDisabled)
     }

    func testRuntimeContinuousBatchingCapabilityAttachesOnlyWithMeasuredIdentityAndBackend() async throws {
        let modelID = "mlx-community/Qwen-Test"
        let modelSHA = String(repeating: "a", count: 64)
        let proof = PagedKVHardwareSizingProof(
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelFamily: "qwen",
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            blockSizeTokens: 32,
            maxPhysicalBlocks: 64,
            maxResidentTokens: 2048,
            parityLabel: "sdpa-parity-v1"
        )
        let observedIdentity = PagedKVObservedRuntimeIdentity(
            hardwareClass: proof.hardwareClass,
            metallibSHA256: proof.metallibSHA256,
            kernelIdentifier: proof.kernelIdentifier,
            parityLabel: proof.parityLabel,
            moeDispatchProven: false,
            poolEpoch: proof.poolEpoch,
            source: .runtimeMeasurement
        )

        let attached = ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 2,
            continuousBatchingMode: .on,
            continuousBatchingDurableReplayAuthorityAvailable: true,
            warmSwapEnabled: false,
            pagedKVObservedRuntimeIdentity: observedIdentity,
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            continuousBatchingBackend: ServingKnobsContinuousBatchingBackend(),
            loader: { _ in throw TestRuntimeError.notExpected }
        )
        let attachedDecision = await attached.pagedKVDecisionForTest()
        let attachedCapability = await attached.continuousBatchingCapabilityForTest()
        XCTAssertNotNil(attachedDecision.descriptor)
        XCTAssertNil(attachedCapability.unsupportedReason)

        let nilObservation = ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 2,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            loader: { _ in throw TestRuntimeError.notExpected }
        )
        let nilObservationDecision = await nilObservation.pagedKVDecisionForTest()
        let nilObservationCapability = await nilObservation.continuousBatchingCapabilityForTest()
        XCTAssertNil(nilObservationDecision.descriptor)
        XCTAssertNotNil(nilObservationCapability.unsupportedReason)

        let noBackend = ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 2,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            pagedKVObservedRuntimeIdentity: observedIdentity,
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: false,
            loader: { _ in throw TestRuntimeError.notExpected }
        )
        let noBackendDecision = await noBackend.pagedKVDecisionForTest()
        let noBackendCapability = await noBackend.continuousBatchingCapabilityForTest()
        XCTAssertNil(noBackendDecision.descriptor)
        XCTAssertNotNil(noBackendCapability.unsupportedReason)
    }

    func testRuntimeContinuousBatchingRequiresDurableReplayAuthorityBeforeAttachCapability() async throws {
        let modelID = "mlx-community/Qwen-Test"
        let modelSHA = String(repeating: "a", count: 64)
        let proof = PagedKVHardwareSizingProof(
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelFamily: "qwen",
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            blockSizeTokens: 32,
            maxPhysicalBlocks: 64,
            maxResidentTokens: 2048,
            parityLabel: "sdpa-parity-v1"
        )
        let observedIdentity = PagedKVObservedRuntimeIdentity(
            hardwareClass: proof.hardwareClass,
            metallibSHA256: proof.metallibSHA256,
            kernelIdentifier: proof.kernelIdentifier,
            parityLabel: proof.parityLabel,
            moeDispatchProven: false,
            poolEpoch: proof.poolEpoch,
            source: .runtimeMeasurement
        )
        let runtime = ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 2,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            pagedKVObservedRuntimeIdentity: observedIdentity,
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            continuousBatchingBackend: ServingKnobsContinuousBatchingBackend(),
            loader: { _ in throw TestRuntimeError.notExpected }
        )
        let capability = await runtime.continuousBatchingCapabilityForTest()
        XCTAssertEqual(capability.unsupportedReason, .durableReplayAuthorityUnavailable)
        XCTAssertThrowsError(try ContinuousBatchingPolicy.validateStrictStartup(capability)) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 503)
            XCTAssertEqual(apiError?.code, "continuous_batching_durable_replay_authority_unavailable")
        }
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

    private static func pagedKVDescriptor() -> PagedKVDescriptor {
        PagedKVDescriptor(
            blockSizeTokens: 32,
            maxPhysicalBlocks: 64,
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            supportedModelFamilies: ["qwen"],
            supportsMoEDispatch: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            parityLabel: "sdpa-parity-v1"
        )
    }

    /// FR-CB10 coverage that exactly matches `tuple` on the eight evidence
    /// fields, so a gating test proves the descriptor gate rather than the
    /// acceptance gate.
    private static func acceptanceCoverage(
        for tuple: ContinuousBatchingRequestedTuple
    ) -> ContinuousBatchingAcceptanceCoverage {
        ContinuousBatchingAcceptanceCoverage(acceptedTuples: [
            ContinuousBatchingAcceptedTuple(
                modelID: tuple.modelID,
                modelSHA256: tuple.modelSHA256,
                cacheClass: tuple.cacheClass,
                kvDType: tuple.kvDType,
                requiresMoE: tuple.requiresMoE,
                hardwareClass: tuple.hardwareClass,
                metallibSHA256: tuple.metallibSHA256,
                kernelIdentifier: tuple.kernelIdentifier
            )
        ])
    }

    private static func continuousBatchingTuple() -> ContinuousBatchingRequestedTuple {
        ContinuousBatchingRequestedTuple(
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            parityLabel: "sdpa-parity-v1",
            poolEpoch: 1
        )
    }

    private static func request(
        model: String,
        stream: Bool = false,
        conversationKey: String? = nil
    ) throws -> ChatCompletionRequest {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Say hi"]],
            "max_tokens": 1,
            "stream": stream,
        ]
        let parsed = try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
        return parsed.withConversationKey(conversationKey)
    }
}

private enum TestRuntimeError: Error {
    case notExpected
}

private actor ServingKnobsContinuousBatchingBackend: ContinuousBatchSchedulerBackend {
    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        rows.map { ContinuousBatchPrefillOutput(requestID: $0.requestID) }
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        rows.map {
            .output(ContinuousBatchDecodeOutput(requestID: $0.requestID, token: $0.currentToken))
        }
    }

    func cancelInFlight() async {}
}
