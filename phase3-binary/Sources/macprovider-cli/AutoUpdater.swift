import Darwin
import Foundation
import MacProviderCore

enum AutoUpdateError: Error, CustomStringConvertible {
    case trustStateLost(String)
    case drainTimeout
    case observerUnavailable
    case currentBinaryUnknown

    var description: String {
        switch self {
        case let .trustStateLost(reason): return "autoupdate trust state lost: \(reason)"
        case .drainTimeout: return "autoupdate drain timed out"
        case .observerUnavailable: return "rollback observer unavailable"
        case .currentBinaryUnknown: return "current binary unknown"
        }
    }
}

struct AutoUpdater: Sendable {
    typealias TrustProvider = @Sendable () async -> AutoUpdateTrustState
    typealias Drain = @Sendable (_ target: String) async throws -> Bool
    typealias SendReady = @Sendable () async throws -> Void
    typealias Restart = @Sendable () throws -> Void

    let config: AppConfig
    let currentVersion: String
    let providerStatus: ProviderStatus
    let releasesAPIURL: String?
    let markerStore: AutoUpdateMarkerStore
    let session: URLSession
    let trustProvider: TrustProvider
    let drain: Drain
    let sendReady: SendReady
    let restartLaunchd: Restart
    let currentBinaryURL: @Sendable () -> URL?
    let rollbackObserverAvailable: @Sendable () -> Bool

    init(
        config: AppConfig,
        currentVersion: String,
        providerStatus: ProviderStatus,
        releasesAPIURL: String? = nil,
        markerStore: AutoUpdateMarkerStore = AutoUpdateMarkerStore(),
        session: URLSession = .shared,
        trustProvider: @escaping TrustProvider,
        drain: @escaping Drain,
        sendReady: @escaping SendReady,
        restartLaunchd: @escaping Restart = { try AutoUpdater.restartLaunchdIfInstalled() },
        currentBinaryURL: @escaping @Sendable () -> URL? = { Bundle.main.executableURL },
        rollbackObserverAvailable: @escaping @Sendable () -> Bool = { AutoUpdater.defaultRollbackObserverAvailable() }
    ) {
        self.config = config
        self.currentVersion = currentVersion
        self.providerStatus = providerStatus
        self.releasesAPIURL = releasesAPIURL
        self.markerStore = markerStore
        self.session = session
        self.trustProvider = trustProvider
        self.drain = drain
        self.sendReady = sendReady
        self.restartLaunchd = restartLaunchd
        self.currentBinaryURL = currentBinaryURL
        self.rollbackObserverAvailable = rollbackObserverAvailable
    }

