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
        binding: PagedKVStorageBinding
    ) {
        self.bridge = bridge
        self.handle = handle
        self.binding = binding
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

    func retain() async throws -> PagedKVRetainedSequence {
        try await bridge.retain(handle: handle)
    }

    func release() async throws {
        try await bridge.release(handle: handle)
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
        observation.matches(config: config)
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
        let binding = try await allocator.binding(for: handle)
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
    /// snapshot. This is the live FR-PKV10 handoff consumed by cold-tier and
    /// cross-turn callers; it is not a byte-only placeholder.
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
        let handle = try await allocator.reattach(retained, conversationKey: conversationKey)
        let binding = try await allocator.binding(for: handle)
        let attachment = PagedKVRequestAttachment(bridge: self, handle: handle, binding: binding)
        let layers = try attachment.makeCacheLayers(count: layerCount)
        let snapshot = try materializeContiguousByteCache(
            handle: handle,
            table: try await allocator.table(for: handle)
        )
        guard snapshot.layers.count == layerCount else {
            throw PagedKVRuntimeBridgeError.cacheLayerCountMismatch
        }
        for layer in snapshot.layers {
            guard layer.layerIndex < layers.count else {
                throw PagedKVRuntimeBridgeError.cacheLayerCountMismatch
            }
            try layers[layer.layerIndex].inject(materialized: layer)
        }
        return (attachment, layers)
    }

    func release(handle: PagedKVBlockTableHandle) async throws {
        try await allocator.release(handle)
        remove(handle)
    }

    private func remove(_ handle: PagedKVBlockTableHandle) {
        lock.lock()
        liveLayers.removeValue(forKey: handle.handleID)
        snapshots.removeValue(forKey: handle.handleID)
        lock.unlock()
        byteSnapshotStore.remove(handle)
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
