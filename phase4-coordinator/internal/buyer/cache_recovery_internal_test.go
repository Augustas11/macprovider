package buyer

import (
	"encoding/json"
	"testing"
)

func TestRequestLogCacheRecoveryFieldsPreservesExplicitStickyHitZero(t *testing.T) {
	prompt, cached := int64(10), int64(0)
	got, reason := requestLogCacheRecoveryFields(&cached, &prompt, &forwardState{stickyResult: "hit"}, 0)
	if reason != "" {
		t.Fatalf("reason=%q want empty", reason)
	}
	if got == nil || *got != 0 {
		t.Fatalf("cached=%v want explicit zero", got)
	}
}

func TestRequestLogCacheRecoveryFieldsDropsNonHitZero(t *testing.T) {
	prompt, cached := int64(10), int64(0)
	got, reason := requestLogCacheRecoveryFields(&cached, &prompt, &forwardState{stickyResult: "miss"}, 0)
	if reason != "" {
		t.Fatalf("reason=%q want empty", reason)
	}
	if got != nil {
		t.Fatalf("cached=%v want nil", got)
	}
}

func TestCachedPromptTokensPointerTreatsExplicitNullAsAbsent(t *testing.T) {
	if got := cachedPromptTokensPointer(json.RawMessage("null")); got != nil {
		t.Fatalf("cached_prompt_tokens null = %v, want nil", got)
	}
}

func TestChatResponseWithCachedPromptTokensSynthesizesMinimalUsageWhenAbsent(t *testing.T) {
	body := []byte(`{"id":"cmpl","choices":[{"message":{"content":"ok"}}]}`)
	updated := chatResponseWithCachedPromptTokens(body, 0)
	var out struct {
		Usage struct {
			CachedPromptTokens int64 `json:"cached_prompt_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(updated, &out); err != nil {
		t.Fatal(err)
	}
	if out.Usage.CachedPromptTokens != 0 {
		t.Fatalf("cached_prompt_tokens=%d want 0 body=%s", out.Usage.CachedPromptTokens, string(updated))
	}
	var decoded map[string]any
	if err := json.Unmarshal(updated, &decoded); err != nil {
		t.Fatal(err)
	}
	usage, ok := decoded["usage"].(map[string]any)
	if !ok {
		t.Fatalf("usage missing or wrong type: %s", string(updated))
	}
	if _, ok := usage["prompt_tokens"]; ok {
		t.Fatalf("synthesized usage invented prompt_tokens: %s", string(updated))
	}
	if _, ok := usage["completion_tokens"]; ok {
		t.Fatalf("synthesized usage invented token counts: %s", string(updated))
	}
}
