package computeintegrity

// SPEC-036 §5A cross-provider scoring: agreement metrics and the learned
// honest-pair tolerance band (FR-22).
//
// This path is independent of the FR-1..FR-18 overt-probe machinery in this
// package: it reads no Policy mode, no ReferenceEvent and no ThresholdRecord.

import (
	"math"
	"sort"
	"sync"
	"time"
)

// SamplingClass splits tolerance windows by how the verified output was
// sampled (FR-22).
type SamplingClass string

const (
	SamplingGreedy  SamplingClass = "greedy"
	SamplingSampled SamplingClass = "sampled"
	// SamplingHot is temperature above hotTemperature. Honest hot outputs
	// can degenerate into near-random tokens the claimed model scores below
	// any floor (measured down to -9.6 mean log-probability on real chips),
	// so hot requests are cover traffic only: the engine never scores them
	// and they never warm a learned band. Its band below is the hard floor,
	// kept only as the conservative answer if one is ever evaluated.
	SamplingHot SamplingClass = "hot"
)

// hotTemperature separates the sampled and hot FR-20 profiles (0.7 and 1.0).
const hotTemperature = 0.85

// SamplingClassFor maps a request temperature to its FR-22 class.
func SamplingClassFor(temperature float64) SamplingClass {
	switch {
	case temperature == 0:
		return SamplingGreedy
	case temperature > hotTemperature:
		return SamplingHot
	}
	return SamplingSampled
}

// MinScoredTokens is the FR-21 floor below which a measurement is
// inconclusive:short_output.
const MinScoredTokens = 16

// Measurement is one scorer's FR-21 answer for one verified output.
type Measurement struct {
	ScoredTokens int
	Top1Matches  int
	SumLogprob   float64
}

// Valid reports whether the measurement is usable: enough scored tokens,
// consistent counts and a finite, non-positive log-probability sum.
func (m Measurement) Valid() bool {
	return m.ScoredTokens >= MinScoredTokens &&
		m.Top1Matches >= 0 && m.Top1Matches <= m.ScoredTokens &&
		!math.IsNaN(m.SumLogprob) && !math.IsInf(m.SumLogprob, 0) && m.SumLogprob <= 0
}

// Top1Rate is the share of output positions where the output token was the
// scorer's arg-max token.
func (m Measurement) Top1Rate() float64 {
	if m.ScoredTokens <= 0 {
		return 0
	}
	return float64(m.Top1Matches) / float64(m.ScoredTokens)
}

// MeanLogprob is the mean log-probability of the output tokens.
func (m Measurement) MeanLogprob() float64 {
	if m.ScoredTokens <= 0 {
		return 0
	}
	return m.SumLogprob / float64(m.ScoredTokens)
}

// ToleranceKey names one honest-pair distribution (FR-22).
type ToleranceKey struct {
	ModelID        string
	ManifestSHA256 string
	Class          SamplingClass
}

// FR-22 constants. The cold prior comes from the CB self-check and the
// decode-isolation evidence (#1947, #1971, #1974): honest kernel-route
// differences flip the arg-max only at near-ties, which do not propagate under
// teacher forcing.
const (
	toleranceWindowSize       = 256
	tolerancePerOperatorCap   = 16
	toleranceWarmSamples      = 32
	toleranceWarmOperators    = 3
	toleranceMADMultiplier    = 6.0
	toleranceLogprobMinMargin = 0.25
	toleranceTop1MinMargin    = 0.05
	priorGreedyTop1Floor      = 0.85
	priorGreedyLogprobFloor   = -1.0
	priorSampledLogprobFloor  = -4.0
	hardGreedyTop1Floor       = 0.50
	hardGreedyLogprobFloor    = -3.0
	hardSampledLogprobFloor   = -6.0
	toleranceUnsetTop1Floor   = -1.0
)

// Band is the in-band region for one tolerance key.
type Band struct {
	Warm             bool
	Top1Floor        float64 // negative when top-1 is not checked (sampled)
	MeanLogprobFloor float64
	Samples          int
	Operators        int
}

// OutReason names why a measurement fell out of band.
type OutReason string

const (
	OutOfBandTop1    OutReason = "out_of_band_top1"
	OutOfBandLogprob OutReason = "out_of_band_logprob"
)

// Evaluate reports whether m is in band, and the first failed metric if not.
func (b Band) Evaluate(m Measurement) (bool, OutReason) {
	if b.Top1Floor >= 0 && m.Top1Rate() < b.Top1Floor {
		return false, OutOfBandTop1
	}
	if m.MeanLogprob() < b.MeanLogprobFloor {
		return false, OutOfBandLogprob
	}
	return true, ""
}

