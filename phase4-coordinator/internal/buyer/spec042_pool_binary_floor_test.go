package buyer

import (
	"context"
	"net/http"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

// poolProviderVer is poolProvider with an explicit binary_version, for the
// SPEC-042 R004/R010 pool binary-floor gate.
func poolProviderVer(providerID, version string) pool.Provider {
	p := poolProvider(providerID)
	p.BinaryVersion = version
	return p
}

// Ordinary filter path: a pool whose only member is below the floor fails
// closed with the non-retryable pool_binary_too_old — never spilling to the
// under-version member or to global (SPEC-042 R004/R010).
func TestPoolBinaryFloor_AllBelowFloor_FailsClosed(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	old := poolProviderVer("member-old", "1.7.0")
	registry.Register(&old, nil)
	tp.AddMember("P", "member-old")
	tp.SetMinBinaryVersion("P", "1.8.0")

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_binary_too_old" {
		t.Fatalf("under-version member: want pool_binary_too_old, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatal("pool_binary_too_old must be non-retryable")
	}
}

// A member at/above the floor passes the gate and is served.
func TestPoolBinaryFloor_AtOrAboveFloor_Served(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	newp := poolProviderVer("member-new", "1.8.0") // exactly the floor
	registry.Register(&newp, nil)
	tp.AddMember("P", "member-new")
	tp.SetMinBinaryVersion("P", "1.8.0")

	provider, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr != nil {
		t.Fatalf("at-floor member rejected: %+v", routeErr)
	}
	if provider.ProviderID != "member-new" {
		t.Fatalf("selected %q, want member-new", provider.ProviderID)
	}
}

// The floor selects the eligible member and drops the under-version one.
func TestPoolBinaryFloor_MixedSelectsEligible(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	old := poolProviderVer("member-old", "1.7.9")
	newp := poolProviderVer("member-new", "1.8.1")
	registry.Register(&old, nil)
	registry.Register(&newp, nil)
	tp.AddMember("P", "member-old")
	tp.AddMember("P", "member-new")
	tp.SetMinBinaryVersion("P", "1.8.0")

	provider, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr != nil {
		t.Fatalf("mixed pool rejected: %+v", routeErr)
	}
	if provider.ProviderID != "member-new" {
		t.Fatalf("selected %q, want member-new (member-old is below floor)", provider.ProviderID)
	}
}

// An empty/unparseable binary_version while a floor is in force is treated as
// below the floor (fail-safe), so such a member is excluded.
func TestPoolBinaryFloor_EmptyVersionExcluded(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	blank := poolProviderVer("member-blank", "") // no version reported
	registry.Register(&blank, nil)
	tp.AddMember("P", "member-blank")
	tp.SetMinBinaryVersion("P", "1.8.0")

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_binary_too_old" {
		t.Fatalf("empty-version member: want pool_binary_too_old, got %+v", routeErr)
	}
}

// No floor configured for the pool -> the gate is a strict no-op; a member is
// served regardless of its (low) binary version.
func TestPoolBinaryFloor_NoFloorInert(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	old := poolProviderVer("member-old", "1.0.0")
	registry.Register(&old, nil)
	tp.AddMember("P", "member-old") // no SetMinBinaryVersion -> floor ""

	provider, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr != nil {
		t.Fatalf("floorless pool rejected a member: %+v", routeErr)
	}
	if provider.ProviderID != "member-old" {
		t.Fatalf("selected %q, want member-old (no floor configured)", provider.ProviderID)
	}
}

// Global (poolless) request: the floor is never consulted; a low-version
// provider is served exactly as before (byte-identical).
func TestPoolBinaryFloor_GlobalUnaffected(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	_ = tp
	old := poolProviderVer("any-provider", "1.0.0")
	registry.Register(&old, nil)

	provider, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq(""), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr != nil {
		t.Fatalf("global request rejected: %+v", routeErr)
	}
	if provider.ProviderID != "any-provider" {
		t.Fatalf("selected %q, want any-provider", provider.ProviderID)
	}
}

// Pinned/self-route path: a hard pin to an under-version member is refused with
// pool_binary_too_old (a pin must not bypass the floor).
func TestPoolBinaryFloor_PinnedBelowFloorRejected(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	old := poolProviderVer("member-old", "1.7.0")
	registry.Register(&old, nil)
	tp.AddMember("P", "member-old")
	tp.SetMinBinaryVersion("P", "1.8.0")

	headers := http.Header{}
	headers.Set("X-MacProvider-Provider", "member-old")
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), headers, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_binary_too_old" {
		t.Fatalf("pin to under-version member: want pool_binary_too_old, got %+v", routeErr)
	}
}

