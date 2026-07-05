import Foundation
import MLXLMCommon
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class HTTPServerSwapTests: XCTestCase {
    func testInferenceProceedsWhenReady() async throws {
        let runtime = ModelRuntime(
            modelID: "ready-model",
            warmSwapEnabled: true,
            loader: { _ in throw HTTPServerSwapTestError.unexpectedContainerLoader },
            testLoader: { target in (target, "hash") },
            testCompletion: { _, _ in
                CompletionResult(content: "ready", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )
        let snapshot = await runtime.currentSnapshot()

        XCTAssertEqual(snapshot.state, .ready)
        let completion = try await runtime.complete(try makeRequest(model: "ready-model"))
        XCTAssertEqual(completion.content, "ready")
    }

    func testHTTPReturns503SwapDrainTimeoutEnvelope() throws {
        let data = try JSONSerialization.data(
            withJSONObject: RouterHandler.swapDrainTimeoutEnvelope(),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(json, #"{"error":{"code":"swap_drain_timeout","type":"service_unavailable"}}"#)
    }

    func testInferenceForNewModelSucceedsAfterSwap() async throws {
        let probe = HTTPCompletionProbe()
        let runtime = ModelRuntime(
            modelID: "A",
            modelHash: "hash-a",
            warmSwapEnabled: true,
            loader: { _ in throw HTTPServerSwapTestError.unexpectedContainerLoader },
            testLoader: { target in (target, "hash-b") },
            testCompletion: { snapshot, _ in
                await probe.record(modelID: snapshot.modelID)
                return CompletionResult(content: snapshot.modelID ?? "<nil>", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )

        let swapTask = try await runtime.beginSwap(targetModelID: "B")
        try await swapTask.value
        let snapshot = await runtime.currentSnapshot()
        let request = try makeRequest(model: "B")
        try request.validateModelMatches(RouterHandler.modelIDForValidation(
            warmSwapEnabled: true,
            bootModelID: "A",
            runtimeSnapshot: snapshot
        ))
        let completion = try await runtime.complete(request)
        let reachedModelIDs = await probe.modelIDs

        XCTAssertEqual(completion.content, "B")
        XCTAssertEqual(reachedModelIDs, ["B"])
    }

    func testInferenceForOldModelRejectedAfterSwap() async throws {
        let runtime = ModelRuntime(
            modelID: "A",
            modelHash: "hash-a",
            warmSwapEnabled: true,
            loader: { _ in throw HTTPServerSwapTestError.unexpectedContainerLoader },
            testLoader: { target in (target, "hash-b") }
        )

        let swapTask = try await runtime.beginSwap(targetModelID: "B")
        try await swapTask.value
        let snapshot = await runtime.currentSnapshot()
        let request = try makeRequest(model: "A")

        XCTAssertThrowsError(try request.validateModelMatches(RouterHandler.modelIDForValidation(
            warmSwapEnabled: true,
            bootModelID: "A",
            runtimeSnapshot: snapshot
        ))) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 404)
            XCTAssertEqual(apiError?.code, "model_not_found")
        }
    }

    func testDisabledValidationUsesBootModelWhenRuntimeDiffers() throws {
        let snapshot = RuntimeSnapshot(state: .ready, container: nil, modelID: "B", modelHash: "hash-b")

        let modelID = RouterHandler.modelIDForValidation(
            warmSwapEnabled: false,
            bootModelID: "A",
            runtimeSnapshot: snapshot
        )

        XCTAssertEqual(modelID, "A")
    }

    func testEnabledValidationUsesRuntimeModelWhenBootDiffers() throws {
        let snapshot = RuntimeSnapshot(state: .ready, container: nil, modelID: "B", modelHash: "hash-b")

        let modelID = RouterHandler.modelIDForValidation(
            warmSwapEnabled: true,
            bootModelID: "A",
            runtimeSnapshot: snapshot
        )

        XCTAssertEqual(modelID, "B")
    }

    func testStreamingRequestAdmittedInReadyDoesNotGetProviderLoading() async throws {
        let probe = HTTPCompletionProbe()
        let chunks = LockedStringArray()
        let runtime = ModelRuntime(
            modelID: "old-model",
            modelHash: "old-hash",
            warmSwapEnabled: true,
            loader: { _ in throw HTTPServerSwapTestError.unexpectedContainerLoader },
            testLoader: { target in
                try await Task.sleep(nanoseconds: 150_000_000)
                return (target, "new-hash")
            },
            testCompletion: { snapshot, _ in
                await probe.record(modelID: snapshot.modelID)
                while await !probe.canFinish {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                return CompletionResult(content: snapshot.modelID ?? "<nil>", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )
        let request = try makeRequest(model: "old-model")
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.state, .ready)
        try request.validateModelMatches(RouterHandler.modelIDForValidation(
            warmSwapEnabled: true,
            bootModelID: "old-model",
            runtimeSnapshot: snapshot
        ))

        let handle = try await runtime.acquireRequestHandle(request)
        do {
            try await runtime.preflight(request, with: handle)
            let streamTask = Task {
                try await runtime.stream(request, with: handle) { chunk in
                    if case .content(let text) = chunk {
                        chunks.append(text)
                    }
                }
            }
            try await waitUntil {
                !(await probe.modelIDs.isEmpty)
            }

            let swapTask = try await runtime.beginSwap(targetModelID: "new-model")
            let loadingSnapshot = await runtime.currentSnapshot()
            XCTAssertEqual(loadingSnapshot.state, .loading)
            await probe.allowFinish()
            let completion = try await streamTask.value
            await runtime.unregisterInFlight(handle.registrationID)
            try await swapTask.value
            let reachedModelIDs = await probe.modelIDs

            XCTAssertEqual(completion.content, "old-model")
            XCTAssertEqual(chunks.values, ["old-model"])
            XCTAssertEqual(reachedModelIDs, ["old-model"])
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
    }

    private func makeRequest(model: String) throws -> ChatCompletionRequest {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try ChatCompletionRequest.parse(data: data)
    }
}

private enum HTTPServerSwapTestError: Error {
    case unexpectedContainerLoader
}

private actor HTTPCompletionProbe {
    private(set) var modelIDs: [String?] = []
    private var _canFinish = false

    var canFinish: Bool { _canFinish }

    func record(modelID: String?) {
        modelIDs.append(modelID)
    }

    func allowFinish() {
        _canFinish = true
    }
}

private final class LockedStringArray: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func append(_ value: String) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }
}

private extension APIError {
    var envelopeJSONString: String {
        let data = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
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
