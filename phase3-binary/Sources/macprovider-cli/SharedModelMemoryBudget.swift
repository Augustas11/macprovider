import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

/// SPEC-001-R017: one memory budget for every model runtime in the process.
///
/// MLX's memory limit, wired limit, buffer-cache limit, buffer cache and
/// `MLX_MAX_MB_PER_BUFFER` are process-global, but each `ModelRuntime` used to
/// size and set them as if it were alone: the last-loaded model's resident
/// weights set the wired limit, one runtime's cache-limit save/restore could
/// clobber a sibling's, and the admission check used the last-loaded model's
/// KV bytes per token. This object is the one owner of that state. Members are
/// keyed by the runtime's GPU turn participant id.
///
/// With one loaded member every decision here is the single-runtime decision
/// the runtime made before (`SharedModelMemoryRules` tests prove it): the row
/// admission is MLX's live limit check, the wired limit is that model's
/// resident bytes, the cache limit is that runtime's value, and every cache
/// clear runs.
struct SharedModelMemoryMember: Sendable, Equatable {
    var label: String
    var modelFamily: String?
    /// True once the member's weights are resident (`registerLoaded`).
    var loaded = false
    /// MLX active bytes the member's load added (its weights).
    var residentBytes = 0
    /// The family keeps its weights in MLX's residency sets
    /// (`ModelRuntime.residentWeightsFamilies`).
    var wiresResidentWeights = false
    var kvBytesPerToken = 0
    /// Worst-case KV bytes of the member's admitted rows: each row's prompt
    /// plus output-token bound, at `kvBytesPerToken`.
    var committedKVBytes = 0
    var peakCommittedKVBytes = 0
    /// Requests registered in flight on the runtime (queued, prefilling or
    /// decoding).
    var inFlightRows = 0
    var pinned = false
    /// Last row admission, monotonic nanoseconds (eviction order).
    var lastAdmissionAt: UInt64 = 0
    /// The MLX buffer-cache limit this member's runtime asks for.
    var cacheLimitRequirementBytes: Int?
    var rowsAdmitted = 0
    var rowsRefused = 0
    var rowsAdmittedPastBudget = 0
}

/// Pure decision functions of the shared budget.
enum SharedModelMemoryRules {
    /// Working memory kept free per loaded member on top of weights and row
    /// KV (activations, temporaries): the small-Mac workspace floor.
    static let perMemberMarginBytes = MLXMemoryBudget.minimumWorkspaceBytes
    /// One row as a load's minimum KV: a 4K-token row (prompt plus output).
    static let minimumRowTokens = 4096

