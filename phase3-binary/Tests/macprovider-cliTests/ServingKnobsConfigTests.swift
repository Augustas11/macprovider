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

    func testPagedKVAttachedDecisionFailsClosedUntilRuntimeBridgeOwnsRequestReservation() throws {
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
                engineBridgeAvailable: true
            )
        )
        XCTAssertNotNil(decision.descriptor)
        XCTAssertThrowsError(try ModelRuntime.enforcePagedKVPreflight(decision)) { error in
            XCTAssertEqual((error as? APIError)?.status, 503)
            XCTAssertEqual((error as? APIError)?.code, "internal_error")
        }
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
                requestedTuple: nil
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
            requestedTuple: nil
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

    func testContinuousBatchingPolicyReportsKvBitsBeforeLocalCapability() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: 4,
            draftConfigured: false,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil
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
            requestedTuple: nil
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
            requestedTuple: nil
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
            requestedTuple: exact
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
            requestedTuple: mismatch
        )
        XCTAssertEqual(rejected.unsupportedReason, .tupleNotAdvertised)
        XCTAssertTrue(rejected.shouldUseSerialPath)
    }

    func testStickyCacheEligibleRequestSerialRoutesUntilBridgeExists() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            stickyCacheEligible: true,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil
        )
        XCTAssertEqual(capability.unsupportedReason, .stickyCacheBridgeUnavailable)
        XCTAssertTrue(capability.shouldUseSerialPath)
    }

    func testUnrepresentableRequestStateSerialRoutesInCanary() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .canary,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            stickyCacheEligible: false,
            requestStateRepresentable: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .disabled,
            requestedTuple: nil
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
            stickyCacheEligible: false,
            requestStateRepresentable: false,
            schedulerBackendAvailable: true,
            pagedKVDecision: .disabled,
            requestedTuple: nil
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
        // Plain request → representable.
        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([:])))

        // Structured output (json_schema) → not representable.
        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "response_format": ["type": "json_schema",
                                "json_schema": ["name": "s",
                                                "schema": ["type": "object",
                                                           "additionalProperties": false]]]
        ])))

        // Tools present WITHOUT tool_choice → not representable (the HIGH the gate missed).
        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "tools": [["type": "function",
                       "function": ["name": "f", "parameters": ["type": "object"]]]]
        ])))

        // Explicit JSON null tool_choice, no tools → representable (must NOT false-positive).
        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "tool_choice": NSNull()
        ])))

        // logit_bias → not representable; logprobs:false → representable.
        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "logit_bias": ["123": -100]
        ])))
        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "logprobs": false
        ])))
        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
            "logprobs": true
        ])))
        // top_logprobs (response metadata) is rejected too so the gate is provably complete.
        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try parsedRequest([
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
            stickyCacheEligible: false,
            requestStateRepresentable: true,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil
        )
        XCTAssertNotEqual(capability.unsupportedReason, .requestStateUnrepresented)
    }

    func testMoETupleRemainsUnsupportedUntilCorrectnessAndMSB04EvidenceExist() {
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
            requestedTuple: tuple
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
            requestedTuple: tuple
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

    func testStrictOnRejectsStickyRequestWithoutCacheBridge() {
        let capability = ContinuousBatchingPolicy.capability(
            mode: .on,
            maxBatch: 2,
            queueLimit: nil,
            kvBits: nil,
            draftConfigured: false,
            stickyCacheEligible: true,
            schedulerBackendAvailable: false,
            pagedKVDecision: .disabled,
            requestedTuple: nil
        )
        XCTAssertEqual(capability.unsupportedReason, .stickyCacheBridgeUnavailable)
        XCTAssertFalse(capability.shouldUseSerialPath)
        XCTAssertThrowsError(try ContinuousBatchingPolicy.validateStrictStartup(capability))
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
            requestedTuple: nil
        )
        XCTAssertEqual(capability.unsupportedReason, .pagedKVDisabled)
        XCTAssertFalse(capability.shouldUseSerialPath)
        XCTAssertThrowsError(try ContinuousBatchingPolicy.validateStrictStartup(capability))
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
        XCTAssertEqual(decision, .fallback(.metallib))
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
                return CompletionResult(content: "unexpected", finishReason: "stop", promptTokens: 1, completionTokens: 1)
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
                CompletionResult(content: "unexpected", finishReason: "stop", promptTokens: 1, completionTokens: 1)
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

    private static func request(model: String, stream: Bool = false) throws -> ChatCompletionRequest {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Say hi"]],
            "max_tokens": 1,
            "stream": stream,
        ]
        return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
    }
}

private enum TestRuntimeError: Error {
    case notExpected
}
