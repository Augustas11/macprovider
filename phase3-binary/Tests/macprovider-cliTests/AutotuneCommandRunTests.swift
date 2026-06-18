import ArgumentParser
import Foundation
import SQLite3
import XCTest
@testable import macprovider_cli

final class AutotuneCommandRunTests: XCTestCase {
    func testRunWritesTuneRunRowOnOK() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command()

        try await command.run(dependencies: fixture.dependencies())

        let row = try fixture.runRow()
        XCTAssertEqual(row.exitReason, "ok")
        XCTAssertNotNil(row.endedAtUTC)
        XCTAssertNotNil(row.recommendationJSON)
        XCTAssertNotNil(row.recipeHash)
    }

    func testRunWritesTuneRunRowOnNoFeasible() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command(["--max-model-size", "3B"])
        var deps = fixture.dependencies()
        deps.runStage1 = { _ in
            throw Stage1IteratorError.noFeasible(
                reason: "mlx-community/Llama-3.2-1B-Instruct-4bit: even smallest failed",
                trials: ["even smallest failed", "3B failed"],
                exitReason: .noFeasible
            )
        }

        try await assertExit { try await command.run(dependencies: deps) }

        let row = try fixture.runRow()
        XCTAssertEqual(row.exitReason, "no_feasible")
        XCTAssertNil(row.recommendationJSON)
        XCTAssertNil(row.recipeHash)
        XCTAssertTrue(fixture.stdout.contains("rank 1 mlx-community/Llama-3.2-1B-Instruct-4bit"))
    }

    func testRunWritesTuneRunRowOnBudgetExhaustedStage1() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command(["--json"])
        var deps = fixture.dependencies()
        deps.runStage1 = { _ in
            throw Stage1IteratorError.budgetExhaustedNoModelSelected
        }

        try await assertExit { try await command.run(dependencies: deps) }

        let row = try fixture.runRow()
        XCTAssertEqual(row.exitReason, "budget_exhausted_no_model_selected")
        XCTAssertNil(row.recommendationJSON)
        XCTAssertNil(row.recipeHash)
        XCTAssertTrue(fixture.stdout.contains(#""recommendation" : null"#), fixture.stdout)
    }

    func testRunWritesTuneRunRowOnBudgetExhaustedStage2() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command(["--json"])
        var deps = fixture.dependencies()
        deps.runStage2 = { _ in
            throw Stage2HillClimbError.budgetExhaustedWithPartialRecommendation(fixture.stage2Result())
        }

        try await assertExit { try await command.run(dependencies: deps) }

        let row = try fixture.runRow()
        XCTAssertEqual(row.exitReason, "budget_exhausted_with_partial_recommendation")
        let json = try XCTUnwrap(row.recommendationJSON)
        XCTAssertTrue(json.contains(#""partial" : true"#), json)
        XCTAssertTrue(fixture.stdout.contains("partial recommendation"), fixture.stdout)
    }

    func testRunWritesTuneRunRowOnProviderConflict() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command()
        var deps = fixture.dependencies()
        deps.detectConflict = { .foreground(pid: 123, argv: ["macprovider-cli", "serve"]) }

        try await assertExit { try await command.run(dependencies: deps) }

        let row = try fixture.runRow()
        XCTAssertEqual(row.exitReason, "provider_conflict")
        XCTAssertNil(row.recommendationJSON)
    }

    func testRunWritesTuneRunRowOnPreWarmIntegrityFailure() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command()
        var deps = fixture.dependencies()
        deps.runStage1 = { _ in
            throw Stage1IteratorError.preWarmIntegrityFailure(
                model: "model-a",
                reason: "signature mismatch",
                exitReason: .preWarmIntegrityFailure
            )
        }

        try await assertExit { try await command.run(dependencies: deps) }

        let row = try fixture.runRow()
        XCTAssertEqual(row.exitReason, "pre_warm_integrity_failure")
        XCTAssertNil(row.recommendationJSON)
    }

    func testCandidatesBySizeIsSortedAscendingFromDefaultList() throws {
        let command = try AutotuneCommand.parse(["--dry-run"])
        let plan = try command.candidatePlan()

        XCTAssertEqual(AutotuneCommand.candidatesBySize(for: plan), [
            "mlx-community/Llama-3.2-1B-Instruct-4bit",
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            "mlx-community/Qwen2.5-14B-Instruct-4bit",
            "mlx-community/Qwen2.5-32B-Instruct-4bit",
        ])
    }

    // Round-1 audit M.1 CRITICAL fix: operator override now returns input
    // order explicitly so the LOCKED Stage1Iterator nil fallback (reversed)
    // is preserved but never triggered from production code. The pre-fix
    // behavior (return nil) silently relied on the LOCKED fallback to mean
    // "input order" — but the LOCKED fallback semantics is
    // `Array(candidates.reversed())`, not `candidates`.
    func testCandidatesBySizeReturnsInputOrderForOperatorOverride() throws {
        let command = try AutotuneCommand.parse(["--candidate-models", "a,b", "--dry-run"])
        let plan = try command.candidatePlan()

        XCTAssertEqual(AutotuneCommand.candidatesBySize(for: plan), ["a", "b"])
    }

    func testInterruptionFlagCancelsLoopAtNextPoll() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command()
        var deps = fixture.dependencies()
        deps.makeInterruptFlag = {
            let flag = AutotuneInterruptFlag()
            flag.set()
            return flag
        }

        let exitCode = try await assertExit { try await command.run(dependencies: deps) }

        XCTAssertEqual(exitCode, ExitCode(130))
        XCTAssertFalse(fixture.stage1Called)
    }

    func testInterruptedSetsTuneRunExitReason() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command()
        var deps = fixture.dependencies()
        deps.makeInterruptFlag = {
            let flag = AutotuneInterruptFlag()
            flag.set()
            return flag
        }

        try await assertExit { try await command.run(dependencies: deps) }

        let row = try fixture.runRow()
        XCTAssertEqual(row.exitReason, "interrupted")
        XCTAssertNil(row.endedAtUTC)
    }

    // Round-1 audit B.1 MAJOR regression-lock: an interrupt arriving AFTER
    // Stage 2 returns but BEFORE recommendation emission / apply must be
    // honored, not silently swallowed by finalizing as `ok`.
    func testInterruptionAfterStage2CancelsBeforeApply() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command(["--apply"])
        let flag = AutotuneInterruptFlag()
        var deps = fixture.dependencies()
        deps.makeInterruptFlag = { flag }
        let originalRunStage2 = deps.runStage2
        deps.runStage2 = { request in
            let result = try await originalRunStage2(request)
            flag.set()
            return result
        }

        let exitCode = try await assertExit { try await command.run(dependencies: deps) }

        XCTAssertEqual(exitCode, ExitCode(130))
        XCTAssertEqual(fixture.applyCalls, 0, "--apply must not be called when interrupted after Stage 2")
        let row = try fixture.runRow()
        XCTAssertEqual(row.exitReason, "interrupted")
        XCTAssertNil(row.endedAtUTC)
    }

    // Round-1 audit J.1 MAJOR regression-lock: a drain failure (e.g.
    // launchctl bootout throws) classifies as `provider_conflict`, not
    // `internal_error`. It is still a conflict scenario, known-classifiable
    // per FR-G.2.
    func testDrainConflictThrowFinalizesAsProviderConflict() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command(["--drain"])
        var deps = fixture.dependencies()
        deps.detectConflict = { .foreground(pid: 123, argv: ["macprovider-cli", "serve"]) }
        deps.drainConflict = { _, _, _ in
            throw NSError(domain: "DrainTest", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "launchctl bootout failed",
            ])
        }

        let exitCode = try await assertExit { try await command.run(dependencies: deps) }

        XCTAssertEqual(exitCode, ExitCode(1))
        let row = try fixture.runRow()
        XCTAssertEqual(row.exitReason, "provider_conflict")
        XCTAssertTrue(fixture.stderr.contains("--drain failed"), fixture.stderr)
    }

    // Round-1 audit K.1 MINOR regression-lock: machine_ram_gb fallback
    // never drops to 0 — when sysctl fails or returns zero, the
    // documented minimum is 1 (FR-G.2 schema NOT NULL + recipe_hash
    // machine-sensitivity intent).
    func testMachineFingerprinterRAMNeverReturnsZero() {
        let sample = MachineFingerprinter().sample()
        XCTAssertGreaterThanOrEqual(sample.ramGB, 1)
    }

    func testApplyFlagInvokesConfigApplier() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command(["--apply"])

        try await command.run(dependencies: fixture.dependencies())

        XCTAssertEqual(fixture.applyCalls, 1)
        XCTAssertTrue(fixture.stdout.contains("applied test summary"))
    }

    func testApplyFlagSetsAppliedColumnInTuneRuns() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command(["--apply"])

        try await command.run(dependencies: fixture.dependencies())

        XCTAssertEqual(try fixture.runRow().applied, 1)
    }

    func testApplyFailureDoesNotSetAppliedColumn() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command(["--apply"])
        var deps = fixture.dependencies()
        deps.applyConfig = { _, _, _ in
            throw ConfigApplierError.backupCollisionsExhausted
        }

        try await command.run(dependencies: deps)

        let row = try fixture.runRow()
        XCTAssertEqual(row.exitReason, "ok")
        XCTAssertEqual(row.applied, 0)
    }

    func testDrainFlagInvokesProviderDrainerOnConflict() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command(["--drain"])
        var deps = fixture.dependencies()
        deps.detectConflict = { .foreground(pid: 123, argv: ["macprovider-cli", "serve"]) }

        try await command.run(dependencies: deps)

        XCTAssertEqual(fixture.drainCalls, 1)
        XCTAssertEqual(try fixture.runRow().exitReason, "ok")
    }

    func testTerminalOutputForAllInfeasibleLeadsWithSmallestSize() async throws {
        let fixture = try Fixture(testCase: self)
        let command = try fixture.command(["--max-model-size", "3B"])
        var deps = fixture.dependencies()
        deps.runStage1 = { _ in
            throw Stage1IteratorError.noFeasible(
                reason: "mlx-community/Llama-3.2-1B-Instruct-4bit: 1B failed",
                trials: ["1B failed", "3B failed"],
                exitReason: .noFeasible
            )
        }

        try await assertExit { try await command.run(dependencies: deps) }

        XCTAssertTrue(fixture.stderr.contains("  1B (smallest): 1B failed"), fixture.stderr)
        let oneB = try XCTUnwrap(fixture.stderr.range(of: "1B (smallest)"))
        let threeB = try XCTUnwrap(fixture.stderr.range(of: "3B: 3B failed"))
        XCTAssertLessThan(oneB.lowerBound, threeB.lowerBound)
    }

    @discardableResult
    private func assertExit(
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
}

