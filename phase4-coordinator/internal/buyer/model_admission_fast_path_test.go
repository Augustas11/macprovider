package buyer

import (
	"context"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

type routeStatusCountingAdmissionStore struct {
	providerws.ModelAdmissionStore
	empty                     atomic.Bool
	found                     atomic.Bool
	generation                atomic.Uint64
	routeStatusCalls          atomic.Int64
	afterRouteStatus          func()
	waitRouteStatusForContext bool
	routeStatusErr            error
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

func (s *routeStatusCountingAdmissionStore) LatestModelAdmissionRouteStatus(ctx context.Context, _, _, _ string) (providerws.ModelAdmissionEvent, bool, error) {
	s.routeStatusCalls.Add(1)
	if s.afterRouteStatus != nil {
		s.afterRouteStatus()
	}
	if s.waitRouteStatusForContext {
		<-ctx.Done()
		return providerws.ModelAdmissionEvent{}, false, ctx.Err()
	}
	if s.routeStatusErr != nil {
		return providerws.ModelAdmissionEvent{}, false, s.routeStatusErr
	}
	return providerws.ModelAdmissionEvent{}, s.found.Load(), nil
}

func (s *routeStatusCountingAdmissionStore) ModelAdmissionProviderRouteGeneration(context.Context, string) (uint64, error) {
	return s.generation.Load(), nil
}

func assertRouteSnapshotPressureRouteErr(t *testing.T, routeErr *routeError) {
	t.Helper()
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" || !routeErr.routeSnapshotPressure {
		t.Fatalf("routeErr=%+v, want route-snapshot-pressure no_provider_available", routeErr)
	}
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

func TestLegacyModelAdmissionSelectionPressureUsesSharedRetryableBudget(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{waitRouteStatusForContext: true}
	store.empty.Store(false)
	s.modelAdmissionStore = store
	for _, id := range []string{"p-one", "p-two", "p-three"} {
		provider := poolProvider(id)
		registry.Register(&provider, nil)
	}

	started := time.Now()
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})
	elapsed := time.Since(started)

	assertRouteSnapshotPressureRouteErr(t, routeErr)
	if elapsed > 2*routeSnapshotDispatchTimeout {
		t.Fatalf("selection elapsed=%s, want bounded by shared admission budget %s", elapsed, routeSnapshotDispatchTimeout)
	}
	if calls := store.routeStatusCalls.Load(); calls < 2 {
		t.Fatalf("LatestModelAdmissionRouteStatus calls=%d, want multiple candidates sharing one expired context", calls)
	}
}

func TestLegacyModelAdmissionPinnedPressureUsesRetryableBudget(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{waitRouteStatusForContext: true}
	store.empty.Store(false)
	s.modelAdmissionStore = store
	provider := poolProvider("p-pinned")
	registry.Register(&provider, nil)

	started := time.Now()
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq(""), http.Header{
		"X-MacProvider-Provider": []string{provider.ProviderID},
	}, nil, "2026-09-15", &forwardState{})
	elapsed := time.Since(started)

	assertRouteSnapshotPressureRouteErr(t, routeErr)
	if elapsed > 2*routeSnapshotDispatchTimeout {
		t.Fatalf("pinned selection elapsed=%s, want bounded by admission budget %s", elapsed, routeSnapshotDispatchTimeout)
	}
}

func TestLegacyModelAdmissionPinnedSessionPressureUsesRetryableBudget(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{waitRouteStatusForContext: true}
	store.empty.Store(false)
	s.modelAdmissionStore = store
	provider := poolProvider("p-session")
	registry.Register(&provider, nil)

	started := time.Now()
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq(""), http.Header{
		"X-MacProvider-Session": []string{provider.AssignedID},
	}, nil, "2026-09-15", &forwardState{})
	elapsed := time.Since(started)

	assertRouteSnapshotPressureRouteErr(t, routeErr)
	if elapsed > 2*routeSnapshotDispatchTimeout {
		t.Fatalf("pinned session selection elapsed=%s, want bounded by admission budget %s", elapsed, routeSnapshotDispatchTimeout)
	}
}

