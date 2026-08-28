import Foundation
import XCTest
@testable import malibu_cli

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
        XCTAssertEqual(request.buyerTTFTCeilingMS, 1_800)
        XCTAssertEqual(request.benchmarks["qwen3-coder-30b-a3b-instruct"]?.modelKey, "qwen3-coder-30b-a3b-instruct")
        XCTAssertEqual(request.rateCard.version, Self.bakedRateCardVersion)
        XCTAssertEqual(request.candidateCatalog.version, "published-2026-07-29-inband-provenance-v1")
        XCTAssertEqual(request.demandRank.version, "published-2026-07-29-inband-provenance-v1")
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
        XCTAssertEqual(result.rateCardVersion, Self.bakedRateCardVersion)
        XCTAssertEqual(result.candidateCatalogVersion, "published-2026-07-29-inband-provenance-v1")
        XCTAssertEqual(result.demandRankVersion, "published-2026-07-29-inband-provenance-v1")
    }

    private static var bakedRateCardVersion: String {
        (try? AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)).version) ?? ""
    }

    func testInlineExactCatalogCarriesInBandProvenance() async throws {
        let envelopeData = try makeEnvelopeData(candidateCatalog: AutotuneStaticInputs.bakedCandidateCatalogJSON)
        let simulator = AutotuneRecommendSimulator(
            fetchRateCard: { _ in throw URLError(.badURL) },
            bakedCandidateCatalogBytes: { Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8) },
            bakedDemandRankBytes: { Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8) }
        )
        let result = try await simulator.recommend(envelopeData: envelopeData)

        XCTAssertEqual(
            try benchGateProvenanceSource(for: "qwen2.5-coder-32b-instruct", in: result),
            "policy"
        )
    }

    func testInlineMutatedCatalogSHAIsRejected() async throws {
        let mutatedCatalog = AutotuneStaticInputs.bakedCandidateCatalogJSON.replacingOccurrences(
            of: "\"min_ram_gb\":48",
            with: "\"min_ram_gb\":47",
            options: [],
            range: AutotuneStaticInputs.bakedCandidateCatalogJSON.range(of: "\"min_ram_gb\":48")
        )
        let envelopeData = try makeEnvelopeData(candidateCatalog: mutatedCatalog)
        let simulator = AutotuneRecommendSimulator(
            fetchRateCard: { _ in throw URLError(.badURL) },
            bakedCandidateCatalogBytes: { Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8) },
            bakedDemandRankBytes: { Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8) }
        )

        do {
            _ = try await simulator.recommend(envelopeData: envelopeData)
            XCTFail("mutated inline legacy catalog without provenance must be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("candidate catalog sha256"))
        }
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
        candidateCatalog: String = #""@LIVE""#,
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
          "donorMode": false,
          "buyer_ttft_ceiling_ms": 1800
        }
        """
        return Data(json.utf8)
    }

    private func benchGateProvenanceSource(for model: String, in result: AutotuneRecommendResult) throws -> String {
        let simulatorJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.simulatorJSON().utf8)) as? [String: Any])
        let candidates = try XCTUnwrap(simulatorJSON["all_candidates"] as? [[String: Any]])
        let candidate = try XCTUnwrap(candidates.first { ($0["model"] as? String) == model })
        let provenance = try XCTUnwrap(candidate["bench_gate_provenance"] as? [String: Any])
        return try XCTUnwrap(provenance["source"] as? String)
    }
}
