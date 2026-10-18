import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
import MacProviderCore
@testable import macprovider_cli

/// SPEC-001-R011: local (loopback, non-network) requests are counted apart
/// from buyer stats and always yield to paying network buyers.
final class LocalRequestPriorityTests: XCTestCase {

    // MARK: - Counter separation

    func testLocalRequestsNeverReachBuyerCountersOrTheHeartbeatWindow() async throws {
        let status = makeStatus(slots: 2)
        let local = LocalPreemptionLease()
        guard case .admitted = await status.beginLocalRequest(local) else { return XCTFail("local not admitted") }

        let inFlight = await status.snapshot()
        XCTAssertEqual(inFlight.requestsInFlight, 0, "local work must not count as buyer work in flight")
        XCTAssertEqual(inFlight.slotsFree, 2, "published buyer capacity ignores local work")
        XCTAssertEqual(inFlight.localUsage.requestsInFlight, 1)

        await status.finishLocalRequest(local, completion: completion(prompt: 11, output: 22), failed: false)
        let buyerStart = await status.beginRequest()
        await status.finishRequest(startedAt: buyerStart, completion: completion(prompt: 3, output: 4), failed: false)

        let snapshot = await status.snapshot(resetWindow: true)
        XCTAssertEqual(snapshot.requestsServedSinceLast, 1, "heartbeat requests_served_since_last is buyer-only")
        XCTAssertEqual(snapshot.requestsTotal, 1)
        XCTAssertEqual(snapshot.requestsToday, 1)
        XCTAssertEqual(snapshot.inputTokensAllTime, 3)
        XCTAssertEqual(snapshot.outputTokensAllTime, 4)
        XCTAssertEqual(snapshot.errorsTotal, 0)
        XCTAssertEqual(snapshot.localUsage.requestsTotal, 1)
        XCTAssertEqual(snapshot.localUsage.requestsCompleted, 1)
        XCTAssertEqual(snapshot.localUsage.promptTokensTotal, 11)
        XCTAssertEqual(snapshot.localUsage.completionTokensTotal, 22)
        XCTAssertEqual(snapshot.localUsage.requestsInFlight, 0)
    }

