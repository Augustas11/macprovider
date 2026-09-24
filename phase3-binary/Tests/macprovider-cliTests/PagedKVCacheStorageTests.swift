import Foundation
import MLX
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

final class PagedKVCacheStorageTests: XCTestCase {
    // MARK: - Pure layout arithmetic (no Metal)

    func testBlockCountAndRangesCoverStoredTokensWithPartialTail() {
        XCTAssertEqual(PagedKVBlockLayout.blockCount(tokens: 0, blockSizeTokens: 4), 0)
        XCTAssertEqual(PagedKVBlockLayout.blockCount(tokens: 1, blockSizeTokens: 4), 1)
        XCTAssertEqual(PagedKVBlockLayout.blockCount(tokens: 4, blockSizeTokens: 4), 1)
        XCTAssertEqual(PagedKVBlockLayout.blockCount(tokens: 5, blockSizeTokens: 4), 2)
        XCTAssertEqual(PagedKVBlockLayout.blockCount(tokens: 5, blockSizeTokens: 0), 0)
        XCTAssertEqual(PagedKVBlockLayout.blockRanges(tokens: 0, blockSizeTokens: 4), [])
        XCTAssertEqual(PagedKVBlockLayout.blockRanges(tokens: 9, blockSizeTokens: 4), [0 ..< 4, 4 ..< 8, 8 ..< 9])
        XCTAssertEqual(PagedKVBlockLayout.blockRanges(tokens: 8, blockSizeTokens: 4), [0 ..< 4, 4 ..< 8])
    }

    func testGrownCapacityUsesWholeStepsAndNeverExceedsMaxResident() {
        XCTAssertEqual(PagedKVBlockLayout.grownCapacity(stored: 0, needed: 1, maxTokens: 10_000), 256)
        XCTAssertEqual(PagedKVBlockLayout.grownCapacity(stored: 256, needed: 257, maxTokens: 10_000), 512)
        XCTAssertEqual(PagedKVBlockLayout.grownCapacity(stored: 0, needed: 300, maxTokens: 10_000), 512)
        XCTAssertEqual(PagedKVBlockLayout.grownCapacity(stored: 100, needed: 101, maxTokens: 10_000), 356)
        XCTAssertEqual(PagedKVBlockLayout.grownCapacity(stored: 0, needed: 1, maxTokens: 64), 64)
        XCTAssertEqual(PagedKVBlockLayout.grownCapacity(stored: 60, needed: 64, maxTokens: 64), 64)
        // Callers reject needed > maxTokens first; if reached, still fit the write.
        XCTAssertEqual(PagedKVBlockLayout.grownCapacity(stored: 60, needed: 70, maxTokens: 64), 70)
        XCTAssertEqual(PagedKVBlockLayout.grownCapacity(stored: Int.max - 10, needed: Int.max - 5, maxTokens: Int.max), Int.max)
    }

    func testSingleTokenGrowthNeverExceedsMaxResidentAndAlwaysFits() {
        for maxTokens in [1, 17, 255, 256, 257, 700] {
            var capacity = 0
            var growths = 0
            for stored in 0 ..< maxTokens {
                if capacity < stored + 1 {
                    capacity = PagedKVBlockLayout.grownCapacity(stored: stored, needed: stored + 1, maxTokens: maxTokens)
                    growths += 1
                }
                XCTAssertGreaterThanOrEqual(capacity, stored + 1)
                XCTAssertLessThanOrEqual(capacity, maxTokens)
            }
            XCTAssertEqual(growths, (maxTokens + 255) / 256, "maxTokens=\(maxTokens)")
        }
    }

    // MARK: - MLX storage behaviour

    func testSingleTokenUpdatesMatchConcatenatedHistoryAcrossBlockAndGrowthBoundaries() throws {
        try requireMetal()
        let cache = makeCache(blockSizeTokens: 4, maxPhysicalBlocks: 200, reconstructViaGather: false)
        var referenceKeys: MLXArray?
        var referenceValues: MLXArray?
        // A multi-token prefill, then single-token decode past the 256 growth step.
        var chunks = [5]
        chunks += Array(repeating: 1, count: 530)
        var token = 0
        for chunk in chunks {
            let keys = Self.tokens(start: token, count: chunk, salt: 0)
            let values = Self.tokens(start: token, count: chunk, salt: 7)
            token += chunk
            referenceKeys = referenceKeys.map { concatenated([$0, keys], axis: 2) } ?? keys
            referenceValues = referenceValues.map { concatenated([$0, values], axis: 2) } ?? values
            let (outKeys, outValues) = cache.update(keys: keys, values: values)
            XCTAssertEqual(outKeys.shape, [1, 2, token, 3])
            XCTAssertEqual(outKeys.dtype, .float16)
            if chunk > 1 || token % 64 == 0 || [255, 256, 257, 512, 513].contains(token) {
                XCTAssertEqual(Self.bytes(outKeys), Self.bytes(referenceKeys!), "keys at token \(token)")
                XCTAssertEqual(Self.bytes(outValues), Self.bytes(referenceValues!), "values at token \(token)")
            }
        }
        XCTAssertEqual(cache.offset, token)
        XCTAssertEqual(cache.storedTokens, token)
        XCTAssertEqual(Self.bytes(cache.state[0]), Self.bytes(referenceKeys!))
        XCTAssertEqual(Self.bytes(cache.state[1]), Self.bytes(referenceValues!))
        XCTAssertLessThanOrEqual(cache.bufferCapacityTokens, 800)
        XCTAssertEqual(cache.bufferCapacityTokens % 256 == 0 || cache.bufferCapacityTokens == 800, true)
        XCTAssertEqual(cache.debugDescription, "PagedKVCache(offset=\(token), blockSizeTokens=4, blocks=\((token + 3) / 4))")
    }

