import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Character-level tokenizer over a 97-token vocabulary: id i is the printable
/// ASCII character 32 + i. The chat template is "role: content\n" per message,
/// then "assistant: ".
struct ShardTestTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        text.unicodeScalars.map { scalar in (0x20...0x7E).contains(scalar.value) ? Int(scalar.value) - 0x20 : 0 }
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(String.UnicodeScalarView(tokenIds.map { Unicode.Scalar(UInt8(0x20 + ($0 % 95))) }))
    }

    func convertTokenToId(_ token: String) -> Int? { encode(text: token, addSpecialTokens: false).first }
    func convertIdToToken(_ id: Int) -> String? { decode(tokenIds: [id], skipSpecialTokens: false) }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let text = messages.map { "\($0["role"] as? String ?? ""): \($0["content"] as? String ?? "")\n" }.joined() + "assistant: "
        return encode(text: text, addSpecialTokens: false)
    }
}

/// Runs every stage call on the CPU device; the engine and stage threads do not
/// inherit a task's default device.
final class CPUShardStage<Inner: ShardBenchStage>: ShardBenchStage {
    let inner: Inner
    init(_ inner: Inner) { self.inner = inner }

    var modelType: String { inner.modelType }
    var hiddenSize: Int { inner.hiddenSize }
    var layers: Range<Int> { inner.layers }
    var totalLayers: Int { inner.totalLayers }
    var weightBytes: Int { inner.weightBytes }

    func newCache() throws -> Inner.Cache { try Device.withDefaultDevice(.cpu) { try inner.newCache() } }
    func forward(tokens: [Int], cache: Inner.Cache) throws -> ShardBenchActivation {
        try Device.withDefaultDevice(.cpu) { try inner.forward(tokens: tokens, cache: cache) }
    }
    func forward(activation: ShardBenchActivation, cache: Inner.Cache) throws -> ShardBenchActivation {
        try Device.withDefaultDevice(.cpu) { try inner.forward(activation: activation, cache: cache) }
    }
    func makeSampler(_ control: ShardRequestControl) -> Inner.Sampler { inner.makeSampler(control) }
    func sample(activation: ShardBenchActivation, cache: Inner.Cache, sampler: Inner.Sampler) throws -> Int {
        try Device.withDefaultDevice(.cpu) { try inner.sample(activation: activation, cache: cache, sampler: sampler) }
    }
    func fill(activation: ShardBenchActivation, cache: Inner.Cache) throws {
        try Device.withDefaultDevice(.cpu) { try inner.fill(activation: activation, cache: cache) }
    }
    func summarize(activation: ShardBenchActivation, cache: Inner.Cache, topK: Int) throws -> ShardLogitSummary {
        try Device.withDefaultDevice(.cpu) { try inner.summarize(activation: activation, cache: cache, topK: topK) }
    }
}

final class ShardGroupRuntimeTests: XCTestCase {
    private let modelID = "lab/shard-test"
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func prompting(eos: Set<Int> = []) -> ShardGroupRuntime.Prompting {
        ShardGroupRuntime.Prompting(
            tokenizer: ShardTestTokenizer(), eosTokenIDs: eos, stopFilter: StopTokenFilter(tokens: []),
            templateSupportsThinkingToggle: false, templateSupportsPreserveThinking: false)
    }

