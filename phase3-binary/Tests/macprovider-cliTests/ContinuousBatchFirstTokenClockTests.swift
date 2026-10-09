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
