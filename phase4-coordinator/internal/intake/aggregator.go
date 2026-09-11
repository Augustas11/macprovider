// Package intake implements the SPEC-023 §16.2(a) `unmatched_model_request_count`
// aggregator as adopted by SPEC-017 v0.2.1 §5.2b: a fixed-memory Space-Saving
// summary of buyer requests whose model string resolved to no admitted catalog
// key, with the per-request processing order S1–S5, the closed
// `other_suppressed` overflow bucket, an opaque window-scoped principal cap,
// and k-anonymity suppression at emission.
//
// The package is a leaf: it holds no database handle, imports nothing from the
// rest of the coordinator, and its only outputs are the wire structs below.
// Callers perform the S1 authentication/model-resolution filter and pass the
// authenticated account id as the principal; the aggregator applies the
// excluded-account flag, normalization, grammar, cap, and summary update.
package intake

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"sync"
	"time"
)

const (
	// Contract names the SPEC-023 clause this aggregator implements; it is
	// emitted verbatim in the wire object.
	Contract = "SPEC-023-16.2a"
	// KAnonymityMin is the SPEC-017 v0.2.1 effective k-anonymity floor. It
	// equals the SPEC-023-owned INTAKE_K_ANONYMITY_MIN and is not
	// configurable (SPEC-017 §5.2b.1).
	KAnonymityMin = 3
	// WindowMaxDays bounds an aggregator epoch (SPEC-017 §3.2a).
	WindowMaxDays = 30
	// MaxEmittedWindows bounds the `windows` array (SPEC-017 §5.2b.5): at
	// most three complete 30-day windows fit the 90-day retention.
	MaxEmittedWindows = 3
	// EmissionRetention bounds how old a closed window may be and still be
	// emitted (SPEC-017 §5.2b.5).
	EmissionRetention = 90 * 24 * time.Hour

	// requestCountSaturation is 2^53 - 1 (SPEC-023 §16.2(a) item 6).
	requestCountSaturation uint64 = 1<<53 - 1
	principalTokenLabel           = "macprovider.intake.unknown_model_principal.v1"
	principalTokenBytes           = 16
	windowKeyBytes                = 32
	windowIDBytes                 = 16
	maxKeyBytes                   = 128

	CloseReasonEpochElapsed       = "epoch_elapsed"
	CloseReasonAggregatorStopped  = "aggregator_stopped"
	CloseReasonParametersChanged  = "parameters_changed"
	CloseReasonEligibilityChanged = "eligibility_changed"

	eligibilityPolicyIDBytes = 16

	// Configuration maxima (SPEC-017 §5.2b.7): operationally safe ceilings
	// so K × P and the cap arithmetic stay bounded.
	MaxKeyBuckets          = 4096
	MaxPrincipalsPerBucket = 4096
	MaxDistinctKeyCap      = 10_000_000
	MaxBuyerRequestFloor   = 1_000_000_000
)

// Params are the operator-configurable SPEC-023 §16.4 knobs the aggregator
// runs with (SPEC-017 §5.2b.7). A change to any of them closes the open
// window.
type Params struct {
	KeyBuckets          int
	PrincipalsPerBucket int
	DistinctKeyCap      int
	BuyerRequestFloor   int
	PrincipalCapPct     int
}

// DefaultParams are the SPEC-023 §16.4 defaults.
func DefaultParams() Params {
	return Params{
		KeyBuckets:          64,
		PrincipalsPerBucket: 64,
		DistinctKeyCap:      10000,
		BuyerRequestFloor:   250,
		PrincipalCapPct:     10,
	}
}

// PrincipalCapRequests is floor(BuyerRequestFloor × PrincipalCapPct / 100):
// the most one principal may contribute to one bucket in one window.
func (p Params) PrincipalCapRequests() int {
	return p.BuyerRequestFloor * p.PrincipalCapPct / 100
}

