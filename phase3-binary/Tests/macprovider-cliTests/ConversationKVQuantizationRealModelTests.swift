// #965 release gates for quantized reusable conversation KV on a real model.
//
// Heavy real-model fixture, skipped unless set:
//   MACPROVIDER_KV_QUANT_CONVERSATION_MODEL=<local full-attention model directory>
// (for example mlx-community/Llama-3.2-3B-Instruct-4bit from the local model store).
// The test host must load a complete MLX metallib (the release `mlx.metallib`).

import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import XCTest

@testable import MacProviderCore
@testable import macprovider_cli

final class ConversationKVQuantizationRealModelTests: XCTestCase {
    private static let modelID = "kv-quant-conversation-model"
    private static let fact = "7391"

    private func loadContainer() async throws -> ModelContainer {
        guard let directory = ProcessInfo.processInfo.environment["MACPROVIDER_KV_QUANT_CONVERSATION_MODEL"],
              !directory.isEmpty else {
            throw XCTSkip("set MACPROVIDER_KV_QUANT_CONVERSATION_MODEL to a local model directory")
        }
        return try await LLMModelFactory.shared.loadContainer(
            from: URL(fileURLWithPath: directory), using: #huggingFaceTokenizerLoader())
    }

    private func runtime(_ container: ModelContainer, kvBits: Int?) -> ModelRuntime {
        ModelRuntime(
            modelID: Self.modelID, maxContextTokensOverride: 8192, kvBitsOverride: kvBits,
            warmSwapEnabled: false, container: container, loader: { _ in throw CancellationError() })
    }

    /// Turn one carries ~1k tokens of filler with the fact near its end, so a
    /// cache that lost or misplaced late turn-one positions cannot answer.
    private static var turnOne: String {
        let filler = (1 ... 40).map { index in
            "Note \(index): the archive shelf \(index) holds ledgers about river trade, weather logs and harbour fees."
        }.joined(separator: " ")
        return filler + " Important, remember this exactly: the vault code is \(fact). Reply with the single word OK."
    }

    private static let turnTwo = "What is the vault code? Reply with the four digit number only."

    private static func request(_ messages: [[String: String]], key: String, maxTokens: Int = 24) throws -> ChatCompletionRequest {
        let body: [String: Any] = ["model": modelID, "messages": messages, "max_tokens": maxTokens, "temperature": 0]
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
            .withConversationKey(key)
    }

    private func assertLedger(
        _ runtime: ModelRuntime, key: String, cacheClass: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Int {
        let ledgerValue = await runtime.conversationCacheEntryLedgerForTest(conversationKey: key)
        let ledger = try XCTUnwrap(ledgerValue, "turn committed a hot entry", file: file, line: line)
        XCTAssertFalse(ledger.offsets.isEmpty, file: file, line: line)
        XCTAssertEqual(Set(ledger.offsets), [ledger.tokens], "cache offsets equal the canonical ledger", file: file, line: line)
        XCTAssertEqual(Set(ledger.classes), [cacheClass], file: file, line: line)
        return ledger.tokens
    }

    // Gates: two-turn recall with kvBits=8, offsets == ledger, hot reuse,
    // end-of-sequence termination commits no stale position.
    func testServeQuantizedConversationRecallsLateTurnOneFact() async throws {
        let container = try await loadContainer()
        let cases: [(kvBits: Int?, cacheClass: String)] = [(8, "QuantizedKVCache"), (nil, "KVCacheSimple")]
        for (kvBits, cacheClass) in cases {
            let runtime = runtime(container, kvBits: kvBits)
            let key = "conv:kv-quant-\(kvBits.map(String.init) ?? "fp16")"
            let first = try await runtime.complete(Self.request([["role": "user", "content": Self.turnOne]], key: key))
            XCTAssertEqual(first.finishReason, "stop", "turn one ends on the model's stop token")
            let firstLedger = try await assertLedger(runtime, key: key, cacheClass: cacheClass)
            XCTAssertGreaterThan(firstLedger, first.promptTokens)

            let second = try await runtime.complete(Self.request([
                ["role": "user", "content": Self.turnOne],
                ["role": "assistant", "content": first.content],
                ["role": "user", "content": Self.turnTwo],
            ], key: key))
            print("kv_bits=\(kvBits.map(String.init) ?? "nil") turn1=\(first.content.debugDescription) turn2=\(second.content.debugDescription) prompt=\(second.promptTokens) cached=\(second.cachedPromptTokens)")
            XCTAssertGreaterThan(second.cachedPromptTokens, first.promptTokens, "turn two reuses the hot turn-one cache")
            XCTAssertTrue(second.content.contains(Self.fact), "kv_bits=\(String(describing: kvBits)) recalled \(second.content)")
            _ = try await assertLedger(runtime, key: key, cacheClass: cacheClass)
        }
    }

    // Gate: a cancelled turn commits nothing, and the next turn is a clean miss.
    func testCancelledQuantizedTurnCommitsNoPartialCache() async throws {
        let container = try await loadContainer()
        let runtime = runtime(container, kvBits: 8)
        let key = "conv:kv-quant-cancel"
        let first = try await runtime.complete(Self.request([["role": "user", "content": Self.turnOne]], key: key))
        _ = try await assertLedger(runtime, key: key, cacheClass: "QuantizedKVCache")

        let messages = [
            ["role": "user", "content": Self.turnOne],
            ["role": "assistant", "content": first.content],
            ["role": "user", "content": "Write a long story about the archive shelves."],
        ]
        let polls = PollCounter()
        do {
            _ = try await runtime.complete(Self.request(messages, key: key, maxTokens: 400), shouldCancel: {
                polls.next() > 60
            })
            XCTFail("the cancelled turn must not complete")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? APIError) != nil, "\(error)")
        }
        let ledgerAfterCancelValue = await runtime.conversationCacheEntryLedgerForTest(conversationKey: key)
        XCTAssertNil(ledgerAfterCancelValue, "a cancelled turn leaves no hot entry")

        let retry = try await runtime.complete(Self.request(messages, key: key, maxTokens: 24))
        XCTAssertEqual(retry.cachedPromptTokens, 0, "the retry prefills from zero")
        _ = try await assertLedger(runtime, key: key, cacheClass: "QuantizedKVCache")
    }

