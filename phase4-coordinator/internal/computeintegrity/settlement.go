package computeintegrity

// This file implements the SPEC-036 money-path core (FR-3):
//
//   - the effective_adverse_state matrix (mode x SPEC-022 enforce x origin x
//     attribution) that decides whether an adverse state has a money/routing effect;
//   - the closed 15-member settlement-reason enum;
//   - the total reason-precedence resolution over a captured request-start state; and
//   - the AND-gate composition of the SPEC-036 decision onto the SPEC-022 outcome.
//
// SPEC-036 holds no independent money authority. It is a strictly subordinate
// AND-gate: it can only ever narrow SPEC-022 creditability, never relax a
// non-creditable SPEC-022 outcome and never promote a row to payable.

// SPEC-022 settlement outcome string values. These mirror the canonical enum in
// internal/billing/settlement_verifier.go (SettlementOutcome{Verified,Quarantined,
// ZeroSettled,Pending}); they are restated here as constants so this leaf package
// does not import the billing money-DB package (avoiding an import cycle when the
// gate is later wired back into settlement). The AND-gate composition below only
// ever emits Quarantined or passes a SPEC-022 outcome through unchanged.
const (
	OutcomeVerified    = "verified"
	OutcomeQuarantined = "quarantined"
	OutcomeZeroSettled = "zero_settled"
	OutcomePending     = "pending"
)

// SettlementReason is the closed v0.1 compute-integrity settlement reason enum
// (FR-3). Implementations MUST NOT emit ad hoc reason strings for covered paid
// settlement; every enforce-mode non-payable condition maps to exactly one member.
type SettlementReason string

const (
	ReasonDriftQuarantined      SettlementReason = "compute_drift_quarantined"
	ReasonUnknown               SettlementReason = "compute_integrity_unknown"
	ReasonPendingDeadline       SettlementReason = "compute_integrity_pending_deadline"
	ReasonExpired               SettlementReason = "compute_integrity_expired"
	ReasonReferenceStale        SettlementReason = "compute_integrity_reference_stale"
	ReasonThresholdStale        SettlementReason = "compute_integrity_threshold_stale"
	ReasonUnreadable            SettlementReason = "compute_integrity_unreadable"
	ReasonUncoveredProfile      SettlementReason = "compute_integrity_uncovered_profile"
	ReasonReferenceMissing      SettlementReason = "compute_integrity_reference_missing"
	ReasonCalibrationMissing    SettlementReason = "compute_integrity_calibration_missing"
	ReasonCircuitBreakerHold    SettlementReason = "compute_integrity_circuit_breaker_hold"
	ReasonBlockedAbusive        SettlementReason = "compute_integrity_blocked_abusive_inconclusive"
	ReasonBlockedReferenceFault SettlementReason = "compute_integrity_blocked_reference_fault"
	ReasonBlockedManualReview   SettlementReason = "compute_integrity_blocked_manual_review_required"
	ReasonBlockedSwapLaundering SettlementReason = "compute_integrity_blocked_swap_laundering_suspected"
)

var validSettlementReasons = map[SettlementReason]bool{
	ReasonDriftQuarantined: true, ReasonUnknown: true, ReasonPendingDeadline: true,
	ReasonExpired: true, ReasonReferenceStale: true, ReasonThresholdStale: true,
	ReasonUnreadable: true, ReasonUncoveredProfile: true, ReasonReferenceMissing: true,
	ReasonCalibrationMissing: true, ReasonCircuitBreakerHold: true, ReasonBlockedAbusive: true,
	ReasonBlockedReferenceFault: true, ReasonBlockedManualReview: true, ReasonBlockedSwapLaundering: true,
}

// ValidSettlementReason reports whether r is a member of the closed v0.1 enum.
func ValidSettlementReason(r SettlementReason) bool { return validSettlementReasons[r] }

// attribution classifies which matrix column an adverse element falls in.
type attribution int

const (
	attribProviderOrBreaker attribution = iota
	attribCoordinator
)

