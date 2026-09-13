package buyer

import (
	"fmt"
	"math"
	"sort"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
)

// ValidateRuntimeRateCardParity verifies that a signed/public rate-card feed,
// when one is served, cannot drift from the effective billing configuration that
// settlement will use. LoadAutotuneFeeds remains responsible for signature,
// sidecar, and cross-release validation; this helper compares already-loaded
// feed bytes with the overlay-effective runtime config.
func ValidateRuntimeRateCardParity(feeds AutotuneFeeds, rewards config.RewardsConfig, usdPerMillionCredits float64) error {
	if !feeds.rateCardEnabled() {
		return nil
	}
	var feed rateCardFeed
	if err := decodeStrictJSON(feeds.RateCardJSON, &feed); err != nil {
		return fmt.Errorf("runtime rate-card parity: malformed signed rate-card feed: %w", err)
	}
	if _, err := validateRateCardFeed(feeds.RateCardJSON, ""); err != nil {
		return fmt.Errorf("runtime rate-card parity: signed rate-card schema: %w", err)
	}
	if feed.USDPerMillionCredits == nil {
		return fmt.Errorf("runtime rate-card parity: signed rate-card missing usd_per_million_credits")
	}
	if !sameFloat64(*feed.USDPerMillionCredits, usdPerMillionCredits) {
		return fmt.Errorf("runtime rate-card parity: usd_per_million_credits signed=%s effective=%s", formatFloat(*feed.USDPerMillionCredits), formatFloat(usdPerMillionCredits))
	}

	providerShareBPS := billing.ParseShareBps(rewards.ProviderShare)
	globalMultiplierPPM := billing.ParseMultiplierPPM(rewards.GlobalMultiplier)
	expected := buildRecommendationRateCardRows(rewards)
	published := make(map[string]recommendationRateCardRow, len(feed.Rows))
	for key, row := range feed.Rows {
		published[key] = recommendationRateCardRow{
			PromptRatePerMtok:         *row.PromptRatePerMtok,
			PromptCacheHitRatePerMtok: *row.PromptCacheHitRatePerMtok,
			CompletionRatePerMtok:     *row.CompletionRatePerMtok,
			ProviderShareBPS:          *row.ProviderShareBPS,
			GlobalMultiplierPPM:       *row.GlobalMultiplierPPM,
		}
	}
	for _, key := range sortedRateCardKeys(published) {
		row := published[key]
		if row.ProviderShareBPS != providerShareBPS {
			return fmt.Errorf("runtime rate-card parity: %s.provider_share_bps signed=%d effective=%d", key, row.ProviderShareBPS, providerShareBPS)
		}
		if row.GlobalMultiplierPPM != globalMultiplierPPM {
			return fmt.Errorf("runtime rate-card parity: %s.global_multiplier_ppm signed=%d effective=%d", key, row.GlobalMultiplierPPM, globalMultiplierPPM)
		}
	}
	if err := compareRuntimeRateCardRows(published, expected); err != nil {
		return err
	}
	if err := validateRuntimeSettlementLookupRows(rewards, published, providerShareBPS, globalMultiplierPPM); err != nil {
		return err
	}
	if err := rejectRuntimeRateCardAliasDrift(rewards, expected, providerShareBPS, globalMultiplierPPM); err != nil {
		return err
	}
	return nil
}

func compareRuntimeRateCardRows(published, expected map[string]recommendationRateCardRow) error {
	for _, key := range sortedRateCardKeys(published) {
		want, ok := expected[key]
		if !ok {
			return fmt.Errorf("runtime rate-card parity: effective rewards.rate_card missing signed row %q", key)
		}
		if published[key] != want {
			return fmt.Errorf("runtime rate-card parity: row %q signed=%+v effective=%+v", key, published[key], want)
		}
	}
	for _, key := range sortedRateCardKeys(expected) {
		if _, ok := published[key]; !ok {
			return fmt.Errorf("runtime rate-card parity: effective rewards.rate_card has extra projected row %q", key)
		}
	}
	return nil
}

func validateRuntimeSettlementLookupRows(rewards config.RewardsConfig, published map[string]recommendationRateCardRow, providerShareBPS, globalMultiplierPPM int64) error {
	for _, key := range sortedRateCardKeys(published) {
		if key == "default" {
			continue
		}
		if _, ok := rewards.RateCard[key]; !ok {
			return fmt.Errorf("runtime rate-card parity: signed row %q has no exact settlement row", key)
		}
		settlement := recommendationRateCardRowFromEntry(billing.RateFor(rewards.RateCard, key), providerShareBPS, globalMultiplierPPM)
		if settlement != published[key] {
			return fmt.Errorf("runtime rate-card parity: settlement lookup for signed row %q resolves %+v, signed %+v", key, settlement, published[key])
		}
	}
	return nil
}

func rejectRuntimeRateCardAliasDrift(rewards config.RewardsConfig, expected map[string]recommendationRateCardRow, providerShareBPS, globalMultiplierPPM int64) error {
	keys := make([]string, 0, len(rewards.RateCard))
	for key := range rewards.RateCard {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if key == "default" {
			continue
		}
		normalized := billing.NormalizeModelKey(key)
		if normalized == "" || normalized == key {
			continue
		}
		canonical, ok := expected[normalized]
		if !ok {
			return fmt.Errorf("runtime rate-card parity: exact alias %q normalizes to unsigned row %q", key, normalized)
		}
		alias := recommendationRateCardRowFromEntry(rewards.RateCard[key], providerShareBPS, globalMultiplierPPM)
		if alias != canonical {
			return fmt.Errorf("runtime rate-card parity: exact alias %q overrides signed row %q", key, normalized)
		}
	}
	return nil
}

func sortedRateCardKeys(rows map[string]recommendationRateCardRow) []string {
	keys := make([]string, 0, len(rows))
	for key := range rows {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func sameFloat64(a, b float64) bool {
	if math.IsNaN(a) || math.IsNaN(b) || math.IsInf(a, 0) || math.IsInf(b, 0) {
		return false
	}
	return a == b
}

func formatFloat(v float64) string { return fmt.Sprintf("%g", v) }
