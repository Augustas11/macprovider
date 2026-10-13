package routing

import (
	"regexp"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func phaseProvider(id string, free, total int) pool.Provider {
	return pool.Provider{ProviderID: id, AssignedID: "s-" + id, ModelID: "m", SlotsFree: free, SlotsTotal: total}
}

// warm gives provider id a fresh record with the given TTFT, prefill and
// decode rates.
func warm(s *PerfStore, id string, ttftMs, prefillTPS, decodeTPS float64) {
	prompt := int64(prefillTPS * ttftMs / 1000)
	decodeMs := 1000.0
	completion := int64(decodeTPS) + 1
	for i := 0; i < PerfFreshMinSamples; i++ {
		s.Observe(PerfObservation{ProviderID: id, Model: "m", PromptTokens: prompt, CompletionTokens: completion, TTFTMs: ttftMs, DecodeMs: decodeMs, At: perfNow})
	}
}

func ids(ps []pool.Provider) []string {
	out := make([]string, len(ps))
	for i, p := range ps {
		out[i] = p.ProviderID
	}
	return out
}

func TestClassifyPhase(t *testing.T) {
	cases := []struct {
		input, maxOut int
		stream        bool
		want          Phase
	}{
		{100, 256, true, PhaseInteractive},
		{100, 256, false, PhaseThroughput},
		{8000, 256, true, PhaseLongInput},
		{8000, 4000, true, PhaseInteractive},
		{4000, 0, false, PhaseLongInput}, // absent max_tokens defaults to 512
		{2047, 1, true, PhaseInteractive},
	}
	for _, c := range cases {
		if got := ClassifyPhase(c.input, c.maxOut, c.stream); got != c.want {
			t.Errorf("ClassifyPhase(%d,%d,%v)=%s want %s", c.input, c.maxOut, c.stream, got, c.want)
		}
	}
	if got := ClassifyPhase(1000, 0, false); got != PhaseThroughput {
		t.Errorf("short non-stream = %s", got)
	}
}

func TestPhaseOrderPrefersMeasuredFitPerPhase(t *testing.T) {
	s := NewPerfStore()
	// fast-ttft: low TTFT, slow prefill; big: high prefill and decode, high TTFT.
	warm(s, "fast-ttft", 50, 1000, 60)
	warm(s, "big", 400, 20000, 60)
	for _, tc := range []struct {
		phase Phase
		want  string
	}{
		{PhaseInteractive, "fast-ttft"},
		{PhaseLongInput, "big"},
	} {
		// The objective order puts the wrong provider first each time.
		candidates := []pool.Provider{phaseProvider("big", 1, 1), phaseProvider("fast-ttft", 1, 1)}
		if tc.phase == PhaseLongInput {
			candidates[0], candidates[1] = candidates[1], candidates[0]
		}
		d := PhaseOrder(candidates, "m", tc.phase, s, perfNow, 0.99, 0)
		if d.Basis != BasisMeasured || candidates[0].ProviderID != tc.want {
			t.Fatalf("%s: basis=%s order=%v", tc.phase, d.Basis, ids(candidates))
		}
	}
	// Throughput prefers free slots times decode rate.
	s2 := NewPerfStore()
	warm(s2, "one-slot", 50, 1000, 100)
	warm(s2, "four-slots", 50, 1000, 60)
	candidates := []pool.Provider{phaseProvider("one-slot", 1, 1), phaseProvider("four-slots", 4, 4)}
	d := PhaseOrder(candidates, "m", PhaseThroughput, s2, perfNow, 0.99, 0)
	if d.Basis != BasisMeasured || candidates[0].ProviderID != "four-slots" {
		t.Fatalf("throughput: basis=%s order=%v", d.Basis, ids(candidates))
	}
}

func TestPhaseOrderFallsBackWithoutEvidence(t *testing.T) {
	s := NewPerfStore()
	candidates := []pool.Provider{phaseProvider("a", 1, 1), phaseProvider("b", 1, 1)}
	d := PhaseOrder(candidates, "m", PhaseInteractive, s, perfNow, 0, 0)
	if d.Basis != BasisFallback || ids(candidates)[0] != "a" || ids(candidates)[1] != "b" {
		t.Fatalf("no evidence: basis=%s order=%v", d.Basis, ids(candidates))
	}
	// One fresh candidate cannot be compared: objective order is kept.
	warm(s, "b", 10, 1000, 100)
	d = PhaseOrder(candidates, "m", PhaseInteractive, s, perfNow, 0.99, 0)
	if d.Basis != BasisFallback || ids(candidates)[0] != "a" {
		t.Fatalf("single fresh: basis=%s order=%v", d.Basis, ids(candidates))
	}
	// Stale evidence is treated as missing.
	warm(s, "a", 500, 1000, 10)
	d = PhaseOrder(candidates, "m", PhaseInteractive, s, perfNow.Add(PerfFreshMaxAge+time.Minute), 0.99, 0)
	if d.Basis != BasisFallback || d.Fresh != 0 || ids(candidates)[0] != "a" {
		t.Fatalf("stale: basis=%s fresh=%d order=%v", d.Basis, d.Fresh, ids(candidates))
	}
	// A nil store always falls back.
	if d := PhaseOrder(candidates, "m", PhaseInteractive, nil, perfNow, 0, 0); d.Basis != BasisFallback {
		t.Fatalf("nil store basis=%s", d.Basis)
	}
}

func TestPhaseOrderExploresUnmeasuredProviders(t *testing.T) {
	s := NewPerfStore()
	warm(s, "a", 10, 1000, 100)
	warm(s, "b", 20, 1000, 100)
	candidates := []pool.Provider{phaseProvider("a", 1, 1), phaseProvider("b", 1, 1), phaseProvider("new", 1, 1)}
	d := PhaseOrder(candidates, "m", PhaseInteractive, s, perfNow, PhaseExplorationShare-0.01, 0)
	if d.Basis != BasisExplore || candidates[0].ProviderID != "new" {
		t.Fatalf("explore: basis=%s order=%v", d.Basis, ids(candidates))
	}
	candidates = []pool.Provider{phaseProvider("new", 1, 1), phaseProvider("b", 1, 1), phaseProvider("a", 1, 1)}
	d = PhaseOrder(candidates, "m", PhaseInteractive, s, perfNow, PhaseExplorationShare, 0)
	if d.Basis != BasisMeasured || candidates[2].ProviderID != "new" || candidates[0].ProviderID != "a" {
		t.Fatalf("no explore: basis=%s order=%v", d.Basis, ids(candidates))
	}
	// Exploration share is bounded: over many draws about 10% explore.
	explored := 0
	for i := 0; i < 1000; i++ {
		c := []pool.Provider{phaseProvider("a", 1, 1), phaseProvider("new", 1, 1)}
		if PhaseOrder(c, "m", PhaseInteractive, s, perfNow, float64(i)/1000, 0).Basis == BasisExplore {
			explored++
		}
	}
	if explored != 100 {
		t.Fatalf("explored %d of 1000", explored)
	}
}

func TestPhaseOrderBandSharesNearEqualProvidersAndLoadDemotesBusy(t *testing.T) {
	s := NewPerfStore()
	warm(s, "a", 100, 1000, 100)
	warm(s, "b", 105, 1000, 100)
	warm(s, "slow", 1000, 1000, 20)
	picked := map[string]int{}
	for i := 0; i < 10; i++ {
		c := []pool.Provider{phaseProvider("a", 2, 2), phaseProvider("b", 2, 2), phaseProvider("slow", 2, 2)}
		PhaseOrder(c, "m", PhaseInteractive, s, perfNow, 0.99, float64(i)/10)
		picked[c[0].ProviderID]++
		if len(c) != 3 {
			t.Fatal("candidates added or removed")
		}
	}
	if picked["a"] == 0 || picked["b"] == 0 || picked["slow"] != 0 {
		t.Fatalf("band share: %v", picked)
	}
	// The fastest provider with one of four slots free loses to a near peer
	// that is idle: the load term keeps one fast Mac from taking everything.
	c := []pool.Provider{phaseProvider("a", 1, 4), phaseProvider("b", 4, 4)}
	PhaseOrder(c, "m", PhaseInteractive, s, perfNow, 0.99, 0)
	if c[0].ProviderID != "b" {
		t.Fatalf("load term: order=%v", ids(c))
	}
}

func TestRouteTraceHeaderGrammar(t *testing.T) {
	grammar := regexp.MustCompile(`^v=1; phase=(interactive|long_input|throughput); basis=(measured|explore|fallback|pinned); evidence=(fresh|none); engine=(general_mlx|continuous_batching|native_mtp|unknown); latency=(low|medium|high|unknown)$`)
	p := phaseProvider("a", 1, 1)
	if EngineClass(p) != "unknown" {
		t.Fatal("no profile must be unknown")
	}
	p.EngineProfile = &pool.EngineProfile{EngineFamily: "continuous_batching"}
	h := RouteTraceHeader(PhaseLongInput, BasisMeasured, true, EngineClass(p), LatencyClass(PhaseLongInput, 20000, PerfEvidence{TTFTMs: 100, PrefillTPS: 5000, PrefillSamples: 3}, true))
	if !grammar.MatchString(h) || h != "v=1; phase=long_input; basis=measured; evidence=fresh; engine=continuous_batching; latency=high" {
		t.Fatalf("header %q", h)
	}
	if got := LatencyClass(PhaseInteractive, 10, PerfEvidence{TTFTMs: 100}, true); got != "low" {
		t.Fatalf("latency %s", got)
	}
	if got := LatencyClass(PhaseInteractive, 10, PerfEvidence{TTFTMs: 1000}, true); got != "medium" {
		t.Fatalf("latency %s", got)
	}
	if got := LatencyClass(PhaseInteractive, 10, PerfEvidence{TTFTMs: 100}, false); got != "unknown" {
		t.Fatalf("latency %s", got)
	}
}
