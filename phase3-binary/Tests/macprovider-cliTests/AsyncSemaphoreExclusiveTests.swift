import Foundation
import XCTest
@testable import macprovider_cli

final class AsyncSemaphoreExclusiveTests: XCTestCase {
    func testExclusiveWaitsForAllHoldersAndExcludesArrivingBuyerThroughCleanup() async throws {
        let gate = AsyncSemaphore(value: 2)
        let events = GateEvents()
        let sharedRelease = GateLatch()
        let cleanupRelease = GateLatch()
        let holders = (0..<2).map { index in
            Task { try await gate.withPermit {
                await events.append("holder\(index)")
                await sharedRelease.wait()
            } }
        }
        try await waitUntil { await events.count == 2 }
        let probe = Task { try await gate.withExclusivePermit {
            await events.append("probe")
            await cleanupRelease.wait()
        } }
        try await waitUntil { await gate.queuedWaiterCount() == 1 }
        let buyer = Task { try await gate.withPermit { await events.append("buyer") } }
        try await waitUntil { await gate.queuedWaiterCount() == 2 }
        let beforeRelease = await events.values
        XCTAssertEqual(beforeRelease.count, 2)
        await sharedRelease.open()
        try await waitUntil { await events.contains("probe") }
        try await settle()
        let duringCleanup = await events.contains("buyer")
        XCTAssertFalse(duringCleanup)
        await cleanupRelease.open()
        for holder in holders { try await holder.value }
        try await probe.value
        try await buyer.value
        let suffix = await Array(events.values.suffix(2))
        XCTAssertEqual(suffix, ["probe", "buyer"])
    }

    func testExclusiveDrainsHoldersAcrossDownResizeToZero() async throws {
        let gate = AsyncSemaphore(value: 2)
        let events = GateEvents()
        let firstRelease = GateLatch()
        let secondRelease = GateLatch()
        let probeRelease = GateLatch()
        let first = Task { try await gate.withPermit {
            await events.append("first")
            await firstRelease.wait()
        } }
        let second = Task { try await gate.withPermit {
            await events.append("second")
            await secondRelease.wait()
        } }
        try await waitUntil { await events.count == 2 }
        await gate.resize(to: 0, stamp: 1)
        let probe = Task { try await gate.withExclusivePermit {
            await events.append("probe")
            await probeRelease.wait()
        } }
        try await waitUntil { await gate.queuedWaiterCount() == 1 }
        await firstRelease.open()
        try await first.value
        let whileSecondHolds = await events.contains("probe")
        XCTAssertFalse(whileSecondHolds, "negative free permits still represent a shared holder")
        await secondRelease.open()
        try await second.value
        try await waitUntil { await events.contains("probe") }
        let buyer = Task { try await gate.withPermit { await events.append("buyer") } }
        try await waitUntil { await gate.queuedWaiterCount() == 1 }
        await probeRelease.open()
        try await probe.value
        let afterExclusive = await events.contains("buyer")
        XCTAssertFalse(afterExclusive, "exclusive release retains the latest zero limit")
        await gate.resize(to: 1, stamp: 2)
        try await buyer.value
    }

    func testCancelingQueuedExclusiveDrainsSharedWaiterWithoutWaitingForHolder() async throws {
        let gate = AsyncSemaphore(value: 2)
        let events = GateEvents()
        let release = GateLatch()
        let holder = Task { try await gate.withPermit {
            await events.append("holder")
            await release.wait()
        } }
        try await waitUntil { await events.contains("holder") }
        let probe = Task { try await gate.withExclusivePermit { await events.append("probe") } }
        try await waitUntil { await gate.queuedWaiterCount() == 1 }
        let buyer = Task { try await gate.withPermit { await events.append("buyer") } }
        try await waitUntil { await gate.queuedWaiterCount() == 2 }
        let blocked = await events.contains("buyer")
        XCTAssertFalse(blocked, "a free permit must not bypass the queued exclusive")
        probe.cancel()
        do { try await probe.value; XCTFail("canceled exclusive acquired") }
        catch is CancellationError { }
        try await buyer.value
        let probeRan = await events.contains("probe")
        XCTAssertFalse(probeRan)
        await release.open()
        try await holder.value
    }

    func testCanceledExclusiveKeepsBuyerBlockedUntilCleanupAcknowledgesRetirement() async throws {
        let gate = AsyncSemaphore(value: 1)
        let events = GateEvents()
        let cleanup = GateLatch()
        let probe = Task { try await gate.withExclusivePermit {
            await events.append("probe")
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch {
                await events.append("cleanup")
                // Deliberately insensitive to task cancellation, like native retirement.
                await cleanup.wait()
                throw error
            }
        } }
        try await waitUntil { await events.contains("probe") }
        let buyer = Task { try await gate.withPermit { await events.append("buyer") } }
        try await waitUntil { await gate.queuedWaiterCount() == 1 }
        probe.cancel()
        try await waitUntil { await events.contains("cleanup") }
        try await settle()
        let beforeAcknowledgment = await events.contains("buyer")
        XCTAssertFalse(beforeAcknowledgment)
        await cleanup.open()
        do { try await probe.value; XCTFail("expected cancellation") }
        catch is CancellationError { }
        try await buyer.value
    }

