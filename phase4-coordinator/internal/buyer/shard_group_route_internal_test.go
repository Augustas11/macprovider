package buyer

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

const shardTestPool = "ijUnc-ZQf-LJeRvkhi-0iQ"
const shardTestPoolModel = "pool/" + shardTestPool + "/deep-model"

func shardHead() pool.Provider {
	return pool.Provider{
		ProviderID: "head", AssignedID: "s-head", ShardGroupHeadV1: true, ShardGroupAvailable: true, ShardGroupEpoch: 1, ShardGroupPoolModelID: shardTestPoolModel,
		ShardGroupMembers:         []pool.ShardGroupMemberView{{ProviderID: "tail", AssignedID: "s-tail", BinaryVersion: "1.8.300"}, {ProviderID: "spare", Spare: true}},
		ModelHashAlgorithm:        "macprovider.snapshot-manifest.v1",
		ModelHash:                 shardTestHash,
		State:                     pool.StateReady,
		ReceiptPubkey:             []byte{1},
		Tier:                      pool.TierTrusted,
		ModelAdmissionPoolID:      shardTestPool,
		ModelAdmissionPoolModelID: shardTestPoolModel,
		BinaryVersion:             "1.8.300",
	}
}

const shardTestHash = "3333333333333333333333333333333333333333333333333333333333333333"

// shardTail is the live session of the head's active member.
func shardTail() pool.Provider {
	return pool.Provider{
		ProviderID: "tail", AssignedID: "s-tail", ShardMemberV1: true, State: pool.StateReady, ReceiptPubkey: []byte{2}, Tier: pool.TierTrusted,
		ModelHashAlgorithm: "macprovider.snapshot-manifest.v1", ModelHash: shardTestHash, BinaryVersion: "1.8.300",
	}
}

func shardRouteFor() shardGroupRoute {
	return shardRouteWith(map[string]pool.Provider{"tail": shardTail()})
}

func shardRouteWith(sessions map[string]pool.Provider) shardGroupRoute {
	return shardGroupRoute{
		poolID:           shardTestPool,
		members:          map[string]bool{"head": true, "tail": true, "spare": true},
		minBinaryVersion: "1.8.0",
		groups:           []poolmanifest.PoolShardGroup{{GroupProviderID: "head", PoolModelID: shardTestPoolModel, MaxMembers: 3}},
		resolve: func(id string) (pool.Provider, bool) {
			p, ok := sessions[id]
			return p, ok
		},
	}
}

// SPEC-051-R016/R028: a head routes only on an authorizing pool route.
func TestShardGroupRouteGate(t *testing.T) {
	if !shardRouteFor().routable(shardHead()) {
		t.Fatal("authorized head refused")
	}
	if !(shardGroupRoute{}).routable(pool.Provider{ProviderID: "plain"}) {
		t.Fatal("a provider that is not a head must pass unchanged")
	}
	cases := map[string]func(*shardGroupRoute, *pool.Provider){
		"global request":        func(r *shardGroupRoute, _ *pool.Provider) { *r = shardGroupRoute{} },
		"group unavailable":     func(_ *shardGroupRoute, p *pool.Provider) { p.ShardGroupAvailable = false },
		"not named by the core": func(r *shardGroupRoute, _ *pool.Provider) { r.groups = nil },
		"bound to another model": func(_ *shardGroupRoute, p *pool.Provider) {
			p.ModelAdmissionPoolModelID = "pool/" + shardTestPool + "/other"
		},
		"bound to another pool": func(_ *shardGroupRoute, p *pool.Provider) { p.ModelAdmissionPoolID = "other-pool" },
		// VM acceptance F7 (R3-C03): the record names another pool model than
		// the grant and the binding.
		"record names another pool model": func(_ *shardGroupRoute, p *pool.Provider) {
			p.ShardGroupPoolModelID = "pool/" + shardTestPool + "/not-the-bound-entry"
		},
		"over the member bound":  func(r *shardGroupRoute, _ *pool.Provider) { r.groups[0].MaxMembers = 2 },
		"head not a member":      func(r *shardGroupRoute, _ *pool.Provider) { delete(r.members, "head") },
		"member not a member":    func(r *shardGroupRoute, _ *pool.Provider) { delete(r.members, "tail") },
		"spare not a member":     func(r *shardGroupRoute, _ *pool.Provider) { delete(r.members, "spare") },
		"member below the floor": func(r *shardGroupRoute, _ *pool.Provider) { r.minBinaryVersion = "1.9.0" },
		"session is also member": func(_ *shardGroupRoute, p *pool.Provider) { p.ShardMemberV1 = true },
		// SPEC-051-R003/R004/R015: the member is re-checked at reservation.
		"member suspended since the last evaluation": func(r *shardGroupRoute, _ *pool.Provider) {
			tail := shardTail()
			tail.ComputeIntegritySuspended = true
			*r = shardRouteWith(map[string]pool.Provider{"tail": tail})
		},
		"member reconnected since the last evaluation": func(r *shardGroupRoute, _ *pool.Provider) {
			tail := shardTail()
			tail.AssignedID = "s-tail-2"
			*r = shardRouteWith(map[string]pool.Provider{"tail": tail})
		},
		"member disconnected": func(r *shardGroupRoute, _ *pool.Provider) { *r = shardRouteWith(nil) },
		// SPEC-051-R003/R004 (R2-C06): a connected spare is re-checked too.
		"connected spare suspended": func(r *shardGroupRoute, _ *pool.Provider) {
			spare := shardTail()
			spare.ProviderID, spare.AssignedID, spare.ComputeIntegritySuspended = "spare", "s-spare", true
			*r = shardRouteWith(map[string]pool.Provider{"tail": shardTail(), "spare": spare})
		},
	}
	for name, mutate := range cases {
		route, head := shardRouteFor(), shardHead()
		mutate(&route, &head)
		if route.routable(head) {
			t.Errorf("%s: head routable", name)
		}
	}
	// A spare's binary floor is not checked until it is active.
	head := shardHead()
	head.ShardGroupMembers[0].BinaryVersion = "1.8.300"
	route := shardRouteFor()
	route.minBinaryVersion = "1.8.300"
	if !route.routable(head) {
		t.Fatal("spare without a session blocked the group")
	}
}