// Validate applies the SPEC-017 §5.2b.7 rules.
func (p Params) Validate() error {
	switch {
	case p.KeyBuckets <= 0:
		return errors.New("intake: key_buckets must be positive")
	case p.PrincipalsPerBucket <= 0:
		return errors.New("intake: principals_per_bucket must be positive")
	case p.DistinctKeyCap <= 0:
		return errors.New("intake: distinct_key_cap must be positive")
	case p.BuyerRequestFloor <= 0:
		return errors.New("intake: buyer_request_floor must be positive")
	case p.PrincipalCapPct < 1 || p.PrincipalCapPct > 10:
		// SPEC-023 §16.4: clearing the floor needs at least ten independent
		// principals, so the cap may never exceed a tenth of the floor.
		return errors.New("intake: principal_cap_pct must be in [1, 10]")
	case p.PrincipalCapRequests() < 1:
		return errors.New("intake: buyer_request_floor × principal_cap_pct / 100 must be at least 1")
	case p.KeyBuckets > MaxKeyBuckets:
		return fmt.Errorf("intake: key_buckets must be at most %d", MaxKeyBuckets)
	case p.PrincipalsPerBucket > MaxPrincipalsPerBucket:
		return fmt.Errorf("intake: principals_per_bucket must be at most %d", MaxPrincipalsPerBucket)
	case p.DistinctKeyCap > MaxDistinctKeyCap:
		return fmt.Errorf("intake: distinct_key_cap must be at most %d", MaxDistinctKeyCap)
	case p.BuyerRequestFloor > MaxBuyerRequestFloor:
		return fmt.Errorf("intake: buyer_request_floor must be at most %d", MaxBuyerRequestFloor)
	}
	return nil
}

// Parameters is the wire form of the parameters in force for the open
// window (SPEC-017 §5.2b.1).
type Parameters struct {
	KeyBuckets           int `json:"key_buckets"`
	PrincipalsPerBucket  int `json:"principals_per_bucket"`
	DistinctKeyCap       int `json:"distinct_key_cap"`
	BuyerRequestFloor    int `json:"buyer_request_floor"`
	PrincipalCapPct      int `json:"principal_cap_pct"`
	PrincipalCapRequests int `json:"principal_cap_requests"`
	KAnonymityMin        int `json:"k_anonymity_min"`
	WindowMaxDays        int `json:"window_max_days"`
}

// Bucket is one emitted (unsuppressed) key. A bucket to which fewer than
// KAnonymityMin distinct principals contributed, or whose lower bound is
// below the window's buyer_request_floor, is never emitted (SPEC-017
// §5.2b.4, §5.2b.5); it is counted in Window.SuppressedBucketCount.
type Bucket struct {
	ModelKey   string `json:"model_key"`
	LowerBound uint64 `json:"lower_bound"`
	Count      uint64 `json:"count"`
	Error      uint64 `json:"error"`
}

// ClearsFloor reports whether this bucket's lower bound — and only that
// value — satisfies a floor (SPEC-023 §16.2(a) items 5 and 9).
func (b Bucket) ClearsFloor(floor uint64) bool {
	return b.LowerBound >= floor
}

// OtherSuppressed is the exact closed four-field overflow bucket
// (SPEC-023 §16.2(a) item 6).
type OtherSuppressed struct {
	RequestCount              uint64 `json:"request_count"`
	RequestCountSaturated     bool   `json:"request_count_saturated"`
	DistinctKeyCount          uint64 `json:"distinct_key_count"`
	DistinctKeyCountSaturated bool   `json:"distinct_key_count_saturated"`
}

