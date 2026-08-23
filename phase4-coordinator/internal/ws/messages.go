package ws

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

type Hello struct {
	Type                   string          `json:"type"`
	Version                int             `json:"version"`
	Tier                   int             `json:"tier"`
	ProviderID             string          `json:"provider_id"`
	Hostname               string          `json:"hostname"`
	ModelID                string          `json:"model_id"`
	ModelHash              string          `json:"model_hash,omitempty"`
	ModelHashAlgorithm     string          `json:"model_hash_algorithm,omitempty"`
	WeightsManifestSHA256  string          `json:"weights_manifest_sha256,omitempty"`
	WeightsHashAlgorithm   string          `json:"weights_manifest_algorithm,omitempty"`
	ModelParamsB           float64         `json:"model_params_b"`
	RAMGB                  int             `json:"ram_gb"`
	MaxContextTokens       int             `json:"max_context_tokens"`
	MaxConcurrency         int             `json:"max_concurrency"`
	ThroughputTPSEstimate  float64         `json:"throughput_tps_estimate"`
	ModelLoadTimeMs        int64           `json:"model_load_time_ms,omitempty"`
	BinaryVersion          string          `json:"binary_version"`
	Attestation            json.RawMessage `json:"attestation"`
	EndpointURL            *string         `json:"endpoint_url,omitempty"`
	CatalogReleaseID       string          `json:"catalog_release_id,omitempty"`
	CatalogPolicyVersion   string          `json:"catalog_policy_version,omitempty"`
	CandidateCatalogSHA256 string          `json:"catalog_candidate_sha256,omitempty"`
	CatalogSignerKeyID     string          `json:"catalog_signer_key_id,omitempty"`
	CandidateRowIdentity   string          `json:"catalog_row_identity,omitempty"`
	CompatibilitySetID     string          `json:"compatibility_set_id,omitempty"`
	CredentialBootstrap    bool            `json:"credential_bootstrap,omitempty"`
	ReferralCode           string          `json:"referral_code,omitempty"`
}

const (
	maxHandshakeHostnameBytes      = 253
	maxHandshakeModelIDBytes       = 256
	maxHandshakeBinaryVersionBytes = 32
	maxHandshakeMetadataBytes      = 1024
	maxReferralCodeBytes           = 256
)

type HelloAck struct {
	Type                      string `json:"type"`
	CoordinatorVersion        int    `json:"coordinator_version"`
	AssignedID                string `json:"assigned_id"`
	HeartbeatIntervalS        int    `json:"heartbeat_interval_s"`
	Tier                      string `json:"tier,omitempty"`
	RecommendedBinaryVersion  string `json:"recommended_binary_version,omitempty"`
	RequiredBinaryVersion     string `json:"required_binary_version,omitempty"`
	AutoupdateDrainExtensions bool   `json:"autoupdate_drain_extensions,omitempty"`
	// SPEC-003 v0.8 FR-C9.2 — populated only when a tokenless provisional
	// provider was just self-minted on this connect. Binary persists to
	// the top-level `provider_token` YAML key (FR-C9.3) so the next
	// reconnect carries Bearer. Note: top-level, NOT nested under
	// `auth:` — codex audit on PR #44 caught the prior spec/code drift.
	AssignedProviderToken string `json:"assigned_provider_token,omitempty"`
	PairOT                string `json:"pair_ot,omitempty"`
	ClaimURL              string `json:"claim_url,omitempty"`
	// The coordinator's admission verdict on this ACCEPT ack — one of
	// bearer_validated / self_minted / bearerless_duplicate (pool.AuthState).
	// mint_failed and the reject paths CLOSE the connection, so they never ride
	// an ack. Emission owner: SPEC-003 FR-C9.2a; field shape: SPEC-001 §6.5.1;
	// autoupdate interpretation: SPEC-020 v0.1.7 (runbook item 23). Propagated so
	// the provider enforces the SPEC-020 trust floor client-side (a
	// bearerless_duplicate race-loser stays notify-only) instead of inferring it.
	// Omitted (empty) by a coordinator with no token issuer → client falls back
	// to its inference.
	AuthState                     string `json:"auth_state,omitempty"`
	CatalogCompatible             bool   `json:"catalog_compatible,omitempty"`
	CatalogReleaseID              string `json:"catalog_release_id,omitempty"`
	CatalogPolicyVersion          string `json:"catalog_policy_version,omitempty"`
	CandidateCatalogSHA256        string `json:"catalog_candidate_sha256,omitempty"`
	CatalogSignerKeyID            string `json:"catalog_signer_key_id,omitempty"`
	CompatibilityPolicy           string `json:"compatibility_policy,omitempty"`
	AcceptedCompatibilitySetID    string `json:"accepted_compatibility_set_id,omitempty"`
	RecommendedCompatibilitySetID string `json:"recommended_compatibility_set_id,omitempty"`
}

type AuthRequest struct {
	Type                           string          `json:"type"`
	Version                        int             `json:"version"`
	Stage                          string          `json:"stage"`
	AuthAttemptID                  string          `json:"auth_attempt_id,omitempty"`
	ProviderID                     string          `json:"provider_id"`
	Hostname                       string          `json:"hostname,omitempty"`
	ModelID                        string          `json:"model_id,omitempty"`
	ModelHash                      string          `json:"model_hash,omitempty"`
	ModelHashAlgorithm             string          `json:"model_hash_algorithm,omitempty"`
	WeightsManifestSHA256          string          `json:"weights_manifest_sha256,omitempty"`
	WeightsHashAlgorithm           string          `json:"weights_manifest_algorithm,omitempty"`
	ModelParamsB                   float64         `json:"model_params_b,omitempty"`
	RAMGB                          int             `json:"ram_gb,omitempty"`
	MaxContextTokens               int             `json:"max_context_tokens,omitempty"`
	MaxConcurrency                 int             `json:"max_concurrency,omitempty"`
	ThroughputTPSEstimate          float64         `json:"throughput_tps_estimate,omitempty"`
	ModelLoadTimeMs                int64           `json:"model_load_time_ms,omitempty"`
	BinaryVersion                  string          `json:"binary_version,omitempty"`
	EndpointURL                    *string         `json:"endpoint_url,omitempty"`
	ProviderECDHPublicKey          string          `json:"provider_ecdh_public_key,omitempty"`
	ProviderReceiptPublicKey       string          `json:"provider_receipt_public_key,omitempty"`
	ProviderReceiptPubkey          []byte          `json:"-"`
	ProviderAdmissionPublicKey     string          `json:"provider_admission_public_key,omitempty"`
	ProviderAdmissionPubkey        []byte          `json:"-"`
	ProviderAdmissionNextPublicKey string          `json:"provider_admission_next_public_key,omitempty"`
	ProviderAdmissionNextPubkey    []byte          `json:"-"`
	ProviderAdmissionRecovery      bool            `json:"provider_admission_recovery,omitempty"`
	Tier2Capabilities              Tier2Caps       `json:"tier2_capabilities,omitempty"`
	AttestationToken               json.RawMessage `json:"attestation_token,omitempty"`
	IdentitySignature              string          `json:"identity_signature,omitempty"`
	IdentityTranscriptSHA256       string          `json:"identity_signature_transcript_sha256,omitempty"`
	SupportedModels                []string        `json:"supported_models,omitempty"`
	PublishesSupportedModels       bool            `json:"publishes_supported_models,omitempty"`
	CatalogReleaseID               string          `json:"catalog_release_id,omitempty"`
	CatalogPolicyVersion           string          `json:"catalog_policy_version,omitempty"`
	CandidateCatalogSHA256         string          `json:"catalog_candidate_sha256,omitempty"`
	CatalogSignerKeyID             string          `json:"catalog_signer_key_id,omitempty"`
	CandidateRowIdentity           string          `json:"catalog_row_identity,omitempty"`
	CompatibilitySetID             string          `json:"compatibility_set_id,omitempty"`
	CredentialBootstrap            bool            `json:"credential_bootstrap,omitempty"`
	ReferralCode                   string          `json:"referral_code,omitempty"`
}

type Spec010Presence struct {
	SupportedModels          bool
	PublishesSupportedModels bool
}

type Tier2Caps struct {
	EncryptedLeg                   bool     `json:"encrypted_leg"`
	Attestation                    bool     `json:"attestation"`
	AEADSuites                     []string `json:"aead_suites"`
	ResponseChunkPlaintextEnvelope bool     `json:"response_chunk_plaintext_envelope,omitempty"`
	InBandAEADRekeyV1              bool     `json:"in_band_aead_rekey_v1,omitempty"`
	TrustedPoolV1                  bool     `json:"trusted_pool_v1,omitempty"`
}

type AuthChallenge struct {
	Type                        string   `json:"type"`
	Version                     int      `json:"version"`
	AuthAttemptID               string   `json:"auth_attempt_id"`
	AssignedID                  string   `json:"assigned_id"`
	AttestationChallenge        string   `json:"attestation_challenge"`
	AttestationFormats          []string `json:"attestation_formats"`
	CoordinatorECDHPublicKey    string   `json:"coordinator_ecdh_public_key"`
	SelectedAEADSuite           string   `json:"selected_aead_suite"`
	SelectedAEAD                string   `json:"selected_aead,omitempty"`
	KeyID                       string   `json:"key_id,omitempty"`
	ExpiresAt                   string   `json:"expires_at"`
	BootstrapIdentityPubkey     string   `json:"bootstrap_identity_public_key,omitempty"`
	AdmissionIdentityPubkey     string   `json:"admission_identity_public_key,omitempty"`
	AdmissionIdentityGeneration int      `json:"admission_identity_generation,omitempty"`
}

