import XCTest
@testable import Malibu

final class InstalledProviderMonitorTests: XCTestCase {
    func testHealthSnapshotDecodesTokenCountersFromJSON() throws {
        let json = """
        {
          "status": "ready",
          "model": "qwen3-coder-30b-a3b-instruct",
          "requests_total": 4,
          "requests_today": 2,
          "input_tokens_today": 766,
          "output_tokens_today": 1325,
          "input_tokens_all_time": 766,
          "output_tokens_all_time": 1325,
          "uptime_s": 4713,
          "restart_count": 5
        }
        """.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]

        let status = object["status"] as? String
        let model = object["model"] as? String
        let requestsTotal = object["requests_total"] as? Int
        let requestsToday = object["requests_today"] as? Int
        let inputTokensToday = Self.int64Value(object["input_tokens_today"])
        let outputTokensToday = Self.int64Value(object["output_tokens_today"])
        let inputTokensAllTime = Self.int64Value(object["input_tokens_all_time"])
        let outputTokensAllTime = Self.int64Value(object["output_tokens_all_time"])
        let uptimeSeconds = object["uptime_s"] as? Int
        let restartCount = object["restart_count"] as? Int

        let snapshot = InstalledProviderMonitor.HealthSnapshot(
            ready: status == "ready",
            model: model,
            requestsTotal: requestsTotal,
            requestsToday: requestsToday,
            inputTokensToday: inputTokensToday,
            outputTokensToday: outputTokensToday,
            inputTokensAllTime: inputTokensAllTime,
            outputTokensAllTime: outputTokensAllTime,
            uptimeSeconds: uptimeSeconds,
            restartCount: restartCount
        )

