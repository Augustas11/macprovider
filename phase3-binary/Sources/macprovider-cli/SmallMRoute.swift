import ArgumentParser
import CryptoKit
import Foundation
import MacProviderCore

/// SPEC-048-R003 / SPEC-038 FR-CB9 (#2335): the MLX core route for small-row
/// affine quantized matmuls in this process.
///
/// `rowInvariant` is the core default: rows 1-16 take kernels with one
/// reduction order, so a row computes the same bits alone and inside a
/// continuous batch. `serialOnly` sets `MLX_METAL_SMALL_M_ROW_INVARIANT=0`,
/// the MLX fork's pre-window per-row `qmv` below the `qmm` limit, which is faster for one row
/// but not row-invariant. Only a process that can never batch decode rows may
/// run it, and such a process refuses every batching entry point.
enum SmallMRoute: String, Sendable, Equatable {
    case rowInvariant = "row_invariant"
    case serialOnly = "serial_only"

    /// Read once per process by the MLX core at its first small-row dispatch;
    /// anything but "0" keeps the row-invariant window.
    static let environmentKey = "MLX_METAL_SMALL_M_ROW_INVARIANT"

    struct Decision: Sendable, Equatable {
        let route: SmallMRoute
        let reason: String
    }

    /// The persisted FR-CB10 self-check verdict for the startup model, as
    /// `SmallMRouteVerdictStore` reads it before MLX starts.
    enum SelfCheckVerdict: String, Sendable, Equatable, CaseIterable {
        /// No verdict was recorded for this startup identity.
        case absent
        /// A verdict was recorded, but its self-check key has no decided
        /// record any more (key changed, record pruned).
        case staleKey = "stale_key"
        /// The record is unfinished or has a re-measurement scheduled.
        case recheckPending = "recheck_pending"
        /// The decided verdict serves more than one row.
        case grantsBatching = "grants_batching"
        /// The decided verdict serves one row: `no_net_gain`, a row
        /// divergence, a crash or a probe that cannot fit.
        case grantsNoBatching = "grants_no_batching"
    }

    /// Everything the route depends on, resolved before MLX is first used.
    struct Inputs: Sendable, Equatable {
        var continuousBatching: ContinuousBatchingMode
        var continuousBatchingExplicitlyConfigured: Bool
        var nativeMTPMode: NativeMTPMode
        /// A native-MTP admission set this process could load for its model:
        /// a feed-resolved sidecar, or `native-mtp-admission.json` next to the
        /// model. Only startup and a creative-hold restore of the same model
        /// load a drafter, so none present means `auto` stays inactive.
        var nativeMTPAdmissionPresent: Bool
        var draftConfigured: Bool
        var shardGroupRole: Bool
        var autotuneCandidate: Bool
        /// Another model this process may warm-swap to; it would be served
        /// without its own self-check here.
        var otherSwitchTargets: Bool
        var selfCheckVerdict: SelfCheckVerdict

        /// `key=value` pairs naming each condition, for the startup event.
        var logFields: String {
            let cb = "\(continuousBatching.rawValue)/\(continuousBatchingExplicitlyConfigured ? "explicit" : "implicit")"
            return "cb=\(cb) native_mtp=\(nativeMTPMode.rawValue) mtp_admission=\(nativeMTPAdmissionPresent ? "present" : "absent") "
                + "draft=\(draftConfigured) shard=\(shardGroupRole) autotune_candidate=\(autotuneCandidate) "
                + "switch_targets=\(otherSwitchTargets) self_check=\(selfCheckVerdict.rawValue)"
        }
    }

    /// SPEC-038 FR-CB9: the route a `serve` process runs, decided once before
    /// MLX is first used, from state that cannot turn batching on later in
    /// the same process. Serial-only needs all of:
    /// - native MTP inactive: mode `off`, or `auto` with no admission set for
    ///   the model (its rounds batch target rows);
    /// - continuous batching unable to activate: set `off` explicitly (the
    ///   emergency override, which no signed policy, self-check or swap
    ///   lifts), or a decided self-check verdict for the current key that
    ///   serves one row with no re-check scheduled;
    /// - no draft model, no shard-group role, no other switch target, and not
    ///   an autotune child (a child measures candidate configurations that
    ///   may batch, and its numbers must hold for the invariant route the
    ///   incumbent serves on).
    /// A verdict recorded on the invariant route stays valid on the serial
    /// route: it says batching gives no net gain against the invariant serial
    /// baseline, and the serial route's baseline is faster, so the verdict
    /// only gets more true. A serial-only process never measures, so no
    /// serial-route number is ever compared with a batched one.
    static func decide(_ inputs: Inputs) -> Decision {
        if inputs.draftConfigured { return Decision(route: .rowInvariant, reason: "draft_model") }
        if inputs.shardGroupRole { return Decision(route: .rowInvariant, reason: "shard_group") }
        if inputs.autotuneCandidate { return Decision(route: .rowInvariant, reason: "autotune_candidate") }
        if inputs.nativeMTPMode != .off, inputs.nativeMTPAdmissionPresent {
            return Decision(route: .rowInvariant, reason: "native_mtp_admission_present")
        }
        if inputs.otherSwitchTargets { return Decision(route: .rowInvariant, reason: "switch_targets") }
        if inputs.continuousBatchingExplicitlyConfigured, inputs.continuousBatching == .off {
            return Decision(route: .serialOnly, reason: "continuous_batching_off_by_configuration")
        }
        switch inputs.selfCheckVerdict {
        case .grantsNoBatching:
            return Decision(route: .serialOnly, reason: "self_check_no_batching")
        case .absent:
            return Decision(route: .rowInvariant, reason: "self_check_verdict_absent")
        case .staleKey:
            return Decision(route: .rowInvariant, reason: "self_check_key_changed")
        case .recheckPending:
            return Decision(route: .rowInvariant, reason: "self_check_recheck_pending")
        case .grantsBatching:
            return Decision(route: .rowInvariant, reason: "self_check_grants_batching")
        }
    }

