package buyer

import (
	"encoding/json"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// #2467: a prior assistant turn's reasoning reaches the provider. Templates
// that replay it (Inkling 2) need the field on the provider body, so neither
// validation, its content normalization, nor the model rewrite may drop it.
func TestChatRequestKeepsAssistantReasoningThroughDispatch(t *testing.T) {
	for _, tc := range []struct {
		name string
		// A user content array forces the normalization re-marshal.
		userContent any
	}{
		{name: "verbatim", userContent: "pick"},
		{name: "normalized", userContent: []any{map[string]any{"type": "text", "text": "pick"}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			messages := []map[string]any{
				{"role": "user", "content": tc.userContent},
				{
					"role": "assistant", "content": nil, "reasoning_content": "earlier thought",
					"tool_calls": []any{map[string]any{
						"id": "call_ABCDEFGHIJKLMNOPQRSTUV", "type": "function",
						"function": map[string]any{"name": "lookup", "arguments": `{"q":"x"}`},
					}},
				},
				{"role": "tool", "tool_call_id": "call_ABCDEFGHIJKLMNOPQRSTUV", "content": "r"},
				{"role": "assistant", "content": "Blue.", "reasoning": "alias thought"},
				{"role": "user", "content": "again"},
			}
			body, err := json.Marshal(map[string]any{"model": "inkling-2-mini", "messages": messages})
			if err != nil {
				t.Fatal(err)
			}
			req, status, code, msg := validateChatRequest(body)
			if status != 0 {
				t.Fatalf("validate: status=%d code=%s msg=%s", status, code, msg)
			}
			out, err := dispatchBodyForProvider(req, pool.Provider{ModelID: "thinkingmachines/inkling-2-mini"})
			if err != nil {
				t.Fatalf("dispatch: %v", err)
			}
			var forwarded struct {
				Model    string           `json:"model"`
				Messages []map[string]any `json:"messages"`
			}
			if err := json.Unmarshal(out, &forwarded); err != nil {
				t.Fatalf("decode: %v body=%s", err, out)
			}
			if forwarded.Model != "thinkingmachines/inkling-2-mini" || len(forwarded.Messages) != len(messages) {
				t.Fatalf("forwarded=%s", out)
			}
			if got := forwarded.Messages[1]["reasoning_content"]; got != "earlier thought" {
				t.Fatalf("reasoning_content=%v body=%s", got, out)
			}
			if got := forwarded.Messages[3]["reasoning"]; got != "alias thought" {
				t.Fatalf("reasoning=%v body=%s", got, out)
			}
		})
	}
}
