import MacProviderCore
import XCTest

final class ModelFitTests: XCTestCase {

    // MARK: - estimateWeightSizeGB

    func testEstimateLlama3B4bit() {
        // 3B * 0.5 = 1.5 → rounds to 2
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit"), 2)
    }

    func testEstimateQwen7B4bit() {
        // 7B * 0.5 = 3.5 → rounds to 4
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"), 4)
    }

    func testEstimateQwen14B4bit() {
        // 14B * 0.5 = 7
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "mlx-community/Qwen2.5-14B-Instruct-4bit"), 7)
    }

    func testEstimateSmolLM17B4bitClampsToOne() {
        // 1.7B * 0.5 = 0.85, clamped to 1
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "mlx-community/SmolLM2-1.7B-Instruct-4bit"), 1)
    }

    func testEstimate32B8bit() {
        // 32B * 1.0 = 32
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "mlx-community/Qwen2.5-32B-Instruct-8bit"), 32)
    }

    func testEstimate7BBF16() {
        // 7B * 2.0 = 14
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "mlx-community/Mistral-7B-Instruct-bf16"), 14)
    }

    func testEstimate70B4bit() {
        // 70B * 0.5 = 35
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "mlx-community/Llama-3.3-70B-Instruct-4bit"), 35)
    }

    func testEstimateSkipsVersionDecimalBeforeNonB() {
        // "Qwen2.5" should not be parsed as 2.5B because next char is "-",
        // not B. Parser should skip past it to find "7B".
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "Qwen2.5-7B-Instruct"), 14)
    }

    func testEstimateUnknownNameReturnsNil() {
        XCTAssertNil(ModelFit.estimateWeightSizeGB(modelID: "some-org/some-random-model"))
        XCTAssertNil(ModelFit.estimateWeightSizeGB(modelID: ""))
    }

    func testEstimateAssumesFP16WhenQuantUnknown() {
        // No 4bit/8bit/bf16/fp16 in the name → 2.0 bytes/param.
        // 7B * 2.0 = 14
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "Mistral-7B-Instruct-v0.3"), 14)
    }

    func testEstimateRecognizesQ4SuffixVariants() {
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "user/Qwen-7B-q4"), 4)
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "user/Qwen-7B_q4_k_m"), 4)
    }

    // Round-2 (codex code MAJOR): Mixture-of-Experts shape must be parsed as
    // experts × per-expert, not just the trailing "MB" half. A regression
    // here means the switch fit guard accepts models that OOM the host.

    func testEstimateMixtral8x7B4bit() {
        // 8 × 7B = 56B params * 0.5 byte = 28 GB
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "mlx-community/Mixtral-8x7B-Instruct-v0.1-4bit"), 28)
    }

    func testEstimateMixtral8x22B4bit() {
        // 8 × 22B = 176B params * 0.5 = 88 GB
        XCTAssertEqual(ModelFit.estimateWeightSizeGB(modelID: "mlx-community/Mixtral-8x22B-Instruct-v0.1-4bit"), 88)
    }

    func testEstimateMoEBeatsSingleNFallback() throws {
        // The presence of "x7B" inside "8x7B" must not be captured as a
        // standalone 7B; check by comparing against the single-N case.
        let moe = try XCTUnwrap(ModelFit.estimateWeightSizeGB(modelID: "Mixtral-8x7B-4bit"))
        let single = try XCTUnwrap(ModelFit.estimateWeightSizeGB(modelID: "Qwen-7B-4bit"))
        XCTAssertGreaterThan(moe, single)
    }

    // MARK: - evaluate (verdict tiers)

    func testEvaluateFitsWhenComfortable() {
        // 7B 4bit (4 GB) on 16 GB Mac: 16 >= 4 + 6 → fits
        XCTAssertEqual(
            ModelFit.evaluate(modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit", ramGB: 16),
            .fits(estGB: 4, ramGB: 16)
        )
    }

    func testEvaluateTightAtBoundary() {
        // 7B 4bit (4 GB) on 8 GB Mac: 8 < 4 + 6 but 8 >= 4 + 2 → tight
        XCTAssertEqual(
            ModelFit.evaluate(modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit", ramGB: 8),
            .tight(estGB: 4, ramGB: 8)
        )
    }

    func testEvaluateWontFitOnUndersizedMac() {
        // 70B 4bit (35 GB) on 8 GB Mac: 8 < 35 + 2 → wontFit
        XCTAssertEqual(
            ModelFit.evaluate(modelID: "mlx-community/Llama-3.3-70B-Instruct-4bit", ramGB: 8),
            .wontFit(estGB: 35, ramGB: 8)
        )
    }

    func testEvaluateLlama3BFitsOnEightGB() {
        // 3B 4bit (2 GB) on 8 GB Mac: 8 >= 2 + 6 → fits (the default install pick)
        XCTAssertEqual(
            ModelFit.evaluate(modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit", ramGB: 8),
            .fits(estGB: 2, ramGB: 8)
        )
    }

    func testEvaluateUnknownPropagates() {
        if case .unknown = ModelFit.evaluate(modelID: "some-org/random", ramGB: 16) {
            // expected
        } else {
            XCTFail("expected .unknown for unparseable name")
        }
    }

    // MARK: - detectRAMGB (smoke: returns positive)

    func testDetectRAMGBIsPositive() {
        XCTAssertGreaterThan(ModelFit.detectRAMGB(), 0)
    }

    // MARK: - Headroom constants match the SPEC-003 v0.9 FR-D2.1 contract

    func testHeadroomConstantsMatchInstaller() {
        XCTAssertEqual(ModelFit.comfortableHeadroomGB, 6)
        XCTAssertEqual(ModelFit.tightHeadroomGB, 2)
    }
}
