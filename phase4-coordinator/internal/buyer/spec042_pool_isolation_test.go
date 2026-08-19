package buyer

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	"github.com/rs/zerolog"
)

// poolIsolationServer builds a buyer.Server wired with a SPEC-042 Trusted Pool
// registry (WithPoolMembership) so the R005 tenant-isolation gate is live.
// Returns the provider registry (to register providers for the queue/poll
// paths) and the trustpool registry (to seed pool membership/revocation).
func poolIsolationServer(t *testing.T) (*Server, *pool.Registry, *trustpool.Registry) {
	t.Helper()
	registry := pool.NewRegistry(nil)
	tp := trustpool.NewRegistry()
	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithPoolMembership(tp),
	)
	return s, registry, tp
}

func poolProvider(providerID string) pool.Provider {
	return pool.Provider{
		ProviderID:       providerID,
		AssignedID:       "s-" + providerID,
		ModelID:          "model-a",
		State:            pool.StateReady,
		Tier:             pool.TierPinned,
		MaxContextTokens: 50000,
		MaxConcurrency:   1,
		SlotsTotal:       1,
		SlotsFree:        1,
		EndpointURL:      "https://" + providerID + ".example",
		InferencePath:    pool.InferencePathHTTPForwarding,
		LastHeartbeatAt:  time.Now().UTC(),
		ConnectedAt:      time.Now().UTC(),
	}
}

