package buyer

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/rs/zerolog"
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

func TestMergeStreamUsagePointersPreservesPriorValidPromptOnPartialUsage(t *testing.T) {
	prompt, cached, firstCompletion := int64(3), int64(0), int64(0)
	nextCompletion := int64(1)

	gotPrompt, gotCached, gotCompletion := mergeStreamUsagePointers(&prompt, &cached, &firstCompletion, nil, nil, &nextCompletion)

	if gotPrompt == nil || *gotPrompt != 3 {
		t.Fatalf("prompt=%v want 3", gotPrompt)
	}
	if gotCached == nil || *gotCached != 0 {
		t.Fatalf("cached=%v want 0", gotCached)
	}
	if gotCompletion == nil || *gotCompletion != 1 {
		t.Fatalf("completion=%v want 1", gotCompletion)
	}
}

func TestLogCacheBillingRoutingDecisionEmitsSpec024Fields(t *testing.T) {
	var buf bytes.Buffer
	server := &Server{log: zerolog.New(&buf)}

	server.logCacheBillingRoutingDecision(billing.CacheBillingRoutingDecision{
		RequestID:          "req-log-cache-hit",
		AttemptN:           0,
		ProviderID:         "provider-a",
		ProviderAssignedID: "session-a",
		CachedPromptTokens: 4,
		StickyResult:       "hit",
	})

	var row map[string]any
	if err := json.Unmarshal(buf.Bytes(), &row); err != nil {
		t.Fatalf("invalid log row %q: %v", buf.String(), err)
	}
	if row["event"] != "routing_decision" {
		t.Fatalf("event=%v want routing_decision", row["event"])
	}
	if row["request_id"] != "req-log-cache-hit" || row["provider_id"] != "provider-a" || row["provider_assigned_id"] != "session-a" {
		t.Fatalf("identity fields missing: %#v", row)
	}
	if row["attempt_n"] != float64(0) || row["cached_prompt_tokens"] != float64(4) || row["sticky_result"] != "hit" {
		t.Fatalf("cache fields missing: %#v", row)
	}

	buf.Reset()
	server.logCacheBillingRoutingDecision(billing.CacheBillingRoutingDecision{
		RequestID:          "req-log-quarantine",
		AttemptN:           0,
		ProviderID:         "provider-a",
		ProviderAssignedID: "session-a",
		CachedPromptTokens: 0,
		StickyResult:       "miss",
		StickyMissReason:   "sticky_miss_provider_not_candidate",
		ValidationReason:   "invalid_cached_prompt_tokens",
	})
	row = map[string]any{}
	if err := json.Unmarshal(buf.Bytes(), &row); err != nil {
		t.Fatalf("invalid quarantine log row %q: %v", buf.String(), err)
	}
	if row["cached_prompt_tokens"] != float64(0) || row["sticky_result"] != "miss" || row["sticky_miss_reason"] != "sticky_miss_provider_not_candidate" {
		t.Fatalf("quarantine routing fields missing: %#v", row)
	}
	if row["cache_validation_reason"] != "invalid_cached_prompt_tokens" || row["cache_json_type"] != "invalid_or_policy_rejected" {
		t.Fatalf("validation fields missing: %#v", row)
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
