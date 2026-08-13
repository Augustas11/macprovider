// Package routing holds SPEC-004 smart-router primitives — candidate
// modeling, effective-throughput weighting, epsilon-cohort
// membership, exclusion-set threading, and the eligibility-filter
// pipeline — extracted from internal/buyer/server.go so each
// SPEC-004 pillar (B helpers, C filter, D classes/objectives/retry,
// A sticky) has a single canonical home.
//
// Phase B added Candidate / Weights / EffectiveThroughput /
// Objective / WithinRelativeEpsilon / InEpsilonCohort.
// Phase C added Excluded + EligibleCandidates + EligibilityChecker
// and wired internal/buyer/server.go's selectProviderExcluding
// through EligibleCandidates (filter -> sort -> tiebreak -> preflight).
// Phase D added BalancedScores (FR-SR-8 normative formula) +
// Decision / LogRoutingDecision / CandidateLogEntry (SPEC-004 §7
// routing-decision log surface with legacy aliases preserved for
// pre-Phase-D consumers); server.go's logRoutingDecisionFull
// delegates here.
// Phase A added the sticky/ sub-package (Map / Lookup / Update /
// PurgeAccount / InvalidateClass); server.go's stickyLookup /
// stickyStore / purgeStickyAccount delegate to sticky.Map and
// the inline stickyEntry has been removed.
//
// Issue #266 Tranche 1 (PR #270) closed the operator-green-light
// safety/correctness items: SIGHUP InvalidateClass wiring, per-
// attempt FR-SR-17 log threading at retry/preflight call sites,
// mid-request stable seed across UTC midnight,
// sticky_account_mismatch warn-log rate-limit.
//
// Issue #266 Tranche 2 (this PR) closed the refactor-only
// extractions: objective.go (SortCandidates + ObjectiveScores +
// KeyedBalancedScores), dispatch.go (RewriteModel + jsonValueStart),
// retry.go (RetryHeaderLimit + ShouldRetry + ShouldRetryInput).
// Buyer-side `sortCandidates` / `routingScores` / `dispatchBodyForProvider`
// / `shouldRetry` are now thin delegators.
//
// Still deferred to follow-up commits (not in this PR): BalancedScores
// compute caching threaded through SortCandidates + epsilon + log
// (deferred #266 Tranche 3), more AC-SR-1 byte-identity scenarios
// (T3), HTTP-path integration test for `sticky_account_mismatch`
// warn emission (T3).
//
// AC-SR-1 default-config regression (byte-identical selection vs
// current SPEC-002 v1.5.2 origin/main behavior) is locked by
// internal/buyer/server_test.go::TestDefaultConfigPreservesBaselineProviderSelection
// (with alias TestSPEC004DefaultConfigRegression matching the
// BUILD prompt's checklist command).
package routing

import "github.com/augstar/macprovider-coordinator/internal/pool"

// Candidate wraps a pool.Provider with routing-evaluation metadata.
// Phase B / C carry only the Provider (the EligibilityChecker
// interface in filter.go covers per-provider state queries instead
// of caching them on Candidate). Phase D may add score caches
// (objective metric, balanced-formula component values) here when
// the runtime randomization wiring needs them; future additions
// remain backward-compatible because the struct is opaque to
// callers outside this package.
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
// objective. Any tier value other than pool.TierProvisional, including
// pool.TierTrusted, uses the Pinned weight (this matches server.go's current
// behavior where the implicit default tier — empty string set to TierPinned at
// provider construction — receives weight 1.0).
func EffectiveThroughput(p pool.Provider, w Weights) float64 {
	weight := w.Pinned
	if p.Tier == pool.TierProvisional {
		weight = w.Provisional
	}
	return p.ThroughputTPSEstimate * weight
}
