import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class AutotuneRecommendTests: XCTestCase {
    private static var catalogTestdata: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("catalog/autotune/testdata", isDirectory: true)
    }

    func testCandidateCatalogSharedNestedSchemaCorpus() throws {
        XCTAssertNoThrow(try AutotuneStaticInputs.decodeCandidateCatalog(
            Data(contentsOf: Self.catalogTestdata.appendingPathComponent("valid-workload-profile.json"))
        ))
        for fixture in [
            "invalid-workload-profiles-type.json",
            "invalid-draft-candidates-type.json",
            "invalid-workload-no-winner-samples.json",
        ] {
            XCTAssertThrowsError(try AutotuneStaticInputs.decodeCandidateCatalog(
                Data(contentsOf: Self.catalogTestdata.appendingPathComponent(fixture))
            ), fixture)
        }
    }

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

    func testBakedLlama32CatalogUsesVerifiedPinnedSnapshotHash() throws {
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(
            Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        )
        let row = try XCTUnwrap(catalog.rows["meta-llama/llama-3.2-3b-instruct"])

        XCTAssertEqual(row.modelID, "mlx-community/Llama-3.2-3B-Instruct-4bit")
        XCTAssertEqual(row.modelRevision, "7f0dc925e0d0afb0322d96f9255cfddf2ba5636e")
        XCTAssertEqual(row.modelSHA256, "e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90")
        XCTAssertEqual(row.minRAMGB, 4)
        XCTAssertEqual(row.runtimeStatus, "recommendable")
    }

    func testOlderSignedCatalogFallsBackToCorrectedBakedCatalog() async throws {
        let staleFeed = AutotuneStaticInputs.bakedCandidateCatalogJSON
            .replacingOccurrences(of: "published-2026-07-10-llama32-hash-repair", with: "published-2026-07-07-p2-qwen3-8b")
            .replacingOccurrences(of: "2026-07-10T00:00:00Z", with: "2026-07-07T12:00:00Z")
            .replacingOccurrences(of: "e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90", with: "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a")
        let sidecar = Data(#"{"key_id":"streamvc-autotune-static-v4","alg":"ed25519","signature":"AA=="}"#.utf8)
        let inputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? sidecar : Data(staleFeed.utf8) },
            verifySignature: { _, _ in true },
            now: { Self.date("2026-07-10T10:00:00Z") }
        )

        let selection = await inputs.loadCandidateCatalog()
        let row = try XCTUnwrap(selection.value.rows["meta-llama/llama-3.2-3b-instruct"])

        XCTAssertTrue(selection.usedFallback)
        XCTAssertTrue(selection.warnings.contains(.candidateCatalogFallbackUsed))
        XCTAssertEqual(row.modelSHA256, "e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90")
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
        let rateCardBytes = try Data(contentsOf: staticDir.appendingPathComponent("rate-card.json"))
        let rateCardSigBytes = try Data(contentsOf: staticDir.appendingPathComponent("rate-card.json.sig"))
        let publicKeyFile = AutotuneStaticInputs.keyID == "streamvc-autotune-static-v4"
            ? "keys/autotune-static-v4.public.base64"
            : "keys/autotune-static-v5.public.base64"
        let publicKeyBytes = try Data(contentsOf: staticDir.appendingPathComponent(publicKeyFile))

        XCTAssertEqual(String(decoding: publicKeyBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), AutotuneStaticInputs.publicKeyBase64)
        XCTAssertTrue(Self.sidecar(demandSigBytes, hasKeyID: AutotuneStaticInputs.keyID))
        XCTAssertTrue(Self.sidecar(catalogSigBytes, hasKeyID: AutotuneStaticInputs.keyID))
        XCTAssertTrue(Self.sidecar(rateCardSigBytes, hasKeyID: AutotuneStaticInputs.keyID))
        XCTAssertTrue(AutotuneStaticInputs.defaultSignatureVerifier(jsonBytes: demandBytes, sidecarBytes: demandSigBytes))
        XCTAssertTrue(AutotuneStaticInputs.defaultSignatureVerifier(jsonBytes: catalogBytes, sidecarBytes: catalogSigBytes))
        XCTAssertTrue(AutotuneStaticInputs.defaultSignatureVerifier(jsonBytes: rateCardBytes, sidecarBytes: rateCardSigBytes))

        let demand = try AutotuneStaticInputs.decodeDemandRank(demandBytes)
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(catalogBytes)
        let rateCard = try AutotuneStaticInputs.decodeRateCard(rateCardBytes)

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
        XCTAssertEqual(rateMatch.row.promptRatePerMtok, 80_000)
        XCTAssertEqual(rateMatch.row.promptCacheHitRatePerMtok, 20_000)
        XCTAssertEqual(rateMatch.row.completionRatePerMtok, 160_000)
    }

    func testCandidateCatalogDecodesSpec029WorkloadProfiles() throws {
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(
            Data(Self.spec029CatalogJSON(workloadProfilesJSON: Self.validSpec029ProfilesJSON).utf8)
        )
        let row = try XCTUnwrap(catalog.rows["fixture-model"])
        let profiles = try XCTUnwrap(row.workloadProfiles)

        let code = try XCTUnwrap(profiles["code_completion"]?["16gb"])
        XCTAssertEqual(code.status, "winner")
        XCTAssertEqual(code.recommended?.kvBits, 4)
        XCTAssertEqual(code.recommended?.draftModelArtifactSHA256, String(repeating: "0", count: 64))
        XCTAssertEqual(code.recommended?.numDraftTokens, 4)
        XCTAssertEqual(code.profileMetrics.sampleCount, 20)
        XCTAssertEqual(code.source, "spec029-report-fixture")
        XCTAssertEqual(code.candidateSource, "research_fixture:spec029-test")

        let short = try XCTUnwrap(profiles["short_chat"]?["8gb"])
        XCTAssertEqual(short.recommended?.kvBits, 8)
        XCTAssertNil(short.recommended?.draftModel)

        let long = try XCTUnwrap(profiles["long_context"]?["16gb"])
        XCTAssertEqual(long.status, "no_winner")
        XCTAssertEqual(long.noWinnerReason, "insufficient_samples")
        XCTAssertNil(long.recommended)
        XCTAssertNil(long.profileMetrics.medianTPS)
        XCTAssertEqual(long.profileMetrics.sampleCount, 7)

        let staticProfiles = #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(candidateSource: "static_draft_candidates:fixture"))}}"#
        let staticCatalog = try AutotuneStaticInputs.decodeCandidateCatalog(
            Data(Self.spec029CatalogJSON(workloadProfilesJSON: staticProfiles, draftCandidatesJSON: Self.spec029DraftCandidatesJSON).utf8)
        )
        let staticProfile = try XCTUnwrap(staticCatalog.rows["fixture-model"]?.workloadProfiles?["code_completion"]?["16gb"])
        XCTAssertEqual(staticProfile.candidateSource, "static_draft_candidates:fixture")
    }

    func testCandidateCatalogRejectsInvalidSpec029WorkloadProfiles() throws {
        let invalidProfiles: [(String, String)] = [
            ("invalid tier", #"{"code_completion":{"24gb":\#(Self.spec029WinnerProfileJSON())}}"#),
            ("unknown workload", #"{"unknown_workload":{"16gb":\#(Self.spec029WinnerProfileJSON())}}"#),
            ("streaming probe published", #"{"streaming_check":{"16gb":\#(Self.spec029WinnerProfileJSON())}}"#),
            ("empty source", #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(source: ""))}}"#),
            ("generic draft candidate source", #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(candidateSource: "fixture"))}}"#),
            ("missing draft candidate source", #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(candidateSource: nil))}}"#),
            ("static draft missing catalog binding", #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(candidateSource: "static_draft_candidates:fixture"))}}"#),
            ("unknown no-winner reason", #"{"long_context":{"16gb":\#(Self.spec029NoWinnerProfileJSON(reason: "unknown"))}}"#),
            ("missing no-winner reason", #"{"long_context":{"16gb":{"status":"no_winner","gate_policy":{"min_samples":20,"max_p95_ttft_ms":60000,"max_stop_token_leak_rate":0,"min_median_tps":null},"profile_metrics":{"median_tps":null,"p95_ttft_ms":null,"stop_token_leak_rate":null,"spec_decode_acceptance_rate":null,"sample_count":7},"source":"fixture"}}}"#),
            ("no cells with sample count", #"{"long_context":{"16gb":\#(Self.spec029NoWinnerProfileJSON(reason: "no_cells_evaluated", sampleCount: 1))}}"#),
            ("insufficient samples with zero count", #"{"long_context":{"16gb":\#(Self.spec029NoWinnerProfileJSON(reason: "insufficient_samples", sampleCount: 0))}}"#),
            ("gate unmet below min samples", #"{"long_context":{"16gb":\#(Self.spec029NoWinnerProfileJSON(reason: "gate_unmet", sampleCount: 19))}}"#),
            ("no-winner with recommended", #"{"long_context":{"16gb":{"status":"no_winner","no_winner_reason":"insufficient_samples","recommended":{"kv_bits":4,"max_context_override":20000,"max_concurrency_override":1},"gate_policy":{"min_samples":20,"max_p95_ttft_ms":60000,"max_stop_token_leak_rate":0,"min_median_tps":null},"profile_metrics":{"median_tps":null,"p95_ttft_ms":null,"stop_token_leak_rate":null,"spec_decode_acceptance_rate":null,"sample_count":7},"source":"fixture"}}}"#),
            ("winner missing required metrics", #"{"code_completion":{"16gb":{"status":"winner","recommended":{"kv_bits":4,"max_context_override":20000,"max_concurrency_override":1},"gate_policy":{"min_samples":20,"max_p95_ttft_ms":12000,"max_stop_token_leak_rate":0,"min_median_tps":null},"profile_metrics":{"median_tps":8.5,"p95_ttft_ms":null,"stop_token_leak_rate":0,"spec_decode_acceptance_rate":null,"sample_count":20},"source":"fixture"}}}"#),
            ("winner p95 fails gate", #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(p95TTFTMS: 12_001))}}"#),
            ("winner leak fails gate", #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(stopTokenLeakRate: 0.01))}}"#),
            ("partial draft tuple", #"{"code_completion":{"16gb":{"status":"winner","recommended":{"kv_bits":4,"max_context_override":20000,"max_concurrency_override":1,"draft_model":"mlx-community/Fixture-Draft-4bit"},"gate_policy":{"min_samples":20,"max_p95_ttft_ms":12000,"max_stop_token_leak_rate":0,"min_median_tps":null},"profile_metrics":{"median_tps":8.5,"p95_ttft_ms":2400,"stop_token_leak_rate":0,"spec_decode_acceptance_rate":null,"sample_count":20},"source":"fixture","candidate_source":"research_fixture:spec029-test"}}}"#),
            ("invalid draft hash", #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(draftHash: "ABC"))}}"#),
            ("uppercase draft hash", #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(draftHash: String(repeating: "A", count: 64)))}}"#),
            ("invalid draft tokens", #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(numDraftTokens: 17))}}"#),
            ("draft context over cap", #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(maxContext: 50_000))}}"#),
            ("draft concurrency over cap", #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(maxConcurrency: 2))}}"#),
            ("non-default gate", #"{"code_completion":{"16gb":\#(Self.spec029WinnerProfileJSON(maxP95TTFTMS: 999_999))}}"#),
            ("omitted gate null", #"{"code_completion":{"16gb":{"status":"winner","recommended":{"kv_bits":4,"max_context_override":20000,"max_concurrency_override":1},"gate_policy":{"min_samples":20,"max_p95_ttft_ms":12000,"max_stop_token_leak_rate":0},"profile_metrics":{"median_tps":8.5,"p95_ttft_ms":2400,"stop_token_leak_rate":0,"spec_decode_acceptance_rate":null,"sample_count":20},"source":"fixture"}}}"#),
            ("omitted nullable metric", #"{"code_completion":{"16gb":{"status":"winner","recommended":{"kv_bits":4,"max_context_override":20000,"max_concurrency_override":1},"gate_policy":{"min_samples":20,"max_p95_ttft_ms":12000,"max_stop_token_leak_rate":0,"min_median_tps":null},"profile_metrics":{"p95_ttft_ms":2400,"stop_token_leak_rate":0,"spec_decode_acceptance_rate":null,"sample_count":20},"source":"fixture"}}}"#),
        ]

        for (label, profiles) in invalidProfiles {
            XCTAssertThrowsError(
                try AutotuneStaticInputs.decodeCandidateCatalog(Data(Self.spec029CatalogJSON(workloadProfilesJSON: profiles).utf8)),
                label
            )
        }

        XCTAssertThrowsError(
            try AutotuneStaticInputs.decodeCandidateCatalog(
                Data(Self.spec029CatalogJSON(workloadProfilesJSON: Self.validSpec029ProfilesJSON, rowExtraJSON: #""per_class":{}"#).utf8)
            ),
            "forbidden per_class alias"
        )
    }

    func testSpec029WorkloadProfilesDoNotChangeRecommendationSelection() throws {
        let baseline = try makeRequest()
        var profiled = baseline
        let fixture = try AutotuneStaticInputs.decodeCandidateCatalog(
            Data(Self.spec029CatalogJSON(workloadProfilesJSON: Self.validSpec029ProfilesJSON).utf8)
        )
        profiled.candidateCatalog.rows["qwen3-coder-30b-a3b-instruct"]?.workloadProfiles =
            fixture.rows["fixture-model"]?.workloadProfiles

        let engine = AutotuneRecommendEngine()
        let baselineResult = engine.recommend(baseline)
        let profiledResult = engine.recommend(profiled)

        XCTAssertEqual(profiled.candidateCatalog.rows["qwen3-coder-30b-a3b-instruct"]?.workloadProfiles?.isEmpty, false)
        XCTAssertEqual(profiledResult.recommendedModel, baselineResult.recommendedModel)
        XCTAssertEqual(profiledResult.candidates, baselineResult.candidates)
        XCTAssertEqual(profiledResult.warnings, baselineResult.warnings)
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

        // binaryVersion is the independently-versioned CLI marketing release
        // number, not a compatibility input — a version-only difference must
        // not discard otherwise-valid cached benchmark evidence (#612).
        var binaryVersionOnlyChange = baseline
        binaryVersionOnlyChange.binaryVersion = "other"
        XCTAssertTrue(AutotuneRecommendEngine.cachedBenchmarkAdmitted(binaryVersionOnlyChange, request: request, modelKey: modelKey))

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

    func testCachedBenchmarkAdmittedAcrossCLIVersionOnlyBump() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        let benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        XCTAssertEqual(benchmark.binaryVersion, request.hardware.binaryVersion)

        // Simulate a CLI update: the running binary's marketing version moves
        // forward while every compatibility input (catalog, model artifact,
        // hardware identity) stays the same as when the benchmark was recorded.
        request.hardware = AutotuneRecommendHardware(
            machine: request.hardware.machine,
            chip: request.hardware.chip,
            memoryGB: request.hardware.memoryGB,
            bandwidthTier: request.hardware.bandwidthTier,
            osVersion: request.hardware.osVersion,
            binaryVersion: "1.8.57",
            diversificationID: request.hardware.diversificationID,
            hardwareIdentityHash: request.hardware.hardwareIdentityHash
        )

        XCTAssertNotEqual(benchmark.binaryVersion, request.hardware.binaryVersion)
        XCTAssertTrue(AutotuneRecommendEngine.cachedBenchmarkAdmitted(benchmark, request: request, modelKey: modelKey))

        let result = AutotuneRecommendEngine().recommend(request)
        XCTAssertEqual(result.recommendedModel, modelKey)
    }

    func test8GBLlama32FeasibleFallbackSurvivesCLIVersionOnlyBump() throws {
        let modelKey = "meta-llama/llama-3.2-3b-instruct"
        var request = try makeRequest(modelKey: modelKey)
        request.hardware = AutotuneRecommendHardware(
            machine: request.hardware.machine,
            chip: "Apple M1",
            memoryGB: 8,
            bandwidthTier: request.hardware.bandwidthTier,
            osVersion: request.hardware.osVersion,
            binaryVersion: request.hardware.binaryVersion,
            diversificationID: request.hardware.diversificationID,
            hardwareIdentityHash: request.hardware.hardwareIdentityHash
        )
        // The cached benchmark was recorded under the pre-update CLI version.
        // Keep swap false: #742 makes swap a paid hard veto; this test isolates
        // CLI marketing-version independence of cached evidence admission.
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        benchmark.swapDetected = false
        request.benchmarks[modelKey] = benchmark

        // A CLI update alone advances the marketing version with every
        // compatibility input (catalog, model artifact, hardware) unchanged.
        request.hardware = AutotuneRecommendHardware(
            machine: request.hardware.machine,
            chip: request.hardware.chip,
            memoryGB: request.hardware.memoryGB,
            bandwidthTier: request.hardware.bandwidthTier,
            osVersion: request.hardware.osVersion,
            binaryVersion: "1.8.57",
            diversificationID: request.hardware.diversificationID,
            hardwareIdentityHash: request.hardware.hardwareIdentityHash
        )

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, modelKey)
        XCTAssertNotEqual(result.recommendedModel, "none")
        XCTAssertFalse(result.humanTranscript().contains("donor mode only"))
        XCTAssertFalse(result.warnings.contains(.swapObservedUnderLoad))
    }

    func testRowIdentityPreservesEvidenceAcrossUnrelatedCatalogChange() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        benchmark.candidateRowIdentity = try XCTUnwrap(request.candidateCatalog.rowIdentity(for: modelKey))
        benchmark.candidateCatalogSHA256 = "previous-release-digest"
        request.benchmarks[modelKey] = benchmark
        request.candidateCatalog.rows["qwen3-8b"]?.notes = "unrelated release note"

        XCTAssertTrue(AutotuneRecommendEngine.cachedBenchmarkAdmitted(benchmark, request: request, modelKey: modelKey))
    }

    func testRowIdentityRejectsChangedSelectedCatalogRow() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        benchmark.candidateRowIdentity = try XCTUnwrap(request.candidateCatalog.rowIdentity(for: modelKey))
        request.candidateCatalog.rows[modelKey]?.benchGate.minSustainedTPS += 1

        XCTAssertFalse(AutotuneRecommendEngine.cachedBenchmarkAdmitted(benchmark, request: request, modelKey: modelKey))
    }

    func testRowIdentityBindsCanonicalDraftAndWorkloadPolicy() throws {
        let raw = Self.policyIdentityCatalogJSON()
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(raw.utf8))
        let identity = try XCTUnwrap(catalog.rowIdentity(for: "fixture"))

        XCTAssertEqual(identity, "e6591bdf9f126f3b3013daf325e1cfbd33a8d5c08f35f785569b5ed1a46b1acf")

        let changedDraft = try AutotuneStaticInputs.decodeCandidateCatalog(Data(
            raw.replacingOccurrences(
                of: String(repeating: "0", count: 64),
                with: String(repeating: "1", count: 64)
            ).utf8
        ))
        let changedWorkload = try AutotuneStaticInputs.decodeCandidateCatalog(Data(
            raw.replacingOccurrences(of: "shared-schema-corpus", with: "changed-source").utf8
        ))
        let equivalentPolicy = try AutotuneStaticInputs.decodeCandidateCatalog(Data(
            raw.replacingOccurrences(
                of: "\"source\":\"shared-schema-corpus\"",
                with: "\"source\":\"shared-schema-corpus\",\"candidate_source\":null,\"ignored_nested\":true"
            ).utf8
        ))

        XCTAssertNotEqual(changedDraft.rowIdentity(for: "fixture"), identity)
        XCTAssertNotEqual(changedWorkload.rowIdentity(for: "fixture"), identity)
        XCTAssertEqual(equivalentPolicy.rowIdentity(for: "fixture"), identity)
    }

    func testRateCardUsesDefaultWhenSpecificRecommendationRowIsMissing() throws {
        let rateCard = RateCardProjection(
            version: "test",
            policyVersion: "autotune-policy-v1",
            generatedAt: Self.date("2026-07-01T00:00:00Z"),
            usdPerMillionCredits: 1.0,
            rows: ["default": RateCardProjection.Row(promptRatePerMtok: 1, completionRatePerMtok: 1, providerShareBPS: 9_000, globalMultiplierPPM: 1_000_000)]
        )

        XCTAssertEqual(rateCard.rowForRecommendation(modelKey: "qwen3-coder-30b-a3b-instruct")?.key, "default")
        XCTAssertEqual(rateCard.rowForRecommendation(modelKey: "meta-llama/llama-3.1-8b-instruct")?.key, "default")
        XCTAssertEqual(rateCard.rowForRecommendation(modelKey: "default")?.key, "default")
    }

    func testRateCardReturnsNilWhenNoDefaultAndNoMatch() throws {
        let rateCard = RateCardProjection(
            version: "test",
            policyVersion: "autotune-policy-v1",
            generatedAt: Self.date("2026-07-01T00:00:00Z"),
            usdPerMillionCredits: 1.0,
            rows: ["qwen3-32b": RateCardProjection.Row(promptRatePerMtok: 1, completionRatePerMtok: 1, providerShareBPS: 9_000, globalMultiplierPPM: 1_000_000)]
        )

        XCTAssertNil(rateCard.rowForRecommendation(modelKey: "unknown-model"))
    }

    func testRateCardPrefersSpecificRowOverDefault() throws {
        // v1.7.6 Track A1: exact/normalized specific row wins over "default".
        let rateCard = RateCardProjection(
            version: "test",
            policyVersion: "autotune-policy-v1",
            generatedAt: Self.date("2026-07-01T00:00:00Z"),
            usdPerMillionCredits: 1.0,
            rows: [
                "default": RateCardProjection.Row(promptRatePerMtok: 9, completionRatePerMtok: 9, providerShareBPS: 9_000, globalMultiplierPPM: 1_000_000),
                "qwen3-32b": RateCardProjection.Row(promptRatePerMtok: 1, completionRatePerMtok: 1, providerShareBPS: 9_000, globalMultiplierPPM: 1_000_000),
            ]
        )

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
        let rateCard = RateCardProjection(
            version: "test",
            policyVersion: "autotune-policy-v1",
            generatedAt: Self.date("2026-07-06T00:00:00Z"),
            usdPerMillionCredits: 1.0,
            rows: [
                "default": RateCardProjection.Row(promptRatePerMtok: 500_000, promptCacheHitRatePerMtok: 125_000, completionRatePerMtok: 1_000_000, providerShareBPS: 9_000, globalMultiplierPPM: 1_000_000),
                "nemotron-3-nano-30b-a3b": RateCardProjection.Row(promptRatePerMtok: 117_500, promptCacheHitRatePerMtok: 29_375, completionRatePerMtok: 235_000, providerShareBPS: 9_000, globalMultiplierPPM: 1_000_000),
            ]
        )

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

    func testExpectedEarningsScoreIncludesThroughputAndDemand() throws {
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
        highDemand.demandWeight = 1
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

        XCTAssertEqual(result.recommendedModel, highThroughputKey)
        XCTAssertGreaterThan(
            try XCTUnwrap(result.allCandidates.first { $0.model == highThroughputKey }?.rawScore),
            try XCTUnwrap(result.allCandidates.first { $0.model == highPayoutKey }?.rawScore)
        )
    }

    func testBuyerTTFTCeilingBlocksPaidRecommendationWithoutUsingCatalogGate() throws {
        var request = try makeRequest()
        request.buyerTTFTCeilingMS = 1_800
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        let catalogCeiling = try XCTUnwrap(request.candidateCatalog.rows[modelKey]).benchGate.max4KTTFTMS
        XCTAssertGreaterThan(catalogCeiling, request.buyerTTFTCeilingMS)
        benchmark.ttftMS = request.buyerTTFTCeilingMS + 1
        request.benchmarks[modelKey] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel)
        XCTAssertTrue(result.warnings.contains(.buyerTTFTCeilingExceeded))
        XCTAssertTrue(result.warnings.contains(.noEligibleModel))
        let scored = try XCTUnwrap(result.allCandidates.first { $0.catalogKey == modelKey })
        XCTAssertFalse(scored.eligible)
        XCTAssertTrue(scored.buyerTTFTCeilingExceeded)
        XCTAssertTrue(scored.why.contains("buyer TTFT ceiling"))
        XCTAssertFalse(result.warnings.contains(.ttftAboveGate))
    }

    func testBuyerTTFTCeilingStillBlocksPaidRecommendationInDonorMode() throws {
        var request = try makeRequest()
        request.donorMode = true
        request.buyerTTFTCeilingMS = 1_800
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        benchmark.ttftMS = request.buyerTTFTCeilingMS + 1
        request.benchmarks[modelKey] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel)
        XCTAssertTrue(result.warnings.contains(.buyerTTFTCeilingExceeded))
        XCTAssertTrue(result.warnings.contains(.noEligibleModel))
        XCTAssertEqual(result.donorFallbackModel, modelKey)
        let scored = try XCTUnwrap(result.allCandidates.first { $0.catalogKey == modelKey })
        XCTAssertFalse(scored.eligible)
        XCTAssertTrue(scored.buyerTTFTCeilingExceeded)
    }

    func testBuyerTTFTCeilingSelectsNextCleanPaidCandidate() throws {
        var request = try makeMultiCandidateRequest(modelKeys: [
            "qwen3-coder-30b-a3b-instruct",
            "openai/gpt-oss-20b",
        ])
        request.buyerTTFTCeilingMS = 1_800
        let blockedKey = "qwen3-coder-30b-a3b-instruct"
        var blocked = try XCTUnwrap(request.benchmarks[blockedKey])
        blocked.ttftMS = request.buyerTTFTCeilingMS + 1
        request.benchmarks[blockedKey] = blocked

        let fallbackKey = "openai/gpt-oss-20b"
        var fallback = try XCTUnwrap(request.benchmarks[blockedKey])
        let fallbackRow = try XCTUnwrap(request.candidateCatalog.rows[fallbackKey])
        fallback.modelKey = fallbackKey
        fallback.sustainedTPS = 40
        fallback.ttftMS = request.buyerTTFTCeilingMS
        fallback.artifactSHA256 = try XCTUnwrap(fallbackRow.modelSHA256)
        fallback.modelArtifactPath = "/tmp/\(fallbackKey)"
        fallback.modelID = fallbackRow.modelID
        request.benchmarks[fallbackKey] = fallback

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, fallbackKey)
        XCTAssertFalse(result.warnings.contains(.buyerTTFTCeilingExceeded))
        XCTAssertTrue(try XCTUnwrap(result.allCandidates.first { $0.catalogKey == blockedKey }).buyerTTFTCeilingExceeded)
        XCTAssertFalse(try XCTUnwrap(result.selectedCandidate).buyerTTFTCeilingExceeded)
    }

    func testRecommendationJSONCarriesBenchGateProvenanceAndDrift() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        request.candidateCatalog.rows[modelKey]?.benchGate.provenance = CandidateCatalog.BenchGate.Provenance(
            source: "measured_single_host",
            hardware: "M5 32GB",
            measuredAt: "2026-07-25",
            notes: "fixture"
        )
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        benchmark.sustainedTPS = 1
        request.benchmarks[modelKey] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.jsonString().utf8)) as? [String: Any])
        let candidate = try XCTUnwrap((root["candidates"] as? [[String: Any]])?.first)
        let provenance = try XCTUnwrap(candidate["bench_gate_provenance"] as? [String: Any])
        let drift = try XCTUnwrap(candidate["bench_gate_drift"] as? [String])

        XCTAssertEqual(provenance["source"] as? String, "measured_single_host")
        XCTAssertEqual(provenance["hardware"] as? String, "M5 32GB")
        XCTAssertEqual(provenance["measured_at"] as? String, "2026-07-25")
        XCTAssertEqual(drift, ["tps_below_gate"])
        XCTAssertEqual(candidate["confidence"] as? String, "low")
        XCTAssertEqual(candidate["buyer_ttft_ceiling_exceeded"] as? Bool, false)

        let transcript = result.humanTranscript()
        XCTAssertTrue(transcript.contains("Confidence: low"), transcript)
        XCTAssertTrue(transcript.contains("Bench gate provenance: source=measured_single_host, hardware=M5 32GB, measured_at=2026-07-25, notes=fixture"), transcript)
        XCTAssertTrue(transcript.contains("Bench gate drift: tps_below_gate"), transcript)
    }

    func testTranscriptSanitizesBenchGateProvenanceControlCharacters() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        request.candidateCatalog.rows[modelKey]?.benchGate.provenance = CandidateCatalog.BenchGate.Provenance(
            source: "measured_single_host",
            hardware: "M5\n32GB",
            measuredAt: "2026-07-25",
            notes: "fixture\n\u{001B}[31mforged-line"
        )

        let result = AutotuneRecommendEngine().recommend(request)
        let transcript = result.humanTranscript()

        XCTAssertTrue(transcript.contains("hardware=M5 32GB"), transcript)
        XCTAssertTrue(transcript.contains("notes=fixture [31mforged-line"), transcript)
        XCTAssertFalse(transcript.contains("hardware=M5\n32GB"), transcript)
        XCTAssertFalse(transcript.contains("notes=fixture\n"), transcript)
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

    func testSupplyDeficitMultiplierChangesExpectedEarningsScore() throws {
        var request = try makeRequest(modelKey: "qwen3-coder-30b-a3b-instruct")
        let baseline = try XCTUnwrap(AutotuneRecommendEngine().recommend(request).selectedCandidate?.rawScore)
        request.demandRank.rows["qwen3-coder-30b-a3b-instruct"]?.supplyDeficitMultiplier = 2
        let shortage = try XCTUnwrap(AutotuneRecommendEngine().recommend(request).selectedCandidate?.rawScore)

        XCTAssertEqual(shortage, baseline * 2, accuracy: 0.000001)
    }

    func testCatalogIntegrityWarningBlocksPaidRecommendation() throws {
        var request = try makeRequest(modelKey: "qwen3-coder-30b-a3b-instruct")
        request.warnings.insert(.candidateCatalogIntegrityFailure)

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel)
        XCTAssertTrue(result.allCandidates.allSatisfy { !$0.eligible })
    }

    func testPaidTrustBlockLeavesCatalogFallbackForLocalDiagnostics() {
        XCTAssertTrue(AutotuneRecommendEngine.paidTrustBlocks([.candidateCatalogIntegrityFailure]))
        XCTAssertTrue(AutotuneRecommendEngine.paidTrustBlocks([.demandRankUpdateRequired]))
        XCTAssertTrue(AutotuneRecommendEngine.paidTrustBlocks([.rateCardIntegrityFailure]))
        XCTAssertTrue(AutotuneRecommendEngine.paidTrustBlocks([.rateCardUpdateRequired]))
        XCTAssertFalse(AutotuneRecommendEngine.paidTrustBlocks([.candidateCatalogFallbackUsed, .rateCardFallbackUsed]))
        XCTAssertTrue(AutotuneRecommendEngine.networkSubmissionBlocks([.candidateCatalogFallbackUsed]))
        XCTAssertFalse(AutotuneRecommendEngine.networkSubmissionBlocks([.rateCardFallbackUsed, .candidateCatalogStale]))
        XCTAssertTrue(
            AutotuneRecommendEngine.shouldFailClosedBeforeBenchmarks(
                [.candidateCatalogFallbackUsed],
                apply: false,
                submitHardwareEvidence: true,
                requireHardwareEvidence: false
            )
        )
        XCTAssertFalse(
            AutotuneRecommendEngine.shouldFailClosedBeforeBenchmarks(
                [.candidateCatalogFallbackUsed],
                apply: false,
                submitHardwareEvidence: false,
                requireHardwareEvidence: false
            )
        )
    }

    func testCatalogFallbackBlocksNetworkSubmissionWithActionableMessage() throws {
        var request = try makeRequest(modelKey: "qwen3-coder-30b-a3b-instruct")
        request.warnings.insert(.candidateCatalogFallbackUsed)

        let result = AutotuneRecommendEngine().recommend(request)
        let message = AutotuneRecommendEngine.networkSubmissionBlockMessage([.candidateCatalogFallbackUsed])

        // Offline recommend diagnostics remain available; only network submit/apply fail closed.
        XCTAssertNotNil(result.recommendedModel)
        XCTAssertTrue(message.contains("signed live catalog unavailable"))
        XCTAssertTrue(message.contains("candidate_catalog_fallback_used"))
        XCTAssertTrue(message.contains("cannot be submitted"))
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
            .replacingOccurrences(of: "published-2026-07-29-inband-provenance-v1", with: "fetched-2026-08-10")
            .replacingOccurrences(of: "2026-07-29T08:45:00Z", with: "2026-08-10T00:00:00Z")
            .utf8)
        let signature = Data(repeating: 0, count: 64).base64EncodedString()
        let sidecar = Data("{\"key_id\":\"streamvc-autotune-static-v4\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
        let staleInputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? sidecar : validFetched },
            verifySignature: { _, _ in true },
            now: { Self.date("2026-08-25T00:00:00Z") }
        )

        let stale = await staleInputs.loadDemandRank()

        XCTAssertFalse(stale.usedFallback)
        XCTAssertEqual(stale.value.version, "fetched-2026-08-10")
        XCTAssertTrue(stale.warnings.contains(.demandRankStale))

        let fallbackInputs = AutotuneStaticInputs(
            fetch: { _ in validFetched },
            verifySignature: { _, _ in false },
            now: { Self.date("2026-08-25T00:00:00Z") }
        )
        let fallback = await fallbackInputs.loadDemandRank()
        XCTAssertTrue(fallback.usedFallback)
        XCTAssertTrue(fallback.warnings.contains(.demandRankFallbackUsed))
    }

    func testSignedRateCardAcceptsVerifiedLiveBytes() async throws {
        let payload = Data(AutotuneStaticInputs.bakedRateCardJSON
            .replacingOccurrences(of: "\"generated_at\":\"2026-07-29T08:45:00Z\"", with: "\"generated_at\":\"2026-07-29T09:00:00Z\"")
            .utf8)
        let privateKey = Curve25519.Signing.PrivateKey()
        let keyID = "streamvc-autotune-static-v4"
        let signature = try privateKey.signature(for: payload).base64EncodedString()
        let sidecar = Data("{\"key_id\":\"\(keyID)\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
        var keyring = AutotuneStaticInputs.defaultTrustedPublicKeys
        keyring[keyID] = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let inputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? sidecar : payload },
            trustedPublicKeys: keyring,
            now: { Self.date("2026-07-29T10:00:00Z") }
        )

        let selection = await inputs.loadRateCard()

        XCTAssertFalse(selection.usedFallback)
        XCTAssertEqual(selection.signerKeyID, keyID)
        XCTAssertFalse(selection.warnings.contains(.rateCardIntegrityFailure))
        XCTAssertEqual(selection.value.generatedAt, Self.date("2026-07-29T09:00:00Z"))
    }

    func testSignedRateCardMissingSidecarFallsBackWithIntegrityWarning() async throws {
        let payload = Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)
        let inputs = AutotuneStaticInputs(
            fetch: { url in
                if url.path.hasSuffix(".sig") { throw URLError(.fileDoesNotExist) }
                return payload
            },
            verifySignature: { _, _ in true },
            now: { Self.date("2026-07-29T10:00:00Z") }
        )

        let selection = await inputs.loadRateCard()

        XCTAssertTrue(selection.usedFallback)
        XCTAssertTrue(selection.warnings.contains(.rateCardFallbackUsed))
        XCTAssertTrue(selection.warnings.contains(.rateCardIntegrityFailure))
    }

    func testSignedRateCardRejectsUnknownSchemaField() async throws {
        let payload = Data(AutotuneStaticInputs.bakedRateCardJSON
            .replacingOccurrences(of: "\"rows\":{", with: "\"unexpected\":true,\"rows\":{")
            .utf8)
        let selection = await Self.loadSignedRateCardWithAcceptedSignature(payload)

        XCTAssertTrue(selection.usedFallback)
        XCTAssertTrue(selection.warnings.contains(.rateCardIntegrityFailure))
    }

    func testSignedRateCardRejectsWrongProjectionVersion() async throws {
        let payload = Data(AutotuneStaticInputs.bakedRateCardJSON
            .replacingOccurrences(
                of: #"\"version\":\"[0-9a-f]{64}\""#,
                with: "\"version\":\"\(String(repeating: "0", count: 64))\"",
                options: .regularExpression
            )
            .utf8)
        let selection = await Self.loadSignedRateCardWithAcceptedSignature(payload)

        XCTAssertTrue(selection.usedFallback)
        XCTAssertTrue(selection.warnings.contains(.rateCardIntegrityFailure))
    }

    func testRecommendationInputsRejectRateCardReleaseMismatch() async throws {
        let demandPayload = Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)
        let candidatePayload = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        let rateCardPayload = Data(AutotuneStaticInputs.bakedRateCardJSON
            .replacingOccurrences(of: "\"generated_at\":\"2026-07-29T08:45:00Z\"", with: "\"generated_at\":\"2026-07-29T09:00:00Z\"")
            .utf8)
        let sidecar = Data("{\"key_id\":\"streamvc-autotune-static-v4\",\"alg\":\"ed25519\",\"signature\":\"\(Data(repeating: 0, count: 64).base64EncodedString())\"}".utf8)
        let inputs = AutotuneStaticInputs(
            fetch: { url in
                if url.path.hasSuffix(".sig") { return sidecar }
                switch url.path {
                case _ where url.path.hasSuffix("/demand-rank"):
                    return demandPayload
                case _ where url.path.hasSuffix("/autotune-candidates"):
                    return candidatePayload
                case _ where url.path.hasSuffix("/rate-card"):
                    return rateCardPayload
                default:
                    throw URLError(.fileDoesNotExist)
                }
            },
            verifySignature: { _, _ in true },
            now: { Self.date("2026-07-29T10:00:00Z") }
        )

        let loaded = await inputs.loadRecommendationInputs()

        XCTAssertTrue(loaded.rateCard.warnings.contains(.rateCardIntegrityFailure))
        XCTAssertTrue(loaded.demand.warnings.contains(.demandRankIntegrityFailure))
        XCTAssertTrue(loaded.candidate.warnings.contains(.candidateCatalogIntegrityFailure))
    }

    func testSignedStaticRejectsSidecarWithExtraFields() async throws {
        let fetched = Data(AutotuneStaticInputs.bakedDemandRankJSON
            .replacingOccurrences(of: "published-2026-07-29-inband-provenance-v1", with: "fetched-2026-07-29")
            .replacingOccurrences(of: "2026-07-29T08:45:00Z", with: "2026-07-29T09:00:00Z")
            .utf8)
        let sidecar = Data(#"{"key_id":"streamvc-autotune-static-v4","alg":"ed25519","signature":"AA==","extra":true}"#.utf8)
        let inputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? sidecar : fetched },
            verifySignature: { _, _ in true },
            now: { Self.date("2026-07-26T17:00:00Z") }
        )

        let selection = await inputs.loadDemandRank()

        XCTAssertTrue(selection.usedFallback)
        XCTAssertTrue(selection.warnings.contains(.demandRankFallbackUsed))
    }

    func testSignedStaticRejectsDuplicateSidecarKeys() async throws {
        let payload = Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)
        let signature = Data(repeating: 0, count: 64).base64EncodedString()
        let sidecar = Data("{\"key_id\":\"streamvc-autotune-static-v4\",\"key_id\":\"streamvc-autotune-static-v4\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
        let inputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? sidecar : payload },
            verifySignature: { _, _ in true },
            now: { Self.date("2026-07-26T17:00:00Z") }
        )

        let selection = await inputs.loadDemandRank()

        XCTAssertTrue(selection.usedFallback)
        XCTAssertTrue(selection.warnings.contains(.demandRankIntegrityFailure))
    }

    func testDemandJSONSuccessWithMissingSidecarIsIntegrityFailure() async {
        let payload = Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)
        let inputs = AutotuneStaticInputs(
            fetch: { url in
                if url.path.hasSuffix(".sig") { throw URLError(.fileDoesNotExist) }
                return payload
            }
        )

        let selection = await inputs.loadDemandRank()

        XCTAssertTrue(selection.usedFallback)
        XCTAssertTrue(selection.warnings.contains(.demandRankIntegrityFailure))
    }

    func testCandidateJSONSuccessWithMissingSidecarIsIntegrityFailure() async {
        let payload = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        let inputs = AutotuneStaticInputs(
            fetch: { url in
                if url.path.hasSuffix(".sig") { throw URLError(.fileDoesNotExist) }
                return payload
            }
        )

        let selection = await inputs.loadCandidateCatalog()

        XCTAssertTrue(selection.usedFallback)
        XCTAssertTrue(selection.warnings.contains(.candidateCatalogIntegrityFailure))
    }

    func testSignedStaticAcceptsPinnedJuly10TransitionReleaseBeforeFeedActivation() async throws {
        let demandPayload = try Data(contentsOf: Self.catalogTestdata.appendingPathComponent("published-2026-07-10-catalog-recovery-v1.demand-rank.json"))
        let candidatePayload = try Data(contentsOf: Self.catalogTestdata.appendingPathComponent("published-2026-07-10-catalog-recovery-v1.autotune-candidates.json"))
        XCTAssertEqual(AutotuneStaticInputs.candidateCatalogSHA256(bytes: demandPayload), "27cdfc12a43b78db32710926ee16699aadce0c4ddd9d8282baca2532f780c5e2")
        XCTAssertEqual(AutotuneStaticInputs.candidateCatalogSHA256(bytes: candidatePayload), "776182f6230eff098345b188322dba0c7fce47a6da46447432991ffdc37eabda")
        XCTAssertThrowsError(try AutotuneStaticInputs.decodeCandidateCatalog(candidatePayload))

        let privateKey = Curve25519.Signing.PrivateKey()
        let keyID = "streamvc-autotune-static-v4"
        let demandSidecar = try Self.sidecar(for: demandPayload, keyID: keyID, privateKey: privateKey)
        let candidateSidecar = try Self.sidecar(for: candidatePayload, keyID: keyID, privateKey: privateKey)
        let inputs = AutotuneStaticInputs(
            fetch: { url in
                switch url.path {
                case _ where url.path.hasSuffix("/demand-rank.sig"):
                    return demandSidecar
                case _ where url.path.hasSuffix("/demand-rank"):
                    return demandPayload
                case _ where url.path.hasSuffix("/autotune-candidates.sig"):
                    return candidateSidecar
                case _ where url.path.hasSuffix("/autotune-candidates"):
                    return candidatePayload
                default:
                    throw URLError(.fileDoesNotExist)
                }
            },
            trustedPublicKeys: [keyID: privateKey.publicKey.rawRepresentation.base64EncodedString()],
            now: { Self.date("2026-07-29T12:00:00Z") }
        )

        let release = await inputs.loadCatalogRelease()

        XCTAssertFalse(release.demand.usedFallback)
        XCTAssertFalse(release.candidate.usedFallback)
        XCTAssertEqual(release.demand.value.version, "published-2026-07-10-catalog-recovery-v1")
        XCTAssertEqual(release.candidate.value.version, "published-2026-07-10-catalog-recovery-v1")
        XCTAssertFalse(release.demand.warnings.contains(.demandRankUpdateRequired))
        XCTAssertFalse(release.candidate.warnings.contains(.candidateCatalogUpdateRequired))
        XCTAssertFalse(release.candidate.warnings.contains(.candidateCatalogIntegrityFailure))
        XCTAssertTrue(release.demand.warnings.contains(.demandRankStale))
        XCTAssertTrue(release.candidate.warnings.contains(.candidateCatalogStale))
    }

    func testSignedStaticRejectsUnpinnedMissingProvenanceTransitionShape() async throws {
        let demandPayload = try Data(contentsOf: Self.catalogTestdata.appendingPathComponent("published-2026-07-10-catalog-recovery-v1.demand-rank.json"))
        let candidatePayload = try Self.dataReplacing(
            Data(contentsOf: Self.catalogTestdata.appendingPathComponent("published-2026-07-10-catalog-recovery-v1.autotune-candidates.json")),
            "\"min_ram_gb\":28",
            "\"min_ram_gb\":29"
        )
        let privateKey = Curve25519.Signing.PrivateKey()
        let keyID = "streamvc-autotune-static-v4"
        let demandSidecar = try Self.sidecar(for: demandPayload, keyID: keyID, privateKey: privateKey)
        let candidateSidecar = try Self.sidecar(for: candidatePayload, keyID: keyID, privateKey: privateKey)
        let inputs = AutotuneStaticInputs(
            fetch: { url in
                switch url.path {
                case _ where url.path.hasSuffix("/demand-rank.sig"):
                    return demandSidecar
                case _ where url.path.hasSuffix("/demand-rank"):
                    return demandPayload
                case _ where url.path.hasSuffix("/autotune-candidates.sig"):
                    return candidateSidecar
                case _ where url.path.hasSuffix("/autotune-candidates"):
                    return candidatePayload
                default:
                    throw URLError(.fileDoesNotExist)
                }
            },
            trustedPublicKeys: [keyID: privateKey.publicKey.rawRepresentation.base64EncodedString()],
            now: { Self.date("2026-07-29T12:00:00Z") }
        )

        let release = await inputs.loadCatalogRelease()

        XCTAssertTrue(release.candidate.usedFallback)
        XCTAssertTrue(release.candidate.warnings.contains(.candidateCatalogIntegrityFailure))
        XCTAssertTrue(release.candidate.warnings.contains(.candidateCatalogFallbackUsed))
    }

    func testSignedStaticRejectsPinnedJuly10TransitionUnderWrongSigner() async throws {
        let demandPayload = try Data(contentsOf: Self.catalogTestdata.appendingPathComponent("published-2026-07-10-catalog-recovery-v1.demand-rank.json"))
        let candidatePayload = try Data(contentsOf: Self.catalogTestdata.appendingPathComponent("published-2026-07-10-catalog-recovery-v1.autotune-candidates.json"))
        let privateKey = Curve25519.Signing.PrivateKey()
        let keyID = "streamvc-autotune-static-v5"
        let demandSidecar = try Self.sidecar(for: demandPayload, keyID: keyID, privateKey: privateKey)
        let candidateSidecar = try Self.sidecar(for: candidatePayload, keyID: keyID, privateKey: privateKey)
        let inputs = AutotuneStaticInputs(
            fetch: { url in
                switch url.path {
                case _ where url.path.hasSuffix("/demand-rank.sig"):
                    return demandSidecar
                case _ where url.path.hasSuffix("/demand-rank"):
                    return demandPayload
                case _ where url.path.hasSuffix("/autotune-candidates.sig"):
                    return candidateSidecar
                case _ where url.path.hasSuffix("/autotune-candidates"):
                    return candidatePayload
                default:
                    throw URLError(.fileDoesNotExist)
                }
            },
            trustedPublicKeys: [keyID: privateKey.publicKey.rawRepresentation.base64EncodedString()],
            now: { Self.date("2026-07-29T12:00:00Z") }
        )

        let release = await inputs.loadCatalogRelease()

        XCTAssertTrue(release.demand.usedFallback)
        XCTAssertTrue(release.candidate.usedFallback)
        XCTAssertTrue(release.demand.warnings.contains(.demandRankUpdateRequired))
        XCTAssertTrue(release.candidate.warnings.contains(.candidateCatalogUpdateRequired))
        XCTAssertFalse(release.demand.warnings.contains(.demandRankIntegrityFailure))
        XCTAssertFalse(release.candidate.warnings.contains(.candidateCatalogIntegrityFailure))
    }

    func testSignedStaticAcceptsBridgeKeyFromTrustedKeyring() async throws {
        let payload = Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)
        let privateKey = Curve25519.Signing.PrivateKey()
        let signature = try privateKey.signature(for: payload).base64EncodedString()
        let keyID = "streamvc-autotune-static-v5"
        let sidecar = Data("{\"key_id\":\"\(keyID)\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
        var keyring = AutotuneStaticInputs.defaultTrustedPublicKeys
        keyring[keyID] = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let inputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? sidecar : payload },
            trustedPublicKeys: keyring,
            now: { Self.date("2026-07-30T17:00:00Z") }
        )

        let selection = await inputs.loadDemandRank()

        XCTAssertFalse(selection.usedFallback)
        XCTAssertFalse(selection.warnings.contains(.demandRankIntegrityFailure))
    }

    func testSignedStaticUnknownKeyIsIntegrityFailure() async throws {
        let payload = Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)
        let signature = Data(repeating: 0, count: 64).base64EncodedString()
        let sidecar = Data("{\"key_id\":\"unknown-v9\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
        let inputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? sidecar : payload },
            verifySignature: { _, _ in true },
            now: { Self.date("2026-07-11T00:00:00Z") }
        )

        let selection = await inputs.loadDemandRank()

        XCTAssertTrue(selection.usedFallback)
        XCTAssertTrue(selection.warnings.contains(.demandRankIntegrityFailure))
    }

    func testPinnedPublicKeyIsValidCurve25519SigningKey() {
        let keyData = Data(base64Encoded: AutotuneStaticInputs.publicKeyBase64)

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
        {"version":"test","generated_at":"2026-07-01T00:00:00Z","source":"operator_curated_autotune_candidate_catalog","policy_version":"autotune-policy-v1","rows":{"model-a":{"model_id":"namespace/model","model_revision":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","model_sha256":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","min_ram_gb":1,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000,"provenance":{"source":"policy","notes":"test fixture"}},"runtime_status":"recommendable"}}}
        """

        XCTAssertThrowsError(try AutotuneStaticInputs.decodeCandidateCatalog(Data(json.utf8)))
    }

    func testBakedCandidateCatalogCarriesBenchGateProvenanceInBand() throws {
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        let row = try XCTUnwrap(catalog.rows["qwen2.5-coder-32b-instruct"])
        XCTAssertEqual(row.benchGate.provenance.source, "policy")
        XCTAssertEqual(row.benchGate.provenance.notes, "#744 audit: gate set by operator policy to broaden eligibility.")
    }

    func testCandidateCatalogRejectsMissingBenchGateProvenance() throws {
        let json = try Self.bakedCandidateCatalogRemovingFirstProvenance()

        XCTAssertThrowsError(try AutotuneStaticInputs.decodeCandidateCatalog(Data(json.utf8)))
    }

    private static func bakedCandidateCatalogRemovingFirstProvenance() throws -> String {
        let data = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try XCTUnwrap(root["rows"] as? [String: Any])
        let firstKey = try XCTUnwrap(rows.keys.sorted().first)
        var row = try XCTUnwrap(rows[firstKey] as? [String: Any])
        var benchGate = try XCTUnwrap(row["bench_gate"] as? [String: Any])
        benchGate.removeValue(forKey: "provenance")
        row["bench_gate"] = benchGate
        rows[firstKey] = row
        root["rows"] = rows
        let mutated = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return try XCTUnwrap(String(data: mutated, encoding: .utf8))
    }

    private static func sidecar(for payload: Data, keyID: String, privateKey: Curve25519.Signing.PrivateKey) throws -> Data {
        let signature = try privateKey.signature(for: payload).base64EncodedString()
        return Data("{\"key_id\":\"\(keyID)\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
    }

    private static func loadSignedRateCardWithAcceptedSignature(_ payload: Data) async -> AutotuneStaticSelection<RateCardProjection> {
        let signature = Data(repeating: 0, count: 64).base64EncodedString()
        let sidecar = Data("{\"key_id\":\"streamvc-autotune-static-v4\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
        let inputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? sidecar : payload },
            verifySignature: { _, _ in true },
            now: { Self.date("2026-07-29T10:00:00Z") }
        )
        return await inputs.loadRateCard()
    }

    private static func dataReplacing(_ data: Data, _ old: String, _ new: String) throws -> Data {
        let string = try XCTUnwrap(String(data: data, encoding: .utf8))
        let updated = string.replacingOccurrences(of: old, with: new, options: [], range: string.range(of: old))
        XCTAssertNotEqual(updated, string)
        return Data(updated.utf8)
    }

    func testCandidateCatalogRejectsMissingBenchGateProvenanceInFetchedRelease() throws {
        let json = """
        {"version":"new-release","generated_at":"2026-07-26T00:00:00Z","source":"operator_curated_autotune_candidate_catalog","policy_version":"autotune-policy-v1","rows":{"model-a":{"model_id":"mlx-community/Test-Model-4bit","model_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","model_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","min_ram_gb":1,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"recommendable"}}}
        """

        XCTAssertThrowsError(try AutotuneStaticInputs.decodeCandidateCatalog(Data(json.utf8)))
    }

    func testCandidateCatalogRejectsNullBenchGateProvenanceOptional() throws {
        let json = """
        {"version":"new-release","generated_at":"2026-07-26T00:00:00Z","source":"operator_curated_autotune_candidate_catalog","policy_version":"autotune-policy-v1","rows":{"model-a":{"model_id":"mlx-community/Test-Model-4bit","model_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","model_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","min_ram_gb":1,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000,"provenance":{"source":"legacy_unverified","notes":null}},"runtime_status":"recommendable"}}}
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

    func testPrefetchVerifiesOnlyExplicitSignedArtifactWithoutStartingBenchmarkRuntime() async throws {
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var request = try makeRequest(modelKey: modelKey)
        request.hardware.memoryGB = 64
        request.hardware.bandwidthTier = .a
        let row = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        let revision = try XCTUnwrap(row.modelRevision)
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let snapshot = resolver.snapshotURL(modelID: row.modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("prefetched-weights".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))
        request.candidateCatalog.rows[modelKey]?.modelSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: resolver,
            runnerFactory: { throw AutotuneRecommendError.invalidStaticJSON("prefetch must not start a provider runtime") },
            prober: RecordingStage1Prober(results: [:]),
            safetySampler: StaticProbeSafetySampler()
        )

        let outcome = try await benchmarker.prefetchArtifacts(
            candidateCatalog: request.candidateCatalog,
            hardware: request.hardware,
            candidateModelIDs: [row.modelID]
        )

        XCTAssertEqual(outcome.matchedModelIDs, [row.modelID])
        XCTAssertEqual(outcome.prefetchedModelIDs, [row.modelID])
        XCTAssertEqual(outcome.artifacts.map(\.path), [snapshot.path])
        XCTAssertTrue(outcome.diagnostics.isEmpty)
    }

    func testPrefetchRejectsDuplicateSignedRowsBeforeArtifactAcquisition() async throws {
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var request = try makeRequest(modelKey: modelKey)
        request.hardware.memoryGB = 64
        request.hardware.bandwidthTier = .a
        let row = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        request.candidateCatalog.rows["duplicate-row"] = row
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: CachedModelArtifactResolver(
                hubRoot: try tempDir(),
                downloader: HuggingFaceSnapshotDownloader(
                    fetch: { _ in
                        throw AutotuneRecommendError.invalidArtifact("artifact acquisition must not start")
                    },
                    download: { _ in
                        throw AutotuneRecommendError.invalidArtifact("artifact acquisition must not start")
                    }
                )
            ),
            runnerFactory: { throw AutotuneRecommendError.invalidStaticJSON("prefetch must not start a provider runtime") },
            prober: RecordingStage1Prober(results: [:]),
            safetySampler: StaticProbeSafetySampler()
        )

        do {
            _ = try await benchmarker.prefetchArtifacts(
                candidateCatalog: request.candidateCatalog,
                hardware: request.hardware,
                candidateModelIDs: [row.modelID]
            )
            XCTFail("duplicate signed rows must fail before artifact acquisition")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("exactly one signed catalog row"))
            XCTAssertTrue(message.contains(modelKey))
            XCTAssertTrue(message.contains("duplicate-row"))
            XCTAssertFalse(message.contains("artifact acquisition must not start"))
        }
    }

    func testPrefetchPreservesMismatchedIncumbentSnapshotWhileAcquiringReplacement() async throws {
        let hub = try tempDir()
        let revision = String(repeating: "c", count: 40)
        let canonical = CachedModelArtifactResolver(hubRoot: hub)
            .snapshotURL(modelID: "namespace/model", revision: revision)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try Data("incumbent".utf8).write(to: canonical.appendingPathComponent("weights.bin"))

        let expectedDirectory = try tempDir()
        try Data("replacement".utf8).write(to: expectedDirectory.appendingPathComponent("weights.bin"))
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: expectedDirectory)
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
        let downloader = HuggingFaceSnapshotDownloader(
            fetch: { request in
                let url = try XCTUnwrap(request.url)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
                return (Data(#"{"siblings":[{"rfilename":"weights.bin"}]}"#.utf8), response)
            },
            download: { _ in
                let downloaded = FileManager.default.temporaryDirectory
                    .appendingPathComponent("autotune-prefetch-\(UUID().uuidString).bin")
                try Data("replacement".utf8).write(to: downloaded)
                return (
                    downloaded,
                    URLResponse(
                        url: URL(string: "https://example.test/weights.bin")!,
                        mimeType: nil,
                        expectedContentLength: 11,
                        textEncodingName: nil
                    )
                )
            }
        )

        let artifact = try await CachedModelArtifactResolver(hubRoot: hub, downloader: downloader)
            .prefetchedArtifactPreservingExisting(for: row)

        XCTAssertNotEqual(artifact.modelArgument, canonical.path)
        XCTAssertEqual(artifact.sha256, expected)
        XCTAssertEqual(try String(contentsOf: canonical.appendingPathComponent("weights.bin")), "incumbent")
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: artifact.modelArgument).appendingPathComponent("weights.bin")),
            "replacement"
        )
    }

    func testPrefetchReceiptRejectsCatalogDriftAndBenchmarkNeverDownloadsAfterBinding() async throws {
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var request = try makeRequest(modelKey: modelKey)
        request.hardware.memoryGB = 64
        request.hardware.bandwidthTier = .a
        let row = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        let revision = try XCTUnwrap(row.modelRevision)
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let snapshot = resolver.snapshotURL(modelID: row.modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("receipt-weights".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))
        request.candidateCatalog.rows[modelKey]?.modelSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        request.candidateCatalogSHA256 = String(repeating: "d", count: 64)
        let outcome = try await AutotuneRecommendationBenchmarker(artifactResolver: resolver).prefetchArtifacts(
            candidateCatalog: request.candidateCatalog,
            hardware: request.hardware,
            candidateModelIDs: [row.modelID]
        )
        let receipt = AutotuneArtifactPrefetchReceipt(
            schemaVersion: AutotuneArtifactPrefetchReceipt.currentSchemaVersion,
            candidateCatalogSHA256: request.candidateCatalogSHA256,
            candidateCatalogVersion: request.candidateCatalog.version,
            candidateCatalogPolicyVersion: request.candidateCatalog.policyVersion,
            artifacts: outcome.artifacts
        )
        let bindings = try receipt.validatedArtifacts(
            candidateCatalog: request.candidateCatalog,
            candidateCatalogSHA256: request.candidateCatalogSHA256
        )

        var drifted = request.candidateCatalog
        drifted.rows[modelKey]?.modelRevision = String(repeating: "e", count: 40)
        XCTAssertThrowsError(try receipt.validatedArtifacts(
            candidateCatalog: drifted,
            candidateCatalogSHA256: request.candidateCatalogSHA256
        ))

        try FileManager.default.removeItem(at: URL(fileURLWithPath: try XCTUnwrap(bindings[modelKey]).path))
        let offlineBenchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: CachedModelArtifactResolver(
                hubRoot: hub,
                downloader: HuggingFaceSnapshotDownloader(
                    fetch: { _ in throw AutotuneRecommendError.invalidArtifact("downloader must not run after cutover") },
                    download: { _ in throw AutotuneRecommendError.invalidArtifact("downloader must not run after cutover") }
                )
            ),
            runnerFactory: { throw AutotuneRecommendError.invalidStaticJSON("runner must not start without receipt bytes") }
        )
        do {
            _ = try await offlineBenchmarker.benchmarks(
                request: request,
                targetContext: 4_000,
                gateTTFTMS: 3_000,
                replicates: 1,
                port: 18_080,
                candidateModelIDs: [row.modelID],
                prefetchedArtifacts: bindings
            )
            XCTFail("cache-only receipt binding must fail when prefetched bytes disappear")
        } catch {
            XCTAssertTrue(String(describing: error).contains("missing pinned snapshot"))
            XCTAssertFalse(String(describing: error).contains("downloader must not run"))
        }
    }

    func testVerifiedArtifactRepairsMismatchedCachedSnapshot() async throws {
        let hub = try tempDir()
        let revision = String(repeating: "b", count: 40)
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let snapshot = resolver.snapshotURL(modelID: "namespace/model", revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))

        let expectedDir = try tempDir()
        try Data("fresh".utf8).write(to: expectedDir.appendingPathComponent("weights.bin"))
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: expectedDir)
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

        let downloader = HuggingFaceSnapshotDownloader(
            fetch: { request in
                let data = Data(#"{"siblings":[{"rfilename":"weights.bin"}]}"#.utf8)
                let url = try XCTUnwrap(request.url)
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )
                )
                return (data, response)
            },
            download: { _ in
                let downloaded = FileManager.default.temporaryDirectory
                    .appendingPathComponent("autotune-download-\(UUID().uuidString).bin")
                try Data("fresh".utf8).write(to: downloaded)
                return (downloaded, URLResponse(url: URL(string: "https://example.test/weights.bin")!, mimeType: nil, expectedContentLength: 5, textEncodingName: nil))
            }
        )

        let verified = try await CachedModelArtifactResolver(hubRoot: hub, downloader: downloader)
            .verifiedArtifact(for: row)

        XCTAssertEqual(verified.modelArgument, snapshot.path)
        XCTAssertEqual(verified.sha256, expected)
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("weights.bin")), "fresh")
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
            artifactResolver: CachedModelArtifactResolver(
                hubRoot: hub,
                downloader: HuggingFaceSnapshotDownloader(
                    fetch: { _ in throw AutotuneRecommendError.invalidArtifact("test network unavailable") },
                    download: { _ in throw AutotuneRecommendError.invalidArtifact("test network unavailable") }
                )
            ),
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
            artifactResolver: CachedModelArtifactResolver(
                hubRoot: hub,
                downloader: HuggingFaceSnapshotDownloader(
                    fetch: { _ in throw AutotuneRecommendError.invalidArtifact("test network unavailable") },
                    download: { _ in throw AutotuneRecommendError.invalidArtifact("test network unavailable") }
                )
            ),
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
        XCTAssertEqual(prober.probedArtifactBindings.count, 1)
        XCTAssertEqual(prober.probedArtifactBindings[0]?.path, goodArtifactPath)
        XCTAssertEqual(
            prober.probedArtifactBindings[0]?.sha256,
            request.candidateCatalog.rows[goodKey]?.modelSHA256
        )
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
        // Whole-series unknown pressure => fail closed (matches the prior
        // nil-fail-closed contract). All-unknown thermal also throttles.
        let unavailable = ProbeSafetyAssessment.assess(samples: [
            ProbeSafetySample(pressureLevel: .unknown, thermalState: nil),
            ProbeSafetySample(pressureLevel: .unknown, thermalState: nil),
            ProbeSafetySample(pressureLevel: .unknown, thermalState: nil),
        ])
        XCTAssertTrue(unavailable.swapDetected)
        XCTAssertTrue(unavailable.thermalThrottleDetected)
        XCTAssertFalse(unavailable.swapObservedUnderLoad)

        // Healthy series: sustained normal pressure, benign thermal.
        let safe = ProbeSafetyAssessment.assess(samples: [
            ProbeSafetySample(pressureLevel: .normal, thermalState: .nominal),
            ProbeSafetySample(pressureLevel: .normal, thermalState: .fair),
            ProbeSafetySample(pressureLevel: .normal, thermalState: .nominal),
        ])
        XCTAssertFalse(safe.swapDetected)
        XCTAssertFalse(safe.thermalThrottleDetected)
        XCTAssertFalse(safe.swapObservedUnderLoad)
    }

    func testProbeSafetyAssessmentDetectsSustainedCriticalThrash() {
        // #742's real incident: a genuinely thrashing node holds CRITICAL
        // memory pressure across the probe => hard swap veto.
        let thrash = ProbeSafetyAssessment.assess(samples: [
            ProbeSafetySample(pressureLevel: .critical, thermalState: .serious),
            ProbeSafetySample(pressureLevel: .critical, thermalState: .serious),
            ProbeSafetySample(pressureLevel: .warning, thermalState: .fair),
            ProbeSafetySample(pressureLevel: .critical, thermalState: .serious),
        ])
        XCTAssertTrue(thrash.swapDetected)
    }

    func testProbeSafetyAssessmentDoesNotBlockIncidentalPressureOn8GB() {
        // 8 GB Mac running the smallest model: mostly normal pressure with a
        // single transient WARNING blip. This must NOT be read as thrash, so
        // llama-3.2-3b stays paid-eligible (the growth-blocker fix).
        let incidental = ProbeSafetyAssessment.assess(samples: [
            ProbeSafetySample(pressureLevel: .normal, thermalState: .nominal),
            ProbeSafetySample(pressureLevel: .normal, thermalState: .nominal),
            ProbeSafetySample(pressureLevel: .warning, thermalState: .fair),
            ProbeSafetySample(pressureLevel: .normal, thermalState: .nominal),
        ])
        XCTAssertFalse(incidental.swapDetected)
        XCTAssertFalse(incidental.swapObservedUnderLoad)
    }

    func testProbeSafetyAssessmentFlagsAdvisoryOnWarningMajority() {
        // Sustained WARNING majority (no critical majority): do not block, but
        // flag the advisory observation for operators / telemetry.
        let warned = ProbeSafetyAssessment.assess(samples: [
            ProbeSafetySample(pressureLevel: .warning, thermalState: .nominal),
            ProbeSafetySample(pressureLevel: .warning, thermalState: .nominal),
            ProbeSafetySample(pressureLevel: .warning, thermalState: .nominal),
        ])
        XCTAssertFalse(warned.swapDetected)
        XCTAssertTrue(warned.swapObservedUnderLoad)
    }

    func testProbeSafetyAssessmentSingleTransientUnknownDoesNotBlock() {
        // A lone unknown reading amid healthy samples must not fail closed.
        let transient = ProbeSafetyAssessment.assess(samples: [
            ProbeSafetySample(pressureLevel: .normal, thermalState: .nominal),
            ProbeSafetySample(pressureLevel: .unknown, thermalState: .nominal),
            ProbeSafetySample(pressureLevel: .normal, thermalState: .nominal),
        ])
        XCTAssertFalse(transient.swapDetected)
    }

    func testProbeSafetyAssessmentShortProbeSustainedCriticalStillBlocks() {
        // Round-1 audit fix (MEDIUM): a short probe that yields only the two
        // synchronous samples must still veto when both read CRITICAL — the old
        // >= 3 total-sample floor let this fail open.
        let shortThrash = ProbeSafetyAssessment.assess(samples: [
            ProbeSafetySample(pressureLevel: .critical, thermalState: .serious),
            ProbeSafetySample(pressureLevel: .critical, thermalState: .serious),
        ])
        XCTAssertTrue(shortThrash.swapDetected)
    }

    func testProbeSafetyAssessmentLoneCriticalSpikeDoesNotBlock() {
        // A single incidental CRITICAL reading among healthy samples is not
        // sustained thrash (requires >= 2 critical), so it must not block.
        let spike = ProbeSafetyAssessment.assess(samples: [
            ProbeSafetySample(pressureLevel: .normal, thermalState: .nominal),
            ProbeSafetySample(pressureLevel: .critical, thermalState: .serious),
            ProbeSafetySample(pressureLevel: .normal, thermalState: .nominal),
        ])
        XCTAssertFalse(spike.swapDetected)
    }

    func testProbeSafetyAssessmentUnknownDoesNotDiluteCriticalMajority() {
        // Round-1 audit fix (MEDIUM): .unknown readings must not dilute the
        // denominator. Two CRITICAL among many UNKNOWN is a critical majority of
        // the READABLE samples and must veto (the old raw-count denominator let
        // this fail open).
        let diluted = ProbeSafetyAssessment.assess(samples: [
            ProbeSafetySample(pressureLevel: .critical, thermalState: .serious),
            ProbeSafetySample(pressureLevel: .critical, thermalState: .serious),
            ProbeSafetySample(pressureLevel: .unknown, thermalState: .serious),
            ProbeSafetySample(pressureLevel: .unknown, thermalState: .serious),
            ProbeSafetySample(pressureLevel: .unknown, thermalState: .serious),
        ])
        XCTAssertTrue(diluted.swapDetected)
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
        {"generated_at":"2026-07-01T00:00:00Z","rate_card_version":"old","demand_rank_version":"published-2026-07-07-p2-qwen3-8b","candidate_catalog_version":"published-2026-07-07-p2-qwen3-8b","candidate_catalog_sha256":"old","benchmark_id":"bench-1","benchmark_generated_at":"2026-07-01T00:00:00Z","binary_version":"test","hardware_identity_hash":"old","recommended_model":"qwen3-coder-30b-a3b-instruct"}
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

    func testIsStaleIgnoresCLIVersionOnlyChange() throws {
        let generatedAt = Self.date("2026-07-01T00:00:00Z")
        let stored = LastRecommendationState(
            generatedAt: generatedAt,
            rateCardVersion: "rate-1",
            demandRankVersion: "demand-1",
            candidateCatalogVersion: "catalog-1",
            candidateCatalogSHA256: "catalog-sha-1",
            benchmarkID: "bench-1",
            benchmarkGeneratedAt: generatedAt,
            binaryVersion: "1.8.55",
            hardwareIdentityHash: "hw-1",
            recommendedModel: "meta-llama/llama-3.2-3b-instruct"
        )
        // Only the CLI marketing version advances; every compatibility input
        // (rate card, demand rank, catalog identity/digest, hardware identity)
        // and the cached benchmark stay the same.
        var current = stored
        current.binaryVersion = "1.8.56"

        XCTAssertFalse(RecommendationStateStore.isStale(
            stored: stored,
            current: current,
            now: generatedAt
        ))
    }

    func testIsStaleDetectsCompatibilityInputChanges() throws {
        let generatedAt = Self.date("2026-07-01T00:00:00Z")
        let stored = LastRecommendationState(
            generatedAt: generatedAt,
            rateCardVersion: "rate-1",
            demandRankVersion: "demand-1",
            candidateCatalogVersion: "catalog-1",
            candidateCatalogSHA256: "catalog-sha-1",
            benchmarkID: "bench-1",
            benchmarkGeneratedAt: generatedAt,
            binaryVersion: "1.8.55",
            hardwareIdentityHash: "hw-1",
            recommendedModel: "meta-llama/llama-3.2-3b-instruct"
        )

        var catalogDigestChanged = stored
        catalogDigestChanged.candidateCatalogSHA256 = "catalog-sha-2"
        XCTAssertTrue(RecommendationStateStore.isStale(stored: stored, current: catalogDigestChanged, now: generatedAt))

        var hardwareChanged = stored
        hardwareChanged.hardwareIdentityHash = "hw-2"
        XCTAssertTrue(RecommendationStateStore.isStale(stored: stored, current: hardwareChanged, now: generatedAt))

        var catalogVersionChanged = stored
        catalogVersionChanged.candidateCatalogVersion = "catalog-2"
        XCTAssertTrue(RecommendationStateStore.isStale(stored: stored, current: catalogVersionChanged, now: generatedAt))
    }

    func testStatusStaleHelperMarksStoredStateStaleWhenSecretCannotBeReused() async throws {
        let dir = try tempDir()
        let secretURL = dir.appendingPathComponent("secret")
        try Data(repeating: 9, count: 32).write(to: secretURL)
        XCTAssertEqual(chmod(secretURL.path, 0o644), 0)
        let stateURL = dir.appendingPathComponent("last-recommendation.json")
        try Data("""
        {"generated_at":"2026-07-01T00:00:00Z","rate_card_version":"baked-2026-07-03","demand_rank_version":"published-2026-07-07-p2-qwen3-8b","candidate_catalog_version":"published-2026-07-07-p2-qwen3-8b","candidate_catalog_sha256":"old","benchmark_id":"bench-1","benchmark_generated_at":"2026-07-01T00:00:00Z","binary_version":"test","hardware_identity_hash":"old","recommended_model":"qwen3-coder-30b-a3b-instruct"}
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
        {"generated_at":"2026-07-02T00:00:00Z","rate_card_version":"baked-2026-07-07-p2-drift","demand_rank_version":"published-2026-07-10-catalog-recovery-v1","candidate_catalog_version":"published-2026-07-10-catalog-recovery-v1","candidate_catalog_sha256":"\(catalogSHA)","benchmark_id":"bench-1","benchmark_generated_at":"2026-07-02T00:00:00Z","binary_version":"test","hardware_identity_hash":"\(identity.cacheIdentityHash)","recommended_model":"qwen3-coder-30b-a3b-instruct"}
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

        // Offline transport uses baked catalog fallback, which blocks network
        // evidence freshness even when the stored SHA matches baked (#582).
        XCTAssertEqual(staleSince, Optional(Self.date("2026-07-02T00:00:00Z")))
        XCTAssertEqual(staleWithDifferentProvider, Optional(Self.date("2026-07-02T00:00:00Z")))
    }

    func testFreshnessTrustBlockIsDistinctFromOrdinaryStaleness() async throws {
        let dir = try tempDir()
        let secretURL = dir.appendingPathComponent("secret")
        let secret = Data(repeating: 9, count: 32)
        try secret.write(to: secretURL)
        XCTAssertEqual(chmod(secretURL.path, 0o600), 0)
        let stateURL = dir.appendingPathComponent("last-recommendation.json")
        let fingerprint = MachineFingerprint(ramGB: 64, chip: "Apple M4 Pro", osVersion: "macOS 15", binaryVersion: "test")
        let identity = HMACIdentity.derive(secret: secret, fingerprint: fingerprint, providerID: "provider-a")
        let catalogBytes = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        let catalogSHA = AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalogBytes)
        try Data("""
        {"generated_at":"2026-07-02T00:00:00Z","rate_card_version":"baked-2026-07-07-p2-drift","demand_rank_version":"published-2026-07-10-catalog-recovery-v1","candidate_catalog_version":"published-2026-07-10-catalog-recovery-v1","candidate_catalog_sha256":"\(catalogSHA)","benchmark_id":"bench-1","benchmark_generated_at":"2026-07-02T00:00:00Z","binary_version":"test","hardware_identity_hash":"\(identity.cacheIdentityHash)","recommended_model":"qwen3-coder-30b-a3b-instruct"}
        """.utf8).write(to: stateURL)
        let signature = Data(repeating: 0, count: 64).base64EncodedString()
        let sidecar = Data("{\"key_id\":\"\(AutotuneStaticInputs.keyID)\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
        let olderDemand = Data(AutotuneStaticInputs.bakedDemandRankJSON
            .replacingOccurrences(of: "2026-07-10T19:00:00Z", with: "2026-07-07T12:00:00Z")
            .utf8)
        let explicitProvenanceCatalog = AutotuneStaticInputs.bakedCandidateCatalogJSON
            .replacingOccurrences(
                of: "\"bench_gate\":{\"min_sustained_tps\":",
                with: "\"bench_gate\":{\"provenance\":{\"source\":\"legacy_unverified\",\"notes\":\"freshness fixture\"},\"min_sustained_tps\":"
            )
        let olderCatalog = Data(explicitProvenanceCatalog
            .replacingOccurrences(of: "2026-07-10T19:00:00Z", with: "2026-07-07T12:00:00Z")
            .utf8)
        let staticInputs = AutotuneStaticInputs(
            fetch: { url in
                if url.path.hasSuffix(".sig") { return sidecar }
                if url.path.hasSuffix("/demand-rank") {
                    return olderDemand
                }
                if url.path.hasSuffix("/autotune-candidates") { return olderCatalog }
                throw AutotuneRecommendError.invalidStaticJSON("offline")
            },
            verifySignature: { _, _ in true },
            now: { Self.date("2026-07-15T00:00:00Z") }
        )

        let status = await RecommendationFreshnessChecker(
            staticInputs: staticInputs,
            fingerprint: fingerprint,
            providerID: "provider-a",
            hmacSecretURL: secretURL,
            stateURL: stateURL,
            now: Self.date("2026-07-15T00:00:00Z")
        ).status()

        XCTAssertEqual(
            status,
            .trustBlocked(
                Optional(Self.date("2026-07-02T00:00:00Z")),
                [
                    .candidateCatalogFallbackUsed,
                    .candidateCatalogUpdateRequired,
                    .demandRankUpdateRequired,
                ]
            )
        )

        let missingStateStatus = await RecommendationFreshnessChecker(
            staticInputs: staticInputs,
            fingerprint: fingerprint,
            providerID: "provider-a",
            hmacSecretURL: secretURL,
            stateURL: dir.appendingPathComponent("missing-recommendation.json"),
            now: Self.date("2026-07-15T00:00:00Z")
        ).status()

        XCTAssertEqual(
            missingStateStatus,
            .trustBlocked(
                nil,
                [
                    .candidateCatalogFallbackUsed,
                    .candidateCatalogUpdateRequired,
                    .demandRankUpdateRequired,
                ]
            )
        )
    }

    // MARK: - Rate-card recommendation gates + swap tolerance

    func testRecommendationUsesDefaultTierWhenSpecificRateCardRowIsMissing() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        request.rateCard.rows.removeValue(forKey: modelKey)
        request.rateCard.rows["default"] = RateCardProjection.Row(
            promptRatePerMtok: 500_000,
            completionRatePerMtok: 1_000_000,
            providerShareBPS: 9_000,
            globalMultiplierPPM: 1_000_000
        )

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, modelKey)
        XCTAssertEqual(result.selectedCandidate?.catalogKey, modelKey)
        XCTAssertTrue(result.warnings.contains(.rateCardDefaultTierUsed))
        XCTAssertFalse(result.warnings.contains(.noEligibleModel))
        let candidate = try XCTUnwrap(result.allCandidates.first { $0.catalogKey == modelKey })
        XCTAssertTrue(candidate.eligible)
        XCTAssertEqual(candidate.model, modelKey)
        XCTAssertEqual(candidate.confidence, "low")
        XCTAssertEqual(result.selectedCandidate?.confidence, "low")
        XCTAssertEqual(candidate.promptRateUSDPerMillionTokens, 0.5)
        XCTAssertEqual(candidate.completionRateUSDPerMillionTokens, 1.0)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.jsonString().utf8)) as? [String: Any])
        let jsonCandidate = try XCTUnwrap((root["candidates"] as? [[String: Any]])?.first)
        XCTAssertEqual(jsonCandidate["confidence"] as? String, "low")
    }

    func testRecommendationNoDefaultTierWarningWhenSpecificRowPresent() throws {
        let result = AutotuneRecommendEngine().recommend(try makeRequest())
        XCTAssertFalse(result.warnings.contains(.rateCardDefaultTierUsed))
    }

    func testSwapDetectedHardBlocksPaidEligibilityAndEmitsWarning() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        // Flip swap flag on the existing feasible benchmark fixture.
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        benchmark.swapDetected = true
        request.benchmarks[modelKey] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        // #742 / SPEC-023 v0.7: swap is a paid-path hard veto.
        XCTAssertNil(result.recommendedModel, "swap_detected must disqualify paid recommendation")
        XCTAssertNotEqual(result.recommendedModel, modelKey)
        XCTAssertTrue(result.warnings.contains(.swapObservedUnderLoad))
        XCTAssertTrue(result.warnings.contains(.noEligibleModel))
        XCTAssertTrue(
            result.allCandidates.contains { $0.catalogKey == modelKey && !$0.eligible && $0.why.localizedCaseInsensitiveContains("swap") }
        )
        XCTAssertTrue(result.humanTranscript().localizedCaseInsensitiveContains("swap"))
    }

    /// AC-1/AC-2/AC-5 for #742: replay the recorded 2026-07-23 M5/32 GB
    /// production benchmark. The swapping qwen3-coder-30b row must never win.
    func testM5_32GB_2026_07_23FixtureNeverRecommendsSwappingQwenCoder() throws {
        var request = try makeMultiCandidateRequest(modelKeys: [
            "qwen3-coder-30b-a3b-instruct",
            "openai/gpt-oss-20b",
            "qwen3-8b",
            "meta-llama/llama-3.2-3b-instruct",
        ])
        request.hardware = AutotuneRecommendHardware(
            machine: "Mac16,12",
            chip: "Apple M5",
            memoryGB: 32,
            bandwidthTier: .c,
            osVersion: "Version 26.5 (Build 25F71)",
            binaryVersion: "1.8.60",
            diversificationID: "fixture-div-2026-07-23",
            hardwareIdentityHash: "fixture-hw-2026-07-23"
        )
        let generatedAt = Self.date("2026-07-23T12:00:00Z")
        request.generatedAt = generatedAt

        // Recorded production row that selected the live incident model.
        request.benchmarks["qwen3-coder-30b-a3b-instruct"] = try fixtureBenchmark(
            modelKey: "qwen3-coder-30b-a3b-instruct",
            request: request,
            sustainedTPS: 13.452081348183558,
            ttftMS: 10_995,
            swapDetected: true,
            generatedAt: generatedAt
        )
        // Next-best measured row on the same Mac after the hand-switch (no swap).
        request.benchmarks["openai/gpt-oss-20b"] = try fixtureBenchmark(
            modelKey: "openai/gpt-oss-20b",
            request: request,
            sustainedTPS: 30.5,
            ttftMS: 3_423,
            swapDetected: false,
            generatedAt: generatedAt
        )
        // Smaller rows that fit 32 GB and clear swap — present so the engine
        // has non-swapping paid alternatives if gpt-oss is unavailable.
        request.benchmarks["qwen3-8b"] = try fixtureBenchmark(
            modelKey: "qwen3-8b",
            request: request,
            sustainedTPS: 40.0,
            ttftMS: 1_200,
            swapDetected: false,
            generatedAt: generatedAt
        )
        request.benchmarks["meta-llama/llama-3.2-3b-instruct"] = try fixtureBenchmark(
            modelKey: "meta-llama/llama-3.2-3b-instruct",
            request: request,
            sustainedTPS: 60.0,
            ttftMS: 400,
            swapDetected: false,
            generatedAt: generatedAt
        )

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNotEqual(result.recommendedModel, "qwen3-coder-30b-a3b-instruct")
        XCTAssertNotNil(result.recommendedModel, "at least one non-swapping paid row must remain eligible")
        let qwen = try XCTUnwrap(result.allCandidates.first { $0.catalogKey == "qwen3-coder-30b-a3b-instruct" })
        XCTAssertFalse(qwen.eligible)
        XCTAssertTrue(qwen.why.localizedCaseInsensitiveContains("swap"))
    }

    /// AC-4: when every paid row swaps, fall to donor mode with swap named.
    func testAllSwappingPaidRowsFallToDonorWithSwapReason() throws {
        var request = try makeRequest(modelKey: "qwen3-coder-30b-a3b-instruct")
        request.hardware = AutotuneRecommendHardware(
            machine: "Mac-test",
            chip: "Apple M5",
            memoryGB: 32,
            bandwidthTier: .c,
            osVersion: "macOS 15",
            binaryVersion: "test-bin",
            diversificationID: "diversification",
            hardwareIdentityHash: "hardware"
        )
        var benchmark = try XCTUnwrap(request.benchmarks["qwen3-coder-30b-a3b-instruct"])
        benchmark.swapDetected = true
        benchmark.sustainedTPS = 13.452081348183558
        benchmark.ttftMS = 10_995
        request.benchmarks["qwen3-coder-30b-a3b-instruct"] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel)
        XCTAssertTrue(result.warnings.contains(.noEligibleModel))
        XCTAssertTrue(result.warnings.contains(.swapObservedUnderLoad))
        XCTAssertTrue(result.humanTranscript().contains("donor mode only"))
        XCTAssertTrue(result.humanTranscript().localizedCaseInsensitiveContains("swap"))
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

    // MARK: - Signed catalog TPS + TTFT advisory parity

    func testTPSBelowSignedCatalogGateWarnsWithoutBlockingRecommendation() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        let minimum = try XCTUnwrap(request.candidateCatalog.rows[modelKey]).benchGate.minSustainedTPS
        benchmark.sustainedTPS = minimum.nextDown
        request.benchmarks[modelKey] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, modelKey)
        XCTAssertTrue(result.warnings.contains(.tpsBelowGate))
        XCTAssertFalse(result.warnings.contains(.noEligibleModel))
        XCTAssertTrue(
            try XCTUnwrap(result.allCandidates.first { $0.catalogKey == modelKey }).why
                .contains("below advisory catalog target")
        )
    }

    func testTTFTAboveSignedCatalogGateWarnsWithoutBlockingRecommendation() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        let maximum = try XCTUnwrap(request.candidateCatalog.rows[modelKey]).benchGate.max4KTTFTMS
        benchmark.ttftMS = maximum + 1
        request.benchmarks[modelKey] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, modelKey)
        XCTAssertTrue(result.warnings.contains(.ttftAboveGate))
        XCTAssertFalse(result.warnings.contains(.noEligibleModel))
        XCTAssertTrue(
            try XCTUnwrap(result.allCandidates.first { $0.catalogKey == modelKey }).why
                .contains("exceeds advisory catalog target")
        )
    }

    func testTPSAndTTFTSignedCatalogGateMissesWarnWithoutBlockingRecommendation() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        let candidate = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        benchmark.sustainedTPS = candidate.benchGate.minSustainedTPS.nextDown
        benchmark.ttftMS = candidate.benchGate.max4KTTFTMS + 1
        request.benchmarks[modelKey] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, modelKey)
        XCTAssertTrue(result.warnings.contains(.tpsBelowGate))
        XCTAssertTrue(result.warnings.contains(.ttftAboveGate))
        XCTAssertEqual(result.selectedCandidate?.tokensPerSecond, (benchmark.sustainedTPS * 1_000_000).rounded() / 1_000_000)
        XCTAssertFalse(result.warnings.contains(.noEligibleModel))
    }

    func testSignedCatalogGateBoundariesAreInclusiveLikeCoordinator() throws {
        var request = try makeRequest()
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        let candidate = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        var benchmark = try XCTUnwrap(request.benchmarks[modelKey])
        benchmark.sustainedTPS = candidate.benchGate.minSustainedTPS
        benchmark.ttftMS = candidate.benchGate.max4KTTFTMS
        request.benchmarks[modelKey] = benchmark

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(result.recommendedModel, modelKey)
    }

    func testDonorModeAlsoTreatsSignedCatalogGateFailuresAsAdvisory() throws {
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

    func testBenchmarksDiagnosesInvalidFeasibleMeasurementsWithoutTrapping() async throws {
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var request = try makeRequest(modelKey: modelKey)
        let row = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        let revision = try XCTUnwrap(row.modelRevision)
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let snapshot = resolver.snapshotURL(modelID: row.modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))
        request.candidateCatalog.rows[modelKey]?.modelSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        request.benchmarks = [:]
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: resolver,
            runnerFactory: { try CandidateProviderRunner(providerBinaryPath: "/bin/true") },
            prober: RecordingStage1Prober(results: [
                snapshot.path: .feasible(medianTPS: 0, p95TTFTMS: .infinity),
            ]),
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
        XCTAssertTrue(diagnostic.contains("invalid feasible throughput"), diagnostic)
    }

    func testBenchmarksDiagnosesInvalidFeasibleTTFTWithoutTrapping() async throws {
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var request = try makeRequest(modelKey: modelKey)
        let row = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        let revision = try XCTUnwrap(row.modelRevision)
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let snapshot = resolver.snapshotURL(modelID: row.modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))
        request.candidateCatalog.rows[modelKey]?.modelSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        request.benchmarks = [:]
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: resolver,
            runnerFactory: { try CandidateProviderRunner(providerBinaryPath: "/bin/true") },
            prober: RecordingStage1Prober(results: [
                snapshot.path: .feasible(medianTPS: 42, p95TTFTMS: .infinity),
            ]),
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
        XCTAssertTrue(diagnostic.contains("invalid feasible TTFT infinityms"), diagnostic)
    }

    func testReceiptBoundBenchmarkFailsClosedOnInvalidFeasibleMeasurement() async throws {
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var request = try makeRequest(modelKey: modelKey)
        request.hardware.memoryGB = 64
        request.hardware.bandwidthTier = .a
        let row = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        let revision = try XCTUnwrap(row.modelRevision)
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let snapshot = resolver.snapshotURL(modelID: row.modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))
        let artifactSHA = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        request.candidateCatalog.rows[modelKey]?.modelSHA256 = artifactSHA
        request.benchmarks = [:]
        let prefetched = PrefetchedModelArtifact(
            modelKey: modelKey,
            modelID: row.modelID,
            modelRevision: revision,
            candidateRowIdentity: try XCTUnwrap(request.candidateCatalog.rowIdentity(for: modelKey)),
            path: snapshot.path,
            sha256: artifactSHA
        )
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: resolver,
            runnerFactory: { try CandidateProviderRunner(providerBinaryPath: "/bin/true") },
            prober: RecordingStage1Prober(results: [
                snapshot.path: .feasible(medianTPS: .nan, p95TTFTMS: 900),
            ]),
            safetySampler: StaticProbeSafetySampler()
        )

        do {
            _ = try await benchmarker.benchmarks(
                request: request,
                targetContext: 4_000,
                gateTTFTMS: 3_000,
                replicates: 1,
                port: 18_080,
                candidateModelIDs: [row.modelID],
                prefetchedArtifacts: [modelKey: prefetched]
            )
            XCTFail("receipt-bound invalid feasible output must fail before state replacement")
        } catch AutotuneRecommendError.candidateProbeFailed(let failedModelKey, let reason) {
            XCTAssertEqual(failedModelKey, modelKey)
            XCTAssertTrue(reason.contains("invalid feasible throughput nan"), reason)
        }
    }

    func testReceiptBoundBenchmarkFailsClosedWhenCandidateIsNotReady() async throws {
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        var request = try makeRequest(modelKey: modelKey)
        request.hardware.memoryGB = 64
        request.hardware.bandwidthTier = .a
        let row = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        let revision = try XCTUnwrap(row.modelRevision)
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let snapshot = resolver.snapshotURL(modelID: row.modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.bin"))
        let artifactSHA = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        request.candidateCatalog.rows[modelKey]?.modelSHA256 = artifactSHA
        request.benchmarks = [:]
        let prefetched = PrefetchedModelArtifact(
            modelKey: modelKey,
            modelID: row.modelID,
            modelRevision: revision,
            candidateRowIdentity: try XCTUnwrap(request.candidateCatalog.rowIdentity(for: modelKey)),
            path: snapshot.path,
            sha256: artifactSHA
        )
        let readinessFailure = "provider readiness timeout before Stage 1 probe: Could not connect to the server"
        let benchmarker = AutotuneRecommendationBenchmarker(
            artifactResolver: resolver,
            runnerFactory: { try CandidateProviderRunner(providerBinaryPath: "/bin/true") },
            prober: RecordingStage1Prober(results: [
                snapshot.path: .infeasible(reason: readinessFailure, nErr: 1),
            ]),
            safetySampler: StaticProbeSafetySampler()
        )

        do {
            _ = try await benchmarker.benchmarks(
                request: request,
                targetContext: 4_000,
                gateTTFTMS: 3_000,
                replicates: 1,
                port: 18_080,
                candidateModelIDs: [row.modelID],
                prefetchedArtifacts: [modelKey: prefetched]
            )
            XCTFail("receipt-bound upgrade probes must fail before recommendation state is replaced")
        } catch AutotuneRecommendError.candidateProbeFailed(let failedModelKey, let reason) {
            XCTAssertEqual(failedModelKey, modelKey)
            XCTAssertEqual(reason, "\(readinessFailure) (n_err=1)")
        }
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
        XCTAssertTrue(stored.contains(#""hardware_evidence":null"#))
        let data = try XCTUnwrap(stored.data(using: .utf8))
        _ = try JSONSerialization.jsonObject(with: data)  // round-trip parse must not throw
    }

    func testLastRecommendationStateDecodesProbeDiagnostics() throws {
        let json = """
        {"generated_at":"2026-07-02T18:00:00Z","rate_card_version":"v1","demand_rank_version":"v1","candidate_catalog_version":"v1","candidate_catalog_sha256":"abc","benchmark_id":null,"benchmark_generated_at":null,"binary_version":"1.7.5","hardware_identity_hash":"hw","recommended_model":null,"probe_diagnostics":{"qwen3-32b":"tier below minimum"}}
        """
        let decoded = try JSONDecoder().decode(LastRecommendationState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.probeDiagnostics, ["qwen3-32b": "tier below minimum"])
        XCTAssertNil(decoded.hardwareEvidence)
    }

    func testLastRecommendationStateDecodesOldJSONWithoutProbeDiagnostics() throws {
        // Backwards-compat: pre-v1.7.5 last-recommendation.json files must still decode.
        let json = """
        {"generated_at":"2026-07-02T18:00:00Z","rate_card_version":"v1","demand_rank_version":"v1","candidate_catalog_version":"v1","candidate_catalog_sha256":"abc","benchmark_id":null,"benchmark_generated_at":null,"binary_version":"1.7.4","hardware_identity_hash":"hw","recommended_model":null}
        """
        let decoded = try JSONDecoder().decode(LastRecommendationState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.probeDiagnostics, [String: String]())
        XCTAssertNil(decoded.hardwareEvidence)
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

    func testTranscriptCountsBenchmarkedRowsNotRenderedEligibleRows() throws {
        let modelKey = "qwen3-coder-30b-a3b-instruct"
        let diagnosticKey = "diagnostic-benchmarked-row"
        var request = try makeRequest(modelKey: modelKey)
        request.candidateCatalog.rows[diagnosticKey] = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        request.demandRank.rows[diagnosticKey] = DemandRank.Row(
            demandWeight: 0.1,
            rank: 2,
            recommendable: false,
            minProviderTarget: 0
        )
        request.rateCard.rows[diagnosticKey] = try XCTUnwrap(request.rateCard.rows[modelKey])
        request.benchmarks[diagnosticKey] = try fixtureBenchmark(
            modelKey: diagnosticKey,
            request: request,
            sustainedTPS: 80,
            ttftMS: 100,
            swapDetected: false,
            generatedAt: request.generatedAt
        )

        let result = AutotuneRecommendEngine().recommend(request)
        let transcript = result.humanTranscript()

        XCTAssertEqual(result.benchmarkedCount, 2)
        XCTAssertEqual(result.candidates.filter(\.eligible).count, 1)
        XCTAssertTrue(transcript.contains("Benchmarked 2 local benchmark results"), transcript)
    }

    func testTranscriptDoesNotOfferUnreadYPrompt() throws {
        let result = AutotuneRecommendEngine().recommend(try makeRequest())

        XCTAssertFalse(result.humanTranscript().contains("[Y/n]"))
        XCTAssertTrue(result.humanTranscript(configurationApplied: true).contains("macprovider-cli serve"))
    }

    private static let validSpec029ProfilesJSON = """
    {
      "code_completion": {
        "16gb": \(spec029WinnerProfileJSON())
      },
      "short_chat": {
        "8gb": {
          "status": "winner",
          "recommended": {
            "kv_bits": 8,
            "max_context_override": 8192,
            "max_concurrency_override": 1
          },
          "gate_policy": {
            "min_samples": 20,
            "max_p95_ttft_ms": 8000,
            "max_stop_token_leak_rate": 0,
            "min_median_tps": null
          },
          "profile_metrics": {
            "median_tps": null,
            "p95_ttft_ms": 700,
            "stop_token_leak_rate": 0,
            "spec_decode_acceptance_rate": null,
            "sample_count": 20
          },
          "source": "fixture"
        }
      },
      "long_context": {
        "16gb": \(spec029NoWinnerProfileJSON())
      }
    }
    """

    private static func policyIdentityCatalogJSON() -> String {
        """
        {"version":"policy-identity-v1","generated_at":"2026-07-10T20:00:00Z","source":"operator_curated_autotune_candidate_catalog","policy_version":"autotune-policy-v1","rows":{"fixture":{"model_id":"mlx-community/Fixture-4bit","model_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","model_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","min_ram_gb":8,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000,"provenance":{"source":"legacy_unverified","notes":"test fixture"}},"runtime_status":"recommendable","draft_candidates":[{"draft_model":"mlx-community/Fixture-Draft-4bit","draft_model_artifact_sha256":"\(String(repeating: "0", count: 64))"}],"workload_profiles":{"short_chat":{"8gb":{"status":"no_winner","no_winner_reason":"no_cells_evaluated","gate_policy":{"min_samples":20,"max_p95_ttft_ms":8000,"max_stop_token_leak_rate":0,"min_median_tps":null},"profile_metrics":{"median_tps":null,"p95_ttft_ms":null,"stop_token_leak_rate":null,"spec_decode_acceptance_rate":null,"sample_count":0},"source":"shared-schema-corpus"}}}}}}
        """
    }

    private static let spec029DraftCandidatesJSON = """
    [
      {
        "draft_model": "mlx-community/Fixture-Draft-4bit",
        "draft_model_artifact_sha256": "\(String(repeating: "0", count: 64))"
      }
    ]
    """

    private static func spec029CatalogJSON(
        workloadProfilesJSON: String,
        draftCandidatesJSON: String? = nil,
        rowExtraJSON: String? = nil
    ) -> String {
        let draftCandidatesLine = draftCandidatesJSON.map { ",\n              \"draft_candidates\": \($0)" } ?? ""
        let rowExtraLine = rowExtraJSON.map { ",\n              \($0)" } ?? ""
        return """
        {
          "version": "fixture-spec029",
          "generated_at": "2026-07-09T00:00:00Z",
          "source": "operator_curated_autotune_candidate_catalog",
          "policy_version": "autotune-policy-v1",
          "rows": {
            "fixture-model": {
              "model_id": "mlx-community/Fixture-Model-4bit",
              "model_revision": "\(String(repeating: "a", count: 40))",
              "model_sha256": "\(String(repeating: "b", count: 64))",
              "min_ram_gb": 12,
              "min_bandwidth_tier": "C",
              "bench_gate": {
                "min_sustained_tps": 1,
                "max_4k_ttft_ms": 1000,
                "provenance": {
                  "source": "legacy_unverified",
                  "notes": "test fixture"
                }
              },
              "runtime_status": "recommendable"\(draftCandidatesLine),
              "workload_profiles": \(workloadProfilesJSON)\(rowExtraLine)
            }
          }
        }
        """
    }

    private static func spec029WinnerProfileJSON(
        draftHash: String = String(repeating: "0", count: 64),
        numDraftTokens: Int = 4,
        maxContext: Int = 20_000,
        maxConcurrency: Int = 1,
        maxP95TTFTMS: Int = 12_000,
        p95TTFTMS: Int = 2_400,
        stopTokenLeakRate: Double = 0,
        source: String = "spec029-report-fixture",
        candidateSource: String? = "research_fixture:spec029-test"
    ) -> String {
        let candidateSourceLine = candidateSource.map { ",\n          \"candidate_source\": \"\($0)\"" } ?? ""
        return """
        {
          "status": "winner",
          "recommended": {
            "kv_bits": 4,
            "max_context_override": \(maxContext),
            "max_concurrency_override": \(maxConcurrency),
            "draft_model": "mlx-community/Fixture-Draft-4bit",
            "draft_model_artifact_sha256": "\(draftHash)",
            "num_draft_tokens": \(numDraftTokens)
          },
          "gate_policy": {
            "min_samples": 20,
            "max_p95_ttft_ms": \(maxP95TTFTMS),
            "max_stop_token_leak_rate": 0,
            "min_median_tps": null
          },
          "profile_metrics": {
            "median_tps": 8.5,
            "p95_ttft_ms": \(p95TTFTMS),
            "stop_token_leak_rate": \(stopTokenLeakRate),
            "spec_decode_acceptance_rate": 0.42,
            "sample_count": 20
          },
          "source": "\(source)"\(candidateSourceLine)
        }
        """
    }

    private static func spec029NoWinnerProfileJSON(reason: String = "insufficient_samples", sampleCount: Int = 7) -> String {
        """
        {
          "status": "no_winner",
          "no_winner_reason": "\(reason)",
          "gate_policy": {
            "min_samples": 20,
            "max_p95_ttft_ms": 60000,
            "max_stop_token_leak_rate": 0,
            "min_median_tps": null
          },
          "profile_metrics": {
            "median_tps": null,
            "p95_ttft_ms": null,
            "stop_token_leak_rate": null,
            "spec_decode_acceptance_rate": null,
            "sample_count": \(sampleCount)
          },
          "source": "fixture"
        }
        """
    }

    private func makeMultiCandidateRequest(modelKeys: [String]) throws -> AutotuneRecommendRequest {
        var demand = try AutotuneStaticInputs.decodeDemandRank(Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8))
        var catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        var rateCard = try AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8))
        let keySet = Set(modelKeys)
        let normalizedKeys = Set(modelKeys.map(AutotuneModelKeyNormalizer.normalize))
        demand.rows = demand.rows.filter { keySet.contains($0.key) }
        catalog.rows = catalog.rows.filter { keySet.contains($0.key) }
        rateCard.rows = rateCard.rows.filter { keySet.contains($0.key) || normalizedKeys.contains($0.key) }

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
        var benchmarks: [String: CandidateBenchmark] = [:]
        for modelKey in modelKeys {
            let candidate = try XCTUnwrap(catalog.rows[modelKey], "missing catalog row \(modelKey)")
            benchmarks[modelKey] = CandidateBenchmark(
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
        }
        return AutotuneRecommendRequest(
            hardware: hardware,
            demandRank: demand,
            candidateCatalog: catalog,
            candidateCatalogSHA256: catalogSHA,
            rateCard: rateCard,
            benchmarks: benchmarks,
            warnings: [],
            generatedAt: generatedAt,
            donorMode: false,
            buyerTTFTCeilingMS: 0
        )
    }

    private func fixtureBenchmark(
        modelKey: String,
        request: AutotuneRecommendRequest,
        sustainedTPS: Double,
        ttftMS: Int,
        swapDetected: Bool,
        generatedAt: Date
    ) throws -> CandidateBenchmark {
        let candidate = try XCTUnwrap(request.candidateCatalog.rows[modelKey])
        return CandidateBenchmark(
            modelKey: modelKey,
            sustainedTPS: sustainedTPS,
            ttftMS: ttftMS,
            swapDetected: swapDetected,
            thermalThrottleDetected: false,
            artifactSHA256: candidate.modelSHA256 ?? String(repeating: "f", count: 64),
            modelArtifactPath: "/tmp/\(modelKey)",
            benchmarkID: "bench-2026-07-23-\(modelKey)",
            generatedAt: generatedAt,
            candidateCatalogSHA256: request.candidateCatalogSHA256,
            binaryVersion: request.hardware.binaryVersion,
            modelID: candidate.modelID,
            hardwareIdentityHash: request.hardware.hardwareIdentityHash
        )
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
            donorMode: false,
            buyerTTFTCeilingMS: 0
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
    private(set) var probedArtifactBindings: [CandidateArtifactBinding?] = []

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
        try await probe(
            model: model,
            port: port,
            runner: runner,
            targetContext: targetContext,
            gateTTFTMS: gateTTFTMS,
            replicates: replicates,
            artifactBinding: nil
        )
    }

    func probe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int,
        artifactBinding: CandidateArtifactBinding?
    ) async throws -> Stage1ProbeResult {
        probedModels.append(model)
        probedArtifactBindings.append(artifactBinding)
        return results[model] ?? .infeasible(reason: "missing stub probe result", nErr: 1)
    }
}

private struct StaticProbeSafetySampler: ProbeSafetySampling {
    func sample() -> ProbeSafetySample {
        ProbeSafetySample(pressureLevel: .normal, thermalState: .nominal)
    }
}
