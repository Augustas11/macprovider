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
                .replacingOccurrences(of: ">Paris]", with: ">true]")
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
                if family != .harmony {
                    request.outputState.resolve(RequestOutputTraits(toolGrammar: family))
                    let finalized = try ModelRuntime.parseGeneratedOutput(
                        filteredText: call, generatedTokenIDs: [], decode: { _ in "" }, request: request,
                        mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: nil)
                    XCTAssertEqual(finalized.toolCalls.count, 1, "finalization \(family) named=\(named)")
                    XCTAssertEqual(finalized.toolCalls.first?.functionName, "f")
                    XCTAssertEqual(finalized.content, "")
                    // Finalization independently rejects bytes outside the
                    // complete native envelope and a second generated call.
                    if family != .qwen {
                        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
                            filteredText: call + call, generatedTokenIDs: [], decode: { _ in "" }, request: request,
                            mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: nil))
                    }
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
        case .lfm2: return "<|tool_call_start|>[" + name + "(city=\"Paris\")]<|tool_call_end|>"
        case .llama3: return "{\"name\":\"" + name + "\",\"parameters\":{\"city\":\"Paris\"}}"
        case .glm: return "<tool_call>" + name + "<arg_key>city</arg_key><arg_value>Paris</arg_value></tool_call>"
        case .gemma4: return "<|tool_call>call:" + name + "{<|\"|>city<|\"|>:<|\"|>Paris<|\"|>}<tool_call|>"
        case .harmony: return "<|start|>assistant to=functions." + name + "<|channel|>commentary<|message|>{\"city\":\"Paris\"}<|call|>"
        case .dsml: return "<｜DSML｜tool_calls><｜DSML｜invoke name=\"" + name + "\"><｜DSML｜parameter name=\"city\" string=\"true\">Paris</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜tool_calls>"
        case .minimax:
            let ns = ToolCallParser.miniMaxNamespace
            return ns + "<tool_call>\n" + ns + "<invoke name=\"" + name + "\">" + ns + "<city>Paris" + ns + "</city>" + ns + "</invoke>\n" + ns + "</tool_call>"
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
            (.lfm2, #"<|tool_call_start|>[f(city="Paris",data=[{"ok":true}])]<|tool_call_end|>"#),
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

    // Qwen3.8-Flash-Next (qwen4_exp) lab serve, 2026-11-20: tool_choice
    // required/named failed 2/3 and 1/3 with 502 tool_selection_validation_failed.
    // The template teaches function-XML calls but the guaranteed grammar forced
    // the JSON envelope. The grammar now follows the loaded template's form.
    private static let readFile = JSONValue.object(["type": .string("object"),
        "properties": .object(["path": .object(["type": .string("string")])]), "required": .array([.string("path")])])

    private func guaranteedRequest(_ choice: Any, parameters: JSONValue = readFile,
                                   extraTools: [String] = []) throws -> ChatCompletionRequest {
        let tools: [[String: Any]] = (["read_file"] + extraTools).map {
            ["type": "function", "function": ["name": $0, "parameters": parameters.jsonObject]]
        }
        let body: [String: Any] = ["model": "qwen/qwen3.8-flash-next-abliterated", "max_tokens": 1024,
            "messages": [["role": "user", "content": "Read the file /etc/hosts using the read_file tool."]],
            "tools": tools, "tool_choice": choice]
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    /// The call as the Qwen3.8 chat template renders it (fixture
    /// `scripts/tests/fixtures/qwen38-27b-official/chat_template.jinja`).
    private func templateCall(_ name: String = "read_file", _ arguments: [(String, String)] = [("path", "/etc/hosts")]) -> String {
        "<tool_call>\n<function=\(name)>\n"
            + arguments.map { "<parameter=\($0.0)>\n\($0.1)\n</parameter>\n" }.joined()
            + "</function>\n</tool_call>"
    }

    func testGuaranteedQwenCallFormatFollowsTheLoadedTemplate() {
        XCTAssertEqual(GrammarConstraintState.guaranteedQwenCallFormat(.xmlFunction), .functionXML)
        XCTAssertEqual(GrammarConstraintState.guaranteedQwenCallFormat(.qwen35), .functionXML)
        XCTAssertEqual(GrammarConstraintState.guaranteedQwenCallFormat(.json), .jsonEnvelope)
        XCTAssertEqual(GrammarConstraintState.guaranteedQwenCallFormat(nil), .jsonEnvelope)
    }

    func testFunctionXMLQwenGuaranteedGrammarIsTheTemplateFormAndParses() throws {
        let named: Any = ["type": "function", "function": ["name": "read_file"]]
        for choice in ["required", named] as [Any] {
            let request = try guaranteedRequest(choice, extraTools: ["write_file"])
            request.outputState.resolve(RequestOutputTraits(toolGrammar: .qwen))
            let dfa = try XCTUnwrap(GrammarTemplates.grammar(
                for: request, traits: request.outputTraits, qwenCallFormat: .functionXML)).compile()
            let call = templateCall()
            XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(call.utf8)))))
            // The JSON envelope is no longer the forced form for this template.
            let json = #"<tool_call>{"name":"read_file","arguments":{"path":"/etc/hosts"}}</tool_call>"#
            XCTAssertNil(dfa.transition(state: 0, bytes: Array(json.utf8)))
            let other = templateCall("write_file")
            if choice is String {
                XCTAssertNotNil(dfa.transition(state: 0, bytes: Array(other.utf8)))
            } else {
                XCTAssertNil(dfa.transition(state: 0, bytes: Array(other.utf8)), "named admits only the selected function")
            }
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: call, generatedTokenIDs: [], decode: { _ in "" }, request: request,
                mode: .complete(), defaultCompletionTokens: 26, toolCallPrefill: nil)
            XCTAssertEqual(parsed.content, "")
            XCTAssertEqual(parsed.toolCalls.map(\.functionName), ["read_file"])
            XCTAssertEqual(try StrictJSONParser.parse(XCTUnwrap(parsed.toolCalls.first).arguments),
                           .object(["path": .string("/etc/hosts")]))
            XCTAssertNoThrow(try ToolSelectionPolicy.validateOutput(
                calls: parsed.toolCalls.map { MacProviderCore.ToolCall(id: $0.id, functionName: $0.functionName, arguments: $0.arguments) }, finishReason: "tool_calls", generatedTokens: 26, request: request))
        }
        // The default stays the JSON envelope (JSON templates, unknown format).
        let request = try guaranteedRequest("required")
        let json = try XCTUnwrap(GrammarTemplates.grammar(for: request, traits: RequestOutputTraits(toolGrammar: .qwen))).compile()
        XCTAssertNil(json.transition(state: 0, bytes: Array(templateCall().utf8)))
    }

    func testFunctionXMLQwenGrammarRoundTripsTypedMultilineAndUnicodeValues() throws {
        let parameters = JSONValue.object(["type": .string("object"), "properties": .object([
            "content": .object(["type": .string("string")]),
            "count": .object(["type": .string("integer")]),
            "mode": .object(["type": .string("string"), "enum": .array([.string("a b"), .string("w")])]),
            "opts": .object(["type": .string("object"), "properties": .object(["ok": .object(["type": .string("boolean")])])]),
        ]), "required": .array([.string("content"), .string("count")])])
        let request = try guaranteedRequest("required", parameters: parameters)
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .qwen))
        let dfa = try XCTUnwrap(GrammarTemplates.grammar(
            for: request, traits: request.outputTraits, qwenCallFormat: .functionXML)).compile()
        let content = "line one\n\tKaunas – Vilnius 🚀\n"
        let call = templateCall("read_file", [("content", content), ("count", "3"), ("mode", "a b"), ("opts", #"{"ok":true}"#)])
        XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(call.utf8)))))
        for bad in [call.replacingOccurrences(of: "\n3\n", with: "\n\"3\"\n"),       // integer as a string
                    call.replacingOccurrences(of: "a b", with: "x"),                // outside the enum
                    call.replacingOccurrences(of: "Vilnius", with: "<b>"),          // markup in a raw value
                    call.replacingOccurrences(of: "one", with: "one\r")] {          // CR in a raw value
            XCTAssertFalse(dfa.transition(state: 0, bytes: Array(bad.utf8)).map(dfa.accepting(state:)) ?? false)
        }
        XCTAssertNil(dfa.transition(state: 0, bytes: Array("<tool_call>\n<function=read_file>\n<parameter=content>\n".utf8) + [0xFF]),
                     "invalid UTF-8 never enters a value")
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: call, generatedTokenIDs: [], decode: { _ in "" }, request: request,
            mode: .complete(), defaultCompletionTokens: 40, toolCallPrefill: nil)
        let arguments = try StrictJSONParser.parse(XCTUnwrap(parsed.toolCalls.first).arguments)
        XCTAssertEqual(arguments, .object(["content": .string(content), "count": .int(3), "mode": .string("a b"),
                                           "opts": .object(["ok": .bool(true)])]))
        XCTAssertNoThrow(try ToolSelectionPolicy.validateOutput(
            calls: parsed.toolCalls.map { MacProviderCore.ToolCall(id: $0.id, functionName: $0.functionName, arguments: $0.arguments) }, finishReason: "tool_calls", generatedTokens: 40, request: request))
    }

    func testFunctionXMLQwenGrammarCoversUndeclaredRequiredKeysAndRootEnums() throws {
        let cases: [(JSONValue, String, JSONValue)] = [
            // A required key the schema does not declare is read untyped.
            (.object(["type": .string("object"), "required": .array([.string("city")])]),
             templateCall("read_file", [("city", "true")]), .object(["city": .bool(true)])),
            // A root object enum admits only its complete instances.
            (.object(["type": .string("object"), "properties": .object(["city": .object(["type": .string("string")])]),
                      "required": .array([.string("city")]), "enum": .array([.object(["city": .string("Paris")])])]),
             templateCall("read_file", [("city", "Paris")]), .object(["city": .string("Paris")])),
        ]
        for (parameters, call, arguments) in cases {
            let request = try guaranteedRequest("required", parameters: parameters)
            request.outputState.resolve(RequestOutputTraits(toolGrammar: .qwen))
            let dfa = try XCTUnwrap(GrammarTemplates.grammar(
                for: request, traits: request.outputTraits, qwenCallFormat: .functionXML)).compile()
            XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(call.utf8)))), call)
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: call, generatedTokenIDs: [], decode: { _ in "" }, request: request,
                mode: .complete(), defaultCompletionTokens: 20, toolCallPrefill: nil)
            XCTAssertEqual(try StrictJSONParser.parse(XCTUnwrap(parsed.toolCalls.first).arguments), arguments)
            XCTAssertNoThrow(try ToolSelectionPolicy.validateOutput(
                calls: parsed.toolCalls.map { MacProviderCore.ToolCall(id: $0.id, functionName: $0.functionName, arguments: $0.arguments) },
                finishReason: "tool_calls", generatedTokens: 20, request: request))
        }
    }

    func testFunctionXMLQwenGrammarKeepsRootEnumStringsTheSchemaDoesNotDeclareAsJSON() throws {
        // The parser would read an undeclared raw `1` back as the integer 1.
        let parameters = JSONValue.object(["type": .string("object"), "enum": .array([.object(["mode": .string("1")])])])
        let dfa = try GrammarTemplates.toolCall(name: "f", parameters: parameters, family: .qwen,
                                                qwenCallFormat: .functionXML).compile()
        let xml = templateCall("f", [("mode", "1")])
        XCTAssertFalse(dfa.transition(state: 0, bytes: Array(xml.utf8)).map { dfa.accepting(state: $0) } ?? false)
        let json = #"<tool_call>{"name":"f","arguments":{"mode":"1"}}</tool_call>"#
        XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(json.utf8)))))
        let calls = try ToolCallParser.parseGuaranteedToolCalls(json, schemas: ["f": parameters])
        XCTAssertEqual(try StrictJSONParser.parse(XCTUnwrap(calls.first).arguments), .object(["mode": .string("1")]))
    }

    func testFunctionXMLQwenGrammarKeepsTheJSONEnvelopeForKeysItCannotTag() throws {
        let parameters = JSONValue.object(["type": .string("object"), "properties": .object([
            "file.path": .object(["type": .string("string")]),
        ])])
        let dfa = try GrammarTemplates.toolCall(name: "f", parameters: parameters, family: .qwen,
                                                qwenCallFormat: .functionXML).compile()
        let json = #"<tool_call>{"name":"f","arguments":{"file.path":"/etc/hosts"}}</tool_call>"#
        XCTAssertTrue(dfa.accepting(state: try XCTUnwrap(dfa.transition(state: 0, bytes: Array(json.utf8)))))
        let calls = try ToolCallParser.parseGuaranteedToolCalls(json, schemas: ["f": parameters])
        XCTAssertEqual(calls.first?.functionName, "f")
    }

    func testFunctionXMLQwenConstraintAdmitsTheTemplateTokensOnly() throws {
        // Synthetic byte vocabulary plus the Qwen `<tool_call>` control token.
        var tokens: [Int: [UInt8]] = [:]
        for byte in 0...255 { tokens[byte] = [UInt8(byte)] }
        let callOpen = 300, eos = 301
        tokens[callOpen] = Array("<tool_call>".utf8)
        tokens[eos] = Array("<|im_end|>".utf8)
        let request = try guaranteedRequest("required")
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .qwen))
        let grammar = try XCTUnwrap(GrammarTemplates.grammar(
            for: request, traits: request.outputTraits, qwenCallFormat: .functionXML))
        func replay(_ text: String) throws -> GrammarConstraintState {
            let state = try GrammarConstraintState(grammar: grammar, tokens: tokens, eosTokenIDs: [eos])
            state.didSample(token: callOpen)
            for byte in text.dropFirst("<tool_call>".count).utf8 { state.didSample(token: Int(byte)) }
            state.didSample(token: eos)
            return state
        }
        XCTAssertNoThrow(try replay(templateCall()).validate())
        XCTAssertThrowsError(try replay(#"<tool_call>{"name":"read_file","arguments":{"path":"/etc/hosts"}}</tool_call>"#).validate())
    }
}
