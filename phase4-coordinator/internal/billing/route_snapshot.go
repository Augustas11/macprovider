package billing

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"modernc.org/sqlite"
)

const (
	// RouteSnapshotPolicyVersion is bumped whenever the effective settlement
	// policy that route snapshots are pinned to changes materially — e.g.
	// the pending_deadline_seconds default (30 -> 300, see
	// settlement.pending_deadline_seconds). Existing rows keep their
	// original version (immutable per row); this only affects new
	// snapshots. Cross-service consumers that gate on an exact version
	// string (currently phase5-gateway's settlementPolicyVersion check)
	// must accept both this and the immediately-prior version during
	// rollout so in-flight/legacy rows keep settling.
	RouteSnapshotPolicyVersion       = "spec022-prereq-v1"
	RouteSnapshotModeObserve         = "observe"
	RouteSnapshotModeEnforce         = "enforce"
	MaxPendingReceiptDeadlineSeconds = 900
	routeSnapshotRetryInitialDelay   = 10 * time.Millisecond
	routeSnapshotRetryMaxDelay       = 100 * time.Millisecond
	routeSnapshotPrimaryMirrorBudget = 25 * time.Millisecond
)

var (
	hex64Pattern        = regexp.MustCompile(`^[0-9a-f]{64}$`)
	receiptKeyIDPattern = regexp.MustCompile(`^ed25519-sha256:[0-9a-f]{64}$`)

	// ErrRouteSnapshotStorePressure marks transient persistence pressure before
	// provider dispatch. Callers may shed capacity; settlement validation errors
	// are never wrapped with this sentinel.
	ErrRouteSnapshotStorePressure = errors.New("route snapshot store pressure")
)

type RouteSnapshot struct {
	AccountScope                         string  `json:"account_scope"`
	RequestID                            string  `json:"request_id"`
	AttemptN                             int64   `json:"attempt_n"`
	ProviderID                           string  `json:"provider_id"`
	ProviderSessionID                    *string `json:"provider_session_id"`
	ProviderGenerationID                 *string `json:"provider_generation_id"`
	PaidEntrypoint                       string  `json:"paid_entrypoint"`
	ProviderReceiptKeyID                 string  `json:"provider_receipt_key_id"`
	ProviderReceiptKeySource             string  `json:"provider_receipt_key_source"`
	ModelID                              string  `json:"model_id"`
	ProviderReportedModelHash            string  `json:"provider_reported_model_hash"`
	ProviderReportedModelHashAlgorithm   string  `json:"provider_reported_model_hash_algorithm"`
	ExpectedCatalogModelHash             string  `json:"expected_catalog_model_hash"`
	ExpectedCatalogModelHashAlgorithm    string  `json:"expected_catalog_model_hash_algorithm"`
	CatalogID                            string  `json:"catalog_id"`
	CatalogBodyDigest                    string  `json:"catalog_body_digest"`
	CatalogSignatureKeyID                string  `json:"catalog_signature_key_id"`
	CatalogSignaturePubkeyFingerprint    string  `json:"catalog_signature_pubkey_fingerprint"`
	CatalogExpiresAtUnixMS               int64   `json:"catalog_expires_at_unix_ms"`
	Spec008HashStatus                    string  `json:"spec008_hash_status"`
	RouteSnapshotPolicyVersion           string  `json:"route_snapshot_policy_version"`
	RouteSnapshotMode                    string  `json:"route_snapshot_mode"`
	RouteDecisionTSUnixMS                int64   `json:"route_decision_ts_unix_ms"`
	RequestStartTSUnixMS                 int64   `json:"request_start_ts_unix_ms"`
	PendingDeadlineSeconds               int64   `json:"pending_deadline_seconds"`
	PromptHashBasis                      string  `json:"prompt_hash_basis"`
	PromptHash                           string  `json:"prompt_hash"`
	ModelAdmissionCandidateID            string  `json:"model_admission_candidate_id,omitempty"`
	ModelAdmissionCoordinatorEventID     string  `json:"model_admission_coordinator_event_id,omitempty"`
	ModelAdmissionServedModelRef         string  `json:"model_admission_served_model_ref,omitempty"`
	ModelAdmissionCatalogModelKey        string  `json:"model_admission_catalog_model_key,omitempty"`
	ModelAdmissionDiscoveryDigestSHA256  string  `json:"model_admission_discovery_digest_sha256,omitempty"`
	ModelAdmissionEvaluationDigestSHA256 string  `json:"model_admission_evaluation_digest_sha256,omitempty"`
	// PoolID is the SPEC-042 Trusted Pool that served this request ("" for
	// global). It binds into the canonical route-snapshot digest / settlement
	// context (SPEC-042 R006) but ONLY when non-empty, so poolless snapshots
	// keep byte-identical digests. Like the *_model_hash_algorithm fields it
	// is carried in route_snapshot_json (not a dedicated column) and recovered
	// on the settlement recompute path so insert-digest == recompute-digest.
	PoolID string `json:"pool_id"`
	// SPEC-010 v1.7 R007(d) / SPEC-047-R003: the six artifact values of a
	// feed-derived binding. Carried in route_snapshot_json (no dedicated
	// columns), bound into the digest only when present, recovered on the
	// settlement recompute path. All six or none; a partial record is invalid.
	ArtifactFeedSHA256              string `json:"artifact_feed_sha256"`
	ArtifactID                      string `json:"artifact_id"`
	ArtifactHash                    string `json:"artifact_hash"`
	ArtifactHashAlgorithm           string `json:"artifact_hash_algorithm"`
	ArtifactFeedSignerKeyID         string `json:"artifact_feed_signer_key_id"`
	ArtifactCandidateCatalogSHA256  string `json:"artifact_candidate_catalog_sha256"`
	ComputeIntegrityCaptureRequired bool   `json:"-"`
	ComputeIntegritySamplingCovered bool   `json:"-"`
	ComputeIntegrityHardwareDigest  string `json:"-"`
}

