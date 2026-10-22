import Foundation
import MLXLMCommon
import MacProviderCore

// Issue #2084 shard group head runtime (SPEC-051). The head serves one model over
// a chain of Macs; to InferenceRelay and HTTPServer it is a runtime like any
// other: it renders the chat template with the model's tokenizer, submits the
// prompt to the session engine, streams detokenized text, applies stop sequences,
// reports usage, honours cancellation, and maps chain failures to explicit buyer
// errors (SPEC-051-R021, R022). Completions carry the request's group attestation
// evidence for the receipt path (SPEC-051-R019).

/// The engine as the runtime drives it (a `ShardGroupEngine` over any stage type).
protocol ShardGroupEngineHandle: AnyObject, Sendable {
    var status: ShardGroupEngineStatus { get }
    func stream(_ request: ShardGenerationRequest) throws -> (id: UInt64, events: AsyncThrowingStream<ShardGenerationEvent, Error>)
    func cancel(_ requestID: UInt64)
    func shutdown() throws
}

extension ShardGroupEngine: ShardGroupEngineHandle {}

/// SPEC-051-R019 evidence a head completion carries to the receipt path.
struct ShardGroupCompletionEvidence: Sendable {
    let attestation: ShardRequestAttestation
    /// Token steps the head received for the request (the segment's `step_end`).
    let tokenSteps: Int
}

/// Whether the coordinator lets the head take network buyer work (SPEC-051-R027,
/// R029): without a coordinator session there is nothing to wait for.
enum ShardGroupServingGate: Equatable, Sendable {
    case notRequired
    case awaitingCoordinator
    case available
    case unavailable(String)

    var admitsNetworkBuyers: Bool {
        switch self {
        case .notRequired, .available: return true
        case .awaitingCoordinator, .unavailable: return false
        }
    }
}

