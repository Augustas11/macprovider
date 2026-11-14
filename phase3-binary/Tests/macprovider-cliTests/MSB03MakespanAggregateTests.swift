import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-038 FR-CB14 v0.3.37: MSB-03's aggregate gate is decoded tokens over
/// the makespan, against the same requests served back to back.
final class MSB03MakespanAggregateTests: XCTestCase {
    private let decodedPerRow = 128
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// Rows submitted together at t0: (first token, last token) seconds after t0.
    private func timings(_ rows: [(Double, Double)]) -> [MSBSchedulerRowTiming] {
        rows.map {
            MSBSchedulerRowTiming(
                submittedAt: t0,
                firstTokenAt: t0.addingTimeInterval($0.0),
                completedAt: t0.addingTimeInterval($0.1)
            )
        }
    }

    /// 512 / 1,024 / 1,536 / 2,048 served one after another: (prefill, decode) seconds.
    private func serialBackToBack(_ requests: [(Double, Double)]) -> [MSBAggregateThroughputInput] {
        var cursor = t0
        return requests.map { prefill, decode in
            let start = cursor
            cursor = cursor.addingTimeInterval(prefill + decode)
            return MSBAggregateThroughputInput(
                decodedTokens: decodedPerRow, decodeStartedAt: start, decodeEndedAt: cursor
            )
        }
    }

    private var serial: [MSBAggregateThroughputInput] {
        serialBackToBack([(1.56, 3.05), (3.1, 3.05), (4.6, 3.1), (6.2, 3.2)])
    }

    /// GLM-5.3-Flash msb03 on the M3 Ultra (#2253). Before the prefill-order
    /// fix the short row's first token came at 6.0 s; after it at 1.56 s.
    /// The last row's last token comes at the same time in both.
    private var before: [MSBSchedulerRowTiming] {
        timings([(6.0, 13.5), (9.1, 16.0), (12.2, 20.0), (15.3, 23.26)])
    }

    private var after: [MSBSchedulerRowTiming] {
        timings([(1.56, 10.0), (4.66, 14.0), (9.3, 19.0), (15.3, 23.26)])
    }

    private func makespan(_ rows: [MSBSchedulerRowTiming]) throws -> MSBAggregateThroughputReport {
        try msbAggregateThroughput(rows.map { try $0.makespanSample(outputTokens: decodedPerRow + 1) })
    }

    private func decodeInterval(_ rows: [MSBSchedulerRowTiming]) throws -> MSBAggregateThroughputReport {
        try msbAggregateThroughput(rows.map { try $0.throughputSample(outputTokens: decodedPerRow + 1) })
    }

    func testServingTheShortRowSoonerKeepsTheMakespanAggregate() throws {
        let beforeMakespan = try makespan(before)
        let afterMakespan = try makespan(after)
        XCTAssertEqual(beforeMakespan.commonWallSeconds, 23.26, accuracy: 1e-6)
        XCTAssertEqual(afterMakespan.commonWallSeconds, beforeMakespan.commonWallSeconds, accuracy: 1e-6)
        XCTAssertEqual(afterMakespan.totalDecodedTokens, 512)
        XCTAssertEqual(
            afterMakespan.aggregateTokensPerSecond, beforeMakespan.aggregateTokensPerSecond, accuracy: 1e-9
        )
        let beforeRatio = try msb03MakespanVsSerial(
            batched: before.map { try $0.makespanSample(outputTokens: decodedPerRow + 1) }, serial: serial
        ).ratio
        let afterRatio = try msb03MakespanVsSerial(
            batched: after.map { try $0.makespanSample(outputTokens: decodedPerRow + 1) }, serial: serial
        ).ratio
        XCTAssertEqual(afterRatio, beforeRatio, accuracy: 1e-9)

        // The old decode-interval aggregate falls only because the earliest
        // first token moved earlier: 29.7 -> 23.6 tok/s on the same makespan.
        XCTAssertEqual(try decodeInterval(before).aggregateTokensPerSecond, 512 / 17.26, accuracy: 1e-6)
        XCTAssertEqual(try decodeInterval(after).aggregateTokensPerSecond, 512 / 21.70, accuracy: 1e-6)
    }

    func testSerialMakespanIsTheWholeBackToBackInterval() throws {
        let report = try msbAggregateThroughput(serial)
        XCTAssertEqual(report.commonWallSeconds, 1.56 + 3.05 + 3.1 + 3.05 + 4.6 + 3.1 + 6.2 + 3.2, accuracy: 1e-6)
        XCTAssertEqual(report.totalDecodedTokens, 512)
    }