    static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return overflow ? Int.max : sum
    }

    static func loadedCount(_ members: [Int: SharedModelMemoryMember]) -> Int {
        members.values.filter(\.loaded).count
    }

    /// Weights, committed row KV and margins of every loaded member;
    /// `committedOverride` replaces one member's committed bytes with a fresh
    /// value.
    static func chargedBytes(
        _ members: [Int: SharedModelMemoryMember], committedOverride: (id: Int, bytes: Int)? = nil
    ) -> Int {
        var total = 0
        for (id, member) in members where member.loaded {
            let committed = committedOverride?.id == id ? committedOverride!.bytes : member.committedKVBytes
            total = saturatingAdd(total, saturatingAdd(member.residentBytes, committed))
            total = saturatingAdd(total, perMemberMarginBytes)
        }
        return total
    }

    struct RowDecision: Sendable, Equatable {
        let admitted: Bool
        /// The row waits even when its own scheduler is idle: a sibling's
        /// rows hold the memory and will release it.
        let holdWhenIdle: Bool
        /// The shared reservation check refused (multi-member only).
        let overSharedBudget: Bool
        /// Bytes charged with this row admitted (0 with one member).
        let requiredBytes: Int
    }

    /// Row admission. One loaded member: exactly `legacyAdmits` (MLX's live
    /// limit check, SPEC-038 FR-CB2). Several: the live check and
    /// resident(all) + committed KV(all rows of all members) + this row's
    /// worst-case KV + one margin per member <= limit.
    static func rowDecision(
        legacyAdmits: Bool,
        limitBytes: Int,
        members: [Int: SharedModelMemoryMember],
        requesterID: Int,
        requesterCommittedBytes: Int,
        rowBytes: Int
    ) -> RowDecision {
        guard loadedCount(members) > 1 else {
            return RowDecision(admitted: legacyAdmits, holdWhenIdle: false, overSharedBudget: false, requiredBytes: 0)
        }
        let required = saturatingAdd(
            chargedBytes(members, committedOverride: (requesterID, requesterCommittedBytes)), rowBytes)
        let fits = required <= limitBytes
        let admitted = legacyAdmits && fits
        let siblingsHoldRows = members.contains { id, member in
            id != requesterID && member.loaded && (member.committedKVBytes > 0 || member.inFlightRows > 0)
        }
        return RowDecision(
            admitted: admitted, holdWhenIdle: !admitted && siblingsHoldRows,
            overSharedBudget: !fits, requiredBytes: required)
    }

    /// The process wired limit: the resident weights of every loaded member
    /// whose family wires them, summed, capped at the working set. Nil when
    /// no member wires or Metal reports no working set.
    static func wiredLimitBytes(members: [Int: SharedModelMemoryMember], workingSetBytes: Int?) -> Int? {
        let sum = members.values.filter { $0.loaded && $0.wiresResidentWeights }
            .reduce(0) { saturatingAdd($0, $1.residentBytes) }
        guard let workingSet = workingSetBytes, workingSet > 0, sum > 0 else { return nil }
        return min(workingSet, sum)
    }

    /// The process buffer-cache limit: the smallest any member asks for, so
    /// a family measured under a cap (LFM2.5's 512 MiB) keeps it while a
    /// sibling is loaded. Nil when no member asks.
    static func cacheLimitBytes(members: [Int: SharedModelMemoryMember]) -> Int? {
        members.values.compactMap(\.cacheLimitRequirementBytes).min()
    }

    /// Whether a cache clear after prefill runs. One loaded member, or the
    /// lab A/B override: always (the call sites' behaviour before R017).
    /// Several: skipped while a sibling has rows in flight and the cache is
    /// within its limit, since the clear would drop buffers the sibling's
    /// next decode step reuses; performed otherwise. Without a caller id the
    /// caller is taken to be one of the busy members.
    static func shouldClearCache(
        members: [Int: SharedModelMemoryMember],
        callerID: Int?,
        cacheBytes: Int,
        cacheLimitBytes: Int,
        forceLegacy: Bool
    ) -> Bool {
        if forceLegacy || loadedCount(members) <= 1 { return true }
        let busy = members.filter { $0.value.loaded && $0.value.inFlightRows > 0 }
        let siblingBusy = callerID.map { id in busy.keys.contains { $0 != id } } ?? (busy.count >= 2)
        return !(siblingBusy && cacheBytes <= cacheLimitBytes)
    }

    struct EvictionCandidate: Sendable, Equatable {
        let id: Int
        let residentBytes: Int
        let inFlightRows: Int
        let pinned: Bool
        let lastUsedAt: UInt64
    }

    struct EvictionPlan: Sendable, Equatable, Encodable {
        /// Members to evict, least recently used first.
        let evict: [Int]
        let freedBytes: Int
        /// The plan frees at least the bytes needed.
        let satisfied: Bool
    }

    /// Idle unpinned members, least recently used first (ties by id), until
    /// `bytesNeeded` is freed. A member with an in-flight row is never chosen.
    static func evictionPlan(_ candidates: [EvictionCandidate], bytesNeeded: Int) -> EvictionPlan {
        guard bytesNeeded > 0 else { return EvictionPlan(evict: [], freedBytes: 0, satisfied: true) }
        let idle = candidates.filter { !$0.pinned && $0.inFlightRows == 0 }
            .sorted { ($0.lastUsedAt, $0.id) < ($1.lastUsedAt, $1.id) }
        var evict: [Int] = []
        var freed = 0
        for candidate in idle where freed < bytesNeeded {
            evict.append(candidate.id)
            freed = saturatingAdd(freed, candidate.residentBytes)
        }
        guard freed >= bytesNeeded else { return EvictionPlan(evict: [], freedBytes: 0, satisfied: false) }
        return EvictionPlan(evict: evict, freedBytes: freed, satisfied: true)
    }

    struct LoadDecision: Sendable, Equatable, Encodable {
        let admitted: Bool
        /// `fits`, `fits_after_eviction`, `insufficient_memory` or `limit_unavailable`.
        let reason: String
        let limitBytes: Int?
        let loadedResidentBytes: Int
        let estimatedResidentBytes: Int
        /// One minimum row of every loaded member plus the new one.
        let minimumRowKVBytes: Int
        let requiredBytes: Int
        let eviction: EvictionPlan?
    }

    /// A load fits when resident(loaded) + estimated resident(new) + one
    /// minimum row of KV for each member and the new one + margins fits the
    /// limit, else after evicting idle unpinned members (R017 *Load*).
    static func loadDecision(
        limitBytes: Int?,
        members: [Int: SharedModelMemoryMember],
        estimatedResidentBytes: Int,
        newMinimumRowKVBytes: Int
    ) -> LoadDecision {
        let loaded = members.filter { $0.value.loaded }
        let resident = loaded.values.reduce(0) { saturatingAdd($0, $1.residentBytes) }
        let rows = loaded.values.reduce(max(0, newMinimumRowKVBytes)) {
            saturatingAdd($0, MLXMemoryBudget.kvBytes(tokens: minimumRowTokens, bytesPerToken: $1.kvBytesPerToken))
        }
        let margins = (loaded.count + 1) * perMemberMarginBytes
        let required = saturatingAdd(saturatingAdd(resident, max(0, estimatedResidentBytes)), saturatingAdd(rows, margins))
        guard let limitBytes else {
            return LoadDecision(admitted: false, reason: "limit_unavailable", limitBytes: nil, loadedResidentBytes: resident,
                                estimatedResidentBytes: estimatedResidentBytes, minimumRowKVBytes: rows, requiredBytes: required, eviction: nil)
        }
        if required <= limitBytes {
            return LoadDecision(admitted: true, reason: "fits", limitBytes: limitBytes, loadedResidentBytes: resident,
                                estimatedResidentBytes: estimatedResidentBytes, minimumRowKVBytes: rows, requiredBytes: required, eviction: nil)
        }
        // An evicted member frees its weights, minimum row and margin.
        let plan = evictionPlan(loaded.map { id, member in
            EvictionCandidate(
                id: id,
                residentBytes: saturatingAdd(saturatingAdd(member.residentBytes, perMemberMarginBytes),
                    MLXMemoryBudget.kvBytes(tokens: minimumRowTokens, bytesPerToken: member.kvBytesPerToken)),
                inFlightRows: max(member.inFlightRows, member.committedKVBytes > 0 ? 1 : 0),
                pinned: member.pinned, lastUsedAt: member.lastAdmissionAt)
        }, bytesNeeded: required - limitBytes)
        return LoadDecision(
            admitted: plan.satisfied, reason: plan.satisfied ? "fits_after_eviction" : "insufficient_memory",
            limitBytes: limitBytes, loadedResidentBytes: resident, estimatedResidentBytes: estimatedResidentBytes,
            minimumRowKVBytes: rows, requiredBytes: required, eviction: plan.satisfied ? plan : nil)
    }

    /// Bytes of a model directory's `*.safetensors` files (symlinks followed,
    /// as in a Hugging Face snapshot): the load estimate of its weights.
    static func estimatedResidentBytes(modelDirectory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: modelDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "safetensors" }.reduce(0) { total, url in
            let size = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return saturatingAdd(total, size)
        }
    }
}

