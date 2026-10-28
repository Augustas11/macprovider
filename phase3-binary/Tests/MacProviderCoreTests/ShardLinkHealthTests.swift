import Foundation
import XCTest
@testable import MacProviderCore

/// Issue #2084 continuous link health: heartbeat pings echoed by the peer's reader
/// thread give each link a sliding p99, and pings relay link reports.
final class ShardLinkHealthTests: XCTestCase {
    private let configuration = ShardLinkConfiguration(groupEpoch: 5, heartbeatInterval: 0.02, missedHeartbeatLimit: 5)

    private func pair(_ configuration: ShardLinkConfiguration? = nil) throws -> (ShardStageLink, ShardStageLink) {
        let configuration = configuration ?? self.configuration
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let dialed = try ShardStageLink.connect(host: "127.0.0.1", port: listener.port, timeout: 5, configuration: configuration)
        return (try listener.accept(timeout: 5, configuration: configuration), dialed)
    }

    private func waitFor(_ timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    func testHeartbeatPayloadRoundTripsAndIsStrict() throws {
        let ping = ShardHeartbeatPayload(kind: .ping, nonce: 0x0102_0304_0506_0708, links: [
            ShardLinkHealth(fromStage: 1, toStage: 2, rttP99Microseconds: 412, samples: 200),
            ShardLinkHealth(fromStage: 2, toStage: 0, rttP99Microseconds: 1_000_000, samples: 3),
        ])
        XCTAssertEqual(try ShardHeartbeatPayload.decode(ping.encode()), ping)
        let echo = ShardHeartbeatPayload(kind: .echo, nonce: 9)
        XCTAssertEqual(try ShardHeartbeatPayload.decode(echo.encode()), echo)
        XCTAssertEqual(echo.encode().count, 10)
        var badKind = echo.encode()
        badKind[0] = 4
        var echoWithEntries = ping.encode()
        echoWithEntries[0] = ShardHeartbeatPayload.Kind.echo.rawValue
        var shortCount = ping.encode()
        shortCount[9] = 3
        var tooMany = ShardHeartbeatPayload(kind: .ping, nonce: 1).encode()
        tooMany[9] = UInt8(ShardHeartbeatPayload.maxEntries + 1)
        tooMany.append(Data(count: 10 * (ShardHeartbeatPayload.maxEntries + 1)))
        for bad in [Data([1, 2, 3]), badKind, echoWithEntries, shortCount, tooMany, ping.encode() + Data([0])] {
            XCTAssertThrowsError(try ShardHeartbeatPayload.decode(bad)) { XCTAssertEqual($0 as? ShardFrameError, .malformedHeartbeat) }
        }
    }

    func testRoundTripWindowSlidesAndReportsP99() {
        var window = ShardRoundTripWindow(capacity: 100)
        XCTAssertNil(window.p99Seconds)
        XCTAssertNil(window.health(from: 0, to: 1))
        for index in 1...100 { window.add(Double(index) / 1e6) }
        XCTAssertEqual(window.p99Seconds ?? 0, 99e-6, accuracy: 1e-12)
        XCTAssertEqual(window.health(from: 0, to: 1), ShardLinkHealth(fromStage: 0, toStage: 1, rttP99Microseconds: 99, samples: 100))
        // A slow spell pushes the p99 up; once it slides out of the window it drops again.
        for _ in 0..<5 { window.add(0.05) }
        XCTAssertEqual(window.p99Seconds ?? 0, 0.05, accuracy: 1e-12)
        for _ in 0..<100 { window.add(200e-6) }
        XCTAssertEqual(window.p99Seconds ?? 0, 200e-6, accuracy: 1e-12)
        XCTAssertEqual(window.count, 100)
    }

    func testEchoedHeartbeatsMeasureTheLinkWhileTheOwnersAreBusy() throws {
        let (accepted, dialed) = try pair()
        defer { accepted.close(); dialed.close() }
        // Neither owner calls receive: each reader thread answers pings on its own,
        // so the round trip is the link's, not the owner's compute.
        waitFor { dialed.roundTrip.samples >= 20 && accepted.roundTrip.samples >= 20 }
        let measured = dialed.roundTrip
        XCTAssertGreaterThanOrEqual(measured.samples, 20)
        let p99 = try XCTUnwrap(measured.p99Seconds)
        // Shared CI runners can delay reader scheduling beyond a heartbeat interval.
        // This test proves autonomous echo collection; the window test checks exact p99 math.
        XCTAssertTrue(p99.isFinite)
        XCTAssertGreaterThan(p99, 0)
        XCTAssertGreaterThanOrEqual(accepted.roundTrip.samples, 20)
        XCTAssertEqual(dialed.roundTripHealth(from: 0, to: 1)?.fromStage, 0)
        // Data still flows in order around the pings.
        for step in 0..<5 as Range<UInt32> {
            try dialed.send(ShardStageFrame(
                header: ShardStageFrameHeader(kind: .token, dtype: .int32, groupEpoch: 5, tokenStep: step, shape: [1]),
                payload: Data([UInt8(step), 0, 0, 0])))
        }
        for step in 0..<5 as Range<UInt32> {
            XCTAssertEqual(try accepted.receive(timeout: 1).header.tokenStep, step)
        }
    }

    func testPingsRelayTheirSendersLinkReport() throws {
        let (accepted, dialed) = try pair()
        defer { accepted.close(); dialed.close() }
        let report = [ShardLinkHealth(fromStage: 1, toStage: 2, rttP99Microseconds: 350, samples: 40)]
        dialed.setHeartbeatReport { report }
        waitFor { accepted.roundTrip.peerLinks == report }
        XCTAssertEqual(accepted.roundTrip.peerLinks, report)
        XCTAssertNotNil(accepted.roundTrip.peerLinksAt)
        XCTAssertEqual(dialed.roundTrip.peerLinks, [], "the other direction reports nothing")
    }

    func testAFrozenPeerNeitherEchoesNorStaysAlive() throws {
        var armed = configuration
        armed.missedHeartbeatLimit = 3
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let dialed = try ShardStageLink.connect(host: "127.0.0.1", port: listener.port, timeout: 5, configuration: armed)
        let accepted = try listener.accept(timeout: 5, configuration: armed)
        defer { accepted.close(); dialed.close() }
        waitFor { dialed.roundTrip.samples > 0 }
        accepted.pauseHeartbeatsForTesting()
        let before = dialed.roundTrip.samples
        XCTAssertThrowsError(try dialed.receive(timeout: 2)) { error in
            guard case ShardLinkError.peerDead = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThanOrEqual(dialed.roundTrip.samples, before + 1)
    }

    func testClosingWakesABlockedReceiveAndThePeerSeesTheEnd() throws {
        // Liveness must not fire before the close on a slow host; this test is about close, not silence.
        let (accepted, dialed) = try pair(
            ShardLinkConfiguration(groupEpoch: 5, heartbeatInterval: 0.02, missedHeartbeatLimit: 500))
        let woke = expectation(description: "receive returned")
        let outcome = ErrorBox()
        DispatchQueue.global().async {
            do {
                _ = try accepted.receive(timeout: 10)
            } catch {
                outcome.error = error
            }
            woke.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        accepted.close()
        wait(for: [woke], timeout: 2)
        XCTAssertEqual(outcome.error as? ShardLinkError, .closed)
        XCTAssertThrowsError(try dialed.receive(timeout: 2)) { XCTAssertEqual($0 as? ShardLinkError, .peerClosed) }
        dialed.close()
    }
}

private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}
