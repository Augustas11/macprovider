import Foundation
import XCTest
@testable import macprovider_cli

private final class FakeWarmRuntime: WarmModelRuntime, @unchecked Sendable {
    let memoryBudgetMemberID: Int
    init(_ memberID: Int) { memoryBudgetMemberID = memberID }
    func warmSetRowReservation() async -> WarmModelRowReservation { .init(rows: 0, tokensPerRow: 0) }
    func unloadForWarmSet() async {}
}

/// SPEC-001-R016 warm-set table: routing, leases and state rules.
final class WarmModelTableTests: XCTestCase {
    private typealias Table = WarmModelTable<FakeWarmRuntime>

    private func makeTable() throws -> (Table, primary: FakeWarmRuntime, warm: FakeWarmRuntime) {
        let table = Table()
        let primary = FakeWarmRuntime(1)
        let warm = FakeWarmRuntime(2)
        try table.insertPrimary(modelID: "Org/Primary", runtime: primary)
        let token = try table.beginLoading(modelID: "Org/Second", pinned: false)
        try table.finishLoading(token: token, runtime: warm)
        return (table, primary, warm)
    }

    private func assertNotLoaded(_ body: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case .notLoaded = error as? WarmModelTableError else {
                return XCTFail("unexpected \(error)", file: file, line: line)
            }
            XCTAssertEqual((error as? WarmModelTableError)?.reason, "model_not_loaded", file: file, line: line)
        }
    }

    // MARK: Resolve

    func testResolveRules() throws {
        let (table, primary, warm) = try makeTable()
        XCTAssertTrue(try table.resolve(servedModelID: nil).runtime === primary, "absent id: the primary")
        XCTAssertTrue(try table.resolve(servedModelID: "Org/Primary").runtime === primary)
        XCTAssertTrue(try table.resolve(servedModelID: "Org/Second").runtime === warm)
        assertNotLoaded(try table.resolve(servedModelID: "Org/Unknown"))

        _ = try table.beginLoading(modelID: "Org/Loading", pinned: false)
        assertNotLoaded(try table.resolve(servedModelID: "Org/Loading"))
        _ = try table.beginEvicting(modelID: "Org/Second", allowPinned: false)
        assertNotLoaded(try table.resolve(servedModelID: "Org/Second"))
        XCTAssertTrue(try table.resolve(servedModelID: nil).runtime === primary)
    }

    func testResolveWithoutPrimaryIsNotLoaded() {
        assertNotLoaded(try Table().resolve(servedModelID: nil))
        XCTAssertNil(Table().resolveLocal(bodyModel: "x"))
    }

    func testResolveIsCaseFolded() throws {
        let (table, primary, warm) = try makeTable()
        XCTAssertTrue(try table.resolve(servedModelID: "org/second").runtime === warm)
        XCTAssertTrue(try table.resolve(servedModelID: "ORG/PRIMARY").runtime === primary)
        XCTAssertEqual(try table.resolve(servedModelID: "org/second").modelID, "Org/Second")
        XCTAssertEqual(try table.resolve(servedModelID: "org/second").key, "org/second")
        XCTAssertThrowsError(try table.beginLoading(modelID: "ORG/SECOND", pinned: false)) { error in
            XCTAssertEqual(error as? WarmModelTableError, .duplicate(modelID: "ORG/SECOND"))
        }
    }

    func testResolveLocalFallsBackToPrimary() throws {
        let (table, primary, warm) = try makeTable()
        XCTAssertTrue(table.resolveLocal(bodyModel: "org/SECOND")?.runtime === warm)
        XCTAssertTrue(table.resolveLocal(bodyModel: "something-else")?.runtime === primary)
        XCTAssertTrue(table.resolveLocal(bodyModel: nil)?.runtime === primary)
        _ = try table.beginEvicting(modelID: "Org/Second", allowPinned: false)
        XCTAssertTrue(table.resolveLocal(bodyModel: "Org/Second")?.runtime === primary,
                      "an evicting member is not served")
    }

    func testEntriesListPrimaryFirstThenInsertionOrder() throws {
        let table = Table()
        let a = try table.beginLoading(modelID: "A", pinned: true)
        try table.finishLoading(token: a, runtime: FakeWarmRuntime(10))
        _ = try table.beginLoading(modelID: "B", pinned: false)
        try table.insertPrimary(modelID: "P", runtime: FakeWarmRuntime(11))
        let entries = table.entries()
        XCTAssertEqual(entries.map(\.modelID), ["P", "A", "B"])
        XCTAssertEqual(entries.map(\.state), [.warm, .warm, .loading])
        XCTAssertEqual(entries.map(\.primary), [true, false, false])
        XCTAssertEqual(entries.map(\.pinned), [true, true, false])
        XCTAssertEqual(entries.map(\.memberID), [11, 10, nil])
        XCTAssertNil(entries[2].runtime)
        XCTAssertThrowsError(try table.insertPrimary(modelID: "Q", runtime: FakeWarmRuntime(12))) { error in
            XCTAssertEqual(error as? WarmModelTableError, .primaryExists)
        }
    }

    // MARK: Leases

    func testLeaseCountsAndDoubleRelease() throws {
        let clock = TickClock()
        let table = Table(now: { clock.next() })
        try table.insertPrimary(modelID: "P", runtime: FakeWarmRuntime(1))
        let first = try table.lease(servedModelID: nil)
        let second = try table.lease(servedModelID: "p")
        XCTAssertEqual(table.entry(modelID: "P")?.leases, 2)
        let stamped = table.entry(modelID: "P")!.lastAdmissionAt
        XCTAssertGreaterThan(stamped, 0)
        first.release()
        first.release()
        XCTAssertEqual(table.entry(modelID: "P")?.leases, 1, "a second release is a no-op")
        second.release()
        XCTAssertEqual(table.entry(modelID: "P")?.leases, 0)
        XCTAssertEqual(table.entry(modelID: "P")?.lastAdmissionAt, stamped, "release does not stamp admission")
        let third = try table.lease(servedModelID: nil)
        XCTAssertGreaterThan(table.entry(modelID: "P")!.lastAdmissionAt, stamped)
        third.release()
    }

    func testDeinitReleasesALeaseNeverReleased() throws {
        let (table, _, warm) = try makeTable()
        do {
            let lease = try table.lease(servedModelID: "Org/Second")
            XCTAssertTrue(lease.runtime === warm)
            XCTAssertEqual(table.entry(modelID: "Org/Second")?.leases, 1)
        }
        XCTAssertEqual(table.entry(modelID: "Org/Second")?.leases, 0)
        do {
            let lease = try table.leaseLocal(bodyModel: "nothing")
            lease.release()
        }
        XCTAssertEqual(table.entry(modelID: "Org/Primary")?.leases, 0, "release then deinit counts once")
    }

    func testLoadingAndEvictingMembersRefuseLeases() throws {
        let (table, _, _) = try makeTable()
        let loading = try table.beginLoading(modelID: "Org/Third", pinned: false)
        assertNotLoaded(try table.lease(servedModelID: "Org/Third"))
        _ = try table.beginEvicting(modelID: "Org/Second", allowPinned: false)
        assertNotLoaded(try table.lease(servedModelID: "Org/Second"))
        XCTAssertEqual(table.entry(modelID: "Org/Second")?.leases, 0)
        table.cancelLoading(token: loading)
        XCTAssertNil(table.entry(modelID: "Org/Third"))
    }

    func testConcurrentLeaseAndReleaseKeepsCountsExact() throws {
        let (table, _, _) = try makeTable()
        let held = LeaseBox()
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            let id: String? = i % 3 == 0 ? nil : (i % 3 == 1 ? "org/second" : "Org/Primary")
            guard let lease = try? table.lease(servedModelID: id) else { return XCTFail("lease refused") }
            if i % 4 == 0 {
                held.append(lease)
            } else if i % 4 == 1 {
                lease.release()
                lease.release()
            } else if i % 4 == 2 {
                lease.release()
            }
            // i % 4 == 3: dropped, released by deinit.
        }
        let kept = held.all()
        let expectedSecond = kept.filter { $0.modelID == "Org/Second" }.count
        XCTAssertEqual(table.entry(modelID: "Org/Second")?.leases, expectedSecond)
        XCTAssertEqual(table.entry(modelID: "Org/Primary")?.leases, kept.count - expectedSecond)
        DispatchQueue.concurrentPerform(iterations: kept.count) { kept[$0].release() }
        XCTAssertEqual(table.entry(modelID: "Org/Second")?.leases, 0)
        XCTAssertEqual(table.entry(modelID: "Org/Primary")?.leases, 0)
    }

    // MARK: State rules

    func testEvictionRules() throws {
        let (table, _, _) = try makeTable()
        func reason(_ body: () throws -> Any) -> String? {
            do { _ = try body(); return nil } catch { return (error as? WarmModelTableError)?.reason }
        }
        XCTAssertEqual(reason { try table.beginEvicting(modelID: "Org/Primary", allowPinned: true) }, "primary")
        let lease = try table.lease(servedModelID: "Org/Second")
        XCTAssertEqual(reason { try table.beginEvicting(modelID: "Org/Second", allowPinned: false) }, "busy")
        lease.release()

        let pinned = try table.beginLoading(modelID: "Org/Pinned", pinned: true)
        XCTAssertEqual(reason { try table.beginEvicting(modelID: "Org/Pinned", allowPinned: true) }, "not_warm",
                       "a loading member is not evicted")
        try table.finishLoading(token: pinned, runtime: FakeWarmRuntime(3))
        XCTAssertEqual(reason { try table.beginEvicting(modelID: "Org/Pinned", allowPinned: false) }, "pinned")
        XCTAssertEqual(reason { try table.beginEvicting(modelID: "Org/Absent", allowPinned: true) }, "model_not_loaded")

        let evicting = try table.beginEvicting(modelID: "Org/Second", allowPinned: false)
        XCTAssertEqual(evicting.state, .evicting)
        XCTAssertEqual(reason { try table.beginEvicting(modelID: "Org/Second", allowPinned: false) }, "not_warm")
        table.cancelEvicting(token: evicting.token)
        XCTAssertEqual(table.entry(modelID: "Org/Second")?.state, .warm)
        XCTAssertEqual(try table.beginEvicting(modelID: "Org/Pinned", allowPinned: true).state, .evicting)
        table.finishEvicting(token: try table.beginEvicting(modelID: "Org/Second", allowPinned: false).token)
        XCTAssertNil(table.entry(modelID: "Org/Second"))
    }

    func testBeginEvictingByMemberIDsIsAllOrNothing() throws {
        let (table, _, _) = try makeTable()
        let third = try table.beginLoading(modelID: "Org/Third", pinned: false)
        try table.finishLoading(token: third, runtime: FakeWarmRuntime(3))
        let lease = try table.lease(servedModelID: "Org/Third")
        XCTAssertThrowsError(try table.beginEvicting(memberIDs: [2, 3]))
        XCTAssertEqual(table.entry(modelID: "Org/Second")?.state, .warm, "nothing marked when one member is busy")
        XCTAssertThrowsError(try table.beginEvicting(memberIDs: [2, 99]))
        XCTAssertThrowsError(try table.beginEvicting(memberIDs: [1]), "the primary is never evicted")
        lease.release()
        XCTAssertEqual(try table.beginEvicting(memberIDs: [3, 2]).map(\.modelID), ["Org/Third", "Org/Second"])
    }

    func testFinishLoadingRequiresALoadingEntry() throws {
        let (table, _, _) = try makeTable()
        let token = try table.resolve(servedModelID: "Org/Second").token
        XCTAssertThrowsError(try table.finishLoading(token: token, runtime: FakeWarmRuntime(9)))
        table.cancelLoading(token: token)
        XCTAssertNotNil(table.entry(modelID: "Org/Second"), "cancelLoading leaves a warm member alone")
        table.finishEvicting(token: token)
        XCTAssertNotNil(table.entry(modelID: "Org/Second"), "finishEvicting needs an evicting member")
    }

    // MARK: Primary re-key

    /// SPEC-011 R-3.10.3: the member becomes the pinned primary, the old
    /// primary an unpinned warm member; leases stay where they were taken.
    func testPromoteMovesThePrimaryAndPinning() throws {
        let (table, primary, warm) = try makeTable()
        let onPrimary = try table.lease(servedModelID: nil)
        let onSecond = try table.lease(servedModelID: "org/second")
        let promoted = try table.promote(modelID: "ORG/SECOND")
        XCTAssertEqual(promoted.old.modelID, "Org/Primary")
        XCTAssertEqual(promoted.new.modelID, "Org/Second")
        XCTAssertEqual(table.entries().map(\.modelID), ["Org/Second", "Org/Primary"])
        XCTAssertEqual(table.entries().map(\.pinned), [true, false])
        XCTAssertEqual(table.memberViews().map(\.primary), [true, false])
        XCTAssertTrue(table.primaryRuntime() === warm)
        XCTAssertTrue(try table.resolve(servedModelID: nil).runtime === warm)
        XCTAssertTrue(try table.resolve(servedModelID: "org/primary").runtime === primary)
        XCTAssertEqual(table.entry(modelID: "Org/Primary")?.leases, 1)
        XCTAssertEqual(table.entry(modelID: "Org/Second")?.leases, 1)
        XCTAssertTrue(onPrimary.runtime === primary, "a lease keeps its member")
        XCTAssertEqual(WarmModelTable<FakeWarmRuntime>.memberKey(token: onSecond.token),
                       WarmModelTable<FakeWarmRuntime>.memberKey(token: promoted.new.token))
        onPrimary.release()
        onSecond.release()
        // The demoted primary may now be evicted once idle.
        XCTAssertEqual(try table.beginEvicting(modelID: "Org/Primary", allowPinned: false).state, .evicting)
    }

    func testPromoteRefusesThePrimaryAndANonWarmMember() throws {
        let (table, _, _) = try makeTable()
        assertNotLoaded(try table.promote(modelID: "org/primary"))
        assertNotLoaded(try table.promote(modelID: "org/absent"))
        _ = try table.beginLoading(modelID: "Org/Third", pinned: false)
        assertNotLoaded(try table.promote(modelID: "org/third"))
        _ = try table.beginEvicting(modelID: "Org/Second", allowPinned: false)
        assertNotLoaded(try table.promote(modelID: "org/second"))
        XCTAssertEqual(table.entries().first?.modelID, "Org/Primary")
    }

    func testPrimaryRekeyAfterWarmSwap() throws {
        let (table, primary, _) = try makeTable()
        let lease = try table.lease(servedModelID: nil)
        try table.rekeyPrimary(to: "Org/Swapped")
        XCTAssertTrue(try table.resolve(servedModelID: "org/swapped").runtime === primary)
        assertNotLoaded(try table.resolve(servedModelID: "Org/Primary"))
        XCTAssertEqual(table.entries().first?.modelID, "Org/Swapped")
        XCTAssertEqual(table.entry(modelID: "Org/Swapped")?.leases, 1, "leases follow the primary")
        lease.release()
        XCTAssertEqual(table.entry(modelID: "Org/Swapped")?.leases, 0)
        XCTAssertThrowsError(try table.rekeyPrimary(to: "ORG/SECOND")) { error in
            XCTAssertEqual(error as? WarmModelTableError, .duplicate(modelID: "ORG/SECOND"))
        }
        try table.rekeyPrimary(to: "ORG/SWAPPED")
        XCTAssertEqual(table.entries().first?.modelID, "ORG/SWAPPED")
        XCTAssertThrowsError(try Table().rekeyPrimary(to: "x"))
    }
}

private final class LeaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var leases: [WarmModelLease<FakeWarmRuntime>] = []
    func append(_ lease: WarmModelLease<FakeWarmRuntime>) { lock.lock(); leases.append(lease); lock.unlock() }
    func all() -> [WarmModelLease<FakeWarmRuntime>] { lock.lock(); defer { lock.unlock() }; return leases }
}

private final class TickClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 100
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
