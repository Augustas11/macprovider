import CryptoKit
import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class InferenceRelayTests: XCTestCase {
    func testEightAdvertisedSeatsSetRelayAdmissionLimit() async throws {
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 8)
        )
        let relay = InferenceRelay(
            modelRuntime: FakeStreamingRuntime(),
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            sendFrame: { _ in }
        )
        let admissionLimit = await relay.currentAdmissionLimit()
        XCTAssertEqual(admissionLimit, 8)
    }

    func testOneAdvertisedSeatRejectsSecondRelayRequest() async throws {
        try await assertRelayCapacity(seats: 1)
    }

    func testRelayAdmissionExpandsAfterProviderStatusCapacityWarmSwap() async throws {
        try await assertRelayCapacityAfterWarmSwap(startupSeats: 1, currentSeats: 8)
    }

    func testRelayAdmissionContractsAfterProviderStatusCapacityWarmSwap() async throws {
        try await assertRelayCapacityAfterWarmSwap(startupSeats: 8, currentSeats: 1)
    }

    func testCoordinatorRelayAdmissionFollowsConfiguredSeats() async throws {
        let cases: [(override: Int?, expectedSeats: Int)] = [(nil, 1), (8, 8)]
        for testCase in cases {
            var config = AppConfig.defaults(configPath: "/tmp/macprovider-relay-capacity-test.yaml")
            config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
            config.providerID = "provider-relay-capacity-test"
            config.model = "mlx-community/Test-Model"
            config.maxConcurrencyOverride = testCase.override
            let status = ProviderStatus(
                modelID: config.model,
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: testCase.expectedSeats)
            )
            let client = try XCTUnwrap(CoordinatorClient(
                config: config,
                modelRuntime: FakeStreamingRuntime(),
                providerStatus: status
            ))
            let relayLimit = await client.relayAdmissionLimitForTest()
            XCTAssertEqual(relayLimit, testCase.expectedSeats)
        }
    }

    private func assertRelayCapacity(seats: Int) async throws {
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: seats)
        )
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: FakeStreamingRuntime(),
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            maxActiveRequests: seats,
            maxBodyBytes: 4096,
            sendFrame: { frame in await recorder.append(frame) }
        )
        try await assertRelayCapacity(seats: seats, status: status, relay: relay, recorder: recorder)
    }

    private func assertRelayCapacityAfterWarmSwap(startupSeats: Int, currentSeats: Int) async throws {
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: startupSeats)
        )
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: FakeStreamingRuntime(),
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            maxActiveRequests: startupSeats,
            maxBodyBytes: 4096,
            sendFrame: { frame in await recorder.append(frame) }
        )
        await status.completeTargetSwap(
            modelID: "mlx-community/Test-Model",
            modelHash: nil,
            maxConcurrency: currentSeats
        )
        let admissionLimit = await relay.currentAdmissionLimit()
        XCTAssertEqual(admissionLimit, currentSeats)
    }

    private func assertRelayCapacity(
        seats: Int,
        status: ProviderStatus,
        relay: InferenceRelay,
        recorder: FrameRecorder
    ) async throws {
        let body = #"{"model":"mlx-community/Test-Model","messages":[{"role":"user","content":"hello"}],"max_tokens":20,"stream":true}"#

        for index in 1...seats {
            try await relay.handleInferenceRequest([
                "type": "inference_request",
                "request_id": "req-capacity-\(index)",
                "stream": true,
                "body": body,
            ])
        }
        try await waitUntil {
            let frames = await recorder.frames
            return (1...seats).allSatisfy { index in
                frames.contains {
                    $0["type"] as? String == "inference_response_chunk" &&
                        $0["request_id"] as? String == "req-capacity-\(index)"
                }
            }
        }

        let overflowID = "req-capacity-overflow"
        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": overflowID,
            "stream": true,
            "body": body,
        ])
        let fullFrames = await recorder.frames
        let overflow = try XCTUnwrap(fullFrames.first {
            $0["type"] as? String == "inference_response_end" && $0["request_id"] as? String == overflowID
        })
        XCTAssertEqual(overflow["status"] as? String, "error_queue_full")
        XCTAssertFalse(fullFrames.contains {
            $0["type"] as? String == "inference_response_end" &&
                $0["status"] as? String == "error_queue_full" &&
                $0["request_id"] as? String != overflowID
        })

        for index in 1...seats {
            try await relay.handleCancelRequest([
                "type": "cancel_request",
                "request_id": "req-capacity-\(index)",
                "reason": "test_cleanup",
            ])
        }
        let drained = await relay.waitUntilIdle(timeoutSeconds: 2)
        XCTAssertTrue(drained)
        let finalFrames = await recorder.frames
        for index in 1...seats {
            let terminal = try XCTUnwrap(finalFrames.first {
                $0["type"] as? String == "inference_response_end" &&
                    $0["request_id"] as? String == "req-capacity-\(index)"
            })
            XCTAssertEqual(terminal["status"] as? String, "cancelled")
        }
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.requestsInFlight, 0)
    }

    func testCancelActiveStreamingRequestReportsUsage() async throws {
        let telemetry = KVCacheTelemetryCapture()
        let runtime = FakeStreamingRuntime()
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        let body = #"{"model":"mlx-community/Test-Model","messages":[{"role":"user","content":"hello"}],"max_tokens":20,"stream":true}"#
        let frames = try await KVCacheTelemetry.withSink({ telemetry.append($0) }) {
            try await relay.handleInferenceRequest([
                "type": "inference_request",
                "request_id": "req-cancel-usage",
                "stream": true,
                "body": body,
            ])

            try await waitUntil {
                let chunks = await recorder.frames.filter { $0["type"] as? String == "inference_response_chunk" }
                return chunks.count == 2
            }

            try await relay.handleCancelRequest([
                "type": "cancel_request",
                "request_id": "req-cancel-usage",
                "reason": "buyer_disconnected",
            ])

            return try await waitForFrames { frames in
                frames.contains {
                    $0["type"] as? String == "inference_response_end" &&
                        $0["status"] as? String == "cancelled"
                }
            } from: {
                await recorder.frames
            }
        }

        let end = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(end["request_id"] as? String, "req-cancel-usage")
        XCTAssertEqual(end["status"] as? String, "cancelled")
        let chunksSent = try XCTUnwrap(end["chunks_sent"] as? Int)
        let responseChunks = frames.filter { $0["type"] as? String == "inference_response_chunk" }
        XCTAssertEqual(chunksSent, responseChunks.count)
        XCTAssertTrue(
            [2, 3].contains(chunksSent),
            "cancel may race with the fake runtime's already-queued second content chunk"
        )
        let usage = try XCTUnwrap(end["usage"] as? [String: Any])
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 7)
        XCTAssertEqual(usage["cached_prompt_tokens"] as? Int, 0)
        XCTAssertEqual(usage["completion_tokens"] as? Int, 2)
        XCTAssertEqual(usage["total_tokens"] as? Int, 9)
        XCTAssertTrue(usage.keys.contains("macprovider_model_hash_observed"))
        XCTAssertTrue(usage["macprovider_model_hash_observed"] is NSNull)
        XCTAssertTrue(telemetry.records.isEmpty)
    }

    // Money-path regression (BUILD_SPEC relay_serve_model_id_alias): the
    // coordinator advertises config.modelCatalogModelID as this provider's
    // model_id and relays buyer requests carrying it. With the served model
    // configured (warm-swap off), a WS-relayed request whose `model` is the
    // catalog alias must be accepted and served, not 404'd.
    func testCatalogAliasAcceptedWhenConfiguredModelLoaded() async throws {
        let runtime = FakeStreamingRuntime()
        let status = ProviderStatus(
            modelID: "qwen3-coder-30b-a3b-instruct",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "qwen3-coder-30b-a3b-instruct",
            catalogModelIDAlias: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            warmSwapEnabled: false,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        let body = #"{"model":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","messages":[{"role":"user","content":"hello"}],"max_tokens":20,"stream":false}"#
        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-alias-accept",
            "stream": false,
            "body": body,
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        let end = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(
            end["status"] as? String,
            "complete",
            "catalog alias must be accepted and served when the configured model is loaded"
        )
    }

    // Contrast: with no alias configured, the same catalog-id request is a
    // genuine model mismatch and must be rejected 404 (surfaced by the relay as
    // an error_model_not_loaded terminal frame).
    func testCatalogAliasRequestRejectedWhenNoAliasConfigured() async throws {
        let runtime = FakeStreamingRuntime()
        let status = ProviderStatus(
            modelID: "qwen3-coder-30b-a3b-instruct",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "qwen3-coder-30b-a3b-instruct",
            catalogModelIDAlias: nil,
            warmSwapEnabled: false,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        let body = #"{"model":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","messages":[{"role":"user","content":"hello"}],"max_tokens":20,"stream":false}"#
        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-alias-reject",
            "stream": false,
            "body": body,
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        let end = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(end["status"] as? String, "error_model_not_loaded")
    }

    // Money-path regression (audit HIGH — relay warm-swap gate): coordinatorWireModelID
    // advertises the catalog id whenever the *configured* model is the served snapshot,
    // even when warm-swap is enabled. So with warmSwapEnabled == true but the current
    // snapshot still the configured model, a relayed request for the catalog alias must
    // still be accepted (the relay gate keys on validationModelID == loadedModelID, not
    // on warmSwapEnabled). Before the fix this 404'd.
    func testCatalogAliasAcceptedUnderWarmSwapWhenConfiguredModelStillLoaded() async throws {
        let runtime = FakeReceiptCompletionRuntime(servedSnapshot: RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "qwen3-coder-30b-a3b-instruct",
            modelHash: nil
        ))
        let status = ProviderStatus(
            modelID: "qwen3-coder-30b-a3b-instruct",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "qwen3-coder-30b-a3b-instruct",
            catalogModelIDAlias: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            warmSwapEnabled: true,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        let body = #"{"model":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","messages":[{"role":"user","content":"hello"}],"max_tokens":20,"stream":false}"#
        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-alias-warmswap",
            "stream": false,
            "body": body,
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        let end = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(
            end["status"] as? String,
            "complete",
            "catalog alias must be accepted under warm-swap when the configured model is still the served snapshot"
        )
    }

    func testUnknownCancelIsIdempotent() async throws {
        let runtime = try await ModelRuntime(modelID: nil)
        let status = ProviderStatus(
            modelID: nil,
            modelLoaded: false,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: nil,
            maxActiveRequests: 1,
            maxBodyBytes: 1024,
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        try await relay.handleCancelRequest([
            "type": "cancel_request",
            "request_id": "req-missing",
            "reason": "buyer_disconnected",
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["type"] as? String, "inference_response_end")
        XCTAssertEqual(frames[0]["request_id"] as? String, "req-missing")
        XCTAssertEqual(frames[0]["status"] as? String, "cancelled")
        XCTAssertEqual(frames[0]["chunks_sent"] as? Int, 0)
        let usage = try XCTUnwrap(frames[0]["usage"] as? [String: Any])
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 0)
        XCTAssertEqual(usage["cached_prompt_tokens"] as? Int, 0)
        XCTAssertEqual(usage["completion_tokens"] as? Int, 0)
        XCTAssertEqual(usage["total_tokens"] as? Int, 0)
        XCTAssertTrue(usage.keys.contains("macprovider_model_hash_observed"))
        XCTAssertTrue(usage["macprovider_model_hash_observed"] is NSNull)
    }

    func testInvalidInferenceRequestSendsNak() async throws {
        let runtime = try await ModelRuntime(modelID: nil)
        let status = ProviderStatus(
            modelID: nil,
            modelLoaded: false,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: nil,
            maxActiveRequests: 1,
            maxBodyBytes: 1024,
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-bad",
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "nak" }
        } from: {
            await recorder.frames
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["type"] as? String, "nak")
        XCTAssertEqual(frames[0]["in_reply_to"] as? String, "inference_request")
        let error = try XCTUnwrap(frames[0]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_message")
    }

    func testMalformedInferenceRequestIDSendsNak() async throws {
        let runtime = try await ModelRuntime(modelID: nil)
        let status = ProviderStatus(
            modelID: nil,
            modelLoaded: false,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: nil,
            maxActiveRequests: 1,
            maxBodyBytes: 1024,
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": String(repeating: "x", count: 513),
            "stream": false,
            "body": #"{"model":"mlx-community/Test-Model","messages":[]}"#,
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "nak" }
        } from: {
            await recorder.frames
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["type"] as? String, "nak")
        XCTAssertEqual(frames[0]["in_reply_to"] as? String, "inference_request")
        let error = try XCTUnwrap(frames[0]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_request_id")
    }

    func testEncryptedInferenceRequestDecryptsAndEncryptsResponseChunk() async throws {
        let runtime = FakeCompletionRuntime()
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let session = try testTier2Session()
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            tier2Session: session,
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        let body = #"{"model":"mlx-community/Test-Model","messages":[{"role":"user","content":"hello"}],"max_tokens":20,"stream":false}"#
        let encrypted = try Tier2ProviderSession.sealRequestForTest(
            session: session,
            requestID: "req-encrypted",
            stream: false,
            plaintext: body
        )
        try await relay.handleInferenceRequest(encrypted)

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }

        let chunk = try XCTUnwrap(frames.first { $0["type"] as? String == "inference_response_chunk" })
        XCTAssertEqual(chunk["request_id"] as? String, "req-encrypted")
        XCTAssertEqual(chunk["encrypted"] as? Bool, true)
        XCTAssertNil(chunk["data"])
        let plaintext = try Tier2ProviderSession.openResponseChunkForTest(
            session: session,
            frame: chunk,
            requestID: "req-encrypted",
            stream: false
        )
        XCTAssertTrue(plaintext.contains("encrypted answer"))

        let end = try XCTUnwrap(frames.first { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(end["request_id"] as? String, "req-encrypted")
        XCTAssertEqual(end["encrypted"] as? Bool, true)
        let endPlaintext = try Tier2ProviderSession.openResponseEndForTest(
            session: session,
            frame: end,
            requestID: "req-encrypted",
            stream: false,
            seq: 1
        )
        XCTAssertEqual(endPlaintext["status"] as? String, "complete")
        XCTAssertEqual(endPlaintext["chunks_sent"] as? Int, 1)
    }

    func testEncryptedInferenceRequestUsesOnlySealedConversationKey() async throws {
        let runtime = FakeCompletionRuntime()
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let session = try testTier2Session()
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            tier2Session: session,
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        let body = #"{"model":"mlx-community/Test-Model","messages":[{"role":"user","content":"hello"}],"max_tokens":20,"stream":false}"#
        var encrypted = try Tier2ProviderSession.sealRequestForTest(
            session: session,
            requestID: "req-encrypted-conv",
            stream: false,
            plaintext: body,
            conversationKey: "conv:sealed"
        )
        encrypted["conversation_key"] = "conv:forged-top-level"

        try await relay.handleInferenceRequest(encrypted)
        _ = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }

        let keys = await runtime.observedConversationKeys()
        XCTAssertEqual(keys, ["conv:sealed"])
    }

    // SPEC-015 §M.0 / §M.2 — coordinator-WS-mediated non-streaming
    // receipt carries the 9-field v0.3 tuple with
    // `receipt_version == "3"` and `model_hash` matching the
    // runtime-served snapshot. Closes the relay-decode gap the
    // round-3 ARCHITECT audit flagged.
    func testRelayNonStreamingEndFrameCarriesV03Receipt() async throws {
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let runtime = FakeReceiptCompletionRuntime(servedSnapshot: RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "mlx-community/Test-Model",
            modelHash: hash
        ))
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            warmSwapEnabled: true,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            receiptBuilder: ReceiptBuilder(keyStore: FixedRelayReceiptKeyStore(key: key)),
            receiptProviderID: "provider-relay-test",
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-relay-receipt",
            "stream": false,
            "body": #"{"model":"mlx-community/Test-Model","messages":[{"role":"user","content":"hello"}]}"#,
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        let endFrame = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(endFrame["request_id"] as? String, "req-relay-receipt")
        let receiptHeader = try XCTUnwrap(endFrame["receipt"] as? String)
        let pieces = receiptHeader.split(separator: ".")
        XCTAssertEqual(pieces.count, 2, "v0.3 receipt envelope MUST be base64.base64")
        let tupleBytes = try XCTUnwrap(Data(base64Encoded: String(pieces[0])))
        let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleBytes) as? [String: Any])
        XCTAssertEqual(tuple["receipt_version"] as? String, "3")
        XCTAssertEqual(tuple["model_hash"] as? String, hash,
                       "relay path MUST bind served-snapshot hash into the receipt")
        XCTAssertEqual(Set(tuple.keys), [
            "model_hash", "model_id", "output_hash", "prompt_hash",
            "provider_pubkey", "receipt_version", "tokens_out",
            "ttft_ms", "unix_ts",
        ])
        let sigBytes = try XCTUnwrap(Data(base64Encoded: String(pieces[1])))
        XCTAssertEqual(sigBytes.count, 64)
    }

    func testRelayStreamingToolArgumentMismatchFailsClosedWithoutReceipt() async throws {
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let runtime = ModelRuntime(
            modelID: "mlx-community/Test-Model",
            modelHash: hash,
            warmSwapEnabled: true,
            loader: { _ in throw URLError(.unsupportedURL) },
            testCompletion: { _, _ in
                CompletionResult(
                    content: "",
                    finishReason: "tool_calls",
                    promptTokens: 1,
                    completionTokens: 1,
                    toolCalls: [ToolCall(
                        id: "call_0123456789abcdef",
                        functionName: "lookup",
                        arguments: #"{"query":"Done. Next"}"#
                    )],
                    settlementDisposition: .eligibleOwner
                )
            },
            testStreamChunks: [
                .toolCallDelta(StreamToolCallDelta(
                    index: 0,
                    id: "call_0123456789abcdef",
                    type: "function",
                    functionName: "lookup",
                    arguments: #"{"query":"Done ."#
                )),
            ]
        )
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: ProviderStatus(
                modelID: "mlx-community/Test-Model",
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
            ),
            loadedModelID: "mlx-community/Test-Model",
            warmSwapEnabled: true,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            sendFrame: { frame in await recorder.append(frame) }
        )

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-tool-argument-mismatch",
            "stream": true,
            "body": #"{"model":"mlx-community/Test-Model","messages":[{"role":"user","content":"Use lookup."}],"stream":true}"#,
        ])
        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: { await recorder.frames }
        let end = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })

        XCTAssertEqual(end["status"] as? String, "error_internal")
        XCTAssertNil(end["receipt"])
        XCTAssertFalse(frames.contains { frame in
            (frame["data"] as? String)?.contains("\"finish_reason\":\"tool_calls\"") == true
        })
    }

    func testRelayNonStreamingEndFrameCarriesV04SettlementReceiptWithWarmSwapDisabled() async throws {
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let runtime = FakeReceiptCompletionRuntime(servedSnapshot: RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "mlx-community/Test-Model",
            modelHash: hash
        ))
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            warmSwapEnabled: false,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            receiptBuilder: ReceiptBuilder(keyStore: FixedRelayReceiptKeyStore(key: key)),
            receiptProviderID: "provider-relay-test",
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-relay-v04",
            "stream": false,
            "body": #"{"model":"mlx-community/Test-Model","messages":[{"role":"user","content":"hello"}]}"#,
            "settlement": settlementMetadataWire(
                keyID: receiptKeyID(key.publicKey.rawRepresentation),
                modelHash: hash
            ),
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        let endFrame = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual((endFrame["receipt_pending_deadline_seconds"] as? NSNumber)?.int64Value, 120)
        XCTAssertEqual(endFrame["late_receipt_settlement"] as? String, "not_settled")
        let terminalTS = try XCTUnwrap((endFrame["terminal_state_ts_unix_ms"] as? NSNumber)?.int64Value)
        let receiptHeader = try XCTUnwrap(endFrame["receipt"] as? String)
        let pieces = receiptHeader.split(separator: ".")
        XCTAssertEqual(pieces.count, 2)
        let tupleBytes = try XCTUnwrap(Data(base64Encoded: String(pieces[0])))
        let signature = try XCTUnwrap(Data(base64Encoded: String(pieces[1])))
        let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleBytes) as? [String: Any])
        XCTAssertEqual(tuple["receipt_version"] as? String, "4")
        XCTAssertEqual(tuple["signature_key_alg"] as? String, "Ed25519")
        XCTAssertEqual(tuple["model_hash"] as? String, hash)
        XCTAssertEqual(tuple["expected_catalog_model_hash"] as? String, hash)
        XCTAssertEqual(tuple["provider_receipt_key_id"] as? String, receiptKeyID(key.publicKey.rawRepresentation))
        XCTAssertEqual((tuple["terminal_state_ts_unix_ms"] as? NSNumber)?.int64Value, terminalTS)
        XCTAssertEqual(Set(tuple.keys), [
            "account_scope", "attempt_n", "catalog_body_digest", "catalog_id",
            "expected_catalog_model_hash", "issued_at_unix_ms", "model_hash",
            "model_id", "output_hash", "output_prefix_end_byte",
            "output_prefix_start_byte", "prompt_hash", "provider_id",
            "provider_receipt_key_id", "receipt_version", "request_id",
            "route_snapshot_digest", "route_snapshot_mode",
            "route_snapshot_policy_version", "signature_key_alg",
            "terminal_state", "terminal_state_ts_unix_ms", "usage",
        ])
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: tupleBytes))
    }

    func testRelayStreamingEndFrameCarriesV04SettlementReceiptWithWarmSwapDisabled() async throws {
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let runtime = FakeReceiptCompletionRuntime(servedSnapshot: RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "mlx-community/Test-Model",
            modelHash: hash
        ))
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            warmSwapEnabled: false,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            receiptBuilder: ReceiptBuilder(keyStore: FixedRelayReceiptKeyStore(key: key)),
            receiptProviderID: "provider-relay-test",
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-relay-v04",
            "stream": true,
            "body": #"{"model":"mlx-community/Test-Model","stream":true,"messages":[{"role":"user","content":"hello"}]}"#,
            "settlement": settlementMetadataWire(
                keyID: receiptKeyID(key.publicKey.rawRepresentation),
                modelHash: hash
            ),
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        let endFrame = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(endFrame["status"] as? String, "complete")
        XCTAssertEqual((endFrame["receipt_pending_deadline_seconds"] as? NSNumber)?.int64Value, 120)
        XCTAssertEqual(endFrame["late_receipt_settlement"] as? String, "not_settled")
        let receiptHeader = try XCTUnwrap(endFrame["receipt"] as? String)
        let pieces = receiptHeader.split(separator: ".")
        XCTAssertEqual(pieces.count, 2)
        let tupleBytes = try XCTUnwrap(Data(base64Encoded: String(pieces[0])))
        let signature = try XCTUnwrap(Data(base64Encoded: String(pieces[1])))
        let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleBytes) as? [String: Any])
        XCTAssertEqual(tuple["receipt_version"] as? String, "4")
        XCTAssertEqual(tuple["model_hash"] as? String, hash)
        XCTAssertEqual(tuple["expected_catalog_model_hash"] as? String, hash)
        XCTAssertEqual(tuple["provider_receipt_key_id"] as? String, receiptKeyID(key.publicKey.rawRepresentation))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: tupleBytes))
    }

    func testPoolAuthorizedLoopbackStreamingReceiptBindsDeliveredToolCallBytes() async throws {
        let model = "mlx-community/Test-Model"
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let runtime = FakePoolAuthorizedLoopbackToolChatterRuntime(
            servedSnapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: model, modelHash: hash)
        )
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: ProviderStatus(
                modelID: model,
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
            ),
            loadedModelID: model,
            warmSwapEnabled: true,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            receiptBuilder: ReceiptBuilder(keyStore: FixedRelayReceiptKeyStore(key: key)),
            receiptProviderID: "provider-relay-test",
            sendFrame: { frame in await recorder.append(frame) }
        )
        var metadata = settlementMetadataWire(keyID: receiptKeyID(key.publicKey.rawRepresentation), modelHash: hash)
        metadata["pool_runtime_authorization"] = ReceiptEligibilityFixtures.poolRuntimeAuthorizationWire(
            runtimeSource: FakePoolAuthorizedLoopbackToolChatterRuntime.runtimeSource,
            requestID: "req-relay-v04",
            providerID: "provider-relay-test"
        )

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-relay-v04",
            "stream": true,
            "body": #"{"model":"mlx-community/Test-Model","stream":true,"messages":[{"role":"user","content":"Use lookup."}],"tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","properties":{"query":{"type":"string"}}}}}]}"#,
            "settlement": metadata,
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        let deliveredWire = frames.compactMap { $0["data"] as? String }.joined()
        XCTAssertTrue(deliveredWire.contains("visible "))
        XCTAssertTrue(deliveredWire.contains("tool_calls"))
        XCTAssertFalse(deliveredWire.contains("hidden tail"))

        let endFrame = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(endFrame["status"] as? String, "complete")
        let receiptHeader = try XCTUnwrap(endFrame["receipt"] as? String)
        let tupleBytes = try XCTUnwrap(Data(base64Encoded: String(receiptHeader.split(separator: ".")[0])))
        let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleBytes) as? [String: Any])
        XCTAssertEqual((tuple["output_prefix_end_byte"] as? NSNumber)?.int64Value, Int64("visible ".utf8.count))
        let usage = try XCTUnwrap(tuple["usage"] as? [String: Any])
        XCTAssertEqual((usage["delivered_output_bytes"] as? NSNumber)?.int64Value, Int64("visible ".utf8.count))
        XCTAssertEqual((usage["observed_output_tokens"] as? NSNumber)?.int64Value, 3)
        XCTAssertEqual((usage["billable_output_tokens"] as? NSNumber)?.int64Value, 3)
        XCTAssertEqual(
            tuple["output_hash"] as? String,
            try settlementOutputHash(
                content: "visible ",
                toolCalls: [FakePoolAuthorizedLoopbackToolChatterRuntime.toolCall],
                finishReason: "tool_calls",
                terminalState: "normal_done",
                start: 0
            )
        )
        XCTAssertNotEqual(
            tuple["output_hash"] as? String,
            try settlementOutputHash(
                content: "visible hidden tail",
                toolCalls: [FakePoolAuthorizedLoopbackToolChatterRuntime.toolCall],
                finishReason: "tool_calls",
                terminalState: "normal_done",
                start: 0
            )
        )
    }

    func testPoolAuthorizedLoopbackStreamingReceiptOmittedWhenDeliveredContentProofFails() async throws {
        let model = "mlx-community/Test-Model"
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let runtime = FakePoolAuthorizedLoopbackToolChatterRuntime(
            servedSnapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: model, modelHash: hash),
            finalContent: "visible hidden tail",
            emitsHiddenTail: true
        )
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: ProviderStatus(
                modelID: model,
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
            ),
            loadedModelID: model,
            warmSwapEnabled: true,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            receiptBuilder: ReceiptBuilder(keyStore: FixedRelayReceiptKeyStore(key: key)),
            receiptProviderID: "provider-relay-test",
            sendFrame: { frame in await recorder.append(frame) }
        )
        var metadata = settlementMetadataWire(keyID: receiptKeyID(key.publicKey.rawRepresentation), modelHash: hash)
        metadata["pool_runtime_authorization"] = ReceiptEligibilityFixtures.poolRuntimeAuthorizationWire(
            runtimeSource: FakePoolAuthorizedLoopbackToolChatterRuntime.runtimeSource,
            requestID: "req-relay-v04",
            providerID: "provider-relay-test"
        )

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-relay-v04",
            "stream": true,
            "body": #"{"model":"mlx-community/Test-Model","stream":true,"messages":[{"role":"user","content":"Use lookup."}],"tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","properties":{"query":{"type":"string"}}}}}]}"#,
            "settlement": metadata,
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        let deliveredWire = frames.compactMap { $0["data"] as? String }.joined()
        XCTAssertTrue(deliveredWire.contains("visible "))
        XCTAssertTrue(deliveredWire.contains("tool_calls"))
        XCTAssertFalse(deliveredWire.contains("hidden tail"))
        let endFrame = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(endFrame["status"] as? String, "complete")
        XCTAssertNil(endFrame["receipt"])
    }

    func testPoolAuthorizedLoopbackStreamingReceiptOmittedWhenPostToolContentWasSuppressed() async throws {
        let model = "mlx-community/Test-Model"
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let runtime = FakePoolAuthorizedLoopbackToolChatterRuntime(
            servedSnapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: model, modelHash: hash),
            finalContent: "visible ",
            emitsHiddenTail: true
        )
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: ProviderStatus(
                modelID: model,
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
            ),
            loadedModelID: model,
            warmSwapEnabled: true,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            receiptBuilder: ReceiptBuilder(keyStore: FixedRelayReceiptKeyStore(key: key)),
            receiptProviderID: "provider-relay-test",
            sendFrame: { frame in await recorder.append(frame) }
        )
        var metadata = settlementMetadataWire(keyID: receiptKeyID(key.publicKey.rawRepresentation), modelHash: hash)
        metadata["pool_runtime_authorization"] = ReceiptEligibilityFixtures.poolRuntimeAuthorizationWire(
            runtimeSource: FakePoolAuthorizedLoopbackToolChatterRuntime.runtimeSource,
            requestID: "req-relay-v04",
            providerID: "provider-relay-test"
        )

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-relay-v04",
            "stream": true,
            "body": #"{"model":"mlx-community/Test-Model","stream":true,"messages":[{"role":"user","content":"Use lookup."}],"tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","properties":{"query":{"type":"string"}}}}}]}"#,
            "settlement": metadata,
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        let deliveredWire = frames.compactMap { $0["data"] as? String }.joined()
        XCTAssertTrue(deliveredWire.contains("visible "))
        XCTAssertTrue(deliveredWire.contains("tool_calls"))
        XCTAssertFalse(deliveredWire.contains("hidden tail"))
        let endFrame = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(endFrame["status"] as? String, "complete")
        XCTAssertNil(endFrame["receipt"])
    }

    func testRelayNonStreamingCancelledAfterCompletionCarriesBuyerCancelSettlementReceipt() async throws {
        let telemetry = KVCacheTelemetryCapture()
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let runtime = FakeCancelAfterCompletionReceiptRuntime(servedSnapshot: RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "mlx-community/Test-Model",
            modelHash: hash
        ))
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            warmSwapEnabled: true,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            receiptBuilder: ReceiptBuilder(keyStore: FixedRelayReceiptKeyStore(key: key)),
            receiptProviderID: "provider-relay-test",
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        try await KVCacheTelemetry.withSink({ telemetry.append($0) }) {
            async let requestTask: Void = relay.handleInferenceRequest([
                "type": "inference_request",
                "request_id": "req-relay-v04",
                "stream": false,
                "body": #"{"model":"mlx-community/Test-Model","messages":[{"role":"user","content":"hello"}]}"#,
                "settlement": settlementMetadataWire(
                    keyID: receiptKeyID(key.publicKey.rawRepresentation),
                    modelHash: hash
                ),
            ])
            try await Task.sleep(nanoseconds: 20_000_000)
            try await relay.handleCancelRequest([
                "type": "cancel_request",
                "request_id": "req-relay-v04",
            ])
            try await requestTask
        }

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        let endFrame = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(endFrame["status"] as? String, "cancelled")
        let terminalTS = try XCTUnwrap((endFrame["terminal_state_ts_unix_ms"] as? NSNumber)?.int64Value)
        let receiptHeader = try XCTUnwrap(endFrame["receipt"] as? String)
        let pieces = receiptHeader.split(separator: ".")
        XCTAssertEqual(pieces.count, 2)
        let tupleBytes = try XCTUnwrap(Data(base64Encoded: String(pieces[0])))
        let signature = try XCTUnwrap(Data(base64Encoded: String(pieces[1])))
        let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleBytes) as? [String: Any])
        XCTAssertEqual(tuple["receipt_version"] as? String, "4")
        XCTAssertEqual(tuple["terminal_state"] as? String, "buyer_cancel")
        XCTAssertEqual((tuple["terminal_state_ts_unix_ms"] as? NSNumber)?.int64Value, terminalTS)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: tupleBytes))
        // Nothing reached the buyer: the receipt binds the empty prefix and
        // bills nothing, while still reporting observed usage (SPEC-015 §N.7).
        let usage = try XCTUnwrap(tuple["usage"] as? [String: Any])
        XCTAssertEqual((usage["delivered_output_bytes"] as? NSNumber)?.int64Value, 0)
        XCTAssertEqual((usage["billable_input_tokens"] as? NSNumber)?.int64Value, 0)
        XCTAssertEqual((usage["billable_output_tokens"] as? NSNumber)?.int64Value, 0)
        XCTAssertEqual((usage["observed_input_tokens"] as? NSNumber)?.int64Value, 5)
        XCTAssertEqual((usage["observed_output_tokens"] as? NSNumber)?.int64Value, 2)
        XCTAssertEqual(tuple["output_hash"] as? String, try buyerCancelOutputHash(content: "", start: 0))
        XCTAssertTrue(telemetry.records.isEmpty)
    }

    func testRelayStreamingCancelledAfterCompletionCarriesBuyerCancelSettlementReceipt() async throws {
        let telemetry = KVCacheTelemetryCapture()
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let runtime = FakeCancelAfterCompletionReceiptRuntime(servedSnapshot: RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "mlx-community/Test-Model",
            modelHash: hash
        ))
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            warmSwapEnabled: true,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            receiptBuilder: ReceiptBuilder(keyStore: FixedRelayReceiptKeyStore(key: key)),
            receiptProviderID: "provider-relay-test",
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        try await KVCacheTelemetry.withSink({ telemetry.append($0) }) {
            async let requestTask: Void = relay.handleInferenceRequest([
                "type": "inference_request",
                "request_id": "req-relay-v04",
                "stream": true,
                "body": #"{"model":"mlx-community/Test-Model","stream":true,"messages":[{"role":"user","content":"hello"}]}"#,
                "settlement": settlementMetadataWire(
                    keyID: receiptKeyID(key.publicKey.rawRepresentation),
                    modelHash: hash
                ),
            ])
            try await Task.sleep(nanoseconds: 20_000_000)
            try await relay.handleCancelRequest([
                "type": "cancel_request",
                "request_id": "req-relay-v04",
            ])
            try await requestTask
        }

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        let endFrame = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(endFrame["status"] as? String, "cancelled")
        let terminalTS = try XCTUnwrap((endFrame["terminal_state_ts_unix_ms"] as? NSNumber)?.int64Value)
        let receiptHeader = try XCTUnwrap(endFrame["receipt"] as? String)
        let pieces = receiptHeader.split(separator: ".")
        XCTAssertEqual(pieces.count, 2)
        let tupleBytes = try XCTUnwrap(Data(base64Encoded: String(pieces[0])))
        let signature = try XCTUnwrap(Data(base64Encoded: String(pieces[1])))
        let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleBytes) as? [String: Any])
        XCTAssertEqual(tuple["receipt_version"] as? String, "4")
        XCTAssertEqual(tuple["terminal_state"] as? String, "buyer_cancel")
        XCTAssertEqual((tuple["terminal_state_ts_unix_ms"] as? NSNumber)?.int64Value, terminalTS)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: tupleBytes))
        // The buyer received "answer" and no finish chunk: the receipt binds
        // that delivered prefix with a null finish reason (SPEC-015 §N.5).
        let usage = try XCTUnwrap(tuple["usage"] as? [String: Any])
        XCTAssertEqual((usage["delivered_output_bytes"] as? NSNumber)?.int64Value, 6)
        XCTAssertEqual((usage["billable_input_tokens"] as? NSNumber)?.int64Value, 5)
        XCTAssertEqual((usage["billable_output_tokens"] as? NSNumber)?.int64Value, 2)
        XCTAssertEqual(tuple["output_hash"] as? String, try buyerCancelOutputHash(content: "answer", start: 0))
        XCTAssertTrue(telemetry.records.isEmpty)
    }

    func testRelayRejectsSettlementMetadataForDifferentRequest() async throws {
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let runtime = FakeReceiptCompletionRuntime(servedSnapshot: RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "mlx-community/Test-Model",
            modelHash: hash
        ))
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            warmSwapEnabled: true,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            receiptBuilder: ReceiptBuilder(keyStore: FixedRelayReceiptKeyStore(key: key)),
            receiptProviderID: "provider-relay-test",
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )
        var metadata = settlementMetadataWire(
            keyID: receiptKeyID(key.publicKey.rawRepresentation),
            modelHash: hash
        )
        metadata["request_id"] = "req-other"

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-relay-v04",
            "stream": false,
            "body": #"{"model":"mlx-community/Test-Model","messages":[{"role":"user","content":"hello"}]}"#,
            "settlement": metadata,
        ])

        let frames = await recorder.frames
        let nak = try XCTUnwrap(frames.first { $0["type"] as? String == "nak" })
        let error = try XCTUnwrap(nak["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_settlement_metadata")
    }

    func testTier2SessionRejectsPlaintextInferenceRequest() async throws {
        let runtime = FakeCompletionRuntime()
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let session = try testTier2Session()
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            tier2Session: session,
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-plaintext",
            "stream": false,
            "body": #"{"model":"mlx-community/Test-Model","messages":[{"role":"user","content":"hello"}]}"#,
        ])

        let frames = await recorder.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["type"] as? String, "nak")
        XCTAssertEqual(frames[0]["in_reply_to"] as? String, "req-plaintext")
        let error = try XCTUnwrap(frames[0]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "tier2_encrypted_frame_required")
    }

    func testRelayStreamingPreflightRejectsBeforeOpeningChunk() async throws {
        let runtime = FakePreflightRejectRuntime()
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-paged-preflight",
            "stream": true,
            "body": #"{"model":"mlx-community/Test-Model","stream":true,"messages":[{"role":"user","content":"hello"}]}"#,
        ])

        let frames = try await waitForFrames { frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        } from: {
            await recorder.frames
        }
        XCTAssertFalse(frames.contains { $0["type"] as? String == "inference_response_chunk" })
        let end = try XCTUnwrap(frames.first { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(end["request_id"] as? String, "req-paged-preflight")
        XCTAssertEqual(end["status"] as? String, "error_internal")
        let errorMessage = try XCTUnwrap(end["error"] as? String)
        XCTAssertFalse(errorMessage.localizedCaseInsensitiveContains("paged"))
        XCTAssertFalse(errorMessage.localizedCaseInsensitiveContains("kv"))
        XCTAssertEqual(end["chunks_sent"] as? Int, 0)
    }

    // Issue #1695: loopback and fixture runtimes never sign a relay receipt,
    // on complete and stream, even with a receipt key, a provider id and v0.4
    // settlement metadata that match the request.
    func testNonSettlementEligibleRuntimesNeverSignRelayReceipts() async throws {
        let loopback = try ReceiptEligibilityFixtures.makeOllamaLoopbackRuntime(testCase: self)
        let cases: [(label: String, runtime: any ModelRuntimeServing, model: String, hash: String)] = [
            ("ollama_loopback", loopback.runtime, ReceiptEligibilityFixtures.ollamaServedRef, loopback.digest),
            ("relay_blind_fixture", ReceiptEligibilityFixtures.makeRelayBlindFixtureRuntime(),
             ReceiptEligibilityFixtures.fixtureModel, String(repeating: "a", count: 64)),
        ]
        for testCase in cases {
            XCTAssertFalse(testCase.runtime.isSettlementReceiptEligible, testCase.label)
            for stream in [false, true] {
                let result = try await relayReceiptRoundTrip(
                    runtime: testCase.runtime,
                    model: testCase.model,
                    expectedModelHash: testCase.hash,
                    requestID: "req-\(testCase.label)-\(stream ? "stream" : "complete")",
                    stream: stream
                )
                let context = "\(testCase.label) stream=\(stream)"
                XCTAssertEqual(result.endFrame["status"] as? String, "complete", context)
                XCTAssertNil(result.endFrame["receipt"], "non-eligible runtime MUST NOT sign a receipt: \(context)")
                XCTAssertEqual(result.omittedReasons, ["runtime_not_settlement_eligible"], context)
            }
        }
    }

    // Issue #1695 regression: native MLX serving still signs relay settlement
    // receipts on complete and stream; eligibility is not gated on admission.
    func testNativeModelRuntimeStillSignsRelaySettlementReceipts() async throws {
        let model = "mlx-community/Test-Model"
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let runtime = ModelRuntime(
            modelID: model,
            modelHash: hash,
            warmSwapEnabled: true,
            loader: { _ in throw CancellationError() },
            testCompletion: { _, _ in
                CompletionResult(
                    content: "answer",
                    finishReason: "stop",
                    promptTokens: 5,
                    completionTokens: 2,
                    settlementDisposition: .eligibleOwner
                )
            }
        )
        XCTAssertTrue(runtime.isSettlementReceiptEligible)
        for stream in [false, true] {
            let result = try await relayReceiptRoundTrip(
                runtime: runtime,
                model: model,
                expectedModelHash: hash,
                requestID: "req-native-\(stream ? "stream" : "complete")",
                stream: stream
            )
            XCTAssertEqual(result.endFrame["status"] as? String, "complete", "stream=\(stream)")
            let receipt = try XCTUnwrap(result.endFrame["receipt"] as? String, "stream=\(stream)")
            let tupleBytes = try XCTUnwrap(Data(base64Encoded: String(receipt.split(separator: ".")[0])))
            let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleBytes) as? [String: Any])
            XCTAssertEqual(tuple["receipt_version"] as? String, "4", "stream=\(stream)")
            XCTAssertEqual(tuple["model_hash"] as? String, hash, "stream=\(stream)")
            XCTAssertEqual(result.omittedReasons, [], "stream=\(stream)")
        }
    }

    // Issue #1695: buyer-cancel-after-completion must not sign for a
    // non-eligible runtime either, on non-streaming and streaming relays.
    func testNonSettlementEligibleRuntimeSignsNoRelayBuyerCancelReceipt() async throws {
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let model = "mlx-community/Test-Model"
        for stream in [false, true] {
            let runtime = FakeCancelAfterCompletionReceiptRuntime(
                servedSnapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: model, modelHash: hash),
                settlementEligible: false
            )
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
            let recorder = FrameRecorder()
            let audit = ReceiptEligibilityAuditRecorder()
            let relay = InferenceRelay(
                modelRuntime: runtime,
                providerStatus: ProviderStatus(
                    modelID: model,
                    modelLoaded: true,
                    capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
                ),
                loadedModelID: model,
                warmSwapEnabled: true,
                maxActiveRequests: 1,
                maxBodyBytes: 4096,
                receiptBuilder: ReceiptBuilder(keyStore: FixedRelayReceiptKeyStore(key: key)),
                receiptProviderID: "provider-relay-test",
                sendFrame: { frame in
                    await recorder.append(frame)
                }
            )
            let body = stream
                ? #"{"model":"mlx-community/Test-Model","stream":true,"messages":[{"role":"user","content":"hello"}]}"#
                : #"{"model":"mlx-community/Test-Model","messages":[{"role":"user","content":"hello"}]}"#
            try await ReceiptAudit.withSink({ record in audit.append(record) }) {
                async let requestTask: Void = relay.handleInferenceRequest([
                    "type": "inference_request",
                    "request_id": "req-relay-v04",
                    "stream": stream,
                    "body": body,
                    "settlement": settlementMetadataWire(
                        keyID: receiptKeyID(key.publicKey.rawRepresentation),
                        modelHash: hash
                    ),
                ])
                try await Task.sleep(nanoseconds: 20_000_000)
                try await relay.handleCancelRequest([
                    "type": "cancel_request",
                    "request_id": "req-relay-v04",
                ])
                try await requestTask
                _ = try await waitForFrames { frames in
                    frames.contains { $0["type"] as? String == "inference_response_end" }
                } from: {
                    await recorder.frames
                }
            }
            let frames = await recorder.frames
            let endFrame = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
            XCTAssertEqual(endFrame["status"] as? String, "cancelled", "stream=\(stream)")
            XCTAssertNil(endFrame["receipt"], "stream=\(stream)")
            XCTAssertEqual(
                ReceiptEligibilityFixtures.omittedReasons(audit.records),
                ["runtime_not_settlement_eligible"],
                "stream=\(stream)"
            )
        }
    }

    // A relay request that yields no receipt leaves exactly one
    // receipt_omitted row with the same reason the HTTP path uses.
    func testRelayReceiptOmissionReasonsMatchHTTP() async throws {
        let model = "mlx-community/Test-Model"
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let runtime = FakeReceiptCompletionRuntime(servedSnapshot: RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: model,
            modelHash: hash
        ))
        let cases: [(label: String, keyStore: ReceiptKeyStoring?, providerID: String?, reason: String)] = [
            ("receipts_disabled", nil, "provider-relay-test", "pre_v1_6_binary"),
            ("missing_provider_id", RelayEmptyReceiptKeyStore(), nil, "no_keypair"),
            ("missing_current_key", RelayEmptyReceiptKeyStore(), "provider-relay-test", "no_keypair"),
        ]
        for testCase in cases {
            for stream in [false, true] {
                let result = try await relayReceiptRoundTrip(
                    runtime: runtime,
                    model: model,
                    expectedModelHash: hash,
                    requestID: "req-omit-\(testCase.label)-\(stream)",
                    stream: stream,
                    keyStore: testCase.keyStore,
                    providerID: testCase.providerID,
                    attachSettlement: false
                )
                let context = "\(testCase.label) stream=\(stream)"
                XCTAssertEqual(result.endFrame["status"] as? String, "complete", context)
                XCTAssertNil(result.endFrame["receipt"], context)
                XCTAssertEqual(result.omittedReasons, [testCase.reason], context)
            }
        }
    }

    // SPEC-015 §N.12 / AC-12b (#1690 M5): a loopback runtime signs exactly one
    // relay receipt when the request's settlement metadata carries a matching
    // pool_runtime_authorization, and nothing (one runtime_not_settlement_eligible
    // row) when it is absent, malformed, for another runtime, or copied from
    // another request, attempt, provider, or route snapshot.
    func testPoolAuthorizedLoopbackSignsRelayReceiptOnlyForMatchingAuthorization() async throws {
        let loopback = try ReceiptEligibilityFixtures.makeOllamaLoopbackRuntime(testCase: self)
        let model = ReceiptEligibilityFixtures.ollamaServedRef
        let providerID = "provider-relay-test"
        for stream in [false, true] {
            let requestID = "req-pool-\(stream ? "stream" : "complete")"
            func authorization(
                runtimeSource: String = OllamaLoopbackServeModel.runtimeSource,
                requestID authorizedRequestID: String? = nil,
                providerID authorizedProviderID: String? = nil,
                attemptN: Int = 0,
                routeSnapshotDigest: String = String(repeating: "3", count: 64)
            ) -> [String: Any] {
                ReceiptEligibilityFixtures.poolRuntimeAuthorizationWire(
                    runtimeSource: runtimeSource,
                    requestID: authorizedRequestID ?? requestID,
                    providerID: authorizedProviderID ?? providerID,
                    attemptN: attemptN,
                    routeSnapshotDigest: routeSnapshotDigest
                )
            }

            let authorized = try await relayReceiptRoundTrip(
                runtime: loopback.runtime,
                model: model,
                expectedModelHash: loopback.digest,
                requestID: requestID,
                stream: stream,
                providerID: providerID,
                settlementExtras: [PoolRuntimeAuthorization.wireKey: authorization()]
            )
            XCTAssertEqual(authorized.endFrame["status"] as? String, "complete", "stream=\(stream)")
            XCTAssertNotNil(authorized.endFrame["receipt"], "authorized loopback MUST sign: stream=\(stream)")
            XCTAssertEqual(authorized.omittedReasons, [], "stream=\(stream)")

            var malformed = authorization()
            malformed["extra"] = "member"
            let refused: [(label: String, extras: [String: Any])] = [
                ("absent", [:]),
                ("malformed", [PoolRuntimeAuthorization.wireKey: malformed]),
                ("other_runtime_source", [PoolRuntimeAuthorization.wireKey: authorization(runtimeSource: LlamaCppLoopbackServeModel.runtimeSource)]),
                ("other_request", [PoolRuntimeAuthorization.wireKey: authorization(requestID: "req-other")]),
                ("other_attempt", [PoolRuntimeAuthorization.wireKey: authorization(attemptN: 1)]),
                ("other_provider", [PoolRuntimeAuthorization.wireKey: authorization(providerID: "provider-other")]),
                ("other_route_snapshot", [PoolRuntimeAuthorization.wireKey: authorization(routeSnapshotDigest: String(repeating: "5", count: 64))]),
            ]
            for testCase in refused {
                let result = try await relayReceiptRoundTrip(
                    runtime: loopback.runtime,
                    model: model,
                    expectedModelHash: loopback.digest,
                    requestID: requestID,
                    stream: stream,
                    providerID: providerID,
                    settlementExtras: testCase.extras
                )
                let context = "\(testCase.label) stream=\(stream)"
                XCTAssertEqual(result.endFrame["status"] as? String, "complete", context)
                XCTAssertNil(result.endFrame["receipt"], "unauthorized loopback MUST NOT sign: \(context)")
                XCTAssertEqual(result.omittedReasons, ["runtime_not_settlement_eligible"], context)
            }
        }
    }

    /// #1816: a pool-route request naming the signed pool entry
    /// (`pool/<pool_id>/<slug>`, the serve request alias) on a loopback
    /// runtime signs the pool-authorized receipt bound to the entry's artifact
    /// hash, and still signs nothing without a matching authorization.
    func testPoolEntryModelIDOnLoopbackSignsOnlyWithPoolAuthorization() async throws {
        let poolModelID = "pool/AbCdEfGhIjKlMnOpQrStUv/gemma3-270m"
        let alias = PoolModelServe.requestAlias(catalogModelID: nil, poolModelID: poolModelID)
        let loopback = try ReceiptEligibilityFixtures.makeOllamaLoopbackRuntime(testCase: self, catalogModelIDAlias: alias)
        let providerID = "provider-relay-test"
        for stream in [false, true] {
            let requestID = "req-pool-entry-\(stream ? "stream" : "complete")"
            let authorization = ReceiptEligibilityFixtures.poolRuntimeAuthorizationWire(
                runtimeSource: OllamaLoopbackServeModel.runtimeSource,
                requestID: requestID,
                providerID: providerID,
                attemptN: 0,
                routeSnapshotDigest: String(repeating: "3", count: 64)
            )
            let authorized = try await relayReceiptRoundTrip(
                runtime: loopback.runtime,
                model: ReceiptEligibilityFixtures.ollamaServedRef,
                expectedModelHash: loopback.digest,
                requestID: requestID,
                stream: stream,
                providerID: providerID,
                settlementExtras: [PoolRuntimeAuthorization.wireKey: authorization],
                requestModel: poolModelID,
                catalogModelIDAlias: alias
            )
            XCTAssertEqual(authorized.endFrame["status"] as? String, "complete", "stream=\(stream)")
            XCTAssertNotNil(authorized.endFrame["receipt"], "stream=\(stream)")
            XCTAssertEqual(authorized.omittedReasons, [], "stream=\(stream)")

            let unauthorized = try await relayReceiptRoundTrip(
                runtime: loopback.runtime,
                model: ReceiptEligibilityFixtures.ollamaServedRef,
                expectedModelHash: loopback.digest,
                requestID: requestID,
                stream: stream,
                providerID: providerID,
                requestModel: poolModelID,
                catalogModelIDAlias: alias
            )
            XCTAssertNil(unauthorized.endFrame["receipt"], "stream=\(stream)")
            XCTAssertEqual(unauthorized.omittedReasons, ["runtime_not_settlement_eligible"], "stream=\(stream)")
        }
    }

    private func relayReceiptRoundTrip(
        runtime: any ModelRuntimeServing,
        model: String,
        expectedModelHash: String,
        requestID: String,
        stream: Bool,
        keyStore: ReceiptKeyStoring? = FixedRelayReceiptKeyStore(
            key: try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        ),
        providerID: String? = "provider-relay-test",
        attachSettlement: Bool = true,
        settlementExtras: [String: Any] = [:],
        requestModel: String? = nil,
        catalogModelIDAlias: String? = nil
    ) async throws -> (endFrame: [String: Any], omittedReasons: [String]) {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let recorder = FrameRecorder()
        let audit = ReceiptEligibilityAuditRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: ProviderStatus(
                modelID: model,
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
            ),
            loadedModelID: model,
            catalogModelIDAlias: catalogModelIDAlias,
            warmSwapEnabled: true,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            receiptBuilder: keyStore.map { ReceiptBuilder(keyStore: $0) },
            receiptProviderID: providerID,
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )
        let body = try JSONSerialization.data(withJSONObject: [
            "model": requestModel ?? model,
            "stream": stream,
            "messages": [["role": "user", "content": "hello"]],
        ] as [String: Any])
        var frame: [String: Any] = [
            "type": "inference_request",
            "request_id": requestID,
            "stream": stream,
            "body": String(decoding: body, as: UTF8.self),
        ]
        if attachSettlement {
            frame["settlement"] = ReceiptEligibilityFixtures.settlementMetadataWire(
                requestID: requestID,
                providerID: providerID ?? "provider-relay-test",
                modelID: requestModel ?? model,
                receiptKeyID: ReceiptEligibilityFixtures.receiptKeyID(key.publicKey.rawRepresentation),
                expectedModelHash: expectedModelHash
            ).merging(settlementExtras) { _, extra in extra }
        }
        let frames = try await ReceiptAudit.withSink({ record in audit.append(record) }) {
            try await relay.handleInferenceRequest(frame)
            return try await waitForFrames { frames in
                frames.contains { $0["type"] as? String == "inference_response_end" }
            } from: {
                await recorder.frames
            }
        }
        let endFrame = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" }, "\(frames)")
        return (endFrame, ReceiptEligibilityFixtures.omittedReasons(audit.records))
    }
}

