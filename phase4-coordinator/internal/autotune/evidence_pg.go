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
	// FIX B (issue #582): also read the matched job's hardware tuple
	// (chip_normalized, unified_memory_gb) so the caller can bind the admitted
	// session to the exact trust root the sweep must later revalidate.
	var chipNormalized string
	var unifiedMemoryGB int
	// FIX 4 (round-6 root-cause fix, issue #582): the denormalized
	// provider_hardware_profiles.verified bit can be briefly stale — TRUE while its
	// backing hardware_verification_trust root has already been revoked/expired
	// (the demotion sweep, an inventory delete, or an operator revoke lands a
	// moment after the bit is read). Making the bit non-security-load-bearing:
	// re-check LIVE trust here with an additional EXISTS that mirrors the verifier's
	// exact trust-match tuple (provider_id, hardware_identity_hash from the job
	// evidence, chip_normalized, unified_memory_gb, and an unexpired root). A
	// revoked/expired root then fails admission immediately regardless of the
	// verified bit, so every demotion/promotion race window collapses to an
	// at-worst brief false-NEGATIVE (self-healing on the next verified pass) and
	// never a false-positive admission of untrusted hardware. This is strictly
	// additive — one extra AND EXISTS condition; no other admission logic changes.
	// The hash is read as `evidence -> 'hardware' ->> 'hardware_identity_hash'`,
	// the same tuple element the verifier matches with
	// `evidence #>> '{hardware,hardware_identity_hash}'` (identical semantics; the
	// chained-arrow spelling is portable across Postgres and the SQLite unit-test
	// harness). The unexpired-root predicate compares expires_at against the
	// store's wall clock bound as $4 (same pattern as the cutoff bind above),
	// rather than an in-SQL now()/clock_timestamp(); this single-statement read has
	// no long-transaction clock-freeze concern and the bind keeps the query
	// portable to the SQLite test harness.
	err := s.db.QueryRowContext(ctx, `
SELECT j.generated_at, j.evidence, j.chip_normalized, j.unified_memory_gb
  FROM hardware_verification_jobs j
  JOIN provider_hardware_profiles p
    ON p.provider_id = j.provider_id
   AND p.verified = TRUE
   AND p.chip_normalized = j.chip_normalized
   AND p.unified_memory_gb = j.unified_memory_gb
 WHERE j.provider_id = $1
   AND j.status = 'verified'
   AND j.generated_at >= $2
   AND j.decision_reason = $3
   AND EXISTS (
       SELECT 1
         FROM hardware_verification_trust t
        WHERE t.provider_id = j.provider_id
          AND t.hardware_identity_hash = j.evidence -> 'hardware' ->> 'hardware_identity_hash'
          AND t.chip_normalized = j.chip_normalized
          AND t.unified_memory_gb = j.unified_memory_gb
          AND (t.expires_at IS NULL OR t.expires_at > $4)
   )
 ORDER BY j.generated_at DESC, j.id DESC
 LIMIT 1`, providerID, cutoff, hardwareverify.VerifiedDecisionReason, now).Scan(&generatedAt, &rawEvidence, &chipNormalized, &unifiedMemoryGB)
	if errors.Is(err, sql.ErrNoRows) {
		return VerifiedEvidence{}, false, nil
	}
	if err != nil {
		return VerifiedEvidence{}, false, fmt.Errorf("load verified autotune evidence: %w", err)
	}
	evidence, err := decodeVerifiedEvidence(rawEvidence, generatedAt, cutoff)
	if err != nil {
		return VerifiedEvidence{}, false, err
	}
	// FIX B (issue #582): bind the admitted trust tuple. HardwareIdentityHash is
	// the same evidence element the trust join matches; chip/memory come from the
	// matched verified job row.
	evidence.ChipNormalized = chipNormalized
	evidence.UnifiedMemoryGB = unifiedMemoryGB
	return evidence, true, nil
}

