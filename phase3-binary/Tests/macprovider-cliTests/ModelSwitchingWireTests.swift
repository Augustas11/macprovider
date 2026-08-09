import XCTest
@testable import macprovider_cli

final class ModelSwitchingWireTests: XCTestCase {
    func testActionIDsUseTheSupportedModelLengthAndControlCharacterBoundary() {
        XCTAssertTrue(ModelSwitchingWireCodec.safeID(String(repeating: "a", count: 256)))
        XCTAssertFalse(ModelSwitchingWireCodec.safeID(String(repeating: "a", count: 257)))
        XCTAssertFalse(ModelSwitchingWireCodec.safeID("model\nname"))
        XCTAssertFalse(ModelSwitchingWireCodec.safeID("model\u{009B}name"))
    }

    func testModelListWireUsesStableSnakeCaseSchema() throws {
        let wire = ModelsListWire(
            generatedAt: "2026-08-08T00:00:00.000Z",
            source: "control_socket",
            warmSwapAvailable: true,
            currentModelID: "old-model",
            rows: [ModelsListWire.Row(
                modelID: "old-model",
                displayID: "old-model",
                actionModelID: "old-model",
                state: "warm",
                weightsPresentLocally: true,
                source: "status_response",
                fit: "fits",
                estimatedGB: 4
            )]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(wire).utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schema_version"] as? String, "models_list.v1")
        XCTAssertEqual(object["warm_swap_available"] as? Bool, true)
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["weights_present_locally"] as? Bool, true)
        XCTAssertEqual(rows.first?["action_model_id"] as? String, "old-model")
    }

    func testNullableListFieldsArePresentAsNull() throws {
        let wire = ModelsListWire(
            generatedAt: "2026-08-08T00:00:00.000Z",
            source: "config_fallback",
            warmSwapAvailable: false,
            currentModelID: nil,
            rows: [ModelsListWire.Row(
                modelID: "org/model",
                displayID: "org/model",
                actionModelID: "org/model",
                state: "idle",
                weightsPresentLocally: false,
                source: "config_fallback",
                fit: nil,
                estimatedGB: nil
            )]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(wire).utf8)) as? [String: Any]
        )
        XCTAssertTrue(object.keys.contains("current_model_id"))
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertTrue(rows.first?.keys.contains("fit") == true)
        XCTAssertTrue(rows.first?.keys.contains("estimated_gb") == true)
    }

    func testBrowseContractAlwaysIncludesAdvisoryNulls() throws {
        let wire = ModelsBrowseWire(
            generatedAt: "2026-08-08T00:00:00.000Z",
            query: nil,
            limit: 30,
            fitsOnly: false,
            maxGB: nil,
            ramGB: 16,
            rows: [ModelsBrowseWire.Row(
                modelID: "mlx-community/model",
                displayID: "mlx-community/model",
                actionModelID: nil,
                source: "huggingface_mlx_community",
                fit: "unknown",
                estimatedGB: nil,
                actionable: false
            )]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(wire).utf8)) as? [String: Any]
        )
        XCTAssertTrue(object.keys.contains("query"))
        XCTAssertTrue(object.keys.contains("max_gb"))
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertTrue(rows.first?.keys.contains("action_model_id") == true)
        XCTAssertTrue(rows.first?.keys.contains("estimated_gb") == true)
    }
}
