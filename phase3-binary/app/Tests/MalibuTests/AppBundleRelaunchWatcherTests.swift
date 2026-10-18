import Foundation
import XCTest
@testable import Malibu

final class AppBundleRelaunchWatcherTests: XCTestCase {
    private typealias Watcher = AppBundleRelaunchWatcher

    private let running = Watcher.Identity(version: "1.8.251", build: "251", executableDevice: 1, executableInode: 100)
    private let installed = Watcher.Identity(version: "1.8.252", build: "252", executableDevice: 1, executableInode: 200)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testUnchangedBundleNeverRelaunches() {
        var state = Watcher.State()
        for offset in stride(from: 0.0, through: 600, by: 15) {
            XCTAssertFalse(Watcher.shouldRelaunch(
                running: running, onDisk: running, blocked: false,
                now: start.addingTimeInterval(offset), state: &state, ledger: .init()
            ))
        }
        XCTAssertEqual(state, Watcher.State())
    }

    func testChangedBundleRelaunchesOnlyAfterSettling() {
        var state = Watcher.State()
        XCTAssertFalse(Watcher.shouldRelaunch(
            running: running, onDisk: installed, blocked: false,
            now: start, state: &state, ledger: .init()
        ))
        XCTAssertFalse(Watcher.shouldRelaunch(
            running: running, onDisk: installed, blocked: false,
            now: start.addingTimeInterval(59), state: &state, ledger: .init()
        ))
        XCTAssertTrue(Watcher.shouldRelaunch(
            running: running, onDisk: installed, blocked: false,
            now: start.addingTimeInterval(60), state: &state, ledger: .init()
        ))
    }

    func testSameVersionInPlaceSwapStillRelaunches() {
        // A swapped bundle that reuses the version stamp still gets a new
        // executable inode, so the running process is known to be stale.
        let rebuilt = Watcher.Identity(version: "1.8.251", build: "251", executableDevice: 1, executableInode: 300)
        var state = Watcher.State()
        XCTAssertFalse(Watcher.shouldRelaunch(
            running: running, onDisk: rebuilt, blocked: false,
            now: start, state: &state, ledger: .init()
        ))
        XCTAssertTrue(Watcher.shouldRelaunch(
            running: running, onDisk: rebuilt, blocked: false,
            now: start.addingTimeInterval(60), state: &state, ledger: .init()
        ))
    }

    func testBlockedDefersUntilTheTransactionEnds() {
        var state = Watcher.State()
        _ = Watcher.shouldRelaunch(
            running: running, onDisk: installed, blocked: true,
            now: start, state: &state, ledger: .init()
        )
        XCTAssertFalse(Watcher.shouldRelaunch(
            running: running, onDisk: installed, blocked: true,
            now: start.addingTimeInterval(3_600), state: &state, ledger: .init()
        ))
        XCTAssertTrue(Watcher.shouldRelaunch(
            running: running, onDisk: installed, blocked: false,
            now: start.addingTimeInterval(3_615), state: &state, ledger: .init()
        ))
    }

    func testRollbackDuringSettleRestartsOrCancelsTheWait() {
        var state = Watcher.State()
        _ = Watcher.shouldRelaunch(
            running: running, onDisk: installed, blocked: false,
            now: start, state: &state, ledger: .init()
        )
        // Rollback swaps the original bundle back: nothing to relaunch.
        XCTAssertFalse(Watcher.shouldRelaunch(
            running: running, onDisk: running, blocked: false,
            now: start.addingTimeInterval(30), state: &state, ledger: .init()
        ))
        XCTAssertEqual(state, Watcher.State())
        // A different target restarts the settle window from first sight.
        let other = Watcher.Identity(version: "1.8.253", build: "253", executableDevice: 1, executableInode: 400)
        XCTAssertFalse(Watcher.shouldRelaunch(
            running: running, onDisk: other, blocked: false,
            now: start.addingTimeInterval(45), state: &state, ledger: .init()
        ))
        XCTAssertFalse(Watcher.shouldRelaunch(
            running: running, onDisk: other, blocked: false,
            now: start.addingTimeInterval(90), state: &state, ledger: .init()
        ))
        XCTAssertTrue(Watcher.shouldRelaunch(
            running: running, onDisk: other, blocked: false,
            now: start.addingTimeInterval(105), state: &state, ledger: .init()
        ))
    }

    func testUnreadableMidSwapBundleResetsTheWait() {
        var state = Watcher.State()
        _ = Watcher.shouldRelaunch(
            running: running, onDisk: installed, blocked: false,
            now: start, state: &state, ledger: .init()
        )
        XCTAssertFalse(Watcher.shouldRelaunch(
            running: running, onDisk: nil, blocked: false,
            now: start.addingTimeInterval(60), state: &state, ledger: .init()
        ))
        XCTAssertEqual(state, Watcher.State())
    }