final class SharedModelMemoryBudget: @unchecked Sendable {
    static let shared = SharedModelMemoryBudget()

    private let lock = NSLock()
    private var members: [Int: SharedModelMemoryMember] = [:]
    private var cacheClearsPerformed = 0
    private var cacheClearsSkipped = 0
    /// `MLX_MAX_MB_PER_BUFFER` as MLX's device read it, and which family set it.
    private var commandBufferBudget: (family: String?, megabytes: Int?)?
    private var commandBufferConflicts: [String] = []
    private let wired = WiredOwner()

    // MARK: Membership

    /// Records the member's weights once loaded and re-derives the process
    /// wired limit. Resident bytes are MLX's active memory after the load
    /// less what other members already hold, so the first member's value is
    /// exactly the active memory the single-runtime ticket used. A wiring
    /// family drops the buffer cache first, as before, so the residency sets
    /// take the live weights.
    func registerLoaded(
        memberID: Int, label: String, modelFamily: String, kvBytesPerToken: Int?, pinned: Bool = true
    ) async {
        let wires = ModelRuntime.residentWeightsFamilies.contains(modelFamily)
        if wires { Memory.clearCache() }
        let (member, count) = recordLoaded(
            memberID: memberID, label: label, modelFamily: modelFamily, wires: wires,
            activeBytes: Memory.activeMemory, kvBytesPerToken: kvBytesPerToken, pinned: pinned)
        noteCommandBufferBudget(modelFamily: modelFamily)
        FileHandle.standardError.write(Data(
            "event=shared_memory_member_loaded member=\(memberID) family=\(modelFamily) resident_bytes=\(member.residentBytes) kv_bytes_per_token=\(member.kvBytesPerToken) loaded_members=\(count)\n".utf8))
        await syncWiredLimit()
    }

