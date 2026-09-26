import ArgumentParser
import CryptoKit
import Foundation
import MacProviderCore

/// Local-only JSONL provider used by the cross-service SPEC-041 harness. It
/// drives the production InferenceRelay, crypto, validation, and journal path;
/// only model generation is deterministic.
struct RelayBlindFixtureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "relay-blind-fixture",
        abstract: "Run the local SPEC-041 provider fixture.",
        shouldDisplay: false
    )

    @Option(help: "Absolute external directory for persistent fixture keys and journal.")
    var stateDir: String

    @Option(help: "Model identifier advertised by the fixture.")
    var model: String = "mlx-community/fixture-model"

    @Option(help: "Assigned provider session required in dispatch context.")
    var assignedSession: String = "relay-blind-fixture-session"

    @Option(help: "Test-only delay between deterministic streaming chunks.")
    var streamDelayMs: Int = 0

    @Flag(help: "Exercise cleartext relay replay through the continuous-batching scheduler.")
    var continuousBatchReplay: Bool = false

    mutating func run() async throws {
        guard ProcessInfo.processInfo.environment["MACPROVIDER_ALLOW_TEST_FIXTURES"] == "1" else {
            throw ValidationError("relay-blind fixture requires MACPROVIDER_ALLOW_TEST_FIXTURES=1")
        }
        guard stateDir.hasPrefix("/") else {
            throw ValidationError("--state-dir must be absolute")
        }
        guard (0...10_000).contains(streamDelayMs) else {
            throw ValidationError("--stream-delay-ms must be in 0...10000")
        }

        let root = URL(fileURLWithPath: stateDir, isDirectory: true)
        let keyManager = try RelayBlindKeyManager(
            directory: root,
            models: [model],
            maxEncryptedRequestBytes: 1_048_576
        )
        let journal = try RelayBlindExecutionJournal(
            directory: root.appendingPathComponent("execution-journal", isDirectory: true)
        )
        let providerRuntime = RelayBlindProviderRuntime(
            keyManager: keyManager,
            journal: journal,
            assignedSession: assignedSession
        )
        let writer = RelayBlindFixtureWriter()
        let status = ProviderStatus(
            modelID: model,
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1)
        )
        let fixtureRuntime: any ModelRuntimeServing
        let replayObserver: RelayReplayFixtureObserver?
        let receiptBuilder: ReceiptBuilder?
        let receiptProviderID: String?
        let modelHash: String?
        if continuousBatchReplay {
            let configured = try RelayReplayFixtureRuntime.make(model: model, root: root)
            fixtureRuntime = configured.runtime
            replayObserver = configured.observer
            receiptBuilder = configured.receiptBuilder
            receiptProviderID = configured.providerID
            modelHash = configured.modelHash
        } else {
            fixtureRuntime = RelayBlindFixtureRuntime(model: model, streamDelayMs: streamDelayMs)
            replayObserver = nil
            receiptBuilder = nil
            receiptProviderID = nil
            modelHash = nil
        }
        func makeRelay() -> InferenceRelay {
            InferenceRelay(
                modelRuntime: fixtureRuntime,
                providerStatus: status,
                loadedModelID: model,
                maxActiveRequests: 1,
                maxBodyBytes: 1_200_000,
                receiptBuilder: receiptBuilder,
                receiptProviderID: receiptProviderID,
                relayBlindRuntime: continuousBatchReplay ? nil : providerRuntime,
                sendFrame: { frame in
                    var output = frame
                    if output["type"] as? String == "inference_response_end",
                       let requestID = output["request_id"] as? String,
                       let replayObserver {
                        let observed = await replayObserver.observation(requestID: requestID)
                        output["fixture_generation_count"] = observed.generationCount
                        output["fixture_settlement_disposition"] = observed.settlementDisposition
                    }
                    try await writer.write(output)
                }
            )
        }
        var relay = makeRelay()

        var descriptor: [String: Any] = [
            "type": "relay_blind_fixture_descriptor",
            "version": RelayBlindEnvelope.version,
            "body_encoding": RelayBlindEnvelope.version,
            "assigned_session": assignedSession,
            "stream_delay_ms": streamDelayMs,
            "identity_public_key": keyManager.identityPublicKeyBase64URL(),
            "relay_blind_key_record": try providerRuntime.advertisedRecord().wireObject,
            "continuous_batch_replay": continuousBatchReplay,
        ]
        if let replayObserver, let receiptProviderID, let modelHash {
            descriptor["provider_id"] = receiptProviderID
            descriptor["model_id"] = model
            descriptor["model_hash"] = modelHash
            descriptor["provider_receipt_public_key"] = replayObserver.receiptPublicKey.base64EncodedString()
            descriptor["provider_receipt_key_id"] = replayObserver.receiptKeyID
            descriptor["replay_store"] = root.appendingPathComponent("continuous-batching-replay", isDirectory: true).path
        }
        try await writer.write(descriptor)

        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            do {
                let data = Data(line.utf8)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw RelayBlindProviderError.invalidEnvelope
                }
                if continuousBatchReplay, object["type"] as? String == "relay_fixture_reconnect" {
                    guard await relay.waitUntilIdle(timeoutSeconds: 10) else {
                        throw RelayBlindProviderError.journalUnavailable
                    }
                    relay = makeRelay()
                    try await writer.write(["type": "relay_fixture_reconnected"])
                    continue
                }
                try await relay.handleInferenceRequest(object)
                guard await relay.waitUntilIdle(timeoutSeconds: 10) else {
                    throw RelayBlindProviderError.journalUnavailable
                }
            } catch let error as RelayBlindProviderError {
                try await writer.write(["type": "relay_blind_fixture_error", "code": error.code])
            } catch {
                try await writer.write(["type": "relay_blind_fixture_error", "code": "fixture_input_invalid"])
            }
        }
    }
}

