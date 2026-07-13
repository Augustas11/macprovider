import XCTest
@testable import Malibu

@MainActor
final class LaunchProviderControllerTests: XCTestCase {

    private func makeController(_ harness: Harness) -> LaunchProviderController {
        let controller = LaunchProviderController(dependencies: harness.dependencies())
        controller.referralCode = Harness.validReferralCode
        return controller
    }

    func testReferralPolicyStartsUnknownAndUsesBoundedLiveDiscovery() {
        let controller = LaunchProviderController(dependencies: Harness().dependencies())

        XCTAssertEqual(controller.referralPolicy, .unknown)
        XCTAssertFalse(controller.referralRequired)
        XCTAssertTrue(controller.showsReferralField)
        XCTAssertLessThanOrEqual(LaunchProviderController.referralPolicyRequestTimeout, 8)
        XCTAssertLessThanOrEqual(LaunchProviderController.referralPolicyResourceTimeout, 10)
    }

    func testReferralPreflightDecodesOnlyConfiguredAbsoluteHTTPSAccessURL() throws {
        let present = try JSONDecoder().decode(
            ReferralPreflightResult.self,
            from: Data(#"{"valid":false,"reason":"expired","required":true,"request_access_url":"https://access.example.test/waitlist"}"#.utf8)
        )
        XCTAssertEqual(present.requestAccessURL?.absoluteString, "https://access.example.test/waitlist")

        let absent = try JSONDecoder().decode(
            ReferralPreflightResult.self,
            from: Data(#"{"valid":false,"reason":"expired","required":true}"#.utf8)
        )
        XCTAssertNil(absent.requestAccessURL)

        for raw in ["http://access.example.test", "/relative", "https://user:secret@access.example.test"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "valid": false,
                "reason": "expired",
                "required": true,
                "request_access_url": raw,
            ])
            let decoded = try JSONDecoder().decode(ReferralPreflightResult.self, from: data)
            XCTAssertNil(decoded.requestAccessURL, "unexpected access URL for \(raw)")
        }
    }

    func testRefreshRetainsCoordinatorConfiguredAccessURL() async {
        let harness = Harness()
        harness.referralPreflight = ReferralPreflightResult(
            valid: false,
            reason: "missing",
            requestAccessURL: URL(string: "https://access.example.test/waitlist")
        )
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.refreshReferralPolicy()

        XCTAssertEqual(controller.requestAccessURL?.absoluteString, "https://access.example.test/waitlist")
    }

