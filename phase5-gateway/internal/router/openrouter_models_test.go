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

const (
	testDualFreePaidID = "mlx-community/Dual-Free-Test-4bit"
	testDualFreeFreeID = testDualFreePaidID + "-free"
	testDualFreeKey    = "dual-free-test"
	testDualFreeSlug   = "example/dual-free-test"
)

// withDualFreeListing appends a synthetic dual-free listing so the retained
// SPEC-006 §5.3.2 free-alias projection stays covered while the live listing
// set declares no free alias.
func withDualFreeListing(t *testing.T) {
	t.Helper()
	saved := openRouterListings
	openRouterListings = append(append([]openRouterListingSpec(nil), saved...), openRouterListingSpec{
		PoolID:         testDualFreePaidID,
		FreeID:         testDualFreeFreeID,
		CatalogKey:     testDualFreeKey,
		OpenRouterSlug: testDualFreeSlug,
		Name:           "Dual Free Test (4-bit)",
		HuggingFaceID:  testDualFreePaidID,
		Tokenizer:      "Llama3",
		Created:        1729728000,
		DualFree:       true,
	})
	t.Cleanup(func() { openRouterListings = saved })
}

func TestOpenRouterListingsPublishQwen36Only(t *testing.T) {
	if len(openRouterListings) != 1 {
		t.Fatalf("len(openRouterListings)=%d want 1 (Qwen3.6-35B-A3B only)", len(openRouterListings))
	}
	listing := openRouterListings[0]
	if listing.PoolID != openRouterQwen36A3BID || listing.CatalogKey != openRouterQwen36A3BCatalogKey || listing.OpenRouterSlug != openRouterQwen36A3BSlug {
		t.Fatalf("listing=%+v", listing)
	}
	if listing.DualFree || listing.FreeID != "" {
		t.Fatalf("Qwen3.6 listing must not declare a free alias: %+v", listing)
	}
	if listing.Name == "" || listing.HuggingFaceID != openRouterQwen36A3BID || listing.Tokenizer != "Qwen" {
		t.Fatalf("incomplete listing: %+v", listing)
	}
}

func TestProjectOpenRouterModelsQwen36Row(t *testing.T) {
	now := time.Date(2026, 9, 30, 12, 0, 0, 0, time.UTC)
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterQwen36A3BID, ReadyProviderCount: 1, ReadySlotsTotal: 4, ReadySlotsFree: 4, MaxContextTokens: 131072},
		{ID: "mlx-community/Llama-3.2-3B-Instruct-4bit", ReadyProviderCount: 6, ReadySlotsTotal: 6, ReadySlotsFree: 6, MaxContextTokens: 131072},
	}, listingRateCard(), now)
	if len(doc.Data) != 1 {
		t.Fatalf("len(data)=%d want 1 Qwen3.6 row only: %+v", len(doc.Data), doc.Data)
	}
	paid := rowByID(t, doc, openRouterQwen36A3BID)
	if paid.IsFree || !paid.IsReady {
		t.Fatalf("paid row: %+v", paid)
	}
	if paid.SchemaVersion != "2.4" || paid.Created != openRouterCatalogCreatedAt {
		t.Fatalf("schema/created: %+v", paid)
	}
	if got := paid.InputModalities[0].SupportedInputs.MaxContextLength; got.Value != 131072 || got.Unit != "token" {
		t.Fatalf("max_context_length=%+v", got)
	}
	if got := paid.InputModalities[0].Pricing; len(got) != 1 || got[0].Type != "prompt" || got[0].Unit != "token" || got[0].CostUSD != "0.0000000135" {
		t.Fatalf("prompt pricing=%+v", got)
	}
	if got := paid.OutputModalities[0].Pricing; len(got) != 1 || got[0].Type != "completion" || got[0].Unit != "token" || got[0].CostUSD != "0.000000027" {
		t.Fatalf("completion pricing=%+v", got)
	}
	if paid.Quantization != "int4" || paid.Compliance.ZDR || paid.DeploymentRegion != "global-volunteer-fleet" {
		t.Fatalf("quantization/zdr/region: %+v", paid)
	}
	if len(paid.Capacity) != 2 || paid.Capacity[0].Type != "request" || paid.Capacity[1].Type != "concurrency" || paid.Capacity[1].Value != 4 || paid.Capacity[0].Value != 4 {
		t.Fatalf("root capacity must derive from live ready slots: %+v", paid.Capacity)
	}
	if len(paid.OutputModalities) != 1 || !paid.OutputModalities[0].Streaming {
		t.Fatalf("output_modalities=%+v", paid.OutputModalities)
	}
	params := paid.OutputModalities[0].SupportedParameters
	for _, param := range []string{"max_tokens", "temperature", "top_p", "stop", "stream", "presence_penalty", "frequency_penalty", "seed"} {
		if _, ok := params[param]; !ok {
			t.Fatalf("missing supported parameter %q in %+v", param, params)
		}
	}
	if params["tools"].Type != "boolean" || params["structured_outputs"].Type != "boolean" {
		t.Fatalf("tool-capable Qwen3 family must declare tools/structured_outputs booleans: %+v", params)
	}
	if got := params["tool_choice"]; got.Type != "enum" || strings.Join(got.Values, ",") != "auto" {
		t.Fatalf("tool_choice descriptor=%+v", got)
	}
	rf := params["response_format"]
	if rf.Type != "object" || len(rf.Values) != 0 || len(rf.Properties) != 2 {
		t.Fatalf("response_format must be an object descriptor: %+v", rf)
	}
	if got := rf.Properties["type"]; got.Type != "enum" || strings.Join(got.Values, ",") != "text,json_object,json_schema" {
		t.Fatalf("response_format.type descriptor=%+v", got)
	}
	if got := rf.Properties["json_schema"]; got.Type != "unknown" || len(got.Values) != 0 || len(got.Properties) != 0 {
		t.Fatalf("response_format.json_schema descriptor=%+v", got)
	}
	if paid.HuggingFaceID != openRouterQwen36A3BID || paid.OpenRouter.Slug != openRouterQwen36A3BSlug {
		t.Fatalf("identity: hf=%q slug=%q", paid.HuggingFaceID, paid.OpenRouter.Slug)
	}
	raw, _ := json.Marshal(doc)
	for _, forbidden := range []string{"architecture", "supported_parameters\":[", "us-east-1", "compute_integrity", "tier1_disclosure", "Llama-3.2", "-free", "supported_features"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatalf("document leaked forbidden field/value %q: %s", forbidden, raw)
		}
	}
	if !strings.Contains(string(raw), `"tool_choice":{"type":"enum","values":["auto"]}`) {
		t.Fatalf("enum descriptor must serialize values: %s", raw)
	}
	if !strings.Contains(string(raw), `"response_format":{"type":"object","properties":{"json_schema":{"type":"unknown"},"type":{"type":"enum","values":["text","json_object","json_schema"]}}}`) {
		t.Fatalf("response_format object descriptor wire shape: %s", raw)
	}
}

