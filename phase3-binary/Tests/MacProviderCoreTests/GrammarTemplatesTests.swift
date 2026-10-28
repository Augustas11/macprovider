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

    func testAdvisorySchemaHintsCannotRejectNonStrictPreparation() throws {
        let schemas = [
            #"{"type":"object","properties":{"optional":{"type":"integer","enum":["text"]}}}"#,
            #"{"type":"object","required":[3]}"#,
            #"{"type":"object","required":["missing"],"additionalProperties":false}"#
        ]
        for schema in schemas {
            let raw = "{\"model\":\"test\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}],\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"result\",\"strict\":false,\"schema\":" + schema + "}}}"
            let request = try ChatCompletionRequest.parse(data: Data(raw.utf8))
            let language = try XCTUnwrap(GrammarTemplates.grammar(for: request, traits: .unresolved))
            let dfa = try language.compile()
            for json in ["{}", "true", "[1]"] {
                XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(json.utf8)))))
            }
        }
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
        XCTAssertTrue(try accepts(string, #""\uD83D\uDE00""#))
        XCTAssertFalse(try accepts(string, #""\uD800""#))
        XCTAssertFalse(try accepts(string, #""\uDC00""#))
    }

    func testUnsupportedKeywordFallsBackToJSONWithoutProse() throws {
        let grammar = GrammarTemplates.schema(.object(["type": .string("string"), "pattern": .string("x")]))
        XCTAssertTrue(try accepts(grammar, #"{"nested":true}"#))
        XCTAssertFalse(try accepts(grammar, "Here is JSON: {}"))
    }

    func testGenericJSONObjectCannotGenerateDuplicateKeys() throws {
        let raw = #"{"model":"test","messages":[{"role":"user","content":"test"}],"response_format":{"type":"json_object"}}"#
        let request = try ChatCompletionRequest.parse(data: Data(raw.utf8))
        let grammar = try XCTUnwrap(GrammarTemplates.grammar(for: request, traits: .unresolved))
        XCTAssertTrue(try accepts(grammar, "{}"))
        XCTAssertTrue(try accepts(grammar, #"{"key":1}"#))
        XCTAssertFalse(try accepts(grammar, #"{"key":1,"key":2}"#))
    }

    func testDefaultCompileBudgetCoversStructuredAndFallbackLanguages() throws {
        for format in [#"{"type":"json_object"}"#, #"{"type":"json_schema","json_schema":{"name":"fallback","strict":false,"schema":{"type":"string","pattern":"x"}}}"#] {
            let request = try ChatCompletionRequest.parse(data: Data(("{\"model\":\"test\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}],\"response_format\":" + format + "}").utf8))
            _ = try XCTUnwrap(GrammarTemplates.grammar(for: request, traits: .unresolved)).compile()
        }
        let parameters = JSONValue.object(["type": .string("object"), "properties": .object(["value": .object(["pattern": .string("x")])]), "unsupported": .bool(true)])
        for family in ToolCallGrammar.allCases {
            _ = try GrammarTemplates.toolCall(name: "f", parameters: parameters, family: family).compile()
        }
    }

    func testEnumHonorsDeclaredTypeAndNumbersStayFinite() throws {
        let typedEnum = GrammarTemplates.schema(.object(["type": .string("integer"), "enum": .array([.int(2), .string("wrong")])]))
        XCTAssertTrue(try accepts(typedEnum, "2"))
        XCTAssertFalse(try accepts(typedEnum, #""wrong""#))
        let number = GrammarTemplates.schema(.object(["type": .string("number")]))
        XCTAssertTrue(try accepts(number, "123.45e-20"))
        XCTAssertFalse(try accepts(number, "1e999"))
        XCTAssertFalse(try accepts(number, "999999999999999999999999999999999999"))
    }

    func testStrictClosedObjectWithoutPropertiesOnlyAcceptsEmptyObject() throws {
        let raw = #"{"model":"test","messages":[{"role":"user","content":"test"}],"response_format":{"type":"json_schema","json_schema":{"name":"empty","strict":true,"schema":{"type":"object","additionalProperties":false}}}}"#
        let request = try ChatCompletionRequest.parse(data: Data(raw.utf8))
        let grammar = try XCTUnwrap(GrammarTemplates.grammar(for: request, traits: .unresolved))
        XCTAssertTrue(try accepts(grammar, "{}"))
        XCTAssertFalse(try accepts(grammar, #"{"key":1}"#))
        if case .jsonSchema(let spec) = request.responseFormat {
            XCTAssertNoThrow(try JSONSchemaValidator.validateInstance(.object([:]), against: spec.schema))
        } else { XCTFail("Expected strict schema") }
    }

    func testNonStrictRequiredPropertiesRemainAdvisory() throws {
        let raw = #"{"model":"test","messages":[{"role":"user","content":"test"}],"response_format":{"type":"json_schema","json_schema":{"name":"required","strict":false,"schema":{"type":"object","required":["missing"]}}}}"#
        let request = try ChatCompletionRequest.parse(data: Data(raw.utf8))
        let grammar = try XCTUnwrap(GrammarTemplates.grammar(for: request, traits: .unresolved))
        XCTAssertTrue(try accepts(grammar, #"{"missing":true}"#))
        XCTAssertTrue(try accepts(grammar, "{}"))
    }

    func testToolWithUndeclaredRequiredPropertyReceivesGenericValueGrammar() throws {
        let raw = #"{"model":"mlx-community/Qwen3.6-35B-A3B-4bit","messages":[{"role":"user","content":"test"}],"max_tokens":100,"tool_choice":"required","tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","required":["missing"]}}}]}"#
        let request = try ChatCompletionRequest.parse(data: Data(raw.utf8))
        let grammar = try XCTUnwrap(GrammarTemplates.grammar(for: request, traits: .unresolved))
        XCTAssertTrue(try accepts(grammar, #"<tool_call>{"name":"f","arguments":{"missing":true}}</tool_call>"#))
        XCTAssertFalse(try accepts(grammar, #"<tool_call>{"name":"f","arguments":{}}</tool_call>"#))
    }

    func testEveryFamilyHasACompleteCallLanguage() throws {
        let examples: [(ToolCallGrammar, String)] = [
            (.qwen, #"<tool_call>{"name":"weather","arguments":{"city":"Paris","count":2}}</tool_call>"#),
            (.lfm2, #"<|tool_call_start|>[weather(city="Paris",count=2)]<|tool_call_end|>"#),
            (.llama3, #"{"name":"weather","parameters":{"city":"Paris","count":2}}"#),
            (.glm, "<tool_call>weather<arg_key>city</arg_key><arg_value>Paris</arg_value><arg_key>count</arg_key><arg_value>2</arg_value></tool_call>"),
            (.gemma4, "<|tool_call>call:weather{<|\"|>city<|\"|>:<|\"|>Paris<|\"|>,<|\"|>count<|\"|>:2}<tool_call|>"),
            (.harmony, #"<|start|>assistant to=functions.weather<|channel|>commentary<|message|>{"city":"Paris","count":2}<|call|>"#),
            (.dsml, #"<｜DSML｜tool_calls><｜DSML｜invoke name="weather"><｜DSML｜parameter name="city" string="true">Paris</｜DSML｜parameter><｜DSML｜parameter name="count" string="false">2</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜tool_calls>"#)
        ]
        XCTAssertEqual(examples.count, ToolCallGrammar.allCases.count)
        for (family, text) in examples {
            XCTAssertTrue(try accepts(GrammarTemplates.toolCall(name: "weather", parameters: parameters, family: family), text), family.rawValue)
        }
    }
}