/// SPEC-015 §M.2.2 — atomic served-snapshot override so the relay
/// test can pin the runtime's request-start container hash and
/// verify the receipt binds to it.
private actor FakeReceiptCompletionRuntime: ModelRuntimeServing {
    private let servedSnapshot: RuntimeSnapshot

    init(servedSnapshot: RuntimeSnapshot) {
        self.servedSnapshot = servedSnapshot
    }

    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    nonisolated var isSettlementReceiptEligible: Bool { true }
    nonisolated var settlementRuntimeSource: String? { nil }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}

    func currentSnapshot() async -> RuntimeSnapshot {
        servedSnapshot
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        CompletionResult(content: "answer", finishReason: "stop", promptTokens: 5, completionTokens: 2, settlementDisposition: .eligibleOwner)
    }

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        let result = CompletionResult(content: "answer", finishReason: "stop", promptTokens: 5, completionTokens: 2, settlementDisposition: .eligibleOwner)
        return (result, servedSnapshot)
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(snapshot: servedSnapshot, registrationID: 0, drainCancelled: DrainCancelToken())
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws { }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        onChunk(.content("answer"))
        return CompletionResult(content: "answer", finishReason: "stop", promptTokens: 5, completionTokens: 2, settlementDisposition: .eligibleOwner)
    }

    func unregisterInFlight(_ id: Int) { }
}

