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

    private func makeClient(
        status: ProviderStatus,
        recorder: CoordinatorFrameRecorder,
        drainTimeoutSeconds: Int = 1,
        reconnectGraceNanoseconds: UInt64 = 10 * 1_000_000_000,
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
