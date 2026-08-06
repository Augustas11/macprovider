package computeintegrity

// Capture is the immutable request-start compute-integrity state captured for
// every covered paid request attempt (FR-4). Settlement is a pure function of this
// captured state (never of the live provider/breaker state at settlement time), so
// that SPEC-022 request-start immutability holds: a later change to policy, breaker,
// or provider state MUST NOT retroactively change an already-admitted attempt.
//
// A missing or unreadable value in any load-bearing field fails closed as
// compute_integrity_unreadable (see SettlementDecision).
type Capture struct {
	// Identity / key fields.
	StableProviderIdentity string
	ProviderID             string
	AssignedID             string
	ModelID                string
	TargetModelHash        string
	TokenizerIdentity      string
	SamplerStage           string
	SamplingProfile        string
	CorpusVersion          string
	ThresholdVersion       string
	HardwareRuntimeClass   string
	TargetGeneration       int64

	// Coverage.
	SamplingProfileCoverageMode SamplingProfileCoverageMode
	// CoveredSamplingProfileSetDigest is the SHA-256 over the JCS-canonical sorted
	// covered-profile list for an all-profile window; empty for a per-profile window.
	CoveredSamplingProfileSetDigest string
	// RequestSamplingProfileCovered reports whether the buyer request's sampling
	// profile is a member of the captured covered window with its own fresh satisfied
	// sub-window (FR-10 all-profile grid; FR-11 coverage). False => uncovered profile.
	RequestSamplingProfileCovered bool

	// HardwareRuntimeClassDigest binds the covered class the state was measured under.
	// A mismatch vs the route snapshot's provider class fails closed as
	// uncovered_profile.
	HardwareRuntimeClassDigest       string
	RouteSnapshotHardwareClassDigest string

	// Composite SPEC-022 policy snapshot (FR-3, FR-4). Settlement reads this to decide
	// whether SPEC-022 was itself in enforce for the request's coverage.
	Spec022PolicyVersion       string
	Spec022PolicyMode          string
	Spec022CoverageDigest      string
	Spec022EffectiveEnforce    bool
	Spec022RouteSnapshotDigest string

	// SPEC-036 policy snapshot.
	ComputeIntegrityPolicyVersion string
	ComputeIntegrityPolicyMode    Mode
	ComputeIntegrityPolicyDigest  string

	// The captured compute-integrity state and its metadata.
	State       State
	ExpiryCause ExpiryCause // set only when State == StateExpired

	// AdjudicationOrigin of any captured overlay/breaker adverse state (FR-3 matrix).
	AdjudicationOrigin AdjudicationOrigin

	// Reference-set admissibility (FR-4).
	ReferenceSetAdmissibilityStatus AdmissibilityStatus
	ReferenceSetAdmissibilityDigest string
	ReferenceQuorumCount            int
	ReferenceFaultCheckVersion      string
	ReferenceSetID                  string
	ReferenceEventDigests           []string

	// Circuit-breaker capture (FR-4, FR-16). CircuitBreakerActive is a non-null bool
	// on every covered enforce row; CircuitBreakerScope is present exactly when
	// active. BreakerFieldsPresent must be true — a missing active/scope pair fails
	// closed as unreadable.
	CircuitBreakerActive bool
	CircuitBreakerScope  CircuitBreakerScope
	BreakerFieldsPresent bool

	WindowID            string
	SignedCatalogDigest string
	CapturedAtUnixMS    int64

	// Unreadable marks a capture whose key fields failed to verify against the route
	// snapshot / request sampler at settlement, or that carries a missing/malformed
	// load-bearing field. Settlement fails such a row closed as
	// compute_integrity_unreadable at the highest precedence.
	Unreadable bool
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

// hardwareClassMatches reports whether the captured hardware_runtime_class digest
// equals the route snapshot's provider class digest (FR-4). A mismatch fails closed
// as uncovered_profile. When the route snapshot digest is empty we treat it as an
// unreadable capture rather than a silent pass.
func (c Capture) hardwareClassMatches() bool {
	return c.HardwareRuntimeClassDigest != "" &&
		c.HardwareRuntimeClassDigest == c.RouteSnapshotHardwareClassDigest
}
