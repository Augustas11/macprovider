import Foundation
import MLX
import MLXLMCommon
import MLXNN
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

final class PagedKVRuntimeMixedCacheTests: XCTestCase {
    func testMixedCacheIsolationProbeCoversLockstepWindowBeforePeerRejoin() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let recorder = MixedCacheRecorder()
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: "mlx-community/Qwen3.6-Test"),
            model: MixedCacheFakeModel(
                recorder: recorder,
                nextTokenByInput: [
                    1: 4,
                    4: 5,
                    5: 6,
                    12: 7,
                    7: 8,
                ]
            ),
            processor: MixedCacheUserInputProcessor(),
            tokenizer: MixedCacheTokenizer()
        ))

        let result = await PagedKVRuntimeParityProbe.runMoEInputIsolationProbe(
            container: container,
            blockSizeTokens: 4,
            maxPhysicalBlocks: 16,
            poolEpoch: 1,
            layerCount: 2,
            promptA: [0, 1],
            promptB: [11, 12],
            cacheKinds: [.recurrentMamba, .pagedAttention]
        )

        XCTAssertTrue(result.proven)
        XCTAssertEqual(result.rowsDecodedInSharedForward, 2)
        XCTAssertEqual(result.rowFailures, 0)
        XCTAssertEqual(result.crossRowDivergences, 0)
        XCTAssertTrue(result.challengeDistinguishing)
        XCTAssertGreaterThanOrEqual(recorder.forwardBatchSizes().filter { $0 == 2 }.count, 2)
        XCTAssertTrue(
            recorder.previousMambaSnapshots().contains([204, 211]),
            "peer-rejoin decode must retain row A's post-window state while admitting the rejoined row B state"
        )
    }

    func testMixedMambaAndPagedAttentionCachesShareForwardAndRetainRowState() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let recorder = MixedCacheRecorder()
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: "mlx-community/Qwen3.6-Test"),
            model: MixedCacheFakeModel(
                recorder: recorder,
                nextTokenByInput: [
                    1: 4,
                    4: 5,
                    5: 6,
                    12: 7,
                    7: 8,
                ]
            ),
            processor: MixedCacheUserInputProcessor(),
            tokenizer: MixedCacheTokenizer()
        ))
        let backend = PagedKVSharedForwardBackend(
            container: container,
            blockSizeTokens: 4,
            maxPhysicalBlocks: 16,
            poolEpoch: 1,
            layerCount: 2,
            cacheKinds: [.recurrentMamba, .pagedAttention],
            compiledDecode: true
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)

        let aHandle = try await allocator.allocate(conversationKey: "row-a", maxTokens: 8)
        let bHandle = try await allocator.allocate(conversationKey: "row-b", maxTokens: 8)

        let first = try await backend.decode(rows: [
            try await decodeInput(
                requestID: "row-a",
                currentToken: 1,
                handle: aHandle,
                allocator: allocator,
                committedKVTokenCount: 0
            ),
            try await decodeInput(
                requestID: "row-b",
                currentToken: 12,
                handle: bHandle,
                allocator: allocator,
                committedKVTokenCount: 0
            ),
        ])
        try await allocator.endDecodeStep(aHandle)
        try await allocator.endDecodeStep(bHandle)
        XCTAssertEqual(tokens(from: first), ["row-a": 4, "row-b": 7])

        let second = try await backend.decode(rows: [
            try await decodeInput(
                requestID: "row-a",
                currentToken: 4,
                handle: aHandle,
                allocator: allocator,
                committedKVTokenCount: 1
            ),
            try await decodeInput(
                requestID: "row-b",
                currentToken: 7,
                handle: bHandle,
                allocator: allocator,
                committedKVTokenCount: 1
            ),
        ])
        try await allocator.endDecodeStep(aHandle)
        try await allocator.endDecodeStep(bHandle)
        XCTAssertEqual(tokens(from: second), ["row-a": 5, "row-b": 8])
        XCTAssertTrue(recorder.sawMambaBatchSize(2))
        XCTAssertTrue(recorder.sawPagedAttentionBatchSize(2))
        XCTAssertGreaterThanOrEqual(recorder.forwardBatchSizes().filter { $0 == 2 }.count, 2)
        XCTAssertTrue(
            recorder.previousMambaSnapshots().contains([201, 212]),
            "second two-row decode must see the distinct Mamba state split from the first decode"
        )
        XCTAssertFalse(backend.lockstepInnerStateNonEmptyForTest(), "mixed layouts must not enter compiled KV-only decode")

        backend.finish(requestID: "row-b")
        let lone = try await backend.decode(rows: [
            try await decodeInput(
                requestID: "row-a",
                currentToken: 5,
                handle: aHandle,
                allocator: allocator,
                committedKVTokenCount: 2
            ),
        ])
        try await allocator.endDecodeStep(aHandle)
        XCTAssertEqual(tokens(from: lone), ["row-a": 6])
        XCTAssertTrue(
            recorder.previousMambaSnapshots().contains([204]),
            "single surviving row must keep its own recurrent Mamba state after the peer row leaves"
        )

        let cHandle = try await allocator.allocate(conversationKey: "row-c", maxTokens: 8)
        let joined = try await backend.decode(rows: [
            try await decodeInput(
                requestID: "row-a",
                currentToken: 6,
                handle: aHandle,
                allocator: allocator,
                committedKVTokenCount: 3
            ),
            try await decodeInput(
                requestID: "row-c",
                currentToken: 1,
                handle: cHandle,
                allocator: allocator,
                committedKVTokenCount: 0
            ),
        ])
        try await allocator.endDecodeStep(aHandle)
        try await allocator.endDecodeStep(cHandle)
        XCTAssertEqual(tokens(from: joined), ["row-a": 6, "row-c": 4])
        XCTAssertTrue(
            recorder.previousMambaSnapshots().contains([205, 0]),
            "a one-token joining row must start with zero recurrent state without disturbing its peer"
        )
    }

    func testHybridRowSnapshotsRecurrentStateAndMaterializesSerialCache() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: "mlx-community/Qwen3.6-Test"),
            model: MixedCacheFakeModel(recorder: MixedCacheRecorder(), nextTokenByInput: [:], attentionDType: .float16),
            processor: MixedCacheUserInputProcessor(),
            tokenizer: MixedCacheTokenizer()
        ))
        let backend = PagedKVSharedForwardBackend(
            container: container,
            blockSizeTokens: 4,
            maxPhysicalBlocks: 16,
            poolEpoch: 1,
            layerCount: 2,
            cacheKinds: [.recurrentMamba, .pagedAttention]
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let handle = try await allocator.allocate(conversationKey: "row-a", maxTokens: 8)

        func prefill(_ tokens: [Int], from offset: Int) async throws {
            _ = try await allocator.extend(handle, by: tokens.count)
            let binding = try await allocator.binding(for: handle)
            _ = try await backend.prefill(rows: [ContinuousBatchPrefillInput(
                requestID: "row-a",
                promptTokens: tokens,
                binding: binding,
                promptTokenOffset: offset,
                committedKVTokenCount: offset,
                targetKVTokenCount: offset + tokens.count,
                isFinalChunk: false
            )])
        }

        try await prefill([1, 2, 3], from: 0)
        let snapshot = await backend.snapshotRecurrentState(requestID: "row-a", tokenCount: 3)
        let checkpoint = try XCTUnwrap(snapshot)
        try await prefill([4, 5], from: 3)

        XCTAssertEqual(checkpoint.tokenCount, 3)
        XCTAssertEqual(Array(checkpoint.states.keys), [0], "only the recurrent layer is snapshotted")
        XCTAssertEqual(checkpoint.states[0]?.first?.asArray(Float.self), [201, 202, 203], "later prefill must not alias the snapshot")

        let binding = try await allocator.binding(for: handle)
        let materialized = try await backend.materializeSerialConversationCache(
            requestID: "row-a",
            binding: binding,
            tokenCount: 4,
            recurrentCheckpoints: [checkpoint]
        )
        let serial = try XCTUnwrap(materialized)
        XCTAssertEqual(serial.tokenCount, 4)
        XCTAssertEqual(serial.recurrentCheckpoints.map(\.tokenCount), [3])
        XCTAssertTrue(serial.layers[0] is MambaCache)
        XCTAssertTrue(serial.layers[0].state.isEmpty, "reuse always restores a checkpoint")
        let attention = try XCTUnwrap(serial.layers[1] as? KVCacheSimple)
        XCTAssertEqual(attention.offset, 4, "trimmed to the covered token count")
        XCTAssertEqual(attention.state[0].asType(.float32).asArray(Float.self), [1, 2, 3, 4])

        let pagedOnly = PagedKVSharedForwardBackend(
            container: container,
            blockSizeTokens: 4,
            maxPhysicalBlocks: 16,
            poolEpoch: 1,
            layerCount: 2
        )
        let none = await pagedOnly.snapshotRecurrentState(requestID: "row-a", tokenCount: 3)
        XCTAssertNil(none)
        let noneSerial = try await pagedOnly.materializeSerialConversationCache(
            requestID: "row-a", binding: binding, tokenCount: 4, recurrentCheckpoints: [checkpoint])
        XCTAssertNil(noneSerial)
    }

    /// SPEC-038 AC-26 hybrid cached turn: a retained handoff installs its paged
    /// attention layers plus recurrent layers restored from the checkpoint at
    /// exactly the handoff length, and refuses anything else.
    func testHybridRetainedInstallRestoresRecurrentStateFromCheckpoint() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: "mlx-community/Qwen3.6-Test"),
            model: MixedCacheFakeModel(recorder: MixedCacheRecorder(), nextTokenByInput: [:], attentionDType: .float16),
            processor: MixedCacheUserInputProcessor(),
            tokenizer: MixedCacheTokenizer()
        ))
        let bridge = PagedKVRuntimeContiguousCacheBridge()
        let backend = PagedKVSharedForwardBackend(
            container: container,
            blockSizeTokens: 4,
            maxPhysicalBlocks: 16,
            poolEpoch: 1,
            layerCount: 2,
            cacheKinds: [.recurrentMamba, .pagedAttention],
            contiguousCacheBridge: bridge
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16, contiguousCacheBridge: bridge)
        let handle = try await allocator.allocate(conversationKey: "conv", maxTokens: 8)

        func prefill(_ tokens: [Int], from offset: Int) async throws {
            _ = try await allocator.extend(handle, by: tokens.count)
            let binding = try await allocator.binding(for: handle)
            _ = try await backend.prefill(rows: [ContinuousBatchPrefillInput(
                requestID: "turn-1",
                promptTokens: tokens,
                binding: binding,
                promptTokenOffset: offset,
                committedKVTokenCount: offset,
                targetKVTokenCount: offset + tokens.count,
                isFinalChunk: false
            )])
        }

        try await prefill([1, 2, 3], from: 0)
        let snapshot = await backend.snapshotRecurrentState(requestID: "turn-1", tokenCount: 3)
        let checkpoint = try XCTUnwrap(snapshot)
        try await prefill([4, 5], from: 3)
        let retained = try await allocator.retain(handle)
        backend.finish(requestID: "turn-1")

        let reattached = try await allocator.reattach(retained, conversationKey: "conv", trimToLogicalTokens: 3)
        let binding = try await allocator.binding(for: reattached)
        let handoff = try bridge.reattachPagedKVCache(handle: reattached, table: binding.currentTable)
        XCTAssertEqual(handoff.logicalTokenCount, 3)

        for invalid in [nil, RecurrentStateCheckpoint(tokenCount: 2, states: checkpoint.states)] {
            do {
                try await backend.installRetainedPagedKVCache(
                    requestID: "turn-2", handoff: handoff, binding: binding, recurrentCheckpoint: invalid)
                XCTFail("a hybrid install needs a checkpoint at exactly the handoff length")
            } catch ContinuousBatchSchedulerError.unsupported(let reason) {
                XCTAssertEqual(reason, "continuous_batching_retained_hybrid_cache_unavailable")
            }
        }

        try await backend.installRetainedPagedKVCache(
            requestID: "turn-2", handoff: handoff, binding: binding, recurrentCheckpoint: checkpoint)
        let restoredSnapshot = await backend.snapshotRecurrentState(requestID: "turn-2", tokenCount: 3)
        let restored = try XCTUnwrap(restoredSnapshot)
        XCTAssertEqual(restored.states[0]?.first?.asArray(Float.self), [201, 202, 203], "state at the checkpoint, not after it")

        let pagedOnly = PagedKVSharedForwardBackend(
            container: container,
            blockSizeTokens: 4,
            maxPhysicalBlocks: 16,
            poolEpoch: 1,
            layerCount: 2
        )
        do {
            try await pagedOnly.installRetainedPagedKVCache(
                requestID: "turn-2", handoff: handoff, binding: binding, recurrentCheckpoint: checkpoint)
            XCTFail("a non-hybrid backend must refuse a recurrent checkpoint")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "continuous_batching_retained_hybrid_cache_unavailable")
        }
        backend.finish(requestID: "turn-2")
        try await allocator.release(reattached)
    }

    private func decodeInput(
        requestID: String,
        currentToken: Int,
        handle: PagedKVBlockTableHandle,
        allocator: PagedKVBlockAllocator,
        committedKVTokenCount: Int
    ) async throws -> ContinuousBatchDecodeInput {
        _ = try await allocator.extend(handle, by: 1)
        try await allocator.beginDecodeStep(handle)
        let binding = try await allocator.binding(for: handle)
        return ContinuousBatchDecodeInput(
            requestID: requestID,
            currentToken: currentToken,
            generatedTokens: [],
            promptTokens: [currentToken],
            samplerSeed: 0,
            temperature: 0.0,
            topP: 1.0,
            presencePenalty: 0.0,
            frequencyPenalty: 0.0,
            binding: binding,
            blockTable: binding.currentTable,
            committedKVTokenCount: committedKVTokenCount,
            targetKVTokenCount: committedKVTokenCount + 1,
            samplerStep: 0
        )
    }

    private func tokens(from outcomes: [ContinuousBatchDecodeOutcome]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: outcomes.compactMap { outcome in
            guard case .output(let output) = outcome else { return nil }
            return (output.requestID, output.token)
        })
    }
}

