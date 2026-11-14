import CryptoKit
import Foundation
import MLX
import MLXLLM
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
    /// The row's committed native-round sequence number (0, 1, 2, ...),
    /// assigned by the bridge when a committing finalize begins and carried by
    /// that round's before- and after-finalize records; nil on other phases.
    #if DEBUG || MACPROVIDER_LAB_HARNESS
    var nativeRound: Int? = nil
    #endif
}

#if DEBUG || MACPROVIDER_LAB_HARNESS
/// Lab only (issue #2143 Window A diagnosis). With
/// `MACPROVIDER_LAB_FIRST_TOKEN_LOGITS=1`, each CB row's first-token logits
/// are logged: their float32 SHA-256 (equal digests mean the prompt state was
/// bit-identical) and the top five `id:logit`, which show how contested the
/// greedy choice was. Absent from release builds.
enum ContinuousBatchLabFirstTokenLogits {
    static let enabled = ProcessInfo.processInfo.environment["MACPROVIDER_LAB_FIRST_TOKEN_LOGITS"] == "1"

    /// `logits`: `[rows, vocabulary]`, one row per `requestIDs` entry.
    static func log(requestIDs: [String], promptTokenCounts: [Int], logits: MLXArray) {
        guard enabled else { return }
        let rows = logits.asType(.float32)
        for (index, requestID) in requestIDs.enumerated() {
            let values = rows[index].asArray(Float.self)
            let digest = values.withUnsafeBytes { SHA256.hash(data: $0) }
                .map { String(format: "%02x", $0) }.joined()
            var top: [(Int, Float)] = []
            for (id, value) in values.enumerated() where top.count < 5 || value > top[4].1 {
                top.append((id, value))
                top.sort { $0.1 > $1.1 }
                if top.count > 5 { top.removeLast() }
            }
            let topText = top.map { "\($0.0):\($0.1)" }.joined(separator: ",")
            try? FileHandle.standardError.write(contentsOf: Data(
                ("[lab-first-logits] request_id=\(requestID) prompt_tokens=\(promptTokenCounts[index]) "
                    + "sha256=\(digest) top5=\(topText)\n").utf8))
        }
    }
}
#endif

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

/// The recurrent state shape is an exact model-topology contract, not a
/// property inferred from whichever Mamba slots happened to be populated.
/// Qwen-family Mamba layers retain convolution and SSM state; LFM2.5 short
/// convolution layers retain only their convolution history.
enum PagedKVRecurrentStateLayout: Equatable, Sendable {
    case mambaTwoSlot
    case lfm25ShortConvOneSlot

    var slotCount: Int {
        switch self {
        case .mambaTwoSlot: 2
        case .lfm25ShortConvOneSlot: 1
        }
    }

    /// The one-slot LFM2.5 topology ModelRuntime must verify before passing
    /// `.lfm25ShortConvOneSlot` into this bridge.
    static let lfm25ExpectedCacheKinds: [PagedKVSharedForwardBackend.CacheKind] = (0..<40).map {
        ($0 - 2).isMultiple(of: 4) ? .pagedAttention : .recurrentMamba
    }
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
    /// Legacy cache codecs serialize Qwen Mamba state as exactly two slots.
    /// LFM's typed one-slot layout is selected only through
    /// `recurrentStateLayout` at the ordinary-CB bridge boundary.
    static let mambaCacheSlotCount = PagedKVRecurrentStateLayout.mambaTwoSlot.slotCount

