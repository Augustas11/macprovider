package buyer

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestMultiTurnRequestValidationMatrix(t *testing.T) {
	cases := []struct {
		name       string
		mutate     func([]map[string]any) []map[string]any
		wantStatus int
		wantCode   string
	}{
		{
			name: "valid_pass_through",
			mutate: func(messages []map[string]any) []map[string]any {
				return messages
			},
		},
		{
			name: "tool_content_null",
			mutate: func(messages []map[string]any) []map[string]any {
				messages[2]["content"] = nil
				return messages
			},
			wantStatus: http.StatusBadRequest,
			wantCode:   "invalid_request",
		},
		{
			name: "tool_missing_id",
			mutate: func(messages []map[string]any) []map[string]any {
				delete(messages[2], "tool_call_id")
				return messages
			},
			wantStatus: http.StatusBadRequest,
			wantCode:   "invalid_tool_call_id",
		},
		{
			name: "tool_id_invalid_regex",
			mutate: func(messages []map[string]any) []map[string]any {
				messages[2]["tool_call_id"] = "call_short"
				return messages
			},
			wantStatus: http.StatusBadRequest,
			wantCode:   "invalid_tool_call_id",
		},
		{
			name: "tool_id_not_found",
			mutate: func(messages []map[string]any) []map[string]any {
				messages[2]["tool_call_id"] = "call_missing123456789"
				return messages
			},
			wantStatus: http.StatusBadRequest,
			wantCode:   "tool_call_id_not_found",
		},
		{
			name: "tool_result_duplicate",
			mutate: func(messages []map[string]any) []map[string]any {
				return append(messages, cloneMessage(messages[2]))
			},
			wantStatus: http.StatusBadRequest,
			wantCode:   "duplicate_tool_call_id",
		},
		{
			name: "tool_result_out_of_order",
			mutate: func(messages []map[string]any) []map[string]any {
				return []map[string]any{messages[2], messages[1]}
			},
			wantStatus: http.StatusBadRequest,
			wantCode:   "tool_call_result_out_of_order",
		},
		{
			name: "assistant_arguments_too_large",
			mutate: func(messages []map[string]any) []map[string]any {
				messages[1]["tool_calls"] = []map[string]any{{
					"id":   "call_0123456789abcdef",
					"type": "function",
					"function": map[string]any{
						"name":      "lookup",
						"arguments": `{"blob":"` + strings.Repeat("x", maxToolCallArgumentsBytes) + `"}`,
					},
				}}
				return messages
			},
			wantStatus: http.StatusRequestEntityTooLarge,
			wantCode:   "tool_call_arguments_too_large",
		},
		{
			name: "tool_result_too_large",
			mutate: func(messages []map[string]any) []map[string]any {
				messages[2]["content"] = strings.Repeat("x", maxToolResultBytes+1)
				return messages
			},
			wantStatus: http.StatusRequestEntityTooLarge,
			wantCode:   "tool_result_too_large",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := multiTurnBody(tc.mutate(validMultiTurnMessages()))
			_, status, code, msg := validateChatRequest(body)
			if tc.wantStatus == 0 {
				if status != 0 {
					t.Fatalf("validateChatRequest status=%d code=%s msg=%s", status, code, msg)
				}
				return
			}
			if status != tc.wantStatus || code != tc.wantCode {
				t.Fatalf("validateChatRequest status=%d code=%s msg=%s, want status=%d code=%s", status, code, msg, tc.wantStatus, tc.wantCode)
			}
		})
	}
}

func TestMultiTurnAggregateCaps(t *testing.T) {
	t.Run("messages_too_long", func(t *testing.T) {
		messages := make([]map[string]any, maxChatMessages+1)
		for i := range messages {
			messages[i] = map[string]any{"role": "user", "content": "hello"}
		}
		_, status, code, _ := validateChatRequest(multiTurnBody(messages))
		if status != http.StatusBadRequest || code != "messages_too_long" {
			t.Fatalf("status=%d code=%s", status, code)
		}
	})

	t.Run("too_many_tool_calls", func(t *testing.T) {
		messages := validMultiTurnMessages()
		calls := make([]map[string]any, maxAssistantToolCalls+1)
		for i := range calls {
			calls[i] = map[string]any{
				"id":   "call_" + strings.Repeat("a", 16-len(itoa(i))) + itoa(i),
				"type": "function",
				"function": map[string]any{
					"name":      "lookup",
					"arguments": `{"ok":true}`,
				},
			}
		}
		messages[1]["tool_calls"] = calls
		messages = messages[:2]
		_, status, code, _ := validateChatRequest(multiTurnBody(messages))
		if status != http.StatusBadRequest || code != "too_many_tool_calls" {
			t.Fatalf("status=%d code=%s", status, code)
		}
	})

	t.Run("tool_results_aggregate_too_large", func(t *testing.T) {
		messages := []map[string]any{{"role": "user", "content": "hello"}}
		calls := make([]map[string]any, 5)
		for i := range calls {
			id := "call_result" + strings.Repeat("a", 16-len(itoa(i))) + itoa(i)
			calls[i] = map[string]any{
				"id":   id,
				"type": "function",
				"function": map[string]any{
					"name":      "lookup",
					"arguments": `{"ok":true}`,
				},
			}
			messages = append(messages, map[string]any{"role": "assistant", "content": nil, "tool_calls": []map[string]any{calls[i]}})
			messages = append(messages, map[string]any{"role": "tool", "tool_call_id": id, "content": strings.Repeat("x", 220*1024)})
		}
		_, status, code, _ := validateChatRequest(multiTurnBody(messages))
		if status != http.StatusRequestEntityTooLarge || code != "tool_results_aggregate_too_large" {
			t.Fatalf("status=%d code=%s", status, code)
		}
	})

	t.Run("tool_call_arguments_aggregate_too_large", func(t *testing.T) {
		messages := validMultiTurnMessages()
		calls := make([]map[string]any, 3)
		for i := range calls {
			calls[i] = map[string]any{
				"id":   "call_args" + strings.Repeat("b", 16-len(itoa(i))) + itoa(i),
				"type": "function",
				"function": map[string]any{
					"name":      "lookup",
					"arguments": `{"blob":"` + strings.Repeat("x", 700*1024) + `"}`,
				},
			}
		}
		messages[1]["tool_calls"] = calls
		messages = messages[:2]
		_, status, code, _ := validateChatRequest(multiTurnBody(messages))
		if status != http.StatusRequestEntityTooLarge || code != "tool_call_arguments_aggregate_too_large" {
			t.Fatalf("status=%d code=%s", status, code)
		}
	})
}

func validMultiTurnMessages() []map[string]any {
	return []map[string]any{
		{"role": "user", "content": "weather"},
		{
			"role":    "assistant",
			"content": nil,
			"tool_calls": []map[string]any{{
				"id":   "call_0123456789abcdef",
				"type": "function",
				"function": map[string]any{
					"name":      "lookup",
					"arguments": `{"city":"Vilnius"}`,
				},
			}},
		},
		{
			"role":         "tool",
			"tool_call_id": "call_0123456789abcdef",
			"content":      `{"temperature_c":21}`,
		},
	}
}

func multiTurnBody(messages []map[string]any) []byte {
	raw, err := json.Marshal(map[string]any{
		"model":    "model-a",
		"messages": messages,
	})
	if err != nil {
		panic(err)
	}
	return raw
}

func cloneMessage(message map[string]any) map[string]any {
	out := make(map[string]any, len(message))
	for key, value := range message {
		out[key] = value
	}
	return out
}
