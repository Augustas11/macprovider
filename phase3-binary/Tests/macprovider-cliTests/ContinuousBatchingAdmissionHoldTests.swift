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
            providerStatus: status, drainSeconds: 5, lifecycleLease: { nil }, context: "test", log: { _ in }
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
            providerStatus: status, drainSeconds: 0, lifecycleLease: { nil }, context: "test", log: { _ in }
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
            providerStatus: status, drainSeconds: 5, lifecycleLease: { "maintenance" }, context: "test",
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
            providerStatus: status, drainSeconds: 5, lifecycleLease: { nil }, context: "test", log: { _ in }
        ) {
            XCTFail("no check under an operator pause")
            return true
        }
        XCTAssertEqual(paused, .skipped(reason: "operator_paused"))
    }

    func testCheckBoundReopensAdmissionWithoutWaitingForTheCheck() async {
        let status = makeStatus()
        let reopened = InFlightObservation()
        let started = Date()
        let outcome = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            providerStatus: status, drainSeconds: 5, checkSeconds: 0.2, lifecycleLease: { nil }, context: "test", log: { _ in }
        ) {
            // A check that ignores the bound until it is cancelled.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
            // Cancellation precedes reopening. Keep this check unfinished
            // while allowing the hold owner to publish the admission change.
            let reopenDeadline = Date().addingTimeInterval(1)
            while await status.selfCheckAdmissionHoldStatus().active, Date() < reopenDeadline {
                await Task.yield()
            }
            let admission = await status.admitRequest(requestID: "after-bound")
            if case .admitted(let at) = admission {
                reopened.set(inFlight: 1, refused: false)
                await status.finishRequest(startedAt: at, completion: nil, failed: false, requestID: "after-bound")
            } else {
                reopened.set(inFlight: 0, refused: true)
            }
            return true
        }
        XCTAssertEqual(outcome, .checkBound)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(reopened.refused, false, "admission re-opened before the cancelled check returned")
        let hold = await status.selfCheckAdmissionHoldStatus()
        XCTAssertFalse(hold.active)
        XCTAssertEqual(hold.lastOutcome, "check_bound")
    }

    func testPauseLeaseOrTargetChangeDuringTheCheckEndsTheHold() async {
        // A pause that begins during the check.
        let paused = makeStatus()
        let pausedOutcome = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            providerStatus: paused, drainSeconds: 5, lifecycleLease: { nil }, context: "test", log: { _ in }
        ) {
            await paused.setOperatorPauseFence(true)
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
            return false
        }
        XCTAssertEqual(pausedOutcome, .yielded)
        let pausedSnapshot = await paused.snapshot()
        XCTAssertEqual(pausedSnapshot.status, .unavailable, "the pause keeps its state")

        // A lifecycle lease acquired during the check.
        let leased = makeStatus()
        let lease = LeaseFlag()
        let leasedOutcome = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            providerStatus: leased, drainSeconds: 5, lifecycleLease: { lease.value }, context: "test", log: { _ in }
        ) {
            lease.set("maintenance")
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
            return false
        }
        XCTAssertEqual(leasedOutcome, .yielded)
        let leasedHold = await leased.selfCheckAdmissionHoldStatus()
        XCTAssertFalse(leasedHold.active)

        // The self-check target changed (a model swap): the check never starts.
        let swapped = makeStatus()
        let ran = InFlightObservation()
        let swappedOutcome = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            providerStatus: swapped, drainSeconds: 5, lifecycleLease: { nil }, stillValid: { false },
            context: "test", log: { _ in }
        ) {
            ran.set(inFlight: 0, refused: false)
            return true
        }
        XCTAssertEqual(swappedOutcome, .yielded)
        XCTAssertNil(ran.inFlight)
    }

    func testCheckBoundEscalatesAfterBoundYieldsUpToFourTimes() {
        let base = ContinuousBatchingSelfCheck.admissionHoldCheckSeconds
        XCTAssertEqual(ContinuousBatchingSelfCheck.admissionHoldCheckBound(base: base, consecutiveBoundYields: 0), 300)
        XCTAssertEqual(ContinuousBatchingSelfCheck.admissionHoldCheckBound(base: base, consecutiveBoundYields: 1), 600)
        XCTAssertEqual(ContinuousBatchingSelfCheck.admissionHoldCheckBound(base: base, consecutiveBoundYields: 5), 1200)
        XCTAssertEqual(ContinuousBatchingSelfCheck.admissionHoldJitterSeconds, 900)
    }

    func testCancelledRuntimeResultYieldsWithoutBecomingADecision() async {
        let status = makeStatus()
        let outcome = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            providerStatus: status, drainSeconds: 0, checkSeconds: 0.1,
            lifecycleLease: { nil }, context: "test", log: { _ in }
        ) {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            // A scheduler may report success while its caller was cancelled.
            // Exercise the same terminal gate as the runtime's batch collector.
            do {
                try ModelRuntime.validateContinuousBatchingSelfCheckTerminal(.length)
                XCTFail("a cancelled self-check must not store a measurement")
                return true
            } catch {
                XCTAssertTrue(error is CancellationError)
                return false
            }
        }
        XCTAssertEqual(outcome, .checkBound, "the watchdog owns expiry even when the check returns false")
        let hold = await status.selfCheckAdmissionHoldStatus()
        XCTAssertFalse(hold.active)
        XCTAssertEqual(hold.lastOutcome, "check_bound")
    }

    func testReportCarriesTheDecodeWindow() {
        let key = ContinuousBatchingSelfCheckKey(
            modelSHA256: "m", metallibSHA256: "l", kernelIdentifier: "k", hardwareClass: "h",
            osBuild: "o", runtimeBuild: "r", decodeWindow: 16
        )
        let json = ContinuousBatchingSelfCheckReport(decision: "granted", servedSlots: 8, verifiedSlots: 8, key: key).jsonObject
        XCTAssertEqual(json["decode_window"] as? Int, 16)
    }

    func testDrainBoundEscalatesAfterDrainTimeoutsUpToFourTimes() {
        XCTAssertEqual(ContinuousBatchingSelfCheck.admissionHoldDrainSeconds(base: 30, consecutiveDrainTimeouts: 0), 30)
        XCTAssertEqual(ContinuousBatchingSelfCheck.admissionHoldDrainSeconds(base: 30, consecutiveDrainTimeouts: 1), 60)
        XCTAssertEqual(ContinuousBatchingSelfCheck.admissionHoldDrainSeconds(base: 30, consecutiveDrainTimeouts: 2), 120)
        XCTAssertEqual(ContinuousBatchingSelfCheck.admissionHoldDrainSeconds(base: 30, consecutiveDrainTimeouts: 9), 120)
    }

    func testRefusalRetryHintRunsToTheHoldBound() async {
        let status = makeStatus()
        let none = await status.selfCheckAdmissionHoldRetryAfterSeconds()
        XCTAssertNil(none)
        let now = Date()
        _ = await status.beginSelfCheckAdmissionHold(expectedEndAt: now.addingTimeInterval(330))
        let hint = await status.selfCheckAdmissionHoldRetryAfterSeconds(now: now)
        XCTAssertEqual(hint, 330)
        let late = await status.selfCheckAdmissionHoldRetryAfterSeconds(now: now.addingTimeInterval(400))
        XCTAssertEqual(late, 1)
    }

    func testUnfinishedCheckReportsYieldedAndReopensAdmission() async {
        let status = makeStatus()
        let outcome = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            providerStatus: status, drainSeconds: 5, lifecycleLease: { nil }, context: "test", log: { _ in }
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

private final class LeaseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
}
