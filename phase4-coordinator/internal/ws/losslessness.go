package ws

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

const (
	LosslessnessProbeVersion = "losslessness_probe_v1"

	losslessnessRequestType                      = "losslessness_probe_v1.request"
	losslessnessResultType                       = "losslessness_probe_v1.result"
	losslessnessEncryptedRequestType             = "losslessness_probe_v1.encrypted_request"
	losslessnessEncryptedResultType              = "losslessness_probe_v1.encrypted_result"
	losslessnessRequestPlaintextType             = "losslessness_probe_v1.request_plaintext"
	losslessnessResultPlaintextType              = "losslessness_probe_v1.result_plaintext"
	losslessnessSamplerStage                     = "post_processors_post_sampling_profile_next_emitted_token"
	losslessnessNormalizationBasis               = "full_distribution"
	losslessnessSupportSelection                 = "support_selection_v1"
	defaultLosslessnessEvidenceTTL               = 30 * 24 * time.Hour
	defaultLosslessnessFreshnessTTL              = 24 * time.Hour
	losslessnessWarnTVUpperThreshold             = 0.02
	losslessnessWarnMedianTVUpperThreshold       = 0.01
	losslessnessQuarantineAnyTVLowerThreshold    = 0.10
	losslessnessQuarantineMedianTVLowerThreshold = 0.05
)

type LosslessnessSamplingProfile struct {
	Temperature float64 `json:"temperature"`
	TopP        float64 `json:"top_p"`
}

type LosslessnessDraftArtifactBinding struct {
	DraftModelID             string `json:"draft_model_id"`
	DraftArtifactSHA256      string `json:"draft_artifact_sha256"`
	TokenizerIdentity        string `json:"tokenizer_identity"`
	CompatibilityCheckDigest string `json:"compatibility_check_digest"`
}

type LosslessnessProfileKey struct {
	ProviderID           string                           `json:"provider_id"`
	AssignedID           string                           `json:"assigned_id"`
	ModelID              string                           `json:"model_id"`
	TargetModelHash      string                           `json:"target_model_hash"`
	TargetGeneration     int                              `json:"target_generation"`
	DraftModelID         string                           `json:"draft_model_id"`
	DraftArtifactBinding LosslessnessDraftArtifactBinding `json:"draft_artifact_binding"`
	DraftGeneration      int                              `json:"draft_generation"`
	SamplingProfile      LosslessnessSamplingProfile      `json:"sampling_profile"`
	CorpusVersion        string                           `json:"corpus_version"`
	ThresholdVersion     string                           `json:"threshold_version"`
}

type LosslessnessGridKey struct {
	ProviderID           string                           `json:"provider_id"`
	AssignedID           string                           `json:"assigned_id"`
	ModelID              string                           `json:"model_id"`
	TargetModelHash      string                           `json:"target_model_hash"`
	TargetGeneration     int                              `json:"target_generation"`
	DraftModelID         string                           `json:"draft_model_id"`
	DraftArtifactBinding LosslessnessDraftArtifactBinding `json:"draft_artifact_binding"`
	DraftGeneration      int                              `json:"draft_generation"`
	CorpusVersion        string                           `json:"corpus_version"`
	ThresholdVersion     string                           `json:"threshold_version"`
}

func (k LosslessnessProfileKey) GridKey() LosslessnessGridKey {
	return LosslessnessGridKey{
		ProviderID:           k.ProviderID,
		AssignedID:           k.AssignedID,
		ModelID:              k.ModelID,
		TargetModelHash:      k.TargetModelHash,
		TargetGeneration:     k.TargetGeneration,
		DraftModelID:         k.DraftModelID,
		DraftArtifactBinding: k.DraftArtifactBinding,
		DraftGeneration:      k.DraftGeneration,
		CorpusVersion:        k.CorpusVersion,
		ThresholdVersion:     k.ThresholdVersion,
	}
}

type LosslessnessProbeOuterEnvelope struct {
	Type               string          `json:"type"`
	ProbeID            string          `json:"probe_id"`
	ProbeRequestDigest string          `json:"probe_request_digest"`
	ProbeResultDigest  string          `json:"probe_result_digest,omitempty"`
	Payload            json.RawMessage `json:"payload"`
}

type LosslessnessProbeRequestPayload struct {
	ProbeVersion           string                                 `json:"probe_version"`
	ProbeID                string                                 `json:"probe_id"`
	ProbeNonce             string                                 `json:"probe_nonce"`
	ExpiresAt              string                                 `json:"expires_at"`
	ModelID                string                                 `json:"model_id"`
	TargetModelHash        string                                 `json:"target_model_hash"`
	TargetGeneration       int                                    `json:"target_generation"`
	DraftModelID           string                                 `json:"draft_model_id"`
	DraftArtifactBinding   LosslessnessDraftArtifactBinding       `json:"draft_artifact_binding"`
	DraftGeneration        int                                    `json:"draft_generation"`
	TokenizerIdentity      string                                 `json:"tokenizer_identity"`
	SamplingProfile        LosslessnessSamplingProfile            `json:"sampling_profile"`
	CorpusVersion          string                                 `json:"corpus_version"`
	ThresholdVersion       string                                 `json:"threshold_version"`
	Prompts                []LosslessnessPromptPayload            `json:"prompts"`
	MeasurementPositions   []int                                  `json:"measurement_positions"`
	RequestedK             int                                    `json:"requested_k"`
	SupportSelection       string                                 `json:"support_selection"`
	MaxPrompts             int                                    `json:"max_prompts"`
	MaxStochasticPositions int                                    `json:"max_stochastic_positions"`
	TimeoutMS              int                                    `json:"timeout_ms"`
	VocabSize              int                                    `json:"-"`
	PositionContextHashes  map[int]string                         `json:"-"`
	HighEntropyPositions   map[int]bool                           `json:"-"`
	OfflinePlainSupport    map[int][]LosslessnessTokenProbability `json:"-"`
}

type LosslessnessPromptPayload struct {
	PromptID              string          `json:"prompt_id"`
	Prompt                string          `json:"prompt"`
	CoordinatorOwned      bool            `json:"coordinator_owned"`
	BuyerOrigin           bool            `json:"buyer_origin"`
	OfflinePositionRecord map[int]float64 `json:"-"`
}

type LosslessnessProbeResultPayload struct {
	ProbeID              string                             `json:"probe_id"`
	ProbeNonce           string                             `json:"probe_nonce"`
	ProbeRequestDigest   string                             `json:"probe_request_digest"`
	ResultKind           string                             `json:"result_kind"`
	TargetModelHash      string                             `json:"target_model_hash,omitempty"`
	TargetGeneration     int                                `json:"target_generation,omitempty"`
	DraftArtifactBinding *LosslessnessDraftArtifactBinding  `json:"draft_artifact_binding,omitempty"`
	DraftGeneration      int                                `json:"draft_generation,omitempty"`
	TokenizerIdentity    string                             `json:"tokenizer_identity,omitempty"`
	Positions            []LosslessnessPositionDistribution `json:"positions,omitempty"`
	ProviderReasonCode   string                             `json:"provider_reason_code,omitempty"`
	IdentityUnavailable  string                             `json:"identity_unavailable_reason,omitempty"`
}

type LosslessnessPositionDistribution struct {
	PositionIndex        int                              `json:"position_index"`
	ContextHash          string                           `json:"context_hash"`
	SupportSelection     string                           `json:"support_selection"`
	PlainTopKTokenIDs    []int                            `json:"plain_top_k_token_ids"`
	SpecTopKTokenIDs     []int                            `json:"spec_top_k_token_ids"`
	SupportTokenIDs      []int                            `json:"support_token_ids"`
	PlainSupport         []LosslessnessTokenProbability   `json:"plain_support"`
	PlainTailMass        float64                          `json:"plain_tail_mass"`
	SpecSupport          []LosslessnessTokenProbability   `json:"spec_support"`
	SpecTailMass         float64                          `json:"spec_tail_mass"`
	TargetModelHash      string                           `json:"target_model_hash"`
	TargetGeneration     int                              `json:"target_generation"`
	DraftArtifactBinding LosslessnessDraftArtifactBinding `json:"draft_artifact_binding"`
	DraftGeneration      int                              `json:"draft_generation"`
	TokenizerIdentity    string                           `json:"tokenizer_identity"`
	NormalizationBasis   string                           `json:"normalization_basis"`
	SamplerStage         string                           `json:"sampler_stage"`
	HighEntropy          bool                             `json:"high_entropy"`
	OfflinePlainSupport  []LosslessnessTokenProbability   `json:"-"`
}

