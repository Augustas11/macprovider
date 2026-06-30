package routing_test

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

// TestSortCandidates pins the SPEC-004 §6 per-objective ranking
// extracted from buyer.Server.sortCandidates in issue #266 T2. Each
// case exercises ONE objective branch + its tiebreak rule.

func makeProvider(id string, tps, params float64, slotsFree int, tier pool.Tier) pool.Provider {
	return pool.Provider{
		ProviderID:            id,
		AssignedID:            id,
		State:                 pool.StateReady,
		Tier:                  tier,
		SlotsFree:             slotsFree,
		SlotsTotal:            1,
		ThroughputTPSEstimate: tps,
		ModelParamsB:          params,
	}
}

func TestSortCandidates_Fast_ThroughputDescThenSlotsAsc(t *testing.T) {
	cands := []pool.Provider{
		makeProvider("a", 100, 0, 5, pool.TierPinned),
		makeProvider("b", 200, 0, 3, pool.TierPinned),
		makeProvider("c", 200, 0, 1, pool.TierPinned), // ties with b on tps; lower slots wins tiebreak
	}
	routing.SortCandidates(cands, routing.ObjectiveFast, routing.DefaultWeights())
	if cands[0].ProviderID != "c" {
		t.Fatalf("expected c (top tps + low slots) first, got %s", cands[0].ProviderID)
	}
	if cands[1].ProviderID != "b" {
		t.Fatalf("expected b second, got %s", cands[1].ProviderID)
	}
}

func TestSortCandidates_Accurate_ParamsDescThenTpsThenSlots(t *testing.T) {
	cands := []pool.Provider{
		makeProvider("a", 100, 7.0, 3, pool.TierPinned),
		makeProvider("b", 100, 70.0, 3, pool.TierPinned), // higher params wins
		makeProvider("c", 200, 70.0, 5, pool.TierPinned), // ties b on params; higher tps wins
	}
	routing.SortCandidates(cands, routing.ObjectiveAccurate, routing.DefaultWeights())
	if cands[0].ProviderID != "c" {
		t.Fatalf("expected c (top params + top tps) first, got %s", cands[0].ProviderID)
	}
	if cands[1].ProviderID != "b" {
		t.Fatalf("expected b (top params + lower tps) second, got %s", cands[1].ProviderID)
	}
}

func TestSortCandidates_Default_SlotsAscThenTpsDesc(t *testing.T) {
	cands := []pool.Provider{
		makeProvider("a", 100, 0, 5, pool.TierPinned),
		makeProvider("b", 200, 0, 5, pool.TierPinned), // ties a on slots; higher tps wins
		makeProvider("c", 100, 0, 1, pool.TierPinned), // lowest slots wins overall
	}
	routing.SortCandidates(cands, routing.ObjectiveDefault, routing.DefaultWeights())
	if cands[0].ProviderID != "c" {
		t.Fatalf("expected c (lowest slots) first, got %s", cands[0].ProviderID)
	}
	if cands[1].ProviderID != "b" {
		t.Fatalf("expected b (tied slots, higher tps) second, got %s", cands[1].ProviderID)
	}
}

func TestSortCandidates_StableUnderEqualOrdering(t *testing.T) {
	// All-equal candidates must retain input order — sticky-affinity
	// targets land in a specific position before sort and must not
	// drift down the cohort. Stable-sort invariant pinned here.
	cands := []pool.Provider{
		makeProvider("a", 100, 1, 1, pool.TierPinned),
		makeProvider("b", 100, 1, 1, pool.TierPinned),
		makeProvider("c", 100, 1, 1, pool.TierPinned),
	}
	routing.SortCandidates(cands, routing.ObjectiveFast, routing.DefaultWeights())
	want := []string{"a", "b", "c"}
	for i, w := range want {
		if cands[i].ProviderID != w {
			t.Fatalf("expected stable order %v, got %v at index %d", want, cands[i].ProviderID, i)
		}
	}
}

func TestSortCandidates_BalancedScoresRouteFromBalancedScores(t *testing.T) {
	// Balanced objective uses BalancedScores; verify the comparator
	// reads the keyed score (not a raw field) by giving one candidate
	// every dimension's max.
	cands := []pool.Provider{
		makeProvider("low", 1, 1, 99, pool.TierPinned),
		makeProvider("top", 1000, 1000, 0, pool.TierPinned), // wins tps + params + ctx; slots small but balanced dominates
	}
	cands[1].MaxContextTokens = 1000
	routing.SortCandidates(cands, routing.ObjectiveBalanced, routing.DefaultWeights())
	if cands[0].ProviderID != "top" {
		t.Fatalf("expected top (balanced wins) first, got %s", cands[0].ProviderID)
	}
}

func TestSortCandidates_ProvisionalDownweightedUnderFast(t *testing.T) {
	// Provisional tier multiplies tps by Weights.Provisional. With
	// the SPEC-002 v1.1 default (0.3), a provisional provider at
	// 333 raw tps becomes ~99 effective and ranks BELOW a pinned
	// provider at 100 raw tps.
	weights := routing.Weights{Pinned: 1.0, Provisional: 0.3}
	cands := []pool.Provider{
		makeProvider("provis", 333, 0, 3, pool.TierProvisional),
		makeProvider("pinned", 100, 0, 3, pool.TierPinned),
	}
	routing.SortCandidates(cands, routing.ObjectiveFast, weights)
	if cands[0].ProviderID != "pinned" {
		t.Fatalf("expected pinned (effective 100) first over provisional (effective 99.9), got %s", cands[0].ProviderID)
	}
}

func TestObjectiveScores_FastReturnsEffectiveThroughput(t *testing.T) {
	cands := []pool.Provider{
		makeProvider("a", 100, 0, 0, pool.TierPinned),
	}
	scores := routing.ObjectiveScores(cands, routing.ObjectiveFast, routing.DefaultWeights())
	if got := scores["a/a"]; got != 100 {
		t.Fatalf("expected fast score = effective tps 100, got %v", got)
	}
}

func TestObjectiveScores_AccurateReturnsParams(t *testing.T) {
	cands := []pool.Provider{makeProvider("a", 100, 42, 0, pool.TierPinned)}
	scores := routing.ObjectiveScores(cands, routing.ObjectiveAccurate, routing.DefaultWeights())
	if got := scores["a/a"]; got != 42 {
		t.Fatalf("expected accurate score = params 42, got %v", got)
	}
}

func TestObjectiveScores_BalancedDelegatesToKeyedBalancedScores(t *testing.T) {
	cands := []pool.Provider{
		makeProvider("a", 100, 10, 5, pool.TierPinned),
		makeProvider("b", 200, 20, 3, pool.TierPinned),
	}
	scores := routing.ObjectiveScores(cands, routing.ObjectiveBalanced, routing.DefaultWeights())
	keyed := routing.KeyedBalancedScores(cands)
	if scores["a/a"] != keyed["a/a"] || scores["b/b"] != keyed["b/b"] {
		t.Fatalf("balanced ObjectiveScores must match KeyedBalancedScores; got %v vs %v", scores, keyed)
	}
}
