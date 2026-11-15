import Foundation

/// A runtime a warm-set member holds (SPEC-001-R016). `ModelRuntime`
/// conforms; tests use fakes that load no model.
protocol WarmModelRuntime: AnyObject, Sendable {
    /// SPEC-001-R017: the runtime's key in `SharedModelMemoryBudget`.
    var memoryBudgetMemberID: Int { get }
    /// R017 *Pinning*: the rows (`slots_total`) and per-row token bound a
    /// pinned member keeps through a later load.
    func warmSetRowReservation() async -> WarmModelRowReservation
    /// Releases the model and every per-runtime registration once the
    /// member is idle; never writes the process-wide provider status.
    func unloadForWarmSet() async
}

struct WarmModelRowReservation: Sendable, Equatable {
    let rows: Int
    let tokensPerRow: Int
}

extension ModelRuntime: WarmModelRuntime {}

/// SPEC-001-R016 entry state. Only `warm` is routing-eligible.
enum WarmModelState: String, Sendable, Equatable {
    case loading
    case warm
    case evicting
}

enum WarmModelTableError: Error, Equatable, CustomStringConvertible {
    /// No `warm` entry has the id (absent, loading or evicting): the
    /// `model_not_loaded` refusal of R016 *Request routing*.
    case notLoaded(modelID: String)
    case duplicate(modelID: String)
    case primaryExists
    case notEvictable(modelID: String, reason: String)

    var reason: String {
        switch self {
        case .notLoaded: return "model_not_loaded"
        case .duplicate: return "model_already_loaded"
        case .primaryExists: return "primary_exists"
        case let .notEvictable(_, reason): return reason
        }
    }

    var description: String {
        switch self {
        case let .notLoaded(modelID): return "model_not_loaded model=\(modelID)"
        case let .duplicate(modelID): return "model_already_loaded model=\(modelID)"
        case .primaryExists: return "primary_exists"
        case let .notEvictable(modelID, reason): return "\(reason) model=\(modelID)"
        }
    }
}

/// One member as the wire and the router see it at one instant.
struct WarmModelTableEntry<Runtime: WarmModelRuntime>: Sendable {
    /// Identifies the member across a primary re-key; leases and state
    /// transitions address it.
    let token: UInt64
    /// The id as configured or requested.
    let modelID: String
    /// `modelID` case-folded (SPEC-010): the routing key.
    let key: String
    /// Nil only while `loading`.
    let runtime: Runtime?
    let state: WarmModelState
    let primary: Bool
    let pinned: Bool
    let leases: Int
    /// Monotonic nanoseconds of the latest lease; 0 before the first.
    let lastAdmissionAt: UInt64
    /// Nil only while `loading`.
    let memberID: Int?
}

/// SPEC-001-R016 warm set: which runtime serves which model id, and how many
/// requests hold each runtime. Every method is synchronous and never awaits
/// while the lock is held, so the coordinator preflight answer can read it
/// inline.
final class WarmModelTable<Runtime: WarmModelRuntime>: @unchecked Sendable {
    private struct Member {
        var token: UInt64
        var modelID: String
        var key: String
        var runtime: Runtime?
        var state: WarmModelState
        var primary: Bool
        var pinned: Bool
        var leases = 0
        var lastAdmissionAt: UInt64 = 0
        var memberID: Int?
    }

