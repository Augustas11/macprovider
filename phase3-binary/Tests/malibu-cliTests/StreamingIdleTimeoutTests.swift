import XCTest
@testable import malibu_cli

final class StreamingIdleTimeoutTests: XCTestCase {
    func testStructuredStreamingIdleTimeoutUsesDeferredSixtySecondDefault() {
        XCTAssertEqual(ModelRuntime.structuredStreamingIdleTimeoutSeconds, 60)
    }
}
