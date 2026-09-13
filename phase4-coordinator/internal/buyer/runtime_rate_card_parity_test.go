package buyer

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

func TestRuntimeRateCardParityNoSignedFeedIsNoop(t *testing.T) {
	rewards := runtimeParityRewards(map[string]config.RateCardEntry{
		"default": runtimeParityEntry(1, 1, 1),
	})
	if err := ValidateRuntimeRateCardParity(AutotuneFeeds{}, rewards, 2.5); err != nil {
		t.Fatalf("ValidateRuntimeRateCardParity no feed: %v", err)
	}
}

func TestRuntimeRateCardParityAcceptsMatchingSignedFeed(t *testing.T) {
	rewards := runtimeParityRewards(map[string]config.RateCardEntry{
		"default":                 runtimeParityEntry(100, 100, 200),
		"meta-llama/llama-3.1-8b": runtimeParityEntry(300, 150, 600),
	})
	feeds := runtimeParityFeeds(t, rewards, 1.25)
	if err := ValidateRuntimeRateCardParity(feeds, rewards, 1.25); err != nil {
		t.Fatalf("ValidateRuntimeRateCardParity matching feed: %v", err)
	}
}

func TestRuntimeRateCardParityRejectsRowKeyDrift(t *testing.T) {
	base := runtimeParityRewards(map[string]config.RateCardEntry{
		"default":                 runtimeParityEntry(100, 100, 200),
		"meta-llama/llama-3.1-8b": runtimeParityEntry(300, 150, 600),
	})
	feeds := runtimeParityFeeds(t, base, 1.0)

	missing := runtimeParityRewards(map[string]config.RateCardEntry{
		"default": runtimeParityEntry(100, 100, 200),
	})
	if err := ValidateRuntimeRateCardParity(feeds, missing, 1.0); err == nil || !strings.Contains(err.Error(), "missing signed row") {
		t.Fatalf("missing row error=%v, want missing signed row", err)
	}

	extra := runtimeParityRewards(map[string]config.RateCardEntry{
		"default":                 runtimeParityEntry(100, 100, 200),
		"meta-llama/llama-3.1-8b": runtimeParityEntry(300, 150, 600),
		"openai/gpt-oss-20b":      runtimeParityEntry(700, 700, 800),
	})
	if err := ValidateRuntimeRateCardParity(feeds, extra, 1.0); err == nil || !strings.Contains(err.Error(), "extra projected row") {
		t.Fatalf("extra row error=%v, want extra projected row", err)
	}
}

func TestRuntimeRateCardParityRejectsExactAliasOverrideDrift(t *testing.T) {
	base := runtimeParityRewards(map[string]config.RateCardEntry{
		"default":                 runtimeParityEntry(100, 100, 200),
		"meta-llama/llama-3.1-8b": runtimeParityEntry(300, 150, 600),
	})
	feeds := runtimeParityFeeds(t, base, 1.0)

	aliasDrift := runtimeParityRewards(map[string]config.RateCardEntry{
		"default":                 runtimeParityEntry(100, 100, 200),
		"meta-llama/llama-3.1-8b": runtimeParityEntry(300, 150, 600),
		"llama-3.1-8b":            runtimeParityEntry(301, 150, 600),
	})
	if err := ValidateRuntimeRateCardParity(feeds, aliasDrift, 1.0); err == nil || !strings.Contains(err.Error(), "exact alias") {
		t.Fatalf("alias drift error=%v, want exact alias rejection", err)
	}

	aliasSame := runtimeParityRewards(map[string]config.RateCardEntry{
		"default":                 runtimeParityEntry(100, 100, 200),
		"meta-llama/llama-3.1-8b": runtimeParityEntry(300, 150, 600),
		"llama-3.1-8b":            runtimeParityEntry(300, 150, 600),
	})
	if err := ValidateRuntimeRateCardParity(feeds, aliasSame, 1.0); err != nil {
		t.Fatalf("identical alias should be tolerated: %v", err)
	}
}

func TestRuntimeRateCardParityRejectsAliasOnlyCanonicalSettlementDrift(t *testing.T) {
	rewards := runtimeParityRewards(map[string]config.RateCardEntry{
		"default":      runtimeParityEntry(100, 100, 200),
		"llama-3.1-8b": runtimeParityEntry(300, 150, 600),
	})
	feeds := runtimeParityFeeds(t, rewards, 1.0)
	if err := ValidateRuntimeRateCardParity(feeds, rewards, 1.0); err == nil || !strings.Contains(err.Error(), "no exact settlement row") {
		t.Fatalf("alias-only canonical settlement error=%v, want exact settlement row rejection", err)
	}
}

func TestRuntimeRateCardParityRejectsAliasOnlyCanonicalEvenWhenDefaultMatches(t *testing.T) {
	rewards := runtimeParityRewards(map[string]config.RateCardEntry{
		"default":      runtimeParityEntry(300, 150, 600),
		"llama-3.1-8b": runtimeParityEntry(300, 150, 600),
	})
	feeds := runtimeParityFeeds(t, rewards, 1.0)
	if err := ValidateRuntimeRateCardParity(feeds, rewards, 1.0); err == nil || !strings.Contains(err.Error(), "no exact settlement row") {
		t.Fatalf("alias-only canonical with matching default error=%v, want exact settlement row rejection", err)
	}
}

