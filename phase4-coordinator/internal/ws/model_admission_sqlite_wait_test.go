package ws

import (
	"context"
	"database/sql"
	"runtime"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestPromotionSQLiteWriteLockWaitHoldsNoAuthorityPins(t *testing.T) {
	db := openProbeAdmissionStore(t)
	store, err := NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	s, p, ps, _, e := admissionGuardFixture(t, store)
	var path string
	if err := store.db.QueryRow("SELECT file FROM pragma_database_list WHERE name='main'").Scan(&path); err != nil {
		t.Fatal(err)
	}
	blocker, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Close()
	blocker.SetMaxOpenConns(1)
	conn, err := blocker.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(context.Background(), "BEGIN IMMEDIATE"); err != nil {
		t.Fatal(err)
	}
	defer conn.ExecContext(context.Background(), "ROLLBACK")
	base := time.Now()
	var clock atomic.Int64
	clock.Store(base.UnixMilli())
	s.now = func() time.Time { return time.UnixMilli(clock.Load()) }
	store.commitTestHooks = &modelAdmissionCommitTestHooks{now: s.now}
	prepared := make(chan struct{})
	original := s.modelAdmissionPrepare
	_ = s.SetModelAdmissionAuthority(admissionFixtureResolver, func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, error) {
		a, err := original(ctx, p, e)
		close(prepared)
		return a, err
	})
	done := make(chan struct{})
	go func() { s.promoteModelAdmission(context.Background(), e, p, base); close(done) }()
	<-prepared
	deadline := time.Now().Add(time.Second)
	for store.db.Stats().InUse != 1 {
		if time.Now().After(deadline) {
			t.Fatal("promotion did not reserve connection for BEGIN wait")
		}
		runtime.Gosched()
	}
	if !ps.writeMu.TryLock() {
		t.Fatal("SQLite BEGIN wait retained session pin")
	}
	ps.writeMu.Unlock()
	if !s.sessionPublicationMu.TryLock() {
		t.Fatal("SQLite BEGIN wait retained publication pin")
	}
	s.sessionPublicationMu.Unlock()
	if !s.modelAdmissionAuthorityMu.TryLock() {
		t.Fatal("SQLite BEGIN wait retained authority installation pin")
	}
	s.modelAdmissionAuthorityMu.Unlock()
	// The external writer still owns the DB, so no owner guard can have run.
	clock.Store(base.Add(10 * time.Minute).UnixMilli())
	if _, err := conn.ExecContext(context.Background(), "ROLLBACK"); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("promotion failed to leave SQLite BEGIN wait")
	}
	latest, _, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, e.CandidateID)
	if err != nil || latest.CoordinatorEventID != e.CoordinatorEventID {
		t.Fatalf("expired BEGIN wait persisted positive: %s %v", latest.State, err)
	}
}
