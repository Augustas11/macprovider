import Foundation
import CryptoKit
import MLXLMCommon
import MacProviderCore
#if canImport(Darwin)
import Darwin
#endif

struct NativeMTPRoundSystemMemorySample: Sendable, Equatable {
    let availableBytes: Int
    let physicalBytes: Int
}

struct NativeMTPRoundSystemMemoryProbe: Sendable, Equatable {
    let identity: String
    private let sampleProvider: @Sendable () -> NativeMTPRoundSystemMemorySample?

    init(
        identity: String = "system",
        sampleProvider: @escaping @Sendable () -> NativeMTPRoundSystemMemorySample?
    ) {
        self.identity = identity
        self.sampleProvider = sampleProvider
    }

    func sample() -> NativeMTPRoundSystemMemorySample? {
        sampleProvider()
    }

    static let system = NativeMTPRoundSystemMemoryProbe {
        Self.systemSample()
    }

    static func == (lhs: NativeMTPRoundSystemMemoryProbe, rhs: NativeMTPRoundSystemMemoryProbe) -> Bool {
        lhs.identity == rhs.identity
    }

    private static func systemSample() -> NativeMTPRoundSystemMemorySample? {
#if canImport(Darwin)
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return nil
        }
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            return nil
        }
        let pages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.purgeable_count)
        let pageBytes = UInt64(pageSize)
        let (available, availableOverflow) = pages.multipliedReportingOverflow(by: pageBytes)
        guard !availableOverflow, available <= UInt64(Int.max) else {
            return nil
        }
        let physical = min(ProcessInfo.processInfo.physicalMemory, UInt64(Int.max))
        return NativeMTPRoundSystemMemorySample(
            availableBytes: Int(available),
            physicalBytes: Int(physical)
        )
#else
        return nil
#endif
    }
}

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
    let maxPrefillTokensPerIteration: Int
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
    /// Decode tokens per hop while a prompt is mid-prefill and nothing else is
    /// waiting to join. `1` is strict one-token-per-prefill-chunk alternation,
    /// which starves active rows behind a long prompt: one 512-token chunk
    /// costs about as much as 30-50 decode steps. Production uses
    /// `defaultDecodeStepsWhilePrefilling` (SPEC-038 FR-CB2).
    let maxDecodeStepsWhilePrefilling: Int
    /// Signed admission/static bound for all in-flight native-MTP complete
    /// windows. This is a contract ceiling, not proof that the host currently
    /// has the unified-memory headroom; `nativeMTPRoundSystemMemoryProbe`
    /// supplies that independent live gate before every proposal.
    let nativeMTPRoundByteCapacity: Int
    let nativeMTPRoundSystemMemoryProbe: NativeMTPRoundSystemMemoryProbe
    let nativeMTPStatusSink: NativeMTPStatusSink?

    init(
        descriptor: PagedKVDescriptor,
        tuple: ContinuousBatchingRequestedTuple,
        moePromotionEvidenceAvailable: Bool = false,
        maxActiveRows: Int,
        queueLimit: Int? = nil,
        decodeHeadroomTokens: Int,
        maxPrefillRowsPerIteration: Int = 1,
        maxPrefillTokensPerIteration: Int? = nil,
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
        maxDecodeLockstepWindow: Int = 1,
        maxDecodeStepsWhilePrefilling: Int = 1,
        nativeMTPRoundByteCapacity: Int? = nil,
        nativeMTPRoundSystemMemoryProbe: NativeMTPRoundSystemMemoryProbe = .system,
        nativeMTPStatusSink: NativeMTPStatusSink? = nil
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
        self.maxPrefillTokensPerIteration = max(
            1,
            maxPrefillTokensPerIteration ?? self.maxPromptChunkTokens
        )
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
        self.maxDecodeStepsWhilePrefilling = max(1, maxDecodeStepsWhilePrefilling)
        self.nativeMTPRoundByteCapacity = max(
            0,
            nativeMTPRoundByteCapacity ?? Int.max
        )
        self.nativeMTPRoundSystemMemoryProbe = nativeMTPRoundSystemMemoryProbe
        self.nativeMTPStatusSink = nativeMTPStatusSink
    }

    /// Production serve-path lockstep burst. Join/leave still happens between
    /// hops (FR-CB5); a queued row forces the scheduler back to one token.
    static let defaultDecodeLockstepWindow = 16

    /// Production decode tokens per hop while a prompt prefills. On the M3
    /// Ultra a 512-token Qwen3.6 chunk is about 1.7 s and a 4-row decode step
    /// about 60 ms, so 8 steps give active rows about 4 tok/s instead of about
    /// 0.6 behind a long prompt, for about 25% slower prefill.
    static let defaultDecodeStepsWhilePrefilling = 8
    static let defaultDecodeHeadroomTokens = 128
    static let defaultPrefillRowsPerIteration = 4
    // Prefill per-iteration token budget when the operator sets no
    // `continuous_batch_prefill_tokens_per_iteration` (SPEC-038). Kept at 1024:
    // a Studio benchmark (1024 vs 2048 vs 8192) found this budget NON-BINDING at
    // 1.5k-8k prompts — single-stream large-prompt TTFT is compute-bound (~300
    // tok/s prefill) and the per-row chunk (`prefill_step_size`) governs per-row
    // prefill, so the total budget does not move TTFT or concurrent-8k
    // admission. The key is exposed for operator tuning/observability (it may
    // bind under many concurrent small prefills), not as a TTFT lever.
    // Operator-tunable up to `maximumPrefillTokensPerIteration`.
    static let defaultPrefillTokensPerIteration = 1_024
    // Upper bound for `continuous_batch_prefill_tokens_per_iteration`. Serve
    // startup rejects a larger value rather than letting one prefill iteration
    // monopolize the backend hop.
    static let maximumPrefillTokensPerIteration = 65_536
    static let defaultPromptChunkTokens = 512

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
    let modelStopTokenIDs: [Int]
    let samplerSeed: Int
    let temperature: Double
    let topP: Double
    let presencePenalty: Double
    let frequencyPenalty: Double
    let cachedPromptTokens: Int
    let retainedPagedKVSequence: PagedKVRetainedSequence?
    /// Prompt positions (`ConversationCache.recurrentCheckpointPositions`) at which
    /// a keyed hybrid row snapshots its recurrent state during prefill. A
    /// reply-end checkpoint is added at terminal when cache is retained or
    /// materialized. Derived
    /// from `promptTokens`, so it stays out of the idempotency fingerprint.
    let recurrentCheckpointPositions: [Int]
    /// Runtime-only model cache shape. Hybrid recurrent rows need a terminal
    /// reply-end checkpoint even when no prompt checkpoint was eligible.
    /// Excluded from the idempotency fingerprint like the checkpoint positions.
    let modelHasRecurrentLayers: Bool
    /// SPEC-038 AC-26 hybrid cached turn: the retained entry's recurrent
    /// checkpoints at or below `cachedPromptTokens`. The one at exactly
    /// `cachedPromptTokens` is installed with the retained paged KV; any others
    /// that sit on this prompt's checkpoint positions carry forward into the
    /// row's own checkpoints. Empty for every non-hybrid request.
    let retainedRecurrentCheckpoints: [RecurrentStateCheckpoint]
    /// Runtime-only row observer. It is deliberately excluded from the
    /// idempotency fingerprint: duplicate waiters reuse the canonical row's
    /// observer and receive its boundary in the retained result.
    let serialToolStopObserver: ContinuousBatchCanonicalStopObserver?
    /// Runtime-only decode path selected before scheduler admission. Ordinary
    /// remains the default; native MTP rows stay distinguishable even when a
    /// directive forces their proposal depth to zero.
    let decodePath: DecodePath
    let nativeMTPMaximumProposalDepth: Int
    /// Runtime-only signed/loaded complete-window byte ceiling for native MTP,
    /// indexed by proposal depth `0...nativeMTPMaximumProposalDepth`. Excluded
    /// from the idempotency fingerprint like other runtime-only native-MTP
    /// selection metadata.
    let nativeMTPCompleteWindowBytesByDepth: [Int]
    let nativeMTPTupleFence: NativeMTPTupleFence?
    let nativeMTPIntegrityProbe: Bool
    /// Test-only/request-fixture proposal source. Production native MTP rows
    /// ask the backend drafter for proposals; empty native rows still use
    /// packed target verification at depth zero.
    let nativeMTPProposalTokens: [Int]
    let nativeMTPAdaptationDirective: NativeMTPAdaptationDirective?

    init(
        id: String,
        conversationKey: String,
        promptTokens: [Int],
        maxOutputTokens: Int,
        stopTokenSequences: [[Int]] = [],
        modelStopTokenIDs: [Int] = [],
        samplerSeed: Int = 0,
        temperature: Double = 1.0,
        topP: Double = 1.0,
        presencePenalty: Double = 0.0,
        frequencyPenalty: Double = 0.0,
        cachedPromptTokens: Int = 0,
        retainedPagedKVSequence: PagedKVRetainedSequence? = nil,
        recurrentCheckpointPositions: [Int] = [],
        modelHasRecurrentLayers: Bool = false,
        retainedRecurrentCheckpoints: [RecurrentStateCheckpoint] = [],
        serialToolStopObserver: ContinuousBatchCanonicalStopObserver? = nil,
        decodePath: DecodePath = .ordinary,
        nativeMTPMaximumProposalDepth: Int = 0,
        nativeMTPCompleteWindowBytesByDepth: [Int] = [],
        nativeMTPTupleFence: NativeMTPTupleFence? = nil,
        nativeMTPIntegrityProbe: Bool = false,
        nativeMTPProposalTokens: [Int] = [],
        nativeMTPAdaptationDirective: NativeMTPAdaptationDirective? = nil
    ) {
        self.id = id
        self.conversationKey = conversationKey
        self.promptTokens = promptTokens
        self.maxOutputTokens = max(0, maxOutputTokens)
        self.stopTokenSequences = stopTokenSequences
        self.modelStopTokenIDs = modelStopTokenIDs
        self.samplerSeed = samplerSeed
        self.temperature = temperature
        self.topP = topP
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.cachedPromptTokens = max(0, cachedPromptTokens)
        self.retainedPagedKVSequence = retainedPagedKVSequence
        self.recurrentCheckpointPositions = recurrentCheckpointPositions
        self.modelHasRecurrentLayers = modelHasRecurrentLayers
        self.retainedRecurrentCheckpoints = retainedRecurrentCheckpoints
        self.serialToolStopObserver = serialToolStopObserver
        self.decodePath = decodePath
        self.nativeMTPMaximumProposalDepth = max(0, nativeMTPMaximumProposalDepth)
        self.nativeMTPCompleteWindowBytesByDepth = nativeMTPCompleteWindowBytesByDepth
        self.nativeMTPTupleFence = decodePath == .nativeMTP ? nativeMTPTupleFence : nil
        self.nativeMTPIntegrityProbe = decodePath == .nativeMTP && nativeMTPIntegrityProbe
        self.nativeMTPProposalTokens = nativeMTPProposalTokens
        self.nativeMTPAdaptationDirective = nativeMTPAdaptationDirective
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationKey
        case promptTokens
        case maxOutputTokens
        case stopTokenSequences
        case modelStopTokenIDs
        case samplerSeed
        case temperature
        case topP
        case presencePenalty
        case frequencyPenalty
        case cachedPromptTokens
    }
}

enum ContinuousBatchSchedulerStopCause: String, Sendable, Equatable {
    case modelStop = "model_stop"
    case requestStop = "request_stop"
}