private actor FakePoolAuthorizedLoopbackToolChatterRuntime: ModelRuntimeServing {
    static let runtimeSource = OllamaLoopbackServeModel.runtimeSource
    static let toolCall = macprovider_cli.ToolCall(
        id: "call_0123456789abcdef0123456789abcdef",
        functionName: "lookup",
        arguments: #"{"query":"weather"}"#
    )

    private let servedSnapshot: RuntimeSnapshot
    private let finalContent: String
    private let emitsHiddenTail: Bool

    init(servedSnapshot: RuntimeSnapshot, finalContent: String = "visible ", emitsHiddenTail: Bool = false) {
        self.servedSnapshot = servedSnapshot
        self.finalContent = finalContent
        self.emitsHiddenTail = emitsHiddenTail
    }

    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    nonisolated var isSettlementReceiptEligible: Bool { false }
    nonisolated var settlementRuntimeSource: String? { Self.runtimeSource }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}

    func currentSnapshot() async -> RuntimeSnapshot {
        servedSnapshot
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        CompletionResult(
            content: finalContent,
            finishReason: "tool_calls",
            promptTokens: 5,
            completionTokens: 3,
            generatedCompletionTokens: 3,
            toolCalls: [Self.toolCall],
            settlementDisposition: .notEligible
        )
    }

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        (try await complete(request, shouldCancel: shouldCancel), servedSnapshot)
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(snapshot: servedSnapshot, registrationID: 0, drainCancelled: DrainCancelToken())
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws { }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        onChunk(.content("visible "))
        onChunk(.toolCallDelta(StreamToolCallDelta(
            index: 0,
            id: Self.toolCall.id,
            type: "function",
            functionName: Self.toolCall.functionName,
            arguments: Self.toolCall.arguments
        )))
        if emitsHiddenTail {
            onChunk(.content("hidden tail"))
        }
        return try await complete(request, shouldCancel: shouldCancel)
    }

    func unregisterInFlight(_ id: Int) { }
}

