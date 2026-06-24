import Foundation
import SQLite3

enum AutotuneDBError: Error, Equatable, CustomStringConvertible {
    case openFailed(String)
    case sqlite(message: String)
    case invalidExitReason(String)
    case invalidRetention(Int)

    var description: String {
        switch self {
        case .openFailed(let message):
            return "failed to open autotune DB: \(message)"
        case .sqlite(let message):
            return "sqlite error: \(message)"
        case .invalidExitReason(let value):
            return "invalid autotune exit_reason: \(value)"
        case .invalidRetention(let value):
            return "--retain-runs must be >= 1 (got \(value))"
        }
    }
}

enum AutotuneExitReason: String, CaseIterable {
    case ok
    case interrupted
    case noFeasible = "no_feasible"
    case budgetExhaustedNoModelSelected = "budget_exhausted_no_model_selected"
    case budgetExhaustedWithPartialRecommendation = "budget_exhausted_with_partial_recommendation"
    case preWarmIntegrityFailure = "pre_warm_integrity_failure"
    case providerConflict = "provider_conflict"
    case configError = "config_error"
    case internalError = "internal_error"

    static func validate(_ rawValue: String) throws {
        if Self(rawValue: rawValue) == nil {
            throw AutotuneDBError.invalidExitReason(rawValue)
        }
    }
}

struct AutotuneTrialRow: Equatable {
    var tsUTC: String
    var runID: String
    var stage: Int
    var model: String
    var targetContext: Int
    var measuredPromptTokens: Int?
    var maxTokens: Int
    var aggThroughputTPS: Double?
    var ttftP95MS: Double?
    var fits: Bool
    var nErr: Int
    var kept: Bool
    var notes: String?
    var kvBits: Int?
    var maxContextCap: Int?
    var maxBatch: Int?
    var replicatesN: Int?
}

struct AutotuneRunRow {
    var runID: String
    var startedAtUTC: String
    var endedAtUTC: String?
    var specVersion: String
    var binaryVersion: String
    var machineRAMGB: Int
    var machineChip: String
    var machineOSVersion: String
    var targetContext: Int
    var candidateModelsJSON: String
    var stage1Replicates: Int
    var stage2Replicates: Int
    var gateTTFTMS: Int
    var tpsTieEpsilon: Double
    var recommendationJSON: String?
    var recipeHash: String?
    var applied: Bool
    var exitReason: String
}

final class AutotuneDB {
    private var handle: OpaquePointer?

