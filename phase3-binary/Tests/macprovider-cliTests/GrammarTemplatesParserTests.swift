import XCTest
import MacProviderCore
@testable import macprovider_cli

final class GrammarTemplatesParserTests: XCTestCase {
    func testFamilyTemplatesRoundTripNestedTypedArguments() throws {
        let parameters = JSONValue.object(["type": .string("object"), "properties": .object([
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
