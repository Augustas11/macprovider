import XCTest
@testable import macprovider_cli

final class RuntimeStateMachineTests: XCTestCase {
    func testInitialStateIsReady() async {
        let machine = RuntimeStateMachine()

        let state = await machine.current()

        XCTAssertEqual(state, .ready)
    }

    func testTransitionToLoadingFromReady() async throws {
        let machine = RuntimeStateMachine()

        try await machine.transitionToLoading(target: "mlx-community/Test")

        let state = await machine.current()
        let target = await machine.currentTargetModelID()
        XCTAssertEqual(state, .loading)
        XCTAssertEqual(target, "mlx-community/Test")
    }

    func testTransitionToLoadingFromLoadingRejected() async throws {
        let machine = RuntimeStateMachine()
        try await machine.transitionToLoading(target: "first")

        do {
            try await machine.transitionToLoading(target: "second")
            XCTFail("Expected notReady")
        } catch let error as RuntimeStateMachineError {
            XCTAssertEqual(error, .notReady(current: .loading))
        }
    }

    func testCompleteSwapTransitionsToReady() async throws {
        let machine = RuntimeStateMachine()
        try await machine.transitionToLoading(target: "target")

        await machine.completeSwap(newModelID: "target", newModelHash: "hash")

        let state = await machine.current()
        let target = await machine.currentTargetModelID()
        XCTAssertEqual(state, .ready)
        XCTAssertNil(target)
    }

    func testFailSwapTransitionsToReadyViaFailed() async throws {
        let machine = RuntimeStateMachine()
        var signals = await machine.signalStream().makeAsyncIterator()
        try await machine.transitionToLoading(target: "target")

        await machine.failSwap(reason: "load failed")

        let signal = await signals.next()
        let state = await machine.current()
        XCTAssertEqual(state, .ready)
        guard case let .failed(reason) = signal?.outcome, reason == "load failed" else {
            XCTFail("Expected failed signal")
            return
        }
    }

    func testSignalCompleted() async throws {
        let machine = RuntimeStateMachine()
        var signals = await machine.signalStream().makeAsyncIterator()
        try await machine.transitionToLoading(target: "target")

        await machine.completeSwap(newModelID: "target", newModelHash: "hash")

        let signal = await signals.next()
        XCTAssertEqual(signal?.targetModelID, "target")
        guard case let .completed(newModelID, newModelHash) = signal?.outcome,
              newModelID == "target",
              newModelHash == "hash"
        else {
            XCTFail("Expected completed signal")
            return
        }
    }

    func testSignalFailed() async throws {
        let machine = RuntimeStateMachine()
        var signals = await machine.signalStream().makeAsyncIterator()
        try await machine.transitionToLoading(target: "target")

        await machine.failSwap(reason: "boom")

        let signal = await signals.next()
        XCTAssertEqual(signal?.targetModelID, "target")
        guard case let .failed(reason) = signal?.outcome, reason == "boom" else {
            XCTFail("Expected failed signal")
            return
        }
    }
}