func ReceiptKeyID(pubkey []byte) (string, error) {
	if len(pubkey) != ed25519.PublicKeySize {
		return "", fmt.Errorf("receipt pubkey length=%d want %d", len(pubkey), ed25519.PublicKeySize)
	}
	sum := sha256.Sum256(pubkey)
	return "ed25519-sha256:" + hex.EncodeToString(sum[:]), nil
}

func (r RouteSnapshot) Value() map[string]any {
	value := map[string]any{
		"account_scope":                        r.AccountScope,
		"request_id":                           r.RequestID,
		"attempt_n":                            int64(r.AttemptN),
		"provider_id":                          r.ProviderID,
		"provider_session_id":                  nullableString(r.ProviderSessionID),
		"provider_generation_id":               nullableString(r.ProviderGenerationID),
		"paid_entrypoint":                      r.PaidEntrypoint,
		"provider_receipt_key_id":              r.ProviderReceiptKeyID,
		"provider_receipt_key_source":          r.ProviderReceiptKeySource,
		"model_id":                             r.ModelID,
		"provider_reported_model_hash":         r.ProviderReportedModelHash,
		"expected_catalog_model_hash":          r.ExpectedCatalogModelHash,
		"catalog_id":                           r.CatalogID,
		"catalog_body_digest":                  r.CatalogBodyDigest,
		"catalog_signature_key_id":             r.CatalogSignatureKeyID,
		"catalog_signature_pubkey_fingerprint": r.CatalogSignaturePubkeyFingerprint,
		"catalog_expires_at_unix_ms":           int64(r.CatalogExpiresAtUnixMS),
		"spec008_hash_status":                  r.Spec008HashStatus,
		"route_snapshot_policy_version":        r.RouteSnapshotPolicyVersion,
		"route_snapshot_mode":                  r.RouteSnapshotMode,
		"route_decision_ts_unix_ms":            int64(r.RouteDecisionTSUnixMS),
		"request_start_ts_unix_ms":             int64(r.RequestStartTSUnixMS),
		"pending_deadline_seconds":             int64(r.PendingDeadlineSeconds),
		"prompt_hash_basis":                    r.PromptHashBasis,
		"prompt_hash":                          r.PromptHash,
	}
	if r.ProviderReportedModelHashAlgorithm != "" || r.ExpectedCatalogModelHashAlgorithm != "" {
		value["provider_reported_model_hash_algorithm"] = r.ProviderReportedModelHashAlgorithm
		value["expected_catalog_model_hash_algorithm"] = r.ExpectedCatalogModelHashAlgorithm
	}
	// SPEC-042 R006: bind pool_id into the canonical route-snapshot digest,
	// but only when a pool served the request — a poolless snapshot omits it
	// and keeps a byte-identical digest to pre-SPEC-042.
	if r.PoolID != "" {
		value["pool_id"] = r.PoolID
	}
	if r.ModelAdmissionCandidateID != "" {
		value["model_admission_candidate_id"] = r.ModelAdmissionCandidateID
		value["model_admission_coordinator_event_id"] = r.ModelAdmissionCoordinatorEventID
		value["model_admission_served_model_ref"] = r.ModelAdmissionServedModelRef
		value["model_admission_catalog_model_key"] = r.ModelAdmissionCatalogModelKey
		value["model_admission_discovery_digest_sha256"] = r.ModelAdmissionDiscoveryDigestSHA256
		value["model_admission_evaluation_digest_sha256"] = r.ModelAdmissionEvaluationDigestSHA256
	}
	if r.ArtifactDerived() {
		value["artifact_feed_sha256"] = r.ArtifactFeedSHA256
		value["artifact_id"] = r.ArtifactID
		value["artifact_hash"] = r.ArtifactHash
		value["artifact_hash_algorithm"] = r.ArtifactHashAlgorithm
		value["artifact_feed_signer_key_id"] = r.ArtifactFeedSignerKeyID
		value["artifact_candidate_catalog_sha256"] = r.ArtifactCandidateCatalogSHA256
	}
	return value
}

// ArtifactDerived reports whether the snapshot references an artifact-feed
// member (any of the six SPEC-047-R003 values present).
func (r RouteSnapshot) ArtifactDerived() bool {
	return r.ArtifactFeedSHA256 != "" || r.ArtifactID != "" || r.ArtifactHash != "" ||
		r.ArtifactHashAlgorithm != "" || r.ArtifactFeedSignerKeyID != "" || r.ArtifactCandidateCatalogSHA256 != ""
}

func (r RouteSnapshot) Digest() (digest string, canonical []byte, err error) {
	if err := r.Validate(); err != nil {
		return "", nil, err
	}
	return CanonicalSHA256Hex(r.Value())
}

