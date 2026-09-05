import Darwin
import Foundation

/// SPEC-001 FR-12 / SPEC-020 R-4.14 — validated local stop intent.
///
/// The provider LaunchAgent runs under `KeepAlive{SuccessfulExit:false}`
/// (`consumer_user`), so launchd restarts a crash/nonzero exit but NOT a clean
/// (exit 0) termination. The companion watchdog no longer restarts on a missing
/// PID, so an *unsolicited* SIGTERM/SIGINT — a stray `kill` or a macOS
/// memory-pressure/jetsam SIGTERM while the launchd job is still loaded — must
/// exit nonzero so launchd relaunches the provider instead of leaving the node
/// down. A genuine local stop transaction (uninstall / operator-disable / local
/// stop) records this marker first so the serve process exits 0 for that case.
///
/// The marker is bound to the target PID, its process-start time (so a reused
/// PID cannot replay a stale marker against a different process instance), and
/// the current boot session; it is short-lived and consumed on read. Storage is
/// hardened (private dir, `O_NOFOLLOW`, regular file owned by the current user,
/// mode `0600`, single link, bounded size). Evaluation is fail-closed: any
/// missing, malformed, expired, mismatched, or unhardened marker is treated as
/// "no stop intent" and the process exits nonzero.
enum StopIntentMarker {
    static let schema = "macprovider.stop-intent.v1"
    /// Default TTL for a recorded stop intent. Bounded so a stale marker cannot
    /// authorize a much later unsolicited signal (belt-and-braces with boot +
    /// process-start binding and consume-on-read).
    static let defaultTTLSeconds: Int64 = 120
    /// Hard cap on the marker file size read on consume; a well-formed marker is
    /// a few hundred bytes.
    static let maxMarkerBytes = 8 * 1024

    typealias ProcessStartProvider = @Sendable (pid_t) -> Int64?

    /// Process-start microseconds for `pid` via `proc_pidinfo(PROC_PIDTBSDINFO)`,
    /// matching `ProviderLifecycleLease`'s process-identity binding.
    static let liveProcessStartMicroseconds: ProcessStartProvider = { pid in
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard count == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        let seconds = Int64(info.pbi_start_tvsec)
        let micros = Int64(info.pbi_start_tvusec)
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !overflow else { return nil }
        let (combined, addOverflow) = scaled.addingReportingOverflow(micros)
        return addOverflow ? nil : combined
    }