/// sha256(JCS(settlement_output_v1)) for a buyer_cancel prefix that carried no
/// finish reason and no tool calls.
private func buyerCancelOutputHash(content: String, start: Int) throws -> String {
    let canonical = try RFC8785JCS.canonicalString(.object([
        "content": .string(content),
        "finish_reason": .null,
        "output_prefix_end_byte": .int(start + content.utf8.count),
        "output_prefix_start_byte": .int(start),
        "terminal_state": .string("buyer_cancel"),
        "tool_calls": .null,
    ]))
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func settlementOutputHash(
    content: String,
    toolCalls: [macprovider_cli.ToolCall]?,
    finishReason: String,
    terminalState: String,
    start: Int
) throws -> String {
    let end = start + content.utf8.count
    let canonical = try RFC8785JCS.canonicalString(.object([
        "content": .string(content),
        "finish_reason": finishReason.isEmpty ? .null : .string(finishReason),
        "output_prefix_end_byte": .int(end),
        "output_prefix_start_byte": .int(start),
        "terminal_state": .string(terminalState),
        "tool_calls": settlementToolCallsValue(toolCalls),
    ]))
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func settlementToolCallsValue(_ toolCalls: [macprovider_cli.ToolCall]?) -> RFC8785JCS.Value {
    guard let toolCalls, !toolCalls.isEmpty else {
        return .null
    }
    return .array(toolCalls.map { call in
        .object([
            "id": .string(call.id),
            "type": .string("function"),
            "function": .object([
                "name": .string(call.functionName),
                "arguments": .rawString(call.arguments),
            ]),
        ])
    })
}

final class UnattestedUsageWireTests: XCTestCase {
    private func completion(_ disposition: ContinuousBatchSettlementDisposition) -> CompletionResult {
        CompletionResult(
            content: "answer",
            finishReason: "stop",
            promptTokens: 0,
            completionTokens: 7,
            generatedCompletionTokens: 7,
            settlementDisposition: disposition
        )
    }

    // Independent review HIGH: a loopback completion whose upstream omitted
    // usage carries placeholder counts (promptTokens ?? 0, delta events); the
    // wire must not send them as billing usage.
    func testUnattestedUsageSendsNoBillingTokenCounts() {
        for usage in [InferenceRelay.usage(completion(.usageUnattested)), RouterHandler.usage(completion(.usageUnattested))] {
            for key in ["prompt_tokens", "cached_prompt_tokens", "completion_tokens", "total_tokens"] {
                XCTAssertNil(usage[key], "\(key) sent for unattested usage")
            }
        }
    }

    func testAttestedUsageStillSendsTokenCounts() {
        let usage = InferenceRelay.usage(completion(.notEligible))
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 0)
        XCTAssertEqual(usage["completion_tokens"] as? Int, 7)
    }
}

private actor FakeCancelAfterCompletionReceiptRuntime: ModelRuntimeServing {
    private let servedSnapshot: RuntimeSnapshot
    private let settlementEligible: Bool

    init(servedSnapshot: RuntimeSnapshot, settlementEligible: Bool = true) {
        self.servedSnapshot = servedSnapshot
        self.settlementEligible = settlementEligible
    }

    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    nonisolated var isSettlementReceiptEligible: Bool { settlementEligible }
    nonisolated var settlementRuntimeSource: String? { nil }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}

    func currentSnapshot() async -> RuntimeSnapshot {
        servedSnapshot
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        while !shouldCancel() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return CompletionResult(
            content: "answer",
            finishReason: "stop",
            promptTokens: 5,
            completionTokens: 2,
            settlementDisposition: settlementEligible ? .eligibleOwner : .notEligible
        )
    }

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        let result = try await complete(request, shouldCancel: shouldCancel)
        return (result, servedSnapshot)
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(snapshot: servedSnapshot, registrationID: 0, drainCancelled: DrainCancelToken())
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws { }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        onChunk(.content("answer"))
        return try await complete(request, shouldCancel: shouldCancel)
    }

    func unregisterInFlight(_ id: Int) { }
}

