#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MLX

struct NativeMTPRoundProfileSnapshot: Sendable, Equatable {
    var phaseNanoseconds: [String: UInt64]
    var roundCount: UInt64
    var rows: UInt64
    var proposals: UInt64
    var targetForwardCalls: UInt64
    var drafterForwardCalls: UInt64
    var perRowModelCallLoops: UInt64

    static let zero = NativeMTPRoundProfileSnapshot(
        phaseNanoseconds: [:],
        roundCount: 0,
        rows: 0,
        proposals: 0,
        targetForwardCalls: 0,
        drafterForwardCalls: 0,
        perRowModelCallLoops: 0
    )

    func delta(since earlier: Self) -> Self {
        let phaseKeys = Set(phaseNanoseconds.keys).union(earlier.phaseNanoseconds.keys)
        return NativeMTPRoundProfileSnapshot(
            phaseNanoseconds: Dictionary(uniqueKeysWithValues: phaseKeys.map { key in
                (key, phaseNanoseconds[key, default: 0] &- earlier.phaseNanoseconds[key, default: 0])
            }),
            roundCount: roundCount &- earlier.roundCount,
            rows: rows &- earlier.rows,
            proposals: proposals &- earlier.proposals,
            targetForwardCalls: targetForwardCalls &- earlier.targetForwardCalls,
            drafterForwardCalls: drafterForwardCalls &- earlier.drafterForwardCalls,
            perRowModelCallLoops: perRowModelCallLoops &- earlier.perRowModelCallLoops
        )
    }

    var record: [String: Any] {
        let divisor = Double(max(1, roundCount))
        let totals = Dictionary(uniqueKeysWithValues: NativeMTPRoundProfilePhase.allCases.map { phase in
            (phase.rawValue, Double(phaseNanoseconds[phase.rawValue, default: 0]) / 1_000_000.0)
        })
        return [
            "phase_total_ms": totals,
            "phase_mean_ms_per_round": totals.mapValues { $0 / divisor },
            "round_count": roundCount,
            "rows": rows,
            "proposals": proposals,
            "target_forward_calls": targetForwardCalls,
            "drafter_forward_calls": drafterForwardCalls,
            "per_row_model_call_loops": perRowModelCallLoops,
        ]
    }
}

enum NativeMTPRoundProfilePhase: String, CaseIterable, Sendable {
    case reservationCheckpointStage = "reservation_checkpoint_stage"
    case drafterProposalForward = "drafter_proposal_forward"
    case targetVerificationForward = "packed_target_verification_forward"
    case acceptanceCommit = "acceptance_commit"
    case finalizeRelease = "finalize_release"
    case tokenDelivery = "token_delivery"
}

final class NativeMTPRoundProfileCollector: @unchecked Sendable {
    static let shared = NativeMTPRoundProfileCollector()
    static let enabled = ProcessInfo.processInfo.environment["MACPROVIDER_NATIVE_MTP_PROFILE"] == "1"

    private let lock = NSLock()
    private var snapshotValue = NativeMTPRoundProfileSnapshot.zero

    private init() {}

    static func start() -> UInt64 {
        enabled ? DispatchTime.now().uptimeNanoseconds : 0
    }

    static func synchronizeMLXBoundary() {
        guard enabled else { return }
        Stream().synchronize()
    }

    func record(_ phase: NativeMTPRoundProfilePhase, since started: UInt64) {
        guard Self.enabled, started > 0 else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        lock.withLock {
            snapshotValue.phaseNanoseconds[phase.rawValue, default: 0] &+= elapsed
        }
    }

    func recordRound(rows: Int, proposals: Int, targetForwardCalls: Int) {
        guard Self.enabled else { return }
        lock.withLock {
            snapshotValue.roundCount &+= 1
            snapshotValue.rows &+= UInt64(clamping: max(0, rows))
            snapshotValue.proposals &+= UInt64(clamping: max(0, proposals))
            snapshotValue.targetForwardCalls &+= UInt64(clamping: max(0, targetForwardCalls))
        }
    }

    func recordDrafterForward(perRowModelCall: Bool) {
        guard Self.enabled else { return }
        lock.withLock {
            snapshotValue.drafterForwardCalls &+= 1
            if perRowModelCall {
                snapshotValue.perRowModelCallLoops &+= 1
            }
        }
    }

    func snapshot() -> NativeMTPRoundProfileSnapshot {
        lock.withLock { snapshotValue }
    }
}
#endif
