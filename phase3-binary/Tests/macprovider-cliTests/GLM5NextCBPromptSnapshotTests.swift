import Foundation
import MLX
import MLXLLM
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-024-R005 on the production CB backend (`PagedKVSharedForwardBackend`)
/// with a tiny randomly initialised GLM-5-Next model and its MTP head.
/// GLM-5-Next's linear-attention kernels are GPU-only, so these run on Metal
/// and skip where the MLX metallib is unavailable.
///
/// Turn 1 prefills to the last role marker, snapshots there (target layers and
/// MTP head state), and finishes. Turn 2 extends turn 1 at the marker. A warm
/// turn-2 row installs the snapshot and prefills only the rest; a cold row
/// prefills the full turn-2 prompt with the same chunk boundaries. Both must
/// hold byte-equal target and head state and produce the same greedy tokens,
/// and the stored snapshot must not change.
final class GLM5NextCBPromptSnapshotTests: XCTestCase {
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

    // MARK: - Harness

    private func runTwoTurns(native: Bool) async throws {
        let configuration = try ConversationPromptSnapshotTests.tinyGLMConfiguration()
        let model = try ConversationPromptSnapshotTests.tinyGLM()
        let kinds = try model.newCache(parameters: nil).map {
            try XCTUnwrap(PagedKVSharedForwardBackend.CacheKind.recognized(from: $0))
        }
        XCTAssertTrue(kinds.contains(where: \.isPagedMLA))
        XCTAssertTrue(kinds.contains(.recurrentMamba))
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
        let rows = Rows(backend: backend, allocator: allocator, native: native)

        var history = [Self.system] + (0 ..< 40).map { ($0 * 7 + 3) % 56 }
        history += [Self.user] + (0 ..< 21).map { ($0 * 5 + 1) % 56 }
        let turn1 = history + [Self.assistant, Self.think]
        let s1 = history.count

        let first = try await rows.run("turn1", prompt: turn1, boundaries: [s1], snapshotAt: s1, steps: 4)
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

        let warm = try await rows.run("warm", prompt: turn2, boundaries: [s2], snapshotAt: nil,
                                      steps: Self.decodeSteps, resume: snapshot)
        let cold = try await rows.run("cold", prompt: turn2, boundaries: [s1, s2], snapshotAt: nil,
                                      steps: Self.decodeSteps)
        XCTAssertEqual(warm.tokens, cold.tokens, "the resumed row's greedy tokens diverged from the cold row")
        XCTAssertGreaterThan(Set(cold.tokens).count, 1)
        assertEqualStates(warm.finalLayers, cold.finalLayers, "target state after prefill")
        if native {
            let warmHead = try XCTUnwrap(warm.finalHead)
            let coldHead = try XCTUnwrap(cold.finalHead)
            assertEqualStates(warmHead, coldHead, "MTP head state after prefill")
        }

        // The rows' writes never reached the stored snapshot.
        assertEqualStates(snapshot.layers.map { $0.state }, storedState, "stored snapshot")
        if let storedHead, let head = snapshot.nativeMTPDrafter {
            assertEqualStates(head.cache.map { $0.state }, storedHead, "stored MTP head state")
        }
    }

    private struct RunResult {
        let tokens: [Int]
        let snapshot: ContinuousBatchSerialConversationCache?
        let finalLayers: [[MLXArray]]
        let finalHead: [[MLXArray]]?
    }

    private final class Rows: @unchecked Sendable {
        let backend: PagedKVSharedForwardBackend
        let allocator: PagedKVBlockAllocator
        let native: Bool

        init(backend: PagedKVSharedForwardBackend, allocator: PagedKVBlockAllocator, native: Bool) {
            self.backend = backend
            self.allocator = allocator
            self.native = native
        }

        /// Production-shaped prefill: chunks of at most `chunk` tokens that
        /// never cross a boundary, the final chunk sampling the first token,
        /// then one-token decode steps.
        func run(
            _ id: String,
            prompt: [Int],
            boundaries: [Int],
            snapshotAt: Int?,
            steps: Int,
            resume: ContinuousBatchSerialConversationCache? = nil
        ) async throws -> RunResult {
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
                let limit = boundaries.filter { $0 > offset }.min() ?? prompt.count
                let end = min(offset + chunk, limit)
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
            return RunResult(tokens: generated, snapshot: snapshot, finalLayers: finalLayers, finalHead: finalHead)
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

    private func requireMetal() throws {
        let bundle = Bundle(for: Self.self)
        guard PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(bundleURL: bundle.resourceURL, executableURL: bundle.executableURL)
        else {
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