type AuthResponse struct {
	Type                      string             `json:"type"`
	Version                   int                `json:"version"`
	Status                    string             `json:"status"`
	AssignedID                string             `json:"assigned_id,omitempty"`
	HeartbeatIntervalS        int                `json:"heartbeat_interval_s,omitempty"`
	Tier                      string             `json:"tier,omitempty"`
	RecommendedBinaryVersion  string             `json:"recommended_binary_version,omitempty"`
	RequiredBinaryVersion     string             `json:"required_binary_version,omitempty"`
	AutoupdateDrainExtensions bool               `json:"autoupdate_drain_extensions,omitempty"`
	Tier2Session              *AuthTier2Session  `json:"tier2_session,omitempty"`
	Error                     *AuthResponseError `json:"error,omitempty"`
	// SPEC-003 v0.8 FR-C9.2 — populated only on proof-stage acceptance
	// when a tokenless provisional provider was just self-minted on this
	// connect. Never present on rejection-shaped responses.
	AssignedProviderToken string `json:"assigned_provider_token,omitempty"`
	PairOT                string `json:"pair_ot,omitempty"`
	ClaimURL              string `json:"claim_url,omitempty"`
	// Coordinator admission verdict on this ACCEPT ack; see the
	// HelloAck.AuthState note (emission SPEC-003 FR-C9.2a, shape SPEC-001 §6.5.1,
	// interpretation SPEC-020 v0.1.7). mint_failed / rejects close the
	// connection and never ride an ack.
	AuthState                           string `json:"auth_state,omitempty"`
	CatalogCompatible                   bool   `json:"catalog_compatible,omitempty"`
	CatalogReleaseID                    string `json:"catalog_release_id,omitempty"`
	CatalogPolicyVersion                string `json:"catalog_policy_version,omitempty"`
	CandidateCatalogSHA256              string `json:"catalog_candidate_sha256,omitempty"`
	CatalogSignerKeyID                  string `json:"catalog_signer_key_id,omitempty"`
	IdentityAdmissionMode               string `json:"identity_admission_mode,omitempty"`
	IdentityAdmissionKeyRole            string `json:"identity_admission_key_role,omitempty"`
	IdentityGeneration                  int    `json:"identity_generation,omitempty"`
	AdmissionIdentityPubkey             string `json:"admission_identity_public_key,omitempty"`
	AdmissionIdentityPreviousValidUntil string `json:"admission_identity_previous_valid_until,omitempty"`
	CompatibilityPolicy                 string `json:"compatibility_policy,omitempty"`
	AcceptedCompatibilitySetID          string `json:"accepted_compatibility_set_id,omitempty"`
	RecommendedCompatibilitySetID       string `json:"recommended_compatibility_set_id,omitempty"`
}

type OwnershipEvent struct {
	Type        string `json:"type"`
	ProviderID  string `json:"provider_id"`
	GitHubLogin string `json:"github_login"`
	Event       string `json:"event"`
}

type AuthResponseError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type AuthTier2Session struct {
	EncryptedLeg AuthEncryptedLegSession `json:"encrypted_leg"`
	Attestation  AuthAttestationSession  `json:"attestation"`
	ModelHash    AuthModelHashSession    `json:"model_hash"`
}

type AuthEncryptedLegSession struct {
	Enabled                        bool   `json:"enabled"`
	Alg                            string `json:"alg"`
	KID                            string `json:"kid"`
	RekeyAfterRequests             int    `json:"rekey_after_requests"`
	RekeyAfterSeconds              int    `json:"rekey_after_seconds"`
	ResponseChunkPlaintextEnvelope bool   `json:"response_chunk_plaintext_envelope,omitempty"`
	InBandAEADRekeyV1              bool   `json:"in_band_aead_rekey_v1,omitempty"`
}

// AEADRekeyRequest starts an in-band Tier-2 key rotation on an already
// authenticated provider WebSocket. The stable provider and assigned session
// identities do not change; only the encrypted-leg epoch is replaced.
type AEADRekeyRequest struct {
	Type                           string `json:"type"`
	Version                        int    `json:"version"`
	RekeyID                        string `json:"rekey_id"`
	AssignedID                     string `json:"assigned_id"`
	Reason                         string `json:"reason"`
	OldKID                         string `json:"old_kid"`
	CoordinatorECDHPublicKey       string `json:"coordinator_ecdh_public_key"`
	SelectedAEAD                   string `json:"selected_aead"`
	ExpiresAt                      string `json:"expires_at"`
	ResponseChunkPlaintextEnvelope bool   `json:"response_chunk_plaintext_envelope"`
}

type AEADRekeyResponse struct {
	Type                  string `json:"type"`
	Version               int    `json:"version"`
	RekeyID               string `json:"rekey_id"`
	AssignedID            string `json:"assigned_id"`
	OldKID                string `json:"old_kid"`
	NewKID                string `json:"new_kid"`
	ProviderECDHPublicKey string `json:"provider_ecdh_public_key"`
}

// AEADRekeyConfirmation is used for both commit directions. The outer binding
// is intentionally duplicated inside the encrypted proof so neither side can
// acknowledge a pending epoch without possessing its freshly derived key.
type AEADRekeyConfirmation struct {
	Type       string                 `json:"type"`
	Version    int                    `json:"version"`
	RekeyID    string                 `json:"rekey_id"`
	AssignedID string                 `json:"assigned_id"`
	OldKID     string                 `json:"old_kid"`
	NewKID     string                 `json:"new_kid"`
	Encrypted  bool                   `json:"encrypted"`
	Enc        tier2.AEADEnvelopeBody `json:"enc"`
}

type AEADRekeyProof struct {
	Type                     string `json:"type"`
	Version                  int    `json:"version"`
	RekeyID                  string `json:"rekey_id"`
	ProviderID               string `json:"provider_id"`
	AssignedID               string `json:"assigned_id"`
	OldKID                   string `json:"old_kid"`
	NewKID                   string `json:"new_kid"`
	ProviderECDHPublicKey    string `json:"provider_ecdh_public_key"`
	CoordinatorECDHPublicKey string `json:"coordinator_ecdh_public_key"`
	SelectedAEAD             string `json:"selected_aead"`
	ExpiresAt                string `json:"expires_at"`
}

type AuthAttestationSession struct {
	Status          string `json:"status"`
	Format          string `json:"format,omitempty"`
	RAMTierAttested bool   `json:"ram_tier_attested"`
}

type AuthModelHashSession struct {
	Status string `json:"status,omitempty"`
}

type Heartbeat struct {
	Type                    string                        `json:"type"`
	Status                  string                        `json:"status"`
	ModelID                 string                        `json:"model_id"`
	ModelParamsB            float64                       `json:"model_params_b"`
	RAMGB                   int                           `json:"ram_gb"`
	MaxContextTokens        int                           `json:"max_context_tokens"`
	MaxConcurrency          int                           `json:"max_concurrency"`
	SlotsFree               int                           `json:"slots_free"`
	SlotsTotal              int                           `json:"slots_total"`
	ThroughputTPSEstimate   float64                       `json:"throughput_tps_estimate"`
	RequestsServedSinceLast int                           `json:"requests_served_since_last"`
	AvgLatencyMSSinceLast   float64                       `json:"avg_latency_ms_since_last"`
	ThroughputTPSSinceLast  float64                       `json:"throughput_tps_since_last"`
	ModelHash               string                        `json:"model_hash,omitempty"`
	ModelHashAlgorithm      string                        `json:"model_hash_algorithm,omitempty"`
	WeightsManifestSHA256   string                        `json:"weights_manifest_sha256,omitempty"`
	WeightsHashAlgorithm    string                        `json:"weights_manifest_algorithm,omitempty"`
	Loading                 bool                          `json:"loading,omitempty"`
	LastAutoupdateEvent     json.RawMessage               `json:"last_autoupdate_event,omitempty"`
	HardwareSummary         *HardwareSummary              `json:"hardware_summary,omitempty"`
	SafetyTelemetry         *pool.ProviderSafetyTelemetry `json:"safety_telemetry,omitempty"`
}

type HeartbeatPresence struct {
	ModelHash             bool
	ModelHashAlgorithm    bool
	WeightsManifestSHA256 bool
	WeightsHashAlgorithm  bool
	Loading               bool
}

type DiagnosticStatus struct {
	Type                  string          `json:"type"`
	SchemaVersion         int             `json:"schema_version"`
	Reason                string          `json:"reason,omitempty"`
	ObservedAt            string          `json:"observed_at,omitempty"`
	ProviderID            string          `json:"provider_id"`
	AssignedID            string          `json:"assigned_id,omitempty"`
	BinaryVersion         string          `json:"binary_version,omitempty"`
	Status                string          `json:"status"`
	ModelID               string          `json:"model_id"`
	ModelLoaded           bool            `json:"model_loaded"`
	ModelHash             string          `json:"model_hash,omitempty"`
	ModelHashAlgorithm    string          `json:"model_hash_algorithm,omitempty"`
	UptimeS               int             `json:"uptime_s,omitempty"`
	RequestsTotal         int             `json:"requests_total,omitempty"`
	RequestsInFlight      int             `json:"requests_in_flight,omitempty"`
	ErrorsTotal           int             `json:"errors_total,omitempty"`
	RestartCount          int             `json:"restart_count,omitempty"`
	MemoryRSSMB           int             `json:"memory_rss_mb,omitempty"`
	MemoryPressure        string          `json:"memory_pressure,omitempty"`
	ThermalState          string          `json:"thermal_state,omitempty"`
	ThermallyThrottled    bool            `json:"thermally_throttled,omitempty"`
	LastConnectionFailure json.RawMessage `json:"last_connection_failure,omitempty"`
}

type IdlePrewarmEvent struct {
	Type   string `json:"type"`
	Event  string `json:"event"`
	Reason string `json:"reason,omitempty"`
}

