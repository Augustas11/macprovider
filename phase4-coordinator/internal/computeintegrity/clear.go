package computeintegrity

// FR-10 clear rules. quarantined_compute_drift and blocked:abusive_inconclusive clear
// via clear_pass_count consecutive passes over at least 24 hours on the overlay key;
// the manual-review, swap-laundering, and reference blocks clear only through
// dual-approved manual review (FR-10, FR-16). A target_generation change never clears
// the overlay (the overlay key omits target_generation).

// AttemptClear tries to clear a pass-sequence-clearable overlay adverse state
// (quarantined_compute_drift or blocked:abusive_inconclusive) using the accumulated
// pass streak (FR-10). It clears only when clear_pass_count CONSECUTIVE passes have
// been recorded over at least 24 hours (any intervening warn/quarantine_candidate
// resets the streak in RecordCanary) AND the current reference set is fresh and
// admissible. Returns whether it cleared.
func (s *Store) AttemptClear(key ComputeIntegrityKey, policy Policy, admissibility AdmissibilityStatus, nowMs int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if admissibility != AdmissibilityAdmissible {
		return false // clear requires current fresh admissible reference evidence.
	}
	ov := s.overlays[key.Overlay()]
	if ov == nil {
		return false
	}
	// Pass-sequence-clearable states are quarantined_compute_drift, blocked:abusive, and
	// a flapping-origin blocked:manual_review whose clear_rule is clear_pass_count_sequence
	// (the sole manual-review exception, FR-10). Other blocks need dual approval.
	clearable := ov.state == StateQuarantinedDrift || ov.state == StateBlockedAbusive ||
		(ov.state == StateBlockedManualReview && ov.flappingPassClearable)
	if !clearable {
		return false
	}
	if ov.passStreak < policy.ClearPassCount {
		return false
	}
	if ov.firstPassMs == 0 || nowMs-ov.firstPassMs < day {
		return false // must span at least 24 hours.
	}
	// Only passes recorded AFTER the block was entered count toward a clear (FR-10):
	// pre-block passes must not clear a fresh block.
	if ov.firstPassMs < ov.blockEnteredMs {
		return false
	}
	// blocked:abusive_inconclusive additionally requires the rolling 24h abusive window
	// to be below the limit before it clears (FR-10).
	if ov.state == StateBlockedAbusive {
		if len(pruneWindow(ov.abusiveEvents, nowMs, day)) > policy.AbusiveInconclusiveLimit {
			return false
		}
	}
	ov.state = ""
	ov.origin = ""
	ov.quarantineCandWindow = 0
	ov.flappingPassClearable = false
	ov.blockEnteredMs = 0
	return true
}

// DualApproveClear clears any overlay adverse state (including manual-review,
// swap-laundering, and reference blocks) through a recorded dual-approved manual
// review (FR-10, FR-16). approverA and approverB must be distinct and non-empty.
// Returns whether it cleared.
func (s *Store) DualApproveClear(key ComputeIntegrityKey, approverA, approverB string) bool {
	if approverA == "" || approverB == "" || approverA == approverB {
		return false // dual approval requires two distinct approvers.
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	cleared := false
	if sw := s.swaps[key.Overlay().SwapLaunderingScope()]; sw != nil && sw.blocked {
		sw.blocked = false
		sw.origin = ""
		cleared = true
	}
	if ov := s.overlays[key.Overlay()]; ov != nil && ov.state.IsAdverseOverlay() {
		ov.state = ""
		ov.origin = ""
		ov.quarantineCandWindow = 0
		cleared = true
	}
	// Dual-approved review may also retire the lineage tombstone.
	tomb := key.Overlay().TombstoneScope()
	if _, ok := s.tombstones[tomb]; ok {
		delete(s.tombstones, tomb)
		cleared = true
	}
	return cleared
}
