import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

/// SPEC-036 FR-21 teacher-forced scoring on the loaded model.
///
/// The scorer never logs or keeps the body, the output, or per-token data:
/// the inputs live only for the duration of one forward pass and the result
/// carries aggregate counts.
enum ComputeScoreRuntime {
    static let prefillChunkTokens = 512
    static let scoreChunkTokens = 128

    struct Scores: Sendable, Equatable {
        let logprobs: [Double]
        let top1: [Bool]
    }

    /// Prefills every prompt token but the last, then feeds the last prompt
    /// token followed by all but the last output token. Row `k` of the second
    /// phase predicts output token `k`, so each output position is scored
    /// against the logits of the position before it.
    static func teacherForced(
        model: any LanguageModel,
        promptTokens: [Int],
        outputTokens: [Int]
    ) throws -> Scores {
        guard let lastPrompt = promptTokens.last, !outputTokens.isEmpty else {
            return Scores(logprobs: [], top1: [])
        }
        let cache = try model.newCache(parameters: nil)
        let head = promptTokens.count - 1
        var offset = 0
        while offset < head {
            let end = min(offset + prefillChunkTokens, head)
            let chunk = MLXArray(promptTokens[offset..<end].map { Int32($0) }).reshaped([1, end - offset])
            _ = model(chunk, cache: cache)
            eval(cache.flatMap { $0.state })
            offset = end
        }
        let inputs = [lastPrompt] + outputTokens.dropLast()
        var logprobs: [Double] = []
        var top1: [Bool] = []
        logprobs.reserveCapacity(outputTokens.count)
        top1.reserveCapacity(outputTokens.count)
        var start = 0
        while start < inputs.count {
            let end = min(start + scoreChunkTokens, inputs.count)
            let count = end - start
            let chunk = MLXArray(inputs[start..<end].map { Int32($0) }).reshaped([1, count])
            let logits = model(chunk, cache: cache)
            let vocab = logits.dim(logits.ndim - 1)
            let rows = logits.reshaped([-1, vocab]).asType(.float32)
            let logProbs = rows - logSumExp(rows, axis: -1, keepDims: true)
            let targets = Array(outputTokens[start..<end])
            let targetArray = MLXArray(targets.map { Int32($0) }).reshaped([count, 1])
            let picked = takeAlong(logProbs, targetArray, axis: -1).reshaped([-1])
            let best = argMax(rows, axis: -1).asType(.int32)
            eval(picked, best)
            eval(cache.flatMap { $0.state })
            let pickedValues = picked.asArray(Float.self)
            let bestValues = best.asArray(Int32.self)
            for i in 0..<count {
                logprobs.append(Double(pickedValues[i]))
                top1.append(Int(bestValues[i]) == targets[i])
            }
            start = end
        }
        return Scores(logprobs: logprobs, top1: top1)
    }

    struct Outcome: Sendable {
        let status: ComputeScoreProtocol.Status
        let promptTokens: Int
        let scores: Scores
    }

    /// The FR-21 scoring body on a loaded model: the prompt is built exactly
    /// as the serving path builds it, the scored text is tokenized without
    /// special tokens and capped at the FR-21 bound, and every output token
    /// is teacher-forced. The provider scoring job and the lab command
    /// `msb-compute-score` both run this.
    static func score(
        context: ModelContext,
        parsed: ChatCompletionRequest,
        scoredText: String,
        templateSupportsThinkingToggle: Bool,
        templateSupportsPreserveThinking: Bool
    ) async throws -> Outcome {
        let input = try ModelRuntime.userInput(
            for: parsed,
            templateSupportsThinkingToggle: templateSupportsThinkingToggle,
            templateSupportsPreserveThinking: templateSupportsPreserveThinking
        )
        let lmInput = try await context.processor.prepare(input: input)
        let promptTokens = lmInput.text.tokens.reshaped([-1]).asArray(Int32.self).map(Int.init)
        let empty = Scores(logprobs: [], top1: [])
        guard promptTokens.count <= ComputeScoreProtocol.maxPromptTokens else {
            return Outcome(status: .tooLong, promptTokens: 0, scores: empty)
        }
        let outputTokens = Array(
            context.tokenizer.encode(text: scoredText, addSpecialTokens: false)
                .prefix(ComputeScoreProtocol.maxScoredTokens)
        )
        guard !promptTokens.isEmpty, !outputTokens.isEmpty else {
            return Outcome(status: .invalid, promptTokens: 0, scores: empty)
        }
        let scores = try teacherForced(
            model: context.model,
            promptTokens: promptTokens,
            outputTokens: outputTokens
        )
        return Outcome(status: .ok, promptTokens: promptTokens.count, scores: scores)
    }
}

