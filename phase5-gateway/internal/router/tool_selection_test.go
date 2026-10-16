package router

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func TestToolSelectionFacadeTranslations(t *testing.T) {
	for _, stream := range []bool{false, true} {
		for _, mode := range []string{"auto", "none", "required", "named"} {
			t.Run(mode+"/stream="+map[bool]string{false: "false", true: "true"}[stream], func(t *testing.T) {
				var want any = mode
				var responsesChoice any = mode
				messagesChoice := map[string]any{"type": mode, "disable_parallel_tool_use": false}
				if mode == "required" {
					messagesChoice["type"] = "any"
				}
				if mode == "named" {
					want = map[string]any{"type": "function", "function": map[string]any{"name": "lookup"}}
					responsesChoice = map[string]any{"type": "function", "name": "lookup"}
					messagesChoice["type"], messagesChoice["name"] = "tool", "lookup"
				}
				responsesBody, _ := json.Marshal(map[string]any{
					"model": openRouterQwen36A3BID, "input": "hi", "store": false, "stream": stream,
					"tool_choice": responsesChoice, "parallel_tool_calls": true,
					"tools": []any{map[string]any{"type": "function", "name": "lookup", "parameters": map[string]any{"type": "object"}}},
				})
				r := newResponsesAdapter(httptest.NewRecorder(), "request", nil)
				translated, err := r.translateRequest(responsesBody)
				if err != nil {
					t.Fatal(err)
				}
				assertToolSelectionTranslation(t, translated, want, stream)
				messagesBody, _ := json.Marshal(map[string]any{
					"model": openRouterQwen36A3BID, "max_tokens": 128, "stream": stream,
					"messages":    []any{map[string]any{"role": "user", "content": "hi"}},
					"tool_choice": messagesChoice,
					"tools":       []any{map[string]any{"name": "lookup", "input_schema": map[string]any{"type": "object"}}},
				})
				a := newAnthropicMessagesAdapter(httptest.NewRecorder(), "request", nil)
				translated, aerr := a.translateRequest(http.Header{}, messagesBody)
				if aerr != nil {
					t.Fatal(aerr)
				}
				assertToolSelectionTranslation(t, translated, want, stream)
			})
		}
	}
}

func TestToolSelectionGatewayErrorClassification(t *testing.T) {
	for _, stream := range []bool{false, true} {
		for _, endpoint := range []string{"chat", "responses", "messages"} {
			for _, generated := range []bool{false, true} {
				label := endpoint + "/stream=" + map[bool]string{false: "false", true: "true"}[stream] + "/generated=" + map[bool]string{false: "false", true: "true"}[generated]
				t.Run(label, func(t *testing.T) {
					status, code := http.StatusBadRequest, "unsupported_tool_choice"
					if generated {
						status, code = http.StatusBadGateway, "tool_selection_validation_failed"
					}
					hits := 0
					client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
						hits++
						var request map[string]any
						if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
							t.Fatal(err)
						}
						if request["tool_choice"] != "required" {
							t.Fatalf("selection changed at coordinator boundary: %v", request)
						}
						body := `{"error":{"message":"tool selection failed","type":"invalid_request_error","code":"` + code + `","retryable":false}}`
						if stream && generated {
							return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream"}}, "data: "+body+"\n\ndata: [DONE]\n\n"), nil
						}
						return responseWithBody(status, http.Header{"Content-Type": []string{"application/json"}}, body), nil
					})}
					h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
						cfg.Coordinator.BuyerURL = "http://coordinator.test"
						cfg.Features.AnthropicMessagesEnabled = true
						cfg.Features.ResponsesAPIEnabled = true
					}, WithHTTPClient(client))
					key := createAccountAndKey(t, store, cfg, "acct_selection_error")
					streamJSON := map[bool]string{false: "false", true: "true"}[stream]
					var response *httptest.ResponseRecorder
					switch endpoint {
					case "chat":
						response = postChat(t, h, key, `{"model":"m","stream":`+streamJSON+`,"max_tokens":32,"messages":[{"role":"user","content":"hi"}],"tool_choice":"required","tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object"}}}]}`, nil)
					case "responses":
						response = postResponses(t, h, key, `{"model":"m","stream":`+streamJSON+`,"store":false,"max_output_tokens":32,"input":"hi","tool_choice":"required","tools":[{"type":"function","name":"lookup","parameters":{"type":"object"}}]}`, nil)
					case "messages":
						response = postAnthropicMessages(t, h, key, `{"model":"m","stream":`+streamJSON+`,"max_tokens":32,"messages":[{"role":"user","content":"hi"}],"tool_choice":{"type":"any"},"tools":[{"name":"lookup","input_schema":{"type":"object"}}]}`, nil)
					}
					body := response.Body.String()
					if !strings.Contains(body, code) || hits != 1 {
						t.Fatalf("error lost or retried: hits=%d status=%d body=%s", hits, response.Code, body)
					}
					if !(stream && generated) && response.Code != status {
						t.Fatalf("status=%d want %d", response.Code, status)
					}
					for _, success := range []string{"response.completed", "event: message_stop", `"finish_reason":"stop"`, `"finish_reason":"tool_calls"`} {
						if strings.Contains(body, success) {
							t.Fatalf("failure included successful result: %s", body)
						}
					}
					snapshot := gatewaySettlementSnapshot(t, dbPath, "acct_selection_error")
					if snapshot.settledRows != 0 || snapshot.activeRows != 0 {
						t.Fatalf("failure settled or leaked reservation: %+v", snapshot)
					}
				})
			}
		}
	}
}