// Window is one COMPLETE aggregator epoch on the wire (SPEC-017 §5.2b.5):
// exactly WindowMaxDays long, closed by epoch_elapsed. Only complete windows
// are ever served or persisted; the open window exists only in the local
// diagnostic form (Aggregator.DiagnosticDump), where window_end is null.
type Window struct {
	WindowID              string          `json:"window_id"`
	WindowStart           string          `json:"window_start"`
	WindowEnd             *string         `json:"window_end"`
	Parameters            Parameters      `json:"parameters"`
	EligibilityPolicyID   string          `json:"eligibility_policy_id"`
	Buckets               []Bucket        `json:"buckets"`
	SuppressedBucketCount int             `json:"suppressed_bucket_count"`
	OtherSuppressed       OtherSuppressed `json:"other_suppressed"`
}

// ParseUTC accepts exactly the SPEC-017 §5.2b timestamp form —
// YYYY-MM-DDTHH:MM:SSZ, no offset, no fraction — so one instant has one
// byte string and window equality is byte equality.
func ParseUTC(s string) (time.Time, error) {
	if len(s) != len("2006-01-02T15:04:05Z") || s[len(s)-1] != 'Z' {
		return time.Time{}, fmt.Errorf("intake: timestamp %q is not YYYY-MM-DDTHH:MM:SSZ", s)
	}
	t, err := time.Parse("2006-01-02T15:04:05Z", s)
	if err != nil {
		return time.Time{}, fmt.Errorf("intake: timestamp %q: %w", s, err)
	}
	return t.UTC(), nil
}

// Complete reports whether the window is a served, exactly-30-day epoch.
func (w Window) Complete() bool {
	if w.WindowEnd == nil {
		return false
	}
	start, err1 := ParseUTC(w.WindowStart)
	end, err2 := ParseUTC(*w.WindowEnd)
	return err1 == nil && err2 == nil && end.Sub(start) == WindowMaxDays*24*time.Hour
}

// FleetRAMClassFloors is the fixed closed class list of SPEC-017 §5.2b.6.
var FleetRAMClassFloors = []int{8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 512}

// ValidateFleetRAMJSON checks a persisted or served `fleet_ram` object
// against the closed contract: exactly the six keys, the one timestamp
// form with an exact 30-day window, k fixed, the eleven floors in order,
// provider_count null exactly when suppressed and never below k, and
// provider_total reconciling to the emitted counts plus provider_suppressed.
func ValidateFleetRAMJSON(raw []byte) error {
	var fleet struct {
		WindowStart        string `json:"window_start"`
		WindowEnd          string `json:"window_end"`
		KAnonymityMin      int    `json:"k_anonymity_min"`
		ProviderTotal      int    `json:"provider_total"`
		ProviderSuppressed int    `json:"provider_suppressed"`
		Classes            []struct {
			RAMGBFloor    int  `json:"ram_gb_floor"`
			ProviderCount *int `json:"provider_count"`
			Suppressed    bool `json:"suppressed"`
		} `json:"classes"`
	}
	if err := DecodeClosed(raw, &fleet); err != nil {
		return err
	}
	start, err := ParseUTC(fleet.WindowStart)
	if err != nil {
		return err
	}
	end, err := ParseUTC(fleet.WindowEnd)
	if err != nil {
		return err
	}
	if end.Sub(start) != WindowMaxDays*24*time.Hour {
		return errors.New("intake: fleet_ram window is not exactly 30 days")
	}
	if fleet.KAnonymityMin != KAnonymityMin || fleet.ProviderTotal < 0 || fleet.ProviderSuppressed < 0 || len(fleet.Classes) != len(FleetRAMClassFloors) {
		return errors.New("intake: fleet_ram shape")
	}
	emitted := 0
	for i, c := range fleet.Classes {
		if c.RAMGBFloor != FleetRAMClassFloors[i] || c.Suppressed != (c.ProviderCount == nil) {
			return errors.New("intake: fleet_ram class")
		}
		if c.ProviderCount != nil {
			if *c.ProviderCount < KAnonymityMin {
				return errors.New("intake: fleet_ram emits a sub-k class")
			}
			emitted += *c.ProviderCount
		}
	}
	if emitted+fleet.ProviderSuppressed != fleet.ProviderTotal {
		return errors.New("intake: fleet_ram does not reconcile")
	}
	return nil
}

