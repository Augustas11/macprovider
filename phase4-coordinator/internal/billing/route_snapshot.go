package billing

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
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
)

var (
	hex64Pattern        = regexp.MustCompile(`^[0-9a-f]{64}$`)
	receiptKeyIDPattern = regexp.MustCompile(`^ed25519-sha256:[0-9a-f]{64}$`)
)

type RouteSnapshot struct {
	AccountScope                       string  `json:"account_scope"`
	RequestID                          string  `json:"request_id"`
	AttemptN                           int64   `json:"attempt_n"`
	ProviderID                         string  `json:"provider_id"`
	ProviderSessionID                  *string `json:"provider_session_id"`
	ProviderGenerationID               *string `json:"provider_generation_id"`
	PaidEntrypoint                     string  `json:"paid_entrypoint"`
	ProviderReceiptKeyID               string  `json:"provider_receipt_key_id"`
	ProviderReceiptKeySource           string  `json:"provider_receipt_key_source"`
	ModelID                            string  `json:"model_id"`
	ProviderReportedModelHash          string  `json:"provider_reported_model_hash"`
	ProviderReportedModelHashAlgorithm string  `json:"provider_reported_model_hash_algorithm"`
	ExpectedCatalogModelHash           string  `json:"expected_catalog_model_hash"`
	ExpectedCatalogModelHashAlgorithm  string  `json:"expected_catalog_model_hash_algorithm"`
	CatalogID                          string  `json:"catalog_id"`
	CatalogBodyDigest                  string  `json:"catalog_body_digest"`
	CatalogSignatureKeyID              string  `json:"catalog_signature_key_id"`
	CatalogSignaturePubkeyFingerprint  string  `json:"catalog_signature_pubkey_fingerprint"`
	CatalogExpiresAtUnixMS             int64   `json:"catalog_expires_at_unix_ms"`
	Spec008HashStatus                  string  `json:"spec008_hash_status"`
	RouteSnapshotPolicyVersion         string  `json:"route_snapshot_policy_version"`
	RouteSnapshotMode                  string  `json:"route_snapshot_mode"`
	RouteDecisionTSUnixMS              int64   `json:"route_decision_ts_unix_ms"`
	RequestStartTSUnixMS               int64   `json:"request_start_ts_unix_ms"`
	PendingDeadlineSeconds             int64   `json:"pending_deadline_seconds"`
	PromptHashBasis                    string  `json:"prompt_hash_basis"`
	PromptHash                         string  `json:"prompt_hash"`
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
	return value
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
		(r.ProviderReportedModelHashAlgorithm != modelidentity.SnapshotManifestV1 ||
			r.ExpectedCatalogModelHashAlgorithm != modelidentity.SnapshotManifestV1) {
		return fmt.Errorf("route snapshot model hash algorithm invalid")
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
	return nil
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
	_, err = s.db.ExecContext(ctx, `
INSERT INTO settlement_route_snapshots (
    account_scope, request_id, attempt_n, provider_id,
    provider_session_id, provider_generation_id, paid_entrypoint,
    provider_receipt_key_id, provider_receipt_key_source,
    model_id, provider_reported_model_hash, expected_catalog_model_hash,
    catalog_id, catalog_body_digest, catalog_signature_key_id,
    catalog_signature_pubkey_fingerprint, catalog_expires_at_unix_ms,
    spec008_hash_status, route_snapshot_policy_version, route_snapshot_mode,
    route_decision_ts_unix_ms, request_start_ts_unix_ms, pending_deadline_seconds,
    prompt_hash_basis, prompt_hash, route_snapshot_digest, route_snapshot_json,
    route_snapshot_canonical_json, created_at_utc
) VALUES (
    ?, ?, ?, ?,
    ?, ?, ?,
    ?, ?,
    ?, ?, ?,
    ?, ?, ?,
    ?, ?,
    ?, ?, ?,
    ?, ?, ?,
    ?, ?, ?, ?,
    ?, strftime('%Y-%m-%dT%H:%M:%fZ','now')
)`,
		snapshot.AccountScope, snapshot.RequestID, snapshot.AttemptN, snapshot.ProviderID,
		nullableString(snapshot.ProviderSessionID), nullableString(snapshot.ProviderGenerationID), snapshot.PaidEntrypoint,
		snapshot.ProviderReceiptKeyID, snapshot.ProviderReceiptKeySource,
		snapshot.ModelID, snapshot.ProviderReportedModelHash, snapshot.ExpectedCatalogModelHash,
		snapshot.CatalogID, snapshot.CatalogBodyDigest, snapshot.CatalogSignatureKeyID,
		snapshot.CatalogSignaturePubkeyFingerprint, snapshot.CatalogExpiresAtUnixMS,
		snapshot.Spec008HashStatus, snapshot.RouteSnapshotPolicyVersion, snapshot.RouteSnapshotMode,
		snapshot.RouteDecisionTSUnixMS, snapshot.RequestStartTSUnixMS, snapshot.PendingDeadlineSeconds,
		snapshot.PromptHashBasis, snapshot.PromptHash, digest, string(rendered),
		string(canonical),
	)
	if err != nil {
		return "", err
	}
	return digest, nil
}

func nullableString(v *string) any {
	if v == nil {
		return nil
	}
	return *v
}
