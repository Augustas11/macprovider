import XCTest
@testable import Malibu

final class StartupRouteTests: XCTestCase {
    @MainActor
    func testFeatureFlagEnvironmentOverridesUserDefaults() {
        let defaults = UserDefaults(suiteName: "malibu-tests-\(UUID().uuidString)")!
        defaults.set("v2", forKey: "onboardingFlow")
        XCTAssertFalse(LaunchProviderController.isOnboardingV2Enabled(
            environment: ["MALIBU_ONBOARD_V2": "0"],
            userDefaults: defaults
        ))
        XCTAssertTrue(LaunchProviderController.isOnboardingV2Enabled(
            environment: ["MALIBU_ONBOARD_V2": "1"],
            userDefaults: defaults
        ))
    }

    func testStartupRouteCellsForFlagOffAndOn() {
        let configured = StartupState(
            configExists: true,
            appMarkerExists: true,
            providerTokenExists: true,
            identityExists: true,
            onboardingStateExists: true,
            firstServingAtExists: true,
            onboardingV2Enabled: false
        )
        XCTAssertEqual(configured.route(), .startAgent)

        let cliOwned = StartupState(
            configExists: true,
            appMarkerExists: false,
            providerTokenExists: false,
            identityExists: false,
            onboardingStateExists: false,
            firstServingAtExists: false,
            onboardingV2Enabled: true
        )
        XCTAssertEqual(cliOwned.route(), .showImportDialog)
        XCTAssertEqual(StartupState(
            configExists: cliOwned.configExists,
            appMarkerExists: cliOwned.appMarkerExists,
            providerTokenExists: cliOwned.providerTokenExists,
            identityExists: cliOwned.identityExists,
            onboardingStateExists: cliOwned.onboardingStateExists,
            firstServingAtExists: cliOwned.firstServingAtExists,
            onboardingV2Enabled: false
        ).route(), .setupPaused)

        let partial = StartupState(
            configExists: false,
            appMarkerExists: false,
            providerTokenExists: false,
            identityExists: true,
            onboardingStateExists: true,
            firstServingAtExists: false,
            onboardingV2Enabled: true
        )
        XCTAssertEqual(partial.route(), .resumeOnboarding)
    }
}