func (r RouteSnapshot) Validate() error {
	required := map[string]string{
		"account_scope":                        r.AccountScope,
		"request_id":                           r.RequestID,
		"provider_id":                          r.ProviderID,
		"paid_entrypoint":                      r.PaidEntrypoint,
		"provider_receipt_key_id":              r.ProviderReceiptKeyID,
		"provider_receipt_key_source":          r.ProviderReceiptKeySource,
		"model_id":                             r.ModelID,
		"provider_reported_model_hash":         r.ProviderReportedModelHash,
		"expected_catalog_model_hash":          r.ExpectedCatalogModelHash,
		"catalog_id":                           r.CatalogID,
		"catalog_body_digest":                  r.CatalogBodyDigest,
		"catalog_signature_key_id":             r.CatalogSignatureKeyID,
		"catalog_signature_pubkey_fingerprint": r.CatalogSignaturePubkeyFingerprint,
		"spec008_hash_status":                  r.Spec008HashStatus,
		"route_snapshot_policy_version":        r.RouteSnapshotPolicyVersion,
		"route_snapshot_mode":                  r.RouteSnapshotMode,
		"prompt_hash_basis":                    r.PromptHashBasis,
		"prompt_hash":                          r.PromptHash,
	}
	for field, value := range required {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("route snapshot missing %s", field)
		}
	}
	if r.AttemptN < 0 {
		return fmt.Errorf("route snapshot attempt_n must be >= 0")
	}
	if !receiptKeyIDPattern.MatchString(r.ProviderReceiptKeyID) {
		return fmt.Errorf("route snapshot provider_receipt_key_id invalid")
	}
	if r.ProviderReceiptKeySource != "auth_session" && r.ProviderReceiptKeySource != "rotation_grace" && r.ProviderReceiptKeySource != "operator_pin" {
		return fmt.Errorf("route snapshot provider_receipt_key_source invalid")
	}
	if r.RouteSnapshotMode != RouteSnapshotModeObserve && r.RouteSnapshotMode != RouteSnapshotModeEnforce {
		return fmt.Errorf("route snapshot route_snapshot_mode invalid")
	}
	if (r.ProviderReportedModelHashAlgorithm != "" || r.ExpectedCatalogModelHashAlgorithm != "") &&
		(!modelidentity.CanonicalAlgorithm(r.ProviderReportedModelHashAlgorithm) ||
			r.ProviderReportedModelHashAlgorithm != r.ExpectedCatalogModelHashAlgorithm) {
		return fmt.Errorf("route snapshot model hash algorithm invalid")
	}
	// SPEC-010 v1.7 R007(d): a GGUF (non-row) expected identity can only be an
	// artifact-feed member, so the six values are mandatory; any artifact
	// value present requires all six, well-formed and equal to the expected
	// pair. Settlement re-verification is this same check on the recovered
	// snapshot plus the digest recompute, never a lookup in a current feed.
	if r.ArtifactDerived() || r.ExpectedCatalogModelHashAlgorithm == modelidentity.GGUFFileV1 {
		if err := r.validateArtifactEvidence(); err != nil {
			return err
		}
	}
	for field, value := range map[string]string{
		"provider_reported_model_hash": r.ProviderReportedModelHash,
		"expected_catalog_model_hash":  r.ExpectedCatalogModelHash,
		"catalog_body_digest":          r.CatalogBodyDigest,
		"prompt_hash":                  r.PromptHash,
	} {
		if !hex64Pattern.MatchString(value) {
			return fmt.Errorf("route snapshot %s must be 64 lowercase hex chars", field)
		}
	}
	if !receiptKeyIDPattern.MatchString(r.CatalogSignaturePubkeyFingerprint) {
		return fmt.Errorf("route snapshot catalog_signature_pubkey_fingerprint invalid")
	}
	if r.CatalogExpiresAtUnixMS <= 0 || r.RouteDecisionTSUnixMS <= 0 || r.RequestStartTSUnixMS <= 0 {
		return fmt.Errorf("route snapshot timestamps must be positive")
	}
	if r.PendingDeadlineSeconds <= 0 || r.PendingDeadlineSeconds > MaxPendingReceiptDeadlineSeconds {
		return fmt.Errorf("route snapshot pending_deadline_seconds must be between 1 and %d", MaxPendingReceiptDeadlineSeconds)
	}
	if r.ComputeIntegrityCaptureRequired {
		if r.RouteSnapshotMode != RouteSnapshotModeEnforce {
			return fmt.Errorf("compute integrity capture requires enforce route snapshot mode")
		}
		if !computeIntegrityDigestPattern.MatchString(r.ComputeIntegrityHardwareDigest) {
			return fmt.Errorf("compute integrity hardware runtime class digest invalid")
		}
	}
	if r.ModelAdmissionCandidateID != "" {
		for field, value := range map[string]string{
			"model_admission_coordinator_event_id":     r.ModelAdmissionCoordinatorEventID,
			"model_admission_served_model_ref":         r.ModelAdmissionServedModelRef,
			"model_admission_catalog_model_key":        r.ModelAdmissionCatalogModelKey,
			"model_admission_discovery_digest_sha256":  r.ModelAdmissionDiscoveryDigestSHA256,
			"model_admission_evaluation_digest_sha256": r.ModelAdmissionEvaluationDigestSHA256,
		} {
			if strings.TrimSpace(value) == "" {
				return fmt.Errorf("route snapshot missing %s", field)
			}
		}
		for field, value := range map[string]string{
			"model_admission_coordinator_event_id":     r.ModelAdmissionCoordinatorEventID,
			"model_admission_discovery_digest_sha256":  r.ModelAdmissionDiscoveryDigestSHA256,
			"model_admission_evaluation_digest_sha256": r.ModelAdmissionEvaluationDigestSHA256,
		} {
			if !hex64Pattern.MatchString(value) {
				return fmt.Errorf("route snapshot %s must be 64 lowercase hex chars", field)
			}
		}
	}
	return nil
}

const (
	RouteSnapshotComponentPrimary = "route_snapshot"
	RouteSnapshotComponentJournal = "route_snapshot_journal"
	RouteSnapshotComponentGuard   = "route_snapshot_guard"

	RouteSnapshotOperationConnection    = "connection"
	RouteSnapshotOperationBusyTimeout   = "busy_timeout"
	RouteSnapshotOperationInsert        = "route_snapshot_insert"
	RouteSnapshotOperationBYOMBinding   = "byom_route_snapshot_binding"
	RouteSnapshotOperationPrimaryMirror = "primary_mirror"
)