type HardwareSummary struct {
	Chip              string  `json:"chip,omitempty"`
	BandwidthGBPerSec int64   `json:"bandwidth_gb_per_s,omitempty"`
	NetworkPowerKW    float64 `json:"network_power_kw,omitempty"`
	GPUCoresTotal     int     `json:"gpu_cores_total,omitempty"`
	CPUCoresTotal     int     `json:"cpu_cores_total,omitempty"`
}

type StateUpdate struct {
	Type                string          `json:"type"`
	State               string          `json:"state"`
	Reason              string          `json:"reason"`
	Since               string          `json:"since"`
	MetricsSnapshot     MetricsSnapshot `json:"metrics_snapshot"`
	LastAutoupdateEvent json.RawMessage `json:"last_autoupdate_event,omitempty"`
}

type PreflightAck struct {
	Type             string `json:"type"`
	RequestID        string `json:"request_id"`
	Accepted         bool   `json:"accepted"`
	EstimatedWaitMS  int    `json:"estimated_wait_ms"`
	Reason           string `json:"reason"`
	MaxContextTokens int    `json:"max_context_tokens"`
}

type DrainStatus struct {
	Type                  string `json:"type"`
	Phase                 string `json:"phase"`
	InflightRequests      int    `json:"inflight_requests"`
	EstimatedDrainSeconds int    `json:"estimated_drain_seconds"`
}

type InferenceRequest struct {
	Type            string                     `json:"type"`
	RequestID       string                     `json:"request_id"`
	Stream          bool                       `json:"stream"`
	Body            string                     `json:"body"`
	Settlement      *SettlementReceiptMetadata `json:"settlement,omitempty"`
	ConversationKey string                     `json:"conversation_key,omitempty"`
}

type SettlementReceiptMetadata struct {
	AccountScope               string `json:"account_scope"`
	RequestID                  string `json:"request_id"`
	AttemptN                   int64  `json:"attempt_n"`
	ProviderID                 string `json:"provider_id"`
	ProviderReceiptKeyID       string `json:"provider_receipt_key_id"`
	ModelID                    string `json:"model_id"`
	ExpectedCatalogModelHash   string `json:"expected_catalog_model_hash"`
	CatalogID                  string `json:"catalog_id"`
	CatalogBodyDigest          string `json:"catalog_body_digest"`
	RouteSnapshotDigest        string `json:"route_snapshot_digest"`
	RouteSnapshotPolicyVersion string `json:"route_snapshot_policy_version"`
	RouteSnapshotMode          string `json:"route_snapshot_mode"`
	PromptHash                 string `json:"prompt_hash"`
	OutputPrefixStartByte      int64  `json:"output_prefix_start_byte"`
	PendingDeadlineSeconds     int64  `json:"pending_deadline_seconds"`
}

type InferenceResponseChunk struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	Seq       int    `json:"seq"`
	Data      string `json:"data"`
}

type InferenceResponseEnd struct {
	Type                          string          `json:"type"`
	RequestID                     string          `json:"request_id"`
	Status                        string          `json:"status"`
	ChunksSent                    int             `json:"chunks_sent"`
	Usage                         json.RawMessage `json:"usage,omitempty"`
	Error                         string          `json:"error,omitempty"`
	Retryable                     *bool           `json:"retryable,omitempty"`
	TerminalStateTSUnixMS         int64           `json:"terminal_state_ts_unix_ms,omitempty"`
	ReceiptPendingDeadlineSeconds int64           `json:"receipt_pending_deadline_seconds,omitempty"`
	LateReceiptSettlement         string          `json:"late_receipt_settlement,omitempty"`
	// SPEC-015 v0.1.x: WS-tunneled non-streaming inference carries the
	// X-MacProvider-Receipt header value as a field on the
	// inference_response_end frame. Coordinator stamps it as the
	// response header when forwarding to the buyer, subject to the
	// same provider receipt-eligibility gate used on the HTTP-direct
	// path.
	Receipt string `json:"receipt,omitempty"`
}

// SELivenessChallenge is sent by the coordinator to a provider that completed
// SE attestation (macprovider-se-p256-v1). The provider MUST sign the
// nonce+timestamp and echo both fields back in an SELivenessResponse.
// Distinct from auth attestation_challenge (Pillar-C token freshness).
type SELivenessChallenge struct {
	Type      string `json:"type"`
	Version   int    `json:"version"`
	Nonce     string `json:"nonce"`
	Timestamp string `json:"timestamp"`
}

// SELivenessResponse is sent by the provider in reply to an SELivenessChallenge.
// Coordinator verifies nonce+timestamp echo and ES256 signature over
// UTF-8(nonce+timestamp) using the stored SE public key.
type SELivenessResponse struct {
	Type      string `json:"type"`
	Version   int    `json:"version"`
	Nonce     string `json:"nonce"`
	Timestamp string `json:"timestamp"`
	PublicKey string `json:"public_key"`
	Signature string `json:"signature"`
}

type CancelRequest struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	Reason    string `json:"reason"`
}

type NakError struct {
	Code    string                 `json:"code"`
	Message string                 `json:"message,omitempty"`
	Details map[string]interface{} `json:"details,omitempty"`
}

type Nak struct {
	Type      string   `json:"type"`
	InReplyTo string   `json:"in_reply_to"`
	Error     NakError `json:"error"`
}

var preflightRejectionReasons = map[string]struct{}{
	"context_exceeds_capacity": {},
	"queue_full":               {},
	"draining":                 {},
	"model_not_loaded":         {},
	"unhealthy":                {},
	"tier_mismatch":            {},
}

type MetricsSnapshot struct {
	SlotsFree  *int `json:"slots_free"`
	SlotsTotal *int `json:"slots_total"`
}

func ParseHello(payload []byte) (Hello, string, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return Hello{}, "json", err
	}

	var h Hello
	if err := requireString(raw, "type", &h.Type); err != nil {
		return Hello{}, err.Field, err
	}
	if h.Type != "hello" {
		return Hello{}, "type", fmt.Errorf("expected hello, got %q", h.Type)
	}
	if err := requireInt(raw, "version", &h.Version); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireInt(raw, "tier", &h.Tier); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireString(raw, "provider_id", &h.ProviderID); err != nil {
		return Hello{}, err.Field, err
	}
	// Issue #274: gate WS self-serve registration on the same
	// providerIDPattern that pinned-provider config validation enforces, so
	// the "/" delimiter inside pool.Provider.SortKey stays unambiguous.
	if err := config.ValidateProviderID(h.ProviderID); err != nil {
		return Hello{}, "provider_id", err
	}
	if err := requireString(raw, "hostname", &h.Hostname); err != nil {
		return Hello{}, err.Field, err
	}
	if len([]byte(h.Hostname)) > maxHandshakeHostnameBytes {
		return Hello{}, "hostname", fmt.Errorf("hostname exceeds %d bytes", maxHandshakeHostnameBytes)
	}
	if err := requireString(raw, "model_id", &h.ModelID); err != nil {
		return Hello{}, err.Field, err
	}
	if len([]byte(h.ModelID)) > maxHandshakeModelIDBytes {
		return Hello{}, "model_id", fmt.Errorf("model_id exceeds %d bytes", maxHandshakeModelIDBytes)
	}
	if v, ok := raw["model_hash"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &h.ModelHash); err != nil {
			return Hello{}, "model_hash", err
		}
		if containsControlChar(h.ModelHash) {
			return Hello{}, "model_hash", fieldError{Field: "model_hash"}
		}
	}
	if field, err := parseModelIdentityMetadata(
		raw,
		h.ModelHash,
		&h.ModelHashAlgorithm,
		&h.WeightsManifestSHA256,
		&h.WeightsHashAlgorithm,
	); err != nil {
		return Hello{}, field, err
	}
	if err := requireFloat(raw, "model_params_b", &h.ModelParamsB); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireInt(raw, "ram_gb", &h.RAMGB); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireInt(raw, "max_context_tokens", &h.MaxContextTokens); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireInt(raw, "max_concurrency", &h.MaxConcurrency); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireFloat(raw, "throughput_tps_estimate", &h.ThroughputTPSEstimate); err != nil {
		return Hello{}, err.Field, err
	}
	if v, ok := raw["model_load_time_ms"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &h.ModelLoadTimeMs); err != nil {
			return Hello{}, "model_load_time_ms", err
		}
	}
	if err := requireString(raw, "binary_version", &h.BinaryVersion); err != nil {
		return Hello{}, err.Field, err
	}
	if len([]byte(h.BinaryVersion)) > maxHandshakeBinaryVersionBytes {
		return Hello{}, "binary_version", fmt.Errorf("binary_version exceeds %d bytes", maxHandshakeBinaryVersionBytes)
	}
	attestation, ok := raw["attestation"]
	if ok {
		if len(attestation) > maxHandshakeMetadataBytes {
			return Hello{}, "attestation", fmt.Errorf("attestation exceeds %d bytes", maxHandshakeMetadataBytes)
		}
		h.Attestation = attestation
	}
	if v, ok := raw["endpoint_url"]; ok && string(v) != "null" {
		var endpoint string
		if err := json.Unmarshal(v, &endpoint); err != nil {
			return Hello{}, "endpoint_url", err
		}
		if containsControlChar(endpoint) {
			return Hello{}, "endpoint_url", fieldError{Field: "endpoint_url"}
		}
		h.EndpointURL = &endpoint
	}
	if v, ok := raw["credential_bootstrap"]; ok {
		if string(v) == "null" || json.Unmarshal(v, &h.CredentialBootstrap) != nil {
			return Hello{}, "credential_bootstrap", fmt.Errorf("credential_bootstrap must be a bool")
		}
	}
	if v, ok := raw["referral_code"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &h.ReferralCode); err != nil || len([]byte(h.ReferralCode)) > maxReferralCodeBytes || containsControlChar(h.ReferralCode) {
			return Hello{}, "referral_code", fmt.Errorf("referral_code must be a string of at most %d bytes", maxReferralCodeBytes)
		}
	}
	if field, err := parseCatalogAdmissionMetadata(raw, &h.CatalogReleaseID, &h.CatalogPolicyVersion, &h.CandidateCatalogSHA256, &h.CatalogSignerKeyID, &h.CandidateRowIdentity); err != nil {
		return Hello{}, field, err
	}
	parseOptionalCompatibilitySetID(raw, &h.CompatibilitySetID)
	return h, "", nil
}

