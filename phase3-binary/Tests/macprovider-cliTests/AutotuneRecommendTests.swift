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
        XCTAssertFalse(result.warnings.contains(.noEligiblePaidModel))
        XCTAssertGreaterThan(try XCTUnwrap(result.candidates.first?.expectedNetUSDPerHour), 0.0050)
    }

    func testAllRowsFailingEligibilityEmitsNoEligibleWarning() throws {
        var request = try makeRequest()
        request.benchmarks = [:]

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel)
        XCTAssertTrue(result.warnings.contains(.noEligiblePaidModel))
        XCTAssertTrue(result.humanTranscript().contains("Recommendation: donor mode only"))
        XCTAssertTrue(result.humanTranscript().contains("Best compatible option: none"))
    }

    func testBelowThresholdEmitsRecommendationBelowThreshold() throws {
        var request = try makeRequest()
        request.rateCard.rows["qwen3-coder-30b-a3b-instruct"]?.completionRatePerMtok = 1_000

        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertNil(result.recommendedModel)
        XCTAssertTrue(result.warnings.contains(.recommendationBelowThreshold))
    }

    func testDonorModeDoesNotTurnListedRowsIntoPaidDefaults() throws {
        var request = try makeRequest(modelKey: "qwen3-32b")
        request.donorMode = true
        request.hardware.bandwidthTier = .a

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

    func testNoCoordinatorDefaultFallbackUnlessCandidateKeyIsDefault() throws {
        let rateCard = try AutotuneStaticInputs.decodeRateCard(Data("""
        {"version":"test","generated_at":"2026-07-01T00:00:00Z","usd_per_million_credits":1.0,"rows":{"default":{"prompt_rate_per_mtok":1,"completion_rate_per_mtok":1,"provider_share_bps":9000,"global_multiplier_ppm":1000000}}}
        """.utf8))

        XCTAssertNil(rateCard.rowForRecommendation(modelKey: "qwen3-coder-30b-a3b-instruct"))
        XCTAssertNil(rateCard.rowForRecommendation(modelKey: "DEFAULT"))
        XCTAssertNil(rateCard.rowForRecommendation(modelKey: " default "))
        XCTAssertNil(rateCard.rowForRecommendation(modelKey: "mlx-community/default-4bit"))
        XCTAssertNotNil(rateCard.rowForRecommendation(modelKey: "default"))
    }

    func testNormalizedRateCardLookupRecordsNormalizedKey() throws {
        let rateCard = try AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8))

        let row = rateCard.rowForRecommendation(modelKey: "mlx-community/gpt-oss-20b-MXFP4-Q8")

        XCTAssertEqual(row?.key, "openai/gpt-oss-20b")
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

    func testRecommendedCandidateOutsideTopFiveIsStillCarriedForApplyLookup() throws {
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

        var foundDiversifiedSelectionOutsideTopFive = false
        for seed in 0..<500 {
            request.hardware.diversificationID = "seed-\(seed)"
            let result = AutotuneRecommendEngine().recommend(request)
            guard let recommendedModel = result.recommendedModel,
                  let selected = result.selectedCandidate,
                  selected.model == recommendedModel
            else {
                continue
            }
            if selected.rank > 5 {
                foundDiversifiedSelectionOutsideTopFive = true
                XCTAssertFalse(result.candidates.contains { $0.model == recommendedModel })
                XCTAssertEqual(result.candidates.map(\.rank), [1, 2, 3, 4, 5])
                XCTAssertFalse(result.jsonString().contains("selectedCandidate"))
                XCTAssertFalse(result.jsonString().contains("selected_candidate"))
                break
            }
        }
        XCTAssertTrue(foundDiversifiedSelectionOutsideTopFive)
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

    func testMinProviderTargetDoesNotAffectScoringOrEligibility() throws {
        var request = try makeRequest()
        let first = AutotuneRecommendEngine().recommend(request)
        request.demandRank.rows["qwen3-coder-30b-a3b-instruct"]?.minProviderTarget = 999_999
        let second = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(first.recommendedModel, second.recommendedModel)
        XCTAssertEqual(first.candidates.first?.expectedNetUSDPerHour, second.candidates.first?.expectedNetUSDPerHour)
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
        XCTAssertLessThan(try XCTUnwrap(json.range(of: #""recommended_model":"#)?.lowerBound), try XCTUnwrap(json.range(of: #""candidates":"#)?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(json.range(of: #""candidates":"#)?.lowerBound), try XCTUnwrap(json.range(of: #""comparison":"#)?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(json.range(of: #""comparison":"#)?.lowerBound), try XCTUnwrap(json.range(of: #""warnings":"#)?.lowerBound))
    }

    func testSignedStaticFallbackAndStaleWarnings() async throws {
        let validFetched = Data(AutotuneStaticInputs.bakedDemandRankJSON
            .replacingOccurrences(of: "baked-2026-07-02", with: "fetched-2026-07-10")
            .replacingOccurrences(of: "2026-07-01T00:00:00Z", with: "2026-07-10T00:00:00Z")
            .utf8)
        let sidecar = Data(#"{"key_id":"streamvc-autotune-static-v2","alg":"ed25519","signature":"AA=="}"#.utf8)
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
            .replacingOccurrences(of: "baked-2026-07-02", with: "fetched-2026-07-10")
            .replacingOccurrences(of: "2026-07-01T00:00:00Z", with: "2026-07-10T00:00:00Z")
            .utf8)
        let sidecar = Data(#"{"key_id":"streamvc-autotune-static-v2","alg":"ed25519","signature":"AA==","extra":true}"#.utf8)
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
        let keyData = Data(base64Encoded: AutotuneStaticInputs.autotune_static_json_ed25519_v2)

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

    func testBenchmarkingFailsClosedOnArtifactHashMismatch() async throws {
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

        do {
            _ = try await benchmarker.benchmarks(
                request: request,
                targetContext: 4_000,
                gateTTFTMS: 3_000,
                replicates: 1,
                port: 18080
            )
            XCTFail("artifact mismatch must fail closed")
        } catch AutotuneRecommendError.invalidArtifact {
            // expected
        }
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

        let benchmarks = try await benchmarker.benchmarks(
            request: request,
            targetContext: 4_000,
            gateTTFTMS: 3_000,
            replicates: 1,
            port: 18080
        )

        XCTAssertNotNil(benchmarks[modelKey])
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

    func testElectricityInputReducesExpectedNet() throws {
        var request = try makeRequest()
        let withoutElectricity = AutotuneRecommendEngine().recommend(request)
        request.electricityUSDPerKWH = 1.0

        let withElectricity = AutotuneRecommendEngine().recommend(request)

        XCTAssertLessThan(
            try XCTUnwrap(withElectricity.candidates.first?.expectedNetUSDPerHour),
            try XCTUnwrap(withoutElectricity.candidates.first?.expectedNetUSDPerHour)
        )
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
        {"generated_at":"2026-07-01T00:00:00Z","rate_card_version":"old","demand_rank_version":"baked-2026-07-02","candidate_catalog_version":"baked-2026-07-02","candidate_catalog_sha256":"old","benchmark_id":"bench-1","benchmark_generated_at":"2026-07-01T00:00:00Z","binary_version":"test","hardware_identity_hash":"old","recommended_model":"qwen3-coder-30b-a3b-instruct"}
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
        {"generated_at":"2026-07-01T00:00:00Z","rate_card_version":"baked-2026-07-02","demand_rank_version":"baked-2026-07-02","candidate_catalog_version":"baked-2026-07-02","candidate_catalog_sha256":"old","benchmark_id":"bench-1","benchmark_generated_at":"2026-07-01T00:00:00Z","binary_version":"test","hardware_identity_hash":"old","recommended_model":"qwen3-coder-30b-a3b-instruct"}
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
        {"generated_at":"2026-07-02T00:00:00Z","rate_card_version":"baked-2026-07-02","demand_rank_version":"baked-2026-07-02","candidate_catalog_version":"baked-2026-07-02","candidate_catalog_sha256":"\(catalogSHA)","benchmark_id":"bench-1","benchmark_generated_at":"2026-07-02T00:00:00Z","binary_version":"test","hardware_identity_hash":"\(identity.cacheIdentityHash)","recommended_model":"qwen3-coder-30b-a3b-instruct"}
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

    private func makeRequest(modelKey: String = "qwen3-coder-30b-a3b-instruct") throws -> AutotuneRecommendRequest {
        var demand = try AutotuneStaticInputs.decodeDemandRank(Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8))
        var catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        var rateCard = try AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8))
        demand.rows = demand.rows.filter { $0.key == modelKey }
        catalog.rows = catalog.rows.filter { $0.key == modelKey }
        rateCard.rows = rateCard.rows.filter { $0.key == modelKey }

        if modelKey == "google-gemma-4-26b-a4b-it" {
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
            electricityUSDPerKWH: nil,
            assumedUtilization: 1.0,
            availabilityHoursPerDay: 24,
            donorMode: false
        )
    }

    private static func date(_ raw: String) -> Date {
        ISO8601DateFormatter.autotuneInternet.date(from: raw)!
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
