import Foundation
import MLX
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

private enum PagedKVGptOssMixedClassTestError: Error {
    case notExpected
}

/// SPEC-039 v0.1.29 `gpt_oss` mixed cache class: exact identities, the exact
/// sliding-window/full-attention layer layout, and paged-vs-contiguous
/// exactness for rows that cross the sliding window.
final class PagedKVGptOssMixedClassTests: XCTestCase {
    private static let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
    private static let modelSHA = String(repeating: "a", count: 64)

    /// The `openai/gpt-oss-20b` shape: 24 layers alternating sliding/full from
    /// layer 0, a 128-token window, 32 experts.
    private static func gptOSSConfig(
        layers: Int = 24,
        layerTypes: [String]?? = .some(nil),
        slidingWindow: Int? = 128,
        architectures: [String] = ["GptOssForCausalLM"],
        modelType: String = "gpt_oss"
    ) -> [String: Any] {
        var object: [String: Any] = [
            "model_type": modelType,
            "architectures": architectures,
            "num_hidden_layers": layers,
            "num_local_experts": 32,
        ]
        if let slidingWindow { object["sliding_window"] = slidingWindow }
        switch layerTypes {
        case .some(.some(let types)): object["layer_types"] = types
        case .some(.none):
            object["layer_types"] = (0..<layers).map { $0.isMultiple(of: 2) ? "sliding_attention" : "full_attention" }
        case .none: break
        }
        return object
    }

    private static func capabilities(
        _ object: [String: Any], modelID: String = "openai/gpt-oss-20b"
    ) throws -> PagedKVRuntimeModelCapabilities {
        ModelRuntime.pagedKVModelCapabilities(
            modelID: modelID, configJSONData: try JSONSerialization.data(withJSONObject: object)
        )
    }

    private static func expectedKinds(layers: Int, window: Int = 128) -> [PagedKVSharedForwardBackend.CacheKind] {
        (0..<layers).map { $0.isMultiple(of: 2) ? .slidingWindow(windowTokens: window) : .pagedAttention }
    }

    func testGptOss20BMixedClassRequiresExactIdentityAndLayout() throws {
        let admitted = try Self.capabilities(Self.gptOSSConfig())
        XCTAssertEqual(admitted.modelFamily, "gpt_oss")
        XCTAssertTrue(admitted.requiresMoEDispatch)
        XCTAssertTrue(admitted.hybridDecoderArchitectureVerified)
        XCTAssertEqual(admitted.slidingWindowAttention?.expectedCacheKinds, Self.expectedKinds(layers: 24))

        // No `layer_types`: the model's own alternating default.
        let implicit = try Self.capabilities(Self.gptOSSConfig(layerTypes: .none))
        XCTAssertTrue(implicit.hybridDecoderArchitectureVerified)
        XCTAssertEqual(implicit.slidingWindowAttention?.expectedCacheKinds, Self.expectedKinds(layers: 24))

        let refused: [(String, [String: Any], String)] = [
            ("path alias", Self.gptOSSConfig(), "mlx-community/gpt-oss-20b-MXFP4-Q8"),
            ("other identity", Self.gptOSSConfig(), "openai/gpt-oss-safeguard-20b"),
            ("extra architecture", Self.gptOSSConfig(architectures: ["GptOssForCausalLM", "Other"]), "openai/gpt-oss-20b"),
            ("model type", Self.gptOSSConfig(modelType: "gpt_oss_v2"), "openai/gpt-oss-20b"),
            ("no window", Self.gptOSSConfig(slidingWindow: nil), "openai/gpt-oss-20b"),
            ("zero window", Self.gptOSSConfig(slidingWindow: 0), "openai/gpt-oss-20b"),
            ("short layer_types", Self.gptOSSConfig(layerTypes: .some(Array(repeating: "full_attention", count: 23))), "openai/gpt-oss-20b"),
            ("all sliding", Self.gptOSSConfig(layerTypes: .some(Array(repeating: "sliding_attention", count: 24))), "openai/gpt-oss-20b"),
            ("all full", Self.gptOSSConfig(layerTypes: .some(Array(repeating: "full_attention", count: 24))), "openai/gpt-oss-20b"),
            ("unknown layer", Self.gptOSSConfig(layerTypes: .some(["linear_attention"] + Array(repeating: "full_attention", count: 23))), "openai/gpt-oss-20b"),
            ("odd implicit layers", Self.gptOSSConfig(layers: 23, layerTypes: .none), "openai/gpt-oss-20b"),
        ]
        for (label, object, modelID) in refused {
            let capabilities = try Self.capabilities(object, modelID: modelID)
            XCTAssertFalse(capabilities.hybridDecoderArchitectureVerified, label)
            XCTAssertNil(capabilities.slidingWindowAttention, label)
        }
    }

