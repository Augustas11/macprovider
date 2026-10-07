import Foundation

public enum NativeMTPStatusReason: String, CaseIterable, Sendable, Equatable {
    case active
    case disabledByDefault = "disabled_by_default"
    case tupleNotAdmitted = "tuple_not_admitted"
    case tupleRevoked = "tuple_revoked"
    case revocationStateUnavailable = "revocation_state_unavailable"
    case requestIneligible = "request_ineligible"
    case unsupportedCacheState = "unsupported_cache_state"
    case capacityUnavailable = "capacity_unavailable"
    case capacityAboveNativeBound = "capacity_above_native_bound"
    case lowAcceptanceDepthZero = "low_acceptance_depth_zero"
    case runtimeFailure = "runtime_failure"
    case warmSwap = "warm_swap"
}

public enum NativeMTPStatusMode: String, Sendable, Equatable {
    case off
    case eligible
    case active
    case degradedDepthZero = "degraded_depth_zero"
}

public struct NativeMTPStatusSnapshot: Sendable, Equatable {
    static let capability = "native_mtp_status_v1"
    static let maximumProposalDepth = 16
    static let closedFieldNames: Set<String> = [
        "supported",
        "enabled",
        "mode",
        "family",
        "proposal_depth",
        "requests_since_reset",
        "proposed_tokens",
        "accepted_tokens",
        "rejected_tokens",
        "bonus_tokens",
        "committed_tokens",
        "target_forwards",
        "mtp_forwards",
        "preoutput_fallbacks",
        "postoutput_failures",
        "capacity_rejections",
        "accepted_by_position",
        "mean_accepted_length",
        "verification_overhead_ms",
        "throughput_delta_ppm",
        "reset_generation",
        "last_reason",
    ]

    let supported: Bool
    let enabled: Bool
    let mode: NativeMTPStatusMode
    let family: String
    let proposalDepth: Int
    let requestsSinceReset: UInt64
    let proposedTokens: UInt64
    let acceptedTokens: UInt64
    let rejectedTokens: UInt64
    let bonusTokens: UInt64
    let committedTokens: UInt64
    let targetForwards: UInt64
    let mtpForwards: UInt64
    let preoutputFallbacks: UInt64
    let postoutputFailures: UInt64
    let capacityRejections: UInt64
    let acceptedByPosition: [UInt64]
    let verificationOverheadMS: UInt64
    let throughputDeltaPPM: Int
    let resetGeneration: UInt64
    let lastReason: NativeMTPStatusReason

    var meanAcceptedLength: Double {
        Double(acceptedTokens) / Double(max(UInt64(1), mtpForwards))
    }

    public func statusObject() -> [String: Any] {
        [
            "supported": supported,
            "enabled": enabled,
            "mode": mode.rawValue,
            "family": family,
            "proposal_depth": proposalDepth,
            "requests_since_reset": NSNumber(value: requestsSinceReset),
            "proposed_tokens": NSNumber(value: proposedTokens),
            "accepted_tokens": NSNumber(value: acceptedTokens),
            "rejected_tokens": NSNumber(value: rejectedTokens),
            "bonus_tokens": NSNumber(value: bonusTokens),
            "committed_tokens": NSNumber(value: committedTokens),
            "target_forwards": NSNumber(value: targetForwards),
            "mtp_forwards": NSNumber(value: mtpForwards),
            "preoutput_fallbacks": NSNumber(value: preoutputFallbacks),
            "postoutput_failures": NSNumber(value: postoutputFailures),
            "capacity_rejections": NSNumber(value: capacityRejections),
            "accepted_by_position": acceptedByPosition.map { NSNumber(value: $0) },
            "mean_accepted_length": meanAcceptedLength,
            "verification_overhead_ms": NSNumber(value: verificationOverheadMS),
            "throughput_delta_ppm": throughputDeltaPPM,
            "reset_generation": NSNumber(value: resetGeneration),
            "last_reason": lastReason.rawValue,
        ]
    }

    public func metricsSamples() -> [(name: String, labels: [String: String], value: UInt64)] {
        var samples: [(String, [String: String], UInt64)] = [
            ("native_mtp_requests_since_reset", ["last_reason": lastReason.rawValue], requestsSinceReset),
            ("native_mtp_proposed_tokens", [:], proposedTokens),
            ("native_mtp_accepted_tokens", [:], acceptedTokens),
            ("native_mtp_rejected_tokens", [:], rejectedTokens),
            ("native_mtp_bonus_tokens", [:], bonusTokens),
            ("native_mtp_committed_tokens", [:], committedTokens),
            ("native_mtp_target_forwards", [:], targetForwards),
            ("native_mtp_mtp_forwards", [:], mtpForwards),
            ("native_mtp_preoutput_fallbacks", [:], preoutputFallbacks),
            ("native_mtp_postoutput_failures", [:], postoutputFailures),
            ("native_mtp_capacity_rejections", [:], capacityRejections),
            ("native_mtp_verification_overhead_ms", [:], verificationOverheadMS),
        ]
        for (position, value) in acceptedByPosition.enumerated() {
            samples.append(("native_mtp_accepted_by_position", ["position": String(position)], value))
        }
        return samples
    }

