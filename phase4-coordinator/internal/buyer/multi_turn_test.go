package buyer

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	"github.com/rs/zerolog"
)

func TestMultiTurnRequestValidationMatrix(t *testing.T) {
	cases := []struct {
		name       string
		mutate     func([]map[string]any) []map[string]any
		wantStatus int
		wantCode   string
	}{
		{
			name: "valid_pass_through",
			mutate: func(messages []map[string]any) []map[string]any {
				return messages
			},
		},
		{
			name: "tool_content_null",
			mutate: func(messages []map[string]any) []map[string]any {
				messages[2]["content"] = nil
				return messages
			},
			wantStatus: http.StatusBadRequest,
			wantCode:   "invalid_request",
		},
		{
			name: "tool_missing_id",
			mutate: func(messages []map[string]any) []map[string]any {
				delete(messages[2], "tool_call_id")
				return messages
			},
			wantStatus: http.StatusBadRequest,
			wantCode:   "invalid_tool_call_id",
		},
		{
			name: "tool_id_invalid_regex",
			mutate: func(messages []map[string]any) []map[string]any {
				messages[2]["tool_call_id"] = "call_short"
				return messages
			},
			wantStatus: http.StatusBadRequest,
			wantCode:   "invalid_tool_call_id",
		},
		{
			name: "tool_id_not_found",
			mutate: func(messages []map[string]any) []map[string]any {
				messages[2]["tool_call_id"] = "call_missing123456789"
				return messages
			},
			wantStatus: http.StatusBadRequest,
			wantCode:   "tool_call_id_not_found",
		},
		{
			name: "tool_result_duplicate",
			mutate: func(messages []map[string]any) []map[string]any {
				return append(messages, cloneMessage(messages[2]))
			},
			wantStatus: http.StatusBadRequest,
			wantCode:   "duplicate_tool_call_id",
		},
		{
			name: "tool_result_out_of_order",
			mutate: func(messages []map[string]any) []map[string]any {
				return []map[string]any{messages[2], messages[1]}
			},
			wantStatus: http.StatusBadRequest,
			wantCode:   "tool_call_result_out_of_order",
		},
		{
			name: "assistant_arguments_too_large",
			mutate: func(messages []map[string]any) []map[string]any {
				messages[1]["tool_calls"] = []map[string]any{{
					"id":   "call_0123456789abcdef",
					"type": "function",
					"function": map[string]any{
						"name":      "lookup",
						"arguments": `{"blob":"` + strings.Repeat("x", maxToolCallArgumentsBytes) + `"}`,
					},
				}}
				return messages
			},
			wantStatus: http.StatusRequestEntityTooLarge,
			wantCode:   "tool_call_arguments_too_large",
		},
		{
			name: "tool_result_too_large",
			mutate: func(messages []map[string]any) []map[string]any {
				messages[2]["content"] = strings.Repeat("x", maxToolResultBytes+1)
				return messages
			},
			wantStatus: http.StatusRequestEntityTooLarge,
			wantCode:   "tool_result_too_large",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := multiTurnBody(tc.mutate(validMultiTurnMessages()))
			_, status, code, msg := validateChatRequest(body)
			if tc.wantStatus == 0 {
				if status != 0 {
					t.Fatalf("validateChatRequest status=%d code=%s msg=%s", status, code, msg)
				}
				return
			}
			if status != tc.wantStatus || code != tc.wantCode {
				t.Fatalf("validateChatRequest status=%d code=%s msg=%s, want status=%d code=%s", status, code, msg, tc.wantStatus, tc.wantCode)
			}
		})
	}
}

