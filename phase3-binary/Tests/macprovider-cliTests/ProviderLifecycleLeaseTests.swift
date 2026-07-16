import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderLifecycleLeaseTests: XCTestCase {
    func testAcquirePersistsOwnerOnlyAtomicJSONAndInspectsAsValid() throws {
        let fixture = try makeFixture()
        let record = try fixture.store.acquire(
            kind: .startup,
            operationID: "startup-transition-1",
            duration: 30 * 60
        )

        guard case .valid(let inspected) = fixture.store.inspect() else {
            return XCTFail("expected a valid lease")
        }
        XCTAssertEqual(inspected, record)
        XCTAssertEqual(record.kind, .startup)
        XCTAssertEqual(record.owner.pid, 4_321)
        XCTAssertEqual(record.owner.processStartMicroseconds, 99_000_123)
        XCTAssertEqual(record.owner.bootSession, "boot-a")
        XCTAssertEqual(record.expiresWallMilliseconds - record.issuedWallMilliseconds, 30 * 60 * 1_000)
        XCTAssertEqual(
            record.expiresMonotonicNanoseconds - record.issuedMonotonicNanoseconds,
            30 * 60 * 1_000_000_000
        )

        var info = stat()
        XCTAssertEqual(lstat(fixture.url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, S_IRUSR | S_IWUSR)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertEqual(info.st_nlink, 1)

        let decoded = try JSONDecoder().decode(
            ProviderLifecycleLeaseRecord.self,
            from: Data(contentsOf: fixture.url)
        )
        XCTAssertEqual(decoded, record)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testDurationCapsAreEnforcedForBothLeaseKinds() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(
            try fixture.store.acquire(kind: .startup, operationID: "too-long", duration: 30 * 60 + 0.001)
        ) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleLeaseError,
                .invalidDuration(kind: .startup, maximumMilliseconds: 30 * 60 * 1_000)
            )
        }
        XCTAssertThrowsError(
            try fixture.store.acquire(kind: .maintenance, operationID: "too-long", duration: 20 * 60 + 0.001)
        ) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleLeaseError,
                .invalidDuration(kind: .maintenance, maximumMilliseconds: 20 * 60 * 1_000)
            )
        }

        let startup = try fixture.store.acquire(
            kind: .startup,
            operationID: "startup-boundary",
            duration: 30 * 60
        )
        XCTAssertTrue(try fixture.store.clear(ifLeaseID: startup.leaseID))
        let maintenance = try fixture.store.acquire(
            kind: .maintenance,
            operationID: "maintenance-boundary",
            duration: 20 * 60
        )
        XCTAssertEqual(
            maintenance.expiresWallMilliseconds - maintenance.issuedWallMilliseconds,
            20 * 60 * 1_000
        )
    }

    func testActiveLeaseRejectsAnotherOperationAndSameOwnerOperationIsIdempotent() throws {
        let fixture = try makeFixture()
        let first = try fixture.store.acquire(
            kind: .maintenance,
            operationID: "update-1",
            duration: 300
        )

        let repeated = try fixture.store.acquire(
            kind: .maintenance,
            operationID: "update-1",
            duration: 60
        )
        XCTAssertEqual(repeated, first)

        XCTAssertThrowsError(
            try fixture.store.acquire(kind: .maintenance, operationID: "update-2", duration: 60)
        ) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .alreadyHeld(first))
        }
    }

    func testRenewRequiresLeaseIDAndExactOwnerIdentity() throws {
        let fixture = try makeFixture()
        let first = try fixture.store.acquire(
            kind: .maintenance,
            operationID: "catalog-migration",
            duration: 120
        )
        fixture.environment.advance(wallMilliseconds: 5_000, monotonicNanoseconds: 5_000_000_000)

        XCTAssertThrowsError(try fixture.store.renew(leaseID: UUID().uuidString, duration: 120)) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .compareAndSwapFailed)
        }

        let renewed = try fixture.store.renew(leaseID: first.leaseID, duration: 120)
        XCTAssertEqual(renewed.leaseID, first.leaseID)
        XCTAssertEqual(renewed.operationID, first.operationID)
        XCTAssertEqual(renewed.issuedWallMilliseconds, first.issuedWallMilliseconds + 5_000)

        fixture.environment.setProcessStart(99_000_124, for: 4_321)
        XCTAssertThrowsError(try fixture.store.renew(leaseID: first.leaseID, duration: 120)) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleLeaseError,
                .leaseNotValid(.ownerProcessMissingOrReused)
            )
        }
    }

    func testInspectionRequiresBothWallAndMonotonicDeadlines() throws {
        let wallFixture = try makeFixture()
        let wallLease = try wallFixture.store.acquire(
            kind: .maintenance,
            operationID: "wall-expiry",
            duration: 60
        )
        wallFixture.environment.advance(wallMilliseconds: 60_000, monotonicNanoseconds: 1)
        XCTAssertEqual(
            wallFixture.store.inspect(),
            .invalidOrExpired(record: wallLease, reason: .wallExpired)
        )

        let monotonicFixture = try makeFixture()
        let monotonicLease = try monotonicFixture.store.acquire(
            kind: .maintenance,
            operationID: "monotonic-expiry",
            duration: 60
        )
        monotonicFixture.environment.advance(wallMilliseconds: 1, monotonicNanoseconds: 60_000_000_000)
        XCTAssertEqual(
            monotonicFixture.store.inspect(),
            .invalidOrExpired(record: monotonicLease, reason: .monotonicExpired)
        )
    }

    func testExpiredOrOwnerDeadLeaseCanBeAtomicallyReplaced() throws {
        let fixture = try makeFixture()
        let first = try fixture.store.acquire(kind: .maintenance, operationID: "old", duration: 60)
        fixture.environment.setProcessStart(nil, for: 4_321)
        XCTAssertEqual(
            fixture.store.inspect(),
            .invalidOrExpired(record: first, reason: .ownerProcessMissingOrReused)
        )

        fixture.environment.setProcessStart(101_000_999, for: 4_321)
        let replacement = try fixture.store.acquire(kind: .startup, operationID: "new", duration: 60)
        XCTAssertNotEqual(replacement.leaseID, first.leaseID)
        XCTAssertEqual(replacement.owner.processStartMicroseconds, 101_000_999)
        XCTAssertEqual(fixture.store.inspect(), .valid(replacement))
    }

    func testBootSessionChangeInvalidatesLease() throws {
        let fixture = try makeFixture()
        let record = try fixture.store.acquire(kind: .startup, operationID: "boot-bound", duration: 60)
        fixture.environment.setBootSession("boot-b")
        fixture.environment.setTimes(wallMilliseconds: 1_000, monotonicNanoseconds: 1_000)

        XCTAssertEqual(
            fixture.store.inspect(),
            .invalidOrExpired(record: record, reason: .bootSessionChanged)
        )
    }

    func testClearIsLeaseIDCompareAndSwap() throws {
        let fixture = try makeFixture()
        let record = try fixture.store.acquire(kind: .startup, operationID: "clear-cas", duration: 60)

        XCTAssertFalse(try fixture.store.clear(ifLeaseID: UUID().uuidString))
        XCTAssertEqual(fixture.store.inspect(), .valid(record))
        XCTAssertTrue(try fixture.store.clear(ifLeaseID: record.leaseID))
        XCTAssertEqual(fixture.store.inspect(), .missing)
        XCTAssertFalse(try fixture.store.clear(ifLeaseID: record.leaseID))
    }

    func testMaintenanceOwnerPreparesExactDurableHandoffAndLaunchdServiceAdoptsIt() throws {
        let fixture = try makeFixture()
        let prepared = try prepareHandoff(fixture)
        let handoff = try XCTUnwrap(prepared.startupHandoff)

        XCTAssertEqual(prepared.kind, .maintenance)
        XCTAssertEqual(handoff.state, .prepared)
        XCTAssertEqual(handoff.operationID, "provider-restart-1")
        XCTAssertEqual(handoff.providerID, "provider-a")
        XCTAssertEqual(handoff.serviceIdentity, LeaseTestEnvironment.serviceIdentity)
        XCTAssertEqual(handoff.bootSession, "boot-a")
        XCTAssertEqual(handoff.targetExecutablePath, LeaseTestEnvironment.targetPath)
        XCTAssertEqual(handoff.targetExecutableSHA256, LeaseTestEnvironment.targetSHA256)
        XCTAssertEqual(handoff.expiresWallMilliseconds - handoff.issuedWallMilliseconds, 60_000)

        fixture.environment.setProcessStart(nil, for: 4_321)
        XCTAssertEqual(fixture.store.inspect(), .valid(prepared))
        fixture.environment.transitionToLaunchdService(pid: 5_321, processStart: 100_000_456)

        let startup = try fixture.store.adoptStartupHandoff(
            operationID: "provider-restart-1",
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity
        )
        XCTAssertEqual(startup.kind, .startup)
        XCTAssertNotEqual(startup.leaseID, prepared.leaseID)
        XCTAssertEqual(startup.owner.pid, 5_321)
        XCTAssertEqual(startup.owner.processStartMicroseconds, 100_000_456)
        XCTAssertEqual(startup.startupHandoff?.handoffID, handoff.handoffID)
        XCTAssertEqual(startup.startupHandoff?.state, .adopted)
        XCTAssertEqual(
            startup.expiresWallMilliseconds - startup.issuedWallMilliseconds,
            5 * 60 * 1_000
        )
        XCTAssertEqual(fixture.store.inspect(), .valid(startup))
    }

    func testServeStartupLeaseFallsBackOnlyWhenNoHandoffExists() throws {
        let fixture = try makeFixture()

        let startup = try ServeCommand.acquireStartupLifecycleLease(
            store: fixture.store,
            operationID: "ordinary-serve",
            providerID: "provider-a",
            duration: 5 * 60
        )

        XCTAssertEqual(startup.kind, .startup)
        XCTAssertEqual(startup.operationID, "ordinary-serve")
        XCTAssertNil(startup.startupHandoff)
    }

    func testServeStartupLeaseAdoptsPreparedHandoffAndCarriesOperationID() throws {
        let fixture = try makeFixture()
        let prepared = try prepareHandoff(fixture)
        fixture.environment.setProcessStart(nil, for: 4_321)
        fixture.environment.transitionToLaunchdService(pid: 5_321, processStart: 100_000_456)

        XCTAssertEqual(
            ServeCommand.startupHandoffOperationID(in: fixture.store),
            "provider-restart-1"
        )
        let startup = try ServeCommand.acquireStartupLifecycleLease(
            store: fixture.store,
            operationID: "provider-restart-1",
            providerID: "provider-a",
            duration: 5 * 60
        )

        XCTAssertEqual(startup.kind, .startup)
        XCTAssertEqual(startup.operationID, prepared.operationID)
        XCTAssertEqual(startup.startupHandoff?.state, .adopted)
    }

    func testServeStartupLeaseDoesNotFallbackOnPreparedIdentityMismatch() throws {
        let fixture = try makeFixture()
        let prepared = try prepareHandoff(fixture)
        fixture.environment.setProcessStart(nil, for: 4_321)
        fixture.environment.transitionToLaunchdService(pid: 5_321, processStart: 100_000_456)

        XCTAssertThrowsError(try ServeCommand.acquireStartupLifecycleLease(
            store: fixture.store,
            operationID: "provider-restart-1",
            providerID: "provider-b",
            duration: 5 * 60
        )) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .handoffMismatch("provider_id"))
        }
        XCTAssertEqual(fixture.store.inspect(), .valid(prepared))
    }

    /// An ADOPTED-state handoff record whose OWNER identity is no longer valid
    /// (crash + launchd restart + PID reuse: the live pid's process-start no
    /// longer matches the record) makes adoptStartupHandoff's adopted branch
    /// throw leaseNotValid(.ownerProcessMissingOrReused). Serve startup must FALL
    /// BACK to a fresh startup acquisition (not restart-loop): the record denotes
    /// an invalid/expired/wrong-owner RECORD, not a live conflicting owner.
    func testServeStartupLeaseFallsBackWhenAdoptedRecordOwnerIdentityInvalid() throws {
        let fixture = try makeFixture()
        _ = try prepareHandoff(fixture)
        fixture.environment.setProcessStart(nil, for: 4_321)
        fixture.environment.transitionToLaunchdService(pid: 5_321, processStart: 100_000_456)

        // First startup adopts the prepared handoff, producing an ADOPTED record
        // owned by pid 5_321 / process-start 100_000_456.
        let adopted = try ServeCommand.acquireStartupLifecycleLease(
            store: fixture.store,
            operationID: "provider-restart-1",
            providerID: "provider-a",
            duration: 5 * 60
        )
        XCTAssertEqual(adopted.kind, .startup)
        XCTAssertEqual(adopted.startupHandoff?.state, .adopted)
        XCTAssertEqual(adopted.owner.processStartMicroseconds, 100_000_456)

        // Simulate a crash + launchd restart that REUSED pid 5_321 with a
        // DIFFERENT process-start. The adopted record's owner identity is now
        // stale: adoptStartupHandoff's adopted branch rejects it as
        // .ownerProcessMissingOrReused (leaseNotValid).
        fixture.environment.setProcessStart(200_000_999, for: 5_321)
        XCTAssertEqual(
            fixture.store.inspect(),
            .invalidOrExpired(record: adopted, reason: .ownerProcessMissingOrReused)
        )

        // The restarted process re-invokes startup with the SAME operation/provider
        // identity the handoff was prepared for, so adoptStartupHandoff reaches its
        // adopted branch and throws leaseNotValid(.ownerProcessMissingOrReused).
        // The new fallback must replace the invalid record with a fresh startup
        // lease owned by the live process rather than throwing.
        let fresh = try ServeCommand.acquireStartupLifecycleLease(
            store: fixture.store,
            operationID: "provider-restart-1",
            providerID: "provider-a",
            duration: 5 * 60
        )
        XCTAssertEqual(fresh.kind, .startup)
        XCTAssertEqual(fresh.operationID, "provider-restart-1")
        XCTAssertNotEqual(fresh.leaseID, adopted.leaseID)
        XCTAssertEqual(fresh.owner.pid, 5_321)
        XCTAssertEqual(fresh.owner.processStartMicroseconds, 200_000_999)
        // Fresh acquisition mints a plain startup lease (no adopted handoff).
        XCTAssertNil(fresh.startupHandoff)
        XCTAssertEqual(fixture.store.inspect(), .valid(fresh))
    }

    /// A VALID live foreign owner (no handoff on disk) must still be a HARD
    /// failure: the leaseNotValid fallback path must NOT bypass acquire()'s
    /// refusal to displace a valid live owner. Here adoptStartupHandoff throws
    /// handoffNotPrepared (no handoff), the fallback calls acquire(), and
    /// acquire() re-validates the live foreign owner and throws .alreadyHeld --
    /// the unchanged startup_lease_unavailable outcome.
    func testServeStartupLeaseStillFailsHardWhenValidLiveForeignOwnerHoldsLease() throws {
        let fixture = try makeFixture()
        // A foreign owner (current pid 4_321) holds a valid, live startup lease
        // with an unrelated operation and no handoff.
        let foreign = try fixture.store.acquire(
            kind: .startup,
            operationID: "foreign-live-op",
            duration: 20 * 60
        )
        XCTAssertEqual(fixture.store.inspect(), .valid(foreign))

        XCTAssertThrowsError(try ServeCommand.acquireStartupLifecycleLease(
            store: fixture.store,
            operationID: "different-startup-op",
            providerID: "provider-a",
            duration: 5 * 60
        )) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .alreadyHeld(foreign))
        }
        // The valid live foreign lease is untouched.
        XCTAssertEqual(fixture.store.inspect(), .valid(foreign))
    }

    func testHandoffPreparationAndAdoptionAreResponseLossIdempotentButNotReplayable() throws {
        let fixture = try makeFixture()
        let firstPrepared = try prepareHandoff(fixture)
        fixture.environment.advance(wallMilliseconds: 1_000, monotonicNanoseconds: 1_000_000_000)
        let repeatedPrepared = try fixture.store.prepareStartupHandoff(
            maintenanceLeaseID: firstPrepared.leaseID,
            operationID: "provider-restart-1",
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity,
            targetExecutablePath: LeaseTestEnvironment.targetPath,
            targetExecutableSHA256: LeaseTestEnvironment.targetSHA256,
            handoffDuration: 60,
            startupLeaseDuration: 5 * 60
        )
        XCTAssertEqual(repeatedPrepared, firstPrepared)

        fixture.environment.setProcessStart(nil, for: 4_321)
        fixture.environment.transitionToLaunchdService(pid: 5_321, processStart: 100_000_456)
        let firstAdoption = try fixture.store.adoptStartupHandoff(
            operationID: "provider-restart-1",
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity
        )
        let repeatedAdoption = try fixture.store.adoptStartupHandoff(
            operationID: "provider-restart-1",
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity
        )
        XCTAssertEqual(repeatedAdoption, firstAdoption)

        fixture.environment.setCurrentPID(6_321, processStart: 101_000_789)
        fixture.environment.setExecutablePath(LeaseTestEnvironment.targetPath, for: 6_321)
        XCTAssertThrowsError(try fixture.store.adoptStartupHandoff(
            operationID: "provider-restart-1",
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity
        )) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .compareAndSwapFailed)
        }

        fixture.environment.setCurrentPID(5_321, processStart: 100_000_456)
        XCTAssertTrue(try fixture.store.clear(ifLeaseID: firstAdoption.leaseID))
        XCTAssertThrowsError(try fixture.store.adoptStartupHandoff(
            operationID: "provider-restart-1",
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity
        )) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .handoffNotPrepared)
        }
    }

    func testHandoffAdoptionRequiresExactOperationProviderAndServiceIdentity() throws {
        let fixture = try makeFixture()
        _ = try prepareHandoff(fixture)

        XCTAssertThrowsError(try fixture.store.adoptStartupHandoff(
            operationID: "different-operation",
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity
        )) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .handoffMismatch("operation_id"))
        }
        XCTAssertThrowsError(try fixture.store.adoptStartupHandoff(
            operationID: "provider-restart-1",
            providerID: "provider-b",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity
        )) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .handoffMismatch("provider_id"))
        }
        XCTAssertThrowsError(try fixture.store.adoptStartupHandoff(
            operationID: "provider-restart-1",
            providerID: "provider-a",
            serviceIdentity: "live.streamvc.other"
        )) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .handoffMismatch("service_identity"))
        }
    }

    func testHandoffAdoptionRejectsUnrelatedSameUIDPIDAndWrongBootSession() throws {
        let pidFixture = try makeFixture()
        _ = try prepareHandoff(pidFixture)
        pidFixture.environment.setProcessStart(nil, for: 4_321)
        pidFixture.environment.transitionToLaunchdService(pid: 5_321, processStart: 100_000_456)
        pidFixture.environment.setCurrentPID(6_321, processStart: 101_000_789)
        pidFixture.environment.setExecutablePath(LeaseTestEnvironment.targetPath, for: 6_321)
        XCTAssertThrowsError(try pidFixture.store.adoptStartupHandoff(
            operationID: "provider-restart-1",
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity
        )) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .launchdServiceOwnerMismatch)
        }

        let bootFixture = try makeFixture()
        _ = try prepareHandoff(bootFixture)
        bootFixture.environment.setProcessStart(nil, for: 4_321)
        bootFixture.environment.setBootSession("boot-b")
        bootFixture.environment.transitionToLaunchdService(pid: 5_321, processStart: 100_000_456)
        XCTAssertThrowsError(try bootFixture.store.adoptStartupHandoff(
            operationID: "provider-restart-1",
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity
        )) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .handoffMismatch("boot_session"))
        }
    }

    func testHandoffAdoptionRejectsWrongExecutablePathAndDigest() throws {
        let pathFixture = try makeFixture()
        _ = try prepareHandoff(pathFixture)
        pathFixture.environment.setProcessStart(nil, for: 4_321)
        pathFixture.environment.transitionToLaunchdService(
            pid: 5_321,
            processStart: 100_000_456,
            executablePath: "/tmp/attacker/macprovider-cli"
        )
        XCTAssertThrowsError(try pathFixture.store.adoptStartupHandoff(
            operationID: "provider-restart-1",
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity
        )) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .targetExecutableMismatch)
        }

        let hashFixture = try makeFixture()
        _ = try prepareHandoff(hashFixture)
        hashFixture.environment.setProcessStart(nil, for: 4_321)
        hashFixture.environment.transitionToLaunchdService(
            pid: 5_321,
            processStart: 100_000_456,
            executableSHA256: String(repeating: "b", count: 64)
        )
        XCTAssertThrowsError(try hashFixture.store.adoptStartupHandoff(
            operationID: "provider-restart-1",
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity
        )) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .targetExecutableMismatch)
        }
    }

    func testExpiredPreparedHandoffCannotBeAdoptedOrExtendWatchdogGrace() throws {
        let fixture = try makeFixture()
        let prepared = try prepareHandoff(fixture, handoffDuration: 30)
        fixture.environment.setProcessStart(nil, for: 4_321)
        fixture.environment.transitionToLaunchdService(pid: 5_321, processStart: 100_000_456)
        fixture.environment.advance(
            wallMilliseconds: 30_000,
            monotonicNanoseconds: 30_000_000_000
        )

        XCTAssertEqual(
            fixture.store.inspect(),
            .invalidOrExpired(record: prepared, reason: .wallExpired)
        )
        XCTAssertThrowsError(try fixture.store.adoptStartupHandoff(
            operationID: "provider-restart-1",
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity
        )) { error in
            XCTAssertEqual(error as? ProviderLifecycleLeaseError, .handoffExpired)
        }
    }

    func testSymlinkLeaseIsRejectedAndNeverReplaced() throws {
        let fixture = try makeFixture()
        let target = fixture.directory.appendingPathComponent("attacker.json")
        try Data("{}".utf8).write(to: target)
        XCTAssertEqual(chmod(target.path, S_IRUSR | S_IWUSR), 0)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)

        XCTAssertEqual(
            fixture.store.inspect(),
            .invalidOrExpired(record: nil, reason: .unsafeStorage("symlink"))
        )
        XCTAssertThrowsError(
            try fixture.store.acquire(kind: .startup, operationID: "must-not-replace", duration: 60)
        ) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleLeaseError,
                .unsafeStorage(path: fixture.url.path, reason: "symlink")
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testHardLinkedLeaseIsRejectedAndNeverReplaced() throws {
        let fixture = try makeFixture()
        _ = try fixture.store.acquire(kind: .startup, operationID: "hard-link", duration: 60)
        let secondName = fixture.directory.appendingPathComponent("second-name.json")
        try FileManager.default.linkItem(at: fixture.url, to: secondName)

        XCTAssertEqual(
            fixture.store.inspect(),
            .invalidOrExpired(record: nil, reason: .unsafeStorage("hard link"))
        )
        XCTAssertThrowsError(
            try fixture.store.acquire(kind: .startup, operationID: "must-not-replace", duration: 60)
        ) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleLeaseError,
                .unsafeStorage(path: fixture.url.path, reason: "hard link")
            )
        }
    }

    func testWrongOwnerAndBroadModeAreRejected() throws {
        let fixture = try makeFixture()
        _ = try fixture.store.acquire(kind: .startup, operationID: "metadata", duration: 60)

        let wrongOwnerStore = ProviderLifecycleLeaseStore(
            url: fixture.url,
            expectedOwnerUID: getuid() &+ 1,
            environment: fixture.environment.value
        )
        XCTAssertEqual(
            wrongOwnerStore.inspect(),
            .invalidOrExpired(record: nil, reason: .unsafeStorage("wrong owner"))
        )

        XCTAssertEqual(chmod(fixture.url.path, S_IRUSR | S_IWUSR | S_IRGRP), 0)
        XCTAssertEqual(
            fixture.store.inspect(),
            .invalidOrExpired(record: nil, reason: .unsafeStorage("mode is not 0600"))
        )
    }

    func testBroadParentDirectoryAndUnsafeLockAreRejected() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(chmod(fixture.directory.path, 0o755), 0)
        XCTAssertEqual(
            fixture.store.inspect(),
            .invalidOrExpired(record: nil, reason: .unsafeStorage("mode is not 0700"))
        )
        XCTAssertThrowsError(
            try fixture.store.acquire(kind: .startup, operationID: "unsafe-parent", duration: 60)
        ) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleLeaseError,
                .unsafeStorage(path: fixture.directory.path, reason: "mode is not 0700")
            )
        }

        XCTAssertEqual(chmod(fixture.directory.path, 0o700), 0)
        let lockURL = fixture.directory.appendingPathComponent(".lease.json.lock")
        XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data()))
        XCTAssertEqual(chmod(lockURL.path, 0o644), 0)
        XCTAssertThrowsError(
            try fixture.store.acquire(kind: .startup, operationID: "unsafe-lock", duration: 60)
        ) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleLeaseError,
                .unsafeStorage(path: lockURL.path, reason: "mode is not 0600")
            )
        }
    }

    func testMalformedRecordIsReportedAndCannotBeSilentlyReplaced() throws {
        let fixture = try makeFixture()
        try Data("{not-json".utf8).write(to: fixture.url)
        XCTAssertEqual(chmod(fixture.url.path, S_IRUSR | S_IWUSR), 0)

        XCTAssertEqual(
            fixture.store.inspect(),
            .invalidOrExpired(record: nil, reason: .malformedRecord)
        )
        XCTAssertThrowsError(
            try fixture.store.acquire(kind: .maintenance, operationID: "replacement", duration: 60)
        ) { error in
            XCTAssertEqual(
                error as? ProviderLifecycleLeaseError,
                .malformedRecord(path: fixture.url.path)
            )
        }
    }

    private func prepareHandoff(
        _ fixture: LeaseFixture,
        handoffDuration: TimeInterval = 60
    ) throws -> ProviderLifecycleLeaseRecord {
        let maintenance = try fixture.store.acquire(
            kind: .maintenance,
            operationID: "provider-restart-1",
            duration: 10 * 60
        )
        return try fixture.store.prepareStartupHandoff(
            maintenanceLeaseID: maintenance.leaseID,
            operationID: maintenance.operationID,
            providerID: "provider-a",
            serviceIdentity: LeaseTestEnvironment.serviceIdentity,
            targetExecutablePath: LeaseTestEnvironment.targetPath,
            targetExecutableSHA256: LeaseTestEnvironment.targetSHA256,
            handoffDuration: handoffDuration,
            startupLeaseDuration: 5 * 60
        )
    }

    private func makeFixture() throws -> LeaseFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderLifecycleLeaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("lease.json")
        let environment = LeaseTestEnvironment()
        return LeaseFixture(
            directory: directory,
            url: url,
            environment: environment,
            store: ProviderLifecycleLeaseStore(url: url, environment: environment.value)
        )
    }
}

