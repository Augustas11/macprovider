import Foundation
import MacProviderCore

/// What a primary runtime's SPEC-011 warm swap needs from its warm set
/// (§3.10). `ModelRuntime` holds it type-erased.
protocol WarmSetSwapHooks: AnyObject, Sendable {
    /// Throws `WarmSetSwapError` when `modelID` is a member other than the
    /// primary (loading, warm or evicting): a load is never started for it.
    func refuseSwapTarget(_ modelID: String) throws
    /// R-3.10.3: `modelID` is a `warm` member other than the primary, so a
    /// switch to it promotes it instead of loading it.
    func isWarmSecondary(_ modelID: String) -> Bool
    /// R-3.10.3: promotes the warm member `modelID` to primary, inside the
    /// caller's `runSwapTurn`. Every primary-only attachment moves with it
    /// before this returns.
    func promoteInSwapTurn(_ modelID: String) async throws
    /// Runs the swap's load, drain and switch while no warm-set load, evict
    /// or unload runs.
    func runSwapTurn(_ body: @Sendable () async -> Void) async
    /// The swap completed: the primary now serves `modelID`.
    func primarySwapped(to modelID: String)
}

enum WarmSetSwapError: Error, Equatable, CustomStringConvertible {
    /// The target finished loading beside the primary while this switch
    /// waited to load it; a new switch promotes it.
    case targetAlreadyWarm(modelID: String)
    /// The target is being loaded or unloaded beside the primary.
    case targetNotWarm(modelID: String, state: String)

    var description: String {
        switch self {
        case let .targetAlreadyWarm(modelID):
            return "model_already_warm model=\(modelID): it finished loading beside the primary model while this switch waited; switch to it again to make it the primary"
        case let .targetNotWarm(modelID, state):
            return "model_not_warm model=\(modelID) state=\(state): it is being loaded or unloaded beside the primary model; switch when it is warm"
        }
    }
}

enum WarmSetConfigurationError: Error, Equatable, CustomStringConvertible {
    /// `warm_models` needs the primary to be a model this process loads
    /// itself; an external runtime (a loopback server or a shard group)
    /// cannot hold further models.
    case externalPrimary(runtime: String)

    var description: String {
        switch self {
        case let .externalPrimary(runtime):
            return "warm_models needs --model to be a local MLX model this process loads; it is served by \(runtime). Remove warm_models or serve a local model."
        }
    }
}

/// The result of one warm-set load, as the boot log and the control socket
/// report it.
enum WarmSetLoadOutcome: Sendable, Equatable {
    case loaded
    case alreadyWarm
    case insufficientMemory(detail: String)
    /// Not in `supported_models`, not present on this Mac, or a family that
    /// cannot run beside the loaded members.
    case unsupportedModel(detail: String)
    case loadFailed(detail: String)

    var code: String {
        switch self {
        case .loaded: return "loaded"
        case .alreadyWarm: return "already_warm"
        case .insufficientMemory: return "insufficient_memory"
        case .unsupportedModel: return "unsupported_model"
        case .loadFailed: return "load_failed"
        }
    }

    var detail: String? {
        switch self {
        case .loaded, .alreadyWarm: return nil
        case let .insufficientMemory(detail), let .unsupportedModel(detail), let .loadFailed(detail): return detail
        }
    }
}

enum WarmSetUnloadOutcome: Sendable, Equatable {
    case unloaded
    case notLoaded
    case primary
    /// The member holds a request; it is never unloaded under one.
    case busy
    case failed(detail: String)

    var code: String {
        switch self {
        case .unloaded: return "unloaded"
        case .notLoaded: return "not_loaded"
        case .primary: return "primary"
        case .busy: return "busy"
        case .failed: return "failed"
        }
    }
}

/// Process shutdown of a warm set, free of its runtime type.
protocol WarmSetShutdown: AnyObject, Sendable {
    func shutdown(idleTimeoutSeconds: Int) async
}

/// The control socket's `warm_set` commands, free of the runtime type.
protocol WarmSetControl: AnyObject, Sendable {
    /// Every member, primary first: its wire entry fields plus leases.
    func controlEntries() async -> [WarmSetControlEntry]
    /// `limits` replaces the configured `warm_model_limits` for this load.
    func load(_ modelID: String, limits: WarmModelLimits?) async -> WarmSetLoadOutcome
    func unload(_ modelID: String) async -> WarmSetUnloadOutcome
}

