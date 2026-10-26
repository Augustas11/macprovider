import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Tokenizers
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

final class BatchInvariantDecodeStateTests: XCTestCase {
    override func setUpWithError() throws {
        let bundle = Bundle(for: Self.self)
        guard PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(
                bundleURL: bundle.resourceURL, executableURL: bundle.executableURL)
        else { throw XCTSkip("MLX default metallib is unavailable") }
    }

    func testSharedWindowsPreserveStationaryStateAcrossReorderAndFinish() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = InvariantFixtureModel()
            let fixture = try await Fixture(model: model)
            let first = try await fixture.decode([0, 1], steps: 2)
            XCTAssertTrue(first.allSatisfy { if case .output = $0 { return true }; return false })
            XCTAssertEqual(model.forwardBatches, [2, 2])
            XCTAssertEqual(model.mergedTags, [[11, 29], [11, 29]])
            XCTAssertEqual(model.mergedOffsets, [[0, 0], [1, 1]])
            _ = try await fixture.decode([1, 0], steps: 1)
            XCTAssertEqual(model.mergedTags.last, [29, 11])
            XCTAssertEqual(model.mergedOffsets.last, [2, 2])
            fixture.backend.finish(requestID: "row-0")
            XCTAssertEqual(fixture.backend.retainedRowCountForTest(), 1)
            _ = try await fixture.decode([1], steps: 1)
            XCTAssertEqual(model.forwardTags.last, [29], "a batch state must never replace a row's state")
        }
    }

    func testStatefulModelWithoutOptInFailsBeforeForward() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = StatefulFixtureModel()
            let fixture = try await Fixture(model: model)
            let result = try await fixture.decode([0, 1], steps: 1)
            XCTAssertEqual(result, Self.failures)
            XCTAssertTrue(model.forwardBatches.isEmpty)
        }
    }

    func testMalformedRowFailsMergeWithoutForward() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = InvariantFixtureModel()
            let fixture = try await Fixture(model: model, missingSecondState: true)
            let result = try await fixture.decode([0, 1], steps: 1)
            XCTAssertEqual(result, Self.failures)
            XCTAssertTrue(model.forwardBatches.isEmpty)
        }
    }

    func testAllMissingStatesFailBeforeEagerOrCompiledForward() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = InvariantFixtureModel()
            let fixture = try await Fixture(model: model, missingAllStates: true)
            let result = try await fixture.decode([0, 1], steps: 1)
            XCTAssertEqual(result, Self.failures)
            XCTAssertTrue(model.forwardBatches.isEmpty)
        }
    }

    func testChangedOutputDiscardsAdvancedCachesBeforePublishingTokens() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = InvariantFixtureModel()
            model.changeOutput = true
            let fixture = try await Fixture(model: model)
            let result = try await fixture.decode([0, 1], steps: 3)
            XCTAssertEqual(result, Self.failures)
            XCTAssertEqual(model.forwardBatches, [2])
            XCTAssertEqual(fixture.backend.retainedRowCountForTest(), 0)
            XCTAssertFalse(fixture.backend.lockstepInnerStateNonEmptyForTest())
        }
    }

    func testInterruptedWindowDiscardsRowsInsteadOfReusingAdvancedState() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = InvariantFixtureModel()
            let fixture = try await Fixture(model: model)
            let output = try await fixture.decode([0, 1], steps: 3, interrupt: true)
            XCTAssertEqual(model.forwardBatches, [2])
            XCTAssertEqual(output.count, 2)
            XCTAssertEqual(fixture.backend.retainedRowCountForTest(), 0)
            XCTAssertFalse(fixture.backend.lockstepInnerStateNonEmptyForTest())
        }
    }

    private static var failures: [ContinuousBatchDecodeOutcome] {
        [0, 1].map { .rowFailure(requestID: "row-\($0)") }
    }

    private final class Fixture {
        let backend: PagedKVSharedForwardBackend
        let allocator: PagedKVBlockAllocator
        var handles: [PagedKVBlockTableHandle] = []
        var offsets = [0, 0]

        init(model: StatefulFixtureModel, missingSecondState: Bool = false, missingAllStates: Bool = false) async throws {
            allocator = try PagedKVBlockAllocator(blockSizeTokens: 8, maxPhysicalBlocks: 16)
            backend = PagedKVSharedForwardBackend(
                container: ModelContainer(context: ModelContext(configuration: .init(id: "state-fixture"),
                    model: model, processor: StateFixtureProcessor(), tokenizer: StateFixtureTokenizer())),
                blockSizeTokens: 8, maxPhysicalBlocks: 16, poolEpoch: 1, layerCount: 1,
                cacheKinds: [.pagedAttention], compiledDecode: true)
            for row in 0..<2 {
                let handle = try await allocator.allocate(conversationKey: "row-\(row)", maxTokens: 16)
                handles.append(handle)
                let binding = try await allocator.binding(for: handle)
                let cache = PagedKVCache(blockSizeTokens: 8, maxPhysicalBlocks: 16, poolEpoch: 1,
                    binding: binding, initialOffset: 0, reconstructViaGather: false)
                var state = LMOutput.State()
                state[fixtureTagKey] = [row == 0 ? 11 : 29]
                try backend.installRowStateForTest(caches: [cache], requestID: "row-\(row)",
                    binding: binding, state: missingAllStates || (missingSecondState && row == 1) ? nil : state)
            }
        }

        func decode(_ rows: [Int], steps: Int, interrupt: Bool = false) async throws -> [ContinuousBatchDecodeOutcome] {
            var inputs: [ContinuousBatchDecodeInput] = []
            for row in rows {
                _ = try await allocator.extend(handles[row], by: steps)
                let binding = try await allocator.binding(for: handles[row])
                inputs.append(ContinuousBatchDecodeInput(requestID: "row-\(row)", currentToken: 1,
                    generatedTokens: [], promptTokens: [], samplerSeed: 0, temperature: 0, topP: 1,
                    presencePenalty: 0, frequencyPenalty: 0, binding: binding, blockTable: binding.currentTable,
                    committedKVTokenCount: offsets[row], targetKVTokenCount: offsets[row] + steps,
                    samplerStep: offsets[row]))
            }
            let result = try await backend.decodeLockstepWindow(rows: inputs, steps: steps,
                onStep: interrupt ? { _ in false } : nil)
            for row in rows { offsets[row] += steps }
            return result
        }
    }
}

