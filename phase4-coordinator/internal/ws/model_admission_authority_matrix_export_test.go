package ws

import (
	"context"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
	"net"
	"reflect"
	"runtime"
	"sync"
	"testing"
	"time"
)

// These bridges exist only in the ws test binary. External ws tests can combine
// the actual coordinator guard with the buyer package without a runtime cycle.
func AdmissionStoreForServerForTest(s *Server) ModelAdmissionStore { return s.modelAdmissions }

func NewAdmissionStoreForTest(t *testing.T, kind string) ModelAdmissionStore {
	t.Helper()
	if kind == "memory" {
		return NewMemoryModelAdmissionStore()
	}
	db := openProbeAdmissionStore(t)
	store, err := NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	return store
}
func NewFullAdmissionOwnerForTest(t *testing.T, registry *pool.Registry, p pool.Provider, store ModelAdmissionStore, event ModelAdmissionEvent) (*Server, pool.Provider, ModelAdmissionEvent) {
	t.Helper()
	a, b := net.Pipe()
	t.Cleanup(func() { a.Close(); b.Close() })
	registry.Register(&p, a)
	registry.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateReady, At: time.Now()})
	p, _ = registry.Resolve(p.ProviderID, p.AssignedID)
	s := NewServer(modelAdmissionProbeAuthConfig(), registry, zerolog.Nop(), WithModelAdmissionStore(store))
	ps := newProviderSession(p.ProviderID, p.AssignedID, a, 8)
	s.storeProviderSession(sessionKey(p.ProviderID, p.AssignedID), ps)
	t.Cleanup(func() { ps.close(); s.deleteProviderSession(sessionKey(p.ProviderID, p.AssignedID)) })
	event.RequestID = "owner-offer"
	event.Nonce = "owner-offer"
	event.PayloadDigestSHA256 = modelAdmissionProbeStringsOf("d", 64)
	event.State = "offer_submitted"
	event, _, err := store.AppendModelAdmissionOffer(context.Background(), event)
	if err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"sandbox_probe_only", "network_admitted_unsettled"} {
		event, err = store.AppendModelAdmissionDecision(context.Background(), modelAdmissionCoordinatorDecisionFromCurrent(event, state, "synthetic_probe_passed", "fixture", state, time.Now()))
		if err != nil {
			t.Fatal(err)
		}
	}
	return s, p, event
}
func PrepareFullAdmissionForTest(s *Server, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, ModelAdmissionCommitGuard, error) {
	a, g, err := s.prepareAdmission(context.Background(), p, e)
	if err != nil {
		return a, nil, err
	}
	return a, func() (func(), error) { return s.pinAdmission(context.Background(), p, a, g) }, nil
}
func PromoteFullAdmissionForTest(s *Server, p pool.Provider, e ModelAdmissionEvent) {
	s.promoteModelAdmission(context.Background(), e, p, time.Now())
}
func DeleteAdmissionSessionForTest(s *Server, p pool.Provider) {
	if ps, ok := s.storedSessionFor(p.ProviderID, p.AssignedID); ok {
		ps.closeTransport()
		ps.close()
	}
	s.deleteProviderSession(sessionKey(p.ProviderID, p.AssignedID))
}
func InstallCountingCanaryBuyerServingForTest(s *Server, count func()) {
	s.pool.SetBuyerServingPredicate(func(p pool.Provider) bool { count(); return s.canaryBuyerServing(p) })
}

