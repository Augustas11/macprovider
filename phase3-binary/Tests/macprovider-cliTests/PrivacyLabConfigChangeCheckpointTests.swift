import Darwin
import Dispatch
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class PrivacyLabConfigChangeCheckpointTests: XCTestCase {
    func testSocketpairReadyAckRoundTrip() throws {
        let pair = try Self.makeSocketPair()
        defer {
            Darwin.close(pair.0)
            Darwin.close(pair.1)
        }
        let scope = try Self.makeScope()
        let checkpoint = try PrivacyLabConfigChangeCheckpoint(fd: pair.0, nonceFactory: { "nonce-ok" })
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { done.signal() }
            guard let ready = try? Self.readFrame(pair.1),
                  ready["schema_version"] as? Int == PrivacyLabConfigChangeCheckpoint.schemaVersion,
                  ready["event"] as? String == PrivacyLabConfigChangeCheckpoint.readyEvent,
                  ready["nonce"] as? String == "nonce-ok",
                  ready["pid"] as? Int == Int(Darwin.getpid()),
                  ready["root_digest"] as? String != nil else {
                return
            }
            Self.writeFrame([
                "event": PrivacyLabConfigChangeCheckpoint.ackEvent,
                "nonce": "nonce-ok",
                "schema_version": PrivacyLabConfigChangeCheckpoint.schemaVersion,
            ], fd: pair.1)
        }

        XCTAssertNoThrow(try checkpoint.signalReady(scope: scope))
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
    }

    func testConstructorOwnsDuplicateWithoutClosingCallerDescriptor() throws {
        let pair = try Self.makeSocketPair()
        defer {
            Darwin.close(pair.0)
            Darwin.close(pair.1)
        }
        let scope = try Self.makeScope()
        let checkpoint = try PrivacyLabConfigChangeCheckpoint(fd: pair.0, nonceFactory: { "nonce-ok" })
        XCTAssertFalse(Self.fdIsClosed(pair.0), "constructor owns a close-on-exec dup, not the caller descriptor")

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { done.signal() }
            _ = try? Self.readFrame(pair.1)
            Self.writeFrame([
                "event": PrivacyLabConfigChangeCheckpoint.ackEvent,
                "nonce": "nonce-ok",
                "schema_version": PrivacyLabConfigChangeCheckpoint.schemaVersion,
            ], fd: pair.1)
        }

        XCTAssertNoThrow(try checkpoint.signalReady(scope: scope))
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertThrowsError(try checkpoint.signalReady(scope: scope)) {
            XCTAssertEqual($0 as? PrivacyLabConfigChangeCheckpointError, .invalidSocket)
        }
    }

    func testInvalidFDAndNonSocketAreRejected() throws {
        XCTAssertThrowsError(try PrivacyLabConfigChangeCheckpoint(fd: 2)) {
            XCTAssertEqual($0 as? PrivacyLabConfigChangeCheckpointError, .invalidFD)
        }

        let file = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("privacy-lab-checkpoint-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        let fd = Darwin.open(file.path, O_RDONLY)
        defer { if fd >= 0 { Darwin.close(fd) } }
        XCTAssertThrowsError(try PrivacyLabConfigChangeCheckpoint(fd: fd)) {
            XCTAssertEqual($0 as? PrivacyLabConfigChangeCheckpointError, .invalidSocket)
        }
    }

    func testWrongNonceAndMalformedAckAreRejected() throws {
        let scope = try Self.makeScope()
        try Self.withCheckpointPair(ack: [
            "event": PrivacyLabConfigChangeCheckpoint.ackEvent,
            "nonce": "wrong",
            "schema_version": PrivacyLabConfigChangeCheckpoint.schemaVersion,
        ]) { checkpoint in
            XCTAssertThrowsError(try checkpoint.signalReady(scope: scope)) {
                XCTAssertEqual($0 as? PrivacyLabConfigChangeCheckpointError, .wrongNonce)
            }
        }

        try Self.withCheckpointPair(rawAck: Data("not-json\n".utf8)) { checkpoint in
            XCTAssertThrowsError(try checkpoint.signalReady(scope: scope)) {
                XCTAssertEqual($0 as? PrivacyLabConfigChangeCheckpointError, .malformed)
            }
        }
    }

    func testAckRejectsExtraKeysAndWrongSchemaVersion() throws {
        let scope = try Self.makeScope()
        try Self.withCheckpointPair(ack: [
            "event": PrivacyLabConfigChangeCheckpoint.ackEvent,
            "nonce": "nonce-ok",
            "schema_version": PrivacyLabConfigChangeCheckpoint.schemaVersion,
            "extra": "nope",
        ]) { checkpoint in
            XCTAssertThrowsError(try checkpoint.signalReady(scope: scope)) {
                XCTAssertEqual($0 as? PrivacyLabConfigChangeCheckpointError, .malformed)
            }
        }

        try Self.withCheckpointPair(ack: [
            "event": PrivacyLabConfigChangeCheckpoint.ackEvent,
            "nonce": "nonce-ok",
            "schema_version": 0,
        ]) { checkpoint in
            XCTAssertThrowsError(try checkpoint.signalReady(scope: scope)) {
                XCTAssertEqual($0 as? PrivacyLabConfigChangeCheckpointError, .malformed)
            }
        }
    }

    func testOversizeAckIsRejected() throws {
        let scope = try Self.makeScope()
        let payload = Data(String(repeating: "x", count: PrivacyLabConfigChangeCheckpoint.maxFrameBytes + 1).utf8) + Data([0x0a])
        try Self.withCheckpointPair(rawAck: payload) { checkpoint in
            XCTAssertThrowsError(try checkpoint.signalReady(scope: scope)) {
                XCTAssertEqual($0 as? PrivacyLabConfigChangeCheckpointError, .oversized)
            }
        }
    }

    func testPeerClosedWriteFailsSafely() throws {
        let pair = try Self.makeSocketPair()
        let scope = try Self.makeScope()
        let checkpoint = try PrivacyLabConfigChangeCheckpoint(fd: pair.0, nonceFactory: { "nonce-ok" })
        Darwin.close(pair.1)
        defer { Darwin.close(pair.0) }

        XCTAssertThrowsError(try checkpoint.signalReady(scope: scope)) { error in
            XCTAssertEqual(error as? PrivacyLabConfigChangeCheckpointError, .writeFailed)
        }
    }

    func testAckTimeoutAndEOFAreRejected() throws {
        let scope = try Self.makeScope()
        let pair = try Self.makeSocketPair()
        defer {
            Darwin.close(pair.0)
            Darwin.close(pair.1)
        }
        let checkpoint = try PrivacyLabConfigChangeCheckpoint(fd: pair.0, nonceFactory: { "nonce-ok" })
        DispatchQueue.global(qos: .utility).async {
            _ = try? Self.readFrame(pair.1)
        }
        XCTAssertThrowsError(try checkpoint.signalReady(scope: scope)) { error in
            XCTAssertEqual(error as? PrivacyLabConfigChangeCheckpointError, .timeout)
        }

        try Self.withCheckpointPair(closeAfterReady: true) { eofCheckpoint in
            XCTAssertThrowsError(try eofCheckpoint.signalReady(scope: scope)) {
                XCTAssertEqual($0 as? PrivacyLabConfigChangeCheckpointError, .eof)
            }
        }
    }

    func testValidAckThenPeerCloseIsAccepted() throws {
        let scope = try Self.makeScope()
        try Self.withCheckpointPair(
            ack: [
                "event": PrivacyLabConfigChangeCheckpoint.ackEvent,
                "nonce": "nonce-ok",
                "schema_version": PrivacyLabConfigChangeCheckpoint.schemaVersion,
            ],
            closeAfterAck: true
        ) { checkpoint in
            XCTAssertNoThrow(try checkpoint.signalReady(scope: scope))
        }
    }

    func testIncompleteAckThenPeerCloseIsRejected() throws {
        let scope = try Self.makeScope()
        try Self.withCheckpointPair(rawAck: Data("{\"event\"".utf8), closeAfterAck: true) { checkpoint in
            XCTAssertThrowsError(try checkpoint.signalReady(scope: scope)) {
                XCTAssertEqual($0 as? PrivacyLabConfigChangeCheckpointError, .eof)
            }
        }
    }

    func testStalledReaderTimesOutReadyWrite() throws {
        let pair = try Self.makeSocketPair()
        defer {
            Darwin.close(pair.0)
            Darwin.close(pair.1)
        }
        var sendBuffer = 1
        guard setsockopt(pair.0, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        // Bound the fixture itself: the checkpoint deadline cannot protect a
        // prefill send that blocks before signalReady is called.
        let flags = Darwin.fcntl(pair.0, F_GETFL)
        guard flags >= 0, Darwin.fcntl(pair.0, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let bytes = [UInt8](repeating: 0x61, count: 4096)
        let prefillDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var bufferFull = false
        for _ in 0..<1024 {
            guard DispatchTime.now().uptimeNanoseconds < prefillDeadline else { break }
            let result = bytes.withUnsafeBytes { raw in
                Darwin.send(pair.0, raw.baseAddress, raw.count, MSG_DONTWAIT | MSG_NOSIGNAL)
            }
            if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                bufferFull = true
                break
            }
            if result < 0 && errno == EINTR {
                continue
            }
            if result <= 0 {
                break
            }
        }
        guard bufferFull else {
            XCTFail("socket prefill did not reach EAGAIN within its time/iteration budget")
            return
        }

        let scope = try Self.makeScope()
        let checkpoint = try PrivacyLabConfigChangeCheckpoint(fd: pair.0, nonceFactory: { "nonce-ok" })
        XCTAssertThrowsError(try checkpoint.signalReady(scope: scope)) { error in
            XCTAssertEqual(error as? PrivacyLabConfigChangeCheckpointError, .timeout)
        }
    }

    func testInvalidSocketTypeRejected() throws {
        var sockets: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_DGRAM, 0, &sockets) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer {
            Darwin.close(sockets[0])
            Darwin.close(sockets[1])
        }
        XCTAssertThrowsError(try PrivacyLabConfigChangeCheckpoint(fd: sockets[0])) {
            XCTAssertEqual($0 as? PrivacyLabConfigChangeCheckpointError, .invalidSocket)
        }
    }

    private static func withCheckpointPair(
        ack: [String: Any]? = nil,
        rawAck: Data? = nil,
        closeAfterReady: Bool = false,
        closeAfterAck: Bool = false,
        body: (PrivacyLabConfigChangeCheckpoint) throws -> Void
    ) throws {
        let pair = try Self.makeSocketPair()
        defer {
            Darwin.close(pair.0)
            Darwin.close(pair.1)
        }
        let checkpoint = try PrivacyLabConfigChangeCheckpoint(fd: pair.0, nonceFactory: { "nonce-ok" })
        DispatchQueue.global(qos: .utility).async {
            _ = try? Self.readFrame(pair.1)
            if closeAfterReady {
                Darwin.close(pair.1)
                return
            }
            if let rawAck {
                _ = rawAck.withUnsafeBytes { raw in
                    Darwin.write(pair.1, raw.baseAddress, raw.count)
                }
            } else if let ack {
                Self.writeFrame(ack, fd: pair.1)
            }
            if closeAfterAck {
                Darwin.close(pair.1)
            }
        }
        try body(checkpoint)
    }

    private static func makeScope() throws -> PrivacyLabIdentityScope {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("privacy-lab-checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let config = Self.labConfig(root: root)
        return try PrivacyLabIdentityScope.validated(config: config, isolateLifecycle: true)
    }

    private static func labConfig(root: URL) -> AppConfig {
        var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
        config.privacyClassBeta = true
        config.relayBlindEnabled = true
        config.credentialStore = .protectedFile
        config.coordinatorURL = "ws://127.0.0.1:19080/v2/provider"
        config.relayBlindStateDirectory = root.path
        return config
    }

    private static func makeSocketPair() throws -> (Int32, Int32) {
        var sockets: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return (sockets[0], sockets[1])
    }

    private static func readFrame(_ fd: Int32) throws -> [String: Any] {
        var bytes: [UInt8] = []
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            guard count > 0 else { throw POSIXError(.EIO) }
            if byte == 0x0a { break }
            bytes.append(byte)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
    }

    private static func writeFrame(_ frame: [String: Any], fd: Int32) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame) + Data([0x0a]) else { return }
        data.withUnsafeBytes { raw in
            _ = Darwin.write(fd, raw.baseAddress, raw.count)
        }
    }

    private static func fdIsClosed(_ fd: Int32) -> Bool {
        errno = 0
        return Darwin.fcntl(fd, F_GETFD) == -1 && errno == EBADF
    }
}
