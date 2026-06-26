package requestlog

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRequestLogInsertAndRead(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	ts := time.Date(2026, 5, 31, 12, 34, 56, 789, time.UTC)
	promptTokens := int64(11)
	completionTokens := int64(7)

	if err := store.Insert(ctx, Row{
		TSUtc:              ts,
		RequestID:          "req-roundtrip",
		Model:              "model-a",
		ProviderAssignedID: "session-1",
		PromptTokens:       &promptTokens,
		CompletionTokens:   &completionTokens,
		LatencyMs:          123.5,
		RoutingMs:          4.5,
		Status:             200,
		Stream:             true,
		BuyerIP:            "203.0.113.1:41234",
		Error:              "provider said no",
		ErrorCode:          "error_internal",
		PrefHeader:         "fastest",
		ProviderHeader:     "p1",
		Retried:            2,
	}); err != nil {
		t.Fatalf("insert: %v", err)
	}

	var got struct {
		ID                 int64
		TSUtc              string
		RequestID          string
		Model              string
		ProviderAssignedID sql.NullString
		PromptTokens       sql.NullInt64
		CompletionTokens   sql.NullInt64
		TotalTokens        sql.NullInt64
		LatencyMs          float64
		RoutingMs          float64
		Status             int
		Stream             int
		BuyerIP            string
		Error              sql.NullString
		ErrorCode          sql.NullString
		PrefHeader         sql.NullString
		ProviderHeader     sql.NullString
		Retried            int
	}
	err := store.db.QueryRowContext(ctx, `
SELECT id, ts_utc, request_id, model, provider_assigned_id,
       prompt_tokens, completion_tokens, total_tokens, latency_ms,
       routing_ms, status, stream, buyer_ip, error, error_code,
       pref_header, provider_header, retried
FROM request_log
WHERE request_id = ?`, "req-roundtrip").Scan(
		&got.ID,
		&got.TSUtc,
		&got.RequestID,
		&got.Model,
		&got.ProviderAssignedID,
		&got.PromptTokens,
		&got.CompletionTokens,
		&got.TotalTokens,
		&got.LatencyMs,
		&got.RoutingMs,
		&got.Status,
		&got.Stream,
		&got.BuyerIP,
		&got.Error,
		&got.ErrorCode,
		&got.PrefHeader,
		&got.ProviderHeader,
		&got.Retried,
	)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if got.ID <= 0 ||
		got.TSUtc != ts.Format(time.RFC3339Nano) ||
		got.RequestID != "req-roundtrip" ||
		got.Model != "model-a" ||
		got.ProviderAssignedID.String != "session-1" || !got.ProviderAssignedID.Valid ||
		got.PromptTokens.Int64 != 11 || !got.PromptTokens.Valid ||
		got.CompletionTokens.Int64 != 7 || !got.CompletionTokens.Valid ||
		got.TotalTokens.Int64 != 18 || !got.TotalTokens.Valid ||
		got.LatencyMs != 123.5 ||
		got.RoutingMs != 4.5 ||
		got.Status != 200 ||
		got.Stream != 1 ||
		got.BuyerIP != "203.0.113.1:41234" ||
		got.Error.String != "provider said no" || !got.Error.Valid ||
		got.ErrorCode.String != "error_internal" || !got.ErrorCode.Valid ||
		got.PrefHeader.String != "fastest" || !got.PrefHeader.Valid ||
		got.ProviderHeader.String != "p1" || !got.ProviderHeader.Valid ||
		got.Retried != 2 {
		t.Fatalf("row mismatch: %#v", got)
	}
}

