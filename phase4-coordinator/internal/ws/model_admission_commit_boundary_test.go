package ws

import (
	"context"
	"errors"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func admissionStoreHooks(store ModelAdmissionStore, h *modelAdmissionCommitTestHooks) {
	switch s := store.(type) {
	case *memoryModelAdmissionStore:
		s.commitTestHooks = h
	case *SQLiteModelAdmissionStore:
		s.commitTestHooks = h
	}
}
func TestPromotionAuthorityExpiry(t *testing.T) {
	for _, at := range []string{"before", "ample-promotion-budget", "exact", "before-insert", "between-boundaries", "after-commit"} {
		t.Run(at, func(t *testing.T) {
			runAdmissionStores(t, func(t *testing.T, store ModelAdmissionStore) {
				s, p, _, _, e := admissionGuardFixture(t, store)
				base := time.Date(2024, 1, 2, 3, 4, 5, 0, time.UTC)
				var clock atomic.Int64
				clock.Store(base.UnixMilli())
				now := func() time.Time { return time.UnixMilli(clock.Load()) }
				s.now = now
				expiry := base.Add(time.Minute)
				hooks := &modelAdmissionCommitTestHooks{now: now}
				admissionStoreHooks(store, hooks)
				resolve := func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (ModelAdmissionEvent, error) {
					e, err := admissionFixtureResolver(ctx, p, e)
					e.ArtifactAdmissionEvidence.AuthorityExpiresAtUnixMS = expiry.UnixMilli()
					e.ArtifactAdmissionEvidence.ProbeExpiresAtUnixMS = base.Add(10 * time.Minute).UnixMilli()
					return e, err
				}
				var releaseOnce atomic.Bool
				_ = s.SetModelAdmissionAuthority(resolve, func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, error) {
					a, err := resolve(ctx, p, e)
					return PreparedModelAdmissionAuthority{Event: a, TryPin: func() (func(), error) {
						return func() {
							if (at == "between-boundaries" || at == "after-commit") && releaseOnce.CompareAndSwap(false, true) {
								clock.Store(expiry.UnixMilli())
							}
						}, nil
					}}, err
				})
				switch at {
				case "before":
					clock.Store(expiry.Add(-time.Millisecond).UnixMilli())
				case "exact":
					clock.Store(expiry.UnixMilli())
				case "before-insert":
					hooks.beforeInsert = func() { clock.Store(expiry.UnixMilli()) }
				}
				// A frozen fake clock can stay 1ms before expiry while real SQLite
				// instrumentation takes longer. Exercise the actual guarded store
				// boundary directly here; promotion separately keeps its real
				// context deadline and may correctly fail closed at that budget.
				var result ModelAdmissionEvent
				if at == "before" {
					result = fixturePriced(t, s, p, e)
				} else {
					result = s.promoteModelAdmission(context.Background(), e, p, base)
				}
				latest, _, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, e.CandidateID)
				if err != nil {
					t.Fatal(err)
				}
				if at == "ample-promotion-budget" {
					if result.State != "settlement_capable" {
						t.Fatalf("ample-budget full promotion failed: %s", result.State)
					}
					return
				}
				if at == "before" {
					if result.State != "catalog_priced" {
						t.Fatalf("historical valid clock did not append: %s", result.State)
					}
					return
				}
				if at == "exact" || at == "before-insert" {
					if latest.CoordinatorEventID != e.CoordinatorEventID {
						t.Fatal("expired insertion persisted")
					}
				} else if latest.State != "catalog_priced" {
					t.Fatalf("first valid commit absent: %s", latest.State)
				}
				observed, err := s.refreshArtifactAdmissionStatus(context.Background(), result)
				if err == nil && artifactPositive(observed) {
					t.Fatal("expired durable evidence returned positive")
				}
			})
		})
	}
}

