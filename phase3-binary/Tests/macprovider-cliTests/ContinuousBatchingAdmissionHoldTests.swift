import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-038 FR-CB10 item 3 (v0.3.22): a due self-check that finds no idle
/// window under steady traffic runs under a bounded admission hold.
final class ContinuousBatchingAdmissionHoldTests: XCTestCase {
    private func makeStatus(slots: Int = 4) -> ProviderStatus {
        ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 50_000, maxConcurrencyOverride: slots)
        )
    }

    func testHoldIsDueOnlyAfterTheDeferralBoundAndHoldsAreSpacedApart() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let after = ContinuousBatchingSelfCheck.admissionHoldAfterSeconds
        XCTAssertEqual(after, 120)
        XCTAssertFalse(ContinuousBatchingSelfCheck.admissionHoldDue(
            dueSince: start, notBefore: .distantPast, after: after, now: start.addingTimeInterval(after - 1)
        ))
        XCTAssertTrue(ContinuousBatchingSelfCheck.admissionHoldDue(
            dueSince: start, notBefore: .distantPast, after: after, now: start.addingTimeInterval(after)
        ))
        // A hold that did not finish is retried no sooner than the bound later.
        let lastHold = start.addingTimeInterval(after)
        XCTAssertFalse(ContinuousBatchingSelfCheck.admissionHoldDue(
            dueSince: start, notBefore: lastHold.addingTimeInterval(after), after: after, now: lastHold.addingTimeInterval(60)
        ))
        XCTAssertTrue(ContinuousBatchingSelfCheck.admissionHoldDue(
            dueSince: start, notBefore: lastHold.addingTimeInterval(after), after: after, now: lastHold.addingTimeInterval(after)
        ))
        XCTAssertGreaterThan(ContinuousBatchingSelfCheck.admissionHoldCheckSeconds, 60)
    }

    func testHoldRefusesNewRequestsKeepsInFlightOnesAndResumes() async {
        let status = makeStatus()
        let inFlight = await status.beginRequestIfAccepting(requestID: "before-hold")
        XCTAssertNotNil(inFlight)

        let refusal = await status.beginSelfCheckAdmissionHold()
        XCTAssertNil(refusal)
        let held = await status.admitRequest(requestID: "during-hold")
        XCTAssertEqual(held, .selfCheckAdmissionHold)
        let legacy = await status.beginRequestIfAccepting()
        XCTAssertNil(legacy)
        let during = await status.snapshot()
        XCTAssertEqual(during.status, .busy)
        XCTAssertEqual(during.slotsFree, 0)
        XCTAssertEqual(during.requestsInFlight, 1, "the request admitted before the hold keeps running")
        XCTAssertEqual(during.cbSelfCheckAdmissionHold?.active, true)

        await status.finishRequest(startedAt: inFlight!, completion: nil, failed: false, requestID: "before-hold")
        let drained = await status.snapshot()
        XCTAssertEqual(drained.requestsInFlight, 0)
        XCTAssertEqual(drained.requestsTotal, 1)
        XCTAssertEqual(drained.errorsTotal, 0)
        XCTAssertEqual(drained.status, .busy, "still held after the drain")

        await status.endSelfCheckAdmissionHold(outcome: "completed")
        let after = await status.snapshot()
        XCTAssertEqual(after.status, .ready)
        XCTAssertEqual(after.slotsFree, 4)
        XCTAssertEqual(after.cbSelfCheckAdmissionHold?.active, false)
        XCTAssertEqual(after.cbSelfCheckAdmissionHold?.lastOutcome, "completed")
        XCTAssertEqual(after.cbSelfCheckAdmissionHold?.holdsTotal, 1)
        let admitted = await status.admitRequest(requestID: "after-hold")
        guard case .admitted = admitted else { return XCTFail("admission did not resume: \(admitted)") }
    }

    func testHoldPublishesBusyWithNoFreeSlotThenReady() async {
        let status = makeStatus()
        let recorder = AdmissionHoldTransitionRecorder()
        await status.setRequestCapacityChangeHandler { recorder.record($0) }
        _ = await status.beginSelfCheckAdmissionHold()
        await status.endSelfCheckAdmissionHold(outcome: "completed")
        await status.setRequestCapacityChangeHandler(nil)
        XCTAssertEqual(recorder.entries.map(\.state), [.busy, .ready])
        XCTAssertEqual(recorder.entries.map(\.slotsFree), [0, 4])
        XCTAssertEqual(recorder.entries.map(\.reason), ["cb_self_check_admission_hold", "request_capacity_available"])
    }

    func testHoldNeverStartsUnderAnOperatorPauseOrADrain() async {
        let paused = makeStatus()
        await paused.setOperatorPauseFence(true)
        let pausedRefusal = await paused.beginSelfCheckAdmissionHold()
        XCTAssertEqual(pausedRefusal, "operator_paused")
        let pausedHold = await paused.selfCheckAdmissionHoldStatus()
        XCTAssertEqual(pausedHold.holdsTotal, 0)

        let draining = makeStatus()
        await draining.setState(.draining, reason: "operator_pause_draining")
        let drainingRefusal = await draining.beginSelfCheckAdmissionHold()
        XCTAssertEqual(drainingRefusal, "provider_draining")

        let held = makeStatus()
        _ = await held.beginSelfCheckAdmissionHold()
        let twice = await held.beginSelfCheckAdmissionHold()
        XCTAssertEqual(twice, "already_held")
    }

    func testPauseDuringTheHoldSurvivesTheHoldEnding() async {
        let status = makeStatus()
        _ = await status.beginSelfCheckAdmissionHold()
        await status.setOperatorPauseFence(true)
        await status.endSelfCheckAdmissionHold(outcome: "yielded")
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.status, .unavailable)
        XCTAssertEqual(snapshot.transitionReason, "operator_paused")
        let admission = await status.admitRequest()
        XCTAssertEqual(admission, .pausedOrDraining)
    }

    func testCheckRunsOnlyAfterInFlightRequestsFinishAndNoneIsDropped() async {
        let status = makeStatus()
        let startedAt = await status.beginRequestIfAccepting(requestID: "long-stream")!
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await status.finishRequest(startedAt: startedAt, completion: nil, failed: false, requestID: "long-stream")
        }
        let observed = InFlightObservation()
        let outcome = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            providerStatus: status, drainSeconds: 5, lifecycleLease: nil, context: "test", log: { _ in }
        ) {
            let inFlight = await status.requestsInFlightCount()
            let refused = await status.admitRequest(requestID: "arrived-during-check")
            observed.set(inFlight: inFlight, refused: refused == .selfCheckAdmissionHold)
            return true
        }
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(observed.inFlight, 0, "the check started only after the in-flight request finished")
        XCTAssertEqual(observed.refused, true, "admission stays held while the check runs")
        let after = await status.snapshot()
        XCTAssertEqual(after.requestsTotal, 1)
        XCTAssertEqual(after.errorsTotal, 0)
        XCTAssertEqual(after.status, .ready)
        XCTAssertEqual(after.cbSelfCheckAdmissionHold?.lastOutcome, "completed")
    }

    func testDrainTimeoutSkipsTheCheckCancelsNothingAndReopensAdmission() async {
        let status = makeStatus()
        let startedAt = await status.beginRequestIfAccepting(requestID: "never-finishes")!
        let checked = InFlightObservation()
        let outcome = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            providerStatus: status, drainSeconds: 0, lifecycleLease: nil, context: "test", log: { _ in }
        ) {
            checked.set(inFlight: -1, refused: false)
            return true
        }
        XCTAssertEqual(outcome, .drainTimeout)
        XCTAssertNil(checked.inFlight, "no check runs beside an in-flight request")
        let inFlight = await status.requestsInFlightCount()
        XCTAssertEqual(inFlight, 1, "the in-flight request is not cancelled")
        let hold = await status.selfCheckAdmissionHoldStatus()
        XCTAssertFalse(hold.active)
        XCTAssertEqual(hold.lastOutcome, "drain_timeout")
        let admitted = await status.admitRequest(requestID: "after-timeout")
        guard case .admitted(let second) = admitted else { return XCTFail("admission did not resume") }
        await status.finishRequest(startedAt: second, completion: nil, failed: false, requestID: "after-timeout")
        await status.finishRequest(startedAt: startedAt, completion: nil, failed: false, requestID: "never-finishes")
    }

    func testLifecycleLeaseAndPauseSkipTheHold() async {
        let status = makeStatus()
        let lines = LogLines()
        let leased = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            providerStatus: status, drainSeconds: 5, lifecycleLease: "maintenance", context: "test",
            log: { lines.append($0) }
        ) {
            XCTFail("no check under a maintenance lease")
            return true
        }
        XCTAssertEqual(leased, .skipped(reason: "lifecycle_lease_maintenance"))
        let hold = await status.selfCheckAdmissionHoldStatus()
        XCTAssertEqual(hold.holdsTotal, 0)
        XCTAssertEqual(hold.lastSkipReason, "lifecycle_lease_maintenance")
        XCTAssertTrue(lines.all.contains { $0.contains("action=admission_hold_skipped reason=lifecycle_lease_maintenance") })

        await status.setOperatorPauseFence(true)
        let paused = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            providerStatus: status, drainSeconds: 5, lifecycleLease: nil, context: "test", log: { _ in }
        ) {
            XCTFail("no check under an operator pause")
            return true
        }
        XCTAssertEqual(paused, .skipped(reason: "operator_paused"))
    }

    func testUnfinishedCheckReportsYieldedAndReopensAdmission() async {
        let status = makeStatus()
        let outcome = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            providerStatus: status, drainSeconds: 5, lifecycleLease: nil, context: "test", log: { _ in }
        ) { false }
        XCTAssertEqual(outcome, .yielded)
        let after = await status.snapshot()
        XCTAssertEqual(after.status, .ready)
        XCTAssertEqual(after.cbSelfCheckAdmissionHold?.lastOutcome, "yielded")
    }

    func testDirectHTTPRefusalIsTheRetryableQueuePressureCode() {
        let held = RouterHandler.admissionRefusalError(.selfCheckAdmissionHold)
        XCTAssertEqual(held.status, 503)
        XCTAssertEqual(held.code, "continuous_batching_stream_backpressure")
        XCTAssertFalse(RouterHandler.retryGuidanceHeaders(code: held.code, seconds: 2).isEmpty, "carries Retry-After")
        let paused = RouterHandler.admissionRefusalError(.pausedOrDraining)
        XCTAssertEqual(paused.status, 503)
        XCTAssertEqual(paused.code, "provider_paused")
    }

    func testStatusReportsTheAdmissionHold() async {
        let status = makeStatus()
        let idle = RouterHandler.continuousBatchingStatusFields(nil)
        let idleHold = idle["self_check_admission_hold"] as? [String: Any]
        XCTAssertEqual(idleHold?["active"] as? Bool, false)
        XCTAssertEqual(idleHold?["holds_total"] as? Int, 0)

        _ = await status.beginSelfCheckAdmissionHold()
        let snapshot = await status.snapshot()
        let fields = RouterHandler.continuousBatchingStatusFields(nil, admissionHold: snapshot.cbSelfCheckAdmissionHold)
        let hold = fields["self_check_admission_hold"] as? [String: Any]
        XCTAssertEqual(hold?["active"] as? Bool, true)
        XCTAssertEqual(hold?["holds_total"] as? Int, 1)
        XCTAssertNotNil(hold?["started_at"] as? String)

        let body = RouterHandler.statusResponse(snapshot, providerID: nil, coordinatorURL: nil)
        let cb = body["continuous_batching"] as? [String: Any]
        let statusHold = cb?["self_check_admission_hold"] as? [String: Any]
        XCTAssertEqual(statusHold?["active"] as? Bool, true)
    }
}

private final class AdmissionHoldTransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RequestCapacityTransitionSnapshot] = []

    func record(_ transition: RequestCapacityTransitionSnapshot) {
        lock.lock(); defer { lock.unlock() }
        stored.append(transition)
    }

    var entries: [RequestCapacityTransitionSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

private final class InFlightObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observedInFlight: Int?
    private var observedRefused: Bool?

    func set(inFlight: Int, refused: Bool) {
        lock.lock(); defer { lock.unlock() }
        observedInFlight = inFlight
        observedRefused = refused
    }

    var inFlight: Int? { lock.lock(); defer { lock.unlock() }; return observedInFlight }
    var refused: Bool? { lock.lock(); defer { lock.unlock() }; return observedRefused }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.lock(); defer { lock.unlock() }; lines.append(line) }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
