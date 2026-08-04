import ArgumentParser
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ServeCommandTests: XCTestCase {
    func testV1853FirstHopFencesRecurringReloadHelperBeforeStartupWork() throws {
        let fixture = try makeSelfUpdateStartupFenceFixture(handoffState: .prepared)
        var recurringHelperActive = true
        var fenceCalls = 0

        let fenced = try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { fixture.pending },
            inspectLifecycleLease: { .valid(fixture.lease) },
            currentExecutableURL: fixture.executable,
            targetVersion: "1.8.54",
            lifecycleEnvironment: selfUpdateStartupFenceEnvironment(),
            executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
            fenceReloadJobs: {
                fenceCalls += 1
                recurringHelperActive = false
            }
        )

        XCTAssertTrue(fenced)
        XCTAssertEqual(fenceCalls, 1)
        XCTAssertFalse(recurringHelperActive)
        XCTAssertNotEqual(
            fixture.pending.sha256,
            try AutoUpdateMarkerStore.sha256(file: fixture.executable),
            "pending.sha256 is the preserved v1.8.53 rollback binary, not the v1.8.54 target"
        )
    }

    func testV1853FirstHopFencesAfterRecurringHelperKilledFirstAdoptedTarget() throws {
        let fixture = try makeSelfUpdateStartupFenceFixture(handoffState: .adopted)
        var fenceCalls = 0

        let fenced = try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { fixture.pending },
            inspectLifecycleLease: {
                .invalidOrExpired(
                    record: fixture.lease,
                    reason: .ownerProcessMissingOrReused
                )
            },
            currentExecutableURL: fixture.executable,
            targetVersion: "1.8.54",
            lifecycleEnvironment: selfUpdateStartupFenceEnvironment(),
            executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
            fenceReloadJobs: { fenceCalls += 1 }
        )

        XCTAssertTrue(fenced)
        XCTAssertEqual(fenceCalls, 1)
    }

    func testAdoptedRestartBeforeCommitFencesAfterOriginalHandoffExpires() throws {
        let fixture = try makeSelfUpdateStartupFenceFixture(
            handoffState: .adopted,
            handoffExpiresWallMilliseconds: 9_000,
            handoffExpiresMonotonicNanoseconds: 9_000_000_000
        )
        var fenceCalls = 0

        XCTAssertTrue(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { fixture.pending },
            inspectLifecycleLease: {
                .invalidOrExpired(
                    record: fixture.lease,
                    reason: .ownerProcessMissingOrReused
                )
            },
            currentExecutableURL: fixture.executable,
            targetVersion: "1.8.54",
            lifecycleEnvironment: selfUpdateStartupFenceEnvironment(),
            executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
            fenceReloadJobs: { fenceCalls += 1 }
        ))
        XCTAssertEqual(fenceCalls, 1)
    }

    func testCoordinatorOwnedRecommendationFirstHopFencesExactLaunchdTarget() throws {
        let fixture = try makeSelfUpdateStartupFenceFixture(
            handoffState: .prepared,
            commitOwner: "coordinator",
            updateAuthorityMode: "coordinator_recommendation"
        )
        try AutoUpdateMarkerStore().validateMarker(fixture.pending)
        var fenceCalls = 0

        XCTAssertTrue(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { fixture.pending },
            inspectLifecycleLease: { .valid(fixture.lease) },
            currentExecutableURL: fixture.executable,
            targetVersion: "1.8.54",
            lifecycleEnvironment: selfUpdateStartupFenceEnvironment(),
            executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
            fenceReloadJobs: { fenceCalls += 1 }
        ))
        XCTAssertEqual(fenceCalls, 1)
    }

    func testCoordinatorOwnedSignedReleaseFirstHopFencesExactLaunchdTarget() throws {
        let fixture = try makeSelfUpdateStartupFenceFixture(
            handoffState: .prepared,
            commitOwner: "coordinator",
            updateAuthorityMode: "signed_release"
        )
        try AutoUpdateMarkerStore().validateMarker(fixture.pending)
        var fenceCalls = 0

        XCTAssertTrue(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { fixture.pending },
            inspectLifecycleLease: { .valid(fixture.lease) },
            currentExecutableURL: fixture.executable,
            targetVersion: "1.8.54",
            lifecycleEnvironment: selfUpdateStartupFenceEnvironment(),
            executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
            fenceReloadJobs: { fenceCalls += 1 }
        ))
        XCTAssertEqual(fenceCalls, 1)
    }

    func testManualServeProcessCannotUseUpdateHandoffToFenceLaunchdHelper() throws {
        let fixture = try makeSelfUpdateStartupFenceFixture(handoffState: .prepared)
        var fenceCalls = 0

        XCTAssertThrowsError(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { fixture.pending },
            inspectLifecycleLease: { .valid(fixture.lease) },
            currentExecutableURL: fixture.executable,
            targetVersion: "1.8.54",
            lifecycleEnvironment: selfUpdateStartupFenceEnvironment(
                processID: 5_321,
                launchdServiceProcessID: 6_321
            ),
            executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
            fenceReloadJobs: { fenceCalls += 1 }
        )) { error in
            XCTAssertEqual(
                error as? SelfUpdateStartupFenceError,
                .authorizationMismatch("launchd_service_owner")
            )
        }
        XCTAssertEqual(fenceCalls, 0)
    }

    func testAdoptedRestartBeforeCommitFencesAfterReboot() throws {
        let fixture = try makeSelfUpdateStartupFenceFixture(handoffState: .adopted)
        var fenceCalls = 0

        XCTAssertTrue(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { fixture.pending },
            inspectLifecycleLease: {
                .invalidOrExpired(
                    record: fixture.lease,
                    reason: .bootSessionChanged
                )
            },
            currentExecutableURL: fixture.executable,
            targetVersion: "1.8.54",
            lifecycleEnvironment: selfUpdateStartupFenceEnvironment(bootSession: "boot-b"),
            executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
            fenceReloadJobs: { fenceCalls += 1 }
        ))
        XCTAssertEqual(fenceCalls, 1)
    }

    func testRestoredPreviousStartupFencesWithoutRecoveringFailedTargetHandoff() throws {
        for rollbackState in [
            CompatibilitySetTransactionState.restoringPrevious,
            .awaitingPreviousReadiness,
        ] {
            let fixture = try makeSelfUpdateStartupFenceFixture(
                handoffState: .adopted,
                updateAuthorityMode: "coordinator_recommendation",
                transactionState: rollbackState
            )
            try Data("v1.8.53 public".utf8).write(to: fixture.executable)
            var inspectedLease = false
            var fenceCalls = 0

            let authorizesFailedTargetHandoff = try ServeCommand
                .fenceAuthorizedSelfUpdateReloadJobsAtStartup(
                    loadPending: { fixture.pending },
                    inspectLifecycleLease: {
                        inspectedLease = true
                        return .valid(fixture.lease)
                    },
                    currentExecutableURL: fixture.executable,
                    targetVersion: "1.8.53",
                    lifecycleEnvironment: selfUpdateStartupFenceEnvironment(),
                    executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
                    fenceReloadJobs: { fenceCalls += 1 }
                )

            XCTAssertFalse(authorizesFailedTargetHandoff)
            XCTAssertFalse(inspectedLease)
            XCTAssertEqual(fenceCalls, 1)
        }
    }

    func testRestoredPreviousStartupRejectsWrongVersionAndBinary() throws {
        let fixture = try makeSelfUpdateStartupFenceFixture(
            handoffState: .adopted,
            updateAuthorityMode: "coordinator_recommendation",
            transactionState: .awaitingPreviousReadiness
        )
        var fenceCalls = 0

        XCTAssertThrowsError(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { fixture.pending },
            inspectLifecycleLease: { .valid(fixture.lease) },
            currentExecutableURL: fixture.executable,
            targetVersion: "1.8.52",
            lifecycleEnvironment: selfUpdateStartupFenceEnvironment(),
            executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
            fenceReloadJobs: { fenceCalls += 1 }
        )) { error in
            XCTAssertEqual(
                error as? SelfUpdateStartupFenceError,
                .authorizationMismatch("rollback_previous_version")
            )
        }

        XCTAssertThrowsError(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { fixture.pending },
            inspectLifecycleLease: { .valid(fixture.lease) },
            currentExecutableURL: fixture.executable,
            targetVersion: "1.8.53",
            lifecycleEnvironment: selfUpdateStartupFenceEnvironment(),
            executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
            fenceReloadJobs: { fenceCalls += 1 }
        )) { error in
            XCTAssertEqual(
                error as? SelfUpdateStartupFenceError,
                .authorizationMismatch("rollback_previous_sha256")
            )
        }
        XCTAssertEqual(fenceCalls, 0)
    }

    func testManualProcessCannotUseRetainedRollbackMarker() throws {
        let fixture = try makeSelfUpdateStartupFenceFixture(
            handoffState: .adopted,
            updateAuthorityMode: "coordinator_recommendation",
            transactionState: .awaitingPreviousReadiness
        )
        try Data("v1.8.53 public".utf8).write(to: fixture.executable)
        var fenceCalls = 0

        XCTAssertThrowsError(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { fixture.pending },
            inspectLifecycleLease: { .valid(fixture.lease) },
            currentExecutableURL: fixture.executable,
            targetVersion: "1.8.53",
            lifecycleEnvironment: selfUpdateStartupFenceEnvironment(
                processID: 5_321,
                launchdServiceProcessID: 6_321
            ),
            executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
            fenceReloadJobs: { fenceCalls += 1 }
        )) { error in
            XCTAssertEqual(
                error as? SelfUpdateStartupFenceError,
                .authorizationMismatch("launchd_service_owner")
            )
        }
        XCTAssertEqual(fenceCalls, 0)
    }

    func testSelfUpdateStartupFenceRejectsAuthorizationMismatchWithoutFencing() throws {
        let fixture = try makeSelfUpdateStartupFenceFixture(handoffState: .prepared)
        var fenceCalls = 0

        XCTAssertThrowsError(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { fixture.pending },
            inspectLifecycleLease: { .valid(fixture.lease) },
            currentExecutableURL: fixture.executable,
            targetVersion: "1.8.55",
            lifecycleEnvironment: selfUpdateStartupFenceEnvironment(),
            executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
            fenceReloadJobs: { fenceCalls += 1 }
        )) { error in
            XCTAssertEqual(
                error as? SelfUpdateStartupFenceError,
                .authorizationMismatch("target_version")
            )
        }
        XCTAssertEqual(fenceCalls, 0)
    }

    func testSelfUpdateStartupFenceRequiresMatchingHandoffBeforeFencing() throws {
        let fixture = try makeSelfUpdateStartupFenceFixture(handoffState: .prepared)
        var fenceCalls = 0

        XCTAssertThrowsError(try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { fixture.pending },
            inspectLifecycleLease: { .missing },
            currentExecutableURL: fixture.executable,
            targetVersion: "1.8.54",
            lifecycleEnvironment: selfUpdateStartupFenceEnvironment(),
            executableSHA256: { try AutoUpdateMarkerStore.sha256(file: $0) },
            fenceReloadJobs: { fenceCalls += 1 }
        )) { error in
            XCTAssertEqual(
                error as? SelfUpdateStartupFenceError,
                .authorizationMismatch("startup_handoff")
            )
        }
        XCTAssertEqual(fenceCalls, 0)
    }

    func testOrdinaryStartupWithoutPendingUpdateDoesNotFenceReloadJobs() throws {
        var inspectedLease = false
        var fenceCalls = 0

        let fenced = try ServeCommand.fenceAuthorizedSelfUpdateReloadJobsAtStartup(
            loadPending: { nil },
            inspectLifecycleLease: {
                inspectedLease = true
                return .missing
            },
            currentExecutableURL: nil,
            targetVersion: "1.8.54",
            executableSHA256: { _ in
                XCTFail("ordinary startup must not hash an executable")
                return ""
            },
            fenceReloadJobs: { fenceCalls += 1 }
        )

        XCTAssertFalse(fenced)
        XCTAssertFalse(inspectedLease)
        XCTAssertEqual(fenceCalls, 0)
    }

    func testAdmissionIdentityStartupTopologyClassifiesMarkedPendingKeyAsRecovery() {
        let current = Data(repeating: 0x11, count: 32)
        let pending = Data(repeating: 0x22, count: 32)

        XCTAssertEqual(
            AdmissionIdentityStartupTopology.resolve(
                currentPublicKey: current,
                pendingPublicKey: pending,
                recoveryMarkerPublicKey: pending
            ),
            .recoveryPending
        )
        XCTAssertEqual(
            AdmissionIdentityStartupTopology.resolve(
                currentPublicKey: current,
                pendingPublicKey: pending,
                recoveryMarkerPublicKey: nil
            ),
            .rotationPending
        )
        XCTAssertEqual(
            AdmissionIdentityStartupTopology.resolve(
                currentPublicKey: current,
                pendingPublicKey: pending,
                recoveryMarkerPublicKey: Data(repeating: 0x33, count: 32)
            ),
            .invalidRecoveryMarker
        )
        XCTAssertEqual(
            AdmissionIdentityStartupTopology.resolve(
                currentPublicKey: pending,
                pendingPublicKey: pending,
                recoveryMarkerPublicKey: pending
            ),
            .recoveryPending,
            "a crash after replacing current but before marker cleanup must replay recovery idempotently"
        )
        XCTAssertEqual(
            AdmissionIdentityStartupTopology.resolve(
                currentPublicKey: pending,
                pendingPublicKey: nil,
                recoveryMarkerPublicKey: pending
            ),
            .recoveryCommittedCleanup,
            "a crash after deleting pending but before deleting the marker must finish local cleanup"
        )
    }

    func testServeCommandRejectsInlineProviderTokenArguments() throws {
        let deprecated = try ServeCommand.parse(["--token", "secret"])
        XCTAssertThrowsError(try ConfigLoader.load(cli: CLIOverrides(providerToken: deprecated.providerToken), environment: [:])) { error in
            XCTAssertTrue(String(describing: error).contains("--provider-token"))
        }

        let legacy = try ServeCommand.parse(["--provider-token", "secret"])
        XCTAssertThrowsError(try ConfigLoader.load(cli: CLIOverrides(providerToken: legacy.providerToken), environment: [:])) { error in
            XCTAssertTrue(String(describing: error).contains("--provider-token"))
        }
    }

    func testConfigLoaderReadsProviderTokenFromPrivateTokenFile() throws {
        let dir = try tempDir()
        let tokenFile = dir.appendingPathComponent("token")
        try "file-token\n".write(to: tokenFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)

        let config = try ConfigLoader.load(cli: CLIOverrides(providerTokenFile: tokenFile.path), environment: [:])

        XCTAssertEqual(config.providerToken, "file-token")
    }

    func testConfigLoaderRejectsWorldReadableProviderTokenFile() throws {
        let dir = try tempDir()
        let tokenFile = dir.appendingPathComponent("token")
        try "file-token\n".write(to: tokenFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenFile.path)

        XCTAssertThrowsError(try ConfigLoader.load(cli: CLIOverrides(providerTokenFile: tokenFile.path), environment: [:]))
    }

    func testNoJoinFlagParses() throws {
        let command = try ServeCommand.parse([
            "--no-join",
            "--model", "model-a",
            "--port", "18080",
        ])

        XCTAssertTrue(command.noJoin)
        XCTAssertEqual(command.model, "model-a")
        XCTAssertEqual(command.port, 18080)
    }

    // MARK: - SPEC-037 FR-KVP11 / AC-9: serve exposes + forwards the KV disk-tier flags

    /// MEDIUM-5: every `--kv-disk-cache-*` flag parses on ServeCommand and maps to the
    /// matching KVDiskCacheCLIOverrides field, so the triple-source config surface reaches
    /// the resolver from the CLI. CLI-wins precedence is then verified through the resolver.
    func testKVDiskCacheServeFlagsParseAndForward() throws {
        let command = try ServeCommand.parse([
            "--no-join", "--model", "model-a",
            "--kv-disk-cache-enabled",
            "--kv-disk-cache-dir", "/var/kvcache",
            "--kv-disk-cache-max-bytes", "3000000000",
            "--kv-disk-cache-max-entries", "42",
            "--kv-disk-cache-max-entry-bytes", "500000000",
            "--kv-disk-cache-retention-minutes", "30",
            "--kv-disk-cache-staging-max-bytes", "100000000",
            "--kv-disk-cache-write-staging-max-bytes", "200000000",
            "--kv-disk-cache-min-free-bytes", "2000000000",
            "--kv-disk-cache-promotion-max-s", "9",
            "--kv-disk-cache-shutdown-drain-s", "7",
        ])
        let o = command.kvDiskCacheCLIOverrides
        XCTAssertEqual(o.enabled, true)
        XCTAssertEqual(o.directory, "/var/kvcache")
        XCTAssertEqual(o.maxBytes, 3_000_000_000)
        XCTAssertEqual(o.maxEntries, 42)
        XCTAssertEqual(o.maxEntryBytes, 500_000_000)
        XCTAssertEqual(o.retentionMinutes, 30)
        XCTAssertEqual(o.stagingMaxBytes, 100_000_000)
        XCTAssertEqual(o.writeStagingMaxBytes, 200_000_000)
        XCTAssertEqual(o.minFreeBytes, 2_000_000_000)
        XCTAssertEqual(o.promotionMaxSeconds, 9)
        XCTAssertEqual(o.shutdownDrainSeconds, 7)
        XCTAssertNil(o.allowBuyerKeys, "an unset flag defers to env/YAML (nil), not false")

        // CLI-wins precedence: the CLI max_bytes overrides a conflicting environment value.
        let resolved = KVDiskCacheConfigResolver.resolve(
            yaml: nil, environment: ["MACPROVIDER_KV_DISK_CACHE_MAX_BYTES": "999"],
            cli: o, homeDirectory: "/Users/tester")
        XCTAssertTrue(resolved.effectiveEnabled)
        XCTAssertEqual(resolved.maxBytes, 3_000_000_000, "CLI override wins over the environment")
        XCTAssertEqual(resolved.directory, "/var/kvcache")
    }

    /// AC-9: `--kv-disk-cache-allow-buyer-keys` reaches the resolver and fails closed —
    /// the tier is force-disabled with the v0.1 precondition error, even with enabled=true.
    func testKVDiskCacheAllowBuyerKeysFlagFailsClosed() throws {
        let command = try ServeCommand.parse([
            "--no-join", "--model", "model-a",
            "--kv-disk-cache-enabled",
            "--kv-disk-cache-allow-buyer-keys",
        ])
        XCTAssertEqual(command.kvDiskCacheCLIOverrides.allowBuyerKeys, true)
        let resolved = KVDiskCacheConfigResolver.resolve(
            yaml: nil, environment: [:], cli: command.kvDiskCacheCLIOverrides, homeDirectory: "/Users/tester")
        XCTAssertFalse(resolved.effectiveEnabled, "allow_buyer_keys=true must force the tier off")
        XCTAssertTrue(resolved.errors.contains { $0.contains("allow_buyer_keys=true is rejected") },
                      "the v0.1 precondition error must be recorded (and later logged on serve)")
    }

    func testAutotuneCandidateFlagRequiresNoJoin() throws {
        XCTAssertThrowsError(try ServeCommand.parse([
            "--autotune-candidate",
            "--model", "model-a",
            "--port", "18080",
        ])) { error in
            XCTAssertTrue(
                String(describing: error).contains("--autotune-candidate requires --no-join"),
                "unexpected error: \(error)"
            )
        }

        let command = try ServeCommand.parse([
            "--no-join",
            "--autotune-candidate",
            "--model", "model-a",
            "--port", "18080",
        ])
        XCTAssertTrue(command.noJoin)
        XCTAssertTrue(command.autotuneCandidate)
    }

    func testAutotuneCandidateSkipsDuplicateStartupMeasurement() async {
        let candidateEstimate = await ServeCommand.startupThroughputEstimate(
            autotuneCandidate: true,
            measure: {
                XCTFail("autotune candidates must leave inference measurement to Stage 1")
                return 99
            }
        )
        XCTAssertEqual(candidateEstimate, 0)

        let providerEstimate = await ServeCommand.startupThroughputEstimate(
            autotuneCandidate: false,
            measure: { 42 }
        )
        XCTAssertEqual(providerEstimate, 42)
    }

    func testAutotuneCandidateRoutesLifecycleStoreToCandidateFile() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("serve-lifecycle-home-\(UUID().uuidString)", isDirectory: true)

        let candidateStore = ServeCommand.lifecycleStateStore(
            autotuneCandidate: true,
            homeDirectory: home
        )
        XCTAssertEqual(candidateStore.url.lastPathComponent, "candidate-state-v1.json")
        XCTAssertEqual(
            candidateStore.url,
            ProviderLifecycleStateStore.candidateURL(homeDirectory: home)
        )

        let incumbentStore = ServeCommand.lifecycleStateStore(
            autotuneCandidate: false,
            homeDirectory: home
        )
        XCTAssertEqual(incumbentStore.url.lastPathComponent, "state-v1.json")
        XCTAssertEqual(
            incumbentStore.url,
            ProviderLifecycleStateStore.defaultURL(homeDirectory: home)
        )

        XCTAssertNotEqual(candidateStore.url, incumbentStore.url)
        XCTAssertEqual(
            candidateStore.url.deletingLastPathComponent(),
            incumbentStore.url.deletingLastPathComponent(),
            "candidate and incumbent stores must share the lifecycle directory"
        )
    }

    func testAutotuneCandidateIsolationRootIsFreshAndOwnerOnly() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("serve-candidate-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let first = try ServeCommand.makeCandidateIsolationRoot(temporaryDirectory: temporaryDirectory)
        let second = try ServeCommand.makeCandidateIsolationRoot(temporaryDirectory: temporaryDirectory)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        XCTAssertNotEqual(first, second)
        var info = stat()
        XCTAssertEqual(lstat(first.path, &info), 0)
        XCTAssertEqual(info.st_uid, geteuid())
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(
            ServeCommand.candidateControlSocketPath(rootDirectory: first),
            first.appendingPathComponent("control.sock").path
        )
        XCTAssertEqual(
            ProviderLifecycleLeaseStore.candidateURL(rootDirectory: first),
            first.appendingPathComponent("lifecycle/lease.json")
        )
    }

    func testEnableReceiptsFlagParses() throws {
        let command = try ServeCommand.parse([
            "--enable-receipts",
            "--model", "model-a",
        ])

        XCTAssertEqual(command.enableReceipts, true)
    }

    func testNoJoinSkipsCoordinatorClientInstantiation() {
        var factoryInvoked = false

        let client = ServeCommand.makeCoordinatorClient(noJoin: true) {
            factoryInvoked = true
            return nil
        }

        XCTAssertNil(client)
        XCTAssertFalse(factoryInvoked)
    }

    func testDefaultServePathInvokesCoordinatorClientFactory() {
        var factoryInvoked = false

        _ = ServeCommand.makeCoordinatorClient(noJoin: false) {
            factoryInvoked = true
            return nil
        }

        XCTAssertTrue(factoryInvoked)
    }

    func testDonorModeSkipsCoordinatorClientInstantiation() {
        var factoryInvoked = false

        let client = ServeCommand.makeCoordinatorClient(noJoin: false, donorMode: true) {
            factoryInvoked = true
            return nil
        }

        XCTAssertNil(client)
        XCTAssertFalse(factoryInvoked)
    }

    func testCoordinatorStartIsScheduledByListeningCallback() async {
        let started = expectation(description: "coordinator start scheduled")

        ServeCommand.startCoordinatorAfterListening {
            started.fulfill()
        }

        await fulfillment(of: [started], timeout: 1)
    }

    func testEstablishedBootstrapShapedProviderCannotServeWithoutCredential() {
        var config = AppConfig.defaults()
        config.providerID = "mp-0123456789abcdef0123456789abcdef"
        config.providerToken = nil

        XCTAssertThrowsError(try ServeCommand.validateCoordinatorCredential(
            config: config,
            credentialStatus: ProviderCredentialStatus(
                source: .none,
                state: .missing,
                restartSafe: false
            ),
            noJoin: false
        )) { error in
            XCTAssertTrue(String(describing: error).contains("credential state is missing"))
        }
    }

    func testCoordinatorCredentialPreflightRejectsEveryNonReadyCustodyState() {
        var config = AppConfig.defaults()
        config.providerID = "provider-a"
        config.providerToken = nil
        let failures: [ProviderCredentialStatus.State] = [
            .degraded, .conflict, .missing, .locked, .notLoggedIn,
            .permissionDenied, .corrupt, .keychainFailure, .incompatible, .unavailable,
        ]

        for state in failures {
            XCTAssertThrowsError(try ServeCommand.validateCoordinatorCredential(
                config: config,
                credentialStatus: ProviderCredentialStatus(
                    source: .none,
                    state: state,
                    restartSafe: false
                ),
                noJoin: false
            ), "state=\(state.rawValue)")
        }
    }

    func testCoordinatorCredentialPreflightAllowsExplicitNonJoiningModes() throws {
        var config = AppConfig.defaults()
        config.providerID = "provider-a"
        config.providerToken = nil
        let missing = ProviderCredentialStatus(
            source: .none,
            state: .missing,
            restartSafe: false
        )

        XCTAssertNoThrow(try ServeCommand.validateCoordinatorCredential(
            config: config,
            credentialStatus: missing,
            noJoin: true
        ))
        config.donorMode = true
        XCTAssertNoThrow(try ServeCommand.validateCoordinatorCredential(
            config: config,
            credentialStatus: missing,
            noJoin: false
        ))
    }

    func testSafeOfflineCatalogFallbackRequestsCoordinatorCompatibility() {
        var factoryInvoked = false

        let client = ServeCommand.makeCoordinatorClient(
            noJoin: false,
            catalogTrustState: "safe_offline_fallback"
        ) {
            factoryInvoked = true
            return nil
        }

        XCTAssertNil(client)
        XCTAssertTrue(factoryInvoked)
    }

    func testCatalogIntegrityFailureDoesNotJoinCoordinator() {
        var factoryInvoked = false
        let client = ServeCommand.makeCoordinatorClient(
            noJoin: false,
            catalogTrustState: "catalog_integrity_failure"
        ) {
            factoryInvoked = true
            return nil
        }
        XCTAssertNil(client)
        XCTAssertFalse(factoryInvoked)
    }

    func testServeStartupPreflightsAcquireSingletonBeforeModelArtifactPreflight() async throws {
        let lockDirectory = try tempDir()
        let heldLock = try ProviderServeLock.acquire(providerID: "mac", port: 61_919, directory: lockDirectory)
        defer { heldLock.release() }
        var config = configWithInvalidArtifact(port: 61_919)

        do {
            _ = try await ServeCommand.runServeStartupPreflights(
                &config,
                joiningCoordinator: false,
                portIsOpen: { _ in false },
                acquireServeLock: { config in
                    do {
                        return try ProviderServeLock.acquire(
                            providerID: config.providerID,
                            port: config.port,
                            directory: lockDirectory
                        )
                    } catch is ProviderServeLockError {
                        throw ExitCode(1)
                    }
                }
            )
            XCTFail("duplicate serve startup must fail before model artifact preflight")
        } catch {
            XCTAssertEqual(error as? ExitCode, ExitCode(1))
        }
    }

    func testServeStartupPreflightsRejectOpenPortBeforeModelArtifactPreflightAndReleaseLock() async throws {
        let lockDirectory = try tempDir()
        var config = configWithInvalidArtifact(port: 61_920)

        do {
            _ = try await ServeCommand.runServeStartupPreflights(
                &config,
                joiningCoordinator: false,
                portIsOpen: { port in port == 61_920 },
                acquireServeLock: { config in
                    try ProviderServeLock.acquire(
                        providerID: config.providerID,
                        port: config.port,
                        directory: lockDirectory
                    )
                }
            )
            XCTFail("legacy listener on serve port must fail before model artifact preflight")
        } catch {
            XCTAssertEqual(error as? ExitCode, ExitCode(1))
        }

        let retryLock = try ProviderServeLock.acquire(providerID: "retry", port: 61_920, directory: lockDirectory)
        retryLock.release()
    }

    func testCoordinatorCatalogPreflightFailureIsClassifiedAndReleasesServeLock() async throws {
        let lockDirectory = try tempDir()
        let snapshot = try makeSnapshot()
        var config = AppConfig.defaults()
        config.providerID = "mac"
        config.port = 61_921
        config.model = "test-public-model"
        config.modelArtifactPath = snapshot.path
        config.modelArtifactSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)

        do {
            _ = try await ServeCommand.runServeStartupPreflights(
                &config,
                joiningCoordinator: true,
                portIsOpen: { _ in false },
                acquireServeLock: { config in
                    try ProviderServeLock.acquire(
                        providerID: config.providerID,
                        port: config.port,
                        directory: lockDirectory
                    )
                }
            )
            XCTFail("missing catalog provenance must fail as catalog-incompatible")
        } catch {
            XCTAssertTrue(error is ServeCatalogPreflightError)
        }

        let retryLock = try ProviderServeLock.acquire(providerID: "retry", port: 61_921, directory: lockDirectory)
        retryLock.release()
    }

    func testReceiptBuilderDisabledByDefault() throws {
        var config = AppConfig.defaults()
        config.providerID = "provider-a"

        XCTAssertNil(try ServeCommand.makeReceiptBuilder(config: config, keyStore: InMemoryReceiptKeyStore()))
    }

    func testReceiptBuilderRequiresProviderID() throws {
        var config = AppConfig.defaults()
        config.enableReceipts = true

        XCTAssertNil(try ServeCommand.makeReceiptBuilder(config: config, keyStore: InMemoryReceiptKeyStore()))
    }

    func testReceiptBuilderEnabledGeneratesCurrentKey() throws {
        var config = AppConfig.defaults()
        config.enableReceipts = true
        config.providerID = "provider-a"
        let store = InMemoryReceiptKeyStore()

        let builder = try XCTUnwrap(ServeCommand.makeReceiptBuilder(config: config, keyStore: store))

        XCTAssertNotNil(try store.loadCurrent(providerId: "provider-a"))
        XCTAssertNotNil(builder)
    }

    func testReceiptRuntimePublishesCurrentKeyPublicBytes() throws {
        var config = AppConfig.defaults()
        config.enableReceipts = true
        config.providerID = "provider-a"
        let store = InMemoryReceiptKeyStore()

        let runtime = try ServeCommand.makeReceiptRuntime(config: config, keyStore: store)
        let current = try XCTUnwrap(store.loadCurrent(providerId: "provider-a"))

        XCTAssertNotNil(runtime.builder)
        XCTAssertEqual(runtime.publicKeyBase64, Data(current.publicKey.rawRepresentation).base64EncodedString())
    }

    func testNoJoinModelArtifactPreflightAcceptsMatchingLocalSnapshotHash() async throws {
        let snapshot = try makeSnapshot()
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        var config = AppConfig.defaults()
        config.model = "test-public-model"
        config.modelArtifactPath = snapshot.path
        config.modelArtifactSHA256 = expected

        try await ServeCommand.runModelArtifactPreflight(config, joiningCoordinator: false)
    }

    func testSelfTestUsesVerifiedArtifactPathForRuntimeLoad() {
        var config = AppConfig.defaults()
        config.model = "test-public-model"
        config.modelArtifactPath = "/tmp/macprovider-test-snapshot"

        XCTAssertEqual(SelfTestCommand.modelLoadPath(for: config), "/tmp/macprovider-test-snapshot")
    }

    func testCoordinatorJoinRequiresCatalogBindingForVerifiedArtifact() async throws {
        let snapshot = try makeSnapshot()
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        var config = AppConfig.defaults()
        config.model = "test-public-model"
        config.modelArtifactPath = snapshot.path
        config.modelArtifactSHA256 = expected

        do {
            try await ServeCommand.runModelArtifactPreflight(config, joiningCoordinator: true)
            XCTFail("coordinator-joining paid mode must require catalog provenance")
        } catch {
            // expected
        }
    }

    func testCoordinatorJoinRequiresVerifiedModelArtifactMetadata() async throws {
        var config = AppConfig.defaults()
        config.model = "test-public-model"

        do {
            try await ServeCommand.runModelArtifactPreflight(config, joiningCoordinator: true)
            XCTFail("coordinator-joining paid mode must require a verified artifact hash")
        } catch {
            // expected
        }
    }

    func testDonorModeRequiresVerifiedModelArtifactHash() async throws {
        var config = AppConfig.defaults()
        config.donorMode = true
        config.model = "/tmp/arbitrary-model"

        do {
            try await ServeCommand.runModelArtifactPreflight(config)
            XCTFail("donor mode must require an artifact hash")
        } catch {
            // expected
        }
    }

    func testDonorModeRequiresCatalogBindingForVerifiedArtifact() async throws {
        let snapshot = try makeSnapshot()
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        var config = AppConfig.defaults()
        config.donorMode = true
        config.model = "test-public-model"
        config.modelArtifactPath = snapshot.path
        config.modelArtifactSHA256 = expected

        do {
            try await ServeCommand.runModelArtifactPreflight(config)
            XCTFail("donor mode must require catalog provenance")
        } catch {
            // expected
        }
    }

    func testDonorModeAcceptsCatalogBoundSnapshot() async throws {
        try await assertCatalogBoundSnapshotPreflight(runtimeStatus: "listed", donorMode: true)
    }

    func testCoordinatorJoinAcceptsCatalogBoundRecommendableSnapshot() async throws {
        try await assertCatalogBoundSnapshotPreflight(runtimeStatus: "recommendable", donorMode: false)
    }

    func testCoordinatorJoinAcceptsNormalizedPublicKeyForCatalogBoundSnapshot() async throws {
        try await assertCatalogBoundSnapshotPreflight(
            runtimeStatus: "recommendable",
            donorMode: false,
            catalogKey: "mlx-community/gpt-oss-20b-MXFP4-Q8",
            configuredModel: "openai/gpt-oss-20b",
            rateCardKey: "openai/gpt-oss-20b"
        )
    }

    func testCoordinatorJoinRejectsCatalogBoundListedSnapshot() async throws {
        do {
            try await assertCatalogBoundSnapshotPreflight(runtimeStatus: "listed", donorMode: false)
            XCTFail("paid coordinator join must require a recommendable catalog row")
        } catch {
            // expected
        }
    }

    func testCoordinatorJoinAcceptsCatalogBoundSnapshotWithStaleProvenanceEnvelope() async throws {
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let key = "test-model"
        let modelID = "test/model"
        let revision = String(repeating: "1", count: 40)
        let snapshot = resolver.snapshotURL(modelID: modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        let artifactSHA = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        let currentCatalogJSON = """
        {"version":"current-catalog","generated_at":"2026-07-29T08:45:00Z","source":"operator_curated_autotune_candidate_catalog","policy_version":"autotune-policy-v1","rows":{"\(key)":{"model_id":"\(modelID)","model_revision":"\(revision)","model_sha256":"\(artifactSHA)","min_ram_gb":1,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000,"provenance":{"source":"legacy_unverified","notes":"test fixture"}},"runtime_status":"recommendable"}}}
        """
        let rateCardJSON = Self.validRateCardJSON(keys: [key])
        let demandRankJSON = Self.validDemandRankJSON(keys: [key], version: "current-catalog")
        let catalogBytes = Data(currentCatalogJSON.utf8)
        let rateCardBytes = Data(rateCardJSON.utf8)
        let demandRankBytes = Data(demandRankJSON.utf8)
        let staticInputs = AutotuneStaticInputs(
            fetch: { url in
                switch url.path {
                case "/v1/rate-card":
                    return rateCardBytes
                case "/v1/autotune-candidates":
                    return catalogBytes
                case "/v1/demand-rank":
                    return demandRankBytes
                default:
                    break
                }
                if url.path.hasSuffix(".sig") {
                    let signature = Data(repeating: 0, count: 64).base64EncodedString()
                    return Data("{\"key_id\":\"streamvc-autotune-static-v4\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
                }
                return catalogBytes
            },
            verifySignature: { _, _ in true },
            now: { ISO8601DateFormatter.autotuneInternet.date(from: "2026-07-29T08:45:00Z")! }
        )
        var config = AppConfig.defaults()
        config.model = key
        config.modelArtifactPath = snapshot.path
        config.modelArtifactSHA256 = artifactSHA
        config.modelCatalogKey = key
        config.modelCatalogModelID = modelID
        config.modelCatalogRevision = revision
        config.modelCatalogSHA256 = artifactSHA
        // Simulate config written by an older autotune --apply against a prior catalog publish.
        config.modelCatalogVersion = "prior-catalog"
        config.modelCatalogHash = String(repeating: "a", count: 64)

        try await ServeCommand.runModelArtifactPreflight(
            config,
            joiningCoordinator: true,
            staticInputs: staticInputs,
            artifactResolver: resolver
        )
    }

    func testCoordinatorJoinRejectsPublicModelKeyMismatchForCatalogBoundSnapshot() async throws {
        do {
            try await assertCatalogBoundSnapshotPreflight(
                runtimeStatus: "recommendable",
                donorMode: false,
                catalogKey: "test-model",
                configuredModel: "different-public-model",
                rateCardKey: "test-model"
            )
            XCTFail("paid coordinator join must bind public model key to verified catalog provenance")
        } catch {
            // expected
        }
    }

    func testCoordinatorJoinAcceptsDefaultRateCardForCatalogBoundSnapshot() async throws {
        try await assertCatalogBoundSnapshotPreflight(
            runtimeStatus: "recommendable",
            donorMode: false,
            catalogKey: "test-model",
            configuredModel: "test-model",
            rateCardKey: "default"
        )
    }

    func testCoordinatorJoinRejectsDefaultRateCardAsPublicModelForCatalogBoundSnapshot() async throws {
        do {
            try await assertCatalogBoundSnapshotPreflight(
                runtimeStatus: "recommendable",
                donorMode: false,
                catalogKey: "test-model",
                configuredModel: "default",
                rateCardKey: "default"
            )
            XCTFail("default rate-card row must not become the served public model")
        } catch {
            // expected
        }
    }

    func testCoordinatorJoinRejectsRateCardIntegrityFailureForCatalogBoundSnapshot() async throws {
        do {
            try await assertCatalogBoundSnapshotPreflight(
                runtimeStatus: "recommendable",
                donorMode: false,
                catalogKey: "test-model",
                configuredModel: nil,
                rateCardKey: "test-model",
                rateCardSidecarMissing: true
            )
            XCTFail("paid coordinator join must block untrusted signed rate-card inputs")
        } catch {
            // expected
        }
    }

    func testCoordinatorJoinRejectsRateCardReleaseMismatchForCatalogBoundSnapshot() async throws {
        do {
            try await assertCatalogBoundSnapshotPreflight(
                runtimeStatus: "recommendable",
                donorMode: false,
                catalogKey: "test-model",
                configuredModel: nil,
                rateCardKey: "test-model",
                rateCardGeneratedAt: "2026-07-29T09:00:00Z"
            )
            XCTFail("paid coordinator join must block signed rate-card/catalog release mismatch")
        } catch {
            // expected
        }
    }

    private func assertCatalogBoundSnapshotPreflight(runtimeStatus: String, donorMode: Bool) async throws {
        try await assertCatalogBoundSnapshotPreflight(
            runtimeStatus: runtimeStatus,
            donorMode: donorMode,
            catalogKey: "test-model",
            configuredModel: nil,
            rateCardKey: "test-model"
        )
    }

    private func assertCatalogBoundSnapshotPreflight(
        runtimeStatus: String,
        donorMode: Bool,
        catalogKey: String,
        configuredModel: String?,
        rateCardKey: String,
        rateCardSidecarMissing: Bool = false,
        rateCardGeneratedAt: String = "2026-07-29T08:45:00Z"
    ) async throws {
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let key = catalogKey
        let modelID = "test/model"
        let revision = String(repeating: "1", count: 40)
        let snapshot = resolver.snapshotURL(modelID: modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        let artifactSHA = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        let catalogJSON = """
        {"version":"test-catalog","generated_at":"2026-07-29T08:45:00Z","source":"operator_curated_autotune_candidate_catalog","policy_version":"autotune-policy-v1","rows":{"\(key)":{"model_id":"\(modelID)","model_revision":"\(revision)","model_sha256":"\(artifactSHA)","min_ram_gb":1,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000,"provenance":{"source":"legacy_unverified","notes":"test fixture"}},"runtime_status":"\(runtimeStatus)"}}}
        """
        let rateCardJSON = Self.validRateCardJSON(keys: [rateCardKey], generatedAt: rateCardGeneratedAt)
        let demandRankJSON = Self.validDemandRankJSON(keys: [key], version: "test-catalog")
        let catalogBytes = Data(catalogJSON.utf8)
        let rateCardBytes = Data(rateCardJSON.utf8)
        let demandRankBytes = Data(demandRankJSON.utf8)
        let staticInputs = AutotuneStaticInputs(
            fetch: { url in
                switch url.path {
                case "/v1/rate-card":
                    return rateCardBytes
                case "/v1/autotune-candidates":
                    return catalogBytes
                case "/v1/demand-rank":
                    return demandRankBytes
                default:
                    break
                }
                if url.path.hasSuffix(".sig") {
                    if rateCardSidecarMissing, url.path == "/v1/rate-card.sig" {
                        throw URLError(.fileDoesNotExist)
                    }
                    let signature = Data(repeating: 0, count: 64).base64EncodedString()
                    return Data("{\"key_id\":\"streamvc-autotune-static-v4\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
                }
                return catalogBytes
            },
            verifySignature: { _, _ in true },
            now: { ISO8601DateFormatter.autotuneInternet.date(from: "2026-07-29T08:45:00Z")! }
        )
        var config = AppConfig.defaults()
        config.donorMode = donorMode
        config.model = configuredModel ?? key
        config.modelArtifactPath = snapshot.path
        config.modelArtifactSHA256 = artifactSHA
        config.modelCatalogKey = key
        config.modelCatalogModelID = modelID
        config.modelCatalogRevision = revision
        config.modelCatalogSHA256 = artifactSHA
        config.modelCatalogVersion = "test-catalog"
        config.modelCatalogHash = AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalogBytes)

        try await ServeCommand.runModelArtifactPreflight(
            config,
            joiningCoordinator: true,
            staticInputs: staticInputs,
            artifactResolver: resolver
        )
    }

    private static func validRateCardJSON(
        keys: [String],
        generatedAt: String = "2026-07-29T08:45:00Z"
    ) -> String {
        var rows: [String: RateCardProjection.Row] = [
            "default": RateCardProjection.Row(
                promptRatePerMtok: 1,
                completionRatePerMtok: 1,
                providerShareBPS: 9_000,
                globalMultiplierPPM: 1_000_000
            ),
        ]
        for key in keys where key != "default" {
            rows[key] = RateCardProjection.Row(
                promptRatePerMtok: 1,
                completionRatePerMtok: 1,
                providerShareBPS: 9_000,
                globalMultiplierPPM: 1_000_000
            )
        }
        let projection = RateCardProjection(
            version: "",
            policyVersion: "autotune-policy-v1",
            generatedAt: ISO8601DateFormatter.autotuneInternet.date(from: generatedAt)!,
            usdPerMillionCredits: 1,
            rows: rows
        )
        let rowsJSON = rows.keys.sorted().map { key -> String in
            let row = rows[key]!
            return "\(Self.jsonStringLiteral(key)):{\"prompt_rate_per_mtok\":\(row.promptRatePerMtok),\"prompt_cache_hit_rate_per_mtok\":\(row.promptCacheHitRatePerMtok),\"completion_rate_per_mtok\":\(row.completionRatePerMtok),\"provider_share_bps\":\(row.providerShareBPS),\"global_multiplier_ppm\":\(row.globalMultiplierPPM)}"
        }.joined(separator: ",")
        return """
        {"version":"\(projection.projectionHash)","policy_version":"autotune-policy-v1","generated_at":"\(generatedAt)","usd_per_million_credits":1,"rows":{\(rowsJSON)}}
        """
    }

    private static func validDemandRankJSON(
        keys: [String],
        version: String,
        generatedAt: String = "2026-07-29T08:45:00Z"
    ) -> String {
        let rowsJSON = keys.sorted().enumerated().map { index, key -> String in
            "\(Self.jsonStringLiteral(key)):{\"demand_weight\":0.5,\"rank\":\(index + 1),\"recommendable\":true,\"min_provider_target\":1}"
        }.joined(separator: ",")
        return """
        {"version":"\(version)","generated_at":"\(generatedAt)","source":"macprovider_buyer_supply_deficit_v1","policy_version":"autotune-policy-v1","cold_start_floor":0.15,"diversification_band":0.85,"rows":{\(rowsJSON)}}
        """
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    func testModelArtifactPreflightRejectsMismatch() async throws {
        let snapshot = try makeSnapshot()
        var config = AppConfig.defaults()
        config.model = snapshot.path
        config.modelArtifactSHA256 = String(repeating: "b", count: 64)

        do {
            try await ServeCommand.runModelArtifactPreflight(config)
            XCTFail("artifact mismatch must fail")
        } catch {
            // expected
        }
    }

    func testModelArtifactPreflightRequiresLocalPathWhenHashSet() async throws {
        var config = AppConfig.defaults()
        config.model = "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"
        config.modelArtifactSHA256 = String(repeating: "a", count: 64)

        do {
            try await ServeCommand.runModelArtifactPreflight(config)
            XCTFail("artifact hash must require a local path")
        } catch {
            // expected
        }
    }

    func testModelArtifactPreflightRequiresHashWhenArtifactPathSet() async throws {
        let snapshot = try makeSnapshot()
        var config = AppConfig.defaults()
        config.model = "test-public-model"
        config.modelArtifactPath = snapshot.path

        do {
            try await ServeCommand.runModelArtifactPreflight(config, joiningCoordinator: false)
            XCTFail("artifact path must require a verification hash")
        } catch {
            // expected
        }
    }

    private func makeSnapshot() throws -> URL {
        let root = try tempDir()
        try Data("weights".utf8).write(to: root.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        return root
    }

    private func configWithInvalidArtifact(port: Int) -> AppConfig {
        var config = AppConfig.defaults()
        config.providerID = "mac"
        config.port = port
        config.model = "test-public-model"
        config.modelArtifactPath = "/tmp/macprovider-missing-\(UUID().uuidString)"
        config.modelArtifactSHA256 = String(repeating: "a", count: 64)
        return config
    }

    private func tempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServeCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeSelfUpdateStartupFenceFixture(
        handoffState: ProviderLifecycleStartupHandoff.State,
        handoffExpiresWallMilliseconds: Int64 = 61_000,
        handoffExpiresMonotonicNanoseconds: Int64 = 61_000_000_000,
        commitOwner: String = "self_update",
        updateAuthorityMode: String? = nil,
        transactionState: CompatibilitySetTransactionState? = nil
    ) throws -> (
        executable: URL,
        pending: AutoUpdatePendingMarker,
        lease: ProviderLifecycleLeaseRecord
    ) {
        let root = try tempDir()
        let executable = root.appendingPathComponent("macprovider-cli")
        try Data("v1.8.54 candidate".utf8).write(to: executable)
        let digest = try AutoUpdateMarkerStore.sha256(file: executable)
        let backup = root.appendingPathComponent("macprovider-cli.rollback")
        let backupBytes = Data("v1.8.53 public".utf8)
        try backupBytes.write(to: backup)
        let backupDigest = try AutoUpdateMarkerStore.sha256(file: backup)
        let compatibilityBound = updateAuthorityMode != nil
        let releaseBackup = root.appendingPathComponent(
            "macprovider-cli.release-rollback",
            isDirectory: true
        )
        let handoff = ProviderLifecycleStartupHandoff(
            version: ProviderLifecycleStartupHandoff.schemaVersion,
            handoffID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            state: handoffState,
            operationID: "self-update:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            providerID: "provider-a",
            serviceIdentity: ServeCommand.providerLaunchdServiceIdentity,
            bootSession: "boot-a",
            targetExecutablePath: executable.path,
            targetExecutableSHA256: digest,
            issuedWallMilliseconds: 1_000,
            expiresWallMilliseconds: handoffExpiresWallMilliseconds,
            issuedMonotonicNanoseconds: 1_000_000_000,
            expiresMonotonicNanoseconds: handoffExpiresMonotonicNanoseconds,
            startupLeaseDurationMilliseconds: 300_000
        )
        let lease = ProviderLifecycleLeaseRecord(
            version: ProviderLifecycleLeaseRecord.schemaVersion,
            leaseID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            operationID: handoff.operationID,
            kind: handoffState == .prepared ? .maintenance : .startup,
            owner: ProviderLifecycleLeaseOwner(
                pid: 4_321,
                processStartMicroseconds: 100_000_123,
                bootSession: "boot-a"
            ),
            issuedWallMilliseconds: 1_000,
            expiresWallMilliseconds: 301_000,
            issuedMonotonicNanoseconds: 1_000_000_000,
            expiresMonotonicNanoseconds: 301_000_000_000,
            startupHandoff: handoff
        )
        let pending = AutoUpdatePendingMarker(
            updateID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            targetVersion: "1.8.54",
            targetPath: executable.path,
            backupPath: backup.path,
            size: backupBytes.count,
            mode: 0o755,
            sha256: backupDigest,
            markerDeadline: "2026-07-20T12:00:00Z",
            releaseBackupPath: compatibilityBound ? releaseBackup.path : nil,
            releaseBackupSHA256: compatibilityBound ? String(repeating: "f", count: 64) : nil,
            commitOwner: commitOwner,
            targetCompatibilitySetID: compatibilityBound
                ? "Augustas11/macprovider:v1.8.54@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                : nil,
            targetCompatibilitySetSHA256: compatibilityBound
                ? String(repeating: "b", count: 64)
                : nil,
            previousVersion: compatibilityBound ? "1.8.53" : nil,
            previousCompatibilitySetID: compatibilityBound
                ? "Augustas11/macprovider:v1.8.53@cccccccccccccccccccccccccccccccccccccccc"
                : nil,
            previousCompatibilitySetSHA256: compatibilityBound
                ? String(repeating: "d", count: 64)
                : nil,
            discoveryHeadSequence: updateAuthorityMode == "signed_release" ? 54 : nil,
            discoveryHeadSHA256: updateAuthorityMode == "signed_release"
                ? String(repeating: "e", count: 64)
                : nil,
            updateAuthorityMode: updateAuthorityMode,
            transactionState: compatibilityBound
                ? (transactionState ?? .activatingTarget)
                : nil
        )
        return (executable, pending, lease)
    }

    private func selfUpdateStartupFenceEnvironment(
        bootSession: String = "boot-a",
        processID: pid_t = 5_321,
        launchdServiceProcessID: pid_t? = 5_321
    ) -> ProviderLifecycleLeaseEnvironment {
        ProviderLifecycleLeaseEnvironment(
            wallMilliseconds: { 10_000 },
            monotonicNanoseconds: { 10_000_000_000 },
            bootSession: { bootSession },
            processStartMicroseconds: { _ in nil },
            processID: { processID },
            launchdServiceProcessID: { _ in launchdServiceProcessID }
        )
    }
}
