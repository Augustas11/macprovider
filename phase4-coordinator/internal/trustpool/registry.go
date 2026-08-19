// Package trustpool holds SPEC-042 Trusted Pool membership and revocation
// state — the "which providers may serve this pool" authority consulted by
// the buyer routing layer for tenant isolation (SPEC-042 R005).
//
// This is deliberately NOT the internal/pool package: internal/pool is the
// global provider registry (the whole network); a trustpool.Registry is the
// per-pool membership ledger + durable revocation blocklist layered on top.
//
// For this implementation slice the registry is an in-memory, directly
// seedable store (AddPool/AddMember/Revoke). The durable, manifest-driven
// write path (SPEC-042 R001 signed manifests, R003 durable ledger, R011
// reconstruction) lands in a later slice; this type is the seam it will
// populate. The Registry is safe for concurrent use.
package trustpool

import "sync"

// Registry maps pool_id -> membership/revocation state.
type Registry struct {
	mu    sync.RWMutex
	pools map[string]*poolState
}

type poolState struct {
	// members is the set of provider identities admitted to the pool
	// (SPEC-042 R003). revoked is the durable per-pool identity blocklist:
	// a revoked identity stays out even if re-added to members by mistake,
	// which is the "identity-forever blocklist" the admission-manager TTL
	// path explicitly is not.
	members map[string]struct{}
	revoked map[string]struct{}
	// generation increments on every membership/revocation change so the
	// routing generation fence (SPEC-042 R005) can detect a snapshot that
	// is no longer current.
	generation uint64
}

// Snapshot is a single consistent read of a pool's routable membership and
// its generation (SPEC-042 R003 single-read / R005 fence). Members already
// has revoked identities removed. Members and Generation are captured under
// one lock acquisition so a revocation committing mid-read cannot stamp a
// stale member set with the current generation.
type Snapshot struct {
	PoolID     string
	Exists     bool
	Members    map[string]bool // non-revoked members, keyed by provider identity
	Generation uint64
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry {
	return &Registry{pools: make(map[string]*poolState)}
}

func (r *Registry) ensure(poolID string) *poolState {
	ps := r.pools[poolID]
	if ps == nil {
		ps = &poolState{members: make(map[string]struct{}), revoked: make(map[string]struct{})}
		r.pools[poolID] = ps
	}
	return ps
}

// AddPool registers a pool with no members (seed helper).
func (r *Registry) AddPool(poolID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ensure(poolID)
}

// AddMember admits a provider identity to a pool and bumps the generation.
// A revoked identity is NOT admitted (the durable blocklist wins); callers
// must Unrevoke first if re-admission is ever intended. Seed helper.
func (r *Registry) AddMember(poolID, providerID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	ps := r.ensure(poolID)
	if _, revoked := ps.revoked[providerID]; revoked {
		return
	}
	if _, ok := ps.members[providerID]; ok {
		return
	}
	ps.members[providerID] = struct{}{}
	ps.generation++
}

// Revoke adds a provider identity to the pool's durable blocklist, removes it
// from the member set, and bumps the generation. After Revoke the provider is
// not routable for the pool at the very next Snapshot (SPEC-042 R003: no
// licensed staleness window). Seed helper / control-plane action.
func (r *Registry) Revoke(poolID, providerID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	ps := r.ensure(poolID)
	if _, already := ps.revoked[providerID]; already {
		return
	}
	ps.revoked[providerID] = struct{}{}
	delete(ps.members, providerID)
	ps.generation++
}

// Snapshot returns a consistent read of the pool's non-revoked members and
// its generation. For an unknown pool, Exists is false and Members is empty,
// which the routing layer treats as fail-closed (no eligible member).
func (r *Registry) Snapshot(poolID string) Snapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ps := r.pools[poolID]
	if ps == nil {
		return Snapshot{PoolID: poolID, Exists: false, Members: map[string]bool{}}
	}
	members := make(map[string]bool, len(ps.members))
	for id := range ps.members {
		if _, revoked := ps.revoked[id]; revoked {
			continue
		}
		members[id] = true
	}
	return Snapshot{PoolID: poolID, Exists: true, Members: members, Generation: ps.generation}
}

// Generation returns the current generation for a pool (0 for unknown pools).
func (r *Registry) Generation(poolID string) uint64 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if ps := r.pools[poolID]; ps != nil {
		return ps.generation
	}
	return 0
}