    private func request(_ content: String, maxTokens: Int = 8, extra: [String: Any] = [:]) throws -> ChatCompletionRequest {
        var body: [String: Any] = ["model": modelID, "max_tokens": maxTokens, "temperature": 0,
                                   "messages": [["role": "user", "content": content]]]
        for (key, value) in extra { body[key] = value }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body)).withRequestID("req_test_1")
    }

    /// A two-stage group of fake stages: the runtime's engine connects to a tail
    /// session on a loopback link each time it (re)connects.
    private func fakeRuntime(
        modelHash: String? = String(repeating: "a", count: 64),
        gate: ShardGroupServingGate = .notRequired,
        tailOnCall: ((Int, ShardStageLink) -> Void)? = nil
    ) async throws -> (ShardGroupRuntime, FakeShardStage) {
        let tail = FakeShardStage(layers: 2..<4, totalLayers: 4)
        let head = FakeShardStage(layers: 0..<2, totalLayers: 4)
        let runtime = ShardGroupRuntime(
            identity: ShardGroupRuntime.Identity(
                modelID: modelID, modelHash: modelHash, modelHashAlgorithm: modelHash == nil ? nil : ModelArtifactIdentity.snapshotManifestV1,
                weightsManifestSHA256: nil, catalogModelIDAlias: nil),
            prompting: prompting(), maxContextTokens: 4096, gate: gate,
            connect: { _ in
                let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
                if let tailOnCall { tail.onCall = { tailOnCall($0, links[1].upstream) } }
                let session = ShardBenchSession(options: ShardBenchTestRig.options(role: .tail, prompts: [], tokens: 1), stage: tail)
                Thread { _ = try? session.run(links: links[1]) }.start()
                let engine = ShardGroupEngine(stage: head, options: ShardGroupEngineTests.options())
                try engine.start(links: links[0])
                return engine
            })
        try await runtime.start()
        return (runtime, tail)
    }

    private func collectStream(
        _ runtime: ShardGroupRuntime, _ request: ChatCompletionRequest, cancelAfter: Int? = nil
    ) async throws -> (chunks: [String], result: CompletionResult) {
        let chunks = ShardChunkBox()
        let handle = try await runtime.acquireRequestHandle(request)
        try await runtime.preflight(request, with: handle)
        let result = try await runtime.stream(request, with: handle, shouldCancel: {
            cancelAfter.map { chunks.count >= $0 } ?? false
        }) { chunk in
            if case .content(let text) = chunk { chunks.append(text) }
        }
        return (chunks.all, result)
    }

    func testStreamsDetokenizedReferenceTokensWithUsageAndSignedEvidence() async throws {
        let (runtime, _) = try await fakeRuntime()
        let request = try request("hello group", maxTokens: 9)
        let promptTokens = try ShardGroupRuntime.promptTokens(for: request, prompting: prompting())
        let reference = try ShardBenchTestRig.reference(splits: [0..<2, 2..<4], total: 4, prompts: [promptTokens], tokens: 9)[0]
        let (chunks, result) = try await collectStream(runtime, request)
        XCTAssertEqual(chunks.joined(), ShardTestTokenizer().decode(tokenIds: reference, skipSpecialTokens: false))
        XCTAssertEqual(result.content, chunks.joined())
        XCTAssertEqual(result.finishReason, "length")
        XCTAssertEqual(result.promptTokens, promptTokens.count)
        XCTAssertEqual(result.completionTokens, 9)
        XCTAssertEqual(result.settlementDisposition, .eligibleOwner)
        let evidence = try XCTUnwrap(result.shardGroupEvidence)
        XCTAssertEqual(evidence.attestation.verdict, "ok")
        XCTAssertEqual(evidence.tokenSteps, 9)
        XCTAssertEqual(evidence.attestation.receipts.map(\.receipt.requestID), ["req_test_1", "req_test_1"])
        await runtime.stop()
    }

    func testStopSequenceEndsTheStreamBeforeIt() async throws {
        let (runtime, _) = try await fakeRuntime()
        let full = try await collectStream(runtime, try request("stop test", maxTokens: 12)).result.content
        // Stop on two characters from the middle of the uninterrupted output.
        let start = full.index(full.startIndex, offsetBy: 5)
        let stop = String(full[start..<full.index(start, offsetBy: 2)])
        let firstStop = try XCTUnwrap(full.range(of: stop))
        let expected = String(full[..<firstStop.lowerBound])
        let (chunks, result) = try await collectStream(runtime, try request("stop test", maxTokens: 12, extra: ["stop": [stop]]))
        XCTAssertEqual(result.content, expected)
        XCTAssertEqual(chunks.joined(), expected, "nothing after the stop reaches the buyer")
        XCTAssertEqual(result.finishReason, "stop")
        await runtime.stop()
    }

    func testCallerCancelReturnsTheDeliveredPrefix() async throws {
        let (runtime, tail) = try await fakeRuntime()
        tail.computeDelay = 0.02
        let (chunks, result) = try await collectStream(runtime, try request("cancel me", maxTokens: 400), cancelAfter: 3)
        XCTAssertEqual(result.finishReason, "cancelled")
        XCTAssertEqual(result.content, chunks.joined())
        XCTAssertLessThan(result.completionTokens, 400)
        XCTAssertEqual(result.shardGroupEvidence?.attestation.verdict, "ok")
        await runtime.stop()
    }

    func testStageLossMapsToRetryableOrExplicitBuyerErrors() async throws {
        // Lost on the tail's first compute: nothing was delivered, the attempt is retryable.
        let (early, _) = try await fakeRuntime(tailOnCall: { call, link in if call == 1 { link.close() } })
        do {
            _ = try await collectStream(early, try request("early loss"))
            XCTFail("expected a shard group failure")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "shard_group_failed")
            XCTAssertEqual(error.status, 503)
            XCTAssertEqual(error.retryableOverride, true)
        }
        await early.stop()

        // Lost after three tokens: the stream ends with an explicit, non-retryable error.
        let (late, _) = try await fakeRuntime(tailOnCall: { call, link in if call == 4 { link.close() } })
        let chunks = ShardChunkBox()
        let request = try request("late loss", maxTokens: 20)
        let handle = try await late.acquireRequestHandle(request)
        do {
            _ = try await late.stream(request, with: handle, shouldCancel: { false }) { chunk in
                if case .content(let text) = chunk { chunks.append(text) }
            }
            XCTFail("expected a shard group failure")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "shard_group_failed")
            XCTAssertEqual(error.status, 502)
            XCTAssertEqual(error.retryableOverride, false)
            XCTAssertTrue(error.message.contains("after 3 tokens"), error.message)
        }
        XCTAssertEqual(chunks.all.joined().count, 3, "the delivered tokens stand")
        await late.stop()
    }

    func testCoordinatorGateHoldsNetworkBuyersButNotLocalOnes() async throws {
        let (runtime, _) = try await fakeRuntime(gate: .awaitingCoordinator)
        let request = try request("gate")
        do {
            _ = try await runtime.acquireRequestHandle(request)
            XCTFail("network buyers wait for the coordinator")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "shard_group_unavailable")
        }
        _ = try await runtime.acquireLocalRequestHandle(request)
        await runtime.setGate(.available)
        _ = try await runtime.acquireRequestHandle(request)
        await runtime.stop()
    }

    func testUnsupportedFeaturesAreRefusedNotIgnored() async throws {
        let (runtime, _) = try await fakeRuntime()
        let tools: [[String: Any]] = [["type": "function", "function": ["name": "f", "parameters": ["type": "object"]]]]
        for (extra, code) in [
            (["tools": tools] as [String: Any], "shard_group_tools_unsupported"),
            (["presence_penalty": 0.5], "shard_group_sampling_unsupported"),
            (["response_format": ["type": "json_object"]], "shard_group_response_format_unsupported"),
        ] {
            do {
                _ = try await runtime.prepare(try request("x", extra: extra))
                XCTFail("expected \(code)")
            } catch let error as APIError {
                XCTAssertEqual(error.code, code)
            }
        }
        let prepared = try await runtime.prepare(try request("x", extra: ["seed": 7, "temperature": 0.5, "top_p": 0.8]))
        XCTAssertEqual(prepared.control, ShardRequestControl(temperature: 0.5, topP: 0.8, seed: 7))
        await runtime.stop()
    }

    /// SPEC-018 §3.12 on a shard group: with an open `<think>` the output up to
    /// `</think>` is reasoning, stop sequences apply only after it, and the
    /// answer's leading whitespace is dropped.
    func testOpenThinkSplitsReasoningAndAppliesStopsOnlyToTheAnswer() {
        let tokenizer = ShardTestTokenizer()
        func run(_ text: String, reasoningOpen: Bool) -> (ShardStreamingText.Released, ShardStreamingText) {
            var output = ShardStreamingText(
                tokenizer: tokenizer, stops: ["STOP"], stopFilter: StopTokenFilter(tokens: []), reasoningOpen: reasoningOpen)
            var total = ShardStreamingText.Released()
            for token in tokenizer.encode(text: text, addSpecialTokens: false) {
                let released = output.append(token)
                total.reasoning += released.reasoning
                total.content += released.content
            }
            let rest = output.finish()
            total.reasoning += rest.reasoning
            total.content += rest.content
            return (total, output)
        }

        let (split, splitOutput) = run("plan STOP</think>  answer STOP tail", reasoningOpen: true)
        XCTAssertEqual(split, ShardStreamingText.Released(reasoning: "plan STOP", content: "answer "))
        XCTAssertTrue(splitOutput.stopped)
        XCTAssertEqual(splitOutput.reasoningTokens, "plan STOP</think>".count)

        let (unclosed, unclosedOutput) = run("still thinking </thi", reasoningOpen: true)
        XCTAssertEqual(unclosed, ShardStreamingText.Released(reasoning: "still thinking </thi", content: ""))
        XCTAssertEqual(unclosedOutput.reasoningTokens, "still thinking </thi".count)

        let (plain, plainOutput) = run("  a</think>b STOP c", reasoningOpen: false)
        XCTAssertEqual(plain, ShardStreamingText.Released(reasoning: "", content: "  a</think>b "))
        XCTAssertEqual(plainOutput.reasoningTokens, 0)
    }

    func testWithoutAVerifiedCatalogArtifactNothingIsReceiptEligible() async throws {
        let (runtime, _) = try await fakeRuntime(modelHash: nil)
        XCTAssertFalse(runtime.isSettlementReceiptEligible)
        let result = try await collectStream(runtime, try request("lab", maxTokens: 2)).result
        XCTAssertEqual(result.settlementDisposition, .notEligible)
        await runtime.stop()
    }

    func testAFailedChainIsReconnectedInTheBackground() async throws {
        // The tail's call count runs on across sessions: only the first session's
        // first compute loses the link.
        let (runtime, _) = try await fakeRuntime(tailOnCall: { call, link in if call == 1 { link.close() } })
        _ = try? await collectStream(runtime, try request("first fails"))
        var reconnected = false
        for _ in 0..<50 where !reconnected {
            try await Task.sleep(nanoseconds: 100_000_000)
            reconnected = await runtime.engineStatus?.running == true
        }
        XCTAssertTrue(reconnected)
        let second = try await collectStream(runtime, try request("second works", maxTokens: 3))
        XCTAssertEqual(second.result.completionTokens, 3)
        await runtime.stop()
    }

    // MARK: Tiny random-weight model: the OpenAI path against shard-bench

    private func checkpoint() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shard-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let config: [String: Any] = [
            "model_type": "llama", "hidden_size": 64, "num_hidden_layers": 4, "intermediate_size": 96,
            "num_attention_heads": 4, "num_key_value_heads": 2, "rms_norm_eps": 1e-5, "vocab_size": 97,
            "tie_word_embeddings": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: config)
        try data.write(to: directory.appendingPathComponent("config.json"))
        try await Device.withDefaultDevice(.cpu) {
            let created = try await LLMTypeRegistry.shared.createModel(configuration: data, modelType: "llama")
            let model = try XCTUnwrap(created as? any LLMModel)
            MLXRandom.seed(2084)
            var weights = [String: MLXArray]()
            for (key, value) in model.parameters().flattened() {
                let noise = MLXRandom.normal(value.shape) * 0.1
                weights[key] = key.hasSuffix("norm.weight") ? 1 + noise : noise
            }
            eval(Array(weights.values))
            try save(arrays: weights, url: directory.appendingPathComponent("model.safetensors"))
        }
        return directory
    }

    private func stages(_ directory: URL) async throws -> (CPUShardStage<PipelineStageModel>, CPUShardStage<PipelineStageModel>) {
        try await Device.withDefaultDevice(.cpu) {
            (CPUShardStage(try await PipelineStageModel.load(directory: directory, layers: 0..<2)),
             CPUShardStage(try await PipelineStageModel.load(directory: directory, layers: 2..<4)))
        }
    }

    func testOpenAIStreamingPathProducesTheSameTokensAsShardBench() async throws {
        let directory = try await checkpoint()
        let request = try request("Explain pipelines.", maxTokens: 10)
        let promptTokens = try ShardGroupRuntime.promptTokens(for: request, prompting: prompting())

        // shard-bench over its own stages: head and tail sessions on a loopback link.
        let (benchHead, benchTail) = try await stages(directory)
        let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
        let tailBox = ShardBenchResultBox(count: 1)
        let tailDone = DispatchSemaphore(value: 0)
        let tailSession = ShardBenchSession(options: ShardBenchTestRig.options(role: .tail, prompts: [promptTokens], tokens: 10), stage: benchTail)
        Thread {
            tailBox.set(0, Result { try tailSession.run(links: links[1]) })
            tailDone.signal()
        }.start()
        let headSession = ShardBenchSession(
            options: ShardBenchTestRig.options(role: .head, prompts: [promptTokens], tokens: 10), stage: benchHead)
        let benchReport = try await ShardBenchThread.run { try headSession.run(links: links[0]) }
        _ = tailDone.wait(timeout: .now() + 20)
        let benchTokens = try XCTUnwrap(benchReport.head?.sequenceTokens.first)

        // The runtime over fresh stages of the same checkpoint.
        let (head, tail) = try await stages(directory)
        let runtime = ShardGroupRuntime(
            identity: ShardGroupRuntime.Identity(modelID: modelID, modelHash: nil, modelHashAlgorithm: nil, weightsManifestSHA256: nil, catalogModelIDAlias: nil),
            prompting: prompting(), maxContextTokens: 512, gate: .notRequired,
            connect: { _ in
                let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
                let session = ShardBenchSession(options: ShardBenchTestRig.options(role: .tail, prompts: [], tokens: 1), stage: tail)
                Thread { _ = try? session.run(links: links[1]) }.start()
                let engine = ShardGroupEngine(stage: head, options: ShardGroupEngineTests.options())
                try engine.start(links: links[0])
                return engine
            })
        try await runtime.start()
        let (chunks, result) = try await collectStream(runtime, request)
        XCTAssertEqual(chunks.joined(), ShardTestTokenizer().decode(tokenIds: benchTokens, skipSpecialTokens: false))
        XCTAssertEqual(result.completionTokens, benchTokens.count)
        XCTAssertEqual(result.shardGroupEvidence?.attestation.verdict, "ok")
        await runtime.stop()
    }
}

