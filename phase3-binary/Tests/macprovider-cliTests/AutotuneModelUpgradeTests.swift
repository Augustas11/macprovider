import ArgumentParser
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-023-R029 / AC-52: stale-recommendation model upgrade.
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

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog, acceleration: .init())

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
            AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.threeBKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog, acceleration: .init()),
            .switchModel(from: Self.threeBKey, to: Self.llama8BKey, reason: "incumbent_policy_demoted")
        )
    }

    func testEqualScoreKeepsIncumbentAndReappliesItsRow() throws {
        let request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        var result = AutotuneRecommendEngine().recommend(request)
        let selectedScore = try XCTUnwrap(result.selectedCandidate).orderingScore
        let index = try XCTUnwrap(result.allCandidates.firstIndex { $0.catalogKey == Self.qwen8BKey })
        result.allCandidates[index].orderingScore = selectedScore

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog, acceleration: .init())

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

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.llama8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog, acceleration: .init())

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

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog, acceleration: .init())

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
            AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog, acceleration: .init()),
            .keep(reason: "incumbent_selected")
        )
    }

    func testNoEligibleRowWritesNoConfig() throws {
        var request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        for key in request.benchmarks.keys {
            request.benchmarks[key]?.thermalThrottleDetected = true
        }
        let result = AutotuneRecommendEngine().recommend(request)

        let decision = AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog, acceleration: .init())

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
            AutotuneModelUpgrade.decide(result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks, catalog: request.candidateCatalog, acceleration: .init()),
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
            catalog: request.candidateCatalog, acceleration: .init()
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
                catalog: request.candidateCatalog, acceleration: .init()
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
            catalog: request.candidateCatalog, acceleration: .init()
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
            catalog: request.candidateCatalog, acceleration: .init()
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
        let leaseStore = Self.temporaryLeaseStore()
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
                // The restarted provider must be able to take its startup lease.
                XCTAssertEqual(leaseStore.inspect(), .missing, "\(exit)")
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
                    isOperatorPaused: { false },
                    acquireLease: { AutotuneModelUpgrade.acquireMaintenanceLease(store: leaseStore) },
                    startLaunchdRestoreGuard: { _ in ProviderLaunchdRestoreGuard { events.append("dismiss") } }
                ) {
                    events.append("retune")
                    XCTAssertNotEqual(leaseStore.inspect(), .missing, "the lease is held while the provider is stopped")
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
            XCTAssertEqual(leaseStore.inspect(), .missing, "the lease is released on \(exit)")
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
                isOperatorPaused: { false },
                acquireLease: { .held("unused") },
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
            isOperatorPaused: { false },
            acquireLease: { AutotuneModelUpgrade.acquireMaintenanceLease(store: Self.temporaryLeaseStore()) },
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

        let errorClock = FakeClock()
        let unreachable = await AutotuneModelUpgrade.waitForLocalProviderIdle(
            port: 8080,
            timeoutSeconds: 5,
            fetchStatus: { _ in throw URLError(.cannotConnectToHost) },
            sleep: { _ in errorClock.advance(1) },
            now: { errorClock.now }
        )
        XCTAssertFalse(unreachable, "a status error is not idle")

        // A status error followed by an idle report is idle.
        let recovering = SequencedStatus([[:], ["requests_in_flight": 0, "requests_queued": 0]])
        let recovered = await AutotuneModelUpgrade.waitForLocalProviderIdle(
            port: 8080,
            timeoutSeconds: 60,
            fetchStatus: { _ in recovering.next() },
            sleep: { _ in },
            now: Date.init
        )
        XCTAssertTrue(recovered)
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
        // The pinned (pre-R029) prefetch still requires its allowlist.
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

    static func temporaryLeaseStore() -> ProviderLifecycleLeaseStore {
        ProviderLifecycleLeaseStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("model-upgrade-lease-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("lifecycle", isDirectory: true)
            .appendingPathComponent("lease.json"))
    }

    static func hardware(memoryGB: Int) -> AutotuneRecommendHardware {
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

private final class RecordBox: @unchecked Sendable {
    var record: AutotuneModelUpgrade.AttemptRecord?

    init(_ record: AutotuneModelUpgrade.AttemptRecord?) {
        self.record = record
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

// MARK: - #2367 fleet bounds and unattended trigger

extension AutotuneModelUpgradeTests {
    func testRunDownloadCapAdmitsTheFirstDownloadsAndDropsTheRest() async throws {
        let fixture = try PrefetchFixture()
        let fetched = FetchLog()
        var downloader = fixture.downloader(log: fetched)
        // Each fixture snapshot advertises 11 bytes ("replacement").
        let budget = RunDownloadBudget(limitBytes: 11)
        downloader.runDownloadBudget = budget
        let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: downloader)
        let outcome = try await AutotuneRecommendationBenchmarker(artifactResolver: resolver).prefetchArtifacts(
            candidateCatalog: fixture.catalog,
            hardware: Self.hardware(memoryGB: 16),
            candidateModelIDs: Set(fixture.catalog.rows.values.map(\.modelID)),
            modelKeyOrder: ["incumbent", "winner", "loser"]
        )

        // The loser's size listing is read (that is how its size is known);
        // its snapshot is refused before any file is fetched.
        XCTAssertEqual(fetched.modelIDs, ["namespace/winner", "namespace/loser"])
        XCTAssertEqual(Set(outcome.artifacts.map(\.modelKey)), ["incumbent", "preexisting", "winner"])
        XCTAssertEqual(outcome.diagnostics.map(\.modelID), ["namespace/loser"])
        XCTAssertTrue(outcome.diagnostics.allSatisfy { $0.reason.contains("run download cap reached") })
        XCTAssertEqual(budget.remainingBytes, 0)
        let loser = try XCTUnwrap(fixture.catalog.rows["loser"])
        let staging = resolver.prefetchSnapshotURL(
            modelID: loser.modelID,
            revision: try XCTUnwrap(loser.modelRevision),
            sha256: try XCTUnwrap(loser.modelSHA256)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertNoThrow(try AutotuneModelUpgrade.verifiedUpgradeArtifacts(outcome, incumbentModelID: "namespace/incumbent"))
    }

    func testRunDownloadBudgetChargesOnlyAdmittedSnapshots() throws {
        let budget = RunDownloadBudget(limitBytes: 100)
        XCTAssertNoThrow(try budget.reserve(bytes: 60, modelID: "a"))
        XCTAssertThrowsError(try budget.reserve(bytes: 41, modelID: "b")) { error in
            XCTAssertEqual(
                error as? AutotuneRecommendError,
                .downloadBudgetExceeded(modelID: "b", requiredBytes: 41, remainingBytes: 40)
            )
        }
        XCTAssertEqual(budget.remainingBytes, 40)
        XCTAssertNoThrow(try budget.reserve(bytes: 40, modelID: "c"))
        XCTAssertEqual(RunDownloadBudget.total([Int64.max, 1]), Int64.max)
    }

    func testRunDownloadCapIsTwiceMemory() {
        XCTAssertEqual(AutotuneModelUpgrade.runDownloadCapBytes(memoryGB: 8), 16 * 1_073_741_824)
        XCTAssertEqual(AutotuneModelUpgrade.runDownloadCapBytes(memoryGB: 512), 1_024 * 1_073_741_824)
        XCTAssertEqual(AutotuneModelUpgrade.runDownloadCapBytes(memoryGB: 0), 2 * 1_073_741_824)
    }

    func testStaggerOffsetIsStableInTheWindowAndSpreadsTheFleet() {
        let window = TimeInterval(AutotuneModelUpgrade.staggerWindowSeconds)
        let inputs = AutotuneModelUpgrade.inputsKey(inputDigests: ["c"], binaryVersion: "1.2.3")
        let first = AutotuneModelUpgrade.staggerOffsetSeconds(providerKey: "provider-1", inputsKey: inputs)
        XCTAssertEqual(first, AutotuneModelUpgrade.staggerOffsetSeconds(providerKey: "provider-1", inputsKey: inputs))
        let offsets = (0..<400).map {
            AutotuneModelUpgrade.staggerOffsetSeconds(providerKey: "provider-\($0)", inputsKey: inputs)
        }
        XCTAssertTrue(offsets.allSatisfy { $0 >= 0 && $0 < window })
        // Spread: every quarter of the window holds a share of the fleet.
        for quarter in 0..<4 {
            let low = window * Double(quarter) / 4
            let high = window * Double(quarter + 1) / 4
            XCTAssertGreaterThan(offsets.filter { $0 >= low && $0 < high }.count, 60, "quarter \(quarter)")
        }
        // Any input release (catalog, rate card, demand rank or binary)
        // reorders the fleet.
        for next in [
            AutotuneModelUpgrade.inputsKey(inputDigests: ["d"], binaryVersion: "1.2.3"),
            AutotuneModelUpgrade.inputsKey(inputDigests: ["c"], binaryVersion: "1.2.4"),
        ] {
            let reordered = (0..<400).filter {
                AutotuneModelUpgrade.staggerOffsetSeconds(providerKey: "provider-\($0)", inputsKey: inputs)
                    != AutotuneModelUpgrade.staggerOffsetSeconds(providerKey: "provider-\($0)", inputsKey: next)
            }
            XCTAssertGreaterThan(reordered.count, 390)
        }
    }

    func testUnattendedGateWaitsForTheOffsetThenRetriesOncePerDay() {
        let released = Date(timeIntervalSince1970: 1_800_000_000)
        let digests = ["candidate_catalog=c", "rate_card=r", "demand_rank=d"]
        let key = "provider-7"
        let store = RecordBox(AutotuneModelUpgrade.AttemptRecord(binaryVersion: "1.2.3", binaryFirstSeenAt: released.addingTimeInterval(-86_400)))
        let inputsKey = AutotuneModelUpgrade.inputsKey(inputDigests: digests, binaryVersion: "1.2.3")
        let notBefore = released.addingTimeInterval(AutotuneModelUpgrade.staggerOffsetSeconds(providerKey: key, inputsKey: inputsKey))
        func gate(_ now: Date, digests: [String] = digests) -> AutotuneModelUpgrade.UnattendedGate {
            AutotuneModelUpgrade.unattendedGate(
                now: now,
                feedGeneratedAt: [released, released.addingTimeInterval(-3600)],
                inputDigests: digests,
                binaryVersion: "1.2.3",
                providerKey: key,
                readRecord: { store.record },
                writeRecord: { store.record = $0 }
            )
        }
        if notBefore > released {
            XCTAssertEqual(gate(notBefore.addingTimeInterval(-1)), .staggered(until: notBefore))
        }
        XCTAssertEqual(gate(notBefore), .proceed)
        let retryAt = notBefore.addingTimeInterval(AutotuneModelUpgrade.unattendedRetrySeconds)
        XCTAssertEqual(gate(notBefore.addingTimeInterval(3600)), .retryLater(until: retryAt))
        XCTAssertEqual(gate(retryAt), .proceed)
    }

    func testStaggerAnchorsOnARateCardOnlyRelease() {
        let catalogReleased = Date(timeIntervalSince1970: 1_800_000_000)
        let rateCardReleased = catalogReleased.addingTimeInterval(10 * 86_400)
        let digests = ["candidate_catalog=c", "rate_card=r2", "demand_rank=d"]
        let store = RecordBox(AutotuneModelUpgrade.AttemptRecord(binaryVersion: "1.2.3", binaryFirstSeenAt: catalogReleased))
        let inputsKey = AutotuneModelUpgrade.inputsKey(inputDigests: digests, binaryVersion: "1.2.3")
        // Pick a provider whose offset is not zero, so the wait is visible.
        let provider = (0..<100).map { "provider-\($0)" }.first {
            AutotuneModelUpgrade.staggerOffsetSeconds(providerKey: $0, inputsKey: inputsKey) > 60
        }!
        let notBefore = rateCardReleased.addingTimeInterval(AutotuneModelUpgrade.staggerOffsetSeconds(providerKey: provider, inputsKey: inputsKey))
        func gate(_ now: Date) -> AutotuneModelUpgrade.UnattendedGate {
            AutotuneModelUpgrade.unattendedGate(
                now: now,
                feedGeneratedAt: [catalogReleased, rateCardReleased, catalogReleased],
                inputDigests: digests,
                binaryVersion: "1.2.3",
                providerKey: provider,
                readRecord: { store.record },
                writeRecord: { store.record = $0 }
            )
        }
        // Long after the catalog's own window, the new rate card still waits.
        XCTAssertEqual(gate(rateCardReleased.addingTimeInterval(1)), .staggered(until: notBefore))
        XCTAssertEqual(gate(notBefore), .proceed)
    }

    func testStaggerAnchorsANewBinaryOnWhenTheGateFirstSawIt() {
        let feedsReleased = Date(timeIntervalSince1970: 1_800_000_000)
        let digests = ["candidate_catalog=c", "rate_card=r", "demand_rank=d"]
        let store = RecordBox(AutotuneModelUpgrade.AttemptRecord(binaryVersion: "1.2.3", binaryFirstSeenAt: feedsReleased))
        let inputsKey = AutotuneModelUpgrade.inputsKey(inputDigests: digests, binaryVersion: "1.2.4")
        let provider = (0..<100).map { "provider-\($0)" }.first {
            AutotuneModelUpgrade.staggerOffsetSeconds(providerKey: $0, inputsKey: inputsKey) > 60
        }!
        let firstSeen = feedsReleased.addingTimeInterval(30 * 86_400)
        func gate(_ now: Date) -> AutotuneModelUpgrade.UnattendedGate {
            AutotuneModelUpgrade.unattendedGate(
                now: now,
                feedGeneratedAt: [feedsReleased],
                inputDigests: digests,
                binaryVersion: "1.2.4",
                providerKey: provider,
                readRecord: { store.record },
                writeRecord: { store.record = $0 }
            )
        }
        let notBefore = firstSeen.addingTimeInterval(AutotuneModelUpgrade.staggerOffsetSeconds(providerKey: provider, inputsKey: inputsKey))
        XCTAssertEqual(gate(firstSeen), .staggered(until: notBefore))
        XCTAssertEqual(store.record?.binaryVersion, "1.2.4")
        XCTAssertEqual(store.record?.binaryFirstSeenAt, firstSeen)
        // The first-seen time persists, so later checks keep the same anchor.
        XCTAssertEqual(gate(firstSeen.addingTimeInterval(30)), .staggered(until: notBefore))
        XCTAssertEqual(gate(notBefore), .proceed)
    }

    func testAttemptWriteFailureStopsTheRun() {
        struct Unwritable: Error {}
        let released = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = AutotuneModelUpgrade.unattendedGate(
            now: released.addingTimeInterval(TimeInterval(AutotuneModelUpgrade.staggerWindowSeconds)),
            feedGeneratedAt: [released],
            inputDigests: ["c"],
            binaryVersion: "1.2.3",
            providerKey: "provider-1",
            readRecord: { AutotuneModelUpgrade.AttemptRecord(binaryVersion: "1.2.3", binaryFirstSeenAt: released) },
            writeRecord: { _ in throw Unwritable() }
        )
        guard case .recordUnwritable = gate else {
            return XCTFail("an unwritable record must stop the run, got \(gate)")
        }
    }

    func testAttemptHistoryBlocksASelectionThatFlipsBack() {
        let released = Date(timeIntervalSince1970: 1_800_000_000)
        let start = released.addingTimeInterval(TimeInterval(AutotuneModelUpgrade.staggerWindowSeconds))
        let store = RecordBox(AutotuneModelUpgrade.AttemptRecord(binaryVersion: "1.2.3", binaryFirstSeenAt: released))
        func gate(_ now: Date, _ digest: String) -> AutotuneModelUpgrade.UnattendedGate {
            AutotuneModelUpgrade.unattendedGate(
                now: now,
                feedGeneratedAt: [released],
                inputDigests: [digest],
                binaryVersion: "1.2.3",
                providerKey: "provider-1",
                readRecord: { store.record },
                writeRecord: { store.record = $0 }
            )
        }
        XCTAssertEqual(gate(start, "a"), .proceed)
        XCTAssertEqual(gate(start.addingTimeInterval(6 * 3600), "b"), .proceed)
        guard case .retryLater = gate(start.addingTimeInterval(12 * 3600), "a") else {
            return XCTFail("flipping back to an input set tried within 24 h must wait")
        }
        // The history is bounded.
        for index in 0..<20 {
            _ = gate(start.addingTimeInterval(TimeInterval(index) * 86_400 * 2), "set-\(index)")
        }
        XCTAssertEqual(store.record?.attempts.count, AutotuneModelUpgrade.attemptHistoryLimit)
    }

    func testAttemptRecordRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-upgrade-attempt-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("model-upgrade-attempt.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(AutotuneModelUpgrade.readAttempt(from: url))
        var record = AutotuneModelUpgrade.AttemptRecord(
            binaryVersion: "1.2.3",
            binaryFirstSeenAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        record.recordAttempt(inputsKey: "k", at: Date(timeIntervalSince1970: 1_800_000_100))
        try AutotuneModelUpgrade.writeAttempt(record, to: url)
        XCTAssertEqual(AutotuneModelUpgrade.readAttempt(from: url), record)
    }

    func testUnattendedTriggerIsSuppressedForPinnedPausedNoJoinAndCandidateServes() {
        func suppression(
            donor: Bool = false, pool: String? = nil, candidate: Bool = false, noJoin: Bool = false,
            isolated: Bool = false, paused: Bool = false
        ) -> String? {
            AutotuneModelUpgrade.unattendedTriggerSuppression(
                donorMode: donor, poolModelID: pool, autotuneCandidate: candidate, noJoin: noJoin,
                isolateLifecycle: isolated, operatorPaused: paused
            )
        }
        XCTAssertNil(suppression())
        XCTAssertEqual(suppression(candidate: true), "autotune_candidate")
        XCTAssertEqual(suppression(noJoin: true), "no_join")
        XCTAssertEqual(suppression(isolated: true), "isolate_lifecycle")
        XCTAssertEqual(suppression(donor: true), "donor_mode")
        XCTAssertEqual(suppression(pool: "pool/model"), "pool_model_id")
        XCTAssertNil(suppression(pool: "  "))
        XCTAssertEqual(suppression(paused: true), "operator_paused")
    }

    func testUnattendedArgumentsAndFlagValidation() {
        XCTAssertEqual(
            AutotuneModelUpgrade.afterUpdateArguments(configPath: "/tmp/config.yaml", unattended: true, parentPID: 42),
            ["autotune", "--recommend", "--upgrade", "--apply", "--unattended", "--upgrade-parent-pid", "42", "--config", "/tmp/config.yaml"]
        )
        XCTAssertNoThrow(try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply", "--unattended", "--upgrade-parent-pid", "42"]))
        XCTAssertThrowsError(try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply", "--unattended"]))
        XCTAssertThrowsError(try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply", "--upgrade-parent-pid", "42"]))
        XCTAssertThrowsError(try AutotuneCommand.parse(["--recommend", "--apply", "--unattended", "--upgrade-parent-pid", "42"]))
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend", "--upgrade", "--prefetch", "--prefetch-receipt", "/tmp/r.json", "--unattended", "--upgrade-parent-pid", "42",
        ]))
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend", "--upgrade", "--apply", "--prefetch-receipt", "/tmp/r.json", "--unattended", "--upgrade-parent-pid", "42",
        ]))
    }

    func testDetachedSpawnRunsInItsOwnSessionAndWritesTheLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-upgrade-spawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-cli")
        // Records its arguments and whether it leads its own session.
        try Data("""
        #!/bin/sh
        echo "args=$*"
        if [ "$(ps -o sess= -p $$ | tr -d ' ')" = "$(ps -o pid= -p $$ | tr -d ' ')" ] || [ "$(ps -o pgid= -p $$ | tr -d ' ')" = "$$" ]; then echo leader=yes; else echo leader=no; fi
        echo stderr-line >&2
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let log = directory.appendingPathComponent("model-upgrade.log").path

        XCTAssertNotNil(AutotuneModelUpgrade.spawnDetachedUnattendedUpgrade(
            executable: script,
            configPath: "/tmp/config.yaml",
            logPath: log,
            parentPID: 4242
        ))
        let deadline = Date().addingTimeInterval(10)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            if text.contains("stderr-line") { break }
            usleep(50_000)
        }
        XCTAssertTrue(text.contains("args=autotune --recommend --upgrade --apply --unattended --upgrade-parent-pid 4242 --config /tmp/config.yaml"), text)
        XCTAssertTrue(text.contains("leader=yes"), text)
        XCTAssertTrue(text.contains("stderr-line"), text)
    }

    func testDetachedSpawnPassesOnlyStandardDescriptors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-upgrade-fds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A descriptor without close-on-exec, like the serve listener.
        let leaked = open(directory.appendingPathComponent("held").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThan(leaked, 2)
        defer { close(leaked) }
        let script = directory.appendingPathComponent("fake-cli")
        try Data("""
        #!/bin/sh
        if [ -e /dev/fd/\(leaked) ]; then echo leaked=yes; else echo leaked=no; fi
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let log = directory.appendingPathComponent("model-upgrade.log").path

        XCTAssertNotNil(AutotuneModelUpgrade.spawnDetachedUnattendedUpgrade(
            executable: script, configPath: nil, logPath: log
        ))
        let deadline = Date().addingTimeInterval(10)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            if text.contains("leaked=") { break }
            usleep(50_000)
        }
        XCTAssertTrue(text.contains("leaked=no"), text)
    }

    func testUnattendedLogRotatesPastTheLimitAndRefusesSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-upgrade-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("model-upgrade.log").path
        try Data(repeating: 0x61, count: 64).write(to: URL(fileURLWithPath: log))
        AutotuneModelUpgrade.rotateUnattendedLog(atPath: log, limitBytes: 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log))
        AutotuneModelUpgrade.rotateUnattendedLog(atPath: log, limitBytes: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log))
        XCTAssertTrue(FileManager.default.fileExists(atPath: log + ".1"))

        // A symlinked log is neither rotated nor written through.
        let target = directory.appendingPathComponent("elsewhere").path
        try Data().write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: log, withDestinationPath: target)
        let script = directory.appendingPathComponent("fake-cli")
        try Data("#!/bin/sh\necho wrote\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pid = AutotuneModelUpgrade.spawnDetachedUnattendedUpgrade(executable: script, configPath: nil, logPath: log)
        if pid != nil { usleep(500_000) }
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "")
    }
}

