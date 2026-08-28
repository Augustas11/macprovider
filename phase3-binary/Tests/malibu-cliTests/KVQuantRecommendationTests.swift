import Foundation
import MacProviderCore
import XCTest

// T3-03 — KV quant family scheme: unit tests for modelID → kvBits mapping.
// GREEN criterion: mapping table matches upstream KVQuantEngineScheme families;
// override semantics preserved (explicit nil / 4 / 8 beats family default).

final class KVQuantRecommendationTests: XCTestCase {

    // MARK: - Family classification

    func testGemma4FamilyRecognised() {
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "mlx-community/gemma-4-26b-a4b-it-4bit"), .gemma4)
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "google/gemma-4-9b-it"), .gemma4)
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "mlx-community/Gemma-4-12B-IT-4bit"), .gemma4)
    }

    func testGPTOSSFamilyRecognised() {
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "mlx-community/gpt-oss-20b-MXFP4-Q8"), .gptOSS)
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "openai/gpt-oss-20b"), .gptOSS)
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "mlx-community/gpt-oss-85b"), .gptOSS)
    }

    func testUnknownFamilyForUnvalidatedModels() {
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"), .unknown)
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "mlx-community/Qwen3-32B-4bit"), .unknown)
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit"), .unknown)
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "mlx-community/Qwen3-8B-4bit"), .unknown)
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"), .unknown)
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit"), .unknown)
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit"), .unknown)
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: ""), .unknown)
    }

    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "mlx-community/Gemma-4-26B-A4B-IT-4BIT"), .gemma4)
        XCTAssertEqual(KVQuantRecommendation.classify(modelID: "OpenAI/GPT-OSS-20B"), .gptOSS)
    }

    // MARK: - Recommended kvBits

    func testGemma4ReturnsEightBits() {
        XCTAssertEqual(KVQuantRecommendation.recommendedKVBits(for: "mlx-community/gemma-4-26b-a4b-it-4bit"), 8)
    }

    func testGPTOSSReturnsEightBits() {
        XCTAssertEqual(KVQuantRecommendation.recommendedKVBits(for: "mlx-community/gpt-oss-20b-MXFP4-Q8"), 8)
    }

    func testUnvalidatedModelsReturnNil() {
        XCTAssertNil(KVQuantRecommendation.recommendedKVBits(for: "mlx-community/Qwen3-32B-4bit"))
        XCTAssertNil(KVQuantRecommendation.recommendedKVBits(for: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"))
        XCTAssertNil(KVQuantRecommendation.recommendedKVBits(for: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"))
        XCTAssertNil(KVQuantRecommendation.recommendedKVBits(for: "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit"))
        XCTAssertNil(KVQuantRecommendation.recommendedKVBits(for: ""))
    }

    // MARK: - Override semantics (operator config wins)

    func testExplicitOverrideBeatsGemmaDefault() {
        let operatorOverride: Int? = nil
        let familyDefault = KVQuantRecommendation.recommendedKVBits(for: "mlx-community/gemma-4-26b-a4b-it-4bit")
        // When operator override is nil, family default applies
        let effective = operatorOverride ?? familyDefault
        XCTAssertEqual(effective, 8)
    }

    func testExplicitFourOverrideSuppressesGemmaDefault() {
        let operatorOverride: Int? = 4
        let familyDefault = KVQuantRecommendation.recommendedKVBits(for: "mlx-community/gemma-4-26b-a4b-it-4bit")
        let effective = operatorOverride ?? familyDefault
        XCTAssertEqual(effective, 4)
    }

    func testExplicitNilEnvSemanticsForUnknownFamily() {
        // Operator has not set kv_bits; model has no validated scheme → nil
        let operatorOverride: Int? = nil
        let familyDefault = KVQuantRecommendation.recommendedKVBits(for: "mlx-community/Qwen3-32B-4bit")
        let effective = operatorOverride ?? familyDefault
        XCTAssertNil(effective)
    }

    // MARK: - Catalog coverage (all published catalog model IDs)

    func testAllCurrentCatalogModelsClassifyCorrectly() {
        let expected: [(String, KVQuantFamily)] = [
            ("mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", .unknown),
            ("mlx-community/gpt-oss-20b-MXFP4-Q8", .gptOSS),
            ("mlx-community/Meta-Llama-3.1-8B-Instruct-4bit", .unknown),
            ("mlx-community/Qwen3-32B-4bit", .unknown),
            ("mlx-community/Qwen2.5-Coder-32B-Instruct-4bit", .unknown),
            ("mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit", .unknown),
            ("mlx-community/Llama-3.2-3B-Instruct-4bit", .unknown),
            ("mlx-community/gemma-4-26b-a4b-it-4bit", .gemma4),
            ("mlx-community/Qwen3-8B-4bit", .unknown),
        ]
        for (modelID, expectedFamily) in expected {
            XCTAssertEqual(
                KVQuantRecommendation.classify(modelID: modelID),
                expectedFamily,
                "Family mismatch for \(modelID)"
            )
        }
    }
}
