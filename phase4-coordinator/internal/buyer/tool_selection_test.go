package buyer

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

const toolSelectionModel = "mlx-community/Qwen3.6-35B-A3B-4bit"
const toolSelectionTools = `[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"],"additionalProperties":false}}}]`

func toolSelectionBody(choice string) []byte {
	return []byte(`{"model":"` + toolSelectionModel + `","max_tokens":128,"messages":[{"role":"user","content":"lookup"}],"tools":` + toolSelectionTools + `,"tool_choice":` + choice + `}`)
}
func selectionRequest(t *testing.T, choice string) chatRequest {
	t.Helper()
	r, status, code, msg := validateChatRequest(toolSelectionBody(choice))
	if status != 0 {
		t.Fatalf("validation %d %s %s", status, code, msg)
	}
	return r
}
func selectionProvider() pool.Provider {
	p := versionFloorProvider("capable", toolSelectionModel, "999.0.0")
	p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{{ModelID: toolSelectionModel, Runtime: engineClassNative, Modes: []string{"auto", "none", "required", "named"}, Validation: "schema-holdback-v1"}}
	return p
}

func TestToolSelectionForwardingUnchanged(t *testing.T) {
	for _, choice := range []string{`"auto"`, `"none"`, `"required"`, `{"type":"function","function":{"name":"lookup"}}`} {
		t.Run(choice, func(t *testing.T) {
			req := selectionRequest(t, choice)
			body, err := dispatchBodyForProvider(req, selectionProvider())
			if err != nil || string(body) != string(req.raw) {
				t.Fatalf("dispatch %s err=%v; want bytes unchanged %s", body, err, req.raw)
			}
		})
	}
	// A legacy session keeps ordinary auto behavior but cannot receive a guarantee.
	p := selectionProvider()
	p.ToolSelectionCapabilities = nil
	if _, err := dispatchBodyForProvider(selectionRequest(t, `"auto"`), p); err != nil {
		t.Fatal(err)
	}
	if _, err := dispatchBodyForProvider(selectionRequest(t, `"required"`), p); err == nil {
		t.Fatal("legacy provider accepted guarantee")
	}
}

func TestToolSelectionRequestValidation(t *testing.T) {
	for _, tc := range []struct{ name, body, code string }{
		{"unknown", string(toolSelectionBody(`"unexpected"`)), "invalid_tool_choice"},

		{"unavailable", string(toolSelectionBody(`{"type":"function","function":{"name":"missing"}}`)), "invalid_tool_choice"},
		{"named_outer_extra", string(toolSelectionBody(`{"type":"function","function":{"name":"lookup"},"extra":true}`)), "invalid_tool_choice"},
		{"named_function_extra", string(toolSelectionBody(`{"type":"function","function":{"name":"lookup","extra":true}}`)), "invalid_tool_choice"},
		{"required_no_tools", `{"model":"m","messages":[{"role":"user","content":"hi"}],"max_tokens":128,"tool_choice":"required"}`, "invalid_tool_choice"},
		{"non_object_schema", strings.Replace(string(toolSelectionBody(`"required"`)), `{"type":"object","properties":{"q"`, `{"type":"string","properties":{"q"`, 1), "unsupported_tool_schema"},
		{"duplicate_choice", strings.TrimSuffix(string(toolSelectionBody(`"auto"`)), "}") + `,"tool_choice":"required"}`, "invalid_tool_choice"},
		{"parallel_null", strings.TrimSuffix(string(toolSelectionBody(`"required"`)), "}") + `,"parallel_tool_calls":null}`, "invalid_tool_choice"},
		{"structured", strings.TrimSuffix(string(toolSelectionBody(`"required"`)), "}") + `,"response_format":{"type":"json_object"}}`, "unsupported_tool_choice"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, status, code, _ := validateChatRequest([]byte(tc.body))
			if status != http.StatusBadRequest || code != tc.code {
				t.Fatalf("got %d %s want 400 %s", status, code, tc.code)
			}
		})
	}
}