// MARK: - #2367 audit fixes

extension AutotuneModelUpgradeTests {
    func testUpgradePrefetcherInstallsTheRunDownloadBudget() throws {
        let fixture = try PrefetchFixture()
        let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: fixture.downloader(log: FetchLog()))
        let prefetcher = AutotuneCommand.budgetedUpgradePrefetcher(
            AutotuneRecommendationBenchmarker(artifactResolver: resolver),
            resolvedConfig: nil,
            memoryGB: 8
        )
        let budget = try XCTUnwrap(prefetcher.artifactResolver.downloader.runDownloadBudget)
        XCTAssertEqual(budget.limitBytes, AutotuneModelUpgrade.runDownloadCapBytes(memoryGB: 8))
        XCTAssertEqual(prefetcher.artifactResolver.hubRoot, resolver.hubRoot)
    }

    func testFallbackAfterAFailedChargedSourceChargesTheSnapshotOnce() async throws {
        var downloader = HuggingFaceSnapshotDownloader(
            fetch: { request in
                let url = try XCTUnwrap(request.url)
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(#"{"siblings":[{"rfilename":"weights.bin","size":11}]}"#.utf8), response)
            },
            download: { request in
                let url = try XCTUnwrap(request.url)
                let downloaded = FileManager.default.temporaryDirectory
                    .appendingPathComponent("r029-fallback-\(UUID().uuidString).bin")
                try Data("replacement".utf8).write(to: downloaded)
                // huggingface.co fails after the snapshot was charged.
                let status = url.host == "huggingface.co" ? 503 : 200
                return (downloaded, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
            }
        )
        downloader.freeSpaceReserveBytes = nil
        downloader.fallbackSources = [.huggingFaceCompatible(URL(string: "https://mirror.example.test")!)]
        let budget = RunDownloadBudget(limitBytes: 11)
        downloader.runDownloadBudget = budget
        let snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("r029-fallback-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("snapshot", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }

        try await downloader.downloadSnapshot(
            modelID: "namespace/model",
            revision: String(repeating: "a", count: 40),
            expectedSHA256: nil,
            to: snapshot
        )

        XCTAssertEqual(budget.remainingBytes, 0, "the snapshot is charged once")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("weights.bin").path))
    }

    func testKeepRecordsTheKeptIncumbentInStateAndEvidence() throws {
        let request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        let result = AutotuneRecommendEngine().recommend(request)
        XCTAssertEqual(result.selectedCandidate?.catalogKey, Self.llama8BKey)
        // The better challenger lacks the incumbent's signed CB admission.
        let decision = AutotuneModelUpgrade.decide(
            result: result,
            incumbentKey: Self.qwen8BKey,
            benchmarks: request.benchmarks,
            catalog: request.candidateCatalog,
            acceleration: AutotuneModelUpgrade.AccelerationAdmissions(continuousBatching: [Self.qwen8BKey])
        )
        XCTAssertEqual(decision, .keep(reason: "challenger_lacks_incumbent_acceleration"))
        let target = AutotuneModelUpgrade.configTarget(
            for: decision, result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks
        )
        XCTAssertEqual(target?.catalogKey, Self.qwen8BKey)

        let served = AutotuneModelUpgrade.servedResult(result, servedKey: target?.catalogKey, benchmarks: request.benchmarks)
        let incumbent = try XCTUnwrap(result.allCandidates.first { $0.catalogKey == Self.qwen8BKey })
        XCTAssertEqual(served.selectedCandidate?.catalogKey, Self.qwen8BKey)
        XCTAssertEqual(served.recommendedModel, incumbent.model)
        XCTAssertEqual(served.benchmarkID, request.benchmarks[Self.qwen8BKey]?.benchmarkID)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("r029-state-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("last-recommendation.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try RecommendationStateStore.write(served, benchmarks: request.benchmarks, to: url)
        let state = try RecommendationStateStore.read(from: url)
        XCTAssertEqual(state.recommendedModel, incumbent.model)
        XCTAssertEqual(state.hardwareEvidence?.recommendedModel, incumbent.model)

        // A kept row that did not pass admission is named nowhere.
        let unadmitted = AutotuneModelUpgrade.servedResult(result, servedKey: "retired/key", benchmarks: request.benchmarks)
        XCTAssertNil(unadmitted.recommendedModel)
        XCTAssertNil(unadmitted.benchmarkGeneratedAt)
    }

    func testSignedCBOrNativeMTPAdmissionIsNeverTradedAway() throws {
        let request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        let result = AutotuneRecommendEngine().recommend(request)
        func decide(_ acceleration: AutotuneModelUpgrade.AccelerationAdmissions) -> AutotuneModelUpgrade.Decision {
            AutotuneModelUpgrade.decide(
                result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks,
                catalog: request.candidateCatalog, acceleration: acceleration
            )
        }
        let keep = AutotuneModelUpgrade.Decision.keep(reason: "challenger_lacks_incumbent_acceleration")
        XCTAssertEqual(decide(.init(nativeMTP: [Self.qwen8BKey])), keep)
        XCTAssertEqual(decide(.init(continuousBatching: [Self.qwen8BKey], nativeMTP: [Self.qwen8BKey, Self.llama8BKey])), keep)
        let switched = AutotuneModelUpgrade.Decision.switchModel(
            from: Self.qwen8BKey, to: Self.llama8BKey, reason: "strictly_higher_expected_earnings"
        )
        XCTAssertEqual(decide(.init(continuousBatching: [Self.qwen8BKey, Self.llama8BKey])), switched)
        XCTAssertEqual(decide(.init(nativeMTP: [Self.llama8BKey])), switched)

        // The signed sidecar names rows by served model and artifact hash.
        let row = try XCTUnwrap(request.candidateCatalog.rows[Self.qwen8BKey])
        let sidecar = try JSONSerialization.data(withJSONObject: [
            "entries": [["model_key": row.modelID, "artifact_hash": try XCTUnwrap(row.modelSHA256)]],
        ])
        XCTAssertEqual(
            AutotuneModelUpgrade.nativeMTPAdmittedKeys(sidecar: sidecar, catalog: request.candidateCatalog),
            [Self.qwen8BKey]
        )
        let wrongHash = try JSONSerialization.data(withJSONObject: [
            "entries": [["model_key": row.modelID, "artifact_hash": String(repeating: "0", count: 64)]],
        ])
        XCTAssertEqual(AutotuneModelUpgrade.nativeMTPAdmittedKeys(sidecar: wrongHash, catalog: request.candidateCatalog), [])
        XCTAssertEqual(
            AutotuneModelUpgrade.continuousBatchingAdmittedKeys(
                ContinuousBatchingPolicyLoadResult(selection: .emptyOff, status: .absentFallback, policySHA256: nil, signerKeyID: nil),
                catalog: request.candidateCatalog
            ),
            []
        )
    }

    func testCleanupRunsWhenIsolationFailsAndKeepsAnAppliedTarget() async throws {
        let fixture = try PrefetchFixture()
        let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: fixture.downloader(log: FetchLog()))
        let outcome = try await AutotuneRecommendationBenchmarker(artifactResolver: resolver).prefetchArtifacts(
            candidateCatalog: fixture.catalog,
            hardware: Self.hardware(memoryGB: 16),
            candidateModelIDs: Set(fixture.catalog.rows.values.map(\.modelID)),
            modelKeyOrder: ["incumbent", "winner", "loser"]
        )
        let byKey = Dictionary(uniqueKeysWithValues: outcome.artifacts.map { ($0.modelKey, $0) })
        let command = try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply"])
        var deps = AutotuneRunDependencies.production
        deps.writeStderr = { _ in }
        struct IsolationFailed: Error {}
        deps.detectConflict = { throw IsolationFailed() }

        // The isolation fails before the operation: nothing is kept but the
        // incumbent (and copies that existed before the run).
        do {
            try await AutotuneModelUpgrade.withRunDownloadCleanup(
                outcome.artifacts, incumbentKey: "incumbent", catalog: fixture.catalog, resolver: resolver,
                configuredKey: { nil }
            ) { _ in
                try await command.drainThenIsolate(
                    dependencies: deps,
                    waitForIdle: { true },
                    isOperatorPaused: { false },
                    acquireLease: { .held("unused") },
                    startLaunchdRestoreGuard: { _ in nil }
                ) {
                    XCTFail("the operation must not run")
                }
            }
            XCTFail("expected the isolation error")
        } catch is IsolationFailed {}
        for key in ["winner", "loser"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(byKey[key]).path), key)
        }
        for key in ["incumbent", "preexisting"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(byKey[key]).path), key)
        }
    }

    func testAppliedTargetSurvivesAFailureAfterApply() async throws {
        let fixture = try PrefetchFixture()
        let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: fixture.downloader(log: FetchLog()))
        let outcome = try await AutotuneRecommendationBenchmarker(artifactResolver: resolver).prefetchArtifacts(
            candidateCatalog: fixture.catalog,
            hardware: Self.hardware(memoryGB: 16),
            candidateModelIDs: Set(fixture.catalog.rows.values.map(\.modelID)),
            modelKeyOrder: ["incumbent", "winner", "loser"]
        )
        let byKey = Dictionary(uniqueKeysWithValues: outcome.artifacts.map { ($0.modelKey, $0) })
        struct LateFailure: Error {}
        do {
            try await AutotuneModelUpgrade.withRunDownloadCleanup(
                outcome.artifacts, incumbentKey: "incumbent", catalog: fixture.catalog, resolver: resolver,
                configuredKey: { nil }
            ) { keep in
                keep.insert("winner")
                throw LateFailure()
            }
        } catch is LateFailure {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(byKey["winner"]).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(byKey["loser"]).path))
    }

    func testHeldLeaseOrOperatorPauseStopsNothing() async throws {
        let command = try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply"])
        let store = Self.temporaryLeaseStore()
        // A free lease and a paused provider: the pause alone stops the run,
        // and the lease is never taken.
        do {
            var stopped = false
            var deps = AutotuneRunDependencies.production
            deps.writeStderr = { _ in }
            deps.detectConflict = { .launchdManaged(pid: 42) }
            deps.drainConflict = { _, _, _ in
                stopped = true
                return .drained
            }
            var leaseRequested = false
            do {
                try await command.drainThenIsolate(
                    dependencies: deps,
                    waitForIdle: { true },
                    isOperatorPaused: { true },
                    acquireLease: {
                        leaseRequested = true
                        return AutotuneModelUpgrade.acquireMaintenanceLease(store: store)
                    },
                    startLaunchdRestoreGuard: { _ in nil }
                ) {
                    XCTFail("nothing runs while the provider is paused")
                }
                XCTFail("expected exit 75")
            } catch let exit as ExitCode {
                XCTAssertEqual(exit.rawValue, 75)
            }
            XCTAssertFalse(stopped)
            XCTAssertFalse(leaseRequested)
            XCTAssertEqual(store.inspect(), .missing)
        }
        // Another operation (an autoupdate) holds the maintenance lease.
        guard case let .acquired(other) = AutotuneModelUpgrade.acquireMaintenanceLease(store: store) else {
            return XCTFail("the first lease must be acquired")
        }
        defer { other.release() }
        do {
            let paused = false
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
                    waitForIdle: { true },
                    isOperatorPaused: { paused },
                    acquireLease: { AutotuneModelUpgrade.acquireMaintenanceLease(store: store) },
                    startLaunchdRestoreGuard: { _ in nil }
                ) {
                    XCTFail("nothing runs while the lease is held or the provider is paused")
                }
                XCTFail("expected exit 75")
            } catch let exit as ExitCode {
                XCTAssertEqual(exit.rawValue, 75)
            }
            XCTAssertFalse(stopped, "paused=\(paused)")
        }
        guard case .valid(let record) = store.inspect() else { return XCTFail("the other lease stays") }
        XCTAssertEqual(record.leaseID, other.record.leaseID)
    }

    func testRunLockAdmitsOneRunAtATime() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("r029-lock-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("model-upgrade.lock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard case let .acquired(first) = AutotuneModelUpgrade.acquireRunLock(at: url) else {
            return XCTFail("the first run takes the lock")
        }
        guard case .busy = AutotuneModelUpgrade.acquireRunLock(at: url) else {
            return XCTFail("a held lock refuses a second run")
        }
        first.release()
        guard case .acquired = AutotuneModelUpgrade.acquireRunLock(at: url) else {
            return XCTFail("a released lock is free")
        }
        // An unopenable lock path is a failure, not a busy lock.
        let blocked = url.deletingLastPathComponent().appendingPathComponent("file")
        try Data().write(to: blocked)
        guard case .failed = AutotuneModelUpgrade.acquireRunLock(at: blocked.appendingPathComponent("model-upgrade.lock")) else {
            return XCTFail("an open error is reported as a failure")
        }
    }

    func testModelSwitchClearsTheDraftModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r029-draft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.yaml")
        let original = "model: old/model\ndraft_model: old/drafter\nnum_draft_tokens: 3\nport: 8080\n"
        let recommendation = RecommendationCore(
            model: "new/model",
            targetContext: 4_000,
            knobs: WinningKnobs(kvBits: nil, maxBatch: 4, maxContext: 8_000),
            tpsMedian: 2,
            ttftP95MS: 10,
            replicates: 3
        )
        try Data(original.utf8).write(to: configURL)
        _ = try ConfigApplier(configPath: configURL).apply(
            recommendation: recommendation,
            now: Date(timeIntervalSince1970: 1_800_000_000),
            draftCapacity: .clamp,
            physicalMemoryGB: 16,
            clearDraftModel: true
        )
        let switched = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(switched.contains("draft_model"), switched)
        XCTAssertFalse(switched.contains("num_draft_tokens"), switched)
        XCTAssertTrue(switched.contains("model: new/model\n"), switched)
        XCTAssertTrue(switched.contains("port: 8080\n"), switched)
        XCTAssertTrue(switched.contains("max_concurrency_override: 4\n"), switched)

        // Without a switch the draft model stays and caps the slots.
        try Data(original.utf8).write(to: configURL)
        _ = try ConfigApplier(configPath: configURL).apply(
            recommendation: recommendation,
            now: Date(timeIntervalSince1970: 1_800_000_001),
            draftCapacity: .clamp,
            physicalMemoryGB: 16
        )
        let kept = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(kept.contains("draft_model: old/drafter"), kept)
        XCTAssertTrue(kept.contains("max_concurrency_override: 1\n"), kept)
    }
}

