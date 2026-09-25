import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

struct PagedKVGatherKernel {
    static let registeredKernelName = "macprovider_paged_kv_gather_v1"
    static let source = """
        uint elem = thread_position_in_grid.x;
        uint logical_token = elem / token_stride;
        uint lane = elem - (logical_token * token_stride);
        uint logical_block = logical_token / block_size_tokens;
        uint within_block = logical_token - (logical_block * block_size_tokens);
        uint physical_block = uint(block_ids[logical_block]);
        uint physical_token = (physical_block * block_size_tokens) + within_block;
        gathered[elem] = physical[physical_token * token_stride + lane];
    """

    static func register() -> MLXFast.MLXFastKernel {
        MLXFast.metalKernel(
            name: Self.registeredKernelName,
            inputNames: ["physical", "block_ids"],
            outputNames: ["gathered"],
            source: Self.source,
            ensureRowContiguous: true
        )
    }

    static func registeredRuntimeKernelIdentifier(
        register: () -> MLXFast.MLXFastKernel = PagedKVGatherKernel.register
    ) -> String? {
        _ = register()
        return registeredKernelName
    }

    static func materialize(
        physical: MLXArray,
        blockIDs: MLXArray,
        logicalTokens: Int,
        blockSizeTokens: Int,
        tokenStride: Int,
        outputShape: [Int],
        using kernel: MLXFast.MLXFastKernel
    ) -> MLXArray {
        let count = max(logicalTokens * tokenStride, 1)
        return kernel(
            [physical, blockIDs],
            template: [
                ("block_size_tokens", blockSizeTokens),
                ("token_stride", tokenStride),
            ],
            grid: (count, 1, 1),
            threadGroup: (min(count, 256), 1, 1),
            outputShapes: [outputShape],
            outputDTypes: [physical.dtype]
        )[0]
    }
}

/// Pure block/capacity arithmetic for `PagedKVCache` storage, kept free of MLX
/// so it is testable on hosts without the Metal library.
enum PagedKVBlockLayout {
    static func blockCount(tokens: Int, blockSizeTokens: Int) -> Int {
        guard tokens > 0, blockSizeTokens > 0 else { return 0 }
        return (tokens - 1) / blockSizeTokens + 1
    }

    /// Half-open token ranges of each logical block over `tokens` stored tokens;
    /// every block is full except possibly the last.
    static func blockRanges(tokens: Int, blockSizeTokens: Int) -> [Range<Int>] {
        (0 ..< blockCount(tokens: tokens, blockSizeTokens: blockSizeTokens)).map { index in
            let start = index * blockSizeTokens
            return start ..< min(start + blockSizeTokens, tokens)
        }
    }

    /// Capacity after growing a buffer so it fits `needed` tokens: `needed`
    /// rounded up to whole allocator blocks, never above `maxTokens` unless
    /// `needed` itself is larger (callers reject that case first). Physical
    /// capacity therefore never exceeds the blocks SPEC-039 FR-PKV2 accounts
    /// for the stored tokens.
    static func grownCapacity(
        needed: Int,
        maxTokens: Int,
        blockSizeTokens: Int
    ) -> Int {
        let alignedTo = alignedCapacity(tokens: needed, blockSizeTokens: blockSizeTokens)
        return max(needed, min(alignedTo, maxTokens))
    }

    /// `tokens` rounded up to whole blocks of `blockSizeTokens`.
    static func alignedCapacity(tokens: Int, blockSizeTokens: Int) -> Int {
        guard tokens > 0 else { return 0 }
        guard blockSizeTokens > 1 else { return tokens }
        let blocks = blockCount(tokens: tokens, blockSizeTokens: blockSizeTokens)
        let (capacity, overflow) = blocks.multipliedReportingOverflow(by: blockSizeTokens)
        return overflow ? tokens : capacity
    }
}

/// Compile-time `KVCache` seam for the future installed paged runtime bridge.
///
/// Production `ModelRuntime` attempts measured observation and instantiates this
/// cache only after packaged metallib/kernel/parity/sizing evidence opens attach.
/// Missing evidence stays fail-closed. The class remains type-checked against
/// `mlx-swift-lm` so real gather execution and parity tests can evolve without
/// changing public buyer behavior.
final class PagedKVCache: KVCache, CustomDebugStringConvertible {
    let blockSizeTokens: Int
    let maxPhysicalBlocks: Int
    let poolEpoch: Int
    let binding: PagedKVStorageBinding

