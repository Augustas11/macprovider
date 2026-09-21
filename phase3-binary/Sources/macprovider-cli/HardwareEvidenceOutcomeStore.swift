import Darwin
import Foundation

/// Issue #1616 — durable record of the last hardware-evidence submission.
///
/// The 2026-09-19 Mac Studio recovery stalled because the reason a provider
/// could not complete onboarding (`hardware_evidence_unavailable: HTTP 429`,
/// and behind it a stuck `waiting_trust` job) was printed once to stderr by
/// `autotune --recommend --submit-hardware-evidence` and then lost. An
/// operator who missed that line had no way to ask the box what happened; the
/// answer only existed in the coordinator's Postgres and journald, which a
/// provider operator cannot read.
///
/// This records the outcome locally so `malibu-cli doctor` can answer it
/// afterwards. It is diagnostics only: nothing reads it back to make an
/// admission, trust, or retry decision, so a missing, stale, or unreadable
/// record degrades to "unknown" and never to a permissive default.
struct HardwareEvidenceOutcome: Codable, Equatable, Sendable {
    /// `submitted`, `skipped`, or `failed` — the submission case that occurred.
    let outcome: String
    /// Human-readable detail. Already sanitized on write (see `sanitize`):
    /// coordinator-derived text reaches this only through the allowlisted
    /// summary in `AutotuneHardwareEvidenceSubmitter`, and this bounds and
    /// strips it again before it can reach an operator's terminal.
    let reason: String?
    /// ISO-8601 instant the attempt was recorded.
    let recordedAt: String

    enum CodingKeys: String, CodingKey {
        case outcome
        case reason
        case recordedAt = "recorded_at"
    }
}

enum HardwareEvidenceOutcomeStore {
    enum StoreError: Error, Equatable {
        case unsafePath
        case ioFailure
        case malformed
    }

    /// Maximum retained reason length. Bounded so an unexpectedly long
    /// coordinator or URLError string cannot flood doctor output or the file.
    static let maximumReasonLength = 240

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macprovider/last-hardware-evidence.json")
    }

    /// Keeps only printable ASCII. C0/C1 control bytes — including the U+009B
    /// single-byte CSI that survives a naive ESC filter — are dropped rather
    /// than escaped, so a reason rendered in a terminal cannot move the cursor
    /// or set attributes.
    static func sanitize(_ reason: String?) -> String? {
        guard let reason else { return nil }
        let kept = reason.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }
        let collapsed = String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty { return nil }
        return String(collapsed.prefix(maximumReasonLength))
    }

    static func record(
        _ submission: AutotuneHardwareEvidenceSubmission,
        at now: Date = Date(),
        to url: URL = defaultURL
    ) {
        let outcome: HardwareEvidenceOutcome
        switch submission {
        case .submitted:
            outcome = HardwareEvidenceOutcome(
                outcome: "submitted",
                reason: nil,
                recordedAt: ISO8601DateFormatter.autotuneInternet.string(from: now)
            )
        case .skipped(let reason):
            outcome = HardwareEvidenceOutcome(
                outcome: "skipped",
                reason: sanitize(reason),
                recordedAt: ISO8601DateFormatter.autotuneInternet.string(from: now)
            )
        case .failed(let reason):
            outcome = HardwareEvidenceOutcome(
                outcome: "failed",
                reason: sanitize(reason),
                recordedAt: ISO8601DateFormatter.autotuneInternet.string(from: now)
            )
        }
        // Best effort: failing to write a diagnostics breadcrumb must never
        // fail the submission it is describing.
        try? write(outcome, to: url)
    }

    static func write(_ outcome: HardwareEvidenceOutcome, to url: URL = defaultURL) throws {
        try ensurePrivateParentDirectory(for: url, create: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try writePrivateFile(encoder.encode(outcome), to: url)
    }

    static func read(from url: URL = defaultURL) throws -> HardwareEvidenceOutcome {
        try ensurePrivateParentDirectory(for: url, create: false)
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { throw StoreError.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o022) == 0,
              st.st_size <= 8192
        else {
            try? handle.close()
            throw StoreError.unsafePath
        }
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        guard let decoded = try? JSONDecoder().decode(HardwareEvidenceOutcome.self, from: data) else {
            throw StoreError.malformed
        }
        // Re-sanitize on read: the file is owner-only, but a record written by
        // an older build predates the write-side filter.
        return HardwareEvidenceOutcome(
            outcome: sanitize(decoded.outcome) ?? "unknown",
            reason: sanitize(decoded.reason),
            recordedAt: sanitize(decoded.recordedAt) ?? ""
        )
    }

    private static func ensurePrivateParentDirectory(for url: URL, create: Bool) throws {
        let parent = url.deletingLastPathComponent()
        var st = stat()
        if lstat(parent.path, &st) != 0 {
            guard create else { throw StoreError.unsafePath }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            guard lstat(parent.path, &st) == 0 else { throw StoreError.ioFailure }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw StoreError.unsafePath
        }
    }

    /// Owner-only atomic replace with an fsync before rename, matching
    /// RecommendationStateStore: a crash must not leave a truncated record.
    private static func writePrivateFile(_ data: Data, to url: URL) throws {
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG, existing.st_uid == getuid() else {
                throw StoreError.unsafePath
            }
        } else if errno != ENOENT {
            throw StoreError.ioFailure
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = temporary.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { throw StoreError.ioFailure }
        var closed = false
        defer {
            if !closed { close(fd) }
            _ = unlink(temporary.path)
        }
        guard fchmod(fd, 0o600) == 0 else { throw StoreError.ioFailure }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw StoreError.ioFailure
                }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw StoreError.ioFailure }
        guard close(fd) == 0 else { throw StoreError.ioFailure }
        closed = true
        guard rename(temporary.path, url.path) == 0 else { throw StoreError.ioFailure }
    }
}
