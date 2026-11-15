import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-001-R019: a further warm member's self-check holds that member
/// alone. The primary's slots, admission and in-flight work are never
/// touched; the member reports no free slot for the check and drains only
/// its own requests admitted before it.
final class WarmMemberSelfCheckHoldTests: XCTestCase {
    private struct Rig {
        let status = ProviderStatus(
            modelID: "model-a", modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 8_000, maxConcurrencyOverride: 2))
        let table = WarmModelTable<WarmFakeRuntime>()
        let memberToken: UInt64

        init() throws {
            try table.insertPrimary(modelID: "model-a", runtime: WarmFakeRuntime(memberID: 1, modelID: "model-a", hash: "a"))
            memberToken = try table.beginLoading(modelID: "model-b", pinned: false)
            try table.finishLoading(token: memberToken, runtime: WarmFakeRuntime(memberID: 2, modelID: "model-b", hash: "b"))
            table.updateInfo(token: memberToken, WarmModelMemberInfo(maxContextTokens: 4_000, slotsTotal: 3))
        }

        func memberHold(allowed: @escaping @Sendable () async -> Bool = { true }) -> WarmMemberSelfCheckAdmissionHold {
            WarmMemberSelfCheckAdmissionHold(memberID: 2, hold: table, providerStatus: status, allowed: allowed)
        }

