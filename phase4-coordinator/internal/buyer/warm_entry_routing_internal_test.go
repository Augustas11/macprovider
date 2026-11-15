package buyer

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// registerWarmEntryProvider registers a session with a SPEC-001-R016 warm
// set: primary model-a with two seats and warm member model-b with one seat
// (memberFree of it free).
func registerWarmEntryProvider(t *testing.T, registry *pool.Registry, providerID string, memberFree int) {
	t.Helper()
	now := time.Now().UTC()
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            "s-" + providerID,
		Hostname:              providerID + ".local",
		ModelID:               "model-a",
		State:                 pool.StateReady,
		Tier:                  pool.TierPinned,
		MaxContextTokens:      50000,
		MaxConcurrency:        2,
		SlotsTotal:            2,
		SlotsFree:             2,
		ThroughputTPSEstimate: 20,
		EndpointURL:           "https://" + providerID + ".example",
		InferencePath:         pool.InferencePathHTTPForwarding,
		LastHeartbeatAt:       now,
		ConnectedAt:           now,
		WarmModels: []pool.WarmModel{
			{ModelID: "model-a", State: pool.WarmModelWarm, Primary: true, Pinned: true, SlotsTotal: 2, SlotsFree: 2, MaxContextTokens: 50000, ThroughputTPSEstimate: 20},
			{ModelID: "model-b", State: pool.WarmModelWarm, SlotsTotal: 1, SlotsFree: memberFree, MaxContextTokens: 50000, ThroughputTPSEstimate: 20},
		},
	}, nil)
}

func warmEntryServer(registry *pool.Registry) *Server {
	s := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	s.slotQueueDeadline = 50 * time.Millisecond
	s.slotQueuePollInterval = time.Millisecond
	return s
}

func warmChatReq(model string) chatRequest {
	return chatRequest{Model: model, raw: []byte(`{"model":"` + model + `","messages":[{"role":"user","content":"hi"}]}`)}
}

func mustEntry(t *testing.T, registry *pool.Registry, providerID, model string) pool.Provider {
	t.Helper()
	entry, ok := registry.ResolveEntry(providerID, "s-"+providerID, model)
	if !ok {
		t.Fatalf("no entry %s/%s", providerID, model)
	}
	return entry
}

func TestWarmEntryRoutingSecondaryModelConsumesOnlyItsSeat(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWarmEntryProvider(t, registry, "pw", 1)
	s := warmEntryServer(registry)

	state := &forwardState{slotReservationsEnabled: true}
	got, routeErr := s.selectProviderExcluding(context.Background(), "rid-b", warmChatReq("model-b"), http.Header{}, nil, "2026-11-15", state)
	if routeErr != nil {
		t.Fatalf("model-b selection rejected: %+v", routeErr)
	}
	if got.ProviderID != "pw" || got.ServedModelID != "model-b" || got.ModelID != "model-b" {
		t.Fatalf("selected %s served=%q model=%q, want pw/model-b", got.ProviderID, got.ServedModelID, got.ModelID)
	}
	if state.queuedSlotProviderID != "pw#model-b" {
		t.Fatalf("reservation key %q, want pw#model-b", state.queuedSlotProviderID)
	}
	state.provider = got
	s.noteProviderAcceptedRequest(state)
	if !state.slotConsumedOnAccept || state.consumedServedModelID != "model-b" {
		t.Fatalf("accept consumed=%v served=%q", state.slotConsumedOnAccept, state.consumedServedModelID)
	}
	member := mustEntry(t, registry, "pw", "model-b")
	primary := mustEntry(t, registry, "pw", "model-a")
	if member.SlotsFree != 0 || member.State != pool.StateBusy {
		t.Fatalf("member slots_free=%d state=%s, want 0 busy", member.SlotsFree, member.State)
	}
	if primary.SlotsFree != 2 || primary.State != pool.StateReady || !primary.RoutingEligible() {
		t.Fatalf("primary slots_free=%d state=%s, want 2 ready", primary.SlotsFree, primary.State)
	}
	if session, _ := registry.Resolve("pw", "s-pw"); session.SlotsFree != 2 || session.State != pool.StateReady {
		t.Fatalf("session slots_free=%d state=%s, want 2 ready", session.SlotsFree, session.State)
	}
	if n := registry.ForwardedInFlightFor("pw", "s-pw", "model-b"); n != 1 {
		t.Fatalf("member in flight=%d, want 1", n)
	}
	if n := registry.ForwardedInFlight("pw", "s-pw"); n != 0 {
		t.Fatalf("session in flight=%d, want 0", n)
	}

	// The full member does not block the primary.
	primaryState := &forwardState{slotReservationsEnabled: true}
	got, routeErr = s.selectProviderExcluding(context.Background(), "rid-a", warmChatReq("model-a"), http.Header{}, nil, "2026-11-15", primaryState)
	if routeErr != nil || got.ServedModelID != "model-a" || primaryState.queuedSlotProviderID != "pw" {
		t.Fatalf("model-a selection served=%q key=%q err=%+v, want model-a on key pw", got.ServedModelID, primaryState.queuedSlotProviderID, routeErr)
	}
	s.releaseQueuedSlotReservation(primaryState)

	// A second model-b request finds the member full and sheds.
	_, routeErr = s.selectProviderExcluding(context.Background(), "rid-b2", warmChatReq("model-b"), http.Header{}, nil, "2026-11-15", &forwardState{slotReservationsEnabled: true})
	if routeErr == nil || routeErr.status != http.StatusTooManyRequests {
		t.Fatalf("second model-b selection: want 429 capacity shed, got %+v", routeErr)
	}

	s.restoreConsumedForwardedSlot(state)
	if member := mustEntry(t, registry, "pw", "model-b"); member.SlotsFree != 1 || registry.ForwardedInFlightFor("pw", "s-pw", "model-b") != 0 {
		t.Fatalf("member after restore slots_free=%d", member.SlotsFree)
	}
	if session, _ := registry.Resolve("pw", "s-pw"); session.SlotsFree != 2 {
		t.Fatalf("session after restore slots_free=%d, want 2", session.SlotsFree)
	}
}