    func testAttachGateAdmitsGptOssMixedClassAndRefusesOtherMixedClasses() throws {
        // Identity open, later gates closed: an admitted class gets past the
        // cache-class check and stops at the metallib gate.
        let gates = PagedKVGates(
            identityAvailable: true, metallibAvailable: false, kernelRegistered: false, parityEstablished: false
        )
        func reason(_ capabilities: PagedKVRuntimeModelCapabilities, modelID: String, cacheClass: String = "mixed") -> PagedKVFallbackReason? {
            ModelRuntime.pagedKVAttachDecision(
                config: Self.config, modelID: modelID, modelHash: Self.modelSHA,
                tokenizerSHA256: nil, chatTemplateSHA256: nil, kvBitsOverride: nil,
                runtimeCacheClass: cacheClass, gates: gates, modelCapabilities: capabilities
            ).reason
        }

        XCTAssertEqual(reason(try Self.capabilities(Self.gptOSSConfig()), modelID: "openai/gpt-oss-20b"), .metallib)
        XCTAssertEqual(
            reason(try Self.capabilities(Self.gptOSSConfig(layers: 36), modelID: "openai/gpt-oss-120b"), modelID: "openai/gpt-oss-120b"),
            .metallib
        )
        XCTAssertEqual(
            reason(try Self.capabilities(Self.gptOSSConfig(), modelID: "mlx-community/gpt-oss-20b-MXFP4-Q8"),
                   modelID: "mlx-community/gpt-oss-20b-MXFP4-Q8"),
            .cacheClass
        )
        XCTAssertEqual(
            reason(try Self.capabilities(Self.gptOSSConfig(slidingWindow: nil)), modelID: "openai/gpt-oss-20b"),
            .cacheClass
        )
        // A pure rotating class is never admitted, even for the exact identity.
        XCTAssertEqual(
            reason(try Self.capabilities(Self.gptOSSConfig()), modelID: "openai/gpt-oss-20b", cacheClass: "RotatingKVCache"),
            .cacheClass
        )
        // Other recognized families with a `mixed` cache stay fail-closed.
        let llamaMixed = try Self.capabilities(["model_type": "llama", "architectures": ["LlamaForCausalLM"]],
                                               modelID: "meta-llama/llama-3.1-8b-instruct")
        XCTAssertEqual(llamaMixed.modelFamily, "llama")
        XCTAssertEqual(reason(llamaMixed, modelID: "meta-llama/llama-3.1-8b-instruct"), .cacheClass)
        let qwenMixed = try Self.capabilities(["model_type": "qwen3", "architectures": ["Qwen3ForCausalLM"]],
                                              modelID: "qwen/qwen3-8b")
        XCTAssertEqual(reason(qwenMixed, modelID: "qwen/qwen3-8b"), .cacheClass)
    }

    func testMeasuredTopologyRequiresTheExactGptOssLayerLayout() throws {
        let admitted = try Self.capabilities(Self.gptOSSConfig())
        let exact = Self.expectedKinds(layers: 24)
        XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(exact, modelCapabilities: admitted))

