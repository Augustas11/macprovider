import Foundation
import XCTest
@testable import macprovider_cli

final class PrismContainerSelectionTests: XCTestCase {
    func testPrismUsesFullArtifactLoader() {
        XCTAssertTrue(selects(["model_type": "prism_hadamard_qwen35"]))
    }

    func testOrdinaryModelsKeepTheirLoader() {
        for modelType in ["qwen3_5", "qwen3_5_text", "llama", "prism_hadamard_qwen35_text",
                          "prism_hadamard_qwen35-evil", "PRISM_HADAMARD_QWEN35"] {
            XCTAssertFalse(selects(["model_type": modelType]), modelType)
        }
    }

    func testNestedLabelsAndMalformedConfigDoNotSelect() {
        XCTAssertFalse(selects(["text_config": ["model_type": "prism_hadamard_qwen35"]]))
        XCTAssertFalse(selects(["architectures": ["prism_hadamard_qwen35"]]))
        XCTAssertFalse(selects(["model_type": ["prism_hadamard_qwen35"]]))
        XCTAssertFalse(ModelRuntime.usesPrismVLMContainer(configJSONData: Data("invalid".utf8)))
        XCTAssertFalse(ModelRuntime.usesPrismVLMContainer(configJSONData: Data("[]".utf8)))
    }

    private func selects(_ config: [String: Any]) -> Bool {
        ModelRuntime.usesPrismVLMContainer(
            configJSONData: try! JSONSerialization.data(withJSONObject: config))
    }
}
