import Foundation

public enum PagedKVDType: String, Sendable, Equatable, Codable {
    case fp16

    public var byteWidth: Int {
        switch self {
        case .fp16: return 2
        }
    }
}

public struct PagedKVDescriptor: Equatable, Sendable, Codable {
    public var blockSizeTokens: Int
    public var maxPhysicalBlocks: Int
    public var modelID: String
    public var modelSHA256: String
    public var tokenizerSHA256: String?
    public var chatTemplateSHA256: String?
    public var supportedModelFamilies: [String]
    public var allowedCacheClasses: [String]
    public var kvDType: PagedKVDType
    public var supportsMoEDispatch: Bool
    public var hardwareClass: String?
    public var metallibSHA256: String
    public var kernelIdentifier: String
    public var parityLabel: String
    public var poolEpoch: Int

    init(
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        modelID: String,
        modelSHA256: String,
        tokenizerSHA256: String? = nil,
        chatTemplateSHA256: String? = nil,
        supportedModelFamilies: [String],
        allowedCacheClasses: [String] = PagedKVAttachGate.allowedCacheClasses,
        kvDType: PagedKVDType = .fp16,
        supportsMoEDispatch: Bool,
        hardwareClass: String? = nil,
        metallibSHA256: String,
        kernelIdentifier: String,
        parityLabel: String,
        poolEpoch: Int = 1
    ) {
        self.blockSizeTokens = blockSizeTokens
        self.maxPhysicalBlocks = maxPhysicalBlocks
        self.modelID = modelID
        self.modelSHA256 = modelSHA256
        self.tokenizerSHA256 = tokenizerSHA256
        self.chatTemplateSHA256 = chatTemplateSHA256
        self.supportedModelFamilies = supportedModelFamilies
        self.allowedCacheClasses = allowedCacheClasses
        self.kvDType = kvDType
        self.supportsMoEDispatch = supportsMoEDispatch
        self.hardwareClass = hardwareClass
        self.metallibSHA256 = metallibSHA256
        self.kernelIdentifier = kernelIdentifier
        self.parityLabel = parityLabel
        self.poolEpoch = poolEpoch
    }

    public func admits(
        modelID: String,
        modelSHA256: String,
        tokenizerSHA256: String?,
        chatTemplateSHA256: String?,
        cacheClass: String,
        kvDType: PagedKVDType,
        requiresMoE: Bool,
        hardwareClass: String,
        metallibSHA256: String,
        kernelIdentifier: String,
        parityLabel: String,
        poolEpoch: Int
    ) -> Bool {
        self.modelID == modelID
            && self.modelSHA256 == modelSHA256
            && self.tokenizerSHA256 == tokenizerSHA256
            && self.chatTemplateSHA256 == chatTemplateSHA256
            && allowedCacheClasses.contains(cacheClass)
            && self.kvDType == kvDType
            && (!requiresMoE || supportsMoEDispatch)
            && self.hardwareClass == hardwareClass
            && self.metallibSHA256 == metallibSHA256
            && self.kernelIdentifier == kernelIdentifier
            && self.parityLabel == parityLabel
            && self.poolEpoch == poolEpoch
    }

    func admits(modelFamily: String, cacheClass: String, kvDType: PagedKVDType, requiresMoE: Bool) -> Bool {
        supportedModelFamilies.contains(modelFamily)
            && allowedCacheClasses.contains(cacheClass)
            && self.kvDType == kvDType
            && (!requiresMoE || supportsMoEDispatch)
    }
}

public struct PagedKVHardwareSizingProof: Equatable, Sendable, Codable {
    public let modelID: String
    public let modelSHA256: String
    public let tokenizerSHA256: String?
    public let chatTemplateSHA256: String?
    public let modelFamily: String
    public let hardwareClass: String
    public let metallibSHA256: String
    public let kernelIdentifier: String
    public let blockSizeTokens: Int
    public let maxPhysicalBlocks: Int
    public let maxResidentTokens: Int
    public let poolEpoch: Int
    public let parityLabel: String

    public init(
        modelID: String,
        modelSHA256: String,
        tokenizerSHA256: String?,
        chatTemplateSHA256: String?,
        modelFamily: String,
        hardwareClass: String,
        metallibSHA256: String,
        kernelIdentifier: String,
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        maxResidentTokens: Int,
        poolEpoch: Int = 1,
        parityLabel: String
    ) {
        self.modelID = modelID
        self.modelSHA256 = modelSHA256
        self.tokenizerSHA256 = tokenizerSHA256
        self.chatTemplateSHA256 = chatTemplateSHA256
        self.modelFamily = modelFamily
        self.hardwareClass = hardwareClass
        self.metallibSHA256 = metallibSHA256
        self.kernelIdentifier = kernelIdentifier
        self.blockSizeTokens = blockSizeTokens
        self.maxPhysicalBlocks = maxPhysicalBlocks
        self.maxResidentTokens = maxResidentTokens
        self.poolEpoch = poolEpoch
        self.parityLabel = parityLabel
    }

    public func covers(
        config: PagedKVConfig,
        modelID: String,
        modelSHA256: String,
        tokenizerSHA256: String?,
        chatTemplateSHA256: String?,
        modelFamily: String,
        observedHardwareClass: String,
        observedMetallibSHA256: String,
        observedKernelIdentifier: String,
        observedParityLabel: String,
        poolEpoch: Int
    ) -> Bool {
        self.modelID == modelID
            && self.modelSHA256 == modelSHA256
            && self.tokenizerSHA256 == tokenizerSHA256
            && self.chatTemplateSHA256 == chatTemplateSHA256
            && self.modelFamily == modelFamily
            && self.hardwareClass == observedHardwareClass
            && self.metallibSHA256 == observedMetallibSHA256
            && self.kernelIdentifier == observedKernelIdentifier
            && self.parityLabel == observedParityLabel
            && !hardwareClass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !metallibSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !kernelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !parityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && blockSizeTokens == config.blockSizeTokens
            && maxPhysicalBlocks >= config.maxPhysicalBlocks
            && maxResidentTokens >= config.maxResidentTokens
            && self.poolEpoch == poolEpoch
    }
}