/// SPEC-001-R016/R017 in `serve`: the primary adopted into the warm set, the
/// boot `warm_models` loaded in list order once the primary serves, runtime
/// loads and unloads, and shutdown. A refused or failed load is one event
/// line and never fatal.
final class WarmSetBoot<Runtime: WarmModelRuntime>: WarmSetSwapHooks, WarmSetShutdown, WarmSetControl, @unchecked Sendable {
    typealias LoadSpec = @Sendable (String) throws -> WarmModelLoadSpec
    typealias MemberInfo = @Sendable (Runtime) async -> WarmModelMemberInfo
    /// R-3.10.3: moves every primary-only attachment from the old primary's
    /// runtime to the new one's (provider status, swap hooks, top-level
    /// fields). Runs inside the loader's turn.
    typealias PrimaryHandoff = @Sendable (_ old: WarmModelTableEntry<Runtime>, _ new: WarmModelTableEntry<Runtime>) async -> Void

    let table: WarmModelTable<Runtime>
    let loader: WarmModelLoader<Runtime>
    /// The effective `supported_models`; nil means the primary only.
    private let supportedModels: [String]?
    private let loadSpec: LoadSpec
    private let memberInfo: MemberInfo
    private let primaryHandoff: PrimaryHandoff
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var bootTask: Task<Void, Never>?
    private var primaryModelID: String?

    init(
        table: WarmModelTable<Runtime>,
        loader: WarmModelLoader<Runtime>,
        supportedModels: [String]?,
        loadSpec: @escaping LoadSpec,
        memberInfo: @escaping MemberInfo,
        primaryHandoff: @escaping PrimaryHandoff = { _, _ in },
        log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.table = table
        self.loader = loader
        self.supportedModels = supportedModels
        self.loadSpec = loadSpec
        self.memberInfo = memberInfo
        self.primaryHandoff = primaryHandoff
        self.log = log
    }

    /// The `ProviderStatus` member key of the current primary.
    var primaryMemberKey: String? {
        table.entries().first(where: \.primary).map { WarmModelTable<Runtime>.memberKey(token: $0.token) }
    }

    /// Startup check: warm models need a primary this process loads itself.
    /// `externalRuntime` names the runtime serving `--model` otherwise.
    static func requireLocalPrimary(warmModels: [String], externalRuntime: String?) throws {
        guard !warmModels.isEmpty, let externalRuntime else { return }
        throw WarmSetConfigurationError.externalPrimary(runtime: externalRuntime)
    }

    func adoptPrimary(modelID: String, runtime: Runtime) async throws {
        setPrimaryModelID(modelID)
        try await loader.adoptPrimary(modelID: modelID, runtime: runtime)
    }

    /// Loads the boot `warm_models` in a background task, in list order.
    func startBootLoads(_ modelIDs: [String]) {
        guard !modelIDs.isEmpty else { return }
        let task = Task { [self] in _ = await bootLoad(modelIDs) }
        lock.lock(); defer { lock.unlock() }
        bootTask = task
    }

    /// Each boot model in list order, pinned (R017 *Pinning*), through the
    /// loader so the shared budget decides. Every outcome is logged; later
    /// entries are tried after a refusal or a failure.
    @discardableResult
    func bootLoad(_ modelIDs: [String]) async -> [WarmSetLoadOutcome] {
        var outcomes: [WarmSetLoadOutcome] = []
        for modelID in modelIDs {
            if Task.isCancelled { break }
            outcomes.append(await load(modelID, pinned: true, boot: true))
        }
        return outcomes
    }

    /// One load on request (the control socket): unpinned, so a later load
    /// may evict it while idle.
    func load(_ modelID: String, limits: WarmModelLimits? = nil) async -> WarmSetLoadOutcome {
        await load(modelID, pinned: false, boot: false, limits: limits)
    }

    /// An explicit unload: refused for the primary and for a member holding
    /// a request.
    func unload(_ modelID: String) async -> WarmSetUnloadOutcome {
        guard let entry = table.entry(modelID: modelID) else { return .notLoaded }
        if entry.primary { return .primary }
        guard entry.state == .warm else { return .notLoaded }
        if entry.leases > 0 { return .busy }
        do {
            try await loader.unload(modelID)
        } catch let error as WarmModelTableError {
            switch error {
            case .notEvictable(_, "busy"): return .busy
            case .notEvictable(_, "primary"): return .primary
            case .notLoaded, .notEvictable(_, "not_warm"): return .notLoaded
            default: return .failed(detail: error.description)
            }
        } catch {
            return .failed(detail: String(describing: error))
        }
        log("event=warm_model_unload action=unloaded model=\(modelID)")
        return .unloaded
    }