/// Thread-safe runtime-only observer owned by the canonical scheduler row.
/// Its handler consumes one newly visible token at a time and therefore never
/// replays a generated prefix. Equality intentionally ignores identity/state
/// because the observer is not part of request semantics or dedupe identity.
final class ContinuousBatchCanonicalStopObserver: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private let handler: @Sendable (Int) -> Bool
    private var observedTokenCount = 0
    private var stopTokenCountValue: Int?

    init(handler: @escaping @Sendable (Int) -> Bool) {
        self.handler = handler
    }

    func observe(_ tokens: [Int]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stopTokenCountValue == nil else { return false }
        for token in tokens {
            observedTokenCount += 1
            if handler(token) {
                stopTokenCountValue = observedTokenCount
                return true
            }
        }
        return false
    }

    var stopTokenCount: Int? {
        lock.lock()
        defer { lock.unlock() }
        return stopTokenCountValue
    }

    static func == (
        lhs: ContinuousBatchCanonicalStopObserver,
        rhs: ContinuousBatchCanonicalStopObserver
    ) -> Bool {
        true
    }
}

enum ContinuousBatchSettlementDisposition: String, Sendable, Equatable {
    case eligibleOwner = "eligible_owner"
    case nonSettlingReplay = "non_settling_replay"
    case notEligible = "not_eligible"
    /// A loopback completion whose upstream did not report complete usage
    /// (`prompt_tokens` and `completion_tokens`). Its counts are not the
    /// upstream's, so it never signs a settlement receipt, even under a
    /// pool runtime authorization (SPEC-015 §N.12, SPEC-022 R-12).
    case usageUnattested = "usage_unattested"
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
    /// The explicit generation stop recognized by the scheduler before it
    /// removes the matched sequence from buyer-visible output.
    var stopCause: ContinuousBatchSchedulerStopCause? = nil
    /// Canonical serial-tool boundary computed once by the scheduler row.
    var serialToolStopTokenCount: Int? = nil
    /// Keyed hybrid rows only: the row's cache in the serial conversation-cache
    /// format, delivered to the settlement owner like `retainedCache`.
    var serialConversationCache: ContinuousBatchSerialConversationCache? = nil
    var nativeMTPCounters: NativeMTPSelfTestCounters? = nil

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
            retainedCache: disposition == .eligibleOwner ? retainedCache : nil,
            stopCause: stopCause,
            serialToolStopTokenCount: serialToolStopTokenCount,
            serialConversationCache: disposition == .eligibleOwner ? serialConversationCache : nil,
            nativeMTPCounters: nativeMTPCounters
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
            retainedCache: cache,
            stopCause: stopCause,
            serialToolStopTokenCount: serialToolStopTokenCount,
            serialConversationCache: serialConversationCache,
            nativeMTPCounters: nativeMTPCounters
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
            && lhs.stopCause == rhs.stopCause
            && lhs.serialToolStopTokenCount == rhs.serialToolStopTokenCount
            && lhs.nativeMTPCounters == rhs.nativeMTPCounters
            && lhs.retainedCache?.retainedSequence == rhs.retainedCache?.retainedSequence
    }
}

final class ContinuousBatchRetainedCache: @unchecked Sendable {
    let retainedSequence: PagedKVRetainedSequence
    let layers: [KVCache]
    let deliveryID: UUID?
    /// Keyed hybrid rows: recurrent state at each checkpoint the row reached, so
    /// the next cached turn can resume from one (SPEC-038 AC-26). Empty otherwise.
    let recurrentCheckpoints: [RecurrentStateCheckpoint]

    init(
        retainedSequence: PagedKVRetainedSequence,
        layers: [KVCache],
        deliveryID: UUID? = nil,
        recurrentCheckpoints: [RecurrentStateCheckpoint] = []
    ) {
        self.retainedSequence = retainedSequence
        self.layers = layers
        self.deliveryID = deliveryID
        self.recurrentCheckpoints = recurrentCheckpoints
    }

    func withDeliveryID(_ deliveryID: UUID?) -> ContinuousBatchRetainedCache {
        ContinuousBatchRetainedCache(
            retainedSequence: retainedSequence,
            layers: layers,
            deliveryID: deliveryID,
            recurrentCheckpoints: recurrentCheckpoints
        )
    }
}

/// SPEC-038 FR-CB4: a keyed hybrid row's cache in the serial conversation-cache
/// format. Attention layers are contiguous `KVCacheSimple` covering the first
/// `tokenCount` canonical tokens; recurrent layers are empty `MambaCache`s,
/// because reuse always restores one of `recurrentCheckpoints` (SPEC-024 FR-CI2).
final class ContinuousBatchSerialConversationCache: @unchecked Sendable {
    let layers: [KVCache]
    let recurrentCheckpoints: [RecurrentStateCheckpoint]
    let tokenCount: Int

    init(layers: [KVCache], recurrentCheckpoints: [RecurrentStateCheckpoint], tokenCount: Int) {
        self.layers = layers
        self.recurrentCheckpoints = recurrentCheckpoints
        self.tokenCount = tokenCount
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
    let sampleFirstToken: Bool
    let samplerSeed: Int
    let temperature: Double
    let topP: Double
    let samplerStep: Int
    /// Native MTP drafters such as Qwen require target hidden states for the
    /// complete prompt. This flag is set only for bounded full-prompt final
    /// chunks; the backend must not replay a larger prompt to synthesize it.
    let nativeMTPPromptPrefill: Bool

    init(
        requestID: String,
        promptTokens: [Int],
        binding: PagedKVStorageBinding,
        promptTokenOffset: Int,
        committedKVTokenCount: Int,
        targetKVTokenCount: Int,
        isFinalChunk: Bool,
        sampleFirstToken: Bool? = nil,
        samplerSeed: Int = 0,
        temperature: Double = 0,
        topP: Double = 1,
        samplerStep: Int = 0,
        nativeMTPPromptPrefill: Bool = false
    ) {
        self.requestID = requestID
        self.promptTokens = promptTokens
        self.binding = binding
        self.promptTokenOffset = promptTokenOffset
        self.committedKVTokenCount = committedKVTokenCount
        self.targetKVTokenCount = targetKVTokenCount
        self.isFinalChunk = isFinalChunk
        self.sampleFirstToken = sampleFirstToken ?? isFinalChunk
        self.samplerSeed = samplerSeed
        self.temperature = temperature
        self.topP = topP
        self.samplerStep = samplerStep
        self.nativeMTPPromptPrefill = nativeMTPPromptPrefill
    }
}

struct ContinuousBatchPrefillOutput: Sendable, Equatable {
    let requestID: String
    /// The first generated token, sampled from the final prompt position.
    /// Required for a successful final chunk and absent for earlier chunks.
    let sampledToken: Int?
    /// Serial fallback can fail one row without coupling healthy rows to that
    /// failure. Shared-forward failures still throw and fail the whole group.
    let failureCode: String?

    init(requestID: String, sampledToken: Int? = nil, failureCode: String? = nil) {
        self.requestID = requestID
        self.sampledToken = sampledToken
        self.failureCode = failureCode
    }
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

struct ContinuousBatchNativeMTPVerifyInput: Sendable, Equatable {
    let requestID: String
    let currentToken: Int
    let proposalTokens: [Int]
    let generatedTokens: [Int]
    let samplerSeed: Int
    let binding: PagedKVStorageBinding
    let blockTable: PagedKVBlockTable
    let committedKVTokenCount: Int
    /// Number of target-cache columns staged by packed verification. Native MTP
    /// verifies the current target column plus every proposal, while scheduler
    /// acceptance/visibility still reports proposal counts only.
    let verifiedInputTokenCount: Int
    let targetKVTokenCount: Int
    let packedRowIndex: Int
    let samplerStep: Int
}

struct ContinuousBatchNativeMTPProposalInput: Sendable, Equatable {
    let requestID: String
    let currentToken: Int
    let generatedTokens: [Int]
    let samplerSeed: Int
    let maximumProposalDepth: Int
    let samplerStep: Int
}

struct ContinuousBatchNativeMTPFinalizeInput: Sendable, Equatable {
    let requestID: String
    let proposalTokenCount: Int
    let committedProposalTokenCount: Int
    /// Exact buyer-visible tokens selected from this packed round, after stop
    /// and max-token filters. The backend uses these to resolve row-local
    /// drafter state against the same accepted prefix as target KV.
    let acceptedTokenIDs: [Int]
    /// Number of staged target-cache columns the backend may make durable for
    /// this row. This is `1 + committedProposalTokenCount` on commit because
    /// the verified target column is part of the native transaction, and `0`
    /// on abort/cancel/invalid rows.
    let committedInputTokenCount: Int
    let shouldCommit: Bool
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
    /// Prefill commits the whole prompt. The final chunk samples the first
    /// generated token from its last-position logits so the prompt partition
    /// matches the serial `TokenIterator` path exactly.
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
    /// Return backend-owned native MTP proposal tokens by request ID. A nil
    /// return means this backend has no drafter source; the scheduler may use
    /// request-fixture proposals in tests. A non-nil empty proposal for a row
    /// means depth-zero target verification is required for that row.
    func proposeNativeMTPPackedRound(
        rows: [ContinuousBatchNativeMTPProposalInput]
    ) async throws -> [String: [Int]]?
    func verifyNativeMTPPackedRound(
        rows: [ContinuousBatchNativeMTPVerifyInput]
    ) async throws -> [NativeMTPVerifiedRow]
    func finalizeNativeMTPPackedRound(
        rows: [ContinuousBatchNativeMTPFinalizeInput]
    ) async throws
    /// Install a same-conversation retained paged-KV handoff before the row resumes
    /// prefill at its serial LCP. Backends that cannot consume FR-PKV10 must fail
    /// closed instead of accepting positive cached-token credit. A hybrid backend
    /// restores its recurrent layers from `recurrentCheckpoint`, taken at exactly
    /// the handoff length, and must fail closed without one.
    func installRetainedPagedKVCache(
        requestID: String,
        handoff: PagedKVPagedCacheHandoff,
        binding: PagedKVStorageBinding,
        recurrentCheckpoint: RecurrentStateCheckpoint?
    ) async throws
    /// Commit the final buyer-visible token into row-local KV state when a row
    /// stops immediately after sampling it. Retention happens after this step so
    /// canonical prompt history and retained paged-KV length agree.
    func commitTerminalKV(_ input: ContinuousBatchTerminalKVCommitInput) async throws
    /// Snapshot the row's own recurrent-layer state right after prefill reached
    /// `tokenCount` prompt tokens. Nil when the backend has no recurrent layers.
    func snapshotRecurrentState(requestID: String, tokenCount: Int) async -> RecurrentStateCheckpoint?
    /// Build the row's serial-format conversation cache at a normal terminal,
    /// before its blocks are released: attention KV materialized from `binding`
    /// and trimmed to `tokenCount`. Nil when the backend has no recurrent layers.
    func materializeSerialConversationCache(
        requestID: String,
        binding: PagedKVStorageBinding,
        tokenCount: Int,
        recurrentCheckpoints: [RecurrentStateCheckpoint]
    ) async throws -> ContinuousBatchSerialConversationCache?
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
    func proposeNativeMTPPackedRound(
        rows: [ContinuousBatchNativeMTPProposalInput]
    ) async throws -> [String: [Int]]? {
        nil
    }