        var swapped = exact
        swapped.swapAt(0, 1)
        var recurrent = exact
        recurrent[1] = .recurrentMamba
        let mismatches: [(String, [PagedKVSharedForwardBackend.CacheKind])] = [
            ("layer order", swapped),
            ("window", Self.expectedKinds(layers: 24, window: 64)),
            ("layer count", Self.expectedKinds(layers: 26)),
            ("recurrent layer", recurrent),
            ("all full", Array(repeating: .pagedAttention, count: 24)),
        ]
        for (label, kinds) in mismatches {
            XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(kinds, modelCapabilities: admitted), label)
        }

        // Verified architecture without a config-derived layout, or another
        // family, does not match the gpt-oss layout.
        let noLayout = PagedKVRuntimeModelCapabilities(
            modelFamily: "gpt_oss", requiresMoEDispatch: true, hybridDecoderArchitectureVerified: true
        )
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(exact, modelCapabilities: noLayout))
        let qwen = PagedKVRuntimeModelCapabilities(
            modelFamily: "qwen", requiresMoEDispatch: false, hybridDecoderArchitectureVerified: true,
            slidingWindowAttention: admitted.slidingWindowAttention
        )
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(exact, modelCapabilities: qwen))
    }

    /// SPEC-039 FR-PKV5 v0.1.30: the T3-03 family KV-quant default reaches
    /// only the serial path; the paged-KV gate sees only an explicit kv_bits.
    func testFamilyKVQuantDefaultReachesOnlyTheSerialPath() async throws {
        func runtime(_ modelID: String, explicit: Int?) -> ModelRuntime {
            ModelRuntime(
                modelID: modelID,
                kvBitsOverride: explicit,
                familyKVQuantDefault: true,
                warmSwapEnabled: false,
                loader: { _ in throw PagedKVGptOssMixedClassTestError.notExpected }
            )
        }
        func gateReason(explicit: Int?) throws -> PagedKVFallbackReason? {
            ModelRuntime.pagedKVAttachDecision(
                config: Self.config, modelID: "openai/gpt-oss-20b", modelHash: Self.modelSHA,
                tokenizerSHA256: nil, chatTemplateSHA256: nil, kvBitsOverride: explicit,
                runtimeCacheClass: "mixed",
                gates: PagedKVGates(
                    identityAvailable: true, metallibAvailable: false, kernelRegistered: false, parityEstablished: false
                ),
                modelCapabilities: try Self.capabilities(Self.gptOSSConfig())
            ).reason
        }

        // (a) gpt-oss, no explicit kv_bits: the gate sees nil, serial gets 8.
        let gptOSS = runtime("openai/gpt-oss-20b", explicit: nil)
        let gateBits = await gptOSS.kvBitsOverrideForTest()
        let serialBits = await gptOSS.serialKVBitsForTest()
        XCTAssertNil(gateBits)
        XCTAssertEqual(serialBits, 8)
        XCTAssertEqual(try gateReason(explicit: gateBits), .metallib, "past the quantized check")

        // (b) explicit kv_bits: the gate sees it and falls back quantized;
        // serial uses the same explicit value.
        let explicit = runtime("openai/gpt-oss-20b", explicit: 4)
        let explicitGateBits = await explicit.kvBitsOverrideForTest()
        let explicitSerialBits = await explicit.serialKVBitsForTest()
        XCTAssertEqual(explicitGateBits, 4)
        XCTAssertEqual(explicitSerialBits, 4)
        XCTAssertEqual(try gateReason(explicit: explicitGateBits), .quantized)

        // (c) a model without a family default is unchanged.
        let llama = runtime("meta-llama/llama-3.1-8b-instruct", explicit: nil)
        let llamaGateBits = await llama.kvBitsOverrideForTest()
        let llamaSerialBits = await llama.serialKVBitsForTest()
        XCTAssertNil(llamaGateBits)
        XCTAssertNil(llamaSerialBits)
        let llamaExplicit = runtime("meta-llama/llama-3.1-8b-instruct", explicit: 8)
        let llamaExplicitSerial = await llamaExplicit.serialKVBitsForTest()
        XCTAssertEqual(llamaExplicitSerial, 8)

        // The family default is opt-in per runtime and follows the model id.
        XCTAssertNil(ModelRuntime.serialKVBits(explicit: nil, familyKVQuantDefault: false, modelID: "openai/gpt-oss-20b"))
        XCTAssertEqual(ModelRuntime.serialKVBits(explicit: nil, familyKVQuantDefault: true, modelID: "openai/gpt-oss-120b"), 8)
        XCTAssertNil(ModelRuntime.serialKVBits(explicit: nil, familyKVQuantDefault: true, modelID: nil))
    }

    /// One sliding-window layer and one full-attention layer, both paged through
    /// the real gather over a non-identity block order, against the serial
    /// keep=0 `RotatingKVCache` and `KVCacheSimple`: every presented key and
    /// value, and every decode step's attention output, is bit-equal, for a
    /// prompt longer than the window, one that crosses it during decode, one
    /// exactly the window, and chunked prefill.
    func testMixedLayoutPagedGatherMatchesSerialCachesAcrossTheWindow() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        let window = 8
        let schedules: [[Int]] = [[10], [3], [8], [12, 1], [5, 6]]
        do {
            PagedKVCache.resetGatherDiagnostics()
            for chunks in schedules {
                let updates = chunks + Array(repeating: 1, count: 3 * window + 3)
                let serialSliding = RotatingKVCache(maxSize: window, keep: 0)
                let serialFull = KVCacheSimple()
                let pagedSliding = Self.pagedCache(windowTokens: window)
                let pagedFull = Self.pagedCache(windowTokens: nil)
                var position = 0
                for (step, count) in updates.enumerated() {
                    let keys = Self.tokens(start: position, count: count, salt: 1)
                    let values = Self.tokens(start: position, count: count, salt: 5)
                    position += count
                    let layers: [(String, KVCache, KVCache)] = [
                        ("sliding", serialSliding, pagedSliding),
                        ("full", serialFull, pagedFull),
                    ]
                    for (name, serial, paged) in layers {
                        let expected = serial.update(keys: keys, values: values)
                        let presented = paged.update(keys: keys, values: values)
                        let context = "chunks \(chunks), update \(step), \(name) layer"
                        XCTAssertEqual(Self.bytes(presented.0), Self.bytes(expected.0), "keys: \(context)")
                        XCTAssertEqual(Self.bytes(presented.1), Self.bytes(expected.1), "values: \(context)")
                        guard count == 1 else { continue }
                        let query = Self.tokens(start: position, count: 1, salt: 9)
                        let serialOut = MLXFast.scaledDotProductAttention(
                            queries: query, keys: expected.0, values: expected.1, scale: 0.125, mask: .none
                        )
                        let pagedOut = MLXFast.scaledDotProductAttention(
                            queries: query, keys: presented.0, values: presented.1, scale: 0.125, mask: .none
                        )
                        XCTAssertEqual(Self.bytes(pagedOut), Self.bytes(serialOut), "attention: \(context)")
                    }
                }
                XCTAssertEqual(pagedSliding.offset, position)
                XCTAssertEqual(pagedSliding.storedTokens, position, "sliding layers page the full history")
            }
            XCTAssertGreaterThan(PagedKVCache.gatherKernelCalls, 0)
            XCTAssertTrue(PagedKVCache.observedNonIdentityPermutation)
            XCTAssertGreaterThanOrEqual(PagedKVCache.maxLogicalBlocksObserved, 2)
        }
    }

    /// `[1, 2, count, 4]` float16 tokens with distinct, exactly representable values.
    private static func tokens(start: Int, count: Int, salt: Int) -> MLXArray {
        var values: [Float] = []
        for head in 0 ..< 2 {
            for token in start ..< start + count {
                for lane in 0 ..< 4 {
                    values.append(Float((token * 7 + head * 3 + lane + salt * 11) % 64) / 16 - 2)
                }
            }
        }
        return MLXArray(values, [1, 2, count, 4]).asType(.float16)
    }

    private static func bytes(_ array: MLXArray) -> Data {
        array.asData(access: .copy).data
    }

    private static func pagedCache(windowTokens: Int?) -> PagedKVCache {
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "gpt-oss-mixed-test", poolEpoch: 1)
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
            reconstructViaGather: true,
            attentionWindowTokens: windowTokens
        )
    }
}
