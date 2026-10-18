import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

/// SPEC-039 v0.1.17 `pagedMLA(kpool:)` row cache for one GLM-5-Next
/// DeepSeek-sparse-attention layer of one sequence.
///
/// It holds the MLA latent `[1, 1, T, kv_lora_rank]` and the indexer's pooled
/// keys `[1, P, index_head_dim]` (one pooled key per `kpool` tokens) on the
/// sequence's one block table: latent capacity grows in whole
/// `blockSizeTokens` blocks and pooled-key capacity in whole
/// `blockSizeTokens / kpool` blocks, so logical block `j` of both buffers
/// covers tokens `[j·b, (j+1)·b)` (FR-PKV4 rule 1). The incomplete pool
/// window (pending indexer keys and gate scores) and the raw keys of the last
/// `kpool - 1 + maxTrim` folded tokens stay row-local, so `trim` of up to
/// `maxTrim` tokens rebuilds the pool state exactly (FR-PKV15).
///
/// Like `PagedKVCache`, production keeps each buffer contiguous per row; the
/// parity scaffold (`reconstructViaGather`) presents both buffers through the
/// `macprovider_paged_kv_gather_v1` kernel over a reversed physical block
/// order, so the attach probe proves the kernel reconstructs both exactly.
/// The model's own MLA sparse attention and indexer read what this cache
/// presents; no attention math runs here (FR-PKV3).
final class PagedMLALatentCache: GLM5NextLatentCache, CustomDebugStringConvertible {
    let kpool: Int
    let maxTrim: Int
    let blockSizeTokens: Int
    let maxPhysicalBlocks: Int
    let poolEpoch: Int
    let binding: PagedKVStorageBinding
    let reconstructViaGather: Bool

    var offset: Int
    private var latentBuffer: MLXArray?
    private var pooledBuffer: MLXArray?
    private(set) var pooledCount = 0
    private var pendingKeys: MLXArray?
    private var pendingGates: MLXArray?
    private var foldedKeys: MLXArray?
    private var foldedGates: MLXArray?
    private var registeredKernel: MLXFast.MLXFastKernel?

    init(
        kpool: Int,
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        poolEpoch: Int,
        binding: PagedKVStorageBinding,
        initialOffset: Int = 0,
        reconstructViaGather: Bool = false,
        maxTrim: Int = 16
    ) {
        self.kpool = max(1, kpool)
        self.maxTrim = max(0, maxTrim)
        self.blockSizeTokens = blockSizeTokens
        self.maxPhysicalBlocks = maxPhysicalBlocks
        self.poolEpoch = poolEpoch
        self.binding = binding
        self.offset = initialOffset
        self.reconstructViaGather = reconstructViaGather
    }

    /// SPEC-039 FR-PKV4 rule 1: one block table serves both buffers only when
    /// a block holds whole pool windows.
    static func blockSizeIsValid(_ blockSizeTokens: Int, kpool: Int) -> Bool {
        kpool >= 1 && blockSizeTokens >= kpool && blockSizeTokens % kpool == 0
    }

    private var pooledBlockSize: Int { max(1, blockSizeTokens / kpool) }

    private var maxResidentTokens: Int {
        let (value, overflow) = blockSizeTokens.multipliedReportingOverflow(by: maxPhysicalBlocks)
        return overflow ? Int.max : value
    }

    var maxSize: Int? { maxResidentTokens }

    /// Allocated latent capacity in tokens (whole blocks).
    var latentCapacityTokens: Int { latentBuffer?.dim(2) ?? 0 }
    /// Allocated pooled-key capacity in pooled keys (whole pooled blocks).
    var pooledCapacity: Int { pooledBuffer?.dim(1) ?? 0 }

    // MARK: - GLM5NextLatentCache

