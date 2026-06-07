package audit

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestOpenStoreCreatesAuditLogSchema(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()

	rows, err := store.DB().QueryContext(context.Background(), `
SELECT name FROM sqlite_master
WHERE type IN ('table', 'index') AND name IN (
    'audit_log',
    'idx_audit_log_ts_utc',
    'idx_audit_log_provider_id',
    'idx_audit_log_event_type'
)`)
	if err != nil {
		t.Fatalf("query schema: %v", err)
	}
	defer rows.Close()
	seen := map[string]bool{}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatalf("scan schema: %v", err)
		}
		seen[name] = true
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("schema rows: %v", err)
	}
	for _, name := range []string{
		"audit_log",
		"idx_audit_log_ts_utc",
		"idx_audit_log_provider_id",
		"idx_audit_log_event_type",
	} {
		if !seen[name] {
			t.Fatalf("missing schema object %q; got %#v", name, seen)
		}
	}
}

func TestInsertAndReadBack(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	ts := time.Date(2026, 6, 7, 14, 23, 9, 123000000, time.UTC)
	payload := `{"event":"custom_event"}`

	if err := store.Insert(ctx, ts, "custom_event", "provider-a", payload); err != nil {
		t.Fatalf("insert: %v", err)
	}

	var gotTS, gotEventType, gotProviderID, gotPayload string
	if err := store.DB().QueryRowContext(ctx, `
SELECT ts_utc, event_type, provider_id, payload_json
FROM audit_log`).Scan(&gotTS, &gotEventType, &gotProviderID, &gotPayload); err != nil {
		t.Fatalf("read row: %v", err)
	}
	if gotTS != ts.Format(time.RFC3339Nano) || gotEventType != "custom_event" || gotProviderID != "provider-a" || gotPayload != payload {
		t.Fatalf("row = (%q, %q, %q, %q)", gotTS, gotEventType, gotProviderID, gotPayload)
	}
}

func TestInsertWithEmptyProviderIDStoresNull(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()

	if err := store.Insert(ctx, time.Now().UTC(), "global_event", "", `{"event":"global_event"}`); err != nil {
		t.Fatalf("insert: %v", err)
	}

	var providerID sql.NullString
	if err := store.DB().QueryRowContext(ctx, `SELECT provider_id FROM audit_log`).Scan(&providerID); err != nil {
		t.Fatalf("read provider_id: %v", err)
	}
	if providerID.Valid {
		t.Fatalf("provider_id valid=%v value=%q, want SQL NULL", providerID.Valid, providerID.String)
	}
}

func TestPruneBeforeRemovesOlderRows(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	now := time.Date(2026, 6, 7, 12, 0, 0, 0, time.UTC)
	for _, ts := range []time.Time{
		now.AddDate(0, 0, -2),
		now.AddDate(0, 0, -1),
		now,
	} {
		if err := store.Insert(ctx, ts, "event", "provider-a", `{"event":"event"}`); err != nil {
			t.Fatalf("insert %s: %v", ts, err)
		}
	}

	deleted, err := store.PruneBefore(ctx, now.AddDate(0, 0, -1).Add(time.Second))
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if deleted != 2 {
		t.Fatalf("deleted=%d want 2", deleted)
	}
	var remaining int
	if err := store.DB().QueryRowContext(ctx, `SELECT COUNT(*) FROM audit_log`).Scan(&remaining); err != nil {
		t.Fatalf("count: %v", err)
	}
	if remaining != 1 {
		t.Fatalf("remaining=%d want 1", remaining)
	}
}

func TestEmitterDoesNotPanicOnSQLiteFailure(t *testing.T) {
	store := openTestStore(t)
	if err := store.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	event := validSwapEvent()
	emitter := func(event pool.SwapEvent) {
		_ = store.EmitSwap(context.Background(), event)
	}

	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("emitter panicked: %v", r)
		}
	}()
	emitter(event)
}

func openTestStore(t *testing.T) *Store {
	t.Helper()
	store, err := OpenStore(t.TempDir() + "/coordinator.db")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	return store
}

func countAuditRows(t *testing.T, store *Store) int {
	t.Helper()
	var count int
	if err := store.DB().QueryRowContext(context.Background(), `SELECT COUNT(*) FROM audit_log`).Scan(&count); err != nil {
		t.Fatalf("count audit rows: %v", err)
	}
	return count
}

func assertErrorContains(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("error=%v, want substring %q", err, want)
	}
}
