package routing

import (
	"fmt"
	"math"
	"reflect"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// measuredProvider is a candidate with every objective key set explicitly.
func measuredProvider(id string, estimate float64, free int, params float64) pool.Provider {
	return pool.Provider{ProviderID: id, AssignedID: "s-" + id, ModelID: "Org/Model-A", ThroughputTPSEstimate: estimate, SlotsFree: free, SlotsTotal: 4, ModelParamsB: params, MaxContextTokens: 8192, Tier: pool.TierPinned}
}

// warmDecode gives id `samples` decode samples of decodeTPS, the last at at.
func warmDecode(s *PerfStore, id string, decodeTPS float64, samples int, at time.Time) {
	for i := 0; i < samples; i++ {
		s.Observe(PerfObservation{ProviderID: id, Model: "org/model-a", Streamed: true, CompletionTokens: 101, TTFTMs: 50, DecodeMs: 100 / decodeTPS * 1000, At: at})
	}
}

// measuredOrder runs the selection's objective steps the way the buyer does:
// estimate sort, then the SPEC-002-R005 positional reorder.
func measuredOrder(candidates []pool.Provider, objective Objective, store *PerfStore, now time.Time) ([]pool.Provider, Weights) {
	out := append([]pool.Provider(nil), candidates...)
	w := DefaultWeights()
	SortCandidatesWithScores(out, objective, w, nil)
	w.Measured = MeasuredThroughputs(out, store, now)
	if objective == ObjectiveBalanced {
		w.MeasuredBalanced = MeasuredBalancedScores(out, w)
	}
	ReorderMeasured(out, objective, w)
	return out, w
}

func estimateOrder(candidates []pool.Provider, objective Objective) []pool.Provider {
	out := append([]pool.Provider(nil), candidates...)
	SortCandidatesWithScores(out, objective, DefaultWeights(), nil)
	return out
}

var allObjectives = []Objective{ObjectiveDefault, ObjectiveFast, ObjectiveAccurate, ObjectiveBalanced}

func invariantCandidates() []pool.Provider {
	return []pool.Provider{
		measuredProvider("a", 40, 1, 7),
		measuredProvider("b", 90, 2, 7),
		measuredProvider("c", 10, 1, 14),
		measuredProvider("d", 90, 1, 7),
		measuredProvider("e", 25, 3, 14),
		measuredProvider("f", 60, 1, 7),
	}
}

// SPEC-002-R005: with zero or one decode-fresh candidate the final order and
// every epsilon cohort are byte-identical to the estimate order, for every
// objective. Stale (older than 15 minutes) and under-3-sample records count
// as unmeasured.
func TestMeasuredReorderInvariantZeroOrOneFresh(t *testing.T) {
	for _, objective := range allObjectives {
		for _, fresh := range []string{"", "a", "c", "e"} {
			t.Run(fmt.Sprintf("%s/fresh=%q", objective, fresh), func(t *testing.T) {
				candidates := invariantCandidates()
				s := NewPerfStore()
				// Unmeasured: two samples only, and three stale samples.
				warmDecode(s, "b", 1900, PerfFreshMinSamples-1, perfNow)
				warmDecode(s, "d", 1900, PerfFreshMinSamples, perfNow.Add(-PerfFreshMaxAge-time.Second))
				if fresh != "" {
					warmDecode(s, fresh, 1900, PerfFreshMinSamples, perfNow)
				}
				got, w := measuredOrder(candidates, objective, s, perfNow)
				want := estimateOrder(candidates, objective)
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("order = %v, want %v", ids(got), ids(want))
				}
				base := DefaultWeights()
				scores := KeyedBalancedScores(got)
				score := func(p pool.Provider) float64 { return scores[p.SortKey()] }
				for _, top := range got {
					for _, c := range got {
						for _, eps := range []float64{0, 0.05, 0.5} {
							if InEpsilonCohort(top, c, objective, eps, w, score) != InEpsilonCohort(top, c, objective, eps, base, score) {
								t.Fatalf("cohort(%s,%s,%v) changed", top.ProviderID, c.ProviderID, eps)
							}
						}
					}
				}
			})
		}
	}
}

