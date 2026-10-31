import XCTest
import Jinja
import MacProviderCore
import MLXLMCommon
import MLX
import MLXVLM
@testable import macprovider_cli

final class ModelRuntimePromptContextTests: XCTestCase {
    func testBonsaiThinkingRequiresModelOwnedCapabilityAndExplicitHighEffort() throws {
        for model in ["prism-ml/Ternary-Bonsai-2-4B-mlx-2bit", "buyer-alias", "/local/model"] {
            for effort in [nil, "none", "minimal", "low", "medium", "high", "xhigh", "max"] as [String?] {
                for capability in [false, true] {
                    let request = try bonsaiRequest(model: model, effort: effort)
                    let input = try ModelRuntime.userInput(
                        for: request, templateSupportsThinkingToggle: true,
                        supportsBonsaiThinking: capability)
                    let enabled = capability && ["high", "xhigh", "max"].contains(effort ?? "")
                    XCTAssertEqual(input.additionalContext?["enable_thinking"] as? Bool, enabled,
                                   "\(model), \(effort ?? "omitted"), \(capability)")
                }
            }
        }
        let request = try bonsaiRequest(effort: "high")
        let input = try ModelRuntime.userInput(for: request, supportsBonsaiThinking: true)
        XCTAssertNil(input.additionalContext?["enable_thinking"], "The template must support the toggle")
    }

    func testBonsaiThinkingStaysOffForStructuredOutputAndDeclaredTools() throws {
        let tool: [String: Any] = ["type": "function", "function": [
            "name": "lookup", "parameters": ["type": "object", "properties": [:]],
        ]]
        let cases: [[String: Any]] = [
            ["response_format": ["type": "json_object"]],
            ["response_format": ["type": "json_schema", "json_schema": [
                "name": "answer", "schema": ["type": "object", "properties": [:]],
            ]]],
            ["tools": [tool]],
            ["tools": [tool], "tool_choice": "auto"],
            ["tools": [tool], "tool_choice": "none"],
            ["tools": [tool], "tool_choice": "required"],
            ["tools": [tool], "tool_choice": ["type": "function", "function": ["name": "lookup"]]],
        ]
        for effort in ["high", "xhigh", "max"] {
            for extra in cases {
                let request = try bonsaiRequest(effort: effort, extra: extra)
                let input = try ModelRuntime.userInput(
                    for: request, templateSupportsThinkingToggle: true, supportsBonsaiThinking: true)
                XCTAssertEqual(input.additionalContext?["enable_thinking"] as? Bool, false)
            }
        }
        let emptyTools = try bonsaiRequest(effort: "high", extra: ["tools": []])
        XCTAssertTrue(ModelRuntime.bonsaiThinkingEnabled(for: emptyTools, supportsBonsaiThinking: true))
    }