// EffectiveAdverseState is the single normative FR-3 predicate: given the captured
// runtime mode, whether SPEC-022 was enforcing, the adverse state's immutable
// adjudication origin, and its attribution, it reports whether the adverse state's
// money/routing EFFECT is active (deny billable covered routing + non-payable
// settlement) or dormant. All downstream consumers (FR-3 settlement, FR-10 state
// resolution, FR-11 onboarding, FR-16 routing, Migration) gate on this predicate.
//
// The total truth table (FR-3):
//
//	mode                         SPEC-022   provider/breaker(EP)  coordinator(EP)  telemetry_only
//	enforce                      enforce    active                active           dormant
//	warn_only/observe            enforce    active                dormant          dormant
//	any                          not-enf.   dormant               dormant          dormant
func EffectiveAdverseState(mode Mode, spec022Enforce bool, origin AdjudicationOrigin, attrib attribution) bool {
	if !spec022Enforce {
		return false // SPEC-036 has no independent money authority; SPEC-022 alone governs.
	}
	if origin != OriginEnforcePreserved {
		return false // telemetry_only never has a money/routing effect.
	}
	if mode == ModeEnforce {
		return true // row 1: both provider/breaker and coordinator blocks are active.
	}
	// row 2 (SPEC-036-only downgrade, SPEC-022 still enforce): provider-attributable
	// and breaker holds are preserved-active; coordinator-attributable go dormant.
	return attrib == attribProviderOrBreaker
}

// Decision is the SPEC-036 gate's verdict on a captured request-start row.
//
//   - Applies == false: SPEC-036 does not alter the SPEC-022 money outcome (SPEC-022
//     was not enforcing, or the captured state has no active money effect).
//   - Applies == true, Payable == true: SPEC-036 does not block (fresh verified/warn
//     under enforce). Final payability still requires SPEC-022 to be payable.
//   - Applies == true, Payable == false: SPEC-036 blocks. Reason is the single
//     highest-precedence closed reason; the row settles quarantined.
type Decision struct {
	Applies bool
	Payable bool
	Reason  SettlementReason
	// AuditReasons carries every lower-precedence non-payable reason that also held,
	// for the FR-14 audit row (not emitted as the settlement reason).
	AuditReasons []SettlementReason
}

// Evaluate resolves the SPEC-036 gate decision for a captured request-start state
// (FR-3, FR-4). Settlement is a pure function of the immutable capture.
func Evaluate(c Capture) Decision {
	// A missing/unreadable composite SPEC-022 binding fails closed BEFORE the not-enforce
	// early return (FR-4): a malformed capture whose binding is absent must not be paid
	// through as if SPEC-022 were legitimately not enforcing.
	if c.compositeBindingUnreadable() {
		return Decision{Applies: true, Payable: false, Reason: ReasonUnreadable}
	}
	// FR-3: if the captured composite snapshot shows SPEC-022 was not in enforce for
	// the request's coverage, SPEC-036 MUST NOT alter the request's money outcome.
	if !c.Spec022EffectiveEnforce {
		return Decision{Applies: false}
	}

	mode := c.ComputeIntegrityPolicyMode
	// Fail closed on an unreadable/malformed captured mode: with SPEC-022 enforcing, an
	// unknown mode must NOT be treated as non-enforce (which would let a fresh verified
	// row pay through). It settles compute_integrity_unreadable.
	if !mode.Known() {
		return Decision{Applies: true, Payable: false, Reason: ReasonUnreadable}
	}
	// A structurally-unreadable capture (bad enum, inconsistent breaker, adverse state
	// with missing origin) fails closed in EVERY mode when SPEC-022 is enforcing — a
	// corrupt preserved-adverse row must never pass through payable under warn_only.
	if c.structurallyUnreadable() {
		return Decision{Applies: true, Payable: false, Reason: ReasonUnreadable}
	}

	// Non-enforce runtime modes (warn_only, observe — identical behavior): only an
	// enforce_preserved provider-attributable overlay or an enforce_preserved active
	// breaker hold still denies money (the §3 Preserved-adverse-state exception).
	// Clean keys, coordinator-attributable blocks, and telemetry_only states have no
	// money effect, so SPEC-036 does not alter the SPEC-022 outcome.
	if mode != ModeEnforce {
		if c.State.IsAdverseOverlay() {
			attrib := attribCoordinator
			if c.State.IsProviderAttributable() {
				attrib = attribProviderOrBreaker
			}
			if EffectiveAdverseState(mode, true, c.AdjudicationOrigin, attrib) {
				return Decision{Applies: true, Payable: false, Reason: reasonForBlockedState(c.State)}
			}
			return Decision{Applies: false} // dormant overlay: SPEC-022 governs.
		}
		if c.CircuitBreakerActive && c.breakerConsistent() &&
			EffectiveAdverseState(mode, true, c.AdjudicationOrigin, attribProviderOrBreaker) {
			return Decision{Applies: true, Payable: false, Reason: ReasonCircuitBreakerHold}
		}
		return Decision{Applies: false} // clean/positive key under warn_only/observe: no money effect.
	}

	// Enforce runtime mode (row 1): fail closed on every non-payable request-start
	// condition. Resolve the single settlement reason by the FR-3 total precedence.
	reason, audit, payable := enforceReason(c)
	if payable {
		return Decision{Applies: true, Payable: true}
	}
	return Decision{Applies: true, Payable: false, Reason: reason, AuditReasons: audit}
}

