import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-038 FR-CB2: a hybrid (gated-delta recurrent + attention) model decodes
/// in the same 16-step lockstep window as KV-only models. These tests prove the
/// window exact against one-step windows with a tiny random-weight Qwen3.5
/// hybrid, so they run in CI without weights: fixed batch with prompts past the
/// 512-token prefill chunk, a stop inside a window (its recurrent checkpoint),
/// and rows joining and leaving between windows. The served-artifact proof is
/// `msb-throughput --scenario hybrid-window` (scripts/lab/cb-studio).
///
/// The real model is used throughout, so no `LanguageModel` fake is involved.
final class HybridDecodeWindowExactnessTests: XCTestCase {
    private static let blockSizeTokens = 16
    private static let maxPhysicalBlocks = 1024
    private static let chunkTokens = ContinuousBatchSchedulerConfiguration.defaultPromptChunkTokens
    private static let window = ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow

    /// Two-layer hybrid (one gated-delta layer, one full-attention layer), the
    /// `PagedKVRuntimeBridgeTests` tiny config with a wider vocabulary and
    /// position range so >512-token prompts decode varied tokens. Untied
    /// embeddings: with tied ones, random weights on MLX 0.32 repeat each
    /// row's first token, which leaves the stop tests no stop to place.
    private static let tinyQwen35HybridConfiguration = """
        {
          "model_type": "qwen3_5_text",
          "hidden_size": 16,
          "num_hidden_layers": 2,
          "intermediate_size": 32,
          "num_attention_heads": 2,
          "num_key_value_heads": 1,
          "head_dim": 8,
          "linear_num_value_heads": 2,
          "linear_num_key_heads": 1,
          "linear_key_head_dim": 32,
          "linear_value_head_dim": 32,
          "linear_conv_kernel_dim": 2,
          "rms_norm_eps": 1e-6,
          "vocab_size": 32,
          "rope_theta": 100000.0,
          "partial_rotary_factor": 0.25,
          "max_position_embeddings": 4096,
          "tie_word_embeddings": false,
          "attention_bias": false,
          "full_attention_interval": 2,
          "mtp_num_hidden_layers": 1,
          "mtp_use_dedicated_embeddings": false,
          "rope_parameters": {
            "type": "default",
            "rope_theta": 100000.0,
            "partial_rotary_factor": 0.25
          }
        }
        """

    func testServePathUsesTheSixteenStepWindowForHybridModels() {
        XCTAssertEqual(
            ModelRuntime.servePathDecodeLockstepWindow(cacheKinds: [.recurrentMamba, .pagedAttention]),
            Self.window
        )
        XCTAssertEqual(Self.window, 16)
    }

    func testStopSequenceMatchSpansHistoryAndWindow() {
        let match = PagedKVSharedForwardBackend.endsWithStopSequence
        XCTAssertTrue(match([1, 2], [3], [[3]]))
        XCTAssertTrue(match([1, 2], [3], [[2, 3]]))
        XCTAssertTrue(match([1, 2], [3, 4], [[1, 2, 3, 4]]))
        XCTAssertFalse(match([1, 2], [3], [[1, 3]]))
        XCTAssertFalse(match([], [3], [[2, 3]]))
        XCTAssertFalse(match([1, 2], [3], [[]]))
        XCTAssertFalse(match([1, 2], [3], []))
    }

    /// Fixed batch of ragged prompts, every one past the 512-token chunk (one
    /// past 1024): greedy tokens and the final recurrent state are the same
    /// whether the rows decode in 16-step windows or one step at a time.
    func testHybridWindowSixteenMatchesWindowOneOnFixedBatchPastPrefillChunk() async throws {
        try requireMetal()
        let target = try Self.tinyQwen35()
        let prompts = [513, 600, 777, 1030].enumerated().map { Self.tinyPrompt(length: $1, salt: $0) }
        let decodeTokens = 3 * Self.window

        let reference = try await Self.runFixedBatch(target: target, prompts: prompts, decodeTokens: decodeTokens, window: 1)
        let candidate = try await Self.runFixedBatch(
            target: target, prompts: prompts, decodeTokens: decodeTokens, window: Self.window
        )
        for row in prompts.indices {
            XCTAssertEqual(reference.tokens[row].count, decodeTokens + 1, "row \(row)")
            XCTAssertEqual(candidate.tokens[row], reference.tokens[row], "row \(row) diverged at window \(Self.window)")
            try Self.assertSameRecurrentState(
                candidate.finalStates[row], reference.finalStates[row], "row \(row) final recurrent state"
            )
        }
        // The batch did not degenerate into one repeated token.
        XCTAssertGreaterThan(Set(reference.tokens.flatMap { $0 }).count, 2)
    }