private final class Fixture {
    private let testCase: XCTestCase
    let dbURL: URL
    var stdout = ""
    var stderr = ""
    var stage1Called = false
    var stage2Called = false
    var applyCalls = 0
    var drainCalls = 0

    init(testCase: XCTestCase) throws {
        self.testCase = testCase
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autotune-command-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("autotune.sqlite")
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func command(_ extra: [String] = []) throws -> AutotuneCommand {
        try AutotuneCommand.parse([
            "--db-path", dbURL.path,
            "--target-context", "2000",
            "--stage2-replicates", "1",
        ] + extra)
    }

    func dependencies() -> AutotuneRunDependencies {
        AutotuneRunDependencies(
            now: { Date(timeIntervalSince1970: 1_781_740_800) },
            makeRunID: { "run-\(UUID().uuidString)" },
            makeInterruptFlag: AutotuneInterruptFlag.init,
            installSignalSources: { _ in nil },
            machineFingerprint: {
                MachineFingerprint(
                    ramGB: 64,
                    chip: "Apple M-test",
                    osVersion: "macOS test",
                    binaryVersion: "test-version"
                )
            },
            makeDB: { try AutotuneDB(path: $0) },
            detectConflict: { .none },
            drainConflict: { [weak self] _, _, _ in
                self?.drainCalls += 1
                return .drained
            },
            restoreConflict: { _, _ in .skipped },
            runStage1: { [weak self] _ in
                self?.stage1Called = true
                return Stage1IteratorResult(
                    selectedModel: "model-a",
                    trials: [],
                    exitReason: .ok
                )
            },
            runStage2: { [weak self] _ in
                self?.stage2Called = true
                return self?.stage2Result() ?? Stage2HillClimbResult(
                    selectedModel: "model-a",
                    winningKnobs: WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 2_000),
                    medianTPS: 10,
                    p95TTFTMS: 500,
                    replicates: 1,
                    cellTrials: []
                )
            },
            emitRecommendation: { try RecommendationEmitter().build($0) },
            applyConfig: { [weak self] _, _, _ in
                self?.applyCalls += 1
                return ConfigApplier.AppliedConfig(
                    backupPath: URL(fileURLWithPath: "/tmp/config.yaml.bak"),
                    summary: "applied test summary"
                )
            },
            writeStdout: { [weak self] in self?.stdout += $0 },
            writeStderr: { [weak self] in self?.stderr += $0 }
        )
    }

