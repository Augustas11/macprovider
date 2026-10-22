import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

/// Regressions from the #2107 buyer-UX conformance run on real catalog models.
/// Model outputs are copied verbatim from the recorded exchanges.
final class BuyerUXConformanceRegressionTests: XCTestCase {
    private static let readFile = ["read_file"]

    /// Qwen2.5-Coder-32B `tools_auto`: the template's JSON body without the
    /// `<tool_call>` tags.
    static let coderBareCall = #"{"name": "read_file", "arguments": {"path": "/etc/hosts"}}"#
    /// Qwen2.5-Coder-32B `responses_function_tool`: the same body inside the
    /// `<tools>` wrapper its system prompt shows.
    static let coderToolsWrapped = "<tools>\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"/etc/hosts\"}}\n</tools>"
    /// Qwen2.5-Coder-32B `stream_tool_deltas`: one bare body per line (the
    /// recording is cut after the second `"name"`; its path is the prompt's).
    static let coderTwoBareCalls = #"{"name": "read_file", "arguments": {"path": "/etc/hosts"}}"# + "\n"
        + #"{"name": "read_file", "arguments": {"path": "/etc/passwd"}}"#
    /// Qwen3.6-35B-A3B `stream_tool_deltas`: a fenced list with a `call` key
    /// and inlined arguments; no grammar the template teaches (model behaviour).
    static let qwen36FencedList = "```json\n[\n  {\"call\": \"read_file\", \"path\": \"/etc/hosts\"},\n  {\"call\": \"read_file\", \"path\": \"/etc/passwd\"}\n]\n```"

    private func parse(_ raw: String, allowed: Set<String>? = ["read_file"]) -> ToolCallParser.ParsedToolCalls {
        ToolCallParser.parseToolCalls(rawOutput: raw, grammar: .qwen, modelID: "qwen2.5-coder-32b-instruct", allowedFunctionNames: allowed)
    }

