import Foundation
import XCTest
@testable import macprovider_cli

final class AutotuneACStage2Tests: XCTestCase {
    /// AC-4: Stage 2 records median-of-N and rejects any-error cells; SPEC-013 lines 1389-1395.
    func testAC4Stage2UsesMedianAndStrictAllFeasible() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let db = try AutotuneDB(path: fixture.dbURL.path)
        let documentedReplicates = [2.0, 2.1, 2.05]
        let prober = AutotuneACStubStage2Prober(results: [
            .feasible(medianTPS: median(documentedReplicates), p95TTFTMS: 900, measuredPromptTokens: 1_600),
            .infeasible(reason: "replicate 2 failed", nErr: 1, measuredPromptTokens: 1_600),
        ])

        let result = try await Stage2HillClimb(
            candidateProviderRunner: { AutotuneACStubProviderRunner() },
            prober: prober,
            autotuneDB: db,
            selectedModel: "selected-model",
            kvBitsAxis: [nil, 4],
            maxBatchAxis: [1],
            maxContextAxis: [2_000],
            targetContext: 2_000,
            gateTTFTMS: 60_000,
            stage2Replicates: 3,
            port: 18_080,
            runID: "ac4-run",
            now: fixture.now
        ).run()

        let rows = try fixture.trialRows()
        XCTAssertEqual(result.medianTPS, 2.05)
        XCTAssertEqual(rows[0].aggThroughputTPS, 2.05)
        XCTAssertTrue(rows[0].fits)
        XCTAssertFalse(rows[1].fits)
        XCTAssertNil(rows[1].aggThroughputTPS)
        XCTAssertEqual(rows[1].nErr, 1)
        XCTAssertEqual(rows.map(\.replicatesN), [3, 3])
    }

    /// AC-5: TPS ties are broken by lower TTFT; SPEC-013 lines 1397-1402.
    func testAC5TPSTiebreakByTTFT() async throws {
        let lowerTTFT = try await runAC5Scenario(cellBTTFT: 3_000)
        XCTAssertEqual(lowerTTFT.winningKnobs, WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 2_000))
        XCTAssertEqual(lowerTTFT.p95TTFTMS, 3_000)

        let higherTTFT = try await runAC5Scenario(cellBTTFT: 4_500)
        XCTAssertEqual(higherTTFT.winningKnobs, WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 2_000))
        XCTAssertEqual(higherTTFT.p95TTFTMS, 4_000)
    }

    /// AC-16: tune_trials.stage distinguishes Stage 1 and Stage 2 rows; SPEC-013 lines 1549-1557.
    func testAC16TuneTrialsStagePopulatesCorrectly() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(["--kv-bits-axis", "unset,4", "--max-batch-axis", "1,2"])
        var deps = fixture.dependencies()
        deps.runStage1 = { request in
            let first = fixture.trial(runID: request.runID, stage: 1, model: "model-a", fits: false, notes: "too large")
            let second = fixture.trial(runID: request.runID, stage: 1, model: "model-b", fits: true, aggTPS: 8, ttft: 800)
            try request.db.insertTrial(first)
            try request.db.insertTrial(second)
            return Stage1IteratorResult(selectedModel: "model-b", trials: [first, second], exitReason: .ok)
        }
        deps.runStage2 = { request in
            var rows: [AutotuneTrialRow] = []
            for kvBits in request.kvBitsAxis {
                for batch in request.maxBatchAxis {
                    let row = fixture.trial(
                        runID: request.runID,
                        stage: 2,
                        model: request.selectedModel,
                        fits: true,
                        aggTPS: Double(10 + batch),
                        ttft: 800,
                        kvBits: kvBits,
                        maxContext: request.targetContext,
                        maxBatch: batch,
                        replicates: request.stage2Replicates,
                        kept: kvBits == nil && batch == 1
                    )
                    try request.db.insertTrial(row)
                    rows.append(row)
                }
            }
            return Stage2HillClimbResult(
                selectedModel: request.selectedModel,
                winningKnobs: WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: request.targetContext),
                medianTPS: 11,
                p95TTFTMS: 800,
                replicates: request.stage2Replicates,
                cellTrials: rows
            )
        }

        try await command.run(dependencies: deps)

        let rows = try fixture.trialRows()
        XCTAssertEqual(rows.filter { $0.stage == 1 }.count, 2)
        XCTAssertEqual(rows.filter { $0.stage == 2 }.count, 4)
        XCTAssertEqual(rows.filter { $0.stage == 2 }.map(\.maxBatch), [1, 2, 1, 2])
    }

    /// AC-18: --max-context-axis adds cells and the 8000-context cell can win; SPEC-013 lines 1581-1591.
    func testAC18MaxContextAxisEvaluatesExtraCellsAndCanWin() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(
            ["--kv-bits-axis", "4", "--max-batch-axis", "1", "--max-context-axis", "4000,8000"],
            targetContext: 4_000
        )
        var deps = fixture.dependencies()
        deps.runStage2 = { request in
            XCTAssertEqual(request.maxContextAxis, [4_000, 8_000])
            let fourK = fixture.trial(
                runID: request.runID,
                stage: 2,
                model: request.selectedModel,
                fits: true,
                aggTPS: 8,
                ttft: 700,
                kvBits: 4,
                maxContext: 4_000,
                maxBatch: 1,
                kept: false
            )
            let eightK = fixture.trial(
                runID: request.runID,
                stage: 2,
                model: request.selectedModel,
                fits: true,
                aggTPS: 10,
                ttft: 800,
                kvBits: 4,
                maxContext: 8_000,
                maxBatch: 1,
                kept: true
            )
            try request.db.insertTrial(fourK)
            try request.db.insertTrial(eightK)
            return Stage2HillClimbResult(
                selectedModel: request.selectedModel,
                winningKnobs: WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 8_000),
                medianTPS: 10,
                p95TTFTMS: 800,
                replicates: request.stage2Replicates,
                cellTrials: [fourK, eightK]
            )
        }

        try await command.run(dependencies: deps)

        let stage2 = try fixture.trialRows().filter { $0.stage == 2 }
        XCTAssertEqual(stage2.count, 2)
        XCTAssertEqual(stage2.map(\.maxContextCap), [4_000, 8_000])
        let knobs = try XCTUnwrap(try fixture.latestRecommendationJSON().recommendation?["knobs"] as? [String: Any])
        XCTAssertEqual(knobs["max_context_override"] as? Int, 8_000)
    }

    /// AC-18: Invalid --max-context-axis below target fails at flag parse; SPEC-013 lines 1581-1591.
    func testAC18InvalidMaxContextAxisFailsAtFlagParseTime() throws {
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--target-context", "4000",
            "--max-context-axis", "2000,4000",
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("--max-context-axis cell 2000 is below --target-context 4000"))
        }
    }

    private func runAC5Scenario(cellBTTFT: Double) async throws -> Stage2HillClimbResult {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let db = try AutotuneDB(path: fixture.dbURL.path)
        let prober = AutotuneACStubStage2Prober(results: [
            .feasible(medianTPS: 10.0, p95TTFTMS: 4_000, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 10.05, p95TTFTMS: cellBTTFT, measuredPromptTokens: 1_600),
        ])
        return try await Stage2HillClimb(
            candidateProviderRunner: { AutotuneACStubProviderRunner() },
            prober: prober,
            autotuneDB: db,
            selectedModel: "selected-model",
            kvBitsAxis: [nil, 4],
            maxBatchAxis: [1],
            maxContextAxis: [2_000],
            targetContext: 2_000,
            gateTTFTMS: 60_000,
            stage2Replicates: 3,
            tpsTieEpsilon: 0.02,
            port: 18_080,
            runID: "ac5-\(cellBTTFT)",
            now: fixture.now
        ).run()
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

final class AutotuneACStubStage2Prober: Stage2Probing {
    private var results: [Stage2ProbeResult]

    init(results: [Stage2ProbeResult]) {
        self.results = results
    }

    func probe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        knobs: WinningKnobs,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int
    ) async throws -> Stage2ProbeResult {
        if results.isEmpty {
            return .infeasible(reason: "missing Stage 2 result", nErr: 1, measuredPromptTokens: nil)
        }
        return results.removeFirst()
    }
}
