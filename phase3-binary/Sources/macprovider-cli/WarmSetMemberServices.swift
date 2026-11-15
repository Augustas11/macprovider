import Foundation

/// What a further member's own background work asks of its warm set
/// (SPEC-001-R019). `WarmSetBoot` conforms.
protocol WarmSetMemberGate: AnyObject, Sendable {
    /// The member is `warm` and no warm-set load, eviction or swap runs.
    func memberSelfCheckAllowed(memberID: Int) async -> Bool
    /// The member's runtime changed what its wire entry reports.
    func republishInfo(memberID: Int) async
}

extension WarmSetBoot: WarmSetMemberGate {}

/// The per-member self-check hold a warm set keeps (`WarmModelTable`).
protocol WarmMemberSelfCheckHolding: AnyObject, Sendable {
    func beginSelfCheckHold(memberID: Int) -> String?
    func endSelfCheckHold(memberID: Int)
    func selfCheckHoldWork(memberID: Int) -> (inFlight: Int, predatingHold: Int)
}

extension WarmModelTable: WarmMemberSelfCheckHolding {}

/// SPEC-001-R019: a further warm member's self-check hold. It closes that
/// member alone (its entry reports no free slot) and drains only that
/// member's own requests admitted before it; it never takes the
/// provider-wide hold, so the primary's `slots_free`, admission and
/// in-flight work are untouched. It starts only while the provider serves
/// and no warm-set load, eviction or swap runs (`allowed`), and the check
/// yields the moment one starts.
struct WarmMemberSelfCheckAdmissionHold: SelfCheckAdmissionHoldScope {
    let memberID: Int
    let hold: any WarmMemberSelfCheckHolding
    let providerStatus: ProviderStatus
    let allowed: @Sendable () async -> Bool

    func beginHold(expectedEndAt: Date) async -> String? {
        guard await providerStatus.isServingForSelfCheckAdmissionHold() else { return "provider_not_serving" }
        guard await allowed() else { return "warm_set_busy" }
        return hold.beginSelfCheckHold(memberID: memberID)
    }

    func endHold(outcome: String) async { hold.endSelfCheckHold(memberID: memberID) }
    /// The skip is logged by the caller; the provider's hold status
    /// describes the primary's hold only.
    func noteHoldSkipped(reason: String) async {}

    func isServingForHold() async -> Bool {
        guard await providerStatus.isServingForSelfCheckAdmissionHold() else { return false }
        return await allowed()
    }

    func heldRequestsInFlight() async -> Int { hold.selfCheckHoldWork(memberID: memberID).inFlight }
    func hasHeldWork() async -> Bool { hold.selfCheckHoldWork(memberID: memberID).inFlight > 0 }
    func hasBuyerWorkPredatingHold() async -> Bool { hold.selfCheckHoldWork(memberID: memberID).predatingHold > 0 }
    func hasWorkPredatingHold() async -> Bool { hold.selfCheckHoldWork(memberID: memberID).predatingHold > 0 }
}