func TestMultiTurnAggregateCaps(t *testing.T) {
	t.Run("coding_agent_session_over_256_is_accepted", func(t *testing.T) {
		messages := make([]map[string]any, 300)
		for i := range messages {
			messages[i] = map[string]any{"role": "user", "content": "hello"}
		}
		_, status, code, msg := validateChatRequest(multiTurnBody(messages))
		if status != 0 {
			t.Fatalf("status=%d code=%s msg=%s", status, code, msg)
		}
	})

	t.Run("too_many_tool_calls", func(t *testing.T) {
		messages := validMultiTurnMessages()
		calls := make([]map[string]any, maxAssistantToolCalls+1)
		for i := range calls {
			calls[i] = map[string]any{
				"id":   "call_" + strings.Repeat("a", 16-len(itoa(i))) + itoa(i),
				"type": "function",
				"function": map[string]any{
					"name":      "lookup",
					"arguments": `{"ok":true}`,
				},
			}
		}
		messages[1]["tool_calls"] = calls
		messages = messages[:2]
		_, status, code, _ := validateChatRequest(multiTurnBody(messages))
		if status != http.StatusBadRequest || code != "too_many_tool_calls" {
			t.Fatalf("status=%d code=%s", status, code)
		}
	})

	t.Run("tool_results_aggregate_too_large", func(t *testing.T) {
		messages := []map[string]any{{"role": "user", "content": "hello"}}
		calls := make([]map[string]any, 5)
		for i := range calls {
			id := "call_result" + strings.Repeat("a", 16-len(itoa(i))) + itoa(i)
			calls[i] = map[string]any{
				"id":   id,
				"type": "function",
				"function": map[string]any{
					"name":      "lookup",
					"arguments": `{"ok":true}`,
				},
			}
			messages = append(messages, map[string]any{"role": "assistant", "content": nil, "tool_calls": []map[string]any{calls[i]}})
			messages = append(messages, map[string]any{"role": "tool", "tool_call_id": id, "content": strings.Repeat("x", 220*1024)})
		}
		_, status, code, _ := validateChatRequest(multiTurnBody(messages))
		if status != http.StatusRequestEntityTooLarge || code != "tool_results_aggregate_too_large" {
			t.Fatalf("status=%d code=%s", status, code)
		}
	})

	t.Run("tool_call_arguments_aggregate_too_large", func(t *testing.T) {
		messages := validMultiTurnMessages()
		calls := make([]map[string]any, 3)
		for i := range calls {
			calls[i] = map[string]any{
				"id":   "call_args" + strings.Repeat("b", 16-len(itoa(i))) + itoa(i),
				"type": "function",
				"function": map[string]any{
					"name":      "lookup",
					"arguments": `{"blob":"` + strings.Repeat("x", 700*1024) + `"}`,
				},
			}
		}
		messages[1]["tool_calls"] = calls
		messages = messages[:2]
		_, status, code, _ := validateChatRequest(multiTurnBody(messages))
		if status != http.StatusRequestEntityTooLarge || code != "tool_call_arguments_aggregate_too_large" {
			t.Fatalf("status=%d code=%s", status, code)
		}
	})
}

func validMultiTurnMessages() []map[string]any {
	return []map[string]any{
		{"role": "user", "content": "weather"},
		{
			"role":    "assistant",
			"content": nil,
			"tool_calls": []map[string]any{{
				"id":   "call_0123456789abcdef",
				"type": "function",
				"function": map[string]any{
					"name":      "lookup",
					"arguments": `{"city":"Vilnius"}`,
				},
			}},
		},
		{
			"role":         "tool",
			"tool_call_id": "call_0123456789abcdef",
			"content":      `{"temperature_c":21}`,
		},
	}
}

func multiTurnBody(messages []map[string]any) []byte {
	raw, err := json.Marshal(map[string]any{
		"model":    "model-a",
		"messages": messages,
	})
	if err != nil {
		panic(err)
	}
	return raw
}

func cloneMessage(message map[string]any) map[string]any {
	out := make(map[string]any, len(message))
	for key, value := range message {
		out[key] = value
	}
	return out
}

const (
	gateLlama32ID = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	gateQwen36ID  = "mlx-community/Qwen3.6-35B-A3B-4bit"
)

func gateMultiTurnRequest(t *testing.T, model string) chatRequest {
	t.Helper()
	body, err := json.Marshal(map[string]any{"model": model, "messages": validMultiTurnMessages()})
	if err != nil {
		t.Fatal(err)
	}
	req, status, code, msg := validateChatRequest(body)
	if status != 0 {
		t.Fatalf("validateChatRequest status=%d code=%s msg=%s", status, code, msg)
	}
	req.multiTurnToolHistory = hasMultiTurnToolData(req.Messages)
	return req
}

