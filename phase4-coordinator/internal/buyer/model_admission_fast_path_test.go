package buyer

import (
	"context"
	"net/http"
	"sync/atomic"
	"testing"

	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

type routeStatusCountingAdmissionStore struct {
	providerws.ModelAdmissionStore
	empty            atomic.Bool
	found            atomic.Bool
	generation       atomic.Uint64
	routeStatusCalls atomic.Int64
	afterRouteStatus func()
}

type routeStatusGenerationGuard struct {
	generation atomic.Uint64
}

func (g *routeStatusGenerationGuard) ModelAdmissionBindingGeneration(string) uint64 {
	return g.generation.Load()
}

func (g *routeStatusGenerationGuard) CompareAndInsertModelAdmissionRouteSnapshot(context.Context, providerws.ModelAdmissionRouteExpectation, func() error) error {
	return nil
}

func (s *routeStatusCountingAdmissionStore) ModelAdmissionEventsEmpty(context.Context) (bool, error) {
	return s.empty.Load(), nil
}

func (s *routeStatusCountingAdmissionStore) LatestModelAdmissionRouteStatus(context.Context, string, string, string) (providerws.ModelAdmissionEvent, bool, error) {
	s.routeStatusCalls.Add(1)
	if s.afterRouteStatus != nil {
		s.afterRouteStatus()
	}
	return providerws.ModelAdmissionEvent{}, s.found.Load(), nil
}

func (s *routeStatusCountingAdmissionStore) ModelAdmissionProviderRouteGeneration(context.Context, string) (uint64, error) {
	return s.generation.Load(), nil
}

func TestEmptyModelAdmissionStoreSkipsLegacyRouteStatusLookup(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{}
	store.empty.Store(true)
	s.modelAdmissionStore = store
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)
	another := poolProvider("p-two")
	registry.Register(&another, nil)

	got, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})
	if routeErr != nil {
		t.Fatalf("empty model-admission store rejected ordinary provider: %+v", routeErr)
	}
	if got.ProviderID != provider.ProviderID && got.ProviderID != another.ProviderID {
		t.Fatalf("selected provider %q, want one of the ordinary registered providers", got.ProviderID)
	}
	if calls := store.routeStatusCalls.Load(); calls != 0 {
		t.Fatalf("LatestModelAdmissionRouteStatus calls = %d, want 0 for empty store fast path", calls)
	}
}

func TestNonEmptyModelAdmissionStoreKeepsLegacyRouteStatusGate(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{}
	store.empty.Store(false)
	store.found.Store(true)
	s.modelAdmissionStore = store
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable {
		t.Fatalf("unbound provider with an admission record was not excluded fail-closed: %+v", routeErr)
	}
	if calls := store.routeStatusCalls.Load(); calls == 0 {
		t.Fatal("LatestModelAdmissionRouteStatus was not called once store is non-empty")
	}
}

func TestLegacyModelAdmissionRouteStatusCachesByRouteGeneration(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{}
	store.empty.Store(false)
	store.found.Store(false)
	s.modelAdmissionStore = store
	guard := &routeStatusGenerationGuard{}
	s.modelAdmissionRouteGuard = guard
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)

	for i := 0; i < 2; i++ {
		got, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})
		if routeErr != nil {
			t.Fatalf("selection %d rejected ordinary provider: %+v", i, routeErr)
		}
		if got.ProviderID != provider.ProviderID {
			t.Fatalf("selection %d provider=%q, want %q", i, got.ProviderID, provider.ProviderID)
		}
	}
	if calls := store.routeStatusCalls.Load(); calls != 1 {
		t.Fatalf("LatestModelAdmissionRouteStatus calls = %d, want 1 for unchanged provider generation", calls)
	}

	guard.generation.Add(1)
	registry.Register(&provider, nil)
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{}); routeErr != nil {
		t.Fatalf("selection after generation change rejected ordinary provider: %+v", routeErr)
	}
	if calls := store.routeStatusCalls.Load(); calls != 2 {
		t.Fatalf("LatestModelAdmissionRouteStatus calls = %d, want generation change to miss cache", calls)
	}
}

func TestLegacyModelAdmissionRouteStatusCacheFailsClosedAfterAppendGeneration(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{}
	store.empty.Store(false)
	store.found.Store(false)
	s.modelAdmissionStore = store
	guard := &routeStatusGenerationGuard{}
	s.modelAdmissionRouteGuard = guard
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)

	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{}); routeErr != nil {
		t.Fatalf("first selection rejected ordinary provider: %+v", routeErr)
	}
	if calls := store.routeStatusCalls.Load(); calls != 1 {
		t.Fatalf("LatestModelAdmissionRouteStatus calls = %d, want first route to populate cache", calls)
	}

	store.found.Store(true)
	store.generation.Add(1)
	guard.generation.Add(1)
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable {
		t.Fatalf("route after admission append generation did not fail closed: %+v", routeErr)
	}
	if calls := store.routeStatusCalls.Load(); calls != 2 {
		t.Fatalf("LatestModelAdmissionRouteStatus calls = %d, want cache miss after append generation", calls)
	}
}

func TestLegacyModelAdmissionRouteStatusCacheFailsClosedAfterStoreGeneration(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{}
	store.empty.Store(false)
	store.found.Store(false)
	s.modelAdmissionStore = store
	guard := &routeStatusGenerationGuard{}
	s.modelAdmissionRouteGuard = guard
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)

	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{}); routeErr != nil {
		t.Fatalf("first selection rejected ordinary provider: %+v", routeErr)
	}
	if calls := store.routeStatusCalls.Load(); calls != 1 {
		t.Fatalf("LatestModelAdmissionRouteStatus calls = %d, want first route to populate cache", calls)
	}

	store.found.Store(true)
	store.generation.Add(1)
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable {
		t.Fatalf("route after store generation change did not fail closed: %+v", routeErr)
	}
	if calls := store.routeStatusCalls.Load(); calls != 2 {
		t.Fatalf("LatestModelAdmissionRouteStatus calls = %d, want cache miss after store generation", calls)
	}
}

func TestLegacyModelAdmissionRouteStatusCacheSkipsStoreWhenGenerationMovesDuringRead(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{}
	store.empty.Store(false)
	store.found.Store(false)
	s.modelAdmissionStore = store
	guard := &routeStatusGenerationGuard{}
	s.modelAdmissionRouteGuard = guard
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)

	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{}); routeErr != nil {
		t.Fatalf("first selection rejected ordinary provider: %+v", routeErr)
	}
	if calls := store.routeStatusCalls.Load(); calls != 1 {
		t.Fatalf("LatestModelAdmissionRouteStatus calls = %d, want first route to populate cache", calls)
	}

	guard.generation.Add(1)
	store.afterRouteStatus = func() {
		guard.generation.Add(1)
	}
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{}); routeErr != nil {
		t.Fatalf("selection with generation move during read rejected ordinary provider: %+v", routeErr)
	}
	callsAfterRace := store.routeStatusCalls.Load()
	if callsAfterRace <= 1 {
		t.Fatalf("LatestModelAdmissionRouteStatus calls = %d, want durable read after generation advanced", callsAfterRace)
	}

	store.afterRouteStatus = nil
	store.found.Store(true)
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid-3", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable {
		t.Fatalf("route after generation-race read did not query store and fail closed: %+v", routeErr)
	}
	if calls := store.routeStatusCalls.Load(); calls <= callsAfterRace {
		t.Fatalf("LatestModelAdmissionRouteStatus calls = %d, want stale read not cached under new generation", calls)
	}
}
