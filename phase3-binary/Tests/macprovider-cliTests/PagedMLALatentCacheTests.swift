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

    /// SPEC-024 FR-CI2a: a CB row's prompt snapshot converts each paged
    /// latent cache into a serial `GLM5NextAttentionCache` that equals the
    /// stock cache fed the same tokens and keeps equalling it as the next turn
    /// extends it. CPU only.
    func testPromptSnapshotConversionEqualsAndExtendsLikeTheStockCacheOnCPU() throws {
        try requireMetal()
        Device.withDefaultDevice(.cpu) {
            var rng = SplitMix(seed: 31)
            let paged = makeCache()
            let oracle = stock()
            for length in [7, 10, 1, 3] {
                step(paged, oracle, length: length, rng: &rng, label: "prefill \(length)")
            }
            let snapshot = PagedKVSharedForwardBackend.serialAttentionCache(copying: paged)
            XCTAssertEqual(snapshot.offset, paged.offset)
            assertStatesEqual(snapshot.state, oracle.state, "converted snapshot")
            // The paged source keeps moving; the snapshot must not.
            step(paged, nil, length: 5, rng: &rng)
            assertStatesEqual(snapshot.state, oracle.state, "snapshot after source advanced")
            var resumed = SplitMix(seed: 97)
            var fresh = SplitMix(seed: 97)
            for length in [9, 1, 1, 6] {
                let input = randomInputs(length: length, rng: &resumed)
                _ = randomInputs(length: length, rng: &fresh)
                let lhs = apply(snapshot, input)
                let rhs = apply(oracle, input)
                XCTAssertTrue(equal(lhs.latent, rhs.latent), "extended latent \(length)")
                XCTAssertEqual(lhs.pooled.map(\.shape), rhs.pooled.map(\.shape))
                if let l = lhs.pooled, let r = rhs.pooled { XCTAssertTrue(equal(l, r), "extended pooled \(length)") }
            }
            assertStatesEqual(snapshot.state, oracle.state, "extended snapshot")
        }
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

    /// The reference is the fork's own packed path over stock caches:
    /// `GLM5NextLatentCacheBatch` working copies written with each row's valid
    /// columns only, then `GLM5NextLatentRowTransaction.stageCommit(retaining:)`.
    /// The paged batch must leave every row byte-equal to it (latent, pooled
    /// keys, pending window, folded raw tail) with the same `maxTrimCount`,
    /// across many rounds so the folded tail fills past its cap, with equal
    /// and with right-padded widths.
    func testPackedVerificationMatchesTheForkRowTransactions() throws {
        try requireMetal()
        var rng = SplitMix(seed: 21)
        let rows = [makeCache(), makeCache(), makeCache()]
        let references = [stock(), stock(), stock()]
        step(rows[0], references[0], length: 13, rng: &rng)
        step(rows[1], references[1], length: 6, rng: &rng)
        step(rows[2], references[2], length: 22, rng: &rng)

        // (valid input columns per row, retained columns per row) per round.
        let rounds: [([Int], [Int])] = [
            ([3, 3, 3], [3, 1, 2]), ([3, 3, 3], [1, 2, 3]), ([3, 3, 3], [2, 3, 1]),
            ([2, 1, 3], [2, 1, 1]), ([1, 2, 2], [1, 1, 2]), ([2, 2, 1], [1, 2, 1]),
            ([3, 1, 2], [3, 1, 2]), ([2, 3, 3], [1, 3, 2]), ([3, 3, 3], [2, 2, 2]),
            ([1, 1, 1], [1, 1, 1]), ([2, 2, 2], [2, 1, 2]), ([3, 2, 1], [2, 2, 1]),
        ]
        // Odd rounds feed the columns one at a time, as the model's
        // per-column verification does; even rounds feed the padded width at once.
        for (round, (inputs, retained)) in rounds.enumerated() {
            let maps = rows.indices.map { index in
                MTPPackedVerificationRowMap(
                    rowIndex: index, queryOffset: rows[index].offset,
                    inputCount: inputs[index], proposalCount: inputs[index] - 1
                )
            }
            let width = inputs.max()!
            let batch = PagedMLABatchLayerCache(rowCaches: rows)
            try batch.prepareMTPPackedVerification(rowMaps: maps)
            let reference = GLM5NextLatentCacheBatch(rowCaches: references)
            try reference.prepareMTPPackedVerification(rowMaps: maps)
            XCTAssertEqual(batch.mtpPackedHostBatchOffsets, rows.map(\.offset))
            XCTAssertEqual(batch.packedVerificationRowLengths, inputs)
            for index in rows.indices {
                let columns = randomInputs(length: width, rng: &rng)
                // The pinned model runs every padded column on the paged copy,
                // which takes only the valid ones; the fork's batch is given
                // only the valid ones.
                if round % 2 == 1 {
                    for c in 0 ..< width {
                        apply(batch.rowCaches[index], (
                            columns.0[.ellipsis, c ..< (c + 1), 0...],
                            columns.1[0..., c ..< (c + 1), 0...],
                            columns.2[0..., c ..< (c + 1), 0...]
                        ))
                    }
                } else {
                    apply(batch.rowCaches[index], columns)
                }
                let valid = inputs[index]
                apply(reference.rowCaches[index], (
                    columns.0[.ellipsis, ..<valid, 0...],
                    columns.1[0..., ..<valid, 0...],
                    columns.2[0..., ..<valid, 0...]
                ))
            }
            XCTAssertEqual(rows.map(\.offset), references.map(\.offset), "verification mutated a live row")
            // The strict facade's post-forward check: query offset + valid width.
            XCTAssertEqual(
                batch.mtpPackedHostBatchOffsets, zip(rows, inputs).map { $0.offset + $1 },
                "round \(round) post-forward offsets"
            )
            batch.finalize()
            reference.finalize()
            let resolutions = try batch.pendingMTPResolutions()
            let transactions = try reference.rowTransactions()
            for index in rows.indices {
                _ = try resolutions[index].stageCommit(inputCount: retained[index])
                _ = try transactions[index].stageCommit(retaining: retained[index])
                let label = "round \(round) row \(index) inputs \(inputs[index]) retained \(retained[index])"
                XCTAssertEqual(rows[index].offset, references[index].offset, label)
                XCTAssertEqual(rows[index].maxTrimCount, references[index].maxTrimCount, label)
                assertStatesEqual(rows[index].state, references[index].state, label)
            }
        }
    }

    /// Window A2: a right-padded packed verify (widths 2, 1, 2, 2) failed the
    /// strict facade with postForwardCacheOffsetMismatch on the shared-KV
    /// source layer (expected 283, actual 284) because the padding column was
    /// written into the short row's staged copy. Each staged copy now takes
    /// only its valid columns; checked on the CPU device. MLX still loads the
    /// default metallib to create a stream, so hosts without one skip.
    func testPaddedVerifyColumnsWriteNothingIntoTheStagedCopy() throws {
        try requireMetal()
        try Device.withDefaultDevice(.cpu) {
            var rng = SplitMix(seed: 9)
            let rows = [makeCache(), makeCache(), makeCache(), makeCache()]
            for (row, length) in zip(rows, [13, 6, 22, 9]) {
                apply(row, randomInputs(length: length, rng: &rng))
            }
            let inputs = [2, 1, 2, 2]
            let maps = rows.indices.map {
                MTPPackedVerificationRowMap(
                    rowIndex: $0, queryOffset: rows[$0].offset,
                    inputCount: inputs[$0], proposalCount: inputs[$0] - 1
                )
            }
            let batch = PagedMLABatchLayerCache(rowCaches: rows)
            try batch.prepareMTPPackedVerification(rowMaps: maps)
            for index in rows.indices {
                for _ in 0 ..< 2 { apply(batch.rowCaches[index], randomInputs(length: 1, rng: &rng)) }
            }
            XCTAssertEqual(batch.mtpPackedHostBatchOffsets, zip(rows, inputs).map { $0.offset + $1 })
            batch.finalize()
            let resolutions = try batch.pendingMTPResolutions()
            XCTAssertEqual(resolutions.map(\.appendedTokenCount), inputs)
            let before = rows[1].offset
            _ = try resolutions[1].stageCommit(inputCount: 1)
            XCTAssertEqual(rows[1].offset, before + 1)
        }
    }

    /// Window 13:22Z step 05 (SPEC-048 MTP-6, 0.1.45): native rounds of depth
    /// 1...3 with every retained count, against one-token decode of the same
    /// tokens. At every committed length the state a forward reads (latent,
    /// pooled keys, partial window) is bit-equal; the folded raw-key tail
    /// (rewind headroom) is a shorter suffix after some rejections, so the
    /// whole `state` differs there, while `observerOracleState` never does.
    func testNativeRoundsMatchOneTokenDecodeInTheObserverOracleState() throws {
        try requireMetal()
        try Device.withDefaultDevice(.cpu) {
            var rng = SplitMix(seed: 31)
            let total = 240
            let stream = randomInputs(length: total + 8, rng: &rng)
            func column(_ t: Int) -> (MLXArray, MLXArray, MLXArray) {
                (stream.0[.ellipsis, t ..< (t + 1), 0...], stream.1[0..., t ..< (t + 1), 0...], stream.2[0..., t ..< (t + 1), 0...])
            }
            let prompt = 9
            let ordinary = makeCache()
            let native = makeCache()
            let promptInputs = (stream.0[.ellipsis, ..<prompt, 0...], stream.1[0..., ..<prompt, 0...], stream.2[0..., ..<prompt, 0...])
            apply(ordinary, promptInputs)
            apply(native, promptInputs)
            var ordinaryStates: [Int: (state: [MLXArray], oracle: [MLXArray])] = [:]
            for t in prompt ..< total {
                apply(ordinary, column(t))
                let snapshot = (state: ordinary.state, oracle: ordinary.observerOracleState)
                eval(snapshot.state + snapshot.oracle)
                ordinaryStates[ordinary.offset] = snapshot
            }
            var compared = 0
            var foldedTailDiffered = false
            while native.offset < total - 4 {
                let depth = Int(rng.next() % 3) + 1
                let retained = Int(rng.next() % UInt64(depth + 1)) + 1
                let start = native.offset
                let batch = PagedMLABatchLayerCache(rowCaches: [native])
                try batch.prepareMTPPackedVerification(rowMaps: [
                    MTPPackedVerificationRowMap(rowIndex: 0, queryOffset: start, inputCount: depth + 1, proposalCount: depth),
                ])
                // Accepted columns carry the decoded tokens; rejected ones differ.
                let junk = randomInputs(length: depth + 1, rng: &rng)
                for c in 0 ... depth {
                    apply(batch.rowCaches[0], c < retained
                        ? column(start + c)
                        : (junk.0[.ellipsis, c ..< (c + 1), 0...], junk.1[0..., c ..< (c + 1), 0...], junk.2[0..., c ..< (c + 1), 0...]))
                }
                batch.finalize()
                _ = try batch.pendingMTPResolutions()[0].stageCommit(inputCount: retained)
                let label = "offset \(native.offset) depth \(depth) retained \(retained)"
                let reference = try XCTUnwrap(ordinaryStates[native.offset], label)
                let state = native.state
                for index in 0 ..< 4 {
                    XCTAssertTrue(equal(state[index], reference.state[index]), "forward-read state[\(index)] \(label)")
                }
                if !(equal(state[4], reference.state[4]) && equal(state[5], reference.state[5])) {
                    foldedTailDiffered = true
                }
                assertStatesEqual(native.observerOracleState, reference.oracle, "oracle state \(label)")
                compared += 1
            }
            XCTAssertGreaterThan(compared, 60)
            XCTAssertTrue(foldedTailDiffered, "the folded rewind headroom never differed; the oracle view would be untested")
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
        XCTAssertEqual(paged.maxTrimCount, oracle.maxTrimCount, "maxTrimCount \(label)")
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
