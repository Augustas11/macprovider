import XCTest
@testable import macprovider_cli

final class UninstallCommandTests: XCTestCase {
    func testStopLaunchdServicesAcceptsVerifiedAbsentJob() throws {
        var calls: [[String]] = []

        try UninstallCommand.stopLaunchdServices(labels: ["live.streamvc.macprovider"], uid: 501) { arguments in
            calls.append(arguments)
            return arguments.first == "bootout" ? 3 : 113
        }

        XCTAssertEqual(calls, [
            ["bootout", "gui/501/live.streamvc.macprovider-watchdog"],
            ["print", "gui/501/live.streamvc.macprovider-watchdog"],
            ["bootout", "gui/501/live.streamvc.macprovider"],
            ["print", "gui/501/live.streamvc.macprovider"],
            ["print", "gui/501/live.streamvc.macprovider-watchdog"],
            ["print", "gui/501/live.streamvc.macprovider"],
        ])
    }

    func testStopLaunchdServicesRejectsJobThatRemainsLoaded() {
        XCTAssertThrowsError(
            try UninstallCommand.stopLaunchdServices(
                labels: ["live.streamvc.macprovider"],
                uid: 501,
                run: { arguments in
                    guard arguments.first == "print" else { return 0 }
                    return arguments.last?.hasSuffix("/live.streamvc.macprovider-watchdog") == true ? 113 : 0
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? UninstallCommand.UninstallError,
                .serviceStillLoaded("live.streamvc.macprovider")
            )
        }
    }

    func testStopLaunchdServicesRejectsIndeterminatePrintFailure() {
        var printCount = 0
        XCTAssertThrowsError(
            try UninstallCommand.stopLaunchdServices(
                labels: ["live.streamvc.macprovider"],
                uid: 501,
                run: { arguments in
                    guard arguments.first == "print" else { return 5 }
                    printCount += 1
                    return printCount == 1 ? 64 : 113
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? UninstallCommand.UninstallError,
                .serviceAbsenceVerificationFailed("live.streamvc.macprovider-watchdog", 64)
            )
        }
    }

    func testStopLaunchdServicesRejectsProviderRestartedAfterInitialStopProof() {
        var calls: [[String]] = []
        var providerPrints = 0

        XCTAssertThrowsError(
            try UninstallCommand.stopLaunchdServices(
                labels: ["live.streamvc.macprovider", "live.streamvc.macprovider-watchdog"],
                uid: 501,
                run: { arguments in
                    calls.append(arguments)
                    guard arguments.first == "print" else { return 0 }
                    if arguments.last?.hasSuffix("/live.streamvc.macprovider") == true {
                        providerPrints += 1
                        return providerPrints == 1 ? 113 : 0
                    }
                    return 113
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? UninstallCommand.UninstallError,
                .serviceStillLoaded("live.streamvc.macprovider")
            )
        }

        XCTAssertEqual(Array(calls.suffix(2)), [
            ["print", "gui/501/live.streamvc.macprovider-watchdog"],
            ["print", "gui/501/live.streamvc.macprovider"],
        ])
    }

    func testStopLaunchdServicesRejectsUnexpectedManifestLabelBeforeLaunchctl() {
        var called = false
        XCTAssertThrowsError(
            try UninstallCommand.stopLaunchdServices(
                labels: ["com.example.unrelated"],
                uid: 501,
                run: { _ in
                    called = true
                    return 113
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? UninstallCommand.UninstallError,
                .unexpectedServiceLabel("com.example.unrelated")
            )
        }
        XCTAssertFalse(called)
    }

    func testArtifactPathsMatchCanonicalInstallLayout() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let paths = UninstallCommand.artifactPaths(home: home)

        XCTAssertEqual(paths.binary.path, "/Users/tester/.local/bin/macprovider-cli")
        XCTAssertEqual(paths.supportDirectory.path, "/Users/tester/macprovider")
        XCTAssertEqual(paths.logsDirectory.path, "/Users/tester/Library/Logs/macprovider")
        XCTAssertEqual(paths.plist.path, "/Users/tester/Library/LaunchAgents/live.streamvc.macprovider.plist")
        XCTAssertEqual(paths.watchdogPlist.path, "/Users/tester/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist")
        XCTAssertEqual(paths.watchdogDirectory.path, "/Users/tester/.local/share/macprovider-watchdog")
        XCTAssertEqual(paths.manifest.path, "/Users/tester/Library/Application Support/macprovider/install_manifest.json")
        XCTAssertEqual(paths.cacheDirectory.path, "/Users/tester/.cache/macprovider")
    }

    func testLoadManifestDecodesInstalledArtifacts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macprovider-uninstall-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = UninstallCommand.artifactPaths(home: root).manifest
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "install_prefix": "\(root.path)/custom",
          "binary_path": "\(root.path)/custom/macprovider-cli",
          "symlink_path": "\(root.path)/.local/bin/macprovider-cli",
          "launchd_labels": ["live.streamvc.macprovider", "live.streamvc.macprovider-watchdog"],
          "launchd_plists": ["\(root.path)/Library/LaunchAgents/live.streamvc.macprovider.plist"],
          "data_dirs": ["\(root.path)/custom", "\(root.path)/Library/Logs/macprovider"],
          "version": "v1.8.10"
        }
        """.write(to: manifest, atomically: true, encoding: .utf8)

        let loaded = UninstallCommand.loadManifest(home: root)
        XCTAssertEqual(loaded?.installPrefix, "\(root.path)/custom")
        XCTAssertEqual(loaded?.launchdLabels, ["live.streamvc.macprovider", "live.streamvc.macprovider-watchdog"])
        XCTAssertEqual(loaded?.dataDirs, ["\(root.path)/custom", "\(root.path)/Library/Logs/macprovider"])
        XCTAssertEqual(loaded?.symlinkPath, "\(root.path)/.local/bin/macprovider-cli")
    }

    func testLegacyManifestCoversProviderAndWatchdogArtifacts() {
        let home = URL(fileURLWithPath: "/Users/legacy")
        let manifest = UninstallCommand.legacyManifest(home: home)

        XCTAssertEqual(manifest.launchdLabels, ["live.streamvc.macprovider", "live.streamvc.macprovider-watchdog"])
        XCTAssertTrue(manifest.dataDirs.contains("/Users/legacy/macprovider"))
        XCTAssertTrue(manifest.dataDirs.contains("/Users/legacy/.local/share/macprovider-watchdog"))
        XCTAssertTrue(manifest.launchdPlists.contains("/Users/legacy/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"))
    }

    func testManifestRemovalAllowlistRejectsTraversalAndUnexpectedPrefixPaths() throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        let legacy = UninstallCommand.legacyManifest(home: home)
        let allowed = try UninstallCommand.allowedRemovalPaths(home: home, manifest: legacy)

        XCTAssertTrue(try UninstallCommand.path("/Users/tester/macprovider", isAllowedBy: allowed.dataDirs))
        XCTAssertFalse(try UninstallCommand.path("/Users/tester/../etc", isAllowedBy: allowed.dataDirs))
        XCTAssertFalse(try UninstallCommand.path("/tmp/custom/macprovider-cli", isAllowedBy: allowed.binaries))
    }

    func testCustomPrefixManifestAllowsOnlyThatPrefixBinaryAndDataDir() throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        let manifest = UninstallCommand.InstallManifest(
            installPrefix: "/opt/macprovider",
            launchdLabels: ["live.streamvc.macprovider"],
            dataDirs: ["/opt/macprovider"],
            version: "v1.8.10",
            binaryPath: "/opt/macprovider/macprovider-cli",
            symlinkPath: "/Users/tester/.local/bin/macprovider-cli",
            launchdPlists: ["/Users/tester/Library/LaunchAgents/live.streamvc.macprovider.plist"]
        )
        let allowed = try UninstallCommand.allowedRemovalPaths(home: home, manifest: manifest)

        XCTAssertTrue(try UninstallCommand.path("/opt/macprovider", isAllowedBy: allowed.dataDirs))
        XCTAssertTrue(try UninstallCommand.path("/opt/macprovider/macprovider-cli", isAllowedBy: allowed.binaries))
        XCTAssertFalse(try UninstallCommand.path("/opt/macprovider/../etc", isAllowedBy: allowed.dataDirs))
        XCTAssertFalse(try UninstallCommand.path("/Users/tester/Library/LaunchAgents/other.plist", isAllowedBy: allowed.plists))
    }
}
