package router

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func TestToRequestAcceptedToolCallIDPreservesSPEC018(t *testing.T) {
	valid := "call_0123456789abcdef"
	if got := toRequestAcceptedToolCallID(valid); got != valid {
		t.Fatalf("valid id rewritten: got %q want %q", got, valid)
	}
	provider := "call_0123456789abcdef0123456789abcdef"
	if got := toRequestAcceptedToolCallID(provider); got != provider {
		t.Fatalf("provider uuid rewritten: got %q", got)
	}
}

func TestToRequestAcceptedToolCallIDRewritesPiAndAnthropicIDs(t *testing.T) {
	cases := []string{
		"toolu_a",
		"call_abc123",
		"call_123",
		"ns.bash:0",
		"call_550e8400-e29b-41d4-a716-446655440000",
		"call_lookup",
		"call_pAYbIr76hXIjncD9UE4eGfnS|item+/=long",
		"../../etc/passwd",
		"call_\nignore",
		"call_" + strings.Repeat("x", 65),
		"toolu_01AbCdEfGhIjKlMnOpQrSt",
	}
	seen := map[string]string{}
	for _, id := range cases {
		got := toRequestAcceptedToolCallID(id)
		if !spec018RequestAcceptedToolCallID(got) {
			t.Fatalf("id %q mapped to %q which fails SPEC-018 AC-31", id, got)
		}
		if spec018RequestAcceptedToolCallID(id) {
			t.Fatalf("fixture %q unexpectedly already valid", id)
		}
		if prev, ok := seen[got]; ok && prev != id {
			t.Fatalf("collision: %q and %q both map to %q", prev, id, got)
		}
		seen[got] = id
		if again := toRequestAcceptedToolCallID(id); again != got {
			t.Fatalf("non-deterministic rewrite for %q: %q vs %q", id, got, again)
		}
	}
}

func TestRewriteChatRequestToolCallIDsPairsAssistantAndTool(t *testing.T) {
	body := []byte(`{"model":"qwen3-coder-30b-a3b-instruct","max_tokens":16,"messages":[` +
		`{"role":"assistant","content":null,"tool_calls":[{"id":"ns.bash:0","type":"function","function":{"name":"bash","arguments":"{}"}}]},` +
		`{"role":"tool","tool_call_id":"ns.bash:0","content":"ok"}` +
		`]}`)
	rewritten := rewriteChatRequestToolCallIDs(body)
	var chat map[string]any
	if err := json.Unmarshal(rewritten, &chat); err != nil {
		t.Fatalf("rewritten json: %v body=%s", err, rewritten)
	}
	messages := chat["messages"].([]any)
	assistantID := messages[0].(map[string]any)["tool_calls"].([]any)[0].(map[string]any)["id"].(string)
	toolID := messages[1].(map[string]any)["tool_call_id"].(string)
	if assistantID != toolID {
		t.Fatalf("paired ids diverged assistant=%q tool=%q", assistantID, toolID)
	}
	if assistantID == "ns.bash:0" {
		t.Fatalf("pi namespaced id was not rewritten")
	}
	if !spec018RequestAcceptedToolCallID(assistantID) {
		t.Fatalf("rewritten id %q fails SPEC-018", assistantID)
	}
	if !bytesContainModel(rewritten, "qwen3-coder-30b-a3b-instruct") {
		t.Fatalf("rewrite dropped surrounding fields: %s", rewritten)
	}
}

func TestRewriteChatRequestToolCallIDsKeepsDuplicatesPaired(t *testing.T) {
	body := []byte(`{"model":"llama","messages":[` +
		`{"role":"assistant","tool_calls":[{"id":"ns.bash:0","type":"function","function":{"name":"bash","arguments":"{}"}},{"id":"ns.bash:0","type":"function","function":{"name":"bash","arguments":"{}"}}]}` +
		`]}`)
	rewritten := rewriteChatRequestToolCallIDs(body)
	var chat map[string]any
	if err := json.Unmarshal(rewritten, &chat); err != nil {
		t.Fatalf("rewritten json: %v", err)
	}
	calls := chat["messages"].([]any)[0].(map[string]any)["tool_calls"].([]any)
	a := calls[0].(map[string]any)["id"].(string)
	b := calls[1].(map[string]any)["id"].(string)
	if a != b {
		t.Fatalf("duplicate source ids remapped apart: %q vs %q", a, b)
	}
	if a == "ns.bash:0" || !spec018RequestAcceptedToolCallID(a) {
		t.Fatalf("duplicate id not rewritten to SPEC-018 form: %q", a)
	}
}

func TestRewriteChatRequestToolCallIDsLeavesValidIDsAndEmpty(t *testing.T) {
	body := []byte(`{"model":"llama","messages":[` +
		`{"role":"assistant","tool_calls":[{"id":"call_0123456789abcdef","type":"function","function":{"name":"lookup","arguments":"{}"}}]},` +
		`{"role":"tool","tool_call_id":"call_0123456789abcdef","content":"ok"},` +
		`{"role":"tool","tool_call_id":"","content":"missing"}` +
		`]}`)
	rewritten := rewriteChatRequestToolCallIDs(body)
	if string(rewritten) != string(body) {
		t.Fatalf("valid+empty ids should be byte-identical\n got %s\nwant %s", rewritten, body)
	}
}

func TestChatCompletionsRewritesPiToolCallIDsBeforeCoordinator(t *testing.T) {
	var upstreamBody map[string]any
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		raw, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read upstream: %v", err)
		}
		if err := json.Unmarshal(raw, &upstreamBody); err != nil {
			t.Fatalf("upstream json: %v raw=%s", err, raw)
		}
		body := `{"id":"chatcmpl_pi","object":"chat.completion","created":1,"model":"qwen3-coder-30b-a3b-instruct",` +
			`"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_pi_tool_ids")

	body := `{"model":"qwen3-coder-30b-a3b-instruct","max_tokens":16,"messages":[` +
		`{"role":"user","content":"run ls"},` +
		`{"role":"assistant","content":null,"tool_calls":[{"id":"call_abc123","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]},` +
		`{"role":"tool","tool_call_id":"call_abc123","content":"ok"}` +
		`]}`
	req, err := http.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	messages, _ := upstreamBody["messages"].([]any)
	if len(messages) != 3 {
		t.Fatalf("upstream messages=%v", upstreamBody["messages"])
	}
	assistantID := messages[1].(map[string]any)["tool_calls"].([]any)[0].(map[string]any)["id"].(string)
	toolID := messages[2].(map[string]any)["tool_call_id"].(string)
	if assistantID == "call_abc123" || toolID == "call_abc123" {
		t.Fatalf("short OpenAI-format Pi id leaked to coordinator: assistant=%q tool=%q", assistantID, toolID)
	}
	if assistantID != toolID {
		t.Fatalf("paired ids diverged assistant=%q tool=%q", assistantID, toolID)
	}
	if !spec018RequestAcceptedToolCallID(assistantID) {
		t.Fatalf("coordinator id %q fails SPEC-018 AC-31", assistantID)
	}
}

func bytesContainModel(body []byte, model string) bool {
	return strings.Contains(string(body), `"model":"`+model+`"`)
}
