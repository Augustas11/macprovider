package billing

import (
	"context"
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// #1690 review LOW (F-4 class): ClaimPayoutReady reads the payout row and
// its source credits and then writes the claim and its audit row. As a
// deferred transaction, a commit from the best-effort primary route-snapshot
// mirror to the same file between the read and the write failed the upgrade
// with SQLITE_BUSY without honouring busy_timeout. Production records the
// authoritative route snapshot in the dedicated journal first; concurrent
// primary-mirror pressure must not fail a claim or drop journal evidence.
func TestClaimPayoutReadySurvivesConcurrentRouteSnapshotWriter(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, routeSnapshotJournalDB := newContentionStoreWithRouteSnapshotJournal(t, dbPath)

	start := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	insertCreditWithOperator(t, store.db, "claim-contention-1", "provider-a", start.Add(time.Hour), 500)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	payoutID := scalar(t, store.db, `SELECT id FROM ledger_payout_ready WHERE provider_id = 'provider-a'`)

	const workers, perWorker = 4, 40
	var wg sync.WaitGroup
	var mu sync.Mutex
	var failures []error
	claims := 0
	fail := func(err error) {
		mu.Lock()
		defer mu.Unlock()
		failures = append(failures, err)
	}
	for w := 0; w < workers; w++ {
		wg.Add(2)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < perWorker; i++ {
				snapshot := testRouteSnapshot()
				snapshot.RequestID = fmt.Sprintf("req-claim-route-%d-%d", w, i)
				// Match the bounded production caller so transient writer pressure
				// exercises route-snapshot retries, not a single busy wait.
				ctx, cancel := context.WithTimeout(context.Background(), 1400*time.Millisecond)
				_, err := store.InsertRouteSnapshot(ctx, snapshot)
				cancel()
				if err != nil {
					fail(fmt.Errorf("route snapshot %d/%d: %w", w, i, err))
				}
			}
		}(w)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < perWorker; i++ {
				claimed, err := store.ClaimPayoutReady(context.Background(), payoutID, 500, fmt.Sprintf("external-%d-%d", w, i), "USDC")
				if err != nil {
					fail(fmt.Errorf("claim %d/%d: %w", w, i, err))
					continue
				}
				if claimed {
					mu.Lock()
					claims++
					mu.Unlock()
				}
			}
		}(w)
	}
	wg.Wait()
	if len(failures) > 0 {
		t.Fatalf("%d concurrent writes failed, first: %v", len(failures), failures[0])
	}
	if claims != 1 {
		t.Fatalf("successful claims=%d, want exactly 1", claims)
	}
	var journalRows int
	if err := routeSnapshotJournalDB.QueryRow(`SELECT COUNT(*) FROM settlement_route_snapshot_journal WHERE request_id LIKE 'req-claim-route-%'`).Scan(&journalRows); err != nil {
		t.Fatal(err)
	}
	if journalRows != workers*perWorker {
		t.Fatalf("route snapshot journal rows=%d, want %d", journalRows, workers*perWorker)
	}
}