func TestLegacyModelAdmissionSelectionCancellationUsesRequestCanceled(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{waitRouteStatusForContext: true}
	store.empty.Store(false)
	s.modelAdmissionStore = store
	provider := poolProvider("p-canceled")
	registry.Register(&provider, nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, routeErr := s.selectProviderExcluding(ctx, "rid", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})

	if routeErr == nil || routeErr.status != statusClientClosedRequest || routeErr.code != "request_canceled" {
		t.Fatalf("routeErr=%+v, want request_canceled", routeErr)
	}
}

func TestLegacyModelAdmissionPinnedCancellationUsesRequestCanceled(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{waitRouteStatusForContext: true}
	store.empty.Store(false)
	s.modelAdmissionStore = store
	provider := poolProvider("p-pinned-canceled")
	registry.Register(&provider, nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, routeErr := s.selectProviderExcluding(ctx, "rid", poolChatReq(""), http.Header{
		"X-MacProvider-Provider": []string{provider.ProviderID},
	}, nil, "2026-09-15", &forwardState{})

	if routeErr == nil || routeErr.status != statusClientClosedRequest || routeErr.code != "request_canceled" {
		t.Fatalf("routeErr=%+v, want request_canceled", routeErr)
	}
}

func TestLegacyModelAdmissionQueuedSelectionCancellationUsesRequestCanceled(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{}
	store.empty.Store(true)
	s.modelAdmissionStore = store
	provider := poolProvider("p-queued-canceled")
	provider.SlotsFree = 0
	registry.Register(&provider, nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, routeErr := s.selectProviderExcluding(ctx, "rid", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})

	if routeErr == nil || routeErr.status != statusClientClosedRequest || routeErr.code != "request_canceled" {
		t.Fatalf("routeErr=%+v, want request_canceled from queue wait", routeErr)
	}
}

func TestLegacyModelAdmissionQueuePressureUsesRetryableBudget(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{waitRouteStatusForContext: true}
	store.empty.Store(false)
	s.modelAdmissionStore = store
	provider := poolProvider("p-queued")
	registry.Register(&provider, nil)
	waiter, ok := s.slotQueue.enter(provider.ProviderID)
	if !ok {
		t.Fatal("enter returned no waiter")
	}
	defer s.slotQueue.leave(waiter)

	started := time.Now()
	_, status := s.pollQueuedProviderWithContext(context.Background(), waiter, provider.ModelID, nil, 100, &forwardState{})
	elapsed := time.Since(started)

	if status != queuedProviderAdmissionStorePressure {
		t.Fatalf("queue status=%v, want admission store pressure", status)
	}
	if elapsed > 2*routeSnapshotDispatchTimeout {
		t.Fatalf("queue poll elapsed=%s, want bounded by admission budget %s", elapsed, routeSnapshotDispatchTimeout)
	}
}

func TestLegacyModelAdmissionQueueWaitsForSlotBeforeStorePressure(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{waitRouteStatusForContext: true}
	store.empty.Store(false)
	s.modelAdmissionStore = store
	provider := poolProvider("p-queued-full")
	provider.SlotsFree = 0
	registry.Register(&provider, nil)
	waiter, ok := s.slotQueue.enter(provider.ProviderID)
	if !ok {
		t.Fatal("enter returned no waiter")
	}
	defer s.slotQueue.leave(waiter)

	_, status := s.pollQueuedProviderWithContext(context.Background(), waiter, provider.ModelID, nil, 100, &forwardState{})

	if status != queuedProviderWait {
		t.Fatalf("queue status=%v, want wait while provider has no free slot", status)
	}
	if calls := store.routeStatusCalls.Load(); calls != 0 {
		t.Fatalf("LatestModelAdmissionRouteStatus calls=%d, want no admission-store read before a slot is free", calls)
	}
}

func TestLegacyModelAdmissionQueuedSelectionDoesNotReadStoreWhileSaturated(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{waitRouteStatusForContext: true}
	store.empty.Store(false)
	s.modelAdmissionStore = store
	s.slotQueueDeadline = 40 * time.Millisecond
	s.slotQueuePollInterval = 5 * time.Millisecond
	provider := poolProvider("p-queued-full")
	provider.SlotsFree = 0
	registry.Register(&provider, nil)

	started := time.Now()
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})
	elapsed := time.Since(started)

	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" {
		t.Fatalf("routeErr=%+v, want bounded queue no_provider_available", routeErr)
	}
	if routeErr.routeSnapshotPressure {
		t.Fatalf("routeErr=%+v, want saturated queue timeout without route-snapshot pressure marker", routeErr)
	}
	if elapsed > routeSnapshotDispatchTimeout {
		t.Fatalf("queued selection elapsed=%s, want queue deadline to win before admission budget %s", elapsed, routeSnapshotDispatchTimeout)
	}
	if calls := store.routeStatusCalls.Load(); calls != 0 {
		t.Fatalf("LatestModelAdmissionRouteStatus calls=%d, want no admission-store read while provider stays saturated", calls)
	}
}

