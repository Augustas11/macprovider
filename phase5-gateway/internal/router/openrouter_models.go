package router

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	openRouterModelsPath               = "/v1/openrouter/models"
	openRouterSchemaVersion            = "2.4"
	openRouterLlama3BCreatedAt         = 1729728000
	openRouterQwen8BCreatedAt          = 1748822400
	openRouterLlama3BPaidID            = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	openRouterLlama3BFreeID            = "mlx-community/Llama-3.2-3B-Instruct-4bit-free"
	openRouterLlama3BCatalogKey        = "meta-llama/llama-3.2-3b-instruct"
	openRouterQwen8BID                 = "mlx-community/Qwen3-8B-4bit"
	openRouterQwen8BCatalogKey         = "qwen3-8b"
	openRouterQwen8BSlug               = "qwen/qwen3-8b"
	openRouterRateCardMaxBytes         = 4 << 20
	openRouterRequestsPerMinutePerSlot = 1
	openRouterTokensPerSecondPerSlot   = 10
)

type openRouterListingSpec struct {
	PoolID           string
	FreeID           string
	CatalogKey       string
	OpenRouterSlug   string
	Name             string
	HuggingFaceID    string
	Tokenizer        string
	Created          int64
	MinWarmProviders int
	DualFree         bool
}

var openRouterListings = []openRouterListingSpec{
	{
		PoolID:           openRouterLlama3BPaidID,
		FreeID:           openRouterLlama3BFreeID,
		CatalogKey:       openRouterLlama3BCatalogKey,
		OpenRouterSlug:   openRouterLlama3BCatalogKey,
		Name:             "Llama 3.2 3B Instruct (4-bit)",
		HuggingFaceID:    openRouterLlama3BPaidID,
		Tokenizer:        "Llama3",
		Created:          openRouterLlama3BCreatedAt,
		MinWarmProviders: 1,
		DualFree:         true,
	},
	{
		PoolID:           openRouterQwen8BID,
		CatalogKey:       openRouterQwen8BCatalogKey,
		OpenRouterSlug:   openRouterQwen8BSlug,
		Name:             "Qwen3 8B (4-bit)",
		HuggingFaceID:    openRouterQwen8BID,
		Tokenizer:        "Qwen",
		Created:          openRouterQwen8BCreatedAt,
		MinWarmProviders: 2,
	},
}

type openRouterModelsDocument struct {
	Data []openRouterModelV24 `json:"data"`
}

type openRouterModelV24 struct {
	SchemaVersion    string                      `json:"schema_version"`
	ID               string                      `json:"id"`
	Name             string                      `json:"name"`
	Created          int64                       `json:"created"`
	Quantization     string                      `json:"quantization"`
	Tokenizer        string                      `json:"tokenizer,omitempty"`
	HuggingFaceID    string                      `json:"hugging_face_id"`
	InputModalities  []openRouterInputModality   `json:"input_modalities"`
	OutputModalities []openRouterOutputModality  `json:"output_modalities"`
	Capacity         []openRouterCapacityEntry   `json:"capacity"`
	DeploymentRegion string                      `json:"deployment_region"`
	Compliance       openRouterCompliance        `json:"compliance"`
	IsReady          bool                        `json:"is_ready"`
	IsFree           bool                        `json:"is_free"`
	OpenRouter       openRouterIdentityExtension `json:"openrouter"`
}

type openRouterInputModality struct {
	Type            string                     `json:"type"`
	SupportedInputs openRouterTextInputSupport `json:"supported_inputs"`
	Pricing         []openRouterPricingEntry   `json:"pricing"`
	Capacity        []openRouterCapacityEntry  `json:"capacity"`
}

type openRouterTextInputSupport struct {
	MaxContextLength openRouterIntegerLimit `json:"max_context_length"`
}

type openRouterIntegerLimit struct {
	Value int    `json:"value"`
	Unit  string `json:"unit,omitempty"`
}

type openRouterPricingEntry struct {
	Type    string `json:"type"`
	Unit    string `json:"unit"`
	CostUSD string `json:"cost_usd"`
}

type openRouterCapacityEntry struct {
	Type  string `json:"type"`
	Unit  string `json:"unit"`
	Per   string `json:"per,omitempty"`
	Value int    `json:"value"`
}

