#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation

/// Lab-only aggregate timings for the existing continuous-batching paths.
///
/// The recorder intentionally retains neither requests nor token values. All
/// durations are monotonic intervals from one invocation. The `inclusive`
/// fields contain their named nested phase fields; consumers must not add the
/// nested values to an inclusive value.
final class NativeMTPPhaseTimingRecorder: @unchecked Sendable {
    struct Stamp: Sendable {
        fileprivate let nanoseconds: UInt64

        init(nanoseconds: UInt64) {
            self.nanoseconds = nanoseconds
        }
    }

    struct Bucket: Codable, Equatable, Sendable {
        let activeRows: Int
        var nativeRounds = 0
        var ordinaryBatches = 0
        /// Drafter proposal plus scheduler construction of verify inputs.
        var proposalPreparationNanoseconds: UInt64 = 0
        /// Target graph construction before the first host materialization.
        var packedTargetVerifyGraphNanoseconds: UInt64 = 0
        /// Includes graph construction and host materialization/readback.
        var packedTargetVerifyInclusiveNanoseconds: UInt64 = 0
        /// Host materialization/readback tail; nested in verify inclusive.
        var packedTargetMaterializationReadbackNanoseconds: UInt64 = 0
        var drafterAdvanceNanoseconds: UInt64 = 0
        /// Includes staging graph construction and its one existing eval.
        var targetCacheCommitEvalNanoseconds: UInt64 = 0
        /// Includes drafter advance and target-cache commit/eval.
        var finalizeMutationInclusiveNanoseconds: UInt64 = 0
        /// Existing ordinary decode call, including its existing eval/readback.
        var ordinaryDecodeEvalReadbackNanoseconds: UInt64 = 0
        var proposedTokens = 0
        /// Buyer-visible candidates selected after packed target verification.
        var acceptedTokens = 0
        /// Accepted drafter proposal tokens successfully made durable.
        var committedTokens = 0
    }

    struct Snapshot: Codable, Equatable, Sendable {
        let schemaVersion = "macprovider.native_mtp_phase_timing.v1"
        /// Inclusive fields contain nested fields and must not be summed.
        let intervalSemantics = "nested_inclusive"
        let buckets: [Bucket]
    }

    private let lock = NSLock()
    private var buckets: [Int: Bucket] = [:]

    func stamp() -> Stamp { Stamp(nanoseconds: DispatchTime.now().uptimeNanoseconds) }

    func recordProposalPreparation(
        activeRows: Int,
        started: Stamp,
        finished: Stamp,
        proposedTokens: Int
    ) {
        mutate(activeRows) { bucket in
            bucket.nativeRounds += 1
            bucket.proposalPreparationNanoseconds &+= Self.elapsed(started, finished)
            bucket.proposedTokens += max(0, proposedTokens)
        }
    }

    /// Adds backend-side target-input preparation to the scheduler's proposal
    /// preparation interval without counting another native round.
    func recordTargetVerifyPreparation(activeRows: Int, started: Stamp, finished: Stamp) {
        mutate(activeRows) { bucket in
            bucket.proposalPreparationNanoseconds &+= Self.elapsed(started, finished)
        }
    }

    func recordPackedTargetVerification(
        activeRows: Int,
        started: Stamp,
        graphFinished: Stamp,
        finished: Stamp
    ) {
        mutate(activeRows) { bucket in
            bucket.packedTargetVerifyGraphNanoseconds &+= Self.elapsed(started, graphFinished)
            bucket.packedTargetMaterializationReadbackNanoseconds &+= Self.elapsed(graphFinished, finished)
            bucket.packedTargetVerifyInclusiveNanoseconds &+= Self.elapsed(started, finished)
        }
    }

    func recordAcceptedTokens(activeRows: Int, count: Int) {
        mutate(activeRows) { $0.acceptedTokens += max(0, count) }
    }

    func recordCommittedTokens(activeRows: Int, count: Int) {
        mutate(activeRows) { $0.committedTokens += max(0, count) }
    }

    func recordFinalizeMutation(
        activeRows: Int,
        started: Stamp,
        drafterFinished: Stamp,
        finished: Stamp
    ) {
        mutate(activeRows) { bucket in
            bucket.drafterAdvanceNanoseconds &+= Self.elapsed(started, drafterFinished)
            bucket.targetCacheCommitEvalNanoseconds &+= Self.elapsed(drafterFinished, finished)
            bucket.finalizeMutationInclusiveNanoseconds &+= Self.elapsed(started, finished)
        }
    }

    /// The scheduler brackets its already-existing ordinary decode call.
    func recordOrdinaryDecodeEvalReadback(activeRows: Int, started: Stamp, finished: Stamp) {
        mutate(activeRows) { bucket in
            bucket.ordinaryBatches += 1
            bucket.ordinaryDecodeEvalReadbackNanoseconds &+= Self.elapsed(started, finished)
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(buckets: buckets.values.sorted { $0.activeRows < $1.activeRows })
    }

    private func mutate(_ activeRows: Int, _ body: (inout Bucket) -> Void) {
        let rows = min(8, max(1, activeRows))
        lock.lock()
        var bucket = buckets[rows] ?? Bucket(activeRows: rows)
        body(&bucket)
        buckets[rows] = bucket
        lock.unlock()
    }

    private static func elapsed(_ started: Stamp, _ finished: Stamp) -> UInt64 {
        finished.nanoseconds >= started.nanoseconds ? finished.nanoseconds - started.nanoseconds : 0
    }
}
#endif
