package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// SPEC-047-R012 pool-proven rollup.
//
// The aggregate used to recount raw attempts by driving the SPEC-022 payable
// view over every enforce-mode ledger credit, which does not finish within
// the build deadline on a production-size ledger, and would silently shrink
// once SPEC-022 R-15 retention archives settled evidence out of the hot
// database. Instead the coordinator keeps one rollup row per pool-manifest
// attempt, and the aggregate reads only that table:
//
//   - Capture: settlement_route_snapshots is append-only (trg_srs_immutable)
//     with AUTOINCREMENT ids allocated under SQLite's single writer, so ids
//     commit in order. A high-water mark over its rowid captures each new
//     enforce-mode pool_manifest snapshot exactly once, with the immutable
//     provenance the aggregate needs (pool, entry, core, pair, owner inputs,
//     settlement policy).
//   - Evaluate: each pass recomputes, for every captured attempt whose
//     finality is unknown or not before the window start, the verdict half
//     of the counting predicate (enforce snapshot, closed payable verdict
//     against it, verified pool label) and its finality time while the
//     snapshot and verdict rows are hot, and the credit half (a payable
//     enforce credit with positive debit and credit) always: ledger credits
//     never leave the hot database. All joins are key lookups. A verdict that
//     closed before the window start can never count in a later window, so
//     its row is no longer re-read.
//   - Freeze: deleting a pool snapshot or a pool-labelled verdict (retention)
//     fires a BEFORE DELETE trigger that captures the attempt if it was not
//     captured yet and records its verdict half and finality from the rows
//     being deleted, in the deleting transaction. So the frozen state is the
//     state at deletion, never an older sample.
//
// Rows are never deleted: re-running the capture from id 0 (cursor reset)
// rebuilds every hot attempt and keeps every frozen one.

const (
	// poolProvenCaptureBatch bounds the snapshot ids one capture read covers.
	poolProvenCaptureBatch = 20_000
	// poolProvenEvaluateBatch bounds the rollup rows one evaluation read covers.
	poolProvenEvaluateBatch = 2_000
	// poolProvenWriteBatch bounds the rows one write transaction touches, so
	// the shared writer connection is held for milliseconds.
	poolProvenWriteBatch = 200
	// poolProvenQueryTimeout is the R009 per-query limit, applied to every
	// refresh read.
	poolProvenQueryTimeout = 10 * time.Second
	// poolProvenWriteTimeout bounds one write transaction, including the wait
	// for the shared writer connection.
	poolProvenWriteTimeout = 2 * time.Second
)

// poolProvenCaptureColumns are the rollup columns a capture fills, in the
// order poolProvenCaptureValuesSQL produces them.
const poolProvenCaptureColumns = `route_snapshot_id, account_scope_hash, request_id, attempt_n, provider_id,
    pool_id, pool_model_id, manifest_version, manifest_core_digest,
    artifact_hash_algorithm, artifact_hash, runtime_source,
    pool_member_account_id, pool_operator_account_id, settlement_policy_version`

// poolProvenCaptureValuesSQL renders the captured values of snapshot row s;
// accountScope is the expression for the second column (SQL cannot compute
// the scope hash, so the Go capture reads the raw scope and hashes it).
func poolProvenCaptureValuesSQL(s, accountScope string) string {
	mv := `json_extract(` + s + `.route_snapshot_json, '$.manifest_version')`
	return s + `.id, ` + accountScope + `, ` + s + `.request_id, ` + s + `.attempt_n, ` + s + `.provider_id,
       ` + s + `.pool_id,
       COALESCE(json_extract(` + s + `.route_snapshot_json, '$.pool_model_id'), ''),
       CASE WHEN typeof(` + mv + `) = 'integer' AND ` + mv + ` > 0 THEN ` + mv + ` ELSE 0 END,
       COALESCE(json_extract(` + s + `.route_snapshot_json, '$.manifest_core_digest'), ''),
       COALESCE(json_extract(` + s + `.route_snapshot_json, '$.expected_catalog_model_hash_algorithm'), ''),
       ` + s + `.expected_catalog_model_hash,
       COALESCE(json_extract(` + s + `.route_snapshot_json, '$.runtime_source'), ''),
       COALESCE(json_extract(` + s + `.route_snapshot_json, '$.pool_member_account_id'), ''),
       COALESCE(json_extract(` + s + `.route_snapshot_json, '$.pool_operator_account_id'), ''),
       ` + s + `.route_snapshot_policy_version`
}

