import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

// T3-01 token/chunk batching: verify streamInterval reduces WS sendChunk calls
// without losing content. Tests count inference_response_chunk frames to confirm
// the send-reduction math and guard content fidelity.

final class StreamIntervalBatchingTests: XCTestCase {

    // MARK: - Helpers

    private func makeRelay(
        runtime: any ModelRuntimeServing,
        streamInterval: Int,
        recorder: FrameRecorder
    ) -> InferenceRelay {
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        return InferenceRelay(
            modelRuntime: runtime,
            providerStatus: status,
            loadedModelID: "mlx-community/Test-Model",
            maxActiveRequests: 1,
            maxBodyBytes: 65536,
            streamInterval: streamInterval,
            sendFrame: { frame in await recorder.append(frame) }
        )
    }

    private func streamBody() -> String {
        #"{"model":"mlx-community/Test-Model","messages":[{"role":"user","content":"hi"}],"max_tokens":32,"stream":true}"#
    }

    private func contentChunks(from frames: [[String: Any]]) -> [String] {
        frames
            .filter { $0["type"] as? String == "inference_response_chunk" }
            .compactMap { frame -> String? in
                guard let sseData = frame["data"] as? String else { return nil }
                // SSE format: "data: {json}\n\n" — strip the prefix before parsing.
                let jsonString: String
                if sseData.hasPrefix("data: ") {
                    jsonString = String(sseData.dropFirst(6))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    jsonString = sseData.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard let raw = try? JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [String: Any],
                      let choices = raw["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let text = delta["content"] as? String,
                      !text.isEmpty
                else { return nil }
                return text
            }
    }

    // MARK: - interval=1 (baseline: one frame per token)

    func testInterval1EmitsOneFramePerToken() async throws {
        let tokenCount = 8
        let runtime = CountingTokenRuntime(tokens: tokenCount)
        let recorder = FrameRecorder()
        let relay = makeRelay(runtime: runtime, streamInterval: 1, recorder: recorder)

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-si-1",
            "stream": true,
            "body": streamBody(),
        ])

        try await waitForEndFrame(recorder: recorder, requestID: "req-si-1")
        let chunks = contentChunks(from: await recorder.frames)

        // Expect exactly tokenCount content frames (one per token)
        XCTAssertEqual(chunks.count, tokenCount, "interval=1 must emit one frame per token")
        // Verify all content arrived and is in order
        XCTAssertEqual(chunks.joined(), (0..<tokenCount).map { "t\($0)" }.joined())
    }

    // MARK: - interval=4 (75% reduction on 8 tokens → 2 content frames)

