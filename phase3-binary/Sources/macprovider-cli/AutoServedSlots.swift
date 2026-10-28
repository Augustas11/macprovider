import CryptoKit
import Foundation
import MacProviderCore

/// SPEC-023-R009 / SPEC-038-R011 (v0.3.15): the slot count `serve` runs.
///
/// Precedence: an owner-pinned `max_concurrency_override` retains its intent;
/// a draft model or the emergency off forces 1 (SPEC-028 FR-4); otherwise the
/// on-device continuous-batching self-check (`ContinuousBatchingSelfCheck`)
/// picks the count, at most the memory-fit recommendation for this Mac. Until
/// it decides, serve runs one slot, or the configured count when a signed
/// positive policy entry names the served model (provisional grant). A signed
/// `max_served_slots` (SPEC-038 FR-CB11 v0.3.22) caps every one of these,
/// the owner pin included; the physical-memory tier also bounds every branch.
/// Neither bound raises a count.
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
        memoryFitKnown: Bool = false,
        policyCeiling: Int? = nil,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Plan {
        let ceiling = ProviderCapacity.boundedServingRows(
            policyCeiling ?? .max, physicalMemoryBytes: physicalMemoryBytes
        )
        let configured = ProviderCapacity.servedSlotCount(maxConcurrencyOverride: configuredSlots)
        if source == .owner {
            // The pin itself stays as written: a warm swap to another model
            // applies that model's own ceiling (`grantableRows`).
            let pinned = min(configured, ceiling)
            return Plan(rows: pinned, initialServed: pinned, ownerPinned: configured, reason: "owner_pinned")
        }
        if draftConfigured {
            return Plan(rows: 1, initialServed: 1, ownerPinned: nil, reason: "draft_model")
        }
        if emergencyOff {
            return Plan(rows: 1, initialServed: 1, ownerPinned: nil, reason: "emergency_off")
        }
        let recommended = min(max(1, recommendedSlots()), ProviderCapacity.maxConcurrencyOverrideLimit, ceiling)
        if provisionalPolicyEntry {
            // SPEC-023-R009: never above a computable memory fit; without one
            // the configured count already served keeps its rows.
            let rows = memoryFitKnown ? recommended : min(max(recommended, configured), ceiling)
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
        // Convert only representable positive GiB values; unknown/overflowing
        // memory preserves the ordinary hard cap rather than wrapping to 8 GiB.
        let memoryBytes = UInt64(exactly: memoryGB).flatMap { gib -> UInt64? in
            let bytes = gib.multipliedReportingOverflow(by: 1_073_741_824)
            return bytes.overflow ? nil : bytes.partialValue
        } ?? 0
        return ProviderCapacity.boundedServingRows(slots, physicalMemoryBytes: memoryBytes)
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

    /// SPEC-038 FR-CB11 (v0.3.22): the signed `max_served_slots` for the
    /// served model key; nil without a verified policy or without one.
    static func policyServedSlotCeiling(
        _ policy: ContinuousBatchingPolicyLoadResult,
        modelKeys: Set<String>
    ) -> Int? {
        guard policy.status == .liveVerified else { return nil }
        return policy.selection.servedSlotCeiling(modelKeys: modelKeys)
    }
}

extension AutoServedSlots {
    /// `AutotuneModelContextCap.memoryFitBatchDepth` at the served context for
    /// the configured artifact. Uncatalogued models require an explicitly
    /// verified binding and actual artifact bytes; unknown geometry stays nil.
    static func memoryFitSlots(
        configJSONData: Data?,
        memoryGB: Int,
        catalogMinRAMGB: Int?,
        contextTokens: Int,
        weightsBytes: UInt64?,
        verifiedArtifactBinding: Bool = false
    ) -> Int? {
        guard let configJSONData else { return nil }
        let artifactBytes = weightsBytes.flatMap {
            $0 > 0 && $0 <= UInt64(Int.max) ? Int($0) : nil
        }
        guard catalogMinRAMGB != nil || (verifiedArtifactBinding && artifactBytes != nil) else {
            return nil
        }
        return AutotuneModelContextCap.memoryFitBatchDepth(
            configData: configJSONData,
            verifiedConfigSHA256: SHA256.hash(data: configJSONData).map { String(format: "%02x", $0) }.joined(),
            hardwareMemoryGB: memoryGB,
            // Actual verified bytes take precedence over this catalog fallback.
            catalogMinRAMGB: catalogMinRAMGB ?? 1,
            calibrationContextTokens: contextTokens,
            verifiedArtifactSizeBytes: artifactBytes
        )
    }
}
