import CryptoKit
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class CoordinatorClientTests: XCTestCase {
    func testDiagnosticStatusPayloadIsRedactedAndMatchesProviderSnapshot() async throws {
        let recorder = CoordinatorFrameRecorder()
        let modelHash = String(repeating: "a", count: 64)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: modelHash,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1
        )
        await status.setCoordinatorSession(connected: true, assignedID: "assigned-1", tier: "pinned")
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            providerToken: "mpk_secret_should_not_leave_status"
        )

        let payload = await client.diagnosticStatusPayloadForTest(reason: "session_accepted")
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(payload["type"] as? String, "diagnostic_status")
        XCTAssertEqual(payload["provider_id"] as? String, "provider-test")
        XCTAssertEqual(payload["assigned_id"] as? String, "assigned-1")
        XCTAssertEqual(payload["model_id"] as? String, "model-a")
        XCTAssertEqual(payload["model_loaded"] as? Bool, true)
        XCTAssertEqual(payload["model_hash"] as? String, modelHash)
        XCTAssertTrue((payload["credential"] as? [String: Any])?["token_configured"] as? Bool == true)
        XCTAssertFalse(text.contains("mpk_secret"), text)
    }

    func testDiagnosticStatusRedactsConnectionFailureSecrets() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        await status.setCoordinatorSession(connected: true, assignedID: "assigned-1", tier: "pinned")
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            providerToken: "mpk_secret_should_not_leave_status"
        )
        let hexSecret = String(repeating: "f", count: 64)
        await client.recordConnectionFailureDiagnosticForTest(
            reasonCode: "authentication_required",
            error: CoordinatorAuthError.rejected(
                code: "invalid_token",
                message: "Authorization: Bearer bearer-secret provider_token=mpk_inline_secret token=\(hexSecret)"
            )
        )

        let payload = await client.diagnosticStatusPayloadForTest(reason: "reconnect")
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertTrue(text.contains("authentication_required"), text)
        XCTAssertFalse(text.contains("bearer-secret"), text)
        XCTAssertFalse(text.contains("mpk_inline_secret"), text)
        XCTAssertFalse(text.contains(hexSecret), text)
    }

    func testConnectionFailuresMapToStableRecoveryLifecycleStates() {
        let offline = CoordinatorClient.lifecycleClassification(
            for: URLError(.notConnectedToInternet)
        )
        XCTAssertEqual(offline.state, .networkOffline)
        XCTAssertEqual(offline.reasonCode, "network_offline")

        let authentication = CoordinatorClient.lifecycleClassification(
            for: CoordinatorAuthError.rejected(code: "invalid_token", message: "secret detail")
        )
        XCTAssertEqual(authentication.state, .authenticationRequired)
        XCTAssertEqual(authentication.reasonCode, "authentication_required")

        let identity = CoordinatorClient.lifecycleClassification(
            for: CoordinatorAuthError.rejected(
                code: "identity_signature_required",
                message: "operator detail"
            )
        )
        XCTAssertEqual(identity.state, .identityMigrationRequired)
        XCTAssertEqual(identity.reasonCode, "identity_migration_required")

        let catalog = CoordinatorClient.lifecycleClassification(
            for: CoordinatorAuthError.invalidMessage(
                "coordinator did not accept provider catalog release"
            )
        )
        XCTAssertEqual(catalog.state, .catalogIncompatible)
        XCTAssertEqual(catalog.reasonCode, "catalog_incompatible")

        let compatibilitySet = CoordinatorClient.lifecycleClassification(
            for: CoordinatorAuthError.rejected(
                code: "compatibility_set_unaccepted",
                message: "set is outside coordinator policy"
            )
        )
        XCTAssertEqual(compatibilitySet.state, .catalogIncompatible)
        XCTAssertEqual(compatibilitySet.reasonCode, "catalog_incompatible")

        let protocolFailure = CoordinatorClient.lifecycleClassification(
            for: CoordinatorAuthError.rejected(
                code: "invalid_auth_request",
                message: "wire detail"
            )
        )
        XCTAssertEqual(protocolFailure.state, .failed)
        XCTAssertEqual(protocolFailure.reasonCode, "coordinator_auth_protocol_invalid")

        let unavailable = CoordinatorClient.lifecycleClassification(
            for: URLError(.timedOut)
        )
        XCTAssertEqual(unavailable.state, .coordinatorUnavailable)
        XCTAssertEqual(unavailable.reasonCode, "coordinator_unavailable")

        let pendingHardware = CoordinatorClient.lifecycleClassification(
            for: CoordinatorAuthError.rejected(
                code: "autotune_evidence_required",
                message: "autotune_evidence_required"
            )
        )
        XCTAssertEqual(pendingHardware.state, .coordinatorUnavailable)
        XCTAssertEqual(pendingHardware.reasonCode, "autotune_evidence_required")

        let evidenceRejected = CoordinatorClient.lifecycleClassification(
            for: CoordinatorAuthError.rejected(
                code: "autotune_evidence_invalid",
                message: "autotune_evidence_invalid"
            )
        )
        XCTAssertEqual(evidenceRejected.state, .catalogIncompatible)
        XCTAssertEqual(evidenceRejected.reasonCode, "autotune_evidence_invalid")

        let evidenceBinaryMismatch = CoordinatorClient.lifecycleClassification(
            for: CoordinatorAuthError.rejected(
                code: "autotune_evidence_binary_version_mismatch",
                message: "autotune_evidence_binary_version_mismatch"
            )
        )
        XCTAssertEqual(evidenceBinaryMismatch.state, .catalogIncompatible)
        XCTAssertEqual(evidenceBinaryMismatch.reasonCode, "autotune_evidence_binary_version_mismatch")

        let uncatalogued = CoordinatorClient.lifecycleClassification(
            for: CoordinatorAuthError.rejected(
                code: "autotune_model_uncatalogued",
                message: "autotune_model_uncatalogued"
            )
        )
        XCTAssertEqual(uncatalogued.state, .catalogIncompatible)
        XCTAssertEqual(uncatalogued.reasonCode, "autotune_model_uncatalogued")

        let capExceeded = CoordinatorClient.lifecycleClassification(
            for: CoordinatorAuthError.rejected(
                code: "autotune_model_cap_exceeded",
                message: "autotune_model_cap_exceeded"
            )
        )
        XCTAssertEqual(capExceeded.state, .catalogIncompatible)
        XCTAssertEqual(capExceeded.reasonCode, "autotune_model_cap_exceeded")
    }

    func testOperatorPauseAndResumeFenceRequestsAndPublishCoordinatorState() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)

        let pauseResult = await client.pauseByOperator()
        let pausedSnapshot = await status.snapshot()
        let pausedRequest = await status.beginRequestIfAccepting(requestID: "paused-request")
        XCTAssertEqual(pauseResult, .accepted)
        XCTAssertEqual(pausedSnapshot.status, .unavailable)
        XCTAssertNil(pausedRequest)

        let pauseReplay = await client.pauseByOperator()
        let resumeResult = await client.resumeByOperator()
        let resumedSnapshot = await status.snapshot()
        let resumedRequest = await status.beginRequestIfAccepting(requestID: "resumed-request")
        XCTAssertEqual(pauseReplay, .accepted, "pause replay must be idempotent")
        XCTAssertEqual(resumeResult, .accepted)
        XCTAssertEqual(resumedSnapshot.status, .ready)
        XCTAssertNotNil(resumedRequest)

        let frames = await recorder.frames
        let states = frames.compactMap { frame -> String? in
            guard frame["type"] as? String == "state_update" else { return nil }
            return frame["state"] as? String
        }
        XCTAssertEqual(states, ["draining", "unavailable", "ready"])
    }

    func testAcceptedStateUpdateAlsoPublishesDiagnosticStatus() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)
        try await client.handleCoordinatorPayloadForTest([
            "type": "hello_ack",
            "assigned_id": "assigned-v1",
            "heartbeat_interval_s": 30,
        ])
        let admissionFrameCount = await recorder.frames.count

        let pauseResult = await client.pauseByOperator()

        XCTAssertEqual(pauseResult, .accepted)
        let frames = await recorder.frames
        let newFrames = Array(frames.dropFirst(admissionFrameCount))
        guard let pauseStateIndex = newFrames.firstIndex(where: { frame in
            frame["type"] as? String == "state_update" &&
                frame["reason"] as? String == "operator_pause_draining"
        }) else {
            XCTFail("missing operator pause state_update in \(newFrames)")
            return
        }
        XCTAssertGreaterThan(newFrames.count, pauseStateIndex + 1)
        let diagnostic = newFrames[pauseStateIndex + 1]
        XCTAssertEqual(diagnostic["type"] as? String, "diagnostic_status")
        XCTAssertEqual(diagnostic["reason"] as? String, "operator_pause_draining")
        XCTAssertEqual(diagnostic["assigned_id"] as? String, "assigned-v1")
    }

    func testDiagnosticStatusFailureDoesNotFailAcceptedStateUpdate() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            sendOverride: { frame in
                await recorder.append(frame)
                if frame["type"] as? String == "diagnostic_status" {
                    throw CoordinatorClientTestError.sendStateUpdateFailed
                }
            }
        )
        try await client.handleCoordinatorPayloadForTest([
            "type": "hello_ack",
            "assigned_id": "assigned-v1",
            "heartbeat_interval_s": 30,
        ])
        let admissionFrameCount = await recorder.frames.count

        let pauseResult = await client.pauseByOperator()

        XCTAssertEqual(pauseResult, .accepted)
        let frames = await recorder.frames
        let newFrames = Array(frames.dropFirst(admissionFrameCount))
        XCTAssertTrue(newFrames.contains { frame in
            frame["type"] as? String == "state_update" &&
                frame["reason"] as? String == "operator_pause_draining"
        }, "state_update should still be sent when diagnostic_status fails: \(newFrames)")
        XCTAssertTrue(newFrames.contains { $0["type"] as? String == "diagnostic_status" })
    }

    func testIdlePrewarmEventIsNotSentBeforeCoordinatorAcceptsSession() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)

        await client.sendIdlePrewarmEvent(event: "idle_prewarm_skipped", reason: "idle_prewarmer_disabled")

        let frames = await recorder.frames
        XCTAssertTrue(frames.isEmpty, "pre-auth idle prewarm event must not race ahead of auth: \(frames)")
    }

    func testWarmSwapCompletionDoesNotSendHeartbeatBeforeCoordinatorAcceptsSession() async throws {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.enableWarmSwap = true
        config.wsTunneledMode = true
        let runtime = makeRuntime(modelID: "model-a", warmSwapEnabled: true)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let socket = FakeProviderWebSocketTask(
            receiveResults: [],
            receiveOverride: { _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                throw CancellationError()
            }
        )
        let factory = FakeProviderWebSocketFactory(sockets: [socket])
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            reconnectGraceNanoseconds: 1_000_000,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil }
        ))

        await client.start()
        try await Task.sleep(nanoseconds: 10_000_000)
        let swapTask = try await runtime.beginSwap(targetModelID: "model-b")
        try await swapTask.value
        try await Task.sleep(nanoseconds: 50_000_000)
        await client.stop()

        let frames = socket.sentFrames()
        XCTAssertFalse(frames.contains { $0["type"] as? String == "heartbeat" },
                       "pre-auth warm-swap completion must not race a heartbeat ahead of auth: \(frames)")
    }

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

    func testEncryptedLosslessnessProbeRejectsCarrierRequestIDMismatch() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder, losslessnessProbeEnabled: true)
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
            "tier2_session": [
                "encrypted_leg": [
                    "enabled": true,
                    "alg": Tier2ProviderSession.aeadSuite,
                    "kid": "kid-test",
                ],
            ],
        ], session: session)

        let payload: [String: Any] = [
            "probe_version": LosslessnessProbeProtocol.version,
            "probe_id": "payload-probe",
            "probe_nonce": "00112233445566778899aabbccddeeff",
            "expires_at": "2026-07-09T12:01:00Z",
            "model_id": "model-a",
            "target_model_hash": "sha256:target",
            "target_generation": 1,
            "draft_model_id": "draft-a",
            "draft_artifact_binding": [
                "draft_model_id": "draft-a",
                "draft_artifact_sha256": "sha256:draft",
                "tokenizer_identity": "tok-v1",
                "compatibility_check_digest": "sha256:compat",
            ],
            "draft_generation": 1,
            "tokenizer_identity": "tok-v1",
            "sampling_profile": [
                "temperature": 0.7,
                "top_p": 1.0,
            ],
            "corpus_version": "corpus-v1",
            "threshold_version": "threshold-v1",
            "prompts": [
                [
                    "prompt_id": "synthetic-1",
                    "prompt": "Synthetic coordinator-owned prompt.",
                    "coordinator_owned": true,
                    "buyer_origin": false,
                ],
            ],
            "measurement_positions": [4],
            "requested_k": 64,
            "support_selection": LosslessnessProbeProtocol.supportSelection,
            "max_prompts": 4,
            "max_stochastic_positions": 8,
            "timeout_ms": 60_000,
        ]
        let digest = try LosslessnessProbeProtocol.digest(payload: payload)
        let outer: [String: Any] = [
            "type": LosslessnessProbeProtocol.requestType,
            "probe_id": "payload-probe",
            "probe_request_digest": digest,
            "payload": payload,
        ]
        let encrypted = try Tier2ProviderSession.sealLosslessnessRequestForTest(
            session: session,
            requestID: "carrier-probe",
            outerEnvelope: outer
        )

        try await client.handleCoordinatorPayloadForTest(encrypted)

        let frames = await recorder.frames
        let nak = try XCTUnwrap(frames.last)
        XCTAssertEqual(nak["type"] as? String, "nak")
        XCTAssertEqual(nak["in_reply_to"] as? String, LosslessnessProbeProtocol.encryptedRequestType)
        let error = try XCTUnwrap(nak["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_message")
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

    func testSignedRecoveryDrainDoesNotRequireCoordinatorWebSocket() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: CoordinatorFrameRecorder(),
            sendOverride: { _ in throw CoordinatorClientTestError.sendStateUpdateFailed }
        )

        let drained = await client.autoupdateLocalDrainForTest(target: "1.8.41")

        XCTAssertTrue(drained)
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.status, .draining)
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

    func testTier2InvalidAuthRequestCloseIsClassifiedForRecovery() async throws {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = true
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let socket = FakeProviderWebSocketTask(
            receiveResults: [.failure(CoordinatorClientTestError.closedByCoordinator)],
            closeCodeRawValue: 4001,
            closeReasonText: "invalid_auth_request: type\nforged\u{2028}line"
        )
        let factory = FakeProviderWebSocketFactory(sockets: [socket])
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil }
        ))

        do {
            try await client.connectAndRunOnceForTest()
            XCTFail("invalid auth_request close should throw")
        } catch let CoordinatorAuthError.rejected(code, message) {
            XCTAssertEqual(code, "invalid_auth_request")
            XCTAssertEqual(message, "invalid_auth_request: type forged line")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTier2ReferralCloseIsTypedWithoutEchoingRawCode() async throws {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "mp-0123456789abcdef0123456789abcdef"
        config.model = "model-a"
        let receiptKey = Curve25519.Signing.PrivateKey()
        let receiptPublicKey = Data(receiptKey.publicKey.rawRepresentation).base64EncodedString()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: false,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let socket = FakeProviderWebSocketTask(
            receiveResults: [.failure(CoordinatorClientTestError.closedByCoordinator)],
            closeCodeRawValue: 4005,
            closeReasonText: "referral_expired"
        )
        let factory = FakeProviderWebSocketFactory(sockets: [socket])
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil },
            providerReceiptPublicKey: receiptPublicKey,
            credentialBootstrap: true,
            bootstrapReceiptSigningKey: receiptKey,
            bootstrapReferralCode: "MAL1-S-key-issuer-secret-tag"
        ))

        do {
            try await client.connectAndRunOnceForTest()
            XCTFail("terminal referral close should throw")
        } catch let CoordinatorAuthError.rejected(code, message) {
            XCTAssertEqual(code, "referral_expired")
            XCTAssertEqual(message, "referral_expired")
            XCTAssertFalse(message.contains("MAL1"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRepeatedInvalidAuthRequestFailuresFireRecoveryHook() async throws {
        let recorder = CoordinatorFrameRecorder()
        let attempts = ReconnectAttemptRecorder()
        let captured = CapturedWatchdogReason()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let preparationRan = LockedBox(false)
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            reconnectInitialBackoffNanoseconds: 1_000_000,
            connectAndRunOverride: {
                _ = await attempts.recordAttempt()
                throw CoordinatorAuthError.rejected(
                    code: "invalid_auth_request",
                    message: "invalid auth_request"
                )
            },
            watchdogExitPreparation: {
                preparationRan.set(true)
            },
            watchdogExitHook: { reason in
                XCTAssertTrue(preparationRan.get(), "auth watchdog hook ran before synchronous cleanup")
                Task { await captured.set(reason) }
            }
        )

        await client.suppressSignedRecoveryDiscoveryForTest()
        await client.start()
        try await Self.waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await captured.value() != nil
        }
        await client.stop()

        let attemptCount = await attempts.currentCount()
        XCTAssertEqual(attemptCount, 3)
        let capturedReason = await captured.value()
        let reason = try XCTUnwrap(capturedReason)
        XCTAssertTrue(reason.contains("auth handshake failed 3 consecutive times"), reason)
        XCTAssertTrue(reason.contains("invalid_auth_request"), reason)
    }

    func testTransientReconnectFailureResetsAuthProtocolFailureStreak() async throws {
        let recorder = CoordinatorFrameRecorder()
        let attempts = ReconnectAttemptRecorder()
        let captured = CapturedWatchdogReason()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            reconnectInitialBackoffNanoseconds: 1_000_000,
            connectAndRunOverride: {
                let attempt = await attempts.recordAttempt()
                switch attempt {
                case 1, 2, 4, 5:
                    throw CoordinatorAuthError.rejected(
                        code: "invalid_auth_request",
                        message: "invalid auth_request"
                    )
                case 3:
                    throw CoordinatorClientTestError.closedByCoordinator
                default:
                    throw CancellationError()
                }
            },
            watchdogExitHook: { reason in
                Task { await captured.set(reason) }
            }
        )

        await client.suppressSignedRecoveryDiscoveryForTest()
        await client.start()
        try await Self.waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await attempts.currentCount() >= 6
        }
        await client.stop()

        let capturedReason = await captured.value()
        XCTAssertNil(capturedReason, "transient reconnect failures should reset the auth protocol failure streak")
        let attemptCount = await attempts.currentCount()
        XCTAssertGreaterThanOrEqual(attemptCount, 6)
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
        XCTAssertEqual(socket.pingCountSnapshot(), 0, "provider auth must not wait for a coordinator PONG")
        XCTAssertTrue(socket.sentFrames().contains { $0["type"] as? String == "hello" })
    }

    func testInvalidInstallerBootstrapBearerRecoversWithSameKeyWithoutResendingStaleToken() async throws {
        let directory = try Self.makeTemporaryDirectory(prefix: "bootstrap-recovery-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.yaml")
        let providerID = "mp-0123456789abcdef0123456789abcdef"
        let staleToken = String(repeating: "a", count: 64)
        let recoveredToken = String(repeating: "b", count: 64)
        try Data("""
        model: model-a
        coordinator_url: wss://127.0.0.1:8444/ws/provider
        provider_id: \(providerID)
        provider_token: \(staleToken)
        """.utf8).write(to: configURL)

        var config = AppConfig.defaults(configPath: configURL.path)
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = providerID
        config.model = "model-a"
        config.providerToken = staleToken
        let receiptKey = Curve25519.Signing.PrivateKey()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let rejected = FakeProviderWebSocketTask(
            receiveResults: [.failure(CancellationError())],
            closeCodeRawValue: 4005,
            closeReasonText: "invalid_token"
        )
        let responder = FakeTier2AuthResponder(
            outcome: .accepted,
            providerID: providerID,
            assignedProviderToken: recoveredToken
        )
        let recovered = FakeProviderWebSocketTask(
            receiveResults: [],
            receiveOverride: { socket in
                try await responder.receive(from: socket)
            }
        )
        let factory = FakeProviderWebSocketFactory(sockets: [rejected, recovered])
        let runtime = try await ModelRuntime(modelID: nil)
        let credentialStore = InMemoryProviderCredentialStore(values: [providerID: staleToken])
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil },
            receiptIdentitySigningKey: receiptKey,
            providerCredentialStore: credentialStore
        ))

        do {
            try await client.connectAndRunOnceForTest()
            XCTFail("successful credential recovery should request an authenticated reconnect")
        } catch is CoordinatorAuthUpgradeReconnect {
        } catch {
            XCTFail("unexpected recovery error: \(error)")
        }

        let requests = factory.requestsSnapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(staleToken)")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        let onDisk = try String(contentsOf: configURL)
        XCTAssertFalse(onDisk.contains("provider_token:"))
        XCTAssertEqual(try credentialStore.load(providerID: providerID), recoveredToken)
        XCTAssertGreaterThan(recovered.cancelCountSnapshot(), 0)
    }

    func testMalibuOriginDoesNotSuppressCLIOwnedBootstrapRecovery() async throws {
        let directory = try Self.makeTemporaryDirectory(prefix: "bootstrap-malibu-boundary-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.yaml")
        let providerID = "mp-00112233445566778899aabbccddeeff"
        let staleToken = String(repeating: "d", count: 64)
        let recoveredToken = String(repeating: "e", count: 64)
        try Data("""
        model: model-a
        coordinator_url: wss://127.0.0.1:8444/ws/provider
        provider_id: \(providerID)
        provider_token: \(staleToken)
        managed_by: malibu-app
        """.utf8).write(to: configURL)

        var config = AppConfig.defaults(configPath: configURL.path)
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = providerID
        config.model = "model-a"
        config.providerToken = staleToken
        config.managedBy = "malibu-app"
        let receiptKey = Curve25519.Signing.PrivateKey()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let rejected = FakeProviderWebSocketTask(
            receiveResults: [.failure(CancellationError())],
            closeCodeRawValue: 4005,
            closeReasonText: "invalid_token"
        )
        let responder = FakeTier2AuthResponder(
            outcome: .accepted,
            providerID: providerID,
            assignedProviderToken: recoveredToken
        )
        let recovered = FakeProviderWebSocketTask(
            receiveResults: [],
            receiveOverride: { socket in
                try await responder.receive(from: socket)
            }
        )
        let factory = FakeProviderWebSocketFactory(sockets: [rejected, recovered])
        let runtime = try await ModelRuntime(modelID: nil)
        let credentialStore = InMemoryProviderCredentialStore(values: [providerID: staleToken])
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil },
            receiptIdentitySigningKey: receiptKey,
            providerCredentialStore: credentialStore
        ))

        do {
            try await client.connectAndRunOnceForTest()
            XCTFail("successful credential recovery should request an authenticated reconnect")
        } catch is CoordinatorAuthUpgradeReconnect {
        } catch {
            XCTFail("unexpected recovery error: \(error)")
        }

        let requests = factory.requestsSnapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(staleToken)")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        let loaded = try ConfigLoader.load(
            cli: CLIOverrides(configPath: configURL.path),
            environment: [:]
        )
        XCTAssertNil(loaded.providerToken)
        XCTAssertEqual(try credentialStore.load(providerID: providerID), recoveredToken)
    }

    func testConfirmedInstallerBootstrapCredentialRecoveryFailsClosedWithoutMutation() async throws {
        let directory = try Self.makeTemporaryDirectory(prefix: "bootstrap-confirmed-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.yaml")
        let providerID = "mp-fedcba9876543210fedcba9876543210"
        let confirmedToken = String(repeating: "c", count: 64)
        try Data("""
        model: model-a
        coordinator_url: wss://127.0.0.1:8444/ws/provider
        provider_id: \(providerID)
        provider_token: \(confirmedToken)
        """.utf8).write(to: configURL)

        var config = AppConfig.defaults(configPath: configURL.path)
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = providerID
        config.model = "model-a"
        config.providerToken = confirmedToken
        let receiptKey = Curve25519.Signing.PrivateKey()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let rejectedBearer = FakeProviderWebSocketTask(
            receiveResults: [.failure(CancellationError())],
            closeCodeRawValue: 4005,
            closeReasonText: "invalid_token"
        )
        let rejectedRecovery = FakeProviderWebSocketTask(
            receiveResults: [.failure(CancellationError())],
            closeCodeRawValue: 4005,
            closeReasonText: "bootstrap_token_used"
        )
        let factory = FakeProviderWebSocketFactory(sockets: [rejectedBearer, rejectedRecovery])
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil },
            receiptIdentitySigningKey: receiptKey
        ))

        do {
            try await client.connectAndRunOnceForTest()
            XCTFail("confirmed credential mismatch must fail closed")
        } catch let CoordinatorAuthError.rejected(code, _) {
            XCTAssertEqual(code, "invalid_token")
        } catch {
            XCTFail("unexpected confirmed-credential error: \(error)")
        }

        let requests = factory.requestsSnapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(confirmedToken)")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        let loaded = try ConfigLoader.load(
            cli: CLIOverrides(configPath: configURL.path),
            environment: [:]
        )
        XCTAssertEqual(loaded.providerToken, confirmedToken)
    }

    func testCredentialBootstrapForcesV2WhenWSTunneledModeIsDisabled() async throws {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = false
        let receiptKey = Curve25519.Signing.PrivateKey()
        let receiptPublicKey = Data(receiptKey.publicKey.rawRepresentation).base64EncodedString()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: false,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let socket = FakeProviderWebSocketTask(receiveResults: [.failure(CancellationError())])
        let factory = FakeProviderWebSocketFactory(sockets: [socket])
        let runtime = try await ModelRuntime(modelID: nil)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            webSocketFactory: { factory.makeSocket(for: $0) },
            sleepAssertionFactory: { nil },
            providerReceiptPublicKey: receiptPublicKey,
            credentialBootstrap: true,
            bootstrapReceiptSigningKey: receiptKey
        ))

        do {
            try await client.connectAndRunOnceForTest()
        } catch {
        }

        let first = try XCTUnwrap(socket.sentFrames().first)
        XCTAssertEqual(first["type"] as? String, "auth_request")
        XCTAssertEqual(first["version"] as? Int, 2)
        XCTAssertEqual(first["stage"] as? String, "initial")
        XCTAssertEqual(first["credential_bootstrap"] as? Bool, true)
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

    func testAdmissionMessagesIncludeInstalledSignedCompatibilitySetID() async throws {
        let recorder = CoordinatorFrameRecorder()
        let setID = "Augustas11/macprovider:v1.8.3@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            compatibilitySetIDOverride: setID
        )

        let hello = await client.helloMessage()
        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())

        XCTAssertEqual(hello["compatibility_set_id"] as? String, setID)
        XCTAssertEqual(auth["compatibility_set_id"] as? String, setID)
    }

    func testConfiguredHelloAckMustEchoInstalledCompatibilitySetID() async throws {
        let recorder = CoordinatorFrameRecorder()
        let installed = "Augustas11/macprovider:v1.8.3@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let target = "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            compatibilitySetIDOverride: installed
        )

        do {
            try await client.handleCoordinatorPayloadForTest([
                "type": "hello_ack",
                "assigned_id": "assigned-v1",
                "heartbeat_interval_s": 30,
            ])
            XCTFail("expected missing compatibility-set policy to fail")
        } catch let CoordinatorAuthError.invalidMessage(message) {
            XCTAssertTrue(message.contains("omitted explicit compatibility-set policy"), message)
        }

        do {
            try await client.handleCoordinatorPayloadForTest([
                "type": "hello_ack",
                "assigned_id": "assigned-v1",
                "heartbeat_interval_s": 30,
                "compatibility_policy": "configured",
                "accepted_compatibility_set_id": target,
                "recommended_compatibility_set_id": target,
            ])
            XCTFail("expected mismatched compatibility-set acknowledgement to fail")
        } catch let CoordinatorAuthError.invalidMessage(message) {
            XCTAssertTrue(message.contains("compatibility-set acknowledgement"), message)
        }
    }

    func testExplicitlyUnconfiguredHelloAckRetainsLegacyAdmission() async throws {
        let recorder = CoordinatorFrameRecorder()
        let installed = "Augustas11/macprovider:v1.8.3@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let target = "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-compatibility-unconfigured-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let markerStore = AutoUpdateMarkerStore(homeDirectory: home)
        try markerStore.persistCompatibilityAdmission(
            acceptedCompatibilitySetID: installed,
            recommendedCompatibilitySetID: target
        )
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            compatibilitySetIDOverride: installed,
            autoupdateMarkerStore: markerStore
        )

        try await client.handleCoordinatorPayloadForTest([
            "type": "hello_ack",
            "assigned_id": "assigned-v1",
            "heartbeat_interval_s": 30,
            "compatibility_policy": "unconfigured",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerStore.compatibilityAdmissionURL.path))
        await client.stop()
    }

    func testConfiguredHelloAckPersistsFreshExactCompatibilityTargetUntilDisconnect() async throws {
        let recorder = CoordinatorFrameRecorder()
        let installed = "Augustas11/macprovider:v1.8.3@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let target = "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-compatibility-configured-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let markerStore = AutoUpdateMarkerStore(homeDirectory: home)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            compatibilitySetIDOverride: installed,
            autoupdateMarkerStore: markerStore
        )

        try await client.handleCoordinatorPayloadForTest([
            "type": "hello_ack",
            "assigned_id": "assigned-v1",
            "heartbeat_interval_s": 30,
            "compatibility_policy": "configured",
            "accepted_compatibility_set_id": installed,
            "recommended_compatibility_set_id": target,
        ])

        let admission = try markerStore.readCompatibilityAdmissionForTest()
        XCTAssertEqual(admission.acceptedCompatibilitySetID, installed)
        XCTAssertEqual(admission.recommendedCompatibilitySetID, target)
        await client.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerStore.compatibilityAdmissionURL.path))
    }

    func testConfiguredAuthResponseRejectsMismatchedCompatibilitySetBeforeSessionAcceptance() async throws {
        let recorder = CoordinatorFrameRecorder()
        let installed = "Augustas11/macprovider:v1.8.3@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let target = "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            compatibilitySetIDOverride: installed
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

        do {
            try await client.acceptAuthResponseForTest([
                "type": "auth_response",
                "version": 2,
                "status": "accepted",
                "assigned_id": "assigned-v2",
                "heartbeat_interval_s": 30,
                "compatibility_policy": "configured",
                "accepted_compatibility_set_id": target,
                "recommended_compatibility_set_id": target,
                "tier2_session": [
                    "encrypted_leg": [
                        "enabled": true,
                        "alg": Tier2ProviderSession.aeadSuite,
                        "kid": "kid-test",
                    ],
                ],
            ], session: session)
            XCTFail("expected mismatched compatibility-set acknowledgement to fail")
        } catch let CoordinatorAuthError.invalidMessage(message) {
            XCTAssertTrue(message.contains("compatibility-set acknowledgement"), message)
        }
        let acceptedKeyID = await client.tier2KeyIDForTest()
        XCTAssertNil(acceptedKeyID)
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

    func testHelloAckAssignedProviderTokenTriggersAuthUpgradeReconnect() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let dir = try Self.makeTemporaryDirectory(prefix: "coordinator-token-reconnect-")
        let configPath = dir.appendingPathComponent("config.yaml").path
        try "provider_id: provider-test\nmodel: model-a\n".write(
            toFile: configPath,
            atomically: true,
            encoding: .utf8
        )
        var config = AppConfig.defaults(configPath: configPath)
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.wsTunneledMode = false
        let runtime = try await ModelRuntime(modelID: nil)
        let credentialStore = InMemoryProviderCredentialStore()
        let credentialStatus = ProviderCredentialStatusRuntime(.unconfigured)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            webSocketFactory: { _ in FakeProviderWebSocketTask(receiveResults: []) },
            sleepAssertionFactory: { nil },
            providerCredentialStore: credentialStore,
            credentialStatusRuntime: credentialStatus
        ))

        do {
            try await client.handleCoordinatorPayloadForTest([
                "type": "hello_ack",
                "assigned_id": "assigned-a",
                "heartbeat_interval_s": 30,
                "assigned_provider_token": "minted-provisional-token",
            ])
            XCTFail("expected CoordinatorAuthUpgradeReconnect")
        } catch is CoordinatorAuthUpgradeReconnect {
            // FR-C9.3: tokenless bootstrap must reconnect with Bearer before serving buyers.
        }
        XCTAssertEqual(try credentialStore.load(providerID: "provider-test"), "minted-provisional-token")
        let persistedCredentialStatus = await credentialStatus.snapshot()
        XCTAssertEqual(
            persistedCredentialStatus,
            ProviderCredentialStatus(source: .cliKeychain, state: .ready, restartSafe: true)
        )
    }

    func testHelloAckAssignedProviderTokenDoesNotAdoptOrWriteYAMLWhenKeychainFails() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let dir = try Self.makeTemporaryDirectory(prefix: "coordinator-token-fallback-")
        defer { try? FileManager.default.removeItem(at: dir) }
        let configPath = dir.appendingPathComponent("config.yaml").path
        try "provider_id: provider-test\nmodel: model-a\n".write(
            toFile: configPath,
            atomically: true,
            encoding: .utf8
        )
        var config = AppConfig.defaults(configPath: configPath)
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        let runtime = try await ModelRuntime(modelID: nil)
        let credentialStore = InMemoryProviderCredentialStore(
            replaceError: NSError(domain: "ProviderCredentialStoreTests", code: 1)
        )
        let credentialStatus = ProviderCredentialStatusRuntime(.unconfigured)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            webSocketFactory: { _ in FakeProviderWebSocketTask(receiveResults: []) },
            sleepAssertionFactory: { nil },
            providerCredentialStore: credentialStore,
            credentialStatusRuntime: credentialStatus
        ))

        do {
            try await client.handleCoordinatorPayloadForTest([
                "type": "hello_ack",
                "assigned_id": "assigned-a",
                "heartbeat_interval_s": 30,
                "assigned_provider_token": "fallback-token",
            ])
            XCTFail("expected credential commit failure")
        } catch let error as CoordinatorAuthError {
            guard case .invalidMessage(let message) = error else {
                XCTFail("unexpected auth error: \(error)")
                return
            }
            XCTAssertEqual(message, "assigned provider credential could not be committed")
        }

        XCTAssertFalse(try String(contentsOfFile: configPath).contains("provider_token:"))
        let persistedCredentialStatus = await credentialStatus.snapshot()
        XCTAssertEqual(persistedCredentialStatus, .unconfigured)
    }

    func testHelloAckAssignedProviderTokenDoesNotAdoptAppManagedTokenWhenKeychainFails() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let dir = try Self.makeTemporaryDirectory(prefix: "coordinator-token-managed-failure-")
        defer { try? FileManager.default.removeItem(at: dir) }
        let configPath = dir.appendingPathComponent("config.yaml").path
        let originalConfig = "provider_id: provider-test\nmanaged_by: malibu-app\nmodel: model-a\n"
        try originalConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
        var config = AppConfig.defaults(configPath: configPath)
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.managedBy = "malibu-app"
        let runtime = try await ModelRuntime(modelID: nil)
        let credentialStore = InMemoryProviderCredentialStore(
            replaceError: NSError(domain: "ProviderCredentialStoreTests", code: 1)
        )
        let credentialStatus = ProviderCredentialStatusRuntime(.unconfigured)
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            webSocketFactory: { _ in FakeProviderWebSocketTask(receiveResults: []) },
            sleepAssertionFactory: { nil },
            providerCredentialStore: credentialStore,
            credentialStatusRuntime: credentialStatus
        ))

        do {
            try await client.handleCoordinatorPayloadForTest([
                "type": "hello_ack",
                "assigned_id": "assigned-a",
                "heartbeat_interval_s": 30,
                "assigned_provider_token": "must-not-be-adopted",
            ])
        } catch let error as CoordinatorAuthError {
            guard case .invalidMessage(let message) = error else {
                XCTFail("unexpected auth error: \(error)")
                return
            }
            XCTAssertEqual(message, "assigned provider credential could not be committed")
        }

        XCTAssertEqual(try String(contentsOfFile: configPath), originalConfig)
        let persistedCredentialStatus = await credentialStatus.snapshot()
        XCTAssertEqual(persistedCredentialStatus, .unconfigured)
    }

    func testAcceptedKeychainBackedRestartRemovesMatchingLegacyYAMLToken() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let dir = try Self.makeTemporaryDirectory(prefix: "coordinator-token-migration-commit-")
        defer { try? FileManager.default.removeItem(at: dir) }
        let configPath = dir.appendingPathComponent("config.yaml").path
        let token = "migration-token"
        try "provider_id: provider-test\nprovider_token: \(token)\nmodel: model-a\n".write(
            toFile: configPath,
            atomically: true,
            encoding: .utf8
        )
        var config = AppConfig.defaults(configPath: configPath)
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.providerToken = token
        config.model = "model-a"
        let runtime = try await ModelRuntime(modelID: nil)
        let credentialStore = InMemoryProviderCredentialStore(values: ["provider-test": token])
        let credentialStatus = ProviderCredentialStatusRuntime(ProviderCredentialStatus(
            source: .cliKeychain,
            state: .ready,
            restartSafe: true,
            migrationPending: true
        ))
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            sendOverride: { _ in },
            sleepAssertionFactory: { nil },
            providerCredentialStore: credentialStore,
            credentialStatusRuntime: credentialStatus
        ))

        try await client.handleCoordinatorPayloadForTest([
            "type": "hello_ack",
            "assigned_id": "assigned-a",
            "heartbeat_interval_s": 3_600,
        ])
        await client.stop()

        let onDisk = try String(contentsOfFile: configPath)
        XCTAssertFalse(onDisk.contains("provider_token:"))
        XCTAssertTrue(onDisk.contains("provider_id: provider-test"))
        let finalCredentialStatus = await credentialStatus.snapshot()
        XCTAssertEqual(
            finalCredentialStatus,
            ProviderCredentialStatus(source: .cliKeychain, state: .ready, restartSafe: true)
        )
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
                    "response_chunk_plaintext_envelope": true,
                ],
            ],
        ], session: session)

        let record = try XCTUnwrap(claimFile.read())
        XCTAssertEqual(record.pairOT, "PAIRV2")
        XCTAssertEqual(record.claimURL, "https://portal.example/claim?ot=PAIRV2")
        let response = try session.sealResponseChunk(requestID: "req-ack", stream: false, seq: 0, plaintext: "ack-body")
        XCTAssertEqual(try Tier2ProviderSession.openResponseChunkForTest(
            session: session,
            frame: response,
            requestID: "req-ack",
            stream: false
        ), "ack-body")
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
        let hardwareSummary = try XCTUnwrap(heartbeat["hardware_summary"] as? [String: Any])
        XCTAssertTrue(
            hardwareSummary["cpu_cores_total"] != nil ||
                hardwareSummary["gpu_cores_total"] != nil ||
                hardwareSummary["bandwidth_gb_per_s"] != nil,
            "hardware_summary should publish at least one capacity field: \(hardwareSummary)"
        )
        var heartbeatWithoutHardware = heartbeat
        heartbeatWithoutHardware.removeValue(forKey: "hardware_summary")
        let safetyTelemetry = try XCTUnwrap(heartbeatWithoutHardware.removeValue(forKey: "safety_telemetry") as? [String: Any])
        XCTAssertEqual(safetyTelemetry["schema_version"] as? Int, 1)
        XCTAssertEqual(safetyTelemetry["provider_id"] as? String, "provider-test")
        XCTAssertEqual(safetyTelemetry["model_id"] as? String, "model-a")
        XCTAssertEqual(safetyTelemetry["requests_queued"] as? Int, 0)
        XCTAssertTrue(["normal", "warning", "critical"].contains(try XCTUnwrap(safetyTelemetry["memory_pressure"] as? String)))
        XCTAssertTrue(["nominal", "fair", "serious", "critical"].contains(try XCTUnwrap(safetyTelemetry["thermal_state"] as? String)))
        XCTAssertNotNil(safetyTelemetry["observation_id"] as? String)
        let heartbeatJSON = Self.jsonString(heartbeatWithoutHardware)
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

    func testCanonicalModelIdentityIsNamedAcrossAdmissionAndHeartbeat() async throws {
        let artifactHash = "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a"
        let weightsHash = "0baf13715db1eeb56e6d0806b0d764aa1c44497aaaaf8d2ba90c21128d9fe2fe"
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: artifactHash,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: weightsHash
        )
        let client = try await makeClient(status: status, recorder: recorder, enableWarmSwap: false)
        await AutoUpdateEventStore.shared.clear()

        let hello = await client.helloMessage()
        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())
        try await client.sendHeartbeatForTest()
        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)

        for frame in [hello, auth, heartbeat] {
            XCTAssertEqual(frame["model_hash"] as? String, artifactHash)
            XCTAssertEqual(frame["model_hash_algorithm"] as? String, ModelArtifactIdentity.snapshotManifestV1)
            XCTAssertEqual(frame["weights_manifest_sha256"] as? String, weightsHash)
            XCTAssertEqual(frame["weights_manifest_algorithm"] as? String, ModelArtifactIdentity.safetensorsManifestV1)
        }
    }

    func testHeartbeatOmitsSpecDecodeTelemetryUnlessOperatorOptsIn() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let startedAt = await status.beginRequest(requestID: "r-spec")
        let generation = await status.currentSpecDecodeGeneration()
        await status.finishRequest(
            startedAt: startedAt,
            completion: CompletionResult(
                content: "ok",
                finishReason: "stop",
                promptTokens: 2,
                completionTokens: 1,
                specDecodeDraftedTokens: 12,
                specDecodeAcceptedTokens: 9,
                specDecodeGeneration: generation
            ),
            failed: false,
            requestID: "r-spec"
        )
        let client = try await makeClient(status: status, recorder: recorder)

        try await client.sendHeartbeatForTest()

        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)
        XCTAssertNil(heartbeat["spec_decode_enabled"])
        XCTAssertNil(heartbeat["spec_decode_draft_model_id"])
        XCTAssertNil(heartbeat["spec_decode_num_draft_tokens"])
        XCTAssertNil(heartbeat["spec_decode_drafted_tokens_since_last"])
        XCTAssertNil(heartbeat["spec_decode_accepted_tokens_since_last"])
        XCTAssertNil(heartbeat["spec_decode_acceptance_rate"])
    }

    func testHeartbeatPublishesSpecDecodeTelemetryOnlyWithOperatorOptIn() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let startedAt = await status.beginRequest(requestID: "r-spec")
        let generation = await status.currentSpecDecodeGeneration()
        await status.finishRequest(
            startedAt: startedAt,
            completion: CompletionResult(
                content: "ok",
                finishReason: "stop",
                promptTokens: 2,
                completionTokens: 1,
                specDecodeDraftedTokens: 12,
                specDecodeAcceptedTokens: 9,
                specDecodeGeneration: generation
            ),
            failed: false,
            requestID: "r-spec"
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            publishesSpecDecodeTelemetry: true
        )

        try await client.sendHeartbeatForTest()

        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)
        XCTAssertEqual(heartbeat["spec_decode_enabled"] as? Bool, true)
        XCTAssertEqual(heartbeat["spec_decode_draft_model_id"] as? String, "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit")
        XCTAssertEqual(heartbeat["spec_decode_num_draft_tokens"] as? Int, 3)
        XCTAssertEqual(heartbeat["spec_decode_drafted_tokens_since_last"] as? Int, 12)
        XCTAssertEqual(heartbeat["spec_decode_accepted_tokens_since_last"] as? Int, 9)
        XCTAssertEqual(try XCTUnwrap(heartbeat["spec_decode_acceptance_rate"] as? Double), 0.75, accuracy: 0.000_001)
    }

    func testHeartbeatPublishesDisabledSpecDecodeShapeDuringGenerationMismatch() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        await status.setSpecDecodeConfig(draftModelID: nil, numDraftTokens: nil)
        let runtime = makeRuntime(modelID: "model-a", warmSwapEnabled: true)
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            enableWarmSwap: true,
            modelRuntime: runtime,
            publishesSpecDecodeTelemetry: true
        )

        try await client.sendHeartbeatForTest()

        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)
        XCTAssertEqual(heartbeat["spec_decode_enabled"] as? Bool, false)
        XCTAssertTrue(heartbeat["spec_decode_draft_model_id"] is NSNull)
        XCTAssertTrue(heartbeat["spec_decode_num_draft_tokens"] is NSNull)
        XCTAssertEqual(heartbeat["spec_decode_drafted_tokens_since_last"] as? Int, 0)
        XCTAssertEqual(heartbeat["spec_decode_accepted_tokens_since_last"] as? Int, 0)
        XCTAssertTrue(heartbeat["spec_decode_acceptance_rate"] is NSNull)
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

    func testCoordinatorFramesUseCatalogModelIDForConfiguredModelKey() async throws {
        let recorder = CoordinatorFrameRecorder()
        let catalogModelID = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: String(repeating: "a", count: 64)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            enableWarmSwap: false,
            modelCatalogModelID: catalogModelID
        )

        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())
        let hello = await client.helloMessage()
        try await client.sendHeartbeatForTest()
        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)
        let supportedModels = try XCTUnwrap(auth["supported_models"] as? [String])

        XCTAssertEqual(auth["model_id"] as? String, catalogModelID)
        XCTAssertEqual(hello["model_id"] as? String, catalogModelID)
        XCTAssertEqual(heartbeat["model_id"] as? String, catalogModelID)
        XCTAssertEqual(supportedModels, [catalogModelID])
    }

    func testCatalogModelIDDoesNotMaskCompletedWarmSwapRuntimeModelID() async throws {
        let recorder = CoordinatorFrameRecorder()
        let runtime = makeRuntime(modelID: "model-b", modelHash: "runtime-hash", warmSwapEnabled: true)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: "boot-hash"
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            enableWarmSwap: true,
            modelRuntime: runtime,
            modelCatalogModelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
        )

        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())
        let hello = await client.helloMessage()
        try await client.sendHeartbeatForTest()
        let frames = await recorder.frames
        let heartbeat = try XCTUnwrap(frames.first)

        XCTAssertEqual(auth["model_id"] as? String, "model-b")
        XCTAssertEqual(hello["model_id"] as? String, "model-b")
        XCTAssertEqual(heartbeat["model_id"] as? String, "model-b")
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
        let preparationRan = LockedBox(false)
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            watchdogExitPreparation: {
                preparationRan.set(true)
            },
            watchdogExitHook: { reason in
                XCTAssertTrue(preparationRan.get(), "watchdog exit hook ran before synchronous cleanup")
                Task { await captured.set(reason) }
            }
        )

        // The minimum tolerance is 15s so a bounded 5s send can finish.
        // Seeding age=16s puts us safely past tolerance on the first
        // 0.5s check tick.
        await client.seedLastHeartbeatSuccessForTest(ageNanoseconds: 16 * 1_000_000_000)
        await client.startHeartbeatWatchdogForTest(intervalSeconds: 1)

        try await Self.waitUntil(timeoutNanoseconds: 5_000_000_000) {
            await captured.value() != nil
        }
        let reason = await captured.value()
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("heartbeat liveness") ?? false, reason ?? "<nil>")
        await client.cancelHeartbeatWatchdogForTest()
    }

    func testHeartbeatWatchdogToleranceExceedsBoundedSendTimeout() {
        let expected = UInt64(15 * 1_000_000_000)
        XCTAssertEqual(
            CoordinatorClient.heartbeatWatchdogToleranceNanosecondsForTest(intervalSeconds: 1),
            expected
        )
        XCTAssertEqual(
            CoordinatorClient.heartbeatWatchdogToleranceNanosecondsForTest(intervalSeconds: Int.max),
            expected
        )
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

        // interval=1 → tolerance=15s. Seed last-success age WELL below
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

    func testExpiredOrphanRecoveryFencesReloadHelpersBeforeRestoringBinary() async throws {
        let fixture = try Self.makeAutoupdateRecoveryFixture(targetVersion: "9.9.9")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try Self.expireAutoupdateMarker(at: fixture.store.pendingURL)
        let fenceCalled = LockedBox(false)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: CoordinatorFrameRecorder(),
            autoupdateReloadHelperFence: {
                XCTAssertEqual(try String(contentsOf: fixture.binary), "new")
                fenceCalled.set(true)
            }
        )
        await AutoUpdateEventStore.shared.clear()

        await client.runStartupAutoupdateRecoveryForTest(
            binaryURL: fixture.binary,
            markerStore: fixture.store
        )

        XCTAssertTrue(fenceCalled.get())
        XCTAssertEqual(try String(contentsOf: fixture.binary), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        let event = await AutoUpdateEventStore.shared.lastWireObject()
        XCTAssertEqual(event?["reason"] as? String, "orphaned_pending_marker_recovered")
    }

    func testExpiredOrphanRecoveryFailsClosedWhenReloadHelperFenceFails() async throws {
        let fixture = try Self.makeAutoupdateRecoveryFixture(targetVersion: "9.9.9")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try Self.expireAutoupdateMarker(at: fixture.store.pendingURL)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: CoordinatorFrameRecorder(),
            autoupdateReloadHelperFence: {
                throw UpdateError.processFailed("reload helper fence", EBUSY)
            }
        )
        await AutoUpdateEventStore.shared.clear()

        await client.runStartupAutoupdateRecoveryForTest(
            binaryURL: fixture.binary,
            markerStore: fixture.store
        )

        XCTAssertEqual(try String(contentsOf: fixture.binary), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
        let event = await AutoUpdateEventStore.shared.lastWireObject()
        XCTAssertEqual(event?["reason"] as? String, "reload_helper_fence_failed")
        XCTAssertEqual(event?["failure_class"] as? String, AutoUpdateFailureClass.other.rawValue)
    }

    func testExpiredOrphanRecoveryDoesNotRestoreBinaryWhenReloadHelperFenceTimesOut() async throws {
        let fixture = try Self.makeAutoupdateRecoveryFixture(targetVersion: "9.9.9")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try Self.expireAutoupdateMarker(at: fixture.store.pendingURL)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: CoordinatorFrameRecorder(),
            autoupdateReloadHelperFence: {
                throw UpdateError.processTimedOut("/bin/launchctl list", 5)
            }
        )
        await AutoUpdateEventStore.shared.clear()

        await client.runStartupAutoupdateRecoveryForTest(
            binaryURL: fixture.binary,
            markerStore: fixture.store
        )

        XCTAssertEqual(try String(contentsOf: fixture.binary), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
        let event = await AutoUpdateEventStore.shared.lastWireObject()
        XCTAssertEqual(event?["reason"] as? String, "reload_helper_fence_failed")
        XCTAssertEqual(event?["failure_class"] as? String, AutoUpdateFailureClass.other.rawValue)
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

    func testSignedStartupRecoveryCommitsStableLocalIdentityBeforeModelIsLoaded() async throws {
        let fixture = try Self.makeAutoupdateRecoveryFixture(
            targetVersion: CoordinatorClient.binaryVersion,
            signedRelease: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let setID = try XCTUnwrap(fixture.marker.targetCompatibilitySetID)
        let setDigest = try XCTUnwrap(fixture.marker.targetCompatibilitySetSHA256)
        let manifest = CompatibilitySetManifest(
            compatibilitySetID: setID,
            envelopeSHA256: setDigest,
            version: CoordinatorClient.binaryVersion,
            catalogReleaseID: "release-a",
            catalogPolicyVersion: "policy-a",
            maintenanceLeaseSeconds: 600,
            readinessTimeoutSeconds: 90
        )
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: false,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let sleepGate = LocalAutoupdateHealthSleepGate()
        let recorder = CoordinatorFrameRecorder()
        let expectedInstanceID = RouterHandler.serviceInstanceID
        let expectedPID = getpid()
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            installedCompatibilityManifest: { _, version in
                version == CoordinatorClient.binaryVersion ? manifest : nil
            },
            autoupdateLocalHealthRequiredConsecutiveSamples: 2,
            autoupdateLocalStatusProbe: {
                Self.localAutoupdateStatus(
                    version: CoordinatorClient.binaryVersion,
                    compatibilitySetID: setID,
                    compatibilitySetSHA256: setDigest,
                    instanceID: expectedInstanceID,
                    processID: expectedPID,
                    modelLoaded: false
                )
            },
            autoupdateLocalHealthSleep: {
                await sleepGate.waitForRelease()
            }
        )
        await AutoUpdateEventStore.shared.clear()

        let recovery = Task {
            await client.runStartupAutoupdateRecoveryForTest(
                binaryURL: fixture.binary,
                markerStore: fixture.store
            )
        }
        try await Self.waitUntil {
            await sleepGate.started
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.lockURL.path))

        await sleepGate.release()
        await recovery.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        let event = await AutoUpdateEventStore.shared.lastWireObject()
        XCTAssertEqual(event?["reason"] as? String, "local_signed_set_health_succeeded")
        let frames = await recorder.frames
        XCTAssertTrue(frames.isEmpty)
    }

    func testSignedStartupRecoveryKeepsRollbackArmedWhenLocallyUnhealthy() async throws {
        let fixture = try Self.makeAutoupdateRecoveryFixture(
            targetVersion: CoordinatorClient.binaryVersion,
            signedRelease: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let setID = try XCTUnwrap(fixture.marker.targetCompatibilitySetID)
        let setDigest = try XCTUnwrap(fixture.marker.targetCompatibilitySetSHA256)
        let manifest = CompatibilitySetManifest(
            compatibilitySetID: setID,
            envelopeSHA256: setDigest,
            version: CoordinatorClient.binaryVersion,
            catalogReleaseID: "release-a",
            catalogPolicyVersion: "policy-a",
            maintenanceLeaseSeconds: 600,
            readinessTimeoutSeconds: 90
        )
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: false,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let recorder = CoordinatorFrameRecorder()
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            installedCompatibilityManifest: { _, version in
                version == CoordinatorClient.binaryVersion ? manifest : nil
            },
            autoupdateLocalHealthRequiredConsecutiveSamples: 2,
            autoupdateLocalStatusProbe: {
                nil
            },
            autoupdateLocalHealthSleep: {
                XCTFail("an unhealthy first sample must not wait or commit")
            }
        )
        await AutoUpdateEventStore.shared.clear()

        await client.runStartupAutoupdateRecoveryForTest(
            binaryURL: fixture.binary,
            markerStore: fixture.store
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.lockURL.path))
        let event = await AutoUpdateEventStore.shared.lastWireObject()
        XCTAssertNil(event)
        let frames = await recorder.frames
        XCTAssertTrue(frames.isEmpty)
    }

    func testSignedStartupRecoveryRejectsDifferentLiveListenerInstance() async throws {
        let fixture = try Self.makeAutoupdateRecoveryFixture(
            targetVersion: CoordinatorClient.binaryVersion,
            signedRelease: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let setID = try XCTUnwrap(fixture.marker.targetCompatibilitySetID)
        let setDigest = try XCTUnwrap(fixture.marker.targetCompatibilitySetSHA256)
        let manifest = CompatibilitySetManifest(
            compatibilitySetID: setID,
            envelopeSHA256: setDigest,
            version: CoordinatorClient.binaryVersion,
            catalogReleaseID: "release-a",
            catalogPolicyVersion: "policy-a",
            maintenanceLeaseSeconds: 600,
            readinessTimeoutSeconds: 90
        )
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let recorder = CoordinatorFrameRecorder()
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            installedCompatibilityManifest: { _, version in
                version == CoordinatorClient.binaryVersion ? manifest : nil
            },
            autoupdateLocalHealthRequiredConsecutiveSamples: 2,
            autoupdateLocalStatusProbe: {
                Self.localAutoupdateStatus(
                    version: CoordinatorClient.binaryVersion,
                    compatibilitySetID: setID,
                    compatibilitySetSHA256: setDigest,
                    instanceID: "different-provider-instance",
                    processID: getpid()
                )
            },
            autoupdateLocalHealthSleep: {
                XCTFail("a different listener instance must fail on the first sample")
            }
        )

        await client.runStartupAutoupdateRecoveryForTest(
            binaryURL: fixture.binary,
            markerStore: fixture.store
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.lockURL.path))
    }

    func testLocalAutoupdateHealthRequiresExactListenerEnvelope() {
        let expectedPID = getpid()
        let expectedInstanceID = RouterHandler.serviceInstanceID
        let status = Self.localAutoupdateStatus(
            version: CoordinatorClient.binaryVersion,
            compatibilitySetID: "set-a",
            compatibilitySetSHA256: "digest-a",
            instanceID: expectedInstanceID,
            processID: expectedPID,
            modelLoaded: false
        )
        let expectedKey = "\(expectedPID):\(expectedInstanceID)"

        XCTAssertEqual(
            CoordinatorClient.localHealthyTargetInstanceKey(
                status,
                targetVersion: CoordinatorClient.binaryVersion,
                expectedCompatibilitySetID: "set-a",
                expectedCompatibilitySetSHA256: "digest-a",
                expectedServiceInstanceID: expectedInstanceID,
                expectedProcessID: expectedPID
            ),
            expectedKey
        )
        for mismatch in [
            Self.localAutoupdateStatus(
                version: "wrong-version",
                compatibilitySetID: "set-a",
                compatibilitySetSHA256: "digest-a",
                instanceID: expectedInstanceID,
                processID: expectedPID
            ),
            Self.localAutoupdateStatus(
                version: CoordinatorClient.binaryVersion,
                compatibilitySetID: "wrong-set",
                compatibilitySetSHA256: "digest-a",
                instanceID: expectedInstanceID,
                processID: expectedPID
            ),
            Self.localAutoupdateStatus(
                version: CoordinatorClient.binaryVersion,
                compatibilitySetID: "set-a",
                compatibilitySetSHA256: "wrong-digest",
                instanceID: expectedInstanceID,
                processID: expectedPID
            ),
            Self.localAutoupdateStatus(
                version: CoordinatorClient.binaryVersion,
                compatibilitySetID: "set-a",
                compatibilitySetSHA256: "digest-a",
                instanceID: expectedInstanceID,
                processID: expectedPID + 1
            ),
        ] {
            XCTAssertNil(
                CoordinatorClient.localHealthyTargetInstanceKey(
                    mismatch,
                    targetVersion: CoordinatorClient.binaryVersion,
                    expectedCompatibilitySetID: "set-a",
                    expectedCompatibilitySetSHA256: "digest-a",
                    expectedServiceInstanceID: expectedInstanceID,
                    expectedProcessID: expectedPID
                )
            )
        }
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
        XCTAssertEqual(caps["response_chunk_plaintext_envelope"] as? Bool, true)
        XCTAssertEqual(caps["in_band_aead_rekey_v1"] as? Bool, true)
    }

    func testInBandAEADRekeyProvesFreshKeysBeforeSameSessionCutover() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)
        let oldSession = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-v2",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "old-kid",
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
            "tier2_session": [
                "encrypted_leg": [
                    "enabled": true,
                    "alg": Tier2ProviderSession.aeadSuite,
                    "kid": "old-kid",
                    "in_band_aead_rekey_v1": true,
                ],
            ],
        ], session: oldSession)

        let coordinatorPrivate = Curve25519.KeyAgreement.PrivateKey()
        let coordinatorPublic = coordinatorPrivate.publicKey.rawRepresentation.base64URLUnpadded()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.string(from: Date().addingTimeInterval(30))
        let request: [String: Any] = [
            "type": "aead_rekey_request",
            "version": 1,
            "rekey_id": "rekey-1",
            "assigned_id": "assigned-v2",
            "reason": "request_threshold",
            "old_kid": "old-kid",
            "coordinator_ecdh_public_key": coordinatorPublic,
            "selected_aead": Tier2ProviderSession.aeadSuite,
            "expires_at": expiresAt,
            "response_chunk_plaintext_envelope": true,
        ]
        try await client.handleCoordinatorPayloadForTest(request)

        let keyIDBeforeCommit = await client.tier2KeyIDForTest()
        let pendingIDBeforeCommit = await client.pendingAEADRekeyIDForTest()
        let framesBeforeCommit = await recorder.frames
        XCTAssertEqual(keyIDBeforeCommit, "old-kid", "request phase must not cut over early")
        XCTAssertEqual(pendingIDBeforeCommit, "rekey-1")
        let response = try XCTUnwrap(framesBeforeCommit.last { $0["type"] as? String == "aead_rekey_response" })
        let providerPublic = try XCTUnwrap(response["provider_ecdh_public_key"] as? String)
        let newKID = try XCTUnwrap(response["new_kid"] as? String)
        XCTAssertNotEqual(newKID, "old-kid")
        let coordinatorSession = try Tier2ProviderSession.coordinatorSessionForRekeyTest(
            coordinatorPrivateKey: coordinatorPrivate,
            providerID: "provider-test",
            assignedID: "assigned-v2",
            providerPublicKeyBase64URL: providerPublic,
            selectedAEAD: Tier2ProviderSession.aeadSuite
        )
        XCTAssertEqual(coordinatorSession.keyID, newKID)
        let proof: [String: Any] = [
            "type": "aead_rekey_proof",
            "version": 1,
            "rekey_id": "rekey-1",
            "provider_id": "provider-test",
            "assigned_id": "assigned-v2",
            "old_kid": "old-kid",
            "new_kid": newKID,
            "provider_ecdh_public_key": providerPublic,
            "coordinator_ecdh_public_key": coordinatorPublic,
            "selected_aead": Tier2ProviderSession.aeadSuite,
            "expires_at": expiresAt,
        ]
        let proofData = try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
        let commitEnvelope = try Tier2ProviderSession.sealAEADRekeyCommitForTest(
            session: coordinatorSession,
            rekeyID: "rekey-1",
            proof: proofData
        )
        try await client.handleCoordinatorPayloadForTest([
            "type": "aead_rekey_commit",
            "version": 1,
            "rekey_id": "rekey-1",
            "assigned_id": "assigned-v2",
            "old_kid": "old-kid",
            "new_kid": newKID,
            "encrypted": true,
            "enc": commitEnvelope,
        ])

        let keyIDAfterCommit = await client.tier2KeyIDForTest()
        let pendingIDAfterCommit = await client.pendingAEADRekeyIDForTest()
        let countersAfterCommit = await client.tier2CountersForTest()
        let framesAfterCommit = await recorder.frames
        XCTAssertEqual(keyIDAfterCommit, newKID)
        XCTAssertNil(pendingIDAfterCommit)
        let counters = try XCTUnwrap(countersAfterCommit)
        XCTAssertEqual(counters.c2p, 1)
        XCTAssertEqual(counters.p2c, 1)
        let committed = try XCTUnwrap(framesAfterCommit.last { $0["type"] as? String == "aead_rekey_committed" })
        XCTAssertEqual(committed["assigned_id"] as? String, "assigned-v2")
        let committedProof = try Tier2ProviderSession.openAEADRekeyCommittedForTest(
            session: coordinatorSession,
            frame: committed,
            rekeyID: "rekey-1"
        )
        XCTAssertEqual(committedProof, proofData)
        await client.stop()
    }

    func testInBandAEADRekeyRejectsOverlappingAttemptWithoutChangingActiveEpoch() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)
        let oldSession = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-v2",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "old-kid",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data(repeating: 0x33, count: 4),
            p2cNonceBase: Data(repeating: 0x44, count: 4)
        )
        try await client.acceptAuthResponseForTest([
            "type": "auth_response", "version": 2, "status": "accepted",
            "assigned_id": "assigned-v2", "heartbeat_interval_s": 30,
            "tier2_session": ["encrypted_leg": [
                "enabled": true,
                "alg": Tier2ProviderSession.aeadSuite,
                "kid": "old-kid",
                "in_band_aead_rekey_v1": true,
            ]],
        ], session: oldSession)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let baseRequest: [String: Any] = [
            "type": "aead_rekey_request", "version": 1, "rekey_id": "rekey-original",
            "assigned_id": "assigned-v2", "reason": "age_threshold", "old_kid": "old-kid",
            "coordinator_ecdh_public_key": Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64URLUnpadded(),
            "selected_aead": Tier2ProviderSession.aeadSuite,
            "expires_at": formatter.string(from: Date().addingTimeInterval(30)),
        ]
        try await client.handleCoordinatorPayloadForTest(baseRequest)
        var overlapping = baseRequest
        overlapping["rekey_id"] = "rekey-overlap"
        do {
            try await client.handleCoordinatorPayloadForTest(overlapping)
            XCTFail("overlapping in-band rekey must be rejected")
        } catch {
            let activeKeyID = await client.tier2KeyIDForTest()
            let pendingRekeyID = await client.pendingAEADRekeyIDForTest()
            XCTAssertEqual(activeKeyID, "old-kid")
            XCTAssertEqual(pendingRekeyID, "rekey-original")
        }
        await client.stop()
    }

    func testInBandAEADRekeyRequiresNegotiatedCapability() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder)
        let oldSession = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-v2",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "old-kid",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data(repeating: 0x33, count: 4),
            p2cNonceBase: Data(repeating: 0x44, count: 4)
        )
        try await client.acceptAuthResponseForTest([
            "type": "auth_response", "version": 2, "status": "accepted",
            "assigned_id": "assigned-v2", "heartbeat_interval_s": 30,
            "tier2_session": ["encrypted_leg": [
                "enabled": true,
                "alg": Tier2ProviderSession.aeadSuite,
                "kid": "old-kid",
            ]],
        ], session: oldSession)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let request: [String: Any] = [
            "type": "aead_rekey_request", "version": 1, "rekey_id": "rekey-unnegotiated",
            "assigned_id": "assigned-v2", "reason": "age_threshold", "old_kid": "old-kid",
            "coordinator_ecdh_public_key": Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64URLUnpadded(),
            "selected_aead": Tier2ProviderSession.aeadSuite,
            "expires_at": formatter.string(from: Date().addingTimeInterval(30)),
        ]

        do {
            try await client.handleCoordinatorPayloadForTest(request)
            XCTFail("unnegotiated in-band rekey must be rejected")
        } catch {
            let activeKeyID = await client.tier2KeyIDForTest()
            let pendingRekeyID = await client.pendingAEADRekeyIDForTest()
            XCTAssertEqual(activeKeyID, "old-kid")
            XCTAssertNil(pendingRekeyID)
            let frames = await recorder.frames
            XCTAssertFalse(frames.contains { $0["type"] as? String == "aead_rekey_response" })
        }
        await client.stop()
    }

    func testInBandAEADRekeyRejectsTamperedProofFieldWithoutCutover() async throws {
        let recorder = CoordinatorFrameRecorder()
        let prepared = try await prepareInBandAEADRekey(recorder: recorder)
        var proof = prepared.proof
        proof["assigned_id"] = "attacker-assigned-id"
        let proofData = try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
        let commitEnvelope = try Tier2ProviderSession.sealAEADRekeyCommitForTest(
            session: prepared.coordinatorSession,
            rekeyID: prepared.rekeyID,
            proof: proofData
        )

        do {
            try await prepared.client.handleCoordinatorPayloadForTest([
                "type": "aead_rekey_commit",
                "version": 1,
                "rekey_id": prepared.rekeyID,
                "assigned_id": "assigned-v2",
                "old_kid": "old-kid",
                "new_kid": prepared.newKID,
                "encrypted": true,
                "enc": commitEnvelope,
            ])
            XCTFail("tampered rekey proof field must be rejected")
        } catch {
            let activeKeyID = await prepared.client.tier2KeyIDForTest()
            let pendingRekeyID = await prepared.client.pendingAEADRekeyIDForTest()
            XCTAssertEqual(activeKeyID, "old-kid")
            XCTAssertEqual(pendingRekeyID, prepared.rekeyID)
        }
        await prepared.client.stop()
    }

    func testInBandAEADRekeyCommittedSendFailureNeverRollsBackOldEpoch() async throws {
        let recorder = CoordinatorFrameRecorder()
        let sendOverride: CoordinatorClient.SendOverride = { frame in
            await recorder.append(frame)
            if frame["type"] as? String == "aead_rekey_committed" {
                throw CoordinatorClientTestError.sendStateUpdateFailed
            }
        }
        let prepared = try await prepareInBandAEADRekey(recorder: recorder, sendOverride: sendOverride)
        let proofData = try JSONSerialization.data(withJSONObject: prepared.proof, options: [.sortedKeys])
        let commitEnvelope = try Tier2ProviderSession.sealAEADRekeyCommitForTest(
            session: prepared.coordinatorSession,
            rekeyID: prepared.rekeyID,
            proof: proofData
        )

        do {
            try await prepared.client.handleCoordinatorPayloadForTest([
                "type": "aead_rekey_commit",
                "version": 1,
                "rekey_id": prepared.rekeyID,
                "assigned_id": "assigned-v2",
                "old_kid": "old-kid",
                "new_kid": prepared.newKID,
                "encrypted": true,
                "enc": commitEnvelope,
            ])
            XCTFail("committed acknowledgement send failure must surface")
        } catch {
            let activeKeyID = await prepared.client.tier2KeyIDForTest()
            let pendingRekeyID = await prepared.client.pendingAEADRekeyIDForTest()
            XCTAssertEqual(activeKeyID, prepared.newKID)
            XCTAssertNil(pendingRekeyID)
        }
        await prepared.client.stop()
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

    func testCredentialBootstrapIsExplicitAcrossHandshakeStages() async throws {
        let recorder = CoordinatorFrameRecorder()
        let receiptKey = Curve25519.Signing.PrivateKey()
        let receiptPublicKey = Data(receiptKey.publicKey.rawRepresentation).base64EncodedString()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: false,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            providerReceiptPublicKey: receiptPublicKey,
            credentialBootstrap: true,
            bootstrapReceiptSigningKey: receiptKey,
            bootstrapReferralCode: "MAL1-S-key-issuer-tag"
        )
        let attempt = Tier2AuthAttempt()
        let hello = await client.helloMessage()
        let initial = await client.authInitialMessage(attempt: attempt)
        let proof = try await client.authProofMessage(challenge: [
            "type": "auth_challenge",
            "version": 2,
            "auth_attempt_id": "auth-bootstrap",
            "assigned_id": "assigned-bootstrap",
            "attestation_challenge": Data(repeating: 0x11, count: 32).base64URLUnpadded(),
            "attestation_formats": ["macprovider-se-p256-v1"],
            "coordinator_ecdh_public_key": Data(repeating: 0x22, count: 32).base64URLUnpadded(),
            "selected_aead_suite": Tier2ProviderSession.aeadSuite,
            "selected_aead": Tier2ProviderSession.aeadSuite,
            "key_id": "bootstrap-kid",
            "expires_at": "2026-07-10T20:00:00Z",
        ], attempt: attempt, initialMessage: initial)

        XCTAssertNil(hello["credential_bootstrap"])
        XCTAssertEqual(initial["credential_bootstrap"] as? Bool, true)
        XCTAssertEqual(initial["referral_code"] as? String, "MAL1-S-key-issuer-tag")
        XCTAssertEqual(initial["provider_receipt_public_key"] as? String, receiptPublicKey)
        XCTAssertEqual(proof["credential_bootstrap"] as? Bool, true)
        XCTAssertEqual(proof["referral_code"] as? String, "MAL1-S-key-issuer-tag")
        XCTAssertNotNil(proof["identity_signature"] as? String)
        XCTAssertNotNil(proof["identity_signature_transcript_sha256"] as? String)
    }

    func testReferralCodeIsOmittedOutsideCredentialBootstrap() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            bootstrapReferralCode: "MAL1-S-key-issuer-tag"
        )
        let attempt = Tier2AuthAttempt()
        let initial = await client.authInitialMessage(attempt: attempt)
        let proof = try await client.authProofMessage(challenge: [
            "type": "auth_challenge",
            "version": 2,
            "auth_attempt_id": "ordinary-no-referral",
            "attestation_challenge": Data(repeating: 0x11, count: 32).base64URLUnpadded(),
        ], attempt: attempt, initialMessage: initial)

        XCTAssertNil(initial["referral_code"])
        XCTAssertNil(proof["referral_code"])
    }

    func testTerminalReferralRejectionStopsBootstrapReconnectLoop() async throws {
        let recorder = CoordinatorFrameRecorder()
        let receiptKey = Curve25519.Signing.PrivateKey()
        let receiptPublicKey = Data(receiptKey.publicKey.rawRepresentation).base64EncodedString()
        let attempts = ReferralBootstrapConnectAttempts()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: false,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            reconnectInitialBackoffNanoseconds: 1_000_000,
            connectAndRunOverride: {
                await attempts.increment()
                throw CoordinatorAuthError.rejected(code: "referral_expired", message: "redacted")
            },
            providerReceiptPublicKey: receiptPublicKey,
            credentialBootstrap: true,
            bootstrapReceiptSigningKey: receiptKey,
            bootstrapReferralCode: "MAL1-S-key-issuer-tag"
        )

        await client.start()
        try await Self.waitUntil {
            await client.credentialBootstrapTerminalReferralFailure() != nil
        }
        let terminalFailure = await client.credentialBootstrapTerminalReferralFailure()
        XCTAssertEqual(terminalFailure, ReferralBootstrapFailure(kind: .expired))
        try await Task.sleep(nanoseconds: 10_000_000)
        let attemptCount = await attempts.value()
        XCTAssertEqual(attemptCount, 1)
        await client.stop()
    }

    func testOrdinaryBearerV2PublishesAndSignsWithSeparateAdmissionIdentity() async throws {
        let recorder = CoordinatorFrameRecorder()
        let receiptKey = Curve25519.Signing.PrivateKey()
        let admissionKey = Curve25519.Signing.PrivateKey()
        let receiptPublicKey = Data(receiptKey.publicKey.rawRepresentation).base64EncodedString()
        let admissionPublicKey = Data(admissionKey.publicKey.rawRepresentation).base64EncodedString()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            providerReceiptPublicKey: receiptPublicKey,
            providerAdmissionPublicKey: admissionPublicKey,
            receiptIdentitySigningKey: admissionKey
        )
        let attempt = Tier2AuthAttempt()
        let initial = await client.authInitialMessage(attempt: attempt)
        let proof = try await client.authProofMessage(challenge: [
            "type": "auth_challenge",
            "version": 2,
            "auth_attempt_id": "auth-receipt-identity",
            "attestation_challenge": Data(repeating: 0x11, count: 32).base64URLUnpadded(),
        ], attempt: attempt, initialMessage: initial)

        let transcript = try XCTUnwrap(proof["identity_signature_transcript_sha256"] as? String)
        let signatureBase64 = try XCTUnwrap(proof["identity_signature"] as? String)
        let signature = try XCTUnwrap(Data(base64Encoded: signatureBase64))
        let payload = try CoordinatorClient.receiptIdentityPayload(
            authAttemptID: "auth-receipt-identity",
            providerID: "provider-test",
            providerECDHPublicKey: attempt.publicKeyBase64URL,
            transcriptSHA256: transcript
        )
        XCTAssertEqual(initial["provider_receipt_public_key"] as? String, receiptPublicKey)
        XCTAssertEqual(initial["provider_admission_public_key"] as? String, admissionPublicKey)
        XCTAssertTrue(admissionKey.publicKey.isValidSignature(signature, for: payload))
        XCTAssertFalse(receiptKey.publicKey.isValidSignature(signature, for: payload))
        XCTAssertEqual(transcript, try CoordinatorClient.initialAuthTranscriptHashBase64(initial))
        XCTAssertNil(proof["credential_bootstrap"])
    }

    func testAdmissionIdentityRotationPublishesPendingKeySignsCoordinatorHintAndCommitsAcceptance() async throws {
        let recorder = CoordinatorFrameRecorder()
        let currentKey = Curve25519.Signing.PrivateKey()
        let pendingKey = Curve25519.Signing.PrivateKey()
        let currentPublicKey = Data(currentKey.publicKey.rawRepresentation).base64EncodedString()
        let pendingPublicKey = Data(pendingKey.publicKey.rawRepresentation).base64EncodedString()
        let currentDigest = SHA256.hash(data: Data(currentKey.publicKey.rawRepresentation))
            .map { String(format: "%02x", $0) }.joined()
        let pendingDigest = SHA256.hash(data: Data(pendingKey.publicKey.rawRepresentation))
            .map { String(format: "%02x", $0) }.joined()
        let commits = LockedBox<[Data]>([])
        let committedDeadlines = LockedBox<[Date?]>([])
        let previousValidUntil = "2031-07-21T12:00:00.000Z"
        let identityStatus = ProviderAdmissionIdentityStatusRuntime(.init(
            source: "cli_keychain",
            state: "rotation_pending",
            publicKeySHA256: currentDigest,
            pendingPublicKeySHA256: pendingDigest
        ))
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            providerAdmissionPublicKey: currentPublicKey,
            providerAdmissionNextPublicKey: pendingPublicKey,
            commitAdmissionIdentityPublicKey: { raw, deadline in
                commits.update { values in values.append(raw) }
                committedDeadlines.update { values in values.append(deadline) }
            },
            receiptIdentitySigningKeyCandidates: [currentKey, pendingKey],
            admissionIdentityStatusRuntime: identityStatus
        )
        let attempt = Tier2AuthAttempt()
        let initial = await client.authInitialMessage(attempt: attempt)
        let proof = try await client.authProofMessage(challenge: [
            "type": "auth_challenge",
            "version": 2,
            "auth_attempt_id": "auth-rotation-response-loss",
            "attestation_challenge": Data(repeating: 0x41, count: 32).base64URLUnpadded(),
            "admission_identity_public_key": pendingPublicKey,
            "admission_identity_generation": 2,
        ], attempt: attempt, initialMessage: initial)

        XCTAssertEqual(initial["provider_admission_public_key"] as? String, currentPublicKey)
        XCTAssertEqual(initial["provider_admission_next_public_key"] as? String, pendingPublicKey)
        let transcript = try XCTUnwrap(proof["identity_signature_transcript_sha256"] as? String)
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(proof["identity_signature"] as? String)))
        let payload = try CoordinatorClient.receiptIdentityPayload(
            authAttemptID: "auth-rotation-response-loss",
            providerID: "provider-test",
            providerECDHPublicKey: attempt.publicKeyBase64URL,
            transcriptSHA256: transcript
        )
        XCTAssertTrue(pendingKey.publicKey.isValidSignature(signature, for: payload))
        XCTAssertFalse(currentKey.publicKey.isValidSignature(signature, for: payload))

        try await client.reconcileAdmissionIdentityIfNeeded([
            "admission_identity_public_key": pendingPublicKey,
            "identity_admission_key_role": "current",
            "identity_generation": 2,
            "admission_identity_previous_valid_until": previousValidUntil,
        ])
        XCTAssertEqual(commits.get(), [Data(pendingKey.publicKey.rawRepresentation)])
        XCTAssertEqual(
            committedDeadlines.get().first.flatMap { $0 },
            CredentialRestartProver.parseISO8601(previousValidUntil)
        )
        var identitySnapshot = await identityStatus.snapshot()
        XCTAssertEqual(identitySnapshot.state, "ready")
        XCTAssertEqual(identitySnapshot.publicKeySHA256, pendingDigest)
        XCTAssertNil(identitySnapshot.pendingPublicKeySHA256)
        XCTAssertEqual(identitySnapshot.previousPublicKeySHA256, currentDigest)
        XCTAssertEqual(identitySnapshot.previousValidUntil, previousValidUntil)
        XCTAssertEqual(identitySnapshot.coordinatorGeneration, 2)
        XCTAssertEqual(identitySnapshot.coordinatorKeyRole, "current")
        XCTAssertEqual(identitySnapshot.recoveryAction, "none")
        // Once reconciled, the same authoritative response is idempotent.
        try await client.reconcileAdmissionIdentityIfNeeded([
            "admission_identity_public_key": pendingPublicKey,
            "identity_admission_key_role": "current",
            "identity_generation": 2,
            "admission_identity_previous_valid_until": previousValidUntil,
        ])
        XCTAssertEqual(commits.get().count, 1)
        identitySnapshot = await identityStatus.snapshot()
        XCTAssertEqual(identitySnapshot.publicKeySHA256, pendingDigest)
        XCTAssertEqual(identitySnapshot.previousPublicKeySHA256, currentDigest)
    }

    func testLegacySessionWithoutAdmissionIdentityOfferDoesNotRequireResponseContract() async throws {
        let client = try await makeClient(
            status: ProviderStatus(
                modelID: "model-a",
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
            ),
            recorder: CoordinatorFrameRecorder()
        )

        try await client.reconcileAdmissionIdentityIfNeeded([:])
    }

    func testAdmissionIdentityOfferRequiresCompleteAuthoritativeResponseContract() async throws {
        let currentKey = Curve25519.Signing.PrivateKey()
        let publicKey = Data(currentKey.publicKey.rawRepresentation).base64EncodedString()
        let client = try await makeClient(
            status: ProviderStatus(
                modelID: "model-a",
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
            ),
            recorder: CoordinatorFrameRecorder(),
            providerAdmissionPublicKey: publicKey,
            receiptIdentitySigningKeyCandidates: [currentKey]
        )

        do {
            try await client.reconcileAdmissionIdentityIfNeeded([:])
            XCTFail("an offered admission identity requires an authoritative response")
        } catch {
            XCTAssertEqual(
                error as? CoordinatorAuthError,
                .invalidMessage("coordinator omitted the admission identity contract")
            )
        }
        do {
            try await client.reconcileAdmissionIdentityIfNeeded([
                "admission_identity_public_key": publicKey,
            ])
            XCTFail("generation and key role are required")
        } catch {
            XCTAssertEqual(
                error as? CoordinatorAuthError,
                .invalidMessage("coordinator returned an incomplete admission identity contract")
            )
        }
        do {
            try await client.reconcileAdmissionIdentityIfNeeded([
                "admission_identity_public_key": publicKey,
                "identity_admission_key_role": "previous",
                "identity_generation": 2,
            ])
            XCTFail("an ordinary current-key proof cannot be accepted as previous")
        } catch {
            XCTAssertEqual(
                error as? CoordinatorAuthError,
                .invalidMessage("coordinator returned a mismatched admission identity role")
            )
        }
    }

    func testAdmissionIdentityRotationRejectsUnknownAcceptedKey() async throws {
        let recorder = CoordinatorFrameRecorder()
        let currentKey = Curve25519.Signing.PrivateKey()
        let pendingKey = Curve25519.Signing.PrivateKey()
        let identityStatus = ProviderAdmissionIdentityStatusRuntime(.init(
            source: "cli_keychain",
            state: "rotation_pending",
            publicKeySHA256: "current",
            pendingPublicKeySHA256: "pending"
        ))
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            providerAdmissionPublicKey: Data(currentKey.publicKey.rawRepresentation).base64EncodedString(),
            providerAdmissionNextPublicKey: Data(pendingKey.publicKey.rawRepresentation).base64EncodedString(),
            commitAdmissionIdentityPublicKey: { _, _ in },
            receiptIdentitySigningKeyCandidates: [currentKey, pendingKey],
            admissionIdentityStatusRuntime: identityStatus
        )

        do {
            try await client.reconcileAdmissionIdentityIfNeeded([
                "admission_identity_public_key": Data(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation).base64EncodedString(),
                "identity_admission_key_role": "current",
                "identity_generation": 3,
            ])
            XCTFail("unknown coordinator admission key must fail closed")
        } catch {
            XCTAssertEqual(
                error as? CoordinatorAuthError,
                .invalidMessage("coordinator accepted an unknown admission identity")
            )
        }
        let identitySnapshot = await identityStatus.snapshot()
        XCTAssertEqual(identitySnapshot.state, "recovery_required")
        XCTAssertEqual(identitySnapshot.transitionError, "coordinator_accepted_unknown_admission_identity")
        XCTAssertEqual(identitySnapshot.recoveryAction, "run_credentials_repair_or_recover_admission_identity")
    }

    func testAdmissionIdentityRotationRejectsMissingAuthoritativePreviousDeadline() async throws {
        let currentKey = Curve25519.Signing.PrivateKey()
        let pendingKey = Curve25519.Signing.PrivateKey()
        let currentPublicKey = Data(currentKey.publicKey.rawRepresentation).base64EncodedString()
        let pendingPublicKey = Data(pendingKey.publicKey.rawRepresentation).base64EncodedString()
        let identityStatus = ProviderAdmissionIdentityStatusRuntime(.init(
            source: "cli_keychain",
            state: "rotation_pending",
            publicKeySHA256: "current",
            pendingPublicKeySHA256: "pending"
        ))
        let client = try await makeClient(
            status: ProviderStatus(
                modelID: "model-a",
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
            ),
            recorder: CoordinatorFrameRecorder(),
            providerAdmissionPublicKey: currentPublicKey,
            providerAdmissionNextPublicKey: pendingPublicKey,
            commitAdmissionIdentityPublicKey: { _, _ in
                XCTFail("a response without the coordinator deadline must not commit")
            },
            receiptIdentitySigningKeyCandidates: [currentKey, pendingKey],
            admissionIdentityStatusRuntime: identityStatus
        )

        do {
            try await client.reconcileAdmissionIdentityIfNeeded([
                "admission_identity_public_key": pendingPublicKey,
                "identity_admission_key_role": "current",
                "identity_generation": 2,
            ])
            XCTFail("rotation acceptance requires the coordinator-authoritative previous-key deadline")
        } catch {
            XCTAssertEqual(
                error as? CoordinatorAuthError,
                .invalidMessage("coordinator omitted the previous admission identity deadline")
            )
        }
        let snapshot = await identityStatus.snapshot()
        XCTAssertEqual(snapshot.transitionError, "coordinator_omitted_previous_identity_deadline")
    }

    func testAdmissionIdentityPreviousKeyProofAdoptsDegradedSessionWithoutChangingCustody() async throws {
        let recorder = CoordinatorFrameRecorder()
        let previousKey = Curve25519.Signing.PrivateKey()
        let authoritativeKey = Curve25519.Signing.PrivateKey()
        let previousPublicKey = Data(previousKey.publicKey.rawRepresentation).base64EncodedString()
        let authoritativePublicKey = Data(authoritativeKey.publicKey.rawRepresentation).base64EncodedString()
        let commits = LockedBox<[Data]>([])
        let identityStatus = ProviderAdmissionIdentityStatusRuntime(.init(
            source: "cli_keychain",
            state: "ready",
            publicKeySHA256: "previous"
        ))
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            providerAdmissionPublicKey: previousPublicKey,
            commitAdmissionIdentityPublicKey: { raw, _ in
                commits.update { values in values.append(raw) }
            },
            receiptIdentitySigningKeyCandidates: [previousKey],
            admissionIdentityStatusRuntime: identityStatus
        )
        let attempt = Tier2AuthAttempt()
        let initial = await client.authInitialMessage(attempt: attempt)
        let proof = try await client.authProofMessage(challenge: [
            "type": "auth_challenge",
            "version": 2,
            "auth_attempt_id": "auth-previous-grace",
            "attestation_challenge": Data(repeating: 0x51, count: 32).base64URLUnpadded(),
            "admission_identity_public_key": previousPublicKey,
            "admission_identity_generation": 2,
        ], attempt: attempt, initialMessage: initial)

        let transcript = try XCTUnwrap(proof["identity_signature_transcript_sha256"] as? String)
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(proof["identity_signature"] as? String)))
        let payload = try CoordinatorClient.receiptIdentityPayload(
            authAttemptID: "auth-previous-grace",
            providerID: "provider-test",
            providerECDHPublicKey: attempt.publicKeyBase64URL,
            transcriptSHA256: transcript
        )
        XCTAssertTrue(previousKey.publicKey.isValidSignature(signature, for: payload))

        try await client.reconcileAdmissionIdentityIfNeeded([
            "admission_identity_public_key": authoritativePublicKey,
            "identity_admission_key_role": "previous",
            "identity_generation": 2,
            "admission_identity_previous_valid_until": "2031-07-21T12:00:00.000Z",
        ])
        XCTAssertTrue(commits.get().isEmpty)
        let identitySnapshot = await identityStatus.snapshot()
        XCTAssertEqual(identitySnapshot.state, "degraded_previous_key")
        XCTAssertEqual(identitySnapshot.coordinatorGeneration, 2)
        XCTAssertEqual(identitySnapshot.coordinatorKeyRole, "previous")
        XCTAssertEqual(identitySnapshot.previousValidUntil, "2031-07-21T12:00:00.000Z")
        XCTAssertEqual(identitySnapshot.recoveryAction, "restore_current_key_or_run_recover_admission_identity")
    }

    func testOperatorAuthorizedAdmissionIdentityRecoveryPublishesAndCommitsStagedKey() async throws {
        let recorder = CoordinatorFrameRecorder()
        let recoveryKey = Curve25519.Signing.PrivateKey()
        let recoveryPublicKey = Data(recoveryKey.publicKey.rawRepresentation).base64EncodedString()
        let recoveryDigest = SHA256.hash(data: Data(recoveryKey.publicKey.rawRepresentation))
            .map { String(format: "%02x", $0) }.joined()
        let commits = LockedBox<[Data]>([])
        let identityStatus = ProviderAdmissionIdentityStatusRuntime(.init(
            source: "cli_keychain_pending",
            state: "recovery_pending",
            publicKeySHA256: recoveryDigest,
            pendingPublicKeySHA256: recoveryDigest,
            recoveryAction: "obtain_operator_recovery_approval_then_restart"
        ))
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            providerAdmissionPublicKey: recoveryPublicKey,
            providerAdmissionRecovery: true,
            commitAdmissionIdentityPublicKey: { raw, deadline in
                XCTAssertNil(deadline)
                commits.update { values in values.append(raw) }
            },
            receiptIdentitySigningKeyCandidates: [recoveryKey],
            admissionIdentityStatusRuntime: identityStatus
        )
        let attempt = Tier2AuthAttempt()
        let initial = await client.authInitialMessage(attempt: attempt)
        XCTAssertEqual(initial["provider_admission_recovery"] as? Bool, true)
        _ = try await client.authProofMessage(challenge: [
            "type": "auth_challenge",
            "version": 2,
            "auth_attempt_id": "auth-recovery",
            "attestation_challenge": Data(repeating: 0x61, count: 32).base64URLUnpadded(),
            "admission_identity_public_key": recoveryPublicKey,
            "admission_identity_generation": 1,
        ], attempt: attempt, initialMessage: initial)

        try await client.reconcileAdmissionIdentityIfNeeded([
            "admission_identity_public_key": recoveryPublicKey,
            "identity_admission_key_role": "recovery",
            "identity_generation": 2,
        ])
        XCTAssertEqual(commits.get(), [Data(recoveryKey.publicKey.rawRepresentation)])
        let identitySnapshot = await identityStatus.snapshot()
        XCTAssertEqual(identitySnapshot.source, "cli_keychain")
        XCTAssertEqual(identitySnapshot.state, "ready")
        XCTAssertEqual(identitySnapshot.publicKeySHA256, recoveryDigest)
        XCTAssertNil(identitySnapshot.pendingPublicKeySHA256)
        XCTAssertEqual(identitySnapshot.coordinatorGeneration, 2)
        XCTAssertEqual(identitySnapshot.coordinatorKeyRole, "recovery")
        XCTAssertEqual(identitySnapshot.recoveryAction, "none")

        let nextInitial = await client.authInitialMessage(attempt: Tier2AuthAttempt())
        XCTAssertNil(nextInitial["provider_admission_recovery"])
    }

    func testOrdinaryBearerV2SelectsHistoricalBootstrapIdentityFromChallengeHint() async throws {
        let recorder = CoordinatorFrameRecorder()
        let currentReceiptKey = Curve25519.Signing.PrivateKey()
        let originalBootstrapKey = Curve25519.Signing.PrivateKey()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            providerReceiptPublicKey: Data(currentReceiptKey.publicKey.rawRepresentation).base64EncodedString(),
            receiptIdentitySigningKeyCandidates: [currentReceiptKey, originalBootstrapKey]
        )
        let attempt = Tier2AuthAttempt()
        let initial = await client.authInitialMessage(attempt: attempt)
        let proof = try await client.authProofMessage(challenge: [
            "type": "auth_challenge",
            "version": 2,
            "auth_attempt_id": "auth-upgrade-identity",
            "attestation_challenge": Data(repeating: 0x21, count: 32).base64URLUnpadded(),
            "bootstrap_identity_public_key": Data(originalBootstrapKey.publicKey.rawRepresentation).base64EncodedString(),
        ], attempt: attempt, initialMessage: initial)

        let transcript = try XCTUnwrap(proof["identity_signature_transcript_sha256"] as? String)
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(proof["identity_signature"] as? String)))
        let payload = try CoordinatorClient.receiptIdentityPayload(
            authAttemptID: "auth-upgrade-identity",
            providerID: "provider-test",
            providerECDHPublicKey: attempt.publicKeyBase64URL,
            transcriptSHA256: transcript
        )
        XCTAssertTrue(originalBootstrapKey.publicKey.isValidSignature(signature, for: payload))
        XCTAssertFalse(currentReceiptKey.publicKey.isValidSignature(signature, for: payload))
    }

    func testOrdinaryBearerV2RefusesCandidateThatDoesNotMatchDurableHint() async throws {
        let recorder = CoordinatorFrameRecorder()
        let unrelatedKey = Curve25519.Signing.PrivateKey()
        let durableKey = Curve25519.Signing.PrivateKey()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            providerReceiptPublicKey: Data(unrelatedKey.publicKey.rawRepresentation).base64EncodedString(),
            receiptIdentitySigningKeyCandidates: [unrelatedKey]
        )
        let attempt = Tier2AuthAttempt()
        let initial = await client.authInitialMessage(attempt: attempt)
        let proof = try await client.authProofMessage(challenge: [
            "type": "auth_challenge",
            "version": 2,
            "auth_attempt_id": "auth-mismatched-identity",
            "attestation_challenge": Data(repeating: 0x31, count: 32).base64URLUnpadded(),
            "bootstrap_identity_public_key": Data(durableKey.publicKey.rawRepresentation).base64EncodedString(),
        ], attempt: attempt, initialMessage: initial)

        XCTAssertNil(proof["identity_signature"])
        XCTAssertNil(proof["identity_signature_transcript_sha256"])
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

        // Advertise the live marketing version on both handshake frames; do not
        // hardcode the number so ordinary candidate bumps do not break this gate.
        XCTAssertFalse(CoordinatorClient.binaryVersion.isEmpty)
        XCTAssertEqual(MacProviderCLI.configuration.version, CoordinatorClient.binaryVersion)
        XCTAssertEqual(hello["binary_version"] as? String, CoordinatorClient.binaryVersion)
        XCTAssertEqual(auth["binary_version"] as? String, CoordinatorClient.binaryVersion)
    }

    func testCatalogProviderRejectsCoordinatorWithoutAdmissionAcknowledgement() async throws {
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            catalogReleaseID: "release-a",
            catalogPolicyVersion: "policy-a",
            catalogCandidateSHA256: String(repeating: "a", count: 64),
            catalogSignerKeyID: "operator-2026-01",
            catalogRowIdentity: String(repeating: "b", count: 64),
            catalogModelSHA256: "old-hash"
        )

        do {
            try await client.handleCoordinatorPayloadForTest([
                "type": "hello_ack",
                "assigned_id": "assigned-a",
                "heartbeat_interval_s": 30,
            ])
            XCTFail("catalog-aware provider must fail closed against a coordinator without catalog admission")
        } catch let CoordinatorAuthError.invalidMessage(message) {
            XCTAssertTrue(message.contains("catalog"), message)
        }
    }

    func testCoordinatorAutoupdateKeepsRollbackArmedWithoutServingCapability() async throws {
        let fixture = try Self.makeAutoupdateRecoveryFixture(targetVersion: CoordinatorClient.binaryVersion)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let configURL = fixture.home.appendingPathComponent("config.yaml")
        try "provider_id: provider-test\nprovider_token: migration-token\nmodel: model-a\n".write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let credentialStore = InMemoryProviderCredentialStore(values: ["provider-test": "migration-token"])
        let credentialStatus = ProviderCredentialStatusRuntime(
            ProviderCredentialStatus(
                source: .cliKeychain,
                state: .ready,
                restartSafe: true,
                migrationPending: true
            )
        )
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            catalogReleaseID: "release-a",
            catalogPolicyVersion: "policy-a",
            catalogCandidateSHA256: String(repeating: "a", count: 64),
            catalogSignerKeyID: "operator-2026-01",
            catalogRowIdentity: String(repeating: "b", count: 64),
            coordinatorReadiness: { _, _, _ in false },
            autoupdateMarkerStore: fixture.store,
            configPath: configURL.path,
            providerToken: "migration-token",
            providerCredentialStore: credentialStore,
            credentialStatusRuntime: credentialStatus
        )

        try await client.handleCoordinatorPayloadForTest([
            "type": "hello_ack",
            "assigned_id": "assigned-a",
            "heartbeat_interval_s": 30,
            "catalog_compatible": true,
        ])

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertTrue(try String(contentsOf: configURL).contains("provider_token: migration-token"))
        let pendingStatus = await credentialStatus.snapshot()
        XCTAssertTrue(pendingStatus.migrationPending)
    }

    func testCoordinatorAutoupdateCommitsAfterAuthoritativeServingCapability() async throws {
        let fixture = try Self.makeAutoupdateRecoveryFixture(targetVersion: CoordinatorClient.binaryVersion)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let configURL = fixture.home.appendingPathComponent("config.yaml")
        try "provider_id: provider-test\nprovider_token: migration-token\nmodel: model-a\n".write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let credentialStore = InMemoryProviderCredentialStore(values: ["provider-test": "migration-token"])
        let credentialStatus = ProviderCredentialStatusRuntime(
            ProviderCredentialStatus(
                source: .cliKeychain,
                state: .ready,
                restartSafe: true,
                migrationPending: true
            )
        )
        let recorder = CoordinatorFrameRecorder()
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            catalogReleaseID: "release-a",
            catalogPolicyVersion: "policy-a",
            catalogCandidateSHA256: String(repeating: "a", count: 64),
            catalogSignerKeyID: "operator-2026-01",
            catalogRowIdentity: String(repeating: "b", count: 64),
            coordinatorReadiness: { providerID, assignedID, envelope in
                providerID == "provider-test"
                    && assignedID == "assigned-a"
                    && envelope.releaseID == "release-a"
                    && envelope.policyVersion == "policy-a"
                    && envelope.candidateSHA256 == String(repeating: "a", count: 64)
                    && envelope.signerKeyID == "operator-2026-01"
                    && envelope.rowIdentity == String(repeating: "b", count: 64)
            },
            autoupdateMarkerStore: fixture.store,
            configPath: configURL.path,
            providerToken: "migration-token",
            providerCredentialStore: credentialStore,
            credentialStatusRuntime: credentialStatus
        )

        try await client.handleCoordinatorPayloadForTest([
            "type": "hello_ack",
            "assigned_id": "assigned-a",
            "heartbeat_interval_s": 30,
            "catalog_compatible": true,
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertFalse(try String(contentsOf: configURL).contains("provider_token:"))
        let committedStatus = await credentialStatus.snapshot()
        XCTAssertFalse(committedStatus.migrationPending)
    }

    func testSelfUpdateOwnedRollbackRetainsLegacyCredentialUntilParentCommits() async throws {
        let fixture = try Self.makeAutoupdateRecoveryFixture(
            targetVersion: CoordinatorClient.binaryVersion,
            commitOwner: "self_update"
        )
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let configURL = fixture.home.appendingPathComponent("config.yaml")
        try "provider_id: provider-test\nprovider_token: migration-token\nmodel: model-a\n".write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let credentialStore = InMemoryProviderCredentialStore(values: ["provider-test": "migration-token"])
        let credentialStatus = ProviderCredentialStatusRuntime(
            ProviderCredentialStatus(
                source: .cliKeychain,
                state: .ready,
                restartSafe: true,
                migrationPending: true
            )
        )
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: CoordinatorFrameRecorder(),
            catalogReleaseID: "release-a",
            catalogPolicyVersion: "policy-a",
            catalogCandidateSHA256: String(repeating: "a", count: 64),
            catalogSignerKeyID: "operator-2026-01",
            catalogRowIdentity: String(repeating: "b", count: 64),
            coordinatorReadiness: { _, _, _ in
                XCTFail("self-update child must not claim its parent-owned rollback")
                return true
            },
            autoupdateMarkerStore: fixture.store,
            configPath: configURL.path,
            providerToken: "migration-token",
            providerCredentialStore: credentialStore,
            credentialStatusRuntime: credentialStatus
        )

        try await client.handleCoordinatorPayloadForTest([
            "type": "hello_ack",
            "assigned_id": "assigned-a",
            "heartbeat_interval_s": 30,
            "catalog_compatible": true,
        ])

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertTrue(try String(contentsOf: configURL).contains("provider_token: migration-token"))
        let retainedStatus = await credentialStatus.snapshot()
        XCTAssertTrue(retainedStatus.migrationPending)
    }

    func testRestoredPreviousSetCleanupWaitsForExactAdmissionAndBuyerServing() async throws {
        let fixture = try Self.makeAutoupdateRecoveryFixture(
            targetVersion: "9.9.9",
            transactionState: .awaitingPreviousReadiness
        )
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let previousID = try XCTUnwrap(fixture.marker.previousCompatibilitySetID)
        let previousDigest = try XCTUnwrap(fixture.marker.previousCompatibilitySetSHA256)
        let manifest = CompatibilitySetManifest(
            compatibilitySetID: previousID,
            envelopeSHA256: previousDigest,
            version: CoordinatorClient.binaryVersion,
            catalogReleaseID: "release-a",
            catalogPolicyVersion: "policy-a",
            maintenanceLeaseSeconds: 600,
            readinessTimeoutSeconds: 300
        )
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(
            status: status,
            recorder: CoordinatorFrameRecorder(),
            catalogReleaseID: "release-a",
            catalogPolicyVersion: "policy-a",
            catalogCandidateSHA256: String(repeating: "a", count: 64),
            catalogSignerKeyID: "operator-2026-01",
            catalogRowIdentity: String(repeating: "b", count: 64),
            compatibilitySetIDOverride: previousID,
            installedCompatibilityManifest: { _, version in
                version == CoordinatorClient.binaryVersion ? manifest : nil
            },
            coordinatorReadiness: { _, _, _ in true },
            autoupdateMarkerStore: fixture.store
        )

        try await client.handleCoordinatorPayloadForTest([
            "type": "hello_ack",
            "assigned_id": "assigned-a",
            "heartbeat_interval_s": 30,
            "catalog_compatible": true,
            "compatibility_policy": "configured",
            "accepted_compatibility_set_id": previousID,
            "recommended_compatibility_set_id": previousID,
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.releaseBackupPath ?? ""))
    }

    func testCatalogWarmSwapNeverPublishesNewModelUnderBootRowIdentity() async throws {
        let recorder = CoordinatorFrameRecorder()
        let runtime = makeRuntime(modelID: "model-a", modelHash: "old-hash", warmSwapEnabled: true) { target in
            (target, "new-hash")
        }
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: "old-hash"
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            enableWarmSwap: true,
            modelRuntime: runtime,
            connectAndRunOverride: { XCTFail("catalog-invalidated client must not reconnect") },
            catalogReleaseID: "release-a",
            catalogPolicyVersion: "policy-a",
            catalogCandidateSHA256: String(repeating: "a", count: 64),
            catalogSignerKeyID: "operator-2026-01",
            catalogRowIdentity: String(repeating: "b", count: 64)
        )
        let swap = try await runtime.beginSwap(targetModelID: "model-b")
        try await swap.value

        let hello = await client.helloMessage()
        let auth = await client.authInitialMessage(attempt: Tier2AuthAttempt())
        XCTAssertEqual(hello["model_id"] as? String, "model-b")
        XCTAssertNil(hello["catalog_row_identity"])
        XCTAssertNil(auth["catalog_row_identity"])
        do {
            try await client.sendHeartbeatForTest()
            XCTFail("catalog-invalidated warm swap must not send a heartbeat")
        } catch {}
        do {
            try await client.connectAndRunOnceForTest()
            XCTFail("catalog-invalidated warm swap must not reconnect")
        } catch {}
        let frames = await recorder.frames
        XCTAssertTrue(frames.isEmpty)
    }

    func testCatalogWarmSwapInvalidatesSameModelIDWhenArtifactHashChanges() async throws {
        let recorder = CoordinatorFrameRecorder()
        let runtime = makeRuntime(modelID: "model-a", modelHash: "old-hash", warmSwapEnabled: true) { target in
            (target, "new-hash")
        }
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: "old-hash"
        )
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            enableWarmSwap: true,
            modelRuntime: runtime,
            connectAndRunOverride: { XCTFail("artifact-invalidated client must not reconnect") },
            catalogReleaseID: "release-a",
            catalogPolicyVersion: "policy-a",
            catalogCandidateSHA256: String(repeating: "a", count: 64),
            catalogSignerKeyID: "operator-2026-01",
            catalogRowIdentity: String(repeating: "b", count: 64),
            catalogModelSHA256: "canonical-old-hash",
            catalogArtifactIdentity: { _ in "canonical-new-hash" }
        )
        let swap = try await runtime.beginSwap(targetModelID: "model-a")
        try await swap.value

        let hello = await client.helloMessage()
        XCTAssertNil(hello["catalog_row_identity"])
        do {
            try await client.sendHeartbeatForTest()
            XCTFail("same-ID different-hash warm swap must fail closed")
        } catch {}
        do {
            try await client.connectAndRunOnceForTest()
            XCTFail("same-ID different-hash warm swap must not reconnect")
        } catch {}
        let frames = await recorder.frames
        XCTAssertTrue(frames.isEmpty)
    }

    func testCatalogWarmSwapBootTrustDoesNotCompareWeightManifestToCanonicalArtifactHash() async throws {
        let recorder = CoordinatorFrameRecorder()
        let runtime = makeRuntime(
            modelID: "model-a",
            modelHash: "runtime-safetensors-json-hash",
            warmSwapEnabled: true
        ) { target in
            (target, "runtime-safetensors-json-hash")
        }
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1),
            modelHash: "runtime-safetensors-json-hash"
        )
        let connected = LockedBox(false)
        let client = try await makeClient(
            status: status,
            recorder: recorder,
            enableWarmSwap: true,
            modelRuntime: runtime,
            connectAndRunOverride: { connected.set(true) },
            catalogReleaseID: "release-a",
            catalogPolicyVersion: "policy-a",
            catalogCandidateSHA256: String(repeating: "a", count: 64),
            catalogSignerKeyID: "operator-2026-01",
            catalogRowIdentity: String(repeating: "b", count: 64),
            catalogModelSHA256: "canonical-all-files-hash",
            catalogArtifactIdentity: { _ in
                XCTFail("generation-zero boot trust must use completed startup preflight")
                return nil
            }
        )

        try await client.connectAndRunOnceForTest()

        XCTAssertTrue(connected.get())
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

    private static func makeAutoupdateRecoveryFixture(
        targetVersion: String,
        commitOwner: String? = nil,
        transactionState: CompatibilitySetTransactionState? = nil,
        signedRelease: Bool = false
    ) throws -> (home: URL, store: AutoUpdateMarkerStore, marker: AutoUpdatePendingMarker, binary: URL, backup: URL) {
        let home = try makeTemporaryDirectory(prefix: "coordinator-autoupdate-")
        let store = AutoUpdateMarkerStore(homeDirectory: home)
        try store.ensureTrustedRoot()
        try Data().write(to: store.lockURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: store.lockURL.path
        )
        let binaryDir = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let updateID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let binary = binaryDir.appendingPathComponent("macprovider-cli")
        let backup = binaryDir.appendingPathComponent(".macprovider-cli.rollback-\(updateID)")
        try Data("new".utf8).write(to: binary)
        try Data("old".utf8).write(to: backup)
        let releaseBackup = store.releaseRollbackBackupPath(binaryURL: binary, updateID: updateID)
        if transactionState != nil {
            try FileManager.default.createDirectory(
                at: releaseBackup,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let previousID = "Augustas11/macprovider:v\(CoordinatorClient.binaryVersion)@0123456789abcdef0123456789abcdef01234567"
        let targetCompatibilitySetID = signedRelease
            ? "Augustas11/macprovider:v\(targetVersion)@fedcba9876543210fedcba9876543210fedcba98"
            : "Augustas11/macprovider:v9.9.9@fedcba9876543210fedcba9876543210fedcba98"
        let marker = AutoUpdatePendingMarker(
            updateID: updateID,
            targetVersion: targetVersion,
            targetPath: binary.path,
            backupPath: backup.path,
            size: 3,
            mode: 0o755,
            sha256: AutoUpdateEvent.sha256Hex("old"),
            markerDeadline: ISO8601DateFormatter.coordinatorAutoupdateTest.string(from: Date().addingTimeInterval(300)),
            releaseBackupPath: transactionState == nil ? nil : releaseBackup.path,
            releaseBackupSHA256: transactionState == nil ? nil : AutoUpdateEvent.sha256Hex(""),
            commitOwner: commitOwner,
            targetCompatibilitySetID: transactionState == nil && !signedRelease
                ? nil
                : targetCompatibilitySetID,
            targetCompatibilitySetSHA256: transactionState == nil && !signedRelease
                ? nil
                : String(repeating: "9", count: 64),
            previousVersion: transactionState == nil ? nil : CoordinatorClient.binaryVersion,
            previousCompatibilitySetID: transactionState == nil ? nil : previousID,
            previousCompatibilitySetSHA256: transactionState == nil
                ? nil
                : String(repeating: "8", count: 64),
            discoveryHeadSequence: signedRelease ? 12 : nil,
            discoveryHeadSHA256: signedRelease ? String(repeating: "7", count: 64) : nil,
            updateAuthorityMode: signedRelease ? "signed_release" : nil,
            transactionState: transactionState
        )
        try store.writePending(marker)
        return (home, store, marker, binary, backup)
    }

    private static func expireAutoupdateMarker(at markerURL: URL) throws {
        let data = try Data(contentsOf: markerURL)
        guard var marker = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        marker["marker_deadline"] = "2000-01-01T00:00:00Z"
        let expired = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
        try expired.write(to: markerURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerURL.path
        )
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

    private struct PreparedInBandAEADRekey {
        let client: CoordinatorClient
        let coordinatorSession: Tier2ProviderSession
        let rekeyID: String
        let newKID: String
        let proof: [String: Any]
    }

    private func prepareInBandAEADRekey(
        recorder: CoordinatorFrameRecorder,
        sendOverride: CoordinatorClient.SendOverride? = nil
    ) async throws -> PreparedInBandAEADRekey {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let client = try await makeClient(status: status, recorder: recorder, sendOverride: sendOverride)
        let oldSession = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-v2",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "old-kid",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data(repeating: 0x33, count: 4),
            p2cNonceBase: Data(repeating: 0x44, count: 4)
        )
        try await client.acceptAuthResponseForTest([
            "type": "auth_response", "version": 2, "status": "accepted",
            "assigned_id": "assigned-v2", "heartbeat_interval_s": 30,
            "tier2_session": ["encrypted_leg": [
                "enabled": true,
                "alg": Tier2ProviderSession.aeadSuite,
                "kid": "old-kid",
                "in_band_aead_rekey_v1": true,
            ]],
        ], session: oldSession)

        let rekeyID = "rekey-adversarial"
        let coordinatorPrivate = Curve25519.KeyAgreement.PrivateKey()
        let coordinatorPublic = coordinatorPrivate.publicKey.rawRepresentation.base64URLUnpadded()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.string(from: Date().addingTimeInterval(30))
        try await client.handleCoordinatorPayloadForTest([
            "type": "aead_rekey_request", "version": 1, "rekey_id": rekeyID,
            "assigned_id": "assigned-v2", "reason": "age_threshold", "old_kid": "old-kid",
            "coordinator_ecdh_public_key": coordinatorPublic,
            "selected_aead": Tier2ProviderSession.aeadSuite,
            "expires_at": expiresAt,
        ])
        let frames = await recorder.frames
        let response = try XCTUnwrap(frames.last { $0["type"] as? String == "aead_rekey_response" })
        let providerPublic = try XCTUnwrap(response["provider_ecdh_public_key"] as? String)
        let newKID = try XCTUnwrap(response["new_kid"] as? String)
        let coordinatorSession = try Tier2ProviderSession.coordinatorSessionForRekeyTest(
            coordinatorPrivateKey: coordinatorPrivate,
            providerID: "provider-test",
            assignedID: "assigned-v2",
            providerPublicKeyBase64URL: providerPublic,
            selectedAEAD: Tier2ProviderSession.aeadSuite
        )
        return PreparedInBandAEADRekey(
            client: client,
            coordinatorSession: coordinatorSession,
            rekeyID: rekeyID,
            newKID: newKID,
            proof: [
                "type": "aead_rekey_proof",
                "version": 1,
                "rekey_id": rekeyID,
                "provider_id": "provider-test",
                "assigned_id": "assigned-v2",
                "old_kid": "old-kid",
                "new_kid": newKID,
                "provider_ecdh_public_key": providerPublic,
                "coordinator_ecdh_public_key": coordinatorPublic,
                "selected_aead": Tier2ProviderSession.aeadSuite,
                "expires_at": expiresAt,
            ]
        )
    }

    private func makeClient(
        status: ProviderStatus,
        recorder: CoordinatorFrameRecorder,
        drainTimeoutSeconds: Int = 1,
        reconnectGraceNanoseconds: UInt64 = 10 * 1_000_000_000,
        reconnectInitialBackoffNanoseconds: UInt64 = 1_000_000_000,
        receiptKeyRotationTimeoutNanoseconds: UInt64 = 55 * 1_000_000_000,
        enableWarmSwap: Bool = false,
        modelRuntime: ModelRuntime? = nil,
        attestationGenerator: Tier2AttestationTokenGenerating = StaticAttestationGenerator(token: nil),
        pairingController: PairingController? = nil,
        connectAndRunOverride: (@Sendable () async throws -> Void)? = nil,
        providerReceiptPublicKey: String? = nil,
        providerAdmissionPublicKey: String? = nil,
        providerAdmissionNextPublicKey: String? = nil,
        providerAdmissionRecovery: Bool = false,
        commitAdmissionIdentityPublicKey: (@Sendable (Data, Date?) throws -> Void)? = nil,
        sendOverride: CoordinatorClient.SendOverride? = nil,
        watchdogExitPreparation: (@Sendable () -> Void)? = nil,
        watchdogExitHook: (@Sendable (String) -> Void)? = nil,
        publishesSpecDecodeTelemetry: Bool = false,
        modelCatalogModelID: String? = nil,
        losslessnessProbeEnabled: Bool = false,
        credentialBootstrap: Bool = false,
        bootstrapReceiptSigningKey: Curve25519.Signing.PrivateKey? = nil,
        bootstrapReferralCode: String? = nil,
        receiptIdentitySigningKey: Curve25519.Signing.PrivateKey? = nil,
        receiptIdentitySigningKeyCandidates: [Curve25519.Signing.PrivateKey] = [],
        catalogReleaseID: String? = nil,
        catalogPolicyVersion: String? = nil,
        catalogCandidateSHA256: String? = nil,
        catalogSignerKeyID: String? = nil,
        catalogRowIdentity: String? = nil,
        compatibilitySetIDOverride: String? = nil,
        installedCompatibilityManifest: CoordinatorClient.InstalledCompatibilityManifest? = nil,
        catalogModelSHA256: String? = nil,
        catalogArtifactIdentity: CoordinatorClient.CatalogArtifactIdentity? = nil,
        coordinatorReadiness: CoordinatorClient.CoordinatorReadiness? = nil,
        coordinatorReadinessAttempts: Int = 1,
        autoupdateMarkerStore: AutoUpdateMarkerStore = AutoUpdateMarkerStore(),
        autoupdateLocalHealthRequiredConsecutiveSamples: Int = SelfUpdate.localHealthRequiredConsecutiveSamples,
        autoupdateLocalStatusProbe: (@Sendable () async -> [String: Any]?)? = nil,
        autoupdateLocalHealthSleep: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        },
        autoupdateReloadHelperFence: @escaping CoordinatorClient.ReloadHelperFence = {},
        configPath: String = "/tmp/macprovider-test.yaml",
        providerToken: String? = nil,
        providerCredentialStore: any ProviderCredentialStoring = KeychainProviderCredentialStore(),
        credentialStatusRuntime: ProviderCredentialStatusRuntime = ProviderCredentialStatusRuntime(.unconfigured),
        admissionIdentityStatusRuntime: ProviderAdmissionIdentityStatusRuntime = ProviderAdmissionIdentityStatusRuntime()
    ) async throws -> CoordinatorClient {
        var config = AppConfig.defaults(configPath: configPath)
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.providerToken = providerToken
        config.model = "model-a"
        config.modelCatalogModelID = modelCatalogModelID
        config.drainTimeoutSeconds = drainTimeoutSeconds
        config.enableWarmSwap = enableWarmSwap
        config.publishesSpecDecodeTelemetry = publishesSpecDecodeTelemetry
        config.losslessnessProbeEnabled = losslessnessProbeEnabled
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
            reconnectInitialBackoffNanoseconds: reconnectInitialBackoffNanoseconds,
            receiptKeyRotationTimeoutNanoseconds: receiptKeyRotationTimeoutNanoseconds,
            attestationGenerator: attestationGenerator,
            sleepAssertionFactory: { nil },
            pairingController: pairingController,
            connectAndRunOverride: connectAndRunOverride,
            providerReceiptPublicKey: providerReceiptPublicKey,
            providerAdmissionPublicKey: providerAdmissionPublicKey,
            providerAdmissionNextPublicKey: providerAdmissionNextPublicKey,
            providerAdmissionRecovery: providerAdmissionRecovery,
            commitAdmissionIdentityPublicKey: commitAdmissionIdentityPublicKey,
            catalogReleaseID: catalogReleaseID,
            catalogPolicyVersion: catalogPolicyVersion,
            catalogCandidateSHA256: catalogCandidateSHA256,
            catalogSignerKeyID: catalogSignerKeyID,
            catalogRowIdentity: catalogRowIdentity,
            compatibilitySetIDOverride: compatibilitySetIDOverride,
            installedCompatibilityManifest: installedCompatibilityManifest,
            catalogModelSHA256: catalogModelSHA256,
            catalogArtifactIdentity: catalogArtifactIdentity,
            coordinatorReadiness: coordinatorReadiness,
            coordinatorReadinessAttempts: coordinatorReadinessAttempts,
            coordinatorReadinessRetryNanoseconds: 0,
            autoupdateMarkerStore: autoupdateMarkerStore,
            autoupdateLocalHealthRequiredConsecutiveSamples: autoupdateLocalHealthRequiredConsecutiveSamples,
            autoupdateLocalStatusProbe: autoupdateLocalStatusProbe,
            autoupdateLocalHealthSleep: autoupdateLocalHealthSleep,
            autoupdateReloadHelperFence: autoupdateReloadHelperFence,
            credentialBootstrap: credentialBootstrap,
            bootstrapReceiptSigningKey: bootstrapReceiptSigningKey,
            bootstrapReferralCode: bootstrapReferralCode,
            receiptIdentitySigningKey: receiptIdentitySigningKey,
            receiptIdentitySigningKeyCandidates: receiptIdentitySigningKeyCandidates,
            providerCredentialStore: providerCredentialStore,
            credentialStatusRuntime: credentialStatusRuntime,
            admissionIdentityStatusRuntime: admissionIdentityStatusRuntime,
            watchdogExitPreparation: watchdogExitPreparation ?? {},
            watchdogExitHook: watchdogExitHook ?? defaultWatchdogHook
        ))
    }

    private static func localAutoupdateStatus(
        version: String,
        compatibilitySetID: String,
        compatibilitySetSHA256: String,
        instanceID: String,
        processID: pid_t,
        modelLoaded: Bool = true
    ) -> [String: Any] {
        [
            "binary_version": version,
            "compatibility_set_id": compatibilitySetID,
            "compatibility_set_sha256": compatibilitySetSHA256,
            "model_loaded": modelLoaded,
            "status": "ready",
            "service_instance": [
                "instance_id": instanceID,
                "pid": Int(processID),
            ],
        ]
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

    // Regression: the system sleep assertion must be held for the whole serving
    // lifetime — acquired once, surviving per-connection cleanup (disconnect),
    // and released only on stop(). Previously it was torn down in
    // cleanupConnection() on every disconnect, letting a battery/8GB Mac sleep
    // during reconnect backoff and flap online only ~1 min every ~30 min.
    func testSleepAssertionSurvivesDisconnectAndReleasesOnStop() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let runtime = try await ModelRuntime(modelID: nil)
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "mp-0123456789abcdef0123456789abcdef"
        config.model = "model-a"

        let spy = SpySleepAssertionFactory()
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            sleepAssertionFactory: { spy.make() }
        ))

        // Serving intent acquires once (as the reconnect loop / session-accept does).
        await client.setSleepAssertionDesiredForTest(true)
        var held = await client.sleepAssertionIsHeldForTest()
        XCTAssertTrue(held)
        XCTAssertEqual(spy.startCount, 1)

        // Idempotent: a re-accept after reconnect must not churn the child.
        await client.setSleepAssertionDesiredForTest(true)
        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(spy.assertion.stopCount, 0)

        // A disconnect (cleanupConnection) must NOT release the assertion —
        // the reconnect backoff must keep the Mac awake.
        await client.cleanupConnectionForTest()
        held = await client.sleepAssertionIsHeldForTest()
        XCTAssertTrue(held, "sleep assertion must survive a disconnect")
        XCTAssertEqual(spy.assertion.stopCount, 0, "disconnect must not stop caffeinate")

        // Terminal shutdown releases it exactly once.
        await client.stop()
        held = await client.sleepAssertionIsHeldForTest()
        XCTAssertFalse(held)
        XCTAssertEqual(spy.assertion.stopCount, 1)
    }

    // Serving intent is the boundary, not "connected": clearing intent (operator
    // pause / terminal exit) releases the assertion so a paused provider may
    // sleep, and re-declaring it (resume) re-arms keep-awake. This pins the
    // audit fix for the operator-pause over-hold.
    func testSleepAssertionFollowsServingIntent() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let runtime = try await ModelRuntime(modelID: nil)
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "mp-0123456789abcdef0123456789abcdef"
        config.model = "model-a"

        let spy = SpySleepAssertionFactory()
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            sleepAssertionFactory: { spy.make() }
        ))

        // Serving → held.
        await client.setSleepAssertionDesiredForTest(true)
        var held = await client.sleepAssertionIsHeldForTest()
        XCTAssertTrue(held)
        XCTAssertEqual(spy.startCount, 1)

        // Pause / terminal exit clears intent → released (paused Mac may sleep).
        await client.setSleepAssertionDesiredForTest(false)
        held = await client.sleepAssertionIsHeldForTest()
        XCTAssertFalse(held, "cleared serving intent must let the Mac sleep")
        XCTAssertEqual(spy.assertion.stopCount, 1)

        // Resume re-declares intent → re-armed.
        await client.setSleepAssertionDesiredForTest(true)
        held = await client.sleepAssertionIsHeldForTest()
        XCTAssertTrue(held)
        XCTAssertEqual(spy.startCount, 2)

        await client.stop()
        held = await client.sleepAssertionIsHeldForTest()
        XCTAssertFalse(held)
        XCTAssertEqual(spy.assertion.stopCount, 2)
    }

    // stop() is a terminal latch: after shutdown, a late/reentrant arm request
    // (a suspended rotation/session-accept/resume resuming after stop) must NOT
    // re-hold the assertion — the Mac must be allowed to sleep once the provider
    // has permanently stopped serving. Pins the audit fix for the stop()
    // reentrancy race and the resume-after-terminal-exit over-hold.
    func testSleepAssertionRefusesReArmAfterStop() async throws {
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let runtime = try await ModelRuntime(modelID: nil)
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "mp-0123456789abcdef0123456789abcdef"
        config.model = "model-a"

        let spy = SpySleepAssertionFactory()
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: runtime,
            providerStatus: status,
            attestationGenerator: StaticAttestationGenerator(token: nil),
            sleepAssertionFactory: { spy.make() }
        ))

        await client.setSleepAssertionDesiredForTest(true)
        var held = await client.sleepAssertionIsHeldForTest()
        XCTAssertTrue(held)

        await client.stop()
        held = await client.sleepAssertionIsHeldForTest()
        XCTAssertFalse(held)
        XCTAssertEqual(spy.assertion.stopCount, 1)

        // A reentrant arm after stop must be refused (canServe == false).
        await client.setSleepAssertionDesiredForTest(true)
        held = await client.sleepAssertionIsHeldForTest()
        XCTAssertFalse(held, "stop() must latch: no re-arm after shutdown")
        XCTAssertEqual(spy.startCount, 1, "no new caffeinate child after stop")
        XCTAssertEqual(spy.assertion.stopCount, 1)
    }
}

