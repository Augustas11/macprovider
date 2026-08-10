package autotune

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/hardwareverify"
)

const (
	GateMatrixSchemaVersion = "macprovider.autotune-gate-matrix.v1"
	GateMatrixSource        = "hardware_verifier_export"
)

type GateMatrixExport struct {
	SchemaVersion          string               `json:"schema_version"`
	Source                 string               `json:"source"`
	GeneratedAt            string               `json:"generated_at"`
	CandidateCatalogSHA256 string               `json:"candidate_catalog_sha256"`
	Providers              []GateMatrixProvider `json:"providers"`
}

type GateMatrixProvider struct {
	ProviderID   string                 `json:"provider_id"`
	Verification GateMatrixVerification `json:"verification"`
	Evidence     json.RawMessage        `json:"evidence"`
}

type GateMatrixVerification struct {
	Status         string `json:"status"`
	DecisionReason string `json:"decision_reason"`
	JobID          int64  `json:"job_id"`
	EvidenceSHA256 string `json:"evidence_sha256"`
	ProcessedAt    string `json:"processed_at"`
}

type gateMatrixJob struct {
	jobID          int64
	providerID     string
	status         string
	decisionReason string
	processedAt    time.Time
	evidenceSHA256 string
	generatedAt    time.Time
	evidence       []byte
}

func (s *PGEvidenceStore) ExportGateMatrix(ctx context.Context, candidateCatalogSHA256 string, minGeneratedAt, asOf time.Time) (GateMatrixExport, error) {
	if s == nil || s.db == nil {
		return GateMatrixExport{}, errors.New("autotune evidence store is nil")
	}
	candidateCatalogSHA256 = strings.TrimSpace(candidateCatalogSHA256)
	if !isLowerSHA256(candidateCatalogSHA256) {
		return GateMatrixExport{}, errors.New("candidate catalog SHA-256 is required")
	}
	minGeneratedAt = minGeneratedAt.UTC()
	asOf = asOf.UTC()
	if minGeneratedAt.IsZero() {
		return GateMatrixExport{}, errors.New("min generated_at is required")
	}
	if asOf.IsZero() || asOf.Before(minGeneratedAt) {
		return GateMatrixExport{}, errors.New("as_of must be at or after min generated_at")
	}
	rows, err := s.exportGateMatrixRows(ctx, candidateCatalogSHA256, minGeneratedAt, asOf)
	if err != nil {
		return GateMatrixExport{}, err
	}
	return buildGateMatrixExport(candidateCatalogSHA256, asOf, rows)
}

