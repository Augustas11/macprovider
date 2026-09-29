import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

enum PagedKVContiguousCacheBridgeError: Error, Equatable {
    case noRecordedBlocks
    case unsupportedDType
    case invalidLayerState
    case blockTableMismatch
    case trimShortfall
}

struct PagedKVContiguousCacheHandoff {
    let handle: PagedKVBlockTableHandle
    private let blockTable: PagedKVBlockTable
    private(set) var logicalTokenCount: Int
    private(set) var tailValidTokenCount: Int
    let caches: [KVCacheSimple]

    init(materializedByteCache cache: PagedKVMaterializedByteCache) throws {
        self.handle = cache.handle
        self.blockTable = cache.blockTable
        self.logicalTokenCount = cache.blockTable.logicalTokenCount
        self.tailValidTokenCount = cache.blockTable.tailValidTokenCount
        self.caches = try Self.restoreCaches(from: cache)
    }

    mutating func trim(toLogicalTokens tokens: Int) throws {
        guard tokens >= 0, tokens <= logicalTokenCount else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        let trimCount = logicalTokenCount - tokens
        guard trimCount > 0 else { return }
        for cache in caches {
            guard cache.isTrimmable, cache.trim(trimCount) == trimCount else {
                throw PagedKVContiguousCacheBridgeError.trimShortfall
            }
        }
        logicalTokenCount = tokens
        tailValidTokenCount = tokens == 0 ? 0 : ((tokens - 1) % blockTable.blockSizeTokens) + 1
    }

    private static func restoreCaches(from cache: PagedKVMaterializedByteCache) throws -> [KVCacheSimple] {
        var restored: [KVCacheSimple] = []
        for layer in cache.layers.sorted(by: { $0.layerIndex < $1.layerIndex }) {
            let mlxDType: DType
            switch layer.dtype {
            case .fp16:
                mlxDType = .float16
            case .bf16:
                mlxDType = .bfloat16
            }
            guard layer.keyShape == layer.valueShape,
                  layer.keyShape.count >= 3,
                  layer.keyShape[layer.keyShape.count - 2] == cache.blockTable.logicalTokenCount,
                  layer.logicalTokenCount == cache.blockTable.logicalTokenCount
            else {
                throw PagedKVContiguousCacheBridgeError.blockTableMismatch
            }
            let expectedBytes = try byteCount(shape: layer.keyShape, dtype: layer.dtype)
            guard layer.keyBytes.count == expectedBytes, layer.valueBytes.count == expectedBytes else {
                throw PagedKVContiguousCacheBridgeError.blockTableMismatch
            }
            let key = MLXArray(layer.keyBytes, layer.keyShape, dtype: mlxDType)
            let value = MLXArray(layer.valueBytes, layer.valueShape, dtype: mlxDType)
            let contiguous = KVCacheSimple()
            contiguous.state = [key, value]
            guard contiguous.offset == cache.blockTable.logicalTokenCount else {
                throw PagedKVContiguousCacheBridgeError.blockTableMismatch
            }
            restored.append(contiguous)
        }
        return restored
    }

    private static func byteCount(shape: [Int], dtype: PagedKVDType) throws -> Int {
        guard shape.count >= 3, shape.allSatisfy({ $0 >= 0 }) else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        var elements = 1
        for dim in shape {
            let (next, overflow) = elements.multipliedReportingOverflow(by: dim)
            guard !overflow else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
            elements = next
        }
        let (bytes, overflow) = elements.multipliedReportingOverflow(by: dtype.byteWidth)
        guard !overflow else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
        return bytes
    }

}

struct PagedKVPagedCacheHandoff {
    let handle: PagedKVBlockTableHandle
    let blockTable: PagedKVBlockTable
    let logicalTokenCount: Int
    let tailValidTokenCount: Int
    let caches: [PagedKVCache]

    init(handle: PagedKVBlockTableHandle, blockTable: PagedKVBlockTable, caches: [PagedKVCache]) {
        self.handle = handle
        self.blockTable = blockTable
        self.logicalTokenCount = blockTable.logicalTokenCount
        self.tailValidTokenCount = blockTable.tailValidTokenCount
        self.caches = caches
    }
}

struct PagedKVRuntimePhysicalLayerBlocks: Equatable, Sendable {
    let layerIndex: Int
    let keyShape: [Int]
    let valueShape: [Int]
    let dtype: PagedKVDType
    let keyBlocks: [Int: Data]
    let valueBlocks: [Int: Data]
    let bytesPerToken: Int
}

protocol PagedKVRuntimeCacheBridge: Sendable {
    func record(caches: [PagedKVCache], binding: PagedKVStorageBinding) throws
    func discard(handle: PagedKVBlockTableHandle)
    func discardContiguousCache(handle: PagedKVBlockTableHandle)
}

final class PagedKVRuntimeContiguousCacheBridge: PagedKVContiguousCacheBridge, PagedKVRuntimeCacheBridge, @unchecked Sendable {
    private struct Record {
        let version = UUID()
        let handle: PagedKVBlockTableHandle
        var table: PagedKVBlockTable
        let caches: [PagedKVCache]
    }

    private let lock = NSLock()
    private var recordsByHandle: [UUID: Record] = [:]

    func record(caches: [PagedKVCache], binding: PagedKVStorageBinding) throws {
        let table = binding.currentTable
        try caches.forEach { cache in
            try Self.validateHandle(cache.binding.handle, matches: binding.handle)
            // Same offset/table/shape guards the eager host copy used to
            // enforce, without the copy: that copy was ~40% of every batched
            // decode window and only the FR-PKV10 materialize path reads it.
            try cache.validateRecordable(table: table)
        }
        lock.lock()
        recordsByHandle[binding.handle.handleID] = Record(
            handle: binding.handle,
            table: table,
            caches: caches
        )
        lock.unlock()
    }

    func discard(handle: PagedKVBlockTableHandle) {
        discardContiguousCache(handle: handle)
    }

    func discardContiguousCache(handle: PagedKVBlockTableHandle) {
        lock.lock()
        recordsByHandle.removeValue(forKey: handle.handleID)
        lock.unlock()
    }

    func trimRecordedContiguousCache(
        handle: PagedKVBlockTableHandle,
        table: PagedKVBlockTable
    ) throws {
        lock.lock()
        let existing = recordsByHandle[handle.handleID]
        lock.unlock()
        guard var record = existing else { return }
        try Self.validateHandle(handle, matches: record.handle)
        guard Self.isSameTableIdentity(record.table, table),
              table.logicalTokenCount <= record.table.logicalTokenCount,
              record.table.physicalBlocks.prefix(table.physicalBlocks.count).elementsEqual(table.physicalBlocks)
        else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        for cache in record.caches {
            guard cache.offset == record.table.logicalTokenCount, cache.isTrimmable else {
                throw PagedKVContiguousCacheBridgeError.blockTableMismatch
            }
        }
        lock.lock()
        let stillCurrent = recordsByHandle[handle.handleID]?.version == record.version
        lock.unlock()
        guard stillCurrent else { return }
        for cache in record.caches {
            let trimCount = cache.offset - table.logicalTokenCount
            if trimCount > 0 {
                guard cache.trim(trimCount) == trimCount else {
                    discardContiguousCache(handle: handle)
                    throw PagedKVContiguousCacheBridgeError.trimShortfall
                }
            }
        }
        if table.logicalTokenCount == 0 {
            discardContiguousCache(handle: handle)
            return
        }
        for cache in record.caches {
            try Self.validateRecordableCache(cache, expectedHandle: handle, table: table)
        }
        record.table = table
        lock.lock()
        if recordsByHandle[handle.handleID]?.version == record.version {
            recordsByHandle[handle.handleID] = record
        }
        lock.unlock()
    }

    func materializeContiguousByteCache(
        handle: PagedKVBlockTableHandle,
        table: PagedKVBlockTable
    ) throws -> PagedKVMaterializedByteCache {
        lock.lock()
        let record = recordsByHandle[handle.handleID]
        lock.unlock()
        guard let record else { throw PagedKVContiguousCacheBridgeError.noRecordedBlocks }
        try Self.validateHandle(handle, matches: record.handle)
        guard table == record.table else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        // Built on demand from the recorded caches, which the record keeps
        // bound to its handle exactly as `reattachPagedKVCache` relies on.
        // `physicalLayerBlocks` re-checks offset == table, so a cache that
        // moved past the recorded table fails closed instead of returning
        // bytes for a different state.
        let physicalLayers = try record.caches.enumerated().map { layerIndex, cache in
            try cache.physicalLayerBlocks(layerIndex: layerIndex, table: table)
        }
        let materializedLayers = try physicalLayers.sorted(by: { $0.layerIndex < $1.layerIndex }).map { layer in
            guard layer.keyBlocks.count == table.physicalBlocks.count,
                  layer.valueBlocks.count == table.physicalBlocks.count
            else {
                throw PagedKVContiguousCacheBridgeError.blockTableMismatch
            }
            let keyShape = try Self.shape(layer.keyShape, logicalTokens: table.logicalTokenCount)
            let valueShape = try Self.shape(layer.valueShape, logicalTokens: table.logicalTokenCount)
            return PagedKVMaterializedByteLayer(
                layerIndex: layer.layerIndex,
                keyShape: keyShape,
                valueShape: valueShape,
                dtype: layer.dtype,
                logicalTokenCount: table.logicalTokenCount,
                keyBytes: try Self.materializeShapedComponent(
                    table: table,
                    physicalBlocks: layer.keyBlocks,
                    shape: keyShape,
                    dtype: layer.dtype
                ),
                valueBytes: try Self.materializeShapedComponent(
                    table: table,
                    physicalBlocks: layer.valueBlocks,
                    shape: valueShape,
                    dtype: layer.dtype
                )
            )
        }
        return PagedKVMaterializedByteCache(handle: handle, blockTable: table, layers: materializedLayers)
    }

    func materializeContiguousKVCache(
        handle: PagedKVBlockTableHandle,
        table: PagedKVBlockTable
    ) throws -> PagedKVContiguousCacheHandoff {
        try PagedKVContiguousCacheHandoff(materializedByteCache: materializeContiguousByteCache(
            handle: handle,
            table: table
        ))
    }

    func reattachPagedKVCache(
        handle: PagedKVBlockTableHandle,
        table: PagedKVBlockTable
    ) throws -> PagedKVPagedCacheHandoff {
        lock.lock()
        let record = recordsByHandle[handle.handleID]
        lock.unlock()
        guard let record else { throw PagedKVContiguousCacheBridgeError.noRecordedBlocks }
        try Self.validateHandle(handle, matches: record.handle)
        guard table == record.table else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        try record.caches.forEach { cache in
            try Self.validateRecordableCache(cache, expectedHandle: handle, table: table)
        }
        return PagedKVPagedCacheHandoff(handle: handle, blockTable: table, caches: record.caches)
    }

    private static func validateHandle(
        _ handle: PagedKVBlockTableHandle,
        matches recorded: PagedKVBlockTableHandle
    ) throws {
        guard handle == recorded else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
    }

    private static func isSameTableIdentity(_ lhs: PagedKVBlockTable, _ rhs: PagedKVBlockTable) -> Bool {
        lhs.handleID == rhs.handleID
            && lhs.blockSizeTokens == rhs.blockSizeTokens
            && lhs.poolEpoch == rhs.poolEpoch
    }

