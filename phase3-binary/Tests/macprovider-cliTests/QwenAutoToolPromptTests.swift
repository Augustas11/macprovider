import CryptoKit
import Foundation
import Jinja
import MacProviderCore
import MLXLMCommon
import XCTest
@testable import macprovider_cli

/// Tokenizer-only diagnostics: no weights, inference, artifact download or prompt logging.
/// Artifact directories must contain the catalog-pinned tokenizer/template files.
final class QwenAutoToolPromptTests: XCTestCase {
    private enum Profile: String {
        case coder = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
        case instruct = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"

        var environmentKey: String {
            self == .coder ? "MACPROVIDER_QWEN_CODER_ARTIFACT_DIR" : "MACPROVIDER_QWEN_INSTRUCT2507_ARTIFACT_DIR"
        }

        // SPEC-018 §3.11, UTF-8 chat_template.jinja SHA-256.
        var templateHash: String {
            self == .coder
                ? "672e747c77e990320152343b0a4951222e40de5645297905d89afba05586d827"
                : "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541"
        }
    }

    func testAutoFixtureRendersAllToolsAndMessagesWithoutCallPrefill() throws {
        let template = try Template("""
        {% for tool in tools %}{{ tool | tojson }}
        {% endfor %}{% for message in messages %}<|im_start|>{{ message.role }}
        {{ message.content }}<|im_end|>
        {% endfor %}<|im_start|>assistant

        """)
        for profile in [Profile.coder, .instruct] {
            let request = try fixture(profile)
            let input = try ModelRuntime.userInput(for: request, toolSelectionModelID: profile.rawValue)
            XCTAssertNil(try ModelRuntime.toolCallPrefill(for: request, toolSelectionModelID: profile.rawValue))
            try assertToolsPreserved(request, input: input)
            let rendered = try template.render([
                "messages": Value(any: DefaultMessageGenerator().generate(from: input)),
                "tools": Value(any: input.tools ?? []),
            ])
            XCTAssertTrue(rendered.contains("diagnostic_lookup"))
            XCTAssertTrue(rendered.contains("diagnostic_clock"))
            XCTAssertTrue(rendered.contains("diagnostic_city"))
            XCTAssertTrue(rendered.contains("DIAGNOSTIC_SYSTEM"))
            XCTAssertTrue(rendered.contains("DIAGNOSTIC_USER"))
            XCTAssertTrue(rendered.hasSuffix("<|im_start|>assistant\n"))
            XCTAssertFalse(rendered.contains("<tool_call>"))
        }
    }

    func testPinnedCoderArtifactAutoPromptAndHistory() async throws {
        try await checkArtifact(.coder)
    }

    func testPinnedInstruct2507ArtifactAutoPromptAndHistory() async throws {
        try await checkArtifact(.instruct)
    }

