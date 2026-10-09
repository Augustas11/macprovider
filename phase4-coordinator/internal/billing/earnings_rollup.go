package billing

// Provider earnings rollup (#1925).
//
// GET /providers/{id}/earnings used to sum the provider's whole payable
// history through spec022_payable_request_credits on every request. This file
// keeps a per-provider, per-UTC-hour, per-model cache of exactly the figures
// the endpoint reads from that view, and the endpoint combines the cached
// hours it can prove current with a live view read of every other hour.
//
// Correctness does not depend on knowing which code paths write billing rows:
//
//   - Every input of the view and of the endpoint's figures lives in five
//     tables (ledger_request_credits, ledger_quarantine_resolutions,
//     settlement_route_snapshots, settlement_receipt_verdicts,
//     settlement_attempt_outputs). Triggers on all five bump the generation
//     of every (provider, hour) bucket a write can affect, inside the
//     writer's own transaction: AFTER INSERT/UPDATE/DELETE for the written
//     row, and BEFORE INSERT/UPDATE for any existing row a REPLACE conflict
//     would delete (SQLite fires no delete trigger for those unless
//     recursive_triggers is on).
//   - A bucket is cached for the (generation, epoch) it was computed from.
//     The recompute reads both and the view in one read snapshot and commits
//     only if neither moved. Rows are never deleted, so a generation only
//     grows within an epoch, and a reset only grows the epoch: no ABA.
//   - The only input that changes without a write is time: a force credit
//     becomes payable when force_credit_matures_at_utc passes. Each bucket
//     stores the earliest future maturity of its rows (read before the view)
//     and is not trusted once that instant has passed. A reader fixes a cutoff
//     at the start of its snapshot and, after its last statement, confirms no
//     credit of the provider matured since the cutoff; otherwise it retries.
//     So every served figure equals the view at one instant.
//   - The schema (view SQL + trigger DDL) is fingerprinted; any change, or a
//     trigger lost to a table rebuild, bumps the epoch, which invalidates
//     every cached bucket at once without a bulk delete.
//
// Hour buckets are keyed by earningsHourKeySQL so that, for any timestamp text
// whose first 13 characters are a valid UTC hour, bucket H holds exactly the
// rows with H:00:00.000000000Z <= ts_utc < (H+1h):00:00.000000000Z under the
// same lexical comparison the endpoint's from/to, week and today filters use
// (all of which are midnight boundaries). Rows whose ts_utc does not start
// with a valid hour land in the empty-key bucket; a provider with any such row
// is served by the original full view read.

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"modernc.org/sqlite"
)

// providerEarningsRollupVersion is part of the schema fingerprint: bump it
// whenever the meaning of a cached bucket changes without a DDL change.
const providerEarningsRollupVersion = 2

const (
	// DefaultProviderEarningsRollupLimit bounds the buckets one refresh pass
	// recomputes; each bucket is its own short write transaction.
	DefaultProviderEarningsRollupLimit = 50
	// defaultProviderEarningsBackfillBatch bounds the ledger rows one backfill
	// step reads, and so the bucket marks its write transaction inserts.
	defaultProviderEarningsBackfillBatch = 500
	// providerEarningsRollupMigrationBudget bounds how long startup waits for
	// a lock held by another process (backup, sqlite3 shell) before failing.
	providerEarningsRollupMigrationBudget = 60 * time.Second
	// providerEarningsRollupReadAttempts bounds the retries of a read that
	// raced a force-credit maturity before it falls back to the view.
	providerEarningsRollupReadAttempts = 3
)

const earningsHourLayout = "2006-01-02T15"

// sqliteNowText is the clock the payable view compares force-credit
// maturity against.
const sqliteNowText = `strftime('%Y-%m-%dT%H:%M:%fZ', 'now')`

// earningsHourKeySQL buckets a timestamp text column by UTC hour, consistent
// with lexical comparison against canonical hour boundaries (see file
// comment). It yields the empty key for text that does not start with a
// valid hour.
func earningsHourKeySQL(col string) string {
	p := "substr(" + col + ", 1, 13)"
	// The '+0 hours' modifier makes strftime normalize (hour 24, Feb 30), so
	// only a prefix that is already a canonical hour round-trips. The lower
	// bound keeps the previous hour a four-digit year.
	return "COALESCE(CASE" +
		" WHEN NOT (" + p + " GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]'" +
		" AND " + p + " >= '0001-01-01T01'" +
		" AND strftime('%Y-%m-%dT%H', " + p + " || ':00:00', '+0 hours') = " + p + ") THEN NULL" +
		" WHEN " + col + " >= " + p + " || ':00:00.000000000Z' THEN " + p +
		" ELSE strftime('%Y-%m-%dT%H', " + p + " || ':00:00', '-1 hours') END, '')"
}

func earningsHourKey(t time.Time) string { return t.UTC().Format(earningsHourLayout) }

// earningsHourBoundary is sqliteTimeText of the hour's first instant.
func earningsHourBoundary(hour string) string { return hour + ":00:00.000000000Z" }

func nextEarningsHour(hour string) (string, error) {
	t, err := time.Parse(earningsHourLayout, hour)
	if err != nil {
		return "", fmt.Errorf("earnings rollup hour %q: %w", hour, err)
	}
	return earningsHourKey(t.Add(time.Hour)), nil
}

