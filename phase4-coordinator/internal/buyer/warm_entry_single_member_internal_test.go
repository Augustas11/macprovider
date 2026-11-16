package buyer

import (
	"context"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// registerOneMemberTwin registers provider pw serving model-a on registry,
// with a warm set of exactly one member when single is set.
func registerOneMemberTwin(registry *pool.Registry, single bool) {
	now := time.Now().UTC()
	p := &pool.Provider{
		ProviderID: "pw", AssignedID: "s-pw", Hostname: "pw.local", ModelID: "model-a",
		State: pool.StateReady, Tier: pool.TierPinned, MaxContextTokens: 50000,
		MaxConcurrency: 2, SlotsTotal: 2, SlotsFree: 2, ThroughputTPSEstimate: 20,
		EndpointURL: "https://pw.example", InferencePath: pool.InferencePathHTTPForwarding,
		LastHeartbeatAt: now, ConnectedAt: now,
	}
	if single {
		p.WarmModels = []pool.WarmModel{{ModelID: "model-a", State: pool.WarmModelWarm, Primary: true, Pinned: true, SlotsTotal: 2, SlotsFree: 2, MaxContextTokens: 50000, ThroughputTPSEstimate: 20}}
	}
	registry.Register(p, nil)
}

// A preflight_ack model_not_loaded from a provider whose warm set has one
// member takes the legacy path: the same route answer and session state as a
// provider without warm_models, and no served model on the preflight.
func TestWarmSetOfOnePreflightModelNotLoadedIsLegacy(t *testing.T) {
	type outcome struct {
		err     *routeError
		state   pool.State
		served  []string
		entries int
	}
	run := func(single bool) outcome {
		registry := pool.NewRegistry(nil)
		registerOneMemberTwin(registry, single)
		s := warmEntryServer(registry)
		s.preflightThreshold = 1
		s.preflightTimeout = time.Second
		var served []string
		s.preflight = func(p pool.Provider, _ string, _ int, _ time.Duration) (PreflightResult, bool, error) {
			served = append(served, p.ServedModelID)
			return PreflightResult{Accepted: false, Reason: "model_not_loaded"}, true, nil
		}
		_, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", warmChatReq("model-a"), http.Header{}, nil, "2026-11-16", &forwardState{slotReservationsEnabled: true})
		session, _ := registry.Resolve("pw", "s-pw")
		return outcome{err: routeErr, state: session.State, served: served, entries: len(registry.EntrySnapshot())}
	}
	legacy, single := run(false), run(true)
	if !reflect.DeepEqual(legacy, single) {
		t.Fatalf("one-member preflight outcome %+v, legacy %+v", single, legacy)
	}
	if len(single.served) == 0 || single.err == nil {
		t.Fatalf("preflight not exercised: %+v", single)
	}
	for _, served := range single.served {
		if served != "" {
			t.Fatalf("one-member preflight named served model %q", served)
		}
	}
}

// A stored sticky entry without a served model (written for a legacy or
// one-member session) matches the primary entry of a multi-model provider,
// never a further member.
func TestStickyWithoutServedModelMatchesPrimaryEntry(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWarmEntryProvider(t, registry, "pw", 1)
	s := warmEntryServer(registry)
	s.stickyEnabled = true
	headers := http.Header{"X-Macprovider-Internal-Conv": {"conv:abc"}}
	s.stickyMap.UpdateServed("conv:abc", "", "pw", "", "model-a")

	primary := []pool.Provider{mustEntry(t, registry, "pw", "model-a")}
	view := s.sortCandidates(primary, s.objectiveForRequest(headers, nil))
	if _, result, reason := s.applySticky("rid", headers, "model-a", nil, primary, view); result != "hit" {
		t.Fatalf("empty served sticky on the primary entry: result=%s reason=%s, want hit", result, reason)
	}
	member := []pool.Provider{mustEntry(t, registry, "pw", "model-b")}
	view = s.sortCandidates(member, s.objectiveForRequest(headers, nil))
	if _, result, _ := s.applySticky("rid", headers, "model-b", nil, member, view); result != "miss" {
		t.Fatalf("empty served sticky matched a further member: result=%s", result)
	}

	// A sticky entry naming the primary model matches the provider after it
	// drops to a one-member (legacy) session.
	legacy := pool.NewRegistry(nil)
	registerOneMemberTwin(legacy, true)
	s = warmEntryServer(legacy)
	s.stickyEnabled = true
	s.stickyMap.UpdateServed("conv:abc", "", "pw", "MODEL-A", "model-a")
	session, _ := legacy.Resolve("pw", "s-pw")
	list := []pool.Provider{session}
	view = s.sortCandidates(list, s.objectiveForRequest(headers, nil))
	if _, result, reason := s.applySticky("rid", headers, "model-a", nil, list, view); result != "hit" {
		t.Fatalf("served sticky on a legacy session serving it: result=%s reason=%s", result, reason)
	}
}
