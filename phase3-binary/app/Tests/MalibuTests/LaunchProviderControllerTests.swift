import XCTest
@testable import Malibu

@MainActor
final class LaunchProviderControllerTests: XCTestCase {

    private func makeController(_ harness: Harness) -> LaunchProviderController {
        let controller = LaunchProviderController(dependencies: harness.dependencies())
        controller.referralCode = Harness.validReferralCode
        return controller
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
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(
            controller.stage,
            .failed(stage: "referral", retryable: true, message: "Enter a valid Malibu pre-beta invite code.")
        )
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
    }

    func testReferralFormatMatchesInstallerContract() {
        XCTAssertTrue(LaunchProviderController.isValidReferralCode(Harness.validReferralCode))
        XCTAssertFalse(LaunchProviderController.isValidReferralCode("MAL1-S-key-seed-short"))
        XCTAssertFalse(LaunchProviderController.isValidReferralCode("MAL1-X-key-seed-AAAAAAAAAAAAAAAAAAAAAAAAAA"))
    }

    func testFreshInstallRejectsExhaustedReferralBeforeInstaller() async {
        let harness = Harness()
        harness.referralPreflight = ReferralPreflightResult(valid: false, reason: "exhausted")
        let controller = makeController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(
            controller.stage,
            .failed(stage: "referral", retryable: true, message: "This invite has already been used. Use a different invite.")
        )
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
                message: "An invite code is required. Enter a new invite code."
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
            .failed(stage: "referral", retryable: true, message: "An invite code is required. Enter a new invite code.")
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
                }
            )
        }
    }
}
