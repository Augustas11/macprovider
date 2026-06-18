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
