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

        let plan = try LaunchProviderController.ModelDownloadPlan.fromAutotuneJSON(data)

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

        let plan = try LaunchProviderController.ModelDownloadPlan.fromAutotuneJSON(data)

        XCTAssertEqual(plan.modelName, "meta-llama/llama-3.1-8b-instruct")
        XCTAssertNil(plan.earningsEstimate)
    }
}