type LosslessnessTokenProbability struct {
	TokenID int     `json:"token_id"`
	P       float64 `json:"p"`
}

type LosslessnessTVInterval struct {
	Lower float64
	Upper float64
}

type LosslessnessValidationResult struct {
	ReasonCode string
	Retryable  bool
}

type LosslessnessExpectedPositionIdentity struct {
	TargetModelHash      string
	TargetGeneration     int
	DraftArtifactBinding LosslessnessDraftArtifactBinding
	DraftGeneration      int
}

var (
	errLosslessnessMalformed       = errors.New("inconclusive:malformed_distribution")
	errLosslessnessRekeyInProgress = errors.New("losslessness probe suspended during tier2 rekey")
)

type losslessnessPendingProbe struct {
	ProviderID          string
	AssignedID          string
	ProbeID             string
	ProbeNonce          string
	ProbeRequestDigest  string
	ExpiresAt           time.Time
	ProfileKey          LosslessnessProfileKey
	RequestedK          int
	VocabSize           int
	TokenizerIdentity   string
	ExpectedIdentity    LosslessnessExpectedPositionIdentity
	RequestedPositions  map[int]struct{}
	ExpectedContextHash map[int]string
	HighEntropyPosition map[int]bool
	OfflinePlainSupport map[int][]LosslessnessTokenProbability
}

type losslessnessDraftAdmissionKey struct {
	ProviderID string
	AssignedID string
	ModelID    string
}

type LosslessnessDraftAdmissionRecord struct {
	ProviderID           string
	AssignedID           string
	ModelID              string
	TargetModelHash      string
	TargetGeneration     int
	DraftModelID         string
	DraftArtifactBinding LosslessnessDraftArtifactBinding
	DraftGeneration      int
	TokenizerIdentity    string
	ExpiresAt            time.Time
}

type LosslessnessTelemetryEvent struct {
	EventSubtype   string
	ProviderID     string
	AssignedID     string
	ProbeID        string
	ResultKind     string
	ReasonCode     string
	ProfileState   LosslessnessStatus
	OperatorAction LosslessnessOperatorAction
	MeasuredAt     time.Time
}

func LosslessnessDigest(rawPayload json.RawMessage) (string, error) {
	canonical, err := canonicalizeJSON(rawPayload)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canonical)
	return "sha256:" + hex.EncodeToString(sum[:]), nil
}

func ValidateLosslessnessEnvelope(raw []byte, wantType string) (LosslessnessProbeOuterEnvelope, error) {
	var env LosslessnessProbeOuterEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return env, err
	}
	if env.Type != wantType {
		return env, fmt.Errorf("losslessness envelope type %q, want %q", env.Type, wantType)
	}
	if strings.TrimSpace(env.ProbeID) == "" || len(env.Payload) == 0 {
		return env, errors.New("losslessness envelope requires probe_id and payload")
	}
	digest, err := LosslessnessDigest(env.Payload)
	if err != nil {
		return env, err
	}
	switch wantType {
	case losslessnessRequestType:
		if env.ProbeRequestDigest != digest {
			return env, fmt.Errorf("probe_request_digest mismatch")
		}
		if err := validateLosslessnessPayloadBinding(env, false); err != nil {
			return env, err
		}
	case losslessnessResultType:
		if env.ProbeRequestDigest == "" {
			return env, fmt.Errorf("probe_request_digest required")
		}
		if env.ProbeResultDigest != digest {
			return env, fmt.Errorf("probe_result_digest mismatch")
		}
		if err := validateLosslessnessPayloadBinding(env, true); err != nil {
			return env, err
		}
	}
	return env, nil
}

func ValidateLosslessnessResultPayload(raw json.RawMessage) (LosslessnessProbeResultPayload, error) {
	var result LosslessnessProbeResultPayload
	if err := json.Unmarshal(raw, &result); err != nil {
		return result, err
	}
	if result.ProbeID == "" || result.ProbeNonce == "" || result.ProbeRequestDigest == "" {
		return result, errors.New("losslessness result missing replay fields")
	}
	switch result.ResultKind {
	case "measurement":
		if result.TargetModelHash == "" || result.TargetGeneration <= 0 ||
			result.DraftArtifactBinding == nil || result.DraftGeneration <= 0 ||
			result.TokenizerIdentity == "" || len(result.Positions) == 0 {
			return result, errors.New("losslessness measurement result missing identity or positions")
		}
	case "provider_inconclusive":
		if !losslessnessProviderReasonAllowed(result.ProviderReasonCode) {
			return result, errors.New("losslessness provider_inconclusive missing allowed reason or identity_unavailable_reason")
		}
		if len(result.Positions) > 0 {
			return result, errors.New("losslessness provider_inconclusive must not carry measurement positions")
		}
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(raw, &fields); err != nil {
			return result, err
		}
		identityKnown := result.TargetModelHash != "" && result.TargetGeneration > 0 &&
			result.DraftArtifactBinding != nil && result.DraftGeneration > 0
		identityUnavailable := result.IdentityUnavailable != "" &&
			jsonFieldIsNull(fields, "target_model_hash") &&
			jsonFieldIsNull(fields, "target_generation") &&
			jsonFieldIsNull(fields, "draft_artifact_binding") &&
			jsonFieldIsNull(fields, "draft_generation")
		if !identityKnown && !identityUnavailable {
			return result, errors.New("losslessness provider_inconclusive requires known identity or explicit null identity fields with identity_unavailable_reason")
		}
	default:
		return result, fmt.Errorf("unsupported losslessness result_kind %q", result.ResultKind)
	}
	return result, nil
}

func jsonFieldIsNull(fields map[string]json.RawMessage, key string) bool {
	value, ok := fields[key]
	return ok && bytes.Equal(bytes.TrimSpace(value), []byte("null"))
}

func losslessnessProviderReasonAllowed(reason string) bool {
	switch reason {
	case "inconclusive:model_swap",
		"inconclusive:unsupported_sampler",
		"inconclusive:draft_unavailable",
		"inconclusive:position_mismatch",
		"inconclusive:missing_distribution",
		"inconclusive:timeout":
		return true
	default:
		return false
	}
}

func validateLosslessnessPayloadBinding(env LosslessnessProbeOuterEnvelope, result bool) error {
	var payload struct {
		ProbeID            string `json:"probe_id"`
		ProbeRequestDigest string `json:"probe_request_digest"`
	}
	if err := json.Unmarshal(env.Payload, &payload); err != nil {
		return err
	}
	if payload.ProbeID == "" || payload.ProbeID != env.ProbeID {
		return fmt.Errorf("losslessness payload probe_id mismatch")
	}
	if result && payload.ProbeRequestDigest != env.ProbeRequestDigest {
		return fmt.Errorf("losslessness payload probe_request_digest mismatch")
	}
	return nil
}

func ComputeTVInterval(pos LosslessnessPositionDistribution) (LosslessnessTVInterval, error) {
	plain, err := probabilityMap(pos.PlainSupport)
	if err != nil {
		return LosslessnessTVInterval{}, err
	}
	spec, err := probabilityMap(pos.SpecSupport)
	if err != nil {
		return LosslessnessTVInterval{}, err
	}
	var diff float64
	for _, id := range pos.SupportTokenIDs {
		pPlain, ok := plain[id]
		if !ok {
			return LosslessnessTVInterval{}, fmt.Errorf("%w: missing plain support token %d", errLosslessnessMalformed, id)
		}
		pSpec, ok := spec[id]
		if !ok {
			return LosslessnessTVInterval{}, fmt.Errorf("%w: missing spec support token %d", errLosslessnessMalformed, id)
		}
		diff += math.Abs(pPlain - pSpec)
	}
	return LosslessnessTVInterval{
		Lower: 0.5 * (diff + math.Abs(pos.PlainTailMass-pos.SpecTailMass)),
		Upper: 0.5 * (diff + pos.PlainTailMass + pos.SpecTailMass),
	}, nil
}

