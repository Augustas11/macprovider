import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

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
        // .../phase3-binary/Tests/macprovider-cliTests/<thisFile>.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // macprovider-cliTests
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
            "authority": "macprovider_cli",
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
    static let targetPath = "/Applications/MacProvider.app/Contents/MacOS/macprovider-cli"
    static let targetSHA256 = String(repeating: "a", count: 64)
    static let serviceIdentity = "live.streamvc.macprovider"

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

    private static func realBootSession() -> String? {
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