func TestPromotionSQLitePostInsertBoundary(t *testing.T) {
	for _, fault := range []string{"rollback", "panic", "cancellation", "expiry"} {
		t.Run(fault, func(t *testing.T) {
			db := openProbeAdmissionStore(t)
			store, err := NewSQLiteModelAdmissionStore(db.DB())
			if err != nil {
				t.Fatal(err)
			}
			s, p, ps, _, e := admissionGuardFixture(t, store)
			assertFullRelease := installAdmissionOwnerReleaseWitnesses(t, s)
			var expired atomic.Bool
			ctx := context.Background()
			var cancel context.CancelFunc
			if fault == "cancellation" {
				ctx, cancel = context.WithCancel(ctx)
				defer cancel()
			}
			realNow := time.Now()
			s.now = func() time.Time {
				if expired.Load() {
					return realNow.Add(2 * time.Hour)
				}
				return realNow
			}
			store.commitTestHooks = &modelAdmissionCommitTestHooks{now: s.now, afterInsert: func() error {
				if ps.writeMu.TryLock() {
					ps.writeMu.Unlock()
					t.Error("session pin released before COMMIT")
				}
				switch fault {
				case "rollback":
					return errors.New("injected transaction rollback")
				case "panic":
					panic("injected transaction panic")
				case "cancellation":
					cancel()
				case "expiry":
					expired.Store(true)
				}
				return nil
			}}
			func() {
				if fault == "panic" {
					defer func() {
						if recover() == nil {
							t.Error("panic absent")
						}
					}()
				}
				s.promoteModelAdmission(ctx, e, p, realNow)
			}()
			assertFullRelease()
			if !ps.writeMu.TryLock() {
				t.Fatal("pin leaked on transaction exit")
			}
			ps.writeMu.Unlock()
			latest, _, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, e.CandidateID)
			if err != nil {
				t.Fatal(err)
			}
			if fault != "expiry" && latest.CoordinatorEventID != e.CoordinatorEventID {
				t.Fatal("rollback kept inserted positive")
			}
			observed, err := s.refreshArtifactAdmissionStatus(context.Background(), latest)
			if err == nil && artifactPositive(observed) {
				t.Fatal("fault or post-insert expiration stayed positive")
			}
			if fault != "expiry" {
				store.commitTestHooks = nil
				if result := s.promoteModelAdmission(context.Background(), e, p, realNow); result.State != "settlement_capable" {
					t.Fatalf("promotion after %s recovery=%s", fault, result.State)
				}
			}
		})
	}
}

func TestPromotionDatabaseWaitHoldsNoAuthorityPins(t *testing.T) {
	db := openProbeAdmissionStore(t)
	store, err := NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	s, p, ps, _, e := admissionGuardFixture(t, store)
	conn, err := store.db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	prepared := make(chan struct{})
	original := s.modelAdmissionPrepare
	_ = s.SetModelAdmissionAuthority(admissionFixtureResolver, func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, error) {
		a, err := original(ctx, p, e)
		close(prepared)
		return a, err
	})
	done := make(chan struct{})
	go func() { s.promoteModelAdmission(context.Background(), e, p, time.Now()); close(done) }()
	<-prepared
	if !ps.writeMu.TryLock() {
		t.Fatal("DB connection wait retained session pin")
	}
	ps.beginClosingLocked()
	ps.writeMu.Unlock()
	if !s.modelAdmissionAuthorityMu.TryLock() {
		t.Fatal("DB connection wait retained resolver pin")
	}
	s.modelAdmissionAuthorityMu.Unlock()
	if !s.sessionPublicationMu.TryLock() {
		t.Fatal("DB connection wait retained session publication pin")
	}
	s.sessionPublicationMu.Unlock()
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	<-done
	latest, _, _ := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, e.CandidateID)
	if latest.CoordinatorEventID != e.CoordinatorEventID {
		t.Fatal("wait crossed closing authority")
	}
}

