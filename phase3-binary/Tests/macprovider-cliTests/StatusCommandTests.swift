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
