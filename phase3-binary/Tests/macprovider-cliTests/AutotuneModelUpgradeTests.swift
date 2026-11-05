import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-023-R028 / AC-52: stale-recommendation model upgrade.
final class AutotuneModelUpgradeTests: XCTestCase {
    private static let threeBKey = "meta-llama/llama-3.2-3b-instruct"
    private static let llama8BKey = "meta-llama/llama-3.1-8b-instruct"
    private static let qwen8BKey = "qwen3-8b"

    private static let defaultTPS: [String: Double] = [
        threeBKey: 38.5,
        llama8BKey: 17.2,
        qwen8BKey: 8.45,
    ]

    // MARK: decision

    func testStrictlyHigherScoreSwitches() throws {
        let request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        let result = AutotuneRecommendEngine().recommend(request)
        let selected = try XCTUnwrap(result.selectedCandidate)
        let incumbent = try XCTUnwrap(result.allCandidates.first { $0.catalogKey == Self.qwen8BKey })
        XCTAssertEqual(selected.catalogKey, Self.llama8BKey)
        XCTAssertTrue(incumbent.eligible)
        XCTAssertGreaterThan(selected.orderingScore, incumbent.orderingScore)

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey)

        XCTAssertEqual(decision, .switchModel(
            from: Self.qwen8BKey,
            to: Self.llama8BKey,
            reason: "strictly_higher_expected_earnings"
        ))
        XCTAssertEqual(
            AutotuneModelUpgrade.configTarget(
                for: decision,
                result: result,
                incumbentKey: Self.qwen8BKey,
                benchmarks: request.benchmarks
            )?.catalogKey,
            Self.llama8BKey
        )
    }

    func testPolicyDemotedIncumbentSwitchesEvenThoughItOutscores() throws {
        let request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        let result = AutotuneRecommendEngine().recommend(request)
        let incumbent = try XCTUnwrap(result.allCandidates.first { $0.catalogKey == Self.threeBKey })
        XCTAssertGreaterThan(incumbent.orderingScore, try XCTUnwrap(result.selectedCandidate).orderingScore)

        XCTAssertEqual(
            AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.threeBKey),
            .switchModel(from: Self.threeBKey, to: Self.llama8BKey, reason: "incumbent_policy_demoted")
        )
    }

    func testEqualScoreKeepsIncumbentAndReappliesItsRow() throws {
        let request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        var result = AutotuneRecommendEngine().recommend(request)
        let selectedScore = try XCTUnwrap(result.selectedCandidate).orderingScore
        let index = try XCTUnwrap(result.allCandidates.firstIndex { $0.catalogKey == Self.qwen8BKey })
        result.allCandidates[index].orderingScore = selectedScore

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey)

        XCTAssertEqual(decision, .keep(reason: "not_strictly_better"))
        XCTAssertEqual(
            AutotuneModelUpgrade.configTarget(
                for: decision,
                result: result,
                incumbentKey: Self.qwen8BKey,
                benchmarks: request.benchmarks
            )?.catalogKey,
            Self.qwen8BKey
        )
    }

    func testWorseAlternativeKeepsSelectedIncumbent() throws {
        let request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        let result = AutotuneRecommendEngine().recommend(request)

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.llama8BKey)

        XCTAssertEqual(decision, .keep(reason: "incumbent_selected"))
        XCTAssertEqual(
            AutotuneModelUpgrade.configTarget(
                for: decision,
                result: result,
                incumbentKey: Self.llama8BKey,
                benchmarks: request.benchmarks
            )?.catalogKey,
            Self.llama8BKey
        )
    }

    func testBetterModelFailingBenchmarkAdmissionKeepsIncumbent() throws {
        var request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        request.benchmarks[Self.llama8BKey]?.swapDetected = true
        let result = AutotuneRecommendEngine().recommend(request)

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey)

        XCTAssertEqual(decision, .keep(reason: "incumbent_selected"))
        XCTAssertEqual(
            AutotuneModelUpgrade.configTarget(
                for: decision,
                result: result,
                incumbentKey: Self.qwen8BKey,
                benchmarks: request.benchmarks
            )?.catalogKey,
            Self.qwen8BKey
        )
    }

    func testBetterModelWithoutPrefetchedBenchmarkKeepsIncumbent() throws {
        var tps = Self.defaultTPS
        tps[Self.llama8BKey] = nil
        let request = try makeSmallDenseRequest(benchmarkTPS: tps)
        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(
            AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey),
            .keep(reason: "incumbent_selected")
        )
    }

    func testNoEligibleRowWritesNoConfig() throws {
        var request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        for key in request.benchmarks.keys {
            request.benchmarks[key]?.thermalThrottleDetected = true
        }
        let result = AutotuneRecommendEngine().recommend(request)

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey)

        XCTAssertEqual(decision, .keep(reason: "no_eligible_candidate"))
        XCTAssertNil(AutotuneModelUpgrade.configTarget(
            for: decision,
            result: result,
            incumbentKey: Self.qwen8BKey,
            benchmarks: request.benchmarks
        ))
    }

    func testIneligibleIncumbentSwitchesToAdmittedRow() throws {
        var request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        request.benchmarks[Self.qwen8BKey]?.swapDetected = true
        let result = AutotuneRecommendEngine().recommend(request)

        XCTAssertEqual(
            AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey),
            .switchModel(from: Self.qwen8BKey, to: Self.llama8BKey, reason: "incumbent_not_eligible")
        )
    }

    // MARK: prefetch

    func testIncumbentPrefetchFailureFailsTheRunAndOtherFailuresAreDropped() throws {
        let incumbent = Self.artifact(key: Self.qwen8BKey, modelID: "mlx-community/Qwen3-8B-4bit")
        let other = Self.artifact(key: Self.threeBKey, modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit")
        let dropped = ArtifactPrefetchOutcomes(
            artifacts: [incumbent],
            diagnostics: [PrefetchDiagnostic(modelID: other.modelID, reason: "disk full")],
            matchedModelIDs: [incumbent.modelID, other.modelID]
        )
        XCTAssertEqual(
            try AutotuneModelUpgrade.verifiedUpgradeArtifacts(dropped, incumbentModelID: incumbent.modelID),
            [incumbent]
        )

        let incumbentFailed = ArtifactPrefetchOutcomes(
            artifacts: [other],
            diagnostics: [PrefetchDiagnostic(modelID: incumbent.modelID, reason: "hash mismatch")],
            matchedModelIDs: [incumbent.modelID, other.modelID]
        )
        XCTAssertThrowsError(
            try AutotuneModelUpgrade.verifiedUpgradeArtifacts(incumbentFailed, incumbentModelID: incumbent.modelID)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("hash mismatch"))
        }
    }

    func testCandidatePlanCoversTheSignedCatalogForTheRAMClass() throws {
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        let demand = try AutotuneStaticInputs.decodeDemandRank(Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8))
        let rateCard = try AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8))
        let hardware = Self.hardware(memoryGB: 32)

        let plan = AutotuneModelUpgrade.candidateModelIDs(
            catalog: catalog,
            demandRank: demand,
            rateCard: rateCard,
            hardware: hardware,
            incumbentKey: Self.threeBKey
        )

        XCTAssertTrue(plan.contains("mlx-community/Llama-3.2-3B-Instruct-4bit"))
        XCTAssertTrue(plan.contains("mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"))
        XCTAssertGreaterThan(plan.count, 2, "an upgrade must not re-confirm only the incumbent")
        for (key, row) in catalog.rows where plan.contains(row.modelID) && key != Self.threeBKey {
            XCTAssertLessThanOrEqual(row.minRAMGB, 32 - AutotuneRecommendEngine.safetyMarginGB, key)
            XCTAssertEqual(row.runtimeStatus, "recommendable", key)
        }
        XCTAssertFalse(plan.contains("mlx-community/GLM-4.5-Air-4bit"))
        XCTAssertFalse(plan.contains("prism-ml/Ternary-Bonsai-2-2B-mlx-2bit"))
    }

    // MARK: pins

    func testExplicitPinsKeepTheModel() {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-upgrade-test.yaml")
        config.modelCatalogKey = Self.qwen8BKey
        config.modelCatalogModelID = "mlx-community/Qwen3-8B-4bit"
        XCTAssertNil(AutotuneModelUpgrade.pinReason(config: config))

        var donor = config
        donor.donorMode = true
        XCTAssertEqual(AutotuneModelUpgrade.pinReason(config: donor), "donor_mode")

        var pool = config
        pool.poolModelID = "pool-model"
        XCTAssertEqual(AutotuneModelUpgrade.pinReason(config: pool), "pool_model_id")

        var unsigned = config
        unsigned.modelCatalogKey = nil
        unsigned.modelCatalogModelID = nil
        XCTAssertEqual(AutotuneModelUpgrade.pinReason(config: unsigned), "no_signed_catalog_identity")

        XCTAssertEqual(AutotuneModelUpgrade.pinReason(config: nil), "config_unreadable")
    }

    func testIncumbentResolvesByCatalogKeyThenUniqueModelID() throws {
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-upgrade-test.yaml")
        config.modelCatalogKey = Self.qwen8BKey
        XCTAssertEqual(AutotuneModelUpgrade.incumbentCatalogKey(config: config, catalog: catalog), Self.qwen8BKey)
        config.modelCatalogKey = "retired/key"
        config.modelCatalogModelID = "mlx-community/Llama-3.2-3B-Instruct-4bit"
        XCTAssertEqual(AutotuneModelUpgrade.incumbentCatalogKey(config: config, catalog: catalog), Self.threeBKey)
        config.modelCatalogModelID = "unknown/model"
        XCTAssertNil(AutotuneModelUpgrade.incumbentCatalogKey(config: config, catalog: catalog))
    }

    // MARK: drain

    func testIdleWaitWaitsForZeroInFlightAndGivesUpWhenBusy() async {
        let responses = SequencedStatus([
            ["requests_in_flight": 1, "requests_queued": 0],
            ["requests_in_flight": 0, "requests_queued": 1],
            ["requests_in_flight": 0, "requests_queued": 0],
        ])
        let idle = await AutotuneModelUpgrade.waitForLocalProviderIdle(
            port: 8080,
            timeoutSeconds: 60,
            fetchStatus: { _ in responses.next() },
            sleep: { _ in },
            now: Date.init
        )
        XCTAssertTrue(idle)
        XCTAssertEqual(responses.calls, 3)

        let clock = FakeClock()
        let busy = await AutotuneModelUpgrade.waitForLocalProviderIdle(
            port: 8080,
            timeoutSeconds: 5,
            fetchStatus: { _ in ["requests_in_flight": 2, "requests_queued": 0] },
            sleep: { _ in clock.advance(1) },
            now: { clock.now }
        )
        XCTAssertFalse(busy, "a provider that stays busy is not stopped")

        let unreachable = await AutotuneModelUpgrade.waitForLocalProviderIdle(
            port: 8080,
            timeoutSeconds: 5,
            fetchStatus: { _ in throw URLError(.cannotConnectToHost) },
            sleep: { _ in },
            now: Date.init
        )
        XCTAssertTrue(unreachable)
    }

    func testIdleWaitCeilingIsTheWarmSwitchDrainBound() {
        XCTAssertEqual(AutotuneModelUpgrade.idleWaitCeilingSeconds, 600)
    }

    // MARK: entry points

    func testUpgradeFlagValidation() {
        XCTAssertThrowsError(try AutotuneCommand.parse(["--upgrade", "--apply"]))
        XCTAssertThrowsError(try AutotuneCommand.parse(["--recommend", "--upgrade"]))
        XCTAssertNoThrow(try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply"]))
        XCTAssertNoThrow(try AutotuneCommand.parse([
            "--recommend", "--upgrade", "--prefetch", "--prefetch-receipt", "/tmp/receipt.json",
        ]))
        XCTAssertNoThrow(try AutotuneCommand.parse([
            "--recommend", "--upgrade", "--apply", "--prefetch-receipt", "/tmp/receipt.json",
        ]))
        XCTAssertNoThrow(try AutotuneCommand.parse([
            "--recommend", "--upgrade", "--apply", "--donor-mode", "--prefetch-receipt", "/tmp/receipt.json",
        ]))
        XCTAssertThrowsError(try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply", "--donor-mode"]))
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend", "--upgrade", "--apply", "--candidate-models", "mlx-community/Qwen3-8B-4bit",
        ]))
        XCTAssertThrowsError(try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply", "--calibrate-context"]))
        XCTAssertThrowsError(try AutotuneCommand.parse(["--recommend", "--upgrade", "--freshness-check"]))
        // The pinned (pre-R028) prefetch still requires its allowlist.
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend", "--prefetch", "--prefetch-receipt", "/tmp/receipt.json",
        ]))
    }

    func testUpdateRunsTheUnpinnedUpgradeWithTheInstalledBinary() {
        XCTAssertEqual(
            AutotuneModelUpgrade.afterUpdateArguments(configPath: nil),
            ["autotune", "--recommend", "--upgrade", "--apply"]
        )
        XCTAssertEqual(
            AutotuneModelUpgrade.afterUpdateArguments(configPath: "/tmp/config.yaml"),
            ["autotune", "--recommend", "--upgrade", "--apply", "--config", "/tmp/config.yaml"]
        )
    }

    // MARK: helpers

    private func makeSmallDenseRequest(benchmarkTPS: [String: Double]) throws -> AutotuneRecommendRequest {
        var demand = try AutotuneStaticInputs.decodeDemandRank(Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8))
        var catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        let rateCard = try AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8))
        let keep: Set<String> = [Self.threeBKey, Self.llama8BKey, Self.qwen8BKey]
        demand.rows = demand.rows.filter { keep.contains($0.key) }
        catalog.rows = catalog.rows.filter { keep.contains($0.key) }
        let catalogSHA = AutotuneStaticInputs.candidateCatalogSHA256(bytes: Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        let generatedAt = ISO8601DateFormatter.autotuneInternet.date(from: "2026-11-05T00:00:00Z")!
        let hardware = Self.hardware(memoryGB: 16)
        var benchmarks: [String: CandidateBenchmark] = [:]
        for (key, tps) in benchmarkTPS {
            guard let candidate = catalog.rows[key] else { continue }
            benchmarks[key] = CandidateBenchmark(
                modelKey: key,
                sustainedTPS: tps,
                ttftMS: 1_000,
                swapDetected: false,
                thermalThrottleDetected: false,
                artifactSHA256: candidate.modelSHA256 ?? String(repeating: "f", count: 64),
                modelArtifactPath: "/tmp/\(key)",
                benchmarkID: "bench-r028-\(key)",
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

    private static func hardware(memoryGB: Int) -> AutotuneRecommendHardware {
        AutotuneRecommendHardware(
            machine: "Mac-test",
            chip: "Apple M5",
            memoryGB: memoryGB,
            bandwidthTier: .c,
            osVersion: "macOS 15",
            binaryVersion: "test-bin",
            diversificationID: "diversification",
            hardwareIdentityHash: "hardware"
        )
    }

    private static func artifact(key: String, modelID: String) -> PrefetchedModelArtifact {
        PrefetchedModelArtifact(
            modelKey: key,
            modelID: modelID,
            modelRevision: "rev",
            candidateRowIdentity: "row-\(key)",
            path: "/tmp/\(key)",
            sha256: String(repeating: "a", count: 64)
        )
    }
}

private final class SequencedStatus: @unchecked Sendable {
    private var responses: [[String: Any]]
    private(set) var calls = 0

    init(_ responses: [[String: Any]]) {
        self.responses = responses
    }

    func next() -> [String: Any] {
        calls += 1
        return responses.isEmpty ? [:] : responses.removeFirst()
    }
}

private final class FakeClock: @unchecked Sendable {
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