public struct PagedKVGates: Equatable, Sendable {
    public let identityAvailable: Bool
    public let observedHardwareClass: String?
    public let metallibAvailable: Bool
    public let kernelRegistered: Bool
    public let parityEstablished: Bool
    public let hardwareSizingProof: PagedKVHardwareSizingProof?
    public let observedMetallibSHA256: String?
    public let observedKernelIdentifier: String?
    public let observedParityLabel: String?
    public let moeDispatchProven: Bool
    public let engineBridgeAvailable: Bool

    public init(
        identityAvailable: Bool,
        observedHardwareClass: String? = nil,
        metallibAvailable: Bool,
        kernelRegistered: Bool,
        parityEstablished: Bool,
        hardwareSizingProof: PagedKVHardwareSizingProof? = nil,
        observedMetallibSHA256: String? = nil,
        observedKernelIdentifier: String? = nil,
        observedParityLabel: String? = nil,
        moeDispatchProven: Bool = false,
        engineBridgeAvailable: Bool = false
    ) {
        self.identityAvailable = identityAvailable
        self.observedHardwareClass = observedHardwareClass
        self.metallibAvailable = metallibAvailable
        self.kernelRegistered = kernelRegistered
        self.parityEstablished = parityEstablished
        self.hardwareSizingProof = hardwareSizingProof
        self.observedMetallibSHA256 = observedMetallibSHA256
        self.observedKernelIdentifier = observedKernelIdentifier
        self.observedParityLabel = observedParityLabel
        self.moeDispatchProven = moeDispatchProven
        self.engineBridgeAvailable = engineBridgeAvailable
    }

    public static let closed = PagedKVGates(
        identityAvailable: false,
        observedHardwareClass: nil,
        metallibAvailable: false,
        kernelRegistered: false,
        parityEstablished: false,
        hardwareSizingProof: nil,
        observedMetallibSHA256: nil,
        observedKernelIdentifier: nil,
        observedParityLabel: nil,
        moeDispatchProven: false,
        engineBridgeAvailable: false
    )

    public static func runtimeClosed(identityAvailable: Bool, observedHardwareClass: String? = nil) -> PagedKVGates {
        PagedKVGates(
            identityAvailable: identityAvailable,
            observedHardwareClass: observedHardwareClass,
            metallibAvailable: false,
            kernelRegistered: false,
            parityEstablished: false,
            hardwareSizingProof: nil,
            observedMetallibSHA256: nil,
            observedKernelIdentifier: nil,
            observedParityLabel: nil,
            moeDispatchProven: false,
            engineBridgeAvailable: false
        )
    }
}

public enum PagedKVAttachDecision: Equatable, Sendable {
    case disabled
    case attached(PagedKVDescriptor)
    case fallback(PagedKVFallbackReason)
    case rejected(PagedKVFallbackReason)

    public var descriptor: PagedKVDescriptor? {
        if case .attached(let descriptor) = self { return descriptor }
        return nil
    }

    public var reason: PagedKVFallbackReason? {
        switch self {
        case .fallback(let reason), .rejected(let reason):
            return reason
        case .disabled, .attached:
            return nil
        }
    }
}

public enum PagedKVAttachGate {
    public static let allowedCacheClasses = ["KVCacheSimple"]
    public static let recognizedModelFamilies = ["llama", "qwen"]

    public static func decide(
        config: PagedKVConfig,
        runtimeCacheClass: String,
        kvBits: Int?,
        modelID: String,
        modelSHA256: String,
        tokenizerSHA256: String?,
        chatTemplateSHA256: String?,
        modelFamily: String,
        requiresMoEDispatch: Bool,
        gates: PagedKVGates
    ) -> PagedKVAttachDecision {
        guard config.effectiveEnabled else { return .disabled }

        func fail(_ reason: PagedKVFallbackReason) -> PagedKVAttachDecision {
            config.fallbackPolicy == .strict ? .rejected(.preflightReject) : .fallback(reason)
        }

        guard config.blockSizeTokens > 0,
              config.blockSizeTokens <= PagedKVConfig.maximumBlockSizeTokens,
              config.maxPhysicalBlocks > 0,
              config.maxPhysicalBlocks <= PagedKVConfig.maximumPhysicalBlocks
        else {
            return fail(.allocator)
        }
        guard kvBits == nil else { return fail(.quantized) }
        guard recognizedModelFamilies.contains(modelFamily) else { return fail(.identity) }
        guard gates.identityAvailable else { return fail(.identity) }
        guard allowedCacheClasses.contains(runtimeCacheClass) else { return fail(.cacheClass) }
        guard gates.metallibAvailable else { return fail(.metallib) }
        guard gates.kernelRegistered else { return fail(.kernel) }
        guard gates.parityEstablished else { return fail(.parity) }
        guard let sizingProof = gates.hardwareSizingProof,
              let observedHardwareClass = gates.observedHardwareClass,
              let observedMetallibSHA256 = gates.observedMetallibSHA256,
              let observedKernelIdentifier = gates.observedKernelIdentifier,
              let observedParityLabel = gates.observedParityLabel,
              sizingProof.covers(
                  config: config,
                  modelID: modelID,
                  modelSHA256: modelSHA256,
                  tokenizerSHA256: tokenizerSHA256,
                  chatTemplateSHA256: chatTemplateSHA256,
                  modelFamily: modelFamily,
                  observedHardwareClass: observedHardwareClass,
                  observedMetallibSHA256: observedMetallibSHA256,
                  observedKernelIdentifier: observedKernelIdentifier,
                  observedParityLabel: observedParityLabel,
                  poolEpoch: 1
              )
        else {
            return fail(.allocator)
        }
        guard !requiresMoEDispatch || gates.moeDispatchProven else { return fail(.kernel) }
        guard gates.engineBridgeAvailable else { return fail(.kernel) }

        return .attached(PagedKVDescriptor(
            blockSizeTokens: config.blockSizeTokens,
            maxPhysicalBlocks: config.maxPhysicalBlocks,
            modelID: modelID,
            modelSHA256: modelSHA256,
            tokenizerSHA256: tokenizerSHA256,
            chatTemplateSHA256: chatTemplateSHA256,
            supportedModelFamilies: [modelFamily],
            allowedCacheClasses: allowedCacheClasses,
            kvDType: .fp16,
            supportsMoEDispatch: gates.moeDispatchProven,
            hardwareClass: sizingProof.hardwareClass,
            metallibSHA256: sizingProof.metallibSHA256,
            kernelIdentifier: sizingProof.kernelIdentifier,
            parityLabel: sizingProof.parityLabel,
            poolEpoch: sizingProof.poolEpoch
        ))
    }
}

