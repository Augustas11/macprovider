import Foundation
import MLXLLM
import MLXLMCommon
import MacProviderCore

actor ModelRuntime {
    private let modelID: String?
    private let container: ModelContainer?
    private let stopTokenFilter: StopTokenFilter

    var loadedModelID: String? {
        modelID
    }

    init(modelID: String?) async throws {
        self.modelID = modelID

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

    func complete(_ request: ChatCompletionRequest) async throws -> CompletionResult {
        try request.validateModelMatches(modelID)
        guard let container else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }

        return try await container.perform { context in
            let input = UserInput(chat: request.messages.map { $0.mlxMessage })
            let lmInput = try await context.processor.prepare(input: input)
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

    private static func configuration(for modelID: String) -> ModelConfiguration {
        if modelID.hasPrefix("/") || FileManager.default.fileExists(atPath: modelID) {
            return ModelConfiguration(directory: URL(fileURLWithPath: modelID))
        }
        if let cachedSnapshot = localHuggingFaceSnapshot(for: modelID) {
            return ModelConfiguration(directory: cachedSnapshot)
        }
        return LLMModelFactory.shared.configuration(id: modelID)
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
