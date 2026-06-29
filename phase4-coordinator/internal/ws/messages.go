package ws

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
)

type Hello struct {
	Type                  string          `json:"type"`
	Version               int             `json:"version"`
	Tier                  int             `json:"tier"`
	ProviderID            string          `json:"provider_id"`
	Hostname              string          `json:"hostname"`
	ModelID               string          `json:"model_id"`
	ModelHash             string          `json:"model_hash,omitempty"`
	ModelParamsB          float64         `json:"model_params_b"`
	RAMGB                 int             `json:"ram_gb"`
	MaxContextTokens      int             `json:"max_context_tokens"`
	MaxConcurrency        int             `json:"max_concurrency"`
	ThroughputTPSEstimate float64         `json:"throughput_tps_estimate"`
	ModelLoadTimeMs       int64           `json:"model_load_time_ms,omitempty"`
	BinaryVersion         string          `json:"binary_version"`
	Attestation           json.RawMessage `json:"attestation"`
	EndpointURL           *string         `json:"endpoint_url,omitempty"`
}

type HelloAck struct {
	Type                     string `json:"type"`
	CoordinatorVersion       int    `json:"coordinator_version"`
	AssignedID               string `json:"assigned_id"`
	HeartbeatIntervalS       int    `json:"heartbeat_interval_s"`
	Tier                     string `json:"tier,omitempty"`
	RecommendedBinaryVersion string `json:"recommended_binary_version,omitempty"`
	RequiredBinaryVersion    string `json:"required_binary_version,omitempty"`
	// SPEC-003 v0.8 FR-C9.2 — populated only when a tokenless provisional
	// provider was just self-minted on this connect. Binary persists to
	// the top-level `provider_token` YAML key (FR-C9.3) so the next
	// reconnect carries Bearer. Note: top-level, NOT nested under
	// `auth:` — codex audit on PR #44 caught the prior spec/code drift.
	AssignedProviderToken string `json:"assigned_provider_token,omitempty"`
	PairOT                string `json:"pair_ot,omitempty"`
	ClaimURL              string `json:"claim_url,omitempty"`
}

type AuthRequest struct {
	Type                     string          `json:"type"`
	Version                  int             `json:"version"`
	Stage                    string          `json:"stage"`
	AuthAttemptID            string          `json:"auth_attempt_id,omitempty"`
	ProviderID               string          `json:"provider_id"`
	Hostname                 string          `json:"hostname,omitempty"`
	ModelID                  string          `json:"model_id,omitempty"`
	ModelHash                string          `json:"model_hash,omitempty"`
	ModelParamsB             float64         `json:"model_params_b,omitempty"`
	RAMGB                    int             `json:"ram_gb,omitempty"`
	MaxContextTokens         int             `json:"max_context_tokens,omitempty"`
	MaxConcurrency           int             `json:"max_concurrency,omitempty"`
	ThroughputTPSEstimate    float64         `json:"throughput_tps_estimate,omitempty"`
	ModelLoadTimeMs          int64           `json:"model_load_time_ms,omitempty"`
	BinaryVersion            string          `json:"binary_version,omitempty"`
	EndpointURL              *string         `json:"endpoint_url,omitempty"`
	ProviderECDHPublicKey    string          `json:"provider_ecdh_public_key,omitempty"`
	ProviderReceiptPublicKey string          `json:"provider_receipt_public_key,omitempty"`
	ProviderReceiptPubkey    []byte          `json:"-"`
	Tier2Capabilities        Tier2Caps       `json:"tier2_capabilities,omitempty"`
	AttestationToken         json.RawMessage `json:"attestation_token,omitempty"`
	SupportedModels          []string        `json:"supported_models,omitempty"`
	PublishesSupportedModels bool            `json:"publishes_supported_models,omitempty"`
}

type Spec010Presence struct {
	SupportedModels          bool
	PublishesSupportedModels bool
}

