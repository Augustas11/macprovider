import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Optional dependency fixture, always CPU. No model download or real weights.
final class DeepseekV4BackendFixtureTests: XCTestCase {
    private func tiny() throws -> DeepseekV4Model {
        guard let path = ProcessInfo.processInfo.environment["MACPROVIDER_DSV4_TINY_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("MACPROVIDER_DSV4_TINY_FIXTURE is not set")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Fail before loading weights if an operator accidentally names a real model.
        guard object["hidden_size"] as? Int == 64, object["num_hidden_layers"] as? Int == 4,
              object["vocab_size"] as? Int == 128, object["sliding_window"] as? Int == 8 else {
            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_tiny_fixture_required")
        }
        let config = try JSONDecoder().decode(DeepseekV4Configuration.self, from: data)
        let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
        let model = DeepseekV4Model(config)
        try loadWeights(modelDirectory: directory, model: model, perLayerQuantization: base.perLayerQuantization)
        model.train(false)
        return model
    }

    private func container(_ model: DeepseekV4Model) -> ModelContainer {
        ModelContainer(context: ModelContext(configuration: .init(id: "deepseek/deepseek-v4-flash"),
            model: model, processor: DeepseekFixtureProcessor(), tokenizer: DeepseekFixtureTokenizer()))
    }

    func testDeepseekV4ProductionBackendExactRaggedDecodeAndMembershipTransitionOnCPU() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = try tiny()
            let kinds = try XCTUnwrap(PagedKVSharedForwardBackend.CacheKind.kinds(from: model.newCache(parameters: nil)))
            let (parity, isolation) = await DeepseekV4RuntimeParityProbe.run(
                container: container(model), blockSizeTokens: 128, maxPhysicalBlocks: 64, cacheKinds: kinds,
                promptA: (0..<65).map { ($0 * 7 + 3) % 128 },
                promptB: (0..<130).map { ($0 * 11 + 17) % 128 })
            let proof = try XCTUnwrap(parity?.rowPoolProof)
            XCTAssertTrue(proof.established)
            XCTAssertTrue(proof.exactParity)
            XCTAssertTrue(proof.raggedOffsets)
            XCTAssertTrue(proof.membershipTransitionParity)
            XCTAssertEqual(parity?.gatherKernelCalls, 0)
            XCTAssertTrue(try XCTUnwrap(isolation).sharedForwardParityProven)
        }
    }

    func testDeepseekV4SchedulerMatchesSerialAcross2048ReferenceBoundaryOnCPU() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = try tiny()
            let prompts = [2049, 2067].enumerated().map { salt, count in
                (0..<count).map { ($0 * 7 + salt * 23 + 3) % 128 }
            }
            let reference = try prompts.map { try serial(model, prompt: $0, count: 6) }
            let tuple = ContinuousBatchingRequestedTuple(modelID: "deepseek/deepseek-v4-flash",
                modelSHA256: "tiny", tokenizerSHA256: nil, chatTemplateSHA256: nil,
                cacheClass: "mixed", kvDType: .fp16, requiresMoE: true, hardwareClass: "cpu-fixture",
                metallibSHA256: "fixture", kernelIdentifier: "deepseek-v4-row-pool-decode-v1", parityLabel: "fixture", poolEpoch: 1)
            let descriptor = PagedKVDescriptor(blockSizeTokens: 128, maxPhysicalBlocks: 128,
                modelID: tuple.modelID, modelSHA256: tuple.modelSHA256, tokenizerSHA256: nil, chatTemplateSHA256: nil,
                supportedModelFamilies: ["deepseek_v4"], allowedCacheClasses: ["mixed"], supportsMoEDispatch: true,
                hardwareClass: tuple.hardwareClass, metallibSHA256: tuple.metallibSHA256,
                kernelIdentifier: tuple.kernelIdentifier, parityLabel: tuple.parityLabel)
            let configuration = ContinuousBatchSchedulerConfiguration(descriptor: descriptor, tuple: tuple,
                moePromotionEvidenceAvailable: true, maxActiveRows: 2, decodeHeadroomTokens: 8,
                maxPrefillRowsPerIteration: 2, maxPrefillTokensPerIteration: 64, maxPromptChunkTokens: 32,
                referencePrefillStepSize: 2048,
                snapshot: .init(modelID: tuple.modelID, modelSHA256: tuple.modelSHA256, weightsGeneration: 1),
                maxDecodeLockstepWindow: 1, maxDecodeRowsPerForward: 8)
            let scheduler = ContinuousBatchScheduler(configuration: configuration,
                allocator: try PagedKVBlockAllocator(blockSizeTokens: 128, maxPhysicalBlocks: 128),
                backend: DeepseekV4ContinuousBatchBackend(container: container(model)),
                replayAuthority: ContinuousBatchRuntimeReplayAuthority.inMemoryForTests())
            async let first = scheduler.submit(.init(id: "tiny-a", conversationKey: "", promptTokens: prompts[0], maxOutputTokens: 6))
            async let second = scheduler.submit(.init(id: "tiny-b", conversationKey: "", promptTokens: prompts[1], maxOutputTokens: 6))
            let (firstResult, secondResult) = try await (first, second)
            let results = [firstResult, secondResult]
            for index in results.indices {
                XCTAssertEqual(results[index].terminalStatus, .length)
                XCTAssertEqual(results[index].generatedTokens, reference[index])
            }
            _ = try await scheduler.drain()
        }
    }

    private func serial(_ model: DeepseekV4Model, prompt: [Int], count: Int) throws -> [Int] {
        let cache = try model.newCache(parameters: nil)
        var offset = 0
        while prompt.count - offset > 1 {
            let end = min(offset + 2048, prompt.count - 1)
            _ = model(MLXArray(prompt[offset..<end].map(Int32.init)).reshaped([1, end - offset]), cache: cache)
            eval(cache)
            offset = end
        }
        var current = prompt.last!
        var result: [Int] = []
        for _ in 0..<count {
            let logits = model(MLXArray([Int32(current)]).reshaped([1, 1]), cache: cache)
            current = argMax(logits[0, -1], axis: -1).item(Int.self)
            eval(cache)
            result.append(current)
        }
        return result
    }
}

private struct DeepseekFixtureProcessor: UserInputProcessor {
    func prepare(input: UserInput) throws -> LMInput {
        LMInput(text: .init(tokens: MLXArray([Int32]()).reshaped([1, 0])))
    }
}

private struct DeepseekFixtureTokenizer: Tokenizer {
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
