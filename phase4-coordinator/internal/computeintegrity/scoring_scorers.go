package computeintegrity

// SPEC-036 FR-21 scorer selection and FR-24 scorer integrity.

import (
	"math"
	"math/rand"
	"sync"
)

// ScorerCandidate is the subset of a connected provider session scorer
// selection needs.
type ScorerCandidate struct {
	ProviderID     string
	AssignedID     string
	ModelID        string
	ManifestSHA256 string
	OperatorKey    string
	Capable        bool // advertised tier2_capabilities.compute_score_v1
	Ready          bool // connected and ready or busy
}

// SelectScorers picks up to n scorers for a verified provider uniformly at
// random, each of a different operator from the verified provider and from
// each other (FR-21, FR-23). eligible filters out keys in suspect, failed or
// recovering and scorer-excluded providers.
func SelectScorers(
	rng *rand.Rand,
	verified ScorerCandidate,
	candidates []ScorerCandidate,
	n int,
	eligible func(ScorerCandidate) bool,
) []ScorerCandidate {
	pool := make([]ScorerCandidate, 0, len(candidates))
	for _, c := range candidates {
		if !c.Capable || !c.Ready ||
			c.ProviderID == verified.ProviderID ||
			c.ModelID != verified.ModelID ||
			c.ManifestSHA256 == "" || c.ManifestSHA256 != verified.ManifestSHA256 ||
			c.OperatorKey == "" || c.OperatorKey == verified.OperatorKey {
			continue
		}
		if eligible != nil && !eligible(c) {
			continue
		}
		pool = append(pool, c)
	}
	rng.Shuffle(len(pool), func(i, j int) { pool[i], pool[j] = pool[j], pool[i] })
	out := make([]ScorerCandidate, 0, n)
	usedOps := map[string]struct{}{}
	for _, c := range pool {
		if len(out) >= n {
			break
		}
		if _, used := usedOps[c.OperatorKey]; used {
			continue
		}
		usedOps[c.OperatorKey] = struct{}{}
		out = append(out, c)
	}
	return out
}

// FR-24 thresholds.
const (
	scorerAgreementWindow   = 8
	scorerMinSplits         = 4
	knownSequencesPerKey    = 8
	knownSequenceLogprobGap = 0.25
	knownCheckLogprobDrop   = 0.5
	knownCheckTop1Drop      = 0.1
	// KnownSequenceCheckEvery is how many scoring jobs pass between
	// known-sequence checks (FR-24).
	KnownSequenceCheckEvery = 25
)

type scorerRecord struct {
	recent   []bool // true = disagreed
	splits   int
	excluded bool
}

// ScorerTracker tracks FR-24 scorer agreement. Safe for concurrent use.
type ScorerTracker struct {
	mu      sync.Mutex
	scorers map[string]*scorerRecord
}

// NewScorerTracker returns a tracker; excluded seeds persisted exclusions.
func NewScorerTracker(excluded []string) *ScorerTracker {
	t := &ScorerTracker{scorers: map[string]*scorerRecord{}}
	for _, id := range excluded {
		t.scorers[id] = &scorerRecord{excluded: true}
	}
	return t
}

func (t *ScorerTracker) record(providerID string) *scorerRecord {
	r := t.scorers[providerID]
	if r == nil {
		r = &scorerRecord{}
		t.scorers[providerID] = r
	}
	return r
}

// RecordPair records a double-scored measurement: agree is whether both
// scorers put it on the same side of the band. It returns the scorers that
// became excluded by this record.
func (t *ScorerTracker) RecordPair(a, b string, agree bool) []string {
	t.mu.Lock()
	defer t.mu.Unlock()
	var newly []string
	for _, id := range []string{a, b} {
		if id == "" {
			continue
		}
		if t.observe(id, !agree) {
			newly = append(newly, id)
		}
	}
	return newly
}

// RecordKnownCheck records a known-sequence check answer. A failed check
// counts as a split answer for that scorer. It reports whether the scorer
// became excluded.
func (t *ScorerTracker) RecordKnownCheck(providerID string, passed bool) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.observe(providerID, !passed)
}

func (t *ScorerTracker) observe(providerID string, disagreed bool) bool {
	r := t.record(providerID)
	if r.excluded {
		return false
	}
	r.recent = append(r.recent, disagreed)
	if len(r.recent) > scorerAgreementWindow {
		r.recent = r.recent[len(r.recent)-scorerAgreementWindow:]
	}
	if disagreed {
		r.splits++
	}
	disagreements := 0
	for _, d := range r.recent {
		if d {
			disagreements++
		}
	}
	if r.splits >= scorerMinSplits && disagreements*2 > len(r.recent) {
		r.excluded = true
		return true
	}
	return false
}

// Excluded reports whether a scorer is FR-24 scorer-excluded.
func (t *ScorerTracker) Excluded(providerID string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	r := t.scorers[providerID]
	return r != nil && r.excluded
}

// Clear removes a scorer exclusion and its history (operator action).
func (t *ScorerTracker) Clear(providerID string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.scorers, providerID)
}

// KnownSequence is an FR-24 consensus measurement kept in memory only.
type KnownSequence struct {
	Body          []byte
	OutputText    string
	ReasoningText string
	MeanLogprob   float64
	Top1Rate      float64
	Scorers       []string
}

// KnownSequences is the FR-24 in-memory cache. Safe for concurrent use.
type KnownSequences struct {
	mu   sync.Mutex
	keys map[ToleranceKey][]KnownSequence
}

// NewKnownSequences returns an empty cache.
func NewKnownSequences() *KnownSequences {
	return &KnownSequences{keys: map[ToleranceKey][]KnownSequence{}}
}

// Offer adds a measurement two scorers both scored in band with mean
// log-probabilities within 0.25 of each other.
func (k *KnownSequences) Offer(key ToleranceKey, seq KnownSequence, a, b Measurement) bool {
	if !a.Valid() || !b.Valid() || math.Abs(a.MeanLogprob()-b.MeanLogprob()) > knownSequenceLogprobGap {
		return false
	}
	seq.MeanLogprob = (a.MeanLogprob() + b.MeanLogprob()) / 2
	seq.Top1Rate = (a.Top1Rate() + b.Top1Rate()) / 2
	k.mu.Lock()
	defer k.mu.Unlock()
	list := append(k.keys[key], seq)
	if len(list) > knownSequencesPerKey {
		list = list[len(list)-knownSequencesPerKey:]
	}
	k.keys[key] = list
	return true
}

// Pick returns a known sequence for key that scorer did not score originally.
func (k *KnownSequences) Pick(rng *rand.Rand, key ToleranceKey, scorer string) (KnownSequence, bool) {
	k.mu.Lock()
	defer k.mu.Unlock()
	var options []KnownSequence
	for _, seq := range k.keys[key] {
		scored := false
		for _, s := range seq.Scorers {
			if s == scorer {
				scored = true
				break
			}
		}
		if !scored {
			options = append(options, seq)
		}
	}
	if len(options) == 0 {
		return KnownSequence{}, false
	}
	return options[rng.Intn(len(options))], true
}

// KnownCheckPassed applies the FR-24 known-sequence comparison.
func KnownCheckPassed(seq KnownSequence, m Measurement) bool {
	if !m.Valid() {
		return false
	}
	return m.MeanLogprob() >= seq.MeanLogprob-knownCheckLogprobDrop &&
		m.Top1Rate() >= seq.Top1Rate-knownCheckTop1Drop
}
