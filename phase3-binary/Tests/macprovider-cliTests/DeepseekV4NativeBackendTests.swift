import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

final class DeepseekV4NativeBackendTests: XCTestCase {
    func testHeldDrafterCatchupOccursOnlyBeforeColumnCapWouldBeExceeded() {
        for count in 0...1024 {
            XCTAssertEqual(DeepseekV4ContinuousBatchBackend.needsDrafterCatchup(
                bufferedColumns: count, nextWindow: 1), count == 1024)
        }
        XCTAssertFalse(DeepseekV4ContinuousBatchBackend.needsDrafterCatchup(bufferedColumns: 1008, nextWindow: 16))
        XCTAssertTrue(DeepseekV4ContinuousBatchBackend.needsDrafterCatchup(bufferedColumns: 1009, nextWindow: 16))
    }

    func testHeldHiddenColumnOwnsItsRowStorage() throws {
        try requireMetallib()
        Device.withDefaultDevice(.cpu) {
            let batch = MLXArray((0..<12).map(Float.init)).reshaped([3, 1, 4])
            let held = DeepseekV4ContinuousBatchBackend.detachedHiddenColumn(batch, row: 1)
            eval(held)
            XCTAssertEqual(held.shape, [1, 1, 4])
            XCTAssertEqual(held.asArray(Float.self), [4, 5, 6, 7])
            batch[1, 0, 0] = MLXArray(Float(99))
            eval(batch)
            XCTAssertEqual(held.asArray(Float.self), [4, 5, 6, 7])
        }
    }

    func testConfidenceBudgetRanksFourRowsByPrefixSurvival() throws {
        XCTAssertEqual(try DeepseekV4ContinuousBatchBackend.confidenceScheduledDepths(
            confidences: [[0.9, 0.9], [0.8, 0.5], [0.7, 0.7], [0.6, 0.8]],
            maximumDepths: [2, 2, 2, 2], tokenBudget: 8), [2, 1, 1, 0])
        XCTAssertEqual(try DeepseekV4ContinuousBatchBackend.confidenceScheduledDepths(
            confidences: Array(repeating: [1, 1], count: 4),
            maximumDepths: [2, 2, 2, 2], tokenBudget: 7), [2, 1, 0, 0])
        XCTAssertEqual(try DeepseekV4ContinuousBatchBackend.confidenceScheduledDepths(
            confidences: Array(repeating: [0.5, 0.5], count: 4),
            maximumDepths: [2, 2, 2, 2], tokenBudget: 4), [0, 0, 0, 0])
    }

    func testConfidenceBudgetRejectsInvalidPredictorsAndWidths() throws {
        for probabilities: [Float] in [[.nan], [.infinity], [-0.1], [1.1], []] {
            XCTAssertThrowsError(try DeepseekV4ContinuousBatchBackend.confidenceScheduledDepths(
                confidences: [probabilities], maximumDepths: [1], tokenBudget: 2))
        }
        XCTAssertThrowsError(try DeepseekV4ContinuousBatchBackend.confidenceScheduledDepths(
            confidences: [[0.9]], maximumDepths: [1], tokenBudget: 0))
    }

