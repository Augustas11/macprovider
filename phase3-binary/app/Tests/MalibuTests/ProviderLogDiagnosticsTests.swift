import XCTest
@testable import Malibu

final class ProviderLogDiagnosticsTests: XCTestCase {
    func testDiagnoseStaleLaunchAgent() {
        let finding = ProviderLogDiagnostics.diagnose(lines: [
            "provider process unhealthy: launchd service live.streamvc.macprovider has no validated PID at /Users/provider/macprovider-cli",
        ])

        XCTAssertEqual(finding?.id, "stale_launch_agent")
        XCTAssertTrue(finding?.userMessage.hasPrefix("Provider setup is blocked") == true)
        XCTAssertTrue(finding?.userMessage.contains("Click Launch Provider") == true)
        XCTAssertTrue(finding?.userMessage.contains("identity and model files") == true)
    }

    func testDiagnoseStaleCatalogProvenance() {
        let finding = ProviderLogDiagnostics.diagnose(lines: [
            "loading config",
            "model catalog provenance envelope is stale (stored",
        ])

        XCTAssertEqual(finding?.id, "stale_model_catalog")
        XCTAssertTrue(finding?.userMessage.contains("Model options changed") == true)
        XCTAssertTrue(finding?.userMessage.contains("update provider software") == true)
        XCTAssertFalse(finding?.userMessage.contains("macprovider-cli") == true)
        XCTAssertFalse(finding?.userMessage.contains("autotune --recommend --apply") == true)
    }

    func testDiagnosePrefersMostRecentMatchingLine() {
        let finding = ProviderLogDiagnostics.diagnose(lines: [
            "model artifact hash mismatch for /tmp/old",
            "model catalog provenance envelope is stale (stored",
        ])

        XCTAssertEqual(finding?.id, "stale_model_catalog")
    }

    func testDiagnoseProviderLogsBeforeWatchdogLogs() {
        let finding = ProviderLogDiagnostics.diagnose(
            providerLines: ["model artifact hash mismatch for /tmp/current"],
            watchdogLines: [
                "provider process unhealthy: launchd service live.streamvc.macprovider has no validated PID at /Users/provider/macprovider-cli"
            ]
        )

        XCTAssertEqual(finding?.id, "artifact_hash_mismatch")
    }

    func testCurrentLaunchdRepairTakesPrecedenceOverGenericProviderFinding() {
        let finding = ProviderLogDiagnostics.diagnose(
            providerLines: [
                "provider process unhealthy: launchd service live.streamvc.macprovider has no validated PID at /Users/provider/macprovider-cli",
                "model artifact hash mismatch for /tmp/current"
            ],
            watchdogLines: [],
            launchdNeedsRepair: true
        )

        XCTAssertEqual(finding?.id, "stale_launch_agent")
    }

    func testHistoricalStaleLaunchAgentFindingRequiresCurrentRepairState() {
        let finding = ProviderLogDiagnostics.Finding(
            id: "stale_launch_agent",
            userMessage: ProviderLogDiagnostics.staleLaunchAgentMessage,
            matchedLine: "historical stale launchd evidence"
        )

        XCTAssertFalse(ProviderLogDiagnostics.isActionable(finding, launchdNeedsRepair: false))
        XCTAssertTrue(ProviderLogDiagnostics.isActionable(finding, launchdNeedsRepair: true))
    }

    func testDiagnoseReturnsNilForUnrecognizedLines() {
        XCTAssertNil(ProviderLogDiagnostics.diagnose(lines: ["serve starting", "connected to coordinator"]))
    }

    func testTimeoutMessageIncludesLogPaths() {
        let message = ProviderLogDiagnostics.timeoutMessage(
            logHint: ProviderLogDiagnostics.logHint(
                paths: ProviderPaths(
                    configFile: URL(fileURLWithPath: "/tmp/config.yaml"),
                    controlSocket: URL(fileURLWithPath: "/tmp/agent.sock"),
                    cliLogFile: URL(fileURLWithPath: "/tmp/malibu-cli.log"),
                    launchdStdoutLog: URL(fileURLWithPath: "/tmp/macprovider.out.log"),
                    launchdStderrLog: URL(fileURLWithPath: "/tmp/macprovider.err.log"),
                    appSupport: URL(fileURLWithPath: "/tmp/Malibu"),
                    appMarkerFile: URL(fileURLWithPath: "/tmp/.installed-by-app"),
                    onboardingStateFile: URL(fileURLWithPath: "/tmp/onboarding.json"),
                    downloadsDirectory: URL(fileURLWithPath: "/tmp/Downloads")
                )
            )
        )

        XCTAssertTrue(message.contains("/tmp/macprovider.err.log"))
        XCTAssertTrue(message.contains("/tmp/macprovider.out.log"))
        XCTAssertTrue(message.contains("/tmp/watchdog.log"))
    }

    func testStaleRuleDoesNotMatchUnrelatedPIDValidation() {
        XCTAssertNil(ProviderLogDiagnostics.diagnose(lines: [
            "unrelated component has no validated PID",
        ]))
    }
}