func TestOpenRouterSupportedParametersGateToolFeaturesBySpec018Family(t *testing.T) {
	toolKeys := []string{"tools", "tool_choice"}
	structuredKeys := []string{"response_format", "structured_outputs"}
	family := []string{openRouterQwen36A3BID, "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit", "mlx-community/Llama-3.3-70B-Instruct-4bit"}
	other := []string{"mlx-community/Llama-3.2-3B-Instruct-4bit", "mlx-community/gpt-oss-20b-MXFP4-Q8", "mlx-community/gemma-4-26b-a4b-it-4bit", "mlx-community/GLM-4.5-Air-4bit"}
	for _, model := range family {
		if !openRouterToolFamilyModel(model) || !openRouterStructuredOutputModel(model) {
			t.Fatalf("%s must match both the SPEC-018 §3.8 and SPEC-019 §4 predicates", model)
		}
		params := openRouterSupportedParameters(model, 4096)
		for _, key := range append(append([]string{}, toolKeys...), structuredKeys...) {
			if _, ok := params[key]; !ok {
				t.Fatalf("%s must declare %q: %+v", model, key, params)
			}
		}
	}
	for _, model := range other {
		if openRouterToolFamilyModel(model) || openRouterStructuredOutputModel(model) {
			t.Fatalf("%s must match neither predicate", model)
		}
		params := openRouterSupportedParameters(model, 4096)
		for _, key := range append(append([]string{}, toolKeys...), structuredKeys...) {
			if _, ok := params[key]; ok {
				t.Fatalf("%s must not declare %q: %+v", model, key, params)
			}
		}
		if _, ok := params["max_tokens"]; !ok {
			t.Fatalf("%s lost base sampling parameters: %+v", model, params)
		}
	}
}

