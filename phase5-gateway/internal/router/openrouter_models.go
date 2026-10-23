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
	openRouterCatalogCreatedAt         = 1789776000 // 2026-09-19 priced-v1 cut
	openRouterQwen36A3BID              = "mlx-community/Qwen3.6-35B-A3B-4bit"
	openRouterQwen36A3BCatalogKey      = "qwen3.6-35b-a3b"
	openRouterQwen36A3BSlug            = "qwen/qwen3.6-35b-a3b"
	openRouterRateCardMaxBytes         = 4 << 20
	openRouterRequestsPerMinutePerSlot = 1
	openRouterTokensPerSecondPerSlot   = 10
)

type openRouterListingSpec struct {
	PoolID         string
	FreeID         string
	CatalogKey     string
	OpenRouterSlug string
	Name           string
	HuggingFaceID  string
	Tokenizer      string
	Quantization   string
	Created        int64
	DualFree       bool
}

// openRouterListings is the operator-chosen OpenRouter listing set
// (SPEC-006 §5.3.2). Other catalog rows stay buyer-routable on
// /v1/chat/completions but are not offered to OpenRouter.
var openRouterListings = []openRouterListingSpec{
	{
		PoolID:         openRouterQwen36A3BID,
		CatalogKey:     openRouterQwen36A3BCatalogKey,
		OpenRouterSlug: openRouterQwen36A3BSlug,
		Name:           "Qwen3.6 35B A3B (4-bit)",
		HuggingFaceID:  openRouterQwen36A3BID,
		Tokenizer:      "Qwen",
		Created:        openRouterCatalogCreatedAt,
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
	Type       string                                   `json:"type"`
	Min        *float64                                 `json:"min,omitempty"`
	Max        *float64                                 `json:"max,omitempty"`
	Values     []string                                 `json:"values,omitempty"`
	Unit       string                                   `json:"unit,omitempty"`
	MaxItems   int                                      `json:"max_items,omitempty"`
	Properties map[string]openRouterParameterDescriptor `json:"properties,omitempty"`
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
	// Capabilities is the coordinator's /v1/models capability object for the
	// model: provider eligibility and buyer-UX conformance masking already
	// applied. Nil when the coordinator lists no serving provider for it.
	Capabilities *openRouterModelCapabilities
}

// openRouterModelCapabilities is the part of the coordinator's per-model
// /v1/models capability object (SPEC-006 §21) that OpenRouter parameters
// project from.
type openRouterModelCapabilities struct {
	Tools          bool     `json:"tools"`
	ToolChoice     []string `json:"tool_choice"`
	ResponseFormat bool     `json:"response_format"`
}

const openRouterCoordinatorModelsMaxBytes = 4 << 20

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
	capabilities, err := s.fetchCoordinatorModelCapabilities(r)
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
			// #1570: only a serving provider's granted context is servable.
			MaxContextTokens: status.ServingMaxContextTokens[model.ID],
			Capabilities:     capabilities[model.ID],
		})
	}
	// A model whose only serving providers are busy with no free slot has no
	// routable status row but still has a servable context.
	for id, contextTokens := range status.ServingMaxContextTokens {
		found := false
		for _, model := range status.Models {
			if model.ID == id {
				found = true
				break
			}
		}
		if !found {
			pool = append(pool, openRouterPoolSnapshot{ID: id, MaxContextTokens: contextTokens, Capabilities: capabilities[id]})
		}
	}
	doc, err := projectOpenRouterModels(pool, rateCard, s.cfg.Limits.MaxTokensPerRequest, s.now())
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

