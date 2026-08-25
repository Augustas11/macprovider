// Package trustpool holds SPEC-042 Trusted Pool membership and revocation
// state — the "which providers may serve this pool" authority consulted by
// the buyer routing layer for tenant isolation (SPEC-042 R005).
//
// This is deliberately NOT the internal/pool package: internal/pool is the
// global provider registry (the whole network); a trustpool.Registry is the
// per-pool membership ledger + durable revocation blocklist layered on top.
//
// For this implementation slice the registry can still be directly seeded by
// tests and static config, but production startup now populates it from durable
// replay snapshots. Routeable publication is a separate step from raw event
// append, so candidate/restrictive state can exist without serving traffic. The
// Registry is safe for concurrent use.
package trustpool

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/versionfloor"
)

// Registry maps pool_id -> membership/revocation state.
type Registry struct {
	mu                 sync.RWMutex
	pools              map[string]*poolState
	providerCeilings   map[string]map[string]struct{}
	delegatedCeilings  map[string]map[string]struct{}
	buyerCeilings      map[string]map[string]struct{}
	ceilingConfigured  bool
	ceilingGeneration  uint64
	revision           uint64
	revocationWatchers map[string]map[chan struct{}]struct{}
	activeDeliveries   map[string]uint64
}

type poolState struct {
	creatorAccountID string
	// members is the set of provider identities admitted to the pool
	// (SPEC-042 R003). revoked is the durable per-pool identity blocklist:
	// a revoked identity stays out even if re-added to members by mistake,
	// which is the "identity-forever blocklist" the admission-manager TTL
	// path explicitly is not.
	members map[string]struct{}
	revoked map[string]struct{}
	buyers  map[string]struct{}
	// routeable is true only for pools whose durable lifecycle is active.
	// Unknown, created, paused, draining, and retired pools fail as
	// pool_unavailable before candidate filtering.
	routeable bool
	// minBinaryVersion is the pool's minimum provider binary version
	// (SPEC-042 R004 predicate). A member whose binary_version is below this
	// floor is not eligible for the pool's traffic (SPEC-042 R010
	// pool_binary_too_old). "" means no floor is configured — the gate is a
	// strict no-op. The floor rides this consistent snapshot so a route
	// attempt evaluates membership AND floor against one coherent view.
	minBinaryVersion string
	// modelAllowlist is the pool manifest's request-model allowlist. Empty
	// means no allowlist is configured and the route gate is inert.
	modelAllowlist []string
	// settlementMode is the manifest-derived settlement policy. "enforce"
	// requires the coordinator's effective verified-model settlement mode to be
	// enforce before pool traffic can route; "observe" is inert for the v0.1
	// labels-only pool settlement contract.
	settlementMode string
	// generation increments on every membership/revocation/floor change so the
	// routing generation fence (SPEC-042 R005) can detect a snapshot that
	// is no longer current.
	generation        uint64
	routeableUntilUTC time.Time
	routeableExpired  bool
}

// Snapshot is a single consistent read of a pool's routable membership and
// its generation (SPEC-042 R003 single-read / R005 fence). Members already
// has revoked identities removed. Members and Generation are captured under
// one lock acquisition so a revocation committing mid-read cannot stamp a
// stale member set with the current generation.
type Snapshot struct {
	PoolID  string
	Exists  bool
	Members map[string]bool // non-revoked members, keyed by provider identity
	// MinBinaryVersion is the pool's minimum provider binary version floor
	// (SPEC-042 R004), captured under the same lock as Members/Generation.
	// "" means no floor — the eligibility gate is inert.
	MinBinaryVersion  string
	ModelAllowlist    []string
	SettlementMode    string
	Routeable         bool
	Generation        uint64
	Revision          uint64
	RouteableUntilUTC time.Time
	RouteableExpired  bool
}

