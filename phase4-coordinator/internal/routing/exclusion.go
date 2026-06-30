package routing

import "github.com/augstar/macprovider-coordinator/internal/pool"

// Excluded is a typed set of providers that must not be selected for
// the current request. It supports the SPEC-004 FR-SR-19 composition
// requirement that F-4 dead-WS failover and SPEC-004 retry share a
// single excluded-provider set so the same dead provider is not
// selected twice within one buyer request.
//
// Phase C exposes the set via Add / Has / Len so server.go and the
// retry loop (Phase D) can thread the same exclusion through every
// selection attempt. The underlying key derivation mirrors the
// existing routeKey helper: a stable string built from
// (provider_id, assigned_id) so two distinct admissions of the same
// peer are treated as separate providers.
type Excluded struct {
	keys map[string]struct{}
}

// NewExcluded returns an empty exclusion set with capacity hint
// based on the expected fault-cap for the current request.
func NewExcluded(capacityHint int) Excluded {
	return Excluded{keys: make(map[string]struct{}, capacityHint)}
}

// Add records a provider key in the exclusion set. The keyer
// argument lets the caller supply the same routeKey function used
// elsewhere in the selection pipeline; Phase C/D wire this from
// buyer/server.go's existing helper to keep key derivation
// byte-identical across the two callers.
func (e Excluded) Add(p pool.Provider, keyer func(pool.Provider) string) {
	if e.keys == nil {
		return
	}
	e.keys[keyer(p)] = struct{}{}
}

// AddKey records a pre-computed key, useful when the caller already
// holds the routeKey result (avoids re-computing it inside loops).
func (e Excluded) AddKey(key string) {
	if e.keys == nil {
		return
	}
	e.keys[key] = struct{}{}
}

// Has reports whether the supplied provider key is in the set.
func (e Excluded) Has(key string) bool {
	if e.keys == nil {
		return false
	}
	_, ok := e.keys[key]
	return ok
}

// Len returns the count of distinct provider keys excluded so far.
// Phase D uses this against
// routing.max_providers_faulted_per_request as the per-request
// breaker fault cap (FR-SR-14).
func (e Excluded) Len() int {
	return len(e.keys)
}