    private static func validateRecordableCache(
        _ cache: PagedKVCache,
        expectedHandle: PagedKVBlockTableHandle,
        table: PagedKVBlockTable
    ) throws {
        try validateHandle(cache.binding.handle, matches: expectedHandle)
        guard cache.offset == table.logicalTokenCount else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        _ = try cache.physicalLayerBlocks(layerIndex: 0, table: table)
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

    private static func materializeShapedComponent(
        table: PagedKVBlockTable,
        physicalBlocks: [Int: Data],
        shape: [Int],
        dtype: PagedKVDType
    ) throws -> Data {
        guard try sequenceLength(for: shape) == table.logicalTokenCount else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        let sequenceAxis = shape.count - 2
        let outerElements = try product(shape.prefix(sequenceAxis))
        let innerBytes = try innerBytesPerToken(shape: shape, dtype: dtype)
        let blockOuterStride = table.blockSizeTokens * innerBytes
        var output = Data()
        output.reserveCapacity(try totalBytes(shape: shape, dtype: dtype))
        for outer in 0..<outerElements {
            for (blockIndex, physicalID) in table.physicalBlocks.enumerated() {
                guard let block = physicalBlocks[physicalID] else {
                    throw PagedKVContiguousCacheBridgeError.blockTableMismatch
                }
                guard block.count >= (outer + 1) * blockOuterStride else {
                    throw PagedKVContiguousCacheBridgeError.blockTableMismatch
                }
                let validTokens = blockIndex == table.physicalBlocks.count - 1
                    ? table.tailValidTokenCount
                    : table.blockSizeTokens
                let byteCount = validTokens * innerBytes
                let sourceStart = outer * blockOuterStride
                output.append(block[sourceStart ..< sourceStart + byteCount])
            }
        }
        guard output.count == (try totalBytes(shape: shape, dtype: dtype)) else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        return output
    }

    private static func sequenceLength(for shape: [Int]) throws -> Int {
        guard shape.count >= 3, shape.allSatisfy({ $0 >= 0 }) else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        return shape[shape.count - 2]
    }

    private static func shape(_ shape: [Int], logicalTokens: Int) throws -> [Int] {
        guard logicalTokens >= 0,
              shape.count >= 3,
              try sequenceLength(for: shape) >= logicalTokens
        else {
            throw PagedKVContiguousCacheBridgeError.blockTableMismatch
        }
        var adjusted = shape
        adjusted[adjusted.count - 2] = logicalTokens
        return adjusted
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
        let (bytes, overflow) = elements.multipliedReportingOverflow(by: dtype.byteWidth)
        guard !overflow else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
        return bytes
    }

    private static func bytesPerToken(shape: [Int], dtype: PagedKVDType) throws -> Int {
        guard shape.count >= 3 else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
        let sequenceAxis = shape.count - 2
        let outerElements = try product(shape.prefix(sequenceAxis))
        let innerBytes = try innerBytesPerToken(shape: shape, dtype: dtype)
        let (bytes, overflow) = outerElements.multipliedReportingOverflow(by: innerBytes)
        guard !overflow else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
        return bytes
    }

    private static func totalBytes(shape: [Int], dtype: PagedKVDType) throws -> Int {
        let tokens = try sequenceLength(for: shape)
        let perToken = try bytesPerToken(shape: shape, dtype: dtype)
        let (bytes, overflow) = tokens.multipliedReportingOverflow(by: perToken)
        guard !overflow else { throw PagedKVContiguousCacheBridgeError.blockTableMismatch }
        return bytes
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
}

extension PagedKVRuntimeContiguousCacheBridge: ContinuousBatchRetainedCacheBridge {}

/// SPEC-039 / SPEC-038 Increment 1 runtime bridge.
///
/// This backend is installable only after the attach gate has separately
/// measured the runtime identity and validated the model's cache topology.
/// Shape and dtype of one recurrent-state slot, checked without reading
/// tensor data.
struct RecurrentStateSlotLayout: Equatable, Sendable {
    let shape: [Int]
    let dtype: DType
}

struct PagedKVMTPPackedCacheExerciseResult: Equatable {
    let batchOffsetsBeforeUpdate: [Int]
    let returnedKeyShape: [Int]
    let rowOffsetsAfterUpdate: [Int]
    let rowStoredTokensAfterUpdate: [Int]
    let rowStateTokenCountsAfterUpdate: [Int]
    let batchTokenCountBeforeFinalize: Int
    let batchTokenCountAfterFinalize: Int
    let rowStateTokenCountsAfterFinalize: [Int]
    let maskShape: [Int]
    let maskValues: [Bool]
}

struct PagedKVMTPPackedCacheResolutionResult: Equatable {
    let rowOffsetsAfterStaging: [Int]
    let rowStoredTokensAfterStaging: [Int]
    let rowStateTokenCountsAfterStaging: [Int]
    let pendingInputCountsBeforeFinalize: [Int]
    let pendingProposalCountsBeforeFinalize: [Int]
    let pendingInputCountsAfterFacadeFinalize: [Int]
    let pendingProposalCountsAfterFacadeFinalize: [Int]
    let rowOffsetsAfterResolution: [Int]
    let rowStoredTokensAfterResolution: [Int]
    let rowStateTokenCountsAfterResolution: [Int]
}

final class PagedKVSharedForwardBackend: ContinuousBatchSchedulerBackend, @unchecked Sendable {
    /// `MambaCache` holds exactly two slots (conv state, SSM state).
    static let mambaCacheSlotCount = 2

    /// SPEC-038 AC-26: a checkpoint is installable only if it covers exactly the
    /// model's recurrent layers, each with the `MambaCache` slot count, and every
    /// slot is a single-row (batch 1) floating-point tensor of rank >= 2. All
    /// recurrent layers of one model share one state layout, so every layer
    /// must match the first; a layer that differs is corrupt or from another
    /// model.
    static func recurrentCheckpointLayoutIsValid(
        _ layouts: [Int: [RecurrentStateSlotLayout]],
        recurrentLayerIndices: [Int]
    ) -> Bool {
        guard let first = recurrentLayerIndices.first,
              Set(layouts.keys) == Set(recurrentLayerIndices),
              let reference = layouts[first],
              reference.count == mambaCacheSlotCount
        else { return false }
        let slotsValid = reference.allSatisfy { slot in
            slot.shape.count >= 2
                && slot.shape[0] == 1
                && slot.shape.allSatisfy { $0 > 0 }
                && [DType.float16, .bfloat16, .float32].contains(slot.dtype)
        }
        return slotsValid && layouts.values.allSatisfy { $0 == reference }
    }

    enum CacheKind: Equatable, Sendable {
        case pagedAttention
        case recurrentMamba
    }

    private struct RowState {
        var caches: [KVCache]
        var state: LMOutput.State?
    }

    private struct DecodeSession {
        var requestIDs: [String]
        var batchedCaches: [PagedKVSharedLayerBatch]
        var compiledCaches: [KVCache]
        var compiledStep: CompiledDecodeStep?
    }

    private struct NativeMTPPendingTransaction {
        let proposalTokenCount: Int
        /// Target token already sampled from the fully committed prompt and
        /// evaluated as the first column of this verification round.
        let currentToken: Int
        let targetState: MTPPackedVerificationRowState
        let draftTokens: MLXArray?
        let layers: [NativeMTPPendingLayerResolution]
    }

    private let container: ModelContainer
    private let drafterContainer: MTPDrafterContainer?
    private let blockSizeTokens: Int
    private let maxPhysicalBlocks: Int
    private let poolEpoch: Int
    private let cacheKinds: [CacheKind]
    private let contiguousCacheBridge: (any PagedKVRuntimeCacheBridge)?
    /// When true, lockstep decode reuses a compiled `[B, 1]` graph over batched
    /// contiguous KV. Tests keep the default off so fake models are not traced.
    let compiledDecode: Bool
    private let lock = NSLock()
    private var rows: [String: RowState] = [:]
    private var decodeSession: DecodeSession?
    private var nativeMTPPendingTransactions: [String: NativeMTPPendingTransaction] = [:]
    private var nativeMTPTargetStates: [String: MTPPackedVerificationRowState] = [:]
    private var nativeMTPDrafterStates: [String: MTPDrafterState] = [:]
    private var nativeMTPDraftTokens: [String: MLXArray] = [:]
#if MACPROVIDER_MLX_PACKED_DRAFTER
    private struct NativeMTPDeferredDrafterAdvance: @unchecked Sendable {
        let draftTokens: MLXArray
        let acceptedCount: Int
        let finalToken: Int
    }

    /// Finalize records the accepted row-local transition without running the
    /// drafter. The next proposal round packs only continuing rows into one
    /// forward; terminal rows are removed without paying for an unused seed.
    private var nativeMTPDeferredDrafterAdvances: [String: NativeMTPDeferredDrafterAdvance] = [:]
#endif
    private var activeOperations = 0
    private var cancelRequested = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        container: ModelContainer,
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        poolEpoch: Int,
        layerCount: Int,
        cacheKinds: [CacheKind]? = nil,
        contiguousCacheBridge: (any PagedKVRuntimeCacheBridge)? = nil,
        compiledDecode: Bool = false,
        drafterContainer: MTPDrafterContainer? = nil
    ) {
        self.container = container
        self.drafterContainer = drafterContainer
        self.blockSizeTokens = blockSizeTokens
        self.maxPhysicalBlocks = maxPhysicalBlocks
        self.poolEpoch = poolEpoch
        if let cacheKinds, !cacheKinds.isEmpty {
            self.cacheKinds = cacheKinds
        } else {
            self.cacheKinds = Array(repeating: .pagedAttention, count: max(1, layerCount))
        }
        self.contiguousCacheBridge = contiguousCacheBridge
        self.compiledDecode = compiledDecode
    }

    /// Descriptor-sourced convenience initializer. Kept for existing production and test
    /// call sites that still build a full `PagedKVDescriptor`; forwards only the three
    /// primitive fields this backend actually reads. NOT used by the load-time probe seam,
    /// which never constructs a `PagedKVDescriptor` (that memberwise init is internal to
    /// `MacProviderCore` and invisible from this module).
    convenience init(
        container: ModelContainer,
        descriptor: PagedKVDescriptor,
        layerCount: Int,
        cacheKinds: [CacheKind]? = nil,
        contiguousCacheBridge: (any PagedKVRuntimeCacheBridge)? = nil,
        compiledDecode: Bool = false,
        drafterContainer: MTPDrafterContainer? = nil
    ) {
        self.init(
            container: container,
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks,
            poolEpoch: descriptor.poolEpoch,
            layerCount: layerCount,
            cacheKinds: cacheKinds,
            contiguousCacheBridge: contiguousCacheBridge,
            compiledDecode: compiledDecode,
            drafterContainer: drafterContainer
        )
    }

    func prefill(rows inputs: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        return try await container.perform(nonSendable: inputs) { context, inputs in
            if Self.canSharePrefillForward(inputs) {
                let rowStates = inputs.map {
                    self.rowState(
                        for: $0.requestID,
                        binding: $0.binding,
                        initialOffset: $0.committedKVTokenCount
                    )
                }
                // Generic LMOutput.State cannot be split safely by row. The
                // supported paged and hybrid runtimes keep recurrent state in
                // their cache layers; any backend-level state uses the proven
                // serial fallback instead.
                if rowStates.allSatisfy({ $0.state == nil }),
                   let batchedCaches = self.makeBatchedCachesIfCompatible(
                       from: rowStates.map(\.caches)
                   ) {
                    let cachesAsKV = batchedCaches.map(\.cache)
                    let chunkLength = inputs[0].promptTokens.count
                    let prompt = MLXArray(
                        inputs.flatMap(\.promptTokens).map(Int32.init)
                    ).reshaped([inputs.count, chunkLength])
                    let text = LMInput.Text(tokens: prompt)
                    let output = withPreparedCache(cachesAsKV, lengths: text.sequenceLengths) {
                        context.model(text, cache: cachesAsKV, state: nil)
                    }
                    if output.state == nil,
                       Self.hasValidBatchState(batchedCaches) {
                        let sampledTokens: [Int]?
                        if inputs.contains(where: \.sampleFirstToken) {
                            sampledTokens = ContinuousBatchRowSampler.sample(
                                logits: output.logits[0..., -1, 0...],
                                rows: inputs.map(Self.samplerRow)
                            ).asArray(Int.self)
                            guard sampledTokens?.count == inputs.count else {
                                throw ContinuousBatchSchedulerError.unsupported(
                                    "continuous_batching_invalid_logits_shape"
                                )
                            }
                        } else {
                            sampledTokens = nil
                        }
                        eval(cachesAsKV)
                        batchedCaches.forEach { $0.syncRowsFromBatch() }
                        for (index, input) in inputs.enumerated() {
                            try self.setRowState(rowStates[index], for: input.requestID, binding: input.binding)
                        }
                        self.clearDecodeSession()
                        return inputs.enumerated().map { index, input in
                            ContinuousBatchPrefillOutput(
                                requestID: input.requestID,
                                sampledToken: input.sampleFirstToken ? sampledTokens?[index] : nil
                            )
                        }
                    }
                    // Backend-level LMOutput.State cannot be split safely by
                    // row. The speculative batched caches have not been synced
                    // back, so discard them and use the isolated serial path.
                }
            }

#if DEBUG || MACPROVIDER_LAB_HARNESS
            let parityPrefillRoundID = NativeMTPParityTraceCollector.shared.allocatePackedRoundID()
#endif
            var outputs: [ContinuousBatchPrefillOutput] = []
            outputs.reserveCapacity(inputs.count)
            for input in inputs {
                do {
                    var state = self.rowState(
                        for: input.requestID,
                        binding: input.binding,
                        initialOffset: input.committedKVTokenCount
                    )
                    var sampledToken: Int?
                    if !input.promptTokens.isEmpty {
                        let prompt = MLXArray(input.promptTokens.map(Int32.init))
                            .reshaped([1, input.promptTokens.count])
                        let text = LMInput.Text(tokens: prompt)
                        var modelState = state.state
                        if input.nativeMTPPromptPrefill {
                            modelState = modelState ?? LMOutput.State()
                            modelState?[mtpEmitFlagKey] = true
                        }
                        let output = withPreparedCache(state.caches, lengths: text.sequenceLengths) {
                            context.model(text, cache: state.caches, state: modelState)
                        }
                        if input.sampleFirstToken {
                            sampledToken = ContinuousBatchRowSampler.sample(
                                logits: output.logits[0..., -1, 0...],
                                rows: [Self.samplerRow(input)]
                            ).asArray(Int.self).first
                        } else {
                            sampledToken = nil
                        }
                        if input.nativeMTPPromptPrefill {
                            guard let sampledToken else {
                                throw ContinuousBatchSchedulerError.unsupported(
                                    "native_mtp_missing_prompt_bonus_token"
                                )
                            }
                            try await self.prepareNativeMTPDrafterState(
                                targetModel: context.model,
                                prompt: prompt,
                                output: output,
                                firstBonusToken: sampledToken,
                                requestID: input.requestID
                            )
#if DEBUG || MACPROVIDER_LAB_HARNESS
                            NativeMTPParityTraceCollector.shared.recordPrefillToken(
                                requestID: input.requestID,
                                token: sampledToken,
                                targetLogits: output.logits[0..., -1, 0...],
                                packedRoundID: parityPrefillRoundID
                            )
#endif
                        }
                        // Earlier chunks evaluate only cache state. The final
                        // chunk also evaluates its sampled token, matching
                        // `TokenIterator.prepare` on the serial path.
                        eval(state.caches)
                        state.state = output.state
                    }
                    try self.setRowState(state, for: input.requestID, binding: input.binding)
                    outputs.append(ContinuousBatchPrefillOutput(
                        requestID: input.requestID,
                        sampledToken: input.sampleFirstToken ? sampledToken : nil
                    ))
                } catch {
                    self.removeRowState(for: input.requestID)
                    outputs.append(ContinuousBatchPrefillOutput(
                        requestID: input.requestID,
                        failureCode: "continuous_batching_prefill_failed"
                    ))
                }
            }
#if DEBUG || MACPROVIDER_LAB_HARNESS
            NativeMTPParityTraceCollector.shared.sealPackedCoordinates([
                NativeMTPParityCoordinate(
                    packedRoundID: parityPrefillRoundID,
                    verificationColumn: 0
                )
            ])
#endif
            self.clearDecodeSession()
            return outputs
        }
    }

    private func makeBatchedCachesIfCompatible(
        from rowCaches: [[KVCache]]
    ) -> [PagedKVSharedLayerBatch]? {
        try? makeBatchedCaches(from: rowCaches)
    }

    private static func hasValidBatchState(_ batches: [PagedKVSharedLayerBatch]) -> Bool {
        do {
            try batches.forEach { try $0.validateBatchState() }
            return true
        } catch {
            return false
        }
    }

    private static func canSharePrefillForward(_ inputs: [ContinuousBatchPrefillInput]) -> Bool {
        guard inputs.count > 1, let first = inputs.first, !first.promptTokens.isEmpty else {
            return false
        }
        guard inputs.allSatisfy({ !$0.nativeMTPPromptPrefill }) else {
            return false
        }
        let chunkLength = first.promptTokens.count
        return inputs.allSatisfy {
            $0.promptTokens.count == chunkLength
                && $0.promptTokenOffset == first.promptTokenOffset
                && $0.committedKVTokenCount == first.committedKVTokenCount
                && $0.targetKVTokenCount == first.targetKVTokenCount
                && $0.committedKVTokenCount == $0.promptTokenOffset
                && $0.targetKVTokenCount == $0.promptTokenOffset + chunkLength
        }
    }

    func decode(rows inputs: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        guard !inputs.isEmpty else { return [] }
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        let supportedInputs = inputs.filter(Self.supportsRowSampling)
        var rowFailures = Set(inputs.map(\.requestID)).subtracting(supportedInputs.map(\.requestID))
        guard !supportedInputs.isEmpty else {
            return inputs.map { .rowFailure(requestID: $0.requestID) }
        }

        let decoded: [ContinuousBatchDecodeOutcome] = try await container.perform(nonSendable: supportedInputs) { context, supportedInputs in
            try self.performDecode(
                model: context.model,
                supportedInputs: supportedInputs,
                steps: 1
            )
        }
        for outcome in decoded {
            if case .rowFailure(let requestID) = outcome {
                rowFailures.insert(requestID)
            }
        }
        let byID: [String: ContinuousBatchDecodeOutcome] = Dictionary(
            uniqueKeysWithValues: decoded.map { ($0.requestID, $0) }
        )
        return inputs.map { input in
            if rowFailures.contains(input.requestID) { return .rowFailure(requestID: input.requestID) }
            if let outcome = byID[input.requestID] { return outcome }
            return .rowFailure(requestID: input.requestID)
        }
    }

    /// Lockstep decode of `steps` tokens inside one `container.perform`; each
    /// row samples with its own parameters (`ContinuousBatchRowSampler`).
    /// Returns every sampled token in generation order so the scheduler can
    /// apply stop/stream/receipt without dropping intermediates. The throughput
    /// harness uses the same seam.
    func decodeLockstepWindow(
        rows inputs: [ContinuousBatchDecodeInput],
        steps: Int
    ) async throws -> [ContinuousBatchDecodeOutcome] {
        guard steps >= 1 else { return [] }
        guard !inputs.isEmpty else { return [] }
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        let supportedInputs = inputs.filter(Self.supportsRowSampling)
        var rowFailures = Set(inputs.map(\.requestID)).subtracting(supportedInputs.map(\.requestID))
        guard !supportedInputs.isEmpty else {
            return inputs.map { .rowFailure(requestID: $0.requestID) }
        }
        let decoded: [ContinuousBatchDecodeOutcome] = try await container.perform(nonSendable: supportedInputs) { context, supportedInputs in
            try self.performDecode(
                model: context.model,
                supportedInputs: supportedInputs,
                steps: steps
            )
        }
        for outcome in decoded {
            if case .rowFailure(let requestID) = outcome {
                rowFailures.insert(requestID)
            }
        }
        let byID: [String: ContinuousBatchDecodeOutcome] = Dictionary(
            uniqueKeysWithValues: decoded.map { ($0.requestID, $0) }
        )
        return inputs.map { input in
            if rowFailures.contains(input.requestID) { return .rowFailure(requestID: input.requestID) }
            if let outcome = byID[input.requestID] { return outcome }
            return .rowFailure(requestID: input.requestID)
        }
    }

    func proposeNativeMTPPackedRound(
        rows inputs: [ContinuousBatchNativeMTPProposalInput]
    ) async throws -> [String: [Int]]? {
        guard !inputs.isEmpty else { return [:] }
        guard let drafterContainer else { return nil }
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }

#if DEBUG || MACPROVIDER_LAB_HARNESS
        NativeMTPRoundProfileCollector.synchronizeMLXBoundary()
#endif
        let proposals = try await container.perform(nonSendable: inputs) { (targetContext: ModelContext, inputs: [ContinuousBatchNativeMTPProposalInput]) in
            var proposals: [String: [Int]] = [:]
            var prepared: [(ContinuousBatchNativeMTPProposalInput, MTPPackedVerificationRowState, MTPDrafterState)] = []
            for input in inputs {
#if MACPROVIDER_MLX_PACKED_DRAFTER
                guard input.maximumProposalDepth > 0
                        || input.shouldAdvanceDeferredDrafter
                else {
                    self.removeNativeMTPDeferredDrafterAdvance(for: input.requestID)
                    proposals[input.requestID] = []
                    continue
                }
#else
                guard input.maximumProposalDepth > 0 else {
                    proposals[input.requestID] = []
                    continue
                }
#endif
                guard let targetState = self.nativeMTPTargetState(for: input.requestID),
                      let drafterState = self.nativeMTPDrafterState(for: input.requestID)
                else {
                    proposals[input.requestID] = []
                    continue
                }
                prepared.append((input, targetState, drafterState))
            }
            guard !prepared.isEmpty else { return proposals }
            let proposalResults = try await drafterContainer.perform(
                nonSendable: (prepared, targetContext.model)
            ) { drafterContext, values in
                let (prepared, targetModel) = values
                guard let statefulDrafter = drafterContext.model as? any StatefulMTPDrafterModel else {
                    throw ContinuousBatchSchedulerError.unsupported("native_mtp_stateful_drafter_required")
                }
                let sampler = GenerateParameters(temperature: 0).sampler()
                var results: [(String, Int, MTPDrafterState, MLXArray)] = []
                results.reserveCapacity(prepared.count)
#if MACPROVIDER_MLX_PACKED_DRAFTER
                var deferredRows: [(ContinuousBatchNativeMTPProposalInput, MTPPackedVerificationRowState, MTPDrafterState, NativeMTPDeferredDrafterAdvance)] = []
                for (input, targetState, drafterState) in prepared {
                    guard input.maximumProposalDepth == 0
                            || NativeMTPProposalBounds.fits(
                                maximumProposalDepth: input.maximumProposalDepth,
                                maximumBlockSize: statefulDrafter.maximumBlockSize
                            )
                    else {
                        throw ContinuousBatchSchedulerError.unsupported("native_mtp_proposal_depth_exceeds_drafter")
                    }
                    if let deferred = self.nativeMTPDeferredDrafterAdvance(for: input.requestID) {
                        deferredRows.append((input, targetState, drafterState, deferred))
                        continue
                    }
                    var state = drafterState
                    let draftTokens: MLXArray
                    if let seed = state.seedToken {
                        // Prompt preparation already ran the only initial MTP
                        // forward. Consuming its seed is not a model call.
                        state.seedToken = nil
                        state.seedHidden = nil
                        state.proposalAppended = 0
                        draftTokens = seed
                    } else {
                        throw ContinuousBatchSchedulerError.unsupported(
                            "native_mtp_missing_packed_drafter_proposal"
                        )
                    }
                    results.append((
                        input.requestID,
                        input.maximumProposalDepth,
                        state,
                        draftTokens
                    ))
                }
                if !deferredRows.isEmpty {
                    guard let packedDrafter = drafterContext.model as? any MTPPackedStatefulDrafterModel else {
                        throw ContinuousBatchSchedulerError.unsupported(
                            "native_mtp_packed_stateful_drafter_required"
                        )
                    }
                    let packedOutputs = try packedDrafter.advanceAndProposePacked(
                        target: targetModel,
                        rows: deferredRows.enumerated().map { rowIndex, item in
                            let (_, targetState, state, deferred) = item
                            return MTPPackedDrafterAdvanceRow(
                                rowIndex: rowIndex,
                                targetHidden: targetState.lastHidden,
                                draftTokens: deferred.draftTokens,
                                acceptedCount: deferred.acceptedCount,
                                finalToken: deferred.finalToken,
                                positionDeltas: targetState.positionDeltas,
                                state: state
                            )
                        },
                        sampler: sampler
                    )
                    guard packedOutputs.count == deferredRows.count,
                          Set(packedOutputs.map(\.rowIndex)).count == deferredRows.count,
                          packedOutputs.allSatisfy({ deferredRows.indices.contains($0.rowIndex) })
                    else {
                        throw ContinuousBatchSchedulerError.unsupported(
                            "native_mtp_invalid_packed_drafter_output"
                        )
                    }
                    for output in packedOutputs {
                        let input = deferredRows[output.rowIndex].0
                        results.append((
                            input.requestID,
                            input.maximumProposalDepth,
                            output.state,
                            output.proposal
                        ))
                    }
#if DEBUG || MACPROVIDER_LAB_HARNESS
                    NativeMTPRoundProfileCollector.shared.recordDrafterForward(perRowModelCall: false)
#endif
                }
#else
                for (input, targetState, drafterState) in prepared {
                    let blockSize = input.maximumProposalDepth + 1
                    guard NativeMTPProposalBounds.fits(
                        maximumProposalDepth: input.maximumProposalDepth,
                        maximumBlockSize: statefulDrafter.maximumBlockSize
                    ) else {
                        throw ContinuousBatchSchedulerError.unsupported("native_mtp_proposal_depth_exceeds_drafter")
                    }
                    var state = drafterState
                    let lastToken = MLXArray([Int32(input.currentToken)])
                    let hiddenIndex = max(0, targetState.lastHidden.dim(1) - 1)
                    let lastHidden = targetState.lastHidden[0..., hiddenIndex ..< (hiddenIndex + 1), 0...]
                    let draftTokens = statefulDrafter.draftBlock(
                        target: targetModel,
                        lastToken: lastToken,
                        lastHidden: lastHidden,
                        sharedKV: targetState.sharedKV,
                        positionDeltas: targetState.positionDeltas,
                        queryOffset: targetState.queryOffset,
                        blockSize: blockSize,
                        state: &state,
                        sampler: sampler
                    )
#if DEBUG || MACPROVIDER_LAB_HARNESS
                    NativeMTPRoundProfileCollector.shared.recordDrafterForward(perRowModelCall: true)
#endif
                    self.rollbackTentativeNativeMTPDrafterWrites(&state)
                    results.append((input.requestID, input.maximumProposalDepth, state, draftTokens))
                }
#endif
                eval(results.flatMap { $0.2.cache }, results.map { $0.3 })
                return results
            }
            for (requestID, maximumProposalDepth, state, draftTokens) in proposalResults {
                self.storeNativeMTPDrafterState(state, for: requestID)
                self.storeNativeMTPDraftTokens(draftTokens, for: requestID)
#if MACPROVIDER_MLX_PACKED_DRAFTER
                self.removeNativeMTPDeferredDrafterAdvance(for: requestID)
#endif
                proposals[requestID] = Array(
                    draftTokens.asArray(Int.self).prefix(maximumProposalDepth)
                )
            }
            return proposals
        }
#if DEBUG || MACPROVIDER_LAB_HARNESS
        NativeMTPRoundProfileCollector.synchronizeMLXBoundary()
#endif
        return proposals
    }