// RouteableSnapshot is a durable reconstruction input: one coherent pool state
// produced by the control plane at boot/failover time. Members are the identities
// routeable RIGHT NOW; non-active pools should pass an empty member set so the
// routing gate fails closed while preserving the pool's generation fence.
type RouteableSnapshot struct {
	PoolID            string
	CreatorAccountID  string
	Members           []string
	Revoked           []string
	BuyerAccounts     []string
	MinBinaryVersion  string
	ModelAllowlist    []string
	SettlementMode    string
	Routeable         bool
	Generation        uint64
	RouteableUntilUTC time.Time
	RouteableExpired  bool
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry {
	return &Registry{
		pools:              make(map[string]*poolState),
		revocationWatchers: make(map[string]map[chan struct{}]struct{}),
		activeDeliveries:   make(map[string]uint64),
	}
}

func (r *Registry) ensure(poolID string) *poolState {
	ps := r.pools[poolID]
	if ps == nil {
		ps = &poolState{members: make(map[string]struct{}), revoked: make(map[string]struct{}), buyers: make(map[string]struct{})}
		r.pools[poolID] = ps
	}
	return ps
}

// InitCreatorAdminCeilings seeds creator-owned allowlists during startup before
// any request can hold a generation fence. Runtime reloads must use
// SetCreatorAdminCeilings so tightening the first ceiling invalidates stale
// pre-reload reservations.
func (r *Registry) InitCreatorAdminCeilings(providerIDs, delegatedProviderIDs, buyerAccountIDs map[string][]string) {
	r.setCreatorAdminCeilings(providerIDs, delegatedProviderIDs, buyerAccountIDs, false)
}

// SetCreatorAdminCeilings installs the current creator-owned allowlists as a
// live routing ceiling. Durable pool events can grant membership/authorization,
// but a configured creator ceiling must still include the provider or buyer at
// route time; removing an id from config therefore cuts stale access without
// waiting for a compensating durable event.
func (r *Registry) SetCreatorAdminCeilings(providerIDs, delegatedProviderIDs, buyerAccountIDs map[string][]string) {
	r.setCreatorAdminCeilings(providerIDs, delegatedProviderIDs, buyerAccountIDs, true)
}

func (r *Registry) setCreatorAdminCeilings(providerIDs, delegatedProviderIDs, buyerAccountIDs map[string][]string, bumpOnChange bool) {
	if r == nil {
		return
	}
	nextProviders := normalizeCreatorCeilings(providerIDs)
	nextDelegatedProviders := normalizeCreatorCeilings(delegatedProviderIDs)
	nextBuyers := normalizeCreatorCeilings(buyerAccountIDs)
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.ceilingConfigured {
		nextProviders = preserveRemovedCreatorCeilingsAsDenyAll(r.providerCeilings, nextProviders)
		nextDelegatedProviders = preserveRemovedCreatorCeilingsAsDenyAll(r.delegatedCeilings, nextDelegatedProviders)
		nextBuyers = preserveRemovedCreatorCeilingsAsDenyAll(r.buyerCeilings, nextBuyers)
	}
	if creatorCeilingsEqual(r.providerCeilings, nextProviders) && creatorCeilingsEqual(r.delegatedCeilings, nextDelegatedProviders) && creatorCeilingsEqual(r.buyerCeilings, nextBuyers) {
		return
	}
	r.providerCeilings = nextProviders
	r.delegatedCeilings = nextDelegatedProviders
	r.buyerCeilings = nextBuyers
	r.ceilingConfigured = true
	if bumpOnChange {
		r.ceilingGeneration++
	}
}

// AddPool registers a pool with no members (seed helper).
func (r *Registry) AddPool(poolID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ensure(poolID).routeable = true
}

// AddMember admits a provider identity to a pool and bumps the generation.
// A revoked identity is NOT admitted (the durable blocklist wins); callers
// must Unrevoke first if re-admission is ever intended. Seed helper.
func (r *Registry) AddMember(poolID, providerID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	ps := r.ensure(poolID)
	ps.routeable = true
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
	ps.routeable = true
	if _, already := ps.revoked[providerID]; already {
		return
	}
	ps.revoked[providerID] = struct{}{}
	delete(ps.members, providerID)
	ps.generation++
	r.notifyProviderRevokedLocked(poolID, providerID)
}

// ProviderRevoked reports whether providerID is on poolID's durable revocation
// blocklist. It is intentionally narrower than "not in Snapshot().Members":
// restrictive lifecycle changes may make a pool non-routeable while still
// allowing already-dispatched in-flight work to drain, but revoke_immediate
// must cut that provider's active transport.
func (r *Registry) ProviderRevoked(poolID, providerID string) bool {
	if r == nil || poolID == "" || providerID == "" {
		return false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.providerRevokedLocked(poolID, providerID)
}

// WatchProviderRevoked returns a channel closed exactly when providerID lands
// on poolID's durable revocation blocklist. The returned stop function only
// unregisters the watch; it does not close the channel, so channel close remains
// a pure revoke_immediate signal for active dispatch cancellation.
func (r *Registry) WatchProviderRevoked(poolID, providerID string) (<-chan struct{}, func(), bool) {
	ch := make(chan struct{})
	if r == nil || poolID == "" || providerID == "" {
		return ch, func() {}, false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.providerRevokedLocked(poolID, providerID) {
		close(ch)
		return ch, func() {}, true
	}
	if r.revocationWatchers == nil {
		r.revocationWatchers = make(map[string]map[chan struct{}]struct{})
	}
	key := revocationWatchKey(poolID, providerID)
	watchers := r.revocationWatchers[key]
	if watchers == nil {
		watchers = make(map[chan struct{}]struct{})
		r.revocationWatchers[key] = watchers
	}
	watchers[ch] = struct{}{}
	var once sync.Once
	stop := func() {
		once.Do(func() {
			r.mu.Lock()
			defer r.mu.Unlock()
			watchers := r.revocationWatchers[key]
			delete(watchers, ch)
			if len(watchers) == 0 {
				delete(r.revocationWatchers, key)
			}
		})
	}
	return ch, stop, false
}

// AuthorizeBuyer grants a buyer account the ability to select a pool. Seed
// helper / control-plane action. The generation bump keeps route snapshots
// honest when a future request/reservation path includes buyer grants.
func (r *Registry) AuthorizeBuyer(poolID, buyerAccountID string) {
	if buyerAccountID == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	ps := r.ensure(poolID)
	ps.routeable = true
	if _, ok := ps.buyers[buyerAccountID]; ok {
		return
	}
	ps.buyers[buyerAccountID] = struct{}{}
	ps.generation++
}

// RemoveBuyerAuthorization revokes a buyer account's ability to select a pool.
// Seed helper / control-plane action.
func (r *Registry) RemoveBuyerAuthorization(poolID, buyerAccountID string) {
	if buyerAccountID == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	ps := r.ensure(poolID)
	ps.routeable = true
	if _, ok := ps.buyers[buyerAccountID]; !ok {
		return
	}
	delete(ps.buyers, buyerAccountID)
	ps.generation++
}

// SetMinBinaryVersion sets the pool's minimum provider binary version floor
// (SPEC-042 R004) and bumps the generation. Bumping the generation means a
// raised floor invalidates in-flight reservations fenced to the prior
// generation (SPEC-042 R005), so the new floor applies at the very next
// dispatch rather than leaking a window of under-version routing. "" clears
// the floor. Seed helper / control-plane action.
//
// The floor MUST be a version the coordinator's canonical comparator can parse
// (versionfloor.Valid); a malformed floor is REJECTED here rather than stored,
// because a stored-but-unparseable floor makes versionfloor.Compare fail for
// every provider and bricks the whole pool with pool_binary_too_old (an
// avoidable, confusing pool-wide outage from a config typo). Invalid input is a
// no-op that returns an error and does not bump the generation.
func (r *Registry) SetMinBinaryVersion(poolID, version string) error {
	if version != "" && !versionfloor.Valid(version) {
		return fmt.Errorf("trustpool: invalid pool min binary version %q for pool %q", version, poolID)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	ps := r.ensure(poolID)
	ps.routeable = true
	if ps.minBinaryVersion == version {
		return nil
	}
	ps.minBinaryVersion = version
	ps.generation++
	return nil
}

// SetModelAllowlist sets the pool's request-model allowlist and bumps the
// generation. Empty clears the allowlist and makes the gate inert. Seed helper /
// control-plane action.
func (r *Registry) SetModelAllowlist(poolID string, models []string) error {
	normalized, err := normalizeModelAllowlist(poolID, models)
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	ps := r.ensure(poolID)
	ps.routeable = true
	if stringSlicesEqual(ps.modelAllowlist, normalized) {
		return nil
	}
	ps.modelAllowlist = normalized
	ps.generation++
	return nil
}

// LoadRouteableSnapshot replaces one pool with a durable reconstructed snapshot.
// It is the boot/failover path for SPEC-043's pool store: the store computes the
// current lifecycle/member view, and the hot routing registry receives only the
// routeable result. This method does not merge with prior in-memory seed state.
func (r *Registry) LoadRouteableSnapshot(s RouteableSnapshot) error {
	if s.PoolID == "" {
		return fmt.Errorf("trustpool: routeable snapshot pool id is required")
	}
	if s.MinBinaryVersion != "" && !versionfloor.Valid(s.MinBinaryVersion) {
		return fmt.Errorf("trustpool: invalid pool min binary version %q for pool %q", s.MinBinaryVersion, s.PoolID)
	}
	if !validPoolSettlementMode(s.SettlementMode) {
		return fmt.Errorf("trustpool: routeable snapshot for pool %q has invalid settlement mode %q", s.PoolID, s.SettlementMode)
	}
	modelAllowlist, err := normalizeModelAllowlist(s.PoolID, s.ModelAllowlist)
	if err != nil {
		return err
	}
	members := make(map[string]struct{}, len(s.Members))
	for _, id := range s.Members {
		if id == "" {
			return fmt.Errorf("trustpool: routeable snapshot for pool %q contains empty member id", s.PoolID)
		}
		members[id] = struct{}{}
	}
	revoked := make(map[string]struct{}, len(s.Revoked))
	for _, id := range s.Revoked {
		if id == "" {
			return fmt.Errorf("trustpool: routeable snapshot for pool %q contains empty revoked id", s.PoolID)
		}
		revoked[id] = struct{}{}
		delete(members, id)
	}
	buyers := make(map[string]struct{}, len(s.BuyerAccounts))
	for _, id := range s.BuyerAccounts {
		if id == "" {
			return fmt.Errorf("trustpool: routeable snapshot for pool %q contains empty buyer account id", s.PoolID)
		}
		buyers[id] = struct{}{}
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	r.pools[s.PoolID] = &poolState{
		creatorAccountID:  s.CreatorAccountID,
		members:           members,
		revoked:           revoked,
		buyers:            buyers,
		routeable:         s.Routeable,
		minBinaryVersion:  s.MinBinaryVersion,
		modelAllowlist:    modelAllowlist,
		settlementMode:    canonicalPoolSettlementMode(s.SettlementMode),
		generation:        s.Generation,
		routeableUntilUTC: s.RouteableUntilUTC.UTC(),
		routeableExpired:  s.RouteableExpired,
	}
	r.notifyRevokedWatchersForPoolsLocked(map[string]*poolState{s.PoolID: r.pools[s.PoolID]})
	return nil
}

// LoadRouteableSnapshots replaces the registry contents with a durable snapshot
// set. The all-or-nothing validation pass avoids partially loaded pool state if
// one reconstructed pool is malformed.
func (r *Registry) LoadRouteableSnapshots(snapshots []RouteableSnapshot) error {
	_, err := r.loadRouteableSnapshots(0, snapshots, false, false)
	return err
}

// LoadRouteableSnapshotsAtRevision replaces the registry only when revision is
// newer than the current high-water mark. Admin mutation publication uses this
// to prevent an older post-commit refresh from overwriting a newer restrictive
// mutation.
func (r *Registry) LoadRouteableSnapshotsAtRevision(revision uint64, snapshots []RouteableSnapshot) error {
	_, err := r.loadRouteableSnapshots(revision, snapshots, true, false)
	return err
}

// RefreshRouteableSnapshotsAtRevision replaces the registry at the current
// revision when the durable replay output changes due to time-based gates.
// Event/approval mutation publishers should keep using LoadRouteableSnapshotsAtRevision.
func (r *Registry) RefreshRouteableSnapshotsAtRevision(revision uint64, snapshots []RouteableSnapshot) (bool, error) {
	return r.loadRouteableSnapshots(revision, snapshots, true, true)
}

func (r *Registry) Revision() uint64 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.revision
}

// Disable clears all routeable trusted-pool snapshots without advancing the
// durable revision. Malformed durable state must fail routing closed
// immediately, while a repaired store at the same revision can republish.
func (r *Registry) Disable() {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.pools = make(map[string]*poolState)
}

// BeginPoolDelivery records a provider-dispatched pool request until the
// returned function is called. It is the route-time proof used by lifecycle
// controls to distinguish delivery drain from later asynchronous settlement.
func (r *Registry) BeginPoolDelivery(poolID string) func() {
	if r == nil || poolID == "" {
		return func() {}
	}
	r.mu.Lock()
	if r.activeDeliveries == nil {
		r.activeDeliveries = make(map[string]uint64)
	}
	r.activeDeliveries[poolID]++
	r.mu.Unlock()

	var once sync.Once
	return func() {
		once.Do(func() {
			r.mu.Lock()
			defer r.mu.Unlock()
			if r.activeDeliveries == nil {
				return
			}
			if r.activeDeliveries[poolID] <= 1 {
				delete(r.activeDeliveries, poolID)
				return
			}
			r.activeDeliveries[poolID]--
		})
	}
}

// BeginPoolDeliveryAtGeneration starts delivery only if the selected pool is
// still routeable at the generation captured by routing. This makes the final
// dispatch authorization and delivery counter increment one atomic registry
// decision, closing the selected-but-not-yet-tracked retirement race.
func (r *Registry) BeginPoolDeliveryAtGeneration(poolID string, generation uint64) (func(), bool) {
	if r == nil || poolID == "" {
		return func() {}, false
	}
	r.mu.Lock()
	ps := r.pools[poolID]
	now := time.Now().UTC()
	if ps == nil || !ps.routeableAt(now) || ps.generationAt(now)+r.ceilingGeneration != generation {
		r.mu.Unlock()
		return func() {}, false
	}
	if r.activeDeliveries == nil {
		r.activeDeliveries = make(map[string]uint64)
	}
	r.activeDeliveries[poolID]++
	r.mu.Unlock()

	var once sync.Once
	return func() {
		once.Do(func() {
			r.mu.Lock()
			defer r.mu.Unlock()
			if r.activeDeliveries == nil {
				return
			}
			if r.activeDeliveries[poolID] <= 1 {
				delete(r.activeDeliveries, poolID)
				return
			}
			r.activeDeliveries[poolID]--
		})
	}, true
}

// PoolDeliveryDrained reports whether no provider-dispatched request for the
// pool is still delivering output to a buyer. Settlement/receipt finalization
// can continue after this turns true.
func (r *Registry) PoolDeliveryDrained(poolID string) bool {
	if r == nil || poolID == "" {
		return true
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.activeDeliveries[poolID] == 0
}

func (r *Registry) ActivePoolDeliveries(poolID string) uint64 {
	if r == nil || poolID == "" {
		return 0
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.activeDeliveries[poolID]
}

func (r *Registry) loadRouteableSnapshots(revision uint64, snapshots []RouteableSnapshot, enforceRevision bool, allowSameRevisionRefresh bool) (bool, error) {
	next := make(map[string]*poolState, len(snapshots))
	for _, s := range snapshots {
		if s.PoolID == "" {
			return false, fmt.Errorf("trustpool: routeable snapshot pool id is required")
		}
		if _, exists := next[s.PoolID]; exists {
			return false, fmt.Errorf("trustpool: duplicate routeable snapshot for pool %q", s.PoolID)
		}
		if s.MinBinaryVersion != "" && !versionfloor.Valid(s.MinBinaryVersion) {
			return false, fmt.Errorf("trustpool: invalid pool min binary version %q for pool %q", s.MinBinaryVersion, s.PoolID)
		}
		if !validPoolSettlementMode(s.SettlementMode) {
			return false, fmt.Errorf("trustpool: routeable snapshot for pool %q has invalid settlement mode %q", s.PoolID, s.SettlementMode)
		}
		modelAllowlist, err := normalizeModelAllowlist(s.PoolID, s.ModelAllowlist)
		if err != nil {
			return false, err
		}
		members := make(map[string]struct{}, len(s.Members))
		for _, id := range s.Members {
			if id == "" {
				return false, fmt.Errorf("trustpool: routeable snapshot for pool %q contains empty member id", s.PoolID)
			}
			members[id] = struct{}{}
		}
		revoked := make(map[string]struct{}, len(s.Revoked))
		for _, id := range s.Revoked {
			if id == "" {
				return false, fmt.Errorf("trustpool: routeable snapshot for pool %q contains empty revoked id", s.PoolID)
			}
			revoked[id] = struct{}{}
			delete(members, id)
		}
		buyers := make(map[string]struct{}, len(s.BuyerAccounts))
		for _, id := range s.BuyerAccounts {
			if id == "" {
				return false, fmt.Errorf("trustpool: routeable snapshot for pool %q contains empty buyer account id", s.PoolID)
			}
			buyers[id] = struct{}{}
		}
		next[s.PoolID] = &poolState{
			creatorAccountID:  s.CreatorAccountID,
			members:           members,
			revoked:           revoked,
			buyers:            buyers,
			routeable:         s.Routeable,
			minBinaryVersion:  s.MinBinaryVersion,
			modelAllowlist:    modelAllowlist,
			settlementMode:    canonicalPoolSettlementMode(s.SettlementMode),
			generation:        s.Generation,
			routeableUntilUTC: s.RouteableUntilUTC.UTC(),
			routeableExpired:  s.RouteableExpired,
		}
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	if enforceRevision && r.revision != 0 {
		switch {
		case revision < r.revision:
			return false, fmt.Errorf("trustpool: stale routeable snapshot revision %d < current %d", revision, r.revision)
		case revision == r.revision && !allowSameRevisionRefresh:
			return false, fmt.Errorf("trustpool: stale routeable snapshot revision %d <= current %d", revision, r.revision)
		case revision == r.revision && poolStateMapsEqual(r.pools, next):
			return false, nil
		}
	}
	changed := r.revision != revision || !poolStateMapsEqual(r.pools, next)
	r.pools = next
	if enforceRevision {
		r.revision = revision
	}
	if changed {
		r.notifyRevokedWatchersForPoolsLocked(next)
	}
	return changed, nil
}

const revocationWatchSep = "\x00"

func revocationWatchKey(poolID, providerID string) string {
	return poolID + revocationWatchSep + providerID
}

func splitRevocationWatchKey(key string) (string, string, bool) {
	poolID, providerID, ok := strings.Cut(key, revocationWatchSep)
	return poolID, providerID, ok
}

func (r *Registry) providerRevokedLocked(poolID, providerID string) bool {
	ps := r.pools[poolID]
	if ps == nil {
		return false
	}
	_, revoked := ps.revoked[providerID]
	return revoked
}

func (r *Registry) notifyProviderRevokedLocked(poolID, providerID string) {
	if r.revocationWatchers == nil {
		return
	}
	key := revocationWatchKey(poolID, providerID)
	for ch := range r.revocationWatchers[key] {
		close(ch)
	}
	delete(r.revocationWatchers, key)
}

func (r *Registry) notifyRevokedWatchersForPoolsLocked(pools map[string]*poolState) {
	if len(r.revocationWatchers) == 0 {
		return
	}
	for key := range r.revocationWatchers {
		poolID, providerID, ok := splitRevocationWatchKey(key)
		if !ok {
			continue
		}
		ps := pools[poolID]
		if ps == nil {
			continue
		}
		if _, revoked := ps.revoked[providerID]; revoked {
			r.notifyProviderRevokedLocked(poolID, providerID)
		}
	}
}

func poolStateMapsEqual(a, b map[string]*poolState) bool {
	if len(a) != len(b) {
		return false
	}
	for poolID, ap := range a {
		bp := b[poolID]
		if bp == nil || !poolStatesEqual(ap, bp) {
			return false
		}
	}
	return true
}

func poolStatesEqual(a, b *poolState) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.routeable == b.routeable &&
		a.creatorAccountID == b.creatorAccountID &&
		a.minBinaryVersion == b.minBinaryVersion &&
		stringSlicesEqual(a.modelAllowlist, b.modelAllowlist) &&
		a.settlementMode == b.settlementMode &&
		a.generation == b.generation &&
		a.routeableUntilUTC.Equal(b.routeableUntilUTC) &&
		a.routeableExpired == b.routeableExpired &&
		stringSetsEqual(a.members, b.members) &&
		stringSetsEqual(a.revoked, b.revoked) &&
		stringSetsEqual(a.buyers, b.buyers)
}

func stringSetsEqual(a, b map[string]struct{}) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if _, ok := b[k]; !ok {
			return false
		}
	}
	return true
}

func normalizeModelAllowlist(poolID string, models []string) ([]string, error) {
	if len(models) == 0 {
		return nil, nil
	}
	out := make([]string, 0, len(models))
	seen := make(map[string]struct{}, len(models))
	for _, model := range models {
		model = strings.TrimSpace(model)
		if model == "" {
			return nil, fmt.Errorf("trustpool: model allowlist for pool %q contains empty model id", poolID)
		}
		if _, ok := seen[model]; ok {
			return nil, fmt.Errorf("trustpool: model allowlist for pool %q contains duplicate model id %q", poolID, model)
		}
		seen[model] = struct{}{}
		out = append(out, model)
	}
	sort.Strings(out)
	return out, nil
}

func cloneStringSlice(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	return append([]string(nil), in...)
}

func stringSlicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// RouteableSnapshots returns a deterministic durable-style export of all
// currently known pools. It is used by tests and admin/debug surfaces; callers
// must not mutate the returned slices.
func (r *Registry) RouteableSnapshots() []RouteableSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ids := make([]string, 0, len(r.pools))
	for id := range r.pools {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	out := make([]RouteableSnapshot, 0, len(ids))
	for _, poolID := range ids {
		ps := r.pools[poolID]
		members := make([]string, 0, len(ps.members))
		for id := range ps.members {
			if _, revoked := ps.revoked[id]; revoked {
				continue
			}
			if !r.providerMembershipAllowedByCreatorCeilingLocked(ps.creatorAccountID, id) {
				continue
			}
			members = append(members, id)
		}
		revoked := make([]string, 0, len(ps.revoked))
		for id := range ps.revoked {
			revoked = append(revoked, id)
		}
		buyers := make([]string, 0, len(ps.buyers))
		for id := range ps.buyers {
			if !r.buyerAllowedByCreatorCeilingLocked(ps.creatorAccountID, id) {
				continue
			}
			buyers = append(buyers, id)
		}
		sort.Strings(members)
		sort.Strings(revoked)
		sort.Strings(buyers)
		out = append(out, RouteableSnapshot{
			PoolID:            poolID,
			CreatorAccountID:  ps.creatorAccountID,
			Members:           members,
			Revoked:           revoked,
			BuyerAccounts:     buyers,
			MinBinaryVersion:  ps.minBinaryVersion,
			ModelAllowlist:    cloneStringSlice(ps.modelAllowlist),
			SettlementMode:    routeablePoolSettlementMode(ps.settlementMode),
			Routeable:         ps.routeable,
			Generation:        ps.generation,
			RouteableUntilUTC: ps.routeableUntilUTC,
			RouteableExpired:  ps.routeableExpired,
		})
	}
	return out
}

// BuyerAuthorizations returns a deterministic account -> pool_id projection for
// gateway-side pool-scope checks. It is intentionally pool-opaque: the gateway
// gets only credential scope, then the coordinator still enforces routeability,
// membership, generation, and freshness on dispatch.
func (r *Registry) BuyerAuthorizations() (map[string][]string, uint64) {
	if r == nil {
		return nil, 0
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	accounts := make(map[string][]string)
	for poolID, ps := range r.pools {
		for accountID := range ps.buyers {
			if !r.buyerAllowedByCreatorCeilingLocked(ps.creatorAccountID, accountID) {
				continue
			}
			accounts[accountID] = append(accounts[accountID], poolID)
		}
	}
	for accountID := range accounts {
		sort.Strings(accounts[accountID])
	}
	return accounts, r.revision + r.ceilingGeneration
}

// Snapshot returns a consistent read of the pool's non-revoked members, its
// binary-version floor, and its generation. For an unknown pool, Exists is
// false and Members is empty, which the routing layer treats as fail-closed
// (no eligible member).
func (r *Registry) Snapshot(poolID string) Snapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ps := r.pools[poolID]
	if ps == nil {
		return Snapshot{PoolID: poolID, Exists: false, Members: map[string]bool{}}
	}
	now := time.Now().UTC()
	routeableExpired := ps.routeableExpired || ps.routeableExpiredAt(now)
	members := make(map[string]bool, len(ps.members))
	for id := range ps.members {
		if _, revoked := ps.revoked[id]; revoked {
			continue
		}
		if !r.providerMembershipAllowedByCreatorCeilingLocked(ps.creatorAccountID, id) {
			continue
		}
		members[id] = true
	}
	return Snapshot{
		PoolID:            poolID,
		Exists:            true,
		Members:           members,
		MinBinaryVersion:  ps.minBinaryVersion,
		ModelAllowlist:    cloneStringSlice(ps.modelAllowlist),
		SettlementMode:    routeablePoolSettlementMode(ps.settlementMode),
		Routeable:         ps.routeableAt(now),
		Generation:        ps.generationAt(now) + r.ceilingGeneration,
		Revision:          r.revision,
		RouteableUntilUTC: ps.routeableUntilUTC,
		RouteableExpired:  routeableExpired,
	}
}

// AuthorizeAndSnapshot reads buyer authorization, routeability, membership, and
// generation under one lock. The caller must carry the returned generation
// through dispatch; any later buyer removal or membership change advances the
// generation and trips the existing pool-state fence.
func (r *Registry) AuthorizeAndSnapshot(poolID, buyerAccountID string) (Snapshot, bool) {
	if r == nil || poolID == "" || buyerAccountID == "" {
		return Snapshot{PoolID: poolID, Members: map[string]bool{}}, false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	ps := r.pools[poolID]
	if ps == nil {
		return Snapshot{PoolID: poolID, Exists: false, Members: map[string]bool{}, Revision: r.revision}, false
	}
	now := time.Now().UTC()
	routeableExpired := ps.routeableExpired || ps.routeableExpiredAt(now)
	members := make(map[string]bool, len(ps.members))
	for id := range ps.members {
		if _, revoked := ps.revoked[id]; revoked {
			continue
		}
		if !r.providerMembershipAllowedByCreatorCeilingLocked(ps.creatorAccountID, id) {
			continue
		}
		members[id] = true
	}
	_, authorized := ps.buyers[buyerAccountID]
	if authorized && !r.buyerAllowedByCreatorCeilingLocked(ps.creatorAccountID, buyerAccountID) {
		authorized = false
	}
	return Snapshot{
		PoolID:            poolID,
		Exists:            true,
		Members:           members,
		MinBinaryVersion:  ps.minBinaryVersion,
		ModelAllowlist:    cloneStringSlice(ps.modelAllowlist),
		SettlementMode:    routeablePoolSettlementMode(ps.settlementMode),
		Routeable:         ps.routeableAt(now),
		Generation:        ps.generationAt(now) + r.ceilingGeneration,
		Revision:          r.revision,
		RouteableUntilUTC: ps.routeableUntilUTC,
		RouteableExpired:  routeableExpired,
	}, authorized
}

// BuyerAuthorized reports whether buyerAccountID may select poolID. Unknown
// pools, empty accounts, and pools without an explicit authorization all fail
// closed.
func (r *Registry) BuyerAuthorized(poolID, buyerAccountID string) bool {
	if r == nil || poolID == "" || buyerAccountID == "" {
		return false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	ps := r.pools[poolID]
	if ps == nil {
		return false
	}
	_, ok := ps.buyers[buyerAccountID]
	if ok && !r.buyerAllowedByCreatorCeilingLocked(ps.creatorAccountID, buyerAccountID) {
		return false
	}
	return ok
}

// Generation returns the current generation for a pool (0 for unknown pools).
func (r *Registry) Generation(poolID string) uint64 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if ps := r.pools[poolID]; ps != nil {
		return ps.generationAt(time.Now().UTC()) + r.ceilingGeneration
	}
	return 0
}

func (ps *poolState) routeableAt(now time.Time) bool {
	if ps == nil || !ps.routeable {
		return false
	}
	if ps.routeableExpired {
		return false
	}
	return !ps.routeableExpiredAt(now)
}

func (ps *poolState) routeableExpiredAt(now time.Time) bool {
	return ps != nil && ps.routeable && !ps.routeableUntilUTC.IsZero() && !now.UTC().Before(ps.routeableUntilUTC.UTC())
}

func (ps *poolState) generationAt(now time.Time) uint64 {
	if ps == nil {
		return 0
	}
	if ps.routeableExpiredAt(now) {
		return ps.generation + 1
	}
	return ps.generation
}

func normalizeCreatorCeilings(in map[string][]string) map[string]map[string]struct{} {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]map[string]struct{}, len(in))
	for creatorID, ids := range in {
		creatorID = strings.TrimSpace(creatorID)
		if creatorID == "" {
			continue
		}
		set := make(map[string]struct{}, len(ids))
		for _, id := range ids {
			id = strings.TrimSpace(id)
			if id == "" {
				continue
			}
			set[id] = struct{}{}
		}
		out[creatorID] = set
	}
	return out
}

func creatorCeilingsEqual(a, b map[string]map[string]struct{}) bool {
	if len(a) != len(b) {
		return false
	}
	for creatorID, aset := range a {
		bset := b[creatorID]
		if !stringSetsEqual(aset, bset) {
			return false
		}
	}
	return true
}

func preserveRemovedCreatorCeilingsAsDenyAll(previous, next map[string]map[string]struct{}) map[string]map[string]struct{} {
	if len(previous) == 0 {
		return next
	}
	if next == nil {
		next = make(map[string]map[string]struct{}, len(previous))
	}
	for creatorID := range previous {
		if _, ok := next[creatorID]; !ok {
			next[creatorID] = map[string]struct{}{}
		}
	}
	return next
}

func (r *Registry) providerMembershipAllowedByCreatorCeilingLocked(creatorID, providerID string) bool {
	if providerID == "" {
		return false
	}
	if creatorID == "" {
		return true
	}
	ownedAllowed := allowedByCreatorCeilingLocked(r.providerCeilings, creatorID, providerID)
	delegatedAllowed := allowedByCreatorCeilingLocked(r.delegatedCeilings, creatorID, providerID)
	_, ownedConfigured := r.providerCeilings[creatorID]
	_, delegatedConfigured := r.delegatedCeilings[creatorID]
	if !ownedConfigured && !delegatedConfigured {
		return true
	}
	if ownedConfigured && ownedAllowed {
		return true
	}
	if delegatedConfigured && delegatedAllowed {
		return true
	}
	return false
}

func (r *Registry) providerAllowedByCreatorCeilingLocked(creatorID, providerID string) bool {
	return allowedByCreatorCeilingLocked(r.providerCeilings, creatorID, providerID)
}

func (r *Registry) providerDelegatedByCreatorCeilingLocked(creatorID, providerID string) bool {
	return allowedByCreatorCeilingLocked(r.delegatedCeilings, creatorID, providerID)
}

func (r *Registry) buyerAllowedByCreatorCeilingLocked(creatorID, buyerAccountID string) bool {
	return allowedByCreatorCeilingLocked(r.buyerCeilings, creatorID, buyerAccountID)
}

func allowedByCreatorCeilingLocked(ceilings map[string]map[string]struct{}, creatorID, id string) bool {
	if len(ceilings) == 0 || creatorID == "" {
		return true
	}
	allowed, configured := ceilings[creatorID]
	if !configured {
		return true
	}
	_, ok := allowed[id]
	return ok
}
