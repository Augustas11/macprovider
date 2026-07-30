package routing_test

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

// TestSortCandidatesWithScores_ReturnsBalancedCache pins the
// issue #266 T3c contract that the balanced-score map surfaced by
// SortCandidatesWithScores matches what KeyedBalancedScores would
// compute fresh — so downstream consumers can reuse the cache
// instead of recomputing the FR-SR-8 normative formula.
func TestSortCandidatesWithScores_ReturnsBalancedCache(t *testing.T) {
	cands := []pool.Provider{
		makeProvider("a", 100, 10, 5, pool.TierPinned),
		makeProvider("b", 200, 20, 3, pool.TierPinned),
		makeProvider("c", 50, 5, 8, pool.TierPinned),
	}
	cache := routing.SortCandidatesWithScores(cands, routing.ObjectiveBalanced, routing.DefaultWeights(), nil)
	if cache == nil {
		t.Fatalf("balanced objective must surface a cache map")
	}
	// Independent recompute must match.
	fresh := routing.KeyedBalancedScores([]pool.Provider{
		makeProvider("a", 100, 10, 5, pool.TierPinned),
		makeProvider("b", 200, 20, 3, pool.TierPinned),
		makeProvider("c", 50, 5, 8, pool.TierPinned),
	})
	for k, v := range fresh {
		if got := cache[k]; got != v {
			t.Fatalf("cache[%s] = %v; want %v", k, got, v)
		}
	}
}

func TestSortCandidatesWithScores_NonBalancedReturnsNil(t *testing.T) {
	cands := []pool.Provider{
		makeProvider("a", 100, 10, 5, pool.TierPinned),
	}
	for _, obj := range []routing.Objective{routing.ObjectiveFast, routing.ObjectiveAccurate, routing.ObjectiveDefault} {
		if cache := routing.SortCandidatesWithScores(cands, obj, routing.DefaultWeights(), nil); cache != nil {
			t.Fatalf("objective %q must return nil cache; got %v", obj, cache)
		}
	}
}

func TestSortCandidatesWithScores_AcceptsExternalCache(t *testing.T) {
	// When the caller supplies a pre-computed cache, SortCandidatesWithScores
	// uses it instead of recomputing.
	cands := []pool.Provider{
		makeProvider("a", 100, 10, 5, pool.TierPinned),
		makeProvider("b", 200, 20, 3, pool.TierPinned),
	}
	// Inject an INVALID cache to prove the function reads from it.
	bogus := map[string]float64{
		"a/a": 99999, // makes "a" the top by score
		"b/b": 1,
	}
	routing.SortCandidatesWithScores(cands, routing.ObjectiveBalanced, routing.DefaultWeights(), bogus)
	if cands[0].ProviderID != "a" {
		t.Fatalf("external cache must drive the sort; expected a first, got %s", cands[0].ProviderID)
	}
}

func TestObjectiveScoresWithCache_ReusesBalancedCache(t *testing.T) {
	bogus := map[string]float64{"a/a": 12345}
	cands := []pool.Provider{makeProvider("a", 100, 10, 5, pool.TierPinned)}
	got := routing.ObjectiveScoresWithCache(cands, routing.ObjectiveBalanced, routing.DefaultWeights(), bogus)
	if got["a/a"] != 12345 {
		t.Fatalf("ObjectiveScoresWithCache must return the supplied balanced cache verbatim; got %v", got["a/a"])
	}
}

func TestObjectiveScoresWithCache_NonBalancedIgnoresCache(t *testing.T) {
	// For non-balanced objectives the cache is meaningless; the
	// function must recompute from the candidates / weights.
	bogus := map[string]float64{"a/a": 12345}
	cands := []pool.Provider{makeProvider("a", 100, 10, 5, pool.TierPinned)}
	got := routing.ObjectiveScoresWithCache(cands, routing.ObjectiveFast, routing.DefaultWeights(), bogus)
	if got["a/a"] != 100 {
		t.Fatalf("non-balanced must recompute; expected 100 (eff_tps), got %v", got["a/a"])
	}
}

// BenchmarkRoutingScoresPipeline measures the difference between
// recompute-each-call and cache-reuse for a representative 16-provider
// balanced selection. Pre-T3c the FR-SR-8 formula ran ~4× per request:
// once in sort, once in epsilon, twice in log emission. T3c makes
// downstream calls O(1) map lookups.
func BenchmarkRoutingScoresPipeline_NoCache(b *testing.B) {
	cands := benchmarkCandidates(16)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		routing.KeyedBalancedScores(cands) // sort
		routing.KeyedBalancedScores(cands) // epsilon
		routing.KeyedBalancedScores(cands) // log set
	}
}

func BenchmarkRoutingScoresPipeline_WithCache(b *testing.B) {
	cands := benchmarkCandidates(16)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		cache := routing.SortCandidatesWithScores(cands, routing.ObjectiveBalanced, routing.DefaultWeights(), nil)
		_ = routing.ObjectiveScoresWithCache(cands, routing.ObjectiveBalanced, routing.DefaultWeights(), cache)
		_ = routing.ObjectiveScoresWithCache(cands, routing.ObjectiveBalanced, routing.DefaultWeights(), cache)
	}
}

func benchmarkCandidates(n int) []pool.Provider {
	out := make([]pool.Provider, n)
	for i := 0; i < n; i++ {
		out[i] = pool.Provider{
			ProviderID:            "p" + string(rune('a'+i)),
			AssignedID:            "a" + string(rune('a'+i)),
			State:                 pool.StateReady,
			SlotsFree:             1 + i%4,
			SlotsTotal:            4,
			ThroughputTPSEstimate: float64(50 + i*10),
			ModelParamsB:          float64(1 + i),
			MaxContextTokens:      4096,
		}
	}
	return out
}
