package computeintegrity

// Capture is the immutable request-start compute-integrity state captured for
// every covered paid request attempt (FR-4). Settlement is a pure function of this
// captured state (never of the live provider/breaker state at settlement time), so
// that SPEC-022 request-start immutability holds: a later change to policy, breaker,
// or provider state MUST NOT retroactively change an already-admitted attempt.
//
// A missing or unreadable value in any load-bearing field fails closed as
// compute_integrity_unreadable (see SettlementDecision).
// The json tags define the closed snake_case FR-4 captured-state object used for the
// FR-13 request-start snapshot digest. Fields that are settlement-verification inputs
// rather than part of the captured object (the route-snapshot class digest, the
// derived profile-coverage boolean, and the internal breaker-present/unreadable flags)
// are excluded with json:"-".
type Capture struct {
	// Identity / key fields.
	StableProviderIdentity string `json:"stable_provider_identity"`
	ProviderID             string `json:"provider_id"`
	AssignedID             string `json:"assigned_id"`
	ModelID                string `json:"model_id"`
	TargetModelHash        string `json:"target_model_hash"`
	TokenizerIdentity      string `json:"tokenizer_identity"`
	SamplerStage           string `json:"sampler_stage"`
	SamplingProfile        string `json:"sampling_profile"`
	CorpusVersion          string `json:"corpus_version"`
	ThresholdVersion       string `json:"threshold_version"`
	HardwareRuntimeClass   string `json:"hardware_runtime_class"`
	TargetGeneration       int64  `json:"target_generation"`

	// Coverage.
	SamplingProfileCoverageMode SamplingProfileCoverageMode `json:"sampling_profile_coverage_mode"`
	// CoveredSamplingProfileSetDigest is the SHA-256 over the JCS-canonical sorted
	// covered-profile list for an all-profile window; empty for a per-profile window.
	CoveredSamplingProfileSetDigest string `json:"covered_sampling_profile_set_digest"`
	// RequestSamplingProfileCovered is a settlement-verification input, not part of the
	// captured object.
	RequestSamplingProfileCovered bool `json:"-"`

	// HardwareRuntimeClassDigest binds the covered class the state was measured under.
	HardwareRuntimeClassDigest string `json:"hardware_runtime_class_digest"`
	// RouteSnapshotHardwareClassDigest is the route snapshot's provider class (compared
	// against the capture), not part of the captured object.
	RouteSnapshotHardwareClassDigest string `json:"-"`

	// Composite SPEC-022 policy snapshot (FR-3, FR-4).
	Spec022PolicyVersion       string `json:"spec022_policy_version"`
	Spec022PolicyMode          string `json:"spec022_policy_mode"`
	Spec022CoverageDigest      string `json:"spec022_coverage_digest"`
	Spec022EffectiveEnforce    bool   `json:"spec022_effective_enforce"`
	Spec022RouteSnapshotDigest string `json:"spec022_route_snapshot_digest"`

	// SPEC-036 policy snapshot.
	ComputeIntegrityPolicyVersion string `json:"compute_integrity_policy_version"`
	ComputeIntegrityPolicyMode    Mode   `json:"compute_integrity_policy_mode"`
	ComputeIntegrityPolicyDigest  string `json:"compute_integrity_policy_digest"`

	// The captured compute-integrity state and its metadata.
	State       State       `json:"compute_integrity_state"`
	ExpiryCause ExpiryCause `json:"expiry_cause,omitempty"`

	AdjudicationOrigin AdjudicationOrigin `json:"adjudication_origin,omitempty"`

	// Reference-set admissibility (FR-4).
	ReferenceSetAdmissibilityStatus AdmissibilityStatus `json:"reference_set_admissibility_status"`
	ReferenceSetAdmissibilityDigest string              `json:"reference_set_admissibility_digest"`
	ReferenceQuorumCount            int                 `json:"reference_quorum_count"`
	ReferenceFaultCheckVersion      string              `json:"reference_fault_check_version"`
	ReferenceSetID                  string              `json:"reference_set_id"`
	ReferenceEventDigests           []string            `json:"reference_event_digests"`

	// Circuit-breaker capture (FR-4, FR-16).
	CircuitBreakerActive bool                `json:"circuit_breaker_active"`
	CircuitBreakerScope  CircuitBreakerScope `json:"circuit_breaker_scope,omitempty"`
	// BreakerFieldsPresent is an internal consistency flag, not part of the captured
	// object.
	BreakerFieldsPresent bool `json:"-"`

	WindowID            string `json:"compute_integrity_window_id"`
	SignedCatalogDigest string `json:"signed_catalog_digest"`
	CapturedAtUnixMS    int64  `json:"captured_at"`

	// Unreadable is an internal settlement-verification flag, not part of the captured
	// object.
	Unreadable bool `json:"-"`
}

// breakerConsistent reports whether the captured circuit-breaker fields are
// internally consistent (FR-4): active/scope must both be present, scope non-null
// and known exactly when active is true, and null (empty) when active is false.
func (c Capture) breakerConsistent() bool {
	if !c.BreakerFieldsPresent {
		return false
	}
	if c.CircuitBreakerActive {
		return c.CircuitBreakerScope.Known()
	}
	return c.CircuitBreakerScope == ""
}

