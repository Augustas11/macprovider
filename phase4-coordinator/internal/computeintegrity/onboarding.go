package computeintegrity

// FR-11 onboarding gate. SPEC-036 never blocks the SPEC-026 local App onboarding flow
// before identity registration. After registration and before covered paid routing,
// each new onboarding key must pass the compute-integrity onboarding gate when policy
// mode is enforce; warn_only computes readiness telemetry only for clean keys.

// OnboardingStatus is the provider-facing onboarding status (FR-11).
type OnboardingStatus string

const (
	OnboardingPending  OnboardingStatus = "compute_integrity_onboarding_pending"
	OnboardingFailed   OnboardingStatus = "compute_integrity_onboarding_failed"
	OnboardingVerified OnboardingStatus = "compute_integrity_onboarding_verified"
)

// OnboardingGateResult is the result of evaluating the onboarding gate.
type OnboardingGateResult struct {
	Status OnboardingStatus
	// InheritedOverlay is set (non-"") when the gate did not run because the overlay
	// carries an active quarantine/block; the key inherits that state (FR-11). The
	// onboarding gate is never a path to bypass an active overlay quarantine.
	InheritedOverlay State
}

// onboardingMinPasses and onboardingMinElapsedMs are the default FR-11 gate: 5 pass
// canaries with at least 30 minutes between the first and final pass.
const (
	onboardingMinPasses    = 5
	onboardingMinElapsedMs = int64(30 * 60 * 1000)
)

// EvaluateOnboarding evaluates the FR-11 onboarding gate for a key. It consults the
// swap-laundering overlay and the per-key overlay FIRST: an active quarantine/block
// means the gate does not run and the key inherits the overlay state. In warn_only the
// gate produces telemetry only and never blocks covered paid routing (the caller must
// not gate routing on a warn_only result), but an inherited enforce-origin
// provider-attributable overlay still excludes the key regardless of mode.
//
// passes are the onboarding canary verdict timestamps observed so far (only pass
// canaries advance the gate).
func (s *Store) EvaluateOnboarding(key ComputeIntegrityKey, mode Mode, spec022Enforce bool, passTimestampsMs []int64) OnboardingGateResult {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Overlay inheritance is checked before the gate runs (FR-11, FR-12), but ONLY for
	// an overlay whose effect is ACTIVE per the FR-3 matrix: a dormant telemetry-only
	// overlay never blocks onboarding.
	if sw := s.swaps[key.Overlay().SwapLaunderingScope()]; sw != nil && sw.blocked &&
		EffectiveAdverseState(mode, spec022Enforce, sw.origin, attribProviderOrBreaker) {
		return OnboardingGateResult{Status: OnboardingFailed, InheritedOverlay: StateBlockedSwapLaunder}
	}
	if ov := s.overlays[key.Overlay()]; ov != nil && ov.state.IsAdverseOverlay() {
		attrib := attribCoordinator
		if ov.state.IsProviderAttributable() {
			attrib = attribProviderOrBreaker
		}
		if EffectiveAdverseState(mode, spec022Enforce, ov.origin, attrib) {
			return OnboardingGateResult{Status: OnboardingFailed, InheritedOverlay: ov.state}
		}
	}
	// An unresolved lineage tombstone means the short onboarding gate cannot restore
	// eligibility (FR-10/FR-12).
	if s.tombstones[key.Overlay().TombstoneScope()] {
		return OnboardingGateResult{Status: OnboardingFailed, InheritedOverlay: StateBlockedManualReview}
	}

	if len(passTimestampsMs) < onboardingMinPasses {
		return OnboardingGateResult{Status: OnboardingPending}
	}
	first := passTimestampsMs[0]
	last := passTimestampsMs[len(passTimestampsMs)-1]
	for _, t := range passTimestampsMs {
		if t < first {
			first = t
		}
		if t > last {
			last = t
		}
	}
	if last-first < onboardingMinElapsedMs {
		return OnboardingGateResult{Status: OnboardingPending}
	}
	return OnboardingGateResult{Status: OnboardingVerified}
}

// OnboardingBlocksRouting reports whether an onboarding result blocks covered paid
// routing for the given mode (FR-11). InheritedOverlay is set by EvaluateOnboarding
// only when the overlay's effect is ACTIVE per the FR-3 matrix (so it already encodes
// the §3 Preserved-adverse-state exception), and it blocks regardless of mode. Absent
// an active overlay, enforce blocks a non-verified gate; warn_only/observe never block
// clean onboarding keys.
func OnboardingBlocksRouting(mode Mode, r OnboardingGateResult) bool {
	if r.InheritedOverlay.IsAdverseOverlay() {
		return true
	}
	if mode != ModeEnforce {
		return false
	}
	return r.Status != OnboardingVerified
}