type Tier2Caps struct {
	EncryptedLeg bool     `json:"encrypted_leg"`
	Attestation  bool     `json:"attestation"`
	AEADSuites   []string `json:"aead_suites"`
}

type AuthChallenge struct {
	Type                     string   `json:"type"`
	Version                  int      `json:"version"`
	AuthAttemptID            string   `json:"auth_attempt_id"`
	AssignedID               string   `json:"assigned_id"`
	AttestationChallenge     string   `json:"attestation_challenge"`
	AttestationFormats       []string `json:"attestation_formats"`
	CoordinatorECDHPublicKey string   `json:"coordinator_ecdh_public_key"`
	SelectedAEADSuite        string   `json:"selected_aead_suite"`
	SelectedAEAD             string   `json:"selected_aead,omitempty"`
	KeyID                    string   `json:"key_id,omitempty"`
	ExpiresAt                string   `json:"expires_at"`
}

type AuthResponse struct {
	Type                     string             `json:"type"`
	Version                  int                `json:"version"`
	Status                   string             `json:"status"`
	AssignedID               string             `json:"assigned_id,omitempty"`
	HeartbeatIntervalS       int                `json:"heartbeat_interval_s,omitempty"`
	Tier                     string             `json:"tier,omitempty"`
	RecommendedBinaryVersion string             `json:"recommended_binary_version,omitempty"`
	RequiredBinaryVersion    string             `json:"required_binary_version,omitempty"`
	Tier2Session             *AuthTier2Session  `json:"tier2_session,omitempty"`
	Error                    *AuthResponseError `json:"error,omitempty"`
	// SPEC-003 v0.8 FR-C9.2 — populated only on proof-stage acceptance
	// when a tokenless provisional provider was just self-minted on this
	// connect. Never present on rejection-shaped responses.
	AssignedProviderToken string `json:"assigned_provider_token,omitempty"`
	PairOT                string `json:"pair_ot,omitempty"`
	ClaimURL              string `json:"claim_url,omitempty"`
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
	Enabled            bool   `json:"enabled"`
	Alg                string `json:"alg"`
	KID                string `json:"kid"`
	RekeyAfterRequests int    `json:"rekey_after_requests"`
	RekeyAfterSeconds  int    `json:"rekey_after_seconds"`
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
	Type                    string  `json:"type"`
	Status                  string  `json:"status"`
	ModelID                 string  `json:"model_id"`
	ModelParamsB            float64 `json:"model_params_b"`
	RAMGB                   int     `json:"ram_gb"`
	MaxContextTokens        int     `json:"max_context_tokens"`
	MaxConcurrency          int     `json:"max_concurrency"`
	SlotsFree               int     `json:"slots_free"`
	SlotsTotal              int     `json:"slots_total"`
	ThroughputTPSEstimate   float64 `json:"throughput_tps_estimate"`
	RequestsServedSinceLast int     `json:"requests_served_since_last"`
	AvgLatencyMSSinceLast   float64 `json:"avg_latency_ms_since_last"`
	ThroughputTPSSinceLast  float64 `json:"throughput_tps_since_last"`
	ModelHash               string  `json:"model_hash,omitempty"`
	Loading                 bool    `json:"loading,omitempty"`
}

type HeartbeatPresence struct {
	ModelHash bool
	Loading   bool
}

type StateUpdate struct {
	Type            string          `json:"type"`
	State           string          `json:"state"`
	Reason          string          `json:"reason"`
	Since           string          `json:"since"`
	MetricsSnapshot MetricsSnapshot `json:"metrics_snapshot"`
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
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	Stream    bool   `json:"stream"`
	Body      string `json:"body"`
}

type InferenceResponseChunk struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	Seq       int    `json:"seq"`
	Data      string `json:"data"`
}

