package autotune

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

const candidateCatalogSource = "operator_curated_autotune_candidate_catalog"

type BenchGate struct {
	MinSustainedTPS float64 `json:"min_sustained_tps"`
	Max4KTTFTMS     int     `json:"max_4k_ttft_ms"`
}

type Row struct {
	ModelID          string          `json:"model_id"`
	ModelRevision    string          `json:"model_revision,omitempty"`
	ModelSHA256      string          `json:"model_sha256,omitempty"`
	MinRAMGB         int             `json:"min_ram_gb"`
	MinBandwidthTier string          `json:"min_bandwidth_tier"`
	BenchGate        BenchGate       `json:"bench_gate"`
	RuntimeStatus    string          `json:"runtime_status"`
	DraftCandidates  json.RawMessage `json:"draft_candidates,omitempty"`
	WorkloadProfiles json.RawMessage `json:"workload_profiles,omitempty"`
}

// PolicyEquivalent compares the same typed canonical policy that RowIdentity
// binds. This deliberately treats omitted and explicit-null optional fields as
// equivalent across Go, Swift, and the catalog release tooling.
func (c *Catalog) PolicyEquivalent(key string, other *Catalog, otherKey string) bool {
	row, ok := c.Row(key)
	if !ok {
		return false
	}
	otherRow, ok := other.Row(otherKey)
	if !ok {
		return false
	}
	leftDigest, leftErr := row.policyDigest()
	rightDigest, rightErr := otherRow.policyDigest()
	return leftErr == nil && rightErr == nil && leftDigest == rightDigest
}

type Catalog struct {
	Version       string
	PolicyVersion string
	SignerKeyID   string
	SHA256        string
	RawJSON       []byte
	rowsByKey     map[string]Row
	keysByModel   map[string][]string
}

func ParseCatalog(rawJSON []byte) (*Catalog, error) {
	if len(rawJSON) == 0 {
		return nil, fmt.Errorf("autotune candidate catalog is empty")
	}
	var envelope struct {
		Version       string         `json:"version"`
		PolicyVersion string         `json:"policy_version"`
		Source        string         `json:"source"`
		Rows          map[string]Row `json:"rows"`
	}
	if err := json.Unmarshal(rawJSON, &envelope); err != nil {
		return nil, fmt.Errorf("parse autotune candidate catalog: %w", err)
	}
	if envelope.Source != candidateCatalogSource {
		return nil, fmt.Errorf("autotune candidate catalog source must be %q", candidateCatalogSource)
	}
	if strings.TrimSpace(envelope.Version) == "" {
		return nil, fmt.Errorf("autotune candidate catalog version is required")
	}
	if strings.TrimSpace(envelope.PolicyVersion) == "" {
		envelope.PolicyVersion = "legacy-spec-023"
	}
	if len(envelope.Rows) == 0 {
		return nil, fmt.Errorf("autotune candidate catalog rows are required")
	}
	sum := sha256.Sum256(rawJSON)
	keysByModel := make(map[string][]string, len(envelope.Rows))
	for key, row := range envelope.Rows {
		key = strings.TrimSpace(key)
		if key == "" {
			return nil, fmt.Errorf("autotune candidate catalog row key is required")
		}
		if strings.TrimSpace(row.ModelID) == "" {
			return nil, fmt.Errorf("autotune candidate catalog row %q model_id is required", key)
		}
		if row.MinRAMGB < 0 {
			return nil, fmt.Errorf("autotune candidate catalog row %q min_ram_gb must be >= 0", key)
		}
		if math.IsNaN(row.BenchGate.MinSustainedTPS) || math.IsInf(row.BenchGate.MinSustainedTPS, 0) || row.BenchGate.MinSustainedTPS < 0 {
			return nil, fmt.Errorf("autotune candidate catalog row %q min_sustained_tps is invalid", key)
		}
		if row.BenchGate.Max4KTTFTMS < 0 {
			return nil, fmt.Errorf("autotune candidate catalog row %q max_4k_ttft_ms must be >= 0", key)
		}
		normalizedModelID := normalizeModelID(row.ModelID)
		keysByModel[normalizedModelID] = append(keysByModel[normalizedModelID], key)
	}
	return &Catalog{
		Version:       envelope.Version,
		PolicyVersion: envelope.PolicyVersion,
		SHA256:        hex.EncodeToString(sum[:]),
		RawJSON:       append([]byte(nil), rawJSON...),
		rowsByKey:     envelope.Rows,
		keysByModel:   keysByModel,
	}, nil
}

