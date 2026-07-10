import XCTest
@testable import Malibu

final class StartupRouteTests: XCTestCase {

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

        let result = try await StartupState.applyMigrationDecision(.importExisting, paths: paths)
        let state = await StartupState.detect(paths: paths)
        let expectedRoute: StartupRoute = state.launchdInstallEvidenceExists ? .startAgent : .showOnboarding
        XCTAssertEqual(result.route, expectedRoute)
        XCTAssertNil(result.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.appMarkerFile.path))
        let rewritten = try String(contentsOf: paths.configFile)
        XCTAssertTrue(rewritten.contains("provider_id: p_import"))
        XCTAssertTrue(rewritten.contains("model: test"))
        XCTAssertFalse(rewritten.contains("provider_token"))
        let importedToken = await KeychainStore.readProviderToken(providerID: "p_import")
        XCTAssertEqual(importedToken, "secret-token")
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
