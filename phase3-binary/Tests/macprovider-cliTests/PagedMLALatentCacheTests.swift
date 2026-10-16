import Foundation
import MLX
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-039 FR-PKV4/FR-PKV15 `pagedMLA`: `PagedMLALatentCache` is bit-for-bit
/// the stock `GLM5NextAttentionCache` (latent, pooled keys, pending and folded
/// windows, exact trim), with and without the parity gather, and the packed
/// verification batch keeps exactly the accepted prefix of each row.
final class PagedMLALatentCacheTests: XCTestCase {
    private let latentWidth = 8
    private let indexDim = 4
    private let kpool = 4
    private let blockSize = 8

    func testMatchesStockCacheAcrossChunksDecodeAndTrims() throws {
        try requireMetal()
        for gather in [false, true] {
            try runScript(reconstructViaGather: gather)
        }
    }

    func testParityGatherCoversBothBuffersOnOneBlockTable() throws {
        try requireMetal()
        let paged = makeCache(reconstructViaGather: true)
        var rng = SplitMix(seed: 7)
        PagedKVCache.resetGatherDiagnostics()
        // 21 tokens: 3 latent blocks of 8; 5 pooled keys in pooled blocks of 2.
        // One forward: the latent append and the indexer's pooled-key read.
        step(paged, nil, length: 21, rng: &rng)
        XCTAssertEqual(PagedKVCache.gatherKernelCalls, 2)
        XCTAssertEqual(PagedKVCache.maxLogicalBlocksObserved, 3)
        XCTAssertTrue(PagedKVCache.observedNonIdentityPermutation)
    }

    func testCapacityIsWholeBlocksForBothBuffers() throws {
        try requireMetal()
        let cache = makeCache()
        var rng = SplitMix(seed: 3)
        step(cache, nil, length: 9, rng: &rng)
        XCTAssertEqual(cache.latentCapacityTokens, 16)
        XCTAssertEqual(cache.pooledCount, 2)
        XCTAssertEqual(cache.pooledCapacity, 2)
        for _ in 0 ..< 8 { step(cache, nil, length: 1, rng: &rng) }
        XCTAssertEqual(cache.offset, 17)
        XCTAssertEqual(cache.latentCapacityTokens, 24)
        XCTAssertEqual(cache.pooledCount, 4)
        XCTAssertEqual(cache.pooledCapacity, 4)
        XCTAssertEqual(cache.trim(9), 9)
        XCTAssertEqual(cache.latentCapacityTokens, 8)
        XCTAssertEqual(cache.pooledCapacity, 2)
    }

    func testCopyIsIndependent() throws {
        try requireMetal()
        let cache = makeCache()
        var rng = SplitMix(seed: 11)
        step(cache, nil, length: 6, rng: &rng)
        let before = cache.state
        let copied = cache.concreteCopy()
        step(copied, nil, length: 5, rng: &rng)
        XCTAssertEqual(cache.offset, 6)
        XCTAssertEqual(copied.offset, 11)
        assertStatesEqual(cache.state, before, "original changed by its copy")
    }

    func testPackedVerificationKeepsExactlyTheAcceptedPrefixPerRow() throws {
        try requireMetal()
        var rng = SplitMix(seed: 21)
        // Two rows at different offsets; width 3 (2 proposals) each.
        let rows = [makeCache(), makeCache()]
        let oracles = [stock(), stock()]
        step(rows[0], oracles[0], length: 13, rng: &rng)
        step(rows[1], oracles[1], length: 6, rng: &rng)

        for accepted in [[3, 1], [1, 2], [2, 3]] {
            let batch = PagedMLABatchLayerCache(rowCaches: rows)
            try batch.prepareMTPPackedVerification(rowMaps: rows.enumerated().map {
                MTPPackedVerificationRowMap(rowIndex: $0.offset, queryOffset: $0.element.offset, inputCount: 3, proposalCount: 2)
            })
            XCTAssertEqual(batch.mtpPackedHostBatchOffsets, rows.map(\.offset))
            // The model appends every column to each staged row.
            var columns: [(MLXArray, MLXArray, MLXArray)] = []
            for staged in batch.rowCaches {
                let input = randomInputs(length: 3, rng: &rng)
                columns.append(input)
                apply(staged, input)
            }
            XCTAssertEqual(rows.map(\.offset), oracles.map(\.offset), "verification mutated a live row")
            batch.finalize()
            let resolutions = try batch.pendingMTPResolutions()
            for (index, resolution) in resolutions.enumerated() {
                _ = try resolution.stageCommit(inputCount: accepted[index])
                let (latent, keys, gates) = columns[index]
                apply(oracles[index], (
                    latent[.ellipsis, ..<accepted[index], 0...],
                    keys[0..., ..<accepted[index], 0...],
                    gates[0..., ..<accepted[index], 0...]
                ))
                XCTAssertEqual(rows[index].offset, oracles[index].offset)
                assertStatesEqual(rows[index].state, oracles[index].state, "row \(index) accepted \(accepted[index])")
            }
        }
    }

