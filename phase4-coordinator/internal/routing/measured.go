package routing

import (
	"math"
	"sort"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// Throughput sources named by SPEC-002-R005 routed throughput.
const (
	ThroughputSourceMeasured = "measured"
	ThroughputSourceReported = "reported"
)

// RoutedThroughput is SPEC-002-R005 routed throughput for one provider: the
// measured decode average with the heartbeat estimate as its capped prior when
// the decode signal of the record for the provider's served model is fresh,
// else the estimate. The bool reports the measured source.
func RoutedThroughput(p pool.Provider, store *PerfStore, now time.Time) (float64, bool) {
	if e, ok := store.Lookup(p.ProviderID, p.ModelID); ok && e.DecodeFresh(now) {
		return e.DecodeWithPrior(p.ThroughputTPSEstimate), true
	}
	return p.ThroughputTPSEstimate, false
}

// MeasuredThroughputs returns routed throughput for the decode-fresh
// candidates only, keyed by pool.Provider.SortKey(). Callers put it in
// Weights.Measured once per request so every step reads the same values.
func MeasuredThroughputs(candidates []pool.Provider, store *PerfStore, now time.Time) map[string]float64 {
	out := map[string]float64{}
	records := store.LookupCandidates(candidates)
	for _, p := range candidates {
		if e, ok := records[p.SortKey()]; ok && e.DecodeFresh(now) {
			out[p.SortKey()] = e.DecodeWithPrior(p.ThroughputTPSEstimate)
		}
	}
	return out
}

// measuredEffective is routed throughput times the tier weight for a
// decode-fresh candidate.
func measuredEffective(p pool.Provider, w Weights) (float64, bool) {
	v, ok := w.Measured[p.SortKey()]
	if !ok {
		return 0, false
	}
	weight := w.Pinned
	if p.Tier == pool.TierProvisional {
		weight = w.Provisional
	}
	return v * weight, true
}

// pairThroughput returns the effective throughputs one comparison uses:
// routed values when both candidates are decode-fresh, else both estimates.
func pairThroughput(a, b pool.Provider, w Weights) (float64, float64) {
	ma, okA := measuredEffective(a, w)
	mb, okB := measuredEffective(b, w)
	if okA && okB {
		return ma, mb
	}
	return EffectiveThroughput(a, w), EffectiveThroughput(b, w)
}

// MeasuredBalancedScores is the FR-SR-8 balanced score of each decode-fresh
// candidate with its throughput term normalized over the decode-fresh
// candidates' routed throughput; the other terms are normalized over all
// candidates. Keyed by SortKey; only decode-fresh candidates appear.
func MeasuredBalancedScores(candidates []pool.Provider, w Weights) map[string]float64 {
	out := map[string]float64{}
	if len(w.Measured) < 2 {
		return out
	}
	rest := balancedNonThroughput(candidates)
	var idx []int
	var tps []float64
	for i, p := range candidates {
		if v, ok := w.Measured[p.SortKey()]; ok {
			idx = append(idx, i)
			tps = append(tps, v)
		}
	}
	for j, i := range idx {
		out[candidates[i].SortKey()] = 0.4*minMaxNorm(tps, j) + rest[i]
	}
	return out
}

// ReorderMeasured applies SPEC-002-R005 routed throughput to the
// objective-sorted candidates: inside each block whose non-throughput
// objective keys are equal (default: slots_free; accurate: model_params_b;
// fast and balanced: the whole list), the decode-fresh candidates are
// reordered by routed throughput among the positions they already hold.
// Unmeasured candidates keep their positions, and with fewer than two
// decode-fresh candidates in a block nothing moves. balanced reorders by
// MeasuredBalancedScores, which the caller passes in w.MeasuredBalanced.
func ReorderMeasured(candidates []pool.Provider, objective Objective, w Weights) {
	if len(w.Measured) < 2 {
		return
	}
	sameBlock := func(a, b pool.Provider) bool {
		switch objective {
		case ObjectiveFast, ObjectiveBalanced:
			return true
		case ObjectiveAccurate:
			return a.ModelParamsB == b.ModelParamsB
		default:
			return a.SlotsFree == b.SlotsFree
		}
	}
	key := func(p pool.Provider) float64 {
		if objective == ObjectiveBalanced {
			return w.MeasuredBalanced[p.SortKey()]
		}
		v, _ := measuredEffective(p, w)
		return v
	}
	for start := 0; start < len(candidates); {
		end := start + 1
		for end < len(candidates) && sameBlock(candidates[start], candidates[end]) {
			end++
		}
		var positions []int
		var fresh []pool.Provider
		for i := start; i < end; i++ {
			if _, ok := w.Measured[candidates[i].SortKey()]; ok {
				positions = append(positions, i)
				fresh = append(fresh, candidates[i])
			}
		}
		if len(fresh) >= 2 {
			sort.SliceStable(fresh, func(i, j int) bool {
				ki, kj := key(fresh[i]), key(fresh[j])
				if ki == kj {
					return fresh[i].SlotsFree < fresh[j].SlotsFree
				}
				return ki > kj
			})
			for n, i := range positions {
				candidates[i] = fresh[n]
			}
		}
		start = end
	}
}

// finiteOrZero guards logged values against NaN and Inf.
func finiteOrZero(v float64) float64 {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return 0
	}
	return v
}

// ThroughputView is the operator-only SPEC-002 FR-O2 measured-throughput view
// of one provider session: /poolz rows and explorer provider rows.
type ThroughputView struct {
	// MeasuredDecodeTPS is the decode average, nil without a decode sample
	// in the last PerfFreshMaxAge.
	MeasuredDecodeTPS     *float64 `json:"measured_decode_tps"`
	MeasuredDecodeSamples int      `json:"measured_decode_samples"`
	// MeasuredDecodeAgeS is the age of the last decode sample, nil without one.
	MeasuredDecodeAgeS     *int64  `json:"measured_decode_age_s"`
	RoutedThroughputTPS    float64 `json:"routed_throughput_tps"`
	RoutedThroughputSource string  `json:"routed_throughput_source"`
}

// ProviderThroughput builds the ThroughputView for p from the record of its
// provider and served model.
func ProviderThroughput(p pool.Provider, store *PerfStore, now time.Time) ThroughputView {
	routed, measured := RoutedThroughput(p, store, now)
	v := ThroughputView{RoutedThroughputTPS: finiteOrZero(routed), RoutedThroughputSource: ThroughputSourceReported}
	if measured {
		v.RoutedThroughputSource = ThroughputSourceMeasured
	}
	e, ok := store.Lookup(p.ProviderID, p.ModelID)
	if !ok || e.DecodeSamples == 0 {
		return v
	}
	v.MeasuredDecodeSamples = e.DecodeSamples
	if !e.DecodeLastObserved.IsZero() {
		age := int64(now.Sub(e.DecodeLastObserved).Seconds())
		v.MeasuredDecodeAgeS = &age
	}
	if signalRecent(e.DecodeSamples, e.DecodeLastObserved, now) {
		decode := finiteOrZero(e.DecodeTPS)
		v.MeasuredDecodeTPS = &decode
	}
	return v
}