    /// Why the serial path owns quantization: on the pinned mlx-swift-lm (3.32.3
    /// line, upstream PR #453) the iterator still quantizes into its own storage,
    /// so the caller's cache stops at the prompt (mlx-swift-lm #312), and the
    /// ledger check refuses it.
    func testIteratorOwnedQuantizationStillLeavesCallerCacheStale() async throws {
        let container = try await loadContainer()
        let result = try await container.perform { context -> (prompt: Int, generated: Int, offsets: [Int], quantized: Bool, accepted: Bool) in
            let input = try await context.processor.prepare(input: UserInput(chat: [.user(Self.turnOne)]))
            let cache = try context.model.newCache(parameters: GenerateParameters(maxKVSize: nil))
            let parameters = GenerateParameters(maxTokens: 16, kvBits: 8, temperature: 0)
            let iterator = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters)
            let generated = generate(input: input, context: context, iterator: iterator) { (_: [Int]) in GenerateDisposition.more }.tokenIds
            let prompt = input.text.tokens.size
            let accepted = ModelRuntime.reconcileConversationCacheLedger(
                cache, ledgerTokenCount: prompt + generated.count, terminalModelStopStripped: true)
            return (prompt, generated.count, cache.map(\.offset), cache.contains { $0 is QuantizedKVCache }, accepted)
        }
        print("iterator-owned kv_bits=8 prompt=\(result.prompt) generated=\(result.generated) caller_offsets=\(Set(result.offsets))")
        XCTAssertGreaterThan(result.generated, 0)
        XCTAssertFalse(result.quantized, "the caller's array never sees the iterator's quantized layers")
        XCTAssertTrue(result.offsets.allSatisfy { $0 < result.prompt + result.generated }, "caller cache misses generated tokens")
        XCTAssertFalse(result.accepted)
    }

    // Gate: encrypted cold-tier persist and promote of a real-model entry. A
    // cold-tier-eligible request keeps fp16 KV (SPEC-037), so this is the
    // representation the serial path persists while kvBits is configured.
    func testColdTierEligibleConversationPersistsAndPromotesRealModelEntry() async throws {
        let container = try await loadContainer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-quant-cold-real-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = KVDiskCacheStoreConfig(
            root: root, namespaceID: "ns-kv-quant-real",
            maxBytes: 1 << 30, maxEntries: 8, maxEntryBytes: 512 << 20,
            retentionSeconds: 3600, stagingMaxBytes: 1 << 30,
            writeStagingMaxBytes: 1 << 30, minFreeBytes: 1024,
            promotionMaxSeconds: 30, eligibilityTTLSeconds: 900)
        config.freeSpaceOverride = 1 << 40
        let store = KVDiskCacheStore(config: config, keychain: KVInMemoryKeychain(), sink: KVRecordingEventSink())
        try await store.activate()
        let adapter = KVConversationColdTierAdapter(
            store: store, namespaceID: "ns-kv-quant-real", eligibilityTTLSeconds: 900,
            writeStagingMaxBytes: config.writeStagingMaxBytes, maxEntryBytes: config.maxEntryBytes,
            stagingMaxBytes: config.stagingMaxBytes)
        adapter.cacheEpoch(await store.currentEpoch)
        let identity = KVIdentityCore(
            requestModel: Self.modelID, servedModelID: Self.modelID, modelSHA256: String(repeating: "b", count: 64),
            catalogRevision: "r1", tokenizerID: Self.modelID, tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), kvBits: nil, kvGroupSize: nil,
            kvQuantMode: nil, kvQuantPolicy: nil)
        let key = "conv:kvs-synth:kv-quant-real"
        XCTAssertNil(ModelRuntime.effectiveKVBits(
            configured: 8, conversationKey: key, serialQuantizedConversation: false), "cold-eligible stays fp16")

        let turnOne = try await container.perform { context -> (tokens: [Int32], reply: String, snapshot: ConversationColdSnapshot?) in
            let input = try await context.processor.prepare(input: UserInput(chat: [.user(Self.turnOne)]))
            let cache = try context.model.newCache(parameters: GenerateParameters(maxKVSize: nil))
            let iterator = try TokenIterator(
                input: input, model: context.model, cache: cache,
                parameters: GenerateParameters(maxTokens: 24, temperature: 0))
            let generated = generate(input: input, context: context, iterator: iterator) { (_: [Int]) in GenerateDisposition.more }
            let tokens = input.text.tokens.asArray(Int32.self) + generated.tokenIds.map(Int32.init)
            XCTAssertTrue(ModelRuntime.reconcileConversationCacheLedger(
                cache, ledgerTokenCount: tokens.count, terminalModelStopStripped: true))
            let snapshot = adapter.captureSnapshot(
                conversationKey: key, layers: ConversationCacheLayers(cache), fullTokens: tokens,
                sampledPurgeGeneration: 0, identity: identity, nowMillis: Int(Date().timeIntervalSince1970 * 1000))
            return (tokens, generated.output, snapshot)
        }
        let snapshot = try XCTUnwrap(turnOne.snapshot, "an fp16 KVCacheSimple entry is captured")
        let write = try await store.writeColdSnapshot(
            rawKey: snapshot.rawKey, tokens: snapshot.tokens, layers: snapshot.layers,
            layersV2: snapshot.layersV2, recurrentCheckpoints: snapshot.recurrentCheckpoints,
            identity: snapshot.identity, sampledPurgeGeneration: snapshot.sampledPurgeGeneration,
            commitSequence: snapshot.commitSequence, createdAtMillis: snapshot.createdAtMillis,
            eligibleUntilMillis: snapshot.eligibleUntilMillis, incarnation: snapshot.incarnation,
            nowMillis: Int(Date().timeIntervalSince1970 * 1000))
        adapter.releaseWriteLive(snapshot.reservedWriteBytes)
        guard case .committed = write else { return XCTFail("cold write must commit, got \(write)") }

        let promoted = await adapter.promoteCandidate(conversationKey: key, identity: identity)
        await store.deactivate()
        let candidate = try XCTUnwrap(promoted, "the persisted entry promotes")
        XCTAssertEqual(candidate.canonicalTokens, turnOne.tokens)

        let reply = turnOne.reply
        let answer = try await container.perform { context -> String in
            let input = try await context.processor.prepare(input: UserInput(chat: [
                .user(Self.turnOne), .assistant(reply), .user(Self.turnTwo),
            ]))
            let incoming = input.text.tokens.asArray(Int32.self)
            let layers = candidate.layers.layers
            let lcp = ConversationCache.longestCommonPrefix(candidate.canonicalTokens, incoming)
            XCTAssertGreaterThan(lcp, Self.turnOne.count / 8)
            for layer in layers {
                XCTAssertEqual(layer.trim(candidate.canonicalTokens.count - lcp), candidate.canonicalTokens.count - lcp)
            }
            let rest = LMInput(tokens: MLXArray(Array(incoming[lcp...])))
            let iterator = try TokenIterator(
                input: rest, model: context.model, cache: layers,
                parameters: GenerateParameters(maxTokens: 16, temperature: 0))
            return generate(input: rest, context: context, iterator: iterator) { (_: [Int]) in GenerateDisposition.more }.output
        }
        print("cold promoted turn2=\(answer.debugDescription)")
        XCTAssertTrue(answer.contains(Self.fact), "promoted cache recalled \(answer)")
    }
}

private final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