    func testAbortedVerificationLeavesRowsUntouched() throws {
        try requireMetal()
        var rng = SplitMix(seed: 5)
        let row = makeCache()
        step(row, nil, length: 10, rng: &rng)
        let before = row.state
        let batch = PagedMLABatchLayerCache(rowCaches: [row])
        try batch.prepareMTPPackedVerification(rowMaps: [
            MTPPackedVerificationRowMap(rowIndex: 0, queryOffset: 10, inputCount: 4, proposalCount: 3),
        ])
        apply(batch.rowCaches[0], randomInputs(length: 4, rng: &rng))
        batch.finalize()
        XCTAssertEqual(row.offset, 10)
        assertStatesEqual(row.state, before, "abort")
        XCTAssertThrowsError(try batch.prepareMTPPackedVerification(rowMaps: [
            MTPPackedVerificationRowMap(rowIndex: 0, queryOffset: 9, inputCount: 2, proposalCount: 1),
        ]))
    }

    // MARK: - Script

    private func runScript(reconstructViaGather: Bool) throws {
        var rng = SplitMix(seed: reconstructViaGather ? 2 : 1)
        let paged = makeCache(reconstructViaGather: reconstructViaGather)
        let oracle = stock()
        // Prefill chunks crossing blocks and pool windows, then decode with
        // MTP-shaped trims (each within maxTrim) that split pool windows.
        let script: [(append: Int, trim: Int)] = [
            (7, 0), (10, 0), (1, 0), (1, 0), (3, 2), (1, 0), (5, 3), (1, 1), (8, 7),
            (1, 0), (4, 4), (2, 0), (16, 16), (1, 0), (6, 5), (1, 0),
        ]
        for (index, entry) in script.enumerated() {
            step(paged, oracle, length: entry.append, rng: &rng, label: "step \(index) gather=\(reconstructViaGather)")
            if entry.trim > 0 {
                XCTAssertTrue(paged.isTrimmable(after: entry.trim))
                XCTAssertEqual(paged.trim(entry.trim), oracle.trim(entry.trim))
                XCTAssertEqual(paged.offset, oracle.offset)
                assertStatesEqual(paged.state, oracle.state, "trim at step \(index) gather=\(reconstructViaGather)")
            }
        }
        XCTAssertEqual(paged.offset, oracle.offset)
    }

    /// One forward's cache traffic, as GLM5NextAttention drives it.
    private func step(
        _ paged: PagedMLALatentCache,
        _ oracle: GLM5NextAttentionCache?,
        length: Int,
        rng: inout SplitMix,
        label: String = ""
    ) {
        let input = randomInputs(length: length, rng: &rng)
        let pagedOut = apply(paged, input)
        guard let oracle else { return }
        let stockOut = apply(oracle, input)
        XCTAssertTrue(equal(pagedOut.latent, stockOut.latent), "latent \(label)")
        switch (pagedOut.pooled, stockOut.pooled) {
        case (nil, nil): break
        case let (lhs?, rhs?): XCTAssertTrue(equal(lhs, rhs), "pooled \(label)")
        default: XCTFail("pooled presence differs \(label)")
        }
        switch (paged.validLatent, oracle.validLatent) {
        case (nil, nil): break
        case let (lhs?, rhs?): XCTAssertTrue(equal(lhs, rhs), "validLatent \(label)")
        default: XCTFail("validLatent presence differs \(label)")
        }
        assertStatesEqual(paged.state, oracle.state, label)
    }

    @discardableResult
    private func apply(
        _ cache: any GLM5NextLatentCache,
        _ input: (MLXArray, MLXArray, MLXArray)
    ) -> (latent: MLXArray, pooled: MLXArray?) {
        let latent = cache.appendLatent(input.0)
        if let (keys, gates) = cache.takeCompleteWindows(keys: input.1, gates: input.2) {
            // A deterministic stand-in for the indexer's gated compression.
            let windows = keys.dim(1) / kpool
            let pooled = (keys * gates).reshaped([1, windows, kpool, indexDim]).sum(axis: 2)
            cache.appendPooled(pooled)
        }
        let pooled = cache.pooledKeys
        eval([latent] + (pooled.map { [$0] } ?? []))
        return (latent, pooled)
    }

    private func randomInputs(length: Int, rng: inout SplitMix) -> (MLXArray, MLXArray, MLXArray) {
        func values(_ count: Int) -> [Float] { (0 ..< count).map { _ in rng.nextFloat() } }
        return (
            MLXArray(values(length * latentWidth)).reshaped([1, 1, length, latentWidth]).asType(.bfloat16),
            MLXArray(values(length * indexDim)).reshaped([1, length, indexDim]).asType(.bfloat16),
            MLXArray(values(length * indexDim)).reshaped([1, length, indexDim]).asType(.bfloat16)
        )
    }

    private func makeCache(reconstructViaGather: Bool = false) -> PagedMLALatentCache {
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "paged-mla-test", poolEpoch: 1)
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
        return PagedMLALatentCache(
            kpool: kpool,
            blockSizeTokens: blockSize,
            maxPhysicalBlocks: 64,
            poolEpoch: 1,
            binding: binding,
            reconstructViaGather: reconstructViaGather
        )
    }

    private func stock() -> GLM5NextAttentionCache {
        GLM5NextAttentionCache(kpool: kpool)
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
        guard PagedKVMetallibGate.defaultMetallibExists() else {
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