// FR-3 precedence tiers (lower = higher precedence). Tier 5 (reference
// admissibility) and tier 6 (calibration/threshold) carry an internal sub-order,
// encoded with adjacent integers. The same reason string can occupy two tiers
// depending on its source: admissibility stale_reference is high-precedence
// (tierRefStaleAdmissibility) while expiry_cause=reference_stale is low
// (tierExpiryGroup) — AC-16 depends on this distinction.
const (
	tierUnreadable            = 10
	tierUncoveredProfile      = 20
	tierSwapLaundering        = 30
	tierManualReview          = 40
	tierRefFault              = 50
	tierRefMissing            = 51
	tierRefStaleAdmissibility = 52
	tierCalibrationMissing    = 60
	tierThresholdStale        = 61
	tierDrift                 = 70
	tierAbusive               = 80
	tierBreaker               = 90
	tierExpiryGroup           = 100 // expired / reference_stale(expiry) / unknown / pending
)

type reasonHit struct {
	tier   int
	reason SettlementReason
}

// enforceReason walks the FR-3 reason-precedence table for an enforce-mode covered
// row and returns the single emitted reason (lowest tier number), the lower-
// precedence reasons that also held (for the FR-14 audit row), and whether the row
// is payable.
func enforceReason(c Capture) (SettlementReason, []SettlementReason, bool) {
	var hits []reasonHit
	add := func(tier int, r SettlementReason) { hits = append(hits, reasonHit{tier, r}) }

	// Tier 1: unreadable — any unreadable/schema-invalid/unverifiable capture,
	// including missing/malformed breaker or admissibility metadata.
	if c.Unreadable || !c.breakerConsistent() || !c.ReferenceSetAdmissibilityStatus.Known() ||
		c.ReferenceSetAdmissibilityStatus == AdmissibilitySchemaInvalid ||
		(c.State == StateExpired && !c.ExpiryCause.Known()) {
		add(tierUnreadable, ReasonUnreadable)
	}

	// Tier 2: uncovered sampling profile (class mismatch or profile not covered).
	if !c.hardwareClassMatches() || !c.RequestSamplingProfileCovered ||
		(c.State == StateExpired && c.ExpiryCause == ExpirySamplingProfileUncov) {
		add(tierUncoveredProfile, ReasonUncoveredProfile)
	}

	// Tiers 3-8: provider-attributable overlay states (active by construction under
	// enforce+enforce_preserved; a telemetry_only overlay is dormant and falls through
	// to the positive-state resolution below).
	if c.State.IsAdverseOverlay() &&
		EffectiveAdverseState(ModeEnforce, true, c.AdjudicationOrigin, overlayAttribution(c.State)) {
		switch c.State {
		case StateBlockedSwapLaunder:
			add(tierSwapLaundering, ReasonBlockedSwapLaundering)
		case StateBlockedManualReview:
			add(tierManualReview, ReasonBlockedManualReview)
		case StateBlockedRefFault:
			add(tierRefFault, ReasonBlockedReferenceFault)
		case StateBlockedRefMissing:
			add(tierRefMissing, ReasonReferenceMissing)
		case StateBlockedCalibMissing:
			add(tierCalibrationMissing, ReasonCalibrationMissing)
		case StateQuarantinedDrift:
			add(tierDrift, ReasonDriftQuarantined)
		case StateBlockedAbusive:
			add(tierAbusive, ReasonBlockedAbusive)
		}
	}

	// Tier 5: reference-set admissibility failures for a covered enforce row.
	switch c.ReferenceSetAdmissibilityStatus {
	case AdmissibilityReferenceFault, AdmissibilityIndepFailed, AdmissibilityProvMissing:
		add(tierRefFault, ReasonBlockedReferenceFault)
	case AdmissibilityMissingQuorum:
		add(tierRefMissing, ReasonReferenceMissing)
	case AdmissibilityStaleReference:
		add(tierRefStaleAdmissibility, ReasonReferenceStale)
	}

	// Tier 9: circuit-breaker hold over an otherwise-payable underlying state.
	if c.CircuitBreakerActive && c.breakerConsistent() {
		add(tierBreaker, ReasonCircuitBreakerHold)
	}

	// Tier 10: expiry / unknown / pending positive-state failures (lowest precedence).
	// Note expiry_cause=reference_stale lands here (tier 100), BELOW drift (tier 70),
	// distinct from admissibility stale_reference at tier 52.
	switch c.State {
	case StateExpired:
		if c.ExpiryCause.Known() {
			add(tierExpiryGroup, expiryReason(c.ExpiryCause))
		}
	case StateUnknown:
		add(tierExpiryGroup, ReasonUnknown)
	case StatePending:
		add(tierExpiryGroup, ReasonPendingDeadline)
	}

	if len(hits) == 0 {
		// Payable only from a fresh verified/warn positive state with no active breaker,
		// admissible references, covered profile, AND complete load-bearing FR-4 evidence
		// (policy/coverage digests, reference set id/digests, covered sampler stage).
		if (c.State == StateVerified || c.State == StateWarn) &&
			c.ReferenceSetAdmissibilityStatus == AdmissibilityAdmissible &&
			!c.CircuitBreakerActive && !c.missingEnforceEvidence() {
			return "", nil, true
		}
		// Defensive: a state we could not classify as payable and produced no reason
		// fails closed as unreadable rather than silently paying.
		return ReasonUnreadable, nil, false
	}

	winner := hits[0]
	for _, h := range hits[1:] {
		if h.tier < winner.tier {
			winner = h
		}
	}
	audit := make([]SettlementReason, 0, len(hits)-1)
	for _, h := range hits {
		if h.tier != winner.tier {
			audit = append(audit, h.reason)
		}
	}
	return winner.reason, audit, false
}