public struct PagedKVBlockTableHandle: Hashable, Sendable {
    let id: UUID
    let conversationKey: String
    let poolEpoch: Int

    public var handleID: UUID { id }
}

public struct PagedKVBlockTable: Equatable, Sendable, Codable {
    public let handleID: UUID
    public let blockSizeTokens: Int
    public let logicalTokenCount: Int
    public let physicalBlocks: [Int]
    public let tailValidTokenCount: Int
    public let poolEpoch: Int

    public var isEmpty: Bool { logicalTokenCount == 0 }
}

public struct PagedKVLayoutMetadata: Equatable, Sendable, Codable {
    public let blockSizeTokens: Int
    public let logicalTokenCount: Int
    public let layerShapes: [[Int]]
    public let layerDTypes: [PagedKVDType]
    public let blockTableVersion: Int
    public let poolEpoch: Int
    public let mlxVersion: String
    public let mlxLMVersion: String
    public let modelID: String
    public let modelSHA256: String?
    public let tokenizerSHA256: String?
    public let chatTemplateSHA256: String?
    public let cacheClass: String
    public let kvBits: Int?
}

public enum PagedKVAllocatorError: Error, Equatable {
    case invalidConfiguration
    case capacityExceeded(requiredBlocks: Int, availableBlocks: Int)
    case unknownHandle
    case conversationMismatch
    case invalidBlockTable(String)
    case retainedHandleStillLive
}

public struct PagedKVRetainedSequence: Equatable, Sendable {
    public let handle: PagedKVBlockTableHandle
    let conversationKey: String
    public let logicalTokenCount: Int
}

public struct PagedKVStorageBinding: Equatable, Sendable {
    public let handle: PagedKVBlockTableHandle
    public let blockSizeTokens: Int
    public let maxLogicalTokens: Int
    public let currentTable: PagedKVBlockTable
    public let poolEpoch: Int
}

struct PagedKVPhysicalLayerBlocks: Equatable, Sendable {
    let layerIndex: Int
    let keyShape: [Int]
    let valueShape: [Int]
    let dtype: PagedKVDType
    let keyBlocks: [Int: Data]
    let valueBlocks: [Int: Data]
    let bytesPerToken: Int

    init(
        layerIndex: Int,
        keyShape: [Int],
        valueShape: [Int],
        dtype: PagedKVDType = .fp16,
        keyBlocks: [Int: Data],
        valueBlocks: [Int: Data],
        bytesPerToken: Int
    ) {
        self.layerIndex = layerIndex
        self.keyShape = keyShape
        self.valueShape = valueShape
        self.dtype = dtype
        self.keyBlocks = keyBlocks
        self.valueBlocks = valueBlocks
        self.bytesPerToken = bytesPerToken
    }
}

public struct PagedKVOrderedLayerBlocks: Equatable, Sendable {
    public let layerIndex: Int
    public let keyShape: [Int]
    public let valueShape: [Int]
    public let dtype: PagedKVDType
    public let keyBlocksInTableOrder: [Data]
    public let valueBlocksInTableOrder: [Data]
    public let bytesPerToken: Int

    public init(
        layerIndex: Int,
        keyShape: [Int],
        valueShape: [Int],
        dtype: PagedKVDType = .fp16,
        keyBlocksInTableOrder: [Data],
        valueBlocksInTableOrder: [Data],
        bytesPerToken: Int
    ) {
        self.layerIndex = layerIndex
        self.keyShape = keyShape
        self.valueShape = valueShape
        self.dtype = dtype
        self.keyBlocksInTableOrder = keyBlocksInTableOrder
        self.valueBlocksInTableOrder = valueBlocksInTableOrder
        self.bytesPerToken = bytesPerToken
    }
}

public struct PagedKVMaterializedByteLayer: Equatable, Sendable {
    public let layerIndex: Int
    public let keyShape: [Int]
    public let valueShape: [Int]
    public let dtype: PagedKVDType
    public let logicalTokenCount: Int
    public let keyBytes: Data
    public let valueBytes: Data

    public init(
        layerIndex: Int,
        keyShape: [Int],
        valueShape: [Int],
        dtype: PagedKVDType,
        logicalTokenCount: Int,
        keyBytes: Data,
        valueBytes: Data
    ) {
        self.layerIndex = layerIndex
        self.keyShape = keyShape
        self.valueShape = valueShape
        self.dtype = dtype
        self.logicalTokenCount = logicalTokenCount
        self.keyBytes = keyBytes
        self.valueBytes = valueBytes
    }
}

