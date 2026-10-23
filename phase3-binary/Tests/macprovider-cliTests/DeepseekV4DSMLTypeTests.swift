import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Declared DSML types govern both the final parser and the streaming serial-stop observer.
final class DeepseekV4DSMLTypeTests: XCTestCase {
    private static let model = "deepseek/deepseek-v4-flash"

    private func schemas(_ type: String) throws -> [String: MacProviderCore.JSONValue] {
        ["check": try MacProviderCore.JSONValue.parse([
            "type": "object", "properties": ["value": ["type": type]],
        ])]
    }

    private func block(_ value: String, string: Bool) -> String {
        """
        <｜DSML｜tool_calls>
        <｜DSML｜invoke name="check">
        <｜DSML｜parameter name="value" string="\(string)">\(value)</｜DSML｜parameter>
        </｜DSML｜invoke>
        </｜DSML｜tool_calls>
        """
    }

    func testDeclaredNonStringTypesRejectInvalidValuesForEitherStringFlag() throws {
        let invalid = [
            ("integer", "five"), ("integer", "1.5"), ("number", "NaN"),
            ("boolean", "yes"), ("object", "[]"), ("array", "{}"), ("null", "false"),
        ]
        for (type, value) in invalid {
            let declared = try schemas(type)
            for flag in [true, false] {
                let text = block(value, string: flag)
                let context = "type=\(type), value=\(value), string=\(flag)"
                XCTAssertThrowsError(try ToolCallParser.parseDSMLCalls(text, schemas: declared), context)
                let parsed = ToolCallParser.parseToolCalls(
                    rawOutput: text, grammar: .dsml, modelID: Self.model,
                    allowedFunctionNames: ["check"], schemas: declared
                )
                XCTAssertTrue(parsed.toolCalls.isEmpty, context)
            }
        }
    }

    func testStreamingDoesNotCompleteADeclaredTypeMismatch() throws {
        for (type, value) in [("integer", "five"), ("boolean", "yes"), ("object", "[]")] {
            for flag in [true, false] {
                var emitter = NativeToolCallStreamEmitter(
                    modelID: Self.model, grammar: .dsml,
                    allowedFunctionNames: ["check"], schemas: try schemas(type)
                )
                // Observe growing output, including the completed block used to stop serial turns.
                var prefix = ""
                for character in block(value, string: flag) {
                    prefix.append(character)
                    XCTAssertTrue(emitter.observe(prefix).isEmpty)
                    XCTAssertFalse(emitter.hasCompletedValidToolCall, "type=\(type), string=\(flag)")
                }
                XCTAssertTrue(emitter.suppressesAssistantContent)
            }
        }
    }

    func testStringFlagPreservesValidDeclaredTypesAndLiteralStringFallback() throws {
        for (type, value) in [
            ("integer", "5"), ("number", "1.5"), ("boolean", "true"),
            ("object", "{}"), ("array", "[]"), ("null", "null"),
        ] {
            let declared = try schemas(type)
            let text = block(value, string: true)
            let calls = try ToolCallParser.parseDSMLCalls(text, schemas: declared)
            XCTAssertEqual(calls.first?.arguments, "{\"value\":\(value)}", type)
            var emitter = NativeToolCallStreamEmitter(
                modelID: Self.model, grammar: .dsml, allowedFunctionNames: ["check"], schemas: declared
            )
            XCTAssertTrue(emitter.observe(text).isEmpty)
            XCTAssertTrue(emitter.hasCompletedValidToolCall, type)
        }
        let literal = block("five", string: true)
        XCTAssertEqual(try ToolCallParser.parseDSMLCalls(literal, schemas: schemas("string")).first?.arguments, #"{"value":"five"}"#)
        XCTAssertEqual(try ToolCallParser.parseDSMLCalls(literal, schemas: nil).first?.arguments, #"{"value":"five"}"#)
    }
}