// DecodeClosed decodes exactly one JSON document into v, refusing any key
// the closed shape does not declare and any trailing content.
func DecodeClosed(raw []byte, v any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return err
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return errors.New("intake: trailing content after the JSON document")
	}
	return nil
}

// ValidateWindowAt is ValidateWindow plus the freshness half the wire
// contract implies: a served window closed no later than now — a
// future-dated persisted window is never evidence.
func ValidateWindowAt(w Window, now time.Time) error {
	if err := ValidateWindow(w); err != nil {
		return err
	}
	if end, _ := ParseUTC(*w.WindowEnd); end.After(now) {
		return fmt.Errorf("intake: window %s ends in the future", w.WindowID)
	}
	return nil
}

// ValidateFleetRAMJSONAt is ValidateFleetRAMJSON plus window_end ≤ now.
func ValidateFleetRAMJSONAt(raw []byte, now time.Time) error {
	if err := ValidateFleetRAMJSON(raw); err != nil {
		return err
	}
	var f struct {
		WindowEnd string `json:"window_end"`
	}
	_ = json.Unmarshal(raw, &f)
	if end, _ := ParseUTC(f.WindowEnd); end.After(now) {
		return errors.New("intake: fleet_ram window ends in the future")
	}
	return nil
}

// ValidateWindow checks a served or persisted window against the closed
// wire contract (SPEC-017 §5.2b): complete, ids well-formed, parameters
// valid with k fixed, buckets at most key_buckets, each bucket a normalized
// key with lower_bound == count − error ≥ buyer_request_floor, ordered by
// lower_bound descending then key. A malformed window is never merged or
// served.
func ValidateWindow(w Window) error {
	if !hexID(w.WindowID) || !hexID(w.EligibilityPolicyID) {
		return errors.New("intake: window_id and eligibility_policy_id must be 32-hex")
	}
	if !w.Complete() {
		return fmt.Errorf("intake: window %s is not a complete %d-day epoch", w.WindowID, WindowMaxDays)
	}
	p := Params{KeyBuckets: w.Parameters.KeyBuckets, PrincipalsPerBucket: w.Parameters.PrincipalsPerBucket, DistinctKeyCap: w.Parameters.DistinctKeyCap, BuyerRequestFloor: w.Parameters.BuyerRequestFloor, PrincipalCapPct: w.Parameters.PrincipalCapPct}
	if err := p.Validate(); err != nil {
		return err
	}
	if w.Parameters.PrincipalCapRequests != p.PrincipalCapRequests() || w.Parameters.KAnonymityMin != KAnonymityMin || w.Parameters.WindowMaxDays != WindowMaxDays {
		return errors.New("intake: window parameters are inconsistent")
	}
	if w.SuppressedBucketCount < 0 {
		return errors.New("intake: negative counter")
	}
	if len(w.Buckets)+w.SuppressedBucketCount > w.Parameters.KeyBuckets {
		return errors.New("intake: more buckets than key_buckets")
	}
	seen := map[string]struct{}{}
	for i, b := range w.Buckets {
		if !keyEligible(b.ModelKey) {
			return fmt.Errorf("intake: bucket key %q is not a normalized key", b.ModelKey)
		}
		if _, dup := seen[b.ModelKey]; dup {
			return fmt.Errorf("intake: duplicate bucket key %q", b.ModelKey)
		}
		seen[b.ModelKey] = struct{}{}
		if b.Error > b.Count || b.LowerBound != b.Count-b.Error || b.LowerBound < uint64(w.Parameters.BuyerRequestFloor) {
			return fmt.Errorf("intake: bucket %q violates lower_bound == count - error >= buyer_request_floor", b.ModelKey)
		}
		if i > 0 {
			prev := w.Buckets[i-1]
			if prev.LowerBound < b.LowerBound || (prev.LowerBound == b.LowerBound && prev.ModelKey > b.ModelKey) {
				return errors.New("intake: buckets are not ordered by lower_bound desc, key asc")
			}
		}
	}
	if w.OtherSuppressed.DistinctKeyCount > uint64(w.Parameters.DistinctKeyCap) || w.OtherSuppressed.RequestCount > requestCountSaturation {
		return errors.New("intake: other_suppressed exceeds its saturation")
	}
	return nil
}

