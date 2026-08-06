package computeintegrity

import (
	"math"
	"sort"
)

// Trusted reference sources and reference-set admissibility (FR-5). The coordinator
// holds trusted references per covered key; enforce requires at least two independent
// fresh references, and provider verdicts use an agreed envelope across all active
// admissible references.

// ReferenceFaultThresholds are the reference-vs-reference fault floors (FR-5, FR-8).
type ReferenceFaultThresholds struct {
	Median   float64 // tau_reference_fault_median
	Position float64 // tau_reference_fault_position
}

// ReferencePosition is one reference's compact distribution at a measured position,
// used for the reference-vs-reference fault predicate (FR-5). PromptID/PositionIndex
// identify the corpus position so the quorum can be checked over the IDENTICAL
// measurement position set.
type ReferencePosition struct {
	PromptID      string
	PositionIndex int
	TopK          []int64
	Full          ReferenceDistribution
}

// ReferenceEvent is a coordinator-held trusted reference for a covered key (FR-5, §3).
type ReferenceEvent struct {
	ReferenceEventDigest          string
	ReferenceSourceID             string
	OperatorID                    string
	FailureDomainID               string // distinct physical host + power/network fault domain
	RuntimeBuildProvenanceDigest  string
	GoldenFixtureValidationDigest string
	// Covered key binding (must match across the quorum).
	ModelID              string
	TargetModelHash      string
	TokenizerIdentity    string
	SamplerStage         string
	SamplingProfile      string
	CorpusVersion        string
	ThresholdVersion     string
	HardwareRuntimeClass string
	// SignedCatalogHash is the signed catalog hash the loaded model hash must equal.
	SignedCatalogHash     string
	LoadedModelHash       string
	CoordinatorControlled bool
	RefreshedAtUnixMS     int64
	// Positions holds this reference's compact per-position distributions over the
	// identical measurement position set shared by the quorum (FR-5).
	Positions []ReferencePosition
}

// admissionWellFormed reports whether a reference event carries the required fields
// (FR-5 admission). A malformed event maps to schema_invalid.
func (r ReferenceEvent) admissionWellFormed() bool {
	return r.ReferenceEventDigest != "" && r.ReferenceSourceID != "" &&
		r.OperatorID != "" && r.FailureDomainID != "" &&
		r.ModelID != "" && r.TargetModelHash != "" && r.TokenizerIdentity != "" &&
		r.SamplerStage != "" && r.SamplingProfile != "" && r.CorpusVersion != "" &&
		r.ThresholdVersion != "" && r.HardwareRuntimeClass != ""
}

// catalogAndTokenizerOK verifies the loaded model hash equals the signed catalog
// hash and the reference runtime is coordinator-controlled (FR-5 admission).
func (r ReferenceEvent) catalogAndTokenizerOK(candidateTokenizer string) bool {
	return r.CoordinatorControlled && r.SignedCatalogHash != "" &&
		r.LoadedModelHash == r.SignedCatalogHash &&
		(candidateTokenizer == "" || r.TokenizerIdentity == candidateTokenizer)
}

// hasProvenance reports whether the reference carries BOTH the runtime-build
// provenance digest AND the signed golden-fixture validation digest (FR-5). The two
// are non-substitutable; a missing either fails admission as provenance_missing.
func (r ReferenceEvent) hasProvenance() bool {
	return r.RuntimeBuildProvenanceDigest != "" && r.GoldenFixtureValidationDigest != ""
}

// coveredKey returns the reference's covered-key 8-tuple (FR-5). Every reference
// counted toward a quorum must bind the same covered key.
func (r ReferenceEvent) coveredKey() ThresholdKey {
	return ThresholdKey{
		ModelID:              r.ModelID,
		TargetModelHash:      r.TargetModelHash,
		TokenizerIdentity:    r.TokenizerIdentity,
		SamplerStage:         r.SamplerStage,
		SamplingProfile:      r.SamplingProfile,
		CorpusVersion:        r.CorpusVersion,
		ThresholdVersion:     r.ThresholdVersion,
		HardwareRuntimeClass: r.HardwareRuntimeClass,
	}
}

