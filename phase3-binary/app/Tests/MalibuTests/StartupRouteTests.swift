import Darwin
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
        "malibu-cli",
        "cli-owned",
        "terminal path",
        "referral_bootstrap_v1",
    ]

    func testStartupRouteInstallStates() {
        let cases: [(String, StartupState, StartupRoute)] = [
            ("healthy-launchd", state(config: true, marker: true, launchd: true, healthy: true), .startAgent),
            ("launchd-config-starting", state(config: true, marker: true, launchd: true, healthy: false), .startAgent),
            ("stale-launchd-repair", state(config: true, marker: true, launchd: true, healthy: false, needsRepair: true), .repairExistingInstall),
            ("stale-launchd-repair-before-import", state(config: true, marker: false, launchd: true, healthy: false, needsRepair: true), .showImportDialog),
            ("healthy-provider-repairs-watchdog-in-background", state(config: true, marker: true, launchd: true, healthy: true, needsRepair: true, providerNeedsRepair: false, watchdogNeedsRepair: true), .startAgentAndRepairWatchdog),
            ("foreign-launchd-conflict", state(config: true, marker: true, launchd: true, healthy: false, manualIntervention: true), .showLaunchdConflict),
            ("foreign-launchd-conflict-before-import", state(config: true, marker: false, launchd: true, healthy: false, manualIntervention: true), .showLaunchdConflict),
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

    func testDetectRoutesForeignWatchdogToManualConflictWithoutUsingRealHome() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let watchdogPlist = root.appendingPathComponent(
            "Library/LaunchAgents/live.malibu.provider-watchdog.plist"
        )
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(
            at: watchdogPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "<plist/>\n".write(to: watchdogPlist, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf 'program = %s\\npath = %s\\n' '\(root.path)/unexpected-watchdog' '\(watchdogPlist.path)'\n"
            .write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launchctl.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let state = await StartupState.detect(
            paths: paths,
            homeDirectory: root,
            launchctlURL: launchctl
        )

        XCTAssertTrue(state.launchdJobNeedsManualIntervention)
        XCTAssertEqual(state.route(), .showLaunchdConflict)
    }

    func testDetectRoutesLoadedProviderWithMissingPlistToManualConflict() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let expectedPlist = root.appendingPathComponent(
            "Library/LaunchAgents/live.malibu.provider.plist"
        )
        let expectedProgram = root.appendingPathComponent("macprovider/malibu-cli")
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(at: launchctl.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf 'program = %s\\npath = %s\\n' '\(expectedProgram.path)' '\(expectedPlist.path)'\n"
            .write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launchctl.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let state = await StartupState.detect(
            paths: paths,
            homeDirectory: root,
            launchctlURL: launchctl
        )

        XCTAssertFalse(state.launchdInstallEvidenceExists)
        XCTAssertTrue(state.launchdJobNeedsManualIntervention)
        XCTAssertEqual(state.route(), .showLaunchdConflict)
    }

    func testDetectRoutesLegacyWatchdogIdentityToRepair() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let providerPlist = root.appendingPathComponent(
            "Library/LaunchAgents/live.malibu.provider.plist"
        )
        let providerProgram = root.appendingPathComponent("macprovider/malibu-cli")
        let providerID = paths.configFile.deletingLastPathComponent().appendingPathComponent("provider_id")
        let manifest = root.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        )
        let watchdogPlist = root.appendingPathComponent(
            "Library/LaunchAgents/live.malibu.provider-watchdog.plist"
        )
        let legacyWatchdog = root.appendingPathComponent(
            ".local/share/macprovider-watchdog/watchdog.sh"
        )
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(
            at: watchdogPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: providerProgram.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: providerID.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: paths.appMarkerFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: paths.appMarkerFile)
        try "provider_id: p_watchdog\nprovider_token: secret-token\n"
            .write(to: paths.configFile, atomically: true, encoding: .utf8)
        try "p_watchdog\n".write(to: providerID, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: providerProgram, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: providerProgram.path
        )
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>Label</key><string>live.malibu.provider</string>
          <key>ProgramArguments</key><array><string>\(providerProgram.path)</string></array>
        </dict></plist>
        """.write(to: providerPlist, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: [
            "install_prefix": providerProgram.deletingLastPathComponent().path,
            "binary_path": providerProgram.path,
            "launchd_labels": ["live.malibu.provider"],
            "launchd_plists": [providerPlist.path]
        ]).write(to: manifest)
        try FileManager.default.createDirectory(
            at: legacyWatchdog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>Label</key><string>live.malibu.provider-watchdog</string>
          <key>ProgramArguments</key><array><string>\(legacyWatchdog.path)</string></array>
        </dict></plist>
        """.write(to: watchdogPlist, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: legacyWatchdog, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: legacyWatchdog.path
        )
        try """
        #!/bin/sh
        case "$*" in
          *macprovider-watchdog*)
            printf 'program = %s\\npath = %s\\n' '\(legacyWatchdog.path)' '\(watchdogPlist.path)'
            ;;
          *)
            exit 1
            ;;
        esac
        """
            .write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launchctl.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let state = await StartupState.detect(
            paths: paths,
            homeDirectory: root,
            launchctlURL: launchctl
        )

        XCTAssertTrue(state.launchdJobNeedsRepair)
        XCTAssertTrue(state.watchdogJobNeedsRepair)
        XCTAssertEqual(state.route(), .repairExistingInstall)
    }

    func testDetectRoutesCompleteLaunchdEvidenceToRepairMissingProvider() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let providerPlist = root.appendingPathComponent(
            "Library/LaunchAgents/live.malibu.provider.plist"
        )
        let providerProgram = root.appendingPathComponent("macprovider/malibu-cli")
        let providerID = paths.configFile.deletingLastPathComponent().appendingPathComponent("provider_id")
        let manifest = root.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        )
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(at: providerPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerID.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.appMarkerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: paths.appMarkerFile)
        try "provider_id: p_missing\nprovider_token: secret-token\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        try "p_missing\n".write(to: providerID, atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>Label</key><string>live.malibu.provider</string>
          <key>ProgramArguments</key><array><string>\(providerProgram.path)</string></array>
        </dict></plist>
        """.write(to: providerPlist, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: [
            "install_prefix": providerProgram.deletingLastPathComponent().path,
            "binary_path": providerProgram.path,
            "launchd_labels": ["live.malibu.provider"],
            "launchd_plists": [providerPlist.path]
        ]).write(to: manifest)
        try "#!/bin/sh\nexit 1\n".write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = await StartupState.detect(
            paths: paths,
            homeDirectory: root,
            launchctlURL: launchctl
        )

        XCTAssertTrue(state.launchdInstallEvidenceExists)
        XCTAssertTrue(state.launchdJobNeedsRepair)
        XCTAssertTrue(state.providerLaunchdJobNeedsRepair)
        XCTAssertEqual(state.route(), .repairExistingInstall)
    }

    func testDetectRoutesLegacyProviderProgramToRepairMissingProvider() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let installDirectory = root.appendingPathComponent("macprovider")
        let providerProgram = installDirectory.appendingPathComponent("malibu-cli")
        let legacyProgram = root.appendingPathComponent(".local/bin/malibu-cli")
        let providerPlist = root.appendingPathComponent(
            "Library/LaunchAgents/live.malibu.provider.plist"
        )
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyProgram.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: legacyProgram, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyProgram.path)
        try writeRepairEvidence(
            paths: paths,
            root: root,
            manifest: [
                "install_prefix": installDirectory.path,
                "binary_path": providerProgram.path,
                "launchd_labels": ["live.malibu.provider"],
                "launchd_plists": [providerPlist.path]
            ],
            plistLabel: "live.malibu.provider",
            plistProgram: legacyProgram.path
        )
        try "#!/bin/sh\nexit 1\n".write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = await StartupState.detect(
            paths: paths,
            homeDirectory: root,
            launchctlURL: launchctl
        )

        XCTAssertTrue(state.launchdJobNeedsRepair)
        XCTAssertTrue(state.providerLaunchdJobNeedsRepair)
        XCTAssertEqual(state.route(), .repairExistingInstall)
    }

    func testDetectRoutesLegacyMacProviderProgramToRepairMissingProvider() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let installDirectory = root.appendingPathComponent("macprovider")
        let providerProgram = installDirectory.appendingPathComponent("macprovider-cli")
        let legacyProgram = root.appendingPathComponent(".local/bin/macprovider-cli")
        let providerPlist = root.appendingPathComponent(
            "Library/LaunchAgents/live.malibu.provider.plist"
        )
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyProgram.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: legacyProgram, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyProgram.path)
        try writeRepairEvidence(
            paths: paths,
            root: root,
            manifest: [
                "install_prefix": installDirectory.path,
                "binary_path": providerProgram.path,
                "launchd_labels": ["live.malibu.provider"],
                "launchd_plists": [providerPlist.path]
            ],
            plistLabel: "live.malibu.provider",
            plistProgram: legacyProgram.path
        )
        try "#!/bin/sh\nexit 1\n".write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = await StartupState.detect(
            paths: paths,
            homeDirectory: root,
            launchctlURL: launchctl
        )

        XCTAssertTrue(state.launchdJobNeedsRepair)
        XCTAssertTrue(state.providerLaunchdJobNeedsRepair)
        XCTAssertEqual(state.route(), .repairExistingInstall)
    }

    func testDetectRejectsSemanticallyInvalidManifestForRepair() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let launchctl = root.appendingPathComponent("launchctl")
        let providerProgram = root.appendingPathComponent("macprovider/malibu-cli")
        let providerPlist = root.appendingPathComponent(
            "Library/LaunchAgents/live.malibu.provider.plist"
        )
        try writeRepairEvidence(
            paths: paths,
            root: root,
            manifest: [
                "install_prefix": root.path,
                "binary_path": providerProgram.path,
                "launchd_labels": ["live.malibu.provider"],
                "launchd_plists": [providerPlist.path]
            ],
            plistLabel: "live.malibu.provider",
            plistProgram: providerProgram.path
        )
        try "#!/bin/sh\nexit 1\n".write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = await StartupState.detect(
            paths: paths,
            homeDirectory: root,
            launchctlURL: launchctl
        )

        XCTAssertTrue(state.launchdInstallEvidenceExists)
        XCTAssertFalse(state.launchdJobNeedsRepair)
        XCTAssertEqual(state.route(), .showOnboarding)
    }

    func testDetectRejectsSemanticallyInvalidLaunchdPlistForRepair() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let launchctl = root.appendingPathComponent("launchctl")
        let providerProgram = root.appendingPathComponent("macprovider/malibu-cli")
        let providerPlist = root.appendingPathComponent(
            "Library/LaunchAgents/live.malibu.provider.plist"
        )
        try writeRepairEvidence(
            paths: paths,
            root: root,
            manifest: [
                "install_prefix": providerProgram.deletingLastPathComponent().path,
                "binary_path": providerProgram.path,
                "launchd_labels": ["live.malibu.provider"],
                "launchd_plists": [providerPlist.path]
            ],
            plistLabel: "foreign.label",
            plistProgram: providerProgram.path
        )
        try "#!/bin/sh\nexit 1\n".write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(
            StartupState.launchdRepairEvidenceExists(
                paths: paths,
                homeDirectory: root
            )
        )
    }

    func testDetectRoutesPartialLaunchdEvidenceToOnboarding() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let providerPlist = root.appendingPathComponent(
            "Library/LaunchAgents/live.malibu.provider.plist"
        )
        let providerProgram = root.appendingPathComponent("macprovider/malibu-cli")
        let providerID = paths.configFile.deletingLastPathComponent().appendingPathComponent("provider_id")
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(at: providerPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerID.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "provider_id: p_partial\nprovider_token: secret-token\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        try "p_partial\n".write(to: providerID, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: paths.appMarkerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: paths.appMarkerFile)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>Label</key><string>live.malibu.provider</string>
          <key>ProgramArguments</key><array><string>\(providerProgram.path)</string></array>
        </dict></plist>
        """.write(to: providerPlist, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 1\n".write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = await StartupState.detect(
            paths: paths,
            homeDirectory: root,
            launchctlURL: launchctl
        )

        XCTAssertTrue(state.launchdInstallEvidenceExists)
        XCTAssertFalse(state.launchdJobNeedsRepair)
        XCTAssertFalse(state.providerLaunchdJobNeedsRepair)
        XCTAssertEqual(state.route(), .showOnboarding)
    }

    func testDetectTreatsConfigFIFOAsUnconfiguredWithoutBlocking() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(
            at: paths.configFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(Darwin.mkfifo(paths.configFile.path, 0o600), 0)
        try "#!/bin/sh\nexit 1\n".write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        try FileManager.default.createDirectory(
            at: paths.appMarkerFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: paths.appMarkerFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = await StartupState.detect(
            paths: paths,
            homeDirectory: root,
            launchctlURL: launchctl
        )

        XCTAssertTrue(state.configExists)
        XCTAssertFalse(state.appIdentityConfigured)
        XCTAssertFalse(state.launchdJobNeedsRepair)
        XCTAssertEqual(state.route(), .showOnboarding)
    }

    func testDetectAcceptsManifestSelectedCustomProviderIdentityWithoutRepair() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let providerPlist = root.appendingPathComponent(
            "Library/LaunchAgents/live.malibu.provider.plist"
        )
        let customProgram = root.appendingPathComponent("provider-support/malibu-cli")
        let manifest = root.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        )
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(
            at: providerPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: customProgram.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "<plist/>\n".write(to: providerPlist, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: customProgram, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: customProgram.path
        )
        try JSONSerialization.data(withJSONObject: [
            "install_prefix": customProgram.deletingLastPathComponent().path,
            "binary_path": customProgram.path,
        ])
            .write(to: manifest)
        try "#!/bin/sh\nprintf 'program = %s\\npath = %s\\n' '\(customProgram.path)' '\(providerPlist.path)'\n"
            .write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launchctl.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let state = await StartupState.detect(
            paths: paths,
            homeDirectory: root,
            launchctlURL: launchctl
        )

        XCTAssertFalse(state.launchdJobNeedsRepair)
    }

    func testMigrationImportWithoutLaunchdRoutesToOnboarding() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let launchctl = root.appendingPathComponent("launchctl")
        try paths.ensureDirectories()
        try "#!/bin/sh\nexit 1\n".write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        try "provider_id: p_import\nprovider_token: secret-token\nmodel: test\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: paths.appSupport.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent()) }
        defer { Task { try? await KeychainStore.deleteProviderToken(providerID: "p_import") } }

        let result = try await StartupState.applyMigrationDecision(
            .importExisting,
            paths: paths,
            importCredentialIntoCLI: { snapshot in
                XCTAssertTrue(try String(contentsOf: snapshot).contains("provider_token: secret-token"))
            },
            homeDirectory: root,
            launchctlURL: launchctl
        )
        let state = await StartupState.detect(
            paths: paths,
            homeDirectory: root,
            launchctlURL: launchctl
        )
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

    func testMigrationStartFreshStopsOnManualLaunchdConflict() async throws {
        let paths = try makeTempPaths()
        let root = paths.appSupport.deletingLastPathComponent()
        let launchctl = root.appendingPathComponent("launchctl")
        try paths.ensureDirectories()
        try "provider_id: p_old\nprovider_token: old-token\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf 'program = %s\\npath = %s\\n' '\(root.path)/unexpected-provider' '\(root.path)/Library/LaunchAgents/live.malibu.provider.plist'\n"
            .write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        defer { try? FileManager.default.removeItem(atPath: root.path) }

        let result = try await StartupState.applyMigrationDecision(
            .startFresh,
            paths: paths,
            deferStartFreshBackup: true,
            homeDirectory: root,
            launchctlURL: launchctl
        )

        XCTAssertEqual(result.route, .showLaunchdConflict)
        XCTAssertNil(result.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configFile.path))
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
        healthy: Bool,
        needsRepair: Bool = false,
        manualIntervention: Bool = false,
        providerNeedsRepair: Bool? = nil,
        watchdogNeedsRepair: Bool = false
    ) -> StartupState {
        StartupState(
            configExists: config,
            appMarkerExists: marker,
            appIdentityConfigured: configured ?? marker,
            launchdInstallEvidenceExists: launchd,
            backgroundProviderHealthy: healthy,
            launchdJobNeedsRepair: needsRepair,
            launchdJobNeedsManualIntervention: manualIntervention,
            providerLaunchdJobNeedsRepair: providerNeedsRepair,
            watchdogJobNeedsRepair: watchdogNeedsRepair
        )
    }

    private func writeRepairEvidence(
        paths: ProviderPaths,
        root: URL,
        manifest: [String: Any],
        plistLabel: String,
        plistProgram: String
    ) throws {
        let providerID = paths.configFile.deletingLastPathComponent().appendingPathComponent("provider_id")
        let providerPlist = root.appendingPathComponent(
            "Library/LaunchAgents/live.malibu.provider.plist"
        )
        try FileManager.default.createDirectory(
            at: providerID.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: providerPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Library/Application Support/macprovider"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: paths.appMarkerFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: paths.appMarkerFile)
        try "provider_id: p_repair\nprovider_token: secret-token\n"
            .write(to: paths.configFile, atomically: true, encoding: .utf8)
        try "p_repair\n".write(to: providerID, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        ))
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>Label</key><string>\(plistLabel)</string>
          <key>ProgramArguments</key><array><string>\(plistProgram)</string></array>
        </dict></plist>
        """.write(to: providerPlist, atomically: true, encoding: .utf8)
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
