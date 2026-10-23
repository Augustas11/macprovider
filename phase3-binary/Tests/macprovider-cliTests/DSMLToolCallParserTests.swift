import XCTest
import MacProviderCore
@testable import macprovider_cli

final class DSMLToolCallParserTests: XCTestCase {
    func testTypedParametersAndMultipleCalls() throws {
        let raw = #"<｜DSML｜tool_calls><｜DSML｜invoke name="weather"><｜DSML｜parameter name="city" string="true">Paris</｜DSML｜parameter><｜DSML｜parameter name="days" string="false">2</｜DSML｜parameter></｜DSML｜invoke><｜DSML｜invoke name="clock"></｜DSML｜invoke></｜DSML｜tool_calls>"#
        let calls = try ToolCallParser.parseDSMLCalls(raw)
        XCTAssertEqual(calls.map(\.functionName), ["weather", "clock"])
        XCTAssertEqual(try StrictJSONParser.parse(calls[0].arguments), .object(["city": .string("Paris"), "days": .int(2)]))
    }
    func testRejectsMalformedDuplicateAndTrailingPayloads() {
        let call = #"<｜DSML｜tool_calls><｜DSML｜invoke name="f"><｜DSML｜parameter name="x" string="false">bad</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜tool_calls>"#
        XCTAssertThrowsError(try ToolCallParser.parseDSMLCalls(call))
        XCTAssertThrowsError(try ToolCallParser.parseDSMLCalls(call + "extra"))
        let duplicate = call.replacingOccurrences(of: "bad", with: "1</｜DSML｜parameter><｜DSML｜parameter name=\"x\" string=\"false\">2")
        XCTAssertThrowsError(try ToolCallParser.parseDSMLCalls(duplicate))
    }
}