// SPEC-051-R016: member sessions and unavailable heads are never routable;
// relay-blind and privacy work never binds a group session (SPEC-051-R009).
func TestShardSessionsRoutingState(t *testing.T) {
	base := pool.Provider{ProviderID: "p", AssignedID: "s", State: pool.StateReady, SlotsFree: 1}
	if !base.RoutingEligible() {
		t.Fatal("baseline provider not routable")
	}
	member := base
	member.ShardMemberV1 = true
	if member.RoutingEligible() || !member.ShardMemberAdmissible() {
		t.Fatalf("member session: routable=%v admissible=%v", member.RoutingEligible(), member.ShardMemberAdmissible())
	}
	head := base
	head.ShardGroupHeadV1 = true
	if head.RoutingEligible() {
		t.Fatal("head without an available group routable")
	}
	head.ShardGroupAvailable = true
	if !head.RoutingEligible() {
		t.Fatal("available head not routing-state eligible")
	}
	if relayBlindBindable(head) || relayBlindBindable(member) {
		t.Fatal("a shard group session bound relay-blind work")
	}
}

// SPEC-051-R021: a head's error_shard_group_failed before any output fails
// over like a provider disconnect, as a zero-credit breaker row.
func TestShardGroupFailedBeforeFirstTokenFailsOver(t *testing.T) {
	end := providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: "req", Status: "error_shard_group_failed"}
	relay := func() *providerws.RelayStream {
		done := make(chan providerws.InferenceResponseEnd, 1)
		done <- end
		return &providerws.RelayStream{RequestID: "req", Chunks: make(chan providerws.InferenceResponseChunk), Done: done, Errors: make(chan error, 1)}
	}
	head := shardHead()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(context.Background())

	result, attempt := (&Server{}).forwardWSNonStreaming(httptest.NewRecorder(), req, "req", head, relay(), nil, nil, &forwardState{}, 0)
	if result != wsForwardProviderDisconnected || attempt.FaultFlag != billing.FaultBreakerQualifying || attempt.Status != http.StatusBadGateway {
		t.Fatalf("non-streaming: result=%q attempt=%+v", result, attempt)
	}
	if tr := classifyWSResult(result, attempt); !tr.failoverEligible {
		t.Fatalf("non-streaming result is not failover-eligible: %+v", tr)
	}
	w := httptest.NewRecorder()
	result, attempt = (&Server{}).forwardWSStreaming(w, req, "req", head, relay(), &forwardState{}, 0)
	if result != wsForwardProviderDisconnected || attempt.FaultFlag != billing.FaultBreakerQualifying {
		t.Fatalf("streaming: result=%q attempt=%+v", result, attempt)
	}
	if tr := classifyStreamResult(result, attempt.Status, attempt); !tr.retryable || !tr.failoverEligible {
		t.Fatalf("streaming result is not retryable: %+v", tr)
	}
	if w.Body.Len() != 0 {
		t.Fatalf("streaming wrote to the buyer before failover: %q", w.Body.String())
	}

	// From a session that is not a head, the status is an ordinary error.
	plain := pool.Provider{ProviderID: "plain", AssignedID: "s-plain"}
	if result, _ := (&Server{}).forwardWSStreaming(httptest.NewRecorder(), req, "req", plain, relay(), &forwardState{}, 0); result == wsForwardProviderDisconnected {
		t.Fatal("non-head session failed over as a shard group failure")
	}
	if shardGroupFailedBeforeFirstToken(head, providerws.InferenceResponseEnd{Status: "error_shard_group_failed", ChunksSent: 3}, true) {
		t.Fatal("a failure after chunks counted as pre-first-token")
	}
}