// MARK: - #2367 audit round 2

extension AutotuneModelUpgradeTests {
    func testTriggerAndChildStopOnlyTheServeThatStartedTheCheck() async throws {
        XCTAssertNil(AutotuneModelUpgrade.providerMismatch(.launchdManaged(pid: 42), expectedPID: 42, systemLaunchDaemonInstalled: false))
        XCTAssertNil(AutotuneModelUpgrade.providerMismatch(.foreground(pid: 42, argv: ["macprovider-cli", "serve"]), expectedPID: 42, systemLaunchDaemonInstalled: false))
        XCTAssertEqual(AutotuneModelUpgrade.providerMismatch(.launchdManaged(pid: 42), expectedPID: 43, systemLaunchDaemonInstalled: false), "detected_provider_is_not_the_parent")
        XCTAssertEqual(AutotuneModelUpgrade.providerMismatch(.foreground(pid: 42, argv: []), expectedPID: 43, systemLaunchDaemonInstalled: false), "detected_provider_is_not_the_parent")
        XCTAssertEqual(AutotuneModelUpgrade.providerMismatch(.launchdManaged(pid: nil), expectedPID: 42, systemLaunchDaemonInstalled: false), "detected_provider_is_not_the_parent")
        XCTAssertEqual(AutotuneModelUpgrade.providerMismatch(.none, expectedPID: 42, systemLaunchDaemonInstalled: false), "no_detected_provider")
        XCTAssertEqual(AutotuneModelUpgrade.providerMismatch(.launchdManaged(pid: 42), expectedPID: nil, systemLaunchDaemonInstalled: false), "no_parent_pid")
        // A headless system LaunchDaemon provider looks foreground to the
        // provider user; SIGTERM would only make launchd relaunch it.
        XCTAssertEqual(AutotuneModelUpgrade.providerMismatch(.foreground(pid: 42, argv: ["macprovider-cli", "serve"]), expectedPID: 42, systemLaunchDaemonInstalled: true), "system_launch_daemon_provider")
        XCTAssertNil(AutotuneModelUpgrade.providerMismatch(.launchdManaged(pid: 42), expectedPID: 42, systemLaunchDaemonInstalled: true))

        // A lab serve (pid 43) started the child; the launchd provider (42)
        // is what the isolation would stop: nothing is stopped.
        let child = try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply", "--unattended", "--upgrade-parent-pid", "43"])
        for detections in [[Int32(42)], [43, 42]] {
            var remaining = detections
            var stopped = false
            var idleChecked = false
            var deps = AutotuneRunDependencies.production
            deps.installSignalSources = { _ in nil }
            deps.writeStderr = { _ in }
            deps.detectConflict = { .launchdManaged(pid: remaining.count > 1 ? remaining.removeFirst() : remaining[0]) }
            deps.drainConflict = { _, _, _ in
                stopped = true
                return .drained
            }
            do {
                try await child.drainThenIsolate(
                    dependencies: deps,
                    waitForIdle: {
                        idleChecked = true
                        return true
                    },
                    isOperatorPaused: { false },
                    acquireLease: { AutotuneModelUpgrade.acquireMaintenanceLease(store: Self.temporaryLeaseStore()) },
                    startLaunchdRestoreGuard: { _ in nil }
                ) {
                    XCTFail("a foreign provider is never re-tuned")
                }
                XCTFail("expected exit 75")
            } catch let exit as ExitCode {
                XCTAssertEqual(exit.rawValue, 75)
            }
            XCTAssertFalse(stopped, "\(detections)")
            // A provider that changed after the first check is refused at the stop.
            XCTAssertEqual(idleChecked, detections.count > 1, "\(detections)")
        }

        // The serve that started the check is the provider: the run proceeds.
        var ran = false
        var deps = AutotuneRunDependencies.production
        deps.installSignalSources = { _ in nil }
        deps.writeStderr = { _ in }
        deps.detectConflict = { .launchdManaged(pid: 43) }
        deps.drainConflict = { _, _, _ in .drained }
        deps.restoreConflict = { _, _ in .restored }
        try await child.drainThenIsolate(
            dependencies: deps,
            waitForIdle: { true },
            isOperatorPaused: { false },
            acquireLease: { AutotuneModelUpgrade.acquireMaintenanceLease(store: Self.temporaryLeaseStore()) },
            startLaunchdRestoreGuard: { _ in nil }
        ) {
            ran = true
        }
        XCTAssertTrue(ran)
    }