func TestPromotionCommitFailureAndReconciliation(t *testing.T) {
	t.Run("real-INSERT-rejection", func(t *testing.T) {
		db := openProbeAdmissionStore(t)
		store, err := NewSQLiteModelAdmissionStore(db.DB())
		if err != nil {
			t.Fatal(err)
		}
		s, p, ps, _, e := admissionGuardFixture(t, store)
		assertFullRelease := installAdmissionOwnerReleaseWitnesses(t, s)
		before := admissionReadbackHistory(t, store, e.CandidateID)
		_, retriesBefore := admissionStoreCounts(t, store)
		if _, err := store.db.Exec(`CREATE TRIGGER guard_insert_rejection BEFORE INSERT ON model_admission_events WHEN NEW.state='catalog_priced' BEGIN SELECT RAISE(ABORT, 'injected guarded INSERT rejection'); END`); err != nil {
			t.Fatal(err)
		}
		afterInsert := false
		store.commitTestHooks = &modelAdmissionCommitTestHooks{afterInsert: func() error {
			afterInsert = true
			return nil
		}}
		if result := s.promoteModelAdmission(context.Background(), e, p, time.Now()); result.CoordinatorEventID != e.CoordinatorEventID {
			t.Fatalf("INSERT rejection returned event %+v", result)
		}
		if afterInsert {
			t.Fatal("INSERT rejection reached post-insert hook")
		}
		assertFullRelease()
		if history := admissionReadbackHistory(t, store, e.CandidateID); !reflect.DeepEqual(history, before) {
			t.Fatalf("INSERT rejection changed history: before=%+v after=%+v", before, history)
		}
		_, retriesAfter := admissionStoreCounts(t, store)
		if retriesAfter != retriesBefore {
			t.Fatalf("INSERT rejection changed replay reservations: %d->%d", retriesBefore, retriesAfter)
		}
		assertAdmissionWSOwnersReleased(t, s, p, ps)
		if _, err := store.db.Exec("DROP TRIGGER guard_insert_rejection"); err != nil {
			t.Fatal(err)
		}
		store.commitTestHooks = nil
		if result := s.promoteModelAdmission(context.Background(), e, p, time.Now()); result.State != "settlement_capable" {
			t.Fatalf("promotion after INSERT recovery=%s", result.State)
		}
	})
	t.Run("real-deferred-constraint-COMMIT-failure", func(t *testing.T) {
		db := openProbeAdmissionStore(t)
		store, err := NewSQLiteModelAdmissionStore(db.DB())
		if err != nil {
			t.Fatal(err)
		}
		s, p, ps, _, e := admissionGuardFixture(t, store)
		assertFullRelease := installAdmissionOwnerReleaseWitnesses(t, s)
		for _, statement := range []string{"PRAGMA foreign_keys=ON", "CREATE TABLE guard_parent(id INTEGER PRIMARY KEY)", "CREATE TABLE guard_child(parent_id INTEGER REFERENCES guard_parent(id) DEFERRABLE INITIALLY DEFERRED)", "CREATE TRIGGER guard_commit_failure AFTER INSERT ON model_admission_events WHEN NEW.state='catalog_priced' BEGIN INSERT INTO guard_child VALUES(999); END"} {
			if _, err := store.db.Exec(statement); err != nil {
				t.Fatal(err)
			}
		}
		inserted := false
		store.commitTestHooks = &modelAdmissionCommitTestHooks{afterInsert: func() error {
			inserted = true
			if ps.writeMu.TryLock() {
				ps.writeMu.Unlock()
				t.Error("pin missing at pre-COMMIT")
			}
			return nil
		}}
		s.promoteModelAdmission(context.Background(), e, p, time.Now())
		assertFullRelease()
		if !inserted {
			t.Fatal("failure happened before actual insert")
		}
		latest, _, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, e.CandidateID)
		if err != nil {
			t.Fatal(err)
		}
		if latest.CoordinatorEventID != e.CoordinatorEventID {
			t.Fatal("failed COMMIT persisted positive")
		}
		if !ps.writeMu.TryLock() {
			t.Fatal("COMMIT failure leaked session pin")
		}
		ps.writeMu.Unlock()
		assertAdmissionWSOwnersReleased(t, s, p, ps)
		if _, err := store.db.Exec("DROP TRIGGER guard_commit_failure"); err != nil {
			t.Fatal(err)
		}
		store.commitTestHooks = nil
		if result := s.promoteModelAdmission(context.Background(), e, p, time.Now()); result.State != "settlement_capable" {
			t.Fatalf("COMMIT recovery failed: %s", result.State)
		}
	})
	for _, unknown := range []bool{false, true} {
		name := "known-committed"
		if unknown {
			name = "unavailable-reconciliation"
		}
		t.Run(name, func(t *testing.T) {
			runAdmissionStores(t, func(t *testing.T, base ModelAdmissionStore) {
				s, p, _, _, e := admissionGuardFixture(t, base)
				assertFullRelease := installAdmissionOwnerReleaseWitnesses(t, s)
				wrapper := &uncertainAdmissionCommitStore{ModelAdmissionStore: base, guarded: base.(guardedModelAdmissionStore), unknown: unknown}
				s.modelAdmissions = wrapper
				result := s.promoteModelAdmission(context.Background(), e, p, time.Now())
				assertFullRelease()
				if result.CoordinatorEventID != e.CoordinatorEventID {
					t.Fatal("uncertain append returned new positive without reconciliation")
				}
				for reconciliation := 0; reconciliation < 2; reconciliation++ {
					observed, err := s.refreshArtifactAdmissionStatus(context.Background(), result)
					if unknown {
						if err == nil || artifactPositive(observed) {
							t.Fatal("unknown reconciliation returned a positive claim")
						}
					} else if err != nil || observed.State != "catalog_priced" {
						t.Fatalf("known commit reconciliation %d: %s %v", reconciliation, observed.State, err)
					}
				}
				latest, _, err := base.LatestModelAdmissionStatus(context.Background(), p.ProviderID, e.CandidateID)
				if err != nil || latest.State != "catalog_priced" {
					t.Fatalf("expected exactly one durable positive: %s %v", latest.State, err)
				}
				history := admissionReadbackHistory(t, base, e.CandidateID)
				if len(history) != 4 || history[3].State != "catalog_priced" {
					t.Fatalf("uncertain complete history=%+v", history)
				}
				attempted, committed := wrapper.attempted, wrapper.committed
				if attempted.ExpectedCurrentEventID != e.CoordinatorEventID || committed.RequestID == "" || committed.Nonce == "" || committed.PayloadDigestSHA256 == "" {
					t.Fatalf("uncertain CAS/replay identity attempted=%+v committed=%+v", attempted, committed)
				}
				prepared, generation, _ := fixturePreparedDecision(t, s, p, e)
				prepared.Event = committed
				replayed, err := base.(guardedModelAdmissionStore).AppendGuardedModelAdmissionDecision(context.Background(), committed, func() (func(), error) {
					return s.pinAdmission(context.Background(), p, prepared, generation)
				})
				if err != nil || replayed.CoordinatorEventID != committed.CoordinatorEventID {
					t.Fatalf("uncertain durable replay=%+v err=%v", replayed, err)
				}
				if after := admissionReadbackHistory(t, base, e.CandidateID); !reflect.DeepEqual(after, history) {
					t.Fatalf("uncertain replay duplicated history: %+v", after)
				}
			})
		})
	}
}