func TestRequestLogTotalTokensOverflowStoresNull(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	promptTokens := int64(math.MaxInt64)
	completionTokens := int64(1)

	if err := store.Insert(ctx, Row{
		TSUtc:              time.Now().UTC(),
		RequestID:          "req-overflow",
		Model:              "model-a",
		ProviderAssignedID: "session-1",
		PromptTokens:       &promptTokens,
		CompletionTokens:   &completionTokens,
		Status:             200,
		BuyerIP:            "203.0.113.1:41234",
	}); err != nil {
		t.Fatalf("insert overflow row: %v", err)
	}

	var totalTokens sql.NullInt64
	if err := store.db.QueryRowContext(ctx, `SELECT total_tokens FROM request_log WHERE request_id = ?`, "req-overflow").Scan(&totalTokens); err != nil {
		t.Fatalf("query total_tokens: %v", err)
	}
	if totalTokens.Valid {
		t.Fatalf("total_tokens = %#v, want NULL on overflow", totalTokens)
	}
}

func TestRequestLogMultiAttemptRows(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()

	if err := store.Insert(ctx, Row{TSUtc: time.Now().UTC(), RequestID: "req-retry", Model: "model-a", ProviderAssignedID: "session-1", Status: 502, BuyerIP: "127.0.0.1:1"}); err != nil {
		t.Fatalf("first insert: %v", err)
	}
	if err := store.Insert(ctx, Row{TSUtc: time.Now().UTC(), RequestID: "req-retry", Model: "model-a", ProviderAssignedID: "session-2", Status: 200, BuyerIP: "127.0.0.1:1"}); err != nil {
		t.Fatalf("second insert: %v", err)
	}

	rows, err := store.db.QueryContext(ctx, `SELECT id, request_id, provider_assigned_id FROM request_log WHERE request_id = ? ORDER BY id ASC`, "req-retry")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer rows.Close()
	var got []struct {
		ID                 int64
		RequestID          string
		ProviderAssignedID string
	}
	for rows.Next() {
		var row struct {
			ID                 int64
			RequestID          string
			ProviderAssignedID string
		}
		if err := rows.Scan(&row.ID, &row.RequestID, &row.ProviderAssignedID); err != nil {
			t.Fatalf("scan: %v", err)
		}
		got = append(got, row)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("rows: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("rows = %d, want 2: %#v", len(got), got)
	}
	if got[0].RequestID != "req-retry" || got[1].RequestID != "req-retry" {
		t.Fatalf("request_id mismatch: %#v", got)
	}
	if got[0].ID >= got[1].ID {
		t.Fatalf("ids not increasing: %#v", got)
	}
	if got[0].ProviderAssignedID == got[1].ProviderAssignedID {
		t.Fatalf("provider_assigned_id did not differ: %#v", got)
	}
}

func TestRequestLogPruneBeforeDeletesOldRowsOnly(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	cutoff := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	rows := []Row{
		{TSUtc: cutoff.Add(-time.Second), RequestID: "req-old", Model: "model-a", Status: 200, BuyerIP: "203.0.113.10"},
		{TSUtc: cutoff, RequestID: "req-cutoff", Model: "model-a", Status: 200, BuyerIP: "203.0.113.11"},
		{TSUtc: cutoff.Add(time.Second), RequestID: "req-new", Model: "model-a", Status: 200, BuyerIP: "203.0.113.12"},
	}
	for _, row := range rows {
		if err := store.Insert(ctx, row); err != nil {
			t.Fatalf("insert %s: %v", row.RequestID, err)
		}
	}

	deleted, err := store.PruneBefore(ctx, cutoff)
	if err != nil {
		t.Fatalf("PruneBefore: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("deleted=%d want 1", deleted)
	}
	var remaining []string
	dbRows, err := store.db.QueryContext(ctx, `SELECT request_id FROM request_log ORDER BY request_id`)
	if err != nil {
		t.Fatalf("query remaining: %v", err)
	}
	defer dbRows.Close()
	for dbRows.Next() {
		var id string
		if err := dbRows.Scan(&id); err != nil {
			t.Fatalf("scan remaining: %v", err)
		}
		remaining = append(remaining, id)
	}
	if err := dbRows.Err(); err != nil {
		t.Fatalf("remaining rows: %v", err)
	}
	if len(remaining) != 2 || remaining[0] != "req-cutoff" || remaining[1] != "req-new" {
		t.Fatalf("remaining=%v want [req-cutoff req-new]", remaining)
	}
}

func TestReserveIdempotencyKeyDetectsReplayConflictAndPrunes(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	old := time.Date(2026, 5, 31, 0, 0, 0, 0, time.UTC)
	cutoff := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)

	requestID, replay, err := store.ReserveIdempotencyKey(ctx, "idem-old", "hash-a", "req-a", old)
	if err != nil {
		t.Fatalf("ReserveIdempotencyKey first: %v", err)
	}
	if replay || requestID != "req-a" {
		t.Fatalf("first reserve requestID=%q replay=%v", requestID, replay)
	}
	requestID, replay, err = store.ReserveIdempotencyKey(ctx, "idem-old", "hash-a", "req-b", cutoff)
	if err != nil {
		t.Fatalf("ReserveIdempotencyKey replay: %v", err)
	}
	if !replay || requestID != "req-a" {
		t.Fatalf("replay requestID=%q replay=%v", requestID, replay)
	}
	if _, _, err := store.ReserveIdempotencyKey(ctx, "idem-old", "hash-b", "req-c", cutoff); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("mismatch err=%v want ErrIdempotencyConflict", err)
	}
	if _, _, err := store.ReserveIdempotencyKey(ctx, "idem-new", "hash-n", "req-n", cutoff.Add(time.Second)); err != nil {
		t.Fatalf("ReserveIdempotencyKey new: %v", err)
	}
	if _, err := store.PruneBefore(ctx, cutoff); err != nil {
		t.Fatalf("PruneBefore: %v", err)
	}
	var count int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM request_idempotency_keys WHERE idempotency_key = 'idem-old'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("old idempotency keys=%d want 0", count)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM request_idempotency_keys WHERE idempotency_key = 'idem-new'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("new idempotency keys=%d want 1", count)
	}
}

