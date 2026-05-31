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

    func stream(
        _ request: ChatCompletionRequest,
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
}

private actor FakeCompletionRuntime: ModelRuntimeServing {
    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        CompletionResult(content: "encrypted answer", finishReason: "stop", promptTokens: 5, completionTokens: 2)
    }

    func stream(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> CompletionResult {
        onChunk("encrypted answer")
        return CompletionResult(content: "encrypted answer", finishReason: "stop", promptTokens: 5, completionTokens: 2)
    }
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