    /// True when every condition but the self-check verdict already allows
    /// the serial route: a verdict of one row recorded now moves the next
    /// start of this configuration to it.
    static func verdictDecidesNextStart(_ inputs: Inputs) -> Bool {
        var withVerdict = inputs
        withVerdict.selfCheckVerdict = .grantsNoBatching
        return decide(withVerdict).route == .serialOnly
            && !(inputs.continuousBatchingExplicitlyConfigured && inputs.continuousBatching == .off)
    }

    /// The route the MLX core takes for a given environment value.
    static func route(environmentValue: String?) -> SmallMRoute {
        environmentValue == "0" ? .serialOnly : .rowInvariant
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var applied: SmallMRoute?
    nonisolated(unsafe) private static var appliedReason: String?

    /// The route this process runs: the one `apply` set, else the one the
    /// inherited environment gives the MLX core.
    static var processRoute: SmallMRoute {
        lock.lock()
        defer { lock.unlock() }
        return applied ?? route(environmentValue: ProcessInfo.processInfo.environment[environmentKey])
    }

    /// Why the process runs its route, for `/v1/status`.
    static var processReason: String {
        lock.lock()
        defer { lock.unlock() }
        return appliedReason ?? "environment"
    }

    /// Sets the environment for this process before MLX's first small-row
    /// dispatch. Row-invariant removes any inherited value, so a stray "0"
    /// never reaches a process that can batch. The first call wins; a later
    /// call returns the route already applied.
    @discardableResult
    static func apply(_ route: SmallMRoute, reason: String = "applied") -> SmallMRoute {
        lock.lock()
        defer { lock.unlock() }
        if let applied { return applied }
        switch route {
        case .serialOnly: setenv(environmentKey, "0", 1)
        case .rowInvariant: unsetenv(environmentKey)
        }
        applied = route
        appliedReason = reason
        return route
    }

    /// The startup event serve and decode-bench print.
    static func event(_ decision: Decision, fields: String? = nil) -> String {
        "event=small_m_route mode=\(decision.route.rawValue) reason=\(decision.reason)\(fields.map { " " + $0 } ?? "")\n"
    }

    /// Nil when a process on `route` may batch rows, else why `entry` refuses.
    static func batchingRefusal(route: SmallMRoute, entry: String) -> String? {
        guard route == .serialOnly else { return nil }
        return "small_m_route_serial_only: \(entry) batches decode rows, but this process runs the serial-only small-row route (\(environmentKey)=0), which is not row-invariant"
    }

    /// For lab commands that batch rows: exits 2 on a serial-only process,
    /// else pins the row-invariant route before MLX starts.
    static func requireRowInvariant(entry: String) throws {
        if let refusal = batchingRefusal(route: processRoute, entry: entry) {
            FileHandle.standardError.write(Data("\(refusal)\n".utf8))
            throw ExitCode(2)
        }
        apply(.rowInvariant, reason: "batching_command")
    }

    /// SPEC-037 FR-KVP4 item 10: the decode-path class in a disk-cache
    /// envelope. KV written on one route is a clean miss on the other.
    var kvDecodePath: String {
        switch self {
        case .rowInvariant: return KVBuildIdentity.decodePathOrdinary
        case .serialOnly: return KVBuildIdentity.decodePathOrdinary + "+serial_small_m"
        }
    }
}

/// SPEC-038 FR-CB9: which self-check key a `serve` startup identity resolved
/// to, so the next start can read the verdict before MLX is first used. The
/// self-check key itself needs the loaded model (cache class, scheduler
/// window, Metal identity), so it cannot be computed that early; the startup
/// identity covers every input that key and the self-check ladder are derived
/// from (model bytes, binary, OS, hardware, signed policy, slot and context
/// configuration). The verdict is still read from the self-check store under
/// that key, so a pruned or re-measuring record is never trusted. A private
/// (0600, owner-only, no symlinks) JSON file next to `cb-self-check.json`.
struct SmallMRouteVerdictStore: Sendable {
    static let schemaVersion = "macprovider.small-m-route.v1"
    static let fileName = "small-m-route.json"
    static let maxEntries = 16
    static let maxFileBytes: off_t = 1 << 20

