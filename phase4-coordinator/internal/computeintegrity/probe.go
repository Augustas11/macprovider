package computeintegrity

import (
	"fmt"
	"time"
)

// SPEC-036 owns its settlement-bearing probe wire framing (FR-6). It composes on
// SPEC-030's measurement math (support selection, TV interval — see tv.go) but does
// NOT reuse SPEC-030's losslessness_probe_v1 payload, type, schema_version, digest
// preimage, or carrier. In particular the digest is domain-separated over the full
// {type, schema_version, payload} object, so the two profiles produce different
// digests by construction.

const (
	ProbeRequestType   = "compute_integrity_probe_v1.request"
	ProbeResultType    = "compute_integrity_probe_v1.result"
	ProbeRequestSchema = "compute_integrity_probe_v1.request"
	ProbeResultSchema  = "compute_integrity_probe_v1.result"

	ProbeEncryptedRequestType = "compute_integrity_probe_v1.encrypted_request"
	ProbeEncryptedResultType  = "compute_integrity_probe_v1.encrypted_result"
	ProbeRequestPlaintextType = "compute_integrity_probe_v1.request_plaintext"
	ProbeResultPlaintextType  = "compute_integrity_probe_v1.result_plaintext"

	SupportSelectionV1 = "compute_integrity_support_selection_v1"

	// Result kinds (FR-6).
	ResultKindMeasurement          = "measurement"
	ResultKindProviderInconclusive = "provider_inconclusive"

	// FR-6 request bounds (inherited SPEC-030 §FR-3 policy values).
	MaxDistinctPrompts       = 4
	MaxPositions             = 8
	NonceMinBytes            = 16 // 128 bits
	ProbeExpirySeconds       = 120
	MaxConcurrentPerProvider = 1
)

// validProviderReasonCodes is the closed provider_inconclusive reason set (FR-6).
var validProviderReasonCodes = map[string]bool{
	"inconclusive:model_swap":            true,
	"inconclusive:unsupported_sampler":   true,
	"inconclusive:reference_unavailable": true,
	"inconclusive:position_mismatch":     true,
	"inconclusive:missing_distribution":  true,
	"inconclusive:timeout":               true,
}

// ValidProviderReasonCode reports membership in the closed provider inconclusive set.
func ValidProviderReasonCode(code string) bool { return validProviderReasonCodes[code] }

// ReferenceTopKSet carries one active reference's top-K token ids in a probe request
// (FR-6). The provider reports probabilities over the union so one probe answers
// every active reference.
type ReferenceTopKSet struct {
	ReferenceEventDigest  string  `json:"reference_event_digest"`
	ReferenceTopKTokenIDs []int64 `json:"reference_top_k_token_ids"`
}

// RequestPosition is one measured corpus position in a probe request (FR-6).
type RequestPosition struct {
	PromptID          string             `json:"prompt_id"`
	PromptRef         string             `json:"prompt_ref"`
	PositionIndex     int                `json:"position_index"`
	TokenPrefixDigest string             `json:"token_prefix_digest"`
	ContextHash       string             `json:"context_hash"`
	ReferenceTopKSets []ReferenceTopKSet `json:"reference_top_k_sets"`
}

// RequestPayload is the canonical compute_integrity_probe_v1.request payload (FR-6).
type RequestPayload struct {
	SchemaVersion        string            `json:"schema_version"`
	ProbeID              string            `json:"probe_id"`
	Nonce                string            `json:"nonce"`
	ExpiresAt            string            `json:"expires_at"`
	ModelID              string            `json:"model_id"`
	TargetModelHash      string            `json:"target_model_hash"`
	TokenizerIdentity    string            `json:"tokenizer_identity"`
	SamplerStage         string            `json:"sampler_stage"`
	TargetGeneration     int64             `json:"target_generation"`
	SamplingProfile      string            `json:"sampling_profile"`
	CorpusVersion        string            `json:"corpus_version"`
	ThresholdVersion     string            `json:"threshold_version"`
	HardwareRuntimeClass string            `json:"hardware_runtime_class"`
	SupportSelection     string            `json:"support_selection"`
	NormalizationBasis   string            `json:"normalization_basis"`
	K                    int               `json:"k"`
	Positions            []RequestPosition `json:"positions"`
	RetryOfProbeID       string            `json:"retry_of_probe_id,omitempty"`
}

