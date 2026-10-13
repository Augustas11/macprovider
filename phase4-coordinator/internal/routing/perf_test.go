package routing

import (
	"math"
	"testing"
	"time"
)

var perfNow = time.Date(2026, 10, 13, 12, 0, 0, 0, time.UTC)

func observe(s *PerfStore, provider string, prompt, completion int64, ttftMs, decodeMs float64, at time.Time) {
	s.Observe(PerfObservation{ProviderID: provider, Model: "m", PromptTokens: prompt, CompletionTokens: completion, TTFTMs: ttftMs, DecodeMs: decodeMs, At: at})
}

func TestPerfStoreEWMAAndFreshness(t *testing.T) {
	s := NewPerfStore()
	observe(s, "p", 1000, 101, 100, 1000, perfNow)
	e, ok := s.Lookup("p", "m")
	if !ok || e.TTFTMs != 100 || e.PrefillTPS != 10000 || e.DecodeTPS != 100 {
		t.Fatalf("first sample: %+v", e)
	}
	if e.Fresh(perfNow) {
		t.Fatal("one sample must not be fresh")
	}
	observe(s, "p", 1000, 101, 200, 1000, perfNow)
	observe(s, "p", 1000, 101, 200, 1000, perfNow)
	e, _ = s.Lookup("p", "m")
	// 100 -> 120 -> 136 with weight 0.2.
	if math.Abs(e.TTFTMs-136) > 1e-9 || e.TTFTSamples != 3 {
		t.Fatalf("ewma: %+v", e)
	}
	if !e.Fresh(perfNow) || !e.Fresh(perfNow.Add(PerfFreshMaxAge)) {
		t.Fatal("three recent samples must be fresh")
	}
	if e.Fresh(perfNow.Add(PerfFreshMaxAge + time.Second)) {
		t.Fatal("evidence older than the freshness window must be stale")
	}
	if _, ok := s.Lookup("p", "other-model"); ok {
		t.Fatal("records are keyed by model")
	}
}

func TestPerfStoreClampsAndThresholds(t *testing.T) {
	s := NewPerfStore()
	// Inflated usage cannot push rates past the clamps.
	observe(s, "p", 10_000_000, 1_000_000, 1, 1, perfNow)
	e, _ := s.Lookup("p", "m")
	if e.PrefillTPS != PerfMaxPrefillTPS || e.DecodeTPS != PerfMaxDecodeTPS {
		t.Fatalf("clamps: %+v", e)
	}
	// A short prompt and a short completion contribute TTFT only.
	s2 := NewPerfStore()
	observe(s2, "q", PerfMinPrefillTokens-1, PerfMinDecodeTokens-1, 50, 100, perfNow)
	e2, _ := s2.Lookup("q", "m")
	if e2.TTFTSamples != 1 || e2.PrefillSamples != 0 || e2.DecodeSamples != 0 {
		t.Fatalf("thresholds: %+v", e2)
	}
	// Invalid observations are ignored.
	s2.Observe(PerfObservation{ProviderID: "", Model: "m", PromptTokens: 1, CompletionTokens: 1, TTFTMs: 1, At: perfNow})
	s2.Observe(PerfObservation{ProviderID: "z", Model: "m", PromptTokens: 1, CompletionTokens: -1, TTFTMs: 1, At: perfNow})
	s2.Observe(PerfObservation{ProviderID: "z", Model: "m", PromptTokens: 1, CompletionTokens: 1, TTFTMs: math.NaN(), At: perfNow})
	if s2.Len() != 1 {
		t.Fatalf("invalid observations stored: %d", s2.Len())
	}
	// A zero-token completion still carries TTFT evidence.
	s2.Observe(PerfObservation{ProviderID: "zero", Model: "m", PromptTokens: 100, CompletionTokens: 0, TTFTMs: 10, At: perfNow})
	if e, ok := s2.Lookup("zero", "m"); !ok || e.TTFTSamples != 1 || e.PrefillSamples != 1 || e.DecodeSamples != 0 {
		t.Fatalf("zero-token completion: %+v ok=%v", e, ok)
	}
	// Cached prompt tokens are not prefill work.
	s3 := NewPerfStore()
	s3.Observe(PerfObservation{ProviderID: "c", Model: "m", PromptTokens: 1000, CachedPromptTokens: 990, CompletionTokens: 20, TTFTMs: 10, DecodeMs: 100, At: perfNow})
	e3, _ := s3.Lookup("c", "m")
	if e3.PrefillSamples != 0 {
		t.Fatalf("cached prefix counted as prefill: %+v", e3)
	}
}

