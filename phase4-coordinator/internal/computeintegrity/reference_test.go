package computeintegrity

import "testing"

// refFixtureEvent returns a well-formed, admissible trusted reference event. Tests
// mutate one axis to exercise a specific admission/independence/fault path.
func refFixtureEvent(id string) ReferenceEvent {
	return ReferenceEvent{
		ReferenceEventDigest:          "sha256:" + id,
		ReferenceSourceID:             "src-" + id,
		OperatorID:                    "op-" + id,
		FailureDomainID:               "fd-" + id,
		RuntimeBuildProvenanceDigest:  "build-" + id,
		GoldenFixtureValidationDigest: "golden-" + id,
		ModelID:                       "model-x",
		TargetModelHash:               "hash-x",
		TokenizerIdentity:             "tok-x",
		SamplerStage:                  SamplerStagePostSampler,
		SamplingProfile:               "temp-0.7",
		CorpusVersion:                 "corpus-1",
		ThresholdVersion:              "thr-1",
		HardwareRuntimeClass:          "m3-max",
		SignedCatalogHash:             "catalog-x",
		LoadedModelHash:               "catalog-x",
		CoordinatorControlled:         true,
		RefreshedAtUnixMS:             1000,
		Positions: []ReferencePosition{{
			PromptID: "p1", PositionIndex: 0,
			TopK: []int64{1, 2}, Full: ReferenceDistribution{1: 0.6, 2: 0.4},
		}},
	}
}

func refFixtureInput(refs ...ReferenceEvent) AdmissibilityInput {
	return AdmissibilityInput{
		References:         refs,
		CandidateTokenizer: "tok-x",
		MinQuorum:          2,
		FreshnessTTLMillis: 24 * 3600 * 1000,
		NowUnixMS:          1000,
		FaultThresholds:    ReferenceFaultThresholds{Median: 0.02, Position: 0.05},
	}
}

// AC-2: trusted reference admission, catalog/tokenizer match, independence, both
// runtime-build AND golden-fixture digests (non-substitutable), freshness, refresh.
func TestAC02_ReferenceAdmission(t *testing.T) {
	t.Run("two independent fresh references are admissible", func(t *testing.T) {
		if got := ComputeAdmissibility(refFixtureInput(refFixtureEvent("a"), refFixtureEvent("b"))); got != AdmissibilityAdmissible {
			t.Fatalf("want admissible, got %s", got)
		}
	})

	t.Run("loaded model hash must equal signed catalog hash", func(t *testing.T) {
		a, b := refFixtureEvent("a"), refFixtureEvent("b")
		a.LoadedModelHash = "different"
		if got := ComputeAdmissibility(refFixtureInput(a, b)); got != AdmissibilitySchemaInvalid {
			t.Fatalf("catalog mismatch: want schema_invalid, got %s", got)
		}
	})

	t.Run("tokenizer identity must match the candidate", func(t *testing.T) {
		a, b := refFixtureEvent("a"), refFixtureEvent("b")
		a.TokenizerIdentity = "other-tok"
		if got := ComputeAdmissibility(refFixtureInput(a, b)); got != AdmissibilitySchemaInvalid {
			t.Fatalf("tokenizer mismatch: want schema_invalid, got %s", got)
		}
	})

	t.Run("missing runtime-build provenance fails admission independently", func(t *testing.T) {
		a, b := refFixtureEvent("a"), refFixtureEvent("b")
		a.RuntimeBuildProvenanceDigest = ""
		if got := ComputeAdmissibility(refFixtureInput(a, b)); got != AdmissibilityProvMissing {
			t.Fatalf("missing runtime-build: want provenance_missing, got %s", got)
		}
	})

	t.Run("missing golden-fixture validation fails admission independently", func(t *testing.T) {
		a, b := refFixtureEvent("a"), refFixtureEvent("b")
		b.GoldenFixtureValidationDigest = ""
		if got := ComputeAdmissibility(refFixtureInput(a, b)); got != AdmissibilityProvMissing {
			t.Fatalf("missing golden fixture: want provenance_missing, got %s", got)
		}
	})

	t.Run("stale reference expires admissibility", func(t *testing.T) {
		a, b := refFixtureEvent("a"), refFixtureEvent("b")
		in := refFixtureInput(a, b)
		in.NowUnixMS = 1000 + 25*3600*1000 // > 24h since refresh
		if got := ComputeAdmissibility(in); got != AdmissibilityStaleReference {
			t.Fatalf("stale: want stale_reference, got %s", got)
		}
	})

	t.Run("references bound to a different covered key are inadmissible", func(t *testing.T) {
		a, b := refFixtureEvent("a"), refFixtureEvent("b")
		b.TargetModelHash = "hash-OTHER" // b covers a different artifact
		in := refFixtureInput(a, b)
		in.CoveredKey = a.coveredKey()
		if got := ComputeAdmissibility(in); got != AdmissibilitySchemaInvalid {
			t.Fatalf("cross-covered-key references: want schema_invalid, got %s", got)
		}
	})

	t.Run("references measured over different position sets are inadmissible", func(t *testing.T) {
		a, b := refFixtureEvent("a"), refFixtureEvent("b")
		b.Positions = []ReferencePosition{{PromptID: "DIFFERENT", PositionIndex: 3, TopK: []int64{1, 2}, Full: ReferenceDistribution{1: 0.6, 2: 0.4}}}
		if got := ComputeAdmissibility(refFixtureInput(a, b)); got != AdmissibilitySchemaInvalid {
			t.Fatalf("mismatched position sets: want schema_invalid, got %s", got)
		}
	})

	t.Run("empty-position reference events are inadmissible", func(t *testing.T) {
		a, b := refFixtureEvent("a"), refFixtureEvent("b")
		b.Positions = nil
		if got := ComputeAdmissibility(refFixtureInput(a, b)); got != AdmissibilitySchemaInvalid {
			t.Fatalf("empty positions: want schema_invalid, got %s", got)
		}
	})

	t.Run("changing runtime-build provenance makes the old identity a new source", func(t *testing.T) {
		// Two references identical except provenance digest are still independent iff
		// operator + failure domain also differ; changing provenance alone on a shared
		// operator/domain does NOT create independence.
		a := refFixtureEvent("a")
		b := refFixtureEvent("a") // same operator/failure-domain/provenance
		b.RuntimeBuildProvenanceDigest = "build-different"
		if ReferencesIndependent(a, b) {
			t.Fatal("shared operator+failure-domain must not be independent even with different builds")
		}
	})
}

