import ArgumentParser
import Foundation
import SQLite3
import XCTest
@testable import malibu_cli

final class AutotuneACStage1Tests: XCTestCase {
    /// AC-1: Largest-first iteration stops on first feasible; SPEC-013 lines 1366-1372.
    func testAC1LargestFirstIterationStopsOnFirstFeasible() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(["--candidate-models", "X,Y,Z"])
        var deps = fixture.dependencies()
        deps.runStage1 = { request in
            let x = fixture.trial(runID: request.runID, stage: 1, model: "X", fits: false, notes: "X too large")
            let y = fixture.trial(runID: request.runID, stage: 1, model: "Y", fits: true, aggTPS: 7.5, ttft: 800)
            try request.db.insertTrial(x)
            try request.db.insertTrial(y)
            return Stage1IteratorResult(selectedModel: "Y", trials: [x, y], exitReason: .ok)
        }

        try await command.run(dependencies: deps)

        let rows = try fixture.trialRows()
        XCTAssertEqual(rows.filter { $0.stage == 1 }.map(\.model), ["X", "Y"])
        XCTAssertFalse(rows.contains { $0.model == "Z" })
        let json = try fixture.latestRecommendationJSON()
        XCTAssertEqual(json.recommendationModel, "Y")
        XCTAssertEqual(json.alternates, ["Z"])
        XCTAssertTrue(fixture.stdout.contains("model:           Y"))
    }

    /// AC-2: Largest-first iteration advances past infeasible candidates; SPEC-013 lines 1374-1379.
    func testAC2LargestFirstIterationIteratesPastInfeasible() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(["--candidate-models", "X,Y,Z"])
        var deps = fixture.dependencies()
        deps.runStage1 = { request in
            let x = fixture.trial(runID: request.runID, stage: 1, model: "X", fits: false, notes: "X OOM")
            let y = fixture.trial(runID: request.runID, stage: 1, model: "Y", fits: false, notes: "Y TTFT gate")
            let z = fixture.trial(runID: request.runID, stage: 1, model: "Z", fits: true, aggTPS: 4.2, ttft: 900)
            for row in [x, y, z] {
                try request.db.insertTrial(row)
            }
            return Stage1IteratorResult(selectedModel: "Z", trials: [x, y, z], exitReason: .ok)
        }

        try await command.run(dependencies: deps)

        let stage1 = try fixture.trialRows().filter { $0.stage == 1 }
        XCTAssertEqual(stage1.map(\.model), ["X", "Y", "Z"])
        XCTAssertEqual(stage1[0].notes, "X OOM")
        XCTAssertEqual(stage1[1].notes, "Y TTFT gate")
        let json = try fixture.latestRecommendationJSON()
        XCTAssertEqual(json.recommendationModel, "Z")
        XCTAssertEqual(json.alternates, [])
    }

    /// AC-3: All-infeasible exits non-zero with smallest-first reason; SPEC-013 lines 1381-1387.
    func testAC3AllInfeasibleExitsNonZeroWithSmallestFirstReason() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(["--max-model-size", "3B"])
        var deps = fixture.dependencies()
        deps.runStage1 = { request in
            let threeB = "mlx-community/Llama-3.2-3B-Instruct-4bit"
            let oneB = "mlx-community/Llama-3.2-1B-Instruct-4bit"
            try request.db.insertTrial(fixture.trial(runID: request.runID, stage: 1, model: threeB, fits: false, notes: "3B TTFT gate"))
            try request.db.insertTrial(fixture.trial(runID: request.runID, stage: 1, model: oneB, fits: false, notes: "1B stop-token leak"))
            throw Stage1IteratorError.noFeasible(
                reason: "\(oneB): 1B stop-token leak",
                trials: ["1B stop-token leak", "3B TTFT gate"],
                exitReason: .noFeasible
            )
        }

        try await fixture.assertExit { try await command.run(dependencies: deps) }

        XCTAssertTrue(fixture.stderr.contains("1B (smallest): 1B stop-token leak"), fixture.stderr)
        let oneB = try XCTUnwrap(fixture.stderr.range(of: "1B (smallest)"))
        let threeB = try XCTUnwrap(fixture.stderr.range(of: "3B: 3B TTFT gate"))
        XCTAssertLessThan(oneB.lowerBound, threeB.lowerBound)
        let row = try fixture.latestRunRow()
        XCTAssertEqual(row.exitReason, "no_feasible")
        XCTAssertNil(row.recommendationJSON)
    }

    /// AC-7: Every candidate serve argv is isolated from the coordinator and
    /// explicitly marked as an autotune-owned runtime; SPEC-013 lines 1426-1432.
    func testAC7NoJoinIsSetOnEveryCandidate() throws {
        let models = ["model-a", "model-b", "model-c"]
        let argvByModel = try models.map { model in
            try CandidateProviderRunner.serveArguments(
                model: model,
                port: 18_080,
                kvBits: 4,
                maxContext: 4_000,
                maxBatch: 2
            )
        }

        XCTAssertEqual(argvByModel.count, models.count)
        for argv in argvByModel {
            XCTAssertEqual(argv.first, "serve")
            XCTAssertTrue(argv.contains("--no-join"), "spawn argv must contain --no-join: \(argv)")
            XCTAssertEqual(argv.filter { $0 == "--no-join" }.count, 1)
            XCTAssertTrue(
                argv.contains("--autotune-candidate"),
                "spawn argv must mark the private autotune candidate: \(argv)"
            )
            XCTAssertEqual(argv.filter { $0 == "--autotune-candidate" }.count, 1)
        }
    }

    /// AC-8: Shape B transient pre-warm failure advances to the next candidate; SPEC-013 lines 1434-1461.
    ///
    /// Shape A exclusion: SPEC-013 Step 6 selected Shape B (runtime online-fallback
    /// classification via `ProviderPreWarmer` + `HuggingFaceCacheChecker`). The AC-8
    /// Shape A variant (invokes `malibu-cli models pull <id>` or equivalent
    /// subcommand) is out of scope for the v1 implementation surface. This test
    /// exercises Shape B's transient classification only.
    func testAC8PreWarmTransientFailureAdvancesToNextCandidate() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(["--candidate-models", "candidate-1,candidate-2"])
        var deps = fixture.dependencies()
        deps.runStage1 = { request in
            try await Stage1Iterator(
                candidateProviderRunner: { AutotuneACStubProviderRunner() },
                providerPreWarmer: AutotuneACStubPreWarmer(results: [
                    "candidate-1": .failed(failureClass: .transient, reason: "network HTTP 503"),
                    "candidate-2": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
                ]),
                autotuneDB: request.db,
                runID: request.runID,
                candidates: request.candidates,
                candidatesBySize: request.candidatesBySize,
                targetContext: request.targetContext,
                gateTTFTMS: request.gateTTFTMS,
                stage1Replicates: request.stage1Replicates,
                port: request.port,
                prober: AutotuneACStubStage1Prober(results: [
                    "candidate-2": .feasible(medianTPS: 9, p95TTFTMS: 700),
                ]),
                now: fixture.now
            ).run()
        }

        try await command.run(dependencies: deps)

        let rows = try fixture.trialRows().filter { $0.stage == 1 }
        XCTAssertEqual(rows.map(\.model), ["candidate-1", "candidate-2"])
        XCTAssertEqual(rows[0].notes, "pre-warm transient: network HTTP 503")
        XCTAssertTrue(rows[1].fits)
        XCTAssertEqual(try fixture.latestRunRow().exitReason, "ok")
    }

    /// AC-8: Integrity-class pre-warm failure aborts the run; SPEC-013 lines 1434-1461.
    ///
    /// Shape A exclusion: same as `testAC8PreWarmTransientFailureAdvancesToNextCandidate` —
    /// Shape B is the implemented surface; Shape A's subcommand-based pull is out
    /// of scope for v1. This test exercises Shape B's integrity classification
    /// (signature/hash mismatch surfaces an abort, not an advance).
    func testAC8PreWarmIntegrityFailureAbortsTheWholeRun() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(["--candidate-models", "candidate-1,candidate-2"])
        var deps = fixture.dependencies()
        deps.runStage1 = { request in
            try await Stage1Iterator(
                candidateProviderRunner: { AutotuneACStubProviderRunner() },
                providerPreWarmer: AutotuneACStubPreWarmer(results: [
                    "candidate-1": .failed(failureClass: .integrity, reason: "signature mismatch"),
                    "candidate-2": .warmed(cacheState: .alreadyCached, loadDurationSec: 0.1),
                ]),
                autotuneDB: request.db,
                runID: request.runID,
                candidates: request.candidates,
                candidatesBySize: request.candidatesBySize,
                targetContext: request.targetContext,
                gateTTFTMS: request.gateTTFTMS,
                stage1Replicates: request.stage1Replicates,
                port: request.port,
                prober: AutotuneACStubStage1Prober(results: [:]),
                now: fixture.now
            ).run()
        }

        try await fixture.assertExit { try await command.run(dependencies: deps) }

        let rows = try fixture.trialRows().filter { $0.stage == 1 }
        XCTAssertEqual(rows.map(\.model), ["candidate-1"])
        XCTAssertEqual(rows[0].notes, "pre-warm integrity: signature mismatch")
        XCTAssertEqual(try fixture.latestRunRow().exitReason, "pre_warm_integrity_failure")
    }

    /// AC-14: Default candidate list is honored in FR-C.1 order; SPEC-013 lines 1537-1541.
    func testAC14DefaultCandidateListIsHonored() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command()
        var captured: [String] = []
        var deps = fixture.dependencies()
        deps.runStage1 = { request in
            captured = request.candidates
            let first = request.candidates[0]
            let second = request.candidates[1]
            let firstRow = fixture.trial(runID: request.runID, stage: 1, model: first, fits: false, notes: "too large")
            let secondRow = fixture.trial(runID: request.runID, stage: 1, model: second, fits: true, aggTPS: 5, ttft: 800)
            try request.db.insertTrial(firstRow)
            try request.db.insertTrial(secondRow)
            return Stage1IteratorResult(selectedModel: second, trials: [firstRow, secondRow], exitReason: .ok)
        }

        try await command.run(dependencies: deps)

        XCTAssertEqual(captured.first, "mlx-community/Qwen2.5-32B-Instruct-4bit")
        XCTAssertEqual(try fixture.trialRows().filter { $0.stage == 1 }.first?.model,
                       "mlx-community/Qwen2.5-32B-Instruct-4bit")
    }

    /// AC-15: Operator override beats size flags with a warning; SPEC-013 lines 1543-1547.
    func testAC15OperatorOverrideBeatsSizeFlags() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(["--candidate-models", "a,b,c", "--max-model-size", "7B"])
        var captured: [String] = []
        var deps = fixture.dependencies()
        deps.runStage1 = { request in
            captured = request.candidates
            let row = fixture.trial(runID: request.runID, stage: 1, model: "a", fits: true, aggTPS: 5, ttft: 800)
            try request.db.insertTrial(row)
            return Stage1IteratorResult(selectedModel: "a", trials: [row], exitReason: .ok)
        }

        try await command.run(dependencies: deps)

        XCTAssertEqual(captured, ["a", "b", "c"])
        XCTAssertTrue(fixture.stderr.contains("warning: --candidate-models supplied; ignoring --max-model-size/--min-model-size"))
    }

    /// AC-17: Operator-supplied order is honored verbatim without rerank; SPEC-013 lines 1559-1579.
    ///
    /// Note on alternates: SPEC-013 FR-F.1 requires `alternates` to list candidates
    /// that are SMALLER than the chosen model. v1's `RecommendationEmitter.alternates()`
    /// uses position-based slicing (candidateModels AFTER chosen index), which is
    /// CORRECT for the default-list largest-first input order but mis-surfaces
    /// alternates for arbitrary operator orders. For `--candidate-models 1b,32b`
    /// with 1B chosen, v1 lists 32B as an "alternate" even though 32B is LARGER.
    /// This is a documented v1 limitation; SPEC-013 v0.4 candidate fix is to plumb
    /// size-parsed orderings into the emitter (the existing AutotuneCommand
    /// `candidatesBySize(for:)` seam can be extended). For Step 11, this test
    /// asserts the LOCKED v1 behavior and the limitation is recorded in
    /// implementation-notes.html.
    func testAC17OperatorOrderHonoredVerbatim() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let oneB = "mlx-community/Llama-3.2-1B-Instruct-4bit"
        let thirtyTwoB = "mlx-community/Qwen2.5-32B-Instruct-4bit"
        let command = try fixture.command(["--candidate-models", "\(oneB),\(thirtyTwoB)"])
        var deps = fixture.dependencies()
        deps.runStage1 = { request in
            XCTAssertEqual(request.candidates, [oneB, thirtyTwoB])
            let row = fixture.trial(runID: request.runID, stage: 1, model: oneB, fits: true, aggTPS: 50, ttft: 100)
            try request.db.insertTrial(row)
            return Stage1IteratorResult(selectedModel: oneB, trials: [row], exitReason: .ok)
        }

        try await command.run(dependencies: deps)

        let stage1 = try fixture.trialRows().filter { $0.stage == 1 }
        XCTAssertEqual(stage1.map(\.model), [oneB], "iteration order is operator's order (not reranked)")
        let json = try fixture.latestRecommendationJSON()
        XCTAssertEqual(json.recommendationModel, oneB)
        // v1 position-based alternates: 32B appears even though it is LARGER than 1B.
        // Documented FR-F.1 deviation for arbitrary operator orders.
        XCTAssertEqual(json.alternates, [thirtyTwoB], "v1 position-based alternates (FR-F.1 deviation documented)")
    }

    /// AC-19: --max-model-size alone trims the default list; SPEC-013 lines 1593-1600.
    func testAC19MaxModelSizeAloneTrimsTheDefaultList() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(["--max-model-size", "8B"])
        var captured: [String] = []
        var deps = fixture.dependencies()
        deps.runStage1 = { request in
            captured = request.candidates
            let first = request.candidates[0]
            let row = fixture.trial(runID: request.runID, stage: 1, model: first, fits: true, aggTPS: 5, ttft: 800)
            try request.db.insertTrial(row)
            return Stage1IteratorResult(selectedModel: first, trials: [row], exitReason: .ok)
        }

        try await command.run(dependencies: deps)

        XCTAssertEqual(captured.first, "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        let models = try fixture.trialRows().map(\.model)
        XCTAssertFalse(models.contains("mlx-community/Qwen2.5-32B-Instruct-4bit"))
        XCTAssertFalse(models.contains("mlx-community/Qwen2.5-14B-Instruct-4bit"))
    }

    /// AC-19: --max-model-size with --min-model-size trims both ends; SPEC-013 lines 1593-1601.
    func testAC19MaxAndMinModelSizeTrimsBothEnds() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(["--max-model-size", "8B", "--min-model-size", "3B"])
        var captured: [String] = []
        var deps = fixture.dependencies()
        deps.runStage1 = { request in
            captured = request.candidates
            let first = request.candidates[0]
            let row = fixture.trial(runID: request.runID, stage: 1, model: first, fits: true, aggTPS: 5, ttft: 800)
            try request.db.insertTrial(row)
            return Stage1IteratorResult(selectedModel: first, trials: [row], exitReason: .ok)
        }

        try await command.run(dependencies: deps)

        XCTAssertEqual(captured, [
            "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
        ])
        XCTAssertFalse(captured.contains("mlx-community/Llama-3.2-1B-Instruct-4bit"))
    }
}

