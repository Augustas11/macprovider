import XCTest
import MacProviderCore
@testable import macprovider_cli

final class ModelRuntimePromptContextTests: XCTestCase {
    func testThinkingCapableTemplatesDisableFlagRegardlessOfModelFamily() throws {
        let artifact = try artifactDirectory(
            chatTemplate: #"{% if enable_thinking is defined and enable_thinking is false %}<think></think>{% else %}<think>{% endif %}"#
        )
        XCTAssertTrue(ModelRuntime.chatTemplateSupportsThinkingToggle(in: artifact))

        for model in [
            "qwen/qwen3.6-27b",
            "mlx-community/GLM-4.5-Air-4bit",
            "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit",
        ] {
            let request = try ChatCompletionRequest.parse(data: Data(#"""
            {
                "model": "\#(model)",
                "messages": [{"role": "user", "content": "Reply exactly PONG"}],
                "max_tokens": 16,
                "temperature": 0
            }
            """#.utf8))

            let input = try ModelRuntime.userInput(
                for: request,
                templateSupportsThinkingToggle: ModelRuntime.chatTemplateSupportsThinkingToggle(in: artifact)
            )
            let context = try XCTUnwrap(input.additionalContext, model)
            XCTAssertEqual(context["enable_thinking"] as? Bool, false, model)
        }
    }

    func testNonThinkingTemplatesKeepDefaultContextRegardlessOfModelFamilyName() throws {
        let coderArtifact = try artifactDirectory(
            chatTemplate: #"{% if add_generation_prompt %}<|im_start|>assistant\n{% endif %}"#
        )
        XCTAssertFalse(ModelRuntime.chatTemplateSupportsThinkingToggle(in: coderArtifact))

        for model in [
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
            "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",
        ] {
            let request = try ChatCompletionRequest.parse(data: Data(#"""
            {
                "model": "\#(model)",
                "messages": [{"role": "user", "content": "Reply exactly PONG"}]
            }
            """#.utf8))
            let input = try ModelRuntime.userInput(
                for: request,
                templateSupportsThinkingToggle: ModelRuntime.chatTemplateSupportsThinkingToggle(in: coderArtifact)
            )
            XCTAssertNil(input.additionalContext, model)
        }
    }

    func testTokenizerConfigEmbeddedTemplateIsDetected() throws {
        let artifact = try artifactDirectory(
            tokenizerConfig: #"{"chat_template":"{% if enable_thinking is false %}direct{% endif %}"}"#
        )
        XCTAssertTrue(ModelRuntime.chatTemplateSupportsThinkingToggle(in: artifact))
    }

    private func artifactDirectory(
        chatTemplate: String? = nil,
        tokenizerConfig: String? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-runtime-prompt-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        if let chatTemplate {
            try Data(chatTemplate.utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        }
        if let tokenizerConfig {
            try Data(tokenizerConfig.utf8).write(to: directory.appendingPathComponent("tokenizer_config.json"))
        }
        return directory
    }
}
