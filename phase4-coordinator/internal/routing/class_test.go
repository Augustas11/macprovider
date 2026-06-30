package routing_test

import (
	"math"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

func TestBalancedScores_EmptyInput(t *testing.T) {
	t.Parallel()
	got := routing.BalancedScores(nil)
	if len(got) != 0 {
		t.Fatalf("empty input: want empty slice, got %v", got)
	}
}

func TestBalancedScores_SingleCandidateAllOnes(t *testing.T) {
	// With one candidate, every norm() degenerates to "all values
	// identical" → 1.0. Final score = 0.4 + 0.3 + 0.2 + 0.1 = 1.0.
	t.Parallel()
	p := pool.Provider{
		ThroughputTPSEstimate: 100,
		ModelParamsB:          70,
		MaxContextTokens:      8192,
		SlotsFree:             4,
		SlotsTotal:            4,
	}
	got := routing.BalancedScores([]pool.Provider{p})
	if len(got) != 1 {
		t.Fatalf("len: want 1, got %d", len(got))
	}
	if math.Abs(got[0]-1.0) > 1e-9 {
		t.Errorf("single-candidate score: want 1.0, got %v", got[0])
	}
}

func TestBalancedScores_NormativeFormulaWeights(t *testing.T) {
	// Two candidates with extreme spread on tps only:
	// p1 tps=100, params=10, ctx=1000, slots=0.5
	// p2 tps=0,   params=10, ctx=1000, slots=0.5
	// norm(tps): p1=1, p2=0; norm(params)=1 each; norm(ctx)=1 each;
	// norm(slots)=1 each.
	// p1 score = 0.4*1 + 0.3*1 + 0.2*1 + 0.1*1 = 1.0
	// p2 score = 0.4*0 + 0.3*1 + 0.2*1 + 0.1*1 = 0.6
	t.Parallel()
	p1 := pool.Provider{ThroughputTPSEstimate: 100, ModelParamsB: 10, MaxContextTokens: 1000, SlotsFree: 2, SlotsTotal: 4}
	p2 := pool.Provider{ThroughputTPSEstimate: 0, ModelParamsB: 10, MaxContextTokens: 1000, SlotsFree: 2, SlotsTotal: 4}
	got := routing.BalancedScores([]pool.Provider{p1, p2})
	if math.Abs(got[0]-1.0) > 1e-9 {
		t.Errorf("p1: want 1.0, got %v", got[0])
	}
	if math.Abs(got[1]-0.6) > 1e-9 {
		t.Errorf("p2: want 0.6 (0.4*0 + 0.3*1 + 0.2*1 + 0.1*1), got %v", got[1])
	}
}

func TestBalancedScores_AllIdenticalAllPerfect(t *testing.T) {
	// When every candidate has identical component values, every
	// norm degenerates to 1.0 → every candidate scores 1.0.
	t.Parallel()
	p := pool.Provider{ThroughputTPSEstimate: 50, ModelParamsB: 30, MaxContextTokens: 4096, SlotsFree: 1, SlotsTotal: 1}
	got := routing.BalancedScores([]pool.Provider{p, p, p})
	for i, s := range got {
		if math.Abs(s-1.0) > 1e-9 {
			t.Errorf("candidate %d: want 1.0 (identical metrics), got %v", i, s)
		}
	}
}

func TestBalancedScores_SlotsTotalZeroDoesNotDivByZero(t *testing.T) {
	// SlotsTotal=0 means slot-share = 0 (no division). Don't panic.
	t.Parallel()
	p1 := pool.Provider{ThroughputTPSEstimate: 100, ModelParamsB: 10, MaxContextTokens: 1000, SlotsTotal: 0}
	p2 := pool.Provider{ThroughputTPSEstimate: 0, ModelParamsB: 10, MaxContextTokens: 1000, SlotsTotal: 0}
	got := routing.BalancedScores([]pool.Provider{p1, p2})
	if len(got) != 2 {
		t.Fatalf("len: want 2, got %d", len(got))
	}
	// Both have slot-share=0, so norm(slots) is "all identical" → 1.0.
	// p1: 0.4*1 + 0.3*1 + 0.2*1 + 0.1*1 = 1.0
	// p2: 0.4*0 + 0.3*1 + 0.2*1 + 0.1*1 = 0.6
	if math.Abs(got[0]-1.0) > 1e-9 || math.Abs(got[1]-0.6) > 1e-9 {
		t.Errorf("scores: want [1.0, 0.6], got %v", got)
	}
}
