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
		ProviderID: "head", AssignedID: "s-head", ShardGroupHeadV1: true, ShardGroupAvailable: true, ShardGroupEpoch: 1,
		ShardGroupMembers:         []pool.ShardGroupMemberView{{ProviderID: "tail", BinaryVersion: "1.8.300"}, {ProviderID: "spare", Spare: true}},
		ModelAdmissionPoolID:      shardTestPool,
		ModelAdmissionPoolModelID: shardTestPoolModel,
		BinaryVersion:             "1.8.300",
	}
}

func shardRouteFor() shardGroupRoute {
	return shardGroupRoute{
		poolID:           shardTestPool,
		members:          map[string]bool{"head": true, "tail": true, "spare": true},
		minBinaryVersion: "1.8.0",
		groups:           []poolmanifest.PoolShardGroup{{GroupProviderID: "head", PoolModelID: shardTestPoolModel, MaxMembers: 3}},
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
		"bound to another pool":  func(_ *shardGroupRoute, p *pool.Provider) { p.ModelAdmissionPoolID = "other-pool" },
		"over the member bound":  func(r *shardGroupRoute, _ *pool.Provider) { r.groups[0].MaxMembers = 2 },
		"head not a member":      func(r *shardGroupRoute, _ *pool.Provider) { delete(r.members, "head") },
		"member not a member":    func(r *shardGroupRoute, _ *pool.Provider) { delete(r.members, "tail") },
		"spare not a member":     func(r *shardGroupRoute, _ *pool.Provider) { delete(r.members, "spare") },
		"member below the floor": func(r *shardGroupRoute, _ *pool.Provider) { r.minBinaryVersion = "1.9.0" },
		"session is also member": func(_ *shardGroupRoute, p *pool.Provider) { p.ShardMemberV1 = true },
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