// fetchCoordinatorModelCapabilities reads the coordinator's /v1/models, the
// capability result after provider eligibility and buyer-UX conformance
// masking, keyed by model id. OpenRouter parameters never widen it.
func (s *Server) fetchCoordinatorModelCapabilities(r *http.Request) (map[string]*openRouterModelCapabilities, error) {
	upReq, err := http.NewRequestWithContext(r.Context(), http.MethodGet, strings.TrimRight(s.coordinatorBuyerURL(), "/")+"/v1/models", nil)
	if err != nil {
		return nil, err
	}
	upReq.Header.Set("X-Request-ID", requestID(r))
	resp, err := s.client.Do(upReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, fmt.Errorf("models status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, openRouterCoordinatorModelsMaxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > openRouterCoordinatorModelsMaxBytes {
		return nil, fmt.Errorf("models response too large")
	}
	var doc struct {
		Data []struct {
			ID           string                       `json:"id"`
			Capabilities *openRouterModelCapabilities `json:"capabilities"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, err
	}
	out := make(map[string]*openRouterModelCapabilities, len(doc.Data))
	for _, model := range doc.Data {
		if model.ID != "" && model.Capabilities != nil {
			out[model.ID] = model.Capabilities
		}
	}
	return out, nil
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

func projectOpenRouterModels(pool []openRouterPoolSnapshot, rateCard openRouterRateCard, maxTokensPerRequest int64, now time.Time) (openRouterModelsDocument, error) {
	byID := make(map[string]openRouterPoolSnapshot, len(pool))
	for _, model := range pool {
		byID[model.ID] = model
	}
	created := now.UTC().Unix()
	data := make([]openRouterModelV24, 0, len(openRouterListings)+1)
	for _, listing := range openRouterListings {
		live, ok := byID[listing.PoolID]
		if !ok {
			live = openRouterPoolSnapshot{ID: listing.PoolID}
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
		data = append(data, openRouterModelRow(listing, listing.PoolID, false, ready, contextLength, maxTokensPerRequest, live, 0, shareCount, paidCost, created))
		if shareCount == 2 {
			freeCost := openRouterTextCostUSD{Prompt: "0", Completion: "0"}
			data = append(data, openRouterModelRow(listing, listing.FreeID, true, ready, contextLength, maxTokensPerRequest, live, 1, shareCount, freeCost, created))
		}
	}
	return openRouterModelsDocument{Data: data}, nil
}

func openRouterModelRow(listing openRouterListingSpec, id string, isFree, ready bool, contextLength int, maxTokensPerRequest int64, live openRouterPoolSnapshot, shareIndex, shareCount int, cost openRouterTextCostUSD, created int64) openRouterModelV24 {
	name := listing.Name
	if isFree {
		name += " (free)"
	}
	if listing.Created > 0 {
		created = listing.Created
	}
	quantization := listing.Quantization
	if quantization == "" {
		quantization = "int4"
	}
	maxOutput := contextLength
	if int64(maxOutput) > maxTokensPerRequest {
		maxOutput = int(maxTokensPerRequest)
	}
	capacity := openRouterCapacityEntries(live, maxOutput, shareIndex, shareCount)
	return openRouterModelV24{
		SchemaVersion: openRouterSchemaVersion,
		ID:            id,
		Name:          name,
		Created:       created,
		Quantization:  quantization,
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
			SupportedParameters: openRouterSupportedParameters(listing.PoolID, maxOutput, live.Capabilities),
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
		return 0
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
		TokensPerMinute:   concurrency * openRouterTokensPerSecondPerSlot * 60,
	}
}

func openRouterSlug(listing openRouterListingSpec, isFree bool) string {
	if !isFree {
		return listing.OpenRouterSlug
	}
	return listing.OpenRouterSlug + ":free"
}

// openRouterSupportedParameters projects tool and structured-output
// parameters from the coordinator's capability result (caps), bounded by the
// SPEC-018/SPEC-019 family predicates: a capability the coordinator masked,
// or a model it lists no capabilities for, is never advertised.
func openRouterSupportedParameters(modelID string, maxTokens int, caps *openRouterModelCapabilities) map[string]openRouterParameterDescriptor {
	params := map[string]openRouterParameterDescriptor{
		"max_tokens":  openRouterIntegerParameter(1, maxTokens, "token"),
		"temperature": openRouterRangeParameter(0, 2),
		"top_p":       openRouterRangeParameter(0, 1),
		"stop":        {Type: "array", MaxItems: 4},
		"stream":      {Type: "boolean"},
		"seed":        openRouterIntegerParameter(0, 9007199254740991, ""),
	}
	if caps == nil {
		return params
	}
	if caps.Tools && openRouterToolFamilyModel(modelID) {
		params["tools"] = openRouterParameterDescriptor{Type: "boolean"}
		values := []string{"auto"}
		// String modes are projected only from live enforcement capabilities.
		// Named selection is an object; /v1/status and SPEC-018 document it.
		for _, mode := range []string{"none", "required"} {
			for _, supported := range caps.ToolChoice {
				if mode == supported {
					values = append(values, mode)
					break
				}
			}
		}
		params["tool_choice"] = openRouterParameterDescriptor{Type: "enum", Values: values}
	}
	if caps.ResponseFormat && openRouterStructuredOutputModel(modelID) {
		// response_format is an object on the wire, so it is an OpenRouter
		// object descriptor: its "type" member is the closed SPEC-019 enum
		// and the json_schema body is not machine-described ("unknown").
		params["response_format"] = openRouterParameterDescriptor{
			Type: "object",
			Properties: map[string]openRouterParameterDescriptor{
				"type":        {Type: "enum", Values: []string{"text", "json_object", "json_schema"}},
				"json_schema": {Type: "unknown"},
			},
		}
		params["structured_outputs"] = openRouterParameterDescriptor{Type: "boolean"}
	}
	return params
}

// DSML needs a live declaration: it is newer than the shared parser floor.
func containsGuaranteedToolMode(modes []string) bool {
	for _, mode := range modes {
		if mode == "required" || mode == "named" {
			return true
		}
	}
	return false
}

// openRouterToolFamilyModel mirrors the coordinator's toolGrammarFamily
// (SPEC-018 §3.1, #2107): every catalog family whose chat template has a tool
// grammar, which the provider both parses and renders as history.
func openRouterToolFamilyModel(modelID string) bool {
	id := strings.ToLower(modelID)
	if strings.Contains(id, "qwen2-vl") || strings.Contains(id, "qwen2vl") {
		return false
	}
	for _, family := range []string{"gpt-oss", "glm-4.5", "glm-4.6", "glm-4.7", "glm-5", "llama-3.1", "llama-3.2", "llama-3.3",
		"llama3.1", "llama3.2", "llama3.3", "gemma-4", "gemma4", "nemotron-3", "nemotron3", "qwen2.5", "qwen3",
		"deepseek-v4", "deepseek_v4"} {
		if strings.Contains(id, family) {
			return true
		}
	}
	return false
}

// openRouterStructuredOutputModel mirrors the SPEC-019 §4 family-rendering
// predicate: only these families have a specified structured-output schema
// instruction. It is kept separate from the SPEC-018 predicate because the two
// specs govern them independently, even though the families coincide today.
func openRouterStructuredOutputModel(modelID string) bool {
	lower := strings.ToLower(modelID)
	return strings.Contains(lower, "qwen2.5") || strings.Contains(lower, "qwen3") || strings.Contains(lower, "llama-3.3")
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