// RowIdentity binds benchmark evidence to the catalog fields that control
// artifact trust and admission for one model. Unrelated row updates can then
// preserve valid evidence without accepting a changed artifact or gate.
func (c *Catalog) RowIdentity(key string) (string, bool) {
	row, ok := c.Row(key)
	if !ok {
		return "", false
	}
	fields := []string{
		c.PolicyVersion,
		key,
		row.ModelID,
		row.ModelRevision,
		row.ModelSHA256,
		fmt.Sprintf("%d", row.MinRAMGB),
		row.MinBandwidthTier,
		fmt.Sprintf("%.6f", row.BenchGate.MinSustainedTPS),
		fmt.Sprintf("%d", row.BenchGate.Max4KTTFTMS),
		row.RuntimeStatus,
	}
	policyDigest, err := row.policyDigest()
	if err != nil {
		return "", false
	}
	if policyDigest != "" {
		fields = append(fields, "policy:"+policyDigest)
	}
	var framed strings.Builder
	for i, field := range fields {
		if i > 0 {
			framed.WriteByte('|')
		}
		fmt.Fprintf(&framed, "%d:%s", len([]byte(field)), field)
	}
	sum := sha256.Sum256([]byte(framed.String()))
	return hex.EncodeToString(sum[:]), true
}

// policyDigest binds benchmark evidence to the structured fields that can
// change runtime selection after the base model has been benchmarked. Rows
// without either field keep their historical identity; once policy is present,
// its RFC 8785 form is part of the identity in both coordinator and provider.
func (r Row) policyDigest() (string, error) {
	policy := make(map[string]any, 2)
	if value, present, err := canonicalDraftCandidatesValue(r.DraftCandidates); err != nil {
		return "", err
	} else if present {
		policy["draft_candidates"] = value
	}
	if value, present, err := canonicalWorkloadProfilesValue(r.WorkloadProfiles); err != nil {
		return "", err
	} else if present {
		policy["workload_profiles"] = value
	}
	if len(policy) == 0 {
		return "", nil
	}
	digest, _, err := billing.CanonicalSHA256Hex(policy)
	if err != nil {
		return "", fmt.Errorf("canonicalize row policy: %w", err)
	}
	return digest, nil
}

type rowDraftCandidate struct {
	DraftModel               string `json:"draft_model"`
	DraftModelArtifactSHA256 string `json:"draft_model_artifact_sha256"`
}

type rowWorkloadRecommended struct {
	KVBits                   int     `json:"kv_bits"`
	MaxContextOverride       int     `json:"max_context_override"`
	MaxConcurrencyOverride   int     `json:"max_concurrency_override"`
	DraftModel               *string `json:"draft_model"`
	DraftModelArtifactSHA256 *string `json:"draft_model_artifact_sha256"`
	NumDraftTokens           *int    `json:"num_draft_tokens"`
}

type rowWorkloadGatePolicy struct {
	MinSamples           int      `json:"min_samples"`
	MaxP95TTFTMS         int      `json:"max_p95_ttft_ms"`
	MaxStopTokenLeakRate float64  `json:"max_stop_token_leak_rate"`
	MinMedianTPS         *float64 `json:"min_median_tps"`
}

type rowWorkloadMetrics struct {
	MedianTPS                *float64 `json:"median_tps"`
	P95TTFTMS                *float64 `json:"p95_ttft_ms"`
	StopTokenLeakRate        *float64 `json:"stop_token_leak_rate"`
	SpecDecodeAcceptanceRate *float64 `json:"spec_decode_acceptance_rate"`
	SampleCount              int      `json:"sample_count"`
}

type rowWorkloadProfile struct {
	Status          *string                 `json:"status"`
	NoWinnerReason  *string                 `json:"no_winner_reason"`
	Recommended     *rowWorkloadRecommended `json:"recommended"`
	GatePolicy      rowWorkloadGatePolicy   `json:"gate_policy"`
	ProfileMetrics  rowWorkloadMetrics      `json:"profile_metrics"`
	Source          string                  `json:"source"`
	CandidateSource *string                 `json:"candidate_source"`
}

