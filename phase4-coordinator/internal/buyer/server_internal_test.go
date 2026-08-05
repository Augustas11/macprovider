package buyer

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

func TestValidatePinnedProviderAcceptsCatalogKeyAlias(t *testing.T) {
	const hfID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
	const catalogKey = "openai/gpt-oss-20b"
	p := pool.Provider{
		ProviderID:       "p1",
		AssignedID:       "s1",
		ModelID:          hfID,
		State:            pool.StateReady,
		SlotsFree:        1,
		SlotsTotal:       1,
		MaxContextTokens: 20000,
	}
	if _, routeErr := validatePinnedProvider(p, catalogKey, 10, "Pinned provider not available"); routeErr != nil {
		t.Fatalf("catalog-key pin rejected: status=%d code=%s msg=%s", routeErr.status, routeErr.code, routeErr.message)
	}
	if _, routeErr := validatePinnedProvider(p, hfID, 10, "Pinned provider not available"); routeErr != nil {
		t.Fatalf("HF-id pin rejected: status=%d code=%s msg=%s", routeErr.status, routeErr.code, routeErr.message)
	}
	if _, routeErr := validatePinnedProvider(p, "qwen/gpt-oss-20b", 10, "Pinned provider not available"); routeErr == nil {
		t.Fatal("foreign-namespace spoof must not satisfy pinned provider model match")
	}
	if _, routeErr := validatePinnedProvider(p, "openai/gpt-oss-120b", 10, "Pinned provider not available"); routeErr == nil {
		t.Fatal("unrelated catalog key must not satisfy pinned provider model match")
	}
}

func TestProviderMatchesRequestClassMemberCatalogKeyAlias(t *testing.T) {
	s := &Server{}
	class := &config.ModelClassConfig{
		Objective: "cheap",
		Members:   []string{"openai/gpt-oss-20b"},
	}
	p := pool.Provider{ModelID: "mlx-community/gpt-oss-20b-MXFP4-Q8"}
	if !s.providerMatchesRequest(p, "fast-class", class) {
		t.Fatal("class member catalog key must match served HF id")
	}
	if s.providerMatchesRequest(p, "fast-class", &config.ModelClassConfig{
		Objective: "cheap",
		Members:   []string{"qwen/gpt-oss-20b"},
	}) {
		t.Fatal("foreign-namespace class member must not match openai-served HF id")
	}
}