    func testLocalFailureIsNotABuyerError() async throws {
        let status = makeStatus(slots: 1)
        let local = LocalPreemptionLease()
        guard case .admitted = await status.beginLocalRequest(local) else { return XCTFail("local not admitted") }
        await status.finishLocalRequest(local, completion: nil, failed: true)
        await status.finishLocalRequest(local, completion: nil, failed: true)
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.errorsTotal, 0)
        XCTAssertEqual(snapshot.requestsTotal, 0)
        XCTAssertEqual(snapshot.localUsage.requestsFailed, 1, "finishing twice counts once")
        XCTAssertEqual(snapshot.localUsage.requestsTotal, 1)
    }

    func testLocalUsageStatusFieldDeclaresItselfUnbilledAndUncounted() {
        let json = LocalUsageSnapshot(requestsTotal: 2, requestsPreempted: 1).statusJSON
        XCTAssertEqual(json["billable"] as? Bool, false)
        XCTAssertEqual(json["heartbeat_counted"] as? Bool, false)
        XCTAssertEqual(json["priority"] as? String, "customers_first")
        XCTAssertEqual(json["requests_total"] as? Int, 2)
        XCTAssertEqual(json["requests_preempted"] as? Int, 1)
        XCTAssertTrue(RouterHandler.localStatusCapabilities.contains("local_chat_priority_v1"))
    }

    // MARK: - Admission policy

    func testReservationKeepsOneSlotFreeForBuyersOnAMultiSlotProvider() async throws {
        let status = makeStatus(slots: 4, queueWaitMS: 100)
        var leases: [LocalPreemptionLease] = []
        for _ in 0..<3 {
            let lease = LocalPreemptionLease()
            guard case .admitted = await status.beginLocalRequest(lease) else { return XCTFail("local not admitted") }
            leases.append(lease)
        }
        let fourth = await status.beginLocalRequest(LocalPreemptionLease())
        XCTAssertEqual(fourth, .preempted, "the reserved slot is never handed to local work")
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.localUsage.requestsDeclined, 1)
        XCTAssertEqual(snapshot.localUsage.reservedBuyerSlots, 1)

        // A buyer takes the reserved slot without preempting anything.
        _ = await status.beginRequest()
        XCTAssertFalse(leases.contains { $0.isPreempted })
        // The next buyer would wait on local work: only the newest yields.
        _ = await status.beginRequest()
        XCTAssertEqual(leases.map(\.isPreempted), [false, false, true])
    }

    func testConfiguredReservationIsCappedBelowTheServedSlots() {
        let policy = LocalPriorityPolicy(reservedBuyerSlots: 9)
        XCTAssertEqual(policy.reservation(forServedSlots: 1), 0)
        XCTAssertEqual(policy.reservation(forServedSlots: 4), 3)
        XCTAssertEqual(LocalPriorityPolicy().reservation(forServedSlots: 2), 1)
    }

    func testSingleSlotLocalRequestQueuesBehindABuyer() async throws {
        let status = makeStatus(slots: 1, queueWaitMS: 5_000)
        let buyerStart = await status.beginRequest()
        let lease = LocalPreemptionLease()
        let waiter = Task { await status.beginLocalRequest(lease) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let waitingUsage = await status.currentLocalUsage()
        XCTAssertEqual(waitingUsage.requestsInFlight, 0, "local work waits while the buyer holds the only slot")
        await status.finishRequest(startedAt: buyerStart, completion: nil, failed: false)
        guard case .admitted = await waiter.value else { return XCTFail("local not admitted after the buyer left") }
    }

    func testSingleSlotLocalRequestTimesOutBehindBuyersWithLocalPreempted() async throws {
        let status = makeStatus(slots: 1, queueWaitMS: 100)
        _ = await status.beginRequest()
        let result = await status.beginLocalRequest(LocalPreemptionLease())
        XCTAssertEqual(result, .preempted)
    }

    func testBuyerArrivalPreemptsSingleSlotLocalRequestImmediately() async throws {
        let status = makeStatus(slots: 1)
        let lease = LocalPreemptionLease()
        guard case .admitted = await status.beginLocalRequest(lease) else { return XCTFail("local not admitted") }
        let fired = expectation(description: "preempted")
        lease.onPreempt { fired.fulfill() }
        _ = await status.beginRequest()
        XCTAssertTrue(lease.isPreempted, "default window is 0 ms: preemption fires inside the buyer's admission")
        await fulfillment(of: [fired], timeout: 1)
        await status.finishLocalRequest(lease, completion: nil, failed: false)
        let usage = await status.currentLocalUsage()
        XCTAssertEqual(usage.requestsPreempted, 1)
    }

    func testPreemptionWindowBoundsTheBuyerWait() async throws {
        let status = makeStatus(slots: 1, preemptionWindowMS: 200)
        let lease = LocalPreemptionLease()
        guard case .admitted = await status.beginLocalRequest(lease) else { return XCTFail("local not admitted") }
        let buyerArrived = DispatchTime.now().uptimeNanoseconds
        _ = await status.beginRequest()
        XCTAssertFalse(lease.isPreempted, "inside the window the local request may still finish")
        try await eventually(timeoutNanoseconds: 2_000_000_000) { lease.isPreempted }
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - buyerArrived) / 1_000_000
        XCTAssertGreaterThanOrEqual(elapsedMS, 150)
        XCTAssertLessThan(elapsedMS, 1_000, "preemption must fire at the window, not later")
    }

    func testBuyerThatFinishesInsideTheWindowLeavesLocalWorkAlone() async throws {
        let status = makeStatus(slots: 1, preemptionWindowMS: 200)
        let lease = LocalPreemptionLease()
        guard case .admitted = await status.beginLocalRequest(lease) else { return XCTFail("local not admitted") }
        let buyerStart = await status.beginRequest()
        await status.finishRequest(startedAt: buyerStart, completion: nil, failed: false)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(lease.isPreempted, "the buyer no longer needs the slot at the window's end")
    }

    func testFinishedLocalRequestIsNeverPreemptedLater() async throws {
        let status = makeStatus(slots: 1, preemptionWindowMS: 100)
        let lease = LocalPreemptionLease()
        guard case .admitted = await status.beginLocalRequest(lease) else { return XCTFail("local not admitted") }
        _ = await status.beginRequest()
        await status.finishLocalRequest(lease, completion: completion(prompt: 1, output: 1), failed: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(lease.isPreempted)
        let usage = await status.currentLocalUsage()
        XCTAssertEqual(usage.requestsCompleted, 1)
        XCTAssertEqual(usage.requestsPreempted, 0)
    }

    func testLocalQueueIsBounded() async throws {
        let status = makeStatus(slots: 1, queueWaitMS: 1_000)
        _ = await status.beginRequest()
        var waiters: [Task<LocalAdmission, Never>] = []
        for _ in 0..<LocalPriorityPolicy.maximumQueuedLocalRequests {
            waiters.append(Task { await status.beginLocalRequest(LocalPreemptionLease()) })
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = DispatchTime.now().uptimeNanoseconds
        let overflow = await status.beginLocalRequest(LocalPreemptionLease())
        XCTAssertEqual(overflow, .preempted)
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - started, 300_000_000, "a full queue declines at once")
        for waiter in waiters {
            let result = await waiter.value
            XCTAssertEqual(result, .preempted)
        }
        let usage = await status.currentLocalUsage()
        XCTAssertEqual(usage.requestsDeclined, LocalPriorityPolicy.maximumQueuedLocalRequests + 1)
    }

    func testProcessDrainPreemptsLocalWorkButOperatorPauseDrainDoesNot() async throws {
        let status = makeStatus(slots: 2)
        let lease = LocalPreemptionLease()
        guard case .admitted = await status.beginLocalRequest(lease) else { return XCTFail("local not admitted") }
        let pauseDrained = await status.waitUntilDrained(timeoutSeconds: 1)
        XCTAssertTrue(pauseDrained)
        XCTAssertFalse(lease.isPreempted, "an operator pause keeps local work running")
        let hasWork = await status.hasInferenceWork()
        XCTAssertTrue(hasWork, "internal work yields to local work")

        lease.onPreempt {
            Task { await status.finishLocalRequest(lease, completion: nil, failed: false) }
        }
        let drained = await status.waitUntilDrained(timeoutSeconds: 2, preemptingLocal: true)
        XCTAssertTrue(drained)
        XCTAssertTrue(lease.isPreempted)
        let idle = await status.hasInferenceWork()
        XCTAssertFalse(idle)
    }

    func testEveryAdmittedLocalRequestEndsInExactlyOneOutcome() async throws {
        let status = makeStatus(slots: 4, reservedBuyerSlots: 0)
        let utility = LocalPreemptionLease()
        let cancelled = LocalPreemptionLease()
        guard case .admitted = await status.beginLocalRequest(utility),
              case .admitted = await status.beginLocalRequest(cancelled) else { return XCTFail("local not admitted") }
        await status.finishLocalRequest(utility, completion: nil, failed: false, succeeded: true)
        await status.finishLocalRequest(cancelled, completion: nil, failed: false)
        let usage = await status.currentLocalUsage()
        XCTAssertEqual(usage.requestsTotal, 2)
        XCTAssertEqual(usage.requestsCompleted, 1, "a successful token utility is a completed request")
        XCTAssertEqual(usage.requestsCancelled, 1, "a client cancel is its own outcome")
        XCTAssertEqual(usage.requestsCompleted + usage.requestsFailed + usage.requestsPreempted + usage.requestsCancelled, usage.requestsTotal)
    }

    func testUpdateDrainSettlesQueuedLocalWaitersAndStaysClosedUntilReopened() async throws {
        let status = makeStatus(slots: 1, queueWaitMS: 5_000)
        let buyerStart = await status.beginRequest()
        let queued = Task { await status.beginLocalRequest(LocalPreemptionLease()) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let drain = Task { await status.waitUntilDrained(timeoutSeconds: 3, preemptingLocal: true) }
        let queuedResult = await queued.value
        XCTAssertEqual(queuedResult, .unavailable, "a draining provider settles queued local work")
        await status.finishRequest(startedAt: buyerStart, completion: nil, failed: false)
        let drained = await drain.value
        XCTAssertTrue(drained)
        let afterDrain = await status.beginLocalRequest(LocalPreemptionLease())
        XCTAssertEqual(afterDrain, .unavailable, "local admission stays closed after an update drain")
        await status.reopenLocalAdmission()
        guard case .admitted = await status.beginLocalRequest(LocalPreemptionLease()) else {
            return XCTFail("reset to ready reopens local admission")
        }
    }

    func testOverlappingWindowsKeepTheBuyerThatStillNeedsASlotAndSpareTheOlderLocal() async throws {
        let status = makeStatus(slots: 2, reservedBuyerSlots: 0, preemptionWindowMS: 150)
        let older = LocalPreemptionLease()
        let newer = LocalPreemptionLease()
        guard case .admitted = await status.beginLocalRequest(older),
              case .admitted = await status.beginLocalRequest(newer) else { return XCTFail("local not admitted") }
        let firstBuyer = await status.beginRequest()
        _ = await status.beginRequest()
        await status.finishRequest(startedAt: firstBuyer, completion: nil, failed: false)
        try await eventually(timeoutNanoseconds: 2_000_000_000) { newer.isPreempted }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(newer.isPreempted, "the remaining buyer still needs one slot")
        XCTAssertFalse(older.isPreempted, "the older local request keeps its slot")
    }

    func testRequestsNeverAdmittedAreCountedAsDeclined() async throws {
        let status = makeStatus(slots: 1)
        let cancelled = await status.beginLocalRequest(LocalPreemptionLease(), isCancelled: { true })
        XCTAssertEqual(cancelled, .cancelled)
        await status.setState(.draining, reason: "drain")
        let unavailable = await status.beginLocalRequest(LocalPreemptionLease())
        XCTAssertEqual(unavailable, .unavailable)
        let usage = await status.currentLocalUsage()
        XCTAssertEqual(usage.requestsDeclined, 2)
        XCTAssertEqual(usage.requestsTotal, 0)
    }

    func testPausedProviderReportsNoBuyerReservation() async throws {
        let status = makeStatus(slots: 4)
        let before = await status.currentLocalUsage()
        XCTAssertEqual(before.reservedBuyerSlots, 1)
        await status.setOperatorPauseFence(true)
        let paused = await status.currentLocalUsage()
        XCTAssertEqual(paused.reservedBuyerSlots, 0)
    }

    func testTimedOutUpdateDrainReopensLocalAdmission() async throws {
        let status = makeStatus(slots: 1)
        _ = await status.beginRequest()
        let drained = await status.waitUntilDrained(timeoutSeconds: 0, preemptingLocal: true)
        XCTAssertFalse(drained)
        let usage = await status.snapshot()
        XCTAssertEqual(usage.requestsInFlight, 1)
        let local = await status.beginLocalRequest(LocalPreemptionLease())
        XCTAssertEqual(local, .preempted, "the buyer holds the only slot, but admission is open again")
    }

    func testOperatorPauseLetsTheProviderUseAllSlotsLocally() async throws {
        let status = makeStatus(slots: 2)
        await status.setOperatorPauseFence(true)
        await status.setState(.unavailable, reason: "operator_paused")
        let first = await status.beginLocalRequest(LocalPreemptionLease())
        let second = await status.beginLocalRequest(LocalPreemptionLease())
        guard case .admitted = first, case .admitted = second else {
            return XCTFail("paused provider must admit local work into every slot: \(first) \(second)")
        }
        let buyer = await status.beginRequestIfAccepting()
        XCTAssertNil(buyer, "pause still fences buyers")
    }

    func testDrainingProviderRejectsLocalWork() async throws {
        let status = makeStatus(slots: 1)
        await status.setState(.draining, reason: "drain")
        let result = await status.beginLocalRequest(LocalPreemptionLease())
        XCTAssertEqual(result, .unavailable)
    }

    func testServedSlotShrinkPreemptsLocalWorkThatNoLongerFits() async throws {
        let status = makeStatus(slots: 2, reservedBuyerSlots: 0)
        let older = LocalPreemptionLease()
        let newer = LocalPreemptionLease()
        guard case .admitted = await status.beginLocalRequest(older),
              case .admitted = await status.beginLocalRequest(newer) else { return XCTFail("local not admitted") }
        _ = await status.beginRequest()
        XCTAssertEqual([older.isPreempted, newer.isPreempted], [false, true])
        await status.updateServedSlots(1)
        XCTAssertEqual([older.isPreempted, newer.isPreempted], [true, true])
    }

    // MARK: - HTTP: serial and continuous-batching gate shapes

    func testSerialPathBuyerPreemptsRunningLocalChatWithLocal503() async throws {
        try await assertBuyerPreemptsRunningLocal(shape: .serial, stream: false)
    }

    func testSerialPathBuyerPreemptsStreamingLocalChat() async throws {
        try await assertBuyerPreemptsRunningLocal(shape: .serial, stream: true)
    }

    func testContinuousBatchingPathBuyerPreemptsRunningLocalChat() async throws {
        try await assertBuyerPreemptsRunningLocal(shape: .continuousBatching, stream: false)
    }

    func testContinuousBatchingPathBuyerPreemptsStreamingLocalChat() async throws {
        try await assertBuyerPreemptsRunningLocal(shape: .continuousBatching, stream: true)
    }

    func testContinuousBatchingPathReservesABuyerSlotAndPreemptsOnlyTheNewestLocal() async throws {
        let probe = SlotProbe()
        let runtime = SlotFixtureRuntime(slots: 4, shape: .continuousBatching, probe: probe)
        let status = makeStatus(slots: 4, queueWaitMS: 200)
        try await withPriorityHTTPServer(runtime: runtime, status: status) { port in
            var locals: [Task<LocalHTTPResponse, Error>] = []
            for index in 0..<3 {
                locals.append(Task { try await post(port: port, content: "local-hold-\(index)") })
                try await eventually { probe.entered("local-hold-\(index)") }
            }
            let declined = try await post(port: port, content: "local-quick")
            XCTAssertEqual(declined.status, 503, declined.body)
            XCTAssertEqual(declined.errorCode, "local_preempted")
            XCTAssertFalse(probe.entered("local-quick"), "the reserved slot never runs local work")

            // The first buyer takes the reserved slot and keeps it.
            let holdingBuyer = Task { try await post(port: port, content: "buyer-hold", network: true) }
            try await eventually { probe.entered("buyer-hold") }
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(probe.cancelledCount, 0, "a buyer that fits preempts nothing")

            // The second buyer would wait on local work: the newest local yields.
            let secondBuyer = try await post(port: port, content: "buyer-2", network: true)
            XCTAssertEqual(secondBuyer.status, 200, secondBuyer.body)
            let preempted = try await locals[2].value
            XCTAssertEqual(preempted.status, 503, preempted.body)
            XCTAssertEqual(preempted.errorCode, "local_preempted", preempted.body)
            let usage = await status.currentLocalUsage()
            XCTAssertEqual(usage.requestsPreempted, 1, "only the newest local request yields")
            XCTAssertEqual(usage.requestsInFlight, 2, "the two older local requests keep running")
            XCTAssertFalse(probe.entered("local-quick"))
            probe.releaseBuyers()
            let buyerResult = try await holdingBuyer.value
            XCTAssertEqual(buyerResult.status, 200)
            for task in locals.prefix(2) { task.cancel() }
        }
        let snapshot = await status.snapshot(resetWindow: true)
        XCTAssertEqual(snapshot.requestsServedSinceLast, 2, "only the two buyers reach the heartbeat window")
        XCTAssertEqual(snapshot.localUsage.requestsDeclined, 1)
        XCTAssertGreaterThanOrEqual(snapshot.localUsage.requestsPreempted, 1)
    }

    func testSerialPathLocalChatWaitsBehindABuyerThenRuns() async throws {
        let probe = SlotProbe()
        let runtime = SlotFixtureRuntime(slots: 1, shape: .serial, probe: probe)
        let status = makeStatus(slots: 1, queueWaitMS: 5_000)
        try await withPriorityHTTPServer(runtime: runtime, status: status) { port in
            let buyer = Task { try await post(port: port, content: "buyer-hold", network: true) }
            try await eventually { probe.entered("buyer-hold") }
            let local = Task { try await post(port: port, content: "local-quick") }
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertFalse(probe.entered("local-quick"), "local work queues behind the buyer")
            probe.releaseBuyers()
            let buyerResult = try await buyer.value
            XCTAssertEqual(buyerResult.status, 200, buyerResult.body)
            let localResult = try await local.value
            XCTAssertEqual(localResult.status, 200, localResult.body)
        }
        let snapshot = await status.snapshot(resetWindow: true)
        XCTAssertEqual(snapshot.requestsServedSinceLast, 1)
        XCTAssertEqual(snapshot.localUsage.requestsCompleted, 1)
    }

    func testSerialPathPreemptionWindowBoundsBuyerWaitOverHTTP() async throws {
        let probe = SlotProbe()
        let runtime = SlotFixtureRuntime(slots: 1, shape: .serial, probe: probe)
        let status = makeStatus(slots: 1, preemptionWindowMS: 300)
        try await withPriorityHTTPServer(runtime: runtime, status: status) { port in
            let local = Task { try await post(port: port, content: "local-hold") }
            try await eventually { probe.entered("local-hold") }
            let sent = DispatchTime.now().uptimeNanoseconds
            let buyer = try await post(port: port, content: "buyer", network: true)
            XCTAssertEqual(buyer.status, 200, buyer.body)
            let enteredAt = try XCTUnwrap(probe.entryTime("buyer"))
            let waitedMS = Double(enteredAt - sent) / 1_000_000
            XCTAssertGreaterThanOrEqual(waitedMS, 250, "the local request keeps its window")
            XCTAssertLessThan(waitedMS, 1_300, "the buyer never waits much past the window")
            let localResult = try await local.value
            XCTAssertEqual(localResult.status, 503, localResult.body)
            XCTAssertEqual(localResult.errorCode, "local_preempted")
        }
    }

    // MARK: - Helpers

    private func assertBuyerPreemptsRunningLocal(
        shape: SlotFixtureRuntime.Shape,
        stream: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let probe = SlotProbe()
        let runtime = SlotFixtureRuntime(slots: 1, shape: shape, probe: probe)
        let status = makeStatus(slots: 1)
        try await withPriorityHTTPServer(runtime: runtime, status: status) { port in
            let local = Task { try await post(port: port, content: "local-hold", stream: stream) }
            try await eventually { probe.entered("local-hold") }
            let sent = DispatchTime.now().uptimeNanoseconds
            let buyer = try await post(port: port, content: "buyer", network: true)
            XCTAssertEqual(buyer.status, 200, buyer.body, file: file, line: line)
            let enteredAt = try XCTUnwrap(probe.entryTime("buyer"), file: file, line: line)
            XCTAssertLessThan(Double(enteredAt - sent) / 1_000_000, 1_000, "buyer waited on local work", file: file, line: line)

            let localResult = try await local.value
            if stream {
                XCTAssertEqual(localResult.status, 200, localResult.body, file: file, line: line)
                XCTAssertTrue(localResult.body.contains("\"local_preempted\""), localResult.body, file: file, line: line)
                XCTAssertTrue(localResult.body.contains("[DONE]"), localResult.body, file: file, line: line)
                XCTAssertFalse(localResult.body.contains("\"finish_reason\":\"stop\""), localResult.body, file: file, line: line)
            } else {
                XCTAssertEqual(localResult.status, 503, localResult.body, file: file, line: line)
                XCTAssertEqual(localResult.errorCode, "local_preempted", file: file, line: line)
                XCTAssertEqual(localResult.retryable, true, file: file, line: line)
            }
        }
        let snapshot = await status.snapshot(resetWindow: true)
        XCTAssertEqual(snapshot.requestsServedSinceLast, 1, "the preempted local request is not served buyer work", file: file, line: line)
        XCTAssertEqual(snapshot.errorsTotal, 0, file: file, line: line)
        XCTAssertEqual(snapshot.localUsage.requestsPreempted, 1, file: file, line: line)
        XCTAssertEqual(snapshot.localUsage.requestsInFlight, 0, file: file, line: line)
    }

    private func makeStatus(
        slots: Int,
        reservedBuyerSlots: Int = LocalPriorityPolicy.defaultReservedBuyerSlots,
        preemptionWindowMS: Int = 0,
        queueWaitMS: Int = 5_000
    ) -> ProviderStatus {
        let status = ProviderStatus(
            modelID: "fixture-model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: slots)
        )
        let policy = LocalPriorityPolicy(
            reservedBuyerSlots: reservedBuyerSlots,
            preemptionWindowMS: preemptionWindowMS,
            queueWaitMS: queueWaitMS
        )
        let ready = expectation(description: "policy")
        Task {
            await status.setLocalPriorityPolicy(policy)
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
        return status
    }

    private func completion(prompt: Int, output: Int) -> CompletionResult {
        CompletionResult(content: "x", finishReason: "stop", promptTokens: prompt, completionTokens: output, settlementDisposition: .eligibleOwner)
    }
}

// MARK: - Fixtures

private final class SlotProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: UInt64] = [:]
    private var cancelled = 0
    private var buyersReleased = false

    func enter(_ content: String) {
        lock.lock()
        entries[content] = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func entered(_ content: String) -> Bool { entryTime(content) != nil }

    func entryTime(_ content: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return entries[content]
    }

    func noteCancelled() {
        lock.lock()
        cancelled += 1
        lock.unlock()
    }

    var cancelledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func releaseBuyers() {
        lock.lock()
        buyersReleased = true
        lock.unlock()
    }

    var areBuyersReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return buyersReleased
    }
}