    private func recordLoaded(
        memberID: Int, label: String, modelFamily: String, wires: Bool, activeBytes active: Int,
        kvBytesPerToken: Int?, pinned: Bool
    ) -> (SharedModelMemoryMember, Int) {
        lock.lock(); defer { lock.unlock() }
        let others = members.filter { $0.key != memberID && $0.value.loaded }
            .values.reduce(0) { SharedModelMemoryRules.saturatingAdd($0, $1.residentBytes) }
        var member = members[memberID] ?? SharedModelMemoryMember(label: label)
        member.label = label
        member.modelFamily = modelFamily
        member.loaded = true
        member.residentBytes = max(0, active - others)
        member.wiresResidentWeights = wires
        member.kvBytesPerToken = max(0, kvBytesPerToken ?? 0)
        member.pinned = pinned
        members[memberID] = member
        return (member, SharedModelMemoryRules.loadedCount(members))
    }

    /// Removes the member; the wired limit and cache limit follow the members
    /// that stay. When none stays the cache limit is left as the last owner
    /// set it, as an unload did before.
    func unregister(memberID: Int) async {
        guard forget(memberID: memberID) else { return }
        await syncWiredLimit()
    }

    /// Synchronous removal (runtime deinit). Returns true when the member
    /// existed; a wired limit it contributed to is re-derived in a task.
    @discardableResult
    func forget(memberID: Int) -> Bool {
        lock.lock()
        guard let removed = members.removeValue(forKey: memberID) else { lock.unlock(); return false }
        let cache = members.isEmpty ? nil : SharedModelMemoryRules.cacheLimitBytes(members: members)
        lock.unlock()
        if removed.cacheLimitRequirementBytes != nil, let cache { Memory.cacheLimit = cache }
        if removed.wiresResidentWeights { Task { await self.syncWiredLimit() } }
        return true
    }

    func setInFlightRows(memberID: Int, _ count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard members[memberID] != nil else { return }
        members[memberID]!.inFlightRows = max(0, count)
    }

    // MARK: Cache limit

    /// The cache limit as this member's runtime last set it, else the
    /// process value (what a single runtime read from `Memory.cacheLimit`).
    func cacheLimit(for memberID: Int) -> Int {
        lock.lock()
        let own = members[memberID]?.cacheLimitRequirementBytes
        lock.unlock()
        return own ?? Memory.cacheLimit
    }

