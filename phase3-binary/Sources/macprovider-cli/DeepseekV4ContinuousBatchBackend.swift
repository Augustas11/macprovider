import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MacProviderCore

/// DeepSeek pools are row-owned state, not ordinary paged K/V. The scheduler's
/// block reservations bound logical resident tokens; this backend never claims
/// a paged gather or retained-cache handoff. Forwards mutate the row-owned caches
/// directly; a failed or stopped row is retired rather than rolled back.
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

    private func ownedRow(id: String, offset: Int, model: DeepseekV4Model) throws -> Row {
        lock.lock()
        let existing = rows[id]
        let unavailable = cancelled || !active.contains(id)
        lock.unlock()
        guard !unavailable else { throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_row_retired") }
        if let existing {
            guard existing.tokenCount == offset else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_row_offset_mismatch")
            }
            return existing
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
                    var row = try self.ownedRow(id: input.requestID, offset: input.committedKVTokenCount, model: model)
                    let tokens = MLXArray(input.promptTokens.map(Int32.init)).reshaped([1, input.promptTokens.count])
                    let logits = model(tokens, cache: row.caches)
                    let sampledArray = input.sampleFirstToken ? ContinuousBatchRowSampler.sample(
                        logits: logits[0..., -1, 0...], rows: [.init(temperature: input.temperature,
                        topP: input.topP, samplerSeed: input.samplerSeed, samplerStep: input.samplerStep,
                        grammarConstraint: input.grammarConstraint)]
                    ) : nil
                    eval((sampledArray.map { [$0] } ?? []) + row.caches.flatMap(\.state))
                    let sampled = sampledArray?.asArray(Int.self).first
                    row.tokenCount = input.targetKVTokenCount
                    self.commit(row, id: input.requestID)
                    return ContinuousBatchPrefillOutput(requestID: input.requestID, sampledToken: sampled)
                } catch {
                    self.finish(requestID: input.requestID)
                    return ContinuousBatchPrefillOutput(requestID: input.requestID, failureCode: "continuous_batching_prefill_failed")
                }
            }
        }
    }

    func decode(rows inputs: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        try await decodeLockstepWindow(rows: inputs, steps: 1, onStep: nil)
    }

    /// One graph is queued ahead of the tokens being read. DeepSeek pools cannot
    /// be trimmed, so a stop retires that row's state, including its queued
    /// one-step overshoot. Only continuing rows publish their final logical
    /// offset. This backend offers no retained-cache/serial-cache handoff.
    func decodeLockstepWindow(
        rows inputs: [ContinuousBatchDecodeInput],
        steps: Int,
        onStep: ContinuousBatchDecodeWindowStepObserver?
    ) async throws -> [ContinuousBatchDecodeOutcome] {
        guard !inputs.isEmpty, steps >= 1 else { return [] }
        guard inputs.count <= Self.maxDecodeRows, Set(inputs.map(\.requestID)).count == inputs.count else {
            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_decode_row_bound")
        }
        return try await container.perform(nonSendable: inputs) { context, inputs in
            guard let model = context.model as? DeepseekV4Model else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_model_required")
            }
            var eligible: [(ContinuousBatchDecodeInput, Row)] = []
            for input in inputs {
                let (expectedTarget, targetOverflow) = input.committedKVTokenCount.addingReportingOverflow(steps)
                guard !targetOverflow, !input.captureNativeMTPDrafterColumns,
                      input.presencePenalty == 0, input.frequencyPenalty == 0,
                      input.targetKVTokenCount == expectedTarget,
                      ContinuousBatchRowSampler.supports(temperature: input.temperature, topP: input.topP),
                      let row = try? self.ownedRow(id: input.requestID, offset: input.committedKVTokenCount, model: model)
                else {
                    self.finish(requestID: input.requestID)
                    continue
                }
                eligible.append((input, row))
            }
            guard !eligible.isEmpty else { return inputs.map { .rowFailure(requestID: $0.requestID) } }
            var collected = eligible.map { _ in [Int]() }
            var stopped = Set<Int>()
            var streaming = eligible.count == inputs.count

            func enqueue(_ tokens: MLXArray, indices: [Int], step: Int) -> MLXArray {
                let logits = model.decodeBatch(tokens.reshaped([indices.count, 1]),
                    rowCaches: indices.map { eligible[$0].1.caches })
                let sampled = ContinuousBatchRowSampler.sample(logits: logits[0..., -1, 0...], rows: indices.map {
                    let input = eligible[$0].0
                    // Grammar rows run one-step windows (the scheduler bounds them),
                    // so no pipelined overshoot advances their grammar state.
                    return .init(temperature: input.temperature, topP: input.topP,
                        samplerSeed: input.samplerSeed, samplerStep: input.samplerStep + step,
                        grammarConstraint: input.grammarConstraint)
                })
                // A single evaluation includes cache writes that logits do not
                // depend on; asArray below only waits for this queued work.
                asyncEval([sampled] + indices.flatMap { eligible[$0].1.caches.flatMap(\.state) })
                return sampled
            }

            var pendingIndices = Array(eligible.indices)
            var pending = enqueue(MLXArray(eligible.map { Int32($0.0.currentToken) }), indices: pendingIndices, step: 0)
            var cancelledWindow = false
            for step in 0..<steps {
                let current = pending
                let currentIndices = pendingIndices
                // Stops from the previous host read are excluded before the
                // next graph is built. A newly discovered stop has at most one
                // already queued forward, and its caches are never committed.
                let nextIndices = currentIndices.filter { !stopped.contains($0) }
                if step + 1 < steps, !nextIndices.isEmpty {
                    let positions = nextIndices.map { Int32(currentIndices.firstIndex(of: $0)!) }
                    let nextTokens = nextIndices.count == currentIndices.count
                        ? current : current.take(MLXArray(positions), axis: 0)
                    pending = enqueue(nextTokens, indices: nextIndices, step: step + 1)
                    pendingIndices = nextIndices
                }
                let sampled = current.asArray(Int.self)
                guard sampled.count == currentIndices.count else {
                    // Directly mutated caches cannot be retried after a failed
                    // forward. The scheduler already isolates row failures.
                    eligible.forEach { self.finish(requestID: $0.0.requestID) }
                    return inputs.map { .rowFailure(requestID: $0.requestID) }
                }
                for (position, index) in currentIndices.enumerated() where !stopped.contains(index) {
                    collected[index].append(sampled[position])
                    let input = eligible[index].0
                    let history = input.generatedTokens + collected[index]
                    if input.stopTokenSequences.contains(where: { !$0.isEmpty && history.suffix($0.count).elementsEqual($0) }) {
                        stopped.insert(index)
                        self.finish(requestID: input.requestID)
                    }
                }
                if streaming, let onStep {
                    if !onStep(.init(stepIndex: step, tokens: sampled)) {
                        cancelledWindow = true
                        break
                    }
                }
                // After a terminal row leaves, per-row outputs have different
                // lengths. The authoritative result carries the remaining
                // tokens; no incomplete cohort is sent to the step observer.
                if !stopped.isEmpty { streaming = false }
                if stopped.count == eligible.count { break }
            }
            // The observer/stop may end before the queued overshoot is read.
            // Drain that graph before the container hop releases its row state.
            if cancelledWindow || stopped.count == eligible.count {
                eval([pending] + eligible.flatMap { $0.1.caches.flatMap(\.state) })
            }
            var outputs: [String: ContinuousBatchDecodeOutcome] = [:]
            for (index, item) in eligible.enumerated() {
                if cancelledWindow {
                    self.finish(requestID: item.0.requestID)
                } else if !stopped.contains(index) {
                    var row = item.1
                    row.tokenCount += collected[index].count
                    self.commit(row, id: item.0.requestID)
                }
                outputs[item.0.requestID] = .output(.init(requestID: item.0.requestID, tokens: collected[index]))
            }
            return inputs.map { outputs[$0.requestID] ?? .rowFailure(requestID: $0.requestID) }
        }
    }

    func commitTerminalKV(_ input: ContinuousBatchTerminalKVCommitInput) async throws {
        try await container.perform(nonSendable: input) { context, input in
            guard let model = context.model as? DeepseekV4Model else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_model_required")
            }
            var row = try self.ownedRow(id: input.requestID, offset: input.committedKVTokenCount, model: model)
            guard input.targetKVTokenCount == input.committedKVTokenCount + 1 else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_row_offset_mismatch")
            }
            let logits = model.decodeBatch(MLXArray([Int32(input.currentToken)]).reshaped([1, 1]), rowCaches: [row.caches])
            eval([logits] + row.caches.flatMap(\.state))
            row.tokenCount = input.targetKVTokenCount
            self.commit(row, id: input.requestID)
        }
    }

    /// SPEC-024 FR-CI2a: the row's own `newCache` layers are already the
    /// serial cache format; copy them at exactly `tokenCount`.
    func snapshotPromptCache(requestID: String, tokenCount: Int) async -> ContinuousBatchSerialConversationCache? {
        await container.perform { _ -> ContinuousBatchSerialConversationCache? in
            self.lock.lock()
            let row = self.rows[requestID]
            self.lock.unlock()
            guard let row, row.tokenCount == tokenCount else { return nil }
            let layers = row.caches.map { $0.copy() }
            eval(layers)
            return ContinuousBatchSerialConversationCache(
                layers: layers, recurrentCheckpoints: [], tokenCount: tokenCount, promptSnapshot: true)
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
