package router

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	openRouterModelsPath        = "/v1/openrouter/models"
	openRouterSchemaVersion     = "2.4"
	openRouterLlama3BPaidID     = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	openRouterLlama3BFreeID     = "mlx-community/Llama-3.2-3B-Instruct-4bit-free"
	openRouterLlama3BCatalogKey = "meta-llama/llama-3.2-3b-instruct"
	openRouterQwen8BID          = "mlx-community/Qwen3-8B-4bit"
	openRouterQwen8BCatalogKey  = "qwen3-8b"
	openRouterRateCardMaxBytes  = 4 << 20
)

type openRouterListingSpec struct {
	PoolID           string
	FreeID           string
	CatalogKey       string
	Name             string
	HuggingFaceID    string
	MinWarmProviders int
	DualFree         bool
}

var openRouterListings = []openRouterListingSpec{
	{
		PoolID:           openRouterLlama3BPaidID,
		FreeID:           openRouterLlama3BFreeID,
		CatalogKey:       openRouterLlama3BCatalogKey,
		Name:             "Llama 3.2 3B Instruct (4-bit)",
		HuggingFaceID:    openRouterLlama3BPaidID,
		MinWarmProviders: 1,
		DualFree:         true,
	},
	{
		PoolID:           openRouterQwen8BID,
		CatalogKey:       openRouterQwen8BCatalogKey,
		Name:             "Qwen3 8B (4-bit)",
		HuggingFaceID:    openRouterQwen8BID,
		MinWarmProviders: 2,
	},
}

type openRouterModelsDocument struct {
	SchemaVersion string               `json:"schema_version"`
	Data          []openRouterModelV24 `json:"data"`
}

type openRouterModelV24 struct {
	ID              string                 `json:"id"`
	Name            string                 `json:"name"`
	Created         int64                  `json:"created"`
	Architecture    openRouterArchitecture `json:"architecture"`
	ContextLength   int                    `json:"context_length"`
	Quantization    string                 `json:"quantization"`
	HuggingFaceID   string                 `json:"hugging_face_id"`
	IsReady         bool                   `json:"is_ready"`
	IsFree          bool                   `json:"is_free"`
	CostUSD         openRouterCostUSD      `json:"cost_usd"`
	Compliance      openRouterCompliance   `json:"compliance"`
	SupportedParams []string               `json:"supported_parameters"`
}

type openRouterArchitecture struct {
	InputModalities  []string `json:"input_modalities"`
	OutputModalities []string `json:"output_modalities"`
	Modality         string   `json:"modality"`
}

type openRouterCostUSD struct {
	Prompt     string `json:"prompt"`
	Completion string `json:"completion"`
}

type openRouterCompliance struct {
	ZDR bool `json:"zdr"`
}

type openRouterRateCard struct {
	USDPerMillionCredits float64                          `json:"usd_per_million_credits"`
	Rows                 map[string]openRouterRateCardRow `json:"rows"`
}

type openRouterRateCardRow struct {
	PromptRatePerMtok     int64 `json:"prompt_rate_per_mtok"`
	CompletionRatePerMtok int64 `json:"completion_rate_per_mtok"`
}

type openRouterPoolSnapshot struct {
	ID                 string
	ReadyProviderCount int
	SlotsFree          int
	MaxContextTokens   int
}

func (s *Server) handleOpenRouterModels(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	status, err := s.statusFromPoolz(r.Context())
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	rateCard, err := s.fetchOpenRouterRateCard(r)
	if err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_rate_card_error", "Coordinator rate-card error")
		return
	}
	pool := make([]openRouterPoolSnapshot, 0, len(status.Models))
	for _, model := range status.Models {
		pool = append(pool, openRouterPoolSnapshot{
			ID:                 model.ID,
			ReadyProviderCount: model.ReadyProviderCount,
			SlotsFree:          model.SlotsFree,
			MaxContextTokens:   model.MaxContextTokens,
		})
	}
	doc := projectOpenRouterModels(pool, rateCard, s.now())
	if r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "public, max-age=15")
		w.WriteHeader(http.StatusOK)
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=15")
	writeJSON(w, http.StatusOK, doc)
}

