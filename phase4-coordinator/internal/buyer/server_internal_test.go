package buyer

import (
	"encoding/json"
	"testing"
)

func TestTokenPointersFromUsageObjectPreservesInvalidUsageForBillingFault(t *testing.T) {
	prompt, completion := tokenPointersFromUsageObject(json.RawMessage(`{"prompt_tokens":-1,"completion_tokens":10}`))
	if prompt == nil || *prompt != -1 || completion == nil || *completion != 10 {
		t.Fatalf("invalid usage was not preserved: prompt=%v completion=%v", prompt, completion)
	}
	tooLarge := maxRequestLogUsageTokens + 1
	raw := json.RawMessage(`{"prompt_tokens":1,"completion_tokens":10000001}`)
	prompt, completion = tokenPointersFromUsageObject(raw)
	if prompt == nil || *prompt != 1 || completion == nil || *completion != tooLarge {
		t.Fatalf("oversized usage was not preserved: prompt=%v completion=%v", prompt, completion)
	}
}

func TestEstimatedCompletionTokensFromBytes(t *testing.T) {
	if got := estimatedCompletionTokensFromBytes(0, 4); got != nil {
		t.Fatalf("zero-byte estimate = %v, want nil", *got)
	}
	got := estimatedCompletionTokensFromBytes(5, 4)
	if got == nil || *got != 2 {
		t.Fatalf("five-byte estimate = %v, want 2", got)
	}
	got = estimatedCompletionTokensFromBytes(5, 16)
	if got == nil || *got != 1 {
		t.Fatalf("five-byte estimate with configured ceiling = %v, want 1", got)
	}
}