func TestOpenStoreAppliesSQLitePragmasViaDSN(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	for _, tc := range []struct {
		query string
		want  int
	}{
		{query: `PRAGMA busy_timeout`, want: 5000},
		{query: `PRAGMA foreign_keys`, want: 1},
	} {
		var got int
		if err := store.db.QueryRowContext(ctx, tc.query).Scan(&got); err != nil {
			t.Fatalf("%s: %v", tc.query, err)
		}
		if got != tc.want {
			t.Fatalf("%s=%d want %d", tc.query, got, tc.want)
		}
	}
}

func TestRequestLogErrorCodePopulation(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()

	if err := store.Insert(ctx, Row{
		TSUtc:              time.Now().UTC(),
		RequestID:          "req-error",
		Model:              "model-a",
		ProviderAssignedID: "session-1",
		Status:             502,
		BuyerIP:            "127.0.0.1:1",
		ErrorCode:          "error_model_not_loaded",
	}); err != nil {
		t.Fatalf("error insert: %v", err)
	}
	if err := store.Insert(ctx, Row{
		TSUtc:              time.Now().UTC(),
		RequestID:          "req-success",
		Model:              "model-a",
		ProviderAssignedID: "session-1",
		Status:             200,
		BuyerIP:            "127.0.0.1:1",
		ErrorCode:          "",
	}); err != nil {
		t.Fatalf("success insert: %v", err)
	}

	var errorCode sql.NullString
	var errorPromptTokens sql.NullInt64
	if err := store.db.QueryRowContext(ctx, `SELECT error_code, prompt_tokens FROM request_log WHERE request_id = ?`, "req-error").Scan(&errorCode, &errorPromptTokens); err != nil {
		t.Fatalf("query error row: %v", err)
	}
	if !errorCode.Valid || errorCode.String != "error_model_not_loaded" {
		t.Fatalf("error_code = %#v, want error_model_not_loaded", errorCode)
	}
	if errorPromptTokens.Valid {
		t.Fatalf("prompt_tokens = %#v, want NULL", errorPromptTokens)
	}

	var successErrorCode sql.NullString
	var successPromptTokens sql.NullInt64
	if err := store.db.QueryRowContext(ctx, `SELECT error_code, prompt_tokens FROM request_log WHERE request_id = ?`, "req-success").Scan(&successErrorCode, &successPromptTokens); err != nil {
		t.Fatalf("query success row: %v", err)
	}
	if successErrorCode.Valid {
		t.Fatalf("success error_code = %#v, want NULL", successErrorCode)
	}
	if successPromptTokens.Valid {
		t.Fatalf("success prompt_tokens = %#v, want NULL", successPromptTokens)
	}
}