    func testGatherParityPathReturnsSameLogicalKVFromInPlaceStorage() throws {
        try requireMetal()
        PagedKVCache.resetGatherDiagnostics()
        let cache = makeCache(blockSizeTokens: 4, maxPhysicalBlocks: 16, reconstructViaGather: true)
        var reference: MLXArray?
        for step in 0 ..< 11 {
            let keys = Self.tokens(start: step, count: 1, salt: 3)
            reference = reference.map { concatenated([$0, keys], axis: 2) } ?? keys
            let (outKeys, _) = cache.update(keys: keys, values: keys)
            XCTAssertEqual(Self.bytes(outKeys), Self.bytes(reference!))
        }
        XCTAssertGreaterThan(PagedKVCache.gatherKernelCalls, 0)
        XCTAssertTrue(PagedKVCache.observedNonIdentityPermutation)
    }

    func testTrimThenUpdateStaysConsistentWithTrimmedHistory() throws {
        try requireMetal()
        let cache = makeCache(blockSizeTokens: 4, maxPhysicalBlocks: 100, reconstructViaGather: false)
        let history = Self.tokens(start: 0, count: 10, salt: 1)
        for index in 0 ..< 10 {
            _ = cache.update(keys: history[.ellipsis, index ..< index + 1, 0...], values: history[.ellipsis, index ..< index + 1, 0...])
        }
        let capacityBefore = cache.bufferCapacityTokens
        XCTAssertEqual(cache.trim(3), 3)
        XCTAssertEqual(cache.offset, 7)
        XCTAssertEqual(cache.bufferCapacityTokens, capacityBefore)
        XCTAssertEqual(Self.bytes(cache.state[0]), Self.bytes(history[.ellipsis, ..<7, 0...]))

        let fresh = Self.tokens(start: 100, count: 2, salt: 9)
        let (outKeys, _) = cache.update(keys: fresh, values: fresh)
        let expected = concatenated([history[.ellipsis, ..<7, 0...], fresh], axis: 2)
        XCTAssertEqual(Self.bytes(outKeys), Self.bytes(expected))
        XCTAssertEqual(Self.bytes(cache.state[0]), Self.bytes(expected))
        XCTAssertEqual(cache.offset, 9)

        XCTAssertEqual(cache.trim(50), 9)
        XCTAssertEqual(cache.offset, 0)
        XCTAssertTrue(cache.state.isEmpty)
        let restart = Self.tokens(start: 200, count: 1, salt: 2)
        let (restarted, _) = cache.update(keys: restart, values: restart)
        XCTAssertEqual(Self.bytes(restarted), Self.bytes(restart))
    }

    func testReturnedKVIsNotMutatedByLaterInPlaceWrites() throws {
        try requireMetal()
        let cache = makeCache(blockSizeTokens: 4, maxPhysicalBlocks: 100, reconstructViaGather: false)
        let first = Self.tokens(start: 0, count: 3, salt: 0)
        let (held, _) = cache.update(keys: first, values: first)
        let heldState = cache.state[0]
        let copy = cache.concreteCopy()
        XCTAssertEqual(cache.trim(1), 1)
        _ = cache.update(keys: Self.tokens(start: 50, count: 1, salt: 0), values: Self.tokens(start: 50, count: 1, salt: 0))
        XCTAssertEqual(Self.bytes(held), Self.bytes(first))
        XCTAssertEqual(Self.bytes(heldState), Self.bytes(first))
        XCTAssertEqual(Self.bytes(copy.state[0]), Self.bytes(first))

        // Arrays adopted through `state` stay untouched after a trim frees
        // capacity and the next update writes in place.
        let adoptedKeys = Self.tokens(start: 0, count: 6, salt: 5)
        let adoptedValues = Self.tokens(start: 0, count: 6, salt: 6)
        let expectedKeys = Self.bytes(adoptedKeys)
        let adopter = makeCache(blockSizeTokens: 4, maxPhysicalBlocks: 100, reconstructViaGather: false)
        adopter.state = [adoptedKeys, adoptedValues]
        XCTAssertEqual(adopter.trim(2), 2)
        let replacement = Self.tokens(start: 70, count: 1, salt: 0)
        let (afterTrim, _) = adopter.update(keys: replacement, values: replacement)
        XCTAssertEqual(
            Self.bytes(afterTrim),
            Self.bytes(concatenated([adoptedKeys[.ellipsis, ..<4, 0...], replacement], axis: 2))
        )
        XCTAssertEqual(Self.bytes(adoptedKeys), expectedKeys)
    }