// TestNoPriorDispatchResponseWriterMarks pins the coordinator half of the
// item-18 fix: the central noPriorDispatchResponseWriter stamps the POSITIVE
// X-MacProvider-Settlement-No-Prior-Dispatch marker on the first response write
// IFF no provider has been (or is about to be) billably credited for this
// request. The signal is derived from two ledger-exact recorder fields plus the
// write status, NOT a request-log ordinal:
//   - providerCredited: any prior attempt persisted a billable (non-503) row.
//   - dispatchedThisAttempt && status != 503: the CURRENT terminal attempt
//     dispatched a provider and its terminal status is billable (recordRow bills
//     iff status != 503), so its own billing row — recorded AFTER this write on
//     the WS paths — must not be erased by a marker.
//
// The cases below map to the real coordinator terminal responses: a pre-dispatch
// route_snapshot_failed 500 and a cold no_provider 503 stay MARKED (refundable);
// a single provider_failed 502, a failover-exhaustion 503 after a billed attempt,
// and a streaming 200 stay UNMARKED (billed); a dispatched-but-queue-full 503
// stays MARKED (dispatched but not billed).
func TestNoPriorDispatchResponseWriterMarks(t *testing.T) {
	for _, tc := range []struct {
		name       string
		credited   bool
		dispatched bool
		status     int  // WriteHeader status; ignored when viaWrite
		viaWrite   bool // exercise Write() (implicit 200) instead of WriteHeader()
		wantMarker bool
	}{
		{name: "route_snapshot_failed_pre_dispatch", credited: false, dispatched: false, status: http.StatusInternalServerError, wantMarker: true},
		{name: "cold_no_provider_503", credited: false, dispatched: false, status: http.StatusServiceUnavailable, wantMarker: true},
		{name: "single_provider_failed_502", credited: false, dispatched: true, status: http.StatusBadGateway, wantMarker: false},
		{name: "dispatched_queue_full_503_not_billed", credited: false, dispatched: true, status: http.StatusServiceUnavailable, wantMarker: true},
		{name: "failover_exhaustion_503_after_billed", credited: true, dispatched: false, status: http.StatusServiceUnavailable, wantMarker: false},
		{name: "credited_and_dispatched_502", credited: true, dispatched: true, status: http.StatusBadGateway, wantMarker: false},
		{name: "streaming_200_dispatched", credited: false, dispatched: true, viaWrite: true, wantMarker: false},
		{name: "streaming_200_no_dispatch_defensive", credited: false, dispatched: false, viaWrite: true, wantMarker: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			inner := httptest.NewRecorder()
			rec := &billingRecorder{providerCredited: tc.credited, dispatchedThisAttempt: tc.dispatched}
			w := &noPriorDispatchResponseWriter{ResponseWriter: inner, rec: rec}
			if tc.viaWrite {
				if _, err := w.Write([]byte("data: {}\n\n")); err != nil {
					t.Fatalf("write: %v", err)
				}
			} else {
				writeError(w, tc.status, "route_snapshot_failed", "boom")
			}
			got := inner.Header().Get(settlementNoPriorDispatchHeader)
			if tc.wantMarker && got == "" {
				t.Fatalf("credited=%v dispatched=%v status=%d: marker must be SET (nothing billable credited)", tc.credited, tc.dispatched, tc.status)
			}
			if !tc.wantMarker && got != "" {
				t.Fatalf("credited=%v dispatched=%v status=%d: marker must be WITHHELD (a provider was/will be credited), got %q", tc.credited, tc.dispatched, tc.status, got)
			}
		})
	}
}

func TestTokenPointersFromUsageObjectPreservesInvalidUsageForBillingFault(t *testing.T) {
	prompt, _, completion := tokenPointersFromUsageObject(json.RawMessage(`{"prompt_tokens":-1,"completion_tokens":10}`))
	if prompt == nil || *prompt != -1 || completion == nil || *completion != 10 {
		t.Fatalf("invalid usage was not preserved: prompt=%v completion=%v", prompt, completion)
	}
	tooLarge := maxRequestLogUsageTokens + 1
	raw := json.RawMessage(`{"prompt_tokens":1,"completion_tokens":10000001}`)
	prompt, _, completion = tokenPointersFromUsageObject(raw)
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
		{"choices_with_delta_tool_calls_array_invalid_minimal_shape", "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_0123456789abcdef\",\"function\":{\"name\":\"f\"}}]}}]}\n", false},
		{"choices_with_delta_tool_calls_array", "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_0123456789abcdef\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]}}]}\n", true},
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

func TestCommitSignal_NonObjectArguments_IncrementalOpenAccepted(t *testing.T) {
	line := "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_0123456789abcdef\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"[]\"}}]}}]}\n"
	if !isCommitWorthyDataLine([]byte(line)) {
		t.Fatal("incremental-open validator must accept argument fragments before final-close")
	}
	validator := newStreamToolCallFinalValidator()
	if err := validator.observeLine([]byte(line)); err != nil {
		t.Fatalf("observeLine: %v", err)
	}
	_ = validator.observeLine([]byte("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n"))
	_ = validator.observeLine([]byte("data: [DONE]\n"))
	if validator.finalCloseOK() {
		t.Fatal("final-close validator must reject non-object accumulated arguments")
	}
}

func TestCommitSignal_DeepNestedArguments_FinalCloseRejected(t *testing.T) {
	arguments := "1"
	for i := 0; i < 100; i++ {
		arguments = `{"x":` + arguments + `}`
	}
	line := "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_0123456789abcdef\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":" + string(mustJSONString(t, arguments)) + "}}]}}]}\n"
	if !isCommitWorthyDataLine([]byte(line)) {
		t.Fatal("incremental-open validator must accept argument fragments before final-close")
	}
	validator := newStreamToolCallFinalValidator()
	if err := validator.observeLine([]byte(line)); err != nil {
		t.Fatalf("observeLine: %v", err)
	}
	_ = validator.observeLine([]byte("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n"))
	_ = validator.observeLine([]byte("data: [DONE]\n"))
	if validator.finalCloseOK() {
		t.Fatal("final-close validator must reject deeply nested accumulated arguments")
	}
}

