import CryptoKit
import Darwin
import Foundation
import MacProviderCore

/// SPEC-048-R013: a running provider picks up a native-MTP admission that a
/// later catalog release adds for its loaded model.
///
/// Native MTP activates only at process start (the admission set is read once
/// and the drafter loads with the model). When the runtime catalog refresh
/// sees a release other than the one this process started on, the provider
/// re-fetches that release's signed admission set into a probe directory. If
/// a fresh start would now admit the loaded model, it restarts itself once:
/// a random bounded delay, then a drain that refuses new requests and waits
/// for the requests in flight with no forced cut, then a nonzero exit that
/// launchd restarts. A revocation is never handled here; the live revocation
/// feed disables a tuple without a restart.
enum NativeMTPAdmissionPickup {
    /// The delay before the drain is uniform over this range, so providers of
    /// one model do not reload together after one catalog release.
    static let jitterRangeSeconds: ClosedRange<Double> = 60...1800
    /// The `state_update` reason while the provider waits for its requests.
    static let drainReason = "native_mtp_admission_restart"
    static let idlePollNanoseconds: UInt64 = 100_000_000

    /// Maps a unit sample onto `jitterRangeSeconds`; any input stays in range.
    static func jitterSeconds(unit: Double) -> Double {
        let clamped = unit.isFinite ? min(1, max(0, unit)) : 1
        return jitterRangeSeconds.lowerBound
            + clamped * (jitterRangeSeconds.upperBound - jitterRangeSeconds.lowerBound)
    }

    /// Everything the pickup needs from outside the coordinator client.
    struct Hooks: Sendable {
        /// Re-fetches the release's admission set and reports whether a fresh
        /// start of this process would admit native MTP for the loaded model
        /// where this process did not.
        var newlyActivatable: @Sendable (CoordinatorClient.CatalogEnvelope) async -> Bool
        /// Records the release as handled; false when it already was, in this
        /// process or an earlier one.
        var claim: @Sendable (_ releaseID: String) -> Bool
        /// Whether a nonzero exit of this process is restarted.
        var supervised: @Sendable () -> Bool
        var randomUnit: @Sendable () -> Double = { Double.random(in: 0...1) }
        var sleep: @Sendable (_ seconds: Double) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
        /// Ends the process through the signal path: the same cleanup and
        /// drain as an unsolicited SIGTERM, which exits nonzero.
        var requestExit: @Sendable () -> Void = { _ = kill(getpid(), SIGTERM) }
    }

    /// Whether a fresh start of this build on the row-invariant route would
    /// admit native MTP for the target from the signed set at `sidecarURL`:
    /// the admission stage of the serve-path loader
    /// (`ModelRuntime.loadNativeMTPDrafterIfAdmitted`) without the weights,
    /// covering signature, tuple, artifact binding and revocation state.
    /// Returns nil when admitted, else a reason code. This only decides
    /// whether to restart; the next start's loader admits or refuses on its
    /// own, so a difference between the two costs at most one restart.
    static func loaderRefusal(
        mode: NativeMTPMode,
        targetModelID: String,
        targetModelRevision: String,
        slotCount: Int,
        sidecarURL: URL,
        artifactRoot: URL?,
        trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring,
        resolvedArtifactAuthority: NativeMTPResolvedArtifactAuthority?,
        runningBuildIdentity: ModelRuntime.NativeMTPRunningBuildIdentity? = ModelRuntime.nativeMTPRunningBuildIdentity()
    ) async -> String? {
        if let reasonCode = ModelRuntime.nativeMTPActivationRefusal(mode: mode, route: .rowInvariant) {
            return reasonCode
        }
        guard let runningBuildIdentity else { return "running_build_identity_unavailable" }
        let signatureURL = sidecarURL.deletingLastPathComponent()
            .appendingPathComponent(NativeMTPAdmissionFeed.signatureFileName)
        guard let sidecarData = try? Data(contentsOf: sidecarURL) else { return "sidecar_missing" }
        guard let signatureData = try? Data(contentsOf: signatureURL) else { return "signature_missing" }
        guard let revocationSignerKeyID = try? NativeMTPAdmissionSidecar.pinnedRevocationSignerKeyID(
            sidecarData: sidecarData,
            signatureData: signatureData,
            trustedKeyring: trustedKeyring
        ) else {
            return "revocation_state_unavailable"
        }
        // SPEC-048-R014: only a signed feed naming the tuple revokes it; with
        // no feed to be had nothing is revoked, as at load.
        let revoked = (try? await NativeMTPRevocationFeedManager.loadNetworkFirst(
            pinnedSignerKeyID: revocationSignerKeyID,
            verifier: NativeMTPRevocationEd25519Verifier(publicKeysByKeyID: trustedKeyring.publicKeysByKeyID),
            store: KeychainNativeMTPRevocationStore.live()
        ))?.feed.revokedSet ?? []
        let machine = MachineFingerprinter().sample()
        do {
            let capability = try NativeMTPAdmissionSidecar.load(
                sidecarData: sidecarData,
                signatureData: signatureData,
                snapshotRoot: sidecarURL.deletingLastPathComponent(),
                artifactRoot: artifactRoot,
                context: NativeMTPAdmissionSidecar.RuntimeContext(
                    modelID: targetModelID,
                    modelRevision: targetModelRevision,
                    upstreamMLXSwiftLMRevision: runningBuildIdentity.upstreamMLXSwiftLMRevision,
                    hardwareChip: machine.chip,
                    ramGB: machine.ramGB,
                    osVersion: machine.osVersion,
                    slotCount: slotCount,
                    revokedTupleSHA256: revoked,
                    decodePathDigest: DecodePathIdentity.digest,
                    metallibSHA256: ModelRuntime.nativeMTPRuntimeMetallibSHA256()
                ),
                trustedKeyring: trustedKeyring,
                resolvedArtifactAuthority: resolvedArtifactAuthority
            )
            return capability.targetArtifactSHA256 == targetModelRevision ? nil : "build_binding_mismatch"
        } catch {
            return "admission_rejected"
        }
    }