func TestWarmEntryMarkFullStaysOnTheMember(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWarmEntryProvider(t, registry, "pw", 1)
	s := warmEntryServer(registry)
	state := &forwardState{slotReservationsEnabled: true}
	got, routeErr := s.selectProviderExcluding(context.Background(), "rid-b", warmChatReq("model-b"), http.Header{}, nil, "2026-11-15", state)
	if routeErr != nil {
		t.Fatalf("selection rejected: %+v", routeErr)
	}
	state.provider = got
	s.noteProviderAcceptedRequest(state)
	s.markForwardedSlotFull(state)
	if n := registry.ForwardedInFlightFor("pw", "s-pw", "model-b"); n != 0 {
		t.Fatalf("member in flight after refusal=%d, want 0", n)
	}
	if member := mustEntry(t, registry, "pw", "model-b"); member.SlotsFree != 0 {
		t.Fatalf("member slots_free=%d, want 0 until its next heartbeat", member.SlotsFree)
	}
	if session, _ := registry.Resolve("pw", "s-pw"); session.SlotsFree != 2 || session.State != pool.StateReady {
		t.Fatalf("session slots_free=%d state=%s, want 2 ready", session.SlotsFree, session.State)
	}
	if s.requeueAfterQueueFull(&http.Request{Header: http.Header{}}, state) {
		t.Fatal("refusal with nothing open on the member requeued")
	}
	// reconcile never republishes the session hint for a further member.
	state.provider.SlotsFree = 1
	s.reconcileForwardedSlotAvailable(state)
	if session, _ := registry.Resolve("pw", "s-pw"); session.SlotsFree != 2 {
		t.Fatalf("session slots_free=%d after reconcile, want 2", session.SlotsFree)
	}
}

