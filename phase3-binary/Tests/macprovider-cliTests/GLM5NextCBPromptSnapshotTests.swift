import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-024-R005 on the production CB backend (`PagedKVSharedForwardBackend`)
/// with a tiny randomly initialised GLM-5-Next model and its MTP head.
/// GLM-5-Next's linear-attention kernels are GPU-only, so these run on Metal
/// and skip where the MLX metallib is unavailable.
///
/// Turn 1 prefills to its last `<|assistant|>`, snapshots there (target layers
/// and MTP head state), and finishes. Turn 2 extends turn 1 at the marker. A
/// warm turn-2 row installs the snapshot and prefills only the rest; a cold
/// row prefills the full turn-2 prompt. Both take their chunk plans from the
/// production planner (`ModelRuntime.continuousBatchPromptResumeBoundaries`
/// and `ContinuousBatchScheduler`'s balanced chunks), must hold byte-equal
/// target and head state and produce the same greedy tokens, and the stored
/// snapshot must not change.
final class GLM5NextCBPromptSnapshotTests: XCTestCase {
    /// GPU-only kernels: other classes set a CPU default device for the whole
    /// process (`Device.setDefault`), so pin the GPU here. Without a metallib
    /// no GPU stream is created (MLX aborts); every test then skips.
    override func invokeTest() {
        guard Self.metallibAvailable else { return super.invokeTest() }
        Device.withDefaultDevice(Device(.gpu)) {
            super.invokeTest()
        }
    }

    private static var metallibAvailable: Bool {
        let bundle = Bundle(for: Self.self)
        return PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(bundleURL: bundle.resourceURL,
                                                         executableURL: bundle.executableURL)
    }

    private static let blockSize = 8
    private static let chunk = 16
    private static let decodeSteps = 8
    private static let (user, assistant, observation, system, think) = (60, 61, 62, 63, 5)

    func testCBRowResumedFromAPromptSnapshotMatchesAColdCBRow() async throws {
        try requireMetal()
        try await runTwoTurns(native: false)
    }

    func testNativeMTPRowResumedFromAPromptSnapshotRestoresTheHeadState() async throws {
        try requireMetal()
        try await runTwoTurns(native: true)
    }

    /// Window A (2026-10-25) root cause, reproduced: a cold prefill that runs
    /// straight through an earlier turn's snapshot position (the plan before
    /// the fix: split only at the row's own snapshot) computes a different
    /// state there than the resumed row, whose short chunk after the snapshot
    /// takes other kernel routes (here 4-bit quantized matmuls and the MoE
    /// gather on a 5-token chunk against one 68-token chunk). The production
    /// plan, split at every resume boundary, gives the identical state.
    /// Kernel routing is device-dependent; on this fixture the old plan
    /// differs on Apple M-series GPUs.
    func testColdPrefillThroughAnEarlierSnapshotDiffersUnlessItSplitsThere() async throws {
        try requireMetal()
        let model = try ConversationPromptSnapshotTests.tinyGLM()
        let floats = model.parameters().flattened().map { key, value in
            (key, value.dtype == .float32 ? value.asType(.bfloat16) : value)
        }
        model.update(parameters: ModuleParameters.unflattened(floats))
        quantize(model: model, groupSize: 32, bits: 4) { _, module in
            (module as? Linear).map { $0.weight.dim(1) % 32 == 0 } ?? false
        }
        eval(model)
        let rows = try Self.rows(model: model, native: false, chunk: 512)

        let history = Self.history
        let turn1 = history + [Self.assistant, Self.think]
        let first = try await rows.run("turn1", prompt: turn1, snapshotAt: history.count, steps: 4)
        let snapshot = try XCTUnwrap(first.snapshot)
        let turn2 = history + [Self.assistant, first.tokens[0] % 56, Self.observation, 2, 5]
            + [Self.assistant, Self.think]

        let warm = try await rows.run("warm", prompt: turn2, snapshotAt: nil, steps: Self.decodeSteps,
                                      resume: snapshot)
        let cold = try await rows.run("cold", prompt: turn2, snapshotAt: nil, steps: Self.decodeSteps)
        let unsplit = try await rows.run("unsplit", prompt: turn2, snapshotAt: nil, steps: Self.decodeSteps,
                                         boundaries: [turn2.count - 2])
        XCTAssertEqual(cold.chunkEnds.filter { $0 > history.count }, warm.chunkEnds,
                       "after the snapshot the cold plan is the resumed plan")
        XCTAssertFalse(unsplit.chunkEnds.contains(history.count))
        assertEqualStates(warm.finalLayers, cold.finalLayers, "resume-boundary plan")
        XCTAssertEqual(warm.tokens, cold.tokens)
        XCTAssertFalse(Self.equalStates(warm.finalLayers, unsplit.finalLayers),
                       "a cold prefill through the snapshot position matched the resumed state; the fixture no longer exposes chunk-plan dependence")
    }

