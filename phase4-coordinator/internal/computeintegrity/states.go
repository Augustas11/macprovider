package computeintegrity

// This file defines the closed enums SPEC-036 is specified over. Every set here
// is closed: an unknown value MUST fail closed (map to compute_integrity_unreadable
// at settlement), never be silently accepted.

// Mode is the SPEC-036 compute_integrity_settlement policy mode (FR-1).
type Mode string

const (
	// ModeObserve computes verdicts and emits audit events but never changes money
	// outcomes, even for provider-attributable adverse state (FR-1). Default.
	ModeObserve Mode = "observe"
	// ModeWarnOnly computes verdicts; new verdicts/clean keys have no money effect,
	// but enforce-origin provider-attributable overlays and active breaker holds
	// preserved from enforce still deny billable routing (§3 exception, FR-3 matrix).
	ModeWarnOnly Mode = "warn_only"
	// ModeEnforce is the maintainer-gated settlement-bearing mode (FR-1 activation
	// preconditions). Not reachable at current beta supply (§6.1).
	ModeEnforce Mode = "enforce"
)

// Known reports whether m is a member of the closed mode enum. An unknown/missing
// captured mode fails closed at settlement (FR-3).
func (m Mode) Known() bool {
	return m == ModeObserve || m == ModeWarnOnly || m == ModeEnforce
}

// State is the compute-integrity measurement/overlay state enum (FR-10). Positive
// states (unknown/pending/verified/warn/expired) live on the window key; adverse
// states (quarantined_compute_drift/blocked:*) live on the overlay key.
type State string

const (
	StateUnknown             State = "unknown"
	StatePending             State = "pending"
	StateVerified            State = "verified"
	StateWarn                State = "warn"
	StateQuarantinedDrift    State = "quarantined_compute_drift"
	StateBlockedRefMissing   State = "blocked:reference_missing"
	StateBlockedCalibMissing State = "blocked:calibration_missing"
	StateBlockedAbusive      State = "blocked:abusive_inconclusive"
	StateBlockedRefFault     State = "blocked:reference_fault"
	StateBlockedManualReview State = "blocked:manual_review_required"
	StateBlockedSwapLaunder  State = "blocked:swap_laundering_suspected"
	StateExpired             State = "expired"
)

// IsBlocked reports whether s is a blocked:<reason> state.
func (s State) IsBlocked() bool {
	switch s {
	case StateBlockedRefMissing, StateBlockedCalibMissing, StateBlockedAbusive,
		StateBlockedRefFault, StateBlockedManualReview, StateBlockedSwapLaunder:
		return true
	}
	return false
}

// IsAdverseOverlay reports whether s is an overlay-owned adverse state
// (quarantine or any block) as opposed to a positive window state.
func (s State) IsAdverseOverlay() bool {
	return s == StateQuarantinedDrift || s.IsBlocked()
}

// IsProviderAttributable reports whether an adverse state is attributable to the
// provider (as opposed to a coordinator-side condition). Provider-attributable
// adverse states survive an enforce->warn_only downgrade as active
// (§3 Preserved-adverse-state exception, FR-3 matrix); coordinator-attributable
// blocks go dormant for routing during the downgrade.
func (s State) IsProviderAttributable() bool {
	switch s {
	case StateQuarantinedDrift, StateBlockedAbusive, StateBlockedManualReview,
		StateBlockedSwapLaunder:
		return true
	}
	// blocked:reference_missing / calibration_missing / reference_fault are
	// coordinator-attributable.
	return false
}

// ExpiryCause is the closed enum of reasons a positive state expired (FR-3, FR-10).
type ExpiryCause string

const (
	ExpiryReferenceStale       ExpiryCause = "reference_stale"
	ExpiryThresholdStale       ExpiryCause = "threshold_stale"
	ExpiryWindowTTLExpired     ExpiryCause = "window_ttl_expired"
	ExpiryTargetGenerationChg  ExpiryCause = "target_generation_changed"
	ExpiryTokenizerChanged     ExpiryCause = "tokenizer_changed"
	ExpirySamplerStageChanged  ExpiryCause = "sampler_stage_changed"
	ExpiryCorpusChanged        ExpiryCause = "corpus_changed"
	ExpiryCatalogChanged       ExpiryCause = "catalog_changed"
	ExpirySamplingProfileUncov ExpiryCause = "sampling_profile_uncovered"
	ExpiryHardwareClassChanged ExpiryCause = "hardware_class_changed"
	ExpiryStateUnreadable      ExpiryCause = "state_unreadable"
)