    private let gatherKernel: PagedKVGatherKernel
    /// When true, every `update()` reconstructs logical K/V through the Metal gather
    /// over reversed physical blocks. Required by parity fixtures. Production shared
    /// forward sets this false: gather is a lossless identity, and running it every
    /// decode step is the ~3× single-stream tax measured on 2026-09-20.
    let reconstructViaGather: Bool
    /// Lazily-registered Metal gather kernel. Created on first `update()` so mere
    /// construction of the seam (the SPEC-038-facing metadata surface) still runs no
    /// Metal — only driving the cache through a real forward pass executes the kernel.
    private var registeredKernel: MLXFast.MLXFastKernel?
    /// Contiguous `[B, H, capacity, D]` backing buffers. Only the first
    /// `storedTokens` positions are logical K/V; block views are derived from
    /// that prefix on demand (record/materialize, description). Appending per
    /// decode step writes in place instead of re-concatenating and re-splitting
    /// the whole history, which made batched decode O(context) per step.
    private var keyBuffer: MLXArray?
    private var valueBuffer: MLXArray?
    /// Logical tokens held in the buffers. Tracks what the old block list held,
    /// which can be less than `offset` when the cache starts at a nonzero
    /// `initialOffset` with no stored K/V.
    private(set) var storedTokens = 0
    /// Bumped on every mutation of stored K/V or `offset`. Lets a batch view
    /// detect that a row changed outside it (for example a bridge trim).
    private(set) var mutationCount = 0
    var offset: Int

    /// Number of times the paged Metal gather kernel actually executed. Proof, for the
    /// parity fixtures, that logical K/V was reconstructed through the real gather rather
    /// than an identity concat. Test-only diagnostics; the cache is single-threaded in
    /// every path that reads these (never injected into the concurrent serve path).
    nonisolated(unsafe) private(set) static var gatherKernelCalls = 0
    /// Largest logical block count seen by any gather (proves a non-degenerate, >= 2-block
    /// layout that crosses a block boundary was actually reconstructed).
    nonisolated(unsafe) private(set) static var maxLogicalBlocksObserved = 0
    /// True once at least one gather ran over a genuinely non-identity physical order.
    nonisolated(unsafe) private(set) static var observedNonIdentityPermutation = false

    static func resetGatherDiagnostics() {
        gatherKernelCalls = 0
        maxLogicalBlocksObserved = 0
        observedNonIdentityPermutation = false
    }

    init(
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        poolEpoch: Int,
        binding: PagedKVStorageBinding,
        gatherKernel: PagedKVGatherKernel = PagedKVGatherKernel(),
        initialOffset: Int? = nil,
        reconstructViaGather: Bool = true
    ) {
        self.blockSizeTokens = blockSizeTokens
        self.maxPhysicalBlocks = maxPhysicalBlocks
        self.poolEpoch = poolEpoch
        self.binding = binding
        self.gatherKernel = gatherKernel
        self.reconstructViaGather = reconstructViaGather
        self.offset = initialOffset ?? binding.currentTable.logicalTokenCount
    }

    /// Descriptor-sourced convenience initializer. Kept for existing production and test
    /// call sites that still build a full `PagedKVDescriptor`; forwards only the three
    /// primitive fields this cache actually reads.
    convenience init(
        descriptor: PagedKVDescriptor,
        binding: PagedKVStorageBinding,
        gatherKernel: PagedKVGatherKernel = PagedKVGatherKernel(),
        initialOffset: Int? = nil
    ) {
        self.init(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks,
            poolEpoch: descriptor.poolEpoch,
            binding: binding,
            gatherKernel: gatherKernel,
            initialOffset: initialOffset,
            reconstructViaGather: true
        )
    }

    var maxSize: Int? { maxResidentTokens }

    /// Allocated sequence capacity of the backing buffers (>= `storedTokens`).
    var bufferCapacityTokens: Int { keyBuffer?.dim(2) ?? 0 }

