import Foundation
import XCTest
@testable import macprovider_cli

/// #2111: promoting deepseek/deepseek-v4-flash to recommendable must not move a
/// 256 GB Mac serving zai-org/glm-5.3-flash (the Studio) off GLM in a fresh
/// `autotune --recommend`. DeepSeek serves serially (one slot, no continuous
/// batching), so the signed demand rank curates it at the cold-start floor
/// (0.15) against GLM's 0.25. The score is payout x tps x demand x shortage,
/// so DeepSeek ranks first only when its single-stream tps exceeds GLM's by
/// (87525 x 0.25) / (137250 x 0.15) = 1.063x.
final class AutotuneRecommendDeepSeekNoChurnTests: XCTestCase {
    private static let glm = "zai-org/glm-5.3-flash"
    private static let deepseek = "deepseek/deepseek-v4-flash"

    /// Measured single-stream decode on the Studio (catalog bench_gate notes):
    /// GLM-5.3-Flash ~42.7 tok/s, DeepSeek-V4-Flash 31-36 tok/s at one row.
    func testGLMStaysFirstOn256GBWithMeasuredThroughput() async throws {
        let result = try await recommend(memoryGB: 256, tps: [Self.glm: 42.7, Self.deepseek: 36.0])
        XCTAssertEqual(result.selectedCandidate?.catalogKey, Self.glm)
        let deepseek = try XCTUnwrap(result.allCandidates.first { $0.catalogKey == Self.deepseek })
        XCTAssertTrue(deepseek.eligible, "DeepSeek is recommendable and fits 256 GB; it ranks below GLM")
        XCTAssertEqual(deepseek.rank, 2)
    }

    /// `--check-only --installed-only` (the Malibu background check and the
    /// window's adoption path) scores every installed row at its catalog
    /// min_sustained_tps, 10 for both: GLM still ranks first.
    func testGLMStaysFirstOn256GBInInstalledOnlyScoring() async throws {
        let result = try await recommend(memoryGB: 256, tps: [Self.glm: 10, Self.deepseek: 10])
        XCTAssertEqual(result.selectedCandidate?.catalogKey, Self.glm)
    }

    /// A 512 GB Mac scores the same rows the same way: GLM first, DeepSeek
    /// second and eligible.
    func testGLMStaysFirstOn512GB() async throws {
        let result = try await recommend(memoryGB: 512, tps: [Self.glm: 42.7, Self.deepseek: 36.0])
        XCTAssertEqual(result.selectedCandidate?.catalogKey, Self.glm)
        XCTAssertEqual(result.allCandidates.first { $0.catalogKey == Self.deepseek }?.rank, 2)
    }

    /// The boundary is the measured throughput ratio: a Mac where DeepSeek
    /// decodes more than 1.063x faster than GLM ranks DeepSeek first.
    func testDeepSeekRanksFirstOnlyAboveTheThroughputRatio() async throws {
        let below = try await recommend(memoryGB: 512, tps: [Self.glm: 40.0, Self.deepseek: 42.4])
        XCTAssertEqual(below.selectedCandidate?.catalogKey, Self.glm)
        let above = try await recommend(memoryGB: 512, tps: [Self.glm: 40.0, Self.deepseek: 42.6])
        XCTAssertEqual(above.selectedCandidate?.catalogKey, Self.deepseek)
    }

    /// The signed release carries the inputs these tests rely on.
    func testBakedReleasePromotesDeepSeekAtTheColdStartFloor() throws {
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        XCTAssertEqual(catalog.rows[Self.deepseek]?.runtimeStatus, "recommendable")
        XCTAssertEqual(catalog.rows[Self.glm]?.runtimeStatus, "recommendable")
        let demand = try JSONDecoder().decode(DemandRank.self, from: Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8))
        XCTAssertEqual(demand.rows[Self.deepseek]?.recommendable, true)
        XCTAssertEqual(demand.rows[Self.deepseek]?.demandWeight, 0.15)
        XCTAssertEqual(demand.rows[Self.glm]?.demandWeight, 0.25)
    }

    private func recommend(memoryGB: Int, tps: [String: Double]) async throws -> AutotuneRecommendResult {
        let catalogBytes = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(catalogBytes)
        let catalogSHA = AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalogBytes)
        var benchmarks: [String] = []
        for (key, value) in tps.sorted(by: { $0.key < $1.key }) {
            let row = try XCTUnwrap(catalog.rows[key])
            benchmarks.append("""
            "\(key)": {
              "sustained_tps": \(value),
              "ttft_ms": 3000,
              "swap_detected": false,
              "thermal_throttle_detected": false,
              "artifact_sha256": "\(try XCTUnwrap(row.modelSHA256))",
              "model_artifact_path": "/tmp/\(key)",
              "benchmark_id": "bench-\(key)",
              "generated_at": "2026-10-23T20:30:00Z",
              "candidate_catalog_sha256": "\(catalogSHA)",
              "binary_version": "test-bin",
              "model_id": "\(row.modelID)",
              "hardware_identity_hash": "sim-hw"
            }
            """)
        }
        let envelope = """
        {
          "hardware": {
            "machine": "Mac15,14",
            "chip": "Apple M3 Ultra",
            "memoryGB": \(memoryGB),
            "bandwidthTier": "S",
            "osVersion": "26.0",
            "binaryVersion": "test-bin",
            "diversificationID": "sim-div",
            "hardwareIdentityHash": "sim-hw"
          },
          "rateCard": \(AutotuneStaticInputs.bakedRateCardJSON),
          "candidateCatalog": "@LIVE",
          "candidateCatalogSHA256": "\(catalogSHA)",
          "demandRank": \(AutotuneStaticInputs.bakedDemandRankJSON),
          "benchmarks": {\(benchmarks.joined(separator: ","))},
          "warnings": [],
          "generatedAt": "2026-10-23T21:00:00Z",
          "donorMode": false
        }
        """
        let simulator = AutotuneRecommendSimulator(
            fetchRateCard: { _ in throw URLError(.badURL) },
            bakedCandidateCatalogBytes: { catalogBytes },
            bakedDemandRankBytes: { Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8) }
        )
        return try await simulator.recommend(envelopeData: Data(envelope.utf8))
    }
}
