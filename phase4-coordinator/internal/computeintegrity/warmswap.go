package computeintegrity

// FR-12 warm-swap and generation handling. Positive state never carries across a
// target-generation boundary; the stable-identity risk overlay and its three
// accumulators persist across every target_generation / assigned_id / admission-key
// change; and a provider-originated artifact change made while the prior per-key
// overlay carries active provider-attributable risk escalates the swap-laundering
// overlay.

// InvalidatePositiveWindow purges the positive window state (verified/warn/pending)
// and outstanding probes for a window key (FR-12), forcing fresh measurement. Called
// on an assigned_id change (a reused generation number could otherwise collide with a
// stale payable window, which projects away assigned_id) and on any
// generation/tokenizer/sampler/corpus/threshold/catalog/hardware-class change. The
// assigned-id-free adverse overlay and accumulators are preserved.
func (s *Store) InvalidatePositiveWindow(k WindowKey) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.windows, k)
}

// ArtifactChangeEvent describes a provider-originated identity change (FR-12).
type ArtifactChangeEvent struct {
	// HashTokenizerOrGenerationChanged is true for a provider-originated change of
	// target_model_hash, tokenizer_identity, or target_generation.
	HashTokenizerOrGenerationChanged bool
	ContinuityProvenReconnect        bool // exempt
	SameHashReload                   bool // exempt
	AtMs                             int64
}

// priorOverlayCarriesRisk reports whether the prior per-key overlay carries active
// provider-attributable risk that must follow the provider across artifact churn
// (FR-12): active provider-attributable state OR a non-zero quarantine-candidate
// window count, 24h abusive-inconclusive count, or 24h onboarding-failure count.
func (ov *overlayState) priorOverlayCarriesRisk() bool {
	if ov == nil {
		return false
	}
	if ov.state.IsProviderAttributable() {
		return true
	}
	return ov.quarantineCandWindow > 0 || len(ov.abusiveEvents) > 0 || len(ov.onboardingFailures) > 0
}

// EscalateSwapLaunderingIfRisky applies the deterministic FR-12 escalation. Given the
// prior artifact's key and a provider-originated change, it moves the swap-laundering
// overlay (stable_provider_identity, model_id) to blocked:swap_laundering_suspected
// when the change is NOT an exempt continuity-proven reconnect or same-hash reload AND
// the prior per-key overlay carries active provider-attributable risk. Returns whether
// it escalated. A clean provider changing artifacts, or a benign warn/reconnect, does
// not escalate.
func (s *Store) EscalateSwapLaunderingIfRisky(priorKey ComputeIntegrityKey, ev ArtifactChangeEvent) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !ev.HashTokenizerOrGenerationChanged || ev.ContinuityProvenReconnect || ev.SameHashReload {
		return false
	}
	ov := s.overlays[priorKey.Overlay()]
	if !ov.priorOverlayCarriesRisk() {
		return false
	}
	scope := priorKey.Overlay().SwapLaunderingScope()
	sw := s.swaps[scope]
	if sw == nil {
		sw = &swapState{}
		s.swaps[scope] = sw
	}
	sw.blocked = true
	// Origin INHERITANCE (FR-3): a swap-laundering block is DERIVED from the prior
	// overlay's risk, so it inherits that overlay's origin. It must NOT launder a
	// telemetry_only source into an enforce_preserved money-blocking state merely because
	// the artifact change happened under enforce — only a fresh enforce-mode adjudication
	// (a new enforce-mode quarantine) creates enforce_preserved risk. When the source is
	// accumulator-only with no recorded origin, default to telemetry_only (conservative).
	if ov.origin.Known() {
		sw.origin = ov.origin
	} else {
		sw.origin = OriginTelemetryOnly
	}
	return true
}

// WriteTombstoneIfAdverse writes an adverse-state lineage tombstone at swap-laundering
// scope when a corpus/threshold rotation produces a new overlay key while the prior
// overlay carries an active quarantine/block (FR-10 clear rule). While a tombstone is
// unresolved, the successor key regains eligibility only through the full FR-10 clear
// rule or dual-approved manual review — never the short FR-11 onboarding gate.
func (s *Store) WriteTombstoneIfAdverse(priorKey ComputeIntegrityKey) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	ov := s.overlays[priorKey.Overlay()]
	if ov == nil || !ov.state.IsAdverseOverlay() {
		return false
	}
	s.tombstones[priorKey.Overlay().TombstoneScope()] = true
	return true
}

// HasTombstone reports whether an unresolved adverse-state lineage tombstone exists
// for a key's tombstone scope (FR-10, FR-12).
func (s *Store) HasTombstone(key ComputeIntegrityKey) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.tombstones[key.Overlay().TombstoneScope()]
}

// SetOverlayAdverse forces an overlay adverse state (used by tests and by the verdict
// pipeline when a block is adjudicated). Origin defaults to enforce_preserved.
func (s *Store) SetOverlayAdverse(k OverlayKey, st State, origin AdjudicationOrigin) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ov := s.overlay(k)
	ov.state = st
	ov.origin = origin
}