type openRouterOutputModality struct {
	Type                string                                   `json:"type"`
	MaxLength           openRouterIntegerLimit                   `json:"max_length"`
	Streaming           bool                                     `json:"streaming"`
	SupportedParameters map[string]openRouterParameterDescriptor `json:"supported_parameters"`
	Pricing             []openRouterPricingEntry                 `json:"pricing"`
	Capacity            []openRouterCapacityEntry                `json:"capacity"`
}

type openRouterParameterDescriptor struct {
	Type     string   `json:"type"`
	Min      *float64 `json:"min,omitempty"`
	Max      *float64 `json:"max,omitempty"`
	Unit     string   `json:"unit,omitempty"`
	MaxItems int      `json:"max_items,omitempty"`
}

type openRouterTextCostUSD struct {
	Prompt     string `json:"prompt"`
	Completion string `json:"completion"`
}

type openRouterCompliance struct {
	ZDR bool `json:"zdr"`
}

type openRouterIdentityExtension struct {
	Slug string `json:"slug"`
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
	ReadySlotsTotal    int
	ReadySlotsFree     int
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
			ReadySlotsTotal:    model.ReadySlotsTotal,
			ReadySlotsFree:     model.ReadySlotsFree,
			MaxContextTokens:   model.MaxContextTokens,
		})
	}
	doc, err := projectOpenRouterModels(pool, rateCard, s.now())
	if err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_rate_card_error", "Coordinator rate-card error")
		return
	}
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

func projectOpenRouterModels(pool []openRouterPoolSnapshot, rateCard openRouterRateCard, now time.Time) (openRouterModelsDocument, error) {
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
		ready := live.ReadySlotsFree > 0
		contextLength := live.MaxContextTokens
		if contextLength < 1 {
			contextLength = 8192
		}
		shareCount := 1
		if listing.DualFree && listing.FreeID != "" && openRouterBaseConcurrency(live) >= 2 {
			shareCount = 2
		}
		paidCost, err := textCostUSDFromRateCard(rateCard, listing.CatalogKey)
		if err != nil {
			return openRouterModelsDocument{}, err
		}
		data = append(data, openRouterModelRow(listing, listing.PoolID, false, ready, contextLength, live, 0, shareCount, paidCost, created))
		if shareCount == 2 {
			freeCost := openRouterTextCostUSD{Prompt: "0", Completion: "0"}
			data = append(data, openRouterModelRow(listing, listing.FreeID, true, ready, contextLength, live, 1, shareCount, freeCost, created))
		}
	}
	return openRouterModelsDocument{Data: data}, nil
}

func openRouterModelRow(listing openRouterListingSpec, id string, isFree, ready bool, contextLength int, live openRouterPoolSnapshot, shareIndex, shareCount int, cost openRouterTextCostUSD, created int64) openRouterModelV24 {
	name := listing.Name
	if isFree {
		name += " (free)"
	}
	if listing.Created > 0 {
		created = listing.Created
	}
	maxOutput := contextLength
	if maxOutput > 4096 {
		maxOutput = 4096
	}
	capacity := openRouterCapacityEntries(live, maxOutput, shareIndex, shareCount)
	return openRouterModelV24{
		SchemaVersion: openRouterSchemaVersion,
		ID:            id,
		Name:          name,
		Created:       created,
		Quantization:  "int4",
		Tokenizer:     listing.Tokenizer,
		HuggingFaceID: listing.HuggingFaceID,
		InputModalities: []openRouterInputModality{{
			Type:            "text",
			SupportedInputs: openRouterTextInputSupport{MaxContextLength: openRouterIntegerLimit{Value: contextLength, Unit: "token"}},
			Pricing:         []openRouterPricingEntry{{Type: "prompt", Unit: "token", CostUSD: cost.Prompt}},
			Capacity:        []openRouterCapacityEntry{{Type: "prompt", Unit: "token", Per: "minute", Value: capacity.TokensPerMinute}},
		}},
		OutputModalities: []openRouterOutputModality{{
			Type:                "text",
			MaxLength:           openRouterIntegerLimit{Value: maxOutput, Unit: "token"},
			Streaming:           true,
			SupportedParameters: openRouterSupportedParameters(maxOutput),
			Pricing:             []openRouterPricingEntry{{Type: "completion", Unit: "token", CostUSD: cost.Completion}},
			Capacity:            []openRouterCapacityEntry{{Type: "completion", Unit: "token", Per: "minute", Value: capacity.TokensPerMinute}},
		}},
		Capacity: []openRouterCapacityEntry{
			{Type: "request", Unit: "request", Per: "minute", Value: capacity.RequestsPerMinute},
			{Type: "concurrency", Unit: "request", Value: capacity.Concurrency},
		},
		DeploymentRegion: "global-volunteer-fleet",
		Compliance:       openRouterCompliance{ZDR: false},
		IsReady:          ready,
		IsFree:           isFree,
		OpenRouter:       openRouterIdentityExtension{Slug: openRouterSlug(listing, isFree)},
	}
}

