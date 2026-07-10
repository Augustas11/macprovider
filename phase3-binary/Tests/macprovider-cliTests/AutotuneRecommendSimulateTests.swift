import Foundation
import XCTest
@testable import macprovider_cli

final class AutotuneRecommendSimulateTests: XCTestCase {
    func testEnvelopeDecodeRoundTripBuildsEngineRequest() async throws {
        let envelopeData = try makeEnvelopeData()

        let envelope = try JSONDecoder().decode(AutotuneRecommendSimulateEnvelope.self, from: envelopeData)
        let request = try await envelope.request(
            fetchRateCard: { _ in throw URLError(.badURL) },
            bakedCandidateCatalogBytes: { Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8) },
            bakedDemandRankBytes: { Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8) }
        )

        XCTAssertEqual(request.hardware.chip, "Apple M4")
        XCTAssertEqual(request.hardware.memoryGB, 32)
        XCTAssertEqual(request.hardware.bandwidthTier, .c)
        XCTAssertEqual(request.donorMode, false)
        XCTAssertEqual(request.benchmarks["qwen3-coder-30b-a3b-instruct"]?.modelKey, "qwen3-coder-30b-a3b-instruct")
        XCTAssertEqual(request.rateCard.version, "baked-2026-07-07-p2-drift")
        XCTAssertEqual(request.candidateCatalog.version, "published-2026-07-10-llama32-hash-repair")
        XCTAssertEqual(request.demandRank.version, "published-2026-07-07-p2-qwen3-8b")
    }

    func testSimulateRecommendationMatchesDirectEngineCall() async throws {
        let envelopeData = try makeEnvelopeData()
        let simulator = AutotuneRecommendSimulator(
            fetchRateCard: { _ in throw URLError(.badURL) },
            bakedCandidateCatalogBytes: { Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8) },
            bakedDemandRankBytes: { Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8) }
        )
        let simulated = try await simulator.recommend(envelopeData: envelopeData)

        let envelope = try JSONDecoder().decode(AutotuneRecommendSimulateEnvelope.self, from: envelopeData)
        let request = try await envelope.request(
            fetchRateCard: { _ in throw URLError(.badURL) },
            bakedCandidateCatalogBytes: { Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8) },
            bakedDemandRankBytes: { Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8) }
        )
        let direct = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(simulated, direct)
        XCTAssertEqual(simulated.jsonString(), direct.jsonString())
    }

    func testLiveSentinelFetchesRateCardAndUsesBakedStaticInputs() async throws {
        let envelopeData = try makeEnvelopeData(rateCard: #""@LIVE""#, candidateCatalog: #""@LIVE""#, demandRank: #""@LIVE""#)
        var fetchedURL: URL?
        let simulator = AutotuneRecommendSimulator(
            fetchRateCard: { url in
                fetchedURL = url
                return Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)
            },
            bakedCandidateCatalogBytes: { Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8) },
            bakedDemandRankBytes: { Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8) }
        )

        let result = try await simulator.recommend(envelopeData: envelopeData)

        XCTAssertEqual(fetchedURL, AutotuneRecommendSimulator.liveRateCardURL)
        XCTAssertEqual(result.rateCardVersion, "baked-2026-07-07-p2-drift")
        XCTAssertEqual(result.candidateCatalogVersion, "published-2026-07-10-llama32-hash-repair")
        XCTAssertEqual(result.demandRankVersion, "published-2026-07-07-p2-qwen3-8b")
    }

    func testSimulatorJSONIncludesFullCandidateUniverse() async throws {
        let envelopeData = try makeEnvelopeData()
        let simulator = AutotuneRecommendSimulator(
            fetchRateCard: { _ in throw URLError(.badURL) },
            bakedCandidateCatalogBytes: { Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8) },
            bakedDemandRankBytes: { Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8) }
        )

        let result = try await simulator.recommend(envelopeData: envelopeData)
        let publicJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.jsonString().utf8)) as? [String: Any])
        let simulatorJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.simulatorJSON().utf8)) as? [String: Any])
        let publicCandidates = try XCTUnwrap(publicJSON["candidates"] as? [[String: Any]])
        let allCandidates = try XCTUnwrap(simulatorJSON["all_candidates"] as? [[String: Any]])

        XCTAssertNil(publicJSON["all_candidates"])
        XCTAssertGreaterThanOrEqual(allCandidates.count, publicCandidates.count)
        XCTAssertEqual(allCandidates.count, result.allCandidates.count)
    }

    private func makeEnvelopeData(
        rateCard: String = AutotuneStaticInputs.bakedRateCardJSON,
        candidateCatalog: String = AutotuneStaticInputs.bakedCandidateCatalogJSON,
        demandRank: String = AutotuneStaticInputs.bakedDemandRankJSON
    ) throws -> Data {
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        let row = try XCTUnwrap(catalog.rows[modelKey])
        let catalogSHA = AutotuneStaticInputs.candidateCatalogSHA256(bytes: Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        let json = """
        {
          "hardware": {
            "machine": "Mac-test",
            "chip": "Apple M4",
            "memoryGB": 32,
            "bandwidthTier": "C",
            "osVersion": "15.5",
            "binaryVersion": "test-bin",
            "diversificationID": "sim-div",
            "hardwareIdentityHash": "sim-hw"
          },
          "rateCard": \(rateCard),
          "candidateCatalog": \(candidateCatalog),
          "candidateCatalogSHA256": "\(catalogSHA)",
          "demandRank": \(demandRank),
          "benchmarks": {
            "\(modelKey)": {
              "sustained_tps": 25.0,
              "ttft_ms": 2500,
              "swap_detected": false,
              "thermal_throttle_detected": false,
              "artifact_sha256": "\(row.modelSHA256!)",
              "model_artifact_path": "/tmp/\(modelKey)",
              "benchmark_id": "bench-\(modelKey)",
              "generated_at": "2026-07-06T00:00:00Z",
              "candidate_catalog_sha256": "\(catalogSHA)",
              "binary_version": "test-bin",
              "model_id": "\(row.modelID)",
              "hardware_identity_hash": "sim-hw"
            }
          },
          "warnings": [],
          "generatedAt": "2026-07-06T00:00:00Z",
          "donorMode": false
        }
        """
        return Data(json.utf8)
    }
}
