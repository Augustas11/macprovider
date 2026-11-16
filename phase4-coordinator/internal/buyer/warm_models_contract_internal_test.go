package buyer

import (
	"encoding/json"
	"net/http"
	"os"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const warmModelsFixtureDir = "../../../test/fixtures/warm-models/"

func readWarmModelsContractFixture(t *testing.T, name string) map[string]json.RawMessage {
	t.Helper()
	raw, err := os.ReadFile(warmModelsFixtureDir + name)
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	var fixture map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
	return fixture
}

// SPEC-001-R016: the served-model header the buyer sets on an HTTP-forwarded
// dispatch is the one the provider's cross-language fixture names.
func TestWarmModelsContractServedModelHeader(t *testing.T) {
	fixture := readWarmModelsContractFixture(t, "coordinator-dispatch-v1.json")
	var want struct {
		Name  string `json:"name"`
		Value string `json:"value"`
	}
	if err := json.Unmarshal(fixture["served_model_header"], &want); err != nil {
		t.Fatal(err)
	}
	var servedModelID string
	if err := json.Unmarshal(fixture["served_model_id"], &servedModelID); err != nil {
		t.Fatal(err)
	}
	if want.Name == "" || want.Value == "" {
		t.Fatalf("fixture served_model_header = %+v", want)
	}
	if servedModelHeader != want.Name {
		t.Fatalf("servedModelHeader = %q, fixture %q", servedModelHeader, want.Name)
	}
	h := http.Header{}
	setServedModelHeader(h, pool.Provider{ModelID: servedModelID, ServedModelID: servedModelID})
	if got := h.Get(want.Name); got != want.Value {
		t.Fatalf("header %s = %q, fixture %q", want.Name, got, want.Value)
	}
}

// SPEC-001-R016: each provider refusal in the model-not-loaded fixture (end
// status, preflight reason, HTTP 503 body) is classified model_not_loaded by
// the buyer for a multi-model entry.
func TestWarmModelsContractModelNotLoadedClassifiedForMultiModelEntry(t *testing.T) {
	fixture := readWarmModelsContractFixture(t, "model-not-loaded-v1.json")
	var end struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(fixture["inference_response_end"], &end); err != nil {
		t.Fatal(err)
	}
	var ack struct {
		Reason string `json:"reason"`
	}
	if err := json.Unmarshal(fixture["preflight_ack"], &ack); err != nil {
		t.Fatal(err)
	}
	var httpRefusal struct {
		Status int             `json:"status"`
		Body   json.RawMessage `json:"body"`
	}
	if err := json.Unmarshal(fixture["http"], &httpRefusal); err != nil {
		t.Fatal(err)
	}
	if httpRefusal.Status != http.StatusServiceUnavailable {
		t.Fatalf("fixture http status = %d", httpRefusal.Status)
	}
	httpCode := httpProviderErrorCode(httpRefusal.Body)
	if httpCode == "" {
		t.Fatalf("httpProviderErrorCode found no code in %s", httpRefusal.Body)
	}

	for name, code := range map[string]string{
		"end_status":       end.Status,
		"preflight_reason": ack.Reason,
		"http_body_code":   httpCode,
	} {
		t.Run(name, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			registerWarmEntryProvider(t, registry, "pw", 1)
			s := warmEntryServer(registry)
			entry := mustEntry(t, registry, "pw", "model-b")
			if entry.ServedModelID != "model-b" {
				t.Fatalf("entry served = %q, want model-b", entry.ServedModelID)
			}
			if !s.entryModelNotLoaded(entry, code, "req-not-loaded") {
				t.Fatalf("%s %q not classified as model not loaded for a multi-model entry", name, code)
			}
		})
	}
}