func ValidateLosslessnessDistribution(pos LosslessnessPositionDistribution, k, vocabSize int, expectedTokenizer, expectedContextHash string, expectedIdentity *LosslessnessExpectedPositionIdentity, expectedHighEntropy bool, offlinePlainSupport []LosslessnessTokenProbability) LosslessnessValidationResult {
	if k != 64 && k != 256 {
		return malformedResult()
	}
	if pos.SupportSelection != losslessnessSupportSelection ||
		pos.NormalizationBasis != losslessnessNormalizationBasis ||
		pos.SamplerStage != losslessnessSamplerStage {
		return malformedResult()
	}
	if expectedTokenizer != "" && pos.TokenizerIdentity != expectedTokenizer {
		return malformedResult()
	}
	if expectedContextHash != "" && pos.ContextHash != expectedContextHash {
		return malformedResult()
	}
	if expectedIdentity != nil && !losslessnessIdentityMatches(pos, *expectedIdentity) {
		return LosslessnessValidationResult{ReasonCode: "inconclusive:identity_mismatch", Retryable: false}
	}
	if !validMass(pos.PlainTailMass) || !validMass(pos.SpecTailMass) {
		return malformedResult()
	}
	if !topKSorted(pos.PlainTopKTokenIDs, pos.PlainSupport, k, vocabSize) ||
		!topKSorted(pos.SpecTopKTokenIDs, pos.SpecSupport, k, vocabSize) {
		return malformedResult()
	}
	union := numericUnion(pos.PlainTopKTokenIDs, pos.SpecTopKTokenIDs)
	if !sameInts(union, pos.SupportTokenIDs) {
		return malformedResult()
	}
	minSupport := k
	if vocabSize > 0 && vocabSize < k {
		minSupport = vocabSize
	}
	if len(pos.SupportTokenIDs) < minSupport || len(pos.SupportTokenIDs) > 2*k {
		return malformedResult()
	}
	plain, err := probabilityMap(pos.PlainSupport)
	if err != nil {
		return malformedResult()
	}
	spec, err := probabilityMap(pos.SpecSupport)
	if err != nil {
		return malformedResult()
	}
	if len(plain) != len(pos.SupportTokenIDs) || len(spec) != len(pos.SupportTokenIDs) {
		return malformedResult()
	}
	var plainSum, specSum float64
	seen := map[int]struct{}{}
	for _, id := range pos.SupportTokenIDs {
		if id < 0 || (vocabSize > 0 && id >= vocabSize) {
			return malformedResult()
		}
		if _, ok := seen[id]; ok {
			return malformedResult()
		}
		seen[id] = struct{}{}
		p, ok := plain[id]
		if !ok {
			return malformedResult()
		}
		plainSum += p
		p, ok = spec[id]
		if !ok {
			return malformedResult()
		}
		specSum += p
	}
	if math.Abs(plainSum+pos.PlainTailMass-1.0) > 1e-5 || math.Abs(specSum+pos.SpecTailMass-1.0) > 1e-5 {
		return malformedResult()
	}
	if k == 256 && (pos.PlainTailMass > 0.005 || pos.SpecTailMass > 0.005) {
		return LosslessnessValidationResult{ReasonCode: "inconclusive:tail_mass_high", Retryable: true}
	}
	if expectedHighEntropy && vocabSize > 0 && len(pos.SupportTokenIDs) < vocabSize {
		if len(offlinePlainSupport) == 0 {
			return malformedResult()
		}
		offline, err := probabilityMap(offlinePlainSupport)
		if err != nil {
			return malformedResult()
		}
		var offlineSupport float64
		for _, id := range pos.SupportTokenIDs {
			offlineSupport += offline[id]
		}
		if pos.PlainTailMass < 1-offlineSupport-1e-5 {
			return malformedResult()
		}
	}
	return LosslessnessValidationResult{ReasonCode: "valid", Retryable: false}
}

func losslessnessIdentityMatches(pos LosslessnessPositionDistribution, expected LosslessnessExpectedPositionIdentity) bool {
	return pos.TargetModelHash == expected.TargetModelHash &&
		pos.TargetGeneration == expected.TargetGeneration &&
		pos.DraftArtifactBinding == expected.DraftArtifactBinding &&
		pos.DraftGeneration == expected.DraftGeneration
}

func LosslessnessRequiresK256Retry(k int, plainTailMass, specTailMass, tvLower, tvUpper, warnThreshold, quarantineThreshold float64) bool {
	if k != 64 {
		return false
	}
	if plainTailMass > 0.01 || specTailMass > 0.01 {
		return true
	}
	if tvUpper >= warnThreshold {
		return true
	}
	return math.Abs(tvLower-quarantineThreshold) <= 0.005
}

func malformedResult() LosslessnessValidationResult {
	return LosslessnessValidationResult{ReasonCode: "inconclusive:malformed_distribution", Retryable: false}
}

type LosslessnessStatus string

const (
	LosslessnessStatusPassFresh             LosslessnessStatus = "pass_fresh"
	LosslessnessStatusWarn                  LosslessnessStatus = "warn"
	LosslessnessStatusInconclusiveRetryable LosslessnessStatus = "inconclusive_retryable"
	LosslessnessStatusBlocked               LosslessnessStatus = "blocked"
	LosslessnessStatusDisabled              LosslessnessStatus = "disabled"
	LosslessnessStatusExpired               LosslessnessStatus = "expired"
	LosslessnessStatusUnknown               LosslessnessStatus = "unknown"
)

type LosslessnessOperatorAction string

const (
	LosslessnessActionNone                       LosslessnessOperatorAction = "none"
	LosslessnessActionInspectThresholdTrend      LosslessnessOperatorAction = "inspect_threshold_trend"
	LosslessnessActionInspectProviderDraft       LosslessnessOperatorAction = "inspect_provider_draft"
	LosslessnessActionApproveCalibrationBaseline LosslessnessOperatorAction = "approve_calibration_baseline"
	LosslessnessActionDisableSpecDecodeKey       LosslessnessOperatorAction = "disable_spec_decode_key"
	LosslessnessActionRetryProbeWithBackoff      LosslessnessOperatorAction = "retry_probe_with_backoff"
	LosslessnessActionInspectProviderLoad        LosslessnessOperatorAction = "inspect_provider_load"
	LosslessnessActionDisableSamplerProfile      LosslessnessOperatorAction = "disable_sampler_profile"
	LosslessnessActionWaitReadySnapshotReprobe   LosslessnessOperatorAction = "wait_ready_snapshot_reprobe"
	LosslessnessActionReloadOrDisableDraft       LosslessnessOperatorAction = "reload_or_disable_draft"
	LosslessnessActionCreateDraftAdmissionRecord LosslessnessOperatorAction = "create_draft_admission_record"
	LosslessnessActionInspectGenerationMismatch  LosslessnessOperatorAction = "inspect_generation_mismatch"
	LosslessnessActionInspectControlReplay       LosslessnessOperatorAction = "inspect_control_channel_replay"
	LosslessnessActionFixProviderSerializer      LosslessnessOperatorAction = "fix_provider_serializer"
	LosslessnessActionFixPositionHandling        LosslessnessOperatorAction = "fix_position_handling"
	LosslessnessActionFixResultCompleteness      LosslessnessOperatorAction = "fix_result_completeness"
	LosslessnessActionRequestSpec028Approval     LosslessnessOperatorAction = "request_spec028_rollout_approval"
	LosslessnessActionDisableStochasticSpec      LosslessnessOperatorAction = "disable_stochastic_spec_decode"
)

type LosslessnessReasonRule struct {
	ReasonCode     string
	Status         string
	Retryable      bool
	NextState      LosslessnessStatus
	OperatorAction LosslessnessOperatorAction
	Abusive        bool
}

