import Foundation
import XCTest
@testable import Malibu

final class AppBundleRelaunchWatcherTests: XCTestCase {
    private typealias Watcher = AppBundleRelaunchWatcher

    private let running = Watcher.Identity(version: "1.8.251", build: "1008251")
    private let installed = Watcher.Identity(version: "1.8.252", build: "1008252")
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func decide(
        _ onDisk: Watcher.Identity?,
        _ readiness: Watcher.Readiness = .clear,
        at offset: TimeInterval,
        _ state: inout Watcher.State,
        ledger: Watcher.AttemptLedger = .init()
    ) -> Bool {
        Watcher.shouldRelaunch(
            running: running, onDisk: onDisk, readiness: readiness,
            now: start.addingTimeInterval(offset), state: &state, ledger: ledger
        )
    }

    func testUnchangedBundleNeverRelaunches() {
        var state = Watcher.State()
        for offset in stride(from: 0.0, through: 3_600, by: 15) {
            XCTAssertFalse(decide(running, at: offset, &state))
        }
        XCTAssertEqual(state, Watcher.State())
    }

    func testChangedBundleRelaunchesOnlyAfterSettling() {
        var state = Watcher.State()
        XCTAssertFalse(decide(installed, at: 0, &state))
        XCTAssertFalse(decide(installed, at: 59, &state))
        XCTAssertTrue(decide(installed, at: 60, &state))
    }

    func testBlockedNeverRelaunchesAndUnknownWaitsPastTheMaintenanceLease() {
        var state = Watcher.State()
        XCTAssertFalse(decide(installed, .blocked, at: 0, &state))
        XCTAssertFalse(decide(installed, .blocked, at: 7_200, &state))
        // Status unavailable (the CLI may be restarting or rolling back).
        XCTAssertFalse(decide(installed, .unknown, at: 899, &state))
        XCTAssertTrue(decide(installed, .unknown, at: 900, &state))
        XCTAssertTrue(decide(installed, .clear, at: 900, &state))
    }

    func testRollbackDuringSettleCancelsAndANewTargetRestartsTheWait() {
        var state = Watcher.State()
        _ = decide(installed, at: 0, &state)
        // Rollback restores the launched version: nothing to relaunch.
        XCTAssertFalse(decide(running, at: 30, &state))
        XCTAssertEqual(state, Watcher.State())
        let other = Watcher.Identity(version: "1.8.253", build: "1008253")
        XCTAssertFalse(decide(other, at: 45, &state))
        XCTAssertFalse(decide(other, at: 90, &state))
        XCTAssertTrue(decide(other, at: 105, &state))
    }

    func testUnreadableMidSwapBundleResetsTheWait() {
        var state = Watcher.State()
        _ = decide(installed, at: 0, &state)
        XCTAssertFalse(decide(nil, at: 60, &state))
        XCTAssertEqual(state, Watcher.State())
    }

    func testAttemptLedgerBoundsRetriesAcrossTargetsAndNeverLoops() {
        let policy = Watcher.Policy()
        var ledger = Watcher.AttemptLedger()
        var attempts = 0
        // A bundle swapped to a fresh target every minute for six hours.
        for minute in 0..<360 {
            let now = start.addingTimeInterval(TimeInterval(minute * 60))
            let target = Watcher.Identity(version: "1.8.\(300 + minute)", build: "\(minute)")
            var state = Watcher.State(pending: target, pendingSince: now.addingTimeInterval(-policy.settleSeconds))
            if Watcher.shouldRelaunch(
                running: running, onDisk: target, readiness: .clear,
                now: now, state: &state, ledger: ledger, policy: policy
            ) {
                attempts += 1
                ledger = Watcher.recordingAttempt(on: ledger, now: now, policy: policy)
            }
        }
        XCTAssertEqual(attempts, policy.maxAttemptsPerWindow)
        XCTAssertLessThanOrEqual(ledger.attempts.count, policy.maxAttemptsPerWindow)
    }

    func testAttemptLedgerCooldownWindowAndFutureDatesAreClamped() {
        let first = Watcher.recordingAttempt(on: .init(), now: start)
        var state = Watcher.State(pending: installed, pendingSince: start.addingTimeInterval(-120))
        XCTAssertFalse(decide(installed, at: 599, &state, ledger: first))
        XCTAssertTrue(decide(installed, at: 600, &state, ledger: first))

        // A tampered future timestamp counts as "now", not as a free pass.
        let future = Watcher.AttemptLedger(attempts: [start.addingTimeInterval(86_400)])
        XCTAssertFalse(decide(installed, at: 0, &state, ledger: future))

        // Attempts older than the window no longer count.
        let old = Watcher.AttemptLedger(attempts: [0, 1, 2].map { start.addingTimeInterval(-7 * 3_600 + $0) })
        XCTAssertTrue(decide(installed, at: 0, &state, ledger: old))
    }