    var pooledKeys: MLXArray? {
        guard pooledCount > 0, let pooledBuffer else { return nil }
        let logical = pooledBuffer[0..., ..<pooledCount, 0...]
        guard reconstructViaGather else { return logical }
        // [1, P, D] -> [1, 1, P, D] for the gather, back after.
        // Same physical order as the latent: the table's block count over
        // `offset` tokens (FR-PKV4 rule 1).
        let gathered = PagedKVCache.reversedBlockGather(
            expandedDimensions(logical, axis: 1),
            blockSizeTokens: pooledBlockSize,
            logicalBlockCount: PagedKVBlockLayout.blockCount(tokens: offset, blockSizeTokens: blockSizeTokens),
            kernel: &registeredKernel
        )
        return gathered.squeezed(axis: 1)
    }

    /// The cached latent `[1, 1, offset, R]` in logical order, nil while
    /// empty. Read by the native-MTP head, not by the target forward, so it
    /// is never routed through the parity gather.
    var validLatent: MLXArray? {
        guard offset > 0, let latentBuffer else { return nil }
        return latentBuffer[.ellipsis, ..<offset, 0...]
    }

    func appendLatent(_ values: MLXArray) -> MLXArray {
        var values = values
        if let budget = stagedValidTokenBudget.latent {
            let accept = min(values.dim(2), max(0, budget))
            stagedValidTokenBudget.latent = budget - accept
            if accept == 0, let latentBuffer, offset > 0 {
                // A right-padding column: write nothing, attend the row's keys.
                let logical = latentBuffer[.ellipsis, ..<offset, 0...]
                guard reconstructViaGather else { return logical }
                return PagedKVCache.reversedBlockGather(logical, blockSizeTokens: blockSizeTokens, kernel: &registeredKernel)
            }
            if accept > 0, accept < values.dim(2) { values = values[.ellipsis, ..<accept, 0...] }
        }
        let length = values.dim(2)
        let previous = offset
        let needed = previous + length
        let capacity = latentBuffer?.dim(2) ?? 0
        if latentBuffer == nil || needed > capacity {
            let grownCapacity = PagedKVBlockLayout.grownCapacity(
                needed: needed,
                maxTokens: maxResidentTokens,
                blockSizeTokens: blockSizeTokens
            )
            let grown = MLXArray.zeros(
                [values.dim(0), values.dim(1), grownCapacity - previous, values.dim(3)],
                dtype: values.dtype
            )
            if let latentBuffer, previous > 0 {
                self.latentBuffer = concatenated([latentBuffer[.ellipsis, ..<previous, 0...], grown], axis: 2)
            } else {
                self.latentBuffer = grown
            }
        }
        offset = needed
        latentBuffer![.ellipsis, previous ..< needed, 0...] = values
        let logical = latentBuffer![.ellipsis, ..<needed, 0...]
        guard reconstructViaGather else { return logical }
        return PagedKVCache.reversedBlockGather(logical, blockSizeTokens: blockSizeTokens, kernel: &registeredKernel)
    }

    func takeCompleteWindows(keys: MLXArray, gates: MLXArray) -> (MLXArray, MLXArray)? {
        var keys = keys
        var gates = gates
        if let budget = stagedValidTokenBudget.indexer {
            let accept = min(keys.dim(1), max(0, budget))
            stagedValidTokenBudget.indexer = budget - accept
            // Right-padding indexer keys: no pending, folded or pooled write.
            if accept == 0 { return nil }
            if accept < keys.dim(1) {
                keys = keys[0..., ..<accept]
                gates = gates[0..., ..<accept]
            }
        }
        let allKeys = pendingKeys.map { concatenated([$0, keys], axis: 1) } ?? keys
        let allGates = pendingGates.map { concatenated([$0, gates], axis: 1) } ?? gates
        let total = allKeys.dim(1)
        let usable = (total / kpool) * kpool
        if usable < total {
            pendingKeys = contiguous(allKeys[0..., usable...])
            pendingGates = contiguous(allGates[0..., usable...])
        } else {
            pendingKeys = nil
            pendingGates = nil
        }
        guard usable > 0 else { return nil }
        let readyKeys = allKeys[0..., ..<usable]
        let readyGates = allGates[0..., ..<usable]
        foldedKeys = keepTail(foldedKeys, readyKeys)
        foldedGates = keepTail(foldedGates, readyGates)
        return (readyKeys, readyGates)
    }