var losslessnessReasonRules = map[string]LosslessnessReasonRule{
	"pass:fresh":                             {"pass:fresh", "pass", false, LosslessnessStatusPassFresh, LosslessnessActionNone, false},
	"warn:threshold_exceeded":                {"warn:threshold_exceeded", "warn", true, LosslessnessStatusWarn, LosslessnessActionInspectThresholdTrend, false},
	"quarantine_candidate:tv_lower_exceeded": {"quarantine_candidate:tv_lower_exceeded", "quarantine_candidate", true, LosslessnessStatusWarn, LosslessnessActionInspectProviderDraft, false},
	"blocked:calibration_missing":            {"blocked:calibration_missing", "blocked", false, LosslessnessStatusBlocked, LosslessnessActionApproveCalibrationBaseline, false},
	"blocked:greedy_control_failed":          {"blocked:greedy_control_failed", "blocked", false, LosslessnessStatusBlocked, LosslessnessActionDisableSpecDecodeKey, false},
	"inconclusive:tail_mass_high":            {"inconclusive:tail_mass_high", "inconclusive", true, LosslessnessStatusInconclusiveRetryable, LosslessnessActionRetryProbeWithBackoff, false},
	"inconclusive:k_retry_failed":            {"inconclusive:k_retry_failed", "inconclusive", true, LosslessnessStatusInconclusiveRetryable, LosslessnessActionInspectProviderLoad, true},
	"inconclusive:timeout":                   {"inconclusive:timeout", "inconclusive", true, LosslessnessStatusInconclusiveRetryable, LosslessnessActionInspectProviderLoad, true},
	"inconclusive:unsupported_sampler":       {"inconclusive:unsupported_sampler", "inconclusive", false, LosslessnessStatusBlocked, LosslessnessActionDisableSamplerProfile, true},
	"inconclusive:model_swap":                {"inconclusive:model_swap", "inconclusive", true, LosslessnessStatusExpired, LosslessnessActionWaitReadySnapshotReprobe, false},
	"inconclusive:draft_unavailable":         {"inconclusive:draft_unavailable", "inconclusive", true, LosslessnessStatusInconclusiveRetryable, LosslessnessActionReloadOrDisableDraft, true},
	"inconclusive:draft_identity_unbound":    {"inconclusive:draft_identity_unbound", "inconclusive", false, LosslessnessStatusBlocked, LosslessnessActionCreateDraftAdmissionRecord, true},
	"inconclusive:identity_mismatch":         {"inconclusive:identity_mismatch", "inconclusive", false, LosslessnessStatusBlocked, LosslessnessActionInspectGenerationMismatch, true},
	"inconclusive:replay_or_expired":         {"inconclusive:replay_or_expired", "inconclusive", false, LosslessnessStatusBlocked, LosslessnessActionInspectControlReplay, true},
	"inconclusive:malformed_distribution":    {"inconclusive:malformed_distribution", "inconclusive", false, LosslessnessStatusBlocked, LosslessnessActionFixProviderSerializer, true},
	"inconclusive:position_mismatch":         {"inconclusive:position_mismatch", "inconclusive", false, LosslessnessStatusBlocked, LosslessnessActionFixPositionHandling, true},
	"inconclusive:missing_distribution":      {"inconclusive:missing_distribution", "inconclusive", false, LosslessnessStatusBlocked, LosslessnessActionFixResultCompleteness, true},
}

type LosslessnessProfileRecord struct {
	Key                         LosslessnessProfileKey
	State                       LosslessnessStatus
	ReasonCode                  string
	Retryable                   bool
	OperatorAction              LosslessnessOperatorAction
	MeasuredAt                  time.Time
	StaleAfter                  time.Time
	VerdictEngineReady          bool
	CalibrationAccepted         bool
	ConsecutiveQuarantine       int
	AbusiveInconclusiveEvents   []time.Time
	RetryableInconclusiveEvents []LosslessnessReasonEvent
	GreedyControlFailureCount   int
}

type LosslessnessReasonEvent struct {
	ReasonCode string
	MeasuredAt time.Time
}

func ApplyLosslessnessReason(record LosslessnessProfileRecord, reasonCode string, measuredAt time.Time) (LosslessnessProfileRecord, error) {
	rule, ok := losslessnessReasonRules[reasonCode]
	if !ok {
		return record, fmt.Errorf("unknown losslessness reason_code %q", reasonCode)
	}
	record.ReasonCode = reasonCode
	record.Retryable = rule.Retryable
	record.OperatorAction = rule.OperatorAction
	record.MeasuredAt = measuredAt.UTC()
	record.StaleAfter = record.MeasuredAt.Add(defaultLosslessnessFreshnessTTL)
	switch reasonCode {
	case "pass:fresh":
		if !record.VerdictEngineReady || !record.CalibrationAccepted {
			return record, errors.New("losslessness pass requires verdict engine and accepted calibration baseline")
		}
		record.ConsecutiveQuarantine = 0
		record.AbusiveInconclusiveEvents = pruneAbuseEvents(record.AbusiveInconclusiveEvents, measuredAt)
		if len(record.AbusiveInconclusiveEvents) >= 3 {
			record.State = LosslessnessStatusBlocked
			record.OperatorAction = LosslessnessActionDisableSamplerProfile
		} else {
			record.State = LosslessnessStatusPassFresh
		}
	case "warn:threshold_exceeded":
		record.State = LosslessnessStatusWarn
	case "quarantine_candidate:tv_lower_exceeded":
		if !record.CalibrationAccepted {
			record.ReasonCode = "blocked:calibration_missing"
			record.Retryable = false
			record.State = LosslessnessStatusBlocked
			record.OperatorAction = LosslessnessActionApproveCalibrationBaseline
			return record, nil
		}
		record.ConsecutiveQuarantine++
		if record.ConsecutiveQuarantine >= 2 {
			record.State = LosslessnessStatusDisabled
			record.OperatorAction = LosslessnessActionDisableSpecDecodeKey
		} else {
			record.State = LosslessnessStatusWarn
		}
	case "blocked:greedy_control_failed":
		record.GreedyControlFailureCount++
		record.State = LosslessnessStatusBlocked
	default:
		repeatedAbusive := repeatedRetryableInconclusiveIsAbusive(record, reasonCode, measuredAt)
		if reasonCode == "inconclusive:tail_mass_high" || reasonCode == "inconclusive:model_swap" {
			record.RetryableInconclusiveEvents = appendRetryableInconclusiveEvent(record.RetryableInconclusiveEvents, reasonCode, measuredAt)
		}
		if rule.Abusive || repeatedAbusive {
			record.AbusiveInconclusiveEvents = appendAbuseEvent(record.AbusiveInconclusiveEvents, measuredAt)
			if len(record.AbusiveInconclusiveEvents) >= 3 {
				record.State = LosslessnessStatusBlocked
				break
			}
		}
		record.State = rule.NextState
	}
	return record, nil
}

func repeatedRetryableInconclusiveIsAbusive(record LosslessnessProfileRecord, reasonCode string, measuredAt time.Time) bool {
	if reasonCode != "inconclusive:tail_mass_high" && reasonCode != "inconclusive:model_swap" {
		return false
	}
	cutoff := measuredAt.Add(-24 * time.Hour)
	count := 1
	for _, event := range record.RetryableInconclusiveEvents {
		if event.ReasonCode == reasonCode && !event.MeasuredAt.Before(cutoff) {
			count++
		}
	}
	return count > 3
}

func appendRetryableInconclusiveEvent(events []LosslessnessReasonEvent, reasonCode string, measuredAt time.Time) []LosslessnessReasonEvent {
	cutoff := measuredAt.Add(-24 * time.Hour)
	out := events[:0]
	for _, event := range events {
		if !event.MeasuredAt.Before(cutoff) {
			out = append(out, event)
		}
	}
	return append(out, LosslessnessReasonEvent{ReasonCode: reasonCode, MeasuredAt: measuredAt.UTC()})
}

func appendAbuseEvent(events []time.Time, measuredAt time.Time) []time.Time {
	return append(pruneAbuseEvents(events, measuredAt), measuredAt.UTC())
}

