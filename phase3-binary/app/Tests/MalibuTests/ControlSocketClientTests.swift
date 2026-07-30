import Darwin
import Foundation
import XCTest
@testable import Malibu

final class ControlSocketClientTests: XCTestCase {
    func testConnectRejectsSocketPathTooLongBeforeSyscallTruncation() async {
        let path = "/" + String(repeating: "a", count: 103)
        XCTAssertEqual(path.utf8.count, 104)
        let client = ControlSocketClient(socketPath: path)

        do {
            try await client.connect(timeout: 0.1)
            XCTFail("expected ENAMETOOLONG for 104-byte Unix socket path")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .ENAMETOOLONG)
        } catch {
            XCTFail("expected POSIXError.ENAMETOOLONG, got \(error)")
        }
    }

    func testMalformedPeerFrameClosesTheStream() async throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer {
            close(sockets[0])
            close(sockets[1])
        }
        let readFD = sockets[0]
        let stream = AsyncStream<ControlFrame> { continuation in
            DispatchQueue.global(qos: .utility).async {
                ControlSocketClient.blockingReadLoop(
                    fd: readFD,
                    continuation: continuation
                )
            }
        }
        let malformed = Data(#"{"type":"future_referral_response"}"#.utf8) + Data([0x0A])
        try malformed.withUnsafeBytes { raw in
            guard Darwin.write(sockets[1], raw.baseAddress, raw.count) == raw.count else {
                throw POSIXError(.EIO)
            }
        }

        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertNil(next)
    }

    func testMalformedAndEOFPeersReleaseTheClientDescriptor() async throws {
        for payload in [
            Data(#"{"type":"future_referral_response"}"#.utf8) + Data([0x0A]),
            Data(),
        ] {
            let fixture = try UnixSocketFixture()
            defer { fixture.close() }
            let client = ControlSocketClient(socketPath: fixture.path)
            let accepted = Task.detached { try fixture.accept() }
            try await client.connect(timeout: 1)
            let peerFD = try await accepted.value
            let wasOpen = await client.hasOpenFileDescriptorForTesting()
            XCTAssertTrue(wasOpen)

            if payload.isEmpty {
                _ = Darwin.shutdown(peerFD, SHUT_RDWR)
            } else {
                try payload.withUnsafeBytes { raw in
                    guard Darwin.write(peerFD, raw.baseAddress, raw.count) == raw.count else {
                        throw POSIXError(.EIO)
                    }
                }
            }
            Darwin.close(peerFD)

            let stream = await client.stream
            var iterator = stream.makeAsyncIterator()
            let next = await iterator.next()
            XCTAssertNil(next)
            for _ in 0..<100 {
                if !(await client.hasOpenFileDescriptorForTesting()) { break }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            let remainsOpen = await client.hasOpenFileDescriptorForTesting()
            XCTAssertFalse(remainsOpen)
            await client.close()
        }
    }
}

private final class UnixSocketFixture: @unchecked Sendable {
    let path: String
    private let listenerFD: Int32

    init() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/tmp/malibu-\(getpid())-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("agent.sock").path
        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { throw POSIXError(.EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = strncpy($0, source, capacity - 1)
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, Darwin.listen(listenerFD, 1) == 0 else {
            Darwin.close(listenerFD)
            throw POSIXError(.EIO)
        }
    }

    func accept() throws -> Int32 {
        let fd = Darwin.accept(listenerFD, nil, nil)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        return fd
    }

    func close() {
        _ = Darwin.shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
        unlink(path)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
}
