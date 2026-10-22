package router

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// #2107 D3: Anthropic SDK clients send `anthropic-beta`, unknown top-level
// keys, `thinking`, cache_control on tool blocks and prior thinking blocks.
func TestAnthropicMessagesAcceptsBetaThinkingAndUnknownKeys(t *testing.T) {
	var upstreamBody map[string]any
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		raw, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read upstream body: %v", err)
		}
		if err := json.Unmarshal(raw, &upstreamBody); err != nil {
			t.Fatalf("decode upstream body: %v raw=%s", err, string(raw))
		}
		body := `{"id":"chatcmpl_think","object":"chat.completion","created":1,"model":"glm",` +
			`"usage":{"prompt_tokens":4,"completion_tokens":9,"total_tokens":13,"completion_tokens_details":{"reasoning_tokens":5}},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"Blue.","reasoning_content":"The user asks for a colour."},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_thinking")

	body := `{"model":"glm","max_tokens":64,"container":"c","context_management":{"edits":[]},
		"thinking":{"type":"enabled","budget_tokens":2048},
		"messages":[
			{"role":"user","content":"pick"},
			{"role":"assistant","content":[{"type":"thinking","thinking":"earlier","signature":"sig"},{"type":"tool_use","id":"toolu_a","name":"lookup","input":{"q":"x"},"cache_control":{"type":"ephemeral"}}]},
			{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","content":"r","cache_control":{"type":"ephemeral"}}]}
		]}`
	resp := postAnthropicMessages(t, h, key, body, map[string]string{"anthropic-beta": "interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14"})
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if upstreamBody["reasoning_effort"] != "low" {
		t.Fatalf("thinking budget 2048 must map to reasoning_effort low: %v", upstreamBody)
	}
	for _, key := range []string{"container", "context_management", "thinking"} {
		if _, ok := upstreamBody[key]; ok {
			t.Fatalf("%s must not be forwarded: %v", key, upstreamBody)
		}
	}
	var out struct {
		Content []map[string]any `json:"content"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out.Content) != 2 || out.Content[0]["type"] != "thinking" || out.Content[0]["thinking"] != "The user asks for a colour." ||
		out.Content[1]["type"] != "text" || out.Content[1]["text"] != "Blue." {
		t.Fatalf("content blocks=%v want thinking then text", out.Content)
	}
}

func TestAnthropicMessagesDropsReasoningWithoutThinking(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_nothink","object":"chat.completion","created":1,"model":"glm",` +
			`"usage":{"prompt_tokens":4,"completion_tokens":9,"total_tokens":13},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"Blue.","reasoning_content":"hidden"},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_nothink")
	resp := postAnthropicMessages(t, h, key, `{"model":"glm","max_tokens":64,"messages":[{"role":"user","content":"pick"}]}`, nil)
	if resp.Code != http.StatusOK || strings.Contains(resp.Body.String(), "hidden") || strings.Contains(resp.Body.String(), `"thinking"`) {
		t.Fatalf("reasoning must not reach a client that did not enable thinking: %d %s", resp.Code, resp.Body.String())
	}
}

func TestAnthropicMessagesStreamsThinkingBlockBeforeText(t *testing.T) {
	stream := `data: {"id":"chatcmpl_t","model":"glm","choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}` + "\n\n" +
		`data: {"id":"chatcmpl_t","model":"glm","choices":[{"delta":{"reasoning_content":"think "},"finish_reason":null}]}` + "\n\n" +
		`data: {"id":"chatcmpl_t","model":"glm","choices":[{"delta":{"reasoning_content":"more"},"finish_reason":null}]}` + "\n\n" +
		`data: {"id":"chatcmpl_t","model":"glm","choices":[{"delta":{"content":"Blue."},"finish_reason":"stop"}]}` + "\n\n" +
		`data: {"id":"chatcmpl_t","model":"glm","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}` + "\n\n" +
		"data: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_thinking")
	resp := postAnthropicMessages(t, h, key, `{"model":"glm","max_tokens":64,"stream":true,"thinking":{"type":"enabled","budget_tokens":20000},"messages":[{"role":"user","content":"pick"}]}`, nil)
	body := resp.Body.String()
	thinkingStart := strings.Index(body, `"content_block":{"signature":"","thinking":"","type":"thinking"}`)
	textStart := strings.Index(body, `"content_block":{"text":"","type":"text"}`)
	if resp.Code != http.StatusOK || thinkingStart < 0 || textStart < thinkingStart ||
		!strings.Contains(body, `"thinking":"think "`) || !strings.Contains(body, `"type":"signature_delta"`) ||
		!strings.Contains(body, `"index":1`) || !strings.Contains(body, `"text":"Blue."`) {
		t.Fatalf("thinking block must precede the text block:\n%s", body)
	}
}