func TestCommitSignal_OversizedArguments_FinalCloseRejected(t *testing.T) {
	arguments := `{"blob":"` + strings.Repeat("x", maxToolCallArgumentsBytes) + `"}`
	line := "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_0123456789abcdef\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":" + string(mustJSONString(t, arguments)) + "}}]}}]}\n"
	if isCommitWorthyDataLine([]byte(line)) {
		t.Fatal("cap-crossing opening chunk must not be commit-worthy")
	}
}

func TestCommitSignal_MixedInvalidToolCalls_Rejected(t *testing.T) {
	valid := `{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"f","arguments":"{\"a\":1}"}}`
	oversizedArguments := `{"blob":"` + strings.Repeat("x", maxToolCallArgumentsBytes) + `"}`
	oversized := `{"index":1,"id":"call_abcdefabcdefabcd","type":"function","function":{"name":"f","arguments":` + string(mustJSONString(t, oversizedArguments)) + `}}`
	cases := []struct {
		name  string
		calls string
	}{
		{"empty_object_then_valid", `{}` + "," + valid},
		{"valid_then_oversized_arguments", valid + "," + oversized},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			line := "data: {\"choices\":[{\"delta\":{\"tool_calls\":[" + tc.calls + "]}}]}\n"
			if isCommitWorthyDataLine([]byte(line)) {
				t.Fatal("mixed valid/invalid tool-call delta must not be commit-worthy")
			}
		})
	}
}

func TestCommitSignal_InvalidToolCallsWithOtherSignals_Rejected(t *testing.T) {
	oversizedArguments := `{"blob":"` + strings.Repeat("x", maxToolCallArgumentsBytes) + `"}`
	cases := []struct {
		name  string
		delta string
	}{
		{"role_with_empty_object", `"role":"assistant","tool_calls":[{}]`},
		{"reasoning_with_oversized_arguments", `"reasoning":"trace","tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"f","arguments":` + string(mustJSONString(t, oversizedArguments)) + `}}]`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			line := "data: {\"choices\":[{\"delta\":{" + tc.delta + "}}]}\n"
			if isCommitWorthyDataLine([]byte(line)) {
				t.Fatal("invalid tool_calls must reject the whole delta even when another signal is present")
			}
		})
	}
}

func TestCommitSignal_InvalidToolCallsStatusPoisonsPreCommit(t *testing.T) {
	line := []byte("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{}]}}]}\n")
	if got := inspectCommitWorthyDataLine(line); got != commitLineMalformedToolCalls {
		t.Fatalf("inspectCommitWorthyDataLine = %v, want malformed tool_calls", got)
	}
	if isCommitWorthyDataLine(line) {
		t.Fatal("malformed tool_calls must not be commit-worthy")
	}
}

