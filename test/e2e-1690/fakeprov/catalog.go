package main

// Catalog identity derivation for -catalog-dir and -catalog-from-coordinator.
//
// catalog_row_identity is validated by the coordinator at
// phase4-coordinator/internal/ws/server.go:3690-3706: it resolves the row with
// Catalog.HighestClaimedTier(hello.model_id) and compares the provider's
// catalog_row_identity to Catalog.RowIdentity(key). The formula below is a
// port of Catalog.RowIdentity (phase4-coordinator/internal/autotune/catalog.go:125)
// and Row.policyDigest (catalog.go:164, with canonicalDraftCandidatesValue :225
// and canonicalWorkloadProfilesValue :246): length-prefixed "N:field" framing
// joined by '|' over (policy_version, key, model_id, model_revision,
// model_sha256, min_ram_gb, min_bandwidth_tier, "%.6f" min_sustained_tps,
// max_4k_ttft_ms, runtime_status[, "policy:"+JCS sha256 of the row policy]),
// then sha256 hex.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type catalogIdentity struct {
	ReleaseID     string
	PolicyVersion string
	CandidatesSHA string
	SignerKeyID   string
	RowIdentity   string
	ModelID       string
	ModelHash     string
}

type benchGate struct {
	MinSustainedTPS float64 `json:"min_sustained_tps"`
	Max4KTTFTMS     int     `json:"max_4k_ttft_ms"`
}

type candidateRow struct {
	ModelID          string          `json:"model_id"`
	ModelRevision    string          `json:"model_revision,omitempty"`
	ModelSHA256      string          `json:"model_sha256,omitempty"`
	MinRAMGB         int             `json:"min_ram_gb"`
	MinBandwidthTier string          `json:"min_bandwidth_tier"`
	BenchGate        benchGate       `json:"bench_gate"`
	RuntimeStatus    string          `json:"runtime_status"`
	DraftCandidates  json.RawMessage `json:"draft_candidates,omitempty"`
	WorkloadProfiles json.RawMessage `json:"workload_profiles,omitempty"`
}

type candidateCatalog struct {
	Version       string                  `json:"version"`
	PolicyVersion string                  `json:"policy_version"`
	Rows          map[string]candidateRow `json:"rows"`
}

func loadCatalogDir(dir, key string) (catalogIdentity, error) {
	var release struct {
		ReleaseID     string `json:"release_id"`
		PolicyVersion string `json:"policy_version"`
		Feeds         map[string]struct {
			SHA256      string `json:"sha256"`
			SignerKeyID string `json:"signer_key_id"`
		} `json:"feeds"`
	}
	raw, err := os.ReadFile(filepath.Join(dir, "release.json"))
	if err != nil {
		return catalogIdentity{}, err
	}
	if err := json.Unmarshal(raw, &release); err != nil {
		return catalogIdentity{}, fmt.Errorf("parse release.json: %w", err)
	}
	feed, ok := release.Feeds["autotune-candidates.json"]
	if !ok {
		return catalogIdentity{}, fmt.Errorf("release.json has no feeds[\"autotune-candidates.json\"]")
	}
	candRaw, err := os.ReadFile(filepath.Join(dir, "autotune-candidates.json"))
	if err != nil {
		return catalogIdentity{}, err
	}
	if sum := sha256.Sum256(candRaw); hex.EncodeToString(sum[:]) != strings.ToLower(feed.SHA256) {
		logf("WARNING: sha256(%s/autotune-candidates.json)=%x != release.json sha256 %s", dir, sum, feed.SHA256)
	}
	return identityFromCandidates(release.ReleaseID, release.PolicyVersion, strings.ToLower(feed.SHA256), feed.SignerKeyID, candRaw, key)
}