    func testReadinessBlocksEveryTransactionAndUserFlow() {
        func readiness(
            state: String? = "serving_buyers",
            lease: String? = nil,
            update: Bool = false,
            repair: Bool = false,
            app: Bool = false
        ) -> Watcher.Readiness {
            Watcher.readiness(
                lifecycleState: state, lifecycleLeaseKind: lease,
                cliUpdateInProgress: update, providerSoftwareRepairInProgress: repair,
                appFlowInProgress: app
            )
        }
        XCTAssertEqual(readiness(), .clear)
        XCTAssertEqual(readiness(state: nil), .unknown)
        XCTAssertEqual(readiness(state: "update_in_progress"), .blocked)
        XCTAssertEqual(readiness(state: "rollback_in_progress"), .blocked)
        XCTAssertEqual(readiness(lease: "maintenance"), .blocked)
        // A Malibu-driven update relaunches through CLIUpdateRunner itself.
        XCTAssertEqual(readiness(update: true), .blocked)
        XCTAssertEqual(readiness(repair: true), .blocked)
        XCTAssertEqual(readiness(state: nil, app: true), .blocked)
    }

    func testReadIdentitySeesAnInPlaceBundleSwap() throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("Malibu.app", isDirectory: true)
        try makeBundle(at: target, version: "1.8.251", build: "1008251")
        XCTAssertEqual(Watcher.readIdentity(bundleURL: target), running)

        let staged = root.appendingPathComponent(".Malibu.app.activation", isDirectory: true)
        try makeBundle(at: staged, version: "1.8.252", build: "1008252")
        XCTAssertEqual(renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)), 0)
        XCTAssertEqual(Watcher.readIdentity(bundleURL: target), installed)
    }

    func testReadIdentityRejectsForeignOrSymlinkedBundles() throws {
        let root = try temporaryDirectory()
        let foreign = root.appendingPathComponent("Foreign/Malibu.app", isDirectory: true)
        try makeBundle(at: foreign, version: "1.8.252", build: "1008252", identifier: "com.example.other")
        XCTAssertNil(Watcher.readIdentity(bundleURL: foreign))

        let real = root.appendingPathComponent("Real/Malibu.app", isDirectory: true)
        try makeBundle(at: real, version: "1.8.252", build: "1008252")
        let link = root.appendingPathComponent("Link/Malibu.app", isDirectory: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertNil(Watcher.readIdentity(bundleURL: link))

        let plist = real.appendingPathComponent("Contents/Info.plist")
        let moved = root.appendingPathComponent("Info.plist")
        try FileManager.default.moveItem(at: plist, to: moved)
        try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: moved)
        XCTAssertNil(Watcher.readIdentity(bundleURL: real))
    }

    @MainActor
    func testMonitorStaysOffOutsideTheUpdaterOwnedInstall() {
        // The XCTest host runs from DerivedData, never /Applications.
        XCTAssertNil(AppBundleRelaunchMonitor(readiness: { .clear }))
    }

    @MainActor
    func testMonitorRelaunchesOnceAfterAProvenSwapAndRetriesAFailureAfterCooldown() async throws {
        let root = try temporaryDirectory()
        let bundle = root.appendingPathComponent("Malibu.app", isDirectory: true)
        try makeBundle(at: bundle, version: "1.8.251", build: "1008251")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "malibu-relaunch-\(UUID().uuidString)"))
        var relaunches = 0
        var failNext = true
        var proven = false
        let monitor = AppBundleRelaunchMonitor(
            bundleURL: bundle,
            running: running,
            readiness: { .clear },
            isCLIOwnedInstall: { _ in proven },
            relaunch: { _ in
                relaunches += 1
                if failNext {
                    failNext = false
                    throw CLIUpdateRunner.Error.appRelaunchFailed("test")
                }
            },
            defaults: defaults
        )

        XCTAssertNil(monitor.tick(now: start))
        try makeBundle(at: bundle, version: "1.8.252", build: "1008252")
        // Not yet the installed CLI's signed set member: never relaunch.
        XCTAssertNil(monitor.tick(now: start.addingTimeInterval(15)))
        XCTAssertNil(monitor.tick(now: start.addingTimeInterval(600)))
        // Proven and settled since first sight: relaunch now.
        proven = true
        let failed = try XCTUnwrap(monitor.tick(now: start.addingTimeInterval(615)))
        await failed.value
        XCTAssertEqual(relaunches, 1)
        XCTAssertFalse(monitor.relaunching)
        // Cooldown after the failed attempt.
        XCTAssertNil(monitor.tick(now: start.addingTimeInterval(700)))
        let retried = try XCTUnwrap(monitor.tick(now: start.addingTimeInterval(615 + 600)))
        await retried.value
        XCTAssertEqual(relaunches, 2)
        // A successful relaunch hands off to the new process; this one stops.
        XCTAssertTrue(monitor.relaunching)
        XCTAssertNil(monitor.tick(now: start.addingTimeInterval(615 + 1_300)))
        XCTAssertEqual(relaunches, 2)
        XCTAssertEqual((defaults.array(forKey: AppBundleRelaunchMonitor.ledgerKey) as? [Double])?.count, 2)
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
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }
}
