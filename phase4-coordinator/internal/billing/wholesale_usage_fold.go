package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// SPEC-005 §2.1b (#1793 slice 8a): request_log keeps
// storage.request_log_retention_days (default 14). A D1a wholesale statement
// prices a whole month of an account's status-200 rows, so before an
// account's rows leave, they are folded into wholesale_usage_daily: per
// account, UTC day, model, and the config generations that price the row
// (its exact and hot-path-derived identity snapshots, and the snapshot in
// effect at its timestamp). A statement reads the folded days and the live
// rows; a month boundary is a day boundary, so the totals are exactly the
// ones the rows gave. The fold and the delete commit in one transaction, and
// a request's rows leave together, so an attempt ordinal never changes
// under a row still to be priced.

const (
	wholesaleFoldScanChunk = 500
	// wholesaleFoldGroupsPerTx bounds the requests one fold transaction
	// holds the writer for.
	wholesaleFoldGroupsPerTx = 50
	// wholesaleFoldRowsPerTx bounds the request_log rows one fold
	// transaction deletes (a request's rows always leave together).
	wholesaleFoldRowsPerTx = 500
	// wholesaleNoSnapshot marks a generation column that does not apply
	// (identity) or did not resolve (timestamp: the statement fails closed
	// with ErrWholesaleNoGeneration, as it did on the row).
	wholesaleNoSnapshot = int64(-1)
)

