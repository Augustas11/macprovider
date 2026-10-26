import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MacProviderCore

/// DeepSeek pools are row-owned state, not ordinary paged K/V. The scheduler's
/// block reservations bound logical resident tokens; this backend never claims
/// a paged gather or retained-cache handoff. Ordinary forwards mutate row-owned
/// caches; native verification publishes only an exactly retained cache prefix.
final class DeepseekV4ContinuousBatchBackend: ContinuousBatchSchedulerBackend, @unchecked Sendable {
    static let maxDecodeRows = 8
    static let prefillChunkTokens = 2_048
    static let nativeMTPDrafterColumnCap = 1_024
    private struct Row {
        var caches: [KVCache]
        var tokenCount: Int
        var drafterState: MTPDrafterState? = nil
        var lastHidden: MLXArray? = nil
        var pendingDrafterColumns: [(token: Int, hidden: MLXArray)] = []
    }
    private struct NativeTransaction {
        let original: Row
        let snapshots: [[KVCache]]
        let hidden: [MLXArray]
        let proposalTokens: [Int]
        let targetTokenIDs: [Int]
    }
    private let container: ModelContainer
    private let nativeMTPDrafterContainer: MTPDrafterContainer?
    private let nativeMTPVerifyTokenBudget: Int
    private var nativeTransactions: [String: NativeTransaction] = [:]
    private let lock = NSLock()
    private var rows: [String: Row] = [:]
    private var active: Set<String> = []
    private var cancelled = false
    #if DEBUG || MACPROVIDER_LAB_HARNESS
    private var labRoundObserver: (@Sendable (String, Int, Int) -> Void)?

    func labDrafterPosition(requestID: String) -> (position: Int?, buffered: Int)? {
        lock.withLock {
            rows[requestID].map { ($0.drafterState?.nextPosition, $0.pendingDrafterColumns.count) }
        }
    }

    func installLabRoundObserver(_ observer: (@Sendable (String, Int, Int) -> Void)?) {
        lock.withLock { labRoundObserver = observer }
    }
    #endif