/// A runtime with the real admission shape around a slot gate. `.serial`
/// waits on the gate like `inferenceGate.withPermit`, which only Task
/// cancellation releases; `.continuousBatching` also observes `shouldCancel`
/// while queued, as `withDrainAndClientCancellation` does around
/// `scheduler.submit`. Both poll `shouldCancel` while generating.
private actor SlotFixtureRuntime: ModelRuntimeServing {
    enum Shape: Sendable { case serial, continuousBatching }

    private let gate: AsyncSemaphore
    private let shape: Shape
    private let probe: SlotProbe

    init(slots: Int, shape: Shape, probe: SlotProbe) {
        self.gate = AsyncSemaphore(value: slots)
        self.shape = shape
        self.probe = probe
    }

    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    nonisolated var isSettlementReceiptEligible: Bool { true }
    nonisolated var settlementRuntimeSource: String? { nil }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}
    func unregisterInFlight(_ id: Int) {}

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(
            snapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: request.model, modelHash: nil),
            registrationID: 0,
            drainCancelled: DrainCancelToken()
        )
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {}

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        try await run(request, shouldCancel: shouldCancel)
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        try await run(request, shouldCancel: shouldCancel, onChunk: onChunk)
    }

    private func run(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: (@Sendable (StreamChunk) -> Void)? = nil
    ) async throws -> CompletionResult {
        let content = Self.content(of: request)
        let probe = probe
        let gate = gate
        let work: @Sendable () async throws -> CompletionResult = {
            try await gate.withPermit {
                probe.enter(content)
                onChunk?(.content("t0"))
                let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
                while DispatchTime.now().uptimeNanoseconds < deadline {
                    let holds = content.hasPrefix("local-hold") || (content == "buyer-hold" && !probe.areBuyersReleased)
                    if !holds { break }
                    if shouldCancel() || Task.isCancelled {
                        probe.noteCancelled()
                        throw CancellationError()
                    }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                return CompletionResult(content: "ok", finishReason: "stop", promptTokens: 1, completionTokens: 1, settlementDisposition: .eligibleOwner)
            }
        }
        switch shape {
        case .serial:
            return try await work()
        case .continuousBatching:
            return try await withThrowingTaskGroup(of: CompletionResult.self) { group in
                group.addTask { try await work() }
                group.addTask {
                    while !shouldCancel() {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    throw CancellationError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        }
    }

    private static func content(of request: ChatCompletionRequest) -> String {
        request.messages.last?.content ?? ""
    }
}

private struct LocalHTTPResponse: Sendable {
    let status: Int
    let body: String

    private var error: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? [String: Any]
    }

    var errorCode: String? { error?["code"] as? String }
    var retryable: Bool? { error?["retryable"] as? Bool }
}

private func withPriorityHTTPServer(
    runtime: any ModelRuntimeServing,
    status: ProviderStatus,
    operation: (Int) async throws -> Void
) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 16)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(RouterHandler(
                    modelID: "fixture-model",
                    providerID: "provider-a",
                    coordinatorURL: nil,
                    modelRuntime: runtime,
                    providerStatus: status,
                    warmSwapEnabled: false,
                    maxBodyBytes: 1_000_000,
                    receiptBuilder: nil
                ))
            }
        }
    let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    do {
        try await operation(try XCTUnwrap(channel.localAddress?.port))
        try await channel.close().get()
        try await group.shutdownGracefully()
    } catch {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        throw error
    }
}