    func stage2Result() -> Stage2HillClimbResult {
        Stage2HillClimbResult(
            selectedModel: "model-a",
            winningKnobs: WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 2_000),
            medianTPS: 12.5,
            p95TTFTMS: 700,
            replicates: 1,
            cellTrials: []
        )
    }

    func runRow() throws -> RunRow {
        let handle = try openSQLite()
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = """
        SELECT ended_at_utc, recommendation_json, recipe_hash, applied, exit_reason
        FROM tune_runs
        ORDER BY started_at_utc DESC
        LIMIT 1
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw sqliteError(handle, fallback: "prepare failed")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError(handle, fallback: "no tune_runs rows")
        }
        return RunRow(
            endedAtUTC: stringOrNil(statement, 0),
            recommendationJSON: stringOrNil(statement, 1),
            recipeHash: stringOrNil(statement, 2),
            applied: Int(sqlite3_column_int64(statement, 3)),
            exitReason: stringOrNil(statement, 4) ?? ""
        )
    }

    private func openSQLite() throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else {
            throw NSError(domain: "AutotuneCommandRunTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "could not open sqlite fixture",
            ])
        }
        return handle
    }

    private func stringOrNil(_ statement: OpaquePointer, _ column: Int32) -> String? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL {
            return nil
        }
        guard let cString = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: cString)
    }

    private func sqliteError(_ handle: OpaquePointer, fallback: String) -> NSError {
        let message = sqlite3_errmsg(handle).map { String(cString: $0) } ?? fallback
        return NSError(domain: "AutotuneCommandRunTests", code: Int(sqlite3_errcode(handle)), userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}

private struct RunRow {
    var endedAtUTC: String?
    var recommendationJSON: String?
    var recipeHash: String?
    var applied: Int
    var exitReason: String
}
