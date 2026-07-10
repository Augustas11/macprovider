package hardwareverify

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	_ "github.com/lib/pq"
)

const verifierDecisionVersion = "hardware-verifier.v2"
const evidenceSchemaVersion = "hardware_evidence.autotune.v1"
const maxEvidenceAge = 7 * 24 * time.Hour
const futureSkew = 5 * time.Minute

const VerifiedDecisionReason = verifierDecisionVersion + ":verified_trusted_hardware"

type Store struct {
	db *sql.DB
}

type Processed struct {
	Verified int
	Rejected int
	Waiting  int
}

type Job struct {
	ID                 int64
	ProviderID         string
	Chip               string
	ChipNormalized     string
	MemoryGB           int
	BandwidthTier      string
	OSVersion          string
	BinaryVersion      string
	GeneratedAt        time.Time
	Evidence           json.RawMessage
	TrustMatched       bool
	ChipProfileMatched bool
}

type Evidence struct {
	SchemaVersion          string      `json:"schema_version"`
	ProviderID             string      `json:"provider_id"`
	GeneratedAt            string      `json:"generated_at"`
	Hardware               Hardware    `json:"hardware"`
	CandidateCatalogSHA256 string      `json:"candidate_catalog_sha256"`
	RecommendedModel       string      `json:"recommended_model"`
	Benchmarks             []Benchmark `json:"benchmarks"`
}

type Hardware struct {
	Chip                 string `json:"chip"`
	MemoryGB             int    `json:"memory_gb"`
	BandwidthTier        string `json:"bandwidth_tier"`
	Detected             bool   `json:"detected"`
	OSVersion            string `json:"os_version"`
	BinaryVersion        string `json:"binary_version"`
	HardwareIdentityHash string `json:"hardware_identity_hash"`
}

type Benchmark struct {
	ModelKey                string  `json:"model_key"`
	ModelID                 string  `json:"model_id"`
	SustainedTPS            float64 `json:"sustained_tps"`
	TTFTMS                  int     `json:"ttft_ms"`
	SwapDetected            bool    `json:"swap_detected"`
	ThermalThrottleDetected bool    `json:"thermal_throttle_detected"`
	ArtifactSHA256          string  `json:"artifact_sha256"`
	CandidateCatalogSHA256  string  `json:"candidate_catalog_sha256"`
	BenchmarkID             string  `json:"benchmark_id,omitempty"`
	GeneratedAt             string  `json:"generated_at"`
	BinaryVersion           string  `json:"binary_version"`
	HardwareIdentityHash    string  `json:"hardware_identity_hash"`
}

type Decision struct {
	Verified bool
	Reason   string
}

func Open(dsn string) (*Store, error) {
	dsn = strings.TrimSpace(dsn)
	if dsn == "" {
		return nil, errors.New("hardware verifier dsn is required")
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open hardware verifier postgres: %w", err)
	}
	db.SetMaxOpenConns(2)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(30 * time.Minute)
	db.SetConnMaxIdleTime(5 * time.Minute)
	return &Store{db: db}, nil
}

func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

func (s *Store) Smoke(ctx context.Context) error {
	if s == nil || s.db == nil {
		return errors.New("hardware verifier store is nil")
	}
	timeout, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var currentUser string
	if err := s.db.QueryRowContext(timeout, `SELECT current_user`).Scan(&currentUser); err != nil {
		return fmt.Errorf("stats_hardware_verifier smoke current_user: %w", err)
	}
	if currentUser != "stats_hardware_verifier" {
		return fmt.Errorf("stats_hardware_verifier smoke current_user = %q, want stats_hardware_verifier", currentUser)
	}
	if _, err := s.db.ExecContext(timeout, `SELECT id, status, evidence FROM hardware_verification_jobs LIMIT 1`); err != nil {
		return fmt.Errorf("stats_hardware_verifier smoke hardware_verification_jobs read: %w", err)
	}
	if _, err := s.db.ExecContext(timeout, `SELECT provider_id, hardware_identity_hash FROM hardware_verification_trust LIMIT 1`); err != nil {
		return fmt.Errorf("stats_hardware_verifier smoke hardware_verification_trust read: %w", err)
	}
	if _, err := s.db.ExecContext(timeout, `SELECT provider_id, verified FROM provider_hardware_profiles LIMIT 1`); err != nil {
		return fmt.Errorf("stats_hardware_verifier smoke provider_hardware_profiles read: %w", err)
	}
	if _, err := s.db.ExecContext(timeout, `SELECT chip_normalized FROM chip_hardware_profiles LIMIT 1`); err != nil {
		return fmt.Errorf("stats_hardware_verifier smoke chip_hardware_profiles read: %w", err)
	}
	return nil
}

