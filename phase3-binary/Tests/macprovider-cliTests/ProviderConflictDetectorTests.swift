import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderConflictDetectorTests: XCTestCase {
    func testDetectLaunchdManagedProviderFromLaunchctlList() throws {
        let detector = ProviderConflictDetector(
            launchctlList: {
                """
                PID\tStatus\tLabel
                42\t0\tcom.apple.example
                1234\t0\tlive.streamvc.macprovider
                """
            },
            processList: { [] }
        )

        XCTAssertEqual(try detector.detect(), .launchdManaged(pid: 1_234))
    }

    func testDetectNoneWhenLaunchctlAndProcessListsAreEmpty() throws {
        let detector = ProviderConflictDetector(
            launchctlList: { "" },
            processList: { [] }
        )

        XCTAssertEqual(try detector.detect(), .none)
    }

    func testDetectForegroundServeProcess() throws {
        let argv = ["/Users/provider/.local/bin/macprovider-cli", "serve", "--model", "X"]
        let detector = ProviderConflictDetector(
            launchctlList: { "" },
            processList: { [(pid: Int32(77), argv: argv)] }
        )

        XCTAssertEqual(try detector.detect(), ProviderConflict.foreground(pid: 77, argv: argv))
    }

    func testAutotuneProcessDoesNotMatchForegroundServe() throws {
        let detector = ProviderConflictDetector(
            launchctlList: { "" },
            processList: {
                [
                    (pid: Int32(88), argv: ["/Users/provider/.local/bin/macprovider-cli", "autotune", "--drain"]),
                ]
            }
        )

        XCTAssertEqual(try detector.detect(), .none)
    }

    func testServeSubstringDoesNotMatchForegroundServe() throws {
        let detector = ProviderConflictDetector(
            launchctlList: { "" },
            processList: {
                [
                    (pid: Int32(99), argv: ["/Users/provider/.local/bin/macprovider-cli", "-serve-helper"]),
                ]
            }
        )

        XCTAssertEqual(try detector.detect(), .none)
    }

    func testRealLaunchctlListWhenIntegrationEnabled() throws {
        guard ProcessInfo.processInfo.environment["MACPROVIDER_INTEGRATION_TEST"] == "1" else {
            throw XCTSkip("set MACPROVIDER_INTEGRATION_TEST=1 to run real launchctl list integration test")
        }

        _ = try ProviderConflictDetector.defaultLaunchctlList()
    }

    // MARK: - Round-1 audit fix tests (detector scope)

    /// Round-1 G.1 closure: `launchctl list` may report a loaded but
    /// inactive job with PID `-`. The parser already returns
    /// `(found: true, pid: nil)` for this case; this test pins the
    /// behavior against future refactors.
    func testParseLaunchdManagedInactivePIDReturnsNil() {
        let output = "-\t-\tlive.streamvc.macprovider\n"
        let parsed = ProviderConflictDetector.parseLaunchdManagedPID(from: output)
        XCTAssertTrue(parsed.found)
        XCTAssertNil(parsed.pid)
    }

    /// Round-1 G.2 closure: a helper binary like
    /// `/path/macprovider-cli-helper serve` is the OTHER false-positive
    /// class the prompt named. `lastPathComponent != "macprovider-cli"`
    /// already rejects it; this test pins the behavior.
    func testHelperBinaryDoesNotMatchForegroundServe() throws {
        let detector = ProviderConflictDetector(
            launchctlList: { "" },
            processList: { [(pid: 9001, argv: ["/usr/local/bin/macprovider-cli-helper", "serve"])] }
        )
        XCTAssertEqual(try detector.detect(), .none)
    }
}

