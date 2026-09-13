package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

func TestCoordinatorRuntimeRateCardParityAcceptsBootMatch(t *testing.T) {
	cfg := config.Default()
	cfg.Rewards = coordinatorParityRewards(map[string]config.RateCardEntry{
		"default":                 coordinatorParityEntry(100, 100, 200),
		"meta-llama/llama-3.1-8b": coordinatorParityEntry(300, 150, 600),
	})
	cfg.Stats.Rollup.UsdPerMillionCredits = 1.25
	feeds := coordinatorParityFeeds(t, cfg.Rewards, 1.25)

	if err := validateAutotuneRuntimeEconomics(feeds, cfg); err != nil {
		t.Fatalf("validateAutotuneRuntimeEconomics matching boot config: %v", err)
	}
}

func TestCoordinatorRuntimeRateCardParityRejectsBootOverlayDrift(t *testing.T) {
	cfg := config.Default()
	cfg.Rewards = coordinatorParityRewards(map[string]config.RateCardEntry{
		"default":                 coordinatorParityEntry(100, 100, 200),
		"meta-llama/llama-3.1-8b": coordinatorParityEntry(300, 150, 600),
	})
	cfg.Stats.Rollup.UsdPerMillionCredits = 1.0
	feeds := coordinatorParityFeeds(t, cfg.Rewards, 1.0)
	cfg.Rewards.RateCard["meta-llama/llama-3.1-8b"] = coordinatorParityEntry(301, 150, 600)

	if err := validateAutotuneRuntimeEconomics(feeds, cfg); err == nil || !strings.Contains(err.Error(), "runtime rate-card parity") {
		t.Fatalf("validateAutotuneRuntimeEconomics drift error=%v, want runtime rate-card parity rejection", err)
	}
}

func TestCoordinatorSIGHUPRuntimeRateCardParityRejectsNewFeedBeforeAnyStagingOrPublication(t *testing.T) {
	cfg := config.Default()
	cfg.Rewards = coordinatorParityRewards(map[string]config.RateCardEntry{
		"default":                 coordinatorParityEntry(100, 100, 200),
		"meta-llama/llama-3.1-8b": coordinatorParityEntry(300, 150, 600),
	})
	cfg.Stats.Rollup.UsdPerMillionCredits = 1.0
	feeds := coordinatorParityFeeds(t, cfg.Rewards, 1.0)
	cfg.Rewards.ProviderShare = 0.91

	candidate := candidateAutotuneFeedsForRuntimeParity(nil, true, feeds)
	if len(candidate.RateCardJSON) == 0 {
		t.Fatal("candidate selector did not choose reloaded feed")
	}
	if err := validateAutotuneRuntimeEconomics(candidate, cfg); err == nil || !strings.Contains(err.Error(), "provider_share_bps") {
		t.Fatalf("validateAutotuneRuntimeEconomics SIGHUP drift error=%v, want provider_share_bps rejection", err)
	}
}

func TestCoordinatorSIGHUPRuntimeRateCardParityRejectsRetainedLiveFeedDrift(t *testing.T) {
	cfg := config.Default()
	cfg.Rewards = coordinatorParityRewards(map[string]config.RateCardEntry{
		"default":                 coordinatorParityEntry(100, 100, 200),
		"meta-llama/llama-3.1-8b": coordinatorParityEntry(300, 150, 600),
	})
	cfg.Stats.Rollup.UsdPerMillionCredits = 1.0
	liveFeeds := coordinatorParityFeeds(t, cfg.Rewards, 1.0)
	server := buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithAutotuneFeeds(liveFeeds), buyer.WithBilling(nil, cfg.Rewards), buyer.WithRateCardUSDPerMillionCredits(1.0))

	cfg.Rewards.RateCard["meta-llama/llama-3.1-8b"] = coordinatorParityEntry(301, 150, 600)
	candidate := candidateAutotuneFeedsForRuntimeParity(server, false, buyer.AutotuneFeeds{})
	if string(candidate.RateCardJSON) != string(liveFeeds.RateCardJSON) {
		t.Fatal("candidate selector did not choose retained live feed")
	}
	if err := validateAutotuneRuntimeEconomics(candidate, cfg); err == nil || !strings.Contains(err.Error(), "row") {
		t.Fatalf("retained feed drift error=%v, want row rejection", err)
	}
	if string(server.CurrentAutotuneFeeds().RateCardJSON) != string(liveFeeds.RateCardJSON) {
		t.Fatal("validation mutated live feed state")
	}
}

func TestCoordinatorSIGHUPRuntimeRateCardParityNoopWhenNoLiveSignedFeed(t *testing.T) {
	cfg := config.Default()
	cfg.Rewards = coordinatorParityRewards(map[string]config.RateCardEntry{"default": coordinatorParityEntry(1, 1, 1)})
	server := buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithBilling(nil, cfg.Rewards))
	candidate := candidateAutotuneFeedsForRuntimeParity(server, false, buyer.AutotuneFeeds{})
	if err := validateAutotuneRuntimeEconomics(candidate, cfg); err != nil {
		t.Fatalf("no live signed feed should no-op: %v", err)
	}
}