    /// The target transaction is tested independently of drafter quality. Each
    /// retained prefix must equal ordinary teacher-forced decode bit for bit.
    func testRaggedNativeTargetCommitEveryPrefixAndAbortAcrossPoolBoundaries() async throws {
        try requireMetallib()
        try await Device.withDefaultDevice(.cpu) {
            let model = try tinyDSparkTarget()
            let container = ModelContainer(context: ModelContext(configuration: .init(id: "deepseek-v4-tiny"),
                model: model, processor: NativeBackendFixtureProcessor(), tokenizer: NativeBackendFixtureTokenizer()))
            for keep in 0...6 {
                let backend = DeepseekV4ContinuousBatchBackend(container: container)
                let allocator = try PagedKVBlockAllocator(blockSizeTokens: 128, maxPhysicalBlocks: 16)
                var handles: [PagedKVBlockTableHandle] = []
                var bindings: [PagedKVStorageBinding] = []
                var prompts: [[Int]] = []
                var serialCaches: [[KVCache]] = []
                for (row, count) in [7, 127].enumerated() {
                    let id = "native-\(row)"
                    let prompt = (0..<count).map { ($0 * 7 + row * 11 + 3) % 128 }
                    prompts.append(prompt)
                    let handle = try await allocator.allocate(conversationKey: id, maxTokens: 256, initialTokens: count)
                    handles.append(handle)
                    let binding = try await allocator.binding(for: handle)
                    bindings.append(binding)
                    let final = try await backend.prefill(rows: [.init(requestID: id,
                        promptTokens: prompt, binding: binding, promptTokenOffset: 0,
                        committedKVTokenCount: 0, targetKVTokenCount: count, isFinalChunk: true)])
                    XCTAssertNil(final[0].failureCode)
                    let cache = try model.newCache(parameters: nil)
                    _ = model(MLXArray(prompt.map(Int32.init)).reshaped([1, count]), cache: cache)
                    eval(cache)
                    serialCaches.append(cache)
                }
                let proposalsByRow = serialCaches.map { cache -> [Int] in
                    let ordinary = cache.map { $0.copy() }
                    var proposals: [Int] = []
                    var current = 13
                    for _ in 0..<5 {
                        let logits = model(MLXArray([Int32(current)]).reshaped([1, 1]), cache: ordinary)
                        current = argMax(logits[0, -1, 0...], axis: -1).item(Int.self)
                        proposals.append(current)
                    }
                    eval(ordinary)
                    if (1...5).contains(keep) { proposals[keep - 1] = (proposals[keep - 1] + 1) % 128 }
                    return proposals
                }
                let inputs = bindings.enumerated().map { row, binding in
                    ContinuousBatchNativeMTPVerifyInput(requestID: "native-\(row)", currentToken: 13,
                        proposalTokens: proposalsByRow[row], generatedTokens: [13], samplerSeed: 5,
                        binding: binding, blockTable: binding.currentTable,
                        committedKVTokenCount: prompts[row].count, verifiedInputTokenCount: 6,
                        targetKVTokenCount: prompts[row].count + 6, packedRowIndex: row, samplerStep: 1)
                }
                let verified = try await backend.verifyNativeMTPPackedRound(rows: inputs)
                XCTAssertEqual(verified.map(\.targetTopTokenIDs.count), [6, 6])
                for row in inputs.indices {
                    let ordinary = serialCaches[row].map { $0.copy() }
                    var expected: [Int] = []
                    for token in [13] + proposalsByRow[row] {
                        let logits = model(MLXArray([Int32(token)]).reshaped([1, 1]), cache: ordinary)
                        expected.append(argMax(logits[0, -1, 0...], axis: -1).item(Int.self))
                    }
                    eval(ordinary)
                    XCTAssertEqual(verified[row].targetTopTokenIDs, expected)
                }
                let finalizing = inputs.enumerated().map { row, input in
                    ContinuousBatchNativeMTPFinalizeInput(requestID: input.requestID, proposalTokenCount: 5,
                        committedProposalTokenCount: max(0, keep - 1),
                        acceptedTokenIDs: keep > 0
                            ? Array(proposalsByRow[row].prefix(keep - 1)) + [verified[row].targetTopTokenIDs[keep - 1]] : [],
                        committedInputTokenCount: keep, shouldCommit: keep > 0)
                }
                try await backend.finalizeNativeMTPPackedRound(rows: finalizing)
                for row in inputs.indices {
                    for token in ([13] + proposalsByRow[row]).prefix(keep) {
                        _ = model(MLXArray([Int32(token)]).reshaped([1, 1]), cache: serialCaches[row])
                    }
                    eval(serialCaches[row])
                    let captured = await backend.snapshotPromptCache(
                        requestID: inputs[row].requestID, tokenCount: prompts[row].count + keep)
                    let snapshot = try XCTUnwrap(captured)
                    assertCachesEqual(snapshot.layers, serialCaches[row])
                    backend.finish(requestID: inputs[row].requestID)
                    try await allocator.release(handles[row])
                }
            }
        }
    }

