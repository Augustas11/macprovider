import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

/// SPEC-039 `pagedQwen4ExpKV` row cache for one Qwen4-Exp (Qwen3.8-Flash-Next)
/// full-attention layer of one sequence.
///
/// It holds the attention keys and values `[1, kvHeads, T, headDim]` and the
/// QSA indexer's raw single-head keys of the same tokens, stored
/// `[1, 1, T, indexerHeadDim]`, on the sequence's one block table: all three
/// buffers grow in whole `blockSizeTokens` blocks, so logical block `j` of
/// each covers tokens `[j·b, (j+1)·b)` (FR-PKV4 rule 1). Trim drops whole
/// tokens from all three buffers together.
///
/// The model writes the attention keys first (`update`), then the indexer
/// keys of the same tokens (`updateIndexer`), and reads `indexerOffset`
/// between the two, so the indexer keeps its own token count, as the
/// serial `Qwen4ExpAttentionCache` does.
///
/// As for `PagedMiniMaxM3SparseCache`, production keeps each buffer
/// contiguous per row; the parity scaffold (`reconstructViaGather`) presents
/// all three through the `macprovider_paged_kv_gather_v1` kernel over a
/// reversed physical block order. The model's own QSA block selection and
/// attention read what this cache presents; no attention math runs here
/// (FR-PKV3).
final class PagedQwen4ExpSparseCache: Qwen4ExpSparseCache, CustomDebugStringConvertible {
    let blockSizeTokens: Int
    let maxPhysicalBlocks: Int
    let poolEpoch: Int
    let binding: PagedKVStorageBinding
    let reconstructViaGather: Bool

    var offset: Int
    private(set) var indexerOffset: Int
    private var keyBuffer: MLXArray?
    private var valueBuffer: MLXArray?
    private var indexBuffer: MLXArray?
    private var registeredKernel: MLXFast.MLXFastKernel?

    init(
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        poolEpoch: Int,
        binding: PagedKVStorageBinding,
        initialOffset: Int = 0,
        reconstructViaGather: Bool = false
    ) {
        self.blockSizeTokens = blockSizeTokens
        self.maxPhysicalBlocks = maxPhysicalBlocks
        self.poolEpoch = poolEpoch
        self.binding = binding
        self.offset = initialOffset
        self.indexerOffset = initialOffset
        self.reconstructViaGather = reconstructViaGather
    }

    private var maxResidentTokens: Int {
        let (value, overflow) = blockSizeTokens.multipliedReportingOverflow(by: maxPhysicalBlocks)
        return overflow ? Int.max : value
    }

    var maxSize: Int? { maxResidentTokens }

    /// Allocated capacity in tokens (whole blocks), shared by all three buffers.
    var capacityTokens: Int { keyBuffer?.dim(2) ?? 0 }

    /// `buffer` grown to hold `needed` tokens in whole growth steps
    /// (`amortizedGrownCapacity`, whole blocks), keeping its first `kept`
    /// tokens.
    private func reserve(_ buffer: MLXArray?, like new: MLXArray, kept: Int, needed: Int) -> MLXArray {
        if let buffer, needed <= buffer.dim(2) { return buffer }
        let capacity = PagedKVBlockLayout.amortizedGrownCapacity(
            needed: needed,
            maxTokens: maxResidentTokens,
            blockSizeTokens: blockSizeTokens
        )
        let grown = MLXArray.zeros([new.dim(0), new.dim(1), capacity - kept, new.dim(3)], dtype: new.dtype)
        guard let buffer, kept > 0 else { return grown }
        return concatenated([buffer[.ellipsis, ..<kept, 0...], grown], axis: 2)
    }

    private func present(_ buffer: MLXArray, tokens: Int) -> MLXArray {
        let logical = buffer[.ellipsis, ..<tokens, 0...]
        guard reconstructViaGather else { return logical }
        return PagedKVCache.reversedBlockGather(logical, blockSizeTokens: blockSizeTokens, kernel: &registeredKernel)
    }