func TestCommitSignal_MinimalValidShape_Accepted(t *testing.T) {
	line := "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_0123456789abcdef\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{\\\"a\\\":1}\"}}]}}]}\n"
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
				{"id":"call_alpha12345678901","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"ToolCallParser\",\"n\":1}"}},
				{"id":"call_beta123456789012","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"phase3-binary/Sources/macprovider-cli/ToolCallParser.swift\"}"}}
			]},
			{"role":"tool","tool_call_id":"call_alpha12345678901","content":"{\"ok\":true}"},
				{"role":"tool","tool_call_id":"call_beta123456789012","content":"{\"bytes\":42}"}
			]
		}`)
	req, status, code, msg := validateChatRequest(body)
	if status != 0 {
		t.Fatalf("validateChatRequest status=%d code=%s msg=%s", status, code, msg)
	}

	originalToolCalls, originalToolIDs := requestSideToolFields(t, body)
	for _, tc := range []struct {
		name            string
		providerModelID string
	}{
		{"same_model_raw_path", "model-a"},
		{"rewritten_model_path", "provider-model-b"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			outbound, err := dispatchBodyForProvider(req, pool.Provider{ModelID: tc.providerModelID})
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

			forwardedToolCalls, forwardedToolIDs := requestSideToolFields(t, []byte(frame.Body))
			if !bytes.Equal(originalToolCalls, forwardedToolCalls) {
				t.Fatalf("tool_calls bytes mutated:\noriginal=%s\nforwarded=%s", originalToolCalls, forwardedToolCalls)
			}
			if len(originalToolIDs) != len(forwardedToolIDs) {
				t.Fatalf("tool_call_id count = %d, want %d", len(forwardedToolIDs), len(originalToolIDs))
			}
			for i := range originalToolIDs {
				if !bytes.Equal(originalToolIDs[i], forwardedToolIDs[i]) {
					t.Fatalf("tool_call_id[%d] bytes = %s, want %s", i, forwardedToolIDs[i], originalToolIDs[i])
				}
			}
		})
	}
}

func TestStructuredTextContentArrayNormalizesForProvider(t *testing.T) {
	body := []byte(`{
		"model":"model-a",
		"messages":[
			{"role":"system","content":[{"type":"text","text":"Be "},{"type":"text","text":"brief."}]},
			{"role":"user","content":[{"type":"text","text":"Hello"}]}
		],
		"user":"sdk-user"
	}`)
	req, status, code, msg := validateChatRequest(body)
	if status != 0 {
		t.Fatalf("validateChatRequest status=%d code=%s msg=%s", status, code, msg)
	}
	for _, providerModelID := range []string{"model-a", "provider-model-b"} {
		t.Run(providerModelID, func(t *testing.T) {
			outbound, err := dispatchBodyForProvider(req, pool.Provider{ModelID: providerModelID})
			if err != nil {
				t.Fatalf("dispatchBodyForProvider: %v", err)
			}
			if bytes.Contains(outbound, []byte(`"tool_calls"`)) || bytes.Contains(outbound, []byte(`"tool_call_id"`)) {
				t.Fatalf("normalized simple messages gained tool fields: %s", string(outbound))
			}

			var got struct {
				Model    string `json:"model"`
				Messages []struct {
					Role    string `json:"role"`
					Content string `json:"content"`
				} `json:"messages"`
			}
			if err := json.Unmarshal(outbound, &got); err != nil {
				t.Fatalf("unmarshal outbound: %v; body=%s", err, string(outbound))
			}
			if got.Model != providerModelID {
				t.Fatalf("model = %q, want %q; body=%s", got.Model, providerModelID, string(outbound))
			}
			if len(got.Messages) != 2 {
				t.Fatalf("messages len = %d, want 2; body=%s", len(got.Messages), string(outbound))
			}
			if got.Messages[0].Content != "Be brief." || got.Messages[1].Content != "Hello" {
				t.Fatalf("normalized content = %#v; body=%s", got.Messages, string(outbound))
			}
		})
	}
}

func TestStructuredTextContentArrayPreservesToolHistory(t *testing.T) {
	body := []byte(`{
		"model":"model-a",
		"messages":[
			{"role":"user","content":[{"type":"text","text":"plan"}]},
			{"role":"assistant","content":null,"tool_calls":[
				{"id":"call_alpha12345678901","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"content array\",\"n\":1}"}}
			]},
			{"role":"tool","tool_call_id":"call_alpha12345678901","content":"{\"ok\":true}"}
		]
	}`)
	req, status, code, msg := validateChatRequest(body)
	if status != 0 {
		t.Fatalf("validateChatRequest status=%d code=%s msg=%s", status, code, msg)
	}

	originalToolCalls, originalToolIDs := requestSideToolFields(t, body)
	for _, providerModelID := range []string{"model-a", "provider-model-b"} {
		t.Run(providerModelID, func(t *testing.T) {
			outbound, err := dispatchBodyForProvider(req, pool.Provider{ModelID: providerModelID})
			if err != nil {
				t.Fatalf("dispatchBodyForProvider: %v", err)
			}
			var got struct {
				Messages []struct {
					Role    string          `json:"role"`
					Content json.RawMessage `json:"content"`
				} `json:"messages"`
			}
			if err := json.Unmarshal(outbound, &got); err != nil {
				t.Fatalf("unmarshal outbound: %v; body=%s", err, string(outbound))
			}
			if len(got.Messages) != 3 {
				t.Fatalf("messages len = %d, want 3; body=%s", len(got.Messages), string(outbound))
			}
			if got.Messages[0].Role != "user" || !bytes.Equal(got.Messages[0].Content, mustJSONString(t, "plan")) {
				t.Fatalf("user content not normalized to string: %#v; body=%s", got.Messages[0], string(outbound))
			}
			forwardedToolCalls, forwardedToolIDs := requestSideToolFields(t, outbound)
			if !bytes.Equal(compactJSONRaw(t, originalToolCalls), compactJSONRaw(t, forwardedToolCalls)) {
				t.Fatalf("tool_calls semantics mutated:\noriginal=%s\nforwarded=%s", originalToolCalls, forwardedToolCalls)
			}
			if len(originalToolIDs) != len(forwardedToolIDs) {
				t.Fatalf("tool_call_id count = %d, want %d", len(forwardedToolIDs), len(originalToolIDs))
			}
			for i := range originalToolIDs {
				if !bytes.Equal(originalToolIDs[i], forwardedToolIDs[i]) {
					t.Fatalf("tool_call_id[%d] bytes = %s, want %s", i, forwardedToolIDs[i], originalToolIDs[i])
				}
			}
		})
	}
}

func compactJSONRaw(t *testing.T, raw json.RawMessage) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := json.Compact(&buf, raw); err != nil {
		t.Fatalf("compact JSON %s: %v", raw, err)
	}
	return buf.Bytes()
}

func TestStructuredContentArrayRejectsMultimodalPart(t *testing.T) {
	body := []byte(`{
		"model":"model-a",
		"messages":[{"role":"user","content":[
			{"type":"text","text":"describe this"},
			{"type":"image_url","image_url":{"url":"https://example.test/image.png"}}
		]}]
	}`)
	_, status, code, msg := validateChatRequest(body)
	if status != 400 || code != "unsupported_content_shape" {
		t.Fatalf("validateChatRequest status=%d code=%s msg=%s, want 400 unsupported_content_shape", status, code, msg)
	}
	if !strings.Contains(msg, "multimodal content arrays are not supported") {
		t.Fatalf("message not actionable: %q", msg)
	}
}

func requestSideToolFields(t *testing.T, body []byte) (json.RawMessage, []json.RawMessage) {
	t.Helper()
	var parsed struct {
		Messages []struct {
			Role       string          `json:"role"`
			ToolCalls  json.RawMessage `json:"tool_calls"`
			ToolCallID json.RawMessage `json:"tool_call_id"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		t.Fatalf("unmarshal body: %v", err)
	}
	var calls json.RawMessage
	var ids []json.RawMessage
	for _, msg := range parsed.Messages {
		switch msg.Role {
		case "assistant":
			if len(msg.ToolCalls) > 0 && !bytes.Equal(msg.ToolCalls, []byte("null")) {
				calls = append(calls[:0], msg.ToolCalls...)
			}
		case "tool":
			ids = append(ids, append(json.RawMessage(nil), msg.ToolCallID...))
		}
	}
	if len(calls) == 0 {
		t.Fatal("assistant tool_calls not found")
	}
	return calls, ids
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

