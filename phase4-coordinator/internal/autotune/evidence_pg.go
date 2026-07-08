package autotune

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

type PGEvidenceStore struct {
	db  *sql.DB
	now func() time.Time
}

func NewPGEvidenceStore(db *sql.DB) *PGEvidenceStore {
	return &PGEvidenceStore{db: db, now: time.Now}
}

func (s *PGEvidenceStore) LatestVerified(ctx context.Context, providerID string, ttl time.Duration) (VerifiedEvidence, bool, error) {
	if s == nil || s.db == nil {
		return VerifiedEvidence{}, false, errors.New("autotune evidence store is nil")
	}
	providerID = strings.TrimSpace(providerID)
	if providerID == "" {
		return VerifiedEvidence{}, false, errors.New("provider_id is required")
	}
	if ttl <= 0 {
		return VerifiedEvidence{}, false, errors.New("evidence ttl must be > 0")
	}
	now := time.Now().UTC()
	if s.now != nil {
		now = s.now().UTC()
	}
	cutoff := now.Add(-ttl)

	var rawEvidence []byte
	var generatedAt time.Time
	err := s.db.QueryRowContext(ctx, `
SELECT generated_at, evidence
  FROM hardware_verification_jobs
 WHERE provider_id = $1
   AND status = 'verified'
   AND generated_at >= $2
 ORDER BY generated_at DESC, id DESC
 LIMIT 1`, providerID, cutoff).Scan(&generatedAt, &rawEvidence)
	if errors.Is(err, sql.ErrNoRows) {
		return VerifiedEvidence{}, false, nil
	}
	if err != nil {
		return VerifiedEvidence{}, false, fmt.Errorf("load verified autotune evidence: %w", err)
	}
	evidence, err := decodeVerifiedEvidence(rawEvidence, generatedAt)
	if err != nil {
		return VerifiedEvidence{}, false, err
	}
	return evidence, true, nil
}

func decodeVerifiedEvidence(raw []byte, generatedAt time.Time) (VerifiedEvidence, error) {
	var payload struct {
		CandidateCatalogSHA256 string `json:"candidate_catalog_sha256"`
		Benchmarks             []struct {
			ModelKey                string  `json:"model_key"`
			ModelID                 string  `json:"model_id"`
			SustainedTPS            float64 `json:"sustained_tps"`
			TTFTMS                  int     `json:"ttft_ms"`
			SwapDetected            bool    `json:"swap_detected"`
			ThermalThrottleDetected bool    `json:"thermal_throttle_detected"`
			ArtifactSHA256          string  `json:"artifact_sha256"`
			CandidateCatalogSHA256  string  `json:"candidate_catalog_sha256"`
		} `json:"benchmarks"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return VerifiedEvidence{}, fmt.Errorf("decode verified autotune evidence: %w", err)
	}
	out := VerifiedEvidence{
		GeneratedAt:            generatedAt.UTC(),
		CandidateCatalogSHA256: strings.TrimSpace(payload.CandidateCatalogSHA256),
	}
	for _, b := range payload.Benchmarks {
		out.Benchmarks = append(out.Benchmarks, VerifiedBenchmark{
			ModelKey:                strings.TrimSpace(b.ModelKey),
			ModelID:                 strings.TrimSpace(b.ModelID),
			SustainedTPS:            b.SustainedTPS,
			TTFTMS:                  b.TTFTMS,
			SwapDetected:            b.SwapDetected,
			ThermalThrottleDetected: b.ThermalThrottleDetected,
			ArtifactSHA256:          strings.TrimSpace(b.ArtifactSHA256),
			CandidateCatalogSHA256:  strings.TrimSpace(b.CandidateCatalogSHA256),
		})
	}
	return out, nil
}