        XCTAssertTrue(snapshot.ready)
        XCTAssertEqual(snapshot.requestsTotal, 4)
        XCTAssertEqual(snapshot.requestsToday, 2)
        XCTAssertEqual(snapshot.restartCount, 5)
        XCTAssertEqual(snapshot.inputTokensToday, 766)
        XCTAssertEqual(snapshot.outputTokensToday, 1325)
        XCTAssertEqual(snapshot.inputTokensAllTime, 766)
        XCTAssertEqual(snapshot.outputTokensAllTime, 1325)
    }

    func testStatusSnapshotDecodesBuyerServingCatalogTrust() throws {
        let now = Date()
        let observedAt = ISO8601DateFormatter().string(from: now)
        let json = """
        {
          "binary_version": "0.5.0",
          "compatibility_set_id": "Augustas11/macprovider:v0.5.0@0123456789abcdef0123456789abcdef01234567",
          "compatibility_set_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
          "provider_id": "provider-a",
          "local_status_contract": {
            "version": 1,
            "minimum_reader_version": 1,
            "lifecycle_owner": "malibu_cli",
            "capabilities": [
              "buyer_serving_authority_v1",
              "catalog_status_v1",
              "compatibility_set_v1",
              "credential_status_v1",
              "admission_identity_v1",
              "lifecycle_lease_v1",
              "lifecycle_significant_events_v1",
              "lifecycle_transition_v1",
              "persisted_lifecycle_state_v1",
              "service_instance_v1",
              "status_observation_v1"
            ]
          },
          "observation": {
            "id": "observation-a",
            "observed_at": "\(observedAt)",
            "valid_for_ms": 5000
          },
          "service_instance": {
            "instance_id": "instance-a",
            "pid": 4321,
            "boot_session": "boot-a",
            "started_at": "2026-07-14T06:59:00Z",
            "role": "serve"
          },
          "lifecycle": {
            "record_state": "valid",
            "sequence": 17,
            "transition_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "transition_at": "2026-07-14T06:59:30Z",
            "state": "serving_buyers",
            "reason_code": "coordinator_buyer_serving_confirmed",
            "authority": "malibu_cli",
            "writer": "serve",
            "operation_id": "serve:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "operator_paused": false,
            "last_restart": {
              "sequence": 2,
              "transition_id": "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
              "transition_at": "2026-07-14T06:55:00Z",
              "state": "starting_provider",
              "reason_code": "maintenance_handoff_restart",
              "writer": "serve",
              "operation_id": "self-update:one"
            },
            "last_update": {
              "sequence": 1,
              "transition_id": "cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa",
              "transition_at": "2026-07-14T06:54:00Z",
              "state": "update_in_progress",
              "reason_code": "signed_compatibility_set_validated",
              "writer": "updater",
              "compatibility_set_id": "set-1",
              "operation_id": "self-update:one"
            }
          },
          "lifecycle_lease": {
            "state": "active",
            "kind": "maintenance",
            "operation_id": "autoupdate:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "owner_pid": 4321,
            "expires_wall_ms": 1784012400000,
            "invalid_reason": null
          },
          "network_state": "buyer_serving",
          "coordinator": {
            "connected": true,
            "tier": "trusted",
            "identity_admission_mode": "signature",
            "recommended_binary_version": "0.5.1"
          },
          "catalog": {
            "state": "live_verified",
            "release_id": "published-2026-07-10-catalog-recovery-v1",
            "digest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "signer_key_id": "streamvc-autotune-static-v4",
            "source": "coordinator"
          },
          "credential": {
            "source": "cli_keychain",
            "state": "ready",
            "restart_safe": true,
            "migration_pending": false,
            "recovery_action": "none"
          },
          "admission_identity": {
            "owner": "malibu_cli",
            "source": "cli_keychain",
            "state": "recovery_pending",
            "public_key_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "pending_public_key_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "previous_public_key_sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            "previous_valid_until": "2026-07-21T12:00:00Z",
            "coordinator_generation": 2,
            "coordinator_public_key_sha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            "coordinator_key_role": "previous",
            "transition_error": "approval_required",
            "recovery_action": "obtain_operator_recovery_approval_then_restart"
          }
        }
        """.data(using: .utf8)!

        let snapshot = try XCTUnwrap(InstalledProviderMonitor.decodeStatus(
            json,
            now: now,
            currentBootSession: "boot-a"
        ))
        XCTAssertEqual(snapshot.providerID, "provider-a")
        XCTAssertEqual(
            snapshot.compatibilitySetID,
            "Augustas11/macprovider:v0.5.0@0123456789abcdef0123456789abcdef01234567"
        )
        XCTAssertEqual(snapshot.compatibilitySetSHA256, String(repeating: "c", count: 64))
        XCTAssertEqual(snapshot.networkState, "buyer_serving")
        XCTAssertEqual(snapshot.contractVersion, 1)
        XCTAssertEqual(snapshot.minimumReaderVersion, 1)
        XCTAssertEqual(snapshot.contractCompatible, true)
        XCTAssertEqual(snapshot.lifecycleOwner, "malibu_cli")
        XCTAssertTrue(snapshot.capabilities.contains("buyer_serving_authority_v1"))
        XCTAssertEqual(snapshot.observationID, "observation-a")
        XCTAssertNotNil(snapshot.observedAt)
        XCTAssertEqual(snapshot.observationValidForMS, 5_000)
        XCTAssertEqual(snapshot.observationFresh, true)
        XCTAssertEqual(snapshot.serviceInstanceID, "instance-a")
        XCTAssertEqual(snapshot.servicePID, 4321)
        XCTAssertEqual(snapshot.serviceBootSession, "boot-a")
        XCTAssertNotNil(snapshot.serviceStartedAt)
        XCTAssertEqual(snapshot.serviceRole, "serve")
        XCTAssertNotNil(snapshot.transitionAt)
        XCTAssertEqual(snapshot.transitionAuthority, "malibu_cli")
        XCTAssertEqual(snapshot.transitionRecordState, "valid")
        XCTAssertEqual(snapshot.transitionSequence, 17)
        XCTAssertEqual(snapshot.transitionID, "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        XCTAssertEqual(snapshot.transitionState, "serving_buyers")
        XCTAssertEqual(snapshot.transitionReason, "coordinator_buyer_serving_confirmed")
        XCTAssertEqual(snapshot.transitionWriter, "serve")
        XCTAssertEqual(snapshot.operatorPaused, false)
        XCTAssertEqual(snapshot.lastRestart?.reason, "maintenance_handoff_restart")
        XCTAssertEqual(snapshot.lastRestart?.operationID, "self-update:one")
        XCTAssertEqual(snapshot.lastUpdate?.reason, "signed_compatibility_set_validated")
        XCTAssertEqual(snapshot.lastUpdate?.compatibilitySetID, "set-1")
        XCTAssertNil(snapshot.lastRejection)
        XCTAssertNil(snapshot.lastWatchdog)
        XCTAssertEqual(snapshot.lifecycleLeaseState, "active")
        XCTAssertEqual(snapshot.lifecycleLeaseKind, "maintenance")
        XCTAssertEqual(
            snapshot.lifecycleLeaseOperationID,
            "autoupdate:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )
        XCTAssertEqual(snapshot.lifecycleLeaseExpiresWallMS, 1_784_012_400_000)
        XCTAssertTrue(snapshot.coordinatorConnected)
        XCTAssertEqual(snapshot.coordinatorIdentityAdmissionMode, "signature")
        XCTAssertEqual(snapshot.catalogState, "live_verified")
        XCTAssertEqual(snapshot.catalogReleaseID, "published-2026-07-10-catalog-recovery-v1")
        XCTAssertEqual(snapshot.catalogSignerKeyID, "streamvc-autotune-static-v4")
        XCTAssertEqual(snapshot.catalogSource, "coordinator")
        XCTAssertEqual(snapshot.credentialSource, "cli_keychain")
        XCTAssertEqual(snapshot.credentialState, "ready")
        XCTAssertEqual(snapshot.admissionIdentitySource, "cli_keychain")
        XCTAssertEqual(snapshot.admissionIdentityState, "recovery_pending")
        XCTAssertEqual(snapshot.admissionIdentityPublicKeySHA256, String(repeating: "b", count: 64))
        XCTAssertEqual(snapshot.admissionIdentityPendingPublicKeySHA256, String(repeating: "d", count: 64))
        XCTAssertEqual(snapshot.admissionIdentityPreviousPublicKeySHA256, String(repeating: "e", count: 64))
        XCTAssertEqual(
            snapshot.admissionIdentityPreviousValidUntil,
            ISO8601DateFormatter().date(from: "2026-07-21T12:00:00Z")
        )
        XCTAssertEqual(snapshot.admissionIdentityCoordinatorGeneration, 2)
        XCTAssertEqual(snapshot.admissionIdentityCoordinatorPublicKeySHA256, String(repeating: "f", count: 64))
        XCTAssertEqual(snapshot.admissionIdentityCoordinatorKeyRole, "previous")
        XCTAssertEqual(snapshot.admissionIdentityTransitionError, "approval_required")
        XCTAssertEqual(snapshot.admissionIdentityRecoveryAction, "obtain_operator_recovery_approval_then_restart")
        XCTAssertEqual(snapshot.credentialRestartSafe, true)
        XCTAssertEqual(snapshot.credentialMigrationPending, false)
        XCTAssertEqual(snapshot.credentialRecoveryAction, "none")

        let legacyJSON = try XCTUnwrap(String(data: json, encoding: .utf8))
            .replacingOccurrences(of: "malibu_cli", with: "macprovider_cli")
            .data(using: .utf8)!
        let legacySnapshot = try XCTUnwrap(InstalledProviderMonitor.decodeStatus(
            legacyJSON,
            now: now,
            currentBootSession: "boot-a"
        ))
        XCTAssertEqual(legacySnapshot.lifecycleOwner, "macprovider_cli")
        XCTAssertEqual(legacySnapshot.transitionAuthority, "macprovider_cli")
        XCTAssertEqual(legacySnapshot.transitionRecordState, "valid")
    }

    func testBusyHealthStatusRemainsHealthyDuringBuyerRequest() {
        XCTAssertTrue(InstalledProviderMonitor.isHealthyStatus("ready"))
        XCTAssertTrue(InstalledProviderMonitor.isHealthyStatus("busy"))
        XCTAssertFalse(InstalledProviderMonitor.isHealthyStatus("starting"))
    }

    func testPersistedLifecycleContractFailsClosedOnFabricatedTransitionID() throws {
        let now = Date()
        let observedAt = ISO8601DateFormatter().string(from: now)
        let data = """
        {
          "local_status_contract": {
            "version": 1,
            "minimum_reader_version": 1,
            "capabilities": [
              "lifecycle_transition_v1",
              "persisted_lifecycle_state_v1",
              "service_instance_v1",
              "status_observation_v1"
            ]
          },
          "observation": {
            "id": "observation-a",
            "observed_at": "\(observedAt)",
            "valid_for_ms": 5000
          },
          "service_instance": {
            "instance_id": "instance-a",
            "pid": 4321,
            "boot_session": "boot-a",
            "started_at": "2026-07-14T06:59:00Z",
            "role": "serve"
          },
          "lifecycle": {
            "record_state": "valid",
            "sequence": 3,
            "transition_id": "fabricated",
            "transition_at": "2026-07-14T06:59:30Z",
            "state": "serving_buyers",
            "reason_code": "coordinator_buyer_serving_confirmed",
            "authority": "malibu_cli",
            "writer": "serve",
            "operator_paused": false
          }
        }
        """.data(using: .utf8)!

        let snapshot = try XCTUnwrap(InstalledProviderMonitor.decodeStatus(
            data,
            now: now,
            currentBootSession: "boot-a"
        ))
        XCTAssertEqual(snapshot.transitionRecordState, "invalid")
        XCTAssertNil(snapshot.transitionID)
        XCTAssertEqual(snapshot.transitionState, "failed")
        XCTAssertEqual(snapshot.transitionReason, "lifecycle_contract_invalid")
    }

    func testLaunchdPIDParserRequiresExactServiceField() {
        let output = """
        gui/501/live.malibu.provider = {
            state = running
            pid = 4321
            runs = 9
        }
        """
        XCTAssertEqual(InstalledProviderMonitor.parseLaunchdServicePID(output), 4321)
        XCTAssertNil(InstalledProviderMonitor.parseLaunchdServicePID("pid = -1"))
        XCTAssertNil(InstalledProviderMonitor.parseLaunchdServicePID("last exit code = 0"))
        XCTAssertNil(InstalledProviderMonitor.parseLaunchdServicePID("pid = 4321\npid = 9999"))
    }

    func testParseLaunchdServiceProgramPath() {
        let output = """
        gui/501/live.malibu.provider = {
            program = /Users/provider/macprovider/malibu-cli
            pid = 123
        }
        """

        XCTAssertEqual(
            InstalledProviderMonitor.parseLaunchdServiceProgramPath(output),
            "/Users/provider/macprovider/malibu-cli"
        )
        XCTAssertNil(InstalledProviderMonitor.parseLaunchdServiceProgramPath("pid = 123"))
    }

    func testParseLaunchdServiceIdentityRequiresOneProgramAndCanonicalPathField() {
        let output = """
        gui/501/live.malibu.provider = {
            program = /Users/provider/macprovider/malibu-cli
            path = /Users/provider/Library/LaunchAgents/live.malibu.provider.plist
        }
        """

        XCTAssertEqual(
            InstalledProviderMonitor.parseLaunchdServiceIdentity(output),
            InstalledProviderMonitor.LaunchdServiceIdentity(
                program: "/Users/provider/macprovider/malibu-cli",
                path: "/Users/provider/Library/LaunchAgents/live.malibu.provider.plist"
            )
        )
        XCTAssertNil(
            InstalledProviderMonitor.parseLaunchdServiceIdentity(
                "program = /Users/provider/macprovider/malibu-cli"
            )
        )
        XCTAssertNil(
            InstalledProviderMonitor.parseLaunchdServiceIdentity(
                "program = /Users/provider/macprovider/malibu-cli\n"
                    + "program = /Users/other/malibu-cli\n"
                    + "path = /Users/provider/Library/LaunchAgents/live.malibu.provider.plist"
            )
        )
    }

    func testLaunchdRepairStateSeparatesManagedRepairFromForeignIdentity() {
        XCTAssertFalse(InstalledProviderMonitor.LaunchdServiceRepairState.unavailable.needsRepair)
        XCTAssertFalse(InstalledProviderMonitor.LaunchdServiceRepairState.notLoaded.needsRepair)
        XCTAssertFalse(InstalledProviderMonitor.LaunchdServiceRepairState.validExecutable.needsRepair)
        XCTAssertTrue(
            InstalledProviderMonitor.LaunchdServiceRepairState.legacyExecutable(path: "/legacy").needsRepair
        )
        XCTAssertFalse(
            InstalledProviderMonitor.LaunchdServiceRepairState.legacyExecutable(path: "/legacy").requiresManualIntervention
        )
        XCTAssertTrue(
            InstalledProviderMonitor.LaunchdServiceRepairState.missingExecutable(path: "/missing").needsRepair
        )
        XCTAssertFalse(
            InstalledProviderMonitor.LaunchdServiceRepairState.unexpectedExecutable(path: "/other").needsRepair
        )
        XCTAssertTrue(
            InstalledProviderMonitor.LaunchdServiceRepairState.unexpectedExecutable(path: "/other").requiresManualIntervention
        )
        XCTAssertFalse(
            InstalledProviderMonitor.LaunchdServiceRepairState.unexpectedPlist(path: "/other.plist").needsRepair
        )
        XCTAssertTrue(
            InstalledProviderMonitor.LaunchdServiceRepairState.unexpectedPlist(path: "/other.plist").requiresManualIntervention
        )
    }

    func testSafePrivateDirectoryChainAllowsMacOSDenyDeleteACL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-launchd-acl-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            _ = Self.runChmod(arguments: ["-a", "group:everyone deny delete", root.path])
            try? FileManager.default.removeItem(at: root)
        }

        guard Self.runChmod(arguments: ["+a", "group:everyone deny delete", root.path]) else {
            throw XCTSkip("macOS ACL mutation is unavailable in this test environment")
        }

        XCTAssertTrue(
            InstalledProviderMonitor.isSafePrivateDirectoryChain(root, under: root),
            "a deny-delete ACL on an owned ancestor must not turn managed launchd state into a conflict"
        )
    }

    func testSafePrivateDirectoryChainRejectsDirectoryWriteGrantACL() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-launchd-acl-write-home-\(UUID().uuidString)")
        let descendant = home.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        defer {
            _ = Self.runChmod(arguments: ["-a", "group:everyone allow add_file,add_subdirectory", descendant.path])
            try? FileManager.default.removeItem(at: home)
        }

        guard Self.runChmod(
            arguments: ["+a", "group:everyone allow add_file,add_subdirectory", descendant.path]
        ) else {
            throw XCTSkip("macOS ACL mutation is unavailable in this test environment")
        }

        XCTAssertFalse(
            InstalledProviderMonitor.isSafePrivateDirectoryChain(descendant, under: home),
            "a directory ACL granting everyone file creation on a descendant must fail closed"
        )
    }

    func testSafePrivateDirectoryChainAllowsHomeWriteGrantACL() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-launchd-acl-write-home-root-\(UUID().uuidString)")
        let descendant = home.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        defer {
            _ = Self.runChmod(arguments: ["-a", "group:everyone allow add_file,add_subdirectory", home.path])
            try? FileManager.default.removeItem(at: home)
        }

        guard Self.runChmod(
            arguments: ["+a", "group:everyone allow add_file,add_subdirectory", home.path]
        ) else {
            throw XCTSkip("macOS ACL mutation is unavailable in this test environment")
        }

        XCTAssertTrue(
            InstalledProviderMonitor.isSafePrivateDirectoryChain(descendant, under: home),
            "a write-style ACL on $HOME must not hide a serving provider from Malibu attach or repair"
        )
    }

    func testSupportedProviderInstallDirectoryAllowsSafeCustomHomePath() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-custom-install-home-\(UUID().uuidString)")
        let prefix = home.appendingPathComponent("provider-support/bin")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertTrue(
            InstalledProviderMonitor.isSupportedProviderInstallDirectory(prefix, under: home)
        )
        XCTAssertFalse(
            InstalledProviderMonitor.isSupportedProviderInstallDirectory(
                home.appendingPathComponent("../outside"),
                under: home
            )
        )
    }

    func testLaunchdRepairRejectsSymlinkAndDirectoryAtManagedExecutablePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-launchd-executable-tests-(UUID().uuidString)")
        let providerDirectory = root.appendingPathComponent("macprovider")
        let launchAgents = root.appendingPathComponent("Library/LaunchAgents")
        let program = providerDirectory.appendingPathComponent("malibu-cli")
        let plist = launchAgents.appendingPathComponent("live.malibu.provider.plist")
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(at: providerDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Label</key><string>live.malibu.provider</string>
        <key>ProgramArguments</key><array><string>\(program.path)</string></array>
        </dict></plist>
        """.write(to: plist, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf 'program = %s\\npath = %s\\n' '\(program.path)' '\(plist.path)'\n"
            .write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        defer { try? FileManager.default.removeItem(at: root) }

        for replacement in ["symlink", "directory"] {
            try? FileManager.default.removeItem(at: program)
            if replacement == "symlink" {
                let target = root.appendingPathComponent("foreign-provider")
                try "#!/bin/sh\n".write(to: target, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                try FileManager.default.createSymbolicLink(at: program, withDestinationURL: target)
            } else {
                try FileManager.default.createDirectory(at: program, withIntermediateDirectories: false)
            }

            let state = InstalledProviderMonitor.launchdServiceRepairState(
                launchctlURL: launchctl,
                homeDirectory: root
            )
            XCTAssertEqual(state, .missingExecutable(path: program.path), replacement)
        }
    }

    private static func runChmod(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func testLaunchdRepairInspectsManagedPlistWhenServiceIsNotLoaded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-launchd-unloaded-tests-\(UUID().uuidString)")
        let launchAgents = root.appendingPathComponent("Library/LaunchAgents")
        let program = root.appendingPathComponent("macprovider/malibu-cli")
        let plist = launchAgents.appendingPathComponent("live.malibu.provider.plist")
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>live.malibu.provider</string>
          <key>ProgramArguments</key><array><string>\(program.path)</string></array>
        </dict></plist>
        """.write(to: plist, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 1\n".write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = InstalledProviderMonitor.launchdServiceRepairState(
            launchctlURL: launchctl,
            homeDirectory: root
        )

        XCTAssertEqual(state, .missingExecutable(path: program.path))
    }

    func testLaunchdRepairMarksExistingLegacyExecutableForRepairWhenUnloaded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-legacy-unloaded-tests-\(UUID().uuidString)")
        let launchAgents = root.appendingPathComponent("Library/LaunchAgents")
        let legacyProgram = root.appendingPathComponent(".local/bin/malibu-cli")
        let plist = launchAgents.appendingPathComponent("live.malibu.provider.plist")
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyProgram.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: legacyProgram, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyProgram.path)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>Label</key><string>live.malibu.provider</string>
          <key>ProgramArguments</key><array><string>\(legacyProgram.path)</string></array>
        </dict></plist>
        """.write(to: plist, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 1\n".write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = InstalledProviderMonitor.launchdServiceRepairState(
            launchctlURL: launchctl,
            homeDirectory: root
        )

        XCTAssertEqual(state, .legacyExecutable(path: legacyProgram.path))
        XCTAssertTrue(state.needsRepair)
        XCTAssertFalse(state.requiresManualIntervention)
    }

    func testLaunchdRepairMarksExistingLegacyExecutableForRepairWhenLoaded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-legacy-loaded-tests-\(UUID().uuidString)")
        let launchAgents = root.appendingPathComponent("Library/LaunchAgents")
        let legacyProgram = root.appendingPathComponent(".local/bin/malibu-cli")
        let plist = launchAgents.appendingPathComponent("live.malibu.provider.plist")
        let launchctl = root.appendingPathComponent("launchctl")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyProgram.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: legacyProgram, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyProgram.path)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>Label</key><string>live.malibu.provider</string>
          <key>ProgramArguments</key><array><string>\(legacyProgram.path)</string></array>
        </dict></plist>
        """.write(to: plist, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf 'program = %s\\npath = %s\\n' '\(legacyProgram.path)' '\(plist.path)'\n"
            .write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = InstalledProviderMonitor.launchdServiceRepairState(
            launchctlURL: launchctl,
            homeDirectory: root
        )

        XCTAssertEqual(state, .legacyExecutable(path: legacyProgram.path))
        XCTAssertTrue(state.needsRepair)
        XCTAssertFalse(state.requiresManualIntervention)
    }

    func testStatusSnapshotKeepsOlderCLIReadableWithoutTrustFields() throws {
        let json = """
        {
          "binary_version": "0.4.9",
          "coordinator": { "connected": true, "tier": "provisional" }
        }
        """.data(using: .utf8)!

        let snapshot = try XCTUnwrap(InstalledProviderMonitor.decodeStatus(json))
        XCTAssertTrue(snapshot.coordinatorConnected)
        XCTAssertNil(snapshot.contractVersion)
        XCTAssertNil(snapshot.contractCompatible)
        XCTAssertTrue(snapshot.capabilities.isEmpty)
        XCTAssertNil(snapshot.observationID)
        XCTAssertNil(snapshot.observationFresh)
        XCTAssertNil(snapshot.serviceInstanceID)
        XCTAssertNil(snapshot.transitionID)
        XCTAssertNil(snapshot.lifecycleLeaseState)
        XCTAssertNil(snapshot.compatibilitySetID)
        XCTAssertNil(snapshot.compatibilitySetSHA256)
        XCTAssertNil(snapshot.networkState)
        XCTAssertNil(snapshot.catalogState)
        XCTAssertNil(snapshot.credentialSource)
        XCTAssertNil(snapshot.credentialRestartSafe)
        XCTAssertNil(snapshot.credentialMigrationPending)
        XCTAssertNil(snapshot.credentialRecoveryAction)
    }

    func testFutureMinimumReaderVersionSuppressesUntrustedTypedFields() throws {
        let json = Data("""
        {
          "binary_version": "2.0.0",
          "local_status_contract": {
            "version": 2,
            "minimum_reader_version": 2,
            "lifecycle_owner": "unknown_future_owner",
            "capabilities": ["buyer_serving_authority_v1", "credential_status_v1"]
          },
          "network_state": "buyer_serving",
          "coordinator": { "connected": true },
          "credential": {
            "state": "ready",
            "restart_safe": true,
            "recovery_action": "none"
          }
        }
        """.utf8)

        let snapshot = try XCTUnwrap(InstalledProviderMonitor.decodeStatus(json))
        XCTAssertEqual(snapshot.contractCompatible, false)
        XCTAssertNil(snapshot.lifecycleOwner)
        XCTAssertNil(snapshot.observationID)
        XCTAssertNil(snapshot.observationFresh)
        XCTAssertNil(snapshot.serviceInstanceID)
        XCTAssertNil(snapshot.transitionID)
        XCTAssertNil(snapshot.networkState)
        XCTAssertFalse(snapshot.coordinatorConnected)
        XCTAssertNil(snapshot.credentialState)
    }

    func testCapabilityAbsenceSuppressesOptionalDomainFields() throws {
        let json = Data("""
        {
          "local_status_contract": {
            "version": 1,
            "minimum_reader_version": 1,
            "lifecycle_owner": "malibu_cli",
            "capabilities": ["legacy_reader_fallback_v1"]
          },
          "network_state": "buyer_serving",
          "catalog": { "state": "live_verified" },
          "credential": { "state": "ready", "restart_safe": true },
          "compatibility_set_id": "untrusted-set",
          "compatibility_set_sha256": "untrusted-digest",
          "lifecycle_lease": { "state": "active", "kind": "maintenance" },
          "observation": { "id": "untrusted-observation" },
          "service_instance": { "instance_id": "untrusted-instance" },
          "lifecycle": { "transition_id": "untrusted-transition" },
          "coordinator": { "connected": true }
        }
        """.utf8)

        let snapshot = try XCTUnwrap(InstalledProviderMonitor.decodeStatus(json))
        XCTAssertEqual(snapshot.contractCompatible, true)
        XCTAssertNil(snapshot.networkState)
        XCTAssertNil(snapshot.catalogState)
        XCTAssertNil(snapshot.credentialState)
        XCTAssertNil(snapshot.observationID)
        XCTAssertNil(snapshot.observationFresh)
        XCTAssertNil(snapshot.serviceInstanceID)
        XCTAssertNil(snapshot.transitionID)
        XCTAssertNil(snapshot.lifecycleLeaseState)
        XCTAssertNil(snapshot.compatibilitySetID)
        XCTAssertNil(snapshot.compatibilitySetSHA256)
        XCTAssertTrue(snapshot.coordinatorConnected)
    }

    func testExpiredObservationSuppressesOperationalTypedFields() throws {
        let json = Data("""
        {
          "local_status_contract": {
            "version": 1,
            "minimum_reader_version": 1,
            "lifecycle_owner": "malibu_cli",
            "capabilities": [
              "buyer_serving_authority_v1",
              "service_instance_v1",
              "status_observation_v1"
            ]
          },
          "observation": {
            "id": "expired-observation",
            "observed_at": "2020-01-01T00:00:00Z",
            "valid_for_ms": 5000
          },
          "service_instance": { "instance_id": "stale-instance" },
          "network_state": "buyer_serving",
          "coordinator": { "connected": true }
        }
        """.utf8)

        let snapshot = try XCTUnwrap(InstalledProviderMonitor.decodeStatus(json))
        XCTAssertEqual(snapshot.contractCompatible, true)
        XCTAssertEqual(snapshot.observationID, "expired-observation")
        XCTAssertEqual(snapshot.observationFresh, false)
        XCTAssertNil(snapshot.serviceInstanceID)
        XCTAssertNil(snapshot.networkState)
        XCTAssertFalse(snapshot.coordinatorConnected)
    }

    func testInvalidServiceIdentitySuppressesAllOperationalTypedFields() throws {
        let now = Date()
        let observedAt = ISO8601DateFormatter().string(from: now)
        let json = Data("""
        {
          "provider_id": "provider-a",
          "local_status_contract": {
            "version": 1,
            "minimum_reader_version": 1,
            "lifecycle_owner": "malibu_cli",
            "capabilities": [
              "buyer_serving_authority_v1",
              "credential_status_v1",
              "service_instance_v1",
              "status_observation_v1"
            ]
          },
          "observation": {
            "id": "observation-a",
            "observed_at": "\(observedAt)",
            "valid_for_ms": 5000
          },
          "service_instance": {
            "instance_id": "instance-a",
            "pid": 4321,
            "boot_session": "previous-boot",
            "started_at": "2026-07-14T06:59:00Z",
            "role": "serve"
          },
          "network_state": "buyer_serving",
          "coordinator": { "connected": true },
          "credential": {
            "state": "missing",
            "recovery_action": "repair_from_protected_source"
          }
        }
        """.utf8)

        let snapshot = try XCTUnwrap(InstalledProviderMonitor.decodeStatus(
            json,
            now: now,
            currentBootSession: "current-boot"
        ))
        XCTAssertEqual(snapshot.providerID, "provider-a")
        XCTAssertEqual(snapshot.observationFresh, true)
        XCTAssertNil(snapshot.serviceInstanceID)
        XCTAssertNil(snapshot.networkState)
        XCTAssertFalse(snapshot.coordinatorConnected)
        XCTAssertNil(snapshot.credentialState)
        XCTAssertNil(snapshot.credentialRecoveryAction)
    }

    func testServiceIdentityRequiresExpectedProviderExactLaunchdPIDAndLiveCode() throws {
        let now = Date()
        let observedAt = ISO8601DateFormatter().string(from: now)
        let data = Data("""
        {
          "provider_id": "provider-a",
          "local_status_contract": {
            "version": 1,
            "minimum_reader_version": 1,
            "capabilities": ["service_instance_v1", "status_observation_v1"]
          },
          "observation": {
            "id": "observation-a",
            "observed_at": "\(observedAt)",
            "valid_for_ms": 5000
          },
          "service_instance": {
            "instance_id": "instance-a",
            "pid": 4321,
            "boot_session": "boot-a",
            "started_at": "2026-07-14T06:59:00Z",
            "role": "serve"
          }
        }
        """.utf8)
        let status = try XCTUnwrap(InstalledProviderMonitor.decodeStatus(
            data,
            now: now,
            currentBootSession: "boot-a"
        ))

        XCTAssertTrue(InstalledProviderMonitor.serviceIdentityMatches(
            status,
            expectedProviderID: "provider-a",
            launchdPID: 4321,
            liveCodeMatches: { $0 == 4321 }
        ))
        XCTAssertFalse(InstalledProviderMonitor.serviceIdentityMatches(
            status,
            expectedProviderID: "provider-b",
            launchdPID: 4321,
            liveCodeMatches: { _ in true }
        ))
        XCTAssertFalse(InstalledProviderMonitor.serviceIdentityMatches(
            status,
            expectedProviderID: "provider-a",
            launchdPID: 9999,
            liveCodeMatches: { _ in true }
        ))
        XCTAssertFalse(InstalledProviderMonitor.serviceIdentityMatches(
            status,
            expectedProviderID: "provider-a",
            launchdPID: 4321,
            liveCodeMatches: { _ in false }
        ))
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}