// RequestEnvelope is the outer probe request envelope (FR-6). The digest is over the
// canonical {type, schema_version, payload}, excluding probe_request_digest.
type RequestEnvelope struct {
	Type               string         `json:"type"`
	SchemaVersion      string         `json:"schema_version"`
	Payload            RequestPayload `json:"payload"`
	ProbeRequestDigest string         `json:"probe_request_digest"`
}

// ResultPosition is one measured position in a measurement-kind result (FR-6).
type ResultPosition struct {
	PromptID                     string    `json:"prompt_id"`
	PositionIndex                int       `json:"position_index"`
	TokenPrefixDigest            string    `json:"token_prefix_digest"`
	ContextHash                  string    `json:"context_hash"`
	ProviderTopKTokenIDs         []int64   `json:"provider_top_k_token_ids"`
	SupportTokenIDs              []int64   `json:"support_token_ids"`
	ProviderSupportProbabilities []float64 `json:"provider_support_probabilities"`
	ProviderTailMass             float64   `json:"provider_tail_mass"`
	ActualTargetModelHash        string    `json:"actual_target_model_hash"`
	ActualTargetGeneration       int64     `json:"actual_target_generation"`
}

// ResultPayload is the canonical compute_integrity_probe_v1.result payload (FR-6). A
// discriminated union on ResultKind; the measurement variant carries Positions, the
// provider_inconclusive variant carries ProviderReasonCode.
type ResultPayload struct {
	SchemaVersion             string              `json:"schema_version"`
	ProbeID                   string              `json:"probe_id"`
	Nonce                     string              `json:"nonce"`
	ProbeRequestDigest        string              `json:"probe_request_digest"`
	ResultKind                string              `json:"result_kind"`
	RetryOfProbeID            string              `json:"retry_of_probe_id,omitempty"`
	ModelID                   string              `json:"model_id"`
	TargetModelHash           string              `json:"target_model_hash"`
	TokenizerIdentity         string              `json:"tokenizer_identity"`
	TargetGeneration          int64               `json:"target_generation"`
	SamplingProfile           string              `json:"sampling_profile"`
	CorpusVersion             string              `json:"corpus_version"`
	ThresholdVersion          string              `json:"threshold_version"`
	HardwareRuntimeClass      string              `json:"hardware_runtime_class"`
	SupportSelection          string              `json:"support_selection"`
	NormalizationBasis        string              `json:"normalization_basis"`
	SamplerStage              string              `json:"sampler_stage"`
	Positions                 []ResultPosition    `json:"positions,omitempty"`
	ValidationMetadata        *ValidationMetadata `json:"validation_metadata,omitempty"`
	ProviderReasonCode        string              `json:"provider_reason_code,omitempty"`
	IdentityUnavailableReason string              `json:"identity_unavailable_reason,omitempty"`
}

// ValidationMetadata is the measurement-variant-only FR-6 metadata block. All fields
// are advisory except that provider_scalar_verdict is non-authoritative — the
// coordinator derives the verdict itself (FR-7). Present exactly for a measurement
// result; forbidden on a provider_inconclusive result.
type ValidationMetadata struct {
	ProviderMeasuredAt    string   `json:"provider_measured_at"`    // RFC3339 UTC
	ProviderExecutionMs   int64    `json:"provider_execution_ms"`   // non-negative
	ProviderFinalK        int      `json:"provider_final_k"`        // 64 or 256
	ProviderScalarVerdict *float64 `json:"provider_scalar_verdict"` // nullable, advisory
}

// ValidateResultVariant enforces the FR-6 discriminated-union rules: a measurement
// result MUST carry positions + validation_metadata and MUST NOT carry a provider
// reason code; a provider_inconclusive result MUST carry a valid provider_reason_code
// and MUST NOT carry positions or validation_metadata.
func ValidateResultVariant(p ResultPayload) error {
	switch p.ResultKind {
	case ResultKindMeasurement:
		if len(p.Positions) == 0 || p.ValidationMetadata == nil {
			return fmt.Errorf("measurement result must carry positions and validation_metadata")
		}
		if p.ProviderReasonCode != "" {
			return fmt.Errorf("measurement result must not carry provider_reason_code")
		}
		if p.ValidationMetadata.ProviderExecutionMs < 0 ||
			(p.ValidationMetadata.ProviderFinalK != 64 && p.ValidationMetadata.ProviderFinalK != 256) {
			return fmt.Errorf("measurement validation_metadata out of range")
		}
	case ResultKindProviderInconclusive:
		if !ValidProviderReasonCode(p.ProviderReasonCode) {
			return fmt.Errorf("provider_inconclusive result must carry a valid provider_reason_code")
		}
		if len(p.Positions) != 0 || p.ValidationMetadata != nil {
			return fmt.Errorf("provider_inconclusive result must not carry positions/validation_metadata")
		}
	default:
		return fmt.Errorf("unknown result_kind %q", p.ResultKind)
	}
	return nil
}

