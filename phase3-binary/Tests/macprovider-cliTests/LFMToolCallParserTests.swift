import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class LFMToolCallParserTests: XCTestCase {
    private func frame(_ body: String) -> String {
        LFMToolCallParser.startMarker + body + LFMToolCallParser.endMarker
    }

    func testOfficialTemplateSingleAndParallelCalls() throws {
        // LiquidAI/LFM2.5-24B-A2B-MLX-4bit@667408d renders a Pythonic
        // list, keyword arguments and single-quoted string values.
        let calls = try LFMToolCallParser.parse(frame(
            "[get_weather(city='Paris'), get_weather(city='London')]"))
        XCTAssertEqual(calls.map(\.functionName), ["get_weather", "get_weather"])
        XCTAssertEqual(calls.map(\.arguments), [#"{"city":"Paris"}"#, #"{"city":"London"}"#])
        XCTAssertNotEqual(calls[0].id, calls[1].id)
    }

    func testNestedJSONAndPythonScalars() throws {
        let calls = try LFMToolCallParser.parse(frame(
            #"[run(data={"items":[1,{"active":true,"value":null}],"note":"a,b)=]"}, yes=True, no=False, missing=None)]"#))
        XCTAssertEqual(calls.first?.arguments,
            #"{"data":{"items":[1,{"active":true,"value":null}],"note":"a,b)=]"},"yes":true,"no":false,"missing":null}"#)
    }

    func testVendorStringEscapingAndUnicode() throws {
        let call = try XCTUnwrap(LFMToolCallParser.parse(frame(
            #"[run(text='it\'s "quoted" \\ path\nnext\rline', unicode='café 🌴', escaped='\uD83C\uDF34')]"#)).first)
        let parsed = try StrictJSONParser.parse(call.arguments)
        guard case .object(let values) = parsed else { return XCTFail("arguments object") }
        XCTAssertEqual(values["text"], .string("it's \"quoted\" \\ path\nnext\rline"))
        XCTAssertEqual(values["unicode"], .string("café 🌴"))
        XCTAssertEqual(values["escaped"], .string("🌴"))
    }

    func testNumberLexemesAreNeverReconstructed() throws {
        let call = try XCTUnwrap(LFMToolCallParser.parse(frame(
            "[run(integer=9007199254740991, precise=0.123456789012345678901, exp=1.2300e-04, neg=-0.0)]")).first)
        XCTAssertEqual(call.arguments,
            #"{"integer":9007199254740991,"precise":0.123456789012345678901,"exp":1.2300e-04,"neg":-0.0}"#)
    }

    func testEnvelopeTextInsideStringsDoesNotTerminateCall() throws {
        let call = try XCTUnwrap(LFMToolCallParser.parse(frame(
            "[run(text='<|tool_call_end|> and <|tool_call_start|>')]")).first)
        XCTAssertEqual(call.arguments, #"{"text":"<|tool_call_end|> and <|tool_call_start|>"}"#)
    }

    func testMalformedOrExecutableDialectFailsClosed() {
        let invalid = [
            "[]", "[run('positional')]", "[run(a=1,a=2)]", "[run(a=1 + 2)]",
            "[run(a=other())]", "[module.run()]", "[run(**kwargs)]", "[run(a=[x for x in y])]",
            "[run(a={'python': True})]", "[run(a={\"x\":1,\"x\":2})]",
            "[run(a={\"x\":1,\"\\u0078\":2})]", "[run(a=NaN)]", "[run(a=Infinity)]",
            "[run(a=1e999)]", "[run(a=9007199254740992)]", "[run(a=01)]",
            "[run(a='\\q')]", "[run(a='\\uD800')]", "[run(a='unterminated)]",
            "[run(a=1,)]", "[run(),]", "[run(a=1)] trailing", "[run(a=1)]; import os",
            "[bad-name()]", "[1run()]", "[run(class=1)]", "[lambda()]", "[rún()]",
        ]
        for body in invalid {
            XCTAssertThrowsError(try LFMToolCallParser.parse(frame(body)), body)
        }
        for raw in [
            LFMToolCallParser.startMarker + "[run()]",
            frame("[run()]") + "junk",
            frame("[run()]") + frame("[run()]"),
            LFMToolCallParser.startMarker + "[run()]<|tool_call_end",
        ] {
            XCTAssertThrowsError(try LFMToolCallParser.parse(raw), raw)
        }
    }

    func testDepthAndArgumentByteBounds() {
        let nested = String(repeating: "[", count: 32) + "0" + String(repeating: "]", count: 32)
        XCTAssertThrowsError(try LFMToolCallParser.parse(frame("[run(a=\(nested))]")))
        let oversized = String(repeating: "x", count: ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP)
        XCTAssertThrowsError(try LFMToolCallParser.parse(frame("[run(a='\(oversized)')]")))
        let value = String(repeating: "x", count: 750_000)
        XCTAssertThrowsError(try LFMToolCallParser.parse(frame(
            "[run(a='\(value)'), run(a='\(value)'), run(a='\(value)')]")))
    }

    func testInclusiveArgumentByteAndDepthBoundaries() throws {
        let count = ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP - #"{"a":""}"#.utf8.count
        let value = String(repeating: "x", count: count)
        let calls = try LFMToolCallParser.parse(frame("[run(a='\(value)'), run(a='\(value)')]"))
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].arguments.utf8.count, ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP)
        XCTAssertEqual(calls.reduce(0) { $0 + $1.arguments.utf8.count },
                       ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP)
        // The returned argument object is depth 1; thirty arrays put the
        // scalar leaf exactly at depth 32.
        let nested = String(repeating: "[", count: 30) + "0" + String(repeating: "]", count: 30)
        XCTAssertEqual(try LFMToolCallParser.parse(frame("[run(a=\(nested))]")).count, 1)
    }

    func testCommonAllowlistDedupeAndLeadingProse() {
        let raw = "Checking now. " + frame("[run(a=1), run(a=1)]")
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw, grammar: .lfm2, modelID: "local-alias", allowedFunctionNames: ["run"])
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(parsed.leadingContent, "Checking now.")
        XCTAssertNil(parsed.cleanedContent)
        let denied = ToolCallParser.parseToolCalls(
            rawOutput: raw, grammar: .lfm2, modelID: "local-alias", allowedFunctionNames: ["other"])
        XCTAssertTrue(denied.toolCalls.isEmpty)
        XCTAssertEqual(denied.cleanedContent, raw)
    }

    func testCommonCallCountCapAndPartialEnvelopeHoldback() {
        let body = "[" + (0..<129).map { "run(a=\($0))" }.joined(separator: ",") + "]"
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: frame(body), grammar: .lfm2, modelID: "local-alias")
        XCTAssertEqual(parsed.toolCalls.count, 128)
        let full = frame("[run(a='ok')]")
        for end in full.indices.dropFirst() {
            let partial = String(full[..<end])
            let parsed = ToolCallParser.parseToolCalls(
                rawOutput: partial, grammar: .lfm2, modelID: "local-alias")
            XCTAssertTrue(parsed.toolCalls.isEmpty, partial)
        }
        XCTAssertEqual(ToolCallParser.callStartMarkers(.lfm2), [LFMToolCallParser.startMarker])
    }
}
