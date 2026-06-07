import Foundation
import XCTest
@testable import macprovider_cli

final class SwitchStateStoreTests: XCTestCase {
    func testReadReturnsNilWhenFileMissing() throws {
        let store = SwitchStateStore(path: try makeStatePath())

        XCTAssertNil(store.readLastSwitchMs())
    }

    func testReadReturnsNilWhenFileCorrupt() throws {
        let path = try makeStatePath()
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not a number".write(to: path, atomically: false, encoding: .utf8)

        XCTAssertNil(SwitchStateStore(path: path).readLastSwitchMs())
    }

    func testWriteAndReadRoundTrip() throws {
        let store = SwitchStateStore(path: try makeStatePath())

        try store.writeLastSwitchMs(1_717_696_989_123)

        XCTAssertEqual(store.readLastSwitchMs(), 1_717_696_989_123)
    }

    func testWriteCreatesParentDirectory() throws {
        let dir = try makeTempDirectory().appendingPathComponent("missing/grandparent")
        let store = SwitchStateStore(path: dir.appendingPathComponent("last-switch.ts"))

        try store.writeLastSwitchMs(42)

        XCTAssertEqual(store.readLastSwitchMs(), 42)
    }

    func testWriteIsAtomic() throws {
        let path = try makeStatePath()
        let store = SwitchStateStore(path: path)

        try store.writeLastSwitchMs(1)
        try store.writeLastSwitchMs(2)

        XCTAssertEqual(store.readLastSwitchMs(), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path + ".tmp"))
    }

    func testCooldownDecisionClearWhenNeverSet() throws {
        let store = SwitchStateStore(path: try makeStatePath())

        XCTAssertEqual(store.cooldownDecision(now: 1_000), .clear)
    }

    func testCooldownDecisionClearWhenWellOutsideWindow() throws {
        let store = SwitchStateStore(path: try makeStatePath())
        try store.writeLastSwitchMs(0)

        XCTAssertEqual(store.cooldownDecision(now: 1_000_000), .clear)
    }

    func testCooldownDecisionCooldownWhenInsideWindow() throws {
        let store = SwitchStateStore(path: try makeStatePath())
        try store.writeLastSwitchMs(1_000_000)

        XCTAssertEqual(store.cooldownDecision(now: 1_005_000), .cooldown(secondsRemaining: 5))
    }

    func testCooldownDecisionCooldownWhenJustInsideWindow() throws {
        let store = SwitchStateStore(path: try makeStatePath())
        try store.writeLastSwitchMs(1_000_000)

        XCTAssertEqual(store.cooldownDecision(now: 1_009_999), .cooldown(secondsRemaining: 1))
    }

    func testCooldownDecisionClearAtExactlyWindowBoundary() throws {
        let store = SwitchStateStore(path: try makeStatePath())
        try store.writeLastSwitchMs(1_000_000)

        XCTAssertEqual(store.cooldownDecision(now: 1_010_000), .clear)
    }

    func testCustomCooldownWindow() throws {
        let store = SwitchStateStore(path: try makeStatePath(), cooldownWindowMs: 5_000)
        try store.writeLastSwitchMs(1_000_000)

        XCTAssertEqual(store.cooldownDecision(now: 1_004_999), .cooldown(secondsRemaining: 1))
        XCTAssertEqual(store.cooldownDecision(now: 1_005_000), .clear)
    }

    private func makeStatePath() throws -> URL {
        try makeTempDirectory().appendingPathComponent("last-switch.ts")
    }

    private func makeTempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("mpm-switch-state-\(getpid())-\(Int.random(in: 0 ... 999_999))")
        try? FileManager.default.removeItem(at: dir)
        return dir
    }
}
