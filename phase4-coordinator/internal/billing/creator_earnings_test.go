package billing

import (
	"context"
	"testing"
	"time"
)

func TestCreatorPoolEarningsSumsPayableOwnedCreditsOnPoolSnapshots(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	day := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	credit := func(requestID, providerID string, ts time.Time, provider int64, quarantined bool) {
		t.Helper()
		q := 0
		if quarantined {
			q = 1
		}
		if _, err := store.db.Exec(`
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model,
    status, stream, prompt_tokens, completion_tokens, estimated_completion_tokens,
    usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
    global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits,
    fault_flag, recovery_source, created_at_utc, quarantined
) VALUES (?, 0, ?, 'assigned', ?, 'model-a', 200, 0, 10, 10, NULL,
          'provider_reported', 1, 1, 1000000, ?, 9000, ?, 'none', 'hot_path', ?, ?)`,
			requestID, providerID, ts.Format(time.RFC3339Nano), provider*2, provider, ts.Format(time.RFC3339Nano), q); err != nil {
			t.Fatalf("insert credit %s: %v", requestID, err)
		}
	}
	snapshot := func(requestID, providerID, poolID string) {
		t.Helper()
		snap := testRouteSnapshot()
		snap.RequestID = requestID
		snap.ProviderID = providerID
		snap.PoolID = poolID
		if _, err := store.InsertRouteSnapshot(ctx, snap); err != nil {
			t.Fatalf("InsertRouteSnapshot %s: %v", requestID, err)
		}
	}
	credit("req-1", "mac-a", day, 100, false)
	snapshot("req-1", "mac-a", "pool-a")
	credit("req-2", "mac-b", day.Add(time.Hour), 40, false)
	snapshot("req-2", "mac-b", "pool-a")
	credit("req-3", "mac-a", day, 7, false)
	snapshot("req-3", "mac-a", "pool-b")
	// Not counted: another owner's Mac, a global (pool-less) request, a
	// quarantined credit, and a pool the query does not name.
	credit("req-4", "mac-stranger", day, 1000, false)
	snapshot("req-4", "mac-stranger", "pool-a")
	credit("req-5", "mac-a", day, 1000, false)
	snapshot("req-5", "mac-a", "")
	credit("req-6", "mac-a", day, 1000, true)
	snapshot("req-6", "mac-a", "pool-a")
	credit("req-7", "mac-a", day, 1000, false)
	snapshot("req-7", "mac-a", "pool-z")
	// Outside the day range below.
	credit("req-8", "mac-a", day.AddDate(0, 0, 10), 5, false)
	snapshot("req-8", "mac-a", "pool-a")

	rows, err := store.CreatorPoolEarnings(ctx, []string{"mac-a", "mac-b"}, []string{"pool-a", "pool-b"}, time.Time{}, time.Time{})
	if err != nil {
		t.Fatalf("CreatorPoolEarnings: %v", err)
	}
	want := []CreatorPoolEarnings{{PoolID: "pool-a", PayableRequests: 3, ProviderCredits: 145}, {PoolID: "pool-b", PayableRequests: 1, ProviderCredits: 7}}
	if len(rows) != len(want) || rows[0] != want[0] || rows[1] != want[1] {
		t.Fatalf("earnings = %+v, want %+v", rows, want)
	}

	from := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	ranged, err := store.CreatorPoolEarnings(ctx, []string{"mac-a", "mac-b"}, []string{"pool-a"}, from, from.AddDate(0, 0, 7))
	if err != nil {
		t.Fatalf("ranged CreatorPoolEarnings: %v", err)
	}
	if len(ranged) != 1 || ranged[0] != (CreatorPoolEarnings{PoolID: "pool-a", PayableRequests: 2, ProviderCredits: 140}) {
		t.Fatalf("ranged earnings = %+v", ranged)
	}
	if rows, err := store.CreatorPoolEarnings(ctx, nil, []string{"pool-a"}, time.Time{}, time.Time{}); err != nil || len(rows) != 0 {
		t.Fatalf("no owned providers = %+v err=%v", rows, err)
	}
	if _, err := store.CreatorPoolEarnings(ctx, []string{"mac-a"}, []string{"pool-a"}, from, time.Time{}); err == nil {
		t.Fatal("half-open range accepted")
	}
}