type uncertainAdmissionCommitStore struct {
	ModelAdmissionStore
	guarded   guardedModelAdmissionStore
	unknown   bool
	attempted ModelAdmissionEvent
	committed ModelAdmissionEvent
}

func (s *uncertainAdmissionCommitStore) AppendGuardedModelAdmissionDecision(ctx context.Context, e ModelAdmissionEvent, g ModelAdmissionCommitGuard) (ModelAdmissionEvent, error) {
	s.attempted = e
	stored, err := s.guarded.AppendGuardedModelAdmissionDecision(ctx, e, g)
	if err != nil {
		return ModelAdmissionEvent{}, err
	}
	s.committed = stored
	return ModelAdmissionEvent{}, errors.New("injected lost commit acknowledgement")
}

func assertAdmissionWSOwnersReleased(t *testing.T, s *Server, p pool.Provider, ps *providerSession) {
	t.Helper()
	if !s.modelAdmissionAuthorityMu.TryLock() {
		t.Fatal("authority installation pin leaked")
	}
	s.modelAdmissionAuthorityMu.Unlock()
	if !s.sessionPublicationMu.TryLock() {
		t.Fatal("session publication pin leaked")
	}
	s.sessionPublicationMu.Unlock()
	if !ps.writeMu.TryLock() {
		t.Fatal("session writer pin leaked")
	}
	ps.writeMu.Unlock()
	_, _, release, ok := s.pool.TryPinModelAdmissionProvider(p.ProviderID, p.AssignedID)
	if !ok || release == nil {
		t.Fatal("pool owner pin leaked")
	}
	release()
}