// #2107 D7: guaranteed selection follows the native provider's declared
// capability for its exact loaded model, not one hard-coded model ID.
func TestToolSelectionFollowsDeclaredCapabilityForAnyModel(t *testing.T) {
	req := selectionRequest(t, `"required"`)
	p := selectionProvider()
	p.ModelID = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
	p.ToolSelectionCapabilities[0].ModelID = p.ModelID
	if !providerSupportsToolSelection(p, req.toolSelection) {
		t.Fatal("a native provider declaring required for its loaded model must be eligible")
	}
}

func TestToolSelectionCapabilityRouting(t *testing.T) {
	req := selectionRequest(t, `"required"`)
	for _, mutation := range []string{"absent", "model", "runtime", "validation", "mode", "loopback", "unknown_adapter"} {
		t.Run(mutation, func(t *testing.T) {
			p := selectionProvider()
			switch mutation {
			case "absent":
				p.ToolSelectionCapabilities = nil
			case "model":
				p.ToolSelectionCapabilities[0].ModelID = "another"
			case "runtime":
				p.ToolSelectionCapabilities[0].Runtime = "unknown"
			case "validation":
				p.ToolSelectionCapabilities[0].Validation = "unknown"
			case "mode":
				p.ToolSelectionCapabilities[0].Modes = []string{"auto"}
			case "unknown_adapter":
				p.RuntimeSource = "unknown_adapter"
			case "loopback":
				p.RuntimeSource = "ollama_loopback"
			}
			if providerSupportsToolSelection(p, req.toolSelection) {
				t.Fatal("incompatible provider eligible")
			}
			registry := pool.NewRegistry(nil)
			registry.Register(&p, nil)
			s := NewServer(registry, zerolog.Nop(), time.Now().UTC())
			for _, header := range []string{"", "X-MacProvider-Provider", "X-MacProvider-Session"} {
				headers := http.Header{}
				if header != "" {
					v := p.ProviderID
					if header == "X-MacProvider-Session" {
						v = p.AssignedID
					}
					headers.Set(header, v)
				}
				_, err := s.selectProviderExcluding(context.Background(), "rid", req, headers, nil, "2024-01-01", &forwardState{})
				if err == nil || err.code != "unsupported_tool_choice" {
					t.Fatalf("%s route error %+v", header, err)
				}
			}
		})
	}
}

func toolSelectionCompletion(name, args, finish string, count int) []byte {
	calls := []any{}
	for i := 0; i < count; i++ {
		calls = append(calls, map[string]any{"id": "call_0123456789abcdef" + strings.Repeat("x", i), "type": "function", "function": map[string]any{"name": name, "arguments": args}})
	}
	b, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"index": 0, "message": map[string]any{"role": "assistant", "content": "", "tool_calls": calls}, "finish_reason": finish}}})
	return b
}
func TestToolSelectionOutputValidation(t *testing.T) {
	for _, tc := range []struct {
		name, choice, function, args, finish string
		count                                int
		parallel, valid                      bool
	}{
		{"required", `"required"`, "lookup", `{"q":"test"}`, "tool_calls", 1, true, true},
		{"prose", `"required"`, "lookup", `{}`, "stop", 0, true, false},
		{"named", `{"type":"function","function":{"name":"lookup"}}`, "lookup", `{"q":"test"}`, "tool_calls", 1, true, true},
		{"wrong_name", `{"type":"function","function":{"name":"lookup"}}`, "other", `{"q":"test"}`, "tool_calls", 1, true, false},
		{"schema_invalid", `"required"`, "lookup", `{"q":1}`, "tool_calls", 1, true, false},
		{"missing_required", `"required"`, "lookup", `{}`, "tool_calls", 1, true, false},
		{"truncated", `"required"`, "lookup", `{"q":`, "tool_calls", 1, true, false},
		{"exhaustion", `"required"`, "lookup", `{"q":"test"}`, "length", 1, true, false},
		{"parallel", `"required"`, "lookup", `{"q":"test"}`, "tool_calls", 2, true, true},
		{"serial", `"required"`, "lookup", `{"q":"test"}`, "tool_calls", 2, false, false},
		{"none", `"none"`, "lookup", `{}`, "stop", 0, true, true},
		{"none_call", `"none"`, "lookup", `{"q":"test"}`, "tool_calls", 1, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			policy := selectionRequest(t, tc.choice).toolSelection
			policy.parallel = tc.parallel
			body := toolSelectionCompletion(tc.function, tc.args, tc.finish, tc.count)
			if err := validateToolSelectionOutput(policy, body, false); (err == nil) != tc.valid {
				t.Fatalf("JSON err=%v valid=%v", err, tc.valid)
			}
			stream, err := chatCompletionJSONToSSE(body)
			if err == nil {
				if err := validateToolSelectionOutput(policy, stream, true); (err == nil) != tc.valid {
					t.Fatalf("SSE err=%v valid=%v stream=%s", err, tc.valid, stream)
				}
			} else if tc.valid {
				t.Fatalf("SSE conversion: %v", err)
			}
		})
	}
}

