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
	// PerfPrefillInputOutputRatio: a prefill sample needs input at least this
	// many times the generated output. Prefill runs roughly 20-50 times faster
	// per token than decode, so below this the service time is decode time.
	PerfPrefillInputOutputRatio = 32
	PerfMinDecodeTokens         = 8
	// PerfServiceMaxInputRatio: a service-throughput sample needs the whole
	// request estimate at most this many times the generated output, so a
	// prompt-ingestion attempt does not pass for generation.
	PerfServiceMaxInputRatio = 16
	PerfMaxTTFTMs            = 600_000
	PerfMaxPrefillTPS        = 50_000
	PerfMaxDecodeTPS         = 2_000
	PerfPriorWeightSamples   = 2
	PerfPriorCapOverMeasure  = 1.25
)

// PerfObservation is one coordinator-timed served attempt. Durations come
// from the coordinator's wall clock; PromptTokens is the coordinator's token
// estimate of the request body (0 withholds a prefill sample) and
// CompletionTokens its estimate of the generated output, never provider usage.
type PerfObservation struct {
	ProviderID         string
	Model              string
	PromptTokens       int64
	CachedPromptTokens int64
	CompletionTokens   int64
	TTFTMs             float64
	DecodeMs           float64
	// ServiceMs is provider dispatch start to done for either response mode,
	// which neither an early content token nor late response headers can
	// shorten. Prefill divides by it, and service throughput is the generated
	// output over it when RequestTokens (the whole request estimate, cached or
	// not) is at most PerfServiceMaxInputRatio times the output.
	ServiceMs     float64
	RequestTokens int64
	// EndToEnd marks an attempt without a first-token time (a non-streamed or
	// buffered response): TTFTMs and DecodeMs are ignored and it yields no
	// TTFT or decode sample.
	EndToEnd bool
	At       time.Time
}

// PerfEvidence is a read-only copy of one store record. Each signal keeps its
// own sample count and last observation time.
type PerfEvidence struct {
	TTFTMs     float64
	PrefillTPS float64
	DecodeTPS  float64
	// ServiceTPS is generated output over dispatch start to done, measured
	// the same way for streamed and non-streamed attempts.
	ServiceTPS          float64
	TTFTSamples         int
	PrefillSamples      int
	DecodeSamples       int
	ServiceSamples      int
	TTFTLastObserved    time.Time
	PrefillLastObserved time.Time
	DecodeLastObserved  time.Time
	ServiceLastObserved time.Time
	LastObserved        time.Time
}

func signalFresh(samples int, last, now time.Time) bool {
	return samples >= PerfFreshMinSamples && signalRecent(samples, last, now)
}

func signalRecent(samples int, last, now time.Time) bool {
	return samples > 0 && !last.IsZero() && now.Sub(last) <= PerfFreshMaxAge
}

// TTFTFresh, PrefillFresh, DecodeFresh and ServiceFresh report whether one signal has at
// least PerfFreshMinSamples samples, the latest within PerfFreshMaxAge.
func (e PerfEvidence) TTFTFresh(now time.Time) bool {
	return signalFresh(e.TTFTSamples, e.TTFTLastObserved, now)
}

func (e PerfEvidence) PrefillFresh(now time.Time) bool {
	return signalFresh(e.PrefillSamples, e.PrefillLastObserved, now)
}

func (e PerfEvidence) DecodeFresh(now time.Time) bool {
	return signalFresh(e.DecodeSamples, e.DecodeLastObserved, now)
}

func (e PerfEvidence) ServiceFresh(now time.Time) bool {
	return signalFresh(e.ServiceSamples, e.ServiceLastObserved, now)
}

// Fresh reports whether any signal of the record is fresh.
func (e PerfEvidence) Fresh(now time.Time) bool {
	return e.TTFTFresh(now) || e.PrefillFresh(now) || e.DecodeFresh(now) || e.ServiceFresh(now)
}

// FreshFor reports whether the record may rank a candidate for phase: the
// signal the phase is judged on must be fresh. A record without TTFT samples
// is never fresh for interactive, so a missing TTFT never reads as fast.
func (e PerfEvidence) FreshFor(phase Phase, now time.Time) bool {
	switch phase {
	case PhaseThroughput:
		return e.ServiceFresh(now)
	case PhaseLongInput:
		return e.PrefillFresh(now) || e.TTFTFresh(now)
	default:
		return e.TTFTFresh(now)
	}
}