func (s *PGEvidenceStore) exportGateMatrixRows(ctx context.Context, candidateCatalogSHA256 string, minGeneratedAt, asOf time.Time) ([]gateMatrixJob, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT j.id,
       j.provider_id,
       j.status,
       j.decision_reason,
       j.processed_at,
       j.evidence_sha256,
       j.generated_at,
       j.evidence
  FROM hardware_verification_jobs j
  JOIN provider_hardware_profiles p
    ON p.provider_id = j.provider_id
   AND p.verified = TRUE
   AND p.chip_normalized = j.chip_normalized
   AND p.unified_memory_gb = j.unified_memory_gb
 WHERE j.status = 'verified'
   AND j.decision_reason = $1
   AND j.generated_at >= $2
   AND j.generated_at <= $3
   AND j.processed_at <= $3
   AND j.evidence ->> 'schema_version' = 'hardware_evidence.autotune.v2'
   AND j.evidence ->> 'probe_protocol' = 'spec-023-harmony-stream.v2'
   AND j.evidence ->> 'candidate_catalog_sha256' = $4
   AND EXISTS (
       SELECT 1
         FROM hardware_verification_trust t
        WHERE t.provider_id = j.provider_id
          AND t.hardware_identity_hash = j.evidence -> 'hardware' ->> 'hardware_identity_hash'
          AND t.chip_normalized = j.chip_normalized
          AND t.unified_memory_gb = j.unified_memory_gb
          AND (t.expires_at IS NULL OR t.expires_at > $3)
   )
 ORDER BY j.provider_id ASC, j.generated_at DESC, j.id DESC`, hardwareverify.VerifiedDecisionReason, minGeneratedAt, asOf, candidateCatalogSHA256)
	if err != nil {
		return nil, fmt.Errorf("query verified autotune gate matrix rows: %w", err)
	}
	defer rows.Close()

	var jobs []gateMatrixJob
	seenProvider := map[string]bool{}
	for rows.Next() {
		var job gateMatrixJob
		var processedAt sql.NullTime
		if err := rows.Scan(
			&job.jobID,
			&job.providerID,
			&job.status,
			&job.decisionReason,
			&processedAt,
			&job.evidenceSHA256,
			&job.generatedAt,
			&job.evidence,
		); err != nil {
			return nil, fmt.Errorf("scan verified autotune gate matrix row: %w", err)
		}
		if seenProvider[job.providerID] {
			continue
		}
		seenProvider[job.providerID] = true
		if processedAt.Valid {
			job.processedAt = processedAt.Time.UTC()
		}
		jobs = append(jobs, job)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read verified autotune gate matrix rows: %w", err)
	}
	return jobs, nil
}

func buildGateMatrixExport(candidateCatalogSHA256 string, generatedAt time.Time, rows []gateMatrixJob) (GateMatrixExport, error) {
	out := GateMatrixExport{
		SchemaVersion:          GateMatrixSchemaVersion,
		Source:                 GateMatrixSource,
		GeneratedAt:            generatedAt.UTC().Format(time.RFC3339),
		CandidateCatalogSHA256: strings.TrimSpace(candidateCatalogSHA256),
	}
	if !isLowerSHA256(out.CandidateCatalogSHA256) {
		return GateMatrixExport{}, errors.New("candidate catalog SHA-256 is required")
	}
	seenProvider := map[string]bool{}
	for index, row := range rows {
		providerID := strings.TrimSpace(row.providerID)
		if providerID == "" {
			return GateMatrixExport{}, fmt.Errorf("gate matrix row %d: provider_id is required", index)
		}
		if seenProvider[providerID] {
			return GateMatrixExport{}, fmt.Errorf("gate matrix row %d: duplicate provider_id %q", index, providerID)
		}
		seenProvider[providerID] = true
		if row.jobID <= 0 {
			return GateMatrixExport{}, fmt.Errorf("gate matrix row %d: job_id is required", index)
		}
		if row.status != "verified" || row.decisionReason != hardwareverify.VerifiedDecisionReason {
			return GateMatrixExport{}, fmt.Errorf("gate matrix row %d: verifier decision is not trusted", index)
		}
		if !isLowerSHA256(strings.TrimSpace(row.evidenceSHA256)) {
			return GateMatrixExport{}, fmt.Errorf("gate matrix row %d: evidence_sha256 is required", index)
		}
		if row.processedAt.IsZero() {
			return GateMatrixExport{}, fmt.Errorf("gate matrix row %d: processed_at is required", index)
		}
		if !json.Valid(row.evidence) {
			return GateMatrixExport{}, fmt.Errorf("gate matrix row %d: evidence is not valid JSON", index)
		}
		out.Providers = append(out.Providers, GateMatrixProvider{
			ProviderID: providerID,
			Verification: GateMatrixVerification{
				Status:         "verified",
				DecisionReason: hardwareverify.VerifiedDecisionReason,
				JobID:          row.jobID,
				EvidenceSHA256: strings.TrimSpace(row.evidenceSHA256),
				ProcessedAt:    row.processedAt.UTC().Format(time.RFC3339),
			},
			Evidence: append(json.RawMessage(nil), row.evidence...),
		})
	}
	return out, nil
}