func ParseFirstAuthMessage(payload []byte) (string, int, error) {
	typ, version, _, err := parseFirstAuthMessageWithField(payload)
	return typ, version, err
}

func parseFirstAuthMessageWithField(payload []byte) (string, int, string, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return "", 0, "json", err
	}
	var typ string
	if err := requireString(raw, "type", &typ); err != nil {
		return "", 0, err.Field, err
	}
	var version int
	if err := requireAuthVersion(raw, &version); err != nil {
		return typ, 0, err.Field, err
	}
	return typ, version, "", nil
}

func ParseAuthRequest(payload []byte) (AuthRequest, Spec010Presence, string, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return AuthRequest{}, Spec010Presence{}, "json", err
	}
	var req AuthRequest
	if err := requireString(raw, "type", &req.Type); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if req.Type != "auth_request" {
		return AuthRequest{}, Spec010Presence{}, "type", fmt.Errorf("expected auth_request, got %q", req.Type)
	}
	if err := requireAuthVersion(raw, &req.Version); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if req.Version != 2 {
		return AuthRequest{}, Spec010Presence{}, "version", fmt.Errorf("unsupported auth_request version %d", req.Version)
	}
	if err := requireString(raw, "stage", &req.Stage); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	switch req.Stage {
	case "initial":
		return parseAuthInitial(raw, req)
	case "proof":
		return parseAuthProof(raw, req)
	default:
		return AuthRequest{}, Spec010Presence{}, "stage", fmt.Errorf("unsupported auth_request stage %q", req.Stage)
	}
}

func parseAuthInitial(raw map[string]json.RawMessage, req AuthRequest) (AuthRequest, Spec010Presence, string, error) {
	if err := requireString(raw, "provider_id", &req.ProviderID); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	// Issue #274: see ParseHello comment — same canonical validator.
	if err := config.ValidateProviderID(req.ProviderID); err != nil {
		return AuthRequest{}, Spec010Presence{}, "provider_id", err
	}
	if err := requireString(raw, "hostname", &req.Hostname); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if len([]byte(req.Hostname)) > maxHandshakeHostnameBytes {
		return AuthRequest{}, Spec010Presence{}, "hostname", fmt.Errorf("hostname exceeds %d bytes", maxHandshakeHostnameBytes)
	}
	if err := requireString(raw, "model_id", &req.ModelID); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if len([]byte(req.ModelID)) > maxHandshakeModelIDBytes {
		return AuthRequest{}, Spec010Presence{}, "model_id", fmt.Errorf("model_id exceeds %d bytes", maxHandshakeModelIDBytes)
	}
	if v, ok := raw["model_hash"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &req.ModelHash); err != nil {
			return AuthRequest{}, Spec010Presence{}, "model_hash", err
		}
		if containsControlChar(req.ModelHash) {
			return AuthRequest{}, Spec010Presence{}, "model_hash", fieldError{Field: "model_hash"}
		}
	}
	if field, err := parseModelIdentityMetadata(
		raw,
		req.ModelHash,
		&req.ModelHashAlgorithm,
		&req.WeightsManifestSHA256,
		&req.WeightsHashAlgorithm,
	); err != nil {
		return AuthRequest{}, Spec010Presence{}, field, err
	}
	if err := requireFloat(raw, "model_params_b", &req.ModelParamsB); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if err := requireInt(raw, "ram_gb", &req.RAMGB); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if err := requireInt(raw, "max_context_tokens", &req.MaxContextTokens); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if err := requireInt(raw, "max_concurrency", &req.MaxConcurrency); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if err := requireFloat(raw, "throughput_tps_estimate", &req.ThroughputTPSEstimate); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if v, ok := raw["model_load_time_ms"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &req.ModelLoadTimeMs); err != nil {
			return AuthRequest{}, Spec010Presence{}, "model_load_time_ms", err
		}
	}
	if err := requireString(raw, "binary_version", &req.BinaryVersion); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if len([]byte(req.BinaryVersion)) > maxHandshakeBinaryVersionBytes {
		return AuthRequest{}, Spec010Presence{}, "binary_version", fmt.Errorf("binary_version exceeds %d bytes", maxHandshakeBinaryVersionBytes)
	}
	if v, ok := raw["endpoint_url"]; ok && string(v) != "null" {
		var endpoint string
		if err := json.Unmarshal(v, &endpoint); err != nil {
			return AuthRequest{}, Spec010Presence{}, "endpoint_url", err
		}
		if containsControlChar(endpoint) {
			return AuthRequest{}, Spec010Presence{}, "endpoint_url", fieldError{Field: "endpoint_url"}
		}
		req.EndpointURL = &endpoint
	}
	if v, ok := raw["credential_bootstrap"]; ok {
		if string(v) == "null" || json.Unmarshal(v, &req.CredentialBootstrap) != nil {
			return AuthRequest{}, Spec010Presence{}, "credential_bootstrap", fmt.Errorf("credential_bootstrap must be a bool")
		}
	}
	if v, ok := raw["provider_admission_recovery"]; ok {
		if string(v) == "null" || json.Unmarshal(v, &req.ProviderAdmissionRecovery) != nil {
			return AuthRequest{}, Spec010Presence{}, "provider_admission_recovery", fmt.Errorf("provider_admission_recovery must be a bool")
		}
	}
	if v, ok := raw["referral_code"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &req.ReferralCode); err != nil || len([]byte(req.ReferralCode)) > maxReferralCodeBytes || containsControlChar(req.ReferralCode) {
			return AuthRequest{}, Spec010Presence{}, "referral_code", fmt.Errorf("referral_code must be a string of at most %d bytes", maxReferralCodeBytes)
		}
	}
	if err := requireString(raw, "provider_ecdh_public_key", &req.ProviderECDHPublicKey); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if v, ok := raw["provider_receipt_public_key"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &req.ProviderReceiptPublicKey); err != nil {
			return AuthRequest{}, Spec010Presence{}, "provider_receipt_public_key", err
		}
		pubkey, err := base64.StdEncoding.DecodeString(req.ProviderReceiptPublicKey)
		if err != nil {
			return AuthRequest{}, Spec010Presence{}, "provider_receipt_public_key", err
		}
		if len(pubkey) != 32 {
			return AuthRequest{}, Spec010Presence{}, "provider_receipt_public_key", fmt.Errorf("provider_receipt_public_key must decode to 32 bytes")
		}
		req.ProviderReceiptPubkey = append([]byte(nil), pubkey...)
	}
	if v, ok := raw["provider_admission_public_key"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &req.ProviderAdmissionPublicKey); err != nil {
			return AuthRequest{}, Spec010Presence{}, "provider_admission_public_key", err
		}
		pubkey, err := base64.StdEncoding.DecodeString(req.ProviderAdmissionPublicKey)
		if err != nil {
			return AuthRequest{}, Spec010Presence{}, "provider_admission_public_key", err
		}
		if len(pubkey) != ed25519.PublicKeySize {
			return AuthRequest{}, Spec010Presence{}, "provider_admission_public_key", fmt.Errorf("provider_admission_public_key must decode to %d bytes", ed25519.PublicKeySize)
		}
		req.ProviderAdmissionPubkey = append([]byte(nil), pubkey...)
	}
	if v, ok := raw["provider_admission_next_public_key"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &req.ProviderAdmissionNextPublicKey); err != nil {
			return AuthRequest{}, Spec010Presence{}, "provider_admission_next_public_key", err
		}
		pubkey, err := base64.StdEncoding.DecodeString(req.ProviderAdmissionNextPublicKey)
		if err != nil {
			return AuthRequest{}, Spec010Presence{}, "provider_admission_next_public_key", err
		}
		if len(pubkey) != ed25519.PublicKeySize {
			return AuthRequest{}, Spec010Presence{}, "provider_admission_next_public_key", fmt.Errorf("provider_admission_next_public_key must decode to %d bytes", ed25519.PublicKeySize)
		}
		req.ProviderAdmissionNextPubkey = append([]byte(nil), pubkey...)
	}
	capsRaw, ok := raw["tier2_capabilities"]
	if !ok {
		return AuthRequest{}, Spec010Presence{}, "missing tier2_capabilities", fieldError{Field: "missing tier2_capabilities"}
	}
	if err := json.Unmarshal(capsRaw, &req.Tier2Capabilities); err != nil {
		return AuthRequest{}, Spec010Presence{}, "tier2_capabilities", err
	}
	// SPEC-010 v1.5 R-3.1.9 mandates the LOCKED reason-text substring
	// for each first-failure validation step. JSON-type failures MUST
	// surface "supported_models must be array of strings" (NOT a bare
	// "supported_models" badField — that would miss the
	// isSpec010CatalogBadField allowlist and fall through to the
	// generic close path, violating AC-K.15).
	presence := Spec010Presence{}
	if v, ok := raw["supported_models"]; ok {
		presence.SupportedModels = true
		if string(v) == "null" {
			return AuthRequest{}, presence, "supported_models must be array of strings", fieldError{Field: "supported_models must be array of strings"}
		}
		if err := json.Unmarshal(v, &req.SupportedModels); err != nil {
			return AuthRequest{}, presence, "supported_models must be array of strings", fieldError{Field: "supported_models must be array of strings"}
		}
	}
	if v, ok := raw["publishes_supported_models"]; ok {
		presence.PublishesSupportedModels = true
		if string(v) == "null" {
			return AuthRequest{}, presence, "publishes_supported_models", fmt.Errorf("publishes_supported_models must be a bool")
		}
		if err := json.Unmarshal(v, &req.PublishesSupportedModels); err != nil {
			return AuthRequest{}, presence, "publishes_supported_models", err
		}
	}
	if presence.SupportedModels {
		if len(req.SupportedModels) == 0 {
			return AuthRequest{}, presence, "supported_models cannot be empty", fieldError{Field: "supported_models cannot be empty"}
		}
		for _, model := range req.SupportedModels {
			if len([]byte(model)) > 256 {
				return AuthRequest{}, presence, "supported_models entry exceeds 256 bytes", fieldError{Field: "supported_models entry exceeds 256 bytes"}
			}
		}
		if len(req.SupportedModels) > 64 {
			return AuthRequest{}, presence, "supported_models exceeds 64 entries", fieldError{Field: "supported_models exceeds 64 entries"}
		}
		seen := make(map[string]struct{}, len(req.SupportedModels))
		for _, model := range req.SupportedModels {
			normalized := normalizeSupportedModelEntry(model)
			if _, ok := seen[normalized]; ok {
				return AuthRequest{}, presence, "supported_models contains duplicate entries", fieldError{Field: "supported_models contains duplicate entries"}
			}
			seen[normalized] = struct{}{}
		}
		// SPEC-010 v1.5 R-3.1.4 / R-3.1.9 — containment failure surfaces
		// the LOCKED substring "model_id not in supported_models". The
		// inverted ordering caught by the pre-merge audit is excluded
		// from the AC-K.15 allowlist; only the verbatim spec substring
		// passes isSpec010CatalogBadField.
		if _, ok := seen[normalizeSupportedModelEntry(req.ModelID)]; !ok {
			return AuthRequest{}, presence, "model_id not in supported_models", fieldError{Field: "model_id not in supported_models"}
		}
	}
	if field, err := parseCatalogAdmissionMetadata(raw, &req.CatalogReleaseID, &req.CatalogPolicyVersion, &req.CandidateCatalogSHA256, &req.CatalogSignerKeyID, &req.CandidateRowIdentity); err != nil {
		return AuthRequest{}, presence, field, err
	}
	parseOptionalCompatibilitySetID(raw, &req.CompatibilitySetID)
	return req, presence, "", nil
}

