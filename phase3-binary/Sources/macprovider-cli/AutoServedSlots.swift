import CryptoKit
import Foundation
import MacProviderCore

/// SPEC-023-R009 / SPEC-038-R011 (v0.3.15): the slot count `serve` runs.
///
/// Precedence: an owner-pinned `max_concurrency_override` is served as written;
/// a draft model or the emergency off forces 1 (SPEC-028 FR-4); otherwise the
/// on-device continuous-batching self-check (`ContinuousBatchingSelfCheck`)
/// picks the count, at most the memory-fit recommendation for this Mac. Until
/// it decides, serve runs one slot, or the configured count when a signed
/// positive policy entry names the served model (provisional grant).
enum AutoServedSlots {
    /// MLX's quantized matmul switches from the vector kernel (qmv) to the
    /// matrix kernel (qmm) above 5 rows. On M1/M2 GPUs (Ultra excepted) rows
    /// 6-8 pay that switch without an aggregate gain, so auto slots stop at 5
    /// there. An owner pin may still go higher.
    static let appleM1M2NonUltraRowCap = 5

    struct Plan: Equatable {
        /// Scheduler rows built at load: the most the self-check may grant.
        let rows: Int
        /// Slots advertised from the first heartbeat until the self-check (or
        /// a stored decision) changes them.
        let initialServed: Int
        /// Non-nil when the owner pinned the count; the self-check then only
        /// turns batching on or off.
        let ownerPinned: Int?
        /// Log reason: `owner_pinned`, `draft_model`, `emergency_off`,
        /// `provisional_policy_entry`, `self_check_pending`.
        let reason: String

        /// False when no self-check may raise the count from `initialServed`.
        var selfChecked: Bool { reason != "draft_model" && reason != "emergency_off" }
    }

    static func plan(
        configuredSlots: Int?,
        source: MaxConcurrencySource?,
        draftConfigured: Bool,
        emergencyOff: Bool,
        provisionalPolicyEntry: Bool,
        recommendedSlots: () -> Int,
        memoryFitKnown: Bool = false
    ) -> Plan {
        let configured = ProviderCapacity.servedSlotCount(maxConcurrencyOverride: configuredSlots)
        if source == .owner {
            return Plan(rows: configured, initialServed: configured, ownerPinned: configured, reason: "owner_pinned")
        }
        if draftConfigured {
            return Plan(rows: 1, initialServed: 1, ownerPinned: nil, reason: "draft_model")
        }
        if emergencyOff {
            return Plan(rows: 1, initialServed: 1, ownerPinned: nil, reason: "emergency_off")
        }
        let recommended = min(max(1, recommendedSlots()), ProviderCapacity.maxConcurrencyOverrideLimit)
        if provisionalPolicyEntry {
            // SPEC-023-R009: never above a computable memory fit; without one
            // the configured count already served keeps its rows.
            let rows = memoryFitKnown ? recommended : max(recommended, configured)
            return Plan(
                rows: rows,
                initialServed: min(configured, rows),
                ownerPinned: nil,
                reason: "provisional_policy_entry"
            )
        }
        return Plan(rows: recommended, initialServed: 1, ownerPinned: nil, reason: "self_check_pending")
    }

    /// The autotune recommendation for this Mac and model: the memory-fit
    /// depth at the served context when the model geometry is known, else the
    /// conservative chip/RAM tier constant (as `autotune --calibrate-concurrency`
    /// bounds its sweep), capped for M1/M2 and at the served hard cap.
    static func recommendedSlots(chip: String, memoryGB: Int, memoryFitCap: Int?) -> Int {
        let tierConstant = AutotuneRecommendHardware(
            machine: nil,
            chip: chip,
            memoryGB: memoryGB,
            bandwidthTier: BandwidthTier.derive(chip: chip),
            osVersion: "",
            binaryVersion: "",
            diversificationID: "",
            hardwareIdentityHash: ""
        ).recommendedMaxBatch
        var slots = memoryFitCap ?? tierConstant
        if isAppleM1M2NonUltra(chip: chip) {
            slots = min(slots, appleM1M2NonUltraRowCap)
        }
        return min(max(1, slots), ProviderCapacity.maxConcurrencyOverrideLimit)
    }

    static func isAppleM1M2NonUltra(chip: String) -> Bool {
        let normalized = chip.lowercased()
        guard !normalized.contains("ultra") else { return false }
        return normalized.range(of: #"\bm[12]\b"#, options: .regularExpression) != nil
    }

    /// Provisional grant: the verified signed policy carries an enabled entry
    /// for the served model key (SPEC-038 v0.3.15; the self-check result then
    /// replaces it).
    static func policyAuthorizesServedModel(
        _ policy: ContinuousBatchingPolicyLoadResult,
        modelKeys: Set<String>,
        emergencyOff: Bool
    ) -> Bool {
        guard policy.status == .liveVerified, !emergencyOff else { return false }
        return policy.selection.entries.contains {
            modelKeys.contains($0.modelKey) && $0.rollout != .off
        }
    }
}

extension AutoServedSlots {
    /// `AutotuneModelContextCap.memoryFitBatchDepth` at the served context for
    /// the configured artifact; nil when its geometry or catalog row is unknown.
    static func memoryFitSlots(
        configJSONData: Data?,
        memoryGB: Int,
        catalogMinRAMGB: Int?,
        contextTokens: Int,
        weightsBytes: UInt64?
    ) -> Int? {
        guard let configJSONData, let catalogMinRAMGB else { return nil }
        return AutotuneModelContextCap.memoryFitBatchDepth(
            configData: configJSONData,
            verifiedConfigSHA256: SHA256.hash(data: configJSONData).map { String(format: "%02x", $0) }.joined(),
            hardwareMemoryGB: memoryGB,
            catalogMinRAMGB: catalogMinRAMGB,
            calibrationContextTokens: contextTokens,
            verifiedArtifactSizeBytes: weightsBytes.flatMap { $0 > 0 && $0 <= UInt64(Int.max) ? Int($0) : nil }
        )
    }
}
