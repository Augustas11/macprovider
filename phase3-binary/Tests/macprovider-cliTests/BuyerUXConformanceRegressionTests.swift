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
    /// Qwen2.5-Coder-32B `stream_tool_deltas` (#2109 rerun): two calls, each in
    /// its own `<tools>` wrapper. Recorded output, verbatim.
    static let coderTwoToolsWrapped = "<tools>\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"/etc/hosts\"}}\n</tools>\n<tools>\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"/etc/passwd\"}}\n</tools>"
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
            (Self.coderTwoToolsWrapped, ["/etc/hosts", "/etc/passwd"]),
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
            "<tools>\n</tools>",
            Self.coderToolsWrapped + "\n<tools>\n</tools>",
            Self.coderToolsWrapped + "\n<tools>\n" + Self.coderBareCall,
            Self.coderToolsWrapped + "\n" + Self.coderBareCall,
            Self.coderToolsWrapped + "\nDone.",
            Self.coderToolsWrapped + "\n<tools>\n" + #"{"name": "write_file", "arguments": {"path": "/etc/hosts"}}"# + "\n</tools>",
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
        for (output, wantCalls) in [(Self.coderTwoBareCalls, 2), (Self.coderToolsWrapped, 1), (Self.coderTwoToolsWrapped, 2), (#"{"color": "blue"} is the answer."#, 0), ("Plain {prose}.", 0)] {
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

    /// Re-audit r1: a serial turn (`parallel_tool_calls:false`) stops as soon
    /// as the output is a complete bare-call output, before later prose or an
    /// unfinished second body can void the whole-output parse. Each prefix is
    /// observed the way the decode loop observes it.
    func testQwenBareCallsTriggerSerialStop() throws {
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "qwen2.5-coder-32b-instruct",
            "messages": [["role": "user", "content": "Read /etc/hosts with the read_file tool."]],
            "tools": [["type": "function", "function": [
                "name": "read_file", "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]],
            ]]],
            "parallel_tool_calls": false,
        ]))
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .qwen))
        XCTAssertTrue(ModelRuntime.serialToolStopApplies(request))
        // (generated output, where the serial stop must fire: the prefix that
        // completes the first output the final parse accepts as calls).
        for (output, stopAt) in [
            (Self.coderBareCall + "\nI read the file.", Self.coderBareCall),
            (Self.coderTwoBareCalls, Self.coderBareCall),
            (Self.coderToolsWrapped + "\nDone.", Self.coderToolsWrapped),
            (Self.coderTwoToolsWrapped, Self.coderToolsWrapped),
        ] {
            var observer = NativeToolCallStreamEmitter(modelID: request.model, grammar: .qwen, allowedFunctionNames: ["read_file"])
            var stoppedPrefix: String?
            for end in 1...output.count {
                let prefix = String(output.prefix(end))
                if ModelRuntime.observeSerialToolStop(&observer, decoded: prefix, stopTokenFilter: StopTokenFilter(tokens: []), requestStops: []) {
                    stoppedPrefix = prefix
                    break
                }
            }
            let stopped = try XCTUnwrap(stoppedPrefix, output)
            XCTAssertEqual(stopped, stopAt, output)
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: stopped, generatedTokenIDs: [], decode: { _ in "" }, request: request,
                mode: .complete(finishReason: "stop"), defaultCompletionTokens: 9, toolCallPrefill: nil
            )
            XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"path":"/etc/hosts"}"#], output)
            XCTAssertEqual(parsed.content, "", output)
        }
        // Never a stop on an unfinished body, an undeclared name or prose.
        for output in [
            #"{"name": "read_file", "arguments": {"path": "/etc/hosts"}"#,
            "<tools>\n" + Self.coderBareCall,
            #"{"name": "write_file", "arguments": {"path": "/etc/hosts"}}"#,
            #"{"color": "blue"}"#,
        ] {
            var observer = NativeToolCallStreamEmitter(modelID: request.model, grammar: .qwen, allowedFunctionNames: ["read_file"])
            for end in 1...output.count {
                XCTAssertFalse(ModelRuntime.observeSerialToolStop(&observer, decoded: String(output.prefix(end)), stopTokenFilter: StopTokenFilter(tokens: []), requestStops: []), output)
            }
        }
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

    /// SPEC-018 v0.3.2: an exact repeat of a call (same name, same canonical
    /// arguments) in one reply is dropped; kept calls are untouched.
    func testDuplicateCallsInOneReplyAreDropped() throws {
        let call = { (args: String) in "<tool_call>\n{\"name\": \"read_file\", \"arguments\": \(args)}\n</tool_call>" }
        let raw = [call(#"{"path": "/etc/hosts", "mode": "r"}"#), call(#"{"mode": "r", "path": "/etc/hosts"}"#), call(#"{"path": "/etc/passwd", "mode": "r"}"#), call(#"{"path": "/etc/hosts", "mode": "r"}"#)].joined(separator: "\n")
        let parsed = parse(raw)
        XCTAssertEqual(parsed.toolCalls.map(\.arguments), [#"{"mode":"r","path":"/etc/hosts"}"#, #"{"mode":"r","path":"/etc/passwd"}"#])
        XCTAssertEqual(parse(Self.coderTwoBareCalls + "\n" + Self.coderBareCall).toolCalls.count, 2, "bare bodies too")
        let other = macprovider_cli.ToolCall(id: "call_b", functionName: "write_file", arguments: #"{"path":"/etc/hosts"}"#)
        let first = macprovider_cli.ToolCall(id: "call_a", functionName: "read_file", arguments: #"{"path":"/etc/hosts"}"#)
        XCTAssertEqual(ToolCallParser.uniqueCappedCalls([first, other, first]), [first, other], "same arguments, other name is kept")
        // Audit r2: canonically equivalent but different Unicode scalars are
        // different arguments; so are numbers that share a Double.
        let composed = macprovider_cli.ToolCall(id: "c1", functionName: "read_file", arguments: "{\"path\":\"/tmp/\u{E9}\"}")
        let decomposed = macprovider_cli.ToolCall(id: "c2", functionName: "read_file", arguments: "{\"path\":\"/tmp/e\u{301}\"}")
        XCTAssertEqual(ToolCallParser.uniqueCappedCalls([composed, decomposed]).count, 2)
        let near = macprovider_cli.ToolCall(id: "n1", functionName: "read_file", arguments: #"{"n":0.1}"#)
        let nearer = macprovider_cli.ToolCall(id: "n2", functionName: "read_file", arguments: #"{"n":0.10000000000000000001}"#)
        XCTAssertEqual(ToolCallParser.uniqueCappedCalls([near, nearer]).count, 2)
        let numbered = macprovider_cli.ToolCall(id: "n3", functionName: "read_file", arguments: #"{"n":0.1}"#)
        XCTAssertEqual(ToolCallParser.uniqueCappedCalls([near, numbered]).count, 1, "identical bytes still dedupe")

        // Streaming finalizes through the same parse.
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "qwen2.5-coder-32b-instruct",
            "messages": [["role": "user", "content": "Read /etc/hosts."]],
            "tools": [["type": "function", "function": [
                "name": "read_file", "parameters": ["type": "object", "properties": ["path": ["type": "string"]]],
            ]]],
            "parallel_tool_calls": true,
            "stream": true,
        ]))
        request.outputState.resolve(RequestOutputTraits(toolGrammar: .qwen))
        let output = call(#"{"path": "/etc/hosts"}"#) + "\n" + call(#"{"path": "/etc/hosts"}"#)
        var emitter = SerialStreamingTextEmitter(request: request)
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        for end in 1...output.count {
            _ = emitter.step(candidate: (String(output.prefix(end)), false), structuredAccumulator: accumulator, idleState: idle) { _ in }
        }
        let streamed = try ModelRuntime.parseGeneratedOutput(
            filteredText: output, generatedTokenIDs: [], decode: { _ in "" }, request: request, mode: .complete(),
            defaultCompletionTokens: 9, toolCallPrefill: nil
        )
        try emitter.finish(finalText: output, parsed: streamed, structuredAccumulator: accumulator, idleState: idle) { _ in }
        XCTAssertEqual(streamed.toolCalls.count, 1)
        XCTAssertEqual(emitter.reconciledToolCalls.count, 1)
    }

    /// SPEC-018 v0.3.2: at most 128 calls (the §3.11 per-reply bound) are
    /// kept per reply, the first ones in generated order.
    func testCallsPerReplyAreCapped() {
        XCTAssertEqual(ToolSelectionPolicy.maxCalls, 128)
        let body = { (i: Int) in "{\"name\": \"read_file\", \"arguments\": {\"path\": \"/tmp/\(i)\"}}" }
        // Audit r2: every grammar keeps the first 128 unique calls instead of
        // rejecting the reply, and duplicates do not count toward the cap.
        let outputs: [(String, ToolCallGrammar)] = [
            ((0..<130).map { "<tool_call>\n" + body($0) + "\n</tool_call>" }.joined(separator: "\n"), .qwen),
            ((0..<130).map(body).joined(separator: "\n"), .qwen),
            ("<tools>\n" + (0..<130).map(body).joined(separator: "\n") + "\n</tools>", .qwen),
            ((0..<130).map { "<tool_call>read_file<arg_key>path</arg_key><arg_value>/tmp/\($0)</arg_value></tool_call>" }.joined(), .glm),
            ((0..<130).map { "{\"name\": \"read_file\", \"parameters\": {\"path\": \"/tmp/\($0)\"}}" }.joined(separator: "; "), .llama3),
        ]
        for (raw, grammar) in outputs {
            let calls = ToolCallParser.parseToolCalls(rawOutput: raw, grammar: grammar, modelID: "m", allowedFunctionNames: ["read_file"]).toolCalls
            XCTAssertEqual(calls.count, 128, "\(grammar)")
            XCTAssertEqual(calls.first?.arguments, #"{"path":"/tmp/0"}"#, "\(grammar)")
            XCTAssertEqual(calls.last?.arguments, #"{"path":"/tmp/127"}"#, "\(grammar)")
        }
        let repeated = (0..<200).map { "<tool_call>\n" + body($0 % 3) + "\n</tool_call>" }.joined(separator: "\n")
        XCTAssertEqual(parse(repeated).toolCalls.count, 3, "200 calls, 3 unique")
    }

    /// SPEC-018 v0.3.2 §3.12: a structured response_format renders with
    /// thinking off (enable_thinking templates) and the lowest effort the
    /// reasoning_effort templates take, overriding the buyer's effort.
    func testStructuredResponseFormatRendersWithThinkingOff() throws {
        for format: [String: Any] in [["type": "json_object"], ["type": "json_schema", "json_schema": ["name": "c", "schema": ["type": "object"]]]] {
            let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
                "model": "z-ai/glm-4.5-air", "messages": [["role": "user", "content": "x"]],
                "response_format": format, "reasoning_effort": "high",
            ]))
            XCTAssertEqual(request.templateReasoningEffort, "low")
            let input = try ModelRuntime.userInput(for: request, templateSupportsThinkingToggle: true)
            XCTAssertEqual(input.additionalContext?["enable_thinking"] as? Bool, false)
            XCTAssertEqual(input.additionalContext?["reasoning_effort"] as? String, "low")
        }
        let text = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "m", "messages": [["role": "user", "content": "x"]], "reasoning_effort": "high",
        ]))
        XCTAssertEqual(text.templateReasoningEffort, "high", "text requests keep the buyer's effort")
    }

    /// GLM-4.5-Air `json_object` 502: the failing bytes were dropped. The
    /// default log line names the shape (fence, think tags, bytes around the
    /// first object) and a digest, never the content (SPEC-001 NFR-7); a
    /// bounded, escaped preview is added only at debug level.
    func testStructuredFailureDiagnosticIsContentFreeByDefault() {
        let secret = "sk-live-do-not-log"
        let fenced = "```json\n{\"color\": \"blue\", \"note\": \"\(secret)\"}\n```"
        let line = ModelRuntime.structuredFailureDiagnostic(fenced, model: "z-ai/glm-4.5-air", preview: false)
        XCTAssertFalse(line.contains(secret), line)
        XCTAssertFalse(line.contains("blue"), line)
        XCTAssertFalse(line.contains("\n"), "one log line")
        for field in ["bytes=\(fenced.utf8.count)", "fence=true", "think=false", "leading_bytes=8", "first_object_parses=true", "trailing_bytes=4"] {
            XCTAssertTrue(line.contains(field), "\(field) in \(line)")
        }
        XCTAssertNotNil(line.range(of: #"digest=[0-9a-f]{32}( |$)"#, options: .regularExpression), line)
        XCTAssertEqual(line, ModelRuntime.structuredFailureDiagnostic(fenced, model: "z-ai/glm-4.5-air", preview: false), "repeats correlate")
        let think = ModelRuntime.structuredFailureDiagnostic("<think>x</think>\n{\"color\": \"blue\"}", model: "m", preview: false)
        XCTAssertTrue(think.contains("think=true"), think)
        XCTAssertTrue(ModelRuntime.structuredFailureDiagnostic("", model: "m", preview: false).contains("bytes=0"))
    }

    func testStructuredFailurePreviewIsBoundedAndEscaped() {
        let content = "Sure!\n\"quoted\"\u{1b}[2J" + String(repeating: "x", count: 500) + "END"
        let line = ModelRuntime.structuredFailureDiagnostic(content, model: "m\ninjected", preview: true)
        XCTAssertFalse(line.contains("\n"), "previews cannot split the log line")
        XCTAssertFalse(line.contains("\u{1b}"), "control bytes are escaped")
        XCTAssertTrue(line.contains("head=\"Sure!\\u{a}\\u{22}quoted"), line)
        XCTAssertTrue(line.contains("xEND\""), line)
        XCTAssertTrue(line.contains("model=\"m\\u{a}injected\""), line)
        XCTAssertLessThan(line.utf8.count, 1_200, "bounded")
        let short = ModelRuntime.structuredFailureDiagnostic("nope", model: "m", preview: true)
        XCTAssertTrue(short.contains("head=\"nope\""), short)
        XCTAssertFalse(short.contains("tail="), "short output is not repeated")
    }

    /// Audit r2: a non-strict schema may require a key it does not declare;
    /// guaranteed function-XML reads it untyped. A strict schema still refuses it.
    func testGuaranteedFunctionXMLAcceptsUndeclaredRequiredKeyForNonStrictSchema() throws {
        let raw = "<tool_call>\n<function=read_file>\n<parameter=path>\n/etc/hosts\n</parameter>\n</function>\n</tool_call>"
        let loose: [String: JSONValue] = ["read_file": .object(["type": .string("object"), "required": .array([.string("path")])])]
        XCTAssertEqual(try ToolCallParser.parseGuaranteedToolCalls(raw, schemas: loose).first?.arguments, #"{"path":"/etc/hosts"}"#)
        // Audit r3: a boolean subschema is untyped too.
        let boolean: [String: JSONValue] = ["read_file": .object([
            "type": .string("object"), "properties": .object(["path": .bool(true)]), "required": .array([.string("path")]),
        ])]
        XCTAssertEqual(try ToolCallParser.parseGuaranteedToolCalls(raw, schemas: boolean).first?.arguments, #"{"path":"/etc/hosts"}"#)
        let strict: [String: JSONValue] = ["read_file": .object([
            "type": .string("object"), "properties": .object(["file": .object(["type": .string("string")])]),
            "required": .array([.string("file")]), "additionalProperties": .bool(false),
        ])]
        XCTAssertThrowsError(try ToolCallParser.parseGuaranteedToolCalls(raw, schemas: strict))
    }
}