func parseAuthProof(raw map[string]json.RawMessage, req AuthRequest) (AuthRequest, Spec010Presence, string, error) {
	if err := requireString(raw, "auth_attempt_id", &req.AuthAttemptID); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if err := requireString(raw, "provider_id", &req.ProviderID); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	// Issue #274: see ParseHello comment — same canonical validator.
	if err := config.ValidateProviderID(req.ProviderID); err != nil {
		return AuthRequest{}, Spec010Presence{}, "provider_id", err
	}
	if token, ok := raw["attestation_token"]; ok {
		if len(token) > maxHandshakeMetadataBytes {
			return AuthRequest{}, Spec010Presence{}, "attestation_token", fmt.Errorf("attestation_token exceeds %d bytes", maxHandshakeMetadataBytes)
		}
		req.AttestationToken = token
	}
	if v, ok := raw["identity_signature"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &req.IdentitySignature); err != nil {
			return AuthRequest{}, Spec010Presence{}, "identity_signature", err
		}
	}
	if v, ok := raw["identity_signature_transcript_sha256"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &req.IdentityTranscriptSHA256); err != nil {
			return AuthRequest{}, Spec010Presence{}, "identity_signature_transcript_sha256", err
		}
	}
	if v, ok := raw["credential_bootstrap"]; ok {
		if string(v) == "null" || json.Unmarshal(v, &req.CredentialBootstrap) != nil {
			return AuthRequest{}, Spec010Presence{}, "credential_bootstrap", fmt.Errorf("credential_bootstrap must be a bool")
		}
	}
	if v, ok := raw["referral_code"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &req.ReferralCode); err != nil || len([]byte(req.ReferralCode)) > maxReferralCodeBytes || containsControlChar(req.ReferralCode) {
			return AuthRequest{}, Spec010Presence{}, "referral_code", fmt.Errorf("referral_code must be a string of at most %d bytes", maxReferralCodeBytes)
		}
	}
	// Proof-stage MUST keep the bare "supported_models" badField (NOT
	// the locked initial-stage substring) — AC-K.15's surfacing
	// contract is initial-stage-only, and the R2V regression test
	// TestProviderAuthV2ProofStageFirstWithMalformedCatalogTakesEnvelopePath
	// requires a proof-stage-first frame with malformed
	// supported_models to take CloseUnrecognizedAuthMessage (4000),
	// not the AC-K.15 CloseInvalidHello path. Keeping the bare
	// badField out of isSpec010CatalogBadField's exact-match list is
	// what implements this separation.
	presence := Spec010Presence{}
	if v, ok := raw["supported_models"]; ok {
		presence.SupportedModels = true
		if string(v) == "null" {
			return AuthRequest{}, presence, "supported_models", fmt.Errorf("supported_models must be an array of strings")
		}
		if err := json.Unmarshal(v, &req.SupportedModels); err != nil {
			return AuthRequest{}, presence, "supported_models", err
		}
	}
	if v, ok := raw["publishes_supported_models"]; ok {
		presence.PublishesSupportedModels = true
		if string(v) == "null" {
			return AuthRequest{}, presence, "publishes_supported_models", fmt.Errorf("publishes_supported_models must be a bool")
		}
		if err := json.Unmarshal(v, &req.PublishesSupportedModels); err != nil {
			return AuthRequest{}, presence, "publishes_supported_models", err
		}
	}
	return req, presence, "", nil
}

func (r AuthRequest) Hello() Hello {
	return Hello{
		Type:                   "hello",
		Version:                1,
		Tier:                   1,
		ProviderID:             r.ProviderID,
		Hostname:               r.Hostname,
		ModelID:                r.ModelID,
		ModelHash:              r.ModelHash,
		ModelHashAlgorithm:     r.ModelHashAlgorithm,
		WeightsManifestSHA256:  r.WeightsManifestSHA256,
		WeightsHashAlgorithm:   r.WeightsHashAlgorithm,
		ModelParamsB:           r.ModelParamsB,
		RAMGB:                  r.RAMGB,
		MaxContextTokens:       r.MaxContextTokens,
		MaxConcurrency:         r.MaxConcurrency,
		ThroughputTPSEstimate:  r.ThroughputTPSEstimate,
		ModelLoadTimeMs:        r.ModelLoadTimeMs,
		BinaryVersion:          r.BinaryVersion,
		EndpointURL:            r.EndpointURL,
		CatalogReleaseID:       r.CatalogReleaseID,
		CatalogPolicyVersion:   r.CatalogPolicyVersion,
		CandidateCatalogSHA256: r.CandidateCatalogSHA256,
		CatalogSignerKeyID:     r.CatalogSignerKeyID,
		CandidateRowIdentity:   r.CandidateRowIdentity,
		CompatibilitySetID:     r.CompatibilitySetID,
		CredentialBootstrap:    r.CredentialBootstrap,
		ReferralCode:           r.ReferralCode,
	}
}

// parseOptionalCompatibilitySetID extracts the field without changing legacy
// parsing behavior when the coordinator policy is unconfigured. Configured
// admission performs the required syntax and length validation in Server,
// where missing, non-string, malformed, and unaccepted IDs receive stable
// policy-specific rejection codes.
func parseOptionalCompatibilitySetID(raw map[string]json.RawMessage, out *string) {
	value, ok := raw["compatibility_set_id"]
	if !ok || string(value) == "null" {
		return
	}
	var parsed string
	if json.Unmarshal(value, &parsed) == nil {
		*out = parsed
	}
}

func parseCatalogAdmissionMetadata(raw map[string]json.RawMessage, releaseID, policyVersion, digest, signerKeyID, rowIdentity *string) (string, error) {
	fields := []struct {
		name string
		out  *string
	}{
		{"catalog_release_id", releaseID},
		{"catalog_policy_version", policyVersion},
		{"catalog_candidate_sha256", digest},
		{"catalog_signer_key_id", signerKeyID},
		{"catalog_row_identity", rowIdentity},
	}
	for _, field := range fields {
		value, ok := raw[field.name]
		if !ok {
			continue
		}
		if string(value) == "null" || json.Unmarshal(value, field.out) != nil || strings.TrimSpace(*field.out) == "" || containsControlChar(*field.out) {
			return field.name, fieldError{Field: field.name}
		}
		if len([]byte(*field.out)) > maxHandshakeMetadataBytes {
			return field.name, fmt.Errorf("%s exceeds %d bytes", field.name, maxHandshakeMetadataBytes)
		}
	}
	return "", nil
}

type fieldError struct {
	Field string
}

func (e fieldError) Error() string {
	return e.Field
}

func requireString(raw map[string]json.RawMessage, field string, out *string) *fieldError {
	v, ok := raw[field]
	if !ok {
		return &fieldError{Field: "missing " + field}
	}
	if err := json.Unmarshal(v, out); err != nil || *out == "" {
		return &fieldError{Field: field}
	}
	if containsControlChar(*out) {
		return &fieldError{Field: field}
	}
	return nil
}

// containsControlChar reports whether s contains any C0 control
// (`<0x20`), DEL (`0x7f`), or C1 control (`0x80-0x9f`) codepoint.
// SPEC-002 v1.5.1 R-2 / issue #197 R4-R5 security: provider-controlled
// strings reaching structured logs or close-frame reason fields MUST
// be rejected when they carry these codepoints. JSON “ decodes
// to U+009B and is valid UTF-8 but would otherwise inject a terminal
// CSI sequence into log sinks.
func containsControlChar(s string) bool {
	for _, r := range s {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) {
			return true
		}
	}
	return false
}