    func testUpdateBeyondMaxResidentIsRejectedAndCapacityIsCapped() throws {
        try requireMetal()
        let cache = makeCache(blockSizeTokens: 4, maxPhysicalBlocks: 3, reconstructViaGather: false)
        for index in 0 ..< 12 {
            let token = Self.tokens(start: index, count: 1, salt: 0)
            _ = cache.update(keys: token, values: token)
            XCTAssertLessThanOrEqual(cache.bufferCapacityTokens, 12)
        }
        XCTAssertEqual(cache.bufferCapacityTokens, 12)
        let overflow = Self.tokens(start: 99, count: 1, salt: 0)
        let (returned, _) = cache.update(keys: overflow, values: overflow)
        XCTAssertEqual(returned.shape, overflow.shape)
        XCTAssertEqual(cache.offset, 12)
        XCTAssertEqual(cache.storedTokens, 12)
        XCTAssertEqual(cache.bufferCapacityTokens, 12)
    }

    func testRecordAndMaterializeAfterInPlaceUpdatesYieldSamePhysicalBlocks() async throws {
        try requireMetal()
        let descriptor = Self.descriptor(blockSizeTokens: 4, maxPhysicalBlocks: 8)
        let bridge = PagedKVRuntimeContiguousCacheBridge()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: 4,
            maxPhysicalBlocks: 8,
            physicalBlockOrder: [6, 2, 7, 0, 5, 1, 4, 3],
            contiguousCacheBridge: bridge
        )
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 32, initialTokens: 10)
        let binding = try await allocator.binding(for: handle)

        let keys = Self.tokens(start: 0, count: 10, salt: 4)
        let values = Self.tokens(start: 0, count: 10, salt: 5)
        let stepped = PagedKVCache(descriptor: descriptor, binding: binding, initialOffset: 0)
        for index in 0 ..< 10 {
            _ = stepped.update(
                keys: keys[.ellipsis, index ..< index + 1, 0...],
                values: values[.ellipsis, index ..< index + 1, 0...]
            )
        }
        let adopted = PagedKVCache(descriptor: descriptor, binding: binding)
        adopted.state = [keys, values]

        try stepped.validateRecordable(table: binding.currentTable)
        let steppedBlocks = try stepped.physicalLayerBlocks(layerIndex: 0, table: binding.currentTable)
        let adoptedBlocks = try adopted.physicalLayerBlocks(layerIndex: 0, table: binding.currentTable)
        XCTAssertEqual(steppedBlocks, adoptedBlocks)
        XCTAssertEqual(Set(steppedBlocks.keyBlocks.keys), Set(binding.currentTable.physicalBlocks))

        try bridge.record(caches: [stepped], binding: binding)
        let materialized = try bridge.materializeContiguousByteCache(handle: handle, table: binding.currentTable)
        XCTAssertEqual(materialized.layers[0].keyBytes, Self.bytes(keys))
        XCTAssertEqual(materialized.layers[0].valueBytes, Self.bytes(values))

        // A cache whose stored tokens no longer match the table fails closed.
        stepped.trim(1)
        XCTAssertThrowsError(try stepped.validateRecordable(table: binding.currentTable))
    }

    // MARK: - Helpers

    private func requireMetal() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    private func makeCache(blockSizeTokens: Int, maxPhysicalBlocks: Int, reconstructViaGather: Bool) -> PagedKVCache {
        PagedKVCache(
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: 1,
            binding: Self.detachedBinding(),
            initialOffset: 0,
            reconstructViaGather: reconstructViaGather
        )
    }

    /// `[1, 2, count, 3]` float16 tokens with distinct, exactly representable values.
    private static func tokens(start: Int, count: Int, salt: Int) -> MLXArray {
        var values: [Float] = []
        for head in 0 ..< 2 {
            for token in start ..< start + count {
                for lane in 0 ..< 3 {
                    values.append(Float((token * 7 + head * 3 + lane + salt * 11) % 1024) - 512)
                }
            }
        }
        return MLXArray(values, [1, 2, count, 3]).asType(.float16)
    }

    private static func bytes(_ array: MLXArray) -> Data {
        array.asData(access: .copy).data
    }

    private static func detachedBinding() -> PagedKVStorageBinding {
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "storage-test", poolEpoch: 1)
        return PagedKVStorageBinding(
            handle: handle,
            blockSizeTokens: 4,
            maxLogicalTokens: 4096,
            currentTable: PagedKVBlockTable(
                handleID: handle.handleID,
                blockSizeTokens: 4,
                logicalTokenCount: 0,
                physicalBlocks: [],
                tailValidTokenCount: 0,
                poolEpoch: 1
            ),
            poolEpoch: 1
        )
    }

    private static func descriptor(blockSizeTokens: Int, maxPhysicalBlocks: Int) -> PagedKVDescriptor {
        PagedKVDescriptor(
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            supportedModelFamilies: ["qwen"],
            supportsMoEDispatch: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            parityLabel: "sdpa-parity-v1"
        )
    }
}