func poolChatReq(poolID string) chatRequest {
	return chatRequest{
		Model:  "model-a",
		raw:    []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`),
		poolID: poolID,
	}
}

// T1/T2 (filter path via slot-queue candidate derivation): a pool non-member
// is dropped and a member is kept; when the pool has no member the candidate
// list is empty (fail closed, no spill).
func TestPoolIsolation_SlotQueueExcludesNonMember(t *testing.T) {
	s, _, tp := poolIsolationServer(t)
	tp.AddMember("P", "member-x")
	checker := &eligibilityCtx{
		s: s, model: "model-a", estimatedTokens: 100,
		tier2Cfg: s.tier2Config(),
		poolID:   "P", poolMembers: tp.Snapshot("P").Members,
	}
	busy := func(id string) pool.Provider {
		p := poolProvider(id)
		p.SlotsFree = 0 // slot-queue eligibility requires a saturated provider
		return p
	}
	providers := []pool.Provider{busy("member-x"), busy("nonmember-z")}
	got := s.slotQueueCandidates(providers, routing.NewExcluded(0), checker)
	if len(got) != 1 || got[0].ProviderID != "member-x" {
		t.Fatalf("slotQueueCandidates = %+v, want only member-x (no spill to non-member)", got)
	}
}

// T5 (pinned/self-route path): a hard pin to a non-member of the selected pool
// MUST be refused fail-closed, never dispatched to the non-member.
func TestPoolIsolation_PinnedNonMemberRejected(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	x := poolProvider("member-x")
	z := poolProvider("nonmember-z")
	registry.Register(&x, nil)
	registry.Register(&z, nil)
	tp.AddMember("P", "member-x") // z is NOT a member

	headers := http.Header{}
	headers.Set("X-MacProvider-Provider", "nonmember-z")
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), headers, nil, "2024-01-01", &forwardState{})
	if routeErr == nil {
		t.Fatal("pin to non-member of pool P was accepted; want fail-closed rejection")
	}
	if routeErr.code != "pool_no_eligible_member" {
		t.Fatalf("route error code = %q, want pool_no_eligible_member", routeErr.code)
	}
}

// A hard pin to a genuine member passes the pool gate (it then proceeds
// through the normal pinned validation).
func TestPoolIsolation_PinnedMemberPassesPoolGate(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	x := poolProvider("member-x")
	registry.Register(&x, nil)
	tp.AddMember("P", "member-x")

	headers := http.Header{}
	headers.Set("X-MacProvider-Provider", "member-x")
	provider, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), headers, nil, "2024-01-01", &forwardState{})
	if routeErr != nil {
		t.Fatalf("pin to pool member rejected: %+v", routeErr)
	}
	if provider.ProviderID != "member-x" {
		t.Fatalf("selected %q, want member-x", provider.ProviderID)
	}
}

// T4 (gen-keyed revocation, R003): a member revoked before selection is not a
// member of the consistent snapshot, so a pin to it is refused at T+epsilon —
// there is no staleness window.
func TestPoolIsolation_RevokedMemberRejectedImmediately(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	x := poolProvider("member-x")
	registry.Register(&x, nil)
	tp.AddMember("P", "member-x")
	tp.Revoke("P", "member-x") // revoked before this request selects

	headers := http.Header{}
	headers.Set("X-MacProvider-Provider", "member-x")
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), headers, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_no_eligible_member" {
		t.Fatalf("revoked member was routable; want pool_no_eligible_member, got %+v", routeErr)
	}
}

// T (slot-queue poll path): the waiter stores only providerID, so a same-ID
// reconnect that is not a pool member must terminate the wait.
func TestPoolIsolation_SlotQueuePollExcludesNonMember(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	z := poolProvider("nonmember-z")
	registry.Register(&z, nil)
	tp.AddMember("P", "member-x") // z is not a member

	w, ok := s.slotQueue.enter("nonmember-z")
	if !ok {
		t.Fatal("enter returned no waiter")
	}
	defer s.slotQueue.leave(w)
	state := &forwardState{poolID: "P", poolMembers: tp.Snapshot("P").Members}
	if _, status := s.pollQueuedProvider(w, "model-a", nil, 100, state); status != queuedProviderTerminal {
		t.Fatalf("poll status = %v, want terminal (non-member off the queue)", status)
	}
}

// T2-ordinary (R005/R010): a non-pinned pool request whose only providers are
// non-members fails closed with the NON-RETRYABLE pool_no_eligible_member, not
// the retryable generic no_provider_available (which would let clients retry a
// terminal condition).
func TestPoolIsolation_OrdinaryNoMember_ReturnsPoolNoEligibleMember(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	z := poolProvider("nonmember-z")
	registry.Register(&z, nil)
	tp.AddPool("P") // pool P exists but has no members; z is a global non-member
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_no_eligible_member" {
		t.Fatalf("ordinary all-non-member: want pool_no_eligible_member, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatalf("pool_no_eligible_member must be non-retryable")
	}
}

// T7-loop (generation fence, R005): the fence is enforced at the top of the
// forwardWithFailover dispatch loop, so a stale pool generation is rejected
// BEFORE any dispatch — covering the retry/failover re-dispatch windows, not
// just the initial selection.
func TestPoolIsolation_LoopFenceRejectsStaleBeforeDispatch(t *testing.T) {
	s, _, tp := poolIsolationServer(t)
	tp.AddMember("P", "member-x")
	startedAt := time.Unix(1716768000, 0)
	// Selection captured generation g; membership then advances -> stale.
	state := &forwardState{poolID: "P", poolGeneration: tp.Generation("P"), poolGenSet: true, faultedRoutes: map[string]struct{}{}}
	tp.Revoke("P", "member-x")
	state.phaseTiming.init(startedAt)
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	w := httptest.NewRecorder()
	rec := s.newBillingRecorder(r, state, startedAt, "rid", "", "", requestlog.AuthenticatedAccount{}, false)
	dispatched := false
	tx := transportCallbacks{
		dispatch: func(http.ResponseWriter, *http.Request, chatRequest, string, string, time.Time, *forwardState, *billingRecorder) (dispatchedAttempt, bool) {
			dispatched = true
			return dispatchedAttempt{}, false
		},
	}
	s.forwardWithFailover(w, r, poolChatReq("P"), "rid", "rid", startedAt, state, nil, rec, tx)
	if dispatched {
		t.Fatal("dispatch ran under a stale pool generation; the loop fence did not fire")
	}
	if w.Code != http.StatusConflict {
		t.Fatalf("status=%d, want 409 (SPEC-042 R010 pool_state_stale)", w.Code)
	}
	if !strings.Contains(w.Body.String(), "pool_state_stale") {
		t.Fatalf("body=%s, want pool_state_stale", w.Body.String())
	}
}

// T7 (generation fence, R005): a request whose fenced generation no longer
// matches the live pool generation (membership changed between selection and
// dispatch) is stale and must be re-selected, not dispatched.
func TestPoolIsolation_GenerationFenceDetectsStale(t *testing.T) {
	s, _, tp := poolIsolationServer(t)
	tp.AddMember("P", "member-x")
	// Selection captured generation g.
	state := &forwardState{poolID: "P", poolGeneration: tp.Generation("P"), poolGenSet: true}
	if s.poolGenerationStale(state) {
		t.Fatal("fresh snapshot must not be stale")
	}
	// A membership change bumps the generation -> the fenced snapshot is stale.
	tp.Revoke("P", "member-x")
	if !s.poolGenerationStale(state) {
		t.Fatal("generation advanced after revocation; fence must report stale")
	}
	// Global requests (no pool) are never fenced.
	if s.poolGenerationStale(&forwardState{}) {
		t.Fatal("global request must never be stale")
	}
}

// T3 (byte-identical global): with no pool selected, a pinned provider is
// served exactly as before — the pool gate is inert.
func TestPoolIsolation_NoPoolSelected_PinnedServed(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	_ = tp
	z := poolProvider("any-provider")
	registry.Register(&z, nil)

	headers := http.Header{}
	headers.Set("X-MacProvider-Provider", "any-provider")
	provider, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq(""), headers, nil, "2024-01-01", &forwardState{})
	if routeErr != nil {
		t.Fatalf("global (no-pool) pinned request rejected: %+v", routeErr)
	}
	if provider.ProviderID != "any-provider" {
		t.Fatalf("selected %q, want any-provider", provider.ProviderID)
	}
}