private final class RelayEmptyReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey { Curve25519.Signing.PrivateKey() }
    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? { nil }
    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}
    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}

private final class FixedRelayReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    private let key: Curve25519.Signing.PrivateKey
    init(key: Curve25519.Signing.PrivateKey) { self.key = key }
    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey { key }
    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? { key }
    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}
    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}

private func settlementMetadataWire(keyID: String, modelHash: String) -> [String: Any] {
    [
        "account_scope": "acct_sha256:" + String(repeating: "1", count: 64),
        "request_id": "req-relay-v04",
        "attempt_n": 0,
        "provider_id": "provider-relay-test",
        "provider_receipt_key_id": keyID,
        "model_id": "mlx-community/Test-Model",
        "expected_catalog_model_hash": modelHash,
        "catalog_id": "catalog-a",
        "catalog_body_digest": String(repeating: "2", count: 64),
        "route_snapshot_digest": String(repeating: "3", count: 64),
        "route_snapshot_policy_version": "spec022-prereq-v0",
        "route_snapshot_mode": "observe",
        "prompt_hash": String(repeating: "4", count: 64),
        "output_prefix_start_byte": 0,
        "pending_deadline_seconds": 120,
    ]
}

private func receiptKeyID(_ pubkey: Data) -> String {
    let digest = SHA256.hash(data: pubkey)
    return "ed25519-sha256:" + digest.map { String(format: "%02x", $0) }.joined()
}