    func appendPooled(_ pooled: MLXArray) {
        let added = pooled.dim(1)
        guard added > 0 else { return }
        let needed = pooledCount + added
        let capacity = pooledBuffer?.dim(1) ?? 0
        if pooledBuffer == nil || needed > capacity {
            let grownCapacity = PagedKVBlockLayout.grownCapacity(
                needed: needed,
                maxTokens: max(1, maxResidentTokens / kpool),
                blockSizeTokens: pooledBlockSize
            )
            let grown = MLXArray.zeros([pooled.dim(0), grownCapacity - pooledCount, pooled.dim(2)], dtype: pooled.dtype)
            if let pooledBuffer, pooledCount > 0 {
                self.pooledBuffer = concatenated([pooledBuffer[0..., ..<pooledCount, 0...], grown], axis: 1)
            } else {
                self.pooledBuffer = grown
            }
        }
        pooledBuffer![0..., pooledCount ..< needed, 0...] = pooled
        pooledCount = needed
    }

    /// A staged packed-verification copy (`PagedMLABatchLayerCache`) takes
    /// only its row's valid columns: latent tokens and indexer keys it may
    /// still accept (nil: unlimited). The pinned model reads per-row lengths
    /// only from the fork's `GLM5NextLatentCacheBatch`, so it still runs a
    /// shorter row's right-padding columns; this copy writes nothing for
    /// them, as that batch does, so its offset after the forward is the
    /// row's query offset plus its valid width (the strict facade's
    /// post-forward check on the shared-KV source layer) and its pending,
    /// folded and pooled keys equal the fork's working copy.
    var stagedValidTokenBudget: (latent: Int?, indexer: Int?) = (nil, nil)

    private var foldedCapacity: Int { kpool - 1 + maxTrim }

    private func keepTail(_ kept: MLXArray?, _ added: MLXArray) -> MLXArray? {
        guard foldedCapacity > 0 else { return nil }
        let all = kept.map { concatenated([$0, added], axis: 1) } ?? added
        return all.dim(1) > foldedCapacity
            ? contiguous(all[0..., (all.dim(1) - foldedCapacity)...]) : all
    }

    // MARK: - Trim (exact, as GLM5NextAttentionCache)

    private var rawCount: Int { (foldedKeys?.dim(1) ?? 0) + (pendingKeys?.dim(1) ?? 0) }
    private var indexed: Bool { pooledCount > 0 || rawCount > 0 }

    private func exactTrimCount(_ n: Int) -> Int {
        var m = min(max(n, 0), offset)
        guard indexed else { return m }
        while m > 0 {
            let partial = (offset - m) % kpool
            if partial == 0 || rawCount - m >= partial { break }
            m -= 1
        }
        return m
    }

    var isTrimmable: Bool { true }

    /// The largest `M` such that every trim of up to `M` tokens is exact, as
    /// `GLM5NextAttentionCache` reports it (upstream #622 per-layer gate).
    var maxTrimCount: Int {
        guard indexed else { return offset }
        var m = 0
        while m < offset {
            let partial = (offset - m - 1) % kpool
            guard partial == 0 || rawCount - (m + 1) >= partial else { break }
            m += 1
        }
        return m
    }

    func isTrimmable(after positions: Int) -> Bool {
        !indexed || positions <= maxTrim
    }

