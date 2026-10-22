package buyer

import (
	"net/http"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	"github.com/augstar/macprovider-coordinator/internal/shardgroup"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// shardGroupRoute is the SPEC-051-R028 route view of one request: the pool it
// selected and that pool's consistent snapshot of members, binary floor and
// shard group authorizations. The zero value is a global request.
type shardGroupRoute struct {
	poolID           string
	members          map[string]bool
	minBinaryVersion string
	groups           []poolmanifest.PoolShardGroup
	// resolve reads a live provider session; the gate re-checks each active
	// member's admission through it at reservation (SPEC-051-R015).
	resolve func(id string) (pool.Provider, bool)
}

// routable applies SPEC-051-R016/R028 to one provider. A provider that did
// not advertise shard_group_head_v1 always passes, so routing without shard
// groups is unchanged. A head session passes only on a pool route whose
// active core names it, while its group is available, bound to that pool's
// named pool model, within the member bound, with every non-head member and
// spare a current pool member, and every active member meeting the pool
// binary floor and still admissible on the session the group evaluation
// bound (SPEC-051-R003/R004: a member change applies before the next
// reservation, not at the next sweep). A global request never reaches a head.
func (r shardGroupRoute) routable(p pool.Provider) bool {
	if !p.ShardGroupHeadV1 {
		return true
	}
	if r.poolID == "" || p.ShardMemberV1 || !p.ShardGroupAvailable {
		return false
	}
	var grant poolmanifest.PoolShardGroup
	found := false
	for _, g := range r.groups {
		if g.GroupProviderID == p.ProviderID {
			grant, found = g, true
			break
		}
	}
	if !found || p.ModelAdmissionPoolID != r.poolID || p.ModelAdmissionPoolModelID != grant.PoolModelID {
		return false
	}
	if uint64(len(p.ShardGroupMembers))+1 > grant.MaxMembers {
		return false
	}
	if !r.members[p.ProviderID] || !poolBinaryFloorMet(p.BinaryVersion, r.minBinaryVersion) {
		return false
	}
	for _, m := range p.ShardGroupMembers {
		if !r.members[m.ProviderID] || (!m.Spare && !poolBinaryFloorMet(m.BinaryVersion, r.minBinaryVersion)) {
			return false
		}
		if !m.Spare && (r.resolve == nil || !shardgroup.MemberReservable(p, m, r.resolve)) {
			return false
		}
	}
	return true
}

// filter applies the gate ahead of routing.EligibleCandidates: it drops every
// shard group head the route does not authorize and reports how many it
// dropped (ReasonShardGroupNotAuthorized). An excluded provider is left for
// the filter to count as excluded. Without a head among providers the slice
// is returned unchanged, so routing without shard groups is byte-identical.
func (r shardGroupRoute) filter(providers []pool.Provider, excluded routing.Excluded) ([]pool.Provider, int) {
	rejected := 0
	for _, p := range providers {
		if !excluded.Has(p.SortKey()) && !r.routable(p) {
			rejected++
		}
	}
	if rejected == 0 {
		return providers, 0
	}
	kept := make([]pool.Provider, 0, len(providers)-rejected)
	for _, p := range providers {
		if excluded.Has(p.SortKey()) || r.routable(p) {
			kept = append(kept, p)
		}
	}
	return kept, rejected
}

// shardGroupFailedStatus is the SPEC-051-R021 terminal status a group head
// sends when the group fails before the first output token.
const shardGroupFailedStatus = "error_shard_group_failed"

// shardGroupFailedBeforeFirstToken reports a SPEC-051-R021 pre-first-token
// group failure: the status from a head session, with no chunk counted by the
// provider and nothing delivered toward the buyer. From any other session, or
// after output, the status is an ordinary provider error.
func shardGroupFailedBeforeFirstToken(p pool.Provider, end providerws.InferenceResponseEnd, nothingDelivered bool) bool {
	return p.ShardGroupHeadV1 && end.Status == shardGroupFailedStatus && end.ChunksSent == 0 && nothingDelivered
}

// shardGroupFailedAttempt is the attempt a SPEC-051-R021 failure records: the
// same retryable, failover-eligible shape as a provider disconnect before the
// first chunk, written as a SPEC-005 §6.11 breaker-qualifying row whose
// credits are zero, so the failed group attempt neither debits the buyer nor
// credits the provider.
func shardGroupFailedAttempt() requestLogAttempt {
	return requestLogAttempt{Status: http.StatusBadGateway, Error: "Shard group failed before the first token; buyer should retry", FaultFlag: billing.FaultBreakerQualifying}
}
