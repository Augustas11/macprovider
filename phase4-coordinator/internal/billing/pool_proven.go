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
// attempt:
//
//   - Capture: settlement_route_snapshots is append-only (trg_srs_immutable)
//     with AUTOINCREMENT ids allocated under SQLite's single writer, so ids
//     commit in order. A high-water mark over its rowid captures each new
//     enforce-mode pool_manifest snapshot exactly once, with the immutable
//     provenance the aggregate needs (pool, entry, core, pair, owner inputs).
//   - Evaluate: each pass recomputes the counting predicate for every
//     captured attempt whose finality is unknown or not before the window
//     start, by primary/unique-key lookups only, and stores whether it counts
//     and its finality time. A verdict that closed before the window start
//     can never count in a later window, so its row is no longer re-read.
//   - Persist: when an attempt's snapshot or verdict row is no longer in the
//     hot database, its stored state is kept, so archived attempts keep
//     counting for the rest of their window.
//
// The aggregate reads only this table. Bumping poolProvenRollupVersion clears
// it and rebuilds it from the hot evidence.
const poolProvenRollupVersion = 1

const (
	// poolProvenCaptureBatch bounds the snapshot ids one capture read covers.
	poolProvenCaptureBatch = 20_000
	// poolProvenEvaluateBatch bounds the rollup rows one evaluation read and
	// its write transaction cover.
	poolProvenEvaluateBatch = 2_000
)

