import Foundation
import MLXLLM
import MLXLMCommon
import MacProviderCore

actor ModelRuntime {
    private let modelID: String?
    private let container: ModelContainer?
    private let stopTokenFilter: StopTokenFilter
    private let maxContextTokens: Int

    var loadedModelID: String? {
        modelID
    }

    init(modelID: String?, maxContextTokensOverride: Int? = nil) async throws {
        self.modelID = modelID
        self.maxContextTokens = maxContextTokensOverride ?? Self.defaultMaxContextTokens()

        guard let modelID else {
            self.container = nil
            self.stopTokenFilter = StopTokenFilter(tokens: [])
            return
        }

        let configuration = Self.configuration(for: modelID)
        let container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
        self.container = container

        let directory = configuration.modelDirectory()
        let tokenizerConfigURL = directory.appendingPathComponent("tokenizer_config.json")
        if FileManager.default.fileExists(atPath: tokenizerConfigURL.path) {
            self.stopTokenFilter = try StopTokenConfigExtractor.extract(fromTokenizerConfigAt: tokenizerConfigURL)
        } else {
            self.stopTokenFilter = StopTokenFilter(tokens: [])
        }
    }

    func preflight(_ request: ChatCompletionRequest) async throws {
        try request.validateModelMatches(modelID)
        guard let container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        try await container.perform { context in
            let input = UserInput(chat: request.messages.map { $0.mlxMessage })
            let lmInput = try await context.processor.prepare(input: input)
            try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
        }
    }

    func complete(_ request: ChatCompletionRequest) async throws -> CompletionResult {
        try request.validateModelMatches(modelID)
        guard let container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        return try await container.perform { context in
            let input = UserInput(chat: request.messages.map { $0.mlxMessage })
            let lmInput = try await context.processor.prepare(input: input)
            try Self.validatePromptTokenCount(lmInput.text.tokens.size, maxContextTokens: maxContextTokens)
            let parameters = GenerateParameters(
                maxTokens: request.maxTokens,
                temperature: Float(request.temperature),
                topP: Float(request.topP)
            )
            let result: GenerateResult = try generate(input: lmInput, parameters: parameters, context: context) { (_: [Int]) in
                GenerateDisposition.more
            }

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

    func stream(
        _ request: ChatCompletionRequest,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> CompletionResult {
        try request.validateModelMatches(modelID)
        guard let container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        let maxContextTokens = maxContextTokens
        return try await container.perform { context in
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

    private static func defaultMaxContextTokens() -> Int {
        let ramGiB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        switch ramGiB {
        case ...12:
            return 20_000
        case ...24:
            return 50_000
        case ...48:
            return 120_000
        default:
            return 200_000
        }
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

struct CompletionResult {
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
