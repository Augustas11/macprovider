// Package routing holds SPEC-004 smart-router primitives — candidate
// modeling, effective-throughput weighting, and epsilon-cohort
// membership — extracted from internal/buyer/server.go so Phase C/D
// can refactor the selection path against a single canonical home.
//
// Phase B scope: this package exists as a scaffolding-only addition.
// The active selection path in internal/buyer/server.go is NOT yet
// wired through these functions; AC-SR-1 default-config regression
// (byte-identical selection vs current SPEC-002 v1.5.2 origin/main
// behavior) is the load-bearing test for Phase B and is preserved
// because server.go is unchanged.
package routing

import "github.com/augstar/macprovider-coordinator/internal/pool"

// Candidate wraps a pool.Provider with routing-evaluation metadata.
// Phase B carries only the Provider; Phase C will add eligibility
// state (post-filter status, exclusion reason, breaker hold) and
// Phase D will add score caches (objective metric, balanced
// component values).
type Candidate struct {
	Provider pool.Provider
}

// Weights captures tier multipliers used in the effective-throughput
// computation. Defaults match SPEC-002 v1.1 §5 Step 2.5:
// Pinned=1.0, Provisional=0.3 (operator-tunable via
// admission.provisional_tier_weight). DefaultWeights returns the
// SPEC-002 v1.1 defaults; production callers SHOULD source the
// Provisional weight from coordinator config and pass it through
// rather than hard-coding 0.3 — Phase D wiring will do that.
type Weights struct {
	Pinned      float64
	Provisional float64
}

// DefaultWeights returns the SPEC-002 v1.1 default tier weights.
func DefaultWeights() Weights {
	return Weights{Pinned: 1.0, Provisional: 0.3}
}

// EffectiveThroughput computes throughput_tps_estimate * tier_weight
// per SPEC-002 v1.1 §5 Step 2.5 and SPEC-004 FR-SR-8 "fast"
// objective. Any tier value other than pool.TierProvisional uses
// the Pinned weight (this matches server.go's current behavior where
// the implicit default tier — empty string set to TierPinned at
// provider construction — receives weight 1.0).
func EffectiveThroughput(p pool.Provider, w Weights) float64 {
	weight := w.Pinned
	if p.Tier == pool.TierProvisional {
		weight = w.Provisional
	}
	return p.ThroughputTPSEstimate * weight
}
