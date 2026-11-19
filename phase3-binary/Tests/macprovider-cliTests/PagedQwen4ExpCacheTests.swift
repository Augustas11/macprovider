import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-039 `qwen4_exp` (Qwen3.8-Flash-Next, #2409): the attach gate and
/// verified layout of the exact identity, the `pagedQwen4ExpKV` cache kind
/// (`PagedQwen4ExpSparseCache` holds bit for bit what the stock
/// `Qwen4ExpAttentionCache` holds), the four-slot PLE recurrent layout with
/// its integer n-gram slot, the scheduler rules, and batched-vs-alone token
/// exactness on a tiny random-weight model.
final class PagedQwen4ExpCacheTests: XCTestCase {
    typealias CacheKind = PagedKVSharedForwardBackend.CacheKind

    override class func setUp() {
        super.setUp()
        MLXTestDevice.pinProcessCPUDefaultWithoutMetallib()
    }

    private static let modelID = "latent-variable/Qwen3.8-Flash-Next-heretic-2-oQ4e-mtp"
    private static let modelSHA = String(repeating: "a", count: 64)
    private static let pagedConfig = PagedKVConfig(enabled: true, blockSizeTokens: 256, maxPhysicalBlocks: 64)

    /// The admitted artifact's layout: 48 layers, QSA full attention every
    /// fourth, one PLE layer (`ple_layer_ids` [2], decoder index 1).
    private static let layerTypes48: [String] = (0 ..< 48).map {
        ($0 + 1).isMultiple(of: 4) ? "full_attention" : "linear_attention"
    }
    private static let kinds48: [CacheKind] = layerTypes48.map {
        $0 == "full_attention" ? .pagedQwen4ExpKV : .recurrentMamba
    }

    private static func config(
        architectures: [String] = ["Qwen4ExpForConditionalGeneration"],
        modelType: String = "qwen4_exp",
        textModelType: String = "qwen4_exp_text",
        layerTypes: [String] = layerTypes48,
        pleLayerIDs: [Int] = [2],
        indexerBudget: Int = 2048,
        quantized: Bool = true
    ) -> Data {
        let text: [String: Any] = [
            "model_type": textModelType,
            "num_hidden_layers": layerTypes.count,
            "full_attention_interval": 4,
            "layer_types": layerTypes,
            "ple_layer_ids": pleLayerIDs,
            "indexer_budget": indexerBudget,
            "indexer_compress_ratio": 4,
            "indexer_kv_heads": 1,
            "num_experts": 512,
            "num_experts_per_tok": 10,
            "moe_intermediate_size": 512,
        ]
        var object: [String: Any] = ["model_type": modelType, "architectures": architectures, "text_config": text]
        if quantized {
            object["quantization"] = [
                "group_size": 64, "bits": 4, "mode": "affine",
                "language_model.lm_head": ["bits": 8, "group_size": 64, "mode": "affine"],
            ] as [String: Any]
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static func capabilities(_ data: Data = config(), modelID: String = modelID) -> PagedKVRuntimeModelCapabilities {
        ModelRuntime.pagedKVModelCapabilities(modelID: modelID, configJSONData: data)
    }

    // MARK: - Attach gate and layout (no Metal)

    func testAllowlistedIdentityCarriesTheVerifiedLayout() throws {
        let capabilities = Self.capabilities()
        XCTAssertEqual(capabilities.modelFamily, "qwen4_exp")
        XCTAssertTrue(capabilities.requiresMoEDispatch)
        XCTAssertTrue(capabilities.hybridDecoderArchitectureVerified)
        let layout = try XCTUnwrap(capabilities.qwen4ExpAttention)
        XCTAssertEqual(layout.pleLayers, [1])
        XCTAssertEqual(layout.expectedCacheKinds, Self.kinds48)
        XCTAssertEqual(capabilities.recurrentStateLayout, .qwen4ExpPLEFourSlot(pleLayers: [1]))
        XCTAssertTrue(capabilities.hasIndexedSparseAttention)
        // The proof prompt passes the 2048-token indexer budget.
        XCTAssertEqual(capabilities.attachProbePromptTokens(blockSizeTokens: 256), 2048 + 512)
        XCTAssertTrue(PagedKVAttachGate.recognizedModelFamilies.contains("qwen4_exp"))
        XCTAssertEqual(ModelRuntime.pagedKVParityLabelSuffix(modelFamily: "qwen4_exp"), "qwen4-exp-qsa-indexed-kv-parity-v1")
    }

    func testMeasuredTopologyRequiresTheExactLayerLayout() throws {
        let admitted = Self.capabilities()
        XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(Self.kinds48, modelCapabilities: admitted))
        var swapped = Self.kinds48
        swapped.swapAt(2, 3)
        let mismatches: [(String, [CacheKind])] = [
            ("layer order", swapped),
            ("dropped layer", Array(Self.kinds48.dropLast())),
            ("stock attention", Self.kinds48.map { $0 == .pagedQwen4ExpKV ? .pagedAttention : $0 }),
            ("MiniMax indexed", Self.kinds48.map { $0 == .pagedQwen4ExpKV ? .pagedIndexedKV : $0 }),
        ]
        for (label, kinds) in mismatches {
            XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(kinds, modelCapabilities: admitted), label)
        }
        // The layout without its four-slot recurrent state is not the measured topology.
        let twoSlot = PagedKVRuntimeModelCapabilities(
            modelFamily: "qwen4_exp", requiresMoEDispatch: true, hybridDecoderArchitectureVerified: true,
            qwen4ExpAttention: admitted.qwen4ExpAttention
        )
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(Self.kinds48, modelCapabilities: twoSlot))
        let noLayout = PagedKVRuntimeModelCapabilities(
            modelFamily: "qwen4_exp", requiresMoEDispatch: true, hybridDecoderArchitectureVerified: true,
            recurrentStateLayout: .qwen4ExpPLEFourSlot(pleLayers: [1])
        )
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(Self.kinds48, modelCapabilities: noLayout))
        // A Qwen hybrid never admits a QSA layer.
        let qwen = PagedKVRuntimeModelCapabilities(
            modelFamily: "qwen", requiresMoEDispatch: false, hybridDecoderArchitectureVerified: true
        )
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(Self.kinds48, modelCapabilities: qwen))
    }

    func testOtherIdentitiesAndLayoutsFailClosed() {
        func verified(_ data: Data, modelID: String = Self.modelID) -> Bool {
            Self.capabilities(data, modelID: modelID).hybridDecoderArchitectureVerified
        }
        XCTAssertTrue(verified(Self.config()))
        for unlisted in ["qwen/qwen3.8-flash-next", "mlx-community/Qwen3.8-Flash-Next-4bit", "/Users/x/models/qwen4"] {
            XCTAssertFalse(verified(Self.config(), modelID: unlisted), unlisted)
        }
        var fullAtFirst = Self.layerTypes48
        fullAtFirst[0] = "full_attention"
        let wrong: [(String, Data)] = [
            ("architectures", Self.config(architectures: ["Qwen4ExpForConditionalGeneration", "Other"])),
            ("model type", Self.config(modelType: "qwen4_exp_text")),
            ("text model type", Self.config(textModelType: "qwen3_5_text")),
            ("layer types", Self.config(layerTypes: fullAtFirst)),
            ("PLE on a full-attention layer", Self.config(pleLayerIDs: [4])),
            ("no PLE layer", Self.config(pleLayerIDs: [])),
            ("PLE id out of range", Self.config(pleLayerIDs: [49])),
            ("no indexer budget", Self.config(indexerBudget: 0)),
        ]
        for (label, data) in wrong {
            XCTAssertFalse(verified(data), label)
        }
    }

    func testAttachGateAdmitsOnlyTheVerifiedLayout() {
        let gates = PagedKVGates(
            identityAvailable: true, metallibAvailable: false, kernelRegistered: false, parityEstablished: false
        )
        func reason(_ capabilities: PagedKVRuntimeModelCapabilities, cacheClass: String = "mixed") -> PagedKVFallbackReason? {
            ModelRuntime.pagedKVAttachDecision(
                config: Self.pagedConfig, modelID: Self.modelID, modelHash: Self.modelSHA,
                tokenizerSHA256: nil, chatTemplateSHA256: nil, kvBitsOverride: nil,
                runtimeCacheClass: cacheClass, gates: gates, modelCapabilities: capabilities
            ).reason
        }
        // Past identity and cache class, stopped at the metallib gate.
        XCTAssertEqual(reason(Self.capabilities()), .metallib)
        // An unknown layout is an unverified mixed class.
        XCTAssertEqual(reason(Self.capabilities(Self.config(pleLayerIDs: [4]))), .cacheClass)
        XCTAssertEqual(reason(Self.capabilities(Self.config(), modelID: "qwen/qwen3.8-flash-next")), .cacheClass)
    }

    func testCachesAreRecognized() throws {
        XCTAssertEqual(CacheKind.recognized(from: Qwen4ExpAttentionCache()), .pagedQwen4ExpKV)
        XCTAssertEqual(CacheKind.recognized(from: ArraysCache(size: 4)), .recurrentMamba)
        XCTAssertEqual(CacheKind.recognized(from: MambaCache()), .recurrentMamba)
        XCTAssertNil(CacheKind.recognized(from: Qwen4ExpAttentionCacheBatch(rowCaches: [Qwen4ExpAttentionCache()])))
        XCTAssertTrue(CacheKind.pagedQwen4ExpKV.usesPagedKVCache)
        XCTAssertTrue(CacheKind.pagedQwen4ExpKV.isPagedIndexedKV)
        XCTAssertFalse(CacheKind.pagedQwen4ExpKV.isPagedMLA)
        XCTAssertEqual(
            CacheKind.kinds(from: [MambaCache(), ArraysCache(size: 4), MambaCache(), Qwen4ExpAttentionCache()]),
            [.recurrentMamba, .recurrentMamba, .recurrentMamba, .pagedQwen4ExpKV]
        )
        XCTAssertEqual(PagedKVSharedForwardBackend.maxFlattenedTokensPerForward(cacheKinds: Self.kinds48), 8)
    }

    // MARK: - Scheduler rules (no Metal)

    /// The quantized MoE config groups prefill chunks by the sorted-gather
    /// bound (512 experts x 4 selections over top-10: 205 tokens).
    func testPrefillGroupingIsTheSortedGatherMoERule() {
        let rule = ContinuousBatchPrefillGroupingRule.fromModelConfiguration(Self.config(), modelID: Self.modelID)
        XCTAssertEqual(rule, .sortedGatherMoE(numExperts: 512, topK: 10))
        XCTAssertEqual(rule.minimumGroupedChunkTokens, 205)
        XCTAssertEqual(
            ContinuousBatchPrefillGroupingRule.fromModelConfiguration(Self.config(quantized: false), modelID: Self.modelID),
            .ungrouped
        )
    }

    // MARK: - Four-slot PLE recurrent layout

    func testFourSlotLayoutIsExactlyThePLELayers() {
        let layout = PagedKVRecurrentStateLayout.qwen4ExpPLEFourSlot(pleLayers: [1])
        XCTAssertEqual(layout.slotCount(layer: 0), 2)
        XCTAssertEqual(layout.slotCount(layer: 1), 4)
        XCTAssertEqual(layout.slotCount(layer: 2), 2)
        XCTAssertEqual(layout.integerSlots(layer: 1), [3])
        XCTAssertEqual(layout.integerSlots(layer: 0), [])
        XCTAssertTrue(layout.makeRecurrentCache(layer: 0) is MambaCache)
        let ple = layout.makeRecurrentCache(layer: 1)
        XCTAssertTrue(type(of: ple) == ArraysCache.self)
        XCTAssertEqual(PagedKVRecurrentStateLayout.mambaTwoSlot.slotCount(layer: 1), 2)
    }

    func testCheckpointLayoutCarriesTheIntegerSlotExactly() {
        let layout = PagedKVRecurrentStateLayout.qwen4ExpPLEFourSlot(pleLayers: [1])
        let mamba = [
            RecurrentStateSlotLayout(shape: [1, 3, 96], dtype: .bfloat16),
            RecurrentStateSlotLayout(shape: [1, 2, 16, 32], dtype: .float32),
        ]
        let ple = mamba + [
            RecurrentStateSlotLayout(shape: [1, 6, 64], dtype: .bfloat16),
            RecurrentStateSlotLayout(shape: [1, 2], dtype: .int32),
        ]
        func valid(_ layouts: [Int: [RecurrentStateSlotLayout]], _ stateLayout: PagedKVRecurrentStateLayout = layout) -> Bool {
            PagedKVSharedForwardBackend.recurrentCheckpointLayoutIsValid(
                layouts, recurrentLayerIndices: [0, 1, 2], stateLayout: stateLayout
            )
        }
        XCTAssertTrue(valid([0: mamba, 1: ple, 2: mamba]))
        var floatHistory = ple
        floatHistory[3] = RecurrentStateSlotLayout(shape: [1, 2], dtype: .float32)
        var intConv = ple
        intConv[0] = RecurrentStateSlotLayout(shape: [1, 3, 96], dtype: .int32)
        var otherShape = mamba
        otherShape[0] = RecurrentStateSlotLayout(shape: [1, 4, 96], dtype: .bfloat16)
        var twoRows = ple
        twoRows[3] = RecurrentStateSlotLayout(shape: [2, 2], dtype: .int32)
        let invalid: [(String, [Int: [RecurrentStateSlotLayout]])] = [
            ("float n-gram history", [0: mamba, 1: floatHistory, 2: mamba]),
            ("integer conv state", [0: mamba, 1: intConv, 2: mamba]),
            ("PLE layer with two slots", [0: mamba, 1: mamba, 2: mamba]),
            ("deltanet layer with four slots", [0: ple, 1: ple, 2: mamba]),
            ("deltanet layers differ", [0: mamba, 1: ple, 2: otherShape]),
            ("two-row history", [0: mamba, 1: twoRows, 2: mamba]),
            ("missing layer", [0: mamba, 1: ple]),
        ]
        for (label, layouts) in invalid {
            XCTAssertFalse(valid(layouts), label)
        }
        // The two-slot default never admits the four-slot layer.
        XCTAssertFalse(valid([0: mamba, 1: ple, 2: mamba], .mambaTwoSlot))
    }

    /// Packing PLE rows and syncing them back keeps every slot, the integer
    /// n-gram history bit for bit (values across the int32 range), and a
    /// fresh row joins with the all-zero state the model reads as a prompt
    /// start.
    func testFourSlotPackAndSyncRoundTripIsBitExact() throws {
        try requireMetal()
        let layout = PagedKVRecurrentStateLayout.qwen4ExpPLEFourSlot(pleLayers: [1])
        let histories: [[Int32]] = [[Int32.max, -7], [Int32.min, 248_044]]
        func row(_ index: Int) -> ArraysCache {
            let cache = layout.makeRecurrentCache(layer: 1)
            let base = Float(index * 100)
            cache[0] = MLXArray((0 ..< 6).map { base + Float($0) }, [1, 2, 3]).asType(.bfloat16)
            cache[1] = MLXArray((0 ..< 4).map { base + 0.5 + Float($0) }, [1, 1, 2, 2])
            cache[2] = MLXArray((0 ..< 4).map { base + 0.25 + Float($0) }, [1, 2, 2]).asType(.bfloat16)
            cache[3] = MLXArray(histories[index], [1, 2])
            return cache
        }
        let rows = [row(0), row(1), layout.makeRecurrentCache(layer: 1)]
        let originals = rows.prefix(2).map { $0.state.map { $0[.ellipsis] } }
        let batch = layout.makeRecurrentCache(layer: 1)
        try PagedKVSharedForwardBackend.packMambaRows(rows, into: batch, stateLayout: layout, layer: 1)
        eval(batch.state)
        XCTAssertEqual(batch.state.count, 4)
        XCTAssertEqual(batch.state.map(\.dtype), [.bfloat16, .float32, .bfloat16, .int32])
        XCTAssertEqual(batch.state[3].shape, [3, 2])
        XCTAssertEqual(batch.state[3].asArray(Int32.self), [Int32.max, -7, Int32.min, 248_044, 0, 0])

        PagedKVSharedForwardBackend.syncMambaRows(from: batch, into: rows, stateLayout: layout, layer: 1)
        for (index, original) in originals.enumerated() {
            let synced = rows[index].state
            XCTAssertEqual(synced.count, 4)
            for (slot, (a, b)) in zip(synced, original).enumerated() {
                XCTAssertEqual(a.dtype, b.dtype, "row \(index) slot \(slot)")
                XCTAssertEqual(a.shape, b.shape, "row \(index) slot \(slot)")
                XCTAssertTrue(all(a .== b).item(Bool.self), "row \(index) slot \(slot)")
            }
        }
        XCTAssertEqual(rows[2].state[3].asArray(Int32.self), [0, 0])

        // A row whose n-gram history has another dtype is not packed.
        let mismatched = row(0)
        mismatched[3] = MLXArray([Int64(1), Int64(2)], [1, 2])
        XCTAssertThrowsError(try PagedKVSharedForwardBackend.packMambaRows(
            [row(1), mismatched], into: layout.makeRecurrentCache(layer: 1), stateLayout: layout, layer: 1
        ))
        // A two-slot row is not a PLE row.
        let twoSlot = MambaCache()
        twoSlot[0] = MLXArray([Float(1)], [1, 1, 1])
        twoSlot[1] = MLXArray([Float(2)], [1, 1, 1])
        XCTAssertThrowsError(try PagedKVSharedForwardBackend.packMambaRows(
            [row(0), twoSlot], into: layout.makeRecurrentCache(layer: 1), stateLayout: layout, layer: 1
        ))
    }

    // MARK: - Paged cache (Metal)

    private let kvHeads = 2
    private let headDim = 8
    private let indexDim = 4
    private let blockSize = 8

    func testPagedCacheMatchesStockAcrossChunksDecodeAndCopy() throws {
        try requireMetal()
        for gather in [false, true] {
            var rng = SplitMix(seed: 13)
            let paged = makeCache(reconstructViaGather: gather)
            let oracle = Qwen4ExpAttentionCache()
            for length in [5, 12, 1, 1, 9, 1] {
                step(paged, oracle, length: length, rng: &rng, label: "gather=\(gather) len=\(length)")
            }
            XCTAssertEqual(paged.offset, oracle.offset)
            XCTAssertEqual(paged.indexerOffset, oracle.indexerOffset)
            assertStatesEqual(paged.state, oracle.state, "gather=\(gather)")
            let copied = paged.concreteCopy()
            let before = copied.state
            step(paged, oracle, length: 3, rng: &rng, label: "gather=\(gather) after copy")
            XCTAssertEqual(copied.offset, 29)
            assertStatesEqual(copied.state, before, "copy after source advanced")
        }
    }

    func testParityGatherCoversAllThreeBuffersAndTrimKeepsWholeBlocks() throws {
        try requireMetal()
        var rng = SplitMix(seed: 7)
        let paged = makeCache(reconstructViaGather: true)
        PagedKVCache.resetGatherDiagnostics()
        // 21 tokens: 3 blocks of 8. One forward reads K, V and indexer keys.
        step(paged, nil, length: 21, rng: &rng)
        XCTAssertEqual(PagedKVCache.gatherKernelCalls, 3)
        XCTAssertEqual(PagedKVCache.maxLogicalBlocksObserved, 3)
        XCTAssertTrue(PagedKVCache.observedNonIdentityPermutation)
        // One 256-token growth step (`amortizedGrownCapacity`).
        XCTAssertEqual(paged.capacityTokens, 256)
        XCTAssertEqual(paged.trim(14), 14)
        XCTAssertEqual(paged.offset, 7)
        XCTAssertEqual(paged.indexerOffset, 7)
        XCTAssertEqual(paged.capacityTokens, 8)
        XCTAssertEqual(paged.state.map { $0.dim(2) }, [7, 7, 7, 7])
    }

    /// Growth copies the stored history; it grows by whole 256-token steps
    /// (`amortizedGrownCapacity`), so 4096 tokens on 16-token blocks
    /// reallocate 16 times, not once per block (256).
    func testGrowthOverFourThousandTokensIsAmortized() throws {
        try requireMetal()
        var rng = SplitMix(seed: 21)
        let paged = makeCache(blockSizeTokens: 16, maxPhysicalBlocks: 256)
        var reallocations = 0
        var capacity = paged.capacityTokens
        for _ in 0 ..< 4096 / 16 {
            step(paged, nil, length: 16, rng: &rng)
            if paged.capacityTokens != capacity {
                reallocations += 1
                capacity = paged.capacityTokens
            }
            XCTAssertTrue(capacity.isMultiple(of: 16))
        }
        eval(paged.innerState())
        XCTAssertEqual(paged.offset, 4096)
        XCTAssertEqual(paged.indexerOffset, 4096)
        XCTAssertEqual(capacity, 4096)
        XCTAssertLessThanOrEqual(reallocations, 16)
    }

    func testBatchRoutesRowsAndTracksRaggedLengths() throws {
        try requireMetal()
        let rows = [makeCache(), makeCache()]
        let batch = PagedQwen4ExpBatchLayerCache(rowCaches: rows)
        XCTAssertNil(CacheKind.recognized(from: batch))
        XCTAssertEqual(CacheKind.recognized(from: rows[0]), .pagedQwen4ExpKV)
        XCTAssertTrue(batch.rowCaches[1] as AnyObject === rows[1])
        batch.prepare(lengths: [3, 3])
        XCTAssertNil(batch.rowLengths)
        batch.prepare(lengths: [3, 2])
        XCTAssertEqual(batch.rowLengths, [3, 2])
        batch.finalize()
        XCTAssertNil(batch.rowLengths)
    }

    // MARK: - Tiny random-weight model: batched decode equals each row alone

    /// The engine's tiny `qwen4_exp_text` (three gated-delta layers, one QSA
    /// layer, a PLE on layer 2, an 8-token indexer budget in blocks of 2).
    private static let tinyTextConfiguration = """
        {
            "model_type": "qwen4_exp_text", "vocab_size": 64, "hidden_size": 32,
            "num_hidden_layers": 4, "num_attention_heads": 2, "num_key_value_heads": 1,
            "head_dim": 16, "rms_norm_eps": 1e-6, "eos_token_id": 1,
            "rope_parameters": {"rope_theta": 10000, "partial_rotary_factor": 0.5, "type": "default"},
            "num_experts": 4, "num_experts_per_tok": 2, "moe_intermediate_size": 16,
            "shared_expert_intermediate_size": 16,
            "linear_num_key_heads": 2, "linear_num_value_heads": 2,
            "linear_key_head_dim": 32, "linear_value_head_dim": 16,
            "linear_conv_kernel_dim": 4,
            "hc_count": 2, "hc_lowrank": 8,
            "indexer_n_heads": 2, "indexer_kv_heads": 1, "indexer_head_dim": 16,
            "indexer_budget": 8, "indexer_compress_ratio": 2,
            "ngram_size": 3, "heads_per_ngram": 2, "ngram_vocab_size_base": 100,
            "make_ngram_vocab_size_divisible_by": 4, "split_ngram_parts": 4,
            "ple_embed_dim": 8, "ple_layer_ids": [2], "full_attention_interval": 4,
            "layer_types": ["linear_attention", "linear_attention", "linear_attention", "full_attention"],
            "output_gate_type": "sigmoid", "hidden_act": "silu", "tie_word_embeddings": false
        }
        """
    private static let tinyKinds: [CacheKind] = [.recurrentMamba, .recurrentMamba, .recurrentMamba, .pagedQwen4ExpKV]
    private static let tinyLayout = PagedKVRecurrentStateLayout.qwen4ExpPLEFourSlot(pleLayers: [1])
    private static let tinyBlockSizeTokens = 4
    private static let tinyMaxPhysicalBlocks = 1024
    private static let lockstepWindow = ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow

    /// The tiny config passes the same layout gate the 48-layer artifact
    /// does, and the model builds exactly that cache topology.
    func testTinyConfigYieldsTheAdmittedTopology() throws {
        let text = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Self.tinyTextConfiguration.utf8)) as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: [
            "model_type": "qwen4_exp", "architectures": ["Qwen4ExpForConditionalGeneration"], "text_config": text,
        ])
        let capabilities = Self.capabilities(data)
        XCTAssertEqual(capabilities.qwen4ExpAttention?.expectedCacheKinds, Self.tinyKinds)
        XCTAssertEqual(capabilities.recurrentStateLayout, Self.tinyLayout)
        let model = try Self.tinyModel()
        let caches = try model.newCache(parameters: nil)
        XCTAssertEqual(CacheKind.kinds(from: caches), Self.tinyKinds)
        XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(Self.tinyKinds, modelCapabilities: capabilities))
        XCTAssertEqual(try ModelRuntime.pagedKVRuntimeCacheClass(model: model, baseParameters: GenerateParameters()), "mixed")
        for (layer, cache) in caches.enumerated() where Self.tinyKinds[layer] == .recurrentMamba {
            XCTAssertTrue(type(of: cache) == type(of: Self.tinyLayout.makeRecurrentCache(layer: layer)), "layer \(layer)")
        }
    }

    /// The model builds its own attention caches and ignores `maxKVSize`, so the
    /// serve cap reached the iterator's explicit-cache check, which counts the
    /// `Qwen4ExpAttentionCache` layer as not realizing it: the first serial
    /// request of a Flash-Next serve failed with "Inference engine error".
    /// Serve parameters must leave the cache uncapped, and one serial
    /// `TokenIterator` step must run on them.
    func testSerialServeParametersLeaveTheSelfSizedCacheUncapped() throws {
        let model = try Self.tinyModel()
        let cache = try model.newCache(parameters: nil)
        let capped = KVCacheConfiguration(capacity: try KVCacheConfiguration.Capacity(maxTokens: 65_536))
        XCTAssertThrowsError(try validateKVCacheCompatibility(cache, configuration: capped)) { error in
            XCTAssertEqual(error as? KVCacheConfigurationError, .incompatibleCapacity(expected: 65_536, count: 1))
        }
        XCTAssertTrue(ModelRuntime.modelSizesItsOwnKVCache(model))
        XCTAssertTrue(ModelRuntime.modelSizesItsOwnKVCache(Qwen4ExpModel(
            try JSONDecoder().decode(Qwen4ExpConfiguration.self, from: Data(Self.tinyTextConfiguration.utf8))
        )))
        let base = GenerateParameters(maxTokens: 8, maxKVSize: 65_536)
        XCTAssertNil(ModelRuntime.explicitCacheIteratorParameters(base, cache: cache).maxKVSize)
        XCTAssertNil(ModelRuntime.serveIteratorParameters(
            base, forceSimpleKV: false, reusedCache: false, cache: cache
        ).maxKVSize)
        let prompt = Self.tinyPrompt(length: 9, salt: 0)
        let serve = try ModelRuntime.makeServeGenerateParameters(
            model: model, maxTokens: 4, promptTokens: prompt.count, maxContextTokens: 65_536,
            kvBitsOverride: nil, prefillStepSize: 512, temperature: 0, topP: 1
        )
        XCTAssertNil(serve.maxKVSize)

        try requireMetal()
        let iteratorCache = try model.newCache(parameters: serve)
        var iterator = try TokenIterator(
            input: LMInput(tokens: MLXArray(prompt.map(Int32.init))), model: model, cache: iteratorCache,
            parameters: ModelRuntime.explicitCacheIteratorParameters(serve, cache: iteratorCache)
        )
        let first = try XCTUnwrap(iterator.next())
        XCTAssertEqual(first, try Self.runSerial(model: model, prompt: prompt, decodeTokens: 0)[0])
    }

    /// Rows on both sides of the indexer budget, prefilled alone and decoded
    /// together for several lockstep windows at 2 and 8 rows, emit bitwise
    /// the greedy tokens of each row decoded alone on the paged backend and
    /// of the stock serial caches.
    func testBatchedRowsMatchEachRowAloneAndTheSerialCaches() async throws {
        try requireMetal()
        let model = try Self.tinyModel()
        let lengths = [3, 21, 9, 30, 14, 5, 26, 17]
        let prompts = lengths.enumerated().map { Self.tinyPrompt(length: $1, salt: $0) }
        let decodeTokens = 2 * Self.lockstepWindow + 5

        var alone: [[Int]] = []
        for (row, prompt) in prompts.enumerated() {
            let paged = try await Self.runPaged(model: model, prompts: [prompt], decodeTokens: decodeTokens)[0]
            let serial = try Self.runSerial(model: model, prompt: prompt, decodeTokens: decodeTokens)
            XCTAssertEqual(paged.count, decodeTokens + 1, "row \(row)")
            XCTAssertEqual(paged, serial, "row \(row): paged alone differs from the serial caches")
            alone.append(paged)
        }
        for rows in [2, 8] {
            let batched = try await Self.runPaged(model: model, prompts: Array(prompts.prefix(rows)), decodeTokens: decodeTokens)
            for row in 0 ..< rows {
                XCTAssertEqual(batched[row], alone[row], "B=\(rows) row \(row): batched differs from alone")
            }
        }
        XCTAssertGreaterThan(Set(alone.flatMap { $0 }).count, 2, "random weights degenerated to one token")
    }

    private static func tinyModel() throws -> Qwen4ExpTextModel {
        let configuration = try JSONDecoder().decode(Qwen4ExpConfiguration.self, from: Data(tinyTextConfiguration.utf8))
        try configuration.validateModelConfiguration()
        let model = Qwen4ExpTextModel(configuration)
        let parameters = model.parameters().flattened()
        let updated: [(String, MLXArray)] = withRandomState(MLXRandom.RandomState(seed: 2409)) {
            parameters.map { key, value in
                let noise = MLXRandom.normal(value.shape).asType(value.dtype)
                if key.hasSuffix("norm.weight") || key.hasSuffix("layernorm.weight") {
                    return (key, 1 + 0.1 * noise)
                }
                return (key, 0.2 * noise)
            }
        }
        model.update(parameters: ModuleParameters.unflattened(updated))
        eval(model)
        return model
    }

    private static func tinyPrompt(length: Int, salt: Int) -> [Int] {
        var state = UInt64(truncatingIfNeeded: 0x2409 &+ salt)
        return (0 ..< length).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % 64)
        }
    }

    private static func container(_ model: Qwen4ExpTextModel) -> ModelContainer {
        ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: modelID),
            model: model,
            processor: StandInUserInputProcessor(),
            tokenizer: Qwen4ExpTestTokenizer()
        ))
    }

    /// Stock serial greedy decode on the model's own caches.
    private static func runSerial(model: Qwen4ExpTextModel, prompt: [Int], decodeTokens: Int) throws -> [Int] {
        let caches = try model.newCache(parameters: nil)
        var logits = model(MLXArray(prompt.map(Int32.init))[.newAxis], cache: caches)
        var tokens: [Int] = []
        for _ in 0 ... decodeTokens {
            let next = argMax(logits[0, -1], axis: -1).item(Int.self)
            tokens.append(next)
            logits = model(MLXArray([Int32(next)])[.newAxis], cache: caches)
        }
        return tokens
    }

    /// Paged prefill (one chunk per row), then lockstep decode windows of
    /// every row together.
    private static func runPaged(model: Qwen4ExpTextModel, prompts: [[Int]], decodeTokens: Int) async throws -> [[Int]] {
        let backend = PagedKVSharedForwardBackend(
            container: container(model),
            blockSizeTokens: tinyBlockSizeTokens,
            maxPhysicalBlocks: tinyMaxPhysicalBlocks,
            poolEpoch: 1,
            layerCount: tinyKinds.count,
            cacheKinds: tinyKinds,
            recurrentStateLayout: tinyLayout
        )
        XCTAssertTrue(ModelRuntime.schedulerFollowsSerialPrefillStride(backend: backend))
        XCTAssertEqual(backend.maxDecodeRowsPerForward, 8)
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: tinyBlockSizeTokens, maxPhysicalBlocks: tinyMaxPhysicalBlocks)
        func id(_ row: Int) -> String { "qwen4-exp-cb-\(row)" }
        var handles: [PagedKVBlockTableHandle] = []
        var generated: [[Int]] = []
        for (row, prompt) in prompts.enumerated() {
            let handle = try await allocator.allocate(conversationKey: id(row), maxTokens: prompt.count + decodeTokens + 8)
            handles.append(handle)
            _ = try await allocator.extend(handle, by: prompt.count)
            let outputs = try await backend.prefill(rows: [ContinuousBatchPrefillInput(
                requestID: id(row),
                promptTokens: prompt,
                binding: try await allocator.binding(for: handle),
                promptTokenOffset: 0,
                committedKVTokenCount: 0,
                targetKVTokenCount: prompt.count,
                isFinalChunk: true
            )])
            XCTAssertNil(outputs.first?.failureCode)
            generated.append([try XCTUnwrap(outputs.first?.sampledToken, "row \(row) sampled no first token")])
        }
        var remaining = decodeTokens
        while remaining > 0 {
            let steps = min(lockstepWindow, remaining)
            var inputs: [ContinuousBatchDecodeInput] = []
            for row in prompts.indices {
                let committed = prompts[row].count - 1 + generated[row].count
                _ = try await allocator.extend(handles[row], by: steps)
                try await allocator.beginDecodeStep(handles[row])
                let binding = try await allocator.binding(for: handles[row])
                inputs.append(ContinuousBatchDecodeInput(
                    requestID: id(row),
                    currentToken: generated[row].last!,
                    generatedTokens: generated[row],
                    promptTokens: prompts[row],
                    samplerSeed: 0,
                    temperature: 0,
                    topP: 1,
                    presencePenalty: 0,
                    frequencyPenalty: 0,
                    binding: binding,
                    blockTable: binding.currentTable,
                    committedKVTokenCount: committed,
                    targetKVTokenCount: committed + steps,
                    samplerStep: generated[row].count
                ))
            }
            let outcomes = try await backend.decodeLockstepWindow(rows: inputs, steps: steps)
            for handle in handles {
                try await allocator.endDecodeStep(handle)
            }
            for (row, outcome) in outcomes.enumerated() {
                guard case .output(let output) = outcome, output.requestID == id(row), output.tokens.count == steps else {
                    XCTFail("row \(row) decode failed: \(outcome)")
                    return generated
                }
                generated[row].append(contentsOf: output.tokens)
            }
            remaining -= steps
        }
        return generated
    }

    // MARK: - Helpers

    private func step(
        _ paged: PagedQwen4ExpSparseCache,
        _ oracle: Qwen4ExpAttentionCache?,
        length: Int,
        rng: inout SplitMix,
        label: String = ""
    ) {
        func values(_ shape: [Int]) -> MLXArray {
            let count = shape.reduce(1, *)
            return MLXArray((0 ..< count).map { _ in rng.nextFloat() }).reshaped(shape).asType(.bfloat16)
        }
        let k = values([1, kvHeads, length, headDim])
        let v = values([1, kvHeads, length, headDim])
        let ik = values([1, length, indexDim])
        // The model reads the indexer offset between the two updates.
        let (pk, pv) = paged.update(keys: k, values: v)
        XCTAssertEqual(paged.indexerOffset, paged.offset - length, "indexer offset \(label)")
        let pik = paged.updateIndexer(keys: ik)
        guard let oracle else { return }
        let (ok, ov) = oracle.update(keys: k, values: v)
        XCTAssertEqual(paged.indexerOffset, oracle.indexerOffset + length, "indexer offset \(label)")
        let oik = oracle.updateIndexer(keys: ik)
        XCTAssertTrue(equal(pk, ok), "keys \(label)")
        XCTAssertTrue(equal(pv, ov), "values \(label)")
        XCTAssertTrue(equal(pik, oik), "index keys \(label)")
    }

    private func makeCache(
        reconstructViaGather: Bool = false,
        blockSizeTokens: Int? = nil,
        maxPhysicalBlocks: Int = 64
    ) -> PagedQwen4ExpSparseCache {
        let blockSize = blockSizeTokens ?? self.blockSize
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "paged-qwen4-exp-test", poolEpoch: 1)
        let binding = PagedKVStorageBinding(
            handle: handle,
            blockSizeTokens: blockSize,
            maxLogicalTokens: 4096,
            currentTable: PagedKVBlockTable(
                handleID: handle.handleID,
                blockSizeTokens: blockSize,
                logicalTokenCount: 0,
                physicalBlocks: [],
                tailValidTokenCount: 0,
                poolEpoch: 1
            ),
            poolEpoch: 1
        )
        return PagedQwen4ExpSparseCache(
            blockSizeTokens: blockSize,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: 1,
            binding: binding,
            reconstructViaGather: reconstructViaGather
        )
    }

    private func equal(_ lhs: MLXArray, _ rhs: MLXArray) -> Bool {
        lhs.shape == rhs.shape && lhs.dtype == rhs.dtype && (lhs.size == 0 || all(lhs .== rhs).item(Bool.self))
    }

    private func assertStatesEqual(_ lhs: [MLXArray], _ rhs: [MLXArray], _ label: String) {
        XCTAssertEqual(lhs.count, rhs.count, label)
        for (index, (a, b)) in zip(lhs, rhs).enumerated() {
            XCTAssertTrue(equal(a, b), "state[\(index)] \(label): \(a.shape) \(a.dtype) vs \(b.shape) \(b.dtype)")
        }
    }

    private func requireMetal() throws {
        guard MLXTestDevice.metallibAvailable else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }
}

private struct Qwen4ExpTestTokenizer: Tokenizer {
    let bosToken: String? = nil
    let eosToken: String? = nil
    let unknownToken: String? = nil

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map(String.init).joined(separator: " ") }
    func convertTokenToId(_ token: String) -> Int? { Int(token) }
    func convertIdToToken(_ id: Int) -> String? { String(id) }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

/// Deterministic test values without a global RNG.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextFloat() -> Float { Float(next() >> 40) / Float(1 << 24) - 0.5 }
}