func TestCoordinatorSIGHUPRuntimeRateCardParityLeavesNoStagedTier2Material(t *testing.T) {
	startup := config.Default()
	startup.Rewards = coordinatorParityRewards(map[string]config.RateCardEntry{"default": coordinatorParityEntry(100, 100, 200)})
	startup.Stats.Rollup.UsdPerMillionCredits = 1.0
	liveFeeds := coordinatorParityFeeds(t, startup.Rewards, 1.0)

	startup, _, wsServer, buyerServer := reloadTestServers(startup)
	buyerServer.SetAutotuneFeeds(liveFeeds)

	next := startup
	next.Stats.Rollup.UsdPerMillionCredits = 2.0
	calledConfigure := false
	originalConfigure := configureDefaultStrict
	configureDefaultStrict = func(cfg config.Tier2Config, logger zerolog.Logger, guards ...func(*tier2.Catalog) error) (*tier2.Catalog, error) {
		calledConfigure = true
		t.Fatalf("configureDefaultStrict called before runtime rate-card parity rejection")
		return nil, nil
	}
	t.Cleanup(func() { configureDefaultStrict = originalConfigure })

	reloadTier2Config(writeReloadConfig(t, next), startup.Tier2, zerolog.Nop(), wsServer, buyerServer, nil)
	if calledConfigure {
		t.Fatal("runtime parity rejection reached Tier-2 configure/staging seam")
	}
}

func coordinatorParityRewards(rows map[string]config.RateCardEntry) config.RewardsConfig {
	return config.RewardsConfig{ProviderShare: 0.90, GlobalMultiplier: 1.0, RateCard: rows}
}

func coordinatorParityEntry(prompt, cacheHit, completion int64) config.RateCardEntry {
	var entry config.RateCardEntry
	entry.PromptCreditsPerMtok = prompt
	entry.SetPromptCacheHitCreditsPerMtok(cacheHit)
	entry.CompletionCreditsPerMtok = completion
	return entry
}

type coordinatorParityRow struct {
	PromptRatePerMtok         int64 `json:"prompt_rate_per_mtok"`
	PromptCacheHitRatePerMtok int64 `json:"prompt_cache_hit_rate_per_mtok"`
	CompletionRatePerMtok     int64 `json:"completion_rate_per_mtok"`
	ProviderShareBPS          int64 `json:"provider_share_bps"`
	GlobalMultiplierPPM       int64 `json:"global_multiplier_ppm"`
}

func coordinatorParityFeeds(t *testing.T, rewards config.RewardsConfig, usd float64) buyer.AutotuneFeeds {
	t.Helper()
	rows := coordinatorParityRows(rewards)
	feed := struct {
		Version              string                          `json:"version"`
		PolicyVersion        string                          `json:"policy_version"`
		GeneratedAt          string                          `json:"generated_at"`
		USDPerMillionCredits float64                         `json:"usd_per_million_credits"`
		Rows                 map[string]coordinatorParityRow `json:"rows"`
	}{
		Version:              coordinatorParityVersion(rows, 9000, 1000000, usd),
		PolicyVersion:        "autotune-policy-v1",
		GeneratedAt:          "2026-07-10T00:00:00Z",
		USDPerMillionCredits: usd,
		Rows:                 rows,
	}
	raw, err := json.Marshal(feed)
	if err != nil {
		t.Fatalf("marshal test feed: %v", err)
	}
	return buyer.AutotuneFeeds{RateCardJSON: raw, RateCardSig: []byte("test-signature")}
}

func coordinatorParityRows(rewards config.RewardsConfig) map[string]coordinatorParityRow {
	providerShareBPS := int64(9000)
	globalMultiplierPPM := int64(1000000)
	out := make(map[string]coordinatorParityRow, len(rewards.RateCard))
	keys := make([]string, 0, len(rewards.RateCard))
	for key := range rewards.RateCard {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		out[key] = coordinatorParityRowFromEntry(rewards.RateCard[key], providerShareBPS, globalMultiplierPPM)
	}
	return out
}

func coordinatorParityRowFromEntry(entry config.RateCardEntry, providerShareBPS, globalMultiplierPPM int64) coordinatorParityRow {
	return coordinatorParityRow{
		PromptRatePerMtok:         entry.PromptCreditsPerMtok,
		PromptCacheHitRatePerMtok: entry.EffectivePromptCacheHitCreditsPerMtok(),
		CompletionRatePerMtok:     entry.CompletionCreditsPerMtok,
		ProviderShareBPS:          providerShareBPS,
		GlobalMultiplierPPM:       globalMultiplierPPM,
	}
}

func coordinatorParityVersion(rows map[string]coordinatorParityRow, providerShareBPS, globalMultiplierPPM int64, usd float64) string {
	keys := make([]string, 0, len(rows))
	for key := range rows {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(`{"global_multiplier_ppm":`)
	b.WriteString(strconv.FormatInt(globalMultiplierPPM, 10))
	b.WriteString(`,"provider_share_bps":`)
	b.WriteString(strconv.FormatInt(providerShareBPS, 10))
	b.WriteString(`,"rows":{`)
	for i, key := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		encodedKey, _ := json.Marshal(key)
		row := rows[key]
		b.Write(encodedKey)
		b.WriteString(`:{"completion_rate_per_mtok":`)
		b.WriteString(strconv.FormatInt(row.CompletionRatePerMtok, 10))
		b.WriteString(`,"global_multiplier_ppm":`)
		b.WriteString(strconv.FormatInt(row.GlobalMultiplierPPM, 10))
		b.WriteString(`,"prompt_cache_hit_rate_per_mtok":`)
		b.WriteString(strconv.FormatInt(row.PromptCacheHitRatePerMtok, 10))
		b.WriteString(`,"prompt_rate_per_mtok":`)
		b.WriteString(strconv.FormatInt(row.PromptRatePerMtok, 10))
		b.WriteString(`,"provider_share_bps":`)
		b.WriteString(strconv.FormatInt(row.ProviderShareBPS, 10))
		b.WriteByte('}')
	}
	b.WriteString(`},"usd_per_million_credits":`)
	b.WriteString(strconv.FormatFloat(usd, 'f', -1, 64))
	b.WriteByte('}')
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}
