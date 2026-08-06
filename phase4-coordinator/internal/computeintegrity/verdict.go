package computeintegrity

// FR-9 single-canary verdicts, the measurement-validation precedence, and the
// coordinator final-inconclusive taxonomy with abusive-classification.

// InconclusiveReason is the closed coordinator final-inconclusive enum (FR-9),
// distinct from the provider-supplied provider_reason_code of FR-6.
type InconclusiveReason string

const (
	IncIdentityReject       InconclusiveReason = "inconclusive:identity_reject"
	IncModelSwap            InconclusiveReason = "inconclusive:model_swap"
	IncPositionMismatch     InconclusiveReason = "inconclusive:position_mismatch"
	IncMalformedDist        InconclusiveReason = "inconclusive:malformed_distribution"
	IncTailMassHigh         InconclusiveReason = "inconclusive:tail_mass_high"
	IncKRetryFailed         InconclusiveReason = "inconclusive:k_retry_failed"
	IncCoordinatorTimeout   InconclusiveReason = "inconclusive:coordinator_timeout"
	IncCoordinatorRefFault  InconclusiveReason = "inconclusive:coordinator_reference_fault"
	IncProviderInconclusive InconclusiveReason = "inconclusive:provider_inconclusive"
)

// AssignVerdict assigns the single-canary verdict from per-reference, per-position TV
// intervals after any required K retry (FR-7, FR-9). perReference[r] holds the TV
// intervals for reference r across the measured positions. The FR-5 agreed-envelope
// rule: pass requires the pass predicate against EVERY active reference;
// quarantine_candidate requires the quarantine predicate against EVERY active
// reference; otherwise warn.
func AssignVerdict(perReference [][]TVInterval, th Thresholds) Verdict {
	if len(perReference) == 0 {
		return VerdictInconclusive
	}
	allPass, allQuar := true, true
	for _, positions := range perReference {
		if len(positions) == 0 {
			return VerdictInconclusive
		}
		if !referencePass(positions, th) {
			allPass = false
		}
		if !referenceQuarantine(positions, th) {
			allQuar = false
		}
	}
	switch {
	case allPass:
		return VerdictPass
	case allQuar:
		return VerdictQuarantineCandidate
	default:
		return VerdictWarn
	}
}

// referencePass reports the FR-9 pass predicate for one reference's positions: median
// tv_upper <= tau_warn_median and every position tv_upper <= tau_warn_position.
func referencePass(positions []TVInterval, th Thresholds) bool {
	uppers := make([]float64, len(positions))
	for i, iv := range positions {
		uppers[i] = iv.Upper
		if iv.Upper > th.TauWarnPosition {
			return false
		}
	}
	return canonicalMedian(uppers) <= th.TauWarnMedian
}

// referenceQuarantine reports the FR-9 quarantine_candidate predicate for one
// reference's positions: median tv_lower > tau_quarantine_median or any position
// tv_lower > tau_quarantine_position.
func referenceQuarantine(positions []TVInterval, th Thresholds) bool {
	lowers := make([]float64, len(positions))
	for i, iv := range positions {
		lowers[i] = iv.Lower
		if iv.Lower > th.TauQuarantinePosition {
			return true
		}
	}
	return canonicalMedian(lowers) > th.TauQuarantineMedian
}

// MeasurementValidationInputs carries the boolean outcomes of the FR-9
// measurement-validation checks, evaluated by the caller against the issued request.
type MeasurementValidationInputs struct {
	AuthReplayEnvelopeFail bool // nonce/digest/type/schema/expiry mismatch or duplicate-digest replay
	PerPositionHashGenSwap bool // per-position actual hash/generation change or mix across positions
	GlobalIdentityMismatch bool // model_id/tokenizer/profile/corpus/threshold/hardware_class echo mismatch
	BindingFail            bool // prompt/position/prefix/context binding failure
	DistributionFail       bool // FR-6 distribution/support/tail validation failure
	TailMassHigh           bool // FR-7 K=256 tail ceiling exceeded
	KRetryFailed           bool // FR-7 mandatory K=256 retry could not complete
}

// ResolveMeasurementValidation applies the FR-9 measurement-validation precedence
// (ordered; first match wins). It returns the inconclusive reason and true if the
// measurement is inconclusive, or false if it passed validation and can be scored.
func ResolveMeasurementValidation(in MeasurementValidationInputs) (InconclusiveReason, bool) {
	switch {
	case in.AuthReplayEnvelopeFail:
		return IncIdentityReject, true
	case in.PerPositionHashGenSwap:
		return IncModelSwap, true
	case in.GlobalIdentityMismatch:
		return IncIdentityReject, true
	case in.BindingFail:
		return IncPositionMismatch, true
	case in.DistributionFail:
		return IncMalformedDist, true
	case in.TailMassHigh:
		return IncTailMassHigh, true
	case in.KRetryFailed:
		return IncKRetryFailed, true
	}
	return "", false
}

// IsAbusiveInconclusive reports whether a coordinator final-inconclusive event counts
// toward the FR-10 abusive-inconclusive accumulator (FR-9). coordinatorFault is true
// when the coordinator attributes the failure to its own corpus/reference/scheduling/
// transport fault, which exempts the otherwise-abusive reasons. model_swap and the
// coordinator-fault reasons are never abusive; tail_mass_high is not abusive unless
// repeated (tracked separately by the caller).
func IsAbusiveInconclusive(reason InconclusiveReason, coordinatorFault bool) bool {
	switch reason {
	case IncModelSwap, IncCoordinatorRefFault:
		return false // identity change / coordinator fault: never abusive.
	case IncTailMassHigh:
		return false // not abusive unless repeated >3 in 24h (caller tracks repetition).
	case IncIdentityReject, IncPositionMismatch, IncMalformedDist, IncKRetryFailed,
		IncCoordinatorTimeout:
		return !coordinatorFault
	case IncProviderInconclusive:
		return !coordinatorFault
	}
	return false
}

// ProviderReasonToInconclusive maps a well-formed provider_inconclusive result's
// provider_reason_code to the abusive-classification effect (FR-9). It returns
// whether the mapped event is abusive. referenceOutageConfirmed is only consulted for
// reference_unavailable, which is abusive UNLESS the coordinator independently
// confirms an outage (a provider-supplied reference_unavailable is not
// self-authenticating).
func ProviderReasonToInconclusive(code string, referenceOutageConfirmed bool) (abusive bool) {
	switch code {
	case "inconclusive:model_swap":
		return false // treated as expired identity change.
	case "inconclusive:reference_unavailable":
		return !referenceOutageConfirmed
	case "inconclusive:unsupported_sampler", "inconclusive:position_mismatch",
		"inconclusive:missing_distribution", "inconclusive:timeout":
		return true
	}
	return true // unknown provider code: fail closed as abusive.
}
