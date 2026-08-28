import Darwin
import Foundation
import XCTest
@testable import malibu_cli

/// Closes the wire-schema seam between the shell recovery code in
/// `phase3-binary/dist/install.sh` and the Swift lifecycle stores. Three R2
/// audit defects all shared one root cause: the shell invented JSON shapes
/// instead of conforming to the store's real wire schema, and nothing
/// round-tripped shell-emitted JSON through the Swift store (or store-emitted
/// JSON through the shell).
///
/// These tests drive the ACTUAL install.sh functions (extracted and run via
/// bash) so the shell code paths under test are the production ones:
///   * a lease the real `ProviderLifecycleLeaseStore` writes is consumed by the
///     shell `reconcile_lifecycle_lease` decoder (nested owner schema), proving
///     the shell reads what Swift writes; and
///   * a `rollback_in_progress` record the shell `restore_lifecycle_state`
///     translation emits is consumed by the real `ProviderLifecycleStateStore`,
///     proving it parses as valid and permits the serve-writer restart.
final class ProviderLifecycleShellConformanceTests: XCTestCase {
    private var installScriptPath: String {
        // .../phase3-binary/Tests/malibu-cliTests/<thisFile>.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // malibu-cliTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // phase3-binary
            .appendingPathComponent("dist/install.sh")
            .path
    }

    // MARK: - Lease: Swift store writes -> shell reconciler reads (Defect 1)

    /// The real lease store persists the owner NESTED (owner.pid /
    /// owner.process_start_us / owner.boot_session). The shell reconciler must
    /// decode that exact shape: a live foreign-owner lease is preserved, and a
    /// lease bound to the rolled-back install operation is removed. Using the
    /// `.live` environment makes the on-disk owner describe THIS running test
    /// process, so the shell's second-resolution liveness check confirms it.
    func testShellReconcilerPreservesLiveForeignLeaseWrittenByStore() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = directory.appendingPathComponent("lease.json")
        let lockURL = directory.appendingPathComponent(".lease.json.lock")
        let store = ProviderLifecycleLeaseStore(
            url: leaseURL,
            environment: .live
        )
        let record = try store.acquire(
            kind: .maintenance,
            operationID: "unrelated-live-op",
            duration: 20 * 60
        )

        // Sanity: the store wrote the nested owner schema the shell must decode.
        let onDisk = try JSONSerialization.jsonObject(
            with: Data(contentsOf: leaseURL)
        ) as? [String: Any]
        let owner = onDisk?["owner"] as? [String: Any]
        XCTAssertNotNil(owner, "store must persist a nested owner object")
        XCTAssertEqual(owner?["pid"] as? Int, Int(record.owner.pid))
        XCTAssertNil(onDisk?["owner_pid"], "store never emits a flat owner_pid")

