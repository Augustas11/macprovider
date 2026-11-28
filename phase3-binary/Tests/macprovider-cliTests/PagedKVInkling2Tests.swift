import Foundation
import MLX
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Inkling 2 continuous batching (#2505): the flat visit layout, the
/// four-slot convolution-tail state, the identity gates, and row attention
/// that hands each row exactly what its serial `RotatingKVCache` returns.
final class PagedKVInkling2Tests: XCTestCase {
    /// `mlx-community/Inkling-2-Mini-oQ4e-mtp` `config.json` (snapshot
    /// 3eea0427), the keys the layout reads.
    static let miniConfig = #"""
        {"model_type": "inkling2_loop", "architectures": ["Inkling2LoopForConditionalGeneration"],
         "text_config": {"model_type": "inkling2_loop_text", "num_hidden_layers": 24,
          "sliding_window_size": 1024,
          "local_layer_ids": [0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 12, 13, 14, 15, 16, 18, 19, 20, 21, 22],
          "loop_config": {"core_start": 6, "core_end": 18, "num_passes": 3, "gate_rank": 64,
                          "is_varloop": false}}}
        """#

    private func miniObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.miniConfig.utf8)) as? [String: Any])
    }

    func testMiniLayoutIsFortyEightVisitsOfAttentionThenTails() throws {
        let layout = try XCTUnwrap(PagedKVInkling2Layout(config: try miniObject()))
        let kinds = layout.expectedCacheKinds
        XCTAssertEqual(kinds.count, 96)
        let attention = stride(from: 0, to: 96, by: 2).map { kinds[$0] }
        XCTAssertTrue(stride(from: 1, to: 96, by: 2).allSatisfy { kinds[$0] == .recurrentMamba })
        XCTAssertEqual(attention.filter { $0 == .slidingWindow(windowTokens: 1024) }.count, 40)
        // Global visits: layer 5, layers 11 and 17 in each of three passes, layer 23.
        let globalVisits = attention.indices.filter { attention[$0] == .pagedAttention }
        XCTAssertEqual(globalVisits, [5, 11, 17, 23, 29, 35, 41, 47])
    }

    func testLayoutRejectsVarloopAndOtherModelTypes() throws {
        var config = try miniObject()
        var text = try XCTUnwrap(config["text_config"] as? [String: Any])
        var loop = try XCTUnwrap(text["loop_config"] as? [String: Any])
        loop["is_varloop"] = true
        text["loop_config"] = loop
        config["text_config"] = text
        XCTAssertNil(PagedKVInkling2Layout(config: config))
        var other = try miniObject()
        var otherText = try XCTUnwrap(other["text_config"] as? [String: Any])
        otherText["model_type"] = "inkling2_text"
        other["text_config"] = otherText
        XCTAssertNil(PagedKVInkling2Layout(config: other))
    }

    func testFlatteningUnwrapsOnlyVisitLists() {
        let simple = KVCacheSimple()
        let ring = RotatingKVCache(maxSize: 8, keep: 0)
        let tails = ArraysCache(size: 4)
        let caches: [KVCache] = [
            CacheList(simple, ArraysCache(size: 4)),
            CacheList(ring, tails),
            CacheList(RotatingKVCache(maxSize: 8, keep: 2), ArraysCache(size: 4)),
            KVCacheSimple(),
        ]
        let flat = PagedKVInkling2Layout.flattened(caches)
        XCTAssertEqual(flat.count, 6)
        XCTAssertTrue((flat[0] as AnyObject) === simple)
        XCTAssertTrue((flat[2] as AnyObject) === ring)
        XCTAssertTrue((flat[3] as AnyObject) === tails)
        XCTAssertTrue(flat[4] is CacheList, "a sink-prefix ring is not a pageable visit")
        XCTAssertEqual(
            PagedKVSharedForwardBackend.CacheKind.kinds(from: Array(flat.prefix(4))),
            [.pagedAttention, .recurrentMamba, .slidingWindow(windowTokens: 8), .recurrentMamba]
        )
    }

    /// The model builds its tails as the fork's `ConvolutionTailCache` (an
    /// `ArraysCache` subclass); a visit holding one flattens and pages like one
    /// holding a plain `ArraysCache`, so CB attaches instead of serving serial.
    func testFlatteningAcceptsTheModelsConvolutionTailCache() {
        let ring = RotatingKVCache(maxSize: 8, keep: 0)
        let tails = ConvolutionTailCache(size: 4)
        let caches: [KVCache] = [
            CacheList(KVCacheSimple(), ConvolutionTailCache(size: 4)),
            CacheList(ring, tails),
            CacheList(KVCacheSimple(), MambaCache()),
        ]
        let flat = PagedKVInkling2Layout.flattened(caches)
        XCTAssertEqual(flat.count, 5)
        XCTAssertTrue((flat[2] as AnyObject) === ring)
        XCTAssertTrue((flat[3] as AnyObject) === tails)
        XCTAssertTrue(flat[4] is CacheList, "a Mamba cache is not a visit's tails")
        XCTAssertEqual(
            PagedKVSharedForwardBackend.CacheKind.kinds(from: Array(flat.prefix(4))),
            [.pagedAttention, .recurrentMamba, .slidingWindow(windowTokens: 8), .recurrentMamba]
        )
    }

    func testAllowlistedIdentityIsAVerifiedPagedFamily() throws {
        let data = Data(Self.miniConfig.utf8)
        let capabilities = ModelRuntime.pagedKVModelCapabilities(
            modelID: "thinkingmachines/inkling-2-mini", configJSONData: data
        )
        XCTAssertEqual(capabilities.modelFamily, "inkling2")
        XCTAssertTrue(PagedKVAttachGate.recognizedModelFamilies.contains("inkling2"))
        XCTAssertTrue(capabilities.hybridDecoderArchitectureVerified)
        XCTAssertEqual(capabilities.recurrentStateLayout, .inkling2ConvTailFourSlot)
        let layout = try XCTUnwrap(capabilities.inkling2Layout)
        XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(
            layout.expectedCacheKinds, modelCapabilities: capabilities
        ))
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(
            Array(layout.expectedCacheKinds.dropLast(2)), modelCapabilities: capabilities
        ))
        // Another identity with the same config is not admitted.
        let other = ModelRuntime.pagedKVModelCapabilities(modelID: "someone/inkling-copy", configJSONData: data)
        XCTAssertFalse(other.hybridDecoderArchitectureVerified)
        XCTAssertNil(other.inkling2Layout)
        XCTAssertEqual(other.recurrentStateLayout, .mambaTwoSlot)
    }

    /// Regression for Studio e2e r1: Inkling's real 48-visit `[CacheList]`
    /// (8 global `KVCacheSimple` + 40 sliding-window keep-0 `RotatingKVCache`,
    /// each paired with `ConvolutionTailCache`) must classify as `"mixed"`,
    /// attach paged KV (never `fallback_paged_fallback_cache_class`), and be
    /// eligible for continuous batching under both default-on coverage and an
    /// explicit CB policy tuple carrying `cache_class: "mixed"`.
    func testInklingRealCacheListClassifiesAsMixedAttachesPagedKVAndEnablesCB() throws {
        let modelID = "thinkingmachines/inkling-2-mini"
        let modelSHA = "75509c7fcd864d109d542676ed14763a2c5c570c731f3c1d1180d0207b6b9b34"
        let metallibSHA = String(repeating: "a", count: 64)
        let hardwareClass = "apple-silicon:Apple M5:ram-32gb"
        let kernelID = PagedKVGatherKernel.registeredKernelName
        let parityLabel = "sdpa-parity-v1"
        let data = Data(Self.miniConfig.utf8)

        let globalVisits: Set<Int> = [5, 11, 17, 23, 29, 35, 41, 47]
        let realInklingCaches: [KVCache] = (0 ..< 48).map { visit in
            let attention: KVCache = globalVisits.contains(visit)
                ? KVCacheSimple()
                : RotatingKVCache(maxSize: 1024, keep: 0)
            return CacheList(attention, ConvolutionTailCache(size: 4))
        }

        let runtimeCacheClass = ModelRuntime.pagedKVRuntimeCacheClass(caches: realInklingCaches)
        XCTAssertEqual(runtimeCacheClass, "mixed")

        let capabilities = ModelRuntime.pagedKVModelCapabilities(modelID: modelID, configJSONData: data)
        XCTAssertTrue(capabilities.hybridDecoderArchitectureVerified)
        XCTAssertTrue(PagedKVAttachGate.supportsCacheClass(
            runtimeCacheClass,
            hybridDecoderArchitectureVerified: capabilities.hybridDecoderArchitectureVerified
        ))

        let flattenedKinds = try XCTUnwrap(
            PagedKVSharedForwardBackend.CacheKind.kinds(from: PagedKVInkling2Layout.flattened(realInklingCaches))
        )
        XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(flattenedKinds, modelCapabilities: capabilities))

        let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let proof = PagedKVHardwareSizingProof(
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelFamily: capabilities.modelFamily,
            hardwareClass: hardwareClass,
            metallibSHA256: metallibSHA,
            kernelIdentifier: kernelID,
            blockSizeTokens: config.blockSizeTokens,
            maxPhysicalBlocks: config.maxPhysicalBlocks,
            maxResidentTokens: config.blockSizeTokens * config.maxPhysicalBlocks,
            parityLabel: parityLabel
        )
        let observed = PagedKVObservedRuntimeIdentity(
            hardwareClass: hardwareClass,
            metallibSHA256: metallibSHA,
            kernelIdentifier: kernelID,
            parityLabel: parityLabel,
            moeDispatchProven: true,
            poolEpoch: proof.poolEpoch,
            source: .runtimeMeasurement
        )
        let gates = PagedKVGates(
            identityAvailable: true,
            observedHardwareClass: hardwareClass,
            metallibAvailable: true,
            kernelRegistered: true,
            parityEstablished: true,
            hardwareSizingProof: proof,
            observedMetallibSHA256: metallibSHA,
            observedKernelIdentifier: kernelID,
            observedParityLabel: parityLabel,
            moeDispatchProven: true,
            engineBridgeAvailable: true,
            observedRuntimeIdentity: observed
        )

        let decision = PagedKVAttachGate.decide(
            config: config,
            runtimeCacheClass: runtimeCacheClass,
            kvBits: nil,
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelFamily: capabilities.modelFamily,
            requiresMoEDispatch: true,
            hybridDecoderArchitectureVerified: capabilities.hybridDecoderArchitectureVerified,
            gates: gates
        )
        let descriptor = try XCTUnwrap(decision.descriptor, "Inkling real CacheList must attach paged KV, got \(decision)")
        XCTAssertNil(decision.reason)

        let requestedTuple = ContinuousBatchingRequestedTuple(
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            cacheClass: runtimeCacheClass,
            kvDType: .fp16,
            requiresMoE: true,
            hardwareClass: hardwareClass,
            metallibSHA256: metallibSHA,
            kernelIdentifier: kernelID,
            parityLabel: parityLabel,
            poolEpoch: descriptor.poolEpoch
        )
        let explicitTuple = ContinuousBatchingAcceptedTuple(
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            cacheClass: "mixed",
            kvDType: .fp16,
            requiresMoE: true,
            hardwareClass: hardwareClass,
            metallibSHA256: metallibSHA,
            kernelIdentifier: kernelID
        )
        for coverage in [
            ContinuousBatchingAcceptanceCoverage.defaultOn(revocations: [], acceptedTuples: [explicitTuple]),
            ContinuousBatchingAcceptanceCoverage(acceptedTuples: [explicitTuple]),
        ] {
            let cb = ContinuousBatchingPolicy.capability(
                mode: .canary,
                maxBatch: 2,
                queueLimit: nil,
                kvBits: nil,
                draftConfigured: false,
                schedulerBackendAvailable: true,
                pagedKVDecision: decision,
                requestedTuple: requestedTuple,
                acceptanceCoverage: coverage
            )
            XCTAssertNil(cb.unsupportedReason)
            XCTAssertFalse(cb.shouldUseSerialPath)
            XCTAssertEqual(cb.maxActiveRows, 2)
        }

        // Non-visit CacheLists (e.g. MambaCache children) must remain "CacheList" and fail closed.
        let nonInklingCaches: [KVCache] = [CacheList(KVCacheSimple(), MambaCache())]
        let nonInklingClass = ModelRuntime.pagedKVRuntimeCacheClass(caches: nonInklingCaches)
        XCTAssertEqual(nonInklingClass, "CacheList")
        let rejected = PagedKVAttachGate.decide(
            config: config,
            runtimeCacheClass: nonInklingClass,
            kvBits: nil,
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelFamily: capabilities.modelFamily,
            requiresMoEDispatch: true,
            hybridDecoderArchitectureVerified: capabilities.hybridDecoderArchitectureVerified,
            gates: gates
        )
        XCTAssertEqual(rejected, .fallback(.cacheClass))
    }

    func testFourSlotTailsPackAndSyncByRow() throws {
        try requireMetal()
        try Device.withDefaultDevice(.cpu) {
            let layout = PagedKVRecurrentStateLayout.inkling2ConvTailFourSlot
            XCTAssertEqual(layout.slotCount(layer: 7), 4)
            let rows = (0 ..< 3).map { row -> ArraysCache in
                let cache = layout.makeRecurrentCache(layer: 1)
                XCTAssertTrue(type(of: cache) == ArraysCache.self)
                for slot in 0 ..< 4 {
                    cache[slot] = MLXArray.full([1, 3, 2 + slot], values: MLXArray(Float(10 * row + slot)))
                }
                return cache
            }
            let batch = layout.makeRecurrentCache(layer: 1)
            try PagedKVSharedForwardBackend.packMambaRows(rows, into: batch, stateLayout: layout, layer: 1)
            XCTAssertEqual(batch.state.map(\.shape), (0 ..< 4).map { [3, 3, 2 + $0] })
            batch[3] = batch[3]! + 1
            PagedKVSharedForwardBackend.syncMambaRows(from: batch, into: rows, stateLayout: layout, layer: 1)
            for (row, cache) in rows.enumerated() {
                XCTAssertEqual(cache[3]!.asArray(Float.self), Array(repeating: Float(10 * row + 4), count: 15))
                XCTAssertEqual(cache[0]!.asArray(Float.self), Array(repeating: Float(10 * row), count: 6))
            }
        }
    }

    /// A one-row paged cache hands the model what `RotatingKVCache` returns,
    /// with the rotation `ringRotation` reports, for every update schedule.
    func testRowAttentionMatchesRotatingCacheKeysAndRotation() throws {
        try requireMetal()
        let window = 8
        let schedules: [[Int]] = [[10, 5], [3], [12, 1], [8], [2, 2, 2], [10, 5, 1, 1, 3]]
        Device.withDefaultDevice(.cpu) {
            for chunks in schedules {
                let rotating = RotatingKVCache(maxSize: window, keep: 0)
                let paged = makeCache(windowTokens: window)
                var position = 0
                for (step, count) in (chunks + Array(repeating: 1, count: 3 * window + 3)).enumerated() {
                    let keys = Self.positions(position, count)
                    position += count
                    let expected = rotating.update(keys: keys, values: keys).0
                    let expectedRotation = count == 1 ? rotating.ringRotation ?? -1 : 0
                    XCTAssertEqual(paged.rowOffsets, [position - count])
                    var seen: KVCacheRowAttentionView?
                    _ = paged.updateAndAttendRows(keys: keys, values: keys) { row, view in
                        XCTAssertEqual(row, 0)
                        seen = view
                        return MLXArray.zeros([1, 1, 1])
                    }
                    XCTAssertEqual(
                        seen?.keys.asArray(Float.self), expected.asArray(Float.self),
                        "chunks \(chunks), update \(step)")
                    XCTAssertEqual(seen?.ringRotation, expectedRotation, "chunks \(chunks), update \(step)")
                }
            }
        }
    }

    /// Batched rows at different offsets: every row writes its own cache and
    /// attends over its own serial ring, and the outputs come back in row order.
    func testBatchedRowAttentionGivesEachRowItsSerialRing() throws {
        try requireMetal()
        let window = 8
        Device.withDefaultDevice(.cpu) {
            let rowChunks: [[Int]] = [[10, 5], [3], [12, 1, 1, 1]]
            var references: [RotatingKVCache] = []
            var rows: [PagedKVCache] = []
            var positions: [Int] = []
            for chunks in rowChunks {
                let rotating = RotatingKVCache(maxSize: window, keep: 0)
                let paged = makeCache(windowTokens: window)
                var position = 0
                for count in chunks {
                    let keys = Self.positions(position, count)
                    position += count
                    _ = rotating.update(keys: keys, values: keys)
                    _ = paged.update(keys: keys, values: keys)
                }
                references.append(rotating)
                rows.append(paged)
                positions.append(position)
            }
            let batch = PagedKVSharedForwardBackend.batchLayerCacheForTest(rowCaches: rows, rowAttention: true)
            guard let rowBatch = batch as? KVCacheRowAttentionProtocol else {
                return XCTFail("a row-attention batch conforms to KVCacheRowAttentionProtocol")
            }
            for step in 0 ..< 2 * window + 3 {
                XCTAssertEqual(rowBatch.rowOffsets, positions)
                let keys = concatenated(positions.map { Self.positions($0, 1) }, axis: 0)
                let expected = references.indices.map { row -> ([Float], Int) in
                    let k = Self.positions(positions[row], 1)
                    let presented = references[row].update(keys: k, values: k).0.asArray(Float.self)
                    return (presented, references[row].ringRotation ?? -1)
                }
                let out = rowBatch.updateAndAttendRows(keys: keys, values: keys) { row, view in
                    XCTAssertEqual(view.keys.asArray(Float.self), expected[row].0, "row \(row), step \(step)")
                    XCTAssertEqual(view.ringRotation, expected[row].1, "row \(row), step \(step)")
                    return MLXArray([Float(row)]).reshaped(1, 1)
                }
                XCTAssertEqual(out.asArray(Float.self), [0, 1, 2])
                positions = positions.map { $0 + 1 }
            }
        }
    }

    private static func positions(_ start: Int, _ count: Int) -> MLXArray {
        MLXArray((start ..< start + count).map(Float.init), [1, 1, count, 1])
    }

    private func requireMetal() throws {
        guard MLXTestDevice.metallibAvailable else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    private func makeCache(windowTokens: Int?) -> PagedKVCache {
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "inkling2-test", poolEpoch: 1)
        return PagedKVCache(
            blockSizeTokens: 4,
            maxPhysicalBlocks: 64,
            poolEpoch: 1,
            binding: PagedKVStorageBinding(
                handle: handle,
                blockSizeTokens: 4,
                maxLogicalTokens: 256,
                currentTable: PagedKVBlockTable(
                    handleID: handle.handleID,
                    blockSizeTokens: 4,
                    logicalTokenCount: 0,
                    physicalBlocks: [],
                    tailValidTokenCount: 0,
                    poolEpoch: 1
                ),
                poolEpoch: 1
            ),
            initialOffset: 0,
            reconstructViaGather: false,
            attentionWindowTokens: windowTokens,
            rollsSlidingRing: true
        )
    }
}
