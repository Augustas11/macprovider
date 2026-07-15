import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderLifecycleStateTests: XCTestCase {
    func testPersistsMonotonicRestartSafeTransitionChain() throws {
        let fixture = try Fixture()
        let firstStore = ProviderLifecycleStateStore(url: fixture.recordURL)
        let first = try firstStore.transition(
            to: .startingProvider,
            reasonCode: "serve_invoked",
            writer: .serve,
            providerID: "provider-1",
            modelID: "org/model",
            operationID: "serve:one",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let restartedStore = ProviderLifecycleStateStore(url: fixture.recordURL)
        _ = try restartedStore.transition(
            to: .importingCredentials,
            reasonCode: "resolving_cli_keychain_custody",
            writer: .serve,
            providerID: "provider-1",
            modelID: "org/model",
            operationID: "serve:one",
            now: Date(timeIntervalSince1970: 1_700_000_000.25)
        )
        _ = try restartedStore.transition(
            to: .validatingCatalog,
            reasonCode: "startup_preflight",
            writer: .serve,
            providerID: "provider-1",
            modelID: "org/model",
            operationID: "serve:one",
            now: Date(timeIntervalSince1970: 1_700_000_000.5)
        )
        let second = try restartedStore.transition(
            to: .loadingModel,
            reasonCode: "catalog_preflight_passed",
            writer: .serve,
            providerID: "provider-1",
            modelID: "org/model",
            compatibilitySetID: "macprovider:1.2.3@catalog:7",
            operationID: "serve:one",
            now: Date(timeIntervalSince1970: 1_700_000_001)
        )

        XCTAssertEqual(first.sequence, 1)
        XCTAssertNil(first.previousTransitionID)
        XCTAssertEqual(second.sequence, 4)
        XCTAssertNotEqual(second.previousTransitionID, first.transitionID)
        XCTAssertEqual(try restartedStore.current(), second)
        XCTAssertEqual(second.transitionDate, Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(second.lastRestart?.transitionID, first.transitionID)
        XCTAssertEqual(second.lastRestart?.reasonCode, "serve_invoked")
    }

    func testExactRetryReusesTransitionIDAndSequence() throws {
        let fixture = try Fixture()
        let store = ProviderLifecycleStateStore(url: fixture.recordURL)
        let first = try store.transition(
            to: .updateInProgress,
            reasonCode: "signed_compatibility_set_validated",
            writer: .updater,
            compatibilitySetID: "set-1",
            operationID: "update-1"
        )
        let replay = try store.transition(
            to: .updateInProgress,
            reasonCode: "signed_compatibility_set_validated",
            writer: .updater,
            compatibilitySetID: "set-1",
            operationID: "update-1"
        )

        XCTAssertEqual(replay, first)
        XCTAssertEqual(replay.sequence, 1)
    }

    func testNonJoiningStartupCanServeLocallyAfterModelLoad() throws {
        let fixture = try Fixture()
        let store = ProviderLifecycleStateStore(url: fixture.recordURL)
        _ = try store.transition(
            to: .startingProvider,
            reasonCode: "serve_invoked",
            writer: .serve,
            operationID: "serve:no-join"
        )
        _ = try store.transition(
            to: .importingCredentials,
            reasonCode: "resolving_cli_keychain_custody",
            writer: .serve,
            operationID: "serve:no-join"
        )
        _ = try store.transition(
            to: .validatingCatalog,
            reasonCode: "startup_preflight",
            writer: .serve,
            operationID: "serve:no-join"
        )
        let loading = try store.transition(
            to: .loadingModel,
            reasonCode: "catalog_preflight_passed",
            writer: .serve,
            operationID: "serve:no-join"
        )
        let locallyServing = try store.transition(
            to: .degradedServing,
            reasonCode: "local_http_ready_join_disabled",
            writer: .serve,
            operationID: "serve:no-join"
        )

        XCTAssertEqual(locallyServing.previousTransitionID, loading.transitionID)
        XCTAssertEqual(locallyServing.state, .degradedServing)
    }

    func testOperatorPauseIntentSurvivesIntermediateRestartStatesUntilExplicitResume() throws {
        let fixture = try Fixture()
        let store = ProviderLifecycleStateStore(url: fixture.recordURL)
        let paused = try store.transition(
            to: .pausedByOperator,
            reasonCode: "operator_pause_confirmed",
            writer: .operatorCommand,
            operationID: "pause-1",
            operatorPaused: true
        )
        let restarting = try store.transition(
            to: .startingProvider,
            reasonCode: "serve_invoked",
            writer: .serve,
            operationID: "serve-2"
        )
        _ = try store.transition(
            to: .importingCredentials,
            reasonCode: "resolving_cli_keychain_custody",
            writer: .serve,
            operationID: "serve-2"
        )
        _ = try store.transition(
            to: .validatingCatalog,
            reasonCode: "startup_preflight",
            writer: .serve,
            operationID: "serve-2"
        )
        _ = try store.transition(
            to: .loadingModel,
            reasonCode: "catalog_preflight_passed",
            writer: .serve,
            operationID: "serve-2"
        )
        let resumed = try store.transition(
            to: .locallyReadyConnecting,
            reasonCode: "operator_resume_requested",
            writer: .operatorCommand,
            operationID: "resume-1",
            operatorPaused: false
        )

        XCTAssertTrue(paused.operatorPauseRequested)
        XCTAssertTrue(restarting.operatorPauseRequested)
        XCTAssertFalse(resumed.operatorPauseRequested)
        XCTAssertEqual(restarting.previousTransitionID, paused.transitionID)
        XCTAssertNotEqual(resumed.previousTransitionID, restarting.transitionID)
    }

    func testPausedStartupCanRestorePauseAfterModelLoad() throws {
        let fixture = try Fixture()
        let store = ProviderLifecycleStateStore(url: fixture.recordURL)
        _ = try store.transition(
            to: .pausedByOperator,
            reasonCode: "operator_pause_confirmed",
            writer: .operatorCommand,
            operationID: "pause-1",
            operatorPaused: true
        )
        _ = try store.transition(
            to: .startingProvider,
            reasonCode: "serve_invoked",
            writer: .serve,
            operationID: "serve:paused"
        )
        _ = try store.transition(
            to: .importingCredentials,
            reasonCode: "resolving_cli_keychain_custody",
            writer: .serve,
            operationID: "serve:paused"
        )
        _ = try store.transition(
            to: .validatingCatalog,
            reasonCode: "startup_preflight",
            writer: .serve,
            operationID: "serve:paused"
        )
        let loading = try store.transition(
            to: .loadingModel,
            reasonCode: "catalog_preflight_passed",
            writer: .serve,
            operationID: "serve:paused"
        )
        let paused = try store.transition(
            to: .pausedByOperator,
            reasonCode: "operator_pause_restored_after_startup",
            writer: .operatorCommand,
            operationID: "serve:paused"
        )

        XCTAssertEqual(paused.previousTransitionID, loading.transitionID)
        XCTAssertTrue(paused.operatorPauseRequested)
        XCTAssertEqual(paused.writer, .operatorCommand)
    }

    func testChangedReasonCreatesLinkedTransition() throws {
        let fixture = try Fixture()
        let store = ProviderLifecycleStateStore(url: fixture.recordURL)
        let first = try store.transition(
            to: .locallyReadyConnecting,
            reasonCode: "local_http_ready_awaiting_coordinator",
            writer: .serve,
            operationID: "serve-1"
        )
        let second = try store.transition(
            to: .locallyReadyConnecting,
            reasonCode: "buyer_serving_readiness_unconfirmed",
            writer: .serve,
            operationID: "serve-1"
        )

        XCTAssertNotEqual(second.transitionID, first.transitionID)
        XCTAssertEqual(second.previousTransitionID, first.transitionID)
        XCTAssertEqual(second.sequence, 2)
    }

    func testSignificantReasonsSurviveReturnToServing() throws {
        let fixture = try Fixture()
        let store = ProviderLifecycleStateStore(url: fixture.recordURL)
        let update = try store.transition(
            to: .updateInProgress,
            reasonCode: "signed_compatibility_set_validated",
            writer: .updater,
            operationID: "self-update:one"
        )
        _ = try store.transition(
            to: .startingProvider,
            reasonCode: "maintenance_handoff_restart",
            writer: .serve,
            operationID: "self-update:one"
        )
        _ = try store.transition(
            to: .importingCredentials,
            reasonCode: "resolving_cli_keychain_custody",
            writer: .serve,
            operationID: "self-update:one"
        )
        _ = try store.transition(
            to: .validatingCatalog,
            reasonCode: "startup_preflight",
            writer: .serve,
            operationID: "self-update:one"
        )
        _ = try store.transition(
            to: .loadingModel,
            reasonCode: "catalog_preflight_passed",
            writer: .serve,
            operationID: "self-update:one"
        )
        _ = try store.transition(
            to: .locallyReadyConnecting,
            reasonCode: "coordinator_connecting",
            writer: .serve,
            operationID: "self-update:one"
        )
        let ready = try store.transition(
            to: .servingBuyers,
            reasonCode: "coordinator_buyer_serving_confirmed",
            writer: .serve,
            operationID: "self-update:one"
        )

        XCTAssertEqual(ready.lastUpdate?.transitionID, update.transitionID)
        XCTAssertEqual(ready.lastUpdate?.reasonCode, "signed_compatibility_set_validated")
        XCTAssertEqual(ready.lastRestart?.reasonCode, "maintenance_handoff_restart")
    }

    func testWriterOwnershipAndMaintenanceFenceRejectCausallyInvalidOverwrite() throws {
        let fixture = try Fixture()
        let store = ProviderLifecycleStateStore(url: fixture.recordURL)
        XCTAssertThrowsError(try store.transition(
            to: .startingProvider,
            reasonCode: "invalid_watchdog_start",
            writer: .watchdog,
            operationID: "watchdog:one"
        )) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleStateError,
                .writerNotAuthorized(writer: "watchdog", state: "starting_provider")
            )
        }

        _ = try store.transition(
            to: .updateInProgress,
            reasonCode: "signed_compatibility_set_validated",
            writer: .updater,
            operationID: "self-update:one"
        )
        XCTAssertThrowsError(try store.transition(
            to: .coordinatorUnavailable,
            reasonCode: "stale_serve_callback",
            writer: .serve,
            operationID: "serve:stale"
        )) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleStateError,
                .operationFenced(previousWriter: "updater", previousState: "update_in_progress")
            )
        }
    }

    func testNonJoiningStartupCanValidateCatalogFromEveryCredentialRecoveryState() throws {
        let credentialRecoveryStates: [ProviderLifecycleState] = [
            .authenticationRequired,
            .keychainUnavailable,
            .identityMigrationRequired,
        ]

        for credentialState in credentialRecoveryStates {
            let fixture = try Fixture()
            let store = ProviderLifecycleStateStore(url: fixture.recordURL)
            _ = try store.transition(
                to: .startingProvider,
                reasonCode: "serve_invoked",
                writer: .serve,
                operationID: "serve:\(credentialState.rawValue)"
            )
            _ = try store.transition(
                to: .importingCredentials,
                reasonCode: "resolving_cli_keychain_custody",
                writer: .serve,
                operationID: "serve:\(credentialState.rawValue)"
            )
            let recovery = try store.transition(
                to: credentialState,
                reasonCode: "credential_\(credentialState.rawValue)",
                writer: .serve,
                operationID: "serve:\(credentialState.rawValue)"
            )
            let validating = try store.transition(
                to: .validatingCatalog,
                reasonCode: "non_joining_startup_preflight",
                writer: .serve,
                operationID: "serve:\(credentialState.rawValue)"
            )

            XCTAssertEqual(recovery.state, credentialState)
            XCTAssertEqual(validating.previousTransitionID, recovery.transitionID)
        }
    }

    // MARK: - Decision Entry 158 pair-validation (v1.8.40 loading_model exits)

    /// Entry 158 legalizes `loading_model -> degraded_serving` ONLY for the
    /// serve writer. `operator_command` is separately authorized to enter
    /// `degraded_serving`, so before the (predecessor, target, writer) tuple
    /// check it could ride the new predecessor edge. It MUST be rejected.
    func testOperatorCommandCannotDegradeFromLoadingModel() throws {
        let fixture = try Fixture()
        let store = ProviderLifecycleStateStore(url: fixture.recordURL)
        try driveToLoadingModel(store, operationID: "serve:entry158-deg")

        XCTAssertThrowsError(try store.transition(
            to: .degradedServing,
            reasonCode: "operator_command_illegal_degrade",
            writer: .operatorCommand,
            operationID: "operator:entry158-deg"
        )) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleStateError,
                .invalidTransition(from: "loading_model", to: "degraded_serving")
            )
        }
    }

    /// Entry 158 legalizes `loading_model -> paused_by_operator` ONLY through
    /// the operator_command writer convention. `installer` is separately
    /// authorized to enter `paused_by_operator`, so it could otherwise ride the
    /// new predecessor edge. It MUST be rejected.
    func testInstallerCannotPauseFromLoadingModel() throws {
        let fixture = try Fixture()
        let store = ProviderLifecycleStateStore(url: fixture.recordURL)
        try driveToLoadingModel(store, operationID: "serve:entry158-pause")

        XCTAssertThrowsError(try store.transition(
            to: .pausedByOperator,
            reasonCode: "installer_illegal_pause",
            writer: .installer,
            operationID: "installer:entry158-pause"
        )) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleStateError,
                .invalidTransition(from: "loading_model", to: "paused_by_operator")
            )
        }
    }

    /// The Entry-158 legal combinations remain green: serve degrades and
    /// operator_command pauses directly from loading_model.
    func testEntry158LegalLoadingModelExitsRemainAllowed() throws {
        let degradeFixture = try Fixture()
        let degradeStore = ProviderLifecycleStateStore(url: degradeFixture.recordURL)
        let loadingBeforeDegrade = try driveToLoadingModel(degradeStore, operationID: "serve:entry158-ok-deg")
        let degraded = try degradeStore.transition(
            to: .degradedServing,
            reasonCode: "local_http_ready_join_disabled",
            writer: .serve,
            operationID: "serve:entry158-ok-deg"
        )
        XCTAssertEqual(degraded.previousTransitionID, loadingBeforeDegrade.transitionID)
        XCTAssertEqual(degraded.writer, .serve)

        let pauseFixture = try Fixture()
        let pauseStore = ProviderLifecycleStateStore(url: pauseFixture.recordURL)
        let loadingBeforePause = try driveToLoadingModel(pauseStore, operationID: "serve:entry158-ok-pause")
        let paused = try pauseStore.transition(
            to: .pausedByOperator,
            reasonCode: "operator_pause_restored_after_startup",
            writer: .operatorCommand,
            operationID: "serve:entry158-ok-pause"
        )
        XCTAssertEqual(paused.previousTransitionID, loadingBeforePause.transitionID)
        XCTAssertEqual(paused.writer, .operatorCommand)
    }

    @discardableResult
    private func driveToLoadingModel(
        _ store: ProviderLifecycleStateStore,
        operationID: String
    ) throws -> ProviderLifecycleStateRecord {
        _ = try store.transition(
            to: .startingProvider,
            reasonCode: "serve_invoked",
            writer: .serve,
            operationID: operationID
        )
        _ = try store.transition(
            to: .importingCredentials,
            reasonCode: "resolving_cli_keychain_custody",
            writer: .serve,
            operationID: operationID
        )
        _ = try store.transition(
            to: .validatingCatalog,
            reasonCode: "startup_preflight",
            writer: .serve,
            operationID: operationID
        )
        return try store.transition(
            to: .loadingModel,
            reasonCode: "catalog_preflight_passed",
            writer: .serve,
            operationID: operationID
        )
    }

    // MARK: - Candidate-scoped store routing (ARCHITECT finding)

    /// The candidate store MUST resolve to a distinct file
    /// (`candidate-state-v1.json`) in the SAME lifecycle directory as the
    /// incumbent's `state-v1.json`, so a candidate never overwrites the
    /// incumbent's Malibu-visible state. Injected home directory keeps this
    /// isolated from the live install (homeDirectoryForCurrentUser ignores
    /// $HOME, so we pass the directory explicitly).
    func testCandidateAndIncumbentStorePathsAreDistinctSiblings() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-home-\(UUID().uuidString)", isDirectory: true)
        let incumbentURL = ProviderLifecycleStateStore.defaultURL(homeDirectory: home)
        let candidateURL = ProviderLifecycleStateStore.candidateURL(homeDirectory: home)

        XCTAssertEqual(incumbentURL.lastPathComponent, "state-v1.json")
        XCTAssertEqual(candidateURL.lastPathComponent, "candidate-state-v1.json")
        XCTAssertNotEqual(incumbentURL, candidateURL)
        XCTAssertEqual(
            incumbentURL.deletingLastPathComponent(),
            candidateURL.deletingLastPathComponent(),
            "candidate store must share the incumbent's lifecycle directory"
        )
    }

    /// Candidate mode changes ONLY the persistence file: the full transition
    /// graph is still a release gate. A candidate-scoped store rejects an
    /// illegal transition exactly as the incumbent store would.
    func testCandidateStoreStillEnforcesTransitionGraph() throws {
        let fixture = try Fixture()
        let candidateURL = fixture.recordURL
            .deletingLastPathComponent()
            .appendingPathComponent("candidate-state-v1.json")
        let store = ProviderLifecycleStateStore(url: candidateURL)

        // A valid startup chain writes to the candidate file.
        _ = try store.transition(
            to: .startingProvider,
            reasonCode: "serve_invoked",
            writer: .serve,
            operationID: "candidate:one"
        )
        // An out-of-graph jump (starting_provider -> serving_buyers) is still
        // rejected in candidate mode — the graph is unchanged.
        XCTAssertThrowsError(try store.transition(
            to: .servingBuyers,
            reasonCode: "illegal_candidate_jump",
            writer: .serve,
            operationID: "candidate:one"
        )) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleStateError,
                .invalidTransition(from: "starting_provider", to: "serving_buyers")
            )
        }
        // The write landed on the candidate file, not on state-v1.json.
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recordURL.path))
    }

    func testMalformedRecordFailsClosed() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(
            at: fixture.recordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("not-json".utf8).write(to: fixture.recordURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.recordURL.path)

        guard case .invalid(let reason) = ProviderLifecycleStateStore(url: fixture.recordURL).inspect() else {
            return XCTFail("malformed lifecycle record must fail closed")
        }
        XCTAssertTrue(reason.contains("malformed"))
    }

    func testSymlinkRecordIsRejectedWithoutFollowingTarget() throws {
        let fixture = try Fixture()
        let directory = fixture.recordURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = fixture.root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        XCTAssertEqual(symlink(target.path, fixture.recordURL.path), 0)

        guard case .invalid(let reason) = ProviderLifecycleStateStore(url: fixture.recordURL).inspect() else {
            return XCTFail("symlink lifecycle record must fail closed")
        }
        XCTAssertTrue(reason.contains("symlink"))
    }

    func testConcurrentWritersSerializeWithoutLosingTransitions() throws {
        let fixture = try Fixture()
        let store = ProviderLifecycleStateStore(url: fixture.recordURL)
        let queue = DispatchQueue(label: "lifecycle-state-test", attributes: .concurrent)
        let group = DispatchGroup()
        let failures = FailureCollector()
        for index in 0 ..< 12 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    _ = try store.transition(
                        to: .watchdogRecovery,
                        reasonCode: "test_\(index)",
                        writer: .watchdog,
                        operationID: "watchdog-\(index)"
                    )
                } catch {
                    failures.append(error)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(failures.values.isEmpty, "unexpected failures: \(failures.values)")
        guard case .valid(let record) = store.inspect() else {
            return XCTFail("expected a valid final transition")
        }
        XCTAssertEqual(record.sequence, 12)
    }

    private final class FailureCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Error] = []

        var values: [Error] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func append(_ error: Error) {
            lock.lock()
            stored.append(error)
            lock.unlock()
        }
    }

    private struct Fixture {
        let root: URL
        let recordURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("provider-lifecycle-state-tests-\(UUID().uuidString)", isDirectory: true)
            recordURL = root
                .appendingPathComponent("lifecycle", isDirectory: true)
                .appendingPathComponent("state-v1.json")
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
