import Foundation
import MLXLMCommon
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ModelRuntimeSwapTests: XCTestCase {
    func testDisabledModeRejectsSwap() async throws {
        let runtime = try await ModelRuntime(modelID: nil, warmSwapEnabled: false)

        do {
            _ = try await runtime.beginSwap(targetModelID: "new-model")
            XCTFail("Expected warm-swap disabled error")
        } catch let error as WarmSwapDisabledError {
            XCTAssertEqual(error.description, "warm swap is not enabled (start serve with --enable-warm-swap)")
        }
    }

    func testEnabledModeAcceptsSwap() async throws {
        let runtime = makeRuntime(modelID: nil, warmSwapEnabled: true) { target in
            try await Task.sleep(nanoseconds: 50_000_000)
            return (target, "new-hash")
        }

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        try await task.value
        let snapshot = await runtime.currentSnapshot()

        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.modelID, "new-model")
        XCTAssertEqual(snapshot.modelHash, "new-hash")
    }

    func testInFlightInferenceUsesOldSnapshot() async throws {
        let probe = InFlightProbe()
        let runtime = makeRuntime(modelID: "old-model", modelHash: "old-hash", warmSwapEnabled: true, loader: { target in
            (target, "new-hash")
        }, completion: { snapshot, _ in
            await probe.markStarted(modelID: snapshot.modelID)
            while await !probe.canFinish {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            return CompletionResult(content: snapshot.modelID ?? "<nil>", finishReason: "stop", promptTokens: 1, completionTokens: 1)
        })

        let request = try makeRequest(model: "old-model")
        let completionTask = Task {
            try await runtime.complete(request)
        }
        try await waitUntil {
            await probe.startedModelID != nil
        }

        let swapTask = try await runtime.beginSwap(targetModelID: "new-model")
        try await swapTask.value
        let postSwap = await runtime.currentSnapshot()
        await probe.allowFinish()
        let completion = try await completionTask.value
        let startedModelID = await probe.startedModelID

        XCTAssertEqual(startedModelID, "old-model")
        XCTAssertEqual(postSwap.modelID, "new-model")
        XCTAssertEqual(completion.content, "old-model")
    }

    func testLoadFailureRollsBack() async throws {
        let runtime = makeRuntime(modelID: "old-model", modelHash: "old-hash", warmSwapEnabled: true) { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            throw TestError.loadFailed
        }
        var signals = await runtime.swapSignals().makeAsyncIterator()

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        try await task.value
        let snapshot = await runtime.currentSnapshot()
        let signal = await signals.next()

        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.modelID, "old-model")
        XCTAssertEqual(snapshot.modelHash, "old-hash")
        guard case let .failed(reason) = signal?.outcome else {
            XCTFail("Expected failed signal")
            return
        }
        XCTAssertTrue(reason.contains("loadFailed"))
    }

    func testNoStarveSnapshotRespondsDuringLoad() async throws {
        let runtime = makeRuntime(modelID: "old-model", warmSwapEnabled: true) { target in
            try await Task.sleep(nanoseconds: 100_000_000)
            return (target, "new-hash")
        }

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        for _ in 0 ..< 20 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = await runtime.currentSnapshot()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            XCTAssertLessThan(elapsed, 10_000_000)
        }
        try await task.value
    }

    func testBootPathDoesNotPassThroughLoading() async throws {
        let runtime = try await ModelRuntime(modelID: nil)

        let snapshot = await runtime.currentSnapshot()

        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertNil(snapshot.container)
        XCTAssertNil(snapshot.modelID)
    }

    func testSwapDrainTimeoutSurvivesPlumbing() {
        let runtime = makeRuntime(modelID: nil, warmSwapEnabled: true, swapDrainTimeoutSeconds: 42)

        XCTAssertEqual(runtime.swapDrainTimeoutForTest(), 42)
    }

    func testWarmSwapConfigUsesCLIOverEnvironmentOverYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(enableWarmSwap: false, swapDrainTimeoutSeconds: 44),
            environment: [
                "MACPROVIDER_ENABLE_WARM_SWAP": "true",
                "MACPROVIDER_SWAP_DRAIN_TIMEOUT_S": "33",
            ],
            fileExists: { _ in true },
            readFile: { _ in "enable_warm_swap: false\nswap_drain_timeout_s: 22\n" }
        )

        XCTAssertEqual(config.enableWarmSwap, false)
        XCTAssertEqual(config.swapDrainTimeoutSeconds, 44)
    }

    func testWarmSwapConfigReadsEnvironmentBeforeYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [
                "MACPROVIDER_ENABLE_WARM_SWAP": "true",
                "MACPROVIDER_SWAP_DRAIN_TIMEOUT_S": "33",
            ],
            fileExists: { _ in true },
            readFile: { _ in "enable_warm_swap: false\nswap_drain_timeout_s: 22\n" }
        )

        XCTAssertEqual(config.enableWarmSwap, true)
        XCTAssertEqual(config.swapDrainTimeoutSeconds, 33)
    }

    private func makeRuntime(
        modelID: String?,
        modelHash: String? = nil,
        warmSwapEnabled: Bool,
        swapDrainTimeoutSeconds: Int = 30,
        loader: @escaping @Sendable (String) async throws -> (String, String?) = { target in (target, nil) },
        completion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)? = nil
    ) -> ModelRuntime {
        ModelRuntime(
            modelID: modelID,
            modelHash: modelHash,
            warmSwapEnabled: warmSwapEnabled,
            swapDrainTimeoutSeconds: swapDrainTimeoutSeconds,
            loader: { _ in throw TestError.unexpectedContainerLoader },
            testLoader: loader,
            testCompletion: completion
        )
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

private actor InFlightProbe {
    private var _startedModelID: String?
    private var _canFinish = false

    var startedModelID: String? { _startedModelID }
    var canFinish: Bool { _canFinish }

    func markStarted(modelID: String?) {
        _startedModelID = modelID
    }

    func allowFinish() {
        _canFinish = true
    }
}

private enum TestError: Error {
    case unexpectedContainerLoader
    case loadFailed
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
