import AppKit
import Foundation
import XCTest
@testable import Malibu

@MainActor
final class AppInstanceHandoffTests: XCTestCase {
    private typealias Identity = AppInstanceHandoff.Identity
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func app(_ pid: Int32, _ version: String?, at offset: TimeInterval = 0) -> Identity {
        Identity(pid: pid, launchedAt: epoch.addingTimeInterval(offset), version: version)
    }

    func testSlowUnregisteredSuccessorIsNeverClassifiedAsLegacy() {
        let old = app(100, "1.8.272")
        let successor = app(101, "1.8.273", at: 1)
        let muchLater = epoch.addingTimeInterval(100)
        XCTAssertNil(AppInstanceHandoff.discoveredIdentity(
            pid: successor.pid, launchedAt: successor.launchedAt,
            record: nil, own: old, now: muchLater
        ))
        // Merely publishing a launch identity cannot displace the serving
        // predecessor: the new process must acknowledge its successful claim.
        XCTAssertNil(AppInstanceHandoff.discoveredIdentity(
            pid: successor.pid, launchedAt: successor.launchedAt,
            record: successor, recordReady: false, own: old, now: muchLater
        ))
        XCTAssertEqual(AppInstanceHandoff.discoveredIdentity(
            pid: successor.pid, launchedAt: successor.launchedAt,
            record: successor, own: old, now: muchLater
        ), successor)
        // A stale record for a recycled PID provides no permission either.
        XCTAssertNil(AppInstanceHandoff.discoveredIdentity(
            pid: successor.pid, launchedAt: successor.launchedAt,
            record: app(successor.pid, "1.8.271", at: -10), own: old, now: muchLater
        ))
    }

    func testOnlyPreexistingMissingRecordsAreLegacy() {
        let current = app(101, "1.8.273", at: 10)
        let old = app(100, nil)
        XCTAssertEqual(AppInstanceHandoff.discoveredIdentity(
            pid: old.pid, launchedAt: old.launchedAt,
            record: nil, own: current, now: epoch.addingTimeInterval(100)
        ), old)
        XCTAssertNil(AppInstanceHandoff.discoveredIdentity(
            pid: 102, launchedAt: current.launchedAt,
            record: nil, own: current, now: epoch.addingTimeInterval(100)
        ))
    }

    func testAcknowledgementFailureDoesNotAskPredecessorToQuit() async {
        let old = app(100, "1.8.272")
        let current = app(101, "1.8.273", at: 10)
        var ownQuit = false
        let handoff = AppInstanceHandoff(
            own: current, peers: { [old] },
            terminate: { _, _ in XCTFail("unacknowledged successor must preserve predecessor"); return false },
            quitSelf: { ownQuit = true }, clock: { 0 }, log: { _ in },
            publishReady: { throw CocoaError(.fileWriteNoPermission) }
        )
        let claimed = await handoff.claim()
        XCTAssertFalse(claimed)
        XCTAssertTrue(ownQuit)
    }

    func testSecondLaunchWinsAtSameVersionWithDeterministicTieBreak() {
        let old = app(100, "1.8.272")
        let new = app(101, "1.8.272", at: 1)
        XCTAssertEqual(AppInstanceHandoff.winner(in: [new, old]), new)
        XCTAssertEqual(AppInstanceHandoff.winner(in: [old, new]), new)
        XCTAssertEqual(AppInstanceHandoff.winner(in: [old, app(102, "1.8.272")])?.pid, 102)
    }

    func testRollbackCannotDisplaceNewerInMemoryVersion() {
        let current = app(100, "1.8.273")
        let rollback = app(101, "1.8.272", at: 100)
        XCTAssertEqual(AppInstanceHandoff.winner(in: [rollback, current]), current)
        var quit = false
        var signals = 0
        let handoff = AppInstanceHandoff(
            own: rollback, peers: { [current] },
            terminate: { _, _ in signals += 1; return true },
            quitSelf: { quit = true }, clock: { 0 }, log: { _ in }
        )
        XCTAssertFalse(handoff.tick())
        XCTAssertTrue(quit)
        XCTAssertEqual(signals, 0)
    }