// prefillAt is the prefill average when it was observed within
// PerfFreshMaxAge, else 0.
func (e PerfEvidence) prefillAt(now time.Time) float64 {
	if !signalRecent(e.PrefillSamples, e.PrefillLastObserved, now) {
		return 0
	}
	return e.PrefillTPS
}

// decodeAt is DecodeWithPrior when decode was observed within
// PerfFreshMaxAge, else 0.
func (e PerfEvidence) decodeAt(now time.Time, selfReported float64) float64 {
	if !signalRecent(e.DecodeSamples, e.DecodeLastObserved, now) {
		return 0
	}
	return e.DecodeWithPrior(selfReported)
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

// Observe records one served attempt. Invalid observations are ignored, and
// an end-to-end attempt that yields no sample creates no record.
func (s *PerfStore) Observe(o PerfObservation) {
	if s == nil || o.ProviderID == "" || o.Model == "" || o.At.IsZero() {
		return
	}
	if o.CompletionTokens < 0 || o.PromptTokens < 0 || o.RequestTokens < 0 {
		return
	}
	if !o.EndToEnd && (math.IsNaN(o.TTFTMs) || math.IsInf(o.TTFTMs, 0) || o.TTFTMs < 0) {
		return
	}
	uncached := o.PromptTokens - o.CachedPromptTokens
	if o.CachedPromptTokens < 0 || uncached < 0 {
		uncached = o.PromptTokens
	}
	// Prefill is measured on prefill-dominated attempts as input over the whole
	// service time, so a provider cannot inflate it by emitting early content.
	prefill := math.NaN()
	if uncached >= PerfMinPrefillTokens && uncached >= PerfPrefillInputOutputRatio*o.CompletionTokens && positiveMs(o.ServiceMs) {
		prefill = clampFloat(float64(uncached)/(o.ServiceMs/1000), 0, PerfMaxPrefillTPS)
	}
	// Decode needs a first token to split the window, so only timed attempts.
	decode := math.NaN()
	if !o.EndToEnd && o.CompletionTokens >= PerfMinDecodeTokens && positiveMs(o.DecodeMs) {
		decode = clampFloat(float64(o.CompletionTokens-1)/(o.DecodeMs/1000), 0, PerfMaxDecodeTPS)
	}
	service := math.NaN()
	if o.CompletionTokens >= PerfMinDecodeTokens && positiveMs(o.ServiceMs) && o.RequestTokens <= PerfServiceMaxInputRatio*o.CompletionTokens {
		service = clampFloat(float64(o.CompletionTokens)/(o.ServiceMs/1000), 0, PerfMaxDecodeTPS)
	}
	if o.EndToEnd && math.IsNaN(prefill) && math.IsNaN(service) {
		return
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
	if !o.EndToEnd {
		e.TTFTMs = ewma(e.TTFTMs, e.TTFTSamples, clampFloat(o.TTFTMs, 1, PerfMaxTTFTMs))
		e.TTFTSamples = saturatingInc(e.TTFTSamples)
		e.TTFTLastObserved = latest(e.TTFTLastObserved, o.At)
	}
	if !math.IsNaN(prefill) {
		e.PrefillTPS = ewma(e.PrefillTPS, e.PrefillSamples, prefill)
		e.PrefillSamples = saturatingInc(e.PrefillSamples)
		e.PrefillLastObserved = latest(e.PrefillLastObserved, o.At)
	}
	if !math.IsNaN(decode) {
		e.DecodeTPS = ewma(e.DecodeTPS, e.DecodeSamples, decode)
		e.DecodeSamples = saturatingInc(e.DecodeSamples)
		e.DecodeLastObserved = latest(e.DecodeLastObserved, o.At)
	}
	if !math.IsNaN(service) {
		e.ServiceTPS = ewma(e.ServiceTPS, e.ServiceSamples, service)
		e.ServiceSamples = saturatingInc(e.ServiceSamples)
		e.ServiceLastObserved = latest(e.ServiceLastObserved, o.At)
	}
	e.LastObserved = latest(e.LastObserved, o.At)
}

func positiveMs(ms float64) bool {
	return ms > 0 && !math.IsInf(ms, 0)
}

func latest(prev, at time.Time) time.Time {
	if at.After(prev) {
		return at
	}
	return prev
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

// LookupMany returns copies of the records for model and each providerID
// present, under one read lock.
func (s *PerfStore) LookupMany(model string, providerIDs []string) map[string]PerfEvidence {
	out := make(map[string]PerfEvidence, len(providerIDs))
	if s == nil {
		return out
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, id := range providerIDs {
		if e, ok := s.entries[perfKey{providerID: id, model: model}]; ok {
			out[id] = *e
		}
	}
	return out
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