    func verifyNativeMTPPackedRound(
        rows inputs: [ContinuousBatchNativeMTPVerifyInput]
    ) async throws -> [NativeMTPVerifiedRow] {
        guard !inputs.isEmpty else { return [] }
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        guard inputs.allSatisfy({ $0.verifiedInputTokenCount == $0.proposalTokens.count + 1 }) else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_invalid_verification_width")
        }
        guard Set(inputs.map(\.requestID)).count == inputs.count,
              Set(inputs.map(\.packedRowIndex)).count == inputs.count,
              inputs.allSatisfy({ $0.packedRowIndex >= 0 && $0.packedRowIndex < inputs.count })
        else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_duplicate_packed_row")
        }

        clearDecodeSession()
#if DEBUG || MACPROVIDER_LAB_HARNESS
        NativeMTPRoundProfileCollector.synchronizeMLXBoundary()
#endif
        let verified: [NativeMTPVerifiedRow] = try await container.perform(nonSendable: inputs) { context, inputs in
            let rowStates = inputs.map {
                self.rowState(
                    for: $0.requestID,
                    binding: $0.binding,
                    initialOffset: $0.committedKVTokenCount
                )
            }
            let batchedCaches = try self.makeBatchedCaches(
                from: rowStates.map(\.caches),
                nativeMTP: true
            )
            let width = inputs.map(\.verifiedInputTokenCount).max() ?? 1
            let tokenRows = inputs.flatMap { input -> [Int32] in
                let valid = [input.currentToken] + input.proposalTokens
                return valid.map(Int32.init) + Array(repeating: Int32(0), count: width - valid.count)
            }
            let tokens = MLXArray(tokenRows, [inputs.count, width])
            let rowMaps = inputs.map {
                MTPPackedVerificationRowMap(
                    rowIndex: $0.packedRowIndex,
                    queryOffset: $0.committedKVTokenCount,
                    inputCount: $0.verifiedInputTokenCount,
                    proposalCount: $0.proposalTokens.count
                )
            }
            let output = try verifyMTPPackedTargets(
                model: context.model,
                tokens: tokens,
                rowMaps: rowMaps,
                cache: batchedCaches.map(\.cache),
                requireContinuationState: true
            )
            let pendingByRequestID = try Dictionary(
                uniqueKeysWithValues: self.pendingNativeMTPTransactions(
                    from: batchedCaches,
                    inputs: inputs,
                    rows: output.rows
                ).map { ($0.0, $0.1) }
            )
            self.replaceNativeMTPTargetStates(
                requestIDs: inputs.map(\.requestID),
                states: Dictionary(uniqueKeysWithValues: output.rows.map { row in
                    let input = inputs[row.map.rowIndex]
                    return (input.requestID, row.continuationState)
                })
            )
            self.replaceNativeMTPPendingTransactions(
                requestIDs: inputs.map(\.requestID),
                transactions: pendingByRequestID.mapValues { $0 }
            )
            for (index, input) in inputs.enumerated() {
                try self.setRowState(rowStates[index], for: input.requestID, binding: input.binding)
            }
#if DEBUG || MACPROVIDER_LAB_HARNESS
            let parityPackedRoundID = NativeMTPParityTraceCollector.shared.allocatePackedRoundID()
#endif
            return output.rows.map { row in
                let input = inputs[row.map.rowIndex]
                let targetTopTokenIDs = Self.topTokenIDs(
                    proposalLogits: row.proposalLogits,
                    bonusLogits: row.bonusLogits
                )
#if DEBUG || MACPROVIDER_LAB_HARNESS
                var traceLogits: [MLXArray] = []
                traceLogits.reserveCapacity(row.map.proposalCount + 1)
                for index in 0 ..< row.map.proposalCount {
                    traceLogits.append(row.proposalLogits[index ..< index + 1, 0...])
                }
                traceLogits.append(row.bonusLogits)
                eval(traceLogits)
                NativeMTPParityTraceCollector.shared.stageVerification(
                    requestID: input.requestID,
                    packedRoundID: parityPackedRoundID,
                    targetLogits: traceLogits,
                    targetArgmaxes: targetTopTokenIDs
                )
#endif
                return NativeMTPVerifiedRow(
                    schedulerRowID: input.requestID,
                    packedRowIndex: input.packedRowIndex,
                    proposedTokenIDs: input.proposalTokens,
                    targetTopTokenIDs: targetTopTokenIDs
                )
            }
        }
#if DEBUG || MACPROVIDER_LAB_HARNESS
        NativeMTPRoundProfileCollector.synchronizeMLXBoundary()