    static func familyLabel(_ raw: String?) -> String {
        let lowered = (raw ?? "unknown").lowercased()
        let bytes = Array(lowered.utf8)
        guard let first = bytes.first,
              ((48...57).contains(first) || (97...122).contains(first)),
              bytes.count <= 64,
              bytes.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 46 || byte == 95 || byte == 45
              })
        else {
            return "unknown"
        }
        return lowered
    }
}

final class NativeMTPStatusSink: @unchecked Sendable, Equatable {
    struct Round: Sendable, Equatable {
        let requestedDepths: [Int]
        let proposedTokens: Int
        let acceptedTokens: Int
        let bonusTokens: Int
        let committedTokens: Int
        let acceptedProposalTokensByRow: [Int]
        let verificationOverheadMS: UInt64
    }

    private struct Counters: Equatable {
        var requestsSinceReset: UInt64 = 0
        var proposedTokens: UInt64 = 0
        var acceptedTokens: UInt64 = 0
        var rejectedTokens: UInt64 = 0
        var bonusTokens: UInt64 = 0
        var committedTokens: UInt64 = 0
        var targetForwards: UInt64 = 0
        var mtpForwards: UInt64 = 0
        var preoutputFallbacks: UInt64 = 0
        var postoutputFailures: UInt64 = 0
        var capacityRejections: UInt64 = 0
        var acceptedByPosition: [UInt64]
        var verificationOverheadMS: UInt64 = 0

        init(proposalDepth: Int) {
            acceptedByPosition = Array(repeating: 0, count: proposalDepth)
        }
    }

    private let lock = NSLock()
    private var supported: Bool
    private var configuredEnabled: Bool
    private var family: String
    private var proposalDepth: Int
    private var throughputDeltaPPM: Int
    private var resetGeneration: UInt64
    private var counters: Counters
    private var activeNativeRows = 0
    private var activeRowsAllDepthZero = false
    private var disabledBySaturation = false
    private var lastReason: NativeMTPStatusReason

    init(
        supported: Bool,
        enabled: Bool,
        family: String?,
        proposalDepth: Int,
        throughputDeltaPPM: Int,
        resetGeneration: UInt64,
        lastReason: NativeMTPStatusReason
    ) {
        let boundedDepth = min(max(0, proposalDepth), NativeMTPStatusSnapshot.maximumProposalDepth)
        self.supported = supported
        self.configuredEnabled = enabled && boundedDepth > 0
        self.family = NativeMTPStatusSnapshot.familyLabel(family)
        self.proposalDepth = boundedDepth
        self.throughputDeltaPPM = throughputDeltaPPM
        self.resetGeneration = resetGeneration
        self.lastReason = lastReason
        self.counters = Counters(proposalDepth: boundedDepth)
    }

    static func == (lhs: NativeMTPStatusSink, rhs: NativeMTPStatusSink) -> Bool {
        lhs === rhs
    }

    static func disabled(resetGeneration: UInt64 = 0, reason: NativeMTPStatusReason = .disabledByDefault) -> NativeMTPStatusSink {
        NativeMTPStatusSink(
            supported: false,
            enabled: false,
            family: nil,
            proposalDepth: 0,
            throughputDeltaPPM: 0,
            resetGeneration: resetGeneration,
            lastReason: reason
        )
    }

    /// Takes over `other`'s configuration and counters in place. A running
    /// scheduler holds this instance in its configuration, so the runtime
    /// re-publishes status into it (tuple admitted after the self-test,
    /// disabled, warm swap) instead of replacing it: a replaced sink would
    /// leave the scheduler recording into an object status never reads.
    func adopt(_ other: NativeMTPStatusSink) {
        guard other !== self else { return }
        let state = other.lock.withLock {
            (other.supported, other.configuredEnabled, other.family, other.proposalDepth,
             other.throughputDeltaPPM, other.resetGeneration, other.counters,
             other.disabledBySaturation, other.lastReason)
        }
        lock.withLock {
            supported = state.0
            configuredEnabled = state.1
            family = state.2
            proposalDepth = state.3
            throughputDeltaPPM = state.4
            resetGeneration = state.5
            counters = state.6
            disabledBySaturation = state.7
            lastReason = state.8
            activeNativeRows = 0
            activeRowsAllDepthZero = false
        }
    }