extension ModelRuntime {

    /// Runs one FR-21 scoring job. Any failure to run is `unavailable`; a body
    /// the serving parser rejects is `invalid`; a prompt over the FR-21 bound
    /// is `too_long`. The job runs as an in-flight request under the serial
    /// inference permit, so a warm swap drains it like any other request.
    func runComputeScore(_ request: ComputeScoreProtocol.Request, now: Date = Date()) async -> ComputeScoreProtocol.Result {
        guard request.expiresAt > now else {
            return ComputeScoreProtocol.Result(request: request, status: .unavailable)
        }
        let parsed: ChatCompletionRequest
        do {
            parsed = try ChatCompletionRequest.parse(data: Data(request.body.utf8))
        } catch {
            return ComputeScoreProtocol.Result(request: request, status: .invalid)
        }
        guard parsed.model == request.modelID else {
            return ComputeScoreProtocol.Result(request: request, status: .invalid)
        }
        let handle: RequestHandle
        do {
            handle = try acquireRequestHandle(parsed)
        } catch {
            return ComputeScoreProtocol.Result(request: request, status: .unavailable)
        }
        defer { unregisterInFlight(handle.registrationID) }
        // #2016: teacher-forced scoring uses the text-only `model(MLXArray, cache:)`
        // forward, which a native-vision (VLM) container does not implement.
        guard let container = handle.snapshot.container,
              handle.snapshot.nativeVisionProfile == nil,
              handle.snapshot.weightsManifestSHA256 == request.weightsManifestSHA256
        else {
            return ComputeScoreProtocol.Result(request: request, status: .unavailable)
        }
        let thinkingToggle = handle.snapshot.templateSupportsThinkingToggle
        let preserveThinking = handle.snapshot.templateSupportsPreserveThinking
        let scoredText = request.scoredText
        let drainCancelled = handle.drainCancelled
        do {
            let outcome: ComputeScoreRuntime.Outcome? = try await serialInferenceGate.withPermit {
                try drainCancelled.check()
                // The permit may have been queued behind other work: a job
                // whose deadline passed meanwhile is discarded by the
                // coordinator, so it runs no inference.
                guard request.expiresAt > Date() else { return nil }
                return try await container.perform { context in
                    try drainCancelled.check()
                    return try await ComputeScoreRuntime.score(
                        context: context,
                        parsed: parsed,
                        scoredText: scoredText,
                        templateSupportsThinkingToggle: thinkingToggle,
                        templateSupportsPreserveThinking: preserveThinking
                    )
                }
            }
            guard let outcome else {
                return ComputeScoreProtocol.Result(request: request, status: .unavailable)
            }
            guard outcome.status == .ok else {
                return ComputeScoreProtocol.Result(request: request, status: outcome.status)
            }
            let aggregate = ComputeScoreProtocol.aggregate(logprobs: outcome.scores.logprobs, top1: outcome.scores.top1)
            return ComputeScoreProtocol.Result(
                request: request,
                status: .ok,
                promptTokens: outcome.promptTokens,
                scoredTokens: aggregate.scored,
                top1Matches: aggregate.matches,
                sumLogprob: aggregate.sum
            )
        } catch {
            return ComputeScoreProtocol.Result(request: request, status: .unavailable)
        }
    }

    /// Lab entry point for `msb-compute-score`: the FR-21 scoring body under
    /// the same serial inference permit as a provider scoring job, without
    /// the wire request's identity, manifest and expiry checks.
    func labComputeScore(_ parsed: ChatCompletionRequest, scoredText: String) async throws -> ComputeScoreRuntime.Outcome {
        let snapshot = await currentSnapshot()
        guard let container = snapshot.container else {
            throw ModelRuntimeLoadError(target: "no model loaded")
        }
        let thinkingToggle = snapshot.templateSupportsThinkingToggle
        let preserveThinking = snapshot.templateSupportsPreserveThinking
        return try await serialInferenceGate.withPermit {
            try await container.perform { context in
                try await ComputeScoreRuntime.score(
                    context: context,
                    parsed: parsed,
                    scoredText: scoredText,
                    templateSupportsThinkingToggle: thinkingToggle,
                    templateSupportsPreserveThinking: preserveThinking
                )
            }
        }
    }
}
