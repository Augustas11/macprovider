import Foundation
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

final class DeepseekV4ContinuousBatchTests: XCTestCase {
    private static func config(_ overrides: [String: Any] = [:]) -> Data {
        var object: [String: Any] = [
            "model_type": "deepseek_v4", "architectures": ["DeepseekV4ForCausalLM"],
            "num_hidden_layers": 4, "compress_ratios": [0, 4, 128, 4, 0],
            "sliding_window": 128, "n_routed_experts": 8, "num_experts_per_tok": 2,
        ]
        object.merge(overrides) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testDeepseekV4PoolTopologyRecognizesWindowCompressorAndIndexer() throws {
        typealias Kind = PagedKVSharedForwardBackend.CacheKind
        let capabilities = ModelRuntime.pagedKVModelCapabilities(
            modelID: "deepseek/deepseek-v4-flash", configJSONData: Self.config())
        XCTAssertEqual(capabilities.modelFamily, "deepseek_v4")
        XCTAssertTrue(capabilities.requiresMoEDispatch)
        XCTAssertTrue(capabilities.hybridDecoderArchitectureVerified)
        let layout = try XCTUnwrap(capabilities.deepseekV4Pool)
        XCTAssertEqual(layout.ratios, [0, 4, 128, 4])
        let caches: [KVCache] = [
            RotatingKVCache(maxSize: 128),
            CacheList(RotatingKVCache(maxSize: 128), DeepseekV4PoolCache(ratio: 4), DeepseekV4PoolCache(ratio: 4)),
            CacheList(RotatingKVCache(maxSize: 128), DeepseekV4PoolCache(ratio: 128)),
            CacheList(RotatingKVCache(maxSize: 128), DeepseekV4PoolCache(ratio: 4), DeepseekV4PoolCache(ratio: 4)),
        ]
        let kinds = try XCTUnwrap(Kind.kinds(from: caches))
        XCTAssertEqual(kinds, layout.expectedCacheKinds)
        XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(kinds, modelCapabilities: capabilities))
        XCTAssertFalse(Kind.deepseekV4Pool(ratio: 4, windowTokens: 128).usesPagedKVCache)
        XCTAssertEqual(ModelRuntime.servePathDecodeLockstepWindow(cacheKinds: kinds),
                       ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow)
        XCTAssertEqual(ModelRuntime.effectiveDecodeRowBound(deviceBound: 16, cacheKinds: kinds), 8)
        XCTAssertEqual(ModelRuntime.effectiveDecodeRowBound(deviceBound: 4, cacheKinds: kinds), 4)
        XCTAssertNil(Kind.recognized(from: CacheList(RotatingKVCache(maxSize: 128), DeepseekV4PoolCache(ratio: 4))))
        XCTAssertNil(Kind.recognized(from: CacheList(RotatingKVCache(maxSize: 128), DeepseekV4PoolCache(ratio: 128), DeepseekV4PoolCache(ratio: 128))))
    }

    func testDeepseekV4AdmissionRejectsUnverifiedIdentityAndTopology() {
        for (id, data) in [
            ("TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX", Self.config()),
            ("deepseek/deepseek-v4-flash", Self.config(["model_type": "deepseek_v41"])),
            ("deepseek/deepseek-v4-flash", Self.config(["architectures": ["DeepseekV4ForCausalLM", "Other"]])),
            ("deepseek/deepseek-v4-flash", Self.config(["sliding_window": 256])),
            ("deepseek/deepseek-v4-flash", Self.config(["compress_ratios": [0, 4, 2, 4]])),
            ("deepseek/deepseek-v4-flash", Self.config(["compress_ratios": [0, 4]])),
        ] {
            let caps = ModelRuntime.pagedKVModelCapabilities(modelID: id, configJSONData: data)
            XCTAssertFalse(caps.hybridDecoderArchitectureVerified, id)
            XCTAssertNil(caps.deepseekV4Pool)
        }
    }

    func testDeepseekV4ReferencePrefillLeavesFinalTokenAlone() {
        for (count, expected) in [(1, [1]), (1024, [1023, 1]), (2048, [2047, 1]),
                                  (2049, [2048, 1]), (4096, [2048, 2047, 1]), (4097, [2048, 2048, 1])] {
            var cursor = 0
            var chunks: [Int] = []
            while cursor < count {
                let end = DeepseekV4ContinuousBatchBackend.prefillEnd(offset: cursor, promptCount: count)
                chunks.append(end - cursor)
                cursor = end
            }
            XCTAssertEqual(chunks, expected)
        }
    }

    func testDeepseekV4RequiresSignedPositiveRuntimeTuple() {
        let tuple = Self.tuple()
        var selection = ContinuousBatchingPolicySelection.emptyOff
        XCTAssertFalse(selection.admitsDeepseekV4Pool(tuple))
        let accepted = ContinuousBatchingAcceptedTuple(
            modelID: tuple.modelID, modelSHA256: tuple.modelSHA256, cacheClass: tuple.cacheClass,
            kvDType: tuple.kvDType, requiresMoE: tuple.requiresMoE, hardwareClass: tuple.hardwareClass,
            metallibSHA256: tuple.metallibSHA256, kernelIdentifier: tuple.kernelIdentifier)
        let provenance = ContinuousBatchingPolicyProvenance(source: "test", status: "test", evidenceID: "test",
            packageManifestSHA256: "test", studioCampaignSHA256: "test", providerCLIVersion: "test", liveExecutableCDHash: "test")
        func policy(_ rollout: ContinuousBatchingMode) -> ContinuousBatchingPolicySelection {
            .init(releaseID: "test", policyVersion: "test", generatedAt: .distantPast, expiresAt: .distantFuture,
                  candidateCatalogSHA256: "test", signerKeyID: "test", source: "test",
                  entries: [.init(tupleSHA256: "test", modelKey: tuple.modelID, rollout: rollout, tuple: accepted, provenance: provenance)])
        }
        selection = policy(.off)
        XCTAssertFalse(selection.admitsDeepseekV4Pool(tuple))
        selection = policy(.canary)
        XCTAssertTrue(selection.admitsDeepseekV4Pool(tuple))
        var otherRuntime = Self.tuple(kernel: "different-runtime")
        XCTAssertFalse(selection.admitsDeepseekV4Pool(otherRuntime))
        otherRuntime = Self.tuple(modelSHA: "other-model")
        XCTAssertFalse(selection.admitsDeepseekV4Pool(otherRuntime))
        selection.revocations = [.init(modelKey: tuple.modelID, modelSHA256: tuple.modelSHA256,
            metallibSHA256: tuple.metallibSHA256, kernelIdentifier: tuple.kernelIdentifier)]
        XCTAssertFalse(selection.admitsDeepseekV4Pool(tuple))
    }

    private static func tuple(modelSHA: String = "model", kernel: String = "deepseek-v4-row-pool-decode-v1") -> ContinuousBatchingRequestedTuple {
        .init(modelID: "deepseek/deepseek-v4-flash", modelSHA256: modelSHA, tokenizerSHA256: nil,
              chatTemplateSHA256: nil, cacheClass: "mixed", kvDType: .fp16, requiresMoE: true,
              hardwareClass: "test-hardware", metallibSHA256: "test-metallib", kernelIdentifier: kernel,
              parityLabel: "test-parity", poolEpoch: 1)
    }
}