    @discardableResult
    func trim(_ n: Int) -> Int {
        let m = exactTrimCount(n)
        guard m > 0 else { return 0 }
        let newOffset = offset - m
        if indexed, rawCount > 0 {
            let parts = [foldedKeys, pendingKeys].compactMap { $0 }
            let gateParts = [foldedGates, pendingGates].compactMap { $0 }
            let raw = parts.count == 1 ? parts[0] : concatenated(parts, axis: 1)
            let rawGates = gateParts.count == 1 ? gateParts[0] : concatenated(gateParts, axis: 1)
            let kept = max(raw.dim(1) - m, 0)
            let pending = newOffset % kpool
            let folded = kept - pending
            pendingKeys = pending > 0 ? contiguous(raw[0..., folded ..< kept]) : nil
            pendingGates = pending > 0 ? contiguous(rawGates[0..., folded ..< kept]) : nil
            foldedKeys = folded > 0 ? contiguous(raw[0..., ..<folded]) : nil
            foldedGates = folded > 0 ? contiguous(rawGates[0..., ..<folded]) : nil
        }
        if pooledCount > 0 {
            pooledCount = min(pooledCount, newOffset / kpool)
        }
        offset = newOffset
        // Keep capacity within the blocks the allocator still accounts for
        // (SPEC-039 FR-PKV2), as `PagedKVCache.trim` does.
        let keepTokens = PagedKVBlockLayout.alignedCapacity(tokens: offset, blockSizeTokens: blockSizeTokens)
        if let latentBuffer, latentBuffer.dim(2) > keepTokens {
            self.latentBuffer = keepTokens > 0 ? contiguous(latentBuffer[.ellipsis, ..<keepTokens, 0...]) : nil
        }
        let keepPools = PagedKVBlockLayout.alignedCapacity(tokens: pooledCount, blockSizeTokens: pooledBlockSize)
        if let pooledBuffer, pooledBuffer.dim(1) > keepPools {
            self.pooledBuffer = keepPools > 0 ? contiguous(pooledBuffer[0..., ..<keepPools, 0...]) : nil
        }
        return m
    }

    // MARK: - KVCache

    func innerState() -> [MLXArray] {
        [latentBuffer, pooledBuffer, pendingKeys, pendingGates, foldedKeys, foldedGates].compactMap { $0 }
    }

    /// GLM-5-Next sparse layers never call the K/V update; they append the
    /// latent through `appendLatent`. Inputs pass through unchanged.
    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        (keys, values)
    }

    /// `[latent, pooledKeys, pendingKeys, pendingGates, foldedKeys, foldedGates]`
    /// in logical order, the `GLM5NextAttentionCache` state layout; absent
    /// parts are empty arrays.
    var state: [MLXArray] {
        get {
            let empty = MLXArray.zeros([0])
            return [
                offset > 0 ? latentBuffer.map { $0[.ellipsis, ..<offset, 0...] } ?? empty : empty,
                pooledCount > 0 ? pooledBuffer.map { $0[0..., ..<pooledCount, 0...] } ?? empty : empty,
                pendingKeys ?? empty, pendingGates ?? empty,
                foldedKeys ?? empty, foldedGates ?? empty,
            ]
        }
        set {
            guard newValue.count == 4 || newValue.count == 6 else { return }
            func present(_ array: MLXArray) -> MLXArray? { array.size == 0 ? nil : array }
            let latent = present(newValue[0])
            let pooled = present(newValue[1])
            latentBuffer = latent.map { $0[.ellipsis] }
            offset = latent?.dim(2) ?? 0
            pooledBuffer = pooled.map { $0[.ellipsis] }
            pooledCount = pooled?.dim(1) ?? 0
            pendingKeys = present(newValue[2])
            pendingGates = present(newValue[3])
            foldedKeys = newValue.count == 6 ? present(newValue[4]) : nil
            foldedGates = newValue.count == 6 ? present(newValue[5]) : nil
        }
    }

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    /// The lab state observer's target-oracle view (SPEC-048 MTP-6, 0.1.45):
    /// everything a later forward reads (latent to `offset`, pooled keys, the
    /// partial pool window's keys and gates) plus the last `maxTrim - kpool`
    /// folded raw keys and gates. The folded tail is rewind headroom that no
    /// forward reads. A native round's exact `trim` of rejected proposals
    /// keeps a shorter suffix of the same raw keys than one-token decode
    /// keeps (after a reject that undoes a pool window, 15 of 19 at kpool 4),
    /// as the fork's `GLM5NextLatentRowTransaction` does, and the next
    /// completed window refills it. Every committed round rejecting at most
    /// `kpool` proposals keeps at least `maxTrim - kpool` of them.
    var observerOracleState: [MLXArray] {
        let state = self.state
        let headroom = max(0, maxTrim - kpool)
        func tail(_ array: MLXArray) -> MLXArray {
            guard array.ndim >= 2, array.dim(1) > headroom else { return array }
            return array[0..., (array.dim(1) - headroom)...]
        }
        return [state[0], state[1], state[2], state[3], tail(state[4]), tail(state[5])]
    }
    #endif

    var metaState: [String] {
        get {
            [
                "macprovider_paged_mla_v1",
                "kpool=\(kpool)",
                "handle=\(binding.handle.handleID.uuidString)",
                "block_size_tokens=\(blockSizeTokens)",
                "pool_epoch=\(poolEpoch)",
            ]
        }
        set {}
    }

    func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
        if n == 1 { return .none }
        if returnArray { return .array(createCausalMask(n: n, offset: offset, windowSize: windowSize)) }
        return .causal
    }

    func copy() -> any KVCache {
        concreteCopy()
    }

    func concreteCopy() -> PagedMLALatentCache {
        let copied = PagedMLALatentCache(
            kpool: kpool,
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: poolEpoch,
            binding: binding,
            initialOffset: offset,
            reconstructViaGather: reconstructViaGather,
            maxTrim: maxTrim
        )
        copied.adopt(self)
        return copied
    }

    /// Take `other`'s logical contents (new array objects, so a later
    /// in-place write on one never reaches the other).
    func adopt(_ other: PagedMLALatentCache) {
        offset = other.offset
        latentBuffer = other.latentBuffer?[.ellipsis]
        pooledBuffer = other.pooledBuffer?[.ellipsis]
        pooledCount = other.pooledCount
        pendingKeys = other.pendingKeys?[.ellipsis]
        pendingGates = other.pendingGates?[.ellipsis]
        foldedKeys = other.foldedKeys?[.ellipsis]
        foldedGates = other.foldedGates?[.ellipsis]
    }

    var debugDescription: String {
        "PagedMLALatentCache(offset=\(offset), kpool=\(kpool), pooled=\(pooledCount), blockSizeTokens=\(blockSizeTokens))"
    }
}

