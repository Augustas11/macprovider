package computeintegrity

const (
	StatusType    = "compute_integrity_status_v1"
	StatusSchema  = "compute_integrity_status_v1"
	StatusCopyV1  = "SPEC-036 v0.1 is an overt distribution-drift readiness signal against approved references. It is not cryptographic proof of honest computation, not hardware integrity, not runtime binary integrity, and not covert attestation."
	ReadinessNone = "no_state"
)

const manualReviewGuidance = "; use the provider appeal/manual-review path for review"

// StatusInput carries the request-independent metadata needed to expose current
// compute-integrity readiness without exporting prompts, outputs, or raw probe
// payloads.
type StatusInput struct {
	Policy Policy
	NowMs  int64

	InvalidationCause        ExpiryCause
	AdmissibilityStatus      AdmissibilityStatus
	Spec022EffectiveEnforce  bool
	CircuitBreakerActive     bool
	CircuitBreakerScope      CircuitBreakerScope
	CircuitBreakerOrigin     AdjudicationOrigin
	ComputePolicyDigest      string
	ReferenceSetID           string
	ReferenceSetDigest       string
	ReferenceEventDigests    []string
	ThresholdRecordDigest    string
	LatestCanaryDigests      []string
	RequestStartSnapshotHash string
	WindowID                 string
	EvaluatedAtUnixMS        int64
}

// StatusSnapshot is the sanitized operator/provider status object for one
// covered key. It intentionally exposes only enum values, policy/key metadata,
// and digest identifiers. It MUST NOT contain raw prompt or output material.
type StatusSnapshot struct {
	Type          string `json:"type"`
	SchemaVersion string `json:"schema_version"`

	ProviderID string           `json:"provider_id"`
	CoveredKey StatusCoveredKey `json:"covered_key"`

	PolicyVersion string `json:"compute_integrity_policy_version,omitempty"`
	PolicyMode    Mode   `json:"compute_integrity_policy_mode"`
	PolicyDigest  string `json:"compute_integrity_policy_digest,omitempty"`
	PolicyEnabled int64  `json:"compute_integrity_policy_enabled_at,omitempty"`

	State                 State                 `json:"compute_integrity_state"`
	ExpiryCause           ExpiryCause           `json:"expiry_cause,omitempty"`
	AdjudicationOrigin    AdjudicationOrigin    `json:"adjudication_origin,omitempty"`
	AdmissibilityStatus   AdmissibilityStatus   `json:"reference_set_admissibility_status,omitempty"`
	CircuitBreakerActive  bool                  `json:"circuit_breaker_active"`
	CircuitBreakerScope   CircuitBreakerScope   `json:"circuit_breaker_scope,omitempty"`
	SettlementEffect      string                `json:"settlement_effect"`
	ProviderReadiness     string                `json:"provider_readiness"`
	ProviderStatusMessage string                `json:"provider_status_message"`
	Evidence              StatusEvidenceDigests `json:"evidence"`
	EvaluatedAtUnixMS     int64                 `json:"evaluated_at_unix_ms"`
	Disclosure            string                `json:"disclosure"`
}

type StatusCoveredKey struct {
	StableProviderIdentity string `json:"stable_provider_identity,omitempty"`
	AssignedID             string `json:"assigned_id,omitempty"`
	ModelID                string `json:"model_id,omitempty"`
	TargetModelHash        string `json:"target_model_hash,omitempty"`
	TokenizerIdentity      string `json:"tokenizer_identity,omitempty"`
	SamplerStage           string `json:"sampler_stage,omitempty"`
	TargetGeneration       int64  `json:"target_generation"`
	SamplingProfile        string `json:"sampling_profile,omitempty"`
	CorpusVersion          string `json:"corpus_version,omitempty"`
	ThresholdVersion       string `json:"threshold_version,omitempty"`
	HardwareRuntimeClass   string `json:"hardware_runtime_class,omitempty"`
	WindowID               string `json:"compute_integrity_window_id,omitempty"`
}

type StatusEvidenceDigests struct {
	ThresholdRecordDigest    string   `json:"threshold_record_digest,omitempty"`
	ReferenceSetID           string   `json:"reference_set_id,omitempty"`
	ReferenceSetDigest       string   `json:"reference_set_admissibility_digest,omitempty"`
	ReferenceEventDigests    []string `json:"reference_event_digests"`
	LatestCanaryDigests      []string `json:"latest_canary_digests"`
	RequestStartSnapshotHash string   `json:"request_start_snapshot_digest,omitempty"`
}

