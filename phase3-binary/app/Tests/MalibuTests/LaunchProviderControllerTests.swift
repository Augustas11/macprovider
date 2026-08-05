import XCTest
@testable import Malibu

@MainActor
final class LaunchProviderControllerTests: XCTestCase {

    func testLaunchViaCLIInstallWhenNotAlreadyRunning() async {
        let harness = Harness()
        let controller = freshController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(harness.cliImportRuns, 1)
        XCTAssertEqual(harness.monitorRuns, 1)
        XCTAssertEqual(harness.loginItemRegistrations, 1)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testInstallLogsAreRedactedBeforeOnboardingStoresThem() async {
        let harness = Harness()
        harness.emittedInstallLogLines = [
            "provider_token: secret-token-value",
            "spec-023 probe completed",
        ]
        let controller = freshController(harness)

        await controller.launch()

        XCTAssertEqual(controller.installLogLines.first, "[redacted]")
        XCTAssertEqual(controller.installLogLines.last, "spec-023 probe completed")
    }

    func testLaunchSkipsInstallerWhenLocalProviderAlreadyHealthy() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        harness.appIdentityConfigured = true
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.cliImportRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 1)
        XCTAssertEqual(harness.loginItemRegistrations, 1)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testReferralOnHealthyIncumbentDoesNotReplaceWithoutConfirmation() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        harness.appIdentityConfigured = true
        let controller = freshController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertNil(harness.installedReferralCode)
        XCTAssertFalse(harness.installedReplacingIncumbentProvider)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testConfirmedReferralOnHealthyIncumbentRunsFreshReplacementInstall() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        harness.appIdentityConfigured = true
        let controller = freshController(harness, replacementConfirmed: true)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertNotNil(harness.installedReferralCode)
        XCTAssertTrue(harness.installedReplacingIncumbentProvider)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testUnhealthyRestartSafeIncumbentRunsInstallerWithoutReferral() async {
        let harness = Harness()
        harness.restartSafeIncumbentPresent = true
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertNil(harness.installedReferralCode)
        XCTAssertFalse(harness.installedReplacingIncumbentProvider)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testReferralOnRestartSafeIncumbentDoesNotReplaceWithoutConfirmation() async {
        let harness = Harness()
        harness.restartSafeIncumbentPresent = true
        let controller = freshController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertNil(harness.installedReferralCode)
        XCTAssertFalse(harness.installedReplacingIncumbentProvider)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testConfirmedReferralOnRestartSafeIncumbentRunsFreshReplacementInstall() async {
        let harness = Harness()
        harness.restartSafeIncumbentPresent = true
        let controller = freshController(harness, replacementConfirmed: true)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertNotNil(harness.installedReferralCode)
        XCTAssertTrue(harness.installedReplacingIncumbentProvider)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testPartialInstallStillAcceptsReferralForFreshRecovery() async {
        let harness = Harness()
        harness.restartSafeIncumbentPresent = false
        let controller = freshController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertNotNil(harness.installedReferralCode)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testLaunchInstallFailureIsRetryable() async {
        let harness = Harness()
        harness.cliInstallError = NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "install failed"])
        let controller = freshController(harness)

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
        let controller = freshController(harness)

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
        let controller = freshController(harness)

        await controller.launch()
        harness.cliInstallError = nil
        await controller.retry()

        XCTAssertEqual(harness.cliInstallRuns, 2)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testLaunchPassesNormalizedReferralLinkToCLIInstaller() async {
        let harness = Harness()
        let controller = freshController(harness)
        let code = "MAL1-S-key_1-issuer_1-" + String(repeating: "A", count: 26)
        controller.referralInput = "https://malibu.tech/j#/\(code)"

        await controller.launch()

        XCTAssertEqual(harness.installedReferralCode, code)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testBlankReferralInputFailsBeforeInstallerStarts() async {
        let harness = Harness()
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "referral")
            XCTAssertTrue(retryable)
            XCTAssertEqual(message, CLIInstallRunner.Error.ReferralFailure.required.message)
        } else {
            XCTFail("expected required referral correction state")
        }
    }

    func testConfirmedReplacementRequiresReferralBeforeAttachingIncumbent() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        harness.appIdentityConfigured = true
        let controller = LaunchProviderController(
            replacementConfirmed: true,
            dependencies: harness.dependencies()
        )

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 0)
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        XCTAssertEqual(harness.startAgentRuns, 0)
        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "referral")
            XCTAssertTrue(retryable)
            XCTAssertEqual(message, CLIInstallRunner.Error.ReferralFailure.required.message)
        } else {
            XCTFail("expected required referral correction state")
        }
    }

    func testInvalidReferralInputDoesNotRunInstaller() async {
        let harness = Harness()
        let controller = freshController(harness)
        controller.referralInput = "https://evil.example/j/not-an-invite"

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        if case let .failed(stage, retryable, _) = controller.stage {
            XCTAssertEqual(stage, "referral")
            XCTAssertTrue(retryable)
        } else {
            XCTFail("expected referral correction state")
        }
    }

    func testReferralInputRequiresNegotiatedCapability() async {
        let harness = Harness()
        harness.referralInputAvailable = false
        let controller = freshController(harness)
        controller.referralInput = "MAL1-S-key_1-issuer_1-" + String(repeating: "A", count: 26)

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "referral")
            XCTAssertTrue(retryable)
            XCTAssertTrue(message.contains("Invite entry is unavailable"))
            XCTAssertTrue(message.contains("provider software"))
            XCTAssertFalse(message.contains("referral_bootstrap_v1"))
        } else {
            XCTFail("expected unavailable referral correction state")
        }
    }

    func testRefreshPublishesReferralCapabilityAvailability() async {
        let harness = Harness()
        harness.referralInputAvailable = false
        let controller = freshController(harness)

        await controller.refreshReferralInputAvailability()

        XCTAssertTrue(controller.referralAvailabilityChecked)
        XCTAssertFalse(controller.referralInputAvailable)
    }

    func testReferralHandoffRequiresBundledArtifactAndInstalledCapability() {
        XCTAssertFalse(LaunchProviderController.referralHandoffAvailable(
            bundledHandoffEnabled: false,
            installedCLIAdvertisesReferralBootstrapV1: true
        ))
        XCTAssertFalse(LaunchProviderController.referralHandoffAvailable(
            bundledHandoffEnabled: true,
            installedCLIAdvertisesReferralBootstrapV1: false
        ))
        XCTAssertTrue(LaunchProviderController.referralHandoffAvailable(
            bundledHandoffEnabled: true,
            installedCLIAdvertisesReferralBootstrapV1: true
        ))
        XCTAssertTrue(LaunchProviderController.referralHandoffAvailable(
            bundledHandoffEnabled: true,
            installedCLIAdvertisesReferralBootstrapV1: nil
        ))
    }

    func testReleasedMalibuArtifactExposesBundledReferralHandoff() {
        let bundledHandoffEnabled = Bundle.main.object(
            forInfoDictionaryKey: "MalibuBundledReferralBootstrapV1"
        ) as? Bool == true

        XCTAssertTrue(bundledHandoffEnabled)
        XCTAssertTrue(LaunchProviderController.referralHandoffAvailable(
            bundledHandoffEnabled: bundledHandoffEnabled,
            installedCLIAdvertisesReferralBootstrapV1: true
        ))
    }

    func testTypedReferralFailureDoesNotDestroyIdentityOrAttachProvider() async {
        let harness = Harness()
        harness.cliInstallError = CLIInstallRunner.Error.referralFailure(.expired)
        let controller = freshController(harness)

        await controller.launch()

        XCTAssertEqual(harness.cliImportRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 0)
        XCTAssertEqual(harness.startAgentRuns, 0)
        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "referral")
            XCTAssertTrue(retryable)
            XCTAssertEqual(message, CLIInstallRunner.Error.ReferralFailure.expired.message)
        } else {
            XCTFail("expected typed referral failure")
        }
    }

    func testRefreshFromExistingInstallConnectsWithoutInstaller() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        harness.appIdentityConfigured = true
        let controller = freshController(harness)

        await controller.refreshFromExistingInstall()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 1)
        XCTAssertEqual(harness.loginItemRegistrations, 1)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testConfirmedReplacementDoesNotAutoRefreshIntoIncumbent() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        harness.appIdentityConfigured = true
        let controller = freshController(harness, replacementConfirmed: true)

        await controller.refreshFromExistingInstall()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 0)
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        XCTAssertEqual(harness.startAgentRuns, 0)
        XCTAssertEqual(controller.stage, .idle)
    }

    func testPermanentImportFailureDoesNotWaitForProviderStart() async {
        let harness = Harness()
        harness.cliImportErrors = [
            NSError(domain: "tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "import failed"])
        ]
        let controller = freshController(harness)

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
        let controller = freshController(harness)

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
        let controller = freshController(harness)

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
                "The existing provider was not fully imported after the background provider became healthy. Retry setup once saved provider access is available."
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
        let controller = freshController(harness)

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
        let controller = freshController(harness)

        await controller.launch()

        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "cliInstall")
            XCTAssertTrue(retryable)
            XCTAssertEqual(message, harness.providerStartFailureMessage)
        } else {
            XCTFail("expected failed cliInstall stage with provider start failure")
        }
    }

    func testAttachFailureDoesNotRegisterLoginItemOrMarkLive() async {
        let harness = Harness()
        harness.attachHealthy = false
        harness.providerStartFailureMessage = "provider attach failed"
        let controller = freshController(harness)

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

    private func freshController(
        _ harness: Harness,
        replacementConfirmed: Bool = false
    ) -> LaunchProviderController {
        let controller = LaunchProviderController(
            replacementConfirmed: replacementConfirmed,
            dependencies: harness.dependencies()
        )
        controller.referralInput = "MAL1-S-key_1-issuer_1-" + String(repeating: "A", count: 26)
        return controller
    }

    private final class Harness {
        var localInstallSucceeded = false
        var restartSafeIncumbentPresent = false
        var referralInputAvailable = true
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
        var emittedInstallLogLines: [String] = ["install.sh finished"]
        var installedReferralCode: String?
        var installedReplacingIncumbentProvider = false

        func dependencies() -> LaunchProviderController.Dependencies {
            LaunchProviderController.Dependencies(
                localInstallSucceeded: {
                    self.localInstallSucceeded || self.localInstallSucceededAfterInstall
                },
                restartSafeIncumbentPresent: { self.restartSafeIncumbentPresent },
                referralInputAvailable: { self.referralInputAvailable },
                registerLoginItem: {
                    self.loginItemRegistrations += 1
                },
                runCLIInstall: { referralCode, replacingIncumbentProvider, onLogLine in
                    self.cliInstallRuns += 1
                    self.installedReferralCode = referralCode
                    self.installedReplacingIncumbentProvider = replacingIncumbentProvider
                    if let error = self.cliInstallError { throw error }
                    self.localInstallSucceededAfterInstall = self.markLocalInstallSucceededAfterInstall
                    for line in self.emittedInstallLogLines {
                        onLogLine(line)
                    }
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
