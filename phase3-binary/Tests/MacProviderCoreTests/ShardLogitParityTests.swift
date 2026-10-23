import XCTest
@testable import MacProviderCore

/// Issue #2084: teacher-forced tolerance parity (logit summaries, their frame
/// payload, and the per-step comparison).
final class ShardLogitParityTests: XCTestCase {
    private func summary(_ tokens: [Int32], _ logprobs: [Float], lse: Float = 3.5) -> ShardLogitSummary {
        ShardLogitSummary(topTokens: tokens, topLogprobs: logprobs, logSumExp: lse)
    }

    func testCodecRoundTripsAndDecodesStrictly() throws {
        let original = summary([7, 9, 11], [-0.2, -1.5, -3])
        let encoded = try ShardLogitSummaryCodec.encode(token: 7, summary: original)
        XCTAssertEqual(encoded.shape, [8])
        XCTAssertEqual(encoded.payload.count, 32)
        let decoded = try ShardLogitSummaryCodec.decode(shape: encoded.shape, payload: encoded.payload)
        XCTAssertEqual(decoded.token, 7)
        XCTAssertEqual(decoded.summary, original)

        XCTAssertThrowsError(try ShardLogitSummaryCodec.decode(shape: [7], payload: Data(count: 28))) { error in
            XCTAssertEqual(error as? ShardLogitSummaryError, .badShape([7]))
        }
        XCTAssertThrowsError(try ShardLogitSummaryCodec.decode(shape: [8], payload: Data(count: 28))) { error in
            XCTAssertEqual(error as? ShardLogitSummaryError, .lengthMismatch(expected: 32, actual: 28))
        }
        XCTAssertThrowsError(try ShardLogitSummaryCodec.encode(token: 1, summary: summary([1, 2], [-2, -1]))) { error in
            XCTAssertEqual(error as? ShardLogitSummaryError, .notDescending)
        }
        XCTAssertThrowsError(try ShardLogitSummaryCodec.encode(token: 1, summary: summary([1], [.nan]))) { error in
            XCTAssertEqual(error as? ShardLogitSummaryError, .nonFinite)
        }
        XCTAssertThrowsError(try ShardLogitSummaryCodec.encode(token: 1, summary: summary([], [])))
    }

    func testTokenLogitsFrameIsStrictlyShaped() throws {
        let encoded = try ShardLogitSummaryCodec.encode(token: 7, summary: summary([7, 9], [-0.1, -2]))
        let frame = ShardStageFrame(
            header: ShardStageFrameHeader(kind: .tokenLogits, dtype: .int32, groupEpoch: 1, shape: encoded.shape),
            payload: encoded.payload)
        XCTAssertEqual(try ShardStageFrameCodec.decode(try ShardStageFrameCodec.encode(frame)), frame)
        var odd = frame
        odd.header.shape = [5]
        odd.payload = Data(count: 20)
        XCTAssertThrowsError(try ShardStageFrameCodec.encode(odd))
        var float = frame
        float.header.dtype = .float32
        XCTAssertThrowsError(try ShardStageFrameCodec.encode(float)) { error in
            XCTAssertEqual(error as? ShardFrameError, .kindDTypeMismatch(kind: .tokenLogits, dtype: .float32))
        }
    }

    func testIdenticalSummariesPass() throws {
        let steps = [summary([4, 5, 6], [-0.1, -2, -3]), summary([8, 4, 2], [-0.5, -1, -4])]
        let parity = try ShardLogitParity.compare(reference: [steps], sharded: [steps])
        XCTAssertEqual(parity.verdict, "pass")
        XCTAssertEqual(parity.steps, 2)
        XCTAssertEqual(parity.top1AgreementRate, 1)
        XCTAssertEqual(parity.maxAbsDeltaLogprob, 0)
        XCTAssertEqual(parity.meanTopKOverlap, 1)
        XCTAssertEqual(parity.minReferenceMargin, 0.5, accuracy: 1e-6)
    }

    func testNearTieFlipIsCountedAndPasses() throws {
        // Reference: 8108 just ahead of 1935 (margin 0.02 nats); sharded: the other way.
        let reference = [summary([3, 1], [-0.1, -2]), summary([8108, 1935, 12], [-0.70, -0.72, -3])]
        let sharded = [summary([3, 1], [-0.1, -2]), summary([1935, 8108, 12], [-0.70, -0.73, -3])]
        let parity = try ShardLogitParity.compare(reference: [reference], sharded: [sharded])
        XCTAssertEqual(parity.verdict, "pass")
        XCTAssertEqual(parity.nearTieFlips, 1)
        XCTAssertEqual(parity.top1AgreementRate, 0.5)
        XCTAssertTrue(parity.hardFailures.isEmpty)
        XCTAssertEqual(parity.maxAbsDeltaLogprob, 0.03, accuracy: 1e-5)
    }

    func testFlipAboveTheTieMarginOrOutsideTop2IsAHardFailure() throws {
        let reference = [summary([3, 1, 2], [-0.1, -0.3, -3]), summary([5, 6, 7], [-0.70, -0.71, -0.72])]
        let sharded = [summary([1, 3, 2], [-0.2, -0.25, -3]), summary([7, 5, 6], [-0.70, -0.71, -0.72])]
        let parity = try ShardLogitParity.compare(reference: [reference], sharded: [sharded])
        XCTAssertEqual(parity.verdict, "fail")
        XCTAssertEqual(parity.hardFailures.map(\.step), [0, 1], "margin 0.2 is no tie; a top-3 token is not the top-2")
        XCTAssertEqual(parity.hardFailures[0].referenceToken, 3)
        XCTAssertEqual(parity.hardFailures[0].shardedToken, 1)
        XCTAssertEqual(parity.hardFailures[0].referenceMargin, 0.2, accuracy: 1e-6)
    }

    func testLogprobDriftBeyondToleranceFailsEvenWithAgreement() throws {
        let reference = [summary([3, 1], [-0.1, -2])]
        let sharded = [summary([3, 1], [-0.35, -2])]
        let parity = try ShardLogitParity.compare(reference: [reference], sharded: [sharded], logprobTolerance: 0.1)
        XCTAssertEqual(parity.verdict, "fail")
        XCTAssertTrue(parity.hardFailures.isEmpty)
        XCTAssertEqual(parity.p99AbsDeltaLogprob, 0.25, accuracy: 1e-6)
    }

    func testReferenceTokenOutsideShardedTopKUsesTheKthLogprobAsABound() throws {
        let reference = [summary([3, 1], [-0.1, -0.12])]
        let sharded = [summary([1, 2], [-0.1, -4])]
        let parity = try ShardLogitParity.compare(reference: [reference], sharded: [sharded], tieMargin: 0.05)
        XCTAssertEqual(parity.nearTieFlips, 1)
        XCTAssertEqual(parity.maxAbsDeltaLogprob, 3.9, accuracy: 1e-5)
        XCTAssertEqual(parity.meanTopKOverlap, 0.5)
        XCTAssertEqual(parity.verdict, "fail", "the bound exceeds the tolerance")
    }

    func testShapeMismatchesAreErrors() {
        let step = summary([1], [-0.1])
        XCTAssertThrowsError(try ShardLogitParity.compare(reference: [[step]], sharded: [])) { error in
            XCTAssertEqual(error as? ShardLogitParityError, .sequenceCount(reference: 1, sharded: 0))
        }
        XCTAssertThrowsError(try ShardLogitParity.compare(reference: [[step, step]], sharded: [[step]])) { error in
            XCTAssertEqual(error as? ShardLogitParityError, .stepCount(sequence: 0, reference: 2, sharded: 1))
        }
    }
}
