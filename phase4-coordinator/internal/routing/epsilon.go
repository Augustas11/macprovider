package routing

import (
	"math"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// Objective names the SPEC-004 FR-SR-8 objective selecting which
// primary metric drives the epsilon cohort. The "default" value
// (utilization mode) is SPEC-002's pre-SPEC-004 baseline.
type Objective string

const (
	ObjectiveDefault  Objective = "default"
	ObjectiveFast     Objective = "fast"
	ObjectiveAccurate Objective = "accurate"
	ObjectiveBalanced Objective = "balanced"
)

// WithinRelativeEpsilon reports whether candidate is inside the
// relative epsilon cohort of top per SPEC-004 v0.2 §5 (epsilon is
// a relative fraction; 0.05 means within 5%). Epsilon-0 admits
// exact ties only — matching SPEC-004 §5 "if tiebreak_randomize is
// true and epsilon is 0, only exact metric ties enter the random
// cohort."
//
// Sign-stable: uses |top| as the relative denominator. When top is
// exactly 0, falls back to absolute |candidate| <= epsilon so a
// 0-metric reference never yields divide-by-zero. Negative metrics
// are admitted by absolute distance scaled by |top|.
func WithinRelativeEpsilon(top, candidate, epsilon float64) bool {
	if top == candidate {
		return true
	}
	if epsilon <= 0 {
		return false
	}
	denom := math.Abs(top)
	if denom == 0 {
		return math.Abs(candidate) <= epsilon
	}
	return math.Abs(top-candidate) <= denom*epsilon
}

// InEpsilonCohort reports whether candidate is in top's epsilon
// cohort per SPEC-004 FR-SR-16. The objective selects which metric
// drives the cohort:
//
//   - ObjectiveDefault (utilization): slots_free MUST equal top's
//     AND effective throughput is within epsilon.
//   - ObjectiveFast: effective throughput is within epsilon.
//   - ObjectiveAccurate: model_params_b is within epsilon.
//   - ObjectiveBalanced: caller supplies pre-computed balanced
//     scores via balancedScore (a function the caller derives from
//     the eligible candidate set — see SPEC-004 FR-SR-8 normative
//     score formula). Phase B does not include the score formula
//     itself; Phase D wires that.
//
// balancedScore is consulted only when objective == ObjectiveBalanced
// and MAY be nil for other objectives; if balancedScore is nil and
// objective == ObjectiveBalanced, InEpsilonCohort returns false (no
// score is treated as out-of-cohort, which is the conservative
// default for misconfigured callers).
func InEpsilonCohort(
	top, candidate pool.Provider,
	objective Objective,
	epsilon float64,
	weights Weights,
	balancedScore func(pool.Provider) float64,
) bool {
	switch objective {
	case ObjectiveAccurate:
		return WithinRelativeEpsilon(top.ModelParamsB, candidate.ModelParamsB, epsilon)
	case ObjectiveBalanced:
		if balancedScore == nil {
			return false
		}
		return WithinRelativeEpsilon(balancedScore(top), balancedScore(candidate), epsilon)
	case ObjectiveFast:
		return WithinRelativeEpsilon(
			EffectiveThroughput(top, weights),
			EffectiveThroughput(candidate, weights),
			epsilon,
		)
	default:
		// ObjectiveDefault (utilization mode): slots_free MUST equal
		// top's, AND effective throughput within epsilon. Per
		// SPEC-004 FR-SR-16 first bullet under "epsilon cohort
		// per objective".
		if top.SlotsFree != candidate.SlotsFree {
			return false
		}
		return WithinRelativeEpsilon(
			EffectiveThroughput(top, weights),
			EffectiveThroughput(candidate, weights),
			epsilon,
		)
	}
}
