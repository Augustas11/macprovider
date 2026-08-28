import Foundation
import CryptoKit
import MacProviderCore

enum ContinuousBatchSchedulerTerminalStatus: String, Sendable, Equatable {
    case stop
    case length
    case cancelled
    case requestFailed
    case batchFailed
    case rejected
}

enum ContinuousBatchSchedulerDiagnostic: String, Sendable, Equatable {
    case accepted
    case backpressureRejected = "backpressure_rejected"
    case batchForwardFailed = "batch_forward_failed"
    case cancelled
    case decodeFirstStep = "decode_first_step"
    case drained
    case forcedDrainStarted = "forced_drain_started"
    case joinedDecode = "joined_decode"
    case localCapabilityMissing = "local_capability_missing"
    case localPreparationFailed = "local_preparation_failed"
    case localExtensionFailed = "local_extension_failed"
    case cleanupFailed = "cleanup_failed"
    case poolCapacityRejected = "pool_capacity_rejected"
    case prefillFailed = "prefill_failed"
    case promptHeadroomReserved = "prompt_headroom_reserved"
    case stickyCacheUnsupported = "sticky_cache_unsupported"
    case stopped
}

struct ContinuousBatchSchedulerSnapshot: Sendable, Equatable {
    let modelID: String
    let modelSHA256: String
    let weightsGeneration: Int
}

struct ContinuousBatchSchedulerConfiguration: Sendable, Equatable {
    let descriptor: PagedKVDescriptor
    let tuple: ContinuousBatchingRequestedTuple
    let moePromotionEvidenceAvailable: Bool
    let maxActiveRows: Int
    let queueLimit: Int
    let decodeHeadroomTokens: Int
    let maxPrefillRowsPerIteration: Int
    let maxPromptChunkTokens: Int
    let drainTimeoutNanoseconds: UInt64
    let drainCancellationGraceNanoseconds: UInt64
    let terminalResultLimit: Int
    let dedupeTombstoneLimit: Int
    let duplicateWaiterLimit: Int
    let tokenDeliveryBufferLimit: Int
    let tokenDeliveryTaskLimit: Int
    let tokenDeliveryTimeoutNanoseconds: UInt64
    let diagnosticLimit: Int
    let vocabularySize: Int
    let maxRequestIDBytes: Int
    let maxRequestTokens: Int
    let maxQueuedTokens: Int
    let maxStopSequences: Int
    let maxStopSequenceTokens: Int
    let maxTotalStopTokens: Int
    let snapshot: ContinuousBatchSchedulerSnapshot

    init(
        descriptor: PagedKVDescriptor,
        tuple: ContinuousBatchingRequestedTuple,
        moePromotionEvidenceAvailable: Bool = false,
        maxActiveRows: Int,
        queueLimit: Int? = nil,
        decodeHeadroomTokens: Int,
        maxPrefillRowsPerIteration: Int = 1,
        maxPromptChunkTokens: Int = 256,
        drainTimeoutNanoseconds: UInt64 = 30_000_000_000,
        drainCancellationGraceNanoseconds: UInt64 = 5_000_000_000,
        terminalResultLimit: Int? = nil,
        dedupeTombstoneLimit: Int? = nil,
        duplicateWaiterLimit: Int = 4,
        tokenDeliveryBufferLimit: Int = 16,
        tokenDeliveryTaskLimit: Int? = nil,
        tokenDeliveryTimeoutNanoseconds: UInt64 = 5_000_000_000,
        diagnosticLimit: Int = 512,
        vocabularySize: Int = Int.max,
        maxRequestIDBytes: Int = 256,
        maxRequestTokens: Int = 131_072,
        maxQueuedTokens: Int = 1_048_576,
        maxStopSequences: Int = 16,
        maxStopSequenceTokens: Int = 64,
        maxTotalStopTokens: Int = 256,
        snapshot: ContinuousBatchSchedulerSnapshot
    ) {
        self.descriptor = descriptor
        self.tuple = tuple
        self.moePromotionEvidenceAvailable = moePromotionEvidenceAvailable
        self.maxActiveRows = max(1, maxActiveRows)
        self.queueLimit = ContinuousBatchingPolicy.queueLimit(
            configured: queueLimit,
            maxActiveRows: self.maxActiveRows
        )
        self.decodeHeadroomTokens = max(0, decodeHeadroomTokens)
        self.maxPrefillRowsPerIteration = max(1, maxPrefillRowsPerIteration)
        self.maxPromptChunkTokens = max(1, maxPromptChunkTokens)
        self.drainTimeoutNanoseconds = drainTimeoutNanoseconds
        self.drainCancellationGraceNanoseconds = drainCancellationGraceNanoseconds
        let (scaledTerminalLimit, terminalOverflow) = self.queueLimit.multipliedReportingOverflow(by: 2)
        self.terminalResultLimit = max(
            1,
            terminalResultLimit ?? max(16, terminalOverflow ? Int.max : scaledTerminalLimit)
        )
        let (scaledTombstoneLimit, tombstoneOverflow) = self.terminalResultLimit.multipliedReportingOverflow(by: 8)
        self.dedupeTombstoneLimit = max(
            self.terminalResultLimit,
            dedupeTombstoneLimit ?? (tombstoneOverflow ? Int.max : scaledTombstoneLimit)
        )
        self.duplicateWaiterLimit = max(1, duplicateWaiterLimit)
        self.tokenDeliveryBufferLimit = max(1, tokenDeliveryBufferLimit)
        let (scaledDeliveryLimit, deliveryLimitOverflow) = self.maxActiveRows.multipliedReportingOverflow(
            by: self.duplicateWaiterLimit
        )
        self.tokenDeliveryTaskLimit = max(
            1,
            min(64, tokenDeliveryTaskLimit ?? (deliveryLimitOverflow ? 64 : scaledDeliveryLimit))
        )
        self.tokenDeliveryTimeoutNanoseconds = tokenDeliveryTimeoutNanoseconds
        self.diagnosticLimit = max(1, diagnosticLimit)
        self.vocabularySize = max(1, vocabularySize)
        self.maxRequestIDBytes = max(1, maxRequestIDBytes)
        self.maxRequestTokens = max(1, maxRequestTokens)
        self.maxQueuedTokens = max(self.maxRequestTokens, maxQueuedTokens)
        self.maxStopSequences = max(1, maxStopSequences)
        self.maxStopSequenceTokens = max(1, maxStopSequenceTokens)
        self.maxTotalStopTokens = max(1, maxTotalStopTokens)
        self.snapshot = snapshot
    }
}

struct ContinuousBatchSchedulerRequest: Sendable, Equatable, Codable {
    let id: String
    let conversationKey: String
    let promptTokens: [Int]
    let maxOutputTokens: Int
    let stopTokenSequences: [[Int]]
    let samplerSeed: Int
    let temperature: Double
    let topP: Double
    let presencePenalty: Double
    let frequencyPenalty: Double
    let cachedPromptTokens: Int

    init(
        id: String,
        conversationKey: String,
        promptTokens: [Int],
        maxOutputTokens: Int,
        stopTokenSequences: [[Int]] = [],
        samplerSeed: Int = 0,
        temperature: Double = 1.0,
        topP: Double = 1.0,
        presencePenalty: Double = 0.0,
        frequencyPenalty: Double = 0.0,
        cachedPromptTokens: Int = 0
    ) {
        self.id = id
        self.conversationKey = conversationKey
        self.promptTokens = promptTokens
        self.maxOutputTokens = max(0, maxOutputTokens)
        self.stopTokenSequences = stopTokenSequences
        self.samplerSeed = samplerSeed
        self.temperature = temperature
        self.topP = topP
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.cachedPromptTokens = max(0, cachedPromptTokens)
    }
}

enum ContinuousBatchSettlementDisposition: String, Sendable, Equatable {
    case eligibleOwner = "eligible_owner"
    case nonSettlingReplay = "non_settling_replay"
    case notEligible = "not_eligible"
}

struct ContinuousBatchSchedulerResult: Sendable, Equatable {
    let requestID: String
    let conversationKey: String
    let outputTokens: [Int]
    let promptTokens: Int
    let completionTokens: Int
    let emittedTokens: Int
    let cachedPromptTokens: Int
    let terminalStatus: ContinuousBatchSchedulerTerminalStatus
    let errorCode: String?
    let snapshot: ContinuousBatchSchedulerSnapshot?
    let settlementDisposition: ContinuousBatchSettlementDisposition

    func withSettlementDisposition(
        _ disposition: ContinuousBatchSettlementDisposition
    ) -> ContinuousBatchSchedulerResult {
        ContinuousBatchSchedulerResult(
            requestID: requestID,
            conversationKey: conversationKey,
            outputTokens: outputTokens,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            emittedTokens: emittedTokens,
            cachedPromptTokens: cachedPromptTokens,
            terminalStatus: terminalStatus,
            errorCode: errorCode,
            snapshot: snapshot,
            settlementDisposition: disposition
        )
    }
}

struct ContinuousBatchSchedulerTokenEvent: Sendable, Equatable {
    let requestID: String
    let tokenIndex: Int
    let token: Int
    /// Present only when a duplicate waiter attaches after visible output has
    /// already been delivered. Ordinary decode events are delta-only.
    let replayTokens: [Int]?
    let snapshot: ContinuousBatchSchedulerSnapshot
}

