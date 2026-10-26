import Foundation
import Jinja
import MLXLMCommon
@testable import macprovider_cli
import XCTest

/// GLM-5.3-Flash's chat template uses Jinja2 numeric attribute access
/// (`m.content.0.type`), which the pinned swift-jinja 2.5.1 parser rejects.
/// `ChatTemplateCompatibility` rewrites it to the equivalent subscript; the
/// rendering must equal transformers' Jinja2 rendering byte for byte
/// (`scripts/tests/fixtures/glm53-chat-template`).
final class GLM5NextChatTemplateTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/tests/fixtures/glm53-chat-template")

    func testRewriteIsExactAndNarrow() {
        func rewritten(_ text: String) -> String { ChatTemplateCompatibility.rewrite(text).template }
        XCTAssertEqual(rewritten("{%- if m.content.0.type == 'x' -%}"), "{%- if m.content[0].type == 'x' -%}")
        XCTAssertEqual(rewritten("{{ tr.output.0.type }}"), "{{ tr.output[0].type }}")
        XCTAssertEqual(rewritten("{{ a.10 }}{{ f().1 }}{{ x[0].2 }}"), "{{ a[10] }}{{ f()[1] }}{{ x[0][2] }}")
        // Untouched: text outside tags, string literals, floats, identifiers
        // ending in digits, and an identifier after the dot.
        let untouched = [
            "v1.0 m.content.0 outside tags",
            "{{ 'm.content.0' }}{{ \"a.1\" }}",
            "{{ 1.5 + x }}{% set y = 0.25 %}",
            "{{ loop.index0 }}{{ item.v2 }}",
            "{{ x.0abc }}",
        ]
        for text in untouched {
            XCTAssertEqual(rewritten(text), text)
            XCTAssertEqual(ChatTemplateCompatibility.rewrite(text).numericAttributeRewrites, 0)
        }
    }

    func testGLM53TemplateNeedsExactlyTheFourRewritesAndThenParses() throws {
        let original = try String(contentsOf: Self.fixtures.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        XCTAssertThrowsError(try Template(original, with: .init(lstripBlocks: true, trimBlocks: true)))
        let result = ChatTemplateCompatibility.rewrite(original)
        XCTAssertEqual(result.numericAttributeRewrites, 4)
        XCTAssertNoThrow(try Template(result.template, with: .init(lstripBlocks: true, trimBlocks: true)))
        // Only the four `.0` accesses changed.
        XCTAssertEqual(result.template.count, original.count + 4)
    }

    /// The swift-transformers rendering context (`PreTrainedTokenizer
    /// .applyChatTemplate`): messages, add_generation_prompt, tools, the
    /// additional context, and the tokenizer config's special tokens.
    func testRenderingEqualsTheJinja2ReferenceByteForByte() throws {
        let original = try String(contentsOf: Self.fixtures.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        let template = try Template(
            ChatTemplateCompatibility.rewrite(original).template,
            with: .init(lstripBlocks: true, trimBlocks: true)
        )
        let (cases, references) = try Self.loadCases()
        XCTAssertEqual(cases.count, 10)
        for (testCase, reference) in zip(cases, references) {
            let name = try XCTUnwrap(testCase["name"] as? String)
            XCTAssertEqual(name, reference["name"] as? String)
            var context: [String: Value] = [
                "messages": try .array((testCase["messages"] as! [Any]).map { try Value(any: $0) }),
                "add_generation_prompt": .boolean(true),
                "eos_token": .string("<|endoftext|>"),
                "pad_token": .string("<|endoftext|>"),
            ]
            if let tools = testCase["tools"] as? [Any] {
                context["tools"] = try .array(tools.map { try Value(any: $0) })
            }
            for (key, value) in (testCase["context"] as? [String: Any]) ?? [:] {
                context[key] = try Value(any: value)
            }
            let rendered = try template.render(context)
            XCTAssertEqual(rendered, reference["text"] as? String, name)
        }
    }

    /// With the real artifact: the provider's tokenizer loader applies the
    /// rewrite and produces exactly the reference token ids.
    func testArtifactTokenizerMatchesTheReferenceTokenIDs() async throws {
        guard let raw = ProcessInfo.processInfo.environment["MACPROVIDER_GLM53_ARTIFACT_DIR"], !raw.isEmpty else {
            throw XCTSkip("MACPROVIDER_GLM53_ARTIFACT_DIR is not set")
        }
        let tokenizer = try await ChatTemplateCompatTokenizerLoader().load(
            from: URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        )
        XCTAssertTrue(tokenizer is ChatTemplateTokenizer)
        let (cases, references) = try Self.loadCases()
        for (testCase, reference) in zip(cases, references) {
            let name = testCase["name"] as! String
            let ids = try tokenizer.applyChatTemplate(
                messages: (testCase["messages"] as! [[String: Any]]).map { $0 as [String: any Sendable] },
                tools: (testCase["tools"] as? [[String: Any]])?.map { $0 as [String: any Sendable] },
                additionalContext: (testCase["context"] as? [String: Any]).map { $0 as [String: any Sendable] }
            )
            XCTAssertEqual(ids, reference["ids"] as? [Int], name)
        }
    }

    private static func loadCases() throws -> ([[String: Any]], [[String: Any]]) {
        let cases = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixtures.appendingPathComponent("cases.json"))
        ) as! [[String: Any]]
        let references = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixtures.appendingPathComponent("reference.json"))
        ) as! [[String: Any]]
        return (cases, references)
    }
}
