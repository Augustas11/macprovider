import Foundation
import CryptoKit
import MLXLLM
import MLXLMCommon
import MacProviderCore

protocol ModelRuntimeServing: Sendable {
    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult
    func stream(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool, onChunk: @escaping @Sendable (String) -> Void) async throws -> CompletionResult
    func currentSnapshot() async -> RuntimeSnapshot
}

extension ModelRuntimeServing {
    func currentSnapshot() async -> RuntimeSnapshot {
        RuntimeSnapshot(state: .ready, container: nil, modelID: nil, modelHash: nil)
    }

    func complete(_ request: ChatCompletionRequest) async throws -> CompletionResult {
        try await complete(request, shouldCancel: { false })
    }

    func stream(
        _ request: ChatCompletionRequest,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> CompletionResult {
        try await stream(request, shouldCancel: { false }, onChunk: onChunk)
    }
}

public struct RuntimeSnapshot: @unchecked Sendable {
    public let state: SwapState
    public let container: ModelContainer?
    public let modelID: String?
    public let modelHash: String?
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
    private let inferenceGate = AsyncSemaphore(value: 1)
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
        warmSwapEnabled: Bool = false,
        swapDrainTimeoutSeconds: Int = 30
    ) async throws {
        self.currentModelID = modelID
        self.maxContextTokens = maxContextTokensOverride ?? Self.defaultMaxContextTokens()
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

    func preflight(_ request: ChatCompletionRequest) async throws {
        let snapshot = await currentSnapshot()
        try Self.validateReady(snapshot.state)
        try request.validateModelMatches(snapshot.modelID)
        guard let container = snapshot.container else {
            if testCompletion != nil {
                return
            }
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        try await inferenceGate.withPermit {
            return try await container.perform { context in
                let input = UserInput(chat: request.messages.map { $0.mlxMessage })
                let lmInput = try await context.processor.prepare(input: input)
                try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
            }
        }
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async throws -> CompletionResult {
        let snapshot = await currentSnapshot()
        try Self.validateReady(snapshot.state)
        try request.validateModelMatches(snapshot.modelID)
        let drainCancelled = DrainCancelToken()
        let registrationID = registerInFlight { drainCancelled.fire() }
        defer { unregisterInFlight(registrationID) }
        if let testCompletion {
            return try await Self.withDrainCancellation(drainCancelled) {
                try await testCompletion(snapshot, request)
            }
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        let inferenceGate = inferenceGate
        let stopTokenFilter = stopTokenFilter
        return try await Self.withDrainCancellation(drainCancelled) {
            try await inferenceGate.withPermit {
                try drainCancelled.check()
                try Task.checkCancellation()
                return try await container.perform { context in
                    try drainCancelled.check()
                    try Task.checkCancellation()
                    let input = UserInput(chat: request.messages.map { $0.mlxMessage })
                    let lmInput = try await context.processor.prepare(input: input)
                    try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
                    let parameters = GenerateParameters(
                        maxTokens: request.maxTokens,
                        temperature: Float(request.temperature),
                        topP: Float(request.topP)
                    )
                    let result: GenerateResult = try generate(input: lmInput, parameters: parameters, context: context) { (_: [Int]) in
                        if Task.isCancelled || shouldCancel() || drainCancelled.isFired {
                            return GenerateDisposition.stop
                        }
                        return GenerateDisposition.more
                    }
                    try drainCancelled.check()
                    try Task.checkCancellation()

                    let filtered = Self.applyOutputFilters(
                        result.output,
                        stopTokenFilter: stopTokenFilter,
                        requestStops: request.stop
                    )

                    let finishReason: String
                    if let maxTokens = request.maxTokens, result.generationTokenCount >= maxTokens, !filtered.hitStop {
                        finishReason = "length"
                    } else {
                        finishReason = "stop"
                    }

                    return CompletionResult(
                        content: filtered.text,
                        finishReason: finishReason,
                        promptTokens: result.promptTokenCount,
                        completionTokens: result.generationTokenCount
                    )
                }
            }
        }
    }

    func stream(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> CompletionResult {
        let snapshot = await currentSnapshot()
        try Self.validateReady(snapshot.state)
        try request.validateModelMatches(snapshot.modelID)
        let drainCancelled = DrainCancelToken()
        let registrationID = registerInFlight { drainCancelled.fire() }
        defer { unregisterInFlight(registrationID) }
        if let testCompletion {
            let completion = try await Self.withDrainCancellation(drainCancelled) {
                try await testCompletion(snapshot, request)
            }
            if !completion.content.isEmpty {
                onChunk(completion.content)
            }
            return completion
        }
        guard let container = snapshot.container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        let inferenceGate = inferenceGate
        let stopTokenFilter = stopTokenFilter
        return try await Self.withDrainCancellation(drainCancelled) {
            try await inferenceGate.withPermit {
                try drainCancelled.check()
                try Task.checkCancellation()
                return try await container.perform { context in
                    try drainCancelled.check()
                    try Task.checkCancellation()
                    let input = UserInput(chat: request.messages.map { $0.mlxMessage })
                    let lmInput = try await context.processor.prepare(input: input)
                    try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
                    let parameters = GenerateParameters(
                        maxTokens: request.maxTokens,
                        temperature: Float(request.temperature),
                        topP: Float(request.topP)
                    )

                    var emittedText = ""
                    var stoppedByRequestStop = false

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

                        let delta = Self.delta(from: emittedText, to: candidate.text)
                        if !delta.isEmpty {
                            emittedText = candidate.text
                            onChunk(delta)
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
                    if !finalDelta.isEmpty {
                        onChunk(finalDelta)
                    }

                    let finishReason: String
                    if let maxTokens = request.maxTokens,
                       result.generationTokenCount >= maxTokens,
                       !stoppedByRequestStop,
                       !final.hitStop
                    {
                        finishReason = "length"
                    } else {
                        finishReason = "stop"
                    }

                    return CompletionResult(
                        content: final.text,
                        finishReason: finishReason,
                        promptTokens: result.promptTokenCount,
                        completionTokens: result.generationTokenCount
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

    private static func validatePromptTokenCount(_ promptTokens: Int, maxContextTokens: Int) throws {
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
}

private final class DrainCancelToken: @unchecked Sendable {
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
}

private extension ChatMessage {
    var mlxMessage: Chat.Message {
        switch role {
        case .system:
            return .system(content ?? "")
        case .user:
            return .user(content ?? "")
        case .assistant:
            return .assistant(content ?? "")
        case .tool:
            return .tool(content ?? "")
        }
    }
}