func configureGateCatalog(t *testing.T) {
	t.Helper()
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := buyerCatalogFixtureModels(t, "spec018-multi-turn-gate", time.Now().UTC().Add(time.Hour),
		gateLlama32ID, gateQwen36ID, "mlx-community/Llama-3.3-70B-Instruct-4bit", "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit")
	if err := tier2.Configure(config.Tier2Config{ObserveEnabled: true, CatalogPath: writeBuyerCatalog(t, raw), CatalogPublicKey: pubkey}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	if got := len(tier2.Default().ModelIDs()); got != 4 {
		t.Fatalf("catalog model ids=%d want 4", got)
	}
}

func TestUnsupportedMultiTurnToolModelGate(t *testing.T) {
	configureGateCatalog(t)
	catalog := tier2.Default().ModelIDs
	firstTurn := func(model string) chatRequest {
		t.Helper()
		body, err := json.Marshal(map[string]any{
			"model":    model,
			"messages": []map[string]any{{"role": "user", "content": "weather"}},
			"tools":    []map[string]any{{"type": "function", "function": map[string]any{"name": "lookup", "parameters": map[string]any{"type": "object"}}}},
		})
		if err != nil {
			t.Fatal(err)
		}
		req, status, code, msg := validateChatRequest(body)
		if status != 0 {
			t.Fatalf("validateChatRequest status=%d code=%s msg=%s", status, code, msg)
		}
		return req
	}
	toolResultOnly := gateMultiTurnRequest(t, gateLlama32ID)
	toolResultOnly.Messages = []chatMessage{{Role: "user"}, {Role: "tool", ToolCallID: "call_0123456789abcdef"}}
	toolResultOnly.multiTurnToolHistory = hasMultiTurnToolData(toolResultOnly.Messages)
	nativeRoute := gateMultiTurnRequest(t, gateLlama32ID)
	nativeRoute.engineClass = engineClassNative
	poolRoute := gateMultiTurnRequest(t, gateLlama32ID)
	poolRoute.poolID = "pool-a"
	poolNativeSelected := poolRoute
	poolNativeSelected.engineClass = engineClassNative
	poolExternal := poolRoute
	poolExternal.engineClass = "llamacpp_loopback"
	externalRoute := gateMultiTurnRequest(t, gateLlama32ID)
	externalRoute.engineClass = "llamacpp_loopback"
	externalAllowlist := []string{"llamacpp_loopback"}

	const reject = "unsupported_modelID_for_multi_turn"
	cases := []struct {
		name      string
		req       chatRequest
		allowlist []string
		wantCode  string
	}{
		{name: "catalog_id_rejected", req: gateMultiTurnRequest(t, gateLlama32ID), wantCode: reject},
		{name: "free_alias_rejected", req: gateMultiTurnRequest(t, gateLlama32ID+"-free"), wantCode: reject},
		{name: "openrouter_slug_alias_rejected", req: gateMultiTurnRequest(t, "meta-llama/llama-3.2-3b-instruct"), wantCode: reject},
		{name: "case_variant_rejected", req: gateMultiTurnRequest(t, "MLX-COMMUNITY/llama-3.2-3b-instruct-4BIT"), wantCode: reject},
		{name: "bare_key_alias_rejected", req: gateMultiTurnRequest(t, "llama-3.2-3b-instruct"), wantCode: reject},
		{name: "tool_result_only_rejected", req: toolResultOnly, wantCode: reject},
		{name: "explicit_native_engine_rejected", req: nativeRoute, wantCode: reject},
		{name: "qwen36_catalog_accepted", req: gateMultiTurnRequest(t, gateQwen36ID)},
		{name: "qwen36_slug_alias_accepted", req: gateMultiTurnRequest(t, "qwen/qwen3.6-35b-a3b")},
		{name: "qwen25_family_accepted", req: gateMultiTurnRequest(t, "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit")},
		{name: "llama33_family_accepted", req: gateMultiTurnRequest(t, "mlx-community/Llama-3.3-70B-Instruct-4bit")},
		{name: "first_turn_tools_fall_back_per_spec018_3_5", req: firstTurn(gateLlama32ID)},
		{name: "non_catalog_model_untouched", req: gateMultiTurnRequest(t, "byom/some-local-model")},
		{name: "native_only_pool_rejected", req: poolRoute, wantCode: reject},
		{name: "pool_explicit_native_rejected_despite_allowlist", req: poolNativeSelected, allowlist: externalAllowlist, wantCode: reject},
		{name: "pool_with_external_allowlist_no_selection_untouched", req: poolRoute, allowlist: externalAllowlist},
		{name: "pool_external_engine_untouched", req: poolExternal, allowlist: externalAllowlist},
		{name: "external_engine_route_untouched", req: externalRoute},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			status, code, msg := unsupportedMultiTurnToolModel(tc.req, catalog, nil, tc.allowlist)
			if tc.wantCode == "" {
				if status != 0 {
					t.Fatalf("status=%d code=%s msg=%s, want pass-through", status, code, msg)
				}
				return
			}
			if status != http.StatusBadRequest || code != tc.wantCode {
				t.Fatalf("status=%d code=%s msg=%s, want 400 %s", status, code, msg, tc.wantCode)
			}
			if spec018RetryableByCode[code] {
				t.Fatalf("%s must be non-retryable", code)
			}
		})
	}
	if status, _, _ := unsupportedMultiTurnToolModel(gateMultiTurnRequest(t, gateLlama32ID), nil, nil, nil); status != 0 {
		t.Fatalf("nil catalog must not reject, status=%d", status)
	}
	tier2.ResetForTest()
	if status, _, _ := unsupportedMultiTurnToolModel(gateMultiTurnRequest(t, gateLlama32ID), tier2.Default().ModelIDs, nil, nil); status != 0 {
		t.Fatalf("unconfigured catalog must not reject, status=%d", status)
	}
}