/// Neutral BYTE extraction only (FR-PKV10 scope honesty): this type carries logical-order
/// K/V bytes reassembled from physical blocks. It is NOT the standalone contiguous
/// `KVCache` handoff that SPEC-024 (cold-tier residency) and SPEC-038 (continuous batching)
/// consume — reconstructing a live, injectable contiguous `KVCache` from these bytes is
/// deferred to the runtime bridge. FR-PKV10 is therefore NOT yet complete as a full
/// extraction contract; only the neutral byte-materialization primitive exists here.
public struct PagedKVMaterializedByteCache: Equatable, Sendable {
    public let handle: PagedKVBlockTableHandle
    public let blockTable: PagedKVBlockTable
    public let layers: [PagedKVMaterializedByteLayer]

    public init(
        handle: PagedKVBlockTableHandle,
        blockTable: PagedKVBlockTable,
        layers: [PagedKVMaterializedByteLayer]
    ) {
        self.handle = handle
        self.blockTable = blockTable
        self.layers = layers
    }
}

/// Neutral byte-extraction bridge only: yields `PagedKVMaterializedByteCache` bytes. The
/// standalone contiguous `KVCache` handoff SPEC-024/SPEC-038 consume (FR-PKV10 as a full
/// extraction contract) is deferred to the runtime bridge and is not provided here.
public protocol PagedKVContiguousCacheBridge: Sendable {
    func materializeContiguousByteCache(
        handle: PagedKVBlockTableHandle,
        table: PagedKVBlockTable
    ) throws -> PagedKVMaterializedByteCache
}

