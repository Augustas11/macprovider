import Foundation
import XCTest
@testable import MacProviderCore

final class LFMToolGrammarTests: XCTestCase {
    func testLoadedTemplateSelectsLFMWithoutGuessingUnknownFamilies() {
        XCTAssertEqual(ToolCallGrammar.resolved(templateFormat: "lfm2", modelID: "alias"), .lfm2)
        XCTAssertEqual(ToolCallGrammar.family(modelID: "LiquidAI/LFM2.5-24B-A2B-MLX-4bit"), .lfm2)
        XCTAssertNil(ToolCallGrammar.family(modelID: "other/lfm2-unknown"))
        XCTAssertEqual(ToolCallGrammar.resolved(templateFormat: "json", modelID: "LiquidAI/LFM2.5-24B-A2B"), .qwen)
    }

    func testNativeMaskUsesListKeywordArgumentsAndTypedValues() throws {
        let parameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["city": .object(["type": .string("string")]), "count": .object(["enum": .array([.int(2)])])]),
            "required": .array([.string("city"), .string("count")])
        ])
        let dfa = try GrammarTemplates.toolCall(name: "weather", parameters: parameters, family: .lfm2).compile()
        func accepts(_ text: String) -> Bool {
            guard let state = dfa.transition(state: dfa.initialState, bytes: Array(text.utf8)) else { return false }
            return dfa.accepting(state: state)
        }
        XCTAssertTrue(accepts(#"<|tool_call_start|>[weather(city="Paris",count=2)]<|tool_call_end|>"#))
        for invalid in [#"<|tool_call_start|>[weather(city="Paris",count=3)]<|tool_call_end|>"#,
                        #"<|tool_call_start|>[weather(city="Paris")]<|tool_call_end|>"#,
                        #"<|tool_call_start|>[other(city="Paris",count=2)]<|tool_call_end|>"#,
                        #"<|tool_call_start|>[weather(city="Paris",count=2)]"#] {
            XCTAssertFalse(accepts(invalid), invalid)
        }
    }

    func testLFMIdentifiersAreValidatedOnlyAtUnquotedLevels() throws {
        for name in ["9name", "bad-name", "class", "é", ""] {
            XCTAssertThrowsError(try ToolSelectionPolicy.validateLFMNames([name: .object([:])]), name)
        }
        for key in ["9key", "bad-key", "True"] {
            XCTAssertThrowsError(try ToolSelectionPolicy.validateLFMNames(["f": .object(["properties": .object([key: .object([:])])])]), key)
        }
        try ToolSelectionPolicy.validateLFMNames(["_f2": .object(["properties": .object([
            "payload": .object(["type": .string("object"), "properties": .object(["nested-key": .object([:])])])
        ])])])
    }
    func testRequestModesValidateNativeNamesAndBuildGuaranteedMasks() throws {
        let model = "LiquidAI/LFM2.5-24B-A2B-MLX-4bit"
        for choice: Any in ["auto", "none", "required", ["type": "function", "function": ["name": "weather"]]] {
            let raw: [String: Any] = [
                "model": model, "messages": [["role": "user", "content": "Weather?"]], "max_tokens": 128,
                "tool_choice": choice,
                "tools": [["type": "function", "function": ["name": "weather", "parameters": ["type": "object", "properties": ["city": ["enum": ["Paris"]]], "required": ["city"]]]]]
            ]
            let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: raw))
            try ToolSelectionPolicy.validateRequest(request, loadedModelID: model, runtime: "mlx_cache")
            let selection = try ToolSelectionPolicy.selection(request.promptSource.toolChoice)
            let grammar = try GrammarTemplates.grammar(for: request, traits: .init(toolGrammar: .lfm2))
            XCTAssertEqual(grammar != nil, selection.requiresCall)
            if let grammar {
                let dfa = try grammar.compile()
                let text = #"<|tool_call_start|>[weather(city="Paris")]<|tool_call_end|>"#
                XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: dfa.initialState, bytes: Array(text.utf8)))))
            }
        }
        let raw: [String: Any] = ["model": model, "messages": [["role": "user", "content": "Go"]],
            "tools": [["type": "function", "function": ["name": "bad-name", "parameters": ["type": "object"]]]]]
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: raw))
        XCTAssertThrowsError(try ToolSelectionPolicy.validateRequest(request, loadedModelID: model, runtime: "mlx_cache"))
    }

}
