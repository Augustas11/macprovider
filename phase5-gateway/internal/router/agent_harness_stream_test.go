package router

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// Agent-harness readiness on all three surfaces: history reasoning reaches
// the provider (SPEC-006-R025), and long prefills survive (SPEC-006-R026).

func captureChatUpstream(t *testing.T, captured *map[string]any) *http.Client {
	t.Helper()
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if err := json.NewDecoder(r.Body).Decode(captured); err != nil {
			t.Fatalf("decode upstream: %v", err)
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}},
			`{"id":"chatcmpl_h","object":"chat.completion","created":1,"model":"dsv4","usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
}

func TestChatCompletionsForwardsAssistantReasoningContent(t *testing.T) {
	var captured map[string]any
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(captureChatUpstream(t, &captured)))
	key := createAccountAndKey(t, store, cfg, "acct_chat_reasoning_history")
	resp := postChat(t, h, key, `{"model":"dsv4","messages":[
		{"role":"user","content":"q"},
		{"role":"assistant","content":null,"reasoning_content":"look first","tool_calls":[{"id":"call_aaaaaaaaaaaaaaaa","type":"function","function":{"name":"exec","arguments":"{}"}}]},
		{"role":"tool","tool_call_id":"call_aaaaaaaaaaaaaaaa","content":"done"}
	],"tools":[{"type":"function","function":{"name":"exec","parameters":{"type":"object"}}}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	msgs := captured["messages"].([]any)
	if got := msgs[1].(map[string]any)["reasoning_content"]; got != "look first" {
		t.Fatalf("forwarded reasoning_content=%v messages=%v", got, msgs)
	}
}

// Claude-Code-style clients echo prior thinking blocks (with the empty
// signature this gateway emits): their text becomes reasoning_content on that
// assistant turn; redacted_thinking stays opaque and is dropped.
func TestAnthropicMessagesThinkingHistoryBecomesReasoningContent(t *testing.T) {
	var captured map[string]any
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(captureChatUpstream(t, &captured)))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_thinking_history")
	resp := postAnthropicMessages(t, h, "", `{"model":"dsv4","max_tokens":64,
		"tools":[{"name":"exec","input_schema":{"type":"object"}}],
		"messages":[
			{"role":"user","content":"fix it"},
			{"role":"assistant","content":[
				{"type":"thinking","thinking":"Read the file.","signature":""},
				{"type":"redacted_thinking","data":"opaque"},
				{"type":"tool_use","id":"toolu_a","name":"exec","input":{"cmd":"cat"}}]},
			{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","content":"x"}]},
			{"role":"assistant","content":[
				{"type":"thinking","thinking":"Patch now.","signature":"sig"},
				{"type":"thinking","thinking":"Then test.","signature":""},
				{"type":"text","text":"Patched."}]},
			{"role":"assistant","content":[{"type":"text","text":"No thinking here."}]},
			{"role":"user","content":"thanks"}
		]}`, map[string]string{"X-Api-Key": key})
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var got []string
	for _, m := range captured["messages"].([]any) {
		msg := m.(map[string]any)
		r, has := msg["reasoning_content"].(string)
		if has && msg["role"] != "assistant" {
			t.Fatalf("reasoning_content on %v", msg)
		}
		got = append(got, msg["role"].(string)+":"+r)
	}
	want := []string{"user:", "assistant:Read the file.", "tool:", "assistant:Patch now.\nThen test.", "assistant:", "user:"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("messages=%q\nwant %q", got, want)
	}
	if strings.Contains(mustJSON(t, captured), "opaque") {
		t.Fatal("redacted_thinking data reached the provider")
	}
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// delayedContentUpstream commits headers with a role frame, stays silent for
// delay (a prefill), then streams one content chunk and [DONE].
func delayedContentUpstream(delay time.Duration) *http.Client {
	return seamStreamingUpstreamCtx(func(pw *io.PipeWriter, ctx context.Context) {
		_, _ = io.WriteString(pw, `data: {"id":"chatcmpl_slow","model":"dsv4","choices":[{"delta":{"role":"assistant"}}]}`+"\n\n")
		select {
		case <-ctx.Done():
			_ = pw.CloseWithError(ctx.Err())
			return
		case <-time.After(delay):
		}
		_, _ = io.WriteString(pw, `data: {"id":"chatcmpl_slow","model":"dsv4","usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4},"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}`+"\n\ndata: [DONE]\n\n")
		_ = pw.Close()
	})
}

func TestStreamingKeepalivesReachEveryBuyerOnAllSurfaces(t *testing.T) {
	prev := wholesaleKeepaliveInterval
	wholesaleKeepaliveInterval = 40 * time.Millisecond
	t.Cleanup(func() { wholesaleKeepaliveInterval = prev })

	for _, surface := range []string{"chat", "responses", "messages"} {
		t.Run(surface, func(t *testing.T) {
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
				cfg.Features.ResponsesAPIEnabled = true
				cfg.Features.AnthropicMessagesEnabled = true
			}, WithHTTPClient(delayedContentUpstream(300*time.Millisecond)))
			key := createAccountAndKey(t, store, cfg, "acct_keepalive_"+surface)
			var resp interface {
				Result() *http.Response
			}
			var body string
			switch surface {
			case "chat":
				r := postChat(t, h, key, `{"model":"dsv4","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
				resp, body = r, r.Body.String()
			case "responses":
				r := postResponses(t, h, key, `{"model":"dsv4","stream":true,"store":false,"input":"hi"}`, nil)
				resp, body = r, r.Body.String()
			case "messages":
				r := postAnthropicMessages(t, h, "", `{"model":"dsv4","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, map[string]string{"X-Api-Key": key})
				resp, body = r, r.Body.String()
			}
			if code := resp.Result().StatusCode; code != http.StatusOK {
				t.Fatalf("status=%d body=%s", code, body)
			}
			if !strings.Contains(body, "\n\n: keepalive\n\n") && !strings.HasPrefix(body, ": keepalive\n\n") {
				t.Fatalf("no standalone keepalive comment:\n%s", body)
			}
			// Comments sit between whole events; every data line still parses.
			for _, frame := range strings.Split(body, "\n\n") {
				for _, line := range strings.Split(frame, "\n") {
					if data, ok := strings.CutPrefix(line, "data: "); ok && data != "[DONE]" && !json.Valid([]byte(data)) {
						t.Fatalf("torn data line %q in:\n%s", line, body)
					}
				}
			}
			if surface == "responses" && !strings.Contains(body, "event: response.completed") {
				t.Fatalf("responses stream incomplete:\n%s", body)
			}
			if surface == "messages" && !strings.Contains(body, "event: message_stop") {
				t.Fatalf("messages stream incomplete:\n%s", body)
			}
			if surface == "chat" && !strings.Contains(body, `"content":"ok"`) {
				t.Fatalf("chat stream incomplete:\n%s", body)
			}
		})
	}
}

func TestFastStreamCarriesNoKeepaliveForOrdinaryBuyers(t *testing.T) {
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(delayedContentUpstream(0)))
	key := createAccountAndKey(t, store, cfg, "acct_keepalive_fast")
	resp := postChat(t, h, key, `{"model":"dsv4","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK || strings.Contains(resp.Body.String(), "keepalive") {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
}

// A long prompt earns prefill time beyond first_token_seconds; without the
// scaling the same prefill is cut with provider_timeout.
func TestFirstTokenBudgetScalesWithPromptSize(t *testing.T) {
	longPrompt := strings.Repeat("abcd ", 2000) // ~2500 estimated tokens
	body := `{"model":"dsv4","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"` + longPrompt + `"}]}`
	for _, tc := range []struct {
		name    string
		rate    int
		wantOK  bool
		account string
	}{
		{"scaled", 1000, true, "acct_first_token_scaled"},
		{"floor only", 0, false, "acct_first_token_floor"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
				cfg.Timeouts.FirstTokenSeconds = 1
				cfg.Timeouts.FirstTokenPrefillTokensPerSecond = tc.rate
				cfg.Timeouts.StreamingIdleMS = 30000
				cfg.Timeouts.CoordinatorRequestSeconds = 300
				cfg.Timeouts.StreamCeilingFloorSeconds = 300
			}, WithHTTPClient(delayedContentUpstream(1600*time.Millisecond)))
			key := createAccountAndKey(t, store, cfg, tc.account)
			resp := postChat(t, h, key, body, nil)
			got := resp.Body.String()
			timedOut := strings.Contains(got, `"code":"provider_timeout"`)
			if tc.wantOK == timedOut || (tc.wantOK && !strings.Contains(got, `"content":"ok"`)) {
				t.Fatalf("wantOK=%v body=%.600s", tc.wantOK, got)
			}
		})
	}
}