    // MARK: - Harness

    private static let history: [Int] = {
        var history = [system] + (0 ..< 40).map { ($0 * 7 + 3) % 56 }
        history += [user] + (0 ..< 21).map { ($0 * 5 + 1) % 56 }
        return history
    }()

    private static func rows(model: GLM5NextTextModel, native: Bool, chunk: Int) throws -> Rows {
        let configuration = try ConversationPromptSnapshotTests.tinyGLMConfiguration()
        let kinds = try model.newCache(parameters: nil).map {
            try XCTUnwrap(PagedKVSharedForwardBackend.CacheKind.recognized(from: $0))
        }
        let drafter: MTPDrafterContainer? = native
            ? MTPDrafterContainer(context: MTPDrafterContext(
                configuration: ModelConfiguration(id: "zai-org/glm-5.3-flash"),
                model: GLM5NextMTPDraftModel(configuration)))
            : nil
        let backend = PagedKVSharedForwardBackend(
            container: ModelContainer(context: ModelContext(
                configuration: ModelConfiguration(id: "zai-org/glm-5.3-flash"),
                model: model, processor: TinyProcessor(), tokenizer: TinyTokenizer())),
            blockSizeTokens: Self.blockSize,
            maxPhysicalBlocks: 256,
            poolEpoch: 1,
            layerCount: kinds.count,
            cacheKinds: kinds,
            drafterContainer: drafter
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: Self.blockSize, maxPhysicalBlocks: 256)
        return Rows(backend: backend, allocator: allocator, native: native, chunk: chunk)
    }

    private func runTwoTurns(native: Bool) async throws {
        let model = try ConversationPromptSnapshotTests.tinyGLM()
        let kinds = try model.newCache(parameters: nil).map {
            try XCTUnwrap(PagedKVSharedForwardBackend.CacheKind.recognized(from: $0))
        }
        XCTAssertTrue(kinds.contains(where: \.isPagedMLA))
        XCTAssertTrue(kinds.contains(.recurrentMamba))
        let rows = try Self.rows(model: model, native: native, chunk: Self.chunk)

        let history = Self.history
        let turn1 = history + [Self.assistant, Self.think]
        let s1 = history.count

        let first = try await rows.run("turn1", prompt: turn1, snapshotAt: s1, steps: 4)
        let snapshot = try XCTUnwrap(first.snapshot)
        XCTAssertEqual(snapshot.tokenCount, s1)
        if native {
            let head = try XCTUnwrap(snapshot.nativeMTPDrafter, "a native row snapshots its MTP head state")
            XCTAssertEqual(head.nextPosition, s1)
            XCTAssertEqual(head.foldedNextToken, Self.assistant)
        } else {
            XCTAssertNil(snapshot.nativeMTPDrafter)
        }
        let storedState = snapshot.layers.map { $0.state }
        let storedHead = snapshot.nativeMTPDrafter?.cache.map { $0.state }

        var turn2 = history + [Self.assistant] + first.tokens.map { $0 % 56 }
        turn2 += [Self.observation] + (0 ..< 30).map { ($0 * 3 + 2) % 56 }
        turn2 += [Self.assistant, Self.think]
        let s2 = turn2.count - 2

        let warm = try await rows.run("warm", prompt: turn2, snapshotAt: nil,
                                      steps: Self.decodeSteps, resume: snapshot)
        let cold = try await rows.run("cold", prompt: turn2, snapshotAt: nil, steps: Self.decodeSteps)
        XCTAssertTrue(cold.chunkEnds.contains(s1) && cold.chunkEnds.contains(s2),
                      "the cold plan ends a chunk at every resume boundary: \(cold.chunkEnds)")
        XCTAssertEqual(warm.tokens, cold.tokens, "the resumed row's greedy tokens diverged from the cold row")
        XCTAssertGreaterThan(Set(cold.tokens).count, 1)
        assertEqualStates(warm.finalLayers, cold.finalLayers, "target state after prefill")
        if native {
            let warmHead = try XCTUnwrap(warm.finalHead)
            let coldHead = try XCTUnwrap(cold.finalHead)
            assertEqualStates(warmHead, coldHead, "MTP head state after prefill")
        }

        // codec-v3 must preserve the exact real six-slot GLM cache and paired
        // MTP head, not just a synthetic tensor fixture. Install its restored
        // serial layers into the same production CB backend and run turn 2.
        let canonical = Array(turn1.prefix(s1)).map(Int32.init)
        let cached = ConversationCacheLayers(snapshot.layers, promptSnapshot: true,
            nativeMTPDrafter: snapshot.nativeMTPDrafter, resumeBoundaryPlan: true)
        let estimate = try XCTUnwrap(KVPromptSnapshotCodec.estimatedLength(cached, tokens: canonical))
        let archive = try XCTUnwrap(KVPromptSnapshotCodec.capture(cached, tokens: canonical),
                                   "real GLM target/head state must be disk serializable")
        let encoded = try KVPromptSnapshotCodec.encodeSegments(archive).reduce(into: Data()) { $0.append($1) }
        XCTAssertEqual(encoded.count, estimate)
        let decoded = try KVPromptSnapshotCodec.decode(encoded,
            expectedLayers: KVPromptSnapshotCodec.records(archive), tokenCount: s1)
        let disk = try XCTUnwrap(KVPromptSnapshotCodec.restore(decoded))
        assertEqualRawStates(disk.layers.map { $0.state }, storedState, "disk target snapshot bytes")
        if let storedHead {
            assertEqualRawStates(try XCTUnwrap(disk.nativeMTPDrafter).cache.map { $0.state },
                                 storedHead, "disk MTP snapshot bytes")
        }
        let diskSnapshot = ContinuousBatchSerialConversationCache(layers: disk.layers,
            recurrentCheckpoints: [], tokenCount: s1, promptSnapshot: true,
            nativeMTPDrafter: disk.nativeMTPDrafter)
        let diskWarm = try await rows.run("disk-warm", prompt: turn2, snapshotAt: nil,
                                         steps: Self.decodeSteps, resume: diskSnapshot)
        XCTAssertEqual(diskWarm.chunkEnds, warm.chunkEnds)
        XCTAssertEqual(diskWarm.tokens, cold.tokens, "disk resume greedy tokens diverged from cold CB")
        assertEqualRawStates(diskWarm.finalLayers, cold.finalLayers, "disk resume target parity")
        if native {
            assertEqualRawStates(try XCTUnwrap(diskWarm.finalHead), try XCTUnwrap(cold.finalHead),
                                 "disk resume native MTP head parity")
        }

        // The rows' writes never reached the stored snapshot.
        assertEqualStates(snapshot.layers.map { $0.state }, storedState, "stored snapshot")
        if let storedHead, let head = snapshot.nativeMTPDrafter {
            assertEqualStates(head.cache.map { $0.state }, storedHead, "stored MTP head state")
        }
    }

