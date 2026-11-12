import Foundation
import MLXLMCommon
import MacProviderCore
@testable import macprovider_cli
import XCTest

/// The DSpark measurement's frozen requests (`scripts/lab/dsv4/dsv4-dspark-requests.json`,
/// written by `make_dspark_requests.py`) go through the provider's own
/// request path: `ChatCompletionRequest.parse`, `ModelRuntime.userInput`, the
/// message generator and the DSV4 renderer give the frozen prompt byte for
/// byte, and with `DSV4_TOKENIZER_DIR` the production tokenizer gives the
/// frozen ids that the bench feeds the model.
final class DeepseekV4DSparkRequestsTests: XCTestCase {
    private typealias Encoding = DeepseekV4Encoding

    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/lab/dsv4/dsv4-dspark-requests.json")

    private func requests() throws -> [Encoding.Value] {
        let doc = try Encoding.parseJSON(String(contentsOf: Self.fixture, encoding: .utf8))
        XCTAssertEqual(doc["schema"]?.string, "macprovider.dsv4-dspark-requests.v1")
        return try XCTUnwrap(doc["requests"]?.array)
    }

    private func prompt(_ item: Encoding.Value) throws -> String {
        let body = try XCTUnwrap(item["request"])
        let request = try ChatCompletionRequest.parse(data: Data(Encoding.toJSON(body).utf8))
        let input = try ModelRuntime.userInput(for: request)
        return try Encoding.renderPrompt(
            messages: DefaultMessageGenerator().generate(from: input),
            tools: input.tools,
            additionalContext: input.additionalContext
        )
    }

    func testFrozenRequestsRenderThroughTheProductionPath() throws {
        let items = try requests()
        XCTAssertEqual(items.count, 12)
        for item in items {
            XCTAssertEqual(try prompt(item), item["prompt"]?.string, item["name"]?.string ?? "")
        }
    }

    func testProductionTokenizerGivesTheFrozenIDs() async throws {
        guard let path = ProcessInfo.processInfo.environment["DSV4_TOKENIZER_DIR"] else {
            throw XCTSkip("DSV4_TOKENIZER_DIR not set")
        }
        let tokenizer = try await ChatTemplateCompatTokenizerLoader().load(from: URL(fileURLWithPath: path))
        XCTAssertTrue(tokenizer is DeepseekV4ChatTokenizer)
        for item in try requests() {
            let name = try XCTUnwrap(item["name"]?.string)
            let expected: [Int] = try XCTUnwrap(item["ids"]?.array).map {
                guard case .int(let id) = $0 else { XCTFail("non-integer id in \(name)"); return -1 }
                return id
            }
            let body = try XCTUnwrap(item["request"])
            let request = try ChatCompletionRequest.parse(data: Data(Encoding.toJSON(body).utf8))
            let input = try ModelRuntime.userInput(for: request)
            XCTAssertEqual(try tokenizer.applyChatTemplate(
                messages: DefaultMessageGenerator().generate(from: input),
                tools: input.tools, additionalContext: input.additionalContext
            ), expected, name)
        }
    }
}
