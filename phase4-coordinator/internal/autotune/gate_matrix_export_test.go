package autotune

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/hardwareverify"
)

func TestExportGateMatrixUsesLatestTrustedVerifiedEvidence(t *testing.T) {
	db := openAutotuneEvidenceTestDB(t)
	catalogSHA := strings.Repeat("b", 64)
	older := time.Date(2026, 7, 30, 10, 0, 0, 0, time.UTC)
	newer := older.Add(time.Hour)
	asOf := newer.Add(time.Hour)
	providerID := "provider-a"
	hardwareHash := strings.Repeat("c", 64)

	if _, err := db.Exec(`
INSERT INTO provider_hardware_profiles (
    provider_id, chip_normalized, unified_memory_gb, verified
) VALUES (?, ?, ?, ?)`, providerID, "apple m4 max", 64, true); err != nil {
		t.Fatalf("insert provider profile: %v", err)
	}
	if _, err := db.Exec(`
INSERT INTO hardware_verification_trust (
    provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, expires_at
) VALUES (?, ?, ?, ?, ?)`, providerID, hardwareHash, "apple m4 max", 64, nil); err != nil {
		t.Fatalf("insert trust root: %v", err)
	}
	insertGateMatrixJob(t, db, gateMatrixFixtureJob{
		ProviderID:     providerID,
		ChipNormalized: "apple m4 max",
		MemoryGB:       64,
		GeneratedAt:    older,
		ProcessedAt:    older.Add(5 * time.Minute),
		CatalogSHA:     catalogSHA,
		HardwareHash:   hardwareHash,
		EvidenceSHA256: strings.Repeat("1", 64),
		SustainedTPS:   20,
		DecisionReason: hardwareverify.VerifiedDecisionReason,
		Status:         "verified",
	})
	insertGateMatrixJob(t, db, gateMatrixFixtureJob{
		ProviderID:     providerID,
		ChipNormalized: "apple m4 max",
		MemoryGB:       64,
		GeneratedAt:    newer,
		ProcessedAt:    newer.Add(5 * time.Minute),
		CatalogSHA:     catalogSHA,
		HardwareHash:   hardwareHash,
		EvidenceSHA256: strings.Repeat("2", 64),
		SustainedTPS:   42,
		DecisionReason: hardwareverify.VerifiedDecisionReason,
		Status:         "verified",
	})

	store := NewPGEvidenceStore(db)
	matrix, err := store.ExportGateMatrix(context.Background(), catalogSHA, older.Add(-time.Minute), asOf)
	if err != nil {
		t.Fatalf("ExportGateMatrix: %v", err)
	}
	if matrix.SchemaVersion != GateMatrixSchemaVersion || matrix.Source != GateMatrixSource {
		t.Fatalf("unexpected matrix header: %+v", matrix)
	}
	if len(matrix.Providers) != 1 {
		t.Fatalf("provider count=%d want 1: %+v", len(matrix.Providers), matrix)
	}
	provider := matrix.Providers[0]
	if provider.ProviderID != providerID || provider.Verification.EvidenceSHA256 != strings.Repeat("2", 64) {
		t.Fatalf("export did not choose latest provider evidence: %+v", provider.Verification)
	}
	if provider.Verification.JobID <= 0 || provider.Verification.ProcessedAt == "" {
		t.Fatalf("missing verifier job bindings: %+v", provider.Verification)
	}
	var evidence struct {
		Benchmarks []struct {
			SustainedTPS float64 `json:"sustained_tps"`
		} `json:"benchmarks"`
	}
	if err := json.Unmarshal(provider.Evidence, &evidence); err != nil {
		t.Fatalf("decode exported evidence: %v", err)
	}
	if len(evidence.Benchmarks) != 1 || evidence.Benchmarks[0].SustainedTPS != 42 {
		t.Fatalf("unexpected exported evidence: %+v", evidence)
	}
}