final class ShardChunkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks = [String]()

    func append(_ chunk: String) {
        lock.lock()
        chunks.append(chunk)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunks.count
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}

/// `serve --shard-member`: the member's stage server outlives its sessions, and its
/// runtime takes no buyer request.
final class ShardMemberRuntimeTests: XCTestCase {
    private func memberConfig(frameProtection: ShardFrameProtection = .crc32c) -> ShardMemberConfig {
        ShardMemberConfig(
            groupProviderID: "head-device", groupEpoch: ShardBenchTestRig.epoch, stageIndex: 1, layerStart: 2, layerEnd: 4,
            listen: "127.0.0.1:0", frameProtection: frameProtection, maxSequences: 8,
            supervision: ShardSupervisionConfig(
                heartbeatIntervalMilliseconds: 50, heartbeatMissLimit: 4, decodeHopDeadlineMilliseconds: 2000,
                prefillChunkDeadlineMilliseconds: 3000, replayDeadlineMilliseconds: 5000))
    }

    private func runOneRequest(
        port: UInt16, prompt: [Int], protection: ShardLinkFrameProtection = .crc32c
    ) throws -> ShardGenerationSummary {
        var options = ShardGroupEngineTests.options()
        options.link.frameProtection = protection
        let links = try ShardBenchLinks.open(
            listen: nil, connect: ShardBenchEndpoint(host: "127.0.0.1", port: port), connectTimeout: 5,
            configuration: options.link, session: "test", signer: options.signer)
        options.expectedMembers = [ShardGroupExpectedMember(memberDeviceID: "mac-b", layers: 2..<4)]
        options.modelDigest = "digest"
        let engine = ShardGroupEngine(stage: FakeShardStage(layers: 0..<2, totalLayers: 4), options: options)
        try engine.start(links: links)
        let collector = ShardGenerationCollector(count: 1)
        let ids = try engine.submit([ShardGenerationRequest(promptTokens: prompt, maxTokens: 4)], sink: collector.receive)
        let (summaries, errors) = collector.wait()
        try engine.shutdown()
        if let error = errors[ids[0]] { throw error }
        return try XCTUnwrap(summaries[ids[0]])
    }