    func testUnverifiedAccelerationAdmissionKeepsTheIncumbent() async throws {
        let request = try makeSmallDenseRequest(benchmarkTPS: Self.defaultTPS)
        let result = AutotuneRecommendEngine().recommend(request)
        func decide(_ acceleration: AutotuneModelUpgrade.AccelerationAdmissions) -> AutotuneModelUpgrade.Decision {
            AutotuneModelUpgrade.decide(
                result: result, incumbentKey: Self.qwen8BKey, benchmarks: request.benchmarks,
                catalog: request.candidateCatalog, acceleration: acceleration
            )
        }
        let unverifiedKeep = AutotuneModelUpgrade.Decision.keep(reason: "acceleration_admission_unverified")
        XCTAssertEqual(decide(.init(unverified: ["continuous_batching"])), unverifiedKeep)
        XCTAssertEqual(decide(.init(unverified: ["native_mtp"])), unverifiedKeep)
        XCTAssertEqual(
            decide(.init()),
            .switchModel(from: Self.qwen8BKey, to: Self.llama8BKey, reason: "strictly_higher_expected_earnings")
        )

        let catalog = AutotuneStaticSelection(value: request.candidateCatalog, selectedBytes: Data(), warnings: [], usedFallback: false)
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("r029-mtp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        func load(_ status: ContinuousBatchingPolicyLoadStatus) async -> AutotuneModelUpgrade.AccelerationAdmissions {
            await AutotuneModelUpgrade.loadAccelerationAdmissions(
                catalog: catalog,
                rateCard: request.rateCard,
                loadCBPolicy: { _ in
                    ContinuousBatchingPolicyLoadResult(selection: .emptyOff, status: status, policySHA256: nil, signerKeyID: nil)
                },
                fetchNativeMTPMembers: { throw URLError(.notConnectedToInternet) },
                nativeMTPRoot: emptyRoot
            )
        }
        // Feed unreachable and no local copy; CB policy not live-verified.
        let neither = await load(.absentFallback)
        XCTAssertEqual(neither.unverified, ["continuous_batching", "native_mtp"])
        XCTAssertEqual(decide(neither), unverifiedKeep)
        let noMTP = await load(.liveVerified)
        XCTAssertEqual(noMTP.unverified, ["native_mtp"])
        XCTAssertEqual(decide(noMTP), unverifiedKeep)
        let integrityFailure = await load(.integrityFailureFallback)
        XCTAssertEqual(integrityFailure.unverified, ["continuous_batching", "native_mtp"])
        // A keep for unreadable admissions is not recorded as final.
        XCTAssertFalse(AutotuneModelUpgrade.recordsKeep(unverifiedKeep, wroteRow: false))
    }

