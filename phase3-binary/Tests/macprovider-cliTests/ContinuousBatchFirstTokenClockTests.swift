import XCTest
@testable import macprovider_cli

final class ContinuousBatchFirstTokenClockTests: XCTestCase {
    func testReportsFirstMarkOnlyRelativeToStart() {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = ContinuousBatchFirstTokenClock()
        XCTAssertNil(clock.ttftMilliseconds(since: start))

        clock.mark(start.addingTimeInterval(1.25))
        clock.mark(start.addingTimeInterval(90))
        XCTAssertEqual(clock.ttftMilliseconds(since: start), 1_250)
    }

    func testNeverReportsNegativeTTFT() {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = ContinuousBatchFirstTokenClock()
        clock.mark(start.addingTimeInterval(-1))
        XCTAssertEqual(clock.ttftMilliseconds(since: start), 0)
    }
}

extension ContinuousBatchFirstTokenClockTests {
    func testMarksOnlyWhenABuyerVisibleChunkIsEmitted() {
        let clock = ContinuousBatchFirstTokenClock()
        var delivered: [String] = []
        // A token event that the stream filter holds back emits no chunk.
        _ = clock.markingFirstChunk(replay: false) { (chunk: String) in delivered.append(chunk) }
        XCTAssertNil(clock.ttftMilliseconds(since: .distantPast))

        let sink = clock.markingFirstChunk(replay: false) { (chunk: String) in delivered.append(chunk) }
        sink("hello")
        XCTAssertEqual(delivered, ["hello"])
        XCTAssertNotNil(clock.ttftMilliseconds(since: .distantPast))
    }

    func testReplayChunksNeverDefineTTFT() {
        // A duplicate or replay waiter catches up on the canonical row's
        // tokens; that delivery must not become the signed TTFT.
        let clock = ContinuousBatchFirstTokenClock()
        var delivered: [String] = []
        let replaySink = clock.markingFirstChunk(replay: true) { (chunk: String) in delivered.append(chunk) }
        replaySink("caught-up")
        XCTAssertEqual(delivered, ["caught-up"])
        XCTAssertNil(clock.ttftMilliseconds(since: .distantPast))

        let start = Date()
        let liveSink = clock.markingFirstChunk(replay: false) { (_: String) in }
        liveSink("live")
        XCTAssertNotNil(clock.ttftMilliseconds(since: start))
    }
}