    func verifyNativeMTPPackedRound(
        rows: [ContinuousBatchNativeMTPVerifyInput]
    ) async throws -> [NativeMTPVerifiedRow] {
        throw ContinuousBatchSchedulerError.unsupported("continuous_batching_native_mtp_backend_unavailable")
    }

    func finalizeNativeMTPPackedRound(
        rows: [ContinuousBatchNativeMTPFinalizeInput]
    ) async throws {
        guard rows.isEmpty else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_native_mtp_backend_unavailable")
        }
    }

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
        binding: PagedKVStorageBinding,
        recurrentCheckpoint: RecurrentStateCheckpoint?
    ) async throws {
        throw ContinuousBatchSchedulerError.unsupported("continuous_batching_paged_kv_handoff_unavailable")
    }

    func commitTerminalKV(_ input: ContinuousBatchTerminalKVCommitInput) async throws {
        throw ContinuousBatchSchedulerError.unsupported("continuous_batching_terminal_kv_commit_unavailable")
    }

    func snapshotRecurrentState(requestID: String, tokenCount: Int) async -> RecurrentStateCheckpoint? {
        nil
    }

    func materializeSerialConversationCache(
        requestID: String,
        binding: PagedKVStorageBinding,
        tokenCount: Int,
        recurrentCheckpoints: [RecurrentStateCheckpoint]
    ) async throws -> ContinuousBatchSerialConversationCache? {
        nil
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
    /// Prompt plus output budget exceeds the served context
    /// (`maxRequestTokens`). A property of the request, rejected before any
    /// inference, so it maps to the serial path's 413
    /// `context_length_exceeded` and the relay's `error_context_exceeded`
    /// (zero settlement; error receipt per SPEC-015 §7.6).
    case contextLengthExceeded(promptTokens: Int, maxOutputTokens: Int, contextTokens: Int)
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
        case let .contextLengthExceeded(promptTokens, maxOutputTokens, contextTokens):
            return APIError(
                status: 413,
                message: "Prompt length (\(promptTokens) tokens) plus max_tokens (\(maxOutputTokens)) exceeds this provider's context window (\(contextTokens) tokens).",
                type: "context_length_exceeded",
                code: "context_length_exceeded",
                param: "max_tokens",
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
        "continuous_batching_retained_hybrid_cache_unavailable": 503,
        "continuous_batching_native_mtp_backend_unavailable": 503,
        "continuous_batching_native_mtp_round_memory_exhausted": 503,
        "continuous_batching_native_mtp_tuple_disabled": 503,
        "continuous_batching_native_mtp_window_bytes_unavailable": 503,
        "continuous_batching_terminal_kv_commit_missing_token": 503,
        "continuous_batching_decode_row_mismatch": 503,
        "continuous_batching_decode_cursor_overflow": 503,
        "continuous_batching_duplicate_decode_row": 503,
        "continuous_batching_duplicate_prefill_row": 503,
        "continuous_batching_prefill_row_mismatch": 503,
        "continuous_batching_reservation_overflow": 503,
        "continuous_batching_native_mtp_prompt_prefill_exceeds_limit": 400,
    ]

    private static func carriedCodeStatus(_ code: String) -> Int {
        carriedCodeStatuses[code] ?? 503
    }
}

actor ContinuousBatchScheduler {
    /// Operator log line for a submit-time context rejection; the relay
    /// collapses it into `error_context_exceeded`, so the numbers live here.
    static func contextRejectedTelemetryLine(promptTokens: Int, maxOutputTokens: Int, cap: Int) -> String {
        "event=batching_rejected code=context_length_exceeded prompt_tokens=\(promptTokens) max_output_tokens=\(maxOutputTokens) cap=\(cap)\n"
    }

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
        var stopCause: ContinuousBatchSchedulerStopCause? = nil
        var prefillCursor: Int
        var snapshot: ContinuousBatchSchedulerSnapshot
        /// Keyed hybrid rows: recurrent state at each reached prompt checkpoint
        /// plus the terminal covered-token checkpoint.
        var recurrentCheckpoints: [RecurrentStateCheckpoint] = []
        var decodePath: DecodePath = .ordinary
        var nativeMTPAdaptation: NativeMTPDepthAdaptationState?
        var nativeMTPDirective: NativeMTPAdaptationDirective?
        var nativeMTPTupleFence: NativeMTPTupleFence?
        var nativeMTPCounters: NativeMTPSelfTestCounters?
        var nativeMTPFixtureProposalsConsumed = false

        var retainedLogicalTokenCount: Int {
            request.promptTokens.count + generatedTokens.count
        }

        var canonicalRetainedLogicalTokenCount: Int {
            retainedLogicalTokenCount - (stopCause == .modelStop ? 1 : 0)
        }

        var usesNativeMTP: Bool {
            decodePath == .nativeMTP
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
    private var nativeMTPReservedRoundBytes = 0
    private var nativeMTPRoundByteReservations: [UUID: Int] = [:]
    private var activePrompt: [String: Row] = [:]
    private var promptOrder: [String] = []
    private var activeDecode: [String: Row] = [:]
    private var requestWaiters: [String: [Waiter]] = [:]
    private var knownRequests: [String: RequestFingerprint] = [:]
    private var terminalResults: [String: ContinuousBatchSchedulerResult] = [:]
    private var disabledNativeMTPTupleFences: Set<NativeMTPTupleFence> = []
    private var nativeMTPRowsWithStagedMutation: Set<String> = []
    private var nativeMTPIntegrityProbeInFlight = false
    private var pendingTerminalDeliveries: [String: PendingTerminalDelivery] = [:]
    private var stoppingWaiterIDs: Set<UUID> = []
    private var stoppingActiveWaiters: [UUID: StoppingActiveWaiter] = [:]
    private var deferredTerminalCompletions: [String: DeferredTerminalCompletion] = [:]
    private var deliveredRetainedOwners: [UUID: DeliveredRetainedOwner] = [:]
    private var terminalResultOrder: [String] = []
    private var dedupeTombstones: Set<String> = []
    private var dedupeTombstoneOrder: [String] = []
    private var cancelledIDs: Set<String> = []
    /// SPEC-038 AC-6c: decoding rows asked to end as a normal `.stop` at their
    /// next applied token (a serial tool turn completed its first tool call).
    private var earlyStopIDs: Set<String> = []
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
        if nativeMTPIntegrityProbeInFlight && !request.nativeMTPIntegrityProbe {
            await discardUnacceptedRetainedCache(for: request)
            throw ContinuousBatchSchedulerError.backpressure
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
        let (contextTokens, contextOverflow) = request.promptTokens.count.addingReportingOverflow(
            request.maxOutputTokens
        )
        if contextOverflow || contextTokens > configuration.maxRequestTokens {
            try? FileHandle.standardError.write(contentsOf: Data(Self.contextRejectedTelemetryLine(
                promptTokens: request.promptTokens.count,
                maxOutputTokens: request.maxOutputTokens,
                cap: configuration.maxRequestTokens
            ).utf8))
            await discardUnacceptedRetainedCache(for: request)
            throw ContinuousBatchSchedulerError.contextLengthExceeded(
                promptTokens: request.promptTokens.count,
                maxOutputTokens: request.maxOutputTokens,
                contextTokens: configuration.maxRequestTokens
            )
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
        if request.decodePath == .nativeMTP,
           request.promptTokens.count > configuration.maxPromptChunkTokens {
            await discardUnacceptedRetainedCache(for: request)
            throw ContinuousBatchSchedulerError.requestFailed(
                "continuous_batching_native_mtp_prompt_prefill_exceeds_limit"
            )
        }
        if let fence = request.nativeMTPTupleFence,
           disabledNativeMTPTupleFences.contains(fence) {
            await discardUnacceptedRetainedCache(for: request)
            throw ContinuousBatchSchedulerError.requestFailed(
                "continuous_batching_native_mtp_tuple_disabled"
            )
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

    /// SPEC-038 AC-6c: end a decoding row as a normal `.stop` at its next
    /// applied token. The serial path stops a serial tool turn (SPEC-018,
    /// `parallel_tool_calls` omitted/false) once the first tool call is
    /// complete; the batched caller truncates the row's tokens back to that
    /// exact point, so this only bounds wasted decode. A row that is not
    /// decoding (queued, prefilling, or already terminal) is left alone.
    func stopEarly(requestID: String) {
        guard activeDecode[requestID] != nil else { return }
        earlyStopIDs.insert(requestID)
    }

    func disableNativeMTPTuple(_ fence: NativeMTPTupleFence) async {
        disabledNativeMTPTupleFences.insert(fence)
        var keptWaiting: [ContinuousBatchSchedulerRequest] = []
        for request in waiting {
            guard request.nativeMTPTupleFence == fence else {
                keptWaiting.append(request)
                continue
            }
            await finishQueued(
                request,
                status: .requestFailed,
                errorCode: "continuous_batching_native_mtp_tuple_disabled"
            )
        }
        waiting = keptWaiting
        let disabledPromptIDs = activePrompt.compactMap { requestID, row in
            row.request.nativeMTPTupleFence == fence ? requestID : nil
        }
        for requestID in disabledPromptIDs {
            guard var row = activePrompt[requestID] else { continue }
            row.decodePath = .ordinary
            row.nativeMTPAdaptation = nil
            row.nativeMTPDirective = nil
            activePrompt[requestID] = row
        }
        await fenceDisabledActiveNativeMTPRows()
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

    func isQuiescentForNativeMTPProbe() -> Bool {
        !cleanupFailedClosed
            && !nativeMTPIntegrityProbeInFlight
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

    func submitNativeMTPIntegrityProbe(
        _ request: ContinuousBatchSchedulerRequest
    ) async throws -> ContinuousBatchSchedulerResult {
        guard request.nativeMTPIntegrityProbe,
              request.decodePath == .nativeMTP,
              isQuiescentForNativeMTPProbe() else {
            throw ContinuousBatchSchedulerError.backpressure
        }
        nativeMTPIntegrityProbeInFlight = true
        defer { nativeMTPIntegrityProbeInFlight = false }
        return try await submit(request)
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
        guard !joinPending else { return 1 }
        // A prompt mid-prefill joins only after its last chunk, so decode may
        // take a bounded window between chunks (FR-CB2) instead of one token.
        let configured = activePrompt.isEmpty
            ? configuration.maxDecodeLockstepWindow
            : min(configuration.maxDecodeLockstepWindow, configuration.maxDecodeStepsWhilePrefilling)
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

    private struct PreparedNativeMTPRow {
        let row: Row
        let input: ContinuousBatchNativeMTPVerifyInput
        let rowMap: NativeMTPPackedRowMap
        let transaction: PagedKVNativeMTPTransaction
        let scratchReservation: PagedKVNativeMTPScratchReservation
        let byteReservation: NativeMTPRoundByteReservation
    }

    private struct NativeMTPRoundByteReservation {
        let id: UUID
        let bytes: Int
    }

    private struct PreReservedNativeMTPRow {
        let row: Row
        let maximumDepth: Int
        let committedKVTokenCount: Int
        let transaction: PagedKVNativeMTPTransaction
        let stagedMapping: PagedKVNativeMTPStagedMapping
        let scratchReservation: PagedKVNativeMTPScratchReservation
        let byteReservation: NativeMTPRoundByteReservation
    }

    private struct ReservedNativeMTPRow {
        let row: Row
        let proposalTokens: [Int]
        let consumedFixtureProposals: Bool
        let inputTokenCount: Int
        let committedKVTokenCount: Int
        let targetKVTokenCount: Int
        let transaction: PagedKVNativeMTPTransaction
        let stagedMapping: PagedKVNativeMTPStagedMapping
        let scratchReservation: PagedKVNativeMTPScratchReservation
        let byteReservation: NativeMTPRoundByteReservation
    }

    private func nativeMTPMaximumProposalDepth(for row: Row) -> Int {
        let remainingOutputTokens = max(0, row.request.maxOutputTokens - row.generatedTokens.count)
        let remainingProposalCapacity = max(0, remainingOutputTokens - 1)
        let requestedDepth = row.nativeMTPDirective?.forcedDepth
            ?? row.nativeMTPAdaptation?.currentDepth
            ?? row.request.nativeMTPMaximumProposalDepth
        return min(
            max(0, requestedDepth),
            row.request.nativeMTPMaximumProposalDepth,
            remainingProposalCapacity
        )
    }

    private func nativeMTPFixtureProposalTokens(for row: Row, maximumDepth: Int) -> [Int] {
        guard !row.nativeMTPFixtureProposalsConsumed else { return [] }
        let boundedDepth = min(maximumDepth, row.request.nativeMTPProposalTokens.count)
        guard row.usesNativeMTP, boundedDepth > 0 else { return [] }
        return Array(row.request.nativeMTPProposalTokens.prefix(boundedDepth))
    }

    private func nativeMTPScratchReservationTokens() -> Int {
        // Target KV columns are reserved by the staged native-MTP transaction.
        // Non-target drafter/cache/hidden/workspace/checkpoint bytes are
        // bounded by the signed per-depth byte ledger below; reserving the same
        // bytes again from the KV block pool would double-count and reject
        // otherwise admissible rows without proving a stronger memory bound.
        0
    }

    private func nativeMTPCompleteWindowBytes(for row: Row, maximumDepth: Int) throws -> Int {
        guard maximumDepth >= 0 else {
            throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_native_mtp_round_memory_exhausted")
        }
        guard row.request.nativeMTPCompleteWindowBytesByDepth.indices.contains(maximumDepth) else {
            throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_native_mtp_window_bytes_unavailable")
        }
        let bytes = row.request.nativeMTPCompleteWindowBytesByDepth[maximumDepth]
        guard bytes > 0 else {
            throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_native_mtp_window_bytes_unavailable")
        }
        return bytes
    }

    private func reserveNativeMTPRoundBytes(_ bytes: Int) throws -> NativeMTPRoundByteReservation {
        guard bytes > 0 else {
            throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_native_mtp_window_bytes_unavailable")
        }
        let (nextReserved, overflow) = nativeMTPReservedRoundBytes.addingReportingOverflow(bytes)
        guard !overflow,
              nextReserved <= configuration.nativeMTPRoundByteCapacity,
              nativeMTPSystemMemoryHeadroomAdmits(reservedAfter: nextReserved) else {
            throw ContinuousBatchSchedulerError.requestFailed("continuous_batching_native_mtp_round_memory_exhausted")
        }
        let id = UUID()
        nativeMTPReservedRoundBytes = nextReserved
        nativeMTPRoundByteReservations[id] = bytes
        return NativeMTPRoundByteReservation(id: id, bytes: bytes)
    }

    private func nativeMTPSystemMemoryHeadroomAdmits(reservedAfter: Int) -> Bool {
        guard reservedAfter > 0,
              let sample = configuration.nativeMTPRoundSystemMemoryProbe.sample(),
              sample.availableBytes > 0,
              sample.physicalBytes > 0 else {
            return false
        }
        let minimumHeadroom = max(1, sample.physicalBytes / 10)
        let (requiredAvailable, overflow) = reservedAfter.addingReportingOverflow(minimumHeadroom)
        guard !overflow else {
            return false
        }
        return sample.availableBytes >= requiredAvailable
    }

    private func releaseNativeMTPRoundBytes(_ reservation: NativeMTPRoundByteReservation) {
        guard let bytes = nativeMTPRoundByteReservations.removeValue(forKey: reservation.id) else {
            cleanupFailedClosed = true
            record(.cleanupFailed)
            ContinuousBatchingPolicy.logForwardFailed(
                ContinuousBatchSchedulerError.requestFailed("continuous_batching_native_mtp_round_memory_exhausted")
            )
            return
        }
        nativeMTPReservedRoundBytes = max(0, nativeMTPReservedRoundBytes - bytes)
    }

    func nativeMTPReservedRoundBytesSnapshot() -> Int {
        nativeMTPReservedRoundBytes
    }

    private func nativeMTPCandidatesToApply(
        acceptedRow: NativeMTPAcceptedRow,
        row: Row
    ) -> [NativeMTPTokenCandidate] {
        var generated = row.generatedTokens
        var selected: [NativeMTPTokenCandidate] = []
        for candidate in acceptedRow.tokenCandidates {
            guard generated.count < row.request.maxOutputTokens else { break }
            generated.append(candidate.tokenID)
            selected.append(candidate)
            if matchingStopLength(
                generated,
                stopSequences: row.request.stopTokenSequences
            ) != nil || earlyStopIDs.contains(row.request.id) {
                break
            }
        }
        return selected
    }

    private func abortNativeMTPRound(_ prepared: [PreparedNativeMTPRow]) async throws {
        guard !prepared.isEmpty else { return }
        var failure: (any Error)?
        do {
            try await backend.finalizeNativeMTPPackedRound(rows: prepared.map {
                ContinuousBatchNativeMTPFinalizeInput(
                    requestID: $0.row.request.id,
                    proposalTokenCount: $0.input.proposalTokens.count,
                    committedProposalTokenCount: 0,
                    acceptedTokenIDs: [],
                    committedInputTokenCount: 0,
                    shouldCommit: false
                )
            })
        } catch {
            failure = error
        }
        for item in prepared {
            do {
                _ = try await allocator.abortNativeMTPTransaction(item.transaction)
            } catch {
                failure = failure ?? error
            }
            do {
                try await allocator.releaseNativeMTPScratchReservation(item.scratchReservation)
            } catch {
                failure = failure ?? error
            }
            releaseNativeMTPRoundBytes(item.byteReservation)
            nativeMTPRowsWithStagedMutation.remove(item.row.request.id)
        }
        if let failure {
            throw failure
        }
    }

    private func releaseNativeMTPScratch(_ reservation: PagedKVNativeMTPScratchReservation) async {
        do {
            try await allocator.releaseNativeMTPScratchReservation(reservation)
        } catch {
            cleanupFailedClosed = true
            record(.cleanupFailed)
            ContinuousBatchingPolicy.logForwardFailed(error)
        }
    }

    private func abortPreReservedNativeMTPRows(_ reserved: [PreReservedNativeMTPRow]) async {
        for item in reserved {
            do {
                _ = try await allocator.abortNativeMTPTransaction(item.transaction)
            } catch {
                cleanupFailedClosed = true
                record(.cleanupFailed)
                ContinuousBatchingPolicy.logForwardFailed(error)
            }
            await releaseNativeMTPScratch(item.scratchReservation)
            releaseNativeMTPRoundBytes(item.byteReservation)
            nativeMTPRowsWithStagedMutation.remove(item.row.request.id)
        }
    }

    private func abortReservedNativeMTPRows(_ reserved: [ReservedNativeMTPRow]) async {
        for item in reserved {
            do {
                _ = try await allocator.abortNativeMTPTransaction(item.transaction)
            } catch {
                cleanupFailedClosed = true
                record(.cleanupFailed)
                ContinuousBatchingPolicy.logForwardFailed(error)
            }
            await releaseNativeMTPScratch(item.scratchReservation)
            releaseNativeMTPRoundBytes(item.byteReservation)
            nativeMTPRowsWithStagedMutation.remove(item.row.request.id)
        }
    }

    private func nativeMTPLocalTopology() throws -> PagedKVStateTopology {
        try PagedKVStateTopology(components: [
            try PagedKVStateTopologyComponent(
                name: "scheduler_paged_kv",
                kind: "attention",
                dtype: configuration.descriptor.kvDType,
                shape: [
                    1,
                    1,
                    configuration.descriptor.blockSizeTokens,
                    1,
                ],
                logicalExtent: configuration.descriptor.blockSizeTokens
            ),
        ])
    }

    private func nativeMTPServedSnapshotID(for row: Row) -> String {
        [
            row.snapshot.modelID,
            row.snapshot.modelSHA256,
            String(row.snapshot.weightsGeneration),
        ].joined(separator: ":")
    }

    private func nativeMTPStagedRowIsCurrent(_ row: Row) -> Bool {
        guard let active = activeDecode[row.request.id] else { return false }
        if let fence = active.nativeMTPTupleFence,
           disabledNativeMTPTupleFences.contains(fence) {
            return false
        }
        return active.usesNativeMTP
            && active.nativeMTPTupleFence == row.nativeMTPTupleFence
            && active.handle == row.handle
            && active.currentToken == row.currentToken
            && active.generatedTokens == row.generatedTokens
            && active.outputTokens == row.outputTokens
    }

    private func staleNativeMTPRows(_ rows: [Row]) -> [Row] {
        rows.filter { !nativeMTPStagedRowIsCurrent($0) }
    }

    private func failStaleNativeMTPRows(
        _ rows: [Row],
        cleanupError: (any Error)?,
        fallbackErrorCode: String
    ) async {
        if let cleanupError {
            record(.cleanupFailed)
            ContinuousBatchingPolicy.logForwardFailed(cleanupError)
        } else {
            record(.localPreparationFailed)
        }
        for row in rows {
            nativeMTPRowsWithStagedMutation.remove(row.request.id)
            guard let removed = activeDecode.removeValue(forKey: row.request.id) else { continue }
            let released = await release(removed.handle)
            let disabled = removed.nativeMTPTupleFence.map {
                disabledNativeMTPTupleFences.contains($0)
            } ?? false
            if disabled && nativeMTPRowHasBuyerVisibleOutput(removed) {
                configuration.nativeMTPStatusSink?.recordPostoutputFailure()
            }
            finish(
                removed,
                status: .requestFailed,
                errorCode: released
                    ? (disabled
                        ? (nativeMTPRowHasBuyerVisibleOutput(removed)
                            ? "continuous_batching_native_mtp_tuple_disabled_postoutput"
                            : "continuous_batching_native_mtp_tuple_disabled")
                        : fallbackErrorCode)
                    : "continuous_batching_cleanup_failed"
            )
            if !released { return }
        }
    }

    private func checkpointAndStageNativeMTP(
        row: Row,
        inputTokenCount: Int,
        topology: PagedKVStateTopology
    ) async throws -> (PagedKVNativeMTPTransaction, PagedKVNativeMTPStagedMapping) {
        let transaction = try await allocator.checkpointNativeMTPTransaction(
            handle: row.handle,
            servedSnapshotID: nativeMTPServedSnapshotID(for: row),
            topology: topology
        )
        do {
            let staged = try await allocator.stageNativeMTPTransaction(
                transaction,
                proposalTokenCount: inputTokenCount
            )
            return (transaction, staged)
        } catch {
            do {
                _ = try await allocator.abortNativeMTPTransaction(transaction)
            } catch {
                throw error
            }
            throw error
        }
    }

    private func runNativeMTPDecodeStep(rows: [Row]) async {
        let nativeMTPStatusSink = configuration.nativeMTPStatusSink
        var nativeMTPStatusRoundStarted = false
        let nativeMTPStatusStartedAt = Date()
        defer {
            if nativeMTPStatusRoundStarted {
                nativeMTPStatusSink?.endRound()
            }
        }
        let topology: PagedKVStateTopology
        do {
            topology = try nativeMTPLocalTopology()
        } catch {
            record(.localPreparationFailed)
            ContinuousBatchingPolicy.logForwardFailed(error)
            for row in rows {
                if let removed = activeDecode.removeValue(forKey: row.request.id) {
                    let released = await release(removed.handle)
                    finish(
                        removed,
                        status: .requestFailed,
                        errorCode: released
                            ? "continuous_batching_native_mtp_topology_failed"
                            : "continuous_batching_cleanup_failed"
                    )
                    if !released { return }
                }
            }
            return
        }
        var preReserved: [PreReservedNativeMTPRow] = []
        preReserved.reserveCapacity(rows.count)
        for row in rows {
            let committedKVTokenCount = row.request.promptTokens.count - 1 + row.generatedTokens.count
            var selectedReservation: PreReservedNativeMTPRow?
            var reservationFailure: (any Error)?
            var depth = nativeMTPMaximumProposalDepth(for: row)
            while depth >= 0 {
                let inputTokenCount = depth + 1
                let target = committedKVTokenCount.addingReportingOverflow(inputTokenCount)
                guard !target.overflow else {
                    reservationFailure = ContinuousBatchSchedulerError.requestFailed(
                        "continuous_batching_decode_cursor_overflow"
                    )
                    break
                }
                let completeWindowBytes: Int
                do {
                    completeWindowBytes = try nativeMTPCompleteWindowBytes(for: row, maximumDepth: depth)
                } catch {
                    reservationFailure = error
                    break
                }
                let byteReservation: NativeMTPRoundByteReservation
                do {
                    byteReservation = try reserveNativeMTPRoundBytes(completeWindowBytes)
                } catch {
                    reservationFailure = error
                    if depth == 0 { break }
                    depth -= 1
                    continue
                }
                let scratchTokens = nativeMTPScratchReservationTokens()
                let scratchReservation: PagedKVNativeMTPScratchReservation
                nativeMTPRowsWithStagedMutation.insert(row.request.id)
                do {
                    scratchReservation = try await allocator.reserveNativeMTPScratchTokens(scratchTokens)
                } catch {
                    releaseNativeMTPRoundBytes(byteReservation)
                    nativeMTPRowsWithStagedMutation.remove(row.request.id)
                    reservationFailure = error
                    if depth == 0 { break }
                    depth -= 1
                    continue
                }
                do {
                    let (transaction, staged) = try await checkpointAndStageNativeMTP(
                        row: row,
                        inputTokenCount: inputTokenCount,
                        topology: topology
                    )
                    selectedReservation = PreReservedNativeMTPRow(
                        row: row,
                        maximumDepth: depth,
                        committedKVTokenCount: committedKVTokenCount,
                        transaction: transaction,
                        stagedMapping: staged,
                        scratchReservation: scratchReservation,
                        byteReservation: byteReservation
                    )
                    break
                } catch {
                    await releaseNativeMTPScratch(scratchReservation)
                    releaseNativeMTPRoundBytes(byteReservation)
                    nativeMTPRowsWithStagedMutation.remove(row.request.id)
                    reservationFailure = error
                    if depth == 0 { break }
                    depth -= 1
                }
            }
            guard let selectedReservation else {
                await abortPreReservedNativeMTPRows(preReserved)
                if let reservationFailure {
                    ContinuousBatchingPolicy.logForwardFailed(reservationFailure)
                }
                let carriedCode: String
                if let schedulerError = reservationFailure as? ContinuousBatchSchedulerError,
                   case .requestFailed(let code) = schedulerError {
                    carriedCode = code
                } else {
                    carriedCode = "continuous_batching_block_extension_failed"
                }
                if carriedCode == "continuous_batching_native_mtp_round_memory_exhausted" {
                    nativeMTPStatusSink?.recordCapacityRejection()
                }
                record(.localExtensionFailed)
                if let removed = activeDecode.removeValue(forKey: row.request.id) {
                    let released = await release(removed.handle)
                    finish(
                        removed,
                        status: .requestFailed,
                        errorCode: released
                            ? carriedCode
                            : "continuous_batching_cleanup_failed"
                    )
                    if !released { return }
                }
                return
            }
            preReserved.append(selectedReservation)
        }
        let proposalInputs = preReserved.map { reservation -> ContinuousBatchNativeMTPProposalInput in
            let row = reservation.row
            return ContinuousBatchNativeMTPProposalInput(
                requestID: row.request.id,
                currentToken: row.currentToken,
                generatedTokens: row.generatedTokens,
                samplerSeed: row.request.samplerSeed,
                maximumProposalDepth: reservation.maximumDepth,
                samplerStep: row.generatedTokens.count
            )
        }
        nativeMTPStatusSink?.beginRound(requestedDepths: proposalInputs.map(\.maximumProposalDepth))
        nativeMTPStatusRoundStarted = true
        let backendProposals: [String: [Int]]?
        do {
            backendProposals = try await backend.proposeNativeMTPPackedRound(rows: proposalInputs)
        } catch {
            recordNativeMTPPostoutputFailureIfVisible(
                sink: nativeMTPStatusSink,
                rows: preReserved.map(\.row)
            )
            record(.batchForwardFailed)
            ContinuousBatchingPolicy.logForwardFailed(error)
            await abortPreReservedNativeMTPRows(preReserved)
            for item in preReserved {
                let row = item.row
                if let removed = activeDecode.removeValue(forKey: row.request.id) {
                    let released = await release(removed.handle)
                    finish(
                        removed,
                        status: .requestFailed,
                        errorCode: released
                            ? "continuous_batching_native_mtp_proposal_failed"
                            : "continuous_batching_cleanup_failed"
                    )
                    if !released { return }
                }
            }
            return
        }
        let stalePreReservedRows = staleNativeMTPRows(preReserved.map(\.row))
        guard stalePreReservedRows.isEmpty else {
            await abortPreReservedNativeMTPRows(preReserved)
            await failStaleNativeMTPRows(
                stalePreReservedRows,
                cleanupError: nil,
                fallbackErrorCode: "continuous_batching_native_mtp_stale_row"
            )
            return
        }

        var reserved: [ReservedNativeMTPRow] = []
        reserved.reserveCapacity(preReserved.count)
        for preReservation in preReserved {
            let row = preReservation.row
            let maximumDepth = preReservation.maximumDepth
            let initialProposals = backendProposals?[row.request.id]
                ?? nativeMTPFixtureProposalTokens(for: row, maximumDepth: maximumDepth)
            var consumedFixtureProposals = backendProposals == nil && !initialProposals.isEmpty
            let committedKVTokenCount = preReservation.committedKVTokenCount
            var proposals = Array(initialProposals.prefix(maximumDepth))
            var inputTokenCount = proposals.count + 1
            var target = committedKVTokenCount.addingReportingOverflow(inputTokenCount)
            if target.overflow, !proposals.isEmpty {
                proposals = []
                consumedFixtureProposals = false
                inputTokenCount = 1
                target = committedKVTokenCount.addingReportingOverflow(inputTokenCount)
            }
            guard !target.overflow else {
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
                await abortReservedNativeMTPRows(reserved)
                return
            }
            reserved.append(ReservedNativeMTPRow(
                row: row,
                proposalTokens: proposals,
                consumedFixtureProposals: consumedFixtureProposals,
                inputTokenCount: inputTokenCount,
                committedKVTokenCount: committedKVTokenCount,
                targetKVTokenCount: target.partialValue,
                transaction: preReservation.transaction,
                stagedMapping: preReservation.stagedMapping,
                scratchReservation: preReservation.scratchReservation,
                byteReservation: preReservation.byteReservation
            ))
        }

        var prepared: [PreparedNativeMTPRow] = []
        prepared.reserveCapacity(reserved.count)
        for (packedRowIndex, reservation) in reserved.enumerated() {
            let row = reservation.row
            do {
                let binding = try await allocator.binding(for: row.handle)
                let stagedBinding = PagedKVStorageBinding(
                    handle: binding.handle,
                    blockSizeTokens: binding.blockSizeTokens,
                    maxLogicalTokens: binding.maxLogicalTokens,
                    rowGeneration: binding.rowGeneration,
                    currentTable: reservation.stagedMapping.privateStagedTable,
                    poolEpoch: binding.poolEpoch
                )
                let input = ContinuousBatchNativeMTPVerifyInput(
                    requestID: row.request.id,
                    currentToken: row.currentToken,
                    proposalTokens: reservation.proposalTokens,
                    generatedTokens: row.generatedTokens,
                    samplerSeed: row.request.samplerSeed,
                    binding: stagedBinding,
                    blockTable: stagedBinding.currentTable,
                    committedKVTokenCount: reservation.committedKVTokenCount,
                    verifiedInputTokenCount: reservation.inputTokenCount,
                    targetKVTokenCount: reservation.targetKVTokenCount,
                    packedRowIndex: packedRowIndex,
                    samplerStep: row.generatedTokens.count
                )
                let rowMap = NativeMTPPackedRowMap(
                    schedulerRowID: row.request.id,
                    packedRowIndex: packedRowIndex,
                    inputTokenCount: reservation.inputTokenCount,
                    proposalTokenCount: reservation.proposalTokens.count
                )
                prepared.append(PreparedNativeMTPRow(
                    row: row,
                    input: input,
                    rowMap: rowMap,
                    transaction: reservation.transaction,
                    scratchReservation: reservation.scratchReservation,
                    byteReservation: reservation.byteReservation
                ))
            } catch {
                record(.localPreparationFailed)
                ContinuousBatchingPolicy.logForwardFailed(error)
                await abortReservedNativeMTPRows(reserved)
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
                return
            }
        }
        guard !prepared.isEmpty else { return }

        record(.decodeFirstStep)
        sharedForwardCalls += 1
        maxObservedBatchDepth = max(maxObservedBatchDepth, prepared.count)

        let verifiedRows: [NativeMTPVerifiedRow]
        do {
            verifiedRows = try await backend.verifyNativeMTPPackedRound(rows: prepared.map(\.input))
        } catch {
            recordNativeMTPPostoutputFailureIfVisible(
                sink: nativeMTPStatusSink,
                rows: prepared.map(\.row)
            )
            let abortError: (any Error)?
            do {
                try await abortNativeMTPRound(prepared)
                abortError = nil
            } catch {
                abortError = error
            }
            if backendCancellationPending { return }
            record(.batchForwardFailed)
            ContinuousBatchingPolicy.logForwardFailed(error)
            if let abortError {
                ContinuousBatchingPolicy.logForwardFailed(abortError)
            }
            for item in prepared {
                if let removed = activeDecode.removeValue(forKey: item.row.request.id) {
                    let released = await release(removed.handle)
                    finish(
                        removed,
                        status: released ? .batchFailed : .requestFailed,
                        errorCode: released
                            ? (abortError == nil
                                ? "continuous_batching_native_mtp_verify_failed"
                                : "continuous_batching_native_mtp_abort_failed")
                            : "continuous_batching_cleanup_failed"
                    )
                }
            }
            return
        }
        let stalePreparedRows = staleNativeMTPRows(prepared.map(\.row))
        guard stalePreparedRows.isEmpty else {
            let abortError: (any Error)?
            do {
                try await abortNativeMTPRound(prepared)
                abortError = nil
            } catch {
                abortError = error
            }
            await failStaleNativeMTPRows(
                abortError == nil ? stalePreparedRows : prepared.map(\.row),
                cleanupError: abortError,
                fallbackErrorCode: abortError == nil
                    ? "continuous_batching_native_mtp_stale_row"
                    : "continuous_batching_native_mtp_abort_failed"
            )
            return
        }

        let acceptedRows: [NativeMTPAcceptedRow]
        do {
            acceptedRows = try NativeMTPAcceptance.acceptGreedy(
                rowMaps: prepared.map(\.rowMap),
                verifiedRows: verifiedRows,
                packedRowCount: prepared.count
            )
        } catch {
            recordNativeMTPPostoutputFailureIfVisible(
                sink: nativeMTPStatusSink,
                rows: prepared.map(\.row)
            )
            let abortError: (any Error)?
            do {
                try await abortNativeMTPRound(prepared)
                abortError = nil
            } catch {
                abortError = error
            }
            record(.localPreparationFailed)
            ContinuousBatchingPolicy.logForwardFailed(error)
            if let abortError {
                ContinuousBatchingPolicy.logForwardFailed(abortError)
            }
            for item in prepared {
                if let removed = activeDecode.removeValue(forKey: item.row.request.id) {
                    let released = await release(removed.handle)
                    finish(
                        removed,
                        status: .requestFailed,
                        errorCode: released
                            ? (abortError == nil
                                ? "continuous_batching_native_mtp_acceptance_failed"
                                : "continuous_batching_native_mtp_abort_failed")
                            : "continuous_batching_cleanup_failed"
                    )
                    if !released { return }
                }
            }
            return
        }

        var acceptedByID: [String: NativeMTPAcceptedRow] = [:]
        for accepted in acceptedRows {
            acceptedByID[accepted.schedulerRowID] = accepted
        }
        var candidatesByID: [String: [NativeMTPTokenCandidate]] = [:]
        var proposalCountByID: [String: Int] = [:]
        var committedProposalCountByID: [String: Int] = [:]
        var invalidCandidateIDs: Set<String> = []
        var finalizeRows: [ContinuousBatchNativeMTPFinalizeInput] = []
        finalizeRows.reserveCapacity(prepared.count)
        for item in prepared {
            guard let accepted = acceptedByID[item.row.request.id] else { continue }
            let selected = nativeMTPCandidatesToApply(acceptedRow: accepted, row: item.row)
            candidatesByID[item.row.request.id] = selected
            if selected.contains(where: { !(0..<configuration.vocabularySize).contains($0.tokenID) }) {
                invalidCandidateIDs.insert(item.row.request.id)
            }
            let shouldCommit = !cancelledIDs.contains(item.row.request.id)
                && !invalidCandidateIDs.contains(item.row.request.id)
            let committedProposalCount = selected.last?.cumulativeProposalCommitCount ?? 0
            proposalCountByID[item.row.request.id] = item.input.proposalTokens.count
            committedProposalCountByID[item.row.request.id] = shouldCommit ? committedProposalCount : 0
            finalizeRows.append(ContinuousBatchNativeMTPFinalizeInput(
                requestID: item.row.request.id,
                proposalTokenCount: item.input.proposalTokens.count,
                committedProposalTokenCount: shouldCommit ? committedProposalCount : 0,
                acceptedTokenIDs: shouldCommit ? selected.map(\.tokenID) : [],
                committedInputTokenCount: shouldCommit ? committedProposalCount + 1 : 0,
                shouldCommit: shouldCommit
            ))
        }

        do {
            try await backend.finalizeNativeMTPPackedRound(rows: finalizeRows)
        } catch {
            recordNativeMTPPostoutputFailureIfVisible(
                sink: nativeMTPStatusSink,
                rows: prepared.map(\.row)
            )
            var localAbortError: (any Error)?
            for item in prepared {
                do {
                    _ = try await allocator.abortNativeMTPTransaction(item.transaction)
                } catch {
                    localAbortError = localAbortError ?? error
                }
                do {
                    try await allocator.releaseNativeMTPScratchReservation(item.scratchReservation)
                } catch {
                    localAbortError = localAbortError ?? error
                }
                releaseNativeMTPRoundBytes(item.byteReservation)
                nativeMTPRowsWithStagedMutation.remove(item.row.request.id)
            }
            record(.batchForwardFailed)
            ContinuousBatchingPolicy.logForwardFailed(error)
            if let localAbortError {
                ContinuousBatchingPolicy.logForwardFailed(localAbortError)
            }
            for item in prepared {
                if let removed = activeDecode.removeValue(forKey: item.row.request.id) {
                    let released = await release(removed.handle)
                    finish(
                        removed,
                        status: .requestFailed,
                        errorCode: released
                            ? (localAbortError == nil
                                ? "continuous_batching_native_mtp_finalize_failed"
                                : "continuous_batching_native_mtp_abort_failed")
                            : "continuous_batching_cleanup_failed"
                    )
                    if !released { return }
                }
            }
            return
        }
        let staleFinalizedRows = staleNativeMTPRows(prepared.map(\.row))
        guard staleFinalizedRows.isEmpty else {
            let abortError: (any Error)?
            do {
                try await abortNativeMTPRound(prepared)
                abortError = nil
            } catch {
                abortError = error
            }
            await failStaleNativeMTPRows(
                abortError == nil ? staleFinalizedRows : prepared.map(\.row),
                cleanupError: abortError,
                fallbackErrorCode: abortError == nil
                    ? "continuous_batching_native_mtp_stale_row"
                    : "continuous_batching_native_mtp_abort_failed"
            )
            return
        }

        let finalizedByID = Dictionary(uniqueKeysWithValues: finalizeRows.map { ($0.requestID, $0) })
        var healthyOutputIDs: Set<String> = []
        for item in prepared {
            guard let finalized = finalizedByID[item.row.request.id] else {
                var cleanupError: (any Error)?
                do {
                    _ = try await allocator.abortNativeMTPTransaction(item.transaction)
                } catch {
                    cleanupError = cleanupError ?? error
                }
                do {
                    try await allocator.releaseNativeMTPScratchReservation(item.scratchReservation)
                } catch {
                    cleanupError = cleanupError ?? error
                }
                releaseNativeMTPRoundBytes(item.byteReservation)
                nativeMTPRowsWithStagedMutation.remove(item.row.request.id)
                if let cleanupError {
                    record(.cleanupFailed)
                    ContinuousBatchingPolicy.logForwardFailed(cleanupError)
                }
                if let removed = activeDecode.removeValue(forKey: item.row.request.id) {
                    let released = await release(removed.handle)
                    finish(
                        removed,
                        status: .requestFailed,
                        errorCode: released
                            ? (cleanupError == nil
                                ? "continuous_batching_native_mtp_finalize_missing"
                                : "continuous_batching_native_mtp_abort_failed")
                            : "continuous_batching_cleanup_failed"
                    )
                    if !released { return }
                }
                continue
            }
            guard nativeMTPStagedRowIsCurrent(item.row) else {
                var cleanupError: (any Error)?
                do {
                    _ = try await allocator.abortNativeMTPTransaction(item.transaction)
                } catch {
                    cleanupError = cleanupError ?? error
                }
                do {
                    try await allocator.releaseNativeMTPScratchReservation(item.scratchReservation)
                } catch {
                    cleanupError = cleanupError ?? error
                }
                releaseNativeMTPRoundBytes(item.byteReservation)
                await failStaleNativeMTPRows(
                    [item.row],
                    cleanupError: cleanupError,
                    fallbackErrorCode: cleanupError == nil
                        ? "continuous_batching_native_mtp_stale_row"
                        : "continuous_batching_native_mtp_abort_failed"
                )
                continue
            }
            var localFinalizeError: (any Error)?
            do {
                if finalized.shouldCommit {
                    _ = try await allocator.commitNativeMTPTransaction(
                        item.transaction,
                        acceptedPrefixTokenCount: finalized.committedInputTokenCount
                    )
                } else {
                    _ = try await allocator.abortNativeMTPTransaction(item.transaction)
                }
            } catch {
                localFinalizeError = localFinalizeError ?? error
            }
            do {
                try await allocator.releaseNativeMTPScratchReservation(item.scratchReservation)
            } catch {
                localFinalizeError = localFinalizeError ?? error
            }
            releaseNativeMTPRoundBytes(item.byteReservation)
            nativeMTPRowsWithStagedMutation.remove(item.row.request.id)
            if localFinalizeError == nil {
                if nativeMTPStagedRowIsCurrent(item.row) {
                    healthyOutputIDs.insert(item.row.request.id)
                } else {
                    await failStaleNativeMTPRows(
                        [item.row],
                        cleanupError: nil,
                        fallbackErrorCode: "continuous_batching_native_mtp_stale_row"
                    )
                }
            } else if let error = localFinalizeError {
                recordNativeMTPPostoutputFailureIfVisible(
                    sink: nativeMTPStatusSink,
                    rows: [item.row]
                )
                record(.cleanupFailed)
                ContinuousBatchingPolicy.logForwardFailed(error)
                if let removed = activeDecode.removeValue(forKey: item.row.request.id) {
                    let released = await release(removed.handle)
                    finish(
                        removed,
                        status: .requestFailed,
                        errorCode: released
                            ? "continuous_batching_native_mtp_finalize_local_failed"
                            : "continuous_batching_cleanup_failed"
                    )
                    if !released { return }
                }
            }
        }
        if backendCancellationPending { return }
        await processCancellations()
        guard !cleanupFailedClosed else { return }

        let acceptedProposalTokens = finalizeRows.reduce(0) { $0 + $1.committedProposalTokenCount }
        let proposedTokens = prepared.reduce(0) { $0 + $1.input.proposalTokens.count }
        let committedTokens = candidatesByID.values.reduce(0) { $0 + $1.count }
        let bonusTokens = candidatesByID.values.reduce(0) { partial, candidates in
            partial + candidates.filter { $0.source == .bonus }.count
        }
        let overheadMS = UInt64(max(0, Date().timeIntervalSince(nativeMTPStatusStartedAt) * 1000.0))
        nativeMTPStatusSink?.recordRound(NativeMTPStatusSink.Round(
            requestedDepths: proposalInputs.map(\.maximumProposalDepth),
            proposedTokens: proposedTokens,
            acceptedTokens: acceptedProposalTokens,
            bonusTokens: bonusTokens,
            committedTokens: committedTokens,
            acceptedProposalTokensByRow: finalizeRows.map(\.committedProposalTokenCount),
            verificationOverheadMS: overheadMS
        ))

        for requestID in invalidCandidateIDs {
            guard let removed = activeDecode.removeValue(forKey: requestID) else { continue }
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

        let stillActive = Set(activeDecode.keys)
        for item in prepared where healthyOutputIDs.contains(item.row.request.id)
            && stillActive.contains(item.row.request.id) {
            if var active = activeDecode[item.row.request.id] {
                let requestID = item.row.request.id
                let candidates = candidatesByID[requestID] ?? []
                let committedProposalCount = committedProposalCountByID[requestID] ?? 0
                let proposalCount = proposalCountByID[requestID] ?? item.input.proposalTokens.count
                let roundCounters = NativeMTPSelfTestCounters(
                    acceptedTokens: UInt64(clamping: max(0, committedProposalCount)),
                    rejectedTokens: UInt64(clamping: max(0, proposalCount - committedProposalCount)),
                    bonusTokens: UInt64(clamping: candidates.filter { $0.source == .bonus }.count),
                    committedTokens: UInt64(clamping: candidates.count)
                )
                active.nativeMTPCounters = Self.addNativeMTPCounters(
                    active.nativeMTPCounters,
                    roundCounters
                )
                activeDecode[requestID] = active
            }
            if let consumed = reserved.first(where: { $0.row.request.id == item.row.request.id })?.consumedFixtureProposals,
               consumed,
               var active = activeDecode[item.row.request.id] {
                active.nativeMTPFixtureProposalsConsumed = true
                activeDecode[item.row.request.id] = active
            }
            for candidate in candidatesByID[item.row.request.id] ?? [] {
                guard activeDecode[item.row.request.id] != nil else { break }
                await applyToken(candidate.tokenID, to: item.row)
                if cleanupFailedClosed { return }
            }
        }
    }

    private func recordNativeMTPPostoutputFailureIfVisible(
        sink: NativeMTPStatusSink?,
        rows: [Row]
    ) {
        guard let sink else { return }
        if rows.contains(where: nativeMTPRowHasBuyerVisibleOutput) {
            sink.recordPostoutputFailure()
        }
    }

    private func nativeMTPRowHasBuyerVisibleOutput(_ row: Row) -> Bool {
        !row.outputTokens.isEmpty
    }

    private static func addNativeMTPCounters(
        _ lhs: NativeMTPSelfTestCounters?,
        _ rhs: NativeMTPSelfTestCounters
    ) -> NativeMTPSelfTestCounters {
        let base = lhs ?? NativeMTPSelfTestCounters(
            acceptedTokens: 0,
            rejectedTokens: 0,
            bonusTokens: 0,
            committedTokens: 0
        )
        let accepted = base.acceptedTokens.addingReportingOverflow(rhs.acceptedTokens)
        let rejected = base.rejectedTokens.addingReportingOverflow(rhs.rejectedTokens)
        let bonus = base.bonusTokens.addingReportingOverflow(rhs.bonusTokens)
        let committed = base.committedTokens.addingReportingOverflow(rhs.committedTokens)
        return NativeMTPSelfTestCounters(
            acceptedTokens: accepted.overflow ? UInt64.max : accepted.partialValue,
            rejectedTokens: rejected.overflow ? UInt64.max : rejected.partialValue,
            bonusTokens: bonus.overflow ? UInt64.max : bonus.partialValue,
            committedTokens: committed.overflow ? UInt64.max : committed.partialValue
        )
    }

    private func fenceDisabledActiveNativeMTPRows() async {
        var nativeIDs: [String] = []
        nativeIDs.reserveCapacity(activeDecode.count)
        for (requestID, row) in activeDecode {
            if row.usesNativeMTP,
               let fence = row.nativeMTPTupleFence,
               disabledNativeMTPTupleFences.contains(fence) {
                nativeIDs.append(requestID)
            }
        }
        for requestID in nativeIDs {
            guard var row = activeDecode[requestID] else { continue }
            if nativeMTPRowsWithStagedMutation.contains(requestID) {
                continue
            }
            activeDecode.removeValue(forKey: requestID)
            if nativeMTPRowHasBuyerVisibleOutput(row) {
                let released = await release(row.handle)
                configuration.nativeMTPStatusSink?.recordPostoutputFailure()
                finish(
                    row,
                    status: .requestFailed,
                    errorCode: released
                        ? "continuous_batching_native_mtp_tuple_disabled_postoutput"
                        : "continuous_batching_cleanup_failed"
                )
                if !released { return }
            } else {
                row.decodePath = DecodePath.ordinary
                row.nativeMTPAdaptation = nil
                row.nativeMTPDirective = nil
                activeDecode[requestID] = row
            }
        }
    }

    private func runDecodeStep() async {
        await fenceDisabledActiveNativeMTPRows()
        guard !cleanupFailedClosed else { return }
        let rows = activeDecode.values.sorted {
            admissionPrecedes($0.request.id, $1.request.id)
        }
        let nativeRows = rows.filter(\.usesNativeMTP)
        guard !nativeRows.isEmpty else {
            await runOrdinaryDecodeStep(rows: rows)
            return
        }
        let ordinaryRows = rows.filter { !$0.usesNativeMTP }
        if rows.first?.usesNativeMTP == true {
            await runNativeMTPDecodeStep(rows: nativeRows)
            guard !cleanupFailedClosed else { return }
            let remainingOrdinary = ordinaryRows.compactMap { activeDecode[$0.request.id] }
            await runOrdinaryDecodeStep(rows: remainingOrdinary)
        } else {
            await runOrdinaryDecodeStep(rows: ordinaryRows)
            guard !cleanupFailedClosed else { return }
            let remainingNative = nativeRows.compactMap { activeDecode[$0.request.id] }
            await runNativeMTPDecodeStep(rows: remainingNative)
        }
    }

    private func runOrdinaryDecodeStep(rows: [Row]) async {
        guard !rows.isEmpty else { return }
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
            row.stopCause = stopLength == 1 && row.request.modelStopTokenIDs.contains(token)
                ? .modelStop
                : .requestStop
            terminalStatus = .stop
        } else if earlyStopIDs.contains(row.request.id) {
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
        if row.request.serialToolStopObserver?.observe(visibleTokens) == true {
            // Match the existing asynchronous stopEarly boundary: the token
            // that completed the call is visible, and the next applied token
            // closes the row. Finalization truncates to the recorded boundary.
            earlyStopIDs.insert(row.request.id)
        }
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
            await finishTerminal(row, status: terminalStatus)
        }
    }

    /// Normal terminal for a row already removed from active tracking. The
    /// retain / materialize awaits can interleave with `cancel(requestID:)`,
    /// which only records the ID and no longer finds the row; a cancel recorded
    /// meanwhile wins, and no conversation cache is published for it.
    private func finishTerminal(_ row: Row, status: ContinuousBatchSchedulerTerminalStatus) async {
        if let retainedCache = await retainTerminalCache(
            for: row,
            targetLogicalTokens: row.canonicalRetainedLogicalTokenCount
        ) {
            if cancelledIDs.remove(row.request.id) != nil {
                await discardRetainedCache(
                    retainedCache.retainedSequence,
                    conversationKey: schedulerConversationKey(for: row.request)
                )
                finish(row, status: .cancelled, errorCode: "request_cancelled")
                return
            }
            finish(row, status: status, errorCode: nil, retainedCache: retainedCache)
            return
        }
        if contiguousCacheBridge != nil, row.request.modelHasRecurrentLayers {
            let released = await release(row.handle)
            if cancelledIDs.remove(row.request.id) != nil {
                finish(row, status: released ? .cancelled : .requestFailed, errorCode: released
                    ? "request_cancelled"
                    : "continuous_batching_cleanup_failed")
                return
            }
            finish(row, status: released ? status : .requestFailed, errorCode: released
                ? nil
                : "continuous_batching_cleanup_failed")
            return
        }
        let serialCache = await materializeSerialConversationCache(for: row)
        let released = await release(row.handle)
        if cancelledIDs.remove(row.request.id) != nil {
            finish(row, status: released ? .cancelled : .requestFailed, errorCode: released
                ? "request_cancelled"
                : "continuous_batching_cleanup_failed")
            return
        }
        finish(row, status: released ? status : .requestFailed, errorCode: released
            ? nil
            : "continuous_batching_cleanup_failed", serialConversationCache: serialCache)
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
            if let fence = request.nativeMTPTupleFence,
               disabledNativeMTPTupleFences.contains(fence) {
                await finishQueued(
                    request,
                    status: .requestFailed,
                    errorCode: "continuous_batching_native_mtp_tuple_disabled"
                )
                continue
            }
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
                    // A hybrid handoff resumes only from a checkpoint at exactly
                    // the cached length; the reattach below trims to it.
                    let recurrentCheckpoint = request.retainedRecurrentCheckpoints.first {
                        $0.tokenCount == request.cachedPromptTokens
                    }
                    if !request.retainedRecurrentCheckpoints.isEmpty && recurrentCheckpoint == nil {
                        throw ContinuousBatchSchedulerError.unsupported(
                            "continuous_batching_retained_hybrid_cache_unavailable"
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
                        binding: binding,
                        recurrentCheckpoint: recurrentCheckpoint
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
                if request.decodePath == .nativeMTP {
                    configuration.nativeMTPStatusSink?.recordNativeMTPAdmission()
                }
                activePrompt[request.id] = Row(
                    request: request,
                    handle: handle,
                    currentToken: request.promptTokens.last ?? 0,
                    generatedTokens: [],
                    outputTokens: [],
                    pendingOutputTokens: [],
                    prefillCursor: prefillCursor,
                    snapshot: configuration.snapshot,
                    // Stored checkpoints on this prompt's own positions are a
                    // prefix of it, so they carry forward (as on the serial path).
                    recurrentCheckpoints: request.retainedRecurrentCheckpoints.filter {
                        request.recurrentCheckpointPositions.contains($0.tokenCount)
                    },
                    decodePath: request.decodePath,
                    nativeMTPAdaptation: nil,
                    nativeMTPDirective: request.nativeMTPAdaptationDirective,
                    nativeMTPTupleFence: request.nativeMTPTupleFence,
                    nativeMTPFixtureProposalsConsumed: false
                )
                promptOrder.append(request.id)
                endQueueWait(requestID: request.id)
            } catch PagedKVAllocatorError.capacityExceeded {
                admittingRequests.removeValue(forKey: request.id)
                if draining {
                    await finishQueued(request, status: .rejected, errorCode: "continuous_batching_draining")
                } else if activeDecode.isEmpty && activePrompt.isEmpty && admittingRequests.isEmpty {
                    record(.poolCapacityRejected)
                    let poolTokens = configuration.descriptor.blockSizeTokens * configuration.descriptor.maxPhysicalBlocks
                    try? FileHandle.standardError.write(contentsOf: Data(
                        "event=batching_pool_capacity_rejected request_id=\(request.id) prompt_tokens=\(request.promptTokens.count) max_output_tokens=\(request.maxOutputTokens) pool_tokens=\(poolTokens)\n".utf8
                    ))
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
        var madeProgress = false
        // Completed prompt rows can be left behind by a zero-length retained
        // suffix. Transition them before selecting a compatible prefill group.
        for id in Array(promptOrder) {
            guard let row = activePrompt[id] else { continue }
            let promptTokenCount = row.request.promptTokens.count
            if row.prefillCursor >= promptTokenCount {
                await transitionPrefilledRow(row)
                madeProgress = true
                if cleanupFailedClosed { return true }
            }
        }

        var selected: [(row: Row, end: Int)] = []
        var selectedOffset: Int?
        var selectedChunkCount: Int?
        var selectedTokenCount = 0
        for id in promptOrder {
            guard selected.count < configuration.maxPrefillRowsPerIteration,
                  let row = activePrompt[id]
            else { continue }
            let remainingBudget = configuration.maxPrefillTokensPerIteration - selectedTokenCount
            guard remainingBudget > 0 else { break }
            let chunkLimit = min(
                configuration.maxPromptChunkTokens,
                selectedChunkCount ?? remainingBudget
            )
            let end = prefillEnd(for: row, maxChunkTokens: chunkLimit)
            let chunkCount = end - row.prefillCursor
            guard chunkCount > 0 else { continue }
            if let selectedOffset, let selectedChunkCount {
                guard row.prefillCursor == selectedOffset,
                      chunkCount == selectedChunkCount,
                      selectedTokenCount + chunkCount <= configuration.maxPrefillTokensPerIteration
                else { continue }
            } else {
                selectedOffset = row.prefillCursor
                selectedChunkCount = chunkCount
            }
            selected.append((row, end))
            selectedTokenCount += chunkCount
        }
        guard !selected.isEmpty else { return madeProgress }

        var prepared: [(row: Row, input: ContinuousBatchPrefillInput, chunkCount: Int)] = []
        for item in selected {
            let row = item.row
            let id = row.request.id
            let end = item.end
            let promptTokenCount = row.request.promptTokens.count
            let chunk = Array(row.request.promptTokens[row.prefillCursor..<end])
            do {
                _ = try await allocator.extend(row.handle, by: chunk.count)
            } catch {
                record(.localExtensionFailed)
                ContinuousBatchingPolicy.logPrefillFailed(error)
                if await finishPrefillFailure(
                    row,
                    failureCode: "continuous_batching_prefill_extend_failed"
                ) == false { return true }
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
                        isFinalChunk: end == promptTokenCount,
                        sampleFirstToken: end == promptTokenCount && row.request.maxOutputTokens > 0,
                        samplerSeed: row.request.samplerSeed,
                        temperature: row.request.temperature,
                        topP: row.request.topP,
                        samplerStep: row.generatedTokens.count,
                        nativeMTPPromptPrefill: row.usesNativeMTP
                            && row.prefillCursor == 0
                            && end == promptTokenCount
                    ),
                    chunk.count
                ))
            } catch {
                record(.localPreparationFailed)
                ContinuousBatchingPolicy.logPrefillFailed(error)
                if await finishPrefillFailure(
                    row,
                    failureCode: "continuous_batching_prefill_prepare_failed"
                ) == false { return true }
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
                guard activePrompt[item.row.request.id] != nil else { continue }
                if await finishPrefillFailure(
                    item.row,
                    failureCode: "continuous_batching_prefill_failed"
                ) == false { return true }
            }
            return true
        }

        let byID = Dictionary(uniqueKeysWithValues: outputs.map { ($0.requestID, $0) })
        for item in prepared {
            let id = item.row.request.id
            guard var row = activePrompt[id], let output = byID[id] else { continue }
            if cancelledIDs.remove(id) != nil {
                _ = removePromptRow(id)
                let released = await release(row.handle)
                finish(row, status: released ? .cancelled : .requestFailed, errorCode: released
                    ? "request_cancelled"
                    : "continuous_batching_cleanup_failed")
                if !released { return true }
                continue
            }
            if let failureCode = output.failureCode {
                if await finishPrefillFailure(row, failureCode: failureCode) == false { return true }
                continue
            }
            row.prefillCursor += item.chunkCount
            if pendingRecurrentCheckpointPositions(for: row).contains(row.prefillCursor) {
                if let checkpoint = await backend.snapshotRecurrentState(requestID: id, tokenCount: row.prefillCursor) {
                    row.recurrentCheckpoints.append(checkpoint)
                }
                guard activePrompt[id] != nil else { continue }
                // A cancel that arrived while the snapshot was suspended only
                // recorded the ID; honour it here, before the row can
                // materialize a cache or move on to decode.
                if cancelledIDs.remove(id) != nil {
                    _ = removePromptRow(id)
                    let released = await release(row.handle)
                    finish(row, status: released ? .cancelled : .requestFailed, errorCode: released
                        ? "request_cancelled"
                        : "continuous_batching_cleanup_failed")
                    if !released { return true }
                    continue
                }
            }
            if row.prefillCursor == row.request.promptTokens.count {
                activePrompt[id] = row
                guard row.request.maxOutputTokens > 0 else {
                    await transitionPrefilledRow(row)
                    if cleanupFailedClosed { return true }
                    continue
                }
                guard let sampledToken = output.sampledToken,
                      (0..<configuration.vocabularySize).contains(sampledToken) else {
                    record(.localPreparationFailed)
                    if await finishPrefillFailure(
                        row,
                        failureCode: "continuous_batching_invalid_prefill_token"
                    ) == false { return true }
                    continue
                }
                await transitionPrefilledRow(row, sampledToken: sampledToken)
                if cleanupFailedClosed { return true }
            } else {
                activePrompt[id] = row
            }
        }
        // Round-robin prompt rows at chunk boundaries. This keeps a long or
        // temporarily incompatible prompt from pinning the FCFS head forever,
        // while admission order remains unchanged.
        for id in prepared.map({ $0.row.request.id }) where activePrompt[id] != nil {
            promptOrder.removeAll { $0 == id }
            promptOrder.append(id)
        }
        return true
    }

    /// A cancellation observed while a fallible prefill operation was
    /// suspended wins over that operation's failure. Cleanup failure still
    /// fails closed because allocator ownership could not be proven released.
    private func finishPrefillFailure(_ row: Row, failureCode: String) async -> Bool {
        let id = row.request.id
        _ = removePromptRow(id)
        let wasCancelled = cancelledIDs.remove(id) != nil
        let released = await release(row.handle)
        finish(
            row,
            status: released && wasCancelled ? .cancelled : .requestFailed,
            errorCode: released
                ? (wasCancelled ? "request_cancelled" : failureCode)
                : "continuous_batching_cleanup_failed"
        )
        return released
    }

    private func prefillEnd(for row: Row, maxChunkTokens: Int) -> Int {
        let promptTokenCount = row.request.promptTokens.count
        var spanEnd = promptTokenCount
        // Hybrid recurrent state may only be snapshotted on its declared
        // boundary, so compatible groups split before crossing one.
        if let checkpoint = pendingRecurrentCheckpointPositions(for: row).first(where: {
            $0 > row.prefillCursor
        }) {
            spanEnd = min(spanEnd, checkpoint)
        }
        let remaining = spanEnd - row.prefillCursor
        guard remaining > 0 else { return row.prefillCursor }
        let chunkLimit = max(1, maxChunkTokens)
        let chunksRemaining = (remaining + chunkLimit - 1) / chunkLimit
        let balancedChunkSize = (remaining + chunksRemaining - 1) / chunksRemaining
        return min(spanEnd, row.prefillCursor + balancedChunkSize)
    }

    private func transitionPrefilledRow(_ row: Row, sampledToken: Int? = nil) async {
        _ = removePromptRow(row.request.id)
        if row.request.maxOutputTokens == 0 {
            await finishTerminal(row, status: .length)
        } else if let sampledToken {
            activeDecode[row.request.id] = row
            CBTrace.log(row.request.id, "sch_active")
            record(.joinedDecode)
            await applyToken(sampledToken, to: row)
        } else {
            // A fully retained prompt has no final-position logits to sample.
            // Fail closed instead of silently reverting to the old P-1 + 1
            // partition that diverges on recurrent hybrid decoders.
            let released = await release(row.handle)
            finish(
                row,
                status: .requestFailed,
                errorCode: released
                    ? "continuous_batching_final_prefill_token_missing"
                    : "continuous_batching_cleanup_failed"
            )
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
        // Every pre-admission completion funnels through here. A cancel recorded
        // while the request was out of `waiting` (mid-admission, e.g. during a
        // retained install) wins over the admission outcome: nothing ran for
        // it, and `requestFailed`/`rejected` would contradict the caller's
        // cancel. A cleanup failure stays visible as such.
        await discardUnacceptedRetainedCache(for: request)
        // Checked after the last await and with none before the result is
        // built, so a cancel recorded during the discard above wins too.
        var status = status
        var errorCode = errorCode
        if status != .cancelled,
           errorCode != "continuous_batching_cleanup_failed",
           cancelledIDs.remove(request.id) != nil {
            status = .cancelled
            errorCode = "request_cancelled"
        }
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
        errorCode: String?,
        serialConversationCache: ContinuousBatchSerialConversationCache? = nil
    ) {
        earlyStopIDs.remove(row.request.id)
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
            retainedCache: nil,
            stopCause: isSuccessful ? row.stopCause : nil,
            serialToolStopTokenCount: isSuccessful
                ? row.request.serialToolStopObserver?.stopTokenCount
                : nil,
            serialConversationCache: isSuccessful ? serialConversationCache : nil,
            nativeMTPCounters: row.nativeMTPCounters
        )
        complete(requestID: row.request.id, result: result)
    }

    private func finish(
        _ row: Row,
        status: ContinuousBatchSchedulerTerminalStatus,
        errorCode: String?,
        retainedCache: ContinuousBatchRetainedCache?
    ) {
        earlyStopIDs.remove(row.request.id)
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
            retainedCache: isSuccessful ? retainedCache : nil,
            stopCause: isSuccessful ? row.stopCause : nil,
            serialToolStopTokenCount: isSuccessful
                ? row.request.serialToolStopObserver?.stopTokenCount
                : nil,
            nativeMTPCounters: row.nativeMTPCounters
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
            guard let recurrentCheckpoints = await terminalRecurrentCheckpoints(
                for: row,
                tokenCount: targetLogicalTokens
            ) else {
                return nil
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
                layers: handoff.caches,
                recurrentCheckpoints: recurrentCheckpoints
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

    /// Checkpoint positions this row still captures: keyed rows only, inside the
    /// prefilled prompt, at most two. The reply-end checkpoint is captured at
    /// terminal separately.
    private func pendingRecurrentCheckpointPositions(for row: Row) -> [Int] {
        guard row.recurrentCheckpoints.count < 2,
              !row.request.conversationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        let prefixTokenCount = row.request.promptTokens.count
        return row.request.recurrentCheckpointPositions.filter { position in
            position > 0 && position <= prefixTokenCount
                && !row.recurrentCheckpoints.contains { $0.tokenCount == position }
        }.sorted()
    }

    /// SPEC-038 FR-CB4 hybrid first turn: at a normal terminal, before the row's
    /// blocks are released, hand back its cache in the serial conversation-cache
    /// format. The row's KV covers the prompt and every sampled token except the
    /// last (never fed back), which is a prefix of the canonical token list the
    /// runtime commits. Best effort: any failure commits nothing.
    private func materializeSerialConversationCache(for row: Row) async -> ContinuousBatchSerialConversationCache? {
        guard row.request.modelHasRecurrentLayers,
              !row.request.conversationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        // A zero-output request commits the whole prompt during prefill. Once
        // generation starts, the final sampled token has not been fed back yet,
        // so the materializable prefix remains prompt + generated - 1.
        let tokenCount = row.generatedTokens.isEmpty
            ? row.request.promptTokens.count
            : row.request.promptTokens.count - 1 + row.generatedTokens.count
        do {
            let binding = try await allocator.binding(for: row.handle)
            guard tokenCount <= binding.currentTable.logicalTokenCount else { return nil }
            guard let recurrentCheckpoints = await terminalRecurrentCheckpoints(for: row, tokenCount: tokenCount) else {
                return nil
            }
            guard !recurrentCheckpoints.isEmpty else { return nil }
            return try await backend.materializeSerialConversationCache(
                requestID: row.request.id,
                binding: binding,
                tokenCount: tokenCount,
                recurrentCheckpoints: recurrentCheckpoints
            )
        } catch {
            return nil
        }
    }

    private func terminalRecurrentCheckpoints(
        for row: Row,
        tokenCount: Int
    ) async -> [RecurrentStateCheckpoint]? {
        var checkpoints = row.recurrentCheckpoints
        guard row.request.modelHasRecurrentLayers,
              (!checkpoints.isEmpty || tokenCount >= ConversationCache.lcpThreshold)
        else {
            return checkpoints
        }
        if checkpoints.contains(where: { $0.tokenCount == tokenCount }) {
            return checkpoints
        }
        guard let checkpoint = await backend.snapshotRecurrentState(
            requestID: row.request.id,
            tokenCount: tokenCount
        ) else {
            return nil
        }
        checkpoints.append(checkpoint)
        return checkpoints.sorted { $0.tokenCount < $1.tokenCount }
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
