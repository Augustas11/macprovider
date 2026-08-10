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
            ownerLogin: OwnerFileReader.githubLogin(configPath: fixture.configPath),
            advanced: true
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
            ownerLogin: OwnerFileReader.githubLogin(configPath: fixture.configPath),
            advanced: true
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
            ownerLogin: OwnerFileReader.githubLogin(configPath: fixture.configPath),
            advanced: true
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
            ownerLogin: OwnerFileReader.githubLogin(configPath: fixture.configPath),
            advanced: true
        )

        XCTAssertTrue(output.contains("Owner: (unclaimed — run `macprovider-cli claim`)"), output)
    }

    func testStatusShowsDonorModeBadge() {
        let output = LocalStatusFormatter.format(
            status(providerID: "provider-a"),
            latestVersion: nil,
            donorMode: true,
            advanced: true
        )

        XCTAssertTrue(output.contains("Model:       model-a DONOR MODE"), output)
    }

    func testStatusShowsStaleRecommendationWarning() {
        let staleSince = ISO8601DateFormatter.autotuneInternet.date(from: "2026-07-01T00:00:00Z")!

        let output = LocalStatusFormatter.format(
            status(providerID: "provider-a"),
            latestVersion: nil,
            staleRecommendationSince: staleSince,
            advanced: true
        )

        XCTAssertTrue(output.contains("Recommendation stale: recommendation inputs changed since 2026-07-01T00:00:00Z."), output)
        XCTAssertTrue(output.contains("Run: macprovider-cli autotune --recommend"), output)
    }

    func testLocalStatusJSONIncludesCredentialPresenceBooleans() async throws {
        let providerStatus = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 20_000, maxConcurrencyOverride: 1)
        )
        let snapshot = await providerStatus.snapshot()
        let body = RouterHandler.statusResponse(
            snapshot,
            providerID: "provider-a",
            coordinatorURL: "wss://user:password@coordinator.example/private?api_key=secret#fragment",
            credentialStatus: ProviderCredentialStatus(source: .cliKeychain, state: .ready, restartSafe: true)
        )

        let credential = try XCTUnwrap(body["credential"] as? [String: Any])
        XCTAssertEqual(credential["token_configured"] as? Bool, true)
        XCTAssertEqual(credential["bootstrap_mode"] as? Bool, false)
        XCTAssertNil(String(describing: credential).range(of: "mpk_", options: [.caseInsensitive]))
        let encoded = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("password"), text)
        XCTAssertFalse(text.contains("api_key"), text)
        XCTAssertFalse(text.contains("/private"), text)
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
            configPath: "/tmp/provider config.yaml",
            advanced: true
        )

        XCTAssertTrue(output.contains("State:       recovery_pending"), output)
        XCTAssertTrue(output.contains(String(repeating: "a", count: 64)), output)
        XCTAssertTrue(output.contains("Previous until: 2026-07-21T12:00:00Z"), output)
        XCTAssertTrue(output.contains("POST /admin/provider-admission-identity/recover"), output)
        XCTAssertTrue(output.contains("--config '/tmp/provider config.yaml' --expected-provider-id 'provider-a' --activate"), output)
    }

    func testDefaultStatusUsesPublicLifecycleLanguage() {
        let policy = try! publicLanguagePolicy()
        let prohibited = policy.terms.map(\.internalTerm)
        let cases: [(String, String, Bool, Bool, String)] = [
            ("buyer_serving", "ready", true, true, "Provider is ready"),
            ("not_buyer_serving", "ready", true, true, "Customer availability is temporarily interrupted"),
            ("buyer_serving_unknown", "ready", true, true, "Waiting for network approval"),
            ("catalog_update_required", "ready", true, true, "This Mac is not currently eligible"),
            ("live_verified", "unavailable", true, false, "Model is preparing"),
            ("live_verified", "ready", false, true, "Provider is connecting"),
            ("buyer_serving", "ready", false, true, "Provider is connecting"),
        ]

        for (networkState, localState, connected, modelLoaded, expectedTitle) in cases {
            var payload = status(providerID: "provider-a")
            payload["network_state"] = networkState
            payload["status"] = localState
            payload["model_loaded"] = modelLoaded
            var coordinator = payload["coordinator"] as! [String: Any]
            coordinator["connected"] = connected
            payload["coordinator"] = coordinator

            let output = LocalStatusFormatter.format(payload, latestVersion: "1.5.0")

            XCTAssertTrue(output.contains(expectedTitle), output)
            XCTAssertTrue(output.contains("Advanced diagnostics: macprovider-cli status --advanced"), output)
            for term in prohibited {
                XCTAssertFalse(output.lowercased().contains(term), "\(term) leaked in:\n\(output)")
            }
            XCTAssertNil(output.range(of: policy.specificationIdentifierPattern, options: [.regularExpression, .caseInsensitive]), output)
        }
    }

    func testDefaultBlockedStatusShowsOneSafeNextStep() {
        var payload = status(providerID: "provider-a")
        payload["network_state"] = "not_buyer_serving"

        let output = LocalStatusFormatter.format(payload)

        XCTAssertEqual(output.components(separatedBy: "Next step:").count - 1, 1, output)
        XCTAssertTrue(output.contains("Keep Malibu open while the coordinator refreshes this Mac's routing status."), output)
    }

    func testDefaultStatusSurfacesHardwareVerificationLifecycle() {
        var pending = status(providerID: "provider-a")
        pending["network_state"] = "live_verified"
        pending["status"] = "ready"
        pending["model_loaded"] = true
        pending["coordinator"] = ["connected": false]
        pending["lifecycle"] = [
            "state": "coordinator_unavailable",
            "reason_code": "autotune_evidence_required",
        ]

        let pendingOutput = LocalStatusFormatter.format(pending)
        XCTAssertTrue(pendingOutput.contains("Pending hardware verification"), pendingOutput)
        XCTAssertTrue(
            pendingOutput.contains("autotune --recommend --freshness-check --require-hardware-evidence"),
            pendingOutput
        )

        var rejected = status(providerID: "provider-a")
        rejected["network_state"] = "live_verified"
        rejected["status"] = "ready"
        rejected["model_loaded"] = true
        rejected["coordinator"] = ["connected": false]
        rejected["lifecycle"] = [
            "state": "catalog_incompatible",
            "reason_code": "autotune_evidence_invalid",
        ]

        let rejectedOutput = LocalStatusFormatter.format(rejected)
        XCTAssertTrue(rejectedOutput.contains("Not eligible: admission evidence failed"), rejectedOutput)
        XCTAssertTrue(rejectedOutput.contains("autotune --recommend --recover-hardware-admission"), rejectedOutput)

        var uncatalogued = status(providerID: "provider-a")
        uncatalogued["network_state"] = "live_verified"
        uncatalogued["status"] = "ready"
        uncatalogued["model_loaded"] = true
        uncatalogued["coordinator"] = ["connected": false]
        uncatalogued["lifecycle"] = [
            "state": "catalog_incompatible",
            "reason_code": "autotune_model_uncatalogued",
        ]

        let uncataloguedOutput = LocalStatusFormatter.format(uncatalogued)
        XCTAssertTrue(uncataloguedOutput.contains("This Mac is not currently eligible"), uncataloguedOutput)
        XCTAssertTrue(
            uncataloguedOutput.contains("autotune --recommend --recover-hardware-admission"),
            uncataloguedOutput
        )
    }

    func testRoutineCLIHelpUsesCanonicalPublicLanguage() {
        let policy = try! publicLanguagePolicy()
        let helpMessages = [
            MacProviderCLI.helpMessage(),
            ServeCommand.helpMessage(),
            StatusCommand.helpMessage(),
            ModelsSwitchCommand.helpMessage(),
            AutotuneCommand.helpMessage(),
            Spec028CanaryCommand.helpMessage(),
            Spec028BenchmarkCommand.helpMessage(),
        ]

        for help in helpMessages {
            XCTAssertNil(help.range(of: policy.specificationIdentifierPattern, options: [.regularExpression, .caseInsensitive]), help)
            XCTAssertNil(help.range(of: #"\bAC-[0-9]+\b"#, options: [.regularExpression, .caseInsensitive]), help)
            for term in policy.terms.map(\.internalTerm) {
                XCTAssertFalse(help.lowercased().contains(term), "\(term) leaked in:\n\(help)")
            }
        }
        XCTAssertTrue(MacProviderCLI.helpMessage().contains("hardware-check"))
        XCTAssertTrue(MacProviderCLI.helpMessage().contains("performance-check"))
        XCTAssertFalse(MacProviderCLI.helpMessage().contains("spec028"))
        XCTAssertTrue(Spec028CanaryCommand.helpMessage().contains("supported-16gb"))
        XCTAssertFalse(Spec028CanaryCommand.helpMessage().contains("ac10"))
        for hiddenCommand in ["bootstrap-auth", "credentials", "decode-bench", "enroll", "lifecycle-state", "lifecycle-lease", "rotate-key"] {
            XCTAssertFalse(MacProviderCLI.helpMessage().contains(hiddenCommand), MacProviderCLI.helpMessage())
        }
    }

    func testHardwareCheckKeepsLegacyAutomationProfileAliases() {
        XCTAssertEqual(Spec028CanaryCommand.HardwareProfile(argument: "ac10"), .supported16GB)
        XCTAssertEqual(Spec028CanaryCommand.HardwareProfile(argument: "ac11"), .supported8GB)
        XCTAssertEqual(Spec028CanaryCommand.HardwareProfile(argument: "supported-16gb"), .supported16GB)
        XCTAssertEqual(Spec028CanaryCommand.HardwareProfile(argument: "supported-8gb"), .supported8GB)
    }

    func testLegacyHardwareCommandsRemainParseableButHidden() throws {
        let canary = try MacProviderCLI.parseAsRoot([
            "spec028-canary", "ac10", "--baseline-runs", "1", "--spec-runs", "1",
        ])
        let benchmark = try MacProviderCLI.parseAsRoot([
            "spec028-benchmark", "--baseline-runs", "1", "--spec-runs", "1",
        ])

        XCTAssertTrue(canary is LegacySpec028CanaryCommand)
        XCTAssertTrue(benchmark is LegacySpec028BenchmarkCommand)
        XCTAssertFalse(MacProviderCLI.helpMessage().contains("spec028-canary"))
        XCTAssertFalse(MacProviderCLI.helpMessage().contains("spec028-benchmark"))
    }

    private func publicLanguagePolicy() throws -> PublicLanguagePolicy {
        let testFile = URL(fileURLWithPath: #filePath)
        let policyURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("public-language.json")
        return try JSONDecoder().decode(PublicLanguagePolicy.self, from: Data(contentsOf: policyURL))
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

private struct PublicLanguagePolicy: Decodable {
    struct Term: Decodable {
        let internalTerm: String

        enum CodingKeys: String, CodingKey {
            case internalTerm = "internal"
        }
    }

    let terms: [Term]
    let specificationIdentifierPattern: String

    enum CodingKeys: String, CodingKey {
        case terms
        case specificationIdentifierPattern = "specification_identifier_pattern"
    }
}

private struct StatusFixture {
    let directory: URL
    let configPath: String
}
