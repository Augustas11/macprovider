package buyer

import (
	"encoding/json"
	"strings"
	"testing"
)

// SPEC-038 FR-CB11 (v0.3.22): an entry may carry an optional signed
// max_served_slots in 1..32. Absent keeps the pre-v0.3.22 tuple identity; the
// digests below are the ones scripts/catalog-release.py derives for the same
// entry (and the CLI test ContinuousBatchingSignedPolicyTests pins too).
const (
	cbGoldenTupleWithoutCeiling = "88f96ab3ba6525df8ae0324215ed13132588299145df3cf74f09cf713e35d644"
	cbGoldenTupleWithCeiling4   = "569a8148ef6551eeb0f63b68c13ced37a20d79396bcddb52c2357582a6f69596"
)

func cbCeilingFixture() (continuousBatchingPolicyFeed, continuousBatchingPolicyEntry) {
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
		CacheClass:          "mixed",
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
	return feed, entry
}

func TestContinuousBatchingPolicyMaxServedSlotsTupleIdentity(t *testing.T) {
	feed, entry := cbCeilingFixture()
	digest, err := continuousBatchingTupleSHA256(feed, entry)
	if err != nil {
		t.Fatal(err)
	}
	if digest != cbGoldenTupleWithoutCeiling {
		t.Fatalf("absent ceiling changed the tuple identity: %s", digest)
	}
	entry.MaxServedSlots = json.RawMessage("4")
	digest, err = continuousBatchingTupleSHA256(feed, entry)
	if err != nil {
		t.Fatal(err)
	}
	if digest != cbGoldenTupleWithCeiling4 {
		t.Fatalf("ceiling tuple identity %s != generator golden", digest)
	}
}

func TestContinuousBatchingPolicyMaxServedSlotsValidation(t *testing.T) {
	// raw builds the feed with max_served_slots spliced in as literal JSON,
	// signing the digest over what the decoder will see.
	raw := func(literal string, sign bool) []byte {
		feed, entry := cbCeilingFixture()
		if sign {
			entry.MaxServedSlots = json.RawMessage(literal)
		}
		digest, err := continuousBatchingTupleSHA256(feed, entry)
		if err != nil {
			if !sign {
				t.Fatal(err)
			}
			// An invalid ceiling has no identity; sign the entry without it.
			entry.MaxServedSlots = nil
			if digest, err = continuousBatchingTupleSHA256(feed, entry); err != nil {
				t.Fatal(err)
			}
		}
		entry.TupleSHA256 = digest
		entry.MaxServedSlots = nil
		feed.Entries = []continuousBatchingPolicyEntry{entry}
		encoded, err := json.Marshal(feed)
		if err != nil {
			t.Fatal(err)
		}
		if literal == "" {
			return encoded
		}
		return []byte(strings.Replace(string(encoded), `"provenance":`, `"max_served_slots":`+literal+`,"provenance":`, 1))
	}
	if _, err := validateContinuousBatchingPolicyFeed(raw("", false), "test-key"); err != nil {
		t.Fatalf("entry without a ceiling rejected: %v", err)
	}
	for _, ok := range []string{"1", "4", "32"} {
		if _, err := validateContinuousBatchingPolicyFeed(raw(ok, true), "test-key"); err != nil {
			t.Fatalf("max_served_slots %s rejected: %v", ok, err)
		}
	}
	for _, bad := range []string{"0", "-1", "33"} {
		_, err := validateContinuousBatchingPolicyFeed(raw(bad, true), "test-key")
		if err == nil || !strings.Contains(err.Error(), "max_served_slots") {
			t.Fatalf("max_served_slots %s accepted or wrong error: %v", bad, err)
		}
	}
	for _, bad := range []string{"4.5", "4.0", "true", `"4"`, "1e1", "04", "null"} {
		if _, err := validateContinuousBatchingPolicyFeed(raw(bad, false), "test-key"); err == nil {
			t.Fatalf("max_served_slots %s accepted", bad)
		}
	}
	// A ceiling added after signing breaks the tuple identity.
	if _, err := validateContinuousBatchingPolicyFeed(raw("4", false), "test-key"); err == nil ||
		!strings.Contains(err.Error(), "tuple_sha256") {
		t.Fatalf("unsigned ceiling accepted or wrong error: %v", err)
	}
}