    /// A row whose stop sequence matches mid-window keeps decoding to the end
    /// of the window, so its recurrent state ends past the stop. The backend
    /// must still hand back the state at exactly the stop boundary (model
    /// stop: through the stop step; request stop: one step later), the window
    /// end state at the window end, and nothing for any other length.
    func testStopInsideAWindowCheckpointsTheRecurrentStateAtTheStopBoundary() async throws {
        try requireMetal()
        let target = try Self.tinyQwen35()
        let prompts = [520, 641, 700].enumerated().map { Self.tinyPrompt(length: $1, salt: 10 + $0) }
        let steps = Self.window

        // Window-1 reference: the recurrent state after every step.
        let reference = try await Self.prefill(target: target, prompts: prompts)
        var referenceStates: [[RecurrentStateCheckpoint]] = prompts.map { _ in [] }
        for _ in 0 ..< steps {
            try await reference.decode(steps: 1)
            for row in prompts.indices {
                let state = await reference.backend.snapshotRecurrentState(
                    requestID: reference.id(row),
                    tokenCount: reference.committed(row)
                )
                referenceStates[row].append(try XCTUnwrap(state))
            }
        }

        // Stops for rows 0 and 1 at different steps inside the window; row 2
        // has none.
        let windowTokens = prompts.indices.map { Array(reference.generated[$0].dropFirst()) }
        let history = prompts.indices.map { [reference.generated[$0][0]] }
        let stop0 = try XCTUnwrap(Self.firstStop(history: history[0], window: windowTokens[0], from: 3))
        let stop1 = try XCTUnwrap(Self.firstStop(history: history[1], window: windowTokens[1], from: stop0.step + 2))

        let candidate = try await Self.prefill(target: target, prompts: prompts)
        try await candidate.decode(steps: steps, stops: [[stop0.sequence], [stop1.sequence], []])
        XCTAssertEqual(candidate.generated, reference.generated, "a stop must not change the window's tokens")

        let start = prompts.map(\.count)
        for (row, stop) in [(0, stop0), (1, stop1)] {
            let id = candidate.id(row)
            for offset in [0, 1] {
                let tokenCount = start[row] + stop.step + 1 + offset
                let snapshot = await candidate.backend.snapshotRecurrentState(requestID: id, tokenCount: tokenCount)
                let checkpoint = try XCTUnwrap(snapshot, "row \(row) has no checkpoint at \(tokenCount)")
                XCTAssertEqual(checkpoint.tokenCount, tokenCount)
                try Self.assertSameRecurrentState(
                    checkpoint, referenceStates[row][stop.step + offset], "row \(row) checkpoint at \(tokenCount)"
                )
            }
            if stop.step + 3 < steps {
                let unrecorded = await candidate.backend.snapshotRecurrentState(
                    requestID: id, tokenCount: start[row] + stop.step + 3
                )
                XCTAssertNil(unrecorded, "row \(row) must fail closed between its stop and the window end")
            }
            // The window end still reports the state the row actually holds.
            let endSnapshot = await candidate.backend.snapshotRecurrentState(
                requestID: id, tokenCount: start[row] + steps
            )
            let end = try XCTUnwrap(endSnapshot)
            try Self.assertSameRecurrentState(end, referenceStates[row][steps - 1], "row \(row) window end")
            // Sanity: the stop-step state is not the window-end state, so a
            // mislabeled window-end snapshot could not pass the checks above.
            XCTAssertFalse(
                try Self.recurrentStatesClose(referenceStates[row][stop.step], referenceStates[row][steps - 1]),
                "row \(row) state did not move between its stop and the window end"
            )
        }
        let noStop = await candidate.backend.snapshotRecurrentState(
            requestID: candidate.id(2), tokenCount: start[2] + 4
        )
        XCTAssertNil(noStop, "a row without a stop has no mid-window checkpoint")
    }

