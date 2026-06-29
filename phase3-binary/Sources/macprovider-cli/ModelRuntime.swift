import Foundation
import CryptoKit
import MLXLLM
import MLXLMCommon
import MacProviderCore

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

extension ModelRuntimeServing {
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

actor ModelRuntime: ModelRuntimeServing {
    private var state: SwapState = .ready
    private var targetModelID: String?
    private var currentModelID: String?
    private var currentContainer: ModelContainer?
    private let stopTokenFilter: StopTokenFilter
    private var currentModelHash: String?
    private let maxContextTokens: Int
    // SPEC-013 autoresearch serving knobs. nil kvBits ⇒ no KV
    // quantization (mlx-swift default). maxBatch defaults to 1, the
    // pre-knob behavior; lifting above 1 widens the autotune search.
    private let kvBitsOverride: Int?
    private let inferenceGate: AsyncSemaphore
    private let maxBatch: Int
    private let warmSwapEnabled: Bool
    private let swapDrainTimeoutSeconds: Int
    private var providerStatus: ProviderStatus?
    private var signalContinuations: [UUID: AsyncStream<SwapSignal>.Continuation] = [:]
    private var nextInFlightID: Int = 0
    private var inFlightCancellations: [Int: @Sendable () -> Void] = [:]
    private let loader: @Sendable (String) async throws -> (ModelContainer, String, String?)
    private let testLoader: (@Sendable (String) async throws -> (String, String?))?
    private let testCompletion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)?

    var loadedModelID: String? {
        currentModelID
    }

    var loadedModelHash: String? {
        currentModelHash
    }

    var isLoaded: Bool {
        currentContainer != nil
    }

    init(
        modelID: String?,
        maxContextTokensOverride: Int? = nil,
        kvBitsOverride: Int? = nil,
        maxBatch: Int = 1,
        warmSwapEnabled: Bool = false,
        swapDrainTimeoutSeconds: Int = 30
    ) async throws {
        self.currentModelID = modelID
        self.maxContextTokens = maxContextTokensOverride ?? Self.defaultMaxContextTokens()
        self.kvBitsOverride = kvBitsOverride
        self.maxBatch = max(1, maxBatch)
        self.inferenceGate = AsyncSemaphore(value: max(1, maxBatch))
        self.warmSwapEnabled = warmSwapEnabled
        self.swapDrainTimeoutSeconds = swapDrainTimeoutSeconds
        self.loader = { targetModelID in
            let configuration = Self.configuration(for: targetModelID)
            let container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
            let directory = configuration.modelDirectory()
            let modelHash = try? Self.modelWeightArtifactManifestHash(in: directory)
            return (container, targetModelID, modelHash)
        }
        self.testLoader = nil
        self.testCompletion = nil

        guard let modelID else {
            self.currentContainer = nil
            self.stopTokenFilter = StopTokenFilter(tokens: [])
            self.currentModelHash = nil
            return
        }

        let configuration = Self.configuration(for: modelID)
        let container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
        self.currentContainer = container

        let directory = configuration.modelDirectory()
        let tokenizerConfigURL = directory.appendingPathComponent("tokenizer_config.json")
        if FileManager.default.fileExists(atPath: tokenizerConfigURL.path) {
            self.stopTokenFilter = try StopTokenConfigExtractor.extract(fromTokenizerConfigAt: tokenizerConfigURL)
        } else {
            self.stopTokenFilter = StopTokenFilter(tokens: [])
        }
        self.currentModelHash = try? Self.modelWeightArtifactManifestHash(in: directory)
    }