private let settlementMetadataHeaderValue: String = {
    let metadata: [String: Any] = [
        "account_scope": "acct_sha256:" + String(repeating: "1", count: 64),
        "request_id": "req-local-priority",
        "attempt_n": 0,
        "provider_id": "provider-a",
        "provider_receipt_key_id": String(repeating: "5", count: 64),
        "model_id": "fixture-model",
        "expected_catalog_model_hash": String(repeating: "6", count: 64),
        "catalog_id": "catalog-a",
        "catalog_body_digest": String(repeating: "2", count: 64),
        "route_snapshot_digest": String(repeating: "3", count: 64),
        "route_snapshot_policy_version": "spec022-prereq-v0",
        "route_snapshot_mode": "observe",
        "prompt_hash": String(repeating: "4", count: 64),
        "output_prefix_start_byte": 5,
        "pending_deadline_seconds": 120,
    ]
    let data = try! JSONSerialization.data(withJSONObject: metadata, options: [.withoutEscapingSlashes])
    return data.base64URLUnpadded()
}()

private let priorityTestSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.httpMaximumConnectionsPerHost = 16
    return URLSession(configuration: configuration)
}()

private func post(port: Int, content: String, stream: Bool = false, network: Bool = false) async throws -> LocalHTTPResponse {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if network {
        request.setValue(settlementMetadataHeaderValue, forHTTPHeaderField: RouterHandler.settlementMetadataHeaderName)
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": "fixture-model",
        "messages": [["role": "user", "content": content]],
        "stream": stream,
    ])
    let (data, response) = try await priorityTestSession.data(for: request)
    return LocalHTTPResponse(
        status: (response as? HTTPURLResponse)?.statusCode ?? 0,
        body: String(decoding: data, as: UTF8.self)
    )
}

private func eventually(
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    _ condition: @escaping () -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("condition never became true")
}
