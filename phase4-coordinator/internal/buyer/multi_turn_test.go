package buyer

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
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
	nativeRoute := gateMultiTurnRequest(t, gateLlama32ID)
	nativeRoute.engineClass = engineClassNative
	poolRoute := gateMultiTurnRequest(t, gateLlama32ID)
	poolRoute.poolID = "pool-a"
	externalRoute := gateMultiTurnRequest(t, gateLlama32ID)
	externalRoute.engineClass = "llamacpp_loopback"

	const reject = "unsupported_modelID_for_multi_turn"
	cases := []struct {
		name     string
		req      chatRequest
		wantCode string
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
		{name: "trusted_pool_route_untouched", req: poolRoute},
		{name: "external_engine_route_untouched", req: externalRoute},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			status, code, msg := unsupportedMultiTurnToolModel(tc.req, catalog)
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
	if status, _, _ := unsupportedMultiTurnToolModel(gateMultiTurnRequest(t, gateLlama32ID), nil); status != 0 {
		t.Fatalf("nil catalog must not reject, status=%d", status)
	}
	tier2.ResetForTest()
	if status, _, _ := unsupportedMultiTurnToolModel(gateMultiTurnRequest(t, gateLlama32ID), tier2.Default().ModelIDs); status != 0 {
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
	var hits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`))
	}))
	t.Cleanup(upstream.Close)
	registry := pool.NewRegistry(nil)
	now := time.Now().UTC()
	registry.Register(&pool.Provider{
		ProviderID:       "p1",
		AssignedID:       "session-1",
		Hostname:         "p1.local",
		ModelID:          gateLlama32ID,
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