    func testEveryUpgradeModeTakesTheRunLockAndAttendedRunsWait() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("r029-lock-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("model-upgrade.lock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var deps = AutotuneRunDependencies.production
        deps.writeStderr = { _ in }
        let receiptApply = try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply", "--prefetch-receipt", "/tmp/r029-receipt.json"])
        let receiptPrefetch = try AutotuneCommand.parse(["--recommend", "--upgrade", "--prefetch", "--prefetch-receipt", "/tmp/r029-receipt.json"])
        let unattended = try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply", "--unattended", "--upgrade-parent-pid", "42"])
        let plain = try AutotuneCommand.parse(["--recommend", "--apply"])

        XCTAssertNil(try plain.acquireUpgradeRunLock(dependencies: deps, at: url))
        let held = try XCTUnwrap(try receiptApply.acquireUpgradeRunLock(dependencies: deps, at: url))
        // The unattended check never waits.
        XCTAssertThrowsError(try unattended.acquireUpgradeRunLock(dependencies: deps, at: url)) { error in
            XCTAssertEqual((error as? ExitCode)?.rawValue, 75)
        }
        // An attended step waits for the holder instead of failing.
        final class Box: @unchecked Sendable {
            let lock: AutotuneModelUpgrade.RunLock
            init(_ lock: AutotuneModelUpgrade.RunLock) { self.lock = lock }
        }
        let box = Box(held)
        let releasedAt = Date().addingTimeInterval(0.3)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { box.lock.release() }
        let waited = try XCTUnwrap(try receiptPrefetch.acquireUpgradeRunLock(dependencies: deps, at: url))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(releasedAt), -0.05)
        waited.release()
    }

    func testCleanupKeepsTheRowTheConfigNamesWhenCleanupRuns() async throws {
        let fixture = try PrefetchFixture()
        let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: fixture.downloader(log: FetchLog()))
        let outcome = try await AutotuneRecommendationBenchmarker(artifactResolver: resolver).prefetchArtifacts(
            candidateCatalog: fixture.catalog,
            hardware: Self.hardware(memoryGB: 16),
            candidateModelIDs: Set(fixture.catalog.rows.values.map(\.modelID)),
            modelKeyOrder: ["incumbent", "winner", "loser"]
        )
        let byKey = Dictionary(uniqueKeysWithValues: outcome.artifacts.map { ($0.modelKey, $0) })
        let configURL = fixture.hub.appendingPathComponent("config.yaml")
        try Data("model: namespace/incumbent\nmodel_catalog_key: incumbent\n".utf8).write(to: configURL)
        XCTAssertEqual(AutotuneModelUpgrade.configuredCatalogKey(configPath: configURL.path, catalog: fixture.catalog), "incumbent")
        do {
            try await AutotuneModelUpgrade.withRunDownloadCleanup(
                outcome.artifacts, incumbentKey: "incumbent", catalog: fixture.catalog, resolver: resolver,
                configuredKey: { AutotuneModelUpgrade.configuredCatalogKey(configPath: configURL.path, catalog: fixture.catalog) }
            ) { _ in
                // Something else points the config at a row this run downloaded,
                // then the run exits 75.
                try Data("model: namespace/winner\nmodel_catalog_key: winner\n".utf8).write(to: configURL)
                throw ExitCode(75)
            }
            XCTFail("expected exit 75")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, 75)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(byKey["winner"]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(byKey["incumbent"]).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(byKey["loser"]).path))
    }

    func testARecordedKeepHoldsUntilTheInputsChange() throws {
        // A pure re-stamp (generated_at and version) keeps the content
        // digest; a row change does not.
        let feed = #"{"generated_at":"2026-11-15T03:40:00Z","version":"v1","rows":{"a":{"x":1}}}"#
        let restamped = #"{"rows":{"a":{"x":1}},"version":"v2","generated_at":"2026-11-16T00:00:00Z"}"#
        let changed = #"{"generated_at":"2026-11-15T03:40:00Z","version":"v1","rows":{"a":{"x":2}}}"#
        XCTAssertEqual(AutotuneModelUpgrade.contentDigest(Data(feed.utf8)), AutotuneModelUpgrade.contentDigest(Data(restamped.utf8)))
        XCTAssertNotEqual(AutotuneModelUpgrade.contentDigest(Data(feed.utf8)), AutotuneModelUpgrade.contentDigest(Data(changed.utf8)))
        // Acceleration keeps are recorded: the admission sets are in the key.
        XCTAssertTrue(AutotuneModelUpgrade.recordsKeep(.keep(reason: "challenger_lacks_incumbent_acceleration"), wroteRow: false))
        XCTAssertFalse(AutotuneModelUpgrade.recordsKeep(.keep(reason: "acceleration_admission_unverified"), wroteRow: false))

        XCTAssertTrue(AutotuneModelUpgrade.recordsKeep(.keep(reason: "no_eligible_candidate"), wroteRow: false))
        XCTAssertFalse(AutotuneModelUpgrade.recordsKeep(.keep(reason: "incumbent_selected"), wroteRow: true))
        XCTAssertFalse(AutotuneModelUpgrade.recordsKeep(.switchModel(from: "a", to: "b", reason: "r"), wroteRow: true))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("r029-keep-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("model-upgrade-attempt.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let admissions = AutotuneModelUpgrade.AccelerationAdmissions(continuousBatching: ["a", "b"], nativeMTP: ["a"])
        let digests = AutotuneModelUpgrade.upgradeInputDigests(
            catalog: Data(feed.utf8), rateCard: Data(), demandRank: Data(), acceleration: admissions
        )
        let key = AutotuneModelUpgrade.inputsKey(inputDigests: digests, binaryVersion: "1.2.3")
        let keptAt = Date(timeIntervalSince1970: 1_800_000_000)
        try AutotuneModelUpgrade.recordKeep(inputsKey: key, at: keptAt, url: url)

        func gate(
            _ catalog: String,
            binary: String = "1.2.3",
            acceleration: AutotuneModelUpgrade.AccelerationAdmissions = admissions,
            now: Date
        ) -> AutotuneModelUpgrade.UnattendedGate {
            AutotuneModelUpgrade.unattendedGate(
                now: now,
                feedGeneratedAt: [],
                inputDigests: AutotuneModelUpgrade.upgradeInputDigests(
                    catalog: Data(catalog.utf8), rateCard: Data(), demandRank: Data(), acceleration: acceleration
                ),
                binaryVersion: binary,
                providerKey: "provider",
                readRecord: { AutotuneModelUpgrade.readAttempt(from: url) },
                writeRecord: { try AutotuneModelUpgrade.writeAttempt($0, to: url) }
            )
        }
        // Days later, after a re-stamp of generated_at and version, and with
        // the same admission sets re-signed, the kept inputs are not re-run.
        let later = keptAt.addingTimeInterval(10 * 86_400)
        XCTAssertEqual(gate(feed, now: later), .kept(since: keptAt))
        XCTAssertEqual(gate(restamped, now: later), .kept(since: keptAt))
        XCTAssertEqual(
            gate(feed, acceleration: .init(continuousBatching: ["b", "a"], nativeMTP: ["a"]), now: later),
            .kept(since: keptAt)
        )
        // New content, a new binary or a changed admission set runs again.
        if case .kept = gate(changed, now: later) { XCTFail("changed content is a new input") }
        if case .kept = gate(feed, binary: "1.2.4", now: later) { XCTFail("a new binary is a new input") }
        for other in [
            AutotuneModelUpgrade.AccelerationAdmissions(continuousBatching: ["a"], nativeMTP: ["a"]),
            AutotuneModelUpgrade.AccelerationAdmissions(continuousBatching: ["a", "b"], nativeMTP: ["a", "b"]),
            AutotuneModelUpgrade.AccelerationAdmissions(continuousBatching: ["a", "b"], nativeMTP: ["a"], unverified: ["native_mtp"]),
        ] {
            if case .kept = gate(feed, acceleration: other, now: later) { XCTFail("an admission change is a new input: \(other)") }
        }

        // A record written before keeps existed still decodes.
        let legacy = #"{"binary_version":"1.2.3","attempts":[]}"#
        try Data(legacy.utf8).write(to: url)
        XCTAssertEqual(AutotuneModelUpgrade.readAttempt(from: url)?.keeps, [])
    }

    func testALostLeaseWritesNoConfigAndTheIncumbentIsRestored() async throws {
        let command = try AutotuneCommand.parse(["--recommend", "--upgrade", "--apply"])
        var events: [String] = []
        var deps = AutotuneRunDependencies.production
        deps.installSignalSources = { _ in nil }
        deps.writeStderr = { _ in }
        deps.detectConflict = { .launchdManaged(pid: 42) }
        deps.drainConflict = { _, _, _ in
            events.append("stop")
            return .drained
        }
        deps.restoreConflict = { _, _ in
            events.append("restart")
            return .restored
        }
        do {
            try await command.drainThenIsolate(
                dependencies: deps,
                waitForIdle: { true },
                isOperatorPaused: { false },
                acquireLease: { AutotuneModelUpgrade.acquireMaintenanceLease(store: Self.temporaryLeaseStore()) },
                startLaunchdRestoreGuard: { _ in nil }
            ) {
                try await AutotuneCommand.commitModelUpgrade(
                    leaseHeld: { false },
                    applyConfig: { events.append("apply") },
                    commitsDecision: true,
                    writeRecommendationState: { events.append("state") },
                    submitHardwareEvidence: { events.append("evidence") },
                    recordKeep: { events.append("keep") }
                )
            }
            XCTFail("expected exit 75")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, 75)
        }
        XCTAssertEqual(events, ["stop", "restart"])
    }

    func testUpgradeCommitAppliesThenWritesStateThenEvidenceThenRecordsTheKeep() async throws {
        var events: [String] = []
        // An ineligible incumbent kept with its row re-applied.
        try await AutotuneCommand.commitModelUpgrade(
            leaseHeld: { true },
            applyConfig: { events.append("apply") },
            commitsDecision: true,
            writeRecommendationState: { events.append("state") },
            submitHardwareEvidence: { events.append("evidence") },
            recordKeep: { events.append("keep") }
        )
        XCTAssertEqual(events, ["apply", "state", "evidence", "keep"])
        // A keep that writes no config still submits evidence and records it.
        events = []
        try await AutotuneCommand.commitModelUpgrade(
            leaseHeld: { false },
            applyConfig: nil,
            commitsDecision: true,
            writeRecommendationState: { events.append("state") },
            submitHardwareEvidence: { events.append("evidence") },
            recordKeep: { events.append("keep") }
        )
        XCTAssertEqual(events, ["state", "evidence", "keep"])
    }

    private static func unattendedRunDependencies(
        lockURL: URL,
        detected: ProviderConflict,
        stderr: @escaping (String) -> Void
    ) -> AutotuneRunDependencies {
        var deps = AutotuneRunDependencies.production
        deps.installSignalSources = { _ in nil }
        deps.writeStderr = stderr
        deps.detectConflict = { detected }
        deps.drainConflict = { _, _, _ in
            XCTFail("nothing is stopped")
            return .drained
        }
        deps.upgradeRunLockURL = lockURL
        return deps
    }

    func testRunTakesTheUpgradeRunLock() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r029-runlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("model-upgrade.lock")
        guard case let .acquired(held) = AutotuneModelUpgrade.acquireRunLock(at: lockURL) else {
            return XCTFail("the lock must be acquired")
        }
        defer { held.release() }
        var stderr = ""
        // A foreign provider makes a run that skipped the lock exit 75 with
        // another message, before any feed read.
        let deps = Self.unattendedRunDependencies(lockURL: lockURL, detected: .launchdManaged(pid: 7)) { stderr += $0 }
        let command = try AutotuneCommand.parse([
            "--recommend", "--upgrade", "--apply", "--unattended", "--upgrade-parent-pid", "42",
            "--config", directory.appendingPathComponent("missing.yaml").path,
        ])
        do {
            try await command.run(dependencies: deps)
            XCTFail("expected exit 75")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, 75)
        }
        XCTAssertTrue(stderr.contains("another model upgrade run holds"), stderr)
    }

    func testUnattendedRunRefusesAForeignProviderBeforeAnyDownload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r029-parentpid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var stderr = ""
        let deps = Self.unattendedRunDependencies(
            lockURL: directory.appendingPathComponent("model-upgrade.lock"),
            detected: .launchdManaged(pid: 7)
        ) { stderr += $0 }
        // A missing config ends a run that skipped the check before any download.
        let command = try AutotuneCommand.parse([
            "--recommend", "--upgrade", "--apply", "--unattended", "--upgrade-parent-pid", "42",
            "--config", directory.appendingPathComponent("missing.yaml").path,
        ])
        do {
            try await command.run(dependencies: deps)
            XCTFail("expected exit 75")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, 75)
        }
        XCTAssertTrue(stderr.contains("reason=detected_provider_is_not_the_parent; nothing was downloaded"), stderr)
    }

    func testServeTickSpawnsOnlyForItsOwnProvider() {
        func tick(_ suppression: String?, _ detected: ProviderConflict?, daemon: Bool = false) -> String? {
            AutotuneModelUpgrade.unattendedTickSuppression(
                triggerSuppression: suppression, detected: detected, servePID: 42, systemLaunchDaemonInstalled: daemon
            )
        }
        XCTAssertNil(tick(nil, .launchdManaged(pid: 42)))
        XCTAssertNil(tick(nil, .foreground(pid: 42, argv: ["macprovider-cli", "serve"])))
        XCTAssertEqual(tick(nil, .launchdManaged(pid: 43)), "detected_provider_is_not_the_parent")
        XCTAssertEqual(tick(nil, ProviderConflict.none), "no_detected_provider")
        XCTAssertEqual(tick(nil, nil), "provider_detection_failed")
        XCTAssertEqual(tick(nil, .foreground(pid: 42, argv: ["macprovider-cli", "serve"]), daemon: true), "system_launch_daemon_provider")
        XCTAssertEqual(tick("operator_paused", .launchdManaged(pid: 42)), "operator_paused")
        XCTAssertEqual(tick("no_join", nil), "no_join")
    }

    func testUnreadableLifecycleStateCountsAsPaused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r029-pause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state-v1.json")
        XCTAssertFalse(AutotuneModelUpgrade.operatorPausePersisted(store: ProviderLifecycleStateStore(url: url)))
        try Data("not json".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertTrue(AutotuneModelUpgrade.operatorPausePersisted(store: ProviderLifecycleStateStore(url: url)))
    }

    func testNoRefundWhenNoFallbackSourceWillBeTried() async throws {
        var downloader = HuggingFaceSnapshotDownloader(
            fetch: { request in
                let url = try XCTUnwrap(request.url)
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(#"{"siblings":[{"rfilename":"weights.bin","size":11}]}"#.utf8), response)
            },
            download: { request in
                let url = try XCTUnwrap(request.url)
                let downloaded = FileManager.default.temporaryDirectory
                    .appendingPathComponent("r029-norefund-\(UUID().uuidString).bin")
                try Data("replacement".utf8).write(to: downloaded)
                return (downloaded, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)))
            }
        )
        downloader.freeSpaceReserveBytes = nil
        // The only fallback needs the signed hash, which this call lacks.
        downloader.fallbackSources = [.contentAddressed(URL(string: "https://cas.example.test")!)]
        let budget = RunDownloadBudget(limitBytes: 11)
        downloader.runDownloadBudget = budget
        let snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("r029-norefund-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("snapshot", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        do {
            try await downloader.downloadSnapshot(
                modelID: "namespace/model",
                revision: String(repeating: "a", count: 40),
                expectedSHA256: nil,
                to: snapshot
            )
            XCTFail("expected the download to fail")
        } catch {}
        XCTAssertEqual(budget.remainingBytes, 0, "the last failed source keeps its charge")
    }

    func testALostLeaseIsNeverConfirmed() throws {
        let store = Self.temporaryLeaseStore()
        guard case let .acquired(lease) = AutotuneModelUpgrade.acquireMaintenanceLease(store: store) else {
            return XCTFail("the lease must be acquired")
        }
        defer { lease.release() }
        XCTAssertTrue(lease.confirmHeld())
        XCTAssertFalse(lease.lost)
        // Another process takes the lease away between renewals.
        XCTAssertTrue(try store.clear(ifLeaseID: lease.record.leaseID))
        XCTAssertFalse(lease.renewNow())
        XCTAssertTrue(lease.lost)
        // A lease re-created with a new id later does not restore this run.
        guard case let .acquired(other) = AutotuneModelUpgrade.acquireMaintenanceLease(store: store) else {
            return XCTFail("a new lease can be taken")
        }
        defer { other.release() }
        XCTAssertFalse(lease.confirmHeld())
    }

    func testAFailedPrefetchRemovesWhatItDownloaded() async throws {
        let fixture = try PrefetchFixture()
        let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: fixture.downloader(log: FetchLog()))
        let revision = String(repeating: "a", count: 40)
        let winnerPath = try resolver.durableStore.artifactURL(
            modelID: "namespace/winner", revision: revision, sha256: fixture.downloadedHash
        ).path
        // The loser's download cannot be adopted into the durable store: an
        // I/O error, not a per-row skip, so it ends the whole prefetch.
        let loserParent = try resolver.durableStore.artifactURL(
            modelID: "namespace/loser", revision: revision, sha256: fixture.downloadedHash
        ).deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: loserParent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: loserParent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: loserParent.path) }
        do {
            _ = try await AutotuneRecommendationBenchmarker(artifactResolver: resolver).prefetchArtifacts(
                candidateCatalog: fixture.catalog,
                hardware: Self.hardware(memoryGB: 16),
                candidateModelIDs: Set(fixture.catalog.rows.values.map(\.modelID)),
                modelKeyOrder: ["incumbent", "winner", "loser"],
                removeRunDownloadsOnFailureKeeping: { ["incumbent"] }
            )
            XCTFail("expected the prefetch to fail")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: winnerPath), "the earlier download is removed")
        let incumbentPath = resolver.snapshotURL(modelID: "namespace/incumbent", revision: revision).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: incumbentPath))
    }
}