/// One `pagedMLA` layer of a continuous batch: the model projects every row
/// together and each row attends against its own `PagedMLALatentCache`
/// (`GLM5NextBatchedLatentCache`), exactly as a serial decode of that row.
///
/// For a packed native-MTP verification (`MTPPackedVerificationCache`) it is
/// the paged equivalent of the fork's `GLM5NextLatentCacheBatch` (whose rows
/// must be `GLM5NextAttentionCache`): the forward writes only staged copies of
/// the rows, and each row's resolution keeps exactly its first `retaining`
/// columns (the base column plus the accepted proposals) by exact `trim` of
/// the staged copy and adopts it into the row, as
/// `GLM5NextLatentRowTransaction.stageCommit(retaining:)` does (SPEC-039
/// FR-PKV15). An aborted round leaves the row untouched. The pinned model
/// reads per-row lengths only from `GLM5NextLatentCacheBatch`, so it also
/// runs a shorter row's right-padding columns; each staged copy accepts only
/// its row's valid columns (`stagedValidTokenBudget`) and writes nothing for
/// the padding, as the fork's batch does.
final class PagedMLABatchLayerCache: GLM5NextBatchedLatentCache, MTPPackedVerificationCache, @unchecked Sendable {
    struct PendingMTPResolution {
        let rowCache: PagedMLALatentCache
        let staged: PagedMLALatentCache
        let inputTokenCount: Int
        let proposalTokenCount: Int
        let appendedTokenCount: Int