// poolProvenSnapshotSQL selects the snapshots the rollup captures.
func poolProvenSnapshotSQL(s string) string {
	return s + `.pool_id IS NOT NULL AND ` + s + `.pool_id <> ''
   AND ` + s + `.route_snapshot_mode = '` + RouteSnapshotModeEnforce + `'
   AND json_extract(` + s + `.route_snapshot_json, '$.expected_model_hash_source') = '` + ExpectedModelHashSourcePoolManifest + `'`
}

// poolProvenVerdictSQL is the verdict half of the SPEC-047-R012 v0.2.9
// counting predicate for verdict v against snapshot s.
func poolProvenVerdictSQL(v, s string) string {
	// COALESCE: a NULL label (or no verdict row) is "not verified", never NULL.
	return `COALESCE((` + s + `.route_snapshot_mode = '` + RouteSnapshotModeEnforce + `'
             AND ` + v + `.route_snapshot_digest = ` + s + `.route_snapshot_digest
             AND ` + v + `.closed = 1
             AND ` + payableSettlementOutcomeSQL(v, s) + `
             AND ` + v + `.pool_label_status = '` + PoolLabelStatusVerified + `'), 0)`
}

// poolProvenFinalitySQL is the coordinator-assigned finality time: when the
// verdict closed.
func poolProvenFinalitySQL(v string) string {
	return `CASE WHEN ` + v + `.closed = 1 THEN COALESCE(` + v + `.updated_at_utc, ` + v + `.created_at_utc) END`
}

// poolProvenSnapshotDeleteCaptureSQL captures the attempt of snapshot row
// old (being deleted). The verdict is found through the attempt's ledger
// credit, whose settlement scope hash is the verdict's: every lookup is a
// unique-key search, so the trigger never walks a provider's history.
func poolProvenSnapshotDeleteCaptureSQL(old string) string {
	return `SELECT ` + poolProvenCaptureValuesSQL(old, "srv.account_scope_hash") + `
      FROM ledger_request_credits lrc
      JOIN settlement_receipt_verdicts srv
        ON srv.account_scope_hash = lrc.settlement_account_scope_hash
       AND srv.request_id = lrc.request_id
       AND srv.attempt_n = lrc.attempt_n
       AND srv.provider_id = lrc.provider_id
     WHERE lrc.request_id = ` + old + `.request_id
       AND lrc.attempt_n = ` + old + `.attempt_n
       AND lrc.provider_id = ` + old + `.provider_id
       AND srv.route_snapshot_digest = ` + old + `.route_snapshot_digest
       AND ` + poolProvenSnapshotSQL(old)
}

// poolProvenVerdictDeleteCaptureSQL captures the attempt of verdict row old
// (being deleted), finding its snapshot by the SPEC-022 payable index.
func poolProvenVerdictDeleteCaptureSQL(old string) string {
	return `SELECT ` + poolProvenCaptureValuesSQL("srs", old+".account_scope_hash") + `
      FROM settlement_route_snapshots srs
     WHERE srs.request_id = ` + old + `.request_id
       AND srs.attempt_n = ` + old + `.attempt_n
       AND srs.provider_id = ` + old + `.provider_id
       AND srs.route_snapshot_mode = '` + RouteSnapshotModeEnforce + `'
       AND srs.route_snapshot_digest = ` + old + `.route_snapshot_digest
       AND ` + poolProvenSnapshotSQL("srs")
}

