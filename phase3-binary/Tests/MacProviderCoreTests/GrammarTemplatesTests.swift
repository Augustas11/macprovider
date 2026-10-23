import XCTest
@testable import MacProviderCore

final class GrammarTemplatesTests: XCTestCase {
    private let parameters = JSONValue.object([
        "type": .string("object"),
        "properties": .object(["city": .object(["type": .string("string")]), "count": .object(["type": .string("integer")])]),
        "required": .array([.string("city"), .string("count")]),
        "additionalProperties": .bool(false)
    ])

    private func accepts(_ grammar: ByteGrammar, _ text: String) throws -> Bool {
        let dfa = try grammar.compile()
        guard let state = dfa.transition(state: 0, bytes: Array(text.utf8)) else { return false }
        return dfa.accepting(state: state)
    }

    func testSchemaValuesAreGeneratedAndTyped() throws {
        let grammar = GrammarTemplates.schema(parameters)
        XCTAssertTrue(try accepts(grammar, #"{"city":"Paris","count":2}"#))
        XCTAssertTrue(try accepts(grammar, #"{"city":"Tokyo","count":-99}"#))
        for text in [#"{"city":2,"count":2}"#, #"{"city":"Paris"}"#, #"{"city":"Paris","count":1.2}"#, #"{"city":"Paris","count":02}"#, #"{"city":"Paris","count":2}junk"#] {
            XCTAssertFalse(try accepts(grammar, text), text)
        }
    }

    func testEnumsArraysBooleansAndEscapes() throws {
        let grammar = GrammarTemplates.schema(.object(["type": .string("array"), "items": .object(["enum": .array([.string("yes"), .bool(false)])])]))
        XCTAssertTrue(try accepts(grammar, #"["yes",false]"#))
        XCTAssertFalse(try accepts(grammar, #"["no"]"#))
        let string = GrammarTemplates.schema(.object(["type": .string("string")]))
        XCTAssertTrue(try accepts(string, #""escaped\n\u00e9""#))
        XCTAssertFalse(try accepts(string, "\"bad\nline\""))
    }

    func testUnsupportedKeywordFallsBackToJSONWithoutProse() throws {
        let grammar = GrammarTemplates.schema(.object(["type": .string("string"), "pattern": .string("x")]))
        XCTAssertTrue(try accepts(grammar, #"{"nested":[true,3]}"#))
        XCTAssertFalse(try accepts(grammar, "Here is JSON: {}"))
    }

    func testEveryFamilyHasACompleteCallLanguage() throws {
        let examples: [(ToolCallGrammar, String)] = [
            (.qwen, #"<tool_call>{"name":"weather","arguments":{"city":"Paris","count":2}}</tool_call>"#),
            (.llama3, #"{"name":"weather","parameters":{"city":"Paris","count":2}}"#),
            (.glm, "<tool_call>weather<arg_key>city</arg_key><arg_value>Paris</arg_value><arg_key>count</arg_key><arg_value>2</arg_value></tool_call>"),
            (.gemma4, "<|tool_call>call:weather{<|\"|>city<|\"|>:<|\"|>Paris<|\"|>,<|\"|>count<|\"|>:2}<tool_call|>"),
            (.harmony, #"<|start|>assistant to=functions.weather<|channel|>commentary<|message|>{"city":"Paris","count":2}<|call|>"#),
            (.deepseekV4, #"<｜DSML｜tool_calls><｜DSML｜invoke name="weather"><｜DSML｜parameter name="city" string="true">Paris</｜DSML｜parameter><｜DSML｜parameter name="count" string="false">2</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜tool_calls>"#)
        ]
        XCTAssertEqual(examples.count, ToolCallGrammar.allCases.count)
        for (family, text) in examples {
            XCTAssertTrue(try accepts(GrammarTemplates.toolCall(name: "weather", parameters: parameters, family: family), text), family.rawValue)
        }
    }
}