func TestRequestLogMigratesExistingTable(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	_, err = db.Exec(`
CREATE TABLE request_log (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc               TEXT    NOT NULL,
    request_id           TEXT    NOT NULL,
    model                TEXT    NOT NULL,
    provider_assigned_id TEXT    NULL,
    prompt_tokens        INTEGER NULL,
    completion_tokens    INTEGER NULL,
    total_tokens         INTEGER NULL,
    latency_ms           REAL    NOT NULL,
    routing_ms           REAL    NOT NULL,
    status               INTEGER NOT NULL,
    stream               INTEGER NOT NULL,
    buyer_ip             TEXT    NOT NULL DEFAULT '',
    error                TEXT    NULL,
    pref_header          TEXT    NULL,
    provider_header      TEXT    NULL,
    retried              INTEGER NOT NULL DEFAULT 0
)`)
	if err != nil {
		t.Fatalf("seed old schema: %v", err)
	}
	_ = db.Close()

	store, err := OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open migrated store: %v", err)
	}
	defer store.Close()
	if err := store.Insert(context.Background(), Row{
		TSUtc:              time.Now().UTC(),
		RequestID:          "req-migrated",
		Model:              "model-a",
		ProviderAssignedID: "session-1",
		Status:             502,
		BuyerIP:            "127.0.0.1",
		ErrorCode:          "error_internal",
	}); err != nil {
		t.Fatalf("insert after migration: %v", err)
	}
	var errorCode sql.NullString
	if err := store.db.QueryRow(`SELECT error_code FROM request_log WHERE request_id = ?`, "req-migrated").Scan(&errorCode); err != nil {
		t.Fatalf("query migrated row: %v", err)
	}
	if !errorCode.Valid || errorCode.String != "error_internal" {
		t.Fatalf("error_code = %#v, want error_internal", errorCode)
	}
	for _, name := range []string{"idx_request_log_ts_utc", "idx_request_log_request_id_id"} {
		var got string
		if err := store.db.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?`, name).Scan(&got); err != nil {
			t.Fatalf("index %s missing: %v", name, err)
		}
	}
}

func TestRequestLogInsertTx(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	tx, err := store.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin tx: %v", err)
	}
	if err := store.InsertTx(ctx, tx, Row{
		TSUtc:              time.Now().UTC(),
		RequestID:          "req-tx",
		Model:              "model-a",
		ProviderAssignedID: "session-1",
		Status:             200,
		BuyerIP:            "127.0.0.1",
	}); err != nil {
		_ = tx.Rollback()
		t.Fatalf("insert tx: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit tx: %v", err)
	}
	var count int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM request_log WHERE request_id = ?`, "req-tx").Scan(&count); err != nil {
		t.Fatalf("query tx row: %v", err)
	}
	if count != 1 {
		t.Fatalf("tx row count = %d, want 1", count)
	}
}