func TestPerfSelfReportIsCappedPrior(t *testing.T) {
	e := PerfEvidence{DecodeTPS: 100, DecodeSamples: 2}
	// A wildly optimistic self-report counts as at most 1.25x the measurement.
	if got := e.DecodeWithPrior(10_000); math.Abs(got-112.5) > 1e-9 {
		t.Fatalf("capped prior = %v", got)
	}
	if got := e.DecodeWithPrior(0); got != 100 {
		t.Fatalf("no prior = %v", got)
	}
	if got := (PerfEvidence{}).DecodeWithPrior(500); got != 0 {
		t.Fatalf("a self-report alone is not a measurement: %v", got)
	}
}

func TestPerfStoreEvictsStaleThenOldest(t *testing.T) {
	s := NewPerfStore()
	s.max = 3
	for i := 0; i < 3; i++ {
		observe(s, "fresh-"+string(rune('a'+i)), 100, 20, 10, 100, perfNow)
		observe(s, "fresh-"+string(rune('a'+i)), 100, 20, 10, 100, perfNow)
		observe(s, "fresh-"+string(rune('a'+i)), 100, 20, 10, 100, perfNow.Add(time.Duration(i)*time.Second))
	}
	observe(s, "new", 100, 20, 10, 100, perfNow.Add(time.Minute))
	if s.Len() != 3 {
		t.Fatalf("len = %d", s.Len())
	}
	if _, ok := s.Lookup("fresh-a", "m"); ok {
		t.Fatal("the least recently observed record should be evicted")
	}
	// The single-sample "new" record is not fresh, so it goes first next time.
	observe(s, "newer", 100, 20, 10, 100, perfNow.Add(2*time.Minute))
	if _, ok := s.Lookup("new", "m"); ok {
		t.Fatal("a record that is not fresh should be evicted before fresh ones")
	}
	if _, ok := s.Lookup("fresh-b", "m"); !ok {
		t.Fatal("fresh records must survive while stale ones exist")
	}
}

// One provider at its model budget replaces only its own records.
func TestPerfStorePerProviderBudget(t *testing.T) {
	s := NewPerfStore()
	s.max, s.maxPerProv = 8, 2
	for i := 0; i < 3; i++ {
		observe(s, "peer-"+string(rune('a'+i)), 100, 20, 10, 100, perfNow)
	}
	for i := 0; i < 10; i++ {
		s.Observe(PerfObservation{ProviderID: "rotator", Model: "m" + string(rune('a'+i)), PromptTokens: 100, CompletionTokens: 20, TTFTMs: 10, DecodeMs: 100, At: perfNow.Add(time.Duration(i) * time.Second)})
	}
	if s.Len() != 5 || s.perProvider["rotator"] != 2 {
		t.Fatalf("len=%d rotator=%d", s.Len(), s.perProvider["rotator"])
	}
	for i := 0; i < 3; i++ {
		if _, ok := s.Lookup("peer-"+string(rune('a'+i)), "m"); !ok {
			t.Fatal("a rotating provider displaced a peer record")
		}
	}
	if _, ok := s.Lookup("rotator", "mj"); !ok {
		t.Fatal("the newest rotator record should be kept")
	}
}
