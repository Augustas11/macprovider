package routing

import (
	"sort"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// SortCandidates sorts the candidate slice in-place by the SPEC-004
// §6 per-objective ranking. Behaviour is byte-identical to the
// pre-extraction `buyer.Server.sortCandidates` (PR #266 T2 — issue
// #266 deferred refactor):
//
//	"fast"      → effective_throughput desc, slots_free asc tiebreak
//	"accurate"  → model_params_b desc, then eff_tps desc, then slots_free asc
//	"balanced"  → BalancedScores desc, slots_free asc tiebreak
//	default     → slots_free asc, eff_tps desc tiebreak
//
// Stable sort everywhere so providers that compare equal under the
// objective retain their input ordering — this matters because the
// caller may have applied sticky-affinity (applySticky) BEFORE the
// sort and the sticky-target candidate must not drift down the cohort.
//
// EffectiveThroughput receives Weights so the per-provisional-tier
// downweight (default 0.3 per SPEC-002 v1.1 §5 Step 2.5) is honored;
// callers should pass DefaultWeights().With(provisional=s.provisionalWeight).
//
// `balanced` uses the SPEC-004 FR-SR-8 normative score formula via
// BalancedScores. Scores are pre-keyed by ProviderID+/+AssignedID
// (mirroring buyer.routeKey) so the comparator can look them up
// across sort-driven candidate swaps.
func SortCandidates(candidates []pool.Provider, objective Objective, weights Weights) {
	switch objective {
	case ObjectiveFast:
		sort.SliceStable(candidates, func(i, j int) bool {
			ti := EffectiveThroughput(candidates[i], weights)
			tj := EffectiveThroughput(candidates[j], weights)
			if ti == tj {
				return candidates[i].SlotsFree < candidates[j].SlotsFree
			}
			return ti > tj
		})
	case ObjectiveAccurate:
		sort.SliceStable(candidates, func(i, j int) bool {
			if candidates[i].ModelParamsB == candidates[j].ModelParamsB {
				ti := EffectiveThroughput(candidates[i], weights)
				tj := EffectiveThroughput(candidates[j], weights)
				if ti != tj {
					return ti > tj
				}
				return candidates[i].SlotsFree < candidates[j].SlotsFree
			}
			return candidates[i].ModelParamsB > candidates[j].ModelParamsB
		})
	case ObjectiveBalanced:
		scores := KeyedBalancedScores(candidates)
		sort.SliceStable(candidates, func(i, j int) bool {
			si := scores[providerSortKey(candidates[i])]
			sj := scores[providerSortKey(candidates[j])]
			if si == sj {
				return candidates[i].SlotsFree < candidates[j].SlotsFree
			}
			return si > sj
		})
	default:
		sort.SliceStable(candidates, func(i, j int) bool {
			if candidates[i].SlotsFree == candidates[j].SlotsFree {
				return EffectiveThroughput(candidates[i], weights) > EffectiveThroughput(candidates[j], weights)
			}
			return candidates[i].SlotsFree < candidates[j].SlotsFree
		})
	}
}

// ObjectiveScores returns a per-candidate scalar score keyed by
// ProviderID+/+AssignedID for the given objective. Used by the
// routing-decision log surface (CandidateLogEntry.ObjectiveMetric)
// to record what the sort comparator ranked on. For "balanced" the
// SPEC-004 FR-SR-8 formula applies (BalancedScores); for "fast" and
// default it's effective_throughput; for "accurate" it's
// model_params_b. Byte-identical to pre-extraction
// `buyer.Server.routingScores`.
func ObjectiveScores(candidates []pool.Provider, objective Objective, weights Weights) map[string]float64 {
	if objective == ObjectiveBalanced {
		return KeyedBalancedScores(candidates)
	}
	out := make(map[string]float64, len(candidates))
	for _, p := range candidates {
		switch objective {
		case ObjectiveFast:
			out[providerSortKey(p)] = EffectiveThroughput(p, weights)
		case ObjectiveAccurate:
			out[providerSortKey(p)] = p.ModelParamsB
		default:
			out[providerSortKey(p)] = EffectiveThroughput(p, weights)
		}
	}
	return out
}

// KeyedBalancedScores wraps the indexed BalancedScores and re-keys
// by ProviderID+/+AssignedID so comparators that survive
// sort-driven candidate swaps can look up scores by stable identity.
// Pre-extraction buyer code did this via a local `balancedScores`
// helper; consolidated here so log + sort surfaces share one
// implementation.
func KeyedBalancedScores(candidates []pool.Provider) map[string]float64 {
	indexed := BalancedScores(candidates)
	out := make(map[string]float64, len(candidates))
	for i, p := range candidates {
		out[providerSortKey(p)] = indexed[i]
	}
	return out
}

// providerSortKey mirrors buyer.routeKey (ProviderID+"/"+AssignedID).
// Kept internal to the routing package so the package owns its own
// stable key derivation; buyer can continue to use its own routeKey
// for log + sticky surfaces (the strings happen to match exactly,
// which is required because the routing-decision log emits the same
// shape).
func providerSortKey(p pool.Provider) string {
	return p.ProviderID + "/" + p.AssignedID
}