func isLowerHex(s string) bool {
	for _, r := range s {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return s != ""
}

func requireInt(raw map[string]json.RawMessage, field string, out *int) *fieldError {
	v, ok := raw[field]
	if !ok {
		return &fieldError{Field: "missing " + field}
	}
	if err := json.Unmarshal(v, out); err != nil {
		return &fieldError{Field: field}
	}
	return nil
}

func requireBool(raw map[string]json.RawMessage, field string, out *bool) *fieldError {
	v, ok := raw[field]
	if !ok {
		return &fieldError{Field: "missing " + field}
	}
	if string(v) == "null" {
		return &fieldError{Field: field}
	}
	if err := json.Unmarshal(v, out); err != nil {
		return &fieldError{Field: field}
	}
	return nil
}

func requireAuthVersion(raw map[string]json.RawMessage, out *int) *fieldError {
	v, ok := raw["version"]
	if !ok {
		return &fieldError{Field: "missing version"}
	}
	if err := json.Unmarshal(v, out); err == nil {
		return nil
	}
	var s string
	if err := json.Unmarshal(v, &s); err != nil || s == "" {
		return &fieldError{Field: "version"}
	}
	parsed, err := strconv.Atoi(s)
	if err != nil {
		return &fieldError{Field: "version"}
	}
	*out = parsed
	return nil
}

func requireFloat(raw map[string]json.RawMessage, field string, out *float64) *fieldError {
	v, ok := raw[field]
	if !ok {
		return &fieldError{Field: "missing " + field}
	}
	if err := json.Unmarshal(v, out); err != nil {
		return &fieldError{Field: field}
	}
	return nil
}

func parseOptionalIdentityString(raw map[string]json.RawMessage, field string, out *string) (bool, error) {
	v, ok := raw[field]
	if !ok {
		return false, nil
	}
	if string(v) == "null" {
		return true, fmt.Errorf("%s must be a string", field)
	}
	if err := json.Unmarshal(v, out); err != nil {
		return true, err
	}
	if *out == "" || len([]byte(*out)) > 128 || containsControlChar(*out) {
		return true, fmt.Errorf("%s must be a non-empty string of at most 128 bytes", field)
	}
	return true, nil
}

func parseModelIdentityMetadata(
	raw map[string]json.RawMessage,
	modelHash string,
	modelHashAlgorithm, weightsHash, weightsHashAlgorithm *string,
) (string, error) {
	modelAlgorithmPresent, err := parseOptionalIdentityString(raw, "model_hash_algorithm", modelHashAlgorithm)
	if err != nil {
		return "model_hash_algorithm", err
	}
	if modelAlgorithmPresent && modelHash == "" {
		return "model_hash_algorithm", fmt.Errorf("model_hash_algorithm requires model_hash")
	}
	if modelAlgorithmPresent && *modelHashAlgorithm != modelidentity.SnapshotManifestV1 {
		return "model_hash_algorithm", fmt.Errorf("unsupported model_hash_algorithm")
	}
	if modelAlgorithmPresent && !modelidentity.ValidSHA256(modelHash) {
		return "model_hash", fmt.Errorf("model_hash must be a lowercase SHA-256 digest")
	}
	weightsPresent, err := parseOptionalIdentityString(raw, "weights_manifest_sha256", weightsHash)
	if err != nil {
		return "weights_manifest_sha256", err
	}
	weightsAlgorithmPresent, err := parseOptionalIdentityString(raw, "weights_manifest_algorithm", weightsHashAlgorithm)
	if err != nil {
		return "weights_manifest_algorithm", err
	}
	if weightsPresent != weightsAlgorithmPresent {
		return "weights_manifest_algorithm", fmt.Errorf("weights_manifest_sha256 and weights_manifest_algorithm must be reported together")
	}
	if weightsAlgorithmPresent && *weightsHashAlgorithm != modelidentity.SafetensorsManifestV1 {
		return "weights_manifest_algorithm", fmt.Errorf("unsupported weights_manifest_algorithm")
	}
	if weightsPresent && !modelidentity.ValidSHA256(*weightsHash) {
		return "weights_manifest_sha256", fmt.Errorf("weights_manifest_sha256 must be a lowercase SHA-256 digest")
	}
	return "", nil
}

func ParseHeartbeat(payload []byte) (Heartbeat, HeartbeatPresence, string, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, "json", err
	}
	var hb Heartbeat
	if err := requireString(raw, "type", &hb.Type); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	if hb.Type != "heartbeat" {
		return Heartbeat{}, HeartbeatPresence{}, "type", fmt.Errorf("expected heartbeat, got %q", hb.Type)
	}
	if err := requireString(raw, "status", &hb.Status); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	if err := requireString(raw, "model_id", &hb.ModelID); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	if len([]byte(hb.ModelID)) > maxHandshakeModelIDBytes {
		return Heartbeat{}, HeartbeatPresence{}, "model_id", fmt.Errorf("model_id exceeds %d bytes", maxHandshakeModelIDBytes)
	}
	if err := requireFloat(raw, "model_params_b", &hb.ModelParamsB); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	if err := requireInt(raw, "ram_gb", &hb.RAMGB); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	if err := requireInt(raw, "max_context_tokens", &hb.MaxContextTokens); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	if err := requireInt(raw, "max_concurrency", &hb.MaxConcurrency); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	if err := requireInt(raw, "slots_free", &hb.SlotsFree); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	if err := requireInt(raw, "slots_total", &hb.SlotsTotal); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	if err := requireFloat(raw, "throughput_tps_estimate", &hb.ThroughputTPSEstimate); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	if err := requireInt(raw, "requests_served_since_last", &hb.RequestsServedSinceLast); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	if err := requireFloat(raw, "avg_latency_ms_since_last", &hb.AvgLatencyMSSinceLast); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	if err := requireFloat(raw, "throughput_tps_since_last", &hb.ThroughputTPSSinceLast); err != nil {
		return Heartbeat{}, HeartbeatPresence{}, err.Field, err
	}
	presence := HeartbeatPresence{}
	if v, ok := raw["model_hash"]; ok {
		presence.ModelHash = true
		if string(v) == "null" {
			return Heartbeat{}, presence, "model_hash", fmt.Errorf("model_hash must be a string")
		}
		if err := json.Unmarshal(v, &hb.ModelHash); err != nil {
			return Heartbeat{}, presence, "model_hash", err
		}
		if containsControlChar(hb.ModelHash) {
			return Heartbeat{}, presence, "model_hash", fieldError{Field: "model_hash"}
		}
	}
	var err error
	presence.ModelHashAlgorithm, err = parseOptionalIdentityString(raw, "model_hash_algorithm", &hb.ModelHashAlgorithm)
	if err != nil {
		return Heartbeat{}, presence, "model_hash_algorithm", err
	}
	presence.WeightsManifestSHA256, err = parseOptionalIdentityString(raw, "weights_manifest_sha256", &hb.WeightsManifestSHA256)
	if err != nil {
		return Heartbeat{}, presence, "weights_manifest_sha256", err
	}
	presence.WeightsHashAlgorithm, err = parseOptionalIdentityString(raw, "weights_manifest_algorithm", &hb.WeightsHashAlgorithm)
	if err != nil {
		return Heartbeat{}, presence, "weights_manifest_algorithm", err
	}
	if presence.ModelHashAlgorithm && !presence.ModelHash {
		return Heartbeat{}, presence, "model_hash_algorithm", fmt.Errorf("model_hash_algorithm requires model_hash")
	}
	if presence.ModelHashAlgorithm && hb.ModelHashAlgorithm != modelidentity.SnapshotManifestV1 {
		return Heartbeat{}, presence, "model_hash_algorithm", fmt.Errorf("unsupported model_hash_algorithm")
	}
	if presence.ModelHashAlgorithm && !modelidentity.ValidSHA256(hb.ModelHash) {
		return Heartbeat{}, presence, "model_hash", fmt.Errorf("model_hash must be a lowercase SHA-256 digest")
	}
	if presence.WeightsManifestSHA256 != presence.WeightsHashAlgorithm {
		return Heartbeat{}, presence, "weights_manifest_algorithm", fmt.Errorf("weights_manifest_sha256 and weights_manifest_algorithm must be reported together")
	}
	if presence.WeightsHashAlgorithm && hb.WeightsHashAlgorithm != modelidentity.SafetensorsManifestV1 {
		return Heartbeat{}, presence, "weights_manifest_algorithm", fmt.Errorf("unsupported weights_manifest_algorithm")
	}
	if presence.WeightsManifestSHA256 && !modelidentity.ValidSHA256(hb.WeightsManifestSHA256) {
		return Heartbeat{}, presence, "weights_manifest_sha256", fmt.Errorf("weights_manifest_sha256 must be a lowercase SHA-256 digest")
	}
	if v, ok := raw["loading"]; ok {
		presence.Loading = true
		if string(v) == "null" {
			return Heartbeat{}, presence, "loading", fmt.Errorf("loading must be a bool")
		}
		if err := json.Unmarshal(v, &hb.Loading); err != nil {
			return Heartbeat{}, presence, "loading", err
		}
	}
	if v, ok := raw["last_autoupdate_event"]; ok && string(v) != "null" {
		if !validAutoupdateEventObject(v) {
			return Heartbeat{}, presence, "last_autoupdate_event", fieldError{Field: "last_autoupdate_event"}
		}
		hb.LastAutoupdateEvent = append([]byte(nil), v...)
	}
	if v, ok := raw["hardware_summary"]; ok && string(v) != "null" {
		var summary HardwareSummary
		if err := json.Unmarshal(v, &summary); err == nil {
			summary.Chip = strings.TrimSpace(summary.Chip)
			if len([]byte(summary.Chip)) <= pool.MaxProviderHardwareChipBytes &&
				!containsControlChar(summary.Chip) &&
				summary.BandwidthGBPerSec >= 0 &&
				summary.BandwidthGBPerSec <= pool.MaxProviderHardwareBandwidthGBPerSec &&
				summary.NetworkPowerKW >= 0 &&
				!math.IsNaN(summary.NetworkPowerKW) &&
				!math.IsInf(summary.NetworkPowerKW, 0) &&
				summary.NetworkPowerKW <= pool.MaxProviderHardwareNetworkPowerKW &&
				summary.GPUCoresTotal >= 0 &&
				summary.GPUCoresTotal <= pool.MaxProviderHardwareGPUCoresTotal &&
				summary.CPUCoresTotal >= 0 &&
				summary.CPUCoresTotal <= pool.MaxProviderHardwareCPUCoresTotal {
				hb.HardwareSummary = &summary
			}
		}
	}
	if v, ok := raw["safety_telemetry"]; ok && string(v) != "null" {
		var telemetryRaw map[string]json.RawMessage
		if err := json.Unmarshal(v, &telemetryRaw); err != nil {
			return Heartbeat{}, presence, "safety_telemetry", err
		}
		for _, required := range []string{
			"schema_version", "provider_id", "model_id", "model_loaded", "runtime_state",
			"hardware_tier", "requests_in_flight", "requests_queued", "memory_rss_mb",
			"memory_capacity_mb", "memory_pressure", "thermal_state", "thermally_throttled",
			"restart_count", "uptime_s", "coordinator_connected", "observation_id",
			"observed_at", "valid_for_ms",
		} {
			if value, exists := telemetryRaw[required]; !exists || string(value) == "null" {
				return Heartbeat{}, presence, "safety_telemetry." + required, fmt.Errorf("missing safety telemetry field %s", required)
			}
		}
		var schemaVersion int
		if err := json.Unmarshal(telemetryRaw["schema_version"], &schemaVersion); err != nil {
			return Heartbeat{}, presence, "safety_telemetry.schema_version", err
		}
		if schemaVersion == 2 {
			for _, required := range []string{
				"coordinator_session_id", "cpu_utilization_pct", "gpu_utilization_pct", "gpu_utilization_scope", "power_source",
				"binary_version", "compatibility_set_id", "model_hash", "model_hash_algorithm",
			} {
				if _, exists := telemetryRaw[required]; !exists {
					return Heartbeat{}, presence, "safety_telemetry." + required, fmt.Errorf("missing safety telemetry field %s", required)
				}
			}
		}
		var telemetry pool.ProviderSafetyTelemetry
		if err := json.Unmarshal(v, &telemetry); err != nil {
			return Heartbeat{}, presence, "safety_telemetry", err
		}
		if (telemetry.SchemaVersion != 1 && telemetry.SchemaVersion != 2) || telemetry.ProviderID == "" || telemetry.ModelID != hb.ModelID ||
			telemetry.RuntimeState != hb.Status || telemetry.HardwareTier == "" ||
			len(telemetry.ProviderID) > 256 || len(telemetry.ModelID) > maxHandshakeModelIDBytes ||
			len(telemetry.HardwareTier) > 128 || len(telemetry.ObservationID) > 128 || len(telemetry.ObservedAt) > 64 ||
			containsControlChar(telemetry.ProviderID) || containsControlChar(telemetry.ModelID) ||
			containsControlChar(telemetry.HardwareTier) || containsControlChar(telemetry.ObservationID) ||
			telemetry.RequestsInFlight < 0 || telemetry.RequestsQueued < 0 ||
			telemetry.MemoryRSSMB < 0 || telemetry.MemoryCapacityMB < 1 ||
			telemetry.RestartCount < 0 || telemetry.UptimeS < 0 ||
			telemetry.ObservationID == "" ||
			telemetry.ValidForMS < 1 || telemetry.ValidForMS > 300_000 {
			return Heartbeat{}, presence, "safety_telemetry", fmt.Errorf("invalid safety telemetry")
		}
		if telemetry.SchemaVersion == 2 {
			if telemetry.CoordinatorSessionID == "" || telemetry.GPUUtilizationScope != "host" ||
				telemetry.BinaryVersion == "" || telemetry.CompatibilitySetID == "" ||
				len(telemetry.CoordinatorSessionID) > 256 ||
				len(telemetry.BinaryVersion) > maxHandshakeBinaryVersionBytes || len(telemetry.CompatibilitySetID) > 1024 ||
				containsControlChar(telemetry.CoordinatorSessionID) ||
				containsControlChar(telemetry.BinaryVersion) || containsControlChar(telemetry.CompatibilitySetID) {
				return Heartbeat{}, presence, "safety_telemetry", fmt.Errorf("invalid version 2 safety telemetry identity")
			}
			if telemetry.ModelHashAlgorithm != modelidentity.SnapshotManifestV1 {
				return Heartbeat{}, presence, "safety_telemetry.model_hash_algorithm", fmt.Errorf("unsupported safety telemetry model_hash_algorithm")
			}
			if !modelidentity.ValidSHA256(telemetry.ModelHash) {
				return Heartbeat{}, presence, "safety_telemetry.model_hash", fmt.Errorf("invalid safety telemetry model_hash")
			}
			if !presence.ModelHash || !presence.ModelHashAlgorithm {
				return Heartbeat{}, presence, "safety_telemetry.model_hash", fmt.Errorf("version 2 safety telemetry requires the outer heartbeat model identity")
			}
			if telemetry.ModelHash != hb.ModelHash {
				return Heartbeat{}, presence, "safety_telemetry.model_hash", fmt.Errorf("safety telemetry model_hash does not match heartbeat")
			}
			if telemetry.ModelHashAlgorithm != hb.ModelHashAlgorithm {
				return Heartbeat{}, presence, "safety_telemetry.model_hash_algorithm", fmt.Errorf("safety telemetry model_hash_algorithm does not match heartbeat")
			}
			_, telemetryWeightsPresent := telemetryRaw["weights_manifest_sha256"]
			_, telemetryWeightsAlgorithmPresent := telemetryRaw["weights_manifest_algorithm"]
			if telemetryWeightsPresent != telemetryWeightsAlgorithmPresent {
				return Heartbeat{}, presence, "safety_telemetry.weights_manifest_algorithm", fmt.Errorf("safety telemetry weights identity must be reported together")
			}
			if telemetryWeightsPresent {
				if telemetry.WeightsHashAlgorithm != modelidentity.SafetensorsManifestV1 {
					return Heartbeat{}, presence, "safety_telemetry.weights_manifest_algorithm", fmt.Errorf("unsupported safety telemetry weights_manifest_algorithm")
				}
				if !modelidentity.ValidSHA256(telemetry.WeightsManifestSHA256) {
					return Heartbeat{}, presence, "safety_telemetry.weights_manifest_sha256", fmt.Errorf("invalid safety telemetry weights_manifest_sha256")
				}
				if !presence.WeightsManifestSHA256 || !presence.WeightsHashAlgorithm {
					return Heartbeat{}, presence, "safety_telemetry.weights_manifest_sha256", fmt.Errorf("safety telemetry weights identity requires the outer heartbeat weights identity")
				}
				if telemetry.WeightsManifestSHA256 != hb.WeightsManifestSHA256 {
					return Heartbeat{}, presence, "safety_telemetry.weights_manifest_sha256", fmt.Errorf("safety telemetry weights_manifest_sha256 does not match heartbeat")
				}
				if telemetry.WeightsHashAlgorithm != hb.WeightsHashAlgorithm {
					return Heartbeat{}, presence, "safety_telemetry.weights_manifest_algorithm", fmt.Errorf("safety telemetry weights_manifest_algorithm does not match heartbeat")
				}
			}
			for field, value := range map[string]*float64{
				"cpu_utilization_pct": telemetry.CPUUtilizationPct,
				"gpu_utilization_pct": telemetry.GPUUtilizationPct,
			} {
				if value != nil && (math.IsNaN(*value) || math.IsInf(*value, 0) || *value < 0 || *value > 100) {
					return Heartbeat{}, presence, "safety_telemetry." + field, fmt.Errorf("invalid utilization")
				}
			}
			if telemetry.PowerSource != "external" && telemetry.PowerSource != "battery" && telemetry.PowerSource != "unknown" {
				return Heartbeat{}, presence, "safety_telemetry.power_source", fmt.Errorf("invalid power source")
			}
		}
		if telemetry.MemoryPressure != "normal" && telemetry.MemoryPressure != "warning" && telemetry.MemoryPressure != "critical" {
			return Heartbeat{}, presence, "safety_telemetry.memory_pressure", fmt.Errorf("invalid memory pressure")
		}
		if telemetry.ThermalState != "nominal" && telemetry.ThermalState != "fair" && telemetry.ThermalState != "serious" && telemetry.ThermalState != "critical" {
			return Heartbeat{}, presence, "safety_telemetry.thermal_state", fmt.Errorf("invalid thermal state")
		}
		if _, err := time.Parse(time.RFC3339Nano, telemetry.ObservedAt); err != nil {
			return Heartbeat{}, presence, "safety_telemetry.observed_at", err
		}
		hb.SafetyTelemetry = &telemetry
	}
	return hb, presence, "", nil
}