func canonicalDraftCandidatesValue(raw json.RawMessage) (any, bool, error) {
	if len(raw) == 0 {
		return nil, false, nil
	}
	var candidates *[]rowDraftCandidate
	if err := json.Unmarshal(raw, &candidates); err != nil {
		return nil, false, fmt.Errorf("decode row draft_candidates policy: %w", err)
	}
	if candidates == nil {
		return nil, false, nil
	}
	value := make([]any, 0, len(*candidates))
	for _, candidate := range *candidates {
		value = append(value, map[string]any{
			"draft_model":                 candidate.DraftModel,
			"draft_model_artifact_sha256": candidate.DraftModelArtifactSHA256,
		})
	}
	return value, true, nil
}

func canonicalWorkloadProfilesValue(raw json.RawMessage) (any, bool, error) {
	if len(raw) == 0 {
		return nil, false, nil
	}
	var profiles *map[string]map[string]rowWorkloadProfile
	if err := json.Unmarshal(raw, &profiles); err != nil {
		return nil, false, fmt.Errorf("decode row workload_profiles policy: %w", err)
	}
	if profiles == nil {
		return nil, false, nil
	}
	workloads := make(map[string]any, len(*profiles))
	for workload, tiers := range *profiles {
		canonicalTiers := make(map[string]any, len(tiers))
		for tier, profile := range tiers {
			value := map[string]any{
				"gate_policy": map[string]any{
					"min_samples":              profile.GatePolicy.MinSamples,
					"max_p95_ttft_ms":          profile.GatePolicy.MaxP95TTFTMS,
					"max_stop_token_leak_rate": profile.GatePolicy.MaxStopTokenLeakRate,
					"min_median_tps":           nullableFloat(profile.GatePolicy.MinMedianTPS),
				},
				"profile_metrics": map[string]any{
					"median_tps":                  nullableFloat(profile.ProfileMetrics.MedianTPS),
					"p95_ttft_ms":                 nullableFloat(profile.ProfileMetrics.P95TTFTMS),
					"stop_token_leak_rate":        nullableFloat(profile.ProfileMetrics.StopTokenLeakRate),
					"spec_decode_acceptance_rate": nullableFloat(profile.ProfileMetrics.SpecDecodeAcceptanceRate),
					"sample_count":                profile.ProfileMetrics.SampleCount,
				},
				"source": profile.Source,
			}
			if profile.Status != nil {
				value["status"] = *profile.Status
			}
			if profile.NoWinnerReason != nil {
				value["no_winner_reason"] = *profile.NoWinnerReason
			}
			if profile.CandidateSource != nil {
				value["candidate_source"] = *profile.CandidateSource
			}
			if profile.Recommended != nil {
				recommended := map[string]any{
					"kv_bits":                  profile.Recommended.KVBits,
					"max_context_override":     profile.Recommended.MaxContextOverride,
					"max_concurrency_override": profile.Recommended.MaxConcurrencyOverride,
				}
				if profile.Recommended.DraftModel != nil {
					recommended["draft_model"] = *profile.Recommended.DraftModel
				}
				if profile.Recommended.DraftModelArtifactSHA256 != nil {
					recommended["draft_model_artifact_sha256"] = *profile.Recommended.DraftModelArtifactSHA256
				}
				if profile.Recommended.NumDraftTokens != nil {
					recommended["num_draft_tokens"] = *profile.Recommended.NumDraftTokens
				}
				value["recommended"] = recommended
			}
			canonicalTiers[tier] = value
		}
		workloads[workload] = canonicalTiers
	}
	return workloads, true, nil
}

func nullableFloat(value *float64) any {
	if value == nil {
		return nil
	}
	return *value
}

func (c *Catalog) Row(key string) (Row, bool) {
	if c == nil {
		return Row{}, false
	}
	row, ok := c.rowsByKey[key]
	return row, ok
}

func (c *Catalog) HighestClaimedTier(modelID string) (key string, row Row, ok bool) {
	if c == nil {
		return "", Row{}, false
	}
	normalized := normalizeModelID(modelID)
	if row, ok := c.rowsByKey[normalized]; ok {
		return normalized, row, true
	}
	keys := c.keysByModel[normalized]
	if len(keys) == 0 {
		return "", Row{}, false
	}
	bestKey := keys[0]
	bestRow := c.rowsByKey[bestKey]
	for _, candidateKey := range keys[1:] {
		candidate := c.rowsByKey[candidateKey]
		if candidate.MinRAMGB > bestRow.MinRAMGB {
			bestKey = candidateKey
			bestRow = candidate
		}
	}
	return bestKey, bestRow, true
}

func normalizeModelID(modelID string) string {
	return strings.ToLower(strings.TrimSpace(modelID))
}
