import MacProviderCore
import XCTest
@testable import macprovider_cli

final class CoordinatorClientTests: XCTestCase {
    func testPreflightAckKeepsRequestIDCorrelation() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)

        try await client.handleCoordinatorPayloadForTest([
            "type": "preflight",
            "request_id": "req-preflight",
            "estimated_tokens": 100,
        ])

        let frames = await recorder.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["type"] as? String, "preflight_ack")
        XCTAssertEqual(frames[0]["request_id"] as? String, "req-preflight")
        XCTAssertEqual(frames[0]["accepted"] as? Bool, true)
        XCTAssertEqual(frames[0]["estimated_wait_ms"] as? Int, 0)
    }

    func testDrainWithNoInflightSendsCompleteAndResetsReady() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)

        try await client.drainFromCoordinator(reason: "test drain")

        let frames = await recorder.frames
        XCTAssertEqual(frames.map { $0["type"] as? String }, ["state_update", "drain_status", "drain_status", "drain_status"])
        XCTAssertEqual(frames.compactMap { $0["phase"] as? String }, ["starting", "in_progress", "complete"])
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.status, .ready)
    }

    func testDrainWaitsForInflightRequestBeforeResettingReady() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder, drainTimeoutSeconds: 1)
        let startedAt = await status.beginRequest(requestID: "req-active")

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            await status.finishRequest(startedAt: startedAt, completion: nil, failed: false, requestID: "req-active")
        }

        try await client.drainFromCoordinator(reason: "test drain")

        let frames = await recorder.frames
        XCTAssertEqual(frames.compactMap { $0["phase"] as? String }, ["starting", "in_progress", "complete"])
        let inflightCounts = frames.compactMap { $0["inflight_requests"] as? Int }
        XCTAssertEqual(inflightCounts.first, 1)
        XCTAssertEqual(inflightCounts.last, 0)
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.activeRequestIDCount, 0)
    }

    func testPostDrainReconnectLoopReentersConnectPath() async throws {
        let recorder = CoordinatorFrameRecorder()
        let attempts = ReconnectAttemptRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            reconnectGraceNanoseconds: 1_000_000,
            connectAndRunOverride: {
                let attempt = await attempts.recordAttempt()
                if attempt == 1 {
                    throw CoordinatorDrainComplete()
                }
                throw CancellationError()
            }
        )

        await client.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        await client.stop()

        let attemptCount = await attempts.currentCount()
        XCTAssertEqual(attemptCount, 2)
    }

    func testHelloIncludesModelHashWhenAvailable() async throws {
        let recorder = CoordinatorFrameRecorder()
        let modelHash = String(repeating: "a", count: 64)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: modelHash
        )
        let client = try await makeClient(status: status, recorder: recorder)

        let hello = await client.helloMessage()

        XCTAssertEqual(hello["model_hash"] as? String, modelHash)
    }

    func testHelloOmitsModelHashWhenUnavailable() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)

        let hello = await client.helloMessage()

        XCTAssertNil(hello["model_hash"])
    }

    func testAuthInitialUsesV2EncryptedLegCapabilitiesAndModelHash() async throws {
        let recorder = CoordinatorFrameRecorder()
        let modelHash = String(repeating: "b", count: 64)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: modelHash
        )
        let client = try await makeClient(status: status, recorder: recorder)
        let attempt = Tier2AuthAttempt()

        let auth = await client.authInitialMessage(attempt: attempt)

        XCTAssertEqual(auth["type"] as? String, "auth_request")
        XCTAssertEqual(auth["version"] as? Int, 2)
        XCTAssertEqual(auth["stage"] as? String, "initial")
        XCTAssertNil(auth["tier"])
        XCTAssertNil(auth["attestation"])
        XCTAssertEqual(auth["provider_id"] as? String, "provider-test")
        XCTAssertEqual(auth["model_hash"] as? String, modelHash)
        XCTAssertEqual(auth["provider_ecdh_public_key"] as? String, attempt.publicKeyBase64URL)
        XCTAssertFalse(attempt.publicKeyBase64URL.contains("="))
        let caps = try XCTUnwrap(auth["tier2_capabilities"] as? [String: Any])
        XCTAssertEqual(caps["encrypted_leg"] as? Bool, true)
        XCTAssertEqual(caps["attestation"] as? Bool, true)
        XCTAssertEqual(caps["aead_suites"] as? [String], [Tier2ProviderSession.aeadSuite])
    }

    func testWsTunneledV2ChallengeFailureFailsClosed() async throws {
        let firstSocket = FakeProviderWebSocketTask(receiveResults: [
            .failure(CoordinatorAuthError.invalidMessage("unrecognized auth message")),
        ])
        let factory = FakeProviderWebSocketFactory(sockets: [firstSocket])
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "ws://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = true
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) }
        ))

        do {
            try await client.connectAndRunOnceForTest()
            XCTFail("connectAndRunOnceForTest should fail closed on v2 challenge failure")
        } catch let CoordinatorAuthError.invalidMessage(message) {
            XCTAssertEqual(message, "unrecognized auth message")
        }

        let firstFrames = firstSocket.sentFrames()
        XCTAssertEqual(firstFrames.count, 1)
        XCTAssertEqual(firstFrames[0]["type"] as? String, "auth_request")
        XCTAssertEqual(firstFrames[0]["version"] as? Int, 2)
        XCTAssertEqual(firstFrames[0]["stage"] as? String, "initial")

        await client.stop()
    }

    func testAuthProofUsesNullAttestationWhenGeneratorIsUnsupported() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)
        let attempt = Tier2AuthAttempt()

        let proof = try await client.authProofMessage(challenge: [
            "type": "auth_challenge",
            "version": 2,
            "auth_attempt_id": "auth-test",
            "attestation_challenge": Data(repeating: 0x11, count: 32).base64URLUnpadded(),
        ], attempt: attempt)

        XCTAssertEqual(proof["type"] as? String, "auth_request")
        XCTAssertEqual(proof["version"] as? Int, 2)
        XCTAssertEqual(proof["stage"] as? String, "proof")
        XCTAssertEqual(proof["auth_attempt_id"] as? String, "auth-test")
        XCTAssertEqual(proof["provider_id"] as? String, "provider-test")
        XCTAssertTrue(proof["attestation_token"] is NSNull)
    }

    func testAuthProofIncludesGeneratedAttestationToken() async throws {
        let recorder = CoordinatorFrameRecorder()
        let modelHash = String(repeating: "c", count: 64)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: modelHash
        )
        let expectedToken: [String: Any] = [
            "format": ManagedDeviceAttestationGenerator.format,
            "token": Data("device-token".utf8).base64URLUnpadded(),
        ]
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            attestationGenerator: StaticAttestationGenerator(token: expectedToken)
        )
        let attempt = Tier2AuthAttempt()

        let proof = try await client.authProofMessage(challenge: [
            "type": "auth_challenge",
            "version": 2,
            "auth_attempt_id": "auth-test",
            "attestation_challenge": Data(repeating: 0x22, count: 32).base64URLUnpadded(),
        ], attempt: attempt)

        let token = try XCTUnwrap(proof["attestation_token"] as? [String: Any])
        XCTAssertEqual(token["format"] as? String, ManagedDeviceAttestationGenerator.format)
        XCTAssertEqual(token["token"] as? String, Data("device-token".utf8).base64URLUnpadded())
    }

    func testManagedDeviceAttestationEnvelopeBindsChallengeAndProviderKey() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: String(repeating: "d", count: 64)
        )
        let snapshot = await status.snapshot()
        let issuedAt = Date(timeIntervalSince1970: 1_716_768_000)
        let challenge = Data(repeating: 0x33, count: 32).base64URLUnpadded()

        let token = ManagedDeviceAttestationGenerator.tokenEnvelope(
            tokenData: Data("device-token".utf8),
            challengeBase64URL: challenge,
            providerID: "provider-test",
            binaryVersion: CoordinatorClient.binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: "provider-public-key",
            issuedAt: issuedAt
        )

        XCTAssertEqual(token["format"] as? String, ManagedDeviceAttestationGenerator.format)
        XCTAssertEqual(token["token"] as? String, Data("device-token".utf8).base64URLUnpadded())
        XCTAssertEqual(token["challenge"] as? String, challenge)
        XCTAssertEqual(token["issued_at"] as? String, "2024-05-27T00:00:00Z")
        XCTAssertEqual(token["expires_at"] as? String, "2024-05-27T00:10:00Z")
        XCTAssertEqual(token["provider_id"] as? String, "provider-test")
        XCTAssertEqual(token["binary_version"] as? String, CoordinatorClient.binaryVersion)
        let claimed = try XCTUnwrap(token["claimed"] as? [String: Any])
        XCTAssertEqual(claimed["ram_gb"] as? Int, snapshot.capacity.ramGB)
        XCTAssertEqual(claimed["model_id"] as? String, "model-a")
        XCTAssertEqual(claimed["model_hash"] as? String, String(repeating: "d", count: 64))
        let binding = try XCTUnwrap(token["key_binding"] as? [String: Any])
        XCTAssertEqual(binding["provider_ecdh_public_key"] as? String, "provider-public-key")
    }

    func testManagedDeviceAttestationGeneratorUsesConfiguredArtifact() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: String(repeating: "e", count: 64)
        )
        let snapshot = await status.snapshot()
        let challenge = Data(repeating: 0x44, count: 32).base64URLUnpadded()
        let artifactToken = Data("mda-token".utf8).base64URLUnpadded()
        let leafDER = Self.minimalDERSequenceBase64URL()
        let rootDER = Self.minimalDERSequencePEM(block: "CERTIFICATE")
        let csrDER = Self.minimalDERSequencePEM(block: "CERTIFICATE REQUEST")
        let artifact = Self.jsonData([
            "format": ManagedDeviceAttestationGenerator.format,
            "token": artifactToken,
            "certificate_chain": [leafDER, rootDER],
            "certificate_signing_request": csrDER,
        ])
        let generator = ManagedDeviceAttestationGenerator(
            artifactPath: "/tmp/mda-artifact.json",
            environment: [:],
            readFile: { path in
                guard path == "/tmp/mda-artifact.json" else {
                    throw NSError(domain: "ManagedDeviceAttestationGeneratorTest", code: 1)
                }
                return artifact
            },
            now: { Date(timeIntervalSince1970: 1_716_768_000) }
        )

        guard let token = await generator.makeAttestationToken(
            challengeBase64URL: challenge,
            authAttemptID: "auth-test",
            providerID: "provider-test",
            binaryVersion: CoordinatorClient.binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: "provider-public-key"
        ) else {
            XCTFail("expected configured MDA artifact to produce an attestation token")
            return
        }

        XCTAssertEqual(token["format"] as? String, ManagedDeviceAttestationGenerator.format)
        XCTAssertEqual(token["token"] as? String, artifactToken)
        XCTAssertEqual(token["challenge"] as? String, challenge)
        XCTAssertEqual(token["issued_at"] as? String, "2024-05-27T00:00:00Z")
        XCTAssertEqual(token["expires_at"] as? String, "2024-05-27T00:10:00Z")
        XCTAssertEqual(token["certificate_chain"] as? [String], [leafDER, rootDER])
        XCTAssertEqual(token["certificate_signing_request"] as? String, csrDER)
        let claimed = try XCTUnwrap(token["claimed"] as? [String: Any])
        XCTAssertEqual(claimed["model_hash"] as? String, String(repeating: "e", count: 64))
        let binding = try XCTUnwrap(token["key_binding"] as? [String: Any])
        XCTAssertEqual(binding["provider_ecdh_public_key"] as? String, "provider-public-key")
    }

    func testManagedDeviceAttestationGeneratorFallsBackWhenArtifactIsMissingCSR() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let snapshot = await status.snapshot()
        let artifact = Self.jsonData([
            "certificate_chain": ["leaf-der"],
        ])
        let generator = ManagedDeviceAttestationGenerator(
            artifactPath: "/tmp/mda-artifact.json",
            environment: [:],
            readFile: { _ in artifact },
            now: { Date(timeIntervalSince1970: 1_716_768_000) }
        )

        let token = await generator.makeAttestationToken(
            challengeBase64URL: Data(repeating: 0x55, count: 32).base64URLUnpadded(),
            authAttemptID: "auth-test",
            providerID: "provider-test",
            binaryVersion: CoordinatorClient.binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: "provider-public-key"
        )

        XCTAssertNil(token)
    }

    func testManagedDeviceAttestationGeneratorFallsBackWhenArtifactEvidenceIsNotDER() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let snapshot = await status.snapshot()
        let artifact = Self.jsonData([
            "certificate_chain": [Data("not-a-der-sequence".utf8).base64URLUnpadded()],
            "certificate_signing_request": Self.minimalDERSequenceBase64URL(),
        ])
        let generator = ManagedDeviceAttestationGenerator(
            artifactPath: "/tmp/mda-artifact.json",
            environment: [:],
            readFile: { _ in artifact },
            now: { Date(timeIntervalSince1970: 1_716_768_000) }
        )

        let token = await generator.makeAttestationToken(
            challengeBase64URL: Data(repeating: 0x66, count: 32).base64URLUnpadded(),
            authAttemptID: "auth-test",
            providerID: "provider-test",
            binaryVersion: CoordinatorClient.binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: "provider-public-key"
        )

        XCTAssertNil(token)
    }

    func testConfigLoaderReadsTier2MDAArtifactPathFromYAMLAndEnvironment() throws {
        let yamlConfig = """
        tier2_mda_artifact_path: /var/lib/macprovider/mda.json
        """
        let fromYAML = try ConfigLoader.load(
            cli: CLIOverrides(configPath: "/tmp/provider.yaml"),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in yamlConfig }
        )
        XCTAssertEqual(fromYAML.tier2MDAArtifactPath, "/var/lib/macprovider/mda.json")

        let fromEnvironment = try ConfigLoader.load(
            cli: CLIOverrides(configPath: "/tmp/provider.yaml"),
            environment: ["MACPROVIDER_TIER2_MDA_ARTIFACT_PATH": "/tmp/env-mda.json"],
            fileExists: { _ in true },
            readFile: { _ in yamlConfig }
        )
        XCTAssertEqual(fromEnvironment.tier2MDAArtifactPath, "/tmp/env-mda.json")
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonData(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    private static func minimalDERSequenceBase64URL() -> String {
        Data([0x30, 0x03, 0x02, 0x01, 0x05]).base64URLUnpadded()
    }

    private static func minimalDERSequencePEM(block: String) -> String {
        """
        -----BEGIN \(block)-----
        \(Data([0x30, 0x03, 0x02, 0x01, 0x05]).base64EncodedString())
        -----END \(block)-----
        """
    }

    private func makeClient(
        status: ProviderStatus,
        recorder: CoordinatorFrameRecorder,
        drainTimeoutSeconds: Int = 1,
        reconnectGraceNanoseconds: UInt64 = 10 * 1_000_000_000,
        attestationGenerator: Tier2AttestationTokenGenerating = StaticAttestationGenerator(token: nil),
        connectAndRunOverride: (() async throws -> Void)? = nil
    ) async throws -> CoordinatorClient {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "ws://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.drainTimeoutSeconds = drainTimeoutSeconds
        let runtime = try await ModelRuntime(modelID: nil)
        return try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            sendOverride: { frame in
                await recorder.append(frame)
            },
            reconnectGraceNanoseconds: reconnectGraceNanoseconds,
            attestationGenerator: attestationGenerator,
            connectAndRunOverride: connectAndRunOverride
        ))
    }
}