    func beginRound(requestedDepths: [Int]) {
        lock.withLock {
            activeNativeRows = requestedDepths.count
            activeRowsAllDepthZero = !requestedDepths.isEmpty && requestedDepths.allSatisfy { $0 == 0 }
        }
    }

    func endRound() {
        lock.withLock {
            activeNativeRows = 0
            activeRowsAllDepthZero = false
        }
    }

    func recordNativeMTPAdmission(rowCount: Int = 1) {
        guard rowCount > 0 else { return }
        lock.withLock {
            guard !disabledBySaturation else { return }
            add(UInt64(rowCount), to: \.requestsSinceReset)
        }
    }

    func recordRound(_ round: Round) {
        lock.withLock {
            guard !disabledBySaturation else { return }
            let rejected = max(0, round.proposedTokens - round.acceptedTokens)
            add(UInt64(max(0, round.proposedTokens)), to: \.proposedTokens)
            add(UInt64(max(0, round.acceptedTokens)), to: \.acceptedTokens)
            add(UInt64(rejected), to: \.rejectedTokens)
            add(UInt64(max(0, round.bonusTokens)), to: \.bonusTokens)
            add(UInt64(max(0, round.committedTokens)), to: \.committedTokens)
            add(1, to: \.targetForwards)
            add(1, to: \.mtpForwards)
            add(round.verificationOverheadMS, to: \.verificationOverheadMS)
            for rowAcceptedTokens in round.acceptedProposalTokensByRow {
                let acceptedPositions = min(max(0, rowAcceptedTokens), counters.acceptedByPosition.count)
                for position in 0..<acceptedPositions {
                    addAcceptedPosition(position)
                }
            }
            lastReason = .active
        }
    }

    func recordCapacityRejection() {
        lock.withLock {
            add(1, to: \.capacityRejections)
            lastReason = disabledBySaturation ? .runtimeFailure : .capacityUnavailable
        }
    }

    func recordPreoutputFallback(_ reason: NativeMTPStatusReason = .requestIneligible) {
        lock.withLock {
            add(1, to: \.preoutputFallbacks)
            lastReason = disabledBySaturation ? .runtimeFailure : reason
        }
    }

    func recordReason(_ reason: NativeMTPStatusReason) {
        lock.withLock {
            if !disabledBySaturation {
                lastReason = reason
            }
        }
    }

    func recordPostoutputFailure() {
        lock.withLock {
            add(1, to: \.postoutputFailures)
            lastReason = .runtimeFailure
        }
    }

    func snapshot() -> NativeMTPStatusSnapshot {
        lock.withLock {
            let enabled = configuredEnabled && !disabledBySaturation
            let mode: NativeMTPStatusMode
            if !enabled {
                mode = .off
            } else if activeNativeRows > 0 {
                mode = activeRowsAllDepthZero ? .degradedDepthZero : .active
            } else {
                mode = .eligible
            }
            return NativeMTPStatusSnapshot(
                supported: supported,
                enabled: enabled,
                mode: mode,
                family: family,
                proposalDepth: proposalDepth,
                requestsSinceReset: counters.requestsSinceReset,
                proposedTokens: counters.proposedTokens,
                acceptedTokens: counters.acceptedTokens,
                rejectedTokens: counters.rejectedTokens,
                bonusTokens: counters.bonusTokens,
                committedTokens: counters.committedTokens,
                targetForwards: counters.targetForwards,
                mtpForwards: counters.mtpForwards,
                preoutputFallbacks: counters.preoutputFallbacks,
                postoutputFailures: counters.postoutputFailures,
                capacityRejections: counters.capacityRejections,
                acceptedByPosition: counters.acceptedByPosition,
                verificationOverheadMS: counters.verificationOverheadMS,
                throughputDeltaPPM: throughputDeltaPPM,
                resetGeneration: resetGeneration,
                lastReason: disabledBySaturation ? .runtimeFailure : lastReason
            )
        }
    }

    private func add(_ value: UInt64, to keyPath: WritableKeyPath<Counters, UInt64>) {
        let (sum, overflow) = counters[keyPath: keyPath].addingReportingOverflow(value)
        if overflow {
            counters[keyPath: keyPath] = UInt64.max
            disableForSaturation()
        } else {
            counters[keyPath: keyPath] = sum
        }
    }

    private func addAcceptedPosition(_ position: Int) {
        guard counters.acceptedByPosition.indices.contains(position) else { return }
        let (sum, overflow) = counters.acceptedByPosition[position].addingReportingOverflow(1)
        if overflow {
            counters.acceptedByPosition[position] = UInt64.max
            disableForSaturation()
        } else {
            counters.acceptedByPosition[position] = sum
        }
    }

    private func disableForSaturation() {
        disabledBySaturation = true
        lastReason = .runtimeFailure
        activeNativeRows = 0
        activeRowsAllDepthZero = false
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