    func testNativeDrafterPrefillAndRoundsMatchOrdinaryGreedy() async throws {
        try requireMetallib()
        try await Device.withDefaultDevice(.cpu) {
            let config = try tinyDSparkConfiguration()
            let model = DeepseekV4Model(config)
            XCTAssertTrue(model.batchesExactly, "the native backend fixture must support exact CB")
            model.train(false)
            let container = ModelContainer(context: ModelContext(configuration: .init(id: "deepseek-v4-tiny"),
                model: model, processor: NativeBackendFixtureProcessor(), tokenizer: NativeBackendFixtureTokenizer()))
            let drafter = MTPDrafterContainer(context: MTPDrafterContext(configuration: .init(id: "deepseek-v4-tiny"),
                model: DeepseekV4DSparkDraftModel(config, maximumDepth: 3)))
            let backend = DeepseekV4ContinuousBatchBackend(container: container, nativeMTPDrafterContainer: drafter)
            let allocator = try PagedKVBlockAllocator(blockSizeTokens: 128, maxPhysicalBlocks: 4)
            let prompt = [3, 7, 11, 19, 23, 31, 37]
            let handle = try await allocator.allocate(conversationKey: "draft", maxTokens: 128,
                initialTokens: prompt.count)
            let binding = try await allocator.binding(for: handle)
            let finalChunk = try await backend.prefill(rows: [.init(requestID: "draft",
                promptTokens: prompt, binding: binding, promptTokenOffset: 0,
                committedKVTokenCount: 0, targetKVTokenCount: prompt.count,
                isFinalChunk: true, nativeMTPPromptPrefill: true)])
            XCTAssertNil(finalChunk[0].failureCode)
            var generated = [try XCTUnwrap(finalChunk[0].sampledToken)]
            var committed = prompt.count
            // A held row shares ordinary decode and owns its columns without
            // advancing the adapter. Its next proposal catches up once.
            for _ in 0..<3 {
                let held = try await backend.decode(rows: [.init(requestID: "draft",
                    currentToken: generated.last!, generatedTokens: generated, promptTokens: prompt, samplerSeed: 1,
                    temperature: 0, topP: 1, presencePenalty: 0, frequencyPenalty: 0,
                    binding: binding, blockTable: binding.currentTable,
                    committedKVTokenCount: committed, targetKVTokenCount: committed + 1,
                    samplerStep: generated.count, captureNativeMTPDrafterColumns: true)])
                guard case .output(let output) = held[0] else { return XCTFail("Held decode failed") }
                generated += output.tokens
                committed += 1
                let status = try XCTUnwrap(backend.labDrafterPosition(requestID: "draft"))
                XCTAssertEqual(status.position, prompt.count)
                XCTAssertEqual(status.buffered, committed - prompt.count)
            }
            for _ in 0..<8 {
                let proposed = try await backend.proposeNativeMTPPackedRound(rows: [.init(requestID: "draft",
                    currentToken: generated.last!, generatedTokens: generated, samplerSeed: 1,
                    maximumProposalDepth: 3, samplerStep: generated.count)])
                let tokens = try XCTUnwrap(proposed?["draft"])
                let status = try XCTUnwrap(backend.labDrafterPosition(requestID: "draft"))
                XCTAssertEqual(status.position, committed)
                XCTAssertEqual(status.buffered, 0)
                let verified = try await backend.verifyNativeMTPPackedRound(rows: [.init(requestID: "draft",
                    currentToken: generated.last!, proposalTokens: tokens, generatedTokens: generated,
                    samplerSeed: 1, binding: binding, blockTable: binding.currentTable,
                    committedKVTokenCount: committed, verifiedInputTokenCount: tokens.count + 1,
                    targetKVTokenCount: committed + tokens.count + 1, packedRowIndex: 0,
                    samplerStep: generated.count)])
                let accepted = try NativeMTPAcceptance.acceptGreedy(rowMaps: [.init(schedulerRowID: "draft",
                    packedRowIndex: 0, inputTokenCount: tokens.count + 1, proposalTokenCount: tokens.count)],
                    verifiedRows: verified, packedRowCount: 1)[0]
                let selected = accepted.tokenCandidates
                let proposalCount = selected.last!.cumulativeProposalCommitCount
                try await backend.finalizeNativeMTPPackedRound(rows: [.init(requestID: "draft",
                    proposalTokenCount: tokens.count, committedProposalTokenCount: proposalCount,
                    acceptedTokenIDs: selected.map(\.tokenID), committedInputTokenCount: proposalCount + 1,
                    shouldCommit: true)])
                committed += proposalCount + 1
                generated += selected.map(\.tokenID)
            }
            let reference = try model.newCache(parameters: nil)
            var logits = model(MLXArray(prompt.map(Int32.init)).reshaped([1, prompt.count]), cache: reference)
            var expected: [Int] = []
            while expected.count < generated.count {
                let current = argMax(logits[0, -1, 0...], axis: -1).item(Int.self)
                expected.append(current)
                if expected.count < generated.count {
                    logits = model(MLXArray([Int32(current)]).reshaped([1, 1]), cache: reference)
                }
            }
            eval(reference)
            XCTAssertEqual(generated, expected)
            backend.finish(requestID: "draft")
            try await allocator.release(handle)
        }
    }

