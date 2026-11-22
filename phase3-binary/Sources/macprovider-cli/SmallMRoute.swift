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
/// `stockOrder` sets the value to 2: one row takes upstream's one-row kernel,
/// a forward of exactly two rows takes an exact kernel whose rows equal the
/// lone row bit for bit, and forwards of 3-16 rows take the batch kernel,
/// whose rows equal each other across 3-16-row forwards but may differ from
/// the lone row in low bits. A process that may batch ordinary rows but has
/// no native MTP, draft model, shard-group role, autotune child or other
/// switch target runs it; native MTP needs `rowInvariant` because its verify
/// window of depth + 1 rows must equal the request's own one-row decode. A
/// process that would keep `rowInvariant` only for native MTP runs `mixed`
/// (v0.3.61, #2462): stock order for the process, `rowInvariant` for each
/// native-admitted request (`SmallMRouteScope`).
enum SmallMRoute: String, Sendable, Equatable {
    case rowInvariant = "row_invariant"
    case serialOnly = "serial_only"
    case stockOrder = "stock_order"

    /// Read once per process by the MLX core when the first quantized matmul
    /// is added to a graph (each op captures its route at graph build, from
    /// a thread scope or else this value); unset, or a value `atoi` parses
    /// to neither 0 nor 2, keeps the row-invariant window
    /// (`route(environmentValue:)`).
    static let environmentKey = "MLX_METAL_SMALL_M_ROW_INVARIANT"
    /// The core's qmv_mma partial-sum count over K, also read once per
    /// process. Its default follows the route (4 on the row-invariant route,
    /// 8 on stock order on some GPU generations); an inherited value would
    /// change a process's output bits with no self-check or cache key
    /// noticing, so only lab builds keep it.
    static let partialSumsEnvironmentKey = "MLX_METAL_QMV_MMA_WK"

    /// Removes an inherited `partialSumsEnvironmentKey` outside lab builds.
    /// Returns true when a value was removed.
    @discardableResult
    static func removeInheritedPartialSums() -> Bool {
        #if MACPROVIDER_LAB_HARNESS
        return false
        #else
        guard getenv(partialSumsEnvironmentKey) != nil else { return false }
        unsetenv(partialSumsEnvironmentKey)
        return true
        #endif
    }

    struct Decision: Sendable, Equatable {
        let route: SmallMRoute
        let reason: String
        /// SPEC-038 FR-CB9 (v0.3.61) `mixed`: `route` is the process route
        /// (`stockOrder`) and native-admitted requests run `rowInvariant`.
        var mixed = false

        /// The mode the startup event and `/v1/status` name.
        var mode: String { mixed ? SmallMRoute.mixedMode : route.rawValue }
    }

    /// SPEC-038 FR-CB9 (v0.3.61): the mode name of a `mixed` process and its reason.
    static let mixedMode = "mixed"
    static let nativeMTPPerRequest = "native_mtp_per_request"

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

    /// The native-MTP admission set where the startup loader looks for it
    /// (`ModelRuntime.loadNativeMTPDrafterIfAdmitted`), against the loaded
    /// model. Startup is the only activation: a creative-hold restore
    /// reloads only a tuple that startup activated.
    enum NativeMTPAdmission: String, Sendable, Equatable, CaseIterable {
        /// No set where the loader looks, or no verified artifact digest
        /// (the loader then never runs).
        case none
        /// A verified set with no entry for this model and artifact digest,
        /// such as the baked feed for a model it does not name.
        case noEntryForModel = "no_entry_for_model"
        case entryForModel = "entry_for_model"
        /// A set that cannot be read or whose signature fails.
        case unverifiable

        /// Whether `auto` could activate native MTP for the loaded model.
        /// An unverifiable set counts, so doubt keeps the invariant route.
        var mayActivate: Bool { self == .entryForModel || self == .unverifiable }
    }

