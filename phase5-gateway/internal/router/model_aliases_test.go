package router

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestModelsPreservesAcceptedAliases(t *testing.T) {
	body := map[string]any{"object": "list", "data": []any{map[string]any{"id": "Jundot/GLM-5.3-Flash-oQ4e-mtp", "aliases": []any{"zai-org/glm-5.3-flash", "z-ai/glm-5.3-flash"}}}}
	sanitizeModelsResponse(body, "")
	entry := body["data"].([]any)[0].(map[string]any)
	aliases, ok := entry["aliases"].([]any)
	if !ok || len(aliases) != 2 {
		t.Fatalf("accepted aliases missing from discovery: %#v", entry["aliases"])
	}
}

func TestModelsAliasesRejectHostileAndCollidingClaims(t *testing.T) {
	body := map[string]any{"data": []any{
		map[string]any{"id": "model-a", "aliases": []any{"safe", "SAFE", "model-b", "shared", "pool/private/model", "bad\nvalue", 42}},
		map[string]any{"id": "model-b", "aliases": []any{"SHARED"}},
	}}
	sanitizeModelsResponse(body, "")
	entries := body["data"].([]any)
	aliases := entries[0].(map[string]any)["aliases"].([]any)
	if len(aliases) != 1 || aliases[0] != "safe" {
		t.Fatalf("unsafe aliases survived: %#v", aliases)
	}
	if got := entries[1].(map[string]any)["aliases"].([]any); len(got) != 0 {
		t.Fatalf("ambiguous aliases survived: %#v", got)
	}
}

func TestModelsHTTPPreservesCoordinatorAliases(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/v1/models" {
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"object":"list","data":[{"id":"Jundot/GLM-5.3-Flash-oQ4e-mtp","aliases":["glm-5.3-flash","z-ai/glm-5.3-flash","zai-org/glm-5.3-flash"]}]}`), nil
		}
		return responseWithBody(http.StatusOK, http.Header{}, `{}`), nil
	})}
	h, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_models_aliases")
	resp := assertStatus(t, h, http.MethodGet, "/v1/models", key, "", "1.2.3.4", http.StatusOK)
	var body struct {
		Data []struct {
			Aliases []string `json:"aliases"`
		} `json:"data"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Data) != 1 || len(body.Data[0].Aliases) != 3 {
		t.Fatalf("aliases missing: %s", resp.Body.String())
	}
}

func TestModelsAliasesExcludedFromPoolView(t *testing.T) {
	poolID := "QpsclmzwdJaWJTk3zowcXQ"
	modelID := "pool/" + poolID + "/creator-model"
	var metadata map[string]any
	if err := json.Unmarshal([]byte(`{"pool_id":"`+poolID+`","pool_model_id":"`+modelID+`","disclosure_class":"pool_attested_unverified","disclosure_text":"Pool-attested, not network-verified","runtime_sources":["mlx_cache"],"artifact_hash_algorithm":"macprovider.snapshot-manifest.v1","artifact_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","max_context_tokens":8192,"price":{"prompt_rate_per_mtok":1,"prompt_cache_hit_rate_per_mtok":1,"completion_rate_per_mtok":2,"global_multiplier_ppm":1000000},"price_source":"pool_creator_signed","manifest_version":5,"manifest_core_digest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}`), &metadata); err != nil {
		t.Fatal(err)
	}
	body := map[string]any{"data": []any{map[string]any{"id": modelID, "aliases": []any{"public-model"}, "macprovider_pool_model": metadata}}}
	sanitizeModelsResponse(body, poolID)
	data := body["data"].([]any)
	if len(data) != 1 {
		t.Fatalf("pool fixture dropped: %#v", body)
	}
	if _, ok := data[0].(map[string]any)["aliases"]; ok {
		t.Fatal("public aliases leaked into selected pool view")
	}
}