type RouteSnapshotPressureDetail struct {
	Component string
	Operation string
	Kind      string
}

type RouteSnapshotPressureEvent struct {
	RequestID  string
	AttemptN   int64
	ProviderID string
	Detail     RouteSnapshotPressureDetail
}

type routeSnapshotStorePressureError struct {
	detail RouteSnapshotPressureDetail
	err    error
}

func (e *routeSnapshotStorePressureError) Error() string {
	if e == nil || e.err == nil {
		return ErrRouteSnapshotStorePressure.Error()
	}
	parts := []string{ErrRouteSnapshotStorePressure.Error()}
	if e.detail.Component != "" {
		parts = append(parts, "component="+e.detail.Component)
	}
	if e.detail.Operation != "" {
		parts = append(parts, "operation="+e.detail.Operation)
	}
	if e.detail.Kind != "" {
		parts = append(parts, "kind="+e.detail.Kind)
	}
	parts = append(parts, "cause="+e.err.Error())
	return strings.Join(parts, " ")
}

func (e *routeSnapshotStorePressureError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.err
}

func (e *routeSnapshotStorePressureError) Is(target error) bool {
	return target == ErrRouteSnapshotStorePressure
}

func RouteSnapshotPressureDetails(err error) (RouteSnapshotPressureDetail, bool) {
	var detailErr *routeSnapshotStorePressureError
	if errors.As(err, &detailErr) && detailErr != nil {
		return detailErr.detail, true
	}
	if IsRouteSnapshotStorePressure(err) {
		return RouteSnapshotPressureDetail{Kind: routeSnapshotPressureKind(err)}, true
	}
	return RouteSnapshotPressureDetail{}, false
}

func (s *Store) InsertRouteSnapshot(ctx context.Context, snapshot RouteSnapshot) (string, error) {
	if s == nil {
		return "", fmt.Errorf("billing store is nil")
	}
	digest, canonical, err := snapshot.Digest()
	if err != nil {
		return "", err
	}
	rendered, err := json.Marshal(snapshot.Value())
	if err != nil {
		return "", err
	}
	if journalDB := s.routeSnapshotJournalDB.Load(); journalDB != nil {
		if err := s.insertRouteSnapshotRow(ctx, journalDB, RouteSnapshotComponentJournal, "settlement_route_snapshot_journal", snapshot, digest, string(rendered), string(canonical), true); err != nil {
			return "", err
		}
		mirrorCtx, cancel := routeSnapshotMirrorContext(ctx, routeSnapshotPrimaryMirrorBudget)
		if err := s.insertRouteSnapshotRow(mirrorCtx, s.routeSnapshotHandle(), RouteSnapshotComponentPrimary, "settlement_route_snapshots", snapshot, digest, string(rendered), string(canonical), false); err != nil {
			s.observeRouteSnapshotPressure(snapshot, err)
		}
		cancel()
		return digest, nil
	}
	if err := s.insertRouteSnapshotRow(ctx, s.routeSnapshotHandle(), RouteSnapshotComponentPrimary, "settlement_route_snapshots", snapshot, digest, string(rendered), string(canonical), true); err != nil {
		return "", err
	}
	return digest, nil
}

func (s *Store) insertRouteSnapshotRow(ctx context.Context, db *sql.DB, component, table string, snapshot RouteSnapshot, digest, rendered, canonical string, retry bool) error {
	if db == nil {
		return fmt.Errorf("billing store is closed")
	}
	if table != "settlement_route_snapshots" && table != "settlement_route_snapshot_journal" {
		return fmt.Errorf("unsupported route snapshot table %q", table)
	}
	connWaitStarted := time.Now()
	conn, err := db.Conn(ctx)
	s.observeSQLiteConnectionWait(component, err, time.Since(connWaitStarted))
	if err != nil {
		return AnnotateRouteSnapshotPressure(err, component, RouteSnapshotOperationConnection)
	}
	defer conn.Close()
	if err := s.applyRouteSnapshotBusyTimeout(ctx, conn); err != nil {
		return AnnotateRouteSnapshotPressure(err, component, RouteSnapshotOperationBusyTimeout)
	}

	hasDeadline := false
	if _, ok := ctx.Deadline(); ok {
		hasDeadline = true
	}
	attempt := 0
	for {
		started := time.Now()
		_, err = conn.ExecContext(ctx, `
INSERT INTO `+table+` (
    account_scope, request_id, attempt_n, provider_id,
    provider_session_id, provider_generation_id, pool_id, paid_entrypoint,
    provider_receipt_key_id, provider_receipt_key_source,
    model_id, provider_reported_model_hash, expected_catalog_model_hash,
    catalog_id, catalog_body_digest, catalog_signature_key_id,
    catalog_signature_pubkey_fingerprint, catalog_expires_at_unix_ms,
    spec008_hash_status, route_snapshot_policy_version, route_snapshot_mode,
    route_decision_ts_unix_ms, request_start_ts_unix_ms, pending_deadline_seconds,
    prompt_hash_basis, prompt_hash, compute_integrity_capture_required,
    compute_integrity_sampling_profile_covered, compute_integrity_hardware_runtime_class_digest,
    route_snapshot_digest, route_snapshot_json,
    route_snapshot_canonical_json, created_at_utc
) VALUES (
    ?, ?, ?, ?,
    ?, ?, ?, ?,
    ?, ?,
    ?, ?, ?,
    ?, ?, ?,
    ?, ?,
    ?, ?, ?,
    ?, ?, ?,
    ?, ?, ?, ?, ?,
    ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ','now')
)`,
			snapshot.AccountScope, snapshot.RequestID, snapshot.AttemptN, snapshot.ProviderID,
			nullableString(snapshot.ProviderSessionID), nullableString(snapshot.ProviderGenerationID), nullString(snapshot.PoolID), snapshot.PaidEntrypoint,
			snapshot.ProviderReceiptKeyID, snapshot.ProviderReceiptKeySource,
			snapshot.ModelID, snapshot.ProviderReportedModelHash, snapshot.ExpectedCatalogModelHash,
			snapshot.CatalogID, snapshot.CatalogBodyDigest, snapshot.CatalogSignatureKeyID,
			snapshot.CatalogSignaturePubkeyFingerprint, snapshot.CatalogExpiresAtUnixMS,
			snapshot.Spec008HashStatus, snapshot.RouteSnapshotPolicyVersion, snapshot.RouteSnapshotMode,
			snapshot.RouteDecisionTSUnixMS, snapshot.RequestStartTSUnixMS, snapshot.PendingDeadlineSeconds,
			snapshot.PromptHashBasis, snapshot.PromptHash,
			boolInt(snapshot.ComputeIntegrityCaptureRequired), boolInt(snapshot.ComputeIntegritySamplingCovered), nullString(snapshot.ComputeIntegrityHardwareDigest),
			digest, rendered,
			canonical,
		)
		s.observeSQLiteWrite(component, "route_snapshot_insert", err, time.Since(started))
		if err == nil {
			return nil
		}
		if !routeSnapshotStorePressure(err) {
			return err
		}
		if !retry || !hasDeadline || !sleepRouteSnapshotRetry(ctx, attempt) {
			return AnnotateRouteSnapshotPressure(err, component, RouteSnapshotOperationInsert)
		}
		attempt++
	}
}

