import Foundation
import Jinja
import MLXLMCommon
import MacProviderCore
@testable import macprovider_cli
import XCTest

final class ReasoningEffortTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/tests/fixtures")

    private func request(model: String, effort: String? = nil, extra: [String: Any] = [:]) throws -> ChatCompletionRequest {
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "Write hello."]]]
        if let effort { body["reasoning_effort"] = effort }
        body.merge(extra) { _, new in new }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    func testLowestEffortsNormalizeOnlyForEffortAwareFamilies() throws {
        let models = [
            "zai-org/glm-5.3-flash", "Jundot/GLM-5.3-Flash-oQ4e-mtp",
            "openai/gpt-oss-20b", "mlx-community/gpt-oss-120b-4bit",
            "qwen/qwen3.8-27b", "mlx-community/Qwen3.8-27B-4bit",
        ]
        for model in models {
            for effort in ChatCompletionRequest.acceptedReasoningEfforts {
                let request = try request(model: model, effort: effort)
                let expected = ["none", "minimal"].contains(effort) ? "low" : effort
                XCTAssertEqual(request.templateReasoningEffort, expected, "\(model): \(effort)")
                let input = try ModelRuntime.userInput(for: request)
                XCTAssertEqual(input.additionalContext?["reasoning_effort"] as? String, expected)
            }
            XCTAssertNil(try request(model: model).templateReasoningEffort)
        }
    }

    func testOtherFamiliesAndUnknownValuesRetainTheirBehavior() throws {
        for model in [
            "deepseek/deepseek-v4-flash", "z-ai/glm-4.5-air", "qwen3-8b", "qwen3-32b",
            "qwen/qwen3.5-27b", "qwen/qwen3.6-35b-a3b", "qwen3-coder-30b-a3b-instruct",
            "qwen/qwen3-30b-a3b-instruct-2507", "qwen2.5-coder-32b-instruct",
            "nvidia/nemotron-3-nano-30b-a3b", "google-gemma-4-26b-a4b-it",
            "meta-llama/llama-3.1-8b-instruct", "meta-llama/llama-3.2-3b-instruct",
            "mlx-community/qwen2-vl-2b-instruct-4bit", "unknown-model",
        ] {
            for effort in ChatCompletionRequest.acceptedReasoningEfforts {
                XCTAssertEqual(try request(model: model, effort: effort).templateReasoningEffort, effort, model)
            }
        }
        // Unknown API values still fail validation, never normalize to a higher level.
        XCTAssertThrowsError(try request(model: "zai-org/glm-5.3-flash", effort: "ultra"))
    }

    func testLoadedIdentityOverridesBuyerAliasForNormalization() throws {
        for effort in ["none", "minimal"] {
            let alias = try request(model: "local-alias", effort: effort)
            let input = try ModelRuntime.userInput(for: alias, toolSelectionModelID: "Jundot/GLM-5.3-Flash-oQ4e-mtp")
            XCTAssertEqual(input.additionalContext?["reasoning_effort"] as? String, "low")
            let glmAlias = try request(model: "zai-org/glm-5.3-flash", effort: effort)
            let other = try ModelRuntime.userInput(for: glmAlias, toolSelectionModelID: "deepseek/deepseek-v4-flash")
            XCTAssertEqual(other.additionalContext?["reasoning_effort"] as? String, effort)
        }
    }

    func testStructuredOutputAndToolDefaultsRemainLow() throws {
        let tools: [[String: Any]] = [["type": "function", "function": [
            "name": "lookup", "parameters": ["type": "object", "properties": [:]],
        ]]]
        for model in ["zai-org/glm-5.3-flash", "openai/gpt-oss-20b", "qwen/qwen3.8-27b", "deepseek/deepseek-v4-flash", "unknown"] {
            XCTAssertEqual(try request(model: model, extra: ["tools": tools]).templateReasoningEffort, "low")
            XCTAssertEqual(try request(model: model, effort: "high", extra: ["tools": tools]).templateReasoningEffort, "high")
            let formats: [[String: Any]] = [
                ["type": "json_object"],
                ["type": "json_schema", "json_schema": ["name": "answer", "schema": ["type": "object"]]],
            ]
            for format in formats {
                for effort in ChatCompletionRequest.acceptedReasoningEfforts {
                    let request = try request(model: model, effort: effort, extra: ["response_format": format])
                    XCTAssertEqual(request.templateReasoningEffort, "low")
                    let input = try ModelRuntime.userInput(for: request, templateSupportsThinkingToggle: true)
                    XCTAssertEqual(input.additionalContext?["reasoning_effort"] as? String, "low")
                    XCTAssertEqual(input.additionalContext?["enable_thinking"] as? Bool, false)
                }
            }
        }
    }

    private func render(_ path: String, request: ChatCompletionRequest, thinkingToggle: Bool = false) throws -> String {
        let source = try String(contentsOf: Self.fixtures.appendingPathComponent(path), encoding: .utf8)
        let template = try Template(ChatTemplateCompatibility.rewrite(source).template, with: .init(lstripBlocks: true, trimBlocks: true))
        let input = try ModelRuntime.userInput(for: request, templateSupportsThinkingToggle: thinkingToggle)
        var context: [String: Value] = [
            "messages": try Value(any: [["role": "user", "content": "Write hello."]]),
            "add_generation_prompt": .boolean(true), "bos_token": .string(""), "eos_token": .string(""),
        ]
        for (key, value) in input.additionalContext ?? [:] { context[key] = try Value(any: value) }
        return try template.render(context)
    }

    func testEffortTemplatesRenderNoneAndMinimalExactlyLikeLow() throws {
        for (model, path, marker) in [
            ("zai-org/glm-5.3-flash", "glm53-chat-template/chat_template.jinja", "Reasoning Effort: Low"),
            ("openai/gpt-oss-20b", "chat-templates-2107/gpt-oss-20b.jinja", "Reasoning: low"),
            ("qwen/qwen3.8-27b", "chat-templates-2107/qwen3.8-27b.jinja", "Reasoning effort is set to low."),
        ] {
            let low = try render(path, request: request(model: model, effort: "low"))
            XCTAssertTrue(low.contains(marker), model)
            for effort in ["none", "minimal"] {
                XCTAssertEqual(try render(path, request: request(model: model, effort: effort)), low, "\(model): \(effort)")
            }
        }
    }

    func testThinkingToggleTemplatesStayOffForLowestEfforts() throws {
        for (model, path, suffix) in [
            ("qwen3-8b", "chat-templates-2107/qwen3-8b.jinja", "<think>\n\n</think>\n\n"),
            ("qwen/qwen3.8-27b", "chat-templates-2107/qwen3.8-27b.jinja", "<think>\n\n</think>\n\n"),
            ("z-ai/glm-4.5-air", "chat-templates-2107/glm-4.5-air.jinja", "<think></think>"),
        ] {
            for effort in ["none", "minimal", "low"] {
                let prompt = try render(path, request: request(model: model, effort: effort), thinkingToggle: true)
                XCTAssertTrue(prompt.hasSuffix(suffix), "\(model): \(effort): \(prompt)")
            }
        }
    }

    func testDeepSeekNoneStillSelectsChatAndMinimalStillSelectsLowThinking() throws {
        for effort in ["none", "minimal"] {
            let input = try ModelRuntime.userInput(for: request(model: "deepseek/deepseek-v4-flash", effort: effort))
            let prompt = try DeepseekV4Encoding.renderPrompt(messages: [["role": "user", "content": "Write hello."]], tools: nil, additionalContext: input.additionalContext)
            XCTAssertTrue(prompt.hasSuffix(effort == "none" ? "</think>" : "<think>"), prompt)
        }
    }
}