// PriorBand is the FR-22 cold-start band for a sampling class.
func PriorBand(class SamplingClass) Band {
	switch class {
	case SamplingGreedy:
		return Band{Top1Floor: priorGreedyTop1Floor, MeanLogprobFloor: priorGreedyLogprobFloor}
	case SamplingHot:
		return Band{Top1Floor: toleranceUnsetTop1Floor, MeanLogprobFloor: hardSampledLogprobFloor}
	}
	return Band{Top1Floor: toleranceUnsetTop1Floor, MeanLogprobFloor: priorSampledLogprobFloor}
}

type toleranceEntry struct {
	operator    string
	top1        float64
	meanLogprob float64
}

// Tolerance keeps the FR-22 honest-pair windows in memory. It is safe for
// concurrent use.
type Tolerance struct {
	mu      sync.Mutex
	windows map[ToleranceKey][]toleranceEntry
	seen    map[ToleranceKey]time.Time
}

// NewTolerance returns an empty tracker; every key starts cold.
func NewTolerance() *Tolerance {
	return &Tolerance{windows: map[ToleranceKey][]toleranceEntry{}, seen: map[ToleranceKey]time.Time{}}
}

// Touch marks the keys of a (model, manifest) as in use at now.
func (t *Tolerance) Touch(modelID, manifest string, now time.Time) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, class := range []SamplingClass{SamplingGreedy, SamplingSampled} {
		t.seen[ToleranceKey{ModelID: modelID, ManifestSHA256: manifest, Class: class}] = now
	}
}

// Prune drops windows of keys not in use since cutoff (retired models and
// manifests); a key in use again starts cold.
func (t *Tolerance) Prune(cutoff time.Time) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for key, at := range t.seen {
		if at.Before(cutoff) {
			delete(t.windows, key)
			delete(t.seen, key)
		}
	}
}

// Accept records an in-band measurement from a verified provider of the
// given operator. Each operator keeps at most tolerancePerOperatorCap entries
// (its oldest is evicted first) and the window at most toleranceWindowSize.
func (t *Tolerance) Accept(key ToleranceKey, operator string, m Measurement) {
	if t == nil || !m.Valid() || operator == "" || key.Class == SamplingHot {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	window := t.windows[key]
	count := 0
	oldest := -1
	for i, e := range window {
		if e.operator == operator {
			if oldest < 0 {
				oldest = i
			}
			count++
		}
	}
	if count >= tolerancePerOperatorCap && oldest >= 0 {
		window = append(window[:oldest], window[oldest+1:]...)
	}
	if len(window) >= toleranceWindowSize {
		window = window[1:]
	}
	window = append(window, toleranceEntry{operator: operator, top1: m.Top1Rate(), meanLogprob: m.MeanLogprob()})
	t.windows[key] = window
	if _, ok := t.seen[key]; !ok {
		t.seen[key] = time.Now()
	}
}

// Band returns the current band for key: the learned band once warm, the
// prior otherwise.
func (t *Tolerance) Band(key ToleranceKey) Band {
	prior := PriorBand(key.Class)
	if t == nil || key.Class == SamplingHot {
		return prior
	}
	t.mu.Lock()
	window := append([]toleranceEntry(nil), t.windows[key]...)
	t.mu.Unlock()
	operators := map[string]struct{}{}
	for _, e := range window {
		operators[e.operator] = struct{}{}
	}
	prior.Samples = len(window)
	prior.Operators = len(operators)
	if len(window) < toleranceWarmSamples || len(operators) < toleranceWarmOperators {
		return prior
	}
	logprobs := make([]float64, len(window))
	top1 := make([]float64, len(window))
	for i, e := range window {
		logprobs[i] = e.meanLogprob
		top1[i] = e.top1
	}
	band := Band{Warm: true, Samples: len(window), Operators: len(operators), Top1Floor: toleranceUnsetTop1Floor}
	band.MeanLogprobFloor = learnedFloor(logprobs, toleranceLogprobMinMargin)
	if key.Class == SamplingGreedy {
		band.MeanLogprobFloor = math.Max(band.MeanLogprobFloor, hardGreedyLogprobFloor)
		band.Top1Floor = math.Max(learnedFloor(top1, toleranceTop1MinMargin), hardGreedyTop1Floor)
	} else {
		band.MeanLogprobFloor = math.Max(band.MeanLogprobFloor, hardSampledLogprobFloor)
	}
	return band
}

// learnedFloor is median - max(6*MAD, minMargin).
func learnedFloor(values []float64, minMargin float64) float64 {
	med := median(values)
	deviations := make([]float64, len(values))
	for i, v := range values {
		deviations[i] = math.Abs(v - med)
	}
	return med - math.Max(toleranceMADMultiplier*median(deviations), minMargin)
}

func median(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[mid]
	}
	return (sorted[mid-1] + sorted[mid]) / 2
}
