import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class LocalResponsesCapabilitiesTests: XCTestCase {
    func testNativeCapabilitiesMatchToolAdmissionPolicy() {
        for model in [ToolSelectionPolicy.supportedNativeModel, "other-native-model"] {
            let value = LocalResponsesCapabilities.loaded(model: model, modelHash: "hash", generation: 9, runtime: "mlx_cache")
            XCTAssertTrue(value.available)
            XCTAssertEqual(value.toolChoiceModes, ToolSelectionPolicy.modes(modelID: model, runtime: "mlx_cache"))
            XCTAssertEqual(value.toolChoiceModes.contains("required"), model == ToolSelectionPolicy.supportedNativeModel)
            XCTAssertEqual(value.textFormats, ["text", "json_object", "json_schema"])
            XCTAssertEqual(value.structuredOutputEnforcement, "json_object_and_strict_json_schema_validated")
            XCTAssertTrue(value.upstreamTextFormats.isEmpty)
            XCTAssertEqual(value.modelHash, "hash")
            XCTAssertEqual(value.generation, 9)
        }
    }

    /// #2014: an alias-served model reports the modes of its catalog identity.
    func testAliasServedCatalogIdentityReportsGuaranteedModes() {
        let alias = LocalResponsesCapabilities.loaded(
            model: "qwen/qwen3.6-35b-a3b", modelHash: "hash", generation: 1, runtime: "mlx_cache",
            toolSelectionModelID: ToolSelectionPolicy.supportedNativeModel)
        XCTAssertEqual(alias.model, "qwen/qwen3.6-35b-a3b")
        XCTAssertEqual(alias.toolChoiceModes, ["auto", "none", "required", "named"])
        let other = LocalResponsesCapabilities.loaded(
            model: "local/other", modelHash: "hash", generation: 1, runtime: "mlx_cache",
            toolSelectionModelID: "mlx-community/Other-4bit")
        XCTAssertEqual(other.toolChoiceModes, ["auto", "none"])
    }

    func testExternalRuntimeDistinguishesForwardedFormatsFromLocalGuarantees() {
        for runtime in ["llamacpp_loopback", "ollama_loopback", "mlxlm_loopback", "lmstudio_loopback"] {
            let value = LocalResponsesCapabilities.loaded(model: ToolSelectionPolicy.supportedNativeModel,
                                                         modelHash: "hash", generation: nil, runtime: runtime)
            XCTAssertTrue(value.available)
            XCTAssertEqual(value.toolChoiceModes, ["auto"])
            XCTAssertEqual(value.textFormats, ["text"])
            XCTAssertEqual(value.upstreamTextFormats, ["json_object", "json_schema"])
            XCTAssertEqual(value.structuredOutputEnforcement, "upstream_dependent")
            XCTAssertNil(value.generation)
        }
    }

    func testUnavailableDoesNotAdvertiseOperationsOrStaleIdentity() throws {
        let value = LocalResponsesCapabilities.unavailable
        XCTAssertFalse(value.available)
        XCTAssertNil(value.model)
        XCTAssertNil(value.modelHash)
        XCTAssertNil(value.generation)
        XCTAssertTrue(value.toolChoiceModes.isEmpty)
        XCTAssertTrue(value.textFormats.isEmpty)
        XCTAssertTrue(value.upstreamTextFormats.isEmpty)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertEqual(json["available"] as? Bool, false)
        XCTAssertNotNil(json["tool_choice_modes"])
        XCTAssertNotNil(json["text_formats"])
    }
}