#endif
        return verified.sorted { $0.packedRowIndex < $1.packedRowIndex }
    }

    func finalizeNativeMTPPackedRound(rows inputs: [ContinuousBatchNativeMTPFinalizeInput]) async throws {
        guard !inputs.isEmpty else { return }
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
#if DEBUG || MACPROVIDER_LAB_HARNESS
        NativeMTPRoundProfileCollector.synchronizeMLXBoundary()
#endif
        try await container.perform(nonSendable: inputs) { context, inputs in
            if inputs.allSatisfy({ !$0.shouldCommit }) {
                let transactions = self.consumeAvailableNativeMTPPendingTransactions(for: inputs)
                if !transactions.isEmpty {
                    let presentInputs = inputs.filter { transactions[$0.requestID] != nil }
                    try self.validateNativeMTPFinalizeInputs(
                        presentInputs,
                        transactions: transactions)
                }
                for input in inputs {
                    self.rollbackNativeMTPDrafterState(for: input.requestID)
                }
                return
            }
            let transactions = try self.consumeNativeMTPPendingTransactions(for: inputs)
            let byRequestID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.requestID, $0) })
            try self.validateNativeMTPFinalizeInputs(inputs, transactions: transactions)
            var drafterCommits: [(ContinuousBatchNativeMTPFinalizeInput, NativeMTPPendingTransaction)] = []
            for (requestID, transaction) in transactions {
                guard let input = byRequestID[requestID] else { continue }
                guard input.shouldCommit else {
                    self.rollbackNativeMTPDrafterState(for: requestID)
                    continue
                }
                drafterCommits.append((input, transaction))
                self.invalidateDecodeSession(containing: requestID)
            }
            try await self.commitNativeMTPTransactions(
                targetModel: context.model,
                commits: drafterCommits
            )
        }
#if DEBUG || MACPROVIDER_LAB_HARNESS
        NativeMTPRoundProfileCollector.synchronizeMLXBoundary()
#endif
    }

    func finish(requestID: String) {
        invalidateDecodeSession(containing: requestID)
        removeNativeMTPPendingTransaction(for: requestID)
        removeNativeMTPRowState(for: requestID)
        removeRowState(for: requestID, discardRecordedCache: false)
    }

    func installRetainedPagedKVCache(
        requestID: String,
        handoff: PagedKVPagedCacheHandoff,
        binding: PagedKVStorageBinding,
        recurrentCheckpoint: RecurrentStateCheckpoint?
    ) async throws {
        let unavailable = ContinuousBatchSchedulerError.unsupported("continuous_batching_retained_hybrid_cache_unavailable")
        guard cacheKinds.contains(.recurrentMamba) else {
            guard recurrentCheckpoint == nil else { throw unavailable }
            let state = RowState(caches: handoff.caches, state: nil)
            try setRowState(state, for: requestID, binding: binding)
            return
        }
        // SPEC-038 AC-26 hybrid cached turn: attention layers come from the
        // handoff, recurrent layers from the checkpoint taken at exactly the
        // handoff length. Never a zero recurrent state.
        guard let recurrentCheckpoint,
              recurrentCheckpoint.tokenCount == handoff.logicalTokenCount
        else {
            throw unavailable
        }
        // Validate every recurrent layer's state shape before anything is
        // installed, so a malformed checkpoint fails admission (which releases
        // the reattached blocks) instead of resuming prefill on invalid state.
        let recurrentIndices = cacheKinds.indices.filter { cacheKinds[$0] == .recurrentMamba }
        let layouts = recurrentCheckpoint.states.mapValues { slots in
            slots.map { RecurrentStateSlotLayout(shape: $0.shape, dtype: $0.dtype) }
        }
        guard Self.recurrentCheckpointLayoutIsValid(layouts, recurrentLayerIndices: recurrentIndices) else {
            throw unavailable
        }
        var attention = handoff.caches.makeIterator()
        var caches: [KVCache] = []
        for (index, kind) in cacheKinds.enumerated() {
            switch kind {
            case .pagedAttention:
                guard let cache = attention.next() else { throw unavailable }
                caches.append(cache)
            case .recurrentMamba:
                guard let state = recurrentCheckpoint.states[index], !state.isEmpty else { throw unavailable }
                let cache = MambaCache()
                cache.state = state
                caches.append(cache)
            }
        }
        guard attention.next() == nil else { throw unavailable }
        try setRowState(RowState(caches: caches, state: nil), for: requestID, binding: binding)
    }

    func commitTerminalKV(_ input: ContinuousBatchTerminalKVCommitInput) async throws {
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        try await container.perform(nonSendable: input) { context, input in
            var state = self.rowState(
                for: input.requestID,
                binding: input.binding,
                initialOffset: input.committedKVTokenCount
            )
            let tokenInput = MLXArray([Int32(input.currentToken)]).reshaped([1, 1])
            let text = LMInput.Text(tokens: tokenInput)
            let output = withPreparedCache(state.caches, lengths: text.sequenceLengths) {
                context.model(text, cache: state.caches, state: state.state)
            }
            eval(output.logits)
            state.state = output.state
            try self.setRowState(state, for: input.requestID, binding: input.binding)
            self.invalidateDecodeSession(containing: input.requestID)
        }
    }

    func snapshotRecurrentState(requestID: String, tokenCount: Int) async -> RecurrentStateCheckpoint? {
        guard cacheKinds.contains(.recurrentMamba), beginOperation() else { return nil }
        defer { endOperation() }
        return await container.perform { _ in
            let row = self.existingRowState(for: requestID)
            guard let row else { return nil }
            var states: [Int: [MLXArray]] = [:]
            for (index, kind) in self.cacheKinds.enumerated() where kind == .recurrentMamba {
                guard row.caches.indices.contains(index) else { return nil }
                let state = row.caches[index].state
                guard !state.isEmpty else { return nil }
                states[index] = state
            }
            eval(states.values.flatMap { $0 })
            return RecurrentStateCheckpoint(tokenCount: tokenCount, states: states)
        }
    }

    /// Reuses the FR-PKV10 materialize path on a throwaway bridge that records
    /// only this row's paged caches, so nothing outlives the call.
    func materializeSerialConversationCache(
        requestID: String,
        binding: PagedKVStorageBinding,
        tokenCount: Int,
        recurrentCheckpoints: [RecurrentStateCheckpoint]
    ) async throws -> ContinuousBatchSerialConversationCache? {
        guard cacheKinds.contains(.recurrentMamba), !recurrentCheckpoints.isEmpty else { return nil }
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        return try await container.perform { _ in
            self.invalidateDecodeSession(containing: requestID)
            let row = self.existingRowState(for: requestID)
            guard let row, row.caches.count == self.cacheKinds.count else { return nil }
            let bridge = PagedKVRuntimeContiguousCacheBridge()
            try bridge.record(caches: Self.pagedAttentionCaches(in: row.caches), binding: binding)
            var handoff = try bridge.materializeContiguousKVCache(handle: binding.handle, table: binding.currentTable)
            try handoff.trim(toLogicalTokens: tokenCount)
            var attention = handoff.caches.makeIterator()
            var layers: [KVCache] = []
            for kind in self.cacheKinds {
                switch kind {
                case .pagedAttention:
                    guard let cache = attention.next() else {
                        throw PagedKVContiguousCacheBridgeError.blockTableMismatch
                    }
                    layers.append(cache)
                case .recurrentMamba:
                    layers.append(MambaCache())
                }
            }
            return ContinuousBatchSerialConversationCache(
                layers: layers,
                recurrentCheckpoints: recurrentCheckpoints,
                tokenCount: tokenCount
            )
        }
    }

    func cancelInFlight() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            cancelRequested = true
            decodeSession = nil
            let handlesToDiscard = rows.compactMap { Self.pagedAttentionCaches(in: $0.value.caches).first?.binding.handle }
            rows.removeAll()
            nativeMTPPendingTransactions.removeAll()
            nativeMTPTargetStates.removeAll()
            nativeMTPDrafterStates.removeAll()
            nativeMTPDraftTokens.removeAll()
#if MACPROVIDER_MLX_PACKED_DRAFTER
            nativeMTPDeferredDrafterAdvances.removeAll()
#endif
            if activeOperations == 0 {
                lock.unlock()
                handlesToDiscard.forEach { contiguousCacheBridge?.discardContiguousCache(handle: $0) }
                continuation.resume()
            } else {
                cancellationWaiters.append(continuation)
                lock.unlock()
                handlesToDiscard.forEach { contiguousCacheBridge?.discardContiguousCache(handle: $0) }
            }
        }
    }

    private func beginOperation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelRequested else { return false }
        activeOperations += 1
        return true
    }

    private func endOperation() {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        activeOperations = max(0, activeOperations - 1)
        if cancelRequested && activeOperations == 0 {
            waiters = cancellationWaiters
            cancellationWaiters.removeAll()
        } else {
            waiters = []
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func rowState(
        for requestID: String,
        binding: PagedKVStorageBinding,
        initialOffset: Int
    ) -> RowState {
        lock.lock()
        defer { lock.unlock() }
        if let existing = rows[requestID] {
            return existing
        }
        return RowState(
            caches: cacheKinds.map { kind in
                switch kind {
                case .pagedAttention:
                    PagedKVCache(
                        blockSizeTokens: blockSizeTokens,
                        maxPhysicalBlocks: maxPhysicalBlocks,
                        poolEpoch: poolEpoch,
                        binding: binding,
                        initialOffset: initialOffset,
                        reconstructViaGather: false
                    )
                case .recurrentMamba:
                    MambaCache()
                }
            },
            state: nil
        )
    }

    private func existingRowState(for requestID: String) -> RowState? {
        lock.lock()
        defer { lock.unlock() }
        return rows[requestID]
    }

    private func setRowState(
        _ state: RowState,
        for requestID: String,
        binding: PagedKVStorageBinding
    ) throws {
        lock.lock()
        let cancelledBeforeRecord = cancelRequested
        lock.unlock()
        guard !cancelledBeforeRecord else {
            contiguousCacheBridge?.discardContiguousCache(handle: binding.handle)
            return
        }
        try contiguousCacheBridge?.record(caches: Self.pagedAttentionCaches(in: state.caches), binding: binding)
        lock.lock()
        if !cancelRequested {
            rows[requestID] = state
            lock.unlock()
        } else {
            lock.unlock()
            contiguousCacheBridge?.discardContiguousCache(handle: binding.handle)
        }
    }

    private func removeRowState(for requestID: String, discardRecordedCache: Bool = true) {
        lock.lock()
        let removed = rows.removeValue(forKey: requestID)
        lock.unlock()
        if discardRecordedCache, let handle = removed.flatMap({ Self.pagedAttentionCaches(in: $0.caches).first?.binding.handle }) {
            contiguousCacheBridge?.discard(handle: handle)
        }
    }

    private func performDecode(
        model: any LanguageModel,
        supportedInputs: [ContinuousBatchDecodeInput],
        steps: Int
    ) throws -> [ContinuousBatchDecodeOutcome] {
#if DEBUG || MACPROVIDER_LAB_HARNESS
        NativeMTPRoundProfileCollector.synchronizeMLXBoundary()
#endif
        let decodeSteps = max(1, steps)
        var rowStates = supportedInputs.map {
            self.rowState(
                for: $0.requestID,
                binding: $0.binding,
                initialOffset: $0.committedKVTokenCount
            )
        }
        if supportedInputs.count > 1 && rowStates.contains(where: { $0.state != nil }) {
            return supportedInputs.map { ContinuousBatchDecodeOutcome.rowFailure(requestID: $0.requestID) }
        }

        let requestIDs = supportedInputs.map(\.requestID)
        var session = copyDecodeSession()
        let batchedCaches: [PagedKVSharedLayerBatch]
        if let existing = session, existing.requestIDs == requestIDs {
            batchedCaches = existing.batchedCaches
        } else {
            session?.batchedCaches.forEach { $0.syncRowsFromBatch() }
            batchedCaches = try makeBatchedCaches(from: rowStates.map(\.caches))
            session = DecodeSession(
                requestIDs: requestIDs,
                batchedCaches: batchedCaches,
                compiledCaches: [],
                compiledStep: nil
            )
        }
        let cachesAsKV = batchedCaches.map(\.cache)
        let canCompile = compiledDecode
            && cacheKinds.allSatisfy({ $0 == .pagedAttention })
            && rowStates.allSatisfy({ $0.state == nil })
            && cachesAsKV.allSatisfy { !$0.innerState().isEmpty }

        let sampledByRow: [[Int]]
        if canCompile {
            var compiledCaches: [KVCache]
            let step: CompiledDecodeStep
            if let existingStep = session?.compiledStep,
               let existing = session?.compiledCaches,
               existing.count == batchedCaches.count,
               !existing.isEmpty
            {
                compiledCaches = existing
                step = existingStep
            } else {
                compiledCaches = try model.newCache(parameters: nil)
                guard compiledCaches.count == batchedCaches.count else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
                }
                for index in compiledCaches.indices {
                    let packed = batchedCaches[index].innerState()
                    if packed.count == 2 {
                        compiledCaches[index].state = packed
                    }
                }
                eval(compiledCaches)
                step = CompiledDecodeStep(model: model, cache: compiledCaches, enabled: true)
                session?.compiledCaches = compiledCaches
                session?.compiledStep = step
            }
            var current = MLXArray(supportedInputs.map { Int32($0.currentToken) }).reshaped([supportedInputs.count, 1])
            eval(current)
            var collected: [[Int]] = supportedInputs.map { _ in [] }
            for stepIndex in 0 ..< decodeSteps {
                let logits = step.step(current)
                current = ContinuousBatchRowSampler.sample(
                    logits: logits[0..., -1, 0...],
                    rows: Self.samplerRows(supportedInputs, step: stepIndex)
                ).reshaped([supportedInputs.count, 1])
                eval(current)
                let stepTokens = current.asArray(Int.self)
                guard stepTokens.count == supportedInputs.count else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_logits_shape")
                }
                for index in supportedInputs.indices {
                    collected[index].append(stepTokens[index])
                }
            }
            Stream().synchronize()
            sampledByRow = collected
            let targets = supportedInputs.map(\.targetKVTokenCount)
            for index in compiledCaches.indices {
                try batchedCaches[index].writebackCompiledInnerState(
                    compiledCaches[index].innerState(),
                    targets: targets
                )
            }
        } else {
            session?.compiledStep = nil
            var currentTokens = supportedInputs.map(\.currentToken)
            var collected: [[Int]] = supportedInputs.map { _ in [] }
            for stepIndex in 0 ..< decodeSteps {
                let tokenInput = MLXArray(currentTokens.map(Int32.init)).reshaped([supportedInputs.count, 1])
                let text = LMInput.Text(tokens: tokenInput)
                let output = withPreparedCache(cachesAsKV, lengths: text.sequenceLengths) {
                    model(text, cache: cachesAsKV, state: supportedInputs.count == 1 ? rowStates[0].state : nil)
                }
                try batchedCaches.forEach { try $0.validateBatchState() }
                let stepSampled = ContinuousBatchRowSampler.sample(
                    logits: output.logits[0..., -1, 0...],
                    rows: Self.samplerRows(supportedInputs, step: stepIndex)
                ).asArray(Int.self)
                guard stepSampled.count == supportedInputs.count else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_logits_shape")
                }
                if supportedInputs.count == 1 {
                    rowStates[0].state = output.state
                } else if output.state != nil {
                    return supportedInputs.map { ContinuousBatchDecodeOutcome.rowFailure(requestID: $0.requestID) }
                }
                for index in supportedInputs.indices {
                    collected[index].append(stepSampled[index])
                }
                currentTokens = stepSampled
            }
            sampledByRow = collected
            batchedCaches.forEach { $0.syncRowsFromBatch() }
        }

        guard sampledByRow.count == supportedInputs.count,
              sampledByRow.allSatisfy({ $0.count == decodeSteps }) else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_logits_shape")
        }
        // Hybrid recurrent decoders (Qwen3.5/Qwen3.8) are exact only when the
        // batched recurrent state is split back to rows at a token boundary.
        // Reusing a packed Mamba batch across windows can carry row-state at the
        // wrong boundary after long prefills, so force the next hybrid window to
        // rebuild from the just-synced row caches. KV-only layouts still keep the
        // reusable session that amortizes contiguous compiled decode.
        storeDecodeSession(cacheKinds.contains(.recurrentMamba) ? nil : session)
        for (index, input) in supportedInputs.enumerated() {
            try self.setRowState(rowStates[index], for: input.requestID, binding: input.binding)
        }
        let outcomes = zip(supportedInputs, sampledByRow).map { input, tokens in
            ContinuousBatchDecodeOutcome.output(ContinuousBatchDecodeOutput(
                requestID: input.requestID,
                tokens: tokens
            ))
        }
