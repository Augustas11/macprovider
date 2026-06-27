package buyer

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
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

// TestIsCommitWorthyDataLine is the unit-test edge matrix for the SSE
// commit predicate added by issue #92 / codex r3. Locks the boundary
// between "real provider work" (commits the stream) and "SSE-shape
// garbage" (forces failover) so future tweaks to isCommitWorthyDataLine
// cannot silently regress the security threshold.
func TestIsCommitWorthyDataLine(t *testing.T) {
	cases := []struct {
		name string
		line string
		want bool
	}{
		// Real OpenAI streaming chunks — commit.
		{"openai_delta_chunk", "data: {\"id\":\"chatcmpl-x\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"}}]}\n", true},
		{"openai_usage_final_chunk", "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2}}\n", true},
		{"openai_chunk_with_crlf", "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\r\n", true},
		{"openai_chunk_no_space_after_colon", "data:{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n", true},

		// SSE-shape garbage that previously committed — must reject.
		{"empty_data_line", "data: \n", false},
		{"done_terminator", "data: [DONE]\n", false},
		{"comment_line", ":\n", false},
		{"empty_blank_line", "\n", false},
		{"crlf_blank_line", "\r\n", false},
		{"id_only_metadata", "data: {\"id\":\"x\"}\n", false},
		{"object_only_metadata", "data: {\"object\":\"chat.completion.chunk\"}\n", false},
		{"choices_null", "data: {\"choices\":null}\n", false},
		{"choices_empty_array", "data: {\"choices\":[]}\n", false},
		{"usage_null", "data: {\"usage\":null}\n", false},
		{"usage_empty_object", "data: {\"usage\":{}}\n", false},
		{"delta_only_metadata", "data: {\"delta\":{\"content\":\"hi\"}}\n", false},

		// Wrong field name (case-sensitive per SSE spec).
		{"capital_Data_prefix", "Data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n", false},
		{"upper_DATA_prefix", "DATA: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n", false},

		// Wrong content shape.
		{"json_array_not_object", "data: [1,2,3]\n", false},
		{"non_json_text", "data: hello world\n", false},
		{"unterminated_json", "data: {\"choices\":\n", false},

		// Non-data SSE fields.
		{"event_field_only", "event: foo\n", false},
		{"id_field_only", "id: 12345\n", false},
		{"retry_field_only", "retry: 1000\n", false},

		// Adversarial: [DONE] embedded inside an id — only the literal
		// content "[DONE]" is filtered, not arbitrary substrings.
		{"id_containing_DONE_literal", "data: {\"id\":\"[DONE]\",\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n", true},

		// r4 value-shape inside containers — reject malformed choices.
		{"choices_integer_element", "data: {\"choices\":[1]}\n", false},
		{"choices_null_element", "data: {\"choices\":[null]}\n", false},
		{"choices_empty_object_element", "data: {\"choices\":[{}]}\n", false},
		{"choices_metadata_only_element", "data: {\"choices\":[{\"index\":0}]}\n", false},

		// r4/r5 value-shape — accept choices carrying real OpenAI signals.
		{"choices_with_message_field", "data: {\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi\"}}]}\n", true},
		{"choices_with_finish_reason_string", "data: {\"choices\":[{\"finish_reason\":\"stop\"}]}\n", true},
		// r5 — reject value-typed gaming: delta:null/{} / message:{} /
		// finish_reason:null / finish_reason:int are no-work signals.
		{"choices_with_delta_null", "data: {\"choices\":[{\"delta\":null}]}\n", false},
		{"choices_with_delta_empty_object", "data: {\"choices\":[{\"delta\":{}}]}\n", false},
		{"choices_with_message_empty_object", "data: {\"choices\":[{\"message\":{}}]}\n", false},
		{"choices_with_finish_reason_null", "data: {\"choices\":[{\"finish_reason\":null}]}\n", false},
		{"choices_with_finish_reason_int", "data: {\"choices\":[{\"finish_reason\":1}]}\n", false},
		{"choices_with_finish_reason_empty_string", "data: {\"choices\":[{\"finish_reason\":\"\"}]}\n", false},

		// post-r6 fresh security-lane MAJOR (PR #167 3-lane audit):
		// arbitrary-key delta/message must NOT pass on non-empty alone.
		{"choices_with_delta_empty_key", "data: {\"choices\":[{\"delta\":{\"\":0}}]}\n", false},
		{"choices_with_delta_unknown_key", "data: {\"choices\":[{\"delta\":{\"x\":\"y\"}}]}\n", false},
		{"choices_with_delta_content_empty", "data: {\"choices\":[{\"delta\":{\"content\":\"\"}}]}\n", false},
		{"choices_with_delta_role_empty", "data: {\"choices\":[{\"delta\":{\"role\":\"\"}}]}\n", false},
		{"choices_with_delta_tool_calls_empty_array", "data: {\"choices\":[{\"delta\":{\"tool_calls\":[]}}]}\n", false},
		{"choices_with_delta_function_call_empty", "data: {\"choices\":[{\"delta\":{\"function_call\":{}}}]}\n", false},
		// post-r6 — accept known-field delta/message variants.
		{"choices_with_delta_role_string", "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n", true},
		{"choices_with_delta_content_string", "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n", true},
		{"choices_with_delta_refusal_string", "data: {\"choices\":[{\"delta\":{\"refusal\":\"i cannot\"}}]}\n", true},
		{"choices_with_delta_reasoning_string", "data: {\"choices\":[{\"delta\":{\"reasoning\":\"thinking\"}}]}\n", true},
		{"choices_with_delta_tool_calls_array_invalid_minimal_shape", "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"f\"}}]}}]}\n", false},
		{"choices_with_delta_tool_calls_array", "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]}}]}\n", true},
		{"choices_with_delta_function_call_object", "data: {\"choices\":[{\"delta\":{\"function_call\":{\"name\":\"f\"}}}]}\n", true},
		{"choices_with_message_content_string", "data: {\"choices\":[{\"message\":{\"content\":\"hi\"}}]}\n", true},

		// r4 value-shape inside usage — reject non-OpenAI shapes.
		{"usage_arbitrary_fields", "data: {\"usage\":{\"foo\":\"bar\"}}\n", false},
		{"usage_only_prompt_tokens", "data: {\"usage\":{\"prompt_tokens\":4}}\n", false},
		{"usage_only_completion_tokens", "data: {\"usage\":{\"completion_tokens\":4}}\n", false},
		{"usage_non_numeric_tokens", "data: {\"usage\":{\"prompt_tokens\":\"a\",\"completion_tokens\":\"b\"}}\n", false},
		// r5 — reject usage with non-integer / negative / overflow values.
		{"usage_negative_tokens", "data: {\"usage\":{\"prompt_tokens\":-1,\"completion_tokens\":-1}}\n", false},
		{"usage_float_tokens", "data: {\"usage\":{\"prompt_tokens\":1.5,\"completion_tokens\":2.5}}\n", false},
		{"usage_overflow_tokens", "data: {\"usage\":{\"prompt_tokens\":99999999999999,\"completion_tokens\":99999999999999}}\n", false},
		{"usage_all_zero_tokens", "data: {\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0,\"total_tokens\":0}}\n", true}, // zero work is a valid OpenAI usage payload
		// r4 — accept valid usage shapes.
		{"usage_completion_plus_total", "data: {\"usage\":{\"completion_tokens\":4,\"total_tokens\":4}}\n", true},
		{"usage_all_three_tokens", "data: {\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2,\"total_tokens\":5}}\n", true},

		// r4 — UTF-8 BOM tolerated.
		{"bom_prefixed_valid_chunk", "\xef\xbb\xbfdata: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := isCommitWorthyDataLine([]byte(tc.line))
			if got != tc.want {
				t.Fatalf("isCommitWorthyDataLine(%q) = %v, want %v", tc.line, got, tc.want)
			}
		})
	}
}

