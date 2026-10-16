package computeintegrity

// SPEC-036 FR-21 scorer selection and FR-24 scorer integrity.

import (
	"math"
	"math/rand"
	"sort"
	"sync"
	"time"
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

// SelectScorers picks up to n scorers for a verified provider: distinct
// operators uniformly at random, then one eligible provider of each, so an
// operator with many Macs is not chosen more often (FR-21, FR-24). Every
// scorer has a different operator from the verified provider and from each
// other. eligible filters out keys in suspect, failed or recovering and
// scorer-excluded providers.
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
	byOperator := map[string][]ScorerCandidate{}
	var operators []string
	for _, c := range pool {
		if _, seen := byOperator[c.OperatorKey]; !seen {
			operators = append(operators, c.OperatorKey)
		}
		byOperator[c.OperatorKey] = append(byOperator[c.OperatorKey], c)
	}
	// Deterministic order before the shuffle so a seeded rng is reproducible.
	sort.Strings(operators)
	rng.Shuffle(len(operators), func(i, j int) { operators[i], operators[j] = operators[j], operators[i] })
	out := make([]ScorerCandidate, 0, n)
	for _, op := range operators {
		if len(out) >= n {
			break
		}
		members := byOperator[op]
		out = append(out, members[rng.Intn(len(members))])
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
	recent   []bool // double-scored measurements only; true = disagreed
	splits   int    // split answers: pair disagreements and failed known checks
	excluded bool
	// silent counts consecutive jobs without a valid answer; restUntil is the
	// availability back-off it triggers (FR-24).
	silent    int
	restUntil time.Time
}

// FR-24 availability back-off: a scorer that leaves this many consecutive
// jobs unanswered is not chosen for scorerRest, so verification moves on to
// other scorers instead of stalling.
const (
	scorerSilentLimit = 8
	scorerRest        = time.Hour
)

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
// counts as a split answer for that scorer; it does not enter the
// double-scored window, which holds pair measurements only. It reports
// whether the scorer became excluded.
func (t *ScorerTracker) RecordKnownCheck(providerID string, passed bool) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	r := t.record(providerID)
	if r.excluded {
		return false
	}
	if !passed {
		r.splits++
	}
	return t.evaluate(r)
}

// RecordAnswer resets a scorer's silence after a valid answer.
func (t *ScorerTracker) RecordAnswer(providerID string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	r := t.record(providerID)
	r.silent = 0
	r.restUntil = time.Time{}
}

// RecordNoAnswer counts a job without a valid answer and starts the
// availability back-off at the limit.
func (t *ScorerTracker) RecordNoAnswer(providerID string, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	r := t.record(providerID)
	r.silent++
	if r.silent >= scorerSilentLimit {
		r.silent = 0
		r.restUntil = now.Add(scorerRest)
	}
}

// Available reports whether a scorer may be chosen now: not excluded and
// not resting after persistent silence.
func (t *ScorerTracker) Available(providerID string, now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	r := t.scorers[providerID]
	return r == nil || (!r.excluded && !now.Before(r.restUntil))
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
	return t.evaluate(r)
}

func (t *ScorerTracker) evaluate(r *scorerRecord) bool {
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

// Prune drops the history of scorers that are not excluded and for which
// keep reports false, so the tracker stays bounded under fleet turnover.
// Exclusions are kept until an operator clears them.
func (t *ScorerTracker) Prune(keep func(providerID string) bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for id, r := range t.scorers {
		if !r.excluded && !keep(id) {
			delete(t.scorers, id)
		}
	}
}

// Clear removes a scorer exclusion and its history (operator action).
func (t *ScorerTracker) Clear(providerID string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.scorers, providerID)
}

// KnownSequence is an FR-24 consensus measurement kept in memory only.
// SourceProvider and SourceOperator name the verified provider that produced
// the output; Scorers and ScorerOperators the two scorers that agreed on it.
type KnownSequence struct {
	Body            []byte
	OutputText      string
	ReasoningText   string
	MeanLogprob     float64
	Top1Rate        float64
	SourceProvider  string
	SourceOperator  string
	Scorers         []string
	ScorerOperators []string
}

// independentOf reports whether a scorer may check this sequence: it is
// neither the source nor an original scorer, and shares no operator with
// any of them.
func (seq KnownSequence) independentOf(c ScorerCandidate) bool {
	if c.OperatorKey == "" || c.ProviderID == seq.SourceProvider || c.OperatorKey == seq.SourceOperator {
		return false
	}
	for _, s := range seq.Scorers {
		if s == c.ProviderID {
			return false
		}
	}
	for _, op := range seq.ScorerOperators {
		if op == c.OperatorKey {
			return false
		}
	}
	return true
}

// KnownSequences is the FR-24 in-memory cache. Safe for concurrent use.
type KnownSequences struct {
	mu   sync.Mutex
	keys map[ToleranceKey][]KnownSequence
	seen map[ToleranceKey]time.Time
}

// NewKnownSequences returns an empty cache.
func NewKnownSequences() *KnownSequences {
	return &KnownSequences{keys: map[ToleranceKey][]KnownSequence{}, seen: map[ToleranceKey]time.Time{}}
}

// Prune drops cached sequences of keys not offered since cutoff.
func (k *KnownSequences) Prune(cutoff time.Time) {
	k.mu.Lock()
	defer k.mu.Unlock()
	for key, at := range k.seen {
		if at.Before(cutoff) {
			delete(k.keys, key)
			delete(k.seen, key)
		}
	}
}

// Offer adds a measurement two scorers both scored in band with mean
// log-probabilities within 0.25 of each other.
func (k *KnownSequences) Offer(key ToleranceKey, seq KnownSequence, a, b Measurement, now time.Time) bool {
	if !a.Valid() || !b.Valid() || math.Abs(a.MeanLogprob()-b.MeanLogprob()) > knownSequenceLogprobGap {
		return false
	}
	seq.MeanLogprob = (a.MeanLogprob() + b.MeanLogprob()) / 2
	seq.Top1Rate = (a.Top1Rate() + b.Top1Rate()) / 2
	k.mu.Lock()
	defer k.mu.Unlock()
	k.seen[key] = now
	list := append(k.keys[key], seq)
	if len(list) > knownSequencesPerKey {
		list = list[len(list)-knownSequencesPerKey:]
	}
	k.keys[key] = list
	return true
}

// Pick returns a known sequence for key that scorer may check
// independently: not its source, not an original scorer, and no shared
// operator with either.
func (k *KnownSequences) Pick(rng *rand.Rand, key ToleranceKey, scorer ScorerCandidate) (KnownSequence, bool) {
	k.mu.Lock()
	defer k.mu.Unlock()
	var options []KnownSequence
	for _, seq := range k.keys[key] {
		if seq.independentOf(scorer) {
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