    func innerState() -> [MLXArray] {
        state
    }

    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        // Controlled handling for this inert seam: never abort the host process on
        // malformed/out-of-contract input. Guard the invariants and return safely instead
        // of `precondition`-crashing. The happy path (shape-consistent, within reserved
        // capacity) is unchanged. NOTE: KERNEL-SIDE (Metal) index/bounds validation is a
        // SEPARATE, still-REQUIRED before-runtime-enable gate item — these Swift-side guards
        // do not substitute for in-shader bounds checks (see pagedGather()).
        guard keys.ndim == 4, values.ndim == 4 else { return (keys, values) }
        let incomingTokens = keys.dim(2)
        guard incomingTokens == values.dim(2) else { return (keys, values) }
        let (projectedOffset, offsetOverflow) = offset.addingReportingOverflow(incomingTokens)
        guard !offsetOverflow, projectedOffset <= maxResidentTokens else { return (keys, values) }

        let start = storedTokens
        let end = start + incomingTokens
        let nextKeys = Self.write(keys, into: keyBuffer, stored: start, maxTokens: maxResidentTokens, blockSizeTokens: blockSizeTokens)
        let nextValues = Self.write(values, into: valueBuffer, stored: start, maxTokens: maxResidentTokens, blockSizeTokens: blockSizeTokens)
        keyBuffer = nextKeys
        valueBuffer = nextValues
        storedTokens = end
        offset += incomingTokens
        mutationCount &+= 1
        let mergedKeys = Self.prefix(nextKeys, end)
        let mergedValues = Self.prefix(nextValues, end)
        guard reconstructViaGather else {
            return (mergedKeys, mergedValues)
        }
        // Reconstruct the logical K/V through the REAL Metal gather over a non-identity
        // (reversed) physical block order. The gather is a lossless permutation round-trip,
        // so a correct paged reconstruction returns tensors identical to `mergedKeys/Values`
        // — the parity fixtures gate exactly that (token-for-token argmax equality).
        let gatheredKeys = pagedGather(mergedKeys)
        let gatheredValues = pagedGather(mergedValues)
        return (gatheredKeys, gatheredValues)
    }

    /// Split a contiguous logical `[1, H, S, D]` tensor into fixed-size blocks placed in
    /// REVERSED physical order, then gather them back to logical order with the registered
    /// `PagedKVGatherKernel` via a block table. Forces genuine physical non-contiguity so
    /// the gather is exercised, not bypassed. Returns a tensor identical to the input.
    private func pagedGather(_ logical: MLXArray) -> MLXArray {
        // Validate rank/dims and compute all shape/grid math with overflow-checked
        // arithmetic BEFORE launching the kernel. Any invalid or overflowing configuration
        // returns the logical tensor unchanged and does NOT launch the kernel.
        //
        // IMPORTANT: these are SWIFT-SIDE guards only. KERNEL-SIDE (Metal) bounds validation
        // — clamping/rejecting out-of-range block_ids and physical_token indices inside the
        // shader before any `physical[...]` read — remains a REQUIRED before-runtime-enable
        // gate item and is intentionally NOT added in this inert (non-serving) merge; the
        // kernel source is frozen here because the seam regression test pins it.
        let blockSize = blockSizeTokens
        guard logical.ndim == 4 else { return logical }
        let H = logical.dim(1)
        let S = logical.dim(2)
        let D = logical.dim(3)
        guard blockSize > 0, H > 0, S > 0, D > 0 else { return logical }

        let nBlocks = (S + blockSize - 1) / blockSize
        let (sPad, sPadOverflow) = nBlocks.multipliedReportingOverflow(by: blockSize)
        guard !sPadOverflow else { return logical }
        let (tokenStride, strideOverflow) = H.multipliedReportingOverflow(by: D)
        guard !strideOverflow, tokenStride > 0 else { return logical }
        // Grid size the kernel will launch (materialize uses logicalTokens * tokenStride);
        // reject before launch if it overflows Int.
        let (gridCount, gridOverflow) = S.multipliedReportingOverflow(by: tokenStride)
        guard !gridOverflow, gridCount > 0 else { return logical }
        // Physical buffer element count must also be representable.
        guard case (_, false) = sPad.multipliedReportingOverflow(by: tokenStride) else { return logical }

        // [1, H, S, D] -> token-major [S, H*D]
        var tokenMajor = logical.reshaped([H, S, D]).transposed(1, 0, 2).reshaped([S, tokenStride])
        if sPad > S {
            // Padding rows are never read (kernel only gathers the first S logical tokens).
            let pad = MLXArray.zeros([sPad - S, tokenStride], dtype: logical.dtype)
            tokenMajor = concatenated([tokenMajor, pad], axis: 0)
        }

        // Physical buffer: physical slot p holds logical block (nBlocks-1-p) → reversed order.
        let physOrder = MLXArray((0 ..< nBlocks).reversed().map { Int32($0) })
        let physical = tokenMajor
            .reshaped([nBlocks, blockSize, tokenStride])
            .take(physOrder, axis: 0)
            .reshaped([sPad, tokenStride])
        // block_ids[logicalBlock] = physical slot holding it = nBlocks-1-logicalBlock. By
        // construction every id is in [0, nBlocks); assert the invariant before launch.
        let blockIDValues = (0 ..< nBlocks).map { Int32(nBlocks - 1 - $0) }
        guard blockIDValues.allSatisfy({ $0 >= 0 && $0 < Int32(nBlocks) }) else { return logical }
        let blockIDs = MLXArray(blockIDValues)

        let kernel: MLXFast.MLXFastKernel
        if let existing = registeredKernel {
            kernel = existing
        } else {
            kernel = PagedKVGatherKernel.register()
            registeredKernel = kernel
        }

        let gathered = PagedKVGatherKernel.materialize(
            physical: physical,
            blockIDs: blockIDs,
            logicalTokens: S,
            blockSizeTokens: blockSize,
            tokenStride: tokenStride,
            outputShape: [S, tokenStride],
            using: kernel
        )
        PagedKVCache.gatherKernelCalls += 1
        PagedKVCache.maxLogicalBlocksObserved = max(PagedKVCache.maxLogicalBlocksObserved, nBlocks)
        if nBlocks > 1 { PagedKVCache.observedNonIdentityPermutation = true }

        // token-major [S, H*D] -> [1, H, S, D]
        return gathered.reshaped([S, H, D]).transposed(1, 0, 2).reshaped([1, H, S, D])
    }

    var state: [MLXArray] {
        get {
            guard storedTokens > 0, let keyBuffer, let valueBuffer else {
                return []
            }
            return [Self.prefix(keyBuffer, storedTokens), Self.prefix(valueBuffer, storedTokens)]
        }
        set {
            // Controlled handling (inert seam): ignore malformed state assignments rather
            // than aborting the process. A well-formed [keys, values] pair with matching
            // sequence length is required; anything else is a no-op.
            guard newValue.count == 2 else { return }
            let keys = newValue[0]
            let values = newValue[1]
            guard keys.ndim == 4, values.ndim == 4, keys.dim(2) == values.dim(2) else { return }
            offset = keys.dim(2)
            // Adopt as exact-capacity buffers without copying data. Wrap in new
            // slice objects: after a `trim` frees capacity, `update` writes in
            // place, and that must never touch the caller's `MLXArray` objects.
            keyBuffer = Self.prefix(keys, keys.dim(2))
            valueBuffer = Self.prefix(values, values.dim(2))
            storedTokens = keys.dim(2)
            mutationCount &+= 1
        }
    }

    var metaState: [String] {
        get {
            [
                "macprovider_paged_kv_v1",
                "handle=\(binding.handle.handleID.uuidString)",
                "block_size_tokens=\(blockSizeTokens)",
                "pool_epoch=\(poolEpoch)",
            ]
        }
        set {
            // Controlled handling (inert seam): a mismatched meta_state marker is ignored
            // rather than aborting the process. The stored metadata is derived from the
            // descriptor/binding, so there is nothing to mutate on a valid marker either.
            guard newValue.first == "macprovider_paged_kv_v1" else { return }
        }
    }

    var isTrimmable: Bool { true }

    @discardableResult
    func trim(_ n: Int) -> Int {
        let trimmed = min(offset, max(n, 0))
        guard trimmed > 0 else { return 0 }
        offset -= trimmed
        storedTokens = min(storedTokens, offset)
        // Keep capacity within the blocks the allocator still accounts for
        // (SPEC-039 FR-PKV2): a trim that frees whole blocks copies the kept
        // prefix into a right-sized buffer so the freed memory is released.
        // Positions past `storedTokens` inside the kept blocks are overwritten
        // by the next `update`.
        let keep = PagedKVBlockLayout.alignedCapacity(tokens: storedTokens, blockSizeTokens: blockSizeTokens)
        if let keyBuffer, let valueBuffer, keyBuffer.dim(2) > keep {
            self.keyBuffer = Self.resized(keyBuffer, stored: storedTokens, capacity: keep)
            self.valueBuffer = Self.resized(valueBuffer, stored: storedTokens, capacity: keep)
        }
        mutationCount &+= 1
        return trimmed
    }

    func copy() -> any KVCache {
        concreteCopy()
    }

    func concreteCopy() -> PagedKVCache {
        let copied = PagedKVCache(
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: poolEpoch,
            binding: binding,
            gatherKernel: gatherKernel,
            reconstructViaGather: reconstructViaGather
        )
        copied.state = state
        return copied
    }

    /// The structural guards of `physicalLayerBlocks` without copying any KV
    /// to host memory. Recording runs after every decode window, so it must
    /// not pay a full-history device-to-host copy per row per window.
    func validateRecordable(table: PagedKVBlockTable) throws {
        // Same checks as `physicalLayerBlocks`, computed from the buffers'
        // metadata so recording does not build per-block views every window.
        let blockCount = PagedKVBlockLayout.blockCount(tokens: storedTokens, blockSizeTokens: blockSizeTokens)
        guard offset == table.logicalTokenCount,
              table.blockSizeTokens == blockSizeTokens,
              blockCount == table.physicalBlocks.count
        else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        guard blockCount > 0,
              let keyBuffer,
              let valueBuffer,
              keyBuffer.ndim >= 3,
              valueBuffer.ndim >= 3,
              Self.firstBlockShape(keyBuffer, storedTokens: storedTokens, blockSizeTokens: blockSizeTokens)
                == Self.firstBlockShape(valueBuffer, storedTokens: storedTokens, blockSizeTokens: blockSizeTokens),
              keyBuffer.dtype == valueBuffer.dtype
        else {
            throw PagedKVContiguousCacheBridgeError.invalidLayerState
        }
        do {
            _ = try Self.pagedDType(for: keyBuffer.dtype)
        } catch {
            throw PagedKVContiguousCacheBridgeError.invalidLayerState
        }
    }

    func physicalLayerBlocks(
        layerIndex: Int,
        table: PagedKVBlockTable
    ) throws -> PagedKVRuntimePhysicalLayerBlocks {
        let keyBlocks = blockViews(keyBuffer)
        let valueBlocks = blockViews(valueBuffer)
        guard offset == table.logicalTokenCount,
              table.blockSizeTokens == blockSizeTokens,
              keyBlocks.count == valueBlocks.count,
              keyBlocks.count == table.physicalBlocks.count
        else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        guard let firstKey = keyBlocks.first,
              let firstValue = valueBlocks.first,
              firstKey.shape == firstValue.shape,
              firstKey.ndim >= 3,
              firstKey.dtype == firstValue.dtype
        else {
            throw PagedKVContiguousCacheBridgeError.invalidLayerState
        }
        let dtype: PagedKVDType
        do {
            dtype = try Self.pagedDType(for: firstKey.dtype)
        } catch {
            throw PagedKVContiguousCacheBridgeError.invalidLayerState
        }
        let sequenceAxis = firstKey.shape.count - 2
        var fullKeyShape = firstKey.shape
        var fullValueShape = firstValue.shape
        fullKeyShape[sequenceAxis] = table.logicalTokenCount
        fullValueShape[sequenceAxis] = table.logicalTokenCount
        let bytesPerToken = try Self.bytesPerToken(shape: fullKeyShape, dtype: dtype)
        return PagedKVRuntimePhysicalLayerBlocks(
            layerIndex: layerIndex,
            keyShape: fullKeyShape,
            valueShape: fullValueShape,
            dtype: dtype,
            keyBlocks: try Self.physicalBlocks(
                keyBlocks,
                table: table,
                fullShape: fullKeyShape,
                dtype: dtype
            ),
            valueBlocks: try Self.physicalBlocks(
                valueBlocks,
                table: table,
                fullShape: fullValueShape,
                dtype: dtype
            ),
            bytesPerToken: bytesPerToken
        )
    }

    func makeMask(
        n: Int,
        windowSize: Int?,
        returnArray: Bool
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        if n == 1 { return .none }
        if returnArray || (windowSize != nil && n > windowSize!) {
            return .array(createCausalMask(n: n, offset: offset, windowSize: windowSize))
        }
        return .causal
    }

    var debugDescription: String {
        "PagedKVCache(offset=\(offset), blockSizeTokens=\(blockSizeTokens), blocks=\(PagedKVBlockLayout.blockCount(tokens: storedTokens, blockSizeTokens: blockSizeTokens)))"
    }

    private var maxResidentTokens: Int {
        let (value, overflow) = blockSizeTokens.multipliedReportingOverflow(by: maxPhysicalBlocks)
        return overflow ? Int.max : value
    }

    /// A new buffer of `capacity` tokens holding `buffer`'s first `stored`
    /// tokens; nil when nothing is kept. Always fresh memory, never a view.
    private static func resized(_ buffer: MLXArray, stored: Int, capacity: Int) -> MLXArray? {
        guard capacity > 0 else { return nil }
        var shape = buffer.shape
        shape[2] = capacity - stored
        let extra = MLXArray.zeros(shape, dtype: buffer.dtype)
        guard stored > 0 else { return extra }
        return concatenated([prefix(buffer, stored), extra], axis: 2)
    }

    /// Appends `incoming` at `[stored ..< stored + n]` of `buffer`, growing it
    /// to whole allocator blocks (capped at `maxTokens`). A buffer whose dtype
    /// or non-sequence dims differ from `incoming` falls back to the old exact
    /// concatenation, so promotion and shape behavior stay unchanged.
    private static func write(
        _ incoming: MLXArray,
        into buffer: MLXArray?,
        stored: Int,
        maxTokens: Int,
        blockSizeTokens: Int
    ) -> MLXArray {
        let n = incoming.dim(2)
        guard let buffer else {
            guard n > 0 else { return prefix(incoming, 0) }
            var target = grown(nil, like: incoming, stored: 0, needed: n, maxTokens: maxTokens, blockSizeTokens: blockSizeTokens)
            target[.ellipsis, 0 ..< n, 0...] = incoming
            return target
        }
        guard n > 0 else { return buffer }
        guard buffer.ndim == 4,
              buffer.dim(0) == incoming.dim(0),
              buffer.dim(1) == incoming.dim(1),
              buffer.dim(3) == incoming.dim(3),
              buffer.dtype == incoming.dtype
        else {
            return concatenated([prefix(buffer, stored), incoming], axis: 2)
        }
        var target = buffer.dim(2) >= stored + n
            ? buffer
            : grown(buffer, like: incoming, stored: stored, needed: stored + n, maxTokens: maxTokens, blockSizeTokens: blockSizeTokens)
        target[.ellipsis, stored ..< stored + n, 0...] = incoming
        return target
    }

    private static func grown(
        _ buffer: MLXArray?,
        like incoming: MLXArray,
        stored: Int,
        needed: Int,
        maxTokens: Int,
        blockSizeTokens: Int
    ) -> MLXArray {
        let capacity = PagedKVBlockLayout.grownCapacity(needed: needed, maxTokens: maxTokens, blockSizeTokens: blockSizeTokens)
        let extra = MLXArray.zeros(
            [incoming.dim(0), incoming.dim(1), capacity - stored, incoming.dim(3)],
            dtype: incoming.dtype
        )
        guard let buffer, stored > 0 else { return extra }
        return concatenated([prefix(buffer, stored), extra], axis: 2)
    }

    /// Always a new slice, never the buffer object: MLX slice assignment
    /// mutates the `MLXArray` object in place, so handing out the buffer itself
    /// would let a later write alias into K/V the caller still holds.
    private static func prefix(_ buffer: MLXArray, _ tokens: Int) -> MLXArray {
        buffer[.ellipsis, ..<tokens, 0...]
    }

    private static func firstBlockShape(_ buffer: MLXArray, storedTokens: Int, blockSizeTokens: Int) -> [Int] {
        var shape = buffer.shape
        shape[shape.count - 2] = min(blockSizeTokens, storedTokens)
        return shape
    }

    /// Block views over the logical prefix, built only when a caller needs
    /// per-block arrays (FR-PKV10 record/materialize).
    private func blockViews(_ buffer: MLXArray?) -> [MLXArray] {
        guard storedTokens > 0, let buffer else { return [] }
        let logical = Self.prefix(buffer, storedTokens)
        return PagedKVBlockLayout.blockRanges(tokens: storedTokens, blockSizeTokens: blockSizeTokens).map {
            logical[.ellipsis, $0, 0...]
        }
    }

    private static func physicalBlocks(
        _ arrays: [MLXArray],
        table: PagedKVBlockTable,
        fullShape: [Int],
        dtype: PagedKVDType
    ) throws -> [Int: Data] {
        let sequenceAxis = fullShape.count - 2
        let outerElements = try product(fullShape.prefix(sequenceAxis))
        let innerBytes = try innerBytesPerToken(shape: fullShape, dtype: dtype)
        let blockOuterStride = try checkedMultiply(table.blockSizeTokens, innerBytes)
        let fullBlockBytes = try checkedMultiply(outerElements, blockOuterStride)
        var mappedBlocks: [Int: Data] = [:]
        mappedBlocks.reserveCapacity(table.physicalBlocks.count)
        for (blockIndex, array) in arrays.enumerated() {
            let validTokens = blockIndex == table.physicalBlocks.count - 1
                ? table.tailValidTokenCount
                : table.blockSizeTokens
            var expectedShape = fullShape
            expectedShape[sequenceAxis] = validTokens
            guard array.shape == expectedShape,
                  try pagedDType(for: array.dtype) == dtype
            else {
                throw PagedKVContiguousCacheBridgeError.blockTableMismatch
            }
            let blockData = array.asData(access: .copy)
            guard blockData.shape == expectedShape,
                  try pagedDType(for: blockData.dType) == dtype
            else {
                throw PagedKVContiguousCacheBridgeError.unsupportedDType
            }
            let validBlockBytes = try checkedMultiply(
                try checkedMultiply(outerElements, validTokens),
                innerBytes
            )
            guard blockData.data.count == validBlockBytes else {
                throw PagedKVContiguousCacheBridgeError.blockTableMismatch
            }
            var padded = Data(repeating: 0, count: fullBlockBytes)
            let sourceOuterStride = try checkedMultiply(validTokens, innerBytes)
            for outer in 0..<outerElements {
                let sourceStart = outer * sourceOuterStride
                let destinationStart = outer * blockOuterStride
                padded.replaceSubrange(
                    destinationStart ..< destinationStart + sourceOuterStride,
                    with: blockData.data[sourceStart ..< sourceStart + sourceOuterStride]
                )
            }
            let physicalID = table.physicalBlocks[blockIndex]
            guard mappedBlocks[physicalID] == nil else {
                throw PagedKVContiguousCacheBridgeError.blockTableMismatch
            }
            mappedBlocks[physicalID] = padded
        }
        guard mappedBlocks.count == table.physicalBlocks.count else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        return mappedBlocks
    }

    private static func pagedDType(for dtype: DType) throws -> PagedKVDType {
        switch dtype {
        case .float16:
            return .fp16
        case .bfloat16:
            return .bf16
        default:
            throw PagedKVContiguousCacheBridgeError.unsupportedDType
        }
    }

    private static func innerBytesPerToken(shape: [Int], dtype: PagedKVDType) throws -> Int {
        guard shape.count >= 3 else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
        let sequenceAxis = shape.count - 2
        var elements = 1
        for dim in shape.suffix(from: sequenceAxis + 1) {
            guard dim > 0 else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
            let (next, overflow) = elements.multipliedReportingOverflow(by: dim)
            guard !overflow else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
            elements = next
        }
        return try checkedMultiply(elements, dtype.byteWidth)
    }

    private static func bytesPerToken(shape: [Int], dtype: PagedKVDType) throws -> Int {
        guard shape.count >= 3 else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
        let sequenceAxis = shape.count - 2
        return try checkedMultiply(
            try product(shape.prefix(sequenceAxis)),
            try innerBytesPerToken(shape: shape, dtype: dtype)
        )
    }

    private static func product<S: Sequence>(_ values: S) throws -> Int where S.Element == Int {
        var result = 1
        for value in values {
            guard value > 0 else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
            let (next, overflow) = result.multipliedReportingOverflow(by: value)
            guard !overflow else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
            result = next
        }
        return result
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
        return value
    }
}
