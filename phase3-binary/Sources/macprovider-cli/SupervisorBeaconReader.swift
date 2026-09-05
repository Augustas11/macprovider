import Darwin
import Foundation

/// SPEC-025 §5.4 / RFC-001 F5 — reads the companion watchdog's supervisor
/// telemetry beacon and projects it onto the provider heartbeat as
/// `last_supervisor_event`.
///
/// The companion watchdog is the sole writer of a single overwrite-OK
/// `supervisor-beacon.json` under its own provider-UID-owned state directory.
/// The CLI is strictly read-only: it never writes, owns no cursor. It reads the
/// beacon with hardened I/O (`O_NOFOLLOW`, regular file owned by the current
/// uid, mode `0600`, single link, bounded size), parses fail-closed, drops a
/// wrong-boot file, and — crucially for the redaction invariant — **projects the
/// parsed object to the allowlisted schema locally** (unknown keys dropped,
/// strings capped, `supervisor_label` mapped to a public allowlist) before it is
/// carried on the wire. Relying on the coordinator to drop unknown keys would be
/// too late for redaction.
///
/// Observability-only: nothing this reader returns gates admission, routing,
/// serving, trust, rewards, autoupdate, or any local authority. A missing,
/// malformed, oversized, wrong-owner, symlinked, or wrong-boot file yields `nil`
/// and the heartbeat proceeds without the field — absence never blocks a
/// heartbeat and never fabricates a restart signal.
enum SupervisorBeaconReader {
    static let schema = "macprovider.supervisor-event.v1"
    /// Wire cap for a single beacon object (matches the autoupdate-event cap).
    static let maxBeaconBytes = 4096
    static let allowedKinds: Set<String> = ["restart", "deferral", "beacon"]
    static let allowedCooldownStates: Set<String> = ["armed", "cooldown_active"]