    func testLaunchViaCLIInstallWhenNotAlreadyRunning() async {
        let harness = Harness()
        let controller = makeController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(harness.cliImportRuns, 1)
        XCTAssertEqual(harness.monitorRuns, 1)
        XCTAssertEqual(harness.loginItemRegistrations, 1)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testFreshInstallRequiresWellFormedReferral() async {
        let harness = Harness()
        harness.referralPreflight = ReferralPreflightResult(valid: false, reason: "missing")
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(
            controller.stage,
            .failed(stage: "referral", retryable: true, message: "An invite is required. Enter an invite code or link.")
        )
        XCTAssertNil(controller.requestAccessURL)
    }

    func testExistingIdentityRepairRunsWithoutReferral() async {
        let harness = Harness()
        harness.appIdentityConfigured = true
        harness.expectedReferralCode = ""
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.refreshReferralPolicy()
        await controller.launch()

        XCTAssertFalse(controller.referralRequired)
        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(harness.cliImportRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 0)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testMissingBearerStopsBeforeInviteOrInstallerAndRetryDoesNotLoop() async {
        let harness = Harness()
        harness.existingIdentityMissingBearer = true
        harness.providerID = "p_missing_bearer"
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        XCTAssertEqual(controller.stage, .existingIdentityMissingBearer(providerID: "p_missing_bearer"))
        XCTAssertEqual(harness.cliInstallRuns, 0)

        await controller.retry()
        XCTAssertEqual(controller.stage, .existingIdentityMissingBearer(providerID: "p_missing_bearer"))
        XCTAssertEqual(harness.cliInstallRuns, 0)
    }

    func testInstallerRepairModeIsBoundToExistingCredential() {
        let fresh = CLIInstallRunner.installerEnvironment(
            base: [
                "MACPROVIDER_PROVIDER_TOKEN": "inherited-token",
                "MACPROVIDER_APP_MANAGED_REPAIR": "1",
            ],
            referralCode: Harness.validReferralCode,
            appManagedRepair: false,
            installPort: 18080,
            home: "/Users/test"
        )
        XCTAssertNil(fresh["MACPROVIDER_PROVIDER_TOKEN"])
        XCTAssertNil(fresh["MACPROVIDER_APP_MANAGED_REPAIR"])
        XCTAssertEqual(fresh["MACPROVIDER_REFERRAL_CODE"], Harness.validReferralCode)

        let repair = CLIInstallRunner.installerEnvironment(
            base: [:],
            referralCode: "",
            appManagedRepair: true,
            installPort: 18080,
            home: "/Users/test"
        )
        XCTAssertNil(repair["MACPROVIDER_PROVIDER_TOKEN"])
        XCTAssertEqual(repair["MACPROVIDER_APP_MANAGED_REPAIR"], "1")
        XCTAssertEqual(repair["MACPROVIDER_REFERRAL_CODE"], "")

        XCTAssertEqual(
            CLIInstallRunner.installerArguments(scriptPath: "/tmp/install.sh", appManagedRepair: false),
            ["/tmp/install.sh"]
        )
        XCTAssertEqual(
            CLIInstallRunner.installerArguments(scriptPath: "/tmp/install.sh", appManagedRepair: true),
            ["/tmp/install.sh", "--provider-token-fd", "0"]
        )
    }

    func testReferralFormatMatchesInstallerContract() {
        XCTAssertTrue(LaunchProviderController.isValidReferralCode(Harness.validReferralCode))
        XCTAssertFalse(LaunchProviderController.isValidReferralCode("MAL1-S-key-seed-short"))
        XCTAssertFalse(LaunchProviderController.isValidReferralCode("MAL1-X-key-seed-AAAAAAAAAAAAAAAAAAAAAAAAAA"))
    }

    func testCanonicalInviteURLIsNormalizedBeforeInstaller() async {
        let harness = Harness()
        let controller = LaunchProviderController(dependencies: harness.dependencies())
        controller.referralCode = "https://coordinator.streamvc.live/j/\(Harness.validReferralCode)?c=x-post"

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(controller.normalizedReferralCode, Harness.validReferralCode)
    }

    func testNonCanonicalInviteURLIsNotExtracted() {
        XCTAssertEqual(
            LaunchProviderController.extractReferralCode(
                "  https://coordinator.streamvc.live/j/\(Harness.validReferralCode)/?c=x-post#install  "
            ),
            Harness.validReferralCode
        )
        XCTAssertEqual(
            LaunchProviderController.extractReferralCode(
                "http://coordinator.streamvc.live/j/\(Harness.validReferralCode)"
            ),
            "http://coordinator.streamvc.live/j/\(Harness.validReferralCode)"
        )
        XCTAssertEqual(
            LaunchProviderController.extractReferralCode(
                "https://coordinator.streamvc.live/?next=/j/\(Harness.validReferralCode)"
            ),
            "https://coordinator.streamvc.live/?next=/j/\(Harness.validReferralCode)"
        )
        XCTAssertEqual(
            LaunchProviderController.extractReferralCode(
                "https://coordinator.streamvc.live/j/\(Harness.validReferralCode)/extra"
            ),
            "https://coordinator.streamvc.live/j/\(Harness.validReferralCode)/extra"
        )
        XCTAssertEqual(
            LaunchProviderController.extractReferralCode(
                "https://coordinator.streamvc.live/j/\(Harness.validReferralCode)//"
            ),
            "https://coordinator.streamvc.live/j/\(Harness.validReferralCode)//"
        )
    }

    func testFreshInstallRejectsExhaustedReferralBeforeInstaller() async {
        let harness = Harness()
        harness.referralPreflight = ReferralPreflightResult(
            valid: false,
            reason: "exhausted",
            requestAccessURL: URL(string: "https://access.example.test/waitlist")
        )
        let controller = makeController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(
            controller.stage,
            .failed(stage: "referral", retryable: true, message: "All spots on this invite are taken. Use a different invite.")
        )
        XCTAssertEqual(controller.requestAccessURL?.absoluteString, "https://access.example.test/waitlist")
    }

    func testDefaultOffPolicyAllowsFreshInstallWithoutReferral() async {
        let harness = Harness()
        harness.referralPreflight = ReferralPreflightResult(valid: true, reason: "disabled", required: false)
        harness.expectedReferralCode = ""
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.refreshReferralPolicy()
        await controller.launch()

        XCTAssertFalse(controller.referralRequired)
        XCTAssertEqual(harness.cliInstallRuns, 1)
    }

    func testLaunchSkipsInstallerWhenLocalProviderAlreadyHealthy() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        harness.appIdentityConfigured = true
        let controller = makeController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.cliImportRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 0)
        XCTAssertEqual(harness.loginItemRegistrations, 1)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testLaunchInstallFailureIsRetryable() async {
        let harness = Harness()
        harness.cliInstallError = NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "install failed"])
        let controller = makeController(harness)

