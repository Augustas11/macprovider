package router

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

// Reasoning round trip on /v1/responses (SPEC-006 §5.4b): provider
// reasoning_content is returned as a `reasoning` output item ahead of the
// turn's message and calls, and a `reasoning` input item becomes
// reasoning_content on the assistant message that follows it.

func responsesSSEEvents(t *testing.T, body string) ([]string, []map[string]any) {
	t.Helper()
	var names []string
	var payloads []map[string]any
	for _, frame := range strings.Split(body, "\n\n") {
		var name, data string
		for _, line := range strings.Split(frame, "\n") {
			if v, ok := strings.CutPrefix(line, "event: "); ok {
				name = v
			}
			if v, ok := strings.CutPrefix(line, "data: "); ok {
				data = v
			}
		}
		if name == "" {
			continue
		}
		var payload map[string]any
		if err := json.Unmarshal([]byte(data), &payload); err != nil {
			t.Fatalf("event %s data is not JSON: %v\n%s", name, err, data)
		}
		names = append(names, name)
		payloads = append(payloads, payload)
	}
	return names, payloads
}

func runResponsesStream(t *testing.T, lines ...string) string {
	t.Helper()
	rec := httptest.NewRecorder()
	adapter := newResponsesAdapter(rec, "abababab-abab-4bab-8bab-abababababab", func() time.Time { return time.Unix(1782864000, 0).UTC() })
	if _, failure := adapter.translateRequest([]byte(`{"model":"dsv4","input":"hi","store":false,"stream":true,"tools":[{"type":"function","name":"lookup","parameters":{"type":"object"}}]}`)); failure != nil {
		t.Fatal(failure)
	}
	adapter.WriteHeader(http.StatusOK)
	for _, line := range lines {
		adapter.handleChatStreamLine(line)
	}
	adapter.finish()
	return rec.Body.String()
}