    /// SPEC-038 AC-26: a checkpoint is installable only if it covers exactly the
    /// model's recurrent layers, each with its verified state-slot count, and every
    /// slot is a single-row (batch 1) floating-point tensor of rank >= 2. All
    /// recurrent layers of one model share one state layout, so every layer
    /// must match the first; a layer that differs is corrupt or from another
    /// model.
    static func recurrentCheckpointLayoutIsValid(
        _ layouts: [Int: [RecurrentStateSlotLayout]],
        recurrentLayerIndices: [Int],
        stateLayout: PagedKVRecurrentStateLayout = .mambaTwoSlot
    ) -> Bool {
        guard let first = recurrentLayerIndices.first,
              Set(layouts.keys) == Set(recurrentLayerIndices),
              let reference = layouts[first],
              reference.count == stateLayout.slotCount
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
        /// SPEC-039 v0.1.17 `glm5_next` sparse-attention layer: the MLA latent
        /// and the indexer's pooled keys (one per `kpool` tokens) paged on the
        /// row's one block table (`PagedMLALatentCache`).
        case pagedMLA(kpool: Int)
        /// Row-owned DeepSeek compressor plus window (and ratio-4 indexer).
        case deepseekV4Pool(ratio: Int, windowTokens: Int)
        /// MiniMax M3 block-sparse attention layer: attention K/V plus the
        /// lightning indexer's keys of the same tokens, all paged on the
        /// row's one block table (`PagedMiniMaxM3SparseCache`).
        case pagedIndexedKV

        var usesPagedKVCache: Bool {
            switch self {
            case .pagedAttention, .slidingWindow, .pagedMLA, .pagedIndexedKV: true
            case .recurrentMamba, .deepseekV4Pool: false
            }
        }

        var isPagedMLA: Bool {
            if case .pagedMLA = self { return true }
            return false
        }

        var isDeepseekV4Pool: Bool {
            if case .deepseekV4Pool = self { return true }
            return false
        }

        var isPagedIndexedKV: Bool { self == .pagedIndexedKV }

        var hasSlidingWindow: Bool {
            if case .slidingWindow = self { return true }
            return false
        }

        static func recognized(from cache: KVCache) -> CacheKind? {
            if let list = cache as? CacheList {
                var leaves: [KVCache] = []
                list.mapChildren { leaves.append($0); return $0 }
                guard let window = leaves.first as? RotatingKVCache,
                      let windowTokens = window.maxSize, windowTokens > 0,
                      window.metaState.first == "0",
                      leaves.count == 2 || leaves.count == 3,
                      let pool = leaves[1] as? DeepseekV4PoolCache,
                      pool.ratio == 4 || pool.ratio == 128,
                      leaves.count == (pool.ratio == 4 ? 3 : 2),
                      leaves.dropFirst().allSatisfy({ ($0 as? DeepseekV4PoolCache)?.ratio == pool.ratio })
                else { return nil }
                return .deepseekV4Pool(ratio: pool.ratio, windowTokens: windowTokens)
            }

            if let latent = cache as? any GLM5NextLatentCache {
                guard latent.kpool >= 1 else { return nil }
                return .pagedMLA(kpool: latent.kpool)
            }
            if cache is any MiniMaxM3SparseCache { return .pagedIndexedKV }
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
            return kinds.contains(where: { $0.usesPagedKVCache || $0.isDeepseekV4Pool }) ? kinds : nil
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
    let recurrentStateLayout: PagedKVRecurrentStateLayout
    private let contiguousCacheBridge: (any PagedKVRuntimeCacheBridge)?
    /// When true, lockstep decode reuses a compiled `[B, 1]` graph over batched
    /// contiguous KV. Tests keep the default off so fake models are not traced.
    let compiledDecode: Bool
    private let lock = NSLock()
    /// Holders of this backend's target `container.perform` (exclusive, so
    /// at most one). Every MLX evaluation of the native-MTP round runs
    /// inside one: forwards, sampling, drafter state, lab digests.
    private var targetLockHolders = 0

    fileprivate func enterTargetLock() {
        lock.lock()
        targetLockHolders += 1
        lock.unlock()
    }

    fileprivate func exitTargetLock() {
        lock.lock()
        targetLockHolders -= 1
        lock.unlock()
    }

    /// Fails closed when a native-MTP helper that evaluates MLX arrays runs
    /// outside the target container's lock, where it could evaluate
    /// concurrently with a forward on the shared container.
    func requireTargetLockHeld(_ site: String) throws {
        lock.lock()
        let held = targetLockHolders > 0
        lock.unlock()
        guard held else {
            try? FileHandle.standardError.write(contentsOf: Data(
                "event=native_mtp_target_lock_not_held site=\(site)\n".utf8
            ))
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_target_lock_not_held")
        }
    }

    #if DEBUG
    /// Runs `body` holding this backend's target lock, for tests.
    func withTargetLockForTest<R: Sendable>(_ body: @Sendable () throws -> R) async throws -> R {
        try await container.perform { _ in
            self.enterTargetLock(); defer { self.exitTargetLock() }
            return try body()
        }
    }
    #endif
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
    /// Most tokens (rows x tokens per row) one shared `glm5_next` forward
    /// carries. The GLM-5-Next fused decode kernels and quantized projections
    /// keep a batched row bitwise equal to its serial decode only up to this
    /// many flattened tokens; past the core's `qmv` vector limit the
    /// projections switch to `qmm` and rows diverge (SPEC-038 FR-CB2).
    static let pagedMLAMaxFlattenedTokensPerForward = 8

    /// The flattened-token cap of a shared forward over these layers, or nil
    /// when only the device route bound applies.
    static func maxFlattenedTokensPerForward(cacheKinds: [CacheKind]) -> Int? {
        cacheKinds.contains(where: { $0.isPagedMLA || $0.isDeepseekV4Pool || $0.isPagedIndexedKV })
            ? pagedMLAMaxFlattenedTokensPerForward : nil
    }

    /// Whether every row of a prefill group prefills in its own forward: no
    /// two-row shared forward fits under the flattened-token cap at the
    /// smallest chunk that may group (`glm5_next`: an 8-token cap against
    /// 144-token grouped chunks). On such a backend a native-MTP prompt row
    /// may join a ragged group (SPEC-038 v0.3.24 FR-CB2): it still prefills
    /// alone, on the serial path its drafter seeding is proven on.
    static func prefillsGroupedRowsAlone(cacheKinds: [CacheKind], minimumGroupedChunkTokens: Int) -> Bool {
        guard let cap = maxFlattenedTokensPerForward(cacheKinds: cacheKinds) else { return false }
        let (tokens, overflow) = max(1, minimumGroupedChunkTokens).multipliedReportingOverflow(by: 2)
        return overflow || tokens > cap
    }

    /// Rows one decode forward may carry beyond the device route bound
    /// (`pagedMLA`: `pagedMLAMaxFlattenedTokensPerForward`); nil when only the
    /// device bound applies. The scheduler splits larger decode steps.
    let maxDecodeRowsPerForward: Int?
    /// Closed backend capability for sharing one ragged target-prefill
    /// forward between native-MTP and ordinary rows. Qwen3.5/3.6 emits
    /// independently sliceable `[B, L, H]` prompt hidden states; other
    /// adapters retain the equal-offset veto unless their grouped rows run
    /// alone under the existing flattened-token rule.
    let nativeMTPPromptRowsJoinRaggedPrefill: Bool

    static func supportsNativeMTPPromptRowsInRaggedPrefill(familyAdapter: String?) -> Bool {
        familyAdapter == "qwen3_5_mtp_v1"
    }

    /// Prompt columns this backend's native-MTP drafter prefills, the last
    /// this many, or nil for the whole prompt. The GLM-5-Next head prefills
    /// its default window (NoPE attention, so no absolute positions); the
    /// scheduler skips drafter work on chunks wholly before it.
    let nativeMTPDrafterPromptWindow: Int?

    static func drafterPromptWindow(familyAdapter: String?) -> Int? {
        familyAdapter == NativeMTPStagedRoundBytes.glm5NextFamilyAdapter
            ? GLM5NextMTPDraftModel.defaultPromptWindow
            : nil
    }

    /// The flattened-token cap `sharedForwardFits` applies to a prefill group.
    var prefillForwardTokenCap: Int? { maxDecodeRowsPerForward }

    /// Whether `rows` prompt chunks of `chunkLength` tokens fit one shared
    /// forward under this backend's flattened-token cap.
    func sharedForwardFits(rows: Int, tokensPerRow: Int) -> Bool {
        guard let cap = maxDecodeRowsPerForward else { return true }
        let (tokens, overflow) = rows.multipliedReportingOverflow(by: tokensPerRow)
        return !overflow && tokens <= cap
    }

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
    /// oMLX fused_batch.advance groups equal draft depths before verification.
    /// Keep every row's real width and the vector-kernel token cap. MTP-7
    /// requires oldest-ready rows first, so cohorts stop at a width change
    /// instead of moving a later compatible row ahead of an older row.
    static func packedVerifyGroups(widths: [Int], maxTokens: Int) -> [[Int]] {
        var groups: [[Int]] = []
        var start = 0
        while start < widths.count {
            let width = widths[start]
            // Division avoids overflow even for an unbounded test limit.
            // An individually wider row still runs alone, as before.
            let rowLimit = max(1, maxTokens / max(1, width))
            var end = start + 1
            while end < widths.count, end - start < rowLimit, widths[end] == width {
                end += 1
            }
            groups.append(Array(start..<end))
            start = end
        }
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
    private var labNativeMTPNumericalOracle: NativeMTPLabNumericalOracle.Binding?
    #if DEBUG || MACPROVIDER_LAB_HARNESS
    private var labNativeMTPStateDigestObserver: NativeMTPStateDigestObserver?
    private var nativeMTPDrafterRecomputeDigests: [String: String] = [:]
    private var labNativeMTPCommittedPrefixTokens: [String: [Int]] = [:]
    private var labNativeMTPCommittedPrefixHidden: [String: [MLXArray]] = [:]
    private var labNativeMTPCommittedPrefixTargetBonus: [String: Int] = [:]
    private var labNativeMTPPrefixPositionDeltasUnsupported: Set<String> = []
    private var labNativeMTPLastFinalizeRecomputePrefixTokens: [String: Int] = [:]
    private var labNativeMTPNextRound: [String: Int] = [:]
    #endif

    init(
        container: ModelContainer,
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        poolEpoch: Int,
        layerCount: Int,
        cacheKinds: [CacheKind]? = nil,
        recurrentStateLayout: PagedKVRecurrentStateLayout = .mambaTwoSlot,
        contiguousCacheBridge: (any PagedKVRuntimeCacheBridge)? = nil,
        compiledDecode: Bool = false,
        drafterContainer: MTPDrafterContainer? = nil,
        nativeMTPFamilyAdapter: String? = nil,
        nativeMTPDrafterColumnCap: Int = PagedKVSharedForwardBackend.defaultNativeMTPDrafterColumnCap,
        maxVerifyTokensPerForward: Int? = nil
    ) {
        self.container = container
        self.drafterContainer = drafterContainer
        self.nativeMTPPromptRowsJoinRaggedPrefill = Self.supportsNativeMTPPromptRowsInRaggedPrefill(
            familyAdapter: nativeMTPFamilyAdapter
        )
        self.nativeMTPDrafterPromptWindow = Self.drafterPromptWindow(
            familyAdapter: nativeMTPFamilyAdapter
        )
        self.nativeMTPDrafterColumnCap = max(1, nativeMTPDrafterColumnCap)
        let resolvedKinds = (cacheKinds?.isEmpty == false)
            ? cacheKinds!
            : Array(repeating: CacheKind.pagedAttention, count: max(1, layerCount))
        let flattenedCap = Self.maxFlattenedTokensPerForward(cacheKinds: resolvedKinds)
        self.maxVerifyTokensPerForward = min(
            max(1, maxVerifyTokensPerForward ?? Self.deviceVerifyTokenBound),
            flattenedCap ?? Int.max
        )
        self.maxDecodeRowsPerForward = flattenedCap
        self.blockSizeTokens = blockSizeTokens
        self.maxPhysicalBlocks = maxPhysicalBlocks
        self.poolEpoch = poolEpoch
        self.cacheKinds = resolvedKinds
        self.recurrentStateLayout = recurrentStateLayout
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
        recurrentStateLayout: PagedKVRecurrentStateLayout = .mambaTwoSlot,
        contiguousCacheBridge: (any PagedKVRuntimeCacheBridge)? = nil,
        compiledDecode: Bool = false,
        drafterContainer: MTPDrafterContainer? = nil,
        nativeMTPFamilyAdapter: String? = nil,
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
            recurrentStateLayout: recurrentStateLayout,
            contiguousCacheBridge: contiguousCacheBridge,
            compiledDecode: compiledDecode,
            drafterContainer: drafterContainer,
            nativeMTPFamilyAdapter: nativeMTPFamilyAdapter,
            nativeMTPDrafterColumnCap: nativeMTPDrafterColumnCap,
            maxVerifyTokensPerForward: maxVerifyTokensPerForward
        )
    }

    func prefill(rows inputs: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        CBTrace.logPreparation(
            nil,
            "prefill_group_begin rows=\(inputs.count) ids=\(inputs.map(\.requestID).joined(separator: ",")) offsets=\(inputs.map(\.promptTokenOffset).map(String.init).joined(separator: ",")) chunks=\(inputs.map { $0.promptTokens.count }.map(String.init).joined(separator: ","))"
        )
        let outputs = try await container.perform(nonSendable: inputs) { context, inputs in
            self.enterTargetLock(); defer { self.exitTargetLock() }
            let raggedOffsets = Self.hasRaggedPromptOffsets(inputs)
            if Self.canSharePrefillForward(
                inputs,
                nativeMTPPromptRowsJoinRaggedPrefill: self.nativeMTPPromptRowsJoinRaggedPrefill
            ),
               self.sharedForwardFits(rows: inputs.count, tokensPerRow: inputs[0].promptTokens.count),
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
                            #if DEBUG || MACPROVIDER_LAB_HARNESS
                            if ContinuousBatchLabFirstTokenLogits.enabled {
                                let sampling = inputs.indices.filter { inputs[$0].sampleFirstToken }
                                ContinuousBatchLabFirstTokenLogits.log(
                                    requestIDs: sampling.map { inputs[$0].requestID },
                                    promptTokenCounts: sampling.map { inputs[$0].targetKVTokenCount },
                                    logits: output.logits[0..., -1, 0...][MLXArray(sampling.map(Int32.init))])
                            }
                            #endif
                            sampledTokens = ContinuousBatchRowSampler.sample(
                                logits: output.logits[0..., -1, 0...],
                                rows: inputs.map(Self.samplerRow)
                            ).asArray(Int.self)
                            guard sampledTokens?.count == inputs.count else {
                                throw ContinuousBatchSchedulerError.unsupported(
                                    "continuous_batching_invalid_logits_shape"
                                )
                            }
                            for (index, input) in inputs.enumerated() where input.sampleFirstToken {
                                self.labCaptureTargetLogits(
                                    requestID: input.requestID, position: input.samplerStep,
                                    tokenIDs: [sampledTokens![index]],
                                    logits: output.logits[index, -1, 0...].reshaped(1, -1))
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
                                    ContinuousBatchingPolicy.logPrefillFailed(error)
                                    self.removeRowState(for: input.requestID)
                                    drafterFailures.insert(index)
                                }
                            }
                        }
                        self.invalidateDecodeSession(containingAnyOf: inputs.map(\.requestID))
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
                        self.invalidateDecodeSession(containingAnyOf: inputs.map(\.requestID))
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
                            #if DEBUG || MACPROVIDER_LAB_HARNESS
                            if ContinuousBatchLabFirstTokenLogits.enabled {
                                ContinuousBatchLabFirstTokenLogits.log(
                                    requestIDs: [input.requestID],
                                    promptTokenCounts: [input.targetKVTokenCount],
                                    logits: output.logits[0..., -1, 0...])
                            }
                            #endif
                            sampledToken = ContinuousBatchRowSampler.sample(
                                logits: output.logits[0..., -1, 0...],
                                rows: [Self.samplerRow(input)]
                            ).asArray(Int.self).first
                            if let sampledToken {
                                self.labCaptureTargetLogits(
                                    requestID: input.requestID, position: input.samplerStep,
                                    tokenIDs: [sampledToken], logits: output.logits[0..., -1, 0...])
                                #if DEBUG || MACPROVIDER_LAB_HARNESS
                                if NativeMTPLabTokenTrace.enabled, input.samplerStep < NativeMTPLabTokenTrace.limit {
                                    let top = NativeMTPLabTokenTrace.topTwo(output.logits[0..., -1, 0...])[0]
                                    NativeMTPLabTokenTrace.write(requestID: input.requestID, path: "prefill", [.init(
                                        index: input.samplerStep, column: 0, width: input.promptTokens.count,
                                        source: "target", token: sampledToken, top1: top.top1, top2: top.top2,
                                        margin: top.margin, kvBefore: input.committedKVTokenCount,
                                        kvAfter: input.targetKVTokenCount
                                    )])
                                }
                                #endif
                            }
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
                    ContinuousBatchingPolicy.logPrefillFailed(error)
                    self.removeRowState(for: input.requestID)
                    outputs.append(ContinuousBatchPrefillOutput(
                        requestID: input.requestID,
                        failureCode: "continuous_batching_prefill_failed"
                    ))
                }
            }
            self.invalidateDecodeSession(containingAnyOf: inputs.map(\.requestID))
            return outputs
        }
        // Match serial serving: release reusable temporary buffers after a
        // whole prompt, while keeping all live row/snapshot arrays intact.
        // Intermediate boundary chunks retain their existing allocation plan.
        ModelRuntime.clearMLXBufferCacheAfterPrefill(
            isFinalChunk: inputs.contains { $0.isFinalChunk })
        CBTrace.logPreparation(
            nil,
            "prefill_group_end rows=\(inputs.count) ids=\(inputs.map(\.requestID).joined(separator: ","))"
        )
        return outputs
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
        try requireTargetLockHeld("seed_drafter_from_prefill")
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
    /// per-row causal mask. Native-MTP rows keep the default equal-offset veto;
    /// only an explicitly admitted backend family may share the ragged forward.
    static func canSharePrefillForward(
        _ inputs: [ContinuousBatchPrefillInput],
        nativeMTPPromptRowsJoinRaggedPrefill: Bool = false
    ) -> Bool {
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
            return nativeMTPPromptRowsJoinRaggedPrefill
                || !inputs.contains(where: \.nativeMTPPromptPrefill)
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
            self.enterTargetLock(); defer { self.exitTargetLock() }
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
            self.enterTargetLock(); defer { self.exitTargetLock() }
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
                self.enterTargetLock(); defer { self.exitTargetLock() }
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
        let groups = Self.packedVerifyGroups(
            widths: ordered.map(\.verifiedInputTokenCount),
            maxTokens: serializesPaddedRows ? 1 : maxVerifyTokensPerForward
        )
        guard groups.count > 1 else {
            return try await verifyNativeMTPPackedGroup(rows: ordered)
        }
        var verifiedRows: [NativeMTPVerifiedRow] = []
        for group in groups {
            // Depth cohorts keep each query's serial width, avoiding both
            // wasted padding and batch-shape-dependent kernel selection.
            // Re-index only within the cohort, then restore scheduler identity.
            let groupInputs = group.enumerated().map { index, originalIndex in
                let input = ordered[originalIndex]
                return ContinuousBatchNativeMTPVerifyInput(
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
                    packedRowIndex: ordered[group[row.packedRowIndex]].packedRowIndex,
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
            self.enterTargetLock(); defer { self.exitTargetLock() }
            // A cancellation between groups of a split round stops before
            // this group touches row state.
            try self.throwIfCancelRequested()
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
            try self.throwIfCancelRequested()
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
            for (row, tokens) in zip(output.rows, topTokenIDsByRow) {
                let input = inputs[row.map.rowIndex]
                // Construct this capture view only when the observer is active.
                self.lock.lock()
                let binding = self.labNativeMTPNumericalOracle
                self.lock.unlock()
                if binding?.oracle.wantsCapture(requestID: input.requestID, position: input.samplerStep) == true {
                    self.labCaptureTargetLogits(
                        requestID: input.requestID, position: input.samplerStep, tokenIDs: tokens,
                        logits: concatenated([row.proposalLogits, row.bonusLogits], axis: 0), speculative: true)
                }
                #if DEBUG || MACPROVIDER_LAB_HARNESS
                if NativeMTPLabTokenTrace.enabled, input.samplerStep < NativeMTPLabTokenTrace.limit {
                    let columns = row.proposalLogits.ndim == 2 && row.proposalLogits.dim(0) > 0
                        ? concatenated([row.proposalLogits, row.bonusLogits], axis: 0)
                        : row.bonusLogits
                    NativeMTPLabTokenTrace.write(
                        requestID: input.requestID, path: "verify",
                        NativeMTPLabTokenTrace.verifyEntries(
                            samplerStep: input.samplerStep,
                            proposals: input.proposalTokens,
                            targets: tokens,
                            tops: NativeMTPLabTokenTrace.topTwo(columns),
                            kvBefore: input.committedKVTokenCount
                        )
                    )
                }
                #endif
            }
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
            self.enterTargetLock(); defer { self.exitTargetLock() }
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
            let labRounds = self.labBeginNativeMTPCommittedRound(
                requestIDs: inputs.filter(\.shouldCommit).map(\.requestID)
            )
            try self.recordNativeMTPStateDigest(
                phase: .beforeFinalize,
                inputs: inputs,
                transactions: transactions,
                rounds: labRounds
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
                        requestID: input.requestID,
                        sampledAtFinalize: true
                    )
                }
                #endif
            }
            for (input, _) in committing {
                self.invalidateDecodeSession(containing: input.requestID)
            }
            self.labResolveNumericalOracleRound(inputs)
            #if DEBUG || MACPROVIDER_LAB_HARNESS
            try self.recordNativeMTPStateDigest(
                phase: .afterFinalize,
                inputs: inputs,
                transactions: transactions,
                rounds: labRounds
            )
            #endif
        }
    }

    func installLabNativeMTPNumericalOracle(_ binding: NativeMTPLabNumericalOracle.Binding?) {
        lock.lock()
        labNativeMTPNumericalOracle = binding
        lock.unlock()
    }

    private func labCaptureTargetLogits(
        requestID: String, position: Int, tokenIDs: [Int], logits makeLogits: @autoclosure () -> MLXArray,
        speculative: Bool = false
    ) {
        lock.lock()
        let binding = labNativeMTPNumericalOracle
        lock.unlock()
        // The decode loops call this per row per step; the row's logits
        // slice is built only when an oracle wants it.
        guard let binding, binding.oracle.wantsCapture(requestID: requestID, position: position) else { return }
        let logits = makeLogits()
        for (offset, token) in tokenIDs.enumerated() {
            let step = position + offset
            guard binding.oracle.wantsCapture(requestID: requestID, position: step) else { break }
            // No extra evaluation, transfer or graph retention unless installed.
            let vector = logits[offset].asType(.float32).asArray(Float.self)
            binding.oracle.capture(
                role: binding.role, requestID: requestID, position: step,
                tokenID: token, logits: vector, speculative: speculative)
        }
    }

    private func labResolveNumericalOracleRound(_ inputs: [ContinuousBatchNativeMTPFinalizeInput]) {
        lock.lock()
        let binding = labNativeMTPNumericalOracle
        lock.unlock()
        guard let binding, binding.role == .native else { return }
        for input in inputs {
            binding.oracle.resolveNativeRound(
                requestID: input.requestID,
                acceptedTokenIDs: input.shouldCommit ? input.acceptedTokenIDs : nil)
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
        guard let observer, !requestIDs.isEmpty else { return }
        // The digests evaluate the row and drafter state, so they run under
        // the target lock like every forward (window A2: they ran outside it,
        // beside a decode window on the same container).
        try await container.perform(nonSendable: requestIDs) { context, requestIDs in
            self.enterTargetLock(); defer { self.exitTargetLock() }
            if phase == .afterAbort {
                for requestID in requestIDs {
                    self.labClearNativeMTPDrafterRecomputeDigest(requestID: requestID)
                    try await self.labRecomputeNativeMTPDrafterDigest(
                        targetModel: context.model,
                        requestID: requestID
                    )
                }
            }
            for requestID in requestIDs {
                let digest = try self.nativeMTPStateDigest(requestID: requestID, transaction: nil)
                observer.record(NativeMTPStateDigestRecord(
                    requestID: requestID,
                    phase: phase,
                    digestSHA256: digest.combined,
                    cacheDigestSHA256: digest.cache,
                    drafterDigestSHA256: digest.drafter,
                    pendingTargetDigestSHA256: nil,
                    drafterRecomputeDigestSHA256: digest.drafterRecompute,
                    committedKVTokenCount: self.rowStateTokenCount(for: requestID),
                    proposedTokens: 0,
                    committedProposalTokens: nil
                ))
            }
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
        // SPEC-039 FR-PKV12: a `glm5_next` row serves first-turn/cache-miss
        // requests only; no FR-CB10 grant covers a retained MLA handoff.
        guard !cacheKinds.contains(where: { $0.isPagedMLA || $0.isPagedIndexedKV }) else { throw unavailable }
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
        guard Self.recurrentCheckpointLayoutIsValid(
            layouts,
            recurrentLayerIndices: recurrentIndices,
            stateLayout: recurrentStateLayout
        ) else {
            throw unavailable
        }
        var attention = handoff.caches.makeIterator()
        var caches: [KVCache] = []
        for (index, kind) in cacheKinds.enumerated() {
            switch kind {
            case .pagedAttention, .slidingWindow:
                guard let cache = attention.next() else { throw unavailable }
                caches.append(cache)
            case .pagedMLA, .deepseekV4Pool, .pagedIndexedKV:
                throw unavailable
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

    /// SPEC-024 FR-CI2a: a GLM-5-Next row (`pagedMLA` plus `recurrentMamba`
    /// layers) in the serial cache format at exactly `tokenCount`. The paged
    /// latent cache holds the `GLM5NextAttentionCache` state layout, so each
    /// sparse layer copies into a serial `GLM5NextAttentionCache`; recurrent
    /// layers copy their state. Every other layout returns nil.
    func snapshotPromptCache(requestID: String, tokenCount: Int) async -> ContinuousBatchSerialConversationCache? {
        await captureGLMPromptSnapshot(requestID: requestID, tokenCount: tokenCount, nextPromptToken: nil)
    }

    /// SPEC-024-R005: on a native-MTP row the snapshot also carries the MTP
    /// head state, copied when the head sits exactly at `tokenCount` with no
    /// tentative proposal (prefill, never mid-verify: the snapshot point is
    /// strictly inside the prompt). Its last entry consumed `nextPromptToken`.
    func snapshotPromptCacheAndHead(
        requestID: String,
        tokenCount: Int,
        nextPromptToken: Int
    ) async -> ContinuousBatchSerialConversationCache? {
        await captureGLMPromptSnapshot(requestID: requestID, tokenCount: tokenCount, nextPromptToken: nextPromptToken)
    }

    private func captureGLMPromptSnapshot(
        requestID: String,
        tokenCount: Int,
        nextPromptToken: Int?
    ) async -> ContinuousBatchSerialConversationCache? {
        guard cacheKinds.contains(where: \.isPagedMLA),
              cacheKinds.allSatisfy({ $0.isPagedMLA || $0 == .recurrentMamba }),
              beginOperation()
        else { return nil }
        defer { endOperation() }
        return await container.perform { _ -> ContinuousBatchSerialConversationCache? in
            guard let row = self.existingRowState(for: requestID),
                  row.caches.count == self.cacheKinds.count,
                  row.recurrentWindow == nil
            else { return nil }
            var layers: [KVCache] = []
            for (index, kind) in self.cacheKinds.enumerated() {
                if kind == .recurrentMamba {
                    let state = row.caches[index].state
                    guard !state.isEmpty else { return nil }
                    let cache = MambaCache()
                    cache.state = state.map { $0[.ellipsis] }
                    layers.append(cache)
                } else {
                    guard let latent = row.caches[index] as? PagedMLALatentCache,
                          latent.offset == tokenCount
                    else { return nil }
                    layers.append(Self.serialAttentionCache(copying: latent))
                }
            }
            var drafter: NativeMTPDrafterPrefixSnapshot?
            if let nextPromptToken,
               let state = self.nativeMTPDrafterState(for: requestID),
               state.nextPosition == tokenCount,
               state.proposalAppended == 0 {
                drafter = NativeMTPDrafterPrefixSnapshot(
                    cache: state.cache.map { $0.copy() },
                    nextPosition: tokenCount,
                    foldedNextToken: nextPromptToken
                )
            }
            eval(layers + (drafter?.cache ?? []))
            return ContinuousBatchSerialConversationCache(
                layers: layers, recurrentCheckpoints: [], tokenCount: tokenCount, promptSnapshot: true,
                nativeMTPDrafter: drafter)
        }
    }

    /// SPEC-024-R005 / SPEC-038 AC-26: the row's caches from a GLM-5-Next
    /// prompt snapshot at exactly `binding`'s logical length. Each sparse layer
    /// takes the snapshot's latent, pooled keys and partial windows; each
    /// recurrent layer its state. The row's arrays alias the snapshot's
    /// immutable MLX buffers until its first write, which writes a new buffer
    /// (`PagedMLALatentCache.adopt`), so the stored entry never changes. A
    /// native row's MTP head resumes from a copy of the snapshot's head state.
    /// Any layout or length mismatch fails admission before a row exists.
    func installPromptSnapshotCache(
        requestID: String,
        snapshot: ContinuousBatchSerialConversationCache,
        binding: PagedKVStorageBinding,
        restoreNativeMTPDrafter: Bool
    ) async throws {
        let unavailable = ContinuousBatchSchedulerError.unsupported("continuous_batching_prompt_snapshot_install_unavailable")
        let tokenCount = snapshot.tokenCount
        guard snapshot.promptSnapshot,
              tokenCount > 0,
              binding.currentTable.logicalTokenCount == tokenCount,
              snapshot.layers.count == cacheKinds.count,
              cacheKinds.contains(where: \.isPagedMLA),
              cacheKinds.allSatisfy({ $0.isPagedMLA || $0 == .recurrentMamba })
        else { throw unavailable }
        let drafter = restoreNativeMTPDrafter ? snapshot.nativeMTPDrafter : nil
        if restoreNativeMTPDrafter {
            guard let drafter, drafter.nextPosition == tokenCount, !drafter.cache.isEmpty else { throw unavailable }
        }
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        let caches = try Self.promptSnapshotRowCaches(
            snapshot,
            cacheKinds: cacheKinds,
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: poolEpoch,
            binding: binding
        )
        try setRowState(RowState(caches: caches, state: nil), for: requestID, binding: binding)
        if let drafter {
            storeNativeMTPDrafterAdvance(
                requestIDs: [requestID],
                states: [MTPDrafterState(cache: drafter.cache.map { $0.copy() }, nextPosition: tokenCount)],
                seedTokens: [nil]
            )
        }
    }

    /// Row caches for `installPromptSnapshotCache`, nil-free or throwing.
    static func promptSnapshotRowCaches(
        _ snapshot: ContinuousBatchSerialConversationCache,
        cacheKinds: [CacheKind],
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        poolEpoch: Int,
        binding: PagedKVStorageBinding
    ) throws -> [KVCache] {
        let unavailable = ContinuousBatchSchedulerError.unsupported("continuous_batching_prompt_snapshot_install_unavailable")
        guard snapshot.layers.count == cacheKinds.count else { throw unavailable }
        var caches: [KVCache] = []
        for (index, kind) in cacheKinds.enumerated() {
            let layer = snapshot.layers[index]
            switch kind {
            case .recurrentMamba:
                guard layer is MambaCache else { throw unavailable }
                let state = layer.state
                guard !state.isEmpty, state.allSatisfy({ $0.size > 0 }) else { throw unavailable }
                let cache = MambaCache()
                cache.state = state.map { $0[.ellipsis] }
                caches.append(cache)
            case .pagedMLA(let kpool):
                guard let serial = layer as? GLM5NextAttentionCache,
                      serial.kpool == kpool,
                      serial.offset == snapshot.tokenCount
                else { throw unavailable }
                let cache = PagedMLALatentCache(
                    kpool: kpool,
                    blockSizeTokens: blockSizeTokens,
                    maxPhysicalBlocks: maxPhysicalBlocks,
                    poolEpoch: poolEpoch,
                    binding: binding,
                    initialOffset: 0,
                    reconstructViaGather: false
                )
                cache.state = serial.state
                guard cache.offset == snapshot.tokenCount else { throw unavailable }
                caches.append(cache)
            case .pagedAttention, .slidingWindow, .deepseekV4Pool, .pagedIndexedKV:
                throw unavailable
            }
        }
        return caches
    }

    /// The serial `GLM5NextAttentionCache` holding a copy of `latent`'s state
    /// (same layout: latent, pooled keys, pending and folded windows).
    static func serialAttentionCache(copying latent: PagedMLALatentCache) -> GLM5NextAttentionCache {
        let cache = GLM5NextAttentionCache(kpool: latent.kpool, maxTrim: latent.maxTrim)
        cache.state = latent.state.map { $0[.ellipsis] }
        return cache
    }

    /// Reuses the FR-PKV10 materialize path on a throwaway bridge that records
    /// only this row's paged caches, so nothing outlives the call.
    func materializeSerialConversationCache(
        requestID: String,
        binding: PagedKVStorageBinding,
        tokenCount: Int,
        recurrentCheckpoints: [RecurrentStateCheckpoint]
    ) async throws -> ContinuousBatchSerialConversationCache? {
        guard cacheKinds.contains(.recurrentMamba),
              !cacheKinds.contains(where: \.isPagedMLA),
              !recurrentCheckpoints.isEmpty
        else { return nil }
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
            // Recurrent layers hold the state at exactly `tokenCount`, matching the
            // serial path's cache. An empty placeholder made the SPEC-037 codec-v2
            // capture reject the entry (`estimate_unavailable`, #2015). Hot reuse
            // overwrites these slots from the selected checkpoint either way.
            let terminal = recurrentCheckpoints.last { $0.tokenCount == tokenCount }
            var layers: [KVCache] = []
            for (index, kind) in self.cacheKinds.enumerated() {
                switch kind {
                case .pagedAttention, .slidingWindow:
                    guard let cache = attention.next() else {
                        throw PagedKVContiguousCacheBridgeError.blockTableMismatch
                    }
                    layers.append(cache)
                case .pagedMLA, .deepseekV4Pool, .pagedIndexedKV:
                    throw PagedKVContiguousCacheBridgeError.blockTableMismatch
                case .recurrentMamba:
                    let cache = MambaCache()
                    if let state = terminal?.states[index] {
                        cache.state = state
                    }
                    layers.append(cache)
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
            let handlesToDiscard = rows.compactMap { Self.storageHandle(in: $0.value.caches) }
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
            labNativeMTPLastFinalizeRecomputePrefixTokens.removeAll()
            labNativeMTPNextRound.removeAll()
            #endif
            if activeOperations == 0 {
                // Cancellation is a barrier, not a terminal backend state.
                cancelRequested = false
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
            cancelRequested = false
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
                case .pagedMLA(let kpool):
                    PagedMLALatentCache(
                        kpool: kpool,
                        blockSizeTokens: blockSizeTokens,
                        maxPhysicalBlocks: maxPhysicalBlocks,
                        poolEpoch: poolEpoch,
                        binding: binding,
                        initialOffset: initialOffset,
                        reconstructViaGather: false
                    )
                case .pagedIndexedKV:
                    PagedMiniMaxM3SparseCache(
                        blockSizeTokens: blockSizeTokens,
                        maxPhysicalBlocks: maxPhysicalBlocks,
                        poolEpoch: poolEpoch,
                        binding: binding,
                        initialOffset: initialOffset,
                        reconstructViaGather: false
                    )
                case .deepseekV4Pool:
                    preconditionFailure("DeepSeek V4 requires DeepseekV4ContinuousBatchBackend")
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
        if discardRecordedCache, let handle = removed.flatMap({ Self.storageHandle(in: $0.caches) }) {
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
        // A capped backend (`pagedMLA`) never forms a wider forward; the
        // scheduler splits decode steps to fit.
        guard sharedForwardFits(rows: supportedInputs.count, tokensPerRow: 1) else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_forward_token_cap")
        }
        var rowStates = supportedInputs.map {
            self.rowState(
                for: $0.requestID,
                binding: $0.binding,
                initialOffset: $0.committedKVTokenCount
            )
        }
        let invariantStateModel = model as? any BatchInvariantDecodeStateModel
        let hasBatchedState = supportedInputs.count > 1
            && (invariantStateModel != nil || rowStates.contains(where: { $0.state != nil }))
        if hasBatchedState && invariantStateModel == nil {
            return supportedInputs.map { ContinuousBatchDecodeOutcome.rowFailure(requestID: $0.requestID) }
        }
        // Native rows riding this forward need the target hidden state of
        // every step for their drafter. Capture asks the target to emit it;
        // that output state is diagnostic only and never becomes row state.
        let captureIndices = drafterContainer == nil
            ? []
            : supportedInputs.indices.filter { supportedInputs[$0].captureNativeMTPDrafterColumns }
        if !captureIndices.isEmpty && (hasBatchedState || rowStates.contains(where: { $0.state != nil })) {
            return supportedInputs.map { ContinuousBatchDecodeOutcome.rowFailure(requestID: $0.requestID) }
        }
        func discardAdvancedRows() {
            storeDecodeSession(nil)
            for input in supportedInputs { removeRowState(for: input.requestID) }
        }
        var capturedColumns: [Int: [(token: Int, hidden: MLXArray)]] = [:]

        let requestIDs = supportedInputs.map(\.requestID)
        var session = copyDecodeSession()
        let batchedCaches: [PagedKVSharedLayerBatch]
        if let existing = session, existing.requestIDs == requestIDs {
            batchedCaches = existing.batchedCaches
        } else {
            let previous = session
            previous?.batchedCaches.forEach { $0.syncRowsFromBatch() }
            // While rows ride the session, its batch buffers are their only
            // K/V. Hybrid (recurrent) sessions are rebuilt every window, so
            // their rows keep their own K/V.
            batchedCaches = try makeBatchedCaches(
                from: rowStates.map(\.caches),
                attachRows: !cacheKinds.contains(.recurrentMamba)
            )
            // Packing re-attached the rows that ride on; rows that left with
            // the old session get their own K/V back. Build the new batch one
            // layer at a time and drop each replaced layer as soon as its
            // successor is packed: evaluated lazily at the first forward,
            // every layer of the old batch, the joining rows' own K/V and the
            // new batch were resident together (a 16K row joining 1K/4K/8K
            // rows: an estimated 6 GB on top of the new 9 GB batch).
            let replaced = previous?.batchedCaches ?? []
            for index in batchedCaches.indices {
                batchedCaches[index].materializePacked()
                if replaced.indices.contains(index) {
                    replaced[index].releaseRowsAndBuffers()
                }
            }
            if previous != nil { storeDecodeSession(nil) }
            session = DecodeSession(
                requestIDs: requestIDs,
                batchedCaches: batchedCaches,
                compiledCaches: [],
                compiledStep: nil
            )
        }
        let cachesAsKV = batchedCaches.map(\.cache)
        let canCompile = compiledDecode
            && !hasBatchedState
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
                // Sampler dtype (uint32): no device-side conversion (#2256).
                let stepTokens = current.asArray(UInt32.self).map(Int.init)
                guard stepTokens.count == supportedInputs.count else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_logits_shape")
                }
                for index in supportedInputs.indices {
                    labCaptureTargetLogits(
                        requestID: supportedInputs[index].requestID,
                        position: supportedInputs[index].samplerStep + stepIndex,
                        tokenIDs: [stepTokens[index]], logits: logits[index, -1, 0...].reshaped(1, -1))
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
            // Ordinary rows keep each step's sampled tokens on the device as
            // the next step's input and queue that step before the host reads
            // the previous one, so the GPU never waits on the host inside a
            // window; the window end is its one draining sync. Rows that need
            // host tokens before the next forward (recurrent stop
            // checkpoints, drafter hidden capture, batched model state) read
            // each step before queuing the next.
            let pipelined = !checkpointStops && captureIndices.isEmpty && !hasBatchedState
            var deviceTokens: MLXArray?
            var pendingStep: (index: Int, sampled: MLXArray, logits: MLXArray, state: LMOutput.State?)?
            /// Host side of one step. False ends the window early.
            func readStep(
                _ stepIndex: Int, sampled: MLXArray, logits: MLXArray, state: LMOutput.State?
            ) throws -> Bool {
                // Read in the sampler's own dtype (uint32). `asArray(Int.self)`
                // converts on the device: a new op queued behind the step
                // already in flight, so the host would wait for that step and
                // the GPU would idle while the next step is built (#2256).
                let stepSampled = sampled.asArray(UInt32.self).map(Int.init)
                guard stepSampled.count == supportedInputs.count else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_logits_shape")
                }
                for index in supportedInputs.indices {
                    labCaptureTargetLogits(
                        requestID: supportedInputs[index].requestID,
                        position: supportedInputs[index].samplerStep + stepIndex,
                        tokenIDs: [stepSampled[index]], logits: logits[index, -1, 0...].reshaped(1, -1))
                }
                #if DEBUG || MACPROVIDER_LAB_HARNESS
                if NativeMTPLabTokenTrace.enabled {
                    for (index, input) in supportedInputs.enumerated()
                    where input.samplerStep + stepIndex < NativeMTPLabTokenTrace.limit {
                        let top = NativeMTPLabTokenTrace.topTwo(logits[index, -1, 0...].reshaped(1, -1))[0]
                        let kvBefore = input.committedKVTokenCount + stepIndex
                        NativeMTPLabTokenTrace.write(requestID: input.requestID, path: "decode", [.init(
                            index: input.samplerStep + stepIndex, column: 0, width: 1, source: "target",
                            token: stepSampled[index], top1: top.top1, top2: top.top2, margin: top.margin,
                            kvBefore: kvBefore, kvAfter: kvBefore + 1
                        )])
                    }
                }
                #endif
                if !captureIndices.isEmpty {
                    guard let hidden = state?[mtpLastHiddenStatesKey],
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
                    return false
                }
                return true
            }
            var stopped = false
            for stepIndex in 0 ..< decodeSteps {
                let tokenInput = deviceTokens
                    ?? MLXArray(currentTokens.map(Int32.init)).reshaped([supportedInputs.count, 1])
                let text = LMInput.Text(tokens: tokenInput)
                let stepState: LMOutput.State?
                if hasBatchedState, let invariantStateModel {
                    do {
                        stepState = try invariantStateModel.batchDecodeState(
                            rowStates.map(\.state),
                            cacheOffsets: supportedInputs.map { $0.committedKVTokenCount + stepIndex }
                        )
                    } catch {
                        // A later merge failure must not leave an earlier step's
                        // advanced cache available for a retry at the old offset.
                        if stepIndex > 0 { discardAdvancedRows() }
                        return supportedInputs.map { .rowFailure(requestID: $0.requestID) }
                    }
                } else if captureIndices.isEmpty {
                    stepState = supportedInputs.count == 1 ? rowStates[0].state : nil
                } else {
                    var emit = LMOutput.State()
                    emit[mtpEmitFlagKey] = true
                    stepState = emit
                }
                let output = withPreparedCache(cachesAsKV, lengths: text.sequenceLengths) {
                    model(text, cache: cachesAsKV, state: stepState)
                }
                if hasBatchedState, let invariantStateModel, let stepState {
                    do {
                        try invariantStateModel.validateBatchDecodeState(output.state, against: stepState)
                    } catch {
                        // Forward already mutated the batch cache. Publish no
                        // tokens, and never reuse that cache with retained state.
                        discardAdvancedRows()
                        return supportedInputs.map { .rowFailure(requestID: $0.requestID) }
                    }
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
                let logits = output.logits
                let sampled = ContinuousBatchRowSampler.sample(
                    logits: logits[0..., -1, 0...],
                    rows: Self.samplerRows(supportedInputs, step: stepIndex)
                )
                if captureIndices.isEmpty {
                    if supportedInputs.count == 1 {
                        rowStates[0].state = output.state
                    } else if !hasBatchedState && output.state != nil {
                        return supportedInputs.map { ContinuousBatchDecodeOutcome.rowFailure(requestID: $0.requestID) }
                    }
                }
                if pipelined {
                    let next = sampled.reshaped([supportedInputs.count, 1])
                    asyncEval(next)
                    deviceTokens = next
                    if let previous = pendingStep {
                        guard try readStep(
                            previous.index, sampled: previous.sampled, logits: previous.logits, state: previous.state
                        ) else {
                            stopped = true
                            break
                        }
                    }
                    pendingStep = (stepIndex, sampled, logits, output.state)
                } else if try !readStep(stepIndex, sampled: sampled, logits: logits, state: output.state) {
                    stopped = true
                    break
                }
            }
            if !stopped, let last = pendingStep {
                _ = try readStep(last.index, sampled: last.sampled, logits: last.logits, state: last.state)
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
        targetBonusToken: Int,
        startsFresh: Bool = false
    ) throws {
        try requireTargetLockHeld("lab_record_committed_prefix")
        guard labNativeMTPObserverInstalled(), !tokens.isEmpty else { return }
        guard tokens.count == hidden.count else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_drafter_recompute_shape_mismatch")
        }
        eval(hidden)
        lock.lock()
        if startsFresh {
            labNativeMTPCommittedPrefixTokens.removeValue(forKey: requestID)
            labNativeMTPCommittedPrefixHidden.removeValue(forKey: requestID)
        }
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

    /// The independent recompute re-prepares a drafter over the row's whole
    /// committed prefix, so it costs O(context) per call; run on every
    /// finalize it grew window J's finalize phase from 117 to 168 ms over
    /// ~450 tokens. At finalize (`sampledAtFinalize`) it runs on a row's
    /// first committed round and then once each time the prefix crosses
    /// another multiple of this many tokens (the glm5_next paged-KV block).
    /// Prefill, prompt-chunk, flush and abort sites still recompute on every
    /// call; they run once per request or rarely.
    static let labDrafterRecomputeIntervalTokens = 256

    static func labDrafterRecomputeDue(
        lastRecomputedPrefixTokens: Int?,
        prefixTokens: Int,
        intervalTokens: Int = labDrafterRecomputeIntervalTokens
    ) -> Bool {
        guard let lastRecomputedPrefixTokens else { return true }
        return prefixTokens / intervalTokens > lastRecomputedPrefixTokens / intervalTokens
    }

    private func labRecomputeNativeMTPDrafterDigest(
        targetModel: any LanguageModel,
        requestID: String,
        sampledAtFinalize: Bool = false
    ) async throws {
        try requireTargetLockHeld("lab_recompute_drafter_digest")
        guard labNativeMTPObserverInstalled(), let drafterContainer else { return }
        lock.lock()
        let tokens = labNativeMTPCommittedPrefixTokens[requestID] ?? []
        let hidden = labNativeMTPCommittedPrefixHidden[requestID] ?? []
        let unsupportedPositionDeltas = labNativeMTPPrefixPositionDeltasUnsupported.contains(requestID)
        let targetBonus = labNativeMTPCommittedPrefixTargetBonus[requestID]
        let actualSeed = nativeMTPDrafterSeedTokens[requestID]
        let lastRecomputedPrefixTokens = labNativeMTPLastFinalizeRecomputePrefixTokens[requestID]
        lock.unlock()
        guard actualSeed != nil, let targetBonus, !tokens.isEmpty else { return }
        guard !sampledAtFinalize || Self.labDrafterRecomputeDue(
            lastRecomputedPrefixTokens: lastRecomputedPrefixTokens,
            prefixTokens: tokens.count
        ) else { return }
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
            guard let served = drafterContext.model as? any StatefulMTPDrafterModel else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_stateful_drafter_required")
            }
            // The recorded prefix already starts at the drafter's prompt
            // window, and the live drafter keeps every column committed after
            // it; replay all of it rather than window it again.
            let drafter: any StatefulMTPDrafterModel
            if let windowed = served as? GLM5NextMTPDraftModel {
                drafter = GLM5NextMTPDraftModel(
                    windowed.configuration, maximumDepth: windowed.maximumDepth, promptWindow: Int.max)
            } else {
                drafter = served
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
        if sampledAtFinalize {
            labNativeMTPLastFinalizeRecomputePrefixTokens[requestID] = tokens.count
        }
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
        try requireTargetLockHeld("prepare_drafter_state")
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
            return (
                state: state,
                seed: state.seedToken?.asType(.int32).asArray(Int32.self).first.map(Int.init),
                promptWindow: (statefulDrafter as? GLM5NextMTPDraftModel)?.promptWindow
            )
        }
        storeNativeMTPDrafterAdvance(requestIDs: [requestID], states: [prepared.state], seedTokens: [prepared.seed])
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        // Record only the columns the drafter prefilled (its prompt window).
        let recordedStart = prepared.promptWindow.map { max(0, prompt.dim(1) - $0) } ?? 0
        try labRecordNativeMTPCommittedPrefix(
            requestID: requestID,
            tokens: Array(prompt.asArray(Int32.self).map(Int.init).dropFirst(recordedStart)),
            hidden: Array(try Self.labHiddenColumns(targetHidden, count: prompt.dim(1)).dropFirst(recordedStart)),
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
    /// and the sampled first token for the final one. With a prompt window
    /// starting at `w` (`nativeMTPPromptWindowStart`), only columns `>= w`
    /// are fed, as the windowed single-pass seeding does: the chunk holding
    /// `w` starts from an empty drafter state, and each later chunk must find
    /// the state the previous chunk left at exactly position `c - w`.
    private func advanceNativeMTPDrafterOverPromptChunk(
        targetModel: any LanguageModel,
        input: ContinuousBatchPrefillInput,
        targetHidden: MLXArray,
        positionDeltas: MLXArray?,
        tailToken: Int
    ) async throws {
        try requireTargetLockHeld("advance_drafter_prompt_chunk")
        guard let drafterContainer else { return }
        // A drafter that keeps nothing from the prompt (the Gemma 4
        // assistant attends over the target's K/V) is left by single-pass
        // seeding with its fresh state and no seed; every chunk leaves the
        // same. Its packed advance needs the target K/V of a verified round,
        // which a prompt chunk has not got (#2328).
        if let promptFreeState = try await Self.promptFreeDrafterState(drafterContainer) {
            storeNativeMTPDrafterAdvance(
                requestIDs: [input.requestID],
                states: [promptFreeState],
                seedTokens: [nil]
            )
            #if DEBUG || MACPROVIDER_LAB_HARNESS
            try labRecordNativeMTPCommittedPrefix(
                requestID: input.requestID,
                tokens: input.promptTokens,
                hidden: try Self.labHiddenColumns(targetHidden, count: input.promptTokens.count),
                positionDeltas: positionDeltas,
                targetBonusToken: tailToken,
                startsFresh: input.promptTokenOffset == 0
            )
            #endif
            return
        }
        let chunkCount = input.promptTokens.count
        guard targetHidden.ndim == 3,
              targetHidden.dim(0) == 1,
              targetHidden.dim(1) >= chunkCount
        else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_invalid_prompt_hidden_state")
        }
        let windowStart = input.nativeMTPPromptWindowStart
        guard windowStart >= 0, windowStart < input.promptTokenOffset + chunkCount else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_invalid_prompt_window")
        }
        let skipped = Self.nativeMTPPromptChunkSkippedColumns(
            promptTokenOffset: input.promptTokenOffset,
            windowStart: windowStart
        )
        let priorState: MTPDrafterState?
        if input.promptTokenOffset <= windowStart {
            priorState = nil
        } else {
            guard let stored = nativeMTPDrafterState(for: input.requestID),
                  stored.nextPosition == input.promptTokenOffset - windowStart,
                  stored.proposalAppended == 0
            else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_missing_drafter_state")
            }
            priorState = stored
        }
        let row = (
            hidden: targetHidden[0..., skipped ..< chunkCount, 0...],
            acceptedTokens: Array(input.promptTokens.dropFirst(skipped + 1)),
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
            tokens: Array(input.promptTokens.dropFirst(skipped)),
            hidden: Array(try Self.labHiddenColumns(targetHidden, count: chunkCount).dropFirst(skipped)),
            positionDeltas: positionDeltas,
            targetBonusToken: tailToken,
            startsFresh: priorState == nil
        )
        try await labRecomputeNativeMTPDrafterDigest(targetModel: targetModel, requestID: input.requestID)
        #endif
    }

    /// Leading columns of prompt chunk `[promptTokenOffset, ...)` that lie
    /// before the drafter's prompt window and are not fed to it.
    static func nativeMTPPromptChunkSkippedColumns(promptTokenOffset: Int, windowStart: Int) -> Int {
        max(0, windowStart - promptTokenOffset)
    }

    /// The fresh state of a drafter that keeps nothing from committed
    /// columns (`requiresPromptPrefill` false: it attends over the target's
    /// K/V, like the Gemma 4 assistant), or nil for a drafter that must
    /// consume them.
    private static func promptFreeDrafterState(_ drafterContainer: MTPDrafterContainer) async throws -> MTPDrafterState? {
        try await drafterContainer.perform(nonSendable: ()) { drafterContext, _ in
            guard let drafter = drafterContext.model as? any StatefulMTPDrafterModel else {
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_stateful_drafter_required")
            }
            return drafter.requiresPromptPrefill ? nil : drafter.makeState(parameters: nil)
        }
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
        try requireTargetLockHeld("flush_drafter_columns")
        guard let drafterContainer, !requestIDs.isEmpty else { return }
        // A prompt-free drafter consumes no columns: its state after them is
        // its fresh state, and the next native round proposes nothing and
        // verifies one column, whose finalize carries the target K/V.
        if let promptFreeState = try await Self.promptFreeDrafterState(drafterContainer) {
            let (flushIDs, _) = try pendingNativeMTPDrafterAdvanceRows(
                requestIDs: requestIDs,
                minimumColumns: minimumColumns
            )
            lock.lock()
            for requestID in flushIDs {
                nativeMTPDrafterStates[requestID] = promptFreeState
                nativeMTPDrafterSeedTokens.removeValue(forKey: requestID)
                nativeMTPPendingDrafterColumns.removeValue(forKey: requestID)
            }
            lock.unlock()
            return
        }
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
        try requireTargetLockHeld("advance_drafters")
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
                state: state,
                sharedKV: transaction.targetState.sharedKV,
                sharedKVOffset: transaction.targetState.queryOffset
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
        labNativeMTPLastFinalizeRecomputePrefixTokens.removeValue(forKey: requestID)
        labNativeMTPNextRound.removeValue(forKey: requestID)
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

    /// Assigns each committing row its next native-round sequence number.
    /// Every committing finalize takes one, observer or not, so a round whose
    /// records go missing leaves a gap the journey detects.
    private func labBeginNativeMTPCommittedRound(requestIDs: [String]) -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        var rounds: [String: Int] = [:]
        for requestID in requestIDs {
            let round = labNativeMTPNextRound[requestID, default: 0]
            rounds[requestID] = round
            labNativeMTPNextRound[requestID] = round + 1
        }
        return rounds
    }

    #if DEBUG
    /// The finalize path's lab bookkeeping without a forward: assigns the
    /// committing rows' round numbers and records their before- and
    /// after-finalize digests, as `finalizeNativeMTPPackedRound` does.
    func labRecordCommittedFinalizeForTest(inputs: [ContinuousBatchNativeMTPFinalizeInput]) throws {
        enterTargetLock(); defer { exitTargetLock() }
        let rounds = labBeginNativeMTPCommittedRound(requestIDs: inputs.filter(\.shouldCommit).map(\.requestID))
        try recordNativeMTPStateDigest(phase: .beforeFinalize, inputs: inputs, transactions: [:], rounds: rounds)
        try recordNativeMTPStateDigest(phase: .afterFinalize, inputs: inputs, transactions: [:], rounds: rounds)
    }
    #endif

    private func recordNativeMTPStateDigest(
        phase: NativeMTPStateDigestPhase,
        inputs: [ContinuousBatchNativeMTPFinalizeInput],
        transactions: [String: NativeMTPPendingTransaction],
        rounds: [String: Int] = [:]
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
                committedProposalTokens: input.committedProposalTokenCount,
                nativeRound: rounds[input.requestID]
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
        try requireTargetLockHeld("row_target_cache_digest")
        lock.lock()
        let row = rows[requestID]
        lock.unlock()
        guard let row else {
            throw ContinuousBatchSchedulerError.unsupported("native_mtp_observer_missing_row_state")
        }
        // Every layer's state is canonicalized and evaluated together, then
        // hashed in one concurrent pass (one GPU wait, all cores), and fed to
        // the hasher in the same layer/slot order as before.
        // A paged MLA layer contributes its target-oracle view: the state a
        // later forward reads plus the rewind headroom every committed round
        // keeps (`PagedMLALatentCache.observerOracleState`, SPEC-048 MTP-6).
        let layers = try row.caches.map { cache in
            (
                cache: cache,
                shape: try rowTargetCacheDigestShape(for: cache),
                state: (cache as? PagedMLALatentCache)?.observerOracleState ?? cache.state
            )
        }
        let records = try Self.arrayDigestRecords(layers.flatMap { layer in
            layer.state.map { (array: $0, logicalTokens: layer.shape.logicalTokens) }
        })
        var nextRecord = records.makeIterator()
        var hasher = SHA256()
        Self.update(&hasher, label: "kind", value: "row-cache")
        for (layerIndex, layer) in layers.enumerated() {
            Self.update(&hasher, label: "layer", value: String(layerIndex))
            Self.update(&hasher, label: "type", value: String(describing: type(of: layer.cache)))
            Self.update(&hasher, label: "offset", value: String(layer.cache.offset))
            if layer.cache is PagedMLALatentCache {
                Self.update(&hasher, label: "view", value: "paged_mla_oracle_state_v1")
            }
            switch layer.shape {
            case .paged(let storedTokens, let blockSizeTokens):
                Self.update(&hasher, label: "paged_stored_tokens", value: String(storedTokens))
                Self.update(&hasher, label: "paged_block_size_tokens", value: String(blockSizeTokens))
            case .standard:
                break
            }
            Self.update(&hasher, label: "slot_count", value: String(layer.state.count))
            for slotIndex in layer.state.indices {
                guard let record = nextRecord.next() else {
                    throw ContinuousBatchSchedulerError.unsupported("native_mtp_observer_digest_record_mismatch")
                }
                Self.update(&hasher, label: "slot_\(slotIndex)", record: record)
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
            // A glm5_next drafter cache's state is already exactly its logical
            // contents (latent to `offset`, pooled, pending and folded keys,
            // empty slots as [0]), not [.., T, D] KV slabs to cut at the
            // drafter position.
            let logicalTokens: Int? = cache is any GLM5NextLatentCache ? nil : state.nextPosition
            for (slotIndex, array) in cache.state.enumerated() {
                try updateArrayDigest(
                    &hasher,
                    label: "slot_\(slotIndex)",
                    array: array,
                    logicalTokens: logicalTokens
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
        try requireTargetLockHeld("drafter_digest")
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
        let records = try arrayDigestRecords([(array: array, logicalTokens: logicalTokens)])
        update(&hasher, label: label, record: records[0])
    }

    /// One state array's digest input: its layout and the SHA-256 of each
    /// fixed-size chunk of its logical bytes, in order.
    struct ArrayDigestRecord: Equatable {
        let dType: String
        let dTypeBits: Int
        let shape: [Int]
        let byteCount: Int
        let chunkDigests: Data
    }

    /// A glm5_next row holds ~140 MB of KDA recurrent state (34 layers of
    /// 64x128x128 fp32) besides its MLA latent cache. One serial SHA-256
    /// pass over it took ~50 ms per digest, and the observer takes four per
    /// native round (window J: 52/83/117 ms propose/verify/finalize phases at
    /// 30 tokens of context, against 0/33/3 ms without the observer). The
    /// bytes are now hashed as 1 MiB chunks on every core; equal bytes still
    /// give equal digests and any changed byte changes its chunk digest.
    static let labDigestChunkBytes = 1 << 20

    static func arrayDigestRecords(
        _ arrays: [(array: MLXArray, logicalTokens: Int?)],
        chunkBytes: Int = labDigestChunkBytes
    ) throws -> [ArrayDigestRecord] {
        for entry in arrays {
            switch entry.array.dtype {
            case .float16, .bfloat16, .float32, .int32, .int64, .uint32, .uint64, .bool:
                break
            default:
                throw ContinuousBatchSchedulerError.unsupported("native_mtp_observer_unsupported_dtype")
            }
        }
        let canonical = try arrays.map { try canonicalLogicalArray($0.array, logicalTokens: $0.logicalTokens) }
        // One evaluation for every array instead of one GPU wait per slot.
        eval(canonical)
        return withExtendedLifetime(canonical) {
            // A contiguous array is read in place (the no-copy Data is valid
            // while `canonical` is alive); a strided slice is copied once. An
            // empty array (a GLM latent cache's unused slot) has no backing
            // pointer for the no-copy path.
            let data = canonical.map { $0.size == 0 ? $0.asData(access: .copy) : $0.asData(access: .noCopyIfContiguous) }
            let chunkDigests = concurrentChunkDigests(data.map(\.data), chunkBytes: chunkBytes)
            return canonical.indices.map { index in
                ArrayDigestRecord(
                    dType: String(describing: data[index].dType),
                    dTypeBits: canonical[index].itemSize * 8,
                    shape: data[index].shape,
                    byteCount: data[index].data.count,
                    chunkDigests: chunkDigests[index]
                )
            }
        }
    }

    /// The concatenated SHA-256 digests of each buffer's `chunkBytes`
    /// chunks (empty for an empty buffer), computed concurrently.
    static func concurrentChunkDigests(_ buffers: [Data], chunkBytes: Int) -> [Data] {
        precondition(chunkBytes > 0)
        var work: [(buffer: Int, range: Range<Int>)] = []
        for (index, buffer) in buffers.enumerated() {
            var start = 0
            while start < buffer.count {
                let end = min(start + chunkBytes, buffer.count)
                work.append((index, start ..< end))
                start = end
            }
        }
        let chunks = work
        let digestBytes = SHA256.byteCount
        var flat = [UInt8](repeating: 0, count: chunks.count * digestBytes)
        flat.withUnsafeMutableBytes { output in
            let output = output
            DispatchQueue.concurrentPerform(iterations: chunks.count) { item in
                let (buffer, range) = chunks[item]
                let digest = buffers[buffer].withUnsafeBytes { bytes in
                    var hasher = SHA256()
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[range]))
                    return hasher.finalize()
                }
                digest.withUnsafeBytes { digestBytesPointer in
                    UnsafeMutableRawBufferPointer(
                        rebasing: output[(item * digestBytes) ..< ((item + 1) * digestBytes)]
                    ).copyMemory(from: digestBytesPointer)
                }
            }
        }
        var result = Array(repeating: Data(), count: buffers.count)
        for (item, entry) in chunks.enumerated() {
            result[entry.buffer].append(contentsOf: flat[(item * digestBytes) ..< ((item + 1) * digestBytes)])
        }
        return result
    }

    private static func update(_ hasher: inout SHA256, label: String, record: ArrayDigestRecord) {
        update(&hasher, label: "\(label).dtype", value: record.dType)
        update(&hasher, label: "\(label).dtype_bits", value: String(record.dTypeBits))
        update(&hasher, label: "\(label).shape", value: record.shape.map(String.init).joined(separator: "x"))
        update(&hasher, label: "\(label).byte_count", value: String(record.byteCount))
        update(&hasher, label: "\(label).chunk_sha256", data: record.chunkDigests)
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
        session?.batchedCaches.forEach { $0.releaseRows() }
    }

    private func invalidateDecodeSession(containing requestID: String) {
        invalidateDecodeSession(containingAnyOf: [requestID])
    }

    /// Ends the decode session only when one of `requestIDs` rides it. A
    /// prompt chunk for a row outside the session leaves the decoding rows'
    /// caches untouched, so their packed batch stays valid; dropping it made
    /// every decode hop between two prompt chunks repack all decoding rows
    /// (a full copy of their KV) and then copy it again to grow.
    private func invalidateDecodeSession(containingAnyOf requestIDs: [String]) {
        lock.lock()
        let session: DecodeSession?
        if let current = decodeSession, requestIDs.contains(where: current.requestIDs.contains) {
            session = decodeSession
            decodeSession = nil
        } else {
            session = nil
        }
        lock.unlock()
        session?.batchedCaches.forEach { $0.releaseRows() }
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

    #if DEBUG
    func rowTargetCacheDigestForTest(requestID: String) throws -> String {
        enterTargetLock()
        defer { exitTargetLock() }
        return try rowTargetCacheDigest(requestID: requestID)
    }
    #endif

    func retainedRowCountForTest() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rows.count
    }

    /// Whether any paged attention layer of a retained row keeps K/V buffers
    /// of its own; nil for an unknown row.
    func rowHoldsOwnKVForTest(requestID: String) -> Bool? {
        existingRowState(for: requestID)?.caches.contains { ($0 as? PagedKVCache)?.holdsOwnKVBuffers == true }
    }

    func installRowStateForTest(
        caches: [KVCache],
        requestID: String,
        binding: PagedKVStorageBinding,
        state: LMOutput.State? = nil
    ) throws {
        try setRowState(RowState(caches: caches, state: state), for: requestID, binding: binding)
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

    static func batchLayerCacheForTest(rowCaches: [PagedKVCache], attachRows: Bool = false) -> any KVCache {
        PagedKVBatchLayerCache(rowCaches: rowCaches, attachRows: attachRows)
    }

    /// Ends a `batchLayerCacheForTest` batch for its rows, as a decode
    /// session does when it ends.
    static func detachBatchRowsForTest(_ cache: any KVCache) {
        (cache as? PagedKVBatchLayerCache)?.detachRows()
    }

    /// A decode session replacing `cache` evaluates its successor layer and
    /// then this (`PagedKVSharedLayerBatch.releaseRowsAndBuffers`).
    static func releaseBatchForTest(_ cache: any KVCache) {
        (cache as? PagedKVBatchLayerCache)?.detachRowsAndRelease()
    }

    static func materializeBatchForTest(_ cache: any KVCache) {
        (cache as? PagedKVBatchLayerCache)?.materialize()
    }

    /// A decode window end on a `batchLayerCacheForTest` batch.
    static func syncBatchRowsForTest(_ cache: any KVCache) {
        (cache as? PagedKVBatchLayerCache)?.syncRowsFromBatch()
    }

    /// The window-end row sync `performDecode` runs on a batch layer cache.
    static func batchLayerSyncRowsForTest(_ cache: any KVCache) {
        (cache as? PagedKVBatchLayerCache)?.syncRowsFromBatch()
    }

    /// Ragged one-token decode steps that wrote the batch buffer only.
    static var batchLayerDeferredRaggedDecodeStepsForTest: Int {
        PagedKVBatchLayerCache.deferredRaggedDecodeSteps
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
                    queryOffset: states[index].caches.lazy.compactMap { ($0 as? PagedKVCache)?.offset ?? ($0 as? PagedMLALatentCache)?.offset }.first ?? 0,
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
        maskOverride: MLXFast.ScaledDotProductAttentionMaskMode? = nil,
        maskWindowSize: Int? = nil
    ) throws -> MLXArray {
        let cache = raggedPrefill
            ? PagedKVRaggedPrefillBatchLayerCache(rowCaches: rowCaches)
            : PagedKVBatchLayerCache(rowCaches: rowCaches)
        if let mtpPackedRowMaps {
            try cache.prepareMTPPackedVerification(rowMaps: mtpPackedRowMaps)
        }
        let mask = maskOverride ?? cache.makeMask(n: queries.dim(2), windowSize: maskWindowSize, returnArray: false)
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
        lastBatchAttentionLeftCachePathForTest = cache.attendedOutsideCachePath
        return attended
    }

    /// Whether the last `batchAttentionForTest` call could not isolate its
    /// rows (the backend would fail that forward).
    nonisolated(unsafe) static var lastBatchAttentionLeftCachePathForTest = false

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
            samplerStep: input.samplerStep,
            grammarConstraint: input.sampleFirstToken ? input.grammarConstraint : nil
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
                samplerStep: $0.samplerStep + step,
                grammarConstraint: $0.grammarConstraint
            )
        }
    }

    private func makeBatchedCaches(
        from rowCaches: [[KVCache]],
        nativeMTP: Bool = false,
        raggedPrefill: Bool = false,
        attachRows: Bool = false
    ) throws -> [PagedKVSharedLayerBatch] {
        guard let layerCount = rowCaches.first?.count,
              rowCaches.allSatisfy({ $0.count == layerCount }),
              layerCount == cacheKinds.count,
              recurrentStateLayout != .lfm25ShortConvOneSlot
                || cacheKinds == PagedKVRecurrentStateLayout.lfm25ExpectedCacheKinds
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
                    : PagedKVBatchLayerCache(rowCaches: rows, attachRows: attachRows)
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
            case .pagedMLA:
                let rows = rowCaches.compactMap { $0[layerIndex] as? PagedMLALatentCache }
                guard rows.count == rowCaches.count else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
                }
                // Rows keep their own state; the batch only routes each row of
                // the forward to its cache, so there is nothing to sync.
                let cache = PagedMLABatchLayerCache(rowCaches: rows)
                return PagedKVSharedLayerBatch(
                    cache: cache,
                    validateBatchStateClosure: {},
                    syncRowsFromBatchClosure: {},
                    writebackCompiledInnerStateClosure: { _, _ in
                        throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
                    },
                    pendingMTPResolutionsClosure: {
                        try cache.pendingMTPResolutions().map {
                            NativeMTPPendingLayerResolution.pagedMLA($0)
                        }
                    }
                )
            case .pagedIndexedKV:
                let rows = rowCaches.compactMap { $0[layerIndex] as? PagedMiniMaxM3SparseCache }
                guard rows.count == rowCaches.count, !nativeMTP else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
                }
                let cache = PagedMiniMaxM3BatchLayerCache(rowCaches: rows)
                return PagedKVSharedLayerBatch(
                    cache: cache,
                    validateBatchStateClosure: {},
                    syncRowsFromBatchClosure: {},
                    writebackCompiledInnerStateClosure: { _, _ in
                        throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
                    },
                    pendingMTPResolutionsClosure: {
                        throw ContinuousBatchSchedulerError.unsupported("native_mtp_packed_cache_missing_staged_state")
                    }
                )
            case .deepseekV4Pool:
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_backend_required")
            case .recurrentMamba:
                let rows = rowCaches.compactMap { $0[layerIndex] as? MambaCache }
                guard rows.count == rowCaches.count else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
                }
                guard nativeMTP else {
                    let cache = MambaCache()
                    try Self.packMambaRows(rows, into: cache, stateLayout: recurrentStateLayout)
                    return PagedKVSharedLayerBatch(
                        cache: cache,
                        validateBatchStateClosure: {
                            guard cache.state.count == self.recurrentStateLayout.slotCount,
                                  cache.state.allSatisfy({ $0.ndim >= 1 && $0.dim(0) == rows.count })
                            else {
                                throw ContinuousBatchSchedulerError.unsupported(
                                    "continuous_batching_invalid_mamba_state"
                                )
                            }
                        },
                        syncRowsFromBatchClosure: {
                            Self.syncMambaRows(from: cache, into: rows, stateLayout: self.recurrentStateLayout)
                        },
                        writebackCompiledInnerStateClosure: { compiledState, targets in
                            guard targets.count == rows.count,
                                  compiledState.count == self.recurrentStateLayout.slotCount,
                                  compiledState.allSatisfy({ $0.ndim >= 1 && $0.dim(0) == rows.count })
                            else {
                                throw ContinuousBatchSchedulerError.unsupported(
                                    "continuous_batching_invalid_mamba_state"
                                )
                            }
                            cache.state = compiledState
                            Self.syncMambaRows(from: cache, into: rows, stateLayout: self.recurrentStateLayout)
                            try Self.packMambaRows(rows, into: cache, stateLayout: self.recurrentStateLayout)
                        },
                        pendingMTPResolutionsClosure: {
                            throw ContinuousBatchSchedulerError.unsupported(
                                "native_mtp_missing_recurrent_transaction"
                            )
                        }
                    )
                }
                guard recurrentStateLayout == .mambaTwoSlot else {
                    throw ContinuousBatchSchedulerError.unsupported("native_mtp_unsupported_recurrent_layout")
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

    /// The block-table handle a row's paged layers are bound to.
    private static func storageHandle(in caches: [KVCache]) -> PagedKVBlockTableHandle? {
        if let paged = pagedAttentionCaches(in: caches).first { return paged.binding.handle }
        if let latent = caches.lazy.compactMap({ ($0 as? PagedMLALatentCache)?.binding.handle }).first { return latent }
        return caches.lazy.compactMap { ($0 as? PagedMiniMaxM3SparseCache)?.binding.handle }.first
    }

    static func packMambaRows(
        _ rows: [MambaCache],
        into batch: MambaCache,
        stateLayout: PagedKVRecurrentStateLayout = .mambaTwoSlot
    ) throws {
        let rowStates = rows.map(\.state)
        guard rowStates.allSatisfy({ $0.isEmpty || $0.count == stateLayout.slotCount }) else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_mamba_state")
        }
        guard rowStates.contains(where: { !$0.isEmpty }) else { return }
        for slot in 0 ..< stateLayout.slotCount {
            guard let first = rowStates.first(where: { $0.indices.contains(slot) })?[slot] else {
                throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
            }
            // A one-token joining row has not run prefill, so its recurrent
            // state is empty. Its missing verified slots receive zero state.
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

    static func syncMambaRows(
        from batch: MambaCache,
        into rows: [MambaCache],
        stateLayout: PagedKVRecurrentStateLayout = .mambaTwoSlot
    ) {
        let batchedState = batch.state
        guard batchedState.count == stateLayout.slotCount,
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

    /// Syncs the rows and, for a batch its rows ride (decode sessions), gives
    /// each row still attached to it its own K/V back.
    func releaseRows() {
        if let cache = cache as? PagedKVBatchLayerCache {
            cache.detachRows()
        } else {
            syncRowsFromBatchClosure()
        }
    }

    /// `releaseRows` for a batch that is being replaced, also dropping its
    /// buffers so a replaced layer frees as soon as nothing reads it.
    func releaseRowsAndBuffers() {
        if let cache = cache as? PagedKVBatchLayerCache {
            cache.detachRowsAndRelease()
        } else {
            syncRowsFromBatchClosure()
        }
    }

    func materializePacked() {
        (cache as? PagedKVBatchLayerCache)?.materialize()
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
/// `v0.32.4-macprovider.4`, `mlx/backend/metal/scaled_dot_product_attention.cpp`:
/// vector mode at line 1508 (`q_pre.shape(2) <= 8`), one vs two passes at
/// line 1577, the `_gqa_<factor>` first-pass kernel at lines 754-763 (8x GQA
/// at head dim 64/128, 12x/16x GQA at head dim 128), the partition count at
/// lines 772-812 (with the `MLX_SDPA_BLOCKS` override at 808).
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

    /// Core's `MLX_SDPA_D512_MIN_KL` (default 1024; 0 lifts the head dim
    /// 512 defaults).
    static let d512MinimumKeyTokens: Int = {
        guard let raw = ProcessInfo.processInfo.environment["MLX_SDPA_D512_MIN_KL"],
              let value = Int(raw)
        else { return 1024 }
        return value
    }()

    /// Whether core attends a call of at most 8 query tokens with a vector
    /// kernel (fork core `has_fused_kernel` and `use_fallback`,
    /// scaled_dot_product_attention.cpp). Any other call takes the
    /// composite fallback, whose matmuls depend on the batch: no shared
    /// call is exact for it.
    static func takesVectorKernel(
        keyTokens n: Int,
        queryTokens: Int,
        gqaFactor: Int,
        headDim: Int,
        valueDim: Int,
        hasArrayMask: Bool,
        d512MinimumKeyTokens: Int = d512MinimumKeyTokens
    ) -> Bool {
        guard queryTokens <= n, queryTokens * gqaFactor <= 32 else { return false }
        // 192/192 has a vector kernel, but `use_fallback` prefers the
        // composite for it.
        let supported = (headDim == valueDim && [64, 96, 128, 256, 512].contains(headDim))
            || (headDim == 192 && valueDim == 128)
            || (headDim == 96 && valueDim == 64)
        guard supported else { return false }
        guard headDim == 512 else { return true }
        if d512MinimumKeyTokens != 0, queryTokens != 1 || gqaFactor != 8 || hasArrayMask {
            return false
        }
        return n >= d512MinimumKeyTokens
    }

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
              takesVectorKernel(
                  keyTokens: n, queryTokens: queryTokens, gqaFactor: queryHeads / kvHeads,
                  headDim: headDim, valueDim: valueDim, hasArrayMask: hasArrayMask
              ),
              let device = architecture.last
        else { return nil }
        let large = device == "d" || device == "s"
        let twoPass = (large && n >= 1024) || (kvHeads < queryHeads && n >= 4096)
        guard twoPass else { return Route(twoPass: false, partitions: 32, gqaKernel: false) }
        let gqaFactor = queryHeads / kvHeads
        let gqaDims = (gqaFactor == 8 && (headDim == 64 || headDim == 128))
            || ((gqaFactor == 12 || gqaFactor == 16) && headDim == 128)
        let gqaKernel = !hasArrayMask && queryTokens == 1 && headDim == valueDim && gqaDims && n >= 8192
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

/// Diagnostic only (off unless a probe turns it on): exact bit
/// fingerprints of one row's inputs and output at every paged attention
/// call, in call order, so a lone run and a shared run of the same row can
/// be compared call by call (#2328).
enum PagedKVAttentionTrace {
    struct Entry: Equatable {
        /// Forward index in the run: prompt chunks first, then decode steps.
        let forward: Int
        /// Order of the row's layer cache among the caches the run attended.
        let layer: Int
        let queryTokens: Int
        let keyTokens: Int
        let kvHeads: Int
        let windowed: Bool
        let queries: [Int64]
        let keys: [Int64]
        let values: [Int64]
        let output: [Int64]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabled = false
    nonisolated(unsafe) private static var layers: [ObjectIdentifier: Int] = [:]
    nonisolated(unsafe) private static var layerCounts: [Int: Int] = [:]
    nonisolated(unsafe) private static var forwards: [Int: Int] = [:]
    nonisolated(unsafe) private static var entries: [Int: [Entry]] = [:]

    /// Starts recording every row of every paged attention call.
    static func begin() {
        lock.lock()
        defer { lock.unlock() }
        enabled = true
        layers = [:]
        layerCounts = [:]
        forwards = [:]
        entries = [:]
    }

    /// Stops recording; the entries of each batch row index, in call order.
    static func end() -> [Int: [Entry]] {
        lock.lock()
        defer { lock.unlock() }
        enabled = false
        let recorded = entries
        entries = [:]
        layers = [:]
        return recorded
    }

    static func record(rowCaches: [PagedKVCache], queries: MLXArray, keys: MLXArray, values: MLXArray, output: MLXArray) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        let rows = min(rowCaches.count, queries.dim(0), keys.dim(0), values.dim(0), output.dim(0))
        for row in 0 ..< rows {
            let id = ObjectIdentifier(rowCaches[row])
            let layer: Int
            if let known = layers[id] {
                layer = known
            } else {
                layer = layerCounts[row, default: 0]
                layerCounts[row] = layer + 1
                layers[id] = layer
            }
            if layer == 0 { forwards[row, default: -1] += 1 }
            func own(_ array: MLXArray) -> [Int64] {
                fingerprint(array[row ..< row + 1, 0..., 0..., 0...])
            }
            entries[row, default: []].append(Entry(
                forward: forwards[row, default: 0],
                layer: layer,
                queryTokens: queries.dim(2),
                keyTokens: rowCaches[row].offset,
                kvHeads: keys.dim(1),
                windowed: rowCaches[row].attentionWindowTokens != nil,
                queries: own(queries),
                keys: own(keys),
                values: own(values),
                output: own(output)
            ))
        }
    }

    /// Two exact integer sums over the array's raw bits (plain and
    /// position-weighted): equal arrays give equal sums, and any changed
    /// element changes them.
    static func fingerprint(_ array: MLXArray) -> [Int64] {
        let raw: MLXArray
        switch array.itemSize {
        case 2: raw = array.view(dtype: .uint16)
        case 4: raw = array.view(dtype: .uint32)
        default: raw = array.asType(.float32).view(dtype: .uint32)
        }
        let flat = raw.asType(.int64).reshaped([-1])
        let weights = (MLXArray.arange(flat.dim(0), dtype: .int64) % 65_521) + 1
        let sums = stacked([flat.sum(), (flat * weights).sum()])
        eval(sums)
        return sums.asArray(Int64.self)
    }
}

enum PagedKVRowAttention {
    /// Whether MLX core reduces a row attended alone in another order than
    /// the same row inside one batched call of equal-length rows, so each row
    /// needs its own call. That holds for a call over a single KV head that
    /// core attends with its composite fallback: every prompt call (more than
    /// 8 query tokens) and every short call no vector kernel takes
    /// (`PagedKVVectorAttentionRoute.route` is nil), such as head dim 512 at
    /// a GQA factor other than 8. Alone, the fallback's two matmuls have one
    /// batch after `collapse_batches`: the query heads fold into the GEMM
    /// rows (fork core `matmul.cpp` batch collapse), and with few rows and a
    /// long history `scores @ V` takes split-K (`steel_gemm_splitk_axpby`,
    /// batch size 1 only), which sums keys in partitions. In a batch of two
    /// each row keeps its own batches: the plain GEMM for a prompt chunk,
    /// GEMV for one decode token. Gemma 4 12B's full-attention layers (16
    /// query heads, 1 KV head, head dim 512) hit this on the 64-token chunk
    /// after 1024 keys (M = 16 x 64, N = 512, K = 1088) and at every decode
    /// step (M = 16, N = 512, K = keys) (#2328). Vector kernels attend each
    /// (row, head) alone and keep one call.
    static func loneCallReducesDifferently(
        rows: Int,
        queryTokens: Int,
        queryHeads: Int,
        kvHeads: Int,
        headDim: Int,
        valueDim: Int,
        keyTokens: Int,
        loneCallHasArrayMask: Bool,
        architecture: String = PagedKVVectorAttentionRoute.deviceArchitecture
    ) -> Bool {
        guard rows > 1, kvHeads == 1 else { return false }
        return queryTokens > 8 || PagedKVVectorAttentionRoute.route(
            keyTokens: keyTokens,
            queryTokens: queryTokens,
            queryHeads: queryHeads,
            kvHeads: kvHeads,
            headDim: headDim,
            valueDim: valueDim,
            hasArrayMask: loneCallHasArrayMask,
            architecture: architecture,
            partitionOverride: nil
        ) == nil
    }

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
    case pagedMLA(PagedMLABatchLayerCache.PendingMTPResolution)
    case recurrent(MTPPackedMambaRowTransaction)

    var inputTokenCount: Int {
        switch self {
        case .pagedAttention(let resolution): resolution.inputTokenCount
        case .pagedMLA(let resolution): resolution.inputTokenCount
        case .recurrent(let resolution): resolution.inputCount
        }
    }

    var proposalTokenCount: Int {
        switch self {
        case .pagedAttention(let resolution): resolution.proposalTokenCount
        case .pagedMLA(let resolution): resolution.proposalTokenCount
        case .recurrent(let resolution): resolution.proposalCount
        }
    }

    /// Publish this layer's committed row state and return the arrays to
    /// evaluate. Finalize evaluates every row and layer of a round together.
    func stageCommit(inputCount: Int) throws -> [MLXArray] {
        switch self {
        case .pagedAttention(let resolution):
            try resolution.stageCommit(inputCount: inputCount)
        case .pagedMLA(let resolution):
            try resolution.stageCommit(inputCount: inputCount)
        case .recurrent(let resolution):
            try resolution.stageCommit(retaining: inputCount)
        }
    }
}

private class PagedKVBatchLayerCache: MTPPackedVerificationCache, KVCacheSinkAttentionProtocol, @unchecked Sendable {
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
    private let storage = PagedKVBatchStorage()
    private var keys: MLXArray? {
        get { storage.keys }
        set { storage.keys = newValue }
    }
    private var values: MLXArray? {
        get { storage.values }
        set { storage.values = newValue }
    }
    /// Decode-session batches hand each row's K/V to the batch buffers
    /// (`PagedKVCache.attachToBatch`) while the rows ride it, so a row's
    /// history is not held twice: once in its own cache and again, padded,
    /// in the batch. Rows get their own copy back when they leave
    /// (`detachRows`) or are next written outside the batch.
    private let attachesRows: Bool
    private var length = 0
    /// Each row's `mutationCount` right after this batch last wrote it. The
    /// in-place ragged path is used only while every row still matches, so a
    /// row changed elsewhere (bridge trim, state writeback) forces a rebuild.
    private var rowMutationCounts: [Int]?
    /// Live lockstep sequence length. When set, `update` concatenates on the
    /// batch tensors instead of looping per row (required for `MLX.compile()`).
    private var batchedOffset: Int?
    /// Ragged one-token decode (#2256): each row's live length while the batch
    /// buffer alone holds the rows' newest tokens, as `batchedOffset` does for
    /// lockstep rows. Set only while the buffer mirrors every row's history
    /// (row `r` in `[..<offset_r]`, zero past it); `syncRowsFromBatch` (or any
    /// path that reads the rows) writes them back first.
    private var deferredRowOffsets: [Int]?
    /// Test diagnostics (DEBUG builds count): one-token ragged steps that
    /// wrote the batch buffer only.
    nonisolated(unsafe) fileprivate static var deferredRaggedDecodeSteps = 0

    /// `attachRows` (decode sessions) attaches rows that hold full, unwindowed
    /// history; sliding-window rows take the per-row update path, where an
    /// attached row would copy its history out every step.
    init(rowCaches: [PagedKVCache], attachRows: Bool = false) {
        self.rowCaches = rowCaches
        self.attachesRows = attachRows
            && rowCaches.allSatisfy { !$0.reconstructViaGather && $0.attentionWindowTokens == nil }
        packFromRows()
    }

    private var rowsAttached: Bool {
        attachesRows && rowCaches.allSatisfy { $0.isAttached(to: storage) }
    }

    /// Ends this batch for its rows: syncs them, then gives every row still
    /// attached to it its own copy of its K/V. A row already re-attached to a
    /// newer batch keeps that batch's storage.
    func detachRows() {
        syncRowsFromBatch()
        for cache in rowCaches where cache.isAttached(to: storage) {
            cache.detachFromBatch()
        }
    }

    /// Evaluates the packed batch buffers now, so the arrays they were packed
    /// from (an older batch's buffers, joining rows' own K/V) can be freed
    /// layer by layer instead of all staying resident until the first forward.
    func materialize() {
        guard let keys, let values else { return }
        eval(keys, values)
    }

    /// `detachRows`, then drops this batch's buffers. Rows that left get a
    /// lazy copy of their history first, which keeps only what they need.
    func detachRowsAndRelease() {
        detachRows()
        keys = nil
        values = nil
        length = 0
        rowMutationCounts = nil
        batchedOffset = nil
    }

    var offset: Int {
        batchedOffset ?? deferredRowOffsets?.min() ?? (rowCaches.map(\.offset).min() ?? 0)
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
        // Deferred ragged rows write back each row's own prefix instead.
        if deferredRowOffsets != nil {
            flushDeferredRows()
            return
        }
        guard batchedOffset != nil else { return }
        if rowsAttached {
            // The rows already read their K/V from the batch buffers; only
            // their lengths move, as the `state` restore below would set them.
            rowCaches.forEach { $0.adoptBatchLength(length) }
            batchedOffset = nil
            return
        }
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
            Self.adoptWindowEnd(
                cache,
                keys: keys[rowIndex ..< rowIndex + 1, 0..., 0..., 0...],
                values: values[rowIndex ..< rowIndex + 1, 0..., 0..., 0...]
            )
        }
        batchedOffset = nil
    }

    /// A row takes back the history this batch decoded for it. The row's
    /// ring continues: unlike a restored snapshot, nothing re-linearized it,
    /// so it keeps `slidingRingAnchor` (the state setter would restart the
    /// ring there, and every later window would present its sliding-window
    /// keys in another slot order than its serial `RotatingKVCache`, #2256).
    private static func adoptWindowEnd(_ cache: PagedKVCache, keys: MLXArray, values: MLXArray) {
        let anchor = cache.slidingRingAnchor
        cache.state = [keys, values]
        cache.slidingRingAnchor = anchor
    }

    /// Writes deferred ragged rows back: row `r` takes `[..<offset_r]` of the
    /// buffer, which then still mirrors every row.
    private func flushDeferredRows() {
        guard let offsets = deferredRowOffsets else { return }
        deferredRowOffsets = nil
        guard let keys, let values else { return }
        for (rowIndex, cache) in rowCaches.enumerated() {
            Self.adoptWindowEnd(
                cache,
                keys: keys[rowIndex ..< rowIndex + 1, 0..., ..<offsets[rowIndex], 0...],
                values: values[rowIndex ..< rowIndex + 1, 0..., ..<offsets[rowIndex], 0...]
            )
        }
        rowMutationCounts = rowCaches.map(\.mutationCount)
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
            if incomingTokenCount > 1 { rowCaches.forEach { $0.slidingRingAnchor = length } }
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
            if length > 1 { rowCaches.forEach { $0.slidingRingAnchor = length } }
            return presentation(
                keys: incomingKeys,
                values: incomingValues,
                priorTokens: 0,
                incomingTokens: incomingKeys.dim(2)
            )
        }
        if let updated = updateDeferredRagged(keys: incomingKeys, values: incomingValues) {
            return updated
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
    /// its own keys. For the vector kernels a padded row keeps its lone bits
    /// whenever its own key length selects the same route as the padded call
    /// (`PagedKVVectorAttentionRoute`): both kernels deal key `i` to partition
    /// `i mod P` and skip masked keys. So one batched call serves every row
    /// whose lone route equals the padded call's, and only the others (a short
    /// row below the two-pass switch, a row in another partition-count class,
    /// a narrower verify row) attend in their own call.
    ///
    /// A split row's mask: for a plain mask this cache built (padding and
    /// causality only), the mask its lone call takes (none for one decode
    /// token, causal for a prompt chunk, its slice of the packed mask for
    /// verification); for any other array mask, its own slice of that mask,
    /// so the mask's semantics are kept. Sliding-window rows (decode only)
    /// attend over their presented suffix. A padded call that cannot be
    /// isolated (rows whose stored keys do not match their extents, an
    /// unmasked multi-token call, an unsupported layout) keeps the single
    /// call and is flagged like a model that calls SDPA itself, so the
    /// backend fails that forward and serializes rows. Rows of one length
    /// keep the single call. Every other operator stays batched.
    func updateAndAttend(
        queries: MLXArray,
        keys incomingKeys: MLXArray,
        values incomingValues: MLXArray,
        scale: Float,
        mask: MLXFast.ScaledDotProductAttentionMaskMode
    ) -> MLXArray {
        let output = attendRows(queries: queries, keys: incomingKeys, values: incomingValues, scale: scale, mask: mask, sinks: nil)
        PagedKVAttentionTrace.record(
            rowCaches: rowCaches, queries: queries, keys: incomingKeys, values: incomingValues, output: output
        )
        return output
    }

    /// GPT-OSS attention with per-head sinks takes the same per-row route:
    /// every split row's call carries the sinks the model's own call would.
    func updateAndAttend(
        queries: MLXArray,
        keys incomingKeys: MLXArray,
        values incomingValues: MLXArray,
        scale: Float,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        sinks: MLXArray
    ) -> MLXArray {
        let output = attendRows(queries: queries, keys: incomingKeys, values: incomingValues, scale: scale, mask: mask, sinks: sinks)
        PagedKVAttentionTrace.record(
            rowCaches: rowCaches, queries: queries, keys: incomingKeys, values: incomingValues, output: output
        )
        return output
    }

    private func attendRows(
        queries: MLXArray,
        keys incomingKeys: MLXArray,
        values incomingValues: MLXArray,
        scale: Float,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        sinks: MLXArray?
    ) -> MLXArray {
        let queryTokens = queries.dim(2)
        let packedRows = preparedMTPPackedRowMaps?.map { (queryOffset: $0.queryOffset, inputCount: $0.inputCount) }
        let offsetsBefore = preUpdateOffsets
        let window = presentationWindowTokens
        let windowed = rowCaches.contains { $0.attentionWindowTokens != nil }
        insideUpdateAndAttend = true
        let (keys, values) = update(keys: incomingKeys, values: incomingValues)
        insideUpdateAndAttend = false
        func batched() -> MLXArray {
            MLXFast.scaledDotProductAttention(
                queries: queries, keys: keys, values: values, scale: scale, mask: mask, sinks: sinks
            )
        }
        // Each row's keys start at column 0 of the buffer: its whole history,
        // or for a sliding-window row its presented suffix.
        let extentOffsets = windowed && window != nil
            ? offsetsBefore.map { PagedKVCache.slidingWindowPresentationPrefix(priorTokens: $0, windowSize: window) }
            : offsetsBefore
        guard let extents = PagedKVRowAttention.extents(
            queryTokens: queryTokens,
            offsetsBefore: extentOffsets,
            packedRows: packedRows
        ) else {
            // No row is padded: the one call is each row's lone call, except
            // where MLX core reduces a lone row in another order
            // (`PagedKVRowAttention.loneCallReducesDifferently`).
            let unpaddedPlainMask = PagedKVBatchLayerCache.maskIsPlainCacheMask(mask)
            var loneCallHasArrayMask = false
            // Packed verification rows take their slice of the packed mask,
            // as the split path gives them.
            if case .array = mask, !unpaddedPlainMask || packedRows != nil { loneCallHasArrayMask = true }
            guard PagedKVRowAttention.loneCallReducesDifferently(
                rows: queries.dim(0),
                queryTokens: queryTokens,
                queryHeads: queries.dim(1),
                kvHeads: keys.dim(1),
                headDim: queries.dim(3),
                valueDim: values.dim(3),
                keyTokens: keys.dim(2),
                loneCallHasArrayMask: loneCallHasArrayMask
            ), !windowed,
                queries.dim(0) == rowCaches.count, keys.dim(0) == rowCaches.count
            else {
                return batched()
            }
            if packedRows != nil, !loneCallHasArrayMask {
                attendedOutsideCachePath = true
                return batched()
            }
            var loneMask = mask
            if case .array(let array) = mask {
                if unpaddedPlainMask, packedRows == nil {
                    // Padding and causality only, and no row is padded: the
                    // mask the lone call takes (none for one decode token).
                    loneMask = queryTokens > 1 ? .causal : .none
                } else if array.ndim != 4 || (array.dim(0) != 1 && array.dim(0) != rowCaches.count) {
                    attendedOutsideCachePath = true
                    return batched()
                }
            }
            return concatenated((0 ..< rowCaches.count).map { row in
                var rowMask = loneMask
                if case .array(let array) = loneMask, array.dim(0) != 1 {
                    rowMask = .array(array[row ..< row + 1, 0..., 0..., 0...])
                }
                return MLXFast.scaledDotProductAttention(
                    queries: queries[row ..< row + 1, 0..., 0..., 0...],
                    keys: keys[row ..< row + 1, 0..., 0..., 0...],
                    values: values[row ..< row + 1, 0..., 0..., 0...],
                    scale: scale,
                    mask: rowMask,
                    sinks: sinks
                )
            }, axis: 0)
        }
        func notIsolatable() -> MLXArray {
            attendedOutsideCachePath = true
            return batched()
        }
        let storageMatches = packedRows == nil
            ? deferredRowOffsets.map { live in
                // Deferred rows live in the buffer this update just wrote.
                zip(live, offsetsBefore).allSatisfy { $0 == $1 + queryTokens }
            } ?? rowCaches.enumerated().allSatisfy({
                $0.element.offset == offsetsBefore[$0.offset] + queryTokens
                    && $0.element.storedTokens == $0.element.offset
            })
            : mtpPackedForwardDidUpdate && rowCaches.enumerated().allSatisfy({
                $0.element.storedTokens == offsetsBefore[$0.offset] && $0.element.offset == offsetsBefore[$0.offset]
            })
        guard queries.dim(0) == rowCaches.count,
              keys.dim(0) == rowCaches.count,
              keys.dim(2) == extents.map(\.keyTokens).max(),
              storageMatches,
              // Sliding windows: one window for every row, one decode token.
              !windowed || (window != nil && packedRows == nil && queryTokens == 1)
        else {
            return notIsolatable()
        }
        // How each split row is masked.
        let plainMask = PagedKVBatchLayerCache.maskIsPlainCacheMask(mask)
        var suppliedArray: MLXArray?
        if case .array(let array) = mask {
            guard array.ndim == 4,
                  array.dim(0) == rowCaches.count || array.dim(0) == 1,
                  array.dim(2) == queryTokens,
                  array.dim(3) == keys.dim(2)
            else {
                return notIsolatable()
            }
            suppliedArray = array
        } else if packedRows != nil {
            return notIsolatable()
        } else if case .none = mask, queryTokens > 1 {
            // An unmasked prompt chunk over padded keys has no per-row equal.
            return notIsolatable()
        }
        let sliceSupplied = packedRows != nil || (suppliedArray != nil && !plainMask)
        // Rows the one padded call already gives their lone bits.
        let sharedRows = PagedKVVectorAttentionRoute.rowsMatchingPaddedCall(
            extents: extents,
            queryTokens: queryTokens,
            paddedKeyTokens: keys.dim(2),
            queryHeads: queries.dim(1),
            kvHeads: keys.dim(1),
            headDim: queries.dim(3),
            valueDim: values.dim(3),
            // Only a plain cache-built mask (decode, ragged prompt or packed
            // verification) is known to exclude every row's padding; under
            // any other mask every padded row splits and attends over its own
            // keys only.
            paddedCallHasArrayMask: suppliedArray != nil && plainMask,
            loneCallHasArrayMask: sliceSupplied
        )
        let shared = sharedRows.isEmpty ? nil : batched()
        if let shared, sharedRows.count == extents.count {
            // Every row's lone route is the padded call's: it is the result.
            return shared
        }
        return concatenated(extents.enumerated().map { row, extent in
            if let shared, sharedRows.contains(row) {
                return shared[row ..< row + 1, 0..., 0..., 0...]
            }
            let rowMask: MLXFast.ScaledDotProductAttentionMaskMode
            if sliceSupplied, let suppliedArray {
                let maskRow = suppliedArray.dim(0) == 1 ? 0 : row
                rowMask = .array(suppliedArray[maskRow ..< maskRow + 1, 0..., ..<extent.queryTokens, ..<extent.keyTokens])
            } else {
                rowMask = extent.queryTokens > 1 ? .causal : .none
            }
            let attended = MLXFast.scaledDotProductAttention(
                queries: queries[row ..< row + 1, 0..., ..<extent.queryTokens, 0...],
                keys: keys[row ..< row + 1, 0..., ..<extent.keyTokens, 0...],
                values: values[row ..< row + 1, 0..., ..<extent.keyTokens, 0...],
                scale: scale,
                mask: rowMask,
                sinks: sinks
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

    /// Ragged one-token decode step on the batch buffer alone (#2256). The
    /// per-row paths cost several kernels per row per layer each step: each
    /// row cache appends, the buffer is written row by row, and a sliding
    /// window layer slices, ring-orders and re-concatenates every row's
    /// window. Here one scatter writes every row's token at its own length
    /// and, for a sliding window, one gather presents every row's window in
    /// the slot order its own row cache would (`PagedKVCache.presentation`),
    /// so attention sees the same tensor. The rows take their history back at
    /// the window end (`flushDeferredRows`), as lockstep rows do.
    ///
    /// Taken only for ragged rows whose buffer mirrors their history, that
    /// would all accept the token, and (sliding window) whose windows are
    /// full after it. Anything else flushes and returns nil, so the
    /// per-row paths keep handling it.
    private func updateDeferredRagged(keys incomingKeys: MLXArray, values incomingValues: MLXArray) -> (MLXArray, MLXArray)? {
        func decline() -> (MLXArray, MLXArray)? {
            flushDeferredRows()
            return nil
        }
        let window = presentationWindowTokens
        // Decode-session batches that attach rows (#2280) keep the rows' K/V
        // only in this buffer: `updateRaggedInPlace` writes the token once and
        // moves their lengths, while a deferred step would leave attached rows
        // behind their batch until a flush, and the flush would hand each row a
        // view of the buffer and detach it. That holds after an outside write
        // detached some rows too, so this checks the batch, not each row.
        guard !attachesRows,
              incomingKeys.dim(2) == 1,
              incomingValues.dim(2) == 1,
              rowCaches.count > 1,
              batchedOffset == nil,
              rowCaches.allSatisfy({ !$0.reconstructViaGather && $0.attentionWindowTokens == window })
        else {
            return decline()
        }
        let starts: [Int]
        if let deferredRowOffsets {
            starts = deferredRowOffsets
        } else {
            starts = rowCaches.map(\.storedTokens)
            guard Set(starts).count > 1,
                  rowCaches.allSatisfy({ $0.storedTokens > 0 && $0.storedTokens == $0.offset })
            else {
                return nil
            }
        }
        guard zip(rowCaches, starts).allSatisfy({ cache, start in start < (cache.maxSize ?? Int.max) }),
              window.map({ window in starts.allSatisfy { $0 >= window - 1 } }) ?? true
        else {
            return decline()
        }
        if deferredRowOffsets == nil,
           keys == nil || rowMutationCounts != rowCaches.map(\.mutationCount) || starts.max() != length {
            // The buffer no longer mirrors the rows (a sliding window layer
            // kept presented windows, or a row changed elsewhere): rebuild it
            // from the rows once.
            packFromRows()
        }
        guard let existingKeys = keys,
              let existingValues = values,
              deferredRowOffsets != nil || (rowMutationCounts == rowCaches.map(\.mutationCount) && starts.max() == length),
              Self.canWrite(incomingKeys, into: existingKeys),
              Self.canWrite(incomingValues, into: existingValues),
              let newKeys = Self.write(incomingKeys, into: existingKeys, rowStarts: starts, stored: length, maxTokens: maxSize, blockSizeTokens: blockSizeTokens),
              let newValues = Self.write(incomingValues, into: existingValues, rowStarts: starts, stored: length, maxTokens: maxSize, blockSizeTokens: blockSizeTokens)
        else {
            return decline()
        }
        let ends = starts.map { $0 + 1 }
        keys = newKeys
        values = newValues
        length = max(length, ends.max() ?? length)
        rowMutationCounts = nil
        deferredRowOffsets = ends
        #if DEBUG
        Self.deferredRaggedDecodeSteps &+= 1
        #endif
        guard let window, window > 0 else {
            return (Self.prefix(newKeys, length), Self.prefix(newValues, length))
        }
        // Row `r` presents keys `[end - window, end)` rotated right by its
        // ring shift: column `j` holds key `end - window + (j - shift) mod window`.
        var indices: [Int32] = []
        indices.reserveCapacity(rowCaches.count * window)
        for (rowIndex, cache) in rowCaches.enumerated() {
            let end = ends[rowIndex]
            let shift = PagedKVCache.slidingRingShift(
                postUpdateOffset: end,
                anchor: cache.slidingRingAnchor,
                windowSize: window
            )
            for column in 0 ..< window {
                indices.append(Int32(end - window + ((column - shift) % window + window) % window))
            }
        }
        let index = MLXArray(indices, [rowCaches.count, 1, window, 1])
        return (takeAlong(newKeys, index, axis: 2), takeAlong(newValues, index, axis: 2))
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
        if rowsAttached {
            // The batch buffers are the rows' only K/V: write them, then move
            // each row's length as its own `update` would have.
            guard rowCaches.allSatisfy({ $0.canAppend(n) }),
                  let newKeys = Self.write(incomingKeys, into: existingKeys, rowStarts: starts, stored: length, maxTokens: maxSize, blockSizeTokens: blockSizeTokens),
                  let newValues = Self.write(incomingValues, into: existingValues, rowStarts: starts, stored: length, maxTokens: maxSize, blockSizeTokens: blockSizeTokens)
            else {
                return nil
            }
            keys = newKeys
            values = newValues
            rowCaches.forEach { $0.advanceInBatch(n) }
            length = (starts.map { $0 + n }.max()) ?? length
            rowMutationCounts = rowCaches.map(\.mutationCount)
            return (Self.prefix(newKeys, length), Self.prefix(newValues, length))
        }
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
            flushDeferredRows()
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
        flushDeferredRows()
        let trimmed = rowCaches.map { $0.trim(n) }.min() ?? 0
        packFromRows()
        return trimmed
    }

    func makeMask(
        n: Int,
        windowSize: Int?,
        returnArray: Bool
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        let (mask, plain) = buildMask(n: n, windowSize: windowSize)
        if plain, case .array(let array) = mask {
            Self.plainMasks.lock.lock()
            Self.plainMasks.table.add(array)
            Self.plainMasks.lock.unlock()
        }
        return mask
    }

    /// Array masks this cache type built that only mask padding and keep
    /// causality (no sliding-window restriction), held weakly: the model
    /// passes the full-attention cache's mask to every attention layer of the
    /// forward. Under such a mask a split row's lone mask is equivalent.
    private static let plainMasks = (lock: NSLock(), table: NSHashTable<MLXArray>.weakObjects())

    fileprivate static func maskIsPlainCacheMask(_ mask: MLXFast.ScaledDotProductAttentionMaskMode) -> Bool {
        guard case .array(let array) = mask else { return false }
        plainMasks.lock.lock()
        defer { plainMasks.lock.unlock() }
        return plainMasks.table.contains(array)
    }

    /// The forward's mask, and whether it is plain (see `plainMasks`).
    private func buildMask(n: Int, windowSize: Int?) -> (MLXFast.ScaledDotProductAttentionMaskMode, Bool) {
        if let rowMaps = preparedMTPPackedRowMaps {
            return (.array(Self.makePackedMTPMask(n: n, rowMaps: rowMaps, windowSize: windowSize)), windowSize == nil)
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
        if n == 1, Set(presentedOffsets).count <= 1, !needsWindow { return (.none, true) }
        // Ragged shared prefill: every row adds the same `n` tokens from its own
        // offset, so query column q of row b sits at `offset_b + q`. The single
        // shared causal offset below cannot express that; build the per-row
        // causal mask instead. The backend only runs this shape for caches
        // without a presentation window (`supportsRaggedPrefillOffsets`), so key
        // column j is absolute position j.
        if n > 1, rowCaches.count > 1, Set(preUpdateOffsets).count > 1 {
            return (.array(PagedKVRaggedPrefillMask.make(
                queryTokens: n,
                rowOffsets: preUpdateOffsets,
                windowSize: windowSize
            )), windowSize == nil)
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
        // Plain when no window applies, or for one decode token whose
        // presented suffix already lies inside the window.
        return (.array(createCausalMask(
            n: n,
            offset: presentedOffsets.max() ?? offset,
            windowSize: effectiveWindow,
            lengths: MLXArray(presentedPostUpdateLengths.map(Int32.init))
        )), effectiveWindow == nil || (n == 1 && !needsWindow))
    }

    func prepare(lengths: [Int]?) {
        preparedLengths = lengths
    }

    func prepare(lengths: MLXArray?) {
        preparedLengths = lengths?.asArray(Int.self)
    }

    func prepareMTPPackedVerification(rowMaps: [MTPPackedVerificationRowMap]) throws {
        flushDeferredRows()
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
        flushDeferredRows()
        return PagedKVBatchLayerCache(rowCaches: rowCaches.map { $0.concreteCopy() })
    }

    fileprivate var preUpdateOffsets: [Int] {
        if let preparedMTPPackedRowMaps {
            return preparedMTPPackedRowMaps.map(\.queryOffset)
        }
        if let batchedOffset {
            return Array(repeating: batchedOffset, count: rowCaches.count)
        }
        if let deferredRowOffsets {
            return deferredRowOffsets
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
        let windowKeys = keys[.ellipsis, start..., 0...]
        let windowValues = values[.ellipsis, start..., 0...]
        guard incomingTokens == 1 else { return (windowKeys, windowValues) }
        // Lockstep rows share `end` but not their last prefill chunk, so each
        // row takes the ring layout its own serial cache would hold.
        let shifts = rowCaches.map {
            PagedKVCache.slidingRingShift(postUpdateOffset: end, anchor: $0.slidingRingAnchor, windowSize: window)
        }
        if Set(shifts).count == 1 {
            return (
                PagedKVCache.ringOrdered(windowKeys, shift: shifts[0]),
                PagedKVCache.ringOrdered(windowValues, shift: shifts[0])
            )
        }
        func perRow(_ array: MLXArray) -> MLXArray {
            concatenated(shifts.enumerated().map { row, shift in
                PagedKVCache.ringOrdered(array[row ..< row + 1, 0..., 0..., 0...], shift: shift)
            }, axis: 0)
        }
        return (perRow(windowKeys), perRow(windowValues))
    }

    private func packFromRows() {
        // Callers that need deferred rows' tokens flush first; this rebuilds
        // from the rows as they are.
        deferredRowOffsets = nil
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
        // Pack with room for the next decode tokens, so the first step after
        // a rebuild writes in place instead of copying the whole batch again
        // to grow it. Only `[..<length]` is ever presented.
        let longest = keyArrays.map { $0.dim(2) }.max() ?? 0
        let capacity = PagedKVBlockLayout.amortizedGrownCapacity(
            needed: longest + 1,
            maxTokens: max(longest, maxSize ?? Int.max),
            blockSizeTokens: blockSizeTokens
        )
        keys = Self.concatenatePadded(keyArrays, fallback: firstKey, paddedTo: capacity)
        values = Self.concatenatePadded(valueArrays, fallback: firstValue, paddedTo: capacity)
        length = longest
        rowMutationCounts = rowCaches.map(\.mutationCount)
        // `batchedOffset` asserts every row is at the same length (the
        // lockstep invariant). Setting it to the minimum for ragged rows made
        // the first step of every rebuilt batch treat all rows as that length:
        // `makeMask` returned no mask (shorter rows attended padding) and
        // `ropeOffset` gave longer rows the wrong positions. Studio: ragged
        // concurrent greedy rows diverged from serial or emitted EOS first.
        let offsets = rowCaches.map(\.offset)
        batchedOffset = Set(offsets).count == 1 ? offsets.first : nil
        // Rows whose stored K/V the packed buffers now hold in full drop
        // their own copy (a row with `storedTokens < offset` keeps it).
        // `concatenatePadded` falls back to one row's array when rows differ
        // in shape or dtype; those rows keep their own K/V.
        if attachesRows,
           keys?.dim(0) == rowCaches.count,
           values?.dim(0) == rowCaches.count,
           rowCaches.allSatisfy({ $0.storedTokens == $0.offset }) {
            for (rowIndex, cache) in rowCaches.enumerated() {
                cache.attachToBatch(storage, row: rowIndex)
            }
        }
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

    /// Writes `incoming` into the batch buffer in place, growing it by whole
    /// growth steps like `KVCacheSimple` when full. `rowStarts == nil` writes every row at
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
            let capacity = PagedKVBlockLayout.amortizedGrownCapacity(
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
        if let rowStarts, n == 1, rowStarts.count > 1 {
            // One token per row: a single scatter instead of one slice
            // write per row. Pure data movement, so the buffer is the same.
            let index = MLXArray(rowStarts.map(Int32.init), [rowStarts.count, 1, 1, 1])
            return putAlong(target, index, values: incoming, axis: 2)
        }
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

    /// Rows stacked on the batch axis, each zero-padded on the sequence axis
    /// to the longest row, or to `paddedTo` when that is longer.
    private static func concatenatePadded(_ arrays: [MLXArray], fallback: MLXArray, paddedTo: Int = 0) -> MLXArray {
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
        let maxSequenceLength = max(arrays.map { $0.dim(2) }.max() ?? 0, paddedTo)
        let padded = arrays.map { array -> MLXArray in
            let padTokens = maxSequenceLength - array.dim(2)
            guard padTokens > 0 else { return array }
            let pad = MLXArray.zeros([array.dim(0), array.dim(1), padTokens, array.dim(3)], dtype: array.dtype)
            return concatenated([array, pad], axis: 2)
        }
        return concatenated(padded, axis: 0)
    }
}