// TestPruneBeforeBatchedDeletesCrossesBatchBoundary inserts 12,000 rows
// straddling the cutoff (well above the 5,000-row pruneBatchSize) and
// asserts that the batched DELETE loop deletes everything strictly older
// than the cutoff and leaves everything at-or-after the cutoff intact.
// Regression guard for M3-1 / PERF-3: a single un-LIMIT-ed DELETE would
// hold the write lock for too long; a buggy loop would either stop early
// (leaving stale rows) or delete too much.
func TestPruneBeforeBatchedDeletesCrossesBatchBoundary(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	cutoff := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	const each = 6000
	for i := 0; i < each; i++ {
		ts := cutoff.Add(-time.Duration(i+1) * time.Second)
		if err := store.Insert(ctx, Row{TSUtc: ts, RequestID: "old", Model: "m", Status: 200, BuyerIP: "1"}); err != nil {
			t.Fatalf("insert old %d: %v", i, err)
		}
	}
	for i := 0; i < each; i++ {
		ts := cutoff.Add(time.Duration(i) * time.Second)
		if err := store.Insert(ctx, Row{TSUtc: ts, RequestID: "new", Model: "m", Status: 200, BuyerIP: "1"}); err != nil {
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
	var remaining int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM request_log`).Scan(&remaining); err != nil {
		t.Fatalf("count remaining: %v", err)
	}
	if remaining != each {
		t.Fatalf("remaining=%d want %d", remaining, each)
	}
	var olderLeft int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM request_log WHERE julianday(ts_utc) < julianday(?)`, cutoff.UTC().Format(time.RFC3339Nano)).Scan(&olderLeft); err != nil {
		t.Fatalf("count older: %v", err)
	}
	if olderLeft != 0 {
		t.Fatalf("rows older than cutoff still present: %d", olderLeft)
	}
}

// TestPruneBeforeNoSQLiteBusyUnderConcurrentInsert runs PruneBefore
// against a backlog while a writer goroutine inserts fresh rows. Both
// must complete without SQLITE_BUSY — the batched DELETE keeps the
// write lock short enough that the writer's busy_timeout absorbs each
// release. Regression guard for M3-1: a single multi-second DELETE
// would exceed busy_timeout under contention.
func TestPruneBeforeNoSQLiteBusyUnderConcurrentInsert(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	cutoff := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	const old = 8000
	for i := 0; i < old; i++ {
		ts := cutoff.Add(-time.Duration(i+1) * time.Second)
		if err := store.Insert(ctx, Row{TSUtc: ts, RequestID: "o", Model: "m", Status: 200, BuyerIP: "1"}); err != nil {
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
			if err := store.Insert(ctx, Row{TSUtc: ts, RequestID: "w", Model: "m", Status: 200, BuyerIP: "1"}); err != nil {
				if strings.Contains(err.Error(), "SQLITE_BUSY") || strings.Contains(err.Error(), "database is locked") {
					writerErr <- err
					return
				}
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
		t.Fatalf("concurrent writer: %v", err)
	}
}

// TestPruneBeforeUsesTsUtcIndex pins the DELETE's plan to the
// idx_request_log_ts_utc index via EXPLAIN QUERY PLAN. A regression that
// drops the index or rewrites the WHERE clause so the planner falls
// back to a SCAN of request_log would break this assertion.
func TestPruneBeforeUsesTsUtcIndex(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx := context.Background()
	rows, err := store.db.QueryContext(ctx,
		`EXPLAIN QUERY PLAN DELETE FROM request_log WHERE rowid IN (SELECT rowid FROM request_log WHERE julianday(ts_utc) < julianday(?) LIMIT ?)`,
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
	if !strings.Contains(plan, "idx_request_log_ts_utc") {
		t.Fatalf("plan does not reference idx_request_log_ts_utc; full plan:\n%s", plan)
	}
}

func openTestStore(t *testing.T) *Store {
	t.Helper()
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	return store
}

// TestOpenStoreCapsPoolAtOneConn pins the SetMaxOpenConns(1) +
// SetMaxIdleConns(1) discipline at the constructor that owns it. Issue
// #21 / ARCH-3: billing reuses this *sql.DB via
// billing.NewStore(reqLogStore.DB()), so the cap here serializes the
// whole money-path. If a future contributor deletes the cap, this
// test fails directly in the requestlog package; the parallel cap-
// dependent nested-cursor regressions in internal/billing remain as
// failure-mode coverage.
func TestOpenStoreCapsPoolAtOneConn(t *testing.T) {
	store := openTestStore(t)
	stats := store.DB().Stats()
	if stats.MaxOpenConnections != 1 {
		t.Fatalf("MaxOpenConnections=%d, want 1 (issue #21 cap)", stats.MaxOpenConnections)
	}
}
