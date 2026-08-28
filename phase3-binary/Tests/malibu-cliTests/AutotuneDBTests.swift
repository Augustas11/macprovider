import Foundation
import SQLite3
import XCTest
@testable import malibu_cli

final class AutotuneDBTests: XCTestCase {
    func testFreshDBCreationCreatesSchemaAtPath() throws {
        let dbURL = try temporaryDBURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))

        do {
            _ = try AutotuneDB(path: dbURL.path)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertTrue(try tableColumns("tune_trials", at: dbURL).contains("stage"))
        XCTAssertTrue(try tableColumns("tune_runs", at: dbURL).contains("exit_reason"))
    }

    func testPrototypeTrialSchemaMigrationAddsStageColumnWithDefault() throws {
        let dbURL = try temporaryDBURL()
        try createPrototypeDBWithoutStage(at: dbURL)

        do {
            _ = try AutotuneDB(path: dbURL.path)
        }

        let columns = try tableColumns("tune_trials", at: dbURL)
        XCTAssertTrue(columns.contains("stage"))
        XCTAssertTrue(columns.contains("replicates_n"))
        XCTAssertEqual(
            try scalarInt("""
            SELECT COUNT(*)
            FROM pragma_table_info('tune_trials')
            WHERE name = 'stage' AND "notnull" = 1 AND dflt_value = '1'
            """, at: dbURL),
            1
        )
        XCTAssertEqual(
            try scalarInt("SELECT stage FROM tune_trials WHERE run_id = 'prototype-run'", at: dbURL),
            1
        )
    }

    func testRetentionSweepDeletesOldestRunsAndTrialsTransactionally() throws {
        let dbURL = try temporaryDBURL()

        do {
            let db = try AutotuneDB(path: dbURL.path)
            for index in 0..<52 {
                let runID = String(format: "run-%03d", index)
                try db.insertRun(makeRun(runID: runID, startedAtUTC: String(format: "2026-06-18T00:%02d:00Z", index)))
                try db.insertTrial(makeTrial(runID: runID))
            }
            try db.applyRetentionInTransaction(retainRuns: 50)
        }

        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM tune_runs", at: dbURL), 50)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM tune_trials", at: dbURL), 50)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM tune_runs WHERE run_id IN ('run-000', 'run-001')", at: dbURL), 0)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM tune_trials WHERE run_id IN ('run-000', 'run-001')", at: dbURL), 0)
        XCTAssertEqual(
            try scalarInt("""
            SELECT COUNT(*)
            FROM tune_trials
            LEFT JOIN tune_runs ON tune_trials.run_id = tune_runs.run_id
            WHERE tune_runs.run_id IS NULL
            """, at: dbURL),
            0
        )
    }

    func testInsertRunRejectsInvalidExitReason() throws {
        let db = try AutotuneDB(path: ":memory:")
        var run = makeRun(runID: "bad-exit-reason")
        run.exitReason = "operator_said_nope"

        XCTAssertThrowsError(try db.insertRun(run)) { error in
            XCTAssertEqual(error as? AutotuneDBError, .invalidExitReason("operator_said_nope"))
        }
    }

    private func makeRun(
        runID: String,
        startedAtUTC: String = "2026-06-18T00:00:00Z"
    ) -> AutotuneRunRow {
        AutotuneRunRow(
            runID: runID,
            startedAtUTC: startedAtUTC,
            endedAtUTC: "2026-06-18T00:00:01Z",
            specVersion: "SPEC-013 v0.3",
            binaryVersion: "test",
            machineRAMGB: 64,
            machineChip: "Apple M-test",
            machineOSVersion: "macOS test",
            targetContext: 2_000,
            candidateModelsJSON: #"["model-a"]"#,
            stage1Replicates: 1,
            stage2Replicates: 3,
            gateTTFTMS: 60_000,
            tpsTieEpsilon: 0.02,
            recommendationJSON: #"{"model":"model-a"}"#,
            recipeHash: "hash-\(runID)",
            applied: false,
            exitReason: AutotuneExitReason.ok.rawValue
        )
    }

    private func makeTrial(runID: String) -> AutotuneTrialRow {
        AutotuneTrialRow(
            tsUTC: "2026-06-18T00:00:00Z",
            runID: runID,
            stage: 1,
            model: "model-a",
            targetContext: 2_000,
            measuredPromptTokens: 1_900,
            maxTokens: 64,
            aggThroughputTPS: 10.5,
            ttftP95MS: 1_000,
            fits: true,
            nErr: 0,
            kept: false,
            notes: nil,
            kvBits: nil,
            maxContextCap: 2_000,
            maxBatch: 1,
            replicatesN: 1
        )
    }

    private func temporaryDBURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-autotune-db-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("autotune.sqlite")
    }

    private func createPrototypeDBWithoutStage(at url: URL) throws {
        let handle = try openSQLite(at: url)
        defer { sqlite3_close(handle) }

        try exec(handle, """
        CREATE TABLE tune_trials (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts_utc TEXT NOT NULL,
            run_id TEXT NOT NULL,
            model TEXT NOT NULL,
            target_context INTEGER NOT NULL,
            measured_prompt_tokens INTEGER,
            max_tokens INTEGER NOT NULL,
            agg_throughput_tps REAL,
            ttft_p95_ms REAL,
            fits INTEGER NOT NULL DEFAULT 0,
            n_err INTEGER NOT NULL DEFAULT 0,
            kept INTEGER NOT NULL DEFAULT 0,
            notes TEXT,
            max_context_cap INTEGER,
            max_batch INTEGER
        )
        """)
        try exec(handle, """
        INSERT INTO tune_trials
            (ts_utc, run_id, model, target_context, max_tokens)
        VALUES
            ('2026-06-18T00:00:00Z', 'prototype-run', 'model-a', 2000, 64)
        """)
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            defer { sqlite3_free(error) }
            let message = error.map { String(cString: $0) } ?? "unknown sqlite fixture error"
            throw NSError(domain: "AutotuneDBTests", code: Int(sqlite3_errcode(handle)), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }

    private func tableColumns(_ table: String, at url: URL) throws -> [String] {
        let handle = try openSQLite(at: url)
        defer { sqlite3_close(handle) }

        let statement = try prepare("PRAGMA table_info(\(table))", in: handle)
        defer { sqlite3_finalize(statement) }

        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 1) {
                columns.append(String(cString: cString))
            }
        }
        return columns
    }

    private func scalarInt(_ sql: String, at url: URL) throws -> Int {
        let handle = try openSQLite(at: url)
        defer { sqlite3_close(handle) }

        let statement = try prepare(sql, in: handle)
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError(handle, fallback: "query returned no rows")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepare(_ sql: String, in handle: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw sqliteError(handle, fallback: "prepare failed")
        }
        return statement
    }

    private func openSQLite(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle
        else {
            throw NSError(domain: "AutotuneDBTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "could not open sqlite fixture",
            ])
        }
        return handle
    }

    private func sqliteError(_ handle: OpaquePointer, fallback: String) -> NSError {
        let message = sqlite3_errmsg(handle).map { String(cString: $0) } ?? fallback
        return NSError(domain: "AutotuneDBTests", code: Int(sqlite3_errcode(handle)), userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
