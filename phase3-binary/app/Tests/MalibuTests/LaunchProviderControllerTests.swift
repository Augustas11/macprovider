import XCTest
@testable import Malibu

@MainActor
final class LaunchProviderControllerTests: XCTestCase {

    func testLaunchViaCLIInstallWhenNotAlreadyRunning() async {
        let harness = Harness()
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(harness.pinnedInstallVersions, ["1.8.40"])
        XCTAssertEqual(harness.cliImportRuns, 1)
        XCTAssertEqual(harness.monitorRuns, 1)
        XCTAssertEqual(harness.loginItemRegistrations, 1)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
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

    func testLaunchInstallFailureIsRetryable() async {
        let harness = Harness()
        harness.cliInstallError = NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "install failed"])
        let controller = LaunchProviderController(dependencies: harness.dependencies())

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
        let controller = LaunchProviderController(dependencies: harness.dependencies())

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
        let controller = LaunchProviderController(dependencies: harness.dependencies())

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
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.refreshFromExistingInstall()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 1)
        XCTAssertEqual(harness.loginItemRegistrations, 1)
        XCTAssertEqual(harness.startAgentRuns, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    func testPermanentImportFailureDoesNotWaitForProviderStart() async {
        let harness = Harness()
        harness.cliImportErrors = [
            NSError(domain: "tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "import failed"])
        ]
        let controller = LaunchProviderController(dependencies: harness.dependencies())

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
        let controller = LaunchProviderController(dependencies: harness.dependencies())

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
        let controller = LaunchProviderController(dependencies: harness.dependencies())

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
        let controller = LaunchProviderController(dependencies: harness.dependencies())

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

    func testHealthyExistingInstallEntersObservationOnlyModeAfterMigrationFailure() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        harness.migrationObservationAvailable = true
        harness.cliImportErrors = [ProviderConfig.SaveError.importKeychainVerificationFailed]
        let controller = LaunchProviderController(dependencies: harness.dependencies())

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.cliImportRuns, 1)
        XCTAssertEqual(harness.migrationObservationRuns, 1)
        XCTAssertEqual(harness.monitorRuns, 0)
        XCTAssertEqual(harness.startAgentRuns, 0)
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        XCTAssertEqual(
            controller.stage,
            .migrationRepairRequired(
                model: harness.configModel,
                message: "The imported provider token could not be verified in Keychain."
            )
        )
    }

    func testLaunchMonitorFailureSurfacesProviderStartFailure() async {
        let harness = Harness()
        harness.monitorHealthy = false
        harness.providerStartFailureMessage =
            "Model catalog is out of date for this Mac. Update Malibu to the latest release, "
            + "or run: macprovider-cli autotune --recommend --apply"
        let controller = LaunchProviderController(dependencies: harness.dependencies())

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
        let controller = LaunchProviderController(dependencies: harness.dependencies())

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

    func testReleaseAuthorityFailureAfterInstallPreventsCredentialAndProviderMutation() async {
        let harness = Harness()
        let controller = LaunchProviderController(
            dependencies: harness.dependencies(),
            authorizeInstalledProvider: {
                throw MalibuReleaseRuntimeAuthorization.Error.providerDigestMismatch
            }
        )

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(harness.cliImportRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 0)
        XCTAssertEqual(harness.startAgentRuns, 0)
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        if case let .failed(stage, retryable, message) = controller.stage {
            XCTAssertEqual(stage, "installedProviderAuthority")
            XCTAssertTrue(retryable)
            XCTAssertEqual(
                message,
                "The installed provider CLI does not match the signed Malibu release authority."
            )
        } else {
            XCTFail("expected installedProviderAuthority failure")
        }
    }

    func testBootstrapAuthorityFailurePreventsInstallerMutation() async {
        let harness = Harness()
        let controller = LaunchProviderController(
            dependencies: harness.dependencies(),
            authorizeBootstrapTarget: {
                throw MalibuReleaseRuntimeAuthorization.Error.releaseContract("bootstrap expired")
            }
        )

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.cliImportRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 0)
        if case let .failed(stage, retryable, _) = controller.stage {
            XCTAssertEqual(stage, "releaseAuthority")
            XCTAssertTrue(retryable)
        } else {
            XCTFail("expected pre-install releaseAuthority failure")
        }
    }

    func testExistingInstallReleaseAuthorityFailurePreventsImportAndAttachment() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        let controller = LaunchProviderController(
            dependencies: harness.dependencies(),
            authorizeInstalledProvider: {
                throw MalibuReleaseRuntimeAuthorization.Error.compatibilitySetMismatch
            }
        )

        await controller.launch()

        XCTAssertEqual(harness.cliInstallRuns, 0)
        XCTAssertEqual(harness.cliImportRuns, 0)
        XCTAssertEqual(harness.monitorRuns, 0)
        XCTAssertEqual(harness.startAgentRuns, 0)
        XCTAssertEqual(harness.loginItemRegistrations, 0)
        if case let .failed(stage, _, _) = controller.stage {
            XCTAssertEqual(stage, "installedProviderAuthority")
        } else {
            XCTFail("expected installedProviderAuthority failure")
        }
    }

    func testRetryRepairsInvalidHealthyProviderWithSignedPinnedCLI() async {
        let harness = Harness()
        harness.localInstallSucceeded = true
        harness.appIdentityConfigured = true
        var authorizationAttempts = 0
        let controller = LaunchProviderController(
            dependencies: harness.dependencies(),
            authorizeBootstrapTarget: { "1.8.40" },
            authorizeInstalledProvider: {
                authorizationAttempts += 1
                if authorizationAttempts == 1 {
                    throw MalibuReleaseRuntimeAuthorization.Error.compatibilitySetMismatch
                }
            }
        )

        await controller.launch()
        if case let .failed(stage, retryable, _) = controller.stage {
            XCTAssertEqual(stage, "installedProviderAuthority")
            XCTAssertTrue(retryable)
        } else {
            XCTFail("expected installed-provider authority failure")
        }

        await controller.retry()

        XCTAssertEqual(harness.cliInstallRuns, 1)
        XCTAssertEqual(harness.pinnedInstallVersions, ["1.8.40"])
        XCTAssertEqual(authorizationAttempts, 2)
        XCTAssertEqual(harness.releaseAuthorityClears, 1)
        XCTAssertEqual(controller.stage, .live(model: harness.configModel, tier: .provisional))
    }

    private final class Harness {
        var localInstallSucceeded = false
        var localInstallSucceededAfterInstall = false
        var markLocalInstallSucceededAfterInstall = true
        var cliInstallRuns = 0
        var pinnedInstallVersions: [String] = []
        var cliImportRuns = 0
        var monitorRuns = 0
        var loginItemRegistrations = 0
        var startAgentRuns = 0
        var migrationObservationRuns = 0
        var importRetryWaits = 0
        var releaseAuthorityClears = 0
        var monitorHealthy = true
        var attachHealthy = true
        var migrationObservationAvailable = false
        var appIdentityConfigured = false
        var providerStartFailureMessage: String?
        var cliInstallError: Error?
        var cliImportErrors: [Error] = []
        var configModel = "mlx-community/Qwen2.5-7B-Instruct-4bit"
        var installLogLines: [String] = []

        func dependencies() -> LaunchProviderController.Dependencies {
            LaunchProviderController.Dependencies(
                localInstallSucceeded: {
                    self.localInstallSucceeded || self.localInstallSucceededAfterInstall
                },
                registerLoginItem: {
                    self.loginItemRegistrations += 1
                },
                runCLIInstall: { pinnedVersion, onLogLine in
                    self.cliInstallRuns += 1
                    self.pinnedInstallVersions.append(pinnedVersion)
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
                observeInstalledProviderDuringMigrationRepair: {
                    self.migrationObservationRuns += 1
                    return self.migrationObservationAvailable
                },
                readConfigModel: { self.configModel },
                providerStartFailure: { self.providerStartFailureMessage },
                appIdentityConfigured: { self.appIdentityConfigured },
                waitBeforeImportRetry: {
                    self.importRetryWaits += 1
                },
                clearProviderReleaseAuthorityBlock: {
                    self.releaseAuthorityClears += 1
                }
            )
        }
    }
}