    private let lock = NSLock()
    /// Insertion order; `entries()` lists the primary first.
    private var members: [Member] = []
    private var nextToken: UInt64 = 0
    private let now: @Sendable () -> UInt64

    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
    }

    static func key(_ modelID: String) -> String { modelID.lowercased(with: nil) }

    // MARK: Lookup

    /// R016 *Request routing* for `served_model_id`: absent means the
    /// primary, exactly as a single-model provider; present names a `warm`
    /// member or is refused.
    func resolve(servedModelID: String?) throws -> WarmModelTableEntry<Runtime> {
        lock.lock(); defer { lock.unlock() }
        return snapshot(try resolvedIndexLocked(servedModelID: servedModelID))
    }

    /// R016 loopback local request: the `warm` member whose id equals the
    /// body `model`, else the primary. Nil only with no primary.
    func resolveLocal(bodyModel: String?) -> WarmModelTableEntry<Runtime>? {
        lock.lock(); defer { lock.unlock() }
        return localIndexLocked(bodyModel: bodyModel).map(snapshot)
    }

    /// Primary first, then insertion order.
    func entries() -> [WarmModelTableEntry<Runtime>] {
        lock.lock(); defer { lock.unlock() }
        return (members.filter(\.primary) + members.filter { !$0.primary }).map(snapshot)
    }

    func entry(modelID: String) -> WarmModelTableEntry<Runtime>? {
        lock.lock(); defer { lock.unlock() }
        return indexLocked(key: Self.key(modelID)).map { snapshot(members[$0]) }
    }

    func entry(token: UInt64) -> WarmModelTableEntry<Runtime>? {
        lock.lock(); defer { lock.unlock() }
        return indexLocked(token: token).map { snapshot(members[$0]) }
    }

    // MARK: Leases

    /// Holds the routed runtime for one request. Taken before the runtime's
    /// request handle, so an evicting or loading member never admits a row.
    func lease(servedModelID: String?) throws -> WarmModelLease<Runtime> {
        lock.lock(); defer { lock.unlock() }
        return leaseLocked(try resolvedIndexLocked(servedModelID: servedModelID))
    }

    func leaseLocal(bodyModel: String?) throws -> WarmModelLease<Runtime> {
        lock.lock(); defer { lock.unlock() }
        guard let index = localIndexLocked(bodyModel: bodyModel) else {
            throw WarmModelTableError.notLoaded(modelID: bodyModel ?? "")
        }
        return leaseLocked(index)
    }

    fileprivate func release(_ lease: WarmModelLease<Runtime>) {
        lock.lock(); defer { lock.unlock() }
        guard !lease.released else { return }
        lease.released = true
        guard let index = indexLocked(token: lease.token) else { return }
        members[index].leases = max(0, members[index].leases - 1)
    }

    private func leaseLocked(_ index: Int) -> WarmModelLease<Runtime> {
        members[index].leases += 1
        members[index].lastAdmissionAt = now()
        return WarmModelLease(
            table: self, token: members[index].token, modelID: members[index].modelID,
            runtime: members[index].runtime!)
    }

    // MARK: State transitions

    /// The boot model, or a runtime adopted as primary: `warm` at once.
    @discardableResult
    func insertPrimary(modelID: String, runtime: Runtime, pinned: Bool = true) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard !members.contains(where: \.primary) else { throw WarmModelTableError.primaryExists }
        return try insertLocked(Member(
            token: 0, modelID: modelID, key: Self.key(modelID), runtime: runtime, state: .warm,
            primary: true, pinned: pinned, memberID: runtime.memoryBudgetMemberID))
    }

    /// A `loading` entry: listed on the wire, never routed or leased.
    func beginLoading(modelID: String, pinned: Bool) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return try insertLocked(Member(
            token: 0, modelID: modelID, key: Self.key(modelID), runtime: nil, state: .loading,
            primary: false, pinned: pinned))
    }

    func finishLoading(token: UInt64, runtime: Runtime) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = indexLocked(token: token), members[index].state == .loading else {
            throw WarmModelTableError.notLoaded(modelID: "\(token)")
        }
        members[index].runtime = runtime
        members[index].memberID = runtime.memoryBudgetMemberID
        members[index].state = .warm
    }

    /// A failed load leaves the table as it was before `beginLoading`.
    func cancelLoading(token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let index = indexLocked(token: token), members[index].state == .loading else { return }
        members.remove(at: index)
    }

    /// R017 *Eviction*: only a `warm`, non-primary member with no lease may
    /// start evicting; a pinned one only when `allowPinned` (an explicit
    /// unload, never a load's LRU eviction). From then on it refuses leases.
    func beginEvicting(modelID: String, allowPinned: Bool) throws -> WarmModelTableEntry<Runtime> {
        lock.lock(); defer { lock.unlock() }
        guard let index = indexLocked(key: Self.key(modelID)) else {
            throw WarmModelTableError.notLoaded(modelID: modelID)
        }
        try checkEvictableLocked(index, allowPinned: allowPinned)
        members[index].state = .evicting
        return snapshot(members[index])
    }

    /// Marks every listed budget member `evicting` or none of them: each
    /// must pass `beginEvicting`'s rules with `allowPinned` false.
    func beginEvicting(memberIDs: [Int]) throws -> [WarmModelTableEntry<Runtime>] {
        lock.lock(); defer { lock.unlock() }
        var indexes: [Int] = []
        for memberID in memberIDs {
            guard let index = members.firstIndex(where: { $0.memberID == memberID }) else {
                throw WarmModelTableError.notEvictable(modelID: "member-\(memberID)", reason: "not_in_warm_set")
            }
            try checkEvictableLocked(index, allowPinned: false)
            indexes.append(index)
        }
        for index in indexes { members[index].state = .evicting }
        return indexes.map { snapshot(members[$0]) }
    }

    /// Returns an `evicting` member to `warm` (its eviction was abandoned).
    func cancelEvicting(token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let index = indexLocked(token: token), members[index].state == .evicting else { return }
        members[index].state = .warm
    }

    /// Removes an `evicting` member once its runtime is unloaded.
    func finishEvicting(token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let index = indexLocked(token: token), members[index].state == .evicting else { return }
        members.remove(at: index)
    }

    /// SPEC-011 warm swap of the primary: the same runtime now serves
    /// `modelID`. Outstanding leases keep counting against the primary.
    func rekeyPrimary(to modelID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = members.firstIndex(where: \.primary) else {
            throw WarmModelTableError.notLoaded(modelID: modelID)
        }
        let key = Self.key(modelID)
        if let other = indexLocked(key: key), other != index { throw WarmModelTableError.duplicate(modelID: modelID) }
        members[index].modelID = modelID
        members[index].key = key
    }

    // MARK: Private

    private func insertLocked(_ member: Member) throws -> UInt64 {
        guard indexLocked(key: member.key) == nil else { throw WarmModelTableError.duplicate(modelID: member.modelID) }
        nextToken &+= 1
        var member = member
        member.token = nextToken
        members.append(member)
        return nextToken
    }

    private func checkEvictableLocked(_ index: Int, allowPinned: Bool) throws {
        let member = members[index]
        guard member.state == .warm else {
            throw WarmModelTableError.notEvictable(modelID: member.modelID, reason: "not_warm")
        }
        guard !member.primary else {
            throw WarmModelTableError.notEvictable(modelID: member.modelID, reason: "primary")
        }
        guard allowPinned || !member.pinned else {
            throw WarmModelTableError.notEvictable(modelID: member.modelID, reason: "pinned")
        }
        guard member.leases == 0 else {
            throw WarmModelTableError.notEvictable(modelID: member.modelID, reason: "busy")
        }
    }

    private func resolvedIndexLocked(servedModelID: String?) throws -> Int {
        guard let servedModelID else {
            guard let primary = members.firstIndex(where: \.primary) else {
                throw WarmModelTableError.notLoaded(modelID: "")
            }
            return primary
        }
        guard let index = indexLocked(key: Self.key(servedModelID)), members[index].state == .warm else {
            throw WarmModelTableError.notLoaded(modelID: servedModelID)
        }
        return index
    }

    private func localIndexLocked(bodyModel: String?) -> Int? {
        if let bodyModel, let index = indexLocked(key: Self.key(bodyModel)), members[index].state == .warm {
            return index
        }
        return members.firstIndex(where: \.primary)
    }

    private func indexLocked(key: String) -> Int? { members.firstIndex { $0.key == key } }
    private func indexLocked(token: UInt64) -> Int? { members.firstIndex { $0.token == token } }

    private func snapshot(_ index: Int) -> WarmModelTableEntry<Runtime> { snapshot(members[index]) }

    private func snapshot(_ member: Member) -> WarmModelTableEntry<Runtime> {
        WarmModelTableEntry(
            token: member.token, modelID: member.modelID, key: member.key, runtime: member.runtime,
            state: member.state, primary: member.primary, pinned: member.pinned, leases: member.leases,
            lastAdmissionAt: member.lastAdmissionAt, memberID: member.memberID)
    }
}

/// One request's hold on a warm member. `release()` is idempotent; a lease
/// dropped without release is released by `deinit`.
final class WarmModelLease<Runtime: WarmModelRuntime>: @unchecked Sendable {
    let token: UInt64
    let modelID: String
    let runtime: Runtime
    private let table: WarmModelTable<Runtime>
    /// Guarded by the table's lock.
    fileprivate var released = false

    fileprivate init(table: WarmModelTable<Runtime>, token: UInt64, modelID: String, runtime: Runtime) {
        self.table = table
        self.token = token
        self.modelID = modelID
        self.runtime = runtime
    }

    func release() { table.release(self) }

    deinit { table.release(self) }
}
