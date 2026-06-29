import XCTest
@testable import macprovider_cli

final class StreamingIdleTimeoutTests: XCTestCase {
    func testStructuredStreamingIdleTimeoutUsesDeferredSixtySecondDefault() {
        XCTAssertEqual(ModelRuntime.structuredStreamingIdleTimeoutSeconds, 60)
    }
}
