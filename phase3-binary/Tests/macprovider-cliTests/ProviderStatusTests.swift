import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderStatusTests: XCTestCase {
    private func makeCapacity(maxConcurrency: Int = 4) -> ProviderCapacity {
        ProviderCapacity(maxContextOverride: 50_000, maxConcurrencyOverride: maxConcurrency)
    }

    func testSlotsFreeReportsZeroWhenThermallyThrottled() async {
        for state: ProcessInfo.ThermalState in [.serious, .critical] {
            let gate = ThermalGate(stateProvider: FixedThermalProvider(state: state))
            let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)
            let snap = await status.snapshot()
            XCTAssertEqual(snap.slotsFree, 0, "throttled state=\(state.label) must report slots_free=0")
            XCTAssertEqual(snap.status, .busy, "throttled state=\(state.label) must report status=busy")
            XCTAssertEqual(snap.slotsTotal, 4, "slots_total is hardware capacity, must stay constant")
            XCTAssertTrue(snap.thermallyThrottled)
        }
    }

    func testSlotsFreeUnthrottledReturnsAvailableCapacity() async {
        for state: ProcessInfo.ThermalState in [.nominal, .fair] {
            let gate = ThermalGate(stateProvider: FixedThermalProvider(state: state))
            let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)
            let snap = await status.snapshot()
            XCTAssertEqual(snap.slotsFree, 4, "unthrottled state=\(state.label) must report full capacity")
            XCTAssertEqual(snap.status, .ready, "unthrottled state=\(state.label) must report status=ready")
            XCTAssertFalse(snap.thermallyThrottled)
        }
    }

    func testTransitionFromNominalToSeriousDropsSlotsToZero() async {
        let gate = ThermalGate(stateProvider: FixedThermalProvider(state: .nominal))
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)

        let before = await status.snapshot()
        XCTAssertEqual(before.slotsFree, 4)
        XCTAssertFalse(before.thermallyThrottled)

        await gate.inject(state: .serious)
        let throttled = await status.snapshot()
        XCTAssertEqual(throttled.slotsFree, 0)
        XCTAssertEqual(throttled.status, .busy)
        XCTAssertTrue(throttled.thermallyThrottled)

        await gate.inject(state: .fair)
        let restored = await status.snapshot()
        XCTAssertEqual(restored.slotsFree, 4)
        XCTAssertEqual(restored.status, .ready)
        XCTAssertFalse(restored.thermallyThrottled)
    }

    func testThrottleDoesNotDrainInFlightRequests() async {
        let gate = ThermalGate(stateProvider: FixedThermalProvider(state: .nominal))
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)

        _ = await status.beginRequest(requestID: "r-1")
        _ = await status.beginRequest(requestID: "r-2")
        let inflightBefore = await status.snapshot()
        XCTAssertEqual(inflightBefore.requestsInFlight, 2)
        XCTAssertEqual(inflightBefore.slotsFree, 2)

        await gate.inject(state: .serious)
        let throttled = await status.snapshot()
        XCTAssertEqual(throttled.requestsInFlight, 2, "in-flight requests are NOT cancelled by throttle")
        XCTAssertEqual(throttled.slotsFree, 0, "but future admissions are gated")
    }

    func testTransitionLoggerFiresOnEdgeOnly() async {
        let gate = ThermalGate(stateProvider: FixedThermalProvider(state: .nominal))
        let recorder = TransitionRecorder()
        await gate.setTransitionLogger { old, new in recorder.record(old: old, new: new) }

        await gate.inject(state: .nominal)
        XCTAssertEqual(recorder.count, 0, "no-op transition must not log")

        await gate.inject(state: .serious)
        await gate.inject(state: .critical)
        await gate.inject(state: .fair)
        XCTAssertEqual(recorder.transitions.map { "\($0.0.label)->\($0.1.label)" },
                       ["nominal->serious", "serious->critical", "critical->fair"])
    }

    func testSnapshotResetWindowReadsAllFieldsInOneActorTurn() async {
        // Regression: thermal-gate `await` must happen BEFORE reading window
        // metrics, otherwise a `finishRequest` running during the suspension
        // races against the read-then-reset of `windowRequests`/etc.
        let gate = ThermalGate(stateProvider: FixedThermalProvider(state: .nominal))
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)

        let start = await status.beginRequest(requestID: "r-1")
        await status.finishRequest(startedAt: start, completion: nil, failed: false, requestID: "r-1")

        let snap = await status.snapshot(resetWindow: true)
        XCTAssertEqual(snap.requestsServedSinceLast, 1, "the served-since-last counter must include the completed request")

        let after = await status.snapshot(resetWindow: false)
        XCTAssertEqual(after.requestsServedSinceLast, 0, "window must reset cleanly after the previous snapshot")
    }

    func testShouldThrottleThreshold() {
        XCTAssertFalse(ThermalGate.shouldThrottle(.nominal))
        XCTAssertFalse(ThermalGate.shouldThrottle(.fair))
        XCTAssertTrue(ThermalGate.shouldThrottle(.serious))
        XCTAssertTrue(ThermalGate.shouldThrottle(.critical))
    }
}

private struct FixedThermalProvider: ThermalStateProviding {
    let state: ProcessInfo.ThermalState
    func currentThermalState() -> ProcessInfo.ThermalState { state }
}

private final class TransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(ProcessInfo.ThermalState, ProcessInfo.ThermalState)] = []

    func record(old: ProcessInfo.ThermalState, new: ProcessInfo.ThermalState) {
        lock.lock(); defer { lock.unlock() }
        entries.append((old, new))
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var transitions: [(ProcessInfo.ThermalState, ProcessInfo.ThermalState)] {
        lock.lock(); defer { lock.unlock() }; return entries
    }
}