    /// Records the member's cache limit and applies the process rule
    /// (`SharedModelMemoryRules.cacheLimitBytes`). Returns the value applied.
    @discardableResult
    func applyCacheLimit(memberID: Int, label: String?, bytes: Int) -> Int {
        lock.lock()
        var member = members[memberID] ?? SharedModelMemoryMember(label: label ?? "unloaded")
        member.cacheLimitRequirementBytes = bytes
        members[memberID] = member
        let applied = SharedModelMemoryRules.cacheLimitBytes(members: members) ?? bytes
        lock.unlock()
        Memory.cacheLimit = applied
        return applied
    }

    // MARK: Row admission

    /// KV bytes per token for the member when more than one member is loaded;
    /// nil keeps the single-runtime source (`MLXMemoryLimit`'s sample).
    func kvBytesPerTokenOverride(memberID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard SharedModelMemoryRules.loadedCount(members) > 1, let member = members[memberID], member.loaded else { return nil }
        return member.kvBytesPerToken
    }

    /// The member's scheduler reports its admitted rows' worst-case tokens.
    func reportCommitted(memberID: Int, tokens: Int) {
        lock.lock(); defer { lock.unlock() }
        guard var member = members[memberID] else { return }
        member.committedKVBytes = MLXMemoryBudget.kvBytes(tokens: tokens, bytesPerToken: member.kvBytesPerToken)
        member.peakCommittedKVBytes = max(member.peakCommittedKVBytes, member.committedKVBytes)
        members[memberID] = member
    }

    /// Decides one row (`SharedModelMemoryRules.rowDecision`). An unknown
    /// member gets the legacy decision. An admitted row's KV is charged at
    /// once, before the scheduler's next report, so a sibling admitting in
    /// between sees it.
    func admitRow(
        memberID: Int, legacyAdmits: Bool, limitBytes: Int, committedTokens: Int, rowTokens: Int
    ) -> SharedModelMemoryRules.RowDecision {
        lock.lock(); defer { lock.unlock() }
        guard var member = members[memberID], member.loaded else {
            return .init(admitted: legacyAdmits, holdWhenIdle: false, overSharedBudget: false, requiredBytes: 0)
        }
        let committed = MLXMemoryBudget.kvBytes(tokens: committedTokens, bytesPerToken: member.kvBytesPerToken)
        let row = MLXMemoryBudget.kvBytes(tokens: rowTokens, bytesPerToken: member.kvBytesPerToken)
        let decision = SharedModelMemoryRules.rowDecision(
            legacyAdmits: legacyAdmits, limitBytes: limitBytes, members: members,
            requesterID: memberID, requesterCommittedBytes: committed, rowBytes: row)
        if decision.admitted {
            member.committedKVBytes = SharedModelMemoryRules.saturatingAdd(committed, row)
            member.peakCommittedKVBytes = max(member.peakCommittedKVBytes, member.committedKVBytes)
            member.rowsAdmitted += 1
            member.lastAdmissionAt = DispatchTime.now().uptimeNanoseconds
        } else {
            member.rowsRefused += 1
        }
        members[memberID] = member
        return decision
    }

    /// A refused row the scheduler admitted anyway because it was idle and
    /// no sibling held rows: counted, never hidden.
    func recordAdmittedPastBudget(memberID: Int) {
        lock.lock(); defer { lock.unlock() }
        guard members[memberID] != nil else { return }
        members[memberID]!.rowsAdmittedPastBudget += 1
        members[memberID]!.lastAdmissionAt = DispatchTime.now().uptimeNanoseconds
    }

    // MARK: Load admission

