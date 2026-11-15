import Foundation
import MLX
import MLXLMCommon
import MLXNN
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
    /// Worst-case KV bytes of the member's live serial-path rows (the token
    /// loop outside continuous batching), charged at admission and released
    /// when the row ends.
    var serialKVBytes = 0
    /// Peak of committed plus serial KV in the measurement window.
    var peakCommittedKVBytes = 0
    /// Requests registered in flight on the runtime (queued, prefilling or
    /// decoding).
    var inFlightRows = 0
    var pinned = false
    /// R017 *Pinning*: KV of the `slots_total` rows a pinned member keeps
    /// through a load (`SharedModelMemoryBudget.reserveRows`).
    var reservedRowKVBytes = 0
    /// Last row admission, monotonic nanoseconds (eviction order).
    var lastAdmissionAt: UInt64 = 0
    /// The MLX buffer-cache limit this member's runtime asks for.
    var cacheLimitRequirementBytes: Int?
    var rowsAdmitted = 0
    var rowsRefused = 0
    var rowsAdmittedPastBudget = 0

    /// Row KV the member holds now: batched and serial.
    var liveKVBytes: Int { SharedModelMemoryRules.saturatingAdd(committedKVBytes, serialKVBytes) }
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

    static func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = max(0, lhs).multipliedReportingOverflow(by: max(0, rhs))
        return overflow ? Int.max : product
    }

    static func loadedCount(_ members: [Int: SharedModelMemoryMember]) -> Int {
        members.values.filter(\.loaded).count
    }

    /// Weights, committed (batched) and serial row KV and margins of every
    /// loaded member; `committedOverride` replaces one member's committed
    /// bytes with a fresh value. `includeRowKV: false` counts weights and
    /// margins only: the budget with every row finished.
    static func chargedBytes(
        _ members: [Int: SharedModelMemoryMember], committedOverride: (id: Int, bytes: Int)? = nil,
        includeRowKV: Bool = true
    ) -> Int {
        var total = 0
        for (id, member) in members where member.loaded {
            total = saturatingAdd(total, saturatingAdd(member.residentBytes, perMemberMarginBytes))
            guard includeRowKV else { continue }
            let committed = committedOverride?.id == id ? committedOverride!.bytes : member.committedKVBytes
            total = saturatingAdd(total, saturatingAdd(committed, member.serialKVBytes))
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
        /// The row exceeds the budget even with every member's rows finished
        /// (weights and margins plus this row): no wait can admit it, so it
        /// is refused at once (multi-member only).
        var neverFits = false
    }

    /// Row admission. One loaded member: exactly `legacyAdmits` (MLX's live
    /// limit check, SPEC-038 FR-CB2). Several: the live check and
    /// resident(all) + committed KV(all rows of all members) + this row's
    /// worst-case KV + one margin per member + the weights of models still
    /// loading (`pendingLoadBytes`) <= limit.
    static func rowDecision(
        legacyAdmits: Bool,
        limitBytes: Int,
        members: [Int: SharedModelMemoryMember],
        requesterID: Int,
        requesterCommittedBytes: Int,
        rowBytes: Int,
        pendingLoadBytes: Int = 0
    ) -> RowDecision {
        guard loadedCount(members) > 1 else {
            return RowDecision(admitted: legacyAdmits, holdWhenIdle: false, overSharedBudget: false, requiredBytes: 0)
        }
        let required = saturatingAdd(saturatingAdd(
            chargedBytes(members, committedOverride: (requesterID, requesterCommittedBytes)), rowBytes), pendingLoadBytes)
        let fits = required <= limitBytes
        let admitted = legacyAdmits && fits
        let neverFits = !fits && saturatingAdd(
            saturatingAdd(chargedBytes(members, includeRowKV: false), rowBytes), pendingLoadBytes) > limitBytes
        let siblingsHoldRows = members.contains { id, member in
            id != requesterID && member.loaded && (member.liveKVBytes > 0 || member.inFlightRows > 0)
        }
        return RowDecision(
            admitted: admitted, holdWhenIdle: !admitted && !neverFits && siblingsHoldRows,
            overSharedBudget: !fits, requiredBytes: required, neverFits: neverFits)
    }

    /// The KV growth bound of a serial-path row: prompt plus output bound
    /// (the remaining context when the request sets none), at most the
    /// served context.
    static func serialRowTokens(promptTokens: Int, maxOutputTokens: Int?, maxContextTokens: Int) -> Int {
        let context = max(0, maxContextTokens)
        let prompt = max(0, promptTokens)
        let output = maxOutputTokens.map { max(0, $0) } ?? max(0, context - prompt)
        return min(saturatingAdd(prompt, output), max(context, prompt))
    }

    /// Resident weight bytes of a member at registration. Alone, MLX's active
    /// memory after the load (the single-runtime figure, unchanged). With a
    /// sibling loaded, active memory also holds the sibling's live KV and
    /// whatever it allocates meanwhile, so the model's own parameter bytes
    /// are used; without them, active memory less every sibling's weights
    /// and row charges.
    static func residentBytes(
        activeBytes: Int, siblings: [SharedModelMemoryMember], weightBytes: Int?
    ) -> Int {
        let loadedSiblings = siblings.filter(\.loaded)
        guard !loadedSiblings.isEmpty else { return max(0, activeBytes) }
        if let weightBytes, weightBytes > 0 { return weightBytes }
        let held = loadedSiblings.reduce(0) { saturatingAdd($0, saturatingAdd($1.residentBytes, $1.liveKVBytes)) }
        return max(0, activeBytes - held)
    }

    /// The bytes of a loaded model's parameters (weights, quantization
    /// scales and biases), independent of anything else MLX holds.
    static func weightBytes(of container: ModelContainer) async -> Int {
        await container.perform { context in
            context.model.parameters().flattenedValues().reduce(0) { SharedModelMemoryRules.saturatingAdd($0, $1.nbytes) }
        }
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

    /// A load fits when resident(loaded) + estimated resident(new) + for each
    /// member the largest of one minimum row, its live (batched and serial)
    /// row KV and, when pinned, its reserved rows + the new one's minimum
    /// row + margins + models still loading (`pendingLoadBytes`) fits the
    /// limit, else after evicting idle unpinned members (R017 *Load*,
    /// *Pinning*: a load never takes a pinned member's reserved rows).
    static func loadDecision(
        limitBytes: Int?,
        members: [Int: SharedModelMemoryMember],
        estimatedResidentBytes: Int,
        newMinimumRowKVBytes: Int,
        pendingLoadBytes: Int = 0
    ) -> LoadDecision {
        let loaded = members.filter { $0.value.loaded }
        let resident = loaded.values.reduce(0) { saturatingAdd($0, $1.residentBytes) }
        let rows = loaded.values.reduce(max(0, newMinimumRowKVBytes)) {
            saturatingAdd($0, max($1.liveKVBytes,
                MLXMemoryBudget.kvBytes(tokens: minimumRowTokens, bytesPerToken: $1.kvBytesPerToken),
                $1.pinned ? $1.reservedRowKVBytes : 0))
        }
        let margins = (loaded.count + 1) * perMemberMarginBytes
        let required = saturatingAdd(
            saturatingAdd(saturatingAdd(resident, max(0, estimatedResidentBytes)), saturatingAdd(rows, margins)),
            max(0, pendingLoadBytes))
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
                inFlightRows: max(member.inFlightRows, member.liveKVBytes > 0 ? 1 : 0),
                pinned: member.pinned, lastUsedAt: member.lastAdmissionAt)
        }, bytesNeeded: required - limitBytes)
        return LoadDecision(
            admitted: plan.satisfied, reason: plan.satisfied ? "fits_after_eviction" : "insufficient_memory",
            limitBytes: limitBytes, loadedResidentBytes: resident, estimatedResidentBytes: estimatedResidentBytes,
            minimumRowKVBytes: rows, requiredBytes: required, eviction: plan.satisfied ? plan : nil)
    }

    /// The resident bytes MLX's process memory limit is sized from
    /// (`MLXMemoryBudget.limitBytes`, which adds one workspace). One loaded
    /// member or none: nil, so the limit keeps MLX's active memory exactly as
    /// a single runtime did. Several: every loaded member's weights plus one
    /// margin per member beyond the first, so the floor covers all of them,
    /// whichever member loaded last.
    static func processLimitResidentBytes(members: [Int: SharedModelMemoryMember]) -> Int? {
        let loaded = members.values.filter(\.loaded)
        guard loaded.count > 1 else { return nil }
        let weights = loaded.reduce(0) { saturatingAdd($0, $1.residentBytes) }
        return saturatingAdd(weights, saturatingMultiply(loaded.count - 1, perMemberMarginBytes))
    }

    /// KV bytes per token of the only loaded member, nil unless exactly one
    /// is loaded: the admission sample's source once a sibling has loaded and
    /// left, so the last load's value never stands in for the survivor's.
    static func soleLoadedKVBytesPerToken(members: [Int: SharedModelMemoryMember]) -> Int? {
        let loaded = members.values.filter(\.loaded)
        return loaded.count == 1 ? loaded[0].kvBytesPerToken : nil
    }

    /// MLX reads `MLX_MAX_MB_PER_BUFFER` once, when it creates its Metal
    /// device. A family that wants another value than the device has would
    /// run with the wrong budget, so it may not load beside the members
    /// already there. `effective` is the recorded budget and its owner (nil
    /// before any member registered); an operator-set value
    /// (`operatorMB`) is the operator's choice and never conflicts.
    static func commandBufferBudgetConflicts(
        family: String, wantedMB: Int?, effective: (family: String?, megabytes: Int?)?, operatorMB: Int?
    ) -> Bool {
        let owner = effective.map { $0.family } ?? (operatorMB == nil ? nil : "environment")
        let current = effective.map { $0.megabytes } ?? operatorMB
        return owner != "environment" && owner != family && wantedMB != current
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
    /// Live serial-path row charges by id.
    private var serialCharges: [UInt64: (memberID: Int, bytes: Int)] = [:]
    private var nextSerialChargeID: UInt64 = 0
    /// Estimated weights plus margin of models loading now, by reservation
    /// id (R017: a `loading` member is charged before it registers).
    private var loadReservations: [UInt64: Int] = [:]
    private var nextLoadReservationID: UInt64 = 0
    /// `MLX_MAX_MB_PER_BUFFER` as MLX's device read it, and which family set it.
    private var commandBufferBudget: (family: String?, megabytes: Int?)?
    private var commandBufferConflicts: [String] = []
    private let wired = WiredOwner()

    // MARK: Membership

    /// Records the member's weights once loaded and re-derives the process
    /// wired limit. Resident bytes follow `SharedModelMemoryRules.residentBytes`:
    /// the first member's value is exactly the active memory the
    /// single-runtime ticket used; a member loaded beside a sibling gets its
    /// own parameter bytes (`weightBytes`), never the sibling's live KV. A
    /// wiring family drops the buffer cache first, as before, so the
    /// residency sets take the live weights.
    func registerLoaded(
        memberID: Int, label: String, modelFamily: String, kvBytesPerToken: Int?, weightBytes: Int? = nil,
        pinned: Bool = true
    ) async {
        let wires = ModelRuntime.residentWeightsFamilies.contains(modelFamily)
        if wires { Memory.clearCache() }
        let (member, count) = recordLoaded(
            memberID: memberID, label: label, modelFamily: modelFamily, wires: wires,
            activeBytes: Memory.activeMemory, weightBytes: weightBytes, kvBytesPerToken: kvBytesPerToken, pinned: pinned)
        noteCommandBufferBudget(modelFamily: modelFamily)
        FileHandle.standardError.write(Data(
            "event=shared_memory_member_loaded member=\(memberID) family=\(modelFamily) resident_bytes=\(member.residentBytes) kv_bytes_per_token=\(member.kvBytesPerToken) loaded_members=\(count)\n".utf8))
        await syncWiredLimit()
    }

    func recordLoaded(
        memberID: Int, label: String, modelFamily: String, wires: Bool, activeBytes active: Int, weightBytes: Int?,
        kvBytesPerToken: Int?, pinned: Bool
    ) -> (SharedModelMemoryMember, Int) {
        lock.lock(); defer { lock.unlock() }
        let siblings = Array(members.filter { $0.key != memberID }.values)
        var member = members[memberID] ?? SharedModelMemoryMember(label: label)
        member.label = label
        member.modelFamily = modelFamily
        member.loaded = true
        member.residentBytes = SharedModelMemoryRules.residentBytes(
            activeBytes: active, siblings: siblings, weightBytes: weightBytes)
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
        serialCharges = serialCharges.filter { $0.value.memberID != memberID }
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

    func member(_ memberID: Int) -> SharedModelMemoryMember? {
        lock.lock(); defer { lock.unlock() }
        return members[memberID]
    }

    /// Rows the member holds now: in flight (queued, prefilling, decoding),
    /// or at least one while any row KV is still charged. Zero means idle
    /// (R017 *Eviction*).
    func busyRows(memberID: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let member = members[memberID] else { return 0 }
        return max(member.inFlightRows, member.liveKVBytes > 0 ? 1 : 0)
    }

    /// Registration pins every member; the warm set unpins the members a
    /// load may evict.
    func setPinned(memberID: Int, _ pinned: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard members[memberID] != nil else { return }
        members[memberID]!.pinned = pinned
    }

    /// R017 *Pinning*: keeps `rows` rows of `tokensPerRow` tokens of the
    /// member's KV out of every later load decision while it is pinned.
    func reserveRows(memberID: Int, rows: Int, tokensPerRow: Int) {
        lock.lock(); defer { lock.unlock() }
        guard var member = members[memberID] else { return }
        member.reservedRowKVBytes = MLXMemoryBudget.kvBytes(
            tokens: SharedModelMemoryRules.saturatingMultiply(max(0, rows), max(0, tokensPerRow)),
            bytesPerToken: member.kvBytesPerToken)
        members[memberID] = member
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
        member.peakCommittedKVBytes = max(member.peakCommittedKVBytes, member.liveKVBytes)
        members[memberID] = member
    }

    /// Charges a serial-path row (the token loop outside continuous
    /// batching) its worst-case KV, `tokens` at the member's KV bytes per
    /// token, so a sibling's row admission sees it. The serial path has no
    /// admission wait: a charge past the shared budget is counted in
    /// `rowsAdmittedPastBudget`. Returns the charge to release with
    /// `releaseSerialRow` on every exit of the row; nil for an unknown or
    /// unloaded member (nothing charged).
    func chargeSerialRow(memberID: Int, tokens: Int, limitBytes: Int? = MLXMemoryLimit.appliedLimitBytes()) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard var member = members[memberID], member.loaded else { return nil }
        let bytes = MLXMemoryBudget.kvBytes(tokens: tokens, bytesPerToken: member.kvBytesPerToken)
        nextSerialChargeID &+= 1
        serialCharges[nextSerialChargeID] = (memberID, bytes)
        member.serialKVBytes = SharedModelMemoryRules.saturatingAdd(member.serialKVBytes, bytes)
        member.peakCommittedKVBytes = max(member.peakCommittedKVBytes, member.liveKVBytes)
        member.rowsAdmitted += 1
        member.lastAdmissionAt = DispatchTime.now().uptimeNanoseconds
        members[memberID] = member
        if SharedModelMemoryRules.loadedCount(members) > 1, let limitBytes,
           SharedModelMemoryRules.chargedBytes(members) > limitBytes {
            members[memberID]!.rowsAdmittedPastBudget += 1
        }
        return nextSerialChargeID
    }

    /// Releases a serial-path row's charge (finish, cancel or error). A
    /// second release, or a charge whose member is gone, is a no-op.
    func releaseSerialRow(_ chargeID: UInt64?) {
        guard let chargeID else { return }
        lock.lock(); defer { lock.unlock() }
        guard let charge = serialCharges.removeValue(forKey: chargeID), members[charge.memberID] != nil else { return }
        members[charge.memberID]!.serialKVBytes = max(0, members[charge.memberID]!.serialKVBytes - charge.bytes)
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
            requesterID: memberID, requesterCommittedBytes: committed, rowBytes: row,
            pendingLoadBytes: pendingLoadBytesLocked())
        if decision.admitted {
            member.committedKVBytes = SharedModelMemoryRules.saturatingAdd(committed, row)
            member.peakCommittedKVBytes = max(member.peakCommittedKVBytes, member.liveKVBytes)
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

    /// The process-limit and admission inputs from every loaded member
    /// (`SharedModelMemoryRules.processLimitResidentBytes`,
    /// `soleLoadedKVBytesPerToken`).
    func processLimitView() -> (residentBytes: Int?, soleKVBytesPerToken: Int?) {
        lock.lock(); defer { lock.unlock() }
        return (SharedModelMemoryRules.processLimitResidentBytes(members: members),
                SharedModelMemoryRules.soleLoadedKVBytesPerToken(members: members))
    }

    // MARK: Load admission

    /// The process memory limit a load is decided against.
    static func processLimitBytes() -> Int? {
        MLXMemoryLimit.appliedLimitBytes() ?? MLXMemoryBudget.limitBytes(
            recommendedWorkingSetBytes: GPU.maxRecommendedWorkingSetBytes(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    /// R017 *Load*: whether a model of `estimatedResidentBytes` (from its
    /// safetensors sizes) with `minimumRowKVBytes` for one row may load now.
    /// `excluding` decides as if those members were already unloaded.
    func canLoad(
        estimatedResidentBytes: Int, minimumRowKVBytes: Int = 0, limitBytes: Int? = SharedModelMemoryBudget.processLimitBytes(),
        excluding: Set<Int> = []
    ) -> SharedModelMemoryRules.LoadDecision {
        lock.lock(); defer { lock.unlock() }
        return SharedModelMemoryRules.loadDecision(
            limitBytes: limitBytes, members: excluding.isEmpty ? members : members.filter { !excluding.contains($0.key) },
            estimatedResidentBytes: estimatedResidentBytes,
            newMinimumRowKVBytes: minimumRowKVBytes, pendingLoadBytes: pendingLoadBytesLocked())
    }

    /// Charges a model being loaded its estimated weights and one margin
    /// until `releaseLoad`, which runs once the runtime has registered its
    /// measured weights or the load failed.
    func reserveLoad(estimatedResidentBytes: Int) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextLoadReservationID &+= 1
        loadReservations[nextLoadReservationID] = SharedModelMemoryRules.saturatingAdd(
            estimatedResidentBytes, SharedModelMemoryRules.perMemberMarginBytes)
        return nextLoadReservationID
    }

    func releaseLoad(_ reservationID: UInt64) {
        lock.lock(); defer { lock.unlock() }
        loadReservations.removeValue(forKey: reservationID)
    }

    var pendingLoadBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingLoadBytesLocked()
    }

    private func pendingLoadBytesLocked() -> Int {
        loadReservations.values.reduce(0, SharedModelMemoryRules.saturatingAdd)
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

    /// A warm-set load's refusal reason when `modelFamily` needs another
    /// command-buffer budget than the device was created with; nil when it
    /// may load (`SharedModelMemoryRules.commandBufferBudgetConflicts`).
    func commandBufferBudgetConflict(modelFamily: String) -> String? {
        let operatorMB = ProcessInfo.processInfo.environment["MLX_MAX_MB_PER_BUFFER"].flatMap(Int.init)
        let wanted = ModelRuntime.commandBufferBudgetMBByFamily[modelFamily]
        lock.lock()
        let effective = commandBufferBudget
        lock.unlock()
        guard SharedModelMemoryRules.commandBufferBudgetConflicts(
            family: modelFamily, wantedMB: wanted, effective: effective, operatorMB: operatorMB
        ) else { return nil }
        let current = effective.map { $0.megabytes } ?? operatorMB
        return "family=\(modelFamily) wanted_mb=\(wanted.map(String.init) ?? "default") effective_mb=\(current.map(String.init) ?? "default")"
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
        let serialKVBytes: Int
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
        for id in peakMembers.keys {
            peakMembers[id]!.committedKVBytes = peakMembers[id]!.peakCommittedKVBytes
            peakMembers[id]!.serialKVBytes = 0
        }
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
                    serialKVBytes: m.serialKVBytes, peakCommittedKVBytes: m.peakCommittedKVBytes, inFlightRows: m.inFlightRows, pinned: m.pinned,
                    cacheLimitRequirementBytes: m.cacheLimitRequirementBytes, rowsAdmitted: m.rowsAdmitted,
                    rowsRefused: m.rowsRefused, rowsAdmittedPastBudget: m.rowsAdmittedPastBudget)
            })
    }

    /// Starts a new measurement window for the peak committed KV.
    func resetPeaks() {
        lock.lock(); defer { lock.unlock() }
        for id in members.keys { members[id]!.peakCommittedKVBytes = members[id]!.liveKVBytes }
    }
}