        var memberView: WarmModelMemberView? { table.views.value.first { $0.modelID == "model-b" } }
    }

    private actor Seen {
        var values: [String: String] = [:]
        func set(_ key: String, _ value: String) { values[key] = value }
    }

    func testAMemberCheckClosesOnlyThatMemberAndNeverPausesThePrimary() async throws {
        let rig = try Rig()
        // A primary request in flight for the whole check.
        guard case .admitted(let primaryStart) = await rig.status.admitRequest(requestID: "primary-1") else {
            return XCTFail("primary request refused")
        }
        // A member request admitted before the hold: the drain waits for it.
        let predating = try rig.table.lease(servedModelID: "model-b")
        let before = await rig.status.snapshot()
        XCTAssertEqual(before.slotsFree, 1)

        let seen = Seen()
        let hold = rig.memberHold()
        let table = rig.table
        let status = rig.status
        let task = Task {
            await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
                scope: hold, drainSeconds: 5, checkSeconds: 5, lifecycleLease: { nil },
                context: "test", log: { _ in }
            ) {
                let snapshot = await status.snapshot()
                let view = table.views.value.first { $0.modelID == "model-b" }
                await seen.set("primary_slots_free", "\(snapshot.slotsFree)")
                await seen.set("primary_hold_active", "\(snapshot.cbSelfCheckAdmissionHold?.active == true)")
                await seen.set("primary_in_flight", "\(snapshot.primaryRequestsInFlight)")
                await seen.set("member_slots_free", "\(view?.slotsFree.map(String.init) ?? "nil")")
                await seen.set("member_leases", "\(view?.inFlight ?? -1)")
                // A primary request arriving now is admitted and counted.
                if case .admitted(let start) = await status.admitRequest(requestID: "primary-2") {
                    await seen.set("primary_slots_free_after_admit", "\(await status.snapshot().slotsFree)")
                    await status.finishRequest(startedAt: start, completion: nil, failed: false, requestID: "primary-2")
                }
                return true
            }
        }
        // The member is closed as soon as the hold starts.
        try await eventually { rig.memberView?.selfCheckHeld == true }
        XCTAssertEqual(rig.memberView?.slotsFree, 0)
        let duringHold = await rig.status.snapshot()
        XCTAssertEqual(duringHold.slotsFree, 1, "the primary's slots never move")
        XCTAssertEqual(duringHold.cbSelfCheckAdmissionHold?.active, false)
        // A member request arriving during the hold queues behind the check
        // and does not hold up its drain.
        let arrival = try rig.table.lease(servedModelID: "model-b")
        try await Task.sleep(nanoseconds: 200_000_000)
        let drainedYet = await seen.values["member_slots_free"]
        XCTAssertNil(drainedYet, "the check ran before the member's own earlier request finished")
        predating.release()
        let outcome = await task.value
        XCTAssertEqual(outcome, .completed)
        let values = await seen.values
        XCTAssertEqual(values["primary_slots_free"], "1")
        XCTAssertEqual(values["primary_hold_active"], "false")
        XCTAssertEqual(values["primary_in_flight"], "1", "the primary's request was not drained")
        XCTAssertEqual(values["primary_slots_free_after_admit"], "0")
        XCTAssertEqual(values["member_slots_free"], "0")
        XCTAssertEqual(values["member_leases"], "1", "only the arrival is in flight on the member")
        // Re-opened after the check.
        XCTAssertEqual(rig.memberView?.selfCheckHeld, false)
        XCTAssertEqual(rig.memberView?.slotsFree, 2)
        arrival.release()
        XCTAssertEqual(rig.memberView?.slotsFree, 3)
        let after = await rig.status.snapshot()
        XCTAssertEqual(after.slotsFree, 1)
        XCTAssertEqual(after.cbSelfCheckAdmissionHold?.holdsTotal, 0, "the provider-wide hold never ran")
        await rig.status.finishRequest(startedAt: primaryStart, completion: nil, failed: false, requestID: "primary-1")
    }

    /// It never overlaps a load, eviction or swap: refused while one runs,
    /// and the check yields the moment one starts.
    func testAMemberHoldIsRefusedDuringAWarmSetChangeAndYieldsToOne() async throws {
        let rig = try Rig()
        let refused = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            scope: rig.memberHold(allowed: { false }), drainSeconds: 1, checkSeconds: 1, lifecycleLease: { nil },
            context: "test", log: { _ in }
        ) { XCTFail("the check ran during a warm-set change"); return true }
        XCTAssertEqual(refused, .skipped(reason: "warm_set_busy"))
        XCTAssertEqual(rig.memberView?.selfCheckHeld, false)

        let busy = LockedFlag()
        let yielded = await ContinuousBatchingSelfCheck.runUnderAdmissionHold(
            scope: rig.memberHold(allowed: { !busy.value }), drainSeconds: 1, checkSeconds: 5, lifecycleLease: { nil },
            context: "test", log: { _ in }
        ) {
            busy.set()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return true
        }
        XCTAssertEqual(yielded, .yielded)
        XCTAssertEqual(rig.memberView?.selfCheckHeld, false)
        XCTAssertEqual(rig.memberView?.slotsFree, 3)
    }

    func testThePrimaryAndAHeldMemberRefuseASecondHold() throws {
        let rig = try Rig()
        XCTAssertEqual(rig.table.beginSelfCheckHold(memberID: 1), "primary")
        XCTAssertNil(rig.table.beginSelfCheckHold(memberID: 2))
        XCTAssertEqual(rig.table.beginSelfCheckHold(memberID: 2), "already_held")
        rig.table.endSelfCheckHold(memberID: 2)
        XCTAssertEqual(rig.memberView?.selfCheckHeld, false)
        XCTAssertEqual(rig.table.beginSelfCheckHold(memberID: 9), "not_in_warm_set")
    }

    /// A lease taken during one hold and released during the next does not
    /// count against the next hold's arrivals.
    func testHoldArrivalsBelongToTheirOwnHold() throws {
        let rig = try Rig()
        XCTAssertNil(rig.table.beginSelfCheckHold(memberID: 2))
        let first = try rig.table.lease(servedModelID: "model-b")
        XCTAssertEqual(rig.table.selfCheckHoldWork(memberID: 2).predatingHold, 0)
        rig.table.endSelfCheckHold(memberID: 2)
        XCTAssertNil(rig.table.beginSelfCheckHold(memberID: 2))
        XCTAssertEqual(rig.table.selfCheckHoldWork(memberID: 2).predatingHold, 1, "earlier than this hold")
        let second = try rig.table.lease(servedModelID: "model-b")
        first.release()
        XCTAssertEqual(rig.table.selfCheckHoldWork(memberID: 2).inFlight, 1)
        XCTAssertEqual(rig.table.selfCheckHoldWork(memberID: 2).predatingHold, 0)
        second.release()
        rig.table.endSelfCheckHold(memberID: 2)
    }

    /// The driver takes the provider-wide hold while its runtime is the
    /// primary (exactly today's check), its member's hold otherwise.
    func testTheDriverHoldsTheProviderOnlyWhileItsRuntimeIsThePrimary() throws {
        let rig = try Rig()
        let member = rig.memberHold()
        XCTAssertTrue(ContinuousBatchingSelfCheckDriver.admissionHoldScope(
            isPrimary: true, member: member, providerStatus: rig.status) is ProcessSelfCheckAdmissionHold)
        XCTAssertTrue(ContinuousBatchingSelfCheckDriver.admissionHoldScope(
            isPrimary: true, member: nil, providerStatus: rig.status) is ProcessSelfCheckAdmissionHold)
        XCTAssertTrue(ContinuousBatchingSelfCheckDriver.admissionHoldScope(
            isPrimary: false, member: nil, providerStatus: rig.status) is ProcessSelfCheckAdmissionHold)
        XCTAssertTrue(ContinuousBatchingSelfCheckDriver.admissionHoldScope(
            isPrimary: false, member: member, providerStatus: rig.status) is WarmMemberSelfCheckAdmissionHold)
    }

    private func eventually(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