func routeSnapshotMirrorContext(parent context.Context, budget time.Duration) (context.Context, context.CancelFunc) {
	if parent == nil {
		parent = context.Background()
	}
	if budget <= 0 {
		return context.WithCancel(parent)
	}
	if deadline, ok := parent.Deadline(); ok {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return context.WithCancel(parent)
		}
		if remaining < budget {
			budget = remaining
		}
	}
	return context.WithTimeout(parent, budget)
}

func (s *Store) InitRouteSnapshotJournal(ctx context.Context) error {
	if s == nil {
		return fmt.Errorf("billing store is nil")
	}
	db := s.routeSnapshotJournalDB.Load()
	if db == nil {
		return nil
	}
	_, err := db.ExecContext(ctx, `
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS settlement_route_snapshot_journal (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_scope TEXT NOT NULL,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL CHECK(attempt_n >= 0),
    provider_id TEXT NOT NULL,
    provider_session_id TEXT NULL,
    provider_generation_id TEXT NULL,
    pool_id TEXT NULL,
    paid_entrypoint TEXT NOT NULL,
    provider_receipt_key_id TEXT NOT NULL CHECK(length(provider_receipt_key_id) = 79 AND substr(provider_receipt_key_id, 1, 15) = 'ed25519-sha256:' AND substr(provider_receipt_key_id, 16) NOT GLOB '*[^0-9a-f]*'),
    provider_receipt_key_source TEXT NOT NULL CHECK(provider_receipt_key_source IN ('auth_session','rotation_grace','operator_pin')),
    model_id TEXT NOT NULL,
    provider_reported_model_hash TEXT NOT NULL CHECK(length(provider_reported_model_hash) = 64 AND provider_reported_model_hash NOT GLOB '*[^0-9a-f]*'),
    expected_catalog_model_hash TEXT NOT NULL CHECK(length(expected_catalog_model_hash) = 64 AND expected_catalog_model_hash NOT GLOB '*[^0-9a-f]*'),
    catalog_id TEXT NOT NULL,
    catalog_body_digest TEXT NOT NULL CHECK(length(catalog_body_digest) = 64 AND catalog_body_digest NOT GLOB '*[^0-9a-f]*'),
    catalog_signature_key_id TEXT NOT NULL,
    catalog_signature_pubkey_fingerprint TEXT NOT NULL CHECK(length(catalog_signature_pubkey_fingerprint) = 79 AND substr(catalog_signature_pubkey_fingerprint, 1, 15) = 'ed25519-sha256:' AND substr(catalog_signature_pubkey_fingerprint, 16) NOT GLOB '*[^0-9a-f]*'),
    catalog_expires_at_unix_ms INTEGER NOT NULL CHECK(catalog_expires_at_unix_ms > 0),
    spec008_hash_status TEXT NOT NULL,
    route_snapshot_policy_version TEXT NOT NULL,
    route_snapshot_mode TEXT NOT NULL CHECK(route_snapshot_mode IN ('observe','enforce')),
    route_decision_ts_unix_ms INTEGER NOT NULL CHECK(route_decision_ts_unix_ms > 0),
    request_start_ts_unix_ms INTEGER NOT NULL CHECK(request_start_ts_unix_ms > 0),
    pending_deadline_seconds INTEGER NOT NULL CHECK(pending_deadline_seconds BETWEEN 1 AND 900),
    prompt_hash_basis TEXT NOT NULL,
    prompt_hash TEXT NOT NULL CHECK(length(prompt_hash) = 64 AND prompt_hash NOT GLOB '*[^0-9a-f]*'),
    compute_integrity_capture_required INTEGER NOT NULL DEFAULT 0 CHECK(compute_integrity_capture_required IN (0,1)),
    compute_integrity_sampling_profile_covered INTEGER NOT NULL DEFAULT 0 CHECK(compute_integrity_sampling_profile_covered IN (0,1)),
    compute_integrity_hardware_runtime_class_digest TEXT NULL CHECK(compute_integrity_hardware_runtime_class_digest IS NULL OR (length(compute_integrity_hardware_runtime_class_digest) = 71 AND substr(compute_integrity_hardware_runtime_class_digest, 1, 7) = 'sha256:' AND substr(compute_integrity_hardware_runtime_class_digest, 8) NOT GLOB '*[^0-9a-f]*')),
    route_snapshot_digest TEXT NOT NULL CHECK(length(route_snapshot_digest) = 64 AND route_snapshot_digest NOT GLOB '*[^0-9a-f]*'),
    route_snapshot_json TEXT NOT NULL,
    route_snapshot_canonical_json TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    mirrored_at_utc TEXT NULL,
    UNIQUE(account_scope, request_id, attempt_n, provider_id)
);
CREATE INDEX IF NOT EXISTS idx_srsj_request ON settlement_route_snapshot_journal(account_scope, request_id, attempt_n);
CREATE INDEX IF NOT EXISTS idx_srsj_provider ON settlement_route_snapshot_journal(provider_id, created_at_utc);
CREATE INDEX IF NOT EXISTS idx_srsj_digest ON settlement_route_snapshot_journal(route_snapshot_digest);
CREATE TRIGGER IF NOT EXISTS trg_srsj_immutable
BEFORE UPDATE OF account_scope, request_id, attempt_n, provider_id,
                 provider_session_id, provider_generation_id, pool_id,
                 paid_entrypoint, provider_receipt_key_id,
                 provider_receipt_key_source, model_id,
                 provider_reported_model_hash, expected_catalog_model_hash,
                 catalog_id, catalog_body_digest, catalog_signature_key_id,
                 catalog_signature_pubkey_fingerprint,
                 catalog_expires_at_unix_ms, spec008_hash_status,
                 route_snapshot_policy_version, route_snapshot_mode,
                 route_decision_ts_unix_ms, request_start_ts_unix_ms,
                 pending_deadline_seconds, prompt_hash_basis, prompt_hash,
                 compute_integrity_capture_required,
                 compute_integrity_sampling_profile_covered,
                 compute_integrity_hardware_runtime_class_digest,
                 route_snapshot_digest, route_snapshot_json,
                 route_snapshot_canonical_json, created_at_utc
ON settlement_route_snapshot_journal
BEGIN
    SELECT RAISE(ABORT, 'settlement route snapshot journal is immutable');
END;
`)
	return err
}

