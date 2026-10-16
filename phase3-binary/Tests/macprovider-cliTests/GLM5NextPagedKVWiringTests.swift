import Foundation
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-039 v0.1.17/v0.1.18 `glm5_next` provider wiring that needs no Metal:
/// cache-kind recognition, the flattened-token cap, the family block size,
/// the allowlist entry, the measured topology, and the attach probe span.
final class GLM5NextPagedKVWiringTests: XCTestCase {
    typealias CacheKind = PagedKVSharedForwardBackend.CacheKind

    /// The admitted artifact's `text_config.layer_types`: 45 layers, sparse at
    /// 3, 7, ..., 43 (11 sparse, 34 KDA), `index_topk` 2048, `index_kpool` 4.
    static let layerTypes: [String] = (0 ..< 45).map {
        $0 % 4 == 3 ? "deepseek_sparse_attention" : "linear_attention"
    }

    static func config(
        architectures: [String] = ["Glm5NextForConditionalGeneration"],
        modelType: String = "glm5_next",
        textModelType: String = "glm5_next_text",
        layerTypes: [String] = GLM5NextPagedKVWiringTests.layerTypes,
        indexTopk: Int = 2048,
        indexKpool: Int = 4
    ) -> Data {
        let object: [String: Any] = [
            "model_type": modelType,
            "architectures": architectures,
            "text_config": [
                "model_type": textModelType,
                "num_hidden_layers": layerTypes.count,
                "layer_types": layerTypes,
                "index_topk": indexTopk,
                "index_kpool": indexKpool,
                "n_routed_experts": 288,
                "num_experts_per_tok": 8,
            ] as [String: Any],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testLayoutFixtureMatchesTheAdmittedArtifactCounts() {
        XCTAssertEqual(Self.layerTypes.filter { $0 == "deepseek_sparse_attention" }.count, 11)
        XCTAssertEqual(Self.layerTypes.filter { $0 == "linear_attention" }.count, 34)
    }

    func testGLM5NextLatentCacheIsRecognizedAsPagedMLAWithItsPoolWidth() {
        XCTAssertEqual(CacheKind.recognized(from: GLM5NextAttentionCache(kpool: 4)), .pagedMLA(kpool: 4))
        XCTAssertEqual(CacheKind.recognized(from: GLM5NextAttentionCache(kpool: 2)), .pagedMLA(kpool: 2))
        XCTAssertTrue(CacheKind.pagedMLA(kpool: 4).usesPagedKVCache)
        XCTAssertTrue(CacheKind.pagedMLA(kpool: 4).isPagedMLA)
        XCTAssertFalse(CacheKind.pagedMLA(kpool: 4).hasSlidingWindow)
        XCTAssertEqual(
            CacheKind.kinds(from: [MambaCache(), GLM5NextAttentionCache(kpool: 4)]),
            [.recurrentMamba, .pagedMLA(kpool: 4)]
        )
    }

    func testPagedMLAForwardsCarryAtMostEightFlattenedTokens() {
        XCTAssertEqual(PagedKVSharedForwardBackend.pagedMLAMaxFlattenedTokensPerForward, 8)
        XCTAssertEqual(
            PagedKVSharedForwardBackend.maxFlattenedTokensPerForward(cacheKinds: [.recurrentMamba, .pagedMLA(kpool: 4)]),
            8
        )
        XCTAssertNil(PagedKVSharedForwardBackend.maxFlattenedTokensPerForward(cacheKinds: [.recurrentMamba, .pagedAttention]))
        XCTAssertNil(PagedKVSharedForwardBackend.maxFlattenedTokensPerForward(cacheKinds: [.slidingWindow(windowTokens: 128)]))
        // Depth 2..4 verification rows (width 3) split at 8 tokens.
        XCTAssertEqual(PagedKVSharedForwardBackend.verifyGroups(widths: [3, 3, 3, 3], maxTokens: 8), [0 ..< 2, 2 ..< 4])
        XCTAssertEqual(PagedKVSharedForwardBackend.verifyGroups(widths: [2, 2, 2, 2], maxTokens: 8), [0 ..< 4])
        XCTAssertEqual(PagedKVSharedForwardBackend.verifyGroups(widths: [5, 1, 1], maxTokens: 8), [0 ..< 1, 1 ..< 3])
    }

    func testGLM5NextDefaultsToA256TokenBlock() {
        let unset = PagedKVConfig(enabled: true)
        let glm = unset.withFamilyDefaults(modelFamily: "glm5_next")
        XCTAssertEqual(glm.blockSizeTokens, 256)
        // FR-PKV2: an unset pool keeps at least 1024 blocks.
        XCTAssertEqual(glm.maxPhysicalBlocks, PagedKVConfig.defaultMaxPhysicalBlocks)
        XCTAssertEqual(unset.withFamilyDefaults(modelFamily: "qwen"), unset)

        let explicitBlock = PagedKVConfig(enabled: true, blockSizeTokens: 128, blockSizeTokensExplicit: true)
        XCTAssertEqual(explicitBlock.withFamilyDefaults(modelFamily: "glm5_next"), explicitBlock)

        let explicitBlocks = PagedKVConfig(enabled: true, maxPhysicalBlocks: 10, maxPhysicalBlocksExplicit: true)
        let pinned = explicitBlocks.withFamilyDefaults(modelFamily: "glm5_next")
        XCTAssertEqual(pinned.blockSizeTokens, 256)
        XCTAssertEqual(pinned.maxPhysicalBlocks, 10)

        // Context coverage is applied after the family block size.
        XCTAssertEqual(glm.sizedToCover(contextTokens: 65_536).maxPhysicalBlocks, 1024)
        XCTAssertEqual(glm.sizedToCover(contextTokens: 1_048_576).maxPhysicalBlocks, 4096)
    }

    func testResolverMarksAnOperatorBlockSizeExplicit() {
        let fromEnv = PagedKVConfigResolver.resolve(
            yaml: nil,
            environment: ["MACPROVIDER_PAGED_KV_BLOCK_SIZE_TOKENS": "64"]
        )
        XCTAssertTrue(fromEnv.blockSizeTokensExplicit)
        XCTAssertEqual(fromEnv.withFamilyDefaults(modelFamily: "glm5_next").blockSizeTokens, 64)
        let fromCLI = PagedKVConfigResolver.resolve(yaml: nil, environment: [:], cli: PagedKVCLIOverrides(blockSizeTokens: 32))
        XCTAssertTrue(fromCLI.blockSizeTokensExplicit)
        let unset = PagedKVConfigResolver.resolve(yaml: nil, environment: [:])
        XCTAssertFalse(unset.blockSizeTokensExplicit)
        let invalid = PagedKVConfigResolver.resolve(
            yaml: nil,
            environment: ["MACPROVIDER_PAGED_KV_BLOCK_SIZE_TOKENS": "0"]
        )
        XCTAssertFalse(invalid.blockSizeTokensExplicit)
    }

    func testAttachGateFailsClosedOnABlockThatSplitsAPoolWindow() {
        func decide(blockSize: Int) -> PagedKVAttachDecision {
            PagedKVAttachGate.decide(
                config: PagedKVConfig(enabled: true, blockSizeTokens: blockSize),
                runtimeCacheClass: "mixed",
                kvBits: nil,
                modelID: "zai-org/glm-5.3-flash",
                modelSHA256: "abc",
                tokenizerSHA256: nil,
                chatTemplateSHA256: nil,
                modelFamily: "glm5_next",
                requiresMoEDispatch: true,
                hybridDecoderArchitectureVerified: true,
                blockSizeMultiple: 4,
                gates: .closed
            )
        }
        XCTAssertEqual(decide(blockSize: 258), .fallback(.allocator))
        XCTAssertNotEqual(decide(blockSize: 256), .fallback(.allocator))
    }

    func testCatalogIdentityCarriesTheVerifiedSparseLayout() throws {
        let capabilities = ModelRuntime.pagedKVModelCapabilities(
            modelID: "zai-org/glm-5.3-flash",
            configJSONData: Self.config()
        )
        XCTAssertEqual(capabilities.modelFamily, "glm5_next")
        XCTAssertTrue(capabilities.requiresMoEDispatch)
        XCTAssertTrue(capabilities.hybridDecoderArchitectureVerified)
        let layout = try XCTUnwrap(capabilities.sparseAttention)
        XCTAssertEqual(layout.indexTopk, 2048)
        XCTAssertEqual(layout.indexKpool, 4)
        XCTAssertEqual(layout.expectedCacheKinds.count, 45)
        XCTAssertTrue(PagedKVAttachGate.recognizedModelFamilies.contains("glm5_next"))
        XCTAssertTrue(PagedKVAttachGate.supportsCacheClass("mixed", hybridDecoderArchitectureVerified: true))
    }

    func testOtherGLM5NextConfigsFailClosed() {
        func verified(_ modelID: String, _ data: Data) -> Bool {
            ModelRuntime.pagedKVModelCapabilities(modelID: modelID, configJSONData: data).hybridDecoderArchitectureVerified
        }
        XCTAssertFalse(verified("Jundot/GLM-5.3-Flash-oQ4e-mtp", Self.config()))
        XCTAssertFalse(verified("zai-org/glm-5.3-flash", Self.config(
            architectures: ["Glm5NextForConditionalGeneration", "Other"])))
        XCTAssertFalse(verified("zai-org/glm-5.3-flash", Self.config(modelType: "glm5")))
        XCTAssertFalse(verified("zai-org/glm-5.3-flash", Self.config(textModelType: "glm5_next")))
        XCTAssertFalse(verified("zai-org/glm-5.3-flash", Self.config(
            layerTypes: Self.layerTypes.map { $0 == "linear_attention" ? "full_attention" : $0 })))
        XCTAssertFalse(verified("zai-org/glm-5.3-flash", Self.config(indexKpool: 0)))
        XCTAssertFalse(verified("zai-org/glm-5.3-flash", Self.config(indexTopk: 0)))
    }

    func testMeasuredTopologyIsExactlyOneCachePerLayerWithThePoolWidth() {
        let capabilities = ModelRuntime.pagedKVModelCapabilities(
            modelID: "zai-org/glm-5.3-flash",
            configJSONData: Self.config()
        )
        let expected: [CacheKind] = Self.layerTypes.map {
            $0 == "deepseek_sparse_attention" ? .pagedMLA(kpool: 4) : .recurrentMamba
        }
        XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(expected, modelCapabilities: capabilities))
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(
            expected.map { $0 == .pagedMLA(kpool: 4) ? .pagedMLA(kpool: 2) : $0 },
            modelCapabilities: capabilities
        ))
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(Array(expected.dropLast()), modelCapabilities: capabilities))
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(expected.reversed(), modelCapabilities: capabilities))
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(
            expected.map { $0 == .pagedMLA(kpool: 4) ? .pagedAttention : $0 },
            modelCapabilities: capabilities
        ))
        // A Qwen hybrid never admits a pagedMLA layer.
        let qwen = PagedKVRuntimeModelCapabilities(
            modelFamily: "qwen", requiresMoEDispatch: false, hybridDecoderArchitectureVerified: true
        )
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(
            [.recurrentMamba, .pagedAttention, .pagedMLA(kpool: 4)], modelCapabilities: qwen
        ))
    }

    func testAttachProbeSpansIndexTopkPlusTwoBlocks() {
        let glm = ModelRuntime.pagedKVModelCapabilities(
            modelID: "zai-org/glm-5.3-flash",
            configJSONData: Self.config()
        )
        XCTAssertEqual(glm.attachProbePromptTokens(blockSizeTokens: 256), 2560)
        XCTAssertEqual(glm.attachProbePromptTokens(blockSizeTokens: 16), 2080)
        let qwen = PagedKVRuntimeModelCapabilities(modelFamily: "qwen", requiresMoEDispatch: false)
        XCTAssertEqual(qwen.attachProbePromptTokens(blockSizeTokens: 256), 513)
        // The paged run's forwards: four leading 512-token chunks, then one per token.
        XCTAssertEqual(PagedKVRuntimeParityProbe.prefillChunkForwards(promptTokens: 2560), 4)
        XCTAssertEqual(PagedKVRuntimeParityProbe.prefillChunkForwards(promptTokens: 513), 1)
        XCTAssertEqual(PagedKVRuntimeParityProbe.prefillChunkForwards(promptTokens: 512), 0)
        XCTAssertEqual(PagedKVRuntimeParityProbeResult(
            established: true, nLayers: 11, nNew: 32, gatherKernelCalls: 0, maxLogicalBlocks: 0,
            nonIdentityPermutation: false
        ).nForwards, 32)
    }

    func testGLM5NextParityLabelNeverSharesTheSDPALabel() {
        XCTAssertEqual(ModelRuntime.pagedKVParityLabelSuffix(modelFamily: "glm5_next"), "glm5-next-mla-parity-v1")
        XCTAssertEqual(ModelRuntime.pagedKVParityLabelSuffix(modelFamily: "qwen"), "sdpa-parity-v1")
        XCTAssertEqual(ModelRuntime.pagedKVParityLabelSuffix(modelFamily: "gpt_oss"), "sdpa-parity-v1")
    }

    func testPagedMLABlockMustHoldWholePoolWindows() {
        XCTAssertTrue(PagedMLALatentCache.blockSizeIsValid(256, kpool: 4))
        XCTAssertFalse(PagedMLALatentCache.blockSizeIsValid(258, kpool: 4))
        XCTAssertFalse(PagedMLALatentCache.blockSizeIsValid(2, kpool: 4))
        XCTAssertFalse(PagedMLALatentCache.blockSizeIsValid(256, kpool: 0))
    }

    func testSelfCheckKeyChangesWithTheFlattenedTokenCap() {
        let plain = ModelRuntime.continuousBatchingSelfCheckRuntimeBuild(forwardBound: 11, routeKeyBoundary: 1024)
        let glm = ModelRuntime.continuousBatchingSelfCheckRuntimeBuild(
            forwardBound: 11, routeKeyBoundary: 1024, forwardTokenCap: 8
        )
        XCTAssertNotEqual(plain, glm)
        XCTAssertTrue(glm.contains("/decode8/verify8"))
        XCTAssertTrue(glm.hasSuffix("+flat8"))
        XCTAssertNotEqual(glm, ModelRuntime.continuousBatchingSelfCheckRuntimeBuild(
            forwardBound: 11, routeKeyBoundary: 1024, forwardTokenCap: 6
        ))
        // A device bound below the cap still records the cap.
        XCTAssertNotEqual(
            ModelRuntime.continuousBatchingSelfCheckRuntimeBuild(forwardBound: 5, routeKeyBoundary: 1024),
            ModelRuntime.continuousBatchingSelfCheckRuntimeBuild(forwardBound: 5, routeKeyBoundary: 1024, forwardTokenCap: 8)
        )
        XCTAssertEqual(plain, ModelRuntime.continuousBatchingSelfCheckRuntimeBuild(forwardBound: 11, routeKeyBoundary: 1024))
    }
}
