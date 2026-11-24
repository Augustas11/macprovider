import Foundation
import XCTest
@testable import macprovider_cli

/// #2467: Inkling 2 prompts render natively (`Inkling2Encoding`) to the bytes
/// the publisher's `chat_template.jinja` renders. Expected prompts come from
/// Jinja2 over that template with transformers' `tojson`
/// (`scripts/lab/2467/make_inkling2_prompt_fixtures.py`, same inputs).
final class Inkling2ChatEncodingTests: XCTestCase {
    private static let readFile: [String: any Sendable] = [
        "type": "function",
        "function": [
            "name": "read_file",
            "description": "Read a file from disk",
            "parameters": ["properties": ["path": ["type": "string"]], "required": ["path"], "type": "object"] as [String: any Sendable],
        ] as [String: any Sendable],
    ]
    private static let search: [String: any Sendable] = [
        "type": "function",
        "function": [
            "name": "search",
            "parameters": ["properties": ["limit": ["type": "integer"], "query": ["type": "string"]], "type": "object"] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    private func render(
        _ messages: [[String: any Sendable]], tools: [[String: any Sendable]]? = nil, effort: String? = nil
    ) throws -> String {
        try Inkling2Encoding.render(
            messages: messages, tools: tools, additionalContext: effort.map { ["reasoning_effort": $0] })
    }

    func testPlainUserTakesTheDefaultEffort() throws {
        XCTAssertEqual(try render([["role": "user", "content": "What is 17*23?"]]),
                       PLAIN)
    }

    func testSystemMessagesComeBeforeTheEffortMessage() throws {
        XCTAssertEqual(try render([
            ["role": "system", "content": "You are terse."],
            ["role": "user", "content": "H\u{e9}llo \"world\"\n/etc"],
        ], effort: "medium"), SYSTEM)
    }

    func testToolsAreDeclaredAsSortedCompactJSON() throws {
        XCTAssertEqual(try render([["role": "user", "content": "Read /etc/hosts."]],
                                  tools: [Self.readFile, Self.search], effort: "low"), TOOLS)
    }

    func testToolHistoryRendersCallFramesAndToolNames() throws {
        let call: [String: any Sendable] = [
            "id": "call_1", "type": "function",
            "function": [
                "name": "search",
                "arguments": [
                    "limit": 5, "query": "na\u{ef}ve \"q\"", "tags": ["a", "b"],
                    "zeta": ["b": true, "a": 0] as [String: any Sendable],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
        XCTAssertEqual(try render([
            ["role": "user", "content": "Find files."],
            ["role": "assistant", "content": "", "reasoning_content": "Search first.", "tool_calls": [call]],
            ["role": "tool", "tool_call_id": "call_1", "content": "[\"x.txt\"]"],
            ["role": "assistant", "content": "Found x.txt."],
            ["role": "user", "content": "Thanks"],
        ], tools: [Self.readFile, Self.search], effort: "none"), HISTORY)
    }

    func testEffortGoesLastWhenEveryMessageIsSystem() throws {
        XCTAssertEqual(try render([["role": "system", "content": "Only system."]], effort: "high"), SYSTEM_ONLY)
    }

    func testAssistantReasoningAndContentAreTwoFrames() throws {
        XCTAssertEqual(try render([
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": "Hello.", "reasoning_content": "Greet back."],
            ["role": "user", "content": "again"],
        ], effort: "max"), REASONING)
    }

    func testEveryEffortLevelMatchesTheTemplateMap() throws {
        let expected = ["none": "0", "minimal": "0.1", "low": "0.2", "medium": "0.7", "high": "0.9", "xhigh": "0.99", "max": "0.99"]
        for effort in ChatCompletionRequestEfforts.all {
            let prompt = try render([["role": "user", "content": "x"]], effort: effort)
            XCTAssertTrue(prompt.hasPrefix("<|message_system|><|content_text|>Thinking effort level: " + expected[effort]! + "<|end_message|>"), effort)
        }
        XCTAssertThrowsError(try render([["role": "user", "content": "x"]], effort: "extreme"))
    }

    func testTemplateErrorsAreErrors() {
        // Arguments as a JSON string, an unknown role and image parts fail
        // as the template's raise_exception does.
        let stringArguments: [String: any Sendable] = ["id": "c", "function": ["name": "f", "arguments": "{}"] as [String: any Sendable]]
        XCTAssertThrowsError(try render([["role": "user", "content": "x"], ["role": "assistant", "content": "", "tool_calls": [stringArguments]]]))
        XCTAssertThrowsError(try render([["role": "developer", "content": "x"]]))
        XCTAssertThrowsError(try render([["role": "user", "content": [["type": "image_url", "image_url": ["url": "x"] as [String: any Sendable]] as [String: any Sendable]]]]))
    }

    func testAppliesOnlyToTheInklingModelType() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        try Data(#"{"model_type":"inkling2_loop","architectures":["Inkling2LoopForConditionalGeneration"]}"#.utf8).write(to: config)
        XCTAssertTrue(Inkling2Encoding.applies(to: directory))
        try Data(#"{"model_type":"qwen3"}"#.utf8).write(to: config)
        XCTAssertFalse(Inkling2Encoding.applies(to: directory))
    }
}

private enum ChatCompletionRequestEfforts {
    static let all = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
}

// Rendered by Jinja2 from the publisher template.
private let PLAIN = "<|message_system|><|content_text|>Thinking effort level: 0.9<|end_message|><|message_user|><|content_text|>What is 17*23?<|end_message|>"
private let SYSTEM = "<|message_system|><|content_text|>You are terse.<|end_message|><|message_system|><|content_text|>Thinking effort level: 0.7<|end_message|><|message_user|><|content_text|>Héllo \"world\"\n/etc<|end_message|>"
private let TOOLS = "<|message_system|>tool_declare<|content_xml|>[{\"description\":\"Read a file from disk\",\"name\":\"read_file\",\"parameters\":{\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"type\":\"object\"},\"type\":\"function\"},{\"description\":\"\",\"name\":\"search\",\"parameters\":{\"properties\":{\"limit\":{\"type\":\"integer\"},\"query\":{\"type\":\"string\"}},\"type\":\"object\"},\"type\":\"function\"}]<|end_message|><|message_system|><|content_text|>Thinking effort level: 0.2<|end_message|><|message_user|><|content_text|>Read /etc/hosts.<|end_message|>"
private let HISTORY = "<|message_system|>tool_declare<|content_xml|>[{\"description\":\"Read a file from disk\",\"name\":\"read_file\",\"parameters\":{\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"type\":\"object\"},\"type\":\"function\"},{\"description\":\"\",\"name\":\"search\",\"parameters\":{\"properties\":{\"limit\":{\"type\":\"integer\"},\"query\":{\"type\":\"string\"}},\"type\":\"object\"},\"type\":\"function\"}]<|end_message|><|message_system|><|content_text|>Thinking effort level: 0<|end_message|><|message_user|><|content_text|>Find files.<|end_message|><|message_model|><|content_thinking|>Search first.<|end_message|><|message_model|>search<|content_invoke_tool_json|>{\"name\":\"search\",\"args\":{\"limit\":5,\"query\":\"naïve \\\"q\\\"\",\"tags\":[\"a\",\"b\"],\"zeta\":{\"a\":0,\"b\":true}}}<|end_message|><|content_model_end_sampling|><|message_tool|>search<|content_text|>[\"x.txt\"]<|end_message|><|message_model|><|content_text|>Found x.txt.<|end_message|><|content_model_end_sampling|><|message_user|><|content_text|>Thanks<|end_message|>"
private let SYSTEM_ONLY = "<|message_system|><|content_text|>Only system.<|end_message|><|message_system|><|content_text|>Thinking effort level: 0.9<|end_message|>"
private let REASONING = "<|message_system|><|content_text|>Thinking effort level: 0.99<|end_message|><|message_user|><|content_text|>hi<|end_message|><|message_model|><|content_thinking|>Greet back.<|end_message|><|message_model|><|content_text|>Hello.<|end_message|><|content_model_end_sampling|><|message_user|><|content_text|>again<|end_message|>"
