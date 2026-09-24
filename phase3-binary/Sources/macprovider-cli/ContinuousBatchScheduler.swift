import Foundation
import CryptoKit
import MLXLMCommon
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
    case queueWaitTimedOut = "queue_wait_timed_out"
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
    /// Bounded admission wait. A request that has not reached a slot within
    /// this window is rejected pre-admission with `.queueWaitTimedOut` rather
    /// than waiting forever behind a saturated batch. `0` disables the bound.
    let queueWaitTimeoutNanoseconds: UInt64
    let diagnosticLimit: Int
    let vocabularySize: Int
    let maxRequestIDBytes: Int
    let maxRequestTokens: Int
    let maxQueuedTokens: Int
    let maxStopSequences: Int
    let maxStopSequenceTokens: Int
    let maxTotalStopTokens: Int
    let snapshot: ContinuousBatchSchedulerSnapshot
    /// Tokens generated inside one backend hop when nothing is waiting to join.
    /// `1` preserves per-token decode (tests, join-pending). Production uses
    /// `defaultDecodeLockstepWindow` so compiled contiguous decode can amortize
    /// the model-container hop. FR-CB5 still inserts at the next hop boundary.
    let maxDecodeLockstepWindow: Int

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
        queueWaitTimeoutNanoseconds: UInt64 = ContinuousBatchSchedulerConfiguration.defaultQueueWaitTimeoutNanoseconds,
        diagnosticLimit: Int = 512,
        vocabularySize: Int = Int.max,
        maxRequestIDBytes: Int = 256,
        maxRequestTokens: Int = 131_072,
        maxQueuedTokens: Int = 1_048_576,
        maxStopSequences: Int = 16,
        maxStopSequenceTokens: Int = 64,
        maxTotalStopTokens: Int = 256,
        snapshot: ContinuousBatchSchedulerSnapshot,
        maxDecodeLockstepWindow: Int = 1
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
        self.queueWaitTimeoutNanoseconds = min(
            queueWaitTimeoutNanoseconds,
            ContinuousBatchSchedulerConfiguration.maximumQueueWaitTimeoutNanoseconds
        )
        self.diagnosticLimit = max(1, diagnosticLimit)
        self.vocabularySize = max(1, vocabularySize)
        self.maxRequestIDBytes = max(1, maxRequestIDBytes)
        self.maxRequestTokens = max(1, maxRequestTokens)
        self.maxQueuedTokens = max(self.maxRequestTokens, maxQueuedTokens)
        self.maxStopSequences = max(1, maxStopSequences)
        self.maxStopSequenceTokens = max(1, maxStopSequenceTokens)
        self.maxTotalStopTokens = max(1, maxTotalStopTokens)
        self.snapshot = snapshot
        self.maxDecodeLockstepWindow = max(1, maxDecodeLockstepWindow)
    }

    /// Production serve-path lockstep burst. Join/leave still happens between
    /// hops (FR-CB5); a queued row forces the scheduler back to one token.
    static let defaultDecodeLockstepWindow = 16

    /// Stream token delivery is non-blocking on the scheduler actor. Compiled
    /// lockstep offers a full window per hop, and the next hop can start while
    /// the waiter is still in tokenizer/SSE work, so production must absorb
    /// more than one window. Tests that want fail-closed backpressure keep the
    /// initializer default of 16.
    static let productionTokenDeliveryBufferLimit = 8_192

    /// SPEC-038 AC-25 bounded admission wait. An unbounded queue wait has no
    /// API-visible terminal outcome at all, so the serve path defaults to 30s
    /// unless the operator sets `continuous_batch_queue_wait_timeout_ms`.
    static let defaultQueueWaitTimeoutNanoseconds: UInt64 = 30_000_000_000

    /// Upper bound (1 hour) for `continuous_batch_queue_wait_timeout_ms`. A
    /// longer wait is not a bounded admission outcome in any useful sense.
    static let maximumQueueWaitTimeoutMS = 3_600_000
    static let maximumQueueWaitTimeoutNanoseconds = UInt64(maximumQueueWaitTimeoutMS) * 1_000_000
}

struct ContinuousBatchSchedulerRequest: Sendable, Equatable, Encodable {
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
    let retainedPagedKVSequence: PagedKVRetainedSequence?

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
        cachedPromptTokens: Int = 0,
        retainedPagedKVSequence: PagedKVRetainedSequence? = nil
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
        self.retainedPagedKVSequence = retainedPagedKVSequence
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationKey
        case promptTokens
        case maxOutputTokens
        case stopTokenSequences
        case samplerSeed
        case temperature
        case topP
        case presencePenalty
        case frequencyPenalty
        case cachedPromptTokens
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
    /// Raw generated tokens, including stop tokens withheld from buyers.
    let generatedTokens: [Int]
    let outputTokens: [Int]
    let promptTokens: Int
    let completionTokens: Int
    let emittedTokens: Int
    let cachedPromptTokens: Int
    let terminalStatus: ContinuousBatchSchedulerTerminalStatus
    let errorCode: String?
    let snapshot: ContinuousBatchSchedulerSnapshot?
    let settlementDisposition: ContinuousBatchSettlementDisposition
    let retainedCache: ContinuousBatchRetainedCache?

    func withSettlementDisposition(
        _ disposition: ContinuousBatchSettlementDisposition
    ) -> ContinuousBatchSchedulerResult {
        ContinuousBatchSchedulerResult(
            requestID: requestID,
            conversationKey: conversationKey,
            generatedTokens: generatedTokens,
            outputTokens: outputTokens,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            emittedTokens: emittedTokens,
            cachedPromptTokens: cachedPromptTokens,
            terminalStatus: terminalStatus,
            errorCode: errorCode,
            snapshot: snapshot,
            settlementDisposition: disposition,
            retainedCache: disposition == .eligibleOwner ? retainedCache : nil
        )
    }

    func withRetainedCache(_ cache: ContinuousBatchRetainedCache?) -> ContinuousBatchSchedulerResult {
        ContinuousBatchSchedulerResult(
            requestID: requestID,
            conversationKey: conversationKey,
            generatedTokens: generatedTokens,
            outputTokens: outputTokens,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            emittedTokens: emittedTokens,
            cachedPromptTokens: cachedPromptTokens,
            terminalStatus: terminalStatus,
            errorCode: errorCode,
            snapshot: snapshot,
            settlementDisposition: settlementDisposition,
            retainedCache: cache
        )
    }

    static func == (lhs: ContinuousBatchSchedulerResult, rhs: ContinuousBatchSchedulerResult) -> Bool {
        lhs.requestID == rhs.requestID
            && lhs.conversationKey == rhs.conversationKey
            && lhs.generatedTokens == rhs.generatedTokens
            && lhs.outputTokens == rhs.outputTokens
            && lhs.promptTokens == rhs.promptTokens
            && lhs.completionTokens == rhs.completionTokens
            && lhs.emittedTokens == rhs.emittedTokens
            && lhs.cachedPromptTokens == rhs.cachedPromptTokens
            && lhs.terminalStatus == rhs.terminalStatus
            && lhs.errorCode == rhs.errorCode
            && lhs.snapshot == rhs.snapshot
            && lhs.settlementDisposition == rhs.settlementDisposition
            && lhs.retainedCache?.retainedSequence == rhs.retainedCache?.retainedSequence
    }
}

