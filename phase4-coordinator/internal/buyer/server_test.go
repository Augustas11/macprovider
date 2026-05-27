package buyer_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
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

func TestChatCompletionsRelaysStreamingSSE(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req map[string]any
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("upstream request json: %v", err)
		}
		if req["stream"] != true {
			t.Fatalf("stream = %v, want true", req["stream"])
		}
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		flusher := w.(http.Flusher)
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n"))
		flusher.Flush()
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"))
		flusher.Flush()
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("Content-Type") != "text/event-stream; charset=utf-8" {
		t.Fatalf("content-type = %q", rr.Header().Get("Content-Type"))
	}
	if rr.Header().Get("X-Accel-Buffering") != "no" || rr.Header().Get("Cache-Control") != "no-cache" {
		t.Fatalf("missing SSE buffering headers: %#v", rr.Header())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p1" || rr.Header().Get("X-MacProvider-Route") != "session-1" {
		t.Fatalf("route headers provider=%q route=%q", rr.Header().Get("X-MacProvider-Provider"), rr.Header().Get("X-MacProvider-Route"))
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`data: {"choices":[{"delta":{"content":"hi"}}]}`)) {
		t.Fatalf("stream body not relayed: %s", rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte("data: [DONE]\n\n")) {
		t.Fatalf("stream terminator missing: %s", rr.Body.String())
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

func TestChatCompletionsPreflightSkipsRejectedCandidate(t *testing.T) {
	rejectedUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("rejected provider should not receive request")
	}))
	defer rejectedUpstream.Close()
	acceptedUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"accepted","choices":[{"message":{"content":"ok"}}]}`))
	}))
	defer acceptedUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: rejectedUpstream.URL},
		{ProviderID: "p2", EndpointURL: acceptedUpstream.URL},
	})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, rejectedUpstream.URL, 20)
	registerWithEndpoint(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 2, acceptedUpstream.URL, 20)

	var calls []string
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithPreflightConfig(1, time.Second),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			calls = append(calls, provider.ProviderID)
			if provider.ProviderID == "p1" {
				return buyer.PreflightResult{Accepted: false, Reason: "queue_full"}, true, nil
			}
			return buyer.PreflightResult{Accepted: true}, true, nil
		}),
	)
	body := chatBodyWithContent("model-a", strings.Repeat("x", 64))

	rr := postChat(t, server, body, nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("provider = %q, want p2", rr.Header().Get("X-MacProvider-Provider"))
	}
	if strings.Join(calls, ",") != "p1,p2" {
		t.Fatalf("preflight calls = %v", calls)
	}
}

func TestChatCompletionsPinnedPreflightRejectDoesNotFallback(t *testing.T) {
	pinnedUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("rejected pinned provider should not receive request")
	}))
	defer pinnedUpstream.Close()
	fallbackUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("pinned rejection should not fallback")
	}))
	defer fallbackUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: pinnedUpstream.URL},
		{ProviderID: "p2", EndpointURL: fallbackUpstream.URL},
	})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, pinnedUpstream.URL, 20)
	registerWithEndpoint(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, fallbackUpstream.URL, 20)
	var calls []string
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithPreflightConfig(1, time.Second),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			calls = append(calls, provider.ProviderID)
			return buyer.PreflightResult{Accepted: false, Reason: "context_exceeds_capacity"}, true, nil
		}),
	)

	rr := postChat(t, server, chatBodyWithContent("model-a", strings.Repeat("x", 64)), http.Header{"X-MacProvider-Provider": []string{"p1"}})

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"preflight_rejected"`)) {
		t.Fatalf("body missing preflight_rejected: %s", rr.Body.String())
	}
	if strings.Join(calls, ",") != "p1" {
		t.Fatalf("preflight calls = %v", calls)
	}
}

func TestChatCompletionsContextLengthRoutesOrReturns413(t *testing.T) {
	smallUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("small context provider should be prefiltered")
	}))
	defer smallUpstream.Close()
	largeUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"large","choices":[{"message":{"content":"ok"}}]}`))
	}))
	defer largeUpstream.Close()

	longBody := chatBodyWithContent("model-a", strings.Repeat("x", 512))
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "small", EndpointURL: smallUpstream.URL},
		{ProviderID: "large", EndpointURL: largeUpstream.URL},
	})
	registerWithEndpoint(registry, "small", "s1", "model-a", pool.StateReady, 20, 1, smallUpstream.URL, 20)
	registerWithEndpoint(registry, "large", "s2", "model-a", pool.StateReady, 1000, 1, largeUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, longBody, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "large" {
		t.Fatalf("provider = %q, want large", rr.Header().Get("X-MacProvider-Provider"))
	}

	onlySmall := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "small", EndpointURL: smallUpstream.URL}})
	registerWithEndpoint(onlySmall, "small", "s1", "model-a", pool.StateReady, 20, 1, smallUpstream.URL, 20)
	smallServer := buyer.NewServer(onlySmall, zerolog.Nop(), time.Unix(1716768000, 0))
	tooLarge := postChat(t, smallServer, longBody, nil)
	if tooLarge.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status=%d body=%s", tooLarge.Code, tooLarge.Body.String())
	}
	if !bytes.Contains(tooLarge.Body.Bytes(), []byte(`"code":"context_exceeds_capacity"`)) {
		t.Fatalf("body missing context_exceeds_capacity: %s", tooLarge.Body.String())
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

func TestProviderFailureStartsRecoveryPreflight(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	recoveryIDs := make(chan string, 1)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRecoveryConfig(10*time.Millisecond, 1, true),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			recoveryIDs <- requestID
			return buyer.PreflightResult{Accepted: true}, true, nil
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	select {
	case requestID := <-recoveryIDs:
		if !strings.HasPrefix(requestID, "recovery-probe-") {
			t.Fatalf("requestID = %q", requestID)
		}
	case <-time.After(time.Second):
		t.Fatal("recovery preflight did not run")
	}
	eventually(t, func() bool {
		for _, p := range registry.Snapshot() {
			return p.ProviderID == "p1" && p.State == pool.StateReady
		}
		return false
	})
}

func TestProviderHTTP530MarksUnavailable(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(530)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	providers := registry.Snapshot()
	if len(providers) != 1 || providers[0].State != pool.StateUnavailable {
		t.Fatalf("providers = %#v", providers)
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

func chatBodyWithContent(model, content string) []byte {
	b, err := json.Marshal(map[string]any{
		"model": model,
		"messages": []map[string]string{
			{"role": "user", "content": content},
		},
	})
	if err != nil {
		panic(err)
	}
	return b
}

func eventually(t *testing.T, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if f() {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("condition did not become true before deadline")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