func TestToolSelectionQueuedReconnectFailsClosed(t *testing.T) {
	p := selectionProvider()
	p.ToolSelectionCapabilities = nil
	registry := pool.NewRegistry(nil)
	registry.Register(&p, nil)
	s := NewServer(registry, zerolog.Nop(), time.Now().UTC())
	waiter, ok := s.slotQueue.enter(p.ProviderID)
	if !ok {
		t.Fatal("queue enter failed")
	}
	defer s.slotQueue.leave(waiter)
	state := &forwardState{toolSelection: selectionRequest(t, `"required"`).toolSelection}
	if _, status := s.pollQueuedProvider(waiter, p.ModelID, nil, 100, state); status != queuedProviderTerminal {
		t.Fatalf("reconnect status %v", status)
	}
}

func TestToolSelectionTransportHoldback(t *testing.T) {
	for _, transport := range []string{"http_stream", "http_json_stream", "ws_stream", "ws_json"} {
		for _, scenario := range []string{"valid", "invalid_schema", "alias", "duplicate"} {
			valid := scenario == "valid"
			t.Run(fmt.Sprintf("%s/%s", transport, scenario), func(t *testing.T) {
				args := `{"q":"test"}`
				if scenario == "invalid_schema" {
					args = `{"q":1}`
				}
				body := toolSelectionCompletion("lookup", args, "tool_calls", 1)
				stream, err := chatCompletionJSONToSSE(body)
				if err != nil {
					t.Fatal(err)
				}
				if scenario == "alias" || scenario == "duplicate" {
					key := "Function"
					if scenario == "duplicate" {
						key = "function"
					}
					attack := []byte(`"function":{"name":"evil","arguments":"{}"},"` + key + `":`)
					body = bytes.Replace(body, []byte(`"function":`), attack, 1)
					stream = bytes.Replace(stream, []byte(`"function":`), attack, 1)
					// Exercise the usage sanitizer, which must not erase raw duplicates.
					body = bytes.Replace(body, []byte(`{`), []byte(`{"usage":{"completion_tokens":1},`), 1)
					stream = bytes.Replace(stream, []byte(`{`), []byte(`{"usage":{"completion_tokens":1},`), 1)
				}
				req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
				rr := httptest.NewRecorder()
				server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now())
				state := &forwardState{toolSelection: selectionRequest(t, `"required"`).toolSelection}
				p := selectionProvider()
				var result wsForwardResult
				var attempt requestLogAttempt
				if strings.HasPrefix(transport, "http") {
					upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
						if transport == "http_stream" {
							w.Header().Set("Content-Type", "text/event-stream")
							_, _ = w.Write(stream)
						} else {
							w.Header().Set("Content-Type", "application/json")
							_, _ = w.Write(body)
						}
					}))
					defer upstream.Close()
					p.EndpointURL = upstream.URL
					requestBody := append([]byte(nil), toolSelectionBody(`"required"`)...)
					requestBody = []byte(strings.TrimSuffix(string(requestBody), "}") + `,"stream":true}`)
					result, _, attempt = server.forwardStreaming(rr, req, "tool-test", requestBody, p, p.ModelID, time.Second, nil, state, 0)
				} else {
					chunks := make(chan providerws.InferenceResponseChunk)
					done := make(chan providerws.InferenceResponseEnd, 1)
					go func() {
						data := stream
						if transport == "ws_json" {
							data = body
						}
						chunks <- providerws.InferenceResponseChunk{Data: string(data)}
						close(chunks)
						done <- providerws.InferenceResponseEnd{Status: "complete"}
					}()
					relay := &providerws.RelayStream{Chunks: chunks, Done: done, Errors: make(chan error, 1)}
					if transport == "ws_stream" {
						result, attempt = server.forwardWSStreaming(rr, req, "tool-test", p, relay, state, 0)
					} else {
						result, attempt = server.forwardWSNonStreaming(rr, req, "tool-test", p, relay, nil, nil, state, 0)
					}
				}
				if valid {
					if result != wsForwardComplete || !strings.Contains(rr.Body.String(), "lookup") {
						t.Fatalf("result=%s attempt=%+v output=%s", result, attempt, rr.Body.String())
					}
				} else {
					if result == wsForwardComplete || attempt.Status != http.StatusBadGateway || attempt.ErrorCode != "tool_selection_validation_failed" {
						t.Fatalf("invalid result=%s attempt=%+v", result, attempt)
					}
					if strings.Contains(rr.Body.String(), "lookup") || strings.Contains(rr.Body.String(), "tool_calls") {
						t.Fatalf("invalid generated call leaked: %s", rr.Body.String())
					}
					if attempt.PromptTokens != nil || attempt.CompletionTokens != nil || attempt.SettlementReceipt != "" {
						t.Fatalf("invalid completion became payable: %+v", attempt)
					}
				}
			})
		}
	}
}

