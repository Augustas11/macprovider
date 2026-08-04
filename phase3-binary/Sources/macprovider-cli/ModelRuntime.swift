import Foundation
import CryptoKit
import Jinja
import MLX
import MLXLLM
import MLXHuggingFace
import MLXLMCommon
import MacProviderCore
import Tokenizers

protocol ModelRuntimeServing: Actor {
    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult
    /// SPEC-015 §M.2 — return the runtime-owned snapshot that
    /// actually drove inference (validation, in-flight registration,
    /// generation) so the receipt can bind `model_hash` to the
    /// container that served. Atomically captured inside the actor
    /// turn — distinct from a caller-side `currentSnapshot()` sample,
    /// which can drift across an actor interleaving / warm-swap.
    func completeWithServedSnapshot(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> (CompletionResult, RuntimeSnapshot)
    func stream(_ request: ChatCompletionRequest, with handle: RequestHandle, shouldCancel: @escaping @Sendable () -> Bool, onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> CompletionResult
    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws
    func pagedKVPreflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws
    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle
    func unregisterInFlight(_ id: Int)
    func currentSnapshot() async -> RuntimeSnapshot
}

enum StreamChunk: Sendable {
    case content(String)
    case toolCallDelta(StreamToolCallDelta)
}

struct StreamToolCallDelta: Sendable {
    let index: Int
    let id: String?
    let type: String?
    let functionName: String?
    let arguments: String?

    /// OpenAI wire-shape conversion: first delta carries id/type/function.name;
    /// subsequent deltas carry function.arguments fragments. All deltas carry index.
    func openAIDeltaDict() -> [String: Any] {
        var delta: [String: Any] = ["index": index]
        if let id { delta["id"] = id }
        if let type { delta["type"] = type }
        var function: [String: Any] = [:]
        if let functionName { function["name"] = functionName }
        if let arguments { function["arguments"] = arguments }
        if !function.isEmpty { delta["function"] = function }
        return delta
    }
}

final class StructuredStreamingContentAccumulator: @unchecked Sendable {
    private let enabled: Bool
    private let lock = NSLock()
    private var bytes = 0
    private var contentValue = ""
    private var capError: APIError?

    init(enabled: Bool) {
        self.enabled = enabled
    }

    var content: String {
        lock.lock()
        defer { lock.unlock() }
        return contentValue
    }

    var error: APIError? {
        lock.lock()
        defer { lock.unlock() }
        return capError
    }

    @discardableResult
    func append(_ delta: String) -> APIError? {
        guard enabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let capError {
            return capError
        }
        let nextBytes = bytes + delta.utf8.count
        // AC-V2-9b (SPEC-019 v0.2.4 §6): 2 MiB streaming content cap on
        // post-stop-token-filter buyer-visible content delta concatenation.
        guard nextBytes <= ModelRuntime.structuredStreamingValidationBufferByteCap else {
            let error = APIError(
                status: 502,
                message: "Structured streaming content exceeded 2097152 bytes",
                type: "upstream_provider_error",
                code: "response_byte_cap_exceeded",
                inferenceRan: true,
                settlementRan: true
            )
            capError = error
            return error
        }
        bytes = nextBytes
        contentValue += delta
        return nil
    }
}

final class StructuredStreamingIdleState: @unchecked Sendable {
    let enabled: Bool
    private let lock = NSLock()
    private var lastContentAt = Date()
    private var finishedValue = false
    private var timedOutValue = false
    private var operationStoppedValue = false

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func noteContent() {
        guard enabled else { return }
        lock.lock()
        lastContentAt = Date()
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishedValue
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOutValue
    }

    var operationStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return operationStoppedValue
    }

    func hasTimedOut(timeout: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finishedValue && Date().timeIntervalSince(lastContentAt) >= timeout
    }

    func markTimedOut() {
        lock.lock()
        timedOutValue = true
        lock.unlock()
    }

    func markFinished() {
        lock.lock()
        finishedValue = true
        lock.unlock()
    }

    func markOperationStopped() {
        lock.lock()
        operationStoppedValue = true
        lock.unlock()
    }
}

private enum StructuredStreamingIdleRaceResult<T: Sendable>: Sendable {
    case operation(T)
    case idle(T)
}

extension ModelRuntimeServing {
    func pagedKVPreflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        try await preflight(request, with: handle)
    }

    func currentSnapshot() async -> RuntimeSnapshot {
        RuntimeSnapshot(state: .ready, container: nil, modelID: nil, modelHash: nil)
    }

    func complete(_ request: ChatCompletionRequest) async throws -> CompletionResult {
        try await complete(request, shouldCancel: { false })
    }

    /// Convenience default — conformers that don't override get the
    /// served snapshot from `currentSnapshot()` AFTER generation. The
    /// real `ModelRuntime` overrides this to capture the snapshot
    /// inside the actor turn that started inference, which is the
    /// SPEC-015 §M.2.2 atomic-read invariant. Mock/stub runtimes used
    /// in tests can rely on this default safely because they don't
    /// model swaps.
    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        let result = try await complete(request, shouldCancel: shouldCancel)
        let snapshot = await currentSnapshot()
        return (result, snapshot)
    }
}

public struct RuntimeSnapshot: @unchecked Sendable {
    public let state: SwapState
    public let container: ModelContainer?
    public let modelID: String?
    public let modelHash: String?
    public let modelHashAlgorithm: String?
    public let weightsManifestSHA256: String?
    public let weightsManifestAlgorithm: String?
    public let draftModelID: String?
    public let draftTargetModelID: String?
    public let draftContainer: ModelContainer?
    public let numDraftTokens: Int?
    public let specDecodeGeneration: Int

    init(
        state: SwapState,
        container: ModelContainer?,
        modelID: String?,
        modelHash: String?,
        modelHashAlgorithm: String? = nil,
        weightsManifestSHA256: String? = nil,
        weightsManifestAlgorithm: String? = nil,
        draftModelID: String? = nil,
        draftTargetModelID: String? = nil,
        draftContainer: ModelContainer? = nil,
        numDraftTokens: Int? = nil,
        specDecodeGeneration: Int = 0
    ) {
        self.state = state
        self.container = container
        self.modelID = modelID
        self.modelHash = modelHash
        self.modelHashAlgorithm = modelHashAlgorithm
        self.weightsManifestSHA256 = weightsManifestSHA256
        self.weightsManifestAlgorithm = weightsManifestSHA256 == nil
            ? nil
            : (weightsManifestAlgorithm ?? ModelArtifactIdentity.safetensorsManifestV1)
        self.draftModelID = draftModelID
        self.draftTargetModelID = draftTargetModelID
        self.draftContainer = draftContainer
        self.numDraftTokens = numDraftTokens
        self.specDecodeGeneration = specDecodeGeneration
    }

    var hasTargetCompatibleDraft: Bool {
        guard draftModelID != nil, let modelID, numDraftTokens != nil else {
            return false
        }
        return draftTargetModelID == modelID
    }
}

struct PagedKVRuntimeModelCapabilities: Equatable, Sendable {
    let modelFamily: String
    let requiresMoEDispatch: Bool
}

public struct RequestHandle: @unchecked Sendable {
    public let snapshot: RuntimeSnapshot
    public let registrationID: Int
    let drainCancelled: DrainCancelToken
}

public struct WarmSwapDisabledError: Error, CustomStringConvertible {
    public var description: String {
        "warm swap is not enabled (start serve with --enable-warm-swap)"
    }
}

public struct DrainCancelledError: Error { }

struct ModelRuntimeLoadError: Error, CustomStringConvertible {
    let target: String
    let reason: String?

    init(target: String, reason: String? = nil) {
        self.target = target
        self.reason = reason
    }

    var description: String {
        reason ?? "model load target must resolve to a local snapshot directory: \(target)"
    }
}

enum SpecDecodeStartupError: Error, CustomStringConvertible, Equatable {
    case targetRequired
    case tokenizerMismatch
    case probeFailed(String)
    case fixtureMissing
    case fixtureInvalid(String)
    case equivalenceFailed(plain: [Int], speculative: [Int])

    var description: String {
        switch self {
        case .targetRequired:
            return "draft_model_target_required"
        case .tokenizerMismatch:
            return "draft_model_tokenizer_mismatch"
        case .probeFailed(let reason):
            return "draft_model_probe_failed: \(reason)"
        case .fixtureMissing:
            return "draft_model_equivalence_failed: spec028 equivalence fixture missing"
        case .fixtureInvalid(let reason):
            return "draft_model_equivalence_failed: spec028 equivalence fixture invalid: \(reason)"
        case .equivalenceFailed:
            return "draft_model_equivalence_failed"
        }
    }
}

struct InternalWarmupResult: Sendable {
    let tokensGenerated: Int
    let firstTokenElapsedMS: Double
    let totalElapsedMS: Double
}

private struct BlockingGenerateResult: Sendable {
    let tokenIds: [Int]
    let output: String

    var generationTokenCount: Int {
        tokenIds.count
    }

    init(_ result: GenerateResult) {
        self.tokenIds = result.tokenIds
        self.output = result.output
    }
}

private final class BlockingInferenceWork<T>: @unchecked Sendable {
    // Callers keep ModelContainer.perform open while this body runs and must
    // return Sendable summaries so non-Sendable MLX state does not escape.
    let body: () throws -> T

    init(_ body: @escaping () throws -> T) {
        self.body = body
    }
}

private final class BlockingInferenceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class BlockingInferenceExecutor: @unchecked Sendable {
    private let label: String

    init(label: String) {
        self.label = label
    }