// earningsRollupLRCColumns are the ledger_request_credits columns the payable
// view or the endpoint's figures read. An UPDATE that changes none of them
// cannot change a bucket (settlement's settled/settlement_id stamping, for
// example), so the trigger skips it. TestProviderEarningsRollupTriggerCoversViewColumns
// pins this list against the view definition.
var earningsRollupLRCColumns = []string{
	"id", "request_id", "attempt_n", "provider_id", "ts_utc", "model",
	"provider_credits", "fault_flag", "quarantined",
	"settlement_policy_mode", "settlement_account_scope_hash", "settlement_policy_version",
}

// earningsRollupLRCKey is ledger_request_credits' only UNIQUE key besides
// its INTEGER PRIMARY KEY id. Every UNIQUE key of the other four inputs
// contains (request_id, attempt_n, provider_id), so a key conflict there
// deletes a row that affects the same credits as the new row; only an id
// conflict can reach other credits. TestProviderEarningsRollupReplaceKeysMatchSchema
// pins both facts against the schema.
var earningsRollupLRCKey = []string{"request_id", "attempt_n", "provider_id"}

type earningsRollupTrigger struct{ name, ddl string }

func earningsMarkSQL(from, where string) string {
	return `INSERT INTO provider_earnings_rollup_buckets(provider_id, bucket_hour, gen, computed_gen)
    SELECT c.provider_id, ` + earningsHourKeySQL("c.ts_utc") + `, 1, 0
      FROM ` + from + `
     WHERE ` + where + `
    ON CONFLICT(provider_id, bucket_hour) DO UPDATE SET gen = gen + 1;`
}

func earningsMarkBucketSQL(providerExpr, tsExpr string) string {
	return `INSERT INTO provider_earnings_rollup_buckets(provider_id, bucket_hour, gen, computed_gen)
    VALUES (` + providerExpr + `, ` + earningsHourKeySQL(tsExpr) + `, 1, 0)
    ON CONFLICT(provider_id, bucket_hour) DO UPDATE SET gen = gen + 1;`
}

// earningsCreditLink joins a row r of an input table to the credits it can
// affect, aliased c.
func earningsCreditLink(table, r string) string {
	if table == "ledger_quarantine_resolutions" {
		return "c.id = " + r + ".request_credit_id"
	}
	return "c.request_id = " + r + ".request_id AND c.attempt_n = " + r + ".attempt_n AND c.provider_id = " + r + ".provider_id"
}

// providerEarningsRollupTriggers is the complete trigger set. Every write to a
// view input marks the buckets of the credits it can affect: the written
// row's OLD and NEW, and any row a REPLACE conflict deletes.
func providerEarningsRollupTriggers() []earningsRollupTrigger {
	changed := make([]string, 0, len(earningsRollupLRCColumns))
	for _, col := range earningsRollupLRCColumns {
		changed = append(changed, "OLD."+col+" IS NOT NEW."+col)
	}
	keyMatch := make([]string, 0, len(earningsRollupLRCKey))
	keyChanged := []string{"OLD.id IS NOT NEW.id"}
	for _, col := range earningsRollupLRCKey {
		keyMatch = append(keyMatch, "c."+col+" = NEW."+col)
		keyChanged = append(keyChanged, "OLD."+col+" IS NOT NEW."+col)
	}
	lrcConflict := "c.id = NEW.id OR (" + strings.Join(keyMatch, " AND ") + ")"
	out := []earningsRollupTrigger{
		{"trg_per_lrc_insert", `CREATE TRIGGER trg_per_lrc_insert AFTER INSERT ON ledger_request_credits
BEGIN
    ` + earningsMarkBucketSQL("NEW.provider_id", "NEW.ts_utc") + `
END`},
		{"trg_per_lrc_update", `CREATE TRIGGER trg_per_lrc_update AFTER UPDATE ON ledger_request_credits
WHEN ` + strings.Join(changed, " OR ") + `
BEGIN
    ` + earningsMarkBucketSQL("OLD.provider_id", "OLD.ts_utc") + `
    ` + earningsMarkBucketSQL("NEW.provider_id", "NEW.ts_utc") + `
END`},
		{"trg_per_lrc_delete", `CREATE TRIGGER trg_per_lrc_delete AFTER DELETE ON ledger_request_credits
BEGIN
    ` + earningsMarkBucketSQL("OLD.provider_id", "OLD.ts_utc") + `
END`},
		{"trg_per_lrc_replace_insert", `CREATE TRIGGER trg_per_lrc_replace_insert BEFORE INSERT ON ledger_request_credits
BEGIN
    ` + earningsMarkSQL("ledger_request_credits c", lrcConflict) + `
END`},
		{"trg_per_lrc_replace_update", `CREATE TRIGGER trg_per_lrc_replace_update BEFORE UPDATE ON ledger_request_credits
WHEN ` + strings.Join(keyChanged, " OR ") + `
BEGIN
    ` + earningsMarkSQL("ledger_request_credits c", lrcConflict) + `
END`},
	}
	for _, t := range []struct{ short, table string }{
		{"lqr", "ledger_quarantine_resolutions"},
		{"srs", "settlement_route_snapshots"},
		{"srv", "settlement_receipt_verdicts"},
		{"sao", "settlement_attempt_outputs"},
	} {
		mark := func(r string) string {
			return earningsMarkSQL("ledger_request_credits c", earningsCreditLink(t.table, r))
		}
		replaced := earningsMarkSQL(t.table+" o JOIN ledger_request_credits c ON "+earningsCreditLink(t.table, "o"), "o.id = NEW.id")
		out = append(out,
			earningsRollupTrigger{"trg_per_" + t.short + "_insert", `CREATE TRIGGER trg_per_` + t.short + `_insert AFTER INSERT ON ` + t.table + `
BEGIN
    ` + mark("NEW") + `
END`},
			earningsRollupTrigger{"trg_per_" + t.short + "_update", `CREATE TRIGGER trg_per_` + t.short + `_update AFTER UPDATE ON ` + t.table + `
BEGIN
    ` + mark("OLD") + `
    ` + mark("NEW") + `
END`},
			earningsRollupTrigger{"trg_per_" + t.short + "_delete", `CREATE TRIGGER trg_per_` + t.short + `_delete AFTER DELETE ON ` + t.table + `
BEGIN
    ` + mark("OLD") + `
END`},
			earningsRollupTrigger{"trg_per_" + t.short + "_replace_insert", `CREATE TRIGGER trg_per_` + t.short + `_replace_insert BEFORE INSERT ON ` + t.table + `
WHEN NEW.id IS NOT NULL
BEGIN
    ` + replaced + `
END`},
			earningsRollupTrigger{"trg_per_" + t.short + "_replace_update", `CREATE TRIGGER trg_per_` + t.short + `_replace_update BEFORE UPDATE ON ` + t.table + `
WHEN OLD.id IS NOT NEW.id
BEGIN
    ` + replaced + `
END`},
		)
	}
	return out
}

