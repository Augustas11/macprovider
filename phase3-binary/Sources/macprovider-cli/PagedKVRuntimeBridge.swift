import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

/// SPEC-039 / SPEC-038 Increment 1 runtime bridge.
///
/// This backend is intentionally installable only after the attach gate has a
/// separately measured runtime identity. Production construction still passes
/// nil observation, so no buyer request reaches this path by default.
final class PagedKVSharedForwardBackend: ContinuousBatchSchedulerBackend, @unchecked Sendable {
    private struct RowState {
        var caches: [PagedKVCache]
        var state: LMOutput.State?
    }

    private let container: ModelContainer
    private let descriptor: PagedKVDescriptor
    private let layerCount: Int
    private let lock = NSLock()
    private var rows: [String: RowState] = [:]
    private var activeOperations = 0
    private var cancelRequested = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(container: ModelContainer, descriptor: PagedKVDescriptor, layerCount: Int) {
        self.container = container
        self.descriptor = descriptor
        self.layerCount = max(1, layerCount)
    }

    func prefill(rows inputs: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        return await container.perform(nonSendable: inputs) { context, inputs in
            var outputs: [ContinuousBatchPrefillOutput] = []
            outputs.reserveCapacity(inputs.count)
            for input in inputs {
                var state = self.rowState(for: input.requestID, binding: input.binding, initialOffset: input.committedKVTokenCount)
                if !input.promptTokens.isEmpty {
                    let prompt = MLXArray(input.promptTokens.map(Int32.init)).reshaped([1, input.promptTokens.count])
                    let text = LMInput.Text(tokens: prompt)
                    let output = withPreparedCache(state.caches, lengths: text.sequenceLengths) {
                        context.model(text, cache: state.caches, state: state.state)
                    }
                    eval(output.logits)
                    state.state = output.state
                }
                self.setRowState(state, for: input.requestID)
                outputs.append(ContinuousBatchPrefillOutput(requestID: input.requestID))
            }
            return outputs
        }
    }

    func decode(rows inputs: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        guard !inputs.isEmpty else { return [] }
        guard beginOperation() else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_backend_cancelled")
        }
        defer { endOperation() }
        let supportedInputs = inputs.filter(Self.supportsGreedySampling)
        var rowFailures = Set(inputs.map(\.requestID)).subtracting(supportedInputs.map(\.requestID))
        guard !supportedInputs.isEmpty else {
            return inputs.map { .rowFailure(requestID: $0.requestID) }
        }

        let decoded: [ContinuousBatchDecodeOutcome] = try await container.perform(nonSendable: supportedInputs) { context, supportedInputs in
            var rowStates = supportedInputs.map {
                self.rowState(
                    for: $0.requestID,
                    binding: $0.binding,
                    initialOffset: $0.committedKVTokenCount
                )
            }
            if supportedInputs.count > 1 && rowStates.contains(where: { $0.state != nil }) {
                return supportedInputs.map { ContinuousBatchDecodeOutcome.rowFailure(requestID: $0.requestID) }
            }
            let batchedCaches = try Self.batchedCaches(from: rowStates.map(\.caches))
            let tokenInput = MLXArray(supportedInputs.map { Int32($0.currentToken) }).reshaped([supportedInputs.count, 1])
            let text = LMInput.Text(tokens: tokenInput)
            let output = withPreparedCache(batchedCaches, lengths: text.sequenceLengths) {
                context.model(text, cache: batchedCaches, state: supportedInputs.count == 1 ? rowStates[0].state : nil)
            }
            let sampled = argMax(output.logits[0..., -1, 0...], axis: -1).asArray(Int.self)
            guard sampled.count == supportedInputs.count else {
                throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_logits_shape")
            }
            if supportedInputs.count == 1 {
                rowStates[0].state = output.state
            } else if output.state != nil {
                return supportedInputs.map { ContinuousBatchDecodeOutcome.rowFailure(requestID: $0.requestID) }
            }
            for (index, input) in supportedInputs.enumerated() {
                self.setRowState(rowStates[index], for: input.requestID)
            }
            return zip(supportedInputs, sampled).map { input, token in
                ContinuousBatchDecodeOutcome.output(ContinuousBatchDecodeOutput(
                    requestID: input.requestID,
                    token: token
                ))
            }
        }
        for outcome in decoded {
            if case .rowFailure(let requestID) = outcome {
                rowFailures.insert(requestID)
            }
        }
        let byID: [String: ContinuousBatchDecodeOutcome] = Dictionary(
            uniqueKeysWithValues: decoded.map { ($0.requestID, $0) }
        )
        return inputs.map { input in
            if rowFailures.contains(input.requestID) { return .rowFailure(requestID: input.requestID) }
            if let outcome = byID[input.requestID] { return outcome }
            return .rowFailure(requestID: input.requestID)
        }
    }

    func finish(requestID: String) {
        removeRowState(for: requestID)
    }

    func cancelInFlight() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            cancelRequested = true
            rows.removeAll()
            if activeOperations == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                cancellationWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func beginOperation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelRequested else { return false }
        activeOperations += 1
        return true
    }

    private func endOperation() {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        activeOperations = max(0, activeOperations - 1)
        if cancelRequested && activeOperations == 0 {
            waiters = cancellationWaiters
            cancellationWaiters.removeAll()
        } else {
            waiters = []
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func rowState(
        for requestID: String,
        binding: PagedKVStorageBinding,
        initialOffset: Int
    ) -> RowState {
        lock.lock()
        defer { lock.unlock() }
        if let existing = rows[requestID] {
            return existing
        }
        return RowState(
            caches: (0 ..< layerCount).map { _ in
                PagedKVCache(
                    descriptor: descriptor,
                    binding: binding,
                    initialOffset: initialOffset
                )
            },
            state: nil
        )
    }

    private func setRowState(_ state: RowState, for requestID: String) {
        lock.lock()
        if !cancelRequested {
            rows[requestID] = state
        }
        lock.unlock()
    }

    private func removeRowState(for requestID: String) {
        lock.lock()
        rows.removeValue(forKey: requestID)
        lock.unlock()
    }

    func retainedRowCountForTest() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rows.count
    }

    private static func supportsGreedySampling(_ input: ContinuousBatchDecodeInput) -> Bool {
        input.temperature == 0.0
            && input.topP == 1.0
            && input.presencePenalty == 0.0
            && input.frequencyPenalty == 0.0
    }

    private static func batchedCaches(from rowCaches: [[PagedKVCache]]) throws -> [KVCache] {
        guard let layerCount = rowCaches.first?.count,
              rowCaches.allSatisfy({ $0.count == layerCount })
        else {
            throw ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
        }
        return (0 ..< layerCount).map { layerIndex in
            PagedKVBatchLayerCache(rowCaches: rowCaches.map { $0[layerIndex] })
        }
    }
}