    func testQwenBareEnvelopeBodiesAreToolCalls() throws {
        for (raw, paths) in [
            (Self.coderBareCall, ["/etc/hosts"]),
            (Self.coderToolsWrapped, ["/etc/hosts"]),
            (Self.coderTwoBareCalls, ["/etc/hosts", "/etc/passwd"]),
        ] {
            let parsed = parse(raw)
            XCTAssertNil(parsed.cleanedContent, raw)
            XCTAssertNil(parsed.leadingContent, raw)
            XCTAssertEqual(parsed.toolCalls.map(\.functionName), Array(repeating: "read_file", count: paths.count), raw)
            XCTAssertEqual(parsed.toolCalls.map(\.arguments), paths.map { #"{"path":"\#($0)"}"# }, raw)
            XCTAssertEqual(Set(parsed.toolCalls.map(\.id)).count, paths.count)
        }
    }

    func testQwenBareBodiesOutsideTheWholeOutputFormStayContent() {
        for raw in [
            Self.qwen36FencedList,
            "Here it is: " + Self.coderBareCall,
            Self.coderBareCall + "\nDone.",
            #"{"name": "write_file", "arguments": {"path": "/etc/hosts"}}"#,
            #"{"name": "read_file", "arguments": {"path": "/etc/hosts"}, "id": 1}"#,
            #"{"name": "read_file", "parameters": {"path": "/etc/hosts"}}"#,
            #"{"name": "read_file", "arguments": "/etc/hosts"}"#,
            "<tools>\n" + Self.coderBareCall,
            #"{"color": "blue"}"#,
        ] {
            let parsed = parse(raw)
            XCTAssertTrue(parsed.toolCalls.isEmpty, raw)
            XCTAssertEqual(parsed.cleanedContent, raw, raw)
        }
        XCTAssertTrue(parse(Self.coderBareCall, allowed: nil).toolCalls.isEmpty, "no declared tools, no call")
    }

    /// The stream holds an output that opens like a bare body, then emits the
    /// parsed calls; anything else streams as content unchanged.
    func testQwenStreamHoldsBareBodyAndFlushesProse() throws {
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "qwen2.5-coder-32b-instruct",
            "messages": [["role": "user", "content": "Read both /etc/hosts and /etc/passwd with the read_file tool, one call per file."]],
            "tools": [["type": "function", "function": [
                "name": "read_file", "description": "Read a file from disk",
                "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]],
            ]]],
            "stream": true,
        ]))
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .qwen))
        for (output, wantCalls) in [(Self.coderTwoBareCalls, 2), (Self.coderToolsWrapped, 1), (#"{"color": "blue"} is the answer."#, 0), ("Plain {prose}.", 0)] {
            var emitter = SerialStreamingTextEmitter(request: request)
            let accumulator = StructuredStreamingContentAccumulator(enabled: false)
            let idle = StructuredStreamingIdleState(enabled: false)
            var content = ""
            for end in 1...output.count {
                _ = emitter.step(candidate: (String(output.prefix(end)), false), structuredAccumulator: accumulator, idleState: idle) {
                    if case .content(let text) = $0 { content += text }
                    if case .toolCallDelta = $0 { XCTFail("no incremental delta for a bare body") }
                }
            }
            if wantCalls > 0 { XCTAssertEqual(content, "", output) }
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request, mode: .complete(),
                defaultCompletionTokens: 9, toolCallPrefill: nil
            )
            try emitter.finish(finalText: output, parsed: parsed, structuredAccumulator: accumulator, idleState: idle) {
                if case .content(let text) = $0 { content += text }
            }
            XCTAssertEqual(parsed.toolCalls.count, wantCalls, output)
            XCTAssertEqual(emitter.reconciledToolCalls.count, wantCalls, output)
            XCTAssertEqual(content, wantCalls > 0 ? "" : output, output)
        }
    }

    /// The `required`/named check uses the same identity the coordinator
    /// capability advertises: a provider loaded under its catalog key with a
    /// profiled catalog id alias (Qwen3-Coder, Qwen3-30B-2507), not only Qwen3.6.
    func testToolSelectionIdentityResolvesEveryProfiledCatalogAlias() {
        for alias in ToolSelectionPolicy.guaranteedCallProfiles.keys {
            XCTAssertEqual(ModelRuntime.toolSelectionModelID(loadedModelID: "catalog-key", configuredModelID: "catalog-key", catalogModelIDAlias: alias), alias)
            XCTAssertEqual(ModelRuntime.toolSelectionModelID(loadedModelID: "swapped", configuredModelID: "catalog-key", catalogModelIDAlias: alias), "swapped", "a warm-swapped model keeps its own id")
        }
        XCTAssertEqual(ModelRuntime.toolSelectionModelID(loadedModelID: "qwen3-8b", configuredModelID: "qwen3-8b", catalogModelIDAlias: "mlx-community/Qwen3-8B-4bit"), "qwen3-8b")
        XCTAssertNil(ModelRuntime.toolSelectionModelID(loadedModelID: nil, configuredModelID: "k", catalogModelIDAlias: ToolSelectionPolicy.supportedNativeModel))
    }

    /// A guaranteed function-XML value for a non-strict property with no single
    /// declared type is JSON when it parses, else its text.
    func testGuaranteedFunctionXMLTypesUntypedNonStrictProperty() throws {
        let schemas: [String: JSONValue] = ["read_file": .object([
            "type": .string("object"),
            "properties": .object(["path": .object(["description": .string("file")]), "n": .object([:])]),
            "required": .array([.string("path")]),
        ])]
        let raw = "<tool_call>\n<function=read_file>\n<parameter=path>\n/etc/hosts\n</parameter>\n<parameter=n>\n3\n</parameter>\n</function>\n</tool_call>"
        let call = try XCTUnwrap(ToolCallParser.parseGuaranteedToolCalls(raw, schemas: schemas).first)
        XCTAssertEqual(call.arguments, #"{"n":3,"path":"/etc/hosts"}"#)
    }

    /// Audit r1: call markup inside a bare body's argument string is data.
    func testQwenBareBodyKeepsMarkerTextInArguments() throws {
        let raw = #"{"name": "read_file", "arguments": {"path": "notes <tool_call> and <function=x>"}}"#
        let parsed = parse(raw)
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"path":"notes <tool_call> and <function=x>"}"#])
        var emitter = NativeToolCallStreamEmitter(modelID: "qwen2.5-coder-32b-instruct", grammar: .qwen, allowedFunctionNames: ["read_file"])
        XCTAssertTrue(emitter.observe(raw).isEmpty, "no incremental delta from marker text inside a held body")
        XCTAssertEqual(emitter.visibleContentPrefix(of: raw), "")
    }

    /// Audit r1: leading whitespace before a bare body is held, so the stream
    /// matches the non-stream response (calls, no content); before prose it
    /// is released with the prose.
    func testQwenStreamHoldsLeadingWhitespace() {
        let emitter = NativeToolCallStreamEmitter(modelID: "qwen2.5-coder-32b-instruct", grammar: .qwen, allowedFunctionNames: ["read_file"])
        XCTAssertEqual(emitter.visibleContentPrefix(of: "\n"), "")
        XCTAssertEqual(emitter.visibleContentPrefix(of: "\n" + Self.coderBareCall), "")
        XCTAssertEqual(emitter.visibleContentPrefix(of: "\nHello"), "\nHello")
    }

    /// Audit r1: a streaming Harmony turn never takes the batched stream sink,
    /// which emits decoded text instead of parsed channels.
    func testStreamingHarmonyIsNotBatchRepresentable() throws {
        func request(stream: Bool) throws -> ChatCompletionRequest {
            try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
                "model": "openai/gpt-oss-20b", "messages": [["role": "user", "content": "hi"]], "stream": stream,
            ]))
        }
        XCTAssertFalse(ModelRuntime.requestStateRepresentable(try request(stream: true)))
        XCTAssertTrue(ModelRuntime.requestStateRepresentable(try request(stream: false)))
    }

    /// Audit r2: bare-body depth follows the tagged path (deeply nested
    /// arguments parse in both forms or in neither).
    func testQwenBareBodyDepthMatchesTaggedPath() throws {
        let arguments = String(repeating: #"{"a":"#, count: 30) + "1" + String(repeating: "}", count: 30)
        let body = #"{"name": "read_file", "arguments": "# + arguments + "}"
        let tagged = parse("<tool_call>\n" + body + "\n</tool_call>")
        XCTAssertEqual(parse(body).toolCalls.count, tagged.toolCalls.count)
        XCTAssertEqual(parse(body).toolCalls.first?.arguments, tagged.toolCalls.first?.arguments)
    }

    /// Audit r2: a non-strict schema may require a key it does not declare;
    /// guaranteed function-XML reads it untyped. A strict schema still refuses it.
    func testGuaranteedFunctionXMLAcceptsUndeclaredRequiredKeyForNonStrictSchema() throws {
        let raw = "<tool_call>\n<function=read_file>\n<parameter=path>\n/etc/hosts\n</parameter>\n</function>\n</tool_call>"
        let loose: [String: JSONValue] = ["read_file": .object(["type": .string("object"), "required": .array([.string("path")])])]
        XCTAssertEqual(try ToolCallParser.parseGuaranteedToolCalls(raw, schemas: loose).first?.arguments, #"{"path":"/etc/hosts"}"#)
        let strict: [String: JSONValue] = ["read_file": .object([
            "type": .string("object"), "properties": .object(["file": .object(["type": .string("string")])]),
            "required": .array([.string("file")]), "additionalProperties": .bool(false),
        ])]
        XCTAssertThrowsError(try ToolCallParser.parseGuaranteedToolCalls(raw, schemas: strict))
    }
}
