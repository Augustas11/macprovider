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

// #1690 VM e2e F-4: the settlement attempt output insert read (overlap
// SELECT) and then wrote in a deferred transaction on the shared handle,
// while route snapshots commit on their own handle to the same file (as
// cmd/coordinator wires routeSnapshotDB). A commit between the read and the
// write fails the upgrade with SQLITE_BUSY_SNAPSHOT (517) or SQLITE_BUSY
// without honouring busy_timeout, and the enforce credit loses its evidence.
// Concurrent writers must leave every attempt output recorded.
func TestInsertSettlementAttemptOutputSurvivesConcurrentRouteSnapshotWriter(t *testing.T) {
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
	// Production wiring (cmd/coordinator routeSnapshotSQLiteBusyTimeout).
	store.SetRouteSnapshotBusyTimeout(500 * time.Millisecond)

	const workers, perWorker = 4, 40
	var wg sync.WaitGroup
	var mu sync.Mutex
	var failures []error
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
				snapshot.RequestID = fmt.Sprintf("req-route-%d-%d", w, i)
				if _, err := store.InsertRouteSnapshot(context.Background(), snapshot); err != nil {
					fail(fmt.Errorf("route snapshot %d/%d: %w", w, i, err))
				}
			}
		}(w)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < perWorker; i++ {
				attempt := SettlementAttemptOutput{
					AccountScope:          "acct-a",
					RequestID:             fmt.Sprintf("req-output-%d-%d", w, i),
					ProviderID:            "provider-a",
					Output:                testSettlementOutput(),
					OutputAvailable:       true,
					Usage:                 testSettlementUsage(),
					UsageSource:           UsageSourceByteEstimated,
					TerminalStateTSUnixMS: 1716768000000,
				}
				if _, err := store.InsertSettlementAttemptOutput(context.Background(), attempt); err != nil {
					fail(fmt.Errorf("attempt output %d/%d: %w", w, i, err))
				}
			}
		}(w)
	}
	wg.Wait()
	if len(failures) > 0 {
		t.Fatalf("%d concurrent writes failed, first: %v", len(failures), failures[0])
	}
	var outputs int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM settlement_attempt_outputs`).Scan(&outputs); err != nil {
		t.Fatal(err)
	}
	if outputs != workers*perWorker {
		t.Fatalf("settlement attempt outputs=%d, want %d", outputs, workers*perWorker)
	}
}
