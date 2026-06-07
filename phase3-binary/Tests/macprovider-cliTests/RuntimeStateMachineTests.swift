import XCTest
@testable import macprovider_cli

final class RuntimeStateMachineTests: XCTestCase {
    func testInitialStateIsReady() async {
        let runtime = makeRuntime(modelID: "ready-model", warmSwapEnabled: true)

        let snapshot = await runtime.currentSnapshot()

        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.modelID, "ready-model")
    }

    func testBeginSwapTransitionsToLoading() async throws {
        let gate = RuntimeStateGate()
        let runtime = makeRuntime(modelID: "old-model", warmSwapEnabled: true) { target in
            await gate.markLoaderStarted()
            try await gate.waitUntilReleased()
            return (target, "hash")
        }

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        try await waitUntil { await gate.loaderStarted }

        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.state, .loading)
        XCTAssertEqual(snapshot.modelID, "old-model")

        await gate.release()
        try await task.value
    }

    func testBeginSwapRejectsWhenLoading() async throws {
        let gate = RuntimeStateGate()
        let runtime = makeRuntime(modelID: "old-model", warmSwapEnabled: true) { target in
            await gate.markLoaderStarted()
            try await gate.waitUntilReleased()
            return (target, "hash")
        }

        let task = try await runtime.beginSwap(targetModelID: "first")
        try await waitUntil { await gate.loaderStarted }

        do {
            _ = try await runtime.beginSwap(targetModelID: "second")
            XCTFail("Expected notReady")
        } catch let error as RuntimeStateMachineError {
            XCTAssertEqual(error, .notReady(current: .loading))
        }

        await gate.release()
        try await task.value
    }

    func testLoadFinishedAndCompletedSignals() async throws {
        let runtime = makeRuntime(modelID: "old-model", warmSwapEnabled: true) { target in
            (target, "hash")
        }
        var signals = await runtime.swapSignals().makeAsyncIterator()

        let task = try await runtime.beginSwap(targetModelID: "target")
        let first = await signals.next()
        let second = await signals.next()
        try await task.value

        XCTAssertEqual(first?.targetModelID, "target")
        guard case .loadFinished = first?.outcome else {
            XCTFail("Expected loadFinished signal")
            return
        }
        guard case let .completed(newModelID, newModelHash) = second?.outcome else {
            XCTFail("Expected completed signal")
            return
        }
        XCTAssertEqual(newModelID, "target")
        XCTAssertEqual(newModelHash, "hash")
    }

    func testFailSwapTransitionsToReadyAndSignalsFailure() async throws {
        let runtime = makeRuntime(modelID: "old-model", modelHash: "old-hash", warmSwapEnabled: true) { _ in
            throw RuntimeStateTestError.loadFailed
        }
        var signals = await runtime.swapSignals().makeAsyncIterator()

        let task = try await runtime.beginSwap(targetModelID: "target")
        try await task.value

        let snapshot = await runtime.currentSnapshot()
        let signal = await signals.next()
        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.modelID, "old-model")
        XCTAssertEqual(snapshot.modelHash, "old-hash")
        guard case let .failed(reason) = signal?.outcome, reason.contains("loadFailed") else {
            XCTFail("Expected failed signal")
            return
        }
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
            loader: { _ in throw RuntimeStateTestError.unexpectedContainerLoader },
            testLoader: loader
        )
    }
}

private actor RuntimeStateGate {
    private var started = false
    private var released = false

    var loaderStarted: Bool { started }

    func markLoaderStarted() {
        started = true
    }

    func release() {
        released = true
    }

    func waitUntilReleased() async throws {
        while !released {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private enum RuntimeStateTestError: Error {
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