        func stageCommit(inputCount: Int) throws -> [MLXArray] {
            guard inputCount >= 0, inputCount <= inputTokenCount else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_finalize_input_count_mismatch")
            }
            guard inputCount > 0 else { return [] }
            let committed = staged.concreteCopy()
            let drop = appendedTokenCount - inputCount
            guard committed.trim(drop) == drop else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_paged_mla_trim_shortfall")
            }
            rowCache.adopt(committed)
            return rowCache.innerState()
        }
    }

    let rows: [PagedMLALatentCache]
    private var stagedRows: [PagedMLALatentCache]?
    private var preparedMTPPackedRowMaps: [MTPPackedVerificationRowMap]?
    private var pendingMTPResolutionsByRow: [PendingMTPResolution]?

    init(rowCaches: [PagedMLALatentCache]) {
        self.rows = rowCaches
    }

    var rowCaches: [any GLM5NextLatentCache] {
        stagedRows ?? rows
    }

    var offset: Int { rows.map(\.offset).min() ?? 0 }
    var maxSize: Int? { rows.compactMap(\.maxSize).min() }

    var batchOffset: MLXArray {
        MLXArray(hostOffsets.map(Int32.init))
    }

    var mtpPackedHostBatchOffsets: [Int]? { hostOffsets }

    /// Each row's valid verification width (`[lastCommitted, proposals...]`,
    /// excluding right padding) while a packed verification is prepared;
    /// nil otherwise (diagnostics; see the type comment on padding).
    var packedVerificationRowLengths: [Int]? {
        // Row maps are positional: map `i` belongs to `rows[i]`.
        preparedMTPPackedRowMaps?.map(\.inputCount)
    }

    private var hostOffsets: [Int] {
        (stagedRows ?? rows).map(\.offset)
    }

    func innerState() -> [MLXArray] {
        (stagedRows ?? rows).flatMap { $0.innerState() }
    }

    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        (keys, values)
    }

    var state: [MLXArray] {
        get { [] }
        set {}
    }

    var metaState: [String] {
        get { ["macprovider_paged_mla_batch_v1"] }
        set {}
    }

    var isTrimmable: Bool { false }

    @discardableResult
    func trim(_ n: Int) -> Int { 0 }

    func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
        n == 1 ? .none : .causal
    }

    func copy() -> any KVCache {
        PagedMLABatchLayerCache(rowCaches: rows.map { $0.concreteCopy() })
    }

    func prepareMTPPackedVerification(rowMaps: [MTPPackedVerificationRowMap]) throws {
        guard rowMaps.count == rows.count else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_row_count_mismatch")
        }
        var seen = Set<Int>()
        for map in rowMaps {
            guard map.rowIndex >= 0,
                  seen.insert(map.rowIndex).inserted,
                  map.queryOffset >= 0,
                  map.inputCount > 0,
                  map.proposalCount >= 0,
                  map.inputCount == map.proposalCount + 1
            else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_invalid_row_map")
            }
        }
        guard zip(rows, rowMaps).allSatisfy({ $0.offset == $1.queryOffset }) else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_offset_mismatch")
        }
        // A staged copy takes its row's valid columns; the commit's trim of
        // the rejected proposals (up to width - 1) must stay exact.
        let width = rowMaps.map(\.inputCount).max() ?? 0
        guard rows.allSatisfy({ $0.maxTrim >= width - 1 }) else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_width_exceeds_exact_trim")
        }
        preparedMTPPackedRowMaps = rowMaps
        stagedRows = zip(rows, rowMaps).map { row, map in
            let staged = row.concreteCopy()
            staged.stagedValidTokenBudget = (map.inputCount, map.inputCount)
            return staged
        }
        pendingMTPResolutionsByRow = nil
    }

    /// Clears only the packed-call metadata; the staged rows become the
    /// pending resolutions, never committed here.
    func finalize() {
        guard let rowMaps = preparedMTPPackedRowMaps, let staged = stagedRows else { return }
        pendingMTPResolutionsByRow = zip(zip(rows, staged), rowMaps).map { pair, map in
            PendingMTPResolution(
                rowCache: pair.0,
                staged: pair.1,
                inputTokenCount: map.inputCount,
                proposalTokenCount: map.proposalCount,
                appendedTokenCount: pair.1.offset - pair.0.offset
            )
        }
        preparedMTPPackedRowMaps = nil
        stagedRows = nil
    }

    func pendingMTPResolutions() throws -> [PendingMTPResolution] {
        guard let pendingMTPResolutionsByRow,
              pendingMTPResolutionsByRow.count == rows.count,
              pendingMTPResolutionsByRow.allSatisfy({
                  $0.appendedTokenCount >= $0.inputTokenCount
                      && $0.appendedTokenCount - $0.inputTokenCount <= $0.rowCache.maxTrim + 1
              })
        else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_missing_staged_state")
        }
        return pendingMTPResolutionsByRow
    }
}