// poolProvenTriggers freeze an attempt's verdict half at deletion. Each
// updates only while both of the attempt's rows still exist (the row being
// deleted is still visible in a BEFORE trigger), so whichever row retention
// deletes first records the state; the second leaves it unchanged.
func poolProvenTriggers() []string {
	srvForOld := `srv.account_scope_hash = pool_proven_rollup_attempts.account_scope_hash
                            AND srv.request_id = OLD.request_id
                            AND srv.attempt_n = OLD.attempt_n
                            AND srv.provider_id = OLD.provider_id`
	return []string{`
CREATE TRIGGER trg_ppr_srs_delete BEFORE DELETE ON settlement_route_snapshots
WHEN OLD.pool_id IS NOT NULL AND OLD.pool_id <> ''
BEGIN
    INSERT OR IGNORE INTO pool_proven_rollup_attempts (` + poolProvenCaptureColumns + `)
    ` + poolProvenSnapshotDeleteCaptureSQL("OLD") + `;
    UPDATE pool_proven_rollup_attempts
       SET verdict_ok = (SELECT ` + poolProvenVerdictSQL("srv", "OLD") + `
                           FROM settlement_receipt_verdicts srv
                          WHERE ` + srvForOld + `),
           finality_at_utc = (SELECT ` + poolProvenFinalitySQL("srv") + `
                                FROM settlement_receipt_verdicts srv
                               WHERE ` + srvForOld + `)
     WHERE route_snapshot_id = OLD.id
       AND EXISTS (SELECT 1 FROM settlement_receipt_verdicts srv WHERE ` + srvForOld + `);
END`, `
CREATE TRIGGER trg_ppr_srv_delete BEFORE DELETE ON settlement_receipt_verdicts
WHEN OLD.pool_id IS NOT NULL AND OLD.pool_id <> ''
BEGIN
    INSERT OR IGNORE INTO pool_proven_rollup_attempts (` + poolProvenCaptureColumns + `)
    ` + poolProvenVerdictDeleteCaptureSQL("OLD") + `;
    UPDATE pool_proven_rollup_attempts
       SET verdict_ok = (SELECT ` + poolProvenVerdictSQL("OLD", "srs") + `
                           FROM settlement_route_snapshots srs
                          WHERE srs.id = pool_proven_rollup_attempts.route_snapshot_id),
           finality_at_utc = ` + poolProvenFinalitySQL("OLD") + `
     WHERE account_scope_hash = OLD.account_scope_hash
       AND request_id = OLD.request_id
       AND attempt_n = OLD.attempt_n
       AND provider_id = OLD.provider_id
       AND EXISTS (SELECT 1 FROM settlement_route_snapshots srs
                    WHERE srs.id = pool_proven_rollup_attempts.route_snapshot_id);
END`}
}