// TestRetryableByCodeClassification asserts that transient availability/timeout
// codes report retryable=true and permanent/client codes report false, closing
// audit finding H2 (every buyer error envelope stamped retryable=false because
// transient codes were absent from the lookup table).
func TestRetryableByCodeClassification(t *testing.T) {
	retryable := []string{
		"no_provider_available", "provider_timeout", "provider_error",
		"provider_disconnected", "provider_failed",
		"provisional_quota_exceeded", "preflight_rejected",
		"idempotency_unavailable", "rate_limited",
		// Round-3 sweep addition: pre-dispatch route-snapshot store
		// failure — a retry can succeed once storage recovers.
		"route_snapshot_failed",
	}
	for _, code := range retryable {
		if !spec018Retryable(code) {
			t.Errorf("code %q must be retryable=true", code)
		}
	}
	permanent := []string{
		"model_not_found", "context_exceeds_capacity", "unsupported_content_shape",
		"invalid_request", "invalid_json", "byte_cap_exceeded",
		// Round-2 sweep additions: reviewed and confirmed permanent.
		"catalog_not_found", "provider_not_found", "provider_response_too_large",
		"not_found", "unauthorized", "request_log_failed", "settlement_finality_failed",
		"idempotency_key_body_mismatch", "idempotency_key_replayed",
		"idempotency_reservation_failed", "malformed_settlement_stream",
		"tool_call_final_close_failed", "malformed_tool_call", "stream_output_exceeded",
		"session_ended", "tier2_hash_verified_required", "tier2_encrypted_leg_required",
		"tier2_attestation_required", "tier2_hard_pin_predicate_failed",
		"tier2_hash_mismatch", "tier2_aead_decrypt_failed", "tier2_output_encoding_invalid",
		// Round-3 sweep additions: reviewed and confirmed permanent.
		"autotune_feed_not_found", "invalid_tools",
	}
	for _, code := range permanent {
		if spec018Retryable(code) {
			t.Errorf("code %q must be retryable=false", code)
		}
	}
}