    /// True for a process started by launchd, whose nonzero exit the provider
    /// LaunchAgent restarts (`StopIntentMarker`). A foreground or lab `serve`
    /// has a shell or harness as parent and would stay down.
    static func supervisedByLaunchd() -> Bool { getppid() == 1 }
}

/// What `/v1/status` reports while a pickup is pending.
struct NativeMTPAdmissionPendingStatus: Sendable, Equatable {
    enum Phase: String, Sendable {
        /// Waiting out the random delay.
        case scheduled
        /// Refusing new requests until the requests in flight finish.
        case waitingForIdle = "waiting_for_idle"
        /// Not supervised: the admission needs a manual restart.
        case restartRequired = "restart_required"
    }

    let releaseID: String
    let phase: Phase
    /// When the drain starts, for `scheduled`.
    let drainNotBefore: Date?

    func statusObject() -> [String: Any] {
        var object: [String: Any] = ["release_id": releaseID, "phase": phase.rawValue]
        if let drainNotBefore {
            object["drain_not_before"] = ISO8601DateFormatter().string(from: drainNotBefore)
        }
        return object
    }
}

/// The catalog releases a pickup restart was already spent on, so one release
/// restarts a provider at most once across process starts. A private (0600,
/// owner-only, no symlinks) JSON file; a store that cannot be written claims
/// nothing, so doubt never restarts.
struct NativeMTPAdmissionPickupStore: Sendable {
    static let schemaVersion = "macprovider.native-mtp-admission-pickup.v1"
    static let fileName = "native-mtp-admission-pickup.json"
    static let maxEntries = 32
    static let maxFileBytes: off_t = 1 << 16

    let url: URL

    static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macprovider", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private struct Document: Codable {
        let schemaVersion: String
        let releases: [String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case releases
        }
    }

    static func digest(_ releaseID: String) -> String {
        SHA256.hash(data: Data(releaseID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func contains(_ releaseID: String) -> Bool {
        read().contains(Self.digest(releaseID))
    }

    /// Records the release; true only when it was not recorded before and the
    /// record is now durable.
    func claim(_ releaseID: String) -> Bool {
        let digest = Self.digest(releaseID)
        var releases = read()
        guard !releases.contains(digest) else { return false }
        releases.append(digest)
        if releases.count > Self.maxEntries { releases = Array(releases.suffix(Self.maxEntries)) }
        guard let data = try? JSONEncoder().encode(Document(schemaVersion: Self.schemaVersion, releases: releases)),
              (try? write(data)) != nil
        else { return false }
        return contains(releaseID)
    }

    private func read() -> [String] {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o077) == 0,
              st.st_size <= Self.maxFileBytes,
              let data = try? handle.readToEnd(),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == Self.schemaVersion
        else { return [] }
        return document.releases
    }

    private func write(_ data: Data) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var existing = stat()
        if lstat(url.path, &existing) == 0,
           (existing.st_mode & S_IFMT) != S_IFREG || existing.st_uid != getuid() {
            throw POSIXError(.EPERM)
        }
        let temporary = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = temporary.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { _ = unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }
}