func TestWarmEntrySlotQueueWaiterIsolation(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWarmEntryProvider(t, registry, "pw", 0)
	s := warmEntryServer(registry)
	member := mustEntry(t, registry, "pw", "model-b")
	primary := mustEntry(t, registry, "pw", "model-a")
	if slotKey(member) != "pw#model-b" || slotKey(primary) != "pw" {
		t.Fatalf("slot keys member=%q primary=%q", slotKey(member), slotKey(primary))
	}

	waiter, ok := s.slotQueue.enter(slotKey(member))
	if !ok {
		t.Fatal("member waiter not admitted")
	}
	defer s.slotQueue.leave(waiter)
	// The primary has two free seats; the member's waiter is not granted one.
	state := &forwardState{slotReservationsEnabled: true}
	if _, status := s.pollQueuedProvider(waiter, "model-b", nil, 0, state); status != queuedProviderWait {
		t.Fatalf("member waiter status=%d, want wait", status)
	}
	// The member's waiter does not block the primary's seats.
	if s.slotQueue.blocksProvider(slotKey(primary), s.liveSlotsFree(primary)) {
		t.Fatal("member waiter blocked the primary")
	}
	got, routeErr := s.selectProviderExcluding(context.Background(), "rid-a", warmChatReq("model-a"), http.Header{}, nil, "2026-11-15", &forwardState{slotReservationsEnabled: true})
	if routeErr != nil || got.ServedModelID != "model-a" {
		t.Fatalf("model-a beside a member waiter served=%q err=%+v", got.ServedModelID, routeErr)
	}

	// A seat on the member is granted to its waiter, as that member.
	registry.RestoreForwardedSlotFor("pw", "s-pw", "model-b")
	if member := mustEntry(t, registry, "pw", "model-b"); member.SlotsFree != 1 {
		t.Fatalf("member slots_free=%d after restore, want 1", member.SlotsFree)
	}
	provider, status := s.pollQueuedProvider(waiter, "model-b", nil, 0, state)
	if status != queuedProviderAvailable || provider.ServedModelID != "model-b" {
		t.Fatalf("member waiter status=%d served=%q, want available model-b", status, provider.ServedModelID)
	}
	s.slotQueue.releaseReservation(slotKey(provider))
}

func TestWarmEntryPinsPickTheRequestedModel(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWarmEntryProvider(t, registry, "pw", 1)
	legacy := poolProvider("legacy")
	registry.Register(&legacy, nil)
	s := warmEntryServer(registry)

	for _, pin := range []http.Header{
		{"X-Macprovider-Provider": {"pw"}},
		{"X-Macprovider-Session": {"s-pw"}},
	} {
		for _, model := range []string{"model-a", "model-b"} {
			got, routeErr := s.selectProviderExcluding(context.Background(), "rid", warmChatReq(model), pin, nil, "2026-11-15", &forwardState{})
			if routeErr != nil || got.ProviderID != "pw" || got.ServedModelID != model {
				t.Fatalf("pin %v model %s: got %s/%q err=%+v", pin, model, got.ProviderID, got.ServedModelID, routeErr)
			}
		}
		// A model the pinned provider does not keep warm is refused like a
		// pin to a provider serving another model.
		_, routeErr := s.selectProviderExcluding(context.Background(), "rid", warmChatReq("model-z"), pin, nil, "2026-11-15", &forwardState{})
		if routeErr == nil || routeErr.status != http.StatusNotFound || routeErr.code != "model_not_found" {
			t.Fatalf("pin %v model-z: want 404 model_not_found, got %+v", pin, routeErr)
		}
	}
	// A provider without a warm set pins as before.
	got, routeErr := s.selectProviderExcluding(context.Background(), "rid", warmChatReq("model-a"), http.Header{"X-Macprovider-Provider": {"legacy"}}, nil, "2026-11-15", &forwardState{})
	if routeErr != nil || got.ProviderID != "legacy" || got.ServedModelID != "" {
		t.Fatalf("legacy pin: got %s/%q err=%+v", got.ProviderID, got.ServedModelID, routeErr)
	}
	_, routeErr = s.selectProviderExcluding(context.Background(), "rid", warmChatReq("model-b"), http.Header{"X-Macprovider-Provider": {"legacy"}}, nil, "2026-11-15", &forwardState{})
	if routeErr == nil || routeErr.code != "model_not_found" {
		t.Fatalf("legacy pin to another model: want model_not_found, got %+v", routeErr)
	}
}

