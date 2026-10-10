import CryptoKit
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

enum NativeMTPStateDigestPhase: String, Sendable {
    case ordinaryAfterDecode = "ordinary_after_decode"
    case afterProposal = "after_proposal"
    case afterVerify = "after_verify"
    case beforeFinalize = "before_finalize"
    case afterFinalize = "after_finalize"
    case beforeAbort = "before_abort"
    case afterAbort = "after_abort"
    case abort = "abort"
}

struct NativeMTPStateDigestRecord: Equatable, Sendable {
    let requestID: String
    let phase: NativeMTPStateDigestPhase
    let digestSHA256: String
    let cacheDigestSHA256: String
    let drafterDigestSHA256: String?
    let pendingTargetDigestSHA256: String?
    let drafterRecomputeDigestSHA256: String?
    let committedKVTokenCount: Int
    let proposedTokens: Int
    let committedProposalTokens: Int?
}

final class NativeMTPStateDigestObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [NativeMTPStateDigestRecord] = []

    func record(_ record: NativeMTPStateDigestRecord) {
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    func snapshot() -> [NativeMTPStateDigestRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
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
    let hostBatchOffsetsBeforeUpdate: [Int]?
    let batchOffsetsAfterUpdate: [Int]
    let hostBatchOffsetsAfterUpdate: [Int]?
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
    /// Each row's flattened keys then values after resolution.
    let rowStateValuesAfterResolution: [[Float]]
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
        /// keep=0 sliding-window attention. Stored as full paged history, then
        /// presented to attention as the rotating-equivalent suffix — not a
        /// ring buffer, and not sink-token keep>0.
        case slidingWindow(windowTokens: Int)

        var usesPagedKVCache: Bool {
            switch self {
            case .pagedAttention, .slidingWindow: true
            case .recurrentMamba: false
            }
        }

        var hasSlidingWindow: Bool {
            if case .slidingWindow = self { return true }
            return false
        }

        static func recognized(from cache: KVCache) -> CacheKind? {
            if cache is KVCacheSimple { return .pagedAttention }
            if cache is MambaCache { return .recurrentMamba }
            if cache is RotatingKVCache {
                guard let window = cache.maxSize, window > 0 else { return nil }
                // RotatingKVCache.metaState is [keep, maxSize, step, offset, idx].
                // keep>0 preserves a sink-token prefix the windowed full-history
                // mask does not reconstruct.
                guard cache.metaState.first == "0" else { return nil }
                return .slidingWindow(windowTokens: window)
            }
            return nil
        }

        static func kinds(from caches: [KVCache]) -> [CacheKind]? {
            guard !caches.isEmpty else { return nil }
            var kinds: [CacheKind] = []
            kinds.reserveCapacity(caches.count)
            for cache in caches {
                guard let kind = recognized(from: cache) else { return nil }
                kinds.append(kind)
            }
            return kinds.contains(where: \.usesPagedKVCache) ? kinds : nil
        }
    }

    private struct RowState {
        var caches: [KVCache]
        var state: LMOutput.State?
        /// Hybrid rows: where the last ordinary decode window left the
        /// recurrent state, plus the stop-boundary checkpoints taken inside it.
        var recurrentWindow: RecurrentWindowRecord? = nil
    }

    /// A multi-step window runs every row for all of its steps, so a row that
    /// stops mid-window ends it with recurrent state past its stop. Paged KV
    /// is trimmed back at terminal; recurrent state cannot be, so the window
    /// keeps the row's state at the stop step and the step after (the
    /// model-stop and request-stop covered lengths, SPEC-038 FR-CB4/AC-26).
    private struct RecurrentWindowRecord {
        /// Tokens the row's recurrent state covers after the window.
        let endTokenCount: Int
        /// The row's recurrent state arrays after the window. Any later
        /// forward replaces them, which retires this record. Held strongly so
        /// a replacement array can never reuse their identity.
        let endState: [MLXArray]
        let checkpoints: [RecurrentStateCheckpoint]
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
        /// Proposal IDs verified this round; the accepted prefix advances the
        /// drafter at finalize.
        let proposalTokens: [Int]
        let layers: [NativeMTPPendingLayerResolution]
    }

    private let container: ModelContainer
    private let drafterContainer: MTPDrafterContainer?
    private let blockSizeTokens: Int
    private let maxPhysicalBlocks: Int
    private let poolEpoch: Int
    let cacheKinds: [CacheKind]
    private let contiguousCacheBridge: (any PagedKVRuntimeCacheBridge)?
    /// When true, lockstep decode reuses a compiled `[B, 1]` graph over batched
    /// contiguous KV. Tests keep the default off so fake models are not traced.
    let compiledDecode: Bool
    private let lock = NSLock()
    private var rows: [String: RowState] = [:]
    private var decodeSession: DecodeSession?
    private var nativeMTPPendingTransactions: [String: NativeMTPPendingTransaction] = [:]
    /// Row-owned drafter state. Only prompt prefill and a committed finalize
    /// change it, so an aborted or cancelled round leaves the pre-round
    /// state in place.
    private var nativeMTPDrafterStates: [String: MTPDrafterState] = [:]
    /// Each row's next depth-one proposal, read back with the round that
    /// produced it so proposal needs no GPU work.
    private var nativeMTPDrafterSeedTokens: [String: Int] = [:]
    /// Committed (sampled token, target hidden state) pairs a native row
    /// produced while riding the ordinary forward at load-gate depth zero, in
    /// order. They are exactly the columns a depth-zero native finalize would
    /// have fed the drafter, and are flushed into it with one packed advance
    /// only before the row's next proposal. A held row that finishes at depth
    /// zero never advances its drafter, so the gate adds no drafter forward to
    /// the shared ordinary rounds (SPEC-048 R015 gated cells). Each column is
    /// one token and its own copied `[1, 1, hidden]` row, never a view of the
    /// batch output. A row holds at most `nativeMTPDrafterColumnCap` columns:
    /// a held row about to pass it catches its drafter up early, before its
    /// next ordinary window.
    private var nativeMTPPendingDrafterColumns: [String: [(token: Int, hidden: MLXArray)]] = [:]
    /// Far above the R015 cells' 512-token completions, so the cap never
    /// fires in a measured gated cell; it bounds the buffer's memory, which
    /// the paged-KV accounting does not see, for long held completions.
    static let defaultNativeMTPDrafterColumnCap = 1024
    let nativeMTPDrafterColumnCap: Int
    /// Most target tokens (rows x verify width) one packed native-MTP
    /// verification forward carries. Every quantized projection of that
    /// forward multiplies that many tokens, and MLX switches it from `qmv` to
    /// `qmm` at the projection's vector limit (`ContinuousBatchDecodeRouteBound`),
    /// so a larger round verifies in consecutive forwards and every row keeps
    /// the kernel route of its lone verification (SPEC-038 FR-CB2).
    let maxVerifyTokensPerForward: Int
    static let deviceVerifyTokenBound: Int = {
        let deviceBound = ContinuousBatchDecodeRouteBound.maxDecodeRowsPerForward(
            architecture: PagedKVVectorAttentionRoute.deviceArchitecture
        )
        #if MACPROVIDER_LAB_HARNESS
        // Lab measurement only, shared with the decode row bound override.
        return ProcessInfo.processInfo.environment["MACPROVIDER_LAB_DECODE_ROW_BOUND"]
            .flatMap { Int($0) }
            .flatMap { $0 >= 1 ? $0 : nil } ?? deviceBound
        #else
        return deviceBound
        #endif
    }()

    /// Consecutive packed-verify groups in packed-row order, each carrying at
    /// most `maxTokens` target tokens (rows x the group's widest row), and at
    /// least one row.
    static func verifyGroups(widths: [Int], maxTokens: Int) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        var start = 0
        var widest = 0
        for (index, width) in widths.enumerated() {
            let candidate = max(widest, width)
            if index > start, candidate * (index - start + 1) > maxTokens {
                groups.append(start ..< index)
                start = index
                widest = width
            } else {
                widest = candidate
            }
        }
        if start < widths.count { groups.append(start ..< widths.count) }
        return groups
    }
    private var activeOperations = 0
    private var cancelRequested = false
    /// Set once a ragged prefill forward attended outside
    /// `PagedKVBatchLayerCache.updateAndAttend` (a model that calls SDPA
    /// itself). That forward's rows are failed before sampling; their
    /// attention depended on the group's padded key length. Later ragged
    /// groups take the serial path.
    private var raggedPrefillAttentionBypassed = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    #if DEBUG || MACPROVIDER_LAB_HARNESS
    private var labNativeMTPStateDigestObserver: NativeMTPStateDigestObserver?
    private var nativeMTPDrafterRecomputeDigests: [String: String] = [:]
    private var labNativeMTPCommittedPrefixTokens: [String: [Int]] = [:]
    private var labNativeMTPCommittedPrefixHidden: [String: [MLXArray]] = [:]
    private var labNativeMTPCommittedPrefixTargetBonus: [String: Int] = [:]
    private var labNativeMTPPrefixPositionDeltasUnsupported: Set<String> = []
    #endif

    init(
        container: ModelContainer,
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        poolEpoch: Int,
        layerCount: Int,
        cacheKinds: [CacheKind]? = nil,
        contiguousCacheBridge: (any PagedKVRuntimeCacheBridge)? = nil,
        compiledDecode: Bool = false,
        drafterContainer: MTPDrafterContainer? = nil,
        nativeMTPDrafterColumnCap: Int = PagedKVSharedForwardBackend.defaultNativeMTPDrafterColumnCap,
        maxVerifyTokensPerForward: Int? = nil
    ) {
        self.container = container
        self.drafterContainer = drafterContainer
        self.nativeMTPDrafterColumnCap = max(1, nativeMTPDrafterColumnCap)
        self.maxVerifyTokensPerForward = max(1, maxVerifyTokensPerForward ?? Self.deviceVerifyTokenBound)
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
        drafterContainer: MTPDrafterContainer? = nil,
        nativeMTPDrafterColumnCap: Int = PagedKVSharedForwardBackend.defaultNativeMTPDrafterColumnCap,
        maxVerifyTokensPerForward: Int? = nil
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
            drafterContainer: drafterContainer,
            nativeMTPDrafterColumnCap: nativeMTPDrafterColumnCap,
            maxVerifyTokensPerForward: maxVerifyTokensPerForward
        )
    }

    func prefill(rows inputs: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        return try await container.perform(nonSendable: inputs) { context, inputs in
            let raggedOffsets = Self.hasRaggedPromptOffsets(inputs)
            if Self.canSharePrefillForward(inputs),
               !raggedOffsets || self.supportsRaggedPrefillOffsets {
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
                       from: rowStates.map(\.caches),
                       raggedPrefill: raggedOffsets
                   ) {
                    let cachesAsKV = batchedCaches.map(\.cache)
                    let chunkLength = inputs[0].promptTokens.count
                    let prompt = MLXArray(
                        inputs.flatMap(\.promptTokens).map(Int32.init)
                    ).reshaped([inputs.count, chunkLength])
                    let text = LMInput.Text(tokens: prompt)
                    // Native rows join the same [B, L] forward as their
                    // ordinary peers, so every row's target state matches the
                    // MTP-disabled run of this group. The emit flag only adds
                    // the prompt hidden states the drafters are seeded from.
                    let hasNativeRows = inputs.contains(where: \.nativeMTPPromptPrefill)
                    var sharedState: LMOutput.State?
                    if hasNativeRows {
                        var emit = LMOutput.State()
                        emit[mtpEmitFlagKey] = true
                        sharedState = emit
                    }
                    let output = withPreparedCache(cachesAsKV, lengths: text.sequenceLengths) {
                        context.model(text, cache: cachesAsKV, state: sharedState)
                    }
                    let promptHidden = hasNativeRows
                        ? Self.sharedPrefillPromptHidden(output.state, rows: inputs.count, chunkLength: chunkLength)
                        : nil
                    // A ragged forward that attended outside the per-row
                    // path is rejected before anything is sampled or
                    // committed; its rows fail below.
                    let attentionBypassed = raggedOffsets
                        && self.noteRaggedPrefillAttentionBypass(batchedCaches)
                    if !attentionBypassed,
                       hasNativeRows ? promptHidden != nil : output.state == nil,
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
                        var drafterFailures = Set<Int>()
                        if let promptHidden {
                            for (index, input) in inputs.enumerated() where input.nativeMTPPromptPrefill {
                                do {
                                    try await self.seedNativeMTPDrafterFromPrefill(
                                        targetModel: context.model,
                                        input: input,
                                        targetHidden: promptHidden.take(MLXArray([Int32(index)]), axis: 0),
                                        positionDeltas: nil,
                                        sampledToken: input.sampleFirstToken ? sampledTokens?[index] : nil
                                    )
                                } catch {
                                    // The shared target forward stays committed
                                    // for every peer; only this row fails.
                                    self.removeRowState(for: input.requestID)
                                    drafterFailures.insert(index)
                                }
                            }
                        }
                        self.clearDecodeSession()
                        CBTrace.log(nil, "prefill_shared rows=\(inputs.count) chunk=\(chunkLength) ragged=\(raggedOffsets)")
                        return inputs.enumerated().map { index, input in
                            drafterFailures.contains(index)
                                ? ContinuousBatchPrefillOutput(
                                    requestID: input.requestID,
                                    failureCode: "continuous_batching_prefill_failed"
                                )
                                : ContinuousBatchPrefillOutput(
                                    requestID: input.requestID,
                                    sampledToken: input.sampleFirstToken ? sampledTokens?[index] : nil
                                )
                        }
                    }
                    // Backend-level LMOutput.State cannot be split safely by
                    // row. The speculative batched caches have not been synced
                    // back, so discard them and use the isolated serial path.
                    // A ragged group is different: each row's paged cache took
                    // its chunk in place during the forward, so a serial retry
                    // would append the chunk twice. Fail those rows instead
                    // (also when the forward bypassed per-row attention).
                    if raggedOffsets {
                        for input in inputs {
                            self.removeRowState(for: input.requestID)
                        }
                        self.clearDecodeSession()
                        return inputs.map {
                            ContinuousBatchPrefillOutput(
                                requestID: $0.requestID,
                                failureCode: "continuous_batching_prefill_failed"
                            )
                        }
                    }
                }
            }

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
                            guard let targetHidden = output.state?[mtpLastHiddenStatesKey] else {
                                throw ContinuousBatchSchedulerError.unsupported(
                                    "native_mtp_missing_prompt_hidden_state"
                                )
                            }
                            try await self.seedNativeMTPDrafterFromPrefill(
                                targetModel: context.model,
                                input: input,
                                targetHidden: targetHidden,
                                positionDeltas: output.state?[mtpPositionDeltasKey],
                                sampledToken: sampledToken
                            )
                        }
                        // Earlier chunks evaluate only cache state. The final
                        // chunk also evaluates its sampled token, matching
                        // `TokenIterator.prepare` on the serial path.
                        eval(state.caches)
                        // The drafter emission is per-call output, not row
                        // state: a stateless row stays stateless so it can
                        // share later batched forwards with other rows.
                        if !(input.nativeMTPPromptPrefill && state.state == nil) {
                            state.state = output.state
                        }
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
            self.clearDecodeSession()
            return outputs
        }
    }

    /// The `[B, >=L, hidden]` prompt hidden states of a shared prefill that
    /// carried native rows, or nil when the output state is not exactly the
    /// drafter emission the forward was asked for. Per-row position deltas
    /// (mRoPE models) cannot be split by row here, so their presence keeps
    /// the group on the serial path.
    static func sharedPrefillPromptHidden(
        _ state: LMOutput.State?,
        rows: Int,
        chunkLength: Int
    ) -> MLXArray? {
        guard let state,
              state[mtpPositionDeltasKey] == nil,
              let hidden = state[mtpLastHiddenStatesKey],
              hidden.ndim == 3,
              hidden.dim(0) == rows,
              hidden.dim(1) >= chunkLength
        else {
            return nil
        }
        return hidden
    }

    /// Seeds or advances a native row's drafter over the prompt chunk just
    /// prefilled, from that row's `[1, >=L, hidden]` target hidden states
    /// (MTP-6). The tail token is the sampled first token for the final
    /// chunk and the next prompt token otherwise.
    private func seedNativeMTPDrafterFromPrefill(
        targetModel: any LanguageModel,
        input: ContinuousBatchPrefillInput,
        targetHidden: MLXArray,
        positionDeltas: MLXArray?,
        sampledToken: Int?
    ) async throws {
        let tailToken: Int
        if input.isFinalChunk {
            guard let sampledToken else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_prompt_bonus_token")
            }
            tailToken = sampledToken
        } else {
            guard let nextPromptToken = input.nativeMTPNextPromptToken else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_next_prompt_token")
            }
            tailToken = nextPromptToken
        }
        if input.promptTokenOffset == 0 && input.isFinalChunk {
            try await prepareNativeMTPDrafterState(
                targetModel: targetModel,
                prompt: MLXArray(input.promptTokens.map(Int32.init)).reshaped([1, input.promptTokens.count]),
                targetHidden: targetHidden,
                positionDeltas: positionDeltas,
                firstBonusToken: tailToken,
                requestID: input.requestID
            )
        } else {
            try await advanceNativeMTPDrafterOverPromptChunk(
                targetModel: targetModel,
                input: input,
                targetHidden: targetHidden,
                positionDeltas: positionDeltas,
                tailToken: tailToken
            )
        }
    }

    private func makeBatchedCachesIfCompatible(
        from rowCaches: [[KVCache]],
        raggedPrefill: Bool = false
    ) -> [PagedKVSharedLayerBatch]? {
        try? makeBatchedCaches(from: rowCaches, raggedPrefill: raggedPrefill)
    }

    /// True when this ragged forward attended outside
    /// `PagedKVBatchLayerCache.updateAndAttend`; later ragged groups then
    /// take the serial path.
    private func noteRaggedPrefillAttentionBypass(_ batches: [PagedKVSharedLayerBatch]) -> Bool {
        notePaddedAttentionBypass(batches, phase: "prefill")
    }

    /// SPEC-038 FR-CB2: a padded forward (rows of different key extents)
    /// whose model called SDPA itself attended over the padded batch, so its
    /// rows' attention followed the padded route. The caller fails that
    /// forward's rows before sampling. From then on the backend forms no
    /// ragged prefill groups and decodes and verifies rows one per forward
    /// (`serializesPaddedRows`).
    private func notePaddedAttentionBypass(_ batches: [PagedKVSharedLayerBatch], phase: String) -> Bool {
        guard Self.attendedOutsideCachePath(batches) else { return false }
        lock.lock()
        let first = !raggedPrefillAttentionBypassed
        raggedPrefillAttentionBypassed = true
        lock.unlock()
        if first {
            try? FileHandle.standardError.write(contentsOf: Data(
                "event=continuous_batch_ragged_prefill_disabled reason=attention_outside_cache phase=\(phase)\n".utf8
            ))
        }
        return true
    }

    private static func attendedOutsideCachePath(_ batches: [PagedKVSharedLayerBatch]) -> Bool {
        batches.contains { ($0.cache as? PagedKVBatchLayerCache)?.attendedOutsideCachePath == true }
    }

    /// True once a padded forward bypassed per-row attention: the scheduler
    /// then decodes one row per forward and verification runs one row per
    /// packed forward, so no row attends over another row's padding.
    var serializesPaddedRows: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raggedPrefillAttentionBypassed
    }

    private static func hasValidBatchState(_ batches: [PagedKVSharedLayerBatch]) -> Bool {
        do {
            try batches.forEach { try $0.validateBatchState() }
            return true
        } catch {
            return false
        }
    }

    /// Rows share one `[B, L]` prompt forward when every chunk has the same
    /// length `L` and continues exactly from that row's committed KV. Prompt
    /// offsets may differ (SPEC-038 FR-CB2 ragged shared prefill): RoPE takes
    /// each row's own offset and `PagedKVBatchLayerCache.makeMask` builds a
    /// per-row causal mask. Native-MTP prompt rows keep the equal-offset rule,
    /// because their drafter seeding is proven only on that shape.
    static func canSharePrefillForward(_ inputs: [ContinuousBatchPrefillInput]) -> Bool {
        guard inputs.count > 1, let first = inputs.first, !first.promptTokens.isEmpty else {
            return false
        }
        let chunkLength = first.promptTokens.count
        let shapeCompatible = inputs.allSatisfy {
            $0.promptTokens.count == chunkLength
                && $0.committedKVTokenCount == $0.promptTokenOffset
                && $0.targetKVTokenCount == $0.promptTokenOffset + chunkLength
        }
        guard shapeCompatible else { return false }
        if hasRaggedPromptOffsets(inputs) {
            return !inputs.contains(where: \.nativeMTPPromptPrefill)
        }
        return true
    }

    static func hasRaggedPromptOffsets(_ inputs: [ContinuousBatchPrefillInput]) -> Bool {
        Set(inputs.map(\.promptTokenOffset)).count > 1
    }

    /// Whether this backend can run a ragged-offset shared prefill. Sliding
    /// window layers present a per-row trimmed K/V suffix whose columns no
    /// longer line up across rows of different lengths, so those models keep
    /// the equal-offset rule.
    var supportsRaggedPrefillOffsets: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cacheKinds.contains(where: \.hasSlidingWindow) && !raggedPrefillAttentionBypassed
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
            let (decodable, capFailures) = await self.catchingUpNativeMTPDrafterColumnsAtCap(
                targetModel: context.model,
                inputs: supportedInputs,
                steps: 1
            )
            guard !decodable.isEmpty else { return capFailures }
            return try self.performDecode(
                model: context.model,
                supportedInputs: decodable,
                steps: 1
            ) + capFailures
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
    /// apply stop/stream/receipt without dropping intermediates, and reports
    /// each step's tokens to `onStep` as soon as they are on the host. The
    /// throughput harness uses the same seam.
    func decodeLockstepWindow(
        rows inputs: [ContinuousBatchDecodeInput],
        steps: Int,
        onStep: ContinuousBatchDecodeWindowStepObserver?
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
            let (decodable, capFailures) = await self.catchingUpNativeMTPDrafterColumnsAtCap(
                targetModel: context.model,
                inputs: supportedInputs,
                steps: steps
            )
            guard !decodable.isEmpty else { return capFailures }
            return try self.performDecode(
                model: context.model,
                supportedInputs: decodable,
                steps: steps,
                onStep: onStep
            ) + capFailures
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

        // The drafter already proposed each row's next token in the round
        // that last advanced it (prefill or finalize), so proposal is a host
        // lookup. The drafter is consulted only to bound the depth.
        let maximumBlockSize = try await drafterContainer.perform { context -> Int? in
            guard context.model is any MTPPackedStatefulDrafterModel else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_drafter_required")
            }
            return context.model.maximumBlockSize
        }
        // A row returning from load-gate depth zero first catches its drafter
        // up on the columns it committed through the ordinary forward, so
        // its proposal follows the same committed prefix as the target. This
        // runs for every proposing row, depth zero included, because a
        // depth-zero finalize also advances the drafter from its state.
        let pendingIDs = inputs.map(\.requestID).filter { hasPendingNativeMTPDrafterColumns(for: $0) }
        if !pendingIDs.isEmpty {
            try await container.perform { context in
                try await self.flushNativeMTPDrafterColumns(
                    targetModel: context.model,
                    requestIDs: pendingIDs,
                    minimumColumns: 1
                )
            }
        }
        var proposals: [String: [Int]] = [:]
        for input in inputs {
            guard input.maximumProposalDepth > 0 else {
                proposals[input.requestID] = []
                continue
            }
            guard NativeMTPProposalBounds.fits(
                maximumProposalDepth: input.maximumProposalDepth,
                maximumBlockSize: maximumBlockSize
            ) else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_proposal_depth_exceeds_drafter")
            }
            proposals[input.requestID] = nativeMTPDrafterSeedToken(for: input.requestID).map { [$0] } ?? []
        }
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
        let ordered = inputs.sorted { $0.packedRowIndex < $1.packedRowIndex }
        let groups = Self.verifyGroups(
            widths: ordered.map(\.verifiedInputTokenCount),
            maxTokens: serializesPaddedRows ? 1 : maxVerifyTokensPerForward
        )
        guard groups.count > 1 else {
            return try await verifyNativeMTPPackedGroup(rows: inputs)
        }
        var verifiedRows: [NativeMTPVerifiedRow] = []
        for group in groups {
            // Each group verifies as its own packed round, rows re-indexed
            // from 0; results keep the round's packed row indices.
            let groupInputs = ordered[group].enumerated().map { index, input in
                ContinuousBatchNativeMTPVerifyInput(
                    requestID: input.requestID,
                    currentToken: input.currentToken,
                    proposalTokens: input.proposalTokens,
                    generatedTokens: input.generatedTokens,
                    samplerSeed: input.samplerSeed,
                    binding: input.binding,
                    blockTable: input.blockTable,
                    committedKVTokenCount: input.committedKVTokenCount,
                    verifiedInputTokenCount: input.verifiedInputTokenCount,
                    targetKVTokenCount: input.targetKVTokenCount,
                    packedRowIndex: index,
                    samplerStep: input.samplerStep,
                    temperature: input.temperature,
                    topP: input.topP
                )
            }
            let groupRows = try await verifyNativeMTPPackedGroup(rows: groupInputs)
            verifiedRows += groupRows.map { row in
                NativeMTPVerifiedRow(
                    schedulerRowID: row.schedulerRowID,
                    packedRowIndex: ordered[group.lowerBound + row.packedRowIndex].packedRowIndex,
                    proposedTokenIDs: row.proposedTokenIDs,
                    targetTopTokenIDs: row.targetTopTokenIDs
                )
            }
        }
        return verifiedRows.sorted { $0.packedRowIndex < $1.packedRowIndex }
    }

    /// One packed verification forward over `inputs` (packed row indices
    /// `0 ..< inputs.count`).
    private func verifyNativeMTPPackedGroup(
        rows inputs: [ContinuousBatchNativeMTPVerifyInput]
    ) async throws -> [NativeMTPVerifiedRow] {
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
            if self.notePaddedAttentionBypass(batchedCaches, phase: "verify") {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_padded_attention_bypassed")
            }
            let pendingByRequestID = try Dictionary(
                uniqueKeysWithValues: self.pendingNativeMTPTransactions(
                    from: batchedCaches,
                    inputs: inputs,
                    rows: output.rows
                ).map { ($0.0, $0.1) }
            )
            self.replaceNativeMTPPendingTransactions(
                requestIDs: inputs.map(\.requestID),
                transactions: pendingByRequestID.mapValues { $0 }
            )
            #if DEBUG || MACPROVIDER_LAB_HARNESS
            try self.recordNativeMTPStateDigest(
                phase: .afterVerify,
                requestIDs: inputs.map(\.requestID),
                transactions: pendingByRequestID
            )
            #endif
            for (index, input) in inputs.enumerated() {
                try self.setRowState(rowStates[index], for: input.requestID, binding: input.binding)
            }
            // One selection and one host transfer for the whole packed round
            // instead of two blocking GPU round trips per row.
            let topTokenIDsByRow = Self.packedTargetTokenIDs(
                rows: output.rows.map { ($0.proposalLogits, $0.bonusLogits) },
                samplers: output.rows.map { row in
                    let input = inputs[row.map.rowIndex]
                    return ContinuousBatchRowSampler.Row(
                        temperature: input.temperature,
                        topP: input.topP,
                        samplerSeed: input.samplerSeed,
                        samplerStep: input.samplerStep
                    )
                }
            )
            return zip(output.rows, topTokenIDsByRow).map { row, targetTopTokenIDs in
                let input = inputs[row.map.rowIndex]
                return NativeMTPVerifiedRow(
                    schedulerRowID: input.requestID,
                    packedRowIndex: input.packedRowIndex,
                    proposedTokenIDs: input.proposalTokens,
                    targetTopTokenIDs: targetTopTokenIDs
                )
            }
        }
        return verified.sorted { $0.packedRowIndex < $1.packedRowIndex }
    }

    func finalizeNativeMTPPackedRound(rows inputs: [ContinuousBatchNativeMTPFinalizeInput]) async throws {
        guard !inputs.isEmpty else { return }
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        try await container.perform(nonSendable: inputs) { context, inputs in
            if inputs.allSatisfy({ !$0.shouldCommit }) {
                // Proposal never mutates drafter state, so an aborted round
                // only drops its staged target transactions.
                let transactions = self.consumeAvailableNativeMTPPendingTransactions(for: inputs)
                let presentInputs = inputs.filter { transactions[$0.requestID] != nil }
                if !transactions.isEmpty {
                    try self.validateNativeMTPFinalizeInputs(
                        presentInputs,
                        transactions: transactions)
                }
                #if DEBUG || MACPROVIDER_LAB_HARNESS
                try self.recordNativeMTPStateDigest(
                    phase: .beforeAbort,
                    inputs: inputs,
                    transactions: transactions
                )
                for input in inputs {
                    self.labClearNativeMTPDrafterRecomputeDigest(requestID: input.requestID)
                    try await self.labRecomputeNativeMTPDrafterDigest(
                        targetModel: context.model,
                        requestID: input.requestID
                    )
                }
                try self.recordNativeMTPStateDigest(
                    phase: .afterAbort,
                    inputs: inputs,
                    transactions: [:]
                )
                #endif
                return
            }
            let transactions = try self.consumeNativeMTPPendingTransactions(for: inputs)
            try self.validateNativeMTPFinalizeInputs(inputs, transactions: transactions)
            #if DEBUG || MACPROVIDER_LAB_HARNESS
            try self.recordNativeMTPStateDigest(
                phase: .beforeFinalize,
                inputs: inputs,
                transactions: transactions
            )
            #endif
            let committing = inputs.filter(\.shouldCommit).compactMap { input in
                transactions[input.requestID].map { (input, $0) }
            }
            // Advance every committing row's drafter with one packed forward
            // that also proposes each row's next token. It validates every
            // row before staging anything, and mutates no stored state.
            let advance = try await self.advanceNativeMTPDrafters(
                targetModel: context.model,
                rows: committing
            )
            // Publish every committing row's target KV and recurrent state for
            // all layers, then evaluate them together with the drafter
            // advance: one GPU wait per round instead of one per row per layer.
            var staged: [MLXArray] = []
            for (input, transaction) in committing {
                for layer in transaction.layers {
                    staged += try layer.stageCommit(inputCount: input.committedInputTokenCount)
                }
            }
            // Convert the seeds inside the same evaluation so the host
            // readback below is a plain copy, not a second GPU submit and wait.
            let seedTokens = advance?.proposals.asType(.int32)
            if let advance, let seedTokens {
                staged += advance.states.flatMap { $0.cache.flatMap(\.state) }
                staged.append(seedTokens)
            }
            eval(staged)
            if let advance, let seedTokens {
                let seeds = seedTokens.asArray(Int32.self).map(Int.init)
                self.storeNativeMTPDrafterAdvance(
                    requestIDs: committing.map(\.0.requestID),
                    states: advance.states,
                    seedTokens: seeds
                )
                #if DEBUG || MACPROVIDER_LAB_HARNESS
                for (input, transaction) in committing {
                    let committedProposalTokens = Array(transaction.proposalTokens.prefix(input.committedProposalTokenCount))
                    let committedTokens = [transaction.currentToken] + committedProposalTokens
                    try self.labRecordNativeMTPCommittedPrefix(
                        requestID: input.requestID,
                        tokens: committedTokens,
                        hidden: try Self.labHiddenColumns(
                            transaction.targetState.lastHidden,
                            count: input.committedInputTokenCount
                        ),
                        positionDeltas: transaction.targetState.positionDeltas,
                        targetBonusToken: input.acceptedTokenIDs.last ?? {
                            throw ContinuousBatchSchedulerError.unsupported("native_mtp_finalize_accepted_tokens_mismatch")
                        }()
                    )
                    try await self.labRecomputeNativeMTPDrafterDigest(
                        targetModel: context.model,
                        requestID: input.requestID
                    )
                }
                #endif
            }
            for (input, _) in committing {
                self.invalidateDecodeSession(containing: input.requestID)
            }
            #if DEBUG || MACPROVIDER_LAB_HARNESS
            try self.recordNativeMTPStateDigest(
                phase: .afterFinalize,
                inputs: inputs,
                transactions: transactions
            )
            #endif
        }
    }

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    func installLabNativeMTPStateDigestObserver(_ observer: NativeMTPStateDigestObserver?) {
        lock.lock()
        labNativeMTPStateDigestObserver = observer
        lock.unlock()
    }

    func recordLabNativeMTPOrdinaryStateDigest(requestIDs: [String]) async throws {
        try await recordLabNativeMTPStateDigest(phase: .ordinaryAfterDecode, requestIDs: requestIDs)
    }

    func recordLabNativeMTPStateDigest(
        phase: NativeMTPStateDigestPhase,
        requestIDs: [String]
    ) async throws {
        lock.lock()
        let observer = labNativeMTPStateDigestObserver
        lock.unlock()
        guard let observer else { return }
        if phase == .afterAbort, !requestIDs.isEmpty {
            try await container.perform(nonSendable: requestIDs) { context, requestIDs in
                for requestID in requestIDs {
                    self.labClearNativeMTPDrafterRecomputeDigest(requestID: requestID)
                    try await self.labRecomputeNativeMTPDrafterDigest(
                        targetModel: context.model,
                        requestID: requestID
                    )
                }
            }
        }
        for requestID in requestIDs {
            let digest = try nativeMTPStateDigest(requestID: requestID, transaction: nil)
            observer.record(NativeMTPStateDigestRecord(
                requestID: requestID,
                phase: phase,
                digestSHA256: digest.combined,
                cacheDigestSHA256: digest.cache,
                drafterDigestSHA256: digest.drafter,
                pendingTargetDigestSHA256: nil,
                drafterRecomputeDigestSHA256: digest.drafterRecompute,
                committedKVTokenCount: rowStateTokenCount(for: requestID),
                proposedTokens: 0,
                committedProposalTokens: nil
            ))
        }
    }
    #endif

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
            case .pagedAttention, .slidingWindow:
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
            if let window = row.recurrentWindow,
               window.endTokenCount != tokenCount,
               self.recurrentStateIDs(row.caches) == window.endState.map(ObjectIdentifier.init) {
                // The state is at the window end, past this boundary. Only a
                // checkpoint taken at exactly `tokenCount` is that state; with
                // none, fail closed rather than mislabel (SPEC-038 FR-CB4).
                return window.checkpoints.first { $0.tokenCount == tokenCount }
            }
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
                case .pagedAttention, .slidingWindow:
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
            nativeMTPDrafterStates.removeAll()
            nativeMTPDrafterSeedTokens.removeAll()
            nativeMTPPendingDrafterColumns.removeAll()
            #if DEBUG || MACPROVIDER_LAB_HARNESS
            nativeMTPDrafterRecomputeDigests.removeAll()
            labNativeMTPCommittedPrefixTokens.removeAll()
            labNativeMTPCommittedPrefixHidden.removeAll()
            labNativeMTPCommittedPrefixTargetBonus.removeAll()
            labNativeMTPPrefixPositionDeltasUnsupported.removeAll()
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

    /// Ends a running window at the next step boundary once `cancelInFlight`
    /// has started, instead of finishing every remaining step.
    private func throwIfCancelRequested() throws {
        lock.lock()
        let cancelled = cancelRequested
        lock.unlock()
        if cancelled {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
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
                case .slidingWindow(let windowTokens):
                    PagedKVCache(
                        blockSizeTokens: blockSizeTokens,
                        maxPhysicalBlocks: maxPhysicalBlocks,
                        poolEpoch: poolEpoch,
                        binding: binding,
                        initialOffset: initialOffset,
                        reconstructViaGather: false,
                        attentionWindowTokens: windowTokens
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
        steps: Int,
        onStep: ContinuousBatchDecodeWindowStepObserver? = nil
    ) throws -> [ContinuousBatchDecodeOutcome] {
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
        // Native rows riding this forward need the target hidden state of
        // every step for their drafter. Capture asks the target to emit it;
        // that output state is diagnostic only and never becomes row state.
        let captureIndices = drafterContainer == nil
            ? []
            : supportedInputs.indices.filter { supportedInputs[$0].captureNativeMTPDrafterColumns }
        if !captureIndices.isEmpty && rowStates.contains(where: { $0.state != nil }) {
            return supportedInputs.map { ContinuousBatchDecodeOutcome.rowFailure(requestID: $0.requestID) }
        }
        var capturedColumns: [Int: [(token: Int, hidden: MLXArray)]] = [:]

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
            && captureIndices.isEmpty
            && cacheKinds.allSatisfy({ $0 == .pagedAttention })
            && rowStates.allSatisfy({ $0.state == nil })
            && cachesAsKV.allSatisfy { !$0.innerState().isEmpty }

        let sampledByRow: [[Int]]
        // Set when the step observer ends the window because every row in it
        // is cancelled; their partially advanced state is then not recorded.
        var endedEarly = false
        // Hybrid rows that stop mid-window: recurrent state at the stop step
        // and the step after, by row index.
        var windowCheckpoints: [Int: [RecurrentStateCheckpoint]] = [:]
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
                try throwIfCancelRequested()
                // The compiled writeback assumes every target step ran, so
                // this path streams but never ends the window early.
                _ = onStep?(ContinuousBatchDecodeWindowStep(stepIndex: stepIndex, tokens: stepTokens))
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
            let checkpointStops = decodeSteps > 1 && cacheKinds.contains(.recurrentMamba)
            var stopStepByRow: [Int: Int] = [:]
            for stepIndex in 0 ..< decodeSteps {
                let tokenInput = MLXArray(currentTokens.map(Int32.init)).reshaped([supportedInputs.count, 1])
                let text = LMInput.Text(tokens: tokenInput)
                let stepState: LMOutput.State?
                if captureIndices.isEmpty {
                    stepState = supportedInputs.count == 1 ? rowStates[0].state : nil
                } else {
                    var emit = LMOutput.State()
                    emit[mtpEmitFlagKey] = true
                    stepState = emit
                }
                let output = withPreparedCache(cachesAsKV, lengths: text.sequenceLengths) {
                    model(text, cache: cachesAsKV, state: stepState)
                }
                if notePaddedAttentionBypass(batchedCaches, phase: "decode") {
                    // Fail closed before sampling; the rows' caches already
                    // took this step, so they are released, not retried.
                    storeDecodeSession(nil)
                    for input in supportedInputs {
                        removeRowState(for: input.requestID)
                    }
                    return supportedInputs.map { ContinuousBatchDecodeOutcome.rowFailure(requestID: $0.requestID) }
                }
                try batchedCaches.forEach { try $0.validateBatchState() }
                let stepSampled = ContinuousBatchRowSampler.sample(
                    logits: output.logits[0..., -1, 0...],
                    rows: Self.samplerRows(supportedInputs, step: stepIndex)
                ).asArray(Int.self)
                guard stepSampled.count == supportedInputs.count else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_logits_shape")
                }
                if !captureIndices.isEmpty {
                    guard let hidden = output.state?[mtpLastHiddenStatesKey],
                          hidden.ndim == 3,
                          hidden.dim(0) == supportedInputs.count,
                          hidden.dim(1) >= 1
                    else {
                        throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_decode_hidden_state")
                    }
                    for index in captureIndices {
                        capturedColumns[index, default: []].append((
                            token: stepSampled[index],
                            hidden: Self.detachedHiddenColumn(hidden, row: index)
                        ))
                    }
                } else if supportedInputs.count == 1 {
                    rowStates[0].state = output.state
                } else if output.state != nil {
                    return supportedInputs.map { ContinuousBatchDecodeOutcome.rowFailure(requestID: $0.requestID) }
                }
                for index in supportedInputs.indices {
                    collected[index].append(stepSampled[index])
                }
                if checkpointStops && stepIndex + 1 < decodeSteps {
                    for (index, input) in supportedInputs.enumerated() {
                        if stopStepByRow[index] == nil,
                           Self.endsWithStopSequence(
                               history: input.generatedTokens,
                               window: collected[index],
                               stopSequences: input.stopTokenSequences
                           ) {
                            stopStepByRow[index] = stepIndex
                        }
                        // After step i the state covers committed + i + 1
                        // tokens. A model stop at step k is covered through
                        // step k; a request stop also covers its stop token,
                        // which step k + 1 feeds.
                        guard let stopStep = stopStepByRow[index], stepIndex - stopStep <= 1 else { continue }
                        windowCheckpoints[index, default: []].append(recurrentRowCheckpoint(
                            batchedCaches,
                            row: index,
                            tokenCount: input.committedKVTokenCount + stepIndex + 1
                        ))
                    }
                }
                currentTokens = stepSampled
                try throwIfCancelRequested()
                if let onStep, !onStep(ContinuousBatchDecodeWindowStep(stepIndex: stepIndex, tokens: stepSampled)) {
                    endedEarly = stepIndex + 1 < decodeSteps
                    break
                }
            }
            sampledByRow = collected
            batchedCaches.forEach { $0.syncRowsFromBatch() }
        }

        // Every row ran the same steps: all of them, or fewer only when the
        // step observer ended the window.
        let ranSteps = sampledByRow.first?.count ?? 0
        guard sampledByRow.count == supportedInputs.count,
              ranSteps >= 1,
              ranSteps == decodeSteps || endedEarly,
              sampledByRow.allSatisfy({ $0.count == ranSteps }) else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_logits_shape")
        }
        // Hybrid recurrent decoders (Qwen3.5/Qwen3.8) are exact only when the
        // batched recurrent state is split back to rows at a token boundary.
        // Reusing a packed Mamba batch across windows can carry row-state at the
        // wrong boundary after long prefills, so force the next hybrid window to
        // rebuild from the just-synced row caches. KV-only layouts still keep the
        // reusable session that amortizes contiguous compiled decode. Inside a
        // window the packed state advances one token per step exactly as
        // one-step windows would; the window end is a token boundary.
        if endedEarly {
            // Every row is cancelled and about to be released. Its KV now ends
            // before its block table (extended for the full window), so it
            // must not be recorded for retention or reused as a session.
            storeDecodeSession(nil)
            for input in supportedInputs {
                removeRowState(for: input.requestID)
            }
            return zip(supportedInputs, sampledByRow).map { input, tokens in
                ContinuousBatchDecodeOutcome.output(ContinuousBatchDecodeOutput(
                    requestID: input.requestID,
                    tokens: tokens
                ))
            }
        }
        storeDecodeSession(cacheKinds.contains(.recurrentMamba) ? nil : session)
        if cacheKinds.contains(.recurrentMamba) {
            for (index, input) in supportedInputs.enumerated() {
                rowStates[index].recurrentWindow = RecurrentWindowRecord(
                    endTokenCount: input.committedKVTokenCount + ranSteps,
                    endState: recurrentStateArrays(rowStates[index].caches),
                    checkpoints: windowCheckpoints[index] ?? []
                )
            }
        }
        for (index, input) in supportedInputs.enumerated() {
            try self.setRowState(rowStates[index], for: input.requestID, binding: input.binding)
        }
        if !capturedColumns.isEmpty {
            eval(capturedColumns.values.flatMap { $0.map(\.hidden) })
            lock.lock()
            for (index, columns) in capturedColumns {
                nativeMTPPendingDrafterColumns[supportedInputs[index].requestID, default: []]
                    .append(contentsOf: columns)
            }
            lock.unlock()
        }
        return zip(supportedInputs, sampledByRow).map { input, tokens in
            ContinuousBatchDecodeOutcome.output(ContinuousBatchDecodeOutput(
                requestID: input.requestID,
                tokens: tokens
            ))
        }
    }

    /// True when the row's history (before the window, then this window's
    /// tokens) ends with one of its stop sequences: the scheduler's stop rule
    /// without copying the whole history every step.
    static func endsWithStopSequence(history: [Int], window: [Int], stopSequences: [[Int]]) -> Bool {
        stopSequences.contains { sequence in
            guard !sequence.isEmpty, sequence.count <= history.count + window.count else { return false }
            let fromHistory = history.suffix(max(0, sequence.count - window.count))
            return Array(fromHistory) + window.suffix(sequence.count - fromHistory.count) == sequence
        }
    }

    /// One row's recurrent state in the packed window batch, as a checkpoint.
    /// A gather allocates its own output, so evaluating it detaches the
    /// checkpoint from this step's packed state.
    private func recurrentRowCheckpoint(
        _ batchedCaches: [PagedKVSharedLayerBatch],
        row: Int,
        tokenCount: Int
    ) -> RecurrentStateCheckpoint {
        let rowIndex = MLXArray([Int32(row)])
        var states: [Int: [MLXArray]] = [:]
        for (index, kind) in cacheKinds.enumerated() where kind == .recurrentMamba {
            states[index] = batchedCaches[index].cache.state.map { $0.take(rowIndex, axis: 0) }
        }
        eval(states.values.flatMap { $0 })
        return RecurrentStateCheckpoint(tokenCount: tokenCount, states: states)
    }

    private func recurrentStateArrays(_ caches: [KVCache]) -> [MLXArray] {
        cacheKinds.indices
            .filter { cacheKinds[$0] == .recurrentMamba && caches.indices.contains($0) }
            .flatMap { caches[$0].state }
    }

    private func recurrentStateIDs(_ caches: [KVCache]) -> [ObjectIdentifier] {
        recurrentStateArrays(caches).map(ObjectIdentifier.init)
    }

    private func copyDecodeSession() -> DecodeSession? {
        lock.lock()
        defer { lock.unlock() }
        return decodeSession
    }

    /// Per-row target top-1 IDs (`proposalCount` proposal positions, then the
    /// bonus position) from one argmax and one host transfer per packed round.
    static func packedTopTokenIDs(rows: [(proposalLogits: MLXArray, bonusLogits: MLXArray)]) -> [[Int]] {
        var logits: [MLXArray] = []
        var counts: [Int] = []
        logits.reserveCapacity(rows.count * 2)
        counts.reserveCapacity(rows.count)
        for row in rows {
            var count = 0
            if row.proposalLogits.ndim == 2, row.proposalLogits.dim(0) > 0 {
                logits.append(row.proposalLogits)
                count += row.proposalLogits.dim(0)
            }
            logits.append(row.bonusLogits)
            count += row.bonusLogits.dim(0)
            counts.append(count)
        }
        guard !logits.isEmpty else { return rows.map { _ in [] } }
        let flat = argMax(concatenated(logits, axis: 0), axis: -1).asType(.int32).asArray(Int32.self)
        var result: [[Int]] = []
        result.reserveCapacity(rows.count)
        var start = 0
        for count in counts {
            result.append(flat[start ..< start + count].map(Int.init))
            start += count
        }
        return result
    }

    /// Per-row target-selected IDs at every verified position. Greedy rows
    /// take the argmax; a sampled row samples position `i` with its own
    /// sampler at step `samplerStep + i`, exactly the draw ordinary decode
    /// makes for the token at that step. The row sampler is a pure function
    /// of (seed, step, logits), so draws at rejected positions consume no
    /// state that a later emitted token depends on.
    static func packedTargetTokenIDs(
        rows: [(proposalLogits: MLXArray, bonusLogits: MLXArray)],
        samplers: [ContinuousBatchRowSampler.Row]
    ) -> [[Int]] {
        guard samplers.count == rows.count,
              samplers.contains(where: { $0.temperature != 0 }) else {
            return packedTopTokenIDs(rows: rows)
        }
        var logits: [MLXArray] = []
        var positionSamplers: [ContinuousBatchRowSampler.Row] = []
        var counts: [Int] = []
        for (row, sampler) in zip(rows, samplers) {
            var count = 0
            if row.proposalLogits.ndim == 2, row.proposalLogits.dim(0) > 0 {
                logits.append(row.proposalLogits)
                count += row.proposalLogits.dim(0)
            }
            logits.append(row.bonusLogits)
            count += row.bonusLogits.dim(0)
            for position in 0 ..< count {
                positionSamplers.append(ContinuousBatchRowSampler.Row(
                    temperature: sampler.temperature,
                    topP: sampler.topP,
                    samplerSeed: sampler.samplerSeed,
                    samplerStep: sampler.samplerStep + position
                ))
            }
            counts.append(count)
        }
        let flat = ContinuousBatchRowSampler.sample(
            logits: concatenated(logits, axis: 0),
            rows: positionSamplers
        ).asType(.int32).asArray(Int32.self)
        var result: [[Int]] = []
        result.reserveCapacity(rows.count)
        var start = 0
        for count in counts {
            result.append(flat[start ..< start + count].map(Int.init))
            start += count
        }
        return result
    }

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    private func labNativeMTPObserverInstalled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return labNativeMTPStateDigestObserver != nil
    }

    private static func labHiddenColumns(_ hidden: MLXArray, count: Int) throws -> [MLXArray] {
        guard hidden.ndim == 3, hidden.dim(0) == 1, hidden.dim(1) >= count else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_invalid_committed_hidden_history")
        }
        return (0..<count).map { hidden[0..., $0 ... $0, 0...] }
    }

    private func labRecordNativeMTPCommittedPrefix(
        requestID: String,
        tokens: [Int],
        hidden: [MLXArray],
        positionDeltas: MLXArray?,
        targetBonusToken: Int
    ) throws {
        guard labNativeMTPObserverInstalled(), !tokens.isEmpty else { return }
        guard tokens.count == hidden.count else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_drafter_recompute_shape_mismatch")
        }
        eval(hidden)
        lock.lock()
        labNativeMTPCommittedPrefixTokens[requestID, default: []].append(contentsOf: tokens)
        labNativeMTPCommittedPrefixHidden[requestID, default: []].append(contentsOf: hidden)
        labNativeMTPCommittedPrefixTargetBonus[requestID] = targetBonusToken
        if positionDeltas != nil {
            labNativeMTPPrefixPositionDeltasUnsupported.insert(requestID)
        }
        nativeMTPDrafterRecomputeDigests.removeValue(forKey: requestID)
        lock.unlock()
    }

    private func labNativeMTPFlushPrefixTokens(
        requestID: String,
        columns: [(token: Int, hidden: MLXArray)]
    ) throws -> [Int] {
        guard labNativeMTPObserverInstalled(), !columns.isEmpty else { return [] }
        lock.lock()
        let previousTargetBonus = labNativeMTPCommittedPrefixTargetBonus[requestID]
        lock.unlock()
        guard let previousTargetBonus else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_drafter_recompute_missing_target_bonus")
        }
        return [previousTargetBonus] + columns.dropLast().map(\.token)
    }

    private func labSnapshotNativeMTPPendingColumns(
        requestIDs: [String]
    ) -> [String: [(token: Int, hidden: MLXArray)]] {
        lock.lock()
        defer { lock.unlock() }
        var snapshot: [String: [(token: Int, hidden: MLXArray)]] = [:]
        for requestID in requestIDs {
            if let columns = nativeMTPPendingDrafterColumns[requestID], !columns.isEmpty {
                snapshot[requestID] = columns
            }
        }
        return snapshot
    }

    private func labClearNativeMTPDrafterRecomputeDigest(requestID: String) {
        lock.lock()
        nativeMTPDrafterRecomputeDigests.removeValue(forKey: requestID)
        lock.unlock()
    }

    private func labRecomputeNativeMTPDrafterDigest(
        targetModel: any LanguageModel,
        requestID: String
    ) async throws {
        guard labNativeMTPObserverInstalled(), let drafterContainer else { return }
        lock.lock()
        let tokens = labNativeMTPCommittedPrefixTokens[requestID] ?? []
        let hidden = labNativeMTPCommittedPrefixHidden[requestID] ?? []
        let unsupportedPositionDeltas = labNativeMTPPrefixPositionDeltasUnsupported.contains(requestID)
        let targetBonus = labNativeMTPCommittedPrefixTargetBonus[requestID]
        let actualSeed = nativeMTPDrafterSeedTokens[requestID]
        lock.unlock()
        guard actualSeed != nil, let targetBonus, !tokens.isEmpty else { return }
        guard tokens.count == hidden.count else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_drafter_recompute_shape_mismatch")
        }
        guard !unsupportedPositionDeltas else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_drafter_recompute_position_deltas_unsupported")
        }
        let prompt = MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
        let targetHidden = hidden.count == 1 ? hidden[0] : concatenated(hidden, axis: 1)
        let recomputed = try await drafterContainer.perform(
            nonSendable: (targetModel, prompt, targetHidden, targetBonus)
        ) { drafterContext, values in
            let (targetModel, prompt, targetHidden, targetBonus) = values
            guard let drafter = drafterContext.model as? any StatefulMTPDrafterModel else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_stateful_drafter_required")
            }
            var state = drafter.makeState(parameters: nil)
            drafter.prepareDrafterState(
                target: targetModel,
                promptTokens: prompt,
                targetHidden: targetHidden,
                firstBonus: MLXArray([Int32(targetBonus)]),
                positionDeltas: nil,
                state: &state,
                sampler: GenerateParameters(temperature: 0).sampler()
            )
            eval(state.cache.flatMap(\.state) + (state.seedToken.map { [$0] } ?? []))
            return (
                state: state,
                seed: state.seedToken?.asType(.int32).asArray(Int32.self).first.map(Int.init)
            )
        }
        let recomputedDigest = try Self.nativeMTPDrafterStateDigest(
            state: recomputed.state,
            seed: recomputed.seed,
            pendingColumns: []
        )
        // Packed advancement and full-prefix preparation use different matmul
        // shapes. SPEC-048 permits accumulation-order drift in drafter state;
        // retain its recomputed digest as evidence without rejecting finalize.
        lock.lock()
        nativeMTPDrafterRecomputeDigests[requestID] = recomputedDigest
        lock.unlock()
    }
    #endif

    private func nativeMTPDrafterState(for requestID: String) -> MTPDrafterState? {
        lock.lock()
        defer { lock.unlock() }
        return nativeMTPDrafterStates[requestID]
    }

    private func nativeMTPDrafterSeedToken(for requestID: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return nativeMTPDrafterSeedTokens[requestID]
    }

    private func storeNativeMTPDrafterAdvance(
        requestIDs: [String],
        states: [MTPDrafterState],
        seedTokens: [Int?]
    ) {
        lock.lock()
        for (index, requestID) in requestIDs.enumerated() {
            nativeMTPDrafterStates[requestID] = states[index]
            nativeMTPDrafterSeedTokens[requestID] = seedTokens[index]
        }
        lock.unlock()
    }

    private func prepareNativeMTPDrafterState(
        targetModel: any LanguageModel,
        prompt: MLXArray,
        targetHidden: MLXArray,
        positionDeltas: MLXArray?,
        firstBonusToken: Int,
        requestID: String
    ) async throws {
        guard let drafterContainer else { return }
        guard targetHidden.ndim == 3,
              targetHidden.dim(0) == 1,
              targetHidden.dim(1) >= prompt.dim(1)
        else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_invalid_prompt_hidden_state")
        }
        let prepared = try await drafterContainer.perform(
            nonSendable: (targetModel, prompt, targetHidden, firstBonusToken, positionDeltas)
        ) { drafterContext, values in
            let (targetModel, prompt, targetHidden, firstBonusToken, positionDeltas) = values
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
                positionDeltas: positionDeltas,
                state: &state,
                sampler: sampler
            )
            eval(state.cache.flatMap(\.state) + (state.seedToken.map { [$0] } ?? []))
            return (state: state, seed: state.seedToken?.asType(.int32).asArray(Int32.self).first.map(Int.init))
        }
        storeNativeMTPDrafterAdvance(requestIDs: [requestID], states: [prepared.state], seedTokens: [prepared.seed])
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        try labRecordNativeMTPCommittedPrefix(
            requestID: requestID,
            tokens: prompt.asArray(Int32.self).map(Int.init),
            hidden: try Self.labHiddenColumns(targetHidden, count: prompt.dim(1)),
            positionDeltas: positionDeltas,
            targetBonusToken: firstBonusToken
        )
        try await labRecomputeNativeMTPDrafterDigest(targetModel: targetModel, requestID: requestID)
        #endif
    }

    /// Advances a native row's drafter over one prompt chunk `[c, c+n)` of a
    /// chunked prefill: the drafter consumes `embed(prompt[c+1 ..< c+n+1])`
    /// paired with target hidden states `c ..< c+n`, at position `c`, which
    /// is the slice of the single-pass shifted-prompt seeding this chunk
    /// owns. The tail token is the next prompt token for a non-final chunk
    /// and the sampled first token for the final one. The first chunk starts
    /// from an empty drafter state; each later chunk must find the state the
    /// previous chunk left at exactly position `c`.
    private func advanceNativeMTPDrafterOverPromptChunk(
        targetModel: any LanguageModel,
        input: ContinuousBatchPrefillInput,
        targetHidden: MLXArray,
        positionDeltas: MLXArray?,
        tailToken: Int
    ) async throws {
        guard let drafterContainer else { return }
        let chunkCount = input.promptTokens.count
        guard targetHidden.ndim == 3,
              targetHidden.dim(0) == 1,
              targetHidden.dim(1) >= chunkCount
        else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_invalid_prompt_hidden_state")
        }
        let priorState: MTPDrafterState?
        if input.promptTokenOffset == 0 {
            priorState = nil
        } else {
            guard let stored = nativeMTPDrafterState(for: input.requestID),
                  stored.nextPosition == input.promptTokenOffset,
                  stored.proposalAppended == 0
            else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_drafter_state")
            }
            priorState = stored
        }
        let row = (
            hidden: targetHidden[0..., ..<chunkCount, 0...],
            acceptedTokens: Array(input.promptTokens.dropFirst()),
            positionDeltas: positionDeltas
        )
        let advanced = try await drafterContainer.perform(
            nonSendable: (targetModel, row, priorState)
        ) { drafterContext, values in
            let (targetModel, row, priorState) = values
            guard let drafter = drafterContext.model as? any MTPPackedStatefulDrafterModel else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_drafter_required")
            }
            let result = try drafter.advanceAndProposePacked(
                target: targetModel,
                rows: [MTPPackedDrafterAdvanceRow(
                    targetHidden: row.hidden,
                    acceptedTokens: row.acceptedTokens,
                    finalToken: tailToken,
                    positionDeltas: row.positionDeltas,
                    state: priorState ?? drafter.makeState(parameters: nil)
                )],
                sampler: GenerateParameters(temperature: 0).sampler()
            )
            guard let state = result.states.first else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_drafter_state")
            }
            eval(state.cache.flatMap(\.state) + [result.proposals])
            return (
                state: state,
                seed: result.proposals.asType(.int32).asArray(Int32.self).first.map(Int.init)
            )
        }
        // Only the final chunk's proposal follows a committed token; an
        // earlier chunk's would be a guess about the next prompt token.
        storeNativeMTPDrafterAdvance(
            requestIDs: [input.requestID],
            states: [advanced.state],
            seedTokens: [input.isFinalChunk ? advanced.seed : nil]
        )
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        try labRecordNativeMTPCommittedPrefix(
            requestID: input.requestID,
            tokens: input.promptTokens,
            hidden: try Self.labHiddenColumns(targetHidden, count: chunkCount),
            positionDeltas: positionDeltas,
            targetBonusToken: tailToken
        )
        try await labRecomputeNativeMTPDrafterDigest(targetModel: targetModel, requestID: input.requestID)
        #endif
    }

    /// Row `row`'s last-position hidden state as a `[1, 1, hidden]` array
    /// with its own buffer. A slice would share the whole `[B, T, hidden]`
    /// batch output, so a buffered column would pin every row's state; a
    /// gather always allocates its output, and evaluation detaches it from
    /// the batch output.
    static func detachedHiddenColumn(_ hidden: MLXArray, row: Int) -> MLXArray {
        hidden[0..., (-1)..., 0...].take(MLXArray([Int32(row)]), axis: 0)
    }

    /// Bounds each held row's buffer at `nativeMTPDrafterColumnCap`: a
    /// capturing row that this `steps`-step window would take past the cap
    /// catches its drafter up first, with one packed advance. A row whose
    /// drafter cannot advance fails alone and is left out of the window; its
    /// batch peers decode as usual.
    private func catchingUpNativeMTPDrafterColumnsAtCap(
        targetModel: any LanguageModel,
        inputs: [ContinuousBatchDecodeInput],
        steps: Int
    ) async -> (decodable: [ContinuousBatchDecodeInput], failed: [ContinuousBatchDecodeOutcome]) {
        let minimumColumns = max(1, nativeMTPDrafterColumnCap - steps + 1)
        let dueIDs = inputs.filter(\.captureNativeMTPDrafterColumns).map(\.requestID).filter {
            pendingNativeMTPDrafterColumnCount(for: $0) >= minimumColumns
        }
        guard !dueIDs.isEmpty else { return (inputs, []) }
        do {
            try await flushNativeMTPDrafterColumns(
                targetModel: targetModel,
                requestIDs: dueIDs,
                minimumColumns: minimumColumns
            )
            return (inputs, [])
        } catch {
            ContinuousBatchingPolicy.logForwardFailed(error)
            let failed = Set(dueIDs)
            return (
                inputs.filter { !failed.contains($0.requestID) },
                dueIDs.map { .rowFailure(requestID: $0) }
            )
        }
    }

    private func pendingNativeMTPDrafterColumnCount(for requestID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return nativeMTPPendingDrafterColumns[requestID]?.count ?? 0
    }

    private func hasPendingNativeMTPDrafterColumns(for requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !(nativeMTPPendingDrafterColumns[requestID]?.isEmpty ?? true)
    }

    /// Feeds each listed row's buffered depth-zero columns to its drafter
    /// with one packed advance for all rows holding at least
    /// `minimumColumns`: the columns are the row's committed tokens paired
    /// with the target hidden states that produced them, so the drafter ends
    /// where per-round depth-zero finalizes would have left it, and its seed
    /// is the proposal for the row's next token. Buffers clear only after the
    /// advanced states are stored.
    private func flushNativeMTPDrafterColumns(
        targetModel: any LanguageModel,
        requestIDs: [String],
        minimumColumns: Int
    ) async throws {
        guard let drafterContainer, !requestIDs.isEmpty else { return }
        let (flushIDs, advanceRows) = try pendingNativeMTPDrafterAdvanceRows(
            requestIDs: requestIDs,
            minimumColumns: minimumColumns
        )
        guard !advanceRows.isEmpty else { return }
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        let labPendingColumns = labSnapshotNativeMTPPendingColumns(requestIDs: flushIDs)
        #endif
        let advanced = try await drafterContainer.perform(
            nonSendable: (advanceRows, targetModel)
        ) { drafterContext, values in
            let (advanceRows, targetModel) = values
            guard let drafter = drafterContext.model as? any MTPPackedStatefulDrafterModel else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_drafter_required")
            }
            let result = try drafter.advanceAndProposePacked(
                target: targetModel,
                rows: advanceRows,
                sampler: GenerateParameters(temperature: 0).sampler()
            )
            eval(result.states.flatMap { $0.cache.flatMap(\.state) } + [result.proposals])
            return (
                states: result.states,
                seeds: result.proposals.asType(.int32).asArray(Int32.self).map(Int.init)
            )
        }
        guard advanced.states.count == flushIDs.count, advanced.seeds.count == flushIDs.count else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_drafter_state")
        }
        storeFlushedNativeMTPDrafterColumns(
            requestIDs: flushIDs,
            states: advanced.states,
            seedTokens: advanced.seeds
        )
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        for requestID in flushIDs {
            let columns = labPendingColumns[requestID] ?? []
            try labRecordNativeMTPCommittedPrefix(
                requestID: requestID,
                tokens: try labNativeMTPFlushPrefixTokens(requestID: requestID, columns: columns),
                hidden: columns.map(\.hidden),
                positionDeltas: nil,
                targetBonusToken: columns.last?.token ?? {
                    throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_drafter_column")
                }()
            )
            try await labRecomputeNativeMTPDrafterDigest(targetModel: targetModel, requestID: requestID)
        }
        #endif
    }

    private func pendingNativeMTPDrafterAdvanceRows(
        requestIDs: [String],
        minimumColumns: Int
    ) throws -> ([String], [MTPPackedDrafterAdvanceRow]) {
        lock.lock()
        defer { lock.unlock() }
        var flushIDs: [String] = []
        var advanceRows: [MTPPackedDrafterAdvanceRow] = []
        for requestID in requestIDs {
            guard let columns = nativeMTPPendingDrafterColumns[requestID],
                  columns.count >= max(1, minimumColumns)
            else { continue }
            guard let state = nativeMTPDrafterStates[requestID], let last = columns.last else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_drafter_state")
            }
            flushIDs.append(requestID)
            advanceRows.append(MTPPackedDrafterAdvanceRow(
                targetHidden: columns.count == 1
                    ? columns[0].hidden
                    : concatenated(columns.map(\.hidden), axis: 1),
                acceptedTokens: columns.dropLast().map(\.token),
                finalToken: last.token,
                positionDeltas: nil,
                state: state
            ))
        }
        return (flushIDs, advanceRows)
    }

    private func storeFlushedNativeMTPDrafterColumns(
        requestIDs: [String],
        states: [MTPDrafterState],
        seedTokens: [Int]
    ) {
        lock.lock()
        for (index, requestID) in requestIDs.enumerated() {
            nativeMTPDrafterStates[requestID] = states[index]
            nativeMTPDrafterSeedTokens[requestID] = seedTokens[index]
            nativeMTPPendingDrafterColumns.removeValue(forKey: requestID)
        }
        lock.unlock()
    }

    /// One packed drafter forward for every committing row. Returns `nil`
    /// when this backend has no drafter. Fails closed, before any state is
    /// staged, when a committing row has no drafter state.
    private func advanceNativeMTPDrafters(
        targetModel: any LanguageModel,
        rows: [(ContinuousBatchNativeMTPFinalizeInput, NativeMTPPendingTransaction)]
    ) async throws -> MTPPackedDrafterAdvanceResult? {
        guard let drafterContainer, !rows.isEmpty else { return nil }
        let advanceRows = try rows.map { input, transaction -> MTPPackedDrafterAdvanceRow in
            guard let state = nativeMTPDrafterState(for: input.requestID),
                  !hasPendingNativeMTPDrafterColumns(for: input.requestID)
            else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_drafter_state")
            }
            guard let finalTokenID = input.acceptedTokenIDs.last else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_finalize_accepted_tokens_mismatch")
            }
            return MTPPackedDrafterAdvanceRow(
                targetHidden: transaction.targetState.lastHidden,
                acceptedTokens: Array(transaction.proposalTokens.prefix(input.committedProposalTokenCount)),
                finalToken: finalTokenID,
                positionDeltas: transaction.targetState.positionDeltas,
                state: state
            )
        }
        return try await drafterContainer.perform(
            nonSendable: (advanceRows, targetModel)
        ) { drafterContext, values in
            let (advanceRows, targetModel) = values
            guard let drafter = drafterContext.model as? any MTPPackedStatefulDrafterModel else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_drafter_required")
            }
            return try drafter.advanceAndProposePacked(
                target: targetModel,
                rows: advanceRows,
                sampler: GenerateParameters(temperature: 0).sampler()
            )
        }
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
                    proposalTokens: input.proposalTokens,
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
        nativeMTPDrafterStates.removeValue(forKey: requestID)
        nativeMTPDrafterSeedTokens.removeValue(forKey: requestID)
        nativeMTPPendingDrafterColumns.removeValue(forKey: requestID)
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        nativeMTPDrafterRecomputeDigests.removeValue(forKey: requestID)
        labNativeMTPCommittedPrefixTokens.removeValue(forKey: requestID)
        labNativeMTPCommittedPrefixHidden.removeValue(forKey: requestID)
        labNativeMTPCommittedPrefixTargetBonus.removeValue(forKey: requestID)
        labNativeMTPPrefixPositionDeltasUnsupported.remove(requestID)
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

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    private func recordNativeMTPStateDigest(
        phase: NativeMTPStateDigestPhase,
        requestIDs: [String],
        transactions: [String: NativeMTPPendingTransaction]
    ) throws {
        lock.lock()
        let observer = labNativeMTPStateDigestObserver
        lock.unlock()
        guard let observer else { return }
        for requestID in requestIDs {
            guard let transaction = transactions[requestID] else { continue }
            let digest = try nativeMTPStateDigest(
                requestID: requestID,
                transaction: transaction
            )
            observer.record(NativeMTPStateDigestRecord(
                requestID: requestID,
                phase: phase,
                digestSHA256: digest.combined,
                cacheDigestSHA256: digest.cache,
                drafterDigestSHA256: digest.drafter,
                pendingTargetDigestSHA256: digest.pendingTarget,
                drafterRecomputeDigestSHA256: digest.drafterRecompute,
                committedKVTokenCount: rowStateTokenCount(for: requestID),
                proposedTokens: transaction.proposalTokenCount,
                committedProposalTokens: nil
            ))
        }
    }

    private func recordNativeMTPStateDigest(
        phase: NativeMTPStateDigestPhase,
        inputs: [ContinuousBatchNativeMTPFinalizeInput],
        transactions: [String: NativeMTPPendingTransaction]
    ) throws {
        lock.lock()
        let observer = labNativeMTPStateDigestObserver
        lock.unlock()
        guard let observer else { return }
        for input in inputs {
            let transaction = transactions[input.requestID]
            let digest = try nativeMTPStateDigest(
                requestID: input.requestID,
                transaction: transaction
            )
            observer.record(NativeMTPStateDigestRecord(
                requestID: input.requestID,
                phase: phase,
                digestSHA256: digest.combined,
                cacheDigestSHA256: digest.cache,
                drafterDigestSHA256: digest.drafter,
                pendingTargetDigestSHA256: digest.pendingTarget,
                drafterRecomputeDigestSHA256: digest.drafterRecompute,
                committedKVTokenCount: rowStateTokenCount(for: input.requestID),
                proposedTokens: transaction?.proposalTokenCount ?? input.proposalTokenCount,
                committedProposalTokens: input.committedProposalTokenCount
            ))
        }
    }

    private func rowStateTokenCount(for requestID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let row = rows[requestID] else { return 0 }
        return row.caches.map(\.offset).max() ?? 0
    }

    private func nativeMTPStateDigest(
        requestID: String,
        transaction: NativeMTPPendingTransaction?
    ) throws -> (combined: String, cache: String, drafter: String?, pendingTarget: String?, drafterRecompute: String?) {
        let cacheDigest = try rowTargetCacheDigest(requestID: requestID)
        let drafterDigest = try nativeMTPDrafterDigest(requestID: requestID)
        let pendingDigest = try transaction.flatMap { try nativeMTPPendingTargetDigest($0) }
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        lock.lock()
        let recomputeDigest = nativeMTPDrafterRecomputeDigests[requestID]
        lock.unlock()
        #else
        let recomputeDigest: String? = nil
        #endif
        var hasher = SHA256()
        Self.update(&hasher, label: "schema", value: "macprovider.native-mtp-state-observer.v1")
        Self.update(&hasher, label: "request_id", value: requestID)
        Self.update(&hasher, label: "cache", value: cacheDigest)
        Self.update(&hasher, label: "drafter", value: drafterDigest ?? "none")
        Self.update(&hasher, label: "pending_target", value: pendingDigest ?? "none")
        Self.update(&hasher, label: "drafter_recompute", value: recomputeDigest ?? "none")
        return (
            combined: Self.hexString(hasher.finalize()),
            cache: cacheDigest,
            drafter: drafterDigest,
            pendingTarget: pendingDigest,
            drafterRecompute: recomputeDigest
        )
    }

    private func rowTargetCacheDigest(requestID: String) throws -> String {
        lock.lock()
        let row = rows[requestID]
        lock.unlock()
        guard let row else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_observer_missing_row_state")
        }
        var hasher = SHA256()
        Self.update(&hasher, label: "kind", value: "row-cache")
        for (layerIndex, cache) in row.caches.enumerated() {
            Self.update(&hasher, label: "layer", value: String(layerIndex))
            Self.update(&hasher, label: "type", value: String(describing: type(of: cache)))
            Self.update(&hasher, label: "offset", value: String(cache.offset))
            let digestShape = try rowTargetCacheDigestShape(for: cache)
            switch digestShape {
            case .paged(let storedTokens, let blockSizeTokens):
                Self.update(&hasher, label: "paged_stored_tokens", value: String(storedTokens))
                Self.update(&hasher, label: "paged_block_size_tokens", value: String(blockSizeTokens))
            case .standard:
                break
            }
            let state = cache.state
            Self.update(&hasher, label: "slot_count", value: String(state.count))
            for (slotIndex, array) in state.enumerated() {
                try Self.updateArrayDigest(
                    &hasher,
                    label: "slot_\(slotIndex)",
                    array: array,
                    logicalTokens: digestShape.logicalTokens
                )
            }
        }
        return Self.hexString(hasher.finalize())
    }

    private enum RowTargetCacheDigestShape {
        case paged(storedTokens: Int, blockSizeTokens: Int)
        case standard(logicalTokens: Int?)

        var logicalTokens: Int? {
            switch self {
            case .paged(let storedTokens, _): return storedTokens
            case .standard(let logicalTokens): return logicalTokens
            }
        }
    }

    private func rowTargetCacheDigestShape(for cache: KVCache) throws -> RowTargetCacheDigestShape {
        if let paged = cache as? PagedKVCache {
            guard paged.attentionWindowTokens == nil else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_observer_unsupported_sliding_window_state")
            }
            guard paged.offset == paged.storedTokens else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_observer_paged_cache_offset_mismatch")
            }
            return .paged(storedTokens: paged.storedTokens, blockSizeTokens: paged.blockSizeTokens)
        }
        guard let cacheKind = CacheKind.recognized(from: cache) else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_observer_unsupported_cache_kind")
        }
        if case .slidingWindow = cacheKind {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_observer_unsupported_sliding_window_state")
        }
        return .standard(logicalTokens: cacheKind == .pagedAttention ? cache.offset : nil)
    }


    private enum LMOutputStateDigestEntry {
        case array(key: String, array: MLXArray)
        case scalar(key: String, value: String)

        var key: String {
            switch self {
            case .array(let key, _), .scalar(let key, _): return key
            }
        }
    }

    private static func updateLMOutputStateDigest(_ hasher: inout SHA256, state: LMOutput.State) throws {
        var entries: [LMOutputStateDigestEntry] = []
        if let lastHidden = state[mtpLastHiddenStatesKey] {
            entries.append(.array(key: "mtp.lastHiddenStates", array: lastHidden))
        }
        if let positionDeltas = state[mtpPositionDeltasKey] {
            entries.append(.array(key: "mtp.positionDeltas", array: positionDeltas))
        }
        if let sharedKV = state[mtpSharedKVStatesKey] {
            for key in sharedKV.keys.sorted() {
                guard let pair = sharedKV[key] else { continue }
                entries.append(.array(key: "mtp.sharedKVStates.\(key).k", array: pair.0))
                entries.append(.array(key: "mtp.sharedKVStates.\(key).v", array: pair.1))
            }
        }
        if let offsets = state[mtpSharedKVOffsetsKey] {
            for key in offsets.keys.sorted() {
                entries.append(.scalar(key: "mtp.sharedKVOffsets.\(key)", value: String(offsets[key] ?? 0)))
            }
        }
        if let sourceIndices = state[mtpSharedKVSourceIndicesKey] {
            for key in sourceIndices.keys.sorted() {
                entries.append(.scalar(key: "mtp.sharedKVSourceIndices.\(key)", value: String(sourceIndices[key] ?? 0)))
            }
        }
        update(&hasher, label: "lm_state_count", value: String(entries.count))
        for entry in entries.sorted(by: { $0.key < $1.key }) {
            update(&hasher, label: "lm_state_key", value: entry.key)
            switch entry {
            case .array(let key, let array):
                try updateArrayDigest(&hasher, label: "lm_state.\(key)", array: array)
            case .scalar(let key, let value):
                update(&hasher, label: "lm_state.\(key)", value: value)
            }
        }
    }

    private static func nativeMTPDrafterStateDigest(
        state: MTPDrafterState,
        seed: Int?,
        pendingColumns: [(token: Int, hidden: MLXArray)]
    ) throws -> String {
        var hasher = SHA256()
        update(&hasher, label: "kind", value: "drafter")
        update(&hasher, label: "next_position", value: String(state.nextPosition))
        update(&hasher, label: "proposal_appended", value: String(state.proposalAppended))
        guard state.nextPosition >= 0 else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_observer_invalid_drafter_position")
        }
        for (layerIndex, cache) in state.cache.enumerated() {
            update(&hasher, label: "layer", value: String(layerIndex))
            for (slotIndex, array) in cache.state.enumerated() {
                try updateArrayDigest(
                    &hasher,
                    label: "slot_\(slotIndex)",
                    array: array,
                    logicalTokens: state.nextPosition
                )
            }
        }
        update(&hasher, label: "seed", value: seed.map(String.init) ?? "none")
        update(&hasher, label: "pending_column_count", value: String(pendingColumns.count))
        for (index, column) in pendingColumns.enumerated() {
            update(&hasher, label: "pending_token_\(index)", value: String(column.token))
            try updateArrayDigest(&hasher, label: "pending_hidden_\(index)", array: column.hidden)
        }
        return hexString(hasher.finalize())
    }

    #if DEBUG
    static func nativeMTPDrafterDigestForTest(
        state: MTPDrafterState,
        seed: Int?,
        pendingColumns: [(token: Int, hidden: MLXArray)] = []
    ) throws -> String {
        try nativeMTPDrafterStateDigest(state: state, seed: seed, pendingColumns: pendingColumns)
    }
    #endif

    private func nativeMTPDrafterDigest(requestID: String) throws -> String? {
        lock.lock()
        let state = nativeMTPDrafterStates[requestID]
        let seed = nativeMTPDrafterSeedTokens[requestID]
        let pendingColumns = nativeMTPPendingDrafterColumns[requestID] ?? []
        lock.unlock()
        guard state != nil || seed != nil || !pendingColumns.isEmpty else { return nil }
        if let state {
            return try Self.nativeMTPDrafterStateDigest(
                state: state,
                seed: seed,
                pendingColumns: pendingColumns
            )
        }
        var hasher = SHA256()
        Self.update(&hasher, label: "kind", value: "drafter")
        Self.update(&hasher, label: "seed", value: seed.map(String.init) ?? "none")
        Self.update(&hasher, label: "pending_column_count", value: String(pendingColumns.count))
        for (index, column) in pendingColumns.enumerated() {
            Self.update(&hasher, label: "pending_token_\(index)", value: String(column.token))
            try Self.updateArrayDigest(&hasher, label: "pending_hidden_\(index)", array: column.hidden)
        }
        return Self.hexString(hasher.finalize())
    }

    private func nativeMTPPendingTargetDigest(_ transaction: NativeMTPPendingTransaction) throws -> String? {
        var hasher = SHA256()
        Self.update(&hasher, label: "kind", value: "pending-target")
        Self.update(&hasher, label: "proposal_count", value: String(transaction.proposalTokenCount))
        Self.update(&hasher, label: "current_token", value: String(transaction.currentToken))
        Self.update(&hasher, label: "proposal_tokens", value: transaction.proposalTokens.map(String.init).joined(separator: ","))
        try Self.updateArrayDigest(&hasher, label: "last_hidden", array: transaction.targetState.lastHidden)
        if let positionDeltas = transaction.targetState.positionDeltas {
            try Self.updateArrayDigest(&hasher, label: "position_deltas", array: positionDeltas)
        } else {
            Self.update(&hasher, label: "position_deltas", value: "none")
        }
        for (layerIndex, layer) in transaction.layers.enumerated() {
            Self.update(&hasher, label: "layer", value: String(layerIndex))
            Self.update(&hasher, label: "input_count", value: String(layer.inputTokenCount))
            Self.update(&hasher, label: "proposal_count", value: String(layer.proposalTokenCount))
        }
        return Self.hexString(hasher.finalize())
    }

    private static func updateArrayDigest(
        _ hasher: inout SHA256,
        label: String,
        array: MLXArray
    ) throws {
        try updateArrayDigest(&hasher, label: label, array: array, logicalTokens: nil)
    }

    private static func updateArrayDigest(
        _ hasher: inout SHA256,
        label: String,
        array: MLXArray,
        logicalTokens: Int?
    ) throws {
        switch array.dtype {
        case .float16, .bfloat16, .float32, .int32, .int64, .uint32, .uint64, .bool:
            break
        default:
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_observer_unsupported_dtype")
        }
        let canonical = try canonicalLogicalArray(array, logicalTokens: logicalTokens)
        let data = canonical.asData(access: .copy)
        update(&hasher, label: "\(label).dtype", value: String(describing: data.dType))
        update(&hasher, label: "\(label).dtype_bits", value: String(canonical.itemSize * 8))
        update(&hasher, label: "\(label).shape", value: data.shape.map(String.init).joined(separator: "x"))
        update(&hasher, label: "\(label).bytes", data: data.data)
    }

    private static func canonicalLogicalArray(
        _ array: MLXArray,
        logicalTokens: Int?
    ) throws -> MLXArray {
        guard let logicalTokens else { return array }
        guard logicalTokens >= 0, array.ndim >= 3 else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_observer_invalid_kv_shape")
        }
        let sequenceAxis = array.ndim - 2
        guard logicalTokens <= array.dim(sequenceAxis) else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_observer_logical_length_exceeds_state")
        }
        if logicalTokens == array.dim(sequenceAxis) { return array }
        return array[0 ..< logicalTokens, axis: sequenceAxis]
    }

    private static func update(_ hasher: inout SHA256, label: String, value: String) {
        update(&hasher, label: label, data: Data(value.utf8))
    }

    private static func update(_ hasher: inout SHA256, label: String, data: Data) {
        hasher.update(data: Data(label.utf8))
        hasher.update(data: Data([0]))
        var count = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
        hasher.update(data: Data([0xff]))
    }

    private static func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    #endif

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

    /// A row's stored drafter state, next proposal, and buffered depth-zero
    /// column count.
    func nativeMTPDrafterSnapshotForTest(
        requestID: String
    ) -> (state: MTPDrafterState?, seedToken: Int?, pendingColumns: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (
            nativeMTPDrafterStates[requestID],
            nativeMTPDrafterSeedTokens[requestID],
            nativeMTPPendingDrafterColumns[requestID]?.count ?? 0
        )
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

    static func batchLayerMaskForTest(
        rowCaches: [PagedKVCache],
        n: Int,
        windowSize: Int?
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        PagedKVBatchLayerCache(rowCaches: rowCaches).makeMask(
            n: n,
            windowSize: windowSize,
            returnArray: true
        )
    }

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    /// One uncompiled shared decode window over retained rows, as
    /// `performDecode` runs it: the batch caches are built once, `steps`
    /// forwards run on them with each row's greedy token fed back, and rows
    /// are synced at the window end. Returns each step's last-position logits
    /// per row as float32 (`[step][row][vocab]`). Decode-isolation probes
    /// compare these bits against the same rows decoded alone.
    func sharedDecodeLogitsForTest(requestIDs: [String], tokens: [Int], steps: Int = 1) async throws -> [[[Float]]] {
        try await container.perform { context in
            let states = try requestIDs.map { id -> RowState in
                guard let state = self.existingRowState(for: id), state.state == nil else {
                    throw ContinuousBatchSchedulerError.unsupported("decode_probe_missing_row")
                }
                return state
            }
            let batchedCaches = try self.makeBatchedCaches(from: states.map(\.caches))
            let caches = batchedCaches.map(\.cache)
            var current = tokens
            var perStep: [[[Float]]] = []
            for _ in 0 ..< max(1, steps) {
                let text = LMInput.Text(tokens: MLXArray(current.map(Int32.init)).reshaped([current.count, 1]))
                let output = withPreparedCache(caches, lengths: text.sequenceLengths) {
                    context.model(text, cache: caches, state: nil)
                }
                try batchedCaches.forEach { try $0.validateBatchState() }
                let logits = output.logits[0..., -1, 0...].asType(.float32)
                eval(logits)
                let vocabulary = logits.dim(1)
                let flat = logits.asArray(Float.self)
                let rows = (0 ..< requestIDs.count).map { Array(flat[$0 * vocabulary ..< ($0 + 1) * vocabulary]) }
                current = rows.map { row in row.indices.max { row[$0] < row[$1] }! }
                perStep.append(rows)
            }
            batchedCaches.forEach { $0.syncRowsFromBatch() }
            eval(states.flatMap(\.caches))
            return perStep
        }
    }

    /// One packed native-MTP verification forward over retained rows, as
    /// `verifyNativeMTPPackedRound` runs it, returning each row's logits for
    /// its real columns (`[inputCount * vocab]` float32, proposal rows then
    /// the bonus row). Nothing is committed and no transaction is kept, so a
    /// probe compares one verify step per prefilled state.
    func sharedVerifyLogitsForTest(requestIDs: [String], tokenRows: [[Int]]) async throws -> [[Float]] {
        try await container.perform { context in
            let states = try requestIDs.map { id -> RowState in
                guard let state = self.existingRowState(for: id), state.state == nil else {
                    throw ContinuousBatchSchedulerError.unsupported("verify_probe_missing_row")
                }
                return state
            }
            let batchedCaches = try self.makeBatchedCaches(from: states.map(\.caches), nativeMTP: true)
            let width = tokenRows.map(\.count).max() ?? 1
            let tokens = MLXArray(
                tokenRows.flatMap { $0.map(Int32.init) + Array(repeating: Int32(0), count: width - $0.count) },
                [tokenRows.count, width]
            )
            let rowMaps = tokenRows.enumerated().map { index, row in
                MTPPackedVerificationRowMap(
                    rowIndex: index,
                    queryOffset: states[index].caches.compactMap { $0 as? PagedKVCache }.first?.offset ?? 0,
                    inputCount: row.count,
                    proposalCount: row.count - 1
                )
            }
            let output = try verifyMTPPackedTargets(
                model: context.model,
                tokens: tokens,
                rowMaps: rowMaps,
                cache: batchedCaches.map(\.cache)
            )
            let perRow = output.rows.sorted { $0.map.rowIndex < $1.map.rowIndex }.map {
                concatenated([$0.proposalLogits, $0.bonusLogits], axis: 0).asType(.float32)
            }
            eval(perRow)
            return perRow.map { $0.asArray(Float.self) }
        }
    }

    /// One attention layer of a shared forward through the batch cache the
    /// backend builds for it (`raggedPrefill` selects the ragged prefill
    /// cache; `mtpPackedRowMaps` prepares packed MTP verification), with the
    /// mask the model asks that cache for, attended through
    /// `attentionWithCacheUpdate` as the served models do. Packed rows are
    /// not committed; other rows' caches keep the update.
    static func batchAttentionForTest(
        rowCaches: [PagedKVCache],
        queries: MLXArray,
        keys: MLXArray,
        values: MLXArray,
        scale: Float,
        raggedPrefill: Bool = false,
        mtpPackedRowMaps: [MTPPackedVerificationRowMap]? = nil,
        maskOverride: MLXFast.ScaledDotProductAttentionMaskMode? = nil
    ) throws -> MLXArray {
        let cache = raggedPrefill
            ? PagedKVRaggedPrefillBatchLayerCache(rowCaches: rowCaches)
            : PagedKVBatchLayerCache(rowCaches: rowCaches)
        if let mtpPackedRowMaps {
            try cache.prepareMTPPackedVerification(rowMaps: mtpPackedRowMaps)
        }
        let mask = maskOverride ?? cache.makeMask(n: queries.dim(2), windowSize: nil, returnArray: false)
        let attended = attentionWithCacheUpdate(
            queries: queries,
            keys: keys,
            values: values,
            cache: cache,
            scale: scale,
            mask: mask
        )
        eval(attended)
        cache.syncRowsFromBatch()
        cache.finalize()
        return attended
    }

    /// Several consecutive decode steps through ONE shared decode batch
    /// cache, as a lockstep window runs them (rows keep their own lengths and
    /// the cache appends in place between steps). Returns each step's
    /// attention output.
    static func batchAttentionWindowForTest(
        rowCaches: [PagedKVCache],
        steps: [(queries: MLXArray, keys: MLXArray, values: MLXArray)],
        scale: Float
    ) -> [MLXArray] {
        let cache = PagedKVBatchLayerCache(rowCaches: rowCaches)
        let outputs = steps.map { step -> MLXArray in
            let mask = cache.makeMask(n: step.queries.dim(2), windowSize: nil, returnArray: false)
            let attended = attentionWithCacheUpdate(
                queries: step.queries,
                keys: step.keys,
                values: step.values,
                cache: cache,
                scale: scale,
                mask: mask
            )
            eval(attended)
            return attended
        }
        cache.syncRowsFromBatch()
        return outputs
    }
    #endif

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
            let hostOffsetsBeforeUpdate = cache.mtpPackedHostBatchOffsets
            let updated = cache.update(keys: keys, values: values)
            let batchOffsetsAfterUpdate = cache.batchOffset.asArray(Int.self)
            let hostOffsetsAfterUpdate = cache.mtpPackedHostBatchOffsets
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
                hostBatchOffsetsBeforeUpdate: hostOffsetsBeforeUpdate,
                batchOffsetsAfterUpdate: batchOffsetsAfterUpdate,
                hostBatchOffsetsAfterUpdate: hostOffsetsAfterUpdate,
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
        committedInputCounts: [Int?],
        stagedCommit: Bool = false
    ) throws -> PagedKVMTPPackedCacheResolutionResult {
        guard committedInputCounts.count == rowMaps.count else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_resolution_count_mismatch")
        }
        return try Device.withDefaultDevice(.cpu) {
            let cache = PagedKVBatchLayerCache(rowCaches: rowCaches)
            try cache.prepareMTPPackedVerification(rowMaps: rowMaps)
            cache.prepare(lengths: rowMaps.map(\.inputCount))
            let incoming = (0 ..< rowCaches.count * width).map { Float($0 + 1) }
            let keys = MLXArray(incoming, [rowCaches.count, 1, width, 1])
            let values = MLXArray(incoming.map { $0 + 1_000 }, [rowCaches.count, 1, width, 1])
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
            var staged: [MLXArray] = []
            for (index, inputCount) in committedInputCounts.enumerated() {
                guard let inputCount else { continue }
                if stagedCommit {
                    staged += try pendingAfterFinalize[index].stageCommit(inputCount: inputCount)
                } else {
                    try pendingAfterFinalize[index].commit(inputCount: inputCount)
                }
            }
            eval(staged)
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
                },
                rowStateValuesAfterResolution: rowCaches.map { row -> [Float] in
                    row.state.flatMap { $0.asType(.float32).asArray(Float.self) }
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
        nativeMTP: Bool = false,
        raggedPrefill: Bool = false
    ) throws -> [PagedKVSharedLayerBatch] {
        guard let layerCount = rowCaches.first?.count,
              rowCaches.allSatisfy({ $0.count == layerCount }),
              layerCount == cacheKinds.count
        else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
        }
        return try (0 ..< layerCount).map { layerIndex in
            switch cacheKinds[layerIndex] {
            case .pagedAttention, .slidingWindow:
                let rows = rowCaches.compactMap { $0[layerIndex] as? PagedKVCache }
                guard rows.count == rowCaches.count else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
                }
                let cache = raggedPrefill
                    ? PagedKVRaggedPrefillBatchLayerCache(rowCaches: rows)
                    : PagedKVBatchLayerCache(rowCaches: rows)
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

/// Per-row causal mask for a ragged shared prefill (SPEC-038 FR-CB2): row `b`
/// adds `queryTokens` tokens at absolute positions `rowOffsets[b] ..<
/// rowOffsets[b] + queryTokens`, and its keys are stored left-aligned and
/// right-padded to the longest row. Query `q` of row `b` attends key `j` iff
/// `j <= rowOffsets[b] + q` (inside the window, when one is set), which also
/// excludes every padded key of a shorter row. Shape `[B, 1, queryTokens,
/// max(rowOffsets) + queryTokens]`, built with array ops once per forward.
enum PagedKVRaggedPrefillMask {
    static func make(queryTokens: Int, rowOffsets: [Int], windowSize: Int?) -> MLXArray {
        let keyCount = (rowOffsets.max() ?? 0) + queryTokens
        let keyPositions = MLXArray(Int32(0) ..< Int32(keyCount))
            .reshaped([1, 1, 1, keyCount])
        let queryPositions = MLXArray(rowOffsets.map(Int32.init))
            .reshaped([rowOffsets.count, 1, 1, 1])
            + MLXArray(Int32(0) ..< Int32(queryTokens)).reshaped([1, 1, queryTokens, 1])
        var mask = keyPositions .<= queryPositions
        if let windowSize {
            mask = mask .&& (queryPositions .< keyPositions + MLXArray(Int32(windowSize)))
        }
        return mask
    }
}

/// The batch cache of a ragged shared prefill (SPEC-038 FR-CB2). Its rows
/// attend over their own keys like every batch cache
/// (`PagedKVBatchLayerCache.updateAndAttend`); the type marks a ragged
/// forward so the backend can reject it when the model attended outside
/// that path.
private final class PagedKVRaggedPrefillBatchLayerCache: PagedKVBatchLayerCache {}

/// One row's share of a batched attention call: its query columns, its own
/// keys (left-aligned in the batch buffer) and the mask its lone call takes.
struct PagedKVRowAttentionExtent: Equatable {
    let queryTokens: Int
    let keyTokens: Int
}

/// The vector attention route MLX core takes for a call (query length at
/// most 8), ported from core fork `Augustas11/mlx` tag
/// `v0.32.2-macprovider.2`, `mlx/backend/metal/scaled_dot_product_attention.cpp`:
/// vector mode at line 812 (`q_pre.shape(2) <= 8`), one vs two passes at
/// line 875, the `_gqa` first-pass kernel at lines 469-473, the partition
/// count at lines 486-523 (with the `MLX_SDPA_BLOCKS` override at 519).
/// Within one route a row's result does not depend on padding: both kernels
/// (`kernels/sdpa_vector.h`) deal key `i` to partition `i mod P`, skip
/// masked keys, and reduce the `P` partials in a fixed order. A rebase that
/// changes that dispatch must update this port; the route-table test and the
/// cache-level bitwise tests fail when a boundary moves (runbook per-rebase
/// gate). An unknown route never shares the padded call.
enum PagedKVVectorAttentionRoute {
    struct Route: Equatable {
        let twoPass: Bool
        let partitions: Int
        let gqaKernel: Bool
    }

    /// The Metal architecture name core reads, and its `MLX_SDPA_BLOCKS`
    /// override (rounded up to 32 as core does).
    static let deviceArchitecture: String = ModelRuntime.metalArchitectureForQuantizedRoutes()
    static let partitionOverride: Int? = {
        guard let raw = ProcessInfo.processInfo.environment["MLX_SDPA_BLOCKS"],
              let value = Int(raw), value > 0
        else { return nil }
        return ((value + 31) / 32) * 32
    }()

    static func route(
        keyTokens n: Int,
        queryTokens: Int,
        queryHeads: Int,
        kvHeads: Int,
        headDim: Int,
        valueDim: Int,
        hasArrayMask: Bool,
        architecture: String,
        partitionOverride: Int?
    ) -> Route? {
        guard queryTokens >= 1, queryTokens <= 8, kvHeads > 0, queryHeads % kvHeads == 0,
              let device = architecture.last
        else { return nil }
        let large = device == "d" || device == "s"
        let twoPass = (large && n >= 1024) || (kvHeads < queryHeads && n >= 4096)
        guard twoPass else { return Route(twoPass: false, partitions: 32, gqaKernel: false) }
        let gqaKernel = !hasArrayMask && queryTokens == 1 && queryHeads == 8 * kvHeads
            && headDim == valueDim && (headDim == 64 || headDim == 128) && n >= 8192
        let simdGroups = (queryHeads / kvHeads) * queryTokens
        var partitions: Int
        if device == "s" {
            partitions = 64
            if n > 1024 && simdGroups > 4 {
                partitions = n <= 8192 ? 128 : n <= 32768 ? 256 : n <= 65536 ? 512 : 1024
            }
        } else if device == "d" {
            partitions = 128
            if simdGroups <= 2 && n > 8192 {
                partitions = 256
            } else if simdGroups >= 6 {
                if n >= 16384 && n < 65536 {
                    partitions = 512
                } else if n >= 65536 {
                    partitions = 1024
                }
            }
        } else {
            partitions = simdGroups >= 4 ? 64 : 32
        }
        if let partitionOverride { partitions = partitionOverride }
        return Route(twoPass: true, partitions: partitions, gqaKernel: gqaKernel)
    }

    /// Rows whose lone call takes the padded call's route, so the padded call
    /// gives them their lone bits. Empty when the call is not a vector call,
    /// the padded call has no array mask (it would then attend padding), or
    /// the architecture is unknown.
    static func rowsMatchingPaddedCall(
        extents: [PagedKVRowAttentionExtent],
        queryTokens: Int,
        paddedKeyTokens: Int,
        queryHeads: Int,
        kvHeads: Int,
        headDim: Int,
        valueDim: Int,
        paddedCallHasArrayMask: Bool,
        loneCallHasArrayMask: Bool,
        architecture: String = deviceArchitecture,
        partitionOverride: Int? = partitionOverride
    ) -> Set<Int> {
        guard paddedCallHasArrayMask,
              let padded = route(
                  keyTokens: paddedKeyTokens,
                  queryTokens: queryTokens,
                  queryHeads: queryHeads,
                  kvHeads: kvHeads,
                  headDim: headDim,
                  valueDim: valueDim,
                  hasArrayMask: true,
                  architecture: architecture,
                  partitionOverride: partitionOverride
              )
        else { return [] }
        return Set(extents.indices.filter { row in
            let extent = extents[row]
            return extent.queryTokens == queryTokens
                && route(
                    keyTokens: extent.keyTokens,
                    queryTokens: extent.queryTokens,
                    queryHeads: queryHeads,
                    kvHeads: kvHeads,
                    headDim: headDim,
                    valueDim: valueDim,
                    hasArrayMask: loneCallHasArrayMask,
                    architecture: architecture,
                    partitionOverride: partitionOverride
                ) == padded
        })
    }
}

enum PagedKVRowAttention {
    /// Per-row extents when one batched SDPA call would not give every row
    /// its lone bits, else nil (one call is exact). Rows whose keys or query
    /// columns are padded to a longer neighbour need their own call:
    /// - decode and ragged prefill: row `b` holds `offsetsBefore[b] + L` keys
    ///   and all `L` query columns;
    /// - packed MTP verification: row `b` holds `queryOffset + inputCount`
    ///   keys and its first `inputCount` columns are real.
    static func extents(
        queryTokens: Int,
        offsetsBefore: [Int],
        packedRows: [(queryOffset: Int, inputCount: Int)]?
    ) -> [PagedKVRowAttentionExtent]? {
        guard offsetsBefore.count > 1, queryTokens > 0 else { return nil }
        let extents: [PagedKVRowAttentionExtent]
        if let packedRows {
            guard packedRows.count == offsetsBefore.count,
                  packedRows.allSatisfy({ $0.inputCount >= 1 && $0.inputCount <= queryTokens && $0.queryOffset >= 0 })
            else { return nil }
            extents = packedRows.map {
                PagedKVRowAttentionExtent(queryTokens: $0.inputCount, keyTokens: $0.queryOffset + $0.inputCount)
            }
        } else {
            guard offsetsBefore.allSatisfy({ $0 >= 0 }) else { return nil }
            extents = offsetsBefore.map {
                PagedKVRowAttentionExtent(queryTokens: queryTokens, keyTokens: $0 + queryTokens)
            }
        }
        let padded = Set(extents.map(\.keyTokens)).count > 1
            || extents.contains { $0.queryTokens < queryTokens }
        return padded ? extents : nil
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

    /// Publish this layer's committed row state and return the arrays to
    /// evaluate. Finalize evaluates every row and layer of a round together.
    func stageCommit(inputCount: Int) throws -> [MLXArray] {
        switch self {
        case .pagedAttention(let resolution):
            try resolution.stageCommit(inputCount: inputCount)
        case .recurrent(let resolution):
            try resolution.stageCommit(retaining: inputCount)
        }
    }
}

private class PagedKVBatchLayerCache: MTPPackedVerificationCache, KVCacheAttentionProtocol, @unchecked Sendable {
    fileprivate struct PendingMTPResolution {
        let rowCache: PagedKVCache
        let inputTokenCount: Int
        let proposalTokenCount: Int
        let inputKeys: MLXArray
        let inputValues: MLXArray

        func commit(inputCount: Int) throws {
            eval(try stageCommit(inputCount: inputCount))
        }

        /// Write the accepted prefix into the row cache without evaluating it;
        /// returns the arrays `commit` would have evaluated.
        func stageCommit(inputCount: Int) throws -> [MLXArray] {
            guard inputCount >= 0, inputCount <= inputTokenCount else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_finalize_input_count_mismatch")
            }
            guard inputCount > 0 else { return [] }
            let keySlice = inputKeys[0..., 0..., 0 ..< inputCount, 0...]
            let valueSlice = inputValues[0..., 0..., 0 ..< inputCount, 0...]
            let updated = rowCache.update(keys: keySlice, values: valueSlice)
            return [updated.0, updated.1]
        }
    }

    fileprivate let rowCaches: [PagedKVCache]
    private var preparedLengths: [Int]?
    fileprivate var preparedMTPPackedRowMaps: [MTPPackedVerificationRowMap]?
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
        MLXArray(hostBatchOffsets.map(Int32.init))
    }

    /// Host integers `batchOffset` is built from. The packed-verify facade
    /// validates row positions against these instead of a per-layer device
    /// readback.
    var mtpPackedHostBatchOffsets: [Int]? {
        hostBatchOffsets
    }

    private var hostBatchOffsets: [Int] {
        if mtpPackedForwardDidUpdate, let rowMaps = preparedMTPPackedRowMaps {
            return rowMaps.map { $0.queryOffset + $0.inputCount }
        }
        return preUpdateOffsets
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

    /// Set while `updateAndAttend` runs this layer's update.
    private var insideUpdateAndAttend = false
    /// True once a padded update (rows of different key extents) reached
    /// this cache without `updateAndAttend`: the model called SDPA itself
    /// over the padded batch, so its rows' attention followed the padded
    /// route (SPEC-038 FR-CB2). The backend fails that forward.
    private(set) var attendedOutsideCachePath = false

    func update(keys incomingKeys: MLXArray, values incomingValues: MLXArray) -> (MLXArray, MLXArray) {
        if !insideUpdateAndAttend,
           incomingKeys.ndim == 4,
           PagedKVRowAttention.extents(
               queryTokens: incomingKeys.dim(2),
               offsetsBefore: preUpdateOffsets,
               packedRows: preparedMTPPackedRowMaps?.map { (queryOffset: $0.queryOffset, inputCount: $0.inputCount) }
           ) != nil
        {
            attendedOutsideCachePath = true
        }
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
            let incomingTokenCount = incomingKeys.dim(2)
            let newKeys = Self.write(incomingKeys, into: existingKeys, rowStarts: nil, stored: start, maxTokens: maxSize, blockSizeTokens: blockSizeTokens)
                ?? concatenated([Self.prefix(existingKeys, start), incomingKeys], axis: 2)
            let newValues = Self.write(incomingValues, into: existingValues, rowStarts: nil, stored: start, maxTokens: maxSize, blockSizeTokens: blockSizeTokens)
                ?? concatenated([Self.prefix(existingValues, start), incomingValues], axis: 2)
            keys = newKeys
            values = newValues
            length = start + incomingTokenCount
            rowMutationCounts = nil
            batchedOffset = (batchedOffset ?? offset) + incomingTokenCount
            return presentation(
                keys: Self.prefix(newKeys, length),
                values: Self.prefix(newValues, length),
                priorTokens: start,
                incomingTokens: incomingTokenCount
            )
        }
        if allowsLockstepConcat, keys == nil, values == nil {
            keys = Self.prefix(incomingKeys, incomingKeys.dim(2))
            values = Self.prefix(incomingValues, incomingValues.dim(2))
            length = incomingKeys.dim(2)
            rowMutationCounts = nil
            batchedOffset = incomingKeys.dim(2)
            return presentation(
                keys: incomingKeys,
                values: incomingValues,
                priorTokens: 0,
                incomingTokens: incomingKeys.dim(2)
            )
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

    /// SPEC-038 FR-CB2 row isolation for attention. Rows of different lengths
    /// share one buffer, left-aligned and zero-padded to the longest row. One
    /// SDPA call over that buffer masks the padding, so the math is per row,
    /// but MLX core picks its kernel from the padded shape: the vector
    /// (decode/verify) kernels choose one or two passes and the two-pass
    /// partition count from the key length, and the unfused prompt path
    /// (head dims 192/256) blocks its GEMMs by it. Either can change a row's
    /// floating-point reduction order with its neighbours.
    ///
    /// For prompt chunks every padded row attends in its own call over exactly
    /// its own keys with the causal mask. For the vector kernels a padded row
    /// keeps its lone bits whenever its own key length selects the same route
    /// as the padded call (`PagedKVVectorAttentionRoute`): both kernels deal
    /// key `i` to partition `i mod P` and skip masked keys. So one batched
    /// call serves every row whose lone route equals the padded call's, and
    /// only the others (a short row below the two-pass switch, a row in
    /// another partition-count class, a narrower verify row) attend in their
    /// own call with the mask their lone call takes: none for one decode
    /// token, their slice of the packed mask for MTP verification. Rows of
    /// one length, and a model that calls SDPA itself, keep the single call.
    /// Every other operator stays batched.
    func updateAndAttend(
        queries: MLXArray,
        keys incomingKeys: MLXArray,
        values incomingValues: MLXArray,
        scale: Float,
        mask: MLXFast.ScaledDotProductAttentionMaskMode
    ) -> MLXArray {
        let queryTokens = queries.dim(2)
        let packedRows = preparedMTPPackedRowMaps?.map { (queryOffset: $0.queryOffset, inputCount: $0.inputCount) }
        let offsetsBefore = preUpdateOffsets
        insideUpdateAndAttend = true
        let (keys, values) = update(keys: incomingKeys, values: incomingValues)
        insideUpdateAndAttend = false
        func batched() -> MLXArray {
            MLXFast.scaledDotProductAttention(queries: queries, keys: keys, values: values, scale: scale, mask: mask)
        }
        guard let extents = PagedKVRowAttention.extents(
                  queryTokens: queryTokens,
                  offsetsBefore: offsetsBefore,
                  packedRows: packedRows
              ),
              // Sliding-window rows present a trimmed suffix; their columns
              // are not absolute positions.
              rowCaches.allSatisfy({ $0.attentionWindowTokens == nil }),
              queries.dim(0) == rowCaches.count,
              keys.dim(0) == rowCaches.count,
              keys.dim(2) == extents.map(\.keyTokens).max(),
              // Every row's buffer holds exactly its own keys: the stored
              // history is the row's whole history, plus this call's tokens
              // unless verification only staged them.
              packedRows == nil
                  ? rowCaches.enumerated().allSatisfy({
                      $0.element.offset == extents[$0.offset].keyTokens
                          && $0.element.storedTokens == extents[$0.offset].keyTokens
                  })
                  : mtpPackedForwardDidUpdate && rowCaches.enumerated().allSatisfy({
                      $0.element.storedTokens == offsetsBefore[$0.offset]
                  }),
              // Split rows take their lone call's mask, which is equivalent
              // only to the masks this cache builds. Any other array mask
              // keeps the single call with the mask as given.
              PagedKVBatchLayerCache.maskIsCacheBuilt(mask)
        else {
            return batched()
        }
        var packedMask: MLXArray?
        if packedRows != nil {
            guard case .array(let array) = mask,
                  array.ndim == 4,
                  array.dim(0) == rowCaches.count,
                  array.dim(2) == queryTokens,
                  array.dim(3) == keys.dim(2)
            else {
                return batched()
            }
            packedMask = array
        }
        // Rows the one padded call already gives their lone bits.
        let sharedRows = PagedKVVectorAttentionRoute.rowsMatchingPaddedCall(
            extents: extents,
            queryTokens: queryTokens,
            paddedKeyTokens: keys.dim(2),
            queryHeads: queries.dim(1),
            kvHeads: keys.dim(1),
            headDim: queries.dim(3),
            valueDim: values.dim(3),
            paddedCallHasArrayMask: { if case .array = mask { return true } else { return false } }(),
            loneCallHasArrayMask: packedRows != nil
        )
        let shared = sharedRows.isEmpty ? nil : batched()
        return concatenated(extents.enumerated().map { row, extent in
            if let shared, sharedRows.contains(row) {
                return shared[row ..< row + 1, 0..., 0..., 0...]
            }
            let rowMask: MLXFast.ScaledDotProductAttentionMaskMode
            if let packedMask {
                rowMask = .array(packedMask[row ..< row + 1, 0..., ..<extent.queryTokens, ..<extent.keyTokens])
            } else {
                rowMask = extent.queryTokens > 1 ? .causal : .none
            }
            let attended = MLXFast.scaledDotProductAttention(
                queries: queries[row ..< row + 1, 0..., ..<extent.queryTokens, 0...],
                keys: keys[row ..< row + 1, 0..., ..<extent.keyTokens, 0...],
                values: values[row ..< row + 1, 0..., ..<extent.keyTokens, 0...],
                scale: scale,
                mask: rowMask
            )
            let paddedColumns = queryTokens - extent.queryTokens
            guard paddedColumns > 0 else { return attended }
            // Padded verify columns attend nothing; one call returned zeros
            // for them too, and their outputs are discarded.
            return concatenated([
                attended,
                MLXArray.zeros([1, attended.dim(1), paddedColumns, attended.dim(3)], dtype: attended.dtype),
            ], axis: 2)
        }, axis: 0)
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
        guard presentationWindowTokens == nil else { return nil }
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
        let mask = buildMask(n: n, windowSize: windowSize)
        if case .array(let array) = mask {
            Self.cacheBuiltMasks.lock.lock()
            Self.cacheBuiltMasks.table.add(array)
            Self.cacheBuiltMasks.lock.unlock()
        }
        return mask
    }

    /// Array masks this cache type built, held weakly: the model passes the
    /// full-attention cache's mask to every attention layer of the forward.
    private static let cacheBuiltMasks = (lock: NSLock(), table: NSHashTable<MLXArray>.weakObjects())

    fileprivate static func maskIsCacheBuilt(_ mask: MLXFast.ScaledDotProductAttentionMaskMode) -> Bool {
        guard case .array(let array) = mask else { return true }
        cacheBuiltMasks.lock.lock()
        defer { cacheBuiltMasks.lock.unlock() }
        return cacheBuiltMasks.table.contains(array)
    }

    private func buildMask(n: Int, windowSize: Int?) -> MLXFast.ScaledDotProductAttentionMaskMode {
        if let rowMaps = preparedMTPPackedRowMaps {
            return .array(Self.makePackedMTPMask(n: n, rowMaps: rowMaps, windowSize: windowSize))
        }
        // `makeMask` runs at the start of the forward, before any layer calls
        // `update`, so these are PRE-update per-row token counts.
        let preUpdateOffsets = self.preUpdateOffsets
        // Equal-length rows have no cross-row padding post-update, so a single query
        // token correctly attends every key (including itself) with no mask — unless
        // a sliding window excludes older keys from that shared history.
        // Prefer the row cache presentation window so mask width matches the
        // K/V suffix returned from update().
        let effectiveWindow = presentationWindowTokens ?? windowSize
        let presentedOffsets = preUpdateOffsets.map {
            PagedKVCache.slidingWindowPresentationPrefix(priorTokens: $0, windowSize: effectiveWindow)
        }
        let presentedPostUpdateLengths = presentedOffsets.map { offset -> Int in
            let (postUpdate, overflow) = offset.addingReportingOverflow(n)
            return overflow ? Int.max : postUpdate
        }
        let needsWindow = effectiveWindow.map { window in presentedPostUpdateLengths.contains { $0 > window } } ?? false
        if n == 1, Set(presentedOffsets).count <= 1, !needsWindow { return .none }
        // Ragged shared prefill: every row adds the same `n` tokens from its own
        // offset, so query column q of row b sits at `offset_b + q`. The single
        // shared causal offset below cannot express that; build the per-row
        // causal mask instead. The backend only runs this shape for caches
        // without a presentation window (`supportsRaggedPrefillOffsets`), so key
        // column j is absolute position j.
        if n > 1, rowCaches.count > 1, Set(preUpdateOffsets).count > 1 {
            return .array(PagedKVRaggedPrefillMask.make(
                queryTokens: n,
                rowOffsets: preUpdateOffsets,
                windowSize: windowSize
            ))
        }
        // `createCausalMask` masks key position j unless `j < lengths[b]`. `lengths[b]`
        // must therefore be the count of VALID keys row b holds AFTER this forward's
        // update (`offset_b + n`), so each row's own current token(s) stay attendable
        // and only genuine cross-row padding is masked. Passing the pre-update offsets
        // here masked each row's own current token whenever rows differed in length —
        // the SPEC-038 FR-CB6 / SPEC-039 batched-decode correctness bug the MoE
        // input-isolation probe catches. `offset` stays the pre-update max: it only
        // sets the query's absolute position for the causal check, which the per-row
        // `lengths` gate then restricts correctly.
        return .array(createCausalMask(
            n: n,
            offset: presentedOffsets.max() ?? offset,
            windowSize: effectiveWindow,
            lengths: MLXArray(presentedPostUpdateLengths.map(Int32.init))
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

    fileprivate var preUpdateOffsets: [Int] {
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

    private var presentationWindowTokens: Int? {
        let values = rowCaches.map(\.attentionWindowTokens)
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        let windows = Set(values.compactMap { $0 })
        return windows.count == 1 ? windows.first : nil
    }

    private func presentation(
        keys: MLXArray,
        values: MLXArray,
        priorTokens: Int,
        incomingTokens: Int
    ) -> (MLXArray, MLXArray) {
        guard let window = presentationWindowTokens, window > 0 else {
            return (keys, values)
        }
        let keepPrior = PagedKVCache.slidingWindowPresentationPrefix(
            priorTokens: priorTokens,
            windowSize: window
        )
        let end = priorTokens + incomingTokens
        let start = max(0, end - keepPrior - incomingTokens)
        guard start > 0 else { return (keys, values) }
        return (
            keys[.ellipsis, start..., 0...],
            values[.ellipsis, start..., 0...]
        )
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
