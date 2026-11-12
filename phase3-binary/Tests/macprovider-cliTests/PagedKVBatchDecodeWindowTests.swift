import Foundation
import MLX
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Decode windows over one shared batch layer cache, synced to the rows at
/// every window end as `performDecode` does (#2256). Keys carry their token
/// position, so equal arrays mean equal slot order: every row must present
/// exactly what its own serial cache (`RotatingKVCache` for a sliding window,
/// its plain history otherwise) holds, in lockstep and ragged batches alike.
/// The paged gather runs a Metal kernel, so the suite skips on hosts without
/// the MLX default metallib (CI runners).
final class PagedKVBatchDecodeWindowTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // The test bundle's metallib counts too: under `swift test`,
        // `Bundle.main` is Xcode's xctest runner, so the main-bundle check alone
        // skipped this suite on every host.
        guard MLXTestDevice.metallibAvailable else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    func testLockstepWindowsKeepEachRowsRotatingSlotOrderAcrossSync() throws {
        try runSlidingWindows(rowChunks: [[10, 5], [12, 1, 1, 1]], window: 8, windows: 4, stepsPerWindow: 5)
    }

    func testRaggedWindowsKeepEachRowsRotatingSlotOrderAcrossSync() throws {
        try runSlidingWindows(
            rowChunks: [[10, 5], [12, 1, 1, 1, 1, 1, 1], [20], [7]],
            window: 8,
            windows: 4,
            stepsPerWindow: 6
        )
        XCTAssertGreaterThan(
            PagedKVSharedForwardBackend.batchLayerDeferredRaggedDecodeStepsForTest, 0,
            "ragged one-token decode with every window full writes the batch buffer only"
        )
    }

    func testRaggedRowShorterThanWindowKeepsRotatingSlotOrder() throws {
        try runSlidingWindows(rowChunks: [[3], [10, 5], [2, 1]], window: 8, windows: 4, stepsPerWindow: 5)
    }

    func testRaggedFullAttentionRowsMatchTheirHistoryAcrossSync() throws {
        Device.withDefaultDevice(.cpu) {
            let lengths = [5, 9, 13, 9]
            let rows = lengths.map { length -> PagedKVCache in
                let cache = makeCache(windowTokens: nil)
                _ = cache.update(keys: Self.positions(0, length), values: Self.positions(0, length))
                return cache
            }
            let batch = PagedKVSharedForwardBackend.batchLayerCacheForTest(rowCaches: rows)
            var positions = lengths
            for window in 0 ..< 3 {
                for step in 0 ..< 6 {
                    let incoming = concatenated(positions.map { Self.positions($0, 1) }, axis: 0)
                    let presented = batch.update(keys: incoming, values: incoming).0
                    positions = positions.map { $0 + 1 }
                    let longest = positions.max()!
                    XCTAssertEqual(presented.dim(2), longest, "window \(window), step \(step)")
                    for (row, length) in positions.enumerated() {
                        let expected = (0 ..< length).map(Float.init) + Array(repeating: 0, count: longest - length)
                        XCTAssertEqual(
                            presented[row ..< row + 1].asArray(Float.self), expected,
                            "window \(window), step \(step), row \(row)"
                        )
                    }
                }
                PagedKVSharedForwardBackend.batchLayerSyncRowsForTest(batch)
                for (row, cache) in rows.enumerated() {
                    XCTAssertEqual(cache.offset, positions[row])
                    XCTAssertEqual(cache.storedTokens, positions[row])
                    XCTAssertEqual(cache.state[0].asArray(Float.self), (0 ..< positions[row]).map(Float.init))
                }
            }
        }
    }

    /// Rows prefilled with their own chunks decode `windows` windows through
    /// one batch cache; each step's presentation must equal the row's
    /// `RotatingKVCache`, and each sync must leave the row's full history.
    private func runSlidingWindows(rowChunks: [[Int]], window: Int, windows: Int, stepsPerWindow: Int) throws {
        Device.withDefaultDevice(.cpu) {
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
            let batch = PagedKVSharedForwardBackend.batchLayerCacheForTest(rowCaches: rows)
            for windowIndex in 0 ..< windows {
                for step in 0 ..< stepsPerWindow {
                    let perRow = positions.map { Self.positions($0, 1) }
                    let expected = zip(references, perRow).map { $0.update(keys: $1, values: $1).0 }
                    let incoming = concatenated(perRow, axis: 0)
                    let presented = batch.update(keys: incoming, values: incoming).0
                    positions = positions.map { $0 + 1 }
                    let longest = expected.map { $0.dim(2) }.max()!
                    XCTAssertEqual(presented.dim(2), longest, "window \(windowIndex), step \(step)")
                    for row in rows.indices {
                        let rowKeys = expected[row].asArray(Float.self)
                        let padded = rowKeys + Array(repeating: 0, count: longest - rowKeys.count)
                        XCTAssertEqual(
                            presented[row ..< row + 1].asArray(Float.self), padded,
                            "rows \(rowChunks), window \(windowIndex), step \(step), row \(row)"
                        )
                    }
                }
                PagedKVSharedForwardBackend.batchLayerSyncRowsForTest(batch)
                for (row, cache) in rows.enumerated() {
                    XCTAssertEqual(cache.offset, positions[row])
                    XCTAssertEqual(cache.state[0].asArray(Float.self), (0 ..< positions[row]).map(Float.init))
                }
            }
        }
    }

    private static func positions(_ start: Int, _ count: Int) -> MLXArray {
        MLXArray((start ..< start + count).map(Float.init), [1, 1, count, 1])
    }

    private func makeCache(windowTokens: Int?) -> PagedKVCache {
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "batch-decode-window-test", poolEpoch: 1)
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
            attentionWindowTokens: windowTokens
        )
    }
}
