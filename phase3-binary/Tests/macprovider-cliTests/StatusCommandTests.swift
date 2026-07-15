import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class StatusCommandTests: XCTestCase {
    func testStatus_WhenOwnerTxtPresent_PrintsOwnerLine() throws {
        let fixture = try makeFixture(prefix: "status-owner")
        try ClaimURLFile(directory: fixture.directory).writeOwner(githubLogin: "deboxfinance")

        let output = LocalStatusFormatter.format(
            status(providerID: "provider-a"),
            latestVersion: nil,
            ownerLogin: OwnerFileReader.githubLogin(configPath: fixture.configPath)
        )

        XCTAssertTrue(output.contains("Provider ID:  provider-a"), output)
        XCTAssertTrue(output.contains("Owner: deboxfinance (github.com/deboxfinance)"), output)
        XCTAssertLessThan(
            try XCTUnwrap(output.range(of: "Provider ID:  provider-a")?.lowerBound),
            try XCTUnwrap(output.range(of: "Owner: deboxfinance (github.com/deboxfinance)")?.lowerBound)
        )
    }

    func testStatus_WhenOwnerTxtAbsent_PrintsUnclaimedLine() throws {
        let fixture = try makeFixture(prefix: "status-unclaimed")

        let output = LocalStatusFormatter.format(
            status(providerID: "provider-a"),
            latestVersion: nil,
            ownerLogin: OwnerFileReader.githubLogin(configPath: fixture.configPath)
        )

        XCTAssertTrue(output.contains("Owner: (unclaimed — run `macprovider-cli claim`)"), output)
    }

    func testStatus_WhenOwnerTxtMalformed_PrintsUnclaimedLine() throws {
        let fixture = try makeFixture(prefix: "status-malformed")
        let ownerURL = ClaimURLFile(directory: fixture.directory).ownerURL
        try "not_github_login=octo\n".write(to: ownerURL, atomically: true, encoding: .utf8)

        let output = LocalStatusFormatter.format(
            status(providerID: "provider-a"),
            latestVersion: nil,
            ownerLogin: OwnerFileReader.githubLogin(configPath: fixture.configPath)
        )

        XCTAssertTrue(output.contains("Owner: (unclaimed — run `macprovider-cli claim`)"), output)
    }

    func testStatus_WhenOwnerTxtContainsInvalidLogin_PrintsUnclaimedLine() throws {
        let fixture = try makeFixture(prefix: "status-invalid-owner")
        let ownerURL = ClaimURLFile(directory: fixture.directory).ownerURL
        try "github_login=bad/login\n".write(to: ownerURL, atomically: true, encoding: .utf8)

        let output = LocalStatusFormatter.format(
            status(providerID: "provider-a"),
            latestVersion: nil,
            ownerLogin: OwnerFileReader.githubLogin(configPath: fixture.configPath)
        )

        XCTAssertTrue(output.contains("Owner: (unclaimed — run `macprovider-cli claim`)"), output)
    }

    func testStatusShowsDonorModeBadge() {
        let output = LocalStatusFormatter.format(
            status(providerID: "provider-a"),
            latestVersion: nil,
            donorMode: true
        )

        XCTAssertTrue(output.contains("Model:       model-a DONOR MODE"), output)
    }

    func testStatusShowsStaleRecommendationWarning() {
        let staleSince = ISO8601DateFormatter.autotuneInternet.date(from: "2026-07-01T00:00:00Z")!

        let output = LocalStatusFormatter.format(
            status(providerID: "provider-a"),
            latestVersion: nil,
            staleRecommendationSince: staleSince
        )

        XCTAssertTrue(output.contains("Recommendation stale: recommendation inputs changed since 2026-07-01T00:00:00Z."), output)
        XCTAssertTrue(output.contains("Run: macprovider-cli autotune --recommend"), output)
    }

    func testStatusShowsActionableAdmissionIdentityRecoveryContract() {
        var payload = status(providerID: "provider-a")
        payload["admission_identity"] = [
            "source": "cli_keychain_pending",
            "state": "recovery_pending",
            "public_key_sha256": String(repeating: "a", count: 64),
            "pending_public_key_sha256": String(repeating: "a", count: 64),
            "previous_public_key_sha256": String(repeating: "c", count: 64),
            "previous_valid_until": "2026-07-21T12:00:00Z",
            "coordinator_generation": 2,
            "coordinator_key_role": "previous",
            "coordinator_public_key_sha256": String(repeating: "b", count: 64),
            "recovery_action": "obtain_operator_recovery_approval_then_restart",
        ]

        let output = LocalStatusFormatter.format(
            payload,
            configPath: "/tmp/provider config.yaml"
        )

        XCTAssertTrue(output.contains("State:       recovery_pending"), output)
        XCTAssertTrue(output.contains(String(repeating: "a", count: 64)), output)
        XCTAssertTrue(output.contains("Previous until: 2026-07-21T12:00:00Z"), output)
        XCTAssertTrue(output.contains("POST /admin/provider-admission-identity/recover"), output)
        XCTAssertTrue(output.contains("--config '/tmp/provider config.yaml' --expected-provider-id 'provider-a' --activate"), output)
    }

    private func makeFixture(prefix: String) throws -> StatusFixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configPath = dir.appendingPathComponent("config.yaml").path
        return StatusFixture(directory: dir, configPath: configPath)
    }

    private func status(providerID: String) -> [String: Any] {
        [
            "binary_version": "1.5.0",
            "provider_id": providerID,
            "model": "model-a",
            "status": "ready",
            "uptime_s": 60,
            "requests_total": 1,
            "errors_total": 0,
            "active_request_id_count": 0,
            "capacity": [
                "ram_gb": 16,
                "ram_tier": "16GB",
                "max_context_tokens": 50_000,
            ],
            "coordinator": [
                "url": "wss://coordinator.example/ws/provider",
                "connected": true,
                "session": "provider-a",
                "tier": 2,
                "recommended_binary_version": "1.5.0",
            ],
        ]
    }
}

private struct StatusFixture {
    let directory: URL
    let configPath: String
}
