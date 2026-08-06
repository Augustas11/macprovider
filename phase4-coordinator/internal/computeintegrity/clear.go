package computeintegrity

// FR-10 clear rules. quarantined_compute_drift and blocked:abusive_inconclusive clear
// via clear_pass_count consecutive passes over at least 24 hours on the overlay key;
// the manual-review, swap-laundering, and reference blocks clear only through
// dual-approved manual review (FR-10, FR-16). A target_generation change never clears
// the overlay (the overlay key omits target_generation).

// AttemptClear tries to clear a pass-sequence-clearable overlay adverse state
// (quarantined_compute_drift or blocked:abusive_inconclusive) using the accumulated
// pass streak (FR-10). It clears only when clear_pass_count consecutive passes have
// been recorded over at least 24 hours. Returns whether it cleared.
func (s *Store) AttemptClear(key ComputeIntegrityKey, policy Policy, nowMs int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	ov := s.overlays[key.Overlay()]
	if ov == nil {
		return false
	}
	if ov.state != StateQuarantinedDrift && ov.state != StateBlockedAbusive {
		return false // manual_review / swap / reference blocks need dual approval.
	}
	if ov.passStreak < policy.ClearPassCount {
		return false
	}
	if ov.firstPassMs == 0 || nowMs-ov.firstPassMs < day {
		return false // must span at least 24 hours.
	}
	ov.state = ""
	ov.origin = ""
	ov.quarantineCandWindow = 0
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
	scope := key.Overlay().SwapLaunderingScope()
	cleared := false
	if sw := s.swaps[scope]; sw != nil && sw.blocked {
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
	if s.tombstones[scope] {
		delete(s.tombstones, scope)
		cleared = true
	}
	return cleared
}
