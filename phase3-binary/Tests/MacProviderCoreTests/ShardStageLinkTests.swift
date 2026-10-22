import Foundation
import XCTest
@testable import MacProviderCore

final class ShardStageLinkTests: XCTestCase {
    private let configuration = ShardLinkConfiguration(groupEpoch: 11, heartbeatInterval: 0.1, missedHeartbeatLimit: 3)

    /// A connected loopback pair inside one process: (listener side, connector side).
    private func linkedPair(_ configuration: ShardLinkConfiguration? = nil) throws -> (ShardStageLink, ShardStageLink) {
        let configuration = configuration ?? self.configuration
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let accepted = LinkBox()
        let acceptDone = expectation(description: "accepted")
        DispatchQueue.global().async {
            accepted.link = try? listener.accept(timeout: 5, configuration: configuration)
            acceptDone.fulfill()
        }
        let client = try ShardStageLink.connect(host: "127.0.0.1", port: listener.port, timeout: 5, configuration: configuration)
        wait(for: [acceptDone], timeout: 6)
        let server = try XCTUnwrap(accepted.link)
        return (server, client)
    }

    private func activation(width: Int, step: UInt32) -> ShardStageFrame {
        ShardStageFrame(
            header: ShardStageFrameHeader(
                kind: .activation, dtype: .bfloat16, groupEpoch: 11, requestID: 1, tokenStep: step,
                sourceStage: 0, destinationStage: 1, layerStart: 0, layerEnd: 4, shape: [1, 1, UInt32(width)]
            ),
            payload: Data((0..<(2 * width)).map { UInt8(truncatingIfNeeded: $0 &+ Int(step)) })
        )
    }

    func testLoopbackFramesArriveInOrderWithSequenceNumbers() throws {
        let (server, client) = try linkedPair()
        defer { server.close(); client.close() }
        for step in 0..<20 as Range<UInt32> {
            let sent = activation(width: 7168, step: step)
            try client.send(sent)
            let received = try server.receive(timeout: 2)
            XCTAssertEqual(received.header.tokenStep, step)
            XCTAssertEqual(received.payload, sent.payload)
            XCTAssertEqual(received.header.groupEpoch, 11)
        }
        // And back the other way on the same connection.
        try server.send(ShardStageFrame(
            header: ShardStageFrameHeader(kind: .token, dtype: .int32, groupEpoch: 11, shape: [1]),
            payload: Data([42, 0, 0, 0])
        ))
        XCTAssertEqual(try client.receive(timeout: 2).payload, Data([42, 0, 0, 0]))
    }

    func testHeartbeatsKeepAnIdleLinkAliveAndAreNotDelivered() throws {
        let (server, client) = try linkedPair()
        defer { server.close(); client.close() }
        // Wait far longer than the 300 ms liveness window with no application traffic.
        XCTAssertThrowsError(try server.receive(timeout: 0.8)) { error in
            XCTAssertEqual(error as? ShardLinkError, .receiveTimedOut)
        }
        XCTAssertGreaterThan(server.statistics.heartbeatsReceived, 3)
        try client.send(activation(width: 4, step: 1))
        XCTAssertEqual(try server.receive(timeout: 1).header.tokenStep, 1)
    }

