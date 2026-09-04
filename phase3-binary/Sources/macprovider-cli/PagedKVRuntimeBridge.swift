import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

/// Errors owned by the provider-local bridge. The allocator remains the source
/// of truth for block-table errors; these cases cover the bridge's cache/lifecycle
/// invariants around that allocator.
enum PagedKVRuntimeBridgeError: Error, Equatable {
    case unavailable
    case descriptorObservationMismatch
    case noCacheLayers
    case cacheLayerCountMismatch
    case cacheStateMismatch
    case logicalLengthMismatch
    case retainedSequenceUnavailable
}

private final class PagedKVByteSnapshotStore: @unchecked Sendable, PagedKVContiguousCacheBridge {
    private let lock = NSLock()
    private var snapshots: [UUID: PagedKVMaterializedByteCache] = [:]

    func store(_ snapshot: PagedKVMaterializedByteCache) {
        lock.lock()
        snapshots[snapshot.handle.handleID] = snapshot
        lock.unlock()
    }

    func materializeContiguousByteCache(
        handle: PagedKVBlockTableHandle,
        table: PagedKVBlockTable
    ) throws -> PagedKVMaterializedByteCache {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = snapshots[handle.handleID],
              snapshot.handle == handle,
              snapshot.blockTable == table
        else { throw PagedKVRuntimeBridgeError.unavailable }
        return snapshot
    }

    func remove(_ handle: PagedKVBlockTableHandle) {
        lock.lock()
        snapshots.removeValue(forKey: handle.handleID)
        lock.unlock()
    }
}

/// A request-scoped reservation. The scheduler owns the same allocator handle;
/// model execution owns the `KVCache` objects created from this binding.
final class PagedKVRequestAttachment: @unchecked Sendable {
    let bridge: PagedKVRuntimeBridge
    let handle: PagedKVBlockTableHandle
    let binding: PagedKVStorageBinding
    private(set) var cacheLayers: [PagedKVCache] = []

    init(
        bridge: PagedKVRuntimeBridge,
        handle: PagedKVBlockTableHandle,
        binding: PagedKVStorageBinding,
        cacheLayers: [PagedKVCache] = []
    ) {
        self.bridge = bridge
        self.handle = handle
        self.binding = binding
        self.cacheLayers = cacheLayers
    }

    func makeCacheLayers(count: Int) throws -> [PagedKVCache] {
        guard count > 0 else { throw PagedKVRuntimeBridgeError.noCacheLayers }
        guard cacheLayers.isEmpty else { throw PagedKVRuntimeBridgeError.cacheStateMismatch }
        let layers = (0 ..< count).map { _ in
            PagedKVCache(descriptor: bridge.descriptor, binding: binding)
        }
        cacheLayers = layers
        bridge.register(layers: layers, for: handle)
        return layers
    }

    func checkpoint() async throws -> PagedKVMaterializedByteCache {
        guard !cacheLayers.isEmpty else { throw PagedKVRuntimeBridgeError.noCacheLayers }
        return try await bridge.checkpoint(handle: handle, layers: cacheLayers)
    }

    func validate() throws {
        try bridge.validate(layers: cacheLayers)
    }

    func retain() async throws -> PagedKVRetainedSequence {
        try await bridge.retain(handle: handle)
    }

    func release() async throws {
        try await bridge.release(handle: handle)
    }

    func discardRetained(_ retained: PagedKVRetainedSequence) async throws {
        try await bridge.discardRetained(
            retained,
            conversationKey: retained.conversationKeyForValidation
        )
    }
}

/// Provider-local owner for a real SPEC-039 request attach.
///
/// The bridge is deliberately constructed from an observed runtime identity and
/// an allocator. It never creates a descriptor from its own defaults. The caller
/// must install the descriptor produced by `PagedKVAttachGate` before this bridge
/// can create request caches.
final class PagedKVRuntimeBridge: @unchecked Sendable, PagedKVContiguousCacheBridge {
    let allocator: PagedKVBlockAllocator
    let observation: PagedKVRuntimeObservation
    let config: PagedKVConfig
    private(set) var descriptor: PagedKVDescriptor