    /// End to end through the scheduler: a keyed hybrid row that hits a model
    /// stop inside a window publishes the same serial conversation-cache entry
    /// (tokens, attention KV and reply-end recurrent checkpoint) at window 16
    /// as at window 1.
    func testKeyedStopMidWindowPublishesTheWindowOneConversationCache() async throws {
        try requireMetal()
        let target = try Self.tinyQwen35(dtype: .bfloat16)
        let prompt = Self.tinyPrompt(length: 600, salt: 31)
        let budget = 40

        let probe = try await Self.runScheduler(
            target: target, maxDecodeLockstepWindow: 1,
            requests: [Self.request("probe", prompt, budget)]
        )
        let probeTokens = try XCTUnwrap(probe["probe"]).generatedTokens
        // Stop on a token first sampled at step 4..9 of the first window
        // (generated[0] comes from prefill).
        let stop = try XCTUnwrap(Self.firstStop(
            history: [probeTokens[0]], window: Array(probeTokens.dropFirst()), from: 4, length: 1
        ))
        XCTAssertLessThan(stop.step, Self.window - 1, "the stop must land inside the first window")
        let keyed = Self.request(
            "keyed", prompt, budget,
            conversationKey: "conv:hybrid-window",
            stopTokenSequences: [stop.sequence],
            modelStopTokenIDs: stop.sequence,
            modelHasRecurrentLayers: true
        )

        let oneRun = try await Self.runScheduler(target: target, maxDecodeLockstepWindow: 1, requests: [keyed])
        let sixteenRun = try await Self.runScheduler(
            target: target, maxDecodeLockstepWindow: Self.window, requests: [keyed]
        )
        let one = try XCTUnwrap(oneRun["keyed"])
        let sixteen = try XCTUnwrap(sixteenRun["keyed"])
        XCTAssertEqual(one.terminalStatus, .stop)
        XCTAssertEqual(sixteen.terminalStatus, .stop)
        XCTAssertEqual(sixteen.generatedTokens, one.generatedTokens)
        XCTAssertEqual(one.generatedTokens, Array(probeTokens.prefix(stop.step + 2)))

        let oneCache = try XCTUnwrap(one.serialConversationCache, "window 1 published no entry")
        let sixteenCache = try XCTUnwrap(sixteen.serialConversationCache, "window 16 published no entry")
        XCTAssertEqual(sixteenCache.tokenCount, oneCache.tokenCount)
        XCTAssertEqual(sixteenCache.layers.count, oneCache.layers.count)
        for (index, (lhs, rhs)) in zip(sixteenCache.layers, oneCache.layers).enumerated() {
            XCTAssertEqual(lhs.state.count, rhs.state.count, "layer \(index)")
            for (a, b) in zip(lhs.state, rhs.state) {
                XCTAssertTrue(allClose(a, b, rtol: 1e-2, atol: 1e-2).item(Bool.self), "layer \(index) KV differs")
            }
        }
        XCTAssertEqual(
            sixteenCache.recurrentCheckpoints.map(\.tokenCount),
            oneCache.recurrentCheckpoints.map(\.tokenCount)
        )
        XCTAssertTrue(sixteenCache.recurrentCheckpoints.contains { $0.tokenCount == oneCache.tokenCount })
        for (lhs, rhs) in zip(sixteenCache.recurrentCheckpoints, oneCache.recurrentCheckpoints) {
            try Self.assertSameRecurrentState(lhs, rhs, "checkpoint \(lhs.tokenCount)", tolerance: 1e-2)
        }
    }

