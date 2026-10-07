package buyer

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

const continuousBatchingPolicySchema = "macprovider.continuous-batching-policy.v1"

// continuousBatchingPolicyCacheClasses is the closed SPEC-023 v0.22.1 cache_class
// enum: exactly what scripts/catalog-release.py and the CLI's signed-policy
// parser accept. `mixed` is the hybrid (recurrent plus paged attention)
// identity #1808 admitted on the producer and provider sides; this is the
// coordinator half of that admission.
var continuousBatchingPolicyCacheClasses = map[string]struct{}{
	"KVCacheSimple": {},
	"mixed":         {},
}

type continuousBatchingPolicyFeed struct {
	SchemaVersion          string                          `json:"schema_version"`
	ReleaseID              string                          `json:"release_id"`
	PolicyVersion          string                          `json:"policy_version"`
	GeneratedAt            string                          `json:"generated_at"`
	ExpiresAt              string                          `json:"expires_at"`
	CandidateCatalogSHA256 string                          `json:"candidate_catalog_sha256"`
	SignerKeyID            string                          `json:"signer_key_id"`
	Entries                []continuousBatchingPolicyEntry `json:"entries"`
}

type continuousBatchingPolicyEntry struct {
	TupleSHA256         string                              `json:"tuple_sha256"`
	ModelKey            string                              `json:"model_key"`
	ModelID             string                              `json:"model_id"`
	ModelSHA256         string                              `json:"model_sha256"`
	TokenizerSHA256     string                              `json:"tokenizer_sha256"`
	ChatTemplateSHA256  string                              `json:"chat_template_sha256"`
	CacheClass          string                              `json:"cache_class"`
	KVDType             string                              `json:"kv_dtype"`
	RequiresMoE         *bool                               `json:"requires_moe"`
	HardwareClass       string                              `json:"hardware_class"`
	MetallibSHA256      string                              `json:"metallib_sha256"`
	KernelIdentifier    string                              `json:"kernel_identifier"`
	Rollout             string                              `json:"rollout"`
	CachedTurnsAccepted *bool                               `json:"cached_turns_accepted"`
	Provenance          *continuousBatchingPolicyProvenance `json:"provenance"`
}

type continuousBatchingPolicyProvenance struct {
	Source                string `json:"source"`
	Status                string `json:"status"`
	EvidenceID            string `json:"evidence_id"`
	PackageManifestSHA256 string `json:"package_manifest_sha256"`
	StudioCampaignSHA256  string `json:"studio_campaign_sha256"`
	ProviderCLIVersion    string `json:"provider_cli_version"`
	LiveExecutableCDHash  string `json:"live_executable_cdhash"`
}

func (f AutotuneFeeds) continuousBatchingPolicyEnabled() bool {
	return len(f.ContinuousBatchingPolicyJSON) > 0 && len(f.ContinuousBatchingPolicySig) > 0
}

func validateContinuousBatchingPolicyFeed(raw []byte, signerKeyID string) (feedRelease, error) {
	var feed continuousBatchingPolicyFeed
	if err := decodeStrictJSON(raw, &feed); err != nil {
		return feedRelease{}, err
	}
	if feed.SchemaVersion != continuousBatchingPolicySchema {
		return feedRelease{}, fmt.Errorf("schema_version must be %q", continuousBatchingPolicySchema)
	}
	if !artifactFeedTimestampGrammar.MatchString(feed.GeneratedAt) {
		return feedRelease{}, fmt.Errorf("generated_at must be RFC3339 at seconds precision with an explicit timezone")
	}
	if !artifactFeedTimestampGrammar.MatchString(feed.ExpiresAt) {
		return feedRelease{}, fmt.Errorf("expires_at must be RFC3339 at seconds precision with an explicit timezone")
	}
	release, err := validateFeedHeader(feed.ReleaseID, feed.PolicyVersion, feed.GeneratedAt, "", "")
	if err != nil {
		return feedRelease{}, err
	}
	expiresAt, err := time.Parse(time.RFC3339, feed.ExpiresAt)
	if err != nil {
		return feedRelease{}, fmt.Errorf("expires_at must be RFC3339: %w", err)
	}
	if !release.generatedAt.Before(expiresAt) {
		return feedRelease{}, fmt.Errorf("expires_at must be after generated_at")
	}
	if !lowerHex64Pattern.MatchString(feed.CandidateCatalogSHA256) {
		return feedRelease{}, fmt.Errorf("candidate_catalog_sha256 must be lowercase 64-hex")
	}
	if strings.TrimSpace(feed.SignerKeyID) == "" || strings.TrimSpace(feed.SignerKeyID) != feed.SignerKeyID {
		return feedRelease{}, fmt.Errorf("signer_key_id must be a non-empty trimmed string")
	}
	if feed.SignerKeyID != signerKeyID {
		return feedRelease{}, fmt.Errorf("signer_key_id must equal signature key_id")
	}
	if feed.Entries == nil {
		return feedRelease{}, fmt.Errorf("entries must be an array")
	}
	if len(feed.Entries) > 10000 {
		return feedRelease{}, fmt.Errorf("entries must contain at most 10000 rows")
	}
	seen := map[string]struct{}{}
	for i, entry := range feed.Entries {
		if err := validateContinuousBatchingPolicyEntry(feed, i, entry); err != nil {
			return feedRelease{}, err
		}
		if _, ok := seen[entry.TupleSHA256]; ok {
			return feedRelease{}, fmt.Errorf("entries[%d].tuple_sha256 duplicates another entry", i)
		}
		seen[entry.TupleSHA256] = struct{}{}
	}
	return release, nil
}