func pruneAbuseEvents(events []time.Time, measuredAt time.Time) []time.Time {
	cutoff := measuredAt.Add(-24 * time.Hour)
	out := events[:0]
	for _, event := range events {
		if !event.Before(cutoff) {
			out = append(out, event)
		}
	}
	return out
}

func LosslessnessGridState(records []LosslessnessProfileRecord, grid LosslessnessGridKey, required []LosslessnessSamplingProfile, now time.Time) string {
	fresh := map[LosslessnessSamplingProfile]bool{}
	for _, record := range records {
		if record.Key.GridKey() == grid &&
			record.State == LosslessnessStatusPassFresh &&
			record.VerdictEngineReady &&
			record.CalibrationAccepted &&
			now.Before(record.StaleAfter) {
			fresh[record.Key.SamplingProfile] = true
		}
	}
	for _, profile := range required {
		if !fresh[profile] {
			return "not_ready"
		}
	}
	return "all_profiles_fresh"
}

func LosslessnessDefaultProfiles() []LosslessnessSamplingProfile {
	return []LosslessnessSamplingProfile{
		{Temperature: 0.2, TopP: 1.0},
		{Temperature: 0.5, TopP: 1.0},
		{Temperature: 0.7, TopP: 1.0},
		{Temperature: 1.0, TopP: 1.0},
		{Temperature: 0.0, TopP: 1.0},
	}
}

func ValidateLosslessnessCorpusPrompt(prompt LosslessnessPromptPayload) error {
	if strings.TrimSpace(prompt.PromptID) == "" {
		return errors.New("prompt_id required")
	}
	if !prompt.CoordinatorOwned || prompt.BuyerOrigin {
		return errors.New("losslessness corpus prompts must be synthetic coordinator-owned material")
	}
	if strings.TrimSpace(prompt.Prompt) == "" {
		return errors.New("prompt must not be empty")
	}
	return nil
}

func losslessnessProbeStoreKey(providerID, assignedID, probeID string) string {
	return providerID + "\x00" + assignedID + "\x00" + probeID
}

func (s *Server) recordLosslessnessPendingProbe(providerID, assignedID string, payload LosslessnessProbeRequestPayload, requestDigest string, now time.Time) (losslessnessPendingProbe, error) {
	expiresAt, err := time.Parse(time.RFC3339Nano, payload.ExpiresAt)
	if err != nil {
		return losslessnessPendingProbe{}, err
	}
	pending := losslessnessPendingProbe{
		ProviderID:         providerID,
		AssignedID:         assignedID,
		ProbeID:            payload.ProbeID,
		ProbeNonce:         payload.ProbeNonce,
		ProbeRequestDigest: requestDigest,
		ExpiresAt:          expiresAt.UTC(),
		ProfileKey: LosslessnessProfileKey{
			ProviderID:           providerID,
			AssignedID:           assignedID,
			ModelID:              payload.ModelID,
			TargetModelHash:      payload.TargetModelHash,
			TargetGeneration:     payload.TargetGeneration,
			DraftModelID:         payload.DraftModelID,
			DraftArtifactBinding: payload.DraftArtifactBinding,
			DraftGeneration:      payload.DraftGeneration,
			SamplingProfile:      payload.SamplingProfile,
			CorpusVersion:        payload.CorpusVersion,
			ThresholdVersion:     payload.ThresholdVersion,
		},
		RequestedK:        payload.RequestedK,
		VocabSize:         payload.VocabSize,
		TokenizerIdentity: payload.TokenizerIdentity,
		ExpectedIdentity: LosslessnessExpectedPositionIdentity{
			TargetModelHash:      payload.TargetModelHash,
			TargetGeneration:     payload.TargetGeneration,
			DraftArtifactBinding: payload.DraftArtifactBinding,
			DraftGeneration:      payload.DraftGeneration,
		},
		RequestedPositions:  map[int]struct{}{},
		ExpectedContextHash: map[int]string{},
		HighEntropyPosition: map[int]bool{},
		OfflinePlainSupport: map[int][]LosslessnessTokenProbability{},
	}
	for _, position := range payload.MeasurementPositions {
		pending.RequestedPositions[position] = struct{}{}
	}
	for position, hash := range payload.PositionContextHashes {
		pending.ExpectedContextHash[position] = hash
	}
	for position, highEntropy := range payload.HighEntropyPositions {
		pending.HighEntropyPosition[position] = highEntropy
	}
	for position, support := range payload.OfflinePlainSupport {
		pending.OfflinePlainSupport[position] = append([]LosslessnessTokenProbability(nil), support...)
		if pending.VocabSize == 0 {
			for _, token := range support {
				if token.TokenID >= pending.VocabSize {
					pending.VocabSize = token.TokenID + 1
				}
			}
		}
	}
	storeKey := losslessnessProbeStoreKey(providerID, assignedID, payload.ProbeID)
	if _, loaded := s.losslessnessPending.LoadOrStore(storeKey, pending); loaded {
		return losslessnessPendingProbe{}, errors.New("duplicate losslessness probe_id")
	}
	nonceKey := losslessnessProbeStoreKey(providerID, assignedID, payload.ProbeNonce)
	if _, loaded := s.losslessnessNonceIndex.LoadOrStore(nonceKey, storeKey); loaded {
		s.losslessnessPending.Delete(storeKey)
		return losslessnessPendingProbe{}, errors.New("duplicate losslessness probe nonce")
	}
	digestKey := losslessnessProbeStoreKey(providerID, assignedID, requestDigest)
	if _, loaded := s.losslessnessDigestIndex.LoadOrStore(digestKey, storeKey); loaded {
		s.losslessnessPending.Delete(storeKey)
		s.losslessnessNonceIndex.Delete(nonceKey)
		return losslessnessPendingProbe{}, errors.New("duplicate losslessness probe request digest")
	}
	return pending, nil
}

func (s *Server) deleteLosslessnessPendingIndexes(pending losslessnessPendingProbe) {
	s.losslessnessNonceIndex.Delete(losslessnessProbeStoreKey(pending.ProviderID, pending.AssignedID, pending.ProbeNonce))
	s.losslessnessDigestIndex.Delete(losslessnessProbeStoreKey(pending.ProviderID, pending.AssignedID, pending.ProbeRequestDigest))
}

func (s *Server) consumeLosslessnessPendingProbe(providerID, assignedID string, result LosslessnessProbeResultPayload, now time.Time) (losslessnessPendingProbe, error) {
	key := losslessnessProbeStoreKey(providerID, assignedID, result.ProbeID)
	value, ok := s.losslessnessPending.LoadAndDelete(key)
	if !ok {
		return losslessnessPendingProbe{}, errors.New("losslessness result has no pending probe")
	}
	pending, ok := value.(losslessnessPendingProbe)
	if !ok {
		return losslessnessPendingProbe{}, errors.New("losslessness pending probe has invalid store type")
	}
	if now.After(pending.ExpiresAt) {
		s.deleteLosslessnessPendingIndexes(pending)
		return pending, errors.New("losslessness result probe expired")
	}
	if result.ProbeNonce != pending.ProbeNonce || result.ProbeRequestDigest != pending.ProbeRequestDigest {
		s.deleteLosslessnessPendingIndexes(pending)
		return pending, errors.New("losslessness result replay fields mismatch")
	}
	s.deleteLosslessnessPendingIndexes(pending)
	return pending, nil
}

func (s *Server) applyLosslessnessProfileReason(key LosslessnessProfileKey, reasonCode string, measuredAt time.Time) (LosslessnessProfileRecord, error) {
	s.losslessnessProfilesMu.Lock()
	defer s.losslessnessProfilesMu.Unlock()
	record := s.losslessnessProfiles[key]
	record.Key = key
	next, err := ApplyLosslessnessReason(record, reasonCode, measuredAt)
	if err != nil {
		return next, err
	}
	s.losslessnessProfiles[key] = next
	return next, nil
}

func (s *Server) losslessnessProfileSnapshot(key LosslessnessProfileKey) (LosslessnessProfileRecord, bool) {
	s.losslessnessProfilesMu.Lock()
	defer s.losslessnessProfilesMu.Unlock()
	record, ok := s.losslessnessProfiles[key]
	return record, ok
}

