import ArgumentParser
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
        let runtime = RelayBlindFixtureRuntime(model: model, streamDelayMs: streamDelayMs)
        let status = ProviderStatus(
            modelID: model,
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1)
        )
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: model,
            maxActiveRequests: 1,
            maxBodyBytes: 1_200_000,
            relayBlindRuntime: providerRuntime,
            sendFrame: { frame in try await writer.write(frame) }
        )

        try await writer.write([
            "type": "relay_blind_fixture_descriptor",
            "version": RelayBlindEnvelope.version,
            "body_encoding": RelayBlindEnvelope.version,
            "assigned_session": assignedSession,
            "stream_delay_ms": streamDelayMs,
            "identity_public_key": keyManager.identityPublicKeyBase64URL(),
            "relay_blind_key_record": try providerRuntime.advertisedRecord().wireObject,
        ])

        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            do {
                let data = Data(line.utf8)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw RelayBlindProviderError.invalidEnvelope
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

private actor RelayBlindFixtureWriter {
    func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}

private actor RelayBlindFixtureRuntime: ModelRuntimeServing {
    private let model: String
    private let promptTokens = 5
    private let streamDelayNanoseconds: UInt64

    init(model: String, streamDelayMs: Int) {
        self.model = model
        self.streamDelayNanoseconds = UInt64(streamDelayMs) * 1_000_000
    }

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
            completionTokens: 4
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
            completionTokens: 4
        )
    }

    func unregisterInFlight(_ id: Int) {}
}