private enum CoordinatorClientTestError: Error {
    case unexpectedContainerLoader
    case sendStateUpdateFailed
    case missingProviderECDHPublicKey
    case closedByCoordinator
}

// Spy sleep assertion + factory: count start()/stop() so a test can prove the
// assertion is held for the serving lifetime rather than churned per session.
private final class SpySleepAssertion: ProviderSleepAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var _stopCount = 0
    var stopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _stopCount
    }
    func stop() {
        lock.lock(); _stopCount += 1; lock.unlock()
    }
}

private final class SpySleepAssertionFactory: @unchecked Sendable {
    let assertion = SpySleepAssertion()
    private let lock = NSLock()
    private var _startCount = 0
    var startCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _startCount
    }
    func make() -> ProviderSleepAssertion? {
        lock.lock(); _startCount += 1; lock.unlock()
        return assertion
    }
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

private actor LocalAutoupdateHealthSleepGate {
    private(set) var started = false
    private var released = false

    func waitForRelease() async {
        started = true
        while !released {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
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
    private let providerID: String
    private let assignedProviderToken: String?
    private let coordinatorPrivateKey = Curve25519.KeyAgreement.PrivateKey()
    private var receiveCount = 0
    private var keyID: String?

    init(
        outcome: FakeTier2AuthOutcome,
        assignedID: String = "assigned-rotation",
        providerID: String = "provider-test",
        assignedProviderToken: String? = nil
    ) {
        self.outcome = outcome
        self.assignedID = assignedID
        self.providerID = providerID
        self.assignedProviderToken = assignedProviderToken
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
                providerID: providerID,
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
                var response: [String: Any] = [
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
                ]
                if let assignedProviderToken {
                    response["assigned_provider_token"] = assignedProviderToken
                }
                return .string(Self.jsonString(response))
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

private actor ReferralBootstrapConnectAttempts {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private final class FakeProviderWebSocketFactory: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeProviderWebSocketFactory")
    private var sockets: [FakeProviderWebSocketTask]
    private var requests: [URLRequest] = []

    init(sockets: [FakeProviderWebSocketTask]) {
        self.sockets = sockets
    }

    private(set) var lastRequest: URLRequest?

    func makeSocket(for request: URLRequest) -> ProviderWebSocketTask {
        queue.sync {
            lastRequest = request
            requests.append(request)
            precondition(!sockets.isEmpty, "fake web socket factory exhausted")
            return sockets.removeFirst()
        }
    }

    func requestsSnapshot() -> [URLRequest] {
        queue.sync { requests }
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
    let closeCodeRawValueForDiagnostics: Int?
    let closeReasonTextForDiagnostics: String?
    private let sendErrorTypes: Set<String>
    private let receiveOverrideIgnoresCancellation: Bool
    private let receiveOverride: (@Sendable (FakeProviderWebSocketTask) async throws -> URLSessionWebSocketTask.Message)?

    init(
        receiveResults: [Result<URLSessionWebSocketTask.Message, Error>],
        receiveDelayNanoseconds: UInt64 = 0,
        closeCodeRawValue: Int? = nil,
        closeReasonText: String? = nil,
        sendErrorTypes: Set<String> = [],
        receiveOverrideIgnoresCancellation: Bool = false,
        receiveOverride: (@Sendable (FakeProviderWebSocketTask) async throws -> URLSessionWebSocketTask.Message)? = nil
    ) {
        self.receiveResults = receiveResults
        self.receiveDelayNanoseconds = receiveDelayNanoseconds
        self.closeCodeRawValueForDiagnostics = closeCodeRawValue
        self.closeReasonTextForDiagnostics = closeReasonText
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
