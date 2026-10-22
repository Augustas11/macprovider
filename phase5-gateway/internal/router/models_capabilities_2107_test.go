package router

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// #2107 D6: per-model capabilities and supported_parameters survive the
// gateway's /v1/models allowlist; malformed values are dropped.
func TestModelsResponseCarriesCapabilities(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"object":"list",
			"data":[
				{"id":"model-a","object":"model","max_context_tokens":65536,
				 "capabilities":{"tools":true,"tool_choice":["auto","none"],"reasoning":true,"response_format":true,"vision":false,"context_length":65536},
				 "supported_parameters":["max_tokens","reasoning_effort","tool_choice","tools"]},
				{"id":"model-b","object":"model",
				 "capabilities":{"tools":"yes","tool_choice":["auto"],"reasoning":false,"response_format":true,"vision":false,"context_length":1},
				 "supported_parameters":["max_tokens","provider_secret"]}
			]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_models_capabilities")
	resp := assertStatus(t, h, http.MethodGet, "/v1/models", key, "", "1.2.3.4", http.StatusOK)
	var body struct {
		Data []map[string]any `json:"data"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("models json: %v", err)
	}
	byID := map[string]map[string]any{}
	for _, row := range body.Data {
		byID[row["id"].(string)] = row
	}
	caps, ok := byID["model-a"]["capabilities"].(map[string]any)
	if !ok || caps["tools"] != true || caps["reasoning"] != true || caps["context_length"] != float64(65536) {
		t.Fatalf("model-a capabilities=%v", byID["model-a"])
	}
	if params, ok := byID["model-a"]["supported_parameters"].([]any); !ok || len(params) != 4 {
		t.Fatalf("model-a supported_parameters=%v", byID["model-a"]["supported_parameters"])
	}
	if _, ok := byID["model-b"]["capabilities"]; ok {
		t.Fatalf("malformed capabilities must be dropped: %v", byID["model-b"])
	}
	if _, ok := byID["model-b"]["supported_parameters"]; ok {
		t.Fatalf("unknown supported_parameters must be dropped: %v", byID["model-b"])
	}
}