func validateContinuousBatchingPolicyEntry(feed continuousBatchingPolicyFeed, index int, entry continuousBatchingPolicyEntry) error {
	label := fmt.Sprintf("entries[%d]", index)
	if !lowerHex64Pattern.MatchString(entry.TupleSHA256) {
		return fmt.Errorf("%s.tuple_sha256 must be lowercase 64-hex", label)
	}
	if err := validateModelKey(entry.ModelKey); err != nil {
		return fmt.Errorf("%s.model_key: %w", label, err)
	}
	if entry.ModelID != entry.ModelKey {
		return fmt.Errorf("%s.model_id must equal model_key", label)
	}
	if !lowerHex64Pattern.MatchString(entry.ModelSHA256) {
		return fmt.Errorf("%s.model_sha256 must be lowercase 64-hex", label)
	}
	if !lowerHex64Pattern.MatchString(entry.TokenizerSHA256) {
		return fmt.Errorf("%s.tokenizer_sha256 must be lowercase 64-hex", label)
	}
	if !lowerHex64Pattern.MatchString(entry.ChatTemplateSHA256) {
		return fmt.Errorf("%s.chat_template_sha256 must be lowercase 64-hex", label)
	}
	if _, ok := continuousBatchingPolicyCacheClasses[entry.CacheClass]; !ok {
		return fmt.Errorf("%s.cache_class must be KVCacheSimple or mixed", label)
	}
	if entry.KVDType != "fp16" && entry.KVDType != "bf16" {
		return fmt.Errorf("%s.kv_dtype must be fp16 or bf16", label)
	}
	if entry.RequiresMoE == nil {
		return fmt.Errorf("%s.requires_moe is required", label)
	}
	if strings.TrimSpace(entry.HardwareClass) == "" || strings.TrimSpace(entry.HardwareClass) != entry.HardwareClass {
		return fmt.Errorf("%s.hardware_class must be a non-empty trimmed string", label)
	}
	if !lowerHex64Pattern.MatchString(entry.MetallibSHA256) {
		return fmt.Errorf("%s.metallib_sha256 must be lowercase 64-hex", label)
	}
	if strings.TrimSpace(entry.KernelIdentifier) == "" || strings.TrimSpace(entry.KernelIdentifier) != entry.KernelIdentifier {
		return fmt.Errorf("%s.kernel_identifier must be a non-empty trimmed string", label)
	}
	switch entry.Rollout {
	case "off", "canary", "on":
	default:
		return fmt.Errorf("%s.rollout must be off, canary, or on", label)
	}
	if entry.CachedTurnsAccepted == nil {
		return fmt.Errorf("%s.cached_turns_accepted is required", label)
	}
	if entry.Provenance == nil {
		return fmt.Errorf("%s.provenance is required", label)
	}
	if err := validateContinuousBatchingPolicyProvenance(label+".provenance", *entry.Provenance); err != nil {
		return err
	}
	expectedTupleSHA, err := continuousBatchingTupleSHA256(feed, entry)
	if err != nil {
		return fmt.Errorf("%s.tuple_sha256: %w", label, err)
	}
	if entry.TupleSHA256 != expectedTupleSHA {
		return fmt.Errorf("%s.tuple_sha256 must equal canonical tuple identity %q", label, expectedTupleSHA)
	}
	return nil
}

func validateContinuousBatchingPolicyProvenance(label string, provenance continuousBatchingPolicyProvenance) error {
	switch provenance.Source {
	case "packaged_studio_campaign", "release_review", "operator_review":
	default:
		return fmt.Errorf("%s.source must be a supported source", label)
	}
	if provenance.Status != "qualified" {
		return fmt.Errorf("%s.status must be qualified", label)
	}
	for field, value := range map[string]string{
		"evidence_id":          provenance.EvidenceID,
		"provider_cli_version": provenance.ProviderCLIVersion,
	} {
		if strings.TrimSpace(value) == "" || strings.TrimSpace(value) != value {
			return fmt.Errorf("%s.%s must be a non-empty trimmed string", label, field)
		}
	}
	for field, value := range map[string]string{
		"package_manifest_sha256": provenance.PackageManifestSHA256,
		"studio_campaign_sha256":  provenance.StudioCampaignSHA256,
	} {
		if !lowerHex64Pattern.MatchString(value) {
			return fmt.Errorf("%s.%s must be lowercase 64-hex", label, field)
		}
	}
	if !lowerHex40Pattern.MatchString(provenance.LiveExecutableCDHash) {
		return fmt.Errorf("%s.live_executable_cdhash must be lowercase 40-hex", label)
	}
	return nil
}

