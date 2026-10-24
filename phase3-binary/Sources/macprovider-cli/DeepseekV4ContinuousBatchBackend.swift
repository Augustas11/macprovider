import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MacProviderCore

/// DeepSeek pools are row-owned state, not ordinary paged K/V. The scheduler's
/// block reservations bound logical resident tokens; this backend never claims
/// a paged gather or retained-cache handoff. Copies stage a complete row (window,
/// both compressor buffers and indexer) before any forward mutates it.
final class DeepseekV4ContinuousBatchBackend: ContinuousBatchSchedulerBackend, @unchecked Sendable {
    static let maxDecodeRows = 8
    static let prefillChunkTokens = 2_048
    private struct Row {
        var caches: [KVCache]
        var tokenCount: Int
    }
    private let container: ModelContainer
    private let lock = NSLock()
    private var rows: [String: Row] = [:]
    private var active: Set<String> = []
    private var cancelled = false

    init(container: ModelContainer) { self.container = container }

    /// The reference leaves the final prompt token in a separate forward.
    static func prefillEnd(offset: Int, promptCount: Int) -> Int {
        guard offset < promptCount else { return offset }
        return offset + (promptCount - offset == 1 ? 1 : min(prefillChunkTokens, promptCount - offset - 1))
    }

    private func stagedRow(id: String, offset: Int, model: DeepseekV4Model) throws -> Row {
        lock.lock()
        let existing = rows[id]
        let unavailable = cancelled || !active.contains(id)
        lock.unlock()
        guard !unavailable else { throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_row_retired") }
        if let existing {
            guard existing.tokenCount == offset else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_row_offset_mismatch")
            }
            return Row(caches: existing.caches.map { $0.copy() }, tokenCount: offset)
        }
        guard offset == 0 else { throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_retained_cache_unavailable") }
        return Row(caches: try model.newCache(parameters: nil), tokenCount: 0)
    }

    private func commit(_ row: Row, id: String) {
        lock.lock(); defer { lock.unlock() }
        if !cancelled && active.contains(id) { rows[id] = row }
    }

    func prefill(rows inputs: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        registerPrefill(inputs.map(\.requestID))
        return try await container.perform(nonSendable: inputs) { context, inputs in
            guard let model = context.model as? DeepseekV4Model else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_model_required")
            }
            // Even same-length prompts run alone: pool boundaries are call-local.
            return inputs.map { input in
                do {
                    guard !input.nativeMTPPromptPrefill, !input.promptTokens.isEmpty,
                          input.promptTokens.count <= Self.prefillChunkTokens,
                          !input.isFinalChunk || input.promptTokens.count == 1,
                          input.sampleFirstToken == input.isFinalChunk,
                          input.promptTokenOffset == input.committedKVTokenCount,
                          input.targetKVTokenCount == input.committedKVTokenCount + input.promptTokens.count,
                          ContinuousBatchRowSampler.supports(temperature: input.temperature, topP: input.topP)
                    else { throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_reference_prefill_required") }
                    var row = try self.stagedRow(id: input.requestID, offset: input.committedKVTokenCount, model: model)
                    let tokens = MLXArray(input.promptTokens.map(Int32.init)).reshaped([1, input.promptTokens.count])
                    let logits = model(tokens, cache: row.caches)
                    let sampled = input.sampleFirstToken ? ContinuousBatchRowSampler.sample(
                        logits: logits[0..., -1, 0...], rows: [.init(temperature: input.temperature,
                        topP: input.topP, samplerSeed: input.samplerSeed, samplerStep: input.samplerStep)]
                    ).asArray(Int.self).first : nil
                    eval(row.caches)
                    row.tokenCount = input.targetKVTokenCount
                    self.commit(row, id: input.requestID)
                    return ContinuousBatchPrefillOutput(requestID: input.requestID, sampledToken: sampled)
                } catch {
                    return ContinuousBatchPrefillOutput(requestID: input.requestID, failureCode: "continuous_batching_prefill_failed")
                }
            }
        }
    }

    func decode(rows inputs: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        guard !inputs.isEmpty else { return [] }
        guard inputs.count <= Self.maxDecodeRows, Set(inputs.map(\.requestID)).count == inputs.count else {
            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_decode_row_bound")
        }
        return try await container.perform(nonSendable: inputs) { context, inputs in
            guard let model = context.model as? DeepseekV4Model else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_model_required")
            }
            var eligible: [(ContinuousBatchDecodeInput, Row)] = []
            for input in inputs {
                guard !input.captureNativeMTPDrafterColumns,
                      input.presencePenalty == 0, input.frequencyPenalty == 0,
                      input.targetKVTokenCount == input.committedKVTokenCount + 1,
                      ContinuousBatchRowSampler.supports(temperature: input.temperature, topP: input.topP),
                      let row = try? self.stagedRow(id: input.requestID, offset: input.committedKVTokenCount, model: model)
                else { continue }
                eligible.append((input, row))
            }
            guard !eligible.isEmpty else { return inputs.map { .rowFailure(requestID: $0.requestID) } }
            let tokens = MLXArray(eligible.map { Int32($0.0.currentToken) }).reshaped([eligible.count, 1])
            let logits = model.decodeBatch(tokens, rowCaches: eligible.map { $0.1.caches })
            let sampled = ContinuousBatchRowSampler.sample(logits: logits[0..., -1, 0...], rows: eligible.map {
                .init(temperature: $0.0.temperature, topP: $0.0.topP,
                      samplerSeed: $0.0.samplerSeed, samplerStep: $0.0.samplerStep)
            }).asArray(Int.self)
            guard sampled.count == eligible.count else {
                throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_logits_shape")
            }
            eval(eligible.flatMap { $0.1.caches })
            var outputs: [String: ContinuousBatchDecodeOutcome] = [:]
            for (index, item) in eligible.enumerated() {
                var row = item.1
                row.tokenCount = item.0.targetKVTokenCount
                self.commit(row, id: item.0.requestID)
                outputs[item.0.requestID] = .output(.init(requestID: item.0.requestID, token: sampled[index]))
            }
            return inputs.map { outputs[$0.requestID] ?? .rowFailure(requestID: $0.requestID) }
        }
    }

    // Pools cannot be trimmed after a stop in a speculative multi-step window.
    // Keep the serve scheduler at window=1; callers may still use the protocol's
    // sequential window helper when they own a fixed-length lab completion.
    func commitTerminalKV(_ input: ContinuousBatchTerminalKVCommitInput) async throws {
        try await container.perform(nonSendable: input) { context, input in
            guard let model = context.model as? DeepseekV4Model else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_model_required")
            }
            var row = try self.stagedRow(id: input.requestID, offset: input.committedKVTokenCount, model: model)
            guard input.targetKVTokenCount == input.committedKVTokenCount + 1 else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_row_offset_mismatch")
            }
            let logits = model.decodeBatch(MLXArray([Int32(input.currentToken)]).reshaped([1, 1]), rowCaches: [row.caches])
            eval(logits); eval(row.caches)
            row.tokenCount = input.targetKVTokenCount
            self.commit(row, id: input.requestID)
        }
    }

    func finish(requestID: String) {
        lock.lock(); defer { lock.unlock() }
        rows.removeValue(forKey: requestID)
        active.remove(requestID)
    }

    func cancelInFlight() async {
        markCancelled()
        // ModelContainer serializes all forwards. Drain it before releasing
        // scheduler bindings even when cancellation races with a queued call.
        await container.perform { _ in () }
    }

    private func registerPrefill(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        if !cancelled { active.formUnion(ids) }
    }

    private func markCancelled() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        rows.removeAll()
        active.removeAll()
    }
}