    // MARK: - Qwen4ExpSparseCache

    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        let previous = offset
        let needed = previous + keys.dim(2)
        keyBuffer = reserve(keyBuffer, like: keys, kept: previous, needed: needed)
        valueBuffer = reserve(valueBuffer, like: values, kept: previous, needed: needed)
        offset = needed
        keyBuffer![.ellipsis, previous ..< needed, 0...] = keys
        valueBuffer![.ellipsis, previous ..< needed, 0...] = values
        return (present(keyBuffer!, tokens: needed), present(valueBuffer!, tokens: needed))
    }

    /// Appends the indexer keys `[1, L, D]` of the tokens the last `update`
    /// added and returns every cached one `[1, T, D]`.
    func updateIndexer(keys: MLXArray) -> MLXArray {
        let previous = indexerOffset
        let end = previous + keys.dim(1)
        precondition(end <= offset, "PagedQwen4ExpSparseCache: indexer keys past the attention keys")
        let stored = expandedDimensions(keys, axis: 1)
        indexBuffer = reserve(indexBuffer, like: stored, kept: previous, needed: end)
        indexerOffset = end
        indexBuffer![.ellipsis, previous ..< end, 0...] = stored
        return present(indexBuffer!, tokens: end).squeezed(axis: 1)
    }

    // MARK: - KVCache

    var isTrimmable: Bool { true }

    @discardableResult
    func trim(_ n: Int) -> Int {
        let trimmed = min(offset, max(n, 0))
        guard trimmed > 0 else { return 0 }
        offset -= trimmed
        indexerOffset = min(indexerOffset, offset)
        let keep = PagedKVBlockLayout.alignedCapacity(tokens: offset, blockSizeTokens: blockSizeTokens)
        func shrink(_ buffer: MLXArray?) -> MLXArray? {
            guard let buffer, buffer.dim(2) > keep else { return buffer }
            return keep > 0 ? contiguous(buffer[.ellipsis, ..<keep, 0...]) : nil
        }
        keyBuffer = shrink(keyBuffer)
        valueBuffer = shrink(valueBuffer)
        indexBuffer = shrink(indexBuffer)
        return trimmed
    }

    func innerState() -> [MLXArray] {
        [keyBuffer, valueBuffer, indexBuffer].compactMap { $0 }
    }

    /// `[keys, values, indexerKeys, indexerValues]` up to `offset`, the
    /// `Qwen4ExpAttentionCache` state layout (indexer values are one wide and
    /// zero: nothing reads them); empty while nothing is cached.
    var state: [MLXArray] {
        get {
            guard offset > 0, indexerOffset == offset,
                  let keyBuffer, let valueBuffer, let indexBuffer
            else { return [] }
            let indexKeys = indexBuffer[.ellipsis, ..<offset, 0...]
            return [
                keyBuffer[.ellipsis, ..<offset, 0...],
                valueBuffer[.ellipsis, ..<offset, 0...],
                indexKeys,
                MLXArray.zeros([indexKeys.dim(0), 1, offset, 1], dtype: indexKeys.dtype),
            ]
        }
        set {
            guard newValue.count == 4,
                  newValue.allSatisfy({ $0.ndim == 4 && $0.dim(2) == newValue[0].dim(2) })
            else {
                keyBuffer = nil
                valueBuffer = nil
                indexBuffer = nil
                offset = 0
                indexerOffset = 0
                return
            }
            keyBuffer = newValue[0][.ellipsis]
            valueBuffer = newValue[1][.ellipsis]
            indexBuffer = newValue[2][.ellipsis]
            offset = newValue[0].dim(2)
            indexerOffset = offset
        }
    }

    var metaState: [String] {
        get {
            [
                "macprovider_paged_qwen4_exp_v1",
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

    func concreteCopy() -> PagedQwen4ExpSparseCache {
        let copied = PagedQwen4ExpSparseCache(
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: poolEpoch,
            binding: binding,
            initialOffset: offset,
            reconstructViaGather: reconstructViaGather
        )
        copied.indexerOffset = indexerOffset
        copied.keyBuffer = keyBuffer?[.ellipsis]
        copied.valueBuffer = valueBuffer?[.ellipsis]
        copied.indexBuffer = indexBuffer?[.ellipsis]
        return copied
    }

    var debugDescription: String {
        "PagedQwen4ExpSparseCache(offset=\(offset), indexerOffset=\(indexerOffset), capacity=\(capacityTokens), blockSizeTokens=\(blockSizeTokens))"
    }
}

/// One `pagedQwen4ExpKV` layer of a continuous batch: the model projects
/// every row together, then each row runs its norms, RoPE, QSA block
/// selection and attention against its own `PagedQwen4ExpSparseCache`
/// (`Qwen4ExpBatchedSparseCache`), exactly as a serial forward of that row.
/// Rows keep their own state, so there is nothing to sync back. No
/// native-MTP verification runs on this family.
final class PagedQwen4ExpBatchLayerCache: Qwen4ExpBatchedSparseCache, @unchecked Sendable {
    let rows: [PagedQwen4ExpSparseCache]
    private(set) var rowLengths: [Int]?

    init(rowCaches: [PagedQwen4ExpSparseCache]) {
        self.rows = rowCaches
    }

    var rowCaches: [any Qwen4ExpSparseCache] { rows }

    var offset: Int { rows.map(\.offset).min() ?? 0 }
    var maxSize: Int? { rows.compactMap(\.maxSize).min() }

    func innerState() -> [MLXArray] {
        rows.flatMap { $0.innerState() }
    }

    /// Attention runs per row; a batched K/V update never runs here.
    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        (keys, values)
    }

    var state: [MLXArray] {
        get { [] }
        set {}
    }

    var metaState: [String] {
        get { ["macprovider_paged_qwen4_exp_batch_v1"] }
        set {}
    }

    var isTrimmable: Bool { false }

    @discardableResult
    func trim(_ n: Int) -> Int { 0 }

    func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
        n == 1 ? .none : .causal
    }

    func copy() -> any KVCache {
        PagedQwen4ExpBatchLayerCache(rowCaches: rows.map { $0.concreteCopy() })
    }

    /// Ragged packed forward: valid leading columns per row (nil when equal).
    func prepare(lengths: [Int]?) {
        rowLengths = lengths.flatMap { Set($0).count <= 1 ? nil : $0 }
    }

    func finalize() {
        rowLengths = nil
    }
}
