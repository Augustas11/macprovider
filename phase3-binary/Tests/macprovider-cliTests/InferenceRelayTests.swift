import CryptoKit
import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class InferenceRelayTests: XCTestCase {
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
}

/// SPEC-015 §M.2.2 — atomic served-snapshot override so the relay
/// test can pin the runtime's request-start container hash and
/// verify the receipt binds to it.
private actor FakeReceiptCompletionRuntime: ModelRuntimeServing {
    private let servedSnapshot: RuntimeSnapshot

    init(servedSnapshot: RuntimeSnapshot) {
        self.servedSnapshot = servedSnapshot
    }

    func currentSnapshot() async -> RuntimeSnapshot {
        servedSnapshot
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        CompletionResult(content: "answer", finishReason: "stop", promptTokens: 5, completionTokens: 2)
    }

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        let result = CompletionResult(content: "answer", finishReason: "stop", promptTokens: 5, completionTokens: 2)
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
        CompletionResult(content: "answer", finishReason: "stop", promptTokens: 5, completionTokens: 2)
    }

    func unregisterInFlight(_ id: Int) { }
}

private actor FakeCancelAfterCompletionReceiptRuntime: ModelRuntimeServing {
    private let servedSnapshot: RuntimeSnapshot

    init(servedSnapshot: RuntimeSnapshot) {
        self.servedSnapshot = servedSnapshot
    }

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
        return CompletionResult(content: "answer", finishReason: "stop", promptTokens: 5, completionTokens: 2)
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
    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        CompletionResult(content: "", finishReason: "stop", promptTokens: 7, completionTokens: 0)
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
        return CompletionResult(content: "onetwo", finishReason: "stop", promptTokens: 7, completionTokens: 2)
    }

    func unregisterInFlight(_ id: Int) { }
}

private actor FakePreflightRejectRuntime: ModelRuntimeServing {
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

    func observedConversationKeys() -> [String?] {
        conversationKeys
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        conversationKeys.append(request.conversationKey)
        return CompletionResult(content: "encrypted answer", finishReason: "stop", promptTokens: 5, completionTokens: 2)
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
        return CompletionResult(content: "encrypted answer", finishReason: "stop", promptTokens: 5, completionTokens: 2)
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
