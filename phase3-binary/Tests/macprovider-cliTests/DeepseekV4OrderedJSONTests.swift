import XCTest
@testable import macprovider_cli

final class DeepseekV4OrderedJSONTests: XCTestCase {
    func testSurrogatePairsRequireLowSurrogateBeforeCombining() throws {
        XCTAssertEqual(try DeepseekV4Encoding.parseJSON(#""\uD800\uDC00""#), .string("\u{10000}"))
        XCTAssertEqual(try DeepseekV4Encoding.parseJSON(#""\uDBFF\uDFFF""#), .string("\u{10FFFF}"))
        XCTAssertThrowsError(try DeepseekV4Encoding.parseJSON(#""\uD800\uE000""#))
        XCTAssertThrowsError(try DeepseekV4Encoding.parseJSON(#""\uD800\u0041""#))
    }
}
