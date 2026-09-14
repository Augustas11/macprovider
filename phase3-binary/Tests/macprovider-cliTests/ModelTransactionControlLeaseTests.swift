import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ModelTransactionControlLeaseTests: XCTestCase {
    private static let inheritedLock: Int32 = 101
    private static let inheritedLifetime: Int32 = 102
    private static let inheritedContext: Int32 = 103

    func testCatalogReadLeaseOwnsIndependentLockUntilEOF() throws {
        let fixture = try Fixture(catalogRead: true); defer { fixture.remove() }
        let child = try fixture.spawn("catalog_lease")
        try fixture.awaitReady(); fixture.closeParentLock()
        try fixture.assertLockBusy()
        fixture.closeLifetimeWriter()
        XCTAssertEqual(try child.wait(seconds: 4), 70)
        try fixture.assertLockReleased()
    }

    func testCatalogReadDeadlinePrecedesBlockedConfigAndHomeWork() throws {
        let fixture = try Fixture(catalogRead: true); defer { fixture.remove() }
        let child = try fixture.spawn("catalog_blocked_home")
        try fixture.awaitReady(); fixture.closeParentLock()
        let began = Date()
        try fixture.assertLockBusy()
        XCTAssertEqual(try child.wait(seconds: 14), 70)
        XCTAssertGreaterThan(Date().timeIntervalSince(began), 8)
        try fixture.assertLockReleased()
    }

    func testCatalogReadRejectsUnheldWrongAndNonPrivateLocks() throws {
        for variant in ["unheld", "unowned", "wrong", "permissions", "pipe_mode"] {
            let fixture = try Fixture(catalogRead: true); defer { fixture.remove() }
            var different: Int32 = -1
            defer { if different >= 0 { close(different) } }
            if variant == "unheld" { fixture.unlockParent() }
            if variant == "permissions" { XCTAssertEqual(chmod(fixture.lockURL.path, 0o644), 0) }
            if variant == "wrong" || variant == "unowned" {
                let path = variant == "wrong" ? fixture.root.appendingPathComponent("wrong.lock").path : fixture.lockURL.path
                different = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
                XCTAssertGreaterThanOrEqual(different, 0)
            }
            let child = try fixture.spawn(variant == "pipe_mode" ? "catalog_pipe_mode" : "catalog_lease",
                                           lock: different >= 0 ? different : nil)
            XCTAssertEqual(try child.wait(seconds: 5), 71, variant)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.readyURL.path), variant)
        }
    }

    func testCatalogParentDeathStopsHelperWithOtherWriterStillAlive() throws {
        let fixture = try Fixture(catalogRead: true); defer { fixture.remove() }
        let parent = try fixture.spawn("catalog_parent")
        try fixture.awaitReady(additionalFile: "helper.pid")
        let helper = try XCTUnwrap(Int32(String(contentsOf: fixture.root.appendingPathComponent("helper.pid"))))
        fixture.closeParentLock(); try fixture.assertLockBusy()
        XCTAssertEqual(kill(parent.pid, SIGKILL), 0)
        XCTAssertEqual(try parent.wait(seconds: 4), -SIGKILL)
        XCTAssertGreaterThanOrEqual(fixture.lifetimeWriter, 0)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, kill(helper, 0) == 0 { usleep(20_000) }
        XCTAssertNotEqual(kill(helper, 0), 0)
        try fixture.assertLockReleased()
    }

    func testInheritedLockSurvivesParentDescriptorCloseUntilLifetimeEOF() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let child = try fixture.spawn("lease")
        try fixture.awaitReady()
        fixture.closeParentLock()
        try fixture.assertLockBusy()
        fixture.closeLifetimeWriter()
        XCTAssertEqual(try child.wait(seconds: 4), 70)
        try fixture.assertLockReleased()
    }

    func testUnrelatedLockDescriptionWrongInodeAndInvalidSelectorsFailClosed() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        for role in ["unowned_lock", "wrong_inode", "duplicate_descriptors", "wrong_parent"] {
            let descriptor: Int32
            if role == "wrong_inode" {
                descriptor = open(fixture.root.appendingPathComponent("other.lock").path,
                                  O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            } else {
                descriptor = open(fixture.lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw FixtureError.io }
            let child: Child
            do { child = try fixture.spawn(role, lock: descriptor) }
            catch { close(descriptor); throw error }
            close(descriptor)
            XCTAssertEqual(try child.wait(seconds: 5), 71, role)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.readyURL.path), role)
        }
    }

    func testFixedTenSecondWatchdogRunsBeforeBlockedHomeMetadata() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let child = try fixture.spawn("blocked_home")
        try fixture.awaitReady()
        let blockedAt = DispatchTime.now().uptimeNanoseconds
        fixture.closeParentLock()
        try fixture.assertLockBusy()
        XCTAssertEqual(try child.wait(seconds: 14), 70)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - blockedAt) / 1_000_000_000
        XCTAssertGreaterThan(elapsed, 8, "fixture must exercise the real fixed deadline, not early EOF")
        XCTAssertLessThan(elapsed, 13)
        try fixture.assertLockReleased()
    }

    func testBlockedReconcileKeepsOtherHeartbeatAvailableAndReleasesOwnerOnDeadline() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = ModelCatalogTransactionStore(root: fixture.root.appendingPathComponent("models/.transactions"))
        try store.secure()
        let first = try fixture.installRunningRecord(store, model: "lease-first")
        let second = try fixture.installRunningRecord(store, model: "lease-second")
        try store.maintainRetention()
        try first.transactionID.write(to: fixture.root.appendingPathComponent("transaction.id"), atomically: true, encoding: .utf8)
        let primaryURL = store.root.appendingPathComponent(first.transactionID + ".json")
        let originalBytes = try Data(contentsOf: primaryURL)
        let child = try fixture.spawn("blocked_reconcile")
        try fixture.awaitReady()
        fixture.closeParentLock()
        try fixture.assertLockBusy()
        XCTAssertThrowsError(try store.ownerLock(first.transactionID))
        let secondOwner = try store.ownerLock(second.transactionID)
        defer { withExtendedLifetime(secondOwner) {} }
        let deadline = Date().addingTimeInterval(14)
        var heartbeats = 0
        while Date() < deadline, try child.poll() == nil {
            let started = DispatchTime.now().uptimeNanoseconds
            let receipt = try store.captureActiveReceipt(selector: XCTUnwrap(second.selector))
            var record = receipt.record
            store.append(&record, state: "running", stage: "preparing")
            try store.commit(record: record, receipt: receipt)
            XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000, 1)
            heartbeats += 1
            usleep(200_000)
        }
        XCTAssertEqual(try child.wait(seconds: 1), 70)
        XCTAssertGreaterThan(heartbeats, 10)
        let recoveredOwner = try store.ownerLock(first.transactionID)
        withExtendedLifetime(recoveredOwner) {}
        XCTAssertEqual(try Data(contentsOf: primaryURL), originalBytes, "deadline cannot manufacture terminal truth")
        try fixture.assertLockReleased()
    }

    func testActualParentDeathStopsHelperWhileLifetimeWriterRemainsOpen() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let parent = try fixture.spawn("parent")
        try fixture.awaitReady(additionalFile: "helper.pid")
        let childPID = try XCTUnwrap(Int32(String(contentsOf: fixture.root.appendingPathComponent("helper.pid"))))
        XCTAssertEqual(kill(childPID, 0), 0)
        fixture.closeParentLock()
        try fixture.assertLockBusy()
        XCTAssertEqual(kill(parent.pid, SIGKILL), 0)
        XCTAssertEqual(try parent.wait(seconds: 4), -SIGKILL)
        // The test still owns the write end: EOF cannot explain helper exit.
        XCTAssertGreaterThanOrEqual(fixture.lifetimeWriter, 0)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, kill(childPID, 0) == 0 { usleep(20_000) }
        XCTAssertNotEqual(kill(childPID, 0), 0, "orphaned control helper survived parent death")
        try fixture.assertLockReleased()
    }

    // Only the selected xctest subprocess enters this fixture. Shipping commands
    // never consult these test environment keys or invoke the isolated-home seam.
    func testLeaseSubprocessEntry() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let role = environment["MODEL_LEASE_TEST_ROLE"],
              let path = environment["MODEL_LEASE_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        if role == "catalog_parent" {
            let child = try Self.spawn(role: "catalog_lease", root: root, lock: 199, lifetime: 200, context: -1)
            try String(child.pid).write(to: root.appendingPathComponent("helper.pid"), atomically: true, encoding: .utf8)
            _exit(try child.wait(seconds: 25))
        }
        if role.hasPrefix("catalog_") {
            var options = ModelCatalogReadOptions()
            options.appReadRequest = UUID().uuidString.lowercased(); options.appReadMode = .quick
            options.readLockFD = 199; options.readLifetimeFD = 200
            do {
                let lease = try ModelCatalogReadLease.start(options: options, budget: .init(mode: .quick), homeDirectory: {
                    if role == "catalog_blocked_home" {
                        try Data("blocked".utf8).write(to: root.appendingPathComponent("ready"))
                        sleep(30)
                    }
                    return root
                })
                withExtendedLifetime(lease) {
                    try? Data("ready".utf8).write(to: root.appendingPathComponent("ready"))
                    sleep(30)
                }
                _exit(72)
            } catch { _exit(71) }
        }
        if role == "parent" {
            let child = try Self.spawn(role: "lease", root: root,
                                       lock: Self.inheritedLock, lifetime: Self.inheritedLifetime, context: Self.inheritedContext)
            try String(child.pid).write(to: root.appendingPathComponent("helper.pid"), atomically: true, encoding: .utf8)
            _exit(try child.wait(seconds: 25))
        }
        var options = ModelTransactionContextOptions()
        options.controlLockFD = Self.inheritedLock
        options.controlLifetimeFD = Self.inheritedLifetime
        options.transactionContextFD = role == "duplicate_descriptors" ? Self.inheritedLifetime : Self.inheritedContext
        options.controlParentPID = role == "wrong_parent" ? getppid() + 1 : getppid()
        do {
            let lease = try ModelTransactionControlLease.start(options: options, homeDirectory: {
                if role == "blocked_home" {
                    try Data("blocked-home".utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
                    sleep(30)
                }
                return root
            })
            defer { withExtendedLifetime(lease) {} }
            if role == "blocked_reconcile" {
                let store = ModelCatalogTransactionStore(root: root.appendingPathComponent("models/.transactions"))
                let id = try String(contentsOf: root.appendingPathComponent("transaction.id"))
                let selector = try store.locked { try XCTUnwrap(store.load(id, target: "lease-first").selector) }
                _ = try store.reconcile(selector, metadataCheck: {
                    try Data("blocked-reconcile".utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
                    sleep(30)
                })
                _exit(72)
            }
            try Data("lease-ready".utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
            sleep(30)
            _exit(72)
        } catch { _exit(71) }
    }

    private enum FixtureError: Error { case io, timeout, childStatus }

    private final class Child {
        let pid: pid_t
        private var result: Int32?
        init(_ pid: pid_t) { self.pid = pid }
        func poll() throws -> Int32? {
            if let result { return result }
            var status: Int32 = 0
            let observed = waitpid(pid, &status, WNOHANG)
            if observed == 0 || (observed < 0 && errno == EINTR) { return nil }
            guard observed == pid else { throw FixtureError.childStatus }
            let signal = status & 0x7f
            result = signal == 0 ? (status >> 8) & 0xff : -signal
            return result
        }
        func wait(seconds: TimeInterval) throws -> Int32 {
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                if let result = try poll() { return result }
                usleep(20_000)
            } while Date() < deadline
            throw FixtureError.timeout
        }
        func stop() {
            // Only an unreaped direct child is signalled; its PID cannot have
            // been reused while this process still owns the wait relationship.
            if result == nil {
                _ = kill(pid, SIGKILL)
                while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
                result = -SIGKILL
            }
        }
        deinit { stop() }
    }

    private final class Fixture {
        let root: URL
        let lockURL: URL
        var readyURL: URL { root.appendingPathComponent("ready") }
        private var lockFD: Int32 = -1
        private var lifetimeRead: Int32 = -1
        private(set) var lifetimeWriter: Int32 = -1
        private var contextRead: Int32 = -1
        private var children: [Child] = []
        private var removed = false
        init(catalogRead: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("control-lease-" + UUID().uuidString.lowercased())
            lockURL = root.appendingPathComponent("Library/Application Support/Malibu/ModelTransactions/" + (catalogRead ? "catalog-read.lock" : "control.lock"))
            try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            lockFD = open(lockURL.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw FixtureError.io }
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw FixtureError.io }
            lifetimeRead = fds[0]; lifetimeWriter = fds[1]
            guard pipe(&fds) == 0 else { throw FixtureError.io }
            contextRead = fds[0]; close(fds[1])
        }
        func unlockParent() { XCTAssertEqual(flock(lockFD, LOCK_UN), 0) }
        func closeParentLock() { if lockFD >= 0 { close(lockFD); lockFD = -1 } }
        func closeLifetimeWriter() { if lifetimeWriter >= 0 { close(lifetimeWriter); lifetimeWriter = -1 } }
        func remove() {
            guard !removed else { return }
            removed = true
            children.forEach { $0.stop() }; children.removeAll()
            closeParentLock(); closeLifetimeWriter()
            if lifetimeRead >= 0 { close(lifetimeRead); lifetimeRead = -1 }
            if contextRead >= 0 { close(contextRead); contextRead = -1 }
            try? FileManager.default.removeItem(at: root)
        }
        deinit { remove() }
        func spawn(_ role: String, lock: Int32? = nil) throws -> Child {
            let child = try ModelTransactionControlLeaseTests.spawn(role: role, root: root, lock: lock ?? lockFD,
                                                                   lifetime: role == "catalog_pipe_mode" ? lifetimeWriter : lifetimeRead, context: contextRead)
            children.append(child)
            return child
        }
        func awaitReady(additionalFile: String? = nil) throws {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: readyURL.path),
                   additionalFile.map({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) ?? true {
                    return
                }
                for child in children {
                    if let status = try child.poll() {
                        XCTFail("lease subprocess exited before its intended boundary: \(status)")
                        throw FixtureError.childStatus
                    }
                }
                usleep(20_000)
            }
            XCTFail("lease subprocess never reached its intended boundary")
            throw FixtureError.timeout
        }
        func assertLockBusy() throws {
            let fd = open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw FixtureError.io }
            defer { close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), -1)
            XCTAssertEqual(errno, EWOULDBLOCK)
        }
        func assertLockReleased() throws {
            let fd = open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw FixtureError.io }
            defer { close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        }
        func installRunningRecord(_ store: ModelCatalogTransactionStore, model: String) throws -> ModelCatalogTransactionRecord {
            let authority = ModelCatalogTransactionAuthority(modelKey: model,
                row: .init(modelID: model, modelRevision: String(repeating: "a", count: 40),
                    modelSHA256: String(repeating: "b", count: 64), minRAMGB: 1, minBandwidthTier: .c,
                    benchGate: .init(minSustainedTPS: 1, max4KTTFTMS: 1000, provenance: .init(source: "fixture-only")),
                    runtimeStatus: "recommendable", notes: nil),
                candidateDigest: String(repeating: "c", count: 64), artifactDigest: String(repeating: "d", count: 64),
                signerKeyID: "fixture-only", estimatedBytes: nil, source: "static_signed")
            let operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
            let selector = ModelCatalogTransactionSelector(transactionID: operation.transactionID, target: model,
                kind: "prepare_model", operationGeneration: operation.operationGeneration)
            let owner = try store.ownerLock(operation.transactionID)
            defer { withExtendedLifetime(owner) {} }
            let receipt = try store.captureActiveReceipt(selector: selector)
            var record = receipt.record
            record.startedAt = Date()
            store.append(&record, state: "running", stage: "preparing")
            try store.commit(record: record, receipt: receipt)
            return record
        }
    }

    private static func spawn(role: String, root: URL, lock: Int32, lifetime: Int32, context: Int32) throws -> Child {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw FixtureError.io }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let descriptorPairs = role.hasPrefix("catalog_") ? [(lock, Int32(199)), (lifetime, Int32(200))] :
            [(lock, inheritedLock), (lifetime, inheritedLifetime), (context, inheritedContext)]
        for (source, target) in descriptorPairs {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else { throw FixtureError.io }
        }
        let log = root.appendingPathComponent(role + ".log").path
        guard posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log, O_CREAT | O_WRONLY | O_TRUNC, 0o600) == 0,
              posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO) == 0 else { throw FixtureError.io }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw FixtureError.io }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw FixtureError.io }
        let arguments = ["/usr/bin/xcrun", "xctest", "-XCTest",
                         "macprovider_cliTests.ModelTransactionControlLeaseTests/testLeaseSubprocessEntry", Bundle(for: Self.self).bundlePath]
        let environment = ["PATH=/usr/bin:/bin", "HOME=\(root.path)", "TMPDIR=\(root.path)",
                           "MODEL_LEASE_TEST_ROLE=\(role)", "MODEL_LEASE_TEST_ROOT=\(root.path)"]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { for value in argv + envp { if let value { free(value) } } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argv in
            envp.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, "/usr/bin/xcrun", &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard result == 0 else { throw FixtureError.io }
        return Child(pid)
    }
}
