package onboarding

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/stats/hardwareverify"
)

const hardwareEvidenceSchemaVersion = "hardware_evidence.autotune.v2"
const hardwareEvidenceProbeProtocol = "spec-023-harmony-stream.v2"
const hardwareEvidenceRecentWindow = 10 * time.Minute
const hardwareEvidenceMaxAge = 7 * 24 * time.Hour
const hardwareEvidenceFutureSkew = 5 * time.Minute

const (
	hardwareEvidenceJobPending      = "pending"
	hardwareEvidenceJobWaitingTrust = "waiting_trust"
	hardwareEvidenceJobVerified     = "verified"

	hardwareEvidenceResponseQueued   = "queued"
	hardwareEvidenceResponseExisting = "existing"
	hardwareEvidenceResponseVerified = "verified"
)

var ErrHardwareEvidenceRateLimited = errors.New("hardware evidence rate limited")

// HardwareEvidenceRequest is provider-authenticated autotune evidence. The
// coordinator queues it for the verifier sidecar; public stats only consume it
// after the sidecar promotes a conservative trusted profile.
type HardwareEvidenceRequest struct {
	SchemaVersion          string                      `json:"schema_version"`
	ProviderID             string                      `json:"provider_id"`
	GeneratedAt            string                      `json:"generated_at"`
	Hardware               HardwareEvidenceHardware    `json:"hardware"`
	CandidateCatalogSHA256 string                      `json:"candidate_catalog_sha256"`
	RecommendedModel       string                      `json:"recommended_model"`
	ProbeProtocol          string                      `json:"probe_protocol"`
	Benchmarks             []HardwareEvidenceBenchmark `json:"benchmarks"`
}

type HardwareEvidenceHardware struct {
	Chip                 string `json:"chip"`
	MemoryGB             int    `json:"memory_gb"`
	BandwidthTier        string `json:"bandwidth_tier"`
	Detected             bool   `json:"detected"`
	OSVersion            string `json:"os_version"`
	BinaryVersion        string `json:"binary_version"`
	HardwareIdentityHash string `json:"hardware_identity_hash"`
	ExecutableSHA256     string `json:"executable_sha256"`
}

type HardwareEvidenceBenchmark struct {
	ModelKey string `json:"model_key"`
	ModelID  string `json:"model_id"`
	// ModelArtifactPath is the resolved local load path actually probed (#745 AC-4).
	ModelArtifactPath       string  `json:"model_artifact_path,omitempty"`
	SustainedTPS            float64 `json:"sustained_tps"`
	TTFTMS                  int     `json:"ttft_ms"`
	SwapDetected            bool    `json:"swap_detected"`
	ThermalThrottleDetected bool    `json:"thermal_throttle_detected"`
	ArtifactSHA256          string  `json:"artifact_sha256"`
	CandidateCatalogSHA256  string  `json:"candidate_catalog_sha256"`
	CandidateRowIdentity    string  `json:"candidate_row_identity"`
	BenchmarkID             string  `json:"benchmark_id,omitempty"`
	GeneratedAt             string  `json:"generated_at"`
	BinaryVersion           string  `json:"binary_version"`
	HardwareIdentityHash    string  `json:"hardware_identity_hash"`
}

type HardwareEvidenceJobRecord struct {
	JobID          int64
	EvidenceSHA    string
	Status         string
	DecisionReason string
	Replay         bool
}