// fetchCatalogFromCoordinator derives the identity the way the real CLI
// adopts the coordinator's live catalog: GET <base>/v1/autotune-release
// (phase4-coordinator/internal/buyer/autotune_feeds.go handleAutotuneRelease:
// release_id, policy_version, feeds.autotune_candidates.{sha256,signer_key_id})
// and GET <base>/v1/autotune-candidates (digest = sha256 of the exact bytes).
// The signer falls back to the key_id of /v1/autotune-candidates.sig.
func fetchCatalogFromCoordinator(ctx context.Context, base, key string) (catalogIdentity, error) {
	base = strings.TrimRight(base, "/")
	var release struct {
		ReleaseID     string `json:"release_id"`
		PolicyVersion string `json:"policy_version"`
		Feeds         struct {
			AutotuneCandidates struct {
				SHA256      string `json:"sha256"`
				SignerKeyID string `json:"signer_key_id"`
			} `json:"autotune_candidates"`
		} `json:"feeds"`
	}
	raw, err := httpGet(ctx, base+"/v1/autotune-release")
	if err != nil {
		return catalogIdentity{}, err
	}
	if err := json.Unmarshal(raw, &release); err != nil {
		return catalogIdentity{}, fmt.Errorf("parse /v1/autotune-release: %w", err)
	}
	candRaw, err := httpGet(ctx, base+"/v1/autotune-candidates")
	if err != nil {
		return catalogIdentity{}, err
	}
	sum := sha256.Sum256(candRaw)
	digest := hex.EncodeToString(sum[:])
	if want := strings.ToLower(release.Feeds.AutotuneCandidates.SHA256); want != "" && want != digest {
		// The feeds can swap between the two GETs (SIGHUP); retry later.
		return catalogIdentity{}, fmt.Errorf("candidates bytes sha256 %s != /v1/autotune-release sha256 %s", digest, want)
	}
	signer := release.Feeds.AutotuneCandidates.SignerKeyID
	if signer == "" {
		sigRaw, err := httpGet(ctx, base+"/v1/autotune-candidates.sig")
		if err != nil {
			return catalogIdentity{}, err
		}
		var sig struct {
			KeyID string `json:"key_id"`
		}
		if err := json.Unmarshal(sigRaw, &sig); err != nil {
			return catalogIdentity{}, fmt.Errorf("parse /v1/autotune-candidates.sig: %w", err)
		}
		signer = sig.KeyID
	}
	return identityFromCandidates(release.ReleaseID, release.PolicyVersion, digest, signer, candRaw, key)
}

func httpGet(ctx context.Context, url string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: HTTP %d: %s", url, resp.StatusCode, truncate(body))
	}
	return body, nil
}

func identityFromCandidates(releaseID, policy, digest, signer string, candRaw []byte, key string) (catalogIdentity, error) {
	id := catalogIdentity{ReleaseID: releaseID, PolicyVersion: policy, CandidatesSHA: digest, SignerKeyID: signer}
	var cat candidateCatalog
	if err := json.Unmarshal(candRaw, &cat); err != nil {
		return id, fmt.Errorf("parse autotune-candidates.json: %w", err)
	}
	if strings.TrimSpace(cat.PolicyVersion) == "" {
		cat.PolicyVersion = "legacy-spec-023" // catalog.go ParseCatalog default
	}
	row, ok := cat.Rows[key]
	if !ok {
		return id, fmt.Errorf("autotune-candidates.json has no row %q", key)
	}
	id.ModelID = row.ModelID
	id.ModelHash = row.ModelSHA256
	var err error
	id.RowIdentity, err = rowIdentity(cat.PolicyVersion, key, row)
	if err != nil {
		return id, err
	}
	if picked := highestClaimedTier(cat, row.ModelID); picked != key {
		logf("WARNING: coordinator resolves model_id %q to row %q, not -catalog-key %q; admission will reject the row identity", row.ModelID, picked, key)
	}
	return id, nil
}

// highestClaimedTier mirrors Catalog.HighestClaimedTier (catalog.go) so a
// mismatched -catalog-key is reported instead of silently rejected.
func highestClaimedTier(cat candidateCatalog, modelID string) string {
	normalized := strings.ToLower(strings.TrimSpace(modelID))
	if _, ok := cat.Rows[normalized]; ok {
		return normalized
	}
	best, bestRAM := "", -1
	for key, row := range cat.Rows {
		if strings.ToLower(strings.TrimSpace(row.ModelID)) != normalized {
			continue
		}
		if row.MinRAMGB > bestRAM || (row.MinRAMGB == bestRAM && key < best) {
			best, bestRAM = key, row.MinRAMGB
		}
	}
	return best
}

func rowIdentity(policyVersion, key string, row candidateRow) (string, error) {
	fields := []string{
		policyVersion,
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
		return "", err
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
	return hex.EncodeToString(sum[:]), nil
}

func (r candidateRow) policyDigest() (string, error) {
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
	digest, _, err := spec015CanonicalSHA256Hex(policy)
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