func TestEmptyAssistantToolCallsRejectedBeforeGate(t *testing.T) {
	for _, raw := range []string{`[]`, `[ ]`} {
		body := []byte(`{"model":"` + gateQwen36ID + `","messages":[{"role":"user","content":"a"},{"role":"assistant","content":"x","tool_calls":` + raw + `}]}`)
		_, status, code, msg := validateChatRequest(body)
		if status != http.StatusBadRequest || code != "invalid_tools" {
			t.Fatalf("tool_calls=%s: status=%d code=%s msg=%s, want 400 invalid_tools", raw, status, code, msg)
		}
	}
	if hasMultiTurnToolData([]chatMessage{{Role: "assistant", ToolCalls: json.RawMessage(`[]`)}, {Role: "assistant", ToolCalls: json.RawMessage(`null`)}}) {
		t.Fatal("empty or null tool_calls must not count as tool history")
	}
}

func TestMultiTurnGateRejectsAliasBeforeDispatch(t *testing.T) {
	configureGateCatalog(t)
	registry := pool.NewRegistry(nil)
	hits := registerGateProvider(t, registry, "p1", gateLlama32ID)
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	for _, model := range []string{gateLlama32ID + "-free", "meta-llama/llama-3.2-3b-instruct"} {
		body, err := json.Marshal(map[string]any{"model": model, "messages": validMultiTurnMessages()})
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
		req.Header.Set("Idempotency-Key", "gate-"+model)
		rr := httptest.NewRecorder()
		server.Handler().ServeHTTP(rr, req)
		if rr.Code != http.StatusBadRequest || !strings.Contains(rr.Body.String(), "unsupported_modelID_for_multi_turn") {
			t.Fatalf("model=%s status=%d body=%s, want 400 unsupported_modelID_for_multi_turn", model, rr.Code, rr.Body.String())
		}
	}
	if got := hits.Load(); got != 0 {
		t.Fatalf("provider dispatched %d times, want 0", got)
	}
}

type gateUpstream struct {
	hits   atomic.Int32
	models sync.Map
}

func (g *gateUpstream) Load() int32 { return g.hits.Load() }

