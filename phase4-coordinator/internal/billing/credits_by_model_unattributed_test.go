package billing

import (
	"context"
	"database/sql"
	"testing"
	"time"
)

// credits_by_model never names an empty model: a credit with no model counts
// in total and in unattributed, and the map sums to total minus unattributed.
// (ledger_request_credits.model is NOT NULL, so unattributed is 0 on the
// ledger; the totals reader still never keys a NULL model.)
func TestPayableTotalsNullModelIsUnattributed(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	ctx := context.Background()
	for _, stmt := range []string{
		`CREATE TABLE credits (provider_id TEXT, model TEXT, provider_credits INTEGER, ts_utc TEXT)`,
		`CREATE VIEW spec022_payable_request_credits AS SELECT * FROM credits`,
	} {
		if _, err := db.ExecContext(ctx, stmt); err != nil {
			t.Fatal(err)
		}
	}
	now := sqliteTimeText(time.Date(2026, 11, 16, 0, 0, 0, 0, time.UTC))
	for _, row := range []struct {
		model   any
		credits int
	}{{"model-a", 5}, {nil, 3}, {"model-b", 2}} {
		if _, err := db.ExecContext(ctx, `INSERT INTO credits VALUES ('p1', ?, ?, ?)`, row.model, row.credits, now); err != nil {
			t.Fatal(err)
		}
	}
	got, err := providerPayableTotalsOn(ctx, db, "p1", now, now, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := got.byModel[""]; ok {
		t.Fatalf("credits_by_model keys an empty model: %v", got.byModel)
	}
	var sum int64
	for _, c := range got.byModel {
		sum += c
	}
	if got.total != 10 || got.unattributed != 3 || sum+got.unattributed != got.total || len(got.models) != 2 || len(got.byModel) != 2 {
		t.Fatalf("total=%d unattributed=%d by_model=%v models=%v", got.total, got.unattributed, got.byModel, got.models)
	}
}