    func run<T: Sendable>(_ body: @escaping (BlockingInferenceCancellation) throws -> T) async throws -> T {
        let cancellation = BlockingInferenceCancellation()
        let work = BlockingInferenceWork {
            try body(cancellation)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let label = label
                Thread.detachNewThread {
                    Thread.current.name = label
                    do {
                        if cancellation.isCancelled {
                            throw CancellationError()
                        }
                        continuation.resume(returning: try work.body())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

struct GenerationConfigStopStringFilter: Sendable {
    let stopStrings: [String]
    var buffer = ""
    var stopped = false

    init(stopStrings: Set<String>) {
        self.stopStrings = stopStrings.filter { !$0.isEmpty }.sorted {
            if $0.count == $1.count {
                return $0 < $1
            }
            return $0.count > $1.count
        }
    }

    var isEnabled: Bool {
        !stopStrings.isEmpty
    }

    mutating func process(_ chunk: String) -> (text: String?, stopped: Bool) {
        guard !stopped else {
            return (nil, true)
        }
        guard isEnabled else {
            return (chunk.isEmpty ? nil : chunk, false)
        }

        buffer += chunk
        if let stopRange = earliestStopRange(in: buffer) {
            let text = String(buffer[..<stopRange.lowerBound])
            buffer = ""
            stopped = true
            return (text.isEmpty ? nil : text, true)
        }

        let suffixLength = longestStopPrefixSuffixLength(in: buffer)
        let emitEnd = buffer.index(buffer.endIndex, offsetBy: -suffixLength)
        let text = String(buffer[..<emitEnd])
        buffer = String(buffer[emitEnd...])
        return (text.isEmpty ? nil : text, false)
    }

    mutating func finish() -> String? {
        guard isEnabled, !stopped, !buffer.isEmpty else {
            return nil
        }
        let text = buffer
        buffer = ""
        return text
    }

    private func earliestStopRange(in text: String) -> Range<String.Index>? {
        var earliest: Range<String.Index>?
        for stopString in stopStrings {
            guard let range = text.range(of: stopString) else {
                continue
            }
            if let current = earliest {
                if range.lowerBound < current.lowerBound {
                    earliest = range
                }
            } else {
                earliest = range
            }
        }
        return earliest
    }

    private func longestStopPrefixSuffixLength(in text: String) -> Int {
        var longest = 0
        for stopString in stopStrings {
            let maxLength = Swift.min(text.count, stopString.count - 1)
            guard maxLength > longest else {
                continue
            }
            for length in stride(from: maxLength, through: longest + 1, by: -1) {
                if text.suffix(length) == stopString.prefix(length) {
                    longest = length
                    break
                }
            }
        }
        return longest
    }
}

actor ModelRuntime: ModelRuntimeServing {
    // AC-V2-9b (LOCKED): SPEC-019 v0.2.4 §6 normative 2 MiB streaming
    // content cap. Byte domain is post-stop-token-filter buyer-visible
    // content delta concatenation.
    static let structuredStreamingValidationBufferByteCap = 2_097_152

    // AC-V2-9 N placeholder: SPEC-019 v0.2.4 §10 defers the concrete
    // idle-timeout value to v0.2.x; 60 is the IMPL placeholder.
    static let structuredStreamingIdleTimeoutSeconds: TimeInterval = 60

    enum SpeculativeRoute: Equatable {
        case speculative
        case tokenIterator
    }

    // SPEC-037 FR-KVP1: the tier-eligible KVCacheSimple selection in the serve paths
    // (see `cacheParameters`) never reaches the speculative caches. An eligible
    // cold-tier request always carries a synthetic conversation key (`conv:kvs-synth:`),
    // and `allowsSpeculativeDecoding` is false whenever `conversationKey != nil`
    // (ChatCompletionRequest.allowsSpeculativeDecoding), so such a request is always
    // routed to `.tokenIterator` here — the speculative branch below allocates its own
    // caches and is untouched by the cache-type change.
    static func speculativeRoute(
        for request: ChatCompletionRequest,
        draftLoaded: Bool,
        numDraftTokens: Int?
    ) -> SpeculativeRoute {
        guard !HarmonyResponseParser.isHarmonyModelID(request.model),
              request.allowsSpeculativeDecoding,
              draftLoaded,
              numDraftTokens != nil else {
            return .tokenIterator
        }
        return .speculative
    }

    struct HarmonyTerminalPreservingTokenizer: MLXLMCommon.Tokenizer {
        let base: any MLXLMCommon.Tokenizer

        var bosToken: String? { base.bosToken }

        var eosToken: String? {
            guard let token = base.eosToken,
                  let tokenID = base.convertTokenToId(token),
                  ModelRuntime.isHarmonyTerminalToken(tokenID) else {
                return base.eosToken
            }
            return nil
        }

        var unknownToken: String? { base.unknownToken }

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            base.encode(text: text, addSpecialTokens: addSpecialTokens)
        }

        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            base.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }

        func convertTokenToId(_ token: String) -> Int? {
            base.convertTokenToId(token)
        }

        func convertIdToToken(_ id: Int) -> String? {
            base.convertIdToToken(id)
        }

        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        }
    }

    private var state: SwapState = .ready
    private var targetModelID: String?
    private var currentModelID: String?
    // The model id this runtime was configured to serve (constant across
    // warm-swaps). Used to gate the catalog-id alias so the alias only applies
    // while the configured model is the one currently loaded.
    private let modelID: String?
    // Coordinator-advertised catalog id (e.g. mlx-community/…) accepted as an
    // alias for the configured served model. nil when unset. See BUILD_SPEC
    // relay_serve_model_id_alias.
    private let catalogModelIDAlias: String?
    private var currentContainer: ModelContainer?
    private var currentDraftModelID: String?
    private var currentDraftTargetModelID: String?
    private var currentDraftContainer: ModelContainer?
    private let configuredDraftModelID: String?
    private let configuredDraftModelLoadPath: String?
    private var currentSpecDecodeGeneration = 0
    private let numDraftTokens: Int
    private let stopTokenFilter: StopTokenFilter
    private var currentModelHash: String?
    private var currentModelHashAlgorithm: String?
    private var currentWeightsManifestSHA256: String?
    /// SPEC-037 HIGH-8 — SHA-256 of the loaded model's live tokenizer configuration
    /// and chat-template bytes, hashed at load time. Nil when the tokenizer files are
    /// unreachable, in which case the cold tier treats identity as unavailable and
    /// skips persistence (rather than deriving a fake hash from the model hash).
    private var currentTokenizerConfigSHA256: String?
    private var currentChatTemplateSHA256: String?
    private let verifiedCatalogArtifactSHA256: String?
    /// SPEC-037 FR-KVP4 (MEDIUM-5) — the model's CATALOG REVISION, distinct from the
    /// artifact SHA. FR-KVP4 requires model_sha256 AND catalog revision as SEPARATE
    /// identity fields; a catalog-revision change with unchanged artifact bytes must
    /// disk_miss_envelope, not hit. Nil ⇒ the cold tier treats identity as unavailable
    /// and neither promotes nor persists (never falls back to the artifact SHA).
    private let verifiedModelCatalogRevision: String?
    private let maxContextTokens: Int
    // SPEC-013 autoresearch serving knobs. nil kvBits ⇒ no KV
    // quantization (mlx-swift default). maxBatch defaults to 1, the
    // pre-knob behavior; lifting above 1 widens the autotune search.
    private let kvBitsOverride: Int?
    private let prefillStepSize: Int
    private let pagedKVConfig: PagedKVConfig
    private var pagedKVAttachDecision: PagedKVAttachDecision
    private let conversationCache: ConversationCache
    /// SPEC-037 stage 5 — set once the serve process activates the encrypted disk
    /// cold tier (FR-KVP7). Gates all per-request cold-tier context construction;
    /// false ⇒ the hot path is byte-identical to today (FR-KVP1).
    private var coldTierAttached = false
    private let inferenceGate: AsyncSemaphore
    private let blockingInferenceExecutor: BlockingInferenceExecutor
    private let maxBatch: Int
    private let continuousBatchingMode: ContinuousBatchingMode
    private let continuousBatchQueueLimit: Int?
    private let warmSwapEnabled: Bool
    private let swapDrainTimeoutSeconds: Int
    private var providerStatus: ProviderStatus?
    private var signalContinuations: [UUID: AsyncStream<SwapSignal>.Continuation] = [:]
    private var nextInFlightID: Int = 0
    private var inFlightCancellations: [Int: @Sendable () -> Void] = [:]
    private let loader: @Sendable (String) async throws -> (ModelContainer, String, String?)
    private let testLoader: (@Sendable (String) async throws -> (String, String?))?
    private let testCompletion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)?
    private let testSpeculativeCompletion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)?
    private let testSpeculativeStream: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)?

    var loadedModelID: String? {
        currentModelID
    }

    var loadedModelHash: String? {
        currentModelHash
    }

    var loadedModelHashAlgorithm: String? {
        currentModelHashAlgorithm
    }

    var loadedWeightsManifestSHA256: String? {
        currentWeightsManifestSHA256
    }

    var isLoaded: Bool {
        currentContainer != nil || (testCompletion != nil && currentModelID != nil)
    }

    private nonisolated static func makeServeGenerateParameters(
        maxTokens: Int?,
        maxContextTokens: Int,
        kvBitsOverride: Int?,
        prefillStepSize: Int,
        temperature: Float,
        topP: Float
    ) -> GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            maxKVSize: maxContextTokens,
            kvBits: kvBitsOverride,
            temperature: temperature,
            topP: topP,
            prefillStepSize: prefillStepSize
        )
    }

    /// SPEC-037 FR-KVP1 — cold-tier persistence depends on the serve cache being a
    /// `KVCacheSimple` (the only v1-allowlisted serializable class, KVDiskCacheFormat
    /// `allowlistedCacheClasses`). `LanguageModel.newCache` builds a `RotatingKVCache`
    /// whenever `maxKVSize != nil` and a `KVCacheSimple` only when it is nil (mlx-swift-lm
    /// `LanguageModel.newCache`). `makeServeGenerateParameters` always sets
    /// `maxKVSize = maxContextTokens`, so without this the disk tier's `captureSnapshot`
    /// cast (`layers as? [KVCacheSimple]`) fails and `commit(cold:)` silently no-ops.
    /// For tier-eligible requests we drop `maxKVSize` (→ `KVCacheSimple`); every other
    /// request keeps the rotating cache unchanged. This affects ONLY the explicitly
    /// allocated `newCache`; the `maxKVSize` carried by the `parameters` passed to
    /// `TokenIterator` is ignored once the cache is explicit.
    nonisolated static func cacheParameters(_ base: GenerateParameters, forceSimpleKV: Bool) -> GenerateParameters {
        guard forceSimpleKV else { return base }
        var p = base
        p.maxKVSize = nil
        return p
    }

    /// SPEC-037 FR-KVP1 (MEDIUM-B) — the single serve cache-allocation used at BOTH
    /// serve sites (non-streaming + streaming). Builds the fresh serve `newCache`,
    /// forcing a `KVCacheSimple` for tier-eligible requests (via `cacheParameters`) so
    /// `captureSnapshot`'s `as? [KVCacheSimple]` cast can serialize it, and keeping the
    /// rotating cache for every other request. Extracted so a serve-site regression that
    /// drops the eligibility wrapper (reverting to `newCache(parameters:)`) must change
    /// THIS helper — pinned by `testEligibleServeNewCacheProducesKVCacheSimple` — rather
    /// than passing green via an inlined change at a call site. The serve sites are
    /// one-line delegations; behavior is identical to the previous inline allocation.
    nonisolated static func serveCache(
        model: any LanguageModel, baseParameters: GenerateParameters, eligible: Bool
    ) -> [KVCache] {
        model.newCache(parameters: cacheParameters(baseParameters, forceSimpleKV: eligible))
    }

    nonisolated static func pagedKVAttachDecision(
        config: PagedKVConfig,
        modelID: String?,
        modelHash: String?,
        tokenizerSHA256: String?,
        chatTemplateSHA256: String?,
        kvBitsOverride: Int?,
        runtimeCacheClass: String,
        gates: PagedKVGates,
        modelCapabilities: PagedKVRuntimeModelCapabilities? = nil
    ) -> PagedKVAttachDecision {
        let capabilities = modelCapabilities ?? Self.pagedKVModelCapabilities(modelID: modelID, configJSONData: nil)
        return PagedKVAttachGate.decide(
            config: config,
            runtimeCacheClass: runtimeCacheClass,
            kvBits: kvBitsOverride,
            modelID: modelID ?? "",
            modelSHA256: modelHash ?? "",
            tokenizerSHA256: tokenizerSHA256,
            chatTemplateSHA256: chatTemplateSHA256,
            modelFamily: capabilities.modelFamily,
            requiresMoEDispatch: capabilities.requiresMoEDispatch,
            gates: modelHash?.isEmpty == false ? gates : .closed
        )
    }

    private nonisolated static func pagedKVRuntimeCapabilityDecision(
        config: PagedKVConfig,
        modelID: String?,
        modelHash: String?,
        tokenizerSHA256: String?,
        chatTemplateSHA256: String?,
        kvBitsOverride: Int?,
        runtimeCacheClass: String,
        modelCapabilities: PagedKVRuntimeModelCapabilities? = nil
    ) -> PagedKVAttachDecision {
        let cacheClassForDecision = runtimeCacheClass == Self.pagedKVUnavailableCacheClass
            ? PagedKVAttachGate.allowedCacheClasses[0]
            : runtimeCacheClass
        return pagedKVAttachDecision(
            config: config,
            modelID: modelID,
            modelHash: modelHash,
            tokenizerSHA256: tokenizerSHA256,
            chatTemplateSHA256: chatTemplateSHA256,
            kvBitsOverride: kvBitsOverride,
            runtimeCacheClass: cacheClassForDecision,
            gates: .runtimeClosed(identityAvailable: modelHash?.isEmpty == false),
            modelCapabilities: modelCapabilities
        )
    }

    private static let pagedKVUnavailableCacheClass = "unavailable"

    private static func pagedKVRuntimeCacheClass(
        container: ModelContainer?,
        maxContextTokens: Int,
        kvBitsOverride: Int?,
        prefillStepSize: Int
    ) async -> String {
        guard let container else { return Self.pagedKVUnavailableCacheClass }
        do {
            return try await container.perform { context in
                let parameters = Self.makeServeGenerateParameters(
                    maxTokens: 1,
                    maxContextTokens: maxContextTokens,
                    kvBitsOverride: kvBitsOverride,
                    prefillStepSize: prefillStepSize,
                    temperature: 0.0,
                    topP: 1.0
                )
                return Self.pagedKVRuntimeCacheClass(model: context.model, baseParameters: parameters)
            }
        } catch {
            return Self.pagedKVUnavailableCacheClass
        }
    }

    nonisolated static func pagedKVRuntimeCacheClass(model: any LanguageModel, baseParameters: GenerateParameters) -> String {
        let caches = model.newCache(parameters: baseParameters)
        guard let first = caches.first else { return "empty" }
        let firstClass = String(describing: type(of: first))
        guard caches.allSatisfy({ String(describing: type(of: $0)) == firstClass }) else {
            return "mixed"
        }
        return firstClass
    }

    nonisolated static func pagedKVModelFamily(_ modelID: String?) -> String {
        let lower = modelID?.lowercased() ?? ""
        if lower.contains("qwen") { return "qwen" }
        if lower.contains("llama") { return "llama" }
        return "unknown"
    }

    nonisolated static func pagedKVModelCapabilities(
        modelID: String?,
        configJSONData: Data?
    ) -> PagedKVRuntimeModelCapabilities {
        PagedKVRuntimeModelCapabilities(
            modelFamily: Self.pagedKVModelFamily(modelID),
            requiresMoEDispatch: (configJSONData.flatMap(Self.pagedKVConfigRequiresMoE) ?? false)
                || Self.pagedKVModelIDLooksLikeExpertModel(modelID)
        )
    }

    private static func pagedKVModelCapabilities(
        modelID: String?,
        directory: URL
    ) -> PagedKVRuntimeModelCapabilities {
        let configData = try? Data(contentsOf: directory.appendingPathComponent("config.json"))
        return Self.pagedKVModelCapabilities(modelID: modelID, configJSONData: configData)
    }

    private nonisolated static func pagedKVConfigRequiresMoE(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        var labels: [String] = []
        if let modelType = object["model_type"] as? String { labels.append(modelType) }
        if let architectures = object["architectures"] as? [String] { labels.append(contentsOf: architectures) }
        if labels.contains(where: { $0.localizedCaseInsensitiveContains("moe") }) {
            return true
        }
        let expertKeys = [
            "num_experts",
            "n_routed_experts",
            "num_local_experts",
            "num_experts_per_tok",
            "moe_intermediate_size",
        ]
        return expertKeys.contains { key in
            if let value = object[key] as? Int { return value > 1 }
            if let value = object[key] as? NSNumber { return value.intValue > 1 }
            return false
        }
    }

    private nonisolated static func pagedKVModelIDLooksLikeExpertModel(_ modelID: String?) -> Bool {
        guard let modelID else { return false }
        let lower = modelID.lowercased()
        if lower.contains("mixtral") || lower.contains("moe") { return true }
        return lower.range(of: #"(^|[-_/])a[0-9]+b($|[-_/])"#, options: .regularExpression) != nil
    }

    nonisolated static func logPagedKVAttachDecision(_ decision: PagedKVAttachDecision) {
        switch decision {
        case .disabled, .attached:
            return
        case .fallback(let reason):
            FileHandle.standardError.write(Data(("event=paged_kv_attach status=fallback reason=\(reason.rawValue)\n").utf8))
        case .rejected(let reason):
            FileHandle.standardError.write(Data(("event=paged_kv_attach status=rejected reason=\(reason.rawValue)\n").utf8))
        }
    }

    nonisolated static func enforcePagedKVPreflight(_ decision: PagedKVAttachDecision) throws {
        if case .attached = decision {
            // This IMPL installs the default-off contract and attach gate only. Serving
            // still requires a runtime owner that reserves a request lease, injects
            // PagedKVCache, and releases/retains the handle around TokenIterator.
            throw APIError(
                status: 503,
                message: "Inference engine unavailable",
                type: "server_error",
                code: "internal_error",
                inferenceRan: false,
                settlementRan: false
            )
        }
        if case .rejected = decision {
            throw APIError(
                status: 503,
                message: "Inference engine unavailable",
                type: "server_error",
                code: "internal_error",
                inferenceRan: false,
                settlementRan: false
            )
        }
    }

    private nonisolated static func harmonyTerminalPreservingContext(
        from context: ModelContext,
        modelID: String
    ) -> ModelContext {
        guard HarmonyResponseParser.isHarmonyModelID(modelID) else {
            return context
        }
        var generationContext = context
        generationContext.configuration.eosTokenIds.remove(HarmonyResponseParser.returnTokenID)
        generationContext.configuration.eosTokenIds.remove(HarmonyResponseParser.callTokenID)
        generationContext.configuration.extraEOSTokens.remove("<|return|>")
        generationContext.configuration.extraEOSTokens.remove("<|call|>")
        generationContext.configuration.stopStrings?.remove("<|return|>")
        generationContext.configuration.stopStrings?.remove("<|call|>")
        generationContext.tokenizer = HarmonyTerminalPreservingTokenizer(base: context.tokenizer)
        return generationContext
    }

    private nonisolated static func isHarmonyTerminalToken(_ tokenID: Int) -> Bool {
        tokenID == HarmonyResponseParser.returnTokenID || tokenID == HarmonyResponseParser.callTokenID
    }

    static func isHarmonyTerminalFinish(modelID: String, generatedTokenIDs: [Int]) -> Bool {
        HarmonyResponseParser.isHarmonyModelID(modelID)
            && generatedTokenIDs.last.map(isHarmonyTerminalToken) == true
    }

    init(
        modelID: String?,
        modelLoadPath: String? = nil,
        draftModelID: String? = nil,
        draftModelLoadPath: String? = nil,
        numDraftTokens: Int = 3,
        maxContextTokensOverride: Int? = nil,
        kvBitsOverride: Int? = nil,
        pagedKVConfig: PagedKVConfig = .defaults(),
        prefillStepSize: Int = 512,
        maxBatch: Int = 1,
        continuousBatchingMode: ContinuousBatchingMode = .off,
        continuousBatchQueueLimit: Int? = nil,
        warmSwapEnabled: Bool = false,
        swapDrainTimeoutSeconds: Int = 30,
        catalogModelIDAlias: String? = nil,
        verifiedModelArtifactSHA256: String? = nil,
        verifiedModelCatalogRevision: String? = nil
    ) async throws {
        let normalizedDraftModelID = Self.nonEmpty(draftModelID)
        let normalizedDraftModelLoadPath = Self.nonEmpty(draftModelLoadPath)
        self.modelID = modelID
        self.catalogModelIDAlias = catalogModelIDAlias
        self.currentModelID = modelID
        self.currentDraftModelID = nil
        self.currentDraftTargetModelID = nil
        self.currentDraftContainer = nil
        self.configuredDraftModelID = normalizedDraftModelID
        self.configuredDraftModelLoadPath = normalizedDraftModelLoadPath
        self.numDraftTokens = numDraftTokens
        self.maxContextTokens = maxContextTokensOverride ?? Self.defaultMaxContextTokens()
        self.kvBitsOverride = kvBitsOverride
        self.prefillStepSize = max(1, prefillStepSize)
        self.pagedKVConfig = pagedKVConfig
        self.pagedKVAttachDecision = Self.pagedKVRuntimeCapabilityDecision(
            config: pagedKVConfig,
            modelID: modelID,
            modelHash: verifiedModelArtifactSHA256,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            kvBitsOverride: kvBitsOverride,
            runtimeCacheClass: Self.pagedKVUnavailableCacheClass
        )
        self.conversationCache = ConversationCache()
        let boundedMaxBatch = min(max(1, maxBatch), ProviderCapacity.maxConcurrencyOverrideLimit)
        self.maxBatch = boundedMaxBatch
        self.inferenceGate = AsyncSemaphore(value: boundedMaxBatch)
        self.blockingInferenceExecutor = BlockingInferenceExecutor(label: "live.streamvc.macprovider.inference")
        self.continuousBatchingMode = continuousBatchingMode
        self.continuousBatchQueueLimit = continuousBatchQueueLimit
        self.warmSwapEnabled = warmSwapEnabled
        self.swapDrainTimeoutSeconds = swapDrainTimeoutSeconds
        self.verifiedCatalogArtifactSHA256 = verifiedModelArtifactSHA256
        self.verifiedModelCatalogRevision = verifiedModelCatalogRevision
        self.loader = { targetModelID in
            let (container, directory) = try await Self.loadLocalContainer(from: targetModelID)
            let modelHash = try? ModelArtifactVerifier.canonicalArtifactHash(directory: directory)
            return (container, targetModelID, modelHash)
        }
        self.testLoader = nil
        self.testCompletion = nil
        self.testSpeculativeCompletion = nil
        self.testSpeculativeStream = nil

        guard let modelID else {
            self.currentContainer = nil
            self.stopTokenFilter = StopTokenFilter(tokens: [])
            self.currentModelHash = nil
            self.currentModelHashAlgorithm = nil
            self.currentWeightsManifestSHA256 = nil
            self.currentTokenizerConfigSHA256 = nil
            self.currentChatTemplateSHA256 = nil
            if normalizedDraftModelID != nil {
                throw SpecDecodeStartupError.targetRequired
            }
            return
        }

        let (container, directory) = try await Self.loadLocalContainer(from: modelLoadPath ?? modelID)
        if let expectedArtifactHash = verifiedModelArtifactSHA256 {
            let loadedArtifactHash = try? ModelArtifactVerifier.canonicalArtifactHash(directory: directory)
            guard loadedArtifactHash == expectedArtifactHash else {
                let observedArtifactHash = loadedArtifactHash ?? "unavailable"
                throw ModelRuntimeLoadError(
                    target: directory.path,
                    reason: "verified model artifact changed during load: expected \(expectedArtifactHash), observed \(observedArtifactHash)"
                )
            }
        }
        self.currentContainer = container

        let tokenizerConfigURL = directory.appendingPathComponent("tokenizer_config.json")
        if FileManager.default.fileExists(atPath: tokenizerConfigURL.path) {
            self.stopTokenFilter = try StopTokenConfigExtractor.extract(fromTokenizerConfigAt: tokenizerConfigURL)
        } else {
            self.stopTokenFilter = StopTokenFilter(tokens: [])
        }
        self.currentModelHash = verifiedModelArtifactSHA256
        self.currentModelHashAlgorithm = verifiedModelArtifactSHA256 == nil
            ? nil
            : ModelArtifactIdentity.snapshotManifestV1
        self.currentWeightsManifestSHA256 = try? Self.modelWeightArtifactManifestHash(in: directory)
        let tokenizerHashes = Self.tokenizerIdentityHashes(in: directory)
        self.currentTokenizerConfigSHA256 = tokenizerHashes.config
        self.currentChatTemplateSHA256 = tokenizerHashes.template
        let runtimeCacheClass = self.pagedKVConfig.effectiveEnabled
            ? await Self.pagedKVRuntimeCacheClass(
                container: container,
                maxContextTokens: self.maxContextTokens,
                kvBitsOverride: self.kvBitsOverride,
                prefillStepSize: self.prefillStepSize
            )
            : Self.pagedKVUnavailableCacheClass
        let modelCapabilities = Self.pagedKVModelCapabilities(modelID: modelID, directory: directory)
        self.pagedKVAttachDecision = Self.pagedKVRuntimeCapabilityDecision(
            config: self.pagedKVConfig,
            modelID: modelID,
            modelHash: self.currentModelHash,
            tokenizerSHA256: tokenizerHashes.config,
            chatTemplateSHA256: tokenizerHashes.template,
            kvBitsOverride: self.kvBitsOverride,
            runtimeCacheClass: runtimeCacheClass,
            modelCapabilities: modelCapabilities
        )
        Self.logPagedKVAttachDecision(self.pagedKVAttachDecision)

        if let draftModelID = normalizedDraftModelID {
            let (draftContainer, draftDirectory) = try await Self.loadLocalContainer(from: normalizedDraftModelLoadPath ?? draftModelID)
            try await Self.validateTokenizerCompatibility(
                target: container,
                targetDirectory: directory,
                draft: draftContainer,
                draftDirectory: draftDirectory
            )
            try await Self.runSpeculativeStartupProbe(
                target: container,
                draft: draftContainer,
                numDraftTokens: 1,
                maxContextTokens: self.maxContextTokens,
                kvBitsOverride: self.kvBitsOverride,
                prefillStepSize: self.prefillStepSize,
                blockingInferenceExecutor: self.blockingInferenceExecutor
            )
            try await Self.runSpeculativeEquivalenceCanary(
                target: container,
                draft: draftContainer,
                targetModelID: modelID,
                numDraftTokens: numDraftTokens,
                maxContextTokens: self.maxContextTokens,
                kvBitsOverride: self.kvBitsOverride,
                prefillStepSize: self.prefillStepSize,
                blockingInferenceExecutor: self.blockingInferenceExecutor
            )
            self.currentDraftModelID = draftModelID
            self.currentDraftTargetModelID = modelID
            self.currentDraftContainer = draftContainer
        }
    }

    init(
        modelID: String?,
        modelHash: String? = nil,
        modelHashAlgorithm: String? = nil,
        weightsManifestSHA256: String? = nil,
        draftModelID: String? = nil,
        numDraftTokens: Int = 3,
        maxContextTokensOverride: Int? = nil,
        kvBitsOverride: Int? = nil,
        pagedKVConfig: PagedKVConfig = .defaults(),
        prefillStepSize: Int = 512,
        maxBatch: Int = 1,
        continuousBatchingMode: ContinuousBatchingMode = .off,
        continuousBatchQueueLimit: Int? = nil,
        warmSwapEnabled: Bool,
        swapDrainTimeoutSeconds: Int = 30,
        providerStatus: ProviderStatus? = nil,
        catalogModelIDAlias: String? = nil,
        loader: @escaping @Sendable (String) async throws -> (ModelContainer, String, String?),
        testLoader: (@Sendable (String) async throws -> (String, String?))? = nil,
        testCompletion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)? = nil,
        testSpeculativeCompletion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)? = nil,
        testSpeculativeStream: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)? = nil
    ) {
        let normalizedDraftModelID = Self.nonEmpty(draftModelID)
        self.modelID = modelID
        self.catalogModelIDAlias = catalogModelIDAlias
        self.currentModelID = modelID
        self.currentContainer = nil
        self.currentDraftModelID = normalizedDraftModelID
        self.currentDraftTargetModelID = normalizedDraftModelID == nil ? nil : modelID
        self.currentDraftContainer = nil
        self.configuredDraftModelID = normalizedDraftModelID
        self.configuredDraftModelLoadPath = nil
        self.numDraftTokens = numDraftTokens
        self.currentModelHash = modelHash
        self.currentModelHashAlgorithm = modelHashAlgorithm
        self.currentWeightsManifestSHA256 = weightsManifestSHA256
        self.currentTokenizerConfigSHA256 = nil
        self.currentChatTemplateSHA256 = nil
        self.verifiedCatalogArtifactSHA256 = nil
        self.verifiedModelCatalogRevision = nil
        self.stopTokenFilter = StopTokenFilter(tokens: [])
        self.maxContextTokens = maxContextTokensOverride ?? Self.defaultMaxContextTokens()
        self.kvBitsOverride = kvBitsOverride
        self.prefillStepSize = max(1, prefillStepSize)
        self.pagedKVConfig = pagedKVConfig
        self.pagedKVAttachDecision = Self.pagedKVRuntimeCapabilityDecision(
            config: pagedKVConfig,
            modelID: modelID,
            modelHash: modelHash,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            kvBitsOverride: kvBitsOverride,
            runtimeCacheClass: Self.pagedKVUnavailableCacheClass
        )
        self.conversationCache = ConversationCache()
        let boundedMaxBatch = min(max(1, maxBatch), ProviderCapacity.maxConcurrencyOverrideLimit)
        self.maxBatch = boundedMaxBatch
        self.inferenceGate = AsyncSemaphore(value: boundedMaxBatch)
        self.blockingInferenceExecutor = BlockingInferenceExecutor(label: "live.streamvc.macprovider.inference")
        self.continuousBatchingMode = continuousBatchingMode
        self.continuousBatchQueueLimit = continuousBatchQueueLimit
        self.warmSwapEnabled = warmSwapEnabled
        self.swapDrainTimeoutSeconds = swapDrainTimeoutSeconds
        self.providerStatus = providerStatus
        self.loader = loader
        self.testLoader = testLoader
        self.testCompletion = testCompletion
        self.testSpeculativeCompletion = testSpeculativeCompletion
        self.testSpeculativeStream = testSpeculativeStream
    }

    func setProviderStatus(_ providerStatus: ProviderStatus) {
        self.providerStatus = providerStatus
    }

    func currentSnapshot() async -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: state,
            container: currentContainer,
            modelID: currentModelID,
            modelHash: currentModelHash,
            modelHashAlgorithm: currentModelHashAlgorithm,
            weightsManifestSHA256: currentWeightsManifestSHA256,
            draftModelID: currentDraftModelID,
            draftTargetModelID: currentDraftTargetModelID,
            draftContainer: currentDraftContainer,
            numDraftTokens: currentDraftModelID == nil ? nil : numDraftTokens,
            specDecodeGeneration: currentSpecDecodeGeneration
        )
    }

    private func requestStartSnapshot() -> RuntimeSnapshot {
        if state == .loading {
            return RuntimeSnapshot(
                state: .ready,
                container: currentContainer,
                modelID: currentModelID,
                modelHash: currentModelHash,
                modelHashAlgorithm: currentModelHashAlgorithm,
                weightsManifestSHA256: currentWeightsManifestSHA256,
                draftModelID: nil,
                draftTargetModelID: nil,
                draftContainer: nil,
                numDraftTokens: nil,
                specDecodeGeneration: currentSpecDecodeGeneration
            )
        }
        return RuntimeSnapshot(
            state: state,
            container: currentContainer,
            modelID: currentModelID,
            modelHash: currentModelHash,
            modelHashAlgorithm: currentModelHashAlgorithm,
            weightsManifestSHA256: currentWeightsManifestSHA256,
            draftModelID: currentDraftModelID,
            draftTargetModelID: currentDraftTargetModelID,
            draftContainer: currentDraftContainer,
            numDraftTokens: currentDraftModelID == nil ? nil : numDraftTokens,
            specDecodeGeneration: currentSpecDecodeGeneration
        )
    }

    func swapSignals() -> AsyncStream<SwapSignal> {
        let pair = AsyncStream<SwapSignal>.makeStream(of: SwapSignal.self)
        let id = UUID()
        signalContinuations[id] = pair.continuation
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSignalContinuation(id) }
        }
        return pair.stream
    }

    func beginSwap(targetModelID: String) async throws -> Task<Void, Error> {
        guard warmSwapEnabled else { throw WarmSwapDisabledError() }
        try transitionToLoading(target: targetModelID)
        let drainTimeoutSeconds = swapDrainTimeoutSeconds
        let providerStatus = providerStatus
        let testLoader = testLoader
        let configuredDraftModelID = configuredDraftModelID
        let configuredDraftModelLoadPath = configuredDraftModelLoadPath
        let numDraftTokens = numDraftTokens
        let maxContextTokens = maxContextTokens
        let kvBitsOverride = kvBitsOverride
        let prefillStepSize = prefillStepSize
        return Task.detached { [weak self, testLoader, drainTimeoutSeconds, providerStatus, configuredDraftModelID, configuredDraftModelLoadPath, numDraftTokens, maxContextTokens, kvBitsOverride, prefillStepSize] in
            guard let self else { return }
            do {
                let container: ModelContainer?
                let modelID: String
                let modelHash: String?
                let modelHashAlgorithm: String?
                let weightsManifestSHA256: String?
                let tokenizerConfigSHA256: String?
                let chatTemplateSHA256: String?
                let modelCapabilities: PagedKVRuntimeModelCapabilities
                let draftModelID: String?
                let draftContainer: ModelContainer?
                let draftFailureReason: String?
                if let testLoader {
                    let loaded = try await testLoader(targetModelID)
                    container = nil
                    modelID = loaded.0
                    modelHash = loaded.1
                    modelHashAlgorithm = await self.currentModelHashAlgorithm
                    weightsManifestSHA256 = nil
                    tokenizerConfigSHA256 = nil
                    chatTemplateSHA256 = nil
                    modelCapabilities = Self.pagedKVModelCapabilities(modelID: modelID, configJSONData: nil)
                    if let configuredDraftModelID {
                        do {
                            let loadedDraft = try await testLoader(configuredDraftModelID)
                            draftModelID = loadedDraft.0
                            draftContainer = nil
                            draftFailureReason = nil
                        } catch {
                            draftModelID = nil
                            draftContainer = nil
                            draftFailureReason = Self.draftSwapFailureReason(for: error)
                        }
                    } else {
                        draftModelID = nil
                        draftContainer = nil
                        draftFailureReason = nil
                    }
                } else {
                    let loaded = try await Self.loadLocalContainer(from: targetModelID)
                    container = loaded.0
                    modelID = targetModelID
                    guard let expected = self.verifiedCatalogArtifactSHA256,
                          await self.isConfiguredCatalogModel(targetModelID),
                          (try? ModelArtifactVerifier.canonicalArtifactHash(directory: loaded.1)) == expected
                    else {
                        throw ModelRuntimeLoadError(target: "signed catalog identity unavailable for \(targetModelID)")
                    }
                    modelHash = expected
                    modelHashAlgorithm = ModelArtifactIdentity.snapshotManifestV1
                    weightsManifestSHA256 = try? Self.modelWeightArtifactManifestHash(in: loaded.1)
                    let swapTokenizerHashes = Self.tokenizerIdentityHashes(in: loaded.1)
                    tokenizerConfigSHA256 = swapTokenizerHashes.config
                    chatTemplateSHA256 = swapTokenizerHashes.template
                    modelCapabilities = Self.pagedKVModelCapabilities(modelID: modelID, directory: loaded.1)
                    if let configuredDraftModelID {
                        do {
                            let draftLoaded = try await Self.loadLocalContainer(from: configuredDraftModelLoadPath ?? configuredDraftModelID)
                            try await Self.validateTokenizerCompatibility(
                                target: loaded.0,
                                targetDirectory: loaded.1,
                                draft: draftLoaded.0,
                                draftDirectory: draftLoaded.1
                            )
                            try await Self.runSpeculativeStartupProbe(
                                target: loaded.0,
                                draft: draftLoaded.0,
                                numDraftTokens: 1,
                                maxContextTokens: maxContextTokens,
                                kvBitsOverride: kvBitsOverride,
                                prefillStepSize: prefillStepSize,
                                blockingInferenceExecutor: blockingInferenceExecutor
                            )
                            try await Self.runSpeculativeEquivalenceCanary(
                                target: loaded.0,
                                draft: draftLoaded.0,
                                targetModelID: modelID,
                                numDraftTokens: numDraftTokens,
                                maxContextTokens: maxContextTokens,
                                kvBitsOverride: kvBitsOverride,
                                prefillStepSize: prefillStepSize,
                                blockingInferenceExecutor: blockingInferenceExecutor
                            )
                            draftModelID = configuredDraftModelID
                            draftContainer = draftLoaded.0
                            draftFailureReason = nil
                        } catch {
                            draftModelID = nil
                            draftContainer = nil
                            draftFailureReason = Self.draftSwapFailureReason(for: error)
                        }
                    } else {
                        draftModelID = nil
                        draftContainer = nil
                        draftFailureReason = nil
                    }
                }
                try await self.enterDrainPhase()
                let didTimeout = await self.waitForDrainOrTimeout(providerStatus: providerStatus, timeoutSeconds: drainTimeoutSeconds)
                if didTimeout {
                    await self.cancelAllInFlightForDrainTimeout()
                    // Cancellation is only a request to stop old-generation
                    // work, not proof that the old container is quiescent.
                    // Keep the old snapshot installed and fail this swap.
                    throw DrainCancelledError()
                }
                await self.completeSwapAtomically(
                    container: container,
                    modelID: modelID,
                    modelHash: modelHash,
                    modelHashAlgorithm: modelHashAlgorithm,
                    weightsManifestSHA256: weightsManifestSHA256,
                    tokenizerConfigSHA256: tokenizerConfigSHA256,
                    chatTemplateSHA256: chatTemplateSHA256,
                    draftModelID: draftModelID,
                    draftContainer: draftContainer,
                    draftFailureReason: draftFailureReason,
                    modelCapabilities: modelCapabilities
                )
            } catch {
                await self.failSwap(reason: String(describing: error))
            }
        }
    }

    nonisolated func swapDrainTimeoutForTest() -> Int {
        swapDrainTimeoutSeconds
    }

    // SPEC-013 autoresearch serving knobs: test-only accessors so test
    // suites can confirm CLI flag values reached the runtime.
    func kvBitsOverrideForTest() -> Int? {
        kvBitsOverride
    }

    func pagedKVDecisionForTest() -> PagedKVAttachDecision {
        pagedKVAttachDecision
    }

    func maxBatchForTest() -> Int {
        maxBatch
    }

    func continuousBatchingCapabilityForTest(stickyCacheEligible: Bool = false) -> ContinuousBatchingCapability {
        continuousBatchingCapability(
            draftConfigured: currentDraftModelID != nil,
            stickyCacheEligible: stickyCacheEligible
        )
    }

    private func continuousBatchingCapability(
        draftConfigured: Bool,
        stickyCacheEligible: Bool,
        requestStateRepresentable: Bool = true
    ) -> ContinuousBatchingCapability {
        // The independently observed runtime tuple and scheduler backend are
        // installed by the deferred SPEC-039 engine bridge. Do not manufacture
        // a self-fulfilling tuple from the advertised descriptor.
        let requestedTuple: ContinuousBatchingRequestedTuple? = nil
        return ContinuousBatchingPolicy.capability(
            mode: continuousBatchingMode,
            maxBatch: maxBatch,
            queueLimit: continuousBatchQueueLimit,
            kvBits: kvBitsOverride,
            draftConfigured: draftConfigured,
            stickyCacheEligible: stickyCacheEligible,
            requestStateRepresentable: requestStateRepresentable,
            schedulerBackendAvailable: false,
            pagedKVDecision: pagedKVAttachDecision,
            requestedTuple: requestedTuple
        )
    }

    /// A request is representable by the batched shared-forward contract only if
    /// its generation is fully described by the scalar sampling parameters the
    /// contract carries. Structured-output/grammar validation, tool-constrained
    /// decoding, logit_bias, and logprobs all impose row-local decoder state the
    /// contract does not model, so such requests must serial-route (canary) / fail
    /// closed (strict) before admission — a gate that holds even after the deferred
    /// SPEC-039 bridge lands, so a future backend cannot silently drop that state.
    static func requestStateRepresentable(_ request: ChatCompletionRequest) -> Bool {
        // Structured-output / grammar-constrained decoding.
        if requiresStructuredValidation(request.responseFormat) { return false }
        // Tool-bearing requests carry tool schemas + tool-call parser state.
        // hasEnabledTools treats an absent, explicit-null, or empty tools array as
        // no-tools, so a bare or explicit-null `tool_choice` does not false-positive
        // here (the meaningful signal is whether tools are actually enabled).
        if hasEnabledTools(request.promptSource.tools) { return false }
        // logit_bias and logprobs (incl. top_logprobs metadata) have no carrier in
        // the scheduler row contract. top_logprobs only shapes response metadata,
        // not token selection, but is rejected here too so the gate is provably
        // complete and no per-request logprob surface can reach a batch unrepresented.
        if isActiveJSONValue(request.promptSource.logitBias) { return false }
        if isRequestedLogprobs(request.promptSource.logprobs) { return false }
        if isActiveJSONValue(request.promptSource.topLogprobs) { return false }
        return true
    }

    /// True when a JSON field is present and not explicit null. `optionalJSONValue`
    /// preserves JSON `null` as `.null`, so a bare `!= nil` check would misclassify
    /// an explicit-null field as active.
    static func isActiveJSONValue(_ value: MacProviderCore.JSONValue?) -> Bool {
        guard let value else { return false }
        if case .null = value { return false }
        return true
    }

    /// True when logprobs are actually requested. Absent, null, or `false` are not
    /// requests and must not force serial routing.
    static func isRequestedLogprobs(_ value: MacProviderCore.JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null, .bool(false):
            return false
        default:
            return true
        }
    }

    private func applyContinuousBatchingPolicy(
        request: ChatCompletionRequest,
        snapshot: RuntimeSnapshot,
        emitTelemetry: Bool = true
    ) throws {
        let capability = continuousBatchingCapability(
            draftConfigured: snapshot.hasTargetCompatibleDraft || currentDraftModelID != nil,
            // v0.2 admits keyless fresh requests only. A conversation key is
            // conservatively treated as sticky/cross-turn until the cache
            // bridge can prove that it has no reusable state.
            stickyCacheEligible: request.conversationKey != nil,
            requestStateRepresentable: Self.requestStateRepresentable(request)
        )
        // Telemetry is emitted once per request at preflight; execution paths
        // re-validate for fail-closed safety but must not re-log the same
        // serial-route event (avoids double-counting canary promotion evidence).
        if emitTelemetry {
            ContinuousBatchingPolicy.logSerialRouteIfNeeded(capability)
        }
        try ContinuousBatchingPolicy.validateStrictStartup(capability)
    }

    func maxContextTokensForTest() -> Int {
        maxContextTokens
    }

    #if DEBUG
    func runBlockingInferenceProbeForTest(milliseconds: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000.0)
        try await blockingInferenceExecutor.run { inferenceCancellation in
            while Date() < deadline {
                if inferenceCancellation.isCancelled {
                    throw CancellationError()
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }
    #endif

    func draftModelIDForTest() -> String? {
        currentDraftModelID
    }

    func numDraftTokensForTest() -> Int {
        numDraftTokens
    }

    private func transitionToLoading(target: String) throws {
        guard state == .ready else {
            throw RuntimeStateMachineError.notReady(current: state)
        }
        state = .loading
        targetModelID = target
    }

    private func enterDrainPhase() throws {
        guard state == .loading else {
            throw RuntimeStateMachineError.notReady(current: state)
        }
        state = .draining
        signal(SwapSignal(targetModelID: targetModelID ?? "", outcome: .loadFinished))
    }

    private func waitForDrainOrTimeout(providerStatus: ProviderStatus?, timeoutSeconds: Int) async -> Bool {
        guard let providerStatus else {
            return false
        }
        let drainStartMs = Int64(Date().timeIntervalSince1970 * 1000)
        let timeoutMs = Int64(timeoutSeconds * 1000)
        while !Task.isCancelled {
            let snapshot = await providerStatus.snapshot()
            let providerInFlight = snapshot.requestsInFlight > 0
            let runtimeInFlight = !inFlightCancellations.isEmpty
            if !providerInFlight && !runtimeInFlight {
                return false
            }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if nowMs - drainStartMs >= timeoutMs {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func completeSwapAtomically(container: ModelContainer?, modelID: String, modelHash: String?) async {
        await completeSwapAtomically(
            container: container,
            modelID: modelID,
            modelHash: modelHash,
            modelHashAlgorithm: nil,
            weightsManifestSHA256: nil,
            tokenizerConfigSHA256: nil,
            chatTemplateSHA256: nil,
            draftModelID: nil,
            draftContainer: nil,
            draftFailureReason: nil,
            modelCapabilities: Self.pagedKVModelCapabilities(modelID: modelID, configJSONData: nil)
        )
    }

    private func completeSwapAtomically(
        container: ModelContainer?,
        modelID: String,
        modelHash: String?,
        modelHashAlgorithm: String?,
        weightsManifestSHA256: String?,
        tokenizerConfigSHA256: String?,
        chatTemplateSHA256: String?,
        draftModelID: String?,
        draftContainer: ModelContainer?,
        draftFailureReason: String?,
        modelCapabilities: PagedKVRuntimeModelCapabilities
    ) async {
        let target = targetModelID ?? modelID
        currentContainer = container
        currentModelID = modelID
        currentModelHash = modelHash
        currentModelHashAlgorithm = modelHash == nil ? nil : modelHashAlgorithm
        currentWeightsManifestSHA256 = weightsManifestSHA256
        currentTokenizerConfigSHA256 = tokenizerConfigSHA256
        currentChatTemplateSHA256 = chatTemplateSHA256
        let runtimeCacheClass = pagedKVConfig.effectiveEnabled
            ? await Self.pagedKVRuntimeCacheClass(
                container: container,
                maxContextTokens: maxContextTokens,
                kvBitsOverride: kvBitsOverride,
                prefillStepSize: prefillStepSize
            )
            : Self.pagedKVUnavailableCacheClass
        pagedKVAttachDecision = Self.pagedKVRuntimeCapabilityDecision(
            config: pagedKVConfig,
            modelID: modelID,
            modelHash: modelHash,
            tokenizerSHA256: tokenizerConfigSHA256,
            chatTemplateSHA256: chatTemplateSHA256,
            kvBitsOverride: kvBitsOverride,
            runtimeCacheClass: runtimeCacheClass,
            modelCapabilities: modelCapabilities
        )
        Self.logPagedKVAttachDecision(pagedKVAttachDecision)
        currentDraftModelID = draftModelID
        currentDraftTargetModelID = draftModelID == nil ? nil : modelID
        currentDraftContainer = draftContainer
        currentSpecDecodeGeneration += 1
        state = .ready
        targetModelID = nil
        if let draftFailureReason {
            Self.logDraftSwapFailure(
                targetModelID: modelID,
                draftModelID: configuredDraftModelID,
                reason: draftFailureReason
            )
        }
        await providerStatus?.completeTargetSwap(
            modelID: modelID,
            modelHash: modelHash,
            modelHashAlgorithm: currentModelHashAlgorithm,
            weightsManifestSHA256: weightsManifestSHA256,
            specDecodeDraftModelID: draftModelID,
            specDecodeNumDraftTokens: draftModelID == nil ? nil : numDraftTokens
        )
        signal(SwapSignal(targetModelID: target, outcome: .completed(newModelID: modelID, newModelHash: modelHash)))
    }

    private func failSwap(reason: String) {
        guard state == .loading || state == .draining else {
            return
        }
        let target = targetModelID ?? ""
        state = .failed
        signal(SwapSignal(targetModelID: target, outcome: .failed(reason: reason)))
        state = .ready
        targetModelID = nil
    }

    private func isConfiguredCatalogModel(_ targetModelID: String) -> Bool {
        targetModelID == modelID || targetModelID == catalogModelIDAlias
    }

    private nonisolated static func logDraftSwapFailure(targetModelID: String?, draftModelID: String?, reason: String) {
        let payload: [String: Any] = [
            "draft_model_id": redactedOperatorModelID(draftModelID) ?? NSNull(),
            "event": "spec_decode_draft_swap_failed",
            "reason": reason,
            "spec_decode_enabled": false,
            "target_model_id": redactedOperatorModelID(targetModelID) ?? NSNull(),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        } catch {
            let line = "event=spec_decode_draft_swap_failed reason=\(reason) spec_decode_enabled=false\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private nonisolated static func redactedOperatorModelID(_ modelID: String?) -> String? {
        ProviderStatus.publicSpecDecodeDraftModelID(modelID)
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private nonisolated static func draftSwapFailureReason(for error: Error) -> String {
        if error is ModelRuntimeLoadError {
            return "draft_model_load_failed"
        }
        if let startupError = error as? SpecDecodeStartupError {
            switch startupError {
            case .targetRequired:
                return "draft_model_target_required"
            case .tokenizerMismatch:
                return "draft_model_tokenizer_mismatch"
            case .probeFailed:
                return "draft_model_probe_failed"
            case .fixtureMissing:
                return "draft_model_equivalence_fixture_missing"
            case .fixtureInvalid:
                return "draft_model_equivalence_fixture_invalid"
            case .equivalenceFailed:
                return "draft_model_equivalence_failed"
            }
        }
        return "draft_model_verification_failed"
    }

    private func signal(_ signal: SwapSignal) {
        for continuation in signalContinuations.values {
            continuation.yield(signal)
        }
    }

    func registerInFlight(_ cancel: @escaping @Sendable () -> Void) -> Int {
        nextInFlightID += 1
        let id = nextInFlightID
        inFlightCancellations[id] = cancel
        return id
    }

    func unregisterInFlight(_ id: Int) {
        inFlightCancellations.removeValue(forKey: id)
    }

    private func cancelAllInFlightForDrainTimeout() {
        let cancels = Array(inFlightCancellations.values)
        inFlightCancellations.removeAll()
        for cancel in cancels {
            cancel()
        }
    }

    private func removeSignalContinuation(_ id: UUID) {
        signalContinuations.removeValue(forKey: id)
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        let snapshot = requestStartSnapshot()
        try Self.validateReady(snapshot.state)
        // Accept the coordinator-advertised catalog id as an alias only while the
        // configured model is the one currently loaded (mirrors
        // coordinatorWireModelID's servedModelID == loadedModelID guard). After a
        // warm-swap to a different model the alias must not apply.
        let aliases = (snapshot.modelID != nil && snapshot.modelID == self.modelID)
            ? modelIDAliasList(catalogModelIDAlias)
            : []
        try request.validateModelMatches(snapshot.modelID, aliases: aliases)
        try Self.validateToolChoiceScope(request)
        let drainCancelled = DrainCancelToken()
        let registrationID = registerInFlight { drainCancelled.fire() }
        return RequestHandle(
            snapshot: snapshot,
            registrationID: registrationID,
            drainCancelled: drainCancelled
        )
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
        try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
        try handle.drainCancelled.check()
        guard let container = handle.snapshot.container else {
            if testCompletion != nil {
                return
            }
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        try await inferenceGate.withPermit {
            try handle.drainCancelled.check()
            return try await container.perform { context in
                try handle.drainCancelled.check()
                let input = try Self.userInput(for: request)
                let lmInput = try await context.processor.prepare(input: input)
                try handle.drainCancelled.check()
                try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
            }
        }
    }

    func pagedKVPreflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
        try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
        try handle.drainCancelled.check()
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async throws -> CompletionResult {
        let (result, _) = try await completeWithServedSnapshot(request, shouldCancel: shouldCancel)
        return result
    }

    /// Runs a synthetic, coordinator-invisible inference against the loaded
    /// runtime. This intentionally bypasses ProviderStatus request accounting,
    /// receipt emission, and conversation-cache reads/writes.
    func runInternalWarmup(
        maxTokens: Int,
        prompt: String,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> InternalWarmupResult {
        let boundedMaxTokens = min(8, max(1, maxTokens))
        guard (1...64).contains(prompt.utf8.count) else {
            throw APIError(
                status: 400,
                message: "internal warmup prompt must be 1...64 UTF-8 bytes",
                type: "invalid_request_error",
                code: "invalid_request",
                param: "prompt"
            )
        }

        let startedAt = Date()
        let snapshot = await currentSnapshot()
        try Self.validateReady(snapshot.state)
        guard snapshot.modelHash != nil else {
            throw APIError(status: 503, message: "Model hash unavailable", type: "server_error", code: "model_not_loaded")
        }

        if let testCompletion {
            let request = try Self.internalWarmupRequest(modelID: snapshot.modelID, prompt: prompt, maxTokens: boundedMaxTokens)
            let completion = try await withThrowingTaskGroup(of: CompletionResult.self) { group in
                group.addTask {
                    try await testCompletion(snapshot, request)
                }
                group.addTask {
                    while !Task.isCancelled {
                        if shouldCancel() {
                            throw CancellationError()
                        }
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    throw CancellationError()
                }
                guard let completion = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return completion
            }
            let elapsed = Date().timeIntervalSince(startedAt) * 1000.0
            return InternalWarmupResult(
                tokensGenerated: completion.generatedCompletionTokens,
                firstTokenElapsedMS: Double(completion.ttftMilliseconds ?? Int64(elapsed)),
                totalElapsedMS: elapsed
            )
        }

        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        let kvBitsOverride = kvBitsOverride
        let prefillStepSize = prefillStepSize
        let inferenceGate = inferenceGate
        let blockingInferenceExecutor = blockingInferenceExecutor
        let firstToken = FirstTokenRecorder()
        let cancellation = WarmupCancellationRecorder()
        let result: BlockingGenerateResult = try await inferenceGate.withPermit {
            if Task.isCancelled || shouldCancel() {
                throw CancellationError()
            }
            return try await container.perform { context in
                if Task.isCancelled || shouldCancel() {
                    throw CancellationError()
                }
                let input = UserInput(chat: [.user(prompt)])
                let lmInput = try await context.processor.prepare(input: input)
                try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
                let parameters = Self.makeServeGenerateParameters(
                    maxTokens: boundedMaxTokens,
                    maxContextTokens: maxContextTokens,
                    kvBitsOverride: kvBitsOverride,
                    prefillStepSize: prefillStepSize,
                    temperature: 0.0,
                    topP: 1.0
                )
                let kvCache = context.model.newCache(parameters: parameters)
                let iterator = try TokenIterator(input: lmInput, model: context.model, cache: kvCache, parameters: parameters)
                return try await blockingInferenceExecutor.run { inferenceCancellation in
                    BlockingGenerateResult(generate(input: lmInput, context: context, iterator: iterator) { tokens in
                        if !tokens.isEmpty {
                            firstToken.recordIfMissing()
                        }
                        if Task.isCancelled || inferenceCancellation.isCancelled || shouldCancel() {
                            cancellation.record()
                            return .stop
                        }
                        return .more
                    })
                }
            }
        }
        if cancellation.wasCancelled || Task.isCancelled || shouldCancel() {
            throw CancellationError()
        }
        let elapsed = Date().timeIntervalSince(startedAt) * 1000.0
        return InternalWarmupResult(
            tokensGenerated: result.generationTokenCount,
            firstTokenElapsedMS: Double(firstToken.elapsedMilliseconds(since: startedAt) ?? Int64(elapsed)),
            totalElapsedMS: elapsed
        )
    }

    /// SPEC-015 §M.2.2 — atomic snapshot capture inside the actor
    /// turn that started inference. The returned snapshot IS the
    /// container that served the response (in-flight tracking pins
    /// it for the request lifetime per SPEC-011 R-3.4.1). Callers
    /// MUST bind the receipt's `model_hash` to this snapshot, NOT to
    /// a separately-sampled `currentSnapshot()`.
    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        let handle = try acquireRequestHandle(request)
        defer { unregisterInFlight(handle.registrationID) }
        return try await completeWithServedSnapshot(request, with: handle, shouldCancel: shouldCancel)
    }

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        let completionStartedAt = Date()
        let snapshot = handle.snapshot
        let drainCancelled = handle.drainCancelled
        // Non-streaming execution is a direct entry path with no preceding
        // preflight (HTTP + relay), so it OWNS the single serial-route telemetry
        // emission for this request. (Streaming preflights first and suppresses
        // here to stay exactly-once.)
        try applyContinuousBatchingPolicy(request: request, snapshot: snapshot, emitTelemetry: true)
        try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
        try drainCancelled.check()
        if let testSpeculativeCompletion,
           Self.speculativeRoute(
               for: request,
               draftLoaded: snapshot.hasTargetCompatibleDraft,
               numDraftTokens: snapshot.numDraftTokens
           ) == .speculative {
            do {
                let result = try await Self.withDrainCancellation(drainCancelled) {
                    try await testSpeculativeCompletion(snapshot, request)
                }
                return (try Self.validateStructuredCompletion(result, request: request).withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash)), snapshot)
            } catch let error as DrainCancelledError {
                throw error
            } catch let error as CancellationError {
                throw error
            } catch let error as SpeculativeGenerationFailure {
                Self.logSpeculativeFallback(error)
            }
        }
        if let testCompletion {
            let result = try await Self.withDrainCancellation(drainCancelled) {
                try await testCompletion(snapshot, request)
            }
            return (try Self.validateStructuredCompletion(result, request: request).withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash)), snapshot)
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        let kvBitsOverride = kvBitsOverride
        let prefillStepSize = prefillStepSize
        let conversationCache = conversationCache
        // SPEC-037 stage 5 — per-request cold-tier context, captured before the
        // nonisolated inference closure (nil unless the disk tier is attached).
        let coldContext = coldContext(for: request, snapshot: snapshot)
        let inferenceGate = inferenceGate
        let blockingInferenceExecutor = blockingInferenceExecutor
        let stopTokenFilter = stopTokenFilter
        let completion = try await Self.withDrainCancellation(drainCancelled) {
            try await inferenceGate.withPermit {
                try drainCancelled.check()
                try Task.checkCancellation()
                return try await container.perform { context in
                    try drainCancelled.check()
                    try Task.checkCancellation()
                    let input = try Self.userInput(for: request)
                    let lmInput = try await context.processor.prepare(input: input)
                    try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
                    let parameters = Self.makeServeGenerateParameters(
                        maxTokens: request.maxTokens,
                        maxContextTokens: maxContextTokens,
                        kvBitsOverride: kvBitsOverride,
                        prefillStepSize: prefillStepSize,
                        temperature: Float(request.temperature),
                        topP: Float(request.topP)
                    )
                    let firstToken = FirstTokenRecorder()
                    let promptTokenIds: [Int32] = lmInput.text.tokens.asArray(Int32.self)
                    if Self.speculativeRoute(
                        for: request,
                        draftLoaded: snapshot.hasTargetCompatibleDraft && snapshot.draftContainer != nil,
                        numDraftTokens: snapshot.numDraftTokens
                    ) == .speculative,
                       let draftContainer = snapshot.draftContainer,
                       let numDraftTokens = snapshot.numDraftTokens {
                        do {
                            return try await Self.runSpeculativeCompletion(
                                input: lmInput,
                                parameters: parameters,
                                targetContext: context,
                                draft: draftContainer,
                                numDraftTokens: numDraftTokens,
                                request: request,
                                stopTokenFilter: stopTokenFilter,
                                promptTokenCount: promptTokenIds.count,
                                completionStartedAt: completionStartedAt,
                                modelHash: snapshot.modelHash,
                                specDecodeGeneration: snapshot.specDecodeGeneration,
                                shouldCancel: shouldCancel,
                                drainCancelled: drainCancelled,
                                blockingInferenceExecutor: blockingInferenceExecutor
                            )
                        } catch let error as DrainCancelledError {
                            throw error
                        } catch let error as CancellationError {
                            throw error
                        } catch let error as SpeculativeGenerationFailure {
                            // FR-12 permits one pre-output retry on the existing
                            // non-speculative target path. This branch happens
                            // before any buyer-visible response exists for the
                            // non-streaming endpoint.
                            Self.logSpeculativeFallback(error)
                        }
                    }
                    let lease = await conversationCache.begin(
                        conversationKey: request.conversationKey,
                        incomingTokens: promptTokenIds,
                        modelID: request.model,
                        kvBits: kvBitsOverride,
                        cold: coldContext
                    )
                        do {
                            let generationContext = Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
                            let kvCache: [KVCache]
                            let iteratorInput: LMInput
                            if let reusableCache = lease?.reusableCache, let lcp = lease?.lcp {
                                kvCache = reusableCache.layers
                                iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[lcp...])))
                            } else {
                                // SPEC-037 FR-KVP1: a tier-eligible request must run on a
                                // KVCacheSimple so captureSnapshot can serialize it; keep the
                                // rotating cache for everything else. TokenIterator still gets
                                // the original `parameters` (its maxKVSize is ignored once the
                                // cache is passed explicitly).
                                kvCache = Self.serveCache(
                                    model: generationContext.model, baseParameters: parameters,
                                    eligible: coldContext?.eligible == true)
                                iteratorInput = lmInput
                            }

                            let iterator = try TokenIterator(input: iteratorInput, model: generationContext.model, cache: kvCache, parameters: parameters)
                            let result: BlockingGenerateResult = try await blockingInferenceExecutor.run { inferenceCancellation in
                                BlockingGenerateResult(generate(input: iteratorInput, context: generationContext, iterator: iterator) { tokens in
                                    if !tokens.isEmpty {
                                        firstToken.recordIfMissing()
                                    }
                                    if Task.isCancelled || inferenceCancellation.isCancelled || shouldCancel() || drainCancelled.isFired {
                                        return GenerateDisposition.stop
                                    }
                                    if HarmonyResponseParser.isHarmonyModelID(request.model),
                                       tokens.last.map(Self.isHarmonyTerminalToken) == true {
                                        return GenerateDisposition.stop
                                    }
                                    return GenerateDisposition.more
                                })
                            }
                            try drainCancelled.check()
                            try Task.checkCancellation()
                            if shouldCancel() {
                                throw CancellationError()
                            }
                            let resultTokenIDs = result.tokenIds

                        guard result.output.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
                            throw APIError(
                                status: 502,
                                message: "Model response exceeded 2097152 bytes",
                                type: "upstream_provider_error",
                                code: "response_byte_cap_exceeded",
                                inferenceRan: true,
                                settlementRan: true
                            )
                        }

                        let filtered = Self.applyOutputFilters(
                            result.output,
                            stopTokenFilter: stopTokenFilter,
                            requestStops: request.stop
                        )

                        let rawLengthFinish = request.maxTokens.map { result.generationTokenCount >= $0 } ?? false
                        let harmonyTerminalFinish = Self.isHarmonyTerminalFinish(
                            modelID: request.model,
                            generatedTokenIDs: resultTokenIDs
                        )
                        let parserFinishReason = HarmonyResponseParser.isHarmonyModelID(request.model)
                            ? (rawLengthFinish && !filtered.hitStop && !harmonyTerminalFinish ? "length" : (filtered.hitStop ? "request_stop" : "stop"))
                            : (rawLengthFinish && !filtered.hitStop ? "length" : (filtered.hitStop ? "request_stop" : "stop"))
                        let parsed = try Self.parseGeneratedOutput(
                            filteredText: filtered.text,
                            generatedTokenIDs: resultTokenIDs,
                            decode: { context.tokenizer.decode(tokenIds: $0) },
                            request: request,
                            mode: .complete(finishReason: parserFinishReason),
                            defaultCompletionTokens: result.generationTokenCount,
                            stopTokenFilter: stopTokenFilter,
                            requestStops: request.stop,
                            globalHitStop: filtered.hitStop
                        )
                        let finishReason: String
                        if !parsed.toolCalls.isEmpty {
                            finishReason = "tool_calls"
                        } else if rawLengthFinish, !filtered.hitStop, !parsed.hitStop, !harmonyTerminalFinish {
                            finishReason = "length"
                        } else {
                            finishReason = "stop"
                        }

                        let cachedPromptTokens = lease?.cachedPromptTokens ?? 0
                        let kvCacheBytesReused = Self.cachedPromptUTF8Bytes(
                            promptTokenIds: promptTokenIds,
                            cachedPromptTokens: cachedPromptTokens,
                            decode: { context.tokenizer.decode(tokenIds: $0) }
                        )
                        let completion = try Self.validateStructuredCompletion(CompletionResult(
                            content: parsed.content,
                            finishReason: finishReason,
                            promptTokens: promptTokenIds.count,
                            cachedPromptTokens: cachedPromptTokens,
                            kvCacheBytesReused: kvCacheBytesReused,
                            completionTokens: parsed.completionTokens,
                            generatedCompletionTokens: parsed.generatedCompletionTokens,
                            ttftMilliseconds: firstToken.elapsedMilliseconds(since: completionStartedAt),
                            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                            modelHashObserved: Self.validObservedModelHash(snapshot.modelHash)
                        ), request: request)
                        if let lease {
                            await conversationCache.commit(lease, cache: ConversationCacheLayers(kvCache), fullTokens: promptTokenIds + resultTokenIDs.map(Int32.init), cold: coldContext)
                        }
                        return completion
                    } catch {
                        if let lease {
                            await conversationCache.abort(lease)
                        }
                        throw error
                    }
                }
            }
        }
        return (completion, snapshot)
    }

    private static func runSpeculativeCompletion(
        input: LMInput,
        parameters: GenerateParameters,
        targetContext: ModelContext,
        draft: ModelContainer,
        numDraftTokens: Int,
        request: ChatCompletionRequest,
        stopTokenFilter: StopTokenFilter,
        promptTokenCount: Int,
        completionStartedAt: Date,
        modelHash: String?,
        specDecodeGeneration: Int,
        shouldCancel: @escaping @Sendable () -> Bool,
        drainCancelled: DrainCancelToken,
        blockingInferenceExecutor: BlockingInferenceExecutor
    ) async throws -> CompletionResult {
        let generated = try await collectSpeculativeText(
            input: input,
            cache: nil,
            parameters: parameters,
            targetContext: targetContext,
            draft: draft,
            numDraftTokens: numDraftTokens,
            shouldCancel: shouldCancel,
            drainCancelled: drainCancelled,
            blockingInferenceExecutor: blockingInferenceExecutor
        )
        try drainCancelled.check()
        try Task.checkCancellation()
        guard generated.output.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
            throw APIError(
                status: 502,
                message: "Model response exceeded 2097152 bytes",
                type: "upstream_provider_error",
                code: "response_byte_cap_exceeded",
                inferenceRan: true,
                settlementRan: true
            )
        }

        let filtered = applyOutputFilters(
            generated.output,
            stopTokenFilter: stopTokenFilter,
            requestStops: request.stop
        )
        let parsed = parseToolCallsIfRequested(filtered.text, request: request)
        let finishReason: String
        if !parsed.toolCalls.isEmpty {
            finishReason = "tool_calls"
        } else if let maxTokens = request.maxTokens,
                  generated.generationTokenCount >= maxTokens,
                  !filtered.hitStop {
            finishReason = "length"
        } else {
            finishReason = "stop"
        }
        return try validateStructuredCompletion(CompletionResult(
            content: parsed.content,
            finishReason: finishReason,
            promptTokens: promptTokenCount,
            completionTokens: generated.generationTokenCount,
            ttftMilliseconds: generated.firstToken.elapsedMilliseconds(since: completionStartedAt),
            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
            modelHashObserved: validObservedModelHash(modelHash),
            specDecodeDraftedTokens: generated.draftedTokens,
            specDecodeAcceptedTokens: generated.acceptedTokens,
            specDecodeGeneration: specDecodeGeneration
        ), request: request)
    }

    struct SpeculativeGenerationFailure: Error, Sendable {
        let reason: String
    }

    private static func logSpeculativeFallback(_ error: SpeculativeGenerationFailure) {
        let line = "event=spec_decode_fallback reason=\(error.reason)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private struct SpeculativeTextResult: Sendable {
        let output: String
        let generationTokenCount: Int
        let draftedTokens: Int
        let acceptedTokens: Int
        let firstToken: FirstTokenRecorder
    }

    private static func collectSpeculativeText(
        input: LMInput,
        cache: [KVCache]?,
        parameters: GenerateParameters,
        targetContext: ModelContext,
        draft: ModelContainer,
        numDraftTokens: Int,
        shouldCancel: @escaping @Sendable () -> Bool,
        drainCancelled: DrainCancelToken,
        blockingInferenceExecutor: BlockingInferenceExecutor
    ) async throws -> SpeculativeTextResult {
        do {
            return try await draft.perform(nonSendable: (input, targetContext, cache)) { draftContext, values in
                let (input, targetContext, cache) = values
                return try await blockingInferenceExecutor.run { inferenceCancellation in
                    let draftCache = draftContext.model.newCache(parameters: parameters)
                    var iterator = try SpeculativeTokenIterator(
                        input: input,
                        mainModel: targetContext.model,
                        draftModel: draftContext.model,
                        mainCache: cache,
                        draftCache: draftCache,
                        parameters: parameters,
                        numDraftTokens: numDraftTokens
                    )
                    let stopTokenIDs = Self.generationStopTokenIDs(for: targetContext)
                    var tokenIDs: [Int] = []
                    var output = ""
                    var detokenizer = MLXLMCommon.NaiveStreamingDetokenizer(tokenizer: targetContext.tokenizer)
                    var stopStringFilter = GenerationConfigStopStringFilter(
                        stopStrings: targetContext.configuration.effectiveStopStrings
                    )
                    let firstToken = FirstTokenRecorder()
                    while let token = iterator.next() {
                        try drainCancelled.check()
                        if Task.isCancelled || inferenceCancellation.isCancelled || shouldCancel() {
                            throw CancellationError()
                        }
                        if token == targetContext.tokenizer.unknownTokenId || stopTokenIDs.contains(token) {
                            iterator.discardGeneratedToken()
                            break
                        }
                        firstToken.recordIfMissing()
                        tokenIDs.append(token)
                        detokenizer.append(token: token)
                        if let chunk = detokenizer.next() {
                            let result = stopStringFilter.process(chunk)
                            if let text = result.text {
                                output += text
                            }
                            if result.stopped {
                                break
                            }
                        }
                    }
                    if let text = stopStringFilter.finish() {
                        output += text
                    }
                    Stream().synchronize()
                    let telemetry = iterator.speculativeDecodingTelemetry
                    return SpeculativeTextResult(
                        output: output,
                        generationTokenCount: tokenIDs.count,
                        draftedTokens: telemetry?.draftTokenCount ?? 0,
                        acceptedTokens: telemetry?.acceptedDraftTokenCount ?? 0,
                        firstToken: firstToken
                    )
                }
            }
        } catch let error as DrainCancelledError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch let error as SpeculativeGenerationFailure {
            throw error
        } catch {
            throw SpeculativeGenerationFailure(reason: "generation_threw")
        }
    }

    private static func generationStopTokenIDs(for context: ModelContext) -> Set<Int> {
        var stopTokenIDs = context.configuration.eosTokenIds
        let tokenizer = context.tokenizer
        if let eosTokenID = tokenizer.eosTokenId {
            stopTokenIDs.insert(eosTokenID)
        }
        for token in context.configuration.extraEOSTokens {
            if let tokenID = tokenizer.convertTokenToId(token) {
                stopTokenIDs.insert(tokenID)
            }
        }
        return stopTokenIDs
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        let snapshot = handle.snapshot
        let drainCancelled = handle.drainCancelled
        try applyContinuousBatchingPolicy(request: request, snapshot: snapshot, emitTelemetry: false)
        try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
        let structuredAccumulator = StructuredStreamingContentAccumulator(enabled: Self.requiresStructuredValidation(request.responseFormat))
        let idleState = StructuredStreamingIdleState(enabled: Self.requiresStructuredValidation(request.responseFormat))
        if let testSpeculativeStream,
           Self.speculativeRoute(
               for: request,
               draftLoaded: snapshot.hasTargetCompatibleDraft,
               numDraftTokens: snapshot.numDraftTokens
           ) == .speculative {
            let completion = try await Self.withDrainCancellation(drainCancelled) {
                try await testSpeculativeStream(snapshot, request)
            }.withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash))
            if !completion.content.isEmpty {
                if let error = structuredAccumulator.append(completion.content) {
                    throw error
                }
                idleState.noteContent()
                onChunk(.content(completion.content))
            }
            return try Self.validateStructuredStreamingCompletion(
                completion,
                request: request,
                buyerVisibleContent: structuredAccumulator.content
            )
        }
        if let testCompletion {
            let completion = try await Self.withDrainCancellation(drainCancelled) {
                try await testCompletion(snapshot, request)
            }.withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash))
            if !completion.content.isEmpty {
                if let error = structuredAccumulator.append(completion.content) {
                    throw error
                }
                idleState.noteContent()
                onChunk(.content(completion.content))
            }
            return try Self.validateStructuredStreamingCompletion(
                completion,
                request: request,
                buyerVisibleContent: structuredAccumulator.content
            )
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        // T2-01: compiled decode env-flag wire-in. When enabled, the
        // decode-bench path uses MLX.compile()-wrapped per-token forwards
        // (see DecodeBenchCommand.runCompiledOnce). Full production stream()
        // wire-in is deferred to a follow-up PR after bench correctness is
        // confirmed via T2-01 artifact. The flag is read here so it appears
        // in inference logs and the serve path is ready to branch on it.
        let compiledDecodeEnabled = CompiledDecode.isEnabledByEnvironment()
        if compiledDecodeEnabled {
            let line = "event=compiled_decode_enabled status=stream_path_deferred flag=\(CompiledDecode.envFlag)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }

        let maxContextTokens = maxContextTokens
        let kvBitsOverride = kvBitsOverride
        let prefillStepSize = prefillStepSize
        let conversationCache = conversationCache
        // SPEC-037 stage 5 — per-request cold-tier context (streaming endpoint).
        let coldContext = coldContext(for: request, snapshot: snapshot)
        let inferenceGate = inferenceGate
        let blockingInferenceExecutor = blockingInferenceExecutor
        let stopTokenFilter = stopTokenFilter
        return try await Self.withDrainCancellation(drainCancelled) {
            try await Self.withStructuredStreamingIdleTimeout(
                idleState: idleState,
                onIdleTimeout: {
                    try Self.synthesizeIdleTimeoutResultOrThrow(
                        accumulator: structuredAccumulator,
                        request: request,
                        modelHash: snapshot.modelHash
                    )
                }
            ) { idleCancellation in
                try await inferenceGate.withPermit {
                try drainCancelled.check()
                try Task.checkCancellation()
                return try await container.perform { context in
                    try drainCancelled.check()
                    try Task.checkCancellation()
                    let input = try Self.userInput(for: request)
                    let lmInput = try await context.processor.prepare(input: input)
                    try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
                    let parameters = Self.makeServeGenerateParameters(
                        maxTokens: request.maxTokens,
                        maxContextTokens: maxContextTokens,
                        kvBitsOverride: kvBitsOverride,
                        prefillStepSize: prefillStepSize,
                        temperature: Float(request.temperature),
                        topP: Float(request.topP)
                    )
                    let generationContext = Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)

                    let promptTokenIds: [Int32] = lmInput.text.tokens.asArray(Int32.self)
                    // Autotune throughput probe: measure warm-decode
                    // wall-time on the provider so the client can derive an
                    // honest decode rate even for reasoning models whose
                    // analysis channel is silent in the SSE stream. Fires on
                    // the first decoded token of ANY channel (reasoning or
                    // final) inside the generate closure below; the duration
                    // to the generate result is reported as
                    // `macprovider_generation_ms`.
                    let decodeTimer = FirstTokenRecorder()
                    // SPEC-037 FR-KVP2.5: speculative-decode routing is
                    // determined BEFORE any conversation-cache begin(). A
                    // speculative-routed request acquires no lease, triggers no
                    // promotion, commits nothing, and leaves no busy key. This
                    // also fixes the latent stuck-busy-key bug on the streaming
                    // speculative path, whose success branch previously returned
                    // without committing or aborting a lease acquired above it
                    // (and passed a possibly-trimmed prompt with cache: nil).
                    if Self.speculativeRoute(
                        for: request,
                        draftLoaded: snapshot.hasTargetCompatibleDraft && snapshot.draftContainer != nil,
                        numDraftTokens: snapshot.numDraftTokens
                    ) == .speculative,
                       let draftContainer = snapshot.draftContainer,
                       let numDraftTokens = snapshot.numDraftTokens {
                        var emittedText = ""
                        var stoppedByRequestStop = false
                        let generated = try await Self.collectSpeculativeText(
                            input: lmInput,
                            cache: nil,
                            parameters: parameters,
                            targetContext: context,
                            draft: draftContainer,
                            numDraftTokens: numDraftTokens,
                            shouldCancel: shouldCancel,
                            drainCancelled: drainCancelled,
                            blockingInferenceExecutor: blockingInferenceExecutor
                        )
                        // Warm-decode wall-time for the speculative path.
                        // collectSpeculativeText owns its own decode loop and
                        // does not fire `decodeTimer`, so this resolves to nil
                        // here; the field is passed for construction-site parity
                        // with the non-speculative path.
                        let decodeEndedAt = Date()
                        let generationMS = decodeTimer.durationMilliseconds(until: decodeEndedAt)
                        try drainCancelled.check()
                        try Task.checkCancellation()

                        let final = Self.applyOutputFilters(
                            generated.output,
                            stopTokenFilter: stopTokenFilter,
                            requestStops: request.stop
                        )
                        let finalDelta = Self.delta(from: emittedText, to: final.text)
                        let parsed = Self.parseToolCallsIfRequested(final.text, request: request)
                        if !finalDelta.isEmpty {
                            if let error = structuredAccumulator.append(finalDelta) {
                                throw error
                            }
                            idleState.noteContent()
                            emittedText = final.text
                            stoppedByRequestStop = final.hitStop
                            onChunk(.content(finalDelta))
                        }
                        if final.hitStop {
                            stoppedByRequestStop = true
                        }
                        if let error = structuredAccumulator.error {
                            throw error
                        }

                        let finishReason: String
                        if !parsed.toolCalls.isEmpty {
                            finishReason = "tool_calls"
                        } else if let maxTokens = request.maxTokens,
                                  generated.generationTokenCount >= maxTokens,
                                  !stoppedByRequestStop,
                                  !final.hitStop {
                            finishReason = "length"
                        } else {
                            finishReason = "stop"
                        }

                        let completion = CompletionResult(
                            content: parsed.content,
                            finishReason: finishReason,
                            promptTokens: promptTokenIds.count,
                            cachedPromptTokens: 0,
                            completionTokens: generated.generationTokenCount,
                            generationMilliseconds: generationMS,
                            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                            modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
                            specDecodeDraftedTokens: generated.draftedTokens,
                            specDecodeAcceptedTokens: generated.acceptedTokens,
                            specDecodeGeneration: snapshot.specDecodeGeneration
                        )
                        return try Self.validateStructuredStreamingCompletion(
                            completion,
                            request: request,
                            buyerVisibleContent: structuredAccumulator.content
                        )
                    }

                    let lease = await conversationCache.begin(
                        conversationKey: request.conversationKey,
                        incomingTokens: promptTokenIds,
                        modelID: request.model,
                        kvBits: kvBitsOverride,
                        cold: coldContext
                    )
                    let kvCache: [KVCache]
                    let iteratorInput: LMInput
                    if let reusableCache = lease?.reusableCache, let lcp = lease?.lcp {
                        kvCache = reusableCache.layers
                        iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[lcp...])))
                    } else {
                        // SPEC-037 FR-KVP1: same tier-eligible → KVCacheSimple selection as
                        // the non-streaming path (see cacheParameters). TokenIterator below
                        // keeps the original `parameters`.
                        kvCache = Self.serveCache(
                            model: generationContext.model, baseParameters: parameters,
                            eligible: coldContext?.eligible == true)
                        iteratorInput = lmInput
                    }

                    var emittedText = ""
                    var stoppedByRequestStop = false
                    var toolStreamer = NativeToolCallStreamEmitter(
                        modelID: request.model,
                        allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools)
                    )
                    var streamingParseError: APIError?
                    var harmonyObservedFinalTokenCount = 0
                    var harmonyObservedTokenCount = 0

                    // SPEC-037 FR-KVP2.5: speculative-decode routing is determined
                    // BEFORE conversationCache.begin() (block above, ahead of the
                    // lease acquisition) — a speculative-routed request acquires no
                    // lease, triggers no promotion, commits nothing, and leaves no
                    // busy key. This non-speculative path therefore never re-checks
                    // speculativeRoute; the post-begin speculative block that origin
                    // carried here would double-run and (on its success return) leak
                    // the lease as a stuck busy key, so it is intentionally dropped.
                    let isHarmonyResponse = HarmonyResponseParser.isHarmonyModelID(request.model)
                    var harmonyFinalDetokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
                    var harmonyStreamingParser = HarmonyResponseParser.StreamingParser(
                        decode: { context.tokenizer.decode(tokenIds: $0) },
                        decodeFinalToken: { tokenID in
                            harmonyFinalDetokenizer.append(token: tokenID)
                            return harmonyFinalDetokenizer.next()
                        },
                        allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools),
                        stopCandidates: stopTokenFilter.tokens + request.stop
                    )
                    let streamToolsIncrementally = Self.hasEnabledTools(request.promptSource.tools) && !isHarmonyResponse
                    let iterator = try TokenIterator(input: iteratorInput, model: generationContext.model, cache: kvCache, parameters: parameters)
                    do {
                        let result: BlockingGenerateResult = try await blockingInferenceExecutor.run { inferenceCancellation in
                            BlockingGenerateResult(generate(input: iteratorInput, context: generationContext, iterator: iterator) { tokens in
                                EgressPerfTraceKey.current?.recordDecodeCallbackEntry()
                                // Round-2 code LOW: only start the decode timer
                                // on a callback that actually carries a token.
                                // An empty first callback would otherwise start
                                // the clock during prefill and inflate the
                                // measured decode window. Mirrors the
                                // `if !tokens.isEmpty { firstToken.recordIfMissing() }`
                                // guards elsewhere in this file.
                                if !tokens.isEmpty {
                                    decodeTimer.recordIfMissing()
                                }
                                if Task.isCancelled || inferenceCancellation.isCancelled || shouldCancel() || drainCancelled.isFired || idleCancellation.isFired {
                                    return .stop
                                }
                                if isHarmonyResponse {
                                    do {
                                        guard tokens.count >= harmonyObservedTokenCount else {
                                            streamingParseError = Self.malformedHarmonyResponseError()
                                            return .stop
                                        }
                                        let newTokenIDs = Array(tokens.dropFirst(harmonyObservedTokenCount))
                                        harmonyObservedTokenCount = tokens.count
                                        let parsed = harmonyStreamingParser.parse(newTokenIDs: newTokenIDs)
                                        if parsed.finalContentTokenCount > harmonyObservedFinalTokenCount {
                                            harmonyObservedFinalTokenCount = parsed.finalContentTokenCount
                                            idleState.noteContent()
                                        }
                                        let output = try Self.harmonyParsedOutput(
                                            from: parsed,
                                            decode: { context.tokenizer.decode(tokenIds: $0) },
                                            stopTokenFilter: stopTokenFilter,
                                            requestStops: request.stop,
                                            countCompletionTokens: false
                                        )
                                        if output.hitStop {
                                            stoppedByRequestStop = true
                                            return .stop
                                        }
                                        if tokens.last.map(Self.isHarmonyTerminalToken) == true {
                                            return .stop
                                        }
                                        return .more
                                    } catch let error as APIError {
                                        streamingParseError = error
                                        return .stop
                                    } catch {
                                        streamingParseError = Self.malformedHarmonyResponseError()
                                        return .stop
                                    }
                                }
                                let decoded = context.tokenizer.decode(tokenIds: tokens)
                                let candidate = Self.streamingSafePrefix(
                                    decoded,
                                    stopTokenFilter: stopTokenFilter,
                                    requestStops: request.stop
                                )
                                if streamToolsIncrementally {
                                    for event in toolStreamer.observe(candidate.text) {
                                        onChunk(event)
                                    }
                                    if candidate.hitStop {
                                        stoppedByRequestStop = true
                                        return .stop
                                    }
                                    return .more
                                }

                                let delta = Self.delta(from: emittedText, to: candidate.text)
                                if !delta.isEmpty {
                                    if structuredAccumulator.append(delta) != nil {
                                        return .stop
                                    }
                                    idleState.noteContent()
                                    emittedText = candidate.text
                                    onChunk(.content(delta))
                                }

                                if candidate.hitStop {
                                    stoppedByRequestStop = true
                                    return .stop
                                }
                                return .more
                            })
                        }
                        // Warm-decode wall-time: from the first decoded token
                        // (any channel) to the generate result. Reported to the
                        // client as `macprovider_generation_ms` so the autotune
                        // probe can divide total decoded tokens by this window
                        // even when the reasoning channel is silent in SSE.
                        let decodeEndedAt = Date()
                        let generationMS = decodeTimer.durationMilliseconds(until: decodeEndedAt)
                        try drainCancelled.check()
                        try Task.checkCancellation()
                        if shouldCancel() {
                            throw CancellationError()
                        }
                        if let streamingParseError {
                            throw streamingParseError
                        }
                        let resultTokenIDs = result.tokenIds

                        let final = Self.applyOutputFilters(
                            result.output,
                            stopTokenFilter: stopTokenFilter,
                            requestStops: request.stop
                        )
                        let rawLengthFinish = request.maxTokens.map { result.generationTokenCount >= $0 } ?? false
                        let harmonyTerminalFinish = Self.isHarmonyTerminalFinish(
                            modelID: request.model,
                            generatedTokenIDs: resultTokenIDs
                        )
                        let parserFinishReason = isHarmonyResponse
                            ? (rawLengthFinish && !stoppedByRequestStop && !harmonyTerminalFinish ? "length" : (stoppedByRequestStop ? "request_stop" : "stop"))
                            : (rawLengthFinish && !final.hitStop && !stoppedByRequestStop ? "length" : ((final.hitStop || stoppedByRequestStop) ? "request_stop" : "stop"))
                        let parsed = try Self.parseGeneratedOutput(
                            filteredText: final.text,
                            generatedTokenIDs: resultTokenIDs,
                            decode: { context.tokenizer.decode(tokenIds: $0) },
                            request: request,
                            mode: .complete(finishReason: parserFinishReason),
                            defaultCompletionTokens: result.generationTokenCount,
                            stopTokenFilter: stopTokenFilter,
                            requestStops: request.stop,
                            globalHitStop: final.hitStop || stoppedByRequestStop
                        )
                        let finalDelta = Self.delta(from: emittedText, to: parsed.content)
                        if streamToolsIncrementally {
                            for event in toolStreamer.observe(final.text) {
                                onChunk(event)
                            }
                            if parsed.toolCalls.isEmpty, !parsed.content.isEmpty {
                                if let error = structuredAccumulator.append(parsed.content) {
                                    throw error
                                }
                                idleState.noteContent()
                                onChunk(.content(parsed.content))
                            }
                        } else if !finalDelta.isEmpty {
                            if let error = structuredAccumulator.append(finalDelta) {
                                throw error
                            }
                            idleState.noteContent()
                            onChunk(.content(finalDelta))
                        }
                        if let error = structuredAccumulator.error {
                            throw error
                        }

                        let finishReason: String
                        if !parsed.toolCalls.isEmpty {
                            finishReason = "tool_calls"
                        } else if let maxTokens = request.maxTokens,
                           result.generationTokenCount >= maxTokens,
                           !stoppedByRequestStop,
                           !final.hitStop,
                           !parsed.hitStop,
                           !harmonyTerminalFinish
                        {
                            finishReason = "length"
                        } else {
                            finishReason = "stop"
                        }

                        let cachedPromptTokens = lease?.cachedPromptTokens ?? 0
                        let kvCacheBytesReused = Self.cachedPromptUTF8Bytes(
                            promptTokenIds: promptTokenIds,
                            cachedPromptTokens: cachedPromptTokens,
                            decode: { context.tokenizer.decode(tokenIds: $0) }
                        )
                        let completion = CompletionResult(
                            content: parsed.content,
                            finishReason: finishReason,
                            promptTokens: promptTokenIds.count,
                            cachedPromptTokens: cachedPromptTokens,
                            kvCacheBytesReused: kvCacheBytesReused,
                            completionTokens: parsed.completionTokens,
                            generatedCompletionTokens: parsed.generatedCompletionTokens,
                            generationMilliseconds: generationMS,
                            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                            modelHashObserved: Self.validObservedModelHash(snapshot.modelHash)
                        )
                        let validated = try Self.validateStructuredStreamingCompletion(
                            completion,
                            request: request,
                            buyerVisibleContent: structuredAccumulator.content
                        )
                        if let lease {
                            await conversationCache.commit(lease, cache: ConversationCacheLayers(kvCache), fullTokens: promptTokenIds + resultTokenIDs.map(Int32.init), cold: coldContext)
                        }
                        return validated
                    } catch {
                        if let lease {
                            await conversationCache.abort(lease)
                        }
                        throw error
                    }
                }
            }
            }
        }
    }

    /// SPEC-037 stage 5 (FR-KVP7) — attach the activated disk cold tier. Called by
    /// the serve lifecycle after the store acquires its namespace lock, so the hot
    /// tier only reaches disk once single-writer ownership is established.
    func attachKVDiskTier(_ tier: KVDiskTier) async {
        let adapter = KVConversationColdTierAdapter(
            store: tier.store, namespaceID: tier.namespaceID,
            eligibilityTTLSeconds: tier.eligibilityTTLSeconds,
            writeStagingMaxBytes: tier.config.writeStagingMaxBytes,
            maxEntryBytes: tier.config.maxEntryBytes,
            stagingMaxBytes: tier.config.stagingMaxBytes)
        await conversationCache.attachColdTier(adapter)
        // CRITICAL-2: keep the adapter's cached epoch in step with the store so
        // captureSnapshot stamps the epoch at commit time. Seeds immediately.
        await tier.store.setEpochObserver { [weak adapter] epoch in adapter?.cacheEpoch(epoch) }
        // CRITICAL-1: wire the store's purge path back to the hot tier so a purge /
        // purge-all drops the matching RAM entry and fences outstanding leases
        // before the on-disk generation is unlinked / the epoch is rotated.
        let cache = conversationCache
        await tier.store.setHotPurgeHooks(
            single: { key in await cache.purgeHot(conversationKey: key) },
            all: { await cache.purgeAllHot() })
        // HIGH-5: drain queued cold writes on graceful shutdown before lock release.
        tier.setDrainHook { seconds in await cache.drainColdWrites(timeoutSeconds: seconds) }
        // HIGH-1 (SPEC-037 KVS-01a): seed the adapter's live-model geometry template
        // from the ACTUAL loaded cache geometry BEFORE admitting requests, so the
        // first post-restart request can promote a persisted entry rather than
        // falling back to a fresh prefill until some other conversation commits.
        await seedColdGeometry(into: adapter)
        coldTierAttached = true
    }

    /// HIGH-1 (SPEC-037 KVS-01a) — seed the cold-tier adapter's live-model geometry
    /// template from the REAL loaded `KVCacheSimple` geometry. Runs a minimal
    /// warmup prefill under the serve generation parameters to populate a cache,
    /// snapshots its per-layer geometry, and seeds the adapter keyed by the served
    /// model ID. Best-effort: no loaded container (headless/test), MLX/Metal
    /// unavailable, a non-`KVCacheSimple` runtime (e.g. a kv-quantized serve, which
    /// never persists anyway), or any warmup failure simply skips the seed — the
    /// tier then behaves as before (the model's first post-restart turn misses).
    /// The seeded template only supplies the EXPECTED geometry to validate against;
    /// every promoted entry still passes full FR-KVP4 envelope validation against
    /// the live manifest, so a stale/wrong seed can only cause a miss.
    private func seedColdGeometry(into adapter: KVConversationColdTierAdapter) async {
        guard let container = currentContainer, let servedModelID = currentModelID else { return }
        let maxContextTokens = maxContextTokens
        let kvBitsOverride = kvBitsOverride
        let prefillStepSize = prefillStepSize
        let blockingInferenceExecutor = blockingInferenceExecutor
        let template: [KVLayerGeometry]? = try? await inferenceGate.withPermit {
            try await container.perform { context -> [KVLayerGeometry]? in
                let input = UserInput(chat: [.user("warmup")])
                let lmInput = try await context.processor.prepare(input: input)
                let parameters = Self.makeServeGenerateParameters(
                    maxTokens: 1,
                    maxContextTokens: maxContextTokens,
                    kvBitsOverride: kvBitsOverride,
                    prefillStepSize: prefillStepSize,
                    temperature: 0.0,
                    topP: 1.0
                )
                // SPEC-037 FR-KVP1: the seed always models the tier-ELIGIBLE path, so it
                // must build a KVCacheSimple (maxKVSize=nil) — otherwise the
                // `as? [KVCacheSimple]` guard below never succeeds and no geometry is seeded.
                let kvCache = context.model.newCache(parameters: Self.cacheParameters(parameters, forceSimpleKV: true))
                let iterator = try TokenIterator(input: lmInput, model: context.model, cache: kvCache, parameters: parameters)
                // A single-token warmup populates the per-layer cache tensors; that is
                // all the seed needs (only the geometry is read, never the values).
                _ = try await blockingInferenceExecutor.run { _ in
                    BlockingGenerateResult(generate(input: lmInput, context: context, iterator: iterator) { (_: [Int]) in
                        GenerateDisposition.stop
                    })
                }
                // Only the v1-allowlisted unquantized class is serializable/persisted;
                // any other runtime skips the seed exactly as it skips persistence.
                // MEDIUM-A: if the forced-simple warmup did NOT produce a KVCacheSimple,
                // this loaded model's runtime does not support the disk tier at all
                // (a model family that overrides `newCache` and ignores `maxKVSize`,
                // e.g. gpt-oss/gemma-4/nemotron). Tell the operator ONCE at attach
                // rather than leaving every eligible request to skip observably but
                // silently at attach time. Log-only: the per-request observable skip in
                // captureSnapshot still covers correctness.
                guard let caches = kvCache as? [KVCacheSimple] else {
                    // Report the FIRST layer that is NOT KVCacheSimple (heterogeneous
                    // arrays whose layer 0 is simple but a later layer is not would
                    // otherwise be misreported as "KVCacheSimple"); fall back to the
                    // first layer's class, or "empty".
                    let className = (kvCache.first(where: { !($0 is KVCacheSimple) }) ?? kvCache.first)
                        .map { String(describing: type(of: $0)) } ?? "empty"
                    Self.logColdTierUnsupportedCacheClass(servedModelID: servedModelID, cacheClass: className)
                    return nil
                }
                guard let payloads = KVCacheSerialization.snapshotLayers(caches) else { return nil }
                return KVConversationColdTierAdapter.seedGeometryTemplate(fromPayloads: payloads)
            }
        } ?? nil
        if let template, !template.isEmpty {
            adapter.seedTemplate(servedModelID: servedModelID, template: template)
        }
    }

    /// MEDIUM-A (SPEC-037) — warn ONCE at cold-tier attach when the loaded model's
    /// forced-simple warmup produces a cache class outside the v1 serialization
    /// allowlist (`KVCacheSimple`). Such a model cannot persist to the disk tier at
    /// all; every eligible request will skip observably (unsupported_cache_class), so
    /// this up-front line tells operators before the first request rather than only
    /// per-request. Log-only — no eligibility-short-circuit plumbing.
    private nonisolated static func logColdTierUnsupportedCacheClass(servedModelID: String, cacheClass: String) {
        let line = "event=kv_disk_tier_unsupported_model served_model_id=\(servedModelID) "
            + "cache_class=\(cacheClass) message=\"kv disk tier: model \(servedModelID) runtime produces "
            + "\(cacheClass), not KVCacheSimple; disk survival will not persist for this model\"\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    // MARK: - FR-KVP8 hot-tier (RAM) purge/status — independent of disk-tier enablement

    /// Purge a single hot (RAM) conversation entry, cancelling any queued cold-tier
    /// persist and fencing outstanding leases. Works regardless of whether the disk
    /// tier is enabled — a running serve owns its ConversationCache and must be able
    /// to remove hot-tier residency so it never keeps serving a purged prefix from
    /// RAM (FR-KVP8). Returns whether the hot tier held live state for the key.
    func purgeHotConversation(conversationKey: String) async -> Bool {
        await conversationCache.purgeHot(conversationKey: conversationKey)
    }

    /// Purge every hot (RAM) conversation entry, invalidating outstanding leases.
    /// Independent of disk-tier enablement (FR-KVP8).
    func purgeAllHotConversations() async {
        await conversationCache.purgeAllHot()
    }

    /// A snapshot of the hot (RAM) conversation cache residency for `kv-cache status`.
    func hotConversationStats() async -> (entries: Int, tokens: Int) {
        await conversationCache.snapshotStats()
    }

    #if DEBUG
    /// Test-only: seed a hot conversation entry (no completion needed) so the
    /// disabled-tier RAM purge/status path is exercisable end-to-end via the control
    /// socket. Sets only the cache offset — no MLX tensor state — so it runs headless.
    func seedHotConversationForTest(key: String, tokens: [Int32], modelID: String) async {
        guard let lease = await conversationCache.begin(
            conversationKey: key, incomingTokens: tokens, modelID: modelID, kvBits: nil) else { return }
        let cache = KVCacheSimple(); cache.offset = tokens.count
        await conversationCache.commit(lease, cache: ConversationCacheLayers([cache]), fullTokens: tokens)
    }

    /// Test-only: begin() a hot lookup and report the cached-prompt-token count, so a
    /// test can assert a post-purge begin is a cold-start miss (0). Aborts the lease.
    func hotCachedPromptTokensForTest(key: String, tokens: [Int32], modelID: String) async -> Int {
        guard let lease = await conversationCache.begin(
            conversationKey: key, incomingTokens: tokens, modelID: modelID, kvBits: nil) else { return 0 }
        let cached = lease.cachedPromptTokens
        await conversationCache.abort(lease)
        return cached
    }
    #endif

    /// Build the per-request cold-tier context (nil when the tier is not attached).
    /// The FR-KVP11 gate decision requires BOTH the synthetic key prefix and
    /// direct-HTTP provenance; the identity core carries the live model identity.
    private func coldContext(for request: ChatCompletionRequest, snapshot: RuntimeSnapshot) -> ConversationColdContext? {
        guard coldTierAttached else { return nil }
        // Evaluate the FR-KVP11 gate FIRST (key sub-namespace + direct-HTTP provenance),
        // independent of identity availability, so a gated request whose live identity is
        // unavailable still reaches the telemetry sink (FR-KVP12) instead of the cold
        // tier silently doing nothing. The pure resolution lives in
        // `ConversationColdContext.resolve` (unit-tested per missing input).
        let gated = KVDiskCacheGate.persists(
            conversationKey: request.conversationKey, provenance: request.ingestProvenance)
        return ConversationColdContext.resolve(
            gated: gated,
            requestModel: request.model,
            servedModelID: snapshot.modelID ?? request.model,
            modelSHA256: snapshot.modelHash,
            // MEDIUM-5: the catalog revision is a SEPARATE identity field from the model
            // artifact SHA (model_sha256). Absent ⇒ resolve() marks identity unavailable
            // (no promote/persist) rather than aliasing the artifact hash as the revision.
            catalogRevision: verifiedModelCatalogRevision,
            tokenizerConfigSHA256: currentTokenizerConfigSHA256,
            chatTemplateSHA256: currentChatTemplateSHA256)
    }

    func measureStartupThroughput(maxTokens: Int = 8) async -> Double {
        guard let container = currentContainer else {
            return 0.0
        }

        do {
            let start = Date()
            let maxContextTokens = maxContextTokens
            let kvBitsOverride = kvBitsOverride
            let prefillStepSize = prefillStepSize
            let blockingInferenceExecutor = blockingInferenceExecutor
            let result: BlockingGenerateResult = try await inferenceGate.withPermit {
                try await container.perform { context in
                    let input = UserInput(chat: [.user("Reply with a short greeting.")])
                    let lmInput = try await context.processor.prepare(input: input)
                    let parameters = Self.makeServeGenerateParameters(
                        maxTokens: maxTokens,
                        maxContextTokens: maxContextTokens,
                        kvBitsOverride: kvBitsOverride,
                        prefillStepSize: prefillStepSize,
                        temperature: 0.0,
                        topP: 1.0
                    )
                    return try await blockingInferenceExecutor.run { _ in
                        BlockingGenerateResult(try generate(input: lmInput, parameters: parameters, context: context) { (_: [Int]) in
                            GenerateDisposition.more
                        })
                    }
                }
            }
            let elapsed = max(Date().timeIntervalSince(start), 0.001)
            return Double(result.generationTokenCount) / elapsed
        } catch {
            return 0.0
        }
    }

    private static func validateTokenizerCompatibility(
        target: ModelContainer,
        targetDirectory: URL,
        draft: ModelContainer,
        draftDirectory: URL
    ) async throws {
        guard let targetFingerprint = try tokenizerArtifactFingerprint(in: targetDirectory),
              let draftFingerprint = try tokenizerArtifactFingerprint(in: draftDirectory),
              targetFingerprint == draftFingerprint
        else {
            throw SpecDecodeStartupError.tokenizerMismatch
        }
        let targetTokenizer = await target.tokenizer
        let draftTokenizer = await draft.tokenizer
        guard tokenizersAreCompatible(targetTokenizer: targetTokenizer, draftTokenizer: draftTokenizer) else {
            throw SpecDecodeStartupError.tokenizerMismatch
        }
    }

    static func tokenizersAreCompatible(
        targetTokenizer: MLXLMCommon.Tokenizer,
        draftTokenizer: MLXLMCommon.Tokenizer
    ) -> Bool {
        let probes = [
            "",
            "hello",
            "Write a Swift function named iso8601DayPrefix.",
            "<|endoftext|>",
            "JSON {\"role\":\"user\",\"content\":\"test\"}",
        ]
        guard targetTokenizer.eosToken == draftTokenizer.eosToken,
              targetTokenizer.unknownToken == draftTokenizer.unknownToken
        else {
            return false
        }
        for probe in probes {
            guard targetTokenizer.encode(text: probe, addSpecialTokens: true) == draftTokenizer.encode(text: probe, addSpecialTokens: true),
                  targetTokenizer.encode(text: probe, addSpecialTokens: false) == draftTokenizer.encode(text: probe, addSpecialTokens: false)
            else {
                return false
            }
        }
        return true
    }

    private static func runSpeculativeStartupProbe(
        target: ModelContainer,
        draft: ModelContainer,
        numDraftTokens: Int,
        maxContextTokens: Int,
        kvBitsOverride: Int?,
        prefillStepSize: Int,
        blockingInferenceExecutor: BlockingInferenceExecutor
    ) async throws {
        do {
            _ = try await target.perform { targetContext in
                let input = UserInput(prompt: "spec028 startup probe")
                let lmInput = try await targetContext.processor.prepare(input: input)
                try validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
                let parameters = GenerateParameters(
                    maxTokens: 1,
                    maxKVSize: maxContextTokens,
                    kvBits: kvBitsOverride,
                    temperature: 0.0,
                    topP: 1.0,
                    prefillStepSize: prefillStepSize
                )
                return try await speculativeTokenIDs(
                    input: lmInput,
                    parameters: parameters,
                    targetContext: targetContext,
                    draft: draft,
                    numDraftTokens: numDraftTokens,
                    blockingInferenceExecutor: blockingInferenceExecutor
                )
            }
        } catch let error as SpecDecodeStartupError {
            throw error
        } catch {
            throw SpecDecodeStartupError.probeFailed(String(describing: error))
        }
    }

    private static func runSpeculativeEquivalenceCanary(
        target: ModelContainer,
        draft: ModelContainer,
        targetModelID: String,
        numDraftTokens: Int,
        maxContextTokens: Int,
        kvBitsOverride: Int?,
        prefillStepSize: Int,
        blockingInferenceExecutor: BlockingInferenceExecutor
    ) async throws {
        let request = try spec028EquivalenceRequest(targetModelID: targetModelID)
        let tokenPair = try await target.perform { targetContext in
            let input = try userInput(for: request)
            let lmInput = try await targetContext.processor.prepare(input: input)
            try validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
            let parameters = GenerateParameters(
                maxTokens: request.maxTokens,
                maxKVSize: maxContextTokens,
                kvBits: kvBitsOverride,
                temperature: 0.0,
                topP: 1.0,
                prefillStepSize: prefillStepSize
            )
            let plain = try await plainTokenIDs(
                input: lmInput,
                parameters: parameters,
                context: targetContext,
                blockingInferenceExecutor: blockingInferenceExecutor
            )
            let speculative = try await speculativeTokenIDs(
                input: lmInput,
                parameters: parameters,
                targetContext: targetContext,
                draft: draft,
                numDraftTokens: numDraftTokens,
                blockingInferenceExecutor: blockingInferenceExecutor
            )
            return (plain, speculative)
        }
        try validateSpeculativeEquivalence(plain: tokenPair.0, speculative: tokenPair.1)
    }

    static func validateSpeculativeEquivalence(plain: [Int], speculative: [Int]) throws {
        guard plain == speculative else {
            throw SpecDecodeStartupError.equivalenceFailed(plain: plain, speculative: speculative)
        }
    }

    private static func plainTokenIDs(
        input: LMInput,
        parameters: GenerateParameters,
        context: ModelContext,
        blockingInferenceExecutor: BlockingInferenceExecutor
    ) async throws -> [Int] {
        let cache = context.model.newCache(parameters: parameters)
        let iterator = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters)
        let result: BlockingGenerateResult = try await blockingInferenceExecutor.run { inferenceCancellation in
            BlockingGenerateResult(generate(input: input, context: context, iterator: iterator) { _ in
                if inferenceCancellation.isCancelled {
                    return GenerateDisposition.stop
                }
                return GenerateDisposition.more
            })
        }
        return result.tokenIds
    }

    private static func speculativeTokenIDs(
        input: LMInput,
        parameters: GenerateParameters,
        targetContext: ModelContext,
        draft: ModelContainer,
        numDraftTokens: Int,
        blockingInferenceExecutor: BlockingInferenceExecutor
    ) async throws -> [Int] {
        try await draft.perform(nonSendable: (input, targetContext)) { draftContext, values in
            let (input, targetContext) = values
            return try await blockingInferenceExecutor.run { inferenceCancellation in
                let draftCache = draftContext.model.newCache(parameters: parameters)
                var iterator = try SpeculativeTokenIterator(
                    input: input,
                    mainModel: targetContext.model,
                    draftModel: draftContext.model,
                    draftCache: draftCache,
                    parameters: parameters,
                    numDraftTokens: numDraftTokens
                )
                let stopTokenIDs = Self.generationStopTokenIDs(for: targetContext)
                var tokenIDs: [Int] = []
                while let token = iterator.next() {
                    if inferenceCancellation.isCancelled {
                        throw CancellationError()
                    }
                    if token == targetContext.tokenizer.unknownTokenId || stopTokenIDs.contains(token) {
                        iterator.discardGeneratedToken()
                        break
                    }
                    tokenIDs.append(token)
                }
                Stream().synchronize()
                return tokenIDs
            }
        }
    }

    private static func spec028EquivalenceRequest(targetModelID: String) throws -> ChatCompletionRequest {
        let data = try spec028EquivalenceFixtureBytes()
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpecDecodeStartupError.fixtureInvalid("root is not an object")
        }
        object["model"] = targetModelID
        let requestData = try JSONSerialization.data(withJSONObject: object)
        return try ChatCompletionRequest.parse(data: requestData)
    }

    private static func spec028EquivalenceFixtureBytes() throws -> Data {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("Tests/Fixtures/spec028/equivalence-smoke-v1.json"),
            cwd.appendingPathComponent("phase3-binary/Tests/Fixtures/spec028/equivalence-smoke-v1.json"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/Fixtures/spec028/equivalence-smoke-v1.json"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try Data(contentsOf: url)
        }
        throw SpecDecodeStartupError.fixtureMissing
    }

    private static func loadLocalContainer(from target: String) async throws -> (ModelContainer, URL) {
        let directory = try localModelDirectory(for: target)
        // mlx-swift-lm 3.x requires an explicit tokenizer loader. The provider
        // preflight has already verified model_artifact_path/model_artifact_sha256,
        // so load directly from the resolved local snapshot instead of downloading.
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
        return (container, directory)
    }

    static func localModelDirectory(for target: String) throws -> URL {
        let expanded = (target as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || FileManager.default.fileExists(atPath: expanded) {
            let url = URL(fileURLWithPath: expanded)
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return url
            }
        }
        if let cachedSnapshot = localHuggingFaceSnapshot(for: target) {
            return cachedSnapshot
        }
        throw ModelRuntimeLoadError(target: target)
    }

    static func validatePromptTokenCount(_ promptTokens: Int, maxContextTokens: Int) throws {
        guard promptTokens <= maxContextTokens else {
            throw APIError(
                status: 413,
                message: "Prompt length (\(promptTokens) tokens) exceeds this provider's safe capacity (\(maxContextTokens) tokens).",
                type: "context_length_exceeded",
                code: "context_length_exceeded",
                param: "messages"
            )
        }
    }

    static func validateReady(_ state: SwapState) throws {
        guard state == .ready else {
            throw providerLoadingError()
        }
    }

    static func providerLoadingError() -> APIError {
        APIError(
            status: 503,
            message: "Provider is loading a new model and is temporarily unavailable. Retry after the indicated interval.",
            type: "service_unavailable",
            code: "provider_loading"
        )
    }

    private nonisolated static func withDrainCancellation<T: Sendable>(
        _ token: DrainCancelToken,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                while !token.isFired {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                throw DrainCancelledError()
            }
            guard let result = try await group.next() else {
                throw DrainCancelledError()
            }
            group.cancelAll()
            return result
        }
    }

    private static func defaultMaxContextTokens() -> Int {
        ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil).maxContextTokens
    }

    static func localHuggingFaceSnapshot(for modelID: String) -> URL? {
        let parts = modelID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        let repoDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(parts[0])--\(parts[1])")
        let refsMain = repoDirectory.appendingPathComponent("refs/main")

        guard let revision = try? String(contentsOf: refsMain, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !revision.isEmpty
        else {
            return nil
        }

        let snapshot = repoDirectory.appendingPathComponent("snapshots/\(revision)")
        guard FileManager.default.fileExists(atPath: snapshot.path) else {
            return nil
        }
        return snapshot
    }

    /// SPEC-037 HIGH-8 — hash the loaded model's LIVE tokenizer configuration and
    /// chat-template bytes for the KV envelope identity. Returns nil for either hash
    /// that is genuinely unreachable, so the cold tier treats identity as unavailable
    /// and skips persistence rather than deriving a fake hash from the model hash.
    ///
    /// - config hash: SHA-256 over the labelled bytes of `tokenizer_config.json` and
    ///   `tokenizer.json` (whichever are present). Nil when neither exists.
    /// - template hash: SHA-256 over a dedicated chat-template file if present, else
    ///   over the `chat_template` field inside `tokenizer_config.json`. Nil when no
    ///   chat template is discoverable.
    static func tokenizerIdentityHashes(in directory: URL) -> (config: String?, template: String?) {
        let fm = FileManager.default
        func bytes(_ name: String) -> Data? {
            let url = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { return nil }
            return try? Data(contentsOf: url)
        }
        func hex(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        var configData = Data()
        var configAny = false
        for name in ["tokenizer_config.json", "tokenizer.json"] {
            if let d = bytes(name) {
                configData.append(Data((name + "\u{0}").utf8))
                configData.append(d)
                configAny = true
            }
        }
        let configHash = configAny ? hex(configData) : nil

        var templateData: Data?
        for name in ["chat_template.jinja", "chat_template.json", "chat_template.txt"] {
            if let d = bytes(name) { templateData = Data((name + "\u{0}").utf8) + d; break }
        }
        if templateData == nil, let cfg = bytes("tokenizer_config.json"),
           let obj = try? JSONSerialization.jsonObject(with: cfg) as? [String: Any],
           let template = obj["chat_template"] as? String {
            templateData = Data(("chat_template\u{0}" + template).utf8)
        }
        let templateHash = templateData.map(hex)
        return (configHash, templateHash)
    }

    static func modelWeightArtifactManifestHash(in directory: URL) throws -> String? {
        let fileManager = FileManager.default
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard url.pathExtension == "safetensors" else { return false }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !fileURLs.isEmpty else { return nil }

        let files = try fileURLs.map { url in
            let contentURL = url.resolvingSymlinksInPath()
            let attributes = try FileManager.default.attributesOfItem(atPath: contentURL.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            return ModelWeightManifestFile(
                name: url.lastPathComponent,
                sha256: try sha256Hex(ofFileAt: contentURL),
                size: size
            )
        }
        let manifest = ModelWeightManifest(files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        return hexString(SHA256.hash(data: data))
    }

    static func tokenizerArtifactFingerprint(in directory: URL) throws -> String? {
        let fileManager = FileManager.default
        let hasFastTokenizer = fileManager.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path)
        let tokenizerArtifactNames = hasFastTokenizer
            ? [
                "tokenizer.json",
                "tokenizer_config.json",
                "special_tokens_map.json",
                "added_tokens.json",
            ]
            : [
                "tokenizer_config.json",
                "special_tokens_map.json",
                "tokenizer.model",
                "vocab.json",
                "merges.txt",
                "added_tokens.json",
            ]
        let files = try tokenizerArtifactNames.compactMap { name -> TokenizerArtifactManifestFile? in
            let url = directory.appendingPathComponent(name)
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                return nil
            }
            let contentURL = url.resolvingSymlinksInPath()
            let data = try tokenizerArtifactFingerprintData(for: contentURL, name: name)
            return TokenizerArtifactManifestFile(
                name: name,
                sha256: hexString(SHA256.hash(data: data)),
                size: UInt64(data.count)
            )
        }

        guard !files.isEmpty else { return nil }

        let manifest = TokenizerArtifactManifest(files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        return hexString(SHA256.hash(data: data))
    }

    private static func tokenizerArtifactFingerprintData(for url: URL, name: String) throws -> Data {
        let data = try Data(contentsOf: url)
        guard name == "tokenizer_config.json",
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return data
        }
        // Chat-template default prompt text can differ across same-vocabulary
        // draft/target repos. Runtime token probes plus the equivalence canary
        // remain the authority for whether such a pair is actually compatible.
        root.removeValue(forKey: "chat_template")
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hexString(hasher.finalize())
    }

    private static func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func validObservedModelHash(_ hash: String?) -> String? {
        guard let hash, hash.utf8.count == 64 else {
            if let hash, !hash.isEmpty {
                FileHandle.standardError.write(Data("AC-46: validObservedModelHash rejected malformed value: \(hash.prefix(16))...\n".utf8))
            }
            return nil
        }
        guard hash.utf8.allSatisfy({ byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }) else {
            FileHandle.standardError.write(Data("AC-46: validObservedModelHash rejected non-hex value: \(hash.prefix(16))...\n".utf8))
            return nil
        }
        return hash
    }

    private static func applyOutputFilters(
        _ text: String,
        stopTokenFilter: StopTokenFilter,
        requestStops: [String]
    ) -> (text: String, hitStop: Bool) {
        let stripped = stopTokenFilter.stripping(from: text)
        var earliestStop: String.Index?
        for stop in requestStops where !stop.isEmpty {
            if let range = stripped.range(of: stop) {
                if earliestStop == nil || range.lowerBound < earliestStop! {
                    earliestStop = range.lowerBound
                }
            }
        }
        if let earliestStop {
            return (String(stripped[..<earliestStop]), true)
        }
        return (stripped, false)
    }

    static func cachedPromptUTF8Bytes(
        promptTokenIds: [Int32],
        cachedPromptTokens: Int,
        decode: ([Int]) -> String
    ) -> Int {
        let clamped = max(0, min(cachedPromptTokens, promptTokenIds.count))
        guard clamped > 0 else { return 0 }
        let prefixTokens = promptTokenIds.prefix(clamped).map(Int.init)
        return decode(Array(prefixTokens)).utf8.count
    }

    private static func streamingSafePrefix(
        _ text: String,
        stopTokenFilter: StopTokenFilter,
        requestStops: [String]
    ) -> (text: String, hitStop: Bool) {
        let filtered = applyOutputFilters(
            text,
            stopTokenFilter: stopTokenFilter,
            requestStops: requestStops
        )
        guard !filtered.hitStop else {
            return filtered
        }

        let candidates = stopTokenFilter.tokens + requestStops.filter { !$0.isEmpty }
        let holdback = longestSuffixPrefixLength(in: filtered.text, candidates: candidates)
        guard holdback > 0 else {
            return filtered
        }
        return (String(filtered.text.dropLast(holdback)), false)
    }

    private static func longestSuffixPrefixLength(in text: String, candidates: [String]) -> Int {
        guard !text.isEmpty, !candidates.isEmpty else { return 0 }
        let maxLength = min(text.count, candidates.map(\.count).max() ?? 0)
        guard maxLength > 0 else { return 0 }

        var longest = 0
        for length in 1 ... maxLength {
            let suffix = String(text.suffix(length))
            if candidates.contains(where: { $0.hasPrefix(suffix) }) {
                longest = length
            }
        }
        return longest
    }

    private static func delta(from emitted: String, to current: String) -> String {
        guard current.hasPrefix(emitted) else { return "" }
        return String(current.dropFirst(emitted.count))
    }

    struct ParsedGeneratedOutput: Sendable {
        let content: String
        let toolCalls: [ToolCall]
        let completionTokens: Int
        let generatedCompletionTokens: Int
        let hitStop: Bool
        let isTerminal: Bool
    }

    static func parseGeneratedOutput(
        filteredText: String,
        generatedTokenIDs: [Int],
        decode: ([Int]) -> String,
        request: ChatCompletionRequest,
        mode: HarmonyResponseParser.Mode,
        defaultCompletionTokens: Int,
        stopTokenFilter: StopTokenFilter = StopTokenFilter(tokens: []),
        requestStops: [String] = [],
        globalHitStop: Bool = false
    ) throws -> ParsedGeneratedOutput {
        guard HarmonyResponseParser.isHarmonyModelID(request.model) else {
            let parsed = parseToolCallsIfRequested(filteredText, request: request)
            return ParsedGeneratedOutput(
                content: parsed.content,
                toolCalls: parsed.toolCalls,
                completionTokens: defaultCompletionTokens,
                generatedCompletionTokens: defaultCompletionTokens,
                hitStop: false,
                isTerminal: true
            )
        }

        let parsed = HarmonyResponseParser.parse(
            tokenIDs: generatedTokenIDs,
            decode: decode,
            allowedFunctionNames: toolFunctionNames(from: request.promptSource.tools),
            mode: mode,
            stopCandidates: stopTokenFilter.tokens + requestStops
        )
        return try harmonyParsedOutput(
            from: parsed,
            decode: decode,
            stopTokenFilter: stopTokenFilter,
            requestStops: requestStops,
            globalHitStop: globalHitStop,
            countCompletionTokens: true,
            generatedCompletionTokens: defaultCompletionTokens
        )
    }

    private static func harmonyParsedOutput(
        from parsed: HarmonyResponseParser.ParseResult,
        decode: ([Int]) -> String,
        stopTokenFilter: StopTokenFilter,
        requestStops: [String],
        globalHitStop: Bool = false,
        countCompletionTokens: Bool,
        generatedCompletionTokens: Int = 0
    ) throws -> ParsedGeneratedOutput {
        guard parsed.status != .malformed, parsed.status != .notApplicable else {
            throw harmonyResponseError(for: parsed.failure)
        }
        let filteredVisible = applyOutputFilters(
            parsed.content ?? "",
            stopTokenFilter: stopTokenFilter,
            requestStops: requestStops
        )
        guard !globalHitStop || filteredVisible.hitStop else {
            throw malformedHarmonyResponseError()
        }
        let toolCalls = filteredVisible.hitStop ? [] : parsed.toolCalls
        let hasToolCalls = !toolCalls.isEmpty
        let visibleContent = hasToolCalls ? "" : filteredVisible.text
        return ParsedGeneratedOutput(
            content: visibleContent,
            toolCalls: toolCalls,
            completionTokens: countCompletionTokens ? harmonyVisibleFinalTokenCount(
                tokenIDs: parsed.finalContentTokenIDs,
                parsedContent: parsed.content ?? "",
                visibleText: visibleContent,
                decode: decode
            ) : 0,
            generatedCompletionTokens: generatedCompletionTokens,
            hitStop: filteredVisible.hitStop,
            isTerminal: parsed.status == .parsed
        )
    }

    private static func harmonyVisibleFinalTokenCount(
        tokenIDs: [Int],
        parsedContent: String,
        visibleText: String,
        decode: ([Int]) -> String
    ) -> Int {
        guard !visibleText.isEmpty, !tokenIDs.isEmpty else { return 0 }
        guard visibleText != parsedContent else { return tokenIDs.count }
        for count in 1 ... tokenIDs.count {
            let prefix = decode(Array(tokenIDs.prefix(count)))
            if prefix == visibleText || prefix.hasPrefix(visibleText) {
                return count
            }
            if !visibleText.hasPrefix(prefix) {
                return max(0, count - 1)
            }
        }
        return tokenIDs.count
    }

    static func malformedHarmonyResponseError() -> APIError {
        APIError(
            status: 502,
            message: "Malformed Harmony tool-call response",
            type: "upstream_provider_error",
            code: "malformed_tool_call_final_json",
            inferenceRan: true,
            settlementRan: true
        )
    }

    static func harmonyResponseError(for failure: HarmonyResponseParser.Failure?) -> APIError {
        switch failure {
        case .perCallByteCapExceeded:
            return APIError(
                status: 502,
                message: "Tool call arguments exceeded 1048576 bytes",
                type: "upstream_provider_error",
                code: "byte_cap_exceeded",
                inferenceRan: true,
                settlementRan: true
            )
        case .responseByteCapExceeded:
            return APIError(
                status: 502,
                message: "Tool call arguments exceeded 2097152 bytes",
                type: "upstream_provider_error",
                code: "response_byte_cap_exceeded",
                inferenceRan: true,
                settlementRan: true
            )
        case .malformed, .none:
            return malformedHarmonyResponseError()
        }
    }

    private static func parseToolCallsIfRequested(_ text: String, request: ChatCompletionRequest) -> (content: String, toolCalls: [ToolCall]) {
        guard let allowedFunctionNames = toolFunctionNames(from: request.promptSource.tools) else {
            return (text, [])
        }
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: text,
            modelID: request.model,
            allowedFunctionNames: allowedFunctionNames
        )
        guard !parsed.toolCalls.isEmpty else {
            return (text, [])
        }
        return ("", parsed.toolCalls)
    }

    private static func requiresStructuredValidation(_ responseFormat: ResponseFormat) -> Bool {
        switch responseFormat {
        case .text:
            return false
        case .jsonObject, .jsonSchema:
            return true
        }
    }

    private static func userInput(for request: ChatCompletionRequest) throws -> UserInput {
        let structuredMessages = try StructuredOutputRenderer.prependResponseFormatInstruction(
            to: request.messages,
            responseFormat: request.responseFormat,
            modelID: request.model
        )
        return UserInput(
            chat: try ToolPromptRenderer.renderMessages(structuredMessages, modelID: request.model),
            tools: Self.mlxToolsForTemplate(from: request.promptSource.tools)
        )
    }

    private static func internalWarmupRequest(modelID: String?, prompt: String, maxTokens: Int) throws -> ChatCompletionRequest {
        let body: [String: Any] = [
            "model": modelID ?? "internal-warmup",
            "messages": [
                [
                    "role": "user",
                    "content": prompt,
                ],
            ],
            "max_tokens": maxTokens,
            "temperature": 0,
            "top_p": 1,
        ]
        return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
    }

    private static func validateStructuredCompletion(_ completion: CompletionResult, request: ChatCompletionRequest) throws -> CompletionResult {
        if completion.toolCalls?.isEmpty == false {
            return completion
        }
        switch request.responseFormat {
        case .text:
            return completion
        case .jsonObject:
            _ = try parseStructuredJSONContent(completion.content, requireObjectOrArray: true)
            return completion
        case .jsonSchema(let spec):
            let parsed = try parseStructuredJSONContent(completion.content, requireObjectOrArray: false)
            do {
                try JSONSchemaValidator.validateInstance(parsed, against: spec.schema)
            } catch let error as APIError {
                throw error
            } catch {
                throw APIError(
                    status: 502,
                    message: "Schema validation aborted before completion",
                    type: "upstream_provider_error",
                    code: "json_schema_validation_failed",
                    param: "",
                    inferenceRan: true,
                    settlementRan: true
                )
            }
            return completion
        }
    }

    static func validateStructuredStreamingCompletion(
        _ completion: CompletionResult,
        request: ChatCompletionRequest,
        buyerVisibleContent: String
    ) throws -> CompletionResult {
        guard requiresStructuredValidation(request.responseFormat), completion.toolCalls?.isEmpty != false else {
            return completion
        }
        let visibleCompletion = CompletionResult(
            content: buyerVisibleContent,
            finishReason: completion.finishReason,
            promptTokens: completion.promptTokens,
            cachedPromptTokens: completion.cachedPromptTokens,
            kvCacheBytesReused: completion.kvCacheBytesReused,
            completionTokens: completion.completionTokens,
            generatedCompletionTokens: completion.generatedCompletionTokens,
            ttftMilliseconds: completion.ttftMilliseconds,
            // Architect LOW: forward the decode-window so the structured
            // streaming path's usage carries `macprovider_generation_ms`
            // instead of null, matching the non-structured path.
            generationMilliseconds: completion.generationMilliseconds,
            toolCalls: completion.toolCalls,
            modelHashObserved: completion.modelHashObserved,
            specDecodeDraftedTokens: completion.specDecodeDraftedTokens,
            specDecodeAcceptedTokens: completion.specDecodeAcceptedTokens,
            specDecodeGeneration: completion.specDecodeGeneration
        )
        return try validateStructuredCompletion(visibleCompletion, request: request)
    }

    static func synthesizeIdleTimeoutResultOrThrow(
        accumulator: StructuredStreamingContentAccumulator,
        request: ChatCompletionRequest,
        modelHash: String?
    ) throws -> CompletionResult {
        let content = accumulator.content
        let synthetic = CompletionResult(
            content: content,
            finishReason: "stop",
            promptTokens: 0,
            completionTokens: 0,
            ttftMilliseconds: 0,
            toolCalls: nil,
            modelHashObserved: validObservedModelHash(modelHash)
        )
        do {
            return try validateStructuredStreamingCompletion(
                synthetic,
                request: request,
                buyerVisibleContent: content
            )
        } catch {
            throw structuredStreamingProviderTimeoutError()
        }
    }

    // AC-V2-9 (SPEC-019 v0.2.4 §10): provider-idle breach validates the
    // buyer-visible buffer-as-of-close before emitting provider_timeout.
    static func withStructuredStreamingIdleTimeout<T: Sendable>(
        idleState: StructuredStreamingIdleState,
        timeout: TimeInterval = structuredStreamingIdleTimeoutSeconds,
        pollNanoseconds: UInt64 = 100_000_000,
        onIdleTimeout: @escaping @Sendable () throws -> T,
        operation: @escaping @Sendable (_ idleCancellation: DrainCancelToken) async throws -> T
    ) async throws -> T {
        guard idleState.enabled else {
            return try await operation(DrainCancelToken())
        }
        let idleCancellation = DrainCancelToken()
        return try await withThrowingTaskGroup(of: StructuredStreamingIdleRaceResult<T>.self) { group in
            group.addTask {
                do {
                    let result = try await operation(idleCancellation)
                    idleState.markOperationStopped()
                    if idleState.timedOut {
                        await Self.waitForStructuredStreamingIdleFinish(idleState)
                        throw DrainCancelledError()
                    }
                    return .operation(result)
                } catch {
                    idleState.markOperationStopped()
                    if idleState.timedOut {
                        await Self.waitForStructuredStreamingIdleFinish(idleState)
                        throw DrainCancelledError()
                    }
                    throw error
                }
            }
            group.addTask {
                while !idleState.isFinished {
                    try await Task.sleep(nanoseconds: pollNanoseconds)
                    if idleState.hasTimedOut(timeout: timeout) {
                        idleState.markTimedOut()
                        idleCancellation.fire()
                        // AC-V2-9 buffer-as-of-close: if the operation
                        // task does not stop within the wait budget we
                        // cannot guarantee a clean snapshot ("close"
                        // event happened, but the accumulator may
                        // still be in flux). Fail closed with
                        // provider_timeout rather than emit a possibly-
                        // stale validation result.
                        let stoppedCleanly = await Self.waitForStructuredStreamingOperationStopped(idleState)
                        if !stoppedCleanly {
                            throw Self.structuredStreamingProviderTimeoutError()
                        }
                        return .idle(try onIdleTimeout())
                    }
                }
                throw DrainCancelledError()
            }
            do {
                while let result = try await group.next() {
                    switch result {
                    case .operation(let value):
                        idleState.markFinished()
                        group.cancelAll()
                        return value
                    case .idle(let value):
                        idleState.markFinished()
                        group.cancelAll()
                        return value
                    }
                }
                throw DrainCancelledError()
            } catch {
                idleState.markFinished()
                group.cancelAll()
                throw error
            }
        }
    }

    private static func waitForStructuredStreamingOperationStopped(
        _ idleState: StructuredStreamingIdleState,
        maxNanoseconds: UInt64 = 100_000_000,
        pollNanoseconds: UInt64 = 10_000_000
    ) async -> Bool {
        var waited: UInt64 = 0
        while !idleState.operationStopped && waited < maxNanoseconds {
            try? await Task.sleep(nanoseconds: pollNanoseconds)
            waited += pollNanoseconds
        }
        return idleState.operationStopped
    }

    private static func waitForStructuredStreamingIdleFinish(
        _ idleState: StructuredStreamingIdleState,
        pollNanoseconds: UInt64 = 10_000_000
    ) async {
        while !idleState.isFinished {
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    private static func structuredStreamingProviderTimeoutError() -> APIError {
        APIError(
            status: 504,
            message: "Provider emitted no buyer-visible structured-output content delta within 60 seconds",
            type: "upstream_provider_error",
            code: "provider_timeout",
            inferenceRan: true,
            settlementRan: true
        )
    }

    private static func parseStructuredJSONContent(_ content: String, requireObjectOrArray: Bool) throws -> MacProviderCore.JSONValue {
        // Whitespace-only output is classified as empty per SPEC-019 §5
        // empty-content override; this prevents `retryable:true` on
        // deterministic whitespace-emit failures.
        guard !content.filter({ !Self.isASCIIStructuredOutputWhitespace($0) }).isEmpty else {
            throw APIError(
                status: 502,
                message: "Model emitted zero tokens for the requested schema; adjust `temperature` / `seed` (for stochastic models), or modify the prompt or schema before retrying — automatic same-request retry will not succeed. If you intended free-form prose, send response_format: {\"type\":\"text\"} or omit the field. Per SPEC-019 v0.1.0, json_object now enforces top-level JSON; this is a breaking change from earlier versions where json_object was a silent no-op.",
                type: "upstream_provider_error",
                code: "malformed_json_response",
                param: "",
                retryable: false,
                inferenceRan: true,
                settlementRan: true
            )
        }
        let parsed: MacProviderCore.JSONValue
        do {
            parsed = try StrictJSONParser.parse(content)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError(
                status: 502,
                message: "Model output was not valid JSON for the requested response_format. If you intended free-form prose, send response_format: {\"type\":\"text\"} or omit the field. Per SPEC-019 v0.1.0, json_object now enforces top-level JSON; this is a breaking change from earlier versions where json_object was a silent no-op.",
                type: "upstream_provider_error",
                code: "malformed_json_response",
                param: "",
                inferenceRan: true,
                settlementRan: true
            )
        }
        if requireObjectOrArray {
            do {
                try JSONSchemaValidator.validateJSONObjectOrArray(parsed)
            } catch let error as APIError where error.code == "malformed_json_response" {
                throw error
            } catch let error as APIError where error.code == "json_schema_validation_failed" {
                throw APIError(
                    status: 502,
                    message: "Model output JSON exceeds the structured-output depth limit",
                    type: "upstream_provider_error",
                    code: "json_schema_validation_failed",
                    param: error.param ?? "",
                    inferenceRan: true,
                    settlementRan: true
                )
            }
        }
        return parsed
    }

    private static func isASCIIStructuredOutputWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r"
    }

    static func mlxToolsForTemplate(from value: MacProviderCore.JSONValue?) -> [[String: Any]]? {
        guard let value, case .array(let tools) = value, !tools.isEmpty else {
            return nil
        }
        let converted = tools.compactMap { tool -> [String: Any]? in
            guard case .object(let object) = tool,
                  case .object(let functionObject)? = object["function"],
                  case .string(let name)? = functionObject["name"],
                  let parameters = functionObject["parameters"]
            else {
                return nil
            }
            // Chat-template engines (swift-jinja via Tokenizers) reject
            // Foundation `NSNull` (issue #718). Represent every JSON null as a
            // native `Jinja.Value.null`, which `Value(any:)` passes through
            // unchanged, so the rendered schema keeps its keys and array
            // positions instead of silently dropping `enum:[null,…]`,
            // `const:null`, or positional defaults.
            // `description` is part of the receipt canonical tool subset, where
            // an absent key and an explicit `null` both canonicalize to JCS null
            // (PromptCanonicalizer.canonicalTool via jcsOrNull) — i.e. they share
            // one signed prompt hash. Render both as a native Jinja null so the
            // template the model actually sees cannot diverge from that hash.
            let description = functionObject["description"].map { jsonAnyForTemplate($0) } ?? Jinja.Value.null
            let function: [String: Any] = [
                "name": name,
                "description": description,
                "parameters": jsonAnyForTemplate(parameters),
            ]
            return [
                "type": "function",
                "function": function,
            ]
        }
        return converted.isEmpty ? nil : converted
    }

    private static func hasEnabledTools(_ value: MacProviderCore.JSONValue?) -> Bool {
        toolFunctionNames(from: value) != nil
    }

    private static func toolFunctionNames(from value: MacProviderCore.JSONValue?) -> Set<String>? {
        guard let value, case .array(let tools) = value, !tools.isEmpty else {
            return nil
        }
        let names = tools.compactMap { tool -> String? in
            guard case .object(let toolObject) = tool,
                  case .object(let functionObject)? = toolObject["function"],
                  case .string(let name)? = functionObject["name"],
                  !name.isEmpty
            else {
                return nil
            }
            return name
        }
        return names.isEmpty ? nil : Set(names)
    }

    /// Converts a JSONValue subtree into the `Any` graph the chat template
    /// consumes, preserving every key and array position. JSON null becomes a
    /// native `Jinja.Value.null` (not `NSNull` and not an omission): swift-jinja
    /// `Value(any:)` matches `case let value as Value` and passes it through,
    /// so `default:null`, `const:null`, `enum:[null,…]`, and positional array
    /// nulls survive round-trip with their original schema semantics (#718/#719).
    ///
    /// Recursion is bounded by the caller, not here: tool schemas are rejected
    /// at `validateTools` (ChatCompletionRequest) when they exceed
    /// `JSONSchemaValidator.maxDepth`, before `JSONValue.parse` builds the tree
    /// this walk consumes. So every value reaching here is already depth-capped,
    /// and the converter can stay a faithful shape-preserving pass with no
    /// silent truncation of over-deep subtrees.
    private static func jsonAnyForTemplate(_ value: MacProviderCore.JSONValue) -> Any {
        switch value {
        case .object(let object):
            var result: [String: Any] = [:]
            result.reserveCapacity(object.count)
            for (key, member) in object {
                result[key] = jsonAnyForTemplate(member)
            }
            return result
        case .array(let array):
            return array.map { jsonAnyForTemplate($0) }
        case .string(let string):
            return string
        case .int(let int):
            return int
        case .double(let double):
            return double
        case .bool(let bool):
            return bool
        case .null:
            return Jinja.Value.null
        }
    }

    private static func validateToolChoiceScope(_ request: ChatCompletionRequest) throws {
        if let toolChoice = request.promptSource.toolChoice,
           !isSupportedToolChoice(toolChoice)
        {
            throw APIError(
                status: 400,
                message: "tool_choice values other than auto are not supported by this provider",
                code: "unsupported_tool_choice"
            )
        }
    }

    private static func isSupportedToolChoice(_ value: MacProviderCore.JSONValue) -> Bool {
        switch value {
        case .string(let choice):
            return choice == "auto"
        case .null:
            return true
        default:
            return false
        }
    }
}

// `internal` (not `private`) so the allowlist fail-closed behavior is unit-testable via
// `@testable import macprovider_cli` (see NativeToolCallStreamEmitterTests).
struct NativeToolCallStreamEmitter {
    private let startDelimiter: String
    private let endDelimiter: String
    private let argumentKey: String
    /// Declared tools for this request. A streamed tool-call delta MUST NOT be emitted for
    /// any function name not in this set — otherwise a widened name grammar could surface an
    /// undeclared tool_call to the buyer before the final parser's fail-closed check
    /// (SPEC-018 §3.5). `nil`/empty means no tools were declared, so nothing may be emitted.
    private let allowedFunctionNames: Set<String>?
    /// Function-XML (`<function=…>`) is a Qwen-row-only grammar (SPEC-018 §3.1 v0.2.7). The
    /// streaming emitter mirrors the non-streaming parser's family gate: only Qwen models may
    /// stream `<function=…>` tool-call deltas; other families fall through to JSON parsing (which
    /// yields nothing for XML), so no non-Qwen family can stream a function-XML delta.
    private let allowsFunctionXML: Bool
    private var opened = false
    private var closed = false
    private var emittedArguments = ""
    private var callID = "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"

    init(modelID: String, allowedFunctionNames: Set<String>?) {
        self.allowedFunctionNames = allowedFunctionNames
        self.allowsFunctionXML = modelID.localizedCaseInsensitiveContains("qwen2.5")
            || modelID.localizedCaseInsensitiveContains("qwen3")
        if modelID.localizedCaseInsensitiveContains("llama-3.3") {
            startDelimiter = "<|python_tag|>"
            endDelimiter = "<|eom_id|>"
            argumentKey = "parameters"
        } else {
            startDelimiter = "<tool_call>"
            endDelimiter = "</tool_call>"
            argumentKey = "arguments"
        }
    }

    mutating func observe(_ text: String) -> [StreamChunk] {
        guard !closed else {
            return []
        }
        if let start = text.range(of: startDelimiter) {
            let afterStart = start.upperBound
            let bodyEnd = text.range(of: endDelimiter, range: afterStart..<text.endIndex)?.lowerBound ?? text.endIndex
            let body = String(text[afterStart..<bodyEnd])
            let isClosed = text.range(of: endDelimiter, range: afterStart..<text.endIndex) != nil
            if allowsFunctionXML, body.contains("<function=") {
                return observeNemotronXML(body: body, isClosed: isClosed)
            }
            return observeJSONToolCall(body: body, isClosed: isClosed)
        }
        if allowsFunctionXML, text.contains("<function=") {
            return observeNemotronXML(body: text, isClosed: false)
        }
        return []
    }

    private mutating func observeJSONToolCall(body: String, isClosed: Bool) -> [StreamChunk] {
        guard let name = stringField("name", in: body),
              let arguments = argumentPrefix(in: body)
        else {
            return []
        }
        // Fail closed: never stream a tool-call delta for an undeclared function name.
        guard let allowed = allowedFunctionNames, allowed.contains(name) else {
            return []
        }
        // Byte-cap parity with the final parser (SPEC-018 §3.4 / §10a #7): never stream oversized
        // arguments; stop the emitter once the cumulative arguments exceed the per-call cap.
        guard arguments.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP else {
            closed = true
            return []
        }

        var events: [StreamChunk] = []
        if !opened {
            opened = true
            events.append(.toolCallDelta(StreamToolCallDelta(index: 0, id: callID, type: "function", functionName: name, arguments: "")))
        }
        let fragment = Self.delta(from: emittedArguments, to: arguments)
        if !fragment.isEmpty {
            emittedArguments = arguments
            events.append(.toolCallDelta(StreamToolCallDelta(index: 0, id: nil, type: nil, functionName: nil, arguments: fragment)))
        }
        if isClosed {
            closed = true
        }
        return events
    }

    private mutating func observeNemotronXML(body: String, isClosed: Bool) -> [StreamChunk] {
        guard let name = ToolCallParser.nemotronFunctionName(in: body),
              let arguments = ToolCallParser.nemotronArgumentsJSON(in: body, includeIncomplete: isClosed)
        else {
            return []
        }
        // Fail closed: never stream a tool-call delta for an undeclared function name.
        guard let allowed = allowedFunctionNames, allowed.contains(name) else {
            return []
        }
        // Byte-cap parity with the final parser (SPEC-018 §3.4 / §10a #7): never stream oversized
        // arguments; stop the emitter once the cumulative arguments exceed the per-call cap.
        guard arguments.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP else {
            closed = true
            return []
        }

        var events: [StreamChunk] = []
        if !opened {
            opened = true
            events.append(.toolCallDelta(StreamToolCallDelta(index: 0, id: callID, type: "function", functionName: name, arguments: "")))
        }
        let fragment = Self.delta(from: emittedArguments, to: arguments)
        if !fragment.isEmpty {
            emittedArguments = arguments
            events.append(.toolCallDelta(StreamToolCallDelta(index: 0, id: nil, type: nil, functionName: nil, arguments: fragment)))
        }
        if isClosed {
            closed = true
        }
        return events
    }

    private func stringField(_ key: String, in body: String) -> String? {
        guard let keyRange = body.range(of: "\"\(key)\""),
              let colon = body.range(of: ":", range: keyRange.upperBound..<body.endIndex)
        else {
            return nil
        }
        var index = colon.upperBound
        while index < body.endIndex, body[index].isWhitespace {
            index = body.index(after: index)
        }
        guard index < body.endIndex, body[index] == "\"" else {
            return nil
        }
        index = body.index(after: index)
        var value = ""
        var escaped = false
        while index < body.endIndex {
            let ch = body[index]
            if escaped {
                value.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return value
            } else {
                value.append(ch)
            }
            index = body.index(after: index)
        }
        return nil
    }

    private func argumentPrefix(in body: String) -> String? {
        guard let keyRange = body.range(of: "\"\(argumentKey)\"") ?? body.range(of: #""arguments""#),
              let colon = body.range(of: ":", range: keyRange.upperBound..<body.endIndex)
        else {
            return nil
        }
        var index = colon.upperBound
        while index < body.endIndex, body[index].isWhitespace {
            index = body.index(after: index)
        }
        guard index < body.endIndex else {
            return nil
        }
        return String(body[index..<body.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func delta(from old: String, to new: String) -> String {
        guard new.hasPrefix(old) else {
            return new
        }
        return String(new.dropFirst(old.count))
    }
}

final class DrainCancelToken: @unchecked Sendable {
    private var _fired = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let lock = NSLock()

    var isFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fired
    }

    func check() throws {
        if isFired {
            throw DrainCancelledError()
        }
    }

    func fire() {
        let continuations: [CheckedContinuation<Void, Never>]
        lock.lock()
        if _fired {
            lock.unlock()
            return
        }
        _fired = true
        continuations = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitUntilFired() async {
        if isFired {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var shouldResume = false
            let id = UUID()
            lock.lock()
            if _fired {
                shouldResume = true
            } else {
                waiters[id] = continuation
            }
            lock.unlock()

            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private struct ModelWeightManifest: Encodable {
    let files: [ModelWeightManifestFile]
}

private struct ModelWeightManifestFile: Encodable {
    let name: String
    let sha256: String
    let size: UInt64
}

private struct TokenizerArtifactManifest: Encodable {
    let files: [TokenizerArtifactManifestFile]
}

private struct TokenizerArtifactManifestFile: Encodable {
    let name: String
    let sha256: String
    let size: UInt64
}

struct CompletionResult: Sendable {
    let content: String
    let finishReason: String
    let promptTokens: Int
    let cachedPromptTokens: Int
    let kvCacheReuseRatio: Double
    let kvCacheBytesReused: Int
    let completionTokens: Int
    let generatedCompletionTokens: Int
    let ttftMilliseconds: Int64?
    let generationMilliseconds: Int64?
    let toolCalls: [ToolCall]?
    let modelHashObserved: String?
    let specDecodeDraftedTokens: Int
    let specDecodeAcceptedTokens: Int
    let specDecodeGeneration: Int?

    init(
        content: String,
        finishReason: String,
        promptTokens: Int,
        cachedPromptTokens: Int = 0,
        kvCacheBytesReused: Int = 0,
        completionTokens: Int,
        generatedCompletionTokens: Int? = nil,
        ttftMilliseconds: Int64? = nil,
        generationMilliseconds: Int64? = nil,
        toolCalls: [ToolCall]? = nil,
        modelHashObserved: String? = nil,
        specDecodeDraftedTokens: Int = 0,
        specDecodeAcceptedTokens: Int = 0,
        specDecodeGeneration: Int? = nil
    ) {
        self.content = content
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        let clampedPromptTokens = max(0, promptTokens)
        let clampedCachedTokens = max(0, min(cachedPromptTokens, clampedPromptTokens))
        self.cachedPromptTokens = clampedCachedTokens
        self.kvCacheReuseRatio = clampedPromptTokens == 0 ? 0 : Double(clampedCachedTokens) / Double(clampedPromptTokens)
        self.kvCacheBytesReused = clampedCachedTokens == 0 ? 0 : max(0, kvCacheBytesReused)
        self.completionTokens = completionTokens
        self.generatedCompletionTokens = max(0, generatedCompletionTokens ?? completionTokens)
        self.ttftMilliseconds = ttftMilliseconds
        self.generationMilliseconds = generationMilliseconds
        self.toolCalls = toolCalls
        self.modelHashObserved = modelHashObserved
        self.specDecodeDraftedTokens = max(0, specDecodeDraftedTokens)
        self.specDecodeAcceptedTokens = max(0, min(specDecodeAcceptedTokens, specDecodeDraftedTokens))
        self.specDecodeGeneration = specDecodeGeneration
    }

    func withModelHashObservedIfMissing(_ observed: String?) -> CompletionResult {
        guard modelHashObserved == nil, let observed else { return self }
        return CompletionResult(
            content: content,
            finishReason: finishReason,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedPromptTokens,
            kvCacheBytesReused: kvCacheBytesReused,
            completionTokens: completionTokens,
            generatedCompletionTokens: generatedCompletionTokens,
            ttftMilliseconds: ttftMilliseconds,
            generationMilliseconds: generationMilliseconds,
            toolCalls: toolCalls,
            modelHashObserved: observed,
            specDecodeDraftedTokens: specDecodeDraftedTokens,
            specDecodeAcceptedTokens: specDecodeAcceptedTokens,
            specDecodeGeneration: specDecodeGeneration
        )
    }
}

private final class FirstTokenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamp: Date?

    func recordIfMissing(now: Date = Date()) {
        lock.lock()
        if timestamp == nil {
            timestamp = now
        }
        lock.unlock()
    }

    func elapsedMilliseconds(since start: Date) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard let timestamp else {
            return nil
        }
        return max(0, Int64(timestamp.timeIntervalSince(start) * 1000))
    }

    func durationMilliseconds(until end: Date) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard let timestamp else { return nil }
        return max(0, Int64(end.timeIntervalSince(timestamp) * 1000))
    }
}

private final class WarmupCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func record() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class StreamedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value {
            return false
        }
        value = true
        return true
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