private struct LeaseFixture {
    let directory: URL
    let url: URL
    let environment: LeaseTestEnvironment
    let store: ProviderLifecycleLeaseStore
}

private final class LeaseTestEnvironment: @unchecked Sendable {
    static let targetPath = "/Applications/MacProvider.app/Contents/MacOS/macprovider-cli"
    static let targetSHA256 = String(repeating: "a", count: 64)
    static let serviceIdentity = "live.streamvc.macprovider"

    private let lock = NSLock()
    private var wall: Int64 = 1_784_016_000_000
    private var monotonic: Int64 = 500_000_000_000
    private var boot = "boot-a"
    private var pid: pid_t = 4_321
    private var starts: [pid_t: Int64] = [4_321: 99_000_123]
    private var launchdPIDs: [String: pid_t] = [:]
    private var executablePaths: [pid_t: String] = [:]
    private var executableDigests: [String: String] = [targetPath: targetSHA256]

    var value: ProviderLifecycleLeaseEnvironment {
        ProviderLifecycleLeaseEnvironment(
            wallMilliseconds: { [weak self] in self?.wallValue() ?? -1 },
            monotonicNanoseconds: { [weak self] in self?.monotonicValue() ?? -1 },
            bootSession: { [weak self] in self?.bootValue() },
            processStartMicroseconds: { [weak self] pid in self?.startValue(for: pid) },
            processID: { [weak self] in self?.pidValue() ?? -1 },
            launchdServiceProcessID: { [weak self] service in self?.launchdPIDValue(for: service) },
            executablePath: { [weak self] pid in self?.executablePathValue(for: pid) },
            executableSHA256: { [weak self] path in self?.executableDigestValue(for: path) }
        )
    }