#if DEBUG || MACPROVIDER_LAB_HARNESS
        NativeMTPRoundProfileCollector.synchronizeMLXBoundary()
#endif
        return outcomes
    }

    private func copyDecodeSession() -> DecodeSession? {
        lock.lock()
        defer { lock.unlock() }
        return decodeSession
    }

    private static func topTokenIDs(proposalLogits: MLXArray, bonusLogits: MLXArray) -> [Int] {
        var ids: [Int] = []
        if proposalLogits.ndim == 2, proposalLogits.dim(0) > 0 {
            ids.append(contentsOf: argMax(proposalLogits, axis: -1).asArray(Int.self))
        }
        ids.append(contentsOf: argMax(bonusLogits, axis: -1).asArray(Int.self))
        return ids
    }

    private func nativeMTPTargetState(for requestID: String) -> MTPPackedVerificationRowState? {
        lock.lock()
        defer { lock.unlock() }
        return nativeMTPTargetStates[requestID]
    }

    private func nativeMTPDrafterState(for requestID: String) -> MTPDrafterState? {
        lock.lock()
        defer { lock.unlock() }
        return nativeMTPDrafterStates[requestID]
    }

    private func storeNativeMTPDrafterState(_ state: MTPDrafterState, for requestID: String) {
        lock.lock()
        nativeMTPDrafterStates[requestID] = state
        lock.unlock()
    }

    private func storeNativeMTPDraftTokens(_ tokens: MLXArray, for requestID: String) {
        lock.lock()
        nativeMTPDraftTokens[requestID] = tokens
        lock.unlock()
    }

    private func consumeNativeMTPDraftTokens(for requestID: String) -> MLXArray? {
        lock.lock()
        defer { lock.unlock() }
        return nativeMTPDraftTokens.removeValue(forKey: requestID)
    }

#if MACPROVIDER_MLX_PACKED_DRAFTER
    private func nativeMTPDeferredDrafterAdvance(
        for requestID: String
    ) -> NativeMTPDeferredDrafterAdvance? {
        lock.lock()
        defer { lock.unlock() }
        return nativeMTPDeferredDrafterAdvances[requestID]
    }

    private func storeNativeMTPDeferredDrafterAdvance(
        _ advance: NativeMTPDeferredDrafterAdvance,
        for requestID: String
    ) {
        lock.lock()
        nativeMTPDeferredDrafterAdvances[requestID] = advance
        lock.unlock()
    }

    private func removeNativeMTPDeferredDrafterAdvance(for requestID: String) {
        lock.lock()
        nativeMTPDeferredDrafterAdvances.removeValue(forKey: requestID)
        lock.unlock()
    }
#endif

    private func replaceNativeMTPTargetStates(
        requestIDs: [String],
        states: [String: MTPPackedVerificationRowState?]
    ) {
        lock.lock()
        for requestID in requestIDs {
            nativeMTPTargetStates[requestID] = states[requestID] ?? nil
        }
        lock.unlock()
    }

    private func rollbackTentativeNativeMTPDrafterWrites(_ state: inout MTPDrafterState) {
        guard state.proposalAppended > 0 else { return }
        let trimmed = trimPromptCache(state.cache, numTokens: state.proposalAppended)
        state.nextPosition = max(0, state.nextPosition - trimmed)
        state.proposalAppended = 0
    }

    private func rollbackNativeMTPDrafterState(for requestID: String) {
        lock.lock()
        var state = nativeMTPDrafterStates[requestID]
        nativeMTPDraftTokens.removeValue(forKey: requestID)
#if MACPROVIDER_MLX_PACKED_DRAFTER
        nativeMTPDeferredDrafterAdvances.removeValue(forKey: requestID)
#endif
        lock.unlock()
        guard var state else { return }
        rollbackTentativeNativeMTPDrafterWrites(&state)
        storeNativeMTPDrafterState(state, for: requestID)
    }

    private func prepareNativeMTPDrafterState(
        targetModel: any LanguageModel,
        prompt: MLXArray,
        output: LMOutput,
        firstBonusToken: Int,
        requestID: String
    ) async throws {
        guard let drafterContainer else { return }
        guard let targetHidden = output.state?[mtpLastHiddenStatesKey] else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_prompt_hidden_state")
        }
        guard targetHidden.ndim == 3,
              targetHidden.dim(0) == 1,
              targetHidden.dim(1) >= prompt.dim(1)
        else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_invalid_prompt_hidden_state")
        }
        let state = try await drafterContainer.perform(
            nonSendable: (targetModel, prompt, targetHidden, firstBonusToken, output.state)
        ) { drafterContext, values in
            let (targetModel, prompt, targetHidden, firstBonusToken, outputState) = values
            guard let statefulDrafter = drafterContext.model as? any StatefulMTPDrafterModel else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_stateful_drafter_required")
            }
            let sampler = GenerateParameters(temperature: 0).sampler()
            var state = statefulDrafter.makeState(parameters: nil)
            statefulDrafter.prepareDrafterState(
                target: targetModel,
                promptTokens: prompt,
                targetHidden: targetHidden,
                firstBonus: MLXArray([Int32(firstBonusToken)]),
                positionDeltas: outputState?[mtpPositionDeltasKey],
                state: &state,
                sampler: sampler
            )
            eval(state.cache)
            return state
        }
        storeNativeMTPDrafterState(state, for: requestID)
    }

    private func commitNativeMTPTransactions(
        targetModel: any LanguageModel,
        commits: [(ContinuousBatchNativeMTPFinalizeInput, NativeMTPPendingTransaction)]
    ) async throws {
        guard !commits.isEmpty else { return }
        guard let drafterContainer else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_drafter_unavailable")
        }
        let commitResult = try await drafterContainer.perform(
            nonSendable: (commits, targetModel)
        ) { drafterContext, values in
            let (commits, targetModel) = values
            guard let statefulDrafter = drafterContext.model as? any StatefulMTPDrafterModel else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_stateful_drafter_required")
            }
            let sampler = GenerateParameters(temperature: 0).sampler()
            var prepared: [(ContinuousBatchNativeMTPFinalizeInput, NativeMTPPendingTransaction, MTPDrafterState)] = []
            prepared.reserveCapacity(commits.count)
            for (input, transaction) in commits {
                guard input.acceptedTokenIDs.last != nil else {
                    throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_final_token")
                }
                guard let state = self.nativeMTPDrafterState(for: input.requestID) else {
                    throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_drafter_state")
                }
                guard transaction.targetState.lastHidden.ndim >= 2,
                      transaction.targetState.lastHidden.dim(-2) > input.committedProposalTokenCount,
                      input.committedProposalTokenCount == 0
                        || (transaction.draftTokens?.dim(-1) ?? 0) >= input.committedProposalTokenCount
                else {
                    throw ContinuousBatchSchedulerError.unsupported("native_mtp_invalid_drafter_commit_state")
                }
                for layer in transaction.layers {
                    try layer.validateCommit(inputCount: input.committedInputTokenCount)
                }
                prepared.append((input, transaction, state))
            }

            // No row-owned cache is mutated until every row/layer/drafter
            // precondition above has passed. From here, commit operations are
            // non-failing for the validated inputs, preserving R006's atomic
            // batch failure boundary.
            var states: [String: MTPDrafterState] = [:]
#if MACPROVIDER_MLX_PACKED_DRAFTER
            var deferredAdvances: [String: NativeMTPDeferredDrafterAdvance] = [:]
#else
            var deferredAdvances: [String: MLXArray] = [:]
#endif
            var dirtyArrays: [MLXArray] = []
#if MACPROVIDER_MLX_PACKED_DRAFTER
            for (input, transaction, _) in prepared {
                guard input.retainDrafterTransition else {
                    self.removeNativeMTPDeferredDrafterAdvance(for: input.requestID)
                    continue
                }
                deferredAdvances[input.requestID] = NativeMTPDeferredDrafterAdvance(
                    draftTokens: transaction.draftTokens
                        ?? MLXArray([Int32](), [1, 0]),
                    acceptedCount: input.committedProposalTokenCount,
                    finalToken: input.acceptedTokenIDs.last!
                )
            }
#endif
            for (input, transaction, initialState) in prepared {
                for layer in transaction.layers {
                    dirtyArrays.append(contentsOf: try layer.commit(
                        inputCount: input.committedInputTokenCount
                    ))
                }
#if !MACPROVIDER_MLX_PACKED_DRAFTER
                var state = initialState
                let draftTokens = transaction.draftTokens
                    ?? MLXArray([Int32](), [1, 0])
                statefulDrafter.commitDrafterState(
                    target: targetModel,
                    targetHidden: transaction.targetState.lastHidden,
                    draftTokens: draftTokens,
                    acceptedCount: input.committedProposalTokenCount,
                    finalToken: MLXArray([Int32(input.acceptedTokenIDs.last!)]),
                    positionDeltas: transaction.targetState.positionDeltas,
                    state: &state,
                    sampler: sampler
                )
#if DEBUG || MACPROVIDER_LAB_HARNESS
                NativeMTPRoundProfileCollector.shared.recordDrafterForward(perRowModelCall: true)
#endif
                states[input.requestID] = state
#endif
            }
#if !MACPROVIDER_MLX_PACKED_DRAFTER
            dirtyArrays.append(contentsOf: states.values.flatMap(\.cache))
#endif
            if !dirtyArrays.isEmpty {
                eval(dirtyArrays)
            }
            return (states, deferredAdvances)
        }
        for (requestID, state) in commitResult.0 {
            storeNativeMTPDrafterState(state, for: requestID)
        }
#if MACPROVIDER_MLX_PACKED_DRAFTER
        for (requestID, advance) in commitResult.1 {
            storeNativeMTPDeferredDrafterAdvance(advance, for: requestID)
        }