    func handleCoordinatorRecommendation(_ rawRecommended: String) async {
        let updateID = UUID().uuidString.lowercased()
        let validated: AutoUpdateRecommendation
        do {
            validated = try AutoUpdateRecommendation.validate(rawRecommended)
        } catch let AutoUpdateValidationError.versionTooLong(sha) {
            await record(updateID: updateID, target: "<redacted>", phase: .eligibility, outcome: .failure, reason: "version_too_long", attempt: 1, failure: .recommendedVersionInvalid, sha: sha)
            return
        } catch AutoUpdateValidationError.componentTooLong {
            await record(updateID: updateID, target: "<invalid>", phase: .eligibility, outcome: .failure, reason: "version_component_too_long", attempt: 1, failure: .recommendedVersionInvalid)
            return
        } catch {
            await record(updateID: updateID, target: "<invalid>", phase: .eligibility, outcome: .failure, reason: "recommended_version_invalid", attempt: 1, failure: .recommendedVersionInvalid)
            return
        }

        let target = validated.normalized
        await record(updateID: updateID, target: target, phase: .detection, outcome: .inProgress, reason: "recommended_binary_version_detected", attempt: 1)

        guard SelfUpdate.compareSemver(currentVersion, target) == .orderedAscending else {
            await record(updateID: updateID, target: target, phase: .eligibility, outcome: .noop, reason: "target_not_newer", attempt: 1)
            return
        }
        guard AutoUpdateConfig.enabled(config) else {
            print("A newer version is available (v\(target)), but autoupdate is disabled.")
            await record(updateID: updateID, target: target, phase: .eligibility, outcome: .skipped, reason: "autoupdate_disabled", attempt: 1)
            return
        }
        do {
            try markerStore.ensureTrustedRoot()
            let policy = markerStore.effectivePolicy()
            if let minimum = policy.minimum, SelfUpdate.compareSemver(target, minimum) == .orderedAscending || policy.revoked.contains(target) {
                await fail(updateID: updateID, target: target, phase: .eligibility, failure: .targetRevokedOrBelowMinimum, reason: "target_revoked_or_below_minimum")
                return
            }
            guard rollbackObserverAvailable() else {
                await fail(updateID: updateID, target: target, phase: .eligibility, failure: .rollbackObserverUnavailable, reason: "rollback_observer_unavailable")
                return
            }
            if let activeCooldown = markerStore.activeCooldown(target: target) {
                await record(updateID: updateID, target: target, phase: .cooldown, outcome: .skipped, reason: "cooldown_\(activeCooldown.failureClass.rawValue)_until_\(ISO8601DateFormatter.autoupdate.string(from: activeCooldown.until))", attempt: activeCooldown.attempt)
                return
            }
            try await ensureEligible(phase: .eligibility)
            let lock = try markerStore.acquireLock()
            _ = lock
            let update = SelfUpdate(currentVersion: currentVersion, releasesAPIURL: releasesAPIURL, session: session)
            let release: GitHubRelease
            do {
                try await ensureEligible(phase: .download)
                release = try await update.resolveReleaseByTags(normalizedTarget: target)
            } catch UpdateError.releaseNotFound {
                markerStore.recordCooldown(target: target, failureClass: .targetReleaseNotFound)
                await fail(updateID: updateID, target: target, phase: .download, failure: .targetReleaseNotFound, reason: "target_release_not_found")
                return
            }
            let prepared: PreparedSelfUpdate
            do {
                prepared = try await update.prepareValidatedUpdate(from: release)
            } catch {
                let failure = Self.failureClass(for: error)
                markerStore.recordCooldown(target: target, failureClass: failure)
                await fail(updateID: updateID, target: target, phase: Self.phase(for: error), failure: failure, reason: String(describing: error))
                return
            }
            defer { prepared.cleanup() }
            try await ensureEligible(phase: .drain)
            let drained = try await drain(target)
            guard drained else {
                markerStore.recordCooldown(target: target, failureClass: .drainTimeout)
                await fail(updateID: updateID, target: target, phase: .drain, failure: .drainTimeout, reason: "drain_timeout")
                try? await sendReady()
                return
            }
            try await ensureEligible(phase: .backup)
            try await preserveMarkerAndSwap(updateID: updateID, target: target, newBinary: prepared.newBinary)
            await record(updateID: updateID, target: target, phase: .swap, outcome: .success, reason: "binary_swap_complete", attempt: 1)
            try await ensureEligible(phase: .restart)
            try restartLaunchd()
            await record(updateID: updateID, target: target, phase: .restart, outcome: .inProgress, reason: "launchctl_bootstrap_invoked", attempt: 1)
        } catch AutoUpdateMarkerError.lockContended {
            await fail(updateID: updateID, target: target, phase: .eligibility, failure: .autoupdateAlreadyPending, reason: "autoupdate_already_pending")
        } catch AutoUpdateError.trustStateLost(let reason) {
            await fail(updateID: updateID, target: target, phase: .eligibility, failure: .trustStateLost, reason: reason)
        } catch {
            markerStore.recordCooldown(target: target, failureClass: .other)
            await fail(updateID: updateID, target: target, phase: .eligibility, failure: .other, reason: String(describing: error))
        }
    }