    func testResizeDuringExclusiveNeverAdmitsAndReleaseUsesLatestStampedLimit() async throws {
        let gate = AsyncSemaphore(value: 1)
        let events = GateEvents()
        let probeRelease = GateLatch()
        let buyersRelease = GateLatch()
        let probe = Task { try await gate.withExclusivePermit {
            await events.append("probe")
            await probeRelease.wait()
        } }
        try await waitUntil { await events.contains("probe") }
        let buyers = (0..<3).map { index in Task { try await gate.withPermit {
            await events.append("buyer\(index)")
            await buyersRelease.wait()
        } } }
        try await waitUntil { await gate.queuedWaiterCount() == 3 }
        await gate.resize(to: 4, stamp: 2)
        await gate.resize(to: 2, stamp: 3)
        await gate.resize(to: 8, stamp: 2)
        try await settle()
        let duringExclusive = await events.count
        XCTAssertEqual(duringExclusive, 1)
        let limit = await gate.currentLimit()
        XCTAssertEqual(limit, 2)
        await probeRelease.open()
        try await probe.value
        try await waitUntil { await events.count == 3 }
        try await settle()
        let admitted = await events.count
        XCTAssertEqual(admitted, 3, "only two buyers enter after exclusive resize to two")
        await buyersRelease.open()
        for buyer in buyers { try await buyer.value }
    }

    func testFIFOAllowsQueuedSharedBeforeNextExclusiveWithoutStarvingEither() async throws {
        let gate = AsyncSemaphore(value: 1)
        let events = GateEvents()
        let release = GateLatch()
        let initial = Task { try await gate.withExclusivePermit {
            await events.append("initial")
            await release.wait()
        } }
        try await waitUntil { await events.contains("initial") }
        let first = Task { try await gate.withPermit { await events.append("first") } }
        try await waitUntil { await gate.queuedWaiterCount() == 1 }
        let exclusive = Task { try await gate.withExclusivePermit { await events.append("exclusive") } }
        try await waitUntil { await gate.queuedWaiterCount() == 2 }
        let last = Task { try await gate.withPermit { await events.append("last") } }
        try await waitUntil { await gate.queuedWaiterCount() == 3 }
        await release.open()
        try await initial.value
        try await first.value
        try await exclusive.value
        try await last.value
        let order = await events.values
        XCTAssertEqual(order, ["initial", "first", "exclusive", "last"])
    }

    func testAlreadyCanceledTasksDoNotInvokeSharedOrExclusiveOperation() async throws {
        let gate = AsyncSemaphore(value: 1)
        let start = GateLatch()
        let events = GateEvents()
        let shared = Task {
            await start.wait()
            try await gate.withPermit { await events.append("shared") }
        }
        let exclusive = Task {
            await start.wait()
            try await gate.withExclusivePermit { await events.append("exclusive") }
        }
        shared.cancel()
        exclusive.cancel()
        await start.open()
        for task in [shared, exclusive] {
            do { try await task.value; XCTFail("expected cancellation") }
            catch is CancellationError { }
        }
        try await gate.withPermit { await events.append("subsequent") }
        let order = await events.values
        XCTAssertEqual(order, ["subsequent"], "canceled acquisitions do not leak ownership")
    }

    func testFailClosedRejectsQueuedAndFutureAcquisitionsDespiteResizeAndRelease() async throws {
        let gate = AsyncSemaphore(value: 1)
        let events = GateEvents()
        let release = GateLatch()
        let holder = Task { try await gate.withExclusivePermit {
            await events.append("holder")
            await release.wait()
        } }
        try await waitUntil { await events.contains("holder") }
        let shared = Task { try await gate.withPermit { await events.append("shared") } }
        let exclusive = Task { try await gate.withExclusivePermit { await events.append("exclusive") } }
        try await waitUntil { await gate.queuedWaiterCount() == 2 }
        await gate.failClosed()
        for task in [shared, exclusive] {
            do { try await task.value; XCTFail("poisoned queued work admitted") }
            catch { XCTAssertEqual(error as? AsyncSemaphore.AdmissionError, .closed) }
        }
        await gate.resize(to: 8, stamp: 20)
        await release.open()
        try await holder.value
        do { try await gate.withPermit { XCTFail("poisoned shared operation ran") }; XCTFail("expected closed") }
        catch { XCTAssertEqual(error as? AsyncSemaphore.AdmissionError, .closed) }
        do { try await gate.withExclusivePermit { XCTFail("poisoned exclusive operation ran") }; XCTFail("expected closed") }
        catch { XCTAssertEqual(error as? AsyncSemaphore.AdmissionError, .closed) }
        let order = await events.values
        XCTAssertEqual(order, ["holder"])
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 30_000_000) }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met")
        throw GateTestError.timedOut
    }
}

private enum GateTestError: Error { case timedOut }

private actor GateEvents {
    private(set) var values: [String] = []
    var count: Int { values.count }
    func append(_ value: String) { values.append(value) }
    func contains(_ value: String) -> Bool { values.contains(value) }
}

private actor GateLatch {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        opened = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