#endif
    }

    private func pendingNativeMTPTransactions(
        from batchedCaches: [PagedKVSharedLayerBatch],
        inputs: [ContinuousBatchNativeMTPVerifyInput],
        rows: [MTPPackedVerificationRowOutput]
    ) throws -> [(String, NativeMTPPendingTransaction)] {
        let layerResolutions = try batchedCaches.map { try $0.pendingMTPResolutions() }
        guard layerResolutions.allSatisfy({ $0.count == inputs.count }) else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_missing_staged_state")
        }
        let continuationByPackedRow = Dictionary(uniqueKeysWithValues: rows.map { ($0.map.rowIndex, $0.continuationState) })
        return try inputs.enumerated().map { packedIndex, input in
            guard let continuationState = continuationByPackedRow[packedIndex] ?? nil else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_continuation_state")
            }
            let layers = try layerResolutions.map { resolutions in
                let resolution = resolutions[packedIndex]
                guard resolution.proposalTokenCount == input.proposalTokens.count,
                      resolution.inputTokenCount == input.verifiedInputTokenCount
                else {
                    throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_staged_state_mismatch")
                }
                return resolution
            }
            return (
                input.requestID,
                NativeMTPPendingTransaction(
                    proposalTokenCount: input.proposalTokens.count,
                    currentToken: input.currentToken,
                    targetState: continuationState,
                    draftTokens: self.consumeNativeMTPDraftTokens(for: input.requestID),
                    layers: layers
                )
            )
        }
    }

    private func replaceNativeMTPPendingTransactions(
        requestIDs: [String],
        transactions: [String: NativeMTPPendingTransaction]
    ) {
        lock.lock()
        for requestID in requestIDs {
            nativeMTPPendingTransactions[requestID] = transactions[requestID]
        }
        lock.unlock()
    }

    private func consumeNativeMTPPendingTransactions(
        for inputs: [ContinuousBatchNativeMTPFinalizeInput]
    ) throws -> [String: NativeMTPPendingTransaction] {
        lock.lock()
        defer { lock.unlock() }
        var consumed: [String: NativeMTPPendingTransaction] = [:]
        for input in inputs {
            guard let transaction = nativeMTPPendingTransactions.removeValue(forKey: input.requestID) else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_pending_transaction")
            }
            consumed[input.requestID] = transaction
        }
        return consumed
    }

    /// Verification can fail before pending target transactions are installed.
    /// A subsequent all-abort cleanup must still be idempotent: row caches were
    /// never mutated, while tentative drafter state still needs rollback.
    private func consumeAvailableNativeMTPPendingTransactions(
        for inputs: [ContinuousBatchNativeMTPFinalizeInput]
    ) -> [String: NativeMTPPendingTransaction] {
        lock.lock()
        defer { lock.unlock() }
        var consumed: [String: NativeMTPPendingTransaction] = [:]
        for input in inputs {
            if let transaction = nativeMTPPendingTransactions.removeValue(forKey: input.requestID) {
                consumed[input.requestID] = transaction
            }
        }
        return consumed
    }

    private func removeNativeMTPPendingTransaction(for requestID: String) {
        lock.lock()
        nativeMTPPendingTransactions.removeValue(forKey: requestID)
        lock.unlock()
    }

    private func removeNativeMTPRowState(for requestID: String) {
        lock.lock()
        nativeMTPTargetStates.removeValue(forKey: requestID)
        nativeMTPDrafterStates.removeValue(forKey: requestID)
        nativeMTPDraftTokens.removeValue(forKey: requestID)
#if MACPROVIDER_MLX_PACKED_DRAFTER
        nativeMTPDeferredDrafterAdvances.removeValue(forKey: requestID)
#endif
        lock.unlock()
    }

    private func validateNativeMTPFinalizeInputs(
        _ inputs: [ContinuousBatchNativeMTPFinalizeInput],
        transactions: [String: NativeMTPPendingTransaction]
    ) throws {
        guard Set(inputs.map(\.requestID)).count == inputs.count else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_duplicate_finalize_row")
        }
        for input in inputs {
            guard let transaction = transactions[input.requestID] else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_pending_transaction")
            }
            guard input.proposalTokenCount == transaction.proposalTokenCount,
                  input.committedProposalTokenCount >= 0,
                  input.committedProposalTokenCount <= input.proposalTokenCount
            else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_finalize_proposal_count_mismatch")
            }
            if input.shouldCommit {
                guard input.committedInputTokenCount == input.committedProposalTokenCount + 1 else {
                    throw ContinuousBatchSchedulerError.unsupported("native_mtp_finalize_input_count_mismatch")
                }
                guard !input.acceptedTokenIDs.isEmpty,
                      input.acceptedTokenIDs.count >= input.committedProposalTokenCount
                else {
                    throw ContinuousBatchSchedulerError.unsupported("native_mtp_finalize_accepted_tokens_mismatch")
                }
            } else {
                guard input.committedProposalTokenCount == 0,
                      input.committedInputTokenCount == 0,
                      input.acceptedTokenIDs.isEmpty
                else {
                    throw ContinuousBatchSchedulerError.unsupported("native_mtp_abort_commits_tokens")
                }
            }
        }
    }

    private func storeDecodeSession(_ session: DecodeSession?) {
        lock.lock()
        decodeSession = session
        lock.unlock()
    }

    private func clearDecodeSession() {
        lock.lock()
        let session = decodeSession
        decodeSession = nil
        lock.unlock()
        session?.batchedCaches.forEach { $0.syncRowsFromBatch() }
    }

    private func invalidateDecodeSession(containing requestID: String) {
        lock.lock()
        let session: DecodeSession?
        if decodeSession?.requestIDs.contains(requestID) == true {
            session = decodeSession
            decodeSession = nil
        } else {
            session = nil
        }
        lock.unlock()
        session?.batchedCaches.forEach { $0.syncRowsFromBatch() }
    }

    func retainedRowCountForTest() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rows.count
    }

    func installRowStateForTest(
        caches: [KVCache],
        requestID: String,
        binding: PagedKVStorageBinding
    ) throws {
        try setRowState(RowState(caches: caches, state: nil), for: requestID, binding: binding)
    }

    func lockstepInnerStateNonEmptyForTest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session = decodeSession else { return false }
        return session.batchedCaches.allSatisfy { !$0.innerState().isEmpty }
    }

    static func validateMTPPackedCacheForTest(
        rowCaches: [PagedKVCache],
        rowMaps: [MTPPackedVerificationRowMap]
    ) throws {
        let cache = PagedKVBatchLayerCache(rowCaches: rowCaches)
        try cache.prepareMTPPackedVerification(rowMaps: rowMaps)
    }

    static func exerciseMTPPackedCacheForTest(
        rowCaches: [PagedKVCache],
        rowMaps: [MTPPackedVerificationRowMap],
        width: Int
    ) throws -> PagedKVMTPPackedCacheExerciseResult {
        try Device.withDefaultDevice(.cpu) {
            let cache = PagedKVBatchLayerCache(rowCaches: rowCaches)
            try cache.prepareMTPPackedVerification(rowMaps: rowMaps)
            let batchOffsets = cache.batchOffset.asArray(Int.self)
            let inputCounts = rowMaps.map(\.inputCount)
            cache.prepare(lengths: inputCounts)
            let mask: MLXArray
            switch cache.makeMask(n: width, windowSize: nil, returnArray: true) {
            case .array(let array):
                mask = array
            default:
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_missing_mask")
            }
            let keys = MLXArray.zeros([rowCaches.count, 1, width, 1], dtype: .float32, stream: .cpu)
            let values = MLXArray.zeros([rowCaches.count, 1, width, 1], dtype: .float32, stream: .cpu)
            let updated = cache.update(keys: keys, values: values)
            let beforeFinalize = cache.innerState().first?.dim(2) ?? 0
            let rowStateCounts = rowCaches.map { row -> Int in
                let state = row.state
                return state.count == 2 ? state[0].dim(2) : 0
            }
            cache.finalize()
            let afterFinalize = cache.innerState().first?.dim(2) ?? 0
            let rowStateCountsAfterFinalize = rowCaches.map { row -> Int in
                let state = row.state
                return state.count == 2 ? state[0].dim(2) : 0
            }
            return PagedKVMTPPackedCacheExerciseResult(
                batchOffsetsBeforeUpdate: batchOffsets,
                returnedKeyShape: updated.0.shape,
                rowOffsetsAfterUpdate: rowCaches.map(\.offset),
                rowStoredTokensAfterUpdate: rowCaches.map(\.storedTokens),
                rowStateTokenCountsAfterUpdate: rowStateCounts,
                batchTokenCountBeforeFinalize: beforeFinalize,
                batchTokenCountAfterFinalize: afterFinalize,
                rowStateTokenCountsAfterFinalize: rowStateCountsAfterFinalize,
                maskShape: mask.shape,
                maskValues: mask.asArray(Bool.self)
            )
        }
    }

    static func exerciseMTPPackedCacheResolutionForTest(
        rowCaches: [PagedKVCache],
        rowMaps: [MTPPackedVerificationRowMap],
        width: Int,
        committedInputCounts: [Int?]
    ) throws -> PagedKVMTPPackedCacheResolutionResult {
        guard committedInputCounts.count == rowMaps.count else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_resolution_count_mismatch")
        }
        return try Device.withDefaultDevice(.cpu) {
            let cache = PagedKVBatchLayerCache(rowCaches: rowCaches)
            try cache.prepareMTPPackedVerification(rowMaps: rowMaps)
            cache.prepare(lengths: rowMaps.map(\.inputCount))
            let keys = MLXArray.zeros([rowCaches.count, 1, width, 1], dtype: .float32, stream: .cpu)
            let values = MLXArray.zeros([rowCaches.count, 1, width, 1], dtype: .float32, stream: .cpu)
            _ = cache.update(keys: keys, values: values)
            let pendingBeforeFinalize = try cache.pendingMTPResolutions()
            let rowStateCountsAfterStaging = rowCaches.map { row -> Int in
                let state = row.state
                return state.count == 2 ? state[0].dim(2) : 0
            }
            let rowOffsetsAfterStaging = rowCaches.map(\.offset)
            let rowStoredTokensAfterStaging = rowCaches.map(\.storedTokens)
            cache.finalize()
            let pendingAfterFinalize = try cache.pendingMTPResolutions()
            for (index, inputCount) in committedInputCounts.enumerated() {
                guard let inputCount else { continue }
                try pendingAfterFinalize[index].commit(inputCount: inputCount)
            }
            return PagedKVMTPPackedCacheResolutionResult(
                rowOffsetsAfterStaging: rowOffsetsAfterStaging,
                rowStoredTokensAfterStaging: rowStoredTokensAfterStaging,
                rowStateTokenCountsAfterStaging: rowStateCountsAfterStaging,
                pendingInputCountsBeforeFinalize: pendingBeforeFinalize.map(\.inputTokenCount),
                pendingProposalCountsBeforeFinalize: pendingBeforeFinalize.map(\.proposalTokenCount),
                pendingInputCountsAfterFacadeFinalize: pendingAfterFinalize.map(\.inputTokenCount),
                pendingProposalCountsAfterFacadeFinalize: pendingAfterFinalize.map(\.proposalTokenCount),
                rowOffsetsAfterResolution: rowCaches.map(\.offset),
                rowStoredTokensAfterResolution: rowCaches.map(\.storedTokens),
                rowStateTokenCountsAfterResolution: rowCaches.map { row -> Int in
                    let state = row.state
                    return state.count == 2 ? state[0].dim(2) : 0
                }
            )
        }
    }

    private static func supportsRowSampling(_ input: ContinuousBatchDecodeInput) -> Bool {
        ContinuousBatchRowSampler.supports(temperature: input.temperature, topP: input.topP)
    }

    private static func samplerRow(_ input: ContinuousBatchPrefillInput) -> ContinuousBatchRowSampler.Row {
        ContinuousBatchRowSampler.Row(
            temperature: input.temperature,
            topP: input.topP,
            samplerSeed: input.samplerSeed,
            samplerStep: input.samplerStep
        )
    }

    private static func samplerRows(
        _ inputs: [ContinuousBatchDecodeInput],
        step: Int
    ) -> [ContinuousBatchRowSampler.Row] {
        inputs.map {
            ContinuousBatchRowSampler.Row(
                temperature: $0.temperature,
                topP: $0.topP,
                samplerSeed: $0.samplerSeed,
                samplerStep: $0.samplerStep + step
            )
        }
    }

    private func makeBatchedCaches(
        from rowCaches: [[KVCache]],
        nativeMTP: Bool = false
    ) throws -> [PagedKVSharedLayerBatch] {
        guard let layerCount = rowCaches.first?.count,
              rowCaches.allSatisfy({ $0.count == layerCount }),
              layerCount == cacheKinds.count
        else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
        }
        return try (0 ..< layerCount).map { layerIndex in
            switch cacheKinds[layerIndex] {
            case .pagedAttention:
                let rows = rowCaches.compactMap { $0[layerIndex] as? PagedKVCache }
                guard rows.count == rowCaches.count else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
                }
                let cache = PagedKVBatchLayerCache(rowCaches: rows)
                return PagedKVSharedLayerBatch(
                    cache: cache,
                    validateBatchStateClosure: {},
                    syncRowsFromBatchClosure: { cache.syncRowsFromBatch() },
                    writebackCompiledInnerStateClosure: { compiledState, targets in
                        try cache.writebackCompiledInnerState(compiledState, targets: targets)
                    },
                    pendingMTPResolutionsClosure: {
                        try cache.pendingMTPResolutions().map {
                            NativeMTPPendingLayerResolution.pagedAttention($0)
                        }
                    }
                )
            case .recurrentMamba:
                let rows = rowCaches.compactMap { $0[layerIndex] as? MambaCache }
                guard rows.count == rowCaches.count else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
                }
                guard nativeMTP else {
                    let cache = MambaCache()
                    try Self.packMambaRows(rows, into: cache)
                    return PagedKVSharedLayerBatch(
                        cache: cache,
                        validateBatchStateClosure: {
                            guard cache.state.count == 2,
                                  cache.state.allSatisfy({ $0.ndim >= 1 && $0.dim(0) == rows.count })
                            else {
                                throw ContinuousBatchSchedulerError.unsupported(
                                    "continuous_batching_invalid_mamba_state"
                                )
                            }
                        },
                        syncRowsFromBatchClosure: { Self.syncMambaRows(from: cache, into: rows) },
                        writebackCompiledInnerStateClosure: { compiledState, targets in
                            guard targets.count == rows.count else {
                                throw ContinuousBatchSchedulerError.unsupported(
                                    "continuous_batching_invalid_cache_layout"
                                )
                            }
                            cache.state = compiledState
                            Self.syncMambaRows(from: cache, into: rows)
                            try Self.packMambaRows(rows, into: cache)
                        },
                        pendingMTPResolutionsClosure: {
                            throw ContinuousBatchSchedulerError.unsupported(
                                "native_mtp_missing_recurrent_transaction"
                            )
                        }
                    )
                }
                let cache = try MTPPackedMambaBatchCache(rowCaches: rows)
                return PagedKVSharedLayerBatch(
                    cache: cache,
                    validateBatchStateClosure: {
                        guard cache.state.count == 2,
                              cache.state.allSatisfy({ $0.ndim >= 1 && $0.dim(0) == rows.count })
                        else {
                            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_mamba_state")
                        }
                    },
                    syncRowsFromBatchClosure: { Self.syncMambaRows(from: cache, into: rows) },
                    writebackCompiledInnerStateClosure: { compiledState, targets in
                        guard targets.count == rows.count else {
                            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
                        }
                        cache.state = compiledState
                        Self.syncMambaRows(from: cache, into: rows)
                        try Self.packMambaRows(rows, into: cache)
                    },
                    pendingMTPResolutionsClosure: {
                        try cache.rowTransactions().map {
                            NativeMTPPendingLayerResolution.recurrent($0)
                        }
                    }
                )
            }
        }
    }

    private static func pagedAttentionCaches(in caches: [KVCache]) -> [PagedKVCache] {
        caches.compactMap { $0 as? PagedKVCache }
    }

    private static func packMambaRows(_ rows: [MambaCache], into batch: MambaCache) throws {
        let rowStates = rows.map(\.state)
        let slotCount = rowStates.map(\.count).max() ?? 0
        guard slotCount > 0 else { return }
        for slot in 0 ..< slotCount {
            guard let first = rowStates.first(where: { $0.indices.contains(slot) })?[slot] else {
                throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
            }
            // A one-token joining row has not run prefill, so its recurrent
            // slots are empty. Qwen35 initializes those slots with zeros.
            let slotArrays = rowStates.map { states in
                states.indices.contains(slot)
                    ? states[slot]
                    : MLXArray.zeros(first.shape, dtype: first.dtype)
            }
            guard slotArrays.allSatisfy({
                      $0.ndim >= 1
                          && $0.dim(0) == 1
                          && Array($0.shape.dropFirst()) == Array(first.shape.dropFirst())
                          && $0.dtype == first.dtype
                  })
            else {
                throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
            }
            batch[slot] = concatenated(slotArrays, axis: 0)
        }
    }

    private static func syncMambaRows(from batch: MambaCache, into rows: [MambaCache]) {
        let batchedState = batch.state
        guard batchedState.count == 2,
              batchedState.allSatisfy({ $0.ndim >= 1 && $0.dim(0) == rows.count })
        else { return }
        for rowIndex in rows.indices {
            rows[rowIndex].state = batchedState.map { array in
                return array[rowIndex ..< rowIndex + 1, .ellipsis]
            }
            rows[rowIndex].offset = batch.offset
        }
    }
}

