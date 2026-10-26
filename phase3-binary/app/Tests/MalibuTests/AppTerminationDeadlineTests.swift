import XCTest
@testable import Malibu

@MainActor
final class AppTerminationDeadlineTests: XCTestCase {
    func testHungDrainRepliesAtDeadlineWithoutWaitingForCancellation() async {
        let deadline = AppTerminationDeadline()
        let replied = expectation(description: "deadline replies")
        let drainStarted = expectation(description: "drain started")
        let watchdogStarted = expectation(description: "watchdog started")
        var releaseDrain: CheckedContinuation<Void, Never>?
        var releaseDeadline: CheckedContinuation<Void, Never>?
        var replies: [Bool] = []
        deadline.begin(drain: {
            await withCheckedContinuation {
                releaseDrain = $0
                drainStarted.fulfill()
            }
        }, wait: {
            await withCheckedContinuation {
                releaseDeadline = $0
                watchdogStarted.fulfill()
            }
        }, reply: {
            replies.append($0)
            replied.fulfill()
        })
        await fulfillment(of: [drainStarted, watchdogStarted], timeout: 2)
        releaseDeadline?.resume()
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [true])
        releaseDrain?.resume()
        await Task.yield()
        XCTAssertEqual(replies, [true], "late drain completion must not reply twice")
    }

    func testNormalDrainAndRepeatedQuitReplyOnlyOnce() async {
        let deadline = AppTerminationDeadline()
        let replied = expectation(description: "drain replies")
        var drainCount = 0
        var replies: [Bool] = []
        let drain: @MainActor () async -> Void = { drainCount += 1 }
        let reply: @MainActor (Bool) -> Void = {
            replies.append($0)
            replied.fulfill()
        }
        deadline.begin(drain: drain, reply: reply)
        deadline.begin(drain: drain, reply: reply)
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(drainCount, 1)
        XCTAssertEqual(replies, [false])
        XCTAssertTrue(deadline.finished)
    }
}
