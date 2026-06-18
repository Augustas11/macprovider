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
}