// StatusForKey resolves and describes the current sanitized status for a covered
// key. It is a read-only projection over Store state.
func (s *Store) StatusForKey(key ComputeIntegrityKey, in StatusInput) StatusSnapshot {
	state, expiry, origin := s.peekStatusState(key, in)
	if state == StateExpired && expiry == "" {
		expiry = in.InvalidationCause
	}
	evaluatedAt := in.EvaluatedAtUnixMS
	if evaluatedAt == 0 {
		evaluatedAt = in.NowMs
	}
	effect, readiness, message := describeStatusEffect(state, in.Policy.Mode, in.Spec022EffectiveEnforce, origin, in.CircuitBreakerActive, in.CircuitBreakerOrigin)
	return StatusSnapshot{
		Type:          StatusType,
		SchemaVersion: StatusSchema,
		ProviderID:    key.ProviderID,
		CoveredKey: StatusCoveredKey{
			StableProviderIdentity: key.StableProviderIdentity,
			AssignedID:             key.AssignedID,
			ModelID:                key.ModelID,
			TargetModelHash:        key.TargetModelHash,
			TokenizerIdentity:      key.TokenizerIdentity,
			SamplerStage:           key.SamplerStage,
			TargetGeneration:       key.TargetGeneration,
			SamplingProfile:        key.SamplingProfile,
			CorpusVersion:          key.CorpusVersion,
			ThresholdVersion:       key.ThresholdVersion,
			HardwareRuntimeClass:   key.HardwareRuntimeClass,
			WindowID:               in.WindowID,
		},
		PolicyVersion:         in.Policy.PolicyVersion,
		PolicyMode:            in.Policy.Mode,
		PolicyDigest:          in.ComputePolicyDigest,
		PolicyEnabled:         in.Policy.EnabledAt,
		State:                 state,
		ExpiryCause:           expiry,
		AdjudicationOrigin:    origin,
		AdmissibilityStatus:   in.AdmissibilityStatus,
		CircuitBreakerActive:  in.CircuitBreakerActive,
		CircuitBreakerScope:   in.CircuitBreakerScope,
		SettlementEffect:      effect,
		ProviderReadiness:     readiness,
		ProviderStatusMessage: message,
		Evidence: StatusEvidenceDigests{
			ThresholdRecordDigest:    in.ThresholdRecordDigest,
			ReferenceSetID:           in.ReferenceSetID,
			ReferenceSetDigest:       in.ReferenceSetDigest,
			ReferenceEventDigests:    append([]string(nil), in.ReferenceEventDigests...),
			LatestCanaryDigests:      append([]string(nil), in.LatestCanaryDigests...),
			RequestStartSnapshotHash: in.RequestStartSnapshotHash,
		},
		EvaluatedAtUnixMS: evaluatedAt,
		Disclosure:        StatusCopyV1,
	}
}