    /// SPEC-001-R019: a member's runtime changed what its wire entry reports
    /// (its own self-check or engine). Only a further member's entry carries
    /// its info; the primary's comes from the top-level fields.
    func republishInfo(memberID: Int) async {
        guard let entry = table.entries().first(where: { $0.memberID == memberID }),
              !entry.primary, entry.state == .warm, let runtime = entry.runtime else { return }
        let info = await memberInfo(runtime)
        // A promotion while the info was read moved the member to the top-level fields.
        guard table.entry(token: entry.token)?.primary == false else { return }
        table.updateInfo(token: entry.token, info)
    }

    /// SPEC-001-R019: whether the self-check of member `memberID` may act now:
    /// the member is `warm`, and no warm-set load, eviction or swap runs.
    /// A check never holds up a load; it only starts between them.
    func memberSelfCheckAllowed(memberID: Int) async -> Bool {
        let entries = table.entries()
        guard entries.contains(where: { $0.memberID == memberID && $0.state == .warm }),
              entries.allSatisfy({ $0.state == .warm }) else { return false }
        return await !loader.isBusy
    }

    // MARK: WarmSetControl

    /// The primary, and a member whose runtime has not published its info
    /// yet, is asked for it here.
    func controlEntries() async -> [WarmSetControlEntry] {
        let views = table.views.value
        var result: [WarmSetControlEntry] = []
        for entry in table.entries() {
            let view = views.first { $0.key == entry.key }
            var info = entry.primary ? nil : view?.info
            if info == nil, entry.state == .warm, let runtime = entry.runtime {
                info = await memberInfo(runtime)
            }
            result.append(WarmSetControlEntry(
                modelID: entry.modelID,
                state: entry.state.rawValue,
                primary: entry.primary,
                pinned: entry.pinned,
                leases: entry.leases,
                slotsTotal: info?.slotsTotal ?? 0,
                slotsFree: entry.state != .warm ? nil
                    : view?.selfCheckHeld == true ? 0 : max(0, (info?.slotsTotal ?? 0) - entry.leases),
                maxContextTokens: info?.maxContextTokens,
                throughputTPSEstimate: info?.throughputTPSEstimate,
                modelParamsB: info?.modelParamsB,
                modelHash: info?.modelHash,
                modelHashAlgorithm: info?.modelHash == nil ? nil : info?.modelHashAlgorithm,
                weightsManifestSHA256: info?.weightsManifestSHA256
            ))
        }
        return result
    }

    // MARK: WarmSetSwapHooks

    func refuseSwapTarget(_ modelID: String) throws {
        guard let entry = table.entry(modelID: modelID), !entry.primary else { return }
        if entry.state == .warm { throw WarmSetSwapError.targetAlreadyWarm(modelID: modelID) }
        throw WarmSetSwapError.targetNotWarm(modelID: modelID, state: entry.state.rawValue)
    }

    func isWarmSecondary(_ modelID: String) -> Bool {
        guard let entry = table.entry(modelID: modelID) else { return false }
        return !entry.primary && entry.state == .warm
    }

    func promoteInSwapTurn(_ modelID: String) async throws {
        let promoted = try await loader.promoteInTurn(modelID)
        // The demoted member becomes a further member on the wire the
        // moment the handoff switches the provider status: its info is
        // published first, so no frame built in between lists it without.
        if let runtime = promoted.old.runtime {
            table.updateInfo(token: promoted.old.token, await memberInfo(runtime))
        }
        await primaryHandoff(promoted.old, promoted.new)
        setPrimaryModelID(promoted.new.modelID)
        // Published again: the handoff moved its solo rate and every
        // primary-only attachment, which its wire entry and preflight
        // answer now report.
        if let runtime = promoted.old.runtime {
            table.updateInfo(token: promoted.old.token, await memberInfo(runtime))
        }
        log("event=warm_model_promote model=\(promoted.new.modelID) previous_primary=\(promoted.old.modelID)")
    }

    func runSwapTurn(_ body: @Sendable () async -> Void) async {
        await loader.exclusive { await body() }
    }

    func primarySwapped(to modelID: String) {
        // The swap target was refused while it was another member, inside
        // the same turn, so the new id is free. A promotion never comes
        // here: it re-keys nothing.
        try? table.rekeyPrimary(to: modelID)
        setPrimaryModelID(modelID)
    }

    // MARK: WarmSetShutdown

    /// Stops the loader (a load in flight is unloaded when it returns, and
    /// never waited for), cancels the boot loads, then unloads every warm
    /// secondary. The primary's teardown is the caller's.
    func shutdown(idleTimeoutSeconds: Int) async {
        await loader.stop()
        takeBootTask()?.cancel()
        await loader.unloadSecondariesForShutdown(
            idleTimeoutNanoseconds: UInt64(max(0, idleTimeoutSeconds)) * 1_000_000_000)
    }

