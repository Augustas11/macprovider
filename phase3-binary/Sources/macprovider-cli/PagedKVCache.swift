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
        if (logical_token >= logical_token_count || lane >= token_stride
            || logical_block >= logical_block_count) {
            gathered[elem] = 0;
            return;
        }
        uint physical_block = uint(block_ids[logical_block]);
        if (physical_block >= physical_block_count) {
            gathered[elem] = 0;
            return;
        }
        uint physical_token = (physical_block * block_size_tokens) + within_block;
        if (physical_token >= physical_token_count) {
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
        logicalBlockCount: Int,
        physicalBlockCount: Int,
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
                ("logical_block_count", logicalBlockCount),
                ("physical_token_count", physicalTokenCount),
                ("physical_block_count", physicalBlockCount),
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
    private(set) var binding: PagedKVStorageBinding

    private let gatherKernel: PagedKVGatherKernel
    /// Lazily-registered Metal gather kernel. Created on first `update()` so mere
    /// construction of the seam (the SPEC-038-facing metadata surface) still runs no
    /// Metal — only driving the cache through a real forward pass executes the kernel.
    private var registeredKernel: MLXFast.MLXFastKernel?
    /// Physical K/V blocks keyed by allocator-issued block ID. Logical order is
    /// reconstructed from `binding.reservedPhysicalBlocks` when a cache state is
    /// read; the cache never invents its own physical permutation.
    private var keyBlocks: [Int: MLXArray] = [:]
    private var valueBlocks: [Int: MLXArray] = [:]
    /// `KVCache.update` is nonthrowing, so latch malformed buyer-controlled
    /// input and let the request bridge convert it into a request-local error.
    private(set) var invariantFailure: String?
    /// Stable non-sequence dimensions established by the first valid update.
    /// Later K/V tensors must remain batch/head/width compatible before host
    /// concatenation or block reshaping is attempted.
    private var tensorShape: [Int]?
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

    /// Refresh the allocator-issued reservation/table after an extend, trim, or
    /// retain/reattach transition. The K/V arrays remain owned by this cache;
    /// only the authoritative physical binding changes.
    func refresh(binding: PagedKVStorageBinding) {
        guard binding.handle == self.binding.handle,
              binding.blockSizeTokens == descriptor.blockSizeTokens,
              binding.poolEpoch == descriptor.poolEpoch
        else {
            invariantViolation("allocator binding refresh mismatch")
            return
        }
        self.binding = binding
    }

    var maxSize: Int? { maxResidentTokens }

    func innerState() -> [MLXArray] {
        state
    }

    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        // KVCache.update cannot throw. Latch malformed or over-capacity updates and
        // return the protocol-required tensors; the request bridge checks the latch
        // before committing or returning the generated result. Kernel-side checks below
        // remain defense in depth.
        if invariantFailure != nil {
            return (keys, values)
        }
        guard keys.ndim == 4,
              values.ndim == 4,
              keys.shape == values.shape,
              keys.dtype == values.dtype,
              keys.dtype == .float16,
              keys.dim(0) == 1,
              keys.dim(1) > 0,
              keys.dim(2) > 0,
              keys.dim(3) > 0
        else {
            invariantViolation("KV tensors have incompatible rank or shape")
            return (keys, values)
        }
        let incomingTensorShape = [keys.dim(0), keys.dim(1), keys.dim(3)]
        if let tensorShape, tensorShape != incomingTensorShape {
            invariantViolation("KV tensor dimensions changed during request")
            return (keys, values)
        }
        let incomingTokens = keys.dim(2)
        guard incomingTokens == values.dim(2) else {
            invariantViolation("key/value token counts differ")
            return (keys, values)
        }
        let (projectedOffset, offsetOverflow) = offset.addingReportingOverflow(incomingTokens)
        guard !offsetOverflow, projectedOffset <= maxResidentTokens else {
            invariantViolation("KV update exceeds reserved capacity")
            return (keys, values)
        }

        let mergedKeys = append(keys, to: keyBlocks)
        let mergedValues = append(values, to: valueBlocks)
        let nextOffset = projectedOffset
        guard let newKeyBlocks = physicalBlocks(for: mergedKeys, logicalTokens: nextOffset),
              let newValueBlocks = physicalBlocks(for: mergedValues, logicalTokens: nextOffset)
        else {
            invariantViolation("allocator block table cannot represent KV update")
            return (keys, values)
        }
        offset = nextOffset
        keyBlocks = newKeyBlocks
        valueBlocks = newValueBlocks
        tensorShape = incomingTensorShape
        // Reconstruct the logical K/V through the REAL Metal gather using the
        // allocator-issued physical block IDs and table order.
        let gatheredKeys = pagedGather(mergedKeys, physicalBlocks: keyBlocks)
        let gatheredValues = pagedGather(mergedValues, physicalBlocks: valueBlocks)
        return (gatheredKeys, gatheredValues)
    }

    /// Gather allocator-owned physical blocks back to logical `[1, H, S, D]`
    /// order with the registered Metal kernel.
    private func pagedGather(_ logical: MLXArray, physicalBlocks: [Int: MLXArray]) -> MLXArray {
        // Validate rank/dims and compute all shape/grid math with overflow-checked
        // arithmetic BEFORE launching the kernel. An invalid attached configuration is
        // latched; returning the logical tensor keeps the nonthrowing protocol well-formed
        // while the request bridge prevents the request from succeeding.
        //
        // The same invariants are repeated in the shader before every physical read. This
        // is intentional defense in depth: host-side validation prevents invalid launches,
        // while the kernel remains safe if a future caller supplies malformed metadata.
        let blockSize = descriptor.blockSizeTokens
        guard logical.ndim == 4 else {
            invariantViolation("logical KV tensor must be rank 4")
            return logical
        }
        let H = logical.dim(1)
        let S = logical.dim(2)
        let D = logical.dim(3)
        guard blockSize > 0, H > 0, S > 0, D > 0 else {
            invariantViolation("logical KV tensor has invalid dimensions")
            return logical
        }

        let (roundedTokens, roundedOverflow) = S.addingReportingOverflow(blockSize - 1)
        guard !roundedOverflow else {
            invariantViolation("logical block count overflow")
            return logical
        }
        let nBlocks = roundedTokens / blockSize
        let (sPad, sPadOverflow) = nBlocks.multipliedReportingOverflow(by: blockSize)
        guard !sPadOverflow else {
            invariantViolation("padded token count overflow")
            return logical
        }
        let (tokenStride, strideOverflow) = H.multipliedReportingOverflow(by: D)
        guard !strideOverflow, tokenStride > 0 else {
            invariantViolation("KV token stride overflow")
            return logical
        }
        // Grid size the kernel will launch (materialize uses logicalTokens * tokenStride);
        // reject before launch if it overflows Int.
        let (gridCount, gridOverflow) = S.multipliedReportingOverflow(by: tokenStride)
        guard !gridOverflow, gridCount > 0 else {
            invariantViolation("Metal grid size overflow")
            return logical
        }
        // Physical buffer element count must also be representable.
        let (_, physicalElementOverflow) = sPad.multipliedReportingOverflow(by: tokenStride)
        guard !physicalElementOverflow else {
            invariantViolation("physical buffer size overflow")
            return logical
        }

        // The allocator, rather than this cache, owns physical placement. Resolve
        // each allocator-issued physical ID into a launch-local dense arena in the
        // exact reserved-table order. This preserves the authoritative physical
        // mapping without allocating a buffer proportional to a sparse high ID.
        let physicalIDs = Array(binding.reservedPhysicalBlocks.prefix(nBlocks))
        guard physicalIDs.count == nBlocks,
              Set(physicalIDs).count == nBlocks,
              physicalIDs.allSatisfy({ $0 >= 0 && $0 < descriptor.maxPhysicalBlocks })
        else {
            invariantViolation("allocator physical table is invalid")
            return logical
        }
        let physicalBlockCount = nBlocks
        let (physicalTokenCount, physicalTokenOverflow) = physicalBlockCount.multipliedReportingOverflow(by: blockSize)
        guard !physicalTokenOverflow, physicalTokenCount > 0 else {
            invariantViolation("physical token count overflow")
            return logical
        }
        let (physicalStorageElementCount, physicalStorageOverflow) = physicalTokenCount.multipliedReportingOverflow(by: tokenStride)
        guard !physicalStorageOverflow else {
            invariantViolation("physical storage size overflow")
            return logical
        }
        // Keep the launch-local arena in a stable physical-slot order. The
        // logical block table supplied to Metal then remains a real permutation
        // of those dense slots instead of being erased by host-side reordering.
        let densePhysicalIDs = physicalIDs.sorted()
        let densePhysicalBlocks = densePhysicalIDs.compactMap { physicalBlocks[$0] }.map {
            $0.reshaped([H, blockSize, D])
                .transposed(1, 0, 2)
                .reshaped([blockSize, tokenStride])
        }
        guard densePhysicalBlocks.count == nBlocks else {
            invariantViolation("physical KV blocks are incomplete")
            return logical
        }
        // Each dense block is already `[blockSize, H*D]`; concatenating on the
        // token axis produces the exact rank-2 arena consumed by the Metal
        // kernel. Do not append a differently-ranked sentinel or take rows by
        // block index: that would select individual tokens and make the final
        // reshape inconsistent whenever `blockSize > 1`.
        let physical = concatenated(densePhysicalBlocks, axis: 0)
        guard physical.shape == [physicalTokenCount, tokenStride],
              physicalTokenCount * tokenStride == physicalStorageElementCount
        else {
            invariantViolation("physical KV arena shape is invalid")
            return logical
        }
        let denseSlotByPhysicalID = Dictionary(
            uniqueKeysWithValues: densePhysicalIDs.enumerated().map { ($1, Int32($0)) }
        )
        guard let blockIDValues = physicalIDs.compactMap({ denseSlotByPhysicalID[$0] }) as [Int32]?,
              blockIDValues.count == nBlocks
        else {
            invariantViolation("physical KV block remap is incomplete")
            return logical
        }
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
            physicalTokenCount: physicalTokenCount,
            logicalBlockCount: nBlocks,
            physicalBlockCount: physicalBlockCount,
            outputShape: [S, tokenStride],
            using: kernel
        )
        PagedKVCache.gatherKernelCalls += 1
        PagedKVCache.maxLogicalBlocksObserved = max(PagedKVCache.maxLogicalBlocksObserved, nBlocks)
        if blockIDValues != Array(0 ..< nBlocks).map(Int32.init) {
            PagedKVCache.observedNonIdentityPermutation = true
        }

        // token-major [S, H*D] -> [1, H, S, D]
        return gathered.reshaped([S, H, D]).transposed(1, 0, 2).reshaped([1, H, S, D])
    }

    private func invariantViolation(_ message: String) {
        if invariantFailure == nil {
            invariantFailure = message
        }
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
            if newValue.isEmpty {
                guard offset == 0, keyBlocks.isEmpty, valueBlocks.isEmpty else {
                    invariantViolation("empty KV state is only valid before the first token")
                    return
                }
                return
            }
            guard newValue.count == 2 else {
                invariantViolation("KV state must contain key and value tensors")
                return
            }
            let keys = newValue[0]
            let values = newValue[1]
            guard keys.ndim == 4,
                  values.ndim == 4,
                  keys.shape == values.shape,
                  keys.dtype == values.dtype,
                  keys.dtype == .float16,
                  keys.dim(0) == 1,
                  keys.dim(1) > 0,
                  keys.dim(2) > 0,
                  keys.dim(3) > 0,
                  keys.dim(2) == values.dim(2)
            else {
                invariantViolation("KV state has invalid shape")
                return
            }
            let newTensorShape = [keys.dim(0), keys.dim(1), keys.dim(3)]
            if let tensorShape, tensorShape != newTensorShape {
                invariantViolation("KV state dimensions changed during request")
                return
            }
            let nextOffset = keys.dim(2)
            guard let newKeyBlocks = physicalBlocks(for: keys, logicalTokens: nextOffset),
                  let newValueBlocks = physicalBlocks(for: values, logicalTokens: nextOffset)
            else {
                invariantViolation("KV state cannot be represented by allocator table")
                return
            }
            offset = nextOffset
            keyBlocks = newKeyBlocks
            valueBlocks = newValueBlocks
            tensorShape = newTensorShape
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
            guard newValue.first == "macprovider_paged_kv_v1" else {
                invariantViolation("KV meta_state marker mismatch")
                return
            }
        }
    }

    var isTrimmable: Bool { true }

    @discardableResult
    func trim(_ n: Int) -> Int {
        let trimmed = min(offset, max(n, 0))
        guard trimmed > 0 else { return 0 }
        offset -= trimmed
        if let keys = materialized(keyBlocks), let values = materialized(valueBlocks),
           let newKeyBlocks = physicalBlocks(for: keys[.ellipsis, ..<offset, 0...], logicalTokens: offset),
           let newValueBlocks = physicalBlocks(for: values[.ellipsis, ..<offset, 0...], logicalTokens: offset) {
            keyBlocks = newKeyBlocks
            valueBlocks = newValueBlocks
        } else if !keyBlocks.isEmpty || !valueBlocks.isEmpty {
            invariantViolation("trimmed KV state cannot be represented by allocator table")
        }
        return trimmed
    }

    func copy() -> any KVCache {
        let copied = PagedKVCache(descriptor: descriptor, binding: binding, gatherKernel: gatherKernel)
        copied.state = state
        copied.invariantFailure = invariantFailure
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
        let poolCapacity = overflow ? Int.max : value
        return min(binding.maxLogicalTokens, poolCapacity)
    }

    private func append(_ array: MLXArray, to blocks: [Int: MLXArray]) -> MLXArray {
        guard let current = materialized(blocks) else { return array }
        return concatenated([current, array], axis: 2)
    }

    private func materialized(_ blocks: [Int: MLXArray]) -> MLXArray? {
        guard !blocks.isEmpty else { return nil }
        _ = gatherKernel
        let blockCount = max(1, (offset + descriptor.blockSizeTokens - 1) / descriptor.blockSizeTokens)
        let orderedIDs = Array(binding.reservedPhysicalBlocks.prefix(blockCount))
        let ordered = orderedIDs.compactMap { blocks[$0] }
        guard ordered.count == blockCount else { return nil }
        let joined = ordered.count == 1 ? ordered[0] : concatenated(ordered, axis: 2)
        let logicalCount = min(offset, joined.dim(2))
        return joined[.ellipsis, ..<logicalCount, 0...]
    }

    private func physicalBlocks(for array: MLXArray, logicalTokens: Int) -> [Int: MLXArray]? {
        let tokens = array.dim(2)
        guard tokens == logicalTokens else { return nil }
        let blockCount = tokens == 0
            ? 0
            : (tokens + descriptor.blockSizeTokens - 1) / descriptor.blockSizeTokens
        let physicalIDs = Array(binding.reservedPhysicalBlocks.prefix(blockCount))
        guard physicalIDs.count == blockCount,
              Set(physicalIDs).count == blockCount,
              physicalIDs.allSatisfy({ $0 >= 0 && $0 < descriptor.maxPhysicalBlocks })
        else { return nil }
        guard blockCount > 0 else { return [:] }
        var blocks: [Int: MLXArray] = [:]
        var start = 0
        var blockIndex = 0
        while start < tokens {
            let end = min(start + descriptor.blockSizeTokens, tokens)
            let block = array[.ellipsis, start ..< end, 0...]
            let validTokens = end - start
            if validTokens < descriptor.blockSizeTokens {
                let pad = MLXArray.zeros(
                    [array.dim(0), array.dim(1), descriptor.blockSizeTokens - validTokens, array.dim(3)],
                    dtype: array.dtype
                )
                blocks[physicalIDs[blockIndex]] = concatenated([block, pad], axis: 2)
            } else {
                blocks[physicalIDs[blockIndex]] = block
            }
            start = end
            blockIndex += 1
        }
        return blocks
    }
}
