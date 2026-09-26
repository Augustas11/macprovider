import Darwin
import Foundation
import MacProviderCore

/// Result of staging, verifying, and durably adopting the Lane A artifact.
///
/// Build 1 Lane A only. The durable path is intentionally not carried here so
/// public transaction JSON never leaks a raw private path; the durable root is
/// derivable from `model_artifact_root` / the default provider-owned store.
struct Build1LaneAStagedArtifact: Equatable, Sendable {
    /// `macprovider.snapshot-manifest.v1` digest of the adopted directory.
    var sha256: String
    /// Sum of regular-file bytes in the adopted directory.
    var adoptedBytes: Int64
    /// `true` when a verified durable copy already existed and no bytes were
    /// transferred; the durable store is left exactly as found.
    var reusedDurableArtifact: Bool
    /// `true` when the redundant staging copy could not be removed after a
    /// successful adoption. The adopted artifact is still valid.
    var stagingCleanupRequired: Bool
}

enum Build1LaneAArtifactStagingError: Error, Equatable, Sendable {
    case rootUnavailable(String)
    case authorityUnavailable(String)
    case authorityMismatch
    case operationConflict
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case transferFailed(String)
    case verificationFailed(expected: String, actual: String)
    case publicationFailed(String)
    case timedOut
    case cancelled
}

/// Stage labels emitted through `model_catalog_transaction_event.v1` progress
/// frames while the Lane A artifact moves from signed authority to durable
/// adoption. The order is fixed; a run emits only the stages it reached.
enum Build1LaneAStagingStage: String, CaseIterable, Sendable {
    case staging = "artifact_staging"
    case verified = "artifact_verified"
    case adopted = "artifact_adopted"
}

struct Build1LaneADiskProbe: Equatable, Sendable {
    var availableBytes: Int64
    var deviceID: UInt64
}

/// Stages the exact Lane A MLX snapshot into an isolated hash-qualified
/// directory under the Hugging Face cache, verifies its snapshot-manifest
/// digest against the signed artifact authority, and only then copies it into
/// the provider-owned durable store.
///
/// Invariants preserved on every exit path:
/// - The active model is never touched: nothing here talks to the control
///   socket, the serve runtime, or the YAML config.
/// - An existing canonical Hugging Face snapshot is never modified or deleted.
/// - Failure or cancellation before adoption leaves the durable store as found
///   and removes the isolated staging directory it created.
/// - Adoption happens only after the staged bytes hash to the authority digest.
struct Build1LaneAArtifactStager {
    typealias ProgressSink = (Build1LaneAStagingStage, _ bytesCompleted: Int64?, _ bytesExpected: Int64?) throws -> Void
    typealias Reauthorize = @Sendable () async throws -> Build1LaneAArtifactAuthority

    static let prepareLockLeaf = ".build1-lane-a-prepare.lock"
    /// SPEC-044 preparation reserve: `available >= 2 * estimated_bytes + 1 GiB`
    /// on the bound root volume, before transfer and again before publication.
    static let publicationReserveBytes: Int64 = 1_073_741_824

    /// Test seam mirroring `Build1LaneAArtifactAuthorityResolver.makeStaticInputs`.
    /// Production resolves the durable root from `model_artifact_root` exactly
    /// like `serve` preflight does, so the adopted copy is the one `serve` uses.
    nonisolated(unsafe) static var makeStager: @Sendable (AppConfig?, Date?, @escaping Reauthorize) -> Build1LaneAArtifactStager = { config, deadline, reauthorize in
        Build1LaneAArtifactStager(
            resolver: CachedModelArtifactResolver.forConfig(config),
            reauthorize: reauthorize,
            deadline: deadline
        )
    }

    var resolver: CachedModelArtifactResolver
    /// Re-resolves the signed Lane A authority immediately before publication.
    /// Adoption proceeds only when the fresh authority equals the one that
    /// gated staging, so a feed that is revoked, re-signed, or rebound while
    /// bytes are in flight cannot be adopted against the stale snapshot.
    var reauthorize: Reauthorize
    var diskProbe: @Sendable (URL) throws -> Build1LaneADiskProbe
    var deadline: Date?