    func testAttemptLedgerBoundsRetriesAndNeverLoops() {
        let policy = Watcher.Policy()
        var ledger = Watcher.AttemptLedger()
        var now = start
        var attempts = 0
        for _ in 0..<40 {
            var state = Watcher.State(pending: installed, pendingSince: now.addingTimeInterval(-policy.settleSeconds))
            if Watcher.shouldRelaunch(
                running: running, onDisk: installed, blocked: false,
                now: now, state: &state, ledger: ledger, policy: policy
            ) {
                attempts += 1
                ledger = Watcher.recordingAttempt(on: ledger, target: installed, now: now)
            }
            now = now.addingTimeInterval(60)
        }
        XCTAssertEqual(attempts, policy.maxAttemptsPerTarget)
        XCTAssertEqual(ledger.attempts, policy.maxAttemptsPerTarget)
        XCTAssertEqual(ledger.targetFingerprint, installed.fingerprint)
    }

    func testAttemptLedgerHonorsCooldownAndResetsForANewTarget() {
        let first = Watcher.recordingAttempt(on: .init(), target: installed, now: start)
        XCTAssertEqual(first.attempts, 1)
        var state = Watcher.State(pending: installed, pendingSince: start.addingTimeInterval(-120))
        XCTAssertFalse(Watcher.shouldRelaunch(
            running: running, onDisk: installed, blocked: false,
            now: start.addingTimeInterval(599), state: &state, ledger: first
        ))
        XCTAssertTrue(Watcher.shouldRelaunch(
            running: running, onDisk: installed, blocked: false,
            now: start.addingTimeInterval(600), state: &state, ledger: first
        ))

        let next = Watcher.Identity(version: "1.8.253", build: "253", executableDevice: 1, executableInode: 500)
        var nextState = Watcher.State(pending: next, pendingSince: start)
        XCTAssertTrue(Watcher.shouldRelaunch(
            running: running, onDisk: next, blocked: false,
            now: start.addingTimeInterval(60), state: &nextState, ledger: first
        ))
        XCTAssertEqual(Watcher.recordingAttempt(on: first, target: next, now: start).attempts, 1)
    }

    func testReadIdentitySeesAnInPlaceBundleSwap() throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("Malibu.app", isDirectory: true)
        try makeBundle(at: target, version: "1.8.251", build: "251")
        let before = try XCTUnwrap(Watcher.readIdentity(bundleURL: target, executableName: "Malibu"))
        XCTAssertEqual(before.version, "1.8.251")
        XCTAssertEqual(before.build, "251")

        let staged = root.appendingPathComponent(".Malibu.app.activation", isDirectory: true)
        try makeBundle(at: staged, version: "1.8.252", build: "252")
        XCTAssertEqual(renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)), 0)
        let after = try XCTUnwrap(Watcher.readIdentity(bundleURL: target, executableName: "Malibu"))
        XCTAssertEqual(after.version, "1.8.252")
        XCTAssertNotEqual(after.executableInode, before.executableInode)
        XCTAssertNotEqual(after, before)
    }

    func testReadIdentityRejectsForeignOrSymlinkedBundles() throws {
        let root = try temporaryDirectory()
        let foreign = root.appendingPathComponent("Foreign/Malibu.app", isDirectory: true)
        try makeBundle(at: foreign, version: "1.8.252", build: "252", identifier: "com.example.other")
        XCTAssertNil(Watcher.readIdentity(bundleURL: foreign, executableName: "Malibu"))

        let real = root.appendingPathComponent("Real/Malibu.app", isDirectory: true)
        try makeBundle(at: real, version: "1.8.252", build: "252")
        let link = root.appendingPathComponent("Link/Malibu.app", isDirectory: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertNil(Watcher.readIdentity(bundleURL: link, executableName: "Malibu"))

        let executable = real.appendingPathComponent("Contents/MacOS/Malibu")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(
            at: executable,
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        XCTAssertNil(Watcher.readIdentity(bundleURL: real, executableName: "Malibu"))
        XCTAssertNil(Watcher.readIdentity(bundleURL: real, executableName: "../Malibu"))
    }

    @MainActor
    func testMonitorStaysOffOutsideTheUpdaterOwnedInstall() {
        // The XCTest host runs from DerivedData, never /Applications.
        XCTAssertNil(AppBundleRelaunchMonitor(isBlocked: { false }, relaunch: { _ in
            XCTFail("a non-installed bundle must never relaunch")
        }))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeBundle(
        at url: URL,
        version: String,
        build: String,
        identifier: String = "tech.malibu.app"
    ) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleExecutable": "Malibu",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: macOS.appendingPathComponent("Malibu"))
    }
}
