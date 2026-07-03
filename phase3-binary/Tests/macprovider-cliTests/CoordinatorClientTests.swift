import CryptoKit
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

    // Regression: M1-1 / XSEC-1. When config.providerToken is set, the WS
    // connect attaches "Authorization: Bearer <token>". When unset, no
    // Authorization header is sent (preserves the legacy fleet's ability
    // to connect against a coordinator with require_provider_tokens=false).
    // Covers both v1 plaintext (wsTunneledMode=false) and v2 ECDH
    // (wsTunneledMode=true) connect paths via openWebSocket.
    func testWebSocketConnectAttachesBearerAuthorizationWhenTokenConfigured_v1Plaintext() async throws {
        let token = "test-token-deadbeef-deadbeef-deadbeef"
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = false
        config.providerToken = token
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let socket = FakeProviderWebSocketTask(receiveResults: [.failure(CancellationError())])
        let factory = FakeProviderWebSocketFactory(sockets: [socket])
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            webSocketFactory: { factory.makeSocket(for: $0) }
        ))

        do {
            try await client.connectAndRunOnceForTest()
        } catch is CancellationError {
        } catch {
            // Other failures fine — we only care about the request handed to the factory.
        }

        let request = try XCTUnwrap(factory.lastRequest, "factory never received a URLRequest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func testWebSocketConnectAttachesBearerAuthorizationWhenTokenConfigured_v2Tier2() async throws {
        let token = "tier2-token-cafebabe-cafebabe-cafebabe"
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = true
        config.providerToken = token
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let socket = FakeProviderWebSocketTask(receiveResults: [
            .failure(CoordinatorAuthError.invalidMessage("unrecognized auth message")),
        ])
        let factory = FakeProviderWebSocketFactory(sockets: [socket])
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
        } catch {
        }

        let request = try XCTUnwrap(factory.lastRequest, "factory never received a URLRequest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func testWebSocketConnectOmitsAuthorizationWhenTokenUnset() async throws {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = false
        // providerToken intentionally not set
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let socket = FakeProviderWebSocketTask(receiveResults: [.failure(CancellationError())])
        let factory = FakeProviderWebSocketFactory(sockets: [socket])
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            webSocketFactory: { factory.makeSocket(for: $0) }
        ))

        do {
            try await client.connectAndRunOnceForTest()
        } catch {
        }

        let request = try XCTUnwrap(factory.lastRequest, "factory never received a URLRequest")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // Regression: M1-1 follow-up (codex security audit 2026-06-11). The
    // NoRedirectURLSessionDelegate refuses HTTP redirects on the provider
    // WS task so the Authorization: Bearer <token> header cannot leak to an
    // attacker-controlled redirect target. Pre-fix URLSession.shared
    // followed redirects with credential headers attached.
    func testNoRedirectURLSessionDelegateRefusesRedirect() {
        let delegate = NoRedirectURLSessionDelegate()
        let session = URLSession.shared
        let dummyURL = URL(string: "https://example.test/ws/provider")!
        let task = session.dataTask(with: dummyURL)
        let response = HTTPURLResponse(
            url: dummyURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://attacker.test/ws/provider"]
        )!
        let newRequest = URLRequest(url: URL(string: "https://attacker.test/ws/provider")!)

        var capturedRequest: URLRequest? = URLRequest(url: dummyURL) // non-nil sentinel
        let expectation = self.expectation(description: "completion called")
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: newRequest
        ) { request in
            capturedRequest = request
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        task.cancel()
        XCTAssertNil(capturedRequest, "delegate must call completion with nil to refuse the redirect")
    }

    // Keepalive sends a heartbeat TEXT frame on the sub-interval tick and sends
    // NO WebSocket control ping. A provider->coordinator control PING triggers
    // the coordinator's auto-PONG write onto a stale (never-cleared) write
    // deadline, which fails with i/o timeout and drops the session; control
    // frames also do not count as liveness on the coordinator. So keepalive must
    // be a text heartbeat, never a ping. See startHeartbeat doc-comment.
    func testCoordinatorSessionKeepaliveSendsHeartbeatTextFrameAndNoPing() async throws {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = false
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let socket = FakeProviderWebSocketTask(
            receiveResults: [
                .success(.string("""
                {"type":"hello_ack","assigned_id":"session-1","heartbeat_interval_s":1,"tier":"pinned"}
                """)),
                .failure(CancellationError()),
            ],
            receiveDelayNanoseconds: 1_200_000_000
        )
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            webSocketFactory: { _ in socket },
            sleepAssertionFactory: { nil }
        ))

        do {
            try await client.connectAndRunOnceForTest()
        } catch is CancellationError {
        }

        // A heartbeat text frame is emitted on the keepalive tick (interval 1s,
        // tick capped at <= interval, fires inside the 1.2s receive window)...
        XCTAssertTrue(socket.sentFrames().contains { $0["type"] as? String == "heartbeat" })
        // ...and no WebSocket control ping is ever sent.
        XCTAssertEqual(socket.pingCountSnapshot(), 0)
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

    func testWSScheme_MustBeWSS_NotWS() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let runtime = try await ModelRuntime(modelID: nil)
        var insecure = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        insecure.coordinatorURL = "ws://127.0.0.1:8444/ws/provider"
        insecure.providerID = "provider-test"
        insecure.model = "model-a"

        XCTAssertNil(CoordinatorClient(config: insecure, modelRuntime: runtime, providerStatus: status))

        var secure = insecure
        secure.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        XCTAssertNotNil(CoordinatorClient(config: secure, modelRuntime: runtime, providerStatus: status))
    }

    func testRequestPairOT_NeverEmitted_OnAdmissionFrames() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)

        let helloJSON = Self.jsonString(await client.helloMessage())
        let authJSON = Self.jsonString(await client.authInitialMessage(attempt: Tier2AuthAttempt()))

        XCTAssertFalse(helloJSON.contains("request_pair_ot"), helloJSON)
        XCTAssertFalse(authJSON.contains("request_pair_ot"), authJSON)
    }

    func testHelloAckPairingMaterial_WritesClaimURLBeforeFailedOpen() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let dir = try Self.makeTemporaryDirectory(prefix: "coordinator-claim-")
        let claimFile = ClaimURLFile(directory: dir)
        let pairingController = PairingController(
            claimURLFile: claimFile,
            browserOpener: BrowserOpener(
                hasControllingTTY: { true },
                environment: { _ in nil },
                spawn: { _ in throw BrowserOpenError.spawnFailed(errno: 9) }
            )
        )
        let client = try await makeClient(status: status, recorder: recorder, pairingController: pairingController)

        try await client.handleCoordinatorPayloadForTest([
            "type": "hello_ack",
            "assigned_id": "assigned-a",
            "heartbeat_interval_s": 30,
            "pair_ot": "PAIRSECRET",
            "claim_url": "https://portal.example/claim?ot=PAIRSECRET",
            "portal_base_url": "https://portal.example",
        ])

        let record = try XCTUnwrap(claimFile.read())
        XCTAssertEqual(record.pairOT, "PAIRSECRET")
        XCTAssertEqual(record.claimURL, "https://portal.example/claim?ot=PAIRSECRET")
        let attrs = try FileManager.default.attributesOfItem(atPath: claimFile.fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAcceptedAuthResponsePairingMaterial_WritesClaimURL() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let dir = try Self.makeTemporaryDirectory(prefix: "coordinator-auth-claim-")
        let claimFile = ClaimURLFile(directory: dir)
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            pairingController: PairingController(
                claimURLFile: claimFile,
                browserOpener: BrowserOpener(hasControllingTTY: { false })
            )
        )
        let session = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-v2",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "kid-test",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data(repeating: 0x33, count: 4),
            p2cNonceBase: Data(repeating: 0x44, count: 4)
        )

        try await client.acceptAuthResponseForTest([
            "type": "auth_response",
            "version": 2,
            "status": "accepted",
            "assigned_id": "assigned-v2",
            "heartbeat_interval_s": 30,
            "pair_ot": "PAIRV2",
            "claim_url": "https://portal.example/claim?ot=PAIRV2",
            "tier2_session": [
                "encrypted_leg": [
                    "enabled": true,
                    "alg": Tier2ProviderSession.aeadSuite,
                    "kid": "kid-test",
                ],
            ],
        ], session: session)

        let record = try XCTUnwrap(claimFile.read())
        XCTAssertEqual(record.pairOT, "PAIRV2")
        XCTAssertEqual(record.claimURL, "https://portal.example/claim?ot=PAIRV2")
    }

    func testOwnershipStatusNeedsClaim_WritesStubWithoutOpeningBrowser() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let dir = try Self.makeTemporaryDirectory(prefix: "coordinator-needs-claim-")
        let claimFile = ClaimURLFile(directory: dir)
        let opened = LockedBox(false)
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            pairingController: PairingController(
                claimURLFile: claimFile,
                browserOpener: BrowserOpener(hasControllingTTY: { true }, spawn: { _ in opened.set(true) })
            )
        )

        try await client.handleCoordinatorPayloadForTest([
            "type": "ownership_status",
            "provider_id": "provider-test",
            "needs_claim": true,
        ])

        XCTAssertEqual(try String(contentsOf: claimFile.fileURL, encoding: .utf8), "needs_refresh=true\n")
        XCTAssertFalse(opened.get())
    }

    func testOwnershipEventBound_DeletesClaimURLAndWritesOwner() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let dir = try Self.makeTemporaryDirectory(prefix: "coordinator-owner-")
        let claimFile = ClaimURLFile(directory: dir)
        try claimFile.write(pairOT: "PAIR", claimURL: "https://portal.example/claim?ot=PAIR", expiresAt: Date().addingTimeInterval(600))
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            pairingController: PairingController(claimURLFile: claimFile, browserOpener: BrowserOpener(hasControllingTTY: { false }))
        )

        try await client.handleCoordinatorPayloadForTest([
            "type": "ownership_event",
            "provider_id": "provider-test",
            "github_login": "octo-user",
            "event": "bound",
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: claimFile.fileURL.path))
        XCTAssertEqual(try String(contentsOf: claimFile.ownerURL, encoding: .utf8), "github_login=octo-user\n")
        let attrs = try FileManager.default.attributesOfItem(atPath: claimFile.ownerURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testHeartbeatDisabledModeOmitsBothFields() async throws {
        let recorder = CoordinatorFrameRecorder()
        let capacity = ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: capacity,
            modelHash: String(repeating: "a", count: 64)
        )
        let client = try await makeClient(status: status, recorder: recorder, enableWarmSwap: false)
        await AutoUpdateEventStore.shared.clear()

        try await client.sendHeartbeatForTest()
        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)
        let heartbeatJSON = Self.jsonString(heartbeat)
        let helloJSON = Self.jsonString(await client.helloMessage())
        let expectedHeartbeat = """
        {"avg_latency_ms_since_last":null,"max_concurrency":1,"max_context_tokens":20000,"model_id":"model-a","model_params_b":0,"ram_gb":\(capacity.ramGB),"requests_served_since_last":0,"slots_free":1,"slots_total":1,"status":"ready","throughput_tps_estimate":0,"throughput_tps_since_last":null,"type":"heartbeat"}
        """
        let expectedHello = """
        {"attestation":null,"binary_version":"\(CoordinatorClient.binaryVersion)","hostname":"\(Host.current().localizedName ?? "unknown")","max_concurrency":1,"max_context_tokens":20000,"model_hash":"\(String(repeating: "a", count: 64))","model_id":"model-a","model_params_b":0,"provider_id":"provider-test","ram_gb":\(capacity.ramGB),"throughput_tps_estimate":0,"tier":1,"type":"hello","version":1}
        """

        XCTAssertFalse(heartbeatJSON.contains("\"model_hash\""), heartbeatJSON)
        XCTAssertFalse(heartbeatJSON.contains("\"loading\""), heartbeatJSON)
        XCTAssertFalse(helloJSON.contains("\"loading\""), helloJSON)
        XCTAssertEqual(heartbeatJSON, expectedHeartbeat)
        XCTAssertEqual(helloJSON, expectedHello)
    }

    func testHeartbeatEnabledModeReadyEmitsLoadingFalse() async throws {
        let recorder = CoordinatorFrameRecorder()
        let runtimeHash = String(repeating: "1", count: 64)
        let runtime = makeRuntime(modelID: "model-b", modelHash: runtimeHash, warmSwapEnabled: true)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder, enableWarmSwap: true, modelRuntime: runtime)

        try await client.sendHeartbeatForTest()
        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)
        let json = Self.jsonString(heartbeat)

        XCTAssertEqual(heartbeat["model_id"] as? String, "model-b")
        XCTAssertEqual(heartbeat["model_hash"] as? String, runtimeHash)
        XCTAssertEqual(heartbeat["loading"] as? Bool, false)
        XCTAssertTrue(json.contains("\"\(runtimeHash)\""), json)
        XCTAssertTrue(json.contains("\"loading\":false"), json)
        XCTAssertNotNil(runtimeHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression))
    }

    func testHeartbeatEnabledModeLoadingEmitsLoadingTrue() async throws {
        let recorder = CoordinatorFrameRecorder()
        let gate = SwapLoaderGate()
        let oldHash = String(repeating: "2", count: 64)
        let newHash = String(repeating: "3", count: 64)
        let runtime = makeRuntime(modelID: "model-a", modelHash: oldHash, warmSwapEnabled: true) { target in
            try await gate.waitForRelease()
            return (target, newHash)
        }
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder, enableWarmSwap: true, modelRuntime: runtime)

        let swapTask = try await runtime.beginSwap(targetModelID: "model-b")
        try await Self.waitUntil {
            await runtime.currentSnapshot().state == .loading
        }
        try await client.sendHeartbeatForTest()
        await gate.release()
        try await swapTask.value
        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)
        let json = Self.jsonString(heartbeat)

        XCTAssertEqual(heartbeat["model_hash"] as? String, oldHash)
        XCTAssertEqual(heartbeat["loading"] as? Bool, true)
        XCTAssertTrue(json.contains("\"loading\":true"), json)
    }

    func testHeartbeatEnabledModeOmitsModelHashWhenNil() async throws {
        let recorder = CoordinatorFrameRecorder()
        let runtime = makeRuntime(modelID: nil, modelHash: nil, warmSwapEnabled: true)
        let status = ProviderStatus(
            modelID: nil,
            modelLoaded: false,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder, enableWarmSwap: true, modelRuntime: runtime)

        try await client.sendHeartbeatForTest()
        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)
        let json = Self.jsonString(heartbeat)

        XCTAssertNil(heartbeat["model_hash"])
        XCTAssertEqual(heartbeat["loading"] as? Bool, false)
        XCTAssertFalse(json.contains("\"model_hash\""), json)
        XCTAssertTrue(json.contains("\"loading\":false"), json)
    }

    func testHelloDisabledModeReadsFromProviderStatus() async throws {
        let recorder = CoordinatorFrameRecorder()
        let runtime = makeRuntime(modelID: "model-a", modelHash: "runtime-hash", warmSwapEnabled: true)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: "boot-hash"
        )
        let client = try await makeClient(status: status, recorder: recorder, enableWarmSwap: false, modelRuntime: runtime)

        let hello = await client.helloMessage()
        let json = Self.jsonString(hello)

        XCTAssertEqual(hello["model_hash"] as? String, "boot-hash")
        XCTAssertTrue(json.contains("\"model_hash\":\"boot-hash\""), json)
        XCTAssertFalse(json.contains("runtime-hash"), json)
    }

    func testHeartbeatDisabledModeKeepsProviderStatusModelIDWhenRuntimeDiffers() async throws {
        let recorder = CoordinatorFrameRecorder()
        let runtime = makeRuntime(modelID: "model-b", modelHash: "runtime-hash", warmSwapEnabled: true)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: "boot-hash"
        )
        let client = try await makeClient(status: status, recorder: recorder, enableWarmSwap: false, modelRuntime: runtime)

        try await client.sendHeartbeatForTest()
        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)

        XCTAssertEqual(heartbeat["model_id"] as? String, "model-a")
        XCTAssertNil(heartbeat["loading"])
    }

    func testHelloDisabledModeKeepsProviderStatusModelIDWhenRuntimeDiffers() async throws {
        let recorder = CoordinatorFrameRecorder()
        let runtime = makeRuntime(modelID: "model-b", modelHash: "runtime-hash", warmSwapEnabled: true)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: "boot-hash"
        )
        let client = try await makeClient(status: status, recorder: recorder, enableWarmSwap: false, modelRuntime: runtime)

        let hello = await client.helloMessage()

        XCTAssertEqual(hello["model_id"] as? String, "model-a")
        XCTAssertEqual(hello["model_hash"] as? String, "boot-hash")
    }

    // Issue #189: a URLSessionWebSocketTask.send() that never returns
    // (TCP half-open) must surface as a throwable timeout, NOT a
    // silent hang. The bounded wrapper is the timeout boundary.
    func testHeartbeatBoundedSendThrowsWhenSendHangs() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        // sendOverride sleeps far longer than the 5s send-timeout; if the
        // bound is missing this test would hang for 30s and the harness
        // would surface that as a timeout failure.
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            sendOverride: { _ in
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        )

        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try await client.sendHeartbeatBoundedForTest()
            XCTFail("expected CoordinatorHeartbeatSendTimeout")
        } catch is CoordinatorHeartbeatSendTimeout {
            // expected
        } catch is CancellationError {
            // also acceptable — the racing send task can lose the
            // cancellation race and surface as a CancellationError.
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
        // Bound is 5s; allow 1s of slack on busy CI runners. The
        // important guarantee is that we did NOT wait the full 30s.
        XCTAssertLessThan(elapsedNs, 10 * 1_000_000_000, "bounded send should not block beyond ~5s, got \(elapsedNs)ns")
    }

    // Issue #189: the watchdog is the App-Nap insurance — if the
    // heartbeat task itself stops being scheduled, an independent
    // observer must fire the exit hook so launchd respawns the
    // process.
    func testHeartbeatWatchdogFiresExitHookOnStaleness() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let captured = CapturedWatchdogReason()
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            watchdogExitHook: { reason in
                Task { await captured.set(reason) }
            }
        )

        // Tolerance = 3 × intervalSeconds. interval=1 → tolerance=3s.
        // Seeding age=5s puts us safely past tolerance on the first
        // 0.5s check tick.
        await client.seedLastHeartbeatSuccessForTest(ageNanoseconds: 5 * 1_000_000_000)
        await client.startHeartbeatWatchdogForTest(intervalSeconds: 1)

        try await Self.waitUntil(timeoutNanoseconds: 5_000_000_000) {
            await captured.value() != nil
        }
        let reason = await captured.value()
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("heartbeat liveness") ?? false, reason ?? "<nil>")
        await client.cancelHeartbeatWatchdogForTest()
    }

    // Issue #189 R1 security MEDIUM: inbound traffic must also count
    // as heartbeat liveness. If the coordinator stops responding but
    // the OS keeps queuing our sends, the watchdog must still fire
    // — and conversely, fresh inbound activity must keep it quiet
    // even when no sends have happened. The handler hook bumps
    // recordHeartbeatSuccess on every received frame.
    func testHandleBumpsHeartbeatSuccessOnInboundActivity() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)

        // Seed the success timestamp far in the past — well beyond
        // any plausible tolerance.
        await client.seedLastHeartbeatSuccessForTest(ageNanoseconds: 60 * 1_000_000_000)
        let staleAge = await client.nanosecondsSinceLastHeartbeatSuccessForTest()
        XCTAssertGreaterThan(staleAge, 30 * 1_000_000_000)

        // An inbound message must reset the watchdog clock. We can
        // route a valid coordinator JSON frame through the handle()
        // hook by invoking the public preflight test seam path; any
        // received frame is fine since the bump happens before the
        // switch on type. We use a malformed frame, which produces
        // a NAK send to the recorder but still trips the bump first.
        try await client.handleForTest(.string("{\"type\":\"hello_ack\",\"interval\":5}"))
        let freshAge = await client.nanosecondsSinceLastHeartbeatSuccessForTest()
        XCTAssertLessThan(freshAge, 5 * 1_000_000_000, "inbound message did not bump heartbeat clock; age=\(freshAge)ns")
    }

    // Issue #189: while the heartbeat is healthy the watchdog must
    // NOT fire. A flapping watchdog would be worse than the bug it
    // tries to mitigate.
    func testHeartbeatWatchdogDoesNotFireWhenSendsAreRecent() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let captured = CapturedWatchdogReason()
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            watchdogExitHook: { reason in
                Task { await captured.set(reason) }
            }
        )

        // interval=1 → tolerance=3s. Seed last-success age WELL below
        // tolerance and run a couple of watchdog ticks; the hook must
        // not fire.
        await client.seedLastHeartbeatSuccessForTest(ageNanoseconds: 0)
        await client.startHeartbeatWatchdogForTest(intervalSeconds: 1)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let reason = await captured.value()
        XCTAssertNil(reason, "watchdog fired on a fresh heartbeat: \(reason ?? "")")
        await client.cancelHeartbeatWatchdogForTest()
    }

    func testHelloEnabledModeReadsFromModelRuntime() async throws {
        let recorder = CoordinatorFrameRecorder()
        let runtime = makeRuntime(modelID: "model-b", modelHash: "runtime-hash", warmSwapEnabled: true)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: "boot-hash"
        )
        let client = try await makeClient(status: status, recorder: recorder, enableWarmSwap: true, modelRuntime: runtime)

        let hello = await client.helloMessage()
        let json = Self.jsonString(hello)

        XCTAssertEqual(hello["model_id"] as? String, "model-b")
        XCTAssertEqual(hello["model_hash"] as? String, "runtime-hash")
        XCTAssertTrue(json.contains("\"model_id\":\"model-b\""), json)
        XCTAssertTrue(json.contains("\"model_hash\":\"runtime-hash\""), json)
        XCTAssertFalse(json.contains("boot-hash"), json)
    }

    // Issue #203: authInitialMessage (v2 auth on connect/reconnect) must
    // source model_id and model_hash from ModelRuntime.currentSnapshot()
    // when warm-swap is enabled, exactly like helloMessage does. Without
    // this, a reconnect after a completed warm-swap re-admits the
    // provider with stale pre-swap metadata until the next regular
    // heartbeat corrects it — coordinator routing decisions in that
    // window use the wrong model_id.
    func testAuthInitialEnabledModeReadsFromModelRuntime() async throws {
        let recorder = CoordinatorFrameRecorder()
        let runtime = makeRuntime(modelID: "model-b", modelHash: "runtime-hash", warmSwapEnabled: true)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: "boot-hash"
        )
        let client = try await makeClient(status: status, recorder: recorder, enableWarmSwap: true, modelRuntime: runtime)

        let attempt = Tier2AuthAttempt()
        let auth = await client.authInitialMessage(attempt: attempt)
        let json = Self.jsonString(auth)

        XCTAssertEqual(auth["model_id"] as? String, "model-b",
                       "auth_request must publish runtime modelID, not ProviderStatus's pre-swap value")
        XCTAssertEqual(auth["model_hash"] as? String, "runtime-hash",
                       "auth_request must publish runtime modelHash, not ProviderStatus's boot-time value")
        let supportedModels = try XCTUnwrap(auth["supported_models"] as? [String])
        XCTAssertTrue(supportedModels.contains("model-b"),
                      "supported_models must validate against post-swap modelID: \(supportedModels)")
        XCTAssertFalse(json.contains("boot-hash"),
                       "auth payload must not leak the pre-swap boot hash: \(json)")
        XCTAssertFalse(json.contains("\"model_id\":\"model-a\""),
                       "auth payload must not leak the pre-swap modelID: \(json)")
    }

    // Counterpart to testHelloDisabledModeReadsFromProviderStatus —
    // when warm-swap is disabled, authInitialMessage continues to
    // source from ProviderStatus (no behavioral change for the
    // default path).
    func testAuthInitialDisabledModeReadsFromProviderStatus() async throws {
        let recorder = CoordinatorFrameRecorder()
        // Runtime would carry a different value, but warmSwapEnabled=false
        // makes authInitialMessage ignore it.
        let runtime = makeRuntime(modelID: "model-runtime", modelHash: "runtime-hash", warmSwapEnabled: false)
        let status = ProviderStatus(
            modelID: "model-status",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: "status-hash"
        )
        let client = try await makeClient(status: status, recorder: recorder, enableWarmSwap: false, modelRuntime: runtime)

        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())

        XCTAssertEqual(auth["model_id"] as? String, "model-status")
        XCTAssertEqual(auth["model_hash"] as? String, "status-hash")
    }

    func testHelloDuringInFlightSwapReturnsOldHash() async throws {
        let recorder = CoordinatorFrameRecorder()
        let gate = SwapLoaderGate()
        let runtime = makeRuntime(modelID: "A", modelHash: "old-hash", warmSwapEnabled: true) { target in
            try await gate.waitForRelease()
            return (target, "new-hash")
        }
        let status = ProviderStatus(
            modelID: "A",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: "boot-hash"
        )
        let client = try await makeClient(status: status, recorder: recorder, enableWarmSwap: true, modelRuntime: runtime)

        let swapTask = try await runtime.beginSwap(targetModelID: "B")
        try await Self.waitUntil {
            await runtime.currentSnapshot().state == .loading
        }
        let inFlightHello = await client.helloMessage()
        await gate.release()
        try await swapTask.value
        let completedHello = await client.helloMessage()

        XCTAssertEqual(inFlightHello["model_hash"] as? String, "old-hash")
        XCTAssertNotEqual(inFlightHello["model_hash"] as? String, "new-hash")
        XCTAssertEqual(completedHello["model_hash"] as? String, "new-hash")
    }

    func testSwapCompletionTriggersImmediateHeartbeat() async throws {
        let recorder = CoordinatorFrameRecorder()
        let newHash = String(repeating: "4", count: 64)
        let runtime = makeRuntime(modelID: "model-a", modelHash: String(repeating: "5", count: 64), warmSwapEnabled: true) { target in
            (target, newHash)
        }
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            enableWarmSwap: true,
            modelRuntime: runtime,
            connectAndRunOverride: {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        )

        await client.start()
        await client.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        let swapTask = try await runtime.beginSwap(targetModelID: "model-b")
        try await swapTask.value
        try await Self.waitUntil(timeoutNanoseconds: 500_000_000) {
            let frames = await recorder.frames
            return frames.contains { frame in
                frame["type"] as? String == "heartbeat"
                    && frame["model_hash"] as? String == newHash
                    && frame["loading"] as? Bool == false
            }
        }
        await client.stop()

        let frames = await recorder.frames
        let matchingHeartbeats = frames.filter { $0["type"] as? String == "heartbeat" && $0["model_hash"] as? String == newHash }
        XCTAssertEqual(matchingHeartbeats.count, 1)
    }

    func testReceiptRotationTimeoutCancelsCandidateSocketAndRestartsReconnect() async throws {
        let committed = LockedBox(false)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = true
        let newKey = Curve25519.Signing.PrivateKey()
        let candidatePublicKey = Data(newKey.publicKey.rawRepresentation).base64EncodedString()
        let candidateResponder = FakeTier2AuthResponder(outcome: .accepted)
        let candidateSocket = FakeProviderWebSocketTask(
            receiveResults: [],
            receiveOverrideIgnoresCancellation: true,
            receiveOverride: { socket in
                let sleeper = Task.detached {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                await sleeper.value
                return try await candidateResponder.receive(from: socket)
            }
        )
        let restoreResponder = FakeTier2AuthResponder(outcome: .accepted)
        let restoreSocket = FakeProviderWebSocketTask(
            receiveResults: [],
            receiveOverride: { socket in
                try await restoreResponder.receive(from: socket)
            }
        )
        let factory = FakeProviderWebSocketFactory(sockets: [candidateSocket, restoreSocket])
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            reconnectGraceNanoseconds: 1_000_000,
            receiptKeyRotationTimeoutNanoseconds: 20_000_000,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil },
            connectAndRunOverride: { throw CancellationError() },
            providerReceiptPublicKey: "old-receipt-public-key"
        ))

        let startedAt = Date()
        do {
            try await client.reconnectWithNewKey(newKey) {
                committed.set(true)
            }
            XCTFail("rotation should time out")
        } catch let error as CoordinatorReceiptRotationTimeout {
            XCTAssertLessThanOrEqual(error.timeoutSeconds, 0.02)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertFalse(committed.get())
        XCTAssertGreaterThan(candidateSocket.cancelCountSnapshot(), 0)
        XCTAssertTrue(restoreSocket.sentFrames().contains { frame in
            frame["type"] as? String == "state_update"
        })
        try await Task.sleep(nanoseconds: 250_000_000)
        let restoreFrames = restoreSocket.sentFrames()
        XCTAssertTrue(restoreFrames.contains { frame in
            frame["provider_receipt_public_key"] as? String == "old-receipt-public-key"
        })
        XCTAssertFalse(restoreFrames.contains { frame in
            frame["provider_receipt_public_key"] as? String == candidatePublicKey
        })
        XCTAssertTrue(candidateSocket.sentFrames().contains { frame in
            frame["provider_receipt_public_key"] as? String == candidatePublicKey
        })
        await client.stop()
    }

    func testPreStagedSuccessSentinelMismatchDoesNotCleanupPendingOrBackup() async throws {
        let fixture = try Self.makeAutoupdateRecoveryFixture(targetVersion: CoordinatorClient.binaryVersion)
        let mismatchedUpdateID = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        try fixture.store.writeSuccessSentinel(
            binaryURL: fixture.binary,
            updateID: mismatchedUpdateID,
            targetVersion: CoordinatorClient.binaryVersion
        )
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let recorder = CoordinatorFrameRecorder()
        let client = try await makeClient(status: status, recorder: recorder)
        await AutoUpdateEventStore.shared.clear()

        await client.runStartupAutoupdateRecoveryForTest(binaryURL: fixture.binary, markerStore: fixture.store)

        XCTAssertEqual(try String(contentsOf: fixture.binary), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.lockURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.successSentinelPath(binaryURL: fixture.binary, updateID: mismatchedUpdateID).path))
        let event = await AutoUpdateEventStore.shared.lastWireObject()
        XCTAssertEqual(event?["failure_class"] as? String, AutoUpdateFailureClass.orphanedSuccessSentinel.rawValue)
        XCTAssertEqual(event?["reason"] as? String, "update_id_mismatch")
        let frames = await recorder.frames
        XCTAssertTrue(frames.isEmpty)
    }

    func testSuccessFinalizeOnlyAfterCoordSendReturns() async throws {
        let fixture = try Self.makeAutoupdateRecoveryFixture(targetVersion: CoordinatorClient.binaryVersion)
        try fixture.store.writeSuccessSentinel(
            binaryURL: fixture.binary,
            updateID: fixture.marker.updateID,
            targetVersion: CoordinatorClient.binaryVersion
        )
        let sentinel = fixture.store.successSentinelPath(binaryURL: fixture.binary, updateID: fixture.marker.updateID)
        let gate = SentinelSendGate(sentinel: sentinel)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: CoordinatorFrameRecorder(),
            sendOverride: { frame in
                if frame["type"] as? String == "state_update" {
                    await gate.markSendStarted()
                    await gate.waitForRelease()
                    await gate.markSendReturned()
                }
            }
        )
        await AutoUpdateEventStore.shared.clear()

        let recovery = Task {
            await client.runStartupAutoupdateRecoveryForTest(binaryURL: fixture.binary, markerStore: fixture.store)
        }
        try await Self.waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await gate.started
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))

        await gate.release()
        await recovery.value

        let sendEvents = await gate.events
        XCTAssertEqual(sendEvents, ["send-start", "send-return"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
    }

    func testReceiptRotationRestoreTimeoutDoesNotHangAfterCandidateRejection() async throws {
        let committed = LockedBox(false)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = true
        let candidateResponder = FakeTier2AuthResponder(
            outcome: .rejected(code: "receipt_rotation_grace_active", message: "active previous-key grace")
        )
        let candidateSocket = FakeProviderWebSocketTask(
            receiveResults: [],
            receiveOverride: { socket in
                try await candidateResponder.receive(from: socket)
            }
        )
        let restoreSocket = FakeProviderWebSocketTask(
            receiveResults: [.success(.string("{}"))],
            receiveDelayNanoseconds: 1_000_000_000
        )
        let factory = FakeProviderWebSocketFactory(sockets: [candidateSocket, restoreSocket])
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            reconnectGraceNanoseconds: 1_000_000,
            receiptKeyRotationTimeoutNanoseconds: 200_000_000,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil },
            connectAndRunOverride: { throw CancellationError() },
            providerReceiptPublicKey: "old-receipt-public-key"
        ))

        let startedAt = Date()
        do {
            try await client.reconnectWithNewKey(Curve25519.Signing.PrivateKey()) {
                committed.set(true)
            }
            XCTFail("rotation should surface coordinator rejection")
        } catch let CoordinatorAuthError.rejected(code, _) {
            XCTAssertEqual(code, "receipt_rotation_grace_active")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertFalse(committed.get())
        XCTAssertGreaterThan(restoreSocket.cancelCountSnapshot(), 0)
        await client.stop()
    }

    func testReceiptRotationPostCommitRestoreTimeoutReportsCommittedUnconfirmed() async throws {
        let committed = LockedBox(false)
        let candidateResponder = FakeTier2AuthResponder(outcome: .accepted)
        let candidateSocket = FakeProviderWebSocketTask(
            receiveResults: [],
            sendErrorTypes: ["state_update"],
            receiveOverride: { socket in
                try await candidateResponder.receive(from: socket)
            }
        )
        let restoreSocket = FakeProviderWebSocketTask(
            receiveResults: [.success(.string("{}"))],
            receiveDelayNanoseconds: 1_000_000_000
        )
        let factory = FakeProviderWebSocketFactory(sockets: [candidateSocket, restoreSocket])
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = true
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            reconnectGraceNanoseconds: 1_000_000,
            receiptKeyRotationTimeoutNanoseconds: 20_000_000,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil },
            connectAndRunOverride: { throw CancellationError() },
            providerReceiptPublicKey: "old-receipt-public-key"
        ))

        let startedAt = Date()
        do {
            try await client.reconnectWithNewKey(Curve25519.Signing.PrivateKey()) {
                committed.set(true)
            }
            XCTFail("rotation should report committed publication failure")
        } catch let error as CoordinatorReceiptRotationCommittedRecoveryFailed {
            XCTAssertTrue(error.description.contains("committed locally"), error.description)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.0)
        XCTAssertTrue(committed.get())
        XCTAssertGreaterThan(restoreSocket.cancelCountSnapshot(), 0)
        await client.stop()
    }

    func testReceiptRotationRejectsConcurrentRequests() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = true
        let firstSocket = FakeProviderWebSocketTask(
            receiveResults: [.success(.string("{}"))],
            receiveDelayNanoseconds: 1_000_000_000
        )
        let restoreSocket = FakeProviderWebSocketTask(
            receiveResults: [.success(.string("{}"))],
            receiveDelayNanoseconds: 1_000_000_000
        )
        let factory = FakeProviderWebSocketFactory(sockets: [firstSocket, restoreSocket])
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            reconnectGraceNanoseconds: 1_000_000,
            receiptKeyRotationTimeoutNanoseconds: 1_000_000_000,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil },
            connectAndRunOverride: { throw CancellationError() },
            providerReceiptPublicKey: "old-receipt-public-key"
        ))

        let first = Task {
            try await client.reconnectWithNewKey(Curve25519.Signing.PrivateKey()) {}
        }
        try await Self.waitUntil(timeoutNanoseconds: 500_000_000) {
            firstSocket.resumeCountSnapshot() == 1
        }

        do {
            try await client.reconnectWithNewKey(Curve25519.Signing.PrivateKey()) {}
            XCTFail("second rotation should be rejected while first is in flight")
        } catch is CoordinatorReceiptRotationInProgress {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        first.cancel()
        _ = try? await first.value
        await client.stop()
    }


    func testReceiptRotationPostCommitStateUpdateFailureRestoresNewKeyBeforeSuccess() async throws {
        let committed = LockedBox(false)
        let candidateResponder = FakeTier2AuthResponder(outcome: .accepted)
        let restoreResponder = FakeTier2AuthResponder(outcome: .accepted)
        let candidateSocket = FakeProviderWebSocketTask(
            receiveResults: [],
            sendErrorTypes: ["state_update"],
            receiveOverride: { socket in
                try await candidateResponder.receive(from: socket)
            }
        )
        let restoreSocket = FakeProviderWebSocketTask(
            receiveResults: [],
            receiveOverride: { socket in
                try await restoreResponder.receive(from: socket)
            }
        )
        let factory = FakeProviderWebSocketFactory(sockets: [candidateSocket, restoreSocket])
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = true
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            reconnectGraceNanoseconds: 1_000_000,
            receiptKeyRotationTimeoutNanoseconds: 1_000_000_000,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil },
            connectAndRunOverride: { throw CancellationError() },
            providerReceiptPublicKey: "old-receipt-public-key"
        ))

        let newKey = Curve25519.Signing.PrivateKey()
        let expectedPubkey = Data(newKey.publicKey.rawRepresentation).base64EncodedString()
        try await client.reconnectWithNewKey(newKey) {
            committed.set(true)
        }

        XCTAssertTrue(committed.get())
        XCTAssertGreaterThan(candidateSocket.cancelCountSnapshot(), 0)
        let restoreFrames = restoreSocket.sentFrames()
        XCTAssertTrue(restoreFrames.contains { frame in
            frame["type"] as? String == "auth_request"
                && frame["stage"] as? String == "initial"
                && frame["provider_receipt_public_key"] as? String == expectedPubkey
        })
        XCTAssertTrue(restoreFrames.contains { frame in
            frame["type"] as? String == "state_update"
        })
        await client.stop()
    }

    func testReceiptRotationRejectedCandidateAwaitsOldKeyRestore() async throws {
        let committed = LockedBox(false)
        let candidateResponder = FakeTier2AuthResponder(
            outcome: .rejected(code: "receipt_rotation_grace_active", message: "active previous-key grace")
        )
        let restoreResponder = FakeTier2AuthResponder(outcome: .accepted)
        let candidateSocket = FakeProviderWebSocketTask(
            receiveResults: [],
            receiveOverride: { socket in
                try await candidateResponder.receive(from: socket)
            }
        )
        let restoreSocket = FakeProviderWebSocketTask(
            receiveResults: [],
            receiveOverride: { socket in
                try await restoreResponder.receive(from: socket)
            }
        )
        let factory = FakeProviderWebSocketFactory(sockets: [candidateSocket, restoreSocket])
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = true
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            reconnectGraceNanoseconds: 1_000_000,
            receiptKeyRotationTimeoutNanoseconds: 1_000_000_000,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil },
            connectAndRunOverride: { throw CancellationError() },
            providerReceiptPublicKey: "old-receipt-public-key"
        ))

        do {
            try await client.reconnectWithNewKey(Curve25519.Signing.PrivateKey()) {
                committed.set(true)
            }
            XCTFail("rotation should surface coordinator rejection")
        } catch let CoordinatorAuthError.rejected(code, message) {
            XCTAssertEqual(code, "receipt_rotation_grace_active")
            XCTAssertTrue(message.contains("active previous-key grace"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(committed.get())
        XCTAssertEqual(restoreSocket.resumeCountSnapshot(), 1)
        let restoreInitial = try XCTUnwrap(restoreSocket.sentFrames().first)
        XCTAssertEqual(restoreInitial["provider_receipt_public_key"] as? String, "old-receipt-public-key")
        await client.stop()
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

    func testAuthInitialIncludesReceiptPublicKeyWhenConfigured() async throws {
        let recorder = CoordinatorFrameRecorder()
        let receiptPublicKey = Data(repeating: 0x42, count: 32).base64EncodedString()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            providerReceiptPublicKey: receiptPublicKey
        )

        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())

        XCTAssertEqual(auth["stage"] as? String, "initial")
        XCTAssertEqual(auth["provider_receipt_public_key"] as? String, receiptPublicKey)
    }

    func testAuthInitialOmitsReceiptPublicKeyWhenUnavailableAndProofNeverIncludesIt() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)
        let attempt = Tier2AuthAttempt()

        let auth = await client.authInitialMessage(attempt: attempt)
        let proof = try await client.authProofMessage(challenge: [
            "type": "auth_challenge",
            "version": 2,
            "auth_attempt_id": "auth-test",
            "attestation_challenge": Data(repeating: 0x11, count: 32).base64URLUnpadded(),
        ], attempt: attempt)

        XCTAssertNil(auth["provider_receipt_public_key"])
        XCTAssertNil(proof["provider_receipt_public_key"])
    }

    func testBinaryVersion_AdvertisesSPEC020V17AcrossHandshakeFrames() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)
        let attempt = Tier2AuthAttempt()

        let hello = await client.helloMessage()
        let auth = await client.authInitialMessage(attempt: attempt)

        XCTAssertEqual(CoordinatorClient.binaryVersion, "1.7.6")
        XCTAssertEqual(MacProviderCLI.configuration.version, "1.7.6")
        XCTAssertEqual(hello["binary_version"] as? String, "1.7.6")
        XCTAssertEqual(auth["binary_version"] as? String, "1.7.6")
    }

    func testAuthInitialDefaultsToSingleEntryCatalog() async throws {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-id-from-snapshot"
        config.supportedModels = nil
        config.publishesSupportedModels = false
        let status = ProviderStatus(
            modelID: "model-id-from-snapshot",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            sleepAssertionFactory: { nil }
        ))

        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())
        let json = Self.jsonString(auth)

        XCTAssertTrue(json.contains("\"supported_models\":[\"model-id-from-snapshot\"]"), json)
        XCTAssertFalse(json.contains("\"publishes_supported_models\""), json)
    }

    func testAuthInitialEmitsExplicitCatalogWhenSet() async throws {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "A"
        config.supportedModels = ["A", "B"]
        config.publishesSupportedModels = true
        let status = ProviderStatus(
            modelID: "A",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            sleepAssertionFactory: { nil }
        ))

        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())
        let json = Self.jsonString(auth)

        XCTAssertTrue(json.contains("\"supported_models\":[\"A\",\"B\"]"), json)
        XCTAssertTrue(json.contains("\"publishes_supported_models\":true"), json)
    }

    func testAuthInitialOmitsPublishesWhenFalse() async throws {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "A"
        config.supportedModels = ["A", "B"]
        config.publishesSupportedModels = false
        let status = ProviderStatus(
            modelID: "A",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            sleepAssertionFactory: { nil }
        ))

        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())
        let json = Self.jsonString(auth)

        XCTAssertTrue(json.contains("\"supported_models\":[\"A\",\"B\"]"), json)
        XCTAssertFalse(json.contains("\"publishes_supported_models\""), json)
    }

    func testHelloMessageUnchangedByPhase1A() async throws {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "A"
        config.supportedModels = ["A", "B"]
        config.publishesSupportedModels = true
        let status = ProviderStatus(
            modelID: "A",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            sleepAssertionFactory: { nil }
        ))

        let hello = await client.helloMessage()
        let json = Self.jsonString(hello)

        XCTAssertFalse(json.contains("\"supported_models\""), json)
        XCTAssertFalse(json.contains("\"publishes_supported_models\""), json)
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
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
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

    func testAuthInitialReceiptKeyOverrideWinsDuringRotation() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let recorder = CoordinatorFrameRecorder()
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            providerReceiptPublicKey: "old-receipt-public-key"
        )

        let message = await client.authInitialMessage(
            attempt: Tier2AuthAttempt(),
            providerReceiptPublicKeyOverride: "new-receipt-public-key"
        )

        XCTAssertEqual(message["provider_receipt_public_key"] as? String, "new-receipt-public-key")
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
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonData(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeAutoupdateRecoveryFixture(targetVersion: String) throws -> (home: URL, store: AutoUpdateMarkerStore, marker: AutoUpdatePendingMarker, binary: URL, backup: URL) {
        let home = try makeTemporaryDirectory(prefix: "coordinator-autoupdate-")
        let store = AutoUpdateMarkerStore(homeDirectory: home)
        try store.ensureTrustedRoot()
        try Data().write(to: store.lockURL)
        let binaryDir = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let updateID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let binary = binaryDir.appendingPathComponent("macprovider-cli")
        let backup = binaryDir.appendingPathComponent(".macprovider-cli.rollback-\(updateID)")
        try Data("new".utf8).write(to: binary)
        try Data("old".utf8).write(to: backup)
        let marker = AutoUpdatePendingMarker(
            updateID: updateID,
            targetVersion: targetVersion,
            targetPath: binary.path,
            backupPath: backup.path,
            size: 3,
            mode: 0o755,
            sha256: AutoUpdateEvent.sha256Hex("old"),
            markerDeadline: ISO8601DateFormatter.coordinatorAutoupdateTest.string(from: Date().addingTimeInterval(300))
        )
        try store.writePending(marker)
        return (home, store, marker, binary, backup)
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
        receiptKeyRotationTimeoutNanoseconds: UInt64 = 55 * 1_000_000_000,
        enableWarmSwap: Bool = false,
        modelRuntime: ModelRuntime? = nil,
        attestationGenerator: Tier2AttestationTokenGenerating = StaticAttestationGenerator(token: nil),
        pairingController: PairingController? = nil,
        connectAndRunOverride: (@Sendable () async throws -> Void)? = nil,
        providerReceiptPublicKey: String? = nil,
        sendOverride: CoordinatorClient.SendOverride? = nil,
        watchdogExitHook: (@Sendable (String) -> Void)? = nil
    ) async throws -> CoordinatorClient {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.drainTimeoutSeconds = drainTimeoutSeconds
        config.enableWarmSwap = enableWarmSwap
        let runtime: ModelRuntime
        if let modelRuntime {
            runtime = modelRuntime
        } else {
            runtime = try await ModelRuntime(modelID: nil)
        }
        let defaultSendOverride: CoordinatorClient.SendOverride = { frame in
            await recorder.append(frame)
        }
        let defaultWatchdogHook: @Sendable (String) -> Void = { _ in
            XCTFail("watchdog exit hook fired unexpectedly")
        }
        return try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            sendOverride: sendOverride ?? defaultSendOverride,
            reconnectGraceNanoseconds: reconnectGraceNanoseconds,
            receiptKeyRotationTimeoutNanoseconds: receiptKeyRotationTimeoutNanoseconds,
            attestationGenerator: attestationGenerator,
            sleepAssertionFactory: { nil },
            pairingController: pairingController,
            connectAndRunOverride: connectAndRunOverride,
            providerReceiptPublicKey: providerReceiptPublicKey,
            watchdogExitHook: watchdogExitHook ?? defaultWatchdogHook
        ))
    }

    private func makeRuntime(
        modelID: String?,
        modelHash: String? = nil,
        warmSwapEnabled: Bool,
        loader: @escaping @Sendable (String) async throws -> (String, String?) = { target in (target, nil) }
    ) -> ModelRuntime {
        ModelRuntime(
            modelID: modelID,
            modelHash: modelHash,
            warmSwapEnabled: warmSwapEnabled,
            loader: { _ in throw CoordinatorClientTestError.unexpectedContainerLoader },
            testLoader: loader
        )
    }

    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ predicate: () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

