#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPPhaseTimingTests: XCTestCase {
    func testRecorderAggregatesOnlyMetadataWithExplicitNestedIntervals() throws {
        let recorder = NativeMTPPhaseTimingRecorder()
        let start = NativeMTPPhaseTimingRecorder.Stamp(nanoseconds: 100)
        let graphFinished = NativeMTPPhaseTimingRecorder.Stamp(nanoseconds: 140)
        let finished = NativeMTPPhaseTimingRecorder.Stamp(nanoseconds: 200)

        recorder.recordProposalPreparation(
            activeRows: 4,
            started: start,
            finished: graphFinished,
            proposedTokens: 4
        )
        recorder.recordPackedTargetVerification(
            activeRows: 4,
            started: start,
            graphFinished: graphFinished,
            finished: finished
        )
        recorder.recordAcceptedTokens(activeRows: 4, count: 7)
        recorder.recordCommittedTokens(activeRows: 4, count: 3)
        recorder.recordFinalizeMutation(
            activeRows: 4,
            started: start,
            drafterFinished: graphFinished,
            finished: finished
        )
        recorder.recordOrdinaryDecodeEvalReadback(
            activeRows: 4,
            started: start,
            finished: finished
        )

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.schemaVersion, "macprovider.native_mtp_phase_timing.v1")
        XCTAssertEqual(snapshot.intervalSemantics, "nested_inclusive")
        let bucket = try XCTUnwrap(snapshot.buckets.first)
        XCTAssertEqual(bucket.activeRows, 4)
        XCTAssertEqual(bucket.nativeRounds, 1)
        XCTAssertEqual(bucket.ordinaryBatches, 1)
        XCTAssertEqual(bucket.proposedTokens, 4)
        XCTAssertEqual(bucket.acceptedTokens, 7)
        XCTAssertEqual(bucket.committedTokens, 3)
        XCTAssertEqual(bucket.packedTargetVerifyGraphNanoseconds, 40)
        XCTAssertEqual(bucket.packedTargetMaterializationReadbackNanoseconds, 60)
        XCTAssertEqual(bucket.packedTargetVerifyInclusiveNanoseconds, 100)
        XCTAssertEqual(bucket.drafterAdvanceNanoseconds, 40)
        XCTAssertEqual(bucket.targetCacheCommitEvalNanoseconds, 60)
        XCTAssertEqual(bucket.finalizeMutationInclusiveNanoseconds, 100)
        XCTAssertEqual(
            bucket.packedTargetVerifyInclusiveNanoseconds,
            bucket.packedTargetVerifyGraphNanoseconds
                + bucket.packedTargetMaterializationReadbackNanoseconds
        )
        XCTAssertEqual(
            bucket.finalizeMutationInclusiveNanoseconds,
            bucket.drafterAdvanceNanoseconds + bucket.targetCacheCommitEvalNanoseconds
        )
    }

    func testRecorderBoundsBucketsAndDropsNegativeCounts() {
        let recorder = NativeMTPPhaseTimingRecorder()
        let stamp = NativeMTPPhaseTimingRecorder.Stamp(nanoseconds: 0)

        recorder.recordProposalPreparation(
            activeRows: 0,
            started: stamp,
            finished: stamp,
            proposedTokens: -1
        )
        recorder.recordAcceptedTokens(activeRows: 12, count: -3)
        recorder.recordCommittedTokens(activeRows: 12, count: -5)

        let buckets = recorder.snapshot().buckets
        XCTAssertEqual(buckets.map(\.activeRows), [1, 8])
        XCTAssertEqual(buckets[0].proposedTokens, 0)
        XCTAssertEqual(buckets[1].acceptedTokens, 0)
        XCTAssertEqual(buckets[1].committedTokens, 0)
    }

    func testSnapshotEncodingHasAggregatePrivacyKeyShape() throws {
        let recorder = NativeMTPPhaseTimingRecorder()
        let stamp = NativeMTPPhaseTimingRecorder.Stamp(nanoseconds: 0)
        recorder.recordProposalPreparation(
            activeRows: 2,
            started: stamp,
            finished: stamp,
            proposedTokens: 1
        )

        let encoded = try JSONEncoder().encode(recorder.snapshot())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(root.keys), Set(["buckets", "intervalSemantics", "schemaVersion"]))
        let bucket = try XCTUnwrap((root["buckets"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(bucket.keys), Set([
            "acceptedTokens",
            "activeRows",
            "committedTokens",
            "drafterAdvanceNanoseconds",
            "finalizeMutationInclusiveNanoseconds",
            "nativeRounds",
            "ordinaryBatches",
            "ordinaryDecodeEvalReadbackNanoseconds",
            "packedTargetMaterializationReadbackNanoseconds",
            "packedTargetVerifyGraphNanoseconds",
            "packedTargetVerifyInclusiveNanoseconds",
            "proposalPreparationNanoseconds",
            "proposedTokens",
            "targetCacheCommitEvalNanoseconds",
        ]))
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("requestID"))
        XCTAssertFalse(text.contains("prompt"))
        XCTAssertFalse(text.contains("tokenID"))
    }
}
#endif
