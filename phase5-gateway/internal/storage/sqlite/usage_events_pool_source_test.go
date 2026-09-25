package sqlite

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// v14 (#1690): a v13 database whose usage_events CHECK predates
// pool_operator_attested is rebuilt in place, keeps every row and column, and
// then accepts the new source.
func TestUsageEventsMigratesToPoolOperatorAttestedSource(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := store.InsertUsageEvent(ctx, storage.UsageEvent{
		RequestID: "req_old", AccountID: "acct_v13", WindowDate: "2026-09-24",
		PromptTokens: 1, CompletionTokens: 2, TotalTokens: 3,
		TokenSource: "coordinator_observed", Outcome: "spec022_verified", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("InsertUsageEvent: %v", err)
	}
	// Recreate the v13 shape: the CHECK without pool_operator_attested.
	v13 := strings.Replace(usageEventsTableDDL, ", 'pool_operator_attested'", "", 1)
	if v13 == usageEventsTableDDL {
		t.Fatal("fixture: v13 DDL substitution did not apply")
	}
	for _, stmt := range []string{
		`ALTER TABLE usage_events RENAME TO usage_events_new`,
		v13,
		`INSERT INTO usage_events SELECT * FROM usage_events_new`,
		`DROP TABLE usage_events_new`,
		usageEventsAuxiliaryDDL,
		`DELETE FROM schema_migrations WHERE version = 14`,
	} {
		if _, err := store.db.ExecContext(ctx, stmt); err != nil {
			t.Fatalf("v13 fixture %q: %v", stmt[:20], err)
		}
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	store, err = Open(ctx, path)
	if err != nil {
		t.Fatalf("Open (migrates to v14): %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if sqlText := readUsageEventsMaster(t, store)["usage_events"]; !strings.Contains(sqlText, "pool_operator_attested") {
		t.Fatalf("usage_events DDL missing pool_operator_attested: %s", sqlText)
	}
	var version int64
	if err := store.db.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_migrations`).Scan(&version); err != nil || version != 14 {
		t.Fatalf("schema version=%d err=%v, want 14", version, err)
	}
	if err := store.InsertUsageEvent(ctx, storage.UsageEvent{
		RequestID: "req_pool", AccountID: "acct_v13", WindowDate: "2026-09-24",
		PromptTokens: 4, CompletionTokens: 5, TotalTokens: 9,
		TokenSource: "pool_operator_attested", Outcome: "spec022_verified", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("InsertUsageEvent pool_operator_attested: %v", err)
	}
	var source string
	if err := store.db.QueryRowContext(ctx, `SELECT token_source FROM usage_events WHERE request_id = 'req_old'`).Scan(&source); err != nil && err != sql.ErrNoRows {
		t.Fatal(err)
	}
	if source != "coordinator_observed" {
		t.Fatalf("pre-migration row source=%q, want preserved coordinator_observed", source)
	}
	assertSQLFails(t, store, `UPDATE usage_events SET total_tokens = 99 WHERE request_id = 'req_pool'`)
}
