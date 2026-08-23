package buyer

import (
	"context"
	"net/http"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

func poolChatReqModel(poolID, model string) chatRequest {
	return chatRequest{
		Model:  model,
		raw:    []byte(`{"model":"` + model + `","messages":[{"role":"user","content":"hi"}]}`),
		poolID: poolID,
	}
}

func TestPoolModelAllowlist_DisallowedFailsClosed(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	member := poolProvider("member-a")
	registry.Register(&member, nil)
	tp.AddMember("P", "member-a")
	if err := tp.SetModelAllowlist("P", []string{"model-b"}); err != nil {
		t.Fatalf("SetModelAllowlist: %v", err)
	}

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.status != http.StatusBadRequest || routeErr.code != "pool_model_not_allowed" {
		t.Fatalf("disallowed model: want 400 pool_model_not_allowed, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatal("pool_model_not_allowed must be non-retryable")
	}
}

func TestPoolModelAllowlist_AllowedServed(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	member := poolProvider("member-a")
	registry.Register(&member, nil)
	tp.AddMember("P", "member-a")
	if err := tp.SetModelAllowlist("P", []string{"model-a"}); err != nil {
		t.Fatalf("SetModelAllowlist: %v", err)
	}

	provider, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr != nil {
		t.Fatalf("allowed model rejected: %+v", routeErr)
	}
	if provider.ProviderID != "member-a" {
		t.Fatalf("selected %q, want member-a", provider.ProviderID)
	}
}

func TestPoolModelAllowlist_EmptyAndGlobalInert(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	member := poolProvider("member-a")
	global := poolProvider("global-a")
	global.ProviderID = "global-a"
	global.AssignedID = "s-global-a"
	registry.Register(&member, nil)
	registry.Register(&global, nil)
	tp.AddMember("P", "member-a")

	provider, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr != nil || provider.ProviderID != "member-a" {
		t.Fatalf("floorless allowlist pool result provider=%q err=%+v, want member-a nil", provider.ProviderID, routeErr)
	}
	if err := tp.SetModelAllowlist("P", []string{"model-b"}); err != nil {
		t.Fatalf("SetModelAllowlist: %v", err)
	}
	provider, routeErr = s.selectProviderExcluding(context.Background(), "rid-global", poolChatReq(""), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr != nil {
		t.Fatalf("global request was affected by pool allowlist: %+v", routeErr)
	}
	if provider.ProviderID == "" {
		t.Fatal("global request selected no provider")
	}
}

func TestPoolModelAllowlist_PinnedDisallowedRejected(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	member := poolProvider("member-a")
	registry.Register(&member, nil)
	tp.AddMember("P", "member-a")
	if err := tp.SetModelAllowlist("P", []string{"model-b"}); err != nil {
		t.Fatalf("SetModelAllowlist: %v", err)
	}

	headers := http.Header{}
	headers.Set("X-MacProvider-Provider", "member-a")
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), headers, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_model_not_allowed" {
		t.Fatalf("pin to disallowed model: want pool_model_not_allowed, got %+v", routeErr)
	}
}

func TestPoolModelAllowlist_SlotQueueExcludesDisallowed(t *testing.T) {
	s, _, tp := poolIsolationServer(t)
	tp.AddMember("P", "member-a")
	if err := tp.SetModelAllowlist("P", []string{"model-b"}); err != nil {
		t.Fatalf("SetModelAllowlist: %v", err)
	}
	snap := tp.Snapshot("P")
	checker := &eligibilityCtx{
		s: s, model: "model-a", estimatedTokens: 100,
		tier2Cfg:             s.tier2Config(),
		poolID:               "P",
		poolMembers:          snap.Members,
		poolModelAllowlist:   snap.ModelAllowlist,
		poolMinBinaryVersion: snap.MinBinaryVersion,
	}
	busy := poolProvider("member-a")
	busy.SlotsFree = 0
	got := s.slotQueueCandidates([]pool.Provider{busy}, routing.NewExcluded(0), checker)
	if len(got) != 0 {
		t.Fatalf("slotQueueCandidates = %+v, want no candidates for disallowed model", got)
	}
}

func TestPoolModelAllowlist_SlotQueuePollExcludesDisallowed(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	member := poolProvider("member-a")
	registry.Register(&member, nil)
	tp.AddMember("P", "member-a")
	if err := tp.SetModelAllowlist("P", []string{"model-b"}); err != nil {
		t.Fatalf("SetModelAllowlist: %v", err)
	}

	w, ok := s.slotQueue.enter("member-a")
	if !ok {
		t.Fatal("enter returned no waiter")
	}
	defer s.slotQueue.leave(w)
	snap := tp.Snapshot("P")
	state := &forwardState{poolID: "P", poolMembers: snap.Members, poolModelAllowlist: snap.ModelAllowlist}
	if _, status := s.pollQueuedProvider(w, "model-a", nil, 100, state); status != queuedProviderTerminal {
		t.Fatalf("poll status = %v, want terminal for disallowed model", status)
	}
}

func TestPoolModelAllowlist_ClassRequestRequiresWholeClassAllowed(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	member := poolProvider("member-a")
	registry.Register(&member, nil)
	tp.AddMember("P", "member-a")
	s.SetRoutingClasses(map[string]config.ModelClassConfig{
		"fast-class": {Members: []string{"model-a", "model-b"}},
	})
	if err := tp.SetModelAllowlist("P", []string{"model-a"}); err != nil {
		t.Fatalf("SetModelAllowlist partial: %v", err)
	}

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReqModel("P", "fast-class"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_model_not_allowed" {
		t.Fatalf("partial class allowlist: want pool_model_not_allowed, got %+v", routeErr)
	}
	if err := tp.SetModelAllowlist("P", []string{"fast-class"}); err != nil {
		t.Fatalf("SetModelAllowlist alias only: %v", err)
	}
	_, routeErr = s.selectProviderExcluding(context.Background(), "rid-alias", poolChatReqModel("P", "fast-class"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_model_not_allowed" {
		t.Fatalf("class alias allowlist: want pool_model_not_allowed, got %+v", routeErr)
	}
	if err := tp.SetModelAllowlist("P", []string{"model-a", "model-b"}); err != nil {
		t.Fatalf("SetModelAllowlist full: %v", err)
	}
	provider, routeErr := s.selectProviderExcluding(context.Background(), "rid2", poolChatReqModel("P", "fast-class"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr != nil || provider.ProviderID != "member-a" {
		t.Fatalf("full class allowlist provider=%q err=%+v, want member-a nil", provider.ProviderID, routeErr)
	}
}
