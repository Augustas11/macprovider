import Foundation

/// SPEC-001-R016 `warm_models`: one entry per warm-set member, the primary
/// first. Sent on the v2 `auth_request` initial stage, the legacy `hello`,
/// every `heartbeat` and `/v1/status` whenever the process has a warm set,
/// also while it has one member.
enum WarmModelsWire {
    /// Top-level fields whose value the primary entry repeats, so for a warm
    /// set of one the entry and the top-level fields say the same thing.
    static let primaryFieldKeys = [
        "model_id",
        "max_context_tokens",
        "throughput_tps_estimate",
        "model_hash",
        "model_hash_algorithm",
        "weights_manifest_sha256",
        "weights_manifest_algorithm",
        "model_params_b",
        "cb_self_check",
        "engine_profile",
    ]

    /// Adds `warm_models` to `message`, a coordinator handshake or
    /// heartbeat whose top-level fields describe the primary, and writes the
    /// primary entry's value of every `primaryFieldKeys` field back to the
    /// top level. Both come from one build, so the coordinator's
    /// primary-versus-top-level check (SPEC-002-R011) can never fail: in
    /// particular the top-level `throughput_tps_estimate` is the primary's
    /// contended estimate (SPEC-001-R018), which equals its solo rate for a
    /// warm set of one or with no busy sibling.
    ///
    /// `sessionModels` is the `supported_models` the session declared: an
    /// entry outside it would make the coordinator reject the whole frame.
    /// Empty means the session declared none (the legacy `hello`), which
    /// the coordinator reads as the top-level model alone; nil skips the
    /// check. A member outside it is left out; a primary outside it (a
    /// warm swap to a model the session never declared) sends no
    /// `warm_models` at all, which the coordinator reads as a warm set of
    /// one built from the top-level fields, exactly as before the field
    /// existed.
    static func attach(
        to message: inout [String: Any],
        primarySlotsTotal: Int,
        primarySlotsFree: Int,
        primaryMemberKey: String? = nil,
        views: [WarmModelMemberView],
        sessionModels: [String]?,
        contention: WarmSetContentionWindow?
    ) {
        var members = views
        if let sessionModels {
            let primaryKey = (message["model_id"] as? String).map(key)
            let declared = sessionModels.isEmpty ? Set(primaryKey.map { [$0] } ?? []) : Set(sessionModels.map(key))
            guard let primaryKey, declared.contains(primaryKey) else { return }
            let primaryIndex = primaryViewIndex(views, primaryMemberKey: primaryMemberKey, primaryKey: primaryKey)
            members = views.indices.filter { $0 == primaryIndex || declared.contains(views[$0].key) }.map { views[$0] }
        }
        let entries = entries(
            primaryFields: message, primarySlotsTotal: primarySlotsTotal, primarySlotsFree: primarySlotsFree,
            primaryMemberKey: primaryMemberKey, views: members, contention: contention)
        for field in primaryFieldKeys {
            if let value = entries[0][field] { message[field] = value }
        }
        message["warm_models"] = entries
    }

    /// The view the top-level fields describe. `primaryMemberKey` is the
    /// member the provider status names primary, read in the same snapshot
    /// as the top-level identity and capacity, so it is the one source of
    /// "who is primary" on the wire: a promotion switches it in one step
    /// (`ProviderStatus.promoteWarmPrimary`). Without it, the view with the
    /// top-level model id, else the view the table marks primary.
    static func primaryViewIndex(_ views: [WarmModelMemberView], primaryMemberKey: String?, primaryKey: String?) -> Int? {
        if let primaryMemberKey, let index = views.firstIndex(where: { $0.memberKey == primaryMemberKey }) {
            return index
        }
        if let primaryKey, let index = views.firstIndex(where: { $0.key == primaryKey }) {
            return index
        }
        return views.firstIndex(where: \.primary)
    }