// EnsurePoolProvenRollup creates the rollup tables and (re)creates its
// freeze triggers. The billing migration runs it after every table rebuild,
// so a rebuild that dropped a trigger gets it back. No index is built on any
// evidence table.
func EnsurePoolProvenRollup(ctx context.Context, db *sql.DB) error {
	if db == nil {
		return errors.New("billing: ledger handle unavailable")
	}
	stmts := append([]string{`
CREATE TABLE IF NOT EXISTS pool_proven_rollup_attempts (
    route_snapshot_id INTEGER PRIMARY KEY,
    account_scope_hash TEXT NOT NULL,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    pool_id TEXT NOT NULL,
    pool_model_id TEXT NOT NULL,
    manifest_version INTEGER NOT NULL,
    manifest_core_digest TEXT NOT NULL,
    artifact_hash_algorithm TEXT NOT NULL,
    artifact_hash TEXT NOT NULL,
    runtime_source TEXT NOT NULL,
    pool_member_account_id TEXT NOT NULL,
    pool_operator_account_id TEXT NOT NULL,
    settlement_policy_version TEXT NOT NULL,
    verdict_ok INTEGER NOT NULL DEFAULT 0 CHECK(verdict_ok IN (0,1)),
    counted INTEGER NOT NULL DEFAULT 0 CHECK(counted IN (0,1)),
    finality_at_utc TEXT NULL
)`, `
CREATE UNIQUE INDEX IF NOT EXISTS idx_ppr_attempt
    ON pool_proven_rollup_attempts(account_scope_hash, request_id, attempt_n, provider_id)`, `
CREATE TABLE IF NOT EXISTS pool_proven_rollup_cursor (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    last_route_snapshot_id INTEGER NOT NULL
)`,
		`INSERT OR IGNORE INTO pool_proven_rollup_cursor(id, last_route_snapshot_id) VALUES (1, 0)`,
		`DROP TRIGGER IF EXISTS trg_ppr_srs_delete`,
		`DROP TRIGGER IF EXISTS trg_ppr_srv_delete`,
	}, poolProvenTriggers()...)
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	for _, stmt := range stmts {
		if _, err := tx.ExecContext(ctx, stmt); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("pool-proven rollup schema: %w", err)
		}
	}
	return tx.Commit()
}

// RefreshPoolProvenRollup brings the rollup current: it captures every
// pool-manifest route snapshot past the high-water mark, then re-evaluates
// each captured attempt whose finality is unknown or not before windowStart.
// Reads go through reader, each under the R009 query timeout, so they never
// hold the writer connection; writes are short transactions on writer.
// Progress commits as it goes; an error leaves the rollup consistent but not
// current.
func RefreshPoolProvenRollup(ctx context.Context, reader, writer *sql.DB, windowStart time.Time) error {
	if reader == nil || writer == nil {
		return errors.New("billing: ledger handle unavailable")
	}
	if err := capturePoolProvenAttempts(ctx, reader, writer); err != nil {
		return fmt.Errorf("capture: %w", err)
	}
	if err := evaluatePoolProvenAttempts(ctx, reader, writer, windowStart); err != nil {
		return fmt.Errorf("evaluate: %w", err)
	}
	return nil
}

type poolProvenCapturedRow struct {
	id                                 int64
	accountScope, requestID            string
	attemptN                           int64
	providerID, poolID, poolModelID    string
	manifestVersion                    int64
	coreDigest, algorithm, hash        string
	runtime                            string
	memberAccountID, operatorAccountID string
	policyVersion                      string
}

func capturePoolProvenAttempts(ctx context.Context, reader, writer *sql.DB) error {
	var cursor, maxID int64
	err := withPoolProvenRead(ctx, func(ctx context.Context) error {
		if err := reader.QueryRowContext(ctx, `SELECT last_route_snapshot_id FROM pool_proven_rollup_cursor WHERE id = 1`).Scan(&cursor); err != nil {
			return fmt.Errorf("cursor: %w", err)
		}
		return reader.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM settlement_route_snapshots`).Scan(&maxID)
	})
	if err != nil {
		return err
	}
	for cursor < maxID {
		upper := min(cursor+poolProvenCaptureBatch, maxID)
		var rows []poolProvenCapturedRow
		if err := withPoolProvenRead(ctx, func(ctx context.Context) error {
			var err error
			rows, err = readPoolProvenSnapshots(ctx, reader, cursor, upper)
			return err
		}); err != nil {
			return err
		}
		for len(rows) > poolProvenWriteBatch {
			if err := insertPoolProvenRows(ctx, writer, rows[:poolProvenWriteBatch], 0); err != nil {
				return err
			}
			rows = rows[poolProvenWriteBatch:]
		}
		// The cursor moves with the range's last rows, only after every
		// earlier row of the range committed, and only forward.
		if err := insertPoolProvenRows(ctx, writer, rows, upper); err != nil {
			return err
		}
		cursor = upper
	}
	return nil
}

func insertPoolProvenRows(ctx context.Context, writer *sql.DB, rows []poolProvenCapturedRow, cursor int64) error {
	return withPoolProvenTx(ctx, writer, func(ctx context.Context, tx *sql.Tx) error {
		for _, r := range rows {
			if _, err := tx.ExecContext(ctx, `
INSERT OR IGNORE INTO pool_proven_rollup_attempts (`+poolProvenCaptureColumns+`)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				r.id, SettlementAccountScopeHash(r.accountScope), r.requestID, r.attemptN, r.providerID,
				r.poolID, r.poolModelID, r.manifestVersion, r.coreDigest,
				r.algorithm, r.hash, r.runtime,
				r.memberAccountID, r.operatorAccountID, r.policyVersion); err != nil {
				return err
			}
		}
		if cursor == 0 {
			return nil
		}
		_, err := tx.ExecContext(ctx, `
UPDATE pool_proven_rollup_cursor SET last_route_snapshot_id = ?
 WHERE id = 1 AND last_route_snapshot_id < ?`, cursor, cursor)
		return err
	})
}