func (s *Store) ProcessPending(ctx context.Context, limit int) (Processed, error) {
	if s == nil || s.db == nil {
		return Processed{}, errors.New("hardware verifier store is nil")
	}
	if limit <= 0 {
		limit = 100
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Processed{}, err
	}
	defer tx.Rollback()

	rows, err := tx.QueryContext(ctx, `
SELECT j.id, j.provider_id, j.chip, j.chip_normalized, j.unified_memory_gb,
       j.bandwidth_tier, j.os_version, j.binary_version, j.generated_at, j.evidence,
       EXISTS (
           SELECT 1
             FROM hardware_verification_trust t
            WHERE t.provider_id = j.provider_id
              AND t.hardware_identity_hash = j.evidence #>> '{hardware,hardware_identity_hash}'
              AND t.chip_normalized = j.chip_normalized
              AND t.unified_memory_gb = j.unified_memory_gb
              AND (t.expires_at IS NULL OR t.expires_at > now())
       ) AS trust_matched,
       EXISTS (
           SELECT 1
             FROM chip_hardware_profiles ch
            WHERE ch.chip_normalized = j.chip_normalized
       ) AS chip_profile_matched
  FROM hardware_verification_jobs j
 WHERE j.status IN ('pending', 'waiting_trust')
 ORDER BY j.id
 LIMIT $1
 FOR UPDATE SKIP LOCKED`, limit)
	if err != nil {
		return Processed{}, err
	}
	var jobs []Job
	for rows.Next() {
		var job Job
		if err := rows.Scan(
			&job.ID,
			&job.ProviderID,
			&job.Chip,
			&job.ChipNormalized,
			&job.MemoryGB,
			&job.BandwidthTier,
			&job.OSVersion,
			&job.BinaryVersion,
			&job.GeneratedAt,
			&job.Evidence,
			&job.TrustMatched,
			&job.ChipProfileMatched,
		); err != nil {
			rows.Close()
			return Processed{}, err
		}
		jobs = append(jobs, job)
	}
	if err := rows.Close(); err != nil {
		return Processed{}, err
	}
	if err := rows.Err(); err != nil {
		return Processed{}, err
	}

	var processed Processed
	for _, job := range jobs {
		decision := Evaluate(job)
		if decision.Verified {
			if err := promoteJob(ctx, tx, job, decision); err != nil {
				return Processed{}, err
			}
			processed.Verified++
			continue
		}
		if decision.Reason == "missing_trusted_hardware_identity" || decision.Reason == "missing_trusted_chip_profile" {
			if err := waitTrustJob(ctx, tx, job.ID, decision.Reason); err != nil {
				return Processed{}, err
			}
			processed.Waiting++
			continue
		}
		if err := rejectJob(ctx, tx, job.ID, decision.Reason); err != nil {
			return Processed{}, err
		}
		processed.Rejected++
	}
	if err := tx.Commit(); err != nil {
		return Processed{}, err
	}
	return processed, nil
}

func Evaluate(job Job) Decision {
	return evaluateAt(job, time.Now().UTC())
}

