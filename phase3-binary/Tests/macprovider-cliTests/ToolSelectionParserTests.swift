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

    // #2014: Qwen3.6's chat template instructs function-XML, so the served model
    // emits it for required/named selection. This is the template's own rendering.
    private let qwen36Schemas: [String: JSONValue] = [
        "get_time": .object([
            "type": .string("object"),
            "properties": .object(["city": .object(["type": .string("string")])]),
            "required": .array([.string("city")]),
            "additionalProperties": .bool(false),
        ]),
        "lookup": .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("integer")]),
                "code": .object(["type": .string("string")]),
                "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            ]),
            "required": .array([.string("id"), .string("code"), .string("tags")]),
            "additionalProperties": .bool(false),
        ]),
    ]

    func testQwen36FunctionXMLEnvelopeParsesWithDeclaredSchemas() throws {
        let raw = "<tool_call>\n<function=get_time>\n<parameter=city>\nVilnius\n</parameter>\n</function>\n</tool_call>"
        let calls = try ToolCallParser.parseGuaranteedToolCalls(raw, schemas: qwen36Schemas)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].functionName, "get_time")
        XCTAssertEqual(calls[0].arguments, #"{"city":"Vilnius"}"#)

        let typed = "<tool_call>\n<function=lookup>\n<parameter=id>\n3\n</parameter>\n<parameter=code>\n007\n</parameter>\n<parameter=tags>\n[\"a\", \"b\"]\n</parameter>\n</function>\n</tool_call>"
        let call = try XCTUnwrap(ToolCallParser.parseGuaranteedToolCalls(typed, schemas: qwen36Schemas).first)
        XCTAssertEqual(try StrictJSONParser.parse(call.arguments), .object([
            "id": .int(3), "code": .string("007"), "tags": .array([.string("a"), .string("b")]),
        ]), "string parameters stay literal text; other parameters are strict JSON")

        let multiline = "<tool_call>\n<function=get_time>\n<parameter=city>\nNew\nYork\n</parameter>\n</function>\n</tool_call>"
        XCTAssertEqual(try ToolCallParser.parseGuaranteedToolCalls(multiline, schemas: qwen36Schemas).first?.arguments, #"{"city":"New\nYork"}"#)
        XCTAssertEqual(try ToolCallParser.parseGuaranteedToolCalls(raw + "\n" + raw, schemas: qwen36Schemas).count, 2)
    }

    func testQwen36FunctionXMLIsNotRepairedOrCoerced() throws {
        let get = { (body: String) in "<tool_call>\n<function=get_time>\n" + body + "</function>\n</tool_call>" }
        for raw in [
            "<tool_call>\n<function=get_time>\n<parameter=city>\nVilnius\n</parameter>\n</function>",
            "<tool_call>\n<function=get_time>\n<parameter=city>\nVilnius\n</parameter>\n</tool_call>",
            "<tool_call>\n<function=get_time>\n<parameter=city>\nVilnius\n</function>\n</tool_call>",
            get("<parameter=city>\nVilnius\n</parameter>\n") + "trailing",
            "Sure.\n" + get("<parameter=city>\nVilnius\n</parameter>\n"),
            get("<parameter=city>\nVilnius\n</parameter>\n<parameter=city>\nRiga\n</parameter>\n"),
            get("<parameter=country>\nLT\n</parameter>\n"),
            get("stray<parameter=city>\nVilnius\n</parameter>\n"),
            get("<parameter=city>\nVilnius\n<parameter=city2>\nx\n</parameter>\n"),
            get("<parameter=city>\nVilnius </tool_call>\n</parameter>\n"),
            "<tool_call>\n<function=get_weather>\n<parameter=city>\nVilnius\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=lookup>\n<parameter=id>\nthree\n</parameter>\n<parameter=code>\nx\n</parameter>\n<parameter=tags>\n[]\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=lookup>\n<parameter=id>\n9007199254740993\n</parameter>\n<parameter=code>\nx\n</parameter>\n<parameter=tags>\n[]\n</parameter>\n</function>\n</tool_call>",
        ] {
            XCTAssertThrowsError(try ToolCallParser.parseGuaranteedToolCalls(raw, schemas: qwen36Schemas), raw) { error in
                XCTAssertEqual((error as? APIError)?.code, "tool_selection_validation_failed")
            }
        }
        XCTAssertThrowsError(try ToolCallParser.parseGuaranteedToolCalls(get("<parameter=city>\nVilnius\n</parameter>\n")),
                             "without declared schemas a function-XML call cannot be typed")
    }
}