    func testMemberServesSuccessiveHeadsAndSignsWithItsKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let server = ShardMemberStageServer(
            stage: FakeShardStage(layers: 2..<4, totalLayers: 4), config: memberConfig(),
            signer: ShardMemberSigner(memberDeviceID: "mac-b", key: key), modelDigest: "digest", modelLabel: "fake")
        try server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let reference = try ShardBenchTestRig.reference(splits: [0..<2, 2..<4], total: 4, prompts: [[4, 5, 6]], tokens: 4)[0]
        for _ in 0..<2 {
            let summary = try runOneRequest(port: port, prompt: [4, 5, 6])
            XCTAssertEqual(summary.tokens, reference)
            XCTAssertEqual(summary.attestation.verdict, "ok")
            XCTAssertEqual(summary.attestation.receipts.last?.publicKey, key.publicKey.rawRepresentation.base64EncodedString())
        }
        var status = server.status
        for _ in 0..<50 where status.sessionsServed < 2 {
            Thread.sleep(forTimeInterval: 0.05)
            status = server.status
        }
        XCTAssertEqual(status.sessionsServed, 2, "a session's end leaves the member listening")
        XCTAssertTrue(status.listening)
        XCTAssertNil(status.lastError)
    }

    func testHMACMemberAuthenticatesTheHeadAndServes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let server = ShardMemberStageServer(
            stage: FakeShardStage(layers: 2..<4, totalLayers: 4), config: memberConfig(frameProtection: .hmacSHA256),
            signer: ShardMemberSigner(memberDeviceID: "mac-b", key: key), modelDigest: "digest", modelLabel: "fake")
        try server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let reference = try ShardBenchTestRig.reference(splits: [0..<2, 2..<4], total: 4, prompts: [[4, 5, 6]], tokens: 4)[0]
        let summary = try runOneRequest(port: port, prompt: [4, 5, 6], protection: .hmacSHA256)
        XCTAssertEqual(summary.tokens, reference)
        XCTAssertEqual(summary.attestation.verdict, "ok")
        // A head that does not run the key agreement never reaches the member's stage.
        XCTAssertThrowsError(try runOneRequest(port: port, prompt: [4, 5, 6], protection: .crc32c))
        var status = server.status
        for _ in 0..<50 where status.lastError == nil {
            Thread.sleep(forTimeInterval: 0.05)
            status = server.status
        }
        XCTAssertTrue(status.lastError?.contains("key agreement") == true, "\(status.lastError ?? "nil")")
        XCTAssertTrue(status.listening, "a refused head leaves the member listening")
    }

    func testMemberReportsItsPeersAndLinkInterfacesWhileJoined() throws {
        let server = ShardMemberStageServer(
            stage: FakeShardStage(layers: 2..<4, totalLayers: 4), config: memberConfig(),
            signer: ShardMemberSigner(memberDeviceID: "mac-b", key: Curve25519.Signing.PrivateKey()), modelDigest: "digest",
            modelLabel: "fake")
        try server.start()
        defer { server.stop() }
        let options = ShardGroupEngineTests.options()
        let links = try ShardBenchLinks.open(
            listen: nil, connect: ShardBenchEndpoint(host: "127.0.0.1", port: try XCTUnwrap(server.port)), connectTimeout: 5,
            configuration: ShardBenchTestRig.configuration(), session: "test", signer: options.signer)
        let engine = ShardGroupEngine(stage: FakeShardStage(layers: 0..<2, totalLayers: 4), options: options)
        try engine.start(links: links)
        var status = server.status
        for _ in 0..<50 where status.stageIndex == nil {
            Thread.sleep(forTimeInterval: 0.02)
            status = server.status
        }
        XCTAssertEqual(status.stageIndex, 1)
        XCTAssertEqual(status.upstreamPeer, "head-device")
        XCTAssertEqual(status.downstreamPeer, "head-device", "a two-stage tail returns tokens to the head")
        XCTAssertEqual(status.upstreamInterface, ShardLinkInterface.other, "loopback is no admissible interconnect")
        XCTAssertEqual(engine.chain.last?.upstreamInterface, ShardLinkInterface.other)
        // SPEC-051-R015: the member's own report of itself and its link to the head.
        let report = try XCTUnwrap(server.healthReport)
        XCTAssertTrue(report.healthy)
        XCTAssertEqual(report.reason, "")
        XCTAssertEqual(report.links.map(\.peer), ["head-device"])
        XCTAssertEqual(report.links.map(\.interfaceType), [ShardLinkInterface.other])
        try engine.shutdown()
        var after = server.healthReport
        for _ in 0..<50 where after != nil {
            Thread.sleep(forTimeInterval: 0.02)
            after = server.healthReport
        }
        XCTAssertNil(after, "no report without a head session")
    }

    func testMemberRefusesAStageThatDoesNotMatchItsConfig() {
        let server = ShardMemberStageServer(
            stage: FakeShardStage(layers: 1..<4, totalLayers: 4), config: memberConfig(),
            signer: ShardMemberSigner(memberDeviceID: "mac-b", key: Curve25519.Signing.PrivateKey()), modelDigest: nil,
            modelLabel: "fake")
        XCTAssertThrowsError(try server.start())
    }

    func testMemberRuntimeTakesNoBuyerRequest() async throws {
        let server = ShardMemberStageServer(
            stage: FakeShardStage(layers: 2..<4, totalLayers: 4), config: memberConfig(),
            signer: ShardMemberSigner(memberDeviceID: "mac-b", key: Curve25519.Signing.PrivateKey()), modelDigest: nil,
            modelLabel: "fake")
        let runtime = ShardMemberRuntime(
            config: memberConfig(),
            identity: ShardGroupRuntime.Identity(modelID: "m", modelHash: nil, modelHashAlgorithm: nil, weightsManifestSHA256: nil, catalogModelIDAlias: nil),
            memberDeviceID: "mac-b", server: server,
            stageProof: ShardGroupServe.StageProof(
                digest: "d", weightsVerified: true,
                fit: ShardStageArtifact.Fit(stageWeightBytes: 1, kvBudgetBytes: 2, kvDemandBytes: 1)))
        let request = try ChatCompletionRequest.parse(data: Data(#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#.utf8))
        for attempt in 0..<2 {
            do {
                _ = attempt == 0 ? try await runtime.acquireRequestHandle(request) : try await runtime.acquireLocalRequestHandle(request)
                XCTFail("a member is never routable")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "shard_member_not_routable")
            }
        }
        XCTAssertFalse(runtime.isSettlementReceiptEligible)
    }
}