// The gate runs ahead of routing.EligibleCandidates and counts what it drops.
func TestShardGroupRouteFilterCounts(t *testing.T) {
	head, plain := shardHead(), pool.Provider{ProviderID: "plain", AssignedID: "s-plain"}
	providers := []pool.Provider{head, plain}
	kept, rejected := (shardGroupRoute{}).filter(providers, routing.NewExcluded(0))
	if rejected != 1 || len(kept) != 1 || kept[0].ProviderID != "plain" {
		t.Fatalf("global route: kept=%+v rejected=%d", kept, rejected)
	}
	kept, rejected = shardRouteFor().filter(providers, routing.NewExcluded(0))
	if rejected != 0 || len(kept) != 2 {
		t.Fatalf("authorizing route: kept=%+v rejected=%d", kept, rejected)
	}
	ex := routing.NewExcluded(1)
	ex.AddKey(head.SortKey())
	kept, rejected = (shardGroupRoute{}).filter(providers, ex)
	if rejected != 0 || len(kept) != 2 {
		t.Fatalf("an excluded head is left to the excluded count: kept=%+v rejected=%d", kept, rejected)
	}
}

// A SPEC-051 shard group head refuses tools and response_format, so it never
// receives a tool request and never advertises either capability (#2107).
func TestShardGroupHeadIsNeverToolOrResponseFormatCapable(t *testing.T) {
	head := pool.Provider{ProviderID: "head", ModelID: "Jundot/GLM-5.3-Flash-oQ4e-mtp", BinaryVersion: toolGrammarProviderMinVersion, ShardGroupHeadV1: true}
	if providerToolGrammarEligible(head) || providerParsesToolGrammar(head) {
		t.Fatal("a shard group head must not be tool eligible")
	}
	if got := toolGrammarEligibleProviders([]pool.Provider{head}); len(got) != 0 {
		t.Fatalf("eligible=%v want none", got)
	}
	caps := mergeModelCapabilities(nil, head, false)
	if caps.Tools || caps.ResponseFormat || len(caps.ToolChoice) != 0 || !caps.Reasoning {
		t.Fatalf("head capabilities=%+v want reasoning only", caps)
	}
}

// R2-C01 / SPEC-051-R016/R028: the slot queue applies the shard group gate at
// admission and again before it reserves a queued provider, so a group head
// that the selection's route does not authorize is never served off the queue.
func TestSlotQueueAppliesTheShardGroupGate(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	head := poolProvider("head")
	head.ShardGroupHeadV1 = true
	head.SlotsFree = 0
	registry.Register(&head, nil)
	registry.SetShardGroupState("head", head.AssignedID, true, 1, shardTestPoolModel, []pool.ShardGroupMemberView{{ProviderID: "tail", AssignedID: "s-tail"}})
	live, ok := registry.Resolve("head", head.AssignedID)
	if !ok || !live.ShardGroupAvailable {
		t.Fatal("head not registered as available")
	}
	checker := &eligibilityCtx{s: s, model: "model-a", estimatedTokens: 100, tier2Cfg: s.tier2Config()}
	if got := s.slotQueueCandidates([]pool.Provider{live}, routing.NewExcluded(0), checker); len(got) != 0 {
		t.Fatalf("queue admitted an unauthorized head: %+v", got)
	}
	plain := poolProvider("plain")
	plain.SlotsFree = 0
	if got := s.slotQueueCandidates([]pool.Provider{plain}, routing.NewExcluded(0), checker); len(got) != 1 {
		t.Fatalf("queue dropped an ordinary provider: %+v", got)
	}
	freed := live
	freed.SlotsFree = 1
	registry.Register(&freed, nil)
	registry.SetShardGroupState("head", freed.AssignedID, true, 1, shardTestPoolModel, nil)
	waiter, ok := s.slotQueue.enter("head")
	if !ok {
		t.Fatal("enter returned no waiter")
	}
	defer s.slotQueue.leave(waiter)
	if _, status := s.pollQueuedProviderWithContext(context.Background(), waiter, "model-a", nil, 100, &forwardState{}); status != queuedProviderTerminal {
		t.Fatalf("queued head without an authorizing route: status %v, want terminal", status)
	}
}
