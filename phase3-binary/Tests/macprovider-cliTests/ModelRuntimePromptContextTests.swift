import XCTest
import Jinja
import MacProviderCore
@testable import macprovider_cli

final class ModelRuntimePromptContextTests: XCTestCase {
    func testThinkingCapableTemplatesDisableFlagRegardlessOfModelFamily() throws {
        let artifact = try artifactDirectory(
            chatTemplate: #"{% if enable_thinking is defined and enable_thinking is false %}<think></think>{% endif %}{% if preserve_thinking %}preserve{% endif %}"#
        )
        XCTAssertTrue(ModelRuntime.chatTemplateSupportsThinkingToggle(in: artifact))
        XCTAssertTrue(ModelRuntime.chatTemplateSupportsPreserveThinking(in: artifact))

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
                templateSupportsThinkingToggle: ModelRuntime.chatTemplateSupportsThinkingToggle(in: artifact),
                templateSupportsPreserveThinking: ModelRuntime.chatTemplateSupportsPreserveThinking(in: artifact)
            )
            let context = try XCTUnwrap(input.additionalContext, model)
            XCTAssertEqual(context["enable_thinking"] as? Bool, false, model)
            XCTAssertEqual(context["preserve_thinking"] as? Bool, true, model)
        }
    }

    func testTemplateAdditionalContextRequiresBothMarkersForPreserveThinking() throws {
        XCTAssertNil(ModelRuntime.templateAdditionalContext(
            supportsThinkingToggle: false,
            supportsPreserveThinking: false
        ))

        let enableOnly = try XCTUnwrap(ModelRuntime.templateAdditionalContext(
            supportsThinkingToggle: true,
            supportsPreserveThinking: false
        ))
        XCTAssertEqual(enableOnly["enable_thinking"] as? Bool, false)
        XCTAssertNil(enableOnly["preserve_thinking"])

        let both = try XCTUnwrap(ModelRuntime.templateAdditionalContext(
            supportsThinkingToggle: true,
            supportsPreserveThinking: true
        ))
        XCTAssertEqual(both["enable_thinking"] as? Bool, false)
        XCTAssertEqual(both["preserve_thinking"] as? Bool, true)

        let preserveOnly = try artifactDirectory(chatTemplate: #"{% if preserve_thinking %}preserve{% endif %}"#)
        XCTAssertFalse(ModelRuntime.chatTemplateSupportsThinkingToggle(in: preserveOnly))
        XCTAssertTrue(ModelRuntime.chatTemplateSupportsPreserveThinking(in: preserveOnly))
        XCTAssertNil(ModelRuntime.templateAdditionalContext(
            supportsThinkingToggle: false,
            supportsPreserveThinking: true
        ))
    }

    func testNonThinkingTemplatesKeepDefaultContextRegardlessOfModelFamilyName() throws {
        let coderArtifact = try artifactDirectory(
            chatTemplate: #"{% if add_generation_prompt %}<|im_start|>assistant\n{% endif %}"#
        )
        XCTAssertFalse(ModelRuntime.chatTemplateSupportsThinkingToggle(in: coderArtifact))
        XCTAssertFalse(ModelRuntime.chatTemplateSupportsPreserveThinking(in: coderArtifact))

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
            tokenizerConfig: #"{"chat_template":"{% if enable_thinking is false and preserve_thinking %}direct{% endif %}"}"#
        )
        XCTAssertTrue(ModelRuntime.chatTemplateSupportsThinkingToggle(in: artifact))
        XCTAssertTrue(ModelRuntime.chatTemplateSupportsPreserveThinking(in: artifact))
    }

    func testPreserveThinkingMakesRenderedTurnsAppendOnly() throws {
        let template = try Template(
            "{% for message in messages %}{{ message.role }}:{% if message.role == 'assistant' and preserve_thinking %}<think>\n\n</think>\n\n{% endif %}{{ message.content }}\n{% endfor %}{% if add_generation_prompt %}assistant:{% if enable_thinking == false %}<think>\n\n</think>\n\n{% endif %}{% endif %}"
        )
        let user = ["role": "user", "content": "first"]
        let assistant = ["role": "assistant", "content": "answer"]
        let nextUser = ["role": "user", "content": "second"]
        let flags: [String: Value] = [
            "enable_thinking": .boolean(false),
            "preserve_thinking": .boolean(true),
            "add_generation_prompt": .boolean(true),
        ]
        let firstPrompt = try template.render(flags.merging([
            "messages": try Value(any: [user]),
        ]) { _, new in new })
        let secondPrompt = try template.render(flags.merging([
            "messages": try Value(any: [user, assistant, nextUser]),
        ]) { _, new in new })

        XCTAssertTrue(secondPrompt.hasPrefix(firstPrompt + "answer\n"), "\nfirst:\n\(firstPrompt)\nsecond:\n\(secondPrompt)")
    }

    func testSameModelIDDifferentArtifactsResolveCapabilityFromSnapshotHash() async throws {
        let thinkingArtifact = try artifactDirectory(
            chatTemplate: #"{% if enable_thinking %}<think>{% endif %}{% if preserve_thinking %}preserve{% endif %}"#
        )
        let nonThinkingArtifact = try artifactDirectory(
            chatTemplate: #"{{ messages | tojson }}"#
        )
        let thinkingHash = String(repeating: "a", count: 64)
        let nonThinkingHash = String(repeating: "b", count: 64)
        let capabilities = ModelRuntime.thinkingToggleCapabilities(for: [
            "shared-model-thinking-artifact": ModelRuntimeTargetAuthority(
                modelArgument: thinkingArtifact.path,
                artifactSHA256: thinkingHash,
                catalogRevision: "thinking-revision"
            ),
            "shared-model-non-thinking-artifact": ModelRuntimeTargetAuthority(
                modelArgument: nonThinkingArtifact.path,
                artifactSHA256: nonThinkingHash,
                catalogRevision: "non-thinking-revision"
            ),
        ])

        XCTAssertEqual(capabilities[thinkingHash], true)
        XCTAssertEqual(capabilities[nonThinkingHash], false)
        let preserveCapabilities = ModelRuntime.preserveThinkingCapabilities(for: [
            "shared-model-thinking-artifact": ModelRuntimeTargetAuthority(
                modelArgument: thinkingArtifact.path,
                artifactSHA256: thinkingHash,
                catalogRevision: "thinking-revision"
            ),
            "shared-model-non-thinking-artifact": ModelRuntimeTargetAuthority(
                modelArgument: nonThinkingArtifact.path,
                artifactSHA256: nonThinkingHash,
                catalogRevision: "non-thinking-revision"
            ),
        ])
        XCTAssertEqual(preserveCapabilities[thinkingHash], true)
        XCTAssertEqual(preserveCapabilities[nonThinkingHash], false)

        let modelID = "mlx-community/shared-model-id"
        let runtime = ModelRuntime(
            modelID: modelID,
            modelHash: thinkingHash,
            templateSupportsThinkingToggle: true,
            templateSupportsPreserveThinking: true,
            warmSwapEnabled: true,
            targetAuthorities: [
                modelID: ModelRuntimeTargetAuthority(
                    modelArgument: nonThinkingArtifact.path,
                    artifactSHA256: nonThinkingHash,
                    catalogRevision: "non-thinking-revision"
                )
            ],
            loader: { _ in throw URLError(.unsupportedURL) },
            testLoader: { _ in (modelID, nonThinkingHash) }
        )

        let thinkingSnapshot = await runtime.currentSnapshot()
        let task = try await runtime.beginSwap(targetModelID: modelID)
        try await task.value
        let nonThinkingSnapshot = await runtime.currentSnapshot()

        XCTAssertEqual(thinkingSnapshot.modelID, modelID)
        XCTAssertEqual(nonThinkingSnapshot.modelID, modelID)
        XCTAssertEqual(thinkingSnapshot.modelHash, thinkingHash)
        XCTAssertEqual(nonThinkingSnapshot.modelHash, nonThinkingHash)
        XCTAssertTrue(thinkingSnapshot.templateSupportsThinkingToggle)
        XCTAssertFalse(nonThinkingSnapshot.templateSupportsThinkingToggle)
        XCTAssertTrue(thinkingSnapshot.templateSupportsPreserveThinking)
        XCTAssertFalse(nonThinkingSnapshot.templateSupportsPreserveThinking)
        XCTAssertFalse(ModelRuntime.resolvedTemplateSupportsThinkingToggle(
            artifactSHA256: String(repeating: "c", count: 64),
            configuredArtifactSHA256: thinkingHash,
            configuredSupportsThinkingToggle: true,
            targetCapabilitiesByArtifactSHA256: capabilities
        ))
    }

    func testPreserveThinkingCapabilityRequiresEnableThinkingMarker() async throws {
        let preserveOnlyArtifact = try artifactDirectory(
            chatTemplate: #"{% if preserve_thinking %}preserve{% endif %}"#
        )
        let preserveOnlyHash = String(repeating: "c", count: 64)
        let capabilities = ModelRuntime.preserveThinkingCapabilities(for: [
            "preserve-only": ModelRuntimeTargetAuthority(
                modelArgument: preserveOnlyArtifact.path,
                artifactSHA256: preserveOnlyHash,
                catalogRevision: "preserve-only-revision"
            ),
        ])
        XCTAssertEqual(capabilities[preserveOnlyHash], false)

        let runtime = ModelRuntime(
            modelID: "mlx-community/preserve-only",
            modelHash: preserveOnlyHash,
            templateSupportsThinkingToggle: false,
            templateSupportsPreserveThinking: true,
            warmSwapEnabled: true,
            loader: { _ in throw URLError(.unsupportedURL) }
        )
        let snapshot = await runtime.currentSnapshot()
        XCTAssertFalse(snapshot.templateSupportsThinkingToggle)
        XCTAssertFalse(snapshot.templateSupportsPreserveThinking)
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