final class ShardGroupConfigTests: XCTestCase {
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    private let supervision: [String: Any] = [
        "heartbeat_interval_ms": 100, "heartbeat_miss_limit": 3, "decode_hop_deadline_ms": 500,
        "prefill_chunk_deadline_ms": 3000, "replay_deadline_ms": 10000,
    ]

    private func head(_ changes: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = [
            "schema": "macprovider.shard-group-config.v1", "group_epoch": 1, "interconnect_class": "thunderbolt-ip",
            "frame_protection": "crc32c", "head_layer_end": 14,
            "stages": [["member_device_id": "mac-b", "endpoint": "169.254.1.2:7101", "layer_start": 14, "layer_end": 28]],
            "max_concurrency": 4, "supervision": supervision,
        ]
        for (key, value) in changes { object[key] = value }
        return object
    }

    private func loadHead(_ object: [String: Any]) throws -> ShardGroupHeadConfig {
        let config = try JSONDecoder().decode(ShardGroupHeadConfig.self, from: json(object))
        try config.validate()
        return config
    }

    func testValidHeadConfigNamesItsMembersAndLayers() throws {
        let config = try loadHead(head(["pool_model_id": "pool/ijUnc-ZQf-LJeRvkhi-0iQ/llama-3b", "prefill_chunk_tokens": 256]))
        XCTAssertEqual(config.numLayers, 28)
        XCTAssertEqual(config.expectedMembers, [ShardGroupExpectedMember(memberDeviceID: "mac-b", layers: 14..<28)])
        XCTAssertEqual(config.supervision.link(epoch: 1).heartbeatInterval, 0.1)
    }