    /// R017 *Load*: whether a model of `estimatedResidentBytes` (from its
    /// safetensors sizes) with `minimumRowKVBytes` for one row may load now.
    func canLoad(estimatedResidentBytes: Int, minimumRowKVBytes: Int = 0) -> SharedModelMemoryRules.LoadDecision {
        let limit = MLXMemoryLimit.appliedLimitBytes() ?? MLXMemoryBudget.limitBytes(
            recommendedWorkingSetBytes: GPU.maxRecommendedWorkingSetBytes(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        lock.lock(); defer { lock.unlock() }
        return SharedModelMemoryRules.loadDecision(
            limitBytes: limit, members: members, estimatedResidentBytes: estimatedResidentBytes,
            newMinimumRowKVBytes: minimumRowKVBytes)
    }

    // MARK: Cache clears

    static var forcesLegacyCacheClear: Bool {
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        return ProcessInfo.processInfo.environment["MACPROVIDER_LAB_LEGACY_CACHE_CLEAR"] == "1"
        #else
        return false
        #endif
    }

    /// The post-prefill buffer-cache clear, through the shared rule.
    func clearCacheAfterPrefill(callerID: Int?) {
        lock.lock()
        let single = SharedModelMemoryRules.loadedCount(members) <= 1
        lock.unlock()
        // One member: the clear runs exactly as before, uncounted.
        if single { Memory.clearCache(); return }
        let cacheBytes = Memory.cacheMemory
        let cacheLimit = Memory.cacheLimit
        lock.lock()
        let clear = SharedModelMemoryRules.shouldClearCache(
            members: members, callerID: callerID, cacheBytes: cacheBytes,
            cacheLimitBytes: cacheLimit, forceLegacy: Self.forcesLegacyCacheClear)
        if clear { cacheClearsPerformed += 1 } else { cacheClearsSkipped += 1 }
        lock.unlock()
        if clear { Memory.clearCache() }
    }

    // MARK: Command-buffer budget

    /// Records the family whose `MLX_MAX_MB_PER_BUFFER` MLX's device uses.
    func recordCommandBufferBudget(modelFamily: String, megabytes: Int) {
        lock.lock(); defer { lock.unlock() }
        if commandBufferBudget == nil { commandBufferBudget = (modelFamily, megabytes) }
    }

    /// MLX reads `MLX_MAX_MB_PER_BUFFER` once, at device creation, so a later
    /// family cannot change it: say so when it would have wanted another value.
    private func noteCommandBufferBudget(modelFamily: String) {
        let configured = ProcessInfo.processInfo.environment["MLX_MAX_MB_PER_BUFFER"]
        let wanted = ModelRuntime.commandBufferBudgetMBByFamily[modelFamily]
        lock.lock()
        if commandBufferBudget == nil { commandBufferBudget = (configured == nil ? nil : "environment", configured.flatMap(Int.init)) }
        let (owner, current) = commandBufferBudget!
        // An operator-set value is the operator's choice, not a conflict.
        let conflict = owner != "environment" && owner != modelFamily && wanted != current
        let line = "event=mlx_max_mb_per_buffer_conflict family=\(modelFamily) wanted_mb=\(wanted.map(String.init) ?? "default") effective_mb=\(current.map(String.init) ?? "default") set_by=\(owner ?? "default")"
        if conflict { commandBufferConflicts.append(line) }
        lock.unlock()
        if conflict { FileHandle.standardError.write(Data("\(line)\n".utf8)) }
    }

    // MARK: Wired limit

    private func syncWiredLimit() async {
        await wired.sync { [self] in
            lock.lock(); defer { lock.unlock() }
            return members
        }
    }

    /// One wired ticket for the process, replaced (new first, then old, so
    /// the limit never dips) whenever the loaded wiring members change.
    private actor WiredOwner {
        private var ticket: WiredMemoryTicket?
        private var tail: Task<Void, Never>?

        func sync(_ members: @escaping @Sendable () -> [Int: SharedModelMemoryMember]) async {
            let previous = tail
            let next = Task { await previous?.value; await self.apply(members()) }
            tail = next
            await next.value
        }

        private func apply(_ members: [Int: SharedModelMemoryMember]) async {
            let wanted = SharedModelMemoryRules.wiredLimitBytes(
                members: members,
                workingSetBytes: members.values.contains { $0.loaded && $0.wiresResidentWeights }
                    ? GPU.maxRecommendedWorkingSetBytes() : nil)
            guard wanted != ticket?.size else { return }
            let old = ticket
            ticket = nil
            if let wanted {
                let new = WiredMemoryTicket(size: wanted, policy: MLXLMCommon.WiredFixedPolicy(limit: wanted), kind: .active)
                let applied = await new.start()
                ticket = new
                let families = members.values.filter { $0.loaded && $0.wiresResidentWeights }.compactMap(\.modelFamily).sorted()
                FileHandle.standardError.write(Data(
                    "event=resident_weights_wired_limit family=\(families.joined(separator: "+")) limit_bytes=\(applied) ticket_bytes=\(wanted) members=\(families.count)\n".utf8))
            }
            if let old { _ = await old.end() }
        }
    }

    // MARK: Snapshot

    struct MemberSnapshot: Sendable, Encodable, Equatable {
        let memberID: Int
        let label: String
        let modelFamily: String?
        let loaded: Bool
        let residentBytes: Int
        let wiresResidentWeights: Bool
        let kvBytesPerToken: Int
        let committedKVBytes: Int
        let peakCommittedKVBytes: Int
        let inFlightRows: Int
        let pinned: Bool
        let cacheLimitRequirementBytes: Int?
        let rowsAdmitted: Int
        let rowsRefused: Int
        let rowsAdmittedPastBudget: Int
    }

    struct Snapshot: Sendable, Encodable, Equatable {
        let limitBytes: Int?
        let wiredLimitBytes: Int?
        let cacheLimitBytes: Int
        let chargedBytes: Int
        let peakChargedBytes: Int
        let headroomBytes: Int?
        let cacheClearsPerformed: Int
        let cacheClearsSkipped: Int
        let commandBufferBudgetSetBy: String?
        let commandBufferBudgetMb: Int?
        let commandBufferConflicts: [String]
        let members: [MemberSnapshot]
    }

    func snapshot() -> Snapshot {
        let limit = MLXMemoryLimit.appliedLimitBytes()
        let cacheLimit = Memory.cacheLimit
        let workingSet = GPU.maxRecommendedWorkingSetBytes()
        lock.lock(); defer { lock.unlock() }
        let wiredBytes = SharedModelMemoryRules.wiredLimitBytes(members: members, workingSetBytes: workingSet)
        let charged = SharedModelMemoryRules.chargedBytes(members)
        var peakMembers = members
        for id in peakMembers.keys { peakMembers[id]!.committedKVBytes = peakMembers[id]!.peakCommittedKVBytes }
        let peak = SharedModelMemoryRules.chargedBytes(peakMembers)
        return Snapshot(
            limitBytes: limit, wiredLimitBytes: wiredBytes, cacheLimitBytes: cacheLimit,
            chargedBytes: charged, peakChargedBytes: peak, headroomBytes: limit.map { $0 - charged },
            cacheClearsPerformed: cacheClearsPerformed, cacheClearsSkipped: cacheClearsSkipped,
            commandBufferBudgetSetBy: commandBufferBudget?.family, commandBufferBudgetMb: commandBufferBudget?.megabytes,
            commandBufferConflicts: commandBufferConflicts,
            members: members.keys.sorted().map { id in
                let m = members[id]!
                return MemberSnapshot(
                    memberID: id, label: m.label, modelFamily: m.modelFamily, loaded: m.loaded,
                    residentBytes: m.residentBytes, wiresResidentWeights: m.wiresResidentWeights,
                    kvBytesPerToken: m.kvBytesPerToken, committedKVBytes: m.committedKVBytes,
                    peakCommittedKVBytes: m.peakCommittedKVBytes, inFlightRows: m.inFlightRows, pinned: m.pinned,
                    cacheLimitRequirementBytes: m.cacheLimitRequirementBytes, rowsAdmitted: m.rowsAdmitted,
                    rowsRefused: m.rowsRefused, rowsAdmittedPastBudget: m.rowsAdmittedPastBudget)
            })
    }

    /// Starts a new measurement window for the peak committed KV.
    func resetPeaks() {
        lock.lock(); defer { lock.unlock() }
        for id in members.keys { members[id]!.peakCommittedKVBytes = members[id]!.committedKVBytes }
    }
}