func (s *Store) ensureWholesaleUsageDailyTable(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS wholesale_usage_daily (
    account_id TEXT NOT NULL,
    day_utc TEXT NOT NULL,
    model TEXT NOT NULL,
    exact_snapshot_id INTEGER NOT NULL,
    derived_snapshot_id INTEGER NOT NULL,
    ts_snapshot_id INTEGER NOT NULL,
    request_count INTEGER NOT NULL CHECK(request_count > 0),
    prompt_tokens INTEGER NOT NULL CHECK(prompt_tokens >= 0),
    completion_tokens INTEGER NOT NULL CHECK(completion_tokens >= 0),
    PRIMARY KEY(account_id, day_utc, model, exact_snapshot_id, derived_snapshot_id, ts_snapshot_id)
);
CREATE TRIGGER IF NOT EXISTS trg_wud_no_delete
BEFORE DELETE ON wholesale_usage_daily
BEGIN
    SELECT RAISE(ABORT, 'wholesale usage daily aggregate is permanent');
END;`)
	return err
}

// wholesaleFoldRow is one status-200 request_log row as a statement prices it.
type wholesaleFoldRow struct {
	model      string
	tsText     string
	prompt     sql.NullInt64
	completion sql.NullInt64
	exact      sql.NullInt64
	derived    sql.NullInt64
}

// wholesaleRowsSQL selects the status-200, partner-paid rows of the request
// log with the linked config generations, exactly as wholesaleLineTotals
// prices them; where restricts the rows.
func wholesaleRowsSQL(where string) string {
	identityAt := func(ordinal string) string {
		return `FROM ledger_provider_identity_snapshots lpis
         WHERE lpis.request_id = r.request_id
           AND lpis.provider_assigned_id = r.provider_assigned_id
           AND lpis.attempt_n = r.` + ordinal
	}
	return `
WITH r AS (
SELECT rl.id, rl.request_id, rl.provider_assigned_id, rl.model, rl.ts_utc, rl.prompt_tokens, rl.completion_tokens,
       ` + requestLogAttemptOrdinalSQL("rl") + ` AS attempt_ordinal,
       ` + requestLogIDOrdinalSQL("rl") + ` AS id_ordinal
  FROM request_log rl
 WHERE rl.status = 200
   AND ` + where + `
   -- SPEC-050-R008: allowance-funded requests are not partner-paid usage.
   AND NOT EXISTS (
       SELECT 1 FROM allowance_reservations ar
        WHERE ar.account_id = rl.account_id
          AND ar.request_id = rl.external_request_id
          AND ar.funding = 'allowance')
)
SELECT r.model, r.ts_utc, r.prompt_tokens, r.completion_tokens,
       (SELECT lpis.config_snapshot_id ` + identityAt("attempt_ordinal") + `) AS exact_snapshot_id,
       CASE
         WHEN r.id_ordinal > r.attempt_ordinal
           THEN (SELECT lpis.config_snapshot_id ` + identityAt("id_ordinal") + `)
       END AS derived_snapshot_id
  FROM r
 ORDER BY r.id`
}

// FoldWholesaleRequestLog folds and deletes the request_log rows of every
// (account, request) whose rows are all older than cutoff, in short
// transactions, until none is left or ctx ends. Rows without an account are
// left to the request-log pruner. The scan walks the ts_utc index by
// (ts_utc, rowid) keyset, so a pass reads only rows older than cutoff once.
// It returns the rows deleted.
func (s *Store) FoldWholesaleRequestLog(ctx context.Context, cutoff time.Time) (int64, error) {
	cutoffText := sqliteTimeText(cutoff)
	var deleted int64
	lastTS, lastRow := "", int64(0)
	for {
		if err := ctx.Err(); err != nil {
			return deleted, err
		}
		rows, err := s.db.QueryContext(ctx, `
SELECT rowid, ts_utc, account_id, request_id FROM request_log
 WHERE ts_utc >= ? AND ts_utc < ?
   AND NOT (ts_utc = ? AND rowid <= ?)
   AND account_id IS NOT NULL
 ORDER BY ts_utc, rowid
 LIMIT ?`, lastTS, cutoffText, lastTS, lastRow, wholesaleFoldScanChunk)
		if err != nil {
			return deleted, err
		}
		var groups []wholesaleFoldGroup
		seen := map[wholesaleFoldGroup]bool{}
		n := 0
		for rows.Next() {
			var rowid int64
			var ts string
			var g wholesaleFoldGroup
			if err := rows.Scan(&rowid, &ts, &g.account, &g.request); err != nil {
				rows.Close()
				return deleted, err
			}
			n++
			lastTS, lastRow = ts, rowid
			if !seen[g] {
				seen[g] = true
				groups = append(groups, g)
			}
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return deleted, err
		}
		if err := rows.Close(); err != nil {
			return deleted, err
		}
		if n == 0 {
			return deleted, nil
		}
		// Short transactions with a pause between them, so the hot-path
		// writer is never starved.
		for len(groups) > 0 {
			got, done, err := s.foldWholesaleGroups(ctx, sqliteTimeText(cutoff), groups[:min(len(groups), wholesaleFoldGroupsPerTx)])
			deleted += got
			if err != nil {
				return deleted, err
			}
			groups = groups[done:]
			if len(groups) > 0 {
				select {
				case <-ctx.Done():
					return deleted, ctx.Err()
				case <-time.After(10 * time.Millisecond):
				}
			}
		}
		if n < wholesaleFoldScanChunk {
			return deleted, nil
		}
		select {
		case <-ctx.Done():
			return deleted, ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
}

// wholesaleFoldGroup is one (account, request): its rows leave together.
type wholesaleFoldGroup struct{ account, request string }

// foldWholesaleGroups folds groups in one transaction until it has deleted
// wholesaleFoldRowsPerTx rows; it returns the rows deleted and the groups it
// got through (at least one).
func (s *Store) foldWholesaleGroups(ctx context.Context, cutoffText string, groups []wholesaleFoldGroup) (int64, int, error) {
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return 0, 0, err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return 0, 0, err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()
	var deleted int64
	done := 0
	for _, g := range groups {
		if done > 0 && deleted >= wholesaleFoldRowsPerTx {
			break
		}
		done++
		var young int
		if err := conn.QueryRowContext(ctx, `
SELECT COUNT(*) FROM request_log
 WHERE account_id = ? AND request_id = ? AND julianday(ts_utc) >= julianday(?)`, g.account, g.request, cutoffText).Scan(&young); err != nil {
			return 0, 0, err
		}
		if young > 0 {
			// A row of the request is still inside the window: the whole
			// request stays until it leaves together.
			continue
		}
		rows, err := conn.QueryContext(ctx, wholesaleRowsSQL(`rl.account_id = ? AND rl.request_id = ?`), g.account, g.request)
		if err != nil {
			return 0, 0, err
		}
		var fold []wholesaleFoldRow
		for rows.Next() {
			var r wholesaleFoldRow
			if err := rows.Scan(&r.model, &r.tsText, &r.prompt, &r.completion, &r.exact, &r.derived); err != nil {
				rows.Close()
				return 0, 0, err
			}
			fold = append(fold, r)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return 0, 0, err
		}
		if err := rows.Close(); err != nil {
			return 0, 0, err
		}
		for _, r := range fold {
			tsSnapshot := wholesaleNoSnapshot
			if !r.exact.Valid && !r.derived.Valid {
				if ts, err := time.Parse(time.RFC3339Nano, r.tsText); err == nil {
					id, _, _, _, serr := snapshotAtQueryer(ctx, conn, ts)
					switch {
					case serr == nil:
						tsSnapshot = id
					case errors.Is(serr, ErrNoSnapshot):
					default:
						return 0, 0, serr
					}
				}
			}
			day := dayPrefix(r.tsText)
			if ts, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(r.tsText)); err == nil {
				day = ts.UTC().Format("2006-01-02")
			}
			if _, err := conn.ExecContext(ctx, `
INSERT INTO wholesale_usage_daily (
    account_id, day_utc, model, exact_snapshot_id, derived_snapshot_id, ts_snapshot_id,
    request_count, prompt_tokens, completion_tokens
) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
ON CONFLICT(account_id, day_utc, model, exact_snapshot_id, derived_snapshot_id, ts_snapshot_id) DO UPDATE SET
    request_count = request_count + 1,
    prompt_tokens = prompt_tokens + excluded.prompt_tokens,
    completion_tokens = completion_tokens + excluded.completion_tokens`,
				g.account, day, r.model, nullSnapshot(r.exact), nullSnapshot(r.derived), tsSnapshot,
				r.prompt.Int64, r.completion.Int64); err != nil {
				return 0, 0, fmt.Errorf("fold wholesale usage: %w", err)
			}
		}
		res, err := conn.ExecContext(ctx, `DELETE FROM request_log WHERE account_id = ? AND request_id = ?`, g.account, g.request)
		if err != nil {
			return 0, 0, err
		}
		n, _ := res.RowsAffected()
		deleted += n
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return 0, 0, err
	}
	committed = true
	return deleted, done, nil
}

func nullSnapshot(v sql.NullInt64) int64 {
	if v.Valid {
		return v.Int64
	}
	return wholesaleNoSnapshot
}

// foldedWholesaleRows reads an account's folded days in [startText, endText)
// as statement rows: each carries the summed tokens and its request count.
func foldedWholesaleRows(ctx context.Context, q evidenceQueryer, accountID, startText, endText string) ([]wholesaleFoldedRow, error) {
	startDay, endDay := dayPrefix(startText), dayPrefix(endText)
	rows, err := q.QueryContext(ctx, `
SELECT day_utc, model, exact_snapshot_id, derived_snapshot_id, ts_snapshot_id,
       request_count, prompt_tokens, completion_tokens
  FROM wholesale_usage_daily
 WHERE account_id = ? AND day_utc >= ? AND day_utc < ?
 ORDER BY day_utc, model, exact_snapshot_id, derived_snapshot_id, ts_snapshot_id`, accountID, startDay, endDay)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []wholesaleFoldedRow
	for rows.Next() {
		var r wholesaleFoldedRow
		var exact, derived int64
		if err := rows.Scan(&r.day, &r.model, &exact, &derived, &r.tsSnapshot, &r.count, &r.prompt, &r.completion); err != nil {
			return nil, err
		}
		if exact != wholesaleNoSnapshot {
			r.exact = sql.NullInt64{Int64: exact, Valid: true}
		}
		if derived != wholesaleNoSnapshot {
			r.derived = sql.NullInt64{Int64: derived, Valid: true}
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

type wholesaleFoldedRow struct {
	day                       string
	model                     string
	exact, derived            sql.NullInt64
	tsSnapshot                int64
	count, prompt, completion int64
}

func dayPrefix(text string) string {
	text = strings.TrimSpace(text)
	if len(text) >= 10 {
		return text[:10]
	}
	return text
}