    func testHeadConfigRefusals() {
        let cases: [([String: Any], String)] = [
            (head(["extra": 1]), "unknown keys"),
            (head(["interconnect_class": "rdma-tb5"]), "reserved"),
            (head(["frame_protection": "aead-chacha20poly1305"]), "not implemented"),
            (head(["interconnect_class": "ethernet"]), "below the hmac-sha256 minimum"),
            (head(["supervision": supervision.merging(["heartbeat_interval_ms": 5]) { $1 }]), "heartbeat_interval_ms"),
            (head(["stages": [["member_device_id": "mac-b", "endpoint": "h:1", "layer_start": 15, "layer_end": 28]]]), "must start at 14"),
            (head(["stages": [
                ["member_device_id": "mac-b", "endpoint": "h:1", "layer_start": 14, "layer_end": 20],
                ["member_device_id": "mac-c", "endpoint": "h:2", "layer_start": 20, "layer_end": 28],
            ]]), "return_listen"),
            (head(["spare": ["member_device_id": "mac-b", "endpoint": "h:3"]]), "also an active member"),
            (head(["max_concurrency": 0]), "max_concurrency"),
            (head(["pool_model_id": "pm_1"]), "not a SPEC-042-R015 pool model id"),
            (head(["stages": [["member_device_id": "bad id", "endpoint": "h:1", "layer_start": 14, "layer_end": 28]]]), "must match"),
        ]
        for (object, fragment) in cases {
            XCTAssertThrowsError(try loadHead(object), fragment) { error in
                XCTAssertTrue(String(describing: error).contains(fragment), "\(fragment): \(error)")
            }
        }
    }

