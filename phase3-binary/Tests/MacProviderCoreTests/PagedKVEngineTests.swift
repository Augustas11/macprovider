import Foundation
@testable import MacProviderCore
import XCTest

final class PagedKVEngineTests: XCTestCase {
    private let proofModelID = "mlx-community/Qwen-Test"
    private let proofModelSHA256 = String(repeating: "a", count: 64)
    private let proofTokenizerSHA256 = String(repeating: "b", count: 64)
    private let proofChatTemplateSHA256 = String(repeating: "c", count: 64)

    private func sizingProof(
        modelID: String? = nil,
        modelSHA256: String? = nil,
        tokenizerSHA256: String? = nil,
        chatTemplateSHA256: String? = nil,
        modelFamily: String,
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        poolEpoch: Int = 1
    ) -> PagedKVHardwareSizingProof {
        PagedKVHardwareSizingProof(
            modelID: modelID ?? proofModelID,
            modelSHA256: modelSHA256 ?? proofModelSHA256,
            tokenizerSHA256: tokenizerSHA256 ?? proofTokenizerSHA256,
            chatTemplateSHA256: chatTemplateSHA256 ?? proofChatTemplateSHA256,
            modelFamily: modelFamily,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged_attention_v1",
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            maxResidentTokens: blockSizeTokens * maxPhysicalBlocks,
            poolEpoch: poolEpoch,
            parityLabel: "sdpa-parity-v1"
        )
    }

    private func decide(
        config: PagedKVConfig,
        runtimeCacheClass: String,
        kvBits: Int?,
        modelFamily: String,
        requiresMoEDispatch: Bool,
        gates: PagedKVGates
    ) -> PagedKVAttachDecision {
        PagedKVAttachGate.decide(
            config: config,
            runtimeCacheClass: runtimeCacheClass,
            kvBits: kvBits,
            modelID: proofModelID,
            modelSHA256: proofModelSHA256,
            tokenizerSHA256: proofTokenizerSHA256,
            chatTemplateSHA256: proofChatTemplateSHA256,
            modelFamily: modelFamily,
            requiresMoEDispatch: requiresMoEDispatch,
            gates: gates
        )
    }

    func testClosedFallbackReasonEnumMatchesSpec039() {
        XCTAssertEqual(
            PagedKVFallbackReason.allCases.map(\.rawValue).sorted(),
            [
                "paged_fallback_allocator",
                "paged_fallback_cache_class",
                "paged_fallback_identity",
                "paged_fallback_kernel",
                "paged_fallback_metallib",
                "paged_fallback_parity",
                "paged_fallback_quantized",
                "paged_preflight_reject",
            ].sorted()
        )
    }

    func testPagedKVConfigDefaultsOffAndCLIOverridesEnvironmentOverridesYAML() {
        let yaml: [String: Any] = [
            "enabled": true,
            "block_size_tokens": 8,
            "max_physical_blocks": 12,
            "fallback_policy": "permissive",
        ]
        let resolved = PagedKVConfigResolver.resolve(
            yaml: yaml,
            environment: [
                "MACPROVIDER_PAGED_KV_BLOCK_SIZE_TOKENS": "16",
                "MACPROVIDER_PAGED_KV_MAX_PHYSICAL_BLOCKS": "24",
            ],
            cli: PagedKVCLIOverrides(maxPhysicalBlocks: 48, fallbackPolicy: " strict ")
        )
        XCTAssertTrue(resolved.enabled)
        XCTAssertEqual(resolved.blockSizeTokens, 16)
        XCTAssertEqual(resolved.maxPhysicalBlocks, 48)
        XCTAssertEqual(resolved.fallbackPolicy, .strict)
        XCTAssertTrue(resolved.errors.isEmpty)

        let defaults = PagedKVConfigResolver.resolve(yaml: nil, environment: [:])
        XCTAssertFalse(defaults.enabled)
        XCTAssertFalse(defaults.effectiveEnabled)
    }