private struct RelayReplayFixtureConfiguredRuntime {
    let runtime: RelayReplayFixtureObserver
    let observer: RelayReplayFixtureObserver
    let receiptBuilder: ReceiptBuilder
    let providerID: String
    let modelHash: String
}

private enum RelayReplayFixtureRuntime {
    static func make(model: String, root: URL) throws -> RelayReplayFixtureConfiguredRuntime {
        let modelHash = String(repeating: "a", count: 64)
        let providerID = "provider-continuous-batch-replay-fixture"
        let descriptor = PagedKVDescriptor(
            blockSizeTokens: 32,
            maxPhysicalBlocks: 64,
            modelID: model,
            modelSHA256: modelHash,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            supportedModelFamilies: ["qwen"],
            supportsMoEDispatch: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            parityLabel: "sdpa-parity-v1"
        )
        let tuple = ContinuousBatchingRequestedTuple(
            modelID: descriptor.modelID,
            modelSHA256: descriptor.modelSHA256,
            tokenizerSHA256: descriptor.tokenizerSHA256,
            chatTemplateSHA256: descriptor.chatTemplateSHA256,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            parityLabel: "sdpa-parity-v1",
            poolEpoch: descriptor.poolEpoch
        )
        let backend = RelayReplayFixtureBackend()
        let scheduler = ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: descriptor,
                tuple: tuple,
                maxActiveRows: 2,
                decodeHeadroomTokens: 1,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: model,
                    modelSHA256: modelHash,
                    weightsGeneration: 1
                )
            ),
            allocator: try PagedKVBlockAllocator(blockSizeTokens: 32, maxPhysicalBlocks: 64),
            backend: backend,
            replayAuthority: ContinuousBatchRuntimeReplayAuthority(
                storeURL: root.appendingPathComponent("continuous-batching-replay", isDirectory: true)
            )
        )
        let keyStore = InMemoryReceiptKeyStore()
        let receiptKey = try keyStore.loadOrGenerate(providerId: providerID)
        let publicKey = receiptKey.publicKey.rawRepresentation
        let keyID = "ed25519-sha256:" + SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        let observer = RelayReplayFixtureObserver(
            scheduler: scheduler,
            backend: backend,
            model: model,
            modelHash: modelHash,
            receiptPublicKey: publicKey,
            receiptKeyID: keyID
        )
        return RelayReplayFixtureConfiguredRuntime(
            runtime: observer,
            observer: observer,
            receiptBuilder: ReceiptBuilder(keyStore: keyStore),
            providerID: providerID,
            modelHash: modelHash
        )
    }
}