// InsertHardwareVerificationJob queues provider-authenticated evidence for the
// out-of-band verifier and may persist the untrusted provider hardware profile.
func (s *PGStore) InsertHardwareVerificationJob(ctx context.Context, providerID string, evidence HardwareEvidenceRequest, generatedAt time.Time) (HardwareEvidenceJobRecord, error) {
	if s == nil || s.db == nil {
		return HardwareEvidenceJobRecord{}, errors.New("onboarding postgres store is nil")
	}
	evidenceSHA, raw, err := canonicalEvidenceSHA(evidence)
	if err != nil {
		return HardwareEvidenceJobRecord{}, err
	}

	chip := trimForStorage(evidence.Hardware.Chip, 120)
	normalized := normalizeChip(chip)
	macosVersion := trimForStorage(evidence.Hardware.OSVersion, 80)
	appVersion := trimForStorage(evidence.Hardware.BinaryVersion, 80)
	memoryGB := evidence.Hardware.MemoryGB
	if memoryGB < 0 {
		memoryGB = 0
	}
	if memoryGB > 4096 {
		memoryGB = 4096
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return HardwareEvidenceJobRecord{}, err
	}
	defer tx.Rollback()

	var existing HardwareEvidenceJobRecord
	err = tx.QueryRowContext(ctx, `
SELECT id, status, decision_reason
  FROM hardware_verification_jobs
 WHERE provider_id = $1
   AND evidence_sha256 = $2
 LIMIT 1`, providerID, evidenceSHA).Scan(&existing.JobID, &existing.Status, &existing.DecisionReason)
	if err == nil {
		existing.EvidenceSHA = evidenceSHA
		return existing, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return HardwareEvidenceJobRecord{}, err
	}

	var recentJobs int
	if err := tx.QueryRowContext(ctx, `
SELECT COUNT(*)
  FROM hardware_verification_jobs
 WHERE provider_id = $1
   AND (status IN ('pending', 'waiting_trust') OR submitted_at > now() - $2::interval)`,
		providerID,
		fmt.Sprintf("%d seconds", int(hardwareEvidenceRecentWindow.Seconds())),
	).Scan(&recentJobs); err != nil {
		return HardwareEvidenceJobRecord{}, err
	}
	if recentJobs > 0 {
		return HardwareEvidenceJobRecord{}, ErrHardwareEvidenceRateLimited
	}

	if _, err := tx.ExecContext(ctx, `
INSERT INTO provider_hardware_profiles (
    provider_id, chip, chip_normalized, unified_memory_gb,
    macos_version, app_version, source, last_reported_at
) VALUES (
    $1, $2, $3, $4, $5, $6, 'cli_hello', $7
)
ON CONFLICT (provider_id) DO UPDATE
   SET chip = $2,
       chip_normalized = $3,
       unified_memory_gb = $4,
       macos_version = $5,
       app_version = $6,
       source = 'cli_hello',
       last_reported_at = $7
 WHERE provider_hardware_profiles.last_reported_at <= $7`,
		providerID, chip, normalized, memoryGB, macosVersion, appVersion, generatedAt.UTC(),
	); err != nil {
		return HardwareEvidenceJobRecord{}, err
	}

	var record HardwareEvidenceJobRecord
	err = tx.QueryRowContext(ctx, `
WITH inserted AS (
    INSERT INTO hardware_verification_jobs (
        provider_id, source, status, chip, chip_normalized, unified_memory_gb,
        bandwidth_tier, os_version, binary_version, benchmark_count,
        max_sustained_tps, generated_at, evidence, evidence_sha256
    ) VALUES (
        $1, 'autotune', 'pending', $2, $3, $4,
        $5, $6, $7, $8,
        $9, $10, $11, $12
    )
    ON CONFLICT (evidence_sha256) DO NOTHING
    RETURNING id, status, decision_reason
)
SELECT id, status, decision_reason FROM inserted
UNION ALL
SELECT id, status, decision_reason
  FROM hardware_verification_jobs
 WHERE provider_id = $1
   AND evidence_sha256 = $12
LIMIT 1`,
		providerID,
		chip,
		normalized,
		memoryGB,
		trimForStorage(evidence.Hardware.BandwidthTier, 20),
		macosVersion,
		appVersion,
		len(evidence.Benchmarks),
		maxBenchmarkTPS(evidence.Benchmarks),
		generatedAt.UTC(),
		raw,
		evidenceSHA,
	).Scan(&record.JobID, &record.Status, &record.DecisionReason)
	if err != nil {
		return HardwareEvidenceJobRecord{}, err
	}
	if err := tx.Commit(); err != nil {
		return HardwareEvidenceJobRecord{}, err
	}
	record.EvidenceSHA = evidenceSHA
	return record, nil
}

func (s *PGStore) ExistingHardwareVerificationJob(ctx context.Context, providerID, evidenceSHA string) (HardwareEvidenceJobRecord, bool, error) {
	if s == nil || s.db == nil {
		return HardwareEvidenceJobRecord{}, false, errors.New("onboarding postgres store is nil")
	}
	var record HardwareEvidenceJobRecord
	err := s.db.QueryRowContext(ctx, `
SELECT id, status, decision_reason
  FROM hardware_verification_jobs
 WHERE provider_id = $1
   AND evidence_sha256 = $2
 LIMIT 1`, providerID, evidenceSHA).Scan(&record.JobID, &record.Status, &record.DecisionReason)
	if errors.Is(err, sql.ErrNoRows) {
		return HardwareEvidenceJobRecord{}, false, nil
	}
	if err != nil {
		return HardwareEvidenceJobRecord{}, false, err
	}
	record.EvidenceSHA = evidenceSHA
	return record, true, nil
}