private final class MixedCacheFakeModel: Module, LanguageModel, KVCacheDimensionProvider {
    let kvHeads = [1, 1]
    private let recorder: MixedCacheRecorder
    private let nextTokenByInput: [Int: Int]
    private let vocabularySize = 32
    private let attentionDType: DType

    init(recorder: MixedCacheRecorder, nextTokenByInput: [Int: Int], attentionDType: DType = .float32) {
        self.recorder = recorder
        self.nextTokenByInput = nextTokenByInput
        self.attentionDType = attentionDType
        super.init()
    }

    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        let batch = input.tokens.dim(0)
        let sequenceLength = input.tokens.dim(1)
        let flatTokens = input.tokens.asArray(Int.self)
        recorder.recordForwardBatch(batch)

        if let cache {
            if let mamba = cache.first as? MambaCache {
                recorder.recordMambaBatch(batch)
                if let previous = mamba[0], previous.ndim >= 1 {
                    eval(previous)
                    recorder.recordPreviousMambaState(previous.asArray(Float.self))
                }
                let stateValues = flatTokens.map { Float($0 + 200) }
                mamba[0] = MLXArray(stateValues, [batch, sequenceLength, 1])
                mamba[1] = MLXArray(stateValues.map { $0 + 1 }, [batch, sequenceLength, 1])
            } else {
                recorder.recordBadLayout()
            }

            if cache.count > 1 {
                let keys = MLXArray(flatTokens.map(Float.init), [batch, 1, sequenceLength, 1]).asType(attentionDType)
                let values = MLXArray(flatTokens.map { Float($0 + 100) }, [batch, 1, sequenceLength, 1]).asType(attentionDType)
                let updated = cache[1].update(keys: keys, values: values)
                eval(updated.0, updated.1)
                recorder.recordPagedAttentionBatch(updated.0.dim(0))
            } else {
                recorder.recordBadLayout()
            }
        }

