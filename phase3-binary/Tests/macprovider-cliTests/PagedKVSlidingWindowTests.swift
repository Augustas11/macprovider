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
            "keep>0 sink-token rotation is not equivalent to a windowed full-history mask"
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

    func testShortPrefillOnLongHistoryStillWindows() {
        XCTAssertFalse(PagedKVCache.slidingWindowRequiresMask(n: 5, offset: 0, windowSize: 8))
        XCTAssertFalse(PagedKVCache.slidingWindowRequiresMask(n: 1, offset: 7, windowSize: 8))
        XCTAssertTrue(PagedKVCache.slidingWindowRequiresMask(n: 1, offset: 8, windowSize: 8))
        XCTAssertTrue(PagedKVCache.slidingWindowRequiresMask(n: 5, offset: 10, windowSize: 8))
        XCTAssertFalse(PagedKVCache.slidingWindowRequiresMask(n: 1, offset: 100, windowSize: nil))
    }

    func testPagedMaskAppliesWindowOnSingleTokenDecodePastTheWindow() throws {
        try requireMetal()
        Device.withDefaultDevice(.cpu) {
            switch makeCache(offset: 3).makeMask(n: 1, windowSize: 8, returnArray: false) {
            case .none:
                break
            default:
                XCTFail("history shorter than the window must keep the no-mask decode fast path")
            }

            let cache = makeCache(offset: 9)
            let mask: MLXArray
            switch cache.makeMask(n: 1, windowSize: 8, returnArray: false) {
            case .array(let array):
                mask = array
            default:
                return XCTFail("single-token decode past the window must return a windowed array mask")
            }
            eval(mask)
            let values = mask.asArray(Bool.self)
            XCTAssertEqual(values.filter { $0 }.count, 8, "query must see exactly the last window tokens")
            XCTAssertEqual(Array(values.prefix(2)), [false, false], "keys older than the window must be masked")
            XCTAssertEqual(Array(values.suffix(8)), Array(repeating: true, count: 8))
        }
    }

    func testBatchedEqualLengthDecodePastWindowKeepsWindowMask() throws {
        try requireMetal()
        Device.withDefaultDevice(.cpu) {
            switch PagedKVSharedForwardBackend.batchLayerMaskForTest(
                rowCaches: [makeCache(offset: 10), makeCache(offset: 10)],
                n: 1,
                windowSize: 8
            ) {
            case .array(let mask):
                eval(mask)
                XCTAssertFalse(mask.asArray(Bool.self).allSatisfy { $0 })
            default:
                XCTFail("equal-length batched decode past the window must not return .none")
            }
        }
    }

    private func requireMetal() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    private func makeCache(offset: Int) -> PagedKVCache {
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
            reconstructViaGather: false
        )
    }
}