func poolProvenCaptureSQL() string {
	return `
SELECT ` + poolProvenCaptureValuesSQL("srs", "srs.account_scope") + `
  FROM settlement_route_snapshots srs
 WHERE srs.id > ? AND srs.id <= ?
   AND ` + poolProvenSnapshotSQL("srs") + `
 ORDER BY srs.id`
}

// readPoolProvenSnapshots reads the captured snapshots with id in
// (after, upto] by a rowid range search.
func readPoolProvenSnapshots(ctx context.Context, reader *sql.DB, after, upto int64) ([]poolProvenCapturedRow, error) {
	rows, err := reader.QueryContext(ctx, poolProvenCaptureSQL(), after, upto)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []poolProvenCapturedRow
	for rows.Next() {
		var r poolProvenCapturedRow
		if err := rows.Scan(&r.id, &r.accountScope, &r.requestID, &r.attemptN, &r.providerID, &r.poolID,
			&r.poolModelID, &r.manifestVersion, &r.coreDigest, &r.algorithm, &r.hash, &r.runtime,
			&r.memberAccountID, &r.operatorAccountID, &r.policyVersion); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

type poolProvenEvaluation struct {
	id                           int64
	storedVerdict, storedCounted bool
	storedFinality               sql.NullString
	hot, verdict, creditPayable  bool
	finality                     sql.NullString
}

// poolProvenChange is one evaluation result. A hot result rewrites the
// verdict half only if both evidence rows still exist when the write commits:
// a delete trigger that froze the verdict in between always wins. Otherwise
// only counted is rewritten, from the verdict stored at write time.
type poolProvenChange struct {
	id                     int64
	hot                    bool
	verdict, creditPayable bool
	finality               sql.NullString
}

// poolProvenAfterEvaluateReadHook runs between an evaluation read and its
// writes (tests only).
var poolProvenAfterEvaluateReadHook func()

func evaluatePoolProvenAttempts(ctx context.Context, reader, writer *sql.DB, windowStart time.Time) error {
	since := windowStart.UTC().Format(time.RFC3339Nano)
	var after int64
	for {
		var batch []poolProvenEvaluation
		if err := withPoolProvenRead(ctx, func(ctx context.Context) error {
			var err error
			batch, err = readPoolProvenEvaluations(ctx, reader, after, since)
			return err
		}); err != nil {
			return err
		}
		if len(batch) == 0 {
			return nil
		}
		after = batch[len(batch)-1].id
		if hook := poolProvenAfterEvaluateReadHook; hook != nil {
			hook()
		}
		var changes []poolProvenChange
		for _, e := range batch {
			// Without both hot rows the verdict half stays as frozen at
			// deletion; the credit half is always current.
			verdict, finality := e.storedVerdict, e.storedFinality
			if e.hot {
				verdict, finality = e.verdict, e.finality
			}
			counted := verdict && e.creditPayable
			if verdict != e.storedVerdict || counted != e.storedCounted || finality != e.storedFinality {
				changes = append(changes, poolProvenChange{e.id, e.hot, e.verdict, e.creditPayable, e.finality})
			}
		}
		for len(changes) > 0 {
			n := min(len(changes), poolProvenWriteBatch)
			if err := updatePoolProvenRows(ctx, writer, changes[:n]); err != nil {
				return err
			}
			changes = changes[n:]
		}
		if len(batch) < poolProvenEvaluateBatch {
			return nil
		}
	}
}

func updatePoolProvenRows(ctx context.Context, writer *sql.DB, changes []poolProvenChange) error {
	return withPoolProvenTx(ctx, writer, func(ctx context.Context, tx *sql.Tx) error {
		for _, c := range changes {
			if c.hot {
				res, err := tx.ExecContext(ctx, `
UPDATE pool_proven_rollup_attempts
   SET verdict_ok = ?, counted = ?, finality_at_utc = ?
 WHERE route_snapshot_id = ?
   AND EXISTS (SELECT 1 FROM settlement_route_snapshots srs WHERE srs.id = pool_proven_rollup_attempts.route_snapshot_id)
   AND EXISTS (SELECT 1 FROM settlement_receipt_verdicts srv
                WHERE srv.account_scope_hash = pool_proven_rollup_attempts.account_scope_hash
                  AND srv.request_id = pool_proven_rollup_attempts.request_id
                  AND srv.attempt_n = pool_proven_rollup_attempts.attempt_n
                  AND srv.provider_id = pool_proven_rollup_attempts.provider_id)`,
					c.verdict, c.verdict && c.creditPayable, c.finality, c.id)
				if err != nil {
					return err
				}
				if n, err := res.RowsAffected(); err != nil || n == 1 {
					if err != nil {
						return err
					}
					continue
				}
			}
			if _, err := tx.ExecContext(ctx, `
UPDATE pool_proven_rollup_attempts SET counted = CASE WHEN verdict_ok = 1 AND ? THEN 1 ELSE 0 END
 WHERE route_snapshot_id = ?`, c.creditPayable, c.id); err != nil {
				return err
			}
		}
		return nil
	})
}

// poolProvenEvaluateSQL reads, per captured attempt, its stored state, the
// verdict half and finality from the hot rows (when both exist), and the
// credit half: an enforce-mode payable credit under the snapshot's policy
// with positive buyer debit and provider credit. Every join is a primary-key
// or unique-key lookup.
func poolProvenEvaluateSQL() string {
	return `
SELECT a.route_snapshot_id,
       a.verdict_ok,
       a.counted,
       a.finality_at_utc,
       srs.id IS NOT NULL AND srv.id IS NOT NULL,
       ` + poolProvenVerdictSQL("srv", "srs") + `,
       ` + poolProvenFinalitySQL("srv") + `,
       EXISTS (
           SELECT 1
             FROM spec022_payable_request_credits p
            WHERE p.request_id = a.request_id
              AND p.attempt_n = a.attempt_n
              AND p.provider_id = a.provider_id
              AND p.settlement_policy_mode = '` + RouteSnapshotModeEnforce + `'
              AND p.settlement_account_scope_hash = a.account_scope_hash
              AND p.settlement_policy_version = a.settlement_policy_version
              AND p.gross_credits > 0
              AND p.provider_credits > 0)
  FROM pool_proven_rollup_attempts a
  LEFT JOIN settlement_route_snapshots srs ON srs.id = a.route_snapshot_id
  LEFT JOIN settlement_receipt_verdicts srv
    ON srv.account_scope_hash = a.account_scope_hash
   AND srv.request_id = a.request_id
   AND srv.attempt_n = a.attempt_n
   AND srv.provider_id = a.provider_id
 WHERE a.route_snapshot_id > ?
   AND (a.finality_at_utc IS NULL OR julianday(a.finality_at_utc) >= julianday(?))
 ORDER BY a.route_snapshot_id
 LIMIT ?`
}

func readPoolProvenEvaluations(ctx context.Context, reader *sql.DB, after int64, since string) ([]poolProvenEvaluation, error) {
	rows, err := reader.QueryContext(ctx, poolProvenEvaluateSQL(), after, since, poolProvenEvaluateBatch)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []poolProvenEvaluation
	for rows.Next() {
		var e poolProvenEvaluation
		if err := rows.Scan(&e.id, &e.storedVerdict, &e.storedCounted, &e.storedFinality,
			&e.hot, &e.verdict, &e.finality, &e.creditPayable); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func withPoolProvenRead(ctx context.Context, fn func(context.Context) error) error {
	ctx, cancel := context.WithTimeout(ctx, poolProvenQueryTimeout)
	defer cancel()
	return fn(ctx)
}

func withPoolProvenTx(ctx context.Context, db *sql.DB, fn func(context.Context, *sql.Tx) error) error {
	ctx, cancel := context.WithTimeout(ctx, poolProvenWriteTimeout)
	defer cancel()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(ctx, tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

// PoolProvenAttempt is one SPEC-047-R012 counted attempt: a settled paid
// attempt whose immutable route snapshot took its expected identity from a
// pool manifest entry. It carries the snapshot's pool provenance so the
// aggregate can resolve the owner account and the entry's licence; it never
// leaves the coordinator.
type PoolProvenAttempt struct {
	ProviderID            string
	PoolID                string
	PoolModelID           string
	ManifestVersion       uint64
	ManifestCoreDigest    string
	ArtifactHashAlgorithm string
	ArtifactHash          string
	RuntimeSource         string
	PoolMemberAccountID   string
	PoolOperatorAccountID string
}

// QueryPoolProvenAttempts lists, from the rollup, the SPEC-047-R012 counted
// attempts whose coordinator-assigned finality time (the closing time of the
// settlement receipt verdict) lies in [since, until]. The rollup must have
// been refreshed for a window starting at or before since. It returns at most
// limit rows; the caller treats limit rows as the ceiling being reached.
func QueryPoolProvenAttempts(ctx context.Context, q interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}, since, until time.Time, limit int) ([]PoolProvenAttempt, error) {
	if q == nil {
		return nil, errors.New("billing: ledger handle unavailable")
	}
	if limit <= 0 || !until.After(since) {
		return nil, errors.New("billing: invalid pool-proven window")
	}
	rows, err := q.QueryContext(ctx, `
SELECT provider_id, pool_id, pool_model_id, manifest_version, manifest_core_digest,
       artifact_hash_algorithm, artifact_hash, runtime_source,
       pool_member_account_id, pool_operator_account_id
  FROM pool_proven_rollup_attempts
 WHERE counted = 1
   AND pool_id <> ''
   AND julianday(finality_at_utc) BETWEEN julianday(?) AND julianday(?)
 ORDER BY route_snapshot_id
 LIMIT ?`,
		since.UTC().Format(time.RFC3339Nano), until.UTC().Format(time.RFC3339Nano), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PoolProvenAttempt
	for rows.Next() {
		var a PoolProvenAttempt
		var version int64
		if err := rows.Scan(&a.ProviderID, &a.PoolID, &a.PoolModelID, &version, &a.ManifestCoreDigest,
			&a.ArtifactHashAlgorithm, &a.ArtifactHash, &a.RuntimeSource, &a.PoolMemberAccountID, &a.PoolOperatorAccountID); err != nil {
			return nil, err
		}
		if version > 0 {
			a.ManifestVersion = uint64(version)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}