// providerEarningsRollupFingerprint changes whenever the cached figures could
// mean something different: the payable view, the triggers, or the version.
func providerEarningsRollupFingerprint(viewSQL string) string {
	h := sha256.New()
	fmt.Fprintf(h, "v%d\x00%s\x00", providerEarningsRollupVersion, viewSQL)
	for _, t := range providerEarningsRollupTriggers() {
		fmt.Fprintf(h, "%s\x00%s\x00", t.name, t.ddl)
	}
	return hex.EncodeToString(h.Sum(nil))
}

// ensureProviderEarningsRollup is the startup migration. It is additive (new
// tables, indexes and triggers only) and idempotent. When the fingerprint
// differs or a trigger is missing it recreates the triggers and bumps the
// epoch in one transaction whose size does not depend on the data: cached
// rows of an older epoch are simply never trusted again and are rebuilt by
// the refresher in bounded batches, and the backfill runs later in batches.
func (s *Store) ensureProviderEarningsRollup(ctx context.Context) error {
	return retrySQLiteBusy(ctx, "provider earnings rollup migration", providerEarningsRollupMigrationBudget, time.Sleep, func() error {
		return s.ensureProviderEarningsRollupOnce(ctx)
	})
}

func (s *Store) ensureProviderEarningsRollupOnce(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS provider_earnings_rollup_state (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    fingerprint TEXT NOT NULL,
    epoch INTEGER NOT NULL,
    backfill_high_id INTEGER NOT NULL,
    backfill_cursor_id INTEGER NOT NULL,
    backfill_complete INTEGER NOT NULL CHECK(backfill_complete IN (0,1)),
    reset_at_utc TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS provider_earnings_rollup_buckets (
    provider_id TEXT NOT NULL,
    bucket_hour TEXT NOT NULL,
    gen INTEGER NOT NULL,
    computed_gen INTEGER NOT NULL,
    computed_epoch INTEGER NOT NULL DEFAULT 0,
    stale_at_utc TEXT NULL,
    PRIMARY KEY(provider_id, bucket_hour)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS provider_earnings_rollup (
    provider_id TEXT NOT NULL,
    bucket_hour TEXT NOT NULL,
    model TEXT NOT NULL,
    payable_count INTEGER NOT NULL,
    payable_credits INTEGER NOT NULL,
    fault_count INTEGER NOT NULL,
    PRIMARY KEY(provider_id, bucket_hour, model)
) WITHOUT ROWID;
`); err != nil {
		return err
	}
	hasEpoch, err := s.columnExists(ctx, "provider_earnings_rollup_buckets", "computed_epoch")
	if err != nil {
		return err
	}
	if !hasEpoch {
		if _, err := s.db.ExecContext(ctx, `ALTER TABLE provider_earnings_rollup_buckets ADD COLUMN computed_epoch INTEGER NOT NULL DEFAULT 0`); err != nil && !strings.Contains(err.Error(), "duplicate column name") {
			return err
		}
	}
	if _, err := s.db.ExecContext(ctx, `
CREATE INDEX IF NOT EXISTS idx_perb_dirty ON provider_earnings_rollup_buckets(provider_id, bucket_hour)
    WHERE gen != computed_gen;
CREATE INDEX IF NOT EXISTS idx_perb_epoch ON provider_earnings_rollup_buckets(computed_epoch, provider_id, bucket_hour);
CREATE INDEX IF NOT EXISTS idx_perb_stale ON provider_earnings_rollup_buckets(stale_at_utc)
    WHERE stale_at_utc IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_lqr_force_credit_matures ON ledger_quarantine_resolutions(force_credit_matures_at_utc)
    WHERE resolution_kind = 'force_credit' AND force_credit_matures_at_utc IS NOT NULL;
`); err != nil {
		return err
	}
	var viewSQL string
	if err := s.db.QueryRowContext(ctx, `SELECT sql FROM sqlite_master WHERE type='view' AND name='spec022_payable_request_credits'`).Scan(&viewSQL); err != nil {
		return fmt.Errorf("provider earnings rollup: read payable view: %w", err)
	}
	fingerprint := providerEarningsRollupFingerprint(viewSQL)
	triggers := providerEarningsRollupTriggers()
	var stored sql.NullString
	if err := s.db.QueryRowContext(ctx, `SELECT fingerprint FROM provider_earnings_rollup_state WHERE id = 1`).Scan(&stored); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	var present int
	names := make([]any, 0, len(triggers))
	for _, t := range triggers {
		names = append(names, t.name)
	}
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN (`+sqlPlaceholders(len(names))+`)`, names...).Scan(&present); err != nil {
		return err
	}
	if stored.Valid && stored.String == fingerprint && present == len(triggers) {
		return nil
	}
	reason := "first install"
	switch {
	case stored.Valid && stored.String != fingerprint:
		reason = "payable view or trigger definition changed"
	case stored.Valid:
		reason = "rollup trigger missing"
	}
	var high int64
	err = sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		// Drop every rollup trigger, including ones an older build named
		// differently, then create the current set.
		rows, err := conn.QueryContext(ctx, `SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'trg\_per\_%' ESCAPE '\'`)
		if err != nil {
			return err
		}
		var existing []string
		for rows.Next() {
			var name string
			if err := rows.Scan(&name); err != nil {
				rows.Close()
				return err
			}
			existing = append(existing, name)
		}
		if err := rows.Close(); err != nil {
			return err
		}
		for _, name := range existing {
			if _, err := conn.ExecContext(ctx, `DROP TRIGGER IF EXISTS "`+name+`"`); err != nil {
				return err
			}
		}
		for _, t := range triggers {
			if _, err := conn.ExecContext(ctx, t.ddl); err != nil {
				return fmt.Errorf("create %s: %w", t.name, err)
			}
		}
		// Rows above high were inserted after the triggers above (AUTOINCREMENT
		// never reuses ids), so they mark themselves; the backfill covers the rest.
		if err := conn.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM ledger_request_credits`).Scan(&high); err != nil {
			return err
		}
		_, err = conn.ExecContext(ctx, `
INSERT INTO provider_earnings_rollup_state(id, fingerprint, epoch, backfill_high_id, backfill_cursor_id, backfill_complete, reset_at_utc)
VALUES (1, ?, 1, ?, 0, ?, ?)
ON CONFLICT(id) DO UPDATE SET
    fingerprint = excluded.fingerprint,
    epoch = provider_earnings_rollup_state.epoch + 1,
    backfill_high_id = excluded.backfill_high_id,
    backfill_cursor_id = 0,
    backfill_complete = excluded.backfill_complete,
    reset_at_utc = excluded.reset_at_utc`,
			fingerprint, high, boolInt(high == 0), sqliteTimeText(time.Now()))
		return err
	})
	if err != nil {
		return err
	}
	if high > 0 {
		log.Printf("provider earnings rollup: reset (%s); backfill of ledger ids <= %d pending", reason, high)
	}
	return nil
}

// retrySQLiteBusy runs fn, retrying with bounded backoff while another
// process holds the database lock (as the #1923 column migration does).
func retrySQLiteBusy(ctx context.Context, what string, budget time.Duration, sleep func(time.Duration), fn func() error) error {
	deadline := time.Now().Add(budget)
	backoff := 100 * time.Millisecond
	for attempt := 1; ; attempt++ {
		err := fn()
		if err == nil || !sqliteBusyOrLocked(err) {
			return err
		}
		if ctx.Err() != nil || time.Now().Add(backoff).After(deadline) {
			return fmt.Errorf("%s: database still busy after %s: %w", what, budget, err)
		}
		log.Printf("%s: database busy (attempt %d), retrying in %s", what, attempt, backoff)
		sleep(backoff)
		if backoff < 2*time.Second {
			backoff *= 2
		}
	}
}

func sqliteBusyOrLocked(err error) bool {
	var sqliteErr *sqlite.Error
	if errors.As(err, &sqliteErr) {
		switch sqliteErr.Code() & 0xff {
		case 5, 6: // SQLITE_BUSY or SQLITE_LOCKED, including extended codes.
			return true
		}
	}
	msg := err.Error()
	return strings.Contains(msg, "database is locked") || strings.Contains(msg, "database table is locked")
}

type earningsBucketAgg struct {
	payableCount, payableCredits, faultCount int64
}

// earningsBuckets is hour -> model -> aggregate.
type earningsBuckets map[string]map[string]earningsBucketAgg

func (b earningsBuckets) add(hour, model string, fn func(*earningsBucketAgg)) {
	models := b[hour]
	if models == nil {
		models = map[string]earningsBucketAgg{}
		b[hour] = models
	}
	agg := models[model]
	fn(&agg)
	models[model] = agg
}

type sqlQueryer interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// computeEarningsBuckets reads the provider's payable credits and fault counts
// live, grouped by hour and model, for loHour <= ts_utc < hiHour ("" means
// unbounded). Payable figures come from spec022_payable_request_credits
// itself, so a live read is the view by definition.
func computeEarningsBuckets(ctx context.Context, q sqlQueryer, providerID, loHour, hiHour string) (earningsBuckets, error) {
	where := "provider_id = ?"
	args := []any{providerID}
	if loHour != "" {
		where += " AND " + sqliteTimeSince("ts_utc")
		args = append(args, earningsHourBoundary(loHour))
	}
	if hiHour != "" {
		where += " AND " + sqliteTimeBefore("ts_utc")
		args = append(args, earningsHourBoundary(hiHour))
	}
	out := earningsBuckets{}
	hk := earningsHourKeySQL("ts_utc")
	rows, err := q.QueryContext(ctx, `
SELECT `+hk+`, model, COUNT(*), COALESCE(SUM(provider_credits), 0)
  FROM spec022_payable_request_credits
 WHERE `+where+`
 GROUP BY 1, 2`, args...)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var hour, model string
		var count, credits int64
		if err := rows.Scan(&hour, &model, &count, &credits); err != nil {
			rows.Close()
			return nil, err
		}
		out.add(hour, model, func(a *earningsBucketAgg) { a.payableCount, a.payableCredits = count, credits })
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	rows, err = q.QueryContext(ctx, `
SELECT `+hk+`, model, COUNT(*)
  FROM ledger_request_credits
 WHERE `+where+` AND fault_flag != 'none'
 GROUP BY 1, 2`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var hour, model string
		var count int64
		if err := rows.Scan(&hour, &model, &count); err != nil {
			return nil, err
		}
		out.add(hour, model, func(a *earningsBucketAgg) { a.faultCount = count })
	}
	return out, rows.Err()
}

// ProviderEarningsRollupPass reports one refresh pass.
type ProviderEarningsRollupPass struct {
	BackfillMarked   int
	BackfillComplete bool
	Recomputed       int
	// Conflicts counts recomputes discarded because a writer or a reset moved
	// the bucket after the read snapshot; a later pass retries them.
	Conflicts int
	// Failed counts buckets whose recompute errored; the pass skipped them and
	// went on. LastFailure is the last such error.
	Failed      int
	LastFailure error
	// More is true when the pass stopped at a bound (limit or ctx deadline)
	// with work left.
	More bool
}

var errEarningsRollupMoved = errors.New("provider earnings rollup bucket changed during recompute")

type earningsBucketKey struct{ provider, hour string }

// earningsRollupCursors rotates the refresher's scans so buckets that keep
// conflicting cannot starve the rest.
type earningsRollupCursors struct {
	mu    sync.Mutex
	dirty earningsBucketKey
	epoch earningsBucketKey
}

// RefreshProviderEarningsRollup runs one bounded pass: one backfill batch
// while the backfill is incomplete, then up to limit buckets that are stale,
// dirty, or from an older epoch. It stops early, without error, when ctx's
// deadline passes; each bucket is its own short write transaction and reads
// use the read pool.
func (s *Store) RefreshProviderEarningsRollup(ctx context.Context, limit int) (ProviderEarningsRollupPass, error) {
	var pass ProviderEarningsRollupPass
	if limit <= 0 || limit > DefaultProviderEarningsRollupLimit {
		limit = DefaultProviderEarningsRollupLimit
	}
	yield := func(err error) (ProviderEarningsRollupPass, error) {
		if ctx.Err() != nil {
			pass.More = true
			return pass, nil
		}
		return pass, err
	}
	marked, complete, err := s.backfillProviderEarningsRollup(ctx)
	if err != nil {
		return yield(err)
	}
	pass.BackfillMarked, pass.BackfillComplete = marked, complete
	var epoch int64
	if err := s.reader().QueryRowContext(ctx, `SELECT epoch FROM provider_earnings_rollup_state WHERE id = 1`).Scan(&epoch); err != nil {
		return yield(err)
	}
	// Stale buckets get a reserved share so dirty churn cannot starve them.
	work, err := s.selectEarningsBuckets(ctx, `
SELECT provider_id, bucket_hour FROM provider_earnings_rollup_buckets INDEXED BY idx_perb_stale
 WHERE stale_at_utc IS NOT NULL AND stale_at_utc <= `+sqliteNowText+` AND gen = computed_gen AND computed_epoch = ?
 ORDER BY stale_at_utc
 LIMIT ?`, epoch, max(1, limit/5))
	if err != nil {
		return yield(err)
	}
	if room := limit - len(work); room > 0 {
		dirty, err := s.selectRotatingEarningsBuckets(ctx, &s.earningsRollupCursors.dirty, `INDEXED BY idx_perb_dirty WHERE gen != computed_gen`, nil, room)
		if err != nil {
			return yield(err)
		}
		work = append(work, dirty...)
	}
	if room := limit - len(work); room > 0 {
		// Buckets cached under an older epoch, oldest epoch first.
		var oldest sql.NullInt64
		if err := s.reader().QueryRowContext(ctx, `SELECT MIN(computed_epoch) FROM provider_earnings_rollup_buckets`).Scan(&oldest); err != nil {
			return yield(err)
		}
		if oldest.Valid && oldest.Int64 < epoch {
			old, err := s.selectRotatingEarningsBuckets(ctx, &s.earningsRollupCursors.epoch, `INDEXED BY idx_perb_epoch WHERE computed_epoch = ?`, []any{oldest.Int64}, room)
			if err != nil {
				return yield(err)
			}
			work = append(work, old...)
		}
	}
	seen := map[earningsBucketKey]bool{}
	for _, k := range work {
		if seen[k] {
			continue
		}
		seen[k] = true
		if ctx.Err() != nil {
			return yield(nil)
		}
		switch err := s.recomputeProviderEarningsBucket(ctx, k.provider, k.hour); {
		case err == nil:
			pass.Recomputed++
		case errors.Is(err, errEarningsRollupMoved):
			pass.Conflicts++
		case ctx.Err() != nil:
			return yield(nil)
		default:
			pass.Failed++
			pass.LastFailure = fmt.Errorf("recompute provider earnings bucket %s %q: %w", k.provider, k.hour, err)
		}
	}
	pass.More = !complete || len(work) == limit
	return pass, nil
}

func (s *Store) selectEarningsBuckets(ctx context.Context, query string, args ...any) ([]earningsBucketKey, error) {
	rows, err := s.reader().QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []earningsBucketKey
	for rows.Next() {
		var k earningsBucketKey
		if err := rows.Scan(&k.provider, &k.hour); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// selectRotatingEarningsBuckets returns up to n buckets matching cond in
// (provider, hour) order after *cursor, wrapping to the start, and advances
// the cursor past the last one returned.
func (s *Store) selectRotatingEarningsBuckets(ctx context.Context, cursor *earningsBucketKey, cond string, args []any, n int) ([]earningsBucketKey, error) {
	s.earningsRollupCursors.mu.Lock()
	from := *cursor
	s.earningsRollupCursors.mu.Unlock()
	base := `SELECT provider_id, bucket_hour FROM provider_earnings_rollup_buckets ` + cond
	out, err := s.selectEarningsBuckets(ctx, base+` AND (provider_id, bucket_hour) > (?, ?) ORDER BY provider_id, bucket_hour LIMIT ?`, append(append([]any{}, args...), from.provider, from.hour, n)...)
	if err != nil {
		return nil, err
	}
	if len(out) < n && (from != earningsBucketKey{}) {
		wrapped, err := s.selectEarningsBuckets(ctx, base+` AND (provider_id, bucket_hour) <= (?, ?) ORDER BY provider_id, bucket_hour LIMIT ?`, append(append([]any{}, args...), from.provider, from.hour, n-len(out))...)
		if err != nil {
			return nil, err
		}
		out = append(out, wrapped...)
	}
	if len(out) > 0 {
		s.earningsRollupCursors.mu.Lock()
		*cursor = out[len(out)-1]
		s.earningsRollupCursors.mu.Unlock()
	}
	return out, nil
}

// backfillProviderEarningsRollup marks the buckets of one batch of ledger rows
// that predate the triggers. The cursor advances in the same transaction as
// the marks, so a crash resumes at the first unmarked row; re-marking is
// harmless because a recompute always reads the base tables.
func (s *Store) backfillProviderEarningsRollup(ctx context.Context) (int, bool, error) {
	var epoch, high, cursor int64
	var complete int
	if err := s.reader().QueryRowContext(ctx, `SELECT epoch, backfill_high_id, backfill_cursor_id, backfill_complete FROM provider_earnings_rollup_state WHERE id = 1`).Scan(&epoch, &high, &cursor, &complete); err != nil {
		return 0, false, err
	}
	if complete == 1 {
		return 0, true, nil
	}
	batch := s.earningsRollupBackfillBatch
	if batch <= 0 {
		batch = defaultProviderEarningsBackfillBatch
	}
	seen := map[earningsBucketKey]bool{}
	var marks []earningsBucketKey
	rows, err := s.reader().QueryContext(ctx, `
SELECT id, provider_id, `+earningsHourKeySQL("ts_utc")+`
  FROM ledger_request_credits
 WHERE id > ? AND id <= ?
 ORDER BY id
 LIMIT ?`, cursor, high, batch)
	if err != nil {
		return 0, false, err
	}
	n, last := 0, cursor
	for rows.Next() {
		var k earningsBucketKey
		if err := rows.Scan(&last, &k.provider, &k.hour); err != nil {
			rows.Close()
			return 0, false, err
		}
		n++
		if !seen[k] {
			seen[k] = true
			marks = append(marks, k)
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, false, err
	}
	rows.Close()
	done := n < batch || last >= high
	if done {
		last = high
	}
	err = sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		res, err := conn.ExecContext(ctx, `
UPDATE provider_earnings_rollup_state
   SET backfill_cursor_id = ?, backfill_complete = ?
 WHERE id = 1 AND epoch = ? AND backfill_cursor_id = ? AND backfill_complete = 0`, last, boolInt(done), epoch, cursor)
		if err != nil {
			return err
		}
		if affected, err := res.RowsAffected(); err != nil {
			return err
		} else if affected != 1 {
			return errEarningsRollupMoved
		}
		for _, k := range marks {
			if _, err := conn.ExecContext(ctx, `INSERT OR IGNORE INTO provider_earnings_rollup_buckets(provider_id, bucket_hour, gen, computed_gen) VALUES (?, ?, 1, 0)`, k.provider, k.hour); err != nil {
				return err
			}
		}
		return nil
	})
	if errors.Is(err, errEarningsRollupMoved) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return len(marks), done, nil
}

// recomputeProviderEarningsBucket rebuilds one bucket from the base tables and
// commits it only if neither its generation nor the epoch moved since the
// read snapshot.
func (s *Store) recomputeProviderEarningsBucket(ctx context.Context, providerID, hour string) error {
	tx, err := s.reader().BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	var gen, epoch int64
	if err := tx.QueryRowContext(ctx, `
SELECT b.gen, s.epoch
  FROM provider_earnings_rollup_buckets b, provider_earnings_rollup_state s
 WHERE b.provider_id = ? AND b.bucket_hour = ? AND s.id = 1`, providerID, hour).Scan(&gen, &epoch); err != nil {
		_ = tx.Rollback()
		if errors.Is(err, sql.ErrNoRows) {
			return errEarningsRollupMoved
		}
		return err
	}
	var staleAt sql.NullString
	var models map[string]earningsBucketAgg
	// The empty-key bucket (unparseable ts_utc) is never served from the
	// cache: a provider that has one is read in full from the view.
	if hour != "" {
		next, err := nextEarningsHour(hour)
		if err != nil {
			_ = tx.Rollback()
			return err
		}
		// Maturity first, view second: any force credit the view still saw
		// as held is in the future of this read, so it is counted here.
		if err := tx.QueryRowContext(ctx, `
SELECT MIN(lqr.force_credit_matures_at_utc)
  FROM ledger_request_credits lrc
  JOIN ledger_quarantine_resolutions lqr ON lqr.request_credit_id = lrc.id
 WHERE lrc.provider_id = ? AND `+sqliteTimeRange("lrc.ts_utc")+`
   AND lqr.resolution_kind = 'force_credit'
   AND lqr.force_credit_matures_at_utc IS NOT NULL
   AND lqr.force_credit_matures_at_utc > `+sqliteNowText,
			providerID, earningsHourBoundary(hour), earningsHourBoundary(next)).Scan(&staleAt); err != nil {
			_ = tx.Rollback()
			return err
		}
		buckets, err := computeEarningsBuckets(ctx, tx, providerID, hour, next)
		if err != nil {
			_ = tx.Rollback()
			return err
		}
		models = buckets[hour]
	}
	if err := tx.Rollback(); err != nil {
		return err
	}
	if s.earningsRollupAfterRead != nil {
		s.earningsRollupAfterRead(providerID, hour)
	}
	return sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		res, err := conn.ExecContext(ctx, `
UPDATE provider_earnings_rollup_buckets
   SET computed_gen = gen, computed_epoch = ?, stale_at_utc = ?
 WHERE provider_id = ? AND bucket_hour = ? AND gen = ?
   AND ? = (SELECT epoch FROM provider_earnings_rollup_state WHERE id = 1)`, epoch, staleAt, providerID, hour, gen, epoch)
		if err != nil {
			return err
		}
		if affected, err := res.RowsAffected(); err != nil {
			return err
		} else if affected != 1 {
			return errEarningsRollupMoved
		}
		if _, err := conn.ExecContext(ctx, `DELETE FROM provider_earnings_rollup WHERE provider_id = ? AND bucket_hour = ?`, providerID, hour); err != nil {
			return err
		}
		for model, agg := range models {
			if _, err := conn.ExecContext(ctx, `
INSERT INTO provider_earnings_rollup(provider_id, bucket_hour, model, payable_count, payable_credits, fault_count)
VALUES (?, ?, ?, ?, ?, ?)`, providerID, hour, model, agg.payableCount, agg.payableCredits, agg.faultCount); err != nil {
				return err
			}
		}
		return nil
	})
}

// earningsWindows are the endpoint's filters: an optional [from, to) range
// and the week/today starts. All are UTC midnights.
type earningsWindows struct {
	from, to    time.Time
	hasRange    bool
	week, today time.Time
}

type providerEarningsFigures struct {
	total, week, today, pending, faults int64
	models                              []string
}

// errEarningsRollupMaturityRace means a force credit of the provider matured
// while the read ran, so its statements may disagree; the read is retried.
var errEarningsRollupMaturityRace = errors.New("provider earnings read raced a force-credit maturity")

// providerEarningsFromRollup serves the figures from cached buckets plus a
// live view read of every hour without a current cache entry, in one read
// snapshot and at one maturity instant. ok=false means the cache cannot
// answer (backfill not finished, the provider has rows outside hour
// bucketing, or maturities kept racing the read) and the caller reads the
// view.
func (s *Store) providerEarningsFromRollup(ctx context.Context, providerID string, win earningsWindows) (providerEarningsFigures, bool, error) {
	for attempt := 0; attempt < providerEarningsRollupReadAttempts; attempt++ {
		figures, ok, err := s.providerEarningsFromRollupOnce(ctx, providerID, win)
		if !errors.Is(err, errEarningsRollupMaturityRace) {
			return figures, ok, err
		}
	}
	return providerEarningsFigures{}, false, nil
}

func (s *Store) providerEarningsFromRollupOnce(ctx context.Context, providerID string, win earningsWindows) (providerEarningsFigures, bool, error) {
	tx, err := s.reader().BeginTx(ctx, nil)
	if err != nil {
		return providerEarningsFigures{}, false, err
	}
	defer func() { _ = tx.Rollback() }()
	return s.providerEarningsFromRollupTx(ctx, tx, providerID, win)
}

func (s *Store) providerEarningsFromRollupTx(ctx context.Context, tx *sql.Tx, providerID string, win earningsWindows) (providerEarningsFigures, bool, error) {
	// cutoff is the maturity instant every figure is evaluated at.
	var cutoff string
	var complete int
	var epoch int64
	if err := tx.QueryRowContext(ctx, `SELECT `+sqliteNowText+`, backfill_complete, epoch FROM provider_earnings_rollup_state WHERE id = 1`).Scan(&cutoff, &complete, &epoch); errors.Is(err, sql.ErrNoRows) {
		return providerEarningsFigures{}, false, nil
	} else if err != nil {
		return providerEarningsFigures{}, false, err
	}
	if complete != 1 {
		return providerEarningsFigures{}, false, nil
	}
	rows, err := tx.QueryContext(ctx, `
SELECT bucket_hour,
       gen = computed_gen AND computed_epoch = ? AND (stale_at_utc IS NULL OR stale_at_utc > ?)
  FROM provider_earnings_rollup_buckets
 WHERE provider_id = ?`, epoch, cutoff, providerID)
	if err != nil {
		return providerEarningsFigures{}, false, err
	}
	clean := map[string]bool{}
	irregular := false
	for rows.Next() {
		var hour string
		var ok bool
		if err := rows.Scan(&hour, &ok); err != nil {
			rows.Close()
			return providerEarningsFigures{}, false, err
		}
		if hour == "" {
			irregular = true
		}
		if ok {
			clean[hour] = true
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return providerEarningsFigures{}, false, err
	}
	rows.Close()
	if irregular {
		return providerEarningsFigures{}, false, nil
	}
	buckets := earningsBuckets{}
	rows, err = tx.QueryContext(ctx, `
SELECT bucket_hour, model, payable_count, payable_credits, fault_count
  FROM provider_earnings_rollup
 WHERE provider_id = ?`, providerID)
	if err != nil {
		return providerEarningsFigures{}, false, err
	}
	for rows.Next() {
		var hour, model string
		var agg earningsBucketAgg
		if err := rows.Scan(&hour, &model, &agg.payableCount, &agg.payableCredits, &agg.faultCount); err != nil {
			rows.Close()
			return providerEarningsFigures{}, false, err
		}
		if clean[hour] {
			buckets.add(hour, model, func(a *earningsBucketAgg) { *a = agg })
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return providerEarningsFigures{}, false, err
	}
	rows.Close()
	if s.earningsRollupReadHook != nil {
		s.earningsRollupReadHook()
	}
	// Every hour that is not clean is read live: the gaps between clean hours
	// plus everything before the first and after the last. Hours with no
	// bucket hold no rows, so merging them into a gap costs nothing.
	cleanHours := make([]string, 0, len(clean))
	for hour := range clean {
		cleanHours = append(cleanHours, hour)
	}
	sort.Strings(cleanHours)
	lo := ""
	readGap := func(hi string) error {
		live, err := computeEarningsBuckets(ctx, tx, providerID, lo, hi)
		if err != nil {
			return err
		}
		for hour, models := range live {
			if hour == "" || clean[hour] {
				// Cannot happen when the triggers hold; never double count.
				return errEarningsRollupMoved
			}
			for model, agg := range models {
				buckets.add(hour, model, func(a *earningsBucketAgg) { *a = agg })
			}
		}
		return nil
	}
	for _, hour := range cleanHours {
		if lo != hour {
			if err := readGap(hour); errors.Is(err, errEarningsRollupMoved) {
				return providerEarningsFigures{}, false, nil
			} else if err != nil {
				return providerEarningsFigures{}, false, err
			}
		}
		var err error
		if lo, err = nextEarningsHour(hour); err != nil {
			return providerEarningsFigures{}, false, err
		}
	}
	if err := readGap(""); errors.Is(err, errEarningsRollupMoved) {
		return providerEarningsFigures{}, false, nil
	} else if err != nil {
		return providerEarningsFigures{}, false, err
	}
	// The view's payable set changes over time only when a force credit
	// matures (the startup migration creates the index this range scan uses). If none of this provider's matured after cutoff (up to now,
	// which is no earlier than any statement above), every statement saw the
	// same payable set: the one at cutoff.
	var raced bool
	if err := tx.QueryRowContext(ctx, `
SELECT EXISTS (
    SELECT 1
      FROM ledger_quarantine_resolutions lqr INDEXED BY idx_lqr_force_credit_matures
      JOIN ledger_request_credits c ON c.id = lqr.request_credit_id
     WHERE lqr.resolution_kind = 'force_credit'
       AND lqr.force_credit_matures_at_utc IS NOT NULL
       AND lqr.force_credit_matures_at_utc > ?
       AND lqr.force_credit_matures_at_utc <= `+sqliteNowText+`
       AND c.provider_id = ?)`, cutoff, providerID).Scan(&raced); err != nil {
		return providerEarningsFigures{}, false, err
	}
	if raced {
		return providerEarningsFigures{}, false, errEarningsRollupMaturityRace
	}
	return foldEarningsBuckets(buckets, win), true, nil
}

// foldEarningsBuckets applies the endpoint's filters to hour buckets. Every
// boundary is a UTC midnight, so comparing hour keys is comparing ts_utc.
func foldEarningsBuckets(buckets earningsBuckets, win earningsWindows) providerEarningsFigures {
	fromKey, toKey := earningsHourKey(win.from), earningsHourKey(win.to)
	weekKey, todayKey := earningsHourKey(win.week), earningsHourKey(win.today)
	out := providerEarningsFigures{models: []string{}}
	models := map[string]bool{}
	for hour, byModel := range buckets {
		inRange := !win.hasRange || (hour >= fromKey && hour < toKey)
		for model, agg := range byModel {
			out.pending += agg.payableCredits
			if !inRange {
				continue
			}
			out.total += agg.payableCredits
			if hour >= weekKey {
				out.week += agg.payableCredits
			}
			if hour >= todayKey {
				out.today += agg.payableCredits
			}
			out.faults += agg.faultCount
			if agg.payableCount > 0 {
				models[model] = true
			}
		}
	}
	for model := range models {
		out.models = append(out.models, model)
	}
	sort.Strings(out.models)
	return out
}