// coordinatorEmittedErrorCodes is every literal code string reachable by a
// buyer-facing error envelope in internal/buyer/*.go, as of the round-3
// 3-lane re-audit sweep of PR #548: writeError, writeErrorWithParam, a
// routeError{} literal, the coordinator's own writeSSEError, AND the
// codes returned by the request-validation helpers (validateChatRequest /
// validateOptionalFields / validateResponseFormatSchema / validateMessages /
// validateTools / validateJSONSchemaRaw / validateJSONSchemaNumericBounds)
// via a status/code/message tuple or *schemaValidationError, which
// ultimately reach writeError(w, status, code, msg) through a variable.
//
// The round-2 version of this list deliberately excluded the
// validation-helper codes as "out of proportion" — that was the bug: it
// let 3 genuinely-emitted codes (autotune_feed_not_found, invalid_tools,
// route_snapshot_failed) ship with NO entry in either this list or
// spec018RetryableByCode while the completeness test still passed, because
// the list wasn't actually exhaustive. This list is now the full 70-entry
// write-site sweep (autotune_feeds.go, route_snapshot.go, and every code
// path in server.go), matching spec018RetryableByCode key-for-key.
var coordinatorEmittedErrorCodes = []string{
	"autotune_feed_not_found", "byte_cap_exceeded", "catalog_not_found",
	"context_exceeds_capacity", "duplicate_tool_call_id", "idempotency_key_body_mismatch",
	"idempotency_key_replayed", "idempotency_reservation_failed", "idempotency_unavailable",
	"invalid_json", "invalid_request", "invalid_tool_call_id",
	"invalid_tools", "json_schema_invalid_const_or_enum_type", "json_schema_invalid_name",
	"json_schema_missing_name", "json_schema_missing_schema", "json_schema_non_strict_unsupported",
	"json_schema_strict_requires_additional_properties_false", "json_schema_strict_requires_all_properties_required", "json_schema_too_deep",
	"json_schema_too_large", "json_schema_unsupported_keyword", "json_schema_validation_failed",
	"malformed_json_response", "malformed_settlement_stream", "malformed_tool_call",
	"malformed_tool_call_final_json", "messages_too_long", "model_not_found",
	"no_provider_available", "not_found", "preflight_rejected",
	"provider_disconnected", "provider_error", "provider_failed",
	"provider_not_found", "provider_response_too_large", "provider_stream_downgraded",
	"provider_timeout", "provisional_quota_exceeded", "rate_limited",
	"request_body_too_large", "request_content_encoding_unsupported", "request_log_failed",
	"response_byte_cap_exceeded", "route_snapshot_failed", "session_ended",
	"settlement_finality_failed", "stream_output_exceeded", "streaming_json_object_unsupported",
	"streaming_json_schema_unsupported", "tier2_aead_decrypt_failed", "tier2_attestation_required",
	"tier2_encrypted_leg_required", "tier2_hard_pin_predicate_failed", "tier2_hash_mismatch",
	"tier2_hash_verified_required", "tier2_output_encoding_invalid", "too_many_tool_calls",
	"tool_call_arguments_aggregate_too_large", "tool_call_arguments_too_large", "tool_call_final_close_failed",
	"tool_call_id_not_found", "tool_call_result_out_of_order", "tool_result_too_large",
	"tool_results_aggregate_too_large", "unauthorized", "unsupported_content_shape",
	"unsupported_modelID_for_multi_turn",
}