    private struct RunResult {
        let tokens: [Int]
        let chunkEnds: [Int]
        let snapshot: ContinuousBatchSerialConversationCache?
        let finalLayers: [[MLXArray]]
        let finalHead: [[MLXArray]]?
    }

    private final class Rows: @unchecked Sendable {
        let backend: PagedKVSharedForwardBackend
        let allocator: PagedKVBlockAllocator
        let native: Bool
        let chunk: Int

        init(backend: PagedKVSharedForwardBackend, allocator: PagedKVBlockAllocator, native: Bool, chunk: Int) {
            self.backend = backend
            self.allocator = allocator
            self.native = native
            self.chunk = chunk
        }

        /// The production prefill plan: the scheduler's balanced chunks of at
        /// most `chunk` tokens, ending at every resume boundary the runtime
        /// derives for `prompt` (or at `boundaries` when given), the final
        /// chunk sampling the first token; then one-token decode steps.
        func run(
            _ id: String,
            prompt: [Int],
            snapshotAt: Int?,
            steps: Int,
            resume: ContinuousBatchSerialConversationCache? = nil,
            boundaries explicitBoundaries: [Int]? = nil
        ) async throws -> RunResult {
            let boundaries = explicitBoundaries ?? ModelRuntime.continuousBatchPromptResumeBoundaries(
                promptTokenIds: prompt.map(Int32.init),
                policy: .resumeMarker(tokenID: Int32(GLM5NextCBPromptSnapshotTests.assistant)))
            var chunkEnds: [Int] = []
            let start = resume?.tokenCount ?? 0
            let handle = try await allocator.allocate(
                conversationKey: "conv:\(id)", maxTokens: prompt.count + steps + 8, initialTokens: start)
            if let resume {
                try await backend.installPromptSnapshotCache(
                    requestID: id, snapshot: resume, binding: try await allocator.binding(for: handle),
                    restoreNativeMTPDrafter: native)
            }
            var offset = start
            var snapshot: ContinuousBatchSerialConversationCache?
            var first: Int?
            while offset < prompt.count {
                let end = ContinuousBatchScheduler.balancedPrefillChunkEnd(
                    cursor: offset,
                    spanEnd: ContinuousBatchScheduler.nextPrefillBound(
                        cursor: offset, promptTokenCount: prompt.count, boundaries: boundaries),
                    maxChunkTokens: chunk)
                chunkEnds.append(end)
                _ = try await allocator.extend(handle, by: end - offset)
                let outputs = try await backend.prefill(rows: [ContinuousBatchPrefillInput(
                    requestID: id,
                    promptTokens: Array(prompt[offset ..< end]),
                    binding: try await allocator.binding(for: handle),
                    promptTokenOffset: offset,
                    committedKVTokenCount: offset,
                    targetKVTokenCount: end,
                    isFinalChunk: end == prompt.count,
                    nativeMTPPromptPrefill: native,
                    nativeMTPNextPromptToken: end < prompt.count ? prompt[end] : nil
                )])
                XCTAssertNil(outputs.first?.failureCode, "\(id) prefill [\(offset), \(end))")
                first = outputs.first?.sampledToken ?? first
                offset = end
                if end == snapshotAt {
                    snapshot = await backend.snapshotPromptCacheAndHead(
                        requestID: id, tokenCount: end, nextPromptToken: prompt[end])
                }
            }
            var generated = [try XCTUnwrap(first, "\(id) sampled no first token")]
            // The full-prompt state (target layers and, on a native row, the
            // head) read through the same capture path.
            let final = await backend.snapshotPromptCacheAndHead(
                requestID: id, tokenCount: prompt.count, nextPromptToken: generated[0])
            let finalLayers = try XCTUnwrap(final, "\(id) final state").layers.map { $0.state }
            let finalHead = final?.nativeMTPDrafter?.cache.map { $0.state }
            for step in 0 ..< steps - 1 {
                _ = try await allocator.extend(handle, by: 1)
                try await allocator.beginDecodeStep(handle)
                let binding = try await allocator.binding(for: handle)
                let committed = prompt.count - 1 + generated.count
                let outcomes = try await backend.decodeLockstepWindow(
                    rows: [ContinuousBatchDecodeInput(
                        requestID: id, currentToken: generated.last!, generatedTokens: generated,
                        promptTokens: prompt, samplerSeed: 0, temperature: 0, topP: 1,
                        presencePenalty: 0, frequencyPenalty: 0, binding: binding,
                        blockTable: binding.currentTable, committedKVTokenCount: committed,
                        targetKVTokenCount: committed + 1, samplerStep: generated.count)],
                    steps: 1)
                try await allocator.endDecodeStep(handle)
                guard case .output(let output) = outcomes.first, output.tokens.count == 1 else {
                    XCTFail("\(id) decode step \(step): \(outcomes)")
                    break
                }
                generated.append(contentsOf: output.tokens)
            }
            backend.finish(requestID: id)
            _ = try await allocator.release(handle)
            return RunResult(tokens: generated, chunkEnds: chunkEnds, snapshot: snapshot,
                             finalLayers: finalLayers, finalHead: finalHead)
        }
    }

