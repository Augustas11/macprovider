import Darwin
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

    /// C06: a ping behind data is marked as queued, rather than contributing a
    /// data-drain duration to the link's round-trip window.
    func testRoundTripsUnderDataTrafficMeasureTheLink() throws {
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let peer = try HeartbeatPeer(port: listener.port)
        // Drive pings explicitly. Liveness is tested elsewhere; it must not race
        // the test thread while CI is descheduled between frames.
        let controlled = ShardLinkConfiguration(
            groupEpoch: 5, heartbeatInterval: 3600, armLivenessOnOpen: false)
        let link = try listener.accept(timeout: 5, configuration: controlled)
        defer { link.close() }

        for step in 0..<40 as Range<UInt32> {
            try peer.send(frame(.activation, step: step))
            try peer.send(ShardStageFrame(
                header: ShardStageFrameHeader(kind: .heartbeat, groupEpoch: 5),
                payload: ShardHeartbeatPayload(kind: .ping, nonce: UInt64(step)).encode()))
            // TCP ordering makes the reader process data before this ping. Read
            // its reply before advancing, without relying on payload size or speed.
            let reply = try peer.receive()
            XCTAssertEqual(reply.header.kind, .heartbeat)
            XCTAssertEqual(
                try ShardHeartbeatPayload.decode(reply.payload),
                ShardHeartbeatPayload(kind: .queuedEcho, nonce: UInt64(step)))
            XCTAssertEqual(try link.receive(timeout: 5).header.tokenStep, step)
        }

        // Exercise the sampler too: the first ping has no preceding outbound
        // data, so it has a pending measurement. Epoch adoption holds heartbeats
        // until the report callback is installed; that callback pauses later pings.
        func checkSample(_ kind: ShardHeartbeatPayload.Kind, expectedSamples: Int) throws {
            let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
            let peer = try HeartbeatPeer(port: listener.port)
            let configuration = ShardLinkConfiguration(
                groupEpoch: 5, heartbeatInterval: 0.05,
                armLivenessOnOpen: false, adoptsHigherEpoch: true)
            let link = try listener.accept(timeout: 5, configuration: configuration)
            defer { link.setHeartbeatReport(nil); link.close() }
            link.setHeartbeatReport {
                link.pauseHeartbeatsForTesting()
                return []
            }
            try peer.send(frame(.activation, step: 0))
            XCTAssertEqual(try link.receive(timeout: 5).header.tokenStep, 0)
            let pingFrame = try peer.receive()
            XCTAssertEqual(pingFrame.header.kind, .heartbeat)
            let ping = try ShardHeartbeatPayload.decode(pingFrame.payload)
            XCTAssertEqual(ping.kind, .ping)

            func respond(_ kind: ShardHeartbeatPayload.Kind, step: UInt32) throws {
                try peer.send(ShardStageFrame(
                    header: ShardStageFrameHeader(kind: .heartbeat, groupEpoch: 5),
                    payload: ShardHeartbeatPayload(kind: kind, nonce: ping.nonce).encode()))
                try peer.send(frame(.activation, step: step))
                // The same reader handles the echo before publishing this frame.
                XCTAssertEqual(try link.receive(timeout: 5).header.tokenStep, step)
                XCTAssertEqual(link.roundTrip.samples, expectedSamples)
            }
            try respond(kind, step: 1)
            if expectedSamples == 0 {
                XCTAssertNil(link.roundTrip.p99Seconds)
            } else {
                XCTAssertNotNil(link.roundTrip.p99Seconds)
            }
            // A queued echo must discard its pending ping, and an ordinary echo
            // must consume it: neither may be sampled by a duplicate reply.
            try respond(.echo, step: 2)
        }
        try checkSample(.queuedEcho, expectedSamples: 0)
        try checkSample(.echo, expectedSamples: 1)
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

/// A peer without a background reader or heartbeat timer, so the test controls
/// the exact order of data and pings and can inspect the echo kind on the wire.
private final class HeartbeatPeer {
    private let fd: Int32
    private var sequence: UInt64 = 0

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw ShardLinkError.socketFailed(operation: "socket", errno: errno) }
        do {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw ShardLinkError.socketFailed(operation: "connect", errno: errno) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            var one: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
            else { throw ShardLinkError.socketFailed(operation: "setsockopt", errno: errno) }
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    deinit { Darwin.close(fd) }

    func send(_ frame: ShardStageFrame) throws {
        var frame = frame
        frame.header.sequence = sequence
        let bytes = try ShardStageFrameCodec.encode(frame)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw ShardLinkError.socketFailed(operation: "write", errno: errno) }
                offset += written
            }
        }
        sequence += 1
    }

    func receive() throws -> ShardStageFrame {
        let header = try readExactly(ShardStageFrameCodec.fixedHeaderSize)
        let length = try ShardStageFrameCodec.frameLength(fixedHeader: header)
        return try ShardStageFrameCodec.decode(header + readExactly(length - header.count))
    }

    private func readExactly(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let received = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if received < 0, errno == EINTR { continue }
                guard received > 0 else { throw ShardLinkError.socketFailed(operation: "read", errno: errno) }
                offset += received
            }
        }
        return bytes
    }
}
