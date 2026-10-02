#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPBenchDecodeThroughputTests: XCTestCase {
    func testPerRequestExcludesFirstTokenAndPrefill() throws {
        // 257 tokens, 2s to first token, 10s wall: 256 decode tokens over 8s.
        let tps = try XCTUnwrap(NativeMTPBenchDecodeThroughput.perRequest(completionTokens: 257, ttftSeconds: 2, wallSeconds: 10))
        XCTAssertEqual(tps, 32, accuracy: 1e-12)
    }

    func testPerRequestUndefinedCasesAreNil() {
        XCTAssertNil(NativeMTPBenchDecodeThroughput.perRequest(completionTokens: 10, ttftSeconds: nil, wallSeconds: 5))
        XCTAssertNil(NativeMTPBenchDecodeThroughput.perRequest(completionTokens: 1, ttftSeconds: 1, wallSeconds: 5))
        XCTAssertNil(NativeMTPBenchDecodeThroughput.perRequest(completionTokens: 10, ttftSeconds: 5, wallSeconds: 5))
    }

    func testAggregateSingleSlotMatchesPerRequest() throws {
        let aggregate = try XCTUnwrap(NativeMTPBenchDecodeThroughput.aggregate([
            NativeMTPBenchDecodeTiming(completionTokens: 257, firstTokenOffset: 2, endOffset: 10),
        ]))
        XCTAssertEqual(aggregate, 32, accuracy: 1e-12)
    }

    func testAggregateUsesEarliestFirstTokenToLatestCompletion() throws {
        // (100 + 50) decode tokens over [1s, 6s].
        let aggregate = try XCTUnwrap(NativeMTPBenchDecodeThroughput.aggregate([
            NativeMTPBenchDecodeTiming(completionTokens: 101, firstTokenOffset: 1, endOffset: 4),
            NativeMTPBenchDecodeTiming(completionTokens: 51, firstTokenOffset: 3, endOffset: 6),
        ]))
        XCTAssertEqual(aggregate, 30, accuracy: 1e-12)
    }

    func testAggregateFailsClosedWithoutAFirstToken() {
        XCTAssertNil(NativeMTPBenchDecodeThroughput.aggregate([]))
        XCTAssertNil(NativeMTPBenchDecodeThroughput.aggregate([
            NativeMTPBenchDecodeTiming(completionTokens: 101, firstTokenOffset: 1, endOffset: 4),
            NativeMTPBenchDecodeTiming(completionTokens: 0, firstTokenOffset: nil, endOffset: 6),
        ]))
    }
}
#endif