func TestToolSelectionStreamingRejectsMalformedTerminal(t *testing.T) {
	policy := selectionRequest(t, `"required"`).toolSelection
	valid, _ := chatCompletionJSONToSSE(toolSelectionCompletion("lookup", `{"q":"test"}`, "tool_calls", 1))
	for name, body := range map[string][]byte{
		"missing_done":        bytes.ReplaceAll(valid, []byte("data: [DONE]\n\n"), nil),
		"earlier_error":       append([]byte("data: {\"error\":{\"message\":\"failed\"}}\n\n"), valid...),
		"duplicate_finish":    bytes.Replace(valid, []byte("data: [DONE]"), []byte("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]"), 1),
		"unterminated_done":   bytes.TrimSuffix(valid, []byte("\n\n")),
		"post_finish_content": bytes.Replace(valid, []byte("data: [DONE]"), []byte("data: {\"choices\":[{\"delta\":{\"content\":\"later\"}}]}\n\ndata: [DONE]"), 1),
	} {
		t.Run(name, func(t *testing.T) {
			if validateToolSelectionOutput(policy, body, true) == nil {
				t.Fatalf("invalid terminal accepted %s", body)
			}
		})
	}
}

func TestToolSelectionCancelWithheldOutput(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)
	rr := httptest.NewRecorder()
	server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now())
	state := &forwardState{toolSelection: selectionRequest(t, `"required"`).toolSelection}
	relay := &providerws.RelayStream{Chunks: make(chan providerws.InferenceResponseChunk), Done: make(chan providerws.InferenceResponseEnd), Errors: make(chan error)}
	result, _ := server.forwardWSStreaming(rr, req, "tool-test", selectionProvider(), relay, state, 0)
	if result != wsForwardCancelled || rr.Body.Len() != 0 {
		t.Fatalf("cancel result=%s body=%s", result, rr.Body.String())
	}
	// A fully valid body read after cancellation must still never commit.
	valid, _ := chatCompletionJSONToSSE(toolSelectionCompletion("lookup", `{"q":"test"}`, "tool_calls", 1))
	resp := &http.Response{Body: io.NopCloser(bytes.NewReader(valid)), Trailer: http.Header{}}
	rr = httptest.NewRecorder()
	result, _, attempt := server.forwardStreamingBuffered(rr, req, "tool-test", resp, selectionProvider(), toolSelectionModel, streamingModeToolSelectionHoldback, "", state, 0)
	if result != wsForwardCancelled || rr.Body.Len() != 0 || attempt.SettlementReceipt != "" || attempt.CompletionTokens != nil {
		t.Fatalf("cancelled valid HTTP result=%s body=%s attempt=%+v", result, rr.Body.String(), attempt)
	}
	// HTTP buffered EOF interruption also exposes no generated prefix.
	resp = &http.Response{Body: io.NopCloser(io.MultiReader(strings.NewReader(`data: {"choices":[{"delta":{"content":"prefix"}}]}\n\n`), errReader{context.Canceled})), Trailer: http.Header{}}
	rr = httptest.NewRecorder()
	result, _, _ = server.forwardStreamingBuffered(rr, req, "tool-test", resp, selectionProvider(), toolSelectionModel, streamingModeToolSelectionHoldback, "", state, 0)
	if result == wsForwardComplete || rr.Body.Len() != 0 {
		t.Fatalf("interrupted HTTP result=%s body=%s", result, rr.Body.String())
	}
}