type persistedRouteSnapshotRow struct {
	AccountScope                      string
	RequestID                         string
	AttemptN                          int64
	ProviderID                        string
	ProviderSession                   sql.NullString
	ProviderGeneration                sql.NullString
	PoolID                            sql.NullString
	PaidEntrypoint                    string
	ProviderReceiptKeyID              string
	ProviderReceiptKeySource          string
	ModelID                           string
	ProviderReportedModelHash         string
	ExpectedCatalogModelHash          string
	CatalogID                         string
	CatalogBodyDigest                 string
	CatalogSignatureKeyID             string
	CatalogSignaturePubkeyFingerprint string
	CatalogExpiresAtUnixMS            int64
	Spec008HashStatus                 string
	RouteSnapshotPolicyVersion        string
	RouteSnapshotMode                 string
	RouteDecisionTSUnixMS             int64
	RequestStartTSUnixMS              int64
	PendingDeadlineSeconds            int64
	PromptHashBasis                   string
	PromptHash                        string
	ComputeIntegrityCaptureRequired   int
	ComputeIntegritySamplingCovered   int
	ComputeIntegrityHardwareDigest    sql.NullString
	RouteSnapshotDigest               string
	RouteSnapshotJSON                 string
	RouteSnapshotCanonicalJSON        string
	CreatedAtUTC                      string
}