    private func preserveMarkerAndSwap(updateID: String, target: String, newBinary: URL) async throws {
        guard let current = currentBinaryURL() else {
            throw AutoUpdateError.currentBinaryUnknown
        }
        let backup = markerStore.rollbackBackupPath(binaryURL: current, updateID: updateID)
        let attrs = try FileManager.default.attributesOfItem(atPath: current.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let sha = try AutoUpdateMarkerStore.sha256(file: current)
        try copyNoFollow(from: current, to: backup, mode: mode)
        let deadline = ISO8601DateFormatter.autoupdate.string(from: Date().addingTimeInterval(60 + 300))
        try markerStore.writePending(AutoUpdatePendingMarker(
            updateID: updateID,
            targetVersion: target,
            targetPath: current.path,
            backupPath: backup.path,
            size: size,
            mode: mode,
            sha256: sha,
            markerDeadline: deadline
        ))
        try await ensureEligible(phase: .swap)
        let staged = current.deletingLastPathComponent()
            .appendingPathComponent(".\(current.lastPathComponent).update-\(UUID().uuidString)")
        try copyNoFollow(from: newBinary, to: staged, mode: 0o755)
        if rename(staged.path, current.path) != 0 {
            let errnoValue = errno
            try? FileManager.default.removeItem(at: staged)
            try? markerStore.restoreBackup(AutoUpdatePendingMarker(
                updateID: updateID,
                targetVersion: target,
                targetPath: current.path,
                backupPath: backup.path,
                size: size,
                mode: mode,
                sha256: sha,
                markerDeadline: deadline
            ))
            throw UpdateError.renameFailed(errnoValue)
        }
    }

    private func copyNoFollow(from source: URL, to finalURL: URL, mode: Int) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw AutoUpdateMarkerError.openFailed(source.path, errno) }
        defer { close(input) }
        let tempURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(finalURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let output = open(tempURL.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(mode))
        guard output >= 0 else { throw AutoUpdateMarkerError.openFailed(tempURL.path, errno) }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let readCount = read(input, &buffer, buffer.count)
            if readCount < 0 {
                try? FileManager.default.removeItem(at: tempURL)
                throw AutoUpdateMarkerError.writeFailed(tempURL.path, errno)
            }
            if readCount == 0 { break }
            try buffer.withUnsafeBytes { raw in
                var offset = 0
                while offset < readCount {
                    let wrote = write(output, raw.baseAddress!.advanced(by: offset), readCount - offset)
                    if wrote <= 0 {
                        try? FileManager.default.removeItem(at: tempURL)
                        throw AutoUpdateMarkerError.writeFailed(tempURL.path, errno)
                    }
                    offset += wrote
                }
            }
        }
        fchmod(output, mode_t(mode))
        fsync(output)
        if rename(tempURL.path, finalURL.path) != 0 {
            let errnoValue = errno
            try? FileManager.default.removeItem(at: tempURL)
            throw AutoUpdateMarkerError.writeFailed(finalURL.path, errnoValue)
        }
    }

    private func ensureEligible(phase: AutoUpdatePhase) async throws {
        let trust = await trustProvider()
        guard trust.isEligible else {
            throw AutoUpdateError.trustStateLost(trust.verdict.rawValue)
        }
        _ = phase
    }

    private func fail(updateID: String, target: String, phase: AutoUpdatePhase, failure: AutoUpdateFailureClass, reason: String) async {
        markerStore.recordCooldown(target: target, failureClass: failure)
        await record(updateID: updateID, target: target, phase: phase, outcome: .failure, reason: reason, attempt: 1, failure: failure)
    }

    private func record(updateID: String, target: String, phase: AutoUpdatePhase, outcome: AutoUpdateOutcome, reason: String, attempt: Int, failure: AutoUpdateFailureClass? = nil, sha: String? = nil) async {
        let inflight = await providerStatus.snapshot().requestsInFlight
        await AutoUpdateEventStore.shared.record(AutoUpdateEvent(
            updateID: updateID,
            currentVersion: currentVersion,
            targetVersion: target,
            phase: phase,
            outcome: outcome,
            reason: reason,
            attempt: attempt,
            failureClass: failure,
            inflightRequests: phase == .drain ? inflight : nil,
            recommendedBinaryVersionSHA256: sha
        ))
    }

    private static func failureClass(for error: Error) -> AutoUpdateFailureClass {
        switch error {
        case UpdateError.missingAsset, UpdateError.checksumMissing:
            return .releaseAssetMissing
        case UpdateError.checksumSignatureInvalid:
            return .signatureInvalid
        case UpdateError.checksumMismatch:
            return .checksumMismatch
        case UpdateError.processFailed:
            return .selfTestFailed
        case UpdateError.insufficientDiskSpace:
            return .insufficientDiskSpace
        default:
            return .other
        }
    }

    private static func phase(for error: Error) -> AutoUpdatePhase {
        switch error {
        case UpdateError.checksumSignatureInvalid:
            return .signature
        case UpdateError.checksumMismatch, UpdateError.checksumMissing:
            return .checksum
        case UpdateError.unsafeArchiveEntry, UpdateError.missingExtractedBinary:
            return .archive
        case UpdateError.processFailed:
            return .selfTest
        case UpdateError.insufficientDiskSpace:
            return .freeSpace
        default:
            return .download
        }
    }

    static func defaultRollbackObserverAvailable() -> Bool {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist")
        return FileManager.default.fileExists(atPath: plist.path)
            || ProcessInfo.processInfo.environment["MACPROVIDER_ROLLBACK_OBSERVER_TEST_AVAILABLE"] == "1"
    }

    static func restartLaunchdIfInstalled() throws {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }
        let domain = "gui/\(getuid())"
        try runProcess("/bin/launchctl", arguments: ["bootout", domain, "live.streamvc.macprovider"], allowFailure: true)
        try runProcess("/bin/launchctl", arguments: ["bootstrap", domain, plist.path])
    }

    private static func runProcess(_ executable: String, arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if !allowFailure, process.terminationStatus != 0 {
            throw UpdateError.processFailed(executable, process.terminationStatus)
        }
    }
}

private extension ISO8601DateFormatter {
    static let autoupdate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