actor ShardGroupRuntime: ModelRuntimeServing {
    struct Identity: Sendable {
        let modelID: String
        let modelHash: String?
        let modelHashAlgorithm: String?
        let weightsManifestSHA256: String?
        let catalogModelIDAlias: String?
    }

    struct Prompting: Sendable {
        let tokenizer: any Tokenizer
        let eosTokenIDs: Set<Int>
        let stopFilter: StopTokenFilter
        let templateSupportsThinkingToggle: Bool
        let templateSupportsPreserveThinking: Bool
    }

    static let startupThroughputPrompt = "Write one short paragraph about how pipeline stages pass activations."

    let identity: Identity
    let maxContextTokens: Int
    /// A verified catalog artifact behind every member (SPEC-051-R008): receipts
    /// are signed only then.
    nonisolated let isSettlementReceiptEligible: Bool
    nonisolated var settlementRuntimeSource: String? { nil }

    private let prompting: Prompting
    private let connect: @Sendable () async throws -> any ShardGroupEngineHandle
    private var engine: (any ShardGroupEngineHandle)?
    private var maintainTask: Task<Void, Never>?
    private(set) var gate: ShardGroupServingGate
    private var providerStatus: ProviderStatus?
    private var registrationCounter = 0

    // SPEC-051-R029 coordinator state (ShardGroupWire.swift).
    let registration: ShardGroupRegistration?
    var acceptedEpoch: UInt64?
    var registerSent: (epoch: UInt64, at: Date)?
    private var warnings = Set<String>()

    init(
        identity: Identity,
        prompting: Prompting,
        maxContextTokens: Int,
        gate: ShardGroupServingGate,
        registration: ShardGroupRegistration? = nil,
        connect: @escaping @Sendable () async throws -> any ShardGroupEngineHandle
    ) {
        self.registration = registration
        self.identity = identity
        self.prompting = prompting
        self.maxContextTokens = maxContextTokens
        self.gate = gate
        self.connect = connect
        self.isSettlementReceiptEligible = identity.modelHash != nil
    }

    // MARK: Engine lifecycle

    /// Connect the chain once (serve fails when the members are not up), then keep
    /// it connected: a failed chain is re-dialled in the background.
    func start() async throws {
        engine = try await connect()
        maintainTask = Task { [weak self] in await self?.maintain() }
    }

    func stop() {
        maintainTask?.cancel()
        maintainTask = nil
        try? engine?.shutdown()
        engine = nil
    }

    private func maintain() async {
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            if engine?.status.running == true {
                backoff = 1
                continue
            }
            if let failure = engine?.status.failure { shardGroupLog("chain down (\(failure)); reconnecting") }
            do {
                engine = try await connect()
                shardGroupLog("chain reconnected")
                backoff = 1
            } catch {
                shardGroupLog("chain reconnect failed: \(error)")
                try? await Task.sleep(nanoseconds: min(backoff, 10) * 1_000_000_000)
                backoff *= 2
            }
        }
    }

    var engineStatus: ShardGroupEngineStatus? { engine?.status }

    func setGate(_ gate: ShardGroupServingGate) {
        if gate != self.gate { shardGroupLog("serving gate \(gate)") }
        self.gate = gate
    }

    /// A new coordinator session registers again and waits for its status.
    func resetCoordinatorSession() {
        acceptedEpoch = nil
        registerSent = nil
        if gate != .notRequired { setGate(.awaitingCoordinator) }
    }

    func warnOnce(_ message: String) {
        guard warnings.insert(message).inserted else { return }
        shardGroupLog(message)
    }

    // MARK: Identity and status

    var loadedModelHash: String? { identity.modelHash }
    var loadedModelHashAlgorithm: String? { identity.modelHashAlgorithm }
    var loadedWeightsManifestSHA256: String? { identity.weightsManifestSHA256 }
    var isLoaded: Bool { true }

    func setProviderStatus(_ providerStatus: ProviderStatus) {
        self.providerStatus = providerStatus
    }

    func currentSnapshot() -> RuntimeSnapshot {
        snapshot()
    }

    private func snapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: .ready, container: nil, modelID: identity.modelID, modelHash: identity.modelHash,
            modelHashAlgorithm: identity.modelHashAlgorithm, weightsManifestSHA256: identity.weightsManifestSHA256,
            templateSupportsThinkingToggle: prompting.templateSupportsThinkingToggle,
            templateSupportsPreserveThinking: prompting.templateSupportsPreserveThinking)
    }

    // MARK: Admission

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        guard gate.admitsNetworkBuyers else {
            throw Self.unavailable("the coordinator has not made this group available (\(gate))")
        }
        return try handle(for: request)
    }

    func acquireLocalRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        try handle(for: request)
    }

    private func handle(for request: ChatCompletionRequest) throws -> RequestHandle {
        try request.validateModelMatches(identity.modelID, aliases: [identity.catalogModelIDAlias].compactMap { $0 })
        guard engine?.status.running == true else {
            throw Self.unavailable(engine?.status.failure ?? "the chain is not connected")
        }
        registrationCounter += 1
        return RequestHandle(snapshot: snapshot(), registrationID: registrationCounter, drainCancelled: DrainCancelToken())
    }

    /// Nothing to release: a request's engine slot ends with its stream.
    func unregisterInFlight(_ id: Int) {}

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        try handle.drainCancelled.check()
        _ = try prepare(request)
    }

    // MARK: Generation

    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult {
        try await generate(request, handle: nil, shouldCancel: shouldCancel, onChunk: nil)
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        try await generate(request, handle: handle, shouldCancel: shouldCancel, onChunk: onChunk)
    }

    struct PreparedRequest: Sendable {
        let promptTokens: [Int]
        let maxTokens: Int
        let control: ShardRequestControl
        let stops: [String]
    }

    /// Validate what a shard group serves and render the prompt: text chat with
    /// temperature, top_p and seed. Tools, structured output, images and
    /// penalties have no stage-side support yet and are refused, not ignored.
    func prepare(_ request: ChatCompletionRequest) throws -> PreparedRequest {
        guard !request.containsNonTextMessageContentPart else {
            throw APIError(status: 400, message: "Images are not supported by this model", code: "unsupported_content_shape", param: "messages")
        }
        guard !ModelRuntime.hasEnabledTools(request.promptSource.tools) else {
            throw APIError(status: 400, message: "Tools are not supported by a shard group yet", code: "shard_group_tools_unsupported", param: "tools")
        }
        guard case .text = request.responseFormat else {
            throw APIError(status: 400, message: "Structured output is not supported by a shard group yet", code: "shard_group_response_format_unsupported", param: "response_format")
        }
        guard request.presencePenalty == 0, request.frequencyPenalty == 0, request.repetitionPenalty == 1, request.topK == 0 else {
            throw APIError(status: 400, message: "Penalties and top_k are not supported by a shard group yet", code: "shard_group_sampling_unsupported")
        }
        let promptTokens = try Self.promptTokens(for: request, prompting: prompting)
        // At least one output token must fit after the prompt.
        try ModelRuntime.validatePromptTokenCount(promptTokens.count, maxContextTokens: maxContextTokens - 1)
        let room = maxContextTokens - promptTokens.count
        let maxTokens = min(request.maxTokens ?? room, room)
        guard maxTokens > 0 else {
            throw APIError(status: 400, message: "max_tokens must be > 0", code: "invalid_request", param: "max_tokens")
        }
        let topP = request.topP > 0 && request.topP <= 1 ? Float(request.topP) : 1
        let control = ShardRequestControl(
            temperature: Float(max(0, request.temperature)), topP: topP,
            seed: request.seed.map { UInt64(bitPattern: Int64($0)) })
        return PreparedRequest(promptTokens: promptTokens, maxTokens: maxTokens, control: control, stops: request.stop.filter { !$0.isEmpty })
    }

    /// The chat template applied by the model's tokenizer, exactly as the single-Mac
    /// runtime renders a text request.
    static func promptTokens(for request: ChatCompletionRequest, prompting: Prompting) throws -> [Int] {
        let input = try ModelRuntime.userInput(
            for: request, templateSupportsThinkingToggle: prompting.templateSupportsThinkingToggle,
            templateSupportsPreserveThinking: prompting.templateSupportsPreserveThinking)
        let messages = DefaultMessageGenerator().generate(from: input)
        do {
            return try prompting.tokenizer.applyChatTemplate(messages: messages, tools: input.tools, additionalContext: input.additionalContext)
        } catch {
            throw APIError(status: 422, message: "The model's tokenizer cannot apply its chat template to this request", code: "chat_template_unsupported")
        }
    }

    private func generate(
        _ request: ChatCompletionRequest,
        handle: RequestHandle?,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: (@Sendable (StreamChunk) -> Void)?
    ) async throws -> CompletionResult {
        try handle?.drainCancelled.check()
        let prepared = try prepare(request)
        guard let engine, engine.status.running else {
            throw Self.unavailable(self.engine?.status.failure ?? "the chain is not connected")
        }
        // The id members sign must be canonical; a request id that is not falls back
        // to the engine's own (the coordinator then rejects the attestation, not the stream).
        let receiptRequestID = request.requestID.flatMap { ShardMemberSigner.isCanonicalString($0) ? $0 : nil }
        let started = Date()
        let submission: (id: UInt64, events: AsyncThrowingStream<ShardGenerationEvent, Error>)
        do {
            submission = try engine.stream(ShardGenerationRequest(
                promptTokens: prepared.promptTokens, maxTokens: prepared.maxTokens, control: prepared.control,
                stopTokenIDs: prompting.eosTokenIDs, receiptRequestID: receiptRequestID))
        } catch {
            throw Self.buyerError(error)
        }
        let requestID = submission.id
        let drainToken = handle?.drainCancelled
        // The engine checks cancels between steps; a cancel waits at most one step.
        let watcher = Task.detached {
            while !Task.isCancelled {
                if shouldCancel() || drainToken?.isFired == true {
                    engine.cancel(requestID)
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        defer { watcher.cancel() }

        var output = ShardStreamingText(tokenizer: prompting.tokenizer, stops: prepared.stops, stopFilter: prompting.stopFilter)
        var content = ""
        var completionTokens = 0
        var firstTokenAt: Date?
        var summary: ShardGenerationSummary?
        do {
            for try await event in submission.events {
                switch event {
                case .token(let token, _):
                    guard !output.stopped else { continue }
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    completionTokens += 1
                    let text = output.append(token)
                    if !text.isEmpty {
                        content += text
                        onChunk?(.content(text))
                    }
                    if output.stopped { engine.cancel(requestID) }
                case .finished(let finished):
                    summary = finished
                }
            }
        } catch {
            throw Self.buyerError(error)
        }
        guard let summary else { throw Self.unavailable("the request ended without a summary") }
        let cancelledByCaller = summary.reason == .cancelled && !output.stopped
        if !output.stopped, !cancelledByCaller {
            let rest = output.finish()
            if !rest.isEmpty {
                content += rest
                onChunk?(.content(rest))
            }
        }
        if cancelledByCaller, drainToken?.isFired == true, !shouldCancel() {
            throw DrainCancelledError()
        }
        let finishReason: String
        if cancelledByCaller {
            finishReason = "cancelled"
        } else if output.stopped || summary.reason == .stop {
            finishReason = "stop"
        } else {
            finishReason = "length"
        }
        let finishedAt = Date()
        return CompletionResult(
            content: content,
            finishReason: finishReason,
            promptTokens: prepared.promptTokens.count,
            completionTokens: completionTokens,
            ttftMilliseconds: firstTokenAt.map { Int64($0.timeIntervalSince(started) * 1000) },
            generationMilliseconds: Int64(finishedAt.timeIntervalSince(started) * 1000),
            modelHashObserved: identity.modelHash,
            settlementDisposition: isSettlementReceiptEligible && summary.attestation.verdict == "ok" ? .eligibleOwner : .notEligible,
            shardGroupEvidence: ShardGroupCompletionEvidence(attestation: summary.attestation, tokenSteps: summary.tokenSteps))
    }

    /// SPEC-001 FR-20 startup estimate through the whole chain: one fixed short
    /// generation, completion tokens over the request wall time. 0 when it fails.
    func measureStartupThroughput(maxTokens: Int) async -> Double {
        guard let engine, engine.status.running else { return 0 }
        do {
            let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
                "model": identity.modelID, "max_tokens": maxTokens, "temperature": 0,
                "messages": [["role": "user", "content": Self.startupThroughputPrompt]],
            ]))
            let started = Date()
            let result = try await generate(request, handle: nil, shouldCancel: { false }, onChunk: nil)
            let elapsed = Date().timeIntervalSince(started)
            guard elapsed > 0, result.completionTokens > 0 else { return 0 }
            let rate = Double(result.completionTokens) / elapsed
            shardGroupLog("startup throughput \(String(format: "%.1f", rate)) tok/s over \(result.completionTokens) tokens")
            return rate
        } catch {
            shardGroupLog("startup throughput probe failed: \(error)")
            return 0
        }
    }

    // MARK: Errors

    static func unavailable(_ detail: String) -> APIError {
        APIError(status: 503, message: "Shard group unavailable: \(detail)", type: "server_error", code: "shard_group_unavailable", retryable: true)
    }

    /// SPEC-051-R021: before the first token the attempt is retryable and carries no
    /// completion. SPEC-051-R022: after it the stream ends with an explicit error;
    /// the delivered tokens stand.
    static func buyerError(_ error: Error) -> Error {
        switch error {
        case ShardGroupEngineError.unavailable(let detail):
            return unavailable(detail)
        case ShardGroupEngineError.failedBeforeFirstToken(let cause):
            return APIError(
                status: 503, message: "Shard group failed before the first token: \(cause)", type: "server_error",
                code: "shard_group_failed", retryable: true)
        case ShardGroupEngineError.streamTerminated(let delivered, let cause):
            return APIError(
                status: 502, message: "Shard group stream terminated after \(delivered) tokens: \(cause)", type: "server_error",
                code: "shard_group_failed", retryable: false, inferenceRan: true)
        case ShardGroupEngineError.invalidRequest(let detail):
            return APIError(status: 400, message: detail, code: "invalid_request")
        default:
            return error
        }
    }
}