func losslessnessReasonForMeasurement(result LosslessnessProbeResultPayload, pending losslessnessPendingProbe) string {
	if result.TargetModelHash != pending.ExpectedIdentity.TargetModelHash ||
		result.TargetGeneration != pending.ExpectedIdentity.TargetGeneration ||
		result.DraftArtifactBinding == nil ||
		*result.DraftArtifactBinding != pending.ExpectedIdentity.DraftArtifactBinding ||
		result.DraftGeneration != pending.ExpectedIdentity.DraftGeneration ||
		result.TokenizerIdentity != pending.TokenizerIdentity {
		return "inconclusive:identity_mismatch"
	}
	if len(result.Positions) == 0 {
		return "inconclusive:missing_distribution"
	}
	if len(pending.RequestedPositions) == 0 || len(result.Positions) != len(pending.RequestedPositions) {
		return "inconclusive:position_mismatch"
	}
	if pending.VocabSize <= 0 {
		return "inconclusive:malformed_distribution"
	}
	var tvLowerValues []float64
	var tvUpperValues []float64
	anyUpperWarn := false
	anyLowerQuarantine := false
	seenPositions := map[int]struct{}{}
	for _, pos := range result.Positions {
		if _, ok := pending.RequestedPositions[pos.PositionIndex]; !ok {
			return "inconclusive:position_mismatch"
		}
		if _, ok := seenPositions[pos.PositionIndex]; ok {
			return "inconclusive:position_mismatch"
		}
		seenPositions[pos.PositionIndex] = struct{}{}
		expectedContextHash, ok := pending.ExpectedContextHash[pos.PositionIndex]
		if !ok || expectedContextHash == "" {
			return "inconclusive:malformed_distribution"
		}
		offlinePlainSupport := pending.OfflinePlainSupport[pos.PositionIndex]
		if len(offlinePlainSupport) == 0 {
			return "inconclusive:malformed_distribution"
		}
		validation := ValidateLosslessnessDistribution(
			pos,
			pending.RequestedK,
			pending.VocabSize,
			pending.TokenizerIdentity,
			expectedContextHash,
			&pending.ExpectedIdentity,
			pending.HighEntropyPosition[pos.PositionIndex],
			offlinePlainSupport,
		)
		if validation.ReasonCode != "valid" {
			return validation.ReasonCode
		}
		tv, err := ComputeTVInterval(pos)
		if err != nil {
			return "inconclusive:malformed_distribution"
		}
		if LosslessnessRequiresK256Retry(
			pending.RequestedK,
			pos.PlainTailMass,
			pos.SpecTailMass,
			tv.Lower,
			tv.Upper,
			losslessnessWarnTVUpperThreshold,
			losslessnessQuarantineMedianTVLowerThreshold,
		) {
			return "inconclusive:tail_mass_high"
		}
		tvLowerValues = append(tvLowerValues, tv.Lower)
		tvUpperValues = append(tvUpperValues, tv.Upper)
		if tv.Lower > losslessnessQuarantineAnyTVLowerThreshold {
			anyLowerQuarantine = true
		}
		if tv.Upper > losslessnessWarnTVUpperThreshold {
			anyUpperWarn = true
		}
	}
	if medianLower := losslessnessCanonicalMedian(tvLowerValues); anyLowerQuarantine || medianLower > losslessnessQuarantineMedianTVLowerThreshold {
		return "quarantine_candidate:tv_lower_exceeded"
	}
	if medianUpper := losslessnessCanonicalMedian(tvUpperValues); anyUpperWarn || medianUpper > losslessnessWarnMedianTVUpperThreshold {
		return "warn:threshold_exceeded"
	}
	return "pass:fresh"
}

func losslessnessCanonicalMedian(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	return sorted[(len(sorted)-1)/2]
}

func (s *Server) runLosslessnessProbeLoop() {
	interval := time.Duration(s.cfg.Pool.LosslessnessProbe.IntervalS) * time.Second
	if interval <= 0 {
		return
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for range ticker.C {
		s.dispatchLosslessnessProbeRound()
	}
}

func (s *Server) dispatchLosslessnessProbeRound() {
	if s.pool == nil || !s.cfg.Pool.LosslessnessProbe.Enabled {
		return
	}
	for _, provider := range s.pool.Snapshot() {
		if !providerPublishedReady(provider) || s.losslessnessProviderHasPending(provider.ProviderID, provider.AssignedID) {
			continue
		}
		if err := s.issueLosslessnessProbeRequest(provider, s.nextLosslessnessProfile(provider)); err != nil {
			if errors.Is(err, errLosslessnessRekeyInProgress) {
				continue
			}
			s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Msg("losslessness probe dispatch failed")
		}
	}
}

func (s *Server) nextLosslessnessProfile(provider pool.Provider) LosslessnessSamplingProfile {
	profiles := LosslessnessDefaultProfiles()
	key := provider.ProviderID + "\x00" + provider.AssignedID + "\x00" + provider.ModelID
	s.losslessnessStateMu.Lock()
	defer s.losslessnessStateMu.Unlock()
	idx := s.losslessnessProfileCursor[key]
	s.losslessnessProfileCursor[key] = (idx + 1) % len(profiles)
	return profiles[idx%len(profiles)]
}

func (s *Server) losslessnessProviderHasPending(providerID, assignedID string) bool {
	prefix := losslessnessProbeStoreKey(providerID, assignedID, "")
	now := s.now()
	found := false
	s.losslessnessPending.Range(func(key, value any) bool {
		storeKey, ok := key.(string)
		if !ok || !strings.HasPrefix(storeKey, prefix) {
			return true
		}
		pending, ok := value.(losslessnessPendingProbe)
		if ok && !pending.ExpiresAt.IsZero() && !now.Before(pending.ExpiresAt) {
			if deleted, loaded := s.losslessnessPending.LoadAndDelete(storeKey); loaded {
				if expired, typed := deleted.(losslessnessPendingProbe); typed {
					s.deleteLosslessnessPendingIndexes(expired)
				}
			}
			return true
		}
		found = true
		return false
	})
	return found
}

func (s *Server) issueLosslessnessProbeRequest(provider pool.Provider, profile LosslessnessSamplingProfile) error {
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return errors.New("losslessness probe dispatch requires active provider session")
	}
	now := s.now()
	payload, err := s.buildLosslessnessProbeRequest(provider, profile, now)
	if err != nil {
		s.recordLosslessnessTelemetry(LosslessnessTelemetryEvent{
			EventSubtype: "admission_blocked",
			ProviderID:   provider.ProviderID,
			AssignedID:   provider.AssignedID,
			ResultKind:   "admission_blocked",
			ReasonCode:   "inconclusive:draft_identity_unbound",
			MeasuredAt:   now,
		})
		return err
	}
	payloadRaw, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	requestDigest, err := LosslessnessDigest(payloadRaw)
	if err != nil {
		return err
	}
	outer := LosslessnessProbeOuterEnvelope{
		Type:               losslessnessRequestType,
		ProbeID:            payload.ProbeID,
		ProbeRequestDigest: requestDigest,
		Payload:            payloadRaw,
	}
	cleartext, err := json.Marshal(outer)
	if err != nil {
		return err
	}
	if _, err := ValidateLosslessnessEnvelope(cleartext, losslessnessRequestType); err != nil {
		return err
	}
	session.rekeyMu.Lock()
	defer session.rekeyMu.Unlock()
	if session.rekey != nil {
		return errLosslessnessRekeyInProgress
	}
	if _, due := session.tier2RekeyReason(s.now(), s.tier2Config()); due {
		return errLosslessnessRekeyInProgress
	}
	pending, err := s.recordLosslessnessPendingProbe(provider.ProviderID, provider.AssignedID, payload, requestDigest, now)
	if err != nil {
		return err
	}
	frame, err := session.sealLosslessnessProbeRequest(provider, payload.ProbeID, cleartext)
	if err != nil {
		s.losslessnessPending.Delete(losslessnessProbeStoreKey(provider.ProviderID, provider.AssignedID, payload.ProbeID))
		s.deleteLosslessnessPendingIndexes(pending)
		if errors.Is(err, errTier2C2PCounterExhausted) {
			s.closeProviderForTier2SessionFailure(session, provider.ProviderID, provider.AssignedID, "", "counter_exhausted", ErrRelayAEADFailed)
		}
		return err
	}
	if err := session.send(frame); err != nil {
		s.losslessnessPending.Delete(losslessnessProbeStoreKey(provider.ProviderID, provider.AssignedID, payload.ProbeID))
		s.deleteLosslessnessPendingIndexes(pending)
		return err
	}
	return nil
}