func ParseDiagnosticStatus(payload []byte) (DiagnosticStatus, string, error) {
	if len(payload) > 8192 {
		return DiagnosticStatus{}, "payload", fmt.Errorf("diagnostic_status exceeds 8192 bytes")
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return DiagnosticStatus{}, "json", err
	}
	var diag DiagnosticStatus
	if err := requireString(raw, "type", &diag.Type); err != nil {
		return DiagnosticStatus{}, err.Field, err
	}
	if diag.Type != "diagnostic_status" {
		return DiagnosticStatus{}, "type", fmt.Errorf("expected diagnostic_status, got %q", diag.Type)
	}
	if err := requireInt(raw, "schema_version", &diag.SchemaVersion); err != nil {
		return DiagnosticStatus{}, err.Field, err
	}
	if diag.SchemaVersion != 1 {
		return DiagnosticStatus{}, "schema_version", fmt.Errorf("unsupported diagnostic_status schema")
	}
	if err := requireString(raw, "provider_id", &diag.ProviderID); err != nil {
		return DiagnosticStatus{}, err.Field, err
	}
	if err := requireString(raw, "assigned_id", &diag.AssignedID); err != nil {
		return DiagnosticStatus{}, err.Field, err
	}
	if err := requireString(raw, "status", &diag.Status); err != nil {
		return DiagnosticStatus{}, err.Field, err
	}
	if err := requireString(raw, "model_id", &diag.ModelID); err != nil {
		return DiagnosticStatus{}, err.Field, err
	}
	if len([]byte(diag.ModelID)) > maxHandshakeModelIDBytes {
		return DiagnosticStatus{}, "model_id", fmt.Errorf("model_id exceeds %d bytes", maxHandshakeModelIDBytes)
	}
	if err := requireBool(raw, "model_loaded", &diag.ModelLoaded); err != nil {
		return DiagnosticStatus{}, err.Field, err
	}
	_ = json.Unmarshal(raw["binary_version"], &diag.BinaryVersion)
	_ = json.Unmarshal(raw["reason"], &diag.Reason)
	_ = json.Unmarshal(raw["observed_at"], &diag.ObservedAt)
	_ = json.Unmarshal(raw["model_hash"], &diag.ModelHash)
	_ = json.Unmarshal(raw["model_hash_algorithm"], &diag.ModelHashAlgorithm)
	_ = json.Unmarshal(raw["uptime_s"], &diag.UptimeS)
	_ = json.Unmarshal(raw["requests_total"], &diag.RequestsTotal)
	_ = json.Unmarshal(raw["requests_in_flight"], &diag.RequestsInFlight)
	_ = json.Unmarshal(raw["errors_total"], &diag.ErrorsTotal)
	_ = json.Unmarshal(raw["restart_count"], &diag.RestartCount)
	_ = json.Unmarshal(raw["memory_rss_mb"], &diag.MemoryRSSMB)
	_ = json.Unmarshal(raw["memory_pressure"], &diag.MemoryPressure)
	_ = json.Unmarshal(raw["thermal_state"], &diag.ThermalState)
	_ = json.Unmarshal(raw["thermally_throttled"], &diag.ThermallyThrottled)
	diag.LastConnectionFailure = raw["last_connection_failure"]
	for field, value := range map[string]string{
		"provider_id":          diag.ProviderID,
		"assigned_id":          diag.AssignedID,
		"binary_version":       diag.BinaryVersion,
		"status":               diag.Status,
		"model_id":             diag.ModelID,
		"model_hash":           diag.ModelHash,
		"model_hash_algorithm": diag.ModelHashAlgorithm,
		"memory_pressure":      diag.MemoryPressure,
		"thermal_state":        diag.ThermalState,
	} {
		if containsControlChar(value) {
			return DiagnosticStatus{}, field, fmt.Errorf("%s contains control characters", field)
		}
	}
	return diag, "", nil
}

