import Foundation
import MacProviderCore

/// What a primary runtime's SPEC-011 warm swap needs from its warm set
/// (§3.10). `ModelRuntime` holds it type-erased.
protocol WarmSetSwapHooks: AnyObject, Sendable {
    /// Throws `WarmSetSwapError` when `modelID` is a member other than the
    /// primary (loading, warm or evicting).
    func refuseSwapTarget(_ modelID: String) throws
    /// Runs the swap's load, drain and switch while no warm-set load, evict
    /// or unload runs.
    func runSwapTurn(_ body: @Sendable () async -> Void) async
    /// The swap completed: the primary now serves `modelID`.
    func primarySwapped(to modelID: String)
}

enum WarmSetSwapError: Error, Equatable, CustomStringConvertible {
    /// The target already runs beside the primary; unload it first.
    case targetAlreadyWarm(modelID: String)

    var description: String {
        switch self {
        case let .targetAlreadyWarm(modelID):
            return "model_already_warm model=\(modelID): it is already loaded beside the primary model; unload it before switching to it"
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

/// SPEC-001-R016/R017 in `serve`: the primary adopted into the warm set, the
/// boot `warm_models` loaded in list order once the primary serves, runtime
/// loads and unloads, and shutdown. A refused or failed load is one event
/// line and never fatal.
final class WarmSetBoot<Runtime: WarmModelRuntime>: WarmSetSwapHooks, WarmSetShutdown, @unchecked Sendable {
    typealias LoadSpec = @Sendable (String) throws -> WarmModelLoadSpec
    typealias MemberInfo = @Sendable (Runtime) async -> WarmModelMemberInfo

    let table: WarmModelTable<Runtime>
    let loader: WarmModelLoader<Runtime>
    /// The effective `supported_models`; nil means the primary only.
    private let supportedModels: [String]?
    private let loadSpec: LoadSpec
    private let memberInfo: MemberInfo
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
        log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.table = table
        self.loader = loader
        self.supportedModels = supportedModels
        self.loadSpec = loadSpec
        self.memberInfo = memberInfo
        self.log = log
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
    func load(_ modelID: String) async -> WarmSetLoadOutcome {
        await load(modelID, pinned: false, boot: false)
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

    // MARK: WarmSetSwapHooks

    func refuseSwapTarget(_ modelID: String) throws {
        if let entry = table.entry(modelID: modelID), !entry.primary {
            throw WarmSetSwapError.targetAlreadyWarm(modelID: modelID)
        }
    }

    func runSwapTurn(_ body: @Sendable () async -> Void) async {
        await loader.exclusive { await body() }
    }

    func primarySwapped(to modelID: String) {
        // The swap target was refused while it was another member, inside
        // the same turn, so the new id is free.
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

    private func load(_ modelID: String, pinned: Bool, boot: Bool) async -> WarmSetLoadOutcome {
        let outcome = await loadOutcome(modelID, pinned: pinned)
        var line = "event=warm_model_load action=\(outcome == .loaded ? "loaded" : "refused") model=\(modelID) outcome=\(outcome.code) pinned=\(pinned) source=\(boot ? "boot" : "request")"
        if let detail = outcome.detail { line += " detail=\(detail.replacingOccurrences(of: " ", with: "_"))" }
        log(line)
        return outcome
    }

    private func loadOutcome(_ modelID: String, pinned: Bool) async -> WarmSetLoadOutcome {
        if let entry = table.entry(modelID: modelID) {
            return entry.state == .warm ? .alreadyWarm : .loadFailed(detail: "member_\(entry.state.rawValue)")
        }
        guard isSupported(modelID) else { return .unsupportedModel(detail: "not_in_supported_models") }
        let spec: WarmModelLoadSpec
        do {
            spec = try loadSpec(modelID)
        } catch {
            return .unsupportedModel(detail: "model_unavailable")
        }
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