func (s *Store) MirrorRouteSnapshotForAttempt(ctx context.Context, id SettlementReceiptIdentity) error {
	if s == nil {
		return fmt.Errorf("billing store is nil")
	}
	journalDB := s.routeSnapshotJournalDB.Load()
	if journalDB == nil {
		return nil
	}
	row, found, err := loadRouteSnapshotJournalRow(ctx, journalDB, id)
	if err != nil || !found {
		return err
	}
	if err := s.insertPersistedRouteSnapshot(ctx, row); err != nil {
		return err
	}
	_, err = journalDB.ExecContext(ctx, `
UPDATE settlement_route_snapshot_journal
   SET mirrored_at_utc = COALESCE(mirrored_at_utc, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID)
	return err
}

func (s *Store) MirrorPendingRouteSnapshots(ctx context.Context, limit int) (int, error) {
	if s == nil {
		return 0, fmt.Errorf("billing store is nil")
	}
	journalDB := s.routeSnapshotJournalDB.Load()
	if journalDB == nil {
		return 0, nil
	}
	if limit <= 0 {
		limit = 100
	}
	rows, err := journalDB.QueryContext(ctx, `
SELECT account_scope, request_id, attempt_n, provider_id
  FROM settlement_route_snapshot_journal
 WHERE mirrored_at_utc IS NULL
 ORDER BY id
 LIMIT ?`, limit)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	var ids []SettlementReceiptIdentity
	for rows.Next() {
		var id SettlementReceiptIdentity
		if err := rows.Scan(&id.AccountScope, &id.RequestID, &id.AttemptN, &id.ProviderID); err != nil {
			return 0, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	mirrored := 0
	for _, id := range ids {
		if err := s.MirrorRouteSnapshotForAttempt(ctx, id); err != nil {
			return mirrored, err
		}
		mirrored++
	}
	return mirrored, nil
}

func loadRouteSnapshotJournalRow(ctx context.Context, db *sql.DB, id SettlementReceiptIdentity) (persistedRouteSnapshotRow, bool, error) {
	var row persistedRouteSnapshotRow
	err := db.QueryRowContext(ctx, `
SELECT account_scope, request_id, attempt_n, provider_id,
       provider_session_id, provider_generation_id, pool_id, paid_entrypoint,
       provider_receipt_key_id, provider_receipt_key_source,
       model_id, provider_reported_model_hash, expected_catalog_model_hash,
       catalog_id, catalog_body_digest, catalog_signature_key_id,
       catalog_signature_pubkey_fingerprint, catalog_expires_at_unix_ms,
       spec008_hash_status, route_snapshot_policy_version, route_snapshot_mode,
       route_decision_ts_unix_ms, request_start_ts_unix_ms, pending_deadline_seconds,
       prompt_hash_basis, prompt_hash, compute_integrity_capture_required,
       compute_integrity_sampling_profile_covered, compute_integrity_hardware_runtime_class_digest,
       route_snapshot_digest, route_snapshot_json, route_snapshot_canonical_json, created_at_utc
  FROM settlement_route_snapshot_journal
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID,
	).Scan(
		&row.AccountScope, &row.RequestID, &row.AttemptN, &row.ProviderID,
		&row.ProviderSession, &row.ProviderGeneration, &row.PoolID, &row.PaidEntrypoint,
		&row.ProviderReceiptKeyID, &row.ProviderReceiptKeySource,
		&row.ModelID, &row.ProviderReportedModelHash, &row.ExpectedCatalogModelHash,
		&row.CatalogID, &row.CatalogBodyDigest, &row.CatalogSignatureKeyID,
		&row.CatalogSignaturePubkeyFingerprint, &row.CatalogExpiresAtUnixMS,
		&row.Spec008HashStatus, &row.RouteSnapshotPolicyVersion, &row.RouteSnapshotMode,
		&row.RouteDecisionTSUnixMS, &row.RequestStartTSUnixMS, &row.PendingDeadlineSeconds,
		&row.PromptHashBasis, &row.PromptHash, &row.ComputeIntegrityCaptureRequired,
		&row.ComputeIntegritySamplingCovered, &row.ComputeIntegrityHardwareDigest,
		&row.RouteSnapshotDigest, &row.RouteSnapshotJSON, &row.RouteSnapshotCanonicalJSON, &row.CreatedAtUTC,
	)
	if err != nil {
		if err == sql.ErrNoRows {
			return persistedRouteSnapshotRow{}, false, nil
		}
		return persistedRouteSnapshotRow{}, false, err
	}
	return row, true, nil
}

