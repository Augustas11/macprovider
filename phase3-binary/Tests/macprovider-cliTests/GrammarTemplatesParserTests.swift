import XCTest
import MacProviderCore
@testable import macprovider_cli

final class GrammarTemplatesParserTests: XCTestCase {
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
            (.deepseekV4, #"<｜DSML｜tool_calls><｜DSML｜invoke name="f"><｜DSML｜parameter name="city" string="true">Paris</｜DSML｜parameter><｜DSML｜parameter name="data" string="false">[{"ok":true}]</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜tool_calls>"#)
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
