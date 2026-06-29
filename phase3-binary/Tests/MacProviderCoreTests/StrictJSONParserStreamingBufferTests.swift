import MacProviderCore
import XCTest

final class StrictJSONParserStreamingBufferTests: XCTestCase {
    func testStrictJSONParserRejectsIncompleteStreamingBufferWithoutPanic() {
        XCTAssertThrowsError(try StrictJSONParser.parse(#"{"name":"Ada","#)) { error in
            XCTAssertFalse(String(describing: error).isEmpty)
        }
    }
}
