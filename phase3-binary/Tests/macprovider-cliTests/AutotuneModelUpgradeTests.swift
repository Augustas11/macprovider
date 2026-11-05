import ArgumentParser
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

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog)

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
            AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.threeBKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog),
            .switchModel(from: Self.threeBKey, to: Self.llama8BKey, reason: "incumbent_policy_demoted")
        )
    }

    func testEqualScoreKeepsIncumbentAndReappliesItsRow() throws {
        let request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        var result = AutotuneRecommendEngine().recommend(request)
        let selectedScore = try XCTUnwrap(result.selectedCandidate).orderingScore
        let index = try XCTUnwrap(result.allCandidates.firstIndex { $0.catalogKey == Self.qwen8BKey })
        result.allCandidates[index].orderingScore = selectedScore

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog)

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

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.llama8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog)

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

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog)

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
            AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog),
            .keep(reason: "incumbent_selected")
        )
    }

    func testNoEligibleRowWritesNoConfig() throws {
        var request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        for key in request.benchmarks.keys {
            request.benchmarks[key]?.thermalThrottleDetected = true
        }
        let result = AutotuneRecommendEngine().recommend(request)

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog)

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
            AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog),
            .switchModel(from: Self.qwen8BKey, to: Self.llama8BKey, reason: "incumbent_not_eligible")
        )
    }

    // MARK: hard bench gate (auto-switch only)

    func testChallengerBelowTPSGateNeverAutoSwitches() throws {
        var tps = Self.defaultTPS
        tps[Self.llama8BKey] = 12.0
        tps[Self.qwen8BKey] = 2.0
        let request = try makeSmallDenseRequest(benchmarkTPS: tps)
        let result = AutotuneRecommendEngine().recommend(request)
        // Manual --recommend keeps the gate advisory and still selects it.
        XCTAssertEqual(result.selectedCandidate?.catalogKey, Self.llama8BKey)
        XCTAssertTrue(result.warnings.contains(.tpsBelowGate))

        let decision = AutotuneModelUpgrade.decide(
            result: result,
            incumbentKey: Self.qwen8BKey,
            benchmarks: request.benchmarks,
            catalog: request.candidateCatalog
        )
        XCTAssertEqual(decision, .keep(reason: "candidate_below_bench_gate"))
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

    func testChallengerAboveTTFTGateNeverAutoSwitches() throws {
        var request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        let ceiling = try XCTUnwrap(request.candidateCatalog.rows[Self.llama8BKey]).benchGate.max4KTTFTMS
        request.benchmarks[Self.llama8BKey]?.ttftMS = ceiling + 1
        let result = AutotuneRecommendEngine().recommend(request)
        XCTAssertEqual(result.selectedCandidate?.catalogKey, Self.llama8BKey)

        XCTAssertEqual(
            AutotuneModelUpgrade.decide(
                result: result,
                incumbentKey: Self.qwen8BKey,
                benchmarks: request.benchmarks,
                catalog: request.candidateCatalog
            ),
            .keep(reason: "candidate_below_bench_gate")
        )
    }

    func testFirstGateClearingChallengerWinsWhenTheTopRowFailsTheGate() throws {
        var tps = Self.defaultTPS
        tps[Self.llama8BKey] = 12.0
        var request = try makeSmallDenseRequest(benchmarkTPS: tps)
        request.benchmarks[Self.qwen8BKey]?.swapDetected = true
        let result = AutotuneRecommendEngine().recommend(request)
        XCTAssertEqual(result.selectedCandidate?.catalogKey, Self.llama8BKey)

        let decision = AutotuneModelUpgrade.decide(
            result: result,
            incumbentKey: Self.qwen8BKey,
            benchmarks: request.benchmarks,
            catalog: request.candidateCatalog
        )
        XCTAssertEqual(decision, .switchModel(from: Self.qwen8BKey, to: Self.threeBKey, reason: "incumbent_not_eligible"))
        XCTAssertEqual(
            AutotuneModelUpgrade.configTarget(
                for: decision,
                result: result,
                incumbentKey: Self.qwen8BKey,
                benchmarks: request.benchmarks
            )?.catalogKey,
            Self.threeBKey
        )
    }

    func testNoGateClearingChallengerKeepsAnIneligibleIncumbentWithoutConfig() throws {
        var request = try makeSmallDenseRequest(benchmarkTPS: [Self.llama8BKey: 12.0, Self.qwen8BKey: 8.45])
        request.benchmarks[Self.qwen8BKey]?.swapDetected = true
        let result = AutotuneRecommendEngine().recommend(request)
        let decision = AutotuneModelUpgrade.decide(
            result: result,
            incumbentKey: Self.qwen8BKey,
            benchmarks: request.benchmarks,
            catalog: request.candidateCatalog
        )
        XCTAssertEqual(decision, .keep(reason: "candidate_below_bench_gate"))
        XCTAssertNil(AutotuneModelUpgrade.configTarget(
            for: decision,
            result: result,
            incumbentKey: Self.qwen8BKey,
            benchmarks: request.benchmarks
        ))
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

    func testCachedProbeBelowTheGateIsNotDownloadedButTheIncumbentIs() throws {
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        let demand = try AutotuneStaticInputs.decodeDemandRank(Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8))
        let rateCard = try AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8))
        let slowKey = "qwen/qwen3.6-27b"
        let slow = try XCTUnwrap(catalog.rows[slowKey])
        let incumbent = try XCTUnwrap(catalog.rows[Self.threeBKey])
        let cached = [
            slowKey: Self.benchmark(key: slowKey, row: slow, tps: 5.0),
            Self.threeBKey: Self.benchmark(key: Self.threeBKey, row: incumbent, tps: 1.0),
        ]

        let plan = AutotuneModelUpgrade.candidateModelIDs(
            catalog: catalog,
            demandRank: demand,
            rateCard: rateCard,
            hardware: Self.hardware(memoryGB: 32),
            incumbentKey: Self.threeBKey,
            cachedBenchmarks: cached
        )

        XCTAssertFalse(plan.contains(slow.modelID))
        XCTAssertTrue(plan.contains(incumbent.modelID))
        XCTAssertTrue(plan.contains("mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"))
    }

    func testPrefetchOrderPutsTheIncumbentFirstThenLikelyWinners() throws {
        var request = try makeSmallDenseRequest(benchmarkTPS: [:])
        let catalog = request.candidateCatalog
        let uncached = AutotuneModelUpgrade.prefetchOrder(request: request, incumbentKey: Self.qwen8BKey, cachedBenchmarks: [:])
        XCTAssertEqual(uncached.first, Self.qwen8BKey)
        XCTAssertEqual(Set(uncached), Set(catalog.rows.keys))
        XCTAssertEqual(uncached.count, catalog.rows.count)

        // A cached probe that measured far above the catalog estimate moves
        // its row ahead of every uncached row.
        let lastKey = try XCTUnwrap(uncached.last)
        let row = try XCTUnwrap(catalog.rows[lastKey])
        request.generatedAt = Date()
        let promoted = AutotuneModelUpgrade.prefetchOrder(
            request: request,
            incumbentKey: Self.qwen8BKey,
            cachedBenchmarks: [lastKey: Self.benchmark(key: lastKey, row: row, tps: 10_000)]
        )
        XCTAssertEqual(Array(promoted.prefix(2)), [Self.qwen8BKey, lastKey])
    }

    func testPrefetchFollowsTheOrderRecordsRunDownloadsAndCleanupRemovesOnlyUnselected() async throws {
        let fixture = try PrefetchFixture()
        let fetched = FetchLog()
        let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: fixture.downloader(log: fetched))
        let outcome = try await AutotuneRecommendationBenchmarker(artifactResolver: resolver).prefetchArtifacts(
            candidateCatalog: fixture.catalog,
            hardware: Self.hardware(memoryGB: 16),
            candidateModelIDs: Set(fixture.catalog.rows.values.map(\.modelID)),
            modelKeyOrder: ["incumbent", "winner", "loser"]
        )

        XCTAssertEqual(fetched.modelIDs, ["namespace/winner", "namespace/loser"])
        let byKey = Dictionary(uniqueKeysWithValues: outcome.artifacts.map { ($0.modelKey, $0) })
        XCTAssertEqual(byKey["incumbent"]?.downloadedByRun, false)
        XCTAssertEqual(byKey["preexisting"]?.downloadedByRun, false)
        XCTAssertEqual(byKey["winner"]?.downloadedByRun, true)
        XCTAssertEqual(byKey["loser"]?.downloadedByRun, true)

        // A row marked downloaded whose path is not its durable artifact path
        // is never removed.
        let preexisting = try XCTUnwrap(byKey["preexisting"])
        let outside = fixture.hub.appendingPathComponent("reference", isDirectory: true).path
        let forged = PrefetchedModelArtifact(
            modelKey: preexisting.modelKey,
            modelID: preexisting.modelID,
            modelRevision: preexisting.modelRevision,
            candidateRowIdentity: preexisting.candidateRowIdentity,
            path: outside,
            sha256: preexisting.sha256,
            downloadedByRun: true
        )
        let removed = AutotuneModelUpgrade.removeUnselectedRunDownloads(
            outcome.artifacts + [forged],
            keepModelKeys: ["incumbent", "winner"],
            catalog: fixture.catalog,
            resolver: resolver
        )

        XCTAssertEqual(removed, [try XCTUnwrap(byKey["loser"]).path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(byKey["loser"]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
        for key in ["incumbent", "preexisting", "winner"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(byKey[key]).path), key)
        }
    }

    func testPrefetchRefusesADownloadWithoutRoomForTheReserveAndLeavesNothing() async throws {
        let fixture = try PrefetchFixture()
        let fetched = FetchLog()
        var downloader = fixture.downloader(log: fetched)
        downloader.freeSpaceReserveBytes = Int64.max / 4
        let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: downloader)
        let outcome = try await AutotuneRecommendationBenchmarker(artifactResolver: resolver).prefetchArtifacts(
            candidateCatalog: fixture.catalog,
            hardware: Self.hardware(memoryGB: 16),
            candidateModelIDs: Set(fixture.catalog.rows.values.map(\.modelID)),
            modelKeyOrder: ["incumbent", "winner", "loser"]
        )

        XCTAssertEqual(Set(outcome.artifacts.map(\.modelKey)), ["incumbent", "preexisting"])
        XCTAssertEqual(Set(outcome.diagnostics.map(\.modelID)), ["namespace/winner", "namespace/loser"])
        XCTAssertTrue(outcome.diagnostics.allSatisfy { $0.reason.contains("not enough free disk space") })
        for key in ["winner", "loser"] {
            let row = try XCTUnwrap(fixture.catalog.rows[key])
            let staging = resolver.prefetchSnapshotURL(
                modelID: row.modelID,
                revision: try XCTUnwrap(row.modelRevision),
                sha256: try XCTUnwrap(row.modelSHA256)
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), key)
        }
        XCTAssertNoThrow(try AutotuneModelUpgrade.verifiedUpgradeArtifacts(outcome, incumbentModelID: "namespace/incumbent"))
    }

    func testReceiptWithoutRunDownloadRecordStillDecodesAndAuthorizesNoRemoval() throws {
        let legacy = #"{"model_key":"k","model_id":"m","model_revision":"r","candidate_row_identity":"i","path":"/tmp/x","sha256":"s"}"#
        let artifact = try JSONDecoder().decode(PrefetchedModelArtifact.self, from: Data(legacy.utf8))
        XCTAssertNil(artifact.downloadedByRun)
    }

    // MARK: drain and restore

    func testUpgradeWaitsForIdleBeforeStoppingAndRestartsOnEveryExit() async throws {
        let command = try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply"])
        enum Exit { case success, failure, interruptedInOperation, interruptedDuringDrain }
        for exit in [Exit.success, .failure, .interruptedInOperation, .interruptedDuringDrain] {
            var events: [String] = []
            var deps = AutotuneRunDependencies.production
            let flag = AutotuneInterruptFlag()
            deps.makeInterruptFlag = { flag }
            deps.installSignalSources = { _ in nil }
            deps.writeStderr = { _ in }
            deps.detectConflict = { .launchdManaged(pid: 42) }
            deps.drainConflict = { _, _, _ in
                events.append("stop")
                if exit == .interruptedDuringDrain { flag.set() }
                return .drained
            }
            deps.restoreConflict = { _, _ in
                events.append("restart")
                return .restored
            }
            do {
                try await command.drainThenIsolate(
                    dependencies: deps,
                    waitForIdle: {
                        events.append("idle")
                        return true
                    },
                    startLaunchdRestoreGuard: { _ in ProviderLaunchdRestoreGuard { events.append("dismiss") } }
                ) {
                    events.append("retune")
                    switch exit {
                    case .success, .interruptedDuringDrain: return
                    case .failure: throw ValidationError("benchmark failed")
                    case .interruptedInOperation: throw ExitCode(130)
                    }
                }
                XCTAssertEqual(exit, .success, "\(exit) must surface its error")
            } catch {
                XCTAssertNotEqual(exit, .success, String(describing: error))
            }
            let expected = exit == .interruptedDuringDrain
                ? ["idle", "stop", "restart", "dismiss"]
                : ["idle", "stop", "retune", "restart", "dismiss"]
            XCTAssertEqual(events, expected, "\(exit)")
        }
    }

    func testBusyProviderIsNeverStopped() async throws {
        let command = try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply"])
        var stopped = false
        var deps = AutotuneRunDependencies.production
        deps.writeStderr = { _ in }
        deps.detectConflict = { .launchdManaged(pid: 42) }
        deps.drainConflict = { _, _, _ in
            stopped = true
            return .drained
        }
        do {
            try await command.drainThenIsolate(
                dependencies: deps,
                waitForIdle: { false },
                startLaunchdRestoreGuard: { _ in nil }
            ) {
                XCTFail("a busy provider must not be re-tuned")
            }
            XCTFail("expected exit 75")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, 75)
        }
        XCTAssertFalse(stopped)
    }

    func testUpgradeRestartsAForegroundIncumbentEvenWithApply() async throws {
        let command = try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply"])
        var restartForeground: Bool?
        var deps = AutotuneRunDependencies.production
        deps.installSignalSources = { _ in nil }
        deps.writeStderr = { _ in }
        deps.detectConflict = { .foreground(pid: 7, argv: ["macprovider-cli", "serve"]) }
        deps.drainConflict = { _, _, _ in .drained }
        deps.restoreConflict = { _, restart in
            restartForeground = restart
            return .restored
        }
        try await command.drainThenIsolate(
            dependencies: deps,
            waitForIdle: { true },
            startLaunchdRestoreGuard: { _ in nil }
        ) {}
        XCTAssertEqual(restartForeground, true)
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

    private static func benchmark(key: String, row: CandidateCatalog.Row, tps: Double) -> CandidateBenchmark {
        CandidateBenchmark(
            modelKey: key,
            sustainedTPS: tps,
            ttftMS: 1_000,
            swapDetected: false,
            thermalThrottleDetected: false,
            artifactSHA256: row.modelSHA256 ?? "",
            modelArtifactPath: "/tmp/\(key)",
            benchmarkID: "cached-\(key)",
            generatedAt: Date(),
            candidateCatalogSHA256: "",
            binaryVersion: "test-bin",
            modelID: row.modelID,
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

private final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    var modelIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    func record(_ url: URL) {
        let path = url.path
        guard let range = path.range(of: "/api/models/") else { return }
        let rest = path[range.upperBound...].split(separator: "/")
        guard rest.count >= 2 else { return }
        let modelID = "\(rest[0])/\(rest[1])"
        lock.lock()
        defer { lock.unlock() }
        if ids.last != modelID { ids.append(modelID) }
    }
}

/// Four signed rows: an incumbent with a canonical snapshot, a row whose
/// hash-qualified prefetch snapshot already exists, and two rows the fake
/// downloader fetches.
private struct PrefetchFixture {
    let hub: URL
    let catalog: CandidateCatalog
    let downloadedHash: String

    init() throws {
        hub = FileManager.default.temporaryDirectory
            .appendingPathComponent("r028-prefetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let revision = String(repeating: "a", count: 40)

        let reference = hub.appendingPathComponent("reference", isDirectory: true)
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: reference.appendingPathComponent("weights.bin"))
        downloadedHash = try ModelArtifactVerifier.canonicalArtifactHash(directory: reference)

        let incumbentSnapshot = resolver.snapshotURL(modelID: "namespace/incumbent", revision: revision)
        try FileManager.default.createDirectory(at: incumbentSnapshot, withIntermediateDirectories: true)
        try Data("incumbent".utf8).write(to: incumbentSnapshot.appendingPathComponent("weights.bin"))
        let incumbentHash = try ModelArtifactVerifier.canonicalArtifactHash(directory: incumbentSnapshot)

        let preexisting = resolver.prefetchSnapshotURL(modelID: "namespace/preexisting", revision: revision, sha256: downloadedHash)
        try FileManager.default.createDirectory(at: preexisting, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: preexisting.appendingPathComponent("weights.bin"))

        func row(_ name: String, sha256: String) -> CandidateCatalog.Row {
            CandidateCatalog.Row(
                modelID: "namespace/\(name)",
                modelRevision: revision,
                modelSHA256: sha256,
                minRAMGB: 1,
                minBandwidthTier: .c,
                benchGate: CandidateCatalog.BenchGate(minSustainedTPS: 1, max4KTTFTMS: 1_000),
                runtimeStatus: "recommendable",
                notes: nil
            )
        }
        var catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8))
        catalog.rows = [
            "incumbent": row("incumbent", sha256: incumbentHash),
            "preexisting": row("preexisting", sha256: downloadedHash),
            "winner": row("winner", sha256: downloadedHash),
            "loser": row("loser", sha256: downloadedHash),
        ]
        self.catalog = catalog
    }

    func downloader(log: FetchLog) -> HuggingFaceSnapshotDownloader {
        HuggingFaceSnapshotDownloader(
            fetch: { request in
                let url = try XCTUnwrap(request.url)
                log.record(url)
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(#"{"siblings":[{"rfilename":"weights.bin","size":11}]}"#.utf8), response)
            },
            download: { _ in
                let downloaded = FileManager.default.temporaryDirectory
                    .appendingPathComponent("r028-download-\(UUID().uuidString).bin")
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
    }
}
