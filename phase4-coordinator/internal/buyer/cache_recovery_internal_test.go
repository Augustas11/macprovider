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

func TestCachedPromptTokensPointerTreatsExplicitNullAsInvalid(t *testing.T) {
	got := cachedPromptTokensPointer(json.RawMessage("null"))
	if got == nil || *got != -1 {
		t.Fatalf("cached_prompt_tokens null = %v, want invalid sentinel", got)
	}
}

func TestChatResponseWithCachedPromptTokensPreservesAbsentUsage(t *testing.T) {
	body := []byte(`{"id":"cmpl","choices":[{"message":{"content":"ok"}}]}`)
	updated := chatResponseWithCachedPromptTokens(body, 0)
	var out map[string]json.RawMessage
	if err := json.Unmarshal(updated, &out); err != nil {
		t.Fatal(err)
	}
	if _, ok := out["usage"]; ok {
		t.Fatalf("coordinator synthesized partial usage: %s", string(updated))
	}
}
