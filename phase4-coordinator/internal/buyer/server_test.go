package buyer_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestModelsAggregatesUniqueReadyProviderModels(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: "https://p1.example"},
		{ProviderID: "p2", EndpointURL: "https://p2.example"},
		{ProviderID: "p3", EndpointURL: "https://p3.example"},
		{ProviderID: "p4", EndpointURL: "https://p4.example"},
	})
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	register(registry, "p2", "session-2", "model-a", pool.StateReady, 50000, 1)
	register(registry, "p3", "session-3", "model-b", pool.StateReady, 120000, 1)
	register(registry, "p4", "session-4", "model-c", pool.StateBusy, 200000, 1)

	started := time.Unix(1716768000, 0)
	server := buyer.NewServer(registry, zerolog.Nop(), started)
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var got struct {
		Object string `json:"object"`
		Data   []struct {
			ID               string `json:"id"`
			Object           string `json:"object"`
			Created          int64  `json:"created"`
			OwnedBy          string `json:"owned_by"`
			ProviderCount    int    `json:"provider_count"`
			MaxContextTokens int    `json:"max_context_tokens"`
			TotalSlots       int    `json:"total_slots"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got.Object != "list" {
		t.Fatalf("object = %q", got.Object)
	}
	if len(got.Data) != 2 {
		t.Fatalf("models = %d, want 2: %#v", len(got.Data), got.Data)
	}
	if got.Data[0].ID != "model-a" || got.Data[0].ProviderCount != 2 || got.Data[0].MaxContextTokens != 50000 || got.Data[0].TotalSlots != 2 {
		t.Fatalf("model-a aggregation wrong: %#v", got.Data[0])
	}
	if got.Data[0].Created != started.Unix() || got.Data[0].OwnedBy != "macprovider" || got.Data[0].Object != "model" {
		t.Fatalf("model-a metadata wrong: %#v", got.Data[0])
	}
	if got.Data[1].ID != "model-b" || got.Data[1].ProviderCount != 1 || got.Data[1].MaxContextTokens != 120000 || got.Data[1].TotalSlots != 1 {
		t.Fatalf("model-b aggregation wrong: %#v", got.Data[1])
	}
}

func TestModelsReturnsEmptyListWhenNoReadyProviders(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: "https://p1.example"},
	})
	register(registry, "p1", "session-1", "model-a", pool.StateBusy, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var got struct {
		Data []any `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if len(got.Data) != 0 {
		t.Fatalf("data len = %d, want 0", len(got.Data))
	}
}

func TestChatCompletionsRoutesNonStreamingRequest(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		var req map[string]any
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("upstream request json: %v", err)
		}
		if req["model"] != "model-a" {
			t.Fatalf("model = %v", req["model"])
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"chatcmpl-test","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p1" {
		t.Fatalf("provider header = %q", rr.Header().Get("X-MacProvider-Provider"))
	}
	if rr.Header().Get("X-MacProvider-Route") != "session-1" {
		t.Fatalf("route header = %q", rr.Header().Get("X-MacProvider-Route"))
	}
	var got map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("response json: %v", err)
	}
	if got["id"] != "chatcmpl-test" {
		t.Fatalf("response not relayed: %#v", got)
	}
}

func TestChatCompletionsRoutingPreferences(t *testing.T) {
	slowUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"slow","choices":[{"message":{"content":"slow"}}]}`))
	}))
	defer slowUpstream.Close()
	fastUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"fast","choices":[{"message":{"content":"fast"}}]}`))
	}))
	defer fastUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "slow", EndpointURL: slowUpstream.URL},
		{ProviderID: "fast", EndpointURL: fastUpstream.URL},
	})
	registerWithEndpoint(registry, "slow", "s1", "model-a", pool.StateReady, 20000, 1, slowUpstream.URL, 10)
	registerWithEndpoint(registry, "fast", "s2", "model-a", pool.StateReady, 20000, 2, fastUpstream.URL, 30)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`)

	defaultRoute := postChat(t, server, body, nil)
	if defaultRoute.Code != http.StatusOK {
		t.Fatalf("default status=%d body=%s", defaultRoute.Code, defaultRoute.Body.String())
	}
	if defaultRoute.Header().Get("X-MacProvider-Provider") != "slow" {
		t.Fatalf("default provider = %q, want slow", defaultRoute.Header().Get("X-MacProvider-Provider"))
	}

	fastRoute := postChat(t, server, body, http.Header{"X-MacProvider-Pref": []string{"fast"}})
	if fastRoute.Code != http.StatusOK {
		t.Fatalf("fast status=%d body=%s", fastRoute.Code, fastRoute.Body.String())
	}
	if fastRoute.Header().Get("X-MacProvider-Provider") != "fast" {
		t.Fatalf("fast provider = %q, want fast", fastRoute.Header().Get("X-MacProvider-Provider"))
	}
}

func TestChatCompletionsValidationPrecedesModelLookup(t *testing.T) {
	registry := pool.NewRegistry(nil)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	body := []byte(`{"model":"missing-model","messages":[{"role":"user","content":"hello"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"test","arguments":"{not json}"}}]}]}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"invalid_tools"`)) {
		t.Fatalf("body missing invalid_tools: %s", rr.Body.String())
	}
}

func TestChatCompletionsSplitsUnknownModelAndUnavailableProvider(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: "http://p1.example"}})
	registerWithEndpoint(registry, "p1", "session-1", "model-a", pool.StateBusy, 20000, 1, "http://p1.example", 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	unknown := postChat(t, server, []byte(`{"model":"missing","messages":[{"role":"user","content":"hello"}]}`), nil)
	if unknown.Code != http.StatusNotFound {
		t.Fatalf("unknown status = %d, body=%s", unknown.Code, unknown.Body.String())
	}
	if !bytes.Contains(unknown.Body.Bytes(), []byte(`"code":"model_not_found"`)) {
		t.Fatalf("unknown body = %s", unknown.Body.String())
	}

	unavailable := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
	if unavailable.Code != http.StatusServiceUnavailable {
		t.Fatalf("unavailable status = %d, body=%s", unavailable.Code, unavailable.Body.String())
	}
	if !bytes.Contains(unavailable.Body.Bytes(), []byte(`"code":"no_provider_available"`)) {
		t.Fatalf("unavailable body = %s", unavailable.Body.String())
	}
}

func register(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int) {
	registerWithEndpoint(registry, providerID, assignedID, modelID, state, maxContextTokens, slotsTotal, "https://"+providerID+".example", 20)
}

func registerWithEndpoint(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int, endpointURL string, throughput float64) {
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            assignedID,
		Hostname:              providerID + ".local",
		ModelID:               modelID,
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      maxContextTokens,
		MaxConcurrency:        slotsTotal,
		SlotsFree:             slotsTotal,
		SlotsTotal:            slotsTotal,
		ThroughputTPSEstimate: throughput,
		EndpointURL:           endpointURL,
		State:                 state,
		LastHeartbeatAt:       time.Now().UTC(),
		ConnectedAt:           time.Now().UTC(),
		BinaryVersion:         "0.1.0",
	}, nil)
}

func postChat(t *testing.T, server *buyer.Server, body []byte, headers http.Header) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	for k, values := range headers {
		for _, v := range values {
			req.Header.Add(k, v)
		}
	}
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	_, _ = io.Copy(io.Discard, rr.Result().Body)
	return rr
}