    init(
        modelID: String?,
        modelHash: String? = nil,
        maxContextTokensOverride: Int? = nil,
        kvBitsOverride: Int? = nil,
        maxBatch: Int = 1,
        warmSwapEnabled: Bool,
        swapDrainTimeoutSeconds: Int = 30,
        providerStatus: ProviderStatus? = nil,
        loader: @escaping @Sendable (String) async throws -> (ModelContainer, String, String?),
        testLoader: (@Sendable (String) async throws -> (String, String?))? = nil,
        testCompletion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)? = nil
    ) {
        self.currentModelID = modelID
        self.currentContainer = nil
        self.currentModelHash = modelHash
        self.stopTokenFilter = StopTokenFilter(tokens: [])
        self.maxContextTokens = maxContextTokensOverride ?? Self.defaultMaxContextTokens()
        self.kvBitsOverride = kvBitsOverride
        self.maxBatch = max(1, maxBatch)
        self.inferenceGate = AsyncSemaphore(value: max(1, maxBatch))
        self.warmSwapEnabled = warmSwapEnabled
        self.swapDrainTimeoutSeconds = swapDrainTimeoutSeconds
        self.providerStatus = providerStatus
        self.loader = loader
        self.testLoader = testLoader
        self.testCompletion = testCompletion
    }

    func setProviderStatus(_ providerStatus: ProviderStatus) {
        self.providerStatus = providerStatus
    }

    func currentSnapshot() async -> RuntimeSnapshot {
        RuntimeSnapshot(
            state: state,
            container: currentContainer,
            modelID: currentModelID,
            modelHash: currentModelHash
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
        let loader = loader
        let testLoader = testLoader
        return Task.detached { [weak self, loader, testLoader, drainTimeoutSeconds, providerStatus] in
            guard let self else { return }
            do {
                let container: ModelContainer?
                let modelID: String
                let modelHash: String?
                if let testLoader {
                    let loaded = try await testLoader(targetModelID)
                    container = nil
                    modelID = loaded.0
                    modelHash = loaded.1
                } else {
                    let loaded = try await loader(targetModelID)
                    container = loaded.0
                    modelID = loaded.1
                    modelHash = loaded.2
                }
                try await self.enterDrainPhase()
                let didTimeout = await Self.waitForDrainOrTimeout(providerStatus: providerStatus, timeoutSeconds: drainTimeoutSeconds)
                if didTimeout {
                    await self.cancelAllInFlightForDrainTimeout()
                }
                await self.completeSwapAtomically(container: container, modelID: modelID, modelHash: modelHash)
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

    func maxBatchForTest() -> Int {
        maxBatch
    }

    func maxContextTokensForTest() -> Int {
        maxContextTokens
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

    private nonisolated static func waitForDrainOrTimeout(providerStatus: ProviderStatus?, timeoutSeconds: Int) async -> Bool {
        guard let providerStatus else {
            return false
        }
        let drainStartMs = Int64(Date().timeIntervalSince1970 * 1000)
        let timeoutMs = Int64(timeoutSeconds * 1000)
        while !Task.isCancelled {
            let snapshot = await providerStatus.snapshot()
            if snapshot.requestsInFlight == 0 {
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

    private func completeSwapAtomically(container: ModelContainer?, modelID: String, modelHash: String?) {
        let target = targetModelID ?? modelID
        currentContainer = container
        currentModelID = modelID
        currentModelHash = modelHash
        state = .ready
        targetModelID = nil
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
        let snapshot = RuntimeSnapshot(
            state: state,
            container: currentContainer,
            modelID: currentModelID,
            modelHash: currentModelHash
        )
        try Self.validateReady(snapshot.state)
        try request.validateModelMatches(snapshot.modelID)
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
        guard let container = handle.snapshot.container else {
            if testCompletion != nil {
                return
            }
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        try await inferenceGate.withPermit {
            return try await container.perform { context in
                let input = try Self.userInput(for: request)
                let lmInput = try await context.processor.prepare(input: input)
                try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
            }
        }
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async throws -> CompletionResult {
        let (result, _) = try await completeWithServedSnapshot(request, shouldCancel: shouldCancel)
        return result
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
        let completionStartedAt = Date()
        let snapshot = await currentSnapshot()
        try Self.validateReady(snapshot.state)
        try request.validateModelMatches(snapshot.modelID)
        try Self.validateToolChoiceScope(request)
        let drainCancelled = DrainCancelToken()
        let registrationID = registerInFlight { drainCancelled.fire() }
        defer { unregisterInFlight(registrationID) }
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
        let inferenceGate = inferenceGate
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
                    let parameters = GenerateParameters(
                        maxTokens: request.maxTokens,
                        maxKVSize: maxContextTokens,
                        kvBits: kvBitsOverride,
                        temperature: Float(request.temperature),
                        topP: Float(request.topP)
                    )
                    let firstToken = FirstTokenRecorder()
                    let result: GenerateResult = try generate(input: lmInput, parameters: parameters, context: context) { tokens in
                        if !tokens.isEmpty {
                            firstToken.recordIfMissing()
                        }
                        if Task.isCancelled || shouldCancel() || drainCancelled.isFired {
                            return GenerateDisposition.stop
                        }
                        return GenerateDisposition.more
                    }
                    try drainCancelled.check()
                    try Task.checkCancellation()

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

                    let parsed = Self.parseToolCallsIfRequested(filtered.text, request: request)
                    let finishReason: String
                    if !parsed.toolCalls.isEmpty {
                        finishReason = "tool_calls"
                    } else if let maxTokens = request.maxTokens, result.generationTokenCount >= maxTokens, !filtered.hitStop {
                        finishReason = "length"
                    } else {
                        finishReason = "stop"
                    }

                    return try Self.validateStructuredCompletion(CompletionResult(
                        content: parsed.content,
                        finishReason: finishReason,
                        promptTokens: result.promptTokenCount,
                        completionTokens: result.generationTokenCount,
                        ttftMilliseconds: firstToken.elapsedMilliseconds(since: completionStartedAt),
                        toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                        modelHashObserved: Self.validObservedModelHash(snapshot.modelHash)
                    ), request: request)
                }
            }
        }
        return (completion, snapshot)
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        let snapshot = handle.snapshot
        let drainCancelled = handle.drainCancelled
        if let testCompletion {
            let completion = try await Self.withDrainCancellation(drainCancelled) {
                try await testCompletion(snapshot, request)
            }.withModelHashObservedIfMissing(Self.validObservedModelHash(snapshot.modelHash))
            if !completion.content.isEmpty {
                onChunk(.content(completion.content))
            }
            return completion
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        let kvBitsOverride = kvBitsOverride
        let inferenceGate = inferenceGate
        let stopTokenFilter = stopTokenFilter
        return try await Self.withDrainCancellation(drainCancelled) {
            try await inferenceGate.withPermit {
                try drainCancelled.check()
                try Task.checkCancellation()
                return try await container.perform { context in
                    try drainCancelled.check()
                    try Task.checkCancellation()
                    let input = try Self.userInput(for: request)
                    let lmInput = try await context.processor.prepare(input: input)
                    try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
                    let parameters = GenerateParameters(
                        maxTokens: request.maxTokens,
                        maxKVSize: maxContextTokens,
                        kvBits: kvBitsOverride,
                        temperature: Float(request.temperature),
                        topP: Float(request.topP)
                    )

                    var emittedText = ""
                    var stoppedByRequestStop = false
                    var toolStreamer = NativeToolCallStreamEmitter(modelID: request.model)

                    let streamToolsIncrementally = Self.hasEnabledTools(request.promptSource.tools)
                    let result: GenerateResult = try generate(input: lmInput, parameters: parameters, context: context) { tokens in
                        if Task.isCancelled || shouldCancel() || drainCancelled.isFired {
                            return .stop
                        }
                        let decoded = context.tokenizer.decode(tokens: tokens)
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
                            emittedText = candidate.text
                            onChunk(.content(delta))
                        }

                        if candidate.hitStop {
                            stoppedByRequestStop = true
                            return .stop
                        }
                        return .more
                    }
                    try drainCancelled.check()
                    try Task.checkCancellation()

                    let final = Self.applyOutputFilters(
                        result.output,
                        stopTokenFilter: stopTokenFilter,
                        requestStops: request.stop
                    )
                    let finalDelta = Self.delta(from: emittedText, to: final.text)
                    let parsed = Self.parseToolCallsIfRequested(final.text, request: request)
                    if streamToolsIncrementally {
                        for event in toolStreamer.observe(final.text) {
                            onChunk(event)
                        }
                        if parsed.toolCalls.isEmpty, !parsed.content.isEmpty {
                            onChunk(.content(parsed.content))
                        }
                    } else if !finalDelta.isEmpty {
                        onChunk(.content(finalDelta))
                    }

                    let finishReason: String
                    if !parsed.toolCalls.isEmpty {
                        finishReason = "tool_calls"
                    } else if let maxTokens = request.maxTokens,
                       result.generationTokenCount >= maxTokens,
                       !stoppedByRequestStop,
                       !final.hitStop
                    {
                        finishReason = "length"
                    } else {
                        finishReason = "stop"
                    }

                    return CompletionResult(
                        content: parsed.content,
                        finishReason: finishReason,
                        promptTokens: result.promptTokenCount,
                        completionTokens: result.generationTokenCount,
                        toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                        modelHashObserved: Self.validObservedModelHash(snapshot.modelHash)
                    )
                }
            }
        }
    }

    func measureStartupThroughput(maxTokens: Int = 8) async -> Double {
        guard let container = currentContainer else {
            return 0.0
        }

        do {
            let start = Date()
            let result: GenerateResult = try await inferenceGate.withPermit {
                try await container.perform { context in
                    let input = UserInput(chat: [.user("Reply with a short greeting.")])
                    let lmInput = try await context.processor.prepare(input: input)
                    let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.0, topP: 1.0)
                    return try generate(input: lmInput, parameters: parameters, context: context) { (_: [Int]) in
                        GenerateDisposition.more
                    }
                }
            }
            let elapsed = max(Date().timeIntervalSince(start), 0.001)
            return Double(result.generationTokenCount) / elapsed
        } catch {
            return 0.0
        }
    }

    private static func configuration(for modelID: String) -> ModelConfiguration {
        if modelID.hasPrefix("/") || FileManager.default.fileExists(atPath: modelID) {
            return ModelConfiguration(directory: URL(fileURLWithPath: modelID))
        }
        if let cachedSnapshot = localHuggingFaceSnapshot(for: modelID) {
            return ModelConfiguration(directory: cachedSnapshot)
        }
        return LLMModelFactory.shared.configuration(id: modelID)
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

    private static func localHuggingFaceSnapshot(for modelID: String) -> URL? {
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

    private static func parseStructuredJSONContent(_ content: String, requireObjectOrArray: Bool) throws -> MacProviderCore.JSONValue {
        guard !content.isEmpty else {
            throw APIError(
                status: 502,
                message: "Model emitted zero tokens for the requested schema; adjust `temperature` / `seed` (for stochastic models), or modify the prompt or schema before retrying — automatic same-request retry will not succeed.",
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
        } catch {
            throw APIError(
                status: 502,
                message: "Model output was not valid JSON for the requested response_format",
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
            return [
                "type": "function",
                "function": [
                    "name": name,
                    "description": functionObject["description"].map(jsonAny) ?? NSNull(),
                    "parameters": jsonAny(parameters),
                ],
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

    private static func jsonObject(_ object: [String: MacProviderCore.JSONValue]) -> [String: Any] {
        object.mapValues(jsonAny)
    }

    private static func jsonAny(_ value: MacProviderCore.JSONValue) -> Any {
        switch value {
        case .object(let object):
            return jsonObject(object)
        case .array(let array):
            return array.map(jsonAny)
        case .string(let string):
            return string
        case .int(let int):
            return int
        case .double(let double):
            return double
        case .bool(let bool):
            return bool
        case .null:
            return NSNull()
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

private struct NativeToolCallStreamEmitter {
    private let startDelimiter: String
    private let endDelimiter: String
    private let argumentKey: String
    private var opened = false
    private var closed = false
    private var emittedArguments = ""
    private var callID = "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"

    init(modelID: String) {
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
        guard !closed, let start = text.range(of: startDelimiter) else {
            return []
        }
        let afterStart = start.upperBound
        let bodyEnd = text.range(of: endDelimiter, range: afterStart..<text.endIndex)?.lowerBound ?? text.endIndex
        let body = String(text[afterStart..<bodyEnd])
        guard let name = stringField("name", in: body),
              let arguments = argumentPrefix(in: body)
        else {
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
        if text.range(of: endDelimiter, range: afterStart..<text.endIndex) != nil {
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

struct CompletionResult: Sendable {
    let content: String
    let finishReason: String
    let promptTokens: Int
    let completionTokens: Int
    let ttftMilliseconds: Int64?
    let toolCalls: [ToolCall]?
    let modelHashObserved: String?

    init(
        content: String,
        finishReason: String,
        promptTokens: Int,
        completionTokens: Int,
        ttftMilliseconds: Int64? = nil,
        toolCalls: [ToolCall]? = nil,
        modelHashObserved: String? = nil
    ) {
        self.content = content
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.ttftMilliseconds = ttftMilliseconds
        self.toolCalls = toolCalls
        self.modelHashObserved = modelHashObserved
    }

    func withModelHashObservedIfMissing(_ observed: String?) -> CompletionResult {
        guard modelHashObserved == nil, let observed else { return self }
        return CompletionResult(
            content: content,
            finishReason: finishReason,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            ttftMilliseconds: ttftMilliseconds,
            toolCalls: toolCalls,
            modelHashObserved: observed
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
