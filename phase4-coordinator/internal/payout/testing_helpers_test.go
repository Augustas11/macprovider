package payout

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "modernc.org/sqlite"
)

// openTestDB opens a per-test SQLite database in t.TempDir
// using the shared project DSN (synchronous=FULL after the
// SPEC-016 §3.1 change). It pre-creates the SPEC-005-shipped
// ledger_payout_ready table — the SPEC-016 same-DB pin
// assertion requires that table to exist; we replicate the
// minimum schema here so unit tests don't drag the full
// billing.Store dependency.
//
// The returned *sql.DB is registered with t.Cleanup.
func openTestDB(t *testing.T) *sql.DB {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(path))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	// Minimum SPEC-005 schema slice — only what SPEC-016
	// AssertSameDB and §4.5 / §4.7 FK references touch.
	if _, err := db.ExecContext(context.Background(), `
CREATE TABLE IF NOT EXISTS ledger_payout_ready (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider_id TEXT NOT NULL,
    window_start_utc TEXT NOT NULL,
    window_end_utc TEXT NOT NULL,
    cadence_days INTEGER NOT NULL CHECK(cadence_days > 0),
    source_credit_count INTEGER NOT NULL CHECK(source_credit_count > 0),
    gross_credits INTEGER NOT NULL CHECK(gross_credits >= 0),
    provider_credits INTEGER NOT NULL CHECK(provider_credits >= 0),
    operator_credits INTEGER NOT NULL CHECK(operator_credits >= 0),
    min_payout_credits INTEGER NOT NULL CHECK(min_payout_credits >= 0),
    payout_currency TEXT NULL,
    payout_external_id TEXT NULL,
    status TEXT NOT NULL DEFAULT 'ready' CHECK(status IN ('ready','consumed','voided')),
    idempotency_key TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    UNIQUE(provider_id, window_start_utc, window_end_utc),
    UNIQUE(idempotency_key)
);
CREATE TRIGGER IF NOT EXISTS trg_lpr_terminal_status_guard
BEFORE UPDATE OF status ON ledger_payout_ready
WHEN OLD.status IN ('consumed','voided') AND NEW.status != OLD.status
BEGIN
    SELECT RAISE(ABORT, 'ledger_payout_ready status is terminal');
END;
`); err != nil {
		t.Fatalf("seed ledger_payout_ready: %v", err)
	}
	if err := Migrate(context.Background(), db); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return db
}

func insertReadyRow(t *testing.T, db *sql.DB, providerID, idempotency string) int64 {
	t.Helper()
	res, err := db.ExecContext(context.Background(), `
INSERT INTO ledger_payout_ready
  (provider_id, window_start_utc, window_end_utc, cadence_days,
   source_credit_count, gross_credits, provider_credits,
   operator_credits, min_payout_credits, idempotency_key, created_at_utc)
VALUES (?, '2026-01-01T00:00:00Z', '2026-01-08T00:00:00Z', 7,
        1, 1000000, 900000, 100000, 500000, ?, '2026-01-08T00:00:00Z')`,
		providerID, idempotency,
	)
	if err != nil {
		t.Fatalf("insert ready row: %v", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("last insert id: %v", err)
	}
	return id
}

// insertPayoutAddress seeds a payout-allowed provider_payout_addresses
// row for providerID registered against hotWallet, so a ready payout can
// actually be SELECTed by §4.3 step 1 (SelectReadyPayouts INNER JOINs
// provider_payout_addresses on registered_against_hot_wallet) and PROCEED
// to allocate/broadcast when a cycle is meant to continue. Without this
// row the join returns nothing, so a "proceed" cycle would silently
// process zero rows and a test could not tell a real proceed apart from a
// halt. Mirrors the happy-path seeding in runner_test.go.
func insertPayoutAddress(t *testing.T, db *sql.DB, providerID, hotWallet string) {
	t.Helper()
	canonicalHot, err := CanonicalizeEIP55(hotWallet)
	if err != nil {
		t.Fatalf("canonicalize hot wallet: %v", err)
	}
	past := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339Nano)
	providerAddr := "0x000000000000000000000000000000000000dEaD"
	if _, err := db.ExecContext(context.Background(), `
INSERT INTO provider_payout_addresses
  (provider_id, chain, address, payout_allowed, pending_until_utc,
   rotated_from, registered_at_utc, registered_against_hot_wallet)
VALUES (?, 'base-mainnet', ?, 1, ?, NULL, ?, ?)`,
		providerID, providerAddr, past, past, canonicalHot); err != nil {
		t.Fatalf("insert payout address: %v", err)
	}
}