func hexID(s string) bool {
	if len(s) != 32 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// UnmatchedModels is the `unmatched_models` object of
// `macprovider.stats-intake.v1`.
type UnmatchedModels struct {
	Contract string   `json:"contract"`
	Windows  []Window `json:"windows"`
}

type entry struct {
	key        string
	count      uint64
	err        uint64
	principals map[[principalTokenBytes]byte]uint32
}

type window struct {
	id          string
	start       time.Time
	key         [windowKeyBytes]byte
	entries     []*entry
	index       map[string]*entry
	other       OtherSuppressed
	eligible    uint64
	params      Params
	policyID    string // eligibility_policy_id in force for this window
	policyCount int    // excluded_account_count in force for this window
}

// Aggregator is safe for concurrent use.
type Aggregator struct {
	mu          sync.Mutex
	params      Params
	normalize   func(string) string
	policyID    string // eligibility_policy_id supplied by the caller (SPEC-017 §5.2b.2)
	policyCount int    // excluded_account_count supplied by the caller
	now         func() time.Time
	random      io.Reader
	open        *window
	closed      []Window // COMPLETE windows only, newest first, at most MaxEmittedWindows
	lastClose   CloseRecord
	stopped     bool
}

// CloseRecord is the constant-size local record of the most recent close
// (SPEC-017 §3.2a); an incomplete window leaves nothing else behind.
type CloseRecord struct {
	WindowID string
	Reason   string
	ClosedAt time.Time
}

// LastClose returns the most recent close record (local diagnostics only).
func (a *Aggregator) LastClose() CloseRecord {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.lastClose
}

// Option configures an Aggregator.
type Option func(*Aggregator)

// WithClock injects the clock (tests).
func WithClock(now func() time.Time) Option {
	return func(a *Aggregator) { a.now = now }
}

// WithRandom injects the random source used for window ids and keys
// (tests); production uses crypto/rand.
func WithRandom(r io.Reader) Option {
	return func(a *Aggregator) { a.random = r }
}

// WithPolicy records the eligibility policy in force (SPEC-017 §5.2b.2):
// the caller — the buyer boundary, which alone holds the excluded-account
// set — derives the opaque policy id and passes only that id and the set's
// cardinality. The aggregator never sees an account identifier.
func WithPolicy(policyID string, excludedAccountCount int) Option {
	return func(a *Aggregator) {
		a.policyID, a.policyCount = policyID, excludedAccountCount
	}
}

// New returns an Aggregator with an open window. normalize is the
// SPEC-005 §5.5 NormalizeModelKey implementation and is required.
func New(params Params, normalize func(string) string, opts ...Option) (*Aggregator, error) {
	if normalize == nil {
		return nil, errors.New("intake: normalize is required")
	}
	if err := params.Validate(); err != nil {
		return nil, err
	}
	a := &Aggregator{
		params:    params,
		normalize: normalize,
		now:       func() time.Time { return time.Now().UTC() },
		random:    rand.Reader,
	}
	for _, opt := range opts {
		opt(a)
	}
	if !hexID(a.policyID) {
		return nil, errors.New("intake: eligibility policy id is required (32-hex)")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.openLocked(a.now()); err != nil {
		return nil, err
	}
	return a, nil
}

// SetPolicy replaces the eligibility policy in force. A different policy id
// closes the open window with `eligibility_changed` so one window never
// mixes two policies (SPEC-017 §3.2a, §5.2b.2).
func (a *Aggregator) SetPolicy(policyID string, excludedAccountCount int) error {
	if !hexID(policyID) {
		return errors.New("intake: eligibility policy id must be 32-hex")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if policyID == a.policyID && excludedAccountCount == a.policyCount {
		return nil
	}
	now := a.now()
	if a.open != nil {
		a.closeLocked(now, CloseReasonEligibilityChanged)
	}
	a.policyID, a.policyCount = policyID, excludedAccountCount
	if a.stopped {
		return nil
	}
	return a.openLocked(now)
}

// SetParams applies new parameters; a change closes the open window with
// `parameters_changed` and opens a fresh one.
func (a *Aggregator) SetParams(params Params) error {
	if err := params.Validate(); err != nil {
		return err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if params == a.params {
		return nil
	}
	now := a.now()
	if a.open != nil {
		a.closeLocked(now, CloseReasonParametersChanged)
	}
	a.params = params
	if a.stopped {
		return nil
	}
	return a.openLocked(now)
}

// Stop closes the open window with `aggregator_stopped`. Later Observe
// calls contribute to nothing; Snapshot keeps serving the closed windows.
func (a *Aggregator) Stop() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.open != nil {
		a.closeLocked(a.now(), CloseReasonAggregatorStopped)
	}
	a.stopped = true
}

// Observe records one buyer request that passed the caller's S1
// authentication, model-resolution, and eligibility-policy checks. rawModel
// is the buyer's requested model string; accountID the authenticated buyer
// account id. The id is used exactly once, to derive the principal token
// BEFORE any intake state is touched, and is not retained (SPEC-023
// §16.2(a) item 10, step S4).
func (a *Aggregator) Observe(rawModel, accountID string) {
	if accountID == "" {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.stopped {
		return
	}
	now := a.now()
	if err := a.ensureWindowLocked(now); err != nil || a.open == nil {
		return
	}
	w := a.open
	// S2 — normalize before any lookup; the raw string is never a key.
	key := a.normalize(rawModel)
	eligibleKey := keyEligible(key)
	// S4 (derivation only) — the token is derived first so no mutation below
	// runs while the raw identifier is still needed; the id is then dropped.
	var token [principalTokenBytes]byte
	if eligibleKey {
		token = principalToken(&w.key, accountID)
	}
	accountID = ""
	w.eligible++
	// S3 — closed grammar and byte limit.
	if !eligibleKey {
		w.other.addRequests(1)
		w.other.addDistinct(1, w.params.DistinctKeyCap)
		return
	}
	// S4 (cap and bound) against the bucket this key would target.
	cap := uint32(w.params.PrincipalCapRequests())
	e := w.index[key]
	if e != nil {
		if seen, tracked := e.principals[token]; tracked {
			if seen >= cap {
				w.other.addRequests(1)
				return
			}
		} else if len(e.principals) >= w.params.PrincipalsPerBucket {
			// Overflow principal: never reaches S5.
			w.other.addRequests(1)
			return
		}
	}
	// S5 — Space-Saving update for an intake-eligible contribution.
	switch {
	case e != nil:
		e.count++
		e.principals[token]++
	case len(w.entries) < w.params.KeyBuckets:
		e = &entry{key: key, count: 1, err: 0, principals: map[[principalTokenBytes]byte]uint32{token: 1}}
		w.entries = append(w.entries, e)
		w.index[key] = e
	default:
		victim := selectVictim(w.entries)
		w.other.addRequests(victim.count - victim.err)
		w.other.addDistinct(1, w.params.DistinctKeyCap)
		delete(w.index, victim.key)
		victim.principals = map[[principalTokenBytes]byte]uint32{token: 1}
		victim.err = victim.count
		victim.count = victim.count + 1
		victim.key = key
		w.index[key] = victim
	}
}

// Snapshot returns the wire object: COMPLETE windows only (closed by
// epoch_elapsed), newest first, bounded by MaxEmittedWindows and
// EmissionRetention. The open window and incomplete windows are never
// part of it (SPEC-017 §5.2b.5).
func (a *Aggregator) Snapshot() UnmatchedModels {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	if !a.stopped {
		_ = a.ensureWindowLocked(now)
	}
	out := UnmatchedModels{Contract: Contract, Windows: []Window{}}
	cutoff := now.Add(-EmissionRetention)
	for _, w := range a.closed {
		if len(out.Windows) >= MaxEmittedWindows {
			break
		}
		if !w.Complete() {
			continue
		}
		if end, err := ParseUTC(*w.WindowEnd); err == nil && end.Before(cutoff) {
			continue
		}
		out.Windows = append(out.Windows, cloneWindow(w))
	}
	return out
}

// DiagnosticDump is the serialized local form of the aggregator's state a
// test or operator may take — never served: exactly the `unmatched_models`
// object restricted to the open window and nothing else (SPEC-017
// §5.2b.5). The open window's emission rules are the served ones, so a
// dump never carries a sub-floor or sub-k key either.
func (a *Aggregator) DiagnosticDump() ([]byte, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := UnmatchedModels{Contract: Contract, Windows: []Window{}}
	if a.open != nil {
		out.Windows = append(out.Windows, a.open.wire(nil, ""))
	}
	return json.Marshal(out)
}

func (a *Aggregator) ensureWindowLocked(now time.Time) error {
	if a.open == nil {
		return a.openLocked(now)
	}
	// An epoch closes at exactly start + 30 days, whatever time the closing
	// call arrives; the next epoch opens at that deadline, so a late tick
	// yields exact windows and, if more than one deadline passed, empty
	// complete windows for the intervening epochs.
	for {
		deadline := a.open.start.Add(WindowMaxDays * 24 * time.Hour)
		if now.Before(deadline) {
			return nil
		}
		a.closeLocked(deadline, CloseReasonEpochElapsed)
		if err := a.openLocked(deadline); err != nil {
			return err
		}
	}
}

func (a *Aggregator) openLocked(now time.Time) error {
	w := &window{start: now.UTC(), index: map[string]*entry{}, params: a.params, policyID: a.policyID, policyCount: a.policyCount}
	if _, err := io.ReadFull(a.random, w.key[:]); err != nil {
		return fmt.Errorf("intake: window key: %w", err)
	}
	var id [windowIDBytes]byte
	if _, err := io.ReadFull(a.random, id[:]); err != nil {
		return fmt.Errorf("intake: window id: %w", err)
	}
	w.id = hex.EncodeToString(id[:])
	a.open = w
	return nil
}

func (a *Aggregator) closeLocked(now time.Time, reason string) {
	w := a.open
	end := now.UTC()
	var closed Window
	complete := reason == CloseReasonEpochElapsed
	if complete {
		closed = w.wire(&end, reason)
	}
	// Destroy the window key and every principal table with the window
	// (SPEC-023 §16.2(a) items 7 and 10). An incomplete window leaves only
	// the constant-size close record behind (SPEC-017 §3.2a).
	for i := range w.key {
		w.key[i] = 0
	}
	for _, e := range w.entries {
		for k := range e.principals {
			delete(e.principals, k)
		}
		e.principals = nil
	}
	w.entries = nil
	w.index = nil
	a.open = nil
	a.lastClose = CloseRecord{WindowID: w.id, Reason: reason, ClosedAt: end}
	if !complete {
		return
	}
	a.closed = append([]Window{closed}, a.closed...)
	if len(a.closed) > MaxEmittedWindows {
		a.closed = a.closed[:MaxEmittedWindows]
	}
}

func (p Params) wire() Parameters {
	return Parameters{
		KeyBuckets:           p.KeyBuckets,
		PrincipalsPerBucket:  p.PrincipalsPerBucket,
		DistinctKeyCap:       p.DistinctKeyCap,
		BuyerRequestFloor:    p.BuyerRequestFloor,
		PrincipalCapPct:      p.PrincipalCapPct,
		PrincipalCapRequests: p.PrincipalCapRequests(),
		KAnonymityMin:        KAnonymityMin,
		WindowMaxDays:        WindowMaxDays,
	}
}

func (w *window) wire(end *time.Time, reason string) Window {
	out := Window{
		WindowID:            w.id,
		WindowStart:         w.start.UTC().Format(time.RFC3339),
		Parameters:          w.params.wire(),
		EligibilityPolicyID: w.policyID,
		Buckets:             []Bucket{},
		OtherSuppressed:     w.other,
	}
	if end != nil {
		s := end.UTC().Format(time.RFC3339)
		out.WindowEnd = &s
	}
	_ = reason
	floor := uint64(w.params.BuyerRequestFloor)
	for _, e := range w.entries {
		// SPEC-017 §5.2b.4: a bucket is emitted only when at least
		// KAnonymityMin DISTINCT principals contributed AND its lower bound
		// clears the window's buyer_request_floor; otherwise it is only
		// counted.
		if len(e.principals) < KAnonymityMin || e.count-e.err < floor {
			out.SuppressedBucketCount++
			continue
		}
		out.Buckets = append(out.Buckets, Bucket{ModelKey: e.key, LowerBound: e.count - e.err, Count: e.count, Error: e.err})
	}
	sortBuckets(out.Buckets)
	return out
}

func sortBuckets(b []Bucket) {
	sort.SliceStable(b, func(i, j int) bool {
		if b[i].LowerBound != b[j].LowerBound {
			return b[i].LowerBound > b[j].LowerBound
		}
		return b[i].ModelKey < b[j].ModelKey
	})
}

func cloneWindow(w Window) Window {
	out := w
	out.Buckets = append([]Bucket{}, w.Buckets...)
	if w.WindowEnd != nil {
		s := *w.WindowEnd
		out.WindowEnd = &s
	}
	return out
}

// selectVictim implements the deterministic SPEC-023 §16.2(a) item 4 rule:
// smallest count, then largest error, then smallest key by UTF-8 bytes.
func selectVictim(entries []*entry) *entry {
	var victim *entry
	for _, e := range entries {
		switch {
		case victim == nil,
			e.count < victim.count,
			e.count == victim.count && e.err > victim.err,
			e.count == victim.count && e.err == victim.err && e.key < victim.key:
			victim = e
		}
	}
	return victim
}

func (o *OtherSuppressed) addRequests(n uint64) {
	if o.RequestCountSaturated {
		return
	}
	if n >= requestCountSaturation-o.RequestCount {
		o.RequestCount = requestCountSaturation
		o.RequestCountSaturated = true
		return
	}
	o.RequestCount += n
}

func (o *OtherSuppressed) addDistinct(n uint64, distinctCap int) {
	if o.DistinctKeyCountSaturated {
		return
	}
	capValue := uint64(distinctCap)
	if n >= capValue-o.DistinctKeyCount {
		o.DistinctKeyCount = capValue
		o.DistinctKeyCountSaturated = true
		return
	}
	o.DistinctKeyCount += n
}

// keyEligible applies the closed grammar `[a-z0-9._/-]{1,128}` to the
// normalized key's bytes (SPEC-023 §16.2(a) item 3).
func keyEligible(key string) bool {
	if len(key) == 0 || len(key) > maxKeyBytes {
		return false
	}
	for i := 0; i < len(key); i++ {
		c := key[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '.', c == '_', c == '/', c == '-':
		default:
			return false
		}
	}
	return true
}

func principalToken(key *[windowKeyBytes]byte, accountID string) [principalTokenBytes]byte {
	mac := hmac.New(sha256.New, key[:])
	mac.Write([]byte(principalTokenLabel))
	mac.Write([]byte(accountID))
	sum := mac.Sum(nil)
	var token [principalTokenBytes]byte
	copy(token[:], sum[:principalTokenBytes])
	return token
}