// Pinned member at/above the floor passes the gate.
func TestPoolBinaryFloor_PinnedAboveFloorServed(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	newp := poolProviderVer("member-new", "1.9.0")
	registry.Register(&newp, nil)
	tp.AddMember("P", "member-new")
	tp.SetMinBinaryVersion("P", "1.8.0")

	headers := http.Header{}
	headers.Set("X-MacProvider-Provider", "member-new")
	provider, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), headers, nil, "2024-01-01", &forwardState{})
	if routeErr != nil {
		t.Fatalf("pin to above-floor member rejected: %+v", routeErr)
	}
	if provider.ProviderID != "member-new" {
		t.Fatalf("selected %q, want member-new", provider.ProviderID)
	}
}

// Slot-queue candidate derivation drops an under-version member and keeps the
// eligible one (the by-hand path must apply the same floor).
func TestPoolBinaryFloor_SlotQueueExcludesBelowFloor(t *testing.T) {
	s, _, tp := poolIsolationServer(t)
	tp.AddMember("P", "member-old")
	tp.AddMember("P", "member-new")
	tp.SetMinBinaryVersion("P", "1.8.0")
	snap := tp.Snapshot("P")
	checker := &eligibilityCtx{
		s: s, model: "model-a", estimatedTokens: 100,
		tier2Cfg:             s.tier2Config(),
		poolID:               "P",
		poolMembers:          snap.Members,
		poolMinBinaryVersion: snap.MinBinaryVersion,
	}
	busy := func(id, ver string) pool.Provider {
		p := poolProviderVer(id, ver)
		p.SlotsFree = 0 // slot-queue eligibility requires a saturated provider
		return p
	}
	providers := []pool.Provider{busy("member-old", "1.7.0"), busy("member-new", "1.8.2")}
	got := s.slotQueueCandidates(providers, routing.NewExcluded(0), checker)
	if len(got) != 1 || got[0].ProviderID != "member-new" {
		t.Fatalf("slotQueueCandidates = %+v, want only member-new (under-version dropped)", got)
	}
}

// Slot-queue poll: a same-ID reconnect below the floor is terminated off the
// queue (the poll path re-checks the floor from the selection snapshot).
func TestPoolBinaryFloor_SlotQueuePollExcludesBelowFloor(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	old := poolProviderVer("member-old", "1.7.0")
	registry.Register(&old, nil)
	tp.AddMember("P", "member-old")
	tp.SetMinBinaryVersion("P", "1.8.0")

	w, ok := s.slotQueue.enter("member-old")
	if !ok {
		t.Fatal("enter returned no waiter")
	}
	defer s.slotQueue.leave(w)
	snap := tp.Snapshot("P")
	state := &forwardState{poolID: "P", poolMembers: snap.Members, poolMinBinaryVersion: snap.MinBinaryVersion}
	if _, status := s.pollQueuedProvider(w, "model-a", nil, 100, state); status != queuedProviderTerminal {
		t.Fatalf("poll status = %v, want terminal (under-version member off the queue)", status)
	}
}

// Membership dominates: a NON-member (whatever its version) is reported
// pool_no_eligible_member, never pool_binary_too_old — the floor is evaluated
// only for actual members.
func TestPoolBinaryFloor_MembershipDominates(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	member := poolProviderVer("member-new", "1.9.0")
	nonmember := poolProviderVer("nonmember-z", "1.0.0")
	registry.Register(&member, nil)
	registry.Register(&nonmember, nil)
	tp.AddMember("P", "member-new") // z is not a member
	tp.SetMinBinaryVersion("P", "1.8.0")

	headers := http.Header{}
	headers.Set("X-MacProvider-Provider", "nonmember-z")
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), headers, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_no_eligible_member" {
		t.Fatalf("pin to non-member: want pool_no_eligible_member (membership dominates), got %+v", routeErr)
	}
}

// SetMinBinaryVersion bumps the pool generation, so a route attempt fenced to
// the prior generation is stale — a raised floor invalidates in-flight
// reservations via the existing R005 fence rather than leaking under-version
// dispatch for a TTL.
func TestPoolBinaryFloor_SetMinBumpsGeneration(t *testing.T) {
	s, _, tp := poolIsolationServer(t)
	tp.AddMember("P", "member-x")
	gen0 := tp.Generation("P")
	state := &forwardState{poolID: "P", poolGeneration: gen0, poolGenSet: true}
	if s.poolGenerationStale(state) {
		t.Fatal("fresh snapshot must not be stale")
	}
	tp.SetMinBinaryVersion("P", "1.8.0")
	if tp.Generation("P") <= gen0 {
		t.Fatalf("SetMinBinaryVersion did not bump generation: gen0=%d now=%d", gen0, tp.Generation("P"))
	}
	if !s.poolGenerationStale(state) {
		t.Fatal("generation advanced after a floor change; fence must report stale")
	}
	// Setting the same floor again is a no-op (no generation churn).
	genAfter := tp.Generation("P")
	tp.SetMinBinaryVersion("P", "1.8.0")
	if tp.Generation("P") != genAfter {
		t.Fatal("setting the same floor bumped the generation; want no-op")
	}
}