func evaluateAt(job Job, now time.Time) Decision {
	if strings.TrimSpace(job.ProviderID) == "" {
		return reject("missing_provider_id")
	}
	if job.GeneratedAt.Before(now.Add(-maxEvidenceAge)) || job.GeneratedAt.After(now.Add(futureSkew)) {
		return reject("stale_job")
	}
	if job.MemoryGB < 8 || job.MemoryGB > 4096 {
		return reject("memory_out_of_range")
	}
	if len(job.Evidence) == 0 {
		return reject("missing_evidence")
	}
	var evidence Evidence
	if err := json.Unmarshal(job.Evidence, &evidence); err != nil {
		return reject("invalid_evidence_json")
	}
	if evidence.SchemaVersion != evidenceSchemaVersion {
		return reject("schema_version_mismatch")
	}
	if evidence.ProviderID != job.ProviderID {
		return reject("provider_id_mismatch")
	}
	evidenceGeneratedAt, err := time.Parse(time.RFC3339, evidence.GeneratedAt)
	if err != nil {
		return reject("invalid_evidence_generated_at")
	}
	if !evidenceGeneratedAt.Equal(job.GeneratedAt) {
		return reject("evidence_generated_at_mismatch")
	}
	if evidenceGeneratedAt.Before(now.Add(-maxEvidenceAge)) || evidenceGeneratedAt.After(now.Add(futureSkew)) {
		return reject("stale_evidence")
	}
	if normalizeChip(evidence.Hardware.Chip) != job.ChipNormalized {
		return reject("chip_mismatch")
	}
	if evidence.Hardware.MemoryGB != job.MemoryGB {
		return reject("memory_mismatch")
	}
	if !strings.EqualFold(strings.TrimSpace(evidence.Hardware.BandwidthTier), strings.TrimSpace(job.BandwidthTier)) {
		return reject("bandwidth_tier_mismatch")
	}
	if strings.TrimSpace(evidence.Hardware.OSVersion) != strings.TrimSpace(job.OSVersion) {
		return reject("os_version_mismatch")
	}
	if strings.TrimSpace(evidence.Hardware.BinaryVersion) != strings.TrimSpace(job.BinaryVersion) {
		return reject("binary_version_mismatch")
	}
	if !isLowerSHA256(evidence.Hardware.HardwareIdentityHash) {
		return reject("invalid_hardware_identity_hash")
	}
	if !isLowerSHA256(evidence.CandidateCatalogSHA256) {
		return reject("invalid_candidate_catalog_sha256")
	}
	if len(evidence.Benchmarks) == 0 {
		return reject("missing_benchmarks")
	}
	seenModelKeys := make(map[string]struct{}, len(evidence.Benchmarks))
	for _, benchmark := range evidence.Benchmarks {
		modelKey := strings.TrimSpace(benchmark.ModelKey)
		if modelKey == "" || strings.TrimSpace(benchmark.ModelID) == "" {
			return reject("missing_benchmark_model_binding")
		}
		if _, exists := seenModelKeys[modelKey]; exists {
			return reject("duplicate_benchmark_model_key")
		}
		seenModelKeys[modelKey] = struct{}{}
		if !isLowerSHA256(benchmark.ArtifactSHA256) {
			return reject("invalid_benchmark_artifact_sha256")
		}
		if benchmark.CandidateCatalogSHA256 != evidence.CandidateCatalogSHA256 {
			return reject("benchmark_catalog_mismatch")
		}
		if benchmark.BinaryVersion != evidence.Hardware.BinaryVersion {
			return reject("benchmark_binary_version_mismatch")
		}
		if benchmark.HardwareIdentityHash != evidence.Hardware.HardwareIdentityHash {
			return reject("benchmark_hardware_identity_mismatch")
		}
		benchmarkGeneratedAt, parseErr := time.Parse(time.RFC3339, benchmark.GeneratedAt)
		if parseErr != nil {
			return reject("invalid_benchmark_generated_at")
		}
		if benchmarkGeneratedAt.Before(now.Add(-maxEvidenceAge)) || benchmarkGeneratedAt.After(now.Add(futureSkew)) {
			return reject("stale_benchmark")
		}
		if math.IsNaN(benchmark.SustainedTPS) || math.IsInf(benchmark.SustainedTPS, 0) || benchmark.SustainedTPS <= 0 {
			return reject("invalid_benchmark_tps")
		}
		if benchmark.TTFTMS <= 0 {
			return reject("invalid_benchmark_ttft")
		}
	}
	if !hasPositiveBenchmark(evidence.Benchmarks) {
		return reject("missing_positive_benchmark")
	}
	if strings.TrimSpace(job.ChipNormalized) == "" {
		return reject("missing_chip_normalized")
	}
	if !job.TrustMatched {
		return reject("missing_trusted_hardware_identity")
	}
	if !job.ChipProfileMatched {
		return reject("missing_trusted_chip_profile")
	}
	return Decision{Verified: true, Reason: VerifiedDecisionReason}
}

