package buyer

import (
	"encoding/json"
	"strings"
	"testing"
)

// SPEC-023 v0.22.1: the coordinator accepts exactly the cache_class enum the
// catalog generator and the CLI accept (#1808 hybrid admission, coordinator
// half). An unknown class still fails closed.
func TestContinuousBatchingPolicyAcceptsTheSpecCacheClassEnum(t *testing.T) {
	build := func(cacheClass string) []byte {
		yes, no := true, false
		feed := continuousBatchingPolicyFeed{
			SchemaVersion:          continuousBatchingPolicySchema,
			ReleaseID:              "release-cb-1",
			PolicyVersion:          "autotune-policy-v1",
			GeneratedAt:            "2026-10-06T00:00:00Z",
			ExpiresAt:              "2026-12-25T00:00:00Z",
			CandidateCatalogSHA256: strings.Repeat("1", 64),
			SignerKeyID:            "test-key",
		}
		entry := continuousBatchingPolicyEntry{
			ModelKey:            "qwen/qwen3.6-35b-a3b",
			ModelID:             "qwen/qwen3.6-35b-a3b",
			ModelSHA256:         strings.Repeat("2", 64),
			TokenizerSHA256:     strings.Repeat("3", 64),
			ChatTemplateSHA256:  strings.Repeat("4", 64),
			CacheClass:          cacheClass,
			KVDType:             "fp16",
			RequiresMoE:         &yes,
			HardwareClass:       "apple-silicon:Apple M3 Ultra:ram-256gb",
			MetallibSHA256:      strings.Repeat("5", 64),
			KernelIdentifier:    "macprovider_paged_kv_gather_v1",
			Rollout:             "canary",
			CachedTurnsAccepted: &no,
			Provenance: &continuousBatchingPolicyProvenance{
				Source: "packaged_studio_campaign", Status: "qualified", EvidenceID: "cb-test",
				PackageManifestSHA256: strings.Repeat("6", 64), StudioCampaignSHA256: strings.Repeat("7", 64),
				ProviderCLIVersion: "1.8.220", LiveExecutableCDHash: strings.Repeat("8", 40),
			},
		}
		digest, err := continuousBatchingTupleSHA256(feed, entry)
		if err != nil {
			t.Fatal(err)
		}
		entry.TupleSHA256 = digest
		feed.Entries = []continuousBatchingPolicyEntry{entry}
		raw, err := json.Marshal(feed)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	for _, class := range []string{"KVCacheSimple", "mixed"} {
		if _, err := validateContinuousBatchingPolicyFeed(build(class), "test-key"); err != nil {
			t.Fatalf("cache_class %q rejected: %v", class, err)
		}
	}
	for _, class := range []string{"RotatingKVCache", "Mixed", "", "MambaCache"} {
		_, err := validateContinuousBatchingPolicyFeed(build(class), "test-key")
		if err == nil || !strings.Contains(err.Error(), "cache_class") {
			t.Fatalf("cache_class %q accepted or wrong error: %v", class, err)
		}
	}
}