private enum CoordinatorClientTestError: Error {
    case unexpectedContainerLoader
    case sendStateUpdateFailed
    case missingProviderECDHPublicKey
}

// Issue #189: thread-safe sink for the injected watchdog exit hook.
private actor CapturedWatchdogReason {
    private var reason: String?
    func set(_ value: String) { reason = value }
    func value() -> String? { reason }
}

private enum FakeTier2AuthOutcome: Sendable {
    case accepted
    case rejected(code: String, message: String)
}

private actor SentinelSendGate {
    private let sentinel: URL
    private(set) var started = false
    private(set) var events: [String] = []
    private var released = false

    init(sentinel: URL) {
        self.sentinel = sentinel
    }

    func markSendStarted() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        started = true
        events.append("send-start")
    }

    func waitForRelease() async {
        while !released {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func markSendReturned() {
        events.append("send-return")
    }

    func release() {
        released = true
    }
}

private extension ISO8601DateFormatter {
    static let coordinatorAutoupdateTest: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

private actor FakeTier2AuthResponder {
    private let outcome: FakeTier2AuthOutcome
    private let assignedID: String
    private let coordinatorPrivateKey = Curve25519.KeyAgreement.PrivateKey()
    private var receiveCount = 0
    private var keyID: String?

    init(outcome: FakeTier2AuthOutcome, assignedID: String = "assigned-rotation") {
        self.outcome = outcome
        self.assignedID = assignedID
    }

    func receive(from socket: FakeProviderWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        receiveCount += 1
        switch receiveCount {
        case 1:
            guard let initial = socket.sentFrames().first else {
                throw CoordinatorClientTestError.missingProviderECDHPublicKey
            }
            guard let providerPublic = initial["provider_ecdh_public_key"] as? String else {
                throw CoordinatorClientTestError.missingProviderECDHPublicKey
            }
            let providerPublicRaw = try Data(base64URLUnpadded: providerPublic)
            let coordinatorPublicRaw = coordinatorPrivateKey.publicKey.rawRepresentation
            let derivedKeyID = fakeTier2KeyID(
                providerID: "provider-test",
                assignedID: assignedID,
                providerPublicKey: providerPublicRaw,
                coordinatorPublicKey: coordinatorPublicRaw,
                selectedAEAD: Tier2ProviderSession.aeadSuite
            )
            keyID = derivedKeyID
            return .string(Self.jsonString([
                "type": "auth_challenge",
                "version": 2,
                "auth_attempt_id": "attempt-rotation",
                "assigned_id": assignedID,
                "attestation_challenge": Data(repeating: 0x77, count: 32).base64URLUnpadded(),
                "attestation_formats": [],
                "coordinator_ecdh_public_key": coordinatorPublicRaw.base64URLUnpadded(),
                "selected_aead_suite": Tier2ProviderSession.aeadSuite,
                "key_id": derivedKeyID,
                "expires_at": "2026-06-22T00:00:00Z",
            ]))
        case 2:
            switch outcome {
            case .accepted:
                return .string(Self.jsonString([
                    "type": "auth_response",
                    "version": 2,
                    "status": "accepted",
                    "assigned_id": assignedID,
                    "heartbeat_interval_s": 30,
                    "tier": "pinned",
                    "tier2_session": [
                        "encrypted_leg": [
                            "enabled": true,
                            "alg": Tier2ProviderSession.aeadSuite,
                            "kid": keyID ?? "",
                        ],
                    ],
                ]))
            case .rejected(let code, let message):
                return .string(Self.jsonString([
                    "type": "auth_response",
                    "version": 2,
                    "status": "rejected",
                    "error": [
                        "code": code,
                        "message": message,
                    ],
                ]))
            }
        default:
            throw CancellationError()
        }
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

private func fakeTier2KeyID(
    providerID: String,
    assignedID: String,
    providerPublicKey: Data,
    coordinatorPublicKey: Data,
    selectedAEAD: String
) -> String {
    var data = Data("macprovider/spec008/pillar-b/transcript/v1".utf8)
    fakeAppendTranscriptField(label: "provider_id", value: Data(providerID.utf8), to: &data)
    fakeAppendTranscriptField(label: "assigned_id", value: Data(assignedID.utf8), to: &data)
    fakeAppendTranscriptField(label: "provider_public", value: providerPublicKey, to: &data)
    fakeAppendTranscriptField(label: "coordinator_public", value: coordinatorPublicKey, to: &data)
    fakeAppendTranscriptField(label: "selected_aead", value: Data(selectedAEAD.utf8), to: &data)
    let transcriptHash = Data(SHA256.hash(data: data))
    return Data(SHA256.hash(data: transcriptHash).prefix(16)).base64URLUnpadded()
}

private func fakeAppendTranscriptField(label: String, value: Data, to data: inout Data) {
    fakeAppendUInt32(UInt32(label.utf8.count), to: &data)
    data.append(Data(label.utf8))
    fakeAppendUInt32(UInt32(value.count), to: &data)
    data.append(value)
}

private func fakeAppendUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private actor SwapLoaderGate {
    private var released = false

    func waitForRelease() async throws {
        while !released {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func release() {
        released = true
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

    private(set) var lastRequest: URLRequest?

    func makeSocket(for request: URLRequest) -> ProviderWebSocketTask {
        queue.sync {
            lastRequest = request
            precondition(!sockets.isEmpty, "fake web socket factory exhausted")
            return sockets.removeFirst()
        }
    }
}

private final class FakeProviderWebSocketTask: ProviderWebSocketTask, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeProviderWebSocketTask")
    private var receiveResults: [Result<URLSessionWebSocketTask.Message, Error>]
    private let receiveDelayNanoseconds: UInt64
    private var sent: [[String: Any]] = []
    private var cancelled = false
    private(set) var resumeCount = 0
    private(set) var cancelCount = 0
    private var pingCount = 0
    private let sendErrorTypes: Set<String>
    private let receiveOverrideIgnoresCancellation: Bool
    private let receiveOverride: (@Sendable (FakeProviderWebSocketTask) async throws -> URLSessionWebSocketTask.Message)?

    init(
        receiveResults: [Result<URLSessionWebSocketTask.Message, Error>],
        receiveDelayNanoseconds: UInt64 = 0,
        sendErrorTypes: Set<String> = [],
        receiveOverrideIgnoresCancellation: Bool = false,
        receiveOverride: (@Sendable (FakeProviderWebSocketTask) async throws -> URLSessionWebSocketTask.Message)? = nil
    ) {
        self.receiveResults = receiveResults
        self.receiveDelayNanoseconds = receiveDelayNanoseconds
        self.sendErrorTypes = sendErrorTypes
        self.receiveOverrideIgnoresCancellation = receiveOverrideIgnoresCancellation
        self.receiveOverride = receiveOverride
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
        if let type = object["type"] as? String, sendErrorTypes.contains(type) {
            throw CoordinatorClientTestError.sendStateUpdateFailed
        }
    }

    func sendPing() async throws {
        queue.sync {
            pingCount += 1
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if receiveDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: receiveDelayNanoseconds)
        }
        if let receiveOverride {
            let isCancelled = queue.sync { cancelled }
            if isCancelled && !receiveOverrideIgnoresCancellation {
                throw CancellationError()
            }
            return try await receiveOverride(self)
        }
        let result = queue.sync {
            if cancelled {
                return Result<URLSessionWebSocketTask.Message, Error>.failure(CancellationError())
            }
            return receiveResults.isEmpty ? Result<URLSessionWebSocketTask.Message, Error>.failure(CancellationError()) : receiveResults.removeFirst()
        }
        return try result.get()
    }

    func cancel(with _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        queue.sync {
            cancelCount += 1
            cancelled = true
        }
    }

    func sentFrames() -> [[String: Any]] {
        queue.sync {
            sent
        }
    }

    func pingCountSnapshot() -> Int {
        queue.sync {
            pingCount
        }
    }

    func resumeCountSnapshot() -> Int {
        queue.sync {
            resumeCount
        }
    }

    func cancelCountSnapshot() -> Int {
        queue.sync {
            cancelCount
        }
    }
}
