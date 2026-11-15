import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-001-R018 advertised capacity: each `warm_models` entry's
/// `throughput_tps_estimate` is its member's rate under the measured GPU
/// contention, never its solo rate while a sibling is busy.
final class WarmSetContentionTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    private func window(busy: [Int: UInt64], wait: [Int: UInt64] = [:], wall: UInt64 = 10) -> WarmSetContentionWindow {
        WarmSetContentionWindow(
            wallNanoseconds: wall * second,
            busyNanoseconds: busy.mapValues { $0 * second },
            waitNanoseconds: wait.mapValues { $0 * second })
    }

    func testNoBusySiblingKeepsTheSoloRate() {
        let w = window(busy: [1: 8], wait: [1: 0])
        XCTAssertNil(w.share(of: 1, siblings: [1, 2]))
        XCTAssertEqual(w.estimate(solo: 40, memberID: 1, members: [1, 2]), 40)
        XCTAssertEqual(w.estimate(solo: 40, memberID: 1, members: [1]), 40, "a warm set of one is never scaled")
        XCTAssertEqual(w.estimate(solo: 40, memberID: nil, members: [1, 2]), 40)
    }

    func testAMemberDecodingBesideABusySiblingGetsTheShareItHeld() {
        let w = window(busy: [1: 3, 2: 6], wait: [1: 3, 2: 1])
        XCTAssertEqual(w.share(of: 1, siblings: [1, 2]) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(w.estimate(solo: 40, memberID: 1, members: [1, 2]), 20)
        XCTAssertEqual(w.estimate(solo: 30, memberID: 2, members: [1, 2]), 25.7)
    }

    func testAnIdleMemberGetsTheTimeItsSiblingsLeaveButNeverLessThanAnEvenSplit() {
        let light = window(busy: [2: 2])
        XCTAssertEqual(light.share(of: 1, siblings: [1, 2]) ?? -1, 0.8, accuracy: 1e-9)
        let saturated = window(busy: [2: 10, 3: 10])
        XCTAssertEqual(saturated.share(of: 1, siblings: [1, 2, 3]) ?? -1, 1.0 / 3, accuracy: 1e-9)
        // A busy participant outside the warm set (not a member) is not a sibling.
        XCTAssertNil(window(busy: [9: 10]).share(of: 1, siblings: [1, 2]))
    }

    func testTheMeterReportsTheLastCompletedWindowOfAtLeastFiveSeconds() {
        let state = MeterState()
        let meter = WarmSetContentionMeter(counters: { state.counters }, clock: { state.now })
        XCTAssertNil(meter.window(), "no window before a base exists")
        state.advance(seconds: 2, busy: [1: 2, 2: 1], wait: [1: 1])
        XCTAssertNil(meter.window(), "the first window is not complete yet")
        state.advance(seconds: 4, busy: [1: 2, 2: 3], wait: [1: 2])
        let first = try? XCTUnwrap(meter.window())
        XCTAssertEqual(first?.wallNanoseconds, 6 * second)
        XCTAssertEqual(first?.busyNanoseconds[1], 4 * second)
        XCTAssertEqual(first?.waitNanoseconds[1], 3 * second)
        XCTAssertEqual(first?.busyNanoseconds[2], 4 * second)
        state.advance(seconds: 1, busy: [1: 1], wait: [:])
        XCTAssertEqual(meter.window(), first, "a shorter span keeps the last completed window")
    }

    func testAProbeSharingTheGPUIsDividedOutToTheSoloRate() {
        XCTAssertEqual(WarmSetContentionMeter.soloRate(measured: 20, busyNanoseconds: 2 * second, waitNanoseconds: 2 * second), 40)
        XCTAssertEqual(WarmSetContentionMeter.soloRate(measured: 20, busyNanoseconds: 2 * second, waitNanoseconds: 0), 20)
        XCTAssertEqual(WarmSetContentionMeter.soloRate(measured: 0, busyNanoseconds: 2 * second, waitNanoseconds: 2 * second), 0)
    }

    func testEveryEntryIsScaledAndTheTopLevelCarriesThePrimarysContendedEstimate() {
        let info = WarmModelMemberInfo(maxContextTokens: 8_000, slotsTotal: 2, throughputTPSEstimate: 30)
        let views = [
            WarmModelMemberView(
                modelID: "model-a", key: "model-a", state: .warm, primary: true, pinned: true, inFlight: 1,
                info: nil, memberID: 1),
            WarmModelMemberView(
                modelID: "model-b", key: "model-b", state: .warm, primary: false, pinned: false, inFlight: 1,
                info: info, memberID: 2),
        ]
        let fields: [String: Any] = ["model_id": "model-a", "throughput_tps_estimate": 40.0]
        func attached(_ contention: WarmSetContentionWindow?) -> [String: Any] {
            var message = fields
            WarmModelsWire.attach(
                to: &message, primarySlotsTotal: 4, primarySlotsFree: 3, views: views, sessionModels: nil,
                contention: contention)
            return message
        }
        // SPEC-001-R018: the primary's estimate under contention is its
        // contended rate, and R016's top level describes the primary, so
        // both carry the one contended value.
        let contended = attached(window(busy: [1: 3, 2: 6], wait: [1: 3, 2: 1]))
        let entries = contended["warm_models"] as? [[String: Any]]
        XCTAssertEqual(entries?[0]["throughput_tps_estimate"] as? Double, 20)
        XCTAssertEqual(entries?[1]["throughput_tps_estimate"] as? Double, 25.7)
        XCTAssertEqual(contended["throughput_tps_estimate"] as? Double, 20, "the top level is the primary entry's value")

        for idle in [attached(window(busy: [:])), attached(nil)] {
            let entries = idle["warm_models"] as? [[String: Any]]
            XCTAssertEqual(idle["throughput_tps_estimate"] as? Double, 40)
            XCTAssertEqual(entries?[0]["throughput_tps_estimate"] as? Double, 40)
            XCTAssertEqual(entries?[1]["throughput_tps_estimate"] as? Double, 30)
        }

        // A warm set of one is never scaled: today's values exactly.
        var single = fields
        WarmModelsWire.attach(
            to: &single, primarySlotsTotal: 4, primarySlotsFree: 3, views: [views[0]], sessionModels: nil,
            contention: window(busy: [1: 3, 9: 6], wait: [1: 3]))
        XCTAssertEqual(single["throughput_tps_estimate"] as? Double, 40)
        XCTAssertEqual((single["warm_models"] as? [[String: Any]])?.first?["throughput_tps_estimate"] as? Double, 40)
    }

    func testTheTableNamesEachWarmMembersGPUParticipant() throws {
        let table = WarmModelTable<WarmFakeRuntime>()
        try table.insertPrimary(modelID: "model-a", runtime: WarmFakeRuntime(memberID: 41, modelID: "model-a", hash: "aa"))
        let token = try table.beginLoading(modelID: "model-b", pinned: false)
        XCTAssertEqual(table.memberViews().map(\.memberID), [41, nil], "a loading member has no runtime yet")
        try table.finishLoading(token: token, runtime: WarmFakeRuntime(memberID: 42, modelID: "model-b", hash: "bb"))
        XCTAssertEqual(table.memberViews().map(\.memberID), [41, 42])
    }

    private final class MeterState: @unchecked Sendable {
        private let lock = NSLock()
        private var clock: UInt64 = 1_000
        private var values: [Int: GPUTurnParticipantCounters] = [:]
        var now: UInt64 { lock.lock(); defer { lock.unlock() }; return clock }
        var counters: [Int: GPUTurnParticipantCounters] { lock.lock(); defer { lock.unlock() }; return values }
        func advance(seconds: UInt64, busy: [Int: UInt64], wait: [Int: UInt64]) {
            lock.lock(); defer { lock.unlock() }
            clock += seconds * 1_000_000_000
            for (id, b) in busy { values[id, default: .init()].busyNanoseconds += b * 1_000_000_000 }
            for (id, w) in wait { values[id, default: .init()].waitNanoseconds += w * 1_000_000_000 }
        }
    }
}