    init(
        resolver: CachedModelArtifactResolver,
        reauthorize: @escaping Reauthorize,
        diskProbe: @escaping @Sendable (URL) throws -> Build1LaneADiskProbe = { try Build1LaneAArtifactStager.systemDiskProbe($0) },
        deadline: Date? = nil
    ) {
        self.resolver = resolver
        self.reauthorize = reauthorize
        self.diskProbe = diskProbe
        self.deadline = deadline
    }

    func stageAndAdopt(
        authority: Build1LaneAArtifactAuthority,
        progress: ProgressSink
    ) async throws -> Build1LaneAStagedArtifact {
        let store = resolver.durableStore
        let durable: URL
        do {
            durable = try store.artifactURL(
                modelID: authority.modelID,
                revision: authority.revision,
                sha256: authority.hash
            )
            try store.ensureRoot()
        } catch {
            throw Build1LaneAArtifactStagingError.rootUnavailable(String(describing: error))
        }

        let lock = try acquirePrepareLock(root: store.root)
        defer { lock.release() }

        try checkDeadlineAndCancellation()

        // 1. A verified durable copy already exists: reuse it without touching
        //    anything on disk. Re-running prepare must be idempotent so the
        //    physical journey never re-downloads gigabytes.
        if let reused = try verifiedDurableArtifact(at: durable, store: store, expected: authority.hash) {
            try progress(.verified, reused, reused)
            try progress(.adopted, reused, reused)
            return Build1LaneAStagedArtifact(
                sha256: authority.hash,
                adoptedBytes: reused,
                reusedDurableArtifact: true,
                stagingCleanupRequired: false
            )
        }

        // 2. Locate a staging source. Prefer the isolated hash-qualified
        //    prefetch directory; fall back to a canonical snapshot only when it
        //    already verifies (never repair or delete the canonical snapshot).
        let staged = resolver.prefetchSnapshotURL(
            modelID: authority.modelID,
            revision: authority.revision,
            sha256: authority.hash
        )
        let canonical = resolver.snapshotURL(modelID: authority.modelID, revision: authority.revision)
        var source: URL?
        var createdStaging = false
        if isDirectory(staged) {
            if try verifies(staged, expected: authority.hash) {
                source = staged
            } else {
                // Stale or corrupt isolated staging from an earlier run: it is
                // ours to reclaim, and it never held the active model.
                try? FileManager.default.removeItem(at: staged)
            }
        }
        if source == nil, isDirectory(canonical), try verifies(canonical, expected: authority.hash) {
            source = canonical
        }

        try checkDeadlineAndCancellation()

        let expected = Int64(authority.sizeBytes)
        let stagingRoot = staged.deletingLastPathComponent()
        if source == nil {
            try requireDiskSpace(stagingRoot: stagingRoot, durableRoot: store.root, expected: expected)
            try progress(.staging, 0, expected)
            do {
                try resolver.validateNoSymlinkCachePath(of: staged, requireComplete: false)
                try await resolver.downloader.downloadSnapshot(
                    modelID: authority.modelID,
                    revision: authority.revision,
                    expectedSHA256: authority.hash,
                    to: staged,
                    deadline: deadline
                )
            } catch {
                try? FileManager.default.removeItem(at: staged)
                throw Self.mapTransferError(error)
            }
            createdStaging = true
            try checkDeadlineAndCancellation()
            source = staged
        }

        guard let source else {
            throw Build1LaneAArtifactStagingError.transferFailed("staging source unavailable")
        }

        // 3. Verify the staged bytes before publication. The canonical snapshot
        //    was already verified above; the freshly staged directory is
        //    verified here for the first time.
        let inspection: ModelArtifactVerifier.CanonicalArtifactInspection
        do {
            try resolver.validateNoSymlinkCachePath(of: source, requireComplete: true)
            inspection = try ModelArtifactVerifier.inspectCanonicalArtifact(directory: source, deadline: deadline)
        } catch AutotuneContextCalibrationError.deadlineExceeded {
            if createdStaging { try? FileManager.default.removeItem(at: staged) }
            throw Build1LaneAArtifactStagingError.timedOut
        } catch {
            if createdStaging { try? FileManager.default.removeItem(at: staged) }
            throw Build1LaneAArtifactStagingError.verificationFailed(
                expected: authority.hash,
                actual: "unreadable:" + String(describing: error)
            )
        }
        guard inspection.sha256 == authority.hash else {
            if createdStaging { try? FileManager.default.removeItem(at: staged) }
            throw Build1LaneAArtifactStagingError.verificationFailed(
                expected: authority.hash,
                actual: inspection.sha256
            )
        }
        let stagedBytes = try regularFileBytes(in: source)
        try progress(.verified, stagedBytes, stagedBytes)

        try checkDeadlineAndCancellation()

        // 4. Re-check the signed authority and the publication headroom
        //    immediately before adoption. Both are fail-closed refusals that
        //    happen before the durable store is touched.
        let fresh: Build1LaneAArtifactAuthority
        do {
            fresh = try await reauthorize()
        } catch {
            if createdStaging { try? FileManager.default.removeItem(at: staged) }
            throw Self.mapReauthorizeError(error)
        }
        guard fresh == authority else {
            if createdStaging { try? FileManager.default.removeItem(at: staged) }
            throw Build1LaneAArtifactStagingError.authorityMismatch
        }
        try checkDeadlineAndCancellation()
        do {
            try requireDiskSpace(stagingRoot: stagingRoot, durableRoot: store.root, expected: expected)
        } catch {
            if createdStaging { try? FileManager.default.removeItem(at: staged) }
            throw error
        }

        // 5. Adopt into the provider-owned durable store. The store copies into
        //    a `.tmp-` sibling, verifies the copy, and swaps atomically with
        //    rollback of any prior destination.
        do {
            _ = try store.adoptVerifiedStaging(
                staging: source,
                modelID: authority.modelID,
                revision: authority.revision,
                sha256: authority.hash
            )
        } catch {
            if createdStaging { try? FileManager.default.removeItem(at: staged) }
            throw Build1LaneAArtifactStagingError.publicationFailed(String(describing: error))
        }

        // 6. The isolated staging copy is redundant once the durable copy is
        //    verified. Never remove the canonical Hugging Face snapshot.
        var stagingCleanupRequired = false
        if source == staged {
            do {
                try FileManager.default.removeItem(at: staged)
            } catch {
                stagingCleanupRequired = true
            }
        }
        try progress(.adopted, stagedBytes, stagedBytes)
        return Build1LaneAStagedArtifact(
            sha256: authority.hash,
            adoptedBytes: stagedBytes,
            reusedDurableArtifact: false,
            stagingCleanupRequired: stagingCleanupRequired
        )
    }

