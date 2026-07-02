package buyer

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
)

type recommendationRateCardResponse struct {
	Version              string                               `json:"version"`
	GeneratedAt          string                               `json:"generated_at"`
	USDPerMillionCredits float64                              `json:"usd_per_million_credits"`
	Rows                 map[string]recommendationRateCardRow `json:"rows"`
}

type recommendationRateCardRow struct {
	PromptRatePerMtok         int64 `json:"prompt_rate_per_mtok"`
	PromptCacheHitRatePerMtok int64 `json:"prompt_cache_hit_rate_per_mtok"`
	CompletionRatePerMtok     int64 `json:"completion_rate_per_mtok"`
	ProviderShareBPS          int64 `json:"provider_share_bps"`
	GlobalMultiplierPPM       int64 `json:"global_multiplier_ppm"`
}

type recommendationRateCardVersionProjection struct {
	GlobalMultiplierPPM  int64                                `json:"global_multiplier_ppm"`
	ProviderShareBPS     int64                                `json:"provider_share_bps"`
	Rows                 map[string]recommendationRateCardRow `json:"rows"`
	USDPerMillionCredits json.RawMessage                      `json:"usd_per_million_credits"`
}

func (s *Server) handleRateCard(w http.ResponseWriter, r *http.Request) {
	rewards, usdPerMillionCredits := s.recommendationRateCardState()
	rows := buildRecommendationRateCardRows(rewards)
	version := recommendationRateCardVersion(rows, billing.ParseShareBps(rewards.ProviderShare), billing.ParseMultiplierPPM(rewards.GlobalMultiplier), usdPerMillionCredits)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(recommendationRateCardResponse{
		Version:              version,
		GeneratedAt:          s.now().UTC().Format(time.RFC3339),
		USDPerMillionCredits: usdPerMillionCredits,
		Rows:                 rows,
	})
}

func buildRecommendationRateCardRows(rewards config.RewardsConfig) map[string]recommendationRateCardRow {
	rows := make(map[string]recommendationRateCardRow, len(rewards.RateCard))
	providerShareBPS := billing.ParseShareBps(rewards.ProviderShare)
	globalMultiplierPPM := billing.ParseMultiplierPPM(rewards.GlobalMultiplier)
	keys := make([]string, 0, len(rewards.RateCard))
	for key := range rewards.RateCard {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	for _, key := range keys {
		normalized := recommendationRateCardProjectionKey(key)
		if normalized == "" {
			continue
		}
		if normalized != key {
			continue
		}
		rows[normalized] = recommendationRateCardRowFromEntry(rewards.RateCard[key], providerShareBPS, globalMultiplierPPM)
	}
	for _, key := range keys {
		normalized := recommendationRateCardProjectionKey(key)
		if normalized == "" {
			continue
		}
		if _, exists := rows[normalized]; exists {
			continue
		}
		rows[normalized] = recommendationRateCardRowFromEntry(rewards.RateCard[key], providerShareBPS, globalMultiplierPPM)
	}
	return rows
}

func recommendationRateCardProjectionKey(key string) string {
	if key == "default" {
		return key
	}
	normalized := billing.NormalizeModelKey(key)
	if normalized == "default" {
		return ""
	}
	return normalized
}

func recommendationRateCardRowFromEntry(entry config.RateCardEntry, providerShareBPS, globalMultiplierPPM int64) recommendationRateCardRow {
	return recommendationRateCardRow{
		PromptRatePerMtok:         entry.PromptCreditsPerMtok,
		PromptCacheHitRatePerMtok: entry.EffectivePromptCacheHitCreditsPerMtok(),
		CompletionRatePerMtok:     entry.CompletionCreditsPerMtok,
		ProviderShareBPS:          providerShareBPS,
		GlobalMultiplierPPM:       globalMultiplierPPM,
	}
}

func recommendationRateCardVersion(rows map[string]recommendationRateCardRow, providerShareBPS, globalMultiplierPPM int64, usdPerMillionCredits float64) string {
	b, err := canonicalRecommendationRateCardVersionBytes(rows, providerShareBPS, globalMultiplierPPM, usdPerMillionCredits)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func canonicalRecommendationRateCardVersionBytes(rows map[string]recommendationRateCardRow, providerShareBPS, globalMultiplierPPM int64, usdPerMillionCredits float64) ([]byte, error) {
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
		encodedKey, err := json.Marshal(key)
		if err != nil {
			return nil, err
		}
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
	b.WriteString(strconv.FormatFloat(usdPerMillionCredits, 'f', -1, 64))
	b.WriteByte('}')
	return []byte(b.String()), nil
}
