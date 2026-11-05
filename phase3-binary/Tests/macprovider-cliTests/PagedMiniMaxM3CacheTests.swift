import Foundation
import MLX
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-039 `pagedIndexedKV` (MiniMax M3): `PagedMiniMaxM3SparseCache` holds
/// bit-for-bit the stock `MiniMaxM3Cache` contents (K, V and indexer keys),
/// with and without the parity gather, on whole blocks; plus the provider
/// wiring that needs no Metal (recognition, cap, family, allowlist, topology,
/// attach probe span, cache identity).
final class PagedMiniMaxM3CacheTests: XCTestCase {
    typealias CacheKind = PagedKVSharedForwardBackend.CacheKind

    private let kvHeads = 2
    private let headDim = 8
    private let indexDim = 4
    private let blockSize = 8

    // MARK: - Wiring (no Metal)

    static func config(
        architectures: [String] = ["MiniMaxM3SparseForConditionalGeneration"],
        modelType: String = "minimax_m3_vl",
        layers: Int = 60,
        frequency: [Int]? = nil,
        useSparse: Bool = true,
        blockSize: Int = 128,
        topkBlocks: Int = 16
    ) -> Data {
        let object: [String: Any] = [
            "model_type": modelType,
            "architectures": architectures,
            "text_config": [
                "num_hidden_layers": layers,
                "num_local_experts": 128,
                "num_experts_per_tok": 4,
                "sparse_attention_config": [
                    "use_sparse_attention": useSparse,
                    "sparse_attention_freq": frequency ?? Array(repeating: 1, count: layers),
                    "sparse_block_size": blockSize,
                    "sparse_topk_blocks": topkBlocks,
                ] as [String: Any],
            ] as [String: Any],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testMiniMaxCachesAreRecognizedAsPagedIndexedKV() {
        XCTAssertEqual(CacheKind.recognized(from: MiniMaxM3Cache()), .pagedIndexedKV)
        XCTAssertEqual(CacheKind.recognized(from: makeCache()), .pagedIndexedKV)
        XCTAssertNil(CacheKind.recognized(from: MiniMaxM3CacheBatch(rowCaches: [MiniMaxM3Cache()])))
        XCTAssertTrue(CacheKind.pagedIndexedKV.usesPagedKVCache)
        XCTAssertTrue(CacheKind.pagedIndexedKV.isPagedIndexedKV)
        XCTAssertFalse(CacheKind.pagedIndexedKV.isPagedMLA)
        XCTAssertEqual(CacheKind.kinds(from: [MiniMaxM3Cache(), MiniMaxM3Cache()]), [.pagedIndexedKV, .pagedIndexedKV])
    }

    /// The serve cap reached the iterator's explicit-cache check, which counts
    /// every sparse layer's `MiniMaxM3Cache` as not realizing it, so the
    /// self-check's serial baseline failed on M3.1-Flash (60 sparse layers).
    func testSerialMiniMaxCacheIteratorParametersPassTheCapacityCheck() throws {
        let cache: [KVCache] = (0 ..< 60).map { _ in MiniMaxM3Cache() }
        let capped = KVCacheConfiguration(capacity: try KVCacheConfiguration.Capacity(maxTokens: 65_536))
        XCTAssertThrowsError(try validateKVCacheCompatibility(cache, configuration: capped)) { error in
            XCTAssertEqual(error as? KVCacheConfigurationError, .incompatibleCapacity(expected: 65_536, count: 60))
        }
        let base = GenerateParameters(maxTokens: 8, maxKVSize: 65_536)
        XCTAssertNil(ModelRuntime.explicitCacheIteratorParameters(base, cache: cache).maxKVSize)
        XCTAssertNil(ModelRuntime.serveIteratorParameters(
            base, forceSimpleKV: false, reusedCache: false, cache: cache
        ).maxKVSize)
        XCTAssertEqual(ModelRuntime.explicitCacheIteratorParameters(base, cache: [KVCacheSimple()]).maxKVSize, 65_536)
    }

    func testIndexedForwardsCarryAtMostEightFlattenedTokens() {
        XCTAssertEqual(PagedKVSharedForwardBackend.maxFlattenedTokensPerForward(cacheKinds: [.pagedIndexedKV]), 8)
        XCTAssertTrue(PagedKVSharedForwardBackend.prefillsGroupedRowsAlone(
            cacheKinds: [.pagedIndexedKV], minimumGroupedChunkTokens: 144
        ))
    }

    func testFamilyAndBlockDefaults() {
        XCTAssertTrue(PagedKVAttachGate.recognizedModelFamilies.contains("minimax_m3"))
        XCTAssertEqual(PagedKVConfig(enabled: true).withFamilyDefaults(modelFamily: "minimax_m3").blockSizeTokens, 256)
        XCTAssertEqual(ModelRuntime.pagedKVParityLabelSuffix(modelFamily: "minimax_m3"), "minimax-m3-indexed-kv-parity-v1")
    }

    func testAllowlistedIdentityCarriesTheVerifiedLayout() throws {
        let capabilities = ModelRuntime.pagedKVModelCapabilities(
            modelID: "MiniMaxAI/MiniMax-M3.1-Flash",
            configJSONData: Self.config()
        )
        XCTAssertEqual(capabilities.modelFamily, "minimax_m3")
        XCTAssertTrue(capabilities.requiresMoEDispatch)
        XCTAssertTrue(capabilities.hybridDecoderArchitectureVerified)
        let layout = try XCTUnwrap(capabilities.blockSparseAttention)
        XCTAssertEqual(layout.selectedTokens, 2048)
        XCTAssertEqual(layout.expectedCacheKinds, Array(repeating: .pagedIndexedKV, count: 60))
        XCTAssertEqual(capabilities.attachProbePromptTokens(blockSizeTokens: 256), 2560)
        XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(layout.expectedCacheKinds, modelCapabilities: capabilities))
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(
            Array(layout.expectedCacheKinds.dropLast()), modelCapabilities: capabilities
        ))
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(
            Array(repeating: .pagedAttention, count: 60), modelCapabilities: capabilities
        ))
    }

    func testOtherMiniMaxConfigsFailClosed() {
        func verified(_ modelID: String, _ data: Data) -> Bool {
            ModelRuntime.pagedKVModelCapabilities(modelID: modelID, configJSONData: data).hybridDecoderArchitectureVerified
        }
        let id = "minimaxai/minimax-m3.1-flash"
        XCTAssertFalse(verified("mlx-community/MiniMax-M3.1-Flash-oQ3e-mtp", Self.config()))
        XCTAssertFalse(verified(id, Self.config(architectures: ["MiniMaxM3SparseForConditionalGeneration", "Other"])))
        XCTAssertFalse(verified(id, Self.config(modelType: "minimax_m3")))
        XCTAssertFalse(verified(id, Self.config(useSparse: false)))
        XCTAssertFalse(verified(id, Self.config(frequency: [0] + Array(repeating: 1, count: 59))))
        XCTAssertFalse(verified(id, Self.config(topkBlocks: 0)))
        // A Qwen hybrid never admits an indexed layer.
        let qwen = PagedKVRuntimeModelCapabilities(
            modelFamily: "qwen", requiresMoEDispatch: false, hybridDecoderArchitectureVerified: true
        )
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(
            [.recurrentMamba, .pagedAttention, .pagedIndexedKV], modelCapabilities: qwen
        ))
    }

    func testParityResultCarriesThreeGathersPerLayerForward() {
        let result = PagedKVRuntimeParityProbeResult(
            established: true, nLayers: 60, nNew: 32, nForwards: 37, gathersPerLayerForward: 3,
            gatherKernelCalls: 60 * 37 * 3, maxLogicalBlocks: 11, nonIdentityPermutation: true
        )
        XCTAssertEqual(result.gathersPerLayerForward, 3)
        XCTAssertEqual(PagedKVRuntimeParityProbeResult(
            established: true, nLayers: 1, nNew: 1, gatherKernelCalls: 2, maxLogicalBlocks: 3,
            nonIdentityPermutation: true
        ).gathersPerLayerForward, 2)
    }

    // MARK: - Cache (Metal)

    func testMatchesStockCacheAcrossChunksDecodeAndTrims() throws {
        try requireMetal()
        for gather in [false, true] {
            var rng = SplitMix(seed: 11)
            let paged = makeCache(reconstructViaGather: gather)
            let oracle = MiniMaxM3Cache()
            for length in [5, 12, 1, 1, 9, 1] {
                step(paged, oracle, length: length, rng: &rng, label: "gather=\(gather) len=\(length)")
            }
            XCTAssertEqual(paged.trim(6), 6)
            XCTAssertEqual(oracle.trim(6), 6)
            XCTAssertEqual(paged.offset, oracle.offset)
            for length in [3, 1, 8] {
                step(paged, oracle, length: length, rng: &rng, label: "gather=\(gather) after trim len=\(length)")
            }
            assertStatesEqual(paged.state, oracle.state, "gather=\(gather) final")
        }
    }

    func testParityGatherCoversAllThreeBuffers() throws {
        try requireMetal()
        let paged = makeCache(reconstructViaGather: true)
        var rng = SplitMix(seed: 7)
        PagedKVCache.resetGatherDiagnostics()
        // 21 tokens: 3 blocks of 8. One forward reads K, V and indexer keys.
        step(paged, nil, length: 21, rng: &rng)
        XCTAssertEqual(PagedKVCache.gatherKernelCalls, 3)
        XCTAssertEqual(PagedKVCache.maxLogicalBlocksObserved, 3)
        XCTAssertTrue(PagedKVCache.observedNonIdentityPermutation)
    }

    func testCapacityIsWholeBlocks() throws {
        try requireMetal()
        let cache = makeCache()
        var rng = SplitMix(seed: 3)
        step(cache, nil, length: 9, rng: &rng)
        XCTAssertEqual(cache.capacityTokens, 16)
        for _ in 0 ..< 8 { step(cache, nil, length: 1, rng: &rng) }
        XCTAssertEqual(cache.offset, 17)
        XCTAssertEqual(cache.capacityTokens, 24)
        XCTAssertEqual(cache.trim(9), 9)
        XCTAssertEqual(cache.capacityTokens, 8)
        XCTAssertEqual(cache.state.map { $0.dim(2) }, [8, 8, 8])
    }

    func testCopyIsIndependent() throws {
        try requireMetal()
        var rng = SplitMix(seed: 5)
        let cache = makeCache()
        step(cache, nil, length: 10, rng: &rng)
        let copied = cache.concreteCopy()
        let before = copied.state
        step(cache, nil, length: 3, rng: &rng)
        XCTAssertEqual(copied.offset, 10)
        assertStatesEqual(copied.state, before, "copy after source advanced")
    }

    func testBatchRoutesRowsAndTracksRaggedLengths() throws {
        try requireMetal()
        let rows = [makeCache(), makeCache()]
        let batch = PagedMiniMaxM3BatchLayerCache(rowCaches: rows)
        XCTAssertEqual(CacheKind.recognized(from: batch), nil)
        XCTAssertEqual(batch.rowCaches.count, 2)
        XCTAssertTrue(batch.rowCaches[1] as AnyObject === rows[1])
        batch.prepare(lengths: [3, 3])
        XCTAssertNil(batch.rowLengths)
        batch.prepare(lengths: [3, 2])
        XCTAssertEqual(batch.rowLengths, [3, 2])
        batch.finalize()
        XCTAssertNil(batch.rowLengths)
    }

    // MARK: - Helpers

    private func step(
        _ paged: PagedMiniMaxM3SparseCache,
        _ oracle: MiniMaxM3Cache?,
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
        let ik = values([1, 1, length, indexDim])
        let (pk, pv) = paged.update(keys: k, values: v)
        let pik = paged.updateIndex(ik)
        guard let oracle else { return }
        let (ok, ov) = oracle.update(keys: k, values: v)
        let oik = oracle.updateIndex(ik)
        XCTAssertTrue(equal(pk, ok), "keys \(label)")
        XCTAssertTrue(equal(pv, ov), "values \(label)")
        XCTAssertTrue(equal(pik, oik), "index keys \(label)")
    }

    private func makeCache(reconstructViaGather: Bool = false) -> PagedMiniMaxM3SparseCache {
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "paged-minimax-test", poolEpoch: 1)
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
        return PagedMiniMaxM3SparseCache(
            blockSizeTokens: blockSize,
            maxPhysicalBlocks: 64,
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
            XCTAssertTrue(equal(a, b), "state[\(index)] \(label): \(a.shape) vs \(b.shape)")
        }
    }

    private func requireMetal() throws {
        // Under `swift test` Bundle.main is Xcode's xctest runner; MLX loads
        // the metallib colocated with this test bundle's binary.
        let tests = Bundle(for: Self.self)
        guard PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(bundleURL: tests.resourceURL, executableURL: tests.executableURL)
        else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }
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
