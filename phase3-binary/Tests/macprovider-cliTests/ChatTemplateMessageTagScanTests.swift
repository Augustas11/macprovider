import Foundation
import Jinja
import XCTest
@testable import MacProviderCore
@testable import macprovider_cli

/// SPEC-018 §3.14: message content never selects a reasoning mode through the
/// Solstice-AI uncensored GLM-5.3-Flash chat template.
final class ChatTemplateMessageTagScanTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/tests/fixtures/")
    private static let tags = ["[default]", "[regular]", "[REGULAR]", "[vanilla]", "[standard]", "{REASON:i2}", "[MODE:oracle]", "[L0]", "[l10]"]
    private static let tool: [String: Any] = ["type": "function", "function": ["name": "read_file", "description": "Read", "parameters": ["type": "object", "properties": ["path": ["type": "string"]]]]]

    private func source(_ path: String = "glm53-uncensored-chat-template/chat_template.jinja") throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(path), encoding: .utf8)
    }

    private func render(_ text: String, messages: [[String: Any]], tools: [[String: Any]]? = nil, effort: String? = nil) throws -> String {
        let template = try Template(text, with: .init(lstripBlocks: true, trimBlocks: true))
        var context: [String: Value] = ["messages": try Value(any: messages), "add_generation_prompt": .boolean(true)]
        if let tools { context["tools"] = try Value(any: tools) }
        if let effort { context["reasoning_effort"] = .string(effort) }
        return try template.render(context)
    }

    private func rewritten() throws -> String { ChatTemplateCompatibility.rewrite(try source()).template }

    private func user(_ text: String) -> [[String: Any]] { [["role": "user", "content": text]] }

    private func toolTurn(_ result: String) -> [[String: Any]] {
        [
            ["role": "user", "content": "Read it."],
            ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "type": "function", "function": ["name": "read_file", "arguments": ["path": "a.ini"]]]]],
            ["role": "tool", "tool_call_id": "c1", "content": result],
        ]
    }

    /// Everything the template decides: the preamble and the generation prompt.
    private func mode(_ prompt: String, body: String) throws -> String {
        try XCTUnwrap(prompt.range(of: body)).isEmpty ? "" : prompt.replacingOccurrences(of: body, with: "")
    }

    func testATagInAUserMessageOrToolResultRendersTheSameModeAsNoTag() throws {
        let text = try rewritten()
        for tag in Self.tags {
            let tagged = "Line \(tag) end"
            let plain = "Line end"
            XCTAssertEqual(try mode(render(text, messages: user(tagged)), body: tagged),
                           try mode(render(text, messages: user(plain)), body: plain), tag)
            XCTAssertEqual(try mode(render(text, messages: toolTurn(tagged)), body: tagged),
                           try mode(render(text, messages: toolTurn(plain)), body: plain), tag)
        }
    }

    func testTagTextSurvivesIntoThePrompt() throws {
        let text = try rewritten()
        for tag in Self.tags {
            XCTAssertTrue(try render(text, messages: user("a \(tag) b")).contains("a \(tag) b"), tag)
            XCTAssertTrue(try render(text, messages: toolTurn("a \(tag) b")).contains("<tool_response>a \(tag) b</tool_response>"), tag)
        }
    }

    func testReasoningEffortSelectsTheModeOverAnyMessageTag() throws {
        let text = try rewritten()
        for (effort, marker) in [("low", "Apollo — [L2]"), ("medium", "Athena — [L4]"), ("high", "Solstice — [L6]"), ("xhigh", "Hyperion — [L7]"), ("max", "Proteus — [L10]")] {
            for body in ["hello", "[L9] [default] hello"] {
                let prompt = try render(text, messages: user(body), effort: effort)
                XCTAssertTrue(prompt.contains("Reasoning effort: \(marker)"), "\(effort): \(body)")
                XCTAssertTrue(prompt.hasSuffix("<|assistant|><think>"), "\(effort): \(body)")
            }
        }
        XCTAssertTrue(try render(text, messages: user("[L9] hello")).contains("Reasoning effort: Proteus — [L10]"))
    }

    func testTemplateVariablesStillDisableThinking() throws {
        let template = try Template(try rewritten(), with: .init(lstripBlocks: true, trimBlocks: true))
        let messages = try Value(any: user("hello [L9]"))
        let prompt = try template.render(["messages": messages, "add_generation_prompt": .boolean(true), "regular": .boolean(true)])
        XCTAssertTrue(prompt.hasSuffix("<|assistant|>"))
        let off = try template.render(["messages": messages, "add_generation_prompt": .boolean(true), "enable_thinking": .boolean(false)])
        XCTAssertTrue(off.hasSuffix("<|assistant|><think></think>"))
    }

    func testTaglessToolConversationIsByteIdenticalWithAndWithoutTheRewrite() throws {
        let original = ChatTemplateCompatibility.rewriteNumericAttributes(try source()).template
        let text = try rewritten()
        XCTAssertNotEqual(text, original)
        let messages = toolTurn("plain result") + [["role": "assistant", "content": "Done."], ["role": "user", "content": "Again."]]
        for effort in [nil, "low", "high"] as [String?] {
            XCTAssertEqual(try render(text, messages: messages, tools: [Self.tool], effort: effort),
                           try render(original, messages: messages, tools: [Self.tool], effort: effort))
        }
    }

    func testOtherTemplatesAreUntouchedAndChangedBytesWarn() throws {
        for path in ["glm53-chat-template/chat_template.jinja", "glm53-abliterated-chat-template/chat_template.jinja"] {
            let text = try source(path)
            let result = ChatTemplateCompatibility.rewrite(text)
            XCTAssertEqual(result, ChatTemplateCompatibility.rewriteNumericAttributes(text), path)
            XCTAssertFalse(result.messageTagScanRemoved || result.messageTagScanKept, path)
        }
        let changed = try source() + " "
        let result = ChatTemplateCompatibility.rewrite(changed)
        XCTAssertFalse(result.messageTagScanRemoved)
        XCTAssertTrue(result.messageTagScanKept)
        XCTAssertEqual(result.template, ChatTemplateCompatibility.rewriteNumericAttributes(changed).template)
        XCTAssertTrue(try XCTUnwrap(ChatTemplateCompatibility.logLine(result)).contains("warning=message_tag_scan_kept"))
    }

    func testLoadLogsOneCompatLine() throws {
        let line = try XCTUnwrap(ChatTemplateCompatibility.logLine(ChatTemplateCompatibility.rewrite(try source())))
        XCTAssertEqual(line.components(separatedBy: "event=chat_template_compat").count, 2)
        XCTAssertTrue(line.contains("rewrite=numeric_attribute_access,message_tag_scan"))
    }

    // MARK: SPEC-018-R010 thinking default

    private func artifact(_ template: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data(template.utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        return directory
    }

    private func solsticeRequest(_ effort: String?, tools: Bool = false, json: Bool = false) throws -> ChatCompletionRequest {
        var body: [String: Any] = ["model": "zai-org/glm-5.3-flash-uncensored", "messages": [["role": "user", "content": "hi"]], "max_tokens": 16]
        if let effort { body["reasoning_effort"] = effort }
        if tools { body["tools"] = [Self.tool] }
        if json { body["response_format"] = ["type": "json_object"] }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    private func renderContext(_ request: ChatCompletionRequest, supportsToggle: Bool) throws -> String {
        let context = try ModelRuntime.userInput(for: request, templateSupportsThinkingToggle: supportsToggle).additionalContext ?? [:]
        var values: [String: Value] = ["messages": try Value(any: user("hi")), "add_generation_prompt": .boolean(true)]
        if let effort = context["reasoning_effort"] as? String { values["reasoning_effort"] = .string(effort) }
        if let thinking = context["enable_thinking"] as? Bool { values["enable_thinking"] = .boolean(thinking) }
        return try Template(try rewritten(), with: .init(lstripBlocks: true, trimBlocks: true)).render(values)
    }

    func testTheReviewedTemplateIsNotAThinkingToggleAndNoOtherTemplateChanges() throws {
        XCTAssertFalse(ModelRuntime.chatTemplateSupportsThinkingToggle(in: try artifact(try source())))
        XCTAssertTrue(ModelRuntime.chatTemplateSupportsThinkingToggle(in: try artifact(try source() + " ")),
                      "One changed byte is not the reviewed template; the key is the SHA-256")
    }

    func testEveryEffortThatIsNotNoneRendersAnOpenThinkOnTheReviewedTemplate() throws {
        let toggle = ModelRuntime.chatTemplateSupportsThinkingToggle(in: try artifact(try source()))
        for effort in [nil, "minimal", "low", "medium", "high", "xhigh", "max"] as [String?] {
            for tools in [false, true] {
                let request = try solsticeRequest(effort, tools: tools)
                XCTAssertNil(try ModelRuntime.userInput(for: request, templateSupportsThinkingToggle: toggle).additionalContext?["enable_thinking"])
                XCTAssertTrue(try renderContext(request, supportsToggle: toggle).hasSuffix("<|assistant|><think>"), "\(effort ?? "omitted") tools=\(tools)")
            }
        }
    }

    func testNoneAndStructuredOutputStayThinkingOffOnTheReviewedTemplate() throws {
        let toggle = ModelRuntime.chatTemplateSupportsThinkingToggle(in: try artifact(try source()))
        for request in [try solsticeRequest("none"), try solsticeRequest("none", tools: true), try solsticeRequest("high", json: true)] {
            let prompt = try renderContext(request, supportsToggle: toggle)
            XCTAssertTrue(prompt.hasSuffix("<|assistant|><think></think>"))
            XCTAssertEqual(prompt, try renderContext(request, supportsToggle: true), "Same bytes as when the toggle was set")
        }
    }
}
