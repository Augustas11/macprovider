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
	routeStatusCalls atomic.Int64
}

func (s *routeStatusCountingAdmissionStore) ModelAdmissionEventsEmpty(context.Context) (bool, error) {
	return s.empty.Load(), nil
}

func (s *routeStatusCountingAdmissionStore) LatestModelAdmissionRouteStatus(context.Context, string, string, string) (providerws.ModelAdmissionEvent, bool, error) {
	s.routeStatusCalls.Add(1)
	return providerws.ModelAdmissionEvent{}, true, nil
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