public actor PagedKVBlockAllocator {
    private struct SequenceState: Sendable {
        var conversationKey: String
        var reservedBlocks: [Int]
        var maxLogicalTokens: Int
        var logicalTokenCount: Int
        var inFlightDecodeSteps: Int
        var retained: Bool
    }

    public let blockSizeTokens: Int
    public let maxPhysicalBlocks: Int
    public let poolEpoch: Int
    private var freeBlocks: [Int]
    private var sequences: [UUID: SequenceState] = [:]
    private let contiguousCacheBridge: (any PagedKVContiguousCacheBridge)?

    public init(
        blockSizeTokens: Int,
        maxPhysicalBlocks: Int,
        poolEpoch: Int = 1,
        physicalBlockOrder: [Int]? = nil,
        contiguousCacheBridge: (any PagedKVContiguousCacheBridge)? = nil
    ) throws {
        guard blockSizeTokens > 0,
              blockSizeTokens <= PagedKVConfig.maximumBlockSizeTokens,
              maxPhysicalBlocks > 0,
              maxPhysicalBlocks <= PagedKVConfig.maximumPhysicalBlocks
        else {
            throw PagedKVAllocatorError.invalidConfiguration
        }
        self.blockSizeTokens = blockSizeTokens
        self.maxPhysicalBlocks = maxPhysicalBlocks
        self.poolEpoch = poolEpoch
        self.contiguousCacheBridge = contiguousCacheBridge
        if let physicalBlockOrder {
            guard Set(physicalBlockOrder).count == physicalBlockOrder.count,
                  physicalBlockOrder.allSatisfy({ (0..<maxPhysicalBlocks).contains($0) })
            else {
                throw PagedKVAllocatorError.invalidConfiguration
            }
            self.freeBlocks = physicalBlockOrder.reversed()
        } else {
            self.freeBlocks = Array((0..<maxPhysicalBlocks).reversed())
        }
    }

    private func lookupState(
        for handle: PagedKVBlockTableHandle,
        conversationMismatchError: PagedKVAllocatorError = .unknownHandle
    ) throws -> SequenceState {
        guard handle.poolEpoch == poolEpoch else {
            throw PagedKVAllocatorError.unknownHandle
        }
        guard let state = sequences[handle.id] else {
            throw PagedKVAllocatorError.unknownHandle
        }
        guard state.conversationKey == handle.conversationKey else {
            throw conversationMismatchError
        }
        return state
    }

    public func requiredBlocks(maxTokens: Int) throws -> Int {
        guard maxTokens >= 0 else {
            throw PagedKVAllocatorError.invalidBlockTable("negative logical length")
        }
        guard maxTokens > 0 else { return 0 }
        let (adjusted, overflow) = maxTokens.addingReportingOverflow(blockSizeTokens - 1)
        guard !overflow else {
            throw PagedKVAllocatorError.invalidBlockTable("logical length overflow")
        }
        return adjusted / blockSizeTokens
    }

    public func canAdmitBatch1(maxTokens: Int) -> Bool {
        (try? requiredBlocks(maxTokens: maxTokens)).map { $0 <= freeBlocks.count } ?? false
    }

    public func allocate(conversationKey: String, maxTokens: Int, initialTokens: Int = 0) throws -> PagedKVBlockTableHandle {
        try allocate(
            conversationKey: conversationKey,
            initialCapacityTokens: maxTokens,
            maxLogicalTokens: maxTokens,
            initialTokens: initialTokens
        )
    }

    public func allocate(
        conversationKey: String,
        initialCapacityTokens: Int,
        maxLogicalTokens: Int,
        initialTokens: Int = 0
    ) throws -> PagedKVBlockTableHandle {
        let trimmedKey = conversationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw PagedKVAllocatorError.conversationMismatch }
        guard initialCapacityTokens >= 0, maxLogicalTokens >= 0 else {
            throw PagedKVAllocatorError.invalidBlockTable("negative reservation")
        }
        guard initialTokens >= 0, initialTokens <= initialCapacityTokens, initialCapacityTokens <= maxLogicalTokens else {
            throw PagedKVAllocatorError.invalidBlockTable("initial length outside reserved range")
        }
        let needed = try requiredBlocks(maxTokens: initialCapacityTokens)
        guard needed <= freeBlocks.count else {
            throw PagedKVAllocatorError.capacityExceeded(requiredBlocks: needed, availableBlocks: freeBlocks.count)
        }
        var reserved: [Int] = []
        reserved.reserveCapacity(needed)
        for _ in 0..<needed {
            reserved.append(freeBlocks.removeLast())
        }
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: trimmedKey, poolEpoch: poolEpoch)
        sequences[handle.id] = SequenceState(
            conversationKey: trimmedKey,
            reservedBlocks: reserved,
            maxLogicalTokens: maxLogicalTokens,
            logicalTokenCount: initialTokens,
            inFlightDecodeSteps: 0,
            retained: false
        )
        try validate(handle)
        return handle
    }

    public func extend(_ handle: PagedKVBlockTableHandle, by tokens: Int) throws -> PagedKVBlockTable {
        guard tokens >= 0 else { throw PagedKVAllocatorError.invalidBlockTable("negative extension") }
        var state = try lookupState(for: handle)
        guard !state.retained else {
            throw PagedKVAllocatorError.retainedHandleStillLive
        }
        guard state.inFlightDecodeSteps == 0 else {
            throw PagedKVAllocatorError.retainedHandleStillLive
        }
        let (nextLength, overflow) = state.logicalTokenCount.addingReportingOverflow(tokens)
        guard !overflow else {
            throw PagedKVAllocatorError.invalidBlockTable("logical length overflow")
        }
        guard nextLength <= state.maxLogicalTokens else {
            throw PagedKVAllocatorError.capacityExceeded(requiredBlocks: try requiredBlocks(maxTokens: nextLength), availableBlocks: state.reservedBlocks.count)
        }
        let needed = try requiredBlocks(maxTokens: nextLength)
        if needed > state.reservedBlocks.count {
            let additional = needed - state.reservedBlocks.count
            guard additional <= freeBlocks.count else {
                throw PagedKVAllocatorError.capacityExceeded(requiredBlocks: needed, availableBlocks: state.reservedBlocks.count + freeBlocks.count)
            }
            for _ in 0..<additional {
                state.reservedBlocks.append(freeBlocks.removeLast())
            }
        }
        state.logicalTokenCount = nextLength
        sequences[handle.id] = state
        return try validate(handle)
    }

    public func beginDecodeStep(_ handle: PagedKVBlockTableHandle) throws {
        var state = try lookupState(for: handle)
        guard !state.retained else {
            throw PagedKVAllocatorError.retainedHandleStillLive
        }
        state.inFlightDecodeSteps += 1
        sequences[handle.id] = state
    }

    public func endDecodeStep(_ handle: PagedKVBlockTableHandle) throws {
        var state = try lookupState(for: handle)
        guard state.inFlightDecodeSteps > 0 else {
            throw PagedKVAllocatorError.invalidBlockTable("unbalanced decode step end")
        }
        state.inFlightDecodeSteps -= 1
        sequences[handle.id] = state
    }

    public func trim(_ handle: PagedKVBlockTableHandle, toLogicalTokens tokens: Int) throws -> PagedKVBlockTable {
        guard tokens >= 0 else { throw PagedKVAllocatorError.invalidBlockTable("negative trim length") }
        var state = try lookupState(for: handle)
        guard !state.retained else {
            throw PagedKVAllocatorError.retainedHandleStillLive
        }
        guard state.inFlightDecodeSteps == 0 else {
            throw PagedKVAllocatorError.retainedHandleStillLive
        }
        guard tokens <= state.logicalTokenCount else {
            throw PagedKVAllocatorError.invalidBlockTable("trim length exceeds logical length")
        }
        state.logicalTokenCount = tokens
        let needed = try requiredBlocks(maxTokens: tokens)
        if needed < state.reservedBlocks.count {
            let released = state.reservedBlocks[needed...]
            state.reservedBlocks.removeSubrange(needed...)
            freeBlocks.append(contentsOf: released.reversed())
        }
        sequences[handle.id] = state
        return try validate(handle)
    }

    public func table(for handle: PagedKVBlockTableHandle) throws -> PagedKVBlockTable {
        try validate(handle)
    }

    public func binding(for handle: PagedKVBlockTableHandle) throws -> PagedKVStorageBinding {
        let state = try lookupState(for: handle)
        return PagedKVStorageBinding(
            handle: handle,
            blockSizeTokens: blockSizeTokens,
            maxLogicalTokens: state.maxLogicalTokens,
            currentTable: try validate(handle),
            poolEpoch: poolEpoch
        )
    }

    func materialize(
        _ handle: PagedKVBlockTableHandle,
        physicalBlocks: [Int: Data],
        bytesPerToken: Int
    ) throws -> Data {
        try PagedKVMaterializer.materialize(
            table: validate(handle),
            physicalBlocks: physicalBlocks,
            bytesPerToken: bytesPerToken
        )
    }

    func materializeCache(
        _ handle: PagedKVBlockTableHandle,
        layers: [PagedKVPhysicalLayerBlocks]
    ) throws -> PagedKVMaterializedByteCache {
        let table = try validate(handle)
        let materializedLayers = try PagedKVMaterializer.materializeCache(table: table, layers: layers)
        return PagedKVMaterializedByteCache(handle: handle, blockTable: table, layers: materializedLayers)
    }

    public func materializeContiguousByteCache(
        _ handle: PagedKVBlockTableHandle
    ) throws -> PagedKVMaterializedByteCache {
        guard let contiguousCacheBridge else {
            throw PagedKVAllocatorError.invalidBlockTable("paged cache bridge unavailable")
        }
        let table = try validate(handle)
        let cache = try contiguousCacheBridge.materializeContiguousByteCache(handle: handle, table: table)
        guard cache.handle == handle, cache.blockTable == table else {
            throw PagedKVAllocatorError.invalidBlockTable("materialized cache handle mismatch")
        }
        try PagedKVMaterializer.validateMaterializedByteCache(cache, table: table)
        return cache
    }

    func materializeOrderedBytes(
        _ handle: PagedKVBlockTableHandle,
        layers: [PagedKVOrderedLayerBlocks]
    ) throws -> PagedKVMaterializedByteCache {
        let table = try validate(handle)
        let materializedLayers = try PagedKVMaterializer.materializeOrderedCache(table: table, layers: layers)
        return PagedKVMaterializedByteCache(handle: handle, blockTable: table, layers: materializedLayers)
    }

    @discardableResult
    public func validate(_ handle: PagedKVBlockTableHandle) throws -> PagedKVBlockTable {
        let state = try lookupState(for: handle)
        let logicalBlocks = try requiredBlocks(maxTokens: state.logicalTokenCount)
        guard logicalBlocks <= state.reservedBlocks.count else {
            throw PagedKVAllocatorError.invalidBlockTable("missing physical block")
        }
        let liveBlocks = Array(state.reservedBlocks.prefix(logicalBlocks))
        guard Set(liveBlocks).count == liveBlocks.count else {
            throw PagedKVAllocatorError.invalidBlockTable("duplicate writable block")
        }
        guard liveBlocks.allSatisfy({ (0..<maxPhysicalBlocks).contains($0) }) else {
            throw PagedKVAllocatorError.invalidBlockTable("out-of-range block")
        }
        let tail = state.logicalTokenCount == 0
            ? 0
            : ((state.logicalTokenCount - 1) % blockSizeTokens) + 1
        guard state.logicalTokenCount == 0 || (1...blockSizeTokens).contains(tail) else {
            throw PagedKVAllocatorError.invalidBlockTable("invalid tail token count")
        }
        return PagedKVBlockTable(
            handleID: handle.id,
            blockSizeTokens: blockSizeTokens,
            logicalTokenCount: state.logicalTokenCount,
            physicalBlocks: liveBlocks,
            tailValidTokenCount: tail,
            poolEpoch: poolEpoch
        )
    }

    public func retain(_ handle: PagedKVBlockTableHandle) throws -> PagedKVRetainedSequence {
        var state = try lookupState(for: handle)
        guard state.inFlightDecodeSteps == 0 else {
            throw PagedKVAllocatorError.retainedHandleStillLive
        }
        guard !state.retained else {
            throw PagedKVAllocatorError.retainedHandleStillLive
        }
        state.retained = true
        sequences[handle.id] = state
        return PagedKVRetainedSequence(
            handle: handle,
            conversationKey: state.conversationKey,
            logicalTokenCount: state.logicalTokenCount
        )
    }

    public func reattach(_ retained: PagedKVRetainedSequence, conversationKey: String) throws -> PagedKVBlockTableHandle {
        guard retained.conversationKey == conversationKey.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw PagedKVAllocatorError.conversationMismatch
        }
        var state = try lookupState(for: retained.handle)
        guard state.retained else {
            throw PagedKVAllocatorError.unknownHandle
        }
        state.retained = false
        sequences[retained.handle.id] = state
        return retained.handle
    }

    public func discardRetained(_ retained: PagedKVRetainedSequence, conversationKey: String) throws {
        guard retained.conversationKey == conversationKey.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw PagedKVAllocatorError.conversationMismatch
        }
        let state = try lookupState(for: retained.handle)
        guard state.retained else {
            throw PagedKVAllocatorError.unknownHandle
        }
        sequences.removeValue(forKey: retained.handle.id)
        freeBlocks.append(contentsOf: state.reservedBlocks.reversed())
    }

    public func release(_ handle: PagedKVBlockTableHandle) throws {
        let state = try lookupState(for: handle, conversationMismatchError: .conversationMismatch)
        guard !state.retained else {
            throw PagedKVAllocatorError.retainedHandleStillLive
        }
        guard state.inFlightDecodeSteps == 0 else {
            throw PagedKVAllocatorError.retainedHandleStillLive
        }
        sequences.removeValue(forKey: handle.id)
        freeBlocks.append(contentsOf: state.reservedBlocks.reversed())
    }

    public func freeBlockCount() -> Int { freeBlocks.count }
}