    /// Default beacon path under the watchdog's own state root. Honors the same
    /// `MACPROVIDER_WATCHDOG_STATE_DIR` override the watchdog uses, so tests and
    /// non-default installs stay aligned across the shell/Swift boundary.
    static func beaconURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["MACPROVIDER_WATCHDOG_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("supervisor-beacon.json", isDirectory: false)
        }
        return home
            .appendingPathComponent(".local/share/macprovider-watchdog/state", isDirectory: true)
            .appendingPathComponent("supervisor-beacon.json", isDirectory: false)
    }

    /// Read + project the beacon, or `nil` if it is absent/untrusted/wrong-boot.
    /// `currentBootSession` defaults to the live `kern.bootsessionuuid`.
    static func lastWireObject(
        url: URL = beaconURL(),
        currentBootSession: String? = bootSessionUUID()
    ) -> [String: Any]? {
        // Ancestry guard (SPEC-025 §5.4 / SPEC-020 R-4.9): the containing directory
        // must not be writable by other users, so no non-owner can replace or
        // symlink-swap the beacon. Owner must be us (consumer: provider-uid 0700)
        // or root (headless: root-owned 0755 — world-traversable but only root
        // writes; a root-owned 0700 dir would be untraversable by the HEADLESS_USER
        // reader, so ownership, not a fixed mode, is the invariant), and no
        // group/other write bit may be set.
        let dirPath = url.deletingLastPathComponent().path
        var dst = stat()
        guard stat(dirPath, &dst) == 0,
              (dst.st_mode & S_IFMT) == S_IFDIR,
              dst.st_uid == getuid() || dst.st_uid == 0,
              (dst.st_mode & 0o022) == 0 else {
            return nil
        }
        // Hardened open: never follow a symlink; require a private, single-link
        // regular file owned by us, no larger than the wire cap.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_nlink == 1,
              st.st_size > 0, st.st_size <= maxBeaconBytes else {
            return nil
        }
        // The file must not be writable by anyone other than its owner-writer:
        //   - consumer: owned by us (== watchdog uid), mode 0600; OR
        //   - headless: owned by root (the root watchdog is the sole writer),
        //     world-readable but with no group/other WRITE bit (e.g. 0644).
        // This keeps the watchdog the sole writer in both topologies — a
        // provider-uid-owned non-0600 file (or any group/other-writable file) is
        // rejected so a modified provider cannot forge the beacon in place.
        let ownedByUs = st.st_uid == getuid() && (st.st_mode & 0o777) == 0o600
        let rootOwnedNotOthersWritable = st.st_uid == 0 && (st.st_mode & 0o022) == 0
        guard ownedByUs || rootOwnedNotOthersWritable else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: Int(st.st_size))
        let readCount = read(fd, &buffer, buffer.count)
        guard readCount == buffer.count else { return nil }

        guard let object = (try? JSONSerialization.jsonObject(with: Data(buffer))) as? [String: Any],
              object["schema"] as? String == schema,
              let kind = object["kind"] as? String, allowedKinds.contains(kind),
              let bootID = boundedString(object["boot_id"], max: 128), !bootID.isEmpty,
              let seq = strictUInt(object["seq"]),
              // Required common fields must be PRESENT (not defaulted): a beacon
              // missing its counters is malformed and drops rather than becoming 0.
              let restartsTotal = strictUInt(object["restarts_total"]),
              let deferralsTotal = strictUInt(object["deferrals_total"]) else {
            return nil
        }
        // Wrong-boot drop is CLI-side: a beacon file left over from a previous
        // boot must never be uplinked. The coordinator treats boot_id only as a
        // partition key and does not re-check the current boot.
        guard let currentBootSession, !currentBootSession.isEmpty, bootID == currentBootSession else {
            return nil
        }

        // Build a fresh object carrying ONLY the allowlisted schema fields, so
        // unknown keys are dropped locally before uplink and every string is
        // bounded and redacted at the source.
        var projected: [String: Any] = [
            "schema": schema,
            "kind": kind,
            "boot_id": bootID,
            "seq": seq,
            "supervisor_label": labelClass(object["supervisor_label"]),
            "supervisor_version": boundedString(object["supervisor_version"], max: 64) ?? "unknown",
            "restarts_total": restartsTotal,
            "deferrals_total": deferralsTotal,
        ]
        if let ts = boundedString(object["ts"], max: 64) {
            projected["ts"] = ts
        }
        projected["last_restart"] = projectLastRestart(object["last_restart"]) ?? NSNull()
        projected["last_deferral"] = projectLastDeferral(object["last_deferral"]) ?? NSNull()
        return projected
    }

    // MARK: - Projection helpers

    private static func projectLastRestart(_ raw: Any?) -> [String: Any]? {
        // Require the exact watchdog-owned reason and a valid seq; a missing/other
        // reason is not a valid supervisor restart — drop it rather than fabricate.
        guard let obj = raw as? [String: Any],
              obj["reason"] as? String == "wedge",
              let seq = strictUInt(obj["seq"]) else {
            return nil
        }
        var out: [String: Any] = [
            "seq": seq,
            "reason": "wedge",
        ]
        if let ts = boundedString(obj["ts"], max: 64) {
            out["ts"] = ts
        }
        if let cooldown = obj["cooldown_state"] as? String, allowedCooldownStates.contains(cooldown) {
            out["cooldown_state"] = cooldown
        } else {
            out["cooldown_state"] = "armed"
        }
        // service_instance is the opaque UUID instance id; anything not
        // UUID-shaped (a path, hostname, PII) is dropped so it never reaches the
        // wire (redaction non-negotiable, SPEC-025 §5.4).
        if let instance = obj["service_instance"] as? String, isUUID(instance) {
            out["service_instance"] = instance
        } else {
            out["service_instance"] = NSNull()
        }
        out["model_liveness"] = projectModelLiveness(obj["model_liveness"]) ?? NSNull()
        return out
    }

    private static func projectLastDeferral(_ raw: Any?) -> [String: Any]? {
        guard let obj = raw as? [String: Any],
              obj["deferral_reason"] as? String == "pending_autoupdate_marker",
              let seq = strictUInt(obj["seq"]) else {
            return nil
        }
        var out: [String: Any] = [
            "seq": seq,
            "deferral_reason": "pending_autoupdate_marker",
        ]
        if let ts = boundedString(obj["ts"], max: 64) {
            out["ts"] = ts
        }
        return out
    }

    private static func projectModelLiveness(_ raw: Any?) -> [String: Any]? {
        guard let obj = raw as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        out["token_age_ms"] = strictUInt(obj["token_age_ms"]).map { $0 as Any } ?? NSNull()
        out["active_inference"] = (obj["active_inference"] as? Bool) ?? false
        out["active_inference_age_ms"] = strictUInt(obj["active_inference_age_ms"]).map { $0 as Any } ?? NSNull()
        return out
    }

    // MARK: - Value helpers

    /// Map any incoming label to the SPEC-025 §5.4 public allowlist. The
    /// watchdog already emits the class, but the CLI re-maps defensively so a
    /// raw launchd label can never reach the wire (redaction non-negotiable).
    private static func labelClass(_ raw: Any?) -> String {
        switch raw as? String {
        case "provider-watchdog", "legacy-watchdog":
            return raw as! String
        default:
            return "unknown"
        }
    }

    /// Canonical UUID shape (8-4-4-4-12 hex), matching RouterHandler.serviceInstanceID.
    private static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private static func boundedString(_ value: Any?, max: Int) -> String? {
        guard let string = value as? String else { return nil }
        if string.utf8.count <= max { return string }
        return String(string.prefix(max))
    }

    /// Strict non-negative integer: rejects bools, floats, negatives, and — the
    /// fail-safe requirement — out-of-range/non-finite values that would TRAP on
    /// `UInt64(d)`. A malformed beacon must always resolve to nil, never crash
    /// the heartbeat.
    private static func strictUInt(_ value: Any?) -> UInt64? {
        if let n = value as? UInt64 { return n }
        if let i = value as? Int, i >= 0 { return UInt64(i) }
        if let n = value as? NSNumber {
            // Reject bools (NSNumber bridges true/false) and non-integers.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            guard d.isFinite, d >= 0, d.rounded() == d, d <= Double(UInt64.max) else { return nil }
            return UInt64(exactly: d)
        }
        return nil
    }

    /// Current boot session UUID via `kern.bootsessionuuid` (immutable per boot,
    /// unaffected by wall-clock correction).
    static func bootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: bytes)
    }
}
