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

    func testCatalogEconomicsWireUsesSchemaAndActionNulls() throws {
        let unavailable = ModelCatalogEconomicsWire.Action(
            available: false,
            requiresConfirmation: false,
            transactionKind: nil,
            transactionID: nil,
            actionTimeoutSeconds: nil,
            estimatedBytes: nil,
            unavailableReason: "static_fallback_not_trusted"
        )
        let wire = ModelCatalogEconomicsWire(
            generatedAt: "2026-08-22T00:00:01.000Z",
            projectionSequence: 1,
            source: ModelCatalogEconomicsWire.Source(
                cliVersion: "1.8.104",
                cliBuildCommit: "unknown",
                processLaunchID: "11111111-2222-4333-8444-555555555555",
                processStartedAt: "2026-08-22T00:00:00.000Z",
                projectionProtocolVersion: "spec-044-cli-v1",
                rateCardSource: "static_signed",
                rateCardDigest: "digest",
                rateCardSignatureDigest: nil,
                demandFeedDigest: "demand",
                candidateFeedDigest: "candidate",
                rateCardMaxAgeSeconds: 604_800
            ),
            warnings: ["feed_fallback"],
            rows: [ModelCatalogEconomicsWire.Row(
                modelKey: "qwen3-8b",
                servedModelID: "qwen3-8b",
                displayModelID: "mlx-community/Qwen3-8B-4bit",
                actionModelID: nil,
                isCurrent: false,
                weightsPresentLocally: false,
                runtimeState: "needs_preparation",
                estimatedGB: 4.0,
                fit: "fits",
                disabledReason: "weights_not_prepared",
                warningCodes: ["feed_fallback"],
                rateCardVersion: "rate",
                rateCardGeneratedAt: "2026-08-22T00:00:00.000Z",
                rateCardKey: "qwen3-8b",
                rateSource: "static_signed",
                promptRateUSDPerMillionTokens: 0.0135,
                completionRateUSDPerMillionTokens: 0.027,
                providerShareBPS: 9_000,
                providerPromptPayoutUSDPerMillionTokens: 0.01215,
                providerCompletionPayoutUSDPerMillionTokens: 0.0243,
                economicsState: "fallback",
                demandRank: 18,
                demandWeight: 0.38,
                readyProviderCount: nil,
                supplyDeficitScore: 1.0,
                actions: ModelCatalogEconomicsWire.ActionSet(
                    switchAction: unavailable,
                    prepare: unavailable,
                    evaluate: unavailable,
                    adoptRecommendation: unavailable,
                    cleanupStaging: unavailable
                )
            )]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(wire).utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schema"] as? String, "model_catalog_economics.v1")
        XCTAssertEqual(object["generated_at"] as? String, "2026-08-22T00:00:01.000Z")
        XCTAssertEqual(object["projection_sequence"] as? Int, 1)
        XCTAssertEqual(object["warnings"] as? [String], ["feed_fallback"])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        let first = try XCTUnwrap(rows.first)
        XCTAssertTrue(first.keys.contains("action_model_id"))
        let actions = try XCTUnwrap(first["actions"] as? [String: Any])
        let switchAction = try XCTUnwrap(actions["switch"] as? [String: Any])
        XCTAssertEqual(switchAction["available"] as? Bool, false)
        XCTAssertTrue(switchAction.keys.contains("transaction_kind"))
        XCTAssertTrue(switchAction.keys.contains("transaction_id"))
        XCTAssertTrue(switchAction.keys.contains("action_timeout_seconds"))
        XCTAssertTrue(switchAction.keys.contains("estimated_bytes"))
    }

    func testRecommendationCheckAndAdoptionFramesUseExpectedSchemas() throws {
        let check = ModelRecommendationCheckEventWire(
            type: "accepted",
            checkID: "check-1",
            candidateModelID: "hf/model",
            isolatedCacheRoot: "redacted",
            stagingOwner: "cli",
            phase: nil,
            elapsedMS: 0,
            cancellable: false,
            downloadBytesWritten: nil,
            downloadBytesTotal: nil,
            reason: nil,
            stagingDiscarded: nil,
            installedOnly: true
        )
        let checkObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(check).utf8)) as? [String: Any]
        )
        XCTAssertEqual(checkObject["schema_version"] as? String, "model_recommendation_check_event.v1")
        XCTAssertEqual(checkObject["check_id"] as? String, "check-1")
        XCTAssertEqual(checkObject["installed_only"] as? Bool, true)
        XCTAssertEqual(checkObject["cancellable"] as? Bool, false)

        let completed = ModelRecommendationCheckEventWire(
            type: "completed",
            checkID: "check-1",
            candidateModelID: "hf/model",
            isolatedCacheRoot: nil,
            stagingOwner: nil,
            phase: "completed",
            elapsedMS: 2,
            cancellable: false,
            downloadBytesWritten: nil,
            downloadBytesTotal: nil,
            reason: nil,
            stagingDiscarded: true,
            installedOnly: true
        )
        let completedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(completed).utf8)) as? [String: Any]
        )
        XCTAssertEqual(completedObject["schema_version"] as? String, "model_recommendation_check_event.v1")
        XCTAssertEqual(completedObject["type"] as? String, "completed")
        XCTAssertEqual(completedObject["phase"] as? String, "completed")
        XCTAssertEqual(completedObject["staging_discarded"] as? Bool, true)

        let adoption = ModelAdoptionEventWire(
            type: "failed",
            transactionID: "tx-1",
            targetModelID: "hf/model",
            fromModelID: "hf/current",
            phase: "switch_loading",
            elapsedMS: 1,
            cancellable: false,
            downloadBytesWritten: nil,
            downloadBytesTotal: nil,
            reason: "switch_failed",
            rollbackState: "rolled_back",
            incumbentModelID: "hf/current",
            configSHA256: nil,
            backupPath: nil
        )
        let adoptionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try ModelSwitchingWireCodec.encode(adoption).utf8)) as? [String: Any]
        )
        XCTAssertEqual(adoptionObject["schema_version"] as? String, "model_adoption_event.v1")
        XCTAssertEqual(adoptionObject["transaction_id"] as? String, "tx-1")
        XCTAssertEqual(adoptionObject["rollback_state"] as? String, "rolled_back")
    }
}
