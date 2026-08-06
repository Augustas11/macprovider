package computeintegrity

import "math"

// FR-10 flapping_window_policy_v0_1 (disabled by default). When enabled, a key that
// persistently hovers near the quarantine boundary — enough pass/warn/quarantine_
// candidate results in the lookback AND the configured margin metric at or below
// threshold_margin — takes the configured action (none or blocked:manual_review_required).

// FlappingCanary is one eligible canary's flapping inputs over the lookback: its id,
// timestamp, verdict, and the tv_lower summary statistics used by the FR-10 margin
// metrics.
type FlappingCanary struct {
	CanaryID           string
	AtMs               int64
	Verdict            Verdict
	MedianTVLower      float64 // median(tv_lower) for the canary
	MaxPositionTVLower float64 // max over positions of tv_lower
}

// FlappingEvidence is the FR-10 audit evidence recorded when the flapping predicate is
// evaluated: metric values, counts, action, and — for a settlement-affecting block —
// the contributing canary ids and (on clear) approver / clear evidence, so the block is
// audit-replayable.
type FlappingEvidence struct {
	Metric                   string
	MetricValue              float64
	PassCount                int
	WarnCount                int
	QuarantineCandidateCount int
	Action                   string
	Triggered                bool
	CanaryIDs                []string
	Approver                 string
	ClearEvidence            string
}

// EvaluateFlapping evaluates the exact FR-10 flapping conjunction over the canaries
// within lookback_window_days of nowMs. It returns whether the trigger fired and the
// audit evidence. The metric is each canary's non-negative margin below the quarantine
// threshold (smaller = closer to quarantine); median uses the canonical lower-middle
// median, max_position uses the minimum margin (the closest any position came to
// quarantine). The trigger boundary is metric <= threshold_margin.
func EvaluateFlapping(canaries []FlappingCanary, fp FlappingWindowPolicy, th Thresholds, nowMs int64) FlappingEvidence {
	ev := FlappingEvidence{Metric: fp.Metric, Action: fp.Action}
	if !fp.Enabled {
		return ev
	}
	lookbackMs := int64(fp.LookbackWindowDays) * day
	medianMargins := make([]float64, 0, len(canaries))
	positionMargins := make([]float64, 0, len(canaries))
	for _, c := range canaries {
		if lookbackMs > 0 && nowMs-c.AtMs > lookbackMs {
			continue // stale canary outside the lookback window does not count.
		}
		ev.CanaryIDs = append(ev.CanaryIDs, c.CanaryID)
		switch c.Verdict {
		case VerdictPass:
			ev.PassCount++
		case VerdictWarn:
			ev.WarnCount++
		case VerdictQuarantineCandidate:
			ev.QuarantineCandidateCount++
		}
		medianMargins = append(medianMargins, math.Max(0, th.TauQuarantineMedian-c.MedianTVLower))
		positionMargins = append(positionMargins, math.Max(0, th.TauQuarantinePosition-c.MaxPositionTVLower))
	}
	switch fp.Metric {
	case flappingMetricMedian:
		ev.MetricValue = canonicalMedian(medianMargins)
	case flappingMetricPosition:
		ev.MetricValue = minFloat(positionMargins)
	default:
		return ev // unknown metric: never triggers.
	}
	countsMet := ev.PassCount >= fp.MinPassCount &&
		ev.WarnCount >= fp.MinWarnCount &&
		ev.QuarantineCandidateCount >= fp.MinQuarantineCandidateCount
	ev.Triggered = countsMet && ev.MetricValue <= fp.ThresholdMargin
	return ev
}

func minFloat(xs []float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	m := xs[0]
	for _, x := range xs[1:] {
		if x < m {
			m = x
		}
	}
	return m
}

// ApplyFlapping evaluates the flapping predicate for a key and, when it triggers with
// action blocked:manual_review_required, moves the overlay to that block (FR-10). The
// clear_rule (dual_approval or clear_pass_count_sequence) is recorded on the policy and
// governs how the block later clears. Returns the evidence. Action "none" is telemetry
// only and changes no state.
func (s *Store) ApplyFlapping(key ComputeIntegrityKey, fp FlappingWindowPolicy, th Thresholds,
	canaries []FlappingCanary, nowMs int64, origin AdjudicationOrigin) FlappingEvidence {
	ev := EvaluateFlapping(canaries, fp, th, nowMs)
	if !ev.Triggered || fp.Action != flappingActionManualReview {
		return ev
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ov := s.overlay(key.Overlay())
	if !ov.state.IsAdverseOverlay() {
		ov.enterBlock(StateBlockedManualReview, origin, nowMs)
		ov.flappingPassClearable = FlappingClearsByPassSequence(fp)
	}
	return ev
}

// FlappingClearsByPassSequence reports whether a blocked:manual_review_required entered
// by the flapping policy may clear via a clear_pass_count pass sequence (the sole
// exception to dual-approval-only clearing, FR-10), i.e. when the policy's clear_rule is
// clear_pass_count_sequence.
func FlappingClearsByPassSequence(fp FlappingWindowPolicy) bool {
	return fp.Enabled && fp.ClearRule == flappingClearPassSequence
}
