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

    /// Decode keys reach SDPA in the slot order a keep=0 `RotatingKVCache`
    /// holds them, through prefill chunks, a short prompt that wraps during
    /// decode, and a one-token remainder chunk. Each key carries its token
    /// position, so equal arrays mean equal slot order.
    func testSlidingWindowPresentationMatchesRotatingCacheSlotOrder() throws {
        try requireMetal()
        let window = 8
        let schedules: [[Int]] = [[10, 5], [3], [12, 1], [8], [2, 2, 2]]
        Device.withDefaultDevice(.cpu) {
            for chunks in schedules {
                let updates = chunks + Array(repeating: 1, count: 3 * window + 3)
                let rotating = RotatingKVCache(maxSize: window, keep: 0)
                let paged = makeCache(offset: 0, windowTokens: window)
                var position = 0
                for (step, count) in updates.enumerated() {
                    let keys = Self.positions(position, count)
                    position += count
                    let expected = rotating.update(keys: keys, values: keys).0
                    let presented = paged.update(keys: keys, values: keys).0
                    XCTAssertEqual(
                        presented.asArray(Float.self), expected.asArray(Float.self),
                        "chunks \(chunks), update \(step)"
                    )
                }
            }
        }
    }

    /// Lockstep rows at one offset take their own ring layout: each row's
    /// slot order follows its own last prefill chunk.
    func testBatchedLockstepDecodeGivesEachRowItsRotatingSlotOrder() throws {
        try requireMetal()
        let window = 8
        Device.withDefaultDevice(.cpu) {
            let rowChunks: [[Int]] = [[10, 5], [12, 1, 1, 1]]
            var references: [RotatingKVCache] = []
            var rows: [PagedKVCache] = []
            for chunks in rowChunks {
                let rotating = RotatingKVCache(maxSize: window, keep: 0)
                let paged = makeCache(offset: 0, windowTokens: window)
                var position = 0
                for count in chunks {
                    let keys = Self.positions(position, count)
                    position += count
                    _ = rotating.update(keys: keys, values: keys)
                    _ = paged.update(keys: keys, values: keys)
                }
                references.append(rotating)
                rows.append(paged)
            }
            let batch = PagedKVSharedForwardBackend.batchLayerCacheForTest(rowCaches: rows)
            var position = 15
            for step in 0 ..< 2 * window + 3 {
                let keys = Self.positions(position, 1)
                position += 1
                let expected = references.map { $0.update(keys: keys, values: keys).0.asArray(Float.self) }
                let presented = batch.update(
                    keys: concatenated([keys, keys], axis: 0),
                    values: concatenated([keys, keys], axis: 0)
                ).0
                for row in 0 ..< 2 {
                    XCTAssertEqual(
                        presented[row ..< row + 1].asArray(Float.self), expected[row],
                        "row \(row), step \(step)"
                    )
                }
            }
        }
    }

    /// A multi-token update after the ring wrapped (a later prefill chunk or
    /// a multi-token commit) linearizes the window like `RotatingKVCache`,
    /// and decode after it follows the new ring.
    func testMultiTokenUpdateAfterWrapMatchesRotatingCacheSlotOrder() throws {
        try requireMetal()
        let window = 8
        let schedules: [[Int]] = [
            [10, 5] + Array(repeating: 1, count: 13) + [3],
            [3] + Array(repeating: 1, count: 12) + [2] + Array(repeating: 1, count: 5) + [9],
        ]
        Device.withDefaultDevice(.cpu) {
            for chunks in schedules {
                let rotating = RotatingKVCache(maxSize: window, keep: 0)
                let paged = makeCache(offset: 0, windowTokens: window)
                var position = 0
                for (step, count) in (chunks + Array(repeating: 1, count: 2 * window + 3)).enumerated() {
                    let keys = Self.positions(position, count)
                    position += count
                    let expected = rotating.update(keys: keys, values: keys).0
                    let presented = paged.update(keys: keys, values: keys).0
                    XCTAssertEqual(
                        presented.asArray(Float.self), expected.asArray(Float.self),
                        "chunks \(chunks), update \(step)"
                    )
                }
            }
        }
    }

    /// A row that wrapped, was trimmed to a shared prefix and resumes with a
    /// one-token or multi-token prompt chunk presents the slot order of a
    /// serial run that prefilled that prefix and continues with the same
    /// chunks. The serial ring cannot be trimmed once wrapped, so serial
    /// resume is a cold prefill to the same boundary.
    func testTrimmedWrappedRowResumesInColdPrefillRingOrder() throws {
        try requireMetal()
        let window = 8
        Device.withDefaultDevice(.cpu) {
            for (trimTo, suffix) in [(20, [1]), (20, [3]), (19, [1, 1]), (6, [1])] {
                let paged = makeCache(offset: 0, windowTokens: window)
                let wrapped = RotatingKVCache(maxSize: window, keep: 0)
                var position = 0
                for count in [10, 5] + Array(repeating: 1, count: 13) {
                    let keys = Self.positions(position, count)
                    position += count
                    _ = paged.update(keys: keys, values: keys)
                    _ = wrapped.update(keys: keys, values: keys)
                }
                XCTAssertFalse(wrapped.isTrimmable, "serial ring refuses trim once wrapped")
                XCTAssertEqual(paged.trim(position - trimTo), position - trimTo)

                let rotating = RotatingKVCache(maxSize: window, keep: 0)
                let prefix = Self.positions(0, trimTo)
                _ = rotating.update(keys: prefix, values: prefix)
                position = trimTo
                for (step, count) in (suffix + Array(repeating: 1, count: 2 * window + 3)).enumerated() {
                    let keys = Self.positions(position, count)
                    position += count
                    let expected = rotating.update(keys: keys, values: keys).0
                    let presented = paged.update(keys: keys, values: keys).0
                    XCTAssertEqual(
                        presented.asArray(Float.self), expected.asArray(Float.self),
                        "trim to \(trimTo), suffix \(suffix), update \(step)"
                    )
                }
            }
        }
    }

    private static func positions(_ start: Int, _ count: Int) -> MLXArray {
        MLXArray((start ..< start + count).map(Float.init), [1, 1, count, 1])
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
