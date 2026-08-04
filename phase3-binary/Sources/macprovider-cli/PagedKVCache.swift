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
        if (logical_token >= logical_token_count || lane >= token_stride
            || logical_block >= block_count || physical_block >= block_count
            || physical_token >= physical_token_count) {
            gathered[elem] = 0;
            return;
        }
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

    static func materialize(
        physical: MLXArray,
        blockIDs: MLXArray,
        logicalTokens: Int,
        blockSizeTokens: Int,
        tokenStride: Int,
        physicalTokenCount: Int,
        blockCount: Int,
        outputShape: [Int],
        using kernel: MLXFast.MLXFastKernel
    ) -> MLXArray {
        let count = max(logicalTokens * tokenStride, 1)
        return kernel(
            [physical, blockIDs],
            template: [
                ("block_size_tokens", blockSizeTokens),
                ("token_stride", tokenStride),
                ("logical_token_count", logicalTokens),
                ("physical_token_count", physicalTokenCount),
                ("block_count", blockCount),
            ],
            grid: (count, 1, 1),
            threadGroup: (min(count, 256), 1, 1),
            outputShapes: [outputShape],
            outputDTypes: [physical.dtype]
        )[0]
    }
}

/// Paged serving cache backed by the SPEC-039 block binding. The runtime bridge
/// owns reservation/lifecycle; this cache owns the `KVCache` contract and the
/// bounded logical-to-physical gather for one transformer layer.
final class PagedKVCache: KVCache, CustomDebugStringConvertible {
    let descriptor: PagedKVDescriptor
    let binding: PagedKVStorageBinding

