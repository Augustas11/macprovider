import Foundation
import XCTest
@testable import MacProviderCore

/// Issue #2084 freeze audit round 1: stage link and parity fixes.
final class ShardLinkAuditFixTests: XCTestCase {
    private let configuration = ShardLinkConfiguration(groupEpoch: 5, heartbeatInterval: 0.05, missedHeartbeatLimit: 4)

    private func pair() throws -> (ShardStageLink, ShardStageLink) {
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let dialed = try ShardStageLink.connect(host: "127.0.0.1", port: listener.port, timeout: 5, configuration: configuration)
        return (try listener.accept(timeout: 5, configuration: configuration), dialed)
    }

    private func waitFor(_ timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    private func frame(_ kind: ShardFrameKind, step: UInt32) -> ShardStageFrame {
        switch kind {
        case .activation:
            return ShardStageFrame(
                header: ShardStageFrameHeader(kind: .activation, dtype: .bfloat16, groupEpoch: 5, requestID: 1, tokenStep: step, shape: [1, 1, 4]),
                payload: Data(count: 8))
        default:
            return ShardStageFrame(header: ShardStageFrameHeader(kind: kind, groupEpoch: 5, requestID: UInt64(step)))
        }
    }

    /// C05 / SPEC-051-R014: a link this end closed hands out none of the work it
    /// still had queued.
    func testQueuedWorkIsNotHandedOutAfterLocalClose() throws {
        let (accepted, dialed) = try pair()
        defer { dialed.close() }
        for step in 0..<3 as Range<UInt32> { try dialed.send(frame(.activation, step: step)) }
        waitFor { accepted.statistics.framesReceived - accepted.statistics.heartbeatsReceived >= 3 }
        accepted.close()
        XCTAssertThrowsError(try accepted.receive(timeout: 0.2)) { error in
            XCTAssertEqual(error as? ShardLinkError, .closed)
        }
    }

    /// C05 / SPEC-051-R014: when the peer goes away, its queued activations are
    /// dropped; its last abort (a session-end acknowledgement) still arrives, then
    /// the failure.
    func testAFailedLinkDropsQueuedWorkButDeliversTheAbort() throws {
        let (accepted, dialed) = try pair()
        for step in 0..<3 as Range<UInt32> { try dialed.send(frame(.activation, step: step)) }
        try dialed.send(frame(.abort, step: 0))
        waitFor { accepted.statistics.framesReceived - accepted.statistics.heartbeatsReceived >= 4 }
        dialed.close()
        waitFor { accepted.hasFailed }
        XCTAssertEqual(try accepted.receive(timeout: 1).header.kind, .abort)
        XCTAssertThrowsError(try accepted.receive(timeout: 1)) { error in
            XCTAssertEqual(error as? ShardLinkError, .peerClosed)
        }
        accepted.close()
    }

    /// C06 / SPEC-051-R007: an echo that queued behind data is a distinct kind the
    /// pinging end does not sample.
    func testQueuedEchoRoundTripsAndIsNotAnOrdinaryEcho() throws {
        let queued = ShardHeartbeatPayload(kind: .queuedEcho, nonce: 41)
        XCTAssertEqual(try ShardHeartbeatPayload.decode(queued.encode()), queued)
        XCTAssertEqual(queued.encode().count, 10)
        XCTAssertNotEqual(queued.encode(), ShardHeartbeatPayload(kind: .echo, nonce: 41).encode())
    }

    /// C06: a link that carries back-to-back data still measures its round trip
    /// from pings that queued behind nothing, so the measured p99 stays a link
    /// time, not the time the data took to drain.
    func testRoundTripsUnderDataTrafficMeasureTheLink() throws {
        let (accepted, dialed) = try pair()
        defer { accepted.close(); dialed.close() }
        let big = ShardStageFrame(
            header: ShardStageFrameHeader(kind: .activation, dtype: .bfloat16, groupEpoch: 5, requestID: 1, shape: [1, 512, 4096]),
            payload: Data(count: 2 * 512 * 4096))
        let sender = Thread {
            for _ in 0..<40 { _ = try? dialed.send(big) }
        }
        sender.start()
        var received = 0
        while received < 40, let _ = try? accepted.receive(timeout: 5) { received += 1 }
        XCTAssertEqual(received, 40)
        waitFor { dialed.roundTrip.samples >= 10 }
        XCTAssertLessThan(try XCTUnwrap(dialed.roundTrip.p99Seconds), 0.015, "loopback round trip, not data drain time")
    }

    /// C12: summaries that did not come through the codec are validated by the
    /// comparison, which throws instead of trapping.
    func testParityRejectsMalformedSummariesWithAnError() {
        let good = ShardLogitSummary(topTokens: [3, 4], topLogprobs: [-0.1, -2], logSumExp: 1)
        let empty = ShardLogitSummary(topTokens: [3], topLogprobs: [], logSumExp: 1)
        XCTAssertThrowsError(try ShardLogitParity.compare(reference: [[empty]], sharded: [[good]]))
        XCTAssertThrowsError(try ShardLogitParity.compare(reference: [[good]], sharded: [[empty]]))
        XCTAssertNoThrow(try ShardLogitParity.compare(reference: [[good]], sharded: [[good]]))
    }
}
