import Foundation
import CoreImage
import CryptoKit
import Darwin
import Jinja
import MLX
import MLXLLM
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import MacProviderCore
import Security
import Tokenizers

protocol ModelRuntimeServing: Actor {
    func localResponsesCapabilities() async -> LocalResponsesCapabilities
    func localTokenUtilityCapabilities() async -> LocalTokenUtilityCapabilities
    func localTokenUtility(_ request: LocalTokenUtilityRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> LocalTokenUtilityResult
    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult
    /// SPEC-015 §M.2 — return the runtime-owned snapshot that
    /// actually drove inference (validation, in-flight registration,
    /// generation) so the receipt can bind `model_hash` to the
    /// container that served. Atomically captured inside the actor
    /// turn — distinct from a caller-side `currentSnapshot()` sample,
    /// which can drift across an actor interleaving / warm-swap.
    func completeWithServedSnapshot(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> (CompletionResult, RuntimeSnapshot)
    func completeWithServedSnapshot(_ request: ChatCompletionRequest, with handle: RequestHandle, shouldCancel: @escaping @Sendable () -> Bool) async throws -> (CompletionResult, RuntimeSnapshot)
    func stream(_ request: ChatCompletionRequest, with handle: RequestHandle, shouldCancel: @escaping @Sendable () -> Bool, onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> CompletionResult
    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws
    func pagedKVPreflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws
    /// Tokenize through the active model processor without entering generation.
    /// SPEC-041 uses this exact count to enforce the buyer-declared input bound
    /// before emitting validation evidence or starting inference.
    func relayBlindPrepare(_ request: ChatCompletionRequest) async throws -> RelayBlindPreparedRequest
    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle
    /// SPEC-001-R011 local requests (chat and token utilities) observe the
    /// actual swap state and are tracked as local rows; network buyers on
    /// HTTP and the relay keep the snapshot-based `acquireRequestHandle`.
    func acquireLocalRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle
    func unregisterInFlight(_ id: Int)
    func currentSnapshot() async -> RuntimeSnapshot
    /// Identity/status surface the serve command reads to build ProviderStatus.
    /// The concrete MLX `ModelRuntime` witnesses these with actor-isolated
    /// members; loopback runtimes report their own GGUF-file identity. Every
    /// conformer implements them explicitly -- no protocol-extension default,
    /// which on an actor conformer would shadow the synchronous witness in an
    /// `await` context and silently no-op status/identity reads.
    var loadedModelHash: String? { get async }
    var loadedModelHashAlgorithm: String? { get async }
    var loadedWeightsManifestSHA256: String? { get async }
    var isLoaded: Bool { get async }
    func setProviderStatus(_ providerStatus: ProviderStatus) async
    /// Issue #1695: whether completions from this runtime may carry a signed
    /// SPEC-015 receipt at all. Every conformer declares it explicitly (no
    /// protocol-extension default) so a new loopback or fixture runtime cannot
    /// inherit receipt eligibility by omission. This is a CLI accident guard,
    /// not a security boundary: the coordinator settlement gate is the control.
    /// SPEC-015 §N.12 (#1690 M5) lifts it for one request at a time, only
    /// through a matching coordinator `pool_runtime_authorization`.
    nonisolated var isSettlementReceiptEligible: Bool { get }
    /// SPEC-015 §N.12: the SPEC-046 `runtime_source` a request's
    /// `pool_runtime_authorization` must name to let this runtime sign that
    /// request's v0.4 receipt. Nil for a runtime no pool authorization can
    /// enable. Declared explicitly by every conformer, as above.
    nonisolated var settlementRuntimeSource: String? { get }
}

struct RelayBlindPreparedRequest: @unchecked Sendable {
    let handle: RequestHandle
    let inputTokens: Int
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

/// When a streaming batched row emitted its first buyer-visible chunk. The
/// serial path reports TTFT from its own generate loop; without this a
/// streaming batched receipt fell back to the whole request duration.
/// Non-streaming receipts keep full generation latency (SPEC-015).
final class ContinuousBatchFirstTokenClock: @unchecked Sendable {
    private let lock = NSLock()
    private var firstTokenAt: Date?

    func mark(_ now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if firstTokenAt == nil { firstTokenAt = now }
    }

    /// Wraps the buyer chunk sink so the first chunk actually emitted (after
    /// stop, UTF-8 and tool filtering) marks the clock. Chunks emitted while
    /// replaying another waiter's tokens (`replay`) never mark it.
    func markingFirstChunk<Chunk>(replay: Bool, _ onChunk: @escaping (Chunk) -> Void) -> (Chunk) -> Void {
        { chunk in
            if !replay { self.mark() }
            onChunk(chunk)
        }
    }

    func ttftMilliseconds(since startedAt: Date) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard let firstTokenAt else { return nil }
        return max(0, Int64(firstTokenAt.timeIntervalSince(startedAt) * 1000))
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
    /// Runtimes without model swaps share their ordinary admission path.
    func acquireLocalRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        try acquireRequestHandle(request)
    }

    func localResponsesCapabilities() async -> LocalResponsesCapabilities { .unavailable }


    func localTokenUtilityCapabilities() async -> LocalTokenUtilityCapabilities {
        LocalTokenUtilityCapabilities(model: nil, modelHash: nil, generation: nil, operations: [])
    }


    func localTokenUtility(_ request: LocalTokenUtilityRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> LocalTokenUtilityResult {
        throw APIError(status: 501, message: "Runtime lacks exact tokenizer and template access", code: "token_utilities_unsupported")
    }

    func relayBlindPrepare(_ request: ChatCompletionRequest) async throws -> RelayBlindPreparedRequest {
        throw RelayBlindProviderError.providerUnsupported
    }

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

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        try await completeWithServedSnapshot(request, shouldCancel: shouldCancel)
    }
}

public struct RuntimeContinuousBatchingSchedulerSnapshot: Sendable, Equatable {
    public let activeDecodeRows: Int
    public let waitingCount: Int
    public let maxObservedBatchDepth: Int
    public let slotsTotal: Int
    public let slotsFree: Int
    public let sharedForwardCalls: Int
}

public struct RuntimeContinuousBatchingPolicySnapshot: Sendable, Equatable {
    public let authorizationSource: String
    public let loadStatus: String
    public let releaseID: String?
    public let policyVersion: String?
    public let signerKeyID: String?
    public let policySHA256: String?
    public let expiresAt: String?
    public let rolloutMode: String
    public let tupleSHA256: String?
    public let authorized: Bool
    public let cachedTurnsAuthorized: Bool
    public let emergencyOffOverride: Bool
    public let localProofResult: String
    public let decisionReason: String
}

public struct RuntimeContinuousBatchingSnapshot: Sendable, Equatable {
    public let mode: ContinuousBatchingMode
    public let active: Bool
    public let unsupportedReason: String?
    public let pagedKVDecision: String
    public let cacheClass: String
    public let policy: RuntimeContinuousBatchingPolicySnapshot
    public let scheduler: RuntimeContinuousBatchingSchedulerSnapshot?
    /// SPEC-038 v0.3.15 on-device self-check state; nil when none ran.
    public var selfCheck: ContinuousBatchingSelfCheckReport? = nil
}

struct RuntimeKVDiskTierSnapshot: Sendable, Equatable {
    let enabled: Bool
    let activated: Bool
    let unsupportedReason: String?
    let bytesUsed: Int?
    let maxBytes: Int
}

private struct KVDiskSeedResult: Sendable {
    let template: [KVLayerGeometry]?
    let unsupportedCacheClass: String?
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
    public let templateSupportsThinkingToggle: Bool
    public let templateSupportsPreserveThinking: Bool
    public let specDecodeGeneration: Int
    public let continuousBatching: RuntimeContinuousBatchingSnapshot?
    public let nativeMTPStatus: NativeMTPStatusSnapshot
    let nativeMTPCapability: NativeMTPCapability?
    let schedulerSupportsNativeMTP: Bool
    let nativeMTPTupleOffer: NativeMTPPublishedTupleOffer?
    let nativeVisionProfile: NativeVisionProfile?

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
        templateSupportsThinkingToggle: Bool = false,
        templateSupportsPreserveThinking: Bool = false,
        specDecodeGeneration: Int = 0,
        continuousBatching: RuntimeContinuousBatchingSnapshot? = nil,
        nativeMTPStatus: NativeMTPStatusSnapshot = NativeMTPStatusSink.disabled().snapshot(),
        nativeMTPCapability: NativeMTPCapability? = nil,
        schedulerSupportsNativeMTP: Bool = false,
        nativeMTPTupleOffer: NativeMTPPublishedTupleOffer? = nil,
        nativeVisionProfile: NativeVisionProfile? = nil
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
        self.templateSupportsThinkingToggle = templateSupportsThinkingToggle
        self.templateSupportsPreserveThinking = templateSupportsPreserveThinking
        self.specDecodeGeneration = specDecodeGeneration
        self.continuousBatching = continuousBatching
        self.nativeMTPStatus = nativeMTPStatus
        self.nativeMTPCapability = nativeMTPCapability
        self.schedulerSupportsNativeMTP = schedulerSupportsNativeMTP
        self.nativeMTPTupleOffer = nativeMTPTupleOffer
        self.nativeVisionProfile = nativeVisionProfile
    }

    var hasTargetCompatibleDraft: Bool {
        guard draftModelID != nil, let modelID, numDraftTokens != nil else {
            return false
        }
        return draftTargetModelID == modelID
    }
}

struct NativeMTPPublishedRuntimeTuple: Sendable, Equatable {
    let modelID: String
    let modelHash: String
    let modelHashAlgorithm: String
    let providerRevision: String
    let runtimeRevision: String
    let tokenizerDigest: String
    let artifactDigest: String
    let manifestDigest: String
    let sidecarDigest: String
    let providerBinarySHA256: String
    let runtimeCDHash: String
    let cacheNamespace: String
    let stateDigest: String
    let proposalDepth: Int

    var goCanonicalJSONString: String {
        let fields: [(String, String)] = [
            ("model_id", modelID),
            ("model_hash", modelHash),
            ("model_hash_algorithm", modelHashAlgorithm),
            ("provider_revision", providerRevision),
            ("runtime_revision", runtimeRevision),
            ("tokenizer_digest", tokenizerDigest),
            ("artifact_digest", artifactDigest),
            ("manifest_digest", manifestDigest),
            ("sidecar_digest", sidecarDigest),
            ("provider_binary_sha256", providerBinarySHA256),
            ("runtime_cdhash", runtimeCDHash),
            ("cache_namespace", cacheNamespace),
            ("state_digest", stateDigest),
        ]
        let body = fields
            .map { "\"\($0.0)\":\"\($0.1)\"" }
            .joined(separator: ",")
        return "{\(body),\"proposal_depth\":\(proposalDepth)}"
    }

    var sha256: String {
        let digest = SHA256.hash(data: Data(goCanonicalJSONString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct NativeMTPPublishedTupleOffer: Sendable, Equatable {
    let targetGeneration: UInt64
    let providerRevision: String
    let runtimeRevision: String
    let runtimeTuple: NativeMTPPublishedRuntimeTuple
    let nativeMTPAdmissionTupleSHA256: String
    let servedSnapshotID: String
    let sidecarDigest: String
    let challengeBankReleaseID: String
    let challengeBankSHA256: String
    let challengeCorpusSHA256: String
    let selftestProfile: String
    let selftestPassDigest: String
    let selftestObservedAt: Date
}

enum NativeMTPRuntimeTupleIdentity {
    static let schemaVersion = "macprovider.native-mtp-runtime-tuple.v1"
    static let domain = "macprovider.native-mtp-runtime-tuple.v1\n"

    static func sha256(
        nativeMTPAdmissionTupleSHA256: String,
        providerID: String,
        assignedID: String,
        targetGeneration: UInt64,
        servedSnapshotID: String
    ) throws -> String {
        guard let generation = Int(exactly: targetGeneration) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("native_mtp_runtime_tuple.target_generation")
        }
        let value = RFC8785JCS.Value.object([
            "assigned_id": .string(assignedID),
            "native_mtp_admission_tuple_sha256": .string(nativeMTPAdmissionTupleSHA256),
            "provider_id": .string(providerID),
            "schema_version": .string(schemaVersion),
            "served_snapshot_id": .string(servedSnapshotID),
            "target_generation": .int(generation),
        ])
        let canonical = try RFC8785JCS.canonicalString(value)
        let digest = SHA256.hash(data: Data((domain + canonical).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// A signed, locally verified artifact that the serve runtime may load during
/// a warm switch. The authority is scoped to an exact model ID by the map
/// built at serve startup; a supported-model string alone is never sufficient.
struct ModelRuntimeTargetAuthority: Sendable, Equatable {
    let modelArgument: String
    let artifactSHA256: String
    let catalogRevision: String
}

struct ModelRuntimePreparedAdoption: Sendable, Equatable {
    let request: ModelAdoptionAuthorityWire
    let authority: ModelRuntimeTargetAuthority
    let expiresAt: Date
}

struct ModelRuntimeAdoptionRecoveryClaim: Sendable, Equatable {
    let transactionID: String
    let fromModelID: String
    let targetModelID: String
    let expiresAt: Date
}

struct ModelRuntimeAdoptionServeKnobs: Sendable, Equatable {
    let kvBits: Int?
    let maxContext: Int
    let maxBatch: Int
    /// The FR-17 source `/v1/status` reports for `maxContext` after the swap.
    var contextSource: MaxContextSource = .recommendationAdoption
}

enum ModelRuntimeAdoptionError: Error, CustomStringConvertible, Equatable {
    case invalidTransactionID
    case invalidRecommendationSHA256
    case invalidServeKnobsSHA256
    case invalidCatalogIdentitySHA256
    case incumbentMismatch(expected: String, actual: String?)
    case unsupportedTarget
    case authorityUnavailable
    case authorityMismatch
    case adoptionReservationConflict
    case transactionConsumed
    case transactionNotPrepared
    case runtimeRejected(String)

    var description: String {
        switch self {
        case .invalidTransactionID:
            return "invalid_transaction_id"
        case .invalidRecommendationSHA256:
            return "invalid_recommendation_sha256"
        case .invalidServeKnobsSHA256:
            return "invalid_serve_knobs_sha256"
        case .invalidCatalogIdentitySHA256:
            return "invalid_catalog_identity_sha256"
        case let .incumbentMismatch(expected, actual):
            return "incumbent_mismatch: expected \(expected), actual \(actual ?? "<none>")"
        case .unsupportedTarget:
            return "unsupported_target"
        case .authorityUnavailable:
            return "runtime_target_authority_unavailable"
        case .authorityMismatch:
            return "runtime_target_authority_mismatch"
        case .adoptionReservationConflict:
            return "model_adoption_reservation_conflict"
        case .transactionConsumed:
            return "model_adoption_transaction_consumed"
        case .transactionNotPrepared:
            return "transaction_not_prepared"
        case let .runtimeRejected(reason):
            return reason
        }
    }
}

struct PagedKVRuntimeModelCapabilities: Equatable, Sendable {
    let modelFamily: String
    let requiresMoEDispatch: Bool
    let hybridDecoderArchitectureVerified: Bool
    /// The verified sparse-attention layout of an allowlisted `glm5_next`
    /// identity (SPEC-039 FR-PKV12), read from its `config.json`.
    let sparseAttention: PagedKVSparseAttentionLayout?

    init(
        modelFamily: String,
        requiresMoEDispatch: Bool,
        hybridDecoderArchitectureVerified: Bool = false,
        sparseAttention: PagedKVSparseAttentionLayout? = nil
    ) {
        self.modelFamily = modelFamily
        self.requiresMoEDispatch = requiresMoEDispatch
        self.hybridDecoderArchitectureVerified = hybridDecoderArchitectureVerified
        self.sparseAttention = sparseAttention
    }

    /// Prompt tokens of the attach-time parity probes: 513 (the production
    /// 512-token chunk boundary), or for a sparse-attention family
    /// `max(513, index_topk + 2 x block_size_tokens)` so the context exceeds
    /// `index_topk` and the indexer selects over paged pooled keys
    /// (SPEC-039 FR-PKV12).
    func attachProbePromptTokens(blockSizeTokens: Int) -> Int {
        let base = PagedKVRuntimeParityProbe.sharedForwardParityPromptTokens
        guard let sparseAttention else { return base }
        let (twoBlocks, blocksOverflow) = max(0, blockSizeTokens).multipliedReportingOverflow(by: 2)
        let (span, spanOverflow) = sparseAttention.indexTopk.addingReportingOverflow(twoBlocks)
        return blocksOverflow || spanOverflow ? Int.max : max(base, span)
    }
}

/// `glm5_next` per-layer layout from `text_config` (SPEC-039 FR-PKV12):
/// `linear_attention` layers ride `MambaCache`, `deepseek_sparse_attention`
/// layers `pagedMLA(kpool: indexKpool)`.
struct PagedKVSparseAttentionLayout: Equatable, Sendable {
    static let recurrentLayerType = "linear_attention"
    static let sparseLayerType = "deepseek_sparse_attention"

    let layerTypes: [String]
    let indexTopk: Int
    let indexKpool: Int

    var expectedCacheKinds: [PagedKVSharedForwardBackend.CacheKind] {
        layerTypes.map { $0 == Self.sparseLayerType ? .pagedMLA(kpool: indexKpool) : .recurrentMamba }
    }

    init?(textConfig: [String: Any]) {
        guard let layerTypes = textConfig["layer_types"] as? [String],
              !layerTypes.isEmpty,
              let hiddenLayers = textConfig["num_hidden_layers"] as? Int,
              layerTypes.count == hiddenLayers,
              layerTypes.allSatisfy({ $0 == Self.recurrentLayerType || $0 == Self.sparseLayerType }),
              layerTypes.contains(Self.sparseLayerType),
              let indexTopk = textConfig["index_topk"] as? Int,
              indexTopk > 0,
              let indexKpool = textConfig["index_kpool"] as? Int,
              indexKpool > 0
        else { return nil }
        self.layerTypes = layerTypes
        self.indexTopk = indexTopk
        self.indexKpool = indexKpool
    }
}

enum NativeMTPDrafterLoadError: Error, Equatable {
    case unsupportedAdapter(String)
}

struct PagedKVRuntimeMeasurementEnvironment: Sendable {
    var metallibCandidatePaths: @Sendable () -> [String]
    var fileExists: @Sendable (String) -> Bool
    var readFileData: @Sendable (String) throws -> Data
    var hardwareFingerprint: @Sendable () -> MachineFingerprint
    var registeredKernelIdentifier: @Sendable () -> String?

    static let live = PagedKVRuntimeMeasurementEnvironment(
        metallibCandidatePaths: {
            PagedKVMetallibGate.candidatePaths(
                bundleURL: Bundle.main.resourceURL,
                executableURL: Bundle.main.executableURL
            )
        },
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        readFileData: { try Data(contentsOf: URL(fileURLWithPath: $0)) },
        hardwareFingerprint: { MachineFingerprinter().sample() },
        registeredKernelIdentifier: { PagedKVGatherKernel.registeredRuntimeKernelIdentifier() }
    )
}

/// Injectable seam over the on-device runtime self-measurement probes. Production
/// uses `.live` (the real MLX-driven probes on the resident model); tests inject a
/// stub so unit coverage of the measurement→attach pipeline needs no MLX/metallib.
struct PagedKVRuntimeProber: Sendable {
    var parity: @Sendable (
        _ container: ModelContainer,
        _ modelID: String,
        _ blockSizeTokens: Int,
        _ maxPhysicalBlocks: Int,
        _ promptTokens: [Int],
        _ nNew: Int
    ) async -> PagedKVRuntimeParityProbeResult
    var moe: @Sendable (
        _ container: ModelContainer,
        _ blockSizeTokens: Int,
        _ maxPhysicalBlocks: Int,
        _ poolEpoch: Int,
        _ layerCount: Int,
        _ promptA: [Int],
        _ promptB: [Int],
        _ parityPromptA: [Int],
        _ parityPromptB: [Int],
        _ cacheKinds: [PagedKVSharedForwardBackend.CacheKind]
    ) async -> PagedKVRuntimeMoEProbeResult

    static let live = PagedKVRuntimeProber(
        parity: { container, modelID, blockSizeTokens, maxPhysicalBlocks, promptTokens, nNew in
            await PagedKVRuntimeParityProbe.runParityProbe(
                container: container,
                modelID: modelID,
                blockSizeTokens: blockSizeTokens,
                maxPhysicalBlocks: maxPhysicalBlocks,
                promptTokens: promptTokens,
                nNew: nNew
            )
        },
        moe: { container, blockSizeTokens, maxPhysicalBlocks, poolEpoch, layerCount, promptA, promptB, parityPromptA, parityPromptB, cacheKinds in
            await PagedKVRuntimeParityProbe.runMoEInputIsolationProbe(
                container: container,
                blockSizeTokens: blockSizeTokens,
                maxPhysicalBlocks: maxPhysicalBlocks,
                poolEpoch: poolEpoch,
                layerCount: layerCount,
                promptA: promptA,
                promptB: promptB,
                parityPromptA: parityPromptA,
                parityPromptB: parityPromptB,
                cacheKinds: cacheKinds
            )
        }
    )
}

struct PagedKVRuntimeMeasurement: Equatable {
    let observedRuntimeIdentity: PagedKVObservedRuntimeIdentity
    let hardwareSizingProof: PagedKVHardwareSizingProof
}

private struct PagedKVRuntimeCapacityProof {
    static func measuredMaxResidentTokens(config: PagedKVConfig, poolEpoch: Int) -> Int? {
        guard config.effectiveEnabled, poolEpoch > 0 else { return nil }
        guard config.blockSizeTokens > 0,
              config.blockSizeTokens <= PagedKVConfig.maximumBlockSizeTokens,
              config.maxPhysicalBlocks > 0,
              config.maxPhysicalBlocks <= PagedKVConfig.maximumPhysicalBlocks
        else {
            return nil
        }
        let (residentTokens, overflow) = config.blockSizeTokens.multipliedReportingOverflow(by: config.maxPhysicalBlocks)
        guard !overflow, residentTokens == config.maxResidentTokens else {
            return nil
        }
        guard (try? PagedKVBlockAllocator(
            blockSizeTokens: config.blockSizeTokens,
            maxPhysicalBlocks: config.maxPhysicalBlocks,
            poolEpoch: poolEpoch
        )) != nil else {
            return nil
        }
        return residentTokens
    }
}

final class ContinuousBatchRuntimeReplayAuthority: ContinuousBatchSchedulerReplayAuthority, @unchecked Sendable {
    private enum StoreError: Error {
        case corrupt
        case lockUnavailable
    }

    private struct ClaimRecord: Codable {
        static let currentVersion = 1

        let version: Int
        let requestIDHash: String
        let fingerprintSHA256: String

        enum CodingKeys: String, CodingKey {
            case version
            case requestIDHash = "request_id_sha256"
            case fingerprintSHA256 = "fingerprint_sha256"
        }

        init(requestIDHash: String, fingerprintSHA256: String) {
            self.version = Self.currentVersion
            self.requestIDHash = requestIDHash
            self.fingerprintSHA256 = fingerprintSHA256
        }
    }

    private let lock = NSLock()
    private let storeURL: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var fingerprintsByRequestIDHash: [String: Data]
    /// SPEC-049-R010: claims for requests that may not persist request-derived
    /// state (the privacy class). Process memory only; never read from or
    /// written to `storeURL`. Bounded: past `processOnlyClaimLimit` the oldest
    /// claim is dropped. That is safe because every privacy request is first
    /// refused on replay by its SPEC-041-R005 execution claim, taken before
    /// decryption, and an active row is still deduplicated by the scheduler;
    /// this map is the in-process CB layer on top of both.
    private var processOnlyFingerprintsByRequestIDHash: [String: (fingerprint: Data, sequence: UInt64)] = [:]
    private var processOnlyClaimOrder: [(requestIDHash: String, sequence: UInt64)] = []
    private var processOnlyClaimOrderHead = 0
    private var processOnlyClaimSequence: UInt64 = 0
    private let processOnlyClaimLimit: Int
    static let defaultProcessOnlyClaimLimit = 65_536
    private var durableAvailableValue: Bool

    init(
        storeURL: URL? = ContinuousBatchRuntimeReplayAuthority.defaultStoreURL(),
        fileManager: FileManager = .default,
        processOnlyClaimLimit: Int = ContinuousBatchRuntimeReplayAuthority.defaultProcessOnlyClaimLimit
    ) {
        self.storeURL = storeURL
        self.processOnlyClaimLimit = max(1, processOnlyClaimLimit)
        if let storeURL {
            do {
                var isDirectory = ObjCBool(false)
                var createdDirectories: [URL] = []
                if fileManager.fileExists(atPath: storeURL.path, isDirectory: &isDirectory) {
                    guard isDirectory.boolValue else { throw StoreError.corrupt }
                } else {
                    createdDirectories = Self.missingDirectoryChain(for: storeURL, fileManager: fileManager)
                    try fileManager.createDirectory(
                        at: storeURL,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                }
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeURL.path)
                try Self.syncDirectoryCreationPath(createdDirectories: createdDirectories, storeURL: storeURL)
                self.fingerprintsByRequestIDHash = [:]
                self.durableAvailableValue = true
            } catch {
                self.fingerprintsByRequestIDHash = [:]
                self.durableAvailableValue = false
            }
        } else {
            self.fingerprintsByRequestIDHash = [:]
            self.durableAvailableValue = false
        }
        self.encoder.outputFormatting = [.sortedKeys]
    }

    static func inMemoryForTests(durableAvailable: Bool = false) -> ContinuousBatchRuntimeReplayAuthority {
        let authority = ContinuousBatchRuntimeReplayAuthority(storeURL: nil)
        authority.durableAvailableValue = durableAvailable
        return authority
    }

    var durableAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return durableAvailableValue
    }

    /// SPEC-049-R010: the single decision for whether a claim reaches the
    /// durable store. The privacy posture probe asserts it for `.privacy`.
    static func persistsClaim(for provenance: KVIngestProvenance) -> Bool {
        provenance.mayPersistRequestDerivedState
    }

    func claim(_ key: ContinuousBatchSchedulerReplayKey) throws -> ContinuousBatchSchedulerReplayClaim {
        let requestIDHash = Self.requestIDHash(key.requestID)
        lock.lock()
        defer { lock.unlock() }
        // In-process replay protection for a request that may not touch the
        // disk: no store lock, read or write. A same-ID claim already taken
        // in this process by either class is still a duplicate.
        guard Self.persistsClaim(for: key.ingestProvenance) else {
            if let existing = processOnlyFingerprintsByRequestIDHash[requestIDHash]?.fingerprint
                ?? fingerprintsByRequestIDHash[requestIDHash] {
                return existing == key.fingerprintSHA256 ? .duplicateSameRequest : .duplicateMismatchedRequest
            }
            insertProcessOnlyClaim(requestIDHash: requestIDHash, fingerprint: key.fingerprintSHA256)
            return .claimed
        }
        if let existing = processOnlyFingerprintsByRequestIDHash[requestIDHash]?.fingerprint {
            return existing == key.fingerprintSHA256 ? .duplicateSameRequest : .duplicateMismatchedRequest
        }
        if let storeURL {
            return try Self.withStoreLock(for: storeURL) {
                let claimURL = try Self.claimURL(for: requestIDHash, in: storeURL)
                if let existing = try readClaim(at: claimURL, requestIDHash: requestIDHash) {
                    fingerprintsByRequestIDHash[requestIDHash] = existing
                    return existing == key.fingerprintSHA256 ? .duplicateSameRequest : .duplicateMismatchedRequest
                }
                if try writeClaim(
                    requestIDHash: requestIDHash,
                    fingerprintSHA256: key.fingerprintSHA256,
                    to: claimURL
                ) {
                    fingerprintsByRequestIDHash[requestIDHash] = key.fingerprintSHA256
                    return .claimed
                }
                guard let existing = try readClaim(at: claimURL, requestIDHash: requestIDHash) else {
                    throw StoreError.corrupt
                }
                fingerprintsByRequestIDHash[requestIDHash] = existing
                return existing == key.fingerprintSHA256 ? .duplicateSameRequest : .duplicateMismatchedRequest
            }
        }
        if let existing = fingerprintsByRequestIDHash[requestIDHash] {
            return existing == key.fingerprintSHA256 ? .duplicateSameRequest : .duplicateMismatchedRequest
        }
        fingerprintsByRequestIDHash[requestIDHash] = key.fingerprintSHA256
        return .claimed
    }

    /// SPEC-038 AC-25: drop a claim whose request never reached admission.
    /// Fingerprint-guarded so a concurrent re-claim of the same ID with a
    /// different body is left alone, and best-effort on the durable tier — a
    /// store error leaves the claim in place, which fails toward the
    /// pre-existing 409 rather than toward permitting a second execution.
    func release(_ key: ContinuousBatchSchedulerReplayKey) {
        let requestIDHash = Self.requestIDHash(key.requestID)
        lock.lock()
        defer { lock.unlock() }
        guard Self.persistsClaim(for: key.ingestProvenance) else {
            guard processOnlyFingerprintsByRequestIDHash[requestIDHash]?.fingerprint == key.fingerprintSHA256 else { return }
            processOnlyFingerprintsByRequestIDHash.removeValue(forKey: requestIDHash)
            return
        }
        if let storeURL {
            try? Self.withStoreLock(for: storeURL) {
                let claimURL = try Self.claimURL(for: requestIDHash, in: storeURL)
                guard let existing = try? readClaim(at: claimURL, requestIDHash: requestIDHash),
                      existing == key.fingerprintSHA256 else { return }
                try FileManager.default.removeItem(at: claimURL)
                try Self.syncDirectory(claimURL.deletingLastPathComponent())
                fingerprintsByRequestIDHash.removeValue(forKey: requestIDHash)
            }
            return
        }
        guard fingerprintsByRequestIDHash[requestIDHash] == key.fingerprintSHA256 else { return }
        fingerprintsByRequestIDHash.removeValue(forKey: requestIDHash)
    }

    /// Caller holds `lock`. Order entries whose claim was released or
    /// re-claimed are skipped by sequence, so only the oldest live claim is
    /// dropped and the order queue stays bounded.
    private func insertProcessOnlyClaim(requestIDHash: String, fingerprint: Data) {
        processOnlyClaimSequence &+= 1
        let sequence = processOnlyClaimSequence
        processOnlyFingerprintsByRequestIDHash[requestIDHash] = (fingerprint, sequence)
        processOnlyClaimOrder.append((requestIDHash, sequence))
        while processOnlyFingerprintsByRequestIDHash.count > processOnlyClaimLimit
            || processOnlyClaimOrder.count - processOnlyClaimOrderHead > 2 * processOnlyClaimLimit {
            let oldest = processOnlyClaimOrder[processOnlyClaimOrderHead]
            processOnlyClaimOrderHead += 1
            if processOnlyFingerprintsByRequestIDHash[oldest.requestIDHash]?.sequence == oldest.sequence {
                processOnlyFingerprintsByRequestIDHash.removeValue(forKey: oldest.requestIDHash)
            }
        }
        if processOnlyClaimOrderHead > processOnlyClaimLimit {
            processOnlyClaimOrder.removeFirst(processOnlyClaimOrderHead)
            processOnlyClaimOrderHead = 0
        }
    }

    private static func defaultStoreURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library/Application Support/macprovider/continuous-batching", isDirectory: true)
            .appendingPathComponent("replay-claims-v1", isDirectory: true)
    }

    private static func requestIDHash(_ requestID: String) -> String {
        hexString(SHA256.hash(data: Data(requestID.utf8)))
    }

    private static func claimURL(for requestIDHash: String, in storeURL: URL) throws -> URL {
        let shard = String(requestIDHash.prefix(2))
        let shardURL = storeURL.appendingPathComponent(shard, isDirectory: true)
        try FileManager.default.createDirectory(
            at: shardURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shardURL.path)
        try syncDirectory(storeURL)
        return shardURL.appendingPathComponent("\(requestIDHash).json", isDirectory: false)
    }

    private func readClaim(at url: URL, requestIDHash: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try decoder.decode(ClaimRecord.self, from: Data(contentsOf: url))
        guard record.version == ClaimRecord.currentVersion,
              record.requestIDHash == requestIDHash,
              let fingerprint = Self.data(fromHexString: record.fingerprintSHA256)
        else {
            throw StoreError.corrupt
        }
        return fingerprint
    }

    private func writeClaim(requestIDHash: String, fingerprintSHA256: Data, to url: URL) throws -> Bool {
        let data = try encoder.encode(ClaimRecord(
            requestIDHash: requestIDHash,
            fingerprintSHA256: Self.hexString(fingerprintSHA256)
        ))
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else {
            if errno == EEXIST { return false }
            throw StoreError.corrupt
        }
        defer { close(fd) }
        let wroteAll = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return data.isEmpty
            }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard wroteAll, fsync(fd) == 0 else {
            throw StoreError.corrupt
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Self.syncDirectory(url.deletingLastPathComponent())
        return true
    }

    private static func syncDirectory(_ url: URL) throws {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard fd >= 0 else { throw StoreError.corrupt }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw StoreError.corrupt }
    }

    private static func missingDirectoryChain(for url: URL, fileManager: FileManager) -> [URL] {
        var missing: [URL] = []
        var current = url
        while true {
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory) {
                break
            }
            missing.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        return missing
    }

    private static func syncDirectoryCreationPath(createdDirectories: [URL], storeURL: URL) throws {
        var synced: Set<String> = []
        func syncOnce(_ url: URL) throws {
            let path = url.standardizedFileURL.path
            guard !synced.contains(path) else { return }
            try syncDirectory(url)
            synced.insert(path)
        }

        for directory in createdDirectories {
            try syncOnce(directory)
            let parent = directory.deletingLastPathComponent()
            if parent.path != directory.path {
                try syncOnce(parent)
            }
        }

        let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let storePath = storeURL.standardizedFileURL.path
        let homePath = homeURL.path
        if storePath == homePath || storePath.hasPrefix(homePath + "/") {
            var current = storeURL
            while true {
                try syncOnce(current)
                let standardized = current.standardizedFileURL
                if standardized.path == homePath { break }
                let parent = standardized.deletingLastPathComponent()
                guard parent.path != standardized.path else { break }
                current = parent
            }
        } else {
            try syncOnce(storeURL)
            let parent = storeURL.deletingLastPathComponent()
            if parent.path != storeURL.path {
                try syncOnce(parent)
            }
        }
    }

    private static func withStoreLock<T>(for storeURL: URL, _ operation: () throws -> T) throws -> T {
        let lockURL = storeURL.appendingPathComponent(".lock", isDirectory: false)
        let fd = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else { throw StoreError.lockUnavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw StoreError.lockUnavailable }
        defer { _ = flock(fd, LOCK_UN) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
        return try operation()
    }

    private static func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func data(fromHexString hex: String) -> Data? {
        guard hex.utf8.count % 2 == 0 else { return nil }
        var data = Data()
        data.reserveCapacity(hex.utf8.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }
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

#if DEBUG || MACPROVIDER_LAB_HARNESS
private enum LabWarmSwapHookError: Error, CustomStringConvertible {
    case invalidTargetIdentity
    case artifactMismatch
    case containerUnavailable
    case runtimeNotReady(String)
    case noInFlightRequest
    case publicationMismatch

    var description: String {
        switch self {
        case .invalidTargetIdentity:
            return "lab warm-swap target identity is invalid"
        case .artifactMismatch:
            return "lab warm-swap artifact digest does not match the loaded runtime artifact"
        case .containerUnavailable:
            return "lab warm-swap requires a loaded container"
        case .runtimeNotReady(let state):
            return "lab warm-swap requires a ready runtime, got \(state)"
        case .noInFlightRequest:
            return "lab warm-swap requires an in-flight request"
        case .publicationMismatch:
            return "lab warm-swap publication did not expose the requested identity"
        }
    }
}
#endif

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
    /// Seconds from the first generated token to the last (mlx-swift-lm
    /// `GenerateResult.generateTime`; prefill excluded).
    var generateTime: TimeInterval = 0

    var generationTokenCount: Int {
        tokenIds.count
    }

    init(_ result: GenerateResult) {
        self.tokenIds = result.tokenIds
        self.output = result.output
        self.generateTime = result.generateTime
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
    static func verifyLoadedArtifact(directory: URL, expectedSHA256: String) throws {
        let loadedArtifactHash = try? ModelArtifactVerifier.canonicalArtifactHash(directory: directory)
        guard loadedArtifactHash == expectedSHA256 else {
            let observedArtifactHash = loadedArtifactHash ?? "unavailable"
            throw ModelRuntimeLoadError(
                target: directory.path,
                reason: "verified model artifact changed during load: expected \(expectedSHA256), observed \(observedArtifactHash)"
            )
        }
    }

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
              !request.containsNonTextMessageContentPart,
              request.allowsSpeculativeDecoding,
              draftLoaded,
              numDraftTokens != nil else {
            return .tokenIterator
        }
        return .speculative
    }

    static func decodePath(
        for request: ChatCompletionRequest,
        draftConfigured: Bool,
        draftLoaded: Bool,
        numDraftTokens: Int?,
        nativeMTPMode: NativeMTPMode = .off,
        nativeMTPCapability: NativeMTPCapability?
    ) -> DecodePathSelection {
        NativeMTPSelector.select(
            request: request,
            draftConfigured: draftConfigured,
            draftLoaded: draftLoaded,
            numDraftTokens: numDraftTokens,
            nativeMTPMode: nativeMTPMode,
            nativeCapability: nativeMTPCapability
        )
    }

    static func nativeMTPRuntimeAdmission(
        for request: ChatCompletionRequest,
        draftConfigured: Bool,
        draftLoaded: Bool,
        numDraftTokens: Int?,
        nativeMTPMode: NativeMTPMode = .off,
        nativeMTPCapability: NativeMTPCapability?,
        schedulerSupportsNativeMTP: Bool = false
    ) -> NativeMTPRuntimeAdmission {
        let selection = decodePath(
            for: request,
            draftConfigured: draftConfigured,
            draftLoaded: draftLoaded,
            numDraftTokens: numDraftTokens,
            nativeMTPMode: nativeMTPMode,
            nativeMTPCapability: nativeMTPCapability
        )
        return NativeMTPRuntimeAdmission.resolve(
            selection: selection,
            capability: nativeMTPCapability,
            schedulerSupportsNativeMTP: schedulerSupportsNativeMTP
        )
    }

    /// SPEC-001-R011: the other active rows a request's native-MTP admission
    /// resolves against (the caller's own handle is registered). A local row
    /// never takes the native row; a buyer's count leaves local rows out,
    /// because they are preempted for it.
    static func nativeMTPOtherActiveRows(isLocal: Bool, registeredRows: Int, localRows: Int) -> Int {
        isLocal ? Int.max : max(0, registeredRows - 1 - localRows)
    }

    static func nativeMTPBuyerPreemptsLocal(_ admission: NativeMTPRuntimeAdmission, isLocal: Bool, localRows: Int) -> Bool {
        !isLocal && admission.usesNativeMTP && localRows > 0
    }

    private func nativeMTPRuntimeAdmission(
        for request: ChatCompletionRequest,
        snapshot: RuntimeSnapshot,
        handle: RequestHandle
    ) -> NativeMTPRuntimeAdmission {
        // SPEC-001-R011: local rows never take a native-MTP row, and a
        // buyer's row count ignores them (the scheduler's load gate covers
        // the overlap until the preempted local rows leave).
        let isLocal = localRegistrationIDs.contains(handle.registrationID)
        let localRows = localRegistrationIDs.count
        let otherActiveRows = Self.nativeMTPOtherActiveRows(
            isLocal: isLocal, registeredRows: inFlightCancellations.count, localRows: localRows
        )
        let admission = Self.nativeMTPRuntimeAdmission(
            for: request,
            draftConfigured: snapshot.hasTargetCompatibleDraft || currentDraftModelID != nil,
            draftLoaded: snapshot.hasTargetCompatibleDraft,
            numDraftTokens: snapshot.numDraftTokens,
            nativeMTPMode: nativeMTPMode,
            nativeMTPCapability: snapshot.nativeMTPCapability,
            schedulerSupportsNativeMTP: snapshot.schedulerSupportsNativeMTP
        ).binding(to: snapshot.nativeMTPTupleOffer.map {
            NativeMTPTupleFence(
                admissionTupleSHA256: $0.nativeMTPAdmissionTupleSHA256,
                servedSnapshotID: $0.servedSnapshotID,
                targetGeneration: $0.targetGeneration
            )
        })
        // The caller's own handle is registered, so every other in-flight
        // request is a row this one would share the target forward with.
        // Check and registration are both actor-isolated, so a burst of
        // concurrent arrivals cannot all observe an empty runtime.
        .resolvingActiveRows(otherActiveRows: otherActiveRows)
        if isLocal {
            // Local selection is not buyer-facing native-MTP status.
            testNativeMTPAdmissionRequestObserver?(request.requestID, admission, otherActiveRows)
            return admission
        }
        if Self.nativeMTPBuyerPreemptsLocal(admission, isLocal: isLocal, localRows: localRows) {
            // A buyer that can run native MTP must not wait at depth zero
            // behind local rows: preempt them.
            let providerStatus = providerStatus
            Task { await providerStatus?.preemptAdmittedLocalWork() }
        }
        recordNativeMTPAdmissionStatus(admission)
        testNativeMTPAdmissionObserver?(admission)
        testNativeMTPAdmissionRequestObserver?(request.requestID, admission, otherActiveRows)
        return admission
    }

    /// SPEC-048-R004/R010: a native admission that the tokenized prompt or
    /// output budget pushes past the signed bounds selects ordinary
    /// (`capability_mismatch`) before any native state exists. Record that
    /// selection like any other, so status reasons and admission observers see
    /// the path the row actually runs instead of the pre-tokenization one.
    private func recordNativeMTPTokenBoundDowngrade(
        requestID: String?,
        admitted: NativeMTPRuntimeAdmission,
        resolved: NativeMTPRuntimeAdmission
    ) {
        guard Self.isNativeMTPTokenBoundDowngrade(admitted: admitted, resolved: resolved) else { return }
        recordNativeMTPAdmissionStatus(resolved)
        testNativeMTPAdmissionObserver?(resolved)
        // -1: the active-row count belongs to the original admission, not to
        // this token-bound reselection.
        testNativeMTPAdmissionRequestObserver?(requestID, resolved, -1)
    }

    nonisolated static func isNativeMTPTokenBoundDowngrade(
        admitted: NativeMTPRuntimeAdmission,
        resolved: NativeMTPRuntimeAdmission
    ) -> Bool {
        admitted.effectivePath == .nativeMTP && resolved.effectivePath != .nativeMTP
    }

    private func recordNativeMTPAdmissionStatus(_ admission: NativeMTPRuntimeAdmission) {
        guard nativeMTPMode == .auto else { return }
        if admission.selection.path == .nativeMTP, admission.effectivePath != .nativeMTP {
            currentNativeMTPStatusSink.recordPreoutputFallback(.unsupportedCacheState)
            return
        }
        guard admission.effectivePath != .nativeMTP,
              let reason = admission.selection.nativeMTPReason,
              !reason.isEligible else {
            return
        }
        let statusReason = Self.nativeMTPStatusReason(for: reason)
        if statusReason == .tupleNotAdmitted,
           currentNativeMTPCapability == nil,
           currentNativeMTPStatusSink.snapshot().lastReason == .revocationStateUnavailable {
            return
        }
        currentNativeMTPStatusSink.recordReason(statusReason)
    }

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    func recordNativeMTPAdmissionStatusForTest(_ admission: NativeMTPRuntimeAdmission) {
        recordNativeMTPAdmissionStatus(admission)
    }

    func setNativeMTPDisabledStatusReasonForTest(_ reason: NativeMTPStatusReason) {
        currentNativeMTPStatusSink.adopt(NativeMTPStatusSink.disabled(resetGeneration: 1, reason: reason))
    }

    /// Publishes a tuple offer as a passed self-check would, without a model.
    /// The tuple is bound to a revocation feed signer, as a sidecar binds it;
    /// tests drive that feed through the injectable poller and reader.
    func installNativeMTPTupleOfferForTest(_ offer: NativeMTPPublishedTupleOffer) {
        currentNativeMTPTupleOffer = offer
        parkedNativeMTPTuple = nil
        currentNativeMTPRevocationRefresh = NativeMTPRevocationRefreshInputs(
            signerKeyID: "test-revocation-signer",
            trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring(publicKeysByKeyID: [:], requiredKeyID: "test-revocation-signer"),
            tupleSHA256: offer.nativeMTPAdmissionTupleSHA256,
            servedSnapshotID: offer.servedSnapshotID,
            targetGeneration: offer.targetGeneration
        )
    }

    func nativeMTPTupleIsParkedForTest() -> Bool {
        parkedNativeMTPTuple != nil
    }

    func nativeMTPRevocationWatcherActiveForTest() -> Bool {
        nativeMTPRevocationRefreshTask != nil
    }

    func setNativeMTPRevocationPollerForTest(_ poller: @escaping NativeMTPRevocationPoller) {
        nativeMTPRevocationPoller = poller
    }

    func setNativeMTPRevokedSetReaderForTest(_ reader: @escaping NativeMTPRevokedSetReader) {
        nativeMTPRevokedSetReader = reader
    }

    /// Runs after the scheduler fence inside `disableNativeMTPTuple`, so a test
    /// can interleave a load or swap at that suspension point.
    func setNativeMTPTupleFenceHookForTest(_ hook: (@Sendable () async -> Void)?) {
        nativeMTPTupleFenceHookForTest = hook
    }

    /// Runs after the scheduler re-enable inside `restoreParkedNativeMTPTuple`,
    /// so a test can revoke or interleave at that suspension point.
    /// A load or warm swap as the runtime sees it: the published tuple is
    /// cleared and the spec-decode generation advances.
    func simulateNativeMTPTupleSwapForTest() {
        parkedNativeMTPTuple = nil
        currentNativeMTPTupleOffer = nil
        currentSpecDecodeGeneration += 1
    }

    func setNativeMTPTupleEnableHookForTest(_ hook: (@Sendable () async -> Void)?) {
        nativeMTPTupleEnableHookForTest = hook
    }
    #endif

    private static func nativeMTPStatusReason(for selectorReason: NativeMTPSelectorReason) -> NativeMTPStatusReason {
        switch selectorReason {
        case .modeOff, .classicDraftConfigured:
            return .disabledByDefault
        case .tupleNotAdmitted, .capabilityMismatch:
            return .tupleNotAdmitted
        case .tupleRevoked:
            return .tupleRevoked
        case .revocationStateUnavailable:
            return .revocationStateUnavailable
        case .unsupportedStateCache:
            return .unsupportedCacheState
        case .insufficientVerificationCapacity:
            return .capacityUnavailable
        case .capacityAboveNativeBound:
            return .capacityAboveNativeBound
        default:
            return .requestIneligible
        }
    }

    /// mlx-swift-lm #424: classic speculative rollback silently fails after a
    /// RotatingKVCache wraps. Stay strictly below the wrap boundary, including
    /// transient draft tokens that may need to be rejected and trimmed.
    static func speculativeCacheWindowSafe(
        promptTokens: Int,
        maxTokens: Int?,
        maxContextTokens: Int,
        numDraftTokens: Int
    ) -> Bool {
        guard promptTokens >= 0,
              let maxTokens,
              maxTokens >= 0,
              numDraftTokens >= 0,
              promptTokens < maxContextTokens else {
            return false
        }
        let remaining = maxContextTokens - promptTokens
        guard numDraftTokens < remaining else { return false }
        return maxTokens < remaining - numDraftTokens
    }

    // mlx-swift-lm #424: RotatingKVCache wrap makes speculative rollback a
    // silent no-op. Keep production serve on ordinary decode until a tagged
    // upstream fix and cache-wrap parity proof land. Tool-loop / auto-prefix
    // traffic also cannot spec-decode (SPEC-028 FR-5, ConversationCache).
    static var productionSpeculativeCacheWrapValidated: Bool {
        false
    }

    /// mlx-swift-lm #312: TokenIterator can replace its local cache array when
    /// dynamic KV quantization begins, leaving a caller-owned reusable cache
    /// without generated-token state. Quantization remains available for
    /// one-shot requests, but reusable conversation keys fail closed to fp16.
    static func effectiveKVBits(configured: Int?, conversationKey: String?, containsImage: Bool = false) -> Int? {
        !containsImage && conversationKey == nil ? configured : nil
    }

    static func effectivePrefillStepSize(configured: Int, containsImage: Bool) -> Int {
        containsImage ? NativeVisionProfile.prefillStepSize : configured
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
    private let configuredModelLoadPath: String?
    // Coordinator-advertised catalog id (e.g. mlx-community/…) accepted as an
    // alias for the configured served model. nil when unset. See BUILD_SPEC
    // relay_serve_model_id_alias.
    private let catalogModelIDAlias: String?
    private var currentContainer: ModelContainer?
    /// Keeps the loaded model's weights in MLX's residency sets; see
    /// `startResidentWeightsTicket(modelFamily:)`.
    private var residentWeightsTicket: WiredMemoryTicket?
    private var currentDraftModelID: String?
    private var currentDraftTargetModelID: String?
    private var currentDraftContainer: ModelContainer?
    private var currentNativeMTPDrafterContainer: MTPDrafterContainer?
    private var currentNativeMTPCapability: NativeMTPCapability?
    private var currentNativeMTPAdmissionCapability: NativeMTPAdmissionCapability?
    private var currentNativeMTPStatusSink = NativeMTPStatusSink.disabled()
    private var currentNativeMTPTupleOffer: NativeMTPPublishedTupleOffer? {
        didSet { nativeMTPPublishedTupleOffer.set(currentNativeMTPTupleOffer, generation: currentSpecDecodeGeneration) }
    }
    /// The published tuple and spec-decode generation, readable without an
    /// actor hop: the coordinator client checks it immediately before it
    /// sends an offer, with no suspension in between.
    nonisolated let nativeMTPPublishedTupleOffer = NativeMTPPublishedTupleOfferBox()
    private var currentNativeMTPSelfTestInput: NativeMTPSelfTestInput?
    private var currentNativeVisionProfile: NativeVisionProfile?
    private var nativeMTPRevocationRefreshTask: Task<Void, Never>?
    private var currentNativeMTPRevocationRefresh: NativeMTPRevocationRefreshInputs?
    /// A tuple the coordinator rejected with `bank_mismatch`, fenced but kept
    /// so it can be offered again without a model reload (SPEC-048-R016
    /// v0.1.48). Cleared by every load, swap, and teardown.
    private var parkedNativeMTPTuple: ParkedNativeMTPTuple?
    /// Told when a parked tuple is discarded because it was revoked or
    /// disabled while parked, so the coordinator client drops its re-offer.
    private var nativeMTPParkedTupleDiscardHandler: (@Sendable (NativeMTPPublishedTupleOffer) async -> Void)?
    private var nativeMTPRevocationPoller: NativeMTPRevocationPoller = ModelRuntime.liveNativeMTPRevocationPoller
    private var nativeMTPRevokedSetReader: NativeMTPRevokedSetReader = ModelRuntime.liveNativeMTPRevokedSetReader
    /// A restore is between its first check and publication; a second
    /// restore of the same tuple is refused meanwhile.
    private var nativeMTPRestoreInFlight = false
    #if DEBUG || MACPROVIDER_LAB_HARNESS
    private var nativeMTPTupleFenceHookForTest: (@Sendable () async -> Void)?
    private var nativeMTPTupleEnableHookForTest: (@Sendable () async -> Void)?
    #endif
    private var nativeMTPStatusResetGeneration: UInt64 = 0
    private let configuredDraftModelID: String?
    private let configuredDraftModelLoadPath: String?
    private let configuredNativeMTPAdmissionSidecarPath: String?
    /// The durable model store root a fetched admission set's projection
    /// resolves against; nil keeps the bundle layout.
    private let configuredNativeMTPAdmissionArtifactRoot: String?
    private let configuredNativeMTPAdmissionSignaturePath: String?
    private let configuredNativeMTPTrustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring?
    private let configuredNativeMTPRunningBuildIdentity: NativeMTPRunningBuildIdentity?
    private let configuredNativeMTPRevokedTupleSHA256: Set<String>?
    private let configuredNativeMTPResolvedArtifactAuthority: NativeMTPResolvedArtifactAuthority?
    private let nativeMTPSelfTestRunner: NativeMTPSelfTestRunner
    private var currentSpecDecodeGeneration = 0 {
        didSet { nativeMTPPublishedTupleOffer.set(currentNativeMTPTupleOffer, generation: currentSpecDecodeGeneration) }
    }
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
    private var configuredTemplateSupportsThinkingToggle = false
    private var currentTemplateSupportsThinkingToggle = false
    private var configuredTemplateSupportsPreserveThinking = false
    private var currentTemplateSupportsPreserveThinking = false
    private let verifiedCatalogArtifactSHA256: String?
    /// SPEC-037 FR-KVP4 (MEDIUM-5) — the model's CATALOG REVISION, distinct from the
    /// artifact SHA. FR-KVP4 requires model_sha256 AND catalog revision as SEPARATE
    /// identity fields; a catalog-revision change with unchanged artifact bytes must
    /// disk_miss_envelope, not hit. Nil ⇒ the cold tier treats identity as unavailable
    /// and neither promotes nor persists (never falls back to the artifact SHA).
    private let verifiedModelCatalogRevision: String?
    private let targetAuthorities: [String: ModelRuntimeTargetAuthority]
    private let targetTemplateSupportsThinkingToggleByArtifactSHA256: [String: Bool]
    private let targetTemplateSupportsPreserveThinkingByArtifactSHA256: [String: Bool]
    private let authorizedSwitchModelIDs: [String]
    /// #1689 FR-20b: context to serve per warm-switch target (lowercased id)
    /// when the configured context was generated by a recommendation. Empty
    /// for an operator-owned context, which then applies to every model.
    private let switchMaxContextByTarget: [String: Int]
    /// SPEC-023-R018 item 9: the slot count each generated switch target
    /// serves; below the served count only when its floor context does not fit.
    private let switchMaxBatchByTarget: [String: Int]
    /// Lowercased ids of the model the configured value's provenance record
    /// names; only a switch back to one of them serves `recommendation_apply`.
    private let switchContextProvenanceModelIDs: Set<String>
    /// The configured `max_context_override` serve started with; a switch that
    /// serves exactly it serves the config value, not a recomputed one.
    private let configuredMaxContextTokens: Int?
    private var preparedAdoptions: [String: ModelRuntimePreparedAdoption] = [:]
    private var preparedAdoptionReservationID: String?
    private var applyingAdoptionTransactionID: String?
    private var adoptionRecoveryClaims: [String: ModelRuntimeAdoptionRecoveryClaim] = [:]
    private var consumedAdoptionTransactionIDs: [String: Date] = [:]
    private var finalizedAdoptionTransactionIDs: [String: Date] = [:]
    private static let adoptionTransactionLifetime: TimeInterval = 5 * 60
    // The CLI permits a drain timeout of up to ten minutes. Once apply starts,
    // retain the switch-lane reservation through that full window plus the
    // normal five-minute commit/recovery margin.
    private static let activeAdoptionTransactionLifetime: TimeInterval = 15 * 60
    private static let maximumConsumedAdoptionTransactionIDs = 64
    private var maxContextTokens: Int
    /// Upstream #424 makes classic speculative rollback unsafe across unknown
    /// model-specific cache windows. Production stays disabled until a tagged
    /// fix and a real cache-wrap parity proof explicitly set this gate.
    private let speculativeCacheWrapValidated: Bool
    // SPEC-013 autoresearch serving knobs. nil kvBits ⇒ no KV
    // quantization (mlx-swift default). maxBatch defaults to 1, the
    // pre-knob behavior; lifting above 1 widens the autotune search.
    private var kvBitsOverride: Int?
    private let prefillStepSize: Int
    private let pagedKVConfig: PagedKVConfig
    private var pagedKVAttachDecision: PagedKVAttachDecision
    private var pagedKVRuntimeCacheClass: String
    private var pagedKVObservedRuntimeIdentity: PagedKVObservedRuntimeIdentity?
    private var pagedKVHardwareSizingProof: PagedKVHardwareSizingProof?
    private var pagedKVSchedulerBackendInstalled: Bool
    private var currentPagedKVModelCapabilities: PagedKVRuntimeModelCapabilities
    private var continuousBatchScheduler: ContinuousBatchScheduler?
    private let testContinuousBatchingBackend: (any ContinuousBatchSchedulerBackend)?
    private let nativeMTPMode: NativeMTPMode
    private let nativeMTPCapability: NativeMTPCapability?
    private let nativeMTPSchedulerSupported: Bool
    private let testNativeMTPAdmissionObserver: (@Sendable (NativeMTPRuntimeAdmission) -> Void)?
    private let testNativeMTPAdmissionRequestObserver: (@Sendable (String?, NativeMTPRuntimeAdmission, Int) -> Void)?
    /// Injectable seam over the on-device SPEC-039 parity/MoE self-measurement probes.
    /// Production uses `.live`; tests inject a stub so unit coverage of the
    /// measurement→attach pipeline needs no MLX/metallib. Mirrors
    /// `testContinuousBatchingBackend`'s production-default / test-injected wiring.
    private let pagedKVRuntimeProber: PagedKVRuntimeProber
    private let continuousBatchReplayAuthority: ContinuousBatchRuntimeReplayAuthority
    private var continuousBatchingDurableReplayAuthorityAvailable: Bool
    private let conversationCache: ConversationCache
    /// SPEC-037 stage 5 — set once the serve process activates the encrypted disk
    /// cold tier (FR-KVP7). Gates all per-request cold-tier context construction;
    /// false ⇒ the hot path is byte-identical to today (FR-KVP1).
    private var coldTierAttached = false
    private var attachedKVDiskTier: KVDiskTier?
    private var attachedKVDiskAdapter: KVConversationColdTierAdapter?
    private var coldTierUnsupportedReason: String?
    private var inferenceGate: AsyncSemaphore
    /// SPEC-036 FR-21: scoring jobs run under the same serial permit as
    /// serial buyer requests.
    var serialInferenceGate: AsyncSemaphore { inferenceGate }
    /// SPEC-038-R011: the served slot count. The serial `inferenceGate` and
    /// the scheduler's buyer-row limit are sized to it (the scheduler keeps
    /// its own bounded queue, token budget, wait timeout and cancellation),
    /// so batched buyer rows never exceed the verified count on any surface.
    /// Scheduler rows (`maxBatch`) may be larger for the self-check.
    private var servedSlotLimit: Int
    /// Bumped on every swap: a self-check target from before it never matches.
    private var selfCheckGeneration = 0
    /// Set by `serve` when the self-check owns the served count; a swap then
    /// serves the owner pin or one slot until the new model's check decides.
    private var servedSlotsManaged = false
    private var ownerPinnedServedSlots: Int?
    /// Resolves a swapped-in model's stored or prior grant before readiness.
    private var servedSlotsResolver: (@Sendable (ContinuousBatchingSelfCheckTarget) -> ContinuousBatchingSelfCheckResolution?)?
    private let blockingInferenceExecutor: BlockingInferenceExecutor
    private var maxBatch: Int
    /// The scheduler rows before a signed policy ceiling (SPEC-038 FR-CB11
    /// v0.3.22): a warm swap re-applies the new model's own ceiling to it.
    private var maxBatchBeforePolicyCeiling: Int
    private let continuousBatchingMode: ContinuousBatchingMode
    private let continuousBatchQueueLimit: Int?
    /// SPEC-038 AC-25 bounded admission wait, in milliseconds. Nil ⇒ the
    /// scheduler configuration default.
    private let continuousBatchQueueWaitTimeoutMS: Int?
    /// SPEC-038 operator-tunable prefill per-iteration token budget. Nil ⇒ the
    /// scheduler's `defaultPrefillTokensPerIteration`.
    private let continuousBatchPrefillTokensPerIteration: Int?
    /// SPEC-038 AC-26 opt-in: positive-cached turns with a usable retained
    /// handoff batch instead of serial-routing. Off keeps the fence.
    private let continuousBatchingCachedTurns: Bool
    /// SPEC-038 FR-CB10 operator-declared per-tuple acceptance coverage.
    private let continuousBatchingAcceptanceCoverage: ContinuousBatchingAcceptanceCoverage
    /// Verified SPEC-023 signed policy provenance. Coverage remains a separate
    /// exact-tuple gate so policy authorization cannot replace local proofs.
    private let continuousBatchingPolicyLoadResult: ContinuousBatchingPolicyLoadResult
    private let continuousBatchingModeExplicitlyConfigured: Bool
    private let continuousBatchingEmergencyOffOverride: Bool
    /// SPEC-038 v0.3.15: the on-device self-check's decision for the loaded
    /// tuple. Reset to pending on every swap.
    private var continuousBatchingSelfCheck: ContinuousBatchingSelfCheckState = .pending
    private var continuousBatchingSelfCheckReport: ContinuousBatchingSelfCheckReport?
    private let warmSwapEnabled: Bool
    private let swapDrainTimeoutSeconds: Int
    private var providerStatus: ProviderStatus?
    private var signalContinuations: [UUID: AsyncStream<SwapSignal>.Continuation] = [:]
    private var nextInFlightID: Int = 0
    private var inFlightCancellations: [Int: @Sendable () -> Void] = [:]
    /// SPEC-001-R011: registrations made by `acquireLocalRequestHandle`, the
    /// local-origin admission path (local chat and token utilities).
    private var localRegistrationIDs: Set<Int> = []
    private let loader: @Sendable (String) async throws -> (ModelContainer, String, String?)
    private let testLoader: (@Sendable (String) async throws -> (String, String?))?
    private let testCompletion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)?
    private let testStreamChunks: [StreamChunk]
    private let testSpeculativeCompletion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)?
    private let testSpeculativeStream: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)?
    private let nativeMTPRequestShapeCapture: NativeMTPRequestShapeCapture?
    #if DEBUG || MACPROVIDER_LAB_HARNESS
    private var labNativeMTPCommitTimingObserver: NativeMTPLabCommittedTokenTimingObserver?
    private var labNativeMTPDecodeOutputCap: NativeMTPLabDecodeOutputCap?
    private var labNativeMTPConversationCacheObserver: NativeMTPLabConversationCacheObserver?
    #endif

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

    /// Native MLX catalog serving settles through SPEC-015 receipts; it has no
    /// SPEC-047 admission rows, so eligibility is never gated on admission.
    nonisolated var isSettlementReceiptEligible: Bool { true }
    nonisolated var settlementRuntimeSource: String? { nil }

    /// The one constructor of serve generation parameters; every serial
    /// `generate`/`TokenIterator` the provider runs takes its parameters from
    /// here. `model` decides the KV cap: a model that sizes its own cache
    /// (`modelSizesItsOwnKVCache`) gets no `maxKVSize`, because mlx-swift-lm's
    /// explicit-cache check would reject its cache against any cap. Without
    /// that cap nothing else bounds its cache, so its completion budget is
    /// clamped to the context the prompt leaves (`serialMaxOutputTokens`).
    nonisolated static func makeServeGenerateParameters(
        model: any LanguageModel,
        maxTokens: Int?,
        promptTokens: Int,
        maxContextTokens: Int,
        kvBitsOverride: Int?,
        prefillStepSize: Int,
        temperature: Float,
        topP: Float
    ) throws -> GenerateParameters {
        GenerateParameters(
            maxTokens: try serialMaxOutputTokens(
                model: model,
                requested: maxTokens,
                promptTokens: promptTokens,
                maxContextTokens: maxContextTokens
            ),
            maxKVSize: modelSizesItsOwnKVCache(model) ? nil : maxContextTokens,
            kvBits: kvBitsOverride,
            temperature: temperature,
            topP: topP,
            prefill: .legacyRemainder(stepSize: prefillStepSize)
        )
    }

    /// SPEC-037 FR-KVP1 / SPEC-024-R001 — `LanguageModel.newCache` builds a
    /// `RotatingKVCache` whenever `maxKVSize != nil` and a `KVCacheSimple` only when it
    /// is nil. `makeServeGenerateParameters` always sets `maxKVSize = maxContextTokens`.
    /// Drop that cap for (1) SPEC-037 disk-tier eligible requests, so `captureSnapshot`
    /// can serialize `KVCacheSimple`, and (2) conversation-keyed serial requests, so
    /// FR-CI2 trim can succeed. mlx-swift-lm's `RotatingKVCache` is trimmable only while
    /// `offset < maxSize`; a keyed hit after the serve cap fills otherwise misses with
    /// `cache_not_trimmable` and re-prefills. The `TokenIterator` that consumes such a
    /// cache must get the same uncapped parameters (`serveIteratorParameters`), because
    /// mlx-swift-lm 3.32.3 validates an explicit cache against `maxKVSize`. Keyless
    /// traffic keeps the rotating cap.
    nonisolated static func cacheParameters(_ base: GenerateParameters, forceSimpleKV: Bool) -> GenerateParameters {
        guard forceSimpleKV else { return base }
        var p = base
        p.maxKVSize = nil
        return p
    }

    /// Parameters for a `TokenIterator` that receives an explicit serve cache.
    /// Since mlx-swift-lm 3.32.3 the iterator validates the explicit cache against
    /// the legacy `maxKVSize` capacity and throws `incompatibleCapacity` when a
    /// `KVCacheSimple` (forced simple, or a reused ConversationCache lease) meets a
    /// capped `maxKVSize`. The iterator must therefore see the same uncapped
    /// parameters the cache was built with (#1998). Prompt length is still bounded
    /// by `validatePromptTokenCount` before allocation.
    nonisolated static func serveIteratorParameters(
        _ base: GenerateParameters, forceSimpleKV: Bool, reusedCache: Bool, cache: [KVCache] = []
    ) -> GenerateParameters {
        explicitCacheIteratorParameters(
            cacheParameters(base, forceSimpleKV: forceSimpleKV || reusedCache),
            cache: cache
        )
    }

    /// Serial completion budget. A capped serve cache (`maxKVSize`, a
    /// `RotatingKVCache`) already bounds memory at `maxContextTokens`, so
    /// `requested` passes through unchanged. A model that sizes its own cache
    /// has no such cap and gets the continuous-batching row's bound
    /// (`continuousBatchMaxOutputTokens`): the context left after the prompt,
    /// never more than an explicit `max_tokens` (reaching it reports
    /// `length`), and the 413 `context_length_exceeded` when no output token
    /// fits.
    nonisolated static func serialMaxOutputTokens(
        requested: Int?,
        promptTokens: Int,
        maxContextTokens: Int,
        modelSizesItsOwnKVCache: Bool
    ) throws -> Int? {
        guard modelSizesItsOwnKVCache else { return requested }
        let remaining = maxContextTokens - promptTokens
        guard remaining >= 1 else {
            throw ContinuousBatchSchedulerError.contextLengthExceeded(
                promptTokens: promptTokens,
                maxOutputTokens: 1,
                contextTokens: maxContextTokens
            ).asAPIError()!
        }
        guard let requested else { return remaining }
        return min(requested, remaining)
    }

    nonisolated static func serialMaxOutputTokens(
        model: any LanguageModel,
        requested: Int?,
        promptTokens: Int,
        maxContextTokens: Int
    ) throws -> Int? {
        try serialMaxOutputTokens(
            requested: requested,
            promptTokens: promptTokens,
            maxContextTokens: maxContextTokens,
            modelSizesItsOwnKVCache: modelSizesItsOwnKVCache(model)
        )
    }

    /// GLM-5-Next's sparse layers always build their own `GLM5NextLatentCache`
    /// and ignore `maxKVSize`; mlx-swift-lm's explicit-cache check counts each
    /// such layer as not realizing a requested cap
    /// (`incompatibleCapacity(expected: maxKVSize, count: 11)`). Prompt length
    /// is still bounded by `validatePromptTokenCount` before allocation.
    nonisolated static func modelSizesItsOwnKVCache(_ model: any LanguageModel) -> Bool {
        model is GLM5NextModel || model is GLM5NextTextModel
    }

    /// Parameters for a `TokenIterator` over an explicit cache the model sized
    /// itself. GLM-5-Next's sparse layers always return their own
    /// `GLM5NextLatentCache`, whatever `maxKVSize` says, and mlx-swift-lm's
    /// explicit-cache check counts every such non-rotating attention layer as
    /// not realizing the requested capacity (`incompatibleCapacity(expected:
    /// maxKVSize, count: 11)` on GLM-5.3-Flash), so any serial request with the
    /// serve cap failed. The iterator gets the uncapped parameters, as for
    /// `KVCacheSimple` (#1998); prompt length is still bounded by
    /// `validatePromptTokenCount` before allocation. Exactly the caches that
    /// carry a `GLM5NextLatentCache` are affected.
    nonisolated static func explicitCacheIteratorParameters(
        _ parameters: GenerateParameters, cache: [KVCache]
    ) -> GenerateParameters {
        guard parameters.maxKVSize != nil, cache.contains(where: { $0 is any GLM5NextLatentCache }) else {
            return parameters
        }
        var uncapped = parameters
        uncapped.maxKVSize = nil
        return uncapped
    }

    /// True when ConversationCache will attempt reuse (trimmed non-empty key).
    nonisolated static func hasReusableConversationKey(_ conversationKey: String?) -> Bool {
        guard let key = conversationKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return false
        }
        return true
    }

    /// SPEC-024-R001 — keyed serial serve and SPEC-037 eligible persist both need
    /// `KVCacheSimple` on full-attention models. Sliding-window models that still
    /// return `RotatingKVCache` with `maxKVSize = nil` stay non-simple and miss.
    nonisolated static func forceSimpleKVCache(eligible: Bool, conversationKey: String?, containsImage: Bool = false) -> Bool {
        if containsImage { return false }
        return eligible || hasReusableConversationKey(conversationKey)
    }

    /// The single serve cache-allocation used at BOTH serve sites (non-streaming +
    /// streaming). `forceSimpleKV` drops `maxKVSize` via `cacheParameters`. Extracted so
    /// a serve-site regression that reverts to `newCache(parameters:)` must change THIS
    /// helper — pinned by `testEligibleServeNewCacheProducesKVCacheSimple` and
    /// `testConversationKeyedServeCacheProducesTrimmableKVCacheSimple`.
    nonisolated static func serveCache(
        model: any LanguageModel, baseParameters: GenerateParameters, forceSimpleKV: Bool
    ) throws -> [KVCache] {
        try model.newCache(parameters: cacheParameters(baseParameters, forceSimpleKV: forceSimpleKV))
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
            hybridDecoderArchitectureVerified: capabilities.hybridDecoderArchitectureVerified,
            blockSizeMultiple: capabilities.sparseAttention?.indexKpool ?? 1,
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
        modelCapabilities: PagedKVRuntimeModelCapabilities? = nil,
        observedRuntimeIdentity: PagedKVObservedRuntimeIdentity? = nil,
        hardwareSizingProof: PagedKVHardwareSizingProof? = nil,
        schedulerBackendInstalled: Bool = false
    ) -> PagedKVAttachDecision {
        let capabilities = modelCapabilities ?? Self.pagedKVModelCapabilities(modelID: modelID, configJSONData: nil)
        return pagedKVAttachDecision(
            config: config,
            modelID: modelID,
            modelHash: modelHash,
            tokenizerSHA256: tokenizerSHA256,
            chatTemplateSHA256: chatTemplateSHA256,
            kvBitsOverride: kvBitsOverride,
            runtimeCacheClass: runtimeCacheClass,
            gates: Self.pagedKVRuntimeBridgeGates(
                config: config,
                modelID: modelID,
                modelHash: modelHash,
                tokenizerSHA256: tokenizerSHA256,
                chatTemplateSHA256: chatTemplateSHA256,
                modelCapabilities: capabilities,
                observedRuntimeIdentity: observedRuntimeIdentity,
                hardwareSizingProof: hardwareSizingProof,
                schedulerBackendInstalled: schedulerBackendInstalled
            ),
            modelCapabilities: capabilities
        )
    }

    private nonisolated static func pagedKVRuntimeBridgeGates(
        config: PagedKVConfig,
        modelID: String?,
        modelHash: String?,
        tokenizerSHA256: String?,
        chatTemplateSHA256: String?,
        modelCapabilities: PagedKVRuntimeModelCapabilities,
        observedRuntimeIdentity: PagedKVObservedRuntimeIdentity?,
        hardwareSizingProof: PagedKVHardwareSizingProof?,
        schedulerBackendInstalled: Bool
    ) -> PagedKVGates {
        guard modelHash?.isEmpty == false,
              let observedRuntimeIdentity,
              let hardwareSizingProof,
              observedRuntimeIdentity.isCompleteRuntimeMeasurement
        else {
            return .runtimeClosed(identityAvailable: modelHash?.isEmpty == false)
        }
        let preflightIdentityMatches = hardwareSizingProof.covers(
            config: config,
            modelID: modelID ?? "",
            modelSHA256: modelHash ?? "",
            tokenizerSHA256: tokenizerSHA256,
            chatTemplateSHA256: chatTemplateSHA256,
            modelFamily: modelCapabilities.modelFamily,
            observedHardwareClass: observedRuntimeIdentity.hardwareClass,
            observedMetallibSHA256: observedRuntimeIdentity.metallibSHA256,
            observedKernelIdentifier: observedRuntimeIdentity.kernelIdentifier,
            observedParityLabel: observedRuntimeIdentity.parityLabel,
            poolEpoch: observedRuntimeIdentity.poolEpoch
        )
        return PagedKVGates(
            identityAvailable: true,
            observedHardwareClass: observedRuntimeIdentity.hardwareClass,
            metallibAvailable: preflightIdentityMatches,
            kernelRegistered: preflightIdentityMatches,
            parityEstablished: preflightIdentityMatches,
            hardwareSizingProof: hardwareSizingProof,
            observedMetallibSHA256: observedRuntimeIdentity.metallibSHA256,
            observedKernelIdentifier: observedRuntimeIdentity.kernelIdentifier,
            observedParityLabel: observedRuntimeIdentity.parityLabel,
            moeDispatchProven: observedRuntimeIdentity.moeDispatchProven,
            engineBridgeAvailable: schedulerBackendInstalled && preflightIdentityMatches,
            observedRuntimeIdentity: observedRuntimeIdentity
        )
    }

    /// SPEC-039 FR-PKV4/FR-PKV12 parity label suffix: `glm5_next` results
    /// (MLA sparse attention over gathered latent and pooled keys) never share
    /// a label with stock-SDPA tuples.
    nonisolated static func pagedKVParityLabelSuffix(modelFamily: String) -> String {
        modelFamily == "glm5_next" ? "glm5-next-mla-parity-v1" : "sdpa-parity-v1"
    }

    /// SPEC-039 FR-PKV12 (v0.1.20): the `glm5_next` AC-20 fixture, attach
    /// proof and row-isolation evidence are recorded under
    /// `docs/evidence/glm53-flash-t4-2026-10-17/`, so the entry advertises
    /// its exact identity. The load-time parity and isolation probes, the
    /// per-Mac FR-CB10 self-check and the signed CB policy still gate serving.
    nonisolated static let glm5NextPagedAttachEvidenceRecorded = true

    nonisolated static func measurePagedKVRuntime(
        config: PagedKVConfig,
        modelID: String?,
        modelSHA256: String?,
        tokenizerSHA256: String?,
        chatTemplateSHA256: String?,
        modelCapabilities: PagedKVRuntimeModelCapabilities,
        parityProbe: PagedKVRuntimeParityProbeResult?,
        moeProbe: PagedKVRuntimeMoEProbeResult?,
        environment: PagedKVRuntimeMeasurementEnvironment = .live
    ) -> PagedKVRuntimeMeasurement? {
        guard config.effectiveEnabled,
              let modelID = Self.nonEmpty(modelID),
              let modelSHA256 = Self.nonEmpty(modelSHA256),
              PagedKVAttachGate.recognizedModelFamilies.contains(modelCapabilities.modelFamily)
        else {
            // Stay silent in the normal disabled case (the fleet default) so this feature
            // is invisible when off; only name the failing precondition once the operator
            // has actually opted in, where knowing WHICH precondition blocked is useful.
            if config.effectiveEnabled {
                PagedKVRuntimeDiagnostics.log("measure nil: preconditions (family=\(modelCapabilities.modelFamily) recognized=\(PagedKVAttachGate.recognizedModelFamilies.contains(modelCapabilities.modelFamily)) modelID=\(Self.nonEmpty(modelID) != nil) modelSHA=\(Self.nonEmpty(modelSHA256) != nil))")
            }
            return nil
        }
        guard let metallibPath = environment.metallibCandidatePaths().first(where: environment.fileExists),
              let metallibData = try? environment.readFileData(metallibPath),
              !metallibData.isEmpty
        else {
            PagedKVRuntimeDiagnostics.log("measure nil: metallib file absent/unreadable/empty (candidates=\(environment.metallibCandidatePaths()))")
            return nil
        }
        let metallibSHA256 = hexString(SHA256.hash(data: metallibData))
        guard let kernelIdentifier = Self.nonEmpty(environment.registeredKernelIdentifier()) else {
            PagedKVRuntimeDiagnostics.log("measure nil: kernel identifier not registered")
            return nil
        }
        let fingerprint = environment.hardwareFingerprint()
        let chip = fingerprint.chip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chip.isEmpty, chip.lowercased() != "unknown", fingerprint.ramGB > 0 else {
            PagedKVRuntimeDiagnostics.log("measure nil: hardware fingerprint unresolved (chip=\(chip) ramGB=\(fingerprint.ramGB))")
            return nil
        }
        let hardwareClass = "apple-silicon:\(chip):ram-\(fingerprint.ramGB)gb"
        // The parity label is derived ONLY from a genuinely established on-device gather
        // parity probe: token-for-token argmax equality against stock KVCacheSimple, plus
        // proof the real Metal gather ran for every layer at every forward pass over BOTH
        // K and V (`nLayers * nNew * 2`) across a non-degenerate (>= 3 block),
        // boundary-crossing, non-identity layout. Anything short of that fails closed —
        // no measured parity, no label, no attach.
        // SPEC-039 FR-PKV12: the `glm5_next` entry advertises only with its
        // evidence recorded (`glm5NextPagedAttachEvidenceRecorded`); without
        // it attach fails closed on parity.
        if modelCapabilities.modelFamily == "glm5_next", !Self.glm5NextPagedAttachEvidenceRecorded {
            PagedKVRuntimeDiagnostics.log("measure nil: glm5_next paged attach evidence not recorded (SPEC-039 AC-20)")
            return nil
        }
        // Every paged layer gathers twice per forward: K and V, or for
        // `pagedMLA` the latent and the pooled keys (SPEC-039 FR-PKV4 rule 4).
        guard let parity = parityProbe,
              parity.established,
              parity.nLayers > 0,
              parity.nNew > 0,
              parity.nForwards >= parity.nNew,
              parity.gatherKernelCalls == parity.nLayers * parity.nForwards * 2,
              parity.maxLogicalBlocks >= 3,
              parity.nonIdentityPermutation
        else {
            if let p = parityProbe {
                PagedKVRuntimeDiagnostics.log(
                    "measure nil: parity gate (established=\(p.established) nLayers=\(p.nLayers) nNew=\(p.nNew) nForwards=\(p.nForwards) gatherKernelCalls=\(p.gatherKernelCalls) expect=\(p.nLayers * p.nForwards * 2) maxLogicalBlocks=\(p.maxLogicalBlocks)>=3? nonIdentity=\(p.nonIdentityPermutation))")
            } else {
                PagedKVRuntimeDiagnostics.log("measure nil: parity probe result nil")
            }
            return nil
        }
        let parityLabel = hexString(SHA256.hash(data: Data(
            "\(metallibSHA256)|\(kernelIdentifier)|\(modelSHA256)|\(tokenizerSHA256 ?? "")|\(chatTemplateSHA256 ?? "")|\(hardwareClass)|\(modelID)|blk\(config.blockSizeTokens)|max\(config.maxPhysicalBlocks)|\(Self.pagedKVParityLabelSuffix(modelFamily: modelCapabilities.modelFamily))".utf8
        )))
        // EVERY paging-eligible model attaches only when a batched shared-forward step is
        // proven to keep rows isolated — the SPEC-038 FR-CB6 determinism/isolation
        // invariant that the serve-time batched `decode(rows:)` path relies on for dense
        // and MoE models alike (the cross-row `makeMask` runs regardless of family).
        // Validate the FULL probe result shape — not just `proven` — so an inconsistent
        // result (proven:true but rowsDecoded != 2, a row failure, a cross-row divergence,
        // or a non-distinguishing challenge) can never open attach. `challengeDistinguishing`
        // guarantees the two probe rows have different serial references, so a shared
        // forward that swapped/leaked row logits is detectable.
        guard let batched = moeProbe,
              batched.proven,
              batched.sharedForwardParityProven,
              batched.parityTokensCompared >= PagedKVRuntimeParityProbe.sharedForwardParityTokens,
              batched.challengeDistinguishing,
              batched.rowsDecodedInSharedForward == 2,
              batched.rowFailures == 0,
              batched.crossRowDivergences == 0
        else {
            if let m = moeProbe {
                PagedKVRuntimeDiagnostics.log(
                    "measure nil: batched-isolation gate (proven=\(m.proven) sharedForwardParity=\(m.sharedForwardParityProven) parityTokens=\(m.parityTokensCompared) challengeDistinguishing=\(m.challengeDistinguishing) rowsDecoded=\(m.rowsDecodedInSharedForward) rowFailures=\(m.rowFailures) crossRowDivergences=\(m.crossRowDivergences))")
            } else {
                PagedKVRuntimeDiagnostics.log("measure nil: batched-isolation probe result nil")
            }
            return nil
        }
        // `moeDispatchProven` stays MoE-specific: it feeds the descriptor's
        // `supportsMoEDispatch` and the attach gate's `requiresMoEDispatch` check, so a
        // dense model must NOT report it true even though it passed the same probe.
        let moeDispatchProven = modelCapabilities.requiresMoEDispatch
        let poolEpoch = 1
        guard let maxResidentTokens = PagedKVRuntimeCapacityProof.measuredMaxResidentTokens(
            config: config,
            poolEpoch: poolEpoch
        ) else {
            PagedKVRuntimeDiagnostics.log("measure nil: capacity sizing unmeasured (blockSize=\(config.blockSizeTokens) maxPhysicalBlocks=\(config.maxPhysicalBlocks))")
            return nil
        }
        let observedIdentity = PagedKVObservedRuntimeIdentity(
            hardwareClass: hardwareClass,
            metallibSHA256: metallibSHA256,
            kernelIdentifier: kernelIdentifier,
            parityLabel: parityLabel,
            moeDispatchProven: moeDispatchProven,
            poolEpoch: poolEpoch,
            source: .runtimeMeasurement
        )
        guard observedIdentity.isCompleteRuntimeMeasurement else {
            PagedKVRuntimeDiagnostics.log("measure nil: observed identity incomplete (parityLabel=\(observedIdentity.parityLabel.isEmpty ? "empty" : "set") moeProven=\(observedIdentity.moeDispatchProven))")
            return nil
        }
        let proof = PagedKVHardwareSizingProof(
            modelID: modelID,
            modelSHA256: modelSHA256,
            tokenizerSHA256: tokenizerSHA256,
            chatTemplateSHA256: chatTemplateSHA256,
            modelFamily: modelCapabilities.modelFamily,
            hardwareClass: hardwareClass,
            metallibSHA256: metallibSHA256,
            kernelIdentifier: kernelIdentifier,
            blockSizeTokens: config.blockSizeTokens,
            maxPhysicalBlocks: config.maxPhysicalBlocks,
            maxResidentTokens: maxResidentTokens,
            poolEpoch: poolEpoch,
            parityLabel: parityLabel
        )
        guard proof.covers(
            config: config,
            modelID: modelID,
            modelSHA256: modelSHA256,
            tokenizerSHA256: tokenizerSHA256,
            chatTemplateSHA256: chatTemplateSHA256,
            modelFamily: modelCapabilities.modelFamily,
            observedHardwareClass: observedIdentity.hardwareClass,
            observedMetallibSHA256: observedIdentity.metallibSHA256,
            observedKernelIdentifier: observedIdentity.kernelIdentifier,
            observedParityLabel: observedIdentity.parityLabel,
            poolEpoch: observedIdentity.poolEpoch
        ) else {
            PagedKVRuntimeDiagnostics.log("measure nil: sizing proof does not cover observed identity")
            return nil
        }
        PagedKVRuntimeDiagnostics.log("measure OK: runtime measurement complete, paged-KV attach eligible for model=\(modelID)")
        // The runtime-revision fields an operator copies into
        // `continuous_batching_accepted_tuples` after this build passes acceptance.
        PagedKVRuntimeDiagnostics.log("runtime-identity model=\(modelID) model_sha256=\(modelSHA256) hardware_class=\(hardwareClass) metallib_sha256=\(metallibSHA256) kernel_identifier=\(kernelIdentifier)")
        return PagedKVRuntimeMeasurement(
            observedRuntimeIdentity: observedIdentity,
            hardwareSizingProof: proof
        )
    }

    /// Fixed canned prompt for the SPEC-039 parity self-test. Long enough (well over
    /// 200 words) to tokenize past 3 * the default `blockSizeTokens` (16), so the
    /// gather diagnostics observe a non-degenerate, boundary-crossing layout at typical
    /// configured block sizes. A short/degenerate tokenization at an unusually large
    /// configured block size fails the probe CLOSED (see `measurePagedKVRuntime`'s
    /// `maxLogicalBlocks >= 3` gate) rather than silently skipping the check.
    private static let pagedKVRuntimeParityProbePrompt = """
        The lighthouse keeper climbed the spiral stairs before dawn, counting each \
        worn stone step out of habit rather than need. Below, the harbor lay quiet \
        under a thin fog that softened the outlines of the fishing boats moored along \
        the pier. She had kept this light for eleven years, through storms that tore \
        shingles from the roof and summers so still the sea looked like glass from \
        sunrise to dusk. Every night the same ritual: check the lamp, check the fuel, \
        check the logbook, and note the weather in careful, unhurried handwriting. \
        Tonight she paused at the gallery railing and watched a single trawler cut a \
        slow wake toward open water, its running lights blinking red and green against \
        the gray. Somewhere past the point, gulls were already arguing over the first \
        catch of the morning, their calls carried thin and sharp across the water. She \
        thought, not for the first time, that the work suited her precisely because it \
        asked so little in the way of explanation and so much in the way of attention. \
        The light did not care about her opinions; it only needed tending, faithfully, \
        one revolution after another, long after the boats and the gulls and the fog \
        had gone their own separate ways into the widening day.
        """

    /// A second, distinct canned prompt for the SPEC-039 MoE input-isolation self-test,
    /// deliberately short — `runMoEInputIsolationProbe` only requires each prompt be
    /// non-empty, and the proof it establishes (row isolation across a batched shared
    /// forward) does not depend on prompt length the way the parity gather probe does.
    private static let pagedKVRuntimeMoEProbePromptA = "Draft a short summary of today's shipping forecast."
    private static let pagedKVRuntimeMoEProbePromptB = "List three ingredients commonly used in a simple tomato soup."

    /// Ordered challenge pairs for the isolation probe. The proof needs the two
    /// rows' serial greedy tokens to differ at every checked step, or a leak
    /// could hide behind identical references. Raw-prose prompts can share a
    /// first token (Studio 2026-09-24: Qwen3.6-27B), so later pairs force
    /// different continuations. Each pair is still checked against its own
    /// serial references, so trying another pair cannot weaken the proof.
    private static let pagedKVRuntimeIsolationProbePromptPairs: [(String, String)] = [
        (pagedKVRuntimeMoEProbePromptA, pagedKVRuntimeMoEProbePromptB),
        ("Count upward in words: one, two, three,", "The first letters of the alphabet are A, B, C,"),
        ("def add(a, b):\n    return", "<html>\n  <head>\n    <title>"),
    ]

    /// Runs the SPEC-039 on-device self-measurement probes (parity, and MoE input
    /// isolation when the resident model requires MoE dispatch) against `container`.
    /// Returns `(nil, nil)` immediately, without touching the model, unless paged KV is
    /// configured on AND the model family is one the attach gate recognizes — so this
    /// never runs extra forward passes on a model/config combination that could not
    /// attach anyway. Called at both load-time and warm-swap adoption sites, strictly
    /// before the runtime is marked ready and before any buyer request is served.
    private func computePagedKVRuntimeProbes(
        container: ModelContainer,
        modelID: String,
        modelCapabilities: PagedKVRuntimeModelCapabilities,
        runtimeCacheClass: String
    ) async -> (PagedKVRuntimeParityProbeResult?, PagedKVRuntimeMoEProbeResult?) {
        // Skip the real model forwards for tuples the (unchanged) attach gate will reject
        // anyway: disabled paged KV, unrecognized family, quantized KV, or a cache class
        // outside the allowlist. This avoids spending Metal work that cannot open attach.
        guard pagedKVConfig.effectiveEnabled,
              Self.pagedKVSkipReason(config: pagedKVConfig, nativeVision: currentNativeVisionProfile != nil) == nil,
              kvBitsOverride == nil,
              PagedKVAttachGate.recognizedModelFamilies.contains(modelCapabilities.modelFamily),
              PagedKVAttachGate.supportsCacheClass(
                  runtimeCacheClass,
                  hybridDecoderArchitectureVerified: modelCapabilities.hybridDecoderArchitectureVerified
              )
        else {
            return (nil, nil)
        }
        let cacheKinds = try? await container.perform { context in
            try Self.pagedKVCacheKinds(model: context.model)
        }
        guard let cacheKinds,
              runtimeCacheClass != "mixed"
                || Self.measuredMixedPagedKVTopology(
                    cacheKinds,
                    modelCapabilities: modelCapabilities
                )
        else { return (nil, nil) }
        let probePromptTokens = modelCapabilities.attachProbePromptTokens(blockSizeTokens: pagedKVConfig.blockSizeTokens)
        let encodedProbePrompt = await container.perform { context in
            context.tokenizer.encode(text: Self.pagedKVRuntimeParityProbePrompt, addSpecialTokens: true)
        }
        let promptTokens = modelCapabilities.sparseAttention == nil
            ? encodedProbePrompt
            : Self.repeatedProbeTokens(encodedProbePrompt, targetCount: probePromptTokens)
        let parityProbe = await pagedKVRuntimeProber.parity(
            container,
            modelID,
            pagedKVConfig.blockSizeTokens,
            pagedKVConfig.maxPhysicalBlocks,
            promptTokens,
            32
        )
        // The batched shared-forward isolation probe exercises the cross-row attention
        // mask (`PagedKVBatchLayerCache.makeMask`) and per-row decode isolation — the
        // SPEC-038 FR-CB6 determinism/isolation invariant — which the serve-time batched
        // `decode(rows:)` path uses for EVERY paging-eligible model, dense or MoE. Run it
        // for all recognized families (not only `requiresMoEDispatch`) so a dense model
        // cannot attach on the single-row parity probe alone and then serve a batched path
        // that was never proven. For MoE it additionally proves expert dispatch stays
        // per-row.
        let layerCount = (try? await container.perform { context in
            try context.model.newCache(parameters: nil).count
        }) ?? 0
        let pairs = Self.pagedKVRuntimeIsolationProbePromptPairs
        let prober = pagedKVRuntimeProber
        let blockSizeTokens = pagedKVConfig.blockSizeTokens
        let maxPhysicalBlocks = pagedKVConfig.maxPhysicalBlocks
        let moeProbe = await Self.firstDistinguishingIsolationProbe(pairCount: pairs.count) { pairIndex in
            let pair = pairs[pairIndex]
            let promptA = await container.perform { context in
                context.tokenizer.encode(text: pair.0, addSpecialTokens: true)
            }
            let promptB = await container.perform { context in
                context.tokenizer.encode(text: pair.1, addSpecialTokens: true)
            }
            let parityPromptA = Self.repeatedProbeTokens(promptA, targetCount: probePromptTokens)
            let parityPromptB = Self.repeatedProbeTokens(promptB, targetCount: probePromptTokens)
            return await prober.moe(
                container,
                blockSizeTokens,
                maxPhysicalBlocks,
                1,
                layerCount,
                promptA,
                promptB,
                parityPromptA,
                parityPromptB,
                cacheKinds
            )
        } onIndistinguishable: { pairIndex in
            PagedKVRuntimeDiagnostics.log(
                "batched-isolation model=\(modelID) challenge pair \(pairIndex) not distinguishing; trying next"
            )
        }
        guard let moeProbe else { return (nil, nil) }
        let p = parityProbe
        PagedKVRuntimeDiagnostics.log(
            "parity model=\(modelID) established=\(p.established) nLayers=\(p.nLayers) nNew=\(p.nNew) nForwards=\(p.nForwards) gatherKernelCalls=\(p.gatherKernelCalls) expectCalls=\(p.nLayers * p.nForwards * 2) maxLogicalBlocks=\(p.maxLogicalBlocks) nonIdentityPermutation=\(p.nonIdentityPermutation)"
        )
        let m = moeProbe
        PagedKVRuntimeDiagnostics.log(
            "batched-isolation model=\(modelID) requiresMoE=\(modelCapabilities.requiresMoEDispatch) proven=\(m.proven) rowsDecoded=\(m.rowsDecodedInSharedForward) rowFailures=\(m.rowFailures) crossRowDivergences=\(m.crossRowDivergences) challengeDistinguishing=\(m.challengeDistinguishing)"
        )
        return (parityProbe, moeProbe)
    }

    /// Runs challenge pairs in order and returns the first verdict. Only a
    /// clean indistinguishable run (both rows decoded, no row failure, no
    /// divergence, serial references merely identical) moves on to the next
    /// pair. Anything else — a distinguishing pass, a real divergence, a probe
    /// failure or exception (`.failClosed`), an incomplete decode — is final,
    /// so a failure can never be retried away by a later passing pair. If no
    /// pair distinguishes, the last result is returned, which is never
    /// `proven`, so the attach gate fails closed.
    static func firstDistinguishingIsolationProbe(
        pairCount: Int,
        attempt: (Int) async -> PagedKVRuntimeMoEProbeResult,
        onIndistinguishable: (Int) -> Void = { _ in }
    ) async -> PagedKVRuntimeMoEProbeResult? {
        var last: PagedKVRuntimeMoEProbeResult?
        for pairIndex in 0 ..< pairCount {
            let result = await attempt(pairIndex)
            last = result
            guard isCleanIndistinguishableIsolationRun(result) else { return result }
            onIndistinguishable(pairIndex)
        }
        return last
    }

    private static func isCleanIndistinguishableIsolationRun(_ result: PagedKVRuntimeMoEProbeResult) -> Bool {
        !result.challengeDistinguishing
            && !result.proven
            && result.sharedForwardParityProven
            && result.parityTokensCompared >= PagedKVRuntimeParityProbe.sharedForwardParityTokens
            && result.rowsDecodedInSharedForward == 2
            && result.rowFailures == 0
            && result.crossRowDivergences == 0
    }

    static func measuredMixedPagedKVTopology(
        _ cacheKinds: [PagedKVSharedForwardBackend.CacheKind],
        modelCapabilities: PagedKVRuntimeModelCapabilities
    ) -> Bool {
        guard modelCapabilities.hybridDecoderArchitectureVerified else { return false }
        if modelCapabilities.modelFamily == "glm5_next" {
            // Exactly one cache per decoder layer, in layer order, each pool
            // width equal to `index_kpool` (SPEC-039 FR-PKV12).
            guard let sparse = modelCapabilities.sparseAttention else { return false }
            return cacheKinds == sparse.expectedCacheKinds
        }
        guard cacheKinds.contains(.pagedAttention),
              !cacheKinds.contains(where: \.isPagedMLA)
        else { return false }
        if modelCapabilities.modelFamily == "qwen",
           cacheKinds.contains(.recurrentMamba),
           !cacheKinds.contains(where: \.hasSlidingWindow) {
            return true
        }
        if modelCapabilities.modelFamily == "gpt_oss",
           cacheKinds.contains(where: \.hasSlidingWindow),
           !cacheKinds.contains(.recurrentMamba) {
            return true
        }
        return false
    }

    private static func repeatedProbeTokens(_ seed: [Int], targetCount: Int) -> [Int] {
        guard targetCount > 0, !seed.isEmpty else { return seed }
        var tokens: [Int] = []
        tokens.reserveCapacity(targetCount)
        while tokens.count < targetCount {
            tokens.append(contentsOf: seed.prefix(targetCount - tokens.count))
        }
        return tokens
    }

    /// Upper bound for `mlx_cache_limit_mb` (1 TiB). Far above any Mac's
    /// unified memory, and small enough that the byte conversion cannot overflow.
    nonisolated static let maximumMLXCacheLimitMB = 1_048_576

    nonisolated static func isValidMLXCacheLimitMB(_ megabytes: Int) -> Bool {
        (0 ... maximumMLXCacheLimitMB).contains(megabytes)
    }

    /// Bounds MLX's buffer cache. Must run before the model loads; see
    /// `AppConfig.mlxCacheLimitMB`. Serve startup rejects an out-of-range value
    /// first (`isValidMLXCacheLimitMB`), so `nil` here only means "not set".
    /// Returns the applied byte limit.
    @discardableResult
    nonisolated static func applyMLXCacheLimit(megabytes: Int?) -> Int? {
        guard let megabytes, isValidMLXCacheLimitMB(megabytes) else { return nil }
        let bytes = megabytes * 1024 * 1024
        Memory.cacheLimit = bytes
        return bytes
    }

    /// Families served with the process wired limit at Metal's recommended
    /// working set for as long as the model is loaded.
    nonisolated static let residentWeightsFamilies: Set<String> = ["glm5_next"]

    /// A model-lifetime wired-limit ticket at Metal's recommended working set,
    /// the limit mlx-lm's generation paths set. At the default limit (0) no
    /// buffer joins MLX's residency sets, and a model this close to the working
    /// set (GLM-5.3-Flash: ~185 GB of 239 GB on a 256 GB M3 Ultra) pays a
    /// multi-second residency cost on every forward: 0.38 tok/s decode, while a
    /// 30 GB cut of the same model decodes at 75 tok/s. A fixed policy always
    /// admits, so starting the ticket never suspends a load. Nil for other
    /// families and when Metal reports no working set.
    nonisolated static func residentWeightsTicket(
        modelFamily: String,
        recommendedWorkingSetBytes: Int?
    ) -> WiredMemoryTicket? {
        guard residentWeightsFamilies.contains(modelFamily),
              let bytes = recommendedWorkingSetBytes, bytes > 0
        else { return nil }
        return WiredMemoryTicket(
            size: bytes, policy: MLXLMCommon.WiredFixedPolicy(limit: bytes), kind: .active)
    }

    nonisolated static func startResidentWeightsTicket(modelFamily: String) async -> WiredMemoryTicket? {
        guard let ticket = residentWeightsTicket(
            modelFamily: modelFamily,
            recommendedWorkingSetBytes: GPU.maxRecommendedWorkingSetBytes()
        ) else { return nil }
        _ = await ticket.start()
        return ticket
    }

    /// Families served with a larger MLX per-command-buffer byte budget, in MB.
    /// MLX commits a command buffer once its distinct input arrays pass
    /// `MLX_MAX_MB_PER_BUFFER` (50 MB on Max/Ultra GPUs). glm5_next's fused MoE
    /// kernels bind whole 288-expert tensors (~4 GB per layer), so every MoE
    /// layer forced commits: 168 command buffers and ~1.2 ms of GPU idle per
    /// decode step at 1k on the M3 Ultra. At 65536 MB MLX's per-buffer op limit
    /// governs instead (19 command buffers, 0.26 ms idle, round-4 window). The
    /// value only shapes command-buffer batching; buffers still commit every
    /// MLX op limit.
    nonisolated static let commandBufferBudgetMBByFamily: [String: Int] = ["glm5_next": 65536]

    /// The per-buffer MB budget to set for a family, or `nil` when the family
    /// keeps MLX's default or the operator already set `MLX_MAX_MB_PER_BUFFER`.
    nonisolated static func commandBufferBudgetMB(modelFamily: String, configured: String?) -> Int? {
        guard let configured, !configured.isEmpty else { return commandBufferBudgetMBByFamily[modelFamily] }
        return nil
    }

    /// Sets the family's command-buffer budget for this process. MLX reads it
    /// once, when it creates its Metal device, so this must run before any MLX
    /// device use (the MLX cache limit, model load). Returns the MB applied.
    @discardableResult
    nonisolated static func applyMLXCommandBufferBudget(modelFamily: String) -> Int? {
        let key = "MLX_MAX_MB_PER_BUFFER"
        guard let mb = commandBufferBudgetMB(
            modelFamily: modelFamily, configured: ProcessInfo.processInfo.environment[key])
        else { return nil }
        setenv(key, String(mb), 0)
        return mb
    }

    /// The model family of a local model target, from its `config.json`.
    nonisolated static func localModelFamily(_ target: String) -> String? {
        guard let directory = try? localModelDirectory(for: target),
              let data = try? Data(contentsOf: directory.appendingPathComponent("config.json"))
        else { return nil }
        return pagedKVModelCapabilities(modelID: target, configJSONData: data).modelFamily
    }

    nonisolated static func clearMLXBufferCacheAfterPrefill(
        using clear: () -> Void = { Memory.clearCache() }
    ) {
        clear()
    }

    private static let pagedKVUnavailableCacheClass = "unavailable"

    /// #2016: a native-vision (VLM) container has no text-only
    /// `callAsFunction(_: MLXArray, cache:)` — Qwen2VL traps in MLXLMCommon — and
    /// the paged probes, cache-class probe and batched engine all forward that
    /// way. A vision runtime therefore always serves on the non-paged cache;
    /// paged KV stays unattached for it with no operator config needed.
    nonisolated static func pagedKVSkipReason(config: PagedKVConfig, nativeVision: Bool) -> String? {
        guard config.effectiveEnabled, nativeVision else { return nil }
        return "native_vision_profile"
    }

    private nonisolated static func logPagedKVSkip(_ reason: String?) {
        guard let reason else { return }
        FileHandle.standardError.write(Data("event=paged_kv action=skipped reason=\(reason)\n".utf8))
    }

    private static func pagedKVRuntimeCacheClass(
        container: ModelContainer?,
        maxContextTokens: Int,
        kvBitsOverride: Int?,
        prefillStepSize: Int
    ) async -> String {
        guard let container else { return Self.pagedKVUnavailableCacheClass }
        return await container.perform { context in
            // A cache-class probe: no prompt and one output token always fit.
            guard let parameters = try? Self.makeServeGenerateParameters(
                                model: context.model,
maxTokens: 1,
                promptTokens: 0,
                maxContextTokens: maxContextTokens,
                kvBitsOverride: kvBitsOverride,
                prefillStepSize: prefillStepSize,
                temperature: 0.0,
                topP: 1.0
            ) else { return Self.pagedKVUnavailableCacheClass }
            // The paged / continuous-batching path never uses the memory-capped serve
            // cache: batched rows are stored in the SPEC-039 paged block pool (which
            // bounds memory the way `maxKVSize` bounds the non-batched serve cache).
            // `makeServeGenerateParameters` always sets `maxKVSize = maxContextTokens`,
            // which makes `LanguageModel.newCache` allocate a `RotatingKVCache` — never
            // the `KVCacheSimple` the paged engine's allowlist (SPEC-039 FR-PKV12)
            // requires — so probing the default serve params would reject EVERY
            // memory-capped serve config regardless of whether the model is paging-
            // compatible. Probe the class the batched path actually pages
            // (`maxKVSize = nil` → `KVCacheSimple` for full-attention models).
            // A genuine sliding-window model still returns RotatingKVCache or
            // mixed uncapped. The shared-forward mapper can represent keep=0
            // rotating layers for isolated harness use, but FR-PKV12 attach
            // stays fail-closed until that identity is evidence-gated.
            return (try? Self.pagedKVRuntimeCacheClass(
                model: context.model,
                baseParameters: Self.cacheParameters(parameters, forceSimpleKV: true)
            )) ?? Self.pagedKVUnavailableCacheClass
        }
    }

    nonisolated static func pagedKVRuntimeCacheClass(model: any LanguageModel, baseParameters: GenerateParameters) throws -> String {
        let caches = try model.newCache(parameters: baseParameters)
        guard let first = caches.first else { return "empty" }
        let firstClass = String(describing: type(of: first))
        guard caches.allSatisfy({ String(describing: type(of: $0)) == firstClass }) else {
            return "mixed"
        }
        return firstClass
    }

    private nonisolated static func pagedKVCacheKinds(
        model: any LanguageModel
    ) throws -> [PagedKVSharedForwardBackend.CacheKind]? {
        PagedKVSharedForwardBackend.CacheKind.kinds(from: try model.newCache(parameters: nil))
    }

    nonisolated static func pagedKVModelFamily(_ modelID: String?) -> String {
        let lower = modelID?.lowercased() ?? ""
        if lower.contains("qwen") { return "qwen" }
        if lower.contains("llama") { return "llama" }
        return "unknown"
    }

    private nonisolated static func pagedKVModelFamily(
        modelID: String?,
        configJSONData: Data?
    ) -> String {
        guard let configJSONData else {
            return Self.pagedKVModelFamily(modelID)
        }
        if let family = Self.pagedKVConfigModelFamily(configJSONData) {
            return family
        }
        return "unknown"
    }

    private nonisolated static func pagedKVConfigModelFamily(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var labels: [String] = []
        if let modelType = object["model_type"] as? String { labels.append(modelType) }
        if let architectures = object["architectures"] as? [String] { labels.append(contentsOf: architectures) }

        let normalizedLabels = labels.map { label in
            label
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
        }
        if normalizedLabels.contains(where: { $0.contains("qwen") }) { return "qwen" }
        if normalizedLabels.contains(where: { $0.contains("llama") }) { return "llama" }
        if normalizedLabels.contains(where: { $0.contains("gptoss") }) { return "gpt_oss" }
        if normalizedLabels.contains(where: { $0.contains("gemma4") }) { return "gemma4" }
        if normalizedLabels.contains(where: { $0.contains("glm4moe") }) { return "glm4_moe" }
        if normalizedLabels.contains(where: { $0.contains("nemotronh") }) { return "nemotron_h" }
        // GLM-5-Next (`glm5_next`, text model `glm5_next_text`): the SPEC-039
        // v0.1.17 KDA/DSA hybrid family. Only the allowlisted identity carries
        // a verified layout; any other `glm5_next` artifact is a `mixed` cache
        // class without one and fails closed.
        if normalizedLabels.contains(where: { $0.contains("glm5next") }) { return "glm5_next" }
        return nil
    }

    nonisolated static func pagedKVModelCapabilities(
        modelID: String?,
        configJSONData: Data?
    ) -> PagedKVRuntimeModelCapabilities {
        // SPEC-039 FR-PKV12 mixed-layout exception allowlist. Each entry is an
        // exact (serving identity → required `config.json` architecture) pair
        // whose hybrid Mamba(recurrent)+KVCacheSimple(attention) topology has
        // been measured to pass the token-parity and batched row-isolation
        // gates on the packaged runtime. This stays an explicit per-identity
        // allowlist by design: the SPEC forbids expanding hybrid support by
        // family/architecture guesswork. That is not hypothetical here — the
        // listed Qwen3.x hybrids passed exact serial-vs-shared-forward parity
        // across the production 512-token prefill boundary, plus batched row
        // isolation and the campaign leftovers gates. The gpt-oss 120b entry is
        // the separately measured sliding-window/full-attention tuple proven in
        // #1780; it does not admit the 20b fixture or the gpt_oss family. Non-
        // hybrid Qwen models are admitted by the base `KVCacheSimple` allowlist.
        // Adding a future measured mixed identity is one entry here plus the
        // matching SPEC-039 line. The runtime parity/isolation probes still gate
        // every attach; this only lets a measured mixed tuple be evaluated
        // instead of rejected outright as an unproven `mixed` class.
        let hybridArchitectureAllowlist: [String: String] = [
            "openai/gpt-oss-120b": "GptOssForCausalLM",
            "qwen/qwen3.5-27b": "Qwen3_5ForConditionalGeneration",
            "qwen/qwen3.5-35b-a3b": "Qwen3_5MoeForConditionalGeneration",
            "qwen/qwen3.6-27b": "Qwen3_5ForConditionalGeneration",
            "qwen/qwen3.6-35b-a3b": "Qwen3_5MoeForConditionalGeneration",
            "qwen/qwen3.8-27b": "Qwen3_5ForConditionalGeneration",
            "zai-org/glm-5.3-flash": "Glm5NextForConditionalGeneration",
        ]
        let configObject = configJSONData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        // `glm5_next` keys on the exact `architectures` array and model types
        // and carries its verified per-layer layout (SPEC-039 FR-PKV12).
        let sparseAttention: PagedKVSparseAttentionLayout? = {
            guard let id = modelID?.lowercased(),
                  let expectedArchitecture = hybridArchitectureAllowlist[id],
                  expectedArchitecture == "Glm5NextForConditionalGeneration",
                  let configObject,
                  configObject["architectures"] as? [String] == [expectedArchitecture],
                  configObject["model_type"] as? String == "glm5_next",
                  let textConfig = configObject["text_config"] as? [String: Any],
                  textConfig["model_type"] as? String == "glm5_next_text"
            else { return nil }
            return PagedKVSparseAttentionLayout(textConfig: textConfig)
        }()
        let allowlistedArchitectureVerified: Bool = {
            guard let id = modelID?.lowercased(),
                  let expectedArchitecture = hybridArchitectureAllowlist[id],
                  let configObject,
                  let architectures = configObject["architectures"] as? [String]
            else { return false }
            if expectedArchitecture == "Glm5NextForConditionalGeneration" { return sparseAttention != nil }
            return architectures.contains(expectedArchitecture)
        }()
        let architectureVerified = allowlistedArchitectureVerified
            || qwen35HybridDecoderArchitectureVerified(
            modelID: modelID,
            configJSONData: configJSONData
        )
        return PagedKVRuntimeModelCapabilities(
            modelFamily: Self.pagedKVModelFamily(modelID: modelID, configJSONData: configJSONData),
            requiresMoEDispatch: (configJSONData.flatMap(Self.pagedKVConfigRequiresMoE) ?? false)
                || Self.pagedKVModelIDLooksLikeExpertModel(modelID),
            hybridDecoderArchitectureVerified: architectureVerified,
            sparseAttention: sparseAttention
        )
    }

    private nonisolated static func qwen35HybridDecoderArchitectureVerified(
        modelID: String?,
        configJSONData: Data?
    ) -> Bool {
        guard let normalizedModelID = modelID?.lowercased(),
              normalizedModelID == "mlx-community/qwen3.5-9b-4bit",
              let configJSONData,
              let object = try? JSONSerialization.jsonObject(with: configJSONData) as? [String: Any],
              let architectures = object["architectures"] as? [String],
              architectures == ["Qwen3_5ForConditionalGeneration"],
              let modelType = object["model_type"] as? String,
              modelType == "qwen3_5",
              let textConfig = object["text_config"] as? [String: Any],
              let textModelType = textConfig["model_type"] as? String,
              textModelType == "qwen3_5_text",
              let numHiddenLayers = textConfig["num_hidden_layers"] as? Int,
              numHiddenLayers > 0,
              let layerTypes = textConfig["layer_types"] as? [String],
              layerTypes.count == numHiddenLayers,
              layerTypes.contains("linear_attention"),
              layerTypes.contains("full_attention"),
              let fullAttentionInterval = textConfig["full_attention_interval"] as? Int,
              fullAttentionInterval > 0,
              let mtpHiddenLayers = textConfig["mtp_num_hidden_layers"] as? Int,
              mtpHiddenLayers > 0,
              textConfig["mtp_use_dedicated_embeddings"] is Bool
        else {
            return false
        }
        return layerTypes.enumerated().allSatisfy { index, layerType in
            if (index + 1).isMultiple(of: fullAttentionInterval) {
                return layerType == "full_attention"
            }
            return layerType == "linear_attention"
        }
    }

    nonisolated static func nativeMTPAdmissionCacheClass(
        runtimeCacheClass: String,
        modelCapabilities: PagedKVRuntimeModelCapabilities
    ) -> String? {
        if runtimeCacheClass == "KVCacheSimple" {
            return "paged_kv"
        }
        if runtimeCacheClass == "mixed",
           modelCapabilities.hybridDecoderArchitectureVerified {
            return "paged_kv"
        }
        return nil
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
        // Multimodal wrappers (e.g. `glm5_next`) keep the expert counts in
        // `text_config`.
        let scopes = [object] + ((object["text_config"] as? [String: Any]).map { [$0] } ?? [])
        return scopes.contains { scope in
            expertKeys.contains { key in
                if let value = scope[key] as? Int { return value > 1 }
                if let value = scope[key] as? NSNumber { return value.intValue > 1 }
                return false
            }
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
        speculativeCacheWrapValidated: Bool = false,
        maxContextTokensOverride: Int? = nil,
        kvBitsOverride: Int? = nil,
        pagedKVConfig: PagedKVConfig = .defaults(),
        prefillStepSize: Int = 512,
        maxBatch: Int = 1,
        continuousBatchingMode: ContinuousBatchingMode = .off,
        continuousBatchQueueLimit: Int? = nil,
        continuousBatchQueueWaitTimeoutMS: Int? = nil,
        continuousBatchPrefillTokensPerIteration: Int? = nil,
        continuousBatchingCachedTurns: Bool = false,
        continuousBatchingAcceptanceCoverage: ContinuousBatchingAcceptanceCoverage = .empty,
        continuousBatchingPolicyLoadResult: ContinuousBatchingPolicyLoadResult = ContinuousBatchingPolicyLoadResult(
            selection: .emptyOff,
            status: .absentFallback,
            policySHA256: nil,
            signerKeyID: nil
        ),
        continuousBatchingEmergencyOffOverride: Bool = false,
        continuousBatchingModeExplicitlyConfigured: Bool? = nil,
        continuousBatchingDurableReplayAuthorityAvailable: Bool = false,
        nativeMTPMode: NativeMTPMode = .off,
        nativeMTPCapability: NativeMTPCapability? = nil,
        nativeMTPSchedulerSupported: Bool = false,
        nativeMTPAdmissionSidecarPath: String? = nil,
        nativeMTPAdmissionArtifactRoot: String? = nil,
        nativeMTPAdmissionSignaturePath: String? = nil,
        nativeMTPTrustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring? = nil,
        nativeMTPRunningBuildIdentity: NativeMTPRunningBuildIdentity? = nil,
        nativeMTPRevokedTupleSHA256: Set<String>? = nil,
        nativeMTPResolvedArtifactAuthority: NativeMTPResolvedArtifactAuthority? = nil,
        nativeMTPSelfTestRunner: NativeMTPSelfTestRunner = .unavailable,
        testNativeMTPAdmissionObserver: (@Sendable (NativeMTPRuntimeAdmission) -> Void)? = nil,
        testNativeMTPAdmissionRequestObserver: (@Sendable (String?, NativeMTPRuntimeAdmission, Int) -> Void)? = nil,
        warmSwapEnabled: Bool = false,
        swapDrainTimeoutSeconds: Int = 30,
        catalogModelIDAlias: String? = nil,
        verifiedModelArtifactSHA256: String? = nil,
        verifiedModelLoadSHA256: String? = nil,
        verifiedModelCatalogRevision: String? = nil,
        targetAuthorities: [String: ModelRuntimeTargetAuthority] = [:],
        authorizedSwitchModelIDs: [String] = [],
        switchMaxContextByTarget: [String: Int] = [:],
        switchMaxBatchByTarget: [String: Int] = [:],
        switchContextProvenanceModelIDs: Set<String> = []
    ) async throws {
        let normalizedDraftModelID = Self.nonEmpty(draftModelID)
        let normalizedDraftModelLoadPath = Self.nonEmpty(draftModelLoadPath)
        self.modelID = modelID
        self.configuredModelLoadPath = Self.nonEmpty(modelLoadPath)
        self.catalogModelIDAlias = catalogModelIDAlias
        self.currentModelID = modelID
        self.currentDraftModelID = nil
        self.currentDraftTargetModelID = nil
        self.currentDraftContainer = nil
        self.currentNativeMTPDrafterContainer = nil
        self.currentNativeMTPCapability = nil
        self.currentNativeMTPAdmissionCapability = nil
        self.currentNativeMTPTupleOffer = nil
        self.currentNativeMTPSelfTestInput = nil
        self.currentNativeVisionProfile = nil
        self.configuredDraftModelID = normalizedDraftModelID
        self.configuredDraftModelLoadPath = normalizedDraftModelLoadPath
        self.configuredNativeMTPAdmissionSidecarPath = Self.nonEmpty(nativeMTPAdmissionSidecarPath)
        self.configuredNativeMTPAdmissionArtifactRoot = Self.nonEmpty(nativeMTPAdmissionArtifactRoot)
        self.configuredNativeMTPAdmissionSignaturePath = Self.nonEmpty(nativeMTPAdmissionSignaturePath)
        self.configuredNativeMTPTrustedKeyring = nativeMTPTrustedKeyring ?? NativeMTPAdmissionSidecar.TrustedKeyring(
            publicKeysByKeyID: AutotuneStaticInputs.defaultTrustedPublicKeys,
            requiredKeyID: AutotuneStaticInputs.keyID
        )
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        self.configuredNativeMTPRunningBuildIdentity = nativeMTPRunningBuildIdentity
        #else
        self.configuredNativeMTPRunningBuildIdentity = nil
        #endif
        self.configuredNativeMTPRevokedTupleSHA256 = nativeMTPRevokedTupleSHA256
        self.configuredNativeMTPResolvedArtifactAuthority = nativeMTPResolvedArtifactAuthority
        self.nativeMTPSelfTestRunner = nativeMTPSelfTestRunner
        self.numDraftTokens = numDraftTokens
        self.speculativeCacheWrapValidated = speculativeCacheWrapValidated
        self.maxContextTokens = maxContextTokensOverride ?? Self.defaultMaxContextTokens()
        self.kvBitsOverride = kvBitsOverride
        self.prefillStepSize = max(1, prefillStepSize)
        self.pagedKVConfig = pagedKVConfig
        self.pagedKVRuntimeCacheClass = Self.pagedKVUnavailableCacheClass
        self.pagedKVObservedRuntimeIdentity = nil
        self.pagedKVHardwareSizingProof = nil
        self.pagedKVSchedulerBackendInstalled = false
        self.currentPagedKVModelCapabilities = Self.pagedKVModelCapabilities(modelID: modelID, configJSONData: nil)
        self.continuousBatchScheduler = nil
        self.testContinuousBatchingBackend = nil
        self.nativeMTPMode = nativeMTPMode
        self.nativeMTPCapability = nativeMTPCapability
        self.nativeMTPSchedulerSupported = nativeMTPSchedulerSupported
        do {
            self.nativeMTPRequestShapeCapture = try NativeMTPRequestShapeCaptureConfig
                .fromEnvironment()
                .map {
                    try NativeMTPRequestShapeCapture(
                        config: $0,
                        nativeMTPMode: nativeMTPMode,
                        runningBuildIdentity: Self.nativeMTPRunningBuildIdentity()
                    )
                }
        } catch {
            fputs("event=native_mtp_request_shape_capture outcome=disabled reason=\(error)\n", stderr)
            self.nativeMTPRequestShapeCapture = nil
        }
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        self.testNativeMTPAdmissionObserver = testNativeMTPAdmissionObserver
        self.testNativeMTPAdmissionRequestObserver = testNativeMTPAdmissionRequestObserver
        #else
        self.testNativeMTPAdmissionObserver = nil
        self.testNativeMTPAdmissionRequestObserver = nil
        #endif
        self.pagedKVRuntimeProber = .live
        self.continuousBatchReplayAuthority = ContinuousBatchRuntimeReplayAuthority()
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
        self.maxBatchBeforePolicyCeiling = boundedMaxBatch
        self.inferenceGate = AsyncSemaphore(value: boundedMaxBatch)
        self.servedSlotLimit = boundedMaxBatch
        self.blockingInferenceExecutor = BlockingInferenceExecutor(label: "live.malibu.provider.inference")
        self.continuousBatchingMode = continuousBatchingMode
        self.continuousBatchQueueLimit = continuousBatchQueueLimit
        self.continuousBatchQueueWaitTimeoutMS = continuousBatchQueueWaitTimeoutMS
        self.continuousBatchPrefillTokensPerIteration = continuousBatchPrefillTokensPerIteration
        self.continuousBatchingCachedTurns = continuousBatchingCachedTurns
        self.continuousBatchingAcceptanceCoverage = continuousBatchingAcceptanceCoverage
        self.continuousBatchingPolicyLoadResult = continuousBatchingPolicyLoadResult
        self.continuousBatchingModeExplicitlyConfigured = continuousBatchingModeExplicitlyConfigured
            ?? (continuousBatchingMode != .off)
        self.continuousBatchingEmergencyOffOverride = continuousBatchingEmergencyOffOverride
        self.continuousBatchingDurableReplayAuthorityAvailable = false
        self.warmSwapEnabled = warmSwapEnabled
        self.swapDrainTimeoutSeconds = swapDrainTimeoutSeconds
        self.verifiedCatalogArtifactSHA256 = verifiedModelArtifactSHA256
        self.verifiedModelCatalogRevision = verifiedModelCatalogRevision
        self.targetAuthorities = targetAuthorities
        self.targetTemplateSupportsThinkingToggleByArtifactSHA256 = Self.thinkingToggleCapabilities(
            for: targetAuthorities
        )
        self.targetTemplateSupportsPreserveThinkingByArtifactSHA256 = Self.preserveThinkingCapabilities(
            for: targetAuthorities
        )
        self.authorizedSwitchModelIDs = authorizedSwitchModelIDs
        self.switchMaxContextByTarget = switchMaxContextByTarget
        self.switchMaxBatchByTarget = switchMaxBatchByTarget
        self.switchContextProvenanceModelIDs = Set(switchContextProvenanceModelIDs.map { $0.lowercased() })
        self.configuredMaxContextTokens = maxContextTokensOverride
        // #2016: a catalog-bound provider serves the vision model under its
        // rate-card key; the catalog model id selects the profile only with the
        // verified catalog artifact binding.
        let verifiedCatalogModelID = verifiedModelArtifactSHA256 == nil ? nil : catalogModelIDAlias
        let nativeVisionSelected = NativeVisionProfile.selectionModelID(
            servedModelID: modelID, configuredModelID: modelID, verifiedCatalogModelID: verifiedCatalogModelID
        ) != nil
        self.loader = { targetModelID in
            let (container, directory) = try await Self.loadLocalContainer(
                from: targetModelID,
                nativeVision: NativeVisionProfile.selectionModelID(
                    servedModelID: targetModelID, configuredModelID: modelID,
                    verifiedCatalogModelID: verifiedCatalogModelID
                ) != nil)
            let modelHash = try? ModelArtifactVerifier.canonicalArtifactHash(directory: directory)
            return (container, targetModelID, modelHash)
        }
        self.testLoader = nil
        self.testCompletion = nil
        self.testStreamChunks = []
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
            self.currentNativeVisionProfile = nil
            if normalizedDraftModelID != nil {
                throw SpecDecodeStartupError.targetRequired
            }
            return
        }

        let targetLoadPath = modelLoadPath ?? modelID
        let candidateNativeMTPLoad: NativeMTPRuntimeLoadResult?
        let candidateNativeMTPDisabledReason: NativeMTPStatusReason
        if normalizedDraftModelID == nil,
           !nativeVisionSelected,
           let verifiedModelArtifactSHA256,
           self.nativeMTPMode == .auto {
            if let targetDirectory = try? Self.localModelDirectory(for: targetLoadPath) {
                let rejectionRecorder = NativeMTPServePathRejectionRecorder()
                candidateNativeMTPLoad = await Self.loadNativeMTPDrafterIfAdmitted(
                    mode: self.nativeMTPMode,
                    targetModelID: modelID,
                    targetModelRevision: verifiedModelArtifactSHA256,
                    targetDirectory: targetDirectory,
                    maxContextTokens: self.maxContextTokens,
                    kvBitsOverride: self.kvBitsOverride,
                    prefillStepSize: self.prefillStepSize,
                    slotCount: self.maxBatch,
                    sidecarPath: self.configuredNativeMTPAdmissionSidecarPath,
                    artifactRoot: self.configuredNativeMTPAdmissionArtifactRoot,
                    signaturePath: self.configuredNativeMTPAdmissionSignaturePath,
                    trustedKeyring: self.configuredNativeMTPTrustedKeyring,
                    runningBuildIdentity: self.configuredNativeMTPRunningBuildIdentity,
                    revokedTupleSHA256: self.configuredNativeMTPRevokedTupleSHA256,
                    resolvedArtifactAuthority: self.configuredNativeMTPResolvedArtifactAuthority,
                    targetGeneration: UInt64(max(1, self.currentSpecDecodeGeneration + 1)),
                    selfTestRunner: self.nativeMTPSelfTestRunner,
                    rejectionObserver: rejectionRecorder.record
                )
                candidateNativeMTPDisabledReason = rejectionRecorder.statusReason ?? .tupleNotAdmitted
            } else {
                candidateNativeMTPLoad = Self.rejectNativeMTPServePath(
                    reasonCode: "target_directory_unavailable",
                    artifactRole: "target"
                )
                candidateNativeMTPDisabledReason = .tupleNotAdmitted
            }
        } else {
            candidateNativeMTPLoad = nil
            candidateNativeMTPDisabledReason = .tupleNotAdmitted
        }

        let container: ModelContainer
        let directory: URL
        let runtimeCacheClass: String
        let modelCapabilities: PagedKVRuntimeModelCapabilities
        if let candidateNativeMTPLoad {
            container = candidateNativeMTPLoad.targetContainer
            directory = candidateNativeMTPLoad.targetDirectory
            runtimeCacheClass = candidateNativeMTPLoad.runtimeCacheClass
            modelCapabilities = candidateNativeMTPLoad.modelCapabilities
        } else {
            let loaded = try await Self.loadLocalContainer(
                from: targetLoadPath,
                nativeVision: nativeVisionSelected
            )
            container = loaded.0
            directory = loaded.1
            let pagedKVSkipReason = Self.pagedKVSkipReason(
                config: self.pagedKVConfig, nativeVision: nativeVisionSelected)
            Self.logPagedKVSkip(pagedKVSkipReason)
            runtimeCacheClass = self.pagedKVConfig.effectiveEnabled && pagedKVSkipReason == nil
                ? await Self.pagedKVRuntimeCacheClass(
                    container: container,
                    maxContextTokens: self.maxContextTokens,
                    kvBitsOverride: self.kvBitsOverride,
                    prefillStepSize: self.prefillStepSize
                )
                : Self.pagedKVUnavailableCacheClass
            modelCapabilities = Self.pagedKVModelCapabilities(modelID: modelID, directory: directory)
        }
        if let expectedArtifactHash = verifiedModelLoadSHA256 ?? verifiedModelArtifactSHA256 {
            try Self.verifyLoadedArtifact(directory: directory, expectedSHA256: expectedArtifactHash)
        }
        self.currentContainer = container
        self.residentWeightsTicket = await Self.startResidentWeightsTicket(
            modelFamily: modelCapabilities.modelFamily)

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
        self.currentNativeVisionProfile = try NativeVisionProfile.load(
            modelID: NativeVisionProfile.selectionModelID(
                servedModelID: modelID, configuredModelID: modelID, verifiedCatalogModelID: verifiedCatalogModelID
            ),
            directory: directory,
            artifactSHA256: self.currentModelHash
        )
        self.configuredTemplateSupportsThinkingToggle = Self.chatTemplateSupportsThinkingToggle(in: directory)
        self.currentTemplateSupportsThinkingToggle = self.configuredTemplateSupportsThinkingToggle
        self.configuredTemplateSupportsPreserveThinking = self.configuredTemplateSupportsThinkingToggle
            && Self.chatTemplateSupportsPreserveThinking(in: directory)
        self.currentTemplateSupportsPreserveThinking = self.configuredTemplateSupportsPreserveThinking
        self.pagedKVRuntimeCacheClass = runtimeCacheClass
        self.currentPagedKVModelCapabilities = modelCapabilities
        let (parityProbe, moeProbe) = await self.computePagedKVRuntimeProbes(
            container: container,
            modelID: modelID,
            modelCapabilities: modelCapabilities,
            runtimeCacheClass: runtimeCacheClass
        )
        if let measurement = Self.measurePagedKVRuntime(
            config: self.pagedKVConfig,
            modelID: modelID,
            modelSHA256: self.currentModelHash,
            tokenizerSHA256: tokenizerHashes.config,
            chatTemplateSHA256: tokenizerHashes.template,
            modelCapabilities: modelCapabilities,
            parityProbe: parityProbe,
            moeProbe: moeProbe
        ) {
            self.pagedKVObservedRuntimeIdentity = measurement.observedRuntimeIdentity
            self.pagedKVHardwareSizingProof = measurement.hardwareSizingProof
        }
        let candidateSchedulerBackendInstalled = self.pagedKVObservedRuntimeIdentity != nil
            && self.pagedKVHardwareSizingProof != nil
        self.pagedKVAttachDecision = Self.pagedKVRuntimeCapabilityDecision(
            config: self.pagedKVConfig,
            modelID: modelID,
            modelHash: self.currentModelHash,
            tokenizerSHA256: tokenizerHashes.config,
            chatTemplateSHA256: tokenizerHashes.template,
            kvBitsOverride: self.kvBitsOverride,
            runtimeCacheClass: runtimeCacheClass,
            modelCapabilities: modelCapabilities,
            observedRuntimeIdentity: self.pagedKVObservedRuntimeIdentity,
            hardwareSizingProof: self.pagedKVHardwareSizingProof,
            schedulerBackendInstalled: candidateSchedulerBackendInstalled
        )
        if case .attached = self.pagedKVAttachDecision {
            self.pagedKVSchedulerBackendInstalled = true
        }
        if let nativeMTPLoad = candidateNativeMTPLoad {
            self.currentNativeMTPDrafterContainer = nativeMTPLoad.drafterContainer
            self.currentNativeMTPAdmissionCapability = nativeMTPLoad.admissionCapability
            self.currentNativeMTPCapability = nil
            self.currentNativeMTPTupleOffer = nil
            self.parkedNativeMTPTuple = nil
            self.currentNativeMTPSelfTestInput = nativeMTPLoad.selfTestInput
        } else {
            self.currentNativeMTPDrafterContainer = nil
            self.currentNativeMTPAdmissionCapability = nil
            self.currentNativeMTPCapability = nil
            self.currentNativeMTPTupleOffer = nil
            self.parkedNativeMTPTuple = nil
            self.currentNativeMTPSelfTestInput = nil
        }
        publishNativeMTPStatusSink(
            capability: nil,
            admissionCapability: nil,
            reasonIfDisabled: candidateNativeMTPDisabledReason
        )
        self.continuousBatchScheduler = await Self.makeContinuousBatchScheduler(
            decision: self.pagedKVAttachDecision,
            tuple: self.continuousBatchingRequestedTuple(),
            container: container,
            nativeMTPDrafterContainer: self.currentNativeMTPDrafterContainer,
            nativeMTPAdmissionCapability: self.currentNativeMTPAdmissionCapability,
            backendOverride: self.testContinuousBatchingBackend,
            maxBatch: self.maxBatch,
            queueLimit: self.continuousBatchQueueLimit,
            queueWaitTimeoutMS: self.continuousBatchQueueWaitTimeoutMS,
            prefillTokensPerIteration: self.continuousBatchPrefillTokensPerIteration,
            maxContextTokens: self.maxContextTokens,
            modelID: modelID,
            modelSHA256: self.currentModelHash,
            weightsGeneration: self.currentSpecDecodeGeneration,
            kvBitsOverride: self.kvBitsOverride,
            prefillStepSize: self.prefillStepSize,
            nativeMTPStatusSink: self.currentNativeMTPStatusSink,
            replayAuthority: self.continuousBatchReplayAuthority,
            cachedTurns: self.continuousBatchingCachedTurns
        )
        if self.continuousBatchScheduler == nil {
            self.pagedKVSchedulerBackendInstalled = false
            self.pagedKVAttachDecision = Self.pagedKVRuntimeCapabilityDecision(
                config: self.pagedKVConfig,
                modelID: modelID,
                modelHash: self.currentModelHash,
                tokenizerSHA256: tokenizerHashes.config,
                chatTemplateSHA256: tokenizerHashes.template,
                kvBitsOverride: self.kvBitsOverride,
                runtimeCacheClass: runtimeCacheClass,
                modelCapabilities: modelCapabilities,
                observedRuntimeIdentity: self.pagedKVObservedRuntimeIdentity,
                hardwareSizingProof: self.pagedKVHardwareSizingProof,
                schedulerBackendInstalled: false
            )
        }
        self.continuousBatchingDurableReplayAuthorityAvailable =
            self.continuousBatchScheduler != nil && self.continuousBatchReplayAuthority.durableAvailable
        if let nativeMTPLoad = candidateNativeMTPLoad {
            let selfTestReceipt: NativeMTPSelfTestReceipt?
            if let scheduler = self.continuousBatchScheduler {
                do {
                    // SPEC-048-R016 (v0.1.32): qualify native MTP on this Mac.
                    // MTP-on greedy output must equal ordinary decode on the same
                    // paged engine, and MTP must beat it by the R015 decode bar.
                    // A pre-signed token digest from another runtime revision is
                    // not the reference.
                    var receipt: NativeMTPSelfTestReceipt?
                    var mtpSeconds = Double.infinity
                    for attempt in 0..<NativeMTPOnDeviceSelfCheck.repetitions {
                        // Distinct request ids: a repeated id would replay the
                        // scheduler's retained result instead of running.
                        let start = Date()
                        receipt = try await self.executeNativeMTPSelfTest(
                            nativeMTPLoad.selfTestInput,
                            scheduler: scheduler,
                            capability: nativeMTPLoad.capability,
                            servedSnapshotID: nativeMTPLoad.servedSnapshotID,
                            attempt: attempt
                        )
                        mtpSeconds = min(mtpSeconds, Date().timeIntervalSince(start))
                    }
                    let ordinary = try await self.executeNativeMTPOrdinaryReference(
                        nativeMTPLoad.selfTestInput,
                        scheduler: scheduler
                    )
                    let verdict = NativeMTPOnDeviceSelfCheck.decide(
                        mtpTokens: receipt?.generatedTokenIDs ?? [],
                        mtpSeconds: mtpSeconds,
                        ordinaryTokens: ordinary.tokens,
                        ordinarySeconds: ordinary.seconds
                    )
                    FileHandle.standardError.write(Data(
                        "event=native_mtp_self_check result=\(verdict.reason) speedup=\(String(format: "%.2f", verdict.speedup)) tokens=\(ordinary.tokens.count)\n".utf8
                    ))
                    if let receipt, verdict.passed, receipt.actualDecodePath == .nativeMTP, !receipt.fallbackUsed {
                        selfTestReceipt = receipt
                    } else {
                        selfTestReceipt = Self.rejectNativeMTPSelfTest(reasonCode: "selftest_\(verdict.reason)")
                    }
                } catch {
                    FileHandle.standardError.write(Data(
                        "event=native_mtp_self_check result=execution_failed error=\(String(describing: error))\n".utf8
                    ))
                    selfTestReceipt = Self.rejectNativeMTPSelfTest(reasonCode: "selftest_execution_failed")
                }
            } else {
                selfTestReceipt = Self.rejectNativeMTPSelfTest(reasonCode: "selftest_scheduler_unavailable")
            }
            if let receipt = selfTestReceipt {
                self.currentNativeMTPCapability = nativeMTPLoad.capability
                self.currentNativeMTPAdmissionCapability = nativeMTPLoad.admissionCapability
                self.currentNativeMTPDrafterContainer = nativeMTPLoad.drafterContainer
                self.currentNativeMTPSelfTestInput = nativeMTPLoad.selfTestInput
                self.currentNativeMTPTupleOffer = Self.nativeMTPTupleOffer(
                    load: nativeMTPLoad,
                    receipt: receipt
                )
                startNativeMTPRevocationRefresh(load: nativeMTPLoad)
                publishNativeMTPStatusSink(
                    capability: nativeMTPLoad.capability,
                    admissionCapability: nativeMTPLoad.admissionCapability,
                    reasonIfDisabled: .tupleNotAdmitted
                )
            } else {
                stopNativeMTPRevocationRefresh()
                self.currentNativeMTPDrafterContainer = nil
                self.currentNativeMTPAdmissionCapability = nil
                self.currentNativeMTPCapability = nil
                self.currentNativeMTPTupleOffer = nil
                self.currentNativeMTPSelfTestInput = nil
                publishNativeMTPStatusSink(
                    capability: nil,
                    admissionCapability: nil,
                    reasonIfDisabled: .tupleNotAdmitted
                )
            }
        }
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
        templateSupportsThinkingToggle: Bool = false,
        templateSupportsPreserveThinking: Bool = false,
        weightsManifestSHA256: String? = nil,
        draftModelID: String? = nil,
        numDraftTokens: Int = 3,
        speculativeCacheWrapValidated: Bool = false,
        maxContextTokensOverride: Int? = nil,
        kvBitsOverride: Int? = nil,
        pagedKVConfig: PagedKVConfig = .defaults(),
        prefillStepSize: Int = 512,
        maxBatch: Int = 1,
        continuousBatchingMode: ContinuousBatchingMode = .off,
        continuousBatchQueueLimit: Int? = nil,
        continuousBatchQueueWaitTimeoutMS: Int? = nil,
        continuousBatchPrefillTokensPerIteration: Int? = nil,
        continuousBatchingCachedTurns: Bool = false,
        // Test-only init: mirrors `ContinuousBatchRuntimeReplayAuthority
        // .inMemoryForTests` — coverage is unrestricted unless a test asserts
        // on the FR-CB10 gate itself.
        continuousBatchingAcceptanceCoverage: ContinuousBatchingAcceptanceCoverage = .unrestrictedForTests,
        continuousBatchingPolicyLoadResult: ContinuousBatchingPolicyLoadResult = ContinuousBatchingPolicyLoadResult(
            selection: .emptyOff,
            status: .absentFallback,
            policySHA256: nil,
            signerKeyID: nil
        ),
        continuousBatchingEmergencyOffOverride: Bool = false,
        continuousBatchingModeExplicitlyConfigured: Bool? = nil,
        continuousBatchingDurableReplayAuthorityAvailable: Bool = false,
        nativeMTPMode: NativeMTPMode = .off,
        nativeMTPCapability: NativeMTPCapability? = nil,
        nativeMTPSchedulerSupported: Bool = false,
        nativeMTPAdmissionSidecarPath: String? = nil,
        nativeMTPAdmissionArtifactRoot: String? = nil,
        nativeMTPAdmissionSignaturePath: String? = nil,
        nativeMTPTrustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring? = nil,
        nativeMTPRunningBuildIdentity: NativeMTPRunningBuildIdentity? = nil,
        nativeMTPRevokedTupleSHA256: Set<String>? = nil,
        nativeMTPResolvedArtifactAuthority: NativeMTPResolvedArtifactAuthority? = nil,
        nativeMTPDrafterContainer: MTPDrafterContainer? = nil,
        labNativeMTPAdmissionCapability: NativeMTPAdmissionCapability? = nil,
        nativeMTPSelfTestRunner: NativeMTPSelfTestRunner = .unavailable,
        testNativeMTPAdmissionObserver: (@Sendable (NativeMTPRuntimeAdmission) -> Void)? = nil,
        testNativeMTPAdmissionRequestObserver: (@Sendable (String?, NativeMTPRuntimeAdmission, Int) -> Void)? = nil,
        warmSwapEnabled: Bool,
        swapDrainTimeoutSeconds: Int = 30,
        providerStatus: ProviderStatus? = nil,
        catalogModelIDAlias: String? = nil,
        targetAuthorities: [String: ModelRuntimeTargetAuthority] = [:],
        authorizedSwitchModelIDs: [String] = [],
        switchMaxContextByTarget: [String: Int] = [:],
        switchMaxBatchByTarget: [String: Int] = [:],
        switchContextProvenanceModelIDs: Set<String> = [],
        pagedKVObservedRuntimeIdentity: PagedKVObservedRuntimeIdentity? = nil,
        pagedKVHardwareSizingProof: PagedKVHardwareSizingProof? = nil,
        pagedKVRuntimeCacheClass: String = ModelRuntime.pagedKVUnavailableCacheClass,
        pagedKVSchedulerBackendInstalled: Bool = false,
        pagedKVModelCapabilities: PagedKVRuntimeModelCapabilities? = nil,
        container: ModelContainer? = nil,
        continuousBatchingBackend: (any ContinuousBatchSchedulerBackend)? = nil,
        continuousBatchPrefillGrouping: ContinuousBatchPrefillGroupingRule? = nil,
        pagedKVRuntimeProber: PagedKVRuntimeProber = .live,
        loader: @escaping @Sendable (String) async throws -> (ModelContainer, String, String?),
        testLoader: (@Sendable (String) async throws -> (String, String?))? = nil,
        testCompletion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)? = nil,
        testStreamChunks: [StreamChunk] = [],
        testNativeVisionProfile: NativeVisionProfile? = nil,
        testSpeculativeCompletion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)? = nil,
        testSpeculativeStream: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)? = nil
    ) {
        let normalizedDraftModelID = Self.nonEmpty(draftModelID)
        let replayAuthority = ContinuousBatchRuntimeReplayAuthority.inMemoryForTests(
            durableAvailable: continuousBatchingDurableReplayAuthorityAvailable
        )
        self.modelID = modelID
        self.configuredModelLoadPath = nil
        self.catalogModelIDAlias = catalogModelIDAlias
        self.currentModelID = modelID
        self.currentContainer = container
        self.currentDraftModelID = normalizedDraftModelID
        self.currentDraftTargetModelID = normalizedDraftModelID == nil ? nil : modelID
        self.currentDraftContainer = nil
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        self.currentNativeMTPDrafterContainer = nativeMTPDrafterContainer
        self.currentNativeMTPCapability = nativeMTPDrafterContainer == nil ? nil : nativeMTPCapability
        #else
        self.currentNativeMTPDrafterContainer = nil
        self.currentNativeMTPCapability = nil
        #endif
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        self.currentNativeMTPAdmissionCapability = nativeMTPDrafterContainer == nil
            ? nil
            : labNativeMTPAdmissionCapability
        self.nativeMTPStatusResetGeneration = self.currentNativeMTPAdmissionCapability == nil ? 0 : 1
        self.currentNativeMTPStatusSink = Self.nativeMTPStatusSink(
            capability: self.currentNativeMTPCapability,
            admissionCapability: self.currentNativeMTPAdmissionCapability,
            mode: nativeMTPMode,
            resetGeneration: self.nativeMTPStatusResetGeneration
        )
        #else
        self.currentNativeMTPAdmissionCapability = nil
        #endif
        self.currentNativeMTPTupleOffer = nil
        self.currentNativeMTPSelfTestInput = nil
        self.configuredDraftModelID = normalizedDraftModelID
        self.configuredDraftModelLoadPath = nil
        self.configuredNativeMTPAdmissionSidecarPath = Self.nonEmpty(nativeMTPAdmissionSidecarPath)
        self.configuredNativeMTPAdmissionArtifactRoot = Self.nonEmpty(nativeMTPAdmissionArtifactRoot)
        self.configuredNativeMTPAdmissionSignaturePath = Self.nonEmpty(nativeMTPAdmissionSignaturePath)
        self.configuredNativeMTPTrustedKeyring = nativeMTPTrustedKeyring
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        self.configuredNativeMTPRunningBuildIdentity = nativeMTPRunningBuildIdentity
        #else
        self.configuredNativeMTPRunningBuildIdentity = nil
        #endif
        self.configuredNativeMTPRevokedTupleSHA256 = nativeMTPRevokedTupleSHA256
        self.configuredNativeMTPResolvedArtifactAuthority = nativeMTPResolvedArtifactAuthority
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        self.nativeMTPSelfTestRunner = nativeMTPSelfTestRunner
        #else
        self.nativeMTPSelfTestRunner = .unavailable
        #endif
        self.numDraftTokens = numDraftTokens
        self.speculativeCacheWrapValidated = speculativeCacheWrapValidated
        self.currentModelHash = modelHash
        self.currentModelHashAlgorithm = modelHashAlgorithm
        self.currentWeightsManifestSHA256 = weightsManifestSHA256
        self.currentTokenizerConfigSHA256 = nil
        self.currentChatTemplateSHA256 = nil
        self.configuredTemplateSupportsThinkingToggle = templateSupportsThinkingToggle
        self.currentTemplateSupportsThinkingToggle = templateSupportsThinkingToggle
        self.configuredTemplateSupportsPreserveThinking = templateSupportsThinkingToggle
            && templateSupportsPreserveThinking
        self.currentTemplateSupportsPreserveThinking = self.configuredTemplateSupportsPreserveThinking
        self.verifiedCatalogArtifactSHA256 = nil
        self.verifiedModelCatalogRevision = nil
        self.targetAuthorities = targetAuthorities
        self.targetTemplateSupportsThinkingToggleByArtifactSHA256 = Self.thinkingToggleCapabilities(
            for: targetAuthorities
        )
        self.targetTemplateSupportsPreserveThinkingByArtifactSHA256 = Self.preserveThinkingCapabilities(
            for: targetAuthorities
        )
        self.authorizedSwitchModelIDs = authorizedSwitchModelIDs
        self.switchMaxContextByTarget = switchMaxContextByTarget
        self.switchMaxBatchByTarget = switchMaxBatchByTarget
        self.switchContextProvenanceModelIDs = Set(switchContextProvenanceModelIDs.map { $0.lowercased() })
        self.configuredMaxContextTokens = maxContextTokensOverride
        self.stopTokenFilter = StopTokenFilter(tokens: [])
        self.maxContextTokens = maxContextTokensOverride ?? Self.defaultMaxContextTokens()
        self.kvBitsOverride = kvBitsOverride
        self.prefillStepSize = max(1, prefillStepSize)
        self.pagedKVConfig = pagedKVConfig
        self.pagedKVRuntimeCacheClass = pagedKVRuntimeCacheClass
        // Defense-in-depth (mirrors the prober fence): only DEBUG/test builds may inject
        // prebuilt paged-KV attach evidence. A release provider ignores caller-supplied
        // identity/proof/backend flags and can only attach from real on-device measurement,
        // so this test initializer can never become a self-authored-evidence bypass.
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        let effectiveObservedIdentity = pagedKVObservedRuntimeIdentity
        let effectiveSizingProof = pagedKVHardwareSizingProof
        let effectiveBackendInstalled = pagedKVSchedulerBackendInstalled
        #else
        let effectiveObservedIdentity: PagedKVObservedRuntimeIdentity? = nil
        let effectiveSizingProof: PagedKVHardwareSizingProof? = nil
        let effectiveBackendInstalled = false
        #endif
        self.pagedKVObservedRuntimeIdentity = effectiveObservedIdentity
        self.pagedKVHardwareSizingProof = effectiveSizingProof
        self.pagedKVSchedulerBackendInstalled = effectiveBackendInstalled
        self.testContinuousBatchingBackend = continuousBatchingBackend
        self.nativeMTPMode = nativeMTPMode
        self.nativeMTPCapability = nativeMTPCapability
        self.nativeMTPSchedulerSupported = nativeMTPSchedulerSupported
        self.nativeMTPRequestShapeCapture = nil
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        self.testNativeMTPAdmissionObserver = testNativeMTPAdmissionObserver
        self.testNativeMTPAdmissionRequestObserver = testNativeMTPAdmissionRequestObserver
        #else
        self.testNativeMTPAdmissionObserver = nil
        self.testNativeMTPAdmissionRequestObserver = nil
        #endif
        // Defense-in-depth: only DEBUG/test builds may inject a non-`.live` prober. A
        // release provider always re-derives evidence via the real on-device `.live`
        // probes, so an injected prober can never revive the "self-authored" attach path.
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        self.pagedKVRuntimeProber = pagedKVRuntimeProber
        #else
        self.pagedKVRuntimeProber = .live
        #endif
        self.continuousBatchReplayAuthority = replayAuthority
        let boundedMaxBatch = min(max(1, maxBatch), ProviderCapacity.maxConcurrencyOverrideLimit)
        let resolvedPagedKVModelCapabilities = pagedKVModelCapabilities
            ?? Self.pagedKVModelCapabilities(modelID: modelID, configJSONData: nil)
        self.currentPagedKVModelCapabilities = resolvedPagedKVModelCapabilities
        self.pagedKVAttachDecision = Self.pagedKVRuntimeCapabilityDecision(
            config: pagedKVConfig,
            modelID: modelID,
            modelHash: modelHash,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            kvBitsOverride: kvBitsOverride,
            runtimeCacheClass: pagedKVRuntimeCacheClass,
            modelCapabilities: resolvedPagedKVModelCapabilities,
            observedRuntimeIdentity: effectiveObservedIdentity,
            hardwareSizingProof: effectiveSizingProof,
            schedulerBackendInstalled: effectiveBackendInstalled
        )
        let requestedTuple = Self.continuousBatchingRequestedTuple(
            decision: self.pagedKVAttachDecision,
            modelID: modelID,
            modelSHA256: modelHash,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            kvBitsOverride: kvBitsOverride,
            runtimeCacheClass: pagedKVRuntimeCacheClass,
            modelCapabilities: resolvedPagedKVModelCapabilities,
            observedRuntimeIdentity: effectiveObservedIdentity
        )
        self.continuousBatchScheduler = nil
        self.conversationCache = ConversationCache()
        self.maxBatch = boundedMaxBatch
        self.maxBatchBeforePolicyCeiling = boundedMaxBatch
        self.inferenceGate = AsyncSemaphore(value: boundedMaxBatch)
        self.servedSlotLimit = boundedMaxBatch
        self.blockingInferenceExecutor = BlockingInferenceExecutor(label: "live.malibu.provider.inference")
        self.continuousBatchingMode = continuousBatchingMode
        self.continuousBatchQueueLimit = continuousBatchQueueLimit
        self.continuousBatchQueueWaitTimeoutMS = continuousBatchQueueWaitTimeoutMS
        self.continuousBatchPrefillTokensPerIteration = continuousBatchPrefillTokensPerIteration
        self.continuousBatchingCachedTurns = continuousBatchingCachedTurns
        self.continuousBatchingAcceptanceCoverage = continuousBatchingAcceptanceCoverage
        self.continuousBatchingPolicyLoadResult = continuousBatchingPolicyLoadResult
        self.continuousBatchingModeExplicitlyConfigured = continuousBatchingModeExplicitlyConfigured
            ?? (continuousBatchingMode != .off)
        self.continuousBatchingEmergencyOffOverride = continuousBatchingEmergencyOffOverride
        self.continuousBatchingDurableReplayAuthorityAvailable = false
        self.warmSwapEnabled = warmSwapEnabled
        self.swapDrainTimeoutSeconds = swapDrainTimeoutSeconds
        self.providerStatus = providerStatus
        self.loader = loader
        self.testLoader = testLoader
        self.testCompletion = testCompletion
        self.testStreamChunks = testStreamChunks
        self.currentNativeVisionProfile = testNativeVisionProfile
        self.testSpeculativeCompletion = testSpeculativeCompletion
        self.testSpeculativeStream = testSpeculativeStream
        let continuousBatchScheduler = Self.makeContinuousBatchScheduler(
            decision: self.pagedKVAttachDecision,
            tuple: requestedTuple,
            backend: continuousBatchingBackend,
            maxBatch: boundedMaxBatch,
            queueLimit: continuousBatchQueueLimit,
            queueWaitTimeoutMS: continuousBatchQueueWaitTimeoutMS,
            prefillTokensPerIteration: continuousBatchPrefillTokensPerIteration,
            maxContextTokens: self.maxContextTokens,
            modelID: modelID,
            modelSHA256: modelHash,
            weightsGeneration: self.currentSpecDecodeGeneration,
            prefillStepSize: self.prefillStepSize,
            nativeMTPRoundByteCapacity: Self.nativeMTPRoundByteCapacity(
                from: self.currentNativeMTPAdmissionCapability
            ),
            nativeMTPStatusSink: self.currentNativeMTPStatusSink,
            // A backend over a real model must name its rule; unnamed, it
            // fails safe to prefilling every chunk alone.
            prefillGrouping: continuousBatchPrefillGrouping
                ?? (container == nil ? .unconstrained : .ungrouped),
            maxDecodeRowsPerForward: container == nil ? Int.max : Self.continuousBatchDecodeRowBound(),
            replayAuthority: replayAuthority
        )
        self.continuousBatchScheduler = continuousBatchScheduler
        self.continuousBatchingDurableReplayAuthorityAvailable =
            continuousBatchScheduler != nil && replayAuthority.durableAvailable
    }

    func setProviderStatus(_ providerStatus: ProviderStatus) {
        self.providerStatus = providerStatus
    }

    func authorizedSwitchModelIDList() -> [String] {
        authorizedSwitchModelIDs
    }

    func currentSnapshot() async -> RuntimeSnapshot {
        let capability = continuousBatchingCapability(draftConfigured: currentDraftModelID != nil)
        let effectiveMode = effectiveContinuousBatchingMode()
        let schedulerMetrics = await continuousBatchScheduler?.metrics()
        let policySnapshot = continuousBatchingPolicySnapshot()
        let decisionLabel: String
        switch pagedKVAttachDecision {
        case .disabled: decisionLabel = "disabled"
        case .attached: decisionLabel = "attached"
        case .fallback(let reason): decisionLabel = "fallback_\(reason.rawValue)"
        case .rejected(let reason): decisionLabel = "rejected_\(reason.rawValue)"
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
            templateSupportsThinkingToggle: currentTemplateSupportsThinkingToggle,
            templateSupportsPreserveThinking: currentTemplateSupportsPreserveThinking,
            specDecodeGeneration: currentSpecDecodeGeneration,
            continuousBatching: RuntimeContinuousBatchingSnapshot(
                mode: effectiveMode,
                active: effectiveMode != .off
                    && capability.unsupportedReason == nil
                    && continuousBatchScheduler != nil,
                unsupportedReason: capability.unsupportedReason?.rawValue,
                pagedKVDecision: decisionLabel,
                cacheClass: pagedKVRuntimeCacheClass,
                policy: policySnapshot,
                scheduler: schedulerMetrics.map {
                    RuntimeContinuousBatchingSchedulerSnapshot(
                        activeDecodeRows: $0.activeDecodeRows,
                        waitingCount: $0.waitingCount,
                        maxObservedBatchDepth: $0.maxObservedBatchDepth,
                        slotsTotal: $0.slotsTotal,
                        slotsFree: $0.slotsFree,
                        sharedForwardCalls: $0.sharedForwardCalls
                    )
                },
                selfCheck: continuousBatchingSelfCheckReport
            ),
            nativeMTPStatus: currentNativeMTPStatusSink.snapshot(),
            nativeMTPCapability: currentNativeMTPCapability,
            schedulerSupportsNativeMTP: currentServedSchedulerSupportsNativeMTP(),
            nativeMTPTupleOffer: currentNativeMTPTupleOffer,
            nativeVisionProfile: currentNativeVisionProfile
        )
    }

    private func continuousBatchingPolicySnapshot() -> RuntimeContinuousBatchingPolicySnapshot {
        let loadResult = continuousBatchingPolicyLoadResult
        let selection = loadResult.selection
        let policyLive = loadResult.status == .liveVerified
        let requestedTuple = continuousBatchingRequestedTuple()
        // The entry's provider CLI version and CDHash are recorded provenance
        // only; the decode-path tuple alone authorizes the signed entry.
        let matchingEntry = requestedTuple.flatMap { tuple in
            selection.entries.first { entry in
                ContinuousBatchingAcceptanceCoverage(acceptedTuples: [entry.tuple]).covers(tuple)
            }
        }
        let descriptorAdmitted = requestedTuple.map { tuple in
            pagedKVAttachDecision.descriptor?.admits(
                modelID: tuple.modelID,
                modelSHA256: tuple.modelSHA256,
                tokenizerSHA256: tuple.tokenizerSHA256,
                chatTemplateSHA256: tuple.chatTemplateSHA256,
                cacheClass: tuple.cacheClass,
                kvDType: tuple.kvDType,
                requiresMoE: tuple.requiresMoE,
                hardwareClass: tuple.hardwareClass,
                metallibSHA256: tuple.metallibSHA256,
                kernelIdentifier: tuple.kernelIdentifier,
                parityLabel: tuple.parityLabel,
                poolEpoch: tuple.poolEpoch
            ) == true
        } ?? false
        let localProofResult: String
        switch pagedKVAttachDecision {
        case .attached where descriptorAdmitted:
            localProofResult = "passed"
        case .disabled:
            localProofResult = "not_run"
        case .fallback, .rejected, .attached:
            localProofResult = "failed"
        }
        let signedPolicyAuthorized = policyLive
            && matchingEntry != nil
            && !continuousBatchingEmergencyOffOverride
        let locallyAuthorized = signedPolicyAuthorized && descriptorAdmitted
        let decisionReason: String
        if continuousBatchingEmergencyOffOverride {
            decisionReason = "emergency_off"
        } else if let requestedTuple, continuousBatchingAcceptanceCoverage.isRevoked(requestedTuple) {
            decisionReason = "revoked"
        } else if case .granted(let slots) = continuousBatchingSelfCheck {
            decisionReason = "self_check_granted_\(slots)"
        } else if case .refused(let reason) = continuousBatchingSelfCheck {
            decisionReason = "self_check_refused_\(reason)"
        } else if loadResult.status != .liveVerified {
            decisionReason = loadResult.status.rawValue
        } else if requestedTuple == nil {
            decisionReason = "local_identity_unavailable"
        } else if matchingEntry == nil {
            decisionReason = "tuple_identity_mismatch"
        } else if !descriptorAdmitted {
            decisionReason = "authorized_local_proof_failed"
        } else {
            decisionReason = "authorized"
        }
        let expiresAt = loadResult.status == .liveVerified
            ? ISO8601DateFormatter.string(
                from: selection.expiresAt,
                timeZone: TimeZone(secondsFromGMT: 0)!,
                formatOptions: [.withInternetDateTime]
            )
            : nil
        return RuntimeContinuousBatchingPolicySnapshot(
            authorizationSource: selection.source,
            loadStatus: loadResult.status.rawValue,
            releaseID: loadResult.status == .liveVerified ? selection.releaseID : nil,
            policyVersion: loadResult.status == .liveVerified ? selection.policyVersion : nil,
            signerKeyID: loadResult.signerKeyID,
            policySHA256: loadResult.policySHA256,
            expiresAt: expiresAt,
            rolloutMode: matchingEntry?.rollout.rawValue ?? ContinuousBatchingMode.off.rawValue,
            tupleSHA256: matchingEntry?.tupleSHA256,
            authorized: signedPolicyAuthorized,
            cachedTurnsAuthorized: locallyAuthorized && matchingEntry?.tuple.cachedTurnsAccepted == true,
            emergencyOffOverride: continuousBatchingEmergencyOffOverride,
            localProofResult: localProofResult,
            decisionReason: decisionReason
        )
    }

    private func requestStartSnapshot() -> RuntimeSnapshot {
        let schedulerSupportsNativeMTP = currentServedSchedulerSupportsNativeMTP()
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
                templateSupportsThinkingToggle: currentTemplateSupportsThinkingToggle,
                templateSupportsPreserveThinking: currentTemplateSupportsPreserveThinking,
                specDecodeGeneration: currentSpecDecodeGeneration,
                nativeMTPStatus: currentNativeMTPStatusSink.snapshot(),
                nativeMTPCapability: currentNativeMTPCapability,
                schedulerSupportsNativeMTP: schedulerSupportsNativeMTP,
                nativeMTPTupleOffer: currentNativeMTPTupleOffer,
                nativeVisionProfile: currentNativeVisionProfile
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
            templateSupportsThinkingToggle: currentTemplateSupportsThinkingToggle,
            templateSupportsPreserveThinking: currentTemplateSupportsPreserveThinking,
            specDecodeGeneration: currentSpecDecodeGeneration,
            nativeMTPStatus: currentNativeMTPStatusSink.snapshot(),
            nativeMTPCapability: currentNativeMTPCapability,
            schedulerSupportsNativeMTP: schedulerSupportsNativeMTP,
            nativeMTPTupleOffer: currentNativeMTPTupleOffer,
            nativeVisionProfile: currentNativeVisionProfile
        )
    }

    private func currentServedSchedulerSupportsNativeMTP() -> Bool {
        currentNativeMTPDrafterContainer != nil && continuousBatchScheduler != nil
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

    func disableNativeMTPTuple(
        admissionTupleSHA256: String,
        servedSnapshotID: String,
        targetGeneration: UInt64,
        reason: NativeMTPStatusReason = .tupleRevoked
    ) async {
        guard let offer = currentNativeMTPTupleOffer,
              offer.nativeMTPAdmissionTupleSHA256 == admissionTupleSHA256,
              offer.servedSnapshotID == servedSnapshotID,
              offer.targetGeneration == targetGeneration else {
            // A tuple parked after `bank_mismatch` is fenced already; a
            // revocation or any other disable discards it (SPEC-048-R016).
            if let parked = parkedNativeMTPTuple,
               parked.offer.nativeMTPAdmissionTupleSHA256 == admissionTupleSHA256,
               parked.offer.servedSnapshotID == servedSnapshotID,
               parked.offer.targetGeneration == targetGeneration {
                await discardParkedNativeMTPTuple(reason: reason)
            }
            return
        }
        let specDecodeGeneration = currentSpecDecodeGeneration
        stopNativeMTPRevocationRefresh()
        let fence = NativeMTPTupleFence(
            admissionTupleSHA256: admissionTupleSHA256,
            servedSnapshotID: servedSnapshotID,
            targetGeneration: targetGeneration
        )
        await continuousBatchScheduler?.disableNativeMTPTuple(fence)
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        if let hook = nativeMTPTupleFenceHookForTest {
            await hook()
        }
        #endif
        // A load or swap that ran while the fence was applied owns the
        // runtime now: its tuple is not this one and must not be cleared.
        guard currentSpecDecodeGeneration == specDecodeGeneration,
              currentNativeMTPTupleOffer == offer else {
            return
        }
        currentNativeMTPCapability = nil
        currentNativeMTPAdmissionCapability = nil
        currentNativeMTPTupleOffer = nil
        currentNativeMTPSelfTestInput = nil
        currentNativeMTPDrafterContainer = nil
        parkedNativeMTPTuple = nil
        currentNativeMTPStatusSink.adopt(NativeMTPStatusSink.disabled(
            resetGeneration: UInt64(max(0, currentSpecDecodeGeneration)),
            reason: reason
        ))
    }

    private struct ParkedNativeMTPTuple {
        let offer: NativeMTPPublishedTupleOffer
        let capability: NativeMTPCapability?
        let admissionCapability: NativeMTPAdmissionCapability?
        let drafterContainer: MTPDrafterContainer?
        let selfTestInput: NativeMTPSelfTestInput?
        let revocationRefresh: NativeMTPRevocationRefreshInputs?
        let specDecodeGeneration: Int
    }

    /// SPEC-048-R016 (v0.1.48): a coordinator `bank_mismatch` fences the tuple
    /// like any disable (queued native rows fail, active rows finish
    /// ordinary), but keeps the qualified load so the provider can offer the
    /// same tuple again on a new session or a coordinator bank change. Returns
    /// whether the tuple was parked.
    @discardableResult
    func parkNativeMTPTupleForReoffer(
        admissionTupleSHA256: String,
        servedSnapshotID: String,
        targetGeneration: UInt64
    ) async -> Bool {
        guard let offer = currentNativeMTPTupleOffer,
              offer.nativeMTPAdmissionTupleSHA256 == admissionTupleSHA256,
              offer.servedSnapshotID == servedSnapshotID,
              offer.targetGeneration == targetGeneration else {
            return false
        }
        let parked = ParkedNativeMTPTuple(
            offer: offer,
            capability: currentNativeMTPCapability,
            admissionCapability: currentNativeMTPAdmissionCapability,
            drafterContainer: currentNativeMTPDrafterContainer,
            selfTestInput: currentNativeMTPSelfTestInput,
            revocationRefresh: currentNativeMTPRevocationRefresh,
            specDecodeGeneration: currentSpecDecodeGeneration
        )
        await disableNativeMTPTuple(
            admissionTupleSHA256: admissionTupleSHA256,
            servedSnapshotID: servedSnapshotID,
            targetGeneration: targetGeneration,
            reason: .tupleNotAdmitted
        )
        // A load or swap that ran while the fence was applied owns the
        // runtime now; the parked tuple belongs to the replaced one.
        guard currentSpecDecodeGeneration == parked.specDecodeGeneration,
              currentNativeMTPTupleOffer == nil else {
            return false
        }
        parkedNativeMTPTuple = parked
        // Parking never pauses revocation: the watcher keeps polling for the
        // parked tuple, and a feed naming it discards it (SPEC-048-R016).
        if let revocationRefresh = parked.revocationRefresh {
            startNativeMTPRevocationRefresh(revocationRefresh)
        }
        return true
    }

    /// Registers the coordinator client's hook for a parked tuple discarded
    /// by a revocation or another disable while it waited for a re-offer.
    func setNativeMTPParkedTupleDiscardHandler(_ handler: (@Sendable (NativeMTPPublishedTupleOffer) async -> Void)?) {
        nativeMTPParkedTupleDiscardHandler = handler
    }

    private func discardParkedNativeMTPTuple(reason: NativeMTPStatusReason) async {
        guard let parked = parkedNativeMTPTuple else { return }
        parkedNativeMTPTuple = nil
        stopNativeMTPRevocationRefresh()
        currentNativeMTPStatusSink.adopt(NativeMTPStatusSink.disabled(
            resetGeneration: UInt64(max(0, currentSpecDecodeGeneration)),
            reason: reason
        ))
        FileHandle.standardError.write(Data(
            "event=native_mtp_tuple_offer action=discarded reason=\(reason.rawValue) target_generation=\(parked.offer.targetGeneration)\n".utf8
        ))
        await nativeMTPParkedTupleDiscardHandler?(parked.offer)
    }

    /// Restores the parked tuple for a re-offer: lifts its scheduler fence and
    /// republishes the qualified capability, exactly the state a fresh load
    /// reaches after its self-check, with revocation polling resumed.
    ///
    /// The tuple stays parked (and so under its revocation watch) until the
    /// moment it is published: a revocation at any suspension below discards
    /// it and the restore then re-fences and gives up. The latest revocation
    /// state (network first, else the last-known verified feed,
    /// SPEC-048-R014) is read before the fence is lifted and again after, and
    /// publication follows the final identity and revocation check with no
    /// suspension in between. A revoked tuple is discarded; with no verified
    /// state at all the tuple stays parked and fenced (fail closed).
    func restoreParkedNativeMTPTuple(_ offer: NativeMTPPublishedTupleOffer) async -> NativeMTPTupleRestoreOutcome {
        guard nativeMTPRestoreInFlight == false,
              let parked = parkedNativeMTPTuple,
              parked.offer == offer,
              currentNativeMTPTupleOffer == nil,
              parked.specDecodeGeneration == currentSpecDecodeGeneration else {
            return .gone
        }
        guard let revocation = parked.revocationRefresh else {
            return .revocationUnavailable
        }
        nativeMTPRestoreInFlight = true
        defer { nativeMTPRestoreInFlight = false }
        let fence = NativeMTPTupleFence(
            admissionTupleSHA256: offer.nativeMTPAdmissionTupleSHA256,
            servedSnapshotID: offer.servedSnapshotID,
            targetGeneration: offer.targetGeneration
        )
        let firstCheck = await nativeMTPRestoreRevocationCheck(offer, revocation)
        guard firstCheck == .restored else { return firstCheck }

        await continuousBatchScheduler?.enableNativeMTPTuple(fence)
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        if let hook = nativeMTPTupleEnableHookForTest {
            await hook()
        }
        #endif
        // Final check after the fence was lifted: identity, then a fresh
        // verified revocation read. Nothing suspends between it and
        // publication, so a revocation lands either before (refused) or
        // after (the restarted watcher disables the published tuple).
        let finalCheck = await nativeMTPRestoreRevocationCheck(offer, revocation)
        guard finalCheck == .restored else {
            await continuousBatchScheduler?.disableNativeMTPTuple(fence)
            return finalCheck
        }
        parkedNativeMTPTuple = nil
        currentNativeMTPCapability = parked.capability
        currentNativeMTPAdmissionCapability = parked.admissionCapability
        currentNativeMTPDrafterContainer = parked.drafterContainer
        currentNativeMTPSelfTestInput = parked.selfTestInput
        currentNativeMTPTupleOffer = parked.offer
        startNativeMTPRevocationRefresh(revocation)
        publishNativeMTPStatusSink(
            capability: parked.capability,
            admissionCapability: parked.admissionCapability,
            reasonIfDisabled: .tupleNotAdmitted
        )
        return .restored
    }

    /// One restore-time check: reads the newest verified revocation state,
    /// then confirms the same tuple is still parked and nothing replaced it.
    /// `.restored` means "may proceed"; a revoked tuple is discarded.
    private func nativeMTPRestoreRevocationCheck(
        _ offer: NativeMTPPublishedTupleOffer,
        _ revocation: NativeMTPRevocationRefreshInputs
    ) async -> NativeMTPTupleRestoreOutcome {
        let revoked: Set<String>
        do {
            revoked = try await nativeMTPRevokedSetReader(revocation.signerKeyID, revocation.trustedKeyring)
        } catch {
            FileHandle.standardError.write(Data(
                "event=native_mtp_tuple_offer action=restore_refused reason=revocation_state_unavailable\n".utf8
            ))
            return .revocationUnavailable
        }
        // The read suspended: a load, swap or revocation may have run.
        guard let current = parkedNativeMTPTuple,
              current.offer == offer,
              currentNativeMTPTupleOffer == nil,
              current.specDecodeGeneration == currentSpecDecodeGeneration else {
            return .gone
        }
        if revoked.contains(revocation.tupleSHA256) {
            await discardParkedNativeMTPTuple(reason: .tupleRevoked)
            return .revoked
        }
        return .restored
    }

    struct NativeMTPRevocationRefreshInputs: Sendable {
        let signerKeyID: String
        let trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring
        let tupleSHA256: String
        let servedSnapshotID: String
        let targetGeneration: UInt64
    }

    private func startNativeMTPRevocationRefresh(load: NativeMTPRuntimeLoadResult) {
        stopNativeMTPRevocationRefresh()
        guard let signerKeyID = load.revocationSignerKeyID,
              let trustedKeyring = load.revocationTrustedKeyring else {
            return
        }
        startNativeMTPRevocationRefresh(NativeMTPRevocationRefreshInputs(
            signerKeyID: signerKeyID,
            trustedKeyring: trustedKeyring,
            tupleSHA256: load.admissionCapability.tupleSHA256,
            servedSnapshotID: load.servedSnapshotID,
            targetGeneration: load.selfTestInput.servedSnapshot?.generation ?? 0
        ))
    }

    private func startNativeMTPRevocationRefresh(_ inputs: NativeMTPRevocationRefreshInputs) {
        stopNativeMTPRevocationRefresh()
        currentNativeMTPRevocationRefresh = inputs
        let tupleSHA256 = inputs.tupleSHA256
        let servedSnapshotID = inputs.servedSnapshotID
        let targetGeneration = inputs.targetGeneration
        let poller = nativeMTPRevocationPoller
        // SPEC-048-R014 (v0.1.32): only a feed naming the tuple disables it.
        // A stale or unreachable feed revokes nothing; polling resumes. The
        // disable reaches a current tuple and a parked one alike.
        let onRevoked: @Sendable () async -> Void = { [weak self] in
            await self?.disableNativeMTPTuple(
                admissionTupleSHA256: tupleSHA256,
                servedSnapshotID: servedSnapshotID,
                targetGeneration: targetGeneration
            )
        }
        nativeMTPRevocationRefreshTask = Task {
            await poller(inputs, onRevoked)
        }
    }

    /// Polls the revocation feed for one tuple until it is revoked (calling
    /// `onRevoked` once) or the task is cancelled.
    typealias NativeMTPRevocationPoller = @Sendable (
        NativeMTPRevocationRefreshInputs,
        _ onRevoked: @escaping @Sendable () async -> Void
    ) async -> Void

    /// The revoked admission-tuple set of the newest verified feed: network
    /// first, else the last-known verified feed; throws when neither exists.
    typealias NativeMTPRevokedSetReader = @Sendable (
        _ signerKeyID: String,
        _ trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring
    ) async throws -> Set<String>

    static let liveNativeMTPRevocationPoller: NativeMTPRevocationPoller = { inputs, onRevoked in
        let verifier = NativeMTPRevocationEd25519Verifier(publicKeysByKeyID: inputs.trustedKeyring.publicKeysByKeyID)
        let store = KeychainNativeMTPRevocationStore.live()
        while !Task.isCancelled {
            let revoked = RevokedFlag()
            await NativeMTPRevocationFeedManager.pollWhileActive(
                pinnedSignerKeyID: inputs.signerKeyID,
                tupleSHA256: inputs.tupleSHA256,
                verifier: verifier,
                store: store
            ) { _ in
                revoked.set()
                await onRevoked()
            } onUnavailable: {
                FileHandle.standardError.write(Data(
                    "event=native_mtp_revocation_feed action=unavailable effect=none\n".utf8
                ))
            }
            if revoked.isSet || Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: UInt64(NativeMTPRevocationFeedManager.refreshIntervalSeconds * 1_000_000_000))
        }
    }

    static let liveNativeMTPRevokedSetReader: NativeMTPRevokedSetReader = { signerKeyID, trustedKeyring in
        let state = try await NativeMTPRevocationFeedManager.loadNetworkFirst(
            pinnedSignerKeyID: signerKeyID,
            verifier: NativeMTPRevocationEd25519Verifier(publicKeysByKeyID: trustedKeyring.publicKeysByKeyID),
            store: KeychainNativeMTPRevocationStore.live()
        )
        return state.feed.revokedSet
    }

    final class RevokedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func stopNativeMTPRevocationRefresh() {
        nativeMTPRevocationRefreshTask?.cancel()
        nativeMTPRevocationRefreshTask = nil
        currentNativeMTPRevocationRefresh = nil
    }

    private func executeNativeMTPSelfTest(
        _ input: NativeMTPSelfTestInput,
        scheduler: ContinuousBatchScheduler,
        capability: NativeMTPCapability,
        servedSnapshotID: String,
        attempt: Int = 0
    ) async throws -> NativeMTPSelfTestReceipt {
        guard let challenge = input.selectedChallenge,
              let servedSnapshot = input.servedSnapshot else {
            throw NativeMTPSelfTestError.failed("missing_challenge_record")
        }
        guard challenge.maxCompletionTokens <= 64 else {
            throw NativeMTPSelfTestError.failed("max_completion_tokens_exceeds_probe_bound")
        }
        let fence = NativeMTPTupleFence(
            admissionTupleSHA256: input.tupleSHA256,
            servedSnapshotID: servedSnapshotID,
            targetGeneration: servedSnapshot.generation
        )
        let schedulerResult = try await scheduler.submitNativeMTPIntegrityProbe(ContinuousBatchSchedulerRequest(
            id: "native-mtp-selftest-\(challenge.challengeID)-\(attempt)",
            conversationKey: "",
            promptTokens: challenge.promptTokenIDs,
            maxOutputTokens: challenge.maxCompletionTokens,
            samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: "native-mtp-selftest-\(challenge.challengeID)-\(attempt)"),
            temperature: 0,
            topP: 1,
            decodePath: .nativeMTP,
            nativeMTPMaximumProposalDepth: challenge.fixedProposalDepth,
            nativeMTPCompleteWindowBytesByDepth: capability.completeWindowBytesByDepth,
            nativeMTPTupleFence: fence,
            nativeMTPIntegrityProbe: true
        ))
        guard schedulerResult.retainedCache == nil,
              schedulerResult.serialConversationCache == nil else {
            throw NativeMTPSelfTestError.failed("selftest_retained_state")
        }
        let counters = schedulerResult.nativeMTPCounters ?? NativeMTPSelfTestCounters(
            acceptedTokens: 0,
            rejectedTokens: UInt64(clamping: challenge.fixedProposalDepth),
            bonusTokens: 0,
            committedTokens: UInt64(clamping: schedulerResult.generatedTokens.count)
        )
        let committedState = NativeMTPSelfTestDigest.committedStateDigest(
            promptTokenIDs: challenge.promptTokenIDs,
            generatedTokenIDs: schedulerResult.generatedTokens,
            acceptedTokens: Int(clamping: counters.acceptedTokens),
            rejectedTokens: Int(clamping: counters.rejectedTokens),
            bonusTokens: Int(clamping: counters.bonusTokens),
            committedTokens: Int(clamping: counters.committedTokens),
            terminalReason: schedulerResult.terminalStatus
        )
        return NativeMTPSelfTestReceipt(
            version: NativeMTPSelfTestRunner.capability,
            tupleSHA256: input.tupleSHA256,
            challengeID: challenge.challengeID,
            challengeBankSHA256: input.challengeBank.challengeBankSHA256,
            servedSnapshotGeneration: servedSnapshot.generation,
            proposalDepth: challenge.fixedProposalDepth,
            maxCompletionTokens: challenge.maxCompletionTokens,
            promptTokenIDs: challenge.promptTokenIDs,
            generatedTokenIDs: schedulerResult.generatedTokens,
            terminalReason: schedulerResult.terminalStatus,
            acceptedTokens: Int(clamping: counters.acceptedTokens),
            rejectedTokens: Int(clamping: counters.rejectedTokens),
            bonusTokens: Int(clamping: counters.bonusTokens),
            committedTokens: Int(clamping: counters.committedTokens),
            committedStateDigestSHA256: committedState,
            actualDecodePath: .nativeMTP,
            fallbackUsed: false
        )
    }

    /// The same challenge prompt on the ordinary decode path of the same
    /// scheduler: the reference the MTP self-check output must equal. Best of
    /// `NativeMTPOnDeviceSelfCheck.repetitions` timed runs.
    private func executeNativeMTPOrdinaryReference(
        _ input: NativeMTPSelfTestInput,
        scheduler: ContinuousBatchScheduler
    ) async throws -> (tokens: [Int], seconds: Double) {
        guard let challenge = input.selectedChallenge else {
            throw NativeMTPSelfTestError.failed("missing_challenge_record")
        }
        var tokens: [Int] = []
        var seconds = Double.infinity
        let runNonce = UUID().uuidString.lowercased()
        for attempt in 0..<NativeMTPOnDeviceSelfCheck.repetitions {
            let id = NativeMTPOnDeviceSelfCheck.ordinaryReferenceRequestID(
                challengeID: challenge.challengeID,
                runNonce: runNonce,
                attempt: attempt
            )
            let start = Date()
            let result = try await scheduler.submit(ContinuousBatchSchedulerRequest(
                id: id,
                conversationKey: "",
                promptTokens: challenge.promptTokenIDs,
                maxOutputTokens: challenge.maxCompletionTokens,
                samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: id),
                temperature: 0,
                topP: 1
            ))
            seconds = min(seconds, Date().timeIntervalSince(start))
            tokens = result.generatedTokens
        }
        return (tokens, seconds)
    }

    func runNativeMTPCanary(_ request: CoordinatorClient.NativeMTPCanaryRequestPayload) async -> CoordinatorClient.NativeMTPCanaryResultPayload {
        func result(
            actualTokens: [Int],
            terminal: ContinuousBatchSchedulerTerminalStatus,
            counters: CoordinatorClient.NativeMTPCanaryCountersPayload,
            committedState: String,
            decodePath: NativeMTPSelfTestExecutionResult.DecodePath,
            fallbackUsed: Bool,
            diagnostic: String?
        ) -> CoordinatorClient.NativeMTPCanaryResultPayload {
            let actualDigest = NativeMTPSelfTest.tokenDigest(actualTokens)
            let resultDigest = CoordinatorClient.nativeMTPCanaryResultDigest(
                requestID: request.requestID,
                providerID: request.providerID,
                assignedID: request.assignedID,
                requestDigest: request.requestDigest,
                targetGeneration: request.targetGeneration,
                providerRevision: request.providerRevision,
                runtimeRevision: request.runtimeRevision,
                challengeID: request.challengeID,
                challengeBankSHA256: request.challengeBankSHA256,
                nonce: request.nonce,
                nativeMTPRuntimeTupleSHA256: request.nativeMTPRuntimeTupleSHA256,
                expectedTokenIDSHA256: request.expectedTokenIDSHA256,
                actualTokenIDSHA256: actualDigest,
                terminalReason: terminal.rawValue,
                counters: counters,
                committedStateSHA256: committedState,
                actualDecodePath: decodePath.rawValue,
                fallbackUsed: fallbackUsed,
                runtimeTuple: request.runtimeTuple,
                diagnostic: diagnostic
            )
            return CoordinatorClient.NativeMTPCanaryResultPayload(
                requestID: request.requestID,
                providerID: request.providerID,
                assignedID: request.assignedID,
                requestDigest: request.requestDigest,
                resultDigest: resultDigest,
                targetGeneration: request.targetGeneration,
                providerRevision: request.providerRevision,
                runtimeRevision: request.runtimeRevision,
                challengeID: request.challengeID,
                challengeBankSHA256: request.challengeBankSHA256,
                nonce: request.nonce,
                nativeMTPRuntimeTupleSHA256: request.nativeMTPRuntimeTupleSHA256,
                expectedTokenIDSHA256: request.expectedTokenIDSHA256,
                actualTokenIDSHA256: actualDigest,
                terminalReason: terminal.rawValue,
                counters: counters,
                committedStateSHA256: committedState,
                actualDecodePath: decodePath.rawValue,
                fallbackUsed: fallbackUsed,
                runtimeTuple: request.runtimeTuple,
                diagnostic: diagnostic
            )
        }
        let zeroCounters = CoordinatorClient.NativeMTPCanaryCountersPayload(
            acceptedTokens: 0,
            rejectedTokens: 0,
            bonusTokens: 0,
            committedTokens: 0
        )
        let unavailableState = NativeMTPSelfTestDigest.committedStateDigest(
            promptTokenIDs: request.promptTokenIDs,
            generatedTokenIDs: [],
            acceptedTokens: 0,
            rejectedTokens: 0,
            bonusTokens: 0,
            committedTokens: 0,
            terminalReason: .requestFailed
        )
        guard let offer = currentNativeMTPTupleOffer,
              let selfTestInput = currentNativeMTPSelfTestInput,
              let selectedChallenge = selfTestInput.selectedChallenge,
              offer.nativeMTPAdmissionTupleSHA256 == request.nativeMTPAdmissionTupleSHA256,
              offer.servedSnapshotID == request.servedSnapshotID,
              offer.targetGeneration == request.targetGeneration,
              request.runtimeTuple == CoordinatorClient.NativeMTPRuntimeTuplePayload(
                offer.runtimeTuple,
                providerRevision: offer.providerRevision,
                runtimeRevision: offer.runtimeRevision
              ),
              request.challengeBankSHA256 == offer.challengeBankSHA256,
              request.challengeCorpusSHA256 == offer.challengeCorpusSHA256,
              request.challengeID == selectedChallenge.challengeID,
              request.promptTokenIDs == selectedChallenge.promptTokenIDs,
              request.proposalDepth == selectedChallenge.fixedProposalDepth,
              request.maxCompletionTokens == selectedChallenge.maxCompletionTokens,
              request.expectedTokenIDSHA256 == selectedChallenge.expectedTokenIDSHA256,
              request.expectedTerminalReason == selectedChallenge.expectedTerminalReason,
              request.expectedCounters == CoordinatorClient.NativeMTPCanaryCountersPayload(
                acceptedTokens: selectedChallenge.expectedCounters.acceptedTokens,
                rejectedTokens: selectedChallenge.expectedCounters.rejectedTokens,
                bonusTokens: selectedChallenge.expectedCounters.bonusTokens,
                committedTokens: selectedChallenge.expectedCounters.committedTokens
              ),
              request.expectedCommittedStateSHA256 == selectedChallenge.expectedCommittedStateDigest,
              request.nativeMTPRuntimeTupleSHA256 == (try? CoordinatorClient.nativeMTPRuntimeTupleSHA256(
                providerID: request.providerID,
                assignedID: request.assignedID,
                targetGeneration: offer.targetGeneration,
                nativeMTPAdmissionTupleSHA256: offer.nativeMTPAdmissionTupleSHA256,
                servedSnapshotID: offer.servedSnapshotID
              ))
        else {
            return result(
                actualTokens: [],
                terminal: .requestFailed,
                counters: zeroCounters,
                committedState: unavailableState,
                decodePath: .unavailable,
                fallbackUsed: false,
                diagnostic: "tuple_mismatch"
            )
        }
        guard let scheduler = continuousBatchScheduler,
              let capability = currentNativeMTPCapability,
              request.proposalDepth > 0,
              request.proposalDepth <= capability.maximumProposalDepth,
              request.maxCompletionTokens > 0,
              request.maxCompletionTokens <= min(64, capability.maximumCompletionTokens)
        else {
            return result(
                actualTokens: [],
                terminal: .requestFailed,
                counters: zeroCounters,
                committedState: unavailableState,
                decodePath: .unavailable,
                fallbackUsed: false,
                diagnostic: "capacity_unavailable"
            )
        }
        let fence = NativeMTPTupleFence(
            admissionTupleSHA256: offer.nativeMTPAdmissionTupleSHA256,
            servedSnapshotID: offer.servedSnapshotID,
            targetGeneration: offer.targetGeneration
        )
        do {
            let schedulerResult = try await scheduler.submitNativeMTPIntegrityProbe(ContinuousBatchSchedulerRequest(
                id: "native-mtp-canary-\(request.requestID)",
                conversationKey: "",
                promptTokens: request.promptTokenIDs,
                maxOutputTokens: request.maxCompletionTokens,
                samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: request.requestID),
                temperature: 0,
                topP: 1,
                decodePath: .nativeMTP,
                nativeMTPMaximumProposalDepth: request.proposalDepth,
                nativeMTPCompleteWindowBytesByDepth: capability.completeWindowBytesByDepth,
                nativeMTPTupleFence: fence,
                nativeMTPIntegrityProbe: true
            ))
            let actualCounters = schedulerResult.nativeMTPCounters ?? NativeMTPSelfTestCounters(
                acceptedTokens: 0,
                rejectedTokens: UInt64(request.proposalDepth),
                bonusTokens: 0,
                committedTokens: UInt64(max(0, schedulerResult.generatedTokens.count))
            )
            let counters = CoordinatorClient.NativeMTPCanaryCountersPayload(
                acceptedTokens: actualCounters.acceptedTokens,
                rejectedTokens: actualCounters.rejectedTokens,
                bonusTokens: actualCounters.bonusTokens,
                committedTokens: actualCounters.committedTokens
            )
            let committedState = NativeMTPSelfTestDigest.committedStateDigest(
                promptTokenIDs: request.promptTokenIDs,
                generatedTokenIDs: schedulerResult.generatedTokens,
                acceptedTokens: Int(counters.acceptedTokens),
                rejectedTokens: Int(counters.rejectedTokens),
                bonusTokens: Int(counters.bonusTokens),
                committedTokens: Int(counters.committedTokens),
                terminalReason: schedulerResult.terminalStatus
            )
            return result(
                actualTokens: schedulerResult.generatedTokens,
                terminal: schedulerResult.terminalStatus,
                counters: counters,
                committedState: committedState,
                decodePath: .nativeMTP,
                fallbackUsed: false,
                diagnostic: nil
            )
        } catch {
            return result(
                actualTokens: [],
                terminal: .requestFailed,
                counters: zeroCounters,
                committedState: unavailableState,
                decodePath: .unavailable,
                fallbackUsed: false,
                diagnostic: "capacity_unavailable"
            )
        }
    }

    /// #1689 FR-20b: the knobs a plain warm switch carries so a
    /// recommendation-generated context follows the served model, through the
    /// same knob path an adoption uses. KV bits stay as they are; slots follow
    /// the target's entry (SPEC-023-R018 item 9), else stay as they are.
    /// Nil keeps the current context (operator-owned, or no generated value).
    func switchKnobs(for targetModelID: String) -> ModelRuntimeAdoptionServeKnobs? {
        switchMaxContextByTarget[targetModelID.lowercased()].map {
            ModelRuntimeAdoptionServeKnobs(
                kvBits: kvBitsOverride,
                maxContext: $0,
                maxBatch: switchMaxBatchByTarget[targetModelID.lowercased()] ?? maxBatch,
                // The configured value only for the model its provenance record
                // names; an equal number recomputed for another model (e.g. a
                // draft-capped one) is still an adoption.
                contextSource: $0 == configuredMaxContextTokens
                    && switchContextProvenanceModelIDs.contains(targetModelID.lowercased())
                    ? .recommendationApply
                    : .recommendationAdoption
            )
        }
    }

    /// #1689 FR-20b: the context served now and its FR-17 source, exactly as
    /// `/v1/status` reports them. `models switch` describes the switch from
    /// this instead of recomputing it. Nil without a status owner.
    func servedContext() async -> (tokens: Int, source: MaxContextSource)? {
        guard let capacity = await providerStatus?.snapshot().capacity else { return nil }
        return (capacity.maxContextTokens, capacity.maxContextSource)
    }

    func beginSwap(
        targetModelID: String,
        adoptionKnobs: ModelRuntimeAdoptionServeKnobs? = nil,
        adoptionTransactionID: String? = nil,
        now: Date = Date()
    ) async throws -> Task<Void, Error> {
        guard warmSwapEnabled else { throw WarmSwapDisabledError() }
        pruneAdoptionTransactions(now: now)
        if let reservationID = preparedAdoptionReservationID {
            guard reservationID == adoptionTransactionID else {
                throw ModelRuntimeAdoptionError.adoptionReservationConflict
            }
        } else if adoptionTransactionID != nil {
            throw ModelRuntimeAdoptionError.transactionNotPrepared
        }
        let targetAuthority = targetAuthority(for: targetModelID)
        if testLoader == nil {
            guard targetAuthority != nil else {
                throw ModelRuntimeLoadError(target: targetModelID, reason: "signed catalog identity unavailable")
            }
        }
        try transitionToLoading(target: targetModelID)
        let drainTimeoutSeconds = swapDrainTimeoutSeconds
        let providerStatus = providerStatus
        let testLoader = testLoader
        let configuredDraftModelID = configuredDraftModelID
        let configuredDraftModelLoadPath = configuredDraftModelLoadPath
        let numDraftTokens = numDraftTokens
        let maxContextTokens = adoptionKnobs?.maxContext ?? maxContextTokens
        let kvBitsOverride = adoptionKnobs?.kvBits ?? kvBitsOverride
        let prefillStepSize = prefillStepSize
        return Task.detached { [weak self, testLoader, drainTimeoutSeconds, providerStatus, configuredDraftModelID, configuredDraftModelLoadPath, numDraftTokens, maxContextTokens, kvBitsOverride, prefillStepSize, targetAuthority, adoptionKnobs] in
            guard let self else { return }
            do {
                let container: ModelContainer?
                let modelID: String
                let modelHash: String?
                let modelHashAlgorithm: String?
                let weightsManifestSHA256: String?
                let tokenizerConfigSHA256: String?
                let chatTemplateSHA256: String?
                let nativeVisionProfile: NativeVisionProfile?
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
                    nativeVisionProfile = nil
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
                    guard let targetAuthority else {
                        throw ModelRuntimeLoadError(target: "signed catalog identity unavailable for \(targetModelID)")
                    }
                    let visionModelID = self.nativeVisionSelectionModelID(for: targetModelID)
                    let loaded = try await Self.loadLocalContainer(
                        from: targetAuthority.modelArgument,
                        nativeVision: visionModelID != nil
                    )
                    container = loaded.0
                    modelID = targetModelID
                    guard (try? ModelArtifactVerifier.canonicalArtifactHash(directory: loaded.1)) == targetAuthority.artifactSHA256
                    else {
                        throw ModelRuntimeLoadError(target: "signed catalog identity unavailable for \(targetModelID)")
                    }
                    modelHash = targetAuthority.artifactSHA256
                    modelHashAlgorithm = ModelArtifactIdentity.snapshotManifestV1
                    weightsManifestSHA256 = try? Self.modelWeightArtifactManifestHash(in: loaded.1)
                    let swapTokenizerHashes = Self.tokenizerIdentityHashes(in: loaded.1)
                    tokenizerConfigSHA256 = swapTokenizerHashes.config
                    chatTemplateSHA256 = swapTokenizerHashes.template
                    nativeVisionProfile = try NativeVisionProfile.load(
                        modelID: visionModelID, directory: loaded.1, artifactSHA256: modelHash)
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
                    nativeVisionProfile: nativeVisionProfile,
                    draftModelID: draftModelID,
                    draftContainer: draftContainer,
                    draftFailureReason: draftFailureReason,
                    modelCapabilities: modelCapabilities,
                    adoptionKnobs: adoptionKnobs
                )
            } catch {
                await self.failSwap(reason: String(describing: error))
            }
        }
    }

    func prepareModelAdoption(
        _ request: ModelAdoptionAuthorityWire,
        now: Date = Date()
    ) async -> ModelAdoptionPrepareResultWire {
        do {
            pruneAdoptionTransactions(now: now)
            if consumedAdoptionTransactionIDs[request.transactionID] != nil {
                throw ModelRuntimeAdoptionError.transactionConsumed
            }
            if let existing = preparedAdoptions[request.transactionID] {
                guard existing.request == request else {
                    throw ModelRuntimeAdoptionError.authorityMismatch
                }
                return acceptedModelAdoptionPreparation(existing)
            }
            guard preparedAdoptionReservationID == nil else {
                throw ModelRuntimeAdoptionError.adoptionReservationConflict
            }
            guard consumedAdoptionTransactionIDs.count < Self.maximumConsumedAdoptionTransactionIDs else {
                throw ModelRuntimeAdoptionError.runtimeRejected("model_adoption_replay_window_full")
            }
            guard state == .ready else {
                throw ModelRuntimeAdoptionError.runtimeRejected("runtime_not_ready")
            }
            let prepared = try validateModelAdoptionPreparation(request, now: now)
            preparedAdoptions[request.transactionID] = prepared
            preparedAdoptionReservationID = request.transactionID
            return acceptedModelAdoptionPreparation(prepared)
        } catch {
            return ModelAdoptionPrepareResultWire(
                transactionID: request.transactionID,
                accepted: false,
                reason: String(describing: error),
                targetModelID: nil,
                targetArtifactPath: nil,
                targetArtifactSHA256: nil,
                targetCatalogRevision: nil,
                serveKnobsSHA256: nil,
                catalogIdentitySHA256: nil
            )
        }
    }

    func beginPreparedModelAdoption(
        transactionID: String,
        now: Date = Date()
    ) async throws -> (ModelRuntimePreparedAdoption, Task<Void, Error>) {
        guard warmSwapEnabled else { throw WarmSwapDisabledError() }
        pruneAdoptionTransactions(now: now)
        guard consumedAdoptionTransactionIDs[transactionID] == nil,
              preparedAdoptionReservationID == transactionID,
              let prepared = preparedAdoptions[transactionID] else {
            throw ModelRuntimeAdoptionError.transactionNotPrepared
        }
        guard applyingAdoptionTransactionID == nil else {
            throw ModelRuntimeAdoptionError.transactionConsumed
        }
        guard currentModelID == prepared.request.expectedIncumbentModelID else {
            consumePreparedAdoption(transactionID: transactionID, now: now)
            throw ModelRuntimeAdoptionError.incumbentMismatch(
                expected: prepared.request.expectedIncumbentModelID,
                actual: currentModelID
            )
        }
        guard let runtimeAuthority = targetAuthority(for: prepared.request.targetModelID),
              runtimeAuthority == prepared.authority else {
            consumePreparedAdoption(transactionID: transactionID, now: now)
            throw ModelRuntimeAdoptionError.authorityMismatch
        }
        do {
            let active = ModelRuntimePreparedAdoption(
                request: prepared.request,
                authority: prepared.authority,
                expiresAt: now.addingTimeInterval(Self.activeAdoptionTransactionLifetime)
            )
            preparedAdoptions[transactionID] = active
            applyingAdoptionTransactionID = transactionID
            let task = try await beginSwap(
                targetModelID: prepared.request.targetModelID,
                adoptionKnobs: ModelRuntimeAdoptionServeKnobs(
                    kvBits: prepared.request.targetKVBits,
                    maxContext: prepared.request.targetMaxContext,
                    maxBatch: prepared.request.targetMaxBatch
                ),
                adoptionTransactionID: transactionID,
                now: now
            )
            return (active, task)
        } catch {
            consumePreparedAdoption(transactionID: transactionID, now: now)
            throw error
        }
    }

    func preparedModelAdoption(
        transactionID: String,
        now: Date = Date()
    ) -> ModelRuntimePreparedAdoption? {
        pruneAdoptionTransactions(now: now)
        return preparedAdoptions[transactionID]
    }

    func cancelPreparedModelAdoption(transactionID: String, now: Date = Date()) -> Bool {
        pruneAdoptionTransactions(now: now)
        if consumedAdoptionTransactionIDs[transactionID] != nil,
           finalizedAdoptionTransactionIDs[transactionID] == nil {
            return true
        }
        guard preparedAdoptions[transactionID] != nil || adoptionRecoveryClaims[transactionID] != nil else {
            return false
        }
        consumePreparedAdoption(transactionID: transactionID, now: now)
        return true
    }

    func claimModelAdoptionRecovery(
        transactionID: String,
        fromModelID: String,
        targetModelID: String,
        now: Date = Date()
    ) -> Bool {
        pruneAdoptionTransactions(now: now)
        guard UUID(uuidString: transactionID) != nil,
              !fromModelID.isEmpty,
              !targetModelID.isEmpty,
              fromModelID != targetModelID,
              state == .ready,
              currentModelID == fromModelID || currentModelID == targetModelID else {
            return false
        }
        if preparedAdoptionReservationID == transactionID {
            if let prepared = preparedAdoptions[transactionID] {
                guard prepared.request.expectedIncumbentModelID == fromModelID,
                      prepared.request.targetModelID == targetModelID else {
                    return false
                }
                preparedAdoptions[transactionID] = ModelRuntimePreparedAdoption(
                    request: prepared.request,
                    authority: prepared.authority,
                    expiresAt: now.addingTimeInterval(Self.activeAdoptionTransactionLifetime)
                )
                return true
            }
            if let claim = adoptionRecoveryClaims[transactionID] {
                guard claim.fromModelID == fromModelID,
                      claim.targetModelID == targetModelID else {
                    return false
                }
                adoptionRecoveryClaims[transactionID] = ModelRuntimeAdoptionRecoveryClaim(
                    transactionID: transactionID,
                    fromModelID: fromModelID,
                    targetModelID: targetModelID,
                    expiresAt: now.addingTimeInterval(Self.activeAdoptionTransactionLifetime)
                )
                return true
            }
            return false
        }
        guard preparedAdoptionReservationID == nil,
              consumedAdoptionTransactionIDs[transactionID] == nil,
              finalizedAdoptionTransactionIDs[transactionID] == nil else {
            return false
        }
        adoptionRecoveryClaims[transactionID] = ModelRuntimeAdoptionRecoveryClaim(
            transactionID: transactionID,
            fromModelID: fromModelID,
            targetModelID: targetModelID,
            expiresAt: now.addingTimeInterval(Self.activeAdoptionTransactionLifetime)
        )
        preparedAdoptionReservationID = transactionID
        return true
    }

    func finalizePreparedModelAdoption(transactionID: String, now: Date = Date()) -> Bool {
        pruneAdoptionTransactions(now: now)
        if finalizedAdoptionTransactionIDs[transactionID] != nil {
            return true
        }
        guard preparedAdoptionReservationID == transactionID,
              state == .ready else {
            return false
        }
        let expectedTarget: String?
        if applyingAdoptionTransactionID == transactionID,
           let prepared = preparedAdoptions[transactionID] {
            expectedTarget = prepared.request.targetModelID
        } else {
            expectedTarget = adoptionRecoveryClaims[transactionID]?.targetModelID
        }
        guard currentModelID == expectedTarget else { return false }
        consumePreparedAdoption(transactionID: transactionID, now: now)
        finalizedAdoptionTransactionIDs[transactionID] = now.addingTimeInterval(Self.adoptionTransactionLifetime)
        return true
    }

    private func acceptedModelAdoptionPreparation(
        _ prepared: ModelRuntimePreparedAdoption
    ) -> ModelAdoptionPrepareResultWire {
        let request = prepared.request
        return ModelAdoptionPrepareResultWire(
            transactionID: request.transactionID,
            accepted: true,
            reason: nil,
            targetModelID: request.targetModelID,
            targetArtifactPath: prepared.authority.modelArgument,
            targetArtifactSHA256: prepared.authority.artifactSHA256,
            targetCatalogRevision: prepared.authority.catalogRevision,
            serveKnobsSHA256: request.serveKnobsSHA256,
            catalogIdentitySHA256: request.catalogIdentitySHA256
        )
    }

    private func pruneAdoptionTransactions(now: Date) {
        let expired = preparedAdoptions.values
            .filter { $0.expiresAt < now }
            .map(\.request.transactionID)
        for transactionID in expired {
            consumePreparedAdoption(transactionID: transactionID, now: now)
        }
        let expiredClaims = adoptionRecoveryClaims.values
            .filter { $0.expiresAt < now }
            .map(\.transactionID)
        for transactionID in expiredClaims {
            consumePreparedAdoption(transactionID: transactionID, now: now)
        }
        consumedAdoptionTransactionIDs = consumedAdoptionTransactionIDs.filter { $0.value >= now }
        finalizedAdoptionTransactionIDs = finalizedAdoptionTransactionIDs.filter { $0.value >= now }
        if let reservationID = preparedAdoptionReservationID,
           preparedAdoptions[reservationID] == nil,
           adoptionRecoveryClaims[reservationID] == nil {
            preparedAdoptionReservationID = nil
        }
    }

    private func consumePreparedAdoption(transactionID: String, now: Date) {
        preparedAdoptions.removeValue(forKey: transactionID)
        adoptionRecoveryClaims.removeValue(forKey: transactionID)
        if preparedAdoptionReservationID == transactionID {
            preparedAdoptionReservationID = nil
        }
        if applyingAdoptionTransactionID == transactionID {
            applyingAdoptionTransactionID = nil
        }
        consumedAdoptionTransactionIDs[transactionID] = now.addingTimeInterval(Self.adoptionTransactionLifetime)
    }

    private func validateModelAdoptionPreparation(
        _ request: ModelAdoptionAuthorityWire,
        now: Date
    ) throws -> ModelRuntimePreparedAdoption {
        guard request.schemaVersion == "model_recommendation_apply_switch.v1" else {
            throw ModelRuntimeAdoptionError.invalidTransactionID
        }
        guard UUID(uuidString: request.transactionID) != nil else {
            throw ModelRuntimeAdoptionError.invalidTransactionID
        }
        guard Self.safeSHA256(request.recommendationSHA256) else {
            throw ModelRuntimeAdoptionError.invalidRecommendationSHA256
        }
        guard Self.safeSHA256(request.serveKnobsSHA256) else {
            throw ModelRuntimeAdoptionError.invalidServeKnobsSHA256
        }
        guard Self.safeSHA256(request.catalogIdentitySHA256) else {
            throw ModelRuntimeAdoptionError.invalidCatalogIdentitySHA256
        }
        guard request.targetMaxContext > 0,
              request.targetMaxBatch > 0,
              request.targetMaxBatch <= ProviderCapacity.maxConcurrencyOverrideLimit,
              request.targetKVBits == nil || request.targetKVBits! > 0,
              request.targetDonorMode == false,
              request.serveKnobsSHA256 == ModelAdoptionAuthorityWire.serveKnobsDigest(
                  kvBits: request.targetKVBits,
                  maxContext: request.targetMaxContext,
                  maxBatch: request.targetMaxBatch,
                  donorMode: request.targetDonorMode
              ) else {
            throw ModelRuntimeAdoptionError.authorityMismatch
        }
        guard currentModelID == request.expectedIncumbentModelID else {
            throw ModelRuntimeAdoptionError.incumbentMismatch(
                expected: request.expectedIncumbentModelID,
                actual: currentModelID
            )
        }
        if !authorizedSwitchModelIDs.isEmpty {
            let authorized = Set(authorizedSwitchModelIDs.map { $0.lowercased(with: nil) })
            guard authorized.contains(request.targetModelID.lowercased(with: nil)) else {
                throw ModelRuntimeAdoptionError.unsupportedTarget
            }
        }
        guard let authority = targetAuthority(for: request.targetModelID) else {
            throw ModelRuntimeAdoptionError.authorityUnavailable
        }
        guard authority.modelArgument == request.targetArtifactPath,
              authority.artifactSHA256 == request.targetArtifactSHA256,
              authority.catalogRevision == request.targetCatalogRevision else {
            throw ModelRuntimeAdoptionError.authorityMismatch
        }
        return ModelRuntimePreparedAdoption(
            request: request,
            authority: authority,
            expiresAt: now.addingTimeInterval(5 * 60)
        )
    }

    private nonisolated static func safeControlID(_ value: String) -> Bool {
        ModelSwitchingWireCodec.safeID(value)
    }

    private nonisolated static func safeSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (97...102).contains(scalar.value)
                || (65...70).contains(scalar.value)
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

    /// SPEC-038-R011 (v0.3.15): the served slot count is the serial-path
    /// gate; scheduler rows stay at `maxBatch`, the most any self-check may
    /// grant, and the relay admits at most the advertised slots. Never above
    /// `maxBatch`: the memory envelope and scheduler were sized for it. A
    /// request already holding a permit of the replaced gate releases it there.
    /// Every step after an await re-checks the swap generation, so a stale
    /// application never resizes the gate or caps a swapped-in scheduler.
    @discardableResult
    func applyServedSlots(_ slots: Int) async -> Bool {
        let generation = selfCheckGeneration
        let served = min(max(1, slots), maxBatch)
        let scheduler = continuousBatchScheduler
        servedSlotLimit = served
        await inferenceGate.resize(to: served, stamp: generation)
        guard selfCheckGeneration == generation else { return false }
        await scheduler?.setBuyerRowLimit(served)
        return selfCheckGeneration == generation
    }

    func configureServedSlots(
        managed: Bool,
        ownerPinned: Int?,
        resolver: (@Sendable (ContinuousBatchingSelfCheckTarget) -> ContinuousBatchingSelfCheckResolution?)? = nil,
        rowsBeforePolicyCeiling: Int? = nil
    ) {
        servedSlotsManaged = managed
        ownerPinnedServedSlots = ownerPinned
        servedSlotsResolver = resolver
        if let rowsBeforePolicyCeiling {
            maxBatchBeforePolicyCeiling = min(
                max(maxBatch, rowsBeforePolicyCeiling), ProviderCapacity.maxConcurrencyOverrideLimit
            )
        }
    }

    func maxBatchBeforePolicyCeilingForTest() -> Int {
        maxBatchBeforePolicyCeiling
    }

    func servedSlotLimitForTest() async -> Int {
        await inferenceGate.currentLimit()
    }

    /// The self-check subject for the loaded model, or nil when there is
    /// nothing to check: a decision already exists, batching cannot run here
    /// (emergency off, draft model, no attached scheduler), or a signed
    /// revocation names this model on this runtime revision.
    func continuousBatchingSelfCheckTarget(includeDecided: Bool = false) -> ContinuousBatchingSelfCheckTarget? {
        guard includeDecided || continuousBatchingSelfCheck == .pending,
              !continuousBatchingEmergencyOffOverride,
              currentDraftModelID == nil,
              let scheduler = continuousBatchScheduler,
              let tuple = continuousBatchingRequestedTuple(),
              !continuousBatchingAcceptanceCoverage.isRevoked(tuple)
        else { return nil }
        return ContinuousBatchingSelfCheckTarget(
            key: ContinuousBatchingSelfCheckKey(
                modelSHA256: tuple.modelSHA256,
                metallibSHA256: tuple.metallibSHA256,
                kernelIdentifier: tuple.kernelIdentifier,
                hardwareClass: tuple.hardwareClass,
                osBuild: ContinuousBatchingSelfCheckKey.currentOSBuild,
                runtimeBuild: Self.continuousBatchingSelfCheckRuntimeBuild(
                    forwardBound: PagedKVSharedForwardBackend.deviceVerifyTokenBound,
                    forwardTokenCap: scheduler.forwardTokenCap
                ),
                decodeWindow: scheduler.maxDecodeLockstepWindow
            ),
            maxRows: maxBatch,
            queueLimit: scheduler.queueLimit,
            generation: selfCheckGeneration,
            probeKeyBoundary: ContinuousBatchingSelfCheck.deviceRouteKeyBoundary,
            maxRequestTokens: scheduler.maxRequestTokens,
            poolTokens: scheduler.poolTokens,
            blockSizeTokens: scheduler.blockSizeTokens,
            // Only a pagedMLA (`glm5_next`) backend has a flattened-token cap.
            decodeOnlyGain: scheduler.forwardTokenCap != nil,
            policyCeiling: continuousBatchingPolicyServedSlotCeiling(modelSHA256: tuple.modelSHA256)
        )
    }

    /// Scheduler rows under a signed served-slot ceiling: never above it,
    /// never raised by it, at least one.
    nonisolated static func rowsUnderPolicyCeiling(rows: Int, ceiling: Int?) -> Int {
        max(1, min(rows, ceiling ?? .max))
    }

    /// SPEC-038 FR-CB11 (v0.3.22): the verified signed policy's
    /// `max_served_slots` for this model artifact, or nil.
    private func continuousBatchingPolicyServedSlotCeiling(modelSHA256: String?) -> Int? {
        guard continuousBatchingPolicyLoadResult.status == .liveVerified,
              let modelSHA256, !modelSHA256.isEmpty else { return nil }
        return continuousBatchingPolicyLoadResult.selection.servedSlotCeiling(modelSHA256: modelSHA256)
    }

    /// True when the loaded tuple can batch at all; false sends `serve` to one
    /// slot unless the owner pinned the count.
    func continuousBatchingCapableForServedSlots() -> Bool {
        guard !continuousBatchingEmergencyOffOverride,
              currentDraftModelID == nil,
              continuousBatchScheduler != nil,
              let tuple = continuousBatchingRequestedTuple()
        else { return false }
        return !continuousBatchingAcceptanceCoverage.isRevoked(tuple)
    }

    /// Applies a decision only while `expected` is still the loaded subject,
    /// so a result measured on one model never lands on a swapped-in one.
    /// With `expected`, the whole transaction (state, report, gates, buyer
    /// limit, advertised capacity) is fenced on the swap generation: it is
    /// dropped if a swap began before it or begins while it runs.
    @discardableResult
    func applyContinuousBatchingSelfCheck(
        _ state: ContinuousBatchingSelfCheckState,
        servedSlots: Int,
        expected: ContinuousBatchingSelfCheckTarget? = nil,
        report: ContinuousBatchingSelfCheckReport? = nil,
        publishCapacity: Bool = false
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let expected, continuousBatchingSelfCheckTarget(includeDecided: true) != expected {
            return false
        }
        let generation = selfCheckGeneration
        continuousBatchingSelfCheck = state
        if let report { continuousBatchingSelfCheckReport = report }
        guard await applyServedSlots(servedSlots), selfCheckGeneration == generation else { return false }
        if publishCapacity {
            await providerStatus?.updateServedSlots(min(max(1, servedSlots), maxBatch), stamp: generation)
        }
        return selfCheckGeneration == generation
    }

    func setContinuousBatchingSelfCheckReport(_ report: ContinuousBatchingSelfCheckReport?) {
        continuousBatchingSelfCheckReport = report
    }

    func continuousBatchingSelfCheckState() -> ContinuousBatchingSelfCheckState {
        continuousBatchingSelfCheck
    }

    /// Greedy prompts for the self-check, tokenized with the loaded chat
    /// template so rows look like buyer turns.
    func continuousBatchingSelfCheckPrompts(_ texts: [String]) async throws -> [[Int]] {
        try Task.checkCancellation()
        guard let container = currentContainer else {
            throw ContinuousBatchSchedulerError.requestFailed("self_check_model_unavailable")
        }
        let prompts = try await container.perform { context in
            var prompts: [[Int]] = []
            for text in texts {
                try Task.checkCancellation()
                let lmInput = try await context.processor.prepare(input: UserInput(chat: [.user(text)]))
                try Task.checkCancellation()
                prompts.append(lmInput.text.tokens.asArray(Int32.self).map(Int.init))
            }
            return prompts
        }
        try Task.checkCancellation()
        return prompts
    }

    /// SPEC-038 FR-CB10: whether a batched row's first divergence from the
    /// same prompt run alone is an exact tie
    /// (`ContinuousBatchingSelfCheck.divergenceVerdict` at
    /// `nearTieLogitTolerance`), against the stock serial logits of the
    /// shared prefix. Returns the logit margin between the two tokens for the
    /// evidence log.
    func continuousBatchingSelfCheckDivergence(
        prompt: [Int],
        sharedPrefix: [Int],
        aloneToken: Int,
        batchedToken: Int,
        otherRowsAloneTokens: [Int]
    ) async throws -> (nearTie: Bool, margin: Float?, reason: String) {
        try Task.checkCancellation()
        guard let container = currentContainer else { return (false, nil, "model_unavailable") }
        let reference = try await container.perform { context in
            try Task.checkCancellation()
            return try PagedKVRuntimeParityProbe.serialReference(model: context.model, prompt: prompt + sharedPrefix)
        }
        try Task.checkCancellation()
        return ContinuousBatchingSelfCheck.divergenceVerdict(
            reference: reference, aloneToken: aloneToken, batchedToken: batchedToken,
            otherRowsAloneTokens: otherRowsAloneTokens
        )
    }

    /// Runs `prompts` together on the attached scheduler at temperature 0 and
    /// returns each row's tokens and the wall time. Cancelling the calling
    /// task cancels every row. With `cohort`, the rows decode only once all
    /// of them are in decode (`ContinuousBatchSchedulerRequest
    /// .selfCheckCohort`), and each row's decode tokens generated beside the
    /// whole cohort, and the wall seconds of those decode steps, are returned
    /// (0 otherwise).
    func runContinuousBatchingSelfCheckBatch(
        prompts: [[Int]],
        maxOutputTokens: Int,
        idPrefix: String,
        cohort: Bool = false
    ) async throws -> ContinuousBatchingSelfCheckBatchRun {
        try Task.checkCancellation()
        guard let scheduler = continuousBatchScheduler else {
            throw ContinuousBatchSchedulerError.requestFailed("self_check_scheduler_unavailable")
        }
        let ids = prompts.indices.map { "\(idPrefix)-\($0)" }
        let start = Date()
        let outputs = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: (Int, [Int], Int, Double).self) { group in
                for (index, prompt) in prompts.enumerated() {
                    let id = ids[index]
                    group.addTask {
                        try Task.checkCancellation()
                        let result = try await scheduler.submit(ContinuousBatchSchedulerRequest(
                            id: id,
                            conversationKey: "",
                            promptTokens: prompt,
                            maxOutputTokens: maxOutputTokens,
                            samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: id),
                            temperature: 0,
                            topP: 1,
                            selfCheckProbe: true,
                            selfCheckCohort: cohort ? ContinuousBatchSelfCheckCohort(id: idPrefix, size: prompts.count) : nil
                        ))
                        try Self.validateContinuousBatchingSelfCheckTerminal(result.terminalStatus)
                        return (
                            index, result.generatedTokens, result.selfCheckCohortDecodeTokens ?? 0,
                            result.selfCheckCohortDecodeSeconds ?? 0
                        )
                    }
                }
                var rows = Array(repeating: [Int](), count: prompts.count)
                var cohortTokens = Array(repeating: 0, count: prompts.count)
                var cohortSeconds = Array(repeating: 0.0, count: prompts.count)
                for try await (index, tokens, decodeTokens, decodeSeconds) in group {
                    try Task.checkCancellation()
                    rows[index] = tokens
                    cohortTokens[index] = decodeTokens
                    cohortSeconds[index] = decodeSeconds
                }
                return (rows, cohortTokens, cohortSeconds)
            }
        } onCancel: {
            Task { for id in ids { await scheduler.cancel(requestID: id) } }
        }
        try Task.checkCancellation()
        return ContinuousBatchingSelfCheckBatchRun(
            outputs: outputs.0, seconds: Date().timeIntervalSince(start),
            cohortDecodeTokens: outputs.1, cohortDecodeSeconds: outputs.2
        )
    }

    /// Scheduler cancellation is a terminal result, not necessarily a thrown
    /// error. Never let its partial tokens become isolation or gain evidence.
    nonisolated static func validateContinuousBatchingSelfCheckTerminal(
        _ status: ContinuousBatchSchedulerTerminalStatus
    ) throws {
        try Task.checkCancellation()
        switch status {
        case .stop, .length: return
        case .cancelled: throw CancellationError()
        default: throw ContinuousBatchSchedulerError.requestFailed("self_check_\(status.rawValue)")
        }
    }

    func continuousBatchingCapabilityForTest() -> ContinuousBatchingCapability {
        continuousBatchingCapability(
            draftConfigured: currentDraftModelID != nil
        )
    }

    private func continuousBatchingCapability(
        draftConfigured: Bool,
        requestHasStableRequestID: Bool = true,
        requestStateRepresentable: Bool = true
    ) -> ContinuousBatchingCapability {
        let requestedTuple = continuousBatchingRequestedTuple()
        let effectiveMode = effectiveContinuousBatchingMode(requestedTuple: requestedTuple)
        let schedulerBackendAvailable = requestedTuple.map {
            continuousBatchScheduler != nil
                && pagedKVAttachDecision.descriptor?.admits(
                    modelID: $0.modelID,
                    modelSHA256: $0.modelSHA256,
                    tokenizerSHA256: $0.tokenizerSHA256,
                    chatTemplateSHA256: $0.chatTemplateSHA256,
                    cacheClass: $0.cacheClass,
                    kvDType: $0.kvDType,
                    requiresMoE: $0.requiresMoE,
                    hardwareClass: $0.hardwareClass,
                    metallibSHA256: $0.metallibSHA256,
                    kernelIdentifier: $0.kernelIdentifier,
                    parityLabel: $0.parityLabel,
                    poolEpoch: $0.poolEpoch
                ) == true
        } ?? false
        return ContinuousBatchingPolicy.capability(
            mode: effectiveMode,
            maxBatch: maxBatch,
            queueLimit: continuousBatchQueueLimit,
            kvBits: kvBitsOverride,
            draftConfigured: draftConfigured,
            requestHasStableRequestID: requestHasStableRequestID,
            requestStateRepresentable: requestStateRepresentable,
            schedulerBackendAvailable: schedulerBackendAvailable,
            durableReplayAuthorityAvailable: continuousBatchingDurableReplayAuthorityAvailable,
            pagedKVDecision: pagedKVAttachDecision,
            requestedTuple: requestedTuple,
            acceptanceCoverage: continuousBatchingAcceptanceCoverage
        )
    }

    private func effectiveContinuousBatchingMode(
        requestedTuple: ContinuousBatchingRequestedTuple? = nil
    ) -> ContinuousBatchingMode {
        if continuousBatchingEmergencyOffOverride { return .off }
        let tuple = requestedTuple ?? continuousBatchingRequestedTuple()
        if let tuple, continuousBatchingAcceptanceCoverage.isRevoked(tuple) { return .off }
        // SPEC-038 v0.3.15: a signed positive entry for this model artifact is
        // a provisional grant that keeps an already-enabled model batching
        // until this Mac's self-check decides; the self-check result rules.
        let provisionalMode = tuple.flatMap { requested in
            continuousBatchingPolicyLoadResult.selection.entries.first { entry in
                entry.tuple.modelID == requested.modelID && entry.tuple.modelSHA256 == requested.modelSHA256
            }?.rollout
        }
        let policyMode: ContinuousBatchingMode?
        switch continuousBatchingSelfCheck {
        case .granted:
            policyMode = provisionalMode ?? .canary
        case .refused:
            // This Mac measured the tuple and it did not qualify; an explicit
            // expert mode does not override that.
            return .off
        case .pending:
            // Production (default-on coverage) serves serially until the
            // self-check decides, unless a provisional grant applies.
            if continuousBatchingAcceptanceCoverage.isDefaultOn && provisionalMode == nil { return .off }
            policyMode = provisionalMode
        }
        guard let policyMode else {
            // An explicit expert/test mode retains the existing strict/canary
            // diagnostics, but it still cannot pass the signed coverage gate.
            return continuousBatchingModeExplicitlyConfigured ? continuousBatchingMode : .off
        }
        guard continuousBatchingModeExplicitlyConfigured else { return policyMode }
        switch (continuousBatchingMode, policyMode) {
        case (.off, _): return .off
        case (.canary, _), (.on, .canary): return .canary
        case (.on, .on): return .on
        case (_, .off): return .off
        }
    }

    private func continuousBatchingRequestedTuple() -> ContinuousBatchingRequestedTuple? {
        Self.continuousBatchingRequestedTuple(
            decision: pagedKVAttachDecision,
            modelID: currentModelID,
            modelSHA256: currentModelHash,
            tokenizerSHA256: currentTokenizerConfigSHA256,
            chatTemplateSHA256: currentChatTemplateSHA256,
            kvBitsOverride: kvBitsOverride,
            runtimeCacheClass: pagedKVRuntimeCacheClass,
            modelCapabilities: currentPagedKVModelCapabilities,
            observedRuntimeIdentity: pagedKVObservedRuntimeIdentity
        )
    }

    private nonisolated static func continuousBatchingRequestedTuple(
        decision: PagedKVAttachDecision,
        modelID: String?,
        modelSHA256: String?,
        tokenizerSHA256: String?,
        chatTemplateSHA256: String?,
        kvBitsOverride: Int?,
        runtimeCacheClass: String,
        modelCapabilities: PagedKVRuntimeModelCapabilities,
        observedRuntimeIdentity: PagedKVObservedRuntimeIdentity?
    ) -> ContinuousBatchingRequestedTuple? {
        guard kvBitsOverride == nil,
              case .attached = decision,
              let observedRuntimeIdentity,
              observedRuntimeIdentity.isCompleteRuntimeMeasurement,
              modelSHA256?.isEmpty == false,
              runtimeCacheClass != Self.pagedKVUnavailableCacheClass
        else {
            return nil
        }
        return ContinuousBatchingRequestedTuple(
            modelID: modelID ?? "",
            modelSHA256: modelSHA256 ?? "",
            tokenizerSHA256: tokenizerSHA256,
            chatTemplateSHA256: chatTemplateSHA256,
            cacheClass: runtimeCacheClass,
            kvDType: .fp16,
            requiresMoE: modelCapabilities.requiresMoEDispatch,
            hardwareClass: observedRuntimeIdentity.hardwareClass,
            metallibSHA256: observedRuntimeIdentity.metallibSHA256,
            kernelIdentifier: observedRuntimeIdentity.kernelIdentifier,
            parityLabel: observedRuntimeIdentity.parityLabel,
            poolEpoch: observedRuntimeIdentity.poolEpoch
        )
    }

    /// Milliseconds → nanoseconds for the bounded admission wait. Absent or
    /// non-positive falls back to the scheduler default rather than disabling
    /// the bound: an unbounded serve-path queue wait is the defect AC-25 names.
    private nonisolated static func queueWaitTimeoutNanoseconds(_ milliseconds: Int?) -> UInt64 {
        guard let milliseconds, milliseconds > 0 else {
            return ContinuousBatchSchedulerConfiguration.defaultQueueWaitTimeoutNanoseconds
        }
        // Serve startup rejects values above the maximum; clamp anyway so no
        // path can turn an oversized value into an effectively unbounded wait.
        let bounded = min(milliseconds, ContinuousBatchSchedulerConfiguration.maximumQueueWaitTimeoutMS)
        return UInt64(bounded) * 1_000_000
    }

    private nonisolated static func nativeMTPRoundByteCapacity(
        from admissionCapability: NativeMTPAdmissionCapability?
    ) -> Int? {
        guard let admissionCapability,
              admissionCapability.qualifiedSlots > 0,
              admissionCapability.completeWindowBytesByDepth.indices.contains(admissionCapability.maxProposalDepth)
        else {
            return nil
        }
        let maxDepthBytes = admissionCapability.completeWindowBytesByDepth[admissionCapability.maxProposalDepth]
        guard maxDepthBytes > 0 else { return nil }
        let (capacity, overflow) = maxDepthBytes.multipliedReportingOverflow(
            by: admissionCapability.qualifiedSlots
        )
        guard !overflow, capacity > 0 else { return nil }
        return capacity
    }

    private static func nativeMTPStatusSink(
        capability: NativeMTPCapability?,
        admissionCapability: NativeMTPAdmissionCapability?,
        mode: NativeMTPMode,
        resetGeneration: UInt64
    ) -> NativeMTPStatusSink {
        guard let capability, let admissionCapability else {
            return NativeMTPStatusSink.disabled(resetGeneration: resetGeneration, reason: .tupleNotAdmitted)
        }
        guard mode == .auto else {
            return NativeMTPStatusSink(
                supported: capability.admitted,
                enabled: false,
                family: capability.family ?? admissionCapability.familyAdapter,
                proposalDepth: capability.maximumProposalDepth,
                throughputDeltaPPM: capability.throughputDeltaPPM,
                resetGeneration: resetGeneration,
                lastReason: .disabledByDefault
            )
        }
        let reason: NativeMTPStatusReason
        if !capability.revocationStateAvailable {
            reason = .revocationStateUnavailable
        } else if capability.revoked {
            reason = .tupleRevoked
        } else if !capability.admitted {
            reason = .tupleNotAdmitted
        } else if !capability.supportsCurrentStateCache {
            reason = .unsupportedCacheState
        } else {
            reason = .active
        }
        return NativeMTPStatusSink(
            supported: capability.admitted,
            enabled: reason == .active,
            family: capability.family ?? admissionCapability.familyAdapter,
            proposalDepth: capability.maximumProposalDepth,
            throughputDeltaPPM: capability.throughputDeltaPPM,
            resetGeneration: resetGeneration,
            lastReason: reason
        )
    }

    private func publishNativeMTPStatusSink(
        capability: NativeMTPCapability?,
        admissionCapability: NativeMTPAdmissionCapability?,
        reasonIfDisabled: NativeMTPStatusReason = .warmSwap
    ) {
        guard nativeMTPStatusResetGeneration < UInt64.max else {
            currentNativeMTPStatusSink.adopt(NativeMTPStatusSink.disabled(
                resetGeneration: UInt64.max,
                reason: .runtimeFailure
            ))
            return
        }
        nativeMTPStatusResetGeneration += 1
        if capability == nil || admissionCapability == nil {
            currentNativeMTPStatusSink.adopt(NativeMTPStatusSink.disabled(
                resetGeneration: nativeMTPStatusResetGeneration,
                reason: nativeMTPMode == .auto ? reasonIfDisabled : .disabledByDefault
            ))
            return
        }
        currentNativeMTPStatusSink.adopt(Self.nativeMTPStatusSink(
            capability: capability,
            admissionCapability: admissionCapability,
            mode: nativeMTPMode,
            resetGeneration: nativeMTPStatusResetGeneration
        ))
    }

    /// The serve path's scheduler configuration, shared by initial load and
    /// every rebuild (warm swap, adoption), so the row cap always tracks the
    /// served context.
    nonisolated static func productionContinuousBatchSchedulerConfiguration(
        descriptor: PagedKVDescriptor,
        tuple: ContinuousBatchingRequestedTuple,
        maxBatch: Int,
        queueLimit: Int?,
        queueWaitTimeoutMS: Int?,
        prefillTokensPerIteration: Int?,
        maxContextTokens: Int,
        modelID: String,
        modelSHA256: String,
        weightsGeneration: Int,
        prefillStepSize: Int,
        maxDecodeLockstepWindow: Int,
        nativeMTPRoundByteCapacity: Int?,
        nativeMTPStatusSink: NativeMTPStatusSink?,
        prefillGrouping: ContinuousBatchPrefillGroupingRule,
        allowsRaggedPrefillOffsets: Bool = false,
        nativeMTPPromptRowsJoinRaggedPrefill: Bool = false,
        maxDecodeRowsPerForward: Int = Int.max
    ) -> ContinuousBatchSchedulerConfiguration {
        ContinuousBatchSchedulerConfiguration(
            descriptor: descriptor,
            tuple: tuple,
            moePromotionEvidenceAvailable: ContinuousBatchingPolicy.productionMoEPromotionEvidenceAvailable,
            maxActiveRows: maxBatch,
            queueLimit: queueLimit,
            decodeHeadroomTokens: ContinuousBatchSchedulerConfiguration.defaultDecodeHeadroomTokens,
            maxPrefillRowsPerIteration: min(
                maxBatch,
                ContinuousBatchSchedulerConfiguration.defaultPrefillRowsPerIteration
            ),
            prefillGrouping: prefillGrouping,
            maxPrefillTokensPerIteration: prefillTokensPerIteration
                ?? ContinuousBatchSchedulerConfiguration.defaultPrefillTokensPerIteration,
            maxPromptChunkTokens: min(
                max(1, prefillStepSize),
                ContinuousBatchSchedulerConfiguration.defaultPromptChunkTokens
            ),
            allowsRaggedPrefillOffsets: allowsRaggedPrefillOffsets,
            nativeMTPPromptRowsJoinRaggedPrefill: nativeMTPPromptRowsJoinRaggedPrefill,
            tokenDeliveryBufferLimit: ContinuousBatchSchedulerConfiguration.productionTokenDeliveryBufferLimit,
            queueWaitTimeoutNanoseconds: Self.queueWaitTimeoutNanoseconds(queueWaitTimeoutMS),
            // The row cap is the served context, not the scheduler's
            // 131,072 test default: a 200k-context provider must batch
            // what its serial path accepts. `maxQueuedTokens` is lifted
            // to at least this by the configuration.
            maxRequestTokens: maxContextTokens,
            snapshot: ContinuousBatchSchedulerSnapshot(
                modelID: modelID,
                modelSHA256: modelSHA256,
                weightsGeneration: weightsGeneration
            ),
            maxDecodeLockstepWindow: maxDecodeLockstepWindow,
            maxDecodeStepsWhilePrefilling: ContinuousBatchSchedulerConfiguration.defaultDecodeStepsWhilePrefilling,
            maxDecodeRowsPerForward: maxDecodeRowsPerForward,
            nativeMTPRoundByteCapacity: nativeMTPRoundByteCapacity,
            nativeMTPStatusSink: nativeMTPStatusSink
        )
    }

    /// The decode row bound every scheduler is built with: the configured
    /// (device) bound capped by the backend's flattened-token bound
    /// (`glm5_next` pagedMLA: 8, SPEC-039 v0.1.19). Applied here, where every
    /// serve, lab and harness scheduler is built, so no construction path can
    /// configure a wider decode forward than its backend runs.
    nonisolated static func schedulerDecodeRowBound(
        configured: Int,
        backend: (any ContinuousBatchSchedulerBackend)?
    ) -> Int {
        guard let cap = (backend as? PagedKVSharedForwardBackend)?.maxDecodeRowsPerForward, cap < configured else {
            return configured
        }
        FileHandle.standardError.write(Data(
            "event=continuous_batch_decode_row_bound max_decode_rows_per_forward=\(cap) device_bound=\(configured) reason=flattened_token_cap\n".utf8
        ))
        return cap
    }

    private nonisolated static func makeContinuousBatchScheduler(
        decision: PagedKVAttachDecision,
        tuple: ContinuousBatchingRequestedTuple?,
        backend: (any ContinuousBatchSchedulerBackend)?,
        maxBatch: Int,
        queueLimit: Int?,
        queueWaitTimeoutMS: Int?,
        prefillTokensPerIteration: Int?,
        maxContextTokens: Int,
        modelID: String?,
        modelSHA256: String?,
        weightsGeneration: Int,
        prefillStepSize: Int,
        maxDecodeLockstepWindow: Int = ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow,
        nativeMTPRoundByteCapacity: Int? = nil,
        nativeMTPStatusSink: NativeMTPStatusSink? = nil,
        prefillGrouping: ContinuousBatchPrefillGroupingRule,
        maxDecodeRowsPerForward: Int = Int.max,
        replayAuthority: any ContinuousBatchSchedulerReplayAuthority,
        contiguousCacheBridge: PagedKVRuntimeContiguousCacheBridge? = nil
    ) -> ContinuousBatchScheduler? {
        guard case .attached(let descriptor) = decision,
              let tuple,
              let backend,
              let modelID,
              let modelSHA256,
              tuple.isAdmitted(by: descriptor)
        else {
            return nil
        }
        guard let allocator = try? PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks,
            contiguousCacheBridge: contiguousCacheBridge
        ) else {
            return nil
        }
        return ContinuousBatchScheduler(
            configuration: productionContinuousBatchSchedulerConfiguration(
                descriptor: descriptor,
                tuple: tuple,
                maxBatch: maxBatch,
                queueLimit: queueLimit,
                queueWaitTimeoutMS: queueWaitTimeoutMS,
                prefillTokensPerIteration: prefillTokensPerIteration,
                maxContextTokens: maxContextTokens,
                modelID: modelID,
                modelSHA256: modelSHA256,
                weightsGeneration: weightsGeneration,
                prefillStepSize: prefillStepSize,
                maxDecodeLockstepWindow: maxDecodeLockstepWindow,
                nativeMTPRoundByteCapacity: nativeMTPRoundByteCapacity,
                nativeMTPStatusSink: nativeMTPStatusSink,
                prefillGrouping: prefillGrouping,
                allowsRaggedPrefillOffsets: (backend as? PagedKVSharedForwardBackend)?
                    .supportsRaggedPrefillOffsets ?? false,
                nativeMTPPromptRowsJoinRaggedPrefill: (backend as? PagedKVSharedForwardBackend).map {
                    PagedKVSharedForwardBackend.prefillsGroupedRowsAlone(
                        cacheKinds: $0.cacheKinds,
                        minimumGroupedChunkTokens: prefillGrouping.minimumGroupedChunkTokens
                    )
                } ?? false,
                maxDecodeRowsPerForward: schedulerDecodeRowBound(configured: maxDecodeRowsPerForward, backend: backend)
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: replayAuthority,
            contiguousCacheBridge: contiguousCacheBridge
        )
    }

    private static func makeContinuousBatchScheduler(
        decision: PagedKVAttachDecision,
        tuple: ContinuousBatchingRequestedTuple?,
        container: ModelContainer?,
        nativeMTPDrafterContainer: MTPDrafterContainer? = nil,
        nativeMTPAdmissionCapability: NativeMTPAdmissionCapability? = nil,
        backendOverride: (any ContinuousBatchSchedulerBackend)?,
        maxBatch: Int,
        queueLimit: Int?,
        queueWaitTimeoutMS: Int?,
        prefillTokensPerIteration: Int?,
        maxContextTokens: Int,
        modelID: String?,
        modelSHA256: String?,
        weightsGeneration: Int,
        kvBitsOverride: Int?,
        prefillStepSize: Int,
        nativeMTPStatusSink: NativeMTPStatusSink? = nil,
        replayAuthority: any ContinuousBatchSchedulerReplayAuthority,
        cachedTurns: Bool
    ) async -> ContinuousBatchScheduler? {
        let nativeMTPRoundByteCapacity: Int?
        if nativeMTPDrafterContainer != nil {
            guard let capacity = Self.nativeMTPRoundByteCapacity(from: nativeMTPAdmissionCapability) else {
                return nil
            }
            nativeMTPRoundByteCapacity = capacity
        } else {
            nativeMTPRoundByteCapacity = nil
        }
        if let backendOverride {
            return makeContinuousBatchScheduler(
                decision: decision,
                tuple: tuple,
                backend: backendOverride,
                maxBatch: maxBatch,
                queueLimit: queueLimit,
                queueWaitTimeoutMS: queueWaitTimeoutMS,
                prefillTokensPerIteration: prefillTokensPerIteration,
                maxContextTokens: maxContextTokens,
                modelID: modelID,
                modelSHA256: modelSHA256,
                weightsGeneration: weightsGeneration,
                prefillStepSize: prefillStepSize,
                maxDecodeLockstepWindow: decodeLockstepWindow(backendOverride: backendOverride),
                nativeMTPRoundByteCapacity: nativeMTPRoundByteCapacity,
                nativeMTPStatusSink: nativeMTPStatusSink,
                // Test backends run no MLX kernels.
                prefillGrouping: .unconstrained,
                replayAuthority: replayAuthority
            )
        }
        guard case .attached(let descriptor) = decision,
              let container,
              let cacheKinds = await pagedKVCacheKinds(container: container)
        else {
            return nil
        }
        // A hybrid (Qwen3.6) row retains its paged KV only when cached-turn
        // batching is on (SPEC-038 AC-26): the next turn then restores the
        // recurrent layers from a checkpoint. Off, a keyed hybrid row keeps the
        // serial-format materialize at terminal instead.
        let isHybrid = cacheKinds.contains(.recurrentMamba)
        let contiguousCacheBridge = isHybrid && !cachedTurns ? nil : PagedKVRuntimeContiguousCacheBridge()
        let maxDecodeLockstepWindow = servePathDecodeLockstepWindow(cacheKinds: cacheKinds)
        let prefillGrouping = await continuousBatchPrefillGrouping(container: container, modelID: modelID)
        return makeContinuousBatchScheduler(
            decision: decision,
            tuple: tuple,
            backend: PagedKVSharedForwardBackend(
                container: container,
                descriptor: descriptor,
                layerCount: cacheKinds.count,
                cacheKinds: cacheKinds,
                contiguousCacheBridge: contiguousCacheBridge,
                // Off on the serve path. A replayed `MLX.compile` step never
                // re-runs `KVCacheSimple.update`'s Swift offset/grow logic, so
                // every step after the trace writes the same KV slot at the
                // same RoPE position: greedy rows loop on the prompt within a
                // few tokens and fail `continuous_batching_invalid_cache_layout`
                // once the traced buffer (seed + 256) is full. Measured on
                // Studio 2026-09-24: signed 176, 181 and main all degenerate
                // with this on and are coherent with it off. Applies to
                // hybrid (Qwen3.6) and KV-only layouts alike.
                compiledDecode: false,
                drafterContainer: nativeMTPDrafterContainer
            ),
            maxBatch: maxBatch,
            queueLimit: queueLimit,
            queueWaitTimeoutMS: queueWaitTimeoutMS,
            prefillTokensPerIteration: prefillTokensPerIteration,
            maxContextTokens: maxContextTokens,
            modelID: modelID,
            modelSHA256: modelSHA256,
            weightsGeneration: weightsGeneration,
            prefillStepSize: prefillStepSize,
            maxDecodeLockstepWindow: maxDecodeLockstepWindow,
            nativeMTPRoundByteCapacity: nativeMTPRoundByteCapacity,
            nativeMTPStatusSink: nativeMTPStatusSink,
            prefillGrouping: prefillGrouping,
            maxDecodeRowsPerForward: continuousBatchDecodeRowBound(cacheKinds: cacheKinds),
            replayAuthority: replayAuthority,
            contiguousCacheBridge: contiguousCacheBridge
        )
    }

    /// The runtime identity the FR-CB10 self-check result is stored under:
    /// the MLX pin plus this build's row-isolation policy (SPEC-038 FR-CB2
    /// v0.3.17: per-row attention routes and the decode and verify forward
    /// bounds of this device) and the FR-CB10 probe version and route
    /// boundary (v0.3.19; with the decode window they fix the probe prompts
    /// and completion length, so stored lone outputs always match them). A
    /// result measured before the policy, at other bounds or by an older
    /// probe matches no live key, so the check re-runs; an earlier grant
    /// carries the Mac through the re-run as for an MLX pin change.
    static var continuousBatchingSelfCheckRuntimeBuild: String {
        continuousBatchingSelfCheckRuntimeBuild(forwardBound: PagedKVSharedForwardBackend.deviceVerifyTokenBound)
    }

    /// A backend with a flattened-token cap (`glm5_next`) keys on the bound
    /// it actually serves under plus the cap itself, so a grant measured
    /// under one bound never survives a change to it.
    static func continuousBatchingSelfCheckRuntimeBuild(
        forwardBound deviceBound: Int,
        routeKeyBoundary: Int = ContinuousBatchingSelfCheck.deviceRouteKeyBoundary,
        forwardTokenCap: Int? = nil
    ) -> String {
        let bound = min(deviceBound, forwardTokenCap ?? Int.max)
        let cap = forwardTokenCap.map { "+flat\($0)" } ?? ""
        // glm5_next (the only capped backend) measures a decode-only gain
        // (SPEC-038 v0.3.21) under its own probe version; every other key is
        // unchanged.
        let probe = forwardTokenCap == nil
            ? ContinuousBatchingSelfCheck.probeVersion
            : ContinuousBatchingSelfCheck.glm5NextProbeVersion
        return "\(ContinuousBatchingSelfCheckKey.currentRuntimeBuild)+cb-isolation-v1/decode\(bound)/verify\(bound)"
            + "+\(probe)/route\(routeKeyBoundary)" + cap
    }

    /// Metal architecture name as MLX core reads it (`MLX_METAL_GPU_ARCH`
    /// overrides the device's own).
    static func metalArchitectureForQuantizedRoutes() -> String {
        if let override = ProcessInfo.processInfo.environment["MLX_METAL_GPU_ARCH"], !override.isEmpty {
            return override
        }
        return GPU.deviceInfo().architecture
    }

    /// The decode row bound for this device (`ContinuousBatchDecodeRouteBound`).
    /// The decode row bound for this device, further capped by the backend's
    /// flattened-token bound for `cacheKinds` (`glm5_next`: 8, SPEC-039
    /// v0.1.19), so the logged bound is the one the scheduler splits by.
    private static func continuousBatchDecodeRowBound(cacheKinds: [PagedKVSharedForwardBackend.CacheKind]?) -> Int {
        let deviceBound = continuousBatchDecodeRowBound()
        let bound = effectiveDecodeRowBound(deviceBound: deviceBound, cacheKinds: cacheKinds)
        if bound != deviceBound {
            FileHandle.standardError.write(Data(
                "event=continuous_batch_decode_row_bound max_decode_rows_per_forward=\(bound) device_bound=\(deviceBound) reason=flattened_token_cap\n".utf8
            ))
        }
        return bound
    }

    static func effectiveDecodeRowBound(deviceBound: Int, cacheKinds: [PagedKVSharedForwardBackend.CacheKind]?) -> Int {
        guard let cacheKinds, let cap = PagedKVSharedForwardBackend.maxFlattenedTokensPerForward(cacheKinds: cacheKinds) else {
            return deviceBound
        }
        return min(deviceBound, cap)
    }

    private static func continuousBatchDecodeRowBound() -> Int {
        let architecture = metalArchitectureForQuantizedRoutes()
        let deviceBound = ContinuousBatchDecodeRouteBound.maxDecodeRowsPerForward(architecture: architecture)
        #if MACPROVIDER_LAB_HARNESS
        // Lab measurement only: capped vs uncapped decode forwards.
        let bound = ProcessInfo.processInfo.environment["MACPROVIDER_LAB_DECODE_ROW_BOUND"]
            .flatMap { Int($0) }
            .flatMap { $0 >= 1 ? $0 : nil } ?? deviceBound
        #else
        let bound = deviceBound
        #endif
        FileHandle.standardError.write(Data(
            "event=continuous_batch_decode_row_bound max_decode_rows_per_forward=\(bound)\n".utf8
        ))
        return bound
    }

    /// The loaded model's prefill grouping rule, from its own `config.json`.
    /// A container not loaded from a local directory has no readable
    /// configuration and fails safe to `.ungrouped`.
    private static func continuousBatchPrefillGrouping(
        container: ModelContainer,
        modelID: String?
    ) async -> ContinuousBatchPrefillGroupingRule {
        guard case .directory(let directory) = await container.configuration.id else {
            return .ungrouped
        }
        let configData = try? Data(contentsOf: directory.appendingPathComponent("config.json"))
        let rule = ContinuousBatchPrefillGroupingRule.fromModelConfiguration(configData, modelID: modelID)
        let bound = rule.minimumGroupedChunkTokens == Int.max ? "none" : String(rule.minimumGroupedChunkTokens)
        FileHandle.standardError.write(Data(
            "event=continuous_batch_prefill_grouping min_grouped_chunk_tokens=\(bound)\n".utf8
        ))
        return rule
    }

    /// Every cache layout, hybrid (recurrent + attention) included, decodes
    /// in the 16-step window (SPEC-038 FR-CB2). Hybrid recurrent state is
    /// packed once per window, advances one token per step inside it, and is
    /// split back to rows at the window end; a row that stops mid-window keeps
    /// recurrent checkpoints at its stop boundary. Exactness against one-step
    /// windows: `HybridDecodeWindowExactnessTests` (tiny Qwen3.5, prompts past
    /// the 512-token chunk) and `msb-throughput --scenario hybrid-window` on
    /// the served artifact.
    nonisolated static func servePathDecodeLockstepWindow(
        cacheKinds: [PagedKVSharedForwardBackend.CacheKind]
    ) -> Int {
        #if MACPROVIDER_LAB_HARNESS
        // Lab A/B measurement only (#1906): a smaller hybrid window, down to 1.
        if cacheKinds.contains(.recurrentMamba),
           let raw = ProcessInfo.processInfo.environment["MACPROVIDER_LAB_HYBRID_DECODE_WINDOW"],
           let window = Int(raw), window >= 1 {
            return min(window, ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow)
        }
        #endif
        return ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow
    }

    /// An injected real paged-KV backend (native-MTP bench / hardware E2E)
    /// must decode in the serve path's windows, or its stream cadence and
    /// throughput are not production's. Scripted test backends keep the
    /// default window.
    nonisolated static func decodeLockstepWindow(
        backendOverride: any ContinuousBatchSchedulerBackend
    ) -> Int {
        guard let paged = backendOverride as? PagedKVSharedForwardBackend else {
            return ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow
        }
        return servePathDecodeLockstepWindow(cacheKinds: paged.cacheKinds)
    }

    private static func pagedKVCacheKinds(
        container: ModelContainer
    ) async -> [PagedKVSharedForwardBackend.CacheKind]? {
        await container.perform { context in
            return try? Self.pagedKVCacheKinds(model: context.model)
        }
    }

    private func rebuildContinuousBatchScheduler(container: ModelContainer?) async {
        publishNativeMTPStatusSink(
            capability: currentNativeMTPCapability,
            admissionCapability: currentNativeMTPAdmissionCapability
        )
        continuousBatchScheduler = await Self.makeContinuousBatchScheduler(
            decision: pagedKVAttachDecision,
            tuple: continuousBatchingRequestedTuple(),
            container: container,
            nativeMTPDrafterContainer: currentNativeMTPDrafterContainer,
            nativeMTPAdmissionCapability: currentNativeMTPAdmissionCapability,
            backendOverride: testContinuousBatchingBackend,
            maxBatch: maxBatch,
            queueLimit: continuousBatchQueueLimit,
            queueWaitTimeoutMS: continuousBatchQueueWaitTimeoutMS,
            prefillTokensPerIteration: continuousBatchPrefillTokensPerIteration,
            maxContextTokens: maxContextTokens,
            modelID: currentModelID,
            modelSHA256: currentModelHash,
            weightsGeneration: currentSpecDecodeGeneration,
            kvBitsOverride: kvBitsOverride,
            prefillStepSize: prefillStepSize,
            nativeMTPStatusSink: currentNativeMTPStatusSink,
            replayAuthority: continuousBatchReplayAuthority,
            cachedTurns: continuousBatchingCachedTurns
        )
        continuousBatchingDurableReplayAuthorityAvailable =
            continuousBatchScheduler != nil && continuousBatchReplayAuthority.durableAvailable
    }

    /// A request is representable by the batched shared-forward contract only if
    /// its generation is fully described by the scalar sampling parameters the
    /// contract carries. logit_bias and logprobs impose row-local decoder state
    /// the contract does not model, so such requests must serial-route (canary) /
    /// fail closed (strict) before admission — a gate that holds for the SPEC-039
    /// bridge so a future backend cannot silently drop that state.
    ///
    /// SPEC-038 AC-6c: structured output (`response_format` json_object /
    /// json_schema) and enabled tools constrain no logit. The serial path
    /// renders them into the prompt (`userInput(for:)`) and applies them after
    /// generation (`parseGeneratedOutput`, `validateStructuredCompletion`, the
    /// SPEC-018 byte caps, the serial tool-turn stop, and the streaming
    /// `SerialStreamingTextEmitter`); a batched row reuses exactly those, so
    /// they batch. Kept gated: Harmony (gpt-oss) models with tools or
    /// structured output. Their serial stream parses Harmony channels as
    /// tokens arrive and sends only the final channel; the batched stream
    /// sink streams decoded text and has no Harmony channel parser, and the
    /// gate cannot tell a streaming request from a non-streaming one. Buyer
    /// stops on Harmony also require that parser: raw scheduler token stops
    /// would terminate on hidden analysis or headers.
    static func requestStateRepresentable(_ request: ChatCompletionRequest) -> Bool {
        if request.containsNonTextMessageContentPart { return false }
        // hasEnabledTools treats an absent, explicit-null, or empty tools array as
        // no-tools, so a bare or explicit-null `tool_choice` does not false-positive
        // here (the meaningful signal is whether tools are actually enabled).
        if HarmonyResponseParser.isHarmonyModelID(request.model),
           isStructuredResponseFormat(request.responseFormat)
            || hasEnabledTools(request.promptSource.tools)
            || request.stop.contains(where: { !$0.isEmpty }) {
            return false
        }
        // logit_bias and logprobs (incl. top_logprobs metadata) have no carrier in
        // the scheduler row contract. top_logprobs only shapes response metadata,
        // not token selection, but is rejected here too so the gate is provably
        // complete and no per-request logprob surface can reach a batch unrepresented.
        if isActiveJSONValue(request.promptSource.logitBias) { return false }
        if isRequestedLogprobs(request.promptSource.logprobs) { return false }
        if isActiveJSONValue(request.promptSource.topLogprobs) { return false }
        // SPEC-038 AC-6b: each batched row samples with the serial path's own
        // sampler for its temperature/top_p and a row-local seed
        // (`ContinuousBatchRowSampler`). Native runtime admission rejects
        // non-default buyer penalties before a request reaches this gate.
        return ContinuousBatchRowSampler.supports(
            temperature: request.temperature,
            topP: request.topP
        )
    }

    nonisolated static func validateNativeSamplingPenalties(_ request: ChatCompletionRequest) throws {
        if request.presencePenalty != 0.0 {
            throw APIError(
                status: 400,
                message: "presence_penalty is not supported by the native MLX provider runtime; omit it or set it to 0",
                code: "unsupported_sampling_penalty",
                param: "presence_penalty"
            )
        }
        if request.frequencyPenalty != 0.0 {
            throw APIError(
                status: 400,
                message: "frequency_penalty is not supported by the native MLX provider runtime; omit it or set it to 0",
                code: "unsupported_sampling_penalty",
                param: "frequency_penalty"
            )
        }
    }

    nonisolated static func requestHasStableRequestID(_ request: ChatCompletionRequest) -> Bool {
        nonEmpty(request.requestID) != nil
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
    ) throws -> ContinuousBatchingCapability {
        let capability = continuousBatchingCapability(
            draftConfigured: snapshot.hasTargetCompatibleDraft || currentDraftModelID != nil,
            requestHasStableRequestID: Self.requestHasStableRequestID(request),
            requestStateRepresentable: Self.requestStateRepresentable(request)
        )
        // Telemetry is emitted once per request at preflight; execution paths
        // re-validate for fail-closed safety but must not re-log the same
        // serial-route event (avoids double-counting canary promotion evidence).
        if emitTelemetry {
            ContinuousBatchingPolicy.logSerialRouteIfNeeded(capability)
        }
        try ContinuousBatchingPolicy.validateStrictStartup(capability)
        return capability
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
        // SPEC-001-R011: a swap drain does not wait out local work.
        await providerStatus.preemptAdmittedLocalWork()
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
            nativeVisionProfile: nil,
            draftModelID: nil,
            draftContainer: nil,
            draftFailureReason: nil,
            modelCapabilities: Self.pagedKVModelCapabilities(modelID: modelID, configJSONData: nil),
            adoptionKnobs: nil
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
        nativeVisionProfile: NativeVisionProfile?,
        draftModelID: String?,
        draftContainer: ModelContainer?,
        draftFailureReason: String?,
        modelCapabilities: PagedKVRuntimeModelCapabilities,
        adoptionKnobs: ModelRuntimeAdoptionServeKnobs?
    ) async {
        let target = targetModelID ?? modelID
        // SPEC-038 v0.3.15: a new model or runtime is re-checked.
        selfCheckGeneration += 1
        let swapGeneration = selfCheckGeneration
        continuousBatchingSelfCheck = .pending
        continuousBatchingSelfCheckReport = nil
        if let adoptionKnobs {
            maxContextTokens = adoptionKnobs.maxContext
            kvBitsOverride = adoptionKnobs.kvBits
            maxBatchBeforePolicyCeiling = adoptionKnobs.maxBatch
        }
        // The rebuilt scheduler never has more rows than the new model's
        // signed policy ceiling (SPEC-038 FR-CB11 v0.3.22).
        maxBatch = Self.rowsUnderPolicyCeiling(
            rows: maxBatchBeforePolicyCeiling,
            ceiling: servedSlotsManaged ? continuousBatchingPolicyServedSlotCeiling(modelSHA256: modelHash) : nil
        )
        // A managed provider serves the owner pin or one slot until the new
        // model's self-check (or its stored result) decides.
        let swapServedSlots: Int? = servedSlotsManaged
            ? min(ownerPinnedServedSlots ?? 1, maxBatch)
            : adoptionKnobs?.maxBatch
        if let swapServedSlots {
            servedSlotLimit = swapServedSlots
            await inferenceGate.resize(to: swapServedSlots, stamp: swapGeneration)
        }
        await conversationCache.purgeAllHot()
        currentContainer = container
        if let previous = residentWeightsTicket {
            residentWeightsTicket = nil
            _ = await previous.end()
        }
        residentWeightsTicket = await Self.startResidentWeightsTicket(modelFamily: modelCapabilities.modelFamily)
        currentModelID = modelID
        currentModelHash = modelHash
        currentTemplateSupportsThinkingToggle = Self.resolvedTemplateSupportsThinkingToggle(
            artifactSHA256: modelHash,
            configuredArtifactSHA256: verifiedCatalogArtifactSHA256,
            configuredSupportsThinkingToggle: configuredTemplateSupportsThinkingToggle,
            targetCapabilitiesByArtifactSHA256: targetTemplateSupportsThinkingToggleByArtifactSHA256
        )
        currentTemplateSupportsPreserveThinking = Self.resolvedTemplateSupportsPreserveThinking(
            artifactSHA256: modelHash,
            configuredArtifactSHA256: verifiedCatalogArtifactSHA256,
            configuredSupportsPreserveThinking: configuredTemplateSupportsPreserveThinking,
            targetCapabilitiesByArtifactSHA256: targetTemplateSupportsPreserveThinkingByArtifactSHA256
        )
        currentModelHashAlgorithm = modelHash == nil ? nil : modelHashAlgorithm
        currentWeightsManifestSHA256 = weightsManifestSHA256
        currentTokenizerConfigSHA256 = tokenizerConfigSHA256
        currentChatTemplateSHA256 = chatTemplateSHA256
        currentNativeVisionProfile = nativeVisionProfile
        if let attachedKVDiskAdapter {
            // The support verdict is model-specific. Re-evaluate it against
            // the newly installed container before the swap is published.
            noteUnsupportedKVDiskCacheClass(nil)
            await seedColdGeometry(into: attachedKVDiskAdapter)
        }
        let pagedKVSkipReason = Self.pagedKVSkipReason(
            config: pagedKVConfig, nativeVision: nativeVisionProfile != nil)
        Self.logPagedKVSkip(pagedKVSkipReason)
        let runtimeCacheClass = pagedKVConfig.effectiveEnabled && pagedKVSkipReason == nil
            ? await Self.pagedKVRuntimeCacheClass(
                container: container,
                maxContextTokens: maxContextTokens,
                kvBitsOverride: kvBitsOverride,
                prefillStepSize: prefillStepSize
            )
            : Self.pagedKVUnavailableCacheClass
        pagedKVRuntimeCacheClass = runtimeCacheClass
        currentPagedKVModelCapabilities = modelCapabilities
        pagedKVObservedRuntimeIdentity = nil
        pagedKVHardwareSizingProof = nil
        pagedKVSchedulerBackendInstalled = false
        let (parityProbe, moeProbe): (PagedKVRuntimeParityProbeResult?, PagedKVRuntimeMoEProbeResult?)
        if let container {
            (parityProbe, moeProbe) = await self.computePagedKVRuntimeProbes(
                container: container,
                modelID: modelID,
                modelCapabilities: modelCapabilities,
                runtimeCacheClass: runtimeCacheClass
            )
        } else {
            (parityProbe, moeProbe) = (nil, nil)
        }
        if let measurement = Self.measurePagedKVRuntime(
            config: pagedKVConfig,
            modelID: modelID,
            modelSHA256: modelHash,
            tokenizerSHA256: tokenizerConfigSHA256,
            chatTemplateSHA256: chatTemplateSHA256,
            modelCapabilities: modelCapabilities,
            parityProbe: parityProbe,
            moeProbe: moeProbe
        ) {
            pagedKVObservedRuntimeIdentity = measurement.observedRuntimeIdentity
            pagedKVHardwareSizingProof = measurement.hardwareSizingProof
        }
        let candidateSchedulerBackendInstalled = pagedKVObservedRuntimeIdentity != nil
            && pagedKVHardwareSizingProof != nil
        pagedKVAttachDecision = Self.pagedKVRuntimeCapabilityDecision(
            config: pagedKVConfig,
            modelID: modelID,
            modelHash: modelHash,
            tokenizerSHA256: tokenizerConfigSHA256,
            chatTemplateSHA256: chatTemplateSHA256,
            kvBitsOverride: kvBitsOverride,
            runtimeCacheClass: runtimeCacheClass,
            modelCapabilities: modelCapabilities,
            observedRuntimeIdentity: pagedKVObservedRuntimeIdentity,
            hardwareSizingProof: pagedKVHardwareSizingProof,
            schedulerBackendInstalled: candidateSchedulerBackendInstalled
        )
        if case .attached = pagedKVAttachDecision {
            pagedKVSchedulerBackendInstalled = true
        }
        stopNativeMTPRevocationRefresh()
        currentNativeMTPDrafterContainer = nil
        currentNativeMTPCapability = nil
        currentNativeMTPAdmissionCapability = nil
        currentNativeMTPTupleOffer = nil
        parkedNativeMTPTuple = nil
        currentSpecDecodeGeneration += 1
        await rebuildContinuousBatchScheduler(container: container)
        if continuousBatchScheduler == nil {
            pagedKVSchedulerBackendInstalled = false
            pagedKVAttachDecision = Self.pagedKVRuntimeCapabilityDecision(
                config: pagedKVConfig,
                modelID: modelID,
                modelHash: modelHash,
                tokenizerSHA256: tokenizerConfigSHA256,
                chatTemplateSHA256: chatTemplateSHA256,
                kvBitsOverride: kvBitsOverride,
                runtimeCacheClass: runtimeCacheClass,
                modelCapabilities: modelCapabilities,
                observedRuntimeIdentity: pagedKVObservedRuntimeIdentity,
                hardwareSizingProof: pagedKVHardwareSizingProof,
                schedulerBackendInstalled: false
            )
        }
        Self.logPagedKVAttachDecision(pagedKVAttachDecision)
        currentDraftModelID = draftModelID
        currentDraftTargetModelID = draftModelID == nil ? nil : modelID
        currentDraftContainer = draftContainer
        state = .ready
        targetModelID = nil
        if let draftFailureReason {
            Self.logDraftSwapFailure(
                targetModelID: modelID,
                draftModelID: configuredDraftModelID,
                reason: draftFailureReason
            )
        }
        // The swapped-in model's stored or prior grant applies before the
        // swap is published, so a qualified model keeps batching.
        var swapAdvertisedSlots = swapServedSlots
        if servedSlotsManaged, selfCheckGeneration == swapGeneration, let resolver = servedSlotsResolver,
           let target = continuousBatchingSelfCheckTarget(includeDecided: true),
           let resolution = resolver(target) {
            continuousBatchingSelfCheck = resolution.state
            continuousBatchingSelfCheckReport = resolution.report
            servedSlotLimit = resolution.servedSlots
            await inferenceGate.resize(to: resolution.servedSlots, stamp: swapGeneration)
            swapAdvertisedSlots = resolution.servedSlots
        }
        // The rebuilt scheduler starts unlimited; cap buyer rows at once.
        if let swapAdvertisedSlots, selfCheckGeneration == swapGeneration {
            let rebuiltScheduler = continuousBatchScheduler
            await rebuiltScheduler?.setBuyerRowLimit(swapAdvertisedSlots)
        }
        await providerStatus?.completeTargetSwap(
            modelID: modelID,
            modelHash: modelHash,
            modelHashAlgorithm: currentModelHashAlgorithm,
            weightsManifestSHA256: weightsManifestSHA256,
            maxContextTokens: adoptionKnobs?.maxContext,
            maxContextSource: adoptionKnobs?.contextSource,
            maxConcurrency: swapAdvertisedSlots,
            specDecodeDraftModelID: speculativeCacheWrapValidated ? draftModelID : nil,
            specDecodeNumDraftTokens: speculativeCacheWrapValidated && draftModelID != nil ? numDraftTokens : nil,
            servedSlotsStamp: servedSlotsManaged ? swapGeneration : nil
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

    /// #2016: `NativeVisionProfile.selectionModelID` for a load target. The
    /// catalog id counts only with the verified catalog artifact binding.
    private nonisolated func nativeVisionSelectionModelID(for targetModelID: String?) -> String? {
        NativeVisionProfile.selectionModelID(
            servedModelID: targetModelID, configuredModelID: modelID,
            verifiedCatalogModelID: verifiedCatalogArtifactSHA256 == nil ? nil : catalogModelIDAlias
        )
    }

    private func isConfiguredCatalogModel(_ targetModelID: String) -> Bool {
        targetModelID == modelID || modelIDAliasList(catalogModelIDAlias).contains(targetModelID)
    }

    private func targetAuthority(for targetModelID: String) -> ModelRuntimeTargetAuthority? {
        if let authority = targetAuthorities[targetModelID]
            ?? targetAuthorities[targetModelID.lowercased(with: nil)] {
            return authority
        }
        guard isConfiguredCatalogModel(targetModelID),
              let artifactSHA256 = verifiedCatalogArtifactSHA256,
              let catalogRevision = verifiedModelCatalogRevision else {
            return nil
        }
        return ModelRuntimeTargetAuthority(
            modelArgument: configuredModelLoadPath ?? targetModelID,
            artifactSHA256: artifactSHA256,
            catalogRevision: catalogRevision
        )
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
        localRegistrationIDs.remove(id)
    }

    private func cancelAllInFlightForDrainTimeout() {
        let cancels = Array(inFlightCancellations.values)
        inFlightCancellations.removeAll()
        localRegistrationIDs.removeAll()
        for cancel in cancels {
            cancel()
        }
    }

    private func removeSignalContinuation(_ id: UUID) {
        signalContinuations.removeValue(forKey: id)
    }

    /// The exact identity SPEC-018 §3.11 tool selection checks. An
    /// alias-configured provider loads `model` under a local name and serves
    /// its configured catalog id; that id is the loaded identity only while the
    /// configured model is the one loaded (the request-alias guard below). A
    /// warm-swapped model, and a pool alias (never the native allowlisted id),
    /// keep the loaded id.
    private func toolSelectionModelID(_ snapshot: RuntimeSnapshot) -> String? {
        guard snapshot.modelID != nil, snapshot.modelID == modelID,
              catalogModelIDAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
                == ToolSelectionPolicy.supportedNativeModel
        else { return snapshot.modelID }
        return ToolSelectionPolicy.supportedNativeModel
    }

    func acquireLocalRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        // Check and register in one actor turn so a swap cannot interleave.
        try Self.validateReady(state)
        let handle = try acquireRequestHandle(request)
        localRegistrationIDs.insert(handle.registrationID)
        return handle
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        let snapshot = requestStartSnapshot()
        try Self.validateReady(snapshot.state)
        _ = try Self.validateNativeVisionRequest(request, profile: snapshot.nativeVisionProfile)
        // Accept the coordinator-advertised catalog id as an alias only while the
        // configured model is the one currently loaded (mirrors
        // coordinatorWireModelID's servedModelID == loadedModelID guard). After a
        // warm-swap to a different model the alias must not apply.
        let aliases = (snapshot.modelID != nil && snapshot.modelID == self.modelID)
            ? modelIDAliasList(catalogModelIDAlias)
            : []
        try request.validateModelMatches(snapshot.modelID, aliases: aliases)
        try ToolSelectionPolicy.validateRequest(request, loadedModelID: toolSelectionModelID(snapshot), runtime: "mlx_cache")
        try Self.validateNativeSamplingPenalties(request)
        let drainCancelled = DrainCancelToken()
        let registrationID = registerInFlight { drainCancelled.fire() }
        return RequestHandle(
            snapshot: snapshot,
            registrationID: registrationID,
            drainCancelled: drainCancelled
        )
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        try ToolSelectionPolicy.validateRequest(request, loadedModelID: toolSelectionModelID(handle.snapshot), runtime: "mlx_cache")
        _ = try Self.validateNativeVisionRequest(request, profile: handle.snapshot.nativeVisionProfile)
        // SPEC-025 §5.2: the streaming path runs preflight (prompt prepare inside
        // container.perform — real model-thread work) before stream() brackets
        // active inference. Bracket it here too so a pre-first-token wedge during
        // preflight is observable (active_inference true) rather than reading idle.
        ModelLivenessTracker.shared.beginInference()
        defer { ModelLivenessTracker.shared.endInference() }
        _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
        if !request.containsNonTextMessageContentPart {
            try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
        }
        try handle.drainCancelled.check()
        guard let container = handle.snapshot.container else {
            if testCompletion != nil {
                return
            }
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        let templateSupportsThinkingToggle = handle.snapshot.templateSupportsThinkingToggle
        let templateSupportsPreserveThinking = handle.snapshot.templateSupportsPreserveThinking
        let selectionModelID = toolSelectionModelID(handle.snapshot)
        try await inferenceGate.withPermit {
            // A cancelled request (client gone, or local work preempted by a
            // buyer under SPEC-001-R011) releases the gate without preparing.
            try Task.checkCancellation()
            try handle.drainCancelled.check()
            return try await container.perform { context in
                try Task.checkCancellation()
                try handle.drainCancelled.check()
                let (lmInput, _) = try await Self.preparedRequestInput(
                    for: request,
                    context: context,
                    templateSupportsThinkingToggle: templateSupportsThinkingToggle,
                    templateSupportsPreserveThinking: templateSupportsPreserveThinking,
                    nativeVisionProfile: handle.snapshot.nativeVisionProfile,
                    toolSelectionModelID: selectionModelID
                )
                try Task.checkCancellation()
                try handle.drainCancelled.check()
                try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
            }
        }
    }


    func localResponsesCapabilities() async -> LocalResponsesCapabilities {
        guard state == .ready else { return .unavailable }
        let snapshot = requestStartSnapshot()
        guard snapshot.state == .ready, snapshot.container != nil, let model = snapshot.modelID else {
            return .unavailable
        }
        return .loaded(model: model, modelHash: snapshot.modelHash,
                       generation: selfCheckGeneration, runtime: "mlx_cache",
                       toolSelectionModelID: toolSelectionModelID(snapshot))
    }

    func localTokenUtilityCapabilities() async -> LocalTokenUtilityCapabilities {
        guard state == .ready else {
            return LocalTokenUtilityCapabilities(model: nil, modelHash: nil, generation: nil, operations: [])
        }
        let snapshot = requestStartSnapshot()
        guard snapshot.state == .ready, snapshot.container != nil, snapshot.modelID != nil else {
            return LocalTokenUtilityCapabilities(model: nil, modelHash: nil, generation: nil, operations: [])
        }
        var operations = ["tokenize", "detokenize"]
        if currentChatTemplateSHA256 != nil { operations.append("apply-template") }
        return LocalTokenUtilityCapabilities(model: snapshot.modelID, modelHash: snapshot.modelHash,
                                             generation: selfCheckGeneration, operations: operations)
    }


    func localTokenUtility(_ request: LocalTokenUtilityRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> LocalTokenUtilityResult {
        let handle = try acquireLocalRequestHandle(request.admissionRequest())
        let generation = selfCheckGeneration
        defer { unregisterInFlight(handle.registrationID) }
        if request.operation == .applyTemplate, currentChatTemplateSHA256 == nil {
            throw APIError(status: 422, message: "Loaded model has no verified chat template", code: "chat_template_unsupported")
        }

        guard let container = handle.snapshot.container, let model = handle.snapshot.modelID else {
            throw APIError(status: 503, message: "Model not loaded", code: "model_not_loaded")
        }
        let checkCancellation: @Sendable () throws -> Void = {
            try Task.checkCancellation()
            try handle.drainCancelled.check()
            if shouldCancel() { throw CancellationError() }
        }
        try checkCancellation()
        let session = LocalTokenUtilitySession(model: model, modelHash: handle.snapshot.modelHash,
                                              generation: generation, gate: inferenceGate)
        let work = Task {
            try await session.perform {

                try checkCancellation()
                return try await container.perform { context in
                    try checkCancellation()
                    let tokens: [Int]?
                    let text: String?
                    switch request.operation {
                    case .tokenize:
                        tokens = context.tokenizer.encode(text: request.text!, addSpecialTokens: false)
                        text = nil
                    case .detokenize:
                        let ids = request.tokens!
                        guard ids.allSatisfy({ context.tokenizer.convertIdToToken($0) != nil }) else {
                            throw LocalTokenUtilityRequest.invalid("Token ID is outside the loaded tokenizer vocabulary")
                        }
                        tokens = nil
                        text = context.tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
                    case .applyTemplate:
                        let messages: [[String: any Sendable]] = request.messages!.map { message in
                            ["role": message["role"]!, "content": message["content"]!]
                        }
                        do {
                            tokens = try context.tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: Self.templateAdditionalContext(
                                supportsThinkingToggle: handle.snapshot.templateSupportsThinkingToggle,
                                supportsPreserveThinking: handle.snapshot.templateSupportsPreserveThinking))
                        } catch {
                            throw APIError(status: 422, message: "Loaded tokenizer cannot apply this chat template", code: "chat_template_unsupported")
                        }
                        guard tokens!.count <= LocalTokenUtilityRequest.tokenLimit else { throw LocalTokenUtilityRequest.limitError() }
                        text = context.tokenizer.decode(tokenIds: tokens!, skipSpecialTokens: false)
                    }
                    guard (tokens?.count ?? 0) <= LocalTokenUtilityRequest.tokenLimit,
                          (text?.utf8.count ?? 0) <= LocalTokenUtilityRequest.outputByteLimit else {
                        throw LocalTokenUtilityRequest.limitError()
                    }
                    try checkCancellation()
                    return (tokens, text)
                }
            }
        }
        // Replace the existing registration in this actor turn, before yielding.
        // Drain timeout cancels a queued permit waiter as well as firing its token.
        inFlightCancellations[handle.registrationID] = {
            handle.drainCancelled.fire()
            work.cancel()
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func relayBlindPrepare(_ request: ChatCompletionRequest) async throws -> RelayBlindPreparedRequest {
        let handle = try acquireRequestHandle(request)
        do {
            _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
            if !request.containsNonTextMessageContentPart {
                try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
            }
            try handle.drainCancelled.check()
            guard let container = handle.snapshot.container else {
                throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
            }
            let maxContextTokens = maxContextTokens
            let templateSupportsThinkingToggle = handle.snapshot.templateSupportsThinkingToggle
            let templateSupportsPreserveThinking = handle.snapshot.templateSupportsPreserveThinking
            let selectionModelID = toolSelectionModelID(handle.snapshot)
            let inputTokens = try await inferenceGate.withPermit {
                try handle.drainCancelled.check()
                return try await container.perform { context in
                    try handle.drainCancelled.check()
                    let (prepared, _) = try await Self.preparedRequestInput(
                        for: request,
                        context: context,
                        templateSupportsThinkingToggle: templateSupportsThinkingToggle,
                        templateSupportsPreserveThinking: templateSupportsPreserveThinking,
                        nativeVisionProfile: handle.snapshot.nativeVisionProfile,
                        toolSelectionModelID: selectionModelID
                    )
                    let count = prepared.text.tokens.size
                    try Self.validatePromptTokenCount(count, maxContextTokens: maxContextTokens)
                    return count
                }
            }
            return RelayBlindPreparedRequest(handle: handle, inputTokens: inputTokens)
        } catch {
            unregisterInFlight(handle.registrationID)
            throw error
        }
    }

    func pagedKVPreflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        _ = try applyContinuousBatchingPolicy(request: request, snapshot: handle.snapshot)
        if !request.containsNonTextMessageContentPart {
            try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
        }
        try handle.drainCancelled.check()
    }

    private struct ContinuousBatchPreparedRequest: Sendable {
        let promptTokens: [Int]
        let stopTokenSequences: [[Int]]
        let modelStopTokenIDs: Set<Int>
        let recurrentCheckpointPositions: [Int]
        /// The loaded model has recurrent (hybrid) layers; computed for keyed
        /// requests only, false otherwise.
        let modelHasRecurrentLayers: Bool
        /// SPEC-018 §3.11 call prefill ending `promptTokens`, if any.
        let toolCallPrefill: String?
    }

    /// Keyed hybrid requests only: where the batched row snapshots recurrent
    /// state, identical to the serial path's `prefillRecurrentCheckpoints`.
    private nonisolated static func continuousBatchRecurrentCheckpointPositions(
        promptTokens: [Int],
        conversationKey: String?,
        hybrid: Bool,
        context: ModelContext
    ) -> [Int] {
        guard nonEmpty(conversationKey) != nil else { return [] }
        return ConversationCache.recurrentCheckpointPositions(
            promptTokenIds: promptTokens.map(Int32.init),
            imStartTokenID: context.tokenizer.convertTokenToId("<|im_start|>").map(Int32.init),
            hybrid: hybrid,
            decode: { context.tokenizer.decode(tokenIds: $0) })
    }

    /// The tokens a batched hybrid entry commits: the canonical list cut to the
    /// length its attention layers cover, so `begin`'s trim lands exactly on a
    /// checkpoint. Nil if the canonical list is shorter (never expected).
    nonisolated static func serialConversationCacheCommitTokens(
        canonicalTokens: [Int32],
        coveredTokenCount: Int
    ) -> [Int32]? {
        guard coveredTokenCount <= canonicalTokens.count else { return nil }
        return Array(canonicalTokens.prefix(coveredTokenCount))
    }

    /// Tokenizer decode for CB streaming. Must not take `ModelContainer`:
    /// compiled lockstep already holds that hop, and a per-token `perform`
    /// behind the delivery buffer is what turned longer canary streams into
    /// `internal_error` after the first content chunk.
    struct StreamingDetokenizer: @unchecked Sendable {
        let decode: ([Int]) -> String
        let makeIncremental: () -> IncrementalTextDecoder
        let cleanUpTokenizationSpaces: Bool

        init(
            decode: @escaping ([Int]) -> String,
            makeIncremental: @escaping () -> IncrementalTextDecoder,
            cleanUpTokenizationSpaces: Bool = false
        ) {
            self.decode = decode
            self.makeIncremental = makeIncremental
            self.cleanUpTokenizationSpaces = cleanUpTokenizationSpaces
        }

        init(
            decode: @escaping ([Int]) -> String,
            tokenPiece: @escaping (Int) -> String?,
            cleanUpTokenizationSpaces: Bool = false
        ) {
            self.init(
                decode: decode,
                makeIncremental: {
                    let box = ByteLevelIncrementalTextDecoderBox(
                        tokenPiece: tokenPiece,
                        cleanUpTokenizationSpaces: cleanUpTokenizationSpaces
                    )
                    return IncrementalTextDecoder(appendToken: box.append)
                },
                cleanUpTokenizationSpaces: cleanUpTokenizationSpaces
            )
        }

        init(tokenizer: any MLXLMCommon.Tokenizer) {
            let cleanupProbe = tokenizer.encode(text: " .", addSpecialTokens: false)
            self.init(
                decode: { tokenizer.decode(tokenIds: $0) },
                tokenPiece: tokenizer.convertIdToToken,
                cleanUpTokenizationSpaces: tokenizer.decode(tokenIds: cleanupProbe) == "."
            )
        }
    }

    final class IncrementalTextDecoder: @unchecked Sendable {
        private let appendToken: (Int) -> String
        private let returnsDelta: Bool
        private var text = ""

        init(decodeToken: @escaping (Int) -> String) {
            appendToken = decodeToken
            returnsDelta = true
        }

        init(appendToken: @escaping (Int) -> String) {
            self.appendToken = appendToken
            returnsDelta = false
        }

        func append(_ token: Int) -> String {
            let decoded = appendToken(token)
            if returnsDelta {
                text += decoded
            } else {
                text = decoded
            }
            return text
        }

        var appendedText: String { text }
    }

    /// Qwen and Llama 3.3 use the Hugging Face byte-level decoder. Decode the
    /// token pieces directly so serial tool rows retain per-token boundaries
    /// without repeatedly decoding the accumulated prefix.
    private final class ByteLevelIncrementalTextDecoderBox: @unchecked Sendable {
        private struct ReplacementStage {
            let pattern: [Character]
            let replacement: [Character]
            var pending: [Character] = []

            init(_ pattern: String, _ replacement: String) {
                self.pattern = Array(pattern)
                self.replacement = Array(replacement)
            }

            mutating func consume(_ input: [Character]) -> [Character] {
                var output: [Character] = []
                for character in input {
                    pending.append(character)
                    while !pattern.starts(with: pending) {
                        output.append(pending.removeFirst())
                    }
                    if pending == pattern {
                        output.append(contentsOf: replacement)
                        pending.removeAll(keepingCapacity: true)
                    }
                }
                return output
            }

            mutating func flush() -> [Character] {
                defer { pending.removeAll(keepingCapacity: true) }
                return pending
            }
        }

        private struct CleanupPipeline {
            private var stages = [
                ReplacementStage(" .", "."),
                ReplacementStage(" ?", "?"),
                ReplacementStage(" !", "!"),
                ReplacementStage(" ,", ","),
                ReplacementStage(" ' ", "'"),
                ReplacementStage(" n't", "n't"),
                ReplacementStage(" 'm", "'m"),
                ReplacementStage(" 's", "'s"),
                ReplacementStage(" 've", "'ve"),
                ReplacementStage(" 're", "'re"),
            ]

            mutating func append(_ text: String) -> String {
                var output = Array(text)
                for index in stages.indices {
                    output = stages[index].consume(output)
                }
                return String(output)
            }

            func provisionalText() -> String {
                var copy = self
                var output: [Character] = []
                for index in copy.stages.indices {
                    var flushed = copy.stages[index].flush()
                    for downstream in copy.stages.indices.dropFirst(index + 1) {
                        flushed = copy.stages[downstream].consume(flushed)
                    }
                    output.append(contentsOf: flushed)
                }
                return String(output)
            }
        }

        private let tokenPiece: (Int) -> String?
        private let cleanUpTokenizationSpaces: Bool
        private var text = ""
        private var cleanupPipeline = CleanupPipeline()
        private var provisionalCleanedText = ""
        private var heldText = ""
        private var pendingBytes: [UInt8] = []

        init(tokenPiece: @escaping (Int) -> String?, cleanUpTokenizationSpaces: Bool) {
            self.tokenPiece = tokenPiece
            self.cleanUpTokenizationSpaces = cleanUpTokenizationSpaces
        }

        func append(_ token: Int) -> String {
            guard let piece = tokenPiece(token) else { return text }
            if let bytes = Self.byteLevelBytes(piece) {
                pendingBytes.append(contentsOf: bytes)
                let incompleteCount = Self.incompleteUTF8SuffixCount(pendingBytes)
                let stableEnd = pendingBytes.count - incompleteCount
                if stableEnd > 0 {
                    heldText += String(decoding: pendingBytes[..<stableEnd], as: UTF8.self)
                    pendingBytes.removeFirst(stableEnd)
                }
            } else {
                if !pendingBytes.isEmpty {
                    heldText += String(decoding: pendingBytes, as: UTF8.self)
                    pendingBytes.removeAll(keepingCapacity: true)
                }
                heldText += piece
            }

            // Match NaiveStreamingDetokenizer: an incomplete/invalid UTF-8
            // tail is withheld until a later token makes the delta complete.
            if pendingBytes.isEmpty, heldText.last != "\u{fffd}" {
                if cleanUpTokenizationSpaces {
                    appendCleaned(heldText)
                } else {
                    text += heldText
                }
                heldText.removeAll(keepingCapacity: true)
            }
            return text
        }

        private func appendCleaned(_ delta: String) {
            text.removeLast(provisionalCleanedText.count)
            text += cleanupPipeline.append(delta)
            provisionalCleanedText = cleanupPipeline.provisionalText()
            text += provisionalCleanedText
        }

        private static func byteLevelBytes(_ piece: String) -> [UInt8]? {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(piece.unicodeScalars.count)
            for scalar in piece.unicodeScalars {
                guard let byte = byteDecoder[scalar] else { return nil }
                bytes.append(byte)
            }
            return bytes
        }

        private static func incompleteUTF8SuffixCount(_ bytes: [UInt8]) -> Int {
            guard let last = bytes.last, last >= 0x80 else { return 0 }
            var continuationCount = 0
            var index = bytes.count - 1
            while bytes[index] & 0xC0 == 0x80 {
                continuationCount += 1
                guard index > 0 else { return 0 }
                index -= 1
            }
            let expected: Int
            switch bytes[index] {
            case 0xC2...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF4: expected = 4
            default: return 0
            }
            let available = continuationCount + 1
            return available < expected ? available : 0
        }

        private static let byteDecoder: [Unicode.Scalar: UInt8] = {
            var bytes = Array(33...126) + Array(161...172) + Array(174...255)
            var scalars = bytes
            var nextScalar = 256
            for byte in 0...255 where !bytes.contains(byte) {
                bytes.append(byte)
                scalars.append(nextScalar)
                nextScalar += 1
            }
            return Dictionary(uniqueKeysWithValues: zip(scalars, bytes).compactMap { scalar, byte in
                Unicode.Scalar(scalar).map { ($0, UInt8(byte)) }
            })
        }()
    }

    /// A batched streaming row's buyer-visible state (SPEC-038 AC-6c). Serial
    /// tool turns retain per-token emitter precision through the byte-level
    /// incremental decoder; every other row decodes once per delivery event.
    /// Once the serial path would have stopped generating, later tokens are
    /// ignored and the stop point is kept so finalize truncates the row to it.
    final class AttachedPagedKVStreamState: @unchecked Sendable {
        private let lock = NSLock()
        private var tokenIDs: [Int] = []
        private var emitter: SerialStreamingTextEmitter
        private var recordedError: APIError?
        private var stoppedValue = false
        private var serialStopTokenCountValue: Int?
        private let decode: ([Int]) -> String
        private let incrementalDecoder: IncrementalTextDecoder?
        private let needsPerTokenPrecision: Bool

        init(request: ChatCompletionRequest, detokenizer: StreamingDetokenizer) {
            emitter = SerialStreamingTextEmitter(
                request: request,
                holdsCleanupDecoderPendingPrefixes: detokenizer.cleanUpTokenizationSpaces
            )
            decode = detokenizer.decode
            needsPerTokenPrecision = ModelRuntime.serialNativeToolStopApplies(request)
            incrementalDecoder = needsPerTokenPrecision ? detokenizer.makeIncremental() : nil
        }

        /// Returns true the first time the row should stop decoding.
        func step(
            eventTokens: [Int],
            stopTokenFilter: StopTokenFilter,
            requestStops: [String],
            structuredAccumulator: StructuredStreamingContentAccumulator,
            idleState: StructuredStreamingIdleState,
            onChunk: (StreamChunk) -> Void
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !stoppedValue, !eventTokens.isEmpty else { return false }
            for token in eventTokens {
                tokenIDs.append(token)
                if needsPerTokenPrecision,
                   let decoded = incrementalDecoder?.append(token),
                   observe(
                       decoded: decoded,
                       stopTokenFilter: stopTokenFilter,
                       requestStops: requestStops,
                       structuredAccumulator: structuredAccumulator,
                       idleState: idleState,
                       onChunk: onChunk
                   ) {
                    return true
                }
            }
            guard !needsPerTokenPrecision else { return false }
            return observe(
                decoded: decode(tokenIDs),
                stopTokenFilter: stopTokenFilter,
                requestStops: requestStops,
                structuredAccumulator: structuredAccumulator,
                idleState: idleState,
                onChunk: onChunk
            )
        }

        private func observe(
            decoded: String,
            stopTokenFilter: StopTokenFilter,
            requestStops: [String],
            structuredAccumulator: StructuredStreamingContentAccumulator,
            idleState: StructuredStreamingIdleState,
            onChunk: (StreamChunk) -> Void
        ) -> Bool {
            let candidate = ModelRuntime.streamingSafePrefix(
                decoded,
                stopTokenFilter: stopTokenFilter,
                requestStops: requestStops
            )
            switch emitter.step(
                candidate: candidate,
                structuredAccumulator: structuredAccumulator,
                idleState: idleState,
                onChunk: onChunk
            ) {
            case .more, .requestStop:
                // A buyer stop string ends the row through its stop-token
                // sequences, and the final filter cuts the text at it.
                return false
            case .toolCallComplete:
                stoppedValue = true
                serialStopTokenCountValue = tokenIDs.count
                return true
            case .structuredError:
                stoppedValue = true
                if recordedError == nil {
                    recordedError = structuredAccumulator.error
                }
                return true
            }
        }

        func finish(
            finalText: String,
            parsed: ModelRuntime.ParsedGeneratedOutput,
            structuredAccumulator: StructuredStreamingContentAccumulator,
            idleState: StructuredStreamingIdleState,
            onChunk: (StreamChunk) -> Void
        ) throws {
            lock.lock()
            defer { lock.unlock() }
            try emitter.finish(
                finalText: finalText,
                parsed: parsed,
                structuredAccumulator: structuredAccumulator,
                idleState: idleState,
                onChunk: onChunk
            )
        }

        var emittedContent: String {
            lock.lock()
            defer { lock.unlock() }
            return emitter.emittedContent
        }

        var reconciledToolCalls: [ToolCall] {
            lock.lock()
            defer { lock.unlock() }
            return emitter.reconciledToolCalls
        }

        /// Token count at which the serial path would have stopped a serial
        /// tool turn; nil when it would not have stopped early.
        var serialStopTokenCount: Int? {
            lock.lock()
            defer { lock.unlock() }
            return serialStopTokenCountValue
        }

        var hasObservedTokens: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !tokenIDs.isEmpty
        }

        func error() -> APIError? {
            lock.lock()
            defer { lock.unlock() }
            return recordedError
        }
    }

    /// A batched non-streaming serial tool turn (SPEC-038 AC-6c): the serial
    /// non-streaming stop test over each delivered token.
    final class ContinuousBatchSerialToolStopState: @unchecked Sendable {
        private let lock = NSLock()
        private var tokenIDs: [Int] = []
        private var observer: NativeToolCallStreamEmitter
        private let guaranteedSelection: Bool
        private var stopTokenCountValue: Int?
        private let incrementalDecoder: IncrementalTextDecoder

        init(request: ChatCompletionRequest, incrementalDecoder: IncrementalTextDecoder) {
            guaranteedSelection = (try? ToolSelectionPolicy.selection(request.promptSource.toolChoice).requiresCall) == true
            observer = NativeToolCallStreamEmitter(
                modelID: request.model,
                allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
            )
            self.incrementalDecoder = incrementalDecoder
        }

        /// Returns true the first time the row should stop decoding.
        func observe(
            eventTokens: [Int],
            stopTokenFilter: StopTokenFilter,
            requestStops: [String]
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard stopTokenCountValue == nil, !eventTokens.isEmpty else { return false }
            for token in eventTokens {
                tokenIDs.append(token)
                if ModelRuntime.observeSerialToolStop(
                    &observer,
                    decoded: incrementalDecoder.append(token),
                    stopTokenFilter: stopTokenFilter,
                    requestStops: requestStops,
                    guaranteedSelection: guaranteedSelection
                ) {
                    stopTokenCountValue = tokenIDs.count
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
    }

    struct ContinuousBatchFinalizedRow: Sendable {
        /// Not yet structured-validated: the non-streaming caller runs
        /// `validateStructuredCompletion`, the streaming caller first sends
        /// the held-back text and then `validateStructuredStreamingCompletion`,
        /// each exactly as its serial counterpart does.
        let completion: CompletionResult
        let filteredText: String
        let parsed: ParsedGeneratedOutput
        /// Generated tokens the completion accounts for (model EOS dropped,
        /// truncated to the serial stop point).
        let generatedTokens: [Int]
        /// The row decoded past the serial stop point, so its retained cache
        /// covers tokens the completion does not and must not be committed.
        let truncatedAtSerialStop: Bool
    }

    struct ContinuousBatchSubmission: Sendable {
        let requestID: String
        let schedulerRequest: ContinuousBatchSchedulerRequest
    }

    /// Output budget of a batched row: the context left after the prompt
    /// (SPEC-001's omitted-`max_tokens` default), and never more than an
    /// explicit `max_tokens`. A paged row cannot slide its KV window past the
    /// served context the way the serial rotating cache does, so a larger
    /// explicit value is clamped here (reaching it reports `length`) rather
    /// than rejected, and the request stays valid on either path. A prompt
    /// that leaves no room for one output token is the serial 413.
    static func continuousBatchMaxOutputTokens(
        requested: Int?,
        promptTokens: Int,
        maxContextTokens: Int,
        provenance: KVIngestProvenance = .unknown
    ) throws -> Int {
        let remaining = maxContextTokens - promptTokens
        guard remaining >= 1 else {
            try? FileHandle.standardError.write(contentsOf: Data(ContinuousBatchScheduler.contextRejectedTelemetryLine(
                promptTokens: promptTokens,
                maxOutputTokens: 1,
                cap: maxContextTokens,
                provenance: provenance
            ).utf8))
            throw ContinuousBatchSchedulerError.contextLengthExceeded(
                promptTokens: promptTokens,
                maxOutputTokens: 1,
                contextTokens: maxContextTokens
            ).asAPIError()!
        }
        guard let requested else { return remaining }
        return min(requested, remaining)
    }

    /// The single relay-request to scheduler-row mapping used by both live
    /// inference and the durable-replay fixture. Keeping stable identity,
    /// sampling inputs, and conversation identity here makes the fixture fail
    /// if the production mapping changes.
    static func continuousBatchSubmission(
        for request: ChatCompletionRequest,
        promptTokens: [Int],
        maxOutputTokens: Int,
        stopTokenSequences: [[Int]] = [],
        modelStopTokenIDs: [Int] = [],
        cachedPromptTokens: Int = 0,
        retainedPagedKVSequence: PagedKVRetainedSequence? = nil,
        recurrentCheckpointPositions: [Int] = [],
        modelHasRecurrentLayers: Bool = false,
        retainedRecurrentCheckpoints: [RecurrentStateCheckpoint] = [],
        serialToolStopObserver: ContinuousBatchCanonicalStopObserver? = nil,
        nativeMTPAdmission: NativeMTPRuntimeAdmission? = nil
    ) throws -> ContinuousBatchSubmission {
        guard let requestID = schedulerRequestID(for: request) else {
            throw attachedPagedKVUnavailableError(
                code: ContinuousBatchingUnsupportedReason.stableRequestIDUnavailable.apiCode
            )
        }
        return ContinuousBatchSubmission(
            requestID: requestID,
            schedulerRequest: ContinuousBatchSchedulerRequest(
                id: requestID,
                conversationKey: request.conversationKey ?? "",
                promptTokens: promptTokens,
                maxOutputTokens: maxOutputTokens,
                stopTokenSequences: stopTokenSequences,
                modelStopTokenIDs: modelStopTokenIDs,
                samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: requestID),
                temperature: request.temperature,
                topP: request.topP,
                presencePenalty: request.presencePenalty,
                frequencyPenalty: request.frequencyPenalty,
                cachedPromptTokens: cachedPromptTokens,
                retainedPagedKVSequence: retainedPagedKVSequence,
                recurrentCheckpointPositions: recurrentCheckpointPositions,
                modelHasRecurrentLayers: modelHasRecurrentLayers,
                retainedRecurrentCheckpoints: retainedRecurrentCheckpoints,
                serialToolStopObserver: serialToolStopObserver,
                decodePath: nativeMTPAdmission?.effectivePath ?? .ordinary,
                nativeMTPMaximumProposalDepth: nativeMTPAdmission?.initialProposalDepth ?? 0,
                nativeMTPCompleteWindowBytesByDepth: nativeMTPAdmission?.completeWindowBytesByDepth ?? [],
                nativeMTPMaximumActiveRows: nativeMTPAdmission?.maximumNativeActiveRows ?? 0,
                nativeMTPTupleFence: nativeMTPAdmission?.tupleFence,
                ingestProvenance: request.ingestProvenance
            )
        )
    }

    /// Builds the one serial-tool observer owned by the canonical scheduler
    /// row. Its boundary is copied into the scheduler result for every waiter.
    static func continuousBatchSerialToolStopObserver(
        request: ChatCompletionRequest,
        detokenizer: StreamingDetokenizer,
        stopTokenFilter: StopTokenFilter
    ) -> ContinuousBatchCanonicalStopObserver? {
        guard serialNativeToolStopApplies(request) else { return nil }
        let state = ContinuousBatchSerialToolStopState(
            request: request,
            incrementalDecoder: detokenizer.makeIncremental()
        )
        return ContinuousBatchCanonicalStopObserver { token in
            state.observe(
                eventTokens: [token],
                stopTokenFilter: stopTokenFilter,
                requestStops: request.stop
            )
        }
    }

    /// SPEC-038 AC-6c: the one post-generation finalize for a batched row,
    /// streaming and non-streaming. It applies the serial path's response
    /// byte cap, output filters, `parseGeneratedOutput` (tool calls,
    /// SPEC-018 caps, Harmony) and finish-reason rule to the row's text. A
    /// serial tool turn is first truncated to the token at which the serial
    /// path stops generating, so the parsed text and billed tokens match.
    static func finalizeContinuousBatchRow(
        request: ChatCompletionRequest,
        result: ContinuousBatchSchedulerResult,
        modelStopTokenIDs: Set<Int>,
        promptTokenIDs: [Int32],
        decode: ([Int]) -> String,
        stopTokenFilter: StopTokenFilter,
        generationMilliseconds: Int64,
        ttftMilliseconds: Int64? = nil,
        modelHash: String?,
        toolCallPrefill: String?
    ) throws -> ContinuousBatchFinalizedRow {
        // The serial path discards the model's end-of-generation token
        // before counting it; bill and cache the batched row the same way.
        // Harmony `<|return|>`/`<|call|>` are excluded from this set, as
        // they are from the serial stop set: the parser reads and counts them.
        let serialStopTokenCount = result.serialToolStopTokenCount
        var generatedTokens = droppingTrailingModelStop(
            result.generatedTokens,
            terminalStatus: result.terminalStatus,
            modelStopTokenIDs: modelStopTokenIDs
        )
        var completionTokenCount = result.completionTokens
            - (result.generatedTokens.count - generatedTokens.count)
        let postModelStopTokenCount = generatedTokens.count
        var outputTokens = result.outputTokens
        var truncated = false
        if let serialStopTokenCount, serialStopTokenCount < generatedTokens.count {
            completionTokenCount -= generatedTokens.count - serialStopTokenCount
            generatedTokens = Array(generatedTokens.prefix(serialStopTokenCount))
            outputTokens = Array(outputTokens.prefix(serialStopTokenCount))
            truncated = true
        }
        let decoded = decode(outputTokens)
        guard decoded.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
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
            decoded,
            stopTokenFilter: stopTokenFilter,
            requestStops: HarmonyResponseParser.isHarmonyModelID(request.model) ? [] : request.stop
        )
        // `length` when the row ended on an output budget: an explicit
        // max_tokens reached by the post-model-stop, pre-truncation
        // generation, or the scheduler's `.length` terminal for the budget
        // that `continuousBatchMaxOutputTokens` clamped to the served context.
        // The output was cut, so it is not a natural `stop`.
        let lengthTerminal = (
            request.maxTokens.map { postModelStopTokenCount >= $0 } == true
                || result.terminalStatus == .length
        )
            && result.stopCause == nil
            && !truncated
        let requestStopTerminal = result.stopCause == .requestStop || filtered.hitStop
        let parserFinishReason = lengthTerminal && !requestStopTerminal
            ? "length"
            : (requestStopTerminal ? "request_stop" : "stop")
        let parsed = try parseGeneratedOutput(
            filteredText: filtered.text,
            generatedTokenIDs: generatedTokens,
            decode: decode,
            request: request,
            mode: .complete(finishReason: parserFinishReason),
            defaultCompletionTokens: completionTokenCount,
            stopTokenFilter: stopTokenFilter,
            requestStops: request.stop,
            globalHitStop: requestStopTerminal,
            toolCallPrefill: toolCallPrefill
        )
        let finishReason: String
        if !parsed.toolCalls.isEmpty {
            finishReason = "tool_calls"
        } else if lengthTerminal, !requestStopTerminal, !parsed.hitStop {
            finishReason = "length"
        } else {
            finishReason = "stop"
        }
        let kvCacheBytesReused = cachedPromptUTF8Bytes(
            promptTokenIds: promptTokenIDs,
            cachedPromptTokens: result.cachedPromptTokens,
            decode: decode
        )
        return ContinuousBatchFinalizedRow(
            completion: CompletionResult(
                content: parsed.content,
                finishReason: finishReason,
                promptTokens: promptTokenIDs.count,
                cachedPromptTokens: result.cachedPromptTokens,
                kvCacheBytesReused: kvCacheBytesReused,
                completionTokens: parsed.completionTokens,
                generatedCompletionTokens: parsed.generatedCompletionTokens,
                ttftMilliseconds: ttftMilliseconds,
                generationMilliseconds: generationMilliseconds,
                toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                modelHashObserved: validObservedModelHash(modelHash),
                settlementDisposition: result.settlementDisposition
            ),
            filteredText: filtered.text,
            parsed: parsed,
            generatedTokens: generatedTokens,
            truncatedAtSerialStop: truncated
        )
    }

    /// SPEC-038 AC-6c: the batched streaming end, in the serial stream's
    /// order: remaining tool-call deltas and held-back content first, then
    /// the structured verdict on the buyer-visible text.
    static func finishContinuousBatchStream(
        _ finalized: ContinuousBatchFinalizedRow,
        state: AttachedPagedKVStreamState,
        request: ChatCompletionRequest,
        structuredAccumulator: StructuredStreamingContentAccumulator,
        idleState: StructuredStreamingIdleState,
        onChunk: (StreamChunk) -> Void
    ) throws -> CompletionResult {
        try state.finish(
            finalText: finalized.filteredText,
            parsed: finalized.parsed,
            structuredAccumulator: structuredAccumulator,
            idleState: idleState,
            onChunk: onChunk
        )
        let completion = HarmonyResponseParser.isHarmonyModelID(request.model)
            ? finalized.completion
            : finalized.completion
                .withContent(state.emittedContent)
                .withToolCalls(state.reconciledToolCalls)
        return try validateStructuredStreamingCompletion(
            completion,
            request: request,
            buyerVisibleContent: structuredAccumulator.content
        )
    }

    /// SPEC-049-R010. Privacy-class requests never begin a conversation-cache
    /// lease or lookup. A nil lease does not take the serial-route fence.
    static func allowsConversationCacheLease(provenance: KVIngestProvenance, nativeAllows: Bool) -> Bool {
        nativeAllows && provenance.mayUseReusableKVCache
    }

    /// The serial path never runs native MTP. A cache-only row selected
    /// native reaches it after the continuous-batching path declined, most
    /// often on a cache hit the scheduler cannot resume (AC-26). It then takes
    /// the lease the ordinary path would take, so the hit and its discount
    /// survive (SPEC-048-R009).
    static func serialConversationCacheLeaseAllowed(
        request: ChatCompletionRequest,
        admission: NativeMTPRuntimeAdmission
    ) -> Bool {
        !request.containsNonTextMessageContentPart && allowsConversationCacheLease(
            provenance: request.ingestProvenance,
            nativeAllows: admission.allowsConversationCacheLease(cacheOnlyKey: request.conversationCacheOnly)
        )
    }

    private static func nativeMTPCaptureEffectiveMaxOutputTokens(
        request: ChatCompletionRequest,
        completion: CompletionResult,
        maxContextTokens: Int
    ) -> Int? {
        if let requested = request.maxTokens { return requested }
        guard completion.promptTokens > 0 else { return nil }
        return max(1, maxContextTokens - completion.promptTokens)
    }

    private func serialRouteCanaryCachedHitMissingRetainedHandoff(
        _ lease: ConversationCacheLease?,
        capability: ContinuousBatchingCapability,
        modelHasRecurrentLayers: Bool
    ) async throws -> Bool {
        guard let lease,
              let reason = Self.cachedHitFenceReason(
                  mode: capability.mode,
                  cachedPromptTokens: lease.cachedPromptTokens,
                  hasRetainedPagedKVHandoff: Self.leaseHasUsableRetainedHandoff(
                      lease,
                      modelHasRecurrentLayers: modelHasRecurrentLayers
                  ),
                  cachedTurnsEnabled: continuousBatchingCachedTurns,
                  cachedTurnsAccepted: continuousBatchingCachedTurns
                      && continuousBatchingRequestedTuple().map {
                          continuousBatchingAcceptanceCoverage.coversCachedTurns($0)
                      } == true
              )
        else {
            return false
        }
        // A retained entry (hybrid or not) cannot serve the serial path, so
        // this discards it and the serial request misses; a serial-format entry
        // is put back for the serial path to reuse.
        await conversationCache.abortForSerialFallback(lease)
        let blocked = ContinuousBatchingCapability(
            mode: capability.mode,
            maxActiveRows: capability.maxActiveRows,
            queueLimit: capability.queueLimit,
            descriptor: capability.descriptor,
            unsupportedReason: reason
        )
        // Strict `.on` must fail closed with the named reason (FR-CB8). Canary
        // serial-routes the same AC-26 fence with reason-coded telemetry.
        try ContinuousBatchingPolicy.validateStrictStartup(blocked)
        ContinuousBatchingPolicy.logSerialRouteIfNeeded(blocked)
        return true
    }

    static func canaryShouldSerialRouteCachedHitMissingRetainedHandoff(
        mode: ContinuousBatchingMode,
        cachedPromptTokens: Int,
        hasRetainedPagedKVHandoff: Bool,
        cachedTurnsEnabled: Bool = false,
        cachedTurnsAccepted: Bool = false
    ) -> Bool {
        cachedHitFenceReason(
            mode: mode,
            cachedPromptTokens: cachedPromptTokens,
            hasRetainedPagedKVHandoff: hasRetainedPagedKVHandoff,
            cachedTurnsEnabled: cachedTurnsEnabled,
            cachedTurnsAccepted: cachedTurnsAccepted
        ) != nil
    }

    /// AC-26 fence for a positive cached-token hit. It stays out of the
    /// scheduler unless the operator opted into `continuous_batching_cached_turns`,
    /// the lease carries a usable retained handoff, AND the accepted tuple
    /// covering this runtime records `cached_turns_accepted` (the per-tuple,
    /// revision-bound packaged proof). A retained handoff alone is capability,
    /// not authorization. Nil means the request may enter the scheduler.
    static func cachedHitFenceReason(
        mode: ContinuousBatchingMode,
        cachedPromptTokens: Int,
        hasRetainedPagedKVHandoff: Bool,
        cachedTurnsEnabled: Bool,
        cachedTurnsAccepted: Bool
    ) -> ContinuousBatchingUnsupportedReason? {
        guard mode != .off, cachedPromptTokens > 0 else { return nil }
        guard cachedTurnsEnabled, hasRetainedPagedKVHandoff else { return .stickyCacheHandoffUnavailable }
        return cachedTurnsAccepted ? nil : .cachedTurnsNotAccepted
    }

    /// A hybrid retained delivery is resumable only from a recurrent checkpoint;
    /// one without any is discarded instead of committed as an entry no turn
    /// could resume (SPEC-038 AC-26).
    nonisolated static func retainedCacheIsCommittable(
        _ retainedCache: ContinuousBatchRetainedCache,
        modelHasRecurrentLayers: Bool,
        canonicalTokenCount: Int
    ) -> Bool {
        !modelHasRecurrentLayers
            || retainedCache.recurrentCheckpoints.contains { $0.tokenCount == canonicalTokenCount }
    }

    /// A retained paged-KV sequence, plus on a hybrid model the recurrent
    /// checkpoint at exactly the cached length (SPEC-038 AC-26).
    nonisolated static func leaseHasUsableRetainedHandoff(
        _ lease: ConversationCacheLease,
        modelHasRecurrentLayers: Bool
    ) -> Bool {
        guard lease.reusableCache?.retainedPagedKVSequence != nil else { return false }
        guard modelHasRecurrentLayers else { return true }
        return lease.recurrentCheckpoint?.tokenCount == lease.cachedPromptTokens
    }

    /// The stored checkpoints a hybrid cached turn hands the scheduler: every
    /// one at or below the cached length (they are a prefix of this prompt).
    /// Empty unless the lease resumes a retained hybrid entry.
    nonisolated static func retainedRecurrentCheckpoints(
        for lease: ConversationCacheLease?
    ) -> [RecurrentStateCheckpoint] {
        guard let lease,
              lease.recurrentCheckpoint != nil,
              let reusable = lease.reusableCache,
              reusable.retainedPagedKVSequence != nil
        else { return [] }
        return reusable.recurrentCheckpoints.filter { $0.tokenCount <= lease.cachedPromptTokens }
    }

    private func attachedContinuousBatchCompletion(
        request: ChatCompletionRequest,
        snapshot: RuntimeSnapshot,
        capability: ContinuousBatchingCapability,
        nativeMTPAdmission: NativeMTPRuntimeAdmission,
        completionStartedAt: Date,
        shouldCancel: @escaping @Sendable () -> Bool,
        drainCancelled: DrainCancelToken
    ) async throws -> CompletionResult? {
        guard capability.isRequested,
              capability.unsupportedReason == nil,
              !capability.shouldUseSerialPath,
              case .attached = pagedKVAttachDecision
        else {
            return nil
        }
        guard let scheduler = continuousBatchScheduler else {
            throw Self.attachedPagedKVUnavailableError(code: "continuous_batching_scheduler_unavailable")
        }
        guard let schedulerRequestID = Self.schedulerRequestID(for: request) else {
            throw Self.attachedPagedKVUnavailableError(
                code: ContinuousBatchingUnsupportedReason.stableRequestIDUnavailable.apiCode
            )
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        let stopTokenFilter = snapshot.nativeVisionProfile == nil
            ? stopTokenFilter : NativeVisionProfile.stopTokenFilter
        let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
        let templateSupportsPreserveThinking = snapshot.templateSupportsPreserveThinking
        let selectionModelID = toolSelectionModelID(snapshot)
        CBTrace.log(schedulerRequestID, "rt_cb_prepare")
        let (prepared, detokenizer) = try await container.perform { context -> (ContinuousBatchPreparedRequest, StreamingDetokenizer) in
            try drainCancelled.check()
            try Task.checkCancellation()
            let (lmInput, toolCallPrefill) = try await Self.preparedRequestInput(
                for: request,
                context: context,
                templateSupportsThinkingToggle: templateSupportsThinkingToggle,
                templateSupportsPreserveThinking: templateSupportsPreserveThinking,
                toolSelectionModelID: selectionModelID
            )
            let promptTokens = lmInput.text.tokens.asArray(Int32.self).map(Int.init)
            try Self.validatePromptTokenCount(promptTokens.count, maxContextTokens: maxContextTokens)
            let stopTokenSequences = Self.continuousBatchStopTokenSequences(
                requestStops: request.stop,
                context: context
            )
            let tokenizer = context.tokenizer
            // Only keyed requests can hold or reuse conversation state.
            let hybrid = try Self.nonEmpty(request.conversationKey) != nil
                && ConversationCacheLayers.hasRecurrentLayers(context.model.newCache(parameters: nil))
            return (
                ContinuousBatchPreparedRequest(
                    promptTokens: promptTokens,
                    stopTokenSequences: stopTokenSequences,
                    modelStopTokenIDs: Self.generationStopTokenIDs(
                        for: Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
                    ),
                    recurrentCheckpointPositions: Self.continuousBatchRecurrentCheckpointPositions(
                        promptTokens: promptTokens,
                        conversationKey: request.conversationKey,
                        hybrid: hybrid,
                        context: context
                    ),
                    modelHasRecurrentLayers: hybrid,
                    toolCallPrefill: toolCallPrefill
                ),
                StreamingDetokenizer(tokenizer: tokenizer)
            )
        }

        try drainCancelled.check()
        try Task.checkCancellation()
        if shouldCancel() { throw CancellationError() }
        let maxOutputTokens = try Self.continuousBatchMaxOutputTokens(
            requested: request.maxTokens,
            promptTokens: prepared.promptTokens.count,
            maxContextTokens: maxContextTokens,
            provenance: request.ingestProvenance
        )
        let tokenBoundedNativeMTPAdmission = nativeMTPAdmission.resolvingTokenBounds(
            promptTokenCount: prepared.promptTokens.count,
            maxOutputTokens: maxOutputTokens
        )
        recordNativeMTPTokenBoundDowngrade(
            requestID: request.requestID,
            admitted: nativeMTPAdmission,
            resolved: tokenBoundedNativeMTPAdmission
        )
        let preparedPromptTokenIDs = prepared.promptTokens.map(Int32.init)
        let coldContext = coldContext(for: request, snapshot: snapshot)
        let batchKVBits = Self.effectiveKVBits(
            configured: kvBitsOverride,
            conversationKey: request.conversationKey
        )
        let conversationCacheAllowed = Self.allowsConversationCacheLease(
            provenance: request.ingestProvenance,
            nativeAllows: tokenBoundedNativeMTPAdmission.allowsConversationCacheLease(
                cacheOnlyKey: request.conversationCacheOnly
            )
        )
        let lease = conversationCacheAllowed
            ? await conversationCache.begin(
                conversationKey: request.conversationKey,
                incomingTokens: preparedPromptTokenIDs,
                modelID: request.model,
                kvBits: batchKVBits,
                cold: coldContext,
                allowRetainedPagedKVHandoff: true,
                fleetGrant: request.fleetCacheGrant
            )
            : nil
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        recordLabNativeMTPConversationCacheBegin(
            request: request,
            surface: "attached_complete",
            leaseAllowed: conversationCacheAllowed,
            lease: lease,
            modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
        )
        #endif
        CBTrace.log(schedulerRequestID, "rt_cb_lease cached=\(lease?.cachedPromptTokens ?? -1)")
        if conversationCacheAllowed,
           try await serialRouteCanaryCachedHitMissingRetainedHandoff(
            lease,
            capability: capability,
            modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
        ) {
            return nil
        }
        let nativeMTPAdmission = tokenBoundedNativeMTPAdmission.resolvingConversationCacheLease(
            hasConversationKey: Self.nonEmpty(request.conversationKey) != nil,
            leaseAllowed: conversationCacheAllowed,
            cachedPromptTokens: lease?.cachedPromptTokens,
            keyedRowsCommitSerialFormat: prepared.modelHasRecurrentLayers && !continuousBatchingCachedTurns
        )
        CBTrace.log(schedulerRequestID, "rt_native path=\(nativeMTPAdmission.effectivePath.rawValue) reason=\(nativeMTPAdmission.selection.nativeMTPReason?.rawValue ?? "-") cache_only=\(request.conversationCacheOnly)")
        recordNativeMTPTokenBoundDowngrade(
            requestID: request.requestID,
            admitted: tokenBoundedNativeMTPAdmission,
            resolved: nativeMTPAdmission
        )
        // SPEC-038 AC-6c: the scheduler row owns the one canonical serial
        // tool boundary; every duplicate and terminal replay receives it.
        let serialToolStop = Self.continuousBatchSerialToolStopObserver(
            request: request,
            detokenizer: detokenizer,
            stopTokenFilter: stopTokenFilter
        )
        let submission = try Self.continuousBatchSubmission(
            for: request,
            promptTokens: prepared.promptTokens,
            maxOutputTokens: maxOutputTokens,
            stopTokenSequences: prepared.stopTokenSequences,
            modelStopTokenIDs: prepared.modelStopTokenIDs.sorted(),
            cachedPromptTokens: lease?.cachedPromptTokens ?? 0,
            retainedPagedKVSequence: lease?.reusableCache?.retainedPagedKVSequence,
            recurrentCheckpointPositions: prepared.recurrentCheckpointPositions,
            modelHasRecurrentLayers: prepared.modelHasRecurrentLayers,
            retainedRecurrentCheckpoints: Self.retainedRecurrentCheckpoints(for: lease),
            serialToolStopObserver: serialToolStop,
            nativeMTPAdmission: nativeMTPAdmission
        )
        let result: ContinuousBatchSchedulerResult
        do {
            CBTrace.log(schedulerRequestID, "rt_cb_submit")
            // Non-streaming receipts report full generation latency as TTFT
            // (SPEC-015): the buyer sees nothing before the whole body.
            result = try await Self.withDrainAndClientCancellation(drainCancelled, shouldCancel: shouldCancel) {
                try await scheduler.submit(submission.schedulerRequest)
            }
        } catch {
            if let lease {
                await conversationCache.abort(lease)
            }
            // SPEC-038 AC-25: one shared scheduler-error map, so the
            // non-streaming and streaming paths cannot drift.
            CBTrace.log(schedulerRequestID, "rt_cb_threw \(type(of: error))")
            throw (error as? ContinuousBatchSchedulerError)?.asAPIError() ?? error
        }
        CBTrace.log(schedulerRequestID, "rt_cb_returned status=\(result.terminalStatus)")
        do {
            try drainCancelled.check()
            try Task.checkCancellation()
            if shouldCancel() { throw CancellationError() }
            guard result.terminalStatus == .stop || result.terminalStatus == .length else {
                throw Self.terminalFailureError(code: result.errorCode ?? "continuous_batching_request_failed")
            }
            let completionEndedAt = Date()
            let finalized = try await container.perform { context in
                try Self.finalizeContinuousBatchRow(
                    request: request,
                    result: result,
                    modelStopTokenIDs: prepared.modelStopTokenIDs,
                    promptTokenIDs: preparedPromptTokenIDs,
                    decode: { context.tokenizer.decode(tokenIds: $0) },
                    stopTokenFilter: stopTokenFilter,
                    generationMilliseconds: Int64(completionEndedAt.timeIntervalSince(completionStartedAt) * 1000),
                    ttftMilliseconds: nil,
                    modelHash: snapshot.modelHash,
                    toolCallPrefill: prepared.toolCallPrefill
                )
            }
            let completion = try Self.validateStructuredCompletion(finalized.completion, request: request)
            let generatedTokens = finalized.generatedTokens
            let canonicalTokenCount = preparedPromptTokenIDs.count + generatedTokens.count
            if !finalized.truncatedAtSerialStop,
               let lease, let retainedCache = result.retainedCache,
               Self.retainedCacheIsCommittable(
                   retainedCache,
                   modelHasRecurrentLayers: prepared.modelHasRecurrentLayers,
                   canonicalTokenCount: canonicalTokenCount
               ) {
                await conversationCache.commit(
                    lease,
                    cache: ConversationCacheLayers(
                        retainedCache.layers,
                        retainedPagedKVSequence: retainedCache.retainedSequence,
                        discardRetainedPagedKVSequence: { retained, key in
                            await scheduler.discardRetainedCache(retained, conversationKey: key)
                        },
                        recurrentCheckpoints: retainedCache.recurrentCheckpoints
                    ),
                    fullTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init)
                )
                await scheduler.acknowledgeRetainedCacheDelivery(retainedCache)
            } else if !finalized.truncatedAtSerialStop,
                      let lease, let serialCache = result.serialConversationCache,
                      let fullTokens = Self.serialConversationCacheCommitTokens(
                          canonicalTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init),
                          coveredTokenCount: serialCache.tokenCount
                      ) {
                // SPEC-038 FR-CB4 hybrid first turn: the next keyed turn serial-
                // routes (AC-26) and reuses this entry from its checkpoints.
                await conversationCache.commit(
                    lease,
                    cache: ConversationCacheLayers(
                        serialCache.layers,
                        recurrentCheckpoints: serialCache.recurrentCheckpoints
                    ),
                    fullTokens: fullTokens,
                    cold: coldContext
                )
            } else if let retainedCache = result.retainedCache {
                await scheduler.cancelRetainedCacheDelivery(
                    retainedCache,
                    conversationKey: result.conversationKey
                )
                if let lease {
                    await conversationCache.abort(lease)
                }
            } else if let lease {
                await conversationCache.abort(lease)
            }
            nativeMTPRequestShapeCapture?.record(
                request: request,
                snapshot: snapshot,
                admission: nativeMTPAdmission,
                lease: lease,
                leaseAllowed: conversationCacheAllowed,
                completion: completion,
                stream: false,
                resolvedMaxCompletionTokens: maxOutputTokens
            )
            return completion
        } catch {
            if let retainedCache = result.retainedCache {
                await scheduler.cancelRetainedCacheDelivery(
                    retainedCache,
                    conversationKey: result.conversationKey
                )
            }
            if let lease {
                await conversationCache.abort(lease)
            }
            throw error
        }
    }

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    /// Replay stops at the observed output length while preserving the original
    /// request budget used by admission and context validation.
    func installLabNativeMTPDecodeOutputCap(_ cap: NativeMTPLabDecodeOutputCap?) async -> Bool {
        labNativeMTPDecodeOutputCap = cap
        if let continuousBatchScheduler {
            await continuousBatchScheduler.installLabNativeMTPDecodeOutputCap(cap)
        }
        return true
    }

    /// Lab-only R015 hook: record the attached scheduler's in-flight load-gate
    /// decisions. Returns false when no scheduler is attached.
    func installLabNativeMTPLoadGateRecorder(_ recorder: NativeMTPLoadGateRecorder?) async -> Bool {
        guard let continuousBatchScheduler else { return false }
        await continuousBatchScheduler.installLabNativeMTPLoadGateRecorder(recorder)
        return true
    }

    /// Lab-only JOURNEY-NATIVE-MTP-SERVING step-05 hook: force proposal
    /// rejections on matching rows. Returns false when no scheduler is attached.
    func installLabNativeMTPProposalOverride(_ override: NativeMTPLabProposalOverride?) async -> Bool {
        guard let continuousBatchScheduler else { return false }
        await continuousBatchScheduler.installLabNativeMTPProposalOverride(override)
        return true
    }

    /// Lab-only journey hook: install the hidden-state digest observer on the
    /// backend used by this runtime's scheduler.
    func installLabNativeMTPStateDigestObserver(_ observer: NativeMTPStateDigestObserver?) async -> Bool {
        guard let continuousBatchScheduler else { return false }
        return await continuousBatchScheduler.installLabNativeMTPStateDigestObserver(observer)
    }

    /// Lab-only journey hook: inject cancellation at precise native-MTP round
    /// boundaries before backend finalize commits.
    func installLabNativeMTPPhaseTrap(_ trap: NativeMTPLabPhaseTrap?) async -> Bool {
        guard let continuousBatchScheduler else { return false }
        await continuousBatchScheduler.installLabNativeMTPPhaseTrap(trap)
        return true
    }

    /// Lab-only journey hook: inject a failure after buyer-visible native output
    /// so the harness can prove no retry stitching happens.
    func installLabNativeMTPPostoutputFault(_ fault: NativeMTPLabPostoutputFault?) async -> Bool {
        guard let continuousBatchScheduler else { return false }
        await continuousBatchScheduler.installLabNativeMTPPostoutputFault(fault)
        return true
    }

    /// Lab-only replay hook: record commit-time timestamps for buyer-visible
    /// output tokens without exposing token values.
    func installLabNativeMTPCommitTimingObserver(_ observer: NativeMTPLabCommittedTokenTimingObserver?) async -> Bool {
        labNativeMTPCommitTimingObserver = observer
        if let continuousBatchScheduler {
            await continuousBatchScheduler.installLabNativeMTPCommitTimingObserver(observer)
        }
        return true
    }

    /// Lab-only replay hook: record sanitized conversation-cache begin outcomes
    /// for normal runtime paths without exposing raw keys, prompts, or token IDs.
    func installLabNativeMTPConversationCacheObserver(_ observer: NativeMTPLabConversationCacheObserver?) async -> Bool {
        labNativeMTPConversationCacheObserver = observer
        return true
    }

    /// Lab-only journey hook: freeze one exact batch composition before any
    /// prefill/decode work starts. Returns false unless the scheduler is idle.
    func installLabBatchComposition(_ requestIDs: [String]?) async -> Bool {
        guard let continuousBatchScheduler else { return false }
        return await continuousBatchScheduler.installLabBatchComposition(requestIDs)
    }

    /// Lab-only JOURNEY-NATIVE-MTP-SERVING step-10 hook: publish a new
    /// model identity through the same actor path used after warm-swap load
    /// and drain, without contacting the control socket or reloading bytes.
    /// It refuses to run unless real work is in flight, so the journey proves
    /// that the old request's already-captured snapshot survives the same
    /// runtime instance publishing a fresh identity with native-MTP cleared.
    func labCompleteWarmSwapForNativeMTPJourney(
        modelID newModelID: String,
        artifactSHA256: String
    ) async throws -> RuntimeSnapshot {
        let trimmedModelID = newModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else {
            throw LabWarmSwapHookError.invalidTargetIdentity
        }
        guard artifactSHA256.count == 64, artifactSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw LabWarmSwapHookError.invalidTargetIdentity
        }
        guard artifactSHA256 == currentModelHash else {
            throw LabWarmSwapHookError.artifactMismatch
        }
        guard trimmedModelID != currentModelID else {
            throw LabWarmSwapHookError.invalidTargetIdentity
        }
        guard let container = currentContainer else {
            throw LabWarmSwapHookError.containerUnavailable
        }
        guard state == .ready else {
            throw LabWarmSwapHookError.runtimeNotReady(String(describing: state))
        }
        guard !inFlightCancellations.isEmpty else {
            throw LabWarmSwapHookError.noInFlightRequest
        }
        try transitionToLoading(target: trimmedModelID)
        try enterDrainPhase()
        await completeSwapAtomically(
            container: container,
            modelID: trimmedModelID,
            modelHash: artifactSHA256,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: currentWeightsManifestSHA256,
            tokenizerConfigSHA256: currentTokenizerConfigSHA256,
            chatTemplateSHA256: currentChatTemplateSHA256,
            // Same container and artifact bytes: a VLM keeps its profile so the
            // paged-KV skip (#2016) still applies to it.
            nativeVisionProfile: currentNativeVisionProfile,
            draftModelID: nil,
            draftContainer: nil,
            draftFailureReason: nil,
            modelCapabilities: currentPagedKVModelCapabilities,
            adoptionKnobs: nil
        )
        let snapshot = await currentSnapshot()
        guard snapshot.modelID == trimmedModelID, snapshot.modelHash == artifactSHA256 else {
            throw LabWarmSwapHookError.publicationMismatch
        }
        return snapshot
    }

    /// Lab-only token-level probe through the attached scheduler, the same
    /// request shape `native_mtp_selftest_v1` submits: a native integrity
    /// probe at a fixed depth (exempt from the load gate), or an ordinary
    /// greedy row as its oracle. Used to build and replay a self-test
    /// challenge on real hardware without the serve-path startup.
    func labTokenProbe(
        id: String,
        promptTokenIDs: [Int],
        maxCompletionTokens: Int,
        nativeDepth: Int?
    ) async throws -> ContinuousBatchSchedulerResult {
        guard let continuousBatchScheduler else {
            throw ContinuousBatchSchedulerError.requestFailed("lab_probe_scheduler_unavailable")
        }
        if nativeDepth != nil {
            guard currentServedSchedulerSupportsNativeMTP(), currentNativeMTPCapability != nil else {
                throw ContinuousBatchSchedulerError.requestFailed("lab_probe_native_mtp_unavailable")
            }
        }
        let base = ContinuousBatchSchedulerRequest(
            id: id,
            conversationKey: "",
            promptTokens: promptTokenIDs,
            maxOutputTokens: maxCompletionTokens,
            samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: id),
            temperature: 0,
            topP: 1,
            decodePath: nativeDepth == nil ? .ordinary : .nativeMTP,
            nativeMTPMaximumProposalDepth: nativeDepth ?? 0,
            nativeMTPCompleteWindowBytesByDepth: nativeDepth == nil
                ? []
                : (currentNativeMTPCapability?.completeWindowBytesByDepth ?? []),
            nativeMTPTupleFence: nil,
            nativeMTPIntegrityProbe: nativeDepth != nil
        )
        if nativeDepth == nil {
            return try await continuousBatchScheduler.submit(base)
        }
        return try await continuousBatchScheduler.submitNativeMTPIntegrityProbe(base)
    }
    #endif

    nonisolated static func schedulerRequestID(for request: ChatCompletionRequest) -> String? {
        nonEmpty(request.requestID)
    }

    private func attachedContinuousBatchStreamingCompletion(
        request: ChatCompletionRequest,
        snapshot: RuntimeSnapshot,
        capability: ContinuousBatchingCapability,
        nativeMTPAdmission: NativeMTPRuntimeAdmission,
        completionStartedAt: Date,
        shouldCancel: @escaping @Sendable () -> Bool,
        drainCancelled: DrainCancelToken,
        structuredAccumulator: StructuredStreamingContentAccumulator,
        idleState: StructuredStreamingIdleState,
        idleCancellation: DrainCancelToken,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult? {
        guard !request.containsNonTextMessageContentPart else { return nil }
        guard capability.isRequested,
              capability.unsupportedReason == nil,
              !capability.shouldUseSerialPath,
              case .attached = pagedKVAttachDecision
        else {
            return nil
        }
        guard let scheduler = continuousBatchScheduler else {
            throw Self.attachedPagedKVUnavailableError(code: "continuous_batching_scheduler_unavailable")
        }
        guard let schedulerRequestID = Self.schedulerRequestID(for: request) else {
            throw Self.attachedPagedKVUnavailableError(
                code: ContinuousBatchingUnsupportedReason.stableRequestIDUnavailable.apiCode
            )
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        let stopTokenFilter = snapshot.nativeVisionProfile == nil
            ? stopTokenFilter : NativeVisionProfile.stopTokenFilter
        let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
        let templateSupportsPreserveThinking = snapshot.templateSupportsPreserveThinking
        let selectionModelID = toolSelectionModelID(snapshot)
        let requestStops = request.stop
        let (prepared, detokenizer) = try await container.perform { context -> (ContinuousBatchPreparedRequest, StreamingDetokenizer) in
            try drainCancelled.check()
            try Task.checkCancellation()
            let (lmInput, toolCallPrefill) = try await Self.preparedRequestInput(
                for: request,
                context: context,
                templateSupportsThinkingToggle: templateSupportsThinkingToggle,
                templateSupportsPreserveThinking: templateSupportsPreserveThinking,
                toolSelectionModelID: selectionModelID
            )
            let promptTokens = lmInput.text.tokens.asArray(Int32.self).map(Int.init)
            try Self.validatePromptTokenCount(promptTokens.count, maxContextTokens: maxContextTokens)
            let stopTokenSequences = Self.continuousBatchStopTokenSequences(
                requestStops: requestStops,
                context: context
            )
            let tokenizer = context.tokenizer
            // Only keyed requests can hold or reuse conversation state.
            let hybrid = try Self.nonEmpty(request.conversationKey) != nil
                && ConversationCacheLayers.hasRecurrentLayers(context.model.newCache(parameters: nil))
            return (
                ContinuousBatchPreparedRequest(
                    promptTokens: promptTokens,
                    stopTokenSequences: stopTokenSequences,
                    modelStopTokenIDs: Self.generationStopTokenIDs(
                    for: Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
                ),
                    recurrentCheckpointPositions: Self.continuousBatchRecurrentCheckpointPositions(
                        promptTokens: promptTokens,
                        conversationKey: request.conversationKey,
                        hybrid: hybrid,
                        context: context
                    ),
                    modelHasRecurrentLayers: hybrid,
                    toolCallPrefill: toolCallPrefill
                ),
                StreamingDetokenizer(tokenizer: tokenizer)
            )
        }

        try drainCancelled.check()
        try Task.checkCancellation()
        if shouldCancel() { throw CancellationError() }
        let streamState = AttachedPagedKVStreamState(
            request: request,
            detokenizer: detokenizer
        )
        let serialToolStop = Self.continuousBatchSerialToolStopObserver(
            request: request,
            detokenizer: detokenizer,
            stopTokenFilter: stopTokenFilter
        )
        let maxOutputTokens = try Self.continuousBatchMaxOutputTokens(
            requested: request.maxTokens,
            promptTokens: prepared.promptTokens.count,
            maxContextTokens: maxContextTokens,
            provenance: request.ingestProvenance
        )
        let tokenBoundedNativeMTPAdmission = nativeMTPAdmission.resolvingTokenBounds(
            promptTokenCount: prepared.promptTokens.count,
            maxOutputTokens: maxOutputTokens
        )
        recordNativeMTPTokenBoundDowngrade(
            requestID: request.requestID,
            admitted: nativeMTPAdmission,
            resolved: tokenBoundedNativeMTPAdmission
        )
        let preparedPromptTokenIDs = prepared.promptTokens.map(Int32.init)
        let coldContext = coldContext(for: request, snapshot: snapshot)
        let batchKVBits = Self.effectiveKVBits(
            configured: kvBitsOverride,
            conversationKey: request.conversationKey
        )
        let conversationCacheAllowed = Self.allowsConversationCacheLease(
            provenance: request.ingestProvenance,
            nativeAllows: tokenBoundedNativeMTPAdmission.allowsConversationCacheLease(
                cacheOnlyKey: request.conversationCacheOnly
            )
        )
        let lease = conversationCacheAllowed
            ? await conversationCache.begin(
                conversationKey: request.conversationKey,
                incomingTokens: preparedPromptTokenIDs,
                modelID: request.model,
                kvBits: batchKVBits,
                cold: coldContext,
                allowRetainedPagedKVHandoff: true,
                fleetGrant: request.fleetCacheGrant
            )
            : nil
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        recordLabNativeMTPConversationCacheBegin(
            request: request,
            surface: "attached_stream",
            leaseAllowed: conversationCacheAllowed,
            lease: lease,
            modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
        )
        #endif
        if conversationCacheAllowed,
           try await serialRouteCanaryCachedHitMissingRetainedHandoff(
            lease,
            capability: capability,
            modelHasRecurrentLayers: prepared.modelHasRecurrentLayers
        ) {
            return nil
        }
        let nativeMTPAdmission = tokenBoundedNativeMTPAdmission.resolvingConversationCacheLease(
            hasConversationKey: Self.nonEmpty(request.conversationKey) != nil,
            leaseAllowed: conversationCacheAllowed,
            cachedPromptTokens: lease?.cachedPromptTokens,
            keyedRowsCommitSerialFormat: prepared.modelHasRecurrentLayers && !continuousBatchingCachedTurns
        )
        CBTrace.log(schedulerRequestID, "rt_native path=\(nativeMTPAdmission.effectivePath.rawValue) reason=\(nativeMTPAdmission.selection.nativeMTPReason?.rawValue ?? "-") cache_only=\(request.conversationCacheOnly)")
        recordNativeMTPTokenBoundDowngrade(
            requestID: request.requestID,
            admitted: tokenBoundedNativeMTPAdmission,
            resolved: nativeMTPAdmission
        )
        let submission = try Self.continuousBatchSubmission(
            for: request,
            promptTokens: prepared.promptTokens,
            maxOutputTokens: maxOutputTokens,
            stopTokenSequences: prepared.stopTokenSequences,
            modelStopTokenIDs: prepared.modelStopTokenIDs.sorted(),
            cachedPromptTokens: lease?.cachedPromptTokens ?? 0,
            retainedPagedKVSequence: lease?.reusableCache?.retainedPagedKVSequence,
            recurrentCheckpointPositions: prepared.recurrentCheckpointPositions,
            modelHasRecurrentLayers: prepared.modelHasRecurrentLayers,
            retainedRecurrentCheckpoints: Self.retainedRecurrentCheckpoints(for: lease),
            serialToolStopObserver: serialToolStop,
            nativeMTPAdmission: nativeMTPAdmission
        )
        let result: ContinuousBatchSchedulerResult
        let firstTokenClock = ContinuousBatchFirstTokenClock()
        do {
            // The SPEC-019 structured idle timeout ends the row as it ends the
            // serial generate loop.
            result = try await Self.withDrainAndClientCancellation(
                drainCancelled,
                shouldCancel: { shouldCancel() || idleCancellation.isFired }
            ) {
                try await scheduler.submit(submission.schedulerRequest, tokenSink: { event in
                    guard !drainCancelled.isFired,
                          !shouldCancel(),
                          !idleCancellation.isFired
                    else {
                        Task { await scheduler.stopEarly(requestID: schedulerRequestID) }
                        return
                    }
                    // Receipt TTFT is the first buyer-visible chunk this row
                    // emits, after stop/UTF-8/tool filtering. A duplicate or
                    // replay waiter's catch-up events never define it.
                    if streamState.step(
                        eventTokens: event.replayTokens ?? [event.token],
                        stopTokenFilter: stopTokenFilter,
                        requestStops: requestStops,
                        structuredAccumulator: structuredAccumulator,
                        idleState: idleState,
                        onChunk: firstTokenClock.markingFirstChunk(replay: event.replayTokens != nil, onChunk)
                    ) {
                        Task { await scheduler.stopEarly(requestID: schedulerRequestID) }
                    }
                })
            }
        } catch {
            if let lease {
                await conversationCache.abort(lease)
            }
            // SPEC-038 AC-25: one shared scheduler-error map, so the
            // streaming and non-streaming paths cannot drift.
            throw (error as? ContinuousBatchSchedulerError)?.asAPIError() ?? error
        }
        do {
            if let error = streamState.error() {
                throw error
            }
            try drainCancelled.check()
            try Task.checkCancellation()
            if shouldCancel() { throw CancellationError() }
            guard result.terminalStatus == .stop || result.terminalStatus == .length else {
                throw Self.terminalFailureError(
                    code: result.errorCode ?? "continuous_batching_request_failed",
                    streamedTokens: result.emittedTokens
                )
            }
            let completionEndedAt = Date()
            let finalized = try await container.perform { context in
                try Self.finalizeContinuousBatchRow(
                    request: request,
                    result: result,
                    modelStopTokenIDs: prepared.modelStopTokenIDs,
                    promptTokenIDs: preparedPromptTokenIDs,
                    decode: { context.tokenizer.decode(tokenIds: $0) },
                    stopTokenFilter: stopTokenFilter,
                    generationMilliseconds: Int64(completionEndedAt.timeIntervalSince(completionStartedAt) * 1000),
                    ttftMilliseconds: firstTokenClock.ttftMilliseconds(since: completionStartedAt),
                    modelHash: snapshot.modelHash,
                    toolCallPrefill: prepared.toolCallPrefill
                )
            }
            // A terminal replay returns the retained result without token
            // events. Re-run its canonical finalized prefix through the same
            // token-by-token emitter so buyer-visible text and tool deltas
            // match the original waiter before the terminal event is sent.
            if !streamState.hasObservedTokens {
                _ = streamState.step(
                    eventTokens: finalized.generatedTokens,
                    stopTokenFilter: stopTokenFilter,
                    requestStops: requestStops,
                    structuredAccumulator: structuredAccumulator,
                    idleState: idleState,
                    onChunk: onChunk
                )
            }
            // #1690 E2E-F13: the stream held back an incomplete UTF-8 tail
            // and any stop-string prefix; the serial stream's end sends the
            // remainder as the final text renders it, so the buyer's bytes
            // equal the receipt's.
            // The final flush can carry the first buyer-visible chunk when
            // filtering held all earlier output back, so it marks the clock
            // too and receipt TTFT is read only after it.
            var validated = try Self.finishContinuousBatchStream(
                finalized,
                state: streamState,
                request: request,
                structuredAccumulator: structuredAccumulator,
                idleState: idleState,
                onChunk: firstTokenClock.markingFirstChunk(replay: false, onChunk)
            )
            if validated.ttftMilliseconds == nil {
                validated.ttftMilliseconds = firstTokenClock.ttftMilliseconds(since: completionStartedAt)
            }
            let generatedTokens = finalized.generatedTokens
            let canonicalTokenCount = preparedPromptTokenIDs.count + generatedTokens.count
            if !finalized.truncatedAtSerialStop,
               let lease, let retainedCache = result.retainedCache,
               Self.retainedCacheIsCommittable(
                   retainedCache,
                   modelHasRecurrentLayers: prepared.modelHasRecurrentLayers,
                   canonicalTokenCount: canonicalTokenCount
               ) {
                await conversationCache.commit(
                    lease,
                    cache: ConversationCacheLayers(
                        retainedCache.layers,
                        retainedPagedKVSequence: retainedCache.retainedSequence,
                        discardRetainedPagedKVSequence: { retained, key in
                            await scheduler.discardRetainedCache(retained, conversationKey: key)
                        },
                        recurrentCheckpoints: retainedCache.recurrentCheckpoints
                    ),
                    fullTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init)
                )
                await scheduler.acknowledgeRetainedCacheDelivery(retainedCache)
            } else if !finalized.truncatedAtSerialStop,
                      let lease, let serialCache = result.serialConversationCache,
                      let fullTokens = Self.serialConversationCacheCommitTokens(
                          canonicalTokens: preparedPromptTokenIDs + generatedTokens.map(Int32.init),
                          coveredTokenCount: serialCache.tokenCount
                      ) {
                // SPEC-038 FR-CB4 hybrid first turn: the next keyed turn serial-
                // routes (AC-26) and reuses this entry from its checkpoints.
                await conversationCache.commit(
                    lease,
                    cache: ConversationCacheLayers(
                        serialCache.layers,
                        recurrentCheckpoints: serialCache.recurrentCheckpoints
                    ),
                    fullTokens: fullTokens,
                    cold: coldContext
                )
            } else if let retainedCache = result.retainedCache {
                await scheduler.cancelRetainedCacheDelivery(
                    retainedCache,
                    conversationKey: result.conversationKey
                )
                if let lease {
                    await conversationCache.abort(lease)
                }
            } else if let lease {
                await conversationCache.abort(lease)
            }
            nativeMTPRequestShapeCapture?.record(
                request: request,
                snapshot: snapshot,
                admission: nativeMTPAdmission,
                lease: lease,
                leaseAllowed: conversationCacheAllowed,
                completion: validated,
                stream: true,
                resolvedMaxCompletionTokens: maxOutputTokens
            )
            return validated
        } catch {
            if let retainedCache = result.retainedCache {
                await scheduler.cancelRetainedCacheDelivery(
                    retainedCache,
                    conversationKey: result.conversationKey
                )
            }
            if let lease {
                await conversationCache.abort(lease)
            }
            throw error
        }
    }

    /// SPEC-038 AC-25: a non-terminal scheduler *result*, as distinct from a
    /// thrown scheduler error. Most carried codes are pre-inference, so they
    /// take the `inferenceRan: false` shape. Post-token delivery backpressure
    /// reuses the single `.deliveryBackpressure` mapping. Any other failure
    /// after a stream already delivered tokens (a decode window streams per
    /// step, so a forward, sampling or stream-mismatch failure can follow
    /// visible output) is also post-inference and not retryable: a retry
    /// would re-run work the buyer partly received.
    nonisolated static func terminalFailureError(code: String, streamedTokens: Int = 0) -> APIError {
        if code == ContinuousBatchSchedulerError.deliveryBackpressureCode,
           let mapped = ContinuousBatchSchedulerError.deliveryBackpressure.asAPIError() {
            return mapped
        }
        guard streamedTokens > 0 else {
            return attachedPagedKVUnavailableError(code: code)
        }
        return APIError(
            status: 503,
            message: "Inference engine unavailable",
            type: "server_error",
            code: code,
            retryable: false,
            inferenceRan: true,
            settlementRan: false
        )
    }

    private nonisolated static func attachedPagedKVUnavailableError(code: String) -> APIError {
        APIError(
            status: 503,
            message: "Inference engine unavailable",
            type: "server_error",
            code: code,
            inferenceRan: false,
            settlementRan: false
        )
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
                let parameters = try Self.makeServeGenerateParameters(
                                        model: context.model,
maxTokens: boundedMaxTokens,
                    promptTokens: lmInput.text.tokens.size,
                    maxContextTokens: maxContextTokens,
                    kvBitsOverride: kvBitsOverride,
                    prefillStepSize: prefillStepSize,
                    temperature: 0.0,
                    topP: 1.0
                )
                let kvCache = try context.model.newCache(parameters: parameters)
                let iterator = try TokenIterator(
                    input: lmInput, model: context.model, cache: kvCache,
                    parameters: Self.explicitCacheIteratorParameters(parameters, cache: kvCache))
                return try await blockingInferenceExecutor.run { inferenceCancellation in
                    BlockingGenerateResult(generate(input: lmInput, context: context, iterator: iterator) { tokens in
                        if !tokens.isEmpty {
                            firstToken.recordIfMissing()
                            ModelLivenessTracker.shared.recordProgress()
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
        try ToolSelectionPolicy.validateRequest(request, loadedModelID: toolSelectionModelID(handle.snapshot), runtime: "mlx_cache")
        _ = try Self.validateNativeVisionRequest(request, profile: handle.snapshot.nativeVisionProfile)
        // SPEC-025 §5.2 model-liveness: mark active buyer inference so a stalled
        // progress token is interpretable as a wedge (observability only).
        ModelLivenessTracker.shared.beginInference()
        defer { ModelLivenessTracker.shared.endInference() }
        let completionStartedAt = Date()
        let snapshot = handle.snapshot
        let drainCancelled = handle.drainCancelled
        // Non-streaming execution is a direct entry path with no preceding
        // preflight (HTTP + relay), so it OWNS the single serial-route telemetry
        // emission for this request. (Streaming preflights first and suppresses
        // here to stay exactly-once.)
        let continuousBatchingCapability = try applyContinuousBatchingPolicy(
            request: request,
            snapshot: snapshot,
            emitTelemetry: true
        )
        let nativeMTPAdmission = nativeMTPRuntimeAdmission(for: request, snapshot: snapshot, handle: handle)
        if !request.containsNonTextMessageContentPart {
            try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
        }
        try drainCancelled.check()
        CBTrace.log(request.requestID, "rt_complete_enter")
        if !request.containsNonTextMessageContentPart,
           let completion = try await attachedContinuousBatchCompletion(
            request: request,
            snapshot: snapshot,
            capability: continuousBatchingCapability,
            nativeMTPAdmission: nativeMTPAdmission,
            completionStartedAt: completionStartedAt,
            shouldCancel: shouldCancel,
            drainCancelled: drainCancelled
        ) {
            return (completion, snapshot)
        }
        CBTrace.log(request.requestID, "rt_serial_path")
        if speculativeCacheWrapValidated,
           let testSpeculativeCompletion,
           Self.speculativeRoute(
               for: request,
               draftLoaded: snapshot.hasTargetCompatibleDraft,
               numDraftTokens: snapshot.numDraftTokens
           ) == .speculative {
            do {
                let result = try await Self.withDrainCancellation(drainCancelled) {
                    try await testSpeculativeCompletion(snapshot, request)
                }
                let completion = try Self.validateStructuredCompletion(result, request: request)
                    .withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash))
                self.nativeMTPRequestShapeCapture?.record(
                    request: request,
                    snapshot: snapshot,
                    admission: nativeMTPAdmission,
                    lease: nil as ConversationCacheLease?,
                    leaseAllowed: false,
                    completion: completion,
                    stream: false,
                    resolvedMaxCompletionTokens: Self.nativeMTPCaptureEffectiveMaxOutputTokens(
                        request: request,
                        completion: completion,
                        maxContextTokens: maxContextTokens
                    )
                )
                return (completion, snapshot)
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
            let completion = try Self.validateStructuredCompletion(result, request: request)
                .withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash))
            self.nativeMTPRequestShapeCapture?.record(
                request: request,
                snapshot: snapshot,
                admission: nativeMTPAdmission,
                lease: nil as ConversationCacheLease?,
                leaseAllowed: false,
                completion: completion,
                stream: false,
                resolvedMaxCompletionTokens: Self.nativeMTPCaptureEffectiveMaxOutputTokens(
                    request: request,
                    completion: completion,
                    maxContextTokens: maxContextTokens
                )
            )
            return (completion, snapshot)
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        let labSerialHooks = try Self.labSerialDecodeHooks(
            requestID: request.requestID,
            outputCap: labNativeMTPDecodeOutputCap,
            timingObserver: labNativeMTPCommitTimingObserver
        )
        let labConversationCacheObserver = labNativeMTPConversationCacheObserver
        #else
        let labSerialHooks: LabSerialDecodeHooks? = nil
        #endif
        if labSerialHooks != nil, HarmonyResponseParser.isHarmonyModelID(request.model) {
            throw Self.labSerialDecodeHookUnsupported("harmony_visible_prefix_accounting")
        }

        let maxContextTokens = maxContextTokens
        let kvBitsOverride = Self.effectiveKVBits(
            configured: kvBitsOverride,
            conversationKey: request.conversationKey,
            containsImage: request.containsNonTextMessageContentPart
        )
        let speculativeCacheWrapValidated = speculativeCacheWrapValidated
        let prefillStepSize = Self.effectivePrefillStepSize(
            configured: prefillStepSize, containsImage: request.containsNonTextMessageContentPart)
        let isLocalRequest = localRegistrationIDs.contains(handle.registrationID)
        let conversationCache = conversationCache
        // SPEC-037 stage 5 — per-request cold-tier context, captured before the
        // nonisolated inference closure (nil unless the disk tier is attached).
        let coldContext = coldContext(for: request, snapshot: snapshot)
        let inferenceGate = inferenceGate
        let blockingInferenceExecutor = blockingInferenceExecutor
        let stopTokenFilter = snapshot.nativeVisionProfile == nil
            ? stopTokenFilter : NativeVisionProfile.stopTokenFilter
        let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
        let templateSupportsPreserveThinking = snapshot.templateSupportsPreserveThinking
        let selectionModelID = toolSelectionModelID(snapshot)
        let completion = try await Self.withDrainCancellation(drainCancelled) {
            try await inferenceGate.withPermit {
                try drainCancelled.check()
                try Task.checkCancellation()
                return try await container.perform { context in
                    try drainCancelled.check()
                    try Task.checkCancellation()
                    let (lmInput, toolCallPrefill) = try await Self.preparedRequestInput(
                        for: request,
                        context: context,
                        templateSupportsThinkingToggle: templateSupportsThinkingToggle,
                        templateSupportsPreserveThinking: templateSupportsPreserveThinking,
                        nativeVisionProfile: snapshot.nativeVisionProfile,
                        toolSelectionModelID: selectionModelID
                    )
                    // Cancelled during preparation (client gone, or local
                    // work preempted under SPEC-001-R011): release the gate.
                    try Task.checkCancellation()
                    try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
                    // The request's completion budget as served: unchanged for
                    // a capped serve cache, clamped to the remaining context
                    // for a model that sizes its own cache.
                    let servedRequestMaxTokens = try Self.serialMaxOutputTokens(
                        model: context.model,
                        requested: request.maxTokens,
                        promptTokens: lmInput.text.tokens.size,
                        maxContextTokens: maxContextTokens
                    )
                    let parameters = try Self.makeServeGenerateParameters(
                                                model: context.model,
maxTokens: Self.labSerialEffectiveMaxTokens(
                            requestMaxTokens: servedRequestMaxTokens,
                            labOutputCap: labSerialHooks?.outputCap
                        ),
                        promptTokens: lmInput.text.tokens.size,
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
                       let numDraftTokens = snapshot.numDraftTokens,
                       speculativeCacheWrapValidated,
                       labSerialHooks == nil,
                       !isLocalRequest,
                       Self.speculativeCacheWindowSafe(
                           promptTokens: promptTokenIds.count,
                           maxTokens: request.maxTokens,
                           maxContextTokens: maxContextTokens,
                           numDraftTokens: numDraftTokens
                       ) {
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
                    let conversationCacheAllowed = Self.serialConversationCacheLeaseAllowed(
                        request: request,
                        admission: nativeMTPAdmission
                    )
                    let lease = conversationCacheAllowed
                        ? await conversationCache.begin(
                            conversationKey: request.conversationKey,
                            incomingTokens: promptTokenIds,
                            modelID: request.model,
                            kvBits: kvBitsOverride,
                            cold: coldContext,
                            fleetGrant: request.fleetCacheGrant
                        )
                        : nil
                    #if DEBUG || MACPROVIDER_LAB_HARNESS
                    if let labConversationCacheObserver {
                        labConversationCacheObserver.record(NativeMTPLabConversationCacheObserver.event(
                            requestID: request.requestID,
                            surface: "serial_complete",
                            keyPresent: Self.nonEmpty(request.conversationKey) != nil,
                            cacheOnly: request.conversationCacheOnly,
                            leaseAllowed: conversationCacheAllowed,
                            lease: lease,
                            modelHasRecurrentLayers: try ConversationCacheLayers.hasRecurrentLayers(context.model.newCache(parameters: nil))
                        ))
                    }
                    #endif
                        do {
                            let generationContext = Self.harmonyTerminalPreservingContext(from: context, modelID: request.model)
                            let kvCache: [KVCache]
                            var iteratorInput: LMInput
                            let forceSimpleKV = Self.forceSimpleKVCache(
                                eligible: coldContext?.eligible == true,
                                conversationKey: request.conversationKey,
                                containsImage: request.containsNonTextMessageContentPart)
                            if let reusableCache = lease?.reusableCache, let lcp = lease?.lcp {
                                kvCache = reusableCache.layers
                                iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[lcp...])))
                            } else {
                                // SPEC-037 FR-KVP1 / SPEC-024-R001: eligible persist and
                                // keyed serial reuse allocate KVCacheSimple; keyless traffic
                                // keeps the rotating cap.
                                kvCache = try Self.serveCache(
                                    model: generationContext.model, baseParameters: parameters,
                                    forceSimpleKV: forceSimpleKV)
                                iteratorInput = lmInput
                            }
                            let recurrent = Self.prefillRecurrentCheckpoints(
                                lease: lease, cache: kvCache, promptTokenIds: promptTokenIds,
                                context: generationContext, prefillStepSize: prefillStepSize)
                            if let resumeAt = recurrent.resumeAt {
                                iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[resumeAt...])))
                            }
                            if isLocalRequest, !request.containsNonTextMessageContentPart {
                                // SPEC-001-R011: a local prompt prefills in chunks with a
                                // preemption check before each, so a buyer never waits on a
                                // long local prefill. Buyer prefill is unchanged.
                                let start = promptTokenIds.count - iteratorInput.text.tokens.size
                                let resumeAt = try Self.cancellableLocalPrefill(
                                    tokenCount: promptTokenIds.count, from: start, stepSize: prefillStepSize,
                                    isCancelled: { Task.isCancelled || shouldCancel() || drainCancelled.isFired }
                                ) { range in
                                    let chunk = LMInput.Text(tokens: MLXArray(Array(promptTokenIds[range])))
                                    _ = generationContext.model(chunk[text: .newAxis], cache: kvCache, state: nil)
                                    eval(kvCache)
                                }
                                if resumeAt > start {
                                    iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[resumeAt...])))
                                }
                            }

                            let iterator = try TokenIterator(
                                input: iteratorInput, model: generationContext.model, cache: kvCache,
                                parameters: Self.serveIteratorParameters(
                                    parameters, forceSimpleKV: forceSimpleKV, reusedCache: lease?.reusableCache != nil,
                                    cache: kvCache))
                            Self.clearMLXBufferCacheAfterPrefill()
                            var serialToolObserver = NativeToolCallStreamEmitter(
                                modelID: request.model,
                                allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools)
                            )
                            let serialToolStopApplies = Self.serialToolStopApplies(request)
                            #if DEBUG || MACPROVIDER_LAB_HARNESS
                            let labCommitTracker = labSerialHooks.map {
                                LabSerialCommitTracker(requestID: $0.requestID, observer: $0.timingObserver)
                            }
                            #else
                            let labCommitTracker: LabSerialCommitTracker? = nil
                            #endif
                            var labSerialHookError: APIError?
                            var requestStopObservationError: APIError?
                            var stoppedByRequestStop = false
                            let isHarmonyResponse = HarmonyResponseParser.isHarmonyModelID(request.model)
                            var harmonyFinalDetokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
                            var requestStopObserver = Self.SerialDecodeRequestStopObserver(
                                modelID: request.model,
                                stopTokenFilter: stopTokenFilter,
                                requestStops: request.stop,
                                allowedFunctionNames: Self.toolFunctionNames(from: request.promptSource.tools),
                                decode: { context.tokenizer.decode(tokenIds: $0) },
                                decodeFinalToken: { tokenID in
                                    harmonyFinalDetokenizer.append(token: tokenID)
                                    return harmonyFinalDetokenizer.next()
                                }
                            )
                            let result: BlockingGenerateResult = try await blockingInferenceExecutor.run { inferenceCancellation in
                                BlockingGenerateResult(generate(input: iteratorInput, context: generationContext, iterator: iterator) { tokens in
                                    if !tokens.isEmpty {
                                        firstToken.recordIfMissing()
                                        ModelLivenessTracker.shared.recordProgress()
                                    }
                                    if Task.isCancelled || inferenceCancellation.isCancelled || shouldCancel() || drainCancelled.isFired {
                                        return GenerateDisposition.stop
                                    }
                                    do {
                                        if try requestStopObserver.observe(generatedTokenIDs: tokens) {
                                            stoppedByRequestStop = true
                                            return GenerateDisposition.stop
                                        }
                                    } catch let error as APIError {
                                        requestStopObservationError = error
                                        return GenerateDisposition.stop
                                    } catch {
                                        requestStopObservationError = Self.malformedHarmonyResponseError()
                                        return GenerateDisposition.stop
                                    }
                                    if isHarmonyResponse,
                                       tokens.last.map(Self.isHarmonyTerminalToken) == true {
                                        return GenerateDisposition.stop
                                    }
                                    if let labSerialHooks, let labCommitTracker {
                                        let outputCount: Int
                                        do {
                                        outputCount = try Self.labSerialVisibleCommitCount(
                                            modelID: request.model,
                                            generatedTokenIDs: tokens,
                                            decodedText: generationContext.tokenizer.decode(tokenIds: tokens),
                                            emittedText: nil,
                                            stopTokenFilter: stopTokenFilter,
                                            requestStops: request.stop
                                        )
                                        } catch let error as APIError {
                                            labSerialHookError = error
                                            return GenerateDisposition.stop
                                        } catch {
                                            labSerialHookError = Self.labSerialDecodeHookUnsupported("visible_prefix_accounting")
                                            return GenerateDisposition.stop
                                        }
                                        labCommitTracker.record(outputCount: outputCount)
                                        if let outputCap = labSerialHooks.outputCap, outputCount >= outputCap {
                                            return GenerateDisposition.stop
                                        }
                                    }
                                    if serialToolStopApplies,
                                       Self.observeSerialToolStop(
                                           &serialToolObserver,
                                           decoded: generationContext.tokenizer.decode(tokenIds: tokens),
                                           stopTokenFilter: stopTokenFilter,
                                           requestStops: request.stop,
                                           guaranteedSelection: (try? ToolSelectionPolicy.selection(request.promptSource.toolChoice).requiresCall) == true
                                       )
                                    {
                                        return GenerateDisposition.stop
                                    }
                                    return GenerateDisposition.more
                                })
                            }
                            try drainCancelled.check()
                            try Task.checkCancellation()
                            if let labSerialHookError {
                                throw labSerialHookError
                            }
                            if let requestStopObservationError {
                                throw requestStopObservationError
                            }
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
                            requestStops: HarmonyResponseParser.isHarmonyModelID(request.model) ? [] : request.stop
                        )

                        let rawLengthFinish = Self.labSerialLengthFinish(
                            generatedCompletionTokens: result.generationTokenCount,
                            requestMaxTokens: servedRequestMaxTokens,
                            labOutputCap: labSerialHooks?.outputCap
                        )
                        let harmonyTerminalFinish = Self.isHarmonyTerminalFinish(
                            modelID: request.model,
                            generatedTokenIDs: resultTokenIDs
                        )
                        let parserFinishReason = HarmonyResponseParser.isHarmonyModelID(request.model)
                            ? (rawLengthFinish && !filtered.hitStop && !stoppedByRequestStop && !harmonyTerminalFinish ? "length" : ((filtered.hitStop || stoppedByRequestStop) ? "request_stop" : "stop"))
                            : (rawLengthFinish && !filtered.hitStop && !stoppedByRequestStop ? "length" : ((filtered.hitStop || stoppedByRequestStop) ? "request_stop" : "stop"))
                        let parsed = try Self.parseGeneratedOutput(
                            filteredText: filtered.text,
                            generatedTokenIDs: resultTokenIDs,
                            decode: { context.tokenizer.decode(tokenIds: $0) },
                            request: request,
                            mode: .complete(finishReason: parserFinishReason),
                            defaultCompletionTokens: result.generationTokenCount,
                            stopTokenFilter: stopTokenFilter,
                            requestStops: request.stop,
                            globalHitStop: filtered.hitStop || stoppedByRequestStop,
                            toolCallPrefill: toolCallPrefill
                        )
                        let finishReason: String
                        if !parsed.toolCalls.isEmpty {
                            finishReason = "tool_calls"
                        } else if rawLengthFinish, !filtered.hitStop, !stoppedByRequestStop, !parsed.hitStop, !harmonyTerminalFinish {
                            finishReason = "length"
                        } else {
                            finishReason = "stop"
                        }
                        let terminalModelStopStripped = Self.serialTerminalModelStopStripped(
                            rawLengthFinish: rawLengthFinish,
                            hitStop: filtered.hitStop || stoppedByRequestStop,
                            parsedHitStop: parsed.hitStop,
                            harmonyTerminalFinish: harmonyTerminalFinish,
                            stoppedBySerialToolCall: serialToolStopApplies
                                && serialToolObserver.hasCompletedValidToolCall
                        )

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
                            modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
                            settlementDisposition: .eligibleOwner
                        ), request: request)
                        self.nativeMTPRequestShapeCapture?.record(
                            request: request,
                            snapshot: snapshot,
                            admission: nativeMTPAdmission,
                            lease: lease,
                            leaseAllowed: conversationCacheAllowed,
                            completion: completion,
                            stream: false,
                            resolvedMaxCompletionTokens: request.maxTokens ?? max(1, maxContextTokens - promptTokenIds.count)
                        )
                        if let lease {
                            let fullTokens = promptTokenIds + resultTokenIDs.map(Int32.init)
                            guard Self.serialHybridCacheCanPublishTerminalCheckpoint(
                                cache: kvCache,
                                terminalModelStopStripped: terminalModelStopStripped
                            ) else {
                                await conversationCache.abort(lease)
                                return completion
                            }
                            guard let recurrentCheckpoints = Self.serialTerminalRecurrentCheckpoints(
                                promptCheckpoints: recurrent.checkpoints,
                                cache: kvCache,
                                tokenCount: fullTokens.count
                            ) else {
                                await conversationCache.abort(lease)
                                return completion
                            }
                            await conversationCache.commit(
                                lease,
                                cache: ConversationCacheLayers(kvCache, recurrentCheckpoints: recurrentCheckpoints),
                                fullTokens: fullTokens,
                                cold: coldContext
                            )
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
        // Speculative decoding requires tool_choice absent: no call prefill.
        let parsed = try parseToolCallsIfRequested(filtered.text, request: request, toolCallPrefill: nil)
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
            settlementDisposition: .eligibleOwner,
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
                    let draftCache = try draftContext.model.newCache(parameters: parameters)
                    var iterator = try SpeculativeTokenIterator(
                        input: input,
                        mainModel: targetContext.model,
                        draftModel: draftContext.model,
                        mainCache: cache,
                        draftCache: draftCache,
                        parameters: parameters,
                        numDraftTokens: numDraftTokens
                    )
                    Self.clearMLXBufferCacheAfterPrefill()
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
                        ModelLivenessTracker.shared.recordProgress()
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

    /// Stop sequences for a batched row: the model's end-of-generation
    /// tokens plus the buyer's `stop` strings. The scheduler stops a row only
    /// on these, so omitting the model EOS set made every batched row run to
    /// `max_tokens` and emit text past the end of the answer, where the serial
    /// path stops on `generationStopTokenIDs`.
    static func continuousBatchStopTokenSequences(
        requestStops: [String],
        context: ModelContext
    ) -> [[Int]] {
        let modelStops = generationStopTokenIDs(for: context).sorted().map { [$0] }
        let buyerStops = requestStops.map {
            context.tokenizer.encode(text: $0, addSpecialTokens: false)
        }.filter { !$0.isEmpty }
        return modelStops + buyerStops
    }

    static func droppingTrailingModelStop(
        _ generatedTokens: [Int],
        terminalStatus: ContinuousBatchSchedulerTerminalStatus,
        modelStopTokenIDs: Set<Int>
    ) -> [Int] {
        guard terminalStatus == .stop,
              let last = generatedTokens.last,
              modelStopTokenIDs.contains(last) else {
            return generatedTokens
        }
        return Array(generatedTokens.dropLast())
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
        try ToolSelectionPolicy.validateRequest(request, loadedModelID: toolSelectionModelID(handle.snapshot), runtime: "mlx_cache")
        _ = try Self.validateNativeVisionRequest(request, profile: handle.snapshot.nativeVisionProfile)
        if try ToolSelectionPolicy.selection(request.promptSource.toolChoice).holdsOutput {
            let (completion, _) = try await completeWithServedSnapshot(request, with: handle, shouldCancel: shouldCancel)
            try handle.drainCancelled.check()
            try Task.checkCancellation()
            if shouldCancel() { throw CancellationError() }
            let validated = try Self.validateStructuredCompletion(completion, request: request)
            if let calls = validated.toolCalls, !calls.isEmpty {
                for (index, call) in calls.enumerated() {
                    try handle.drainCancelled.check()
                    if shouldCancel() { throw CancellationError() }
                    onChunk(.toolCallDelta(StreamToolCallDelta(index: index, id: call.id, type: "function", functionName: call.functionName, arguments: call.arguments)))
                }
            } else if !validated.content.isEmpty {
                onChunk(.content(validated.content))
            }
            return validated
        }
        // SPEC-025 §5.2 model-liveness: mark active buyer inference so a stalled
        // progress token is interpretable as a wedge (observability only).
        ModelLivenessTracker.shared.beginInference()
        defer { ModelLivenessTracker.shared.endInference() }
        let snapshot = handle.snapshot
        let drainCancelled = handle.drainCancelled
        let continuousBatchingCapability = try applyContinuousBatchingPolicy(
            request: request,
            snapshot: snapshot,
            emitTelemetry: false
        )
        let nativeMTPAdmission = nativeMTPRuntimeAdmission(for: request, snapshot: snapshot, handle: handle)
        if !request.containsNonTextMessageContentPart {
            try Self.enforcePagedKVPreflight(pagedKVAttachDecision)
        }
        let structuredAccumulator = StructuredStreamingContentAccumulator(enabled: Self.requiresStructuredValidation(request.responseFormat))
        let idleState = StructuredStreamingIdleState(enabled: Self.requiresStructuredValidation(request.responseFormat))
        // SPEC-038 AC-6c: a batched structured-output stream runs under the
        // same SPEC-019 idle timeout as the serial one. It gets its own idle
        // state because the timeout race marks its state finished, and a
        // batched attempt that serial-routes (nil) must leave the serial
        // stream's timeout armed.
        let batchedIdleState = StructuredStreamingIdleState(enabled: Self.requiresStructuredValidation(request.responseFormat))
        let batchedCompletionStartedAt = Date()
        let batchedCompletion = try await Self.withStructuredStreamingIdleTimeout(
            idleState: batchedIdleState,
            onIdleTimeout: { () throws -> CompletionResult? in
                try Self.synthesizeIdleTimeoutResultOrThrow(
                    accumulator: structuredAccumulator,
                    request: request,
                    modelHash: snapshot.modelHash
                )
            }
        ) { idleCancellation in
            try await self.attachedContinuousBatchStreamingCompletion(
                request: request,
                snapshot: snapshot,
                capability: continuousBatchingCapability,
                nativeMTPAdmission: nativeMTPAdmission,
                completionStartedAt: batchedCompletionStartedAt,
                shouldCancel: shouldCancel,
                drainCancelled: drainCancelled,
                structuredAccumulator: structuredAccumulator,
                idleState: batchedIdleState,
                idleCancellation: idleCancellation,
                onChunk: onChunk
            )
        }
        if let completion = batchedCompletion {
            return completion
        }
        if speculativeCacheWrapValidated,
           let testSpeculativeStream,
           Self.speculativeRoute(
               for: request,
               draftLoaded: snapshot.hasTargetCompatibleDraft,
               numDraftTokens: snapshot.numDraftTokens
           ) == .speculative {
            let completion = try await Self.withDrainCancellation(drainCancelled) {
                try await testSpeculativeStream(snapshot, request)
            }.withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash))
            for chunk in testStreamChunks {
                onChunk(chunk)
            }
            if !completion.content.isEmpty {
                if let error = structuredAccumulator.append(completion.content) {
                    throw error
                }
                idleState.noteContent()
                onChunk(.content(completion.content))
            }
            let validated = try Self.validateStructuredStreamingCompletion(
                completion,
                request: request,
                buyerVisibleContent: structuredAccumulator.content
            )
            self.nativeMTPRequestShapeCapture?.record(
                request: request,
                snapshot: snapshot,
                admission: nativeMTPAdmission,
                lease: nil as ConversationCacheLease?,
                leaseAllowed: false,
                completion: validated,
                stream: true,
                resolvedMaxCompletionTokens: Self.nativeMTPCaptureEffectiveMaxOutputTokens(
                    request: request,
                    completion: validated,
                    maxContextTokens: maxContextTokens
                )
            )
            return validated
        }
        if let testCompletion {
            let completion = try await Self.withDrainCancellation(drainCancelled) {
                try await testCompletion(snapshot, request)
            }.withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash))
            for chunk in testStreamChunks {
                onChunk(chunk)
            }
            if !completion.content.isEmpty {
                if let error = structuredAccumulator.append(completion.content) {
                    throw error
                }
                idleState.noteContent()
                onChunk(.content(completion.content))
            }
            let validated = try Self.validateStructuredStreamingCompletion(
                completion,
                request: request,
                buyerVisibleContent: structuredAccumulator.content
            )
            self.nativeMTPRequestShapeCapture?.record(
                request: request,
                snapshot: snapshot,
                admission: nativeMTPAdmission,
                lease: nil as ConversationCacheLease?,
                leaseAllowed: false,
                completion: validated,
                stream: true,
                resolvedMaxCompletionTokens: Self.nativeMTPCaptureEffectiveMaxOutputTokens(
                    request: request,
                    completion: validated,
                    maxContextTokens: maxContextTokens
                )
            )
            return validated
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        let labSerialHooks = try Self.labSerialDecodeHooks(
            requestID: request.requestID,
            outputCap: labNativeMTPDecodeOutputCap,
            timingObserver: labNativeMTPCommitTimingObserver
        )
        let labConversationCacheObserver = labNativeMTPConversationCacheObserver
        #else
        let labSerialHooks: LabSerialDecodeHooks? = nil
        #endif
        if labSerialHooks != nil, HarmonyResponseParser.isHarmonyModelID(request.model) {
            throw Self.labSerialDecodeHookUnsupported("harmony_visible_prefix_accounting")
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
        let kvBitsOverride = Self.effectiveKVBits(
            configured: kvBitsOverride,
            conversationKey: request.conversationKey,
            containsImage: request.containsNonTextMessageContentPart
        )
        let speculativeCacheWrapValidated = speculativeCacheWrapValidated
        let prefillStepSize = Self.effectivePrefillStepSize(
            configured: prefillStepSize, containsImage: request.containsNonTextMessageContentPart)
        let isLocalRequest = localRegistrationIDs.contains(handle.registrationID)
        let conversationCache = conversationCache
        // SPEC-037 stage 5 — per-request cold-tier context (streaming endpoint).
        let coldContext = coldContext(for: request, snapshot: snapshot)
        let inferenceGate = inferenceGate
        let blockingInferenceExecutor = blockingInferenceExecutor
        let stopTokenFilter = snapshot.nativeVisionProfile == nil
            ? stopTokenFilter : NativeVisionProfile.stopTokenFilter
        let templateSupportsThinkingToggle = snapshot.templateSupportsThinkingToggle
        let templateSupportsPreserveThinking = snapshot.templateSupportsPreserveThinking
        let selectionModelID = toolSelectionModelID(snapshot)
        return try await Self.withDrainCancellation(drainCancelled) {
            try await Self.withStructuredStreamingIdleTimeout(
                idleState: idleState,
                onIdleTimeout: { () throws -> CompletionResult in
                    try Self.synthesizeIdleTimeoutResultOrThrow(
                        accumulator: structuredAccumulator,
                        request: request,
                        modelHash: snapshot.modelHash
                    )
                }
            ) { idleCancellation -> CompletionResult in
                try await inferenceGate.withPermit { () async throws -> CompletionResult in
                try drainCancelled.check()
                try Task.checkCancellation()
                return try await container.perform { context in
                    try drainCancelled.check()
                    try Task.checkCancellation()
                    let (lmInput, toolCallPrefill) = try await Self.preparedRequestInput(
                        for: request,
                        context: context,
                        templateSupportsThinkingToggle: templateSupportsThinkingToggle,
                        templateSupportsPreserveThinking: templateSupportsPreserveThinking,
                        nativeVisionProfile: snapshot.nativeVisionProfile,
                        toolSelectionModelID: selectionModelID
                    )
                    // Cancelled during preparation (client gone, or local
                    // work preempted under SPEC-001-R011): release the gate.
                    try Task.checkCancellation()
                    try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
                    // The request's completion budget as served: unchanged for
                    // a capped serve cache, clamped to the remaining context
                    // for a model that sizes its own cache.
                    let servedRequestMaxTokens = try Self.serialMaxOutputTokens(
                        model: context.model,
                        requested: request.maxTokens,
                        promptTokens: lmInput.text.tokens.size,
                        maxContextTokens: maxContextTokens
                    )
                    let parameters = try Self.makeServeGenerateParameters(
                                                model: context.model,
maxTokens: Self.labSerialEffectiveMaxTokens(
                            requestMaxTokens: servedRequestMaxTokens,
                            labOutputCap: labSerialHooks?.outputCap
                        ),
                        promptTokens: lmInput.text.tokens.size,
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
                       let numDraftTokens = snapshot.numDraftTokens,
                       speculativeCacheWrapValidated,
                       labSerialHooks == nil,
                       !isLocalRequest,
                       Self.speculativeCacheWindowSafe(
                           promptTokens: promptTokenIds.count,
                           maxTokens: request.maxTokens,
                           maxContextTokens: maxContextTokens,
                           numDraftTokens: numDraftTokens
                       ) {
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
                        let parsed = try Self.parseToolCallsIfRequested(final.text, request: request, toolCallPrefill: nil)
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
                            content: emittedText,
                            finishReason: finishReason,
                            promptTokens: promptTokenIds.count,
                            cachedPromptTokens: 0,
                            completionTokens: generated.generationTokenCount,
                            generationMilliseconds: generationMS,
                            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                            modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
                            settlementDisposition: .eligibleOwner,
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

                    let conversationCacheAllowed = Self.serialConversationCacheLeaseAllowed(
                        request: request,
                        admission: nativeMTPAdmission
                    )
                    let lease = conversationCacheAllowed
                        ? await conversationCache.begin(
                            conversationKey: request.conversationKey,
                            incomingTokens: promptTokenIds,
                            modelID: request.model,
                            kvBits: kvBitsOverride,
                            cold: coldContext,
                            fleetGrant: request.fleetCacheGrant
                        )
                        : nil
                    #if DEBUG || MACPROVIDER_LAB_HARNESS
                    if let labConversationCacheObserver {
                        labConversationCacheObserver.record(NativeMTPLabConversationCacheObserver.event(
                            requestID: request.requestID,
                            surface: "serial_stream",
                            keyPresent: Self.nonEmpty(request.conversationKey) != nil,
                            cacheOnly: request.conversationCacheOnly,
                            leaseAllowed: conversationCacheAllowed,
                            lease: lease,
                            modelHasRecurrentLayers: try ConversationCacheLayers.hasRecurrentLayers(generationContext.model.newCache(parameters: nil))
                        ))
                    }
                    #endif
                    let kvCache: [KVCache]
                    var iteratorInput: LMInput
                    let forceSimpleKV = Self.forceSimpleKVCache(
                        eligible: coldContext?.eligible == true,
                        conversationKey: request.conversationKey,
                        containsImage: request.containsNonTextMessageContentPart)
                    if let reusableCache = lease?.reusableCache, let lcp = lease?.lcp {
                        kvCache = reusableCache.layers
                        iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[lcp...])))
                    } else {
                        // SPEC-037 FR-KVP1 / SPEC-024-R001: same KVCacheSimple selector as
                        // the non-streaming path (eligible persist or keyed serial reuse).
                        kvCache = try Self.serveCache(
                            model: generationContext.model, baseParameters: parameters,
                            forceSimpleKV: forceSimpleKV)
                        iteratorInput = lmInput
                    }
                    let recurrent = Self.prefillRecurrentCheckpoints(
                        lease: lease, cache: kvCache, promptTokenIds: promptTokenIds,
                        context: generationContext, prefillStepSize: prefillStepSize)
                    if let resumeAt = recurrent.resumeAt {
                        iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[resumeAt...])))
                    }
                    if isLocalRequest, !request.containsNonTextMessageContentPart {
                        // SPEC-001-R011: a local prompt prefills in chunks with a
                        // preemption check before each, so a buyer never waits on a
                        // long local prefill. Buyer prefill is unchanged.
                        let start = promptTokenIds.count - iteratorInput.text.tokens.size
                        let resumeAt = try Self.cancellableLocalPrefill(
                            tokenCount: promptTokenIds.count, from: start, stepSize: prefillStepSize,
                            isCancelled: { Task.isCancelled || shouldCancel() || drainCancelled.isFired }
                        ) { range in
                            let chunk = LMInput.Text(tokens: MLXArray(Array(promptTokenIds[range])))
                            _ = generationContext.model(chunk[text: .newAxis], cache: kvCache, state: nil)
                            eval(kvCache)
                        }
                        if resumeAt > start {
                            iteratorInput = LMInput(tokens: MLXArray(Array(promptTokenIds[resumeAt...])))
                        }
                    }

                    var stoppedByRequestStop = false
                    var stoppedBySerialToolCall = false
                    var textEmitter = SerialStreamingTextEmitter(request: request)
                    var streamingParseError: APIError?
                    var harmonyObservedFinalTokenCount = 0
                    var harmonyObservedTokenCount = 0
                    var labSerialHookError: APIError?
                    #if DEBUG || MACPROVIDER_LAB_HARNESS
                    let labCommitTracker = labSerialHooks.map {
                        LabSerialCommitTracker(requestID: $0.requestID, observer: $0.timingObserver)
                    }
                    #else
                    let labCommitTracker: LabSerialCommitTracker? = nil
                    #endif

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
                        stopCandidates: stopTokenFilter.tokens
                    )
                    let iterator = try TokenIterator(
                        input: iteratorInput, model: generationContext.model, cache: kvCache,
                        parameters: Self.serveIteratorParameters(
                            parameters, forceSimpleKV: forceSimpleKV, reusedCache: lease?.reusableCache != nil,
                            cache: kvCache))
                    Self.clearMLXBufferCacheAfterPrefill()
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
                                    ModelLivenessTracker.shared.recordProgress()
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
                                let step = textEmitter.step(
                                    candidate: candidate,
                                    structuredAccumulator: structuredAccumulator,
                                    idleState: idleState,
                                    onChunk: onChunk
                                )
                                if let labSerialHooks, let labCommitTracker {
                                    let outputCount: Int
                                    do {
                                        outputCount = try Self.labSerialVisibleCommitCount(
                                            modelID: request.model,
                                            generatedTokenIDs: tokens,
                                            decodedText: decoded,
                                            emittedText: textEmitter.emittedContent,
                                            stopTokenFilter: stopTokenFilter,
                                            requestStops: request.stop
                                        )
                                    } catch let error as APIError {
                                        labSerialHookError = error
                                        return .stop
                                    } catch {
                                        labSerialHookError = Self.labSerialDecodeHookUnsupported("visible_prefix_accounting")
                                        return .stop
                                    }
                                    labCommitTracker.record(outputCount: outputCount)
                                    if let outputCap = labSerialHooks.outputCap, outputCount >= outputCap {
                                        return .stop
                                    }
                                }
                                switch step {
                                case .more:
                                    return .more
                                case .requestStop:
                                    stoppedByRequestStop = true
                                    return .stop
                                case .toolCallComplete:
                                    stoppedBySerialToolCall = true
                                    return .stop
                                case .structuredError:
                                    return .stop
                                }
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
                        if let labSerialHookError {
                            throw labSerialHookError
                        }
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
                            requestStops: HarmonyResponseParser.isHarmonyModelID(request.model) ? [] : request.stop
                        )
                        let rawLengthFinish = Self.labSerialLengthFinish(
                            generatedCompletionTokens: result.generationTokenCount,
                            requestMaxTokens: servedRequestMaxTokens,
                            labOutputCap: labSerialHooks?.outputCap
                        )
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
                            globalHitStop: final.hitStop || stoppedByRequestStop,
                            toolCallPrefill: toolCallPrefill
                        )
                        try textEmitter.finish(
                            finalText: final.text,
                            parsed: parsed,
                            structuredAccumulator: structuredAccumulator,
                            idleState: idleState,
                            onChunk: onChunk
                        )

                        let finishReason: String
                        if !parsed.toolCalls.isEmpty {
                            finishReason = "tool_calls"
                        } else if let maxTokens = servedRequestMaxTokens,
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
                        let terminalModelStopStripped = Self.serialTerminalModelStopStripped(
                            rawLengthFinish: rawLengthFinish,
                            hitStop: final.hitStop || stoppedByRequestStop,
                            parsedHitStop: parsed.hitStop,
                            harmonyTerminalFinish: harmonyTerminalFinish,
                            stoppedBySerialToolCall: stoppedBySerialToolCall
                        )

                        let cachedPromptTokens = lease?.cachedPromptTokens ?? 0
                        let kvCacheBytesReused = Self.cachedPromptUTF8Bytes(
                            promptTokenIds: promptTokenIds,
                            cachedPromptTokens: cachedPromptTokens,
                            decode: { context.tokenizer.decode(tokenIds: $0) }
                        )
                        let completion = CompletionResult(
                            content: isHarmonyResponse ? parsed.content : textEmitter.emittedContent,
                            finishReason: finishReason,
                            promptTokens: promptTokenIds.count,
                            cachedPromptTokens: cachedPromptTokens,
                            kvCacheBytesReused: kvCacheBytesReused,
                            completionTokens: parsed.completionTokens,
                            generatedCompletionTokens: parsed.generatedCompletionTokens,
                            generationMilliseconds: generationMS,
                            toolCalls: textEmitter.reconciledToolCalls.isEmpty
                                ? nil
                                : textEmitter.reconciledToolCalls,
                            modelHashObserved: Self.validObservedModelHash(snapshot.modelHash),
                            settlementDisposition: .eligibleOwner
                        )
                        let validated = try Self.validateStructuredStreamingCompletion(
                            completion,
                            request: request,
                            buyerVisibleContent: structuredAccumulator.content
                        )
                        self.nativeMTPRequestShapeCapture?.record(
                            request: request,
                            snapshot: snapshot,
                            admission: nativeMTPAdmission,
                            lease: lease,
                            leaseAllowed: conversationCacheAllowed,
                            completion: validated,
                            stream: true,
                            resolvedMaxCompletionTokens: request.maxTokens ?? max(1, maxContextTokens - promptTokenIds.count)
                        )
                        if let lease {
                            let fullTokens = promptTokenIds + resultTokenIDs.map(Int32.init)
                            guard Self.serialHybridCacheCanPublishTerminalCheckpoint(
                                cache: kvCache,
                                terminalModelStopStripped: terminalModelStopStripped
                            ) else {
                                await conversationCache.abort(lease)
                                return validated
                            }
                            guard let recurrentCheckpoints = Self.serialTerminalRecurrentCheckpoints(
                                promptCheckpoints: recurrent.checkpoints,
                                cache: kvCache,
                                tokenCount: fullTokens.count
                            ) else {
                                await conversationCache.abort(lease)
                                return validated
                            }
                            await conversationCache.commit(
                                lease,
                                cache: ConversationCacheLayers(kvCache, recurrentCheckpoints: recurrentCheckpoints),
                                fullTokens: fullTokens,
                                cold: coldContext
                            )
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
    func isFleetCachePurgeReady() -> Bool {
        attachedKVDiskTier != nil
    }

    func registerKVDiskTierForPurge(_ tier: KVDiskTier) {
        attachedKVDiskTier = tier
    }

    func kvDiskTierSnapshot() async -> RuntimeKVDiskTierSnapshot? {
        guard let tier = attachedKVDiskTier else { return nil }
        let bytesUsed = coldTierAttached ? await tier.store.cachedTotalBytesUsed() : nil
        return RuntimeKVDiskTierSnapshot(
            enabled: tier.config.effectiveEnabled,
            activated: coldTierAttached,
            unsupportedReason: coldTierUnsupportedReason,
            bytesUsed: bytesUsed,
            maxBytes: tier.config.maxBytes
        )
    }

    func attachKVDiskTier(_ tier: KVDiskTier) async {
        coldTierUnsupportedReason = nil
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
        attachedKVDiskAdapter = adapter
        attachedKVDiskTier = tier
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
        let result: KVDiskSeedResult? = try? await inferenceGate.withPermit {
            try await container.perform { context -> KVDiskSeedResult in
                let input = UserInput(chat: [.user("warmup")])
                let lmInput = try await context.processor.prepare(input: input)
                let parameters = try Self.makeServeGenerateParameters(
                                        model: context.model,
maxTokens: 1,
                    promptTokens: lmInput.text.tokens.size,
                    maxContextTokens: maxContextTokens,
                    kvBitsOverride: kvBitsOverride,
                    prefillStepSize: prefillStepSize,
                    temperature: 0.0,
                    topP: 1.0
                )
                // SPEC-037 FR-KVP1: the seed always models the tier-ELIGIBLE path, so it
                // must build a KVCacheSimple (maxKVSize=nil) — otherwise the
                // `as? [KVCacheSimple]` guard below never succeeds and no geometry is seeded.
                let seedParameters = Self.cacheParameters(parameters, forceSimpleKV: true)
                let kvCache = try context.model.newCache(parameters: seedParameters)
                let iterator = try TokenIterator(input: lmInput, model: context.model, cache: kvCache, parameters: seedParameters)
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
                if adapter.seedTemplate(servedModelID: servedModelID, layers: kvCache) {
                    return KVDiskSeedResult(template: nil, unsupportedCacheClass: nil)
                }
                guard let caches = kvCache as? [KVCacheSimple] else {
                    // Report the FIRST layer that is NOT KVCacheSimple (heterogeneous
                    // arrays whose layer 0 is simple but a later layer is not would
                    // otherwise be misreported as "KVCacheSimple"); fall back to the
                    // first layer's class, or "empty".
                    let className = (kvCache.first(where: { !($0 is KVCacheSimple) }) ?? kvCache.first)
                        .map { String(describing: type(of: $0)) } ?? "empty"
                    Self.logColdTierUnsupportedCacheClass(servedModelID: servedModelID, cacheClass: className)
                    return KVDiskSeedResult(template: nil, unsupportedCacheClass: className)
                }
                guard let payloads = KVCacheSerialization.snapshotLayers(caches) else {
                    return KVDiskSeedResult(template: nil, unsupportedCacheClass: nil)
                }
                return KVDiskSeedResult(
                    template: KVConversationColdTierAdapter.seedGeometryTemplate(fromPayloads: payloads),
                    unsupportedCacheClass: nil
                )
            }
        } ?? nil
        noteUnsupportedKVDiskCacheClass(result?.unsupportedCacheClass)
        if let template = result?.template, !template.isEmpty {
            adapter.seedTemplate(servedModelID: servedModelID, template: template)
        }
    }

    func noteUnsupportedKVDiskCacheClass(_ cacheClass: String?) {
        coldTierUnsupportedReason = cacheClass == nil ? nil : "unsupported_cache_class"
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
    /// A fleet acknowledgement requires both hot lease fencing and durable
    /// key destruction. Failure leaves coordinator reconciliation pending.
    func purgeFleetConversation(conversationKey: String) async -> Bool {
        _ = await conversationCache.purgeHot(conversationKey: conversationKey)
        guard let tier = attachedKVDiskTier else { return false }
        let result = await tier.purge(rawKey: conversationKey)
        if case .failed = result { return false }
        return true
    }

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
    /// The FR-KVP11/R014 gate admits a synthetic key on direct HTTP or a valid
    /// fleet grant on relay/Tier-2; the identity core carries the live model identity.
    private func coldContext(for request: ChatCompletionRequest, snapshot: RuntimeSnapshot) -> ConversationColdContext? {
        Self.coldContext(
            for: request,
            tierAttached: coldTierAttached,
            allowBuyerKeys: attachedKVDiskTier?.config.allowBuyerKeys == true,
            servedModelID: snapshot.modelID ?? request.model,
            modelSHA256: snapshot.modelHash,
            // MEDIUM-5: the catalog revision is a SEPARATE identity field from the model
            // artifact SHA (model_sha256). Absent ⇒ resolve() marks identity unavailable
            // (no promote/persist) rather than aliasing the artifact hash as the revision.
            catalogRevision: verifiedModelCatalogRevision,
            tokenizerConfigSHA256: currentTokenizerConfigSHA256,
            chatTemplateSHA256: currentChatTemplateSHA256)
    }

    /// SPEC-049-R010 (v0.6.0): the KV disk tier never sees privacy-class work.
    /// A nil cold context makes the conversation cache skip every cold-tier call,
    /// so a privacy request gets no disk lookup, write, restore or KV telemetry,
    /// whatever key or grant it carries. This is checked before the SPEC-037
    /// gate; the gate and the conversation-cache lease refuse privacy as well.
    static func coldTierAdmits(provenance: KVIngestProvenance) -> Bool {
        provenance.mayUseReusableKVCache
    }

    static func coldContext(
        for request: ChatCompletionRequest,
        tierAttached: Bool,
        allowBuyerKeys: Bool,
        servedModelID: String,
        modelSHA256: String?,
        catalogRevision: String?,
        tokenizerConfigSHA256: String?,
        chatTemplateSHA256: String?
    ) -> ConversationColdContext? {
        guard tierAttached,
              coldTierAdmits(provenance: request.ingestProvenance),
              !request.containsNonTextMessageContentPart
        else { return nil }
        // Evaluate the FR-KVP11 gate FIRST (key sub-namespace + direct-HTTP provenance),
        // independent of identity availability, so a gated request whose live identity is
        // unavailable still reaches the telemetry sink (FR-KVP12) instead of the cold
        // tier silently doing nothing. The pure resolution lives in
        // `ConversationColdContext.resolve` (unit-tested per missing input).
        let gated = KVDiskCacheGate.persists(
            conversationKey: request.conversationKey, provenance: request.ingestProvenance,
            fleetGrant: allowBuyerKeys ? request.fleetCacheGrant : nil)
        return ConversationColdContext.resolve(
            gated: gated,
            requestModel: request.model,
            servedModelID: servedModelID,
            modelSHA256: modelSHA256,
            catalogRevision: catalogRevision,
            tokenizerConfigSHA256: tokenizerConfigSHA256,
            chatTemplateSHA256: chatTemplateSHA256)
    }

    /// Token budget of the serve-time startup probe behind
    /// `capacity.throughput_tps_estimate`; the elapsed time includes prefill,
    /// so it is not a sustained decode benchmark (#1689).
    static let startupThroughputProbeMaxTokens = 8

    /// The startup probe's fixed prompt, shared by native and loopback runtimes.
    static let startupThroughputProbePrompt = "Reply with a short greeting."

    /// The one `capacity.throughput_tps_estimate` formula for every runtime
    /// (SPEC-001 FR-17/FR-20, SPEC-002): completion tokens of the startup
    /// generation over the whole request's elapsed time (prefill, first
    /// token and decode).
    static func startupThroughputRate(completionTokens: Int, elapsedSeconds: TimeInterval) -> Double {
        Double(completionTokens) / max(elapsedSeconds, 0.001)
    }

    /// SPEC-038 FR-CB10 serial baseline: the self-check prompts run one at a
    /// time through stock serial decode (the path a one-slot provider
    /// serves). `endToEndTPS` is all tokens over whole-call wall time, the
    /// baseline every family is measured against; `decodeTPS` (v0.3.21,
    /// glm5_next only) is the tokens after each prompt's first over the time
    /// from that first token to the last, summed over the prompts.
    func continuousBatchingSelfCheckSerialTPS(
        prompts: [[Int]], maxTokens: Int
    ) async throws -> ContinuousBatchingSelfCheckSerialRate {
        guard let container = currentContainer else {
            throw ContinuousBatchSchedulerError.requestFailed("self_check_model_unavailable")
        }
        let maxContextTokens = maxContextTokens
        let kvBitsOverride = kvBitsOverride
        let prefillStepSize = prefillStepSize
        let blockingInferenceExecutor = blockingInferenceExecutor
        var tokens = 0
        var seconds = 0.0
        var decodeTokens = 0
        var decodeSeconds = 0.0
        for prompt in prompts {
            try Task.checkCancellation()
            let start = Date()
            let result: BlockingGenerateResult = try await inferenceGate.withPermit {
                try await container.perform { context in
                    let lmInput = LMInput(text: LMInput.Text(tokens: MLXArray(prompt.map(Int32.init))))
                    let parameters = try Self.makeServeGenerateParameters(
                        model: context.model,
                        maxTokens: maxTokens,
                        promptTokens: prompt.count,
                        maxContextTokens: maxContextTokens,
                        kvBitsOverride: kvBitsOverride,
                        prefillStepSize: prefillStepSize,
                        temperature: 0.0,
                        topP: 1.0
                    )
                    return try await blockingInferenceExecutor.run { cancellation in
                        // Yield to a buyer at once: the driver cancels this
                        // task when a request arrives.
                        BlockingGenerateResult(try generate(input: lmInput, parameters: parameters, context: context) { (_: [Int]) in
                            cancellation.isCancelled ? GenerateDisposition.stop : GenerateDisposition.more
                        })
                    }
                }
            }
            try Task.checkCancellation()
            seconds += Date().timeIntervalSince(start)
            tokens += result.generationTokenCount
            if result.generationTokenCount > 1, result.generateTime > 0 {
                decodeTokens += result.generationTokenCount - 1
                decodeSeconds += result.generateTime
            }
        }
        return ContinuousBatchingSelfCheckSerialRate(
            decodeTPS: decodeSeconds > 0 ? Double(decodeTokens) / decodeSeconds : 0,
            endToEndTPS: seconds > 0 ? Double(tokens) / seconds : 0
        )
    }

    func measureStartupThroughput(maxTokens: Int = ModelRuntime.startupThroughputProbeMaxTokens) async -> Double {
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
                    let input = UserInput(chat: [.user(Self.startupThroughputProbePrompt)])
                    let lmInput = try await context.processor.prepare(input: input)
                    let parameters = try Self.makeServeGenerateParameters(
                                                model: context.model,
maxTokens: maxTokens,
                        promptTokens: lmInput.text.tokens.size,
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
            return Self.startupThroughputRate(
                completionTokens: result.generationTokenCount,
                elapsedSeconds: Date().timeIntervalSince(start)
            )
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
                    maxKVSize: modelSizesItsOwnKVCache(targetContext.model) ? nil : maxContextTokens,
                    kvBits: kvBitsOverride,
                    temperature: 0.0,
                    topP: 1.0,
                    prefill: .legacyRemainder(stepSize: prefillStepSize)
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
                maxKVSize: modelSizesItsOwnKVCache(targetContext.model) ? nil : maxContextTokens,
                kvBits: kvBitsOverride,
                temperature: 0.0,
                topP: 1.0,
                prefill: .legacyRemainder(stepSize: prefillStepSize)
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
        let cache = try context.model.newCache(parameters: parameters)
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
                let draftCache = try draftContext.model.newCache(parameters: parameters)
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

    private static func loadLocalContainer(
        from target: String,
        nativeVision: Bool = false
    ) async throws -> (ModelContainer, URL) {
        try await loadLocalContainer(
            from: target,
            tokenizerLoader: ChatTemplateCompatTokenizerLoader(),
            nativeVision: nativeVision
        )
    }

    private static func loadLocalContainer(
        from target: String,
        tokenizerLoader: any TokenizerLoader,
        nativeVision: Bool = false
    ) async throws -> (ModelContainer, URL) {
        let directory = try localModelDirectory(for: target)
        // mlx-swift-lm 3.x requires an explicit tokenizer loader. The provider
        // preflight has already verified model_artifact_path/model_artifact_sha256,
        // so load directly from the resolved local snapshot instead of downloading.
        let container: ModelContainer
        if nativeVision {
            let before = try NativeVisionProfile.load(
                modelID: NativeVisionProfile.modelID, directory: directory, artifactSHA256: nil)
            container = try await VLMModelFactory.shared.loadContainer(from: directory, using: tokenizerLoader)
            let after = try NativeVisionProfile.load(
                modelID: NativeVisionProfile.modelID, directory: directory, artifactSHA256: before?.artifactSHA256)
            guard before == after else { throw NativeVisionProfile.identityError() }
        } else {
            container = try await LLMModelFactory.shared.loadContainer(from: directory, using: tokenizerLoader)
        }
        return (container, directory)
    }

    struct NativeMTPRunningBuildIdentity: Equatable, Sendable {
        let sourceCommit: String
        let reproducibleBuildSHA256: String
        let liveExecutableCDHash: String
        let upstreamMLXSwiftLMRevision: String

        init(
            sourceCommit: String,
            reproducibleBuildSHA256: String,
            liveExecutableCDHash: String,
            upstreamMLXSwiftLMRevision: String = KVBuildIdentity.mlxSwiftLMRevision
        ) {
            self.sourceCommit = sourceCommit
            self.reproducibleBuildSHA256 = reproducibleBuildSHA256
            self.liveExecutableCDHash = liveExecutableCDHash
            self.upstreamMLXSwiftLMRevision = upstreamMLXSwiftLMRevision
        }
    }

    private struct NativeMTPLiveProcessCodeIdentity: Equatable, Sendable {
        let cdHash: String
    }

    private struct NativeMTPRuntimeLoadResult {
        let targetContainer: ModelContainer
        let targetDirectory: URL
        let drafterContainer: MTPDrafterContainer
        let capability: NativeMTPCapability
        let admissionCapability: NativeMTPAdmissionCapability
        let selfTestInput: NativeMTPSelfTestInput
        let selfTestRuntimeTuple: NativeMTPSelfTestRuntimeTuple
        let runtimeTuple: NativeMTPPublishedRuntimeTuple
        let servedSnapshotID: String
        let runtimeCacheClass: String
        let modelCapabilities: PagedKVRuntimeModelCapabilities
        let revocationSignerKeyID: String?
        let revocationTrustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring?
        let revocationExpiresAt: Date?
    }

    private final class NativeMTPServePathRejectionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedReason: NativeMTPStatusReason?

        var statusReason: NativeMTPStatusReason? {
            lock.lock()
            defer { lock.unlock() }
            return storedReason
        }

        func record(_ reasonCode: String) {
            guard reasonCode == "revocation_state_unavailable" else { return }
            lock.lock()
            storedReason = .revocationStateUnavailable
            lock.unlock()
        }
    }

    private struct NativeMTPCapturedTokenizerLoader: TokenizerLoader {
        let tokenizerDirectory: URL
        let base: any TokenizerLoader

        func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
            try await base.load(from: tokenizerDirectory)
        }
    }

    private static func nativeMTPTupleOffer(
        load: NativeMTPRuntimeLoadResult,
        receipt: NativeMTPSelfTestReceipt
    ) -> NativeMTPPublishedTupleOffer {
        NativeMTPPublishedTupleOffer(
            targetGeneration: load.selfTestInput.servedSnapshot?.generation ?? 0,
            providerRevision: load.admissionCapability.providerRevision,
            runtimeRevision: load.admissionCapability.upstreamMLXSwiftLMRevision,
            runtimeTuple: load.runtimeTuple,
            nativeMTPAdmissionTupleSHA256: load.admissionCapability.tupleSHA256,
            servedSnapshotID: load.servedSnapshotID,
            sidecarDigest: load.admissionCapability.sidecarSHA256,
            challengeBankReleaseID: load.admissionCapability.selfTestChallengeBank.releaseID,
            challengeBankSHA256: load.admissionCapability.selfTestChallengeBank.challengeBankSHA256,
            challengeCorpusSHA256: load.admissionCapability.selfTestChallengeBank.challengeBankSHA256,
            selftestProfile: NativeMTPSelfTestRunner.capability,
            selftestPassDigest: receipt.passDigestSHA256,
            selftestObservedAt: Date()
        )
    }

    static func nativeMTPRunningBuildIdentity(
        launchedExecutableURL: URL? = Bundle.main.executableURL,
        markerStore: AutoUpdateMarkerStore = AutoUpdateMarkerStore()
    ) -> NativeMTPRunningBuildIdentity? {
        let canonicalBinaryURL = markerStore.resolveCanonicalInstallBinary(
            launchedExecutableURL: launchedExecutableURL
        )
        let installedSourceCommit = CompatibilitySetManifest.loadInstalledPreferringInstallAuthority(
            launchedExecutableURL: launchedExecutableURL,
            canonicalBinaryURL: canonicalBinaryURL,
            expectedVersion: CoordinatorClient.binaryVersion,
            allowProviderVersionMismatch: false
        ).flatMap { compatibilitySetSourceCommit($0.compatibilitySetID) }
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        // A lab build has no installed compatibility set; the rehearsal names
        // the commit it was built from. The executable digest and live CDHash
        // are still measured from the running process.
        let resolvedSourceCommit = installedSourceCommit ?? labNativeMTPSourceCommit()
        #else
        let resolvedSourceCommit = installedSourceCommit
        #endif
        guard let sourceCommit = resolvedSourceCommit,
              let executableURL = CompatibilitySetManifest.resolvedExecutableURL(launchedExecutableURL),
              let executableSHA256 = try? sha256RegularFileNoFollow(executableURL),
              let liveCodeIdentity = nativeMTPLiveProcessCodeIdentity()
        else {
            return nil
        }
        return NativeMTPRunningBuildIdentity(
            sourceCommit: sourceCommit,
            reproducibleBuildSHA256: executableSHA256,
            liveExecutableCDHash: liveCodeIdentity.cdHash,
            upstreamMLXSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision
        )
    }

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    static func labNativeMTPSourceCommit(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let commit = environment["MACPROVIDER_LAB_NATIVE_MTP_SOURCE_COMMIT"],
              commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
        else {
            return nil
        }
        return commit
    }
    #endif

    static func nativeMTPRunningBuildIdentityForTest(
        launchedExecutableURL: URL?,
        markerStore: AutoUpdateMarkerStore
    ) -> NativeMTPRunningBuildIdentity? {
        nativeMTPRunningBuildIdentity(
            launchedExecutableURL: launchedExecutableURL,
            markerStore: markerStore
        )
    }

    static func nativeMTPRunningBuildIdentityForTest(
        compatibilitySetID: String,
        reproducibleBuildSHA256: String,
        liveExecutableCDHash: String
    ) -> NativeMTPRunningBuildIdentity? {
        guard let sourceCommit = compatibilitySetSourceCommit(compatibilitySetID),
              reproducibleBuildSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              liveExecutableCDHash.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
        else {
            return nil
        }
        return NativeMTPRunningBuildIdentity(
            sourceCommit: sourceCommit,
            reproducibleBuildSHA256: reproducibleBuildSHA256,
            liveExecutableCDHash: liveExecutableCDHash,
            upstreamMLXSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision
        )
    }

    private static func compatibilitySetSourceCommit(_ compatibilitySetID: String) -> String? {
        guard CompatibilitySetManifest.isCanonicalCompatibilitySetID(compatibilitySetID),
              let marker = compatibilitySetID.lastIndex(of: "@")
        else {
            return nil
        }
        let commit = String(compatibilitySetID[compatibilitySetID.index(after: marker)...])
        guard commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return commit
    }

    private static func sha256RegularFileNoFollow(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_nlink == 1
        else {
            throw CocoaError(.fileReadUnknown)
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hexString(hasher.finalize())
    }

    private static func nativeMTPLiveProcessCodeIdentity() -> NativeMTPLiveProcessCodeIdentity? {
        var currentCode: SecCode?
        guard SecCodeCopySelf([], &currentCode) == errSecSuccess,
              let currentCode,
              SecCodeCheckValidity(
                currentCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil
              ) == errSecSuccess
        else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(currentCode, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        ) == errSecSuccess,
              let info = signingInfo as? [String: Any],
              let cdHash = info[kSecCodeInfoUnique as NSString as String] as? Data,
              !cdHash.isEmpty
        else {
            return nil
        }
        let cdHashHex = hexString(cdHash)
        guard cdHashHex.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return NativeMTPLiveProcessCodeIdentity(
            cdHash: cdHashHex
        )
    }

    private static func loadNativeMTPDrafterIfAdmitted(
        mode: NativeMTPMode,
        targetModelID: String,
        targetModelRevision: String?,
        targetDirectory: URL,
        maxContextTokens: Int,
        kvBitsOverride: Int?,
        prefillStepSize: Int,
        slotCount: Int,
        sidecarPath: String?,
        artifactRoot: String? = nil,
        signaturePath: String?,
        trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring?,
        runningBuildIdentity injectedRunningBuildIdentity: NativeMTPRunningBuildIdentity?,
        revokedTupleSHA256: Set<String>?,
        resolvedArtifactAuthority: NativeMTPResolvedArtifactAuthority?,
        targetGeneration: UInt64,
        selfTestRunner: NativeMTPSelfTestRunner,
        rejectionObserver: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> NativeMTPRuntimeLoadResult? {
        func reject(reasonCode: String, artifactRole: String) -> NativeMTPRuntimeLoadResult? {
            rejectionObserver(reasonCode)
            return rejectNativeMTPServePath(reasonCode: reasonCode, artifactRole: artifactRole)
        }
        guard mode == .auto else {
            return reject(reasonCode: "mode_not_auto", artifactRole: "runtime")
        }
        guard let targetModelRevision else {
            return reject(reasonCode: "target_revision_missing", artifactRole: "target")
        }
        guard let trustedKeyring else {
            return reject(reasonCode: "trusted_keyring_missing", artifactRole: "sidecar")
        }
        guard let runningBuildIdentity = injectedRunningBuildIdentity ?? nativeMTPRunningBuildIdentity() else {
            return reject(reasonCode: "running_build_identity_unavailable", artifactRole: "runtime")
        }
        let bundleRoot = targetDirectory.deletingLastPathComponent()
        let bundledSidecar = bundleRoot.appendingPathComponent("native-mtp-admission.json")
        let defaultSidecar = FileManager.default.fileExists(atPath: bundledSidecar.path)
            ? bundledSidecar
            : targetDirectory.appendingPathComponent("native-mtp-admission.json")
        let sidecarURL = sidecarPath
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? defaultSidecar
        let signatureURL = signaturePath
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? sidecarURL.deletingLastPathComponent().appendingPathComponent("native-mtp-admission.json.sig")
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            return reject(reasonCode: "sidecar_missing", artifactRole: "sidecar")
        }
        guard FileManager.default.fileExists(atPath: signatureURL.path) else {
            return reject(reasonCode: "signature_missing", artifactRole: "signature")
        }
        do {
            let revocationAdmissionState: NativeMTPRevocationAdmissionState
            if let revokedTupleSHA256 {
                revocationAdmissionState = NativeMTPRevocationAdmissionState(
                    revokedTupleSHA256: revokedTupleSHA256,
                    signerKeyID: nil,
                    trustedKeyring: nil,
                    expiresAt: nil
                )
            } else {
                guard let loadedRevocationState = await Self.nativeMTPRevocationAdmissionState(
                    sidecarURL: sidecarURL,
                    signatureURL: signatureURL,
                    trustedKeyring: trustedKeyring
                ) else {
                    return reject(
                        reasonCode: "revocation_state_unavailable",
                        artifactRole: "sidecar"
                    )
                }
                revocationAdmissionState = loadedRevocationState
            }
            let effectiveRevokedTupleSHA256 = revocationAdmissionState.revokedTupleSHA256
            let snapshotRoot = sidecarURL.deletingLastPathComponent()
            let machine = MachineFingerprinter().sample()
            let admissionCapability = try NativeMTPAdmissionSidecar.load(
                sidecarURL: sidecarURL,
                signatureURL: signatureURL,
                snapshotRoot: snapshotRoot,
                artifactRoot: artifactRoot.map { URL(fileURLWithPath: $0, isDirectory: true) },
                context: NativeMTPAdmissionSidecar.RuntimeContext(
                    modelID: targetModelID,
                    modelRevision: targetModelRevision,
                    upstreamMLXSwiftLMRevision: runningBuildIdentity.upstreamMLXSwiftLMRevision,
                    hardwareChip: machine.chip,
                    ramGB: machine.ramGB,
                    osVersion: machine.osVersion,
                    slotCount: slotCount,
                    revokedTupleSHA256: effectiveRevokedTupleSHA256
                ),
                trustedKeyring: trustedKeyring,
                resolvedArtifactAuthority: resolvedArtifactAuthority,
                captureArtifacts: true
            )
            guard nativeMTPAdmissionMatchesRunningBuild(
                admissionCapability,
                targetModelRevision: targetModelRevision,
                runningBuildIdentity: runningBuildIdentity
            ) else {
                return reject(reasonCode: "build_binding_mismatch", artifactRole: "sidecar")
            }
            guard let capturedArtifacts = admissionCapability.capturedArtifacts else {
                return reject(reasonCode: "captured_artifacts_unavailable", artifactRole: "pair")
            }
            let drafterDirectory = try nativeMTPArtifactDirectory(for: capturedArtifacts.mtpURL)
            guard let capturedTokenizerLoader = nativeMTPCapturedTokenizerLoader(
                capturedArtifacts: capturedArtifacts
            ) else {
                return reject(reasonCode: "captured_tokenizer_invalid", artifactRole: "target")
            }
            guard try nativeMTPCapturedManifestMatchesAdmission(
                capturedArtifacts: capturedArtifacts,
                admissionCapability: admissionCapability
            ) else {
                return reject(reasonCode: "captured_manifest_mismatch", artifactRole: "pair")
            }
            // SPEC-048-R002: an embedded (`checkpoint_mtp`) next-N layer is
            // observed once, inside the target artifact.
            let artifactObservation = try admissionCapability.sourceLayout == "checkpoint_mtp"
                ? NativeMTPArtifactObserver.observeEmbedded(targetDirectory: capturedArtifacts.targetURL)
                : NativeMTPArtifactObserver.observePair(
                    targetDirectory: capturedArtifacts.targetURL,
                    mtpDirectory: drafterDirectory
                )
            guard nativeMTPArtifactObservationMatchesAdmission(
                artifactObservation,
                admissionCapability: admissionCapability
            ) else {
                return reject(reasonCode: "artifact_observation_mismatch", artifactRole: "pair")
            }
            let targetLoad = try await loadLocalContainer(
                from: capturedArtifacts.targetURL.path,
                tokenizerLoader: capturedTokenizerLoader
            )
            let capturedTargetContainer = targetLoad.0
            let capturedTargetDirectory = targetLoad.1
            guard capturedTargetDirectory
                .resolvingSymlinksInPath()
                .standardizedFileURL == capturedArtifacts.targetURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            else {
                return reject(reasonCode: "captured_target_identity_mismatch", artifactRole: "target")
            }
            let modelCapabilities = pagedKVModelCapabilities(modelID: targetModelID, directory: capturedTargetDirectory)
            let runtimeCacheClass = await pagedKVRuntimeCacheClass(
                container: capturedTargetContainer,
                maxContextTokens: maxContextTokens,
                kvBitsOverride: kvBitsOverride,
                prefillStepSize: prefillStepSize
            )
            guard let canonicalCacheClass = nativeMTPAdmissionCacheClass(
                runtimeCacheClass: runtimeCacheClass,
                modelCapabilities: modelCapabilities
            ) else {
                return reject(reasonCode: "runtime_cache_class_unsupported", artifactRole: "runtime")
            }
            let targetCacheKinds = await pagedKVCacheKinds(container: capturedTargetContainer)
            let drafterPresent = await nativeMTPDrafterPresent(
                familyAdapter: admissionCapability.familyAdapter,
                targetContainer: capturedTargetContainer
            )
            guard nativeMTPAdmissionCapabilitySupported(
                admissionCapability,
                canonicalCacheClass: canonicalCacheClass,
                modelCapabilities: modelCapabilities,
                cacheKinds: targetCacheKinds,
                drafterPresent: drafterPresent
            ) else {
                return reject(reasonCode: "admission_capability_unsupported", artifactRole: "sidecar")
            }
            let drafterContainer = try await loadNativeMTPDrafterContainer(
                familyAdapter: admissionCapability.familyAdapter,
                targetDirectory: capturedArtifacts.targetURL,
                drafterDirectory: drafterDirectory,
                tokenizerLoader: capturedTokenizerLoader
            )
            try capturedArtifacts.revalidateAfterLoad()
            let drafterRuntimeObservation = await drafterContainer.perform { context -> (maximumBlockSize: Int?, stateLayerCount: Int?) in
                let stateLayerCount = (context.model as? any MTPPackedStatefulDrafterModel)?
                    .makeState(parameters: nil)
                    .cache
                    .count
                return (context.model.maximumBlockSize, stateLayerCount)
            }
            guard drafterRuntimeObservation.stateLayerCount == admissionCapability.predictionLayerCount else {
                return reject(reasonCode: "drafter_state_layer_count_mismatch", artifactRole: "mtp")
            }
            guard NativeMTPProposalBounds.fits(
                maximumProposalDepth: admissionCapability.maxProposalDepth,
                maximumBlockSize: drafterRuntimeObservation.maximumBlockSize
            ) else {
                return reject(reasonCode: "drafter_proposal_depth_unsupported", artifactRole: "mtp")
            }
            let selectedChallenge = try loadNativeMTPSelfTestChallenge(
                admissionCapability: admissionCapability,
                snapshotRoot: snapshotRoot,
                trustedKeyring: trustedKeyring
            )
            let selfTestRuntimeTuple = try nativeMTPSelfTestRuntimeTuple(
                admissionCapability: admissionCapability,
                runningBuildIdentity: runningBuildIdentity,
                selectedChallenge: selectedChallenge,
                targetGeneration: targetGeneration
            )
            let tupleSHA256 = admissionCapability.tupleSHA256
            let selfTestInput = NativeMTPSelfTestInput(
                tupleSHA256: tupleSHA256,
                modelID: admissionCapability.modelID,
                modelRevision: admissionCapability.modelRevision,
                familyAdapter: admissionCapability.familyAdapter,
                proposalDepth: selectedChallenge.fixedProposalDepth,
                challengeBank: admissionCapability.selfTestChallengeBank,
                selectedChallenge: selectedChallenge,
                servedSnapshot: NativeMTPSelfTestServedSnapshot(
                    tupleSHA256: tupleSHA256,
                    runtimeTuple: selfTestRuntimeTuple,
                    generation: targetGeneration,
                    proposalDepth: selectedChallenge.fixedProposalDepth
                )
            )
            let capability = NativeMTPCapability(
                admitted: true,
                revoked: false,
                revocationStateAvailable: true,
                supportsCurrentProcessor: true,
                supportsCurrentStateCache: true,
                supportsStreaming: true,
                supportsNonStreaming: true,
                supportsStopSequences: true,
                hasQualifiedRowMappedTransactions: true,
                maximumProposalDepth: admissionCapability.maxProposalDepth,
                maximumPromptTokens: admissionCapability.maxPromptTokens,
                maximumCompletionTokens: admissionCapability.maxCompletionTokens,
                completeWindowBytesByDepth: admissionCapability.completeWindowBytesByDepth,
                family: admissionCapability.familyAdapter,
                throughputDeltaPPM: admissionCapability.throughputDeltaPPM,
                maximumNativeActiveRows: admissionCapability.maxNativeActiveRows,
                supportsSampling: admissionCapability.supportsSampling
            )
            let runtimeTuple = NativeMTPPublishedRuntimeTuple(
                modelID: selfTestRuntimeTuple.modelID,
                modelHash: selfTestRuntimeTuple.modelHash,
                modelHashAlgorithm: selfTestRuntimeTuple.modelHashAlgorithm,
                providerRevision: admissionCapability.providerRevision,
                runtimeRevision: admissionCapability.upstreamMLXSwiftLMRevision,
                tokenizerDigest: selfTestRuntimeTuple.tokenizerDigest,
                artifactDigest: selfTestRuntimeTuple.artifactDigest,
                manifestDigest: selfTestRuntimeTuple.manifestDigest,
                sidecarDigest: selfTestRuntimeTuple.sidecarDigest,
                providerBinarySHA256: selfTestRuntimeTuple.providerBinarySHA256,
                runtimeCDHash: selfTestRuntimeTuple.runtimeCDHash,
                cacheNamespace: selfTestRuntimeTuple.cacheNamespace,
                stateDigest: selfTestRuntimeTuple.stateDigest,
                proposalDepth: selfTestRuntimeTuple.proposalDepth
            )
            let servedSnapshotID = try nativeMTPServedSnapshotID(
                admissionCapability: admissionCapability,
                runtimeTuple: selfTestRuntimeTuple,
                selectedChallenge: selectedChallenge,
                targetGeneration: targetGeneration
            )
            return NativeMTPRuntimeLoadResult(
                targetContainer: capturedTargetContainer,
                targetDirectory: capturedTargetDirectory,
                drafterContainer: drafterContainer,
                capability: capability,
                admissionCapability: admissionCapability,
                selfTestInput: selfTestInput,
                selfTestRuntimeTuple: selfTestRuntimeTuple,
                runtimeTuple: runtimeTuple,
                servedSnapshotID: servedSnapshotID,
                runtimeCacheClass: runtimeCacheClass,
                modelCapabilities: modelCapabilities,
                revocationSignerKeyID: revocationAdmissionState.signerKeyID,
                revocationTrustedKeyring: revocationAdmissionState.trustedKeyring,
                revocationExpiresAt: revocationAdmissionState.expiresAt
            )
        } catch {
            let rejection = nativeMTPServePathRejection(for: error)
            return reject(
                reasonCode: rejection.reasonCode,
                artifactRole: rejection.artifactRole
            )
        }
    }

    /// Maps a serve-path admission error to a closed reason code. Error
    /// payloads are never logged: they can carry tensor names or paths.
    static func nativeMTPServePathRejection(for error: Error) -> (reasonCode: String, artifactRole: String) {
        if let observationError = error as? NativeMTPArtifactObservationError {
            switch observationError {
            case .unsupportedQuantization:
                return ("artifact_quantization_unsupported", "pair")
            case .missingQuantizationMetadata:
                return ("artifact_quantization_metadata_missing", "pair")
            case .incompatibleSafetensorsHeaders, .unsupportedDType:
                return ("artifact_tensor_representation_rejected", "pair")
            case .observationDrift:
                return ("artifact_observation_drift", "pair")
            case .missingConfig, .malformedConfig, .missingMTPPredictionLayerCount,
                 .invalidMTPPredictionLayerCount, .missingSafetensors, .malformedSafetensors:
                return ("artifact_observation_invalid", "pair")
            }
        }
        if error is NativeMTPAdmissionSidecarError {
            return ("sidecar_validation_rejected", "sidecar")
        }
        if error is ModelRuntimeLoadError {
            return ("artifact_load_failed", "pair")
        }
        if error is NativeMTPSelfTestError {
            return ("selftest_challenge_bank_rejected", "challenge_bank")
        }
        if error is ModelFactoryError {
            return ("model_factory_load_failed", "pair")
        }
        if error is CocoaError {
            return ("artifact_io_failed", "pair")
        }
        return ("serve_path_admission_failed", "runtime")
    }

    private static func rejectNativeMTPServePath(
        reasonCode: String,
        artifactRole: String
    ) -> NativeMTPRuntimeLoadResult? {
        logNativeMTPServePathRejection(reasonCode: reasonCode, artifactRole: artifactRole)
        return nil
    }

    private static func rejectNativeMTPSelfTest(reasonCode: String) -> NativeMTPSelfTestReceipt? {
        logNativeMTPServePathRejection(reasonCode: reasonCode, artifactRole: "runtime")
        return nil
    }

    private static func logNativeMTPServePathRejection(reasonCode: String, artifactRole: String) {
        FileHandle.standardError.write(Data(nativeMTPServePathRejectionLogLine(
            reasonCode: reasonCode,
            artifactRole: artifactRole
        ).utf8))
    }

    /// One sorted-key JSON object per rejection, terminated by a single newline.
    static func nativeMTPServePathRejectionLogLine(reasonCode: String, artifactRole: String) -> String {
        let payload: [String: String] = [
            "artifact_role": artifactRole,
            "event": "native_mtp_serve_path_admission",
            "reason_code": reasonCode,
            "status": "rejected",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        return "event=native_mtp_serve_path_admission status=rejected reason_code=\(reasonCode) artifact_role=\(artifactRole)\n"
    }

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    struct NativeMTPHardwareE2EServePathLoad: @unchecked Sendable {
        let targetContainer: ModelContainer
        let drafterContainer: MTPDrafterContainer
    }

    /// Lab-only entry into the production serve-path admission loader, so the
    /// hardware e2e exercises the real sidecar, capture, observer, and drafter
    /// admission instead of an injected drafter. The self-test runs later in
    /// production startup and is not part of this load.
    static func nativeMTPServePathLoadForHardwareE2E(
        targetModelID: String,
        targetModelRevision: String,
        targetDirectory: URL,
        maxContextTokens: Int,
        slotCount: Int,
        sidecarURL: URL,
        signatureURL: URL,
        trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring,
        runningBuildIdentity: NativeMTPRunningBuildIdentity,
        resolvedArtifactAuthority: NativeMTPResolvedArtifactAuthority
    ) async -> NativeMTPHardwareE2EServePathLoad? {
        guard let load = await loadNativeMTPDrafterIfAdmitted(
            mode: .auto,
            targetModelID: targetModelID,
            targetModelRevision: targetModelRevision,
            targetDirectory: targetDirectory,
            maxContextTokens: maxContextTokens,
            kvBitsOverride: nil,
            prefillStepSize: 512,
            slotCount: slotCount,
            sidecarPath: sidecarURL.path,
            signaturePath: signatureURL.path,
            trustedKeyring: trustedKeyring,
            runningBuildIdentity: runningBuildIdentity,
            revokedTupleSHA256: [],
            resolvedArtifactAuthority: resolvedArtifactAuthority,
            targetGeneration: 1,
            selfTestRunner: .unavailable
        ) else {
            return nil
        }
        return NativeMTPHardwareE2EServePathLoad(
            targetContainer: load.targetContainer,
            drafterContainer: load.drafterContainer
        )
    }
    #endif

    private struct NativeMTPRevocationAdmissionState {
        let revokedTupleSHA256: Set<String>
        let signerKeyID: String?
        let trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring?
        let expiresAt: Date?
    }

    private static func nativeMTPRevocationAdmissionState(
        sidecarURL: URL,
        signatureURL: URL,
        trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring
    ) async -> NativeMTPRevocationAdmissionState? {
        do {
            let sidecarData = try Data(contentsOf: sidecarURL)
            let signatureData = try Data(contentsOf: signatureURL)
            let revocationSignerKeyID = try NativeMTPAdmissionSidecar.pinnedRevocationSignerKeyID(
                sidecarData: sidecarData,
                signatureData: signatureData,
                trustedKeyring: trustedKeyring
            )
            let store = KeychainNativeMTPRevocationStore.live()
            let verifier = NativeMTPRevocationEd25519Verifier(publicKeysByKeyID: trustedKeyring.publicKeysByKeyID)
            // SPEC-048-R014 (v0.1.32): the revocation feed only revokes. When
            // no fresh signed feed can be had, nothing is revoked; the refresh
            // keeps polling and disables the tuple once a feed names it.
            guard let state = try? await NativeMTPRevocationFeedManager.loadNetworkFirst(
                pinnedSignerKeyID: revocationSignerKeyID,
                verifier: verifier,
                store: store
            ) else {
                return NativeMTPRevocationAdmissionState(
                    revokedTupleSHA256: [],
                    signerKeyID: revocationSignerKeyID,
                    trustedKeyring: trustedKeyring,
                    expiresAt: nil
                )
            }
            return NativeMTPRevocationAdmissionState(
                revokedTupleSHA256: state.feed.revokedSet,
                signerKeyID: revocationSignerKeyID,
                trustedKeyring: trustedKeyring,
                expiresAt: nil
            )
        } catch {
            return nil
        }
    }

    private static func nativeMTPAdmissionMatchesRunningBuild(
        _ admissionCapability: NativeMTPAdmissionCapability,
        targetModelRevision: String,
        runningBuildIdentity: NativeMTPRunningBuildIdentity
    ) -> Bool {
        // SPEC-048-R013 (v0.1.32): admission is model-keyed. The upstream MLX
        // revision, provider revision and build identity are recorded
        // provenance; the on-device MTP-on vs MTP-off self-check qualifies the
        // running runtime. Only the loaded target artifact must match.
        admissionCapability.targetArtifactSHA256 == targetModelRevision
    }

    static func nativeMTPAdmissionMatchesRunningBuildForTest(
        _ admissionCapability: NativeMTPAdmissionCapability,
        targetModelRevision: String,
        runningBuildIdentity: NativeMTPRunningBuildIdentity
    ) -> Bool {
        nativeMTPAdmissionMatchesRunningBuild(
            admissionCapability,
            targetModelRevision: targetModelRevision,
            runningBuildIdentity: runningBuildIdentity
        )
    }

    private static func nativeMTPArtifactDirectory(for url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        return values.isDirectory == true ? url : url.deletingLastPathComponent()
    }

    private static func nativeMTPCapturedTokenizerLoader(
        capturedArtifacts: NativeMTPAdmissionCapturedArtifacts
    ) -> (any TokenizerLoader)? {
        guard let targetURL = nativeMTPCapturedTokenizerDirectory(
            targetURL: capturedArtifacts.targetURL,
            tokenizerURL: capturedArtifacts.tokenizerURL
        )
        else {
            return nil
        }
        return NativeMTPCapturedTokenizerLoader(
            tokenizerDirectory: targetURL,
            base: ChatTemplateCompatTokenizerLoader()
        )
    }

    private static func nativeMTPCapturedManifestMatchesAdmission(
        capturedArtifacts: NativeMTPAdmissionCapturedArtifacts,
        admissionCapability: NativeMTPAdmissionCapability
    ) throws -> Bool {
        let pathMatches = nativeMTPCapturedManifestPathMatchesMTP(
            mtpURL: capturedArtifacts.mtpURL,
            manifestURL: capturedArtifacts.manifestURL
        )
        guard pathMatches else { return false }
        return try sha256RegularFileNoFollow(capturedArtifacts.manifestURL) == admissionCapability.mtpManifestSHA256
    }

    private static func nativeMTPCapturedManifestPathMatchesMTP(mtpURL: URL, manifestURL: URL) -> Bool {
        let mtpURL = mtpURL.standardizedFileURL
        let manifestURL = manifestURL.standardizedFileURL
        return manifestURL == mtpURL.appendingPathComponent("config.json").standardizedFileURL
            && BYOMArtifactPathPolicy.isContained(manifestURL, in: mtpURL)
    }

    static func nativeMTPCapturedManifestPathMatchesMTPForTest(mtpURL: URL, manifestURL: URL) -> Bool {
        nativeMTPCapturedManifestPathMatchesMTP(mtpURL: mtpURL, manifestURL: manifestURL)
    }

    private static func loadNativeMTPSelfTestChallenge(
        admissionCapability: NativeMTPAdmissionCapability,
        snapshotRoot: URL,
        trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring
    ) throws -> NativeMTPSelfTestChallenge {
        guard trustedKeyring.publicKeysByKeyID[admissionCapability.selfTestChallengeBank.signerKeyID] != nil else {
            throw NativeMTPSelfTestError.invalidSignature
        }
        let root = snapshotRoot.standardizedFileURL
        let bankURL = root
            .appendingPathComponent(admissionCapability.selfTestChallengeBank.challengeBankPath, isDirectory: false)
            .standardizedFileURL
        guard BYOMArtifactPathPolicy.isContained(bankURL, in: root) else {
            throw NativeMTPSelfTestError.challengeBankMismatch
        }
        let data = try readNativeMTPSelfTestBank(bankURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == admissionCapability.selfTestChallengeBank.challengeBankSHA256 else {
            throw NativeMTPSelfTestError.challengeBankMismatch
        }
        let bank = try NativeMTPSelfTest.parseChallengeBank(data)
        guard bank.releaseID == admissionCapability.selfTestChallengeBank.releaseID,
              bank.signerKeyID == admissionCapability.selfTestChallengeBank.signerKeyID else {
            throw NativeMTPSelfTestError.challengeBankMismatch
        }
        let matches = bank.entries.filter {
            $0.modelID == admissionCapability.modelID
                && $0.modelHash == admissionCapability.targetArtifactSHA256
                && $0.tokenizerSHA256 == admissionCapability.tokenizerSHA256
                && $0.artifactSHA256 == admissionCapability.mtpArtifactSHA256
                && $0.mtpManifestSHA256 == admissionCapability.mtpManifestSHA256
                && $0.fixedProposalDepth <= admissionCapability.maxProposalDepth
                && $0.promptTokenIDs.count <= admissionCapability.maxPromptTokens
                && $0.maxCompletionTokens <= admissionCapability.maxCompletionTokens
        }
        guard matches.count == 1,
              let selected = matches.first,
              try NativeMTPSelfTest.selectChallenge(bank, challengeID: selected.challengeID) == selected
        else {
            throw NativeMTPSelfTestError.challengeBankMismatch
        }
        return selected
    }

    private static func readNativeMTPSelfTestBank(_ url: URL) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= 4 * 1024 * 1024
        else {
            throw NativeMTPSelfTestError.challengeBankMismatch
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func nativeMTPSelfTestRuntimeTuple(
        admissionCapability: NativeMTPAdmissionCapability,
        runningBuildIdentity: NativeMTPRunningBuildIdentity,
        selectedChallenge: NativeMTPSelfTestChallenge,
        targetGeneration: UInt64
    ) throws -> NativeMTPSelfTestRuntimeTuple {
        let stateDigest = try nativeMTPServedStateDigest(
            admissionCapability: admissionCapability,
            selectedChallenge: selectedChallenge,
            targetGeneration: targetGeneration
        )
        return NativeMTPSelfTestRuntimeTuple(
            modelID: selectedChallenge.modelID,
            modelHash: selectedChallenge.modelHash,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            tokenizerDigest: selectedChallenge.tokenizerSHA256,
            artifactDigest: selectedChallenge.artifactSHA256,
            manifestDigest: selectedChallenge.mtpManifestSHA256,
            sidecarDigest: admissionCapability.sidecarSHA256,
            providerBinarySHA256: runningBuildIdentity.reproducibleBuildSHA256,
            runtimeCDHash: runningBuildIdentity.liveExecutableCDHash,
            cacheNamespace: "native_mtp:\(admissionCapability.tupleSHA256):\(selectedChallenge.challengeID)",
            stateDigest: stateDigest,
            proposalDepth: selectedChallenge.fixedProposalDepth
        )
    }

    private static func nativeMTPServedStateDigest(
        admissionCapability: NativeMTPAdmissionCapability,
        selectedChallenge: NativeMTPSelfTestChallenge,
        targetGeneration: UInt64
    ) throws -> String {
        guard let generation = Int(exactly: targetGeneration) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("native_mtp_selftest.target_generation")
        }
        return try RFC8785JCS.sha256Hex(of: .object([
            "challenge_id": .string(selectedChallenge.challengeID),
            "fixed_proposal_depth": .int(selectedChallenge.fixedProposalDepth),
            "native_mtp_admission_tuple_sha256": .string(admissionCapability.tupleSHA256),
            "schema_version": .int(1),
            "target_generation": .int(generation),
        ]))
    }

    private static func nativeMTPServedSnapshotID(
        admissionCapability: NativeMTPAdmissionCapability,
        runtimeTuple: NativeMTPSelfTestRuntimeTuple,
        selectedChallenge: NativeMTPSelfTestChallenge,
        targetGeneration: UInt64
    ) throws -> String {
        guard let generation = Int(exactly: targetGeneration) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("native_mtp_served_snapshot.target_generation")
        }
        return try RFC8785JCS.sha256Hex(of: .object([
            "challenge_id": .string(selectedChallenge.challengeID),
            "native_mtp_admission_tuple_sha256": .string(admissionCapability.tupleSHA256),
            "runtime_tuple_sha256": .string(try NativeMTPSelfTest.runtimeTupleDigest(runtimeTuple)),
            "schema_version": .int(1),
            "target_generation": .int(generation),
        ]))
    }

    private static func nativeMTPCapturedTokenizerDirectory(targetURL: URL, tokenizerURL: URL) -> URL? {
        let targetURL = targetURL.standardizedFileURL
        let tokenizerURL = tokenizerURL.standardizedFileURL
        guard tokenizerURL.deletingLastPathComponent() == targetURL,
              tokenizerURL.lastPathComponent == "tokenizer.json",
              BYOMArtifactPathPolicy.isContained(tokenizerURL, in: targetURL)
        else {
            return nil
        }
        return targetURL
    }

    static func nativeMTPCapturedTokenizerDirectoryForTest(targetURL: URL, tokenizerURL: URL) -> URL? {
        nativeMTPCapturedTokenizerDirectory(targetURL: targetURL, tokenizerURL: tokenizerURL)
    }

    private static func nativeMTPArtifactObservationMatchesAdmission(
        _ observation: NativeMTPArtifactPairObservation?,
        admissionCapability: NativeMTPAdmissionCapability
    ) -> Bool {
        guard let observation else { return false }
        guard observation.target.format.sidecarQuantizationLabel == admissionCapability.quantization.target
            && observation.mtp.format.sidecarQuantizationLabel == admissionCapability.quantization.mtp
            && observation.target.mtpPredictionLayerCount == admissionCapability.predictionLayerCount
            && observation.mtp.mtpPredictionLayerCount == admissionCapability.predictionLayerCount
        else {
            return false
        }
        // Every signed quantization field is recomputed from the observed
        // artifacts; a kind the observer cannot recompute never admits.
        let quantization = admissionCapability.quantization
        switch (quantization.target, quantization.mtp) {
        case ("mlx_affine_4bit", "mlx_affine_4bit"):
            guard let representation = try? NativeMTPArtifactObserver.affineRepresentation(for: observation) else {
                return false
            }
            return representation.groupSize == quantization.blockSizeElements
                && representation.manifestSHA256 == quantization.representationManifestSHA256
                && representation.perLayerExceptions == quantization.perLayerExceptions
                && representation.unquantizedExceptions == quantization.unquantizedExceptions
        case ("bf16", "bf16"):
            guard let representation = try? NativeMTPArtifactObserver.baseRepresentation(for: observation) else {
                return false
            }
            return quantization.blockSizeElements == nil
                && representation.manifestSHA256 == quantization.representationManifestSHA256
                && quantization.perLayerExceptions.isEmpty
                && quantization.unquantizedExceptions.isEmpty
        default:
            return false
        }
    }

    static func nativeMTPArtifactObservationMatchesAdmissionForTest(
        _ observation: NativeMTPArtifactPairObservation?,
        admissionCapability: NativeMTPAdmissionCapability
    ) -> Bool {
        nativeMTPArtifactObservationMatchesAdmission(
            observation,
            admissionCapability: admissionCapability
        )
    }

    /// A native-MTP family adapter and the artifact layout it ships in
    /// (SPEC-048 MTP-2: the adapter string determines the layout).
    struct NativeMTPAdapterLayout: Hashable, Sendable {
        let familyAdapter: String
        let sourceLayout: String
    }

    /// Where an admitted adapter's drafter comes from.
    enum NativeMTPDrafterSource: Equatable, Sendable {
        /// A separate drafter artifact, loaded through `MTPDrafterModelFactory`.
        case separateArtifact
        /// The next-N layer inside the target (`checkpoint_mtp`): a
        /// parameterless drafter that resolves the loaded target's own
        /// `mtp[0]` layer, embeddings and lm_head, built from the target's
        /// `config.json` without a second weight load.
        case targetEmbedded
    }

    /// The (adapter, layout) pairs this provider can serve natively.
    static let nativeMTPSupportedAdapterLayouts: Set<NativeMTPAdapterLayout> = [
        NativeMTPAdapterLayout(familyAdapter: "qwen3_5_mtp_v1", sourceLayout: "separate_artifact"),
        NativeMTPAdapterLayout(familyAdapter: "glm5_next_mtp_v1", sourceLayout: "checkpoint_mtp"),
    ]

    static func nativeMTPDrafterSource(familyAdapter: String) -> NativeMTPDrafterSource? {
        switch familyAdapter {
        case "qwen3_5_mtp_v1": .separateArtifact
        case "glm5_next_mtp_v1": .targetEmbedded
        default: nil
        }
    }

    private static func nativeMTPAdmissionCapabilitySupported(
        _ admissionCapability: NativeMTPAdmissionCapability,
        canonicalCacheClass: String,
        modelCapabilities: PagedKVRuntimeModelCapabilities,
        cacheKinds: [PagedKVSharedForwardBackend.CacheKind]?,
        drafterPresent: Bool
    ) -> Bool {
        let layout = NativeMTPAdapterLayout(
            familyAdapter: admissionCapability.familyAdapter,
            sourceLayout: admissionCapability.sourceLayout
        )
        guard nativeMTPSupportedAdapterLayouts.contains(layout),
              admissionCapability.predictionLayerCount == admissionCapability.maxProposalDepth,
              admissionCapability.cacheClass == canonicalCacheClass,
              admissionCapability.stateClass == nativeMTPExpectedStateClass(modelCapabilities: modelCapabilities),
              drafterPresent
        else { return false }
        guard nativeMTPDrafterSource(familyAdapter: layout.familyAdapter) == .targetEmbedded else {
            return true
        }
        return glm5NextNativeMTPTopologySupported(
            maxProposalDepth: admissionCapability.maxProposalDepth,
            modelCapabilities: modelCapabilities,
            cacheKinds: cacheKinds
        )
    }

    /// `glm5_next_mtp_v1` (SPEC-048 MTP-2, SPEC-039 FR-PKV12/FR-PKV15): the
    /// exact verified KDA + `pagedMLA` topology and the 8-token forward bound
    /// in force with one row's verification inside it. Packed verification
    /// runs KDA rows through `MTPPackedMambaBatchCache` and `pagedMLA` rows
    /// through `PagedMLABatchLayerCache`.
    private static func glm5NextNativeMTPTopologySupported(
        maxProposalDepth: Int,
        modelCapabilities: PagedKVRuntimeModelCapabilities,
        cacheKinds: [PagedKVSharedForwardBackend.CacheKind]?
    ) -> Bool {
        guard modelCapabilities.modelFamily == "glm5_next",
              modelCapabilities.hybridDecoderArchitectureVerified,
              let layout = modelCapabilities.sparseAttention,
              let cacheKinds,
              cacheKinds == layout.expectedCacheKinds,
              let cap = PagedKVSharedForwardBackend.maxFlattenedTokensPerForward(cacheKinds: cacheKinds),
              cap == PagedKVSharedForwardBackend.pagedMLAMaxFlattenedTokensPerForward,
              maxProposalDepth >= 1,
              maxProposalDepth + 1 <= cap
        else { return false }
        return true
    }

    static func nativeMTPAdmissionCapabilitySupportedForTest(
        _ admissionCapability: NativeMTPAdmissionCapability,
        canonicalCacheClass: String,
        modelCapabilities: PagedKVRuntimeModelCapabilities,
        cacheKinds: [PagedKVSharedForwardBackend.CacheKind]? = nil,
        drafterPresent: Bool = true
    ) -> Bool {
        nativeMTPAdmissionCapabilitySupported(
            admissionCapability,
            canonicalCacheClass: canonicalCacheClass,
            modelCapabilities: modelCapabilities,
            cacheKinds: cacheKinds,
            drafterPresent: drafterPresent
        )
    }

    /// Whether the adapter's drafter can exist for this target: a separate
    /// artifact is checked at its own load; an embedded drafter needs the
    /// target loaded with its next-N weights.
    static func nativeMTPDrafterPresent(
        familyAdapter: String,
        targetContainer: ModelContainer
    ) async -> Bool {
        switch nativeMTPDrafterSource(familyAdapter: familyAdapter) {
        case .separateArtifact: return true
        case nil: return false
        case .targetEmbedded:
            return await targetContainer.perform { context in
                switch context.model {
                case let model as GLM5NextModel: model.languageModel.hasMTPWeights
                case let model as GLM5NextTextModel: model.hasMTPWeights
                default: false
                }
            }
        }
    }

    /// The drafter container for an admitted adapter. A `checkpoint_mtp`
    /// drafter is built from the target's `config.json` through the drafter
    /// type registry, never through `MTPDrafterModelFactory`, which would
    /// read the target's weight files a second time for a model that owns no
    /// parameters.
    static func loadNativeMTPDrafterContainer(
        familyAdapter: String,
        targetDirectory: URL,
        drafterDirectory: URL,
        tokenizerLoader: any TokenizerLoader
    ) async throws -> MTPDrafterContainer {
        switch nativeMTPDrafterSource(familyAdapter: familyAdapter) {
        case .separateArtifact:
            await Qwen35TextMTPRegistration.register()
            return try await MTPDrafterModelFactory.shared.loadContainer(
                from: drafterDirectory,
                using: tokenizerLoader
            )
        case .targetEmbedded:
            await GLM5NextMTPRegistration.register()
            let configData = try Data(contentsOf: targetDirectory.appendingPathComponent("config.json"))
            guard let object = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
                  let modelType = object["model_type"] as? String
            else {
                throw NativeMTPDrafterLoadError.unsupportedAdapter(familyAdapter)
            }
            let model = try await MTPDrafterTypeRegistry.shared.createModel(
                configuration: configData,
                modelType: modelType
            )
            return MTPDrafterContainer(context: MTPDrafterContext(
                configuration: ModelConfiguration(directory: targetDirectory, tokenizerSource: nil, defaultPrompt: ""),
                model: model
            ))
        case nil:
            throw NativeMTPDrafterLoadError.unsupportedAdapter(familyAdapter)
        }
    }

    private static func nativeMTPExpectedStateClass(
        modelCapabilities: PagedKVRuntimeModelCapabilities
    ) -> String {
        modelCapabilities.hybridDecoderArchitectureVerified
            ? "hybrid_stageable_rewindable"
            : "stageable_rewindable"
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

    private nonisolated static func withDrainAndClientCancellation<T: Sendable>(
        _ token: DrainCancelToken,
        shouldCancel: @escaping @Sendable () -> Bool,
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
            group.addTask {
                while !shouldCancel() {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                throw CancellationError()
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

    /// Detect the thinking toggle from the exact template bytes instead of
    /// inferring it from a model-family name.
    static func chatTemplateSupportsThinkingToggle(in directory: URL) -> Bool {
        chatTemplate(in: directory, contains: "enable_thinking")
    }

    static func chatTemplateSupportsPreserveThinking(in directory: URL) -> Bool {
        chatTemplate(in: directory, contains: "preserve_thinking")
    }

    private static func chatTemplate(in directory: URL, contains markerText: String) -> Bool {
        let fileManager = FileManager.default
        let marker = Data(markerText.utf8)

        for name in ["chat_template.jinja", "chat_template.json", "chat_template.txt", "tokenizer_config.json"] {
            let url = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
            else {
                continue
            }
            if data.range(of: marker) != nil {
                return true
            }
        }
        return false
    }

    static func thinkingToggleCapabilities(
        for authorities: [String: ModelRuntimeTargetAuthority]
    ) -> [String: Bool] {
        var byModelArgument: [String: Bool] = [:]
        var capabilities: [String: Bool] = [:]
        capabilities.reserveCapacity(authorities.count)

        for authority in authorities.values {
            let supported = byModelArgument[authority.modelArgument] ?? {
                let value = chatTemplateSupportsThinkingToggle(
                    in: URL(fileURLWithPath: authority.modelArgument, isDirectory: true)
                )
                byModelArgument[authority.modelArgument] = value
                return value
            }()
            let artifactSHA256 = authority.artifactSHA256.lowercased(with: nil)
            if let existing = capabilities[artifactSHA256], existing != supported {
                capabilities[artifactSHA256] = false
            } else {
                capabilities[artifactSHA256] = supported
            }
        }
        return capabilities
    }

    static func preserveThinkingCapabilities(
        for authorities: [String: ModelRuntimeTargetAuthority]
    ) -> [String: Bool] {
        var byModelArgument: [String: Bool] = [:]
        var capabilities: [String: Bool] = [:]
        capabilities.reserveCapacity(authorities.count)

        for authority in authorities.values {
            let supported = byModelArgument[authority.modelArgument] ?? {
                let directory = URL(fileURLWithPath: authority.modelArgument, isDirectory: true)
                let value = chatTemplateSupportsThinkingToggle(in: directory)
                    && chatTemplateSupportsPreserveThinking(in: directory)
                byModelArgument[authority.modelArgument] = value
                return value
            }()
            let artifactSHA256 = authority.artifactSHA256.lowercased(with: nil)
            if let existing = capabilities[artifactSHA256], existing != supported {
                capabilities[artifactSHA256] = false
            } else {
                capabilities[artifactSHA256] = supported
            }
        }
        return capabilities
    }

    static func resolvedTemplateSupportsThinkingToggle(
        artifactSHA256: String?,
        configuredArtifactSHA256: String?,
        configuredSupportsThinkingToggle: Bool,
        targetCapabilitiesByArtifactSHA256: [String: Bool]
    ) -> Bool {
        guard let artifactSHA256 = nonEmpty(artifactSHA256)?.lowercased(with: nil) else {
            return false
        }
        if let supported = targetCapabilitiesByArtifactSHA256[artifactSHA256] {
            return supported
        }
        guard artifactSHA256 == nonEmpty(configuredArtifactSHA256)?.lowercased(with: nil) else {
            return false
        }
        return configuredSupportsThinkingToggle
    }

    static func resolvedTemplateSupportsPreserveThinking(
        artifactSHA256: String?,
        configuredArtifactSHA256: String?,
        configuredSupportsPreserveThinking: Bool,
        targetCapabilitiesByArtifactSHA256: [String: Bool]
    ) -> Bool {
        guard let artifactSHA256 = nonEmpty(artifactSHA256)?.lowercased(with: nil) else {
            return false
        }
        if let supported = targetCapabilitiesByArtifactSHA256[artifactSHA256] {
            return supported
        }
        guard artifactSHA256 == nonEmpty(configuredArtifactSHA256)?.lowercased(with: nil) else {
            return false
        }
        return configuredSupportsPreserveThinking
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
        // Each chunk is an autoreleased NSData; without a pool per chunk a
        // whole artifact's bytes stay resident until the caller's pool drains
        // (a 186 GB model doubled its load peak and was killed).
        while try autoreleasepool(invoking: {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
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

    static func applyOutputFilters(
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

    struct LabSerialDecodeHooks: Sendable {
        let requestID: String
        let outputCap: Int?
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        let timingObserver: NativeMTPLabCommittedTokenTimingObserver?
        #endif
    }

    final class LabSerialCommitTracker: @unchecked Sendable {
        private let requestID: String
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        private let observer: NativeMTPLabCommittedTokenTimingObserver?
        #endif
        private var committedOutputCount = 0

        #if DEBUG || MACPROVIDER_LAB_HARNESS
        init(requestID: String, observer: NativeMTPLabCommittedTokenTimingObserver?) {
            self.requestID = requestID
            self.observer = observer
        }
        #else
        init(requestID: String) {
            self.requestID = requestID
        }
        #endif

        func record(outputCount: Int) {
            #if DEBUG || MACPROVIDER_LAB_HARNESS
            guard let observer else {
                committedOutputCount = max(committedOutputCount, outputCount)
                return
            }
            let boundedOutputCount = max(committedOutputCount, outputCount)
            guard boundedOutputCount > committedOutputCount else { return }
            for ordinal in committedOutputCount ..< boundedOutputCount {
                observer.record(requestID: requestID, ordinal: ordinal, outputCount: ordinal + 1)
            }
            committedOutputCount = boundedOutputCount
            #else
            committedOutputCount = max(committedOutputCount, outputCount)
            _ = requestID
            #endif
        }
    }

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    private func recordLabNativeMTPConversationCacheBegin(
        request: ChatCompletionRequest,
        surface: String,
        leaseAllowed: Bool,
        lease: ConversationCacheLease?,
        modelHasRecurrentLayers: Bool
    ) {
        guard let observer = labNativeMTPConversationCacheObserver else { return }
        observer.record(NativeMTPLabConversationCacheObserver.event(
            requestID: request.requestID,
            surface: surface,
            keyPresent: Self.nonEmpty(request.conversationKey) != nil,
            cacheOnly: request.conversationCacheOnly,
            leaseAllowed: leaseAllowed,
            lease: lease,
            modelHasRecurrentLayers: modelHasRecurrentLayers
        ))
    }
    #endif

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    static func labSerialDecodeHooks(
        requestID: String?,
        outputCap: NativeMTPLabDecodeOutputCap?,
        timingObserver: NativeMTPLabCommittedTokenTimingObserver?
    ) throws -> LabSerialDecodeHooks? {
        guard outputCap != nil || timingObserver != nil else { return nil }
        guard let requestID, !requestID.isEmpty else {
            throw labSerialDecodeHookUnsupported("missing_request_id")
        }
        return LabSerialDecodeHooks(
            requestID: requestID,
            outputCap: outputCap?.cap(requestID: requestID),
            timingObserver: timingObserver
        )
    }
    #endif

    static func labSerialVisibleCommitCount(
        modelID: String,
        generatedTokenIDs: [Int],
        decodedText: String,
        emittedText: String?,
        stopTokenFilter: StopTokenFilter,
        requestStops: [String]
    ) throws -> Int {
        guard !HarmonyResponseParser.isHarmonyModelID(modelID) else {
            throw labSerialDecodeHookUnsupported("harmony_visible_prefix_accounting")
        }
        let filtered = applyOutputFilters(
            decodedText,
            stopTokenFilter: stopTokenFilter,
            requestStops: requestStops
        )
        guard !filtered.hitStop, filtered.text == decodedText else {
            throw labSerialDecodeHookUnsupported("filtered_visible_prefix_accounting")
        }
        if let emittedText, emittedText != decodedText {
            throw labSerialDecodeHookUnsupported("emitted_visible_prefix_accounting")
        }
        return generatedTokenIDs.count
    }

    static func labSerialLengthFinish(
        generatedCompletionTokens: Int,
        requestMaxTokens: Int?,
        labOutputCap: Int?
    ) -> Bool {
        if let labOutputCap {
            return generatedCompletionTokens >= labOutputCap
        }
        return requestMaxTokens.map { generatedCompletionTokens >= $0 } ?? false
    }

    static func labSerialEffectiveMaxTokens(requestMaxTokens: Int?, labOutputCap: Int?) -> Int? {
        guard let labOutputCap else { return requestMaxTokens }
        guard let requestMaxTokens else { return labOutputCap }
        return min(requestMaxTokens, labOutputCap)
    }

    private static func labSerialDecodeHookUnsupported(_ reason: String) -> APIError {
        APIError(
            status: 502,
            message: "LAB serial decode replay hook unsupported for this request: \(reason)",
            type: "upstream_provider_error",
            code: "lab_serial_decode_hook_unsupported",
            inferenceRan: false,
            settlementRan: false
        )
    }

    /// SPEC-024 FR-CI2 hybrid reuse. For a keyed serial request on a model with
    /// recurrent layers, prefill `cache` from the tokens it already holds up to each
    /// recurrent checkpoint position (`ConversationCache.recurrentCheckpointPositions`)
    /// and snapshot the recurrent states there. Checkpoint positions the restored
    /// cache is already past reuse the stored checkpoint at that exact length (still
    /// a prefix of this prompt). `resumeAt` is the prompt index the TokenIterator
    /// must continue from, or nil when nothing was prefilled here.
    static func prefillRecurrentCheckpoints(
        lease: ConversationCacheLease?,
        cache: [KVCache],
        promptTokenIds: [Int32],
        context: ModelContext,
        prefillStepSize: Int
    ) -> (checkpoints: [RecurrentStateCheckpoint], resumeAt: Int?) {
        guard let lease else { return ([], nil) }
        let positions = ConversationCache.recurrentCheckpointPositions(
            promptTokenIds: promptTokenIds,
            imStartTokenID: context.tokenizer.convertTokenToId("<|im_start|>").map(Int32.init),
            hybrid: ConversationCacheLayers.hasRecurrentLayers(cache),
            decode: { context.tokenizer.decode(tokenIds: $0) })
        guard !positions.isEmpty else { return ([], nil) }
        let cachedTokens = lease.reusableCache == nil ? 0 : lease.lcp
        let reusable = lease.reusableCache?.recurrentCheckpoints ?? []
        var cursor = cachedTokens
        var checkpoints: [RecurrentStateCheckpoint] = []
        for position in positions {
            if position < cursor {
                if let stored = reusable.first(where: { $0.tokenCount == position }) {
                    checkpoints.append(stored)
                }
                continue
            }
            var start = cursor
            while start < position {
                let end = min(start + max(1, prefillStepSize), position)
                let chunk = LMInput.Text(tokens: MLXArray(Array(promptTokenIds[start..<end])))
                _ = context.model(chunk[text: .newAxis], cache: cache, state: nil)
                asyncEval(cache)
                start = end
            }
            eval(cache)
            cursor = position
            guard let checkpoint = captureRecurrentCheckpoint(cache: cache, tokenCount: position) else {
                return (checkpoints, cursor > cachedTokens ? cursor : nil)
            }
            checkpoints.append(checkpoint)
        }
        return (checkpoints, cursor > cachedTokens ? cursor : nil)
    }

    /// SPEC-001-R011: prefills `[start, tokenCount)` in `stepSize` chunks,
    /// checking `isCancelled` before each chunk, and leaves the final
    /// (at most `stepSize`) tokens for the TokenIterator, exactly as its own
    /// prefill would. Returns the index the iterator continues from.
    static func cancellableLocalPrefill(
        tokenCount: Int,
        from start: Int,
        stepSize: Int,
        isCancelled: () -> Bool,
        prefill: (Range<Int>) throws -> Void
    ) throws -> Int {
        let step = max(1, stepSize)
        var cursor = max(0, start)
        while tokenCount - cursor > step {
            if isCancelled() { throw CancellationError() }
            try prefill(cursor ..< cursor + step)
            cursor += step
        }
        if isCancelled() { throw CancellationError() }
        return cursor
    }

    static func captureRecurrentCheckpoint(cache: [KVCache], tokenCount: Int) -> RecurrentStateCheckpoint? {
        var states: [Int: [MLXArray]] = [:]
        for (index, layer) in cache.enumerated() where layer is ArraysCache {
            let state = layer.state
            guard !state.isEmpty else { return nil }
            states[index] = state
        }
        guard !states.isEmpty else { return nil }
        return RecurrentStateCheckpoint(tokenCount: tokenCount, states: states)
    }

    static func serialHybridCacheCanPublishTerminalCheckpoint(
        cache: [KVCache],
        terminalModelStopStripped: Bool
    ) -> Bool {
        guard ConversationCacheLayers.hasRecurrentLayers(cache) else { return true }
        return !terminalModelStopStripped
    }

    static func serialTerminalModelStopStripped(
        rawLengthFinish: Bool,
        hitStop: Bool,
        parsedHitStop: Bool,
        harmonyTerminalFinish: Bool,
        stoppedBySerialToolCall: Bool
    ) -> Bool {
        !rawLengthFinish
            && !hitStop
            && !parsedHitStop
            && !harmonyTerminalFinish
            && !stoppedBySerialToolCall
    }

    static func serialTerminalRecurrentCheckpoints(
        promptCheckpoints: [RecurrentStateCheckpoint],
        cache: [KVCache],
        tokenCount: Int
    ) -> [RecurrentStateCheckpoint]? {
        var checkpoints = promptCheckpoints
        guard ConversationCacheLayers.hasRecurrentLayers(cache),
              tokenCount >= ConversationCache.lcpThreshold
        else {
            return checkpoints
        }
        if checkpoints.contains(where: { $0.tokenCount == tokenCount }) {
            return checkpoints
        }
        guard let terminalCheckpoint = captureRecurrentCheckpoint(cache: cache, tokenCount: tokenCount) else {
            return nil
        }
        checkpoints.append(terminalCheckpoint)
        return checkpoints.sorted { $0.tokenCount < $1.tokenCount }
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

    static func streamingSafePrefix(
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
        let safe = holdback > 0 ? String(filtered.text.dropLast(holdback)) : filtered.text
        return (withoutIncompleteUTF8Tail(safe), false)
    }

    struct SerialDecodeRequestStopObserver {
        private let enabled: Bool
        private let modelID: String
        private let stopTokenFilter: StopTokenFilter
        private let requestStops: [String]
        private let decode: ([Int]) -> String
        private var harmonyParser: HarmonyResponseParser.StreamingParser?
        private var harmonyObservedTokenCount = 0

        init(
            modelID: String,
            stopTokenFilter: StopTokenFilter,
            requestStops: [String],
            allowedFunctionNames: Set<String>? = nil,
            decode: @escaping ([Int]) -> String,
            decodeFinalToken: ((Int) -> String?)? = nil
        ) {
            self.enabled = requestStops.contains { !$0.isEmpty }
            self.modelID = modelID
            self.stopTokenFilter = stopTokenFilter
            self.requestStops = requestStops
            self.decode = decode
            if enabled, HarmonyResponseParser.isHarmonyModelID(modelID) {
                self.harmonyParser = HarmonyResponseParser.StreamingParser(
                    decode: decode,
                    decodeFinalToken: decodeFinalToken,
                    allowedFunctionNames: allowedFunctionNames,
                    stopCandidates: stopTokenFilter.tokens + requestStops
                )
            } else {
                self.harmonyParser = nil
            }
        }

        mutating func observe(generatedTokenIDs: [Int]) throws -> Bool {
            guard enabled else { return false }
            guard HarmonyResponseParser.isHarmonyModelID(modelID) else {
                return ModelRuntime.streamingSafePrefix(
                    decode(generatedTokenIDs),
                    stopTokenFilter: stopTokenFilter,
                    requestStops: requestStops
                ).hitStop
            }
            guard generatedTokenIDs.count >= harmonyObservedTokenCount else {
                throw ModelRuntime.malformedHarmonyResponseError()
            }
            guard var parser = harmonyParser else {
                throw ModelRuntime.malformedHarmonyResponseError()
            }
            let newTokenIDs = Array(generatedTokenIDs.dropFirst(harmonyObservedTokenCount))
            harmonyObservedTokenCount = generatedTokenIDs.count
            let parsed = parser.parse(newTokenIDs: newTokenIDs)
            harmonyParser = parser
            let output = try ModelRuntime.harmonyParsedOutput(
                from: parsed,
                decode: decode,
                stopTokenFilter: stopTokenFilter,
                requestStops: requestStops,
                countCompletionTokens: false
            )
            return output.hitStop
        }
    }

    /// #1690 E2E-F13: a decode of a token prefix that ends inside a
    /// multi-byte UTF-8 character renders the partial bytes as trailing
    /// U+FFFD, which the next token replaces with the real character. Such a
    /// tail is never streamed; the final decode flushes it as it renders.
    static func withoutIncompleteUTF8Tail(_ text: String) -> String {
        var scalars = text.unicodeScalars
        while scalars.last == "\u{FFFD}" {
            scalars.removeLast()
        }
        return String(scalars)
    }

    /// The text to append so the streamed bytes become `current`: exact on
    /// Unicode scalars, not Characters, so a combining mark or a completed
    /// grapheme cluster never makes `emitted` look like a non-prefix or a
    /// dropped Character eat scalars. Empty when `current` does not extend
    /// `emitted` (never a lossy or out-of-order fragment).
    static func streamDelta(from emitted: String, to current: String) -> String {
        let emittedScalars = emitted.unicodeScalars
        let currentScalars = current.unicodeScalars
        guard currentScalars.starts(with: emittedScalars) else { return "" }
        var appended = String.UnicodeScalarView()
        appended.append(contentsOf: currentScalars.dropFirst(emittedScalars.count))
        return String(appended)
    }

    /// A decode may rewrite an already-visible space during tokenizer cleanup.
    /// Resume from the rewritten decode's scalar prefix; buyer-visible bytes
    /// already sent remain immutable.
    static func streamDeltaAfterCleanupRewrite(from previous: String, to current: String) -> String {
        let previousScalars = previous.unicodeScalars
        let currentScalars = current.unicodeScalars
        var commonPrefixCount = 0
        var previousIndex = previousScalars.startIndex
        var currentIndex = currentScalars.startIndex
        while previousIndex != previousScalars.endIndex,
              currentIndex != currentScalars.endIndex,
              previousScalars[previousIndex] == currentScalars[currentIndex]
        {
            commonPrefixCount += 1
            previousScalars.formIndex(after: &previousIndex)
            currentScalars.formIndex(after: &currentIndex)
        }
        var appended = String.UnicodeScalarView()
        appended.append(contentsOf: currentScalars.dropFirst(commonPrefixCount))
        return String(appended)
    }

    static func removingAlreadyEmittedRewritePrefix(
        from delta: String,
        emittedSuffix: String
    ) -> String {
        let emittedScalars = Array(emittedSuffix.unicodeScalars)
        let deltaScalars = delta.unicodeScalars
        for count in stride(from: min(emittedScalars.count, deltaScalars.count), through: 1, by: -1) {
            if emittedScalars.suffix(count).elementsEqual(deltaScalars.prefix(count)) {
                return String(deltaScalars.dropFirst(count))
            }
        }
        return delta
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
        streamDelta(from: emitted, to: current)
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
        globalHitStop: Bool = false,
        toolCallPrefill: String?
    ) throws -> ParsedGeneratedOutput {
        guard HarmonyResponseParser.isHarmonyModelID(request.model) else {
            if try ToolSelectionPolicy.selection(request.promptSource.toolChoice).requiresCall,
               case .complete(let finishReason) = mode, finishReason == "length" {
                throw ToolSelectionPolicy.outputError("Tool generation exhausted its token budget")
            }
            let parsed = try parseToolCallsIfRequested(filteredText, request: request, toolCallPrefill: toolCallPrefill)
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
            stopCandidates: stopTokenFilter.tokens,
            requestStops: requestStops
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
            message: "Harmony response did not produce a valid final channel. This most often means the reasoning budget was exhausted before the model reached its final answer; retry with a higher max_tokens or a lower reasoning effort. It can also indicate malformed Harmony tool-call framing.",
            type: "upstream_provider_error",
            code: "malformed_tool_call_final_json",
            inferenceRan: true,
            settlementRan: true
        )
    }

    static func streamedToolCallArgumentsMismatchError() -> APIError {
        APIError(
            status: 502,
            message: "Streamed tool-call arguments did not match the finalized tool call",
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

    /// SPEC-018 serial tool turn (`parallel_tool_calls` omitted/false) on a
    /// non-Harmony model with tools: generation stops once the first tool
    /// call is complete and valid. Guaranteed selection runs to the normal
    /// terminal so cardinality validation can inspect the entire output.
    static func serialToolStopApplies(_ request: ChatCompletionRequest) -> Bool {
        request.stopsAfterFirstCompleteToolCall
            && (try? ToolSelectionPolicy.selection(request.promptSource.toolChoice).requiresCall) != true
            && !HarmonyResponseParser.isHarmonyModelID(request.model)
            && hasEnabledTools(request.promptSource.tools)
    }

    static func serialNativeToolStopApplies(_ request: ChatCompletionRequest) -> Bool {
        serialToolStopApplies(request)
            && NativeToolCallStreamEmitter.supports(modelID: request.model)
    }

    /// One serial-tool-turn stop test over the decode of every token so far.
    /// The serial non-streaming path and the continuous-batching rows
    /// (SPEC-038 AC-6c) share it, so both stop at the same token.
    static func observeSerialToolStop(
        _ observer: inout NativeToolCallStreamEmitter,
        decoded: String,
        stopTokenFilter: StopTokenFilter,
        requestStops: [String],
        guaranteedSelection: Bool = false
    ) -> Bool {
        guard !guaranteedSelection else { return false }
        let candidate = streamingSafePrefix(
            decoded,
            stopTokenFilter: stopTokenFilter,
            requestStops: requestStops
        )
        _ = observer.observe(candidate.text)
        return observer.hasCompletedValidToolCall
    }

    private static func parseToolCallsIfRequested(
        _ text: String,
        request: ChatCompletionRequest,
        toolCallPrefill: String?
    ) throws -> (content: String, toolCalls: [ToolCall]) {
        if try ToolSelectionPolicy.selection(request.promptSource.toolChoice).requiresCall {
            // The prompt ended inside the call: parse prefill + continuation.
            // Without calls the turn fails validation; the content is only the
            // generated text, never the prefill.
            let calls = try ToolCallParser.parseGuaranteedToolCalls(
                (toolCallPrefill ?? "") + text, schemas: try ToolSelectionPolicy.schemas(request)
            )
            return (calls.isEmpty ? text : "", calls)
        }
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
        if request.stopsAfterFirstCompleteToolCall, parsed.toolCalls.count > 1 {
            return ("", Array(parsed.toolCalls.prefix(1)))
        }
        return ("", parsed.toolCalls)
    }

    /// Any json_object or json_schema request, strict or not (SPEC-019 §1a).
    /// Routing gates that depend on the rendered structured-output prompt use
    /// this; post-inference validation and holdback use
    /// `requiresStructuredValidation`.
    static func isStructuredResponseFormat(_ responseFormat: ResponseFormat) -> Bool {
        if case .text = responseFormat {
            return false
        }
        return true
    }

    static func requiresStructuredValidation(_ responseFormat: ResponseFormat) -> Bool {
        switch responseFormat {
        case .text:
            return false
        case .jsonObject:
            return true
        case .jsonSchema(let spec):
            // SPEC-019 v0.3.0 §1a: non-strict output is not validated.
            return spec.strict
        }
    }

    static func templateAdditionalContext(
        supportsThinkingToggle: Bool,
        supportsPreserveThinking: Bool = false
    ) -> [String: any Sendable]? {
        guard supportsThinkingToggle else { return nil }
        var context: [String: any Sendable] = ["enable_thinking": false]
        if supportsPreserveThinking {
            context["preserve_thinking"] = true
        }
        return context
    }

    /// Validate media before processor work, test generation seams or dispatch.
    /// Parsing alone is never an assertion that the loaded model sees images.
    static func validateNativeVisionRequest(
        _ request: ChatCompletionRequest, profile: NativeVisionProfile?
    ) throws -> NativeImageInput? {
        if profile != nil {
            for message in request.messages {
                if let text = message.content { try NativeVisionProfile.validateText(text) }
            }
        }
        guard request.containsNonTextMessageContentPart else { return nil }
        guard profile != nil else {
            throw APIError(status: 400, message: "Images are not supported by this model",
                           code: "unsupported_content_shape", param: "messages")
        }
        let choice = try ToolSelectionPolicy.selection(request.promptSource.toolChoice)
        guard case .text = request.responseFormat,
              !hasEnabledTools(request.promptSource.tools),
              choice == .auto,
              !request.conversationCacheOnly else {
            throw APIError(status: 400, message: "Images cannot be combined with tools, structured output or cache-only requests",
                           code: "unsupported_content_shape", param: "messages")
        }
        guard let input = try request.validatedNativeImageInput() else {
            throw APIError(status: 400, message: "Unsupported media content",
                           code: "unsupported_content_shape", param: "messages")
        }
        for message in input.messages {
            // The pinned template concatenates adjacent text parts verbatim.
            // Check the concatenation too: split visual tokens must not create
            // extra processor placeholders that no admitted image owns.
            let text = message.parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }.joined()
            try NativeVisionProfile.validateText(text)
        }
        return input
    }

    static func userInput(
        for request: ChatCompletionRequest,
        templateSupportsThinkingToggle: Bool = false,
        templateSupportsPreserveThinking: Bool = false,
        nativeVisionProfile: NativeVisionProfile? = nil,
        toolSelectionModelID: String? = nil
    ) throws -> UserInput {
        if let input = try validateNativeVisionRequest(request, profile: nativeVisionProfile) {
            return try NativeVisionProfile.userInput(from: input)
        }
        let structuredMessages = try StructuredOutputRenderer.prependResponseFormatInstruction(
            to: request.messages,
            responseFormat: request.responseFormat,
            modelID: request.model
        )
        let selection = try ToolSelectionPolicy.selection(request.promptSource.toolChoice)
        var messages = structuredMessages
        let callCountInstruction = request.parallelToolCalls == true
            ? "Return between 1 and 128 calls."
            : "Return exactly one call."
        switch selection {
        case .required:
            messages = Self.withLeadingSystemInstruction("Call a declared function using complete <tool_call> envelopes in the tool-call format described above. \(callCountInstruction) Return only tool calls; arguments must match the declared schemas.", to: messages)
        case .named(let name):
            messages = Self.withLeadingSystemInstruction("Call the declared function \(name) using a complete <tool_call> envelope in the tool-call format described above. \(callCountInstruction) Return only calls to that function; arguments must match its schema.", to: messages)
        case .none:
            messages = Self.withLeadingSystemInstruction("Do not call any function or tool. Respond with assistant text.", to: messages)
        case .auto: break
        }
        // A profiled identity is the loaded model even when the buyer names it
        // by a local alias, so tool history renders in its template's format.
        let renderModelID = ToolSelectionPolicy.guaranteedCallProfile(modelID: toolSelectionModelID) != nil
            ? toolSelectionModelID ?? request.model
            : request.model
        let chat = try ToolPromptRenderer.renderMessages(messages, modelID: renderModelID)
        let tools: [[String: Any]]?
        switch selection {
        case .none:
            tools = nil
        case .named(let name):
            // SPEC-018 §3.11: the template shows only the selected function.
            tools = Self.mlxToolsForTemplate(from: request.promptSource.tools)?
                .filter { ($0["function"] as? [String: Any])?["name"] as? String == name }
        case .auto, .required:
            tools = Self.mlxToolsForTemplate(from: request.promptSource.tools)
        }
        let additionalContext = Self.templateAdditionalContext(
            supportsThinkingToggle: templateSupportsThinkingToggle,
            supportsPreserveThinking: templateSupportsPreserveThinking
        )
        return UserInput(
            chat: chat,
            tools: tools,
            additionalContext: additionalContext
        )
    }

    /// SPEC-018 §3.11 call prefill for a guaranteed selection on a model with
    /// a guaranteed-call profile; nil for every other request.
    static func toolCallPrefill(
        for request: ChatCompletionRequest,
        toolSelectionModelID: String?
    ) throws -> (prefill: String, generationPromptSuffix: String)? {
        let selection = try ToolSelectionPolicy.selection(request.promptSource.toolChoice)
        guard selection.requiresCall,
              let profile = ToolSelectionPolicy.guaranteedCallProfile(modelID: toolSelectionModelID) else {
            return nil
        }
        // Restricts a named choice to a declared `[A-Za-z0-9_-]` name before
        // it is written into the prompt.
        _ = try ToolSelectionPolicy.schemas(request)
        guard let prefill = profile.prefill(for: selection) else { return nil }
        return (prefill, profile.generationPromptSuffix)
    }

    /// Appends the call prefill to rendered prompt tokens. The prefill goes in
    /// only directly after the template's generation prompt, with any think
    /// block already closed; otherwise nil, and the turn keeps validation only.
    static func appendingToolCallPrefill(
        _ prefill: String,
        generationPromptSuffix: String,
        to promptTokens: [Int],
        tokenizer: any MLXLMCommon.Tokenizer
    ) -> [Int]? {
        let suffix = tokenizer.encode(text: generationPromptSuffix, addSpecialTokens: false)
        let prefillTokens = tokenizer.encode(text: prefill, addSpecialTokens: false)
        // The appended tokens must be exactly what the template would have
        // produced for suffix + prefill as one string.
        guard !suffix.isEmpty, !prefillTokens.isEmpty, promptTokens.count >= suffix.count,
              Array(promptTokens.suffix(suffix.count)) == suffix,
              tokenizer.encode(text: generationPromptSuffix + prefill, addSpecialTokens: false) == suffix + prefillTokens
        else {
            return nil
        }
        return promptTokens + prefillTokens
    }

    /// Request prompt preparation for every serving path. Returns the model
    /// input and the call prefill it ends with, if any; the parser reads the
    /// prefill followed by the generated text, and the prefill is never
    /// buyer-visible content.
    static func preparedRequestInput(
        for request: ChatCompletionRequest,
        context: ModelContext,
        templateSupportsThinkingToggle: Bool,
        templateSupportsPreserveThinking: Bool,
        nativeVisionProfile: NativeVisionProfile? = nil,
        toolSelectionModelID: String?
    ) async throws -> (input: LMInput, toolCallPrefill: String?) {
        // Planned first: it validates the selected name before any prompt text.
        let plan = try toolCallPrefill(for: request, toolSelectionModelID: toolSelectionModelID)
        let input = try userInput(
            for: request,
            templateSupportsThinkingToggle: templateSupportsThinkingToggle,
            templateSupportsPreserveThinking: templateSupportsPreserveThinking,
            nativeVisionProfile: nativeVisionProfile,
            toolSelectionModelID: toolSelectionModelID
        )
        let lmInput = try await context.processor.prepare(input: input)
        guard let plan else {
            return (lmInput, nil)
        }
        guard let tokens = appendingToolCallPrefill(
            plan.prefill,
            generationPromptSuffix: plan.generationPromptSuffix,
            to: lmInput.text.tokens.asArray(Int.self),
            tokenizer: context.tokenizer
        ) else {
            fputs("warning: tool-call prefill skipped; the generation prompt does not end as the profile expects\n", stderr)
            return (lmInput, nil)
        }
        return (LMInput(tokens: MLXArray(tokens.map(Int32.init))), plan.prefill)
    }

    /// Tool-selection instructions join a leading system message, or become
    /// one. Qwen3.6's chat template rejects a system message after index 0, so
    /// a second leading system message would break a buyer's system prompt.
    static func withLeadingSystemInstruction(_ instruction: String, to messages: [ChatMessage]) -> [ChatMessage] {
        guard let first = messages.first, first.role == .system else {
            return [ChatMessage(role: .system, content: instruction)] + messages
        }
        let existing = first.content ?? ""
        var adjusted = messages
        adjusted[0] = ChatMessage(
            role: .system,
            content: existing.isEmpty ? instruction : existing + "\n\n" + instruction,
            toolCallID: first.toolCallID,
            toolCalls: first.toolCalls
        )
        return adjusted
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

    static func validateStructuredCompletion(_ completion: CompletionResult, request: ChatCompletionRequest) throws -> CompletionResult {
        let validationCalls = (completion.toolCalls ?? []).map {
            MacProviderCore.ToolCall(id: $0.id, functionName: $0.functionName, arguments: $0.arguments)
        }
        try ToolSelectionPolicy.validateOutput(
            calls: validationCalls, finishReason: completion.finishReason,
            generatedTokens: completion.generatedCompletionTokens, request: request
        )
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
            guard spec.strict else {
                return completion
            }
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
            settlementDisposition: completion.settlementDisposition,
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
            modelHashObserved: validObservedModelHash(modelHash),
            settlementDisposition: .eligibleOwner
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

    static func hasEnabledTools(_ value: MacProviderCore.JSONValue?) -> Bool {
        toolFunctionNames(from: value) != nil
    }

    static func toolFunctionNames(from value: MacProviderCore.JSONValue?) -> Set<String>? {
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


}

/// The serial streaming path's buyer-visible text step for non-Harmony output:
/// incremental tool-call deltas (SPEC-018), assistant-content suppression once
/// a tool call opens, the SPEC-019 structured-content accumulator, and the
/// serial-tool-turn stop. The serial `stream` path and the continuous-batching
/// stream sink (SPEC-038 AC-6c) both drive this one type, so a batched
/// tool-bearing or structured-output row emits the serial SSE sequence.
struct SerialStreamingTextEmitter {
    enum Step: Equatable {
        case more
        /// A buyer `stop` string matched in the decoded text.
        case requestStop
        /// A serial tool turn completed its first valid tool call.
        case toolCallComplete
        /// The structured-output accumulator refused the delta (its error is
        /// held by the accumulator).
        case structuredError
    }

    private let streamToolsIncrementally: Bool
    private let stopsAfterFirstCompleteToolCall: Bool
    private var toolStreamer: NativeToolCallStreamEmitter
    private var lastEmittedDecodedText = ""
    private var emittedTextSuffix = ""
    private(set) var emittedContent = ""
    private(set) var cleanupRewriteFallbackCount = 0
    private(set) var reconciledToolCalls: [ToolCall] = []
    private let holdsCleanupPatternPrefixes: Bool
    private let holdsCleanupDecoderPendingPrefixes: Bool

    init(
        request: ChatCompletionRequest,
        holdsCleanupPatternPrefixes: Bool = true,
        holdsCleanupDecoderPendingPrefixes: Bool = false
    ) {
        streamToolsIncrementally = ModelRuntime.hasEnabledTools(request.promptSource.tools)
            && !HarmonyResponseParser.isHarmonyModelID(request.model)
        stopsAfterFirstCompleteToolCall = request.stopsAfterFirstCompleteToolCall
        toolStreamer = NativeToolCallStreamEmitter(
            modelID: request.model,
            allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
        )
        self.holdsCleanupPatternPrefixes = holdsCleanupPatternPrefixes
        self.holdsCleanupDecoderPendingPrefixes = holdsCleanupDecoderPendingPrefixes
    }

    /// One decoded prefix of the generation (`streamingSafePrefix` of every
    /// token so far).
    mutating func step(
        candidate: (text: String, hitStop: Bool),
        structuredAccumulator: StructuredStreamingContentAccumulator,
        idleState: StructuredStreamingIdleState,
        onChunk: (StreamChunk) -> Void
    ) -> Step {
        let stableText = holdsCleanupPatternPrefixes
            ? Self.cleanupStablePrefix(
                of: candidate.text,
                includesDecoderPendingPrefixes: holdsCleanupDecoderPendingPrefixes
            )
            : candidate.text
        if streamToolsIncrementally {
            // Capture prose before observing the tool delimiter: observe() flips
            // suppression as soon as a call opens, but cleanup holdback may have
            // deferred the separator immediately before that delimiter.
            let visibleContent = toolStreamer.visibleContentPrefix(of: stableText)
            for event in toolStreamer.observe(stableText) {
                onChunk(event)
            }
            if !visibleContent.isEmpty || !toolStreamer.suppressesAssistantContent {
                let delta = delta(to: visibleContent)
                if !delta.isEmpty {
                    if structuredAccumulator.append(delta) != nil {
                        return .structuredError
                    }
                    idleState.noteContent()
                    noteEmitted(delta)
                    onChunk(.content(delta))
                }
                lastEmittedDecodedText = visibleContent
            }
            if stopsAfterFirstCompleteToolCall, toolStreamer.hasCompletedValidToolCall {
                return .toolCallComplete
            }
            return candidate.hitStop ? .requestStop : .more
        }

        let delta = delta(to: stableText)
        if !delta.isEmpty {
            if structuredAccumulator.append(delta) != nil {
                return .structuredError
            }
            idleState.noteContent()
            noteEmitted(delta)
            onChunk(.content(delta))
        }
        lastEmittedDecodedText = stableText
        return candidate.hitStop ? .requestStop : .more
    }

    /// The end of generation: remaining tool-call deltas over the final
    /// filtered text, then any content the stream held back.
    mutating func finish(
        finalText: String,
        parsed: ModelRuntime.ParsedGeneratedOutput,
        structuredAccumulator: StructuredStreamingContentAccumulator,
        idleState: StructuredStreamingIdleState,
        onChunk: (StreamChunk) -> Void
    ) throws {
        reconciledToolCalls = parsed.toolCalls
        let finalDelta = delta(to: parsed.content)
        if streamToolsIncrementally {
            for event in toolStreamer.observe(finalText) {
                onChunk(event)
            }
            if let deliveredArguments = toolStreamer.deliveredArguments {
                guard let finalizedArguments = parsed.toolCalls.first?.arguments,
                      Data(deliveredArguments.utf8) == Data(finalizedArguments.utf8)
                else {
                    throw ModelRuntime.streamedToolCallArgumentsMismatchError()
                }
                if let deliveredCallID = toolStreamer.deliveredCallID,
                   let first = parsed.toolCalls.first
                {
                    reconciledToolCalls[0] = ToolCall(
                        id: deliveredCallID,
                        functionName: first.functionName,
                        arguments: first.arguments
                    )
                }
            }
            if parsed.toolCalls.isEmpty,
               !parsed.content.isEmpty,
               !toolStreamer.suppressesAssistantContent
            {
                let contentDelta = delta(to: parsed.content)
                if !contentDelta.isEmpty {
                    if let error = structuredAccumulator.append(contentDelta) {
                        throw error
                    }
                    idleState.noteContent()
                    noteEmitted(contentDelta)
                    onChunk(.content(contentDelta))
                }
            }
        } else if !finalDelta.isEmpty {
            if let error = structuredAccumulator.append(finalDelta) {
                throw error
            }
            idleState.noteContent()
            noteEmitted(finalDelta)
            onChunk(.content(finalDelta))
        }
        lastEmittedDecodedText = parsed.content
        assert(
            cleanupRewriteFallbackCount > 0
                || !parsed.toolCalls.isEmpty
                || toolStreamer.suppressesAssistantContent
                || emittedContent == parsed.content,
            "prefix-only streaming must emit content byte-identical to parsed.content"
        )
        if let error = structuredAccumulator.error {
            throw error
        }
    }

    private mutating func delta(to current: String) -> String {
        let delta = ModelRuntime.streamDeltaAfterCleanupRewrite(
            from: lastEmittedDecodedText,
            to: current
        )
        guard !current.unicodeScalars.starts(with: lastEmittedDecodedText.unicodeScalars) else {
            return delta
        }
        cleanupRewriteFallbackCount += 1
        return ModelRuntime.removingAlreadyEmittedRewritePrefix(
            from: delta,
            emittedSuffix: emittedTextSuffix
        )
    }

    private mutating func noteEmitted(_ delta: String) {
        emittedContent += delta
        let scalars = (emittedTextSuffix + delta).unicodeScalars
        emittedTextSuffix = String(scalars.suffix(4))
    }

    static func cleanupStablePrefix(
        of text: String,
        includesDecoderPendingPrefixes: Bool = false
    ) -> String {
        let patterns = [" .", " ?", " !", " ,", " ' ", " n't", " 'm", " 's", " 've", " 're"]
        var heldCharacterCount = 0
        for pattern in patterns {
            let characters = Array(pattern)
            guard characters.count > 1 else { continue }
            for prefixLength in 1..<characters.count {
                let prefix = String(characters.prefix(prefixLength))
                if text.hasSuffix(prefix) {
                    heldCharacterCount = max(heldCharacterCount, prefix.count)
                }
                // ByteLevelIncrementalTextDecoderBox may provisionally expose
                // the characters after the cleanup rule's leading space while
                // that space is still pending (for example "'" for " ' ").
                // They are just as rewritable as the full pattern prefix.
                let pendingPrefix = String(prefix.dropFirst())
                if includesDecoderPendingPrefixes,
                   !pendingPrefix.isEmpty,
                   text.hasSuffix(pendingPrefix)
                {
                    heldCharacterCount = max(heldCharacterCount, pendingPrefix.count)
                }
            }
        }
        guard heldCharacterCount > 0 else { return text }
        return String(text.dropLast(heldCharacterCount))
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
    /// SPEC-018 §3.2: only Qwen 2.5/3 and Llama 3.3 native grammars are recognized.
    /// Unsupported families must not complete a serial stop on lookalike markup.
    private let enabled: Bool
    private var sawToolDelimiter = false
    private var opened = false
    private var closed = false
    private var completedValidToolCall = false
    private var emittedArguments = ""
    private var callID = "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"

    init(modelID: String, allowedFunctionNames: Set<String>?) {
        self.allowedFunctionNames = allowedFunctionNames
        let isQwen = modelID.localizedCaseInsensitiveContains("qwen2.5")
            || modelID.localizedCaseInsensitiveContains("qwen3")
        let isLlama33 = modelID.localizedCaseInsensitiveContains("llama-3.3")
        self.enabled = Self.supports(modelID: modelID)
        self.allowsFunctionXML = isQwen
        if isLlama33 {
            startDelimiter = "<|python_tag|>"
            endDelimiter = "<|eom_id|>"
            argumentKey = "parameters"
        } else {
            startDelimiter = "<tool_call>"
            endDelimiter = "</tool_call>"
            argumentKey = "arguments"
        }
    }

    static func supports(modelID: String) -> Bool {
        modelID.localizedCaseInsensitiveContains("qwen2.5")
            || modelID.localizedCaseInsensitiveContains("qwen3")
            || modelID.localizedCaseInsensitiveContains("llama-3.3")
    }

    var suppressesAssistantContent: Bool { enabled && (opened || sawToolDelimiter) }

    /// True once a declared tool has parser-valid, within-cap arguments (complete
    /// JSON object or closed function-XML). Wrapper-close, prefixes, and cap
    /// failures must not satisfy this; they must not stop a serial turn.
    var hasCompletedValidToolCall: Bool { completedValidToolCall }
    var deliveredArguments: String? { opened ? emittedArguments : nil }
    var deliveredCallID: String? { opened ? callID : nil }

    func visibleContentPrefix(of text: String) -> String {
        guard enabled else { return text }
        if suppressesAssistantContent {
            return ""
        }
        if let start = text.range(of: startDelimiter) {
            return String(text[..<start.lowerBound])
        }
        if allowsFunctionXML, let start = text.range(of: "<function=") {
            return String(text[..<start.lowerBound])
        }
        return Self.stripIncompleteOpenDelimiter(from: text, delimiter: startDelimiter, extra: allowsFunctionXML ? "<function=" : nil)
    }

    mutating func observe(_ text: String) -> [StreamChunk] {
        guard enabled, !closed else {
            return []
        }
        if let start = text.range(of: startDelimiter) {
            sawToolDelimiter = true
            let afterStart = start.upperBound
            let bodyEnd = text.range(of: endDelimiter, range: afterStart..<text.endIndex)?.lowerBound ?? text.endIndex
            let body = String(text[afterStart..<bodyEnd])
            var isClosed = text.range(of: endDelimiter, range: afterStart..<text.endIndex) != nil
            if allowsFunctionXML, body.contains("<function=") {
                // Outer </tool_call> is not a valid XML close; wait for </function>.
                return observeNemotronXML(body: body, isClosed: body.contains("</function>"))
            }
            if !isClosed, ToolCallParser.firstCompleteJSONObject(in: body) != nil {
                isClosed = true
            }
            return observeJSONToolCall(body: body, isClosed: isClosed)
        }
        if allowsFunctionXML, text.contains("<function=") {
            sawToolDelimiter = true
            let isClosed = text.contains("</function>")
            return observeNemotronXML(body: text, isClosed: isClosed)
        }
        return []
    }

    private mutating func observeJSONToolCall(body: String, isClosed: Bool) -> [StreamChunk] {
        let name: String
        let arguments: String?
        let parsedComplete: Bool
        if let object = ToolCallParser.firstCompleteJSONObject(in: body),
           let parsed = ToolCallParser.jsonToolCallNameAndArguments(in: object, argumentKey: argumentKey)
        {
            name = parsed.name
            arguments = parsed.arguments
            parsedComplete = true
        } else {
            guard let parsedName = stringField("name", in: body),
                  let prefix = ToolCallParser.jsonArgumentsPrefix(in: body, argumentKey: argumentKey)
            else {
                return []
            }
            name = parsedName
            // Partial raw JSON cannot be guaranteed to prefix the finalized
            // canonical JSON (whitespace is removed and keys are sorted).
            // Open the call once its name is known, but hold all argument
            // bytes until the object is complete and canonical.
            _ = prefix
            arguments = nil
            parsedComplete = false
        }
        // Fail closed: never stream a tool-call delta for an undeclared function name.
        guard let allowed = allowedFunctionNames, allowed.contains(name) else {
            return []
        }
        // Byte-cap parity with the final parser (SPEC-018 §3.4 / §10a #7): never stream oversized
        // arguments; stop the emitter once the cumulative arguments exceed the per-call cap.
        guard arguments?.utf8.count ?? 0 <= ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP else {
            closed = true
            return []
        }

        var events: [StreamChunk] = []
        if !opened {
            opened = true
            events.append(.toolCallDelta(StreamToolCallDelta(index: 0, id: callID, type: "function", functionName: name, arguments: "")))
        }
        if let arguments {
            let fragment = Self.delta(from: emittedArguments, to: arguments)
            if !fragment.isEmpty {
                emittedArguments = arguments
                events.append(.toolCallDelta(StreamToolCallDelta(index: 0, id: nil, type: nil, functionName: nil, arguments: fragment)))
            }
        }
        if isClosed {
            closed = true
            if parsedComplete {
                completedValidToolCall = true
            }
        }
        return events
    }

    private mutating func observeNemotronXML(body: String, isClosed: Bool) -> [StreamChunk] {
        guard let name = ToolCallParser.nemotronFunctionName(in: body) else {
            return []
        }
        // Fail closed: never stream a tool-call delta for an undeclared function name.
        guard let allowed = allowedFunctionNames, allowed.contains(name) else {
            return []
        }

        let arguments = isClosed ? ToolCallParser.nemotronArgumentsJSON(in: body, includeIncomplete: true) : nil
        if isClosed, let arguments, arguments.utf8.count > ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP {
            closed = true
            return []
        }

        var events: [StreamChunk] = []
        if !opened {
            opened = true
            events.append(.toolCallDelta(StreamToolCallDelta(index: 0, id: callID, type: "function", functionName: name, arguments: "")))
        }
        // Function-XML arguments are re-serialized as whole JSON objects (sorted keys),
        // so they are not concat-safe prefixes. Hold until </function> then emit once.
        // Emitting "{}" on the open tag made clients run tools with empty args and made
        // later `{"command":...}` concat into malformed JSON.
        if isClosed {
            if let arguments {
                let fragment = Self.delta(from: emittedArguments, to: arguments)
                if !fragment.isEmpty {
                    emittedArguments = arguments
                    events.append(.toolCallDelta(StreamToolCallDelta(index: 0, id: nil, type: nil, functionName: nil, arguments: fragment)))
                }
                completedValidToolCall = true
            }
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

    private static func stripIncompleteOpenDelimiter(from text: String, delimiter: String, extra: String?) -> String {
        var candidates = [delimiter]
        if let extra {
            candidates.append(extra)
        }
        var longest = 0
        for candidate in candidates {
            let prefixes = (1..<candidate.count).map { String(candidate.prefix($0)) }
            for prefix in prefixes where text.hasSuffix(prefix) {
                longest = max(longest, prefix.count)
            }
        }
        guard longest > 0 else {
            return text
        }
        return String(text.dropLast(longest))
    }

    private static func delta(from old: String, to new: String) -> String {
        guard new.hasPrefix(old) else {
            // A replacement that is not a prefix is not concat-safe on the OpenAI
            // wire (`{}` + `{"command":...}`). Skip rather than emit a second object.
            return ""
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
    var ttftMilliseconds: Int64?
    let generationMilliseconds: Int64?
    let toolCalls: [ToolCall]?
    let modelHashObserved: String?
    let settlementDisposition: ContinuousBatchSettlementDisposition
    let specDecodeDraftedTokens: Int
    let specDecodeAcceptedTokens: Int
    let specDecodeGeneration: Int?
    /// #1690 E2E-F3: set on every loopback stream result, nil otherwise.
    /// Maps each content UTF-8 byte length at an upstream chunk boundary to
    /// the completion tokens generated through it, as the upstream attested
    /// them per token; empty when it did not.
    let loopbackPrefixCompletionTokens: [Int: Int]?

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
        settlementDisposition: ContinuousBatchSettlementDisposition,
        specDecodeDraftedTokens: Int = 0,
        specDecodeAcceptedTokens: Int = 0,
        specDecodeGeneration: Int? = nil,
        loopbackPrefixCompletionTokens: [Int: Int]? = nil
    ) {
        self.loopbackPrefixCompletionTokens = loopbackPrefixCompletionTokens
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
        self.settlementDisposition = settlementDisposition
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
            settlementDisposition: settlementDisposition,
            specDecodeDraftedTokens: specDecodeDraftedTokens,
            specDecodeAcceptedTokens: specDecodeAcceptedTokens,
            specDecodeGeneration: specDecodeGeneration,
            loopbackPrefixCompletionTokens: loopbackPrefixCompletionTokens
        )
    }

    func withContent(_ content: String) -> CompletionResult {
        CompletionResult(
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
            modelHashObserved: modelHashObserved,
            settlementDisposition: settlementDisposition,
            specDecodeDraftedTokens: specDecodeDraftedTokens,
            specDecodeAcceptedTokens: specDecodeAcceptedTokens,
            specDecodeGeneration: specDecodeGeneration,
            loopbackPrefixCompletionTokens: content == self.content ? loopbackPrefixCompletionTokens : nil
        )
    }

    func withToolCalls(_ toolCalls: [ToolCall]) -> CompletionResult {
        CompletionResult(
            content: content,
            finishReason: finishReason,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedPromptTokens,
            kvCacheBytesReused: kvCacheBytesReused,
            completionTokens: completionTokens,
            generatedCompletionTokens: generatedCompletionTokens,
            ttftMilliseconds: ttftMilliseconds,
            generationMilliseconds: generationMilliseconds,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            modelHashObserved: modelHashObserved,
            settlementDisposition: settlementDisposition,
            specDecodeDraftedTokens: specDecodeDraftedTokens,
            specDecodeAcceptedTokens: specDecodeAcceptedTokens,
            specDecodeGeneration: specDecodeGeneration,
            loopbackPrefixCompletionTokens: loopbackPrefixCompletionTokens
        )
    }

    /// #1690 E2E-F3: the usage a buyer_cancel end frame and receipt carry for
    /// a cancelled loopback stream: the upstream's prompt tokens and the
    /// completion tokens generated through exactly the delivered content.
    /// Without an attested count for that prefix the usage is unattested, so
    /// it is relayed empty and never signed. A native completion, or a
    /// loopback one whose whole content was delivered, is returned unchanged.
    func cancelledPrefixUsage(deliveredContent: String?) -> CompletionResult {
        guard let table = loopbackPrefixCompletionTokens, deliveredContent != content else { return self }
        let tokens = deliveredContent.flatMap { delivered in
            content.utf8.starts(with: delivered.utf8) ? table[delivered.utf8.count] : nil
        }
        return CompletionResult(
            content: deliveredContent ?? content,
            finishReason: finishReason,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedPromptTokens,
            kvCacheBytesReused: kvCacheBytesReused,
            completionTokens: tokens ?? completionTokens,
            generatedCompletionTokens: tokens ?? generatedCompletionTokens,
            ttftMilliseconds: ttftMilliseconds,
            generationMilliseconds: generationMilliseconds,
            toolCalls: toolCalls,
            modelHashObserved: modelHashObserved,
            settlementDisposition: tokens == nil ? .usageUnattested : settlementDisposition,
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

final class StreamedToolCallArgs: @unchecked Sendable {
    private struct StreamedCall {
        var id: String?
        var type: String?
        var functionName: String?
        var arguments = ""
    }

    private let lock = NSLock()
    private var byIndex: [Int: StreamedCall] = [:]

    func note(_ delta: StreamToolCallDelta) {
        lock.lock()
        var call = byIndex[delta.index] ?? StreamedCall()
        if let id = delta.id { call.id = id }
        if let type = delta.type { call.type = type }
        if let functionName = delta.functionName {
            call.functionName = (call.functionName ?? "") + functionName
        }
        if let fragment = delta.arguments, !fragment.isEmpty {
            call.arguments += fragment
        }
        byIndex[delta.index] = call
        lock.unlock()
    }

    func snapshot() -> [Int: String] {
        lock.lock()
        defer { lock.unlock() }
        return byIndex.mapValues(\.arguments)
    }

    func finalDeltas(for toolCalls: [ToolCall]?) throws -> [[[String: Any]]] {
        lock.lock()
        let streamedCalls = byIndex
        lock.unlock()
        let streamed = streamedCalls.mapValues(\.arguments)
        let finalized = toolCalls ?? []
        guard streamed.keys.allSatisfy({ $0 >= 0 && $0 < finalized.count }) else {
            throw ModelRuntime.streamedToolCallArgumentsMismatchError()
        }
        for (index, streamedCall) in streamedCalls {
            let finalCall = finalized[index]
            guard finalCall.arguments.hasPrefix(streamedCall.arguments),
                  streamedCall.id.map({ $0 == finalCall.id }) ?? true,
                  streamedCall.type.map({ $0 == "function" }) ?? true,
                  streamedCall.functionName.map({ $0 == finalCall.functionName }) ?? true
            else {
                throw ModelRuntime.streamedToolCallArgumentsMismatchError()
            }
        }
        let deltas = ToolCall.openAIFallbackDeltas(
            toolCalls: finalized,
            streamedArgumentsByIndex: streamed
        )
        for (index, call) in finalized.enumerated() {
            let delivered = streamed[index] ?? ""
            let appended = deltas.flatMap { $0 }.compactMap { delta -> String? in
                guard delta["index"] as? Int == index,
                      let function = delta["function"] as? [String: Any]
                else { return nil }
                return function["arguments"] as? String
            }.joined()
            guard Data((delivered + appended).utf8) == Data(call.arguments.utf8) else {
                throw ModelRuntime.streamedToolCallArgumentsMismatchError()
            }
        }
        return deltas
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

#if DEBUG || MACPROVIDER_LAB_HARNESS
extension ModelRuntime {
    /// Lab harness entry point: runs the same live parity + batched-isolation/MoE
    /// probes and measurement that the production load path runs, so lab runtimes
    /// attach paged KV from real on-device evidence instead of a synthesized identity.
    func labMeasurePagedKVRuntime(
        container: ModelContainer,
        modelID: String,
        modelCapabilities: PagedKVRuntimeModelCapabilities,
        runtimeCacheClass: String
    ) async -> PagedKVRuntimeMeasurement? {
        let (parityProbe, moeProbe) = await computePagedKVRuntimeProbes(
            container: container,
            modelID: modelID,
            modelCapabilities: modelCapabilities,
            runtimeCacheClass: runtimeCacheClass
        )
        return Self.measurePagedKVRuntime(
            config: pagedKVConfig,
            modelID: modelID,
            modelSHA256: currentModelHash,
            tokenizerSHA256: currentTokenizerConfigSHA256,
            chatTemplateSHA256: currentChatTemplateSHA256,
            modelCapabilities: modelCapabilities,
            parityProbe: parityProbe,
            moeProbe: moeProbe
        )
    }
}
#endif
