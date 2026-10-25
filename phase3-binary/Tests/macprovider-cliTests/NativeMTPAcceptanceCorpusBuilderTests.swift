#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class NativeMTPAcceptanceCorpusBuilderTests: XCTestCase {
    func testFeatureFixturesUseConsumedReasoningAndHistoryControls() throws {
        for index in 0..<3 {
            let data = try JSONSerialization.data(withJSONObject: NativeMTPAcceptanceCorpusBuilder.requestObject(
                modelID: "zai-org/glm-5.3-flash", index: index, padding: 0
            ))
            let request = try ChatCompletionRequest.parse(data: data)
            XCTAssertFalse(request.stream)
            XCTAssertEqual(request.maxTokens, 256)
            XCTAssertEqual(request.temperature, index == 1 ? 0 : 1)
            XCTAssertEqual(request.topP, index == 1 ? 1 : 0.95)
            if index != 0 {
                XCTAssertEqual(request.templateReasoningEffort(for: request.model), "high")
                XCTAssertTrue(request.messages.contains { $0.role == .tool })
                XCTAssertTrue(request.messages.contains {
                    $0.role == .assistant && $0.reasoningContent?.isEmpty == false && $0.toolCalls?.isEmpty == false
                })
            }
        }
    }
}
#endif