        // A foreign live owner (install op does not match) must be PRESERVED.
        let foreignResult = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:some-other-transaction"
        )
        XCTAssertEqual(foreignResult, 0, "reconcile should succeed")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "a live foreign-owner lease must survive reconciliation"
        )
    }

    func testShellReconcilerRemovesLeaseBoundToRolledBackOperation() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = directory.appendingPathComponent("lease.json")
        let lockURL = directory.appendingPathComponent(".lease.json.lock")
        let store = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        _ = try store.acquire(
            kind: .maintenance,
            operationID: "install:this-transaction",
            duration: 20 * 60
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: leaseURL.path))

        let result = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:this-transaction"
        )
        XCTAssertEqual(result, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "a lease bound to the rolled-back install operation must be removed"
        )
    }

    /// EMPIRICAL EXACT-IDENTITY SELF-CHECK (R8 CODE-M): proves the shell
    /// reconciler's owner-liveness now reads the SAME microsecond process-start
    /// the Swift store persists, by driving BOTH sides against THIS running
    /// process. The real `.live` store writes owner.process_start_us for the
    /// current pid (its Swift proc_pidinfo read); the shell reconciler's
    /// process_start_microseconds reads the same pid's kinfo_proc.p_starttime via
    /// sysctl. Because both kernel paths yield identical microseconds, the
    /// live-pid lease is PRESERVED. A byte-identical copy whose
    /// owner.process_start_us is bumped by EXACTLY ONE microsecond is REMOVED --
    /// which can only happen if the shell compares at full microsecond precision
    /// (the former second-truncated compare would have PRESERVED the +1us copy,
    /// since +1us stays in the same whole second). This is the mutation guard for
    /// the exact-identity fix.
    func testShellReconcilerExactMicrosecondIdentityPreservesLivePidAndRemovesPlusOneMicrosecond() throws {
        // POSITIVE: a live-pid store-written lease is PRESERVED (python and Swift
        // read identical microsecond start values from the kernel).
        let preserveDir = try makeTrustedDirectory()
        let preserveURL = preserveDir.appendingPathComponent("lease.json")
        let preserveLock = preserveDir.appendingPathComponent(".lease.json.lock")
        let preserveStore = ProviderLifecycleLeaseStore(url: preserveURL, environment: .live)
        let live = try preserveStore.acquire(
            kind: .maintenance,
            operationID: "exact-identity-live-op",
            duration: 20 * 60
        )
        // Confirm the store wrote a positive microsecond start for THIS process.
        XCTAssertGreaterThan(live.owner.processStartMicroseconds, 0)
        let preserveRC = try runReconcile(
            leaseURL: preserveURL,
            lockURL: preserveLock,
            installOperationID: "install:unrelated-exact-identity"
        )
        XCTAssertEqual(preserveRC, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: preserveURL.path),
            "a live-pid lease with the store's exact microsecond start must be PRESERVED"
        )

        // NEGATIVE: the SAME record with owner.process_start_us + 1 (one
        // microsecond off, still the same whole second) must be REMOVED, proving
        // the shell compares at exact microsecond precision, not second precision.
        let removeDir = try makeTrustedDirectory()
        let removeURL = removeDir.appendingPathComponent("lease.json")
        let removeLock = removeDir.appendingPathComponent(".lease.json.lock")
        guard var mutated = try JSONSerialization.jsonObject(
            with: Data(contentsOf: preserveURL)
        ) as? [String: Any],
              var owner = mutated["owner"] as? [String: Any] else {
            return XCTFail("store lease must decode as JSON with a nested owner")
        }
        owner["process_start_us"] = live.owner.processStartMicroseconds + 1
        mutated["owner"] = owner
        let mutatedData = try JSONSerialization.data(
            withJSONObject: mutated,
            options: [.sortedKeys]
        )
        try (mutatedData + Data([0x0a])).write(to: removeURL)
        // Sanity: THIS is exactly the record Swift would also reject on read
        // (.ownerProcessMissingOrReused), so removing it keeps the shell's
        // preserve-set a subset of Swift's read-acceptance.
        let mutatedStore = ProviderLifecycleLeaseStore(url: removeURL, environment: .live)
        if case .valid = mutatedStore.inspect() {
            XCTFail("store must reject a +1us owner start as invalid")
        }
        let removeRC = try runReconcile(
            leaseURL: removeURL,
            lockURL: removeLock,
            installOperationID: "install:unrelated-exact-identity"
        )
        XCTAssertEqual(removeRC, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: removeURL.path),
            "a lease whose owner start is off by ONE microsecond must be REMOVED"
        )
    }

    /// ADOPTED-handoff conformance (R8 CODE-M): a store-shaped record in the
    /// ADOPTED state (kind=startup, handoff.state=adopted) routes through the
    /// reconciler's ORDINARY owner-liveness path (state != "prepared"), NOT the
    /// prepared-handoff exemption. With a DEAD or MISMATCHED owner it must be
    /// REMOVED -- and with exact microsecond identity this is now deterministic
    /// (a same-second pid reuse is no longer preservable). This mirrors the Swift
    /// side, where adoptStartupHandoff's adopted branch rejects such a record as
    /// leaseNotValid(.ownerProcessMissingOrReused) and the paired CLI fallback
    /// re-acquires fresh rather than restart-looping.
    func testShellReconcilerRemovesAdoptedHandoffRecordWithDeadOwner() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = directory.appendingPathComponent("lease.json")
        let lockURL = directory.appendingPathComponent(".lease.json.lock")
        guard let boot = LeaseHandoffHarness.realBootSession() else {
            throw XCTSkip("kern.bootsessionuuid unavailable")
        }
        let wallNow = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let monoNow = Int64(min(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), UInt64(Int64.max)))
        let recordIssuedWall = wallNow - 5 * 60 * 1_000
        let recordExpiresWall = wallNow + 15 * 60 * 1_000
        let recordIssuedMono = monoNow - 5 * 60 * 1_000_000_000
        let recordExpiresMono = monoNow + 15 * 60 * 1_000_000_000
        // An ADOPTED startup record: kind=startup, handoff.state=adopted. Its
        // owner is a DEAD pid, so owner-liveness must REMOVE it. The handoff
        // window brackets now, so the removal is due to owner death, not a stale
        // window (proving the adopted record flows through owner-liveness, not the
        // prepared-only exemption).
        let handoff: [String: Any] = [
            "version": 1,
            "handoff_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "state": "adopted",
            "operation_id": "adopted-dead-owner-op",
            "provider_id": "provider-a",
            "service_identity": LeaseHandoffHarness.serviceIdentity,
            "boot_session": boot,
            "target_executable_path": LeaseHandoffHarness.targetPath,
            "target_executable_sha256": LeaseHandoffHarness.targetSHA256,
            "issued_wall_ms": wallNow - 60 * 1_000,
            "expires_wall_ms": wallNow + 4 * 60 * 1_000,
            "issued_monotonic_ns": monoNow - 60 * 1_000_000_000,
            "expires_monotonic_ns": monoNow + 4 * 60 * 1_000_000_000,
            "startup_lease_duration_ms": 5 * 60 * 1_000,
        ]
        let record: [String: Any] = [
            "version": 1,
            "lease_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "operation_id": "adopted-dead-owner-op",
            "kind": "startup",
            "owner": [
                "pid": 999_999,
                "process_start_us": 100_000_456,
                "boot_session": boot,
            ] as [String: Any],
            "issued_wall_ms": recordIssuedWall,
            "expires_wall_ms": recordExpiresWall,
            "issued_monotonic_ns": recordIssuedMono,
            "expires_monotonic_ns": recordExpiresMono,
            "startup_handoff": handoff,
        ]
        let recordData = try JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        )
        try (recordData + Data([0x0a])).write(to: leaseURL)
        // Sanity: the store also rejects this adopted record on read (dead owner).
        let decodedStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        if case .valid = decodedStore.inspect() {
            XCTFail("store must not consider an adopted record with a dead owner valid")
        }
        let rc = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:unrelated-adopted-conformance"
        )
        XCTAssertEqual(rc, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "an adopted-handoff record with a dead owner must be removed"
        )
    }

    /// The shell reconciler must not PRESERVE a record Swift's validationFailure
    /// would REJECT for an out-of-window clock, even when the owner is LIVE. The
    /// store's validationFailure runs the shared record boot/wall/monotonic
    /// window checks (ProviderLifecycleLease.swift ~888..894) AFTER structure and
    /// BEFORE either preservation branch, so a live owner cannot rescue an
    /// out-of-window record. The shell's owner_is_live() checks only
    /// pid/boot/process-start, NOT the record windows, so without the shell's
    /// record_shared_validity_ok gate this live-owner lease would be PRESERVED by
    /// the shell yet REJECTED by Swift -- a restart loop for a handoff-bearing
    /// lease (serve only falls back on handoffNotPrepared).
    ///
    /// This test acquires a REAL lease via the `.live` store (stamping THIS
    /// running process as the genuinely-live owner: real pid, real process-start
    /// second, real boot session), then rewrites ONLY the record's four window
    /// fields so the whole window is in the PAST (structurally valid duration
    /// algebra, but expired). The ACTUAL shell reconciler must REMOVE it, and the
    /// real store then self-heals by acquiring a fresh lease.
    func testShellReconcilerRemovesLiveOwnerOutOfWindowRecordThenStoreAcquiresFresh() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = directory.appendingPathComponent("lease.json")
        let lockURL = directory.appendingPathComponent(".lease.json.lock")

        // 1. Acquire a REAL lease: the `.live` environment stamps the owner with
        //    THIS process's live identity (pid alive, real process-start second,
        //    real boot session), so the shell's owner_is_live() returns True.
        let store = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        _ = try store.acquire(
            kind: .startup,
            operationID: "unrelated-live-out-of-window",
            duration: 15 * 60
        )

        // 2. Rewrite ONLY the record's four window fields so the whole window is
        //    in the PAST (issued 20m ago, expired 5m ago) on BOTH the wall and
        //    monotonic axes, keeping monotonicDuration == wallDuration * 1e6 so
        //    the record stays STRUCTURALLY VALID. The owner block is untouched:
        //    the ONLY reason to REMOVE is the shared-validity window gate.
        guard var onDisk = try JSONSerialization.jsonObject(
            with: Data(contentsOf: leaseURL)
        ) as? [String: Any] else {
            return XCTFail("acquired lease is not a JSON object")
        }
        let wallNow = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let monoNow = Int64(min(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), UInt64(Int64.max)))
        let issuedWall = wallNow - 20 * 60 * 1_000
        let expiresWall = wallNow - 5 * 60 * 1_000
        let wallDuration = expiresWall - issuedWall
        let issuedMono = monoNow - 20 * 60 * 1_000_000_000
        let expiresMono = issuedMono + wallDuration * 1_000_000
        onDisk["issued_wall_ms"] = issuedWall
        onDisk["expires_wall_ms"] = expiresWall
        onDisk["issued_monotonic_ns"] = issuedMono
        onDisk["expires_monotonic_ns"] = expiresMono
        let rewritten = try JSONSerialization.data(
            withJSONObject: onDisk,
            options: [.sortedKeys]
        )
        try (rewritten + Data([0x0a])).write(to: leaseURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: leaseURL.path
        )

        // Sanity: the real store does NOT consider this a valid record (its
        // window is expired) even though the owner is live -- proving the shell
        // must not rely on "Swift revalidates".
        let decodedStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        if case .valid = decodedStore.inspect() {
            XCTFail("store must not consider an out-of-window live-owner record valid")
        }

        // 3. Run the ACTUAL shell reconciler with an UNRELATED install operation
        //    id (this is a foreign lease, not the rolled-back transaction).
        let rc = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:unrelated-conformance-transaction"
        )
        XCTAssertEqual(rc, 0, "reconcile should succeed")

        // 4. The out-of-window record must be REMOVED even though the owner is
        //    live (the shared-validity gate).
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "a live-owner record with an expired window must be removed"
        )

        // 5. Self-healing: with the invalid record gone, the REAL store can
        //    acquire a fresh lease.
        let freshStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        let fresh = try freshStore.acquire(
            kind: .startup,
            operationID: "serve:after-out-of-window-removal",
            duration: 5 * 60
        )
        XCTAssertEqual(fresh.kind, .startup)
        XCTAssertNil(fresh.startupHandoff)
        guard case .valid = freshStore.inspect() else {
            return XCTFail("freshly acquired lease must inspect as valid")
        }
    }

    /// The reconciler must not PRESERVE a record that carries a `.prepared`
    /// handoff whose HANDOFF window is expired, even when the OWNER is LIVE. In
    /// Swift's validationFailure the owner process-start liveness check (~904) is
    /// reached ONLY in the ELSE / no-prepared-handoff case: a record WITH a
    /// prepared handoff is governed SOLELY by the handoff-window check (~896..
    /// 901), which returns `.wallExpired` for an expired handoff regardless of
    /// owner liveness. A decision order that ran owner_is_live for ALL records
    /// would PRESERVE this live-owner record yet Swift's inspect() would reject
    /// it -> restart loop (serve only falls back on handoffNotPrepared). This
    /// test acquires a REAL maintenance lease via `.live` (stamping THIS process
    /// as the genuinely-live owner), splices in a `.prepared` handoff with an
    /// EXPIRED window (record window still valid + containing it), runs the
    /// ACTUAL shell reconciler (which must REMOVE it because the record carries a
    /// prepared handoff, routing it exclusively through the handoff-window
    /// exemption), and proves the real store self-heals.
    func testShellReconcilerRemovesLiveOwnerExpiredPreparedHandoffThenStoreAcquiresFresh() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = directory.appendingPathComponent("lease.json")
        let lockURL = directory.appendingPathComponent(".lease.json.lock")

        // 1. Acquire a REAL maintenance lease: `.live` stamps the owner with THIS
        //    process's live identity, so the shell's owner_is_live() would return
        //    True -- making the handoff-window governance the ONLY thing that can
        //    remove it.
        let store = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        _ = try store.acquire(
            kind: .maintenance,
            operationID: "unrelated-live-expired-handoff",
            duration: 19 * 60
        )
        guard var onDisk = try JSONSerialization.jsonObject(
            with: Data(contentsOf: leaseURL)
        ) as? [String: Any] else {
            return XCTFail("acquired lease is not a JSON object")
        }

        let wallNow = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let monoNow = Int64(min(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), UInt64(Int64.max)))
        // Record window: valid + in-bracket, and wide enough to CONTAIN the
        // (expired) handoff window (Swift requires handoff.expires <= record.expires).
        let recordIssuedWall = wallNow - 10 * 60 * 1_000
        let recordExpiresWall = wallNow + 9 * 60 * 1_000
        let recordWallDuration = recordExpiresWall - recordIssuedWall
        let recordIssuedMono = monoNow - 10 * 60 * 1_000_000_000
        let recordExpiresMono = recordIssuedMono + recordWallDuration * 1_000_000
        onDisk["issued_wall_ms"] = recordIssuedWall
        onDisk["expires_wall_ms"] = recordExpiresWall
        onDisk["issued_monotonic_ns"] = recordIssuedMono
        onDisk["expires_monotonic_ns"] = recordExpiresMono

        guard let boot = LeaseHandoffHarness.realBootSession() else {
            throw XCTSkip("kern.bootsessionuuid unavailable")
        }
        // Handoff window: 3.5-min duration (<= 5-min ceiling), issued 4m ago and
        // EXPIRED 30s ago -> Swift's ~900..901 return .wallExpired / .monotonicExpired.
        let handoffIssuedWall = wallNow - 4 * 60 * 1_000
        let handoffExpiresWall = wallNow - 30 * 1_000
        let handoffWallDuration = handoffExpiresWall - handoffIssuedWall
        let handoffIssuedMono = monoNow - 4 * 60 * 1_000_000_000
        let handoffExpiresMono = handoffIssuedMono + handoffWallDuration * 1_000_000
        let operationID = onDisk["operation_id"] as? String ?? "unrelated-live-expired-handoff"
        let handoff: [String: Any] = [
            "version": 1,
            "handoff_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "state": "prepared",
            "operation_id": operationID,
            "provider_id": "provider-a",
            "service_identity": LeaseHandoffHarness.serviceIdentity,
            "boot_session": boot,
            "target_executable_path": LeaseHandoffHarness.targetPath,
            "target_executable_sha256": LeaseHandoffHarness.targetSHA256,
            "issued_wall_ms": handoffIssuedWall,
            "expires_wall_ms": handoffExpiresWall,
            "issued_monotonic_ns": handoffIssuedMono,
            "expires_monotonic_ns": handoffExpiresMono,
            "startup_lease_duration_ms": 5 * 60 * 1_000,
        ]
        onDisk["startup_handoff"] = handoff
        let rewritten = try JSONSerialization.data(
            withJSONObject: onDisk,
            options: [.sortedKeys]
        )
        try (rewritten + Data([0x0a])).write(to: leaseURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: leaseURL.path
        )

        // Sanity: the real store does NOT consider this valid (expired handoff
        // window) even though the owner is live.
        let decodedStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        if case .valid = decodedStore.inspect() {
            XCTFail("store must not consider an expired-handoff live-owner record valid")
        }

        let rc = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:unrelated-conformance-transaction"
        )
        XCTAssertEqual(rc, 0, "reconcile should succeed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "a live-owner record with an expired prepared handoff must be removed"
        )

        // Self-healing: the real store can now acquire a fresh lease.
        let freshStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        let fresh = try freshStore.acquire(
            kind: .startup,
            operationID: "serve:after-expired-handoff-removal",
            duration: 5 * 60
        )
        XCTAssertEqual(fresh.kind, .startup)
        XCTAssertNil(fresh.startupHandoff)
        guard case .valid = freshStore.inspect() else {
            return XCTFail("freshly acquired lease must inspect as valid")
        }
    }

    // MARK: - Lease: prepared-handoff exemption parity (R3 CODE MEDIUM)

    /// The real lease store INTENTIONALLY exempts an unexpired `.prepared`
    /// startup handoff from the owner process-start liveness check so launchd can
    /// adopt the handoff AFTER the maintenance process that prepared it has
    /// exited (validationFailure -> `handoff.state == .prepared` in
    /// ProviderLifecycleLease.swift). The shell reconciler in install.sh must
    /// mirror that cross-process exemption: a foreign lease carrying a valid
    /// prepared handoff on the current boot session must SURVIVE rollback even
    /// though its owner process is gone.
    ///
    /// This test drives the REAL store to prepare a handoff, simulates the
    /// preparer process exiting (its process-start becomes unresolvable while
    /// clocks and boot session stay live/real), runs the ACTUAL shell reconciler
    /// against the store-written file, asserts the file survives byte-for-byte,
    /// and then proves the real store can still ADOPT the untouched handoff --
    /// i.e. the reconciler preserved a genuinely adoptable durable handoff.
    func testShellReconcilerPreservesPreparedHandoffAfterPreparerExitsThenStoreAdopts() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = directory.appendingPathComponent("lease.json")
        let lockURL = directory.appendingPathComponent(".lease.json.lock")

        // A controllable environment with REAL wall/monotonic clocks and the REAL
        // boot session (so the shell reconciler, which reads the same OS clocks
        // and `kern.bootsessionuuid`, agrees on validity), but a scriptable owner
        // identity so we can be the maintenance preparer, then simulate its exit,
        // then become the launchd adopter.
        let harness = LeaseHandoffHarness()
        let store = ProviderLifecycleLeaseStore(url: leaseURL, environment: harness.environment)

        // 1. Acquire a maintenance lease as a live preparer, then prepare a
        //    durable startup handoff (mirrors ProviderLifecycleLeaseTests'
        //    prepareHandoff fixture, but through the real store on a real path).
        let maintenance = try store.acquire(
            kind: .maintenance,
            operationID: "provider-restart-conformance",
            duration: 10 * 60
        )
        let prepared = try store.prepareStartupHandoff(
            maintenanceLeaseID: maintenance.leaseID,
            operationID: maintenance.operationID,
            providerID: "provider-a",
            serviceIdentity: LeaseHandoffHarness.serviceIdentity,
            targetExecutablePath: LeaseHandoffHarness.targetPath,
            targetExecutableSHA256: LeaseHandoffHarness.targetSHA256,
            handoffDuration: 4 * 60,
            startupLeaseDuration: 5 * 60
        )
        XCTAssertEqual(prepared.startupHandoff?.state, .prepared)

        // The exact bytes the store wrote: the reconciler must not mutate them.
        let bytesBeforeReconcile = try Data(contentsOf: leaseURL)

        // 2. Simulate the preparer process exiting: its pid is no longer alive and
        //    its process-start is unresolvable. The record's owner still names
        //    that (now-dead) pid, so an owner-liveness-only reconciler would
        //    delete it. Clocks and boot session remain real and unchanged.
        harness.simulatePreparerExit()

        // 3. Run the ACTUAL shell reconciler with an UNRELATED install operation
        //    id (this is a foreign lease, not the rolled-back transaction).
        let rc = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:unrelated-conformance-transaction"
        )
        XCTAssertEqual(rc, 0, "reconcile should succeed")

        // 4. The valid prepared handoff must be PRESERVED, byte-for-byte.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "a valid prepared handoff with a dead owner must survive rollback"
        )
        let bytesAfterReconcile = try Data(contentsOf: leaseURL)
        XCTAssertEqual(
            bytesAfterReconcile,
            bytesBeforeReconcile,
            "the reconciler must not rewrite a preserved prepared-handoff lease"
        )

        // 5. Prove the preserved handoff is still genuinely adoptable: the
        //    launchd service comes up (a fresh live pid running the exact target
        //    executable) and the REAL store adopts the untouched durable handoff.
        harness.transitionToLaunchdService()
        let startup = try store.adoptStartupHandoff(
            operationID: "provider-restart-conformance",
            providerID: "provider-a",
            serviceIdentity: LeaseHandoffHarness.serviceIdentity
        )
        XCTAssertEqual(startup.kind, .startup)
        XCTAssertEqual(startup.startupHandoff?.state, .adopted)
        XCTAssertEqual(startup.startupHandoff?.handoffID, prepared.startupHandoff?.handoffID)
        XCTAssertEqual(startup.owner.pid, harness.launchdServicePID)
    }

    /// The exemption must NOT rescue an EXPIRED handoff: once the prepared
    /// window has closed, a dead-owner lease follows the ordinary removal path,
    /// exactly as the store's validationFailure returns `.wallExpired` /
    /// `.monotonicExpired` for the same record.
    func testShellReconcilerRemovesExpiredPreparedHandoffWithDeadOwner() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = directory.appendingPathComponent("lease.json")
        let lockURL = directory.appendingPathComponent(".lease.json.lock")

        let harness = LeaseHandoffHarness()
        let store = ProviderLifecycleLeaseStore(url: leaseURL, environment: harness.environment)

        let maintenance = try store.acquire(
            kind: .maintenance,
            operationID: "provider-restart-conformance-expired",
            duration: 10 * 60
        )
        _ = try store.prepareStartupHandoff(
            maintenanceLeaseID: maintenance.leaseID,
            operationID: maintenance.operationID,
            providerID: "provider-a",
            serviceIdentity: LeaseHandoffHarness.serviceIdentity,
            targetExecutablePath: LeaseHandoffHarness.targetPath,
            targetExecutableSHA256: LeaseHandoffHarness.targetSHA256,
            // A short window we will step past before reconciling.
            handoffDuration: 2,
            startupLeaseDuration: 5 * 60
        )

        // The preparer exits and enough real time passes that the handoff window
        // is now closed. The store agrees the record is invalid-or-expired.
        harness.simulatePreparerExit()
        Thread.sleep(forTimeInterval: 2.2)
        if case .valid = store.inspect() {
            XCTFail("store should not still consider the expired handoff valid")
        }

        let rc = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:unrelated-conformance-transaction"
        )
        XCTAssertEqual(rc, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "an expired prepared handoff with a dead owner must be removed"
        )
    }

    /// A record that is store-READABLE (valid JSON in the real wire schema) but
    /// STRUCTURALLY INVALID per Swift's validateStartupHandoffStructure must NOT
    /// be preserved by the shell reconciler's prepared-handoff exemption. The
    /// auditor's example is `kind: "startup"` carrying a `.prepared` startup
    /// handoff: Swift only permits `.maintenance` to carry a prepared handoff, so
    /// its inspect() would reject this as `.invalidField("startup_handoff_state")`.
    /// If the shell PRESERVED it, the restored CLI would inspect() it as invalid,
    /// its fallback only re-acquires on `handoffNotPrepared`, and the provider
    /// would restart-loop. This test writes that record with a dead owner, runs
    /// the ACTUAL shell reconciler (which must REMOVE the file via
    /// record_matches_swift_structure), then proves the real
    /// ProviderLifecycleLeaseStore self-heals by acquiring a fresh lease.
    func testShellReconcilerRemovesStructurallyInvalidPreparedHandoffThenStoreAcquiresFresh() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = directory.appendingPathComponent("lease.json")
        let lockURL = directory.appendingPathComponent(".lease.json.lock")

        // Build the invalid record with REAL clocks + boot session so the ONLY
        // reason the exemption is declined is the structural (kind) invariant --
        // not a stale window or a boot mismatch.
        guard let boot = LeaseHandoffHarness.realBootSession() else {
            throw XCTSkip("kern.bootsessionuuid unavailable")
        }
        let wallNow = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let monoNow = Int64(min(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), UInt64(Int64.max)))

        // Record window: opened 5m ago, closes 15m out (well inside its bounds).
        let recordIssuedWall = wallNow - 5 * 60 * 1_000
        let recordExpiresWall = wallNow + 15 * 60 * 1_000
        let recordIssuedMono = monoNow - 5 * 60 * 1_000_000_000
        let recordExpiresMono = monoNow + 15 * 60 * 1_000_000_000
        // Live handoff window that brackets now and stays inside the record window.
        let handoffIssuedWall = wallNow - 60 * 1_000
        let handoffExpiresWall = wallNow + 4 * 60 * 1_000
        let handoffIssuedMono = monoNow - 60 * 1_000_000_000
        let handoffExpiresMono = monoNow + 4 * 60 * 1_000_000_000

        let handoff: [String: Any] = [
            "version": 1,
            "handoff_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "state": "prepared",
            "operation_id": "provider-restart-invalid-kind",
            "provider_id": "provider-a",
            "service_identity": LeaseHandoffHarness.serviceIdentity,
            "boot_session": boot,
            "target_executable_path": LeaseHandoffHarness.targetPath,
            "target_executable_sha256": LeaseHandoffHarness.targetSHA256,
            "issued_wall_ms": handoffIssuedWall,
            "expires_wall_ms": handoffExpiresWall,
            "issued_monotonic_ns": handoffIssuedMono,
            "expires_monotonic_ns": handoffExpiresMono,
            "startup_lease_duration_ms": 5 * 60 * 1_000,
        ]
        let record: [String: Any] = [
            "version": 1,
            "lease_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "operation_id": "provider-restart-invalid-kind",
            // The invalid invariant: Swift permits ONLY maintenance to carry a
            // prepared handoff. "startup" here is store-readable but rejected.
            "kind": "startup",
            "owner": [
                // A dead pid: the preparer has exited.
                "pid": 999_999,
                "process_start_us": 1,
                "boot_session": boot,
            ] as [String: Any],
            "issued_wall_ms": recordIssuedWall,
            "expires_wall_ms": recordExpiresWall,
            "issued_monotonic_ns": recordIssuedMono,
            "expires_monotonic_ns": recordExpiresMono,
            "startup_handoff": handoff,
        ]
        let recordData = try JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        )
        try (recordData + Data([0x0a])).write(to: leaseURL)

        // Sanity: the record is genuinely store-READABLE JSON (it decodes into a
        // ProviderLifecycleLeaseRecord) yet Swift's own store does NOT consider
        // it valid -- proving the shell must not rely on "Swift revalidates".
        let decodedStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        if case .valid = decodedStore.inspect() {
            XCTFail("store must not consider a kind-startup prepared handoff valid")
        }

        // Run the ACTUAL shell reconciler with an UNRELATED install operation id.
        let rc = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:unrelated-conformance-transaction"
        )
        XCTAssertEqual(rc, 0, "reconcile should succeed")

        // The structurally invalid record must be REMOVED (the self-healing path).
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "a structurally invalid prepared-handoff record must be removed"
        )

        // Prove self-healing: with the invalid record gone, the REAL store can
        // acquire a fresh lease (which it could not have done atop the invalid
        // file if the shell had preserved it -- the CLI's fallback only
        // re-acquires on handoffNotPrepared).
        let freshStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        let fresh = try freshStore.acquire(
            kind: .startup,
            operationID: "serve:after-structural-removal",
            duration: 5 * 60
        )
        XCTAssertEqual(fresh.kind, .startup)
        XCTAssertNil(fresh.startupHandoff)
        guard case .valid = freshStore.inspect() else {
            return XCTFail("freshly acquired lease must inspect as valid")
        }
    }

    // MARK: - Lease: wire-type parity closures (R5 CODE MEDIUM, Findings 1 & 2)

    /// Auditor reproduction 1 (Finding 1): owner.pid decodes as Swift Int32. A
    /// JSON pid of 2147483648 (Int32.max + 1) passes an unbounded positivity
    /// mirror yet FAILS JSONDecoder, so the store's inspect() cannot yield a
    /// valid record. If the shell reconciler had preserved it, the restored CLI
    /// would inspect() it as malformed, its fallback only re-acquires on
    /// handoffNotPrepared, and the provider would restart-loop. The reconciler
    /// must therefore REMOVE the file (fail toward removal), after which the real
    /// store self-heals by acquiring a fresh lease. The record otherwise carries
    /// a live prepared handoff + dead owner, so the ONLY thing that could have
    /// preserved it is the exemption -- which the Int32 bound now declines.
    func testShellReconcilerRemovesInt32OverflowPidPreparedHandoffThenStoreAcquiresFresh() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = directory.appendingPathComponent("lease.json")
        let lockURL = directory.appendingPathComponent(".lease.json.lock")

        guard let boot = LeaseHandoffHarness.realBootSession() else {
            throw XCTSkip("kern.bootsessionuuid unavailable")
        }
        let wallNow = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let monoNow = Int64(min(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), UInt64(Int64.max)))
        let record = Self.preparedHandoffRecordJSON(
            boot: boot,
            wallNow: wallNow,
            monoNow: monoNow,
            operationID: "provider-restart-int32-overflow",
            serviceIdentity: LeaseHandoffHarness.serviceIdentity,
            // Int32.max + 1: an unbounded positivity check would accept this pid,
            // but Swift's JSONDecoder overflows Int32 and the decode fails.
            ownerPID: 2_147_483_648,
            ownerProcessStartUS: 1
        )
        let recordData = try JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        )
        try (recordData + Data([0x0a])).write(to: leaseURL)

        // Sanity: the real store does NOT consider this a valid record (the
        // Int32 pid overflows JSONDecoder -> malformed), so the shell must not
        // rely on "Swift revalidates".
        let decodedStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        if case .valid = decodedStore.inspect() {
            XCTFail("store must not consider an Int32-overflow pid record valid")
        }

        let rc = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:unrelated-conformance-transaction"
        )
        XCTAssertEqual(rc, 0, "reconcile should succeed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "an Int32-overflow pid prepared-handoff record must be removed"
        )

        // Self-healing: the real store can now acquire a fresh lease.
        let freshStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        let fresh = try freshStore.acquire(
            kind: .startup,
            operationID: "serve:after-int32-removal",
            duration: 5 * 60
        )
        XCTAssertEqual(fresh.kind, .startup)
        XCTAssertNil(fresh.startupHandoff)
        guard case .valid = freshStore.inspect() else {
            return XCTFail("freshly acquired lease must inspect as valid")
        }
    }

    /// Auditor reproduction 2 (Finding 2): operation_id is trimmed by Swift with
    /// Foundation's trimmingCharacters(.whitespacesAndNewlines), whose scalar set
    /// includes U+200B (ZERO WIDTH SPACE) while Python str.strip does NOT strip
    /// it. A U+200B-prefixed operation id therefore fails the store's
    /// `trimmed == value` guard (inspect() rejects it) but would PASS a shell
    /// str.strip mirror -> false preserve -> restart loop. The strictly-stricter
    /// printable-ASCII identity rule rejects it, so the reconciler must REMOVE the
    /// file and the store then self-heals. The U+200B is on BOTH record and
    /// handoff operation_id (Swift requires equality) so the id-validity is the
    /// sole rejection cause.
    func testShellReconcilerRemovesZeroWidthSpaceOperationIDPreparedHandoffThenStoreAcquiresFresh() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = directory.appendingPathComponent("lease.json")
        let lockURL = directory.appendingPathComponent(".lease.json.lock")

        guard let boot = LeaseHandoffHarness.realBootSession() else {
            throw XCTSkip("kern.bootsessionuuid unavailable")
        }
        let wallNow = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let monoNow = Int64(min(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), UInt64(Int64.max)))
        // U+200B ZERO WIDTH SPACE prefix. Foundation trims it; Python str.strip
        // does not; the printable-ASCII rule rejects any non-0x21..0x7e scalar.
        let zwspOperationID = "\u{200B}provider-restart-zwsp"
        let record = Self.preparedHandoffRecordJSON(
            boot: boot,
            wallNow: wallNow,
            monoNow: monoNow,
            operationID: zwspOperationID,
            serviceIdentity: LeaseHandoffHarness.serviceIdentity,
            ownerPID: 999_999,
            ownerProcessStartUS: 1
        )
        let recordData = try JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        )
        try (recordData + Data([0x0a])).write(to: leaseURL)

        // Sanity: the real store does NOT consider this valid (Foundation trims
        // the U+200B so operationID != trimmed -> invalid operation_id).
        let decodedStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        if case .valid = decodedStore.inspect() {
            XCTFail("store must not consider a U+200B-prefixed operation id valid")
        }

        let rc = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:unrelated-conformance-transaction"
        )
        XCTAssertEqual(rc, 0, "reconcile should succeed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "a U+200B-prefixed operation-id prepared-handoff record must be removed"
        )

        // Self-healing: the real store can now acquire a fresh lease.
        let freshStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        let fresh = try freshStore.acquire(
            kind: .startup,
            operationID: "serve:after-zwsp-removal",
            duration: 5 * 60
        )
        XCTAssertEqual(fresh.kind, .startup)
        XCTAssertNil(fresh.startupHandoff)
        guard case .valid = freshStore.inspect() else {
            return XCTFail("freshly acquired lease must inspect as valid")
        }
    }

    /// R6 remaining-surface item 2: a store-shaped prepared handoff whose
    /// `target_executable_path` carries a ".." component
    /// ("/Users/a/../macprovider/malibu-cli"). Swift's
    /// validateTargetExecutablePath rejects any path where
    /// `path != URL(fileURLWithPath: path).standardizedFileURL.path`, and
    /// standardizedFileURL resolves the ".." away -- so the real store's
    /// inspect() cannot yield a valid record. The previous shell mirror used
    /// os.path.normpath == value; the R6 closure replaces it with conservative
    /// component rules (no empty / "." / ".." component, no trailing slash), so
    /// the shell REMOVES the file regardless of any normalizer coincidence. If
    /// the shell had PRESERVED it, the restored CLI would inspect() it as
    /// malformed and restart-loop. After removal the real store self-heals via
    /// a fresh acquire(). The store never emits a ".."-containing
    /// target_executable_path (it persists an already-standardized
    /// executablePath(pid)), so this record is corruption/forgery.
    func testShellReconcilerRemovesNonStandardizedTargetPathPreparedHandoffThenStoreAcquiresFresh() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = directory.appendingPathComponent("lease.json")
        let lockURL = directory.appendingPathComponent(".lease.json.lock")

        guard let boot = LeaseHandoffHarness.realBootSession() else {
            throw XCTSkip("kern.bootsessionuuid unavailable")
        }
        let wallNow = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let monoNow = Int64(min(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), UInt64(Int64.max)))
        // A ".."-containing absolute path: its own os.path.normpath would collapse
        // it, and Foundation's standardizedFileURL resolves the "..". The
        // conservative shell rule rejects any ".." component outright.
        let dotDotTargetPath = "/Users/a/../macprovider/malibu-cli"
        let record = Self.preparedHandoffRecordJSON(
            boot: boot,
            wallNow: wallNow,
            monoNow: monoNow,
            operationID: "provider-restart-target-dotdot",
            serviceIdentity: LeaseHandoffHarness.serviceIdentity,
            ownerPID: 999_999,
            ownerProcessStartUS: 1,
            targetExecutablePath: dotDotTargetPath
        )
        let recordData = try JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        )
        try (recordData + Data([0x0a])).write(to: leaseURL)

        // Sanity: the real store does NOT consider this valid -- standardizedFileURL
        // resolves the ".." so path != standardized -> invalid target_executable_path.
        let decodedStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        if case .valid = decodedStore.inspect() {
            XCTFail("store must not consider a '..'-component target path valid")
        }

        let rc = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:unrelated-conformance-transaction"
        )
        XCTAssertEqual(rc, 0, "reconcile should succeed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "a '..'-component target-path prepared-handoff record must be removed"
        )

        // Self-healing: the real store can now acquire a fresh lease.
        let freshStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        let fresh = try freshStore.acquire(
            kind: .startup,
            operationID: "serve:after-target-path-removal",
            duration: 5 * 60
        )
        XCTAssertEqual(fresh.kind, .startup)
        XCTAssertNil(fresh.startupHandoff)
        guard case .valid = freshStore.inspect() else {
            return XCTFail("freshly acquired lease must inspect as valid")
        }
    }

    /// Auditor reproduction (R6 CODE-M1): the record `version` field decodes as a
    /// Swift Int, and JSONDecoder rejects a JSON boolean for an Int field. The
    /// shell's `record.get("version") != 1` check alone would ACCEPT a JSON
    /// `true`, because Python's `True == 1`. A record whose `version` is the
    /// boolean `true` is therefore store-READABLE-shaped but NOT decodable by the
    /// real store (its inspect() cannot yield a valid record), so preserving it
    /// would restart-loop the provider. The reconciler must apply the non-bool
    /// integer predicate to the version field and REMOVE the file, after which
    /// the real store self-heals by acquiring a fresh lease. The record otherwise
    /// carries a live prepared handoff + dead owner, so the ONLY thing that could
    /// have preserved it is the exemption -- which the version predicate declines.
    func testShellReconcilerRemovesBooleanVersionPreparedHandoffThenStoreAcquiresFresh() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = directory.appendingPathComponent("lease.json")
        let lockURL = directory.appendingPathComponent(".lease.json.lock")

        guard let boot = LeaseHandoffHarness.realBootSession() else {
            throw XCTSkip("kern.bootsessionuuid unavailable")
        }
        let wallNow = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let monoNow = Int64(min(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), UInt64(Int64.max)))
        var record = Self.preparedHandoffRecordJSON(
            boot: boot,
            wallNow: wallNow,
            monoNow: monoNow,
            operationID: "provider-restart-bool-version",
            serviceIdentity: LeaseHandoffHarness.serviceIdentity,
            ownerPID: 999_999,
            ownerProcessStartUS: 1
        )
        // The sole defect: a JSON boolean where an Int version is required.
        record["version"] = true
        let recordData = try JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        )
        try (recordData + Data([0x0a])).write(to: leaseURL)

        // Sanity: the real store does NOT consider this a valid record (the
        // boolean version overflows the Int decode -> malformed), so the shell
        // must not rely on "Swift revalidates".
        let decodedStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        if case .valid = decodedStore.inspect() {
            XCTFail("store must not consider a boolean-version record valid")
        }

        let rc = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:unrelated-conformance-transaction"
        )
        XCTAssertEqual(rc, 0, "reconcile should succeed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "a boolean-version prepared-handoff record must be removed"
        )

        // Self-healing: the real store can now acquire a fresh lease.
        let freshStore = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        let fresh = try freshStore.acquire(
            kind: .startup,
            operationID: "serve:after-bool-version-removal",
            duration: 5 * 60
        )
        XCTAssertEqual(fresh.kind, .startup)
        XCTAssertNil(fresh.startupHandoff)
        guard case .valid = freshStore.inspect() else {
            return XCTFail("freshly acquired lease must inspect as valid")
        }
    }

    /// Builds a store-READABLE-shaped MAINTENANCE lease record carrying a live
    /// `.prepared` startup handoff and a dead owner, so the ONLY preservation
    /// path is the exemption. Callers inject a single boundary-violating field
    /// (an Int32-overflow pid, a non-ASCII operation id, or a non-standardized
    /// target_executable_path) to prove the mirror declines the exemption.
    /// Windows are real-clock-derived so the exemption is declined for the
    /// injected reason, not a stale/expired window.
    private static func preparedHandoffRecordJSON(
        boot: String,
        wallNow: Int64,
        monoNow: Int64,
        operationID: String,
        serviceIdentity: String,
        ownerPID: Int64,
        ownerProcessStartUS: Int64,
        targetExecutablePath: String = LeaseHandoffHarness.targetPath
    ) -> [String: Any] {
        let recordIssuedWall = wallNow - 5 * 60 * 1_000
        let recordExpiresWall = wallNow + 15 * 60 * 1_000
        let recordIssuedMono = monoNow - 5 * 60 * 1_000_000_000
        let recordExpiresMono = monoNow + 15 * 60 * 1_000_000_000
        let handoffIssuedWall = wallNow - 60 * 1_000
        let handoffExpiresWall = wallNow + 4 * 60 * 1_000
        let handoffIssuedMono = monoNow - 60 * 1_000_000_000
        let handoffExpiresMono = monoNow + 4 * 60 * 1_000_000_000

        let handoff: [String: Any] = [
            "version": 1,
            "handoff_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "state": "prepared",
            "operation_id": operationID,
            "provider_id": "provider-a",
            "service_identity": serviceIdentity,
            "boot_session": boot,
            "target_executable_path": targetExecutablePath,
            "target_executable_sha256": LeaseHandoffHarness.targetSHA256,
            "issued_wall_ms": handoffIssuedWall,
            "expires_wall_ms": handoffExpiresWall,
            "issued_monotonic_ns": handoffIssuedMono,
            "expires_monotonic_ns": handoffExpiresMono,
            "startup_lease_duration_ms": 5 * 60 * 1_000,
        ]
        return [
            "version": 1,
            "lease_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "operation_id": operationID,
            "kind": "maintenance",
            "owner": [
                "pid": ownerPID,
                "process_start_us": ownerProcessStartUS,
                "boot_session": boot,
            ] as [String: Any],
            "issued_wall_ms": recordIssuedWall,
            "expires_wall_ms": recordExpiresWall,
            "issued_monotonic_ns": recordIssuedMono,
            "expires_monotonic_ns": recordExpiresMono,
            "startup_handoff": handoff,
        ]
    }

    // MARK: - Lease: trusted-directory gate negatives (R7 CODE LOW 1)

    /// The reconciler's pre-parse storage gate mirrors Swift inspect()'s
    /// validateTrustedDirectory: it declines to preserve (removes) a lease whose
    /// PARENT directory is not a real directory owned by us with mode EXACTLY
    /// 0700 and no extended ACL, because Swift's inspect() returns `.missing`
    /// for such a directory and never reads the lease. These are direct
    /// regression tests for the parent-directory gate (previously only file-level
    /// storage rejections were covered): each builds a live-owner store-shaped
    /// lease under a directory violating one testable trusted-directory rule and
    /// asserts the reconciler REMOVES the lease (or reconciles it as removable)
    /// without crashing. A live owner is used so the ONLY reason to preserve
    /// would be a lax directory gate -- exactly the defect these guard.
    ///
    /// Disabling the directory gate (accepting a lax parent dir) would let at
    /// least the 0755 and symlink cases false-PRESERVE, failing these tests, so
    /// they also mutation-guard the gate.

    /// Parent dir mode 0755 (group/other traversable): Swift's
    /// validateTrustedDirectory requires EXACTLY 0700 -> inspect() `.missing`.
    func testShellReconcilerRemovesLeaseUnderMode0755Directory() throws {
        let directory = try makeTrustedDirectory()
        // Loosen the parent dir to 0755 after building the live-owner lease so
        // the ONLY violation is the directory mode.
        let leaseURL = try acquireLiveLease(in: directory)
        let lockURL = directory.appendingPathComponent(".lease.json.lock")
        XCTAssertEqual(chmod(directory.path, 0o755), 0)

        let rc = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:unrelated-conformance-transaction"
        )
        XCTAssertEqual(rc, 0, "reconcile should succeed without crashing")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "a lease under a 0755 (non-0700) directory must be removed"
        )
    }

    /// Parent dir is a SYMLINK to the real 0700 directory: Swift's
    /// validateTrustedDirectory rejects a symlinked directory (it lstat/O_NOFOLLOW
    /// resolves and refuses) -> inspect() `.missing`. The reconciler's gate uses
    /// lstat on the parent and rejects `S_ISLNK`.
    func testShellReconcilerRemovesLeaseUnderSymlinkDirectory() throws {
        let realDirectory = try makeTrustedDirectory()
        let leaseURL = try acquireLiveLease(in: realDirectory)
        let lockURL = realDirectory.appendingPathComponent(".lease.json.lock")

        // A sibling symlink pointing AT the real 0700 directory. The lease is
        // addressed THROUGH the symlink so the reconciler's parent dir
        // (dirname of the symlinked lease path) is the symlink itself.
        let symlinkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conformance-symlinkdir-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: symlinkDir,
            withDestinationURL: realDirectory
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: symlinkDir) }

        let leaseViaSymlink = symlinkDir.appendingPathComponent("lease.json")
        let lockViaSymlink = symlinkDir.appendingPathComponent(".lease.json.lock")
        _ = leaseURL // real path retained for teardown symmetry
        _ = lockURL

        let rc = try runReconcile(
            leaseURL: leaseViaSymlink,
            lockURL: lockViaSymlink,
            installOperationID: "install:unrelated-conformance-transaction"
        )
        XCTAssertEqual(rc, 0, "reconcile should succeed without crashing")
        // The real lease (reached via the symlinked parent) must be removed: the
        // reconciler declined to preserve it because its parent dir is a symlink.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseViaSymlink.path),
            "a lease whose parent directory is a symlink must be removed"
        )
    }

    /// Parent dir carrying an extended ACL: Swift's validateTrustedDirectory
    /// rejects a directory with a non-mode ACL -> inspect() `.missing`. The
    /// reconciler's lease_dir_has_extended_acl gate declines preservation.
    func testShellReconcilerRemovesLeaseUnderExtendedACLDirectory() throws {
        let directory = try makeTrustedDirectory()
        let leaseURL = try acquireLiveLease(in: directory)
        let lockURL = directory.appendingPathComponent(".lease.json.lock")

        // Add an extended ACL entry to the parent directory via `chmod +a`.
        // The reconciler detects the trailing "+" / numbered ACL entry and
        // declines preservation. If chmod +a is unavailable on this host, skip.
        let chmodRC = try runChmodAddACL(path: directory.path)
        try XCTSkipUnless(chmodRC == 0, "chmod +a unavailable; cannot add an ACL")

        let rc = try runReconcile(
            leaseURL: leaseURL,
            lockURL: lockURL,
            installOperationID: "install:unrelated-conformance-transaction"
        )
        XCTAssertEqual(rc, 0, "reconcile should succeed without crashing")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseURL.path),
            "a lease under a directory carrying an extended ACL must be removed"
        )
    }

    // MARK: - State: shell translation writes -> Swift store reads (Defect 3)

    /// A stale updater-written snapshot must translate into an installer-owned
    /// `rollback_in_progress` record that the REAL state store accepts as valid
    /// and that a serve-writer restart can leave. The translated record must
    /// also preserve the last_restart/last_rejection/last_watchdog journals and
    /// refresh last_update.
    func testShellTranslatedRecordParsesInStoreAndPermitsServeRestart() throws {
        let stateDirectory = try makeTrustedDirectory()
        let stateURL = stateDirectory.appendingPathComponent("state-v1.json")
        let stateLockURL = stateDirectory.appendingPathComponent(".state-v1.json.lock")

        // A recovery bundle holding the updater snapshot to translate.
        let recoveryDir = try makeTrustedDirectory()
        let failedCurrentDir = try makeTrustedDirectory()

        let event: [String: Any] = [
            "sequence": 55,
            "transition_id": "33333333-3333-4333-8333-333333333333",
            "transition_at": "2026-07-15T17:00:00.000Z",
            "state": "update_in_progress",
            "reason_code": "update_admission_pending",
            "writer": "updater",
            "operation_id": "updater-dead-op-9999",
        ]
        let snapshot: [String: Any] = [
            "version": 1,
            "sequence": 55,
            "transition_id": "33333333-3333-4333-8333-333333333333",
            "previous_transition_id": "00000000-0000-4000-8000-000000000000",
            "transition_at": "2026-07-15T17:00:00.000Z",
            "state": "update_in_progress",
            "reason_code": "update_admission_pending",
            "authority": "malibu_cli",
            "writer": "updater",
            "provider_id": "mac",
            "model_id": "qwen3-coder-30b-a3b-instruct",
            "operation_id": "updater-dead-op-9999",
            "operator_paused": false,
            "last_update": event,
            "last_restart": event,
            "last_rejection": event,
            "last_watchdog": event,
        ]
        let snapshotData = try JSONSerialization.data(
            withJSONObject: snapshot,
            options: [.sortedKeys]
        )
        try (snapshotData + Data([0x0a]))
            .write(to: recoveryDir.appendingPathComponent("lifecycle-state-v1.json"))

        // The store dir starts empty (no current record): had_snapshot drives it.
        let rc = try runRestore(
            stateURL: stateURL,
            stateLockURL: stateLockURL,
            recoveryDir: recoveryDir,
            failedCurrentDir: failedCurrentDir,
            hadSnapshot: true,
            installOperationID: "install:conformance"
        )
        XCTAssertEqual(rc, 0, "restore/translation should succeed")

        // The REAL store must accept the translated record as valid.
        let store = ProviderLifecycleStateStore(url: stateURL)
        guard case .valid(let translated) = store.inspect() else {
            return XCTFail("translated record did not inspect as valid")
        }
        XCTAssertEqual(translated.state, .rollbackInProgress)
        XCTAssertEqual(translated.writer, .installer)
        XCTAssertEqual(translated.reasonCode, "install_rollback_restored_translated")
        // Journals Malibu displays: restart/rejection/watchdog preserved from
        // the snapshot; update refreshed to the installer rollback transition.
        XCTAssertEqual(translated.lastRestart?.reasonCode, "update_admission_pending")
        XCTAssertEqual(translated.lastRejection?.reasonCode, "update_admission_pending")
        XCTAssertEqual(translated.lastWatchdog?.reasonCode, "update_admission_pending")
        XCTAssertEqual(translated.lastUpdate?.writer, .installer)
        XCTAssertEqual(translated.lastUpdate?.state, .rollbackInProgress)
        XCTAssertEqual(translated.lastUpdate?.reasonCode, "install_rollback_restored_translated")

        // A serve-writer restart out of the translated record is permitted.
        let restarted = try store.transition(
            to: .startingProvider,
            reasonCode: "serve_invoked",
            writer: .serve,
            providerID: "mac",
            modelID: "qwen3-coder-30b-a3b-instruct",
            operationID: "serve:after-rollback"
        )
        XCTAssertEqual(restarted.state, .startingProvider)
        XCTAssertEqual(restarted.writer, .serve)
        XCTAssertGreaterThan(restarted.sequence, translated.sequence)
    }

    // MARK: - Harness

    /// Extracts the named install.sh functions into a sourceable script.
    private func extractFunctions(_ names: Set<String>) throws -> URL {
        let contents = try String(contentsOfFile: installScriptPath, encoding: .utf8)
        var output: [String] = []
        let lines = contents.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let name: String
            if let range = line.range(of: "()") {
                name = String(line[line.startIndex..<range.lowerBound])
            } else {
                name = ""
            }
            guard names.contains(name) else {
                index += 1
                continue
            }
            var depth = 0
            while index < lines.count {
                let current = lines[index]
                output.append(current)
                depth += current.filter { $0 == "{" }.count
                depth -= current.filter { $0 == "}" }.count
                index += 1
                if depth == 0 { break }
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conformance-functions-\(UUID().uuidString).sh")
        try output.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func runReconcile(
        leaseURL: URL,
        lockURL: URL,
        installOperationID: String
    ) throws -> Int32 {
        let functions = try extractFunctions(["reconcile_lifecycle_lease"])
        let script = """
        set -euo pipefail
        . "$1"
        REC_LIFECYCLE_LEASE_PATH="$2" \
        REC_LIFECYCLE_LEASE_LOCK_PATH="$3" \
        REC_LIFECYCLE_INSTALL_OPERATION_ID="$4" \
          reconcile_lifecycle_lease
        """
        return try runBash(
            script: script,
            arguments: [functions.path, leaseURL.path, lockURL.path, installOperationID]
        )
    }

    private func runRestore(
        stateURL: URL,
        stateLockURL: URL,
        recoveryDir: URL,
        failedCurrentDir: URL,
        hadSnapshot: Bool,
        installOperationID: String
    ) throws -> Int32 {
        let functions = try extractFunctions(["restore_lifecycle_state"])
        let script = """
        set -euo pipefail
        . "$1"
        REC_LIFECYCLE_STATE_PATH="$2" \
        REC_LIFECYCLE_STATE_LOCK_PATH="$3" \
        RECOVERY_DIR="$4" \
        FAILED_CURRENT_DIR="$5" \
        REC_HAD_LIFECYCLE_STATE="$6" \
        REC_LIFECYCLE_INSTALL_OPERATION_ID="$7" \
          restore_lifecycle_state
        """
        return try runBash(
            script: script,
            arguments: [
                functions.path,
                stateURL.path,
                stateLockURL.path,
                recoveryDir.path,
                failedCurrentDir.path,
                hadSnapshot ? "1" : "0",
                installOperationID,
            ]
        )
    }

    private func runBash(script: String, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "bash"] + arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: errData, encoding: .utf8) ?? ""
            if !message.isEmpty {
                XCTFail("shell function exited \(process.terminationStatus): \(message)")
            }
        }
        return process.terminationStatus
    }

    private func makeTrustedDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Acquires a REAL lease via the `.live` store inside `directory`, stamping
    /// THIS running process as the genuinely-live owner (so the shell's
    /// owner_is_live() returns True and the ONLY reason the reconciler could
    /// REMOVE the lease is a storage/directory gate, not owner death). Returns
    /// the lease URL.
    private func acquireLiveLease(in directory: URL) throws -> URL {
        let leaseURL = directory.appendingPathComponent("lease.json")
        let store = ProviderLifecycleLeaseStore(url: leaseURL, environment: .live)
        _ = try store.acquire(
            kind: .startup,
            operationID: "unrelated-live-trusted-dir",
            duration: 15 * 60
        )
        return leaseURL
    }

    /// Adds an extended ACL entry to `path` via `/bin/chmod +a`. Returns the
    /// process exit status (0 = ACL added). Used to build the extended-ACL
    /// directory negative; callers skip when it is unavailable.
    private func runChmodAddACL(path: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// A lease environment that reads the REAL OS wall/monotonic clocks and the REAL
/// boot session -- so a cross-process shell reconciler observing the same OS
/// agrees on validity -- while scripting the owner identity so a test can be the
/// maintenance preparer, simulate its exit, then become the launchd adopter.
///
/// The clock and boot sources are byte-for-byte the same primitives as
/// ProviderLifecycleLeaseEnvironment.live (Date-based wall milliseconds,
/// CLOCK_MONOTONIC_RAW nanoseconds, `kern.bootsessionuuid`), which is exactly
/// what makes the prepared-handoff window the store writes comparable to the
/// window the install.sh reconciler reads.
private final class LeaseHandoffHarness: @unchecked Sendable {
    static let targetPath = "/Applications/MacProvider.app/Contents/MacOS/malibu-cli"
    static let targetSHA256 = String(repeating: "a", count: 64)
    static let serviceIdentity = "live.malibu.provider"

    // A pid that is guaranteed NOT to be alive on the host, so the shell
    // reconciler's owner-liveness check fails and preservation can only come
    // from the prepared-handoff exemption.
    let preparerPID: pid_t = 999_999
    let launchdServicePID: pid_t = 999_998

    private let lock = NSLock()
    private var pid: pid_t
    private var starts: [pid_t: Int64]
    private var launchdPIDs: [String: pid_t] = [:]
    private var executablePaths: [pid_t: String] = [:]

    init() {
        pid = preparerPID
        starts = [preparerPID: 100_000_123, launchdServicePID: 100_000_456]
    }

    /// The preparer process exits: its pid is no longer running and its
    /// process-start is unresolvable, while everything else stays live/real.
    func simulatePreparerExit() {
        lock.lock()
        starts[preparerPID] = nil
        lock.unlock()
    }

    /// The launchd service comes up running the exact target executable, and the
    /// current owner identity becomes that service (the adopter).
    func transitionToLaunchdService() {
        lock.lock()
        pid = launchdServicePID
        launchdPIDs[LeaseHandoffHarness.serviceIdentity] = launchdServicePID
        executablePaths[launchdServicePID] = LeaseHandoffHarness.targetPath
        lock.unlock()
    }

    var environment: ProviderLifecycleLeaseEnvironment {
        ProviderLifecycleLeaseEnvironment(
            wallMilliseconds: {
                Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
            },
            monotonicNanoseconds: {
                let value = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
                return value > UInt64(Int64.max) ? Int64.max : Int64(value)
            },
            bootSession: { LeaseHandoffHarness.realBootSession() },
            processStartMicroseconds: { [weak self] pid in
                guard let self = self else { return nil }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.starts[pid] ?? nil
            },
            processID: { [weak self] in self?.currentPID() ?? -1 },
            launchdServiceProcessID: { [weak self] service in
                guard let self = self else { return nil }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.launchdPIDs[service]
            },
            executablePath: { [weak self] pid in
                guard let self = self else { return nil }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.executablePaths[pid]
            },
            executableSHA256: { path in
                path == LeaseHandoffHarness.targetPath ? LeaseHandoffHarness.targetSHA256 : nil
            }
        )
    }

    private func currentPID() -> pid_t {
        lock.lock(); defer { lock.unlock() }
        return pid
    }

    static func realBootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        let value = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