// ResultEnvelope is the outer probe result envelope (FR-6).
type ResultEnvelope struct {
	Type               string        `json:"type"`
	SchemaVersion      string        `json:"schema_version"`
	Payload            ResultPayload `json:"payload"`
	ProbeRequestDigest string        `json:"probe_request_digest"`
	ProbeResultDigest  string        `json:"probe_result_digest"`
}

// ComputeRequestDigest returns the domain-separated request digest over
// {type, schema_version, payload} (FR-6). The digest field itself is excluded
// because it is not part of the digested object.
func ComputeRequestDigest(env RequestEnvelope) (string, error) {
	return jcsDigest(map[string]any{
		"type":           env.Type,
		"schema_version": env.SchemaVersion,
		"payload":        env.Payload,
	})
}

// ComputeResultDigest returns the domain-separated result digest over
// {type, schema_version, payload} (FR-6).
func ComputeResultDigest(env ResultEnvelope) (string, error) {
	return jcsDigest(map[string]any{
		"type":           env.Type,
		"schema_version": env.SchemaVersion,
		"payload":        env.Payload,
	})
}

// SetRequestDigest computes and stamps the request digest on the envelope.
func (env *RequestEnvelope) SetRequestDigest() error {
	d, err := ComputeRequestDigest(*env)
	if err != nil {
		return err
	}
	env.ProbeRequestDigest = d
	return nil
}

// SetResultDigest computes and stamps the result digest on the envelope.
func (env *ResultEnvelope) SetResultDigest() error {
	d, err := ComputeResultDigest(*env)
	if err != nil {
		return err
	}
	env.ProbeResultDigest = d
	return nil
}

// ValidateRequestBounds enforces the FR-6 request structural bounds (closed key set
// is enforced by the struct shape; this checks the value bounds): k in {64,256}, at
// most 4 distinct prompts and 8 positions, support-selection/normalization/sampler
// constants, one-to-one prompt_id<->prompt_ref, and retry_of_probe_id presence rules.
func ValidateRequestBounds(env RequestEnvelope) error {
	p := env.Payload
	if env.Type != ProbeRequestType || env.SchemaVersion != ProbeRequestSchema ||
		p.SchemaVersion != ProbeRequestSchema {
		return fmt.Errorf("probe request: wrong type/schema_version")
	}
	if p.K != 64 && p.K != 256 {
		return fmt.Errorf("probe request: k must be 64 or 256, got %d", p.K)
	}
	if p.SupportSelection != SupportSelectionV1 {
		return fmt.Errorf("probe request: support_selection must be %q", SupportSelectionV1)
	}
	if p.NormalizationBasis != NormalizationFullDist {
		return fmt.Errorf("probe request: normalization_basis must be %q for v0.1", NormalizationFullDist)
	}
	if p.SamplerStage != SamplerStagePostSampler {
		return fmt.Errorf("probe request: v0.1 enforce sampler_stage must be %q", SamplerStagePostSampler)
	}
	if len(p.Positions) < 1 || len(p.Positions) > MaxPositions {
		return fmt.Errorf("probe request: positions length %d out of [1,%d]", len(p.Positions), MaxPositions)
	}
	prompts := map[string]string{}
	for _, pos := range p.Positions {
		if pos.PromptID == "" || pos.PromptRef == "" {
			return fmt.Errorf("probe request: position missing prompt_id/prompt_ref")
		}
		if pos.PositionIndex < 0 {
			return fmt.Errorf("probe request: negative position_index %d", pos.PositionIndex)
		}
		if ref, ok := prompts[pos.PromptID]; ok {
			if ref != pos.PromptRef {
				return fmt.Errorf("probe request: prompt_id %q maps to two prompt_refs", pos.PromptID)
			}
		} else {
			prompts[pos.PromptID] = pos.PromptRef
		}
		if len(pos.ReferenceTopKSets) == 0 {
			return fmt.Errorf("probe request: position %q missing reference_top_k_sets", pos.PromptID)
		}
	}
	if len(prompts) > MaxDistinctPrompts {
		return fmt.Errorf("probe request: %d distinct prompts exceeds %d", len(prompts), MaxDistinctPrompts)
	}
	// retry_of_probe_id is present EXACTLY for a K=256 retry: every K=256 probe is a
	// mandatory retry of a K=64 attempt (FR-7) and MUST bind it; a K=64 probe MUST NOT
	// carry one.
	if p.K == 64 && p.RetryOfProbeID != "" {
		return fmt.Errorf("probe request: K=64 initial probe must not carry retry_of_probe_id")
	}
	if p.K == 256 && p.RetryOfProbeID == "" {
		return fmt.Errorf("probe request: K=256 retry must carry retry_of_probe_id")
	}
	// Nonce must be a single-use unpredictable value of at least 128 bits (FR-6). We
	// require at least NonceMinHexBytes*2 hex characters (or an equivalently long token).
	if len(p.Nonce) < NonceMinBytes*2 {
		return fmt.Errorf("probe request: nonce too short (need >= %d chars for 128 bits)", NonceMinBytes*2)
	}
	// expires_at must be a parseable RFC3339 timestamp (the <=120s-after-issuance bound
	// is checked by ValidateProbeExpiry, which knows the issuance time).
	if _, err := time.Parse(time.RFC3339, p.ExpiresAt); err != nil {
		return fmt.Errorf("probe request: expires_at not RFC3339: %w", err)
	}
	return nil
}

