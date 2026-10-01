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
    var hostSyncs: UInt64 = 0
    var compiledOrdinarySteps: UInt64 = 0

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
            perRowModelCallLoops: perRowModelCallLoops &- earlier.perRowModelCallLoops,
            hostSyncs: hostSyncs &- earlier.hostSyncs,
            compiledOrdinarySteps: compiledOrdinarySteps &- earlier.compiledOrdinarySteps
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
            "host_syncs": hostSyncs,
            "host_syncs_per_round": Double(hostSyncs) / divisor,
            "compiled_ordinary_steps": compiledOrdinarySteps,
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
    // Lab sub-phases inside the target forward window. Each boundary
    // synchronizes the MLX stream, so CPU graph build and GPU execution are
    // charged separately.
    case verifyPrepare = "verify_a_prepare_caches_inputs"
    case verifyGraphBuild = "verify_b_graph_build_cpu"
    case verifyForwardEval = "verify_c_forward_gpu_eval"
    case verifyCheckpointTransactions = "verify_d_checkpoint_transactions"
    case verifyTopTokens = "verify_e_top_tokens_host"
    case verifyParityTrace = "verify_e2_parity_trace_eval"
    case verifyStateStore = "verify_f_state_store"
    case ordinaryPrepare = "ordinary_a_prepare_caches_inputs"
    case ordinaryGraphBuild = "ordinary_b_graph_build_cpu"
    case ordinaryForwardEval = "ordinary_c_forward_gpu_eval"
    case ordinarySample = "ordinary_e_sample_host"
    case ordinaryWriteback = "ordinary_f_writeback"
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

    /// Synchronize the default MLX stream, charge the elapsed time since
    /// `started` to `phase`, and restart the clock.
    func lap(_ phase: NativeMTPRoundProfilePhase, _ started: inout UInt64) {
        guard Self.enabled, started > 0 else { return }
        Stream().synchronize()
        record(phase, since: started)
        started = DispatchTime.now().uptimeNanoseconds
    }

    /// Force evaluation only while profiling so the following lap measures
    /// GPU execution of an otherwise lazy graph.
    static func evalForProfile(_ arrays: [MLXArray]) {
        guard enabled, !arrays.isEmpty else { return }
        eval(arrays)
    }

    func countHostSyncs(_ count: Int) {
        guard Self.enabled, count > 0 else { return }
        lock.withLock { snapshotValue.hostSyncs &+= UInt64(count) }
    }

    func countCompiledOrdinaryStep() {
        guard Self.enabled else { return }
        lock.withLock { snapshotValue.compiledOrdinarySteps &+= 1 }
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