private actor FrameRecorder {
    private(set) var frames: [[String: Any]] = []

    func append(_ frame: [String: Any]) {
        frames.append(frame)
    }
}

private final class KVCacheTelemetryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [Data] = []

    var records: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func append(_ record: Data) {
        lock.lock()
        captured.append(record)
        lock.unlock()
    }
}

private actor FakeStreamingRuntime: ModelRuntimeServing {
    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    nonisolated var isSettlementReceiptEligible: Bool { true }
    nonisolated var settlementRuntimeSource: String? { nil }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}
    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        CompletionResult(content: "", finishReason: "stop", promptTokens: 7, completionTokens: 0, settlementDisposition: .eligibleOwner)
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(
            snapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: request.model, modelHash: nil),
            registrationID: 0,
            drainCancelled: DrainCancelToken()
        )
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws { }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        onChunk(.content("one"))
        try await Task.sleep(nanoseconds: 20_000_000)
        onChunk(.content("two"))
        while !shouldCancel() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return CompletionResult(content: "onetwo", finishReason: "stop", promptTokens: 7, completionTokens: 2, settlementDisposition: .eligibleOwner)
    }

    func unregisterInFlight(_ id: Int) { }
}

private actor FakePreflightRejectRuntime: ModelRuntimeServing {
    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    nonisolated var isSettlementReceiptEligible: Bool { true }
    nonisolated var settlementRuntimeSource: String? { nil }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}
    func currentSnapshot() async -> RuntimeSnapshot {
        RuntimeSnapshot(state: .ready, container: nil, modelID: "mlx-community/Test-Model", modelHash: nil)
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        throw APIError(status: 503, message: "Inference engine unavailable", type: "server_error", code: "internal_error")
    }

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        throw APIError(status: 503, message: "Inference engine unavailable", type: "server_error", code: "internal_error")
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(
            snapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: request.model, modelHash: nil),
            registrationID: 0,
            drainCancelled: DrainCancelToken()
        )
    }

    func pagedKVPreflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        throw APIError(status: 503, message: "Inference engine unavailable", type: "server_error", code: "internal_error")
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws { }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        XCTFail("relay must reject before stream starts")
        throw APIError(status: 503, message: "Inference engine unavailable", type: "server_error", code: "internal_error")
    }

    func unregisterInFlight(_ id: Int) { }
}

