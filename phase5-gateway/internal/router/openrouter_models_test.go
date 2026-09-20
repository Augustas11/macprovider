package router

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func mustProjectOpenRouterModels(t *testing.T, pool []openRouterPoolSnapshot, rateCard openRouterRateCard, now time.Time) openRouterModelsDocument {
	t.Helper()
	doc, err := projectOpenRouterModels(pool, rateCard, now)
	if err != nil {
		t.Fatalf("projectOpenRouterModels: %v", err)
	}
	return doc
}

func listingRateCard() openRouterRateCard {
	rows := make(map[string]openRouterRateCardRow, len(openRouterListings))
	for _, listing := range openRouterListings {
		rows[listing.CatalogKey] = openRouterRateCardRow{PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000}
	}
	return openRouterRateCard{USDPerMillionCredits: 1, Rows: rows}
}

func listingRateCardJSON(t *testing.T) string {
	t.Helper()
	raw, err := json.Marshal(listingRateCard())
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func rowByID(t *testing.T, doc openRouterModelsDocument, id string) openRouterModelV24 {
	t.Helper()
	for _, row := range doc.Data {
		if row.ID == id {
			return row
		}
	}
	t.Fatalf("missing row %q", id)
	return openRouterModelV24{}
}

func expectedCatalogDocumentLen(llamaReadySlots int) int {
	n := len(openRouterListings)
	if llamaReadySlots >= 2 {
		n++
	}
	return n
}

func TestOpenRouterListingsCoverLiveCatalog(t *testing.T) {
	if len(openRouterListings) != 17 {
		t.Fatalf("len(openRouterListings)=%d want 17 priced-v1 rows", len(openRouterListings))
	}
	seenPool := map[string]struct{}{}
	seenCard := map[string]struct{}{}
	dualFree := 0
	for _, listing := range openRouterListings {
		if listing.PoolID == "" || listing.CatalogKey == "" || listing.OpenRouterSlug == "" || listing.Name == "" {
			t.Fatalf("incomplete listing: %+v", listing)
		}
		if _, ok := seenPool[listing.PoolID]; ok {
			t.Fatalf("duplicate pool id %q", listing.PoolID)
		}
		if _, ok := seenCard[listing.CatalogKey]; ok {
			t.Fatalf("duplicate rate-card key %q", listing.CatalogKey)
		}
		seenPool[listing.PoolID] = struct{}{}
		seenCard[listing.CatalogKey] = struct{}{}
		if listing.DualFree {
			dualFree++
			if listing.PoolID != openRouterLlama3BPaidID {
				t.Fatalf("only Llama 3B may emit a free alias, got %q", listing.PoolID)
			}
		}
	}
	if dualFree != 1 {
		t.Fatalf("dualFree listings=%d want 1", dualFree)
	}
}

func TestProjectOpenRouterModelsDualLlamaSKU(t *testing.T) {
	now := time.Date(2026, 9, 11, 12, 0, 0, 0, time.UTC)
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 6, ReadySlotsTotal: 4, ReadySlotsFree: 4, MaxContextTokens: 131072},
		{ID: openRouterQwen8BID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 32768},
	}, listingRateCard(), now)
	if len(doc.Data) != expectedCatalogDocumentLen(4) {
		t.Fatalf("len(data)=%d want %d (full catalog plus Llama free alias)", len(doc.Data), expectedCatalogDocumentLen(4))
	}
	paid := rowByID(t, doc, openRouterLlama3BPaidID)
	free := rowByID(t, doc, openRouterLlama3BFreeID)
	qwen := rowByID(t, doc, openRouterQwen8BID)
	if paid.IsFree || !paid.IsReady {
		t.Fatalf("paid row: %+v", paid)
	}
	if !free.IsFree || !free.IsReady {
		t.Fatalf("free row: %+v", free)
	}
	if qwen.IsFree || !qwen.IsReady {
		t.Fatalf("Qwen must list with one warm node: %+v", qwen)
	}
	if paid.SchemaVersion != "2.4" || free.SchemaVersion != "2.4" {
		t.Fatalf("row schema versions paid=%q free=%q", paid.SchemaVersion, free.SchemaVersion)
	}
	if paid.Created != openRouterLlama3BCreatedAt || free.Created != openRouterLlama3BCreatedAt {
		t.Fatalf("created must be stable listing timestamp paid=%d free=%d", paid.Created, free.Created)
	}
	if len(paid.InputModalities) != 1 || paid.InputModalities[0].Type != "text" {
		t.Fatalf("paid input_modalities=%+v", paid.InputModalities)
	}
	if got := paid.InputModalities[0].SupportedInputs.MaxContextLength; got.Value != 131072 || got.Unit != "token" {
		t.Fatalf("paid max_context_length=%+v", got)
	}
	if got := paid.InputModalities[0].Pricing; len(got) != 1 || got[0].Type != "prompt" || got[0].Unit != "token" || got[0].CostUSD != "0.0000000135" {
		t.Fatalf("paid prompt pricing=%+v", got)
	}
	if got := paid.OutputModalities[0].Pricing; len(got) != 1 || got[0].Type != "completion" || got[0].Unit != "token" || got[0].CostUSD != "0.000000027" {
		t.Fatalf("paid completion pricing=%+v", got)
	}
	if got := free.InputModalities[0].Pricing; len(got) != 1 || got[0].CostUSD != "0" {
		t.Fatalf("free prompt pricing=%+v", got)
	}
	if got := free.OutputModalities[0].Pricing; len(got) != 1 || got[0].CostUSD != "0" {
		t.Fatalf("free completion pricing=%+v", got)
	}
	if paid.Quantization != "int4" || paid.Compliance.ZDR {
		t.Fatalf("quantization/zdr paid=%+v", paid)
	}
	if paid.DeploymentRegion != "global-volunteer-fleet" {
		t.Fatalf("deployment_region paid=%q", paid.DeploymentRegion)
	}
	if len(paid.Capacity) != 2 || paid.Capacity[0].Type != "request" || paid.Capacity[1].Type != "concurrency" {
		t.Fatalf("root capacity=%+v", paid.Capacity)
	}
	if paid.Capacity[1].Value != 2 || paid.Capacity[0].Value != 2 {
		t.Fatalf("capacity must derive conservatively from live ready slots, got %+v", paid.Capacity)
	}
	if free.Capacity[1].Value != 2 || free.Capacity[0].Value != 2 {
		t.Fatalf("free capacity must share the same ready pool, got %+v", free.Capacity)
	}
	if len(paid.OutputModalities) != 1 || !paid.OutputModalities[0].Streaming {
		t.Fatalf("paid output_modalities=%+v", paid.OutputModalities)
	}
	for _, param := range []string{"max_tokens", "temperature", "top_p", "stop", "stream", "presence_penalty", "frequency_penalty", "seed"} {
		if _, ok := paid.OutputModalities[0].SupportedParameters[param]; !ok {
			t.Fatalf("missing supported parameter %q in %+v", param, paid.OutputModalities[0].SupportedParameters)
		}
	}
	if _, ok := paid.OutputModalities[0].SupportedParameters["tools"]; ok {
		t.Fatalf("tools must remain undeclared until live reliability is proven: %+v", paid.OutputModalities[0].SupportedParameters)
	}
	if paid.HuggingFaceID != openRouterLlama3BPaidID || free.HuggingFaceID != openRouterLlama3BPaidID {
		t.Fatalf("hugging_face_id paid=%q free=%q", paid.HuggingFaceID, free.HuggingFaceID)
	}
	if paid.OpenRouter.Slug != openRouterLlama3BCatalogKey || free.OpenRouter.Slug != openRouterLlama3BCatalogKey+":free" {
		t.Fatalf("openrouter slug paid=%q free=%q", paid.OpenRouter.Slug, free.OpenRouter.Slug)
	}
	raw, _ := json.Marshal(doc)
	for _, forbidden := range []string{"architecture", "supported_parameters\":[", "us-east-1", "compute_integrity", "tier1_disclosure"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatalf("document leaked forbidden field/value %q: %s", forbidden, raw)
		}
	}
	if !strings.Contains(string(raw), `"input_modalities"`) || !strings.Contains(string(raw), `"output_modalities"`) || !strings.Contains(string(raw), `"capacity"`) {
		t.Fatalf("document missing schema-2.4 modality/capacity fields: %s", raw)
	}
	if !strings.Contains(string(raw), `"deployment_region":"global-volunteer-fleet"`) {
		t.Fatalf("document missing honest deployment_region: %s", raw)
	}
}