// PositionSetDigest returns a digest over the reference's measurement position set
// (sorted (prompt_id, position_index) pairs) (FR-5). References counted toward a
// quorum must compare over the IDENTICAL position set, i.e. share this digest.
func (r ReferenceEvent) PositionSetDigest() (string, error) {
	pairs := make([][2]any, 0, len(r.Positions))
	for _, p := range r.Positions {
		pairs = append(pairs, [2]any{p.PromptID, p.PositionIndex})
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i][0].(string) != pairs[j][0].(string) {
			return pairs[i][0].(string) < pairs[j][0].(string)
		}
		return pairs[i][1].(int) < pairs[j][1].(int)
	})
	list := make([]any, len(pairs))
	for i, p := range pairs {
		list[i] = []any{p[0], p[1]}
	}
	// Normative preimage: the canonical JSON array [[prompt_id, position_index], ...],
	// not a wrapper object, so external auditors/producers compute the same digest.
	return jcsDigest(list)
}

// distributionsWellFormed reports whether every position's compact distribution is
// valid (FR-5): finite probabilities in [0,1], total mass not exceeding 1 (within the
// mass tolerance), top-K ids with no duplicates, and top-K a subset of the distribution
// support. A malformed reference distribution (e.g. total mass > 1) must be rejected as
// schema_invalid, never silently clamped to an admissible TV of 0.
func (r ReferenceEvent) distributionsWellFormed() bool {
	for _, pos := range r.Positions {
		if !noDuplicates(pos.TopK) {
			return false
		}
		var mass float64
		for _, p := range pos.Full {
			if math.IsNaN(p) || math.IsInf(p, 0) || p < 0 || p > 1 {
				return false
			}
			mass += p
		}
		if mass > 1+massConservationTolerance {
			return false
		}
		for _, id := range pos.TopK {
			if _, ok := pos.Full[id]; !ok {
				return false
			}
		}
	}
	return true
}

// ReferencesIndependent reports the closed FR-5 three-way independence predicate: two
// sources are independent iff ALL THREE of (a) distinct operator identity, (b)
// distinct hardware failure domain, and (c) distinct runtime-build/kernel provenance
// hold. None is substitutable: two references sharing a runtime build cannot count as
// two independent references even if both pass golden-fixture validation.
func ReferencesIndependent(a, b ReferenceEvent) bool {
	return a.OperatorID != b.OperatorID &&
		a.FailureDomainID != b.FailureDomainID &&
		a.RuntimeBuildProvenanceDigest != b.RuntimeBuildProvenanceDigest
}

// referencePairTVUpper computes the max/median tv_upper across shared positions for a
// pair of references over the union of their per-position top-K (FR-5), mirroring the
// FR-7 provider tv_upper math applied reference-vs-reference.
func referencePairTVUpper(a, b ReferenceEvent) (medianUpper, maxUpper float64) {
	// Align positions by their (prompt_id, position_index) identity, not slice order, so
	// two references listing the same positions in a different order are compared
	// position-for-position (FR-5).
	bByID := make(map[[2]any]ReferencePosition, len(b.Positions))
	for _, bp := range b.Positions {
		bByID[[2]any{bp.PromptID, bp.PositionIndex}] = bp
	}
	uppers := make([]float64, 0, len(a.Positions))
	for _, ap := range a.Positions {
		bp, ok := bByID[[2]any{ap.PromptID, ap.PositionIndex}]
		if !ok {
			continue // positions not in both references are not comparable.
		}
		s := numericUnion(ap.TopK, bp.TopK)
		var aMass, bMass, diff float64
		for _, t := range s {
			pa := ap.Full[t]
			pb := bp.Full[t]
			aMass += pa
			bMass += pb
			diff += math.Abs(pa - pb)
		}
		aTail := math.Max(0, 1.0-aMass)
		bTail := math.Max(0, 1.0-bMass)
		upper := 0.5 * (diff + aTail + bTail)
		uppers = append(uppers, upper)
		if upper > maxUpper {
			maxUpper = upper
		}
	}
	return canonicalMedian(uppers), maxUpper
}

// PairInReferenceFault reports whether a reference pair is in reference_fault (FR-5):
// median(tv_upper) >= tau_reference_fault_median OR any position
// tv_upper >= tau_reference_fault_position.
func PairInReferenceFault(a, b ReferenceEvent, ft ReferenceFaultThresholds) bool {
	med, mx := referencePairTVUpper(a, b)
	return med >= ft.Median || mx >= ft.Position
}

// AdmissibilityInput bundles the inputs for ComputeAdmissibility.
type AdmissibilityInput struct {
	References         []ReferenceEvent
	CandidateTokenizer string
	// CoveredKey is the covered key every reference must bind (FR-5). Zero value skips
	// the check (observe/telemetry callers), but enforce callers MUST set it.
	CoveredKey         ThresholdKey
	MinQuorum          int // enforce requires >= 2
	FreshnessTTLMillis int64
	NowUnixMS          int64
	FaultThresholds    ReferenceFaultThresholds
}