        await controller.launch()

        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "cliInstall")
            XCTAssertTrue(retryable)
            XCTAssertEqual(message, "install failed")
        } else {
            XCTFail("expected failed cliInstall stage")
        }
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        XCTAssertEqual(harness.startAgentRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 0)
    }

    func testLaunchMonitorFailureIsRetryable() async {
        let harness = Harness()
        harness.monitorHealthy = false
        let controller = makeController(harness)

        await controller.launch()

        if case let .failed(stage, retryable, _) = controller.stage {
            XCTAssertEqual(stage, "cliInstall")
            XCTAssertTrue(retryable)
        } else {
            XCTFail("expected failed cliInstall stage after monitor timeout")
        }
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        XCTAssertEqual(harness.startAgentRuns, 0)
    }

    func testRetryRerunsInstallAfterFailure() async {
        let harness = Harness()
        harness.cliInstallError = NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "install failed"])
        let controller = makeController(harness)

        await controller.launch()
        harness.cliInstallError = nil
        await controller.retry()

        XCTAssertEqual(harness.cliInstallRuns, 2)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testRefreshFromExistingInstallConnectsWithoutInstaller() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        harness.appIdentityConfigured = true
        let controller = makeController(harness)

        await controller.refreshFromExistingInstall()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 0)
        XCTAssertEqual(harness.loginItemRegistrations, 1)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testPermanentImportFailureDoesNotWaitForProviderStart() async {
        let harness = Harness()
        harness.cliImportErrors = [
            NSError(domain: "tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "import failed"])
        ]
        let controller = makeController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(harness.cliImportRuns, 1)
        XCTAssertEqual(harness.monitorRuns, 0)
        XCTAssertEqual(harness.importRetryWaits, 0)
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        XCTAssertEqual(harness.startAgentRuns, 0)
        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "identityImport")
            XCTAssertTrue(retryable)
            XCTAssertEqual(message, "import failed")
        } else {
            XCTFail("expected retryable failed stage after permanent import failure")
        }
    }

    func testTokenlessFirstImportRetriesAfterProviderBecomesHealthy() async {
        let harness = Harness()
        harness.markLocalInstallSucceededAfterInstall = false
        harness.cliImportErrors = [ProviderConfig.SaveError.missingProviderToken]
        let controller = makeController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(harness.cliImportRuns, 2)
        XCTAssertEqual(harness.monitorRuns, 1)
        XCTAssertEqual(harness.loginItemRegistrations, 1)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(harness.importRetryWaits, 0)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testRetryAfterPersistentImportFailureDoesNotBypassIdentityImport() async {
        let harness = Harness()
        harness.cliImportErrors = Array(
            repeating: ProviderConfig.SaveError.missingProviderToken,
            count: 2 * (MalibuOnboardingTimeouts.providerTokenImportRetryAttempts + 1)
        )
        let controller = makeController(harness)

        await controller.launch()
        await controller.retry()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(
            harness.cliImportRuns,
            2 * (MalibuOnboardingTimeouts.providerTokenImportRetryAttempts + 1)
        )
        XCTAssertEqual(harness.monitorRuns, 2)
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        XCTAssertEqual(harness.startAgentRuns, 0)
        XCTAssertEqual(harness.importRetryWaits, 2 * (MalibuOnboardingTimeouts.providerTokenImportRetryAttempts - 1))
        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "identityImport")
            XCTAssertTrue(retryable)
            XCTAssertEqual(
                message,
                "Provider identity was not fully imported after the background provider became healthy. Retry setup once the provider token is available."
            )
        } else {
            XCTFail("expected retryable failed stage after retry exhausts identity import again")
        }
    }

    func testExistingInstallPermanentImportFailureDoesNotBypassIdentityImport() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        harness.cliImportErrors = [
            ProviderConfig.SaveError.importKeychainVerificationFailed
        ]
        let controller = makeController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.cliImportRuns, 1)
        XCTAssertEqual(harness.monitorRuns, 0)
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        XCTAssertEqual(harness.startAgentRuns, 0)
        XCTAssertEqual(harness.importRetryWaits, 0)
        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "identityImport")
            XCTAssertTrue(retryable)
            XCTAssertEqual(message, "The imported provider token could not be verified in Keychain.")
        } else {
            XCTFail("expected identityImport failure after permanent import error")
        }
    }

    func testLaunchMonitorFailureSurfacesProviderStartFailure() async {
        let harness = Harness()
        harness.monitorHealthy = false
        harness.providerStartFailureMessage =
            "Model catalog is out of date for this Mac. Update Malibu to the latest release, "
            + "or run: macprovider-cli autotune --recommend --apply"
        let controller = makeController(harness)

        await controller.launch()

        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "cliInstall")
            XCTAssertTrue(retryable)
            XCTAssertEqual(message, harness.providerStartFailureMessage)
        } else {
            XCTFail("expected failed cliInstall stage with provider start failure")
        }
    }

    // PROD-M4: after policy discovery leaves the invite non-required, an
    // authoritative `referral_required` rejection from the install log must
    // re-gate to a mandatory invite (not a generic Retry with no invite field).
    func testAuthoritativeReferralRequiredReGatesToMandatoryInvite() async {
        let harness = Harness()
        harness.referralPreflight = ReferralPreflightResult(valid: true, reason: "disabled", required: false)
        harness.installLogLines = ["macprovider-install FATAL: MACPROVIDER_REFERRAL_REJECTED referral_required"]
        harness.cliInstallError = NSError(
            domain: "tests", code: 6, userInfo: [NSLocalizedDescriptionKey: "install failed"]
        )
        let controller = makeController(harness)

        await controller.refreshReferralPolicy()
        XCTAssertFalse(controller.referralRequired)

        await controller.launch()

        XCTAssertTrue(controller.referralRequired)
        XCTAssertEqual(
            controller.stage,
            .failed(
                stage: "referral",
                retryable: true,
                message: "An invite is required. Enter an invite code or link."
            )
        )
    }

    // PROD-M1: when policy discovery failed (.unknown) and no invite is
    // supplied, an authoritative `required` preflight must re-gate to the
    // editable invite step BEFORE the expensive installer runs — not after
    // 10–30 min of downloads/tuning.
    func testUnknownPolicyRejectsMissingInviteBeforeInstaller() async {
        let harness = Harness()
        harness.referralPreflightError = NSError(domain: "tests", code: 0)
        harness.referralPreflight = ReferralPreflightResult(valid: false, reason: "missing", required: true)
        harness.expectedReferralCode = ""
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.refreshReferralPolicy()
        XCTAssertFalse(controller.referralRequired)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(
            controller.stage,
            .failed(stage: "referral", retryable: true, message: "An invite is required. Enter an invite code or link.")
        )
    }

    // PROD-M1: an unknown policy with a valid supplied code validates the code
    // at preflight and then proceeds to install (no false gate).
    func testUnknownPolicyValidatesSuppliedCodeThenInstalls() async {
        let harness = Harness()
        harness.referralPreflightError = NSError(domain: "tests", code: 0)
        harness.referralPreflight = ReferralPreflightResult(valid: true, reason: "valid", required: true)
        let controller = makeController(harness)

        await controller.refreshReferralPolicy()
        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testAttachFailureDoesNotRegisterLoginItemOrMarkLive() async {
        let harness = Harness()
        harness.attachHealthy = false
        harness.providerStartFailureMessage = "provider attach failed"
        let controller = makeController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(harness.cliImportRuns, 1)
        XCTAssertEqual(harness.monitorRuns, 1)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "cliInstall")
            XCTAssertTrue(retryable)
            XCTAssertEqual(message, "provider attach failed")
        } else {
            XCTFail("expected failed cliInstall stage after attach failure")
        }
    }

    // PROD-M6: "Start New" records the retired identity (id + archive path) so
    // the UI can name it and offer a local-file restore; restoring clears the
    // archive banner without claiming credential or serving recovery.
    func testStartAsNewProviderRecordsRetiredIdentityAndRestoresArchivedFiles() async {
        let harness = Harness()
        harness.providerID = "p_retire_me"
        let archive = URL(fileURLWithPath: "/tmp/malibu-archive-xyz")
        harness.startFreshArchive = archive
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.startAsNewProvider()

        XCTAssertEqual(controller.retiredIdentity?.providerID, "p_retire_me")
        XCTAssertEqual(controller.retiredIdentity?.archivePath, archive.path)
        XCTAssertEqual(controller.stage, .idle)

        await controller.restoreRetiredProviderFiles()

        XCTAssertEqual(harness.restoreRuns, 1)
        XCTAssertNil(controller.retiredIdentity)
        XCTAssertEqual(controller.stage, .idle)
    }

    func testRestoreRetiredProviderFilesReturnsToMissingCredentialRecovery() async {
        let harness = Harness()
        harness.providerID = "p_still_missing"
        harness.startFreshArchive = URL(fileURLWithPath: "/tmp/malibu-archive-xyz")
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.startAsNewProvider()
        harness.existingIdentityMissingBearer = true
        await controller.restoreRetiredProviderFiles()

        XCTAssertEqual(harness.restoreRuns, 1)
        XCTAssertEqual(
            controller.stage,
            .existingIdentityMissingBearer(providerID: "p_still_missing")
        )
    }

    func testRestoreRetiredProviderFilesSurfacesRestoreFailure() async {
        let harness = Harness()
        harness.startFreshArchive = URL(fileURLWithPath: "/tmp/malibu-archive-xyz")
        harness.restoreError = NSError(domain: "tests", code: 9, userInfo: [NSLocalizedDescriptionKey: "occupied"])
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.startAsNewProvider()
        await controller.restoreRetiredProviderFiles()

        // The retired banner remains so the user can retry / restore manually.
        XCTAssertNotNil(controller.retiredIdentity)
        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "startFresh")
            XCTAssertTrue(retryable)
            XCTAssertTrue(message.contains("occupied"))
        } else {
            XCTFail("expected failed startFresh stage after restore failure")
        }
    }

    private final class Harness {
        static let validReferralCode = "MAL1-S-key-seed-AAAAAAAAAAAAAAAAAAAAAAAAAA"
        var localInstallSucceeded = false
        var localInstallSucceededAfterInstall = false
        var markLocalInstallSucceededAfterInstall = true
        var cliInstallRuns = 0
        var cliImportRuns = 0
        var monitorRuns = 0
        var loginItemRegistrations = 0
        var startAgentRuns = 0
        var importRetryWaits = 0
        var monitorHealthy = true
        var attachHealthy = true
        var appIdentityConfigured = false
        var existingIdentityMissingBearer = false
        var providerStartFailureMessage: String?
        var cliInstallError: Error?
        var cliImportErrors: [Error] = []
        var configModel = "mlx-community/Qwen2.5-7B-Instruct-4bit"
        var installLogLines: [String] = []
        var referralPreflight = ReferralPreflightResult(valid: true, reason: "valid")
        // PROD-M1: when set, validateReferralCode throws this on its FIRST call
        // only — used to drive policy discovery into `.unknown` (refresh) while
        // still returning a definitive result at the pre-install preflight.
        var referralPreflightError: Error?
        var expectedReferralCode = Harness.validReferralCode
        // PROD-M6: start-fresh archive + undo injection.
        var providerID = "p_existing"
        var startFreshArchive: URL? = URL(fileURLWithPath: "/tmp/malibu-test-archive")
        var startFreshError: Error?
        var restoreError: Error?
        var restoreRuns = 0

        func dependencies() -> LaunchProviderController.Dependencies {
            LaunchProviderController.Dependencies(
                localInstallSucceeded: {
                    self.localInstallSucceeded || self.localInstallSucceededAfterInstall
                },
                validateReferralCode: { _ in
                    if let error = self.referralPreflightError {
                        self.referralPreflightError = nil
                        throw error
                    }
                    return self.referralPreflight
                },
                registerLoginItem: {
                    self.loginItemRegistrations += 1
                },
                runCLIInstall: { referralCode, onLogLine in
                    XCTAssertEqual(referralCode, self.expectedReferralCode)
                    self.cliInstallRuns += 1
                    for line in self.installLogLines { onLogLine(line) }
                    if let error = self.cliInstallError { throw error }
                    self.localInstallSucceededAfterInstall = self.markLocalInstallSucceededAfterInstall
                    onLogLine("install.sh finished")
                },
                importCLIConfigAfterInstall: {
                    self.cliImportRuns += 1
                    if !self.cliImportErrors.isEmpty {
                        throw self.cliImportErrors.removeFirst()
                    }
                    self.appIdentityConfigured = true
                },
                waitForInstalledProviderHealth: {
                    self.monitorRuns += 1
                    return self.monitorHealthy
                },
                attachInstalledProviderAfterInstall: {
                    self.startAgentRuns += 1
                    return self.attachHealthy
                },
                readConfigModel: { self.configModel },
                providerStartFailure: { self.providerStartFailureMessage },
                appIdentityConfigured: { self.appIdentityConfigured },
                waitBeforeImportRetry: {
                    self.importRetryWaits += 1
                },
                existingIdentityMissingBearer: { self.existingIdentityMissingBearer },
                readProviderID: { self.providerID },
                moveAppOwnedConfigAside: {
                    if let error = self.startFreshError { throw error }
                    return self.startFreshArchive
                },
                restoreArchivedFiles: { _ in
                    self.restoreRuns += 1
                    if let error = self.restoreError { throw error }
                }
            )
        }
    }
}
