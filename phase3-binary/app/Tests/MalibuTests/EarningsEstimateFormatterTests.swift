import XCTest
@testable import Malibu

final class EarningsEstimateFormatterTests: XCTestCase {
    func testFormatsChipModelAndDailyRange() {
        let line = EarningsEstimateFormatter.line(
            modelName: "Llama-3.1-8B-Q4",
            range: EarningsEstimateRange(lowDailyUSD: 4.12, highDailyUSD: 8.24),
            chipName: "your M3 Max"
        )
        XCTAssertEqual(
            line,
            "Llama-3.1-8B-Q4 on your M3 Max typically earns ~$4.12-$8.24/day at current demand."
        )
    }

    func testNilRangeHidesLine() {
        XCTAssertNil(EarningsEstimateFormatter.line(modelName: "Llama", range: nil, chipName: "your Mac"))
    }

    func testAutotuneJSONBuildsModelPlanAndDailyEstimate() throws {
        let data = Data("""
        {
          "schema_version": "autotune_recommend.v1",
          "inputs": {
            "availability_hours_per_day": 12
          },
          "recommended_model": "meta-llama/llama-3.1-8b-instruct",
          "candidates": [
            {
              "model": "meta-llama/llama-3.1-8b-instruct",
              "expected_net_usd_per_hour": 0.5
            }
          ]
        }
        """.utf8)

        let plan = try ModelDownloadPlan.fromAutotuneJSON(data)

        XCTAssertEqual(plan.modelName, "meta-llama/llama-3.1-8b-instruct")
        XCTAssertEqual(plan.earningsEstimate, EarningsEstimateRange(lowDailyUSD: 6, highDailyUSD: 6))
    }

    func testAutotuneJSONOmitsEstimateWhenRateCardFieldsAreUnavailable() throws {
        let data = Data("""
        {
          "schema_version": "autotune_recommend.v1",
          "recommended_model": "meta-llama/llama-3.1-8b-instruct",
          "candidates": []
        }
        """.utf8)

        let plan = try ModelDownloadPlan.fromAutotuneJSON(data)

        XCTAssertEqual(plan.modelName, "meta-llama/llama-3.1-8b-instruct")
        XCTAssertNil(plan.earningsEstimate)
    }

    func testAutotuneRecommendationResultParsesServeConfigPayload() throws {
        let data = Data("""
        {
          "schema_version": "autotune_recommend.v1",
          "inputs": {
            "availability_hours_per_day": 12
          },
          "recommended_model": "meta-llama/llama-3.1-8b-instruct",
          "serve_config": {
            "model": "meta-llama/llama-3.1-8b-instruct",
            "model_artifact_path": "/Users/test/snapshots/241a666dad6cb93c8ff213d39a7f34a36bf26db4",
            "model_artifact_sha256": "\(String(repeating: "a", count: 64))",
            "model_catalog_key": "meta-llama/llama-3.1-8b-instruct",
            "model_catalog_model_id": "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
            "model_catalog_revision": "241a666dad6cb93c8ff213d39a7f34a36bf26db4",
            "model_catalog_sha256": "\(String(repeating: "a", count: 64))",
            "model_catalog_version": "baked-2026-07-03",
            "model_catalog_hash": "\(String(repeating: "b", count: 64))",
            "kv_bits": null,
            "max_context_override": 4000,
            "max_concurrency_override": 1,
            "donor_mode": false
          },
          "candidates": [
            {
              "model": "meta-llama/llama-3.1-8b-instruct",
              "expected_net_usd_per_hour": 0.5
            }
          ]
        }
        """.utf8)

        let result = try AutotuneRecommendationResult.fromAutotuneJSON(data)

        XCTAssertEqual(result.plan.modelName, "meta-llama/llama-3.1-8b-instruct")
        XCTAssertEqual(result.plan.earningsEstimate, EarningsEstimateRange(lowDailyUSD: 6, highDailyUSD: 6))
        XCTAssertEqual(result.serveConfig.modelArtifactSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(result.serveConfig.maxContextOverride, 4000)
        XCTAssertFalse(result.serveConfig.donorMode)
    }

    func testAutotuneRecommendationResultRejectsMissingServeConfigPayload() {
        let data = Data("""
        {
          "schema_version": "autotune_recommend.v1",
          "recommended_model": "meta-llama/llama-3.1-8b-instruct",
          "candidates": []
        }
        """.utf8)

        XCTAssertThrowsError(try AutotuneRecommendationResult.fromAutotuneJSON(data))
    }

    func testAutotuneRecommendationResultRejectsBooleanNumericFields() {
        let data = Data("""
        {
          "schema_version": "autotune_recommend.v1",
          "recommended_model": "meta-llama/llama-3.1-8b-instruct",
          "serve_config": {
            "model": "meta-llama/llama-3.1-8b-instruct",
            "model_artifact_path": "/Users/test/snapshots/241a666dad6cb93c8ff213d39a7f34a36bf26db4",
            "model_artifact_sha256": "\(String(repeating: "a", count: 64))",
            "model_catalog_key": "meta-llama/llama-3.1-8b-instruct",
            "model_catalog_model_id": "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
            "model_catalog_revision": "241a666dad6cb93c8ff213d39a7f34a36bf26db4",
            "model_catalog_sha256": "\(String(repeating: "a", count: 64))",
            "model_catalog_version": "baked-2026-07-03",
            "model_catalog_hash": "\(String(repeating: "b", count: 64))",
            "kv_bits": null,
            "max_context_override": true,
            "max_concurrency_override": 1,
            "donor_mode": false
          },
          "candidates": []
        }
        """.utf8)

        XCTAssertThrowsError(try AutotuneRecommendationResult.fromAutotuneJSON(data))
    }
}
