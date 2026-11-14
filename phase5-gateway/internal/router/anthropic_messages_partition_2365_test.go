package router

import (
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// #2365: /v1/messages sessions that share a system prompt and tool list are
// partitioned by metadata.user_id, as Chat and Responses are by
// prompt_cache_key, so they no longer share one provider conversation key.
func TestMessagesAutoPrefixKeyPartitionsByMetadataUserID(t *testing.T) {
	var captured []string
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/internal/routing" {
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"sticky":{"enabled":false}}`), nil
		}
		body, _ := io.ReadAll(r.Body)
		if strings.Contains(string(body), "user_id") || strings.Contains(string(body), "metadata") {
			t.Errorf("metadata must not be forwarded in the translated chat body: %s", body)
		}
		captured = append(captured, r.Header.Get("X-MacProvider-Internal-Conv-Cache"))
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	const account = "acct_messages_partition_2365"
	key := createAccountAndKey(t, store, cfg, account)
	messages := func(metadata, question string) string {
		return `{"model":"llama","max_tokens":20,"system":"agent scaffold",` + metadata + `"messages":[{"role":"user","content":"` + question + `"}]}`
	}
	for _, body := range []string{
		messages(`"metadata":{"user_id":"session-a"},`, "turn one"),
		messages(`"metadata":{"user_id":"session-a"},`, "turn two"),
		messages(`"metadata":{"user_id":"session-b"},`, "turn one"),
		messages(``, "turn one"),
		messages(`"metadata":{"user_id":null},`, "turn one"),
		messages(`"metadata":{"user_id":"`+strings.Repeat("k", maxPromptCacheKeyBytes+1)+`"},`, "turn one"),
		messages(`"metadata":{"user_id":42},`, "turn one"),
		messages(`"metadata":{"user_id":"  session-a  "},`, "turn three"),
		messages(`"metadata":{"user_id":""},`, "turn one"),
		messages(`"metadata":null,`, "turn one"),
		messages(`"metadata":{"user_id":"`+strings.Repeat("k", maxPromptCacheKeyBytes)+`"},`, "turn one"),
	} {
		if resp := postAnthropicMessages(t, h, key, body, nil); resp.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
		}
	}
	if len(captured) != 11 {
		t.Fatalf("captured %d upstream requests, want 11", len(captured))
	}
	for i, got := range captured {
		if got == "" {
			t.Fatalf("request %d: Internal-Conv-Cache must be set", i)
		}
	}
	sessionA, sessionB, unpartitioned := captured[0], captured[2], captured[3]
	if captured[1] != sessionA {
		t.Fatalf("session-a turns = %q, %q; want one key", captured[0], captured[1])
	}
	if sessionB == sessionA || sessionB == unpartitioned || sessionA == unpartitioned {
		t.Fatalf("keys must differ: session-a %q session-b %q unpartitioned %q", sessionA, sessionB, unpartitioned)
	}
	if captured[4] != unpartitioned || captured[5] != unpartitioned || captured[6] != unpartitioned {
		t.Fatalf("null, oversized or non-string user_id must keep the unpartitioned key; got %q, %q, %q want %q", captured[4], captured[5], captured[6], unpartitioned)
	}
	if captured[8] != unpartitioned || captured[9] != unpartitioned {
		t.Fatalf("empty user_id or null metadata must keep the unpartitioned key; got %q, %q want %q", captured[8], captured[9], unpartitioned)
	}
	if captured[10] == unpartitioned || captured[10] == sessionA {
		t.Fatalf("a %d-byte user_id must partition; got %q", maxPromptCacheKeyBytes, captured[10])
	}
	if captured[7] != sessionA {
		t.Fatalf("padded user_id = %q, want trimmed session-a key %q", captured[7], sessionA)
	}
}

// #2365: cached prompt tokens are reported as cache_read_input_tokens and
// excluded from input_tokens, as Anthropic reports them.
func TestAnthropicUsageFromChatReportsCacheRead(t *testing.T) {
	for _, tc := range []struct {
		name  string
		usage tokenUsage
		want  anthropicUsage
	}{
		{"nested cached", tokenUsage{PromptTokens: 2584, CompletionTokens: 9, PromptTokensDetails: promptTokensDetails{CachedTokens: 2556}}, anthropicUsage{InputTokens: 28, CacheReadInputTokens: 2556, OutputTokens: 9}},
		{"flat cached", tokenUsage{PromptTokens: 100, CachedPromptTokens: 40, CompletionTokens: 1}, anthropicUsage{InputTokens: 60, CacheReadInputTokens: 40, OutputTokens: 1}},
		{"no cache", tokenUsage{PromptTokens: 5, CompletionTokens: 7}, anthropicUsage{InputTokens: 5, OutputTokens: 7}},
		{"cached above prompt", tokenUsage{PromptTokens: 10, PromptTokensDetails: promptTokensDetails{CachedTokens: 50}}, anthropicUsage{InputTokens: 0, CacheReadInputTokens: 10}},
		{"negative cached", tokenUsage{PromptTokens: 10, PromptTokensDetails: promptTokensDetails{CachedTokens: -3}}, anthropicUsage{InputTokens: 10}},
	} {
		if got := anthropicUsageFromChat(tc.usage); got != tc.want {
			t.Errorf("%s: got %+v want %+v", tc.name, got, tc.want)
		}
	}
}