func assertToolSelectionTranslation(t *testing.T, raw []byte, want any, stream bool) {
	t.Helper()
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(body["tool_choice"], want) || body["stream"] != stream || body["parallel_tool_calls"] != true {
		t.Fatalf("selection or stream/parallel policy changed: %s", raw)
	}
}

func TestToolSelectionFacadeRejectsMissingToolsAndNames(t *testing.T) {
	for _, choice := range []string{`{"type":"any"}`, `{"type":"tool","name":"missing"}`} {
		a := newAnthropicMessagesAdapter(httptest.NewRecorder(), "request", nil)
		_, err := a.translateRequest(http.Header{}, []byte(`{"model":"m","max_tokens":8,"messages":[{"role":"user","content":"hi"}],"tool_choice":`+choice+`}`))
		if err == nil || err.code != "invalid_tools" {
			t.Fatalf("choice=%s error=%v", choice, err)
		}
	}
	for _, choice := range []string{`true`, `42`, `[]`, `"required"`, `{"type":"function","name":"missing"}`} {
		r := newResponsesAdapter(httptest.NewRecorder(), "request", nil)
		_, err := r.translateRequest([]byte(`{"model":"m","input":"hi","store":false,"tool_choice":` + choice + `}`))
		if err == nil {
			t.Fatalf("Responses accepted %s without tools", choice)
		}
	}
}

func TestToolSelectionFacadeStreamingFailureNeverCompletes(t *testing.T) {
	for _, code := range []string{"tool_selection_validation_failed", "provider_timeout", "stream_truncated"} {
		t.Run(code, func(t *testing.T) {
			line := `data: {"error":{"type":"upstream_provider_error","code":"` + code + `","message":"validation failed","retryable":false}}`
			rec := httptest.NewRecorder()
			a := newAnthropicMessagesAdapter(rec, "request", nil)
			a.stream, a.guaranteedToolSelection = true, true
			a.WriteHeader(http.StatusOK)
			a.handleChatStreamLine(line)
			a.handleChatStreamLine("data: [DONE]")
			a.finish()
			body := rec.Body.String()
			if !strings.Contains(body, "event: error") || strings.Contains(body, "event: message_delta") || strings.Contains(body, "event: message_stop") || strings.Contains(body, "tool_use") {
				t.Fatalf("Messages failure became success: %s", body)
			}
			rec = httptest.NewRecorder()
			r := newResponsesAdapter(rec, "request", nil)
			r.stream = true
			r.WriteHeader(http.StatusOK)
			r.handleChatStreamLine(line)
			r.handleChatStreamLine("data: [DONE]")
			body = rec.Body.String()
			if !strings.Contains(body, "event: response.failed") || strings.Contains(body, "event: response.completed") || strings.Contains(body, "function_call") {
				t.Fatalf("Responses failure became success: %s", body)
			}
		})
	}
}

func TestToolSelectionCapabilitiesRequireCurrentEnforcement(t *testing.T) {
	yes, no := true, false
	capability := toolSelectionCapability{ModelID: openRouterQwen36A3BID, Runtime: "mlx_cache", Modes: []string{"auto", "none", "required", "named"}, Validation: "schema-holdback-v1"}
	base := poolzProviderRow{ModelID: openRouterQwen36A3BID, RuntimeSource: "mlx_cache", State: "ready", SlotsFree: 1, SlotsTotal: 1, MaxContextTokens: 8192, RoutingEligible: &yes, ServingEligible: &yes, ToolSelectionCapabilities: []toolSelectionCapability{capability}}
	for _, test := range []struct {
		name   string
		mutate func(*poolzProviderRow)
		want   string
	}{
		{"supported", func(*poolzProviderRow) {}, "auto,none,required,named"},
		{"legacy", func(p *poolzProviderRow) { p.ToolSelectionCapabilities = nil }, "auto"},
		{"loopback", func(p *poolzProviderRow) { p.RuntimeSource = "ollama_loopback" }, "auto"},
		{"stale_model", func(p *poolzProviderRow) { p.ToolSelectionCapabilities[0].ModelID = "old" }, "auto"},
		{"unknown_validation", func(p *poolzProviderRow) { p.ToolSelectionCapabilities[0].Validation = "parser-only" }, "auto"},
		{"ineligible", func(p *poolzProviderRow) { p.ServingEligible = &no; p.RoutingEligible = &no }, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			p := base
			p.ToolSelectionCapabilities = []toolSelectionCapability{capability}
			test.mutate(&p)
			status := aggregateStatus(poolzResponse{Pool: []poolzProviderRow{p}}, 1, time.Now())
			modes := status.ServingToolChoiceModes[p.ModelID]
			if got := strings.Join(modes, ","); got != test.want {
				t.Fatalf("modes=%s want %s", got, test.want)
			}
			params := openRouterSupportedParameters(p.ModelID, 128, modes...)
			wantEnum := "auto"
			if test.name == "supported" {
				wantEnum = "auto,none,required"
			}
			if got := strings.Join(params["tool_choice"].Values, ","); got != wantEnum {
				t.Fatalf("public enum=%s want %s", got, wantEnum)
			}
		})
	}
}