/// Per-row compiled-decode writeback. Compile-with-state can grow the batched
/// KV past each row's committed target; slicing must keep each row's own
/// prefix, not a batch-wide minimum.
enum PagedKVCompiledWriteback {
    static func rowSlices(
        keysValues compiledState: [MLXArray],
        targets: [Int]
    ) throws -> [(MLXArray, MLXArray)] {
        guard compiledState.count == 2 else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
        }
        let keys = compiledState[0]
        let values = compiledState[1]
        guard keys.ndim == 4,
              values.ndim == 4,
              keys.dim(0) == targets.count,
              values.dim(0) == targets.count,
              keys.dim(2) == values.dim(2),
              !targets.isEmpty
        else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
        }
        let compiledSequence = keys.dim(2)
        return try targets.enumerated().map { rowIndex, target in
            guard target > 0, compiledSequence >= target else {
                throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
            }
            return (
                keys[rowIndex ..< rowIndex + 1, 0..., 0..<target, 0...],
                values[rowIndex ..< rowIndex + 1, 0..., 0..<target, 0...]
            )
        }
    }
}

private struct PagedKVSharedLayerBatch {
    let cache: KVCache
    let validateBatchStateClosure: () throws -> Void
    let syncRowsFromBatchClosure: () -> Void
    let writebackCompiledInnerStateClosure: ([MLXArray], [Int]) throws -> Void
    let pendingMTPResolutionsClosure: () throws -> [NativeMTPPendingLayerResolution]

    func innerState() -> [MLXArray] {
        cache.innerState()
    }

    func validateBatchState() throws {
        try validateBatchStateClosure()
    }

    func syncRowsFromBatch() {
        syncRowsFromBatchClosure()
    }

    func writebackCompiledInnerState(_ compiledState: [MLXArray], targets: [Int]) throws {
        try writebackCompiledInnerStateClosure(compiledState, targets)
    }

    func pendingMTPResolutions() throws -> [NativeMTPPendingLayerResolution] {
        try pendingMTPResolutionsClosure()
    }
}

private enum NativeMTPPendingLayerResolution {
    case pagedAttention(PagedKVBatchLayerCache.PendingMTPResolution)
    case recurrent(MTPPackedMambaRowTransaction)

    var inputTokenCount: Int {
        switch self {
        case .pagedAttention(let resolution): resolution.inputTokenCount
        case .recurrent(let resolution): resolution.inputCount
        }
    }

    var proposalTokenCount: Int {
        switch self {
        case .pagedAttention(let resolution): resolution.proposalTokenCount
        case .recurrent(let resolution): resolution.proposalCount
        }
    }

    func validateCommit(inputCount: Int) throws {
        switch self {
        case .pagedAttention(let resolution):
            try resolution.validateCommit(inputCount: inputCount)
        case .recurrent(let resolution):
            guard inputCount > 0, inputCount <= resolution.inputCount,
                  inputCount == resolution.inputCount
                    || (inputCount == 1 && resolution.proposalCount == 1)
            else {
                throw ContinuousBatchSchedulerError.unsupported(
                    "native_mtp_finalize_recurrent_retention_unsupported"
                )
            }
        }
    }

    func commit(inputCount: Int) throws -> [MLXArray] {
        switch self {
        case .pagedAttention(let resolution):
            return try resolution.commit(inputCount: inputCount)
        case .recurrent(let resolution):
            try resolution.commit(retaining: inputCount)
            return []
        }
    }
}

private final class PagedKVBatchLayerCache: MTPPackedVerificationCache, @unchecked Sendable {
    fileprivate struct PendingMTPResolution {
        let rowCache: PagedKVCache
        let inputTokenCount: Int
        let proposalTokenCount: Int
        let inputKeys: MLXArray
        let inputValues: MLXArray

        func validateCommit(inputCount: Int) throws {
            guard inputCount >= 0, inputCount <= self.inputTokenCount else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_finalize_input_count_mismatch")
            }
        }

