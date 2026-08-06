package computeintegrity

import (
	"fmt"
	"sort"
)

// Policy is the single authoritative compute_integrity_settlement policy surface
// (FR-1). It carries the covered key dimensions, the window/threshold parameters,
// the circuit-breaker policy, and the optional flapping policy. Defaults follow
// FR-1; NewDefaultPolicy applies them.
type Policy struct {
	PolicyVersion string
	Mode          Mode
	EnabledAt     int64

	// Coverage.
	ModelIDs                   []string
	TargetModelHash            string
	SignedCatalogSelector      string
	TokenizerIdentity          string
	SamplerStage               string
	NormalizationBasis         string
	Entrypoints                []string
	SamplingProfiles           []string
	CoverageMode               SamplingProfileCoverageMode
	ReferenceSourceMode        string // "trusted_reference" or "hybrid"
	ReferenceFaultCheckVersion string
	HardwareRuntimeClass       string
	CorpusVersion              string
	ThresholdVersion           string

	// Window / verdict parameters.
	MaxActiveReferences          int
	WindowSizeDays               int
	PositiveStateFreshnessTTLHrs int
	MinWindowCanaries            int
	QuarantineCandidateCount     int
	ClearPassCount               int
	ReferenceFreshnessTTLHours   int
	AbusiveInconclusiveLimit     int // events in 24h; the limit is "more than" this
	CanaryCadenceMinutes         int // scheduled per-key cadence, for the TTL>=2x cadence gate

	// Disclosure.
	DisclosureCopyVersion string
	DisclosureCopyDigest  string

	// Optional automatic mode downgrade on total reference-fleet outage (FR-1).
	ReferenceUnavailableAutoDowngrade bool
	AutoDowngradeMaxMinutes           int

	CircuitBreaker CircuitBreakerPolicy
	FlappingPolicy FlappingWindowPolicy

	// StableIdentityAuthorityNamed records that a maintainer-approved
	// stable-device/operator-identity authority has been named (FR-1 Sybil
	// precondition). Enforce is categorically unavailable until true (§6.1).
	StableIdentityAuthorityNamed bool
	// ApprovedCostModel records the maintainer-approved FR-17 cost model.
	ApprovedCostModel bool
}

// CircuitBreakerPolicy is the closed deterministic circuit-breaker activation object
// (FR-1). Boundaries are inclusive (>=).
type CircuitBreakerPolicy struct {
	RollingWindowMinutes int
	EventTimeBasis       string // fixed: "transition_recorded_at"
	ModelScopeThreshold  int
	FleetScopeThreshold  int
	QuietWindowMinutes   int
}

// FlappingWindowPolicy is disabled by default (FR-1). When enabled, all fields are
// required.
type FlappingWindowPolicy struct {
	Enabled                     bool
	LookbackWindowDays          int
	Metric                      string // median_tv_lower_margin_to_quarantine | max_position_tv_lower_margin_to_quarantine
	ThresholdMargin             float64
	MinPassCount                int
	MinWarnCount                int
	MinQuarantineCandidateCount int
	Action                      string // blocked:manual_review_required | none
	ClearRule                   string // dual_approval | clear_pass_count_sequence
}

const (
	referenceSourceTrusted = "trusted_reference"
	referenceSourceHybrid  = "hybrid"

	flappingMetricMedian   = "median_tv_lower_margin_to_quarantine"
	flappingMetricPosition = "max_position_tv_lower_margin_to_quarantine"

	flappingActionManualReview = "blocked:manual_review_required"
	flappingActionNone         = "none"

	flappingClearDualApproval = "dual_approval"
	flappingClearPassSequence = "clear_pass_count_sequence"

	eventTimeBasisTransitionRecorded = "transition_recorded_at"

	// v0.1 sampler stage with a defined provider-side capture + normalization basis.
	SamplerStagePostSampler = "post_processors_post_sampling_profile_next_emitted_token"
	NormalizationFullDist   = "full_distribution"
)

// NewDefaultPolicy returns a policy pre-populated with the FR-1 defaults, in observe
// mode (the safe, always-reachable default).
func NewDefaultPolicy() Policy {
	return Policy{
		Mode:                         ModeObserve,
		CoverageMode:                 CoveragePerProfile,
		ReferenceSourceMode:          referenceSourceTrusted,
		NormalizationBasis:           NormalizationFullDist,
		MaxActiveReferences:          2,
		WindowSizeDays:               7,
		PositiveStateFreshnessTTLHrs: 24,
		MinWindowCanaries:            5,
		QuarantineCandidateCount:     3,
		ClearPassCount:               5,
		ReferenceFreshnessTTLHours:   24,
		AbusiveInconclusiveLimit:     3,
		CanaryCadenceMinutes:         360,
		CircuitBreaker: CircuitBreakerPolicy{
			RollingWindowMinutes: 60,
			EventTimeBasis:       eventTimeBasisTransitionRecorded,
			ModelScopeThreshold:  3,
			FleetScopeThreshold:  5,
			QuietWindowMinutes:   120,
		},
	}
}

