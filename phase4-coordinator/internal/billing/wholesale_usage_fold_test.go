package billing

import (
	"context"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

// SPEC-005 §2.1b: folding request_log rows into per-day usage aggregates
// before they leave never changes a D1a wholesale statement.
func TestWholesaleFoldKeepsStatementsIdentical(t *testing.T) {
	ctx := context.Background()
	reqStore, store := newRequestAndBillingStores(t)
	store.SetWholesalePricing(1.0)
	model := "mlx-community/Llama-3.2-3B-Instruct-4bit"
	other := "mlx-community/Qwen2.5-7B-Instruct-4bit"
	cheap := RewardsConfig{GlobalMultiplier: 1, ProviderShare: 0.9, RateCard: map[string]RateCardEntry{
		model: {PromptCreditsPerMtok: 13500, CompletionCreditsPerMtok: 27000},
		other: {PromptCreditsPerMtok: 20000, CompletionCreditsPerMtok: 40000},
	}}
	dear := RewardsConfig{GlobalMultiplier: 1.5, ProviderShare: 0.9, RateCard: map[string]RateCardEntry{
		model: {PromptCreditsPerMtok: 50000, CompletionCreditsPerMtok: 90000},
	}}
	if _, err := store.InsertConfigSnapshot(ctx, cheap, time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	dearID, err := store.InsertConfigSnapshot(ctx, dear, time.Date(2026, 9, 15, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	account := "acct_partner"
	insert := func(requestID, m string, ts time.Time, status int, prompt, completion int64, accountID string) {
		t.Helper()
		row := requestlog.Row{TSUtc: ts, RequestID: requestID, AccountID: accountID, Model: m,
			PromptTokens: &prompt, CompletionTokens: &completion, Status: status, BuyerIP: "127.0.0.1",
			ProviderAssignedID: "pa-1"}
		if err := reqStore.Insert(ctx, row); err != nil {
			t.Fatal(err)
		}
	}
	for day := 1; day <= 30; day++ {
		ts := time.Date(2026, 9, day, 10, 0, 0, 0, time.UTC)
		insert(fmt.Sprintf("req-%d-a", day), model, ts, 200, int64(1000+day), int64(2000+3*day), account)
		insert(fmt.Sprintf("req-%d-b", day), other, ts.Add(time.Hour), 200, int64(700+day), int64(900+day), account)
		insert(fmt.Sprintf("req-%d-err", day), model, ts.Add(2*time.Hour), 500, 5, 0, account)
		insert(fmt.Sprintf("req-%d-anon", day), model, ts, 200, 10, 10, "")
	}
	// A retried request: a failed attempt and a priced attempt whose identity
	// links the dear generation, so the row is priced at that generation.
	retryTS := time.Date(2026, 9, 3, 8, 0, 0, 0, time.UTC)
	insert("req-retry", model, retryTS, 502, 0, 0, account)
	insert("req-retry", model, retryTS.Add(time.Second), 200, 4000, 8000, account)
	if _, err := store.db.Exec(`
INSERT INTO ledger_provider_identity_snapshots (request_id, attempt_n, provider_assigned_id, provider_id, resolved_from, config_snapshot_id, created_at_utc)
VALUES ('req-retry', 1, 'pa-1', 'prov-1', 'response_header', ?, ?)`, dearID, sqliteTimeText(retryTS)); err != nil {
		t.Fatal(err)
	}
	// One request straddling the fold cutoff stays hot until all its rows leave.
	insert("req-straddle", model, time.Date(2026, 9, 19, 23, 59, 59, 0, time.UTC), 502, 0, 0, account)
	insert("req-straddle", model, time.Date(2026, 9, 20, 0, 0, 1, 0, time.UTC), 200, 333, 444, account)

	statement := func() WholesaleStatement {
		t.Helper()
		stmt, err := store.GenerateWholesaleStatement(ctx, account, "2026-09", true)
		if err != nil {
			t.Fatal(err)
		}
		stmt.GeneratedAtUTC = ""
		return stmt
	}
	before := statement()
	if before.RequestCount != 62 || len(before.LineItems) != 2 {
		t.Fatalf("statement before fold: requests=%d items=%+v", before.RequestCount, before.LineItems)
	}

	count := func(where string, args ...any) int64 {
		t.Helper()
		return scalar(t, store.db, `SELECT COUNT(*) FROM request_log WHERE `+where, args...)
	}
	deleted, err := store.FoldWholesaleRequestLog(ctx, time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if deleted == 0 || count(`account_id = ? AND request_id = 'req-straddle'`, account) != 2 {
		t.Fatalf("fold deleted %d rows; straddling request rows left=%d", deleted, count(`account_id = ? AND request_id = 'req-straddle'`, account))
	}
	if anon := count(`account_id IS NULL OR account_id = ''`); anon != 30 {
		t.Fatalf("the fold touched rows without an account: %d left, want 30", anon)
	}
	if got := statement(); !reflect.DeepEqual(got, before) {
		t.Fatalf("statement after a partial fold differs:\nbefore %+v\nafter  %+v", before, got)
	}
	if _, err := store.FoldWholesaleRequestLog(ctx, time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	if left := count(`account_id = ?`, account); left != 0 {
		t.Fatalf("%d partner rows left after a full fold", left)
	}
	if got := statement(); !reflect.DeepEqual(got, before) {
		t.Fatalf("statement after a full fold differs:\nbefore %+v\nafter  %+v", before, got)
	}
	// The request-log pruner removes only rows without an account; the fold
	// is the only way rows with one leave.
	if _, err := reqStore.PruneBefore(ctx, time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	if left := count(`1=1`); left != 0 {
		t.Fatalf("request-log pruner left %d rows", left)
	}
	if got := statement(); !reflect.DeepEqual(got, before) {
		t.Fatalf("statement after the pruner differs:\nbefore %+v\nafter  %+v", before, got)
	}
	if _, err := store.db.Exec(`DELETE FROM wholesale_usage_daily`); err == nil {
		t.Fatal("folded wholesale usage was deletable")
	}
}

// The request-log pruner never deletes a row with an account: those leave
// only through the wholesale fold, a request at a time.
func TestRequestLogPruneLeavesAccountRowsToTheFold(t *testing.T) {
	ctx := context.Background()
	reqStore, store := newRequestAndBillingStores(t)
	old := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	one := int64(1)
	for _, account := range []string{"acct", ""} {
		if err := reqStore.Insert(ctx, requestlog.Row{TSUtc: old, RequestID: "r-" + account, AccountID: account, Model: "m",
			PromptTokens: &one, CompletionTokens: &one, Status: 200, BuyerIP: "127.0.0.1"}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := reqStore.PruneBefore(ctx, old.AddDate(0, 0, 1)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM request_log WHERE account_id = 'acct'`); got != 1 {
		t.Fatalf("account row pruned outside the fold: %d left", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM request_log WHERE account_id IS NULL OR account_id = ''`); got != 0 {
		t.Fatalf("anonymous row kept: %d", got)
	}
}
