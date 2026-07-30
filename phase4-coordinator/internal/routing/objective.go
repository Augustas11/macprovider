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
// BalancedScores. Scores are pre-keyed by `pool.Provider.SortKey()`
// so the comparator can look them up across sort-driven candidate
// swaps.
//
// Per-request perf note (#266 T3c): callers that need the same
// balanced scores downstream (epsilon cohort, routing-decision log)
// should call SortCandidatesWithScores instead — that overload
// surfaces the computed score map so the FR-SR-8 formula doesn't
// recompute O(N) times per request.
func SortCandidates(candidates []pool.Provider, objective Objective, weights Weights) {
	_ = SortCandidatesWithScores(candidates, objective, weights, nil)
}

// SortCandidatesWithScores sorts in-place under the objective and
// returns the per-candidate `balanced` score map when objective is
// ObjectiveBalanced (nil for other objectives). Issue #266 T3c
// caching path — callers that need the same scores downstream
// (epsilon-cohort comparisons, routing-decision log) pass the
// returned map back in via WithBalancedScoreCache so the FR-SR-8
// normative formula runs exactly once per request rather than
// O(N) times.
//
// `cache` is an optional pre-computed balanced-score map (keyed by
// pool.Provider.SortKey()); pass non-nil to reuse a cache from a
// prior call within the same request. nil cache + balanced
// objective recomputes via KeyedBalancedScores.
func SortCandidatesWithScores(candidates []pool.Provider, objective Objective, weights Weights, cache map[string]float64) map[string]float64 {
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
		return nil
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
		return nil
	case ObjectiveBalanced:
		scores := cache
		if scores == nil {
			scores = KeyedBalancedScores(candidates)
		}
		sort.SliceStable(candidates, func(i, j int) bool {
			si := scores[candidates[i].SortKey()]
			sj := scores[candidates[j].SortKey()]
			if si == sj {
				return candidates[i].SlotsFree < candidates[j].SlotsFree
			}
			return si > sj
		})
		return scores
	default:
		sort.SliceStable(candidates, func(i, j int) bool {
			if candidates[i].SlotsFree == candidates[j].SlotsFree {
				return EffectiveThroughput(candidates[i], weights) > EffectiveThroughput(candidates[j], weights)
			}
			return candidates[i].SlotsFree < candidates[j].SlotsFree
		})
		return nil
	}
}

// ObjectiveScores returns a per-candidate scalar score keyed by
// `pool.Provider.SortKey()` for the given objective. Used by the
// routing-decision log surface (CandidateLogEntry.ObjectiveMetric)
// to record what the sort comparator ranked on. For "balanced" the
// SPEC-004 FR-SR-8 formula applies (BalancedScores); for "fast" and
// default it's effective_throughput; for "accurate" it's
// model_params_b. Byte-identical to pre-extraction
// `buyer.Server.routingScores`.
//
// Caching path (#266 T3c): when the caller already has a balanced
// score map from SortCandidatesWithScores, prefer ObjectiveScoresWithCache
// — that overload reuses the cache rather than recomputing.
func ObjectiveScores(candidates []pool.Provider, objective Objective, weights Weights) map[string]float64 {
	return ObjectiveScoresWithCache(candidates, objective, weights, nil)
}

// ObjectiveScoresWithCache is the cache-aware ObjectiveScores. When
// objective is ObjectiveBalanced and `cache` is non-nil, the cache
// is returned directly. Otherwise the function computes and returns
// a fresh map. Issue #266 T3c.
func ObjectiveScoresWithCache(candidates []pool.Provider, objective Objective, weights Weights, cache map[string]float64) map[string]float64 {
	if objective == ObjectiveBalanced {
		if cache != nil {
			return cache
		}
		return KeyedBalancedScores(candidates)
	}
	out := make(map[string]float64, len(candidates))
	for _, p := range candidates {
		switch objective {
		case ObjectiveFast:
			out[p.SortKey()] = EffectiveThroughput(p, weights)
		case ObjectiveAccurate:
			out[p.SortKey()] = p.ModelParamsB
		default:
			out[p.SortKey()] = EffectiveThroughput(p, weights)
		}
	}
	return out
}

// KeyedBalancedScores wraps the indexed BalancedScores and re-keys
// by `pool.Provider.SortKey()` so comparators that survive
// sort-driven candidate swaps can look up scores by stable identity.
// Pre-extraction buyer code did this via a local `balancedScores`
// helper; consolidated here so log + sort surfaces share one
// implementation.
func KeyedBalancedScores(candidates []pool.Provider) map[string]float64 {
	indexed := BalancedScores(candidates)
	out := make(map[string]float64, len(candidates))
	for i, p := range candidates {
		out[p.SortKey()] = indexed[i]
	}
	return out
}