    func testInvalidPagedKVConfigDisablesFailClosed() {
        let resolved = PagedKVConfigResolver.resolve(
            yaml: ["enabled": true, "block_size_tokens": 0],
            environment: ["MACPROVIDER_PAGED_KV_FALLBACK_POLICY": "surprise"],
            cli: PagedKVCLIOverrides(maxPhysicalBlocks: -1)
        )
        XCTAssertFalse(resolved.enabled)
        XCTAssertFalse(resolved.effectiveEnabled)
        XCTAssertEqual(resolved.errors.count, 3)
    }

    func testUnsupportedPagedKVYAMLTypesDisableFailClosed() {
        let resolved = PagedKVConfigResolver.resolve(
            yaml: [
                "enabled": ["true"],
                "fallback_policy": ["strict"],
            ],
            environment: [:]
        )
        XCTAssertFalse(resolved.enabled)
        XCTAssertFalse(resolved.effectiveEnabled)
        XCTAssertEqual(resolved.errors.count, 2)
    }

    func testPagedKVConfigRejectsOversizedValuesAndRedactsRawErrors() {
        let secretLikeValue = "secret-token-that-should-not-log"
        let resolved = PagedKVConfigResolver.resolve(
            yaml: nil,
            environment: [
                "MACPROVIDER_PAGED_KV_ENABLED": "true",
                "MACPROVIDER_PAGED_KV_BLOCK_SIZE_TOKENS": secretLikeValue,
                "MACPROVIDER_PAGED_KV_MAX_PHYSICAL_BLOCKS": String(PagedKVConfig.maximumPhysicalBlocks + 1),
            ]
        )
        XCTAssertFalse(resolved.enabled)
        XCTAssertFalse(resolved.effectiveEnabled)
        XCTAssertEqual(resolved.errors.count, 2)
        XCTAssertFalse(resolved.errors.joined(separator: "\n").contains(secretLikeValue))
    }

    func testAttachGateFailsClosedForQuantizedAndCacheClassBeforeDescriptor() {
        let config = PagedKVConfig(enabled: true, blockSizeTokens: 16, maxPhysicalBlocks: 8)
        let gates = PagedKVGates(
            identityAvailable: true,
            observedHardwareClass: "apple-silicon-test",
            metallibAvailable: true,
            kernelRegistered: true,
            parityEstablished: true,
            hardwareSizingProof: sizingProof(modelFamily: "qwen", blockSizeTokens: 16, maxPhysicalBlocks: 8)
        )

        XCTAssertEqual(
            decide(
                config: config,
                runtimeCacheClass: "KVCacheSimple",
                kvBits: 4,
                modelFamily: "qwen",
                requiresMoEDispatch: true,
                gates: gates
            ),
            .fallback(.quantized)
        )
        XCTAssertEqual(
            decide(
                config: config,
                runtimeCacheClass: "RotatingKVCache",
                kvBits: nil,
                modelFamily: "qwen",
                requiresMoEDispatch: false,
                gates: gates
            ),
            .fallback(.cacheClass)
        )
    }