        func commit(inputCount: Int) throws -> [MLXArray] {
            try validateCommit(inputCount: inputCount)
            guard inputCount > 0 else { return [] }
            let keySlice = inputKeys[0..., 0..., 0 ..< inputCount, 0...]
            let valueSlice = inputValues[0..., 0..., 0 ..< inputCount, 0...]
            let updated = rowCache.update(keys: keySlice, values: valueSlice)
            return [updated.0, updated.1]
        }
    }

    private let rowCaches: [PagedKVCache]
    private var preparedLengths: [Int]?
    private var preparedMTPPackedRowMaps: [MTPPackedVerificationRowMap]?
    private var mtpPackedForwardDidUpdate = false
    private var pendingMTPResolutionsByRow: [PendingMTPResolution]?
    /// `[B, H, capacity, D]` batch buffers; only `[..<length]` is logical. Rows
    /// shorter than `length` are zero past their own stored tokens, exactly
    /// the padding `concatenatePadded` produced.
    private var keys: MLXArray?
    private var values: MLXArray?
    private var length = 0
    /// Each row's `mutationCount` right after this batch last wrote it. The
    /// in-place ragged path is used only while every row still matches, so a
    /// row changed elsewhere (bridge trim, state writeback) forces a rebuild.
    private var rowMutationCounts: [Int]?
    /// Live lockstep sequence length. When set, `update` concatenates on the
    /// batch tensors instead of looping per row (required for `MLX.compile()`).
    private var batchedOffset: Int?

    init(rowCaches: [PagedKVCache]) {
        self.rowCaches = rowCaches
        packFromRows()
    }

    var offset: Int {
        batchedOffset ?? (rowCaches.map(\.offset).min() ?? 0)
    }

    var ropeOffset: RoPEOffset {
        .batch(MLXArray(preUpdateOffsets.map(Int32.init)))
    }

    var batchOffset: MLXArray {
        let offsets: [Int]
        if mtpPackedForwardDidUpdate, let rowMaps = preparedMTPPackedRowMaps {
            offsets = rowMaps.map { $0.queryOffset + $0.inputCount }
        } else {
            offsets = preUpdateOffsets
        }
        return MLXArray(offsets.map(Int32.init))
    }

    var maxSize: Int? {
        rowCaches.compactMap(\.maxSize).min()
    }

    /// The rows' allocator block size; batch buffers grow in whole blocks too.
    private var blockSizeTokens: Int {
        rowCaches.first?.blockSizeTokens ?? 1
    }

    func innerState() -> [MLXArray] {
        guard let keys, let values else { return [] }
        return [Self.prefix(keys, length), Self.prefix(values, length)]
    }

    func syncRowsFromBatch() {
        // Only the lockstep-concat path (equal-length rows) writes KV to the
        // batch tensors alone; it is the one that sets `batchedOffset`. Ragged
        // rows take the per-row `update` path, which already wrote each row's
        // own cache and left the batch tensors padded to the longest row.
        // Copying those padded tensors back would give every shorter row the
        // batch-max length and fail the next window with
        // `paged_kv_block_table_mismatch` (Studio, 2+ concurrent rows).
        guard batchedOffset != nil else { return }
        let state = innerState()
        guard state.count == 2 else { return }
        let keys = state[0]
        let values = state[1]
        guard keys.ndim == 4,
              values.ndim == 4,
              keys.dim(0) == rowCaches.count,
              values.dim(0) == rowCaches.count
        else {
            return
        }
        for (rowIndex, cache) in rowCaches.enumerated() {
            cache.state = [
                keys[rowIndex ..< rowIndex + 1, 0..., 0..., 0...],
                values[rowIndex ..< rowIndex + 1, 0..., 0..., 0...]
            ]
        }
        batchedOffset = nil
    }

    func writebackCompiledInnerState(_ compiledState: [MLXArray], targets: [Int]) throws {
        let slices = try PagedKVCompiledWriteback.rowSlices(
            keysValues: compiledState,
            targets: targets
        )
        for (rowIndex, cache) in rowCaches.enumerated() {
            cache.state = [slices[rowIndex].0, slices[rowIndex].1]
        }
        packFromRows()
    }

    func update(keys incomingKeys: MLXArray, values incomingValues: MLXArray) -> (MLXArray, MLXArray) {
        guard incomingKeys.ndim == 4,
              incomingValues.ndim == 4,
              incomingKeys.dim(0) == rowCaches.count,
              incomingValues.dim(0) == rowCaches.count
        else {
            return (incomingKeys, incomingValues)
        }
        if let rowMaps = preparedMTPPackedRowMaps {
            return updatePackedMTPVerification(keys: incomingKeys, values: incomingValues, rowMaps: rowMaps)
        }
        if allowsLockstepConcat,
           let existingKeys = keys,
           let existingValues = values,
           length == offset
        {
            let start = length
            let newKeys = Self.write(incomingKeys, into: existingKeys, rowStarts: nil, stored: start, maxTokens: maxSize, blockSizeTokens: blockSizeTokens)
                ?? concatenated([Self.prefix(existingKeys, start), incomingKeys], axis: 2)
            let newValues = Self.write(incomingValues, into: existingValues, rowStarts: nil, stored: start, maxTokens: maxSize, blockSizeTokens: blockSizeTokens)
                ?? concatenated([Self.prefix(existingValues, start), incomingValues], axis: 2)
            keys = newKeys
            values = newValues
            length = start + incomingKeys.dim(2)
            rowMutationCounts = nil
            batchedOffset = (batchedOffset ?? offset) + incomingKeys.dim(2)
            return (Self.prefix(newKeys, length), Self.prefix(newValues, length))
        }
        if allowsLockstepConcat, keys == nil, values == nil {
            keys = Self.prefix(incomingKeys, incomingKeys.dim(2))
            values = Self.prefix(incomingValues, incomingValues.dim(2))
            length = incomingKeys.dim(2)
            rowMutationCounts = nil
            batchedOffset = incomingKeys.dim(2)
            return (incomingKeys, incomingValues)
        }
        if let updated = updateRaggedInPlace(keys: incomingKeys, values: incomingValues) {
            batchedOffset = nil
            return updated
        }
        let countsBefore = rowCaches.map(\.mutationCount)
        var updatedKeys: [MLXArray] = []
        var updatedValues: [MLXArray] = []
        updatedKeys.reserveCapacity(rowCaches.count)
        updatedValues.reserveCapacity(rowCaches.count)
        for (rowIndex, cache) in rowCaches.enumerated() {
            let keySlice = incomingKeys[rowIndex ..< rowIndex + 1, 0..., 0..., 0...]
            let valueSlice = incomingValues[rowIndex ..< rowIndex + 1, 0..., 0..., 0...]
            let updated = cache.update(keys: keySlice, values: valueSlice)
            updatedKeys.append(updated.0)
            updatedValues.append(updated.1)
        }
        let mergedKeys = Self.concatenatePadded(updatedKeys, fallback: incomingKeys)
        let mergedValues = Self.concatenatePadded(updatedValues, fallback: incomingValues)
        length = mergedKeys.dim(2)
        keys = Self.prefix(mergedKeys, length)
        values = Self.prefix(mergedValues, length)
        // The buffer mirrors the rows only if every row accepted the update;
        // a rejected row contributed its raw input instead of its history.
        let countsAfter = rowCaches.map(\.mutationCount)
        rowMutationCounts = zip(countsBefore, countsAfter).allSatisfy { $0 != $1 } ? countsAfter : nil
        batchedOffset = nil
        return (mergedKeys, mergedValues)
    }

    private func updatePackedMTPVerification(
        keys incomingKeys: MLXArray,
        values incomingValues: MLXArray,
        rowMaps: [MTPPackedVerificationRowMap]
    ) -> (MLXArray, MLXArray) {
        guard rowMaps.count == rowCaches.count,
              incomingKeys.ndim == 4,
              incomingValues.ndim == 4,
              incomingKeys.dim(0) == rowCaches.count,
              incomingValues.dim(0) == rowCaches.count,
              incomingKeys.dim(2) == incomingValues.dim(2),
              incomingKeys.dim(2) >= (rowMaps.map(\.inputCount).max() ?? 0),
              zip(rowCaches, rowMaps).allSatisfy({ cache, map in
                  cache.offset == map.queryOffset && map.inputCount == map.proposalCount + 1
              })
        else {
            return (incomingKeys, incomingValues)
        }

        var stagedKeys: [MLXArray] = []
        var stagedValues: [MLXArray] = []
        var pendingResolutions: [PendingMTPResolution] = []
        stagedKeys.reserveCapacity(rowCaches.count)
        stagedValues.reserveCapacity(rowCaches.count)
        pendingResolutions.reserveCapacity(rowCaches.count)
        for (rowIndex, cache) in rowCaches.enumerated() {
            let state = cache.state
            let map = rowMaps[rowIndex]
            let inputRange = 0 ..< map.inputCount
            let inputKeys = incomingKeys[rowIndex ..< rowIndex + 1, 0..., inputRange, 0...]
            let inputValues = incomingValues[rowIndex ..< rowIndex + 1, 0..., inputRange, 0...]
            let resolvedKeys: MLXArray
            let resolvedValues: MLXArray
            if state.count == 2 {
                resolvedKeys = concatenated([state[0], inputKeys], axis: 2)
                resolvedValues = concatenated([state[1], inputValues], axis: 2)
            } else if cache.storedTokens == 0 {
                resolvedKeys = inputKeys
                resolvedValues = inputValues
            } else {
                return (incomingKeys, incomingValues)
            }
            stagedKeys.append(resolvedKeys)
            stagedValues.append(resolvedValues)
            pendingResolutions.append(PendingMTPResolution(
                rowCache: cache,
                inputTokenCount: map.inputCount,
                proposalTokenCount: map.proposalCount,
                inputKeys: inputKeys,
                inputValues: inputValues
            ))
        }

        let mergedKeys = Self.concatenatePadded(stagedKeys, fallback: incomingKeys)
        let mergedValues = Self.concatenatePadded(stagedValues, fallback: incomingValues)
        keys = Self.prefix(mergedKeys, mergedKeys.dim(2))
        values = Self.prefix(mergedValues, mergedValues.dim(2))
        length = mergedKeys.dim(2)
        rowMutationCounts = nil
        batchedOffset = nil
        pendingMTPResolutionsByRow = pendingResolutions
        mtpPackedForwardDidUpdate = true
        return (mergedKeys, mergedValues)
    }

    /// Ragged per-row step without re-padding the whole batch: each row's
    /// cache appends in place, and the same tokens are written into the batch
    /// buffer at that row's own stored length. Returns nil (caller takes the
    /// rebuild path) unless the buffer provably mirrors every row: rows
    /// unchanged since this batch last wrote them, matching dims and dtype,
    /// and every row accepting the update. The gather-parity path always
    /// rebuilds so the probe's gather output is what reaches attention.
    private func updateRaggedInPlace(keys incomingKeys: MLXArray, values incomingValues: MLXArray) -> (MLXArray, MLXArray)? {
        guard let existingKeys = keys,
              let existingValues = values,
              let expectedCounts = rowMutationCounts,
              rowCaches.allSatisfy({ !$0.reconstructViaGather }),
              rowCaches.map(\.mutationCount) == expectedCounts,
              existingKeys.ndim == 4,
              existingValues.ndim == 4,
              Self.canWrite(incomingKeys, into: existingKeys),
              Self.canWrite(incomingValues, into: existingValues),
              incomingKeys.dim(2) == incomingValues.dim(2)
        else {
            return nil
        }
        let starts = rowCaches.map(\.storedTokens)
        guard starts.max() == length else { return nil }
        let n = incomingKeys.dim(2)
        for (rowIndex, cache) in rowCaches.enumerated() {
            let before = cache.mutationCount
            _ = cache.update(
                keys: incomingKeys[rowIndex ..< rowIndex + 1, 0..., 0..., 0...],
                values: incomingValues[rowIndex ..< rowIndex + 1, 0..., 0..., 0...]
            )
            guard cache.mutationCount != before, cache.storedTokens == starts[rowIndex] + n else {
                // A row rejected the update (capacity/overflow guard). Its
                // store is unchanged, but earlier rows already appended, so
                // drop the buffer and return what the rebuild path would.
                return rebuildAfterPartialRaggedUpdate(
                    failedRow: rowIndex,
                    keys: incomingKeys,
                    values: incomingValues
                )
            }
        }
        let newLength = (starts.map { $0 + n }.max()) ?? length
        guard let newKeys = Self.write(incomingKeys, into: existingKeys, rowStarts: starts, stored: length, maxTokens: maxSize, blockSizeTokens: blockSizeTokens),
              let newValues = Self.write(incomingValues, into: existingValues, rowStarts: starts, stored: length, maxTokens: maxSize, blockSizeTokens: blockSizeTokens)
        else {
            // Unreachable: `canWrite` was checked above for both.
            return rebuildAfterPartialRaggedUpdate(failedRow: rowCaches.count, keys: incomingKeys, values: incomingValues)
        }
        keys = newKeys
        values = newValues
        length = newLength
        rowMutationCounts = rowCaches.map(\.mutationCount)
        return (Self.prefix(newKeys, newLength), Self.prefix(newValues, newLength))
    }

    /// Finishes a ragged step that a row rejected partway: rows before
    /// `failedRow` already appended, the failed row returned its input
    /// unchanged, later rows still get their update. The result matches the
    /// per-row rebuild path exactly.
    private func rebuildAfterPartialRaggedUpdate(
        failedRow: Int,
        keys incomingKeys: MLXArray,
        values incomingValues: MLXArray
    ) -> (MLXArray, MLXArray) {
        var updatedKeys: [MLXArray] = []
        var updatedValues: [MLXArray] = []
        for (rowIndex, cache) in rowCaches.enumerated() {
            let keySlice = incomingKeys[rowIndex ..< rowIndex + 1, 0..., 0..., 0...]
            let valueSlice = incomingValues[rowIndex ..< rowIndex + 1, 0..., 0..., 0...]
            if rowIndex < failedRow {
                // Already appended; its state is what its `update` returned.
                let state = cache.state
                updatedKeys.append(state.count == 2 ? state[0] : keySlice)
                updatedValues.append(state.count == 2 ? state[1] : valueSlice)
            } else if rowIndex == failedRow {
                updatedKeys.append(keySlice)
                updatedValues.append(valueSlice)
            } else {
                let updated = cache.update(keys: keySlice, values: valueSlice)
                updatedKeys.append(updated.0)
                updatedValues.append(updated.1)
            }
        }
        let mergedKeys = Self.concatenatePadded(updatedKeys, fallback: incomingKeys)
        let mergedValues = Self.concatenatePadded(updatedValues, fallback: incomingValues)
        length = mergedKeys.dim(2)
        keys = Self.prefix(mergedKeys, length)
        values = Self.prefix(mergedValues, length)
        rowMutationCounts = nil
        return (mergedKeys, mergedValues)
    }

    var state: [MLXArray] {
        get { innerState() }
        set {
            guard newValue.count == 2 else { return }
            length = newValue[0].dim(2)
            keys = Self.prefix(newValue[0], length)
            values = Self.prefix(newValue[1], newValue[1].dim(2))
            rowMutationCounts = nil
            batchedOffset = newValue[0].dim(2)
        }
    }

    var metaState: [String] {
        get { ["macprovider_paged_kv_batch_v1"] }
        set { _ = newValue }
    }

    var isTrimmable: Bool {
        rowCaches.allSatisfy(\.isTrimmable)
    }

    @discardableResult
    func trim(_ n: Int) -> Int {
        let trimmed = rowCaches.map { $0.trim(n) }.min() ?? 0
        packFromRows()
        return trimmed
    }

    func makeMask(
        n: Int,
        windowSize: Int?,
        returnArray: Bool
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        if let rowMaps = preparedMTPPackedRowMaps {
            return .array(Self.makePackedMTPMask(n: n, rowMaps: rowMaps, windowSize: windowSize))
        }
        // `makeMask` runs at the start of the forward, before any layer calls
        // `update`, so these are PRE-update per-row token counts.
        let preUpdateOffsets = self.preUpdateOffsets
        // Equal-length rows have no cross-row padding post-update, so a single query
        // token correctly attends every key (including itself) with no mask.
        if n == 1, Set(preUpdateOffsets).count <= 1 { return .none }
        // Fail-safe: the single shared causal `offset` (max) below is only correct when
        // every row advances by the same `n` from a comparable base. Today `decode(rows:)`
        // — the sole batched caller — is always n==1, so this is unreachable; a future
        // n>1 batched caller with unequal per-row offsets would need per-row query offsets
        // this single-offset mask cannot express, and would silently miscompute. Trap in
        // debug/CI (compiled out in release) so such a caller is caught at development time.
        assert(
            n == 1 || rowCaches.count == 1 || Set(preUpdateOffsets).count == 1,
            "PagedKVBatchLayerCache.makeMask: unsupported batched multi-token shape "
                + "(n=\(n), rows=\(rowCaches.count), distinctOffsets=\(Set(preUpdateOffsets).count))"
        )
        // `createCausalMask` masks key position j unless `j < lengths[b]`. `lengths[b]`
        // must therefore be the count of VALID keys row b holds AFTER this forward's
        // update (`offset_b + n`), so each row's own current token(s) stay attendable
        // and only genuine cross-row padding is masked. Passing the pre-update offsets
        // here masked each row's own current token whenever rows differed in length —
        // the SPEC-038 FR-CB6 / SPEC-039 batched-decode correctness bug the MoE
        // input-isolation probe catches. `offset` stays the pre-update max: it only
        // sets the query's absolute position for the causal check, which the per-row
        // `lengths` gate then restricts correctly.
        let postUpdateLengths = preUpdateOffsets.map { $0 + n }
        return .array(createCausalMask(
            n: n,
            offset: preUpdateOffsets.max() ?? offset,
            windowSize: windowSize,
            lengths: MLXArray(postUpdateLengths.map(Int32.init))
        ))
    }

    func prepare(lengths: [Int]?) {
        preparedLengths = lengths
    }

    func prepare(lengths: MLXArray?) {
        preparedLengths = lengths?.asArray(Int.self)
    }

    func prepareMTPPackedVerification(rowMaps: [MTPPackedVerificationRowMap]) throws {
        guard rowMaps.count == rowCaches.count else {
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
        guard zip(rowCaches, rowMaps).allSatisfy({ cache, map in
            cache.offset == map.queryOffset
        }) else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_offset_mismatch")
        }
        preparedMTPPackedRowMaps = rowMaps
        pendingMTPResolutionsByRow = nil
        mtpPackedForwardDidUpdate = false
    }

    func finalize() {
        preparedLengths = nil
        if preparedMTPPackedRowMaps != nil {
            preparedMTPPackedRowMaps = nil
            mtpPackedForwardDidUpdate = false
            packFromRows()
        }
    }

    fileprivate func pendingMTPResolutions() throws -> [PendingMTPResolution] {
        guard let pendingMTPResolutionsByRow,
              pendingMTPResolutionsByRow.count == rowCaches.count
        else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_missing_staged_state")
        }
        return pendingMTPResolutionsByRow
    }

    func copy() -> any KVCache {
        PagedKVBatchLayerCache(rowCaches: rowCaches.map { $0.concreteCopy() })
    }

    private var preUpdateOffsets: [Int] {
        if let preparedMTPPackedRowMaps {
            return preparedMTPPackedRowMaps.map(\.queryOffset)
        }
        if let batchedOffset {
            return Array(repeating: batchedOffset, count: rowCaches.count)
        }
        return rowCaches.map(\.offset)
    }

    private static func makePackedMTPMask(
        n: Int,
        rowMaps: [MTPPackedVerificationRowMap],
        windowSize: Int?
    ) -> MLXArray {
        let totalKeys = rowMaps.map { $0.queryOffset + $0.inputCount }.max() ?? n
        var maskValues: [Int32] = []
        maskValues.reserveCapacity(rowMaps.count * n * totalKeys)
        for map in rowMaps {
            for queryColumn in 0 ..< n {
                let validQuery = queryColumn < map.inputCount
                let queryPosition = map.queryOffset + queryColumn
                for keyPosition in 0 ..< totalKeys {
                    let validKey = keyPosition < map.queryOffset + map.inputCount
                    let causal = keyPosition <= queryPosition
                    let inWindow = windowSize.map { queryPosition < keyPosition + $0 } ?? true
                    maskValues.append(validQuery && validKey && causal && inWindow ? 1 : 0)
                }
            }
        }
        return MLXArray(maskValues, [rowMaps.count, 1, n, totalKeys]) .!= MLXArray(Int32(0))
    }

    private var allowsLockstepConcat: Bool {
        rowCaches.allSatisfy { !$0.reconstructViaGather }
            && Set(preUpdateOffsets).count <= 1
    }

    private func packFromRows() {
        let keyArrays = rowCaches.compactMap { cache -> MLXArray? in
            let state = cache.state
            return state.count == 2 ? state[0] : nil
        }
        let valueArrays = rowCaches.compactMap { cache -> MLXArray? in
            let state = cache.state
            return state.count == 2 ? state[1] : nil
        }
        guard keyArrays.count == rowCaches.count,
              valueArrays.count == rowCaches.count,
              let firstKey = keyArrays.first,
              let firstValue = valueArrays.first
        else {
            keys = nil
            values = nil
            length = 0
            rowMutationCounts = nil
            batchedOffset = nil
            return
        }
        let packedKeys = Self.concatenatePadded(keyArrays, fallback: firstKey)
        keys = packedKeys
        values = Self.concatenatePadded(valueArrays, fallback: firstValue)
        length = packedKeys.dim(2)
        rowMutationCounts = rowCaches.map(\.mutationCount)
        // `batchedOffset` asserts every row is at the same length (the
        // lockstep invariant). Setting it to the minimum for ragged rows made
        // the first step of every rebuilt batch treat all rows as that length:
        // `makeMask` returned no mask (shorter rows attended padding) and
        // `ropeOffset` gave longer rows the wrong positions. Studio: ragged
        // concurrent greedy rows diverged from serial or emitted EOS first.
        let offsets = rowCaches.map(\.offset)
        batchedOffset = Set(offsets).count == 1 ? offsets.first : nil
    }

    /// Always a new slice; see `PagedKVCache.prefix` (in-place slice writes).
    /// Every array this cache adopts or hands out goes through it, so only
    /// objects this cache created are ever written in place.
    private static func prefix(_ buffer: MLXArray, _ tokens: Int) -> MLXArray {
        buffer[.ellipsis, ..<tokens, 0...]
    }

    /// In-place writes need identical batch/head/dim sizes and dtype; slice
    /// assignment would otherwise broadcast or cast where concatenation
    /// promoted, changing what reaches attention.
    private static func canWrite(_ incoming: MLXArray, into buffer: MLXArray) -> Bool {
        incoming.ndim == 4
            && buffer.ndim == 4
            && buffer.dim(0) == incoming.dim(0)
            && buffer.dim(1) == incoming.dim(1)
            && buffer.dim(3) == incoming.dim(3)
            && buffer.dtype == incoming.dtype
    }

    /// Writes `incoming` into the batch buffer in place, growing it like
    /// `KVCacheSimple` when full. `rowStarts == nil` writes every row at
    /// `stored` (lockstep); otherwise row `r` lands at `rowStarts[r]`. New
    /// capacity is zero-filled, so rows stay zero past their own length.
    /// Returns nil when `canWrite` fails.
    private static func write(
        _ incoming: MLXArray,
        into buffer: MLXArray,
        rowStarts: [Int]?,
        stored: Int,
        maxTokens: Int?,
        blockSizeTokens: Int
    ) -> MLXArray? {
        guard canWrite(incoming, into: buffer) else { return nil }
        let n = incoming.dim(2)
        let needed = (rowStarts?.max() ?? stored) + n
        var target = buffer
        if buffer.dim(2) < needed {
            let capacity = PagedKVBlockLayout.grownCapacity(
                needed: needed,
                maxTokens: maxTokens ?? Int.max,
                blockSizeTokens: blockSizeTokens
            )
            let extra = MLXArray.zeros(
                [buffer.dim(0), buffer.dim(1), capacity - stored, buffer.dim(3)],
                dtype: buffer.dtype
            )
            target = concatenated([prefix(buffer, stored), extra], axis: 2)
        }
        guard n > 0 else { return target }
        if let rowStarts {
            for (rowIndex, start) in rowStarts.enumerated() {
                target[rowIndex ..< rowIndex + 1, 0..., start ..< start + n, 0...] =
                    incoming[rowIndex ..< rowIndex + 1, 0..., 0..., 0...]
            }
        } else {
            target[.ellipsis, stored ..< stored + n, 0...] = incoming
        }
        return target
    }

    private static func concatenatePadded(_ arrays: [MLXArray], fallback: MLXArray) -> MLXArray {
        guard let first = arrays.first,
              arrays.allSatisfy({
                  $0.ndim == 4
                      && $0.dim(0) == first.dim(0)
                      && $0.dim(1) == first.dim(1)
                      && $0.dim(3) == first.dim(3)
                      && $0.dtype == first.dtype
              })
        else {
            return fallback
        }
        let maxSequenceLength = arrays.map { $0.dim(2) }.max() ?? 0
        let padded = arrays.map { array -> MLXArray in
            let padTokens = maxSequenceLength - array.dim(2)
            guard padTokens > 0 else { return array }
            let pad = MLXArray.zeros([array.dim(0), array.dim(1), padTokens, array.dim(3)], dtype: array.dtype)
            return concatenated([array, pad], axis: 2)
        }
        return concatenated(padded, axis: 0)
    }
}