// registerGateProvider registers one HTTP-forwarding provider serving model
// and records how often it was dispatched and with which body model.
func registerGateProvider(t *testing.T, registry *pool.Registry, providerID, model string) *gateUpstream {
	t.Helper()
	up := &gateUpstream{}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		up.hits.Add(1)
		var body struct {
			Model string `json:"model"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		up.models.Store(body.Model, true)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`))
	}))
	t.Cleanup(upstream.Close)
	now := time.Now().UTC()
	registry.Register(&pool.Provider{
		ProviderID:       providerID,
		AssignedID:       providerID + "-session",
		Hostname:         providerID + ".local",
		ModelID:          model,
		MaxContextTokens: 20000,
		MaxConcurrency:   1,
		SlotsFree:        1,
		SlotsTotal:       1,
		EndpointURL:      upstream.URL,
		Tier:             pool.TierPinned,
		InferencePath:    pool.InferencePathHTTPForwarding,
		State:            pool.StateReady,
		LastHeartbeatAt:  now,
		ConnectedAt:      now,
	}, nil)
	return up
}

func postGateChat(t *testing.T, server *Server, model string, messages []map[string]any, idempotencyKey string) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(map[string]any{"model": model, "messages": messages})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	if idempotencyKey != "" {
		req.Header.Set("Idempotency-Key", idempotencyKey)
	}
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	return rr
}

func TestMultiTurnToolClassKeepsOnlyProfiledMembers(t *testing.T) {
	mixed := &config.ModelClassConfig{Objective: "latency", Models: []string{gateLlama32ID, gateQwen36ID}}
	got := modelClassMembers(multiTurnToolClass(mixed))
	if len(got) != 1 || got[0] != gateQwen36ID {
		t.Fatalf("filtered members=%v want [%s]", got, gateQwen36ID)
	}
	onlyLlama := &config.ModelClassConfig{Members: []string{gateLlama32ID}}
	if got := modelClassMembers(multiTurnToolClass(onlyLlama)); len(got) != 0 {
		t.Fatalf("Members-only class must filter to empty, got %v", got)
	}
	req := gateMultiTurnRequest(t, "mlx-fast")
	if status, code, _ := unsupportedMultiTurnToolModel(req, nil, onlyLlama, nil); status != http.StatusBadRequest || code != "unsupported_modelID_for_multi_turn" {
		t.Fatalf("class with no profiled member: status=%d code=%s", status, code)
	}
	if status, _, _ := unsupportedMultiTurnToolModel(req, nil, mixed, nil); status != 0 {
		t.Fatalf("class with a profiled member must pass the pre-dispatch gate, status=%d", status)
	}
	pooled := req
	pooled.poolID = "pool-a"
	if status, _, _ := unsupportedMultiTurnToolModel(pooled, nil, onlyLlama, nil); status != http.StatusBadRequest {
		t.Fatalf("native-only pool route must apply the class gate, status=%d", status)
	}
	if status, _, _ := unsupportedMultiTurnToolModel(pooled, nil, onlyLlama, []string{"llamacpp_loopback"}); status != 0 {
		t.Fatalf("pool route that may reach an allowlisted external runtime keeps provider-side behavior, status=%d", status)
	}
	plain := req
	plain.multiTurnToolHistory = false
	if status, _, _ := unsupportedMultiTurnToolModel(plain, nil, onlyLlama, nil); status != 0 {
		t.Fatalf("class request without tool history must pass, status=%d", status)
	}
}