func overlayAttribution(s State) attribution {
	if s.IsProviderAttributable() {
		return attribProviderOrBreaker
	}
	return attribCoordinator
}

// reasonForBlockedState maps an adverse overlay state to its settlement reason
// (used by the warn_only/observe preserved-adverse path, where exactly one adverse
// state is active).
func reasonForBlockedState(s State) SettlementReason {
	switch s {
	case StateQuarantinedDrift:
		return ReasonDriftQuarantined
	case StateBlockedRefMissing:
		return ReasonReferenceMissing
	case StateBlockedCalibMissing:
		return ReasonCalibrationMissing
	case StateBlockedAbusive:
		return ReasonBlockedAbusive
	case StateBlockedRefFault:
		return ReasonBlockedReferenceFault
	case StateBlockedManualReview:
		return ReasonBlockedManualReview
	case StateBlockedSwapLaunder:
		return ReasonBlockedSwapLaundering
	}
	return ReasonUnreadable
}

func expiryReason(cause ExpiryCause) SettlementReason {
	switch cause {
	case ExpiryReferenceStale:
		return ReasonReferenceStale
	case ExpiryThresholdStale:
		return ReasonThresholdStale
	case ExpirySamplingProfileUncov:
		return ReasonUncoveredProfile
	case ExpiryStateUnreadable:
		return ReasonUnreadable
	default:
		// window_ttl_expired, target_generation_changed, tokenizer_changed,
		// sampler_stage_changed, corpus_changed, catalog_changed, hardware_class_changed.
		return ReasonExpired
	}
}

// ApplyGate composes the SPEC-036 Decision onto a SPEC-022 settlement outcome as a
// strict AND-gate (FR-3): it only ever narrows creditability. It never relaxes a
// non-creditable SPEC-022 outcome and never promotes a row to payable.
//
// Returns the final settlement outcome and reason. When SPEC-036 blocks a covered
// enforce row, the outcome becomes quarantined with the SPEC-036 reason (drift is a
// trust failure and MUST NOT settle as zero_settled), overriding an otherwise-valid
// SPEC-022 verified receipt. When SPEC-036 does not block, the SPEC-022 outcome and
// reason pass through unchanged.
func ApplyGate(spec022Outcome, spec022Reason string, d Decision) (string, string) {
	if !d.Applies || d.Payable {
		return spec022Outcome, spec022Reason
	}
	return OutcomeQuarantined, string(d.Reason)
}
