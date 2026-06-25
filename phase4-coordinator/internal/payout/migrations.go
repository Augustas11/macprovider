package payout

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/payout/migrations"
)

// Migrate applies every SPEC-016 schema migration to db in
// lexicographic filename order. Each migration MAY use either
// idempotent statements (CREATE TABLE/INDEX/TRIGGER IF NOT
// EXISTS) or non-idempotent statements (ALTER TABLE ADD COLUMN);
// the runner tracks applied migration names in
// payout_schema_applied so re-runs are safe even when SQLite
// cannot natively enforce idempotency on the statement (e.g.
// ALTER TABLE ADD COLUMN — codex round-1 [sec:2.1] closure
// added migration 0010 which uses ALTER).
//
// SPEC-016 §3.1 / §4.7 / §4.8a / §4.8b / §4.9 pin every
// SPEC-016 table to the SAME SQLite database file as SPEC-005's
// ledger_payout_ready. Migrate is invoked on the shared *sql.DB
// handle returned by requestlog.OpenStore — the same handle
// billing.NewStore receives — so the same-DB pin holds
// structurally; AssertPragmas + AssertSameDB further verify
// at runtime.
func Migrate(ctx context.Context, db *sql.DB) error {
	if db == nil {
		return fmt.Errorf("payout.Migrate: db is required")
	}
	if _, err := db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS payout_schema_applied (
    name TEXT PRIMARY KEY,
    applied_at_utc TEXT NOT NULL
)`); err != nil {
		return fmt.Errorf("payout.Migrate: bootstrap tracking table: %w", err)
	}
	entries, err := fs.ReadDir(migrations.FS, ".")
	if err != nil {
		return fmt.Errorf("payout.Migrate: read embedded migrations: %w", err)
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasSuffix(name, ".sql") {
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		var applied string
		err := db.QueryRowContext(ctx,
			`SELECT name FROM payout_schema_applied WHERE name = ?`, name,
		).Scan(&applied)
		if err == nil && applied == name {
			continue // already applied
		}
		if err != nil && err != sql.ErrNoRows {
			return fmt.Errorf("payout.Migrate: lookup %s: %w", name, err)
		}
		body, err := fs.ReadFile(migrations.FS, name)
		if err != nil {
			return fmt.Errorf("payout.Migrate: read %s: %w", name, err)
		}
		if _, err := db.ExecContext(ctx, string(body)); err != nil {
			return fmt.Errorf("payout.Migrate: exec %s: %w", name, err)
		}
		if _, err := db.ExecContext(ctx,
			`INSERT INTO payout_schema_applied (name, applied_at_utc) VALUES (?, ?)`,
			name, "0",
		); err != nil {
			return fmt.Errorf("payout.Migrate: record %s: %w", name, err)
		}
	}
	return nil
}

// AssertPragmas verifies that the open *sql.DB has the PRAGMA
// values SPEC-016 §3.1 requires: foreign_keys=ON, journal_mode=WAL,
// synchronous=FULL. Failing fast on mismatch is the SPEC's
// "fail-loud" requirement — a connection with relaxed durability
// silently weakens the money-path guarantees the §4.x atomicity
// arguments rest on.
func AssertPragmas(ctx context.Context, db *sql.DB) error {
	if db == nil {
		return fmt.Errorf("payout.AssertPragmas: db is required")
	}
	var foreignKeys int
	if err := db.QueryRowContext(ctx, `PRAGMA foreign_keys`).Scan(&foreignKeys); err != nil {
		return fmt.Errorf("payout.AssertPragmas: read foreign_keys: %w", err)
	}
	if foreignKeys != 1 {
		return fmt.Errorf("payout.AssertPragmas: foreign_keys must be ON (got %d) — see SPEC-016 §3.1", foreignKeys)
	}
	var journalMode string
	if err := db.QueryRowContext(ctx, `PRAGMA journal_mode`).Scan(&journalMode); err != nil {
		return fmt.Errorf("payout.AssertPragmas: read journal_mode: %w", err)
	}
	if !strings.EqualFold(journalMode, "wal") {
		return fmt.Errorf("payout.AssertPragmas: journal_mode must be WAL (got %q) — see SPEC-016 §3.1", journalMode)
	}
	var synchronous int
	if err := db.QueryRowContext(ctx, `PRAGMA synchronous`).Scan(&synchronous); err != nil {
		return fmt.Errorf("payout.AssertPragmas: read synchronous: %w", err)
	}
	// SQLite reports synchronous as an integer: 0=OFF, 1=NORMAL,
	// 2=FULL, 3=EXTRA. SPEC-016 §3.1 requires FULL.
	if synchronous != 2 {
		return fmt.Errorf("payout.AssertPragmas: synchronous must be FULL=2 (got %d) — see SPEC-016 §3.1", synchronous)
	}
	return nil
}

// payoutTables enumerates every SPEC-016-owned table whose §3.1
// / §4.7 / §4.8a / §4.8b / §4.9 prose pins it to the same
// SQLite database file as SPEC-005's ledger_payout_ready.
// AssertSameDB walks this list against PRAGMA database_list to
// catch a misconfigured multi-DB topology at startup.
var payoutTables = []string{
	"provider_payout_addresses",
	"provider_payout_address_nonces",
	"payout_attempts",
	"payout_runner_state",
	"runtime_flags",
	"runtime_flag_audit",
	"runtime_flags_bootstrapped",
	"payout_runner_lease",
	"payout_hot_wallet_funding",
	"payout_reorg_orphans",
	"cancel_reconfirm_stale_outbox",
	"wallet_nonce_cursor",
}

// AssertSameDB verifies that every payout table resolves through
// the SAME PRAGMA database_list "main" database as
// ledger_payout_ready. SPEC-016 §3.1 / §4.7 / §4.8a / §4.8b /
// §4.9 require the same-DB pin so the §9.5b.1 compensation flow
// and the §4.8 intra-txn trigger-presence check stay
// transactionally atomic. ATTACHed databases are rejected.
func AssertSameDB(ctx context.Context, db *sql.DB) error {
	if db == nil {
		return fmt.Errorf("payout.AssertSameDB: db is required")
	}
	rows, err := db.QueryContext(ctx, `PRAGMA database_list`)
	if err != nil {
		return fmt.Errorf("payout.AssertSameDB: PRAGMA database_list: %w", err)
	}
	defer rows.Close()
	var mainFile string
	databases := 0
	for rows.Next() {
		var seq int
		var name, file string
		if err := rows.Scan(&seq, &name, &file); err != nil {
			return fmt.Errorf("payout.AssertSameDB: scan database_list: %w", err)
		}
		databases++
		if name == "main" {
			mainFile = file
		}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("payout.AssertSameDB: iterate database_list: %w", err)
	}
	if databases != 1 {
		return fmt.Errorf("payout.AssertSameDB: expected exactly one open database, got %d — ATTACHed DBs are rejected per SPEC-016 §3.1", databases)
	}
	_ = mainFile // captured for log surface; not load-bearing here.
	// Assert that ledger_payout_ready (SPEC-005) and every
	// payout table appear under the same "main" schema.
	tables := append([]string{"ledger_payout_ready"}, payoutTables...)
	for _, table := range tables {
		var schema string
		err := db.QueryRowContext(ctx,
			`SELECT 'main' FROM main.sqlite_master WHERE type='table' AND name=?`, table,
		).Scan(&schema)
		if err == sql.ErrNoRows {
			return fmt.Errorf("payout.AssertSameDB: table %q is missing from main DB — SPEC-016 §3.1 pin violated", table)
		}
		if err != nil {
			return fmt.Errorf("payout.AssertSameDB: lookup %q: %w", table, err)
		}
	}
	return nil
}

// RequiredTriggers is the union of bootstrap-related triggers
// SPEC-016 §4.8a top-of-cycle assertion expects to be present
// (the SPEC-005 trg_lpr_terminal_status_guard is asserted
// separately at the §4.3 step 8 boundary).
var RequiredTriggers = []string{
	"trg_prs_bootstrap_one_way",
	"trg_pa_bootstrap_flip",
	"trg_pa_bootstrap_flip_insert",
	"trg_lpr_terminal_status_guard",
}

// AssertTriggersPresent verifies every RequiredTriggers entry
// exists in sqlite_master. SPEC-016 §4.8a requires this check
// at runner startup. The runner cycle and the §4.3 step 8 / §4.9
// `source='manual'` paths perform their own intra-transaction
// re-checks; this startup check is the first line of defense.
func AssertTriggersPresent(ctx context.Context, db *sql.DB) error {
	if db == nil {
		return fmt.Errorf("payout.AssertTriggersPresent: db is required")
	}
	for _, name := range RequiredTriggers {
		var got string
		err := db.QueryRowContext(ctx,
			`SELECT name FROM sqlite_master WHERE type='trigger' AND name=?`, name,
		).Scan(&got)
		if err == sql.ErrNoRows {
			return fmt.Errorf("payout.AssertTriggersPresent: trigger %q missing — SPEC-016 §4.8a invariant violated", name)
		}
		if err != nil {
			return fmt.Errorf("payout.AssertTriggersPresent: lookup %q: %w", name, err)
		}
	}
	return nil
}