    func advance(wallMilliseconds: Int64, monotonicNanoseconds: Int64) {
        lock.lock()
        wall += wallMilliseconds
        monotonic += monotonicNanoseconds
        lock.unlock()
    }

    func setBootSession(_ value: String) {
        lock.lock()
        boot = value
        lock.unlock()
    }

    func setTimes(wallMilliseconds: Int64, monotonicNanoseconds: Int64) {
        lock.lock()
        wall = wallMilliseconds
        monotonic = monotonicNanoseconds
        lock.unlock()
    }

    func setProcessStart(_ value: Int64?, for pid: pid_t) {
        lock.lock()
        starts[pid] = value
        lock.unlock()
    }

    func transitionToLaunchdService(
        pid: pid_t,
        processStart: Int64,
        serviceIdentity: String = LeaseTestEnvironment.serviceIdentity,
        executablePath: String = LeaseTestEnvironment.targetPath,
        executableSHA256: String = LeaseTestEnvironment.targetSHA256
    ) {
        lock.lock()
        self.pid = pid
        starts[pid] = processStart
        launchdPIDs[serviceIdentity] = pid
        executablePaths[pid] = executablePath
        executableDigests[executablePath] = executableSHA256
        lock.unlock()
    }

    func setCurrentPID(_ value: pid_t, processStart: Int64) {
        lock.lock()
        pid = value
        starts[value] = processStart
        lock.unlock()
    }

    func setLaunchdPID(_ value: pid_t?, for serviceIdentity: String = LeaseTestEnvironment.serviceIdentity) {
        lock.lock()
        launchdPIDs[serviceIdentity] = value
        lock.unlock()
    }

    func setExecutablePath(_ value: String?, for pid: pid_t) {
        lock.lock()
        executablePaths[pid] = value
        lock.unlock()
    }

    func setExecutableSHA256(_ value: String?, for path: String = LeaseTestEnvironment.targetPath) {
        lock.lock()
        executableDigests[path] = value
        lock.unlock()
    }

    private func wallValue() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return wall
    }

    private func monotonicValue() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return monotonic
    }

    private func bootValue() -> String {
        lock.lock()
        defer { lock.unlock() }
        return boot
    }

    private func startValue(for pid: pid_t) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return starts[pid]
    }

    private func pidValue() -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }

    private func launchdPIDValue(for serviceIdentity: String) -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return launchdPIDs[serviceIdentity]
    }

    private func executablePathValue(for pid: pid_t) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return executablePaths[pid]
    }

    private func executableDigestValue(for path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return executableDigests[path]
    }
}