func (s *Store) insertPersistedRouteSnapshot(ctx context.Context, row persistedRouteSnapshotRow) error {
	if s == nil || s.db == nil {
		return fmt.Errorf("billing store is closed")
	}
	_, err := s.db.ExecContext(ctx, `
INSERT OR IGNORE INTO settlement_route_snapshots (
    account_scope, request_id, attempt_n, provider_id,
    provider_session_id, provider_generation_id, pool_id, paid_entrypoint,
    provider_receipt_key_id, provider_receipt_key_source,
    model_id, provider_reported_model_hash, expected_catalog_model_hash,
    catalog_id, catalog_body_digest, catalog_signature_key_id,
    catalog_signature_pubkey_fingerprint, catalog_expires_at_unix_ms,
    spec008_hash_status, route_snapshot_policy_version, route_snapshot_mode,
    route_decision_ts_unix_ms, request_start_ts_unix_ms, pending_deadline_seconds,
    prompt_hash_basis, prompt_hash, compute_integrity_capture_required,
    compute_integrity_sampling_profile_covered, compute_integrity_hardware_runtime_class_digest,
    route_snapshot_digest, route_snapshot_json,
    route_snapshot_canonical_json, created_at_utc
) VALUES (
    ?, ?, ?, ?,
    ?, ?, ?, ?,
    ?, ?,
    ?, ?, ?,
    ?, ?, ?,
    ?, ?,
    ?, ?, ?,
    ?, ?, ?,
    ?, ?, ?, ?, ?,
    ?, ?, ?, ?
)`,
		row.AccountScope, row.RequestID, row.AttemptN, row.ProviderID,
		row.ProviderSession, row.ProviderGeneration, row.PoolID, row.PaidEntrypoint,
		row.ProviderReceiptKeyID, row.ProviderReceiptKeySource,
		row.ModelID, row.ProviderReportedModelHash, row.ExpectedCatalogModelHash,
		row.CatalogID, row.CatalogBodyDigest, row.CatalogSignatureKeyID,
		row.CatalogSignaturePubkeyFingerprint, row.CatalogExpiresAtUnixMS,
		row.Spec008HashStatus, row.RouteSnapshotPolicyVersion, row.RouteSnapshotMode,
		row.RouteDecisionTSUnixMS, row.RequestStartTSUnixMS, row.PendingDeadlineSeconds,
		row.PromptHashBasis, row.PromptHash, row.ComputeIntegrityCaptureRequired,
		row.ComputeIntegritySamplingCovered, row.ComputeIntegrityHardwareDigest,
		row.RouteSnapshotDigest, row.RouteSnapshotJSON,
		row.RouteSnapshotCanonicalJSON, row.CreatedAtUTC,
	)
	if err != nil {
		return wrapRouteSnapshotStorePressure(err)
	}
	var existingDigest string
	err = s.db.QueryRowContext(ctx, `
SELECT route_snapshot_digest
  FROM settlement_route_snapshots
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		row.AccountScope, row.RequestID, row.AttemptN, row.ProviderID,
	).Scan(&existingDigest)
	if err != nil {
		return wrapRouteSnapshotStorePressure(err)
	}
	if existingDigest != row.RouteSnapshotDigest {
		return fmt.Errorf("route snapshot mirror digest mismatch for request %s attempt %d provider %s", row.RequestID, row.AttemptN, row.ProviderID)
	}
	return nil
}

func (s *Store) applyRouteSnapshotBusyTimeout(ctx context.Context, conn *sql.Conn) error {
	if s == nil || conn == nil {
		return nil
	}
	ms := s.routeSnapshotBusyTimeoutMS.Load()
	if ms <= 0 {
		return nil
	}
	_, err := conn.ExecContext(ctx, "PRAGMA busy_timeout = "+strconv.FormatInt(ms, 10))
	return err
}

func sleepRouteSnapshotRetry(ctx context.Context, attempt int) bool {
	delay := routeSnapshotRetryInitialDelay
	for i := 0; i < attempt && delay < routeSnapshotRetryMaxDelay; i++ {
		delay *= 2
	}
	if delay > routeSnapshotRetryMaxDelay {
		delay = routeSnapshotRetryMaxDelay
	}
	if deadline, ok := ctx.Deadline(); ok {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return false
		}
		if delay > remaining {
			delay = remaining
		}
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func wrapRouteSnapshotStorePressure(err error) error {
	return AnnotateRouteSnapshotPressure(err, "", "")
}

func AnnotateRouteSnapshotPressure(err error, component, operation string) error {
	if err == nil {
		return nil
	}
	var detailErr *routeSnapshotStorePressureError
	if errors.As(err, &detailErr) {
		return err
	}
	if routeSnapshotStorePressure(err) {
		return &routeSnapshotStorePressureError{
			detail: RouteSnapshotPressureDetail{Component: component, Operation: operation, Kind: routeSnapshotPressureKind(err)},
			err:    err,
		}
	}
	return err
}

func (s *Store) observeRouteSnapshotPressure(snapshot RouteSnapshot, err error) {
	detail, ok := RouteSnapshotPressureDetails(err)
	if !ok {
		return
	}
	if detail.Operation == RouteSnapshotOperationInsert {
		detail.Operation = RouteSnapshotOperationPrimaryMirror
	}
	s.routeSnapshotPressureMu.RLock()
	observer := s.routeSnapshotPressureObserve
	s.routeSnapshotPressureMu.RUnlock()
	if observer == nil {
		return
	}
	event := RouteSnapshotPressureEvent{
		RequestID:  snapshot.RequestID,
		AttemptN:   snapshot.AttemptN,
		ProviderID: snapshot.ProviderID,
		Detail:     detail,
	}
	go func() {
		defer func() { _ = recover() }()
		observer(event)
	}()
}

// IsRouteSnapshotStorePressure reports whether err is transient pressure from
// the route-snapshot persistence path. Settlement validation errors are not
// classified as pressure.
func IsRouteSnapshotStorePressure(err error) bool {
	return errors.Is(err, ErrRouteSnapshotStorePressure) || routeSnapshotStorePressure(err)
}

func routeSnapshotPressureKind(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "context_deadline_exceeded"
	}
	var sqliteErr *sqlite.Error
	if errors.As(err, &sqliteErr) {
		switch sqliteErr.Code() & 0xff {
		case 5:
			return "sqlite_busy"
		case 6:
			return "sqlite_locked"
		default:
			return fmt.Sprintf("sqlite_%d", sqliteErr.Code())
		}
	}
	return "unknown"
}

func routeSnapshotStorePressure(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var sqliteErr *sqlite.Error
	if errors.As(err, &sqliteErr) {
		switch sqliteErr.Code() & 0xff {
		case 5, 6: // SQLITE_BUSY or SQLITE_LOCKED, including extended codes.
			return true
		}
	}
	return false
}

func (s *Store) observeSQLiteConnectionWait(component string, err error, duration time.Duration) {
	if s == nil || s.sqliteMetric == nil {
		return
	}
	outcome := "success"
	if err != nil {
		outcome = "error"
	}
	s.sqliteMetric.ObserveSQLiteConnectionWait(component, outcome, duration)
}

func (s *Store) observeSQLiteWrite(component, operation string, err error, duration time.Duration) {
	if s == nil || s.sqliteMetric == nil {
		return
	}
	outcome := "success"
	if err != nil {
		outcome = "error"
	}
	s.sqliteMetric.ObserveSQLiteWriteDuration(component, operation, outcome, duration)
}

func nullableString(v *string) any {
	if v == nil {
		return nil
	}
	return *v
}

func (r RouteSnapshot) validateArtifactEvidence() error {
	for field, value := range map[string]string{
		"artifact_feed_sha256":              r.ArtifactFeedSHA256,
		"artifact_hash":                     r.ArtifactHash,
		"artifact_candidate_catalog_sha256": r.ArtifactCandidateCatalogSHA256,
	} {
		if !isLowerHex64Digest(value) {
			return fmt.Errorf("route snapshot artifact evidence %s missing or invalid", field)
		}
	}
	if strings.TrimSpace(r.ArtifactID) == "" || strings.TrimSpace(r.ArtifactFeedSignerKeyID) == "" {
		return fmt.Errorf("route snapshot artifact evidence incomplete")
	}
	if !modelidentity.CanonicalAlgorithm(r.ArtifactHashAlgorithm) ||
		r.ArtifactHashAlgorithm != r.ExpectedCatalogModelHashAlgorithm ||
		r.ArtifactHash != r.ExpectedCatalogModelHash {
		return fmt.Errorf("route snapshot artifact evidence does not name the expected identity")
	}
	return nil
}

func isLowerHex64Digest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, ch := range value {
		if (ch < '0' || ch > '9') && (ch < 'a' || ch > 'f') {
			return false
		}
	}
	return true
}
