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
final class PagedKVSharedForwardBackend: ContinuousBatchSchedulerBackend, @unchecked Sendable {
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

    private let container: ModelContainer
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
        compiledDecode: Bool = false
    ) {
        self.container = container
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
        compiledDecode: Bool = false
    ) {
        self.init(
            container: container,
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks,
            poolEpoch: descriptor.poolEpoch,
            layerCount: layerCount,
            cacheKinds: cacheKinds,
            contiguousCacheBridge: contiguousCacheBridge,
            compiledDecode: compiledDecode
        )
    }

    func prefill(rows inputs: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        return try await container.perform(nonSendable: inputs) { context, inputs in
            var outputs: [ContinuousBatchPrefillOutput] = []
            outputs.reserveCapacity(inputs.count)
            for input in inputs {
                var state = self.rowState(for: input.requestID, binding: input.binding, initialOffset: input.committedKVTokenCount)
                if !input.promptTokens.isEmpty {
                    let prompt = MLXArray(input.promptTokens.map(Int32.init)).reshaped([1, input.promptTokens.count])
                    let text = LMInput.Text(tokens: prompt)
                    let output = withPreparedCache(state.caches, lengths: text.sequenceLengths) {
                        context.model(text, cache: state.caches, state: state.state)
                    }
                    eval(output.logits)
                    state.state = output.state
                }
                try self.setRowState(state, for: input.requestID, binding: input.binding)
                outputs.append(ContinuousBatchPrefillOutput(requestID: input.requestID))
            }
            self.clearDecodeSession()
            return outputs
        }
    }

    func decode(rows inputs: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        guard !inputs.isEmpty else { return [] }
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        let supportedInputs = inputs.filter(Self.supportsGreedySampling)
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

    /// Greedy lockstep decode of `steps` tokens inside one `container.perform`.
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
        let supportedInputs = inputs.filter(Self.supportsGreedySampling)
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

    func finish(requestID: String) {
        invalidateDecodeSession(containing: requestID)
        removeRowState(for: requestID, discardRecordedCache: false)
    }

    func installRetainedPagedKVCache(
        requestID: String,
        handoff: PagedKVPagedCacheHandoff,
        binding: PagedKVStorageBinding
    ) async throws {
        guard cacheKinds.allSatisfy({ $0 == .pagedAttention }) else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_retained_hybrid_cache_unavailable")
        }
        let state = RowState(caches: handoff.caches, state: nil)
        try setRowState(state, for: requestID, binding: binding)
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

    func cancelInFlight() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            cancelRequested = true
            decodeSession = nil
            let handlesToDiscard = rows.compactMap { Self.pagedAttentionCaches(in: $0.value.caches).first?.binding.handle }
            rows.removeAll()
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
                compiledCaches = model.newCache(parameters: nil)
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
            for _ in 0 ..< decodeSteps {
                let logits = step.step(current)
                current = argMax(logits[0..., -1, 0...], axis: -1).reshaped([supportedInputs.count, 1])
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
            for _ in 0 ..< decodeSteps {
                let tokenInput = MLXArray(currentTokens.map(Int32.init)).reshaped([supportedInputs.count, 1])
                let text = LMInput.Text(tokens: tokenInput)
                let output = withPreparedCache(cachesAsKV, lengths: text.sequenceLengths) {
                    model(text, cache: cachesAsKV, state: supportedInputs.count == 1 ? rowStates[0].state : nil)
                }
                try batchedCaches.forEach { try $0.validateBatchState() }
                let stepSampled = argMax(output.logits[0..., -1, 0...], axis: -1).asArray(Int.self)
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
        storeDecodeSession(session)
        for (index, input) in supportedInputs.enumerated() {
            try self.setRowState(rowStates[index], for: input.requestID, binding: input.binding)
        }
        return zip(supportedInputs, sampledByRow).map { input, tokens in
            ContinuousBatchDecodeOutcome.output(ContinuousBatchDecodeOutput(
                requestID: input.requestID,
                tokens: tokens
            ))
        }
    }

    private func copyDecodeSession() -> DecodeSession? {
        lock.lock()
        defer { lock.unlock() }
        return decodeSession
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
        caches: [PagedKVCache],
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

    private static func supportsGreedySampling(_ input: ContinuousBatchDecodeInput) -> Bool {
        input.temperature == 0.0
            && input.topP == 1.0
            && input.presencePenalty == 0.0
            && input.frequencyPenalty == 0.0
    }

    private func makeBatchedCaches(from rowCaches: [[KVCache]]) throws -> [PagedKVSharedLayerBatch] {
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
                    }
                )
            case .recurrentMamba:
                let rows = rowCaches.compactMap { $0[layerIndex] as? MambaCache }
                guard rows.count == rowCaches.count else {
                    throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
                }
                let cache = MambaCache()
                try Self.packMambaRows(rows, into: cache)
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
}

private final class PagedKVBatchLayerCache: KVCache, @unchecked Sendable {
    private let rowCaches: [PagedKVCache]
    private var preparedLengths: [Int]?
    private var keys: MLXArray?
    private var values: MLXArray?
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

    var maxSize: Int? {
        rowCaches.compactMap(\.maxSize).min()
    }

    func innerState() -> [MLXArray] {
        guard let keys, let values else { return [] }
        return [keys, values]
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
        guard let keys, let values,
              keys.ndim == 4,
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
        if allowsLockstepConcat,
           let existingKeys = keys,
           let existingValues = values,
           existingKeys.dim(2) == offset
        {
            let newKeys = concatenated([existingKeys, incomingKeys], axis: 2)
            let newValues = concatenated([existingValues, incomingValues], axis: 2)
            keys = newKeys
            values = newValues
            batchedOffset = (batchedOffset ?? offset) + incomingKeys.dim(2)
            return (newKeys, newValues)
        }
        if allowsLockstepConcat, keys == nil, values == nil {
            keys = incomingKeys
            values = incomingValues
            batchedOffset = incomingKeys.dim(2)
            return (incomingKeys, incomingValues)
        }
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
        keys = mergedKeys
        values = mergedValues
        batchedOffset = nil
        return (mergedKeys, mergedValues)
    }

    var state: [MLXArray] {
        get { innerState() }
        set {
            guard newValue.count == 2 else { return }
            keys = newValue[0]
            values = newValue[1]
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

    func finalize() {
        preparedLengths = nil
    }

    func copy() -> any KVCache {
        PagedKVBatchLayerCache(rowCaches: rowCaches.map { $0.concreteCopy() })
    }

    private var preUpdateOffsets: [Int] {
        if let batchedOffset {
            return Array(repeating: batchedOffset, count: rowCaches.count)
        }
        return rowCaches.map(\.offset)
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
            batchedOffset = nil
            return
        }
        keys = Self.concatenatePadded(keyArrays, fallback: firstKey)
        values = Self.concatenatePadded(valueArrays, fallback: firstValue)
        // `batchedOffset` asserts every row is at the same length (the
        // lockstep invariant). Setting it to the minimum for ragged rows made
        // the first step of every rebuilt batch treat all rows as that length:
        // `makeMask` returned no mask (shorter rows attended padding) and
        // `ropeOffset` gave longer rows the wrong positions. Studio: ragged
        // concurrent greedy rows diverged from serial or emitted EOS first.
        let offsets = rowCaches.map(\.offset)
        batchedOffset = Set(offsets).count == 1 ? offsets.first : nil
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