enum PagedKVMaterializer {
    static func validateMaterializedByteCache(
        _ cache: PagedKVMaterializedByteCache,
        table: PagedKVBlockTable
    ) throws {
        guard Set(cache.layers.map(\.layerIndex)).count == cache.layers.count else {
            throw PagedKVAllocatorError.invalidBlockTable("duplicate materialized layer")
        }
        for layer in cache.layers {
            guard layer.dtype == .fp16 else {
                throw PagedKVAllocatorError.invalidBlockTable("unsupported materialized dtype")
            }
            guard layer.keyShape == layer.valueShape, layer.keyShape.count >= 3 else {
                throw PagedKVAllocatorError.invalidBlockTable("materialized layer shape mismatch")
            }
            guard try sequenceLength(for: layer.keyShape) == table.logicalTokenCount,
                  layer.logicalTokenCount == table.logicalTokenCount
            else {
                throw PagedKVAllocatorError.invalidBlockTable("materialized shape does not match logical length")
            }
            let expectedBytes = try totalBytes(shape: layer.keyShape, dtype: layer.dtype)
            guard layer.keyBytes.count == expectedBytes, layer.valueBytes.count == expectedBytes else {
                throw PagedKVAllocatorError.invalidBlockTable("materialized layer byte count mismatch")
            }
        }
    }