// MARK: - #2485 prefetch cleanup, unsupported model types and the disk floor

extension AutotuneModelUpgradeTests {
    func testCleanupRemovesTheStagingSnapshotItsBlobsAndTheDurableCopy() async throws {
        let fixture = try PrefetchFixture()
        let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: fixture.downloader(log: FetchLog()))
        let outcome = try await Self.prefetchAll(fixture, resolver: resolver)
        let byKey = Dictionary(uniqueKeysWithValues: outcome.artifacts.map { ($0.modelKey, $0) })
        let loser = try XCTUnwrap(byKey["loser"])
        let winner = try XCTUnwrap(byKey["winner"])
        let loserStaging = Self.staging(loser, resolver: resolver)
        let winnerStaging = Self.staging(winner, resolver: resolver)
        // The download leaves the Hugging Face staging copy beside the durable one.
        XCTAssertTrue(FileManager.default.fileExists(atPath: loserStaging.path))

        // Hub-style blobs: one only the loser's snapshot links, one another
        // snapshot of the same repo links too.
        let repo = loserStaging.deletingLastPathComponent().deletingLastPathComponent()
        let blobs = try Self.linkBlobs(["own", "shared"], from: loserStaging, repo: repo)
        let other = repo.appendingPathComponent("snapshots/other-revision", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: other.appendingPathComponent("shared.bin").path,
            withDestinationPath: "../../blobs/shared"
        )

