import CryptoKit
import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class InferenceRelayTests: XCTestCase {
    func testCancelActiveStreamingRequestReportsUsage() async throws {
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

        let frames = try await waitForFrames { frames in
            frames.contains {
                $0["type"] as? String == "inference_response_end" &&
                    $0["status"] as? String == "cancelled"
            }
        } from: {
            await recorder.frames
        }
        let end = try XCTUnwrap(frames.last { $0["type"] as? String == "inference_response_end" })
        XCTAssertEqual(end["request_id"] as? String, "req-cancel-usage")
        XCTAssertEqual(end["status"] as? String, "cancelled")
        XCTAssertEqual(end["chunks_sent"] as? Int, 2)
        let usage = try XCTUnwrap(end["usage"] as? [String: Any])
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 7)
        XCTAssertEqual(usage["completion_tokens"] as? Int, 2)
        XCTAssertEqual(usage["total_tokens"] as? Int, 9)
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

        let frames = await recorder.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["type"] as? String, "inference_response_end")
        XCTAssertEqual(frames[0]["request_id"] as? String, "req-missing")
        XCTAssertEqual(frames[0]["status"] as? String, "cancelled")
        XCTAssertEqual(frames[0]["chunks_sent"] as? Int, 0)
        let usage = try XCTUnwrap(frames[0]["usage"] as? [String: Any])
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 0)
        XCTAssertEqual(usage["completion_tokens"] as? Int, 0)
        XCTAssertEqual(usage["total_tokens"] as? Int, 0)
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

        let frames = await recorder.frames
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
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> CompletionResult {
        CompletionResult(content: "answer", finishReason: "stop", promptTokens: 5, completionTokens: 2)
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

private actor FrameRecorder {
    private(set) var frames: [[String: Any]] = []

    func append(_ frame: [String: Any]) {
        frames.append(frame)
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
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> CompletionResult {
        onChunk("one")
        try await Task.sleep(nanoseconds: 20_000_000)
        onChunk("two")
        while !shouldCancel() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return CompletionResult(content: "onetwo", finishReason: "stop", promptTokens: 7, completionTokens: 2)
    }

    func unregisterInFlight(_ id: Int) { }
}

private actor FakeCompletionRuntime: ModelRuntimeServing {
    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        CompletionResult(content: "encrypted answer", finishReason: "stop", promptTokens: 5, completionTokens: 2)
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
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> CompletionResult {
        onChunk("encrypted answer")
        return CompletionResult(content: "encrypted answer", finishReason: "stop", promptTokens: 5, completionTokens: 2)
    }

    func unregisterInFlight(_ id: Int) { }
}

private func testTier2Session() throws -> Tier2ProviderSession {
    try Tier2ProviderSession(
        providerID: "provider-test",
        assignedID: "assigned-test",
        selectedAEAD: Tier2ProviderSession.aeadSuite,
        keyID: "kid-test",
        c2pKey: Data(repeating: 0x11, count: 32),
        p2cKey: Data(repeating: 0x22, count: 32),
        c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
        p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
    )
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
