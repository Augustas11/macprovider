package hardwareverify

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// TestPromotionDecisionReparksWhenTrustRootInactive pins FIX 2 (issue #582): a
// job that passed Evaluate but whose backing hardware trust root went inactive
// (expired/revoked/deleted) between batch selection and the promoting write must
// NOT be promoted — promoteJob re-parks it as waiting_trust with a reason the
// operator approval path can re-drive. The live SQL round-trip (the EXISTS
// re-check against hardware_verification_trust) additionally requires a live
// PostgreSQL smoke, which this environment cannot run; this unit test pins the
// promote-vs-repark decision and that the re-park reason matches the approval
// gate.
func TestPromotionDecisionReparksWhenTrustRootInactive(t *testing.T) {
	promote, reason := promotionDecision(false)
	if promote {
		t.Fatal("promotionDecision(false): an inactive trust root must NOT promote")
	}
	if reason != "missing_trusted_hardware_identity" {
		t.Fatalf("re-park reason = %q, want missing_trusted_hardware_identity (must match the operator approval gate)", reason)
	}
	if promote, _ := promotionDecision(true); !promote {
		t.Fatal("promotionDecision(true): an active trust root must promote")
	}
}

func TestEvaluateVerifiesFullyBoundTrustedHardwareEvidence(t *testing.T) {
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	decision := evaluateAt(validJob(t, now, "Apple M5", "C"), now)
	if !decision.Verified {
		t.Fatalf("decision.Verified = false, reason=%s", decision.Reason)
	}
	if decision.Reason != VerifiedDecisionReason {
		t.Fatalf("reason = %q, want %q", decision.Reason, VerifiedDecisionReason)
	}
}

func TestEvaluatePostgresMicrosecondTimestampBinding(t *testing.T) {
	now := time.Date(2026, 7, 10, 12, 0, 0, 123456000, time.UTC)
	for _, tc := range []struct {
		name      string
		generated string
		verified  bool
		reason    string
	}{
		{name: "zero padded nanoseconds", generated: "2026-07-10T12:00:00.123456000Z", verified: true, reason: VerifiedDecisionReason},
		{name: "precision lost by postgres", generated: "2026-07-10T12:00:00.123456789Z", reason: "evidence_generated_at_mismatch"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			job := validJob(t, now, "Apple M5", "C")
			var evidence Evidence
			if err := json.Unmarshal(job.Evidence, &evidence); err != nil {
				t.Fatal(err)
			}
			evidence.GeneratedAt = tc.generated
			job.Evidence = mustEvidenceJSON(t, evidence)
			decision := evaluateAt(job, now)
			if decision.Verified != tc.verified || decision.Reason != tc.reason {
				t.Fatalf("decision=%+v", decision)
			}
		})
	}
}

func TestEvaluateAllowsHigherTierChipsWhenOperatorInventoryMatches(t *testing.T) {
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name string
		chip string
		tier string
	}{
		{name: "pro", chip: "Apple M4 Pro", tier: "B"},
		{name: "max", chip: "Apple M4 Max", tier: "A"},
		{name: "ultra", chip: "Apple M3 Ultra", tier: "S"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			decision := evaluateAt(validJob(t, now, tc.chip, tc.tier), now)
			if !decision.Verified {
				t.Fatalf("decision.Verified = false for %s, reason=%s", tc.chip, decision.Reason)
			}
		})
	}
}

func TestEvaluateRejectsProviderMismatch(t *testing.T) {
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	job := validJob(t, now, "Apple M5", "C")
	var evidence Evidence
	if err := json.Unmarshal(job.Evidence, &evidence); err != nil {
		t.Fatal(err)
	}
	evidence.ProviderID = "other"
	job.Evidence = mustEvidenceJSON(t, evidence)

	decision := evaluateAt(job, now)
	if decision.Verified || decision.Reason != "provider_id_mismatch" {
		t.Fatalf("decision = %+v", decision)
	}
}