func TestCommitSignal_EmptyToolCallObject_Rejected(t *testing.T) {
	line := "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{}]}}]}\n"
	if isCommitWorthyDataLine([]byte(line)) {
		t.Fatal("empty tool-call object must not be commit-worthy")
	}
}

func TestCommitSignal_NonObjectArguments_Rejected(t *testing.T) {
	line := "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"[]\"}}]}}]}\n"
	if isCommitWorthyDataLine([]byte(line)) {
		t.Fatal("non-object function.arguments must not be commit-worthy")
	}
}

func TestCommitSignal_DeepNestedArguments_Rejected(t *testing.T) {
	arguments := "1"
	for i := 0; i < 100; i++ {
		arguments = `{"x":` + arguments + `}`
	}
	line := "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":" + string(mustJSONString(t, arguments)) + "}}]}}]}\n"
	if isCommitWorthyDataLine([]byte(line)) {
		t.Fatal("deeply nested function.arguments must not be commit-worthy")
	}
}

func TestCommitSignal_OversizedArguments_Rejected(t *testing.T) {
	arguments := `{"blob":"` + strings.Repeat("x", 256*1024) + `"}`
	line := "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":" + string(mustJSONString(t, arguments)) + "}}]}}]}\n"
	if isCommitWorthyDataLine([]byte(line)) {
		t.Fatal("oversized function.arguments must not be commit-worthy")
	}
}

func TestCommitSignal_MinimalValidShape_Accepted(t *testing.T) {
	line := "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{\\\"a\\\":1}\"}}]}}]}\n"
	if !isCommitWorthyDataLine([]byte(line)) {
		t.Fatal("minimal valid tool-call delta must be commit-worthy")
	}
}

