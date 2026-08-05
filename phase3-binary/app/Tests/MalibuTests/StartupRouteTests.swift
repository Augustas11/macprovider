import XCTest
@testable import Malibu

final class StartupRouteTests: XCTestCase {
    private let prohibitedPublicTerms = [
        "compatibility set",
        "admission identity",
        "watchdog",
        "buyer-serving",
        "spec-023",
        "migration token",
        "credential custody",
        "coordinator admission",
        "provider cli",
        "macprovider-cli",
        "cli-owned",
        "terminal path",
        "referral_bootstrap_v1",
    ]

    func testStartupRouteInstallStates() {
        let cases: [(String, StartupState, StartupRoute)] = [
            ("healthy-launchd", state(config: true, marker: true, launchd: true, healthy: true), .startAgent),
            ("launchd-config-starting", state(config: true, marker: true, launchd: true, healthy: false), .startAgent),
            ("legacy-app-config", state(config: true, marker: true, launchd: false, healthy: false), .showOnboarding),
            ("cli-owned", state(config: true, marker: false, launchd: false, healthy: false), .showImportDialog),
            ("launchd-cli-owned-healthy", state(config: true, marker: false, launchd: true, healthy: true), .showImportDialog),
            ("launchd-cli-owned-starting", state(config: true, marker: false, launchd: true, healthy: false), .showImportDialog),
            ("app-owned-missing-identity-healthy", state(config: true, marker: true, configured: false, launchd: true, healthy: true), .showOnboarding),
            ("app-owned-missing-identity-starting", state(config: true, marker: true, configured: false, launchd: true, healthy: false), .showOnboarding),
            ("launchd-only", state(config: false, marker: false, launchd: true, healthy: false), .showOnboarding),
            ("fresh", state(config: false, marker: false, launchd: false, healthy: false), .showOnboarding)
        ]

        for (name, base, expected) in cases {
            XCTAssertEqual(base.route(), expected, name)
        }
    }