    func testMemberConfigAndSpareEpoch() throws {
        var object: [String: Any] = [
            "schema": "macprovider.shard-member-config.v1", "group_provider_id": "mac-a", "group_epoch": 3, "role": "spare",
            "stage_index": 1, "layer_start": 14, "layer_end": 28, "listen": "0.0.0.0:7101",
            "interconnect_class": "thunderbolt-ip", "max_sequences": 8, "supervision": supervision,
        ]
        let config = try JSONDecoder().decode(ShardMemberConfig.self, from: json(object))
        try config.validate()
        XCTAssertEqual(config.linkEpoch, 4, "a spare runs at the epoch the head starts when it replaces a stage")
        object["stage_index"] = 0
        let head = try JSONDecoder().decode(ShardMemberConfig.self, from: json(object))
        XCTAssertThrowsError(try head.validate())
        object["stage_index"] = 1
        object["unknown_key"] = 1
        XCTAssertThrowsError(try JSONDecoder().decode(ShardMemberConfig.self, from: json(object)))
        object["unknown_key"] = nil
        // SPEC-051-R011: frame protection defaults to the class minimum and never below it.
        XCTAssertEqual(config.frameProtection, .crc32c)
        object["interconnect_class"] = "ethernet"
        let ethernet = try JSONDecoder().decode(ShardMemberConfig.self, from: json(object))
        try ethernet.validate()
        XCTAssertEqual(ethernet.frameProtection, .hmacSHA256)
        XCTAssertEqual(ethernet.supervision.link(epoch: 3, frameProtection: ethernet.frameProtection.linkProtection).frameProtection, .hmacSHA256)
        object["frame_protection"] = "crc32c"
        let weak = try JSONDecoder().decode(ShardMemberConfig.self, from: json(object))
        XCTAssertThrowsError(try weak.validate()) { error in
            XCTAssertTrue(String(describing: error).contains("below the hmac-sha256 minimum"), "\(error)")
        }
    }

    func testInterfaceClassification() {
        XCTAssertEqual(ShardLinkInterface.classify(bsdName: "utun3"), ShardLinkInterface.vpn)
        XCTAssertEqual(ShardLinkInterface.classify(bsdName: "lo0"), ShardLinkInterface.other)
        XCTAssertEqual(ShardLinkInterface.classify(bsdName: "bridge0"), ShardLinkInterface.thunderbolt)
        XCTAssertEqual(ShardLinkInterface.classify(bsdName: "bridge100"), ShardLinkInterface.other)
        XCTAssertEqual(ShardLinkInterface.classify(peerAddress: "127.0.0.1:7101"), ShardLinkInterface.other)
        XCTAssertEqual(ShardLinkInterface.host(of: "[fe80::1]:7101"), "fe80::1")
    }
}