func TestMultiTurnGateModelClassAlias(t *testing.T) {
	configureGateCatalog(t)
	plainMessages := []map[string]any{{"role": "user", "content": "hi"}}

	t.Run("mixed_class_routes_tool_history_to_profiled_member_only", func(t *testing.T) {
		registry := pool.NewRegistry(nil)
		llama := registerGateProvider(t, registry, "p-llama", gateLlama32ID)
		qwen := registerGateProvider(t, registry, "p-qwen", gateQwen36ID)
		server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
		server.SetRoutingClasses(map[string]config.ModelClassConfig{"mlx-fast": {Objective: "latency", Models: []string{gateLlama32ID, gateQwen36ID}}})
		for i := 0; i < 4; i++ {
			rr := postGateChat(t, server, "mlx-fast", validMultiTurnMessages(), "")
			if rr.Code != http.StatusOK {
				t.Fatalf("attempt %d status=%d body=%s", i, rr.Code, rr.Body.String())
			}
		}
		if got := llama.Load(); got != 0 {
			t.Fatalf("Llama-3.2 provider dispatched %d times with tool history, want 0", got)
		}
		if got := qwen.Load(); got != 4 {
			t.Fatalf("Qwen3.6 provider dispatched %d times, want 4", got)
		}
		if _, ok := qwen.models.Load(gateQwen36ID); !ok {
			t.Fatal("dispatched body model must be rewritten to the concrete Qwen3.6 id (SPEC-004 FR-SR-7a)")
		}
	})

	t.Run("class_without_profiled_member_rejects_before_idempotency_and_dispatch", func(t *testing.T) {
		registry := pool.NewRegistry(nil)
		llama := registerGateProvider(t, registry, "p-llama", gateLlama32ID)
		server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
		server.SetRoutingClasses(map[string]config.ModelClassConfig{"mlx-fast": {Objective: "latency", Members: []string{gateLlama32ID}}})
		rr := postGateChat(t, server, "mlx-fast", validMultiTurnMessages(), "gate-class-reject")
		if rr.Code != http.StatusBadRequest || !strings.Contains(rr.Body.String(), "unsupported_modelID_for_multi_turn") {
			t.Fatalf("status=%d body=%s, want 400 unsupported_modelID_for_multi_turn (no idempotency reservation)", rr.Code, rr.Body.String())
		}
		if got := llama.Load(); got != 0 {
			t.Fatalf("provider dispatched %d times, want 0", got)
		}
	})

	t.Run("class_without_tool_history_is_unaffected", func(t *testing.T) {
		registry := pool.NewRegistry(nil)
		llama := registerGateProvider(t, registry, "p-llama", gateLlama32ID)
		server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
		server.SetRoutingClasses(map[string]config.ModelClassConfig{"mlx-fast": {Objective: "latency", Members: []string{gateLlama32ID}}})
		rr := postGateChat(t, server, "mlx-fast", plainMessages, "")
		if rr.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
		}
		if got := llama.Load(); got != 1 {
			t.Fatalf("plain class request dispatched %d times, want 1", got)
		}
	})
}

func gatePoolServer(t *testing.T, allowlist []string, members ...pool.Provider) (*Server, *pool.Registry) {
	t.Helper()
	configureGateCatalog(t)
	registry := pool.NewRegistry(nil)
	tp := trustpool.NewRegistry()
	ids := make([]string, 0, len(members))
	for i := range members {
		p := members[i]
		registry.Register(&p, nil)
		ids = append(ids, p.ProviderID)
	}
	if err := tp.LoadRouteableSnapshot(trustpool.RouteableSnapshot{PoolID: "P", Members: ids, RuntimeAllowlist: allowlist, SettlementMode: "observe", Routeable: true, Generation: 1}); err != nil {
		t.Fatalf("LoadRouteableSnapshot: %v", err)
	}
	return NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), WithPoolMembership(tp)), registry
}

func gatePoolMember(providerID, model string) pool.Provider {
	p := poolProvider(providerID)
	p.ModelID = model
	return p
}

func gatePoolToolRequest(t *testing.T, model string) chatRequest {
	t.Helper()
	req := gateMultiTurnRequest(t, model)
	req.poolID = "P"
	return req
}

func providerStateFingerprint(registry *pool.Registry) string {
	var b strings.Builder
	for _, p := range registry.Snapshot() {
		b.WriteString(p.ProviderID + "|" + string(p.State) + "|" + itoa(p.SlotsFree) + ";")
	}
	return b.String()
}