// Validate checks the structural invariants of a policy that hold in every mode
// (FR-1). Enforce-only preconditions are checked by ActivationCheck, not here.
func (p Policy) Validate() error {
	switch p.Mode {
	case ModeObserve, ModeWarnOnly, ModeEnforce:
	default:
		return fmt.Errorf("invalid mode %q", p.Mode)
	}
	switch p.CoverageMode {
	case CoveragePerProfile, CoverageAllProfile:
	default:
		return fmt.Errorf("invalid sampling-profile coverage mode %q", p.CoverageMode)
	}
	switch p.ReferenceSourceMode {
	case referenceSourceTrusted, referenceSourceHybrid:
	default:
		return fmt.Errorf("invalid reference source mode %q", p.ReferenceSourceMode)
	}
	if p.MaxActiveReferences < 2 || p.MaxActiveReferences > 4 {
		return fmt.Errorf("max_active_references must be in [2,4], got %d", p.MaxActiveReferences)
	}
	if p.WindowSizeDays <= 0 {
		return fmt.Errorf("window_size_days must be positive")
	}
	if p.PositiveStateFreshnessTTLHrs <= 0 {
		return fmt.Errorf("positive_state_freshness_ttl_hours must be positive")
	}
	if p.MinWindowCanaries <= 0 {
		return fmt.Errorf("min_window_canaries must be positive")
	}
	if p.QuarantineCandidateCount <= 0 || p.QuarantineCandidateCount > p.MinWindowCanaries {
		return fmt.Errorf("quarantine_candidate_count must be in [1, min_window_canaries]")
	}
	if p.ClearPassCount <= 0 {
		return fmt.Errorf("clear_pass_count must be positive")
	}
	if err := p.CircuitBreaker.validate(); err != nil {
		return err
	}
	if err := p.FlappingPolicy.validate(); err != nil {
		return err
	}
	return nil
}

func (cb CircuitBreakerPolicy) validate() error {
	if cb.RollingWindowMinutes <= 0 {
		return fmt.Errorf("circuit_breaker rolling_window_minutes must be positive")
	}
	if cb.EventTimeBasis != eventTimeBasisTransitionRecorded {
		return fmt.Errorf("circuit_breaker event_time_basis must be %q", eventTimeBasisTransitionRecorded)
	}
	if cb.ModelScopeThreshold <= 0 || cb.FleetScopeThreshold <= 0 {
		return fmt.Errorf("circuit_breaker scope thresholds must be positive")
	}
	if cb.QuietWindowMinutes <= 0 {
		return fmt.Errorf("circuit_breaker quiet_window_minutes must be positive")
	}
	return nil
}

func (fp FlappingWindowPolicy) validate() error {
	if !fp.Enabled {
		return nil // disabled by default; fields ignored.
	}
	if fp.LookbackWindowDays <= 0 {
		return fmt.Errorf("flapping lookback_window_days must be positive")
	}
	switch fp.Metric {
	case flappingMetricMedian, flappingMetricPosition:
	default:
		return fmt.Errorf("invalid flapping metric %q", fp.Metric)
	}
	if fp.ThresholdMargin < 0 {
		return fmt.Errorf("flapping threshold_margin must be non-negative")
	}
	if fp.MinPassCount < 0 || fp.MinWarnCount < 0 || fp.MinQuarantineCandidateCount < 0 {
		return fmt.Errorf("flapping min counts must be non-negative")
	}
	switch fp.Action {
	case flappingActionManualReview, flappingActionNone:
	default:
		return fmt.Errorf("invalid flapping action %q", fp.Action)
	}
	switch fp.ClearRule {
	case flappingClearDualApproval, flappingClearPassSequence:
	default:
		return fmt.Errorf("invalid flapping clear_rule %q", fp.ClearRule)
	}
	return nil
}

// Digest returns the JCS SHA-256 digest of the policy object (FR-4
// compute_integrity_policy_digest), so the exact money rule in force at request
// start is provable. Slice fields are sorted for a canonical representation.
func (p Policy) Digest() (string, error) {
	models := append([]string(nil), p.ModelIDs...)
	sort.Strings(models)
	entrypoints := append([]string(nil), p.Entrypoints...)
	sort.Strings(entrypoints)
	profiles := append([]string(nil), p.SamplingProfiles...)
	sort.Strings(profiles)

	obj := map[string]any{
		"policy_version":                     p.PolicyVersion,
		"mode":                               string(p.Mode),
		"model_ids":                          toAnySlice(models),
		"target_model_hash":                  p.TargetModelHash,
		"signed_catalog_selector":            p.SignedCatalogSelector,
		"tokenizer_identity":                 p.TokenizerIdentity,
		"sampler_stage":                      p.SamplerStage,
		"normalization_basis":                p.NormalizationBasis,
		"entrypoints":                        toAnySlice(entrypoints),
		"sampling_profiles":                  toAnySlice(profiles),
		"coverage_mode":                      string(p.CoverageMode),
		"reference_source_mode":              p.ReferenceSourceMode,
		"reference_fault_check_version":      p.ReferenceFaultCheckVersion,
		"hardware_runtime_class":             p.HardwareRuntimeClass,
		"corpus_version":                     p.CorpusVersion,
		"threshold_version":                  p.ThresholdVersion,
		"max_active_references":              p.MaxActiveReferences,
		"window_size_days":                   p.WindowSizeDays,
		"positive_state_freshness_ttl_hours": p.PositiveStateFreshnessTTLHrs,
		"min_window_canaries":                p.MinWindowCanaries,
		"quarantine_candidate_count":         p.QuarantineCandidateCount,
		"clear_pass_count":                   p.ClearPassCount,
		"reference_freshness_ttl_hours":      p.ReferenceFreshnessTTLHours,
		"abusive_inconclusive_limit":         p.AbusiveInconclusiveLimit,
		"disclosure_copy_version":            p.DisclosureCopyVersion,
		"disclosure_copy_digest":             p.DisclosureCopyDigest,
	}
	return jcsDigest(obj)
}

func toAnySlice(ss []string) []any {
	out := make([]any, len(ss))
	for i, s := range ss {
		out[i] = s
	}
	return out
}