func TestRuntimeRateCardParityRejectsRateDrift(t *testing.T) {
	base := runtimeParityRewards(map[string]config.RateCardEntry{
		"default":                 runtimeParityEntry(100, 100, 200),
		"meta-llama/llama-3.1-8b": runtimeParityEntry(300, 150, 600),
	})
	feeds := runtimeParityFeeds(t, base, 1.0)
	cases := []struct {
		name string
		row  config.RateCardEntry
	}{
		{"prompt", runtimeParityEntry(301, 150, 600)},
		{"cache", runtimeParityEntry(300, 151, 600)},
		{"completion", runtimeParityEntry(300, 150, 601)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			drift := runtimeParityRewards(map[string]config.RateCardEntry{
				"default":                 runtimeParityEntry(100, 100, 200),
				"meta-llama/llama-3.1-8b": tc.row,
			})
			if err := ValidateRuntimeRateCardParity(feeds, drift, 1.0); err == nil || !strings.Contains(err.Error(), "row") {
				t.Fatalf("rate drift error=%v, want row mismatch", err)
			}
		})
	}
}

func TestRuntimeRateCardParityRejectsGlobalEconomicsDrift(t *testing.T) {
	base := runtimeParityRewards(map[string]config.RateCardEntry{
		"default":                 runtimeParityEntry(100, 100, 200),
		"meta-llama/llama-3.1-8b": runtimeParityEntry(300, 150, 600),
	})
	feeds := runtimeParityFeeds(t, base, 1.0)

	share := base
	share.ProviderShare = 0.91
	if err := ValidateRuntimeRateCardParity(feeds, share, 1.0); err == nil || !strings.Contains(err.Error(), "provider_share_bps") {
		t.Fatalf("provider share drift error=%v, want provider_share_bps", err)
	}

	multiplier := base
	multiplier.GlobalMultiplier = 1.1
	if err := ValidateRuntimeRateCardParity(feeds, multiplier, 1.0); err == nil || !strings.Contains(err.Error(), "global_multiplier_ppm") {
		t.Fatalf("global multiplier drift error=%v, want global_multiplier_ppm", err)
	}

	if err := ValidateRuntimeRateCardParity(feeds, base, 2.0); err == nil || !strings.Contains(err.Error(), "usd_per_million_credits") {
		t.Fatalf("usd drift error=%v, want usd_per_million_credits", err)
	}
}

func TestRuntimeRateCardParityRejectsMalformedRateCardBytes(t *testing.T) {
	feeds := AutotuneFeeds{RateCardJSON: []byte(`{"version":`), RateCardSig: []byte("sig")}
	rewards := runtimeParityRewards(map[string]config.RateCardEntry{"default": runtimeParityEntry(1, 1, 1)})
	if err := ValidateRuntimeRateCardParity(feeds, rewards, 1.0); err == nil || !strings.Contains(err.Error(), "malformed") {
		t.Fatalf("malformed feed error=%v, want malformed", err)
	}
}

func runtimeParityRewards(rows map[string]config.RateCardEntry) config.RewardsConfig {
	return config.RewardsConfig{ProviderShare: 0.90, GlobalMultiplier: 1.0, RateCard: rows}
}

func runtimeParityEntry(prompt, cacheHit, completion int64) config.RateCardEntry {
	var entry config.RateCardEntry
	entry.PromptCreditsPerMtok = prompt
	entry.SetPromptCacheHitCreditsPerMtok(cacheHit)
	entry.CompletionCreditsPerMtok = completion
	return entry
}

func runtimeParityFeeds(t *testing.T, rewards config.RewardsConfig, usd float64) AutotuneFeeds {
	t.Helper()
	providerShareBPS := int64(9000)
	globalMultiplierPPM := int64(1000000)
	rows := buildRecommendationRateCardRows(rewards)
	feed := struct {
		Version              string                               `json:"version"`
		PolicyVersion        string                               `json:"policy_version"`
		GeneratedAt          string                               `json:"generated_at"`
		USDPerMillionCredits float64                              `json:"usd_per_million_credits"`
		Rows                 map[string]recommendationRateCardRow `json:"rows"`
	}{
		Version:              recommendationRateCardVersion(rows, providerShareBPS, globalMultiplierPPM, usd),
		PolicyVersion:        "autotune-policy-v1",
		GeneratedAt:          "2026-07-10T00:00:00Z",
		USDPerMillionCredits: usd,
		Rows:                 rows,
	}
	raw, err := json.Marshal(feed)
	if err != nil {
		t.Fatalf("marshal rate-card feed: %v", err)
	}
	if _, err := validateRateCardFeed(raw, ""); err != nil {
		t.Fatalf("test feed invalid: %v\n%s", err, raw)
	}
	return AutotuneFeeds{RateCardJSON: raw, RateCardSig: []byte("test-signature")}
}