func (s *Server) buildLosslessnessProbeRequest(provider pool.Provider, profile LosslessnessSamplingProfile, now time.Time) (LosslessnessProbeRequestPayload, error) {
	admission, ok := s.losslessnessDraftAdmission(provider.ProviderID, provider.AssignedID, provider.ModelID, now)
	if !ok {
		return LosslessnessProbeRequestPayload{}, errors.New("losslessness probe requires current draft_admission_v1")
	}
	cfg := s.cfg.Pool.LosslessnessProbe
	maxPrompts := cfg.MaxPromptsPerProbe
	if maxPrompts <= 0 || maxPrompts > 4 {
		maxPrompts = 4
	}
	maxPositions := cfg.MaxStochasticPositions
	if maxPositions <= 0 || maxPositions > 8 {
		maxPositions = 8
	}
	probeID, err := losslessnessRandomID("losslessness-", 16)
	if err != nil {
		return LosslessnessProbeRequestPayload{}, err
	}
	nonce, err := losslessnessRandomID("", 16)
	if err != nil {
		return LosslessnessProbeRequestPayload{}, err
	}
	positions := make([]int, maxPositions)
	contextHashes := make(map[int]string, maxPositions)
	highEntropy := make(map[int]bool, maxPositions)
	offline := make(map[int][]LosslessnessTokenProbability, maxPositions)
	for i := range positions {
		positions[i] = i
		contextHashes[i] = losslessnessSyntheticHash(probeID, fmt.Sprintf("position:%d", i))
		highEntropy[i] = i < 4
		offline[i] = losslessnessSyntheticOfflineSupport(70)
	}
	prompts := make([]LosslessnessPromptPayload, 0, maxPrompts)
	for i := 0; i < maxPrompts; i++ {
		prompts = append(prompts, LosslessnessPromptPayload{
			PromptID:         fmt.Sprintf("spec029-synthetic-%02d", i+1),
			Prompt:           fmt.Sprintf("SPEC-029 synthetic losslessness probe prompt %02d.", i+1),
			CoordinatorOwned: true,
			BuyerOrigin:      false,
		})
	}
	timeoutMS := cfg.TimeoutS * 1000
	if timeoutMS <= 0 {
		timeoutMS = 60000
	}
	return LosslessnessProbeRequestPayload{
		ProbeVersion:           LosslessnessProbeVersion,
		ProbeID:                probeID,
		ProbeNonce:             nonce,
		ExpiresAt:              now.Add(time.Duration(cfg.TimeoutS) * time.Second).UTC().Format(time.RFC3339Nano),
		ModelID:                admission.ModelID,
		TargetModelHash:        admission.TargetModelHash,
		TargetGeneration:       admission.TargetGeneration,
		DraftModelID:           admission.DraftModelID,
		DraftArtifactBinding:   admission.DraftArtifactBinding,
		DraftGeneration:        admission.DraftGeneration,
		TokenizerIdentity:      admission.TokenizerIdentity,
		SamplingProfile:        profile,
		CorpusVersion:          "spec029-prototype-corpus-v1",
		ThresholdVersion:       "spec029-v0.1-draft-thresholds",
		Prompts:                prompts,
		MeasurementPositions:   positions,
		RequestedK:             64,
		SupportSelection:       losslessnessSupportSelection,
		MaxPrompts:             maxPrompts,
		MaxStochasticPositions: maxPositions,
		TimeoutMS:              timeoutMS,
		VocabSize:              70,
		PositionContextHashes:  contextHashes,
		HighEntropyPositions:   highEntropy,
		OfflinePlainSupport:    offline,
	}, nil
}

func (s *Server) recordLosslessnessDraftAdmission(record LosslessnessDraftAdmissionRecord) {
	s.losslessnessStateMu.Lock()
	defer s.losslessnessStateMu.Unlock()
	key := losslessnessDraftAdmissionKey{ProviderID: record.ProviderID, AssignedID: record.AssignedID, ModelID: record.ModelID}
	s.losslessnessDraftAdmissions[key] = record
	s.losslessnessTargetGenerations[key.ProviderID+"\x00"+key.AssignedID+"\x00"+key.ModelID] = record.TargetGeneration
}

func (s *Server) losslessnessDraftAdmission(providerID, assignedID, modelID string, now time.Time) (LosslessnessDraftAdmissionRecord, bool) {
	s.losslessnessStateMu.Lock()
	defer s.losslessnessStateMu.Unlock()
	record, ok := s.losslessnessDraftAdmissions[losslessnessDraftAdmissionKey{ProviderID: providerID, AssignedID: assignedID, ModelID: modelID}]
	if !ok || (!record.ExpiresAt.IsZero() && !now.Before(record.ExpiresAt)) {
		return LosslessnessDraftAdmissionRecord{}, false
	}
	return record, true
}

func (s *Server) recordLosslessnessTelemetry(event LosslessnessTelemetryEvent) {
	s.losslessnessStateMu.Lock()
	defer s.losslessnessStateMu.Unlock()
	s.losslessnessTelemetry = append(s.losslessnessTelemetry, event)
}

func (s *Server) losslessnessTelemetrySnapshot() []LosslessnessTelemetryEvent {
	s.losslessnessStateMu.Lock()
	defer s.losslessnessStateMu.Unlock()
	return append([]LosslessnessTelemetryEvent(nil), s.losslessnessTelemetry...)
}

func losslessnessRandomID(prefix string, n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return prefix + hex.EncodeToString(buf), nil
}

func losslessnessSyntheticHash(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return "sha256:" + hex.EncodeToString(sum[:])
}

func losslessnessSyntheticOfflineSupport(vocabSize int) []LosslessnessTokenProbability {
	if vocabSize <= 0 {
		return nil
	}
	out := make([]LosslessnessTokenProbability, vocabSize)
	p := 1.0 / float64(vocabSize)
	for i := range out {
		out[i] = LosslessnessTokenProbability{TokenID: i, P: p}
	}
	return out
}

type encryptedLosslessnessRequest struct {
	Type      string                 `json:"type"`
	RequestID string                 `json:"request_id"`
	Stream    bool                   `json:"stream"`
	Encrypted bool                   `json:"encrypted"`
	Enc       tier2.AEADEnvelopeBody `json:"enc"`
}

type encryptedLosslessnessResult struct {
	Type      string                 `json:"type"`
	RequestID string                 `json:"request_id"`
	Stream    bool                   `json:"stream"`
	Encrypted bool                   `json:"encrypted"`
	Enc       tier2.AEADEnvelopeBody `json:"enc"`
}

type encryptedLosslessnessPlaintext struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

func (ps *providerSession) sealLosslessnessProbeRequest(provider pool.Provider, probeID string, cleartextOuterEnvelope []byte) ([]byte, error) {
	ps.tier2Mu.Lock()
	session := ps.tier2
	if session == nil {
		ps.tier2Mu.Unlock()
		return cleartextOuterEnvelope, nil
	}
	defer ps.tier2Mu.Unlock()
	if session.C2PCounter == ^uint64(0) {
		return nil, errTier2C2PCounterExhausted
	}
	seq := session.C2PCounter
	aad := tier2.AEADFrameAAD{
		Type:       losslessnessEncryptedRequestType,
		Direction:  "c2p",
		RequestID:  probeID,
		Stream:     false,
		ProviderID: provider.ProviderID,
		AssignedID: provider.AssignedID,
		Seq:        seq,
	}
	plaintext, err := json.Marshal(encryptedLosslessnessPlaintext{
		Type:    losslessnessRequestPlaintextType,
		Payload: cleartextOuterEnvelope,
	})
	if err != nil {
		return nil, err
	}
	envelope, err := tier2.SealPillarBFrame(session.C2PKey, session.C2PNonceBase, session.KeyID, seq, aad, plaintext)
	if err != nil {
		return nil, err
	}
	session.C2PCounter++
	return json.Marshal(encryptedLosslessnessRequest{
		Type:      losslessnessEncryptedRequestType,
		RequestID: probeID,
		Stream:    false,
		Encrypted: true,
		Enc:       envelope.Enc,
	})
}