    private static func equalStates(_ lhs: [[MLXArray]], _ rhs: [[MLXArray]]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            a.count == b.count && zip(a, b).allSatisfy { x, y in
                x.shape == y.shape && x.dtype == y.dtype && (x.size == 0 || all(x .== y).item(Bool.self))
            }
        }
    }

    private func assertEqualStates(_ lhs: [[MLXArray]], _ rhs: [[MLXArray]], _ label: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, label, file: file, line: line)
        for (layer, (a, b)) in zip(lhs, rhs).enumerated() {
            XCTAssertEqual(a.count, b.count, "\(label) layer \(layer)", file: file, line: line)
            for (slot, (x, y)) in zip(a, b).enumerated() {
                let same = x.shape == y.shape && x.dtype == y.dtype
                    && (x.size == 0 || all(x .== y).item(Bool.self))
                XCTAssertTrue(same, "\(label) layer \(layer) slot \(slot)", file: file, line: line)
            }
        }
    }

    private func assertEqualRawStates(_ lhs: [[MLXArray]], _ rhs: [[MLXArray]], _ label: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, label, file: file, line: line)
        for (layer, (left, right)) in zip(lhs, rhs).enumerated() {
            XCTAssertEqual(left.count, right.count, label, file: file, line: line)
            for (slot, (a, b)) in zip(left, right).enumerated() {
                XCTAssertEqual(a.shape, b.shape, "\(label) layer \(layer) slot \(slot)", file: file, line: line)
                XCTAssertEqual(a.dtype, b.dtype, label, file: file, line: line)
                XCTAssertEqual(a.asData(access: .copy).data, b.asData(access: .copy).data,
                               "\(label) layer \(layer) slot \(slot)", file: file, line: line)
            }
        }
    }

    private func requireMetal() throws {
        guard Self.metallibAvailable else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }
}

private struct TinyProcessor: UserInputProcessor {
    func prepare(input: UserInput) throws -> LMInput {
        LMInput(text: .init(tokens: MLXArray([Int32]()).reshaped([1, 0])))
    }
}

private struct TinyTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map(String.init).joined(separator: " ") }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}
