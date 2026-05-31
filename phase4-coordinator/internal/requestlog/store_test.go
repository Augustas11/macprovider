package requestlog

import (
	"context"
	"database/sql"
	"path/filepath"
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

func openTestStore(t *testing.T) *Store {
	t.Helper()
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	return store
}