// Two and three decode-fresh candidates reorder only among the positions they
// already hold; every unmeasured candidate keeps its exact position.
func TestMeasuredReorderOnlyAmongFreshPositions(t *testing.T) {
	for _, objective := range allObjectives {
		for _, fresh := range [][]string{{"a", "f"}, {"a", "d", "f"}, {"c", "e"}} {
			t.Run(fmt.Sprintf("%s/%v", objective, fresh), func(t *testing.T) {
				candidates := invariantCandidates()
				s := NewPerfStore()
				// Measured decode runs against the estimate order: the first
				// listed (lowest estimate in each case) decodes fastest.
				for i, id := range fresh {
					warmDecode(s, id, float64(100*(len(fresh)-i)), PerfFreshMinSamples, perfNow)
				}
				got, w := measuredOrder(candidates, objective, s, perfNow)
				want := estimateOrder(candidates, objective)
				isFresh := map[string]bool{}
				for _, id := range fresh {
					isFresh[id] = true
				}
				var freshPositionsGot, freshPositionsWant []int
				for i := range got {
					if isFresh[got[i].ProviderID] {
						freshPositionsGot = append(freshPositionsGot, i)
					} else if got[i].ProviderID != want[i].ProviderID {
						t.Fatalf("unmeasured %s moved: got %v want %v", want[i].ProviderID, ids(got), ids(want))
					}
					if isFresh[want[i].ProviderID] {
						freshPositionsWant = append(freshPositionsWant, i)
					}
				}
				if !reflect.DeepEqual(freshPositionsGot, freshPositionsWant) {
					t.Fatalf("fresh positions %v, want %v", freshPositionsGot, freshPositionsWant)
				}
				if len(w.Measured) != len(fresh) {
					t.Fatalf("measured = %v", w.Measured)
				}
				if objective == ObjectiveFast && reflect.DeepEqual(ids(got), ids(want)) {
					t.Fatalf("fast: measured decode moved nothing: %v", ids(got))
				}
				// Inside one block of equal non-throughput keys, the fresh
				// candidates are in descending routed order.
				for i := 0; i < len(freshPositionsGot); i++ {
					for j := i + 1; j < len(freshPositionsGot); j++ {
						a, b := got[freshPositionsGot[i]], got[freshPositionsGot[j]]
						sameBlock := objective == ObjectiveFast || objective == ObjectiveBalanced ||
							(objective == ObjectiveAccurate && a.ModelParamsB == b.ModelParamsB) ||
							(objective == ObjectiveDefault && a.SlotsFree == b.SlotsFree)
						if !sameBlock {
							continue
						}
						ka, kb := w.Measured[a.SortKey()], w.Measured[b.SortKey()]
						if objective == ObjectiveBalanced {
							ka, kb = w.MeasuredBalanced[a.SortKey()], w.MeasuredBalanced[b.SortKey()]
						}
						if ka < kb {
							t.Fatalf("%s (%v) above %s (%v): %v", a.ProviderID, ka, b.ProviderID, kb, ids(got))
						}
					}
				}
			})
		}
	}
}

// A fresh candidate is never compared with an unmeasured one on its measured
// value: a slower-estimate fresh provider with a huge measured decode stays
// below a faster-estimate unmeasured provider unless another fresh candidate
// held the higher position.
func TestMeasuredFreshNeverJumpsUnmeasured(t *testing.T) {
	for _, objective := range []Objective{ObjectiveFast, ObjectiveBalanced} {
		unmeasured := measuredProvider("unmeasured", 100, 1, 7)
		slowFresh := measuredProvider("slow-fresh", 50, 1, 7)
		otherFresh := measuredProvider("other-fresh", 20, 1, 7)
		s := NewPerfStore()
		warmDecode(s, "slow-fresh", 1900, PerfFreshMinSamples, perfNow)
		warmDecode(s, "other-fresh", 10, PerfFreshMinSamples, perfNow)
		got, _ := measuredOrder([]pool.Provider{slowFresh, otherFresh, unmeasured}, objective, s, perfNow)
		if ids(got)[0] != "unmeasured" || ids(got)[1] != "slow-fresh" || ids(got)[2] != "other-fresh" {
			t.Fatalf("%s: order = %v", objective, ids(got))
		}
	}
}

// The estimate is a prior capped at 1.25 times the measured decode, so an
// inflated self-report cannot carry a fresh provider.
func TestMeasuredThroughputCapsInflatedEstimate(t *testing.T) {
	s := NewPerfStore()
	warmDecode(s, "p", 100, PerfFreshMinSamples, perfNow)
	p := measuredProvider("p", 1_000_000, 1, 7)
	want := (PerfPriorWeightSamples*100*PerfPriorCapOverMeasure + 3*100) / (PerfPriorWeightSamples + 3)
	got, measured := RoutedThroughput(p, s, perfNow)
	if !measured || math.Abs(got-want) > 1e-6 {
		t.Fatalf("routed = %v measured=%v, want %v", got, measured, want)
	}
	if m := MeasuredThroughputs([]pool.Provider{p}, s, perfNow); math.Abs(m[p.SortKey()]-want) > 1e-6 {
		t.Fatalf("MeasuredThroughputs = %v", m)
	}
	// Stale and under-3-sample records route on the estimate.
	if got, measured := RoutedThroughput(p, s, perfNow.Add(PerfFreshMaxAge+time.Second)); measured || got != 1_000_000 {
		t.Fatalf("stale: %v %v", got, measured)
	}
	thin := NewPerfStore()
	warmDecode(thin, "p", 100, PerfFreshMinSamples-1, perfNow)
	if got, measured := RoutedThroughput(p, thin, perfNow); measured || got != 1_000_000 {
		t.Fatalf("thin: %v %v", got, measured)
	}
	if got, measured := RoutedThroughput(p, nil, perfNow); measured || got != 1_000_000 {
		t.Fatalf("nil store: %v %v", got, measured)
	}
}