// structurallyUnreadable reports whether the capture is malformed in a way that
// prevents trusting ANY field — an unknown state/admissibility/expiry/coverage-mode
// enum value, an inconsistent breaker, an adverse overlay or active breaker whose
// adjudication_origin is missing/unknown, or the explicit Unreadable flag. Such a
// capture fails closed to compute_integrity_unreadable in EVERY mode (FR-3): a
// preserved-adverse row rolled back to warn_only must not pass through payable just
// because its metadata is corrupt.
func (c Capture) structurallyUnreadable() bool {
	if c.Unreadable || !c.breakerConsistent() || !c.State.Known() ||
		!c.ReferenceSetAdmissibilityStatus.Known() || !c.SamplingProfileCoverageMode.Known() {
		return true
	}
	// A missing hardware-class digest on either side (capture or route snapshot) is an
	// unreadable capture, not merely an uncovered profile — the class binding cannot be
	// verified at all.
	if c.HardwareRuntimeClassDigest == "" || c.RouteSnapshotHardwareClassDigest == "" {
		return true
	}
	if c.State == StateExpired && !c.ExpiryCause.Known() {
		return true
	}
	// An adverse overlay state or an active breaker MUST carry a known adjudication
	// origin; a missing/unknown origin on money-affecting adverse state is unreadable.
	if (c.State.IsAdverseOverlay() || c.CircuitBreakerActive) && !c.AdjudicationOrigin.Known() {
		return true
	}
	return false
}

// compositeBindingUnreadable reports whether the captured composite SPEC-022 binding
// is missing/unreadable (FR-4). A covered row always carries the binding; if it is
// absent the capture is malformed and MUST fail closed as compute_integrity_unreadable
// — a `spec022_effective_enforce=false` that arises from a missing binding must NOT be
// mistaken for a legitimate "SPEC-022 not enforcing" and paid through.
func (c Capture) compositeBindingUnreadable() bool {
	return c.Spec022PolicyVersion == "" || c.Spec022PolicyMode == "" ||
		c.Spec022CoverageDigest == "" || c.Spec022RouteSnapshotDigest == ""
}

// missingEnforceEvidence reports whether a captured row that claims a payable
// verified/warn positive state is missing a load-bearing FR-4 field required for
// enforce settlement. It requires the composite SPEC-022 coverage digest, the SPEC-036
// policy digest, the v0.1 covered sampler stage, AND complete, consistent
// reference-set admissibility evidence (a two-reference independent quorum must be
// provable): a non-empty reference set id, admissibility digest, and fault-check
// version; a quorum count of at least two; and at least that many non-empty reference
// event digests. Such a row is not payable and settles compute_integrity_unreadable.
func (c Capture) missingEnforceEvidence() bool {
	if c.SamplerStage != SamplerStagePostSampler {
		return true
	}
	// Core covered-key identity must be present.
	if c.StableProviderIdentity == "" || c.ModelID == "" || c.TargetModelHash == "" ||
		c.TokenizerIdentity == "" || c.SamplingProfile == "" || c.CorpusVersion == "" ||
		c.ThresholdVersion == "" || c.HardwareRuntimeClass == "" || c.TargetGeneration < 0 {
		return true
	}
	// The positive state must be provably tied to the SPEC-036 policy, the signed
	// catalog entry, the measurement window, and a capture time at request start.
	if c.ComputeIntegrityPolicyVersion == "" || c.ComputeIntegrityPolicyDigest == "" ||
		c.Spec022CoverageDigest == "" || c.SignedCatalogDigest == "" ||
		c.WindowID == "" || c.CapturedAtUnixMS <= 0 {
		return true
	}
	if c.ReferenceSetID == "" || c.ReferenceSetAdmissibilityDigest == "" ||
		c.ReferenceFaultCheckVersion == "" {
		return true
	}
	if c.ReferenceQuorumCount < 2 || len(c.ReferenceEventDigests) < c.ReferenceQuorumCount {
		return true
	}
	// Require at least ReferenceQuorumCount DISTINCT non-empty reference event digests:
	// a repeated digest is one reference, not a provable independent quorum.
	seen := make(map[string]struct{}, len(c.ReferenceEventDigests))
	for _, d := range c.ReferenceEventDigests {
		if d == "" {
			return true
		}
		seen[d] = struct{}{}
	}
	if len(seen) < c.ReferenceQuorumCount {
		return true
	}
	return false
}

// hardwareClassMatches reports whether the captured hardware_runtime_class digest
// equals the route snapshot's provider class digest (FR-4). A mismatch fails closed
// as uncovered_profile. When the route snapshot digest is empty we treat it as an
// unreadable capture rather than a silent pass.
func (c Capture) hardwareClassMatches() bool {
	return c.HardwareRuntimeClassDigest != "" &&
		c.HardwareRuntimeClassDigest == c.RouteSnapshotHardwareClassDigest
}