func TestToolSelectionBoundedNumericSchemas(t *testing.T) {
	for _, token := range []string{"1e999999999", "1e-999999999", "0e-999999999", "1e-324", "9007199254740992", "-9007199254740992", strings.Repeat("1", 129)} {
		t.Run(token[:min(len(token), 32)], func(t *testing.T) {
			if boundedToolNumber(token) {
				t.Fatal("unbounded number admitted")
			}
			if toolSchemaValuesEqual(json.Number(token), json.Number(token)) {
				t.Fatal("unbounded number compared")
			}
			for _, keyword := range []string{"const", "enum"} {
				value := token
				if keyword == "enum" {
					value = "[" + token + "]"
				}
				schema := `{"type":"object","properties":{"q":{"type":"number","` + keyword + `":` + value + `}},"required":["q"],"additionalProperties":false}`
				body := strings.Replace(string(toolSelectionBody(`"required"`)), `{"type":"object","properties":{"q":{"type":"string"}},"required":["q"],"additionalProperties":false}`, schema, 1)
				_, status, code, _ := validateChatRequest([]byte(body))
				if status != http.StatusBadRequest || code != "unsupported_tool_schema" {
					t.Fatalf("%s numeric token admitted status=%d code=%s", keyword, status, code)
				}
			}
		})
	}
	for _, tc := range []struct {
		left, right string
		equal       bool
	}{
		{"1", "1.0", true}, {"1", "1e0", true}, {"9007199254740990", "9007199254740991", false}, {"0", "-0", true}, {"1.5", "1.50", true},
	} {
		if got := toolSchemaValuesEqual(json.Number(tc.left), json.Number(tc.right)); got != tc.equal {
			t.Fatalf("%s == %s got %v", tc.left, tc.right, got)
		}
	}
}

func TestToolSelectionNumericMultipleOfParity(t *testing.T) {
	for _, tc := range []struct {
		typ, value, multiple string
		valid                bool
	}{
		{"integer", "9007199254740993", "3", false},
		{"integer", "9007199254740994", "3", false},
		{"number", "0.3", "0.1", true},
		{"number", "0.31", "0.1", false},
		{"number", "1.0000000000001", "1", true},
		{"number", "10000000000000000.0", "1", false},
		{"number", "1e20", "3", false},
	} {
		schema := json.RawMessage(`{"type":"` + tc.typ + `","multipleOf":` + tc.multiple + `}`)
		if got := toolArgumentsConform(schema, []byte(tc.value)); got != tc.valid {
			t.Fatalf("%s %s multipleOf %s got %v", tc.typ, tc.value, tc.multiple, got)
		}
	}
}