        var logits = Array(repeating: Float(-1_000), count: batch * sequenceLength * vocabularySize)
        for row in 0 ..< batch {
            for position in 0 ..< sequenceLength {
                let token = flatTokens[row * sequenceLength + position]
                let next = nextTokenByInput[token] ?? token
                logits[(row * sequenceLength + position) * vocabularySize + next] = 1_000
            }
        }
        return LMOutput(logits: MLXArray(logits, [batch, sequenceLength, vocabularySize]))
    }
}

private final class MixedCacheRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var forwardBatches: [Int] = []
    private var mambaBatches: [Int] = []
    private var pagedAttentionBatches: [Int] = []
    private var previousStates: [[Float]] = []
    private var badLayoutCount = 0

    func recordForwardBatch(_ value: Int) {
        lock.lock()
        forwardBatches.append(value)
        lock.unlock()
    }

    func recordMambaBatch(_ value: Int) {
        lock.lock()
        mambaBatches.append(value)
        lock.unlock()
    }

    func recordPagedAttentionBatch(_ value: Int) {
        lock.lock()
        pagedAttentionBatches.append(value)
        lock.unlock()
    }

    func recordPreviousMambaState(_ values: [Float]) {
        lock.lock()
        previousStates.append(values)
        lock.unlock()
    }

    func recordBadLayout() {
        lock.lock()
        badLayoutCount += 1
        lock.unlock()
    }

    func forwardBatchSizes() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return forwardBatches
    }

    func sawMambaBatchSize(_ value: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return badLayoutCount == 0 && mambaBatches.contains(value)
    }

    func sawPagedAttentionBatchSize(_ value: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return badLayoutCount == 0 && pagedAttentionBatches.contains(value)
    }

    func previousMambaSnapshots() -> [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        return previousStates
    }
}

private struct MixedCacheTokenizer: Tokenizer {
    let bosToken: String? = nil
    let eosToken: String? = nil
    let unknownToken: String? = nil

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        text.split(separator: " ").compactMap { Int($0) }
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map(String.init).joined(separator: " ")
    }

    func convertTokenToId(_ token: String) -> Int? {
        Int(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        String(id)
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        []
    }
}

private struct MixedCacheUserInputProcessor: UserInputProcessor {
    func prepare(input: UserInput) throws -> LMInput {
        LMInput(text: .init(tokens: MLXArray([Int32]()).reshaped([1, 0])))
    }
}