// EnsurePoolProvenRollup creates the rollup tables, and clears the rollup
// when it was written under a different rollup version.
func EnsurePoolProvenRollup(ctx context.Context, db *sql.DB) error {
	if db == nil {
		return errors.New("billing: ledger handle unavailable")
	}
	if _, err := db.ExecContext(ctx, `
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
    counted INTEGER NOT NULL DEFAULT 0 CHECK(counted IN (0,1)),
    finality_at_utc TEXT NULL
);
CREATE TABLE IF NOT EXISTS pool_proven_rollup_cursor (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    rollup_version INTEGER NOT NULL,
    last_route_snapshot_id INTEGER NOT NULL
);`); err != nil {
		return err
	}
	return withPoolProvenTx(ctx, db, func(tx *sql.Tx) error {
		var version int64
		err := tx.QueryRowContext(ctx, `SELECT rollup_version FROM pool_proven_rollup_cursor WHERE id = 1`).Scan(&version)
		if err == nil && version == poolProvenRollupVersion {
			return nil
		}
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM pool_proven_rollup_attempts`); err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `
INSERT INTO pool_proven_rollup_cursor(id, rollup_version, last_route_snapshot_id) VALUES (1, ?, 0)
ON CONFLICT(id) DO UPDATE SET rollup_version = excluded.rollup_version, last_route_snapshot_id = 0`, poolProvenRollupVersion)
		return err
	})
}

// RefreshPoolProvenRollup brings the rollup current: it captures every
// pool-manifest route snapshot past the high-water mark, then re-evaluates the
// counting predicate of each captured attempt whose finality is unknown or not
// before windowStart. Reads go through reader, so they never hold the
// writer connection; each write is one short transaction on writer. Progress
// commits as it goes; an error leaves the rollup consistent but not current.
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
	id                                   int64
	accountScope, requestID              string
	attemptN                             int64
	providerID, poolID, poolModelID      string
	manifestVersion                      sql.NullInt64
	coreDigest, algorithm, hash, runtime string
	memberAccountID, operatorAccountID   string
}

func capturePoolProvenAttempts(ctx context.Context, reader, writer *sql.DB) error {
	var cursor, maxID int64
	if err := reader.QueryRowContext(ctx, `SELECT last_route_snapshot_id FROM pool_proven_rollup_cursor WHERE id = 1`).Scan(&cursor); err != nil {
		return fmt.Errorf("cursor: %w", err)
	}
	if err := reader.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM settlement_route_snapshots`).Scan(&maxID); err != nil {
		return err
	}
	for cursor < maxID {
		upper := min(cursor+poolProvenCaptureBatch, maxID)
		rows, err := readPoolProvenSnapshots(ctx, reader, cursor, upper)
		if err != nil {
			return err
		}
		if err := withPoolProvenTx(ctx, writer, func(tx *sql.Tx) error {
			for _, r := range rows {
				var version int64
				if r.manifestVersion.Valid && r.manifestVersion.Int64 > 0 {
					version = r.manifestVersion.Int64
				}
				if _, err := tx.ExecContext(ctx, `
INSERT OR IGNORE INTO pool_proven_rollup_attempts (
    route_snapshot_id, account_scope_hash, request_id, attempt_n, provider_id,
    pool_id, pool_model_id, manifest_version, manifest_core_digest,
    artifact_hash_algorithm, artifact_hash, runtime_source,
    pool_member_account_id, pool_operator_account_id
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
					r.id, SettlementAccountScopeHash(r.accountScope), r.requestID, r.attemptN, r.providerID,
					r.poolID, r.poolModelID, version, r.coreDigest,
					r.algorithm, r.hash, r.runtime,
					r.memberAccountID, r.operatorAccountID); err != nil {
					return err
				}
			}
			// The cursor only moves forward, so a concurrent pass cannot
			// rewind it.
			_, err := tx.ExecContext(ctx, `
UPDATE pool_proven_rollup_cursor SET last_route_snapshot_id = ?
 WHERE id = 1 AND last_route_snapshot_id < ?`, upper, upper)
			return err
		}); err != nil {
			return err
		}
		cursor = upper
	}
	return nil
}

// readPoolProvenSnapshots reads the enforce-mode pool_manifest snapshots with
// id in (after, upto] by a rowid range search.
func readPoolProvenSnapshots(ctx context.Context, reader *sql.DB, after, upto int64) ([]poolProvenCapturedRow, error) {
	rows, err := reader.QueryContext(ctx, `
SELECT id, account_scope, request_id, attempt_n, provider_id, pool_id,
       COALESCE(json_extract(route_snapshot_json, '$.pool_model_id'), ''),
       json_extract(route_snapshot_json, '$.manifest_version'),
       COALESCE(json_extract(route_snapshot_json, '$.manifest_core_digest'), ''),
       COALESCE(json_extract(route_snapshot_json, '$.expected_catalog_model_hash_algorithm'), ''),
       expected_catalog_model_hash,
       COALESCE(json_extract(route_snapshot_json, '$.runtime_source'), ''),
       COALESCE(json_extract(route_snapshot_json, '$.pool_member_account_id'), ''),
       COALESCE(json_extract(route_snapshot_json, '$.pool_operator_account_id'), '')
  FROM settlement_route_snapshots
 WHERE id > ? AND id <= ?
   AND pool_id IS NOT NULL AND pool_id <> ''
   AND route_snapshot_mode = 'enforce'
   AND json_extract(route_snapshot_json, '$.expected_model_hash_source') = ?
 ORDER BY id`, after, upto, ExpectedModelHashSourcePoolManifest)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []poolProvenCapturedRow
	for rows.Next() {
		var r poolProvenCapturedRow
		if err := rows.Scan(&r.id, &r.accountScope, &r.requestID, &r.attemptN, &r.providerID, &r.poolID,
			&r.poolModelID, &r.manifestVersion, &r.coreDigest, &r.algorithm, &r.hash, &r.runtime,
			&r.memberAccountID, &r.operatorAccountID); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

type poolProvenEvaluation struct {
	id              int64
	counted         bool
	finality        sql.NullString
	storedCounted   bool
	storedFinality  sql.NullString
	evidencePresent bool
}

func evaluatePoolProvenAttempts(ctx context.Context, reader, writer *sql.DB, windowStart time.Time) error {
	query := poolProvenEvaluateSQL()
	since := windowStart.UTC().Format(time.RFC3339Nano)
	var after int64
	for {
		batch, err := readPoolProvenEvaluations(ctx, reader, query, after, since)
		if err != nil {
			return err
		}
		if len(batch) == 0 {
			return nil
		}
		after = batch[len(batch)-1].id
		if err := withPoolProvenTx(ctx, writer, func(tx *sql.Tx) error {
			for _, e := range batch {
				// Archived evidence keeps the state last computed from it.
				if !e.evidencePresent || (e.counted == e.storedCounted && e.finality == e.storedFinality) {
					continue
				}
				if _, err := tx.ExecContext(ctx, `
UPDATE pool_proven_rollup_attempts SET counted = ?, finality_at_utc = ? WHERE route_snapshot_id = ?`,
					e.counted, e.finality, e.id); err != nil {
					return err
				}
			}
			return nil
		}); err != nil {
			return err
		}
		if len(batch) < poolProvenEvaluateBatch {
			return nil
		}
	}
}

// poolProvenEvaluateSQL is the SPEC-047-R012 v0.2.9 counting predicate per
// captured attempt: an enforce-mode snapshot whose verdict closed payable
// with a verified pool label against that snapshot, and an enforce-mode
// payable credit under the snapshot's policy with positive buyer debit and
// provider credit. Every join is a primary-key or unique-key lookup.
func poolProvenEvaluateSQL() string {
	return `
SELECT a.route_snapshot_id,
       a.counted,
       a.finality_at_utc,
       srs.id IS NOT NULL AND srv.id IS NOT NULL,
       CASE WHEN srv.closed = 1 THEN COALESCE(srv.updated_at_utc, srv.created_at_utc) END,
       CASE WHEN srs.id IS NOT NULL AND srv.id IS NOT NULL
             AND srs.route_snapshot_mode = 'enforce'
             AND srv.route_snapshot_digest = srs.route_snapshot_digest
             AND srv.closed = 1
             AND ` + payableSettlementOutcomeSQL("srv", "srs") + `
             AND srv.pool_label_status = ?
             AND EXISTS (
                 SELECT 1
                   FROM spec022_payable_request_credits p
                  WHERE p.request_id = a.request_id
                    AND p.attempt_n = a.attempt_n
                    AND p.provider_id = a.provider_id
                    AND p.settlement_policy_mode = 'enforce'
                    AND p.settlement_account_scope_hash = a.account_scope_hash
                    AND p.settlement_policy_version = srs.route_snapshot_policy_version
                    AND p.gross_credits > 0
                    AND p.provider_credits > 0)
            THEN 1 ELSE 0 END
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

func readPoolProvenEvaluations(ctx context.Context, reader *sql.DB, query string, after int64, since string) ([]poolProvenEvaluation, error) {
	rows, err := reader.QueryContext(ctx, query, PoolLabelStatusVerified, after, since, poolProvenEvaluateBatch)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []poolProvenEvaluation
	for rows.Next() {
		var e poolProvenEvaluation
		if err := rows.Scan(&e.id, &e.storedCounted, &e.storedFinality, &e.evidencePresent, &e.finality, &e.counted); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func withPoolProvenTx(ctx context.Context, db *sql.DB, fn func(*sql.Tx) error) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
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