    func testALongerBatchedMakespanStillFailsTheGate() throws {
        // A genuine slowdown: the same rows, but the last token 40 s in.
        let slow = timings([(1.56, 18.0), (4.66, 26.0), (9.3, 33.0), (15.3, 40.0)])
        let ratio = try msb03MakespanVsSerial(
            batched: slow.map { try $0.makespanSample(outputTokens: decodedPerRow + 1) }, serial: serial
        ).ratio
        XCTAssertLessThan(ratio, 1.0)
        XCTAssertFalse(msb03AggregatePass(aggregateVsSerial: ratio))

        // A batch that finishes well before the back-to-back serial run passes.
        let fast = timings([(1.56, 8.0), (4.66, 12.0), (9.3, 16.0), (15.3, 20.0)])
        let fastRatio = try msb03MakespanVsSerial(
            batched: fast.map { try $0.makespanSample(outputTokens: decodedPerRow + 1) }, serial: serial
        ).ratio
        XCTAssertEqual(fastRatio, 27.86 / 20.0, accuracy: 1e-6)
        XCTAssertTrue(msb03AggregatePass(aggregateVsSerial: fastRatio))
    }

    func testSerialRunWithNoDecodedTokensFailsClosed() throws {
        let fast = timings([(1.56, 8.0), (4.66, 12.0), (9.3, 16.0), (15.3, 20.0)])
        let empty = serial.map {
            MSBAggregateThroughputInput(decodedTokens: 0, decodeStartedAt: $0.decodeStartedAt, decodeEndedAt: $0.decodeEndedAt)
        }
        let ratio = try msb03MakespanVsSerial(
            batched: fast.map { try $0.makespanSample(outputTokens: decodedPerRow + 1) }, serial: empty
        ).ratio
        XCTAssertEqual(ratio, 0)
        XCTAssertFalse(msb03AggregatePass(aggregateVsSerial: ratio))
    }

    /// SPEC-038 v0.3.52: msb03's makespan and TTFT gates together.
    private func msb03Passes(makespan: Double, ttftRatio: Double, prefill: MSB03PrefillKind) -> Bool {
        msb03AggregatePass(aggregateVsSerial: makespan, prefill: prefill)
            && msb03ShortRequestTTFTPass(ratio: ttftRatio)
    }

    func testPrefillKindFollowsTheBackendsFlattenedPrefillCap() {
        // `glm5_next` pagedMLA: an 8-token cap against 512-token chunks.
        XCTAssertEqual(msb03PrefillKind(prefillForwardTokenCap: 8, promptChunkTokens: 512), .perRow)
        XCTAssertEqual(msb03PrefillKind(prefillForwardTokenCap: nil, promptChunkTokens: 512), .shared)
        XCTAssertEqual(msb03PrefillKind(prefillForwardTokenCap: 1024, promptChunkTokens: 512), .shared)
        XCTAssertEqual(msb03PrefillKind(prefillForwardTokenCap: 1023, promptChunkTokens: 512), .perRow)
        XCTAssertEqual(msb03MakespanBar(prefill: .perRow), 1.0)
        XCTAssertEqual(msb03MakespanBar(prefill: .shared), 1.2)
    }

    func testPerRowPrefillBackendPassesAboveSerialMakespan() {
        // GLM-5.3-Flash on the M3 Ultra: 1.19x, the lower edge of a 1.19x-1.22x ceiling.
        XCTAssertTrue(msb03Passes(makespan: 1.19, ttftRatio: 1.0, prefill: .perRow))
        XCTAssertFalse(msb03Passes(makespan: 0.99, ttftRatio: 1.0, prefill: .perRow))
        XCTAssertFalse(msb03Passes(makespan: 1.19, ttftRatio: 2.5, prefill: .perRow))
    }

    func testSharedForwardBackendKeepsTheAbove1point2Bar() {
        XCTAssertFalse(msb03Passes(makespan: 1.19, ttftRatio: 1.0, prefill: .shared))
        XCTAssertTrue(msb03Passes(makespan: 1.21, ttftRatio: 1.0, prefill: .shared))
    }

    /// GLM-5.3-Flash msb03 lab rows (#2331): `--decode-tokens 128` asks for
    /// 129 output tokens, the prefill's sampled token plus 128 decode steps.
    func testUsageExpectsThePrefillTokenPlusTheDecodeSteps() {
        let rows = zip([512, 1024, 1536, 2048], 0...).map { prompt, index in
            MSBUsageRow(
                requestID: "msb-sched-\(index)",
                promptTokens: prompt,
                completionTokens: 129,
                emittedTokens: 129,
                cachedPromptTokens: 0,
                terminalStatus: ContinuousBatchSchedulerTerminalStatus.length.rawValue,
                settlementDisposition: ContinuousBatchSettlementDisposition.eligibleOwner.rawValue
            )
        }
        let expected = msb03ExpectedCompletionTokens(decodeTokens: 128)
        XCTAssertEqual(expected, 129)
        XCTAssertTrue(msbUsageAttributionPass(
            rows: rows, expectedPromptTokens: msb03PromptLengths(), expectedCompletionTokens: expected
        ))
        XCTAssertFalse(msbUsageAttributionPass(
            rows: rows, expectedPromptTokens: msb03PromptLengths(), expectedCompletionTokens: 128
        ))
    }

    func testMakespanSampleRejectsARowThatEndsBeforeItArrives() {
        let row = MSBSchedulerRowTiming(submittedAt: t0, firstTokenAt: t0, completedAt: t0)
        XCTAssertThrowsError(try row.makespanSample(outputTokens: 2))
        XCTAssertThrowsError(try row.makespanSample(outputTokens: 0))
    }
}