func decodeVerifiedEvidence(raw []byte, generatedAt, benchmarkCutoff time.Time) (VerifiedEvidence, error) {
	var payload struct {
		GeneratedAt            string `json:"generated_at"`
		CandidateCatalogSHA256 string `json:"candidate_catalog_sha256"`
		ProbeProtocol          string `json:"probe_protocol"`
		Hardware               struct {
			BinaryVersion        string `json:"binary_version"`
			HardwareIdentityHash string `json:"hardware_identity_hash"`
			ExecutableSHA256     string `json:"executable_sha256"`
		} `json:"hardware"`
		Benchmarks []struct {
			ModelKey                string  `json:"model_key"`
			ModelID                 string  `json:"model_id"`
			SustainedTPS            float64 `json:"sustained_tps"`
			TTFTMS                  int     `json:"ttft_ms"`
			SwapDetected            bool    `json:"swap_detected"`
			ThermalThrottleDetected bool    `json:"thermal_throttle_detected"`
			ArtifactSHA256          string  `json:"artifact_sha256"`
			CandidateCatalogSHA256  string  `json:"candidate_catalog_sha256"`
			GeneratedAt             string  `json:"generated_at"`
			BinaryVersion           string  `json:"binary_version"`
			HardwareIdentityHash    string  `json:"hardware_identity_hash"`
			CandidateRowIdentity    string  `json:"candidate_row_identity"`
		} `json:"benchmarks"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return VerifiedEvidence{}, fmt.Errorf("decode verified autotune evidence: %w", err)
	}
	payloadGeneratedAt, err := time.Parse(time.RFC3339, payload.GeneratedAt)
	if err != nil || !payloadGeneratedAt.Equal(generatedAt) {
		return VerifiedEvidence{}, errors.New("verified autotune evidence generated_at binding mismatch")
	}
	catalogSHA := strings.TrimSpace(payload.CandidateCatalogSHA256)
	if payload.ProbeProtocol != "spec-023-harmony-stream.v2" ||
		!isLowerSHA256(catalogSHA) ||
		strings.TrimSpace(payload.Hardware.BinaryVersion) == "" ||
		!isLowerSHA256(payload.Hardware.HardwareIdentityHash) ||
		!isLowerSHA256(payload.Hardware.ExecutableSHA256) {
		return VerifiedEvidence{}, errors.New("verified autotune evidence has invalid immutable bindings")
	}
	if len(payload.Benchmarks) == 0 {
		return VerifiedEvidence{}, errors.New("verified autotune evidence has no benchmarks")
	}
	out := VerifiedEvidence{
		GeneratedAt:            generatedAt.UTC(),
		CandidateCatalogSHA256: catalogSHA,
		ProbeProtocol:          payload.ProbeProtocol,
		BinaryVersion:          strings.TrimSpace(payload.Hardware.BinaryVersion),
		ExecutableSHA256:       strings.TrimSpace(payload.Hardware.ExecutableSHA256),
		// FIX B (issue #582): the hardware_identity_hash from the immutable
		// evidence binding — the same tuple element the trust join matches.
		HardwareIdentityHash: strings.TrimSpace(payload.Hardware.HardwareIdentityHash),
	}
	for _, b := range payload.Benchmarks {
		benchmarkGeneratedAt, parseErr := time.Parse(time.RFC3339, b.GeneratedAt)
		if parseErr != nil || benchmarkGeneratedAt.Before(benchmarkCutoff) {
			return VerifiedEvidence{}, errors.New("verified autotune benchmark is stale")
		}
		if strings.TrimSpace(b.ModelKey) == "" || strings.TrimSpace(b.ModelID) == "" ||
			!isLowerSHA256(strings.TrimSpace(b.ArtifactSHA256)) ||
			b.CandidateCatalogSHA256 != catalogSHA ||
			b.BinaryVersion != payload.Hardware.BinaryVersion ||
			b.HardwareIdentityHash != payload.Hardware.HardwareIdentityHash ||
			!isLowerSHA256(strings.TrimSpace(b.CandidateRowIdentity)) {
			return VerifiedEvidence{}, errors.New("verified autotune benchmark binding mismatch")
		}
		out.Benchmarks = append(out.Benchmarks, VerifiedBenchmark{
			ModelKey:                strings.TrimSpace(b.ModelKey),
			ModelID:                 strings.TrimSpace(b.ModelID),
			SustainedTPS:            b.SustainedTPS,
			TTFTMS:                  b.TTFTMS,
			SwapDetected:            b.SwapDetected,
			ThermalThrottleDetected: b.ThermalThrottleDetected,
			ArtifactSHA256:          strings.TrimSpace(b.ArtifactSHA256),
			CandidateCatalogSHA256:  strings.TrimSpace(b.CandidateCatalogSHA256),
			CandidateRowIdentity:    strings.TrimSpace(b.CandidateRowIdentity),
		})
	}
	return out, nil
}

func isLowerSHA256(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}