    /// Rows join and leave only at window boundaries: one row leaves on its
    /// output budget, one stops mid-window, one joins while the first cohort
    /// decodes. Every row emits the same tokens at window 16 as at window 1.
    func testRowsJoiningAndLeavingBetweenWindowsMatchWindowOne() async throws {
        try requireMetal()
        let target = try Self.tinyQwen35()
        let prompts: [String: [Int]] = [
            "long": Self.tinyPrompt(length: 530, salt: 41),
            "leaves": Self.tinyPrompt(length: 610, salt: 42),
            "stops": Self.tinyPrompt(length: 700, salt: 43),
            "joiner": Self.tinyPrompt(length: 545, salt: 44),
        ]
        let budgets = ["long": 40, "leaves": 12, "stops": 40, "joiner": 24]

        let probe = try await Self.runScheduler(
            target: target, maxDecodeLockstepWindow: 1,
            requests: [Self.request("stops", prompts["stops"]!, budgets["stops"]!)]
        )
        let probeTokens = try XCTUnwrap(probe["stops"]).generatedTokens
        let stop = try XCTUnwrap(Self.firstStop(
            history: [probeTokens[0]], window: Array(probeTokens.dropFirst()), from: 6, length: 1
        ))

        func run(window: Int) async throws -> [String: ContinuousBatchSchedulerResult] {
            let tiny = Self.schedulerBackend(target: target)
            let scheduler = try Self.makeScheduler(backend: tiny, maxDecodeLockstepWindow: window)
            let joiner = HybridWindowTaskBox()
            let long = Task {
                try await scheduler.submit(Self.request("long", prompts["long"]!, budgets["long"]!)) { event in
                    if event.tokenIndex == 5 {
                        joiner.start {
                            try await scheduler.submit(Self.request("joiner", prompts["joiner"]!, budgets["joiner"]!))
                        }
                    }
                }
            }
            let leaves = Task { try await scheduler.submit(Self.request("leaves", prompts["leaves"]!, budgets["leaves"]!)) }
            let stops = Task {
                try await scheduler.submit(Self.request(
                    "stops", prompts["stops"]!, budgets["stops"]!, stopTokenSequences: [stop.sequence]
                ))
            }
            var results: [String: ContinuousBatchSchedulerResult] = [:]
            results["long"] = try await long.value
            let joinedMidFlight = joiner.isStarted
            joiner.start {
                try await scheduler.submit(Self.request("joiner", prompts["joiner"]!, budgets["joiner"]!))
            }
            results["leaves"] = try await leaves.value
            results["stops"] = try await stops.value
            results["joiner"] = try await joiner.value()
            XCTAssertTrue(joinedMidFlight, "window \(window): joiner must be submitted while the cohort decodes")
            XCTAssertEqual(tiny.retainedRowCountForTest(), 0, "window \(window) left row state behind")
            return results
        }

        let one = try await run(window: 1)
        let sixteen = try await run(window: Self.window)
        for id in ["long", "leaves", "joiner"] {
            XCTAssertEqual(one[id]?.terminalStatus, .length, id)
            XCTAssertEqual(sixteen[id]?.terminalStatus, .length, id)
            XCTAssertEqual(one[id]?.generatedTokens.count, budgets[id], id)
        }
        XCTAssertEqual(one["stops"]?.terminalStatus, .stop)
        XCTAssertEqual(sixteen["stops"]?.terminalStatus, .stop)
        for id in prompts.keys.sorted() {
            XCTAssertEqual(sixteen[id]?.generatedTokens, one[id]?.generatedTokens, "\(id) diverged at window 16")
        }
    }

    // MARK: - Fixtures

    private static func tinyQwen35(dtype: DType? = nil) throws -> Qwen35TextModel {
        let configuration = try JSONDecoder().decode(
            Qwen35TextConfiguration.self,
            from: Data(tinyQwen35HybridConfiguration.utf8)
        )
        MLXRandom.seed(1906)
        let target = Qwen35TextModel(configuration)
        if let dtype {
            // The serial conversation-cache format stores only fp16/bf16 KV.
            target.update(parameters: target.parameters().mapValues { $0.asType(dtype) })
        }
        eval(target)
        return target
    }