    func testPeerCloseSurfacesWithinDeadline() throws {
        let (server, client) = try linkedPair()
        defer { server.close() }
        let start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { client.close() }
        XCTAssertThrowsError(try server.receive(timeout: 5)) { error in
            XCTAssertEqual(error as? ShardLinkError, .peerClosed)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testHungPeerIsDeclaredDeadAfterMissedHeartbeats() throws {
        let (server, client) = try linkedPair()
        defer { server.close(); client.close() }
        client.pauseHeartbeatsForTesting()
        let start = Date()
        XCTAssertThrowsError(try server.receive(timeout: 10)) { error in
            guard case .peerDead(let silent) = error as? ShardLinkError else {
                return XCTFail("expected peerDead, got \(error)")
            }
            XCTAssertGreaterThanOrEqual(silent, 300)
        }
        let elapsed = Date().timeIntervalSince(start)
        // Liveness window is 3 x 100 ms; allow the in-flight heartbeat plus scheduling slack.
        XCTAssertGreaterThanOrEqual(elapsed, 0.3)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testSendAfterPeerCloseThrowsInsteadOfTrapping() throws {
        let (server, client) = try linkedPair()
        defer { client.close() }
        server.close()
        // The first write can land in the kernel buffer before the RST arrives; keep
        // writing until the loss surfaces as a typed error.
        var surfaced: ShardLinkError?
        for step in 0..<200 as Range<UInt32> {
            do {
                try client.send(activation(width: 7168, step: step))
            } catch {
                surfaced = error as? ShardLinkError
                break
            }
            usleep(5_000)
        }
        let error = try XCTUnwrap(surfaced, "send to a closed peer never failed")
        XCTAssertTrue([.peerClosed, .sendTimedOut].contains(error) || {
            if case .socketFailed = error { return true }
            return false
        }(), "unexpected error \(error)")
    }

    func testLocalCloseMakesSendAndReceiveThrowClosed() throws {
        let (server, client) = try linkedPair()
        defer { server.close() }
        client.close()
        XCTAssertThrowsError(try client.send(activation(width: 4, step: 0))) { error in
            XCTAssertEqual(error as? ShardLinkError, .closed)
        }
        XCTAssertThrowsError(try client.receive(timeout: 1)) { error in
            XCTAssertEqual(error as? ShardLinkError, .closed)
        }
    }

    func testOversizeIncomingFrameIsRejectedByReceiver() throws {
        let small = ShardLinkConfiguration(groupEpoch: 11, limits: ShardFrameLimits(payloadCap: 1024))
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let accepted = LinkBox()
        let acceptDone = expectation(description: "accepted")
        DispatchQueue.global().async {
            accepted.link = try? listener.accept(timeout: 5, configuration: small)
            acceptDone.fulfill()
        }
        let client = try ShardStageLink.connect(host: "127.0.0.1", port: listener.port, timeout: 5, configuration: configuration)
        defer { client.close() }
        wait(for: [acceptDone], timeout: 6)
        let server = try XCTUnwrap(accepted.link)
        defer { server.close() }
        try client.send(activation(width: 4096, step: 0))
        XCTAssertThrowsError(try server.receive(timeout: 2)) { error in
            XCTAssertEqual(error as? ShardLinkError, .frame(.payloadTooLarge(length: 8192, cap: 1024)))
        }
    }

    func testEpochMismatchIsRejected() throws {
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let accepted = LinkBox()
        let acceptDone = expectation(description: "accepted")
        DispatchQueue.global().async {
            accepted.link = try? listener.accept(timeout: 5, configuration: self.configuration)
            acceptDone.fulfill()
        }
        let stale = ShardLinkConfiguration(groupEpoch: 10)
        let client = try ShardStageLink.connect(host: "127.0.0.1", port: listener.port, timeout: 5, configuration: stale)
        defer { client.close() }
        wait(for: [acceptDone], timeout: 6)
        let server = try XCTUnwrap(accepted.link)
        defer { server.close() }
        try client.send(activation(width: 4, step: 0))
        XCTAssertThrowsError(try server.receive(timeout: 2)) { error in
            XCTAssertEqual(error as? ShardLinkError, .frame(.epochMismatch(expected: 11, actual: 10)))
        }
    }

    func testReceiveTimeoutMidFrameKeepsTheStreamAligned() throws {
        let quiet = ShardLinkConfiguration(groupEpoch: 11, heartbeatInterval: 1, missedHeartbeatLimit: 3)
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let accepted = LinkBox()
        let acceptDone = expectation(description: "accepted")
        DispatchQueue.global().async {
            accepted.link = try? listener.accept(timeout: 5, configuration: quiet)
            acceptDone.fulfill()
        }
        // A raw socket so the test controls exactly which bytes are on the wire.
        let raw = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(raw, 0)
        defer { Darwin.close(raw) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = listener.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(raw, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        wait(for: [acceptDone], timeout: 6)
        let server = try XCTUnwrap(accepted.link)
        defer { server.close() }

        let bytes = [UInt8](try ShardStageFrameCodec.encode(activation(width: 64, step: 5)))
        for (range, expectTimeout) in [(0..<30, true), (30..<100, true), (100..<bytes.count, false)] {
            let written = bytes[range].withUnsafeBytes { Darwin.write(raw, $0.baseAddress!, $0.count) }
            XCTAssertEqual(written, range.count)
            if expectTimeout {
                XCTAssertThrowsError(try server.receive(timeout: 0.2)) { error in
                    XCTAssertEqual(error as? ShardLinkError, .receiveTimedOut)
                }
            } else {
                XCTAssertEqual(try server.receive(timeout: 2).header.tokenStep, 5)
            }
        }
    }

    func testConnectWithoutListenerTimesOut() throws {
        // Bind then drop a listener so the port is very likely free and refusing.
        let port = try ShardStageListener(host: "127.0.0.1", port: 0).port
        XCTAssertThrowsError(try ShardStageLink.connect(host: "127.0.0.1", port: port, timeout: 0.3, configuration: configuration)) { error in
            XCTAssertEqual(error as? ShardLinkError, .connectTimedOut)
        }
    }
}

private final class LinkBox: @unchecked Sendable {
    var link: ShardStageLink?
}
