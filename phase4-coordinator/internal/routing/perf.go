package routing

import (
	"math"
	"sync"
	"time"
)

// SPEC-002-R005 measured-performance store constants.
const (
	PerfEWMAWeight           = 0.2
	PerfFreshMinSamples      = 3
	PerfFreshMaxAge          = 15 * time.Minute
	PerfStoreMaxEntries      = 65536
	PerfMaxModelsPerProvider = 64
	PerfMinPrefillTokens     = 64
	PerfMinDecodeTokens      = 8
	PerfMaxTTFTMs            = 600_000
	PerfMaxPrefillTPS        = 50_000
	PerfMaxDecodeTPS         = 2_000
	PerfPriorWeightSamples   = 2
	PerfPriorCapOverMeasure  = 1.25
)

// PerfObservation is one coordinator-timed served attempt. Durations come
// from the coordinator's wall clock; PromptTokens is the coordinator's token
// estimate of the request body (0 withholds a prefill sample) and
// CompletionTokens its delivered-bytes estimate, never provider usage.
type PerfObservation struct {
	ProviderID         string
	Model              string
	PromptTokens       int64
	CachedPromptTokens int64
	CompletionTokens   int64
	TTFTMs             float64
	DecodeMs           float64
	At                 time.Time
}

// PerfEvidence is a read-only copy of one store record.
type PerfEvidence struct {
	TTFTMs         float64
	PrefillTPS     float64
	DecodeTPS      float64
	TTFTSamples    int
	PrefillSamples int
	DecodeSamples  int
	LastObserved   time.Time
}

// Fresh reports whether the record may drive phase-aware ordering.
func (e PerfEvidence) Fresh(now time.Time) bool {
	return e.TTFTSamples >= PerfFreshMinSamples && !e.LastObserved.IsZero() && now.Sub(e.LastObserved) <= PerfFreshMaxAge
}

// DecodeWithPrior blends the self-reported throughput estimate into the
// measured decode average as a prior worth PerfPriorWeightSamples samples,
// capped so a self-report never outranks the measurement.
func (e PerfEvidence) DecodeWithPrior(selfReported float64) float64 {
	if e.DecodeSamples == 0 {
		return 0
	}
	if selfReported <= 0 || math.IsNaN(selfReported) || math.IsInf(selfReported, 0) {
		return e.DecodeTPS
	}
	prior := math.Min(selfReported, e.DecodeTPS*PerfPriorCapOverMeasure)
	n := float64(e.DecodeSamples)
	return (PerfPriorWeightSamples*prior + n*e.DecodeTPS) / (PerfPriorWeightSamples + n)
}

type perfKey struct {
	providerID string
	model      string
}

// PerfStore is the in-memory SPEC-002-R005 store keyed by provider and
// requested model. It is not persisted.
type PerfStore struct {
	mu          sync.RWMutex
	entries     map[perfKey]*PerfEvidence
	perProvider map[string]int
	max         int
	maxPerProv  int
}

func NewPerfStore() *PerfStore {
	return &PerfStore{entries: make(map[perfKey]*PerfEvidence), perProvider: make(map[string]int), max: PerfStoreMaxEntries, maxPerProv: PerfMaxModelsPerProvider}
}

func clampFloat(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func ewma(prev float64, samples int, sample float64) float64 {
	if samples == 0 {
		return sample
	}
	return prev + PerfEWMAWeight*(sample-prev)
}

// Observe records one served attempt. Invalid observations are ignored.
func (s *PerfStore) Observe(o PerfObservation) {
	if s == nil || o.ProviderID == "" || o.Model == "" || o.At.IsZero() {
		return
	}
	if o.CompletionTokens < 0 || o.PromptTokens < 0 || math.IsNaN(o.TTFTMs) || math.IsInf(o.TTFTMs, 0) || o.TTFTMs < 0 {
		return
	}
	ttft := clampFloat(o.TTFTMs, 1, PerfMaxTTFTMs)
	uncached := o.PromptTokens - o.CachedPromptTokens
	if o.CachedPromptTokens < 0 || uncached < 0 {
		uncached = o.PromptTokens
	}
	key := perfKey{providerID: o.ProviderID, model: o.Model}
	s.mu.Lock()
	defer s.mu.Unlock()
	e, ok := s.entries[key]
	if !ok {
		// A provider at its model budget replaces its own least recently
		// observed record, so it can never displace another provider's.
		if s.perProvider[o.ProviderID] >= s.maxPerProv {
			s.evictProviderOldestLocked(o.ProviderID)
		}
		if len(s.entries) >= s.max {
			s.evictLocked(o.At)
		}
		e = &PerfEvidence{}
		s.entries[key] = e
		s.perProvider[o.ProviderID]++
	}
	e.TTFTMs = ewma(e.TTFTMs, e.TTFTSamples, ttft)
	e.TTFTSamples = saturatingInc(e.TTFTSamples)
	if uncached >= PerfMinPrefillTokens {
		rate := clampFloat(float64(uncached)/(ttft/1000), 0, PerfMaxPrefillTPS)
		e.PrefillTPS = ewma(e.PrefillTPS, e.PrefillSamples, rate)
		e.PrefillSamples = saturatingInc(e.PrefillSamples)
	}
	if o.CompletionTokens >= PerfMinDecodeTokens && o.DecodeMs > 0 && !math.IsInf(o.DecodeMs, 0) {
		rate := clampFloat(float64(o.CompletionTokens-1)/(o.DecodeMs/1000), 0, PerfMaxDecodeTPS)
		e.DecodeTPS = ewma(e.DecodeTPS, e.DecodeSamples, rate)
		e.DecodeSamples = saturatingInc(e.DecodeSamples)
	}
	if o.At.After(e.LastObserved) {
		e.LastObserved = o.At
	}
}

func saturatingInc(n int) int {
	if n >= math.MaxInt32 {
		return n
	}
	return n + 1
}

func (s *PerfStore) deleteLocked(k perfKey) {
	delete(s.entries, k)
	if s.perProvider[k.providerID] <= 1 {
		delete(s.perProvider, k.providerID)
	} else {
		s.perProvider[k.providerID]--
	}
}

func (s *PerfStore) evictProviderOldestLocked(providerID string) {
	var oldestKey perfKey
	var oldest time.Time
	found := false
	for k, e := range s.entries {
		if k.providerID == providerID && (!found || e.LastObserved.Before(oldest)) {
			oldestKey, oldest, found = k, e.LastObserved, true
		}
	}
	if found {
		s.deleteLocked(oldestKey)
	}
}

// evictLocked frees room: records that are not fresh go first, then the
// least recently observed one.
func (s *PerfStore) evictLocked(now time.Time) {
	for k, e := range s.entries {
		if !e.Fresh(now) {
			s.deleteLocked(k)
		}
	}
	if len(s.entries) < s.max {
		return
	}
	var oldestKey perfKey
	var oldest time.Time
	first := true
	for k, e := range s.entries {
		if first || e.LastObserved.Before(oldest) {
			oldestKey, oldest, first = k, e.LastObserved, false
		}
	}
	s.deleteLocked(oldestKey)
}

// Lookup returns a copy of the record for providerID and model.
func (s *PerfStore) Lookup(providerID, model string) (PerfEvidence, bool) {
	if s == nil {
		return PerfEvidence{}, false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	e, ok := s.entries[perfKey{providerID: providerID, model: model}]
	if !ok {
		return PerfEvidence{}, false
	}
	return *e, true
}

// Len reports the number of records.
func (s *PerfStore) Len() int {
	if s == nil {
		return 0
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.entries)
}