    /// Deterministic pseudo-random prompt over the tiny vocabulary.
    private static func tinyPrompt(length: Int, salt: Int) -> [Int] {
        var state = UInt64(truncatingIfNeeded: 0x9E37_79B9 &+ salt)
        return (0 ..< length).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % 32)
        }
    }

    private static func container(_ target: Qwen35TextModel) -> ModelContainer {
        ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: descriptor().modelID),
            model: target,
            processor: StandInUserInputProcessor(),
            tokenizer: HybridWindowTokenizer()
        ))
    }

    private static func schedulerBackend(target: Qwen35TextModel) -> PagedKVSharedForwardBackend {
        PagedKVSharedForwardBackend(
            container: container(target),
            descriptor: descriptor(),
            layerCount: 2,
            cacheKinds: [.recurrentMamba, .pagedAttention]
        )
    }

    /// The first step `k >= from` whose stop sequence (the `length` tokens
    /// ending at `window[k]`) matches the row's history plus window for the
    /// first time at `k`, so the scheduler would stop the row exactly there.
    private static func firstStop(
        history: [Int],
        window: [Int],
        from: Int,
        length maxLength: Int = 3
    ) -> (step: Int, sequence: [Int])? {
        for step in from ..< max(from, min(window.count, Self.window - 2)) {
            for length in 1 ... maxLength where length <= step + 1 {
                let sequence = Array(window[(step + 1 - length) ... step])
                // The prefill token alone must not already stop the row.
                guard !PagedKVSharedForwardBackend.endsWithStopSequence(
                    history: history, window: [], stopSequences: [sequence]
                ) else { continue }
                let firstMatch = (0 ... step).first { candidate in
                    PagedKVSharedForwardBackend.endsWithStopSequence(
                        history: history,
                        window: Array(window[0 ... candidate]),
                        stopSequences: [sequence]
                    )
                }
                if firstMatch == step { return (step, sequence) }
            }
        }
        return nil
    }

    // MARK: - Backend-level fixed batch

    private final class FixedBatch {
        let backend: PagedKVSharedForwardBackend
        let allocator: PagedKVBlockAllocator
        let prompts: [[Int]]
        var handles: [PagedKVBlockTableHandle] = []
        var generated: [[Int]] = []

        init(backend: PagedKVSharedForwardBackend, allocator: PagedKVBlockAllocator, prompts: [[Int]]) {
            self.backend = backend
            self.allocator = allocator
            self.prompts = prompts
        }

        func id(_ row: Int) -> String { "hybrid-window-\(row)" }

        /// Tokens the row's state covers: the prompt and every generated
        /// token except the last, which has not been fed back.
        func committed(_ row: Int) -> Int { prompts[row].count - 1 + generated[row].count }

        func decode(steps: Int, stops: [[[Int]]]? = nil) async throws {
            var inputs: [ContinuousBatchDecodeInput] = []
            for row in prompts.indices {
                _ = try await allocator.extend(handles[row], by: steps)
                try await allocator.beginDecodeStep(handles[row])
                let binding = try await allocator.binding(for: handles[row])
                var input = ContinuousBatchDecodeInput(
                    requestID: id(row),
                    currentToken: generated[row].last!,
                    generatedTokens: generated[row],
                    promptTokens: prompts[row],
                    samplerSeed: 0,
                    temperature: 0,
                    topP: 1,
                    presencePenalty: 0,
                    frequencyPenalty: 0,
                    binding: binding,
                    blockTable: binding.currentTable,
                    committedKVTokenCount: committed(row),
                    targetKVTokenCount: committed(row) + steps,
                    samplerStep: generated[row].count
                )
                input.stopTokenSequences = stops?[row] ?? []
                inputs.append(input)
            }
            let outcomes = try await backend.decodeLockstepWindow(rows: inputs, steps: steps)
            for handle in handles {
                try await allocator.endDecodeStep(handle)
            }
            XCTAssertEqual(outcomes.count, prompts.count)
            for (row, outcome) in outcomes.enumerated() {
                guard case .output(let output) = outcome, output.requestID == id(row), output.tokens.count == steps else {
                    throw HybridWindowTestError.decodeFailed("\(outcome)")
                }
                generated[row].append(contentsOf: output.tokens)
            }
        }
    }

    /// Production prefill: each row in 512-token chunks, the final chunk
    /// sampling the first token.
    private static func prefill(target: Qwen35TextModel, prompts: [[Int]]) async throws -> FixedBatch {
        let batch = FixedBatch(
            backend: PagedKVSharedForwardBackend(
                container: container(target),
                blockSizeTokens: blockSizeTokens,
                maxPhysicalBlocks: maxPhysicalBlocks,
                poolEpoch: 1,
                layerCount: 2,
                cacheKinds: [.recurrentMamba, .pagedAttention]
            ),
            allocator: try PagedKVBlockAllocator(blockSizeTokens: blockSizeTokens, maxPhysicalBlocks: maxPhysicalBlocks),
            prompts: prompts
        )
        for (row, prompt) in prompts.enumerated() {
            let handle = try await batch.allocator.allocate(conversationKey: batch.id(row), maxTokens: prompt.count + 128)
            batch.handles.append(handle)
            var offset = 0
            var first: Int?
            while offset < prompt.count {
                let end = min(offset + chunkTokens, prompt.count)
                _ = try await batch.allocator.extend(handle, by: end - offset)
                let outputs = try await batch.backend.prefill(rows: [ContinuousBatchPrefillInput(
                    requestID: batch.id(row),
                    promptTokens: Array(prompt[offset ..< end]),
                    binding: try await batch.allocator.binding(for: handle),
                    promptTokenOffset: offset,
                    committedKVTokenCount: offset,
                    targetKVTokenCount: end,
                    isFinalChunk: end == prompt.count
                )])
                XCTAssertEqual(outputs.count, 1)
                XCTAssertNil(outputs.first?.failureCode)
                first = outputs.first?.sampledToken ?? first
                offset = end
            }
            batch.generated.append([try XCTUnwrap(first, "row \(row) sampled no first token")])
        }
        return batch
    }

    private static func runFixedBatch(
        target: Qwen35TextModel,
        prompts: [[Int]],
        decodeTokens: Int,
        window: Int
    ) async throws -> (tokens: [[Int]], finalStates: [RecurrentStateCheckpoint]) {
        let batch = try await prefill(target: target, prompts: prompts)
        var remaining = decodeTokens
        while remaining > 0 {
            let steps = min(window, remaining)
            try await batch.decode(steps: steps)
            remaining -= steps
        }
        var states: [RecurrentStateCheckpoint] = []
        for row in prompts.indices {
            let state = await batch.backend.snapshotRecurrentState(
                requestID: batch.id(row),
                tokenCount: batch.committed(row)
            )
            states.append(try XCTUnwrap(state))
        }
        return (batch.generated, states)
    }

    private static func recurrentStatesClose(
        _ lhs: RecurrentStateCheckpoint,
        _ rhs: RecurrentStateCheckpoint,
        tolerance: Float = 1e-5
    ) throws -> Bool {
        guard Set(lhs.states.keys) == Set(rhs.states.keys), !lhs.states.isEmpty else { return false }
        for (layer, arrays) in lhs.states {
            let other = try XCTUnwrap(rhs.states[layer])
            guard arrays.count == other.count else { return false }
            for (a, b) in zip(arrays, other) {
                guard a.shape == b.shape,
                      allClose(a, b, rtol: Double(tolerance), atol: Double(tolerance)).item(Bool.self)
                else { return false }
            }
        }
        return true
    }

    private static func assertSameRecurrentState(
        _ lhs: RecurrentStateCheckpoint,
        _ rhs: RecurrentStateCheckpoint,
        _ message: String,
        tolerance: Float = 1e-5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(try recurrentStatesClose(lhs, rhs, tolerance: tolerance), message, file: file, line: line)
    }

    // MARK: - Scheduler

    private static func descriptor() -> PagedKVDescriptor {
        PagedKVDescriptor(
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            supportedModelFamilies: ["qwen"],
            supportsMoEDispatch: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            parityLabel: "sdpa-parity-v1"
        )
    }

    private static func makeScheduler(
        backend: any ContinuousBatchSchedulerBackend,
        maxDecodeLockstepWindow: Int
    ) throws -> ContinuousBatchScheduler {
        let descriptor = descriptor()
        let tuple = ContinuousBatchingRequestedTuple(
            modelID: descriptor.modelID,
            modelSHA256: descriptor.modelSHA256,
            tokenizerSHA256: descriptor.tokenizerSHA256,
            chatTemplateSHA256: descriptor.chatTemplateSHA256,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: descriptor.metallibSHA256,
            kernelIdentifier: descriptor.kernelIdentifier,
            parityLabel: descriptor.parityLabel,
            poolEpoch: descriptor.poolEpoch
        )
        return ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: descriptor,
                tuple: tuple,
                maxActiveRows: 4,
                decodeHeadroomTokens: 4,
                maxPromptChunkTokens: chunkTokens,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: descriptor.modelID,
                    modelSHA256: descriptor.modelSHA256,
                    weightsGeneration: 1
                ),
                maxDecodeLockstepWindow: maxDecodeLockstepWindow,
                maxDecodeStepsWhilePrefilling: min(8, maxDecodeLockstepWindow)
            ),
            allocator: try PagedKVBlockAllocator(blockSizeTokens: blockSizeTokens, maxPhysicalBlocks: maxPhysicalBlocks),
            backend: backend,
            replayAuthority: HybridWindowReplayAuthority()
        )
    }

    private static func runScheduler(
        target: Qwen35TextModel,
        maxDecodeLockstepWindow: Int,
        requests: [ContinuousBatchSchedulerRequest]
    ) async throws -> [String: ContinuousBatchSchedulerResult] {
        let scheduler = try makeScheduler(
            backend: schedulerBackend(target: target),
            maxDecodeLockstepWindow: maxDecodeLockstepWindow
        )
        var results: [String: ContinuousBatchSchedulerResult] = [:]
        for request in requests {
            results[request.id] = try await scheduler.submit(request)
        }
        return results
    }

    private static func request(
        _ id: String,
        _ prompt: [Int],
        _ maxOutputTokens: Int,
        conversationKey: String = "",
        stopTokenSequences: [[Int]] = [],
        modelStopTokenIDs: [Int] = [],
        modelHasRecurrentLayers: Bool = false
    ) -> ContinuousBatchSchedulerRequest {
        ContinuousBatchSchedulerRequest(
            id: id,
            conversationKey: conversationKey,
            promptTokens: prompt,
            maxOutputTokens: maxOutputTokens,
            stopTokenSequences: stopTokenSequences,
            modelStopTokenIDs: modelStopTokenIDs,
            samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: id),
            temperature: 0,
            topP: 1,
            modelHasRecurrentLayers: modelHasRecurrentLayers
        )
    }

    private func requireMetal() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }
}