func TestProjectOpenRouterModelsCapacityTracksLiveSlots(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 6, ReadySlotsTotal: 4, ReadySlotsFree: 4, MaxContextTokens: 50000},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	if len(doc.Data) != expectedCatalogDocumentLen(4) {
		t.Fatalf("len(data)=%d", len(doc.Data))
	}
	got := rowByID(t, doc, openRouterLlama3BPaidID).Capacity
	if len(got) != 2 || got[0].Value != 2 || got[1].Value != 2 {
		t.Fatalf("capacity=%+v want 2rpm/2 concurrency for paid half of shared pool", got)
	}
	paid := rowByID(t, doc, openRouterLlama3BPaidID)
	if promptCap := paid.InputModalities[0].Capacity[0].Value; promptCap != 2*openRouterTokensPerSecondPerSlot*60 {
		t.Fatalf("prompt capacity=%d", promptCap)
	}
	if completionCap := paid.OutputModalities[0].Capacity[0].Value; completionCap != 2*openRouterTokensPerSecondPerSlot*60 {
		t.Fatalf("completion capacity=%d", completionCap)
	}
}

func TestProjectOpenRouterModelsRowsStaySchema24Native(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 8192},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	raw, err := json.Marshal(rowByID(t, doc, openRouterLlama3BPaidID))
	if err != nil {
		t.Fatal(err)
	}
	var row map[string]json.RawMessage
	if err := json.Unmarshal(raw, &row); err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"schema_version", "id", "name", "input_modalities", "output_modalities"} {
		if _, ok := row[required]; !ok {
			t.Fatalf("row missing required schema-2.4 key %q: %s", required, raw)
		}
	}
	for _, forbidden := range []string{"architecture", "context_length", "cost_usd", "supported_sampling_parameters", "supported_features", "capacity_tpm"} {
		if _, ok := row[forbidden]; ok {
			t.Fatalf("row contains legacy key %q: %s", forbidden, raw)
		}
	}
	if string(row["schema_version"]) != `"2.4"` {
		t.Fatalf("row schema_version=%s", row["schema_version"])
	}
	params := rowByID(t, doc, openRouterLlama3BPaidID).OutputModalities[0].SupportedParameters
	if params["max_tokens"].Type != "integer" || params["max_tokens"].Unit != "token" {
		t.Fatalf("max_tokens descriptor=%+v", params["max_tokens"])
	}
	if params["temperature"].Type != "range" || params["stream"].Type != "boolean" {
		t.Fatalf("parameter descriptors=%+v", params)
	}
}