func TestMultiTurnGateNativeTrustedPoolRoute(t *testing.T) {
	t.Run("native_pool_llama_tool_history_rejected_without_provider_mutation", func(t *testing.T) {
		s, registry := gatePoolServer(t, nil, gatePoolMember("member-llama", gateLlama32ID))
		before := providerStateFingerprint(registry)
		for _, model := range []string{gateLlama32ID, gateLlama32ID + "-free", "meta-llama/llama-3.2-3b-instruct"} {
			picked, routeErr := s.selectProviderExcluding(context.Background(), "rid", gatePoolToolRequest(t, model), http.Header{}, nil, "2024-01-01", &forwardState{})
			if routeErr == nil || routeErr.status != http.StatusBadRequest || routeErr.code != "unsupported_modelID_for_multi_turn" {
				t.Fatalf("model=%s: want 400 unsupported_modelID_for_multi_turn, got provider=%q err=%+v", model, picked.ProviderID, routeErr)
			}
			if picked.ProviderID != "" {
				t.Fatalf("model=%s: no provider may be selected, got %q", model, picked.ProviderID)
			}
		}
		if after := providerStateFingerprint(registry); after != before {
			t.Fatalf("provider state mutated: before=%s after=%s", before, after)
		}
	})

	t.Run("native_pool_plain_request_still_routes", func(t *testing.T) {
		s, _ := gatePoolServer(t, nil, gatePoolMember("member-llama", gateLlama32ID))
		plain := poolChatReqModel("P", gateLlama32ID)
		picked, routeErr := s.selectProviderExcluding(context.Background(), "rid", plain, http.Header{}, nil, "2024-01-01", &forwardState{})
		if routeErr != nil || picked.ProviderID != "member-llama" {
			t.Fatalf("plain pool request: provider=%q err=%+v", picked.ProviderID, routeErr)
		}
	})

	t.Run("native_pool_qwen_tool_history_routes", func(t *testing.T) {
		s, _ := gatePoolServer(t, nil, gatePoolMember("member-qwen", gateQwen36ID))
		picked, routeErr := s.selectProviderExcluding(context.Background(), "rid", gatePoolToolRequest(t, gateQwen36ID), http.Header{}, nil, "2024-01-01", &forwardState{})
		if routeErr != nil || picked.ProviderID != "member-qwen" {
			t.Fatalf("profiled model on native pool: provider=%q err=%+v", picked.ProviderID, routeErr)
		}
	})

	t.Run("withheld_external_allowlist_is_native_only", func(t *testing.T) {
		// SPEC-022 R-12.8: without negotiated finality the allowlist is
		// withheld, so the route can only reach native members.
		s, _ := gatePoolServer(t, []string{"llamacpp_loopback"}, gatePoolMember("member-llama", gateLlama32ID))
		_, routeErr := s.selectProviderExcluding(context.Background(), "rid", gatePoolToolRequest(t, gateLlama32ID), http.Header{}, nil, "2024-01-01", &forwardState{})
		if routeErr == nil || routeErr.code != "unsupported_modelID_for_multi_turn" {
			t.Fatalf("withheld allowlist: want unsupported_modelID_for_multi_turn, got %+v", routeErr)
		}
	})

	t.Run("external_engine_selection_passes_gate", func(t *testing.T) {
		s, _ := gatePoolServer(t, []string{"llamacpp_loopback"}, gatePoolMember("member-llama", gateLlama32ID))
		req := gatePoolToolRequest(t, gateLlama32ID)
		req.engineClass = "llamacpp_loopback"
		_, routeErr := s.selectProviderExcluding(context.Background(), "rid", req, http.Header{}, nil, "2024-01-01", &forwardState{settlementTrailersNegotiated: true})
		if routeErr != nil && routeErr.code == "unsupported_modelID_for_multi_turn" {
			t.Fatalf("explicit external engine must keep provider-side behavior, got %+v", routeErr)
		}
	})

	t.Run("negotiated_external_allowlist_without_selection_passes_gate", func(t *testing.T) {
		s, _ := gatePoolServer(t, []string{"llamacpp_loopback"}, gatePoolMember("member-llama", gateLlama32ID))
		_, routeErr := s.selectProviderExcluding(context.Background(), "rid", gatePoolToolRequest(t, gateLlama32ID), http.Header{}, nil, "2024-01-01", &forwardState{settlementTrailersNegotiated: true})
		if routeErr != nil && routeErr.code == "unsupported_modelID_for_multi_turn" {
			t.Fatalf("pool that may reach an external runtime keeps provider-side behavior, got %+v", routeErr)
		}
	})
}