func (ps *providerSession) openLosslessnessProbeResult(provider pool.Provider, probeID string, envelope tier2.AEADEnvelope) ([]byte, error) {
	ps.tier2Mu.Lock()
	defer ps.tier2Mu.Unlock()
	if ps.tier2 == nil {
		return nil, errors.New("encrypted losslessness result for provider without tier2 session")
	}
	if ps.tier2.P2CCounter == ^uint64(0) {
		return nil, errors.New("tier2 p2c frame counter exhausted")
	}
	seq := ps.tier2.P2CCounter
	aad := tier2.AEADFrameAAD{
		Type:       losslessnessEncryptedResultType,
		Direction:  "p2c",
		RequestID:  probeID,
		Stream:     false,
		ProviderID: provider.ProviderID,
		AssignedID: provider.AssignedID,
		Seq:        seq,
	}
	plaintext, err := tier2.OpenPillarBFrame(ps.tier2.P2CKey, ps.tier2.P2CNonceBase, ps.tier2.KeyID, seq, aad, envelope)
	if err != nil {
		return nil, err
	}
	var carrier encryptedLosslessnessPlaintext
	if err := json.Unmarshal(plaintext, &carrier); err != nil {
		return nil, err
	}
	if carrier.Type != losslessnessResultPlaintextType || len(carrier.Payload) == 0 {
		return nil, errors.New("invalid losslessness result plaintext envelope")
	}
	ps.tier2.P2CCounter++
	return carrier.Payload, nil
}

func (s *Server) handleLosslessnessProbeResult(providerID, assignedID string, payload []byte) {
	if !s.cfg.Pool.LosslessnessProbe.Enabled {
		s.log.Warn().Str("provider_id", providerID).Msg("losslessness result ignored while probe feature disabled")
		return
	}

	var envelope struct {
		Type      string                 `json:"type"`
		RequestID string                 `json:"request_id"`
		Stream    bool                   `json:"stream"`
		Encrypted bool                   `json:"encrypted"`
		Enc       tier2.AEADEnvelopeBody `json:"enc"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid losslessness result json")
		return
	}

	cleartext := payload
	if envelope.Type == losslessnessEncryptedResultType {
		if !envelope.Encrypted || envelope.Stream || envelope.RequestID == "" {
			s.log.Warn().Str("provider_id", providerID).Msg("invalid encrypted losslessness result carrier")
			return
		}
		provider, ok := s.pool.Resolve(providerID, assignedID)
		if !ok {
			s.log.Warn().Str("provider_id", providerID).Msg("losslessness result from unresolved provider")
			return
		}
		session, ok := s.sessionFor(providerID, assignedID)
		if !ok {
			s.log.Warn().Str("provider_id", providerID).Msg("encrypted losslessness result without active session")
			return
		}
		opened, err := session.openLosslessnessProbeResult(provider, envelope.RequestID, tier2.AEADEnvelope{Encrypted: true, Enc: envelope.Enc})
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid encrypted losslessness result")
			return
		}
		cleartext = opened
	} else if envelope.Type == losslessnessResultType {
		if session, ok := s.sessionFor(providerID, assignedID); ok && session.hasTier2Session() {
			s.log.Warn().Str("provider_id", providerID).Msg("plaintext losslessness result rejected for active tier2 session")
			return
		}
	}

	outer, err := ValidateLosslessnessEnvelope(cleartext, losslessnessResultType)
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid losslessness result envelope")
		return
	}
	if envelope.Type == losslessnessEncryptedResultType && outer.ProbeID != envelope.RequestID {
		s.log.Warn().Str("provider_id", providerID).Msg("losslessness encrypted result request_id/probe_id mismatch")
		return
	}
	result, err := ValidateLosslessnessResultPayload(outer.Payload)
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid losslessness result payload")
		return
	}
	pending, err := s.consumeLosslessnessPendingProbe(providerID, assignedID, result, s.now())
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("losslessness result rejected without pending probe")
		return
	}
	reasonCode := "pass:fresh"
	if result.ResultKind == "provider_inconclusive" {
		reasonCode = result.ProviderReasonCode
	} else {
		reasonCode = losslessnessReasonForMeasurement(result, pending)
	}
	record, err := s.applyLosslessnessProfileReason(pending.ProfileKey, reasonCode, s.now())
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("losslessness result has unmapped reason")
		return
	}
	s.recordLosslessnessTelemetry(LosslessnessTelemetryEvent{
		EventSubtype:   "probe_result",
		ProviderID:     providerID,
		AssignedID:     assignedID,
		ProbeID:        result.ProbeID,
		ResultKind:     result.ResultKind,
		ReasonCode:     reasonCode,
		ProfileState:   record.State,
		OperatorAction: record.OperatorAction,
		MeasuredAt:     record.MeasuredAt,
	})
	s.log.Info().
		Str("provider_id", providerID).
		Str("probe_id", result.ProbeID).
		Str("result_kind", result.ResultKind).
		Str("reason_code", reasonCode).
		Str("profile_state", string(record.State)).
		Str("operator_action", string(record.OperatorAction)).
		Str("evidence_strength", "cooperative_prototype_not_settlement_evidence").
		Str("spec_status", "SPEC-029 v0.1-draft prototype").
		Msg("validated losslessness probe result and derived prototype operator state")
}

func probabilityMap(values []LosslessnessTokenProbability) (map[int]float64, error) {
	out := make(map[int]float64, len(values))
	for _, value := range values {
		if value.TokenID < 0 || !validMass(value.P) {
			return nil, errLosslessnessMalformed
		}
		if _, exists := out[value.TokenID]; exists {
			return nil, errLosslessnessMalformed
		}
		out[value.TokenID] = value.P
	}
	return out, nil
}

func validMass(v float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0) && v >= 0 && v <= 1
}

func topKSorted(ids []int, support []LosslessnessTokenProbability, k, vocabSize int) bool {
	wantLen := k
	if vocabSize > 0 && vocabSize < k {
		wantLen = vocabSize
	}
	if len(ids) != wantLen {
		return false
	}
	probs, err := probabilityMap(support)
	if err != nil {
		return false
	}
	seen := map[int]struct{}{}
	for i, id := range ids {
		if id < 0 || (vocabSize > 0 && id >= vocabSize) {
			return false
		}
		if _, ok := seen[id]; ok {
			return false
		}
		seen[id] = struct{}{}
		if _, ok := probs[id]; !ok {
			return false
		}
		if i == 0 {
			continue
		}
		prev := ids[i-1]
		if probs[prev] < probs[id] {
			return false
		}
		if probs[prev] == probs[id] && prev > id {
			return false
		}
	}
	lastID := ids[len(ids)-1]
	lastP := probs[lastID]
	for _, candidate := range support {
		if _, ok := seen[candidate.TokenID]; ok {
			continue
		}
		if candidate.P > lastP {
			return false
		}
		if candidate.P == lastP && candidate.TokenID < lastID {
			return false
		}
	}
	return true
}

func numericUnion(a, b []int) []int {
	set := map[int]struct{}{}
	for _, id := range a {
		set[id] = struct{}{}
	}
	for _, id := range b {
		set[id] = struct{}{}
	}
	out := make([]int, 0, len(set))
	for id := range set {
		out = append(out, id)
	}
	sort.Ints(out)
	return out
}

func sameInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func canonicalizeJSON(raw []byte) ([]byte, error) {
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.UseNumber()
	var value any
	if err := dec.Decode(&value); err != nil {
		return nil, err
	}
	return billing.CanonicalJSONRawStrings(value)
}