final class AutotuneACTestFixture {
    private let testCase: XCTestCase
    private let directory: URL
    let dbURL: URL
    let configURL: URL
    var stdout = ""
    var stderr = ""
    var runIDCounter = 0
    let nowDate = Date(timeIntervalSince1970: 1_781_740_800)

    init(testCase: XCTestCase) throws {
        self.testCase = testCase
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autotune-ac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("autotune.sqlite")
        configURL = directory.appendingPathComponent("config.yaml")
        testCase.addTeardownBlock { [directory] in
            try? FileManager.default.removeItem(at: directory)
        }
    }

    var now: () -> Date {
        { [nowDate] in nowDate }
    }

    func command(_ extra: [String] = [], targetContext: Int = 2_000) throws -> AutotuneCommand {
        try AutotuneCommand.parse([
            "--db-path", dbURL.path,
            "--target-context", "\(targetContext)",
            "--stage2-replicates", "1",
        ] + extra)
    }

    func dependencies() -> AutotuneRunDependencies {
        AutotuneRunDependencies(
            now: now,
            makeRunID: { [weak self] in
                guard let self else { return "run-deallocated" }
                self.runIDCounter += 1
                return "run-\(self.runIDCounter)"
            },
            makeInterruptFlag: AutotuneInterruptFlag.init,
            installSignalSources: { _ in nil },
            machineFingerprint: {
                MachineFingerprint(ramGB: 64, chip: "Apple M-test", osVersion: "macOS test", binaryVersion: "test-version")
            },
            makeDB: { try AutotuneDB(path: $0) },
            detectConflict: { .none },
            drainConflict: { _, _, _ in .drained },
            restoreConflict: { _, _ in .skipped },
            runStage1: { request in
                let selected = request.candidates[0]
                let row = self.trial(runID: request.runID, stage: 1, model: selected, fits: true, aggTPS: 10, ttft: 500)
                try request.db.insertTrial(row)
                return Stage1IteratorResult(selectedModel: selected, trials: [row], exitReason: .ok)
            },
            runStage2: { request in
                let row = self.trial(
                    runID: request.runID,
                    stage: 2,
                    model: request.selectedModel,
                    fits: true,
                    aggTPS: 12.5,
                    ttft: 700,
                    kvBits: 4,
                    maxContext: request.targetContext,
                    maxBatch: 1,
                    replicates: request.stage2Replicates,
                    kept: true
                )
                try request.db.insertTrial(row)
                return Stage2HillClimbResult(
                    selectedModel: request.selectedModel,
                    winningKnobs: WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: request.targetContext),
                    medianTPS: 12.5,
                    p95TTFTMS: 700,
                    replicates: request.stage2Replicates,
                    cellTrials: [row]
                )
            },
            emitRecommendation: { try RecommendationEmitter().build($0) },
            applyConfig: { _, _, _ in
                ConfigApplier.AppliedConfig(
                    backupPath: URL(fileURLWithPath: "/tmp/config.yaml.bak"),
                    summary: "applied test summary"
                )
            },
            writeStdout: { [weak self] in self?.stdout += $0 },
            writeStderr: { [weak self] in self?.stderr += $0 }
        )
    }

    func trial(
        runID: String,
        stage: Int,
        model: String,
        fits: Bool,
        notes: String? = nil,
        aggTPS: Double? = nil,
        ttft: Double? = nil,
        kvBits: Int? = nil,
        maxContext: Int? = nil,
        maxBatch: Int? = nil,
        replicates: Int = 1,
        kept: Bool = false
    ) -> AutotuneTrialRow {
        AutotuneTrialRow(
            tsUTC: "2026-06-18T00:00:00.000Z",
            runID: runID,
            stage: stage,
            model: model,
            targetContext: maxContext ?? 2_000,
            measuredPromptTokens: fits ? 1_600 : nil,
            maxTokens: 64,
            aggThroughputTPS: fits ? aggTPS : nil,
            ttftP95MS: fits ? ttft : nil,
            fits: fits,
            nErr: fits ? 0 : 1,
            kept: kept,
            notes: notes,
            kvBits: kvBits,
            maxContextCap: maxContext,
            maxBatch: maxBatch,
            replicatesN: replicates
        )
    }

    @discardableResult
    func assertExit(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ExitCode {
        do {
            try await operation()
            XCTFail("expected ExitCode", file: file, line: line)
            return .success
        } catch let exit as ExitCode {
            return exit
        }
    }

    func latestRunRow() throws -> AutotuneACRunRow {
        try runRows().last ?? {
            throw NSError(domain: "AutotuneACTestFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no tune_runs rows"])
        }()
    }

    func runRows() throws -> [AutotuneACRunRow] {
        let handle = try openSQLite()
        defer { sqlite3_close(handle) }
        let sql = """
        SELECT run_id, ended_at_utc, recommendation_json, recipe_hash, applied, exit_reason
        FROM tune_runs
        ORDER BY rowid ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw sqliteError(handle, fallback: "prepare tune_runs failed")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [AutotuneACRunRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(AutotuneACRunRow(
                runID: stringOrNil(statement, 0) ?? "",
                endedAtUTC: stringOrNil(statement, 1),
                recommendationJSON: stringOrNil(statement, 2),
                recipeHash: stringOrNil(statement, 3),
                applied: Int(sqlite3_column_int64(statement, 4)),
                exitReason: stringOrNil(statement, 5) ?? ""
            ))
        }
        return rows
    }

    func trialRows() throws -> [AutotuneTrialRow] {
        let handle = try openSQLite()
        defer { sqlite3_close(handle) }
        let sql = """
        SELECT ts_utc, run_id, stage, model, target_context,
               measured_prompt_tokens, max_tokens, agg_throughput_tps,
               ttft_p95_ms, fits, n_err, kept, notes,
               kv_bits, max_context_cap, max_batch, replicates_n
        FROM tune_trials
        ORDER BY id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw sqliteError(handle, fallback: "prepare tune_trials failed")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [AutotuneTrialRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(AutotuneTrialRow(
                tsUTC: stringOrNil(statement, 0) ?? "",
                runID: stringOrNil(statement, 1) ?? "",
                stage: intOrNil(statement, 2) ?? 0,
                model: stringOrNil(statement, 3) ?? "",
                targetContext: intOrNil(statement, 4) ?? 0,
                measuredPromptTokens: intOrNil(statement, 5),
                maxTokens: intOrNil(statement, 6) ?? 0,
                aggThroughputTPS: doubleOrNil(statement, 7),
                ttftP95MS: doubleOrNil(statement, 8),
                fits: (intOrNil(statement, 9) ?? 0) == 1,
                nErr: intOrNil(statement, 10) ?? 0,
                kept: (intOrNil(statement, 11) ?? 0) == 1,
                notes: stringOrNil(statement, 12),
                kvBits: intOrNil(statement, 13),
                maxContextCap: intOrNil(statement, 14),
                maxBatch: intOrNil(statement, 15),
                replicatesN: intOrNil(statement, 16)
            ))
        }
        return rows
    }

    func latestRecommendationJSON() throws -> AutotuneACRecommendationJSON {
        let json = try XCTUnwrap(latestRunRow().recommendationJSON)
        let data = Data(json.utf8)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let root else {
            throw NSError(domain: "AutotuneACTestFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "recommendation_json is not an object"])
        }
        let recommendation = root["recommendation"] as? [String: Any]
        return AutotuneACRecommendationJSON(
            root: root,
            recommendation: recommendation,
            recommendationModel: recommendation?["model"] as? String,
            alternates: root["alternates"] as? [String] ?? []
        )
    }

    func emittedJSONFromStdout() throws -> [String: Any] {
        guard let start = stdout.firstIndex(of: "{") else {
            throw NSError(domain: "AutotuneACTestFixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "stdout did not contain JSON"])
        }
        let json = String(stdout[start...])
        let data = Data(json.utf8)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AutotuneACTestFixture", code: 4, userInfo: [NSLocalizedDescriptionKey: "stdout JSON is not an object"])
        }
        return root
    }

    private func openSQLite() throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else {
            throw NSError(domain: "AutotuneACTestFixture", code: 5, userInfo: [NSLocalizedDescriptionKey: "could not open sqlite fixture"])
        }
        return handle
    }

    private func intOrNil(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(statement, column))
    }

    private func doubleOrNil(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        return sqlite3_column_double(statement, column)
    }

    private func stringOrNil(_ statement: OpaquePointer, _ column: Int32) -> String? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    private func sqliteError(_ handle: OpaquePointer, fallback: String) -> NSError {
        let message = sqlite3_errmsg(handle).map { String(cString: $0) } ?? fallback
        return NSError(domain: "AutotuneACTestFixture", code: Int(sqlite3_errcode(handle)), userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}

struct AutotuneACRunRow {
    var runID: String
    var endedAtUTC: String?
    var recommendationJSON: String?
    var recipeHash: String?
    var applied: Int
    var exitReason: String
}

struct AutotuneACRecommendationJSON {
    var root: [String: Any]
    var recommendation: [String: Any]?
    var recommendationModel: String?
    var alternates: [String]
}

final class AutotuneACStubProviderRunner: Stage1ProviderRunning {
    func start(model: String, port: Int, kvBits: Int?, maxContext: Int?, maxBatch: Int?) throws {}
    func waitForReady(timeout: TimeInterval) async throws -> ReadyStatus { .ready }
    func stop(graceSeconds: Double) -> StopResult { .stopped }
}

final class AutotuneACStubPreWarmer: Stage1PreWarming {
    private let results: [String: PreWarmResult]

    init(results: [String: PreWarmResult]) {
        self.results = results
    }

    func prewarmAndProbe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        readyTimeoutSec: TimeInterval
    ) async throws -> PreWarmResult {
        results[model] ?? .failed(failureClass: .transient, reason: "missing pre-warm result")
    }
}

final class AutotuneACStubStage1Prober: Stage1Probing {
    private let results: [String: Stage1ProbeResult]

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
        results[model] ?? .infeasible(reason: "missing Stage 1 result", nErr: 1)
    }
}