func continuousBatchingTupleSHA256(feed continuousBatchingPolicyFeed, entry continuousBatchingPolicyEntry) (string, error) {
	entryWithoutDigest := map[string]any{
		"model_key":             entry.ModelKey,
		"model_id":              entry.ModelID,
		"model_sha256":          entry.ModelSHA256,
		"tokenizer_sha256":      entry.TokenizerSHA256,
		"chat_template_sha256":  entry.ChatTemplateSHA256,
		"cache_class":           entry.CacheClass,
		"kv_dtype":              entry.KVDType,
		"requires_moe":          *entry.RequiresMoE,
		"hardware_class":        entry.HardwareClass,
		"metallib_sha256":       entry.MetallibSHA256,
		"kernel_identifier":     entry.KernelIdentifier,
		"rollout":               entry.Rollout,
		"cached_turns_accepted": *entry.CachedTurnsAccepted,
		"provenance": map[string]any{
			"source":                  entry.Provenance.Source,
			"status":                  entry.Provenance.Status,
			"evidence_id":             entry.Provenance.EvidenceID,
			"package_manifest_sha256": entry.Provenance.PackageManifestSHA256,
			"studio_campaign_sha256":  entry.Provenance.StudioCampaignSHA256,
			"provider_cli_version":    entry.Provenance.ProviderCLIVersion,
			"live_executable_cdhash":  entry.Provenance.LiveExecutableCDHash,
		},
	}
	identity := map[string]any{
		"schema_version":           "macprovider.continuous-batching-policy-tuple.v1",
		"release_id":               feed.ReleaseID,
		"policy_version":           feed.PolicyVersion,
		"generated_at":             feed.GeneratedAt,
		"expires_at":               feed.ExpiresAt,
		"candidate_catalog_sha256": feed.CandidateCatalogSHA256,
		"signer_key_id":            feed.SignerKeyID,
		"entry":                    entryWithoutDigest,
	}
	canonical, err := json.Marshal(identity)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(append([]byte("macprovider.continuous-batching-policy-tuple.v1\n"), canonical...))
	return hex.EncodeToString(sum[:]), nil
}

func bindContinuousBatchingPolicyFeed(policy, candidates loadedAutotuneFeed) error {
	if policy.verification.Version != candidates.verification.Version {
		return fmt.Errorf("autotune feed release mismatch: continuous_batching_policy release_id %q != autotune_candidates version %q",
			policy.verification.Version, candidates.verification.Version)
	}
	if policy.verification.PolicyVersion != candidates.verification.PolicyVersion {
		return fmt.Errorf("autotune feed release mismatch: continuous_batching_policy policy_version %q != autotune_candidates policy_version %q",
			policy.verification.PolicyVersion, candidates.verification.PolicyVersion)
	}
	if !policy.verification.GeneratedAt.Equal(candidates.verification.GeneratedAt) {
		return fmt.Errorf("autotune feed release mismatch: continuous_batching_policy generated_at %q != autotune_candidates generated_at %q",
			policy.verification.GeneratedAt.Format(time.RFC3339), candidates.verification.GeneratedAt.Format(time.RFC3339))
	}
	if policy.verification.KeyID != candidates.verification.KeyID {
		return fmt.Errorf("autotune.continuous_batching_policy signer key_id %q != autotune_candidates signer key_id %q",
			policy.verification.KeyID, candidates.verification.KeyID)
	}
	var feed continuousBatchingPolicyFeed
	if err := decodeStrictJSON(policy.jsonBytes, &feed); err != nil {
		return fmt.Errorf("autotune.continuous_batching_policy schema: %w", err)
	}
	if feed.CandidateCatalogSHA256 != candidates.verification.SHA256 {
		return fmt.Errorf("autotune.continuous_batching_policy candidate_catalog_sha256 %q does not match the served autotune_candidates bytes %q",
			feed.CandidateCatalogSHA256, candidates.verification.SHA256)
	}
	var catalog candidateCatalogFeed
	if err := decodeStrictJSON(candidates.jsonBytes, &catalog); err != nil {
		return fmt.Errorf("autotune.autotune_candidates schema: %w", err)
	}
	if feed.GeneratedAt != catalog.GeneratedAt {
		return fmt.Errorf("autotune feed release mismatch: continuous_batching_policy generated_at %q is not the candidate catalog's exact stamp %q",
			feed.GeneratedAt, catalog.GeneratedAt)
	}
	for i, entry := range feed.Entries {
		row, ok := catalog.Rows[entry.ModelKey]
		if !ok {
			return fmt.Errorf("autotune.continuous_batching_policy entries[%d] model_key %q is absent from the candidate catalog", i, entry.ModelKey)
		}
		if row.ModelSHA256 == nil || *row.ModelSHA256 != entry.ModelSHA256 {
			return fmt.Errorf("autotune.continuous_batching_policy entries[%d] model_sha256 does not match candidate row", i)
		}
		switch row.RuntimeStatus {
		case "candidate", "listed", "recommendable":
		default:
			return fmt.Errorf("autotune.continuous_batching_policy entries[%d] runtime_status %q is not eligible", i, row.RuntimeStatus)
		}
	}
	return nil
}