func (h *Handler) HandleHardwareEvidence(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeJSONError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	if h.StatsDB == nil || h.AuthTokenStore == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "unavailable", "onboarding dependencies unavailable")
		return
	}
	token := bearerToken(r.Header)
	providerID, ok, err := h.AuthTokenStore.ValidateToken(r.Context(), token)
	if err != nil {
		writeJSONError(w, http.StatusServiceUnavailable, "unavailable", "token validation unavailable")
		return
	}
	if !ok {
		writeJSONError(w, http.StatusUnauthorized, "unauthorized", "provider bearer token required")
		return
	}
	sourceIP := clientIP(r, h.TrustedProxies)
	if h.HardwareEvidenceIPRateLimiter != nil && !h.HardwareEvidenceIPRateLimiter.Allow(sourceIP) {
		w.Header().Set("Retry-After", "60")
		writeJSONError(w, http.StatusTooManyRequests, "rate_limited", "hardware evidence ip rate limit exceeded")
		return
	}
	body, err := readBoundedBody(w, r, 128*1024)
	if err != nil {
		writeJSONError(w, http.StatusRequestEntityTooLarge, "request_too_large", "body exceeds 128 KiB")
		return
	}
	var req HardwareEvidenceRequest
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_json", "request body is not valid hardware evidence JSON")
		return
	}
	if dec.Decode(&struct{}{}) != io.EOF {
		writeJSONError(w, http.StatusBadRequest, "invalid_json", "request body must contain exactly one JSON object")
		return
	}
	generatedAt, err := h.validateHardwareEvidence(req, providerID)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_evidence", err.Error())
		return
	}
	store, ok := h.StatsDB.(interface {
		InsertHardwareVerificationJob(context.Context, string, HardwareEvidenceRequest, time.Time) (HardwareEvidenceJobRecord, error)
	})
	if !ok {
		writeJSONError(w, http.StatusServiceUnavailable, "unavailable", "hardware evidence queue unavailable")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), hardwareProfilePersistTimeout)
	defer cancel()
	evidenceSHA, _, err := canonicalEvidenceSHA(req)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_evidence", "hardware evidence cannot be canonicalized")
		return
	}
	if duplicateStore, ok := h.StatsDB.(interface {
		ExistingHardwareVerificationJob(context.Context, string, string) (HardwareEvidenceJobRecord, bool, error)
	}); ok {
		existing, found, lookupErr := duplicateStore.ExistingHardwareVerificationJob(ctx, providerID, evidenceSHA)
		if lookupErr != nil {
			writeJSONError(w, http.StatusServiceUnavailable, "unavailable", "hardware evidence queue unavailable")
			return
		}
		if found {
			status, accepted := hardwareEvidenceResponseStatus(existing, true, evidenceSHA)
			if !accepted {
				writeJSONError(w, http.StatusConflict, "evidence_replay_not_accepted", "existing hardware evidence is not in an accepted replay state")
				return
			}
			writeHardwareEvidenceResponse(w, status, providerID, existing)
			return
		}
	}
	if h.HardwareEvidenceProviderRateLimiter != nil && !h.HardwareEvidenceProviderRateLimiter.Allow(providerID) {
		w.Header().Set("Retry-After", "600")
		writeJSONError(w, http.StatusTooManyRequests, "rate_limited", "hardware evidence provider rate limit exceeded")
		return
	}
	record, err := store.InsertHardwareVerificationJob(ctx, providerID, req, generatedAt)
	if err != nil {
		if errors.Is(err, ErrHardwareEvidenceRateLimited) {
			w.Header().Set("Retry-After", "600")
			writeJSONError(w, http.StatusTooManyRequests, "rate_limited", "hardware evidence queue already has a recent job")
			return
		}
		writeJSONError(w, http.StatusServiceUnavailable, "unavailable", "hardware evidence queue unavailable")
		return
	}
	status, accepted := hardwareEvidenceResponseStatus(record, false, evidenceSHA)
	if !accepted {
		writeJSONError(w, http.StatusConflict, "evidence_replay_not_accepted", "hardware evidence queue returned a non-accepted state")
		return
	}
	writeHardwareEvidenceResponse(w, status, providerID, record)
}

