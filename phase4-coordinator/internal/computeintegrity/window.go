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
	tombstones map[TombstoneScope]bool
}

// NewStore returns an empty in-memory compute-integrity store.
func NewStore() *Store {
	return &Store{
		windows:    map[WindowKey]*windowState{},
		overlays:   map[OverlayKey]*overlayState{},
		swaps:      map[SwapLaunderingScope]*swapState{},
		tombstones: map[TombstoneScope]bool{},
	}
}

// deriveOrigin returns the FR-3 adjudication origin for a state adjudicated under the
// given runtime mode and SPEC-022 enforce conjunction. Only enforce + SPEC-022 enforce
// yields enforce_preserved; everything else is telemetry_only (which never has a
// money/routing effect). This is the re-adjudication boundary: a telemetry_only state
// only becomes money-blocking via a fresh enforce-mode adjudication.
func deriveOrigin(mode Mode, spec022Enforce bool) AdjudicationOrigin {
	if mode == ModeEnforce && spec022Enforce {
		return OriginEnforcePreserved
	}
	return OriginTelemetryOnly
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
// accumulators (FR-9, FR-10). origin is the FR-3 adjudication origin under which this
// canary was measured (deriveOrigin at record time); it is stamped onto the overlay the
// first time risk (a quarantine_candidate) is recorded, so a later swap-laundering block
// or promotion derived from accumulator-only risk inherits the correct origin. A
// quarantine_candidate increments the rolling count; a pass advances the clear streak.
func (s *Store) RecordCanary(key ComputeIntegrityKey, v Verdict, atMs int64, origin AdjudicationOrigin) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.window(key.Window())
	ws.canaries = append(ws.canaries, canary{verdict: v, atMs: atMs})
	ws.hasPending = false
	ws.assignedID = key.AssignedID

	ov := s.overlay(key.Overlay())
	switch v {
	case VerdictPass:
		if ov.passStreak == 0 {
			ov.firstPassMs = atMs
		}
		ov.passStreak++
	case VerdictQuarantineCandidate:
		ov.quarantineCandWindow++
		ov.passStreak = 0 // any non-pass breaks the consecutive-pass clear streak (FR-10).
		ov.firstPassMs = 0
		if !ov.origin.Known() {
			ov.origin = origin // stamp the origin of the accumulated risk.
		}
	default: // warn, inconclusive: not a pass, so the consecutive-pass streak resets.
		ov.passStreak = 0
		ov.firstPassMs = 0
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
	// Spec022EffectiveEnforce is whether SPEC-022 is enforcing for this coverage. It
	// (with Policy.Mode) sets the adjudication origin of any newly-promoted adverse
	// state (FR-3): a quarantine first met under observe/warn_only or while SPEC-022 is
	// not enforcing is telemetry_only, not enforce_preserved.
	Spec022EffectiveEnforce bool
}

// ResolveState recomputes the effective compute-integrity state for a key by the
// FR-10 ordered resolution (first match wins). It is deterministic and never sticky:
// an intervening quarantine_candidate that does not satisfy the window quarantine rule
// resolves to pending, not a retained verified.
func (s *Store) ResolveState(key ComputeIntegrityKey, in ResolveInput) (State, ExpiryCause, AdjudicationOrigin) {
	s.mu.Lock()
	defer s.mu.Unlock()

	mode := in.Policy.Mode
	spec022 := in.Spec022EffectiveEnforce
	origin := deriveOrigin(mode, spec022)

	// 1. Adverse overlays take precedence ONLY when their effect is active per the FR-3
	// effective_adverse_state matrix; a dormant (telemetry_only, or coordinator-
	// attributable on a SPEC-036-only downgrade) overlay persists but falls through to
	// positive-state recomputation, so a telemetry-only quarantine never blocks routing.
	if sw := s.swaps[key.Overlay().SwapLaunderingScope()]; sw != nil && sw.blocked {
		if EffectiveAdverseState(mode, spec022, sw.origin, attribProviderOrBreaker) {
			return StateBlockedSwapLaunder, "", sw.origin
		}
	}
	ov := s.overlays[key.Overlay()]
	if ov == nil && s.windowMeetsQuarantine(key.Window(), in.Policy, in.NowMs) {
		ov = s.overlay(key.Overlay())
	}
	if ov != nil {
		// A window that meets the quarantine rule promotes to quarantined_compute_drift.
		// Its origin is the origin already stamped on the accumulated risk when Known
		// (never downgrade an enforce_preserved accumulation), else the current mode's.
		if ov.state == "" && s.windowMeetsQuarantine(key.Window(), in.Policy, in.NowMs) {
			ov.state = StateQuarantinedDrift
			if !ov.origin.Known() {
				ov.origin = origin
			}
		}
		if ov.state.IsAdverseOverlay() {
			attrib := attribCoordinator
			if ov.state.IsProviderAttributable() {
				attrib = attribProviderOrBreaker
			}
			if EffectiveAdverseState(mode, spec022, ov.origin, attrib) {
				return ov.state, "", ov.origin
			}
			// Dormant overlay: persist, fall through to positive resolution below.
		}
	}

	// Coordinator-attributable reference block from admissibility (a live coordinator
	// condition). Under a SPEC-036-only downgrade these are dormant for routing per the
	// matrix; they still prevent a fresh verified/warn positive state below.
	if mode == ModeEnforce && spec022 {
		switch in.AdmissibilityStatus {
		case AdmissibilityMissingQuorum:
			return StateBlockedRefMissing, "", OriginEnforcePreserved
		case AdmissibilityReferenceFault, AdmissibilityIndepFailed, AdmissibilityProvMissing:
			return StateBlockedRefFault, "", OriginEnforcePreserved
		}
	}

	// 2. Freshness/invalidation failure -> expired with cause.
	if in.InvalidationCause != "" {
		return StateExpired, in.InvalidationCause, ""
	}

	ws := s.windows[key.Window()]
	// 3. No valid result yet -> unknown.
	if ws == nil || len(ws.canaries) == 0 {
		if ws != nil && ws.hasPending {
			return StatePending, "", ""
		}
		return StateUnknown, "", ""
	}

	elig := eligible(ws, in.Policy, in.NowMs)
	// Under-sampled windows (including a window all of whose canaries aged out beyond
	// window_size_days) remain pending, never expired (FR-10).
	if len(elig) < in.Policy.MinWindowCanaries {
		return StatePending, "", ""
	}
	// Freshness TTL: a window whose newest eligible canary is older than the
	// positive-state TTL expires as window_ttl_expired (non-payable), not pending (FR-10).
	newest := elig[len(elig)-1]
	ttlMs := int64(in.Policy.PositiveStateFreshnessTTLHrs) * 3600 * 1000
	if ttlMs > 0 && in.NowMs-newest.atMs > ttlMs {
		return StateExpired, ExpiryWindowTTLExpired, ""
	}
	// Coordinator-attributable non-admissibility or an unmet quarantine rule leaves the
	// key non-payable but not expired -> pending.
	if in.AdmissibilityStatus != AdmissibilityAdmissible || s.windowMeetsQuarantine(key.Window(), in.Policy, in.NowMs) {
		return StatePending, "", ""
	}
	// 4/5: payable positive states.
	if s.verifiedPassRule(key.Window(), in.Policy, in.NowMs) {
		return StateVerified, "", ""
	}
	if latestIsWarnClass(ws) {
		return StateWarn, "", ""
	}
	return StatePending, "", ""
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

// windowMeetsQuarantine reports whether at least quarantine_candidate_count of the
// latest min_window_canaries ELIGIBLE canaries (within window_size_days) are
// quarantine_candidate, regardless of intervening passes (FR-10). Canaries that have
// aged out of the rolling window do not count.
func (s *Store) windowMeetsQuarantine(k WindowKey, policy Policy, nowMs int64) bool {
	elig := eligible(s.windows[k], policy, nowMs)
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
