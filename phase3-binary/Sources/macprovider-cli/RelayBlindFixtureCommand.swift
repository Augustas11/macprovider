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

    @Flag(name: .customLong("privacy-class"), help: "Run the SPEC-049 privacy fixture with memory-only agreement keys.")
    var privacyClass: Bool = false

    @Option(name: .customLong("privacy-fixture-cdhash"), help: "40 lowercase hex code cdhash for an adversarial privacy fixture.")
    var privacyFixtureCDHash: String?

    @Flag(name: .customLong("privacy-fixture-traced"), help: "Report the privacy fixture as traced so posture advertising stays off.")
    var privacyFixtureTraced: Bool = false

    @Option(name: .customLong("provider-id"), help: "Provider id carried in privacy posture statements.")
    var privacyProviderID: String = "privacy-fixture-provider"

    @Option(name: .customLong("privacy-fixture-completion"), help: "Deterministic completion text for a privacy fixture. Token counts stay 5 and 4.")
    var privacyFixtureCompletion: String?

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
        if privacyClass && continuousBatchReplay {
            throw ValidationError("--privacy-class cannot be combined with --continuous-batch-replay")
        }
        if !privacyClass && (privacyFixtureCDHash != nil || privacyFixtureTraced || privacyFixtureCompletion != nil) {
            throw ValidationError("--privacy-fixture-cdhash, --privacy-fixture-traced, and --privacy-fixture-completion require --privacy-class")
        }
        if let privacyFixtureCDHash, !privacyFixtureCDHashIsHex(privacyFixtureCDHash) {
            throw ValidationError("--privacy-fixture-cdhash must be 40 lowercase hex characters")
        }
        if let privacyFixtureCompletion, !privacyFixtureCompletionText(privacyFixtureCompletion) {
            throw ValidationError("--privacy-fixture-completion must be 1...256 bytes of printable text without a newline")
        }
        guard privacyProviderIdentifier(privacyProviderID) else {
            throw ValidationError("--provider-id must be 1...128 printable ASCII characters")
        }

        let root = URL(fileURLWithPath: stateDir, isDirectory: true)
        let keyManager = try RelayBlindKeyManager(
            directory: root,
            models: [model],
            maxEncryptedRequestBytes: 1_048_576,
            persistAgreementKey: !privacyClass
        )
        let journalDirectory = privacyClass
            ? try PrivacyStateDirectory.executionJournal(stateRoot: root)
            : root.appendingPathComponent("execution-journal", isDirectory: true)
        let journal = try RelayBlindExecutionJournal(directory: journalDirectory)
        let providerRuntime = RelayBlindProviderRuntime(
            keyManager: keyManager,
            journal: journal,
            assignedSession: assignedSession
        )
        let privacyProbe: FixturePrivacyPostureProbe?
        let privacySigner: SELivenessTestSigning?
        let privacyResponder: PrivacyPostureResponder?
        if privacyClass {
            let signer = try FixturePrivacySEKey.loadOrCreate(stateRoot: root)
            let probe = FixturePrivacyPostureProbe(
                traced: privacyFixtureTraced,
                codeCDHash: privacyFixtureCDHash ?? FixturePrivacyPostureProbe.defaultCodeCDHash,
                binaryVersion: CoordinatorClient.binaryVersion
            )
            privacyProbe = probe
            privacySigner = signer
            privacyResponder = PrivacyPostureResponder(
                probe: probe,
                seSigner: signer,
                seKeyBackend: PrivacyClassConstants.seBackendFile,
                relayBlindRuntime: providerRuntime,
                providerID: privacyProviderID,
                binaryVersion: CoordinatorClient.binaryVersion
            )
        } else {
            privacyProbe = nil
            privacySigner = nil
            privacyResponder = nil
        }
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
            fixtureRuntime = RelayBlindFixtureRuntime(model: model, streamDelayMs: streamDelayMs, completionText: privacyFixtureCompletion)
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
                privacyClassBeta: privacyClass,
                postureProbe: privacyProbe,
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
        if privacyClass, let privacySigner, let privacyProbe {
            descriptor["provider_id"] = privacyProviderID
            descriptor["se_public_key"] = privacySigner.publicKeyBase64
            descriptor["se_key_backend"] = PrivacyClassConstants.seBackendFile
            descriptor["code_cdhash"] = privacyProbe.codeCDHash
            descriptor["team_id"] = FixturePrivacyPostureProbe.teamID
            descriptor["signing_identifier"] = FixturePrivacyPostureProbe.signingIdentifier
            descriptor["binary_version"] = CoordinatorClient.binaryVersion
            if let records = privacyResponder?.privacyKeyRecords() {
                descriptor["privacy_key_records"] = records
            }
        }
        try await writer.write(descriptor)

        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            do {
                let data = Data(line.utf8)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw RelayBlindProviderError.invalidEnvelope
                }
                if object["type"] as? String == "relay_fixture_assigned_session" {
                    guard privacyClass,
                          let session = object["assigned_session"] as? String,
                          privacyProviderIdentifier(session) else {
                        try await writer.write([
                            "type": "relay_blind_fixture_error",
                            "code": "fixture_input_invalid",
                        ])
                        continue
                    }
                    assignedSession = session
                    providerRuntime.adoptAssignedSession(session)
                    try await writer.write([
                        "type": "relay_fixture_assigned_session_ack",
                        "assigned_session": session,
                    ])
                    continue
                }
                if object["type"] as? String == "privacy_posture_challenge" {
                    guard let privacyResponder else {
                        try await writer.write([
                            "type": "relay_blind_fixture_error",
                            "code": "privacy_posture_unavailable",
                        ])
                        continue
                    }
                    do {
                        guard let response = try privacyResponder.respond(
                            to: object,
                            assignedSession: assignedSession
                        ) else {
                            try await writer.write([
                                "type": "relay_blind_fixture_error",
                                "code": "privacy_posture_unavailable",
                            ])
                            continue
                        }
                        try await writer.write(response)
                    } catch {
                        try await writer.write([
                            "type": "relay_blind_fixture_error",
                            "code": "fixture_input_invalid",
                        ])
                    }
                    continue
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

private func privacyFixtureCDHashIsHex(_ value: String) -> Bool {
    privacyFixtureCDHash(value)
}

private func privacyFixtureCompletionText(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return !bytes.isEmpty && bytes.count <= 256 && bytes.allSatisfy { $0 >= 0x20 && $0 != 0x7f }
}

private func privacyProviderIdentifier(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return !bytes.isEmpty && bytes.count <= 128 && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
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
        generationStarts += rows.filter(\.sampleFirstToken).count
        return rows.map {
            ContinuousBatchPrefillOutput(
                requestID: $0.requestID,
                sampledToken: $0.sampleFirstToken ? 7 : nil
            )
        }
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
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
    private let completionText: String

    init(model: String, streamDelayMs: Int, completionText: String? = nil) {
        self.model = model
        self.streamDelayNanoseconds = UInt64(streamDelayMs) * 1_000_000
        self.completionText = completionText ?? "relay-blind fixture response"
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
            content: completionText,
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
        let chunks = fixtureCompletionChunks(completionText)
        onChunk(.content(chunks.0))
        if streamDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: streamDelayNanoseconds)
        }
        if shouldCancel() { throw CancellationError() }
        if !chunks.1.isEmpty {
            onChunk(.content(chunks.1))
        }
        return CompletionResult(
            content: completionText,
            finishReason: "stop",
            promptTokens: promptTokens,
            completionTokens: 4,
            settlementDisposition: .notEligible
        )
    }

    func unregisterInFlight(_ id: Int) {}
}

private func fixtureCompletionChunks(_ text: String) -> (String, String) {
    if text == "relay-blind fixture response" {
        return ("relay-blind ", "fixture response")
    }
    let characters = Array(text)
    let mid = max(1, characters.count / 2)
    return (String(characters[..<mid]), String(characters[mid...]))
}
