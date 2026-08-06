package computeintegrity

// FR-16 operator controls: the circuit breaker and manual review. The breaker fails
// closed for affected scopes when new quarantined_compute_drift or
// blocked:reference_fault transitions meet or exceed (>=) the configured model- or
// fleet-level thresholds in a rolling window. It denies NEW covered paid admissions
// for the affected scope; it never retroactively reclassifies an already-admitted row
// (settlement immutability). The enforce->warn_only rollback is a mode flip handled by
// Evaluate (a captured row keeps its captured outcome); the preserved-adverse-state
// exception is enforced by the FR-3 matrix.

// BreakerState is the closed circuit-breaker state (FR-16).
type BreakerState string

const (
	BreakerInactive      BreakerState = "inactive"
	BreakerActive        BreakerState = "active"
	BreakerOverrideRoute BreakerState = "override_routing_only"
	BreakerCleared       BreakerState = "cleared"
)

// BreakerTransitionKind is the in-scope transition set (fixed, FR-1/FR-16).
type BreakerTransitionKind string

const (
	TransitionDrift          BreakerTransitionKind = "quarantined_compute_drift"
	TransitionReferenceFault BreakerTransitionKind = "blocked:reference_fault"
)

// BreakerTransition is one in-scope transition, deduplicated per covered key (FR-1).
type BreakerTransition struct {
	OverlayKey OverlayKey
	ModelID    string
	Kind       BreakerTransitionKind
	AtMs       int64
}

// EvaluateBreaker computes the circuit-breaker activation from the in-scope
// transitions within the rolling window (FR-1, FR-16). Scope precedence is
// whole-policy > model > key: a fleet-threshold breach activates the whole-policy
// breaker; otherwise a model-threshold breach activates that model's breaker.
// Boundaries are inclusive (>=). Returns the state and the activated scope.
func EvaluateBreaker(transitions []BreakerTransition, cb CircuitBreakerPolicy, nowMs int64) (BreakerState, CircuitBreakerScope) {
	windowMs := int64(cb.RollingWindowMinutes) * 60 * 1000
	// Deduplicate per covered key (a repeated transition on one key counts once).
	fleetKeys := map[OverlayKey]struct{}{}
	perModelKeys := map[string]map[OverlayKey]struct{}{}
	for _, tr := range transitions {
		if tr.Kind != TransitionDrift && tr.Kind != TransitionReferenceFault {
			continue
		}
		if windowMs > 0 && nowMs-tr.AtMs > windowMs {
			continue
		}
		fleetKeys[tr.OverlayKey] = struct{}{}
		if perModelKeys[tr.ModelID] == nil {
			perModelKeys[tr.ModelID] = map[OverlayKey]struct{}{}
		}
		perModelKeys[tr.ModelID][tr.OverlayKey] = struct{}{}
	}
	if len(fleetKeys) >= cb.FleetScopeThreshold {
		return BreakerActive, BreakerScopePolicy
	}
	for _, keys := range perModelKeys {
		if len(keys) >= cb.ModelScopeThreshold {
			return BreakerActive, BreakerScopeModel
		}
	}
	return BreakerInactive, ""
}

// BreakerClearInput carries the FR-16 circuit-breaker clear requirements.
type BreakerClearInput struct {
	QuietWindowSatisfied    bool // no new in-scope transitions for the quiet window
	FreshReferenceAdmission bool // fresh reference admissibility for every affected key
	DualApproved            bool // dual-approved manual review of the breaker evidence bundle
	AuditRowRecorded        bool // previous/new state, scope, bounds, digests, approvers
}

// CanClearBreaker reports whether all FR-16 breaker-clear requirements are met.
func CanClearBreaker(in BreakerClearInput) bool {
	return in.QuietWindowSatisfied && in.FreshReferenceAdmission && in.DualApproved && in.AuditRowRecorded
}

// OverrideAdmitsBillable reports whether an override_routing_only admits billable
// buyer traffic (FR-16). It never does: an override may open only operator-funded,
// non-buyer probe/reference/diagnostic traffic and MUST NOT make a held settlement
// payable.
func OverrideAdmitsBillable(_ BreakerState) bool { return false }

// ManualReviewDecision records a dual-approved manual-review decision (FR-16). The two
// approvers must be distinct and non-empty for the decision to be valid.
type ManualReviewDecision struct {
	ApproverA      string
	ApproverB      string
	Decision       string // "clear" | "block"
	Rationale      string
	EvidenceDigest string
}

// Valid reports whether a manual-review decision satisfies the dual-approval
// requirement (FR-16).
func (d ManualReviewDecision) Valid() bool {
	return d.ApproverA != "" && d.ApproverB != "" && d.ApproverA != d.ApproverB &&
		(d.Decision == "clear" || d.Decision == "block") && d.EvidenceDigest != ""
}
