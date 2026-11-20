import Foundation
import MLXLLM
import MLXLMCommon
@testable import macprovider_cli
import XCTest

/// #2415: Llama 3.x and dense Qwen3 prefill serial prompts in 2048-token
/// chunks; every other family, an operator-set `prefill_step_size`, images
/// and small-memory Macs keep the configured step.
final class SerialFamilyPrefillStepTests: XCTestCase {
    private let largeMac: UInt64 = 64 * 1_073_741_824
    private let mac24GiB: UInt64 = 24 * 1_073_741_824
    private let mac16GiB: UInt64 = 16 * 1_073_741_824

    private static func configurationData(vocab: Int, extra: String = "") -> Data {
        Data("""
            {
              "hidden_size": 16,
              "num_hidden_layers": 1,
              "intermediate_size": 32,
              "num_attention_heads": 2,
              "num_key_value_heads": 1,
              "head_dim": 8,
              "rms_norm_eps": 1e-6,
              "vocab_size": \(vocab),
              "rope_theta": 10000.0,
              "max_position_embeddings": 4096,
              "tie_word_embeddings": true\(extra)
            }
            """.utf8)
    }

    private static func llama(vocab: Int) throws -> LlamaModel {
        LlamaModel(try JSONDecoder().decode(LlamaConfiguration.self, from: configurationData(vocab: vocab)))
    }

    private static func qwen3() throws -> Qwen3Model {
        Qwen3Model(try JSONDecoder().decode(Qwen3Configuration.self, from: configurationData(vocab: 151_936)))
    }

    func testFamilyResolution() throws {
        XCTAssertEqual(ModelRuntime.serialPrefillFamily(model: try Self.llama(vocab: 128_256)), .llama3)
        XCTAssertEqual(ModelRuntime.serialPrefillFamily(model: try Self.qwen3()), .qwen3Dense)
        // Llama 2 (32000) and Mistral (32768 / 131072) share LlamaModel and keep the global step.
        for vocab in [32_000, 32_768, 131_072] {
            XCTAssertNil(ModelRuntime.serialPrefillFamily(model: try Self.llama(vocab: vocab)), "vocab \(vocab)")
            XCTAssertNil(ModelRuntime.serialFamilyPrefillStep(model: try Self.llama(vocab: vocab)), "vocab \(vocab)")
        }
    }

    func testModelWidthReadFromFinalNorm() throws {
        XCTAssertEqual(ModelRuntime.finalNormWidth(model: try Self.llama(vocab: 128_256)), 16)
        XCTAssertEqual(ModelRuntime.finalNormWidth(model: try Self.qwen3()), 16)
        XCTAssertEqual(ModelRuntime.serialFamilyPrefillStep(model: try Self.llama(vocab: 128_256)), 2048)
        XCTAssertEqual(ModelRuntime.serialFamilyPrefillStep(model: try Self.qwen3()), 2048)
    }

    func testOnlyMeasuredSizesTakeFamilyStep() {
        // Llama 3.2 1B/3B (2048/3072), Llama 3.1 8B and Qwen3-8B (4096) take 2048.
        for hidden in [1024, 2048, 3072, 4096] {
            XCTAssertEqual(ModelRuntime.serialFamilyPrefillStep(family: .llama3, hiddenSize: hidden), 2048, "\(hidden)")
            XCTAssertEqual(ModelRuntime.serialFamilyPrefillStep(family: .qwen3Dense, hiddenSize: hidden), 2048, "\(hidden)")
        }
        // Qwen3-14B/32B and 27B class (5120+), Llama 3 70B (8192): unmeasured, keep the global step.
        for hidden in [5120, 8192] {
            XCTAssertNil(ModelRuntime.serialFamilyPrefillStep(family: .llama3, hiddenSize: hidden), "\(hidden)")
            XCTAssertNil(ModelRuntime.serialFamilyPrefillStep(family: .qwen3Dense, hiddenSize: hidden), "\(hidden)")
        }
        XCTAssertNil(ModelRuntime.serialFamilyPrefillStep(family: .qwen3Dense, hiddenSize: nil))
        XCTAssertNil(ModelRuntime.serialFamilyPrefillStep(family: nil, hiddenSize: 4096))
    }

    func testFamilyStepAppliesByDefaultOnLargeMacs() {
        XCTAssertEqual(ModelRuntime.serialPrefillStepSize(
            configured: 512, explicitlyConfigured: false, containsImage: false,
            familyStep: 2048, physicalMemoryBytes: largeMac), 2048)
    }

    func testOtherFamiliesKeepConfiguredStep() {
        XCTAssertEqual(ModelRuntime.serialPrefillStepSize(
            configured: 512, explicitlyConfigured: false, containsImage: false,
            familyStep: nil, physicalMemoryBytes: largeMac), 512)
    }

    func testExplicitOperatorStepWins() {
        for step in [256, 512, 1024, 4096] {
            XCTAssertEqual(ModelRuntime.serialPrefillStepSize(
                configured: step, explicitlyConfigured: true, containsImage: false,
                familyStep: 2048, physicalMemoryBytes: largeMac), step)
        }
    }

    func testSmallMemoryMacsKeepConfiguredStep() {
        for memory in [mac16GiB, mac24GiB] {
            XCTAssertEqual(ModelRuntime.serialPrefillStepSize(
                configured: 512, explicitlyConfigured: false, containsImage: false,
                familyStep: 2048, physicalMemoryBytes: memory), 512)
        }
        XCTAssertEqual(ModelRuntime.serialPrefillStepSize(
            configured: 512, explicitlyConfigured: false, containsImage: false,
            familyStep: 2048, physicalMemoryBytes: 32 * 1_073_741_824), 2048)
    }

    func testImagesKeepVisionStep() {
        XCTAssertEqual(ModelRuntime.serialPrefillStepSize(
            configured: 1024, explicitlyConfigured: false, containsImage: true,
            familyStep: 2048, physicalMemoryBytes: largeMac),
            ModelRuntime.effectivePrefillStepSize(configured: 1024, containsImage: true))
    }
}