func TestOpenRouterModelDocumentOmitsInventedAttestationRegionClaims(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 8192},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	raw, _ := json.Marshal(doc)
	if strings.Contains(string(raw), "compute_integrity") || strings.Contains(string(raw), "tier1_disclosure") || strings.Contains(string(raw), "us-east-1") {
		t.Fatalf("document leaked forbidden fields: %s", raw)
	}
}

func TestProjectOpenRouterModelsIsReadyRequiresWarmSlot(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 2, ReadySlotsTotal: 2, ReadySlotsFree: 0, MaxContextTokens: 8192},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	if len(doc.Data) != expectedCatalogDocumentLen(2) {
		t.Fatalf("len=%d", len(doc.Data))
	}
	if rowByID(t, doc, openRouterLlama3BPaidID).IsReady || rowByID(t, doc, openRouterLlama3BFreeID).IsReady {
		t.Fatalf("is_ready must be false without a free slot: %+v", doc.Data)
	}
}

func TestProjectOpenRouterModelsListsUnservedCatalogRows(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 8192},
		{ID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", ReadyProviderCount: 1, ReadySlotsTotal: 4, ReadySlotsFree: 4, MaxContextTokens: 32768},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	if len(doc.Data) != expectedCatalogDocumentLen(1) {
		t.Fatalf("len(data)=%d want full catalog", len(doc.Data))
	}
	qwen := rowByID(t, doc, openRouterQwen8BID)
	if qwen.IsReady || qwen.IsFree {
		t.Fatalf("unserved Qwen must stay listed and not ready: %+v", qwen)
	}
	if qwen.OpenRouter.Slug != openRouterQwen8BSlug {
		t.Fatalf("Qwen openrouter slug=%q want %q", qwen.OpenRouter.Slug, openRouterQwen8BSlug)
	}
	coder := rowByID(t, doc, "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit")
	if !coder.IsReady || coder.IsFree {
		t.Fatalf("served catalog row must be ready: %+v", coder)
	}
	glm := rowByID(t, doc, "mlx-community/GLM-4.5-Air-4bit")
	if glm.IsReady {
		t.Fatalf("unserved catalog row must not invent is_ready true: %+v", glm)
	}
	if qwen.Capacity[1].Value != 0 || glm.Capacity[1].Value != 0 {
		t.Fatalf("unserved rows must advertise 0 concurrency, qwen=%+v glm=%+v", qwen.Capacity, glm.Capacity)
	}
	if qwen.InputModalities[0].Capacity[0].Value != 0 || glm.OutputModalities[0].Capacity[0].Value != 0 {
		t.Fatalf("unserved rows must advertise 0 token capacity")
	}
}

