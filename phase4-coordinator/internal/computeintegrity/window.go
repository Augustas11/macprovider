package computeintegrity

import "sync"

// FR-10 window state machine + FR-12 warm-swap/laundering. State ownership is
// canonical (FR-10, §3): positive measurement/verdict state and the rolling verdict
// window live on the window key; active quarantine/block state and the three rolling
// accumulators live on the overlay key (the window key minus target_generation). A
// higher-level swap-laundering overlay keyed by (stable_provider_identity, model_id)
// spans all artifacts for that provider/model.

// canary is one finalized eligible canary result on a window key.
type canary struct {
	verdict Verdict
	atMs    int64
}

// windowState holds the rolling verdict window and outstanding-probe markers for a
// window key (FR-10). Positive state is recomputed from it, never stored sticky.
type windowState struct {
	canaries   []canary
	hasPending bool
	assignedID string // the assigned_id whose measurements populated this window
}

// overlayState holds the adverse overlay state and the three rolling accumulators for
// an overlay key (FR-10, §3). These persist across target_generation / assigned_id /
// admission-key churn (FR-12).
type overlayState struct {
	state                State // "" (none), quarantined_compute_drift, or a blocked:<reason>
	origin               AdjudicationOrigin
	quarantineCandWindow int     // rolling quarantine-candidate window count
	abusiveEvents        []int64 // 24h abusive-inconclusive event timestamps
	onboardingFailures   []int64 // 24h onboarding-failure timestamps
	passStreak           int     // consecutive passes toward a clear
	firstPassMs          int64   // first pass in the current clear streak
}

// swapState holds the swap-laundering overlay for a (stable_provider_identity, model)
// scope (FR-12).
type swapState struct {
	blocked bool
	origin  AdjudicationOrigin
}

// Store is the in-memory compute-integrity state store. It is safe for concurrent use.
// A concrete durable store can wrap the same key algebra; the window/overlay ownership
// rules here are what the AC fixtures pin.
type Store struct {
	mu         sync.Mutex
	windows    map[WindowKey]*windowState
	overlays   map[OverlayKey]*overlayState
	swaps      map[SwapLaunderingScope]*swapState
	tombstones map[SwapLaunderingScope]bool
}

// NewStore returns an empty in-memory compute-integrity store.
func NewStore() *Store {
	return &Store{
		windows:    map[WindowKey]*windowState{},
		overlays:   map[OverlayKey]*overlayState{},
		swaps:      map[SwapLaunderingScope]*swapState{},
		tombstones: map[SwapLaunderingScope]bool{},
	}
}

func (s *Store) window(k WindowKey) *windowState {
	ws := s.windows[k]
	if ws == nil {
		ws = &windowState{}
		s.windows[k] = ws
	}
	return ws
}

func (s *Store) overlay(k OverlayKey) *overlayState {
	os := s.overlays[k]
	if os == nil {
		os = &overlayState{}
		s.overlays[k] = os
	}
	return os
}

// RecordCanary records a finalized eligible canary and updates the overlay
// accumulators (FR-9, FR-10). A quarantine_candidate increments the rolling
// quarantine-candidate window count; a pass advances the clear streak.
func (s *Store) RecordCanary(key ComputeIntegrityKey, v Verdict, atMs int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.window(key.Window())
	ws.canaries = append(ws.canaries, canary{verdict: v, atMs: atMs})
	ws.hasPending = false
	ws.assignedID = key.AssignedID

	ov := s.overlay(key.Overlay())
	switch v {
	case VerdictQuarantineCandidate:
		ov.quarantineCandWindow++
		ov.passStreak = 0
		ov.firstPassMs = 0
	case VerdictPass:
		if ov.passStreak == 0 {
			ov.firstPassMs = atMs
		}
		ov.passStreak++
	}
}

// RecordAbusiveInconclusive records an abusive-inconclusive event on the overlay key
// (FR-9, FR-10) and blocks the key when the 24h count exceeds the limit.
func (s *Store) RecordAbusiveInconclusive(key ComputeIntegrityKey, atMs int64, limit int, origin AdjudicationOrigin) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ov := s.overlay(key.Overlay())
	ov.abusiveEvents = pruneWindow(append(ov.abusiveEvents, atMs), atMs, day)
	if len(ov.abusiveEvents) > limit && !ov.state.IsAdverseOverlay() {
		ov.state = StateBlockedAbusive
		ov.origin = origin
	}
}

// RecordOnboardingFailure records an onboarding-failure event (FR-11); two failures
// in 24h move the key to blocked:manual_review_required in enforce mode.
func (s *Store) RecordOnboardingFailure(key ComputeIntegrityKey, atMs int64, origin AdjudicationOrigin) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ov := s.overlay(key.Overlay())
	ov.onboardingFailures = pruneWindow(append(ov.onboardingFailures, atMs), atMs, day)
	if len(ov.onboardingFailures) >= 2 && !ov.state.IsAdverseOverlay() {
		ov.state = StateBlockedManualReview
		ov.origin = origin
	}
}

const day = int64(24 * 3600 * 1000)

func pruneWindow(times []int64, now, window int64) []int64 {
	out := times[:0]
	for _, t := range times {
		if now-t < window {
			out = append(out, t)
		}
	}
	return out
}

// ResolveInput carries the freshness/invalidation context for state resolution.
type ResolveInput struct {
	Policy Policy
	NowMs  int64
	// InvalidationCause, when non-empty, signals a freshness/invalidation failure
	// detected at request-start re-evaluation (FR-4): TTL, generation, tokenizer,
	// sampler, corpus, threshold, catalog, or hardware-class change.
	InvalidationCause   ExpiryCause
	AdmissibilityStatus AdmissibilityStatus
}