    /// `primaryFields` is the message the entries ride on (its top-level
    /// fields describe the primary); `primarySlotsTotal` and
    /// `primarySlotsFree` are the primary's rows, as the top-level
    /// `slots_total` / `slots_free` report them. A `loading` or `evicting`
    /// entry carries no `slots_free`. Each entry's `throughput_tps_estimate`
    /// is its member's rate under the measured `contention` (SPEC-001-R018);
    /// a coordinator frame takes the primary's back to the top level
    /// (`attach`).
    ///
    /// The primary entry is the top-level fields, and the view they
    /// describe is `primaryViewIndex`; every other view is listed once as a
    /// further member, whatever its `primary` flag says. A promotion marks
    /// the new primary in the table before the provider status names it, so
    /// for that moment the new primary is a further member here and the old
    /// one is still the primary entry: no member is ever dropped, and there
    /// is exactly one primary, the one the top-level fields describe.
    static func entries(
        primaryFields: [String: Any],
        primarySlotsTotal: Int,
        primarySlotsFree: Int,
        primaryMemberKey: String? = nil,
        views: [WarmModelMemberView],
        contention: WarmSetContentionWindow? = WarmSetContentionMeter.shared.window()
    ) -> [[String: Any]] {
        let primaryLoading = primaryFields["loading"] as? Bool == true
        let primaryKey = (primaryFields["model_id"] as? String).map(key)
        let primaryIndex = primaryViewIndex(views, primaryMemberKey: primaryMemberKey, primaryKey: primaryKey)
        let primaryView = primaryIndex.map { views[$0] }
        var primary: [String: Any] = [
            "state": primaryLoading ? WarmModelState.loading.rawValue : WarmModelState.warm.rawValue,
            "primary": true,
            "pinned": primaryView?.pinned ?? true,
            "slots_total": primarySlotsTotal,
        ]
        if !primaryLoading {
            primary["slots_free"] = primarySlotsFree
        }
        for key in primaryFieldKeys {
            if let value = primaryFields[key], !(value is NSNull) {
                primary[key] = value
            }
        }
        let members = Set(views.compactMap(\.memberID))
        if let contention, let solo = primary["throughput_tps_estimate"] as? Double {
            primary["throughput_tps_estimate"] = contention.estimate(
                solo: solo, memberID: primaryView?.memberID, members: members)
        }
        let primaryEngineProfile = primaryFields["engine_profile"] as? [String: Any]
        return [primary] + views.indices.filter { $0 != primaryIndex }.map { views[$0] }.map { view in
            var entry = secondaryEntry(view, primaryEngineProfile: primaryEngineProfile)
            if let contention, let solo = entry["throughput_tps_estimate"] as? Double {
                entry["throughput_tps_estimate"] = contention.estimate(solo: solo, memberID: view.memberID, members: members)
            }
            return entry
        }
    }

    /// The SPEC-010 case fold of a model id, as `WarmModelMemberView.key`.
    private static func key(_ modelID: String) -> String { modelID.lowercased(with: nil) }

    /// `primaryEngineProfile` is the primary's `engine_profile`: a member's
    /// profile takes its chip and memory classes from it and is sent only
    /// beside it.
    static func secondaryEntry(_ view: WarmModelMemberView, primaryEngineProfile: [String: Any]? = nil) -> [String: Any] {
        var entry: [String: Any] = [
            "model_id": view.modelID,
            "state": view.state.rawValue,
            "primary": false,
            "pinned": view.pinned,
            "slots_total": view.info?.slotsTotal ?? 0,
        ]
        if let slotsFree = view.slotsFree {
            entry["slots_free"] = slotsFree
        }
        guard let info = view.info else { return entry }
        entry["max_context_tokens"] = info.maxContextTokens
        entry["throughput_tps_estimate"] = info.throughputTPSEstimate
        if let modelParamsB = info.modelParamsB {
            entry["model_params_b"] = modelParamsB
        }
        if let modelHash = info.modelHash {
            entry["model_hash"] = modelHash
            if let algorithm = info.modelHashAlgorithm {
                entry["model_hash_algorithm"] = algorithm
            }
        }
        if let weights = info.weightsManifestSHA256 {
            entry["weights_manifest_sha256"] = weights
            entry["weights_manifest_algorithm"] = ModelArtifactIdentity.safetensorsManifestV1
        }
        // SPEC-001-R019: the member's own tool selection modes, vision
        // runtime, self-check and engine, each by the rule the top-level
        // field follows for the primary.
        entry["tool_selection_capabilities"] = CoordinatorClient.toolSelectionCapabilities(
            wireModelID: view.modelID, runtimeWireModelID: view.modelID, runtimeSource: nil)
        if let vision = info.visionCapability {
            entry["vision_runtime_capabilities"] = [vision]
        }
        if let report = info.cbSelfCheck {
            entry["cb_self_check"] = report.jsonObject
        }
        if let engine = info.engine, let primaryEngineProfile {
            var profile = EngineProfile(
                nativeMTPActive: engine.nativeMTPActive,
                continuousBatchingActive: engine.continuousBatchingActive,
                cbGrantedSlots: engine.cbGrantedSlots,
                chip: nil,
                ramGB: 0,
                maxContextTokens: info.maxContextTokens
            ).wireObject
            profile["chip_class"] = primaryEngineProfile["chip_class"]
            profile["ram_class_gb"] = primaryEngineProfile["ram_class_gb"]
            entry["engine_profile"] = profile
        }
        return entry
    }
}
