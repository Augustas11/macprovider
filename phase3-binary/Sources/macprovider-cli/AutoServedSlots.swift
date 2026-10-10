import CryptoKit
import Foundation
import MacProviderCore

/// SPEC-023-R009 / SPEC-038-R011: the slot count `serve` runs, recomputed at
/// every serve start from the signed continuous-batching policy loaded there,
/// so a new policy entry raises existing providers without another
/// `autotune --recommend --apply`.
///
/// Precedence: an owner-pinned `max_concurrency_override` is served as written;
/// a draft model forces 1 (SPEC-028 FR-4); continuous batching authorized and
/// active for the served tuple runs the memory-fit recommendation; anything
/// else runs 1.
enum AutoServedSlots {
    /// MLX's quantized matmul switches from the vector kernel (qmv) to the
    /// matrix kernel (qmm) above 5 rows. On M1/M2 GPUs (Ultra excepted) rows
    /// 6-8 pay that switch without an aggregate gain, so auto slots stop at 5
    /// there. An owner pin may still go higher.
    static let appleM1M2NonUltraRowCap = 5

    struct Decision: Equatable {
        let slots: Int
        /// Log reason: `owner_pinned`, `draft_model`, `cb_authorized`,
        /// `cb_not_authorized`.
        let reason: String
    }

    static func resolve(
        configuredSlots: Int?,
        source: MaxConcurrencySource?,
        draftConfigured: Bool,
        continuousBatchingAuthorized: Bool,
        recommendedSlots: () -> Int
    ) -> Decision {
        if source == .owner {
            return Decision(
                slots: ProviderCapacity.servedSlotCount(maxConcurrencyOverride: configuredSlots),
                reason: "owner_pinned"
            )
        }
        if draftConfigured {
            return Decision(slots: 1, reason: "draft_model")
        }
        guard continuousBatchingAuthorized else {
            return Decision(slots: 1, reason: "cb_not_authorized")
        }
        return Decision(
            slots: min(max(1, recommendedSlots()), ProviderCapacity.maxConcurrencyOverrideLimit),
            reason: "cb_authorized"
        )
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

    /// Pre-load gate: the verified signed policy carries an enabled entry for
    /// the served model key and no emergency off is configured. The exact
    /// tuple match is known only after the model loads; `serve` checks it then
    /// and lowers the slots to 1 when batching is not active.
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
    /// Post-load gate: batching runs for the loaded tuple under the signed
    /// policy (not only an expert/test mode).
    static func continuousBatchingServing(_ snapshot: RuntimeContinuousBatchingSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.active && snapshot.policy.authorized
    }

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