    let url: URL

    struct Entry: Codable, Equatable {
        let startupIdentity: String
        let key: ContinuousBatchingSelfCheckKey

        enum CodingKeys: String, CodingKey {
            case startupIdentity = "startup_identity"
            case key
        }
    }

    private struct Document: Codable {
        let schemaVersion: String
        let entries: [Entry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case entries
        }
    }

    init(selfCheckStore: ContinuousBatchingSelfCheckStore) {
        url = selfCheckStore.url.deletingLastPathComponent().appendingPathComponent(Self.fileName)
    }

    init(url: URL) {
        self.url = url
    }

    /// SHA-256 over sorted `name=value` lines.
    static func startupIdentity(_ components: [String: String]) -> String {
        let canonical = components.keys.sorted().map { "\($0)=\(components[$0] ?? "")\n" }.joined()
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The verdict a stored self-check record gives the route. Nil: the key
    /// has no record.
    static func verdict(record: ContinuousBatchingSelfCheckStore.Record?) -> SmallMRoute.SelfCheckVerdict {
        guard let record else { return .staleKey }
        guard let decision = record.decision,
              record.inProgressSlots == nil,
              record.remeasureAfter == nil,
              record.remeasureInProgress != true,
              record.widthProgress == nil
        else { return .recheckPending }
        return decision.slots > 1 ? .grantsBatching : .grantsNoBatching
    }

    func verdict(startupIdentity: String, selfCheckStore: ContinuousBatchingSelfCheckStore) -> SmallMRoute.SelfCheckVerdict {
        guard let entry = read().last(where: { $0.startupIdentity == startupIdentity }) else { return .absent }
        return Self.verdict(record: selfCheckStore.record(for: entry.key))
    }

    /// Records the self-check key the startup identity resolved to when its
    /// decision serves one row, and forgets it otherwise. Returns true when
    /// the next start with this identity reads a one-row verdict.
    @discardableResult
    func record(startupIdentity: String, key: ContinuousBatchingSelfCheckKey, decision: ContinuousBatchingSelfCheckDecision) -> Bool {
        var entries = read().filter { $0.startupIdentity != startupIdentity }
        let oneRow = decision.slots <= 1
        if oneRow { entries.append(Entry(startupIdentity: startupIdentity, key: key)) }
        if entries.count > Self.maxEntries { entries = Array(entries.suffix(Self.maxEntries)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Document(schemaVersion: Self.schemaVersion, entries: entries)),
              (try? write(data)) != nil
        else { return false }
        return oneRow
    }

    private func read() -> [Entry] {
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
        return document.entries
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

/// Writes the startup model's applied self-check decision to the verdict
/// store, once per key, and logs when it moves the next start to the serial
/// route. Only built when every other serial-only condition holds.
final class SmallMRouteVerdictRecorder: @unchecked Sendable {
    private let store: SmallMRouteVerdictStore
    private let selfCheckStore: ContinuousBatchingSelfCheckStore
    private let startupIdentity: String
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var startupModelSHA256: String?
    private var lastRecorded: (ContinuousBatchingSelfCheckKey, ContinuousBatchingSelfCheckDecision)?

    init(
        store: SmallMRouteVerdictStore,
        selfCheckStore: ContinuousBatchingSelfCheckStore,
        startupIdentity: String,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.store = store
        self.selfCheckStore = selfCheckStore
        self.startupIdentity = startupIdentity
        self.log = log
    }

    func applied(key: ContinuousBatchingSelfCheckKey, decision: ContinuousBatchingSelfCheckDecision) {
        lock.lock()
        defer { lock.unlock() }
        // The first key applied is the startup model's; a warm-swapped model
        // never writes under the startup identity.
        if startupModelSHA256 == nil { startupModelSHA256 = key.modelSHA256 }
        guard key.modelSHA256 == startupModelSHA256 else { return }
        if let lastRecorded, lastRecorded.0 == key, lastRecorded.1 == decision { return }
        lastRecorded = (key, decision)
        store.record(startupIdentity: startupIdentity, key: key, decision: decision)
        let next = store.verdict(startupIdentity: startupIdentity, selfCheckStore: selfCheckStore) == .grantsNoBatching
        log("event=small_m_route action=verdict_recorded decision=\(decision.reason) slots=\(decision.slots) next_start=\(next ? SmallMRoute.serialOnly.rawValue : SmallMRoute.rowInvariant.rawValue)")
    }
}
