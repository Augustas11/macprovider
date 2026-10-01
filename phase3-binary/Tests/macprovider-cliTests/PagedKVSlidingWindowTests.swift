import Foundation
import MLX
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

final class PagedKVSlidingWindowTests: XCTestCase {
    func testRotatingCacheKindMapsKeepZeroAndRejectsSinkPrefix() {
        XCTAssertEqual(
            PagedKVSharedForwardBackend.CacheKind.recognized(from: KVCacheSimple()),
            .pagedAttention
        )
        XCTAssertEqual(
            PagedKVSharedForwardBackend.CacheKind.recognized(from: MambaCache()),
            .recurrentMamba
        )
        XCTAssertEqual(
            PagedKVSharedForwardBackend.CacheKind.recognized(from: RotatingKVCache(maxSize: 128, keep: 0)),
            .slidingWindow(windowTokens: 128)
        )
        XCTAssertNil(
            PagedKVSharedForwardBackend.CacheKind.recognized(from: RotatingKVCache(maxSize: 128, keep: 4)),
            "keep>0 sink-token rotation is not equivalent to keep=0 rotating-window presentation"
        )
        XCTAssertNil(PagedKVSharedForwardBackend.CacheKind.recognized(from: RotatingKVCache(maxSize: 0, keep: 0)))
    }

    func testLayoutMapsGptOssStyleAlternatingLayers() {
        let caches: [KVCache] = [
            RotatingKVCache(maxSize: 128, keep: 0),
            KVCacheSimple(),
            RotatingKVCache(maxSize: 128, keep: 0),
            KVCacheSimple(),
        ]
        let kinds = PagedKVSharedForwardBackend.CacheKind.kinds(from: caches)
        XCTAssertEqual(kinds, [
            .slidingWindow(windowTokens: 128),
            .pagedAttention,
            .slidingWindow(windowTokens: 128),
            .pagedAttention,
        ])
        XCTAssertEqual(kinds?.filter(\.usesPagedKVCache).count, 4)
        XCTAssertTrue(kinds?.contains(where: \.hasSlidingWindow) == true)
        XCTAssertNil(
            PagedKVSharedForwardBackend.CacheKind.kinds(from: [
                RotatingKVCache(maxSize: 128, keep: 4),
                KVCacheSimple(),
            ])
        )
    }

    func testGptOssIdentityIsNotAQwenHybridAllowlistHit() {
        let config = Data(#"{"model_type":"gpt_oss","architectures":["GptOssForCausalLM"]}"#.utf8)
        let capabilities = ModelRuntime.pagedKVModelCapabilities(
            modelID: "openai/gpt-oss-20b",
            configJSONData: config
        )
        XCTAssertEqual(capabilities.modelFamily, "gpt_oss")
        XCTAssertFalse(capabilities.hybridDecoderArchitectureVerified)
        XCTAssertFalse(PagedKVAttachGate.supportsCacheClass("mixed"))
        XCTAssertFalse(PagedKVAttachGate.supportsCacheClass("RotatingKVCache", hybridDecoderArchitectureVerified: true))
        XCTAssertFalse(PagedKVAttachGate.supportsCacheClass(
            "mixed",
            hybridDecoderArchitectureVerified: capabilities.hybridDecoderArchitectureVerified
        ))
    }

    func testLegacyFullHistoryMaskPredicateStillWindows() {
        XCTAssertFalse(PagedKVCache.slidingWindowRequiresMask(n: 5, offset: 0, windowSize: 8))
        XCTAssertFalse(PagedKVCache.slidingWindowRequiresMask(n: 1, offset: 7, windowSize: 8))
        XCTAssertTrue(PagedKVCache.slidingWindowRequiresMask(n: 1, offset: 8, windowSize: 8))
        XCTAssertTrue(PagedKVCache.slidingWindowRequiresMask(n: 5, offset: 10, windowSize: 8))
        XCTAssertFalse(PagedKVCache.slidingWindowRequiresMask(n: 1, offset: 100, windowSize: nil))
    }

    func testPagedSingleTokenDecodePastWindowPresentsOnlyWindow() throws {
        try requireMetal()
        Device.withDefaultDevice(.cpu) {
            let short = makeCache(offset: 0, windowTokens: 8)
            _ = short.update(
                keys: MLXArray.zeros([1, 1, 3, 1], dtype: .float32),
                values: MLXArray.zeros([1, 1, 3, 1], dtype: .float32)
            )
            switch short.makeMask(n: 1, windowSize: 8, returnArray: false) {
            case .none:
                break
            default:
                XCTFail("history shorter than the window must keep the no-mask decode fast path")
            }

            let cache = makeCache(offset: 0, windowTokens: 8)
            _ = cache.update(
                keys: MLXArray.zeros([1, 1, 10, 1], dtype: .float32),
                values: MLXArray.zeros([1, 1, 10, 1], dtype: .float32)
            )
            switch cache.makeMask(n: 1, windowSize: 8, returnArray: false) {
            case .none:
                break
            default:
                XCTFail("single-token decode over an already-windowed presentation needs no array mask")
            }
            let presented = cache.update(
                keys: MLXArray.zeros([1, 1, 1, 1], dtype: .float32),
                values: MLXArray.zeros([1, 1, 1, 1], dtype: .float32)
            )
            XCTAssertEqual(presented.0.dim(2), 8)
            XCTAssertEqual(cache.state[0].dim(2), 11, "paged storage keeps full history for materialization")
        }
    }

    func testPagedMultiTokenPrefillPastWindowMatchesRotatingPresentation() throws {
        try requireMetal()
        Device.withDefaultDevice(.cpu) {
            let cache = makeCache(offset: 0, windowTokens: 8)
            _ = cache.update(
                keys: MLXArray.zeros([1, 1, 10, 1], dtype: .float32),
                values: MLXArray.zeros([1, 1, 10, 1], dtype: .float32)
            )
            switch cache.makeMask(n: 5, windowSize: 8, returnArray: false) {
            case .array(let mask):
                eval(mask)
                XCTAssertEqual(mask.dim(0), 5)
                XCTAssertEqual(mask.dim(1), 12)
            default:
                XCTFail("multi-token prefill crossing the window needs a capped-offset array mask")
            }
            let presented = cache.update(
                keys: MLXArray.zeros([1, 1, 5, 1], dtype: .float32),
                values: MLXArray.zeros([1, 1, 5, 1], dtype: .float32)
            )
            XCTAssertEqual(presented.0.dim(2), 12)
            XCTAssertEqual(cache.state[0].dim(2), 15)
        }
    }

    func testBatchedEqualLengthDecodePastWindowUsesPresentedWindow() throws {
        switch PagedKVSharedForwardBackend.batchLayerMaskForTest(
            rowCaches: [
                makeCache(offset: 10, windowTokens: 8),
                makeCache(offset: 10, windowTokens: 8),
            ],
            n: 1,
            windowSize: 8
        ) {
        case .none:
            break
        default:
            XCTFail("equal-length batched decode over windowed presentations needs no array mask")
        }
    }

    private func requireMetal() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    private func makeCache(offset: Int, windowTokens: Int? = nil) -> PagedKVCache {
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "sliding-window-test", poolEpoch: 1)
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
            initialOffset: offset,
            reconstructViaGather: false,
            attentionWindowTokens: windowTokens
        )
    }
}