func TestProjectOpenRouterModelsIgnoresNonReadyCapacity(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{
			ID:                 openRouterLlama3BPaidID,
			ReadyProviderCount: 1,
			ReadySlotsTotal:    1,
			ReadySlotsFree:     0,
			MaxContextTokens:   8192,
		},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	if len(doc.Data) != expectedCatalogDocumentLen(1) {
		t.Fatalf("len(data)=%d", len(doc.Data))
	}
	paid := rowByID(t, doc, openRouterLlama3BPaidID)
	if paid.IsReady {
		t.Fatal("is_ready must use ready free slots, not aggregate free slots from unavailable providers")
	}
	if got := paid.Capacity[1].Value; got != 1 {
		t.Fatalf("concurrency=%d want 1 ready slot", got)
	}
}

func TestProjectOpenRouterModelsOmitsFreeAliasWhenCapacityCannotBeShared(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 8192},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	if len(doc.Data) != expectedCatalogDocumentLen(1) {
		t.Fatalf("len(data)=%d want catalog without Llama free alias", len(doc.Data))
	}
	paid := rowByID(t, doc, openRouterLlama3BPaidID)
	if paid.IsFree {
		t.Fatalf("unexpected row: %+v", paid)
	}
	for _, row := range doc.Data {
		if row.ID == openRouterLlama3BFreeID {
			t.Fatal("free alias must stay omitted until capacity can be split")
		}
	}
}

func TestProjectOpenRouterModelsFailsClosedOnInvalidPaidRateCard(t *testing.T) {
	pool := []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 8192},
	}
	tests := []struct {
		name string
		card openRouterRateCard
	}{
		{
			name: "missing catalog key",
			card: openRouterRateCard{USDPerMillionCredits: 1, Rows: map[string]openRouterRateCardRow{}},
		},
		{
			name: "zero usd conversion",
			card: openRouterRateCard{USDPerMillionCredits: 0, Rows: map[string]openRouterRateCardRow{
				openRouterLlama3BCatalogKey: {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
			}},
		},
		{
			name: "zero prompt rate",
			card: openRouterRateCard{USDPerMillionCredits: 1, Rows: map[string]openRouterRateCardRow{
				openRouterLlama3BCatalogKey: {PromptRatePerMtok: 0, CompletionRatePerMtok: 27000},
			}},
		},
		{
			name: "missing non-llama catalog key",
			card: func() openRouterRateCard {
				card := listingRateCard()
				delete(card.Rows, "z-ai/glm-4.5-air")
				return card
			}(),
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := projectOpenRouterModels(pool, tt.card, time.Unix(1, 0).UTC()); err == nil {
				t.Fatal("expected invalid paid rate card to fail closed")
			}
		})
	}
}

func TestOpenRouterModelsHandlerUnauthenticated(t *testing.T) {
	poolz := `{"pool":[{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","state":"ready","slots_free":2,"slots_total":2,"max_context_tokens":8192,"auth_state":"bearer_validated"}]}`
	rateCard := listingRateCardJSON(t)
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/poolz"):
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, poolz), nil
		case strings.HasSuffix(r.URL.Path, "/v1/rate-card"):
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, rateCard), nil
		default:
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))
	resp := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, openRouterModelsPath, nil)
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var doc openRouterModelsDocument
	if err := json.Unmarshal(resp.Body.Bytes(), &doc); err != nil {
		t.Fatalf("decode: %v body=%s", err, resp.Body.String())
	}
	if len(doc.Data) != expectedCatalogDocumentLen(2) {
		t.Fatalf("doc rows=%d want %d", len(doc.Data), expectedCatalogDocumentLen(2))
	}
	if rowByID(t, doc, openRouterLlama3BPaidID).SchemaVersion != "2.4" || rowByID(t, doc, openRouterLlama3BFreeID).SchemaVersion != "2.4" {
		t.Fatalf("row schema versions=%q/%q", rowByID(t, doc, openRouterLlama3BPaidID).SchemaVersion, rowByID(t, doc, openRouterLlama3BFreeID).SchemaVersion)
	}
}

func TestOpenRouterModelsHandlerFailsClosedOnMissingRateCardRow(t *testing.T) {
	poolz := `{"pool":[{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":8192,"auth_state":"bearer_validated"}]}`
	rateCard := `{"usd_per_million_credits":1,"rows":{}}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/poolz"):
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, poolz), nil
		case strings.HasSuffix(r.URL.Path, "/v1/rate-card"):
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, rateCard), nil
		default:
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))
	resp := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, openRouterModelsPath, nil)
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "coordinator_rate_card_error") {
		t.Fatalf("body=%s", resp.Body.String())
	}
}
