package sqlite

import (
	"context"
	"path/filepath"
	"testing"
)

// A schema-14 gateway (Pearl through v1.8.200) has settlement_reconcile_attempts
// with only its four original columns. Opening it with the schema-15 binary
// must add the backlog columns and index instead of failing on the index
// ("no such column: operator_review"), which crash-looped the v1.8.205 gateway.
func TestOpenUpgradesSchema14SettlementReconcileAttempts(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("first Open: %v", err)
	}
	for _, stmt := range []string{
		`DROP INDEX IF EXISTS idx_settlement_reconcile_next_attempt`,
		`DROP TABLE settlement_reconcile_attempts`,
		`CREATE TABLE settlement_reconcile_attempts (
			attempt_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
			account_id TEXT NOT NULL,
			request_id TEXT NOT NULL,
			reservation_created_at TEXT NOT NULL,
			UNIQUE (account_id, request_id),
			FOREIGN KEY (account_id, request_id) REFERENCES quota_reservations(account_id, request_id) ON DELETE CASCADE
		)`,
		`DELETE FROM schema_migrations WHERE version >= 15`,
	} {
		if _, err := store.db.ExecContext(ctx, stmt); err != nil {
			t.Fatalf("downgrade to schema 14 (%s): %v", stmt, err)
		}
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	store, err = Open(ctx, path)
	if err != nil {
		t.Fatalf("Open schema-14 database: %v", err)
	}
	defer store.Close()
	for _, column := range []string{"attempt_count", "next_attempt_after", "operator_review", "operator_review_reason"} {
		var n int
		if err := store.db.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM pragma_table_info('settlement_reconcile_attempts') WHERE name = ?`, column).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 1 {
			t.Fatalf("column %s missing after upgrade", column)
		}
	}
	var indexes int
	if err := store.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_settlement_reconcile_next_attempt'`).Scan(&indexes); err != nil {
		t.Fatal(err)
	}
	if indexes != 1 {
		t.Fatalf("idx_settlement_reconcile_next_attempt count=%d want 1", indexes)
	}
	var version int
	if err := store.db.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_migrations`).Scan(&version); err != nil {
		t.Fatal(err)
	}
	if version < 15 {
		t.Fatalf("schema version=%d want >= 15", version)
	}
}