private actor FakeCompletionRuntime: ModelRuntimeServing {
    private var conversationKeys: [String?] = []

    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    nonisolated var isSettlementReceiptEligible: Bool { true }
    nonisolated var settlementRuntimeSource: String? { nil }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}

    func observedConversationKeys() -> [String?] {
        conversationKeys
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        conversationKeys.append(request.conversationKey)
        return CompletionResult(content: "encrypted answer", finishReason: "stop", promptTokens: 5, completionTokens: 2, settlementDisposition: .eligibleOwner)
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(
            snapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: request.model, modelHash: nil),
            registrationID: 0,
            drainCancelled: DrainCancelToken()
        )
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws { }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        conversationKeys.append(request.conversationKey)
        onChunk(.content("encrypted answer"))
        return CompletionResult(content: "encrypted answer", finishReason: "stop", promptTokens: 5, completionTokens: 2, settlementDisposition: .eligibleOwner)
    }

    func unregisterInFlight(_ id: Int) { }
}

private func testTier2Session() throws -> Tier2ProviderSession {
    let session = try Tier2ProviderSession(
        providerID: "provider-test",
        assignedID: "assigned-test",
        selectedAEAD: Tier2ProviderSession.aeadSuite,
        keyID: "kid-test",
        c2pKey: Data(repeating: 0x11, count: 32),
        p2cKey: Data(repeating: 0x22, count: 32),
        c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
        p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
    )
    session.enableResponseChunkPlaintextEnvelope()
    return session
}