    static func materializeOrderedCache(
        table: PagedKVBlockTable,
        layers: [PagedKVOrderedLayerBlocks]
    ) throws -> [PagedKVMaterializedByteLayer] {
        let physicalBlocks = table.physicalBlocks
        return try materializeCache(
            table: table,
            layers: layers.map { layer in
                guard layer.keyBlocksInTableOrder.count == physicalBlocks.count,
                      layer.valueBlocksInTableOrder.count == physicalBlocks.count
                else {
                    throw PagedKVAllocatorError.invalidBlockTable("ordered materialized block count mismatch")
                }
                return PagedKVPhysicalLayerBlocks(
                    layerIndex: layer.layerIndex,
                    keyShape: layer.keyShape,
                    valueShape: layer.valueShape,
                    dtype: layer.dtype,
                    keyBlocks: Dictionary(uniqueKeysWithValues: zip(physicalBlocks, layer.keyBlocksInTableOrder)),
                    valueBlocks: Dictionary(uniqueKeysWithValues: zip(physicalBlocks, layer.valueBlocksInTableOrder)),
                    bytesPerToken: layer.bytesPerToken
                )
            }
        )
    }

    static func materializeCache(
        table: PagedKVBlockTable,
        layers: [PagedKVPhysicalLayerBlocks]
    ) throws -> [PagedKVMaterializedByteLayer] {
        guard Set(layers.map(\.layerIndex)).count == layers.count else {
            throw PagedKVAllocatorError.invalidBlockTable("duplicate materialized layer")
        }
        return try layers.sorted(by: { $0.layerIndex < $1.layerIndex }).map { layer in
            guard layer.dtype == .fp16 else {
                throw PagedKVAllocatorError.invalidBlockTable("unsupported materialized dtype")
            }
            guard layer.keyShape == layer.valueShape, layer.keyShape.count >= 3 else {
                throw PagedKVAllocatorError.invalidBlockTable("materialized layer shape mismatch")
            }
            guard try sequenceLength(for: layer.keyShape) == table.logicalTokenCount else {
                throw PagedKVAllocatorError.invalidBlockTable("materialized shape does not match logical length")
            }
            let expectedBytesPerToken = try bytesPerToken(shape: layer.keyShape, dtype: layer.dtype)
            guard layer.bytesPerToken == expectedBytesPerToken else {
                throw PagedKVAllocatorError.invalidBlockTable("materialized bytes_per_token mismatch")
            }
            let keyBytes = try materializeShapedComponent(
                table: table,
                physicalBlocks: layer.keyBlocks,
                shape: layer.keyShape,
                dtype: layer.dtype
            )
            let valueBytes = try materializeShapedComponent(
                table: table,
                physicalBlocks: layer.valueBlocks,
                shape: layer.valueShape,
                dtype: layer.dtype
            )
            let expectedBytes = try totalBytes(shape: layer.keyShape, dtype: layer.dtype)
            guard keyBytes.count == expectedBytes, valueBytes.count == expectedBytes else {
                throw PagedKVAllocatorError.invalidBlockTable("materialized layer byte count mismatch")
            }
            return PagedKVMaterializedByteLayer(
                layerIndex: layer.layerIndex,
                keyShape: layer.keyShape,
                valueShape: layer.valueShape,
                dtype: layer.dtype,
                logicalTokenCount: table.logicalTokenCount,
                keyBytes: keyBytes,
                valueBytes: valueBytes
            )
        }
    }

    private static func materializeShapedComponent(
        table: PagedKVBlockTable,
        physicalBlocks: [Int: Data],
        shape: [Int],
        dtype: PagedKVDType
    ) throws -> Data {
        let sequenceAxis = shape.count - 2
        let logicalTokens = try sequenceLength(for: shape)
        guard logicalTokens == table.logicalTokenCount else {
            throw PagedKVAllocatorError.invalidBlockTable("materialized shape does not match logical length")
        }
        let outerElements = try product(shape.prefix(sequenceAxis))
        let innerElements = try product(shape.suffix(from: sequenceAxis + 1))
        let (innerBytes, innerOverflow) = innerElements.multipliedReportingOverflow(by: dtype.byteWidth)
        guard !innerOverflow else {
            throw PagedKVAllocatorError.invalidBlockTable("materialized byte count overflow")
        }
        let (blockOuterStride, strideOverflow) = table.blockSizeTokens.multipliedReportingOverflow(by: innerBytes)
        guard !strideOverflow else {
            throw PagedKVAllocatorError.invalidBlockTable("materialized block stride overflow")
        }
        let (minimumBlockBytes, blockOverflow) = outerElements.multipliedReportingOverflow(by: blockOuterStride)
        guard !blockOverflow else {
            throw PagedKVAllocatorError.invalidBlockTable("materialized block byte count overflow")
        }
        let expectedBytes = try totalBytes(shape: shape, dtype: dtype)
        var output = Data()
        output.reserveCapacity(expectedBytes)
        for outer in 0..<outerElements {
            for (index, physicalID) in table.physicalBlocks.enumerated() {
                guard let block = physicalBlocks[physicalID] else {
                    throw PagedKVAllocatorError.invalidBlockTable("missing physical block")
                }
                guard block.count >= minimumBlockBytes else {
                    throw PagedKVAllocatorError.invalidBlockTable("short physical block")
                }
                let validTokens = index == table.physicalBlocks.count - 1
                    ? table.tailValidTokenCount
                    : table.blockSizeTokens
                let (validBytes, validOverflow) = validTokens.multipliedReportingOverflow(by: innerBytes)
                guard !validOverflow else {
                    throw PagedKVAllocatorError.invalidBlockTable("block byte count overflow")
                }
                let start = outer * blockOuterStride
                output.append(block[start ..< start + validBytes])
            }
        }
        guard output.count == expectedBytes else {
            throw PagedKVAllocatorError.invalidBlockTable("materialized layer byte count mismatch")
        }
        return output
    }

    private static func sequenceLength(for shape: [Int]) throws -> Int {
        guard shape.count >= 3, shape.allSatisfy({ $0 >= 0 }) else {
            throw PagedKVAllocatorError.invalidBlockTable("invalid materialized shape")
        }
        return shape[shape.count - 2]
    }

