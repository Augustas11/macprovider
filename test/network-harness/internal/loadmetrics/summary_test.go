package loadmetrics

import (
	"math"
	"testing"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/buyer"
	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

// Helper: build a scenario with two prompts (short + medium) so
// PromptFor(buyerIdx, reqIdx) alternates classes.
func demoScenario() *scenario.Scenario {
	return &scenario.Scenario{
		Prompts: []scenario.Prompt{
			{Model: "test", User: "hi", MaxTokens: 16},
			{Model: "test", User: "hi", MaxTokens: 200},
		},
	}
}

func TestGini_EqualDistribution_Zero(t *testing.T) {
	if g := gini([]int{10, 10, 10}); g != 0 {
		t.Fatalf("gini(equal) = %v, want 0", g)
	}
}

func TestGini_MaxInequality(t *testing.T) {
	// One provider took everything; Gini approaches (n-1)/n for large n.
	g := gini([]int{0, 0, 0, 100})
	want := (4.0 - 1.0) / 4.0
	if math.Abs(g-want) > 1e-9 {
		t.Fatalf("gini(one-takes-all) = %v, want %v", g, want)
	}
}

func TestGini_ZeroTotal(t *testing.T) {
	if g := gini([]int{0, 0, 0}); g != 0 {
		t.Fatalf("gini(all-zero) = %v, want 0", g)
	}
}

func TestGini_Empty(t *testing.T) {
	if g := gini(nil); g != 0 {
		t.Fatalf("gini(nil) = %v, want 0", g)
	}
}

func TestStddev_Empty_Zero(t *testing.T) {
	if s := stddev(nil); s != 0 {
		t.Fatalf("stddev(nil) = %v", s)
	}
}

func TestStddev_Uniform_Zero(t *testing.T) {
	if s := stddev([]int{5, 5, 5}); s != 0 {
		t.Fatalf("stddev(uniform) = %v", s)
	}
}

func TestStddev_Known(t *testing.T) {
	// Population stddev of {2,4,4,4,5,5,7,9} is exactly 2.
	got := stddev([]int{2, 4, 4, 4, 5, 5, 7, 9})
	if math.Abs(got-2.0) > 1e-9 {
		t.Fatalf("stddev = %v, want 2", got)
	}
}

func TestMaxMinRatio_ZeroFloor(t *testing.T) {
	// min=0 must not divide by zero.
	r := maxMinRatio([]int{0, 100})
	if r != 100 {
		t.Fatalf("ratio(0,100) = %v, want 100", r)
	}
}

func TestMaxMinRatio_Uniform(t *testing.T) {
	r := maxMinRatio([]int{7, 7, 7})
	if r != 1 {
		t.Fatalf("ratio(uniform) = %v, want 1", r)
	}
}

func TestMaxMinRatio_AllZero(t *testing.T) {
	if r := maxMinRatio([]int{0, 0}); r != 0 {
		t.Fatalf("ratio(all-zero) = %v", r)
	}
}

func TestPct_NearestRank(t *testing.T) {
	xs := []float64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
	if p := pct(xs, 0.50); p != 5 {
		t.Fatalf("p50 = %v, want 5", p)
	}
	if p := pct(xs, 0.95); p != 10 {
		t.Fatalf("p95 = %v, want 10", p)
	}
	if p := pct(xs, 0.99); p != 10 {
		t.Fatalf("p99 = %v, want 10", p)
	}
}

func TestPct_Empty_Zero(t *testing.T) {
	if p := pct(nil, 0.5); p != 0 {
		t.Fatalf("pct(nil) = %v", p)
	}
}

func TestHistogram_Single(t *testing.T) {
	h := histogram([]float64{42})
	if h.P50 != 42 || h.P95 != 42 || h.P99 != 42 || h.Mean != 42 || h.Max != 42 || h.Count != 1 {
		t.Fatalf("single-element histogram = %+v", h)
	}
}

func TestCompute_EvenDistribution(t *testing.T) {
	sc := demoScenario()
	base := time.Unix(1_800_000_000, 0).UTC()
	results := []buyer.Result{}
	for i := 0; i < 6; i++ {
		results = append(results, buyer.Result{
			BuyerIndex: i, RequestIndex: 0,
			Outcome:         "ok",
			RouteProviderID: []string{"A", "B", "C"}[i%3],
			TotalMillis:     100,
			StartUTC:        base,
			EndUTC:          base.Add(time.Second),
		})
	}
	sum := Compute(sc, results, []string{"A", "B", "C"}, nil)
	if len(sum.RouteDistribution) != 3 {
		t.Fatalf("routes = %d, want 3", len(sum.RouteDistribution))
	}
	for _, e := range sum.RouteDistribution {
		if e.Requests != 2 || math.Abs(e.Share-1.0/3.0) > 1e-9 {
			t.Fatalf("uneven share for %s: %+v", e.ProviderID, e)
		}
	}
	if sum.Fairness.Gini != 0 {
		t.Fatalf("gini = %v, want 0 (even)", sum.Fairness.Gini)
	}
	if sum.Fairness.MaxMinRatio != 1 {
		t.Fatalf("ratio = %v, want 1", sum.Fairness.MaxMinRatio)
	}
	if sum.Starvation.MinRequestsPerReadyProvider != 2 {
		t.Fatalf("floor = %v, want 2", sum.Starvation.MinRequestsPerReadyProvider)
	}
	if len(sum.Starvation.ProvidersWithZeroSuccess) != 0 {
		t.Fatalf("unexpected zero-success providers: %v", sum.Starvation.ProvidersWithZeroSuccess)
	}
}

func TestCompute_StarvedProvider(t *testing.T) {
	sc := demoScenario()
	base := time.Unix(1_800_000_000, 0).UTC()
	results := []buyer.Result{}
	for i := 0; i < 10; i++ {
		results = append(results, buyer.Result{
			BuyerIndex: i, RequestIndex: 0,
			Outcome: "ok", RouteProviderID: "A",
			TotalMillis: 100, StartUTC: base, EndUTC: base.Add(time.Second),
		})
	}
	sum := Compute(sc, results, []string{"A", "B", "C"}, nil)
	if sum.Starvation.MinRequestsPerReadyProvider != 0 {
		t.Fatalf("floor = %v, want 0 (B and C got nothing)", sum.Starvation.MinRequestsPerReadyProvider)
	}
	if len(sum.Starvation.ProvidersWithZeroSuccess) != 2 {
		t.Fatalf("zero-success providers = %v, want 2", sum.Starvation.ProvidersWithZeroSuccess)
	}
	// A took 10/10 = 1.0 share; B, C = 0.
	found := map[string]float64{}
	for _, e := range sum.RouteDistribution {
		found[e.ProviderID] = e.Share
	}
	if found["A"] != 1.0 || found["B"] != 0 || found["C"] != 0 {
		t.Fatalf("shares = %v", found)
	}
}

func TestCompute_LatencyByPromptClass(t *testing.T) {
	sc := demoScenario() // Prompt 0 max_tokens=16 (short), Prompt 1 max_tokens=200 (medium)
	base := time.Unix(1_800_000_000, 0).UTC()
	results := []buyer.Result{
		// PromptFor(0,0) → prompt 0 (short)
		{BuyerIndex: 0, RequestIndex: 0, Outcome: "ok", RouteProviderID: "A", TotalMillis: 100, StartUTC: base, EndUTC: base.Add(time.Second)},
		// PromptFor(0,1) → prompt 1 (medium)
		{BuyerIndex: 0, RequestIndex: 1, Outcome: "ok", RouteProviderID: "A", TotalMillis: 500, StartUTC: base, EndUTC: base.Add(time.Second)},
		// PromptFor(1,0) → prompt 1 (medium)
		{BuyerIndex: 1, RequestIndex: 0, Outcome: "ok", RouteProviderID: "A", TotalMillis: 700, StartUTC: base, EndUTC: base.Add(time.Second)},
	}
	sum := Compute(sc, results, []string{"A"}, nil)
	short := sum.LatencyByPromptClass["short_16tok"]
	medium := sum.LatencyByPromptClass["medium_200tok"]
	if short.Count != 1 || short.P50 != 100 {
		t.Fatalf("short bucket = %+v", short)
	}
	if medium.Count != 2 || medium.P50 != 500 {
		t.Fatalf("medium bucket = %+v", medium)
	}
	if short.MaxTokensLower != 1 || short.MaxTokensUpper != 32 {
		t.Fatalf("short bounds = [%d,%d]", short.MaxTokensLower, short.MaxTokensUpper)
	}
}

func TestCompute_LatencyByPromptClass_EmptyBucketStillEmitted(t *testing.T) {
	sc := demoScenario()
	sum := Compute(sc, nil, []string{"A"}, nil)
	// Both default classes must be present with count=0 so downstream
	// tools that diff runs never see a missing key.
	if _, ok := sum.LatencyByPromptClass["short_16tok"]; !ok {
		t.Fatalf("short_16tok missing from empty run")
	}
	if _, ok := sum.LatencyByPromptClass["medium_200tok"]; !ok {
		t.Fatalf("medium_200tok missing from empty run")
	}
}

func TestCompute_FailedRequestsIgnoredInRouting(t *testing.T) {
	sc := demoScenario()
	base := time.Unix(1_800_000_000, 0).UTC()
	results := []buyer.Result{
		{BuyerIndex: 0, RequestIndex: 0, Outcome: "ok", RouteProviderID: "A", TotalMillis: 100, StartUTC: base, EndUTC: base.Add(time.Second)},
		{BuyerIndex: 1, RequestIndex: 0, Outcome: "http_error", RouteProviderID: "A", TotalMillis: 200, StartUTC: base, EndUTC: base.Add(time.Second)},
		{BuyerIndex: 2, RequestIndex: 0, Outcome: "timeout", RouteProviderID: "B", TotalMillis: 60000, StartUTC: base, EndUTC: base.Add(time.Second)},
	}
	sum := Compute(sc, results, []string{"A", "B"}, nil)
	var aReq int
	for _, e := range sum.RouteDistribution {
		if e.ProviderID == "A" {
			aReq = e.Requests
		}
	}
	if aReq != 1 {
		t.Fatalf("A requests = %d, want 1 (failed excluded)", aReq)
	}
}

func TestCompute_FallbackReadySetFromResults(t *testing.T) {
	// No rig-supplied Ready set — Compute must fall back to
	// providers that appear in results (successful OR not).
	sc := demoScenario()
	base := time.Unix(1_800_000_000, 0).UTC()
	results := []buyer.Result{
		{BuyerIndex: 0, RequestIndex: 0, Outcome: "ok", RouteProviderID: "A", TotalMillis: 100, StartUTC: base, EndUTC: base.Add(time.Second)},
		{BuyerIndex: 1, RequestIndex: 0, Outcome: "http_error", RouteProviderID: "B", TotalMillis: 200, StartUTC: base, EndUTC: base.Add(time.Second)},
	}
	sum := Compute(sc, results, nil, nil)
	if sum.Starvation.ReadyProviderCount != 2 {
		t.Fatalf("fallback ready count = %d, want 2", sum.Starvation.ReadyProviderCount)
	}
}

func TestCompute_WindowSeconds(t *testing.T) {
	sc := demoScenario()
	start := time.Unix(1_800_000_000, 0).UTC()
	results := []buyer.Result{
		{BuyerIndex: 0, RequestIndex: 0, Outcome: "ok", TotalMillis: 100, StartUTC: start, EndUTC: start.Add(2 * time.Second)},
		{BuyerIndex: 1, RequestIndex: 0, Outcome: "ok", TotalMillis: 100, StartUTC: start.Add(1 * time.Second), EndUTC: start.Add(10 * time.Second)},
	}
	sum := Compute(sc, results, []string{"A"}, nil)
	if sum.WindowSeconds != 10 {
		t.Fatalf("window = %v, want 10", sum.WindowSeconds)
	}
}

func TestClassIndex_UnknownMaxTokensSkipped(t *testing.T) {
	ci := indexClasses(DefaultClasses)
	if _, ok := ci.match(0); ok {
		t.Fatalf("zero max_tokens should not match any class")
	}
	if _, ok := ci.match(9999); ok {
		t.Fatalf("out-of-range max_tokens should not match any class")
	}
	if lbl, ok := ci.match(16); !ok || lbl != "short_16tok" {
		t.Fatalf("16 → %q,%v", lbl, ok)
	}
}