func mustJSONString(t *testing.T, value string) []byte {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("json marshal string: %v", err)
	}
	return raw
}

func TestRequestSidePassThrough_ToolCalls_ByteEquivalent(t *testing.T) {
	body := []byte(`{
		"model":"model-a",
		"messages":[
			{"role":"user","content":"plan"},
			{"role":"assistant","content":null,"tool_calls":[
				{"id":"call_alpha-1","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"ToolCallParser\",\"n\":1}"}},
				{"id":"call.beta_2","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"phase3-binary/Sources/macprovider-cli/ToolCallParser.swift\"}"}}
			]},
			{"role":"tool","tool_call_id":"call_alpha-1","content":"{\"ok\":true}"},
			{"role":"tool","tool_call_id":"call.beta_2","content":"{\"bytes\":42}"}
		]
	}`)
	req, status, code, msg := validateChatRequest(body)
	if status != 0 {
		t.Fatalf("validateChatRequest status=%d code=%s msg=%s", status, code, msg)
	}
	outbound, err := dispatchBodyForProvider(req, pool.Provider{ModelID: "model-a"})
	if err != nil {
		t.Fatalf("dispatchBodyForProvider: %v", err)
	}
	frameRaw, err := json.Marshal(providerws.InferenceRequest{
		Type:      "inference_request",
		RequestID: "req-ac24",
		Stream:    false,
		Body:      string(outbound),
	})
	if err != nil {
		t.Fatalf("marshal inference request: %v", err)
	}
	var frame providerws.InferenceRequest
	if err := json.Unmarshal(frameRaw, &frame); err != nil {
		t.Fatalf("unmarshal inference request frame: %v", err)
	}

	originalToolCalls, originalToolIDs := requestSideToolFields(t, body)
	forwardedToolCalls, forwardedToolIDs := requestSideToolFields(t, []byte(frame.Body))
	if !bytes.Equal(canonicalJSON(t, originalToolCalls), canonicalJSON(t, forwardedToolCalls)) {
		t.Fatalf("tool_calls mutated:\noriginal=%s\nforwarded=%s", originalToolCalls, forwardedToolCalls)
	}
	if len(originalToolIDs) != len(forwardedToolIDs) {
		t.Fatalf("tool_call_id count = %d, want %d", len(forwardedToolIDs), len(originalToolIDs))
	}
	for i := range originalToolIDs {
		if originalToolIDs[i] != forwardedToolIDs[i] {
			t.Fatalf("tool_call_id[%d] = %q, want %q", i, forwardedToolIDs[i], originalToolIDs[i])
		}
	}
}

func requestSideToolFields(t *testing.T, body []byte) (json.RawMessage, []string) {
	t.Helper()
	var parsed struct {
		Messages []struct {
			Role       string          `json:"role"`
			ToolCalls  json.RawMessage `json:"tool_calls"`
			ToolCallID string          `json:"tool_call_id"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		t.Fatalf("unmarshal body: %v", err)
	}
	var calls json.RawMessage
	var ids []string
	for _, msg := range parsed.Messages {
		switch msg.Role {
		case "assistant":
			if len(msg.ToolCalls) > 0 && !bytes.Equal(msg.ToolCalls, []byte("null")) {
				calls = append(calls[:0], msg.ToolCalls...)
			}
		case "tool":
			ids = append(ids, msg.ToolCallID)
		}
	}
	if len(calls) == 0 {
		t.Fatal("assistant tool_calls not found")
	}
	return calls, ids
}

func canonicalJSON(t *testing.T, raw json.RawMessage) []byte {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var value any
	if err := dec.Decode(&value); err != nil {
		t.Fatalf("decode canonical json: %v", err)
	}
	out, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal canonical json: %v", err)
	}
	return out
}

// TestIsSSEBlankLine locks the blank-line terminator detection used
// by the forwardStreaming pre-commit loop.
func TestIsSSEBlankLine(t *testing.T) {
	if !isSSEBlankLine([]byte("\n")) {
		t.Fatal("\\n must be a blank line terminator")
	}
	if !isSSEBlankLine([]byte("\r\n")) {
		t.Fatal("\\r\\n must be a blank line terminator")
	}
	if isSSEBlankLine([]byte("data: x\n")) {
		t.Fatal("data: x\\n must NOT be a blank line terminator")
	}
	if isSSEBlankLine([]byte("data: x\r\n")) {
		t.Fatal("data: x\\r\\n must NOT be a blank line terminator")
	}
	if isSSEBlankLine([]byte("")) {
		t.Fatal("empty slice must NOT be a blank line terminator (ReadBytes never returns empty + nil)")
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