type openRouterDerivedCapacity struct {
	Concurrency       int
	RequestsPerMinute int
	TokensPerMinute   int
}

func openRouterBaseConcurrency(live openRouterPoolSnapshot) int {
	concurrency := live.ReadySlotsTotal
	if concurrency < 1 {
		concurrency = live.ReadyProviderCount
	}
	if concurrency < 1 {
		concurrency = 1
	}
	return concurrency
}

func openRouterCapacityEntries(live openRouterPoolSnapshot, maxOutputTokens int, shareIndex, shareCount int) openRouterDerivedCapacity {
	concurrency := openRouterBaseConcurrency(live)
	if shareCount > 1 {
		base := concurrency / shareCount
		remainder := concurrency % shareCount
		concurrency = base
		if shareIndex < remainder {
			concurrency++
		}
		if concurrency < 1 {
			concurrency = 1
		}
	}
	requestsPerMinute := concurrency * openRouterRequestsPerMinutePerSlot
	return openRouterDerivedCapacity{
		Concurrency:       concurrency,
		RequestsPerMinute: requestsPerMinute,
		TokensPerMinute:   max(1, concurrency*openRouterTokensPerSecondPerSlot*60),
	}
}

func openRouterSlug(listing openRouterListingSpec, isFree bool) string {
	if !isFree {
		return listing.OpenRouterSlug
	}
	return listing.OpenRouterSlug + ":free"
}

func openRouterSupportedParameters(maxTokens int) map[string]openRouterParameterDescriptor {
	return map[string]openRouterParameterDescriptor{
		"max_tokens":        openRouterIntegerParameter(1, maxTokens, "token"),
		"temperature":       openRouterRangeParameter(0, 2),
		"top_p":             openRouterRangeParameter(0, 1),
		"stop":              {Type: "array", MaxItems: 4},
		"stream":            {Type: "boolean"},
		"presence_penalty":  openRouterRangeParameter(-2, 2),
		"frequency_penalty": openRouterRangeParameter(-2, 2),
		"seed":              openRouterIntegerParameter(0, 9007199254740991, ""),
	}
}

func openRouterRangeParameter(minValue, maxValue float64) openRouterParameterDescriptor {
	return openRouterParameterDescriptor{Type: "range", Min: &minValue, Max: &maxValue}
}

func openRouterIntegerParameter(minValue, maxValue int, unit string) openRouterParameterDescriptor {
	minFloat := float64(minValue)
	maxFloat := float64(maxValue)
	return openRouterParameterDescriptor{Type: "integer", Min: &minFloat, Max: &maxFloat, Unit: unit}
}

func textCostUSDFromRateCard(card openRouterRateCard, catalogKey string) (openRouterTextCostUSD, error) {
	row, ok := card.Rows[catalogKey]
	if !ok {
		return openRouterTextCostUSD{}, fmt.Errorf("rate-card missing catalog key %q", catalogKey)
	}
	if row.PromptRatePerMtok <= 0 || row.CompletionRatePerMtok <= 0 {
		return openRouterTextCostUSD{}, fmt.Errorf("rate-card invalid non-positive rates for %q", catalogKey)
	}
	usd := card.USDPerMillionCredits
	if usd <= 0 || math.IsNaN(usd) || math.IsInf(usd, 0) {
		return openRouterTextCostUSD{}, fmt.Errorf("rate-card invalid usd_per_million_credits")
	}
	return openRouterTextCostUSD{
		Prompt:     formatUSDPerToken(row.PromptRatePerMtok, usd),
		Completion: formatUSDPerToken(row.CompletionRatePerMtok, usd),
	}, nil
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
