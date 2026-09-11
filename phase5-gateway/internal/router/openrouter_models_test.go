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

func TestProjectOpenRouterModelsDualLlamaSKU(t *testing.T) {
	now := time.Date(2026, 9, 11, 12, 0, 0, 0, time.UTC)
	doc := projectOpenRouterModels([]openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 6, SlotsFree: 4, MaxContextTokens: 131072},
		{ID: openRouterQwen8BID, ReadyProviderCount: 1, SlotsFree: 1, MaxContextTokens: 32768},
	}, openRouterRateCard{
		USDPerMillionCredits: 1,
		Rows: map[string]openRouterRateCardRow{
			openRouterLlama3BCatalogKey: {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
			openRouterQwen8BCatalogKey:  {PromptRatePerMtok: 13500, CompletionRatePerMtok: 27000},
		},
	}, now)
	if doc.SchemaVersion != openRouterSchemaVersion {
		t.Fatalf("schema_version=%q", doc.SchemaVersion)
	}
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
	if paid.CostUSD.Prompt != "0.0000000135" || paid.CostUSD.Completion != "0.000000027" {
		t.Fatalf("paid cost_usd=%+v", paid.CostUSD)
	}
	if free.CostUSD.Prompt != "0" || free.CostUSD.Completion != "0" {
		t.Fatalf("free cost_usd=%+v", free.CostUSD)
	}
	if paid.Quantization != "int4" || paid.Compliance.ZDR {
		t.Fatalf("quantization/zdr paid=%+v", paid)
	}
	if paid.HuggingFaceID != openRouterLlama3BPaidID || free.HuggingFaceID != openRouterLlama3BPaidID {
		t.Fatalf("hugging_face_id paid=%q free=%q", paid.HuggingFaceID, free.HuggingFaceID)
	}
	raw, _ := json.Marshal(doc)
	if strings.Contains(string(raw), "us-east-1") || strings.Contains(string(raw), "compute_integrity") || strings.Contains(string(raw), "tier1_disclosure") {
		t.Fatalf("document leaked forbidden fields: %s", raw)
	}
}

func TestProjectOpenRouterModelsIsReadyRequiresWarmSlot(t *testing.T) {
	doc := projectOpenRouterModels([]openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 2, SlotsFree: 0, MaxContextTokens: 8192},
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
	doc := projectOpenRouterModels([]openRouterPoolSnapshot{
		{ID: openRouterLlama3BPaidID, ReadyProviderCount: 2, SlotsFree: 1, MaxContextTokens: 8192},
		{ID: openRouterQwen8BID, ReadyProviderCount: 2, SlotsFree: 1, MaxContextTokens: 32768},
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
		}
	}
	if !sawQwen {
		t.Fatal("expected Qwen when two warm nodes")
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
	if doc.SchemaVersion != "2.4" || len(doc.Data) != 2 {
		t.Fatalf("doc=%+v", doc)
	}
}
