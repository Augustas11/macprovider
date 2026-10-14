package integration

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// #1570 OpenRouter-shaped requests through the real gateway and coordinator.
// Every case ends in a 2xx or a clean 4xx, never a 5xx.

func openRouterShapedErrorCode(t *testing.T, body []byte) string {
	t.Helper()
	var envelope struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		t.Fatalf("decode error body: %v body=%s", err, string(body))
	}
	return envelope.Error.Code
}

// SPEC-019 v0.3.0 §1a: OpenAI-shaped json_schema requests (no strict, or
// strict:false, with optional fields, anyOf and $defs) are accepted; a
// strict:true request with the same schema still fails closed with a 400.
func TestOpenRouterShapedJSONSchemaModes(t *testing.T) {
	// Non-strict requests route only to provider CLI 1.8.242+ (SPEC-019 §1a
	// rollout).
	s := newScenario(t, scenarioOpts{seedAccount: true, providerSetup: func(fp *fakeProvider) {
		fp.binaryVersion = "1.8.242"
	}})
	schema := `{"type":"object","properties":{"name":{"type":"string"},"nick":{"anyOf":[{"type":"string"},{"type":"null"}]}},"required":["name"],"$defs":{"x":{"type":"string"}}}`
	request := func(strictField string) string {
		return `{"model":"llama-3.2-3b-instruct","max_tokens":32,"messages":[{"role":"user","content":"name a person"}],` +
			`"response_format":{"type":"json_schema","json_schema":{"name":"person"` + strictField + `,"schema":` + schema + `}}}`
	}
	for _, tc := range []struct {
		name        string
		strictField string
		wantStatus  int
		wantCode    string
	}{
		{"strict false", `,"strict":false`, http.StatusOK, ""},
		{"strict absent", ``, http.StatusOK, ""},
		{"strict true", `,"strict":true`, http.StatusBadRequest, "json_schema_unsupported_keyword"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			status, _, body := s.chatRequest(nil, request(tc.strictField))
			if status != tc.wantStatus {
				t.Fatalf("status=%d want %d body=%s", status, tc.wantStatus, string(body))
			}
			if tc.wantCode != "" {
				if got := openRouterShapedErrorCode(t, body); got != tc.wantCode {
					t.Fatalf("code=%q want %q body=%s", got, tc.wantCode, string(body))
				}
			}
		})
	}
}

// SPEC-006 §7.2.1: a prompt within the provider's advertised context is
// routed even when raw bytes/4 would exceed it. Russian text packs about four
// bytes per Qwen token, so bytes/4 over-counted it and the coordinator
// rejected it with 413 context_exceeds_capacity.
func TestOpenRouterShapedLongContextWithinAdvertisedMax(t *testing.T) {
	const contextTokens = 16384
	s := newScenario(t, scenarioOpts{
		seedAccount: true,
		// The fake provider answers no WS preflight; keep this prompt below
		// the preflight threshold so the context check is the only gate.
		coordinatorConfig: func(_ *scenario, cfg map[string]any) {
			cfg["routing"].(map[string]any)["preflight_threshold_tokens"] = contextTokens
		},
		providerSetup: func(p *fakeProvider) {
			p.maxContextTokens = contextTokens
		},
	})
	prompt := strings.Repeat("Машинное обучение — это область искусственного интеллекта. ", 650)
	encoded, _ := json.Marshal(prompt)
	body := `{"model":"llama-3.2-3b-instruct","max_tokens":32,"messages":[{"role":"user","content":` + string(encoded) + `}]}`
	if len(body)/4 <= contextTokens {
		t.Fatalf("fixture: bytes/4=%d must exceed the %d-token context", len(body)/4, contextTokens)
	}
	status, _, respBody := s.chatRequest(nil, body)
	if status != http.StatusOK {
		t.Fatalf("status=%d body=%s", status, string(respBody))
	}
}