    static func markerURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent(".local/share/macprovider", isDirectory: true)
            .appendingPathComponent("stop-intent.json", isDirectory: false)
    }

    /// Record a validated stop intent for `targetPID` in the current boot
    /// session. Called by a local stop transaction immediately before it stops
    /// the provider service. Best-effort: a write failure or an unresolvable
    /// process-start simply means the serve process will exit nonzero on the
    /// incoming signal (fail-closed).
    @discardableResult
    static func record(
        targetPID: Int32,
        reason: String,
        ttlSeconds: Int64 = defaultTTLSeconds,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bootSession: String? = CredentialRestartProver.currentBootSessionUUID(),
        now: Date = Date(),
        processStartMicroseconds: ProcessStartProvider = liveProcessStartMicroseconds
    ) -> Bool {
        guard targetPID > 0, let bootSession, !bootSession.isEmpty else { return false }
        guard let processStart = processStartMicroseconds(targetPID) else { return false }
        let expiresWallMs = Int64(now.timeIntervalSince1970 * 1000) + max(1, ttlSeconds) * 1000
        let payload: [String: Any] = [
            "schema": schema,
            "pid": Int(targetPID),
            "process_start_us": processStart,
            "boot_session": bootSession,
            "expires_wall_ms": expiresWallMs,
            "reason": reason,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return false
        }
        let url = markerURL(home: home)
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Exclusive-create a fresh private temp, write, then atomically rename
            // over the destination so a reader never sees a partial file and the
            // final file carries our owner/mode (not a pre-existing file's).
            let tmp = dir.appendingPathComponent(".stop-intent.\(getpid()).\(UUID().uuidString).tmp")
            let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return false }
            var wrote = false
            defer { if !wrote { try? FileManager.default.removeItem(at: tmp) } }
            let written = data.withUnsafeBytes { raw in
                write(fd, raw.baseAddress, raw.count)
            }
            close(fd)
            guard written == data.count else { return false }
            // Publish with POSIX rename(2): atomic, and the destination becomes the
            // temp's inode — so the final file carries the temp's 0600 mode and our
            // ownership, never a pre-existing destination's (looser) metadata the way
            // FileManager.replaceItemAt can. Then reopen with O_NOFOLLOW and confirm
            // the published file is a private, single-linked regular file owned by us
            // before returning success.
            guard rename(tmp.path, url.path) == 0 else { return false }
            wrote = true  // tmp no longer exists after a successful rename
            let vfd = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard vfd >= 0 else { try? FileManager.default.removeItem(at: url); return false }
            defer { close(vfd) }
            var vst = stat()
            guard fstat(vfd, &vst) == 0,
                  (vst.st_mode & S_IFMT) == S_IFREG,
                  vst.st_uid == getuid(),
                  (vst.st_mode & 0o777) == 0o600,
                  vst.st_nlink == 1 else {
                try? FileManager.default.removeItem(at: url)
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// Consume the marker and report whether it authorizes a clean (exit 0)
    /// termination of `currentPID`. Always deletes the marker (consume-once), so
    /// a single recorded intent can authorize at most one stop. Fail-closed on
    /// any missing/malformed/expired/mismatched/unhardened marker.
    @discardableResult
    static func consumeIfValid(
        currentPID: Int32 = getpid(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bootSession: String? = CredentialRestartProver.currentBootSessionUUID(),
        now: Date = Date(),
        processStartMicroseconds: ProcessStartProvider = liveProcessStartMicroseconds
    ) -> Bool {
        let url = markerURL(home: home)
        defer { try? FileManager.default.removeItem(at: url) }

        // Open without following symlinks and validate the file is a private,
        // single-linked regular file owned by us before trusting its bytes.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o777) == 0o600,
              st.st_nlink == 1,
              st.st_size > 0, st.st_size <= maxMarkerBytes else {
            return false
        }
        var buffer = [UInt8](repeating: 0, count: Int(st.st_size))
        let readCount = read(fd, &buffer, buffer.count)
        guard readCount == buffer.count else { return false }
        let data = Data(buffer)

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["schema"] as? String == schema else {
            return false
        }
        guard let pid = strictInt64(object["pid"]), pid > 0, pid == Int64(currentPID) else {
            return false
        }
        guard let recordedBoot = object["boot_session"] as? String,
              let bootSession, !bootSession.isEmpty,
              recordedBoot == bootSession else {
            return false
        }
        guard let recordedStart = strictInt64(object["process_start_us"]),
              let currentStart = processStartMicroseconds(currentPID),
              recordedStart == currentStart else {
            return false
        }
        guard let expiresWallMs = strictInt64(object["expires_wall_ms"]) else { return false }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        return nowMs < expiresWallMs
    }

    /// Strict integral parse: accept only an exact integer JSON number (no
    /// fractional, string, or out-of-range values). `JSONSerialization` yields
    /// `NSNumber`; reject anything whose value is not an exact `Int64`.
    private static func strictInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        // Reject booleans and non-integral / floating values.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let type = String(cString: number.objCType)
        // Allowable integral encodings from JSONSerialization: q/l/i/s/c and unsigned.
        guard !type.contains("f"), !type.contains("d") else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.rounded() == doubleValue,
              doubleValue >= Double(Int64.min), doubleValue <= Double(Int64.max) else {
            return nil
        }
        return number.int64Value
    }
}