    // MARK: - Helpers

    private func checkDeadlineAndCancellation() throws {
        if Task.isCancelled {
            throw Build1LaneAArtifactStagingError.cancelled
        }
        if let deadline, Date() >= deadline {
            throw Build1LaneAArtifactStagingError.timedOut
        }
    }

    private static func mapReauthorizeError(_ error: Error) -> Build1LaneAArtifactStagingError {
        if error is CancellationError {
            return .cancelled
        }
        if let staging = error as? Build1LaneAArtifactStagingError {
            return staging
        }
        return .authorityUnavailable(String(describing: error))
    }

    private static func mapTransferError(_ error: Error) -> Build1LaneAArtifactStagingError {
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return .cancelled
        }
        if let calibration = error as? AutotuneContextCalibrationError, calibration == .deadlineExceeded {
            return .timedOut
        }
        if let staging = error as? Build1LaneAArtifactStagingError {
            return staging
        }
        return .transferFailed(String(describing: error))
    }

    private func verifiedDurableArtifact(at durable: URL, store: DurableModelArtifactStore, expected: String) throws -> Int64? {
        guard isDirectory(durable) else { return nil }
        // A durable entry with symlink ancestors or a stale digest is not
        // trusted; adoption below overwrites it through the store's own path.
        guard store.contains(durable.path) else { return nil }
        guard try verifies(durable, expected: expected) else { return nil }
        return try regularFileBytes(in: durable)
    }

    private func verifies(_ directory: URL, expected: String) throws -> Bool {
        do {
            return try ModelArtifactVerifier.canonicalArtifactHash(directory: directory, deadline: deadline) == expected
        } catch AutotuneContextCalibrationError.deadlineExceeded {
            throw Build1LaneAArtifactStagingError.timedOut
        } catch {
            return false
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private func regularFileBytes(in directory: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw Build1LaneAArtifactStagingError.verificationFailed(expected: "", actual: "unreadable:enumerate")
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFREG {
                total += Int64(st.st_size)
            }
        }
        return total
    }

    /// SPEC-044 preparation headroom: the bound durable root volume must hold
    /// `2 * expected + 1 GiB`; a distinct staging volume must additionally hold
    /// `expected + 1 GiB`. Overflow refuses before any side effect.
    private func requireDiskSpace(stagingRoot: URL, durableRoot: URL, expected: Int64) throws {
        guard expected > 0 else {
            throw Build1LaneAArtifactStagingError.transferFailed("artifact authority size must be positive")
        }
        let durableRequired = try Self.checkedRequirement(expected, multiplier: 2)
        let durable = try diskProbe(Self.nearestExistingAncestor(of: durableRoot))
        guard durable.availableBytes >= durableRequired else {
            throw Build1LaneAArtifactStagingError.insufficientDiskSpace(
                requiredBytes: durableRequired,
                availableBytes: durable.availableBytes
            )
        }
        let staging = try diskProbe(Self.nearestExistingAncestor(of: stagingRoot))
        if staging.deviceID == durable.deviceID {
            return
        }
        let stagingRequired = try Self.checkedRequirement(expected, multiplier: 1)
        guard staging.availableBytes >= stagingRequired else {
            throw Build1LaneAArtifactStagingError.insufficientDiskSpace(
                requiredBytes: stagingRequired,
                availableBytes: staging.availableBytes
            )
        }
    }

    static func checkedRequirement(_ expected: Int64, multiplier: Int64) throws -> Int64 {
        let scaled = expected.multipliedReportingOverflow(by: multiplier)
        guard !scaled.overflow else {
            throw Build1LaneAArtifactStagingError.insufficientDiskSpace(requiredBytes: .max, availableBytes: 0)
        }
        let total = scaled.partialValue.addingReportingOverflow(publicationReserveBytes)
        guard !total.overflow else {
            throw Build1LaneAArtifactStagingError.insufficientDiskSpace(requiredBytes: .max, availableBytes: 0)
        }
        return total.partialValue
    }

    static func nearestExistingAncestor(of url: URL) -> URL {
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return current
    }

    static func systemDiskProbe(_ url: URL) throws -> Build1LaneADiskProbe {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else {
            throw Build1LaneAArtifactStagingError.rootUnavailable("statfs failed for staging or durable volume")
        }
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw Build1LaneAArtifactStagingError.rootUnavailable("stat failed for staging or durable volume")
        }
        let available = UInt64(fs.f_bavail).multipliedReportingOverflow(by: UInt64(fs.f_bsize))
        let clamped = available.overflow ? UInt64(Int64.max) : min(available.partialValue, UInt64(Int64.max))
        return Build1LaneADiskProbe(availableBytes: Int64(clamped), deviceID: UInt64(st.st_dev))
    }

    // MARK: - Prepare lock

    /// Serializes Lane A prepare runs per durable root. The lock file is a
    /// hidden regular file, which the store's inactive-artifact GC skips.
    final class PrepareLock {
        private var fd: Int32

        fileprivate init(fd: Int32) {
            self.fd = fd
        }

        func release() {
            guard fd >= 0 else { return }
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
            fd = -1
        }

        deinit { release() }
    }

    private func acquirePrepareLock(root: URL) throws -> PrepareLock {
        let path = root.appendingPathComponent(Self.prepareLockLeaf, isDirectory: false).path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw Build1LaneAArtifactStagingError.rootUnavailable("cannot open prepare lock")
        }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid() else {
            _ = close(fd)
            throw Build1LaneAArtifactStagingError.rootUnavailable("prepare lock is not a private regular file")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd)
            throw Build1LaneAArtifactStagingError.operationConflict
        }
        return PrepareLock(fd: fd)
    }
}