// TestCoordinatorErrorCodeCompleteness closes L-R2-2 coordinator-side: every
// emitted code must have an EXPLICIT entry in spec018RetryableByCode (true
// or false) — a code present in coordinatorEmittedErrorCodes but absent
// from the map is indistinguishable, at runtime, from an explicit false via
// Go's map zero-value, which is exactly how H2 happened in the first
// place. This does not check the boolean VALUE (TestRetryableByCodeClassification
// does that for the specific codes it names) — only that nobody forgot to
// decide.
//
// Limitation (carried, round-3 finding #4, also in SPEC-006 §5.2): this
// guards the CURRENT hand-curated inventory above, not future ones. A
// brand-new write site with a brand-new code will not fail this test
// merely by existing — it fails only once someone adds it to
// coordinatorEmittedErrorCodes without a matching map entry. Nothing here
// parses server.go at test time to catch a new call site automatically; a
// proper AST/registration-based guard is a separate follow-up.
func TestCoordinatorErrorCodeCompleteness(t *testing.T) {
	for _, code := range coordinatorEmittedErrorCodes {
		if _, ok := spec018RetryableByCode[code]; !ok {
			t.Errorf("code %q is emitted but has no explicit entry in spec018RetryableByCode", code)
		}
	}
}

// TestWriteErrorEnvelopeRetryableField exercises the generic error writer end
// to end and asserts the emitted envelope carries the correct retryable flag
// for a transient code (no_provider_available => true) and a permanent code
// (model_not_found => false).
func TestWriteErrorEnvelopeRetryableField(t *testing.T) {
	cases := []struct {
		code string
		want bool
	}{
		{"no_provider_available", true},
		{"provider_timeout", true},
		{"provider_disconnected", true},
		{"provider_failed", true},
		{"provisional_quota_exceeded", true},
		{"preflight_rejected", true},
		{"idempotency_unavailable", true},
		{"rate_limited", true},
		{"model_not_found", false},
	}
	for _, tc := range cases {
		rr := httptest.NewRecorder()
		writeError(rr, http.StatusServiceUnavailable, tc.code, "x")
		var env struct {
			Error struct {
				Code      string `json:"code"`
				Retryable bool   `json:"retryable"`
			} `json:"error"`
		}
		if err := json.Unmarshal(rr.Body.Bytes(), &env); err != nil {
			t.Fatalf("code %q: bad envelope: %v", tc.code, err)
		}
		if env.Error.Retryable != tc.want {
			t.Errorf("code %q: retryable=%v, want %v", tc.code, env.Error.Retryable, tc.want)
		}
	}
}