    // MARK: Private

    private func load(_ modelID: String, pinned: Bool, boot: Bool, limits: WarmModelLimits? = nil) async -> WarmSetLoadOutcome {
        let outcome = await loadOutcome(modelID, pinned: pinned, limits: limits)
        var line = "event=warm_model_load action=\(outcome == .loaded ? "loaded" : "refused") model=\(modelID) outcome=\(outcome.code) pinned=\(pinned) source=\(boot ? "boot" : "request")"
        if let detail = outcome.detail { line += " detail=\(detail.replacingOccurrences(of: " ", with: "_"))" }
        log(line)
        return outcome
    }

    private func loadOutcome(_ modelID: String, pinned: Bool, limits: WarmModelLimits?) async -> WarmSetLoadOutcome {
        if let entry = table.entry(modelID: modelID) {
            return entry.state == .warm ? .alreadyWarm : .loadFailed(detail: "member_\(entry.state.rawValue)")
        }
        guard isSupported(modelID) else { return .unsupportedModel(detail: "not_in_supported_models") }
        var spec: WarmModelLoadSpec
        do {
            spec = try loadSpec(modelID)
        } catch {
            return .unsupportedModel(detail: "model_unavailable")
        }
        if let limits { spec.limits = limits }
        let entry: WarmModelTableEntry<Runtime>
        do {
            entry = try await loader.load(spec, pinned: pinned)
        } catch let error as WarmModelLoaderError {
            switch error {
            case .insufficientMemory: return .insufficientMemory(detail: error.description)
            case .commandBufferBudgetConflict: return .unsupportedModel(detail: error.description)
            case .stopped: return .loadFailed(detail: error.reason)
            }
        } catch WarmModelTableError.duplicate {
            return .alreadyWarm
        } catch {
            return .loadFailed(detail: String(describing: error))
        }
        if let runtime = entry.runtime {
            table.updateInfo(token: entry.token, await memberInfo(runtime))
        }
        return .loaded
    }

    private func setPrimaryModelID(_ modelID: String) {
        lock.lock(); defer { lock.unlock() }
        primaryModelID = modelID
    }

    private func takeBootTask() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        let task = bootTask
        bootTask = nil
        return task
    }

    private func isSupported(_ modelID: String) -> Bool {
        lock.lock()
        let primary = primaryModelID
        lock.unlock()
        let key = WarmModelTable<Runtime>.key(modelID)
        return (supportedModels ?? primary.map { [$0] } ?? []).contains { WarmModelTable<Runtime>.key($0) == key }
    }
}

extension WarmSetBoot where Runtime == ModelRuntime {
    /// SPEC-011 R-3.10.3 in `serve`: the primary role moves to the promoted
    /// runtime (the provider status, the switch, the swap-signal
    /// subscribers), then the top-level identity and capacity follow it,
    /// then the pending switch hears `completed`.
    ///
    /// SPEC-001-R018: the demoted primary keeps, as its member solo rate, the
    /// estimate the top level advertised for it while it was the primary: the
    /// start-up probe of the boot model, the same measurement a member probe
    /// would repeat. No probe runs, so a promotion never takes the GPU from
    /// the serving members. With `--autotune-candidate` that estimate is 0,
    /// as the primary's is.
    static func modelRuntimePrimaryHandoff(
        providerStatus: ProviderStatus, memberServices: WarmSetMemberServices? = nil
    ) -> PrimaryHandoff {
        { old, new in
            guard let oldRuntime = old.runtime, let newRuntime = new.runtime else { return }
            if let memberServices {
                memberServices.setSoloThroughput(
                    memberID: oldRuntime.memoryBudgetMemberID, await providerStatus.primarySoloThroughputEstimate())
            }
            let target = await oldRuntime.handOffPrimaryRole(to: newRuntime)
            let rows = await newRuntime.warmSetRowReservation()
            await providerStatus.promoteWarmPrimary(
                memberKey: WarmModelTable<ModelRuntime>.memberKey(token: new.token),
                modelID: new.modelID,
                modelHash: await newRuntime.loadedModelHash,
                modelHashAlgorithm: await newRuntime.loadedModelHashAlgorithm,
                weightsManifestSHA256: await newRuntime.loadedWeightsManifestSHA256,
                maxContextTokens: rows.tokensPerRow,
                maxConcurrency: rows.rows)
            if let target { await newRuntime.announceSwitchCompleted(target: target) }
        }
    }
}
