import Darwin
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
}