    func testHungDrainIsForcedAndExitIsVerified() {
        let old = app(100, "1.8.272")
        let current = app(101, "1.8.273", at: 100)
        var running = [old]
        var now: TimeInterval = 0
        var signals: [Bool] = []
        var logs: [String] = []
        let handoff = AppInstanceHandoff(
            own: current, peers: { running },
            terminate: { target, force in
                XCTAssertEqual(target, old)
                signals.append(force)
                if force { running.removeAll() }
                return true
            }, quitSelf: { XCTFail("successor must remain running") },
            clock: { now }, log: { logs.append($0) }
        )
        XCTAssertTrue(handoff.tick())
        XCTAssertEqual(signals, [false])
        now = 39.9
        handoff.tick()
        XCTAssertEqual(signals, [false])
        now = 40
        handoff.tick()
        XCTAssertEqual(signals, [false, true])
        handoff.tick()
        XCTAssertEqual(running.count + 1, 1)
        XCTAssertTrue(logs.contains { $0.contains("PID 100 exited") })
    }

    func testGracefulExitNeverForcesAndLegacyPeersAreRetired() {
        let legacy = app(100, nil)
        let current = app(101, "1.8.273", at: 100)
        var running = [legacy]
        var signals: [Bool] = []
        let handoff = AppInstanceHandoff(
            own: current, peers: { running },
            terminate: { _, force in signals.append(force); return true },
            quitSelf: { XCTFail() }, clock: { 100 }, log: { _ in }
        )
        handoff.tick()
        running = []
        handoff.tick()
        XCTAssertEqual(signals, [false])
    }

    func testElectionIsRepeatedBeforeEscalation() {
        let old = app(100, "1.8.272")
        let current = app(101, "1.8.273", at: 100)
        let newer = app(102, "1.8.274", at: 200)
        var running = [old]
        var now: TimeInterval = 0
        var quit = false
        var signals: [Int32] = []
        let handoff = AppInstanceHandoff(
            own: current, peers: { running },
            terminate: { identity, _ in signals.append(identity.pid); return true },
            quitSelf: { quit = true }, clock: { now }, log: { _ in }
        )
        handoff.tick()
        running.append(newer)
        now = 40
        XCTAssertFalse(handoff.tick())
        XCTAssertTrue(quit)
        XCTAssertEqual(signals, [old.pid])
        XCTAssertFalse(handoff.tick())
        XCTAssertEqual(signals, [old.pid])
    }

    func testReusedPIDDoesNotInheritOldGraceDeadline() {
        let old = app(100, "1.8.272")
        let replacement = app(100, "1.8.272", at: 20)
        let current = app(101, "1.8.273", at: 100)
        var running = [old]
        var now: TimeInterval = 0
        var forced: [Identity] = []
        let handoff = AppInstanceHandoff(
            own: current, peers: { running },
            terminate: { identity, force in if force { forced.append(identity) }; return true },
            quitSelf: { XCTFail() }, clock: { now }, log: { _ in }
        )
        handoff.tick()
        running = [replacement]
        now = 40
        handoff.tick()
        XCTAssertEqual(forced, [])
        now = 80
        handoff.tick()
        XCTAssertEqual(forced, [replacement])
    }

    func testForceRefusalAndSurvivingPIDAreLoggedOnce() {
        let old = app(100, "1.8.272")
        let current = app(101, "1.8.273", at: 100)
        var now: TimeInterval = 0
        var logs: [String] = []
        let handoff = AppInstanceHandoff(
            own: current, peers: { [old] }, terminate: { _, _ in false },
            quitSelf: { XCTFail() }, clock: { now }, log: { logs.append($0) }
        )
        handoff.tick()
        now = 40
        handoff.tick()
        now = 45
        handoff.tick()
        now = 50
        handoff.tick()
        XCTAssertEqual(logs.filter { $0.contains("refused") }.count, 1)
        XCTAssertEqual(logs.filter { $0.contains("still running") }.count, 1)
    }