private let fixtureTagKey = LMOutput.Key<[Int]>("fixture-stationary-tags")

private class StatefulFixtureModel: Module, LanguageModel, KVCacheDimensionProvider {
    let kvHeads = [1]
    var forwardBatches: [Int] = []
    var forwardTags: [[Int]] = []
    var changeOutput = false

    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters) throws -> PrepareResult {
        .tokens(input.text)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        let batch = input.tokens.dim(0)
        let length = input.tokens.dim(1)
        forwardBatches.append(batch)
        forwardTags.append(state?[fixtureTagKey] ?? [])
        let keys = MLXArray.ones([batch, 1, length, 1])
        for layer in cache ?? [] {
            eval(attentionWithCacheUpdate(queries: keys, keys: keys, values: keys,
                cache: layer, scale: 1, mask: .none))
        }
        var output = state
        if changeOutput { output?[fixtureTagKey] = [-1] }
        return LMOutput(logits: MLXArray([Float](repeating: 0, count: batch * length * 4),
            [batch, length, 4]), state: output)
    }
}

private final class InvariantFixtureModel: StatefulFixtureModel, BatchInvariantDecodeStateModel {
    var mergedTags: [[Int]] = []
    var mergedOffsets: [[Int]] = []

    func batchDecodeState(_ states: [LMOutput.State?], cacheOffsets: [Int]) throws -> LMOutput.State {
        let tags = try states.map { state -> Int in
            guard let values = state?[fixtureTagKey], values.count == 1 else { throw FixtureError.invalidState }
            return values[0]
        }
        mergedTags.append(tags)
        mergedOffsets.append(cacheOffsets)
        var result = LMOutput.State()
        result[fixtureTagKey] = tags
        return result
    }

    func validateBatchDecodeState(_ output: LMOutput.State?, against input: LMOutput.State) throws {
        guard output?[fixtureTagKey] == input[fixtureTagKey] else { throw FixtureError.invalidState }
    }
}

private enum FixtureError: Error { case invalidState }

private struct StateFixtureProcessor: UserInputProcessor {
    func prepare(input: UserInput) throws -> LMInput {
        LMInput(text: .init(tokens: MLXArray([Int32]()).reshaped([1, 0])))
    }
}

private struct StateFixtureTokenizer: Tokenizer {
    let bosToken: String? = nil
    let eosToken: String? = nil
    let unknownToken: String? = nil
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
}
