import MacProviderCore
import XCTest

final class StrictJSONParserDepthTests: XCTestCase {
    func testArrayDepthBoundary() throws {
        XCTAssertNoThrow(try StrictJSONParser.parse(Self.nestedArrayJSON(jsonDepth: 32)))
        XCTAssertAPIError(try StrictJSONParser.parse(Self.nestedArrayJSON(jsonDepth: 33)), code: "json_schema_validation_failed")
    }

    func testObjectDepthBoundary() throws {
        XCTAssertNoThrow(try StrictJSONParser.parse(Self.nestedObjectJSON(jsonDepth: 32)))
        XCTAssertAPIError(try StrictJSONParser.parse(Self.nestedObjectJSON(jsonDepth: 33)), code: "json_schema_validation_failed")
    }

    func testMixedDepthBoundary() throws {
        XCTAssertNoThrow(try StrictJSONParser.parse(Self.mixedJSON(jsonDepth: 32)))
        XCTAssertAPIError(try StrictJSONParser.parse(Self.mixedJSON(jsonDepth: 33)), code: "json_schema_validation_failed")
    }

    private static func nestedArrayJSON(jsonDepth: Int) -> String {
        precondition(jsonDepth >= 1)
        return String(repeating: "[", count: jsonDepth - 1) + "0" + String(repeating: "]", count: jsonDepth - 1)
    }

    private static func nestedObjectJSON(jsonDepth: Int) -> String {
        precondition(jsonDepth >= 1)
        return String(repeating: #"{"a":"#, count: jsonDepth - 1) + "0" + String(repeating: "}", count: jsonDepth - 1)
    }

    private static func mixedJSON(jsonDepth: Int) -> String {
        precondition(jsonDepth >= 1)
        var suffix = ""
        var prefix = ""
        for level in 0..<(jsonDepth - 1) {
            if level.isMultiple(of: 2) {
                prefix += "["
                suffix = "]" + suffix
            } else {
                prefix += #"{"a":"#
                suffix = "}" + suffix
            }
        }
        return prefix + "0" + suffix
    }

    private func XCTAssertAPIError(
        _ expression: @autoclosure () throws -> JSONValue,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502, file: file, line: line)
            XCTAssertEqual(apiError?.code, code, file: file, line: line)
        }
    }
}
