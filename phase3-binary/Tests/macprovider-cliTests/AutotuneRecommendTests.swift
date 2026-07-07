import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class AutotuneRecommendTests: XCTestCase {
    func testRecommendationSelectsPaidEligibleRowAboveThreshold() throws {
        let request = try makeRequest()

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, "qwen3-coder-30b-a3b-instruct")
        XCTAssertFalse(result.warnings.contains(.noEligibleModel))
        XCTAssertGreaterThan(try XCTUnwrap(result.candidates.first?.rawScore), 0)
    }

    func testBakedNemotronInputsArePaidRecommendable() throws {
        let modelKey = "nvidia/nemotron-3-nano-30b-a3b"
        let demand = try AutotuneStaticInputs.decodeDemandRank(Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8))
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        let rateCard = try AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8))

        let demandRow = try XCTUnwrap(demand.rows[modelKey])
        XCTAssertTrue(demandRow.recommendable)
        XCTAssertEqual(demandRow.rank, 68)
        XCTAssertEqual(demandRow.demandWeight, 0.30)
        XCTAssertEqual(demandRow.minProviderTarget, 20)

        let catalogRow = try XCTUnwrap(catalog.rows[modelKey])
        XCTAssertEqual(catalogRow.modelID, "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit")
        XCTAssertEqual(catalogRow.modelRevision, "832f602eba5d22436c258c1462bdedc5afddb42b")
        XCTAssertEqual(catalogRow.modelSHA256, "1bc78f214f9a042eaeb290b1fa4cb29915df1028f79d8479266349166c40a71f")
        XCTAssertEqual(catalogRow.runtimeStatus, "recommendable")
        XCTAssertEqual(catalogRow.minRAMGB, 32)
        XCTAssertEqual(catalogRow.minBandwidthTier, .c)

        let rateMatch = try XCTUnwrap(rateCard.rowForRecommendation(modelKey: modelKey))
        XCTAssertEqual(rateMatch.key, "nemotron-3-nano-30b-a3b")
        let rateRow = rateMatch.row
        XCTAssertEqual(rateRow.promptRatePerMtok, 80_000)
        XCTAssertEqual(rateRow.completionRatePerMtok, 160_000)
        XCTAssertEqual(rateRow.providerShareBPS, 9_000)
    }

    func testPublishedStaticNemotronInputsArePaidRecommendableAndSigned() throws {
        let modelKey = "nvidia/nemotron-3-nano-30b-a3b"
        let staticDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("dist/static")
        let demandBytes = try Data(contentsOf: staticDir.appendingPathComponent("demand-rank.json"))
        let demandSigBytes = try Data(contentsOf: staticDir.appendingPathComponent("demand-rank.json.sig"))
        let catalogBytes = try Data(contentsOf: staticDir.appendingPathComponent("autotune-candidates.json"))
        let catalogSigBytes = try Data(contentsOf: staticDir.appendingPathComponent("autotune-candidates.json.sig"))
        let publicKeyBytes = try Data(contentsOf: staticDir.appendingPathComponent("keys/autotune-static-v4.public.base64"))

        XCTAssertEqual(String(decoding: publicKeyBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), AutotuneStaticInputs.publicKeyBase64)
        XCTAssertTrue(Self.sidecar(demandSigBytes, hasKeyID: AutotuneStaticInputs.keyID))
        XCTAssertTrue(Self.sidecar(catalogSigBytes, hasKeyID: AutotuneStaticInputs.keyID))
        XCTAssertTrue(AutotuneStaticInputs.defaultSignatureVerifier(jsonBytes: demandBytes, sidecarBytes: demandSigBytes))
        XCTAssertTrue(AutotuneStaticInputs.defaultSignatureVerifier(jsonBytes: catalogBytes, sidecarBytes: catalogSigBytes))

        let demand = try AutotuneStaticInputs.decodeDemandRank(demandBytes)
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(catalogBytes)

        let demandRow = try XCTUnwrap(demand.rows[modelKey])
        XCTAssertTrue(demandRow.recommendable)
        XCTAssertEqual(demandRow.rank, 68)
        XCTAssertEqual(demandRow.demandWeight, 0.30)
        XCTAssertEqual(demandRow.minProviderTarget, 20)

        let catalogRow = try XCTUnwrap(catalog.rows[modelKey])
        XCTAssertEqual(catalogRow.modelID, "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit")
        XCTAssertEqual(catalogRow.modelRevision, "832f602eba5d22436c258c1462bdedc5afddb42b")
        XCTAssertEqual(catalogRow.modelSHA256, "1bc78f214f9a042eaeb290b1fa4cb29915df1028f79d8479266349166c40a71f")
        XCTAssertEqual(catalogRow.runtimeStatus, "recommendable")
        XCTAssertEqual(catalogRow.minRAMGB, 32)
        XCTAssertEqual(catalogRow.minBandwidthTier, .c)
    }

    func testRecommendationJSONIncludesApplyReadyServeConfigWhenProvided() throws {
        let request = try makeRequest()
        let result = AutotuneRecommendEngine().recommend(request)
        let selected = try XCTUnwrap(result.selectedCandidate)
        let benchmark = try XCTUnwrap(request.benchmarks[selected.catalogKey])
        let row = try XCTUnwrap(request.candidateCatalog.rows[selected.catalogKey])
        let core = RecommendationCore(
            model: selected.model,
            targetContext: 4000,
            knobs: WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 4000),
            tpsMedian: selected.tokensPerSecond,
            ttftP95MS: 0,
            replicates: 0,
            modelArtifactPath: benchmark.modelArtifactPath,
            modelArtifactSHA256: benchmark.artifactSHA256,
            modelCatalogKey: selected.catalogKey,
            modelCatalogModelID: row.modelID,
            modelCatalogRevision: row.modelRevision,
            modelCatalogSHA256: row.modelSHA256,
            modelCatalogVersion: request.candidateCatalog.version,
            modelCatalogHash: request.candidateCatalogSHA256
        )

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.jsonString(serveConfig: core).utf8)) as? [String: Any])
        let serveConfig = try XCTUnwrap(root["serve_config"] as? [String: Any])

        XCTAssertEqual(Set(serveConfig.keys), Set(ConfigApplier.recommendationOwnedKeys))
        XCTAssertEqual(serveConfig["model"] as? String, selected.model)
        XCTAssertEqual(serveConfig["model_artifact_path"] as? String, benchmark.modelArtifactPath)
        XCTAssertEqual(serveConfig["model_artifact_sha256"] as? String, benchmark.artifactSHA256)
        XCTAssertEqual(serveConfig["model_catalog_key"] as? String, selected.catalogKey)
        XCTAssertEqual(serveConfig["model_catalog_model_id"] as? String, row.modelID)
        XCTAssertEqual(serveConfig["model_catalog_revision"] as? String, row.modelRevision)
        XCTAssertEqual(serveConfig["model_catalog_sha256"] as? String, row.modelSHA256)
        XCTAssertEqual(serveConfig["model_catalog_version"] as? String, request.candidateCatalog.version)
        XCTAssertEqual(serveConfig["model_catalog_hash"] as? String, request.candidateCatalogSHA256)
        XCTAssertEqual(serveConfig["max_context_override"] as? Int, 4000)
        XCTAssertEqual(serveConfig["max_concurrency_override"] as? Int, 1)
        XCTAssertEqual(serveConfig["donor_mode"] as? Bool, false)
        XCTAssertEqual(root["recommended_model"] as? String, result.recommendedModel)
    }

    func testRecommendationJSONUsesNullServeConfigWhenNotProvided() throws {
        let request = try makeRequest()
        let result = AutotuneRecommendEngine().recommend(request)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.jsonString().utf8)) as? [String: Any])

        XCTAssertTrue(root.keys.contains("serve_config"))
        XCTAssertTrue(root["serve_config"] is NSNull)
    }

    func testRecommendApplyServeConfigUsesHardwareDerivedMaxBatch() throws {
        var request = try makeRequest()
        request.hardware = Self.hardware(chip: "Apple M4 Max", memoryGB: 64, bandwidthTier: .a)
        let result = AutotuneRecommendEngine().recommend(request)
        let selected = try XCTUnwrap(result.selectedCandidate)
        let benchmark = try XCTUnwrap(request.benchmarks[selected.catalogKey])
        let row = try XCTUnwrap(request.candidateCatalog.rows[selected.catalogKey])

        let core = AutotuneCommand.recommendationCoreForConfig(
            selected: selected,
            selectedBenchmark: benchmark,
            selectedRow: row,
            catalogVersion: request.candidateCatalog.version,
            catalogHash: request.candidateCatalogSHA256,
            hardware: request.hardware
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.jsonString(serveConfig: core).utf8)) as? [String: Any])
        let serveConfig = try XCTUnwrap(root["serve_config"] as? [String: Any])

        XCTAssertEqual(core.knobs.maxBatch, 2)
        XCTAssertEqual(serveConfig["max_concurrency_override"] as? Int, 2)
    }

    func testAllRowsFailingEligibilityEmitsNoEligibleWarning() throws {
        var request = try makeRequest()
        request.benchmarks = [:]

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel)
        XCTAssertTrue(result.warnings.contains(.noEligibleModel))
        XCTAssertTrue(result.humanTranscript().contains("Recommendation: donor mode only"))
        XCTAssertTrue(result.humanTranscript().contains("Best compatible option: none"))
    }

    func testDonorModeDoesNotTurnListedRowsIntoPaidDefaults() throws {
        var request = try makeRequest(modelKey: "qwen3-32b")
        request.donorMode = true
        request.hardware.bandwidthTier = .a
        request.candidateCatalog.rows["qwen3-32b"]?.runtimeStatus = "listed"

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel)
        XCTAssertTrue(AutotuneRecommendEngine.donorModeAdmitted(
            modelKey: "qwen3-32b",
            candidate: request.candidateCatalog.rows["qwen3-32b"],
            request: request
        ))
    }

    func testNormalRecommendationTranscriptNamesListedDonorCompatibleFallback() throws {
        var request = try makeRequest(modelKey: "qwen3-32b")
        request.donorMode = false
        request.hardware.bandwidthTier = .a
        request.demandRank.rows["qwen3-32b"]?.recommendable = false
        request.candidateCatalog.rows["qwen3-32b"]?.runtimeStatus = "listed"

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel)
        XCTAssertEqual(result.donorFallbackModel, "qwen3-32b")
        XCTAssertTrue(result.humanTranscript().contains("Best compatible option: qwen3-32b"))
    }

    func testDonorFallbackOutsideTopFiveIsStillCarriedForApplyLookup() throws {
        var request = try makeRequest()
        request.donorMode = true
        let candidateTemplate = try XCTUnwrap(request.candidateCatalog.rows.values.first)
        let demandTemplate = try XCTUnwrap(request.demandRank.rows.values.first)
        let rateTemplate = try XCTUnwrap(request.rateCard.rows.values.first)
        request.candidateCatalog.rows = [:]
        request.demandRank.rows = [:]
        request.rateCard.rows = [:]
        request.benchmarks = [:]

        for index in 0..<6 {
            let key = "blocked-high-raw-\(index)"
            var candidate = candidateTemplate
            candidate.runtimeStatus = "blocked"
            request.candidateCatalog.rows[key] = candidate
            var demand = demandTemplate
            demand.demandWeight = 10
            demand.rank = index + 1
            demand.recommendable = true
            request.demandRank.rows[key] = demand
            request.rateCard.rows[key] = RateCardProjection.Row(
                promptRatePerMtok: rateTemplate.promptRatePerMtok,
                completionRatePerMtok: 9_000_000,
                providerShareBPS: rateTemplate.providerShareBPS,
                globalMultiplierPPM: rateTemplate.globalMultiplierPPM
            )
            request.benchmarks[key] = CandidateBenchmark(
                modelKey: key,
                sustainedTPS: 1_000,
                ttftMS: 1,
                swapDetected: false,
                thermalThrottleDetected: false,
                artifactSHA256: candidate.modelSHA256!,
                modelArtifactPath: "/tmp/\(key)",
                benchmarkID: "bench-\(key)",
                generatedAt: request.generatedAt,
                candidateCatalogSHA256: request.candidateCatalogSHA256,
                binaryVersion: request.hardware.binaryVersion,
                modelID: candidate.modelID,
                hardwareIdentityHash: request.hardware.hardwareIdentityHash
            )
        }

        let donorKey = "listed-donor-fallback"
        var donorCandidate = candidateTemplate
        donorCandidate.runtimeStatus = "listed"
        request.candidateCatalog.rows[donorKey] = donorCandidate
        var donorDemand = demandTemplate
        donorDemand.demandWeight = 0.1
        donorDemand.rank = 99
        donorDemand.recommendable = false
        request.demandRank.rows[donorKey] = donorDemand
        request.rateCard.rows[donorKey] = rateTemplate
        request.benchmarks[donorKey] = CandidateBenchmark(
            modelKey: donorKey,
            sustainedTPS: 100,
            ttftMS: 1,
            swapDetected: false,
            thermalThrottleDetected: false,
            artifactSHA256: donorCandidate.modelSHA256!,
            modelArtifactPath: "/tmp/\(donorKey)",
            benchmarkID: "bench-\(donorKey)",
            generatedAt: request.generatedAt,
            candidateCatalogSHA256: request.candidateCatalogSHA256,
            binaryVersion: request.hardware.binaryVersion,
            modelID: donorCandidate.modelID,
            hardwareIdentityHash: request.hardware.hardwareIdentityHash
        )

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel)
        XCTAssertEqual(result.candidates.count, 5)
        XCTAssertFalse(result.candidates.contains { $0.catalogKey == donorKey })
        XCTAssertEqual(result.donorFallbackModel, donorKey)
        XCTAssertEqual(result.donorFallbackCandidate?.catalogKey, donorKey)
        XCTAssertFalse(result.jsonString().contains("donorFallbackCandidate"))
        XCTAssertFalse(result.jsonString().contains("donor_fallback_candidate"))
    }

    func testDonorModeRejectsBlockedRows() throws {
        var request = try makeRequest(modelKey: "google-gemma-4-26b-a4b-it")
        request.donorMode = true
        request.candidateCatalog.rows["google-gemma-4-26b-a4b-it"]?.modelRevision = String(repeating: "6", count: 40)
        request.candidateCatalog.rows["google-gemma-4-26b-a4b-it"]?.modelSHA256 = String(repeating: "f", count: 64)

        XCTAssertFalse(AutotuneRecommendEngine.donorModeAdmitted(
            modelKey: "google-gemma-4-26b-a4b-it",
            candidate: request.candidateCatalog.rows["google-gemma-4-26b-a4b-it"],
            request: request
        ))
    }

    func testDonorTranscriptDoesNotNameBlockedRowsAsCompatible() throws {
        var request = try makeRequest(modelKey: "google-gemma-4-26b-a4b-it")
        request.donorMode = true
        request.candidateCatalog.rows["google-gemma-4-26b-a4b-it"]?.modelRevision = String(repeating: "6", count: 40)
        request.candidateCatalog.rows["google-gemma-4-26b-a4b-it"]?.modelSHA256 = String(repeating: "f", count: 64)

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel)
        XCTAssertTrue(result.humanTranscript().contains("Best compatible option: none"))
        XCTAssertFalse(result.humanTranscript().contains("Best compatible option: google-gemma-4-26b-a4b-it"))
    }

    func testCachedBenchmarkAdmissionRejectsEveryMismatch() throws {
        let request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        let baseline = try XCTUnwrap(request.benchmarks[modelKey])
        XCTAssertTrue(AutotuneRecommendEngine.cachedBenchmarkAdmitted(baseline, request: request, modelKey: modelKey))

        var catalogMismatch = baseline
        catalogMismatch.candidateCatalogSHA256 = "mismatch"
        XCTAssertFalse(AutotuneRecommendEngine.cachedBenchmarkAdmitted(catalogMismatch, request: request, modelKey: modelKey))

        var binaryMismatch = baseline
        binaryMismatch.binaryVersion = "other"
        XCTAssertFalse(AutotuneRecommendEngine.cachedBenchmarkAdmitted(binaryMismatch, request: request, modelKey: modelKey))

        var modelMismatch = baseline
        modelMismatch.modelID = "other/model"
        XCTAssertFalse(AutotuneRecommendEngine.cachedBenchmarkAdmitted(modelMismatch, request: request, modelKey: modelKey))

        var artifactMismatch = baseline
        artifactMismatch.artifactSHA256 = String(repeating: "0", count: 64)
        XCTAssertFalse(AutotuneRecommendEngine.cachedBenchmarkAdmitted(artifactMismatch, request: request, modelKey: modelKey))

        var hardwareMismatch = baseline
        hardwareMismatch.hardwareIdentityHash = "other"
        XCTAssertFalse(AutotuneRecommendEngine.cachedBenchmarkAdmitted(hardwareMismatch, request: request, modelKey: modelKey))

        var stale = baseline
        stale.generatedAt = request.generatedAt.addingTimeInterval(-(AutotuneRecommendEngine.maxBenchmarkAge + 1))
        XCTAssertFalse(AutotuneRecommendEngine.cachedBenchmarkAdmitted(stale, request: request, modelKey: modelKey))
    }

    func testRateCardFallsThroughToDefaultForArbitraryModelKey() throws {
        // v1.7.6 Track A1: any model without a specific rate-card row
        // falls through to the "default" row so probe-feasible models
        // still receive an earnings estimate. Coord's `RateFor` at
        // phase4-coordinator/internal/billing/formula.go already pays
        // the default rate for served inference on unmatched models —
        // client now agrees.
        let rateCard = try AutotuneStaticInputs.decodeRateCard(Data("""
        {"version":"test","generated_at":"2026-07-01T00:00:00Z","usd_per_million_credits":1.0,"rows":{"default":{"prompt_rate_per_mtok":1,"completion_rate_per_mtok":1,"provider_share_bps":9000,"global_multiplier_ppm":1000000}}}
        """.utf8))

        XCTAssertEqual(rateCard.rowForRecommendation(modelKey: "qwen3-coder-30b-a3b-instruct")?.key, "default")
        XCTAssertEqual(rateCard.rowForRecommendation(modelKey: "meta-llama/llama-3.1-8b-instruct")?.key, "default")
        XCTAssertEqual(rateCard.rowForRecommendation(modelKey: "default")?.key, "default")
    }

    func testRateCardReturnsNilWhenNoDefaultAndNoMatch() throws {
        let rateCard = try AutotuneStaticInputs.decodeRateCard(Data("""
        {"version":"test","generated_at":"2026-07-01T00:00:00Z","usd_per_million_credits":1.0,"rows":{"qwen3-32b":{"prompt_rate_per_mtok":1,"completion_rate_per_mtok":1,"provider_share_bps":9000,"global_multiplier_ppm":1000000}}}
        """.utf8))

        XCTAssertNil(rateCard.rowForRecommendation(modelKey: "unknown-model"))
    }

    func testRateCardPrefersSpecificRowOverDefault() throws {
        // v1.7.6 Track A1: exact/normalized specific row wins over "default".
        let rateCard = try AutotuneStaticInputs.decodeRateCard(Data("""
        {"version":"test","generated_at":"2026-07-01T00:00:00Z","usd_per_million_credits":1.0,"rows":{"default":{"prompt_rate_per_mtok":9,"completion_rate_per_mtok":9,"provider_share_bps":9000,"global_multiplier_ppm":1000000},"qwen3-32b":{"prompt_rate_per_mtok":1,"completion_rate_per_mtok":1,"provider_share_bps":9000,"global_multiplier_ppm":1000000}}}
        """.utf8))

        let match = rateCard.rowForRecommendation(modelKey: "qwen3-32b")
        XCTAssertEqual(match?.key, "qwen3-32b")
        XCTAssertEqual(match?.row.promptRatePerMtok, 1)
    }

    func testNormalizedRateCardLookupRecordsNormalizedKey() throws {
        let rateCard = try AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8))

        let row = rateCard.rowForRecommendation(modelKey: "mlx-community/gpt-oss-20b-MXFP4-Q8")

        XCTAssertEqual(row?.key, "openai/gpt-oss-20b")
    }

    func testNemotronRateCardLookupUsesNormalizedCoordinatorKey() throws {
        let rateCard = try AutotuneStaticInputs.decodeRateCard(Data("""
        {"version":"test","generated_at":"2026-07-06T00:00:00Z","usd_per_million_credits":1.0,"rows":{"default":{"prompt_rate_per_mtok":500000,"completion_rate_per_mtok":1000000,"provider_share_bps":9000,"global_multiplier_ppm":1000000},"nemotron-3-nano-30b-a3b":{"prompt_rate_per_mtok":117500,"completion_rate_per_mtok":235000,"provider_share_bps":9000,"global_multiplier_ppm":1000000}}}
        """.utf8))

        for modelKey in [
            "nvidia/nemotron-3-nano-30b-a3b",
            "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit",
        ] {
            let row = rateCard.rowForRecommendation(modelKey: modelKey)
            XCTAssertEqual(row?.key, "nemotron-3-nano-30b-a3b")
            XCTAssertEqual(row?.row.promptRatePerMtok, 117_500)
            XCTAssertEqual(row?.row.completionRatePerMtok, 235_000)
        }
    }

    func testNemotronRecommendationKeepsPublicServedModelWithNormalizedRateCard() throws {
        let modelKey = "nvidia/nemotron-3-nano-30b-a3b"
        var request = try makeRequest(modelKey: modelKey)
        request.rateCard.rows = [
            "nemotron-3-nano-30b-a3b": RateCardProjection.Row(
                promptRatePerMtok: 117_500,
                completionRatePerMtok: 235_000,
                providerShareBPS: 9_000,
                globalMultiplierPPM: 1_000_000
            ),
        ]

        let result = AutotuneRecommendEngine().recommend(request)
        let selected = try XCTUnwrap(result.selectedCandidate)
        let benchmark = try XCTUnwrap(request.benchmarks[selected.catalogKey])
        let row = try XCTUnwrap(request.candidateCatalog.rows[selected.catalogKey])
        let core = RecommendationCore(
            model: selected.model,
            targetContext: 4000,
            knobs: WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 4000),
            tpsMedian: selected.tokensPerSecond,
            ttftP95MS: 0,
            replicates: 0,
            modelArtifactPath: benchmark.modelArtifactPath,
            modelArtifactSHA256: benchmark.artifactSHA256,
            modelCatalogKey: selected.catalogKey,
            modelCatalogModelID: row.modelID,
            modelCatalogRevision: row.modelRevision,
            modelCatalogSHA256: row.modelSHA256,
            modelCatalogVersion: request.candidateCatalog.version,
            modelCatalogHash: request.candidateCatalogSHA256
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.jsonString(serveConfig: core).utf8)) as? [String: Any])
        let serveConfig = try XCTUnwrap(root["serve_config"] as? [String: Any])

        XCTAssertEqual(result.recommendedModel, modelKey)
        XCTAssertEqual(selected.model, modelKey)
        XCTAssertEqual(selected.catalogKey, modelKey)
        XCTAssertEqual(serveConfig["model"] as? String, modelKey)
        XCTAssertEqual(serveConfig["model_catalog_key"] as? String, modelKey)
        XCTAssertEqual(request.rateCard.rowForRecommendation(modelKey: modelKey)?.key, "nemotron-3-nano-30b-a3b")
    }

    func testNormalizedRecommendationKeepsCatalogKeyForBenchmarkLookup() throws {
        let alias = "mlx-community/gpt-oss-20b-MXFP4-Q8"
        let normalized = "openai/gpt-oss-20b"
        var request = try makeRequest(modelKey: normalized)
        request.candidateCatalog.rows[alias] = request.candidateCatalog.rows.removeValue(forKey: normalized)
        request.demandRank.rows[alias] = request.demandRank.rows.removeValue(forKey: normalized)
        var benchmark = try XCTUnwrap(request.benchmarks.removeValue(forKey: normalized))
        benchmark.modelKey = alias
        benchmark.benchmarkID = "bench-alias"
        request.benchmarks[alias] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, normalized)
        XCTAssertEqual(result.candidates.first?.model, normalized)
        XCTAssertEqual(result.candidates.first?.catalogKey, alias)
        XCTAssertEqual(result.benchmarkID, "bench-alias")
        XCTAssertFalse(result.jsonString().contains("catalogKey"))
        XCTAssertFalse(result.jsonString().contains("catalog_key"))
    }

    func testRecommendedModelIsAlwaysTopRankedEligibleRow() throws {
        var request = try makeRequest()
        let candidateTemplate = try XCTUnwrap(request.candidateCatalog.rows.values.first)
        let demandTemplate = try XCTUnwrap(request.demandRank.rows.values.first)
        let rateTemplate = try XCTUnwrap(request.rateCard.rows.values.first)
        request.candidateCatalog.rows = [:]
        request.demandRank.rows = [:]
        request.rateCard.rows = [:]
        request.benchmarks = [:]

        for index in 0..<6 {
            let key = "candidate-\(index)"
            var candidate = candidateTemplate
            candidate.modelID = "test/\(key)"
            candidate.modelRevision = String(repeating: "\(index)", count: 40)
            candidate.modelSHA256 = String(repeating: "a", count: 64)
            candidate.runtimeStatus = "recommendable"
            request.candidateCatalog.rows[key] = candidate
            request.demandRank.rows[key] = demandTemplate
            request.rateCard.rows[key] = rateTemplate
            request.benchmarks[key] = CandidateBenchmark(
                modelKey: key,
                sustainedTPS: 100,
                ttftMS: 1,
                swapDetected: false,
                thermalThrottleDetected: false,
                artifactSHA256: candidate.modelSHA256!,
                modelArtifactPath: "/tmp/\(key)",
                benchmarkID: "bench-\(key)",
                generatedAt: request.generatedAt,
                candidateCatalogSHA256: request.candidateCatalogSHA256,
                binaryVersion: request.hardware.binaryVersion,
                modelID: candidate.modelID,
                hardwareIdentityHash: request.hardware.hardwareIdentityHash
            )
        }

        let result = AutotuneRecommendEngine().recommend(request)
        let recommended = try XCTUnwrap(result.recommendedModel)
        let selected = try XCTUnwrap(result.selectedCandidate)
        XCTAssertEqual(selected.model, recommended)
        XCTAssertEqual(selected.rank, 1)
        XCTAssertTrue(result.candidates.contains { $0.model == recommended })
        XCTAssertEqual(result.candidates.first?.model, recommended)
        XCTAssertFalse(result.jsonString().contains("selectedCandidate"))
        XCTAssertFalse(result.jsonString().contains("selected_candidate"))
    }

    func testPayoutScoreRanksAboveThroughputAndDemand() throws {
        var request = try makeRequest()
        let candidateTemplate = try XCTUnwrap(request.candidateCatalog.rows.values.first)
        let demandTemplate = try XCTUnwrap(request.demandRank.rows.values.first)
        request.candidateCatalog.rows = [:]
        request.demandRank.rows = [:]
        request.rateCard.rows = [:]
        request.benchmarks = [:]

        let highPayoutKey = "high-payout-low-throughput"
        var highPayoutCandidate = candidateTemplate
        highPayoutCandidate.modelID = "test/high-payout"
        highPayoutCandidate.modelRevision = String(repeating: "1", count: 40)
        highPayoutCandidate.modelSHA256 = String(repeating: "b", count: 64)
        request.candidateCatalog.rows[highPayoutKey] = highPayoutCandidate
        request.demandRank.rows[highPayoutKey] = demandTemplate
        request.rateCard.rows[highPayoutKey] = RateCardProjection.Row(
            promptRatePerMtok: 450_000,
            completionRatePerMtok: 900_000,
            providerShareBPS: 9_000,
            globalMultiplierPPM: 1_000_000
        )
        request.benchmarks[highPayoutKey] = CandidateBenchmark(
            modelKey: highPayoutKey,
            sustainedTPS: 1,
            ttftMS: 1,
            swapDetected: false,
            thermalThrottleDetected: false,
            artifactSHA256: highPayoutCandidate.modelSHA256!,
            modelArtifactPath: "/tmp/high-payout",
            benchmarkID: "bench-high-payout",
            generatedAt: request.generatedAt,
            candidateCatalogSHA256: request.candidateCatalogSHA256,
            binaryVersion: request.hardware.binaryVersion,
            modelID: highPayoutCandidate.modelID,
            hardwareIdentityHash: request.hardware.hardwareIdentityHash
        )

        let highThroughputKey = "low-payout-high-throughput"
        var highThroughputCandidate = candidateTemplate
        highThroughputCandidate.modelID = "test/high-throughput"
        highThroughputCandidate.modelRevision = String(repeating: "2", count: 40)
        highThroughputCandidate.modelSHA256 = String(repeating: "c", count: 64)
        request.candidateCatalog.rows[highThroughputKey] = highThroughputCandidate
        var highDemand = demandTemplate
        highDemand.demandWeight = 10
        request.demandRank.rows[highThroughputKey] = highDemand
        request.rateCard.rows[highThroughputKey] = RateCardProjection.Row(
            promptRatePerMtok: 13_500,
            completionRatePerMtok: 27_000,
            providerShareBPS: 9_000,
            globalMultiplierPPM: 1_000_000
        )
        request.benchmarks[highThroughputKey] = CandidateBenchmark(
            modelKey: highThroughputKey,
            sustainedTPS: 1_000,
            ttftMS: 1,
            swapDetected: false,
            thermalThrottleDetected: false,
            artifactSHA256: highThroughputCandidate.modelSHA256!,
            modelArtifactPath: "/tmp/high-throughput",
            benchmarkID: "bench-high-throughput",
            generatedAt: request.generatedAt,
            candidateCatalogSHA256: request.candidateCatalogSHA256,
            binaryVersion: request.hardware.binaryVersion,
            modelID: highThroughputCandidate.modelID,
            hardwareIdentityHash: request.hardware.hardwareIdentityHash
        )

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, highPayoutKey)
        XCTAssertGreaterThan(
            try XCTUnwrap(result.candidates.first?.rawScore),
            try XCTUnwrap(result.candidates.first { $0.model == highThroughputKey }?.rawScore)
        )
    }

    func testJSONCandidatesExcludeIneligibleDiagnosticsWhenEligibleRowsExist() throws {
        let eligibleKey = "qwen3-coder-30b-a3b-instruct"
        let diagnosticKey = "diagnostic-listed-row"
        var request = try makeRequest(modelKey: eligibleKey)
        var diagnosticRow = try XCTUnwrap(request.candidateCatalog.rows[eligibleKey])
        diagnosticRow.runtimeStatus = "listed"
        request.candidateCatalog.rows[diagnosticKey] = diagnosticRow
        request.demandRank.rows[diagnosticKey] = DemandRank.Row(
            demandWeight: 0.5,
            rank: 2,
            recommendable: false,
            minProviderTarget: 0
        )

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.candidates.map(\.catalogKey), [eligibleKey])
    }

    func testBandwidthTierOrderingAndDerivation() {
        XCTAssertTrue(BandwidthTier.a.satisfies(minimum: .b))
        XCTAssertFalse(BandwidthTier.b.satisfies(minimum: .a))
        XCTAssertEqual(BandwidthTier.derive(chip: "Apple M4 Ultra"), .s)
        XCTAssertEqual(BandwidthTier.derive(chip: "Apple M3 Max"), .a)
        XCTAssertEqual(BandwidthTier.derive(chip: "Apple M5 Max"), .a)
        XCTAssertEqual(BandwidthTier.derive(chip: "Apple M2 Max"), .b)
        XCTAssertEqual(BandwidthTier.derive(chip: "Apple M2 Pro"), .b)
    }

    func testRecommendedMaxBatchKeepsBaseAndProSingleSlot() {
        XCTAssertEqual(Self.hardware(chip: "Apple M5", memoryGB: 32, bandwidthTier: .c).recommendedMaxBatch, 1)
        XCTAssertEqual(Self.hardware(chip: "Apple M4 Pro", memoryGB: 64, bandwidthTier: .b).recommendedMaxBatch, 1)
    }

    func testRecommendedMaxBatchBumpsMaxAndUltraTiers() {
        XCTAssertEqual(Self.hardware(chip: "Apple M4 Max", memoryGB: 48, bandwidthTier: .a).recommendedMaxBatch, 2)
        XCTAssertEqual(Self.hardware(chip: "Apple M4 Ultra", memoryGB: 96, bandwidthTier: .s).recommendedMaxBatch, 3)
        XCTAssertEqual(Self.hardware(chip: "Apple M4 Ultra", memoryGB: 128, bandwidthTier: .s).recommendedMaxBatch, 4)
        XCTAssertEqual(Self.hardware(chip: "Apple M4 Ultra", memoryGB: 192, bandwidthTier: .s).recommendedMaxBatch, 4)
    }

    func testRecommendedMaxBatchDoesNotBumpLowRamMaxOrUltra() {
        XCTAssertEqual(Self.hardware(chip: "Apple M3 Max", memoryGB: 36, bandwidthTier: .a).recommendedMaxBatch, 1)
        XCTAssertEqual(Self.hardware(chip: "Apple M2 Ultra", memoryGB: 64, bandwidthTier: .a).recommendedMaxBatch, 1)
    }

    func testMinProviderTargetDoesNotAffectScoringOrEligibility() throws {
        var request = try makeRequest()
        let first = AutotuneRecommendEngine().recommend(request)
        request.demandRank.rows["qwen3-coder-30b-a3b-instruct"]?.minProviderTarget = 999_999
        let second = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(first.recommendedModel, second.recommendedModel)
        XCTAssertEqual(first.candidates.first?.rawScore, second.candidates.first?.rawScore)
    }

    func testRecommendationIsDeterministicForSameDiversificationID() throws {
        let request = try makeRequest()

        let first = AutotuneRecommendEngine().recommend(request)
        let second = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(first.recommendedModel, second.recommendedModel)
        XCTAssertEqual(first.candidates, second.candidates)
    }

    func testJSONFieldOrderStartsWithLockedSchemaOrder() throws {
        let result = AutotuneRecommendEngine().recommend(try makeRequest())
        let json = result.jsonString()

        XCTAssertTrue(json.hasPrefix(#"{"schema_version":"autotune_recommend.v1","generated_at":"#), json)
        XCTAssertLessThan(try XCTUnwrap(json.range(of: #""hardware":"#)?.lowerBound), try XCTUnwrap(json.range(of: #""inputs":"#)?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(json.range(of: #""inputs":"#)?.lowerBound), try XCTUnwrap(json.range(of: #""recommended_model":"#)?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(json.range(of: #""recommended_model":"#)?.lowerBound), try XCTUnwrap(json.range(of: #""prompt_rate_usd_per_million_tokens":"#)?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(json.range(of: #""prompt_rate_usd_per_million_tokens":"#)?.lowerBound), try XCTUnwrap(json.range(of: #""candidates":"#)?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(json.range(of: #""candidates":"#)?.lowerBound), try XCTUnwrap(json.range(of: #""warnings":"#)?.lowerBound))
    }

    func testSignedStaticFallbackAndStaleWarnings() async throws {
        let validFetched = Data(AutotuneStaticInputs.bakedDemandRankJSON
            .replacingOccurrences(of: "published-2026-07-07-p1-gemma", with: "fetched-2026-07-10")
            .replacingOccurrences(of: "2026-07-01T00:00:00Z", with: "2026-07-10T00:00:00Z")
            .utf8)
        let sidecar = Data(#"{"key_id":"streamvc-autotune-static-v4","alg":"ed25519","signature":"AA=="}"#.utf8)
        let staleInputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? sidecar : validFetched },
            verifySignature: { _, _ in true },
            now: { Self.date("2026-07-30T00:00:00Z") }
        )

        let stale = await staleInputs.loadDemandRank()

        XCTAssertFalse(stale.usedFallback)
        XCTAssertEqual(stale.value.version, "fetched-2026-07-10")
        XCTAssertTrue(stale.warnings.contains(.demandRankStale))

        let fallbackInputs = AutotuneStaticInputs(
            fetch: { _ in validFetched },
            verifySignature: { _, _ in false },
            now: { Self.date("2026-07-30T00:00:00Z") }
        )
        let fallback = await fallbackInputs.loadDemandRank()
        XCTAssertTrue(fallback.usedFallback)
        XCTAssertTrue(fallback.warnings.contains(.demandRankFallbackUsed))
    }

    func testSignedStaticRejectsSidecarWithExtraFields() async throws {
        let fetched = Data(AutotuneStaticInputs.bakedDemandRankJSON
            .replacingOccurrences(of: "published-2026-07-07-p1-gemma", with: "fetched-2026-07-10")
            .replacingOccurrences(of: "2026-07-01T00:00:00Z", with: "2026-07-10T00:00:00Z")
            .utf8)
        let sidecar = Data(#"{"key_id":"streamvc-autotune-static-v4","alg":"ed25519","signature":"AA==","extra":true}"#.utf8)
        let inputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? sidecar : fetched },
            verifySignature: { _, _ in true },
            now: { Self.date("2026-07-11T00:00:00Z") }
        )

        let selection = await inputs.loadDemandRank()

        XCTAssertTrue(selection.usedFallback)
        XCTAssertTrue(selection.warnings.contains(.demandRankFallbackUsed))
    }

    func testPinnedPublicKeyIsValidCurve25519SigningKey() {
        let keyData = Data(base64Encoded: AutotuneStaticInputs.autotune_static_json_ed25519_v4)

        XCTAssertEqual(keyData?.count, 32)
        XCTAssertNotNil(try? Curve25519.Signing.PublicKey(rawRepresentation: try XCTUnwrap(keyData)))
    }

    func testCandidateCatalogHashChangesWithWhitespace() {
        let compact = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        let spaced = Data((AutotuneStaticInputs.bakedCandidateCatalogJSON + "\n").utf8)

        XCTAssertNotEqual(
            AutotuneStaticInputs.candidateCatalogSHA256(bytes: compact),
            AutotuneStaticInputs.candidateCatalogSHA256(bytes: spaced)
        )
    }

    func testCandidateCatalogRejectsUppercaseRevisionAndSHA() throws {
        let json = """
        {"version":"test","generated_at":"2026-07-01T00:00:00Z","source":"operator_curated_autotune_candidate_catalog","rows":{"model-a":{"model_id":"namespace/model","model_revision":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","model_sha256":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","min_ram_gb":1,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"recommendable"}}}
        """

        XCTAssertThrowsError(try AutotuneStaticInputs.decodeCandidateCatalog(Data(json.utf8)))
    }

    func testHFAssetRedirectAllowsKnownCDNAndStripsAuthorization() {
        let session = URLSession.shared
        let original = URL(string: "https://huggingface.co/mlx-community/model/resolve/rev/model.safetensors")!
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(
            url: original,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://us.aws.cdn.hf.co/model.safetensors"]
        )!
        var newRequest = URLRequest(url: URL(string: "https://us.aws.cdn.hf.co/model.safetensors")!)
        newRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let waiter = expectation(description: "redirect completion")
        var redirected: URLRequest?
        HFAssetRedirectGuard().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: newRequest
        ) { request in
            redirected = request
            waiter.fulfill()
        }
        wait(for: [waiter], timeout: 1)
        task.cancel()

        XCTAssertEqual(redirected?.url?.host, "us.aws.cdn.hf.co")
        XCTAssertNil(redirected?.value(forHTTPHeaderField: "Authorization"))
    }

    func testHFAssetRedirectRejectsUnknownHost() {
        let session = URLSession.shared
        let original = URL(string: "https://huggingface.co/mlx-community/model/resolve/rev/model.safetensors")!
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(
            url: original,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://evil.example.com/model.safetensors"]
        )!
        let newRequest = URLRequest(url: URL(string: "https://evil.example.com/model.safetensors")!)

        let waiter = expectation(description: "redirect completion")
        var redirected: URLRequest?
        HFAssetRedirectGuard().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: newRequest
        ) { request in
            redirected = request
            waiter.fulfill()
        }
        wait(for: [waiter], timeout: 1)
        task.cancel()

        XCTAssertNil(redirected)
    }

    // MARK: - downloadWithResume (v1.7.4 retry-with-resume for HF -1005 drops)

    private static func makeDownloadRetryPolicyNoDelay(
        maxAttempts: Int,
        sleepCalls: SleepCounter
    ) -> HuggingFaceSnapshotDownloader.DownloadRetryPolicy {
        HuggingFaceSnapshotDownloader.DownloadRetryPolicy(
            maxAttempts: maxAttempts,
            baseDelaySeconds: 0.0,
            backoffMultiplier: 1.0,
            sleep: { ns in await sleepCalls.record(ns) }
        )
    }

    private actor SleepCounter {
        var invocations: [UInt64] = []
        func record(_ ns: UInt64) { invocations.append(ns) }
        func snapshot() -> [UInt64] { invocations }
    }

    private static let dummyOKResponse: HTTPURLResponse = HTTPURLResponse(
        url: URL(string: "https://huggingface.co/repo/resolve/main/file.safetensors")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!

    private static func fakeDownloadedFileURL(name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hf-download-resume-\(UUID().uuidString)-\(name)")
        try Data("stub".utf8).write(to: url)
        return url
    }

    func testDownloadWithResumeSucceedsOnFirstAttempt() async throws {
        let counter = SleepCounter()
        let policy = Self.makeDownloadRetryPolicyNoDelay(maxAttempts: 3, sleepCalls: counter)
        let request = URLRequest(url: URL(string: "https://huggingface.co/repo/resolve/main/file.safetensors")!)
        let temp = try Self.fakeDownloadedFileURL(name: "first-attempt")

        let initialCalls = SleepCounter()
        let (localURL, response) = try await HuggingFaceSnapshotDownloader.downloadWithResume(
            request: request,
            policy: policy,
            initialDownload: { req in
                await initialCalls.record(UInt64(req.url?.absoluteString.count ?? 0))
                return (temp, Self.dummyOKResponse)
            },
            resumeDownload: { _ in
                XCTFail("resume should not be invoked when initial download succeeds")
                return (temp, Self.dummyOKResponse)
            }
        )

        XCTAssertEqual(localURL, temp)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let calls = await initialCalls.snapshot()
        XCTAssertEqual(calls.count, 1)
        let sleeps = await counter.snapshot()
        XCTAssertTrue(sleeps.isEmpty, "no backoff sleep expected on first-try success")
        try? FileManager.default.removeItem(at: temp)
    }

    func testDownloadWithResumeUsesResumeDataOnTransientFailure() async throws {
        let counter = SleepCounter()
        let policy = Self.makeDownloadRetryPolicyNoDelay(maxAttempts: 3, sleepCalls: counter)
        let request = URLRequest(url: URL(string: "https://huggingface.co/repo/resolve/main/file.safetensors")!)
        let resumeBlob = Data("resume-state-bytes".utf8)
        let temp = try Self.fakeDownloadedFileURL(name: "resume-hit")

        let resumeCalls = SleepCounter()
        let (localURL, _) = try await HuggingFaceSnapshotDownloader.downloadWithResume(
            request: request,
            policy: policy,
            initialDownload: { _ in
                throw URLError(
                    .networkConnectionLost,
                    userInfo: [NSURLSessionDownloadTaskResumeData: resumeBlob]
                )
            },
            resumeDownload: { data in
                XCTAssertEqual(data, resumeBlob, "resume must carry the exact bytes URLSession serialized")
                await resumeCalls.record(UInt64(data.count))
                return (temp, Self.dummyOKResponse)
            }
        )

        XCTAssertEqual(localURL, temp)
        let calls = await resumeCalls.snapshot()
        XCTAssertEqual(calls.count, 1)
        let sleeps = await counter.snapshot()
        XCTAssertEqual(sleeps.count, 1, "one backoff sleep expected between attempts 1 and 2")
        try? FileManager.default.removeItem(at: temp)
    }

    func testDownloadWithResumeRetriesFreshWhenNoResumeDataProvided() async throws {
        let counter = SleepCounter()
        let policy = Self.makeDownloadRetryPolicyNoDelay(maxAttempts: 3, sleepCalls: counter)
        let request = URLRequest(url: URL(string: "https://huggingface.co/repo/resolve/main/file.safetensors")!)
        let temp = try Self.fakeDownloadedFileURL(name: "no-resume-fresh")

        let initialCalls = SleepCounter()
        _ = try await HuggingFaceSnapshotDownloader.downloadWithResume(
            request: request,
            policy: policy,
            initialDownload: { req in
                await initialCalls.record(UInt64(req.url?.absoluteString.count ?? 0))
                let count = await initialCalls.snapshot().count
                if count == 1 {
                    throw URLError(.timedOut)
                }
                return (temp, Self.dummyOKResponse)
            },
            resumeDownload: { _ in
                XCTFail("resume must not run when no resume data was captured")
                return (temp, Self.dummyOKResponse)
            }
        )

        let calls = await initialCalls.snapshot()
        XCTAssertEqual(calls.count, 2, "second attempt is a fresh initialDownload when no resume data")
        try? FileManager.default.removeItem(at: temp)
    }

    func testDownloadWithResumeExhaustsAttemptsThenThrowsLast() async throws {
        let counter = SleepCounter()
        let policy = Self.makeDownloadRetryPolicyNoDelay(maxAttempts: 3, sleepCalls: counter)
        let request = URLRequest(url: URL(string: "https://huggingface.co/repo/resolve/main/file.safetensors")!)
        let final = URLError(.networkConnectionLost)

        do {
            _ = try await HuggingFaceSnapshotDownloader.downloadWithResume(
                request: request,
                policy: policy,
                initialDownload: { _ in throw URLError(.timedOut) },
                resumeDownload: { _ in throw final }
            )
            XCTFail("expected throw after all attempts fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut, "no resume data ever captured, initial keeps running; last=timedOut")
        }
        let sleeps = await counter.snapshot()
        XCTAssertEqual(sleeps.count, 2, "sleeps=maxAttempts-1 between failing attempts")
    }

    func testDownloadWithResumeRethrowsNonTransientImmediately() async throws {
        let counter = SleepCounter()
        let policy = Self.makeDownloadRetryPolicyNoDelay(maxAttempts: 3, sleepCalls: counter)
        let request = URLRequest(url: URL(string: "https://huggingface.co/repo/resolve/main/file.safetensors")!)

        // .cancelled (-999) is programmatic cancel — never retry.
        do {
            _ = try await HuggingFaceSnapshotDownloader.downloadWithResume(
                request: request,
                policy: policy,
                initialDownload: { _ in throw URLError(.cancelled) },
                resumeDownload: { _ in
                    XCTFail("resume must not run on non-transient error")
                    return (URL(fileURLWithPath: "/tmp/x"), Self.dummyOKResponse)
                }
            )
            XCTFail("expected cancellation to propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        let sleeps = await counter.snapshot()
        XCTAssertTrue(sleeps.isEmpty, "non-transient errors skip backoff and skip retry")
    }

    func testDownloadWithResumeRethrowsNonURLErrorImmediately() async throws {
        struct SpecificError: Error, Equatable {}
        let counter = SleepCounter()
        let policy = Self.makeDownloadRetryPolicyNoDelay(maxAttempts: 3, sleepCalls: counter)
        let request = URLRequest(url: URL(string: "https://huggingface.co/repo/resolve/main/file.safetensors")!)

        do {
            _ = try await HuggingFaceSnapshotDownloader.downloadWithResume(
                request: request,
                policy: policy,
                initialDownload: { _ in throw SpecificError() },
                resumeDownload: { _ in
                    XCTFail("resume must not run on non-URLError")
                    return (URL(fileURLWithPath: "/tmp/x"), Self.dummyOKResponse)
                }
            )
            XCTFail("expected non-URLError to propagate")
        } catch is SpecificError {
            // expected
        } catch {
            XCTFail("expected SpecificError; got \(error)")
        }
        let sleeps = await counter.snapshot()
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testIsTransientDownloadErrorCoversExpectedSet() {
        let transient: [URLError.Code] = [
            .networkConnectionLost, .timedOut, .notConnectedToInternet,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .resourceUnavailable
        ]
        for code in transient {
            XCTAssertTrue(
                HuggingFaceSnapshotDownloader.isTransientDownloadError(URLError(code)),
                "\(code) should be considered transient"
            )
        }
        let nonTransient: [URLError.Code] = [
            .cancelled, .badURL, .unsupportedURL, .badServerResponse,
            .userAuthenticationRequired, .fileDoesNotExist
        ]
        for code in nonTransient {
            XCTAssertFalse(
                HuggingFaceSnapshotDownloader.isTransientDownloadError(URLError(code)),
                "\(code) should NOT be considered transient"
            )
        }
    }

    func testExtractResumeDataReturnsNilWhenAbsent() {
        let e = URLError(.networkConnectionLost)
        XCTAssertNil(HuggingFaceSnapshotDownloader.extractResumeData(from: e))
    }

    func testExtractResumeDataReturnsBytesWhenPresent() {
        let blob = Data("captured-resume-state".utf8)
        let e = URLError(
            .networkConnectionLost,
            userInfo: [NSURLSessionDownloadTaskResumeData: blob]
        )
        XCTAssertEqual(HuggingFaceSnapshotDownloader.extractResumeData(from: e), blob)
    }

    func testHMACIdentityUsesSeparateDomainsAndSecretFileIs0600() throws {
        let dir = try tempDir()
        let secretURL = dir.appendingPathComponent("autotune-hmac-secret")
        let secret = try AutotuneHMACSecretStore(path: secretURL, randomBytes: { Data(repeating: 7, count: $0) }).loadOrCreate()
        let fingerprint = MachineFingerprint(ramGB: 64, chip: "Apple M4 Pro", osVersion: "macOS 15", binaryVersion: "test")
        let identity = HMACIdentity.derive(secret: secret, fingerprint: fingerprint)
        let upgraded = MachineFingerprint(ramGB: 64, chip: "Apple M4 Pro", osVersion: "macOS 15.1", binaryVersion: "next")
        let upgradedIdentity = HMACIdentity.derive(secret: secret, fingerprint: upgraded)
        let providerIdentity = HMACIdentity.derive(secret: secret, fingerprint: fingerprint, providerID: "provider-a")
        let providerUpgradeIdentity = HMACIdentity.derive(secret: secret, fingerprint: upgraded, providerID: "provider-a")
        let otherProviderIdentity = HMACIdentity.derive(secret: secret, fingerprint: fingerprint, providerID: "provider-b")
        let otherLocalIdentity = HMACIdentity.derive(secret: Data(repeating: 8, count: 32), fingerprint: fingerprint)

        XCTAssertNotEqual(identity.diversificationID, identity.cacheIdentityHash)
        XCTAssertEqual(identity.diversificationID, upgradedIdentity.diversificationID)
        XCTAssertEqual(identity.cacheIdentityHash, upgradedIdentity.cacheIdentityHash)
        XCTAssertEqual(providerIdentity.diversificationID, providerUpgradeIdentity.diversificationID)
        XCTAssertNotEqual(providerIdentity.diversificationID, otherProviderIdentity.diversificationID)
        XCTAssertNotEqual(identity.diversificationID, otherLocalIdentity.diversificationID)
        var st = stat()
        XCTAssertEqual(lstat(secretURL.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    // Locks the 2026-07-03 fix that removed the keychain code path from
    // AutotuneHMACSecretStore.loadOrCreate. Any future refactor that
    // reintroduces `SecItemCopyMatching` / `SecItemAdd` calls against the
    // legacy `live.streamvc.macprovider.autotune` service in this file
    // will fail this test. Keychain access is what caused every
    // auto-updated provider to see a "login keychain password" prompt on
    // interactive autotune runs after a version bump, because the ACL of
    // the keychain item is bound to the specific creating binary's
    // code-signature hash and auto-update replaces the binary.
    func testHMACSecretStoreDoesNotCallKeychainAPIs() {
        // Reflect the file bytes for any lingering keychain-service or
        // account literal so this test tracks the *source*, not just the
        // runtime behaviour. Fixed-string check keeps the invariant tight.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/macprovider-cli/AutotuneRecommend.swift")
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertFalse(source.contains("SecItemCopyMatching"), "AutotuneRecommend.swift must not call SecItemCopyMatching — see 2026-07-03 keychain-prompt fix")
        XCTAssertFalse(source.contains("SecItemAdd"), "AutotuneRecommend.swift must not call SecItemAdd — see 2026-07-03 keychain-prompt fix")
        // Note: the legacy service literal `live.streamvc.macprovider.autotune`
        // is intentionally allowed in comments (so operators can grep the
        // source for the name they need to delete via `security` CLI).
        // Only the runtime `kSecAttrService:` binding must not reappear.
        XCTAssertFalse(source.contains("kSecAttrService"), "AutotuneRecommend.swift must not bind kSecAttrService — see 2026-07-03 keychain-prompt fix")
    }

    func testHMACSecretFileRotatesRecoverableRegularFileFailuresAndRejectsSymlink() throws {
        let worldDir = try tempDir()
        let worldURL = worldDir.appendingPathComponent("secret")
        try Data(repeating: 1, count: 32).write(to: worldURL)
        XCTAssertEqual(chmod(worldURL.path, 0o644), 0)
        let worldSecret = try AutotuneHMACSecretStore(path: worldURL, randomBytes: { Data(repeating: 2, count: $0) }).loadOrCreate()
        XCTAssertEqual(worldSecret, Data(repeating: 2, count: 32))
        var st = stat()
        XCTAssertEqual(lstat(worldURL.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)

        let shortDir = try tempDir()
        let shortURL = shortDir.appendingPathComponent("secret")
        try Data(repeating: 1, count: 31).write(to: shortURL)
        XCTAssertEqual(chmod(shortURL.path, 0o600), 0)
        let shortSecret = try AutotuneHMACSecretStore(path: shortURL, randomBytes: { Data(repeating: 3, count: $0) }).loadOrCreate()
        XCTAssertEqual(shortSecret, Data(repeating: 3, count: 32))

        let symlinkDir = try tempDir()
        let target = symlinkDir.appendingPathComponent("target")
        let linkURL = symlinkDir.appendingPathComponent("secret")
        try Data(repeating: 1, count: 32).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        XCTAssertEqual(symlink("target", linkURL.path), 0)
        XCTAssertThrowsError(try AutotuneHMACSecretStore(path: linkURL).loadOrCreate())
    }

    func testModelArtifactHashRejectsSymlinkAndHardlink() throws {
        let symlinkDir = try tempDir()
        try Data("model".utf8).write(to: symlinkDir.appendingPathComponent("weights.bin"))
        XCTAssertEqual(symlink("weights.bin", symlinkDir.appendingPathComponent("link.bin").path), 0)
        XCTAssertThrowsError(try ModelArtifactVerifier.canonicalArtifactHash(directory: symlinkDir))

        let hardlinkDir = try tempDir()
        let original = hardlinkDir.appendingPathComponent("weights.bin")
        let hardlink = hardlinkDir.appendingPathComponent("weights-copy.bin")
        try Data("model".utf8).write(to: original)
        guard link(original.path, hardlink.path) == 0 else {
            throw XCTSkip("hardlinks are unavailable on this filesystem")
        }
        XCTAssertThrowsError(try ModelArtifactVerifier.canonicalArtifactHash(directory: hardlinkDir))
    }

    func testModelArtifactHashIsDeterministicForSameFiles() throws {
        let first = try tempDir()
        let second = try tempDir()
        try Data("a".utf8).write(to: first.appendingPathComponent("a.bin"))
        try Data("b".utf8).write(to: first.appendingPathComponent("b.bin"))
        try Data("b".utf8).write(to: second.appendingPathComponent("b.bin"))
        try Data("a".utf8).write(to: second.appendingPathComponent("a.bin"))

        XCTAssertEqual(
            try ModelArtifactVerifier.canonicalArtifactHash(directory: first),
            try ModelArtifactVerifier.canonicalArtifactHash(directory: second)
        )
    }

    func testModelArtifactHashIncludesHiddenFiles() throws {
        let dir = try tempDir()
        try Data("visible".utf8).write(to: dir.appendingPathComponent("weights.bin"))
        let withoutHidden = try ModelArtifactVerifier.canonicalArtifactHash(directory: dir)
        try Data("hidden".utf8).write(to: dir.appendingPathComponent(".weights.index"))

        XCTAssertNotEqual(withoutHidden, try ModelArtifactVerifier.canonicalArtifactHash(directory: dir))
    }

    func testCachedArtifactResolverRequiresExactRevisionAndHash() throws {
        let hub = try tempDir()
        let revision = String(repeating: "a", count: 40)
        let snapshot = hub
            .appendingPathComponent("models--namespace--model", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        let row = CandidateCatalog.Row(
            modelID: "namespace/model",
            modelRevision: revision,
            modelSHA256: expected,
            minRAMGB: 1,
            minBandwidthTier: .c,
            benchGate: CandidateCatalog.BenchGate(minSustainedTPS: 1, max4KTTFTMS: 1_000),
            runtimeStatus: "recommendable",
            notes: nil
        )

        let verified = try CachedModelArtifactResolver(hubRoot: hub).verifiedExistingArtifact(for: row)

        XCTAssertEqual(verified.sha256, expected)
        XCTAssertEqual(verified.modelArgument, snapshot.path)

        var mismatch = row
        mismatch.modelSHA256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try CachedModelArtifactResolver(hubRoot: hub).verifiedExistingArtifact(for: mismatch))
    }

    func testBenchmarksDiagnosesRowsSkippedByArtifactHashMismatch() async throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        let row = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        let revision = try XCTUnwrap(row.modelRevision)
        let hub = try tempDir()
        let snapshot = hub
            .appendingPathComponent("models--mlx-community--Qwen3-Coder-30B-A3B-Instruct-4bit", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))
        request.benchmarks = [:]
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: CachedModelArtifactResolver(hubRoot: hub),
            runnerFactory: { throw AutotuneRecommendError.invalidStaticJSON("runner should not start") }
        )

        let outcomes = try await benchmarker.benchmarks(
            request: request,
            targetContext: 4_000,
            gateTTFTMS: 3_000,
            replicates: 1,
            port: 18080
        )

        XCTAssertNil(outcomes.benchmarks[modelKey])
        let diagnostic = try XCTUnwrap(outcomes.diagnostics[modelKey])
        XCTAssertTrue(diagnostic.contains("hash mismatch"))
    }

    func testBenchmarkRecommendContinuesWhenUnrelatedRowHasArtifactMismatch() async throws {
        let badKey = "meta-llama/llama-3.1-8b-instruct"
        let goodKey = "qwen3-coder-30b-a3b-instruct"
        var request = try makeRequest(modelKey: goodKey)
        let badRow = try XCTUnwrap(
            try AutotuneStaticInputs.decodeCandidateCatalog(
                Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
            ).rows[badKey]
        )
        request.candidateCatalog.rows[badKey] = badRow
        request.demandRank.rows[badKey] = try XCTUnwrap(
            try AutotuneStaticInputs.decodeDemandRank(
                Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)
            ).rows[badKey]
        )
        request.rateCard.rows[badKey] = try XCTUnwrap(
            try AutotuneStaticInputs.decodeRateCard(
                Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)
            ).rows[badKey]
        )
        request.benchmarks = [:]

        let hub = try tempDir()
        let badRevision = try XCTUnwrap(badRow.modelRevision)
        let badSnapshot = hub
            .appendingPathComponent("models--mlx-community--Meta-Llama-3.1-8B-Instruct-4bit", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(badRevision, isDirectory: true)
        try FileManager.default.createDirectory(at: badSnapshot, withIntermediateDirectories: true)
        try Data("stale-llama".utf8).write(to: badSnapshot.appendingPathComponent("weights.bin"))

        let goodRow = try XCTUnwrap(request.candidateCatalog.rows[goodKey])
        let goodRevision = try XCTUnwrap(goodRow.modelRevision)
        let goodSnapshot = hub
            .appendingPathComponent("models--mlx-community--Qwen3-Coder-30B-A3B-Instruct-4bit", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(goodRevision, isDirectory: true)
        try FileManager.default.createDirectory(at: goodSnapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: goodSnapshot.appendingPathComponent("weights.bin"))
        request.candidateCatalog.rows[goodKey]?.modelSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: goodSnapshot)
        let goodArtifactPath = goodSnapshot.path

        let prober = RecordingStage1Prober(results: [
            goodArtifactPath: .feasible(medianTPS: 88, p95TTFTMS: 900)
        ])
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: CachedModelArtifactResolver(hubRoot: hub),
            runnerFactory: { try CandidateProviderRunner(providerBinaryPath: "/bin/true") },
            prober: prober,
            safetySampler: StaticProbeSafetySampler(),
            clock: { Self.date("2026-07-02T00:00:00Z") }
        )

        let outcomes = try await benchmarker.benchmarks(
            request: request,
            targetContext: 4_000,
            gateTTFTMS: 3_000,
            replicates: 1,
            port: 18080
        )

        XCTAssertNil(outcomes.benchmarks[badKey])
        XCTAssertTrue(try XCTUnwrap(outcomes.diagnostics[badKey]).contains("hash mismatch"))
        XCTAssertNotNil(outcomes.benchmarks[goodKey])
        XCTAssertEqual(prober.probedModels, [goodArtifactPath])
    }

    func testBenchmarksScopesToCandidateModelsWhenFilterProvided() async throws {
        let goodKey = "qwen3-coder-30b-a3b-instruct"
        let skippedKey = "meta-llama/llama-3.1-8b-instruct"
        var request = try makeRequest(modelKey: goodKey)
        let skippedRow = try XCTUnwrap(
            try AutotuneStaticInputs.decodeCandidateCatalog(
                Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
            ).rows[skippedKey]
        )
        request.candidateCatalog.rows[skippedKey] = skippedRow
        request.benchmarks = [:]

        let goodRow = try XCTUnwrap(request.candidateCatalog.rows[goodKey])
        let revision = try XCTUnwrap(goodRow.modelRevision)
        let hub = try tempDir()
        let snapshot = hub
            .appendingPathComponent("models--mlx-community--Qwen3-Coder-30B-A3B-Instruct-4bit", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))
        request.candidateCatalog.rows[goodKey]?.modelSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        let artifactPath = snapshot.path

        let prober = RecordingStage1Prober(results: [
            artifactPath: .feasible(medianTPS: 88, p95TTFTMS: 900)
        ])
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: CachedModelArtifactResolver(hubRoot: hub),
            runnerFactory: { try CandidateProviderRunner(providerBinaryPath: "/bin/true") },
            prober: prober,
            safetySampler: StaticProbeSafetySampler()
        )

        let outcomes = try await benchmarker.benchmarks(
            request: request,
            targetContext: 4_000,
            gateTTFTMS: 3_000,
            replicates: 1,
            port: 18080,
            candidateModelIDs: Set([goodRow.modelID])
        )

        XCTAssertNotNil(outcomes.benchmarks[goodKey])
        XCTAssertNil(outcomes.benchmarks[skippedKey])
        XCTAssertNil(outcomes.diagnostics[skippedKey])
        XCTAssertEqual(prober.probedModels, [artifactPath])
    }

    func testBenchmarkingRethrowsUnexpectedRunnerFailures() async throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        let row = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        let revision = try XCTUnwrap(row.modelRevision)
        let hub = try tempDir()
        let snapshot = hub
            .appendingPathComponent("models--mlx-community--Qwen3-Coder-30B-A3B-Instruct-4bit", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))
        request.candidateCatalog.rows[modelKey]?.modelSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        request.benchmarks = [:]
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: CachedModelArtifactResolver(hubRoot: hub),
            runnerFactory: { throw AutotuneRecommendError.invalidStaticJSON("runner failed") }
        )

        do {
            _ = try await benchmarker.benchmarks(
                request: request,
                targetContext: 4_000,
                gateTTFTMS: 3_000,
                replicates: 1,
                port: 18080
            )
            XCTFail("unexpected benchmark infrastructure errors must fail closed")
        } catch AutotuneRecommendError.invalidStaticJSON(let message) {
            XCTAssertEqual(message, "runner failed")
        }
    }

    func testBenchmarkingIncludesListedDonorCompatibleRowsBeforeDonorMode() async throws {
        let modelKey = "qwen3-32b"
        var request = try makeRequest(modelKey: modelKey)
        request.donorMode = false
        request.hardware.bandwidthTier = .a
        request.demandRank.rows[modelKey]?.recommendable = false
        request.candidateCatalog.rows[modelKey]?.runtimeStatus = "listed"
        let row = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        let revision = try XCTUnwrap(row.modelRevision)
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let snapshot = resolver.snapshotURL(modelID: row.modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))
        request.candidateCatalog.rows[modelKey]?.modelSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        request.benchmarks = [:]
        let prober = RecordingStage1Prober(results: [
            snapshot.path: .feasible(medianTPS: 12, p95TTFTMS: 900),
        ])
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: resolver,
            runnerFactory: { try CandidateProviderRunner(providerBinaryPath: "/bin/true") },
            prober: prober,
            safetySampler: StaticProbeSafetySampler()
        )

        let outcomes = try await benchmarker.benchmarks(
            request: request,
            targetContext: 4_000,
            gateTTFTMS: 3_000,
            replicates: 1,
            port: 18080
        )

        XCTAssertNotNil(outcomes.benchmarks[modelKey])
        XCTAssertEqual(prober.probedModels, [snapshot.path])
    }

    func testProbeSafetyAssessmentFailsClosedOnUnavailableTelemetry() {
        let unavailable = ProbeSafetyAssessment.assess(
            before: ProbeSafetySample(pageouts: nil, thermalState: nil),
            after: ProbeSafetySample(pageouts: nil, thermalState: nil)
        )
        XCTAssertTrue(unavailable.swapDetected)
        XCTAssertTrue(unavailable.thermalThrottleDetected)

        let safe = ProbeSafetyAssessment.assess(
            before: ProbeSafetySample(pageouts: 10, thermalState: .nominal),
            after: ProbeSafetySample(pageouts: 10, thermalState: .fair)
        )
        XCTAssertFalse(safe.swapDetected)
        XCTAssertFalse(safe.thermalThrottleDetected)

        let unsafe = ProbeSafetyAssessment.assess(
            before: ProbeSafetySample(pageouts: 10, thermalState: .nominal),
            after: ProbeSafetySample(pageouts: 11, thermalState: .serious)
        )
        XCTAssertTrue(unsafe.swapDetected)
        XCTAssertTrue(unsafe.thermalThrottleDetected)
    }

    func testBothMarketFallbacksProduceLowConfidence() throws {
        var request = try makeRequest()
        request.warnings = [.rateCardFallbackUsed, .demandRankFallbackUsed]

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.candidates.first?.confidence, "low")
    }

    func testStaleMarketInputsProduceLowConfidence() throws {
        var request = try makeRequest()
        request.warnings = [.candidateCatalogStale]

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.candidates.first?.confidence, "low")
    }

    func testStatusStaleHelperComparesStoredAndCurrentState() async throws {
        let dir = try tempDir()
        let secretURL = dir.appendingPathComponent("secret")
        try Data(repeating: 9, count: 32).write(to: secretURL)
        XCTAssertEqual(chmod(secretURL.path, 0o600), 0)
        let stateURL = dir.appendingPathComponent("last-recommendation.json")
        try Data("""
        {"generated_at":"2026-07-01T00:00:00Z","rate_card_version":"old","demand_rank_version":"published-2026-07-07-p1-gemma","candidate_catalog_version":"published-2026-07-07-p1-gemma","candidate_catalog_sha256":"old","benchmark_id":"bench-1","benchmark_generated_at":"2026-07-01T00:00:00Z","binary_version":"test","hardware_identity_hash":"old","recommended_model":"qwen3-coder-30b-a3b-instruct"}
        """.utf8).write(to: stateURL)
        let staticInputs = AutotuneStaticInputs(
            fetch: { _ in throw AutotuneRecommendError.invalidStaticJSON("offline") },
            now: { Self.date("2026-07-02T00:00:00Z") }
        )
        let fingerprint = MachineFingerprint(ramGB: 64, chip: "Apple M4 Pro", osVersion: "macOS 15", binaryVersion: "test")

        let staleSince = await StatusCommand.staleRecommendationSince(
            staticInputs: staticInputs,
            fingerprint: fingerprint,
            hmacSecretURL: secretURL,
            stateURL: stateURL,
            now: Self.date("2026-07-02T00:00:00Z")
        )

        XCTAssertEqual(staleSince, Optional(Self.date("2026-07-01T00:00:00Z")))
    }

    func testStatusStaleHelperMarksStoredStateStaleWhenSecretCannotBeReused() async throws {
        let dir = try tempDir()
        let secretURL = dir.appendingPathComponent("secret")
        try Data(repeating: 9, count: 32).write(to: secretURL)
        XCTAssertEqual(chmod(secretURL.path, 0o644), 0)
        let stateURL = dir.appendingPathComponent("last-recommendation.json")
        try Data("""
        {"generated_at":"2026-07-01T00:00:00Z","rate_card_version":"baked-2026-07-03","demand_rank_version":"published-2026-07-07-p1-gemma","candidate_catalog_version":"published-2026-07-07-p1-gemma","candidate_catalog_sha256":"old","benchmark_id":"bench-1","benchmark_generated_at":"2026-07-01T00:00:00Z","binary_version":"test","hardware_identity_hash":"old","recommended_model":"qwen3-coder-30b-a3b-instruct"}
        """.utf8).write(to: stateURL)
        let staticInputs = AutotuneStaticInputs(
            fetch: { _ in throw AutotuneRecommendError.invalidStaticJSON("offline") },
            now: { Self.date("2026-07-02T00:00:00Z") }
        )
        let fingerprint = MachineFingerprint(ramGB: 64, chip: "Apple M4 Pro", osVersion: "macOS 15", binaryVersion: "test")

        let staleSince = await StatusCommand.staleRecommendationSince(
            staticInputs: staticInputs,
            fingerprint: fingerprint,
            hmacSecretURL: secretURL,
            stateURL: stateURL,
            now: Self.date("2026-07-02T00:00:00Z")
        )

        XCTAssertEqual(staleSince, Optional(Self.date("2026-07-01T00:00:00Z")))
    }

    func testStatusFreshnessUsesConfiguredProviderIDIdentity() async throws {
        let dir = try tempDir()
        let secretURL = dir.appendingPathComponent("secret")
        let secret = Data(repeating: 9, count: 32)
        try secret.write(to: secretURL)
        XCTAssertEqual(chmod(secretURL.path, 0o600), 0)
        let stateURL = dir.appendingPathComponent("last-recommendation.json")
        let staticInputs = AutotuneStaticInputs(
            fetch: { _ in throw AutotuneRecommendError.invalidStaticJSON("offline") },
            now: { Self.date("2026-07-02T00:00:00Z") }
        )
        let fingerprint = MachineFingerprint(ramGB: 64, chip: "Apple M4 Pro", osVersion: "macOS 15", binaryVersion: "test")
        let catalogSHA = AutotuneStaticInputs.candidateCatalogSHA256(bytes: Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        let identity = HMACIdentity.derive(secret: secret, fingerprint: fingerprint, providerID: "provider-a")
        try Data("""
        {"generated_at":"2026-07-02T00:00:00Z","rate_card_version":"baked-2026-07-07-p2-drift","demand_rank_version":"published-2026-07-07-p1-gemma","candidate_catalog_version":"published-2026-07-07-p1-gemma","candidate_catalog_sha256":"\(catalogSHA)","benchmark_id":"bench-1","benchmark_generated_at":"2026-07-02T00:00:00Z","binary_version":"test","hardware_identity_hash":"\(identity.cacheIdentityHash)","recommended_model":"qwen3-coder-30b-a3b-instruct"}
        """.utf8).write(to: stateURL)

        let staleSince = await StatusCommand.staleRecommendationSince(
            staticInputs: staticInputs,
            fingerprint: fingerprint,
            providerID: "provider-a",
            hmacSecretURL: secretURL,
            stateURL: stateURL,
            now: Self.date("2026-07-02T00:00:00Z")
        )
        let staleWithDifferentProvider = await StatusCommand.staleRecommendationSince(
            staticInputs: staticInputs,
            fingerprint: fingerprint,
            providerID: "provider-b",
            hmacSecretURL: secretURL,
            stateURL: stateURL,
            now: Self.date("2026-07-02T00:00:00Z")
        )

        XCTAssertNil(staleSince)
        XCTAssertEqual(staleWithDifferentProvider, Optional(Self.date("2026-07-02T00:00:00Z")))
    }

    // MARK: - Default-tier fallthrough + swap tolerance (v1.7.6 Track A1/A2a)

    func testRecommendationEmitsRateCardDefaultTierWarningWhenSpecificRowMissing() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        // Drop the specific row so the engine has to fall through to "default".
        request.rateCard.rows.removeValue(forKey: modelKey)
        // Provide a default row so the fallthrough resolves.
        request.rateCard.rows["default"] = RateCardProjection.Row(
            promptRatePerMtok: 500_000,
            completionRatePerMtok: 1_000_000,
            providerShareBPS: 9_000,
            globalMultiplierPPM: 1_000_000
        )

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertTrue(result.warnings.contains(.rateCardDefaultTierUsed))
        // v1.7.6 Track A1 correction: the SERVED model is the catalog model
        // (what MLX will actually load), not the pricing key. Only the
        // rate-card row used for earnings math resolves to "default".
        XCTAssertEqual(result.recommendedModel, modelKey)
        XCTAssertEqual(result.selectedCandidate?.catalogKey, modelKey)
    }

    func testRecommendationNoDefaultTierWarningWhenSpecificRowPresent() throws {
        let result = AutotuneRecommendEngine().recommend(try makeRequest())
        XCTAssertFalse(result.warnings.contains(.rateCardDefaultTierUsed))
    }

    func testSwapDetectedNoLongerBlocksEligibilityButEmitsWarning() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        // Flip swap flag on the existing feasible benchmark fixture.
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        benchmark.swapDetected = true
        request.benchmarks[modelKey] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, modelKey, "v1.7.6 Track A2a: swap detected must not veto eligibility")
        XCTAssertTrue(result.warnings.contains(.swapObservedUnderLoad))
        XCTAssertFalse(result.warnings.contains(.noEligibleModel))
    }

    func testThermalThrottleStillHardBlocksEligibility() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        benchmark.thermalThrottleDetected = true
        request.benchmarks[modelKey] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel, "v1.7.6: thermal throttle stays a hard-block (TPS reading unreliable)")
        XCTAssertTrue(result.warnings.contains(.noEligibleModel))
    }

    func testDonorModeInheritsSwapRelaxation() throws {
        var request = try makeRequest(modelKey: "qwen3-32b")
        request.donorMode = true
        request.hardware.bandwidthTier = .a
        var benchmark = try XCTUnwrap(request.benchmarks["qwen3-32b"])
        benchmark.swapDetected = true
        request.benchmarks["qwen3-32b"] = benchmark

        XCTAssertTrue(AutotuneRecommendEngine.donorModeAdmitted(
            modelKey: "qwen3-32b",
            candidate: request.candidateCatalog.rows["qwen3-32b"],
            request: request
        ))
    }

    func testDonorModeStillRejectsThermalThrottle() throws {
        var request = try makeRequest(modelKey: "qwen3-32b")
        request.donorMode = true
        request.hardware.bandwidthTier = .a
        var benchmark = try XCTUnwrap(request.benchmarks["qwen3-32b"])
        benchmark.thermalThrottleDetected = true
        request.benchmarks["qwen3-32b"] = benchmark

        XCTAssertFalse(AutotuneRecommendEngine.donorModeAdmitted(
            modelKey: "qwen3-32b",
            candidate: request.candidateCatalog.rows["qwen3-32b"],
            request: request
        ))
    }

    // MARK: - v1.7.9 Track A5 (Option B) — soft TPS + TTFT gates

    func testTPSBelowGateNoLongerBlocksEligibilityButEmitsWarning() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        // Force TPS below the catalog gate (20 tok/s for qwen3-coder in
        // baked-2026-07-03; was 25 in baked-2026-07-02). Keep it high
        // enough that expected_net_usd_per_hour still clears the
        // $0.005/hr paid threshold.
        benchmark.sustainedTPS = 15
        request.benchmarks[modelKey] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, modelKey,
            "v1.7.9 Option B: TPS below catalog gate must not veto eligibility")
        XCTAssertTrue(result.warnings.contains(.tpsBelowGate))
        XCTAssertFalse(result.warnings.contains(.noEligibleModel))
    }

    func testTTFTAboveGateNoLongerBlocksEligibilityButEmitsWarning() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        // Force TTFT above the catalog ceiling (3000ms for qwen3-coder).
        benchmark.ttftMS = 6_000
        request.benchmarks[modelKey] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, modelKey,
            "v1.7.9 Option B: TTFT above catalog ceiling must not veto eligibility")
        XCTAssertTrue(result.warnings.contains(.ttftAboveGate))
    }

    func testNoTPSWarningWhenBenchmarkClearsGate() throws {
        let result = AutotuneRecommendEngine().recommend(try makeRequest())
        XCTAssertFalse(result.warnings.contains(.tpsBelowGate))
        XCTAssertFalse(result.warnings.contains(.ttftAboveGate))
    }

    func testDonorModeInheritsTPSAndTTFTRelaxation() throws {
        var request = try makeRequest(modelKey: "qwen3-32b")
        request.donorMode = true
        request.hardware.bandwidthTier = .a
        var benchmark = try XCTUnwrap(request.benchmarks["qwen3-32b"])
        // Below TPS gate + above TTFT ceiling for qwen3-32b.
        benchmark.sustainedTPS = 1
        benchmark.ttftMS = 100_000
        request.benchmarks["qwen3-32b"] = benchmark

        XCTAssertTrue(AutotuneRecommendEngine.donorModeAdmitted(
            modelKey: "qwen3-32b",
            candidate: request.candidateCatalog.rows["qwen3-32b"],
            request: request
        ))
    }

    // MARK: - Stage1 probe timeout + BenchmarkOutcomes diagnostics (v1.7.5)

    func testStage1ProberDefaultIdleTimeoutIsSafeForLargePrefill() {
        // Regression guard: v1.7.4 shipped with `TimeInterval(maxTokens)` = 64s,
        // which idle-timed-out on M-Base 30B-MoE + 3200-token probes before the
        // first byte arrived. Any value < 200s would re-introduce that bug.
        XCTAssertGreaterThanOrEqual(Stage1Prober.defaultProbeIdleTimeoutSec, 200)
    }

    func testStage1ProberClampsSubSecondTimeoutToOne() {
        // The `max(1, ...)` clamp guards the URLRequest contract (timeoutInterval
        // must be > 0). Cover the boundary explicitly.
        let clamped = Stage1Prober(probeIdleTimeoutSec: 0)
        // Cannot inspect private storage; instead assert Mirror shows the clamp.
        let mirror = Mirror(reflecting: clamped)
        let stored = mirror.children.first(where: { $0.label == "probeIdleTimeoutSec" })?.value as? TimeInterval
        XCTAssertEqual(stored, 1)
    }

    func testBenchmarksReturnsInfeasibleDiagnostics() async throws {
        let modelKey = "qwen3-32b"
        var request = try makeRequest(modelKey: modelKey)
        request.hardware.bandwidthTier = .a
        let row = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        let revision = try XCTUnwrap(row.modelRevision)
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let snapshot = resolver.snapshotURL(modelID: row.modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))
        request.candidateCatalog.rows[modelKey]?.modelSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        request.benchmarks = [:]
        let prober = RecordingStage1Prober(results: [
            snapshot.path: .infeasible(reason: "probe request failed: The request timed out.", nErr: 3),
        ])
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: resolver,
            runnerFactory: { try CandidateProviderRunner(providerBinaryPath: "/bin/true") },
            prober: prober,
            safetySampler: StaticProbeSafetySampler()
        )

        let outcomes = try await benchmarker.benchmarks(
            request: request,
            targetContext: 4_000,
            gateTTFTMS: 3_000,
            replicates: 3,
            port: 18080
        )

        XCTAssertNil(outcomes.benchmarks[modelKey])
        XCTAssertEqual(
            outcomes.diagnostics[modelKey],
            "probe request failed: The request timed out. (n_err=3)"
        )
    }

    func testBenchmarksDiagnosesRowsSkippedByRAMGate() async throws {
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var request = try makeRequest(modelKey: modelKey)
        request.hardware.memoryGB = 8   // < row.minRAMGB + safetyMarginGB
        request.benchmarks = [:]
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: CachedModelArtifactResolver(hubRoot: try tempDir()),
            runnerFactory: { throw AutotuneRecommendError.invalidStaticJSON("must not spawn runner for skipped row") },
            prober: RecordingStage1Prober(results: [:]),
            safetySampler: StaticProbeSafetySampler()
        )

        let outcomes = try await benchmarker.benchmarks(
            request: request,
            targetContext: 4_000,
            gateTTFTMS: 3_000,
            replicates: 1,
            port: 18080
        )

        XCTAssertNil(outcomes.benchmarks[modelKey])
        let diagnostic = try XCTUnwrap(outcomes.diagnostics[modelKey])
        XCTAssertTrue(diagnostic.contains("min_ram"))
        XCTAssertTrue(diagnostic.contains("safety margin"))
    }

    func testBenchmarksBreaksBetweenCandidatesWhenInterruptFlagIsSet() async throws {
        // ARCH-M-1 regression: once SIGTERM has arrived, the benchmarker must
        // stop spawning fresh CandidateProviderRunner subprocesses so the App
        // (or user) can tear down the autotune subtree cleanly. Pre-set the
        // flag; the loop should exit on its very first iteration, leaving
        // every model diagnosed as "interrupted before probe".
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var request = try makeRequest(modelKey: modelKey)
        request.benchmarks = [:]
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: CachedModelArtifactResolver(hubRoot: try tempDir()),
            runnerFactory: { throw AutotuneRecommendError.invalidStaticJSON("must not spawn runner after interrupt") },
            prober: RecordingStage1Prober(results: [:]),
            safetySampler: StaticProbeSafetySampler()
        )
        let flag = AutotuneInterruptFlag()
        flag.set()

        let outcomes = try await benchmarker.benchmarks(
            request: request,
            targetContext: 4_000,
            gateTTFTMS: 3_000,
            replicates: 1,
            port: 18080,
            interruptFlag: flag
        )

        XCTAssertTrue(outcomes.benchmarks.isEmpty)
        let diagnostic = try XCTUnwrap(outcomes.diagnostics[modelKey])
        XCTAssertEqual(diagnostic, "interrupted before probe")
    }

    func testAutotuneBecomeProcessGroupLeaderIsIdempotent() {
        // Calling `setpgid(0, 0)` when we already are the process-group
        // leader is a no-op on macOS (rc 0). This just verifies the helper
        // does not crash and returns Bool. Not a substitute for an
        // end-to-end signal-cascade test — those live in the App-side
        // subprocess integration tests — but pins the helper's contract.
        _ = autotuneBecomeProcessGroupLeader()
    }

    func testAutotuneCascadeGateTripsExactlyOnce() {
        // R2 CODE-R2-M-1 / ARCH-R2-M-1 regression: the cascade must fire once
        // per AutotuneSignalSources instance, not once per signal event. Without
        // this gate, `killpg(0, SIGTERM)` from the SIGTERM handler re-enters
        // the same handler, storming SIGTERMs until process death.
        let gate = AutotuneCascadeGate()
        XCTAssertFalse(gate.hasTripped())
        XCTAssertTrue(gate.trip(), "first trip must return true")
        XCTAssertTrue(gate.hasTripped())
        XCTAssertFalse(gate.trip(), "second trip must return false")
        XCTAssertFalse(gate.trip(), "third trip must return false")
        XCTAssertTrue(gate.hasTripped())
    }

    func testAutotuneCascadeGateIsThreadSafeUnderContention() {
        // Under signal-storm contention (multiple dispatch source events
        // firing on the signal queue concurrently), exactly one caller must
        // observe `trip() == true`. NSLock guarantees this; test pins it.
        let gate = AutotuneCascadeGate()
        let group = DispatchGroup()
        let lock = NSLock()
        var trueCount = 0
        for _ in 0..<64 {
            group.enter()
            DispatchQueue.global().async {
                let outcome = gate.trip()
                lock.lock()
                if outcome { trueCount += 1 }
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(trueCount, 1, "exactly one concurrent trip() call must win")
    }

    func testBenchmarksDiagnosesRowsSkippedByBandwidthGate() async throws {
        let modelKey = "qwen3-32b"
        var request = try makeRequest(modelKey: modelKey)
        request.hardware.bandwidthTier = .c  // qwen3-32b needs >= B
        request.benchmarks = [:]
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: CachedModelArtifactResolver(hubRoot: try tempDir()),
            runnerFactory: { throw AutotuneRecommendError.invalidStaticJSON("must not spawn runner") },
            prober: RecordingStage1Prober(results: [:]),
            safetySampler: StaticProbeSafetySampler()
        )

        let outcomes = try await benchmarker.benchmarks(
            request: request,
            targetContext: 4_000,
            gateTTFTMS: 3_000,
            replicates: 1,
            port: 18080
        )

        XCTAssertNil(outcomes.benchmarks[modelKey])
        let diagnostic = try XCTUnwrap(outcomes.diagnostics[modelKey])
        XCTAssertTrue(diagnostic.contains("bandwidth tier"))
        XCTAssertTrue(diagnostic.contains("below minimum"))
    }

    func testStoredStateJSONIncludesProbeDiagnostics() throws {
        var result = AutotuneRecommendEngine().recommend(try makeRequest())
        result.probeDiagnostics = [
            "qwen3-32b": "bandwidth tier C below minimum B",
            "gpt-oss-20b": "probe request failed: The request timed out. (n_err=1)",
        ]
        let stored = result.storedStateJSON()
        XCTAssertTrue(stored.contains(#""probe_diagnostics":{"#))
        XCTAssertTrue(stored.contains(#""gpt-oss-20b":"probe request failed: The request timed out. (n_err=1)""#))
        XCTAssertTrue(stored.contains(#""qwen3-32b":"bandwidth tier C below minimum B""#))
        // Deterministic ordering: keys sorted lexicographically.
        let gptIdx = try XCTUnwrap(stored.range(of: #""gpt-oss-20b""#))
        let qwenIdx = try XCTUnwrap(stored.range(of: #""qwen3-32b""#))
        XCTAssertLessThan(gptIdx.lowerBound, qwenIdx.lowerBound)
    }

    func testStoredStateJSONEmitsEmptyDiagnosticsObjectWhenNone() throws {
        let result = AutotuneRecommendEngine().recommend(try makeRequest())
        // Default probeDiagnostics is [:] — JSON must still be valid.
        let stored = result.storedStateJSON()
        XCTAssertTrue(stored.contains(#""probe_diagnostics":{}"#))
        let data = try XCTUnwrap(stored.data(using: .utf8))
        _ = try JSONSerialization.jsonObject(with: data)  // round-trip parse must not throw
    }

    func testLastRecommendationStateDecodesProbeDiagnostics() throws {
        let json = """
        {"generated_at":"2026-07-02T18:00:00Z","rate_card_version":"v1","demand_rank_version":"v1","candidate_catalog_version":"v1","candidate_catalog_sha256":"abc","benchmark_id":null,"benchmark_generated_at":null,"binary_version":"1.7.5","hardware_identity_hash":"hw","recommended_model":null,"probe_diagnostics":{"qwen3-32b":"tier below minimum"}}
        """
        let decoded = try JSONDecoder().decode(LastRecommendationState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.probeDiagnostics, ["qwen3-32b": "tier below minimum"])
    }

    func testLastRecommendationStateDecodesOldJSONWithoutProbeDiagnostics() throws {
        // Backwards-compat: pre-v1.7.5 last-recommendation.json files must still decode.
        let json = """
        {"generated_at":"2026-07-02T18:00:00Z","rate_card_version":"v1","demand_rank_version":"v1","candidate_catalog_version":"v1","candidate_catalog_sha256":"abc","benchmark_id":null,"benchmark_generated_at":null,"binary_version":"1.7.4","hardware_identity_hash":"hw","recommended_model":null}
        """
        let decoded = try JSONDecoder().decode(LastRecommendationState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.probeDiagnostics, [String: String]())
    }

    // MARK: - v4 pivot: per-token payout

    func testRecommendReturnsHighestScoringEligibleRow() throws {
        let request = try makeRequest()
        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNotNil(result.recommendedModel)
        let top = try XCTUnwrap(result.candidates.first)
        XCTAssertTrue(top.eligible)
        XCTAssertGreaterThan(top.rawScore, 0)
        XCTAssertEqual(top.model, result.recommendedModel)
        for other in result.candidates.dropFirst() where other.eligible {
            XCTAssertGreaterThanOrEqual(top.rawScore, other.rawScore)
        }
    }

    func testRecommendFallsToDonorWhenNoRowFitsRAM() throws {
        var request = try makeRequest()
        request.hardware.memoryGB = 4

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel)
        XCTAssertTrue(result.warnings.contains(.noEligibleModel))
        XCTAssertTrue(result.humanTranscript().contains("No catalog model currently fits this Mac"))
    }

    func testRecommendResultCarriesPerTokenRates() throws {
        let result = AutotuneRecommendEngine().recommend(try makeRequest())

        XCTAssertNotNil(result.promptRatePerMillionTokens)
        XCTAssertNotNil(result.completionRatePerMillionTokens)
        XCTAssertGreaterThan(try XCTUnwrap(result.promptRatePerMillionTokens), 0)
        XCTAssertGreaterThan(try XCTUnwrap(result.completionRatePerMillionTokens), 0)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertGreaterThan(candidate.promptRateUSDPerMillionTokens, 0)
        XCTAssertGreaterThan(candidate.completionRateUSDPerMillionTokens, 0)
        XCTAssertGreaterThan(candidate.rawScore, 0)
    }

    func testTranscriptRendersPerTokenRate() throws {
        let result = AutotuneRecommendEngine().recommend(try makeRequest())
        let transcript = result.humanTranscript()

        XCTAssertTrue(transcript.contains("per million prompt tokens"), transcript)
        XCTAssertTrue(transcript.contains("per million completion tokens"), transcript)
        XCTAssertFalse(transcript.contains("/hr"), transcript)
        XCTAssertFalse(transcript.contains("starter"), transcript)
    }

    private func makeRequest(modelKey: String = "qwen3-coder-30b-a3b-instruct") throws -> AutotuneRecommendRequest {
        var demand = try AutotuneStaticInputs.decodeDemandRank(Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8))
        var catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        var rateCard = try AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8))
        let normalizedModelKey = AutotuneModelKeyNormalizer.normalize(modelKey)
        demand.rows = demand.rows.filter { $0.key == modelKey }
        catalog.rows = catalog.rows.filter { $0.key == modelKey }
        rateCard.rows = rateCard.rows.filter { $0.key == modelKey || $0.key == normalizedModelKey }

        if modelKey == "google-gemma-4-26b-a4b-it" {
            catalog.rows[modelKey] = CandidateCatalog.Row(
                modelID: "mlx-community/gemma-4-26b-a4b-it-4bit",
                modelRevision: nil,
                modelSHA256: nil,
                minRAMGB: 32,
                minBandwidthTier: .c,
                benchGate: CandidateCatalog.BenchGate(minSustainedTPS: 30, max4KTTFTMS: 3000),
                runtimeStatus: "blocked",
                notes: "test fixture"
            )
            rateCard.rows[modelKey] = RateCardProjection.Row(
                promptRatePerMtok: 60_000,
                completionRatePerMtok: 120_000,
                providerShareBPS: 9_000,
                globalMultiplierPPM: 1_000_000
            )
        }

        let catalogSHA = AutotuneStaticInputs.candidateCatalogSHA256(bytes: Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        let generatedAt = Self.date("2026-07-02T00:00:00Z")
        let hardware = AutotuneRecommendHardware(
            machine: "Mac-test",
            chip: "Apple M4 Pro",
            memoryGB: 64,
            bandwidthTier: .c,
            osVersion: "macOS 15",
            binaryVersion: "test-bin",
            diversificationID: "diversification",
            hardwareIdentityHash: "hardware"
        )
        let candidate = try XCTUnwrap(catalog.rows[modelKey])
        let benchmark = CandidateBenchmark(
            modelKey: modelKey,
            sustainedTPS: 100,
            ttftMS: max(1, candidate.benchGate.max4KTTFTMS - 1),
            swapDetected: false,
            thermalThrottleDetected: false,
            artifactSHA256: candidate.modelSHA256 ?? String(repeating: "f", count: 64),
            modelArtifactPath: "/tmp/\(modelKey)",
            benchmarkID: "bench-\(modelKey)",
            generatedAt: generatedAt,
            candidateCatalogSHA256: catalogSHA,
            binaryVersion: hardware.binaryVersion,
            modelID: candidate.modelID,
            hardwareIdentityHash: hardware.hardwareIdentityHash
        )
        return AutotuneRecommendRequest(
            hardware: hardware,
            demandRank: demand,
            candidateCatalog: catalog,
            candidateCatalogSHA256: catalogSHA,
            rateCard: rateCard,
            benchmarks: [modelKey: benchmark],
            warnings: [],
            generatedAt: generatedAt,
            donorMode: false
        )
    }

    private static func hardware(
        chip: String,
        memoryGB: Int,
        bandwidthTier: BandwidthTier
    ) -> AutotuneRecommendHardware {
        AutotuneRecommendHardware(
            machine: "Mac-test",
            chip: chip,
            memoryGB: memoryGB,
            bandwidthTier: bandwidthTier,
            osVersion: "macOS 15",
            binaryVersion: "test-bin",
            diversificationID: "diversification",
            hardwareIdentityHash: "hardware"
        )
    }

    private static func date(_ raw: String) -> Date {
        ISO8601DateFormatter.autotuneInternet.date(from: raw)!
    }

    private static func sidecar(_ data: Data, hasKeyID keyID: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["key_id", "alg", "signature"])
        else {
            return false
        }
        return object["key_id"] as? String == keyID &&
            object["alg"] as? String == "ed25519" &&
            Data(base64Encoded: object["signature"] as? String ?? "") != nil
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-autotune-recommend-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }
}

private final class RecordingStage1Prober: Stage1Probing {
    private let results: [String: Stage1ProbeResult]
    private(set) var probedModels: [String] = []

    init(results: [String: Stage1ProbeResult]) {
        self.results = results
    }

    func probe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int
    ) async throws -> Stage1ProbeResult {
        probedModels.append(model)
        return results[model] ?? .infeasible(reason: "missing stub probe result", nErr: 1)
    }
}

private struct StaticProbeSafetySampler: ProbeSafetySampling {
    func sample() -> ProbeSafetySample {
        ProbeSafetySample(pageouts: 10, thermalState: .nominal)
    }
}