private final class PagedKVBatchLayerCache: KVCache, @unchecked Sendable {
    private let rowCaches: [PagedKVCache]
    private var preparedLengths: [Int]?

    init(rowCaches: [PagedKVCache]) {
        self.rowCaches = rowCaches
    }

    var offset: Int {
        rowCaches.map(\.offset).min() ?? 0
    }

    var ropeOffset: RoPEOffset {
        .batch(MLXArray(rowCaches.map { Int32($0.offset) }))
    }

    var maxSize: Int? {
        rowCaches.compactMap(\.maxSize).min()
    }

    func innerState() -> [MLXArray] {
        []
    }

    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        guard keys.ndim == 4,
              values.ndim == 4,
              keys.dim(0) == rowCaches.count,
              values.dim(0) == rowCaches.count
        else {
            return (keys, values)
        }
        var updatedKeys: [MLXArray] = []
        var updatedValues: [MLXArray] = []
        updatedKeys.reserveCapacity(rowCaches.count)
        updatedValues.reserveCapacity(rowCaches.count)
        for (rowIndex, cache) in rowCaches.enumerated() {
            let keySlice = keys[rowIndex ..< rowIndex + 1, 0..., 0..., 0...]
            let valueSlice = values[rowIndex ..< rowIndex + 1, 0..., 0..., 0...]
            let updated = cache.update(keys: keySlice, values: valueSlice)
            updatedKeys.append(updated.0)
            updatedValues.append(updated.1)
        }
        return (
            Self.concatenatePadded(updatedKeys, fallback: keys),
            Self.concatenatePadded(updatedValues, fallback: values)
        )
    }

    var state: [MLXArray] {
        get { [] }
        set { _ = newValue }
    }

    var metaState: [String] {
        get { ["macprovider_paged_kv_batch_v1"] }
        set { _ = newValue }
    }

    var isTrimmable: Bool {
        rowCaches.allSatisfy(\.isTrimmable)
    }

    @discardableResult
    func trim(_ n: Int) -> Int {
        rowCaches.map { $0.trim(n) }.min() ?? 0
    }

    func makeMask(
        n: Int,
        windowSize: Int?,
        returnArray: Bool
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        let lengths = rowCaches.map(\.offset)
        if n == 1, Set(lengths).count <= 1 { return .none }
        return .array(createCausalMask(
            n: n,
            offset: lengths.max() ?? offset,
            windowSize: windowSize,
            lengths: MLXArray(lengths.map(Int32.init))
        ))
    }

    func prepare(lengths: [Int]?) {
        preparedLengths = lengths
    }

    func prepare(lengths: MLXArray?) {
        preparedLengths = lengths?.asArray(Int.self)
    }

    func finalize() {
        preparedLengths = nil
    }

    func copy() -> any KVCache {
        PagedKVBatchLayerCache(rowCaches: rowCaches.map { $0.concreteCopy() })
    }

    private static func concatenatePadded(_ arrays: [MLXArray], fallback: MLXArray) -> MLXArray {
        guard let first = arrays.first,
              arrays.allSatisfy({
                  $0.ndim == 4
                      && $0.dim(0) == first.dim(0)
                      && $0.dim(1) == first.dim(1)
                      && $0.dim(3) == first.dim(3)
                      && $0.dtype == first.dtype
              })
        else {
            return fallback
        }
        let maxSequenceLength = arrays.map { $0.dim(2) }.max() ?? 0
        let padded = arrays.map { array -> MLXArray in
            let padTokens = maxSequenceLength - array.dim(2)
            guard padTokens > 0 else { return array }
            let pad = MLXArray.zeros([array.dim(0), array.dim(1), padTokens, array.dim(3)], dtype: array.dtype)
            return concatenated([array, pad], axis: 2)
        }
        return concatenated(padded, axis: 0)
    }
}