    private static func product<S: Sequence>(_ values: S) throws -> Int where S.Element == Int {
        var result = 1
        for value in values {
            guard value > 0 else {
                throw PagedKVAllocatorError.invalidBlockTable("invalid materialized shape")
            }
            let (next, overflow) = result.multipliedReportingOverflow(by: value)
            guard !overflow else {
                throw PagedKVAllocatorError.invalidBlockTable("materialized shape overflow")
            }
            result = next
        }
        return result
    }

    private static func bytesPerToken(shape: [Int], dtype: PagedKVDType) throws -> Int {
        guard shape.count >= 3, shape.allSatisfy({ $0 >= 0 }) else {
            throw PagedKVAllocatorError.invalidBlockTable("invalid materialized shape")
        }
        var elementsPerToken = 1
        for (index, dim) in shape.enumerated() where index != shape.count - 2 {
            guard dim > 0 else {
                throw PagedKVAllocatorError.invalidBlockTable("invalid materialized shape")
            }
            let (next, overflow) = elementsPerToken.multipliedReportingOverflow(by: dim)
            guard !overflow else {
                throw PagedKVAllocatorError.invalidBlockTable("materialized shape overflow")
            }
            elementsPerToken = next
        }
        let (bytes, overflow) = elementsPerToken.multipliedReportingOverflow(by: dtype.byteWidth)
        guard !overflow else {
            throw PagedKVAllocatorError.invalidBlockTable("materialized byte count overflow")
        }
        return bytes
    }

    private static func totalBytes(shape: [Int], dtype: PagedKVDType) throws -> Int {
        let sequence = try sequenceLength(for: shape)
        let perToken = try bytesPerToken(shape: shape, dtype: dtype)
        let (bytes, overflow) = sequence.multipliedReportingOverflow(by: perToken)
        guard !overflow else {
            throw PagedKVAllocatorError.invalidBlockTable("materialized byte count overflow")
        }
        return bytes
    }

    static func materialize(
        table: PagedKVBlockTable,
        physicalBlocks: [Int: Data],
        bytesPerToken: Int
    ) throws -> Data {
        guard bytesPerToken > 0 else {
            throw PagedKVAllocatorError.invalidBlockTable("bytes_per_token must be positive")
        }
        guard table.blockSizeTokens > 0, table.logicalTokenCount >= 0 else {
            throw PagedKVAllocatorError.invalidBlockTable("invalid table dimensions")
        }
        let expectedBlocks: Int
        if table.logicalTokenCount == 0 {
            expectedBlocks = 0
            guard table.tailValidTokenCount == 0 else {
                throw PagedKVAllocatorError.invalidBlockTable("non-empty tail on empty table")
            }
        } else {
            let (adjusted, overflow) = table.logicalTokenCount.addingReportingOverflow(table.blockSizeTokens - 1)
            guard !overflow else {
                throw PagedKVAllocatorError.invalidBlockTable("logical length overflow")
            }
            expectedBlocks = adjusted / table.blockSizeTokens
            let expectedTail = ((table.logicalTokenCount - 1) % table.blockSizeTokens) + 1
            guard table.tailValidTokenCount == expectedTail else {
                throw PagedKVAllocatorError.invalidBlockTable("invalid tail token count")
            }
        }
        guard table.physicalBlocks.count == expectedBlocks else {
            throw PagedKVAllocatorError.invalidBlockTable("physical block count does not match logical length")
        }
        guard Set(table.physicalBlocks).count == table.physicalBlocks.count else {
            throw PagedKVAllocatorError.invalidBlockTable("duplicate physical block")
        }
        guard table.physicalBlocks.allSatisfy({ $0 >= 0 }) else {
            throw PagedKVAllocatorError.invalidBlockTable("negative physical block")
        }
        let (expectedBytes, reserveOverflow) = table.logicalTokenCount.multipliedReportingOverflow(by: bytesPerToken)
        guard !reserveOverflow else {
            throw PagedKVAllocatorError.invalidBlockTable("materialized byte count overflow")
        }
        var output = Data()
        output.reserveCapacity(expectedBytes)
        for (index, physicalID) in table.physicalBlocks.enumerated() {
            guard let block = physicalBlocks[physicalID] else {
                throw PagedKVAllocatorError.invalidBlockTable("missing physical block")
            }
            let validTokens = index == table.physicalBlocks.count - 1
                ? table.tailValidTokenCount
                : table.blockSizeTokens
            let (validBytes, overflow) = validTokens.multipliedReportingOverflow(by: bytesPerToken)
            guard !overflow else {
                throw PagedKVAllocatorError.invalidBlockTable("block byte count overflow")
            }
            guard block.count >= validBytes else {
                throw PagedKVAllocatorError.invalidBlockTable("short physical block")
            }
            output.append(block.prefix(validBytes))
        }
        guard output.count == expectedBytes else {
            throw PagedKVAllocatorError.invalidBlockTable("materialized byte count mismatch")
        }
        return output
    }
}

public enum PagedKVMetallibGate {
    public static func defaultMetallibExists(
        bundleURL: URL? = Bundle.main.resourceURL,
        executableURL: URL? = Bundle.main.executableURL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        candidatePaths(bundleURL: bundleURL, executableURL: executableURL).contains(where: fileExists)
    }

    public static func candidatePaths(bundleURL: URL?, executableURL: URL?) -> [String] {
        var paths: [String] = []
        if let bundleURL {
            paths.append(bundleURL.appendingPathComponent("default.metallib").path)
            paths.append(bundleURL.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib").path)
        }
        if let executableURL {
            let dir = executableURL.deletingLastPathComponent()
            paths.append(dir.appendingPathComponent("default.metallib").path)
            paths.append(dir.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib").path)
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}
