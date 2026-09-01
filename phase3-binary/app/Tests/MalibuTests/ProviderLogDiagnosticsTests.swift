import XCTest
@testable import Malibu

final class ProviderLogDiagnosticsTests: XCTestCase {
    func testDiagnoseStaleLaunchAgent() {
        let finding = ProviderLogDiagnostics.diagnose(lines: [
            "provider process unhealthy: launchd service live.malibu.provider has no validated PID at /Users/provider/macprovider-cli",
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

    func testDetectsHomeAutoupdateACLRejection() {
        let finding = ProviderLogDiagnostics.homeAutoupdateACLRejection(
            lines: [
                "[2026-08-19T01:05:42Z] autoupdate recovery_error=acl_write_rejected:/Users/provider"
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/provider")
        )

        XCTAssertEqual(finding?.id, "autoupdate_home_acl_rejected")
        XCTAssertTrue(finding?.userMessage.contains("macOS folder permission") == true)
        XCTAssertFalse(finding?.userMessage.contains("/Users/provider") == true)
    }

    func testDetectsHomeAutoupdateACLRejectionWithSpaceInHomePath() {
        let finding = ProviderLogDiagnostics.homeAutoupdateACLRejection(
            lines: [
                "[2026-08-19T01:05:42Z] autoupdate recovery_error=acl_write_rejected:/Users/provider name"
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/provider name")
        )

        XCTAssertEqual(finding?.id, "autoupdate_home_acl_rejected")
    }

    func testIgnoresNonHomeAutoupdateACLRejection() {
        let finding = ProviderLogDiagnostics.homeAutoupdateACLRejection(
            lines: [
                "[2026-08-19T01:05:42Z] autoupdate recovery_error=acl_write_rejected:/Users/provider/.local/share/macprovider/autoupdate"
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/provider")
        )

        XCTAssertNil(finding)
    }

    func testIgnoresHomeAutoupdateACLRejectionBeforeSuccessfulBundledRepairMarker() {
        let finding = ProviderLogDiagnostics.homeAutoupdateACLRejection(
            lines: [
                "[2026-08-19T01:05:42Z] autoupdate recovery_error=acl_write_rejected:/Users/provider",
                "[2026-08-19T01:08:20Z] \(ProviderLogDiagnostics.providerSoftwareInstallHandledAutoupdateACLMarker)",
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/provider")
        )

        XCTAssertNil(finding)
    }

    func testDetectsHomeAutoupdateACLRejectionAfterSuccessfulBundledRepairMarker() {
        let finding = ProviderLogDiagnostics.homeAutoupdateACLRejection(
            lines: [
                "[2026-08-19T01:08:20Z] \(ProviderLogDiagnostics.providerSoftwareInstallHandledAutoupdateACLMarker)",
                "[2026-08-19T01:09:42Z] autoupdate recovery_error=acl_write_rejected:/Users/provider",
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/provider")
        )

        XCTAssertEqual(finding?.id, "autoupdate_home_acl_rejected")
    }

    func testIgnoresHomeAutoupdateACLRejectionBeforeWatchdogRecoverySuccess() {
        let finding = ProviderLogDiagnostics.homeAutoupdateACLRejection(
            lines: [
                "[2026-08-19T01:05:42Z] autoupdate recovery_error=acl_write_rejected:/Users/provider",
                "[2026-08-19T01:06:00Z] autoupdate lifecycle_transition=watchdog_recovery reason_code=watchdog_rollback_readiness",
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/provider")
        )

        XCTAssertNil(finding)
    }

    func testHomeAutoupdateACLRejectionReadsPastInMemoryTailFromLogFile() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        var lines = (0..<250).map { "noise line \($0)" }
        lines.insert(
            "[2026-08-19T01:05:42Z] autoupdate recovery_error=acl_write_rejected:/Users/provider",
            at: 0
        )
        try (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)

        XCTAssertNil(
            ProviderLogDiagnostics.homeAutoupdateACLRejection(
                lines: Array(lines.suffix(200)),
                homeDirectory: URL(fileURLWithPath: "/Users/provider")
            )
        )
        let finding = ProviderLogDiagnostics.homeAutoupdateACLRejection(
            logFile: log,
            homeDirectory: URL(fileURLWithPath: "/Users/provider")
        )
        XCTAssertEqual(finding?.id, "autoupdate_home_acl_rejected")
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
                "provider process unhealthy: launchd service live.malibu.provider has no validated PID at /Users/provider/macprovider-cli"
            ]
        )

        XCTAssertEqual(finding?.id, "artifact_hash_mismatch")
    }

    func testCurrentLaunchdRepairTakesPrecedenceOverGenericProviderFinding() {
        let finding = ProviderLogDiagnostics.diagnose(
            providerLines: [
                "provider process unhealthy: launchd service live.malibu.provider has no validated PID at /Users/provider/macprovider-cli",
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

    func testAutoupdateDisabledRequiresCanonicalFalseValuedKey() {
        XCTAssertEqual(
            ProviderLogDiagnostics.diagnose(lines: ["auto_update_enabled: false"])?.id,
            "autoupdate_disabled"
        )
        XCTAssertEqual(
            ProviderLogDiagnostics.diagnose(lines: ["status autoupdate.enabled=false"])?.id,
            "autoupdate_disabled"
        )
        XCTAssertEqual(
            ProviderLogDiagnostics.diagnose(lines: [#"{"auto_update_enabled":false}"#])?.id,
            "autoupdate_disabled"
        )
        XCTAssertNil(ProviderLogDiagnostics.diagnose(lines: ["autoupdate_disabled=false"]))
        XCTAssertNil(ProviderLogDiagnostics.diagnose(lines: ["cleared autoupdate_disabled"]))
        XCTAssertNil(ProviderLogDiagnostics.diagnose(lines: ["autoupdate_enabled: false"]))
        XCTAssertNil(ProviderLogDiagnostics.diagnose(lines: ["auto_update_enabled: true"]))
        XCTAssertNil(ProviderLogDiagnostics.diagnose(lines: ["prefix_auto_update_enabled=false"]))
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
