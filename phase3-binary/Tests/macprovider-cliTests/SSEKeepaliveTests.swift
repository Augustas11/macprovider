import XCTest
@testable import macprovider_cli

final class SSEKeepaliveTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    func testCommentIsAnSSECommentClientsIgnore() {
        XCTAssertEqual(SSEKeepalive.comment, ": keepalive\n\n")
        XCTAssertFalse(SSEKeepalive.comment.hasPrefix("data:"))
    }

    func testQuietStreamGetsACommentEveryIntervalAndOutputResetsTheClock() {
        let sink = Sink()
        let keepalive = SSEKeepalive(interval: .seconds(10)) { sink.append(SSEKeepalive.comment) }
        let start = ContinuousClock.now
        keepalive.noteOutput()
        XCTAssertFalse(keepalive.tick(now: start.advanced(by: .seconds(5))))
        XCTAssertTrue(keepalive.tick(now: start.advanced(by: .seconds(11))))
        XCTAssertFalse(keepalive.tick(now: start.advanced(by: .seconds(15))))
        XCTAssertTrue(keepalive.tick(now: start.advanced(by: .seconds(22))))
        XCTAssertEqual(sink.all, [SSEKeepalive.comment, SSEKeepalive.comment])
        keepalive.stop()
        XCTAssertFalse(keepalive.tick(now: start.advanced(by: .seconds(60))), "Nothing may follow the end of the stream")
        XCTAssertEqual(sink.count, 2)
    }

    func testHeartbeatRunsOnlyWhileTheStreamIsOpen() async throws {
        let sink = Sink()
        let keepalive = SSEKeepalive(interval: .milliseconds(40)) { sink.append(SSEKeepalive.comment) }
        // A tool call being buffered: the runtime writes nothing for a while.
        try await keepalive.during { try await Task.sleep(for: .milliseconds(400)) }
        let emitted = sink.count
        XCTAssertGreaterThanOrEqual(emitted, 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sink.count, emitted, "No keepalive after the stream ends")
    }

    func testThrowingStreamStillStopsTheHeartbeat() async {
        let sink = Sink()
        let keepalive = SSEKeepalive(interval: .milliseconds(20)) { sink.append(SSEKeepalive.comment) }
        struct Failure: Error {}
        do {
            _ = try await keepalive.during { () async throws -> Int in throw Failure() }
            XCTFail("expected the stream error")
        } catch {}
        XCTAssertFalse(keepalive.tick(now: ContinuousClock.now.advanced(by: .seconds(1))))
    }
}
