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

	"github.com/lib/pq"
)

const verifierDecisionVersion = "hardware-verifier.v2"
const evidenceSchemaVersion = "hardware_evidence.autotune.v2"
const evidenceProbeProtocol = "spec-023-harmony-stream.v2"

// MaxEvidenceAgeDays is the evidence-age limit (in whole days) the verifier
// enforces: a job whose generated_at is older than this is rejected as
// stale_job/stale_evidence by Evaluate. It is exported so the operator
// hardware-trust approval path can reject an over-age job AT approval time using
// the SAME limit (issue #582 FIX 5), instead of committing an approval the
// verifier then rejects as stale on its next pass. maxEvidenceAge is derived
// from it so the two never drift.
const MaxEvidenceAgeDays = 7
const maxEvidenceAge = MaxEvidenceAgeDays * 24 * time.Hour
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
	ProbeProtocol          string      `json:"probe_protocol"`
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
	ExecutableSHA256     string `json:"executable_sha256"`
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
	CandidateRowIdentity    string  `json:"candidate_row_identity"`
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
	// lib/pq's sql.Open defers DSN parsing, so a malformed connection string only
	// surfaces later (e.g. at Smoke) as a net/url error that echoes the
	// credential-bearing URL into logs. Parse eagerly via pq.NewConnector so the
	// failure is caught here, and never surface the raw DSN in the error (issue
	// #582 FIX 6).
	connector, err := pq.NewConnector(dsn)
	if err != nil {
		return nil, errors.New("open hardware verifier postgres: invalid connection string (redacted)")
	}
	db := sql.OpenDB(connector)
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
			promoted, err := promoteJob(ctx, tx, job, decision)
			if err != nil {
				return Processed{}, err
			}
			// FIX 2 (issue #582): promoteJob re-validates the backing trust root
			// under this transaction and re-parks the job as waiting_trust when the
			// root went inactive between batch selection and promotion. Count it as
			// waiting, not verified, so the counters stay honest.
			if promoted {
				processed.Verified++
			} else {
				processed.Waiting++
			}
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
	if evidence.ProbeProtocol != evidenceProbeProtocol {
		return reject("probe_protocol_mismatch")
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
	if !isLowerSHA256(evidence.Hardware.ExecutableSHA256) {
		return reject("invalid_executable_sha256")
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
		if !isLowerSHA256(benchmark.CandidateRowIdentity) {
			return reject("invalid_benchmark_candidate_row_identity")
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

// promotionDecision maps a fresh in-transaction trust re-check to the action
// taken at promotion time (issue #582 FIX 2). A job that passed Evaluate but
// whose backing hardware trust root was expired/revoked/deleted between batch
// selection and this write must NOT be promoted; it is re-parked as
// waiting_trust with a reason the operator approval path can re-drive
// (missing_trusted_hardware_identity — the exact gate the approval endpoint and
// request_hardware_trust_approval accept).
func promotionDecision(trustStillActive bool) (promote bool, reparkReason string) {
	if trustStillActive {
		return true, ""
	}
	return false, "missing_trusted_hardware_identity"
}

// promoteJob promotes a verified job, but first re-validates — with a fresh read
// inside the verifier's transaction (which already holds the job FOR UPDATE) —
// that the backing hardware trust root is STILL active. The batch-selection scan
// read trust_matched at an earlier snapshot; the trust root can be
// expired/revoked/deleted (API revoke, applyTrustDemotions, inventory delete)
// in the window before this write. Re-checking here closes the
// revoke/demote/delete-vs-promote race uniformly at the source (issue #582
// FIX 2). Returns whether the job was actually promoted; false means it was
// re-parked as waiting_trust. This does NOT alter batch ordering/selection (the
// ORDER BY id LIMIT ... FOR UPDATE SKIP LOCKED fairness residual is unchanged).
func promoteJob(ctx context.Context, tx *sql.Tx, job Job, decision Decision) (bool, error) {
	// FIX 1 (issue #582): serialize this promotion against the operator
	// approve/revoke path by taking the SAME per-provider advisory lock the
	// SECURITY DEFINER functions use — key/args (582026, hashtext(provider_id))
	// match request/approve/revoke_hardware_trust_approval in
	// 019_hardware_trust_operator_approval.up.sql exactly. Without it a concurrent
	// revoke that expired the backing trust root can interleave between this
	// re-check and the profile write.
	//
	// FIX 5 (round-6 deadlock fix, issue #582): use the NON-BLOCKING
	// pg_try_advisory_xact_lock, not the blocking pg_advisory_xact_lock. This
	// transaction already holds the job row FOR UPDATE (from the batch SELECT) and
	// only NOW requests the provider advisory lock; approve/revoke take the advisory
	// lock FIRST and then the job row locks. A blocking wait here would close that
	// lock cycle into a deadlock (40P01). Instead, if the lock is already held by a
	// concurrent approve/revoke, SKIP this job's promotion this pass and leave it
	// parked in its current status; the next verifier tick re-selects it (this
	// mirrors the batch's FOR UPDATE SKIP LOCKED philosophy). The job is reported as
	// NOT promoted, so ProcessPending counts it as waiting — never verified or
	// rejected. Taking the lock here does NOT touch the batch SELECT ordering above.
	var lockAcquired bool
	if err := tx.QueryRowContext(ctx, `SELECT pg_try_advisory_xact_lock(582026, hashtext($1))`, job.ProviderID).Scan(&lockAcquired); err != nil {
		return false, err
	}
	if !lockAcquired {
		return false, nil
	}
	var trustStillActive bool
	// FIX 1 (issue #582): compare expires_at against clock_timestamp() (real time,
	// advances mid-transaction) rather than now()/transaction_timestamp() (frozen
	// at transaction start). A revoke that set expires_at = clock_timestamp() after
	// this verifier transaction began would still satisfy `expires_at > now()`
	// (frozen), promoting a just-revoked root; clock_timestamp() sees it inactive.
	if err := tx.QueryRowContext(ctx, `
SELECT EXISTS (
    SELECT 1
      FROM hardware_verification_jobs j
      JOIN hardware_verification_trust t
        ON t.provider_id = j.provider_id
       AND t.hardware_identity_hash = j.evidence #>> '{hardware,hardware_identity_hash}'
       AND t.chip_normalized = j.chip_normalized
       AND t.unified_memory_gb = j.unified_memory_gb
       AND (t.expires_at IS NULL OR t.expires_at > clock_timestamp())
     WHERE j.id = $1
)`, job.ID).Scan(&trustStillActive); err != nil {
		return false, err
	}
	if promote, reparkReason := promotionDecision(trustStillActive); !promote {
		// The trust root went inactive since selection — re-park instead of
		// promoting so a later operator approval can re-drive the job.
		if err := waitTrustJob(ctx, tx, job.ID, reparkReason); err != nil {
			return false, err
		}
		return false, nil
	}
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
		return false, err
	}
	if _, err := tx.ExecContext(ctx, `
UPDATE hardware_verification_jobs
   SET status = 'verified',
       processed_at = now(),
       decision_reason = $2
 WHERE id = $1 AND status IN ('pending', 'waiting_trust')`, job.ID, decision.Reason); err != nil {
		return false, err
	}
	return true, nil
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