    init(container: ModelContainer, nativeMTPDrafterContainer: MTPDrafterContainer? = nil,
         nativeMTPVerifyTokenBudget: Int = DeepseekV4ContinuousBatchBackend.maxDecodeRows) {
        self.container = container
        self.nativeMTPDrafterContainer = nativeMTPDrafterContainer
        self.nativeMTPVerifyTokenBudget = max(1, nativeMTPVerifyTokenBudget)
    }

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
            // Keep the reference serial prefill partition for each row.
            var outputs: [ContinuousBatchPrefillOutput] = []
            for input in inputs {
                do {
                    guard (!input.nativeMTPPromptPrefill || self.nativeMTPDrafterContainer != nil),
                          !input.promptTokens.isEmpty,
                          input.promptTokens.count <= Self.prefillChunkTokens,
                          !input.isFinalChunk || input.promptTokens.count == 1,
                          input.sampleFirstToken == input.isFinalChunk,
                          input.promptTokenOffset == input.committedKVTokenCount,
                          input.targetKVTokenCount == input.committedKVTokenCount + input.promptTokens.count,
                          ContinuousBatchRowSampler.supports(temperature: input.temperature, topP: input.topP)
                    else { throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_reference_prefill_required") }
                    var row = try self.ownedRow(id: input.requestID, offset: input.committedKVTokenCount, model: model)
                    let tokens = MLXArray(input.promptTokens.map(Int32.init)).reshaped([1, input.promptTokens.count])
                    var state = LMOutput.State()
                    state[mtpEmitFlagKey] = input.nativeMTPPromptPrefill
                    let output = model(.init(tokens: tokens), cache: row.caches, state: state)
                    let logits = output.logits
                    let sampledArray = input.sampleFirstToken ? ContinuousBatchRowSampler.sample(
                        logits: logits[0..., -1, 0...], rows: [.init(temperature: input.temperature,
                        topP: input.topP, samplerSeed: input.samplerSeed, samplerStep: input.samplerStep,
                        grammarConstraint: input.grammarConstraint)]
                    ) : nil
                    eval((sampledArray.map { [$0] } ?? []) + row.caches.flatMap(\.state))
                    let sampled = sampledArray?.asArray(Int.self).first
                    if input.nativeMTPPromptPrefill {
                        guard let hidden = output.state?[mtpLastHiddenStatesKey] else {
                            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_drafter_hidden_required")
                        }
                        row.drafterState = try await self.prepareDrafter(
                            target: model, tokens: tokens, hidden: hidden,
                            bonus: sampled ?? 0, state: row.drafterState)
                        row.lastHidden = hidden[0..., (-1)..., 0...]
                    }
                    row.tokenCount = input.targetKVTokenCount
                    self.commit(row, id: input.requestID)
                    outputs.append(ContinuousBatchPrefillOutput(requestID: input.requestID, sampledToken: sampled))
                } catch {
                    self.finish(requestID: input.requestID)
                    outputs.append(ContinuousBatchPrefillOutput(requestID: input.requestID, failureCode: "continuous_batching_prefill_failed"))
                }
            }
            return outputs
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
        guard steps <= Self.nativeMTPDrafterColumnCap else {
            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_decode_window_bound")
        }
        guard inputs.count <= Self.maxDecodeRows, Set(inputs.map(\.requestID)).count == inputs.count else {
            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_decode_row_bound")
        }
        return try await container.perform(nonSendable: inputs) { context, inputs in
            guard let model = context.model as? DeepseekV4Model else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_model_required")
            }
            guard model.batchesExactly else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_hisa_not_batch_exact")
            }
            var eligible: [(ContinuousBatchDecodeInput, Row)] = []
            for input in inputs {
                let (expectedTarget, targetOverflow) = input.committedKVTokenCount.addingReportingOverflow(steps)
                guard !targetOverflow,
                      (!input.captureNativeMTPDrafterColumns || self.nativeMTPDrafterContainer != nil),
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
            // R006: a held row pays no adapter forward until proposal resumes or
            // its next ordinary window would exceed the owned-column cap.
            let due = eligible.indices.filter {
                eligible[$0].0.captureNativeMTPDrafterColumns && Self.needsDrafterCatchup(
                    bufferedColumns: eligible[$0].1.pendingDrafterColumns.count, nextWindow: steps)
            }
            let caughtUp = try await self.catchUpDrafterColumns(target: model, rows: due.map { eligible[$0].1 })
            for (position, index) in due.enumerated() { eligible[index].1 = caughtUp[position] }
            var collected = eligible.map { _ in [Int]() }
            var stopped = Set<Int>()
            var streaming = eligible.count == inputs.count

            func enqueue(_ tokens: MLXArray, indices: [Int], step: Int) -> (tokens: MLXArray, hidden: MLXArray?) {
                let output = model.decodeBatchOutput(tokens.reshaped([indices.count, 1]),
                    rowCaches: indices.map { eligible[$0].1.caches },
                    emitMTPState: indices.contains { eligible[$0].0.captureNativeMTPDrafterColumns })
                let logits = output.logits
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
                return (sampled, output.state?[mtpLastHiddenStatesKey])
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
                        ? current.tokens : current.tokens.take(MLXArray(positions), axis: 0)
                    pending = enqueue(nextTokens, indices: nextIndices, step: step + 1)
                    pendingIndices = nextIndices
                }
                let sampled = current.tokens.asArray(Int.self)
                guard sampled.count == currentIndices.count else {
                    // Directly mutated caches cannot be retried after a failed
                    // forward. The scheduler already isolates row failures.
                    eligible.forEach { self.finish(requestID: $0.0.requestID) }
                    return inputs.map { .rowFailure(requestID: $0.requestID) }
                }
                for (position, index) in currentIndices.enumerated() where !stopped.contains(index) {
                    collected[index].append(sampled[position])
                    let input = eligible[index].0
                    if input.captureNativeMTPDrafterColumns {
                        guard let hidden = current.hidden else {
                            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_drafter_hidden_required")
                        }
                        // Gather allocates owned storage; evaluation releases the
                        // shared batch graph rather than retaining every peer.
                        let rowHidden = Self.detachedHiddenColumn(hidden, row: position)
                        eval(rowHidden)
                        eligible[index].1.pendingDrafterColumns.append((sampled[position], rowHidden))
                        eligible[index].1.lastHidden = rowHidden
                    }
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
                eval([pending.tokens] + eligible.flatMap { $0.1.caches.flatMap(\.state) })
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

    /// DeepInfer's confidence scheduler ranks cumulative survival probabilities;
    /// ties retain request/position order. Every row always retains its anchor.
    static func confidenceScheduledDepths(
        confidences: [[Float]], maximumDepths: [Int], tokenBudget: Int
    ) throws -> [Int] {
        guard confidences.count == maximumDepths.count,
              maximumDepths.allSatisfy({ $0 >= 0 }), tokenBudget >= maximumDepths.count
        else { throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_invalid_confidence_budget") }
        for row in maximumDepths.indices {
            guard confidences[row].count >= maximumDepths[row],
                  confidences[row].prefix(maximumDepths[row]).allSatisfy({ $0.isFinite && (0...1).contains($0) })
            else { throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_invalid_confidence") }
        }
        return MTPConfidenceSchedule.proposalCounts(
            conditionalRates: maximumDepths.indices.map { Array(confidences[$0].prefix(maximumDepths[$0])) },
            verificationBudget: tokenBudget)
    }

    static func detachedHiddenColumn(_ hidden: MLXArray, row: Int) -> MLXArray {
        hidden[0..., (-1)..., 0...].take(MLXArray([Int32(row)]), axis: 0)
    }

    static func needsDrafterCatchup(bufferedColumns: Int, nextWindow: Int) -> Bool {
        bufferedColumns > 0 && bufferedColumns > nativeMTPDrafterColumnCap - nextWindow
    }

    /// One ragged packed adapter advance for all due rows, with no padded
    /// columns and no target replay. The final emitted token anchors the next
    /// proposal; hidden columns advance exactly their committed prefix length.
    private func catchUpDrafterColumns(target: DeepseekV4Model, rows: [Row]) async throws -> [Row] {
        guard !rows.isEmpty else { return [] }
        guard let drafter = nativeMTPDrafterContainer else {
            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_drafter_required")
        }
        return try await drafter.perform(nonSendable: (target, rows)) { context, values in
            guard let model = context.model as? any MTPPackedStatefulDrafterModel else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_packed_drafter_required")
            }
            let advances = try values.1.map { row -> MTPPackedDrafterAdvanceRow in
                guard let state = row.drafterState, !row.pendingDrafterColumns.isEmpty,
                      row.pendingDrafterColumns.count <= Self.nativeMTPDrafterColumnCap,
                      state.nextPosition + row.pendingDrafterColumns.count == row.tokenCount else {
                    throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_pending_drafter_offset_mismatch")
                }
                return .init(targetHidden: concatenated(row.pendingDrafterColumns.map(\.hidden), axis: 1),
                    acceptedTokens: row.pendingDrafterColumns.dropLast().map(\.token),
                    finalToken: row.pendingDrafterColumns.last!.token, positionDeltas: nil, state: state)
            }
            let result = try model.advanceAndProposePacked(target: values.0, rows: advances, sampler: ArgMaxSampler())
            eval(result.states.flatMap { $0.cache.flatMap(\.state) } + [result.proposals]
                + result.states.compactMap(\.proposalConfidence))
            var updated = values.1
            for index in updated.indices {
                guard result.states[index].nextPosition == updated[index].tokenCount else {
                    throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_drafter_catchup_offset_mismatch")
                }
                updated[index].drafterState = result.states[index]
                updated[index].pendingDrafterColumns = []
            }
            return updated
        }
    }

    private func prepareDrafter(
        target: DeepseekV4Model, tokens: MLXArray, hidden: MLXArray,
        bonus: Int, state: MTPDrafterState?
    ) async throws -> MTPDrafterState {
        guard let drafter = nativeMTPDrafterContainer else {
            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_drafter_required")
        }
        return try await drafter.perform(nonSendable: (target, tokens, hidden, state)) { context, values in
            guard let model = context.model as? any MTPPackedStatefulDrafterModel else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_packed_drafter_required")
            }
            var state = values.3 ?? model.makeState(parameters: nil)
            model.prepareDrafterState(target: values.0, promptTokens: values.1,
                targetHidden: values.2, firstBonus: MLXArray([Int32(bonus)]), positionDeltas: nil,
                state: &state, sampler: ArgMaxSampler())
            eval(state.cache.flatMap(\.state) + [values.2])
            return state
        }
    }

    func proposeNativeMTPPackedRound(
        rows inputs: [ContinuousBatchNativeMTPProposalInput]
    ) async throws -> [String: [Int]]? {
        guard let drafter = nativeMTPDrafterContainer else { return nil }
        guard inputs.count <= Self.maxDecodeRows, Set(inputs.map(\.requestID)).count == inputs.count else {
            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_decode_row_bound")
        }
        guard !inputs.isEmpty else { return [:] }
        return try await container.perform(nonSendable: inputs) { context, inputs in
            guard let target = context.model as? DeepseekV4Model else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_model_required")
            }
            var rowStates: [Row] = []
            for input in inputs {
                let (row, unavailable) = self.lock.withLock {
                    (self.rows[input.requestID], self.cancelled || !self.active.contains(input.requestID))
                }
                guard !unavailable, let row, row.drafterState != nil, row.lastHidden != nil else {
                    throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_drafter_prefill_required")
                }
                rowStates.append(row)
            }
            let due = inputs.indices.filter { inputs[$0].maximumProposalDepth > 0
                && !rowStates[$0].pendingDrafterColumns.isEmpty }
            let caughtUp = try await self.catchUpDrafterColumns(target: target, rows: due.map { rowStates[$0] })
            for (position, index) in due.enumerated() { rowStates[index] = caughtUp[position] }
            let drafted = try await drafter.perform(nonSendable: (target, rowStates)) { context, values in
                guard let model = context.model as? any MTPPackedStatefulDrafterModel else {
                    throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_packed_drafter_required")
                }
                var updated = values.1
                var proposals: [MLXArray] = []
                var confidence: [MLXArray] = []
                for input in inputs {
                    guard input.maximumProposalDepth >= 0,
                          (input.maximumProposalDepth == 0 || NativeMTPProposalBounds.fits(
                            maximumProposalDepth: input.maximumProposalDepth, maximumBlockSize: model.maximumBlockSize))
                    else { throw ContinuousBatchSchedulerError.unsupported("native_mtp_proposal_depth_exceeds_drafter") }
                }
                let unseeded = inputs.indices.filter {
                    inputs[$0].maximumProposalDepth > 0 && ((updated[$0].drafterState!.seedToken?.size ?? 0)
                        < inputs[$0].maximumProposalDepth || (updated[$0].drafterState!.proposalConfidence?.size ?? 0)
                        < inputs[$0].maximumProposalDepth)
                }
                if !unseeded.isEmpty {
                    guard let dspark = model as? DeepseekV4DSparkDraftModel else {
                        throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_dspark_drafter_required")
                    }
                    let initial = try dspark.proposePacked(target: values.0,
                        states: unseeded.map { updated[$0].drafterState! },
                        anchors: unseeded.map { inputs[$0].currentToken },
                        depth: inputs.map(\.maximumProposalDepth).max()!)
                    for (index, row) in unseeded.enumerated() { updated[row].drafterState = initial.states[index] }
                }
                for (index, input) in inputs.enumerated() {
                    if input.maximumProposalDepth == 0 {
                        proposals.append(MLXArray.zeros([0], dtype: .int32))
                        confidence.append(MLXArray.zeros([0], dtype: .float32))
                        continue
                    }
                    guard let tokens = updated[index].drafterState!.seedToken,
                          let rates = updated[index].drafterState!.proposalConfidence,
                          tokens.size >= input.maximumProposalDepth, rates.size >= input.maximumProposalDepth else {
                        throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_confidence_required")
                    }
                    proposals.append(tokens[0..., ..<input.maximumProposalDepth].asType(.int32).reshaped([-1]))
                    confidence.append(rates[0..., ..<input.maximumProposalDepth].asType(.float32).reshaped([-1]))
                }
                eval(proposals + confidence + updated.flatMap { $0.drafterState!.cache.flatMap(\.state) }
                    + updated.compactMap { $0.drafterState?.seedToken }
                    + updated.compactMap { $0.drafterState?.proposalConfidence })
                return (updated, proposals.map { $0.asArray(Int32.self).map(Int.init) },
                    confidence.map { $0.asArray(Float.self) })
            }
            let depths = try Self.confidenceScheduledDepths(confidences: drafted.2,
                maximumDepths: inputs.map(\.maximumProposalDepth),
                tokenBudget: max(inputs.count, self.nativeMTPVerifyTokenBudget))
            var result: [String: [Int]] = [:]
            for (index, input) in inputs.enumerated() {
                self.commit(drafted.0[index], id: input.requestID)
                result[input.requestID] = Array(drafted.1[index].prefix(depths[index]))
            }
            return result
        }
    }

    /// Batch pointwise target work across ragged rows and proposal positions;
    /// each attention/compressor step retains ordinary serial cache geometry.
    func verifyNativeMTPPackedRound(
        rows inputs: [ContinuousBatchNativeMTPVerifyInput]
    ) async throws -> [NativeMTPVerifiedRow] {
        guard !inputs.isEmpty else { return [] }
        guard inputs.count <= Self.maxDecodeRows,
              Set(inputs.map(\.requestID)).count == inputs.count,
              Set(inputs.map(\.packedRowIndex)) == Set(inputs.indices),
              inputs.allSatisfy({ $0.verifiedInputTokenCount == $0.proposalTokens.count + 1
                  && (1...6).contains($0.verifiedInputTokenCount) && $0.temperature == 0
                  && $0.committedKVTokenCount >= 0
                  && !$0.committedKVTokenCount.addingReportingOverflow($0.verifiedInputTokenCount).overflow
                  && $0.targetKVTokenCount == $0.committedKVTokenCount.addingReportingOverflow($0.verifiedInputTokenCount).partialValue })
        else { throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_invalid_verification_width") }
        return try await container.perform(nonSendable: inputs) { context, inputs in
            guard let model = context.model as? DeepseekV4Model, model.batchesExactly else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_exact_model_required")
            }
            var originals: [Row] = []
            for input in inputs {
                let hasPending = self.lock.withLock { self.nativeTransactions[input.requestID] != nil }
                guard !hasPending else {
                    throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_transaction_pending")
                }
                originals.append(try self.ownedRow(id: input.requestID,
                    offset: input.committedKVTokenCount, model: model))
            }
            let working = originals.map(\.caches)
            var snapshots = inputs.map { _ in [[KVCache]]() }
            var hiddenColumns = inputs.map { _ in [MLXArray]() }
            var sampledColumns = inputs.map { _ in [MLXArray]() }
            // The existing exact small-M route supports eight flattened
            // positions. Pack whole ragged rows without padding or clipping
            // their individual accepted prefixes.
            var groups: [[Int]] = []
            var group: [Int] = []
            var groupWidth = 0
            for index in inputs.indices {
                if groupWidth + inputs[index].verifiedInputTokenCount > Self.maxDecodeRows {
                    groups.append(group)
                    group = []
                    groupWidth = 0
                }
                group.append(index)
                groupWidth += inputs[index].verifiedInputTokenCount
            }
            if !group.isEmpty { groups.append(group) }
            for indices in groups {
                let verified = model.verifyBatchOutput(
                    indices.map { [inputs[$0].currentToken] + inputs[$0].proposalTokens },
                    rowCaches: indices.map { working[$0] })
                guard let hidden = verified.output.state?[mtpLastHiddenStatesKey] else {
                    throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_drafter_hidden_required")
                }
                let sampled = argMax(verified.output.logits[0, 0..., 0...], axis: -1).asType(.int32)
                for (batchIndex, index) in indices.enumerated() {
                    let offset = verified.rowOffsets[batchIndex]
                    snapshots[index] = verified.cachePrefixes[batchIndex]
                    for column in 0..<inputs[index].verifiedInputTokenCount {
                        let position = offset + column
                        sampledColumns[index].append(sampled[position..<(position + 1)])
                        hiddenColumns[index].append(hidden[0..., position..<(position + 1), 0...])
                    }
                }
            }
            let selections = concatenated(sampledColumns.flatMap { $0 }, axis: 0)
            let workingState: [MLXArray] = working.flatMap { $0.flatMap(\.state) }
            let snapshotState: [MLXArray] = snapshots.flatMap { prefixes in
                prefixes.flatMap { caches in caches.flatMap(\.state) }
            }
            let hiddenState: [MLXArray] = hiddenColumns.flatMap { $0 }
            eval([selections] + workingState + snapshotState + hiddenState)
            let selectedIDs = selections.asArray(Int32.self).map(Int.init)
            var cursor = 0
            var verified: [NativeMTPVerifiedRow] = []
            try self.lock.withLock {
                guard !self.cancelled, inputs.allSatisfy({ self.active.contains($0.requestID) }) else {
                    throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_row_retired")
                }
                for index in inputs.indices {
                    let input = inputs[index]
                    let top = Array(selectedIDs[cursor..<(cursor + input.verifiedInputTokenCount)])
                    self.nativeTransactions[input.requestID] = NativeTransaction(original: originals[index],
                        snapshots: snapshots[index], hidden: hiddenColumns[index],
                        proposalTokens: input.proposalTokens, targetTokenIDs: top)
                    cursor += input.verifiedInputTokenCount
                    verified.append(.init(schedulerRowID: input.requestID, packedRowIndex: input.packedRowIndex,
                        proposedTokenIDs: input.proposalTokens, targetTopTokenIDs: top))
                }
            }
            return verified.sorted { $0.packedRowIndex < $1.packedRowIndex }
        }
    }

    func finalizeNativeMTPPackedRound(rows inputs: [ContinuousBatchNativeMTPFinalizeInput]) async throws {
        guard !inputs.isEmpty else { return }
        try await container.perform(nonSendable: inputs) { context, inputs in
            guard let target = context.model as? DeepseekV4Model else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_model_required")
            }
            let transactions = self.lock.withLock { inputs.map { self.nativeTransactions[$0.requestID] } }
            guard Set(inputs.map(\.requestID)).count == inputs.count else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_duplicate_finalize")
            }
            for (input, transaction) in zip(inputs, transactions) {
                guard let transaction else {
                    if !input.shouldCommit { continue }
                    throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_transaction_missing")
                }
                guard (!input.shouldCommit || self.nativeMTPDrafterContainer == nil
                          || transaction.original.drafterState != nil),
                      input.proposalTokenCount == transaction.proposalTokens.count,
                      input.committedProposalTokenCount >= 0,
                      input.committedProposalTokenCount <= input.proposalTokenCount,
                      input.shouldCommit
                        ? (input.committedInputTokenCount == input.committedProposalTokenCount + 1
                            && input.committedInputTokenCount <= transaction.snapshots.count
                            && !input.acceptedTokenIDs.isEmpty)
                        : input.committedInputTokenCount == 0
                else { throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_invalid_finalize") }
                if input.shouldCommit {
                    var accepted = 0
                    while accepted < transaction.proposalTokens.count,
                          transaction.proposalTokens[accepted] == transaction.targetTokenIDs[accepted] {
                        accepted += 1
                    }
                    let candidates = Array(transaction.proposalTokens.prefix(accepted))
                        + [transaction.targetTokenIDs[accepted]]
                    guard input.acceptedTokenIDs == Array(candidates.prefix(input.acceptedTokenIDs.count)),
                          input.committedProposalTokenCount == min(input.acceptedTokenIDs.count, accepted) else {
                        throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_finalize_token_mismatch")
                    }
                } else {
                    guard input.acceptedTokenIDs.isEmpty, input.committedProposalTokenCount == 0 else {
                        throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_invalid_abort")
                    }
                }
            }
            let committing = inputs.indices.filter { inputs[$0].shouldCommit }
            var advancedStates: [MTPDrafterState]? = nil
            if !committing.isEmpty, let drafter = self.nativeMTPDrafterContainer {
                let rows = committing.map { index -> MTPPackedDrafterAdvanceRow in
                    let input = inputs[index]
                    let transaction = transactions[index]!
                    return .init(targetHidden: concatenated(Array(transaction.hidden.prefix(input.committedInputTokenCount)), axis: 1),
                        acceptedTokens: Array(transaction.proposalTokens.prefix(input.committedProposalTokenCount)),
                        finalToken: input.acceptedTokenIDs.last!, positionDeltas: nil,
                        state: transaction.original.drafterState!)
                }
                advancedStates = try await drafter.perform(nonSendable: (target, rows)) { context, values in
                    guard let model = context.model as? any MTPPackedStatefulDrafterModel else {
                        throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_packed_drafter_required")
                    }
                    let result = try model.advanceAndProposePacked(target: values.0, rows: values.1, sampler: ArgMaxSampler())
                    eval(result.states.flatMap { $0.cache.flatMap(\.state) }
                        + result.states.compactMap(\.proposalConfidence) + [result.proposals])
                    return result.states
                }
            }
            var staged: [(String, Row)] = []
            for (advanceIndex, index) in committing.enumerated() {
                let input = inputs[index]
                let transaction = transactions[index]!
                var row = transaction.original
                row.caches = transaction.snapshots[input.committedInputTokenCount - 1]
                row.tokenCount += input.committedInputTokenCount
                row.lastHidden = transaction.hidden[input.committedInputTokenCount - 1]
                if let advancedStates { row.drafterState = advancedStates[advanceIndex] }
                staged.append((input.requestID, row))
            }
            eval(staged.flatMap { $0.1.caches.flatMap(\.state) })
            let published = self.lock.withLock {
                for input in inputs { self.nativeTransactions.removeValue(forKey: input.requestID) }
                var published = Set<String>()
                for (id, row) in staged where !self.cancelled && self.active.contains(id) {
                    self.rows[id] = row
                    published.insert(id)
                }
                return published
            }
            #if DEBUG || MACPROVIDER_LAB_HARNESS
            let observer = self.lock.withLock { self.labRoundObserver }
            for input in inputs {
                observer?(input.requestID, input.proposalTokenCount,
                    published.contains(input.requestID) ? input.committedProposalTokenCount : 0)
            }
            #else
            _ = published
            #endif
        }
    }

    func commitTerminalKV(_ input: ContinuousBatchTerminalKVCommitInput) async throws {
        try await container.perform(nonSendable: input) { context, input in
            guard let model = context.model as? DeepseekV4Model else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_model_required")
            }
            guard model.batchesExactly else {
                throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_hisa_not_batch_exact")
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
        nativeTransactions.removeValue(forKey: requestID)
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
        nativeTransactions.removeAll()
        active.removeAll()
    }
}