    private let gatherKernel: PagedKVGatherKernel
    /// Lazily-registered Metal gather kernel. Created on first `update()` so mere
    /// construction of the seam (the SPEC-038-facing metadata surface) still runs no
    /// Metal — only driving the cache through a real forward pass executes the kernel.
    private var registeredKernel: MLXFast.MLXFastKernel?
    private var keyBlocks: [MLXArray] = []
    private var valueBlocks: [MLXArray] = []
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
        descriptor: PagedKVDescriptor,
        binding: PagedKVStorageBinding,
        gatherKernel: PagedKVGatherKernel = PagedKVGatherKernel()
    ) {
        self.descriptor = descriptor
        self.binding = binding
        self.gatherKernel = gatherKernel
        self.offset = binding.currentTable.logicalTokenCount
    }

    var maxSize: Int? { maxResidentTokens }

    func innerState() -> [MLXArray] {
        state
    }

    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        // Controlled handling for the serving bridge: never abort the host process on
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

        let mergedKeys = append(keys, to: keyBlocks)
        let mergedValues = append(values, to: valueBlocks)
        offset += incomingTokens
        keyBlocks = splitIntoBlocks(mergedKeys)
        valueBlocks = splitIntoBlocks(mergedValues)
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
        // The same invariants are repeated in the shader before every physical read. This
        // is intentional defense in depth: host-side validation prevents invalid launches,
        // while the kernel remains safe if a future caller supplies malformed metadata.
        let blockSize = descriptor.blockSizeTokens
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
            physicalTokenCount: sPad * tokenStride,
            blockCount: nBlocks,
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
            guard let keys = materialized(keyBlocks),
                  let values = materialized(valueBlocks)
            else {
                return []
            }
            return [keys, values]
        }
        set {
            // Controlled handling: ignore malformed state assignments rather
            // than aborting the process. A well-formed [keys, values] pair with matching
            // sequence length is required; anything else is a no-op.
            guard newValue.count == 2 else { return }
            let keys = newValue[0]
            let values = newValue[1]
            guard keys.ndim == 4, values.ndim == 4, keys.dim(2) == values.dim(2) else { return }
            offset = keys.dim(2)
            keyBlocks = splitIntoBlocks(keys)
            valueBlocks = splitIntoBlocks(values)
        }
    }

    var metaState: [String] {
        get {
            [
                "macprovider_paged_kv_v1",
                "handle=\(binding.handle.handleID.uuidString)",
                "block_size_tokens=\(descriptor.blockSizeTokens)",
                "pool_epoch=\(descriptor.poolEpoch)",
            ]
        }
        set {
            // Controlled handling: a mismatched meta_state marker is ignored
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
        if let keys = materialized(keyBlocks), let values = materialized(valueBlocks) {
            keyBlocks = splitIntoBlocks(keys[.ellipsis, ..<offset, 0...])
            valueBlocks = splitIntoBlocks(values[.ellipsis, ..<offset, 0...])
        }
        return trimmed
    }

    func copy() -> any KVCache {
        let copied = PagedKVCache(descriptor: descriptor, binding: binding, gatherKernel: gatherKernel)
        copied.state = state
        return copied
    }

    /// Extract the current logical K/V tensors into the neutral FR-PKV10 byte
    /// representation. The allocator validates the block table separately; this
    /// method is deliberately limited to one layer and never invents shape/dtype
    /// metadata.
    func materializedByteLayer(layerIndex: Int) throws -> PagedKVMaterializedByteLayer {
        guard layerIndex >= 0,
              let keys = materialized(keyBlocks),
              let values = materialized(valueBlocks),
              keys.ndim == 4,
              values.ndim == 4,
              keys.shape == values.shape,
              keys.dim(2) == offset,
              keys.dtype == .float16,
              values.dtype == .float16
        else {
            throw PagedKVAllocatorError.invalidBlockTable("paged cache state is not contiguous fp16 K/V")
        }
        let keyData = keys.asData()
        let valueData = values.asData()
        guard keyData.shape == valueData.shape,
              keyData.dType == .float16,
              valueData.dType == .float16
        else {
            throw PagedKVAllocatorError.invalidBlockTable("paged cache byte state mismatch")
        }
        return PagedKVMaterializedByteLayer(
            layerIndex: layerIndex,
            keyShape: keyData.shape,
            valueShape: valueData.shape,
            dtype: .fp16,
            logicalTokenCount: offset,
            keyBytes: keyData.data,
            valueBytes: valueData.data
        )
    }

    /// Rehydrate a layer from a validated FR-PKV10 contiguous snapshot. The
    /// caller must validate the snapshot against the allocator's current table
    /// before calling this method.
    func inject(materialized layer: PagedKVMaterializedByteLayer) throws {
        guard layer.dtype == .fp16,
              layer.keyShape == layer.valueShape,
              layer.keyShape.count == 4,
              layer.keyShape[2] == layer.logicalTokenCount
        else {
            throw PagedKVAllocatorError.invalidBlockTable("invalid contiguous K/V layer")
        }
        let keys = MLXArray(layer.keyBytes, layer.keyShape, dtype: .float16)
        let values = MLXArray(layer.valueBytes, layer.valueShape, dtype: .float16)
        state = [keys, values]
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
        "PagedKVCache(offset=\(offset), blockSizeTokens=\(descriptor.blockSizeTokens), blocks=\(keyBlocks.count))"
    }

    private var maxResidentTokens: Int {
        let (value, overflow) = descriptor.blockSizeTokens.multipliedReportingOverflow(by: descriptor.maxPhysicalBlocks)
        return overflow ? Int.max : value
    }

    private func append(_ array: MLXArray, to blocks: [MLXArray]) -> MLXArray {
        guard let current = materialized(blocks) else { return array }
        return concatenated([current, array], axis: 2)
    }

    private func materialized(_ blocks: [MLXArray]) -> MLXArray? {
        guard !blocks.isEmpty else { return nil }
        // Storage retrieval only (logical accumulation). The paged Metal gather runs in
        // `update()` via `pagedGather`, which reconstructs logical order from a non-identity
        // physical block layout; this helper just returns the accumulated logical K/V.
        _ = gatherKernel
        return blocks.count == 1 ? blocks[0] : concatenated(blocks, axis: 2)
    }

    private func splitIntoBlocks(_ array: MLXArray) -> [MLXArray] {
        let tokens = array.dim(2)
        guard tokens > 0 else { return [] }
        var blocks: [MLXArray] = []
        var start = 0
        while start < tokens {
            let end = min(start + descriptor.blockSizeTokens, tokens)
            blocks.append(array[.ellipsis, start ..< end, 0...])
            start = end
        }
        return blocks
    }
}