final class ProviderDrainerTests: XCTestCase {
    func testLaunchdDrainInvokesBootoutWithGuiServiceTarget() throws {
        var calls: [(String, [String])] = []
        let drainer = ProviderDrainer(
            uid: 501,
            launchctlRunner: { executable, arguments in
                calls.append((executable, arguments))
            },
            portIsOpen: { _ in false }
        )

        let result = try drainer.drain(.launchdManaged(pid: 123), port: 18_080, graceSeconds: 0)

        XCTAssertEqual(result, .drained)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "/bin/launchctl")
        XCTAssertEqual(calls[0].1, ["bootout", "gui/501/live.streamvc.macprovider"])
    }

    func testForegroundDrainSendsSIGTERMToPID() throws {
        var signals: [(Int32, Int32)] = []
        let drainer = ProviderDrainer(
            signalSender: { pid, signal in
                signals.append((pid, signal))
                return 0
            },
            processIsRunning: { _ in false },
            portIsOpen: { _ in false }
        )

        let result = try drainer.drain(
            .foreground(pid: 4_242, argv: ["/usr/local/bin/macprovider-cli", "serve"]),
            port: 18_080,
            graceSeconds: 0
        )

        XCTAssertEqual(result, .drained)
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].0, 4_242)
        XCTAssertEqual(signals[0].1, SIGTERM)
    }

    func testLaunchdRestoreInvokesBootstrapWithGuiDomainAndPlist() throws {
        let plistURL = URL(fileURLWithPath: "/Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist")
        var calls: [(String, [String])] = []
        let drainer = ProviderDrainer(
            uid: 502,
            plistURL: plistURL,
            launchctlRunner: { executable, arguments in
                calls.append((executable, arguments))
            }
        )

        let result = try drainer.restore(.launchdManaged(pid: nil))

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "/bin/launchctl")
        XCTAssertEqual(calls[0].1, ["bootstrap", "gui/502", plistURL.path])
    }

    func testLaunchdCrashRestoreGuardStartsOnlyForLaunchdManagedConflict() throws {
        let plistURL = URL(fileURLWithPath: "/Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist")
        var starts: [(String, String)] = []
        var dismissCount = 0
        let drainer = ProviderDrainer(
            uid: 502,
            plistURL: plistURL,
            launchdRestoreGuardStarter: { domain, plistPath in
                starts.append((domain, plistPath))
                return ProviderLaunchdRestoreGuard {
                    dismissCount += 1
                }
            }
        )

        let guardHandle = try XCTUnwrap(
            try drainer.startLaunchdCrashRestoreGuard(for: .launchdManaged(pid: nil))
        )
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts[0].0, "gui/502")
        XCTAssertEqual(starts[0].1, plistURL.path)

        XCTAssertNil(try drainer.startLaunchdCrashRestoreGuard(for: .none))
        XCTAssertNil(
            try drainer.startLaunchdCrashRestoreGuard(
                for: .foreground(pid: 515, argv: ["/usr/local/bin/macprovider-cli", "serve"])
            )
        )
        XCTAssertEqual(starts.count, 1)

        guardHandle.dismiss()
        guardHandle.dismiss()
        XCTAssertEqual(dismissCount, 1)
    }

    func testLaunchdRestoreGuardScriptBootstrapsOnceOnEOFWithoutDismissToken() throws {
        let fixture = try makeLaunchdGuardFixture()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            ProviderLaunchdRestoreGuard.restoreScript,
            "macprovider-launchd-restore-guard-test",
            fixture.launchctl.path,
            "gui/502",
            "/Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist",
            ProviderLaunchdRestoreGuard.dismissToken,
        ]
        process.standardInput = Pipe().fileHandleForReading
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertEqual(
            log,
            "bootstrap gui/502 /Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist\n"
        )
    }

    func testLaunchdRestoreGuardIgnoresHangupBeforeEOF() throws {
        let fixture = try makeLaunchdGuardFixture()
        let stdin = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            ProviderLaunchdRestoreGuard.restoreScript,
            "macprovider-launchd-restore-guard-test",
            fixture.launchctl.path,
            "gui/502",
            "/Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist",
            ProviderLaunchdRestoreGuard.dismissToken,
        ]
        process.standardInput = stdin.fileHandleForReading
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(Darwin.kill(process.processIdentifier, SIGHUP), 0)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertEqual(
            log,
            "bootstrap gui/502 /Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist\n"
        )
    }

    func testLaunchdRestoreGuardDismissTokenExitsWithoutBootstrap() throws {
        let fixture = try makeLaunchdGuardFixture()
        let guardHandle = try ProviderLaunchdRestoreGuard.start(
            launchdDomain: "gui/502",
            plistPath: "/Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist",
            launchctlPath: fixture.launchctl.path
        )

        guardHandle.dismiss()

        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertEqual(log, "")
    }

    // MARK: - Round-1 audit fix tests (drainer scope)

    /// Round-1 G.3 closure: the foreground drain MUST emit the SIGKILL-
    /// disabled warning when grace expires with the process still
    /// running. The injected warning writer captures the message.
    func testForegroundDrainEmitsNoSIGKILLWarningWhenProcessRemainsAfterGrace() throws {
        var signals: [(Int32, Int32)] = []
        var warnings: [String] = []
        let drainer = ProviderDrainer(
            signalSender: { pid, signal in
                signals.append((pid, signal))
                return 0
            },
            processIsRunning: { _ in true },   // stays alive past grace
            portIsOpen: { _ in false },        // port is free though
            warningWriter: { message in warnings.append(message) }
        )

        let result = try drainer.drain(
            .foreground(pid: 7_777, argv: ["/usr/local/bin/macprovider-cli", "serve"]),
            port: 18_080,
            graceSeconds: 0
        )

        XCTAssertEqual(result, .drained)  // port-free wins the result enum
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].1, SIGTERM)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("pid 7777"), "warning should name the stuck PID; got \(warnings[0])")
        XCTAssertTrue(warnings[0].contains("SIGKILL is disabled in v1"), "warning should name the v1 SIGKILL policy; got \(warnings[0])")
    }

    func testForegroundRestoreSkipsUnlessRestartForegroundIsTrue() throws {
        var restarts: [[String]] = []
        let conflict = ProviderConflict.foreground(
            pid: 515,
            argv: ["/usr/local/bin/macprovider-cli", "serve", "--model", "X"]
        )
        let drainer = ProviderDrainer(
            foregroundRestarter: { argv in
                restarts.append(argv)
            }
        )

        XCTAssertEqual(try drainer.restore(conflict, restartForeground: false), .skipped)
        XCTAssertEqual(restarts, [])

        XCTAssertEqual(try drainer.restore(conflict, restartForeground: true), .restored)
        XCTAssertEqual(restarts, [["/usr/local/bin/macprovider-cli", "serve", "--model", "X"]])
    }

    private func makeLaunchdGuardFixture() throws -> (launchctl: URL, log: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-restore-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let log = directory.appendingPathComponent("launchctl.log")
        try Data().write(to: log)
        let launchctl = directory.appendingPathComponent("launchctl")
        let script = """
        #!/bin/sh
        printf "%s %s %s\\n" "$1" "$2" "$3" >> "\(log.path)"
        exit 0
        """
        try script.write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        return (launchctl, log)
    }
}