func TestExportGateMatrixRejectsExpiredTrustAndCatalogMismatch(t *testing.T) {
	db := openAutotuneEvidenceTestDB(t)
	catalogSHA := strings.Repeat("b", 64)
	otherSHA := strings.Repeat("a", 64)
	generatedAt := time.Date(2026, 7, 30, 10, 0, 0, 0, time.UTC)
	asOf := generatedAt.Add(time.Hour)
	hardwareHash := strings.Repeat("c", 64)

	for _, providerID := range []string{"expired-provider", "wrong-catalog-provider"} {
		if _, err := db.Exec(`
INSERT INTO provider_hardware_profiles (
    provider_id, chip_normalized, unified_memory_gb, verified
) VALUES (?, ?, ?, ?)`, providerID, "apple m4 max", 64, true); err != nil {
			t.Fatalf("insert provider profile: %v", err)
		}
	}
	if _, err := db.Exec(`
INSERT INTO hardware_verification_trust (
    provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, expires_at
) VALUES (?, ?, ?, ?, ?)`, "expired-provider", hardwareHash, "apple m4 max", 64, generatedAt.Add(-time.Minute)); err != nil {
		t.Fatalf("insert expired trust root: %v", err)
	}
	if _, err := db.Exec(`
INSERT INTO hardware_verification_trust (
    provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, expires_at
) VALUES (?, ?, ?, ?, ?)`, "wrong-catalog-provider", hardwareHash, "apple m4 max", 64, nil); err != nil {
		t.Fatalf("insert active trust root: %v", err)
	}
	insertGateMatrixJob(t, db, gateMatrixFixtureJob{
		ProviderID:     "expired-provider",
		ChipNormalized: "apple m4 max",
		MemoryGB:       64,
		GeneratedAt:    generatedAt,
		ProcessedAt:    generatedAt.Add(5 * time.Minute),
		CatalogSHA:     catalogSHA,
		HardwareHash:   hardwareHash,
		EvidenceSHA256: strings.Repeat("3", 64),
		SustainedTPS:   30,
		DecisionReason: hardwareverify.VerifiedDecisionReason,
		Status:         "verified",
	})
	insertGateMatrixJob(t, db, gateMatrixFixtureJob{
		ProviderID:     "wrong-catalog-provider",
		ChipNormalized: "apple m4 max",
		MemoryGB:       64,
		GeneratedAt:    generatedAt,
		ProcessedAt:    generatedAt.Add(5 * time.Minute),
		CatalogSHA:     otherSHA,
		HardwareHash:   hardwareHash,
		EvidenceSHA256: strings.Repeat("4", 64),
		SustainedTPS:   31,
		DecisionReason: hardwareverify.VerifiedDecisionReason,
		Status:         "verified",
	})

	store := NewPGEvidenceStore(db)
	matrix, err := store.ExportGateMatrix(context.Background(), catalogSHA, generatedAt.Add(-time.Minute), asOf)
	if err != nil {
		t.Fatalf("ExportGateMatrix: %v", err)
	}
	if len(matrix.Providers) != 0 {
		t.Fatalf("untrusted or wrong-catalog providers exported: %+v", matrix.Providers)
	}
}