// ComputeAdmissibility computes the reference-set admissibility status for a covered
// key (FR-5). The status is a single closed value; only Admissible can support a
// payable verified/warn row. Checks are ordered from most-structural to most-specific.
func ComputeAdmissibility(in AdmissibilityInput) AdmissibilityStatus {
	// Fail closed on a misconfigured admissibility request: enforce requires a quorum of
	// at least two independent references and a positive freshness TTL; a caller that
	// omits these must never yield admissible.
	if in.MinQuorum < 2 {
		return AdmissibilityMissingQuorum
	}
	if in.FreshnessTTLMillis <= 0 {
		return AdmissibilityStaleReference
	}
	var wantPosDigest string
	// Schema: every event must be well-formed, bind the covered key, carry a non-empty
	// position set, and compare over the IDENTICAL measurement position set.
	for i, r := range in.References {
		if !r.admissionWellFormed() || !r.catalogAndTokenizerOK(in.CandidateTokenizer) {
			return AdmissibilitySchemaInvalid
		}
		if (in.CoveredKey != ThresholdKey{}) && r.coveredKey() != in.CoveredKey {
			return AdmissibilitySchemaInvalid // reference bound to a different covered key.
		}
		if len(r.Positions) == 0 || !r.distributionsWellFormed() {
			return AdmissibilitySchemaInvalid // empty or malformed distributions cannot be compared.
		}
		pd, err := r.PositionSetDigest()
		if err != nil {
			return AdmissibilitySchemaInvalid
		}
		if i == 0 {
			wantPosDigest = pd
		} else if pd != wantPosDigest {
			return AdmissibilitySchemaInvalid // references measured over different positions.
		}
	}
	// Provenance: every event must carry BOTH runtime-build provenance AND golden
	// fixture validation (non-substitutable).
	for _, r := range in.References {
		if !r.hasProvenance() {
			return AdmissibilityProvMissing
		}
	}
	if len(in.References) < in.MinQuorum {
		return AdmissibilityMissingQuorum
	}
	// Freshness: keep only fresh references.
	fresh := make([]ReferenceEvent, 0, len(in.References))
	for _, r := range in.References {
		if in.FreshnessTTLMillis <= 0 || in.NowUnixMS-r.RefreshedAtUnixMS <= in.FreshnessTTLMillis {
			fresh = append(fresh, r)
		}
	}
	if len(fresh) < in.MinQuorum {
		// References exist but too few are fresh -> stale, not missing.
		return AdmissibilityStaleReference
	}
	// Independence: need at least MinQuorum sources that are pairwise independent.
	if maxIndependentSet(fresh) < in.MinQuorum {
		return AdmissibilityIndepFailed
	}
	// Reference-vs-reference fault: any admissible pair in reference_fault fails closed.
	for i := 0; i < len(fresh); i++ {
		for j := i + 1; j < len(fresh); j++ {
			if PairInReferenceFault(fresh[i], fresh[j], in.FaultThresholds) {
				return AdmissibilityReferenceFault
			}
		}
	}
	return AdmissibilityAdmissible
}

// maxIndependentSet returns the size of the largest set of pairwise-independent
// references (FR-5). Because independence requires three distinct discriminators,
// a greedy clique search over a small fleet (N<=4 per max_active_references) suffices.
func maxIndependentSet(refs []ReferenceEvent) int {
	n := len(refs)
	best := 0
	// Bounded fleet (<=4); enumerate subsets.
	for mask := 1; mask < (1 << n); mask++ {
		ok := true
		members := make([]int, 0, n)
		for i := 0; i < n; i++ {
			if mask&(1<<i) != 0 {
				members = append(members, i)
			}
		}
		for a := 0; a < len(members) && ok; a++ {
			for b := a + 1; b < len(members); b++ {
				if !ReferencesIndependent(refs[members[a]], refs[members[b]]) {
					ok = false
					break
				}
			}
		}
		if ok && len(members) > best {
			best = len(members)
		}
	}
	return best
}

// AuditorReferenceDigests returns the sorted set of reference event digests used for
// a verdict, for inclusion in auditor bundles (FR-5, FR-13).
func AuditorReferenceDigests(refs []ReferenceEvent) []string {
	out := make([]string, 0, len(refs))
	for _, r := range refs {
		out = append(out, r.ReferenceEventDigest)
	}
	sort.Strings(out)
	return out
}
