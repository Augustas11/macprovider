package routing_test

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

func TestWithinRelativeEpsilon_ExactTiePassesAtZeroEpsilon(t *testing.T) {
	t.Parallel()
	if !routing.WithinRelativeEpsilon(100, 100, 0) {
		t.Fatalf("exact tie at epsilon=0: want true")
	}
}

func TestWithinRelativeEpsilon_NonExactFailsAtZeroEpsilon(t *testing.T) {
	t.Parallel()
	if routing.WithinRelativeEpsilon(100, 99.999, 0) {
		t.Fatalf("non-exact tie at epsilon=0: want false (SPEC-004 §5)")
	}
}

func TestWithinRelativeEpsilon_FivePercentBoundary(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name      string
		top, cand float64
		epsilon   float64
		want      bool
	}{
		{"within 5%", 100, 95, 0.05, true},
		{"at 5% boundary", 100, 95.0001, 0.05, true},
		{"just outside 5%", 100, 94.999, 0.05, false},
		{"top below candidate within 5%", 100, 104, 0.05, true},
		{"top below candidate outside 5%", 100, 106, 0.05, false},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := routing.WithinRelativeEpsilon(tc.top, tc.cand, tc.epsilon); got != tc.want {
				t.Fatalf("WithinRelativeEpsilon(%v, %v, %v): want %v, got %v", tc.top, tc.cand, tc.epsilon, tc.want, got)
			}
		})
	}
}

func TestWithinRelativeEpsilon_NegativeEpsilonNeverAdmits(t *testing.T) {
	t.Parallel()
	if routing.WithinRelativeEpsilon(100, 100.0001, -0.05) {
		t.Fatalf("negative epsilon (other than exact tie): want false")
	}
	if !routing.WithinRelativeEpsilon(100, 100, -0.05) {
		t.Fatalf("exact tie still passes regardless of epsilon sign")
	}
}

func TestWithinRelativeEpsilon_TopZeroFallsBackToAbsolute(t *testing.T) {
	t.Parallel()
	// When top=0, relative cohort is undefined; helper falls back
	// to |candidate| <= epsilon. Pins existing server.go behavior.
	if !routing.WithinRelativeEpsilon(0, 0.04, 0.05) {
		t.Fatalf("top=0, |cand|<=epsilon: want true")
	}
	if routing.WithinRelativeEpsilon(0, 0.06, 0.05) {
		t.Fatalf("top=0, |cand|>epsilon: want false")
	}
}

func TestWithinRelativeEpsilon_NegativeMetricsScaledByAbsTop(t *testing.T) {
	t.Parallel()
	// |top|=100, denom=100, |top-cand|=|−100−(−95)|=5, 5 <= 100*0.05 = 5 → true.
	if !routing.WithinRelativeEpsilon(-100, -95, 0.05) {
		t.Fatalf("negative metrics within 5%%: want true")
	}
}

func TestInEpsilonCohort_DefaultRequiresSlotsFreeEqualPlusThroughputCohort(t *testing.T) {
	t.Parallel()
	w := routing.DefaultWeights()
	top := pool.Provider{Tier: pool.TierPinned, ThroughputTPSEstimate: 100, SlotsFree: 4}
	sameSlotsClose := pool.Provider{Tier: pool.TierPinned, ThroughputTPSEstimate: 96, SlotsFree: 4}
	sameSlotsFar := pool.Provider{Tier: pool.TierPinned, ThroughputTPSEstimate: 80, SlotsFree: 4}
	differentSlots := pool.Provider{Tier: pool.TierPinned, ThroughputTPSEstimate: 99, SlotsFree: 3}
	if !routing.InEpsilonCohort(top, sameSlotsClose, routing.ObjectiveDefault, 0.05, w, nil) {
		t.Errorf("default: same slots + throughput within 5%%: want in-cohort")
	}
	if routing.InEpsilonCohort(top, sameSlotsFar, routing.ObjectiveDefault, 0.05, w, nil) {
		t.Errorf("default: same slots + throughput outside 5%%: want out-of-cohort")
	}
	if routing.InEpsilonCohort(top, differentSlots, routing.ObjectiveDefault, 0.05, w, nil) {
		t.Errorf("default: different slots: want out-of-cohort regardless of throughput")
	}
}