func TestExportGateMatrixRejectsRowsMissingV2ProbeProtocol(t *testing.T) {
	db := openAutotuneEvidenceTestDB(t)
	catalogSHA := strings.Repeat("b", 64)
	generatedAt := time.Date(2026, 7, 30, 10, 0, 0, 0, time.UTC)
	hardwareHash := strings.Repeat("c", 64)
	providerID := "provider-missing-protocol"

	if _, err := db.Exec(`
INSERT INTO provider_hardware_profiles (
    provider_id, chip_normalized, unified_memory_gb, verified
) VALUES (?, ?, ?, ?)`, providerID, "apple m4 max", 64, true); err != nil {
		t.Fatalf("insert provider profile: %v", err)
	}
	if _, err := db.Exec(`
INSERT INTO hardware_verification_trust (
    provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, expires_at
) VALUES (?, ?, ?, ?, ?)`, providerID, hardwareHash, "apple m4 max", 64, nil); err != nil {
		t.Fatalf("insert trust root: %v", err)
	}
	insertGateMatrixJob(t, db, gateMatrixFixtureJob{
		ProviderID:          providerID,
		ChipNormalized:      "apple m4 max",
		MemoryGB:            64,
		GeneratedAt:         generatedAt,
		ProcessedAt:         generatedAt.Add(5 * time.Minute),
		CatalogSHA:          catalogSHA,
		HardwareHash:        hardwareHash,
		EvidenceSHA256:      strings.Repeat("5", 64),
		SustainedTPS:        30,
		DecisionReason:      hardwareverify.VerifiedDecisionReason,
		Status:              "verified",
		OmitV2ProbeProtocol: true,
	})

	store := NewPGEvidenceStore(db)
	matrix, err := store.ExportGateMatrix(context.Background(), catalogSHA, generatedAt.Add(-time.Minute), generatedAt.Add(time.Hour))
	if err != nil {
		t.Fatalf("ExportGateMatrix: %v", err)
	}
	if len(matrix.Providers) != 0 {
		t.Fatalf("missing-probe-protocol row exported: %+v", matrix.Providers)
	}
}

type gateMatrixFixtureJob struct {
	ProviderID          string
	ChipNormalized      string
	MemoryGB            int
	GeneratedAt         time.Time
	ProcessedAt         time.Time
	CatalogSHA          string
	HardwareHash        string
	EvidenceSHA256      string
	SustainedTPS        float64
	DecisionReason      string
	Status              string
	OmitV2ProbeProtocol bool
}

func insertGateMatrixJob(t *testing.T, db execer, job gateMatrixFixtureJob) {
	t.Helper()
	evidence := gateMatrixFixtureEvidence(t, job)
	if _, err := db.Exec(`
INSERT INTO hardware_verification_jobs (
    provider_id, status, chip_normalized, unified_memory_gb,
    generated_at, processed_at, decision_reason, evidence, evidence_sha256
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		job.ProviderID,
		job.Status,
		job.ChipNormalized,
		job.MemoryGB,
		job.GeneratedAt,
		job.ProcessedAt,
		job.DecisionReason,
		evidence,
		job.EvidenceSHA256,
	); err != nil {
		t.Fatalf("insert gate matrix job: %v", err)
	}
}

type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

func gateMatrixFixtureEvidence(t *testing.T, job gateMatrixFixtureJob) []byte {
	t.Helper()
	payload := map[string]any{
		"schema_version":           "hardware_evidence.autotune.v2",
		"provider_id":              job.ProviderID,
		"generated_at":             job.GeneratedAt.Format(time.RFC3339),
		"candidate_catalog_sha256": job.CatalogSHA,
		"recommended_model":        "model",
		"probe_protocol":           "spec-023-harmony-stream.v2",
		"hardware": map[string]any{
			"chip":                   "Apple M4 Max",
			"memory_gb":              job.MemoryGB,
			"bandwidth_tier":         "A",
			"detected":               true,
			"os_version":             "macOS test",
			"binary_version":         "1.9.0",
			"hardware_identity_hash": job.HardwareHash,
			"executable_sha256":      strings.Repeat("e", 64),
		},
		"benchmarks": []map[string]any{{
			"model_key":                 "model",
			"model_id":                  "mlx-community/model",
			"model_artifact_path":       "/tmp/macprovider-model",
			"sustained_tps":             job.SustainedTPS,
			"ttft_ms":                   1200,
			"swap_detected":             false,
			"thermal_throttle_detected": false,
			"artifact_sha256":           strings.Repeat("d", 64),
			"candidate_catalog_sha256":  job.CatalogSHA,
			"candidate_row_identity":    strings.Repeat("a", 64),
			"benchmark_id":              "bench-1",
			"generated_at":              job.GeneratedAt.Format(time.RFC3339),
			"binary_version":            "1.9.0",
			"hardware_identity_hash":    job.HardwareHash,
		}},
	}
	if job.OmitV2ProbeProtocol {
		delete(payload, "probe_protocol")
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