private enum HybridWindowTestError: Error {
    case decodeFailed(String)
}

private final class HybridWindowReplayAuthority: ContinuousBatchSchedulerReplayAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    func claim(_ key: ContinuousBatchSchedulerReplayKey) throws -> ContinuousBatchSchedulerReplayClaim {
        lock.lock()
        defer { lock.unlock() }
        let storageKey = "\(key.requestID):\(key.fingerprintSHA256.base64EncodedString())"
        return keys.insert(storageKey).inserted ? .claimed : .duplicateSameRequest
    }

    func release(_ key: ContinuousBatchSchedulerReplayKey) {
        lock.lock()
        defer { lock.unlock() }
        keys.remove("\(key.requestID):\(key.fingerprintSHA256.base64EncodedString())")
    }
}

private struct HybridWindowTokenizer: Tokenizer {
    let bosToken: String? = nil
    let eosToken: String? = nil
    let unknownToken: String? = nil

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map(String.init).joined(separator: " ") }
    func convertTokenToId(_ token: String) -> Int? { Int(token) }
    func convertIdToToken(_ id: Int) -> String? { String(id) }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        []
    }
}

private final class HybridWindowTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ContinuousBatchSchedulerResult, any Error>?

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return task != nil
    }

    func start(_ body: @escaping @Sendable () async throws -> ContinuousBatchSchedulerResult) {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { try await body() }
    }

    func value() async throws -> ContinuousBatchSchedulerResult {
        while true {
            lock.lock()
            let current = task
            lock.unlock()
            if let current { return try await current.value }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