// RunAdmissionOwnerHTTPMatrixForTest drives each owner through actual signed
// HTTP offer/retry, real WS probe, and both store serialization implementations.
func RunAdmissionOwnerHTTPMatrixForTest(t *testing.T, setup func(*testing.T, *Server, *pool.Registry, pool.Provider) (pool.Provider, func(), func(), func() bool)) {
	for _, boundary := range []string{"catalog_priced", "settlement_capable"} {
		t.Run(boundary, func(t *testing.T) {
			for _, entry := range []string{"offer", "retry"} {
				t.Run(entry, func(t *testing.T) {
					for _, kind := range []string{"memory", "sqlite"} {
						t.Run(kind, func(t *testing.T) {
							orders := []string{"invalidate-first", "guard-first"}
							if kind == "sqlite" {
								orders = append(orders, "post-insert")
							}
							for _, order := range orders {
								t.Run(order, func(t *testing.T) {
									base := NewAdmissionStoreForTest(t, kind)
									wrapped := &admissionHTTPMatrixStore{admissionReadbackStore: &admissionReadbackStore{ModelAdmissionStore: base}, target: boundary}
									probeCompleted := make(chan struct{})
									var probeOnce sync.Once
									f := newAdmissionReadbackHTTP(t, wrapped, entry == "offer", func(f *admissionReadbackHTTP) {
										f.afterProbe = func() { probeOnce.Do(func() { close(probeCompleted) }) }
									})
									var mutate, route func()
									var pending func() bool
									f.p, mutate, route, pending = setup(t, f.s, f.s.pool, f.p)
									// setup must retain the exact already-stored WS identity and connection.
									original := f.payload("offer", map[string]any{"catalog_model_key": "test-model"})
									f.original = original
									path, payload := "offers", original
									if entry == "retry" {
										f.require(f.call(f.s, "offers", original), modelAdmissionOfferSubmitted)
										f.s.storeProviderSession(sessionKey(f.p.ProviderID, f.p.AssignedID), f.ps)
										path = "retry"
										payload = f.payload("retry", map[string]any{"catalog_model_key": "test-model"})
									}
									reached := make(chan struct{})
									resume, release := admissionHTTPGate(t)
									committed := make(chan struct{})
									finish, releaseFinish := admissionHTTPGate(t)
									var once, commitOnce sync.Once
									pause := func() { once.Do(func() { close(reached); <-resume }) }
									var attempted ModelAdmissionEvent
									wrapped.beforePositive = func(e ModelAdmissionEvent) {
										if e.State == boundary {
											attempted = e
											if order == "invalidate-first" {
												pause()
											}
										}
									}
									if order == "guard-first" {
										wrapped.afterGuard = pause
									}
									if order == "post-insert" {
										base.(*SQLiteModelAdmissionStore).commitTestHooks = &modelAdmissionCommitTestHooks{afterInsert: func() error {
											if wrapped.inTarget.Load() {
												pause()
											}
											return nil
										}}
									}
									wrapped.afterPositive = func(e ModelAdmissionEvent) {
										if e.State == boundary {
											commitOnce.Do(func() { close(committed); <-finish })
										}
									}
									result := make(chan admissionHTTPResult, 1)
									go func() { result <- f.call(f.s, path, payload) }()
									admissionReadbackWait(t, reached)
									admissionReadbackWait(t, probeCompleted)
									mutated := make(chan struct{})
									go func() { mutate(); close(mutated) }()
									if order == "invalidate-first" {
										admissionReadbackWait(t, mutated)
										releaseFinish()
										release()
									} else {
										deadline := time.Now().Add(3 * time.Second)
										for {
											if pending() {
												break
											}
											if time.Now().After(deadline) {
												t.Fatal("real owner writer never reached held authority pin")
											}
											runtime.Gosched()
										}
										select {
										case <-mutated:
											t.Fatal("owner publication completed while full store guard held")
										default:
										}
										release()
										admissionReadbackWait(t, committed)
										admissionReadbackWait(t, mutated)
										releaseFinish()
									}
									assertAdmissionHTTPNonPositive(t, admissionReadbackReceive(t, result))
									history := admissionReadbackHistory(t, base, f.candidate)
									expectedStates := []string{modelAdmissionOfferSubmitted, "sandbox_probe_only", "network_admitted_unsettled"}
									if boundary == "settlement_capable" || order != "invalidate-first" {
										expectedStates = append(expectedStates, "catalog_priced")
									}
									if boundary == "settlement_capable" && order != "invalidate-first" {
										expectedStates = append(expectedStates, "settlement_capable")
									}
									if len(expectedStates) > 3 {
										expectedStates = append(expectedStates, modelAdmissionRevoked)
									}
									assertAdmissionHTTPHistory(t, history, expectedStates)
									if f.latest(base).CoordinatorEventID != history[len(history)-1].CoordinatorEventID {
										t.Fatal("latest differs from complete history")
									}

									positives := 0
									for _, e := range history {
										if artifactPositive(e) {
											positives++
										}
									}
									want := 0
									if boundary == "settlement_capable" {
										want++
									}
									if order != "invalidate-first" {
										want++
									}
									if positives != want {
										t.Fatalf("positive history=%d want=%d: %+v", positives, want, history)
									}
									if order == "invalidate-first" {
										assertReadbackReplayKeysAbsent(t, base, attempted)
									}
									reservations := admissionReadbackRetries(t, base)
									assertAdmissionHTTPNonPositive(t, f.call(f.s, path, payload))
									assertAdmissionHTTPNonPositive(t, f.call(f.s, "status?candidate_id="+f.candidate, nil))
									if !reflect.DeepEqual(history, admissionReadbackHistory(t, base, f.candidate)) {
										t.Fatal("replay/status appended another event")
									}
									if string(reservations) != string(admissionReadbackRetries(t, base)) || f.probes.Load() != 1 {
										t.Fatal("replay changed reservation or repeated probe")
									}
									if route != nil {
										route()
									}
								})
							}
						})
					}
				})
			}
		})
	}
}