func TestInEpsilonCohort_FastUsesEffectiveThroughputWithTierWeight(t *testing.T) {
	t.Parallel()
	// Use Provisional=0.5 (float-exact) to dodge IEEE 754 imprecision
	// that 0.3 introduces; the contract under test is "EffectiveThroughput
	// is applied per-side before WithinRelativeEpsilon" — not the specific
	// weight value.
	w := routing.Weights{Pinned: 1.0, Provisional: 0.5}
	// top pinned tps=100, effective=100; provisional cand tps=180,
	// effective=90 → within 10% of 100 (|100-90|=10, 10 <= 100*0.10).
	top := pool.Provider{Tier: pool.TierPinned, ThroughputTPSEstimate: 100}
	prov := pool.Provider{Tier: pool.TierProvisional, ThroughputTPSEstimate: 180}
	if !routing.InEpsilonCohort(top, prov, routing.ObjectiveFast, 0.10, w, nil) {
		t.Errorf("fast: pinned eff 100 vs provisional eff 90 within 10%%: want in-cohort")
	}
	// Without tier weight (Pinned=1.0, Provisional=1.0), provisional 180
	// would NOT be in 10% cohort of 100.
	wNoTier := routing.Weights{Pinned: 1.0, Provisional: 1.0}
	if routing.InEpsilonCohort(top, prov, routing.ObjectiveFast, 0.10, wNoTier, nil) {
		t.Errorf("fast: no tier-weight: provisional 180 vs 100 should not be in-cohort")
	}
}

func TestInEpsilonCohort_AccurateUsesModelParamsB(t *testing.T) {
	t.Parallel()
	w := routing.DefaultWeights()
	top := pool.Provider{ModelParamsB: 70}
	close := pool.Provider{ModelParamsB: 68}
	far := pool.Provider{ModelParamsB: 50}
	if !routing.InEpsilonCohort(top, close, routing.ObjectiveAccurate, 0.05, w, nil) {
		t.Errorf("accurate: 68B vs 70B within 5%%: want in-cohort")
	}
	if routing.InEpsilonCohort(top, far, routing.ObjectiveAccurate, 0.05, w, nil) {
		t.Errorf("accurate: 50B vs 70B: want out-of-cohort")
	}
}

func TestInEpsilonCohort_BalancedUsesInjectedScores(t *testing.T) {
	t.Parallel()
	w := routing.DefaultWeights()
	top := pool.Provider{ProviderID: "A"}
	cand := pool.Provider{ProviderID: "B"}
	scoreMap := map[string]float64{"A": 0.9, "B": 0.88}
	score := func(p pool.Provider) float64 { return scoreMap[p.ProviderID] }
	if !routing.InEpsilonCohort(top, cand, routing.ObjectiveBalanced, 0.05, w, score) {
		t.Errorf("balanced: 0.88 vs 0.9 within 5%%: want in-cohort")
	}
}

func TestInEpsilonCohort_BalancedNilScoreReturnsFalse(t *testing.T) {
	t.Parallel()
	w := routing.DefaultWeights()
	a := pool.Provider{ProviderID: "A"}
	b := pool.Provider{ProviderID: "B"}
	if routing.InEpsilonCohort(a, b, routing.ObjectiveBalanced, 0.50, w, nil) {
		t.Fatalf("balanced + nil score func: want false (conservative)")
	}
}

func TestInEpsilonCohort_UnknownObjectiveFallsBackToDefault(t *testing.T) {
	t.Parallel()
	w := routing.DefaultWeights()
	top := pool.Provider{Tier: pool.TierPinned, ThroughputTPSEstimate: 100, SlotsFree: 2}
	cand := pool.Provider{Tier: pool.TierPinned, ThroughputTPSEstimate: 98, SlotsFree: 2}
	if !routing.InEpsilonCohort(top, cand, routing.Objective("nonsense"), 0.05, w, nil) {
		t.Errorf("unknown objective: falls back to default branch (slots equal + throughput cohort): want in-cohort")
	}
}