func promoteJob(ctx context.Context, tx *sql.Tx, job Job, decision Decision) error {
	if _, err := tx.ExecContext(ctx, `
INSERT INTO provider_hardware_profiles (
    provider_id, chip, chip_normalized, unified_memory_gb,
    macos_version, app_version, source, verified, last_reported_at
) VALUES (
    $1, $2, $3, $4, $5, $6, 'cli_hello', TRUE, $7
)
ON CONFLICT (provider_id) DO UPDATE
   SET chip = EXCLUDED.chip,
       chip_normalized = EXCLUDED.chip_normalized,
       unified_memory_gb = EXCLUDED.unified_memory_gb,
       macos_version = EXCLUDED.macos_version,
       app_version = EXCLUDED.app_version,
       source = EXCLUDED.source,
       verified = TRUE,
       last_reported_at = EXCLUDED.last_reported_at
 WHERE provider_hardware_profiles.last_reported_at <= EXCLUDED.last_reported_at`,
		job.ProviderID,
		job.Chip,
		job.ChipNormalized,
		job.MemoryGB,
		job.OSVersion,
		job.BinaryVersion,
		job.GeneratedAt.UTC(),
	); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `
UPDATE hardware_verification_jobs
   SET status = 'verified',
       processed_at = now(),
       decision_reason = $2
 WHERE id = $1 AND status IN ('pending', 'waiting_trust')`, job.ID, decision.Reason)
	return err
}

func waitTrustJob(ctx context.Context, tx *sql.Tx, id int64, reason string) error {
	_, err := tx.ExecContext(ctx, `
UPDATE hardware_verification_jobs
   SET status = 'waiting_trust',
       processed_at = now(),
       decision_reason = $2
 WHERE id = $1 AND status IN ('pending', 'waiting_trust')`, id, verifierDecisionVersion+":"+reason)
	return err
}

func rejectJob(ctx context.Context, tx *sql.Tx, id int64, reason string) error {
	_, err := tx.ExecContext(ctx, `
UPDATE hardware_verification_jobs
   SET status = 'rejected',
       processed_at = now(),
       decision_reason = $2
 WHERE id = $1 AND status IN ('pending', 'waiting_trust')`, id, verifierDecisionVersion+":"+reason)
	return err
}

func reject(reason string) Decision {
	return Decision{Verified: false, Reason: reason}
}

func hasPositiveBenchmark(benchmarks []Benchmark) bool {
	for _, b := range benchmarks {
		if b.SustainedTPS > 0 && !math.IsNaN(b.SustainedTPS) && !math.IsInf(b.SustainedTPS, 0) {
			return true
		}
	}
	return false
}

func normalizeChip(chip string) string {
	chip = strings.ToLower(strings.TrimSpace(chip))
	return strings.Join(strings.Fields(chip), " ")
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
