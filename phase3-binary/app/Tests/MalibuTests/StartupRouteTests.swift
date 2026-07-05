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

    func testStartupRouteFiveInstallStatesByFlagPosition() {
        let cases: [(String, StartupState, StartupRoute, StartupRoute)] = [
            ("configured", state(config: true, marker: true, token: true, identity: true, onboarding: true, firstServing: true), .startAgent, .startAgent),
            ("configured-v2-partial", state(config: true, marker: true, token: true, identity: true, onboarding: true, firstServing: false), .resumeOnboarding, .resumeOnboarding),
            ("cli-owned", state(config: true, marker: false, token: false, identity: false, onboarding: false, firstServing: false), .showImportDialog, .showImportDialog),
            ("v2-partial", state(config: false, marker: false, token: false, identity: true, onboarding: true, firstServing: false), .resumeOnboarding, .resumeOnboarding),
            ("fresh", state(config: false, marker: false, token: false, identity: false, onboarding: false, firstServing: false), .setupPaused, .showOnboarding),
            ("identity-only", state(config: false, marker: false, token: false, identity: true, onboarding: false, firstServing: false), .setupPaused, .resumeOnboarding)
        ]

        for (name, base, flagOffRoute, flagOnRoute) in cases {
            var off = base
            off = StartupState(
                configExists: off.configExists,
                appMarkerExists: off.appMarkerExists,
                providerTokenExists: off.providerTokenExists,
                linkState: off.linkState,
                identityExists: off.identityExists,
                onboardingStateExists: off.onboardingStateExists,
                firstServingAtExists: off.firstServingAtExists,
                onboardingV2Enabled: false
            )
            XCTAssertEqual(off.route(), flagOffRoute, name)

            let on = StartupState(
                configExists: base.configExists,
                appMarkerExists: base.appMarkerExists,
                providerTokenExists: base.providerTokenExists,
                linkState: base.linkState,
                identityExists: base.identityExists,
                onboardingStateExists: base.onboardingStateExists,
                firstServingAtExists: base.firstServingAtExists,
                onboardingV2Enabled: true
            )
            XCTAssertEqual(on.route(), flagOnRoute, name)
        }
    }

    func testMigrationImportMovesTokenToKeychainAndRemovesBearerFromConfig() async throws {
        let paths = try makeTempPaths()
        try paths.ensureDirectories()
        try "provider_id: p_import\nprovider_token: secret-token\nmodel: test\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: paths.appSupport.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent()) }
        defer { Task { try? await KeychainStore.deleteProviderToken(providerID: "p_import") } }

        let result = try await StartupState.applyMigrationDecision(.importExisting, paths: paths)
        XCTAssertEqual(result.route, .startAgent)
        XCTAssertNil(result.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.appMarkerFile.path))
        let rewritten = try String(contentsOf: paths.configFile)
        XCTAssertTrue(rewritten.contains("provider_id: p_import"))
        XCTAssertTrue(rewritten.contains("model: test"))
        XCTAssertFalse(rewritten.contains("provider_token"))
        let importedToken = await KeychainStore.readProviderToken(providerID: "p_import")
        XCTAssertEqual(importedToken, "secret-token")
    }

    func testMigrationStartFreshMovesConfigAsideAndReclassifiesFreshByFlag() async throws {
        for (enabled, expectedRoute) in [(false, StartupRoute.setupPaused), (true, .showOnboarding)] {
            let paths = try makeTempPaths()
            try paths.ensureDirectories()
            try "provider_id: p_old\nprovider_token: old-token\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: paths.appSupport.deletingLastPathComponent()) }
            defer { try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent()) }

            let result = try await StartupState.applyMigrationDecision(
                .startFresh,
                paths: paths,
                now: Date(timeIntervalSince1970: 1_783_082_460),
                onboardingV2Enabled: enabled
            )
            XCTAssertEqual(result.route, expectedRoute)
            XCTAssertNotNil(result.backupPath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configFile.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.backupPath!))
            let attrs = try FileManager.default.attributesOfItem(atPath: result.backupPath!)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testMigrationCancelTouchesNoFiles() async throws {
        let paths = try makeTempPaths()
        try paths.ensureDirectories()
        try "provider_id: p_keep\nprovider_token: keep-token\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: paths.appSupport.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent()) }

        let before = try String(contentsOf: paths.configFile)
        let result = try await StartupState.applyMigrationDecision(.cancel, paths: paths)
        XCTAssertEqual(result.route, .quit)
        XCTAssertNil(result.backupPath)
        XCTAssertEqual(try String(contentsOf: paths.configFile), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appMarkerFile.path))
        let untouchedToken = await KeychainStore.readProviderToken(providerID: "p_keep")
        XCTAssertNil(untouchedToken)
    }

    func testConfiguredPendingLinkStateResumesOnboarding() {
        let state = StartupState(
            configExists: true,
            appMarkerExists: true,
            providerTokenExists: true,
            linkState: .pendingLink,
            identityExists: true,
            onboardingStateExists: false,
            firstServingAtExists: false,
            onboardingV2Enabled: true
        )

        XCTAssertEqual(state.route(), .resumeOnboarding)
    }

    private func state(
        config: Bool,
        marker: Bool,
        token: Bool,
        identity: Bool,
        onboarding: Bool,
        firstServing: Bool
    ) -> StartupState {
        StartupState(
            configExists: config,
            appMarkerExists: marker,
            providerTokenExists: token,
            linkState: nil,
            identityExists: identity,
            onboardingStateExists: onboarding,
            firstServingAtExists: firstServing,
            onboardingV2Enabled: false
        )
    }

    private func makeTempPaths() throws -> ProviderPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-startup-tests-\(UUID().uuidString)", isDirectory: true)
        let configRoot = root.appendingPathComponent("config", isDirectory: true)
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        return ProviderPaths(
            configFile: configRoot.appendingPathComponent("config.yaml"),
            controlSocket: appSupport.appendingPathComponent("agent.sock"),
            cliLogFile: root.appendingPathComponent("logs/malibu-cli.log"),
            appSupport: appSupport,
            appMarkerFile: appSupport.appendingPathComponent(".installed-by-app"),
            onboardingStateFile: appSupport.appendingPathComponent("onboarding.json"),
            downloadsDirectory: appSupport.appendingPathComponent("Downloads", isDirectory: true)
        )
    }

}