    func testRealBonsaiTokenizerThinkingPrefixAndDefaultTokenIdentity() async throws {
        let paths = ProcessInfo.processInfo.environment["MACPROVIDER_TOKENIZER_DIRS"]?
            .split(separator: "\n").map(String.init) ?? []
        guard let path = paths.first(where: { path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("config.json")) else { return false }
            return ModelRuntime.usesPrismVLMContainer(configJSONData: data)
        }) else { throw XCTSkip("A Bonsai artifact is not configured in MACPROVIDER_TOKENIZER_DIRS") }
        let tokenizer = try await ChatTemplateCompatTokenizerLoader().load(from: URL(fileURLWithPath: path))
        let config = try tinyPrismConfiguration()
        let processor = BonsaiPromptTestProcessor(tokenizer: tokenizer)
        let prismContext = ModelContext(
            configuration: ModelConfiguration(id: "/local/artifact"),
            model: try PrismHadamardQwen35(config), processor: processor, tokenizer: tokenizer)
        let ordinaryContext = ModelContext(
            configuration: ModelConfiguration(id: "prism-ml/Ternary-Bonsai-2-4B-mlx-2bit"),
            model: Qwen35(config.base), processor: processor, tokenizer: tokenizer)
        let messages: [[String: any Sendable]] = [["role": "user", "content": "What is 2+2?"]]
        let disabled = try tokenizer.applyChatTemplate(
            messages: messages, tools: nil, additionalContext: ["enable_thinking": false])
        for effort in [nil, "none", "minimal", "low", "medium", "high", "xhigh", "max"] as [String?] {
            let request = try bonsaiRequest(effort: effort)
            let input = try ModelRuntime.userInput(
                for: request, templateSupportsThinkingToggle: true, supportsBonsaiThinking: true)
            let tokens = try tokenizer.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: input.additionalContext)
            let (serial, _) = try await ModelRuntime.preparedRequestInput(
                for: request, context: prismContext, templateSupportsThinkingToggle: true,
                templateSupportsPreserveThinking: false, toolSelectionModelID: "/local/artifact")
            let (alternate, _) = try await ModelRuntime.preparedRequestTokens(
                for: request, processor: processor, tokenizer: tokenizer,
                templateSupportsThinkingToggle: true, templateSupportsPreserveThinking: false,
                toolSelectionModelID: "/local/artifact", supportsBonsaiThinking: true)
            XCTAssertEqual(serial.text.tokens.asArray(Int.self), tokens)
            XCTAssertEqual(alternate, tokens)
            let (ordinary, _) = try await ModelRuntime.preparedRequestInput(
                for: request, context: ordinaryContext, templateSupportsThinkingToggle: true,
                templateSupportsPreserveThinking: false,
                toolSelectionModelID: "prism-ml/Ternary-Bonsai-2-4B-mlx-2bit")
            XCTAssertEqual(ordinary.text.tokens.asArray(Int.self), disabled,
                           "A model name must not opt an ordinary Qwen model into Bonsai thinking")
            if ["high", "xhigh", "max"].contains(effort ?? "") {
                XCTAssertTrue(ReasoningOutput.promptLeavesThinkOpen(tokenizer.decode(tokenIds: Array(tokens.suffix(16)))))
                XCTAssertNotEqual(tokens, disabled)
            } else {
                XCTAssertEqual(tokens, disabled, "\(effort ?? "omitted") changed the default prompt")
            }
        }
    }

    private func tinyPrismConfiguration() throws -> PrismHadamardQwen35Configuration {
        // No forward pass or model weights are needed to establish the loaded type.
        let object: [String: Any] = [
            "model_type": "prism_hadamard_qwen35", "schema_version": 2,
            "base_model_type": "qwen3_5", "tensor_namespace": "mlx-vlm-qwen3_5",
            "gdn_activation_layout": "grouped",
            "quantization": ["bits": 2, "group_size": 128, "mode": "affine"],
            "modules": [["path": "model.embed_tokens", "block": 512,
                         "embedding": true, "dtype": "float16"]],
            "text_config": [
                "model_type": "qwen3_5_text", "hidden_size": 512,
                "num_hidden_layers": 2, "intermediate_size": 512,
                "num_attention_heads": 1, "num_key_value_heads": 1,
                "head_dim": 128, "linear_num_value_heads": 1,
                "linear_num_key_heads": 1, "linear_key_head_dim": 128,
                "linear_value_head_dim": 128, "linear_conv_kernel_dim": 4,
                "vocab_size": 4, "full_attention_interval": 2, "tie_word_embeddings": true,
            ],
            "vision_config": [
                "model_type": "qwen3_5", "depth": 1, "hidden_size": 8,
                "intermediate_size": 16, "out_hidden_size": 512,
                "num_heads": 1, "patch_size": 16, "spatial_merge_size": 1,
                "temporal_patch_size": 1, "num_position_embeddings": 8,
            ],
        ]
        return try JSONDecoder().decode(PrismHadamardQwen35Configuration.self,
                                       from: JSONSerialization.data(withJSONObject: object))
    }

    private func bonsaiRequest(
        model: String = "buyer-alias", effort: String? = nil, extra: [String: Any] = [:]
    ) throws -> ChatCompletionRequest {
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "What is 2+2?"]]]
        if let effort { body["reasoning_effort"] = effort }
        body.merge(extra) { _, new in new }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

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

private struct BonsaiPromptTestProcessor: UserInputProcessor {
    let tokenizer: any MLXLMCommon.Tokenizer

    func prepare(input: UserInput) throws -> LMInput {
        let tokens = try tokenizer.applyChatTemplate(
            messages: DefaultMessageGenerator().generate(from: input), tools: nil,
            additionalContext: input.additionalContext)
        return LMInput(tokens: MLXArray(tokens.map(Int32.init)))
    }
}
