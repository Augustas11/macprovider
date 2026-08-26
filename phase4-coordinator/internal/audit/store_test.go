package audit

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestDefaultDBPathReturnsSiblingAuditDB(t *testing.T) {
	if got, want := DefaultDBPath(filepath.Join("var", "lib", "macprovider", "coordinator.db")), filepath.Join("var", "lib", "macprovider", "coordinator-audit.db"); got != want {
		t.Fatalf("DefaultDBPath=%q want %q", got, want)
	}
	if got := DefaultDBPath("coordinator.db"); got != "coordinator-audit.db" {
		t.Fatalf("DefaultDBPath local=%q want coordinator-audit.db", got)
	}
}

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

func TestOpenStoreKeepsSQLiteAutocheckpointOwnerDefault(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()

	var got int
	if err := store.DB().QueryRowContext(context.Background(), `PRAGMA wal_autocheckpoint`).Scan(&got); err != nil {
		t.Fatalf("PRAGMA wal_autocheckpoint: %v", err)
	}
	if got == 0 {
		t.Fatal("audit store disabled wal_autocheckpoint without an explicit checkpoint owner")
	}
}

func TestOpenStoreWithManualWALCheckpointDisablesAutocheckpoint(t *testing.T) {
	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	var got int
	if err := store.DB().QueryRowContext(context.Background(), `PRAGMA wal_autocheckpoint`).Scan(&got); err != nil {
		t.Fatalf("PRAGMA wal_autocheckpoint: %v", err)
	}
	if got != 0 {
		t.Fatalf("wal_autocheckpoint=%d want 0", got)
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

func TestInsertSettlementReceiptOutboxIsIdempotent(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	ts := time.Date(2026, 6, 7, 14, 23, 9, 123000000, time.UTC)
	payload := `{"event":"one"}`

	inserted, err := store.InsertSettlementReceiptOutbox(ctx, ts, "settlement_receipt_verdict", "provider-a", payload, 42)
	if err != nil {
		t.Fatalf("first insert: %v", err)
	}
	if !inserted {
		t.Fatal("first insert inserted=false want true")
	}
	inserted, err = store.InsertSettlementReceiptOutbox(ctx, ts, "settlement_receipt_verdict", "provider-a", payload, 42)
	if err != nil {
		t.Fatalf("second insert: %v", err)
	}
	if inserted {
		t.Fatal("second insert inserted=true want false")
	}

	var count int
	var gotTS, gotPayload string
	if err := store.DB().QueryRowContext(ctx, `
SELECT COUNT(*), MIN(ts_utc), MIN(payload_json)
FROM audit_log
WHERE settlement_receipt_audit_outbox_id = 42`).Scan(&count, &gotTS, &gotPayload); err != nil {
		t.Fatal(err)
	}
	if count != 1 || gotTS != ts.Format(time.RFC3339Nano) || gotPayload != `{"event":"one"}` {
		t.Fatalf("row count/ts/payload = %d/%s/%s", count, gotTS, gotPayload)
	}
}

func TestInsertSettlementReceiptOutboxRefusesMismatchedDuplicate(t *testing.T) {
	tests := []struct {
		name      string
		ts        time.Time
		eventType string
		provider  string
		payload   string
	}{
		{
			name:      "timestamp",
			ts:        time.Date(2026, 6, 7, 15, 23, 9, 123000000, time.UTC),
			eventType: "settlement_receipt_verdict",
			provider:  "provider-a",
			payload:   `{"event":"one"}`,
		},
		{
			name:      "event type",
			ts:        time.Date(2026, 6, 7, 14, 23, 9, 123000000, time.UTC),
			eventType: "settlement_receipt_replayed",
			provider:  "provider-a",
			payload:   `{"event":"one"}`,
		},
		{
			name:      "provider",
			ts:        time.Date(2026, 6, 7, 14, 23, 9, 123000000, time.UTC),
			eventType: "settlement_receipt_verdict",
			provider:  "provider-b",
			payload:   `{"event":"one"}`,
		},
		{
			name:      "payload",
			ts:        time.Date(2026, 6, 7, 14, 23, 9, 123000000, time.UTC),
			eventType: "settlement_receipt_verdict",
			provider:  "provider-a",
			payload:   `{"event":"two"}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			store := openTestStore(t)
			defer store.Close()
			ctx := context.Background()
			originalTS := time.Date(2026, 6, 7, 14, 23, 9, 123000000, time.UTC)
			originalPayload := `{"event":"one"}`

			inserted, err := store.InsertSettlementReceiptOutbox(ctx, originalTS, "settlement_receipt_verdict", "provider-a", originalPayload, 42)
			if err != nil {
				t.Fatalf("first insert: %v", err)
			}
			if !inserted {
				t.Fatal("first insert inserted=false want true")
			}

			inserted, err = store.InsertSettlementReceiptOutbox(ctx, tt.ts, tt.eventType, tt.provider, tt.payload, 42)
			if err == nil {
				t.Fatal("mismatched duplicate err=nil want error")
			}
			if inserted {
				t.Fatal("mismatched duplicate inserted=true want false")
			}
			assertErrorContains(t, err, "already exists with different audit event")

			var count int
			var gotTS, gotEventType, gotProvider, gotPayload string
			if err := store.DB().QueryRowContext(ctx, `
SELECT COUNT(*), MIN(ts_utc), MIN(event_type), MIN(provider_id), MIN(payload_json)
FROM audit_log
WHERE settlement_receipt_audit_outbox_id = 42`).Scan(&count, &gotTS, &gotEventType, &gotProvider, &gotPayload); err != nil {
				t.Fatal(err)
			}
			if count != 1 || gotTS != originalTS.Format(time.RFC3339Nano) || gotEventType != "settlement_receipt_verdict" || gotProvider != "provider-a" || gotPayload != originalPayload {
				t.Fatalf("row count/ts/event/provider/payload = %d/%s/%s/%s/%s", count, gotTS, gotEventType, gotProvider, gotPayload)
			}
		})
	}
}

func TestOpenStoreMigratesLegacyAuditLogForSettlementReceiptOutboxID(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    provider_id TEXT,
    payload_json TEXT NOT NULL
);
INSERT INTO audit_log(ts_utc, event_type, provider_id, payload_json)
VALUES('2026-06-07T14:23:09Z', 'legacy', 'provider-a', '{}');`); err != nil {
		_ = db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	store, err := OpenStore(dbPath)
	if err != nil {
		t.Fatalf("OpenStore legacy schema: %v", err)
	}
	defer store.Close()

	if ok, err := store.columnExists(context.Background(), "audit_log", "settlement_receipt_audit_outbox_id"); err != nil || !ok {
		t.Fatalf("settlement_receipt_audit_outbox_id exists=%v err=%v", ok, err)
	}
	var indexCount int
	if err := store.DB().QueryRowContext(context.Background(), `
SELECT COUNT(*)
FROM sqlite_schema
WHERE type='index' AND name='idx_audit_log_settlement_receipt_outbox'`).Scan(&indexCount); err != nil {
		t.Fatal(err)
	}
	if indexCount != 1 {
		t.Fatalf("unique outbox index count=%d want 1", indexCount)
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

// TestPruneBeforeBoundaryIsStrictlyLess pins the exact-cutoff semantic of
// PruneBefore per SPEC-002 v1.3.5 §7.10 R-7.10.2 and the requestlog
// precedent: PruneBefore uses a strict `<` comparison, so a row stamped
// exactly at the cutoff MUST survive while a row stamped any amount older
// MUST be removed. A future regression flipping `<` to `<=` would let the
// at-cutoff row escape — this test catches that drift.
func TestPruneBeforeBoundaryIsStrictlyLess(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	cutoff := time.Date(2026, 6, 7, 12, 0, 0, 0, time.UTC)
	// Epsilon is 1 second because PruneBefore compares via SQLite
	// julianday() (float64 days). Sub-millisecond epsilons collapse
	// to the same Julian Date at float64 precision near ~2.46e6.
	// The strict-< vs <= semantic is still proven: "at" the cutoff
	// survives, "before" is removed.
	rows := []struct {
		label string
		ts    time.Time
	}{
		{"before", cutoff.Add(-time.Second)},
		{"at", cutoff},
		{"after", cutoff.Add(time.Second)},
	}
	for _, r := range rows {
		if err := store.Insert(ctx, r.ts, "event", r.label, `{"event":"event"}`); err != nil {
			t.Fatalf("insert %s: %v", r.label, err)
		}
	}

	deleted, err := store.PruneBefore(ctx, cutoff)
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("deleted=%d want 1 (only the strictly-before row)", deleted)
	}

	rowsAfter, err := store.DB().QueryContext(ctx, `SELECT provider_id FROM audit_log ORDER BY ts_utc ASC`)
	if err != nil {
		t.Fatalf("select: %v", err)
	}
	defer rowsAfter.Close()
	var labels []string
	for rowsAfter.Next() {
		var label string
		if err := rowsAfter.Scan(&label); err != nil {
			t.Fatalf("scan: %v", err)
		}
		labels = append(labels, label)
	}
	if len(labels) != 2 || labels[0] != "at" || labels[1] != "after" {
		t.Fatalf("remaining provider_id order = %v, want [at after] — exact-cutoff row MUST survive", labels)
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

// TestPruneBeforeBatchedDeletesCrossesBatchBoundary inserts 12,000 audit
// rows across the cutoff (well above the 500-row pruneBatchSize) and
// asserts the batched DELETE loop drains everything strictly older while
// leaving the at/after rows intact. Regression guard for M3-1 / PERF-3.
func TestPruneBeforeBatchedDeletesCrossesBatchBoundary(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	cutoff := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	const each = 6000
	for i := 0; i < each; i++ {
		ts := cutoff.Add(-time.Duration(i+1) * time.Second)
		if err := store.Insert(ctx, ts, "event", "p", `{"event":"event"}`); err != nil {
			t.Fatalf("insert old %d: %v", i, err)
		}
	}
	for i := 0; i < each; i++ {
		ts := cutoff.Add(time.Duration(i) * time.Second)
		if err := store.Insert(ctx, ts, "event", "p", `{"event":"event"}`); err != nil {
			t.Fatalf("insert new %d: %v", i, err)
		}
	}

	deleted, err := store.PruneBefore(ctx, cutoff)
	if err != nil {
		t.Fatalf("PruneBefore: %v", err)
	}
	if deleted != each {
		t.Fatalf("deleted=%d want %d", deleted, each)
	}
	if got := countAuditRows(t, store); got != each {
		t.Fatalf("remaining=%d want %d", got, each)
	}
}

// TestPruneBeforeNoSQLiteBusyUnderConcurrentInsert proves the batched
// DELETE keeps the write lock short enough for a concurrent inserter
// (covered by busy_timeout) under contention. Regression guard for M3-1.
func TestPruneBeforeNoSQLiteBusyUnderConcurrentInsert(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	cutoff := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	const old = 8000
	for i := 0; i < old; i++ {
		ts := cutoff.Add(-time.Duration(i+1) * time.Second)
		if err := store.Insert(ctx, ts, "event", "p", `{"event":"event"}`); err != nil {
			t.Fatalf("seed %d: %v", i, err)
		}
	}

	stop := make(chan struct{})
	writerErr := make(chan error, 1)
	go func() {
		base := cutoff.Add(time.Hour)
		for i := 0; ; i++ {
			select {
			case <-stop:
				writerErr <- nil
				return
			default:
			}
			ts := base.Add(time.Duration(i) * time.Millisecond)
			if err := store.Insert(ctx, ts, "event", "w", `{"event":"event"}`); err != nil {
				writerErr <- err
				return
			}
		}
	}()

	if _, err := store.PruneBefore(ctx, cutoff); err != nil {
		close(stop)
		<-writerErr
		if strings.Contains(err.Error(), "SQLITE_BUSY") || strings.Contains(err.Error(), "database is locked") {
			t.Fatalf("PruneBefore hit lock contention: %v", err)
		}
		t.Fatalf("PruneBefore: %v", err)
	}
	close(stop)
	if err := <-writerErr; err != nil {
		if strings.Contains(err.Error(), "SQLITE_BUSY") || strings.Contains(err.Error(), "database is locked") {
			t.Fatalf("concurrent writer hit lock contention: %v", err)
		}
		t.Fatalf("concurrent writer: %v", err)
	}
}

// TestPruneBeforeUsesTsUtcIndex pins the DELETE's plan to
// idx_audit_log_ts_utc via EXPLAIN QUERY PLAN. A planner regression
// (index dropped or WHERE clause rewritten in a non-sargable way) would
// surface here as a SCAN audit_log.
func TestPruneBeforeUsesTsUtcIndex(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	rows, err := store.DB().QueryContext(ctx,
		`EXPLAIN QUERY PLAN DELETE FROM audit_log WHERE rowid IN (SELECT rowid FROM audit_log WHERE julianday(ts_utc) < julianday(?) LIMIT ?)`,
		time.Now().UTC().Format(time.RFC3339Nano), pruneBatchSize)
	if err != nil {
		t.Fatalf("explain: %v", err)
	}
	defer rows.Close()
	var combined strings.Builder
	for rows.Next() {
		var id, parent, notUsed int
		var detail string
		if err := rows.Scan(&id, &parent, &notUsed, &detail); err != nil {
			t.Fatalf("scan plan: %v", err)
		}
		combined.WriteString(detail)
		combined.WriteString("\n")
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("plan rows: %v", err)
	}
	plan := combined.String()
	if !strings.Contains(plan, "idx_audit_log_ts_utc") {
		t.Fatalf("plan does not reference idx_audit_log_ts_utc; full plan:\n%s", plan)
	}
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