func TestWarmEntryStickyIsPerModel(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWarmEntryProvider(t, registry, "pw", 1)
	other := poolProvider("other")
	other.ModelID = "model-b"
	other.SlotsTotal, other.SlotsFree, other.MaxConcurrency = 1, 1, 1
	other.ThroughputTPSEstimate = 20
	registry.Register(&other, nil)
	s := warmEntryServer(registry)
	s.stickyEnabled = true
	headers := http.Header{"X-Macprovider-Internal-Conv": {"conv:abc"}}

	candidates := func() []pool.Provider {
		var out []pool.Provider
		for _, p := range registry.EntrySnapshot() {
			if p.ModelID == "model-b" {
				out = append(out, p)
			}
		}
		if len(out) != 2 {
			t.Fatalf("model-b candidates=%d, want 2", len(out))
		}
		return out
	}

	s.stickyMap.UpdateServed("conv:abc", "", "pw", "model-b", "model-b")
	list := candidates()
	view := s.sortCandidates(list, s.objectiveForRequest(headers, nil))
	list, result, _ := s.applySticky("rid", headers, "model-b", nil, list, view)
	if result != "hit" || list[0].ProviderID != "pw" || list[0].ServedModelID != "model-b" {
		t.Fatalf("sticky to pw/model-b: result=%s first=%s/%q", result, list[0].ProviderID, list[0].ServedModelID)
	}

	// A sticky entry for the provider's other model is not a hit for this one.
	s.stickyMap.UpdateServed("conv:abc", "", "pw", "model-a", "model-a")
	list = candidates()
	view = s.sortCandidates(list, s.objectiveForRequest(headers, nil))
	_, result, reason := s.applySticky("rid", headers, "model-b", nil, list, view)
	if result != "miss" || reason != "provider_not_candidate" {
		t.Fatalf("sticky to pw/model-a for model-b: result=%s reason=%s, want miss provider_not_candidate", result, reason)
	}

	// stickyStore records the served entry.
	member := mustEntry(t, registry, "pw", "model-b")
	s.stickyStore(headers, member, "model-b")
	if entry, ok, _ := s.stickyLookup("conv:abc"); !ok || entry.ProviderID != "pw" || entry.ServedModelID != "model-b" {
		t.Fatalf("stored sticky entry=%+v ok=%v", entry, ok)
	}
	s.stickyStore(headers, other, "model-b")
	if entry, _, _ := s.stickyLookup("conv:abc"); entry.ProviderID != "other" || entry.ServedModelID != "" {
		t.Fatalf("legacy sticky entry=%+v, want other with no served model", entry)
	}
}

// SPEC-002-R011: a preflight_ack model_not_loaded from a warm entry closes
// that entry until its next heartbeat and selection moves to the next
// candidate; with no other candidate the answer is today's no-provider one.
func TestWarmEntryPreflightModelNotLoadedFailsOver(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWarmEntryProvider(t, registry, "pw", 1)
	s := warmEntryServer(registry)
	s.preflightThreshold = 1
	s.preflightTimeout = time.Second
	s.preflight = func(p pool.Provider, _ string, _ int, _ time.Duration) (PreflightResult, bool, error) {
		if p.ProviderID == "pw" && p.ServedModelID == "model-b" {
			return PreflightResult{Accepted: false, Reason: "model_not_loaded"}, true, nil
		}
		return PreflightResult{Accepted: true}, true, nil
	}

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", warmChatReq("model-b"), http.Header{}, nil, "2026-11-15", &forwardState{slotReservationsEnabled: true})
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" || routeErr.message != "No provider available for model model-b" {
		t.Fatalf("exhausted preflight = %+v, want 503 no_provider_available for model-b", routeErr)
	}
	if member := mustEntry(t, registry, "pw", "model-b"); member.RoutingEligible() {
		t.Fatalf("member after preflight model_not_loaded = %s, want unavailable", member.State)
	}
	if primary := mustEntry(t, registry, "pw", "model-a"); !primary.RoutingEligible() {
		t.Fatalf("primary after member model_not_loaded = %s, want routable", primary.State)
	}
	// No candidate left: the same answer a request gets with no provider.
	_, again := s.selectProviderExcluding(context.Background(), "rid-2", warmChatReq("model-b"), http.Header{}, nil, "2026-11-15", &forwardState{slotReservationsEnabled: true})
	if again == nil || again.status != routeErr.status || again.code != routeErr.code || again.message != routeErr.message {
		t.Fatalf("no-candidate answer = %+v, want %+v", again, routeErr)
	}

	now := time.Now().UTC()
	registry.Register(&pool.Provider{
		ProviderID: "p2", AssignedID: "s-p2", Hostname: "p2.local", ModelID: "model-b",
		State: pool.StateReady, Tier: pool.TierPinned, MaxContextTokens: 50000,
		MaxConcurrency: 1, SlotsTotal: 1, SlotsFree: 1, ThroughputTPSEstimate: 10,
		EndpointURL: "https://p2.example", InferencePath: pool.InferencePathHTTPForwarding,
		LastHeartbeatAt: now, ConnectedAt: now,
	}, nil)
	got, routeErr := s.selectProviderExcluding(context.Background(), "rid-3", warmChatReq("model-b"), http.Header{}, nil, "2026-11-15", &forwardState{slotReservationsEnabled: true})
	if routeErr != nil || got.ProviderID != "p2" {
		t.Fatalf("failover provider=%q err=%+v, want p2", got.ProviderID, routeErr)
	}
}
