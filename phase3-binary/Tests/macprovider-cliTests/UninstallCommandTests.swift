import CryptoKit
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class UninstallCommandTests: XCTestCase {

    // MARK: - SPEC-037 FR-KVP8 — uninstall purges KV disk tier (Finding 3)

    private func namespaceDigest(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// FR-KVP8: uninstall's KV cleanup (`purge --all --forget`) must enumerate-and-
    /// delete the namespace's Keychain items (per-epoch master + per-entry DEKs) AND
    /// remove the namespace directory, so no orphaned ciphertext or key material
    /// outlives the product. Drives the exact seam `UninstallCommand.run()` invokes.
    func testUninstallPurgesKVDiskCacheKeychainAndNamespaceDir() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvuninstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let namespaceID = "prov-uninstall"
        let keychain = KVInMemoryKeychain()
        let config = KVDiskCacheConfig(enabled: true, directory: root.path, minFreeBytes: 1024 * 1024)
        let tier = KVDiskTier(config: config, namespaceID: namespaceID, eligibilityTTLSeconds: 900,
                              keychain: keychain, sink: KVRecordingEventSink())
        let activated = await tier.activateForControlPlane()
        XCTAssertTrue(activated)

        // Write one entry: creates the namespace dir + per-epoch master + per-entry DEK.
        let key = "conv:kvs-synth:uninstall"
        let seq = 4
        let byteCount = 1 * 2 * seq * 4 * KVCodecDType.f32.byteSize
        let identity = KVWriteIdentity(
            requestModel: "m", servedModelID: "m", modelSHA256: String(repeating: "b", count: 64),
            catalogRevision: "r", tokenizerID: "m", tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), abiEpoch: 1,
            mlxSwiftLMRevision: "x", mlxVersion: "y", cacheClass: "KVCacheSimple", layerCount: 1,
            kvBits: nil, kvGroupSize: nil, kvQuantMode: nil, kvQuantPolicy: nil, decodePath: "ordinary", keyEpoch: 1)
        let index = try await tier.store.currentIndex(rawKey: key)
        let sampled = try await tier.store.highWatermark(rawKey: key)
        let snapshot = KVWriteSnapshot(
            rawKey: key, indexHMAC: try XCTUnwrap(index), tokens: Array(0 ..< Int32(seq)),
            layers: [KVLayerPayload(layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 2, seq, 4],
                                    dtype: .f32, cacheOffset: seq,
                                    keyBytes: Data(count: byteCount), valueBytes: Data(count: byteCount))],
            identity: identity, sampledPurgeGeneration: sampled, commitSequence: 1,
            createdAtMillis: 1_000_000, eligibleUntilMillis: 1_900_000, incarnation: "inc-uninstall")
        guard case .committed = try await tier.store.write(snapshot, nowMillis: 1_000_000) else {
            return XCTFail("seed entry must commit")
        }

        let keyManager = KVKeyManager(keychain: keychain, namespaceID: namespaceID)
        XCTAssertGreaterThanOrEqual(try keyManager.keychainItemCount(), 1, "entry write created Keychain items")
        let namespaceDir = root.appendingPathComponent(namespaceDigest(namespaceID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: namespaceDir.path), "namespace dir exists after write")

        // Invoke the exact cleanup seam uninstall runs.
        var warnings: [String] = []
        await UninstallCommand.purgeKVDiskCache(tier, warnings: &warnings)

        XCTAssertEqual(try keyManager.keychainItemCount(), 0, "uninstall deletes all namespace Keychain items")
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespaceDir.path), "uninstall removes the namespace dir")
        XCTAssertTrue(warnings.isEmpty, "a clean KV cleanup adds no warning: \(warnings)")
    }

    /// FINDING C — when the KV disk tier cannot be resolved (config unreadable /
    /// empty provider_id) uninstall must not skip cleanup silently: it surfaces an
    /// explicit warning that encrypted KV survival data + Keychain DEKs may remain,
    /// while still staying best-effort (never hard-failing uninstall).
    func testUninstallWarnsWhenKVCleanupCannotResolveConfig() async throws {
        // Point config resolution at a path that does not exist so ConfigLoader.load
        // throws (explicit path + missing file) and makeKVDiskTierForUninstall() → nil.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvuninstall-missing-\(UUID().uuidString).yaml").path
        let previous = getenv("MACPROVIDER_CONFIG").map { String(cString: $0) }
        setenv("MACPROVIDER_CONFIG", missing, 1)
        defer {
            if let previous { setenv("MACPROVIDER_CONFIG", previous, 1) } else { unsetenv("MACPROVIDER_CONFIG") }
        }
        XCTAssertNil(UninstallCommand.makeKVDiskTierForUninstall(), "precondition: tier unresolvable")

        var warnings: [String] = []
        await UninstallCommand.purgeKVDiskCacheBestEffort(warnings: &warnings)

        XCTAssertEqual(warnings.count, 1, "the skip path must surface exactly one warning: \(warnings)")
        let warning = try XCTUnwrap(warnings.first)
        XCTAssertTrue(warning.contains("kv-cache cleanup skipped"), "warning names the skip: \(warning)")
        XCTAssertTrue(warning.contains("may remain"), "warning states residue may remain: \(warning)")
    }

    func testStopLaunchdServicesAcceptsVerifiedAbsentJob() throws {
        var calls: [[String]] = []

        try UninstallCommand.stopLaunchdServices(labels: ["live.malibu.provider"], uid: 501) { arguments in
            calls.append(arguments)
            return arguments.first == "bootout" ? 3 : 113
        }

        XCTAssertEqual(calls, [
            ["bootout", "gui/501/live.malibu.provider-watchdog"],
            ["print", "gui/501/live.malibu.provider-watchdog"],
            ["bootout", "gui/501/live.malibu.provider"],
            ["print", "gui/501/live.malibu.provider"],
            ["bootout", "gui/501/live.streamvc.macprovider-watchdog"],
            ["print", "gui/501/live.streamvc.macprovider-watchdog"],
            ["bootout", "gui/501/live.streamvc.macprovider"],
            ["print", "gui/501/live.streamvc.macprovider"],
            ["print", "gui/501/live.malibu.provider-watchdog"],
            ["print", "gui/501/live.malibu.provider"],
            ["print", "gui/501/live.streamvc.macprovider-watchdog"],
            ["print", "gui/501/live.streamvc.macprovider"],
        ])
    }

    func testStopLaunchdServicesAcceptsLegacyStreamVCLabelsForMigration() throws {
        var calls: [[String]] = []

        try UninstallCommand.stopLaunchdServices(
            labels: ["live.streamvc.macprovider", "live.streamvc.macprovider-watchdog"],
            uid: 501
        ) { arguments in
            calls.append(arguments)
            return 113
        }

        XCTAssertTrue(calls.contains(["bootout", "gui/501/live.streamvc.macprovider-watchdog"]))
        XCTAssertTrue(calls.contains(["bootout", "gui/501/live.streamvc.macprovider"]))
    }

    func testStopLaunchdServicesRejectsJobThatRemainsLoaded() {
        XCTAssertThrowsError(
            try UninstallCommand.stopLaunchdServices(
                labels: ["live.malibu.provider"],
                uid: 501,
                run: { arguments in
                    guard arguments.first == "print" else { return 0 }
                    return arguments.last?.hasSuffix("/live.malibu.provider-watchdog") == true ? 113 : 0
                },
                sleep: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? UninstallCommand.UninstallError,
                .serviceStillLoaded("live.malibu.provider")
            )
        }
    }

    // A `bootout` that returns before the job finishes tearing down leaves
    // `launchctl print` reporting status 0 for a brief window. The absence check
    // must poll through that grace window rather than immediately refusing, so a
    // job that becomes absent on a later poll is accepted (issue #1420, Claim 1).
    func testStopLaunchdServicesToleratesBootoutTeardownLag() throws {
        var providerPrints = 0
        var sleeps = 0
        try UninstallCommand.stopLaunchdServices(
            labels: ["live.malibu.provider"],
            uid: 501,
            run: { arguments in
                guard arguments.first == "print" else { return 3 }
                guard arguments.last?.hasSuffix("/live.malibu.provider") == true else { return 113 }
                providerPrints += 1
                // First poll: still tearing down (0); second poll: gone (113).
                return providerPrints >= 2 ? 113 : 0
            },
            sleep: { _ in sleeps += 1 }
        )
        XCTAssertGreaterThanOrEqual(providerPrints, 2)
        XCTAssertGreaterThanOrEqual(sleeps, 1)
    }

    func testStopLaunchdServicesRejectsIndeterminatePrintFailure() {
        var printCount = 0
        XCTAssertThrowsError(
            try UninstallCommand.stopLaunchdServices(
                labels: ["live.malibu.provider"],
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
                .serviceAbsenceVerificationFailed("live.malibu.provider-watchdog", 64)
            )
        }
    }

    func testStopLaunchdServicesRejectsProviderRestartedAfterInitialStopProof() {
        var calls: [[String]] = []
        var providerPrints = 0

        XCTAssertThrowsError(
            try UninstallCommand.stopLaunchdServices(
                labels: ["live.malibu.provider", "live.malibu.provider-watchdog"],
                uid: 501,
                run: { arguments in
                    calls.append(arguments)
                    guard arguments.first == "print" else { return 0 }
                    if arguments.last?.hasSuffix("/live.malibu.provider") == true {
                        providerPrints += 1
                        // Absent at the per-label stop proof, then persistently
                        // re-loaded (status 0) once the watchdog restarts it — the
                        // final recheck polls through the grace window and still
                        // fails closed.
                        return providerPrints == 1 ? 113 : 0
                    }
                    return 113
                },
                sleep: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? UninstallCommand.UninstallError,
                .serviceStillLoaded("live.malibu.provider")
            )
        }

        // The final recheck detects the restarted provider; the last launchctl
        // call is a print of the provider label (repeated across the grace-window
        // polls before failing closed).
        XCTAssertEqual(calls.last, ["print", "gui/501/live.malibu.provider"])
        XCTAssertGreaterThan(providerPrints, 2)
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

    func testStopUninstallServicesUsesSystemDomainForHeadless() throws {
        var commands: [[String]] = []
        try UninstallCommand.stopUninstallServices(
            labels: ["live.malibu.provider", "live.malibu.provider-watchdog"],
            uid: 501,
            systemDomain: true,
            run: { arguments in
                commands.append(arguments)
                return arguments.contains("print") ? 113 : 0
            },
            sleep: { _ in }
        )
        let bootouts = commands.filter { $0.contains("bootout") }
        let prints = commands.filter { $0.contains("print") }
        XCTAssertEqual(bootouts.count, 4, "every managed system job is booted out")
        XCTAssertTrue(bootouts.allSatisfy { $0.contains { $0.hasPrefix("system/live.") } })
        XCTAssertTrue(prints.allSatisfy { $0.contains { $0.hasPrefix("system/live.") } })
        XCTAssertFalse(commands.contains { $0.contains("gui/501") })
    }

    func testStopUninstallServicesRejectsUnexpectedHeadlessLabel() {
        var called = false
        XCTAssertThrowsError(
            try UninstallCommand.stopUninstallServices(
                labels: ["com.example.unrelated"],
                uid: 501,
                systemDomain: true,
                run: { _ in
                    called = true
                    return 113
                },
                sleep: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? UninstallCommand.UninstallError,
                .unexpectedServiceLabel("com.example.unrelated")
            )
        }
        XCTAssertFalse(called)
    }

    func testStopUninstallServicesFailsClosedWhenSudoBootoutFails() {
        XCTAssertThrowsError(
            try UninstallCommand.stopUninstallServices(
                labels: ["live.malibu.provider"],
                uid: 501,
                systemDomain: true,
                run: { arguments in
                    arguments.contains("bootout") ? 1 : 113
                },
                sleep: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? UninstallCommand.UninstallError,
                .headlessUninstallPrivilegeRequired
            )
        }
    }

    func testStopUninstallServicesFailsClosedWhenSystemServiceRemainsLoaded() {
        XCTAssertThrowsError(
            try UninstallCommand.stopUninstallServices(
                labels: ["live.malibu.provider"],
                uid: 501,
                systemDomain: true,
                run: { _ in 0 },
                sleep: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? UninstallCommand.UninstallError,
                .serviceStillLoaded("live.malibu.provider-watchdog")
            )
        }
    }

    func testArtifactPathsMatchCanonicalInstallLayout() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let paths = UninstallCommand.artifactPaths(home: home)

        XCTAssertEqual(paths.binary.path, "/Users/tester/.local/bin/macprovider-cli")
        XCTAssertEqual(paths.supportDirectory.path, "/Users/tester/macprovider")
        XCTAssertEqual(paths.logsDirectory.path, "/Users/tester/Library/Logs/macprovider")
        XCTAssertEqual(paths.plist.path, "/Users/tester/Library/LaunchAgents/live.malibu.provider.plist")
        XCTAssertEqual(paths.watchdogPlist.path, "/Users/tester/Library/LaunchAgents/live.malibu.provider-watchdog.plist")
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
          "launchd_labels": ["live.malibu.provider", "live.malibu.provider-watchdog"],
          "launchd_plists": ["\(root.path)/Library/LaunchAgents/live.malibu.provider.plist"],
          "data_dirs": ["\(root.path)/custom", "\(root.path)/Library/Logs/macprovider"],
          "provider_state_root": "\(root.path)/.local/share/macprovider",
          "version": "v1.8.10"
        }
        """.write(to: manifest, atomically: true, encoding: .utf8)

        let result = try UninstallCommand.loadManifest(home: root)
        guard case .loaded(let loaded) = result else {
            return XCTFail("manifest was not loaded")
        }
        XCTAssertEqual(loaded.installPrefix, "\(root.path)/custom")
        XCTAssertEqual(loaded.launchdLabels, ["live.malibu.provider", "live.malibu.provider-watchdog"])
        XCTAssertEqual(loaded.dataDirs, ["\(root.path)/custom", "\(root.path)/Library/Logs/macprovider"])
        XCTAssertEqual(loaded.symlinkPath, "\(root.path)/.local/bin/macprovider-cli")
        XCTAssertEqual(loaded.providerStateRoot, "\(root.path)/.local/share/macprovider")
        XCTAssertNil(loaded.installProfile)
        XCTAssertNil(loaded.launchdDomain)

        // The autoupdate transaction residue removed on uninstall lives under
        // the manifest's provider_state_root (issue #1420, Claim 2).
        let allowed = try UninstallCommand.allowedRemovalPaths(home: root, manifest: loaded)
        XCTAssertEqual(
            allowed.autoupdateResidue,
            "\(root.path)/.local/share/macprovider/autoupdate"
        )
    }

    func testAllowedRemovalPathsFallsBackToCanonicalStateRootWhenManifestOmitsIt() throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        // Older manifests predate `provider_state_root`; uninstall must still
        // clear the canonical autoupdate residue so reinstall is not blocked.
        let manifest = UninstallCommand.InstallManifest(
            installPrefix: "/Users/tester/macprovider",
            launchdLabels: ["live.malibu.provider", "live.malibu.provider-watchdog"],
            dataDirs: ["/Users/tester/macprovider"],
            version: "v1.8.10",
            binaryPath: nil,
            symlinkPath: "/Users/tester/.local/bin/macprovider-cli",
            launchdPlists: [],
            installProfile: nil,
            launchdDomain: nil
        )
        XCTAssertNil(manifest.providerStateRoot)
        let allowed = try UninstallCommand.allowedRemovalPaths(home: home, manifest: manifest)
        XCTAssertEqual(
            allowed.autoupdateResidue,
            "/Users/tester/.local/share/macprovider/autoupdate"
        )
    }

    func testAllowedRemovalPathsRejectsOffTreeManifestStateRoot() throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        // A corrupt/tampered manifest must not redirect recursive residue removal
        // at an arbitrary path; a non-canonical provider_state_root falls back to
        // the canonical location instead of being honored (issue #1420 audit).
        let manifest = UninstallCommand.InstallManifest(
            installPrefix: "/Users/tester/macprovider",
            launchdLabels: ["live.malibu.provider", "live.malibu.provider-watchdog"],
            dataDirs: ["/Users/tester/macprovider"],
            version: "v1.8.10",
            binaryPath: nil,
            symlinkPath: "/Users/tester/.local/bin/macprovider-cli",
            launchdPlists: [],
            installProfile: nil,
            launchdDomain: nil,
            providerStateRoot: "/Users/tester/Documents"
        )
        let allowed = try UninstallCommand.allowedRemovalPaths(home: home, manifest: manifest)
        XCTAssertEqual(
            allowed.autoupdateResidue,
            "/Users/tester/.local/share/macprovider/autoupdate"
        )
        XCTAssertNotEqual(allowed.autoupdateResidue, "/Users/tester/Documents/autoupdate")
    }

    func testLoadManifestFailsClosedOnMalformedManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macprovider-uninstall-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = UninstallCommand.artifactPaths(home: root).manifest
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{not-json".write(to: manifest, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try UninstallCommand.loadManifest(home: root)) { error in
            guard case .invalidInstallManifest = error as? UninstallCommand.UninstallError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testHeadlessManifestUninstallProfileRemainsUnsupportedForLegacyCallers() throws {
        let manifest = UninstallCommand.InstallManifest(
            installPrefix: "/Users/fleet/macprovider",
            launchdLabels: ["live.malibu.provider", "live.malibu.provider-watchdog"],
            dataDirs: ["/Users/fleet/macprovider"],
            version: "v1.8.106",
            binaryPath: "/Users/fleet/macprovider/macprovider-cli",
            symlinkPath: "/Users/fleet/.local/bin/macprovider-cli",
            launchdPlists: [
                "/Users/fleet/.config/macprovider/launchd/live.malibu.provider.plist",
                "/Users/fleet/.config/macprovider/launchd/live.malibu.provider-watchdog.plist",
            ],
            installProfile: "headless_fleet",
            launchdDomain: "system"
        )

        XCTAssertThrowsError(try UninstallCommand.validateUninstallProfile(manifest)) { error in
            XCTAssertEqual(error as? UninstallCommand.UninstallError, .unsupportedHeadlessInstallProfile)
        }
    }

    func testHeadlessManifestUsesSystemDomainAndConsumerDoesNot() {
        let headless = UninstallCommand.InstallManifest(
            installPrefix: "/Users/fleet/macprovider",
            launchdLabels: ["live.malibu.provider"],
            dataDirs: [],
            version: nil,
            binaryPath: nil,
            symlinkPath: nil,
            launchdPlists: [],
            installProfile: "headless_fleet",
            launchdDomain: "system"
        )
        let consumer = UninstallCommand.InstallManifest(
            installPrefix: "/Users/fleet/macprovider",
            launchdLabels: ["live.malibu.provider"],
            dataDirs: [],
            version: nil,
            binaryPath: nil,
            symlinkPath: nil,
            launchdPlists: [],
            installProfile: "consumer_user",
            launchdDomain: "gui/501"
        )
        XCTAssertTrue(UninstallCommand.installsInSystemDomain(headless))
        XCTAssertFalse(UninstallCommand.installsInSystemDomain(consumer))
    }

    func testHeadlessAllowedRemovalPathsIncludeSystemLaunchDaemonPlists() throws {
        let home = URL(fileURLWithPath: "/Users/fleet", isDirectory: true)
        let manifest = UninstallCommand.InstallManifest(
            installPrefix: "/Users/fleet/macprovider",
            launchdLabels: ["live.malibu.provider"],
            dataDirs: [],
            version: nil,
            binaryPath: nil,
            symlinkPath: nil,
            launchdPlists: [
                "/Users/fleet/.config/macprovider/launchd/live.malibu.provider.plist",
                "/Users/fleet/.config/macprovider/launchd/live.malibu.provider-watchdog.plist",
            ],
            installProfile: "headless_fleet",
            launchdDomain: "system"
        )
        let allowed = try UninstallCommand.allowedRemovalPaths(home: home, manifest: manifest)
        XCTAssertTrue(
            try UninstallCommand.path(
                "/Library/LaunchDaemons/live.malibu.provider.plist",
                isAllowedBy: allowed.plists
            )
        )
        XCTAssertTrue(
            try UninstallCommand.path(
                "/Library/LaunchDaemons/live.malibu.provider-watchdog.plist",
                isAllowedBy: allowed.plists
            )
        )
    }

    func testLoadedConsumerManifestStillFailsClosedWhenSystemArtifactsExist() throws {
        XCTAssertThrowsError(try UninstallCommand.validateNoHeadlessSystemArtifactsPresent(
            systemPlists: ["/Library/LaunchDaemons/live.malibu.provider.plist"],
            fileExists: { $0 == "/Library/LaunchDaemons/live.malibu.provider.plist" }
        ) { _ in 113 }) { error in
            XCTAssertEqual(error as? UninstallCommand.UninstallError, .unsupportedHeadlessInstallProfile)
        }
    }

    func testMissingManifestFailsClosedWhenSystemServiceIsLoaded() throws {
        XCTAssertThrowsError(try UninstallCommand.validateNoHeadlessSystemArtifactsPresent(
            systemPlists: [],
            fileExists: { _ in false }
        ) { arguments in
            arguments == ["print", "system/live.malibu.provider"] ? 0 : 113
        }) { error in
            XCTAssertEqual(error as? UninstallCommand.UninstallError, .unsupportedHeadlessInstallProfile)
        }
    }

    func testMissingManifestFailsClosedWhenSystemServiceStateIsUnknown() throws {
        XCTAssertThrowsError(try UninstallCommand.validateNoHeadlessSystemArtifactsPresent(
            systemPlists: [],
            fileExists: { _ in false }
        ) { _ in 64 }) { error in
            guard case .headlessProfileIndeterminateWithoutManifest(let label, let status) = error as? UninstallCommand.UninstallError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(label, "live.malibu.provider-watchdog")
            XCTAssertEqual(status, 64)
        }
    }

    func testMissingManifestFailsClosedWhenSystemLaunchDaemonPlistExists() throws {
        XCTAssertThrowsError(try UninstallCommand.validateNoHeadlessSystemArtifactsPresent(
            systemPlists: ["/Library/LaunchDaemons/live.malibu.provider.plist"],
            fileExists: { $0 == "/Library/LaunchDaemons/live.malibu.provider.plist" }
        ) { _ in 113 }) { error in
            XCTAssertEqual(error as? UninstallCommand.UninstallError, .unsupportedHeadlessInstallProfile)
        }
    }

    func testMissingManifestAllowsLegacyWhenSystemServicesAreAbsent() throws {
        XCTAssertNoThrow(try UninstallCommand.validateNoHeadlessSystemArtifactsPresent(
            systemPlists: [],
            fileExists: { _ in false }
        ) { _ in 113 })
        XCTAssertNoThrow(try UninstallCommand.validateNoHeadlessSystemArtifactsPresent(
            systemPlists: [],
            fileExists: { _ in false }
        ) { _ in 1 })
        XCTAssertNoThrow(try UninstallCommand.validateNoHeadlessSystemArtifactsPresent(
            systemPlists: [],
            fileExists: { _ in false }
        ) { _ in 3 })
    }

    func testLegacyManifestCoversProviderAndWatchdogArtifacts() {
        let home = URL(fileURLWithPath: "/Users/legacy")
        let manifest = UninstallCommand.legacyManifest(home: home)

        XCTAssertEqual(manifest.launchdLabels, ["live.malibu.provider", "live.malibu.provider-watchdog"])
        XCTAssertTrue(manifest.dataDirs.contains("/Users/legacy/macprovider"))
        XCTAssertTrue(manifest.dataDirs.contains("/Users/legacy/.local/share/macprovider-watchdog"))
        XCTAssertTrue(manifest.launchdPlists.contains("/Users/legacy/Library/LaunchAgents/live.malibu.provider-watchdog.plist"))
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
            launchdLabels: ["live.malibu.provider"],
            dataDirs: ["/opt/macprovider"],
            version: "v1.8.10",
            binaryPath: "/opt/macprovider/macprovider-cli",
            symlinkPath: "/Users/tester/.local/bin/macprovider-cli",
            launchdPlists: ["/Users/tester/Library/LaunchAgents/live.malibu.provider.plist"],
            installProfile: nil,
            launchdDomain: nil
        )
        let allowed = try UninstallCommand.allowedRemovalPaths(home: home, manifest: manifest)

        XCTAssertTrue(try UninstallCommand.path("/opt/macprovider", isAllowedBy: allowed.dataDirs))
        XCTAssertTrue(try UninstallCommand.path("/opt/macprovider/macprovider-cli", isAllowedBy: allowed.binaries))
        XCTAssertFalse(try UninstallCommand.path("/opt/macprovider/../etc", isAllowedBy: allowed.dataDirs))
        XCTAssertFalse(try UninstallCommand.path("/Users/tester/Library/LaunchAgents/other.plist", isAllowedBy: allowed.plists))
    }

    func testApplicationSupportCleanupRetainsOnlyLifecycleTombstone() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macprovider-uninstall-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = root.appendingPathComponent("lifecycle", isDirectory: true)
        try FileManager.default.createDirectory(at: lifecycle, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: lifecycle.appendingPathComponent("state-v1.json"))
        try Data().write(to: lifecycle.appendingPathComponent(".state-v1.json.lock"))
        try Data("lease".utf8).write(to: lifecycle.appendingPathComponent("lease-v1.json"))
        try Data("manifest".utf8).write(to: root.appendingPathComponent("install_manifest.json"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".residue"))
        let models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: models.appendingPathComponent("weights.bin"))

        var warnings: [String] = []
        UninstallCommand.cleanupApplicationSupportPreservingLifecycleState(
            root,
            warnings: &warnings
        )

        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            ["lifecycle"]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: lifecycle.path).sorted(),
            [".state-v1.json.lock", "state-v1.json"]
        )
    }

    func testAliasIsOwnedSymlinkOnlyForCanonicalEntrypointTarget() throws {
        // #1261: uninstall removes the malibu-cli alias only when it is our
        // symlink (points exactly at ~/.local/bin/macprovider-cli), including
        // when dangling; never a user's own file or a symlink to another target.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alias-owned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let entrypoint = dir.appendingPathComponent("macprovider-cli")
        let alias = dir.appendingPathComponent("malibu-cli")

        // Owned: symlink -> canonical entrypoint (even while the entrypoint is
        // absent, i.e. dangling).
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: entrypoint.path)
        XCTAssertTrue(UninstallCommand.aliasIsOwnedSymlink(alias, canonicalEntrypoint: entrypoint))

        // Not owned: a symlink to a different target that merely shares the name.
        try FileManager.default.removeItem(at: alias)
        let other = dir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let foreign = other.appendingPathComponent("macprovider-cli")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: foreign.path)
        XCTAssertFalse(UninstallCommand.aliasIsOwnedSymlink(alias, canonicalEntrypoint: entrypoint))

        // Not owned: a user's own regular file at the alias path.
        try FileManager.default.removeItem(at: alias)
        try Data("mine".utf8).write(to: alias)
        XCTAssertFalse(UninstallCommand.aliasIsOwnedSymlink(alias, canonicalEntrypoint: entrypoint))
    }
}