typealias ContinuousBatchSchedulerTokenSink = @Sendable (ContinuousBatchSchedulerTokenEvent) async -> Void

struct ContinuousBatchSchedulerMetrics: Sendable, Equatable {
    let slotsTotal: Int
    let slotsFree: Int
    let waitingCount: Int
    let activeDecodeRows: Int
    let activePromptRows: Int
    let sharedForwardCalls: Int
    let prefillCalls: Int
    let maxObservedBatchDepth: Int
    let retainedTerminalResults: Int
    let retainedDedupeTombstones: Int
    let attachedWaiters: Int
    let retainedDiagnostics: Int
    let diagnostics: [ContinuousBatchSchedulerDiagnostic]
}

/// Capability token for a generation swap. A runtime bridge must require this
/// value before replacing the scheduler's model snapshot; timeout paths never
/// produce one, so catching `drainTimedOut` cannot be mistaken for quiescence.
struct ContinuousBatchDrainPermit: Sendable, Equatable {
    fileprivate let schedulerID: UUID
    let snapshot: ContinuousBatchSchedulerSnapshot
}

struct ContinuousBatchPrefillInput: Sendable, Equatable {
    let requestID: String
    let promptTokens: [Int]
    let binding: PagedKVStorageBinding
    let promptTokenOffset: Int
    let committedKVTokenCount: Int
    let targetKVTokenCount: Int
    let isFinalChunk: Bool
}

struct ContinuousBatchPrefillOutput: Sendable, Equatable {
    let requestID: String
}

struct ContinuousBatchDecodeInput: Sendable, Equatable {
    let requestID: String
    let currentToken: Int
    let generatedTokens: [Int]
    let promptTokens: [Int]
    let samplerSeed: Int
    let temperature: Double
    let topP: Double
    let presencePenalty: Double
    let frequencyPenalty: Double
    let blockTable: PagedKVBlockTable
    let committedKVTokenCount: Int
    let targetKVTokenCount: Int
    /// Zero-based sampling step. Backends MUST sample as a pure function of
    /// this step, `samplerSeed`, the complete generated-token history, sampling
    /// parameters, and the row logits; hidden cross-row sampler state is
    /// forbidden.
    let samplerStep: Int
}

struct ContinuousBatchDecodeOutput: Sendable, Equatable {
    let requestID: String
    let token: Int
}

enum ContinuousBatchDecodeOutcome: Sendable, Equatable {
    case output(ContinuousBatchDecodeOutput)
    /// A fallible row-local sampler/logit-processing failure. Shared-forward
    /// failures still throw from `decode(rows:)` and fail the whole batch.
    case rowFailure(requestID: String)

    var requestID: String {
        switch self {
        case .output(let output): output.requestID
        case .rowFailure(let requestID): requestID
        }
    }
}

protocol ContinuousBatchSchedulerBackend: Sendable {
    /// Prefill commits only the prompt prefix. The final prompt token remains
    /// scheduler-owned as the first shared-decode input.
    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput]
    /// Each row's table describes the post-step target length; the backend
    /// writes `currentToken` at `committedKVTokenCount` and returns one sampled
    /// token without advancing any other row's cursor.
    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome]
    /// Returns only after in-flight calls have stopped accessing row bindings.
    func cancelInFlight() async
}

enum ContinuousBatchSchedulerReplayClaim: Sendable, Equatable {
    case claimed
    case duplicateSameRequest
    case duplicateMismatchedRequest
}

struct ContinuousBatchSchedulerReplayKey: Sendable, Equatable {
    let requestID: String
    let fingerprintSHA256: Data
}

/// Durable request-log boundary for scheduler admission. Implementations must
/// atomically remember a non-secret canonical request fingerprint for at least
/// the settlement replay horizon; the scheduler's bounded local result caches
/// are an optimization, never the authority that permits re-execution.
protocol ContinuousBatchSchedulerReplayAuthority: Sendable {
    func claim(_ key: ContinuousBatchSchedulerReplayKey) throws -> ContinuousBatchSchedulerReplayClaim
}

private final class ContinuousBatchTokenDeliveryCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var inUse = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inUse < limit else { return false }
        inUse += 1
        return true
    }

    func release() {
        lock.lock()
        precondition(inUse > 0, "token delivery capacity release must balance acquisition")
        inUse -= 1
        lock.unlock()
    }
}