func (s *Server) fetchOpenRouterRateCard(r *http.Request) (openRouterRateCard, error) {
	upReq, err := http.NewRequestWithContext(r.Context(), http.MethodGet, strings.TrimRight(s.coordinatorBuyerURL(), "/")+"/v1/rate-card", nil)
	if err != nil {
		return openRouterRateCard{}, err
	}
	upReq.Header.Set("X-Request-ID", requestID(r))
	resp, err := s.client.Do(upReq)
	if err != nil {
		return openRouterRateCard{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return openRouterRateCard{}, fmt.Errorf("rate-card status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, openRouterRateCardMaxBytes+1))
	if err != nil {
		return openRouterRateCard{}, err
	}
	if int64(len(body)) > openRouterRateCardMaxBytes {
		return openRouterRateCard{}, fmt.Errorf("rate-card too large")
	}
	var card openRouterRateCard
	if err := json.Unmarshal(body, &card); err != nil {
		return openRouterRateCard{}, err
	}
	return card, nil
}

func projectOpenRouterModels(pool []openRouterPoolSnapshot, rateCard openRouterRateCard, now time.Time) openRouterModelsDocument {
	byID := make(map[string]openRouterPoolSnapshot, len(pool))
	for _, model := range pool {
		byID[model.ID] = model
	}
	created := now.UTC().Unix()
	data := make([]openRouterModelV24, 0, 4)
	for _, listing := range openRouterListings {
		live, ok := byID[listing.PoolID]
		if !ok || live.ReadyProviderCount < listing.MinWarmProviders {
			continue
		}
		ready := live.SlotsFree > 0
		contextLength := live.MaxContextTokens
		if contextLength < 1 {
			contextLength = 8192
		}
		paidCost := costUSDFromRateCard(rateCard, listing.CatalogKey)
		data = append(data, openRouterModelRow(listing, listing.PoolID, false, ready, contextLength, paidCost, created))
		if listing.DualFree && listing.FreeID != "" {
			freeCost := openRouterCostUSD{Prompt: "0", Completion: "0"}
			data = append(data, openRouterModelRow(listing, listing.FreeID, true, ready, contextLength, freeCost, created))
		}
	}
	return openRouterModelsDocument{SchemaVersion: openRouterSchemaVersion, Data: data}
}

func openRouterModelRow(listing openRouterListingSpec, id string, isFree, ready bool, contextLength int, cost openRouterCostUSD, created int64) openRouterModelV24 {
	name := listing.Name
	if isFree {
		name += " (free)"
	}
	return openRouterModelV24{
		ID:            id,
		Name:          name,
		Created:       created,
		Architecture:  openRouterArchitecture{InputModalities: []string{"text"}, OutputModalities: []string{"text"}, Modality: "text->text"},
		ContextLength: contextLength,
		Quantization:  "int4",
		HuggingFaceID: listing.HuggingFaceID,
		IsReady:       ready,
		IsFree:        isFree,
		CostUSD:       cost,
		Compliance:    openRouterCompliance{ZDR: false},
		SupportedParams: []string{
			"max_tokens", "temperature", "top_p", "stop", "stream", "presence_penalty", "frequency_penalty", "seed",
		},
	}
}

func costUSDFromRateCard(card openRouterRateCard, catalogKey string) openRouterCostUSD {
	row, ok := card.Rows[catalogKey]
	if !ok {
		return openRouterCostUSD{Prompt: "0", Completion: "0"}
	}
	usd := card.USDPerMillionCredits
	if usd <= 0 {
		usd = 1
	}
	return openRouterCostUSD{
		Prompt:     formatUSDPerToken(row.PromptRatePerMtok, usd),
		Completion: formatUSDPerToken(row.CompletionRatePerMtok, usd),
	}
}

func formatUSDPerToken(creditsPerMtok int64, usdPerMillionCredits float64) string {
	if creditsPerMtok <= 0 || usdPerMillionCredits <= 0 {
		return "0"
	}
	// 1 credit = $0.000001 when usd_per_million_credits is 1.0.
	// USD/token = credits_per_mtok * usd_per_million_credits / 1e12
	perToken := float64(creditsPerMtok) * usdPerMillionCredits / 1e12
	s := strconv.FormatFloat(perToken, 'f', 16, 64)
	s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	if s == "" || s == "-0" {
		return "0"
	}
	return s
}