private actor RelayReplayFixtureObserver: ModelRuntimeServing {
    let receiptPublicKey: Data
    let receiptKeyID: String
    private let scheduler: ContinuousBatchScheduler
    private let backend: RelayReplayFixtureBackend
    private let model: String
    private let modelHash: String
    private var dispositions: [String: String] = [:]

    init(
        scheduler: ContinuousBatchScheduler,
        backend: RelayReplayFixtureBackend,
        model: String,
        modelHash: String,
        receiptPublicKey: Data,
        receiptKeyID: String
    ) {
        self.scheduler = scheduler
        self.backend = backend
        self.model = model
        self.modelHash = modelHash
        self.receiptPublicKey = receiptPublicKey
        self.receiptKeyID = receiptKeyID
    }

    nonisolated var isSettlementReceiptEligible: Bool { true }
    nonisolated var settlementRuntimeSource: String? { nil }
    var loadedModelHash: String? { get async { modelHash } }
    var loadedModelHashAlgorithm: String? { get async { "snapshot-manifest-v1" } }
    var loadedWeightsManifestSHA256: String? { get async { nil } }
    var isLoaded: Bool { get async { true } }

    func setProviderStatus(_ providerStatus: ProviderStatus) async {}

    func currentSnapshot() async -> RuntimeSnapshot {
        RuntimeSnapshot(state: .ready, container: nil, modelID: model, modelHash: modelHash)
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        let (completion, _) = try await completeWithServedSnapshot(request, shouldCancel: shouldCancel)
        return completion
    }

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        if shouldCancel() { throw CancellationError() }
        let promptTokens = [3]
        let submission = try ModelRuntime.continuousBatchSubmission(
            for: request,
            promptTokens: promptTokens,
            maxOutputTokens: request.maxTokens ?? 2
        )
        let result = try await scheduler.submit(submission.schedulerRequest)
        let finalized = try ModelRuntime.finalizeContinuousBatchRow(
            request: request,
            result: result,
            modelStopTokenIDs: [],
            promptTokenIDs: promptTokens.map(Int32.init),
            decode: { $0.map(String.init).joined(separator: " ") },
            stopTokenFilter: StopTokenFilter(tokens: []),
            generationMilliseconds: 0,
            modelHash: modelHash
        )
        dispositions[submission.requestID] = finalized.completion.settlementDisposition.rawValue
        return (finalized.completion, await currentSnapshot())
    }

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        try await completeWithServedSnapshot(request, shouldCancel: shouldCancel)
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        throw RelayBlindProviderError.providerUnsupported
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        throw RelayBlindProviderError.providerUnsupported
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        throw RelayBlindProviderError.providerUnsupported
    }

    func unregisterInFlight(_ id: Int) {}

    func observation(requestID: String) async -> (generationCount: Int, settlementDisposition: String) {
        (await backend.generationCount(), dispositions[requestID] ?? "unobserved")
    }
}

private actor RelayReplayFixtureBackend: ContinuousBatchSchedulerBackend {
    private var generationStarts = 0

    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        return rows.map { ContinuousBatchPrefillOutput(requestID: $0.requestID) }
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        generationStarts += rows.filter { $0.generatedTokens.isEmpty }.count
        return rows.map {
            .output(ContinuousBatchDecodeOutput(requestID: $0.requestID, token: 7))
        }
    }

    func cancelInFlight() async {}
    func generationCount() -> Int { generationStarts }
}

private actor RelayBlindFixtureWriter {
    func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}

actor RelayBlindFixtureRuntime: ModelRuntimeServing {
    private let model: String
    private let promptTokens = 5
    private let streamDelayNanoseconds: UInt64

    init(model: String, streamDelayMs: Int) {
        self.model = model
        self.streamDelayNanoseconds = UInt64(streamDelayMs) * 1_000_000
    }

    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    nonisolated var isSettlementReceiptEligible: Bool { false }
    nonisolated var settlementRuntimeSource: String? { nil }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}

    func currentSnapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(state: .ready, container: nil, modelID: model, modelHash: nil)
    }

    func relayBlindPrepare(_ request: ChatCompletionRequest) throws -> RelayBlindPreparedRequest {
        RelayBlindPreparedRequest(handle: try acquireRequestHandle(request), inputTokens: promptTokens)
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        if shouldCancel() { throw CancellationError() }
        return CompletionResult(
            content: "relay-blind fixture response",
            finishReason: "stop",
            promptTokens: promptTokens,
            completionTokens: 4,
            settlementDisposition: .notEligible
        )
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(
            snapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: model, modelHash: nil),
            registrationID: 1,
            drainCancelled: DrainCancelToken()
        )
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {}

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        if shouldCancel() { throw CancellationError() }
        onChunk(.content("relay-blind "))
        if streamDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: streamDelayNanoseconds)
        }
        if shouldCancel() { throw CancellationError() }
        onChunk(.content("fixture response"))
        return CompletionResult(
            content: "relay-blind fixture response",
            finishReason: "stop",
            promptTokens: promptTokens,
            completionTokens: 4,
            settlementDisposition: .notEligible
        )
    }

    func unregisterInFlight(_ id: Int) {}
}