func installAdmissionOwnerReleaseWitnesses(t *testing.T, s *Server) func() {
	t.Helper()
	original := s.modelAdmissionPrepare
	type witness struct {
		name     string
		mu       sync.Mutex
		acquired atomic.Int32
		released atomic.Int32
	}
	witnesses := []*witness{
		{name: "signed-feed"},
		{name: "buyer-billing"},
		{name: "settlement-config"},
		{name: "tier2-default-publication"},
		{name: "tier2-catalog-state"},
	}
	if err := s.SetModelAdmissionAuthority(admissionFixtureResolver, func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, error) {
		prepared, err := original(ctx, p, e)
		if err != nil {
			return prepared, err
		}
		subordinate := prepared.TryPin
		prepared.TryPin = func() (func(), error) {
			releaseSubordinate, err := subordinate()
			if err != nil {
				return nil, err
			}
			locked := make([]*witness, 0, len(witnesses))
			for _, owner := range witnesses {
				if !owner.mu.TryLock() {
					for i := len(locked) - 1; i >= 0; i-- {
						locked[i].mu.Unlock()
						locked[i].released.Add(1)
					}
					releaseSubordinate()
					return nil, errors.New("release witness contention: " + owner.name)
				}
				owner.acquired.Add(1)
				locked = append(locked, owner)
			}
			return func() {
				for i := len(locked) - 1; i >= 0; i-- {
					locked[i].mu.Unlock()
					locked[i].released.Add(1)
				}
				releaseSubordinate()
			}, nil
		}
		return prepared, nil
	}); err != nil {
		t.Fatal(err)
	}
	return func() {
		t.Helper()
		for _, owner := range witnesses {
			if !owner.mu.TryLock() {
				t.Fatalf("%s owner pin leaked", owner.name)
			}
			owner.mu.Unlock()
			if owner.acquired.Load() == 0 || owner.acquired.Load() != owner.released.Load() {
				t.Fatalf("%s release witness acquired=%d released=%d", owner.name, owner.acquired.Load(), owner.released.Load())
			}
		}
	}
}
func (s *uncertainAdmissionCommitStore) ObserveModelAdmission(ctx context.Context, p, c string, f func(ModelAdmissionEvent) (func(), error)) (ModelAdmissionEvent, error) {
	return s.guarded.ObserveModelAdmission(ctx, p, c, f)
}
func (s *uncertainAdmissionCommitStore) LatestModelAdmissionStatus(ctx context.Context, p, c string) (ModelAdmissionEvent, bool, error) {
	if s.unknown {
		return ModelAdmissionEvent{}, false, errors.New("injected reconciliation read failure")
	}
	return s.ModelAdmissionStore.LatestModelAdmissionStatus(ctx, p, c)
}