// hardwareEvidenceResponseStatus is the submission/replay state machine. New
// pending jobs queue normally. A duplicate may reuse work only while pending,
// while waiting for operator trust, or after the current verifier has recorded
// its exact trusted-hardware decision. Every other finalized or unknown state
// is fail-closed and must be resubmitted as new evidence instead of laundering
// a rejected/failed/legacy decision through an HTTP 2xx replay response.
func hardwareEvidenceResponseStatus(record HardwareEvidenceJobRecord, replay bool, expectedEvidenceSHA string) (string, bool) {
	if record.JobID <= 0 || record.EvidenceSHA != expectedEvidenceSHA || !isLowerSHA256(record.EvidenceSHA) {
		return "", false
	}
	replay = replay || record.Replay
	switch record.Status {
	case hardwareEvidenceJobPending:
		if replay {
			return hardwareEvidenceResponseExisting, true
		}
		return hardwareEvidenceResponseQueued, true
	case hardwareEvidenceJobWaitingTrust:
		return hardwareEvidenceResponseExisting, true
	case hardwareEvidenceJobVerified:
		if record.DecisionReason == hardwareverify.VerifiedDecisionReason {
			return hardwareEvidenceResponseVerified, true
		}
	}
	return "", false
}

func writeHardwareEvidenceResponse(w http.ResponseWriter, status, providerID string, record HardwareEvidenceJobRecord) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"status":       status,
		"provider_id":  providerID,
		"job_id":       record.JobID,
		"evidence_sha": record.EvidenceSHA,
	})
}

func (h *Handler) validateHardwareEvidence(req HardwareEvidenceRequest, tokenProviderID string) (time.Time, error) {
	if req.SchemaVersion != hardwareEvidenceSchemaVersion {
		return time.Time{}, errors.New("schema_version must be hardware_evidence.autotune.v2")
	}
	if req.ProbeProtocol != hardwareEvidenceProbeProtocol {
		return time.Time{}, errors.New("probe_protocol is not the supported SPEC-023 protocol")
	}
	if strings.TrimSpace(req.ProviderID) == "" || len(req.ProviderID) > 128 {
		return time.Time{}, errors.New("provider_id is required")
	}
	if req.ProviderID != tokenProviderID {
		return time.Time{}, errors.New("provider_id must match bearer token")
	}
	generatedAt, err := time.Parse(time.RFC3339, req.GeneratedAt)
	if err != nil {
		return time.Time{}, errors.New("generated_at must be RFC3339")
	}
	if !postgresMicrosecondAlignedRFC3339(req.GeneratedAt) {
		return time.Time{}, errors.New("generated_at must be aligned to Postgres microsecond precision")
	}
	now := time.Now().UTC()
	if h.Now != nil {
		now = h.Now().UTC()
	}
	if generatedAt.Before(now.Add(-hardwareEvidenceMaxAge)) || generatedAt.After(now.Add(hardwareEvidenceFutureSkew)) {
		return time.Time{}, errors.New("generated_at is outside the accepted window")
	}
	if strings.TrimSpace(req.Hardware.Chip) == "" || len(req.Hardware.Chip) > 120 {
		return time.Time{}, errors.New("hardware.chip is required")
	}
	if req.Hardware.MemoryGB <= 0 || req.Hardware.MemoryGB > 4096 {
		return time.Time{}, errors.New("hardware.memory_gb must be in 1...4096")
	}
	switch strings.ToUpper(strings.TrimSpace(req.Hardware.BandwidthTier)) {
	case "C", "B", "A", "S", "UNKNOWN":
	default:
		return time.Time{}, errors.New("hardware.bandwidth_tier is invalid")
	}
	if strings.TrimSpace(req.Hardware.OSVersion) == "" || len(req.Hardware.OSVersion) > 80 {
		return time.Time{}, errors.New("hardware.os_version is required")
	}
	if strings.TrimSpace(req.Hardware.BinaryVersion) == "" || len(req.Hardware.BinaryVersion) > 80 {
		return time.Time{}, errors.New("hardware.binary_version is required")
	}
	if !isLowerSHA256(req.Hardware.HardwareIdentityHash) {
		return time.Time{}, errors.New("hardware.hardware_identity_hash must be lowercase sha256")
	}
	if !isLowerSHA256(req.Hardware.ExecutableSHA256) {
		return time.Time{}, errors.New("hardware.executable_sha256 must be lowercase sha256")
	}
	if !isLowerSHA256(req.CandidateCatalogSHA256) {
		return time.Time{}, errors.New("candidate_catalog_sha256 must be lowercase sha256")
	}
	if len(req.RecommendedModel) > 240 {
		return time.Time{}, errors.New("recommended_model is too long")
	}
	if len(req.Benchmarks) == 0 || len(req.Benchmarks) > 64 {
		return time.Time{}, errors.New("benchmarks must contain 1...64 entries")
	}
	seenModelKeys := make(map[string]struct{}, len(req.Benchmarks))
	for _, b := range req.Benchmarks {
		modelKey := strings.TrimSpace(b.ModelKey)
		if modelKey == "" || len(b.ModelKey) > 160 {
			return time.Time{}, errors.New("benchmark.model_key is required")
		}
		if _, exists := seenModelKeys[modelKey]; exists {
			return time.Time{}, errors.New("benchmark.model_key must be unique")
		}
		seenModelKeys[modelKey] = struct{}{}
		if strings.TrimSpace(b.ModelID) == "" || len(b.ModelID) > 240 {
			return time.Time{}, errors.New("benchmark.model_id is required")
		}
		if math.IsNaN(b.SustainedTPS) || math.IsInf(b.SustainedTPS, 0) || b.SustainedTPS <= 0 || b.SustainedTPS > 1_000_000 {
			return time.Time{}, errors.New("benchmark.sustained_tps is invalid")
		}
		if b.TTFTMS <= 0 || b.TTFTMS > 3_600_000 {
			return time.Time{}, errors.New("benchmark.ttft_ms is invalid")
		}
		if !isLowerSHA256(b.ArtifactSHA256) {
			return time.Time{}, errors.New("benchmark.artifact_sha256 must be lowercase sha256")
		}
		if b.CandidateCatalogSHA256 != req.CandidateCatalogSHA256 {
			return time.Time{}, errors.New("benchmark.candidate_catalog_sha256 must match evidence")
		}
		if len(b.BenchmarkID) > 160 {
			return time.Time{}, errors.New("benchmark.benchmark_id is too long")
		}
		benchmarkGeneratedAt, parseErr := time.Parse(time.RFC3339, b.GeneratedAt)
		if parseErr != nil {
			return time.Time{}, errors.New("benchmark.generated_at must be RFC3339")
		}
		if benchmarkGeneratedAt.Before(now.Add(-hardwareEvidenceMaxAge)) || benchmarkGeneratedAt.After(now.Add(hardwareEvidenceFutureSkew)) {
			return time.Time{}, errors.New("benchmark.generated_at is outside the accepted window")
		}
		if b.BinaryVersion != req.Hardware.BinaryVersion {
			return time.Time{}, errors.New("benchmark.binary_version must match hardware")
		}
		if b.HardwareIdentityHash != req.Hardware.HardwareIdentityHash {
			return time.Time{}, errors.New("benchmark.hardware_identity_hash must match hardware")
		}
		if len(b.CandidateRowIdentity) != 64 || !isLowerHex(b.CandidateRowIdentity) {
			return time.Time{}, errors.New("benchmark.candidate_row_identity must be 64 lowercase hex characters")
		}
	}
	return generatedAt.UTC(), nil
}

