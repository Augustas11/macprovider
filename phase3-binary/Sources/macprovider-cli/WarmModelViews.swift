import Foundation

/// What a warm member's runtime reports for preflight and the wire
/// (SPEC-001-R016), published by the owner of the runtime once it is loaded
/// and again whenever a value changes.
struct WarmModelMemberInfo: Sendable, Equatable {
    var maxContextTokens: Int
    /// Rows this model may hold (`slots_total`).
    var slotsTotal: Int
    var throughputTPSEstimate: Double = 0
    var modelHash: String? = nil
    var modelHashAlgorithm: String? = nil
    var weightsManifestSHA256: String? = nil
    var modelParamsB: Double? = nil
    /// SPEC-001-R019: this member's own continuous-batching self-check.
    var cbSelfCheck: ContinuousBatchingSelfCheckReport? = nil
    /// SPEC-001-R019: this member's own serving engine state, the inputs of
    /// its `engine_profile`.
    var engine: WarmModelEngineState? = nil
}

/// What a member's `engine_profile` says about its own runtime; the chip and
/// memory classes are the process's.
struct WarmModelEngineState: Sendable, Equatable {
    let continuousBatchingActive: Bool
    let cbGrantedSlots: Int
    let nativeMTPActive: Bool

    init(continuousBatchingActive: Bool, cbGrantedSlots: Int, nativeMTPActive: Bool) {
        self.continuousBatchingActive = continuousBatchingActive
        self.cbGrantedSlots = cbGrantedSlots
        self.nativeMTPActive = nativeMTPActive
    }

    init(snapshot: RuntimeSnapshot) {
        self.init(
            continuousBatchingActive: snapshot.continuousBatching?.active == true,
            cbGrantedSlots: snapshot.continuousBatching?.scheduler?.slotsTotal ?? 0,
            nativeMTPActive: snapshot.nativeMTPStatus.mode == .active)
    }
}

/// One member as preflight and the wire read it at one instant.
struct WarmModelMemberView: Sendable, Equatable {
    let modelID: String
    /// `modelID` case-folded (SPEC-010): the routing key.
    let key: String
    let state: WarmModelState
    let primary: Bool
    let pinned: Bool
    /// Requests holding the member: leased before admission, released at
    /// their terminal point.
    let inFlight: Int
    /// Nil until the member's runtime has published it.
    let info: WarmModelMemberInfo?

    /// Rows the member may admit now; nil unless `warm` (absent on the wire
    /// means zero).
    var slotsFree: Int? {
        guard state == .warm else { return nil }
        return max(0, (info?.slotsTotal ?? 0) - inFlight)
    }
}

/// A lock-protected copy of the warm set's member views, republished by the
/// table on every change, so the coordinator preflight answer reads it
/// without awaiting any actor or runtime.
final class WarmModelViewCell: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [WarmModelMemberView] = []

    /// Primary first, then the table's insertion order.
    var value: [WarmModelMemberView] {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func publish(_ views: [WarmModelMemberView]) {
        lock.lock()
        current = views
        lock.unlock()
    }
}