private func waitUntil(
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

private func waitForFrames(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    _ predicate: ([[String: Any]]) -> Bool,
    from read: () async -> [[String: Any]]
) async throws -> [[String: Any]] {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        let frames = await read()
        if predicate(frames) {
            return frames
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for frames")
    return await read()
}

// #1690 final audit R1 CODE-6: the streaming chunk callback is @Sendable and
// may run concurrently; batching state and frame order stay consistent.
final class RelayStreamBatcherConcurrencyTests: XCTestCase {
    private final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [String] = []
        func append(_ frame: String) -> Bool {
            lock.lock()
            frames.append(frame)
            lock.unlock()
            return true
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return frames
        }
    }

    func testConcurrentContentDeliveryKeepsEveryTokenExactlyOnce() {
        let sink = FrameSink()
        let batcher = RelayStreamBatcher(
            streamInterval: 7,
            deltaFrame: { delta in (delta["content"] as? String) ?? "" },
            enqueueFrame: { sink.append($0) }
        )
        let tokens = 2_000
        DispatchQueue.concurrentPerform(iterations: tokens) { _ in
            batcher.accept(.content("x"))
        }
        batcher.flushContent()
        let frames = sink.all
        XCTAssertEqual(frames.joined().count, tokens, "every token lands in exactly one frame")
        XCTAssertTrue(frames.dropLast().allSatisfy { $0.count == 7 }, "full batches are never torn")
        XCTAssertTrue(batcher.everyFrameDelivered(sent: frames.count))
        XCTAssertFalse(batcher.everyFrameDelivered(sent: frames.count - 1))
    }

    func testDeliveredContentIsTheSentContentOnly() {
        let sink = FrameSink()
        let batcher = RelayStreamBatcher(
            streamInterval: 2,
            deltaFrame: { delta in (delta["content"] as? String) ?? "" },
            enqueueFrame: { sink.append($0) }
        )
        batcher.accept(.content("ab"))
        batcher.accept(.content("cd"))
        batcher.accept(.content("e"))
        XCTAssertEqual(batcher.deliveredContent(sent: sink.all.count), "abcd", "unflushed content was never sent")
        XCTAssertNil(batcher.deliveredContent(sent: sink.all.count - 1))
        batcher.flushContent()
        XCTAssertEqual(batcher.deliveredContent(sent: sink.all.count), "abcde")
    }

    func testCompletedOutputProofRequiresByteExactContent() {
        let sink = FrameSink()
        let batcher = RelayStreamBatcher(
            streamInterval: 1,
            deltaFrame: { delta in (delta["content"] as? String) ?? "" },
            enqueueFrame: { sink.append($0) }
        )
        batcher.accept(.content("\u{00E9}"))
        let decomposed = CompletionResult(
            content: "e\u{0301}",
            finishReason: "stop",
            promptTokens: 1,
            completionTokens: 1,
            settlementDisposition: .eligibleOwner
        )

        XCTAssertEqual("\u{00E9}", "e\u{0301}")
        XCTAssertFalse("\u{00E9}".utf8.elementsEqual("e\u{0301}".utf8))
        XCTAssertNil(batcher.deliveredCompleteOutput(sent: sink.all.count, completion: decomposed))
    }

    func testDeliveredContentIsNilOnceAToolCallOpened() {
        let sink = FrameSink()
        let batcher = RelayStreamBatcher(
            streamInterval: 1,
            deltaFrame: { _ in "f" },
            enqueueFrame: { sink.append($0) }
        )
        batcher.accept(.content("a"))
        batcher.accept(.toolCallDelta(StreamToolCallDelta(index: 0, id: "call_1", type: "function", functionName: "f", arguments: "{")))
        XCTAssertNil(batcher.deliveredContent(sent: sink.all.count))
    }

    func testDroppedFrameIsNeverReportedDelivered() {
        let batcher = RelayStreamBatcher(streamInterval: 1, deltaFrame: { _ in "f" }, enqueueFrame: { _ in false })
        batcher.accept(.content("x"))
        XCTAssertFalse(batcher.everyFrameDelivered(sent: 0))
    }
}

// #1690 BUG-2: the coordinator's cancel_request names the delivered prefix.
// Chunks the provider sent after the coordinator retired the request never
// reached the buyer, so the receipt binds the named prefix, not everything
// sent, and its token count from the per-chunk accounting.
final class RelayCancelDeliveredBoundaryTests: XCTestCase {
    private static let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"

    private func cancelledEndFrame(deliveredOutputBytes: Any?) async throws -> (end: [String: Any], key: Curve25519.Signing.PrivateKey) {
        let runtime = FakeBoundaryCancelRuntime(servedSnapshot: RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "mlx-community/Test-Model",
            modelHash: Self.hash
        ))
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let recorder = FrameRecorder()
        let relay = InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            warmSwapEnabled: true,
            maxActiveRequests: 1,
            maxBodyBytes: 4096,
            receiptBuilder: ReceiptBuilder(keyStore: FixedRelayReceiptKeyStore(key: key)),
            receiptProviderID: "provider-relay-test",
            sendFrame: { frame in
                await recorder.append(frame)
            }
        )
        async let requestTask: Void = relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-relay-v04",
            "stream": true,
            "body": #"{"model":"mlx-community/Test-Model","stream":true,"messages":[{"role":"user","content":"hello"}]}"#,
            "settlement": settlementMetadataWire(
                keyID: receiptKeyID(key.publicKey.rawRepresentation),
                modelHash: Self.hash
            ),
        ])
        // Every content frame is sent before the cancel arrives.
        _ = try await waitForFrames({ frames in
            frames.filter { $0["type"] as? String == "inference_response_chunk" }.count >= 5
        }, from: { await recorder.frames })
        var cancel: [String: Any] = ["type": "cancel_request", "request_id": "req-relay-v04", "reason": "buyer_disconnected"]
        cancel["delivered_output_bytes"] = deliveredOutputBytes
        try await relay.handleCancelRequest(cancel)
        try await requestTask
        let frames = try await waitForFrames({ frames in
            frames.contains { $0["type"] as? String == "inference_response_end" }
        }, from: { await recorder.frames })
        let end = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(end["status"] as? String, "cancelled")
        return (end, key)
    }

    private func signedTuple(_ end: [String: Any], key: Curve25519.Signing.PrivateKey) throws -> [String: Any] {
        let pieces = try XCTUnwrap(end["receipt"] as? String).split(separator: ".")
        XCTAssertEqual(pieces.count, 2)
        let tupleBytes = try XCTUnwrap(Data(base64Encoded: String(pieces[0])))
        let signature = try XCTUnwrap(Data(base64Encoded: String(pieces[1])))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: tupleBytes))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: tupleBytes) as? [String: Any])
    }

    func testBoundaryBelowSentBindsThatPrefixAndItsTokenCount() async throws {
        let (end, key) = try await cancelledEndFrame(deliveredOutputBytes: 9)
        let tuple = try signedTuple(end, key: key)
        XCTAssertEqual(tuple["terminal_state"] as? String, "buyer_cancel")
        let usage = try XCTUnwrap(tuple["usage"] as? [String: Any])
        XCTAssertEqual((usage["delivered_output_bytes"] as? NSNumber)?.int64Value, 9)
        XCTAssertEqual((usage["billable_output_tokens"] as? NSNumber)?.int64Value, 2)
        XCTAssertEqual(tuple["output_hash"] as? String, try buyerCancelOutputHash(content: "Once upon", start: 0))
        let relayed = try XCTUnwrap(end["usage"] as? [String: Any])
        XCTAssertEqual(relayed["completion_tokens"] as? Int, 2)
    }

    func testBoundaryOffAFrameBoundarySignsNoReceipt() async throws {
        let (end, _) = try await cancelledEndFrame(deliveredOutputBytes: 7)
        XCTAssertNil(end["receipt"], "a boundary inside a frame cannot be bound: fail closed")
    }

    func testBoundaryPastTheSentContentSignsNoReceipt() async throws {
        let (end, _) = try await cancelledEndFrame(deliveredOutputBytes: 64)
        XCTAssertNil(end["receipt"])
    }

    func testZeroBoundaryBindsTheEmptyPrefix() async throws {
        let (end, key) = try await cancelledEndFrame(deliveredOutputBytes: 0)
        let tuple = try signedTuple(end, key: key)
        let usage = try XCTUnwrap(tuple["usage"] as? [String: Any])
        XCTAssertEqual((usage["delivered_output_bytes"] as? NSNumber)?.int64Value, 0)
        XCTAssertEqual(tuple["output_hash"] as? String, try buyerCancelOutputHash(content: "", start: 0))
    }

    func testNoBoundaryKeepsSigningEverythingSent() async throws {
        for missing in [nil, "9" as Any, -1 as Any] {
            let (end, key) = try await cancelledEndFrame(deliveredOutputBytes: missing)
            let tuple = try signedTuple(end, key: key)
            let usage = try XCTUnwrap(tuple["usage"] as? [String: Any])
            XCTAssertEqual((usage["delivered_output_bytes"] as? NSNumber)?.int64Value, 16)
            XCTAssertEqual((usage["billable_output_tokens"] as? NSNumber)?.int64Value, 4)
            XCTAssertEqual(tuple["output_hash"] as? String, try buyerCancelOutputHash(content: "Once upon a time", start: 0))
        }
    }

    func testBatcherBoundaryMatchesCanonicalBytesOfSentFramesOnly() {
        var frames: [String] = []
        let batcher = RelayStreamBatcher(
            streamInterval: 1,
            deltaFrame: { delta in (delta["content"] as? String) ?? "" },
            enqueueFrame: { frames.append($0); return true }
        )
        batcher.accept(.content("a\r\n"))
        batcher.accept(.content("e\u{0301}"))
        batcher.accept(.content("z"))
        // Canonical bytes: "a\n" = 2, then "é" (NFC) = 2 more, then 1.
        XCTAssertEqual(batcher.deliveredContent(sent: 3, deliveredOutputBytes: 4), "a\r\ne\u{0301}")
        XCTAssertEqual(batcher.deliveredContent(sent: 3, deliveredOutputBytes: 2), "a\r\n")
        XCTAssertNil(batcher.deliveredContent(sent: 3, deliveredOutputBytes: 3), "inside a frame")
        XCTAssertNil(batcher.deliveredContent(sent: 2, deliveredOutputBytes: 5), "the frame was never sent")
        XCTAssertEqual(batcher.deliveredContent(sent: 3, deliveredOutputBytes: 5), "a\r\ne\u{0301}z")
        XCTAssertEqual(batcher.deliveredContent(sent: 0, deliveredOutputBytes: 0), "")
        XCTAssertEqual(batcher.deliveredContent(sent: 3, deliveredOutputBytes: nil), batcher.deliveredContent(sent: 3))
    }
}

/// Streams "Once upon a time" in four upstream chunks with an attested
/// per-chunk completion count, then waits for the cancel.
private actor FakeBoundaryCancelRuntime: ModelRuntimeServing {
    private let servedSnapshot: RuntimeSnapshot

    init(servedSnapshot: RuntimeSnapshot) {
        self.servedSnapshot = servedSnapshot
    }

    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    nonisolated var isSettlementReceiptEligible: Bool { true }
    nonisolated var settlementRuntimeSource: String? { nil }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}

    func currentSnapshot() async -> RuntimeSnapshot {
        servedSnapshot
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        while !shouldCancel() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return CompletionResult(
            content: "Once upon a time",
            finishReason: "stop",
            promptTokens: 5,
            completionTokens: 4,
            settlementDisposition: .eligibleOwner,
            loopbackPrefixCompletionTokens: [0: 0, 4: 1, 9: 2, 11: 3, 16: 4]
        )
    }

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        let result = try await complete(request, shouldCancel: shouldCancel)
        return (result, servedSnapshot)
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(snapshot: servedSnapshot, registrationID: 0, drainCancelled: DrainCancelToken())
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws { }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        for piece in ["Once", " upon", " a", " time"] {
            onChunk(.content(piece))
        }
        return try await complete(request, shouldCancel: shouldCancel)
    }

    func unregisterInFlight(_ id: Int) { }
}