func TestPromotionLockOrderAndAvailability(t *testing.T) {
	runAdmissionStores(t, func(t *testing.T, store ModelAdmissionStore) {
		s, p, ps, _, e := admissionGuardFixture(t, store)
		start, done := make(chan struct{}), make(chan struct{})
		go func() {
			defer close(done)
			<-start
			for i := 0; i < 200; i++ {
				s.pool.MarkState(p.ProviderID, p.AssignedID, pool.StateBusy)
				s.pool.RecordCanaryResult(p.ProviderID, p.AssignedID, true, time.Now(), 3)
				s.pool.MarkState(p.ProviderID, p.AssignedID, pool.StateReady)
				s.storeProviderSession(sessionKey(p.ProviderID, p.AssignedID), ps)
			}
		}()
		close(start)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for i := 0; i < 64; i++ {
			s.promoteModelAdmission(ctx, e, p, time.Now())
			if ctx.Err() != nil {
				t.Fatal("bounded promotion stress exhausted deadline")
			}
			if _, ok := s.pool.Resolve(p.ProviderID, p.AssignedID); !ok {
				t.Fatal("ordinary registry observation unavailable")
			}
		}
		select {
		case <-done:
		case <-ctx.Done():
			t.Fatal("registry/canary publication deadlocked")
		}
		t.Log("completed 64 promotions and 200 registry/canary/session publications")
		a, g, err := s.prepareAdmission(ctx, p, e)
		if err != nil {
			t.Fatal(err)
		}
		began := time.Now()
		release, err := s.pinAdmission(ctx, p, a, g)
		if err != nil {
			t.Fatal(err)
		}
		release()
		held := time.Since(began)
		t.Logf("uncontended authority validation+pin duration=%s", held)
		if held > 250*time.Millisecond {
			t.Fatal("uncontended pin exceeded commit budget")
		}
	})
}

func TestPromotionExpiryWhileWaitingForDatabase(t *testing.T) {
	db := openProbeAdmissionStore(t)
	store, err := NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	s, p, ps, _, e := admissionGuardFixture(t, store)
	base := time.Now()
	var clock atomic.Int64
	clock.Store(base.UnixMilli())
	s.now = func() time.Time { return time.UnixMilli(clock.Load()) }
	store.commitTestHooks = &modelAdmissionCommitTestHooks{now: s.now}
	conn, err := store.db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
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
	if !ps.writeMu.TryLock() {
		t.Fatal("database wait held transport pin")
	}
	ps.writeMu.Unlock()
	clock.Store(base.Add(10 * time.Minute).UnixMilli())
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	<-done
	latest, _, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, e.CandidateID)
	if err != nil || latest.CoordinatorEventID != e.CoordinatorEventID {
		t.Fatalf("expired DB wait appended: %s %v", latest.State, err)
	}
}

func TestPromotionOneMillisecondBudgetFailsClosed(t *testing.T) {
	db := openProbeAdmissionStore(t)
	store, err := NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	s, p, ps, _, e := admissionGuardFixture(t, store)
	base := time.Date(2024, 1, 2, 3, 4, 5, 0, time.UTC)
	s.now = func() time.Time { return base }
	store.commitTestHooks = &modelAdmissionCommitTestHooks{now: s.now}
	prepared := make(chan struct{})
	resolve := func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (ModelAdmissionEvent, error) {
		a, err := admissionFixtureResolver(ctx, p, e)
		a.ArtifactAdmissionEvidence.AuthorityExpiresAtUnixMS = base.Add(time.Millisecond).UnixMilli()
		a.ArtifactAdmissionEvidence.ProbeExpiresAtUnixMS = base.Add(time.Minute).UnixMilli()
		return a, err
	}
	_ = s.SetModelAdmissionAuthority(resolve, func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, error) {
		a, err := resolve(ctx, p, e)
		close(prepared)
		return PreparedModelAdmissionAuthority{Event: a, TryPin: func() (func(), error) { return func() {}, nil }}, err
	})
	conn, err := store.db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	done := make(chan ModelAdmissionEvent, 1)
	go func() { done <- s.promoteModelAdmission(context.Background(), e, p, base) }()
	<-prepared
	select {
	case result := <-done:
		if artifactPositive(result) {
			t.Fatal("expired real commit budget returned positive")
		}
	case <-time.After(time.Second):
		t.Fatal("1ms commit context failed to bound connection wait")
	}
	if !ps.writeMu.TryLock() {
		t.Fatal("budget exhaustion retained session pin")
	}
	ps.writeMu.Unlock()
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	latest, _, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, e.CandidateID)
	if err != nil || latest.CoordinatorEventID != e.CoordinatorEventID {
		t.Fatal("budget exhaustion persisted event")
	}
}