    init(path: String = AutotuneCommand.defaultDBPath) throws {
        if path != ":memory:" {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let opened = db else {
            let message = db.map(Self.errorMessage) ?? "unknown sqlite open error"
            if let db {
                sqlite3_close(db)
            }
            throw AutotuneDBError.openFailed(message)
        }
        handle = opened

        do {
            try migrate()
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func insertTrial(_ row: AutotuneTrialRow) throws {
        let sql = """
        INSERT INTO tune_trials
            (ts_utc, run_id, stage, model, target_context, measured_prompt_tokens,
             max_tokens, agg_throughput_tps, ttft_p95_ms, fits, n_err, kept, notes,
             kv_bits, max_context_cap, max_batch, replicates_n)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { statement in
            try bind(row.tsUTC, at: 1, in: statement)
            try bind(row.runID, at: 2, in: statement)
            try bind(row.stage, at: 3, in: statement)
            try bind(row.model, at: 4, in: statement)
            try bind(row.targetContext, at: 5, in: statement)
            try bind(row.measuredPromptTokens, at: 6, in: statement)
            try bind(row.maxTokens, at: 7, in: statement)
            try bind(row.aggThroughputTPS, at: 8, in: statement)
            try bind(row.ttftP95MS, at: 9, in: statement)
            try bind(row.fits ? 1 : 0, at: 10, in: statement)
            try bind(row.nErr, at: 11, in: statement)
            try bind(row.kept ? 1 : 0, at: 12, in: statement)
            try bind(row.notes, at: 13, in: statement)
            try bind(row.kvBits, at: 14, in: statement)
            try bind(row.maxContextCap, at: 15, in: statement)
            try bind(row.maxBatch, at: 16, in: statement)
            try bind(row.replicatesN, at: 17, in: statement)
            try stepDone(statement)
        }
    }

    func insertRun(_ row: AutotuneRunRow) throws {
        try AutotuneExitReason.validate(row.exitReason)

        let sql = """
        INSERT INTO tune_runs
            (run_id, started_at_utc, ended_at_utc, spec_version, binary_version,
             machine_ram_gb, machine_chip, machine_os_version, target_context,
             candidate_models_json, stage1_replicates, stage2_replicates,
             gate_ttft_ms, tps_tie_epsilon, recommendation_json, recipe_hash,
             applied, exit_reason)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { statement in
            try bind(row.runID, at: 1, in: statement)
            try bind(row.startedAtUTC, at: 2, in: statement)
            try bind(row.endedAtUTC, at: 3, in: statement)
            try bind(row.specVersion, at: 4, in: statement)
            try bind(row.binaryVersion, at: 5, in: statement)
            try bind(row.machineRAMGB, at: 6, in: statement)
            try bind(row.machineChip, at: 7, in: statement)
            try bind(row.machineOSVersion, at: 8, in: statement)
            try bind(row.targetContext, at: 9, in: statement)
            try bind(row.candidateModelsJSON, at: 10, in: statement)
            try bind(row.stage1Replicates, at: 11, in: statement)
            try bind(row.stage2Replicates, at: 12, in: statement)
            try bind(row.gateTTFTMS, at: 13, in: statement)
            try bind(row.tpsTieEpsilon, at: 14, in: statement)
            try bind(row.recommendationJSON, at: 15, in: statement)
            try bind(row.recipeHash, at: 16, in: statement)
            try bind(row.applied ? 1 : 0, at: 17, in: statement)
            try bind(row.exitReason, at: 18, in: statement)
            try stepDone(statement)
        }
    }

    /// Updates the provisional `tune_runs` row written at run start.
    ///
    /// Step 10 keeps this as a true UPDATE rather than DELETE+INSERT so
    /// `run_id` remains stable and any concurrent/reporting reader never
    /// observes the row disappear between lifecycle states.
    func updateRun(
        runID: String,
        endedAtUTC: String?,
        recommendationJSON: String?,
        recipeHash: String?,
        applied: Bool,
        exitReason: AutotuneExitReason
    ) throws {
        let sql = """
        UPDATE tune_runs
        SET ended_at_utc = ?,
            recommendation_json = ?,
            recipe_hash = ?,
            applied = ?,
            exit_reason = ?
        WHERE run_id = ?
        """
        try withStatement(sql) { statement in
            try bind(endedAtUTC, at: 1, in: statement)
            try bind(recommendationJSON, at: 2, in: statement)
            try bind(recipeHash, at: 3, in: statement)
            try bind(applied ? 1 : 0, at: 4, in: statement)
            try bind(exitReason.rawValue, at: 5, in: statement)
            try bind(runID, at: 6, in: statement)
            try stepDone(statement)
        }
    }

    /// Mark the winning Stage 2 cell for a given run by setting
    /// `kept = 1` on the single row matching the run's stage-2 winner
    /// knobs. All other Stage 2 rows for the same run retain
    /// `kept = 0`. Idempotent.
    ///
    /// Added in Step 8 round-1 audit response (D.1 MAJOR closure):
    /// the prior pattern of computing `kept` per-insert during Stage 2
    /// iteration left multiple rows with `kept = 1` for runs where
    /// later cells outperformed earlier baselines. SPEC-013 §5.7 FR-G.1
    /// requires only the final winning Stage 2 cell to carry
    /// `kept = 1`.
    func markStage2WinnerCell(
        runID: String,
        kvBits: Int?,
        maxBatch: Int,
        maxContextCap: Int
    ) throws {
        let kvBitsClause: String
        if kvBits == nil {
            kvBitsClause = "kv_bits IS NULL"
        } else {
            kvBitsClause = "kv_bits = ?"
        }
        let sql = """
        UPDATE tune_trials SET kept = 1
        WHERE run_id = ? AND stage = 2 AND \(kvBitsClause)
              AND max_batch = ? AND max_context_cap = ?
        """
        try withStatement(sql) { statement in
            var bindIndex: Int32 = 1
            try bind(runID, at: bindIndex, in: statement)
            bindIndex += 1
            if let kvBits {
                try bind(kvBits, at: bindIndex, in: statement)
                bindIndex += 1
            }
            try bind(maxBatch, at: bindIndex, in: statement)
            bindIndex += 1
            try bind(maxContextCap, at: bindIndex, in: statement)
            try stepDone(statement)
        }
    }

    func applyRetentionInTransaction(retainRuns: Int) throws {
        guard retainRuns >= 1 else {
            throw AutotuneDBError.invalidRetention(retainRuns)
        }

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let staleRunsSQL = """
            SELECT run_id FROM tune_runs
            ORDER BY started_at_utc DESC, run_id DESC
            LIMIT -1 OFFSET \(retainRuns)
            """
            try execute("""
            DELETE FROM tune_trials
            WHERE run_id IN (\(staleRunsSQL))
            """)
            try execute("""
            DELETE FROM tune_runs
            WHERE run_id IN (\(staleRunsSQL))
            """)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS tune_trials (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts_utc TEXT NOT NULL,
            run_id TEXT NOT NULL,
            stage INTEGER NOT NULL DEFAULT 1,
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
            kv_bits INTEGER,
            max_context_cap INTEGER,
            max_batch INTEGER,
            replicates_n INTEGER
        )
        """)
        for (column, definition) in Self.additiveTrialColumns {
            try ignoreDuplicateColumn {
                try execute("ALTER TABLE tune_trials ADD COLUMN \(column) \(definition)")
            }
        }
        try execute("CREATE INDEX IF NOT EXISTS idx_tune_trials_run_id ON tune_trials(run_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_tune_trials_ts ON tune_trials(ts_utc)")

        try execute("""
        CREATE TABLE IF NOT EXISTS tune_runs (
            run_id TEXT PRIMARY KEY,
            started_at_utc TEXT NOT NULL,
            ended_at_utc TEXT,
            spec_version TEXT NOT NULL,
            binary_version TEXT NOT NULL,
            machine_ram_gb INTEGER NOT NULL,
            machine_chip TEXT NOT NULL,
            machine_os_version TEXT NOT NULL,
            target_context INTEGER NOT NULL,
            candidate_models_json TEXT NOT NULL,
            stage1_replicates INTEGER NOT NULL,
            stage2_replicates INTEGER NOT NULL,
            gate_ttft_ms INTEGER NOT NULL,
            tps_tie_epsilon REAL NOT NULL,
            recommendation_json TEXT,
            recipe_hash TEXT,
            applied INTEGER NOT NULL DEFAULT 0,
            exit_reason TEXT NOT NULL
        )
        """)
    }

    private func execute(_ sql: String) throws {
        try withStatement(sql) { statement in
            try stepDone(statement)
        }
    }

    private func ignoreDuplicateColumn(_ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch AutotuneDBError.sqlite(let message) where message.localizedCaseInsensitiveContains("duplicate column") {
            return
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let handle else {
            throw AutotuneDBError.sqlite(message: "database is closed")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw currentError()
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw currentError()
        }
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw currentError()
            }
            return
        }
        guard sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw currentError()
        }
    }

    private func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw currentError()
            }
            return
        }
        guard sqlite3_bind_int64(statement, index, sqlite3_int64(value)) == SQLITE_OK else {
            throw currentError()
        }
    }

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw currentError()
            }
            return
        }
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw currentError()
        }
    }

    private func currentError() -> AutotuneDBError {
        guard let handle else {
            return .sqlite(message: "database is closed")
        }
        return .sqlite(message: Self.errorMessage(handle))
    }

    private func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    private static func errorMessage(_ handle: OpaquePointer) -> String {
        guard let cString = sqlite3_errmsg(handle) else {
            return "unknown sqlite error"
        }
        return String(cString: cString)
    }

    private static let additiveTrialColumns: [(String, String)] = [
        ("stage", "INTEGER NOT NULL DEFAULT 1"),
        ("kv_bits", "INTEGER"),
        ("max_context_cap", "INTEGER"),
        ("max_batch", "INTEGER"),
        ("replicates_n", "INTEGER"),
    ]
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