    private let lock = NSLock()
    private let byteSnapshotStore: PagedKVByteSnapshotStore
    private var liveLayers: [UUID: [PagedKVCache]] = [:]
    private var snapshots: [UUID: PagedKVMaterializedByteCache] = [:]
    /// A failed release leaves allocator-owned blocks unresolved. Stop accepting
    /// new reservations until the process can be restarted with a fresh pool;
    /// explicit release retries remain allowed for the failed handle.
    private var unhealthy = false

    init(
        config: PagedKVConfig,
        observation: PagedKVRuntimeObservation,
        descriptor: PagedKVDescriptor
    ) throws {
        guard observation.matches(config: config),
              descriptor.blockSizeTokens == config.blockSizeTokens,
              descriptor.maxPhysicalBlocks == config.maxPhysicalBlocks,
              descriptor.supportedModelFamilies.contains(observation.modelFamily),
              descriptor.admits(
                  modelID: observation.modelID,
                  modelSHA256: observation.modelSHA256,
                  tokenizerSHA256: observation.tokenizerSHA256,
                  chatTemplateSHA256: observation.chatTemplateSHA256,
                  cacheClass: observation.cacheClass,
                  kvDType: observation.kvDType,
                  requiresMoE: observation.requiresMoEDispatch,
                  hardwareClass: observation.hardwareClass ?? "",
                  metallibSHA256: observation.metallibSHA256 ?? "",
                  kernelIdentifier: observation.kernelIdentifier ?? "",
                  parityLabel: observation.parityLabel ?? "",
                  poolEpoch: observation.poolEpoch ?? -1
              )
        else {
            throw PagedKVRuntimeBridgeError.descriptorObservationMismatch
        }
        let byteSnapshotStore = PagedKVByteSnapshotStore()
        self.config = config
        self.observation = observation
        self.descriptor = descriptor
        self.byteSnapshotStore = byteSnapshotStore
        self.allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks,
            poolEpoch: descriptor.poolEpoch,
            contiguousCacheBridge: byteSnapshotStore
        )
    }

    var isAttached: Bool {
        lock.lock()
        let healthy = !unhealthy
        lock.unlock()
        return healthy && observation.matches(config: config)
    }

    var isUnhealthy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unhealthy
    }

    func reserve(
        requestID: String,
        maxTokens: Int,
        initialTokens: Int = 0
    ) async throws -> PagedKVRequestAttachment {
        guard isAttached else { throw PagedKVRuntimeBridgeError.unavailable }
        let handle = try await allocator.allocate(
            conversationKey: requestID,
            maxTokens: maxTokens,
            initialTokens: initialTokens
        )
        guard isAttached else {
            await releaseAllocatorHandle(handle)
            throw PagedKVRuntimeBridgeError.unavailable
        }
        let binding: PagedKVStorageBinding
        do {
            binding = try await allocator.binding(for: handle)
        } catch {
            await releaseAllocatorHandle(handle)
            throw error
        }
        guard isAttached else {
            await releaseAllocatorHandle(handle)
            throw PagedKVRuntimeBridgeError.unavailable
        }
        return PagedKVRequestAttachment(bridge: self, handle: handle, binding: binding)
    }

    func register(layers: [PagedKVCache], for handle: PagedKVBlockTableHandle) {
        lock.lock()
        liveLayers[handle.handleID] = layers
        lock.unlock()
    }

    private func store(
        _ snapshot: PagedKVMaterializedByteCache,
        layers: [PagedKVCache]
    ) {
        lock.lock()
        snapshots[snapshot.handle.handleID] = snapshot
        liveLayers[snapshot.handle.handleID] = layers
        lock.unlock()
    }

    /// Advances the allocator table to the cache's logical length, extracts the
    /// physical sequence through the existing allocator bridge seam, and stores
    /// the validated neutral snapshot for synchronous protocol access.
    func checkpoint(
        handle: PagedKVBlockTableHandle,
        layers: [PagedKVCache]
    ) async throws -> PagedKVMaterializedByteCache {
        guard !layers.isEmpty else { throw PagedKVRuntimeBridgeError.noCacheLayers }
        guard layers.allSatisfy({ $0.binding.handle == handle }) else {
            throw PagedKVRuntimeBridgeError.cacheStateMismatch
        }
        try validate(layers: layers)
        let logicalLengths = Set(layers.map(\.offset))
        guard logicalLengths.count == 1,
              let logicalLength = logicalLengths.first
        else { throw PagedKVRuntimeBridgeError.logicalLengthMismatch }

        let current = try await allocator.table(for: handle).logicalTokenCount
        if logicalLength > current {
            _ = try await allocator.extend(handle, by: logicalLength - current)
        } else if logicalLength < current {
            _ = try await allocator.trim(handle, toLogicalTokens: logicalLength)
        }
        let table = try await allocator.table(for: handle)
        guard table.logicalTokenCount == logicalLength else {
            throw PagedKVRuntimeBridgeError.logicalLengthMismatch
        }
        let binding = try await allocator.binding(for: handle)
        for layer in layers {
            layer.refresh(binding: binding)
        }

        let materializedLayers = try layers.enumerated().map { index, layer in
            try layer.materializedByteLayer(layerIndex: index)
        }
        guard materializedLayers.allSatisfy({ $0.logicalTokenCount == table.logicalTokenCount }) else {
            throw PagedKVRuntimeBridgeError.logicalLengthMismatch
        }
        let snapshot = PagedKVMaterializedByteCache(
            handle: handle,
            blockTable: table,
            layers: materializedLayers
        )
        store(snapshot, layers: layers)
        byteSnapshotStore.store(snapshot)
        return snapshot
    }

    func validate(layers: [PagedKVCache]) throws {
        guard !layers.isEmpty else { throw PagedKVRuntimeBridgeError.noCacheLayers }
        guard layers.allSatisfy({ $0.invariantFailure == nil }) else {
            throw PagedKVRuntimeBridgeError.cacheStateMismatch
        }
    }

    /// The frozen engine protocol remains synchronous. It reads the last
    /// request-scoped snapshot; the async `checkpoint` above is the only method
    /// that publishes one, so a stale/mismatched table cannot be silently reused.
    func materializeContiguousByteCache(
        handle: PagedKVBlockTableHandle,
        table: PagedKVBlockTable
    ) throws -> PagedKVMaterializedByteCache {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = snapshots[handle.handleID],
              snapshot.handle == handle,
              snapshot.blockTable == table
        else {
            throw PagedKVRuntimeBridgeError.unavailable
        }
        return snapshot
    }

    /// Builds standalone `KVCacheSimple` layers from the validated contiguous
    /// snapshot for callers that explicitly request a contiguous handoff.
    func materializeContiguousKVCache(
        handle: PagedKVBlockTableHandle
    ) async throws -> [KVCache] {
        let snapshot = try await allocator.materializeContiguousByteCache(handle)
        return try snapshot.layers.sorted(by: { $0.layerIndex < $1.layerIndex }).map { layer in
            guard layer.keyShape == layer.valueShape,
                  layer.keyShape.count == 4,
                  layer.keyShape[2] == snapshot.blockTable.logicalTokenCount
            else { throw PagedKVRuntimeBridgeError.cacheStateMismatch }
            let cache = KVCacheSimple()
            cache.state = [
                MLXArray(layer.keyBytes, layer.keyShape, dtype: .float16),
                MLXArray(layer.valueBytes, layer.valueShape, dtype: .float16),
            ]
            return cache
        }
    }

    /// Retains the allocator-owned blocks, then reattaches the same handle for a
    /// later turn. The logical cache snapshot remains keyed by the same handle,
    /// so a mid-block trim can be applied before new tokens are appended.
    func retain(handle: PagedKVBlockTableHandle) async throws -> PagedKVRetainedSequence {
        try await allocator.retain(handle)
    }

    func reattach(
        _ retained: PagedKVRetainedSequence,
        conversationKey: String,
        layerCount: Int
    ) async throws -> (PagedKVRequestAttachment, [PagedKVCache]) {
        guard layerCount > 0 else { throw PagedKVRuntimeBridgeError.noCacheLayers }
        guard isAttached else { throw PagedKVRuntimeBridgeError.unavailable }
        let retainedLayers = layers(for: retained.handle)
        guard let retainedLayers, retainedLayers.count == layerCount else {
            throw PagedKVRuntimeBridgeError.retainedSequenceUnavailable
        }

        // Reattach the still-live allocator/cache backing directly. A retained
        // sequence must not round-trip through a contiguous byte snapshot: that
        // path is reserved for explicit materialization/export only.
        let handle = try await allocator.reattach(retained, conversationKey: conversationKey)
        guard isAttached else {
            await releaseAllocatorHandle(handle)
            remove(handle)
            throw PagedKVRuntimeBridgeError.unavailable
        }
        let binding: PagedKVStorageBinding
        do {
            binding = try await allocator.binding(for: handle)
        } catch {
            // Reattach clears the allocator's retained bit before binding is
            // read. Roll back the active handle so a partial reattach cannot
            // strand its reserved blocks.
            await releaseAllocatorHandle(handle)
            remove(handle)
            throw error
        }
        guard isAttached else {
            await releaseAllocatorHandle(handle)
            remove(handle)
            throw PagedKVRuntimeBridgeError.unavailable
        }
        for layer in retainedLayers {
            layer.refresh(binding: binding)
        }
        let attachment = PagedKVRequestAttachment(
            bridge: self,
            handle: handle,
            binding: binding,
            cacheLayers: retainedLayers
        )
        register(layers: retainedLayers, for: handle)
        return (attachment, retainedLayers)
    }

    func discardRetained(
        _ retained: PagedKVRetainedSequence,
        conversationKey: String
    ) async throws {
        try await allocator.discardRetained(retained, conversationKey: conversationKey)
        remove(retained.handle)
    }

    func release(handle: PagedKVBlockTableHandle) async throws {
        do {
            try await allocator.release(handle)
            remove(handle)
        } catch {
            markUnhealthy()
            throw error
        }
    }

    private func markUnhealthy() {
        lock.lock()
        unhealthy = true
        lock.unlock()
    }

    private func releaseAllocatorHandle(_ handle: PagedKVBlockTableHandle) async {
        for _ in 0..<2 {
            do {
                try await allocator.release(handle)
                return
            } catch {
                continue
            }
        }
        markUnhealthy()
    }

    private func remove(_ handle: PagedKVBlockTableHandle) {
        lock.lock()
        liveLayers.removeValue(forKey: handle.handleID)
        snapshots.removeValue(forKey: handle.handleID)
        lock.unlock()
        byteSnapshotStore.remove(handle)
    }

    private func layers(for handle: PagedKVBlockTableHandle) -> [PagedKVCache]? {
        lock.lock()
        defer { lock.unlock() }
        return liveLayers[handle.handleID]
    }
}

