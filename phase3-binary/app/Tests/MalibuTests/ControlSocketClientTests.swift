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
}
