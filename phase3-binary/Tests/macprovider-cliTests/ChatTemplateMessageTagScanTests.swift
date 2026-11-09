import Foundation
import Jinja
import XCTest
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
}