    /// Resolves `NativeMTPAdmission` for a set at `sidecarURL`, with its
    /// signature beside it, matched as the loader matches it.
    static func nativeMTPAdmission(
        sidecarURL: URL,
        modelID: String,
        modelRevision: String,
        trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring = NativeMTPAdmissionSidecar.TrustedKeyring(
            publicKeysByKeyID: AutotuneStaticInputs.defaultTrustedPublicKeys,
            requiredKeyID: AutotuneStaticInputs.keyID
        )
    ) -> NativeMTPAdmission {
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return .none }
        do {
            return try NativeMTPAdmissionSidecar.namesEntry(
                sidecarURL: sidecarURL,
                signatureURL: sidecarURL.deletingLastPathComponent()
                    .appendingPathComponent(NativeMTPAdmissionFeed.signatureFileName),
                trustedKeyring: trustedKeyring,
                modelID: modelID,
                modelRevision: modelRevision
            ) ? .entryForModel : .noEntryForModel
        } catch {
            return .unverifiable
        }
    }

    /// Everything the route depends on, resolved before MLX is first used.
    struct Inputs: Sendable, Equatable {
        var continuousBatching: ContinuousBatchingMode
        var continuousBatchingExplicitlyConfigured: Bool
        var nativeMTPMode: NativeMTPMode
        var nativeMTPAdmission: NativeMTPAdmission
        var draftConfigured: Bool
        var shardGroupRole: Bool
        var autotuneCandidate: Bool
        /// Another model this process may warm-swap to (it would be served
        /// without its own self-check here) or loads beside the startup model
        /// (`warm_models`): the route is decided once, from the startup model
        /// only, and a further model's native MTP needs the row-invariant
        /// route.
        var otherSwitchTargets: Bool
        var selfCheckVerdict: SelfCheckVerdict
        /// SPEC-038 FR-CB9 (v0.3.56): why this startup identity left the
        /// stock order route (`SmallMRouteVerdictStore.stockOrderFallback`),
        /// or nil.
        var stockOrderFallback: String? = nil
        /// SPEC-038 FR-CB9 (v0.3.56): config `small_m_route: row_invariant`.
        var operatorForcesRowInvariant: Bool = false

        /// `key=value` pairs naming each condition, for the startup event.
        var logFields: String {
            let cb = "\(continuousBatching.rawValue)/\(continuousBatchingExplicitlyConfigured ? "explicit" : "implicit")"
            return "cb=\(cb) native_mtp=\(nativeMTPMode.rawValue) mtp_admission=\(nativeMTPAdmission.rawValue) "
                + "draft=\(draftConfigured) shard=\(shardGroupRole) autotune_candidate=\(autotuneCandidate) "
                + "switch_targets=\(otherSwitchTargets) self_check=\(selfCheckVerdict.rawValue)"
                + (stockOrderFallback.map { " stock_order_fallback=\($0)" } ?? "")
                + (operatorForcesRowInvariant ? " operator_small_m_route=row_invariant" : "")
        }
    }

    /// SPEC-038 FR-CB9: the route a `serve` process runs, decided once before
    /// MLX is first used, from state that cannot turn batching on later in
    /// the same process. A draft model, shard-group role, autotune child,
    /// or another switch target keeps the row-invariant route. Native MTP
    /// that may activate takes `mixed` (v0.3.61: stock order process route,
    /// row-invariant native requests) when batching can activate and no
    /// stock order fallback or operator override applies, and keeps the
    /// row-invariant route otherwise. Otherwise serial-only needs all of:
    /// - native MTP inactive: mode `off`, or `auto` with no verified entry
    ///   for the loaded model and artifact digest (its rounds batch target
    ///   rows); an unreadable or unverifiable set keeps the invariant route;
    /// - continuous batching unable to activate: set `off` explicitly (the
    ///   emergency override, which no signed policy, self-check or swap
    ///   lifts), or a decided self-check verdict for the current key that
    ///   serves one row with no re-check scheduled;
    /// - no draft model, no shard-group role, no other switch target, and not
    ///   an autotune child (a child measures candidate configurations that
    ///   may batch on the row-invariant route; autotune compares children
    ///   only with each other, cached child results and catalog gates, never
    ///   with the stopped incumbent's numbers).
    /// Every other such process may batch ordinary rows and takes the stock
    /// order route, with the self-check verdict as its reason, unless a
    /// failure measured on stock order for this startup identity sent it to
    /// the row-invariant route (`stockOrderFallback`, sticky for the
    /// identity; a new runtime build is a new identity and re-decides). A
    /// one-row verdict then counts only if it was measured on the
    /// row-invariant route, as it does today.
    /// `operatorForcesRowInvariant` turns only that stock order decision into
    /// the row-invariant route (`operator_row_invariant`); it never changes a
    /// serial-only or another row-invariant decision, and batching stays on.
    /// A one-row verdict recorded on a batching route stays valid on the
    /// serial route: it says batching gives no net gain against that route's
    /// serial baseline (on stock order the same upstream one-row kernel the
    /// serial route runs), or that rows diverged, which the serial route
    /// never risks. A serial-only process never measures, so no serial-route
    /// number is ever compared with a batched one.
    /// The SPEC-039 two-row attach probe (`PagedKVRuntimeParityProbe`)
    /// compares a two-row forward with serial decode exactly; on stock order
    /// it stays valid only because the core's two-row kernel is exact against
    /// its lone row.
    /// `Inputs.otherSwitchTargets`: a switch target other than the startup
    /// model, or any configured further model (SPEC-001-R017 `warm_models`).
    static func servesOtherModels(
        switchTargets: some Sequence<String>,
        startupModelIDs: Set<String>,
        warmModels: [String]
    ) -> Bool {
        !warmModels.isEmpty || switchTargets.contains { !startupModelIDs.contains($0.lowercased()) }
    }

    static func decide(_ inputs: Inputs) -> Decision {
        if inputs.draftConfigured { return Decision(route: .rowInvariant, reason: "draft_model") }
        if inputs.shardGroupRole { return Decision(route: .rowInvariant, reason: "shard_group") }
        if inputs.autotuneCandidate { return Decision(route: .rowInvariant, reason: "autotune_candidate") }
        if inputs.nativeMTPMode != .off, inputs.nativeMTPAdmission.mayActivate {
            // SPEC-038 FR-CB9 (v0.3.61): native MTP needs the row-invariant
            // route only for its own requests. With every other stock order
            // condition met the process takes `mixed`; any other reason to
            // keep the pair keeps it process-wide, as before.
            let keep = Decision(route: .rowInvariant, reason: "native_mtp_\(inputs.nativeMTPAdmission.rawValue)")
            if inputs.otherSwitchTargets
                || (inputs.continuousBatchingExplicitlyConfigured && inputs.continuousBatching == .off)
                || inputs.selfCheckVerdict == .grantsNoBatching {
                return keep
            }
            if let fallback = inputs.stockOrderFallback { return Decision(route: .rowInvariant, reason: fallback) }
            if inputs.operatorForcesRowInvariant { return Decision(route: .rowInvariant, reason: operatorRowInvariant) }
            return Decision(route: .stockOrder, reason: nativeMTPPerRequest, mixed: true)
        }
        if inputs.otherSwitchTargets { return Decision(route: .rowInvariant, reason: "switch_targets") }
        if inputs.continuousBatchingExplicitlyConfigured, inputs.continuousBatching == .off {
            return Decision(route: .serialOnly, reason: "continuous_batching_off_by_configuration")
        }
        if inputs.selfCheckVerdict == .grantsNoBatching {
            return Decision(route: .serialOnly, reason: "self_check_no_batching")
        }
        if let fallback = inputs.stockOrderFallback {
            return Decision(route: .rowInvariant, reason: fallback)
        }
        // Every decision left below is stock order.
        if inputs.operatorForcesRowInvariant {
            return Decision(route: .rowInvariant, reason: operatorRowInvariant)
        }
        switch inputs.selfCheckVerdict {
        case .grantsNoBatching:
            return Decision(route: .serialOnly, reason: "self_check_no_batching")
        case .absent:
            return Decision(route: .stockOrder, reason: "self_check_verdict_absent")
        case .staleKey:
            return Decision(route: .stockOrder, reason: "self_check_key_changed")
        case .recheckPending:
            return Decision(route: .stockOrder, reason: "self_check_recheck_pending")
        case .grantsBatching:
            return Decision(route: .stockOrder, reason: "self_check_grants_batching")
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

    /// SPEC-038 FR-CB9 (v0.3.56) stock order fallback reasons.
    static let stockOrderDivergence = "stock_order_divergence"
    static let stockOrderCrash = "stock_order_crash"
    static let stockOrderAttachFailed = "stock_order_attach_failed"
    static let stockOrderReferenceUnfit = "stock_order_reference_unfit"
    /// The reason when config `small_m_route: row_invariant` replaced stock order.
    static let operatorRowInvariant = "operator_row_invariant"

    /// The fallback a self-check result measured on stock order gives the
    /// next start: any width whose rows diverged (a same-order reference
    /// whose rows disagree is one), or a crashed step. Nil for every other
    /// result, including no net gain, which says batching does not beat the
    /// one-row kernel the serial route also runs.
    static func stockOrderFallbackReason(
        decision: ContinuousBatchingSelfCheckDecision,
        anyWidthDiverged: Bool,
        crashed: Bool
    ) -> String? {
        if anyWidthDiverged || decision.reason.hasPrefix("row_divergence_at_") { return stockOrderDivergence }
        if crashed || decision.reason.hasPrefix("crashed_at_") { return stockOrderCrash }
        return nil
    }

    /// Whether the SPEC-039 attach probes ran and failed: the paged parity
    /// probe did not establish parity, or the two-row shared-forward probe
    /// saw a row fail, rows diverge, or (with a distinguishing challenge)
    /// tokens differ from serial decode. Probes that did not run (nil), or a
    /// challenge that could not distinguish its rows, are not failures.
    static func attachProbeFailed(
        parity: PagedKVRuntimeParityProbeResult?,
        isolation: PagedKVRuntimeMoEProbeResult?
    ) -> Bool {
        guard let parity, let isolation else { return false }
        if !parity.established { return true }
        if isolation.rowFailures > 0 || isolation.crossRowDivergences > 0 { return true }
        return isolation.challengeDistinguishing && !isolation.sharedForwardParityProven
    }

    /// The route the MLX core takes for a given environment value. The core
    /// parses a set value with C `atoi` and leaves the window off when it is
    /// 0, so "", "false", "00", "-0", " 0", "0abc" and, on Darwin, a value
    /// that wraps to 0 such as "4294967296" are all serial-only; a value that
    /// parses to 2 ("2", "02", " 2") is stock order. This calls the same C
    /// library `atoi`, so the label matches the core.
    static func route(environmentValue: String?) -> SmallMRoute {
        guard let environmentValue else { return .rowInvariant }
        switch environmentValue.withCString({ atoi($0) }) {
        case 0: return .serialOnly
        case 2: return .stockOrder
        default: return .rowInvariant
        }
    }

    /// SPEC-038 FR-CB9: the count a serial-only `serve` serves and reports,
    /// the same as the row-invariant route serves for the same Mac. With a
    /// stored one-row decision that is the self-check's served count (owner
    /// pin, capped by the verified count and the rows); with continuous
    /// batching off by configuration it is the count already planned (the
    /// owner pin, else one), as an emergency-off process serves.
    static func serialOnlyServedSlots(
        stored decision: ContinuousBatchingSelfCheckDecision?,
        ownerPinned: Int?,
        servedNow: Int
    ) -> Int {
        guard let decision else { return max(1, servedNow) }
        return ContinuousBatchingSelfCheck.servedSlots(decision: decision, ownerPinned: ownerPinned, maxRows: servedNow)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var applied: SmallMRoute?
    nonisolated(unsafe) private static var appliedReason: String?
    nonisolated(unsafe) private static var appliedMixed = false

    /// SPEC-038 FR-CB9 (v0.3.61): whether this process runs `mixed`.
    static var processMixed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return applied != nil && appliedMixed
    }

    /// The mode `/v1/status` reports: `mixed`, or the process route.
    static var processMode: String {
        processMixed ? mixedMode : processRoute.rawValue
    }

    /// SPEC-038 FR-CB9 (v0.3.61): the route a request's forwards are built
    /// on, fixed once at admission. In `mixed` a native-admitted request runs
    /// the row-invariant route for its whole life, ordinary fallback
    /// included, and every other request the stock order process route; in
    /// every other mode each request runs the process route.
    static func requestRoute(
        nativeAdmitted: Bool,
        processRoute: SmallMRoute = SmallMRoute.processRoute,
        mixed: Bool = SmallMRoute.processMixed
    ) -> SmallMRoute {
        guard mixed else { return processRoute }
        return nativeAdmitted ? .rowInvariant : .stockOrder
    }

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

    /// Sets the environment for this process before MLX first builds a
    /// small-row quantized matmul: the core reads the process route once,
    /// when the first such op is added to a graph, and each op keeps the
    /// route it was built on. Row-invariant removes any inherited value, so
    /// a stray "0" or "2" never reaches a process that needs the invariant
    /// route. `mixed` (v0.3.61) applies the stock order route and marks the
    /// process so native-admitted requests scope their forwards to the
    /// row-invariant route. The first call wins; a later call returns the
    /// route already applied.
    @discardableResult
    static func apply(_ route: SmallMRoute, reason: String = "applied", mixed: Bool = false) -> SmallMRoute {
        lock.lock()
        defer { lock.unlock() }
        if removeInheritedPartialSums() {
            FileHandle.standardError.write(Data(
                "event=small_m_route action=inherited_value_removed variable=\(partialSumsEnvironmentKey)\n".utf8
            ))
        }
        if let applied { return applied }
        switch route {
        case .serialOnly: setenv(environmentKey, "0", 1)
        case .stockOrder: setenv(environmentKey, "2", 1)
        case .rowInvariant: unsetenv(environmentKey)
        }
        applied = route
        appliedReason = reason
        appliedMixed = mixed && route == .stockOrder
        return route
    }

    /// The startup event serve and decode-bench print.
    static func event(_ decision: Decision, fields: String? = nil) -> String {
        "event=small_m_route mode=\(decision.mode) reason=\(decision.reason)\(fields.map { " " + $0 } ?? "")\n"
    }

    /// Nil when a process on `route` may batch rows, else why `entry` refuses.
    static func batchingRefusal(route: SmallMRoute, entry: String) -> String? {
        guard route == .serialOnly else { return nil }
        return "small_m_route_serial_only: \(entry) batches decode rows, but this process runs the serial-only small-row route (\(environmentKey)=0), which is not row-invariant"
    }

    /// For every command other than `serve` and `decode-bench` that runs MLX
    /// compute: pins the row-invariant route before MLX starts, removing an
    /// inherited value (any value `atoi` parses to 0 or 2), so the command
    /// never runs the serial or stock order route. Exits 2 only when this
    /// process already applied another route, which no command entry does.
    static func requireRowInvariant(entry: String) throws {
        let inherited = ProcessInfo.processInfo.environment[environmentKey]
        let applied = apply(.rowInvariant, reason: "command")
        if applied != .rowInvariant {
            let refusal = batchingRefusal(route: applied, entry: entry)
                ?? "small_m_route_\(applied.rawValue): \(entry) needs the row-invariant small-row route, but this process already runs \(applied.rawValue)"
            FileHandle.standardError.write(Data("\(refusal)\n".utf8))
            throw ExitCode(2)
        }
        if let inherited, route(environmentValue: inherited) != .rowInvariant {
            FileHandle.standardError.write(Data(
                "event=small_m_route action=inherited_value_removed entry=\(entry) mode=\(applied.rawValue)\n".utf8
            ))
        }
    }

    /// SPEC-037 FR-KVP4 item 10: the decode-path class in a disk-cache
    /// envelope. KV written on one route is a clean miss on every other.
    /// Stock order has its own class, not serial-only's: a lone stock order
    /// row runs the same one-row kernel as serial-only, but a stock order
    /// process also writes KV from rows decoded in 3-16-row forwards (batch
    /// kernel), which serial-only never produces; and its lone-row KV is not
    /// the row-invariant route's either.
    var kvDecodePath: String {
        switch self {
        case .rowInvariant: return KVBuildIdentity.decodePathOrdinary
        case .serialOnly: return KVBuildIdentity.decodePathOrdinary + "+serial_small_m"
        case .stockOrder: return KVBuildIdentity.decodePathOrdinary + "+stock_order_small_m"
        }
    }
}

/// SPEC-038 FR-CB9: which self-check key a `serve` startup identity resolved
/// to, so the next start can read the verdict before MLX is first used. The
/// self-check key itself needs the loaded model (cache class, scheduler
/// window, Metal identity), so it cannot be computed that early; the startup
/// identity covers every input that key and the self-check ladder are derived
/// from (model bytes, binary, OS, hardware, signed policy, slot and context
/// configuration, paged-KV block size and pool). The verdict is still read from the self-check store under
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
        /// The self-check key of a one-row verdict, or nil when the entry
        /// only records a stock order fallback.
        var key: ContinuousBatchingSelfCheckKey?
        /// The route the one-row verdict was measured on; nil for entries
        /// written before routes were recorded.
        var route: String?
        /// SPEC-038 FR-CB9 (v0.3.56): a failure measured on stock order
        /// (`SmallMRoute.stockOrder*` reasons). Sticky for the startup
        /// identity: the next starts take the row-invariant route.
        var stockOrderFallback: String?

        enum CodingKeys: String, CodingKey {
            case startupIdentity = "startup_identity"
            case key
            case route
            case stockOrderFallback = "stock_order_fallback"
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
        if decision.slots > 1 { return .grantsBatching }
        return decidesOneRow(reason: decision.reason) ? .grantsNoBatching : .recheckPending
    }

    /// One-row reasons that settle the key: measured with no gain, a row
    /// divergence or leak, a crash, a configured single row, or
    /// `probe_shape_unavailable` (not even two exactness-probe rows fit).
    /// The last two are fixed by quantities the startup identity keys: the
    /// slot configuration, served context and paged-KV pool. Any change to
    /// them is a new identity that starts on a batching route and
    /// re-measures. Any other one-row reason (`serial_baseline_unavailable`,
    /// `probe_shape_unmet_at_<k>`) re-runs on bound growth, which only a
    /// process on a batching route can do, so it keeps that route.
    static func decidesOneRow(reason: String) -> Bool {
        reason == "no_net_gain" || reason == "single_row" || reason == "probe_shape_unavailable"
            || reason.hasPrefix("row_divergence_at_") || reason.hasPrefix("crashed_at_")
    }

    /// The resolved paged-KV pool for the startup identity, as
    /// `<block size tokens>x<physical blocks>`.
    static func pagedKVPool(_ config: PagedKVConfig) -> String {
        "\(config.blockSizeTokens)x\(config.maxPhysicalBlocks)"
    }

    func verdict(startupIdentity: String, selfCheckStore: ContinuousBatchingSelfCheckStore) -> SmallMRoute.SelfCheckVerdict {
        guard let entry = read().last(where: { $0.startupIdentity == startupIdentity }),
              let key = entry.key
        else { return .absent }
        return Self.verdict(record: selfCheckStore.record(for: key))
    }

    /// The stock order fallback recorded for the startup identity, or nil.
    func stockOrderFallback(startupIdentity: String) -> String? {
        read().last(where: { $0.startupIdentity == startupIdentity })?.stockOrderFallback
    }

    /// The route `SmallMRoute.decide` gives the next start of this identity
    /// when nothing but the verdict and the fallback decide it.
    func nextStartRoute(startupIdentity: String, selfCheckStore: ContinuousBatchingSelfCheckStore) -> SmallMRoute {
        if verdict(startupIdentity: startupIdentity, selfCheckStore: selfCheckStore) == .grantsNoBatching { return .serialOnly }
        return stockOrderFallback(startupIdentity: startupIdentity) == nil ? .stockOrder : .rowInvariant
    }

    /// The stored decision behind a `grantsNoBatching` verdict, for the
    /// refused self-check state a serial-only process reports.
    func oneRowDecision(
        startupIdentity: String,
        selfCheckStore: ContinuousBatchingSelfCheckStore
    ) -> (key: ContinuousBatchingSelfCheckKey, decision: ContinuousBatchingSelfCheckDecision)? {
        guard let entry = read().last(where: { $0.startupIdentity == startupIdentity }),
              let key = entry.key,
              let record = selfCheckStore.record(for: key),
              Self.verdict(record: record) == .grantsNoBatching,
              let decision = record.decision
        else { return nil }
        return (key, decision)
    }

    /// Records the self-check key the startup identity resolved to when its
    /// decision serves one row, and forgets it otherwise. Returns true when
    /// the next start with this identity reads a one-row verdict.
    /// `route` is the route the decision was measured on. On stock order a
    /// `stockOrderFallback` (given now or recorded before for the identity)
    /// replaces the one-row verdict: the next start takes the row-invariant
    /// route and measures there, so a stock-order-only failure never sends a
    /// start to the serial route. A recorded fallback is kept by every later
    /// record for the identity.
    @discardableResult
    func record(
        startupIdentity: String,
        key: ContinuousBatchingSelfCheckKey,
        decision: ContinuousBatchingSelfCheckDecision,
        route: SmallMRoute? = nil,
        stockOrderFallback: String? = nil
    ) -> Bool {
        let all = read()
        let fallback = all.last(where: { $0.startupIdentity == startupIdentity })?.stockOrderFallback
            ?? (route == .stockOrder ? stockOrderFallback : nil)
        var entries = all.filter { $0.startupIdentity != startupIdentity }
        let oneRow = decision.slots <= 1 && !(route == .stockOrder && fallback != nil)
        if oneRow || fallback != nil {
            entries.append(Entry(
                startupIdentity: startupIdentity,
                key: oneRow ? key : nil,
                route: oneRow ? route?.rawValue : nil,
                stockOrderFallback: fallback
            ))
        }
        return save(entries) && oneRow
    }

    /// Records a stock order fallback for the startup identity (an attach
    /// probe or a same-order reference that failed before any decision).
    /// The first reason recorded stays; a one-row verdict measured on stock
    /// order is dropped with it. Returns true when the fallback is stored.
    @discardableResult
    func recordStockOrderFallback(startupIdentity: String, reason: String) -> Bool {
        let all = read()
        let existing = all.last(where: { $0.startupIdentity == startupIdentity })
        var entries = all.filter { $0.startupIdentity != startupIdentity }
        let keepVerdict = existing?.key != nil && existing?.route != SmallMRoute.stockOrder.rawValue
        entries.append(Entry(
            startupIdentity: startupIdentity,
            key: keepVerdict ? existing?.key : nil,
            route: keepVerdict ? existing?.route : nil,
            stockOrderFallback: existing?.stockOrderFallback ?? reason
        ))
        return save(entries)
    }

    private func save(_ entries: [Entry]) -> Bool {
        let entries = entries.count > Self.maxEntries ? Array(entries.suffix(Self.maxEntries)) : entries
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Document(schemaVersion: Self.schemaVersion, entries: entries)),
              (try? write(data)) != nil
        else { return false }
        return true
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
/// store, once per key, and logs the route it gives the next start. Only
/// built when every other serial-only condition holds, so a start without a
/// one-row verdict or a stock order fallback takes the stock order route.
/// `route` is the route this process runs: a correctness failure, a crash,
/// an attach-probe failure or an unfit same-order reference on stock order
/// records a fallback instead of a one-row verdict.
final class SmallMRouteVerdictRecorder: @unchecked Sendable {
    private let store: SmallMRouteVerdictStore
    private let selfCheckStore: ContinuousBatchingSelfCheckStore
    private let startupIdentity: String
    private let route: SmallMRoute
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var startupModelSHA256: String?
    private var lastRecorded: (ContinuousBatchingSelfCheckKey, ContinuousBatchingSelfCheckDecision)?

    init(
        store: SmallMRouteVerdictStore,
        selfCheckStore: ContinuousBatchingSelfCheckStore,
        startupIdentity: String,
        route: SmallMRoute = .rowInvariant,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.store = store
        self.selfCheckStore = selfCheckStore
        self.startupIdentity = startupIdentity
        self.route = route
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
        let measured = selfCheckStore.record(for: key)
        let fallback = route == .stockOrder
            ? SmallMRoute.stockOrderFallbackReason(
                decision: decision,
                anyWidthDiverged: measured?.measurements.contains { !$0.conformant } ?? false,
                crashed: measured?.crashedSlots != nil
            )
            : nil
        store.record(startupIdentity: startupIdentity, key: key, decision: decision, route: route, stockOrderFallback: fallback)
        let next = store.nextStartRoute(startupIdentity: startupIdentity, selfCheckStore: selfCheckStore)
        log("event=small_m_route action=verdict_recorded decision=\(decision.reason) slots=\(decision.slots) next_start=\(next.rawValue)\(fallback.map { " fallback=\($0)" } ?? "")")
    }

    /// Records a stock order failure found outside a self-check decision
    /// (`SmallMRoute.stockOrderAttachFailed`, `stockOrderReferenceUnfit`).
    /// Ignored on any other route and, when `modelSHA256` is given, for any
    /// model but the startup model.
    func stockOrderFailed(reason: String, modelSHA256: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard route == .stockOrder else { return }
        if let modelSHA256 {
            if startupModelSHA256 == nil { startupModelSHA256 = modelSHA256 }
            guard modelSHA256 == startupModelSHA256 else { return }
        }
        guard store.stockOrderFallback(startupIdentity: startupIdentity) == nil else { return }
        store.recordStockOrderFallback(startupIdentity: startupIdentity, reason: reason)
        log("event=small_m_route action=stock_order_fallback_recorded reason=\(reason) next_start=\(store.nextStartRoute(startupIdentity: startupIdentity, selfCheckStore: selfCheckStore).rawValue)")
    }
}
