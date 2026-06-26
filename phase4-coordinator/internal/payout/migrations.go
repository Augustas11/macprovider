package payout

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"regexp"
	"sort"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/payout/migrations"
)

// addColumnStmt matches a single SQLite ALTER TABLE ADD COLUMN
// statement (any whitespace, optional column-constraint trail).
// Captures: 1=table, 2=column. Closes FULL-r1 [full-code:r1-4]
// MEDIUM: bare ADD COLUMN is non-idempotent on SQLite (rerun
// fails "duplicate column"); if the process crashes after the
// ALTER but before payout_schema_applied gets the marker, the
// next boot would fail on the same file. The migration runner
// now pre-checks PRAGMA table_info and skips ADD COLUMN if the
// column already exists.
var addColumnStmt = regexp.MustCompile(`(?is)\bALTER\s+TABLE\s+([A-Za-z_][A-Za-z0-9_]*)\s+ADD\s+COLUMN\s+([A-Za-z_][A-Za-z0-9_]*)\b`)

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
		// FULL-r1 [full-code:r1-4] MEDIUM closure: rewrite any
		// non-idempotent ADD COLUMN into an idempotent NO-OP if
		// the column already exists. Covers the crash-window where
		// a prior boot executed the ALTER but died before recording
		// the applied marker — the next boot must NOT fail with
		// "duplicate column". Each ADD COLUMN site is checked
		// independently; non-matching SQL passes through unchanged.
		stmt, err := stripExistingColumnAlters(ctx, db, string(body))
		if err != nil {
			return fmt.Errorf("payout.Migrate: prepare %s: %w", name, err)
		}
		if _, err := db.ExecContext(ctx, stmt); err != nil {
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

// stripExistingColumnAlters scans body for ALTER TABLE ADD COLUMN
// statements and, for each (table, column) pair whose column
// already exists per PRAGMA table_info, replaces the entire
// statement with a SQL comment so the runner can execute the
// remainder idempotently. Closes FULL-r1 [full-code:r1-4] MEDIUM.
//
// SQLite has no ALTER TABLE ... ADD COLUMN IF NOT EXISTS form, so
// the SPEC-016 migrations 0010 + 0012 historically ran a bare
// ALTER. A crash between the ALTER and the payout_schema_applied
// INSERT would leave the schema with the column but no marker;
// the next boot would re-execute the file and fail "duplicate
// column". This helper makes those statements rerun-safe by
// detecting the prior application and dropping them.
//
// Non-ALTER statements pass through unchanged. The function is
// conservative: it operates only on whole-statement matches and
// preserves byte layout outside those matches, so newly authored
// migrations are unaffected.
//
// FULL-r2 [full-sec:r2-1] MEDIUM closure: ignore -- line comments
// and single/double-quoted string literals when locating ALTER
// statements. A future migration that ships a commented or
// quoted "ALTER TABLE x ADD COLUMN y ..." form would otherwise
// trigger a spurious PRAGMA lookup and a rewrite that corrupts
// the migration body. Trust boundary is "embedded authored asset",
// but the parser robustness gap is worth closing.
func stripExistingColumnAlters(ctx context.Context, db *sql.DB, body string) (string, error) {
	matches := addColumnStmt.FindAllStringSubmatchIndex(body, -1)
	if len(matches) == 0 {
		return body, nil
	}
	skipMask := buildExecutableMask(body)
	var b strings.Builder
	prev := 0
	for _, m := range matches {
		start, end := m[0], m[1]
		// Skip matches that begin inside a comment or string literal —
		// the executable mask is true only at byte positions that
		// belong to top-level executable SQL.
		if !skipMask[start] {
			continue
		}
		tableStart, tableEnd := m[2], m[3]
		colStart, colEnd := m[4], m[5]
		table := body[tableStart:tableEnd]
		column := body[colStart:colEnd]
		exists, err := columnExists(ctx, db, table, column)
		if err != nil {
			return "", err
		}
		if !exists {
			continue
		}
		// Extend the match to the trailing semicolon so the
		// rewritten comment covers the whole statement (the
		// regex already matched up through the column name; the
		// remainder of the statement — type, constraints,
		// terminator — sits between end and the next `;`).
		stmtEnd := end
		for stmtEnd < len(body) && body[stmtEnd] != ';' {
			stmtEnd++
		}
		if stmtEnd < len(body) {
			stmtEnd++ // include the semicolon
		}
		b.WriteString(body[prev:start])
		fmt.Fprintf(&b, "-- payout.Migrate: ADD COLUMN %s.%s already present, statement skipped (rerun-safe)", table, column)
		prev = stmtEnd
	}
	b.WriteString(body[prev:])
	return b.String(), nil
}

// buildExecutableMask returns a per-byte mask the same length as
// body. Each entry is true when the byte at that index is part of
// executable top-level SQL — i.e. NOT inside a `-- line comment`
// and NOT inside a `' ... '` or `" ... "` string literal. The
// caller uses the mask to filter regex matches that happen to
// land inside ignorable text.
//
// SQLite's string-literal rules: single-quote escapes the next
// single quote via doubling (`”`); double-quote works the same
// way for identifiers. The mask is conservative: any byte that
// could plausibly be in literal/comment context is marked false.
func buildExecutableMask(body string) []bool {
	mask := make([]bool, len(body))
	inSingle := false
	inDouble := false
	inLineComment := false
	for i := 0; i < len(body); i++ {
		ch := body[i]
		var next byte
		if i+1 < len(body) {
			next = body[i+1]
		}
		if inLineComment {
			if ch == '\n' {
				inLineComment = false
				mask[i] = true
				continue
			}
			continue
		}
		if !inSingle && !inDouble && ch == '-' && next == '-' {
			// Start of a line comment.
			inLineComment = true
			continue
		}
		if !inDouble && ch == '\'' {
			inSingle = !inSingle
			continue
		}
		if !inSingle && ch == '"' {
			inDouble = !inDouble
			continue
		}
		if !inSingle && !inDouble {
			mask[i] = true
		}
	}
	return mask
}

// columnExists returns true when PRAGMA table_info(<table>) lists
// the named column. Safe against missing tables (returns false +
// no error).
func columnExists(ctx context.Context, db *sql.DB, table, column string) (bool, error) {
	rows, err := db.QueryContext(ctx, fmt.Sprintf(`PRAGMA table_info(%q)`, table))
	if err != nil {
		return false, fmt.Errorf("PRAGMA table_info(%s): %w", table, err)
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, ctype string
		var notnull, pk int
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			return false, fmt.Errorf("scan table_info(%s): %w", table, err)
		}
		if name == column {
			return true, nil
		}
	}
	return false, rows.Err()
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