final class ContinuousBatchRetainedCache: @unchecked Sendable {
    let retainedSequence: PagedKVRetainedSequence
    let layers: [KVCache]
    let deliveryID: UUID?

    init(retainedSequence: PagedKVRetainedSequence, layers: [KVCache], deliveryID: UUID? = nil) {
        self.retainedSequence = retainedSequence
        self.layers = layers
        self.deliveryID = deliveryID
    }

    func withDeliveryID(_ deliveryID: UUID?) -> ContinuousBatchRetainedCache {
        ContinuousBatchRetainedCache(
            retainedSequence: retainedSequence,
            layers: layers,
            deliveryID: deliveryID
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
    let binding: PagedKVStorageBinding
    let blockTable: PagedKVBlockTable
    let committedKVTokenCount: Int
    let targetKVTokenCount: Int
    /// Zero-based sampling step. Backends MUST sample as a pure function of
    /// this step, `samplerSeed`, the complete generated-token history, sampling
    /// parameters, and the row logits; hidden cross-row sampler state is
    /// forbidden.
    let samplerStep: Int
}

struct ContinuousBatchTerminalKVCommitInput: Sendable, Equatable {
    let requestID: String
    let currentToken: Int
    let binding: PagedKVStorageBinding
    let blockTable: PagedKVBlockTable
    let committedKVTokenCount: Int
    let targetKVTokenCount: Int
}

struct ContinuousBatchDecodeOutput: Sendable, Equatable {
    let requestID: String
    /// Last sampled token. Equal to `tokens.last` when `tokens` is non-empty.
    let token: Int
    /// Generation-order tokens for this backend call. One-token `decode(rows:)`
    /// yields `[token]`. A lockstep window yields every sampled token so the
    /// scheduler can apply stop/stream/receipt sequentially without dropping
    /// intermediates.
    let tokens: [Int]

    init(requestID: String, token: Int) {
        self.requestID = requestID
        self.token = token
        self.tokens = [token]
    }

    init(requestID: String, tokens: [Int]) {
        self.requestID = requestID
        self.tokens = tokens
        self.token = tokens.last ?? 0
    }
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
    /// Greedy lockstep decode of `steps` tokens. Implementations MAY keep the
    /// work inside one model-container hop. Returned `tokens` MUST contain every
    /// sampled token in generation order, not only the last.
    func decodeLockstepWindow(
        rows: [ContinuousBatchDecodeInput],
        steps: Int
    ) async throws -> [ContinuousBatchDecodeOutcome]
    /// Install a same-conversation retained paged-KV handoff before the row resumes
    /// prefill at its serial LCP. Backends that cannot consume FR-PKV10 must fail
    /// closed instead of accepting positive cached-token credit.
    func installRetainedPagedKVCache(
        requestID: String,
        handoff: PagedKVPagedCacheHandoff,
        binding: PagedKVStorageBinding
    ) async throws
    /// Commit the final buyer-visible token into row-local KV state when a row
    /// stops immediately after sampling it. Retention happens after this step so
    /// canonical prompt history and retained paged-KV length agree.
    func commitTerminalKV(_ input: ContinuousBatchTerminalKVCommitInput) async throws
    /// Row-local cleanup hook for backend state that is not owned by the
    /// scheduler/allocator. Called after the scheduler has reached a terminal
    /// result for the request. Implementations that keep no row-local state can
    /// rely on the default no-op.
    func finish(requestID: String)
    /// Returns only after in-flight calls have stopped accessing row bindings.
    func cancelInFlight() async
}

protocol ContinuousBatchRetainedCacheBridge: Sendable {
    func reattachPagedKVCache(
        handle: PagedKVBlockTableHandle,
        table: PagedKVBlockTable
    ) throws -> PagedKVPagedCacheHandoff
}

extension ContinuousBatchSchedulerBackend {
    func decodeLockstepWindow(
        rows: [ContinuousBatchDecodeInput],
        steps: Int
    ) async throws -> [ContinuousBatchDecodeOutcome] {
        let window = max(1, steps)
        var tokensByID: [String: [Int]] = [:]
        var failed: Set<String> = []
        var current = rows
        for _ in 0..<window {
            guard !current.isEmpty else { break }
            let outcomes = try await decode(rows: current)
            var byID: [String: ContinuousBatchDecodeOutcome] = [:]
            for outcome in outcomes {
                byID[outcome.requestID] = outcome
            }
            var next: [ContinuousBatchDecodeInput] = []
            next.reserveCapacity(current.count)
            for input in current {
                guard let outcome = byID[input.requestID] else {
                    failed.insert(input.requestID)
                    continue
                }
                switch outcome {
                case .rowFailure(let requestID):
                    failed.insert(requestID)
                case .output(let output):
                    let sampled = output.tokens.isEmpty ? [output.token] : output.tokens
                    guard let last = sampled.last else {
                        failed.insert(input.requestID)
                        continue
                    }
                    tokensByID[output.requestID, default: []].append(contentsOf: sampled)
                    next.append(ContinuousBatchDecodeInput(
                        requestID: input.requestID,
                        currentToken: last,
                        generatedTokens: input.generatedTokens + sampled,
                        promptTokens: input.promptTokens,
                        samplerSeed: input.samplerSeed,
                        temperature: input.temperature,
                        topP: input.topP,
                        presencePenalty: input.presencePenalty,
                        frequencyPenalty: input.frequencyPenalty,
                        binding: input.binding,
                        blockTable: input.blockTable,
                        committedKVTokenCount: input.committedKVTokenCount + sampled.count,
                        targetKVTokenCount: input.targetKVTokenCount + sampled.count,
                        samplerStep: input.samplerStep + sampled.count
                    ))
                }
            }
            current = next
        }
        return rows.map { row in
            if failed.contains(row.requestID) {
                return .rowFailure(requestID: row.requestID)
            }
            let tokens = tokensByID[row.requestID] ?? []
            guard !tokens.isEmpty else {
                return .rowFailure(requestID: row.requestID)
            }
            return .output(ContinuousBatchDecodeOutput(requestID: row.requestID, tokens: tokens))
        }
    }

    func installRetainedPagedKVCache(
        requestID: String,
        handoff: PagedKVPagedCacheHandoff,
        binding: PagedKVStorageBinding
    ) async throws {
        throw ContinuousBatchSchedulerError.unsupported("continuous_batching_paged_kv_handoff_unavailable")
    }

    func commitTerminalKV(_ input: ContinuousBatchTerminalKVCommitInput) async throws {
        throw ContinuousBatchSchedulerError.unsupported("continuous_batching_terminal_kv_commit_unavailable")
    }

    func finish(requestID: String) {}
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
    /// Drops a claim taken for a request that never reached admission, so the
    /// same request ID can be re-sent. Only the pre-admission queue-wait
    /// expiry calls this: the request owns no slot, no result and no receipt,
    /// so releasing cannot permit a re-execution of work that already ran.
    /// Must be a no-op when the stored fingerprint no longer matches `key`,
    /// so a re-claim by a different body is never deleted. Best-effort: a
    /// release that fails leaves the claim standing, which is the safe side.
    func release(_ key: ContinuousBatchSchedulerReplayKey)
}

final class ContinuousBatchTokenDeliveryCapacity: @unchecked Sendable {
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

final class ContinuousBatchTokenDelivery: @unchecked Sendable {
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
    /// Test seam: runs after the drain loop sees an empty queue and before it
    /// decides whether to finish, the window an `offer()` can land in.
    var afterDrainSawEmptyQueueForTest: (@Sendable () -> Void)?

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
        while true {
            while let event = nextEvent(generation: generation) {
                await sink(event)
                if Task.isCancelled { break }
            }
            afterDrainSawEmptyQueueForTest?()
            // An `offer()` between the empty check above and this call saw
            // `draining == true`, appended, and started no drain of its own;
            // finishing here would strand that event and the terminal
            // `finish(afterDraining:)` would wait forever. `finishDrain`
            // re-checks the queue under the same lock that clears `draining`.
            if finishDrain(generation: generation, keepDrainingIfQueued: !Task.isCancelled) {
                return
            }
        }
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

    /// Returns `false` only when events were queued after the drain loop saw
    /// an empty queue; the caller keeps draining.
    private func finishDrain(generation: UUID, keepDrainingIfQueued: Bool) -> Bool {
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
            return true
        }
        if keepDrainingIfQueued, !timedOut, !queue.isEmpty {
            lock.unlock()
            return false
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
        return true
    }
}

enum ContinuousBatchSchedulerError: Error, Equatable {
    case unsupported(String)
    /// Pre-admission queue pressure: the request was refused before any
    /// inference ran, so nothing is on the wire and re-sending it once the
    /// queue drains is safe. Every throw site is in `submit()` / `enqueue()`
    /// and fires before the waiter's delivery has been offered a single
    /// event. Post-token delivery failure is `.deliveryBackpressure`, which
    /// is a different buyer-visible outcome — do not merge the two.
    case backpressure
    /// Post-token delivery backpressure: an *active decode row's* waiter
    /// would not accept a token event, so the row is torn down mid-stream.
    /// Inference ran and the buyer may already hold partial output, so this
    /// is `inferenceRan: true`, not retryable, and carries no `Retry-After`:
    /// telling the buyer to retry would invite a duplicate request for work
    /// that partly happened.
    case deliveryBackpressure
    /// Serve-path-unreachable today. `.drained` and `.drainTimedOut` are only
    /// thrown out of `ContinuousBatchScheduler.drain()`, whose sole caller in
    /// `Sources/` is `MSBThroughputCommand` — a benchmark harness, not the
    /// HTTP serve path. They are deliberately absent from `asAPIError()`:
    /// mapping them would ship buyer-visible code no request can reach. Wire
    /// `drain()` into the warm-swap path before adding a mapping here.
    case drained
    /// See `.drained`: harness-only, deliberately unmapped.
    case drainTimedOut
    case requestFailed(String)
    case duplicateRequestMismatch
    case idempotencyWindowExpired
    case idempotencyAuthorityUnavailable
    /// Admission wait exceeded `queueWaitTimeoutNanoseconds`. Distinct from
    /// `.backpressure`, which rejects at submit because the queue was already
    /// full; this request was queued and never reached a slot in time.
    case queueWaitTimedOut
}

extension ContinuousBatchSchedulerError {
    /// Buyer-visible code for post-token delivery backpressure, named once so
    /// the throw site, the terminal-result error code and the serve-path
    /// mapper cannot drift apart.
    static let deliveryBackpressureCode = "continuous_batching_stream_delivery_backpressure"

    /// SPEC-038 AC-25: the single scheduler-error → buyer-visible outcome map.
    /// Both the streaming and non-streaming serve paths call this so the two
    /// cannot drift. Returns `nil` only for the serve-unreachable cases
    /// (`.drained` / `.drainTimedOut`); the caller then rethrows unchanged.
    ///
    /// Every mapped case is a pre-admission or pre-inference rejection, so all
    /// of them are `inferenceRan: false, settlementRan: false` — non-settling,
    /// no receipt. The one exception is `.deliveryBackpressure`, which is
    /// raised against an already-decoding row: see its case below.
    func asAPIError() -> APIError? {
        switch self {
        case .backpressure:
            return APIError(
                status: 503,
                message: "Inference engine unavailable",
                type: "server_error",
                code: "continuous_batching_stream_backpressure",
                inferenceRan: false,
                settlementRan: false
            )
        case .deliveryBackpressure:
            // Not `continuous_batching_stream_backpressure`: that code is
            // marked retryable and carries a `Retry-After` bound, which is
            // correct for a pre-admission refusal and wrong here. This row
            // was decoding, tokens may already have reached the buyer, and a
            // retry would re-run work that partly happened. `retryable` is
            // pinned false at the call site so a later entry in
            // `APIError.retryableByCode` cannot silently flip it.
            return APIError(
                status: 503,
                message: "Inference engine unavailable",
                type: "server_error",
                code: Self.deliveryBackpressureCode,
                retryable: false,
                inferenceRan: true,
                settlementRan: false
            )
        case .queueWaitTimedOut:
            return APIError(
                status: 503,
                message: "Inference engine unavailable",
                type: "server_error",
                code: "continuous_batching_queue_wait_timeout",
                inferenceRan: false,
                settlementRan: false
            )
        case .duplicateRequestMismatch:
            return APIError(
                status: 409,
                message: "Request id was already used for a different request body",
                type: "invalid_request_error",
                code: "continuous_batching_duplicate_request_mismatch",
                inferenceRan: false,
                settlementRan: false
            )
        case .idempotencyWindowExpired:
            return APIError(
                status: 409,
                message: "Request id is outside the idempotency retention window",
                type: "invalid_request_error",
                code: "continuous_batching_idempotency_window_expired",
                inferenceRan: false,
                settlementRan: false
            )
        case .idempotencyAuthorityUnavailable:
            return APIError(
                status: 503,
                message: "Idempotency authority unavailable",
                type: "server_error",
                code: "continuous_batching_idempotency_authority_unavailable",
                inferenceRan: false,
                settlementRan: false
            )
        case .unsupported(let code), .requestFailed(let code):
            // Both cases already carry a well-formed API code string, so the
            // carried string IS the buyer-visible code; only the status has to
            // be decided. Every one of these that can escape `submit()` is
            // raised before the request is enqueued or before it reaches a
            // slot, so none of them can be thrown after inference ran — the
            // decode/prefill-structure `.requestFailed` codes never propagate
            // to a caller, the pump converts them into a terminal
            // `ContinuousBatchSchedulerResult` instead.
            let status = Self.carriedCodeStatus(code)
            return APIError(
                status: status,
                message: status == 400
                    ? "Continuous batching rejected the request before admission"
                    : "Continuous batching is unavailable for this request",
                type: status == 400 ? "invalid_request_error" : "server_error",
                code: code,
                inferenceRan: false,
                settlementRan: false
            )
        case .drained, .drainTimedOut:
            return nil
        }
    }

    /// Status for a code carried by `.unsupported` / `.requestFailed`.
    ///
    /// A code that `ContinuousBatchingUnsupportedReason` already publishes
    /// takes that reason's status, so the preflight surface and the runtime
    /// surface cannot disagree about the same string. The rest follow the same
    /// convention by shape: 400 when the rejection is a property of the
    /// request, 503 when it is a property of the provider's capability or
    /// availability. Unknown codes fail to 503 — an unrecognised scheduler
    /// rejection is a provider-side condition, not buyer error — but the
    /// fallback is a runtime safety net, not the classification: every code
    /// the scheduler can carry is listed in `carriedCodeStatuses`, and
    /// `ContinuousBatchSchedulerTests
    /// .testEveryCarriedSchedulerCodeIsClassified` fails on any new literal
    /// that is not, so a future serve-path code cannot silently inherit 503.
    static let carriedCodeStatuses: [String: Int] = [
        // 400 — a property of the request.
        ContinuousBatchingUnsupportedReason.stickyCacheHandoffUnavailable.apiCode: 400,
        // Mirrors `.tupleNotAdvertised` / `.moePromotionEvidenceUnavailable`,
        // which `localCapabilityReason` reports without the API prefix.
        "local_paged_kv_descriptor_mismatch": 400,
        "moe_promotion_evidence_unavailable": 400,
        "continuous_batching_cached_tokens_require_conversation_key": 400,
        "continuous_batching_invalid_cached_prompt_tokens": 400,
        "continuous_batching_invalid_request": 400,
        "continuous_batching_request_fingerprint_failed": 400,
        // 503 — a property of the provider's capability or availability.
        "continuous_batching_scheduler_failed_closed": 503,
        "continuous_batching_admission_sequence_exhausted": 503,
        "continuous_batching_local_binding_mismatch": 503,
        "continuous_batching_terminal_kv_commit_unavailable": 503,
        "continuous_batching_terminal_kv_commit_missing_token": 503,
        "continuous_batching_decode_row_mismatch": 503,
        "continuous_batching_duplicate_decode_row": 503,
        "continuous_batching_duplicate_prefill_row": 503,
        "continuous_batching_prefill_row_mismatch": 503,
        "continuous_batching_reservation_overflow": 503,
    ]

    private static func carriedCodeStatus(_ code: String) -> Int {
        carriedCodeStatuses[code] ?? 503
    }
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

        var retainedLogicalTokenCount: Int {
            request.promptTokens.count + generatedTokens.count
        }
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

    private struct DeliveredRetainedOwner {
        let retained: PagedKVRetainedSequence
        let conversationKey: String
    }

    private let configuration: ContinuousBatchSchedulerConfiguration
    private let schedulerID = UUID()
    private let allocator: PagedKVBlockAllocator
    private let backend: any ContinuousBatchSchedulerBackend
    private let replayAuthority: any ContinuousBatchSchedulerReplayAuthority
    private let contiguousCacheBridge: (any ContinuousBatchRetainedCacheBridge)?
    private let tokenDeliveryCapacity: ContinuousBatchTokenDeliveryCapacity

    private var waiting: [ContinuousBatchSchedulerRequest] = []
    /// Absolute uptime deadline per queued request, set once when the request
    /// enters `waiting` so a re-queued admission attempt keeps the original
    /// clock instead of restarting it.
    private var queueWaitDeadlines: [String: UInt64] = [:]
    private var queueWaitTimeoutTasks: [String: Task<Void, Never>] = [:]
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
    private var deliveredRetainedOwners: [UUID: DeliveredRetainedOwner] = [:]
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
        replayAuthority: any ContinuousBatchSchedulerReplayAuthority,
        contiguousCacheBridge: (any ContinuousBatchRetainedCacheBridge)? = nil
    ) {
        self.configuration = configuration
        self.tokenDeliveryCapacity = ContinuousBatchTokenDeliveryCapacity(
            limit: configuration.tokenDeliveryTaskLimit
        )
        self.allocator = allocator
        self.backend = backend
        self.replayAuthority = replayAuthority
        self.contiguousCacheBridge = contiguousCacheBridge
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
        do {
            try Task.checkCancellation()
        } catch {
            await discardUnacceptedRetainedCache(for: request)
            throw error
        }
        if cleanupFailedClosed {
            await discardUnacceptedRetainedCache(for: request)
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_scheduler_failed_closed")
        }
        if let reason = Self.localCapabilityReason(
            descriptor: configuration.descriptor,
            tuple: configuration.tuple,
            moePromotionEvidenceAvailable: configuration.moePromotionEvidenceAvailable
        ) {
            record(.localCapabilityMissing)
            await discardUnacceptedRetainedCache(for: request)
            throw ContinuousBatchSchedulerError.unsupported(reason)
        }
        if request.cachedPromptTokens > 0 && request.retainedPagedKVSequence == nil {
            record(.stickyCacheUnsupported)
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_paged_kv_handoff_unavailable")
        }
        let trimmedConversationKey = request.conversationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.cachedPromptTokens > 0 && trimmedConversationKey.isEmpty {
            record(.stickyCacheUnsupported)
            await discardUnacceptedRetainedCache(for: request)
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_cached_tokens_require_conversation_key")
        }
        if request.cachedPromptTokens > 0 && request.cachedPromptTokens >= request.promptTokens.count {
            record(.stickyCacheUnsupported)
            await discardUnacceptedRetainedCache(for: request)
            throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_invalid_cached_prompt_tokens")
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
            await discardUnacceptedRetainedCache(for: request)
            throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_invalid_request")
        }
        guard queueHasCapacity(addingTokenCost: retainedTokenCost) else {
            record(.backpressureRejected)
            await discardUnacceptedRetainedCache(for: request)
            throw ContinuousBatchSchedulerError.backpressure
        }
        guard nextAdmissionSequence < UInt64.max else {
            cleanupFailedClosed = true
            await discardUnacceptedRetainedCache(for: request)
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_admission_sequence_exhausted")
        }
        let admissionSequence = nextAdmissionSequence
        nextAdmissionSequence += 1
        pendingBindingChecks += 1
        pendingBindingTokenCount += retainedTokenCost
        CBTrace.log(request.id, "sch_submit seq=\(admissionSequence) cur=\(currentAdmissionSequence) active=\(activeDecode.count)")
        let bindingsAreValid = await localBindingsAreValid()
        CBTrace.log(request.id, "sch_bindings")
        await waitForAdmissionTurn(admissionSequence)
        CBTrace.log(request.id, "sch_turn")
        pendingBindingChecks -= 1
        pendingBindingTokenCount -= retainedTokenCost
        guard bindingsAreValid else {
            record(.localCapabilityMissing)
            finishAdmissionTurn(admissionSequence)
            await discardUnacceptedRetainedCache(for: request)
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_local_binding_mismatch")
        }
        do {
            try Task.checkCancellation()
        } catch {
            finishAdmissionTurn(admissionSequence)
            await discardUnacceptedRetainedCache(for: request)
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
                CBTrace.log(request.id, "sch_enqueued waiting=\(waiting.count) active=\(activeDecode.count)")
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
            await finishQueued(
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
            scheduleDiscardUnacceptedRetainedCache(for: request)
            continuation.resume(throwing: ContinuousBatchSchedulerError.requestFailed(
                "continuous_batching_request_fingerprint_failed"
            ))
            return
        }
        if Task.isCancelled {
            delivery.finish()
            scheduleDiscardUnacceptedRetainedCache(for: request)
            continuation.resume(throwing: CancellationError())
            return
        }
        if let known = knownRequests[request.id], known != requestFingerprint {
            delivery.finish()
            scheduleDiscardUnacceptedRetainedCache(for: request)
            continuation.resume(throwing: ContinuousBatchSchedulerError.duplicateRequestMismatch)
            return
        }
        if let terminal = terminalResults[request.id] {
            delivery.finish()
            scheduleDiscardUnacceptedRetainedCache(for: request)
            continuation.resume(returning: terminal.withSettlementDisposition(.nonSettlingReplay))
            return
        }
        if var pending = pendingTerminalDeliveries[request.id] {
            // Pre-admission for *this* caller: a duplicate that could not be
            // attached to the in-flight terminal delivery. Its own delivery
            // has never been offered an event, so nothing reached this buyer
            // and re-sending the same id is safe — it attaches or replays.
            guard pending.waiters.count < configuration.duplicateWaiterLimit else {
                record(.backpressureRejected)
                delivery.finish()
                scheduleDiscardUnacceptedRetainedCache(for: request)
                continuation.resume(throwing: ContinuousBatchSchedulerError.backpressure)
                return
            }
            scheduleDiscardUnacceptedRetainedCache(for: request)
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
                // Still pre-admission for this caller: `delivery` is the
                // new waiter's, freshly built in `submit()`, and this replay
                // is the first event ever offered to it. A refusal here means
                // the caller has seen nothing.
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
            scheduleDiscardUnacceptedRetainedCache(for: request)
            continuation.resume(throwing: ContinuousBatchSchedulerError.idempotencyWindowExpired)
            return
        }
        if draining {
            delivery.finish()
            scheduleDiscardUnacceptedRetainedCache(for: request)
            continuation.resume(throwing: ContinuousBatchSchedulerError.drained)
            return
        }
        if knownRequests[request.id] != nil {
            // Same shape as the `pendingTerminalDeliveries` guard above:
            // the duplicate never attached and never received an event.
            let deferredWaiterCount = deferredTerminalCompletions[request.id]?.waiters.count ?? 0
            guard requestWaiters[request.id, default: []].count + deferredWaiterCount
                    < configuration.duplicateWaiterLimit else {
                record(.backpressureRejected)
                delivery.finish()
                scheduleDiscardUnacceptedRetainedCache(for: request)
                continuation.resume(throwing: ContinuousBatchSchedulerError.backpressure)
                return
            }
            scheduleDiscardUnacceptedRetainedCache(for: request)
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
                // First offer to this waiter's own fresh delivery, as
                // above: the attach is rolled back and the caller has seen
                // no output, so this stays the pre-admission classification
                // even though the request it tried to join is decoding.
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
            scheduleDiscardUnacceptedRetainedCache(for: request)
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
                scheduleDiscardUnacceptedRetainedCache(for: request)
                continuation.resume(throwing: ContinuousBatchSchedulerError.idempotencyWindowExpired)
                return
            case .duplicateMismatchedRequest:
                delivery.finish()
                scheduleDiscardUnacceptedRetainedCache(for: request)
                continuation.resume(throwing: ContinuousBatchSchedulerError.duplicateRequestMismatch)
                return
            }
        } catch {
            delivery.finish()
            scheduleDiscardUnacceptedRetainedCache(for: request)
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
        beginQueueWait(requestID: request.id)
        ensurePump()
    }

    /// Starts the bounded admission clock for a request that just entered the
    /// waiting queue.
    private func beginQueueWait(requestID: String) {
        let timeout = configuration.queueWaitTimeoutNanoseconds
        guard timeout > 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let (candidate, overflow) = now.addingReportingOverflow(timeout)
        queueWaitDeadlines[requestID] = overflow ? UInt64.max : candidate
        armQueueWaitTimeout(requestID: requestID)
    }

    private func armQueueWaitTimeout(requestID: String) {
        guard let deadline = queueWaitDeadlines[requestID] else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = deadline > now ? deadline - now : 0
        queueWaitTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        queueWaitTimeoutTasks[requestID] = Task { [weak self] in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: remaining)
            }
            guard !Task.isCancelled else { return }
            await self?.expireQueueWait(requestID: requestID)
        }
    }

    /// Stops the timer while the request is out of `waiting` for an admission
    /// attempt. The deadline is retained so a re-queue resumes the same clock.
    private func suspendQueueWaitTimeout(requestID: String) {
        queueWaitTimeoutTasks.removeValue(forKey: requestID)?.cancel()
    }

    /// Test hook: cancels a queued request's timeout task but keeps its
    /// absolute deadline, reproducing "deadline passed, timer not yet run"
    /// deterministically. Production code never calls it.
    func cancelQueueWaitTimerForTest(requestID: String) {
        suspendQueueWaitTimeout(requestID: requestID)
    }

    private func endQueueWait(requestID: String) {
        queueWaitTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        queueWaitDeadlines.removeValue(forKey: requestID)
    }

    /// Bounded admission wait expiry. The request never reached a slot, so it
    /// owns no row, no block-table handle and no terminal result: the only
    /// state it leaves behind is the non-receipt diagnostic. It can never be
    /// settlement-eligible because no result is produced for it at all.
    ///
    /// Internal rather than private so a `@testable` test can drive the stale
    /// wake directly: it happens only when the timeout task reaches the actor
    /// in the same turn the pump pulls the request into admission, which
    /// cannot be forced from outside the actor.
    func expireQueueWait(requestID: String) async {
        // A timeout task can reach here after `suspendQueueWaitTimeout`
        // cancelled it: cancellation does not unschedule a task that already
        // woke. Do not touch `queueWaitDeadlines` until the request is
        // confirmed still queued and actually past its deadline. Clearing it
        // for a request that is mid-admission would strip the absolute
        // deadline, and a `capacityExceeded` bounce would then re-arm with no
        // deadline at all — the unbounded wait this bound exists to remove.
        guard let deadline = queueWaitDeadlines[requestID],
              DispatchTime.now().uptimeNanoseconds >= deadline,
              let index = waiting.firstIndex(where: { $0.id == requestID }) else { return }
        let request = waiting.remove(at: index)
        endQueueWait(requestID: requestID)
        record(.queueWaitTimedOut)
        // SPEC-038 AC-25: the durable replay claim was taken at submit, before
        // this request ever reached a slot. Nothing ran, nothing was cached,
        // nothing can settle, so the claim guards no execution — holding it
        // would answer a same-ID retry of a 503 this provider itself marked
        // `retryable: true` with a 409 instead, and churn a claim file for
        // work that never happened. Released before the waiters are resumed
        // so a retry cannot race ahead of the release.
        if let fingerprint = knownRequests[requestID] {
            replayAuthority.release(ContinuousBatchSchedulerReplayKey(
                requestID: requestID,
                fingerprintSHA256: fingerprint.sha256
            ))
        }
        knownRequests.removeValue(forKey: requestID)
        requestAdmissionSequences.removeValue(forKey: requestID)
        cancelledIDs.remove(requestID)
        let waiters = requestWaiters.removeValue(forKey: requestID) ?? []
        await discardUnacceptedRetainedCache(for: request)
        for waiter in waiters {
            waiter.delivery.finish()
            waiter.continuation.resume(throwing: ContinuousBatchSchedulerError.queueWaitTimedOut)
        }
    }

    private func cancelWaiter(requestID: String, waiterID: UUID) async {
        CBTrace.log(requestID, "sch_cancel_waiter")
        guard stoppingWaiterIDs.insert(waiterID).inserted else { return }
        if let delivered = deliveredRetainedOwners.removeValue(forKey: waiterID) {
            stoppingWaiterIDs.remove(waiterID)
            await discardRetainedCache(delivered.retained, conversationKey: delivered.conversationKey)
            return
        }
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

    private func finishStoppedWaiter(requestID: String, waiterID: UUID) async {
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
                    generatedTokens: [],
                    outputTokens: [],
                    promptTokens: pending.result.promptTokens,
                    completionTokens: 0,
                    emittedTokens: pending.result.emittedTokens,
                    cachedPromptTokens: pending.result.cachedPromptTokens,
                    terminalStatus: .requestFailed,
                    errorCode: "continuous_batching_stream_delivery_cancelled",
                    snapshot: pending.result.snapshot,
                    settlementDisposition: .notEligible,
                    retainedCache: nil
                )
                finalizeTerminalResult(requestID: requestID, result: failedResult, waiters: pending.waiters)
                if let retainedCache = pending.result.retainedCache {
                    await discardRetainedCache(
                        retainedCache.retainedSequence,
                        conversationKey: pending.result.conversationKey
                    )
                }
            } else if pending.remainingWaiterIDs.isEmpty {
                pendingTerminalDeliveries.removeValue(forKey: requestID)
                await finalizePendingTerminal(requestID: requestID, pending: pending)
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
                await finishQueued(request, status: .cancelled, errorCode: "request_cancelled")
                cancelledIDs.remove(request.id)
            } else {
                remaining.append(request)
            }
        }
        waiting = remaining
        cancelledIDs.subtract(terminalResults.keys)
    }

    /// One-token decode when a row is queued or still prefilling (FR-CB5 join
    /// at the next hop). Otherwise the compiled lockstep window, capped by the
    /// shortest remaining `maxOutputTokens` in the batch.
    private func lockstepDecodeWindowSteps(for rows: [Row]) -> Int {
        let joinPending = !waiting.isEmpty
            || pendingBindingChecks > 0
            || !admittingRequests.isEmpty
            || !activePrompt.isEmpty
        guard !joinPending else { return 1 }
        let configured = configuration.maxDecodeLockstepWindow
        guard configured > 1 else { return 1 }
        var window = configured
        var bounded = false
        for row in rows {
            let remaining = row.request.maxOutputTokens - row.generatedTokens.count
            guard remaining > 0 else { continue }
            window = min(window, remaining)
            bounded = true
        }
        return bounded ? max(1, window) : 1
    }

    private func runDecodeStep() async {
        let rows = activeDecode.values.sorted {
            admissionPrecedes($0.request.id, $1.request.id)
        }
        let windowSteps = lockstepDecodeWindowSteps(for: rows)
        var prepared: [(row: Row, input: ContinuousBatchDecodeInput)] = []
        prepared.reserveCapacity(rows.count)
        for row in rows {
            let committedKVTokenCount = row.request.promptTokens.count - 1 + row.generatedTokens.count
            let (targetKVTokenCount, targetOverflow) = committedKVTokenCount.addingReportingOverflow(windowSteps)
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
                _ = try await allocator.extend(row.handle, by: windowSteps)
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
                let binding = try await allocator.binding(for: row.handle)
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
                    binding: binding,
                    blockTable: binding.currentTable,
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
                ContinuousBatchingPolicy.logForwardFailed(error)
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
            outcomes = try await backend.decodeLockstepWindow(
                rows: prepared.map(\.input),
                steps: windowSteps
            )
            try validateDecodeOutputStructure(outcomes, expectedRequestIDs: prepared.map { $0.row.request.id })
        } catch {
            for item in prepared {
                _ = await endDecodeStep(item.row.handle)
            }
            if backendCancellationPending { return }
            record(.batchForwardFailed)
            ContinuousBatchingPolicy.logForwardFailed(error)
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
        for output in outputs {
            let sampled = output.tokens
            let invalid = sampled.isEmpty
                || sampled.contains { !(0..<configuration.vocabularySize).contains($0) }
            guard invalid else { continue }
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
        var maxSteps = 1
        for output in outputs {
            let count = output.tokens.isEmpty ? 1 : output.tokens.count
            maxSteps = max(maxSteps, count)
        }
        for step in 0..<maxSteps {
            for id in activeDecode.keys.sorted(by: admissionPrecedes) {
                guard let row = activeDecode[id], let output = byID[id] else { continue }
                let sampled = output.tokens
                guard step < sampled.count else { continue }
                await applyToken(sampled[step], to: row)
                if cleanupFailedClosed { return }
            }
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
        CBTrace.log(row.request.id, "sch_active")
        if !deliverVisibleTokens(
            visibleTokens,
            firstIndex: firstVisibleIndex,
            row: row
        ) {
            activeDecode.removeValue(forKey: row.request.id)
            let released = await release(row.handle)
            // Post-token, like the `.deliveryBackpressure` thrown at the
            // waiter above: this row was decoding when its last consumer
            // refused an event. The terminal result is replayable to a later
            // duplicate of the same request id, so it must not carry the
            // pre-admission code — that one is retryable and this is not.
            finish(
                row,
                status: .requestFailed,
                errorCode: released
                    ? ContinuousBatchSchedulerError.deliveryBackpressureCode
                    : "continuous_batching_cleanup_failed"
            )
            return
        }

        if let terminalStatus {
            activeDecode.removeValue(forKey: row.request.id)
            if let retainedCache = await retainTerminalCache(
                for: row,
                targetLogicalTokens: row.retainedLogicalTokenCount
            ) {
                finish(row, status: terminalStatus, errorCode: nil, retainedCache: retainedCache)
            } else {
                let released = await release(row.handle)
                finish(row, status: released ? terminalStatus : .requestFailed, errorCode: released
                    ? nil
                    : "continuous_batching_cleanup_failed")
            }
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
                        error: ContinuousBatchSchedulerError.deliveryBackpressure
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
            // SPEC-038 AC-25: a request already past its absolute admission
            // deadline (for example re-queued by a `capacityExceeded` bounce
            // after the deadline passed) expires here, synchronously. Its
            // zero-delay timeout task would otherwise race this pump, and the
            // pump could admit it after the bound it was promised.
            if let deadline = queueWaitDeadlines[waiting[0].id],
               DispatchTime.now().uptimeNanoseconds >= deadline {
                await expireQueueWait(requestID: waiting[0].id)
                madeProgress = true
                continue
            }
            let request = waiting.removeFirst()
            suspendQueueWaitTimeout(requestID: request.id)
            madeProgress = true
            if cancelledIDs.remove(request.id) != nil {
                await finishQueued(request, status: .cancelled, errorCode: "request_cancelled")
                continue
            }

            admittingRequests[request.id] = request
            var admissionHandle: PagedKVBlockTableHandle?
            do {
                let reservation = try initialReservation(for: request)
                let handle: PagedKVBlockTableHandle
                let prefillCursor: Int
                if let retained = request.retainedPagedKVSequence {
                    guard let contiguousCacheBridge else {
                        throw ContinuousBatchSchedulerError.unsupported(
                            "continuous_batching_paged_kv_handoff_unavailable"
                        )
                    }
                    handle = try await allocator.reattach(
                        retained,
                        conversationKey: request.conversationKey,
                        trimToLogicalTokens: request.cachedPromptTokens,
                        maxLogicalTokens: reservation.maxLogicalTokens
                    )
                    admissionHandle = handle
                    let binding = try await allocator.binding(for: handle)
                    let handoff = try contiguousCacheBridge.reattachPagedKVCache(
                        handle: handle,
                        table: binding.currentTable
                    )
                    try await backend.installRetainedPagedKVCache(
                        requestID: request.id,
                        handoff: handoff,
                        binding: binding
                    )
                    prefillCursor = request.cachedPromptTokens
                } else {
                    handle = try await allocator.allocate(
                        conversationKey: schedulerConversationKey(for: request),
                        initialCapacityTokens: reservation.initialCapacityTokens,
                        maxLogicalTokens: reservation.maxLogicalTokens,
                        initialTokens: 0
                    )
                    admissionHandle = handle
                    prefillCursor = 0
                }
                admittingRequests.removeValue(forKey: request.id)
                if draining {
                    let released = await release(handle)
                    await finishQueued(
                        request,
                        status: released ? .rejected : .requestFailed,
                        errorCode: released ? "continuous_batching_draining" : "continuous_batching_cleanup_failed"
                    )
                    if !released { return madeProgress }
                    continue
                } else if cancelledIDs.remove(request.id) != nil {
                    let released = await release(handle)
                    await finishQueued(
                        request,
                        status: released ? .cancelled : .requestFailed,
                        errorCode: released ? "request_cancelled" : "continuous_batching_cleanup_failed"
                    )
                    if !released { return madeProgress }
                    continue
                }
                record(.promptHeadroomReserved)
                record(.accepted)
                try? FileHandle.standardError.write(contentsOf: Data("event=batching_admitted action=scheduler_admitted\n".utf8))
                activePrompt[request.id] = Row(
                    request: request,
                    handle: handle,
                    currentToken: request.promptTokens.last ?? 0,
                    generatedTokens: [],
                    outputTokens: [],
                    pendingOutputTokens: [],
                    prefillCursor: prefillCursor,
                    snapshot: configuration.snapshot
                )
                promptOrder.append(request.id)
                endQueueWait(requestID: request.id)
            } catch PagedKVAllocatorError.capacityExceeded {
                admittingRequests.removeValue(forKey: request.id)
                if draining {
                    await finishQueued(request, status: .rejected, errorCode: "continuous_batching_draining")
                } else if activeDecode.isEmpty && activePrompt.isEmpty && admittingRequests.isEmpty {
                    record(.poolCapacityRejected)
                    await finishQueued(
                        request,
                        status: .rejected,
                        errorCode: "continuous_batching_pool_capacity_exhausted"
                    )
                } else {
                    waiting.insert(request, at: 0)
                    armQueueWaitTimeout(requestID: request.id)
                    return madeProgress
                }
            } catch PagedKVAllocatorError.conversationMismatch {
                admittingRequests.removeValue(forKey: request.id)
                if let admissionHandle {
                    let released = await release(admissionHandle)
                    if !released { return madeProgress }
                } else if let retained = request.retainedPagedKVSequence {
                    await discardRetainedCache(retained)
                }
                await finishQueued(request, status: .requestFailed, errorCode: "continuous_batching_admission_failed")
            } catch {
                admittingRequests.removeValue(forKey: request.id)
                if let admissionHandle {
                    let released = await release(admissionHandle)
                    if !released { return madeProgress }
                } else {
                    await discardUnacceptedRetainedCache(for: request)
                }
                await finishQueued(request, status: .requestFailed, errorCode: "continuous_batching_admission_failed")
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
                ContinuousBatchingPolicy.logPrefillFailed(error)
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
                ContinuousBatchingPolicy.logPrefillFailed(error)
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
            ContinuousBatchingPolicy.logPrefillFailed(error)
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
            if let retainedCache = await retainTerminalCache(
                for: row,
                targetLogicalTokens: row.retainedLogicalTokenCount
            ) {
                finish(row, status: .length, errorCode: nil, retainedCache: retainedCache)
            } else {
                let released = await release(row.handle)
                finish(row, status: released ? .length : .requestFailed, errorCode: released
                    ? nil
                    : "continuous_batching_cleanup_failed")
            }
        } else {
            activeDecode[row.request.id] = row
            CBTrace.log(row.request.id, "sch_active")
            record(.joinedDecode)
        }
    }

    private func failRemainingAfterCleanupFailure() async {
        while !waiting.isEmpty {
            await finishQueued(
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
    ) async {
        await discardUnacceptedRetainedCache(for: request)
        let result = ContinuousBatchSchedulerResult(
            requestID: request.id,
            conversationKey: request.conversationKey,
            generatedTokens: [],
            outputTokens: [],
            promptTokens: 0,
            completionTokens: 0,
            emittedTokens: 0,
            cachedPromptTokens: 0,
            terminalStatus: status,
            errorCode: errorCode,
            snapshot: nil,
            settlementDisposition: .notEligible,
            retainedCache: nil
        )
        complete(requestID: request.id, result: result)
    }

    private func discardUnacceptedRetainedCache(for request: ContinuousBatchSchedulerRequest) async {
        guard let retained = request.retainedPagedKVSequence else { return }
        await discardRetainedCache(retained)
    }

    private func scheduleDiscardUnacceptedRetainedCache(for request: ContinuousBatchSchedulerRequest) {
        guard let retained = request.retainedPagedKVSequence else { return }
        Task { await self.discardRetainedCache(retained) }
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
            generatedTokens: isSuccessful ? row.generatedTokens : [],
            outputTokens: outputTokens,
            promptTokens: row.request.promptTokens.count,
            completionTokens: isSuccessful ? row.generatedTokens.count : 0,
            emittedTokens: row.outputTokens.count,
            cachedPromptTokens: row.request.cachedPromptTokens,
            terminalStatus: status,
            errorCode: errorCode,
            snapshot: row.snapshot,
            settlementDisposition: isSuccessful ? .eligibleOwner : .notEligible,
            retainedCache: nil
        )
        complete(requestID: row.request.id, result: result)
    }

    private func finish(
        _ row: Row,
        status: ContinuousBatchSchedulerTerminalStatus,
        errorCode: String?,
        retainedCache: ContinuousBatchRetainedCache?
    ) {
        record(status == .cancelled ? .cancelled : .stopped)
        let isSuccessful = status == .stop || status == .length
        let outputTokens = isSuccessful ? row.outputTokens : []
        let result = ContinuousBatchSchedulerResult(
            requestID: row.request.id,
            conversationKey: row.request.conversationKey,
            generatedTokens: isSuccessful ? row.generatedTokens : [],
            outputTokens: outputTokens,
            promptTokens: row.request.promptTokens.count,
            completionTokens: isSuccessful ? row.generatedTokens.count : 0,
            emittedTokens: row.outputTokens.count,
            cachedPromptTokens: row.request.cachedPromptTokens,
            terminalStatus: status,
            errorCode: errorCode,
            snapshot: row.snapshot,
            settlementDisposition: isSuccessful ? .eligibleOwner : .notEligible,
            retainedCache: isSuccessful ? retainedCache : nil
        )
        complete(requestID: row.request.id, result: result)
    }

    private func complete(requestID: String, result: ContinuousBatchSchedulerResult) {
        CBTrace.log(requestID, "sch_complete status=\(result.terminalStatus) waiters=\(requestWaiters[requestID]?.count ?? 0) stopping=\(stoppingActiveWaiters.values.contains(where: { $0.requestID == requestID }))")
        endQueueWait(requestID: requestID)
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
            if let retainedCache = result.retainedCache {
                Task {
                    await self.discardRetainedCache(
                        retainedCache.retainedSequence,
                        conversationKey: result.conversationKey
                    )
                }
            }
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

    private func finishTerminalDelivery(requestID: String, waiterID: UUID, delivered: Bool) async {
        guard !stoppingWaiterIDs.contains(waiterID) else {
            CBTrace.log(requestID, "sch_ftd_skip_stopping")
            return
        }
        guard var pending = pendingTerminalDeliveries[requestID],
              pending.remainingWaiterIDs.remove(waiterID) != nil else {
            CBTrace.log(requestID, "sch_ftd_skip_no_pending")
            return
        }
        CBTrace.log(requestID, "sch_ftd delivered=\(delivered) remaining=\(pending.remainingWaiterIDs.count)")
        pending.deliveryOutcomes[waiterID] = delivered
        guard pending.remainingWaiterIDs.isEmpty else {
            pendingTerminalDeliveries[requestID] = pending
            return
        }
        pendingTerminalDeliveries.removeValue(forKey: requestID)
        await finalizePendingTerminal(requestID: requestID, pending: pending)
    }

    private func finalizePendingTerminal(requestID: String, pending: PendingTerminalDelivery) async {
        let result: ContinuousBatchSchedulerResult
        if pending.deliveryOutcomes.values.contains(true) {
            result = pending.result
        } else {
            result = ContinuousBatchSchedulerResult(
                requestID: pending.result.requestID,
                conversationKey: pending.result.conversationKey,
                generatedTokens: [],
                outputTokens: [],
                promptTokens: pending.result.promptTokens,
                completionTokens: 0,
                emittedTokens: pending.result.emittedTokens,
                cachedPromptTokens: pending.result.cachedPromptTokens,
                terminalStatus: .requestFailed,
                errorCode: "continuous_batching_stream_delivery_timed_out",
                snapshot: pending.result.snapshot,
                settlementDisposition: .notEligible,
                retainedCache: nil
            )
        }
        finalizeTerminalResult(
            requestID: requestID,
            result: result,
            waiters: pending.waiters,
            deliveryOutcomes: pending.deliveryOutcomes
        )
        if !pending.deliveryOutcomes.values.contains(true),
           let retainedCache = pending.result.retainedCache {
            await discardRetainedCache(
                retainedCache.retainedSequence,
                conversationKey: pending.result.conversationKey
            )
        }
    }

    private func finalizeTerminalResult(
        requestID: String,
        result: ContinuousBatchSchedulerResult,
        waiters: [Waiter],
        deliveryOutcomes: [UUID: Bool]? = nil
    ) {
        backend.finish(requestID: requestID)
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
                    generatedTokens: [],
                    outputTokens: [],
                    promptTokens: result.promptTokens,
                    completionTokens: 0,
                    emittedTokens: result.emittedTokens,
                    cachedPromptTokens: result.cachedPromptTokens,
                    terminalStatus: .requestFailed,
                    errorCode: "continuous_batching_stream_delivery_timed_out",
                    snapshot: result.snapshot,
                    settlementDisposition: .notEligible,
                    retainedCache: nil
                ))
            } else {
                let disposition: ContinuousBatchSettlementDisposition = waiter.id == settlementOwnerID
                    ? .eligibleOwner
                    : (result.settlementDisposition == .eligibleOwner ? .nonSettlingReplay : .notEligible)
                var waiterResult = result.withSettlementDisposition(disposition)
                if disposition == .eligibleOwner, let retainedCache = waiterResult.retainedCache {
                    deliveredRetainedOwners[waiter.id] = DeliveredRetainedOwner(
                        retained: retainedCache.retainedSequence,
                        conversationKey: result.conversationKey
                    )
                    waiterResult = waiterResult.withRetainedCache(retainedCache.withDeliveryID(waiter.id))
                }
                waiter.continuation.resume(returning: waiterResult)
            }
            CBTrace.log(requestID, "sch_resumed")
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

    private func schedulerConversationKey(for request: ContinuousBatchSchedulerRequest) -> String {
        let trimmed = request.conversationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "continuous-batching:\(request.id)" : trimmed
    }

    private func retainTerminalCache(for row: Row, targetLogicalTokens: Int) async -> ContinuousBatchRetainedCache? {
        let trimmedKey = row.request.conversationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, let contiguousCacheBridge else { return nil }
        var retainedSequence: PagedKVRetainedSequence?
        do {
            let binding = try await allocator.binding(for: row.handle)
            if targetLogicalTokens > binding.currentTable.logicalTokenCount {
                _ = try await allocator.extend(
                    row.handle,
                    by: targetLogicalTokens - binding.currentTable.logicalTokenCount
                )
                let targetBinding = try await allocator.binding(for: row.handle)
                guard let terminalToken = row.generatedTokens.last else {
                    throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_terminal_kv_commit_missing_token")
                }
                try await backend.commitTerminalKV(ContinuousBatchTerminalKVCommitInput(
                    requestID: row.request.id,
                    currentToken: terminalToken,
                    binding: targetBinding,
                    blockTable: targetBinding.currentTable,
                    committedKVTokenCount: binding.currentTable.logicalTokenCount,
                    targetKVTokenCount: targetLogicalTokens
                ))
            } else if targetLogicalTokens < binding.currentTable.logicalTokenCount {
                _ = try await allocator.trim(row.handle, toLogicalTokens: targetLogicalTokens)
            }
            let retained = try await allocator.retain(row.handle)
            retainedSequence = retained
            let retainedBinding = try await allocator.binding(for: retained.handle)
            let handoff = try contiguousCacheBridge.reattachPagedKVCache(
                handle: retained.handle,
                table: retainedBinding.currentTable
            )
            return ContinuousBatchRetainedCache(
                retainedSequence: retained,
                layers: handoff.caches
            )
        } catch {
            if let retainedSequence {
                do {
                    _ = try await allocator.reattach(retainedSequence, conversationKey: trimmedKey)
                } catch {
                    cleanupFailedClosed = true
                    record(.cleanupFailed)
                }
            }
            return nil
        }
    }

    func discardRetainedCache(_ retained: PagedKVRetainedSequence, conversationKey: String) async {
        do {
            try await allocator.discardRetained(retained, conversationKey: conversationKey)
        } catch PagedKVAllocatorError.unknownHandle {
            return
        } catch {
            cleanupFailedClosed = true
            record(.cleanupFailed)
        }
    }

    func discardRetainedCache(_ retained: PagedKVRetainedSequence) async {
        do {
            try await allocator.discardRetained(retained)
        } catch PagedKVAllocatorError.unknownHandle {
            return
        } catch {
            cleanupFailedClosed = true
            record(.cleanupFailed)
        }
    }

    func acknowledgeRetainedCacheDelivery(_ retainedCache: ContinuousBatchRetainedCache) {
        guard let deliveryID = retainedCache.deliveryID else { return }
        deliveredRetainedOwners.removeValue(forKey: deliveryID)
    }

    func cancelRetainedCacheDelivery(
        _ retainedCache: ContinuousBatchRetainedCache,
        conversationKey: String
    ) async {
        guard let deliveryID = retainedCache.deliveryID else {
            await discardRetainedCache(retainedCache.retainedSequence, conversationKey: conversationKey)
            return
        }
        guard let delivered = deliveredRetainedOwners.removeValue(forKey: deliveryID) else { return }
        await discardRetainedCache(delivered.retained, conversationKey: delivered.conversationKey)
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
