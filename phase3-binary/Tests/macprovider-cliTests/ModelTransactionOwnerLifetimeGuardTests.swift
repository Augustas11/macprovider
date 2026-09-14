import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ModelTransactionOwnerLifetimeGuardTests: XCTestCase {
    func testPrepareAndCleanupContentionFenceBeforeIndependentExitWithoutLateRevival() throws {
        for kind in ["prepare_model", "cleanup_staging"] {
            let fixture = try Fixture(kind: kind); defer { fixture.remove() }
            let owner = try fixture.start(mode: "contended")
            try fixture.awaitFile("ready")
            try fixture.assertOwnerBusy()
            XCTAssertEqual(try fixture.wait(owner, seconds: 13), 70)
            let initial = try fixture.timestamps().first.unwrap()
            let fencedAt = try UInt64(String(contentsOf: fixture.root.appendingPathComponent("fenced"))).unwrap()
            XCTAssertGreaterThanOrEqual(fencedAt - initial, 8_000_000_000)
            XCTAssertLessThan(fencedAt - initial, 9_500_000_000)
            XCTAssertTrue(fixture.exists("publication-refused"))
            XCTAssertTrue(fixture.exists("late-ack-refused"))
            XCTAssertFalse(fixture.exists("new-publication"))
            XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("committed-truth")), "original-success")
            try fixture.assertOwnerReleased()
        }
    }

    func testBlockedEvaluationAndCancellationStillExitWithCandidateAndRestorationOwnership() throws {
        let fixture = try Fixture(kind: "evaluate_model"); defer { fixture.remove() }
        let owner = try fixture.start(mode: "blocked")
        try fixture.awaitFile("ready")
        try fixture.awaitFile("candidate-ready")
        try fixture.assertOwnerBusy()
        let candidatePID = try Int32(String(contentsOf: fixture.root.appendingPathComponent("candidate.pid"))).unwrap()
        XCTAssertEqual(kill(candidatePID, 0), 0)
        XCTAssertEqual(try fixture.wait(owner, seconds: 13), 70)
        XCTAssertTrue(fixture.exists("fenced"))
        try fixture.assertOwnerReleased()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, kill(candidatePID, 0) == 0 { usleep(20_000) }
        XCTAssertNotEqual(kill(candidatePID, 0), 0)
        try fixture.awaitFile("restore-attempted", seconds: 5)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("committed-truth")), "original-success")
        XCTAssertFalse(fixture.exists("new-publication"))
        XCTAssertFalse(fixture.exists("restoration-succeeded"), "an attempted bootstrap is not a readiness claim")
    }

    func testDurableAcknowledgmentAfterBriefContentionResumesWithoutResettingDueTick() throws {
        let fixture = try Fixture(kind: "prepare_model"); defer { fixture.remove() }
        let owner = try fixture.start(mode: "healthy")
        try fixture.awaitFile("ready")
        // The first due heartbeat is busy at five seconds. Release at six;
        // retries must remain due instead of waiting another five seconds.
        usleep(6_000_000)
        XCTAssertEqual(try fixture.timestamps().count, 1)
        fixture.releaseJournal()
        let resumed = Date().addingTimeInterval(1.5)
        while Date() < resumed, try fixture.timestamps().count < 2 { usleep(20_000) }
        XCTAssertGreaterThanOrEqual(try fixture.timestamps().count, 2)
        usleep(5_000_000)
        XCTAssertTrue(owner.isRunning, "actual durable acknowledgments must extend the owner beyond its initial ten seconds")
        XCTAssertFalse(fixture.exists("fenced"))
        try Data().write(to: fixture.root.appendingPathComponent("finish"))
        XCTAssertEqual(try fixture.wait(owner, seconds: 3), 0)
        try fixture.assertOwnerReleased()
    }

    // Fresh xctest processes execute this fixture; shipping entry points never
    // read its environment keys, choose its mode or substitute its dependencies.
    func testOwnerWatchdogSubprocessEntry() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["OWNER_WATCHDOG_TEST_ROOT"], let mode = env["OWNER_WATCHDOG_TEST_MODE"] else { return }
        let root = URL(fileURLWithPath: path)
        if mode == "candidate" {
            let parent = try env["OWNER_WATCHDOG_TEST_PARENT"].flatMap(Int32.init).unwrap()
            let lifetime = CandidateParentLifetimeGuard(expectedParentPID: parent)
            defer { withExtendedLifetime(lifetime) {} }
            try Data().write(to: root.appendingPathComponent("candidate-ready"))
            sleep(30)
            _exit(72)
        }
        let ownerFD = open(root.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard ownerFD >= 0, flock(ownerFD, LOCK_EX | LOCK_NB) == 0 else { _exit(71) }
        defer { close(ownerFD) }
        let watchdog = ModelTransactionOwnerLifetimeGuard(onFence: {
            let stamp = String(DispatchTime.now().uptimeNanoseconds)
            try? stamp.write(to: root.appendingPathComponent("fenced"), atomically: true, encoding: .utf8)
            // A stalled cancellation callback must not stall the timer queue.
            if mode == "blocked" { sleep(30) }
        })
        defer { withExtendedLifetime(watchdog) {} }
        var last = try Self.persistHeartbeat(root)
        let initial = last
        try watchdog.acknowledgeDurableHeartbeat()
        var candidate: Process?
        var restoration: ProviderLaunchdRestoreGuard?
        defer { withExtendedLifetime(candidate) {}; withExtendedLifetime(restoration) {} }
        if mode == "blocked" {
            try watchdog.checkPublicationAllowed()
            candidate = Self.helper(root: root, mode: "candidate", parent: getpid())
            try candidate!.run()
            try String(candidate!.processIdentifier).write(to: root.appendingPathComponent("candidate.pid"), atomically: true, encoding: .utf8)
            try watchdog.checkPublicationAllowed()
            restoration = try ProviderLaunchdRestoreGuard.start(launchdDomain: "fixture-domain",
                plistPath: root.appendingPathComponent("restore-attempted").path,
                launchctlPath: root.appendingPathComponent("fixture-launchctl").path)
        }
        try Data().write(to: root.appendingPathComponent("ready"))
        if mode == "blocked" {
            let fifo = root.appendingPathComponent("blocked-metadata").path
            guard mkfifo(fifo, 0o600) == 0 else { _exit(71) }
            // No writer exists: this real blocking syscall never reaches an ack.
            let blocked = open(fifo, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if blocked >= 0 { close(blocked) }
            _exit(72)
        }
        let journal = open(root.appendingPathComponent("journal.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard journal >= 0 else { _exit(71) }
        defer { close(journal) }
        var triedLateAck = false
        while true {
            if mode == "healthy", FileManager.default.fileExists(atPath: root.appendingPathComponent("finish").path) {
                // A real terminal durability boundary may acknowledge progress;
                // it does not disable the guard or revive a fenced operation.
                _ = try Self.persistHeartbeat(root)
                try watchdog.acknowledgeDurableHeartbeat()
                _exit(0)
            }
            do { try watchdog.checkPublicationAllowed() }
            catch {
                try Data().write(to: root.appendingPathComponent("publication-refused"))
                if !triedLateAck {
                    triedLateAck = true
                    _ = try Self.persistHeartbeat(root)
                    do { try watchdog.acknowledgeDurableHeartbeat(); _exit(73) }
                    catch { try Data().write(to: root.appendingPathComponent("late-ack-refused")) }
                }
                usleep(50_000)
                continue
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if mode == "contended", now - initial >= 8_250_000_000 {
                // Reaching a publication after the fence is an explicit failure,
                // not merely the absence of a positive fixture marker.
                try Data().write(to: root.appendingPathComponent("new-publication"))
                _exit(74)
            }
            if now - last >= 5_000_000_000, flock(journal, LOCK_EX | LOCK_NB) == 0 {
                last = try Self.persistHeartbeat(root)
                try watchdog.acknowledgeDurableHeartbeat()
                _ = flock(journal, LOCK_UN)
            }
            usleep(500_000)
        }
    }

    private static func persistHeartbeat(_ root: URL) throws -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let fd = open(root.appendingPathComponent("heartbeats").path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FixtureError.io }
        defer { close(fd) }
        let data = Data("\(now)\n".utf8)
        guard data.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == data.count,
              fsync(fd) == 0 else { throw FixtureError.io }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw FixtureError.io }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw FixtureError.io }
        return now
    }

    private static func helper(root: URL, mode: String, parent: Int32 = 0) -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "macprovider_cliTests.ModelTransactionOwnerLifetimeGuardTests/testOwnerWatchdogSubprocessEntry", Bundle(for: Self.self).bundlePath]
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
            "OWNER_WATCHDOG_TEST_ROOT": root.path, "OWNER_WATCHDOG_TEST_MODE": mode,
            "OWNER_WATCHDOG_TEST_PARENT": String(parent)]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        return child
    }

    private enum FixtureError: Error { case io, timeout }
    private final class Fixture {
        let root: URL
        private var journal: Int32 = -1
        private var children: [Process] = []
        init(kind: String) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("owner-heartbeat-\(kind)-" + UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            journal = open(root.appendingPathComponent("journal.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard journal >= 0, flock(journal, LOCK_EX | LOCK_NB) == 0 else { throw FixtureError.io }
            try Data("original-success".utf8).write(to: root.appendingPathComponent("committed-truth"))
            let fake = root.appendingPathComponent("fixture-launchctl")
            try Data("#!/bin/sh\nprintf 'attempted\\n' > \"$3\"\n".utf8).write(to: fake)
            guard chmod(fake.path, 0o700) == 0 else { throw FixtureError.io }
        }
        func start(mode: String) throws -> Process {
            let child = ModelTransactionOwnerLifetimeGuardTests.helper(root: root, mode: mode)
            try child.run(); children.append(child); return child
        }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
        func awaitFile(_ name: String, seconds: TimeInterval = 15) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if exists(name) { return }; usleep(20_000) }
            XCTFail("owner watchdog fixture did not reach \(name)")
            throw FixtureError.timeout
        }
        func timestamps() throws -> [UInt64] {
            try String(contentsOf: root.appendingPathComponent("heartbeats")).split(separator: "\n").map {
                try UInt64($0).unwrap()
            }
        }
        func wait(_ child: Process, seconds: TimeInterval) throws -> Int32 {
            let deadline = Date().addingTimeInterval(seconds)
            while child.isRunning && Date() < deadline { usleep(20_000) }
            guard !child.isRunning else { throw FixtureError.timeout }
            child.waitUntilExit()
            XCTAssertEqual(child.terminationReason, .exit)
            return child.terminationStatus
        }
        func assertOwnerBusy() throws {
            let fd = open(root.appendingPathComponent("owner.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw FixtureError.io }
            defer { close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), -1); XCTAssertEqual(errno, EWOULDBLOCK)
        }
        func assertOwnerReleased() throws {
            let fd = open(root.appendingPathComponent("owner.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw FixtureError.io }
            defer { close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        }
        func releaseJournal() { if journal >= 0 { close(journal); journal = -1 } }
        func remove() {
            for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
            children.removeAll(); releaseJournal()
            try? FileManager.default.removeItem(at: root)
        }
        deinit { remove() }
    }
}

private extension Optional {
    func unwrap(file: StaticString = #filePath, line: UInt = #line) throws -> Wrapped {
        try XCTUnwrap(self, file: file, line: line)
    }
}