func TestResponsesStreamingReasoningItemPrecedesFunctionCall(t *testing.T) {
	body := runResponsesStream(t,
		`data: {"id":"chatcmpl_rs","model":"dsv4","choices":[{"delta":{"role":"assistant","reasoning_content":"Need to "}}]}`,
		`data: {"id":"chatcmpl_rs","model":"dsv4","choices":[{"delta":{"reasoning_content":"look it up."}}]}`,
		`data: {"id":"chatcmpl_rs","model":"dsv4","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"lookup","arguments":"{\"q\":1}"}}]}}]}`,
		`data: {"id":"chatcmpl_rs","model":"dsv4","usage":{"prompt_tokens":11,"completion_tokens":9,"total_tokens":20,"completion_tokens_details":{"reasoning_tokens":4}},"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
		`data: [DONE]`,
	)
	names, payloads := responsesSSEEvents(t, body)
	want := []string{
		"response.created",
		"response.output_item.added", "response.content_part.added",
		"response.reasoning_text.delta", "response.reasoning_text.delta",
		"response.reasoning_text.done", "response.content_part.done", "response.output_item.done",
		"response.output_item.added", "response.function_call_arguments.delta",
		"response.function_call_arguments.done", "response.output_item.done",
		"response.completed",
	}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("events=%v\nwant %v\n%s", names, want, body)
	}
	payloads = payloads[1:]
	if payloads[0]["output_index"].(float64) != 0 || payloads[7]["output_index"].(float64) != 1 {
		t.Fatalf("reasoning must take output_index 0 and the call 1:\n%s", body)
	}
	added := payloads[0]["item"].(map[string]any)
	if added["type"] != "reasoning" || !reflect.DeepEqual(added["summary"], []any{}) {
		t.Fatalf("reasoning added item=%v", added)
	}
	if got := payloads[4]["text"]; got != "Need to look it up." {
		t.Fatalf("reasoning_text.done text=%v", got)
	}
	done := payloads[6]["item"].(map[string]any)
	wantItem := map[string]any{
		"id": "rs_resp_abababab-abab-4bab-8bab-abababababab", "type": "reasoning", "summary": []any{},
		"content": []any{map[string]any{"type": "reasoning_text", "text": "Need to look it up."}},
	}
	if !reflect.DeepEqual(done, wantItem) {
		t.Fatalf("reasoning done item=%v\nwant %v", done, wantItem)
	}
	response := payloads[len(payloads)-1]["response"].(map[string]any)
	output := response["output"].([]any)
	if len(output) != 2 || !reflect.DeepEqual(output[0], wantItem) || output[1].(map[string]any)["type"] != "function_call" {
		t.Fatalf("completed output=%v", output)
	}
	usage := response["usage"].(map[string]any)
	if usage["input_tokens"].(float64) != 11 || usage["output_tokens"].(float64) != 9 || usage["total_tokens"].(float64) != 20 {
		t.Fatalf("usage changed: %v", usage)
	}
	if got := usage["output_tokens_details"].(map[string]any)["reasoning_tokens"].(float64); got != 4 {
		t.Fatalf("reasoning_tokens=%v want 4", got)
	}
}

func TestResponsesStreamingReasoningItemPrecedesMessage(t *testing.T) {
	body := runResponsesStream(t,
		`data: {"id":"chatcmpl_rm","model":"dsv4","choices":[{"delta":{"reasoning_content":"Easy."}}]}`,
		`data: {"id":"chatcmpl_rm","model":"dsv4","choices":[{"delta":{"content":"Hello"}}]}`,
		`data: {"id":"chatcmpl_rm","model":"dsv4","usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5},"choices":[{"delta":{},"finish_reason":"stop"}]}`,
		`data: [DONE]`,
	)
	names, payloads := responsesSSEEvents(t, body)
	reasoningDone, messageAdded := -1, -1
	for i, name := range names {
		item, _ := payloads[i]["item"].(map[string]any)
		if name == "response.output_item.done" && item["type"] == "reasoning" {
			reasoningDone = i
		}
		if name == "response.output_item.added" && item["type"] == "message" {
			messageAdded = i
		}
	}
	if reasoningDone < 0 || messageAdded < 0 || reasoningDone > messageAdded {
		t.Fatalf("reasoning must close before the message opens: %v", names)
	}
	output := payloads[len(payloads)-1]["response"].(map[string]any)["output"].([]any)
	if len(output) != 2 || output[0].(map[string]any)["type"] != "reasoning" || output[1].(map[string]any)["type"] != "message" {
		t.Fatalf("completed output=%v", output)
	}
	usage := payloads[len(payloads)-1]["response"].(map[string]any)["usage"].(map[string]any)
	if got := usage["output_tokens_details"].(map[string]any)["reasoning_tokens"].(float64); got != 0 {
		t.Fatalf("reasoning_tokens=%v want 0 when the provider reports none", got)
	}
}

func TestResponsesStreamingReasoningOnlyTruncatedStillClosesItem(t *testing.T) {
	body := runResponsesStream(t,
		`data: {"id":"chatcmpl_rt","model":"dsv4","choices":[{"delta":{"reasoning_content":"thinking"}}]}`,
		`data: {"id":"chatcmpl_rt","model":"dsv4","choices":[{"delta":{},"finish_reason":"length"}]}`,
		`data: [DONE]`,
	)
	names, payloads := responsesSSEEvents(t, body)
	if names[len(names)-1] != "response.incomplete" || names[len(names)-2] != "response.output_item.done" {
		t.Fatalf("events=%v", names)
	}
	output := payloads[len(payloads)-1]["response"].(map[string]any)["output"].([]any)
	if len(output) != 1 || output[0].(map[string]any)["type"] != "reasoning" {
		t.Fatalf("incomplete output=%v", output)
	}
}

// The no-reasoning path is unchanged: same events and output as before.
func TestResponsesStreamingWithoutReasoningGolden(t *testing.T) {
	body := runResponsesStream(t,
		`data: {"id":"chatcmpl_plain","model":"llama","choices":[{"delta":{"content":"hi"}}]}`,
		`data: {"id":"chatcmpl_plain","model":"llama","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"lookup","arguments":"{}"}}]}}]}`,
		`data: {"id":"chatcmpl_plain","model":"llama","usage":{"prompt_tokens":4,"completion_tokens":5,"total_tokens":9},"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
		`data: [DONE]`,
	)
	// Captured from origin/main before reasoning items existed.
	golden, err := os.ReadFile("testdata/responses_stream_no_reasoning.golden")
	if err != nil {
		t.Fatal(err)
	}
	if body != string(golden) {
		t.Fatalf("no-reasoning stream changed:\n%s\nwant:\n%s", body, golden)
	}
	_, payloads := responsesSSEEvents(t, body)
	response := payloads[len(payloads)-1]["response"].(map[string]any)
	output, _ := json.Marshal(response["output"])
	wantOutput := `[{"content":[{"annotations":[],"text":"hi","type":"output_text"}],"id":"msg_resp_abababab-abab-4bab-8bab-abababababab","role":"assistant","status":"completed","type":"message"},{"arguments":"{}","call_id":"call_0123456789abcdef","id":"fc_call_0123456789abcdef","name":"lookup","status":"completed","type":"function_call"}]`
	if string(output) != wantOutput {
		t.Fatalf("output=%s\nwant %s", output, wantOutput)
	}
	usage, _ := json.Marshal(response["usage"])
	wantUsage := `{"input_tokens":4,"input_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"output_tokens":5,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":9}`
	if string(usage) != wantUsage {
		t.Fatalf("usage=%s\nwant %s", usage, wantUsage)
	}
}

func translateResponsesNonStreaming(t *testing.T, chat string) map[string]any {
	t.Helper()
	adapter := newResponsesAdapter(httptest.NewRecorder(), "cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd", nil)
	if _, failure := adapter.translateRequest([]byte(`{"model":"dsv4","input":"hi","store":false}`)); failure != nil {
		t.Fatal(failure)
	}
	raw, err := adapter.translateNonStreamingResponse([]byte(chat))
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestResponsesNonStreamingReasoningItemPrecedesOutput(t *testing.T) {
	got := translateResponsesNonStreaming(t, `{
		"id":"chatcmpl_ns","created":1782864000,"model":"dsv4",
		"usage":{"prompt_tokens":7,"completion_tokens":6,"total_tokens":13,"completion_tokens_details":{"reasoning_tokens":3}},
		"choices":[{"message":{"role":"assistant","content":"Done.","reasoning_content":"Check first.",
			"tool_calls":[{"id":"call_0123456789abcdef","type":"function","function":{"name":"lookup","arguments":"{}"}}]},"finish_reason":"tool_calls"}]
	}`)
	output := got["output"].([]any)
	if len(output) != 3 {
		t.Fatalf("output=%v", output)
	}
	wantItem := map[string]any{
		"id": "rs_resp_chatcmpl_ns", "type": "reasoning", "summary": []any{},
		"content": []any{map[string]any{"type": "reasoning_text", "text": "Check first."}},
	}
	if !reflect.DeepEqual(output[0], wantItem) {
		t.Fatalf("reasoning item=%v\nwant %v", output[0], wantItem)
	}
	if output[1].(map[string]any)["type"] != "message" || output[2].(map[string]any)["type"] != "function_call" {
		t.Fatalf("output order=%v", output)
	}
	usage := got["usage"].(map[string]any)
	if usage["input_tokens"].(float64) != 7 || usage["output_tokens"].(float64) != 6 || usage["total_tokens"].(float64) != 13 {
		t.Fatalf("usage changed: %v", usage)
	}
	if r := usage["output_tokens_details"].(map[string]any)["reasoning_tokens"].(float64); r != 3 {
		t.Fatalf("reasoning_tokens=%v want 3", r)
	}
	// A count larger than completion_tokens is not trusted.
	bogus := translateResponsesNonStreaming(t, `{"id":"chatcmpl_ns2","model":"dsv4",
		"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3,"completion_tokens_details":{"reasoning_tokens":9}},
		"choices":[{"message":{"role":"assistant","content":"x"},"finish_reason":"stop"}]}`)
	if r := bogus["usage"].(map[string]any)["output_tokens_details"].(map[string]any)["reasoning_tokens"].(float64); r != 0 {
		t.Fatalf("unsanitized reasoning_tokens=%v", r)
	}
}

func TestResponsesNonStreamingWithoutReasoningGolden(t *testing.T) {
	got := translateResponsesNonStreaming(t, `{
		"id":"chatcmpl_plain","created":1782864000,"model":"llama",
		"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8},
		"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
	}`)
	output, _ := json.Marshal(got["output"])
	if string(output) != `[{"content":[{"annotations":[],"text":"ok","type":"output_text"}],"id":"msg_resp_chatcmpl_plain","role":"assistant","status":"completed","type":"message"}]` {
		t.Fatalf("output=%s", output)
	}
	usage, _ := json.Marshal(got["usage"])
	if string(usage) != `{"input_tokens":5,"input_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"output_tokens":3,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":8}` {
		t.Fatalf("usage=%s", usage)
	}
}

func translatedResponsesMessages(t *testing.T, request string) []map[string]any {
	t.Helper()
	adapter := newResponsesAdapter(httptest.NewRecorder(), "efefefef-efef-4fef-8fef-efefefefefef", nil)
	raw, failure := adapter.translateRequest([]byte(request))
	if failure != nil {
		t.Fatal(failure)
	}
	var chat struct {
		Messages []map[string]any `json:"messages"`
	}
	if err := json.Unmarshal(raw, &chat); err != nil {
		t.Fatal(err)
	}
	return chat.Messages
}

// The history Codex CLI 0.163 sends back for a custom provider: each
// reasoning item as received (summary, reasoning_text content,
// encrypted_content null) followed by that turn's calls.
func TestResponsesReasoningInputAttachesToFollowingAssistantTurn(t *testing.T) {
	messages := translatedResponsesMessages(t, `{"model":"dsv4","store":false,"include":["reasoning.encrypted_content"],"input":[
		{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the bug"}]},
		{"type":"reasoning","id":"rs_resp_a","summary":[],"content":[{"type":"reasoning_text","text":"Read the file first."}],"encrypted_content":null},
		{"type":"function_call","id":"fc_a","call_id":"call_aaaaaaaaaaaaaaaa","name":"exec","arguments":"{\"cmd\":\"cat a\"}"},
		{"type":"function_call_output","call_id":"call_aaaaaaaaaaaaaaaa","output":"a"},
		{"type":"reasoning","id":"rs_resp_b","summary":[],"content":[{"type":"reasoning_text","text":"Now patch it."}],"encrypted_content":null},
		{"type":"function_call","id":"fc_b","call_id":"call_bbbbbbbbbbbbbbbb","name":"exec","arguments":"{}"},
		{"type":"function_call","id":"fc_c","call_id":"call_cccccccccccccccc","name":"exec","arguments":"{}"},
		{"type":"function_call_output","call_id":"call_bbbbbbbbbbbbbbbb","output":"ok"},
		{"type":"function_call_output","call_id":"call_cccccccccccccccc","output":"ok"},
		{"type":"reasoning","summary":[{"type":"summary_text","text":"Summarize."}]},
		{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fixed."}]},
		{"type":"reasoning","summary":[],"content":[{"type":"reasoning_text","text":"orphan"}]},
		{"type":"message","role":"user","content":[{"type":"input_text","text":"thanks"}]}
	]}`)
	type row struct{ role, reasoning string }
	var got []row
	for _, m := range messages {
		r, _ := m["reasoning_content"].(string)
		got = append(got, row{m["role"].(string), r})
	}
	want := []row{
		{"user", ""},
		{"assistant", "Read the file first."},
		{"tool", ""},
		{"assistant", "Now patch it."},
		{"assistant", ""},
		{"tool", ""},
		{"tool", ""},
		{"assistant", "Summarize."},
		{"user", ""},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("messages=%v\nwant %v", got, want)
	}
	for _, m := range messages {
		if _, ok := m["reasoning_content"]; ok && m["role"] != "assistant" {
			t.Fatalf("reasoning_content on non-assistant message: %v", m)
		}
	}
}

func TestResponsesReasoningInputTextSelection(t *testing.T) {
	for name, tc := range map[string]struct {
		item string
		want string
	}{
		"content wins over summary":  {`{"type":"reasoning","summary":[{"type":"summary_text","text":"short"}],"content":[{"type":"reasoning_text","text":"long"}]}`, "long"},
		"text content parts":         {`{"type":"reasoning","summary":[],"content":[{"type":"text","text":"a"},{"type":"reasoning_text","text":"b"}]}`, "a\nb"},
		"encrypted content ignored":  {`{"type":"reasoning","summary":[],"encrypted_content":"gAAAAopaque"}`, ""},
		"unknown part types ignored": {`{"type":"reasoning","summary":[{"type":"other","text":"x"}],"content":[{"type":"image","text":"y"}]}`, ""},
		"malformed parts ignored":    {`{"type":"reasoning","summary":"x","content":[1,{"type":"reasoning_text","text":2}]}`, ""},
		"multiple items joined":      {`{"type":"reasoning","summary":[],"content":[{"type":"reasoning_text","text":"one"}]},{"type":"reasoning","summary":[],"content":[{"type":"reasoning_text","text":"two"}]}`, "one\ntwo"},
	} {
		t.Run(name, func(t *testing.T) {
			messages := translatedResponsesMessages(t, `{"model":"dsv4","store":false,"input":[
				{"type":"message","role":"user","content":"q"},`+tc.item+`,
				{"type":"function_call","call_id":"call_aaaaaaaaaaaaaaaa","name":"exec","arguments":"{}"}]}`)
			got, has := messages[1]["reasoning_content"].(string)
			if tc.want == "" {
				if has {
					t.Fatalf("reasoning_content=%q want none", got)
				}
				return
			}
			if got != tc.want {
				t.Fatalf("reasoning_content=%q want %q", got, tc.want)
			}
		})
	}
}

type responsesReasoningUsageRow struct {
	prompt, completion, total int64
	source                    string
}

func responsesUsageRow(t *testing.T, dbPath, accountID string) responsesReasoningUsageRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var row responsesReasoningUsageRow
	if err := db.QueryRow(`SELECT prompt_tokens, completion_tokens, total_tokens, token_source FROM usage_events WHERE account_id = ?`, accountID).
		Scan(&row.prompt, &row.completion, &row.total, &row.source); err != nil {
		t.Fatal(err)
	}
	return row
}

// Reasoning is already inside the provider's completion_tokens. Returning it
// as an item, and forwarding history reasoning, leaves the billed usage row
// and the reported usage identical to the same response without reasoning.
func TestResponsesReasoningDoesNotChangeBilledUsage(t *testing.T) {
	const usage = `"usage":{"prompt_tokens":40,"completion_tokens":25,"total_tokens":65,"completion_tokens_details":{"reasoning_tokens":18}}`
	for _, stream := range []bool{false, true} {
		rows := map[bool]responsesReasoningUsageRow{}
		reported := map[bool]string{}
		for _, withReasoning := range []bool{false, true} {
			reasoningField := ""
			if withReasoning {
				reasoningField = `"reasoning_content":"step by step",`
			}
			var captured map[string]any
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if err := json.NewDecoder(r.Body).Decode(&captured); err != nil {
					t.Fatalf("decode upstream: %v", err)
				}
				if stream {
					body := strings.Join([]string{
						`data: {"id":"chatcmpl_bill","model":"dsv4","choices":[{"delta":{` + reasoningField + `"content":"answer"}}]}`,
						`data: {"id":"chatcmpl_bill","model":"dsv4",` + usage + `,"choices":[{"delta":{},"finish_reason":"stop"}]}`,
						`data: [DONE]`, ``,
					}, "\n\n")
					return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, body), nil
				}
				return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}},
					`{"id":"chatcmpl_bill","object":"chat.completion","created":1782864000,"model":"dsv4",`+usage+`,
					"choices":[{"index":0,"message":{"role":"assistant",`+reasoningField+`"content":"answer"},"finish_reason":"stop"}]}`), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
			account := "acct_responses_reasoning_bill"
			key := createAccountAndKey(t, store, cfg, account)
			resp := postResponses(t, h, key, `{"model":"dsv4","store":false,"stream":`+map[bool]string{true: "true", false: "false"}[stream]+`,"input":[
				{"type":"message","role":"user","content":"q"},
				{"type":"reasoning","summary":[],"content":[{"type":"reasoning_text","text":"earlier thought"}]},
				{"type":"function_call","call_id":"call_aaaaaaaaaaaaaaaa","name":"exec","arguments":"{}"},
				{"type":"function_call_output","call_id":"call_aaaaaaaaaaaaaaaa","output":"done"}
			]}`, nil)
			if resp.Code != http.StatusOK {
				t.Fatalf("stream=%v status=%d body=%s", stream, resp.Code, resp.Body.String())
			}
			// The gateway forwards history reasoning on the assistant turn.
			msgs := captured["messages"].([]any)
			if got := msgs[1].(map[string]any)["reasoning_content"]; got != "earlier thought" {
				t.Fatalf("upstream assistant reasoning_content=%v messages=%v", got, msgs)
			}
			body := resp.Body.String()
			if withReasoning != strings.Contains(body, `"type":"reasoning"`) {
				t.Fatalf("stream=%v withReasoning=%v reasoning item presence wrong:\n%s", stream, withReasoning, body)
			}
			var usageJSON string
			if stream {
				_, payloads := responsesSSEEvents(t, body)
				b, _ := json.Marshal(payloads[len(payloads)-1]["response"].(map[string]any)["usage"])
				usageJSON = string(b)
			} else {
				var out map[string]any
				if err := json.Unmarshal(resp.Body.Bytes(), &out); err != nil {
					t.Fatal(err)
				}
				b, _ := json.Marshal(out["usage"])
				usageJSON = string(b)
			}
			reported[withReasoning] = usageJSON
			rows[withReasoning] = responsesUsageRow(t, dbPath, account)
		}
		if rows[true] != rows[false] {
			t.Fatalf("stream=%v billed usage differs: with=%+v without=%+v", stream, rows[true], rows[false])
		}
		if rows[true].prompt != 40 || rows[true].completion != 25 || rows[true].total != 65 {
			t.Fatalf("stream=%v billed usage=%+v want provider-reported 40/25/65", stream, rows[true])
		}
		if reported[true] != reported[false] {
			t.Fatalf("stream=%v reported usage differs:\nwith=%s\nwithout=%s", stream, reported[true], reported[false])
		}
		want := `{"input_tokens":40,"input_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"output_tokens":25,"output_tokens_details":{"reasoning_tokens":18},"total_tokens":65}`
		if reported[true] != want {
			t.Fatalf("stream=%v reported usage=%s want %s", stream, reported[true], want)
		}
	}
}
