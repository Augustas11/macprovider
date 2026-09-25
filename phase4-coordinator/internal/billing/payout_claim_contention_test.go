package billing

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

// #1690 review LOW (F-4 class): ClaimPayoutReady reads the payout row and
// its source credits and then writes the claim and its audit row. As a
// deferred transaction, a commit on another handle to the same file
// (routeSnapshotDB) between the read and the write failed the upgrade with
// SQLITE_BUSY without honouring busy_timeout. Concurrent writers must not
// fail a claim.
func TestClaimPayoutReadySurvivesConcurrentRouteSnapshotWriter(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	reqStore, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reqStore.Close() })
	store, err := NewStore(reqStore.DB())
	if err != nil {
		t.Fatal(err)
	}
	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
	if err != nil {
		t.Fatal(err)
	}
	routeSnapshotDB.SetMaxOpenConns(4)
	routeSnapshotDB.SetMaxIdleConns(4)
	t.Cleanup(func() { _ = routeSnapshotDB.Close() })
	store.SetRouteSnapshotDB(routeSnapshotDB)
	store.SetRouteSnapshotBusyTimeout(500 * time.Millisecond)

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
				if _, err := store.InsertRouteSnapshot(context.Background(), snapshot); err != nil {
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
}