    func testCancelledNativeRowCannotPublishAStagedVerification() async throws {
        try requireMetallib()
        try await Device.withDefaultDevice(.cpu) {
            let model = try tinyDSparkTarget()
            let container = ModelContainer(context: ModelContext(configuration: .init(id: "deepseek-v4-tiny"),
                model: model, processor: NativeBackendFixtureProcessor(), tokenizer: NativeBackendFixtureTokenizer()))
            let backend = DeepseekV4ContinuousBatchBackend(container: container)
            let allocator = try PagedKVBlockAllocator(blockSizeTokens: 128, maxPhysicalBlocks: 2)
            let handle = try await allocator.allocate(conversationKey: "cancel", maxTokens: 128, initialTokens: 1)
            let binding = try await allocator.binding(for: handle)
            let prefill = try await backend.prefill(rows: [.init(requestID: "cancel", promptTokens: [3],
                binding: binding, promptTokenOffset: 0, committedKVTokenCount: 0,
                targetKVTokenCount: 1, isFinalChunk: true)])
            XCTAssertNil(prefill[0].failureCode)
            _ = try await backend.verifyNativeMTPPackedRound(rows: [.init(requestID: "cancel", currentToken: 7,
                proposalTokens: [11], generatedTokens: [7], samplerSeed: 1, binding: binding,
                blockTable: binding.currentTable, committedKVTokenCount: 1, verifiedInputTokenCount: 2,
                targetKVTokenCount: 3, packedRowIndex: 0, samplerStep: 1)])
            backend.finish(requestID: "cancel")
            do {
                try await backend.finalizeNativeMTPPackedRound(rows: [.init(requestID: "cancel",
                    proposalTokenCount: 1, committedProposalTokenCount: 0, acceptedTokenIDs: [13],
                    committedInputTokenCount: 1, shouldCommit: true)])
                XCTFail("Retired row published target state")
            } catch {}
            let snapshot = await backend.snapshotPromptCache(requestID: "cancel", tokenCount: 2)
            XCTAssertNil(snapshot)
            try await allocator.release(handle)
        }
    }

    private func assertCachesEqual(_ actual: [KVCache], _ expected: [KVCache],
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.metaState, b.metaState, file: file, line: line)
            XCTAssertEqual(a.state.count, b.state.count, file: file, line: line)
            for (x, y) in zip(a.state, b.state) {
                XCTAssertEqual(x.shape, y.shape, file: file, line: line)
                XCTAssertTrue((x .== y).all().item(Bool.self), file: file, line: line)
            }
        }
    }

    private func requireMetallib() throws {
        let tests = Bundle(for: Self.self)
        guard PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(bundleURL: tests.resourceURL, executableURL: tests.executableURL)
        else { throw XCTSkip("MLX default metallib is unavailable in this test host") }
    }

    private func tinyDSparkTarget() throws -> DeepseekV4Model {
        let model = DeepseekV4Model(try tinyDSparkConfiguration())
        XCTAssertTrue(model.batchesExactly, "the native backend fixture must support exact CB")
        model.train(false)
        return model
    }

    private func tinyDSparkConfiguration() throws -> DeepseekV4Configuration {
        guard let path = ProcessInfo.processInfo.environment["MACPROVIDER_DSV4_TINY_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("MACPROVIDER_DSV4_TINY_FIXTURE is not set")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("config.json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        guard object["hidden_size"] as? Int == 64, object["num_hidden_layers"] as? Int == 4,
              object["vocab_size"] as? Int == 128, object["sliding_window"] as? Int == 8 else {
            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_tiny_fixture_required")
        }
        // CB requires the exact indexer; approximate HISA has separate fork coverage.
        object["index_block"] = 0
        object["index_keep"] = 0
        object["compress_ratios"] = Array((object["compress_ratios"] as! [Int]).prefix(4)) + [0, 0, 0]
        object["dspark_target_layer_ids"] = [1, 2, 3]
        object["dspark_block_size"] = 5
        object["dspark_noise_token_id"] = 9
        object["dspark_markov_rank"] = 4
        // These tests initialize only a tiny model; they do not load the
        // artifact or qualify its tokens.
        return try JSONDecoder().decode(DeepseekV4Configuration.self,
            from: JSONSerialization.data(withJSONObject: object))
    }
}

private struct NativeBackendFixtureProcessor: UserInputProcessor {
    func prepare(input: UserInput) throws -> LMInput {
        LMInput(text: .init(tokens: MLXArray([Int32]()).reshaped([1, 0])))
    }
}

private struct NativeBackendFixtureTokenizer: Tokenizer {
    let bosToken: String? = nil
    let eosToken: String? = nil
    let unknownToken: String? = nil
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.split(separator: " ").compactMap { Int($0) } }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map(String.init).joined(separator: " ") }
    func convertTokenToId(_ token: String) -> Int? { Int(token) }
    func convertIdToToken(_ id: Int) -> String? { String(id) }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
}