    func testLegacyHungQuitWithoutHandshakeIsForcedAtExistingDeadline() {
        let current = app(101, "1.8.274", at: 100)
        var now: TimeInterval = 0
        var running = true
        var signals: [Bool] = []
        let handoff = AppInstanceHandoff(
            own: current,
            peers: {
                guard running else { return [] }
                return [AppInstanceHandoff.discoveredIdentity(
                    pid: 100, launchedAt: self.epoch, record: nil,
                    own: current, now: self.epoch.addingTimeInterval(100 + now)
                )].compactMap { $0 }
            },
            terminate: { _, force in
                signals.append(force)
                // Legacy terminateLater never completes. Only force exits it.
                if force { running = false }
                return true
            },
            quitSelf: { XCTFail("successor must survive") }, clock: { now }, log: { _ in }
        )
        handoff.tick()
        now = 39.9
        handoff.tick()
        XCTAssertEqual(signals, [false])
        now = 40
        handoff.tick()
        handoff.tick()
        XCTAssertEqual(signals, [false, true])
        XCTAssertFalse(running)
    }

    func testDiscoveryAndSignalValidationAcceptNoncanonicalRunningBundle() throws {
        // The real XCTest app host lives in DerivedData, outside either
        // canonical install path. Activation and arbitrary moves must use
        // the same path-independent running-process validation.
        let host = NSRunningApplication.current
        let date = try XCTUnwrap(host.launchDate)
        let url = try XCTUnwrap(host.bundleURL)
        XCTAssertFalse(CLIUpdateRunner.isUpdaterOwnedMalibuInstall(url))
        let identity = Identity(pid: host.processIdentifier, launchedAt: date, version: "1.8.272")
        var validations: [Int32] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let registry = AppInstanceHandoff.Registry(directory: directory, validatesSignature: {
            validations.append($0)
            return $0 == host.processIdentifier
        })
        try registry.publish(identity, ready: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let successor = Identity(pid: -1, launchedAt: date.addingTimeInterval(10), version: "1.8.274")
        XCTAssertTrue(registry.peers(own: successor).contains(identity))
        XCTAssertNotNil(registry.application(matching: identity))
        XCTAssertGreaterThanOrEqual(validations.filter { $0 == host.processIdentifier }.count, 2)
        let reused = Identity(pid: identity.pid, launchedAt: date.addingTimeInterval(-1), version: nil)
        XCTAssertNil(registry.application(matching: reused))
    }

    func testInvalidRunningSignatureCannotBecomeTerminationTarget() throws {
        let host = NSRunningApplication.current
        let identity = Identity(
            pid: host.processIdentifier, launchedAt: try XCTUnwrap(host.launchDate), version: nil
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let registry = AppInstanceHandoff.Registry(directory: directory, validatesSignature: { _ in false })
        XCTAssertNil(registry.application(matching: identity))
        let successor = Identity(pid: -1, launchedAt: identity.launchedAt.addingTimeInterval(10), version: "1.8.274")
        XCTAssertFalse(registry.peers(own: successor).contains(identity))
    }

    func testSimilarNamedNonMalibuProcessIsNeverTargeted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lookalike = directory.appendingPathComponent("Malibu-helper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: lookalike)
        let process = Process()
        process.executableURL = lookalike
        process.arguments = ["10"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let registry = AppInstanceHandoff.Registry(validatesSignature: { _ in
            XCTFail("non-Malibu bundle must be rejected before signature validation")
            return true
        })
        let identity = Identity(pid: process.processIdentifier, launchedAt: Date(), version: nil)
        XCTAssertNil(registry.application(matching: identity))
        XCTAssertFalse(AppInstanceHandoff.Registry.isSignedMalibu(process.processIdentifier))
        XCTAssertTrue(process.isRunning)
    }

}
