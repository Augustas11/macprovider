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
// used for the reference-vs-reference fault predicate (FR-5).
type ReferencePosition struct {
	TopK []int64
	Full ReferenceDistribution
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
	n := len(a.Positions)
	if len(b.Positions) < n {
		n = len(b.Positions)
	}
	uppers := make([]float64, 0, n)
	for i := 0; i < n; i++ {
		s := numericUnion(a.Positions[i].TopK, b.Positions[i].TopK)
		var aMass, bMass, diff float64
		for _, t := range s {
			ap := a.Positions[i].Full[t]
			bp := b.Positions[i].Full[t]
			aMass += ap
			bMass += bp
			diff += math.Abs(ap - bp)
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
	MinQuorum          int // enforce requires >= 2
	FreshnessTTLMillis int64
	NowUnixMS          int64
	FaultThresholds    ReferenceFaultThresholds
}

// ComputeAdmissibility computes the reference-set admissibility status for a covered
// key (FR-5). The status is a single closed value; only Admissible can support a
// payable verified/warn row. Checks are ordered from most-structural to most-specific.
func ComputeAdmissibility(in AdmissibilityInput) AdmissibilityStatus {
	// Schema: every event must be well-formed.
	for _, r := range in.References {
		if !r.admissionWellFormed() || !r.catalogAndTokenizerOK(in.CandidateTokenizer) {
			return AdmissibilitySchemaInvalid
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