// PostgreSQL timestamptz stores microseconds. Reject timestamps that would
// lose information on insert so the signed evidence JSON and its database
// binding remain exactly comparable during asynchronous verification. Extra
// fractional digits are accepted only when they are zero padding.
func postgresMicrosecondAlignedRFC3339(value string) bool {
	dot := strings.IndexByte(value, '.')
	if dot < 0 {
		return true
	}
	end := len(value)
	for i := dot + 1; i < len(value); i++ {
		if value[i] == 'Z' || value[i] == '+' || value[i] == '-' {
			end = i
			break
		}
	}
	fraction := value[dot+1 : end]
	if len(fraction) <= 6 {
		return true
	}
	for _, digit := range fraction[6:] {
		if digit != '0' {
			return false
		}
	}
	return true
}

func isLowerSHA256(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	for _, c := range value {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

func canonicalEvidenceJSON(evidence HardwareEvidenceRequest) ([]byte, error) {
	raw, err := json.Marshal(evidence)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	return billing.CanonicalJSON(value)
}

func canonicalEvidenceSHA(evidence HardwareEvidenceRequest) (string, []byte, error) {
	canonical, err := canonicalEvidenceJSON(evidence)
	if err != nil {
		return "", nil, err
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:]), canonical, nil
}

func maxBenchmarkTPS(benchmarks []HardwareEvidenceBenchmark) float64 {
	var max float64
	for _, b := range benchmarks {
		if b.SustainedTPS > max && !math.IsNaN(b.SustainedTPS) && !math.IsInf(b.SustainedTPS, 0) {
			max = b.SustainedTPS
		}
	}
	return max
}

func bearerToken(headers http.Header) string {
	auth := strings.TrimSpace(headers.Get("Authorization"))
	token, ok := strings.CutPrefix(auth, "Bearer ")
	if !ok {
		return ""
	}
	return strings.TrimSpace(token)
}
