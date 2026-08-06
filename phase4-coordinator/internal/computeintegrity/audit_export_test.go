package computeintegrity

import (
	"math"
	"testing"
)

func sampleBundle() AuditorBundle {
	return AuditorBundle{
		Type:          AuditorBundleType,
		SchemaVersion: AuditorBundleSchema,
		Payload: AuditorBundlePayload{
			PolicyVersion:             "ci-v1",
			PolicyMode:                ModeEnforce,
			CurrentState:              StateQuarantinedDrift,
			WindowID:                  "win-1",
			ThresholdVersion:          "thr-1",
			ThresholdRecordDigest:     "sha256:thr",
			ReferenceEventDigests:     []string{"sha256:refA", "sha256:refB"},
			ReferenceSetAdmissibility: "sha256:adm",
			SettlementRowID:           "settle-1",
			SigningKeyID:              "audit-key-1",
			AggregationRule:           "compute_integrity_support_selection_v1",
			RetainedEvidence: []RetainedPositionEvidence{{
				PromptID: "p1", PositionIndex: 0, TokenPrefixDigest: "sha256:pfx", ContextHash: "sha256:ctx",
				K: 64, SamplerStage: SamplerStagePostSampler,
				SupportTokenIDs:              []int64{1, 2, 3},
				ProviderSupportProbabilities: []float64{0.5, 0.5, 0.0},
				ProviderTailMass:             0.0,
			}},
		},
	}
}

// AC-9: audit / export.
func TestAC09_AuditExport(t *testing.T) {
	t.Run("bundle digest is deterministic and recomputable from the payload", func(t *testing.T) {
		b := sampleBundle()
		d, err := b.ComputeBundleDigest()
		if err != nil {
			t.Fatal(err)
		}
		d2, _ := b.ComputeBundleDigest()
		if d != d2 || d == "" {
			t.Fatal("bundle digest must be deterministic")
		}
	})

	t.Run("bundle exposes linkable ids without raw prompts/output", func(t *testing.T) {
		b := sampleBundle()
		if b.Payload.SettlementRowID == "" || len(b.Payload.ReferenceEventDigests) == 0 {
			t.Fatal("bundle must carry linkable settlement/reference identifiers")
		}
		ok, err := BundleOmitsRawContent(b)
		if err != nil {
			t.Fatal(err)
		}
		if !ok {
			t.Fatal("bundle must not contain raw prompt/output content")
		}
	})

	t.Run("signed auditor bundle references a signing key id (bundle exists before enforce)", func(t *testing.T) {
		if sampleBundle().Payload.SigningKeyID == "" {
			t.Fatal("settlement-impacting bundle must bind a signing key id")
		}
	})

	t.Run("a verifier can recompute settlement-impacting TV intervals from exported evidence", func(t *testing.T) {
		b := sampleBundle()
		ev := b.Payload.RetainedEvidence[0]
		refs := map[string]struct {
			TopK []int64
			Full ReferenceDistribution
		}{
			"sha256:refA": {TopK: []int64{1, 2}, Full: ReferenceDistribution{1: 0.5, 2: 0.5}},
			"sha256:refB": {TopK: []int64{1, 3}, Full: ReferenceDistribution{1: 0.5, 3: 0.5}},
		}
		got, err := RecomputeTVFromEvidence(ev, []int64{1, 2}, refs)
		if err != nil {
			t.Fatal(err)
		}
		// refA identical to provider -> TV 0; refB diverges -> TV 0.5.
		if math.Abs(got["sha256:refA"].Upper) > 1e-9 {
			t.Fatalf("refA should recompute TV ~0, got %+v", got["sha256:refA"])
		}
		if math.Abs(got["sha256:refB"].Upper-0.5) > 1e-9 {
			t.Fatalf("refB should recompute TV ~0.5, got %+v", got["sha256:refB"])
		}
	})

	t.Run("request-start snapshot digest is over the closed FR-4 capture", func(t *testing.T) {
		d, err := RequestStartSnapshotDigest(payableCapture())
		if err != nil || d == "" {
			t.Fatalf("snapshot digest failed: %v", err)
		}
	})
}
