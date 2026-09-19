import XCTest

@testable import macprovider_cli

/// SPEC-038 FR-CB6 batched-vs-serial "accepted numerical tolerance" unit tests.
///
/// These pin the pure conformance predicate that the MoE input-isolation probe uses to
/// decide whether a batched row's greedy token is a genuine own-distribution numerical tie
/// (conformant) or a divergence/leak (fail). They run without a model, and the leak cases
/// prove that admitting numerical ties never admits a cross-row leak.
final class PagedKVBatchedToleranceTests: XCTestCase {
    /// Build a reference with an explicit logit at each of top1/top2 (vocab padded with a
    /// clearly-lower floor so unrelated tokens are never near-ties).
    private func reference(top1: Int, top1Logit: Float, top2: Int, top2Logit: Float, vocab: Int = 128)
        -> PagedKVRuntimeParityProbe.SerialReference
    {
        var logits = [Float](repeating: -50.0, count: vocab)
        logits[top1] = top1Logit
        logits[top2] = top2Logit
        return PagedKVRuntimeParityProbe.SerialReference(top1: top1, top2: top2, logits: logits)
    }

    private func conformant(_ decoded: Int, _ ref: PagedKVRuntimeParityProbe.SerialReference, other: Int?, tol: Float = 1.0) -> Bool {
        PagedKVRuntimeParityProbe.batchedTokenIsConformant(
            decoded: decoded, own: ref, otherRowSerialTop1: other, tolerance: tol
        )
    }

    func testExactSerialArgmaxIsConformant() {
        let r = reference(top1: 5, top1Logit: 10.0, top2: 9, top2Logit: 9.75)
        XCTAssertTrue(conformant(5, r, other: 42))
    }

    func testOwnRunnerUpWithinToleranceIsConformant() {
        // gap 0.25 <= 1.0 tolerance — the observed live Qwen3-Coder near-tie logit values
        // (17.625 vs 17.375), with token IDs mapped into the test vocab.
        let r = reference(top1: 5, top1Logit: 17.625, top2: 9, top2Logit: 17.375)
        XCTAssertTrue(conformant(9, r, other: 42))
    }

    func testOwnRunnerUpBeyondToleranceDiverges() {
        // gap 2.5 > 1.0 tolerance — the batched forward strayed too far from the row's own
        // distribution to be a numerical tie; must count as a divergence.
        let r = reference(top1: 5, top1Logit: 10.0, top2: 9, top2Logit: 7.5)
        XCTAssertFalse(conformant(9, r, other: 42))
    }

    func testOtherRowTokenIsLeakEvenWhenAlsoOwnRunnerUpWithinTolerance() {
        // Worst case: the other row's serial argmax (42) is ALSO this row's runner-up within
        // tolerance. The explicit leak guard must still reject it — admitting ties must never
        // admit a cross-row leak.
        let r = reference(top1: 5, top1Logit: 10.0, top2: 42, top2Logit: 9.75)
        XCTAssertFalse(conformant(42, r, other: 42))
    }

    func testTokenOutsideOwnTopTwoDiverges() {
        // A token that is neither the row's argmax nor its runner-up is never a tie.
        let r = reference(top1: 5, top1Logit: 10.0, top2: 9, top2Logit: 9.75)
        XCTAssertFalse(conformant(77, r, other: 42))
    }

    func testZeroToleranceStillAdmitsExactMatchButRejectsAnyGap() {
        let r = reference(top1: 5, top1Logit: 10.0, top2: 9, top2Logit: 9.9999)
        XCTAssertTrue(conformant(5, r, other: 42, tol: 0.0))
        XCTAssertFalse(conformant(9, r, other: 42, tol: 0.0))
    }
}