/// SPEC-001-R019: the background work each further warm member runs on its
/// own runtime (its continuous-batching self-check), keyed by the member's
/// budget id. Work is started when the member's runtime is built and stopped
/// only right before that runtime unloads: loading, evicting, promoting or
/// swapping another member never touches it.
final class WarmSetMemberServices: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Int: [Task<Void, Never>]] = [:]
    private var soloThroughput: [Int: Double] = [:]
    private weak var gateStorage: (any WarmSetMemberGate)?

    /// Set once the warm set exists; until then no member work may act.
    var gate: (any WarmSetMemberGate)? {
        get { lock.lock(); defer { lock.unlock() }; return gateStorage }
        set { lock.lock(); gateStorage = newValue; lock.unlock() }
    }

    func stepAllowed(memberID: Int) async -> Bool {
        await gate?.memberSelfCheckAllowed(memberID: memberID) ?? false
    }

    func published(memberID: Int) async {
        await gate?.republishInfo(memberID: memberID)
    }

    func add(memberID: Int, _ task: Task<Void, Never>) {
        lock.lock()
        tasks[memberID, default: []].append(task)
        lock.unlock()
    }

    /// SPEC-001-R018: the member's solo decode rate, measured once when its
    /// runtime is built; the wire scales it by the measured contention.
    func setSoloThroughput(memberID: Int, _ tps: Double) {
        lock.lock(); soloThroughput[memberID] = tps; lock.unlock()
    }

    func soloThroughput(memberID: Int) -> Double {
        lock.lock(); defer { lock.unlock() }
        return soloThroughput[memberID] ?? 0
    }

    /// Members with running work.
    func memberIDs() -> Set<Int> {
        lock.lock(); defer { lock.unlock() }
        return Set(tasks.keys)
    }

    /// Cancels member `memberID`'s work and waits for it to return (a
    /// self-check step writes its journal before it does).
    func stop(memberID: Int) async {
        let running = take(memberID: memberID)
        for task in running { task.cancel() }
        for task in running { await task.value }
    }

    private func take(memberID: Int) -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        soloThroughput[memberID] = nil
        return tasks.removeValue(forKey: memberID) ?? []
    }
}

extension WarmSetMemberServices {
    /// SPEC-001-R019 in `serve`: a further member's served slots and its own
    /// self-check, set up exactly as `serve` sets up the boot model's from the
    /// same plan, store and signed provisional grant, against the member's
    /// own tuple. Returns the driver to run, or nil when this process runs no
    /// self-check (no plan, a plan that is not self-checked, or the serial
    /// small-row route, where batching is off for every member).
    static func configureMemberSelfCheck(
        runtime: ModelRuntime,
        plan: AutoServedSlots.Plan?,
        serialOnlyRoute: Bool,
        store: ContinuousBatchingSelfCheckStore,
        provisional: ContinuousBatchingSelfCheckDriver.Provisional?,
        makeDriver: (_ ownerPinned: Int?) -> ContinuousBatchingSelfCheckDriver,
        log: @Sendable (String) -> Void
    ) async -> ContinuousBatchingSelfCheckDriver? {
        guard let plan, !serialOnlyRoute else { return nil }
        let modelID = await runtime.loadedModelID ?? "unknown"
        // Before any served count is applied, the runtime serves every row it was built with.
        let rows = await runtime.warmSetRowReservation().rows
        var served = min(plan.initialServed, rows)
        var source = plan.reason
        if plan.ownerPinned == nil, !(await runtime.continuousBatchingCapableForServedSlots()) {
            served = 1
            source = "cb_unavailable_for_loaded_tuple"
        }
        let ownerPinned = plan.ownerPinned
        let resolver: @Sendable (ContinuousBatchingSelfCheckTarget) -> ContinuousBatchingSelfCheckResolution? = { target in
            ContinuousBatchingSelfCheckResolution.resolve(
                store: store, target: target, ownerPinned: ownerPinned, provisional: provisional)
        }
        await runtime.configureServedSlots(
            managed: plan.selfChecked, ownerPinned: ownerPinned, resolver: plan.selfChecked ? resolver : nil)
        if plan.selfChecked,
           let target = await runtime.continuousBatchingSelfCheckTarget(),
           let resolution = resolver(target) {
            served = resolution.servedSlots
            source = "self_check_\(resolution.report.decision)"
            await runtime.applyContinuousBatchingSelfCheck(resolution.state, servedSlots: served)
            await runtime.setContinuousBatchingSelfCheckReport(resolution.report)
        } else {
            await runtime.applyServedSlots(served)
        }
        log("event=served_slots action=applied slots=\(served) rows=\(rows) reason=\(source) model=\(modelID) warm_member=true")
        return plan.selfChecked ? makeDriver(ownerPinned) : nil
    }
}