func describeStatusEffect(state State, mode Mode, spec022Enforce bool, origin AdjudicationOrigin, breakerActive bool, breakerOrigin AdjudicationOrigin) (string, string, string) {
	enforceActive := mode == ModeEnforce && spec022Enforce
	if breakerActive && EffectiveAdverseState(mode, spec022Enforce, breakerOrigin, attribProviderOrBreaker) {
		return "blocks_new_paid_admission", "blocked", "covered paid admission is paused for this compute-integrity scope" + manualReviewGuidance
	}
	if state.IsAdverseOverlay() {
		attrib := attribCoordinator
		if state.IsProviderAttributable() {
			attrib = attribProviderOrBreaker
		}
		if EffectiveAdverseState(mode, spec022Enforce, origin, attrib) {
			return "blocks_new_paid_admission", "blocked", "covered paid admission is paused for this compute-integrity key" + manualReviewGuidance
		}
		return "telemetry_only", readinessForAdverseTelemetry(state), "compute-integrity state is visible as readiness telemetry only"
	}
	switch state {
	case StateVerified:
		if enforceActive {
			return "admits_when_other_gates_pass", "ready", "compute-integrity readiness is verified for this covered key"
		}
		return "telemetry_only", "ready", "compute-integrity readiness is verified telemetry only"
	case StateWarn:
		if enforceActive {
			return "admits_warn_when_other_gates_pass", "warn", "compute-integrity readiness is warn for this covered key"
		}
		return "telemetry_only", "warn", "compute-integrity warn state is readiness telemetry only"
	case StateExpired:
		if enforceActive {
			return "blocks_new_paid_admission", "expired", "compute-integrity evidence is stale or expired" + manualReviewGuidance + " or submit fresh evidence"
		}
		return "would_block_in_enforce", "expired", "compute-integrity state is stale or expired and needs fresh evidence"
	case StatePending:
		if enforceActive {
			return "blocks_new_paid_admission", "pending", "compute-integrity evidence is pending or incomplete" + manualReviewGuidance
		}
		return "would_block_in_enforce", "pending", "compute-integrity readiness is pending until enough fresh evidence exists"
	case StateUnknown:
		if enforceActive {
			return "blocks_new_paid_admission", ReadinessNone, "compute-integrity evidence is unavailable for this key" + manualReviewGuidance
		}
		return "would_block_in_enforce", ReadinessNone, "compute-integrity has no current state for this covered key"
	default:
		if enforceActive {
			return "blocks_new_paid_admission", "unknown", "compute-integrity status is unavailable or unsupported" + manualReviewGuidance
		}
		return "would_block_in_enforce", "unknown", "compute-integrity state is unreadable or unsupported"
	}
}

func readinessForAdverseTelemetry(state State) string {
	if state == StateQuarantinedDrift {
		return "quarantined"
	}
	if state.IsBlocked() {
		return "blocked"
	}
	return "warn"
}

func (s *Store) peekStatusState(key ComputeIntegrityKey, in StatusInput) (State, ExpiryCause, AdjudicationOrigin) {
	s.mu.Lock()
	defer s.mu.Unlock()

	mode := in.Policy.Mode
	spec022 := in.Spec022EffectiveEnforce
	origin := deriveOrigin(mode, spec022)

	if sw := s.swaps[key.Overlay().SwapLaunderingScope()]; sw != nil && sw.blocked {
		return StateBlockedSwapLaunder, "", sw.origin
	}
	if ov := s.overlays[key.Overlay()]; ov != nil {
		if ov.state.IsAdverseOverlay() {
			return ov.state, "", ov.origin
		}
		if s.windowMeetsQuarantine(key.Window(), in.Policy, in.NowMs) {
			if ov.origin.Known() {
				return StateQuarantinedDrift, "", ov.origin
			}
			return StateQuarantinedDrift, "", origin
		}
	} else if s.windowMeetsQuarantine(key.Window(), in.Policy, in.NowMs) {
		return StateQuarantinedDrift, "", origin
	}

	if mode == ModeEnforce && spec022 {
		switch in.AdmissibilityStatus {
		case AdmissibilityMissingQuorum:
			return StateBlockedRefMissing, "", OriginEnforcePreserved
		case AdmissibilityReferenceFault, AdmissibilityIndepFailed, AdmissibilityProvMissing:
			return StateBlockedRefFault, "", OriginEnforcePreserved
		}
	}

	if in.InvalidationCause != "" {
		return StateExpired, in.InvalidationCause, ""
	}

	ws := s.windows[key.Window()]
	if ws == nil || len(ws.canaries) == 0 {
		if ws != nil && ws.hasPending {
			return StatePending, "", ""
		}
		return StateUnknown, "", ""
	}
	elig := eligible(ws, in.Policy, in.NowMs)
	if len(elig) < in.Policy.MinWindowCanaries {
		return StatePending, "", ""
	}
	newest := elig[len(elig)-1]
	ttlMs := int64(in.Policy.PositiveStateFreshnessTTLHrs) * 3600 * 1000
	if ttlMs > 0 && in.NowMs-newest.atMs > ttlMs {
		return StateExpired, ExpiryWindowTTLExpired, ""
	}
	if in.AdmissibilityStatus != AdmissibilityAdmissible || s.windowMeetsQuarantine(key.Window(), in.Policy, in.NowMs) {
		return StatePending, "", ""
	}
	if s.verifiedPassRule(key.Window(), in.Policy, in.NowMs) {
		return StateVerified, "", ""
	}
	if elig[len(elig)-1].verdict == VerdictWarn {
		return StateWarn, "", ""
	}
	return StatePending, "", ""
}