func TestProjectOpenRouterModelsDualFreeSKU(t *testing.T) {
	withDualFreeListing(t)
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: testDualFreePaidID, ReadyProviderCount: 6, ReadySlotsTotal: 4, ReadySlotsFree: 4, MaxContextTokens: 131072},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	if len(doc.Data) != len(openRouterListings)+1 {
		t.Fatalf("len(data)=%d want listings plus free alias", len(doc.Data))
	}
	paid := rowByID(t, doc, testDualFreePaidID)
	free := rowByID(t, doc, testDualFreeFreeID)
	if paid.IsFree || !paid.IsReady || !free.IsFree || !free.IsReady {
		t.Fatalf("paid=%+v free=%+v", paid, free)
	}
	if got := free.InputModalities[0].Pricing; len(got) != 1 || got[0].CostUSD != "0" {
		t.Fatalf("free prompt pricing=%+v", got)
	}
	if got := free.OutputModalities[0].Pricing; len(got) != 1 || got[0].CostUSD != "0" {
		t.Fatalf("free completion pricing=%+v", got)
	}
	if paid.Capacity[1].Value != 2 || free.Capacity[1].Value != 2 {
		t.Fatalf("paid/free must split the shared pool: paid=%+v free=%+v", paid.Capacity, free.Capacity)
	}
	if paid.HuggingFaceID != testDualFreePaidID || free.HuggingFaceID != testDualFreePaidID {
		t.Fatalf("hugging_face_id paid=%q free=%q", paid.HuggingFaceID, free.HuggingFaceID)
	}
	if paid.OpenRouter.Slug != testDualFreeSlug || free.OpenRouter.Slug != testDualFreeSlug+":free" {
		t.Fatalf("openrouter slug paid=%q free=%q", paid.OpenRouter.Slug, free.OpenRouter.Slug)
	}
	if _, ok := paid.OutputModalities[0].SupportedParameters["tools"]; ok {
		t.Fatalf("non-family synthetic row must not declare tools")
	}
}

func TestProjectOpenRouterModelsCapacityTracksLiveSlots(t *testing.T) {
	withDualFreeListing(t)
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: testDualFreePaidID, ReadyProviderCount: 6, ReadySlotsTotal: 4, ReadySlotsFree: 4, MaxContextTokens: 50000},
		{ID: openRouterQwen36A3BID, ReadyProviderCount: 1, ReadySlotsTotal: 3, ReadySlotsFree: 3, MaxContextTokens: 50000},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	if len(doc.Data) != len(openRouterListings)+1 {
		t.Fatalf("len(data)=%d", len(doc.Data))
	}
	if got := rowByID(t, doc, openRouterQwen36A3BID).Capacity; len(got) != 2 || got[0].Value != 3 || got[1].Value != 3 {
		t.Fatalf("single-SKU capacity=%+v want full 3 ready slots", got)
	}
	got := rowByID(t, doc, testDualFreePaidID).Capacity
	if len(got) != 2 || got[0].Value != 2 || got[1].Value != 2 {
		t.Fatalf("capacity=%+v want 2rpm/2 concurrency for paid half of shared pool", got)
	}
	paid := rowByID(t, doc, testDualFreePaidID)
	if promptCap := paid.InputModalities[0].Capacity[0].Value; promptCap != 2*openRouterTokensPerSecondPerSlot*60 {
		t.Fatalf("prompt capacity=%d", promptCap)
	}
	if completionCap := paid.OutputModalities[0].Capacity[0].Value; completionCap != 2*openRouterTokensPerSecondPerSlot*60 {
		t.Fatalf("completion capacity=%d", completionCap)
	}
}

func TestProjectOpenRouterModelsRowsStaySchema24Native(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterQwen36A3BID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 8192},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	raw, err := json.Marshal(rowByID(t, doc, openRouterQwen36A3BID))
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
	params := rowByID(t, doc, openRouterQwen36A3BID).OutputModalities[0].SupportedParameters
	if params["max_tokens"].Type != "integer" || params["max_tokens"].Unit != "token" {
		t.Fatalf("max_tokens descriptor=%+v", params["max_tokens"])
	}
	if params["temperature"].Type != "range" || params["stream"].Type != "boolean" {
		t.Fatalf("parameter descriptors=%+v", params)
	}
}

func TestOpenRouterModelDocumentOmitsInventedAttestationRegionClaims(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterQwen36A3BID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 8192},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	raw, _ := json.Marshal(doc)
	if strings.Contains(string(raw), "compute_integrity") || strings.Contains(string(raw), "tier1_disclosure") || strings.Contains(string(raw), "us-east-1") {
		t.Fatalf("document leaked forbidden fields: %s", raw)
	}
}

func TestProjectOpenRouterModelsIsReadyRequiresWarmSlot(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterQwen36A3BID, ReadyProviderCount: 2, ReadySlotsTotal: 2, ReadySlotsFree: 0, MaxContextTokens: 8192},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	if len(doc.Data) != len(openRouterListings) {
		t.Fatalf("len=%d", len(doc.Data))
	}
	if rowByID(t, doc, openRouterQwen36A3BID).IsReady {
		t.Fatalf("is_ready must be false without a free slot: %+v", doc.Data)
	}
}

