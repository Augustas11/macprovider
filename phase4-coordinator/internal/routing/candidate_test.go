package routing_test

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

func TestEffectiveThroughput_PinnedDefaultsToOne(t *testing.T) {
	t.Parallel()
	w := routing.DefaultWeights()
	p := pool.Provider{
		Tier:                  pool.TierPinned,
		ThroughputTPSEstimate: 100,
	}
	if got := routing.EffectiveThroughput(p, w); got != 100 {
		t.Fatalf("pinned tier with default weights: want 100, got %v", got)
	}
}

func TestEffectiveThroughput_ProvisionalUsesWeight(t *testing.T) {
	t.Parallel()
	w := routing.DefaultWeights()
	p := pool.Provider{
		Tier:                  pool.TierProvisional,
		ThroughputTPSEstimate: 100,
	}
	if got := routing.EffectiveThroughput(p, w); got != 30 {
		t.Fatalf("provisional with default 0.3 weight: want 30, got %v", got)
	}
}

func TestEffectiveThroughput_EmptyTierTreatedAsPinned(t *testing.T) {
	// pool.Provider construction defaults empty tier to TierPinned;
	// callers passing a zero-value tier must still receive the
	// pinned weight. This pins server.go's current behavior.
	t.Parallel()
	w := routing.DefaultWeights()
	p := pool.Provider{
		Tier:                  "",
		ThroughputTPSEstimate: 50,
	}
	if got := routing.EffectiveThroughput(p, w); got != 50 {
		t.Fatalf("empty tier (treated as pinned): want 50, got %v", got)
	}
}

func TestEffectiveThroughput_ZeroThroughputStaysZero(t *testing.T) {
	t.Parallel()
	w := routing.DefaultWeights()
	p := pool.Provider{
		Tier:                  pool.TierProvisional,
		ThroughputTPSEstimate: 0,
	}
	if got := routing.EffectiveThroughput(p, w); got != 0 {
		t.Fatalf("zero throughput * 0.3: want 0, got %v", got)
	}
}

func TestEffectiveThroughput_CustomWeightsRespected(t *testing.T) {
	t.Parallel()
	w := routing.Weights{Pinned: 2.0, Provisional: 0.5}
	pinned := pool.Provider{Tier: pool.TierPinned, ThroughputTPSEstimate: 10}
	prov := pool.Provider{Tier: pool.TierProvisional, ThroughputTPSEstimate: 10}
	if got := routing.EffectiveThroughput(pinned, w); got != 20 {
		t.Fatalf("custom pinned=2.0: want 20, got %v", got)
	}
	if got := routing.EffectiveThroughput(prov, w); got != 5 {
		t.Fatalf("custom provisional=0.5: want 5, got %v", got)
	}
}

func TestDefaultWeights_MatchesSPEC002V11(t *testing.T) {
	t.Parallel()
	w := routing.DefaultWeights()
	if w.Pinned != 1.0 {
		t.Errorf("default pinned: want 1.0, got %v", w.Pinned)
	}
	if w.Provisional != 0.3 {
		t.Errorf("default provisional: want 0.3, got %v", w.Provisional)
	}
}

func TestCandidate_WrapsProvider(t *testing.T) {
	// Phase B Candidate is intentionally minimal — Provider only.
	// This test pins the field so a Phase C/D addition doesn't
	// accidentally shadow it.
	t.Parallel()
	p := pool.Provider{ProviderID: "p-1"}
	c := routing.Candidate{Provider: p}
	if c.Provider.ProviderID != "p-1" {
		t.Fatalf("Candidate.Provider.ProviderID: want p-1, got %q", c.Provider.ProviderID)
	}
}
