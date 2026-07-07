import XCTest
@testable import Malibu

final class ProviderLogDiagnosticsTests: XCTestCase {
    func testDiagnoseStaleCatalogProvenance() {
        let finding = ProviderLogDiagnostics.diagnose(lines: [
            "loading config",
            "model catalog provenance envelope is stale (stored",
        ])

        XCTAssertEqual(finding?.id, "stale_model_catalog")
        XCTAssertTrue(finding?.userMessage.contains("autotune --recommend --apply") == true)
    }

    func testDiagnosePrefersMostRecentMatchingLine() {
        let finding = ProviderLogDiagnostics.diagnose(lines: [
            "model artifact hash mismatch for /tmp/old",
            "model catalog provenance envelope is stale (stored",
        ])

        XCTAssertEqual(finding?.id, "stale_model_catalog")
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
    }
}