func TestEvaluateRejectsReboundAndStaleEvidence(t *testing.T) {
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name   string
		reason string
		mutate func(*Job, *Evidence)
	}{
		{
			name: "top timestamp rebound", reason: "evidence_generated_at_mismatch",
			mutate: func(_ *Job, evidence *Evidence) { evidence.GeneratedAt = now.Add(time.Hour).Format(time.RFC3339) },
		},
		{
			name: "job binary rebound", reason: "binary_version_mismatch",
			mutate: func(job *Job, _ *Evidence) { job.BinaryVersion = "1.8.0" },
		},
		{
			name: "catalog rebound", reason: "benchmark_catalog_mismatch",
			mutate: func(_ *Job, evidence *Evidence) {
				evidence.Benchmarks[0].CandidateCatalogSHA256 = strings.Repeat("a", 64)
			},
		},
		{
			name: "artifact binding missing", reason: "invalid_benchmark_artifact_sha256",
			mutate: func(_ *Job, evidence *Evidence) { evidence.Benchmarks[0].ArtifactSHA256 = "" },
		},
		{
			name: "benchmark binary rebound", reason: "benchmark_binary_version_mismatch",
			mutate: func(_ *Job, evidence *Evidence) { evidence.Benchmarks[0].BinaryVersion = "1.8.0" },
		},
		{
			name: "hardware identity rebound", reason: "benchmark_hardware_identity_mismatch",
			mutate: func(_ *Job, evidence *Evidence) {
				evidence.Benchmarks[0].HardwareIdentityHash = strings.Repeat("a", 64)
			},
		},
		{
			name: "stale benchmark", reason: "stale_benchmark",
			mutate: func(_ *Job, evidence *Evidence) {
				evidence.Benchmarks[0].GeneratedAt = now.Add(-8 * 24 * time.Hour).Format(time.RFC3339)
			},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			job := validJob(t, now, "Apple M5", "C")
			var evidence Evidence
			if err := json.Unmarshal(job.Evidence, &evidence); err != nil {
				t.Fatal(err)
			}
			tc.mutate(&job, &evidence)
			job.Evidence = mustEvidenceJSON(t, evidence)
			decision := evaluateAt(job, now)
			if decision.Verified || decision.Reason != tc.reason {
				t.Fatalf("decision = %+v, want reason %q", decision, tc.reason)
			}
		})
	}
}

func TestEvaluateWaitsOnlyAfterEvidenceIntegrityPasses(t *testing.T) {
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	job := validJob(t, now, "Apple M5", "C")
	job.TrustMatched = false
	decision := evaluateAt(job, now)
	if decision.Verified || decision.Reason != "missing_trusted_hardware_identity" {
		t.Fatalf("decision = %+v", decision)
	}

	job = validJob(t, now, "Apple M5", "C")
	job.ChipProfileMatched = false
	decision = evaluateAt(job, now)
	if decision.Verified || decision.Reason != "missing_trusted_chip_profile" {
		t.Fatalf("decision = %+v", decision)
	}
}

func validJob(t *testing.T, now time.Time, chip, tier string) Job {
	t.Helper()
	hardwareIdentity := strings.Repeat("c", 64)
	catalogSHA := strings.Repeat("b", 64)
	evidence := Evidence{
		SchemaVersion:          evidenceSchemaVersion,
		ProviderID:             "mac",
		GeneratedAt:            now.Format(time.RFC3339),
		CandidateCatalogSHA256: catalogSHA,
		RecommendedModel:       "mlx-community/model",
		ProbeProtocol:          evidenceProbeProtocol,
		Hardware: Hardware{
			Chip:                 chip,
			MemoryGB:             32,
			BandwidthTier:        tier,
			Detected:             true,
			OSVersion:            "15.5",
			BinaryVersion:        "1.7.9",
			HardwareIdentityHash: hardwareIdentity,
			ExecutableSHA256:     strings.Repeat("e", 64),
		},
		Benchmarks: []Benchmark{{
			ModelKey:               "model",
			ModelID:                "mlx-community/model",
			SustainedTPS:           42.5,
			TTFTMS:                 1200,
			ArtifactSHA256:         strings.Repeat("d", 64),
			CandidateCatalogSHA256: catalogSHA,
			BenchmarkID:            "bench-1",
			GeneratedAt:            now.Format(time.RFC3339),
			BinaryVersion:          "1.7.9",
			HardwareIdentityHash:   hardwareIdentity,
			CandidateRowIdentity:   strings.Repeat("f", 64),
		}},
	}
	return Job{
		ID:                 1,
		ProviderID:         "mac",
		Chip:               chip,
		ChipNormalized:     normalizeChip(chip),
		MemoryGB:           32,
		BandwidthTier:      tier,
		OSVersion:          "15.5",
		BinaryVersion:      "1.7.9",
		GeneratedAt:        now,
		Evidence:           mustEvidenceJSON(t, evidence),
		TrustMatched:       true,
		ChipProfileMatched: true,
	}
}

func mustEvidenceJSON(t *testing.T, evidence Evidence) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(evidence)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
