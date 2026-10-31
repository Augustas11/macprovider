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
    override func setUpWithError() throws {
        // MLX loads the default metallib even for the CPU device; probe beside
        // the test bundle's own executable too, where MLX looks.
        let tests = Bundle(for: Self.self)
        guard PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(bundleURL: tests.resourceURL, executableURL: tests.executableURL)
        else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    private func tiny() throws -> DeepseekV4Model {
        guard let path = ProcessInfo.processInfo.environment["MACPROVIDER_DSV4_TINY_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("MACPROVIDER_DSV4_TINY_FIXTURE is not set")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Fail before loading weights if an operator accidentally names a real model.
        guard object["hidden_size"] as? Int == 64, object["num_hidden_layers"] as? Int == 4,
              object["vocab_size"] as? Int == 128, object["sliding_window"] as? Int == 8 else {
            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_tiny_fixture_required")
        }
        // CB requires the exact indexer; approximate HISA has separate fork coverage.
        object["index_block"] = 0
        object["index_keep"] = 0
        let config = try JSONDecoder().decode(DeepseekV4Configuration.self,
            from: JSONSerialization.data(withJSONObject: object))
        let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
        let model = DeepseekV4Model(config)
        XCTAssertTrue(model.batchesExactly, "the backend fixture must support exact CB")
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

    func testDeepseekV4SchedulerMatchesFullContextSerialOnCPU() async throws {
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
                referencePrefillStepSize: DeepseekV4Model.prefillStepSize,
                // CPU fixture prefill can exceed the production admission deadline.
                queueWaitTimeoutNanoseconds: 600_000_000_000,
                snapshot: .init(modelID: tuple.modelID, modelSHA256: tuple.modelSHA256, weightsGeneration: 1),
                maxDecodeLockstepWindow: 16, maxDecodeRowsPerForward: 8)
            let scheduler = ContinuousBatchScheduler(configuration: configuration,
                allocator: try PagedKVBlockAllocator(blockSizeTokens: 128, maxPhysicalBlocks: 128),
                backend: DeepseekV4ContinuousBatchBackend(container: container(model)),
                replayAuthority: ContinuousBatchRuntimeReplayAuthority.inMemoryForTests())
            async let first = scheduler.submit(.init(id: "tiny-a", conversationKey: "", promptTokens: prompts[0],
                maxOutputTokens: 6, temperature: 0))
            async let second = scheduler.submit(.init(id: "tiny-b", conversationKey: "", promptTokens: prompts[1],
                maxOutputTokens: 6, temperature: 0))
            let (firstResult, secondResult) = try await (first, second)
            let results = [firstResult, secondResult]
            for index in results.indices {
                XCTAssertEqual(results[index].terminalStatus, .length, results[index].errorCode ?? "no error code")
                XCTAssertEqual(results[index].generatedTokens, reference[index])
            }
            _ = try await scheduler.drain()
        }
    }

    func testDeepseekV4PipelinedWindowsMatchSerialAtOneTwoFourEightRowsOnCPU() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = try tiny()
            for rowCount in [1, 2, 4, 8] {
                let backend = DeepseekV4ContinuousBatchBackend(container: container(model))
                let allocator = try PagedKVBlockAllocator(blockSizeTokens: 128, maxPhysicalBlocks: 32)
                var states: [FixtureRow] = []
                for row in 0..<rowCount {
                    let prompt = (0..<(9 + row * 3)).map { ($0 * 7 + row * 13 + 3) % 128 }
                    states.append(try await prefill(id: "row-\(row)", prompt: prompt, backend: backend, allocator: allocator))
                }
                let reference = try states.map { try serial(model, prompt: $0.prompt, count: 8) }
                let first = try await window(states, steps: 4, backend: backend, allocator: allocator)
                for index in states.indices {
                    states[index].generated += try tokens(first[index])
                    XCTAssertEqual(states[index].generated, Array(reference[index].prefix(5)))
                }
                // Rebuild row order at the next container hop while retaining
                // each row's distinct ragged pool offset and sampler position.
                states.reverse()
                let second = try await window(states, steps: 3, backend: backend, allocator: allocator)
                for index in states.indices {
                    states[index].generated += try tokens(second[index])
                    let original = rowCount - index - 1
                    XCTAssertEqual(states[index].generated, reference[original])
                    backend.finish(requestID: states[index].id)
                    try await allocator.release(states[index].handle)
                }
            }
        }
    }

    func testDeepseekV4PipelinedStopDiscardsOvershootAndPreservesPeerOnCPU() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = try tiny()
            let backend = DeepseekV4ContinuousBatchBackend(container: container(model))
            let allocator = try PagedKVBlockAllocator(blockSizeTokens: 128, maxPhysicalBlocks: 8)
            var first = try await prefill(id: "stop", prompt: [3, 7, 11, 19, 23, 31, 37, 43, 47],
                backend: backend, allocator: allocator)
            var peer = try await prefill(id: "peer", prompt: [5, 13, 17, 29, 41, 53, 59, 61, 67, 71, 73],
                backend: backend, allocator: allocator)
            let stopReference = try serial(model, prompt: first.prompt, count: 7)
            let peerReference = try serial(model, prompt: peer.prompt, count: 8)
            // A two-token stop crossing the prefill/decode boundary.
            let stop = Array(stopReference.prefix(2))
            let outcomes = try await window([first, peer], steps: 4, stops: [first.id: [stop]],
                backend: backend, allocator: allocator)
            first.generated += try tokens(outcomes[0])
            peer.generated += try tokens(outcomes[1])
            XCTAssertEqual(first.generated, stop)
            XCTAssertEqual(peer.generated, Array(peerReference.prefix(5)))
            let resumed = try await window([peer, first], steps: 3, backend: backend, allocator: allocator)
            peer.generated += try tokens(resumed[0])
            XCTAssertEqual(peer.generated, peerReference)
            XCTAssertEqual(resumed[1], .rowFailure(requestID: first.id),
                "A stopped pool must never be reused at an overshot offset")
            backend.finish(requestID: peer.id)
            try await allocator.release(first.handle)
            try await allocator.release(peer.handle)
        }
    }

    func testDeepseekV4PipelinedCancellationDiscardsQueuedStateOnCPU() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = try tiny()
            let backend = DeepseekV4ContinuousBatchBackend(container: container(model))
            let allocator = try PagedKVBlockAllocator(blockSizeTokens: 128, maxPhysicalBlocks: 8)
            var row = try await prefill(id: "cancel", prompt: [3, 7, 11, 19, 23, 31, 37, 43, 47],
                backend: backend, allocator: allocator)
            let outcomes = try await window([row], steps: 4, backend: backend, allocator: allocator,
                onStep: { _ in false })
            row.generated += try tokens(outcomes[0])
            XCTAssertEqual(row.generated.count, 2)
            let resumed = try await window([row], steps: 1, backend: backend, allocator: allocator)
            XCTAssertEqual(resumed, [.rowFailure(requestID: row.id)])
            await backend.cancelInFlight()
            try await allocator.release(row.handle)
        }
    }

    func testDeepseekV4PipelinedSamplingKeepsRowLocalStepSeedsOnCPU() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = try tiny()
            let backend = DeepseekV4ContinuousBatchBackend(container: container(model))
            let referenceBackend = DeepseekV4ContinuousBatchBackend(container: container(model))
            let allocator = try PagedKVBlockAllocator(blockSizeTokens: 128, maxPhysicalBlocks: 8)
            let referenceAllocator = try PagedKVBlockAllocator(blockSizeTokens: 128, maxPhysicalBlocks: 8)
            var states: [FixtureRow] = []
            var references: [FixtureRow] = []
            for index in 0..<2 {
                let prompt = (0..<(9 + index * 4)).map { ($0 * 7 + index * 13 + 3) % 128 }
                states.append(try await prefill(id: "sample-\(index)", prompt: prompt, backend: backend, allocator: allocator))
                references.append(try await prefill(id: "sample-\(index)", prompt: prompt,
                    backend: referenceBackend, allocator: referenceAllocator))
            }
            let batched = try await window(states, steps: 5, temperature: 0.7, topP: 0.9,
                backend: backend, allocator: allocator)
            for _ in 0..<5 {
                let outcomes = try await window(references, steps: 1, temperature: 0.7, topP: 0.9,
                    backend: referenceBackend, allocator: referenceAllocator)
                for index in references.indices { references[index].generated += try tokens(outcomes[index]) }
            }
            for index in states.indices {
                states[index].generated += try tokens(batched[index])
                XCTAssertEqual(states[index].generated, references[index].generated)
                backend.finish(requestID: states[index].id)
                referenceBackend.finish(requestID: references[index].id)
                try await allocator.release(states[index].handle)
                try await referenceAllocator.release(references[index].handle)
            }
        }
    }

    private struct FixtureRow {
        let id: String
        let prompt: [Int]
        let handle: PagedKVBlockTableHandle
        var generated: [Int]
    }

    private func prefill(id: String, prompt: [Int], backend: DeepseekV4ContinuousBatchBackend,
                         allocator: PagedKVBlockAllocator) async throws -> FixtureRow {
        let handle = try await allocator.allocate(conversationKey: id, maxTokens: 128, initialTokens: 0)
        var offset = 0
        var first: Int?
        while offset < prompt.count {
            let end = DeepseekV4ContinuousBatchBackend.prefillEnd(offset: offset, promptCount: prompt.count)
            _ = try await allocator.extend(handle, by: end - offset)
            let binding = try await allocator.binding(for: handle)
            let outputs = try await backend.prefill(rows: [.init(requestID: id,
                promptTokens: Array(prompt[offset..<end]), binding: binding, promptTokenOffset: offset,
                committedKVTokenCount: offset, targetKVTokenCount: end, isFinalChunk: end == prompt.count)])
            XCTAssertNil(outputs.first?.failureCode)
            if end == prompt.count { first = outputs.first?.sampledToken }
            offset = end
        }
        return FixtureRow(id: id, prompt: prompt, handle: handle, generated: [try XCTUnwrap(first)])
    }

    private func window(_ states: [FixtureRow], steps: Int, stops: [String: [[Int]]] = [:],
                        temperature: Double = 0, topP: Double = 1,
                        backend: DeepseekV4ContinuousBatchBackend, allocator: PagedKVBlockAllocator,
                        onStep: ContinuousBatchDecodeWindowStepObserver? = nil) async throws -> [ContinuousBatchDecodeOutcome] {
        var inputs: [ContinuousBatchDecodeInput] = []
        for row in states {
            _ = try await allocator.extend(row.handle, by: steps)
            let binding = try await allocator.binding(for: row.handle)
            let committed = row.prompt.count + row.generated.count - 1
            inputs.append(.init(requestID: row.id, currentToken: try XCTUnwrap(row.generated.last),
                generatedTokens: row.generated, promptTokens: row.prompt, samplerSeed: 17,
                temperature: temperature, topP: topP, presencePenalty: 0, frequencyPenalty: 0,
                binding: binding, blockTable: binding.currentTable,
                committedKVTokenCount: committed, targetKVTokenCount: committed + steps,
                samplerStep: row.generated.count, stopTokenSequences: stops[row.id] ?? []))
        }
        return try await backend.decodeLockstepWindow(rows: inputs, steps: steps, onStep: onStep)
    }

    private func tokens(_ outcome: ContinuousBatchDecodeOutcome) throws -> [Int] {
        guard case .output(let output) = outcome else {
            XCTFail("Expected successful decode: \(outcome)")
            throw ContinuousBatchSchedulerError.unsupported("fixture_decode_failed")
        }
        return output.tokens
    }

    private func serial(_ model: DeepseekV4Model, prompt: [Int], count: Int) throws -> [Int] {
        let cache = try model.newCache(parameters: nil)
        var offset = 0
        var finalLogits: MLXArray?
        while offset < prompt.count {
            let end = DeepseekV4ContinuousBatchBackend.prefillEnd(offset: offset, promptCount: prompt.count)
            finalLogits = model(MLXArray(prompt[offset..<end].map(Int32.init)).reshaped([1, end - offset]), cache: cache)
            eval(cache)
            offset = end
        }
        var logits = try XCTUnwrap(finalLogits)
        var result: [Int] = []
        while result.count < count {
            let current = argMax(logits[0, -1], axis: -1).item(Int.self)
            eval(cache)
            result.append(current)
            if result.count < count {
                logits = model(MLXArray([Int32(current)]).reshaped([1, 1]), cache: cache)
            }
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
