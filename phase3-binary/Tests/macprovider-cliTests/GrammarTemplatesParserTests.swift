import XCTest
import MacProviderCore
@testable import macprovider_cli

final class GrammarTemplatesParserTests: XCTestCase {
    func testEveryFamilySynthesizesUndeclaredRequiredProperties() throws {
        for family in ToolCallGrammar.allCases {
            let raw = #"{"model":"test","messages":[{"role":"user","content":"test"}],"max_tokens":100,"tool_choice":"required","tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","required":["city"]}}}]}"#
            let request = try ChatCompletionRequest.parse(data: Data(raw.utf8))
            let grammar = try XCTUnwrap(GrammarTemplates.grammar(for: request, traits: RequestOutputTraits(toolGrammar: family)))
            let dfa = try grammar.compile()
            let call = requestCall(name: "f", family: family)
                .replacingOccurrences(of: "<|\"|>Paris<|\"|>", with: "true")
                .replacingOccurrences(of: "\"Paris\"", with: "true")
                .replacingOccurrences(of: ">Paris<", with: ">true<")
                .replacingOccurrences(of: "string=\"true\"", with: "string=\"false\"")
            XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(call.utf8)))), family.rawValue)
            if family != .harmony {
                let parsed = ToolCallParser.parseToolCalls(rawOutput: call, grammar: family, modelID: "test", allowedFunctionNames: ["f"], schemas: ["f": .object(["type": .string("object"), "required": .array([.string("city")])])])
                let result = try XCTUnwrap(parsed.toolCalls.first, family.rawValue)
                XCTAssertEqual(try StrictJSONParser.parse(result.arguments), .object(["city": .bool(true)]))
            }
        }
    }

    func testMalformedRequiredPropertyNamesRejectBeforeGeneration() throws {
        let raw = #"{"model":"test","messages":[{"role":"user","content":"test"}],"max_tokens":100,"tool_choice":"required","tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","required":[3]}}}]}"#
        let request = try ChatCompletionRequest.parse(data: Data(raw.utf8))
        XCTAssertThrowsError(try GrammarTemplates.grammar(for: request, traits: RequestOutputTraits(toolGrammar: .qwen))) { error in
            XCTAssertEqual((error as? APIError)?.status, 400)
        }
    }

    func testEveryFamilyRequestRootObjectEnumConstrainsArguments() throws {
        let parameters: [String: Any] = [
            "type": "object", "properties": ["city": ["type": "string", "enum": ["Paris", "Tokyo"]]],
            "required": ["city"], "additionalProperties": false,
            "enum": [["city": "Paris"], ["city": 3], ["wrong": "Paris"]]
        ]
        let tools: [[String: Any]] = [["type": "function", "function": ["name": "f", "parameters": parameters]]]
        for family in ToolCallGrammar.allCases {
            let body: [String: Any] = ["model": "test", "messages": [["role": "user", "content": "test"]],
                "max_tokens": 100, "tools": tools, "tool_choice": "required"]
            let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
            let grammar = try XCTUnwrap(GrammarTemplates.grammar(for: request, traits: RequestOutputTraits(toolGrammar: family)))
            let dfa = try grammar.compile()
            let call = requestCall(name: "f", family: family)
            XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(call.utf8)))), family.rawValue)
            XCTAssertNil(dfa.transition(state: 0, bytes: Array(call.replacingOccurrences(of: "Paris", with: "Tokyo").utf8)), family.rawValue)
            // Even though the child schema admits Tokyo, the root object enum
            // admits only the complete Paris instance.
            let schema = try JSONValue.parse(parameters)
            try JSONSchemaValidator.validateInstance(.object(["city": .string("Paris")]), against: schema)
        }
    }

    func testRootObjectEnumWithoutCompatibleValuesRejectsBeforeGeneration() throws {
        let raw = #"{"model":"test","messages":[{"role":"user","content":"test"}],"max_tokens":100,"tool_choice":"required","tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false,"enum":[{"city":3}]}}}]}"#
        let request = try ChatCompletionRequest.parse(data: Data(raw.utf8))
        for family in ToolCallGrammar.allCases {
            XCTAssertThrowsError(try GrammarTemplates.grammar(for: request, traits: RequestOutputTraits(toolGrammar: family))) { error in
                XCTAssertEqual((error as? APIError)?.status, 400)
            }
        }
    }

    func testEveryFamilyRequiredAndNamedRequestTemplatesParseCalls() throws {
        let schema = JSONValue.object(["type": .string("object"), "properties": .object([
            "city": .object(["type": .string("string"), "enum": .array([.string("Paris"), .string("Tokyo")])])
        ]), "required": .array([.string("city")]), "additionalProperties": .bool(false)])
        let tools: [[String: Any]] = ["f", "g"].map { name in
            ["type": "function", "function": ["name": name, "parameters": schema.jsonObject]]
        }
        for family in ToolCallGrammar.allCases {
            for named in [false, true] {
                let choice: Any = named ? ["type": "function", "function": ["name": "f"]] : "required"
                let body: [String: Any] = [
                    "model": "test", "messages": [["role": "user", "content": "test"]],
                    "max_tokens": 100, "tools": tools, "tool_choice": choice
                ]
                let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
                let grammar = try XCTUnwrap(GrammarTemplates.grammar(for: request, traits: RequestOutputTraits(toolGrammar: family)))
                let dfa = try grammar.compile()
                let call = requestCall(name: "f", family: family)
                XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(call.utf8)))), "\(family) named=\(named)")
                let other = requestCall(name: "g", family: family)
                if named {
                    XCTAssertNil(dfa.transition(state: 0, bytes: Array(other.utf8)), family.rawValue)
                } else {
                    XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(other.utf8)))), family.rawValue)
                }
                let parsedCalls: [macprovider_cli.ToolCall]
                if family == .harmony {
                    let textByID: [Int: String] = [
                        HarmonyResponseParser.startTokenID: "<|start|>", 1: "assistant to=functions.f",
                        HarmonyResponseParser.channelTokenID: "<|channel|>", 2: "commentary",
                        HarmonyResponseParser.messageTokenID: "<|message|>", 3: #"{"city":"Paris"}"#,
                        HarmonyResponseParser.callTokenID: "<|call|>"
                    ]
                    let tokens = [HarmonyResponseParser.startTokenID, 1, HarmonyResponseParser.channelTokenID, 2,
                                  HarmonyResponseParser.messageTokenID, 3, HarmonyResponseParser.callTokenID]
                    let decode: ([Int]) -> String = { $0.map { textByID[$0] ?? "" }.joined() }
                    XCTAssertEqual(decode(tokens), call)
                    let parsed = HarmonyResponseParser.parse(tokenIDs: tokens, decode: decode, allowedFunctionNames: ["f", "g"])
                    XCTAssertEqual(parsed.status, .parsed)
                    parsedCalls = parsed.toolCalls
                } else {
                    parsedCalls = ToolCallParser.parseToolCalls(rawOutput: call, grammar: family, modelID: "test", allowedFunctionNames: ["f", "g"], schemas: ["f": schema, "g": schema]).toolCalls
                }
                XCTAssertEqual(parsedCalls.count, 1)
                let parsedCall = try XCTUnwrap(parsedCalls.first, family.rawValue)
                XCTAssertEqual(parsedCall.functionName, "f")
                XCTAssertEqual(try StrictJSONParser.parse(parsedCall.arguments), .object(["city": .string("Paris")]))
            }
        }
    }

    private func requestCall(name: String, family: ToolCallGrammar) -> String {
        switch family {
        case .qwen: return "<tool_call>{\"name\":\"" + name + "\",\"arguments\":{\"city\":\"Paris\"}}</tool_call>"
        case .llama3: return "{\"name\":\"" + name + "\",\"parameters\":{\"city\":\"Paris\"}}"
        case .glm: return "<tool_call>" + name + "<arg_key>city</arg_key><arg_value>Paris</arg_value></tool_call>"
        case .gemma4: return "<|tool_call>call:" + name + "{<|\"|>city<|\"|>:<|\"|>Paris<|\"|>}<tool_call|>"
        case .harmony: return "<|start|>assistant to=functions." + name + "<|channel|>commentary<|message|>{\"city\":\"Paris\"}<|call|>"
        case .dsml: return "<｜DSML｜tool_calls><｜DSML｜invoke name=\"" + name + "\"><｜DSML｜parameter name=\"city\" string=\"true\">Paris</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜tool_calls>"
        }
    }

    func testHarmonyStructuredFormatsRoundTripFinalFrames() throws {
        let formats = [
            #"{"type":"json_object"}"#,
            #"{"type":"json_schema","json_schema":{"name":"result","strict":true,"schema":{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}}}"#
        ]
        for format in formats {
            let raw = "{\"model\":\"mlx-community/gpt-oss-20b\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}],\"response_format\":" + format + "}"
            let request = try ChatCompletionRequest.parse(data: Data(raw.utf8))
            let grammar = try XCTUnwrap(GrammarTemplates.grammar(for: request, traits: RequestOutputTraits(toolGrammar: .harmony)))
            let body = #"{"ok":true}"#
            let textByID: [Int: String] = [
                HarmonyResponseParser.startTokenID: "<|start|>", 1: "assistant",
                HarmonyResponseParser.channelTokenID: "<|channel|>", 2: "final",
                HarmonyResponseParser.messageTokenID: "<|message|>", 3: body,
                HarmonyResponseParser.returnTokenID: "<|return|>"
            ]
            let tokens = [HarmonyResponseParser.startTokenID, 1, HarmonyResponseParser.channelTokenID, 2,
                          HarmonyResponseParser.messageTokenID, 3, HarmonyResponseParser.returnTokenID]
            let decode: ([Int]) -> String = { $0.map { textByID[$0] ?? "" }.joined() }
            let dfa = try grammar.compile()
            XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(decode(tokens).utf8)))))
            XCTAssertNil(dfa.transition(state: 0, bytes: Array(body.utf8)))
            let parsed = HarmonyResponseParser.parse(tokenIDs: tokens, decode: decode)
            XCTAssertEqual(parsed.status, .parsed)
            XCTAssertEqual(parsed.content, body)
            XCTAssertTrue(parsed.toolCalls.isEmpty)
        }
    }

    func testFamilyTemplatesRoundTripNestedTypedArguments() throws {
        let parameters = JSONValue.object(["type": .string("object"), "unsupported": .bool(true), "properties": .object([
            "city": .object(["type": .string("string"), "enum": .array([.string("Paris"), .string("Tokyo")])]),
            "data": .object(["type": .string("array"), "items": .object(["type": .string("object"), "properties": .object(["ok": .object(["type": .string("boolean")])])])])
        ])])
        let examples: [(ToolCallGrammar, String)] = [
            (.qwen, #"<tool_call>{"name":"f","arguments":{"city":"Paris","data":[{"ok":true}]}}</tool_call>"#),
            (.llama3, #"{"name":"f","parameters":{"city":"Paris","data":[{"ok":true}]}}"#),
            (.glm, #"<tool_call>f<arg_key>city</arg_key><arg_value>Paris</arg_value><arg_key>data</arg_key><arg_value>[{"ok":true}]</arg_value></tool_call>"#),
            (.gemma4, "<|tool_call>call:f{<|\"|>city<|\"|>:<|\"|>Paris<|\"|>,<|\"|>data<|\"|>:[{<|\"|>ok<|\"|>:true}]}<tool_call|>"),
            (.dsml, #"<｜DSML｜tool_calls><｜DSML｜invoke name="f"><｜DSML｜parameter name="city" string="true">Paris</｜DSML｜parameter><｜DSML｜parameter name="data" string="false">[{"ok":true}]</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜tool_calls>"#)
        ]
        for (family, text) in examples {
            let dfa = try GrammarTemplates.toolCall(name: "f", parameters: parameters, family: family).compile()
            XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(text.utf8)))))
            let parsed = ToolCallParser.parseToolCalls(rawOutput: text, grammar: family, modelID: "test", allowedFunctionNames: ["f"], schemas: ["f": parameters])
            let call = try XCTUnwrap(parsed.toolCalls.first, family.rawValue)
            XCTAssertEqual(call.functionName, "f")
            XCTAssertEqual(try StrictJSONParser.parse(call.arguments), .object(["city": .string("Paris"), "data": .array([.object(["ok": .bool(true)])])]))
            let invalid = text.replacingOccurrences(of: "Paris", with: "London")
            XCTAssertNil(dfa.transition(state: 0, bytes: Array(invalid.utf8)), family.rawValue)
        }
    }
}