var knownExpiryCauses = map[ExpiryCause]bool{
	ExpiryReferenceStale: true, ExpiryThresholdStale: true, ExpiryWindowTTLExpired: true,
	ExpiryTargetGenerationChg: true, ExpiryTokenizerChanged: true, ExpirySamplerStageChanged: true,
	ExpiryCorpusChanged: true, ExpiryCatalogChanged: true, ExpirySamplingProfileUncov: true,
	ExpiryHardwareClassChanged: true, ExpiryStateUnreadable: true,
}

// Known reports whether c is a member of the closed expiry_cause enum. Unknown
// causes MUST be rejected before settlement or fail closed as unreadable (FR-3).
func (c ExpiryCause) Known() bool { return knownExpiryCauses[c] }

// AdmissibilityStatus is the reference-set admissibility status (FR-4, FR-5).
// Only Admissible can support a payable verified/warn row.
type AdmissibilityStatus string

const (
	AdmissibilityAdmissible     AdmissibilityStatus = "admissible"
	AdmissibilityMissingQuorum  AdmissibilityStatus = "missing_quorum"
	AdmissibilityReferenceFault AdmissibilityStatus = "reference_fault"
	AdmissibilityStaleReference AdmissibilityStatus = "stale_reference"
	AdmissibilityIndepFailed    AdmissibilityStatus = "independence_failed"
	AdmissibilityProvMissing    AdmissibilityStatus = "provenance_missing"
	AdmissibilitySchemaInvalid  AdmissibilityStatus = "schema_invalid"
)

var knownAdmissibility = map[AdmissibilityStatus]bool{
	AdmissibilityAdmissible: true, AdmissibilityMissingQuorum: true, AdmissibilityReferenceFault: true,
	AdmissibilityStaleReference: true, AdmissibilityIndepFailed: true, AdmissibilityProvMissing: true,
	AdmissibilitySchemaInvalid: true,
}

// Known reports whether a is a member of the closed admissibility enum. Unknown
// values MUST fail closed (FR-4).
func (a AdmissibilityStatus) Known() bool { return knownAdmissibility[a] }

// AdjudicationOrigin records the mode conjunction under which an adverse overlay or
// breaker hold was adjudicated (FR-3). It is set at state creation, is immutable,
// and is inherited by any derived successor state.
type AdjudicationOrigin string

const (
	// OriginEnforcePreserved: adjudicated while SPEC-036 was enforce AND the SPEC-022
	// conjunction was true. Its money/routing effect is preserved across a
	// SPEC-036-only downgrade (FR-3 matrix rows 1-2).
	OriginEnforcePreserved AdjudicationOrigin = "enforce_preserved"
	// OriginTelemetryOnly: computed under observe/warn_only or where SPEC-022 was not
	// enforcing. NEVER has a money/routing effect.
	OriginTelemetryOnly AdjudicationOrigin = "telemetry_only"
)

// CircuitBreakerScope is the closed scope enum for an active circuit-breaker hold
// (FR-4, FR-16). Present exactly when circuit_breaker_active is true.
type CircuitBreakerScope string

const (
	BreakerScopeKey    CircuitBreakerScope = "key"
	BreakerScopeModel  CircuitBreakerScope = "model"
	BreakerScopePolicy CircuitBreakerScope = "policy"
)

var knownBreakerScopes = map[CircuitBreakerScope]bool{
	BreakerScopeKey: true, BreakerScopeModel: true, BreakerScopePolicy: true,
}

// Known reports whether sc is a member of the closed breaker-scope enum.
func (sc CircuitBreakerScope) Known() bool { return knownBreakerScopes[sc] }

// Verdict is the single-canary verdict the coordinator assigns (FR-9).
type Verdict string

const (
	VerdictPass                Verdict = "pass"
	VerdictWarn                Verdict = "warn"
	VerdictQuarantineCandidate Verdict = "quarantine_candidate"
	VerdictInconclusive        Verdict = "inconclusive"
)

// SamplingProfileCoverageMode selects per-profile vs all-profile windows (FR-1, FR-10).
type SamplingProfileCoverageMode string

const (
	CoveragePerProfile SamplingProfileCoverageMode = "per_profile"
	CoverageAllProfile SamplingProfileCoverageMode = "all_profile"
)

// AllProfilesWindowProfile is the reserved sampling_profile marker for an
// all-profile (closed profile grid) window (FR-10).
const AllProfilesWindowProfile = "__all_profiles__"