    func testAttachGateCannotAttachUntilEngineBridgeIsRegistered() {
        let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let proof = sizingProof(modelFamily: "qwen", blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let decision = decide(
            config: config,
            runtimeCacheClass: "KVCacheSimple",
            kvBits: nil,
            modelFamily: "qwen",
            requiresMoEDispatch: true,
            gates: PagedKVGates(
                identityAvailable: true,
                observedHardwareClass: "apple-silicon-test",
                metallibAvailable: true,
                kernelRegistered: true,
                parityEstablished: true,
                hardwareSizingProof: proof,
                observedMetallibSHA256: proof.metallibSHA256,
                observedKernelIdentifier: proof.kernelIdentifier,
                observedParityLabel: proof.parityLabel,
                moeDispatchProven: true
            )
        )
        XCTAssertEqual(decision, .fallback(.kernel))
    }

    func testAttachGateAttachesWhenRuntimeBridgeCapabilityIsAvailable() throws {
        let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let proof = sizingProof(modelFamily: "qwen", blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let decision = decide(
            config: config,
            runtimeCacheClass: "KVCacheSimple",
            kvBits: nil,
            modelFamily: "qwen",
            requiresMoEDispatch: true,
            gates: PagedKVGates(
                identityAvailable: true,
                observedHardwareClass: "apple-silicon-test",
                metallibAvailable: true,
                kernelRegistered: true,
                parityEstablished: true,
                hardwareSizingProof: proof,
                observedMetallibSHA256: proof.metallibSHA256,
                observedKernelIdentifier: proof.kernelIdentifier,
                observedParityLabel: proof.parityLabel,
                moeDispatchProven: true,
                engineBridgeAvailable: true
            )
        )
        let descriptor = try XCTUnwrap(decision.descriptor)
        XCTAssertTrue(descriptor.admits(
            modelID: proofModelID,
            modelSHA256: proofModelSHA256,
            tokenizerSHA256: proofTokenizerSHA256,
            chatTemplateSHA256: proofChatTemplateSHA256,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: true,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: proof.metallibSHA256,
            kernelIdentifier: proof.kernelIdentifier,
            parityLabel: proof.parityLabel,
            poolEpoch: proof.poolEpoch
        ))
    }

    func testAttachDescriptorIsSingleSourceOfTruth() {
        let descriptor = PagedKVDescriptor(
            blockSizeTokens: 32,
            maxPhysicalBlocks: 64,
            modelID: proofModelID,
            modelSHA256: proofModelSHA256,
            tokenizerSHA256: proofTokenizerSHA256,
            chatTemplateSHA256: proofChatTemplateSHA256,
            supportedModelFamilies: ["qwen"],
            supportsMoEDispatch: true,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged_attention_v1",
            parityLabel: "sdpa-parity-v1"
        )
        XCTAssertTrue(descriptor.admits(
            modelID: proofModelID,
            modelSHA256: proofModelSHA256,
            tokenizerSHA256: proofTokenizerSHA256,
            chatTemplateSHA256: proofChatTemplateSHA256,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: true,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged_attention_v1",
            parityLabel: "sdpa-parity-v1",
            poolEpoch: 1
        ))
        XCTAssertEqual(descriptor.maxPhysicalBlocks, 64)
        XCTAssertEqual(descriptor.hardwareClass, "apple-silicon-test")
        XCTAssertEqual(descriptor.metallibSHA256, String(repeating: "d", count: 64))
        XCTAssertEqual(descriptor.kernelIdentifier, "paged_attention_v1")
        XCTAssertFalse(descriptor.admits(
            modelID: "mlx-community/Other-Qwen",
            modelSHA256: proofModelSHA256,
            tokenizerSHA256: proofTokenizerSHA256,
            chatTemplateSHA256: proofChatTemplateSHA256,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged_attention_v1",
            parityLabel: "sdpa-parity-v1",
            poolEpoch: 1
        ))
        XCTAssertFalse(descriptor.admits(
            modelID: proofModelID,
            modelSHA256: proofModelSHA256,
            tokenizerSHA256: "wrong-tokenizer",
            chatTemplateSHA256: proofChatTemplateSHA256,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged_attention_v1",
            parityLabel: "sdpa-parity-v1",
            poolEpoch: 1
        ))
        XCTAssertFalse(descriptor.admits(
            modelID: proofModelID,
            modelSHA256: proofModelSHA256,
            tokenizerSHA256: proofTokenizerSHA256,
            chatTemplateSHA256: proofChatTemplateSHA256,
            cacheClass: "RotatingKVCache",
            kvDType: .fp16,
            requiresMoE: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: "paged_attention_v1",
            parityLabel: "sdpa-parity-v1",
            poolEpoch: 1
        ))
    }

    func testAttachGateRequiresSeparateMoEDispatchProof() {
        let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let proof = sizingProof(modelFamily: "qwen", blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let unprovenMoE = decide(
            config: config,
            runtimeCacheClass: "KVCacheSimple",
            kvBits: nil,
            modelFamily: "qwen",
            requiresMoEDispatch: true,
            gates: PagedKVGates(
                identityAvailable: true,
                observedHardwareClass: "apple-silicon-test",
                metallibAvailable: true,
                kernelRegistered: true,
                parityEstablished: true,
                hardwareSizingProof: proof,
                observedMetallibSHA256: proof.metallibSHA256,
                observedKernelIdentifier: proof.kernelIdentifier,
                observedParityLabel: proof.parityLabel,
                moeDispatchProven: false
            )
        )
        XCTAssertEqual(unprovenMoE, .fallback(.kernel))
    }

    func testAttachGateRequiresKnownFamilyAndHardwareSizingProof() {
        let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
        XCTAssertEqual(
            decide(
                config: config,
                runtimeCacheClass: "KVCacheSimple",
                kvBits: nil,
                modelFamily: "unknown",
                requiresMoEDispatch: false,
                gates: PagedKVGates(
                    identityAvailable: true,
                    observedHardwareClass: "apple-silicon-test",
                    metallibAvailable: true,
                    kernelRegistered: true,
                    parityEstablished: true,
                    hardwareSizingProof: sizingProof(modelFamily: "unknown", blockSizeTokens: 32, maxPhysicalBlocks: 64)
                )
            ),
            .fallback(.identity)
        )
        XCTAssertEqual(
            decide(
                config: config,
                runtimeCacheClass: "KVCacheSimple",
                kvBits: nil,
                modelFamily: "llama",
                requiresMoEDispatch: false,
                gates: PagedKVGates(
                    identityAvailable: true,
                    metallibAvailable: true,
                    kernelRegistered: true,
                    parityEstablished: true
                )
            ),
            .fallback(.allocator)
        )
    }

    func testAttachGateRejectsSizingProofForDifferentHardware() {
        let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let decision = decide(
            config: config,
            runtimeCacheClass: "KVCacheSimple",
            kvBits: nil,
            modelFamily: "qwen",
            requiresMoEDispatch: false,
            gates: PagedKVGates(
                identityAvailable: true,
                observedHardwareClass: "apple-silicon-other",
                metallibAvailable: true,
                kernelRegistered: true,
                parityEstablished: true,
                hardwareSizingProof: sizingProof(modelFamily: "qwen", blockSizeTokens: 32, maxPhysicalBlocks: 64)
            )
        )
        XCTAssertEqual(decision, .fallback(.allocator))
    }

    func testAttachGateRejectsDirectInvalidConfig() {
        let config = PagedKVConfig(enabled: true, blockSizeTokens: 0, maxPhysicalBlocks: 64)
        let decision = decide(
            config: config,
            runtimeCacheClass: "KVCacheSimple",
            kvBits: nil,
            modelFamily: "qwen",
            requiresMoEDispatch: false,
            gates: PagedKVGates(
                identityAvailable: true,
                observedHardwareClass: "apple-silicon-test",
                metallibAvailable: true,
                kernelRegistered: true,
                parityEstablished: true,
                hardwareSizingProof: sizingProof(modelFamily: "qwen", blockSizeTokens: 32, maxPhysicalBlocks: 64)
            )
        )
        XCTAssertEqual(decision, .fallback(.allocator))
    }

    func testStrictAttachGateRejectsAtPreflight() {
        let decision = decide(
            config: PagedKVConfig(enabled: true, fallbackPolicy: .strict),
            runtimeCacheClass: "KVCacheSimple",
            kvBits: nil,
            modelFamily: "llama",
            requiresMoEDispatch: false,
            gates: .closed
        )
        XCTAssertEqual(decision, .rejected(.preflightReject))
    }

    func testAllocatorReservesWorstCaseAndRejectsOversizedBatch1() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 3)
        let admitsTwelve = await allocator.canAdmitBatch1(maxTokens: 12)
        let admitsThirteen = await allocator.canAdmitBatch1(maxTokens: 13)
        XCTAssertTrue(admitsTwelve)
        XCTAssertFalse(admitsThirteen)

        _ = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 12, initialTokens: 1)
        let admitsAfterReservation = await allocator.canAdmitBatch1(maxTokens: 1)
        XCTAssertFalse(admitsAfterReservation)
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.allocate(conversationKey: "conv:b", maxTokens: 1)
        }
    }

    func testAllocatorRejectsTokenArithmeticOverflow() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 3)
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.requiredBlocks(maxTokens: Int.max)
        }

        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 8, initialTokens: 1)
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.extend(handle, by: Int.max)
        }
    }

    func testAllocatorNonIdentityLayoutBoundaryCrossingTrimAndMaterialize() async throws {
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: 4,
            maxPhysicalBlocks: 6,
            physicalBlockOrder: [3, 1, 4, 0, 2, 5]
        )
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 12, initialTokens: 7)
        var table = try await allocator.table(for: handle)
        XCTAssertEqual(table.physicalBlocks, [3, 1])
        XCTAssertEqual(table.tailValidTokenCount, 3)
        XCTAssertNotEqual(table.physicalBlocks, [0, 1])

        table = try await allocator.extend(handle, by: 2)
        XCTAssertEqual(table.physicalBlocks, [3, 1, 4])
        XCTAssertEqual(table.tailValidTokenCount, 1)

        table = try await allocator.trim(handle, toLogicalTokens: 6)
        XCTAssertEqual(table.physicalBlocks, [3, 1])
        XCTAssertEqual(table.tailValidTokenCount, 2)

        let block3 = Data("abcd".utf8)
        let block1 = Data("efgh".utf8)
        let materialized = try await allocator.materialize(
            handle,
            physicalBlocks: [3: block3, 1: block1],
            bytesPerToken: 1
        )
        XCTAssertEqual(String(data: materialized, encoding: .utf8), "abcdef")
    }

    func testTrimReleasesNoLongerLiveReservedBlocks() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 3)
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 12, initialTokens: 9)
        var freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocks, 0)

        let table = try await allocator.trim(handle, toLogicalTokens: 4)
        XCTAssertEqual(table.logicalTokenCount, 4)
        XCTAssertEqual(table.physicalBlocks.count, 1)
        freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocks, 2)
    }

    func testAllocatorBindingAndMaterializedCacheAreHandleOwned() async throws {
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: 4,
            maxPhysicalBlocks: 4,
            physicalBlockOrder: [2, 0, 3, 1]
        )
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 8, initialTokens: 6)
        let binding = try await allocator.binding(for: handle)
        XCTAssertEqual(binding.handle, handle)
        XCTAssertEqual(binding.maxLogicalTokens, 8)
        XCTAssertEqual(binding.currentTable.physicalBlocks, [2, 0])

        let materialized = try await allocator.materializeCache(
            handle,
            layers: [
                PagedKVPhysicalLayerBlocks(
                    layerIndex: 1,
                    keyShape: [1, 1, 6, 1],
                    valueShape: [1, 1, 6, 1],
                    keyBlocks: [
                        2: Data([0, 1, 2, 3, 4, 5, 6, 7]),
                        0: Data([8, 9, 10, 11, 12, 13, 14, 15]),
                    ],
                    valueBlocks: [
                        2: Data([100, 101, 102, 103, 104, 105, 106, 107]),
                        0: Data([108, 109, 110, 111, 112, 113, 114, 115]),
                    ],
                    bytesPerToken: 2
                ),
            ]
        )

        XCTAssertEqual(materialized.handle, handle)
        XCTAssertEqual(materialized.blockTable.physicalBlocks, [2, 0])
        XCTAssertEqual(materialized.layers.map(\.layerIndex), [1])
        XCTAssertEqual(materialized.layers[0].keyBytes, Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]))
        XCTAssertEqual(materialized.layers[0].valueBytes, Data([100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111]))

        let ordered = try await allocator.materializeOrderedBytes(
            handle,
            layers: [
                PagedKVOrderedLayerBlocks(
                    layerIndex: 1,
                    keyShape: [1, 1, 6, 1],
                    valueShape: [1, 1, 6, 1],
                    keyBlocksInTableOrder: [
                        Data([0, 1, 2, 3, 4, 5, 6, 7]),
                        Data([8, 9, 10, 11, 12, 13, 14, 15]),
                    ],
                    valueBlocksInTableOrder: [
                        Data([100, 101, 102, 103, 104, 105, 106, 107]),
                        Data([108, 109, 110, 111, 112, 113, 114, 115]),
                    ],
                    bytesPerToken: 2
                ),
            ]
        )
        XCTAssertEqual(ordered.layers[0].keyBytes, materialized.layers[0].keyBytes)
        XCTAssertEqual(ordered.layers[0].valueBytes, materialized.layers[0].valueBytes)
    }

    func testContiguousBridgeMaterializesValidEmptySequence() async throws {
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: 4,
            maxPhysicalBlocks: 1,
            contiguousCacheBridge: EmptyContiguousCacheBridge()
        )
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 4, initialTokens: 0)

        let materialized = try await allocator.materializeContiguousByteCache(handle)

        XCTAssertEqual(materialized.blockTable.logicalTokenCount, 0)
        XCTAssertEqual(materialized.blockTable.physicalBlocks, [])
        XCTAssertEqual(materialized.layers.count, 1)
        XCTAssertEqual(materialized.layers[0].keyShape, [1, 1, 0, 2])
        XCTAssertEqual(materialized.layers[0].keyBytes, Data())
        XCTAssertEqual(materialized.layers[0].valueBytes, Data())
    }

    func testMaterializedCacheRejectsBytesPerTokenThatDoesNotMatchFP16Shape() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 2)
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 8, initialTokens: 6)
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.materializeCache(
                handle,
                layers: [
                    PagedKVPhysicalLayerBlocks(
                        layerIndex: 0,
                        keyShape: [1, 1, 6, 1],
                        valueShape: [1, 1, 6, 1],
                        keyBlocks: [
                            0: Data(repeating: 0, count: 8),
                            1: Data(repeating: 0, count: 8),
                        ],
                        valueBlocks: [
                            0: Data(repeating: 0, count: 8),
                            1: Data(repeating: 0, count: 8),
                        ],
                        bytesPerToken: 1
                    ),
                ]
            )
        }
    }

    func testMaterializedCacheCopiesMultiHeadSequenceAxisAcrossBlocks() async throws {
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: 2,
            maxPhysicalBlocks: 2,
            physicalBlockOrder: [0, 1]
        )
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 4, initialTokens: 3)
        let keyBlock0 = Data([0, 1, 2, 3, 4, 5, 6, 7, 20, 21, 22, 23, 24, 25, 26, 27])
        let keyBlock1 = Data([8, 9, 10, 11, 99, 99, 99, 99, 28, 29, 30, 31, 99, 99, 99, 99])
        let valueBlock0 = Data([100, 101, 102, 103, 104, 105, 106, 107, 120, 121, 122, 123, 124, 125, 126, 127])
        let valueBlock1 = Data([108, 109, 110, 111, 199, 199, 199, 199, 128, 129, 130, 131, 199, 199, 199, 199])

        let materialized = try await allocator.materializeCache(
            handle,
            layers: [
                PagedKVPhysicalLayerBlocks(
                    layerIndex: 0,
                    keyShape: [1, 2, 3, 2],
                    valueShape: [1, 2, 3, 2],
                    keyBlocks: [0: keyBlock0, 1: keyBlock1],
                    valueBlocks: [0: valueBlock0, 1: valueBlock1],
                    bytesPerToken: 8
                ),
            ]
        )

        XCTAssertEqual(materialized.layers[0].keyBytes, Data([
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
            20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
        ]))
        XCTAssertEqual(materialized.layers[0].valueBytes, Data([
            100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111,
            120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131,
        ]))
    }

    func testAllocatorRejectsExtensionBeyondAdmittedCeilingWithoutMutation() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 2)
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 4, initialTokens: 4)
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.extend(handle, by: 1)
        }
        let table = try await allocator.table(for: handle)
        XCTAssertEqual(table.logicalTokenCount, 4)
        XCTAssertEqual(table.physicalBlocks.count, 1)
        let freeAfterRejectedExtension = await allocator.freeBlockCount()
        XCTAssertEqual(freeAfterRejectedExtension, 1)
    }

    func testAllocatorDynamicReservationExtendsFromSharedPoolAtomically() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 3)
        let handle = try await allocator.allocate(
            conversationKey: "conv:a",
            initialCapacityTokens: 4,
            maxLogicalTokens: 12,
            initialTokens: 4
        )
        var freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocks, 2)

        var table = try await allocator.extend(handle, by: 1)
        XCTAssertEqual(table.logicalTokenCount, 5)
        XCTAssertEqual(table.physicalBlocks.count, 2)
        freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocks, 1)

        table = try await allocator.extend(handle, by: 7)
        XCTAssertEqual(table.logicalTokenCount, 12)
        XCTAssertEqual(table.physicalBlocks.count, 3)
        freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocks, 0)

        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.extend(handle, by: 1)
        }
        let tableAfterRejectedExtension = try await allocator.table(for: handle)
        XCTAssertEqual(tableAfterRejectedExtension.logicalTokenCount, 12)
        XCTAssertEqual(tableAfterRejectedExtension.physicalBlocks.count, 3)
    }

    func testRetainReattachIsSameConversationOnlyAndReleaseHonorsInFlight() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 4)
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 8, initialTokens: 4)
        try await allocator.beginDecodeStep(handle)
        await XCTAssertThrowsErrorAsync {
            try await allocator.release(handle)
        }
        try await allocator.endDecodeStep(handle)
        await XCTAssertThrowsErrorAsync {
            try await allocator.endDecodeStep(handle)
        }

        let retained = try await allocator.retain(handle)
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.extend(handle, by: 1)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.trim(handle, toLogicalTokens: 2)
        }
        await XCTAssertThrowsErrorAsync {
            try await allocator.release(handle)
        }
        let reattached = try await allocator.reattach(retained, conversationKey: "conv:a")
        XCTAssertEqual(reattached, handle)
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.reattach(retained, conversationKey: "conv:a")
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.reattach(retained, conversationKey: "conv:b")
        }
    }

    func testExtendAndTrimRejectDuringInFlightDecodeStep() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 3)
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 12, initialTokens: 4)
        try await allocator.beginDecodeStep(handle)
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.extend(handle, by: 1)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.trim(handle, toLogicalTokens: 2)
        }
        try await allocator.endDecodeStep(handle)
        let table = try await allocator.extend(handle, by: 1)
        XCTAssertEqual(table.logicalTokenCount, 5)
    }

    func testDiscardRetainedReclaimsReservedBlocks() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 2)
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 8, initialTokens: 4)
        let retained = try await allocator.retain(handle)
        await XCTAssertThrowsErrorAsync {
            try await allocator.discardRetained(retained, conversationKey: "conv:b")
        }
        try await allocator.discardRetained(retained, conversationKey: "conv:a")
        let freeAfterDiscard = await allocator.freeBlockCount()
        XCTAssertEqual(freeAfterDiscard, 2)
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.reattach(retained, conversationKey: "conv:a")
        }
    }

    func testReleaseWithWrongConversationDoesNotDeleteLiveStateOrLeakBlocks() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 2)
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 8, initialTokens: 4)
        let wrongConversationHandle = PagedKVBlockTableHandle(
            id: handle.id,
            conversationKey: "conv:b",
            poolEpoch: handle.poolEpoch
        )

        await XCTAssertThrowsErrorAsync {
            try await allocator.release(wrongConversationHandle)
        }
        let freeAfterMismatchedRelease = await allocator.freeBlockCount()
        XCTAssertEqual(freeAfterMismatchedRelease, 0)
        let table = try await allocator.table(for: handle)
        XCTAssertEqual(table.logicalTokenCount, 4)

        try await allocator.release(handle)
        let freeAfterRelease = await allocator.freeBlockCount()
        XCTAssertEqual(freeAfterRelease, 2)
    }

    func testAllocatorRejectsWrongEpochHandleAcrossOperations() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 2, poolEpoch: 7)
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 8, initialTokens: 4)
        let wrongEpochHandle = PagedKVBlockTableHandle(
            id: handle.id,
            conversationKey: "conv:a",
            poolEpoch: handle.poolEpoch + 1
        )

        await XCTAssertThrowsErrorAsync { _ = try await allocator.validate(wrongEpochHandle) }
        await XCTAssertThrowsErrorAsync { _ = try await allocator.binding(for: wrongEpochHandle) }
        await XCTAssertThrowsErrorAsync { _ = try await allocator.extend(wrongEpochHandle, by: 1) }
        await XCTAssertThrowsErrorAsync { _ = try await allocator.trim(wrongEpochHandle, toLogicalTokens: 2) }
        await XCTAssertThrowsErrorAsync { try await allocator.beginDecodeStep(wrongEpochHandle) }
        await XCTAssertThrowsErrorAsync { try await allocator.endDecodeStep(wrongEpochHandle) }
        await XCTAssertThrowsErrorAsync { _ = try await allocator.retain(wrongEpochHandle) }
        await XCTAssertThrowsErrorAsync { try await allocator.release(wrongEpochHandle) }

        let retained = try await allocator.retain(handle)
        let wrongEpochRetained = PagedKVRetainedSequence(
            handle: wrongEpochHandle,
            conversationKey: "conv:a",
            logicalTokenCount: retained.logicalTokenCount
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await allocator.reattach(wrongEpochRetained, conversationKey: "conv:a")
        }
        await XCTAssertThrowsErrorAsync {
            try await allocator.discardRetained(wrongEpochRetained, conversationKey: "conv:a")
        }

        let reattached = try await allocator.reattach(retained, conversationKey: "conv:a")
        try await allocator.release(reattached)
        let freeAfterRelease = await allocator.freeBlockCount()
        XCTAssertEqual(freeAfterRelease, 2)
    }

    func testMaterializerRejectsMalformedTablesBeforeAllocation() {
        let duplicateBlocks = PagedKVBlockTable(
            handleID: UUID(),
            blockSizeTokens: 4,
            logicalTokenCount: 5,
            physicalBlocks: [1, 1],
            tailValidTokenCount: 1,
            poolEpoch: 1
        )
        XCTAssertThrowsError(
            try PagedKVMaterializer.materialize(
                table: duplicateBlocks,
                physicalBlocks: [1: Data(repeating: 0, count: 4)],
                bytesPerToken: 1
            )
        )

        let mismatchedLength = PagedKVBlockTable(
            handleID: UUID(),
            blockSizeTokens: 4,
            logicalTokenCount: 5,
            physicalBlocks: [1],
            tailValidTokenCount: 1,
            poolEpoch: 1
        )
        XCTAssertThrowsError(
            try PagedKVMaterializer.materialize(
                table: mismatchedLength,
                physicalBlocks: [1: Data(repeating: 0, count: 4)],
                bytesPerToken: 1
            )
        )

        let wrongTail = PagedKVBlockTable(
            handleID: UUID(),
            blockSizeTokens: 4,
            logicalTokenCount: 5,
            physicalBlocks: [1, 2],
            tailValidTokenCount: 4,
            poolEpoch: 1
        )
        XCTAssertThrowsError(
            try PagedKVMaterializer.materialize(
                table: wrongTail,
                physicalBlocks: [
                    1: Data(repeating: 0, count: 4),
                    2: Data(repeating: 0, count: 4),
                ],
                bytesPerToken: 1
            )
        )

        let overflowing = PagedKVBlockTable(
            handleID: UUID(),
            blockSizeTokens: 4,
            logicalTokenCount: Int.max,
            physicalBlocks: [],
            tailValidTokenCount: 1,
            poolEpoch: 1
        )
        XCTAssertThrowsError(
            try PagedKVMaterializer.materialize(
                table: overflowing,
                physicalBlocks: [:],
                bytesPerToken: 2
            )
        )
    }
}

private struct EmptyContiguousCacheBridge: PagedKVContiguousCacheBridge {
    func materializeContiguousByteCache(
        handle: PagedKVBlockTableHandle,
        table: PagedKVBlockTable
    ) throws -> PagedKVMaterializedByteCache {
        PagedKVMaterializedByteCache(
            handle: handle,
            blockTable: table,
            layers: [
                PagedKVMaterializedByteLayer(
                    layerIndex: 0,
                    keyShape: [1, 1, table.logicalTokenCount, 2],
                    valueShape: [1, 1, table.logicalTokenCount, 2],
                    dtype: .fp16,
                    logicalTokenCount: table.logicalTokenCount,
                    keyBytes: Data(repeating: 0, count: table.logicalTokenCount * 4),
                    valueBytes: Data(repeating: 0, count: table.logicalTokenCount * 4)
                ),
            ]
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        // expected
    }
}