func ParseIdlePrewarmEvent(payload []byte) (IdlePrewarmEvent, string, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return IdlePrewarmEvent{}, "json", err
	}
	var ev IdlePrewarmEvent
	if err := requireString(raw, "type", &ev.Type); err != nil {
		return IdlePrewarmEvent{}, err.Field, err
	}
	if ev.Type != "idle_prewarm_event" {
		return IdlePrewarmEvent{}, "type", fmt.Errorf("expected idle_prewarm_event, got %q", ev.Type)
	}
	if err := requireString(raw, "event", &ev.Event); err != nil {
		return IdlePrewarmEvent{}, err.Field, err
	}
	if !validIdlePrewarmEvent(ev.Event) {
		return IdlePrewarmEvent{}, "event", fmt.Errorf("invalid idle prewarm event %q", ev.Event)
	}
	if v, ok := raw["reason"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &ev.Reason); err != nil {
			return IdlePrewarmEvent{}, "reason", err
		}
		if !validIdlePrewarmReason(ev.Reason) {
			return IdlePrewarmEvent{}, "reason", fmt.Errorf("invalid idle prewarm reason %q", ev.Reason)
		}
	}
	if ev.Event == "idle_prewarm_skipped" && ev.Reason == "" {
		return IdlePrewarmEvent{}, "reason", fmt.Errorf("idle_prewarm_skipped requires reason")
	}
	if ev.Event != "idle_prewarm_skipped" && ev.Reason != "" {
		return IdlePrewarmEvent{}, "reason", fmt.Errorf("reason is only valid for idle_prewarm_skipped")
	}
	return ev, "", nil
}

func validIdlePrewarmEvent(event string) bool {
	switch event {
	case "idle_prewarm_fired",
		"idle_prewarm_completed",
		"idle_prewarm_skipped",
		"idle_prewarm_cancelled_by_real_request",
		"idle_prewarm_failed":
		return true
	default:
		return false
	}
}

func validIdlePrewarmReason(reason string) bool {
	switch reason {
	case "disabled", "busy", "not_idle_yet", "thermal_pressure", "on_battery", "model_not_loaded":
		return true
	default:
		return false
	}
}

func ParseStateUpdate(payload []byte) (StateUpdate, string, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return StateUpdate{}, "json", err
	}
	var update StateUpdate
	if err := requireString(raw, "type", &update.Type); err != nil {
		return StateUpdate{}, err.Field, err
	}
	if update.Type != "state_update" {
		return StateUpdate{}, "type", fmt.Errorf("expected state_update, got %q", update.Type)
	}
	if err := requireString(raw, "state", &update.State); err != nil {
		return StateUpdate{}, err.Field, err
	}
	if v, ok := raw["reason"]; ok {
		_ = json.Unmarshal(v, &update.Reason)
		if containsControlChar(update.Reason) {
			return StateUpdate{}, "reason", fieldError{Field: "reason"}
		}
	}
	if v, ok := raw["since"]; ok {
		_ = json.Unmarshal(v, &update.Since)
		if containsControlChar(update.Since) {
			return StateUpdate{}, "since", fieldError{Field: "since"}
		}
	}
	if v, ok := raw["metrics_snapshot"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &update.MetricsSnapshot); err != nil {
			return StateUpdate{}, "metrics_snapshot", err
		}
	}
	if v, ok := raw["last_autoupdate_event"]; ok && string(v) != "null" {
		if !validAutoupdateEventObject(v) {
			return StateUpdate{}, "last_autoupdate_event", fieldError{Field: "last_autoupdate_event"}
		}
		update.LastAutoupdateEvent = append([]byte(nil), v...)
	}
	return update, "", nil
}

func validAutoupdateEventObject(raw json.RawMessage) bool {
	if len(raw) == 0 || len(raw) > 4096 {
		return false
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err != nil {
		return false
	}
	return object != nil
}

func ParsePreflightAck(payload []byte) (PreflightAck, string, error) {
	var ack PreflightAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		return PreflightAck{}, "json", err
	}
	if ack.Type != "preflight_ack" {
		return PreflightAck{}, "type", fmt.Errorf("expected preflight_ack, got %q", ack.Type)
	}
	if ack.RequestID == "" {
		return PreflightAck{}, "request_id", fieldError{Field: "missing request_id"}
	}
	if containsControlChar(ack.RequestID) {
		return PreflightAck{}, "request_id", fieldError{Field: "request_id"}
	}
	if !ack.Accepted {
		if _, ok := preflightRejectionReasons[ack.Reason]; !ok {
			return PreflightAck{}, "reason", fieldError{Field: "invalid reason"}
		}
	}
	return ack, "", nil
}

func ParseDrainStatus(payload []byte) (DrainStatus, string, error) {
	var status DrainStatus
	if err := json.Unmarshal(payload, &status); err != nil {
		return DrainStatus{}, "json", err
	}
	if status.Type != "drain_status" {
		return DrainStatus{}, "type", fmt.Errorf("expected drain_status, got %q", status.Type)
	}
	switch status.Phase {
	case "starting", "in_progress", "complete", "timeout_skipped":
	default:
		return DrainStatus{}, "phase", fieldError{Field: "invalid phase"}
	}
	if status.InflightRequests < 0 {
		return DrainStatus{}, "inflight_requests", fieldError{Field: "invalid inflight_requests"}
	}
	if status.EstimatedDrainSeconds < 0 {
		return DrainStatus{}, "estimated_drain_seconds", fieldError{Field: "invalid estimated_drain_seconds"}
	}
	return status, "", nil
}

func ParseNak(payload []byte) (Nak, string, error) {
	var nak Nak
	if err := json.Unmarshal(payload, &nak); err != nil {
		return Nak{}, "json", err
	}
	if nak.Type != "nak" {
		return Nak{}, "type", fmt.Errorf("expected nak, got %q", nak.Type)
	}
	if nak.InReplyTo == "" {
		return Nak{}, "in_reply_to", fieldError{Field: "missing in_reply_to"}
	}
	if nak.Error.Code == "" {
		return Nak{}, "error.code", fieldError{Field: "missing error.code"}
	}
	// SPEC-002 v1.5.1 R-2 / issue #197 R5 security: nak.in_reply_to,
	// nak.error.code, and nak.error.message all reach structured logs
	// on the inference-failure path; reject control-character payloads
	// at parse time to prevent terminal-CSI log injection.
	if containsControlChar(nak.InReplyTo) {
		return Nak{}, "in_reply_to", fieldError{Field: "in_reply_to"}
	}
	if containsControlChar(nak.Error.Code) {
		return Nak{}, "error.code", fieldError{Field: "error.code"}
	}
	if containsControlChar(nak.Error.Message) {
		return Nak{}, "error.message", fieldError{Field: "error.message"}
	}
	return nak, "", nil
}