private final class ContinuousBatchTokenDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let bufferLimit: Int
    private let timeoutNanoseconds: UInt64
    private let sink: ContinuousBatchSchedulerTokenSink
    private let capacity: ContinuousBatchTokenDeliveryCapacity
    private var queue: [ContinuousBatchSchedulerTokenEvent] = []
    private var drainCompletion: (@Sendable (Bool) -> Void)?
    private var accepting = true
    private var draining = false
    private var timedOut = false
    private var ownsCapacity = false
    private var drainGeneration: UUID?
    private var deliveryTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        bufferLimit: Int,
        timeoutNanoseconds: UInt64,
        capacity: ContinuousBatchTokenDeliveryCapacity,
        sink: @escaping ContinuousBatchSchedulerTokenSink
    ) {
        self.bufferLimit = max(1, bufferLimit)
        self.timeoutNanoseconds = timeoutNanoseconds
        self.capacity = capacity
        self.sink = sink
    }

    /// Non-blocking offer. The scheduler fails only this waiter when its
    /// consumer cannot keep up with the bounded delivery buffer.
    func offer(_ event: ContinuousBatchSchedulerTokenEvent) -> Bool {
        var generationToStart: UUID?
        lock.lock()
        guard accepting, queue.count < bufferLimit else {
            lock.unlock()
            return false
        }
        if !draining {
            guard capacity.tryAcquire() else {
                lock.unlock()
                return false
            }
            ownsCapacity = true
            draining = true
            let generation = UUID()
            drainGeneration = generation
            generationToStart = generation
        }
        queue.append(event)
        lock.unlock()
        if let generationToStart {
            startDrain(generation: generationToStart)
        }
        return true
    }

    /// Stops new events while allowing the already-bounded queue to drain in
    /// order outside scheduler isolation.
    func finish() {
        stop(afterStopping: {})
    }

    /// Stops new delivery. Cooperative sinks acknowledge immediately; a sink
    /// that ignores cancellation is detached from scheduler state at the same
    /// hard deadline used by terminal delivery and completes this waiter as a
    /// non-settling failure. Its live-task capacity remains quarantined until
    /// the sink actually returns, preventing unbounded detached-task growth.
    func stop(afterStopping completion: @escaping @Sendable () -> Void) {
        lock.lock()
        accepting = false
        queue.removeAll()
        if draining {
            drainCompletion = { _ in completion() }
            let task = deliveryTask
            lock.unlock()
            task?.cancel()
            startTimeout()
            return
        }
        let task = deliveryTask
        lock.unlock()
        task?.cancel()
        completion()
    }

    /// Stops new events and invokes `completion` only after every accepted
    /// event has completed delivery. The callback runs outside the lock and
    /// outside scheduler actor isolation.
    func finish(afterDraining completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        accepting = false
        if draining || !queue.isEmpty {
            precondition(drainCompletion == nil, "token delivery may finish only once")
            drainCompletion = completion
            lock.unlock()
            startTimeout()
            return
        }
        lock.unlock()
        completion(true)
    }

    private func startDrain(generation: UUID) {
        let task = Task { await self.drain(generation: generation) }
        lock.lock()
        if drainGeneration == generation {
            deliveryTask = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    private func startTimeout() {
        lock.lock()
        guard drainCompletion != nil, timeoutTask == nil else {
            lock.unlock()
            return
        }
        let task = Task { [timeoutNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            self.timeout()
        }
        timeoutTask = task
        lock.unlock()
    }

    private func drain(generation: UUID) async {
        while let event = nextEvent(generation: generation) {
            await sink(event)
            if Task.isCancelled { break }
        }
        finishDrain(generation: generation)
    }

    private func nextEvent(generation: UUID) -> ContinuousBatchSchedulerTokenEvent? {
        lock.lock()
        if drainGeneration == generation, !timedOut, !queue.isEmpty {
            let event = queue.removeFirst()
            lock.unlock()
            return event
        }
        lock.unlock()
        return nil
    }

    private func timeout() {
        lock.lock()
        guard drainGeneration != nil, let completion = drainCompletion else {
            lock.unlock()
            return
        }
        timedOut = true
        accepting = false
        queue.removeAll()
        let task = deliveryTask
        draining = false
        drainGeneration = nil
        deliveryTask = nil
        timeoutTask = nil
        drainCompletion = nil
        lock.unlock()
        task?.cancel()
        completion(false)
    }

    private func finishDrain(generation: UUID) {
        lock.lock()
        guard drainGeneration == generation else {
            let shouldReleaseDetachedCapacity = timedOut
                && drainGeneration == nil
                && ownsCapacity
            if shouldReleaseDetachedCapacity {
                ownsCapacity = false
            }
            lock.unlock()
            if shouldReleaseDetachedCapacity { capacity.release() }
            return
        }
        draining = false
        drainGeneration = nil
        deliveryTask = nil
        let timeout = timeoutTask
        timeoutTask = nil
        let completion = drainCompletion
        let completedBeforeTimeout = !timedOut
        drainCompletion = nil
        let shouldRelease = ownsCapacity
        ownsCapacity = false
        lock.unlock()
        timeout?.cancel()
        if shouldRelease { capacity.release() }
        completion?(completedBeforeTimeout)
    }
}

enum ContinuousBatchSchedulerError: Error, Equatable {
    case unsupported(String)
    case backpressure
    case drained
    case drainTimedOut
    case requestFailed(String)
    case duplicateRequestMismatch
    case idempotencyWindowExpired
    case idempotencyAuthorityUnavailable
}

actor ContinuousBatchScheduler {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<ContinuousBatchSchedulerResult, Error>
        let delivery: ContinuousBatchTokenDelivery
    }

    private struct RequestFingerprint: Sendable, Equatable {
        let sha256: Data

        init?(_ request: ContinuousBatchSchedulerRequest) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let encoded = try? encoder.encode(request) else { return nil }
            sha256 = Data(SHA256.hash(data: encoded))
        }
    }

    private struct Row: Sendable {
        var request: ContinuousBatchSchedulerRequest
        var handle: PagedKVBlockTableHandle
        var currentToken: Int
        /// All sampled tokens, including stop tokens held back from buyers.
        var generatedTokens: [Int]
        var outputTokens: [Int]
        var pendingOutputTokens: [Int]
        var prefillCursor: Int
        var snapshot: ContinuousBatchSchedulerSnapshot
    }

    private struct PendingTerminalDelivery {
        let result: ContinuousBatchSchedulerResult
        var waiters: [Waiter]
        var remainingWaiterIDs: Set<UUID>
        var deliveryOutcomes: [UUID: Bool] = [:]
    }

    private struct StoppingActiveWaiter {
        let requestID: String
        let waiter: Waiter
        let error: any Error
    }

    private struct DeferredTerminalCompletion {
        let result: ContinuousBatchSchedulerResult
        let waiters: [Waiter]
    }

    private let configuration: ContinuousBatchSchedulerConfiguration
    private let schedulerID = UUID()
    private let allocator: PagedKVBlockAllocator
    private let backend: any ContinuousBatchSchedulerBackend
    private let replayAuthority: any ContinuousBatchSchedulerReplayAuthority
    private let tokenDeliveryCapacity: ContinuousBatchTokenDeliveryCapacity

    private var waiting: [ContinuousBatchSchedulerRequest] = []
    private var pendingBindingChecks = 0
    private var pendingBindingTokenCount = 0
    private var nextAdmissionSequence: UInt64 = 0
    private var currentAdmissionSequence: UInt64 = 0
    private var admissionTurnWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var requestAdmissionSequences: [String: UInt64] = [:]
    private var admittingRequests: [String: ContinuousBatchSchedulerRequest] = [:]
    private var activePrompt: [String: Row] = [:]
    private var promptOrder: [String] = []
    private var activeDecode: [String: Row] = [:]
    private var requestWaiters: [String: [Waiter]] = [:]
    private var knownRequests: [String: RequestFingerprint] = [:]
    private var terminalResults: [String: ContinuousBatchSchedulerResult] = [:]
    private var pendingTerminalDeliveries: [String: PendingTerminalDelivery] = [:]
    private var stoppingWaiterIDs: Set<UUID> = []
    private var stoppingActiveWaiters: [UUID: StoppingActiveWaiter] = [:]
    private var deferredTerminalCompletions: [String: DeferredTerminalCompletion] = [:]
    private var terminalResultOrder: [String] = []
    private var dedupeTombstones: Set<String> = []
    private var dedupeTombstoneOrder: [String] = []
    private var cancelledIDs: Set<String> = []
    private var draining = false
    private var cleanupFailedClosed = false
    private var backendCancellationPending = false
    private var pumpRestartRequested = false
    private var pumpRunning = false
    private var diagnostics: [ContinuousBatchSchedulerDiagnostic] = []
    private var sharedForwardCalls = 0
    private var prefillCalls = 0
    private var maxObservedBatchDepth = 0

    init(
        configuration: ContinuousBatchSchedulerConfiguration,
        allocator: PagedKVBlockAllocator,
        backend: any ContinuousBatchSchedulerBackend,
        replayAuthority: any ContinuousBatchSchedulerReplayAuthority
    ) {
        self.configuration = configuration
        self.tokenDeliveryCapacity = ContinuousBatchTokenDeliveryCapacity(
            limit: configuration.tokenDeliveryTaskLimit
        )
        self.allocator = allocator
        self.backend = backend
        self.replayAuthority = replayAuthority
    }

    static func localCapabilityReason(
        descriptor: PagedKVDescriptor,
        tuple: ContinuousBatchingRequestedTuple,
        moePromotionEvidenceAvailable: Bool = false
    ) -> String? {
        guard tuple.isAdmitted(by: descriptor) else {
            return "local_paged_kv_descriptor_mismatch"
        }
        if tuple.requiresMoE && !moePromotionEvidenceAvailable {
            return "moe_promotion_evidence_unavailable"
        }
        return nil
    }

    func submit(
        _ request: ContinuousBatchSchedulerRequest,
        tokenSink: @escaping ContinuousBatchSchedulerTokenSink = { _ in }
    ) async throws -> ContinuousBatchSchedulerResult {
        try Task.checkCancellation()
        if cleanupFailedClosed {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_scheduler_failed_closed")
        }
        if let reason = Self.localCapabilityReason(
            descriptor: configuration.descriptor,
            tuple: configuration.tuple,
            moePromotionEvidenceAvailable: configuration.moePromotionEvidenceAvailable
        ) {
            record(.localCapabilityMissing)
            throw ContinuousBatchSchedulerError.unsupported(reason)
        }
        if !request.conversationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || request.cachedPromptTokens > 0 {
            record(.stickyCacheUnsupported)
            throw ContinuousBatchSchedulerError.unsupported("keyed_or_sticky_cache_reuse_deferred_until_paged_kv_cache_bridge")
        }
        guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.id.lengthOfBytes(using: .utf8) <= configuration.maxRequestIDBytes,
              !request.promptTokens.isEmpty,
              request.promptTokens.allSatisfy({ (0..<configuration.vocabularySize).contains($0) }),
              request.stopTokenSequences.count <= configuration.maxStopSequences,
              request.stopTokenSequences.allSatisfy({ sequence in
                  !sequence.isEmpty
                      && sequence.count <= configuration.maxStopSequenceTokens
                      && sequence.allSatisfy { (0..<configuration.vocabularySize).contains($0) }
              }),
              let retainedTokenCost = validatedRetainedTokenCost(for: request),
              retainedTokenCost <= configuration.maxRequestTokens else {
            throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_invalid_request")
        }
        guard queueHasCapacity(addingTokenCost: retainedTokenCost) else {
            record(.backpressureRejected)
            throw ContinuousBatchSchedulerError.backpressure
        }
        guard nextAdmissionSequence < UInt64.max else {
            cleanupFailedClosed = true
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_admission_sequence_exhausted")
        }
        let admissionSequence = nextAdmissionSequence
        nextAdmissionSequence += 1
        pendingBindingChecks += 1
        pendingBindingTokenCount += retainedTokenCost
        let bindingsAreValid = await localBindingsAreValid()
        await waitForAdmissionTurn(admissionSequence)
        pendingBindingChecks -= 1
        pendingBindingTokenCount -= retainedTokenCost
        guard bindingsAreValid else {
            record(.localCapabilityMissing)
            finishAdmissionTurn(admissionSequence)
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_local_binding_mismatch")
        }
        do {
            try Task.checkCancellation()
        } catch {
            finishAdmissionTurn(admissionSequence)
            throw error
        }
        let waiterID = UUID()
        let delivery = ContinuousBatchTokenDelivery(
            bufferLimit: configuration.tokenDeliveryBufferLimit,
            timeoutNanoseconds: configuration.tokenDeliveryTimeoutNanoseconds,
            capacity: tokenDeliveryCapacity,
            sink: tokenSink
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    request,
                    admissionSequence: admissionSequence,
                    waiterID: waiterID,
                    continuation: continuation,
                    delivery: delivery
                )
                finishAdmissionTurn(admissionSequence)
            }
        } onCancel: {
            Task { await self.cancelWaiter(requestID: request.id, waiterID: waiterID) }
        }
    }

    func cancel(requestID: String) {
        guard terminalResults[requestID] == nil, knownRequests[requestID] != nil else { return }
        // Once generation has produced its terminal result, accepted token
        // delivery owns completion ordering. Cancellation cannot overtake that
        // delivery fence and rewrite the already-decided terminal state.
        if pendingTerminalDeliveries[requestID] != nil {
            return
        }
        cancelledIDs.insert(requestID)
        ensurePump()
    }

    func drain() async throws -> ContinuousBatchDrainPermit {
        guard !cleanupFailedClosed else {
            throw ContinuousBatchSchedulerError.unsupported(
                "continuous_batching_scheduler_failed_closed"
            )
        }
        draining = true
        record(.drained)
        while !waiting.isEmpty {
            let request = waiting.removeFirst()
            finishQueued(
                request,
                status: .rejected,
                errorCode: "continuous_batching_draining"
            )
        }
        ensurePump()
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let (candidateDeadline, deadlineOverflow) = startedAt.addingReportingOverflow(
            configuration.drainTimeoutNanoseconds
        )
        var deadline = deadlineOverflow ? UInt64.max : candidateDeadline
        var forcedCancellation = false
        while pendingBindingChecks > 0 || !waiting.isEmpty || !admittingRequests.isEmpty
            || !activePrompt.isEmpty || !activeDecode.isEmpty || !pendingTerminalDeliveries.isEmpty
            || !stoppingActiveWaiters.isEmpty || !deferredTerminalCompletions.isEmpty
            || pumpRunning || backendCancellationPending {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline {
                if forcedCancellation {
                    cleanupFailedClosed = true
                    throw ContinuousBatchSchedulerError.drainTimedOut
                }
                cleanupFailedClosed = true
                record(.forcedDrainStarted)
                forcedCancellation = true
                cancelledIDs.formUnion(admittingRequests.keys)
                cancelledIDs.formUnion(activePrompt.keys)
                cancelledIDs.formUnion(activeDecode.keys)
                stopPendingTerminalDeliveriesForDrain()
                startBackendCancellation()
                let (graceDeadline, graceOverflow) = now.addingReportingOverflow(
                    configuration.drainCancellationGraceNanoseconds
                )
                deadline = graceOverflow ? UInt64.max : graceDeadline
            }
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                throw error
            }
        }
        if forcedCancellation {
            cleanupFailedClosed = true
            throw ContinuousBatchSchedulerError.drainTimedOut
        }
        guard !cleanupFailedClosed else {
            throw ContinuousBatchSchedulerError.unsupported(
                "continuous_batching_scheduler_failed_closed"
            )
        }
        return ContinuousBatchDrainPermit(
            schedulerID: schedulerID,
            snapshot: configuration.snapshot
        )
    }

    func validatesQuiescentDrainPermit(_ permit: ContinuousBatchDrainPermit) -> Bool {
        !cleanupFailedClosed
            && permit.schedulerID == schedulerID
            && permit.snapshot == configuration.snapshot
            && pendingBindingChecks == 0
            && waiting.isEmpty
            && admittingRequests.isEmpty
            && activePrompt.isEmpty
            && activeDecode.isEmpty
            && pendingTerminalDeliveries.isEmpty
            && stoppingActiveWaiters.isEmpty
            && deferredTerminalCompletions.isEmpty
            && !pumpRunning
            && !backendCancellationPending
    }

    private func stopPendingTerminalDeliveriesForDrain() {
        for requestID in pendingTerminalDeliveries.keys.sorted() {
            guard let pending = pendingTerminalDeliveries[requestID] else { continue }
            for waiter in pending.waiters
            where pending.remainingWaiterIDs.contains(waiter.id)
                && stoppingWaiterIDs.insert(waiter.id).inserted {
                waiter.delivery.stop(afterStopping: {
                    Task { await self.finishStoppedWaiter(requestID: requestID, waiterID: waiter.id) }
                })
            }
        }
    }

    func metrics() -> ContinuousBatchSchedulerMetrics {
        ContinuousBatchSchedulerMetrics(
            slotsTotal: configuration.maxActiveRows,
            slotsFree: max(0, configuration.maxActiveRows - occupiedSlots),
            waitingCount: waiting.count + pendingBindingChecks,
            activeDecodeRows: activeDecode.count,
            activePromptRows: activePrompt.count + admittingRequests.count,
            sharedForwardCalls: sharedForwardCalls,
            prefillCalls: prefillCalls,
            maxObservedBatchDepth: maxObservedBatchDepth,
            retainedTerminalResults: terminalResults.count,
            retainedDedupeTombstones: dedupeTombstones.count,
            attachedWaiters: requestWaiters.values.reduce(0) { $0 + $1.count }
                + pendingTerminalDeliveries.values.reduce(0) { $0 + $1.waiters.count }
                + stoppingActiveWaiters.count
                + deferredTerminalCompletions.values.reduce(0) { $0 + $1.waiters.count },
            retainedDiagnostics: diagnostics.count,
            diagnostics: diagnostics
        )
    }

    private func enqueue(
        _ request: ContinuousBatchSchedulerRequest,
        admissionSequence: UInt64,
        waiterID: UUID,
        continuation: CheckedContinuation<ContinuousBatchSchedulerResult, Error>,
        delivery: ContinuousBatchTokenDelivery
    ) {
        guard let requestFingerprint = RequestFingerprint(request) else {
            delivery.finish()
            continuation.resume(throwing: ContinuousBatchSchedulerError.requestFailed(
                "continuous_batching_request_fingerprint_failed"
            ))
            return
        }
        if Task.isCancelled {
            delivery.finish()
            continuation.resume(throwing: CancellationError())
            return
        }
        if let known = knownRequests[request.id], known != requestFingerprint {
            delivery.finish()
            continuation.resume(throwing: ContinuousBatchSchedulerError.duplicateRequestMismatch)
            return
        }
        if let terminal = terminalResults[request.id] {
            delivery.finish()
            continuation.resume(returning: terminal.withSettlementDisposition(.nonSettlingReplay))
            return
        }
        if var pending = pendingTerminalDeliveries[request.id] {
            guard pending.waiters.count < configuration.duplicateWaiterLimit else {
                record(.backpressureRejected)
                delivery.finish()
                continuation.resume(throwing: ContinuousBatchSchedulerError.backpressure)
                return
            }
            let waiter = Waiter(
                id: waiterID,
                continuation: continuation,
                delivery: delivery
            )
            if let token = pending.result.outputTokens.last,
               let snapshot = pending.result.snapshot {
                let replay = ContinuousBatchSchedulerTokenEvent(
                    requestID: request.id,
                    tokenIndex: pending.result.outputTokens.count - 1,
                    token: token,
                    replayTokens: pending.result.outputTokens,
                    snapshot: snapshot
                )
                guard delivery.offer(replay) else {
                    record(.backpressureRejected)
                    delivery.finish()
                    continuation.resume(throwing: ContinuousBatchSchedulerError.backpressure)
                    return
                }
            }
            pending.waiters.append(waiter)
            pending.remainingWaiterIDs.insert(waiterID)
            pendingTerminalDeliveries[request.id] = pending
            delivery.finish(afterDraining: { delivered in
                Task {
                    await self.finishTerminalDelivery(
                        requestID: request.id,
                        waiterID: waiterID,
                        delivered: delivered
                    )
                }
            })
            return
        }
        if dedupeTombstones.contains(request.id) {
            delivery.finish()
            continuation.resume(throwing: ContinuousBatchSchedulerError.idempotencyWindowExpired)
            return
        }
        if draining {
            delivery.finish()
            continuation.resume(throwing: ContinuousBatchSchedulerError.drained)
            return
        }
        if knownRequests[request.id] != nil {
            let deferredWaiterCount = deferredTerminalCompletions[request.id]?.waiters.count ?? 0
            guard requestWaiters[request.id, default: []].count + deferredWaiterCount
                    < configuration.duplicateWaiterLimit else {
                record(.backpressureRejected)
                delivery.finish()
                continuation.resume(throwing: ContinuousBatchSchedulerError.backpressure)
                return
            }
            requestWaiters[request.id, default: []].append(Waiter(
                id: waiterID,
                continuation: continuation,
                delivery: delivery
            ))
            if let row = activeDecode[request.id], let token = row.outputTokens.last {
                let replay = ContinuousBatchSchedulerTokenEvent(
                    requestID: row.request.id,
                    tokenIndex: row.outputTokens.count - 1,
                    token: token,
                    replayTokens: row.outputTokens,
                    snapshot: row.snapshot
                )
                if !delivery.offer(replay) {
                    var retained = requestWaiters[request.id] ?? []
                    retained.removeAll { $0.id == waiterID }
                    if retained.isEmpty {
                        requestWaiters.removeValue(forKey: request.id)
                        cancel(requestID: request.id)
                    } else {
                        requestWaiters[request.id] = retained
                    }
                    delivery.finish()
                    continuation.resume(throwing: ContinuousBatchSchedulerError.backpressure)
                }
            }
            return
        }
        guard let retainedTokenCost = validatedRetainedTokenCost(for: request),
              queueHasCapacity(addingTokenCost: retainedTokenCost) else {
            record(.backpressureRejected)
            delivery.finish()
            continuation.resume(throwing: ContinuousBatchSchedulerError.backpressure)
            return
        }
        do {
            switch try replayAuthority.claim(ContinuousBatchSchedulerReplayKey(
                requestID: request.id,
                fingerprintSHA256: requestFingerprint.sha256
            )) {
            case .claimed:
                break
            case .duplicateSameRequest:
                delivery.finish()
                continuation.resume(throwing: ContinuousBatchSchedulerError.idempotencyWindowExpired)
                return
            case .duplicateMismatchedRequest:
                delivery.finish()
                continuation.resume(throwing: ContinuousBatchSchedulerError.duplicateRequestMismatch)
                return
            }
        } catch {
            delivery.finish()
            continuation.resume(throwing: ContinuousBatchSchedulerError.idempotencyAuthorityUnavailable)
            return
        }
        knownRequests[request.id] = requestFingerprint
        requestAdmissionSequences[request.id] = admissionSequence
        requestWaiters[request.id, default: []].append(Waiter(
            id: waiterID,
            continuation: continuation,
            delivery: delivery
        ))
        waiting.append(request)
        ensurePump()
    }

    private func cancelWaiter(requestID: String, waiterID: UUID) {
        guard stoppingWaiterIDs.insert(waiterID).inserted else { return }
        if let waiter = pendingTerminalDeliveries[requestID]?.waiters.first(where: { $0.id == waiterID }) {
            waiter.delivery.stop(afterStopping: {
                Task { await self.finishStoppedWaiter(requestID: requestID, waiterID: waiterID) }
            })
            return
        }
        guard var waiters = requestWaiters[requestID],
              let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            stoppingWaiterIDs.remove(waiterID)
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            requestWaiters.removeValue(forKey: requestID)
        } else {
            requestWaiters[requestID] = waiters
        }
        stoppingActiveWaiters[waiterID] = StoppingActiveWaiter(
            requestID: requestID,
            waiter: waiter,
            error: CancellationError()
        )
        waiter.delivery.stop(afterStopping: {
            Task { await self.finishStoppedWaiter(requestID: requestID, waiterID: waiterID) }
        })
    }

    private func finishStoppedWaiter(requestID: String, waiterID: UUID) {
        guard stoppingWaiterIDs.remove(waiterID) != nil else { return }
        if var pending = pendingTerminalDeliveries[requestID],
           pending.remainingWaiterIDs.contains(waiterID),
           let index = pending.waiters.firstIndex(where: { $0.id == waiterID }) {
            let waiter = pending.waiters.remove(at: index)
            pending.remainingWaiterIDs.remove(waiterID)
            pending.deliveryOutcomes.removeValue(forKey: waiterID)
            waiter.continuation.resume(throwing: CancellationError())
            if pending.waiters.isEmpty {
                pendingTerminalDeliveries.removeValue(forKey: requestID)
                let failedResult = ContinuousBatchSchedulerResult(
                    requestID: pending.result.requestID,
                    conversationKey: pending.result.conversationKey,
                    outputTokens: [],
                    promptTokens: pending.result.promptTokens,
                    completionTokens: 0,
                    emittedTokens: pending.result.emittedTokens,
                    cachedPromptTokens: pending.result.cachedPromptTokens,
                    terminalStatus: .requestFailed,
                    errorCode: "continuous_batching_stream_delivery_cancelled",
                    snapshot: pending.result.snapshot,
                    settlementDisposition: .notEligible
                )
                finalizeTerminalResult(requestID: requestID, result: failedResult, waiters: pending.waiters)
            } else if pending.remainingWaiterIDs.isEmpty {
                pendingTerminalDeliveries.removeValue(forKey: requestID)
                finalizePendingTerminal(requestID: requestID, pending: pending)
            } else {
                pendingTerminalDeliveries[requestID] = pending
            }
            return
        }
        guard let stopping = stoppingActiveWaiters.removeValue(forKey: waiterID) else { return }
        stopping.waiter.continuation.resume(throwing: stopping.error)
        if !stoppingActiveWaiters.values.contains(where: { $0.requestID == requestID }),
           let deferred = deferredTerminalCompletions.removeValue(forKey: requestID) {
            let newlyAttachedWaiters = requestWaiters.removeValue(forKey: requestID) ?? []
            beginTerminalDelivery(
                requestID: requestID,
                result: deferred.result,
                waiters: deferred.waiters + newlyAttachedWaiters
            )
            return
        }
        if requestWaiters[requestID]?.isEmpty ?? true {
            cancel(requestID: requestID)
        }
    }

    private func ensurePump() {
        guard !pumpRunning else { return }
        pumpRunning = true
        Task { await self.pumpUntilIdle() }
    }

    private func pumpUntilIdle() async {
        defer {
            pumpRunning = false
            if pumpRestartRequested {
                pumpRestartRequested = false
                ensurePump()
            }
        }
        while true {
            if backendCancellationPending { break }
            if cleanupFailedClosed {
                await processCancellations()
                await failRemainingAfterCleanupFailure()
                break
            }
            await processCancellations()
            if await failClosedIfNeeded() { break }
            var madeProgress = false
            if !activeDecode.isEmpty {
                await runDecodeStep()
                madeProgress = true
                if backendCancellationPending { break }
                if await failClosedIfNeeded() { break }
                await processCancellations()
                if await failClosedIfNeeded() { break }
            }
            if await admitWaitingRows() {
                madeProgress = true
            }
            if await failClosedIfNeeded() { break }
            if await runPrefillStep() {
                madeProgress = true
            }
            if await failClosedIfNeeded() { break }
            guard madeProgress else { break }
        }
    }

    private func startBackendCancellation() {
        guard !backendCancellationPending else { return }
        backendCancellationPending = true
        Task {
            await backend.cancelInFlight()
            self.backendCancellationFinished()
        }
    }

    private func backendCancellationFinished() {
        backendCancellationPending = false
        if pumpRunning {
            pumpRestartRequested = true
        } else {
            ensurePump()
        }
    }

    private func processCancellations() async {
        guard !cancelledIDs.isEmpty else { return }
        let active = activeDecode.keys
            .filter { cancelledIDs.contains($0) }
            .sorted { admissionPrecedes($0, $1) }
        for id in active {
            if let row = activeDecode.removeValue(forKey: id) {
                let released = await release(row.handle)
                finish(row, status: released ? .cancelled : .requestFailed, errorCode: released
                    ? "request_cancelled"
                    : "continuous_batching_cleanup_failed")
                if !released { return }
            }
            cancelledIDs.remove(id)
        }
        let prompt = promptOrder.filter { cancelledIDs.contains($0) }
        for id in prompt {
            guard let row = removePromptRow(id) else { continue }
            let released = await release(row.handle)
            finish(row, status: released ? .cancelled : .requestFailed, errorCode: released
                ? "request_cancelled"
                : "continuous_batching_cleanup_failed")
            if !released { return }
            cancelledIDs.remove(id)
        }
        var remaining: [ContinuousBatchSchedulerRequest] = []
        for request in waiting {
            if cancelledIDs.contains(request.id) {
                finishQueued(request, status: .cancelled, errorCode: "request_cancelled")
                cancelledIDs.remove(request.id)
            } else {
                remaining.append(request)
            }
        }
        waiting = remaining
        cancelledIDs.subtract(terminalResults.keys)
    }

    private func runDecodeStep() async {
        let rows = activeDecode.values.sorted {
            admissionPrecedes($0.request.id, $1.request.id)
        }
        var prepared: [(row: Row, input: ContinuousBatchDecodeInput)] = []
        prepared.reserveCapacity(rows.count)
        for row in rows {
            let committedKVTokenCount = row.request.promptTokens.count - 1 + row.generatedTokens.count
            let (targetKVTokenCount, targetOverflow) = committedKVTokenCount.addingReportingOverflow(1)
            guard !targetOverflow else {
                if let removed = activeDecode.removeValue(forKey: row.request.id) {
                    let released = await release(removed.handle)
                    finish(
                        removed,
                        status: .requestFailed,
                        errorCode: released
                            ? "continuous_batching_decode_cursor_overflow"
                            : "continuous_batching_cleanup_failed"
                    )
                    if !released { return }
                }
                continue
            }
            do {
                _ = try await allocator.extend(row.handle, by: 1)
            } catch {
                record(.localExtensionFailed)
                if let removed = activeDecode.removeValue(forKey: row.request.id) {
                    let released = await release(removed.handle)
                    finish(
                        removed,
                        status: .requestFailed,
                        errorCode: released
                            ? "continuous_batching_block_extension_failed"
                            : "continuous_batching_cleanup_failed"
                    )
                    if !released { return }
                }
                continue
            }
            var beganDecode = false
            do {
                try await allocator.beginDecodeStep(row.handle)
                beganDecode = true
                prepared.append((row, ContinuousBatchDecodeInput(
                    requestID: row.request.id,
                    currentToken: row.currentToken,
                    generatedTokens: row.generatedTokens,
                    promptTokens: row.request.promptTokens,
                    samplerSeed: row.request.samplerSeed,
                    temperature: row.request.temperature,
                    topP: row.request.topP,
                    presencePenalty: row.request.presencePenalty,
                    frequencyPenalty: row.request.frequencyPenalty,
                    blockTable: try await allocator.table(for: row.handle),
                    committedKVTokenCount: committedKVTokenCount,
                    targetKVTokenCount: targetKVTokenCount,
                    samplerStep: row.generatedTokens.count
                )))
            } catch {
                if beganDecode {
                    let ended = await endDecodeStep(row.handle)
                    if !ended {
                        if let removed = activeDecode.removeValue(forKey: row.request.id) {
                            _ = await release(removed.handle)
                            finish(
                                removed,
                                status: .requestFailed,
                                errorCode: "continuous_batching_decode_cleanup_failed"
                            )
                        }
                        for prior in prepared {
                            _ = await endDecodeStep(prior.row.handle)
                        }
                        return
                    }
                }
                record(.localPreparationFailed)
                if let removed = activeDecode.removeValue(forKey: row.request.id) {
                    let released = await release(removed.handle)
                    finish(
                        removed,
                        status: .requestFailed,
                        errorCode: released
                            ? "continuous_batching_decode_prepare_failed"
                            : "continuous_batching_cleanup_failed"
                    )
                    if !released { return }
                }
            }
        }
        guard !prepared.isEmpty else { return }

        record(.decodeFirstStep)
        sharedForwardCalls += 1
        maxObservedBatchDepth = max(maxObservedBatchDepth, prepared.count)
        let outcomes: [ContinuousBatchDecodeOutcome]
        do {
            outcomes = try await backend.decode(rows: prepared.map(\.input))
            try validateDecodeOutputStructure(outcomes, expectedRequestIDs: prepared.map { $0.row.request.id })
        } catch {
            for item in prepared {
                _ = await endDecodeStep(item.row.handle)
            }
            if backendCancellationPending { return }
            record(.batchForwardFailed)
            for item in prepared {
                if let removed = activeDecode.removeValue(forKey: item.row.request.id) {
                    let released = await release(removed.handle)
                    finish(
                        removed,
                        status: released ? .batchFailed : .requestFailed,
                        errorCode: released
                            ? "continuous_batching_forward_failed"
                            : "continuous_batching_cleanup_failed"
                    )
                }
            }
            return
        }

        var healthyOutputIDs: Set<String> = []
        for item in prepared {
            if await endDecodeStep(item.row.handle) {
                healthyOutputIDs.insert(item.row.request.id)
            } else if let removed = activeDecode.removeValue(forKey: item.row.request.id) {
                _ = await release(removed.handle)
                finish(
                    removed,
                    status: .requestFailed,
                    errorCode: "continuous_batching_decode_cleanup_failed"
                )
            }
        }
        if backendCancellationPending { return }
        await processCancellations()
        guard !cleanupFailedClosed else { return }
        for outcome in outcomes {
            guard case .rowFailure(let requestID) = outcome,
                  let removed = activeDecode.removeValue(forKey: requestID) else { continue }
            record(.localPreparationFailed)
            let released = await release(removed.handle)
            finish(
                removed,
                status: .requestFailed,
                errorCode: released
                    ? "continuous_batching_row_sampling_failed"
                    : "continuous_batching_cleanup_failed"
            )
        }
        guard !cleanupFailedClosed else { return }
        let outputs = outcomes.compactMap { outcome -> ContinuousBatchDecodeOutput? in
            guard case .output(let output) = outcome else { return nil }
            return output
        }
        var invalidOutputIDs: Set<String> = []
        for output in outputs where !(0..<configuration.vocabularySize).contains(output.token) {
            invalidOutputIDs.insert(output.requestID)
            record(.localPreparationFailed)
            if let removed = activeDecode.removeValue(forKey: output.requestID) {
                let released = await release(removed.handle)
                finish(
                    removed,
                    status: .requestFailed,
                    errorCode: released
                        ? "continuous_batching_invalid_decode_token"
                        : "continuous_batching_cleanup_failed"
                )
                if !released { return }
            }
        }
        let stillActive = Set(activeDecode.keys)
        await applyDecodeOutputs(outputs.filter {
            healthyOutputIDs.contains($0.requestID)
                && stillActive.contains($0.requestID)
                && !invalidOutputIDs.contains($0.requestID)
        })
    }

    private func applyDecodeOutputs(_ outputs: [ContinuousBatchDecodeOutput]) async {
        var byID: [String: ContinuousBatchDecodeOutput] = [:]
        for output in outputs {
            byID[output.requestID] = output
        }
        for id in activeDecode.keys.sorted(by: admissionPrecedes) {
            guard let row = activeDecode[id], let output = byID[id] else { continue }
            await applyToken(output.token, to: row)
            if cleanupFailedClosed { return }
        }
    }

    private func applyToken(_ token: Int, to initialRow: Row) async {
        guard var row = activeDecode[initialRow.request.id] else { return }
        row.generatedTokens.append(token)
        row.currentToken = token
        row.pendingOutputTokens.append(token)

        let terminalStatus: ContinuousBatchSchedulerTerminalStatus?
        if let stopLength = matchingStopLength(
            row.generatedTokens,
            stopSequences: row.request.stopTokenSequences
        ) {
            guard stopLength <= row.pendingOutputTokens.count else {
                activeDecode.removeValue(forKey: row.request.id)
                let released = await release(row.handle)
                finish(
                    row,
                    status: .requestFailed,
                    errorCode: released
                        ? "continuous_batching_stop_filter_state_invalid"
                        : "continuous_batching_cleanup_failed"
                )
                return
            }
            row.pendingOutputTokens.removeLast(stopLength)
            terminalStatus = .stop
        } else if row.generatedTokens.count >= row.request.maxOutputTokens {
            terminalStatus = .length
        } else {
            terminalStatus = nil
        }

        let visibleTokens: [Int]
        if terminalStatus != nil {
            visibleTokens = row.pendingOutputTokens
            row.pendingOutputTokens.removeAll(keepingCapacity: true)
        } else {
            var ready: [Int] = []
            while let first = row.pendingOutputTokens.first,
                  !isPotentialStopPrefix(
                      row.pendingOutputTokens,
                      stopSequences: row.request.stopTokenSequences
                  ) {
                ready.append(first)
                row.pendingOutputTokens.removeFirst()
            }
            visibleTokens = ready
        }

        let firstVisibleIndex = row.outputTokens.count
        row.outputTokens.append(contentsOf: visibleTokens)
        activeDecode[row.request.id] = row
        if !deliverVisibleTokens(
            visibleTokens,
            firstIndex: firstVisibleIndex,
            row: row
        ) {
            activeDecode.removeValue(forKey: row.request.id)
            let released = await release(row.handle)
            finish(
                row,
                status: .requestFailed,
                errorCode: released
                    ? "continuous_batching_stream_backpressure"
                    : "continuous_batching_cleanup_failed"
            )
            return
        }

        if let terminalStatus {
            activeDecode.removeValue(forKey: row.request.id)
            let released = await release(row.handle)
            finish(row, status: released ? terminalStatus : .requestFailed, errorCode: released
                ? nil
                : "continuous_batching_cleanup_failed")
        }
    }

    private func deliverVisibleTokens(_ tokens: [Int], firstIndex: Int, row: Row) -> Bool {
        guard !tokens.isEmpty else { return !(requestWaiters[row.request.id]?.isEmpty ?? true) }
        for (offset, token) in tokens.enumerated() {
            let event = ContinuousBatchSchedulerTokenEvent(
                requestID: row.request.id,
                tokenIndex: firstIndex + offset,
                token: token,
                replayTokens: nil,
                snapshot: row.snapshot
            )
            var retained: [Waiter] = []
            for waiter in requestWaiters[row.request.id] ?? [] {
                if waiter.delivery.offer(event) {
                    retained.append(waiter)
                } else {
                    beginStoppingActiveWaiter(
                        requestID: row.request.id,
                        waiter: waiter,
                        error: ContinuousBatchSchedulerError.backpressure
                    )
                }
            }
            if retained.isEmpty {
                requestWaiters.removeValue(forKey: row.request.id)
                return false
            }
            requestWaiters[row.request.id] = retained
        }
        return true
    }

    private func beginStoppingActiveWaiter(
        requestID: String,
        waiter: Waiter,
        error: any Error
    ) {
        guard stoppingWaiterIDs.insert(waiter.id).inserted else { return }
        stoppingActiveWaiters[waiter.id] = StoppingActiveWaiter(
            requestID: requestID,
            waiter: waiter,
            error: error
        )
        waiter.delivery.stop(afterStopping: {
            Task { await self.finishStoppedWaiter(requestID: requestID, waiterID: waiter.id) }
        })
    }

    private func admitWaitingRows() async -> Bool {
        guard occupiedSlots < configuration.maxActiveRows, !waiting.isEmpty else { return false }
        var madeProgress = false
        var attempts = 0
        while attempts < configuration.maxPrefillRowsPerIteration,
              occupiedSlots < configuration.maxActiveRows,
              !waiting.isEmpty {
            attempts += 1
            let request = waiting.removeFirst()
            madeProgress = true
            if cancelledIDs.remove(request.id) != nil {
                finishQueued(request, status: .cancelled, errorCode: "request_cancelled")
                continue
            }

            admittingRequests[request.id] = request
            do {
                let reservation = try initialReservation(for: request)
                let handle = try await allocator.allocate(
                    conversationKey: "continuous-batching:\(request.id)",
                    initialCapacityTokens: reservation.initialCapacityTokens,
                    maxLogicalTokens: reservation.maxLogicalTokens,
                    initialTokens: 0
                )
                admittingRequests.removeValue(forKey: request.id)
                if draining {
                    let released = await release(handle)
                    finishQueued(
                        request,
                        status: released ? .rejected : .requestFailed,
                        errorCode: released ? "continuous_batching_draining" : "continuous_batching_cleanup_failed"
                    )
                    if !released { return madeProgress }
                    continue
                } else if cancelledIDs.remove(request.id) != nil {
                    let released = await release(handle)
                    finishQueued(
                        request,
                        status: released ? .cancelled : .requestFailed,
                        errorCode: released ? "request_cancelled" : "continuous_batching_cleanup_failed"
                    )
                    if !released { return madeProgress }
                    continue
                }
                record(.promptHeadroomReserved)
                record(.accepted)
                activePrompt[request.id] = Row(
                    request: request,
                    handle: handle,
                    currentToken: request.promptTokens.last ?? 0,
                    generatedTokens: [],
                    outputTokens: [],
                    pendingOutputTokens: [],
                    prefillCursor: 0,
                    snapshot: configuration.snapshot
                )
                promptOrder.append(request.id)
            } catch PagedKVAllocatorError.capacityExceeded {
                admittingRequests.removeValue(forKey: request.id)
                if draining {
                    finishQueued(request, status: .rejected, errorCode: "continuous_batching_draining")
                } else if activeDecode.isEmpty && activePrompt.isEmpty && admittingRequests.isEmpty {
                    record(.poolCapacityRejected)
                    finishQueued(
                        request,
                        status: .rejected,
                        errorCode: "continuous_batching_pool_capacity_exhausted"
                    )
                } else {
                    waiting.insert(request, at: 0)
                    return madeProgress
                }
            } catch {
                admittingRequests.removeValue(forKey: request.id)
                finishQueued(request, status: .requestFailed, errorCode: "continuous_batching_admission_failed")
            }
        }
        return madeProgress
    }

    private func runPrefillStep() async -> Bool {
        let selectedIDs = Array(promptOrder.prefix(configuration.maxPrefillRowsPerIteration))
        guard !selectedIDs.isEmpty else { return false }

        var prepared: [(row: Row, input: ContinuousBatchPrefillInput, chunkCount: Int)] = []
        var madeProgress = false
        for id in selectedIDs {
            guard let row = activePrompt[id] else { continue }
            let prefixTokenCount = row.request.promptTokens.count - 1
            if row.prefillCursor >= prefixTokenCount {
                await transitionPrefilledRow(row)
                madeProgress = true
                if cleanupFailedClosed { return true }
                continue
            }
            let end = min(prefixTokenCount, row.prefillCursor + configuration.maxPromptChunkTokens)
            let chunk = Array(row.request.promptTokens[row.prefillCursor..<end])
            do {
                _ = try await allocator.extend(row.handle, by: chunk.count)
            } catch {
                record(.localExtensionFailed)
                _ = removePromptRow(id)
                let released = await release(row.handle)
                finish(
                    row,
                    status: .requestFailed,
                    errorCode: released
                        ? "continuous_batching_prefill_extend_failed"
                        : "continuous_batching_cleanup_failed"
                )
                if !released { return true }
                continue
            }
            do {
                prepared.append((
                    row,
                    ContinuousBatchPrefillInput(
                        requestID: id,
                        promptTokens: chunk,
                        binding: try await allocator.binding(for: row.handle),
                        promptTokenOffset: row.prefillCursor,
                        committedKVTokenCount: row.prefillCursor,
                        targetKVTokenCount: end,
                        isFinalChunk: end == prefixTokenCount
                    ),
                    chunk.count
                ))
            } catch {
                record(.localPreparationFailed)
                _ = removePromptRow(id)
                let released = await release(row.handle)
                finish(
                    row,
                    status: .requestFailed,
                    errorCode: released
                        ? "continuous_batching_prefill_prepare_failed"
                        : "continuous_batching_cleanup_failed"
                )
                if !released { return true }
            }
        }
        guard !prepared.isEmpty else { return madeProgress }

        prefillCalls += 1
        let outputs: [ContinuousBatchPrefillOutput]
        do {
            outputs = try await backend.prefill(rows: prepared.map(\.input))
            try validatePrefillOutputStructure(outputs, expectedRequestIDs: prepared.map { $0.row.request.id })
        } catch {
            record(.prefillFailed)
            for item in prepared {
                guard let row = removePromptRow(item.row.request.id) else { continue }
                let released = await release(row.handle)
                finish(
                    row,
                    status: .requestFailed,
                    errorCode: released
                        ? "continuous_batching_prefill_failed"
                        : "continuous_batching_cleanup_failed"
                )
                if !released { return true }
            }
            return true
        }

        let byID = Dictionary(uniqueKeysWithValues: outputs.map { ($0.requestID, $0) })
        for item in prepared {
            let id = item.row.request.id
            guard var row = activePrompt[id], byID[id] != nil else { continue }
            if cancelledIDs.remove(id) != nil {
                _ = removePromptRow(id)
                let released = await release(row.handle)
                finish(row, status: released ? .cancelled : .requestFailed, errorCode: released
                    ? "request_cancelled"
                    : "continuous_batching_cleanup_failed")
                if !released { return true }
                continue
            }
            row.prefillCursor += item.chunkCount
            if row.prefillCursor == row.request.promptTokens.count - 1 {
                activePrompt[id] = row
                await transitionPrefilledRow(row)
                if cleanupFailedClosed { return true }
            } else {
                activePrompt[id] = row
            }
        }
        return true
    }

    private func transitionPrefilledRow(_ row: Row) async {
        _ = removePromptRow(row.request.id)
        if row.request.maxOutputTokens == 0 {
            let released = await release(row.handle)
            finish(row, status: released ? .length : .requestFailed, errorCode: released
                ? nil
                : "continuous_batching_cleanup_failed")
        } else {
            activeDecode[row.request.id] = row
            record(.joinedDecode)
        }
    }

    private func failRemainingAfterCleanupFailure() async {
        while !waiting.isEmpty {
            finishQueued(
                waiting.removeFirst(),
                status: .requestFailed,
                errorCode: "continuous_batching_scheduler_failed_closed"
            )
        }
        for id in promptOrder {
            guard let row = activePrompt.removeValue(forKey: id) else { continue }
            _ = await release(row.handle)
            finish(row, status: .requestFailed, errorCode: "continuous_batching_scheduler_failed_closed")
        }
        promptOrder.removeAll()
        for id in activeDecode.keys.sorted() {
            guard let row = activeDecode.removeValue(forKey: id) else { continue }
            _ = await release(row.handle)
            finish(row, status: .requestFailed, errorCode: "continuous_batching_scheduler_failed_closed")
        }
        cancelledIDs.removeAll()
    }

    private func failClosedIfNeeded() async -> Bool {
        guard cleanupFailedClosed else { return false }
        await processCancellations()
        await failRemainingAfterCleanupFailure()
        return true
    }

    private func finishQueued(
        _ request: ContinuousBatchSchedulerRequest,
        status: ContinuousBatchSchedulerTerminalStatus,
        errorCode: String?
    ) {
        let result = ContinuousBatchSchedulerResult(
            requestID: request.id,
            conversationKey: request.conversationKey,
            outputTokens: [],
            promptTokens: 0,
            completionTokens: 0,
            emittedTokens: 0,
            cachedPromptTokens: 0,
            terminalStatus: status,
            errorCode: errorCode,
            snapshot: nil,
            settlementDisposition: .notEligible
        )
        complete(requestID: request.id, result: result)
    }

    private func finish(
        _ row: Row,
        status: ContinuousBatchSchedulerTerminalStatus,
        errorCode: String?
    ) {
        record(status == .cancelled ? .cancelled : .stopped)
        let isSuccessful = status == .stop || status == .length
        let outputTokens = isSuccessful ? row.outputTokens : []
        let result = ContinuousBatchSchedulerResult(
            requestID: row.request.id,
            conversationKey: row.request.conversationKey,
            outputTokens: outputTokens,
            promptTokens: row.request.promptTokens.count,
            completionTokens: isSuccessful ? row.generatedTokens.count : 0,
            emittedTokens: row.outputTokens.count,
            cachedPromptTokens: row.request.cachedPromptTokens,
            terminalStatus: status,
            errorCode: errorCode,
            snapshot: row.snapshot,
            settlementDisposition: isSuccessful ? .eligibleOwner : .notEligible
        )
        complete(requestID: row.request.id, result: result)
    }

    private func complete(requestID: String, result: ContinuousBatchSchedulerResult) {
        guard terminalResults[requestID] == nil, pendingTerminalDeliveries[requestID] == nil else { return }
        requestAdmissionSequences.removeValue(forKey: requestID)
        let waiters = requestWaiters.removeValue(forKey: requestID) ?? []
        if stoppingActiveWaiters.values.contains(where: { $0.requestID == requestID }) {
            deferredTerminalCompletions[requestID] = DeferredTerminalCompletion(
                result: result,
                waiters: waiters
            )
            return
        }
        beginTerminalDelivery(requestID: requestID, result: result, waiters: waiters)
    }

    private func beginTerminalDelivery(
        requestID: String,
        result: ContinuousBatchSchedulerResult,
        waiters: [Waiter]
    ) {
        guard !waiters.isEmpty else {
            finalizeTerminalResult(requestID: requestID, result: result, waiters: [])
            return
        }
        pendingTerminalDeliveries[requestID] = PendingTerminalDelivery(
            result: result,
            waiters: waiters,
            remainingWaiterIDs: Set(waiters.map(\.id))
        )
        for waiter in waiters {
            waiter.delivery.finish(afterDraining: { delivered in
                Task {
                    await self.finishTerminalDelivery(
                        requestID: requestID,
                        waiterID: waiter.id,
                        delivered: delivered
                    )
                }
            })
        }
    }

    private func finishTerminalDelivery(requestID: String, waiterID: UUID, delivered: Bool) {
        guard !stoppingWaiterIDs.contains(waiterID) else { return }
        guard var pending = pendingTerminalDeliveries[requestID],
              pending.remainingWaiterIDs.remove(waiterID) != nil else { return }
        pending.deliveryOutcomes[waiterID] = delivered
        guard pending.remainingWaiterIDs.isEmpty else {
            pendingTerminalDeliveries[requestID] = pending
            return
        }
        pendingTerminalDeliveries.removeValue(forKey: requestID)
        finalizePendingTerminal(requestID: requestID, pending: pending)
    }

    private func finalizePendingTerminal(requestID: String, pending: PendingTerminalDelivery) {
        let result: ContinuousBatchSchedulerResult
        if pending.deliveryOutcomes.values.contains(true) {
            result = pending.result
        } else {
            result = ContinuousBatchSchedulerResult(
                requestID: pending.result.requestID,
                conversationKey: pending.result.conversationKey,
                outputTokens: [],
                promptTokens: pending.result.promptTokens,
                completionTokens: 0,
                emittedTokens: pending.result.emittedTokens,
                cachedPromptTokens: pending.result.cachedPromptTokens,
                terminalStatus: .requestFailed,
                errorCode: "continuous_batching_stream_delivery_timed_out",
                snapshot: pending.result.snapshot,
                settlementDisposition: .notEligible
            )
        }
        finalizeTerminalResult(
            requestID: requestID,
            result: result,
            waiters: pending.waiters,
            deliveryOutcomes: pending.deliveryOutcomes
        )
    }

    private func finalizeTerminalResult(
        requestID: String,
        result: ContinuousBatchSchedulerResult,
        waiters: [Waiter],
        deliveryOutcomes: [UUID: Bool]? = nil
    ) {
        terminalResultOrder.append(requestID)
        terminalResults[requestID] = result.withSettlementDisposition(
            result.settlementDisposition == .eligibleOwner ? .nonSettlingReplay : .notEligible
        )
        let settlementOwnerID = result.settlementDisposition == .eligibleOwner
            ? waiters.first(where: { deliveryOutcomes?[$0.id] != false })?.id
            : nil
        for waiter in waiters {
            if deliveryOutcomes?[waiter.id] == false {
                waiter.continuation.resume(returning: ContinuousBatchSchedulerResult(
                    requestID: result.requestID,
                    conversationKey: result.conversationKey,
                    outputTokens: [],
                    promptTokens: result.promptTokens,
                    completionTokens: 0,
                    emittedTokens: result.emittedTokens,
                    cachedPromptTokens: result.cachedPromptTokens,
                    terminalStatus: .requestFailed,
                    errorCode: "continuous_batching_stream_delivery_timed_out",
                    snapshot: result.snapshot,
                    settlementDisposition: .notEligible
                ))
            } else {
                waiter.continuation.resume(returning: result.withSettlementDisposition(
                    waiter.id == settlementOwnerID ? .eligibleOwner : (
                        result.settlementDisposition == .eligibleOwner ? .nonSettlingReplay : .notEligible
                    )
                ))
            }
        }
        while terminalResultOrder.count > configuration.terminalResultLimit {
            let evictedID = terminalResultOrder.removeFirst()
            terminalResults.removeValue(forKey: evictedID)
            knownRequests.removeValue(forKey: evictedID)
            cancelledIDs.remove(evictedID)
            if dedupeTombstones.insert(evictedID).inserted {
                dedupeTombstoneOrder.append(evictedID)
            }
        }
        while dedupeTombstoneOrder.count > configuration.dedupeTombstoneLimit {
            dedupeTombstones.remove(dedupeTombstoneOrder.removeFirst())
        }
    }

    private func record(_ diagnostic: ContinuousBatchSchedulerDiagnostic) {
        diagnostics.append(diagnostic)
        if diagnostics.count > configuration.diagnosticLimit {
            diagnostics.removeFirst(diagnostics.count - configuration.diagnosticLimit)
        }
    }

    @discardableResult
    private func release(_ handle: PagedKVBlockTableHandle) async -> Bool {
        do {
            try await allocator.release(handle)
            return true
        } catch {
            cleanupFailedClosed = true
            record(.cleanupFailed)
            return false
        }
    }

    @discardableResult
    private func endDecodeStep(_ handle: PagedKVBlockTableHandle) async -> Bool {
        do {
            try await allocator.endDecodeStep(handle)
            return true
        } catch {
            cleanupFailedClosed = true
            record(.cleanupFailed)
            return false
        }
    }

    private var occupiedSlots: Int {
        admittingRequests.count + activePrompt.count + activeDecode.count
    }

    private func admissionPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let lhsSequence = requestAdmissionSequences[lhs] ?? UInt64.max
        let rhsSequence = requestAdmissionSequences[rhs] ?? UInt64.max
        return lhsSequence == rhsSequence ? lhs < rhs : lhsSequence < rhsSequence
    }

    @discardableResult
    private func removePromptRow(_ requestID: String) -> Row? {
        promptOrder.removeAll { $0 == requestID }
        return activePrompt.removeValue(forKey: requestID)
    }

    private func initialReservation(for request: ContinuousBatchSchedulerRequest) throws -> (
        initialCapacityTokens: Int,
        maxLogicalTokens: Int
    ) {
        let prompt = request.promptTokens.count
        let (promptPlusHeadroom, headroomOverflow) = prompt.addingReportingOverflow(configuration.decodeHeadroomTokens)
        let (promptPlusOutput, outputOverflow) = prompt.addingReportingOverflow(request.maxOutputTokens)
        guard !headroomOverflow, !outputOverflow else {
            throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_reservation_overflow")
        }
        let initialCapacity = configuration.maxActiveRows == 1
            ? promptPlusOutput
            : min(promptPlusHeadroom, promptPlusOutput)
        return (initialCapacity, promptPlusOutput)
    }

    private func validateDecodeOutputStructure(
        _ outcomes: [ContinuousBatchDecodeOutcome],
        expectedRequestIDs: [String]
    ) throws {
        var seen: Set<String> = []
        for outcome in outcomes {
            guard seen.insert(outcome.requestID).inserted else {
                throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_duplicate_decode_row")
            }
        }
        guard seen == Set(expectedRequestIDs) else {
            throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_decode_row_mismatch")
        }
    }

    private func validatePrefillOutputStructure(
        _ outputs: [ContinuousBatchPrefillOutput],
        expectedRequestIDs: [String]
    ) throws {
        var seen: Set<String> = []
        for output in outputs {
            guard seen.insert(output.requestID).inserted else {
                throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_duplicate_prefill_row")
            }
        }
        guard seen == Set(expectedRequestIDs) else {
            throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_prefill_row_mismatch")
        }
    }

    private func matchingStopLength(_ tokens: [Int], stopSequences: [[Int]]) -> Int? {
        stopSequences
            .filter { !$0.isEmpty && $0.count <= tokens.count && Array(tokens.suffix($0.count)) == $0 }
            .map(\.count)
            .max()
    }

    private func validatedRetainedTokenCost(
        for request: ContinuousBatchSchedulerRequest
    ) -> Int? {
        guard request.maxOutputTokens <= configuration.maxRequestTokens else { return nil }
        let (contextTokens, contextOverflow) = request.promptTokens.count.addingReportingOverflow(
            request.maxOutputTokens
        )
        guard !contextOverflow, contextTokens <= configuration.maxRequestTokens else { return nil }
        var stopTokens = 0
        for sequence in request.stopTokenSequences {
            let (next, overflow) = stopTokens.addingReportingOverflow(sequence.count)
            guard !overflow, next <= configuration.maxTotalStopTokens else { return nil }
            stopTokens = next
        }
        let (retained, retainedOverflow) = request.promptTokens.count.addingReportingOverflow(stopTokens)
        guard !retainedOverflow else { return nil }
        return retained
    }

    private func queueHasCapacity(addingTokenCost tokenCost: Int) -> Bool {
        let (queuedCount, countOverflow) = waiting.count.addingReportingOverflow(pendingBindingChecks)
        guard !countOverflow, queuedCount < configuration.queueLimit else { return false }
        var waitingTokens = 0
        for request in waiting {
            guard let cost = validatedRetainedTokenCost(for: request) else { return false }
            let (next, overflow) = waitingTokens.addingReportingOverflow(cost)
            guard !overflow else { return false }
            waitingTokens = next
        }
        let (withPending, pendingOverflow) = waitingTokens.addingReportingOverflow(
            pendingBindingTokenCount
        )
        guard !pendingOverflow else { return false }
        let (total, totalOverflow) = withPending.addingReportingOverflow(tokenCost)
        return !totalOverflow && total <= configuration.maxQueuedTokens
    }

    private func isPotentialStopPrefix(_ pending: [Int], stopSequences: [[Int]]) -> Bool {
        stopSequences.contains { sequence in
            pending.count <= sequence.count && Array(sequence.prefix(pending.count)) == pending
        }
    }

    private func localBindingsAreValid() async -> Bool {
        let allocatorBlockSize = await allocator.blockSizeTokens
        let allocatorMaxBlocks = await allocator.maxPhysicalBlocks
        let allocatorPoolEpoch = await allocator.poolEpoch
        return allocatorBlockSize == configuration.descriptor.blockSizeTokens
            && allocatorMaxBlocks == configuration.descriptor.maxPhysicalBlocks
            && allocatorPoolEpoch == configuration.descriptor.poolEpoch
            && configuration.snapshot.modelID == configuration.descriptor.modelID
            && configuration.snapshot.modelSHA256 == configuration.descriptor.modelSHA256
    }

    private func waitForAdmissionTurn(_ sequence: UInt64) async {
        precondition(sequence >= currentAdmissionSequence, "admission sequence cannot move backward")
        guard sequence != currentAdmissionSequence else { return }
        await withCheckedContinuation { continuation in
            precondition(admissionTurnWaiters[sequence] == nil, "admission sequence waiter must be unique")
            admissionTurnWaiters[sequence] = continuation
        }
    }

    private func finishAdmissionTurn(_ sequence: UInt64) {
        precondition(sequence == currentAdmissionSequence, "admission must advance in FCFS order")
        currentAdmissionSequence += 1
        admissionTurnWaiters.removeValue(forKey: currentAdmissionSequence)?.resume()
    }
}
