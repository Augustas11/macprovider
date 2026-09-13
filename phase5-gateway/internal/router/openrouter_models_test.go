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

func TestProjectOpenRouterModelsDualLlamaSKU(t *testing.T) {
	now := time.Date(2026, 9, 11, 12, 0, 0, 0, time.UTC)
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 6, ReadySlotsTotal: 4, ReadySlotsFree: 4, MaxContextTokens: 131072},
		{ID: openRouterQwen8BID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 32768},
	}, openRouterRateCard{
		USDPerMillionCredits: 1,
		Rows: map[string]openRouterRateCardRow{
			openRouterLlama3BCatalogKey: {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
			openRouterQwen8BCatalogKey:  {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
		},
	}, now)
	if len(doc.Data) != 2 {
		t.Fatalf("len(data)=%d want 2 (Qwen stays off until two warm nodes)", len(doc.Data))
	}
	paid := doc.Data[0]
	free := doc.Data[1]
	if paid.ID != openRouterLlama3BPaidID || paid.IsFree || !paid.IsReady {
		t.Fatalf("paid row: %+v", paid)
	}
	if free.ID != openRouterLlama3BFreeID || !free.IsFree || !free.IsReady {
		t.Fatalf("free row: %+v", free)
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
	}, openRouterRateCard{USDPerMillionCredits: 1, Rows: map[string]openRouterRateCardRow{
		openRouterLlama3BCatalogKey: {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
	}}, time.Unix(1, 0).UTC())
	if len(doc.Data) != 2 {
		t.Fatalf("len(data)=%d", len(doc.Data))
	}
	got := doc.Data[0].Capacity
	if len(got) != 2 || got[0].Value != 2 || got[1].Value != 2 {
		t.Fatalf("capacity=%+v want 2rpm/2 concurrency for paid half of shared pool", got)
	}
	if promptCap := doc.Data[0].InputModalities[0].Capacity[0].Value; promptCap != 2*openRouterTokensPerSecondPerSlot*60 {
		t.Fatalf("prompt capacity=%d", promptCap)
	}
	if completionCap := doc.Data[0].OutputModalities[0].Capacity[0].Value; completionCap != 2*openRouterTokensPerSecondPerSlot*60 {
		t.Fatalf("completion capacity=%d", completionCap)
	}
}

func TestProjectOpenRouterModelsRowsStaySchema24Native(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 8192},
	}, openRouterRateCard{USDPerMillionCredits: 1, Rows: map[string]openRouterRateCardRow{
		openRouterLlama3BCatalogKey: {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
	}}, time.Unix(1, 0).UTC())
	raw, err := json.Marshal(doc.Data[0])
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
	params := doc.Data[0].OutputModalities[0].SupportedParameters
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
	}, openRouterRateCard{USDPerMillionCredits: 1, Rows: map[string]openRouterRateCardRow{
		openRouterLlama3BCatalogKey: {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
	}}, time.Unix(1, 0).UTC())
	raw, _ := json.Marshal(doc)
	if strings.Contains(string(raw), "compute_integrity") || strings.Contains(string(raw), "tier1_disclosure") || strings.Contains(string(raw), "us-east-1") {
		t.Fatalf("document leaked forbidden fields: %s", raw)
	}
}

func TestProjectOpenRouterModelsIsReadyRequiresWarmSlot(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 2, ReadySlotsTotal: 2, ReadySlotsFree: 0, MaxContextTokens: 8192},
	}, openRouterRateCard{USDPerMillionCredits: 1, Rows: map[string]openRouterRateCardRow{
		openRouterLlama3BCatalogKey: {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
	}}, time.Unix(1, 0).UTC())
	if len(doc.Data) != 2 {
		t.Fatalf("len=%d", len(doc.Data))
	}
	if doc.Data[0].IsReady || doc.Data[1].IsReady {
		t.Fatalf("is_ready must be false without a free slot: %+v", doc.Data)
	}
}

func TestProjectOpenRouterModelsIncludesQwenWhenRedundant(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 2, ReadySlotsTotal: 2, ReadySlotsFree: 1, MaxContextTokens: 8192},
		{ID: openRouterQwen8BID, ReadyProviderCount: 2, ReadySlotsTotal: 2, ReadySlotsFree: 1, MaxContextTokens: 32768},
	}, openRouterRateCard{USDPerMillionCredits: 1, Rows: map[string]openRouterRateCardRow{
		openRouterLlama3BCatalogKey: {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
		openRouterQwen8BCatalogKey:  {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
	}}, time.Unix(1, 0).UTC())
	var sawQwen bool
	for _, row := range doc.Data {
		if row.ID == openRouterQwen8BID {
			sawQwen = true
			if row.IsFree {
				t.Fatal("Qwen row must not be the free alias")
			}
			if row.OpenRouter.Slug != openRouterQwen8BSlug {
				t.Fatalf("Qwen openrouter slug=%q want %q", row.OpenRouter.Slug, openRouterQwen8BSlug)
			}
		}
	}
	if !sawQwen {
		t.Fatal("expected Qwen when two warm nodes")
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
	}, openRouterRateCard{USDPerMillionCredits: 1, Rows: map[string]openRouterRateCardRow{
		openRouterLlama3BCatalogKey: {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
	}}, time.Unix(1, 0).UTC())
	if len(doc.Data) != 1 {
		t.Fatalf("len(data)=%d", len(doc.Data))
	}
	if doc.Data[0].IsReady {
		t.Fatal("is_ready must use ready free slots, not aggregate free slots from unavailable providers")
	}
	if got := doc.Data[0].Capacity[1].Value; got != 1 {
		t.Fatalf("concurrency=%d want 1 ready slot", got)
	}
}

func TestProjectOpenRouterModelsOmitsFreeAliasWhenCapacityCannotBeShared(t *testing.T) {
	doc := mustProjectOpenRouterModels(t, []openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 1, ReadySlotsTotal: 1, ReadySlotsFree: 1, MaxContextTokens: 8192},
	}, openRouterRateCard{USDPerMillionCredits: 1, Rows: map[string]openRouterRateCardRow{
		openRouterLlama3BCatalogKey: {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
	}}, time.Unix(1, 0).UTC())
	if len(doc.Data) != 1 {
		t.Fatalf("len(data)=%d want 1 paid row until capacity can be split", len(doc.Data))
	}
	if doc.Data[0].ID != openRouterLlama3BPaidID || doc.Data[0].IsFree {
		t.Fatalf("unexpected row: %+v", doc.Data[0])
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
	rateCard := `{"usd_per_million_credits":1,"rows":{"meta-llama/llama-3.2-3b-instruct":{"prompt_rate_per_mtok":13500,"completion_rate_per_mtok":27000}}}`
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
	if len(doc.Data) != 2 {
		t.Fatalf("doc=%+v", doc)
	}
	if doc.Data[0].SchemaVersion != "2.4" || doc.Data[1].SchemaVersion != "2.4" {
		t.Fatalf("row schema versions=%q/%q", doc.Data[0].SchemaVersion, doc.Data[1].SchemaVersion)
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