type InferenceResponseEnd struct {
	Type       string          `json:"type"`
	RequestID  string          `json:"request_id"`
	Status     string          `json:"status"`
	ChunksSent int             `json:"chunks_sent"`
	Usage      json.RawMessage `json:"usage,omitempty"`
	Error      string          `json:"error,omitempty"`
	Retryable  *bool           `json:"retryable,omitempty"`
	// SPEC-015 v0.1.x: WS-tunneled non-streaming inference carries the
	// X-MacProvider-Receipt header value as a field on the
	// inference_response_end frame. Coordinator stamps it as the
	// response header when forwarding to the buyer, subject to the
	// same provider receipt-eligibility gate used on the HTTP-direct
	// path.
	Receipt string `json:"receipt,omitempty"`
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
	if err := requireString(raw, "hostname", &h.Hostname); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireString(raw, "model_id", &h.ModelID); err != nil {
		return Hello{}, err.Field, err
	}
	if v, ok := raw["model_hash"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &h.ModelHash); err != nil {
			return Hello{}, "model_hash", err
		}
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
	attestation, ok := raw["attestation"]
	if ok {
		h.Attestation = attestation
	}
	if v, ok := raw["endpoint_url"]; ok && string(v) != "null" {
		var endpoint string
		if err := json.Unmarshal(v, &endpoint); err != nil {
			return Hello{}, "endpoint_url", err
		}
		h.EndpointURL = &endpoint
	}
	return h, "", nil
}

func ParseFirstAuthMessage(payload []byte) (string, int, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return "", 0, err
	}
	var typ string
	if err := requireString(raw, "type", &typ); err != nil {
		return "", 0, err
	}
	var version int
	if err := requireInt(raw, "version", &version); err != nil {
		return "", 0, err
	}
	return typ, version, nil
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
	if err := requireInt(raw, "version", &req.Version); err != nil {
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
	if err := requireString(raw, "hostname", &req.Hostname); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if err := requireString(raw, "model_id", &req.ModelID); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if v, ok := raw["model_hash"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &req.ModelHash); err != nil {
			return AuthRequest{}, Spec010Presence{}, "model_hash", err
		}
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
	if v, ok := raw["endpoint_url"]; ok && string(v) != "null" {
		var endpoint string
		if err := json.Unmarshal(v, &endpoint); err != nil {
			return AuthRequest{}, Spec010Presence{}, "endpoint_url", err
		}
		req.EndpointURL = &endpoint
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
	return req, presence, "", nil
}

func parseAuthProof(raw map[string]json.RawMessage, req AuthRequest) (AuthRequest, Spec010Presence, string, error) {
	if err := requireString(raw, "auth_attempt_id", &req.AuthAttemptID); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if err := requireString(raw, "provider_id", &req.ProviderID); err != nil {
		return AuthRequest{}, Spec010Presence{}, err.Field, err
	}
	if token, ok := raw["attestation_token"]; ok {
		req.AttestationToken = token
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
		Type:                  "hello",
		Version:               1,
		Tier:                  1,
		ProviderID:            r.ProviderID,
		Hostname:              r.Hostname,
		ModelID:               r.ModelID,
		ModelHash:             r.ModelHash,
		ModelParamsB:          r.ModelParamsB,
		RAMGB:                 r.RAMGB,
		MaxContextTokens:      r.MaxContextTokens,
		MaxConcurrency:        r.MaxConcurrency,
		ThroughputTPSEstimate: r.ThroughputTPSEstimate,
		ModelLoadTimeMs:       r.ModelLoadTimeMs,
		BinaryVersion:         r.BinaryVersion,
		EndpointURL:           r.EndpointURL,
	}
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
	return nil
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
	return hb, presence, "", nil
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
	}
	if v, ok := raw["since"]; ok {
		_ = json.Unmarshal(v, &update.Since)
	}
	if v, ok := raw["metrics_snapshot"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &update.MetricsSnapshot); err != nil {
			return StateUpdate{}, "metrics_snapshot", err
		}
	}
	return update, "", nil
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
	case "starting", "in_progress", "complete":
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
	return nak, "", nil
}