func TestToolSelectionBudgetAndEnvelopeValidation(t *testing.T) {
	base := string(toolSelectionBody(`"required"`))
	for name, body := range map[string]string{
		"missing_budget":    strings.Replace(base, `"max_tokens":128,`, ``, 1),
		"zero_budget":       strings.Replace(base, `"max_tokens":128`, `"max_tokens":0`, 1),
		"large_budget":      strings.Replace(base, `"max_tokens":128`, `"max_tokens":16385`, 1),
		"fractional_budget": strings.Replace(base, `"max_tokens":128`, `"max_tokens":1.5`, 1),
	} {
		t.Run(name, func(t *testing.T) {
			_, status, code, _ := validateChatRequest([]byte(body))
			if status != 400 || code != "unsupported_tool_choice" {
				t.Fatalf("%d %s", status, code)
			}
		})
	}
	alias := strings.Replace(base, `"max_tokens":128`, `"max_completion_tokens":128`, 1)
	if req, status, code, _ := validateChatRequest([]byte(alias)); status != 0 || req.maxTokens != 128 {
		t.Fatalf("alias status=%d code=%s budget=%d", status, code, req.maxTokens)
	}
	for name, body := range map[string]string{
		"function_alias":   strings.Replace(base, `"function":`, `"Function":`, 1),
		"parameters_alias": strings.Replace(base, `"parameters":`, `"Parameters":`, 1),
		"name_alias":       strings.Replace(base, `"name":"lookup"`, `"name":"evil","Name":"lookup"`, 1),
		"choice_alias":     strings.Replace(string(toolSelectionBody(`{"type":"function","function":{"name":"lookup"}}`)), `"function":{"name":"lookup"}}}`, `"Function":{"name":"lookup"}}}`, 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, status, _, _ := validateChatRequest([]byte(body)); status != 400 {
				t.Fatalf("alias accepted %s", body)
			}
		})
	}
}

func TestToolSelectionSchemaNullKeywordShapes(t *testing.T) {
	for _, schema := range []string{
		`{"type":"object","additionalProperties":null}`,
		`{"type":"object","properties":null,"additionalProperties":false}`,
		`{"type":"object","required":null,"additionalProperties":false}`,
		`{"type":"object","properties":{"":{"type":"string"}},"required":[null],"additionalProperties":false}`,
		`{"type":"object","properties":{"q":{"type":"string","enum":null}},"required":["q"],"additionalProperties":false}`,
		`{"type":"object","properties":{"q":{"type":"array","items":null}},"required":["q"],"additionalProperties":false}`,
	} {
		// SPEC-018 §3.11 v0.3.1: an object schema outside the strict subset is
		// admitted, but never as strict (its output gets the required-keys check).
		body := strings.Replace(string(toolSelectionBody(`"required"`)), `{"type":"object","properties":{"q":{"type":"string"}},"required":["q"],"additionalProperties":false}`, schema, 1)
		var raw map[string]json.RawMessage
		if err := json.Unmarshal([]byte(body), &raw); err != nil {
			t.Fatal(err)
		}
		policy, reqErr := validateToolSelection([]byte(body), raw)
		if reqErr != nil || policy == nil || policy.strict["lookup"] {
			t.Fatalf("schema %s: policy=%+v err=%+v; want admitted non-strict", schema, policy, reqErr)
		}
	}
	// null is a valid scalar value in a null schema.
	if !toolSchemaShapesSupported([]byte(`{"type":"null","const":null,"enum":[null]}`), 1) {
		t.Fatal("null scalar rejected")
	}
}

func TestToolSelectionStrictConsolidationPreservesFragments(t *testing.T) {
	policy := selectionRequest(t, `"required"`).toolSelection
	policy.schemas["lookup"] = bytes.Replace(policy.schemas["lookup"], []byte(`"type":"string"`), []byte(`"type":"string","const":"abab"`), 1)
	stream := []byte(`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"ab"}}]}}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ab\"}"}}]}}]}

data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

`)
	if validateToolSelectionOutput(policy, stream, true) != nil {
		t.Fatalf("fixture invalid: %s", stream)
	}
	out, err := consolidatedToolCallSSEForSelection(stream, true)
	if err != nil || validateToolSelectionOutput(policy, out, true) != nil {
		t.Fatalf("validated arguments changed err=%v output=%s", err, out)
	}
}

