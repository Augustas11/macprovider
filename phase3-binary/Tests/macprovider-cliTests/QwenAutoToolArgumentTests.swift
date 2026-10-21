import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class QwenAutoToolArgumentTests: XCTestCase {
    private let model = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"

    private func schemas(type: JSONValue?) -> [String: JSONValue] {
        var property: [String: JSONValue] = [:]
        property["type"] = type
        return ["lookup": .object([
            "type": .string("object"), "properties": .object(["value": .object(property)]),
        ])]
    }

    private func xml(_ value: String) -> String {
        "<tool_call><function=lookup><parameter=value>\(value)</parameter></function></tool_call>"
    }

    private func arguments(_ raw: String, schemas: [String: JSONValue]?) -> String? {
        ToolCallParser.parseToolCalls(
            rawOutput: raw, modelID: model, allowedFunctionNames: ["lookup"], schemas: schemas
        ).toolCalls.first?.arguments
    }

    private func argumentFragments(_ events: [StreamChunk]) -> String {
        events.compactMap { event in
            if case .toolCallDelta(let delta) = event { return delta.arguments }
            return nil
        }.joined()
    }

    private func request(type: String, stream: Bool = false) throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [["role": "user", "content": "Look up a value"]],
            "tool_choice": "auto", "stream": stream,
            "tools": [["type": "function", "function": ["name": "lookup", "parameters": [
                "type": "object", "properties": ["value": ["type": type]],
            ]]]],
        ]))
    }

    func testStringValuesPreserveLiteralTextAndOnlyStripFramingNewlines() throws {
        let schema = schemas(type: .string("string"))
        let fixtures = [
            ("42", "42"), ("true", "true"), ("false", "false"), ("null", "null"),
            (#"{"n":1}"#, #"{"n":1}"#), (#""quoted""#, #""quoted""#),
            ("  padded \t ", "  padded \t "), ("", ""), ("  \t ", "  \t "),
            ("\n  42 \t\n", "  42 \t"), ("\r\n true \r\n", " true "),
            ("\n\nkept\n\n", "\nkept\n"),
        ]
        for (raw, expected) in fixtures {
            let result = try XCTUnwrap(arguments(xml(raw), schemas: schema))
            XCTAssertEqual(try StrictJSONParser.parse(result), .object(["value": .string(expected)]))
        }
    }

    func testExplicitTypesDecodeStrictStructuredAndScalarJSON() throws {
        let fixtures: [(String, String, JSONValue)] = [
            ("integer", "-42", .int(-42)), ("number", "1.25", .double(1.25)),
            ("number", "3e2", .double(300)), ("boolean", "false", .bool(false)),
            ("null", "null", .null),
            ("object", #"{"z":[1,true,null],"a":{"n":2}}"#,
             .object(["z": .array([.int(1), .bool(true), .null]), "a": .object(["n": .int(2)])])),
            ("array", #"["42",{"ok":true},2]"#,
             .array([.string("42"), .object(["ok": .bool(true)]), .int(2)])),
        ]
        for (type, raw, expected) in fixtures {
            let result = try XCTUnwrap(arguments(xml("\n\(raw)\n"), schemas: schemas(type: .string(type))))
            // Foundation canonicalization can render an integral Double as an integer.
            XCTAssertEqual(result, try JSONValue.object(["value": expected]).deterministicJSONString())
        }
    }

    func testFinalStreamingAndSerialStopUseIdenticalTypedDecoding() throws {
        for (type, value) in [("string", "\n 42 \n"), ("string", "true"),
                              ("object", #"{"z":1,"a":[true,"42"]}"#), ("array", "[1,2]"),
                              ("number", "1.5"), ("boolean", "true")] {
            let schema = schemas(type: .string(type))
            let raw = xml(value)
            let expected = try XCTUnwrap(arguments(raw, schemas: schema))
            var emitter = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["lookup"], schemas: schema)
            var observer = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["lookup"], schemas: schema)
            var prefix = ""
            var emitted = ""
            for character in raw {
                prefix.append(character)
                emitted += argumentFragments(emitter.observe(prefix))
                let stopped = ModelRuntime.observeSerialToolStop(
                    &observer, decoded: prefix, stopTokenFilter: StopTokenFilter(tokens: []), requestStops: []
                )
                XCTAssertEqual(stopped, prefix.contains("</function>"))
            }
            XCTAssertEqual(emitted, expected)
            XCTAssertTrue(emitter.hasCompletedValidToolCall)
        }
    }

    func testInvalidTypedValuesNeverCompleteStreamingOrSerialStop() {
        let fixtures = [
            ("integer", "1.5"), ("integer", #""42""#), ("number", "true"),
            ("boolean", "True"), ("boolean", "1"), ("object", "[]"),
            ("array", "{}"), ("null", #""null""#), ("number", "NaN"),
            ("object", #"{"x":1,"x":2}"#), ("object", #"{"nested":{"x":1,"x":2}}"#),
            ("object", #"{"n":9007199254740992}"#), ("number", "1e100"),
            ("array", String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)),
            ("string", "<function=other>"),
        ]
        for (type, value) in fixtures {
            assertMalformed(xml(value), schemas: schemas(type: .string(type)))
        }
        assertMalformed(
            "<function=lookup><parameter=value>42</function>", schemas: schemas(type: .string("string"))
        )
        assertMalformed(
            "<function=lookup><parameter=value>one</parameter><parameter=value>two</parameter></function>",
            schemas: schemas(type: .string("string"))
        )
    }

    private func assertMalformed(_ raw: String, schemas: [String: JSONValue], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(arguments(raw, schemas: schemas), file: file, line: line)
        var emitter = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["lookup"], schemas: schemas)
        XCTAssertTrue(emitter.observe(raw).isEmpty, file: file, line: line)
        XCTAssertFalse(emitter.hasCompletedValidToolCall, file: file, line: line)
        var observer = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["lookup"], schemas: schemas)
        XCTAssertFalse(ModelRuntime.observeSerialToolStop(
            &observer, decoded: raw, stopTokenFilter: StopTokenFilter(tokens: []), requestStops: []
        ), file: file, line: line)
    }

    func testTypedArgumentsRespectFinalByteCaps() throws {
        let schema = schemas(type: .string("string"))
        let overhead = #"{"value":""}"#.utf8.count
        let withinCap = xml(String(repeating: "x", count: ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP - overhead))
        let result = try XCTUnwrap(arguments(withinCap, schemas: schema))
        XCTAssertEqual(result.utf8.count, ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP)
        assertMalformed(xml(String(repeating: "x", count: ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP)), schemas: schema)
        XCTAssertNil(arguments(withinCap + withinCap + xml("x"), schemas: schema), "Response cap must remain enforced")
    }

    func testTypedArgumentContainerDepthKeepsExistingInclusiveBoundary() {
        let schema = schemas(type: .string("array"))
        let nested = String(repeating: "[", count: 31) + "0" + String(repeating: "]", count: 31)
        XCTAssertNotNil(arguments(xml(nested), schemas: schema), "31 arrays plus the arguments object have depth 32")
        assertMalformed(xml("[" + nested + "]"), schemas: schema)
    }

    func testUntypedAmbiguousAndUndeclaredParametersRetainAutoDecoding() {
        let raw = xml(" 42 ")
        for schema in [nil, [:], schemas(type: nil), schemas(type: .array([.string("string"), .string("number")])),
                       ["lookup": .object(["properties": .object([:])])]] as [[String: JSONValue]?] {
            XCTAssertEqual(arguments(raw, schemas: schema), #"{"value":42}"#)
        }
        // A typed property does not turn auto into required/enum/additionalProperties validation.
        let schema: [String: JSONValue] = ["lookup": .object([
            "type": .string("object"), "required": .array([.string("missing")]),
            "properties": .object(["value": .object(["type": .string("string"), "enum": .array([.string("other")])])]),
        ])]
        XCTAssertEqual(arguments(xml("42"), schemas: schema), #"{"value":"42"}"#)
        XCTAssertEqual(arguments(#"<tool_call>{"name":"lookup","arguments":{"value":42}}</tool_call>"#, schemas: schema), #"{"value":42}"#)
    }

    func testSchemasReachProductionFinalParserAndContinuousBatchStopObserver() throws {
        let request = try request(type: "string")
        let raw = xml("42")
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: raw, generatedTokenIDs: [], decode: { _ in "" }, request: request,
            mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: nil
        )
        XCTAssertEqual(parsed.toolCalls.first?.arguments, #"{"value":"42"}"#)
        let invalidRequest = try self.request(type: "integer")
        let invalidRaw = xml("wrong")
        let stop = ModelRuntime.ContinuousBatchSerialToolStopState(
            request: invalidRequest,
            incrementalDecoder: ModelRuntime.IncrementalTextDecoder(decodeToken: { _ in invalidRaw })
        )
        XCTAssertFalse(stop.observe(eventTokens: [0], stopTokenFilter: StopTokenFilter(tokens: []), requestStops: []))
        XCTAssertNil(stop.stopTokenCount)
    }

    func testDuplicateToolNamesDoNotChooseAnArbitrarySchema() throws {
        let parameters = try XCTUnwrap(schemas(type: .string("string"))["lookup"])
        let tool: JSONValue = .object(["type": .string("function"), "function": .object([
            "name": .string("lookup"), "parameters": parameters,
        ])])
        XCTAssertEqual(ModelRuntime.autoToolParameterSchemas(from: .array([tool, tool, tool])), [:])
        XCTAssertEqual(ModelRuntime.autoToolParameterSchemas(from: .array([tool])), ["lookup": parameters])
    }

    func testQwenRecoveryKeepsTypedStringsAndDoesNotBroadenFamilyOrAllowlist() {
        let schema = schemas(type: .string("string"))
        let bare = "<function=lookup><parameter=value>42</parameter></function>"
        for raw in [bare, "<tool_call>" + bare] {
            XCTAssertEqual(arguments(raw, schemas: schema), #"{"value":"42"}"#)
        }
        XCTAssertTrue(ToolCallParser.parseToolCalls(
            rawOutput: xml("42"), modelID: "unrelated-model", allowedFunctionNames: ["lookup"], schemas: schema
        ).toolCalls.isEmpty)
        var emitter = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["other"], schemas: schema)
        XCTAssertTrue(emitter.observe(xml("42")).isEmpty)
    }
}
