package router

import (
	"encoding/json"
	"io"
	"net/http"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// #2467: Inkling 2's template replays every earlier assistant turn's
// reasoning, so the gateway forwards it to the coordinator on each surface.

func captureCoordinatorMessages(t *testing.T, captured *[]map[string]any, reply string) *http.Client {
	t.Helper()
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		raw, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read upstream body: %v", err)
		}
		var body struct {
			Messages []map[string]any `json:"messages"`
		}
		if err := json.Unmarshal(raw, &body); err != nil {
			t.Fatalf("decode upstream body: %v raw=%s", err, raw)
		}
		*captured = body.Messages
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, reply), nil
	})}
}

const reasoningHistoryReply = `{"id":"chatcmpl_r","object":"chat.completion","created":1,"model":"inkling-2-mini",` +
	`"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6},` +
	`"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`

func TestChatCompletionsForwardsAssistantReasoningHistory(t *testing.T) {
	var messages []map[string]any
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(captureCoordinatorMessages(t, &messages, reasoningHistoryReply)))
	key := createAccountAndKey(t, store, cfg, "acct_reasoning_history_chat")

	// `toolu_a` is not an accepted ID, so the tool-ID rewrite re-marshals
	// the messages: that path must keep reasoning too.
	body := `{"model":"inkling-2-mini","messages":[
		{"role":"user","content":"pick"},
		{"role":"assistant","content":null,"reasoning_content":"first thought",
		 "tool_calls":[{"id":"toolu_a","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"x\"}"}}]},
		{"role":"tool","tool_call_id":"toolu_a","content":"r"},
		{"role":"assistant","content":"Blue.","reasoning":"alias thought"},
		{"role":"user","content":"again"}]}`
	resp := postChat(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if len(messages) != 5 {
		t.Fatalf("forwarded messages=%v", messages)
	}
	if messages[1]["reasoning_content"] != "first thought" {
		t.Fatalf("reasoning_content dropped: %v", messages[1])
	}
	if messages[3]["reasoning"] != "alias thought" {
		t.Fatalf("reasoning alias dropped: %v", messages[3])
	}
	if id := messages[2]["tool_call_id"]; id == "toolu_a" {
		t.Fatalf("tool ID rewrite path not exercised: %v", messages[2])
	}
}

func TestAnthropicMessagesForwardsThinkingBlocksAsReasoningContent(t *testing.T) {
	var messages []map[string]any
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(captureCoordinatorMessages(t, &messages, reasoningHistoryReply)))
	key := createAccountAndKey(t, store, cfg, "acct_reasoning_history_anthropic")

	// No `thinking` on this request: history reasoning is forwarded
	// regardless of whether the new turn asks to see thinking.
	body := `{"model":"inkling-2-mini","max_tokens":64,"messages":[
		{"role":"user","content":"pick"},
		{"role":"assistant","content":[
			{"type":"thinking","thinking":"part one","signature":"s"},
			{"type":"redacted_thinking","data":"opaque"},
			{"type":"thinking","thinking":"part two","signature":"s"},
			{"type":"tool_use","id":"toolu_a","name":"lookup","input":{"q":"x"}}]},
		{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","content":"r"}]},
		{"role":"assistant","content":[{"type":"thinking","thinking":"why blue","signature":"s"},{"type":"text","text":"Blue."}]},
		{"role":"user","content":"again"}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var assistants []map[string]any
	for _, m := range messages {
		if m["role"] == "assistant" {
			assistants = append(assistants, m)
		}
	}
	if len(assistants) != 2 {
		t.Fatalf("forwarded messages=%v", messages)
	}
	if assistants[0]["reasoning_content"] != "part one\npart two" || assistants[0]["tool_calls"] == nil {
		t.Fatalf("tool turn reasoning=%v", assistants[0])
	}
	if assistants[1]["reasoning_content"] != "why blue" || assistants[1]["content"] != "Blue." {
		t.Fatalf("text turn reasoning=%v", assistants[1])
	}
}