// A prompt that really exceeds every provider's context is a clean 413.
func TestOpenRouterShapedOverContextIsClean413(t *testing.T) {
	s := newScenario(t, scenarioOpts{seedAccount: true})
	prompt := strings.Repeat("alpha bravo charlie delta echo foxtrot ", 2000)
	status, _, body := s.chatRequest(nil, `{"model":"llama-3.2-3b-instruct","max_tokens":32,"messages":[{"role":"user","content":"`+prompt+`"}]}`)
	if status != http.StatusRequestEntityTooLarge {
		t.Fatalf("status=%d want 413 body=%s", status, string(body))
	}
	if got := openRouterShapedErrorCode(t, body); got != "context_exceeds_capacity" {
		t.Fatalf("code=%q want context_exceeds_capacity", got)
	}
}

// The 09-30 tool_result_roundtrip shape: an assistant tool_calls turn and a
// role:"tool" result, with the non-OpenAI tool_call_id format other upstreams
// produce, crosses the gateway (id rewrite) and coordinator validation and is
// served. The non-profile model case (400 unsupported_modelID_for_multi_turn
// before dispatch) needs catalog resolution and is covered by coordinator
// unit tests.
func TestOpenRouterShapedToolRoundtripIsServed(t *testing.T) {
	s := newScenario(t, scenarioOpts{seedAccount: true})
	body := `{"model":"llama-3.2-3b-instruct","max_tokens":32,` +
		`"tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],` +
		`"messages":[` +
		`{"role":"user","content":"weather in Paris?"},` +
		`{"role":"assistant","content":null,"tool_calls":[{"id":"toolu_01A","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]},` +
		`{"role":"tool","tool_call_id":"toolu_01A","content":"{\"temp_c\":18}"}]}`
	status, _, respBody := s.chatRequest(nil, body)
	if status != http.StatusOK {
		t.Fatalf("status=%d want 200 body=%s", status, string(respBody))
	}
	forwarded, _ := s.fakeProv.LastReceiptBodies()
	var req struct {
		Messages []struct {
			Role       string `json:"role"`
			ToolCallID string `json:"tool_call_id"`
			ToolCalls  []struct {
				ID string `json:"id"`
			} `json:"tool_calls"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(forwarded, &req); err != nil || len(req.Messages) != 3 {
		t.Fatalf("forwarded body=%s err=%v", string(forwarded), err)
	}
	callID := req.Messages[1].ToolCalls[0].ID
	if !strings.HasPrefix(callID, "call_") || req.Messages[2].ToolCallID != callID {
		t.Fatalf("tool_call_id pairing not preserved through the id rewrite: call=%q result=%q", callID, req.Messages[2].ToolCallID)
	}
}

// Bad OpenRouter-forwarded parameters are clean 4xx responses.
func TestOpenRouterShapedBadParamsAreClean4xx(t *testing.T) {
	s := newScenario(t, scenarioOpts{seedAccount: true})
	for _, tc := range []struct {
		name string
		body string
	}{
		{"temperature out of range", `{"model":"llama-3.2-3b-instruct","temperature":5,"messages":[{"role":"user","content":"hi"}]}`},
		{"n above one", `{"model":"llama-3.2-3b-instruct","n":2,"messages":[{"role":"user","content":"hi"}]}`},
		{"unknown response_format type", `{"model":"llama-3.2-3b-instruct","response_format":{"type":"yaml"},"messages":[{"role":"user","content":"hi"}]}`},
		{"strict not boolean", `{"model":"llama-3.2-3b-instruct","response_format":{"type":"json_schema","json_schema":{"name":"x","strict":"yes","schema":{"type":"object"}}},"messages":[{"role":"user","content":"hi"}]}`},
		{"json_schema without name", `{"model":"llama-3.2-3b-instruct","response_format":{"type":"json_schema","json_schema":{"strict":false,"schema":{}}},"messages":[{"role":"user","content":"hi"}]}`},
		{"unknown model", `{"model":"no-such-model","messages":[{"role":"user","content":"hi"}]}`},
		{"empty messages", `{"model":"llama-3.2-3b-instruct","messages":[]}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			status, _, body := s.chatRequest(nil, tc.body)
			if status < 400 || status > 499 {
				t.Fatalf("status=%d want 4xx body=%s", status, string(body))
			}
		})
	}
}