    /// Set PRIVATE_REQUEST to a raw saved Chat Completions JSON body and MODEL
    /// to one of the two exact profile IDs. The request's buyer alias is retained.
    /// Optional REFERENCE_IDS is a private JSON [Int] produced by the upstream
    /// tokenizer for the same full request. Failures never include input or IDs.
    func testPrivateOpenCodeAutoRequestPrompt() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MACPROVIDER_QWEN_PRIVATE_REQUEST"], !path.isEmpty else {
            throw XCTSkip("MACPROVIDER_QWEN_PRIVATE_REQUEST is not set")
        }
        guard let model = environment["MACPROVIDER_QWEN_PRIVATE_MODEL"],
              let profile = Profile(rawValue: model) else {
            XCTFail("Private replay requires an exact Qwen profile in MACPROVIDER_QWEN_PRIVATE_MODEL")
            return
        }
        let directory = try artifactDirectory(profile)
        do {
            let request = try ChatCompletionRequest.parse(data: Data(contentsOf: fileURL(path)))
            guard try ToolSelectionPolicy.selection(request.promptSource.toolChoice) == .auto else {
                XCTFail("Private replay requires auto tool choice")
                return
            }
            let tokenizer = try await pinnedTokenizer(profile, directory: directory)
            let input = try providerInput(request, profile: profile, directory: directory)
            try assertToolsPreserved(request, input: input)
            let ids = try render(input, tokenizer: tokenizer)
            let text = tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
            assertToolNamesAndProperties(input, rendered: text)
            XCTAssertTrue(text.hasSuffix("<|im_start|>assistant\n"), "Native assistant suffix is missing")
            for message in request.messages where message.role == .system || message.role == .user {
                if let content = message.content, !content.isEmpty {
                    XCTAssertTrue(text.contains(content), "A system/user message was not preserved")
                }
            }
            XCTAssertNil(try ModelRuntime.toolCallPrefill(for: request, toolSelectionModelID: profile.rawValue))
            if let reference = environment["MACPROVIDER_QWEN_PRIVATE_REFERENCE_IDS"], !reference.isEmpty {
                let expected = try JSONDecoder().decode([Int].self, from: Data(contentsOf: fileURL(reference)))
                XCTAssertTrue(ids == expected, "Private reference token IDs differ")
            }
        } catch {
            // Parser/template errors can embed private source text. Do not print error.
            XCTFail("Private prompt replay failed; request, prompt and tokenizer details withheld")
        }
    }

    private func checkArtifact(_ profile: Profile) async throws {
        let directory = try artifactDirectory(profile)
        let tokenizer = try await pinnedTokenizer(profile, directory: directory)
        for history in [false, true] {
            let request = try fixture(profile, history: history)
            let input = try providerInput(request, profile: profile, directory: directory)
            try assertToolsPreserved(request, input: input)
            let text = tokenizer.decode(tokenIds: try render(input, tokenizer: tokenizer), skipSpecialTokens: false)
            assertToolNamesAndProperties(input, rendered: text)
            XCTAssertTrue(text.contains("<|im_start|>system\n"))
            XCTAssertTrue(text.contains("DIAGNOSTIC_SYSTEM"))
            XCTAssertTrue(text.contains("<|im_start|>user\nDIAGNOSTIC_USER<|im_end|>"))
            XCTAssertTrue(text.hasSuffix("<|im_start|>assistant\n"))
            XCTAssertNil(try ModelRuntime.toolCallPrefill(for: request, toolSelectionModelID: profile.rawValue))
            if history {
                let expectedCall = profile == .coder
                    ? "<tool_call>\n<function=diagnostic_lookup>\n<parameter=diagnostic_city>\nParis\n</parameter>\n</function>\n</tool_call>"
                    : "<tool_call>\n{\"name\": \"diagnostic_lookup\", \"arguments\": {\"diagnostic_city\":\"Paris\"}}\n</tool_call>"
                XCTAssertTrue(text.contains("<|im_start|>assistant\n" + expectedCall))
                XCTAssertTrue(text.contains("<tool_response>\nDIAGNOSTIC_RESULT\n</tool_response>"))
                XCTAssertEqual(text.components(separatedBy: "DIAGNOSTIC_RESULT").count - 1, 1)
                XCTAssertFalse(text.contains("<tool_response id="))
                XCTAssertFalse(text.contains("call_diagnostic"))
            }
        }
    }

    private func providerInput(_ request: ChatCompletionRequest, profile: Profile, directory: URL) throws -> UserInput {
        try ModelRuntime.userInput(
            for: request,
            templateSupportsThinkingToggle: ModelRuntime.chatTemplateSupportsThinkingToggle(in: directory),
            templateSupportsPreserveThinking: ModelRuntime.chatTemplateSupportsPreserveThinking(in: directory),
            toolSelectionModelID: profile.rawValue
        )
    }

    private func render(_ input: UserInput, tokenizer: any MLXLMCommon.Tokenizer) throws -> [Int] {
        try tokenizer.applyChatTemplate(
            messages: DefaultMessageGenerator().generate(from: input),
            tools: input.tools,
            additionalContext: input.additionalContext
        )
    }

    private func assertToolsPreserved(_ request: ChatCompletionRequest, input: UserInput) throws {
        guard case .array(let original)? = request.promptSource.tools, !original.isEmpty,
              let tools = input.tools else {
            XCTFail("Expected nonempty tool definitions")
            return
        }
        XCTAssertTrue(tools.count == original.count, "Tool count changed")
        // Serialize through Jinja so native Value.null is compared as JSON null.
        let rendered = try Template("{{ tools | tojson }}").render(["tools": Value(any: tools)])
        let converted = try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [[String: Any]]
        guard let converted, converted.count == original.count else {
            XCTFail("Tool conversion shape changed")
            return
        }
        for (source, target) in zip(original, converted) {
            let sourceObject = try JSONSerialization.jsonObject(with: Data(source.deterministicJSONString().utf8)) as? [String: Any]
            let expected = sourceObject?["function"] as? [String: Any]
            let actual = target["function"] as? [String: Any]
            XCTAssertTrue(expected?["name"] as? String == actual?["name"] as? String, "Tool name changed")
            let expectedSchema = expected?["parameters"] as? NSDictionary
            let actualSchema = actual?["parameters"] as? NSDictionary
            XCTAssertTrue(expectedSchema != nil && expectedSchema == actualSchema, "Tool schema changed")
            XCTAssertTrue((expected?["description"] as? String) == (actual?["description"] as? String), "Tool description changed")
        }
    }

    private func assertToolNamesAndProperties(_ input: UserInput, rendered: String) {
        for tool in input.tools ?? [] {
            guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String else {
                XCTFail("Missing function descriptor")
                continue
            }
            XCTAssertTrue(rendered.contains(name), "A tool name is absent from the native prompt")
            let schema = function["parameters"] as? [String: Any]
            for key in (schema?["properties"] as? [String: Any] ?? [:]).keys {
                XCTAssertTrue(rendered.contains(key), "A schema property is absent from the native prompt")
            }
        }
    }

    private func pinnedTokenizer(_ profile: Profile, directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let template = try Data(contentsOf: directory.appendingPathComponent("chat_template.jinja"))
        let hash = SHA256.hash(data: template).map { String(format: "%02x", $0) }.joined()
        guard hash == profile.templateHash else { throw DiagnosticError.templateMismatch }
        return try await ChatTemplateCompatTokenizerLoader().load(from: directory)
    }

    private enum DiagnosticError: Error { case templateMismatch }

    private func artifactDirectory(_ profile: Profile) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[profile.environmentKey], !path.isEmpty else {
            throw XCTSkip("\(profile.environmentKey) is not set")
        }
        return fileURL(path)
    }

    private func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private func fixture(_ profile: Profile, history: Bool = false) throws -> ChatCompletionRequest {
        var messages: [[String: Any]] = [
            ["role": "system", "content": "DIAGNOSTIC_SYSTEM"],
            ["role": "user", "content": "DIAGNOSTIC_USER"],
        ]
        if history {
            messages += [
                ["role": "assistant", "content": "", "tool_calls": [["id": "call_diagnostic", "type": "function",
                    "function": ["name": "diagnostic_lookup", "arguments": #"{"diagnostic_city":"Paris"}"#]]]],
                ["role": "tool", "tool_call_id": "call_diagnostic", "content": "DIAGNOSTIC_RESULT"],
            ]
        }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": profile.rawValue, "messages": messages, "tool_choice": "auto", "max_tokens": 64,
            "tools": ["diagnostic_lookup", "diagnostic_clock"].map { name in
                ["type": "function", "function": ["name": name, "description": "Diagnostic function", "parameters": [
                    "type": "object", "properties": ["diagnostic_city": ["type": "string", "description": "Diagnostic city"]],
                    "required": ["diagnostic_city"], "additionalProperties": false,
                ]]] as [String: Any]
            },
        ]))
    }
}