func TestProjectOpenRouterModelsListsUnservedCatalogRows(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", ReadyProviderCount: 1, ReadySlotsTotal: 4, ReadySlotsFree: 4, MaxContextTokens: 32768},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	if len(doc.Data) != len(openRouterListings) {
		t.Fatalf("len(data)=%d want every listing and nothing else", len(doc.Data))
	}
	qwen := rowByID(t, doc, openRouterQwen36A3BID)
	if qwen.IsReady || qwen.IsFree {
		t.Fatalf("unserved listing must stay listed and not ready: %+v", qwen)
	}
	if qwen.OpenRouter.Slug != openRouterQwen36A3BSlug {
		t.Fatalf("Qwen openrouter slug=%q want %q", qwen.OpenRouter.Slug, openRouterQwen36A3BSlug)
	}
	if qwen.Capacity[0].Value != 0 || qwen.Capacity[1].Value != 0 {
		t.Fatalf("unserved rows must advertise 0 request/concurrency capacity: %+v", qwen.Capacity)
	}
	if qwen.InputModalities[0].Capacity[0].Value != 0 || qwen.OutputModalities[0].Capacity[0].Value != 0 {
		t.Fatalf("unserved rows must advertise 0 token capacity")
	}
	for _, row := range doc.Data {
		if row.ID == "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit" {
			t.Fatalf("served but unlisted catalog row must not be published: %+v", row)
		}
	}
}

func TestProjectOpenRouterModelsIgnoresNonReadyCapacity(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{
			ID:                 openRouterQwen36A3BID,
			ReadyProviderCount: 1,
			ReadySlotsTotal:    1,
			ReadySlotsFree:     0,
			MaxContextTokens:   8192,
		},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	if len(doc.Data) != len(openRouterListings) {
		t.Fatalf("len(data)=%d", len(doc.Data))
	}
	paid := rowByID(t, doc, openRouterQwen36A3BID)
	if paid.IsReady {
		t.Fatal("is_ready must use ready free slots, not aggregate free slots from unavailable providers")
	}
	if got := paid.Capacity[1].Value; got != 1 {
		t.Fatalf("concurrency=%d want 1 ready slot", got)
	}
}

func TestProjectOpenRouterModelsOmitsFreeAliasWhenCapacityCannotBeShared(t *testing.T) {
	withDualFreeListing(t)
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: testDualFreePaidID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 8192},
	}, listingRateCard(), time.Unix(1, 0).UTC())
	if len(doc.Data) != len(openRouterListings) {
		t.Fatalf("len(data)=%d want listings without free alias", len(doc.Data))
	}
	paid := rowByID(t, doc, testDualFreePaidID)
	if paid.IsFree {
		t.Fatalf("unexpected row: %+v", paid)
	}
	for _, row := range doc.Data {
		if row.ID == testDualFreeFreeID {
			t.Fatal("free alias must stay omitted until capacity can be split")
		}
	}
}

func TestProjectOpenRouterModelsFailsClosedOnInvalidPaidRateCard(t *testing.T) {
	pool := []openRouterPoolSnapshot{
		{ID: openRouterQwen36A3BID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 8192},
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
				openRouterQwen36A3BCatalogKey: {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
			}},
		},
		{
			name: "zero prompt rate",
			card: openRouterRateCard{USDPerMillionCredits: 1, Rows: map[string]openRouterRateCardRow{
				openRouterQwen36A3BCatalogKey: {PromptRatePerMtok: 0, CompletionRatePerMtok: 27000},
			}},
		},
		{
			name: "missing listed catalog key among other rows",
			card: func() openRouterRateCard {
				card := listingRateCard()
				delete(card.Rows, openRouterQwen36A3BCatalogKey)
				card.Rows["meta-llama/llama-3.2-3b-instruct"] = openRouterRateCardRow{PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000}
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
	poolz := `{"pool":[{"model_id":"mlx-community/Qwen3.6-35B-A3B-4bit","state":"ready","slots_free":2,"slots_total":2,"max_context_tokens":8192,"auth_state":"bearer_validated"},{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","state":"ready","slots_free":2,"slots_total":2,"max_context_tokens":8192,"auth_state":"bearer_validated"}]}`
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
	if len(doc.Data) != 1 {
		t.Fatalf("doc rows=%d want 1 Qwen3.6 row", len(doc.Data))
	}
	row := rowByID(t, doc, openRouterQwen36A3BID)
	if row.SchemaVersion != "2.4" || !row.IsReady {
		t.Fatalf("row=%+v", row)
	}
	if !strings.Contains(resp.Body.String(), `"tools":{"type":"boolean"}`) || !strings.Contains(resp.Body.String(), `"structured_outputs":{"type":"boolean"}`) {
		t.Fatalf("handler document missing tool/structured-output descriptors: %s", resp.Body.String())
	}
}

func TestOpenRouterModelsHandlerFailsClosedOnMissingRateCardRow(t *testing.T) {
	poolz := `{"pool":[{"model_id":"mlx-community/Qwen3.6-35B-A3B-4bit","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":8192,"auth_state":"bearer_validated"}]}`
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
