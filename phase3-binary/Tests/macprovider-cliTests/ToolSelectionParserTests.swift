import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ToolSelectionParserTests: XCTestCase {
    func testCompleteJSONEnvelopeAndMultipleCalls() throws {
        let call = #"<tool_call>{"name":"lookup","arguments":{"id":3}}</tool_call>"#
        XCTAssertEqual(try ToolCallParser.parseGuaranteedToolCalls(call).first?.arguments, #"{"id":3}"#)
        XCTAssertEqual(try ToolCallParser.parseGuaranteedToolCalls(call + "\n" + call).count, 2)
    }

    func testClosingMarkerInsideArgumentStringIsData() throws {
        let raw = #"<tool_call>{"name":"lookup","arguments":{"text":"literal </tool_call> token","nested":["<tool_call>"]}}</tool_call>"#
        let call = try XCTUnwrap(ToolCallParser.parseGuaranteedToolCalls(raw).first)
        XCTAssertEqual(try StrictJSONParser.parse(call.arguments), .object([
            "text": .string("literal </tool_call> token"),
            "nested": .array([.string("<tool_call>")]),
        ]))
        XCTAssertThrowsError(try ToolCallParser.parseGuaranteedToolCalls(raw + "</tool_call>"))
        XCTAssertThrowsError(try ToolCallParser.parseGuaranteedToolCalls(#"<tool_call>{"name":"lookup","arguments":{"text":"literal </tool_call>"}} garbage </tool_call>"#))
    }

    func testGuaranteedParserDoesNotRepairOrDropBadTrailingCalls() throws {
        let call = #"<tool_call>{"name":"lookup","arguments":{"id":3}}</tool_call>"#
        for raw in [
            #"<tool_call>{"name":"lookup","arguments":{"id":3}}"#,
            #"<tool_call><function=lookup><parameter=id>3</parameter></function></tool_call>"#,
            #"<tool_call>{"name":"lookup","arguments":"{}"}</tool_call>"#,
            #"<tool_call>{"name":"lookup","arguments":{}}</tool_call>trailing"#,
            call + #"<tool_call>{"name":"lookup","arguments":{"id":"#,
            call + #"<tool_call>{"name":"lookup","arguments":{},"extra":1}</tool_call>"#,
            #"<tool_call>{"name":"lookup","arguments":{"id":3,"id":4}}</tool_call>"#,
        ] {
            XCTAssertThrowsError(try ToolCallParser.parseGuaranteedToolCalls(raw)) { error in
                XCTAssertEqual((error as? APIError)?.code, "tool_selection_validation_failed")
            }
        }
    }

    func testGuaranteedEnvelopePreservesArgumentDepthAndRejectsUnsafeNumbersBeforeSerialization() throws {
        // Argument root plus 30 arrays plus scalar is the existing depth32.
        let nested = String(repeating: "[", count: 30) + "0" + String(repeating: "]", count: 30)
        let body = #"{"name":"lookup","arguments":{"nested":\#(nested)}}"#
        let calls = try ToolCallParser.parseGuaranteedToolCalls("<tool_call>" + body + "</tool_call>")
        XCTAssertEqual(calls.count, 1)
        XCTAssertNoThrow(try StrictJSONParser.parse(calls[0].arguments))
        for integer in ["9007199254740993", "-9223372036854775808"] {
            XCTAssertThrowsError(try ToolCallParser.parseGuaranteedToolCalls(#"<tool_call>{"name":"lookup","arguments":{"id":\#(integer)}}</tool_call>"#))
        }
    }

    func testAutoRecoveryRemainsAvailable() throws {
        let raw = #"<tool_call>{"name":"lookup","arguments":{"id":3}}"#
        XCTAssertEqual(ToolCallParser.parseToolCalls(rawOutput: raw, modelID: ToolSelectionPolicy.supportedNativeModel).toolCalls.count, 1)
        XCTAssertThrowsError(try ToolCallParser.parseGuaranteedToolCalls(raw))
    }
}