// AC-15: reference quorum, disagreement, non-substitutable independence, and the
// agreed envelope.
func TestAC15_ReferenceQuorum(t *testing.T) {
	t.Run("missing quorum -> missing_quorum (maps to reference_missing)", func(t *testing.T) {
		if got := ComputeAdmissibility(refFixtureInput(refFixtureEvent("a"))); got != AdmissibilityMissingQuorum {
			t.Fatalf("single reference: want missing_quorum, got %s", got)
		}
		// And that status maps to reference_missing at settlement.
		c := payableCapture()
		c.ReferenceSetAdmissibilityStatus = AdmissibilityMissingQuorum
		if d := Evaluate(c); d.Reason != ReasonReferenceMissing {
			t.Fatalf("missing_quorum should settle reference_missing, got %s", d.Reason)
		}
	})

	t.Run("two references sharing runtime-build/kernel FAIL quorum even if both pass golden fixture", func(t *testing.T) {
		a := refFixtureEvent("a")
		b := refFixtureEvent("b")
		b.RuntimeBuildProvenanceDigest = a.RuntimeBuildProvenanceDigest // shared build
		// both still have (distinct) golden fixture digests, yet independence fails.
		if got := ComputeAdmissibility(refFixtureInput(a, b)); got != AdmissibilityIndepFailed {
			t.Fatalf("shared runtime-build: want independence_failed, got %s", got)
		}
	})

	t.Run("duplicate (same source) references cannot satisfy quorum", func(t *testing.T) {
		a := refFixtureEvent("a")
		if got := ComputeAdmissibility(refFixtureInput(a, a)); got != AdmissibilityIndepFailed {
			t.Fatalf("duplicate references: want independence_failed, got %s", got)
		}
	})

	t.Run("trusted-reference disagreement -> reference_fault", func(t *testing.T) {
		a := refFixtureEvent("a")
		b := refFixtureEvent("b")
		// Same measured position (p1,0) but b's distribution diverges hard from a's.
		b.Positions = []ReferencePosition{{PromptID: "p1", PositionIndex: 0, TopK: []int64{3, 4}, Full: ReferenceDistribution{3: 0.9, 4: 0.1}}}
		if got := ComputeAdmissibility(refFixtureInput(a, b)); got != AdmissibilityReferenceFault {
			t.Fatalf("disagreeing references: want reference_fault, got %s", got)
		}
	})

	t.Run("independence_failed and reference_fault both suppress drift and are not admissible", func(t *testing.T) {
		for _, st := range []AdmissibilityStatus{AdmissibilityIndepFailed, AdmissibilityReferenceFault} {
			c := payableCapture()
			c.State = StateQuarantinedDrift // a drift verdict must be suppressed by ref failure
			c.ReferenceSetAdmissibilityStatus = st
			d := Evaluate(c)
			if d.Reason != ReasonBlockedReferenceFault {
				t.Fatalf("%s + drift: want reference_fault reason (suppresses drift), got %s", st, d.Reason)
			}
		}
	})

	t.Run("auditor bundle lists all reference digests", func(t *testing.T) {
		got := AuditorReferenceDigests([]ReferenceEvent{refFixtureEvent("b"), refFixtureEvent("a")})
		if len(got) != 2 || got[0] != "sha256:a" || got[1] != "sha256:b" {
			t.Fatalf("auditor digests should be sorted+complete, got %v", got)
		}
	})
}