func TestLegacyModelAdmissionPressureShedsBeforeMixedSaturatedQueueWait(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{waitRouteStatusForContext: true}
	store.empty.Store(false)
	s.modelAdmissionStore = store
	s.slotQueueDeadline = 2 * time.Second
	s.slotQueuePollInterval = 5 * time.Millisecond
	pressured := poolProvider("p-pressure")
	registry.Register(&pressured, nil)
	saturated := poolProvider("p-queued-full")
	saturated.SlotsFree = 0
	registry.Register(&saturated, nil)

	started := time.Now()
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})
	elapsed := time.Since(started)

	assertRouteSnapshotPressureRouteErr(t, routeErr)
	if elapsed > 2*routeSnapshotDispatchTimeout {
		t.Fatalf("mixed pressure+queue elapsed=%s, want pressure budget to win before queue deadline %s", elapsed, s.slotQueueDeadline)
	}
}

func TestLegacyModelAdmissionPressureOutranksMixedFleetTerminalError(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{waitRouteStatusForContext: true}
	store.empty.Store(false)
	s.modelAdmissionStore = store
	ready := poolProvider("p-ready")
	registry.Register(&ready, nil)
	tooSmall := poolProvider("p-small")
	tooSmall.MaxContextTokens = 1
	registry.Register(&tooSmall, nil)

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})
	assertRouteSnapshotPressureRouteErr(t, routeErr)
}

func TestLegacyModelAdmissionPressurePreservesPinnedExactModelAgainstClassFallback(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{waitRouteStatusForContext: true}
	store.empty.Store(false)
	s.modelAdmissionStore = store
	s.SetRoutingClasses(map[string]config.ModelClassConfig{
		"model-a": {Models: []string{"model-b"}, Objective: "fast"},
	})
	provider := poolProvider("p-pinned-exact")
	registry.Register(&provider, nil)
	tp.AddMember("P", provider.ProviderID)
	if err := tp.SetModelAllowlist("P", []string{"model-a"}); err != nil {
		t.Fatalf("SetModelAllowlist: %v", err)
	}

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{
		"X-MacProvider-Provider": []string{provider.ProviderID},
	}, nil, "2026-09-15", &forwardState{})
	assertRouteSnapshotPressureRouteErr(t, routeErr)
}

func TestLegacyModelAdmissionPressurePreservesPinnedSessionExactModelAgainstClassFallback(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	store := &routeStatusCountingAdmissionStore{waitRouteStatusForContext: true}
	store.empty.Store(false)
	s.modelAdmissionStore = store
	s.SetRoutingClasses(map[string]config.ModelClassConfig{
		"model-a": {Models: []string{"model-b"}, Objective: "fast"},
	})
	provider := poolProvider("p-session-exact")
	registry.Register(&provider, nil)
	tp.AddMember("P", provider.ProviderID)
	if err := tp.SetModelAllowlist("P", []string{"model-a"}); err != nil {
		t.Fatalf("SetModelAllowlist: %v", err)
	}

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{
		"X-MacProvider-Session": []string{provider.AssignedID},
	}, nil, "2026-09-15", &forwardState{})
	assertRouteSnapshotPressureRouteErr(t, routeErr)
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