// Epsilon cohorts compare routed values only when both candidates are fresh.
func TestMeasuredEpsilonCohortPairs(t *testing.T) {
	a := measuredProvider("a", 100, 1, 7)
	b := measuredProvider("b", 100, 1, 7)
	c := measuredProvider("c", 100, 1, 7)
	w := DefaultWeights()
	w.Measured = map[string]float64{a.SortKey(): 100, b.SortKey(): 10}
	if InEpsilonCohort(a, b, ObjectiveFast, 0.05, w, nil) || InEpsilonCohort(a, b, ObjectiveDefault, 0.05, w, nil) {
		t.Fatal("two fresh candidates must compare routed throughput")
	}
	if !InEpsilonCohort(a, c, ObjectiveFast, 0.05, w, nil) || !InEpsilonCohort(c, b, ObjectiveDefault, 0.05, w, nil) {
		t.Fatal("a fresh and an unmeasured candidate must compare estimates")
	}
	w.MeasuredBalanced = map[string]float64{a.SortKey(): 1, b.SortKey(): 0.5}
	same := func(pool.Provider) float64 { return 1 }
	if InEpsilonCohort(a, b, ObjectiveBalanced, 0.05, w, same) {
		t.Fatal("two fresh candidates must compare measured balanced scores")
	}
	if !InEpsilonCohort(a, c, ObjectiveBalanced, 0.05, w, same) {
		t.Fatal("mixed pair must compare FR-SR-8 scores")
	}
}

// The store key is the served model, case-folded: alias, class and casing
// variants of one session share one record.
func TestPerfStoreKeyIsCaseFoldedServedModel(t *testing.T) {
	s := NewPerfStore()
	for _, model := range []string{"Org/Model-A", "org/model-a", "ORG/MODEL-A"} {
		s.Observe(PerfObservation{ProviderID: "p", Model: model, Streamed: true, CompletionTokens: 101, TTFTMs: 50, DecodeMs: 1000, At: perfNow})
	}
	if s.Len() != 1 {
		t.Fatalf("records = %d, want 1", s.Len())
	}
	if e, ok := s.Lookup("p", "org/Model-a"); !ok || e.DecodeSamples != 3 {
		t.Fatalf("lookup = %+v %v", e, ok)
	}
}

// Operator view: measured fields next to the routed value and its source.
func TestProviderThroughputView(t *testing.T) {
	p := measuredProvider("p", 30, 1, 7)
	if v := ProviderThroughput(p, nil, perfNow); v.MeasuredDecodeTPS != nil || v.MeasuredDecodeAgeS != nil || v.MeasuredDecodeSamples != 0 || v.RoutedThroughputTPS != 30 || v.RoutedThroughputSource != ThroughputSourceReported {
		t.Fatalf("no store: %+v", v)
	}
	s := NewPerfStore()
	warmDecode(s, "p", 100, PerfFreshMinSamples, perfNow)
	v := ProviderThroughput(p, s, perfNow.Add(10*time.Second))
	if v.MeasuredDecodeTPS == nil || *v.MeasuredDecodeTPS != 100 || v.MeasuredDecodeSamples != 3 || v.MeasuredDecodeAgeS == nil || *v.MeasuredDecodeAgeS != 10 || v.RoutedThroughputSource != ThroughputSourceMeasured {
		t.Fatalf("fresh: %+v", v)
	}
	stale := ProviderThroughput(p, s, perfNow.Add(PerfFreshMaxAge+time.Minute))
	if stale.MeasuredDecodeTPS != nil || stale.MeasuredDecodeAgeS == nil || stale.RoutedThroughputTPS != 30 || stale.RoutedThroughputSource != ThroughputSourceReported {
		t.Fatalf("stale: %+v", stale)
	}
}

// SPEC-004 §7: candidate_set entries name the throughput source and both
// values.
func TestCandidateLogEntryThroughputSource(t *testing.T) {
	a := measuredProvider("a", 30, 1, 7)
	b := measuredProvider("b", 40, 1, 7)
	w := DefaultWeights()
	w.Measured = map[string]float64{a.SortKey(): 120}
	ea := ProviderToCandidateLogEntry(a, 0, w)
	eb := ProviderToCandidateLogEntry(b, 0, w)
	if ea.ThroughputSource != ThroughputSourceMeasured || ea.ThroughputTPSEstimate != 30 || ea.RoutedThroughputTPS != 120 || ea.EffectiveThroughput != 30 {
		t.Fatalf("measured entry = %+v", ea)
	}
	if eb.ThroughputSource != ThroughputSourceReported || eb.ThroughputTPSEstimate != 40 || eb.RoutedThroughputTPS != 40 {
		t.Fatalf("reported entry = %+v", eb)
	}
}