    func testMigrationImportWithoutLaunchdRoutesToOnboarding() async throws {
        let paths = try makeTempPaths()
        try paths.ensureDirectories()
        try "provider_id: p_import\nprovider_token: secret-token\nmodel: test\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: paths.appSupport.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent()) }
        defer { Task { try? await KeychainStore.deleteProviderToken(providerID: "p_import") } }

        let result = try await StartupState.applyMigrationDecision(
            .importExisting,
            paths: paths,
            importCredentialIntoCLI: { snapshot in
                XCTAssertTrue(try String(contentsOf: snapshot).contains("provider_token: secret-token"))
            }
        )
        let state = await StartupState.detect(paths: paths)
        let expectedRoute: StartupRoute = state.launchdInstallEvidenceExists ? .startAgent : .showOnboarding
        XCTAssertEqual(result.route, expectedRoute)
        XCTAssertNil(result.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.appMarkerFile.path))
        let rewritten = try String(contentsOf: paths.configFile)
        XCTAssertTrue(rewritten.contains("provider_id: p_import"))
        XCTAssertTrue(rewritten.contains("model: test"))
        XCTAssertTrue(rewritten.contains("provider_token: secret-token"))
        let importedToken = await KeychainStore.readProviderToken(providerID: "p_import")
        XCTAssertNil(importedToken)
    }

    func testMigrationStartFreshMovesConfigAsideAndShowsOnboarding() async throws {
        let paths = try makeTempPaths()
        try paths.ensureDirectories()
        try "provider_id: p_old\nprovider_token: old-token\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: paths.appSupport.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent()) }

        let result = try await StartupState.applyMigrationDecision(
            .startFresh,
            paths: paths,
            now: Date(timeIntervalSince1970: 1_783_082_460)
        )
        XCTAssertEqual(result.route, .showOnboarding)
        XCTAssertNotNil(result.backupPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.backupPath!))
        let attrs = try FileManager.default.attributesOfItem(atPath: result.backupPath!)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testConfirmedReplacementDefersConfigBackupToInstallerTransaction() async throws {
        let paths = try makeTempPaths()
        try paths.ensureDirectories()
        try "provider_id: p_old\nprovider_token: old-token\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: paths.appSupport.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent()) }

        let result = try await StartupState.applyMigrationDecision(
            .startFresh,
            paths: paths,
            deferStartFreshBackup: true
        )

        XCTAssertEqual(result.route, .showOnboarding)
        XCTAssertNil(result.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configFile.path))
        XCTAssertEqual(
            try String(contentsOf: paths.configFile),
            "provider_id: p_old\nprovider_token: old-token\n"
        )
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

    func testExistingProviderDialogMakesUseExistingPrimaryAndStartFreshDestructive() {
        XCTAssertEqual(MigrationDialogCopy.useExistingButton, "Use Existing Provider")
        XCTAssertEqual(MigrationDialogCopy.startFreshButton, "Start Fresh")
        XCTAssertTrue(MigrationDialogCopy.message.contains("keeps the same provider identity"))
        XCTAssertTrue(MigrationDialogCopy.message.contains("payment history"))
        XCTAssertTrue(MigrationDialogCopy.message.contains("saved access"))
        XCTAssertTrue(MigrationDialogCopy.message.contains("local model setup"))
        XCTAssertTrue(MigrationDialogCopy.message.contains("creates a new provider"))
        XCTAssertTrue(MigrationDialogCopy.message.contains("restore the old setup"))

        let publicDialog = [
            MigrationDialogCopy.title,
            MigrationDialogCopy.message,
            MigrationDialogCopy.useExistingButton,
            MigrationDialogCopy.startFreshButton,
            MigrationDialogCopy.cancelButton,
        ].joined(separator: "\n").lowercased()
        for term in prohibitedPublicTerms {
            XCTAssertFalse(publicDialog.contains(term), "\(term) leaked in:\n\(publicDialog)")
        }
    }

    func testStartFreshBackupCopyUsesOrdinaryLanguage() {
        let copy = [
            StartFreshBackupCopy.title,
            StartFreshBackupCopy.message(path: "/tmp/old-config.yaml"),
        ].joined(separator: "\n").lowercased()

        XCTAssertTrue(copy.contains("previous provider identity"))
        XCTAssertTrue(copy.contains("payment history"))
        XCTAssertTrue(copy.contains("saved access"))
        for term in prohibitedPublicTerms {
            XCTAssertFalse(copy.contains(term), "\(term) leaked in:\n\(copy)")
        }
    }

    func testStartFreshRequiresASeparateDestructiveConfirmation() {
        XCTAssertEqual(StartFreshConfirmationCopy.cancelButton, "Keep Existing Provider")
        XCTAssertEqual(StartFreshConfirmationCopy.startFreshButton, "Create New Provider")
        XCTAssertFalse(StartFreshConfirmationCopy.confirms(.alertFirstButtonReturn))
        XCTAssertTrue(StartFreshConfirmationCopy.confirms(.alertSecondButtonReturn))
        XCTAssertFalse(StartFreshConfirmationCopy.confirms(.abort))

        let copy = [
            StartFreshConfirmationCopy.title,
            StartFreshConfirmationCopy.message,
            StartFreshConfirmationCopy.cancelButton,
            StartFreshConfirmationCopy.startFreshButton,
        ].joined(separator: "\n").lowercased()
        XCTAssertTrue(copy.contains("unchanged until the new provider is ready"), copy)
        XCTAssertTrue(copy.contains("different identity"), copy)
        XCTAssertTrue(copy.contains("payment history"), copy)
        XCTAssertTrue(copy.contains("saved access"), copy)
        XCTAssertTrue(copy.contains("local model setup"), copy)
        for term in prohibitedPublicTerms {
            XCTAssertFalse(copy.contains(term), "\(term) leaked in:\n\(copy)")
        }
    }

    func testMigrationErrorCopyUsesOrdinaryLanguage() {
        let error = NSError(
            domain: "coordinator.admission",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "coordinator admission failed at /tmp/macprovider.err.log"]
        )
        let copy = [
            MigrationErrorCopy.title,
            MigrationErrorCopy.message(error),
        ].joined(separator: "\n").lowercased()

        XCTAssertTrue(copy.contains("current setup was not changed"))
        XCTAssertTrue(copy.contains("advanced diagnostics"))
        XCTAssertEqual(MigrationErrorCopy.cancelButton, "Cancel")
        XCTAssertEqual(MigrationErrorCopy.retryButton, "Try Again")
        XCTAssertFalse(copy.contains("coordinator"), copy)
        XCTAssertFalse(copy.contains("/tmp"), copy)
        for term in prohibitedPublicTerms {
            XCTAssertFalse(copy.contains(term), "\(term) leaked in:\n\(copy)")
        }
    }

    func testMigrationErrorCopyShowsASanitizedActualReason() {
        let error = ProviderCredentialHandoffRunner.Error.importFailed(7)

        let copy = MigrationErrorCopy.message(error)

        XCTAssertTrue(copy.contains("could not prepare the saved access"), copy)
        XCTAssertTrue(copy.contains("exit 7"), copy)
        XCTAssertTrue(copy.contains("original setup was preserved"), copy)
        XCTAssertTrue(copy.contains("current setup was not changed"), copy)
    }

    func testMigrationErrorCopyRedactsEveryUnboundedHandoffReason() {
        let secret = "provider_token=secret /Users/name/config.yaml?token=secret"
        let cases: [ProviderCredentialHandoffRunner.Error] = [
            .invalidCLI(secret),
            .invalidOutput(secret),
            .launchFailed(secret),
        ]

        for error in cases {
            let copy = MigrationErrorCopy.message(error).lowercased()
            XCTAssertFalse(copy.contains("secret"), copy)
            XCTAssertFalse(copy.contains("/users/"), copy)
            XCTAssertFalse(copy.contains("provider_token"), copy)
            XCTAssertTrue(copy.contains("retry"), copy)
            XCTAssertTrue(copy.contains("current setup was not changed"), copy)
        }
    }

    func testCanonicalPublicLanguagePolicyContainsTheMalibuCoreTerms() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let policyURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("public-language.json")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: policyURL)) as? [String: Any]
        )
        let terms = try XCTUnwrap(object["terms"] as? [[String: String]])
        let internalTerms = Set(terms.compactMap { $0["internal"] })

        for term in [
            "compatibility set",
            "admission identity",
            "watchdog",
            "buyer-serving",
            "spec-023 probe",
            "coordinator admission",
            "credential custody",
            "migration token",
        ] {
            XCTAssertTrue(internalTerms.contains(term), "missing canonical mapping for \(term)")
        }
    }

    private func state(
        config: Bool,
        marker: Bool,
        configured: Bool? = nil,
        launchd: Bool,
        healthy: Bool
    ) -> StartupState {
        StartupState(
            configExists: config,
            appMarkerExists: marker,
            appIdentityConfigured: configured ?? marker,
            launchdInstallEvidenceExists: launchd,
            backgroundProviderHealthy: healthy
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
            launchdStdoutLog: root.appendingPathComponent("logs/macprovider.out.log"),
            launchdStderrLog: root.appendingPathComponent("logs/macprovider.err.log"),
            appSupport: appSupport,
            appMarkerFile: appSupport.appendingPathComponent(".installed-by-app"),
            onboardingStateFile: appSupport.appendingPathComponent("onboarding.json"),
            downloadsDirectory: appSupport.appendingPathComponent("Downloads", isDirectory: true)
        )
    }
}