// ValidateRetryBinding enforces the FR-7 mandatory-retry binding: a K=256 retry MUST
// bind the SAME covered key, corpus positions (prompt/prefix/context and reference
// top-K sets), and target_generation as the K=64 attempt it retries, and echo its
// probe_id. This prevents a provider from substituting easier/different evidence on
// retry after the K=64 trigger.
func ValidateRetryBinding(retry, original RequestEnvelope) error {
	rp, op := retry.Payload, original.Payload
	if rp.K != 256 || op.K != 64 {
		return fmt.Errorf("retry binding: expected K=256 retry of a K=64 attempt")
	}
	if rp.RetryOfProbeID != op.ProbeID {
		return fmt.Errorf("retry binding: retry_of_probe_id does not echo the K=64 probe_id")
	}
	// Covered key must match exactly.
	if rp.ModelID != op.ModelID || rp.TargetModelHash != op.TargetModelHash ||
		rp.TokenizerIdentity != op.TokenizerIdentity || rp.SamplerStage != op.SamplerStage ||
		rp.TargetGeneration != op.TargetGeneration || rp.SamplingProfile != op.SamplingProfile ||
		rp.CorpusVersion != op.CorpusVersion || rp.ThresholdVersion != op.ThresholdVersion ||
		rp.HardwareRuntimeClass != op.HardwareRuntimeClass {
		return fmt.Errorf("retry binding: covered key differs from the K=64 attempt")
	}
	// Position set and per-position binding (including reference top-K) must match.
	if len(rp.Positions) != len(op.Positions) {
		return fmt.Errorf("retry binding: position count differs")
	}
	for i := range rp.Positions {
		a, b := rp.Positions[i], op.Positions[i]
		if a.PromptID != b.PromptID || a.PositionIndex != b.PositionIndex ||
			a.TokenPrefixDigest != b.TokenPrefixDigest || a.ContextHash != b.ContextHash {
			return fmt.Errorf("retry binding: position %d identity differs", i)
		}
		if len(a.ReferenceTopKSets) != len(b.ReferenceTopKSets) {
			return fmt.Errorf("retry binding: position %d reference-set count differs", i)
		}
		for j := range a.ReferenceTopKSets {
			if a.ReferenceTopKSets[j].ReferenceEventDigest != b.ReferenceTopKSets[j].ReferenceEventDigest {
				return fmt.Errorf("retry binding: position %d reference digest differs", i)
			}
		}
	}
	return nil
}

// ValidateProbeExpiry enforces the FR-6 load-bound expiry: the probe MUST expire no
// more than 120 seconds after issuance. issuedAtUnixMS is the coordinator's issuance
// time. It is checked at issuance (the issuer knows both times).
func ValidateProbeExpiry(env RequestEnvelope, issuedAtUnixMS int64) error {
	exp, err := time.Parse(time.RFC3339, env.Payload.ExpiresAt)
	if err != nil {
		return fmt.Errorf("probe expiry: expires_at not RFC3339: %w", err)
	}
	expMs := exp.UnixMilli()
	if expMs <= issuedAtUnixMS {
		return fmt.Errorf("probe expiry: expires_at is not after issuance")
	}
	if expMs-issuedAtUnixMS > int64(ProbeExpirySeconds)*1000 {
		return fmt.Errorf("probe expiry: expires_at more than %ds after issuance", ProbeExpirySeconds)
	}
	return nil
}
