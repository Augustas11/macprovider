import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-023-R029 step 7: `model_pinned` is a strict YAML boolean, off by
/// default, and a pinned config is kept by the model upgrade.
final class ModelPinnedConfigTests: XCTestCase {
    private func load(yaml: String?) throws -> AppConfig {
        try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [:],
            fileExists: { _ in yaml != nil },
            readFile: { _ in yaml ?? "" }
        )
    }

    func testDefaultsOff() throws {
        XCTAssertFalse(try load(yaml: nil).modelPinned)
        XCTAssertFalse(AppConfig.defaults().modelPinned)
    }

    func testYAMLPinKeepsASignedModel() throws {
        let config = try load(yaml: """
        model_catalog_key: thinkingmachines/inkling-2-mini
        model_catalog_model_id: mlx-community/Inkling-2-Mini-oQ4e-mtp
        model_pinned: true

        """)
        XCTAssertTrue(config.modelPinned)
        XCTAssertEqual(AutotuneModelUpgrade.pinReason(config: config), "model_pinned")
        XCTAssertFalse(try load(yaml: "model_pinned: false\n").modelPinned)
    }

    func testRejectsNonBooleanValues() {
        for yaml in ["model_pinned: maybe\n", "model_pinned: 2\n", "model_pinned: [true]\n"] {
            XCTAssertThrowsError(try load(yaml: yaml), yaml) { error in
                XCTAssertTrue(String(describing: error).contains("model_pinned"), String(describing: error))
            }
        }
    }
}
