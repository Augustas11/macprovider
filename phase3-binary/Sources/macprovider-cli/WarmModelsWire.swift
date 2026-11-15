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

    /// `primaryFields` is the message the entries ride on (its top-level
    /// fields describe the primary); `primarySlotsTotal` and
    /// `primarySlotsFree` are the primary's rows, as the top-level
    /// `slots_total` / `slots_free` report them. A `loading` or `evicting`
    /// entry carries no `slots_free`.
    static func entries(
        primaryFields: [String: Any],
        primarySlotsTotal: Int,
        primarySlotsFree: Int,
        views: [WarmModelMemberView]
    ) -> [[String: Any]] {
        let primaryLoading = primaryFields["loading"] as? Bool == true
        var primary: [String: Any] = [
            "state": primaryLoading ? WarmModelState.loading.rawValue : WarmModelState.warm.rawValue,
            "primary": true,
            "pinned": views.first(where: \.primary)?.pinned ?? true,
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
        let primaryEngineProfile = primaryFields["engine_profile"] as? [String: Any]
        return [primary] + views.filter { !$0.primary }.map { secondaryEntry($0, primaryEngineProfile: primaryEngineProfile) }
    }

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
        // SPEC-001-R019: the member's own self-check and engine.
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