private actor CoordinatorFrameRecorder {
    private(set) var frames: [[String: Any]] = []

    func append(_ frame: [String: Any]) {
        frames.append(frame)
    }
}

private actor ReconnectAttemptRecorder {
    private var count = 0

    func recordAttempt() -> Int {
        count += 1
        return count
    }

    func currentCount() -> Int {
        count
    }
}

private struct StaticAttestationGenerator: Tier2AttestationTokenGenerating, @unchecked Sendable {
    let token: [String: Any]?

    func makeAttestationToken(
        challengeBase64URL: String?,
        authAttemptID: String,
        providerID: String,
        binaryVersion: String,
        snapshot: ProviderSnapshot,
        providerECDHPublicKey: String
    ) async -> [String: Any]? {
        token
    }
}

private final class FakeProviderWebSocketFactory: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeProviderWebSocketFactory")
    private var sockets: [FakeProviderWebSocketTask]

    init(sockets: [FakeProviderWebSocketTask]) {
        self.sockets = sockets
    }

    func makeSocket(for _: URL) -> ProviderWebSocketTask {
        queue.sync {
            precondition(!sockets.isEmpty, "fake web socket factory exhausted")
            return sockets.removeFirst()
        }
    }
}

private final class FakeProviderWebSocketTask: ProviderWebSocketTask, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeProviderWebSocketTask")
    private var receiveResults: [Result<URLSessionWebSocketTask.Message, Error>]
    private var sent: [[String: Any]] = []
    private(set) var resumeCount = 0
    private(set) var cancelCount = 0

    init(receiveResults: [Result<URLSessionWebSocketTask.Message, Error>]) {
        self.receiveResults = receiveResults
    }

    func resume() {
        queue.sync {
            resumeCount += 1
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(decoding: data, as: UTF8.self)
        @unknown default:
            text = "{}"
        }
        let data = Data(text.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        queue.sync {
            sent.append(object)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let result = queue.sync {
            receiveResults.isEmpty ? Result<URLSessionWebSocketTask.Message, Error>.failure(CancellationError()) : receiveResults.removeFirst()
        }
        return try result.get()
    }

    func cancel(with _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        queue.sync {
            cancelCount += 1
        }
    }

    func sentFrames() -> [[String: Any]] {
        queue.sync {
            sent
        }
    }
}