/// Detokenized output with stop sequences: text that could still begin a stop
/// sequence is held back, and nothing after a matched stop is ever emitted.
struct ShardStreamingText {
    private var detokenizer: NaiveStreamingDetokenizer
    private let stops: [String]
    private let stopFilter: StopTokenFilter
    private let holdBack: Int
    private var held = ""
    private(set) var stopped = false

    init(tokenizer: any Tokenizer, stops: [String], stopFilter: StopTokenFilter) {
        self.detokenizer = NaiveStreamingDetokenizer(tokenizer: tokenizer)
        self.stops = stops
        self.stopFilter = stopFilter
        self.holdBack = max(0, (stops.map(\.count).max() ?? 0) - 1)
    }

    /// The text this token releases.
    mutating func append(_ token: Int) -> String {
        guard !stopped else { return "" }
        detokenizer.append(token: token)
        guard let piece = detokenizer.next() else { return "" }
        held += stopFilter.stripping(from: piece)
        if let stop = stops.compactMap({ held.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let released = String(held[..<stop.lowerBound])
            held = ""
            stopped = true
            return released
        }
        guard held.count > holdBack else { return "" }
        let cut = held.index(held.endIndex, offsetBy: -holdBack)
        let released = String(held[..<cut])
        held = String(held[cut...])
        return released
    }

    /// Release what was held back at the end of the request.
    mutating func finish() -> String {
        defer { held = "" }
        return stopped ? "" : held
    }
}
