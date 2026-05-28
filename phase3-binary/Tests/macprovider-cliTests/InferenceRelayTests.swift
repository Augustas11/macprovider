import XCTest
@testable import macprovider_cli

final class InferenceRelayTests: XCTestCase {
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
}

private actor FrameRecorder {
    private(set) var frames: [[String: Any]] = []

    func append(_ frame: [String: Any]) {
        frames.append(frame)
    }
}