        let removed = AutotuneModelUpgrade.removeUnselectedRunDownloads(
            outcome.artifacts,
            keepModelKeys: ["incumbent", "winner"],
            catalog: fixture.catalog,
            resolver: resolver
        )

        XCTAssertEqual(removed, [loser.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: loser.path), "durable copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: loserStaging.path), "prefetch snapshot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobs["own"]!.path), "blob only it linked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobs["shared"]!.path), "blob another snapshot links")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: winner.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: winnerStaging.path))
        // A second pass finds nothing left to remove.
        XCTAssertEqual(AutotuneModelUpgrade.removeUnselectedRunDownloads(
            outcome.artifacts,
            keepModelKeys: ["incumbent", "winner"],
            catalog: fixture.catalog,
            resolver: resolver
        ), [])

        // A repo left with nothing in it goes too; the incumbent and the
        // copy that existed before the run stay.
        XCTAssertEqual(AutotuneModelUpgrade.removeUnselectedRunDownloads(
            outcome.artifacts,
            keepModelKeys: ["incumbent"],
            catalog: fixture.catalog,
            resolver: resolver
        ), [winner.path])
        let winnerRepo = winnerStaging.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: winnerRepo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(byKey["incumbent"]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(byKey["preexisting"]).path))
        let preexisting = try XCTUnwrap(byKey["preexisting"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.staging(preexisting, resolver: resolver).path))
    }

    func testCleanupNeverRemovesWhatTheServedModelUses() async throws {
        let fixture = try PrefetchFixture()
        let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: fixture.downloader(log: FetchLog()))
        let outcome = try await Self.prefetchAll(fixture, resolver: resolver)
        let byKey = Dictionary(uniqueKeysWithValues: outcome.artifacts.map { ($0.modelKey, $0) })
        let loser = try XCTUnwrap(byKey["loser"])
        let winner = try XCTUnwrap(byKey["winner"])
        let loserStaging = Self.staging(loser, resolver: resolver)
        let repo = loserStaging.deletingLastPathComponent().deletingLastPathComponent()
        let blobs = try Self.linkBlobs(["own"], from: loserStaging, repo: repo)
        // The served model lives outside the repo and links the loser's blob.
        let served = fixture.hub.appendingPathComponent("served-model", isDirectory: true)
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: served.appendingPathComponent("weights.bin").path,
            withDestinationPath: blobs["own"]!.path
        )

        AutotuneModelUpgrade.removeUnselectedRunDownloads(
            outcome.artifacts,
            keepModelKeys: ["incumbent"],
            catalog: fixture.catalog,
            resolver: resolver,
            servedPaths: [served.path, winner.path]
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: loserStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobs["own"]!.path), "a blob the served model links")
        XCTAssertTrue(FileManager.default.fileExists(atPath: winner.path), "the served path itself")
        XCTAssertTrue(FileManager.default.fileExists(atPath: served.path))
    }

    func testUnsupportedModelTypeIsSkippedBeforeDownload() async throws {
        let fixture = try PrefetchFixture()
        let downloads = URLLog()
        var downloader = HuggingFaceSnapshotDownloader(
            fetch: { request in
                let url = try XCTUnwrap(request.url)
                let modelType = url.path.contains("/namespace/loser/") ? "qwen2_vl" : "llama"
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                let body = #"{"siblings":[{"rfilename":"weights.bin","size":11}],"config":{"model_type":"\#(modelType)"}}"#
                return (Data(body.utf8), response)
            },
            download: { request in
                downloads.record(try XCTUnwrap(request.url))
                return try r2485DownloadedReplacement()
            }
        )
        downloader.loadableModelType = { $0 != "qwen2_vl" }
        let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: downloader)
        let outcome = try await Self.prefetchAll(fixture, resolver: resolver)

        XCTAssertEqual(Set(outcome.artifacts.map(\.modelKey)), ["incumbent", "preexisting", "winner"])
        let diagnostic = try XCTUnwrap(outcome.diagnostics.first { $0.modelID == "namespace/loser" })
        XCTAssertTrue(diagnostic.reason.contains("model_type qwen2_vl"), diagnostic.reason)
        XCTAssertFalse(downloads.paths.contains { $0.contains("/namespace/loser/") }, "\(downloads.paths)")
        XCTAssertTrue(downloads.paths.contains { $0.contains("/namespace/winner/") })
        let row = try XCTUnwrap(fixture.catalog.rows["loser"])
        let staging = resolver.prefetchSnapshotURL(
            modelID: row.modelID,
            revision: try XCTUnwrap(row.modelRevision),
            sha256: try XCTUnwrap(row.modelSHA256)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testHubConfigWithoutAReadableModelTypeSkipsNothing() throws {
        let decode = { (json: String) in
            try JSONDecoder().decode(HuggingFaceSnapshotDownloader.ModelInfo.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"siblings":[],"config":{"model_type":"qwen2_vl"}}"#).modelType, "qwen2_vl")
        XCTAssertNil(try decode(#"{"siblings":[],"config":{"model_type":3}}"#).modelType)
        XCTAssertNil(try decode(#"{"siblings":[],"config":null}"#).modelType)
        XCTAssertNil(try decode(#"{"siblings":[{"rfilename":"a","size":1}]}"#).modelType)
        XCTAssertEqual(try decode(#"{"siblings":[{"rfilename":"a","size":1}],"config":[]}"#).siblings.count, 1)
    }

    func testProbeLoadsOnlyTheModelTypesThePathLoaderBuilds() async {
        let llamaLoads = await ModelRuntime.probeLoadsModelType("llama")
        let qwen3Loads = await ModelRuntime.probeLoadsModelType("qwen3")
        let prismLoads = await ModelRuntime.probeLoadsModelType("prism_hadamard_qwen35")
        let qwen2VLLoads = await ModelRuntime.probeLoadsModelType("qwen2_vl")
        let unknownLoads = await ModelRuntime.probeLoadsModelType("no_such_model_type")
        XCTAssertTrue(llamaLoads)
        XCTAssertTrue(qwen3Loads)
        XCTAssertTrue(prismLoads)
        XCTAssertFalse(qwen2VLLoads)
        XCTAssertFalse(unknownLoads)
    }

    func testDiskFloorStopsTheRunAndKeepsWhatIsDone() async throws {
        func run(stopAtDiskFloor: Bool) async throws -> (ArtifactPrefetchOutcomes, [String]) {
            let fixture = try PrefetchFixture()
            var catalog = fixture.catalog
            var tail = try XCTUnwrap(catalog.rows["winner"])
            tail.modelID = "namespace/tail"
            catalog.rows["tail"] = tail
            let disk = DiskBox(availableBytes: 100)
            let downloads = URLLog()
            var downloader = HuggingFaceSnapshotDownloader(
                fetch: { request in
                    let url = try XCTUnwrap(request.url)
                    // The loser is too large for the room left above the floor;
                    // the tail after it would fit.
                    let size = url.path.contains("/namespace/loser/") ? 50 : 11
                    let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                    return (Data(#"{"siblings":[{"rfilename":"weights.bin","size":\#(size)}]}"#.utf8), response)
                },
                download: { request in
                    downloads.record(try XCTUnwrap(request.url))
                    disk.consume(11)
                    return try r2485DownloadedReplacement()
                }
            )
            downloader.freeSpaceReserveBytes = 60
            downloader.availableDiskBytes = { _ in disk.availableBytes }
            let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: downloader)
            let outcome = try await AutotuneRecommendationBenchmarker(artifactResolver: resolver).prefetchArtifacts(
                candidateCatalog: catalog,
                hardware: Self.hardware(memoryGB: 16),
                candidateModelIDs: Set(catalog.rows.values.map(\.modelID)),
                modelKeyOrder: ["incumbent", "winner", "loser", "tail"],
                stopAtDiskFloor: stopAtDiskFloor
            )
            return (outcome, downloads.paths)
        }

        let (stopped, stoppedDownloads) = try await run(stopAtDiskFloor: true)
        // winner: 100 free >= 11 + 60, downloaded (89 left); loser: 89 < 50 + 60,
        // refused; the tail is not started; the row already on disk is kept.
        XCTAssertEqual(Set(stopped.artifacts.map(\.modelKey)), ["incumbent", "winner", "preexisting"])
        XCTAssertEqual(stoppedDownloads.filter { $0.contains("/namespace/") }.count, 1)
        XCTAssertTrue(stoppedDownloads.allSatisfy { !$0.contains("/namespace/tail/") })
        let loserReason = try XCTUnwrap(stopped.diagnostics.first { $0.modelID == "namespace/loser" }).reason
        XCTAssertTrue(loserReason.contains("not enough free disk space"), loserReason)
        let tailReason = try XCTUnwrap(stopped.diagnostics.first { $0.modelID == "namespace/tail" }).reason
        XCTAssertTrue(tailReason.contains("free disk space floor"), tailReason)
        XCTAssertNoThrow(try AutotuneModelUpgrade.verifiedUpgradeArtifacts(stopped, incumbentModelID: "namespace/incumbent"))

        // Without the stop (a manual recommend), the smaller tail still fits.
        let (skipped, _) = try await run(stopAtDiskFloor: false)
        XCTAssertTrue(skipped.artifacts.contains { $0.modelKey == "tail" })
    }

    func testUpgradeFreeSpaceFloorIsOneMemoryAtLeast16GiB() throws {
        XCTAssertEqual(AutotuneModelUpgrade.upgradeFreeSpaceFloorBytes(memoryGB: 8), 16 * 1_073_741_824)
        XCTAssertEqual(AutotuneModelUpgrade.upgradeFreeSpaceFloorBytes(memoryGB: 32), 32 * 1_073_741_824)
        XCTAssertEqual(AutotuneModelUpgrade.upgradeFreeSpaceFloorBytes(memoryGB: 512), 512 * 1_073_741_824)
        XCTAssertGreaterThan(
            AutotuneModelUpgrade.upgradeFreeSpaceFloorBytes(memoryGB: 8),
            HuggingFaceSnapshotDownloader.downloadFreeSpaceReserveBytes
        )
        let fixture = try PrefetchFixture()
        let resolver = CachedModelArtifactResolver(hubRoot: fixture.hub, downloader: fixture.downloader(log: FetchLog()))
        let prefetcher = AutotuneCommand.budgetedUpgradePrefetcher(
            AutotuneRecommendationBenchmarker(artifactResolver: resolver),
            resolvedConfig: nil,
            memoryGB: 32
        )
        XCTAssertEqual(
            prefetcher.artifactResolver.downloader.freeSpaceReserveBytes,
            AutotuneModelUpgrade.upgradeFreeSpaceFloorBytes(memoryGB: 32)
        )
        XCTAssertNotNil(prefetcher.artifactResolver.downloader.loadableModelType)
    }

    private static func prefetchAll(
        _ fixture: PrefetchFixture,
        resolver: CachedModelArtifactResolver
    ) async throws -> ArtifactPrefetchOutcomes {
        try await AutotuneRecommendationBenchmarker(artifactResolver: resolver).prefetchArtifacts(
            candidateCatalog: fixture.catalog,
            hardware: hardware(memoryGB: 16),
            candidateModelIDs: Set(fixture.catalog.rows.values.map(\.modelID)),
            modelKeyOrder: ["incumbent", "winner", "loser"]
        )
    }

    private static func staging(_ artifact: PrefetchedModelArtifact, resolver: CachedModelArtifactResolver) -> URL {
        resolver.prefetchSnapshotURL(
            modelID: artifact.modelID,
            revision: artifact.modelRevision,
            sha256: artifact.sha256
        ).standardizedFileURL
    }

    /// Writes `repo/blobs/<name>` for each name and links it from
    /// `snapshot/<name>.bin` with the relative path the Hub uses.
    private static func linkBlobs(_ names: [String], from snapshot: URL, repo: URL) throws -> [String: URL] {
        let blobs = repo.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        var urls: [String: URL] = [:]
        for name in names {
            let blob = blobs.appendingPathComponent(name).standardizedFileURL
            try Data(name.utf8).write(to: blob)
            try FileManager.default.createSymbolicLink(
                atPath: snapshot.appendingPathComponent("\(name).bin").path,
                withDestinationPath: "../../blobs/\(name)"
            )
            urls[name] = blob
        }
        return urls
    }
}

private func r2485DownloadedReplacement() throws -> (URL, URLResponse) {
    let downloaded = FileManager.default.temporaryDirectory
        .appendingPathComponent("r2485-download-\(UUID().uuidString).bin")
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

private final class URLLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ url: URL) {
        lock.lock()
        recorded.append(url.path)
        lock.unlock()
    }
}

private final class DiskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Int64

    init(availableBytes: Int64) {
        available = availableBytes
    }

    var availableBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    func consume(_ bytes: Int64) {
        lock.lock()
        available -= bytes
        lock.unlock()
    }
}
