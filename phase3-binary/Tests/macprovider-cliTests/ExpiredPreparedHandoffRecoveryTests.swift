import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ExpiredPreparedHandoffRecoveryTests: XCTestCase {
    func testStartupRecoversBeforeFenceExitsAndNextProcessAcquiresFreshLease() throws {
        let fixture = try Fixture()
        XCTAssertThrowsError(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { try fixture.markerStore.readPending() },
            inspectLifecycleLease: { fixture.leaseStore.inspect() },
            currentExecutableURL: fixture.binary,
            targetVersion: "1.8.119",
            lifecycleEnvironment: fixture.clock.environment,
            fenceReloadJobs: { XCTFail("expired authority must not fence reload helpers") }
        ))
        XCTAssertThrowsError(try ServeCommand.recoverAbandonedStartupHandoffBeforeFencing(
            recovery: fixture.recovery
        ))
        XCTAssertEqual(fixture.fenceCount, 1)
        XCTAssertEqual(try String(contentsOf: fixture.binary), "old")
        XCTAssertEqual(fixture.leaseStore.inspect(), .missing)
        let marker = try XCTUnwrap(try fixture.markerStore.readPending())
        XCTAssertEqual(marker.transactionState, .awaitingPreviousReadiness)

        // A fresh launchd process is running the restored version. Recovery no
        // longer rewrites bytes or loops; the previous-release fence and normal
        // startup lease acquisition both succeed without operator intervention.
        fixture.clock.pid = 3_333
        try ServeCommand.recoverAbandonedStartupHandoffBeforeFencing(recovery: fixture.recovery)
        XCTAssertFalse(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { try fixture.markerStore.readPending() },
            inspectLifecycleLease: { fixture.leaseStore.inspect() },
            currentExecutableURL: fixture.binary,
            targetVersion: "1.8.118",
            lifecycleEnvironment: fixture.clock.environment,
            fenceReloadJobs: { fixture.fenceCount += 1 }
        ))
        _ = try fixture.lifecycleStore.transition(
            to: .startingProvider, reasonCode: "launchd_service_started", writer: .serve,
            providerID: "provider-test", operationID: "serve:respawn"
        )
        let lease = try ServeCommand.acquireStartupLifecycleLease(
            store: fixture.leaseStore, operationID: "serve:respawn",
            providerID: "provider-test", duration: 60
        )
        XCTAssertNil(lease.startupHandoff)
        XCTAssertEqual(lease.kind, .startup)
        XCTAssertEqual(fixture.fenceCount, 2)
    }

    func testMarkerFreeIdentityRotationRemainsAdoptable() throws {
        let fixture = try Fixture()
        fixture.markerStore.clearPending()
        fixture.clock.wall -= 120_000
        fixture.clock.monotonic -= 120_000_000_000
        let before = try Data(contentsOf: fixture.leaseStore.url)
        try ServeCommand.recoverAbandonedStartupHandoffBeforeFencing(recovery: fixture.recovery)
        XCTAssertEqual(try Data(contentsOf: fixture.leaseStore.url), before)
        let adopted = try ServeCommand.acquireStartupLifecycleLease(
            store: fixture.leaseStore, operationID: fixture.operationID, providerID: "provider-test", duration: 60
        )
        XCTAssertEqual(adopted.startupHandoff?.state, .adopted)
        XCTAssertEqual(fixture.fenceCount, 0)
    }

    func testAdoptedHandoffSkipsAutomaticPreparedRecoveryAndKeepsManualEscape() throws {
        let fixture = try Fixture(adopted: true)
        let before = try fixture.snapshot()
        try ServeCommand.recoverAbandonedStartupHandoffBeforeFencing(recovery: fixture.recovery)
        XCTAssertEqual(try fixture.snapshot(), before)
        // The old adopted process is gone. Manual recovery retains the stale
        // adopted lease for the existing fresh-lease path after rollback.
        fixture.clock.pid = 3_333
        fixture.clock.adoptedOwnerDead = true
        guard case .recovered = fixture.recovery.recover() else { return XCTFail("manual adopted escape regressed") }
        XCTAssertEqual(try Data(contentsOf: fixture.leaseStore.url), before[1])
    }

    func testLegacyRollbackInterruptionBeforeAndAfterLeaseRetirementSelfHeals() throws {
        for retired in [false, true] {
            let fixture = try Fixture(restored: true, legacy: true)
            if retired {
                XCTAssertTrue(try fixture.leaseStore.clear(ifLeaseID: XCTUnwrap(fixture.record).leaseID))
            }
            XCTAssertThrowsError(try ServeCommand.recoverAbandonedStartupHandoffBeforeFencing(recovery: fixture.recovery))
            XCTAssertEqual(fixture.leaseStore.inspect(), .missing)
            XCTAssertNil(try fixture.markerStore.readPending())
            try ServeCommand.recoverAbandonedStartupHandoffBeforeFencing(recovery: fixture.recovery)
            XCTAssertFalse(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
                loadPending: { try fixture.markerStore.readPending() },
                inspectLifecycleLease: { fixture.leaseStore.inspect() },
                currentExecutableURL: fixture.binary, targetVersion: "1.8.118",
                lifecycleEnvironment: fixture.clock.environment, fenceReloadJobs: {}
            ))
        }
    }

    func testLifecycleOnlyRecoveryContinuesButAnyRestorationExits() throws {
        let fixture = try Fixture()
        XCTAssertNoThrow(try ServeCommand.exitAfterUpdateRollbackIfNeeded(nil))
        XCTAssertThrowsError(try ServeCommand.exitAfterUpdateRollbackIfNeeded(.restored(fixture.marker)))
        XCTAssertThrowsError(try ServeCommand.exitAfterUpdateRollbackIfNeeded(.restoredAwaitingReadiness(fixture.marker)))
    }

    func testRecoverCommandRetiresPreparedLeaseAndPreservesReadinessMarker() throws {
        let fixture = try Fixture()
        guard case .recovered(.restoredAwaitingReadiness, true) = fixture.recovery.recover() else {
            return XCTFail("expected successful abandoned handoff recovery")
        }
        XCTAssertEqual(fixture.leaseStore.inspect(), .missing)
        XCTAssertEqual(try fixture.markerStore.readPending()?.transactionState, .awaitingPreviousReadiness)
        XCTAssertEqual(try fixture.lifecycleStore.current()?.writer, .installer)
    }

    func testOperatorLifecycleSupersedesExpiredHandoffWithoutLosingPause() throws {
        for coordinator in [false, true] {
            for state in [ProviderLifecycleState.pausedByOperator, .servingBuyers, .degradedServing, .locallyReadyConnecting] {
                let fixture = try Fixture(coordinator: coordinator, operatorState: state)
                let superseding = try XCTUnwrap(try fixture.lifecycleStore.current())
                XCTAssertNotEqual(superseding.operationID, fixture.operationID)
                guard case .recovered(.restoredAwaitingReadiness, true) = fixture.recovery.recover() else {
                    return XCTFail("operator lifecycle must not strand expired handoff: \(state)")
                }
                XCTAssertEqual(try String(contentsOf: fixture.binary), "old")
                XCTAssertEqual(fixture.leaseStore.inspect(), .missing)
                XCTAssertEqual(fixture.fenceCount, 1)
                let translated = try XCTUnwrap(try fixture.lifecycleStore.current())
                XCTAssertEqual(translated.writer, .installer)
                XCTAssertEqual(translated.previousTransitionID, superseding.transitionID)
                XCTAssertEqual(translated.operatorPauseRequested, state == .pausedByOperator)

                // The restored process can pass preflight, acquire a fresh
                // startup lease, and complete the ordinary lifecycle chain.
                fixture.clock.pid = 3_333
                try ServeCommand.recoverAbandonedStartupHandoffBeforeFencing(recovery: fixture.recovery)
                XCTAssertFalse(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
                    loadPending: { try fixture.markerStore.readPending() },
                    inspectLifecycleLease: { fixture.leaseStore.inspect() },
                    currentExecutableURL: fixture.binary, targetVersion: "1.8.118",
                    lifecycleEnvironment: fixture.clock.environment, fenceReloadJobs: {}
                ))
                let startup = "serve:after-operator-recovery"
                _ = try fixture.lifecycleStore.transition(
                    to: .startingProvider, reasonCode: "launchd_service_started", writer: .serve,
                    providerID: "provider-test", operationID: startup
                )
                _ = try ServeCommand.acquireStartupLifecycleLease(
                    store: fixture.leaseStore, operationID: startup, providerID: "provider-test", duration: 60
                )
                for next in [ProviderLifecycleState.importingCredentials, .validatingCatalog, .loadingModel, .locallyReadyConnecting] {
                    _ = try fixture.lifecycleStore.transition(
                        to: next, reasonCode: "startup_test", writer: .serve,
                        providerID: "provider-test", operationID: startup
                    )
                }
                let ready = try fixture.lifecycleStore.transition(
                    to: state == .pausedByOperator ? .pausedByOperator : .servingBuyers,
                    reasonCode: "startup_ready", writer: state == .pausedByOperator ? .operatorCommand : .serve,
                    providerID: "provider-test", operationID: startup
                )
                XCTAssertEqual(ready.operatorPauseRequested, state == .pausedByOperator)
                XCTAssertEqual(ready.state, state == .pausedByOperator ? .pausedByOperator : .servingBuyers)
            }
        }
    }

    func testOperatorSupersessionDoesNotBypassDeadlinesOrLiveOwner() throws {
        for mode in ["owner", "deadline", "handoff"] {
            let fixture = try Fixture(futureDeadline: mode == "deadline", operatorState: .pausedByOperator)
            if mode == "owner" { fixture.clock.oldOwnerLive = true }
            if mode == "handoff" { fixture.clock.wall -= 120_000; fixture.clock.monotonic -= 120_000_000_000 }
            let before = try fixture.snapshot()
            switch fixture.recovery.recover() {
            case .recoveryRefused, .transactionActive: break
            default: XCTFail("operator command must not bypass \(mode)")
            }
            XCTAssertEqual(try fixture.snapshot(), before)
            XCTAssertEqual(fixture.fenceCount, 0)
        }
    }

    func testRecoveryOutputExplainsFencingEnableAndPause() {
        let message = RecoverUpdateCommand.recoveryMessage(markerRecovered: true)
        for expected in ["fenced", "launchctl enable", "launchctl bootstrap", "launchctl kickstart", "live.malibu.provider", "operator pause flag is preserved"] {
            XCTAssertTrue(message.contains(expected), expected)
        }
        XCTAssertFalse(RecoverUpdateCommand.recoveryMessage(markerRecovered: false).contains("were fenced"))
    }

    func testPreviouslyTranslatedRollbackAndFailedServeRemainRecoverable() throws {
        for failedServe in [false, true] {
            let fixture = try Fixture(restored: true)
            _ = try fixture.lifecycleStore.transition(
                to: .rollbackInProgress,
                reasonCode: WedgedUpdateRecovery.translationReasonCode, writer: .installer,
                providerID: "provider-test", operationID: "install-rollback:1234"
            )
            if failedServe {
                _ = try fixture.lifecycleStore.transition(
                    to: .startingProvider, reasonCode: "maintenance_handoff_restart", writer: .serve,
                    providerID: "provider-test", operationID: fixture.operationID
                )
            }
            guard case .recovered = fixture.recovery.recover() else {
                return XCTFail("old recover-update / failed serve must not strand prepared authority")
            }
            XCTAssertEqual(fixture.leaseStore.inspect(), .missing)
        }
    }

    func testHistoricalSelfUpdateWithoutLifecycleProviderUsesConfiguredProvider() throws {
        let fixture = try Fixture()
        _ = try fixture.lifecycleStore.transition(
            to: .updateInProgress, reasonCode: "signed_compatibility_set_validated", writer: .updater,
            compatibilitySetID: Fixture.targetSet, operationID: fixture.operationID
        )
        guard case .recovered = fixture.recovery.recover() else {
            return XCTFail("historical writer omitted provider ID; exact configured identity is required")
        }
    }

    func testLiveOwnerFutureTransactionAndUnexpiredHandoffAreUntouched() throws {
        for mode in ["owner", "deadline", "handoff", "mutation-lock"] {
            let fixture = try Fixture(futureDeadline: mode == "deadline")
            if mode == "owner" { fixture.clock.oldOwnerLive = true }
            if mode == "handoff" { fixture.clock.wall -= 120_000; fixture.clock.monotonic -= 120_000_000_000 }
            let heldLock = mode == "mutation-lock" ? try fixture.markerStore.acquireRecoveryLock() : nil
            defer { withExtendedLifetime(heldLock) {} }
            let before = try fixture.snapshot()
            switch fixture.recovery.recover() {
            case .recoveryRefused, .transactionActive, .ownerLive: break
            default: XCTFail("must refuse \(mode)")
            }
            XCTAssertEqual(try fixture.snapshot(), before, mode)
            XCTAssertEqual(fixture.fenceCount, 0)
        }
    }

    func testMalformedMismatchedAndAdoptedAuthorityCannotBeRetired() throws {
        for operatorSuperseded in [false, true] {
            for mode in ["operation", "provider", "service", "target", "digest", "corrupt", "unsafe", "marker", "commit-owner", "compatibility"] {
                let fixture = try Fixture(operatorState: operatorSuperseded ? .pausedByOperator : nil)
                if mode == "corrupt" {
                    try Data("{".utf8).write(to: fixture.leaseStore.url)
                } else if mode == "unsafe" {
                    XCTAssertEqual(chmod(fixture.leaseStore.url.path, 0o644), 0)
                } else if mode == "marker" {
                    try Data("{".utf8).write(to: fixture.markerStore.pendingURL)
                } else if mode == "commit-owner" || mode == "compatibility" {
                    var markerJSON = try XCTUnwrap(JSONSerialization.jsonObject(
                        with: Data(contentsOf: fixture.markerStore.pendingURL)
                    ) as? [String: Any])
                    markerJSON[mode == "commit-owner" ? "commit_owner" : "target_compatibility_set_id"] = "different"
                    try JSONSerialization.data(withJSONObject: markerJSON).write(to: fixture.markerStore.pendingURL)
                } else {
                    var json = try XCTUnwrap(JSONSerialization.jsonObject(
                        with: Data(contentsOf: fixture.leaseStore.url)
                    ) as? [String: Any])
                    var handoff = try XCTUnwrap(json["startup_handoff"] as? [String: Any])
                    switch mode {
                    case "operation":
                        json["operation_id"] = "self-update:different"
                        if !operatorSuperseded { handoff["operation_id"] = "self-update:different" }
                    case "provider": handoff["provider_id"] = "different-provider"
                    case "service": handoff["service_identity"] = "other.service"
                    case "target": handoff["target_executable_path"] = "/tmp/different-cli"
                    case "digest": handoff["target_executable_sha256"] = String(repeating: "f", count: 64)
                    default: break
                    }
                    json["startup_handoff"] = handoff
                    try JSONSerialization.data(withJSONObject: json).write(to: fixture.leaseStore.url)
                }
                let before = try fixture.snapshot()
                guard case .recoveryRefused = fixture.recovery.recover() else {
                    return XCTFail("must refuse \(mode)")
                }
                XCTAssertEqual(try fixture.snapshot(), before, mode)
                XCTAssertEqual(fixture.fenceCount, 0)
            }
        }
    }

    func testHelperFenceFailureAndCorruptBackupKeepLeaseMarkerAndBytes() throws {
        for corruptBackup in [false, true] {
            let fixture = try Fixture()
            if corruptBackup {
                try Data("bad".utf8).write(to: URL(fileURLWithPath: fixture.marker.backupPath))
            }
            var recovery = fixture.recovery
            recovery.fenceReloadJobs = { throw CocoaError(.fileReadNoPermission) }
            let before = try fixture.snapshot()
            guard case .recoveryRefused = recovery.recover() else { return XCTFail("must refuse") }
            XCTAssertEqual(try fixture.snapshot(), before)
        }
    }

    func testDisallowedPreviousVersionRetainsAllRecoveryState() async throws {
        let fixture = try Fixture()
        try await fixture.markerStore.updateSignedPolicy(minimum: "1.8.119", revoked: [])
        let before = try fixture.snapshot()
        guard case .recoveryRefused = fixture.recovery.recover() else { return XCTFail("must refuse revoked rollback") }
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertEqual(fixture.fenceCount, 0)
    }

    func testLeaseCompareAndSwapRefusesReplacementBeforeRecoveryCallback() throws {
        let fixture = try Fixture()
        let previous = try XCTUnwrap(fixture.record)
        XCTAssertTrue(try fixture.leaseStore.clear(ifLeaseID: previous.leaseID))
        let replacement = try fixture.leaseStore.acquire(kind: .startup, operationID: "other-operation", duration: 60)
        XCTAssertThrowsError(try fixture.leaseStore.retireExpiredPreparedStartupHandoff(matching: previous) {
            XCTFail("must not mutate transaction after lease replacement")
        })
        XCTAssertEqual(fixture.leaseStore.inspect(), .valid(replacement))
    }

    private final class Fixture {
        static let targetSet = "Augustas11/macprovider:v1.8.119@" + String(repeating: "a", count: 40)
        let home: URL
        let binary: URL
        let clock: Clock
        let markerStore: AutoUpdateMarkerStore
        let lifecycleStore: ProviderLifecycleStateStore
        let leaseStore: ProviderLifecycleLeaseStore
        let marker: AutoUpdatePendingMarker
        let operationID: String
        var record: ProviderLifecycleLeaseRecord?
        var fenceCount = 0

        init(restored: Bool = false, futureDeadline: Bool = false, adopted: Bool = false, legacy: Bool = false, coordinator: Bool = false, operatorState: ProviderLifecycleState? = nil) throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("expired-handoff-\(UUID())")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let bin = home.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            binary = bin.appendingPathComponent("macprovider-cli")
            try Data("new".utf8).write(to: binary)
            clock = Clock(binary: binary)
            markerStore = AutoUpdateMarkerStore(homeDirectory: home, malibuAppCandidateOverride: [])
            try markerStore.ensureTrustedRoot()
            lifecycleStore = ProviderLifecycleStateStore(url: home.appendingPathComponent("lifecycle/state-v1.json"))
            leaseStore = ProviderLifecycleLeaseStore(url: home.appendingPathComponent("lifecycle/lease.json"), environment: clock.environment)
            let updateID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            operationID = coordinator ? "autoupdate:\(updateID)" : "self-update:bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
            let backup = markerStore.rollbackBackupPath(binaryURL: binary, updateID: updateID)
            try Data("old".utf8).write(to: backup)
            let release = markerStore.releaseRollbackBackupPath(binaryURL: binary, updateID: updateID)
            try FileManager.default.createDirectory(at: release, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            marker = AutoUpdatePendingMarker(
                updateID: updateID, targetVersion: "1.8.119", targetPath: binary.path,
                backupPath: backup.path, size: 3, mode: 0o755,
                sha256: AutoUpdateEvent.sha256Hex("old"),
                markerDeadline: ISO8601DateFormatter().string(from: Date().addingTimeInterval(futureDeadline ? 300 : -60)),
                releaseBackupPath: release.path, releaseBackupSHA256: AutoUpdateEvent.sha256Hex(""),
                commitOwner: coordinator ? "coordinator" : "self_update", targetCompatibilitySetID: legacy ? nil : Self.targetSet,
                targetCompatibilitySetSHA256: legacy ? nil : String(repeating: "a", count: 64),
                previousVersion: legacy ? nil : "1.8.118", previousCompatibilitySetID: legacy ? nil : "Augustas11/macprovider:v1.8.118@" + String(repeating: "b", count: 40),
                previousCompatibilitySetSHA256: legacy ? nil : String(repeating: "b", count: 64),
                transactionState: legacy ? nil : (restored ? .awaitingPreviousReadiness : .activatingTarget)
            )
            try markerStore.writePending(marker)
            _ = try lifecycleStore.transition(
                to: .updateInProgress, reasonCode: "signed_compatibility_set_validated", writer: .updater,
                providerID: "provider-test", compatibilitySetID: legacy ? nil : Self.targetSet, operationID: operationID
            )
            let maintenance = try leaseStore.acquire(kind: .maintenance, operationID: operationID, duration: 600)
            record = try leaseStore.prepareStartupHandoff(
                maintenanceLeaseID: maintenance.leaseID, operationID: operationID,
                providerID: "provider-test", serviceIdentity: ServeCommand.providerLaunchdServiceIdentity,
                targetExecutablePath: binary.path, targetExecutableSHA256: AutoUpdateEvent.sha256Hex("new"),
                handoffDuration: 60, startupLeaseDuration: 120
            )
            clock.pid = 2_222
            clock.oldOwnerLive = false
            if adopted {
                record = try leaseStore.adoptStartupHandoff(
                    operationID: operationID, providerID: "provider-test", serviceIdentity: ServeCommand.providerLaunchdServiceIdentity
                )
            }
            if let operatorState {
                // An operator can overwrite the lifecycle while update startup
                // authority remains prepared. Pause uses a valid predecessor.
                _ = try lifecycleStore.transition(
                    to: .servingBuyers, reasonCode: "operator_resume_confirmed", writer: .operatorCommand,
                    providerID: "provider-test", compatibilitySetID: Self.targetSet,
                    operationID: "operator-resume:test", operatorPaused: false
                )
                if operatorState != .servingBuyers {
                    _ = try lifecycleStore.transition(
                        to: operatorState, reasonCode: "operator_command_confirmed", writer: .operatorCommand,
                        providerID: "provider-test", compatibilitySetID: Self.targetSet,
                        operationID: "operator-pause:test", operatorPaused: operatorState == .pausedByOperator
                    )
                }
            }
            clock.wall += 120_000
            clock.monotonic += 120_000_000_000
            if restored { try Data("old".utf8).write(to: binary) }
        }

        var recovery: WedgedUpdateRecovery {
            WedgedUpdateRecovery(
                markerStore: markerStore, lifecycleStore: lifecycleStore,
                leaseStore: leaseStore, fenceReloadJobs: { self.fenceCount += 1 }, expectedProviderID: "provider-test"
            )
        }

        func snapshot() throws -> [Data] {
            try [binary, leaseStore.url, lifecycleStore.url, markerStore.pendingURL].map { try Data(contentsOf: $0) }
        }

        deinit { try? FileManager.default.removeItem(at: home) }
    }

    private final class Clock: @unchecked Sendable {
        let binary: URL
        var wall = Int64(Date().addingTimeInterval(-120).timeIntervalSince1970 * 1_000)
        var monotonic: Int64 = 1_000_000_000
        var pid: Int32 = 1_111
        var oldOwnerLive = true
        var adoptedOwnerDead = false

        init(binary: URL) { self.binary = binary }

        var environment: ProviderLifecycleLeaseEnvironment {
            ProviderLifecycleLeaseEnvironment(
                wallMilliseconds: { self.wall }, monotonicNanoseconds: { self.monotonic },
                bootSession: { "boot-test" },
                processStartMicroseconds: { pid in (pid == 1_111 && !self.oldOwnerLive) || (pid == 2_222 && self.adoptedOwnerDead) ? nil : Int64(pid) * 1_000 },
                processID: { self.pid }, launchdServiceProcessID: { _ in self.pid },
                executablePath: { _ in self.binary.path },
                executableSHA256: { _ in try? AutoUpdateMarkerStore.sha256(file: self.binary) }
            )
        }
    }
}