    func testInterval4BatchesFourTokensPerFrame() async throws {
        let tokenCount = 8
        let runtime = CountingTokenRuntime(tokens: tokenCount)
        let recorder = FrameRecorder()
        let relay = makeRelay(runtime: runtime, streamInterval: 4, recorder: recorder)

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-si-4",
            "stream": true,
            "body": streamBody(),
        ])

        try await waitForEndFrame(recorder: recorder, requestID: "req-si-4")
        let chunks = contentChunks(from: await recorder.frames)

        // 8 tokens ÷ 4 interval = 2 content frames
        XCTAssertEqual(chunks.count, 2, "interval=4 must batch 8 tokens into 2 frames")
        guard chunks.count == 2 else { return }
        XCTAssertEqual(chunks[0], "t0t1t2t3")
        XCTAssertEqual(chunks[1], "t4t5t6t7")
        // Send-count reduction: 8→2 = 75%
    }

    // MARK: - Remainder flush (tokens not divisible by interval)

    func testInterval4FlushesRemainder() async throws {
        // 10 tokens: 2 full batches of 4 + remainder of 2
        let tokenCount = 10
        let runtime = CountingTokenRuntime(tokens: tokenCount)
        let recorder = FrameRecorder()
        let relay = makeRelay(runtime: runtime, streamInterval: 4, recorder: recorder)

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-si-rem",
            "stream": true,
            "body": streamBody(),
        ])

        try await waitForEndFrame(recorder: recorder, requestID: "req-si-rem")
        let chunks = contentChunks(from: await recorder.frames)

        XCTAssertEqual(chunks.count, 3, "10 tokens ÷ 4 = 2 full + 1 remainder frame")
        guard chunks.count == 3 else { return }
        XCTAssertEqual(chunks[2], "t8t9")
        XCTAssertEqual(chunks.joined(), (0..<tokenCount).map { "t\($0)" }.joined())
    }

    // MARK: - Content fidelity: all text arrives concatenated in order

    func testContentFidelityLargeInterval() async throws {
        let tokenCount = 7
        let runtime = CountingTokenRuntime(tokens: tokenCount)
        let recorder = FrameRecorder()
        let relay = makeRelay(runtime: runtime, streamInterval: 100, recorder: recorder)

        try await relay.handleInferenceRequest([
            "type": "inference_request",
            "request_id": "req-si-big",
            "stream": true,
            "body": streamBody(),
        ])

        try await waitForEndFrame(recorder: recorder, requestID: "req-si-big")
        let chunks = contentChunks(from: await recorder.frames)

        // All tokens flushed at stream end as one frame
        XCTAssertEqual(chunks.count, 1)
        guard chunks.count == 1 else { return }
        XCTAssertEqual(chunks[0], (0..<tokenCount).map { "t\($0)" }.joined())
    }

    // MARK: - Config loader: stream_interval default is 1

    func testStreamIntervalDefaultIsOne() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in false },
            readFile: { _ in "" }
        )
        XCTAssertEqual(config.streamInterval, 1)
    }

    // MARK: - Config loader: CLI overrides env overrides YAML

    func testStreamIntervalYAMLApplied() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "stream_interval: 4\n" }
        )
        XCTAssertEqual(config.streamInterval, 4)
    }

    func testStreamIntervalEnvOverridesYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_STREAM_INTERVAL": "4"],
            fileExists: { _ in true },
            readFile: { _ in "stream_interval: 1\n" }
        )
        XCTAssertEqual(config.streamInterval, 4)
    }

    func testStreamIntervalCLIOverridesEnv() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(streamInterval: 2),
            environment: ["MACPROVIDER_STREAM_INTERVAL": "4"],
            fileExists: { _ in true },
            readFile: { _ in "stream_interval: 8\n" }
        )
        XCTAssertEqual(config.streamInterval, 2)
    }

    // MARK: - Relay stores the configured interval

    func testRelayStoresStreamInterval() {
        let status = ProviderStatus(
            modelID: nil,
            modelLoaded: false,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let relay = InferenceRelay(
            modelRuntime: NullRuntime(),
            providerStatus: status,
            loadedModelID: nil,
            maxActiveRequests: 1,
            maxBodyBytes: 1024,
            streamInterval: 4,
            sendFrame: { _ in }
        )
        XCTAssertEqual(relay.streamInterval, 4)
    }
}

// MARK: - Fake runtime that emits N numbered tokens synchronously

private actor CountingTokenRuntime: ModelRuntimeServing {
    private let tokenCount: Int
    init(tokens: Int) { self.tokenCount = tokens }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        CompletionResult(content: "", finishReason: "stop", promptTokens: 1, completionTokens: tokenCount)
    }

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        let result = try await complete(request, shouldCancel: shouldCancel)
        let snap = RuntimeSnapshot(state: .ready, container: nil, modelID: request.model, modelHash: nil)
        return (result, snap)
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
        for i in 0..<tokenCount {
            onChunk(.content("t\(i)"))
        }
        return CompletionResult(content: (0..<tokenCount).map { "t\($0)" }.joined(),
                                finishReason: "stop", promptTokens: 1, completionTokens: tokenCount)
    }

    func unregisterInFlight(_ id: Int) { }
}

// MARK: - No-op runtime for init tests

private actor NullRuntime: ModelRuntimeServing {
    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult {
        CompletionResult(content: "", finishReason: "stop", promptTokens: 0, completionTokens: 0)
    }
    func completeWithServedSnapshot(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> (CompletionResult, RuntimeSnapshot) {
        let r = try await complete(request, shouldCancel: shouldCancel)
        return (r, RuntimeSnapshot(state: .ready, container: nil, modelID: nil, modelHash: nil))
    }
    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(snapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: nil, modelHash: nil), registrationID: 0, drainCancelled: DrainCancelToken())
    }
    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws { }
    func stream(_ request: ChatCompletionRequest, with handle: RequestHandle, shouldCancel: @escaping @Sendable () -> Bool, onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> CompletionResult {
        CompletionResult(content: "", finishReason: "stop", promptTokens: 0, completionTokens: 0)
    }
    func unregisterInFlight(_ id: Int) { }
}

// MARK: - Wait helper

private func waitForEndFrame(
    recorder: FrameRecorder,
    requestID: String,
    timeoutNanoseconds: UInt64 = 3_000_000_000
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        let frames = await recorder.frames
        if frames.contains(where: {
            $0["type"] as? String == "inference_response_end" &&
            $0["request_id"] as? String == requestID
        }) { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for inference_response_end for \(requestID)")
}

private actor FrameRecorder {
    private(set) var frames: [[String: Any]] = []
    func append(_ frame: [String: Any]) { frames.append(frame) }
}