func TestToolSelectionHTTPGeneratedFailureEnvelope(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(toolSelectionCompletion("lookup", `{"q":1}`, "tool_calls", 1))
	}))
	defer upstream.Close()
	p := selectionProvider()
	p.EndpointURL = upstream.URL
	registry := pool.NewRegistry(nil)
	registry.Register(&p, nil)
	server := NewServer(registry, zerolog.Nop(), time.Now())
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(toolSelectionBody(`"required"`)))
	server.Handler().ServeHTTP(rr, req)
	var envelope struct {
		Error struct {
			Code          string `json:"code"`
			Retryable     bool   `json:"retryable"`
			InferenceRan  bool   `json:"inference_ran"`
			SettlementRan bool   `json:"settlement_ran"`
		} `json:"error"`
	}
	if json.Unmarshal(rr.Body.Bytes(), &envelope) != nil || rr.Code != 502 || envelope.Error.Code != "tool_selection_validation_failed" || envelope.Error.Retryable || !envelope.Error.InferenceRan || !envelope.Error.SettlementRan {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

// #2107 validation: the buyer-UX suite's ordinary OpenAI tool (no
// additionalProperties:false) was refused for required/named. It is admitted
// as a non-strict schema, and its output must still hold the required keys.
func TestToolSelectionAdmitsOrdinaryOpenAISchema(t *testing.T) {
	body := []byte(`{"model":"m","max_tokens":1024,"messages":[{"role":"user","content":"Read the file /etc/hosts using the read_file tool."}],"tools":[{"type":"function","function":{"name":"read_file","description":"Read a file from disk","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}],"tool_choice":"required"}`)
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		t.Fatal(err)
	}
	policy, reqErr := validateToolSelection(body, raw)
	if reqErr != nil || policy == nil || policy.strict["read_file"] {
		t.Fatalf("policy=%+v err=%+v; want admitted non-strict", policy, reqErr)
	}
	output := func(arguments string) []byte {
		encoded, _ := json.Marshal(arguments)
		return []byte(`{"choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read_file","arguments":` + string(encoded) + `}}]}}]}`)
	}
	if err := validateToolSelectionOutput(policy, output(`{"path":"/etc/hosts"}`), false); err != nil {
		t.Fatalf("valid call rejected: %v", err)
	}
	// Audit r1: the numeric domain holds for non-strict output too.
	if err := validateToolSelectionOutput(policy, output(`{"path":"/etc/hosts","n":9007199254740993}`), false); err == nil {
		t.Fatal("out-of-domain number accepted for a non-strict schema")
	}
	for _, arguments := range []string{`{}`, `{"file":"/etc/hosts"}`, `[]`} {
		if err := validateToolSelectionOutput(policy, output(arguments), false); err == nil {
			t.Fatalf("arguments %s accepted without the required path", arguments)
		}
	}
}

// Audit r1: only the exact "required" member names required keys; a
// differently cased member must not replace it (Swift uses exact lookup).
func TestToolSelectionNonStrictRequiredIsExactKey(t *testing.T) {
	schema := json.RawMessage(`{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"Required":[]}`)
	if toolArgumentsMatchSchema(schema, false, json.RawMessage(`{}`)) {
		t.Fatal("cased Required member replaced the required list")
	}
	if !toolArgumentsMatchSchema(schema, false, json.RawMessage(`{"path":"a"}`)) {
		t.Fatal("valid arguments rejected")
	}
}

// Audit r2: container depth counts the root as 1 (empty deepest container
// included), and a null required entry names no key.
func TestToolSelectionNonStrictDepthAndRequiredEntries(t *testing.T) {
	nest := func(levels int) string {
		return strings.Repeat(`{"a":`, levels-1) + `{}` + strings.Repeat(`}`, levels-1)
	}
	if got := jsonContainerDepth([]byte(nest(32))); got != 32 {
		t.Fatalf("depth %d want 32", got)
	}
	if got := jsonContainerDepth([]byte(nest(33))); got != 33 {
		t.Fatalf("depth %d want 33", got)
	}
	schema := json.RawMessage(`{"type":"object","required":[null,"path",1]}`)
	if !toolArgumentsMatchSchema(schema, false, json.RawMessage(`{"path":"a"}`)) {
		t.Fatal("null or non-string required entry demanded a key")
	}
	if toolArgumentsMatchSchema(schema, false, json.RawMessage(`{}`)) {
		t.Fatal("string required entry not enforced")
	}
}
