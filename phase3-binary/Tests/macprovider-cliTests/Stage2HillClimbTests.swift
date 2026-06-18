import Foundation
import SQLite3
import XCTest
@testable import macprovider_cli

final class Stage2HillClimbTests: XCTestCase {
    func testStage2HillClimbPicksFirstFeasibleAsBaseline() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prober = StubStage2Prober(results: [
            .feasible(medianTPS: 10, p95TTFTMS: 900, measuredPromptTokens: 1_600),
        ])

        let result = try await makeHillClimb(
            db: db,
            prober: prober,
            kvBitsAxis: [nil],
            maxBatchAxis: [1],
            maxContextAxis: [2_000]
        ).run()

        XCTAssertEqual(result.selectedModel, "selected-model")
        XCTAssertEqual(result.winningKnobs, WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 2_000))
        XCTAssertEqual(result.medianTPS, 10)
        XCTAssertEqual(result.p95TTFTMS, 900)
        XCTAssertEqual(result.replicates, 1)
        XCTAssertEqual(result.cellTrials.count, 1)
        XCTAssertTrue(result.cellTrials[0].kept)
        XCTAssertEqual(try persistedTrialRows(at: dbURL).count, 1)
    }

    func testStage2HillClimbAppliesIsNewBestThroughputPrimary() async throws {
        let db = try AutotuneDB(path: try temporaryDBURL().path)
        let prober = StubStage2Prober(results: [
            .feasible(medianTPS: 10, p95TTFTMS: 700, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 12, p95TTFTMS: 900, measuredPromptTokens: 1_600),
        ])

        let result = try await makeHillClimb(
            db: db,
            prober: prober,
            kvBitsAxis: [nil, 4],
            maxBatchAxis: [1],
            maxContextAxis: [2_000]
        ).run()

        XCTAssertEqual(result.winningKnobs, WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 2_000))
        XCTAssertEqual(result.medianTPS, 12)
        XCTAssertEqual(result.cellTrials.map(\.kept), [true, true])
    }

    func testStage2HillClimbAppliesIsNewBestTTFTTiebreak() async throws {
        let db = try AutotuneDB(path: try temporaryDBURL().path)
        let prober = StubStage2Prober(results: [
            .feasible(medianTPS: 10, p95TTFTMS: 1_000, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 10.1, p95TTFTMS: 800, measuredPromptTokens: 1_600),
        ])

        let result = try await makeHillClimb(
            db: db,
            prober: prober,
            kvBitsAxis: [nil, 4],
            maxBatchAxis: [1],
            maxContextAxis: [2_000]
        ).run()

        XCTAssertEqual(result.winningKnobs, WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 2_000))
        XCTAssertEqual(result.p95TTFTMS, 800)
        XCTAssertEqual(result.cellTrials.map(\.kept), [true, true])
    }

    func testStage2HillClimbRejectsCellWhenAnyReplicateInfeasible() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prober = StubStage2Prober(results: [
            .infeasible(reason: "TTFT 61000ms exceeded gate 60000ms", nErr: 1, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 9, p95TTFTMS: 900, measuredPromptTokens: 1_600),
        ])

        let result = try await makeHillClimb(
            db: db,
            prober: prober,
            kvBitsAxis: [nil, 4],
            maxBatchAxis: [1],
            maxContextAxis: [2_000],
            stage2Replicates: 3
        ).run()

        XCTAssertEqual(result.winningKnobs, WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 2_000))
        XCTAssertEqual(result.cellTrials.count, 2)
        XCTAssertFalse(result.cellTrials[0].fits)
        XCTAssertNil(result.cellTrials[0].aggThroughputTPS)
        XCTAssertNil(result.cellTrials[0].ttftP95MS)
        XCTAssertEqual(result.cellTrials[0].replicatesN, 3)
        XCTAssertEqual(try persistedTrialRows(at: dbURL)[0].aggThroughputTPS, nil)
    }

    func testStage2HillClimbAllCellsInfeasibleThrowsNoFeasibleCell() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prober = StubStage2Prober(results: [
            .infeasible(reason: "HTTP 503", nErr: 1, measuredPromptTokens: nil),
            .infeasible(reason: "provider exited", nErr: 1, measuredPromptTokens: nil),
        ])

        do {
            _ = try await makeHillClimb(
                db: db,
                prober: prober,
                kvBitsAxis: [nil, 4],
                maxBatchAxis: [1],
                maxContextAxis: [2_000]
            ).run()
            XCTFail("expected no feasible cell")
        } catch let error as Stage2HillClimbError {
            guard case .noFeasibleCell(let reason) = error else {
                return XCTFail("expected noFeasibleCell, got \(error)")
            }
            XCTAssertTrue(reason.contains("HTTP 503"), reason)
            XCTAssertTrue(reason.contains("provider exited"), reason)
            XCTAssertTrue(error.description.contains("Stage 2 found no feasible knob cell"))
        }

        XCTAssertEqual(try persistedTrialRows(at: dbURL).count, 2)
    }

    func testStage2HillClimbPersistsAllCellTrialsWithStageTwo() async throws {
        let dbURL = try temporaryDBURL()
        let db = try AutotuneDB(path: dbURL.path)
        let prober = StubStage2Prober(results: [
            .feasible(medianTPS: 10, p95TTFTMS: 900, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 11, p95TTFTMS: 850, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 9, p95TTFTMS: 700, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 10.5, p95TTFTMS: 950, measuredPromptTokens: 1_600),
        ])

        _ = try await makeHillClimb(
            db: db,
            prober: prober,
            kvBitsAxis: [nil, 4],
            maxBatchAxis: [1, 2],
            maxContextAxis: [2_000],
            stage2Replicates: 2
        ).run()

        let rows = try persistedTrialRows(at: dbURL)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.stage), [2, 2, 2, 2])
        XCTAssertEqual(rows.map(\.kvBits), [nil, nil, 4, 4])
        XCTAssertEqual(rows.map(\.maxBatch), [1, 2, 1, 2])
        XCTAssertEqual(rows.map(\.maxContextCap), [2_000, 2_000, 2_000, 2_000])
        XCTAssertEqual(rows.map(\.replicatesN), [2, 2, 2, 2])
        XCTAssertEqual(prober.probedKnobs, [
            WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 2_000),
            WinningKnobs(kvBits: nil, maxBatch: 2, maxContext: 2_000),
            WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 2_000),
            WinningKnobs(kvBits: 4, maxBatch: 2, maxContext: 2_000),
        ])
    }

    func testStage2HillClimbHonorsTPSTieEpsilon() async throws {
        let db = try AutotuneDB(path: try temporaryDBURL().path)
        let prober = StubStage2Prober(results: [
            .feasible(medianTPS: 10, p95TTFTMS: 800, measuredPromptTokens: 1_600),
            .feasible(medianTPS: 10.05, p95TTFTMS: 900, measuredPromptTokens: 1_600),
        ])

        let result = try await makeHillClimb(
            db: db,
            prober: prober,
            kvBitsAxis: [nil, 4],
            maxBatchAxis: [1],
            maxContextAxis: [2_000],
            tpsTieEpsilon: 0.02
        ).run()

        XCTAssertEqual(result.winningKnobs, WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 2_000))
        XCTAssertEqual(result.medianTPS, 10)
        XCTAssertEqual(result.cellTrials.map(\.kept), [true, false])
    }

    private func makeHillClimb(
        db: AutotuneDB,
        prober: StubStage2Prober,
        kvBitsAxis: [Int?],
        maxBatchAxis: [Int],
        maxContextAxis: [Int],
        stage2Replicates: Int = 1,
        tpsTieEpsilon: Double = 0.02
    ) -> Stage2HillClimb {
        Stage2HillClimb(
            candidateProviderRunner: { StubStage2ProviderRunner() },
            prober: prober,
            autotuneDB: db,
            selectedModel: "selected-model",
            kvBitsAxis: kvBitsAxis,
            maxBatchAxis: maxBatchAxis,
            maxContextAxis: maxContextAxis,
            targetContext: 2_000,
            gateTTFTMS: 60_000,
            stage2Replicates: stage2Replicates,
            tpsTieEpsilon: tpsTieEpsilon,
            port: 18_080,
            runID: "stage2-test-run",
            now: { Date(timeIntervalSince1970: 1_781_740_800) }
        )
    }

    private func temporaryDBURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage2-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("autotune.sqlite")
    }

    private func persistedTrialRows(at url: URL) throws -> [AutotuneTrialRow] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else {
            throw NSError(domain: "Stage2HillClimbTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "could not open sqlite fixture",
            ])
        }
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
            throw sqliteError(handle, fallback: "prepare failed")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [AutotuneTrialRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func intOrNil(_ column: Int32) -> Int? {
                if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
                return Int(sqlite3_column_int64(statement, column))
            }
            func doubleOrNil(_ column: Int32) -> Double? {
                if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
                return sqlite3_column_double(statement, column)
            }
            func stringOrNil(_ column: Int32) -> String? {
                if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
                guard let cString = sqlite3_column_text(statement, column) else { return nil }
                return String(cString: cString)
            }

            rows.append(AutotuneTrialRow(
                tsUTC: stringOrNil(0) ?? "",
                runID: stringOrNil(1) ?? "",
                stage: intOrNil(2) ?? 0,
                model: stringOrNil(3) ?? "",
                targetContext: intOrNil(4) ?? 0,
                measuredPromptTokens: intOrNil(5),
                maxTokens: intOrNil(6) ?? 0,
                aggThroughputTPS: doubleOrNil(7),
                ttftP95MS: doubleOrNil(8),
                fits: (intOrNil(9) ?? 0) == 1,
                nErr: intOrNil(10) ?? 0,
                kept: (intOrNil(11) ?? 0) == 1,
                notes: stringOrNil(12),
                kvBits: intOrNil(13),
                maxContextCap: intOrNil(14),
                maxBatch: intOrNil(15),
                replicatesN: intOrNil(16)
            ))
        }
        return rows
    }

    private func sqliteError(_ handle: OpaquePointer, fallback: String) -> NSError {
        let message = sqlite3_errmsg(handle).map { String(cString: $0) } ?? fallback
        return NSError(domain: "Stage2HillClimbTests", code: Int(sqlite3_errcode(handle)), userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}

private final class StubStage2ProviderRunner: Stage1ProviderRunning {
    func start(
        model: String,
        port: Int,
        kvBits: Int?,
        maxContext: Int?,
        maxBatch: Int?
    ) throws {}

    func waitForReady(timeout: TimeInterval) async throws -> ReadyStatus {
        .ready
    }

    func stop(graceSeconds: Double) -> StopResult {
        .stopped
    }
}

private final class StubStage2Prober: Stage2Probing {
    private var results: [Stage2ProbeResult]
    private(set) var probedKnobs: [WinningKnobs] = []

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
        probedKnobs.append(knobs)
        if results.isEmpty {
            return .infeasible(reason: "missing stub probe result", nErr: 1, measuredPromptTokens: nil)
        }
        return results.removeFirst()
    }
}