/// The scheduler's backend-facing representation of a decode forward. The
/// shape is part of the value so tests and the production driver can assert that
/// one shared invocation receives exactly `[B, 1]`, rather than accidentally
/// falling back to one hidden model call per row.
struct PagedKVSharedForwardBatch: Sendable, Equatable {
    let tokens: [Int]

    var shape: [Int] { [tokens.count, 1] }
}

protocol PagedKVSharedForwardDriver: Sendable {
    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput]
    func decode(
        batch: PagedKVSharedForwardBatch,
        rows: [ContinuousBatchDecodeInput]
    ) async throws -> [ContinuousBatchDecodeOutcome]
    func cancelInFlight() async
}

/// Adapter from the SPEC-038 scheduler to a model driver. The scheduler still
/// owns admission, block lifecycle, cancellation, and row isolation; this type
/// only packages active row tokens as the shared `[B,1]` input and forwards the
/// call once.
struct PagedKVSharedForwardBackend: ContinuousBatchSchedulerBackend {
    let driver: any PagedKVSharedForwardDriver

    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        try await driver.prefill(rows: rows)
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        guard !rows.isEmpty else { return [] }
        let batch = PagedKVSharedForwardBatch(tokens: rows.map(\.currentToken))
        guard batch.shape == [rows.count, 1] else {
            throw PagedKVRuntimeBridgeError.cacheStateMismatch
        }
        return try await driver.decode(batch: batch, rows: rows)
    }

    func cancelInFlight() async {
        await driver.cancelInFlight()
    }
}
