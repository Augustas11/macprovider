package sourceevidence

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

func TestStoreClosesNoDispatchAndFencesSettlementWrites(t *testing.T) {
	ctx := context.Background()
	store, db := newTestStore(t)
	row := testNoDispatchRow("acct-a", "external-a", "11111111-1111-4111-8111-111111111111", 404, "")
	if err := store.RecordNoDispatch(ctx, ClosureInput{TerminalKind: TerminalModelNotFound, Row: row}); err != nil {
		t.Fatalf("RecordNoDispatch: %v", err)
	}
	resolved, err := store.ResolveClosed(ctx, Scope{AccountID: row.AccountID, ExternalRequestID: row.ExternalRequestID, RequiredInternalRequestID: row.RequestID, NotBeforeUnixMS: row.TSUtc.Add(-time.Second).UnixMilli()})
	if err != nil {
		t.Fatalf("ResolveClosed: %v", err)
	}
	if resolved.LogStatus != 404 || resolved.AttemptN != 0 || resolved.ProviderSet || resolved.Closure.TerminalKind != TerminalModelNotFound {
		t.Fatalf("unexpected resolved record: %+v", resolved)
	}
	_, err = db.ExecContext(ctx, `INSERT INTO ledger_request_credits (
request_id, attempt_n, provider_id, ts_utc, model, status, stream, usage_source,
prompt_rate_per_mtok, completion_rate_per_mtok, global_multiplier_ppm, gross_credits,
provider_share_bps, provider_credits, created_at_utc
) VALUES (?,0,'provider-a',?,'m',200,0,'null_error',0,0,0,0,0,0,?)`, row.RequestID, time.Now().UTC().Format(time.RFC3339Nano), time.Now().UTC().Format(time.RFC3339Nano))
	if err == nil {
		t.Fatalf("settlement write after closure unexpectedly succeeded")
	}
}

func TestStoreRejectsGlobalRequestIDCollision(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t)
	requestID := "22222222-2222-4222-8222-222222222222"
	first := testNoDispatchRow("acct-a", "external-a", requestID, 503, "Pool unavailable")
	if err := store.RecordNoDispatch(ctx, ClosureInput{TerminalKind: TerminalPoolUnavailable, Row: first}); err != nil {
		t.Fatalf("first RecordNoDispatch: %v", err)
	}
	second := testNoDispatchRow("acct-b", "external-b", requestID, 503, "Pool unavailable")
	if err := store.RecordNoDispatch(ctx, ClosureInput{TerminalKind: TerminalPoolUnavailable, Row: second}); err == nil {
		t.Fatalf("second closure with same global request_id unexpectedly succeeded")
	}
}

func newTestStore(t *testing.T) (*Store, *sql.DB) {
	t.Helper()
	reqLog, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("requestlog.OpenStore: %v", err)
	}
	t.Cleanup(func() { _ = reqLog.Close() })
	if _, err := billing.NewStore(reqLog.DB()); err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	if err := Migrate(context.Background(), reqLog.DB()); err != nil {
		t.Fatalf("Migrate: %v", err)
	}
	store, err := NewStore(reqLog.DB(), []byte("01234567890123456789012345678901"), func() time.Time { return time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC) })
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	return store, reqLog.DB()
}

func testNoDispatchRow(accountID, externalID, requestID string, status int, msg string) requestlog.Row {
	if msg == "" {
		msg = "No provider has advertised the requested model"
	}
	return requestlog.Row{
		TSUtc:             time.Date(2026, 10, 7, 11, 59, 59, 0, time.UTC),
		RequestID:         requestID,
		ExternalRequestID: externalID,
		AccountID:         accountID,
		Status:            status,
		Error:             msg,
	}
}