// ResolveState recomputes the effective compute-integrity state for a key by the
// FR-10 ordered resolution (first match wins). It is deterministic and never sticky:
// an intervening quarantine_candidate that does not satisfy the window quarantine rule
// resolves to pending, not a retained verified.
func (s *Store) ResolveState(key ComputeIntegrityKey, in ResolveInput) (State, ExpiryCause) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// 1. Swap-laundering overlay (consulted first, FR-12) or per-key overlay adverse state.
	if sw := s.swaps[key.Overlay().SwapLaunderingScope()]; sw != nil && sw.blocked {
		return StateBlockedSwapLaunder, ""
	}
	ov := s.overlays[key.Overlay()]
	if ov != nil {
		// A window that meets the quarantine rule promotes to quarantined_compute_drift.
		if ov.state == "" && s.windowMeetsQuarantine(key.Window(), in.Policy) {
			ov.state = StateQuarantinedDrift
			ov.origin = OriginEnforcePreserved
		}
		if ov.state.IsAdverseOverlay() {
			return ov.state, ""
		}
	} else if s.windowMeetsQuarantine(key.Window(), in.Policy) {
		nov := s.overlay(key.Overlay())
		nov.state = StateQuarantinedDrift
		nov.origin = OriginEnforcePreserved
		return StateQuarantinedDrift, ""
	}

	// Coordinator-attributable reference block from admissibility.
	switch in.AdmissibilityStatus {
	case AdmissibilityMissingQuorum:
		return StateBlockedRefMissing, ""
	case AdmissibilityReferenceFault, AdmissibilityIndepFailed, AdmissibilityProvMissing:
		return StateBlockedRefFault, ""
	}

	// 2. Freshness/invalidation failure -> expired with cause.
	if in.InvalidationCause != "" {
		return StateExpired, in.InvalidationCause
	}

	ws := s.windows[key.Window()]
	// 3. No valid result yet -> unknown.
	if ws == nil || len(ws.canaries) == 0 {
		if ws != nil && ws.hasPending {
			return StatePending, ""
		}
		return StateUnknown, ""
	}

	// 4/5/6: payable-window prerequisites gate verified/warn; else pending.
	if !s.payableWindowPrereqs(key.Window(), in) {
		return StatePending, ""
	}
	if s.verifiedPassRule(key.Window(), in.Policy, in.NowMs) {
		return StateVerified, ""
	}
	if latestIsWarnClass(ws) {
		return StateWarn, ""
	}
	return StatePending, ""
}

// eligibleCanaries returns the canaries within window_size_days of now, oldest-first.
func eligible(ws *windowState, policy Policy, nowMs int64) []canary {
	if ws == nil {
		return nil
	}
	windowMs := int64(policy.WindowSizeDays) * day
	out := make([]canary, 0, len(ws.canaries))
	for _, c := range ws.canaries {
		if windowMs <= 0 || nowMs-c.atMs <= windowMs {
			out = append(out, c)
		}
	}
	return out
}

func (s *Store) windowMeetsQuarantine(k WindowKey, policy Policy) bool {
	ws := s.windows[k]
	if ws == nil {
		return false
	}
	elig := ws.canaries
	if len(elig) < policy.MinWindowCanaries {
		return false
	}
	latest := elig[len(elig)-policy.MinWindowCanaries:]
	count := 0
	for _, c := range latest {
		if c.verdict == VerdictQuarantineCandidate {
			count++
		}
	}
	return count >= policy.QuarantineCandidateCount
}

func (s *Store) payableWindowPrereqs(k WindowKey, in ResolveInput) bool {
	ws := s.windows[k]
	elig := eligible(ws, in.Policy, in.NowMs)
	if len(elig) < in.Policy.MinWindowCanaries {
		return false // under-sampled -> pending
	}
	// Freshness TTL: newest eligible canary must be within the positive-state TTL.
	newest := elig[len(elig)-1]
	ttlMs := int64(in.Policy.PositiveStateFreshnessTTLHrs) * 3600 * 1000
	if ttlMs > 0 && in.NowMs-newest.atMs > ttlMs {
		return false
	}
	if in.AdmissibilityStatus != AdmissibilityAdmissible {
		return false
	}
	if s.windowMeetsQuarantine(k, in.Policy) {
		return false
	}
	return true
}

func (s *Store) verifiedPassRule(k WindowKey, policy Policy, nowMs int64) bool {
	ws := s.windows[k]
	elig := eligible(ws, policy, nowMs)
	if len(elig) < policy.ClearPassCount {
		return false
	}
	for _, c := range elig[len(elig)-policy.ClearPassCount:] {
		if c.verdict != VerdictPass {
			return false
		}
	}
	return true
}

func latestIsWarnClass(ws *windowState) bool {
	if len(ws.canaries) == 0 {
		return false
	}
	return ws.canaries[len(ws.canaries)-1].verdict == VerdictWarn
}

// QuarantineCandidateWindowCount returns the overlay's rolling quarantine-candidate
// count (FR-10 accumulator), used by the FR-12 swap-laundering trigger.
func (s *Store) QuarantineCandidateWindowCount(k OverlayKey) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	if ov := s.overlays[k]; ov != nil {
		return ov.quarantineCandWindow
	}
	return 0
}

// OverlayState returns the current adverse overlay state for a key ("" if none).
func (s *Store) OverlayState(k OverlayKey) State {
	s.mu.Lock()
	defer s.mu.Unlock()
	if ov := s.overlays[k]; ov != nil {
		return ov.state
	}
	return ""
}
