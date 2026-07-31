package router

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func TestResponsesRouteFlagOffReturnsNotFound(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{})
	key := createAccountAndKey(t, store, cfg, "acct_responses_flag_off")

	resp := postResponses(t, h, key, `{"model":"llama","input":"hi","store":false}`, nil)

	if resp.Code != http.StatusNotFound {
		t.Fatalf("status=%d want 404 body=%s", resp.Code, resp.Body.String())
	}
}

func TestResponsesNonStreamingTranslatesThroughChatPipeline(t *testing.T) {
	var capturedPath string
	var capturedBody map[string]any
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		capturedPath = r.URL.Path
		if err := json.NewDecoder(r.Body).Decode(&capturedBody); err != nil {
			t.Fatalf("decode upstream request: %v", err)
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_resp_1",
			"object":"chat.completion",
			"created":1782864000,
			"model":"llama",
			"usage":{"prompt_tokens":5,"cached_prompt_tokens":2,"completion_tokens":3,"total_tokens":8},
			"choices":[{"index":0,"message":{"role":"assistant","content":"<think>hidden</think> visible answer"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_nonstream")

	resp := postResponses(t, h, key, `{
		"model":"llama",
		"instructions":"be terse",
		"input":[{"role":"user","content":[{"type":"input_text","text":"hi"}]}],
		"max_output_tokens":20,
		"store":false,
		"tools":[{"type":"function","name":"lookup","description":"lookup","parameters":{"type":"object"}}]
	}`, map[string]string{"X-Request-ID": "12121212-1212-4212-8212-121212121212"})

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if capturedPath != "/v1/chat/completions" {
		t.Fatalf("upstream path=%q want /v1/chat/completions", capturedPath)
	}
	if got := capturedBody["max_tokens"].(float64); got != 20 {
		t.Fatalf("translated max_tokens=%v want 20", got)
	}
	messages := capturedBody["messages"].([]any)
	if len(messages) != 2 {
		t.Fatalf("translated messages=%v want system+user", messages)
	}
	if messages[0].(map[string]any)["role"] != "system" || messages[0].(map[string]any)["content"] != "be terse" {
		t.Fatalf("system message not translated: %v", messages[0])
	}
	if messages[1].(map[string]any)["role"] != "user" || messages[1].(map[string]any)["content"] != "hi" {
		t.Fatalf("user message not translated: %v", messages[1])
	}
	tools := capturedBody["tools"].([]any)
	fn := tools[0].(map[string]any)["function"].(map[string]any)
	if fn["name"] != "lookup" {
		t.Fatalf("tool not translated: %v", tools)
	}

	var body map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("responses json: %v body=%s", err, resp.Body.String())
	}
	if body["object"] != "response" || body["status"] != "completed" || body["store"] != false {
		t.Fatalf("bad response envelope: %v", body)
	}
	output := body["output"].([]any)
	message := output[0].(map[string]any)
	if message["status"] != "completed" {
		t.Fatalf("message status=%v want completed", message["status"])
	}
	text := message["content"].([]any)[0].(map[string]any)["text"]
	if text != "visible answer" {
		t.Fatalf("output text=%q want stripped visible answer", text)
	}
	usage := body["usage"].(map[string]any)
	if usage["input_tokens"].(float64) != 5 || usage["output_tokens"].(float64) != 3 {
		t.Fatalf("usage not mapped: %v", usage)
	}
	if usage["output_tokens_details"].(map[string]any)["reasoning_tokens"].(float64) != 0 {
		t.Fatalf("usage output details not populated: %v", usage)
	}
	gotSettlement := gatewaySettlementSnapshot(t, dbPath, "acct_responses_nonstream")
	if gotSettlement.usageRows != 1 || gotSettlement.settledRows != 1 || gotSettlement.activeRows != 0 {
		t.Fatalf("settlement=%+v want one settled usage row", gotSettlement)
	}
}

func TestResponsesCodex0146DefaultToolsAreFlattened(t *testing.T) {
	var capturedBody map[string]any
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if err := json.NewDecoder(r.Body).Decode(&capturedBody); err != nil {
			t.Fatalf("decode upstream request: %v", err)
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_codex_tools",
			"object":"chat.completion",
			"created":1782864000,
			"model":"llama",
			"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_codex_0146_tools")

	resp := postResponses(t, h, key, `{
		"model":"llama",
		"input":"hi",
		"include":["reasoning.encrypted_content"],
		"reasoning":{"summary":"auto"},
		"parallel_tool_calls":false,
		"store":false,
		"tools":[
			{"type":"function","name":"exec_command","description":"Run a command","parameters":{"type":"object"},"strict":true},
			{"type":"function","name":"write_stdin","description":"Write to a command","parameters":{"type":"object"},"strict":true},
			{"type":"function","name":"update_plan","description":"Update the plan","parameters":{"type":"object"},"strict":true},
			{"type":"function","name":"request_user_input","description":"Ask for user input","parameters":{"type":"object"},"strict":true},
			{"type":"function","name":"view_image","description":"View an image","parameters":{"type":"object"},"strict":true},
			{"type":"namespace","name":"multi_agent_v1","tools":[
				{"type":"function","name":"close_agent","description":"Close an agent","parameters":{"type":"object"},"strict":true},
				{"type":"function","name":"resume_agent","description":"Resume an agent","parameters":{"type":"object"},"strict":true},
				{"type":"function","name":"send_input","description":"Send input to an agent","parameters":{"type":"object"},"strict":true},
				{"type":"function","name":"spawn_agent","description":"Spawn an agent","parameters":{"type":"object"},"strict":true},
				{"type":"function","name":"wait_agent","description":"Wait for an agent","parameters":{"type":"object"},"strict":true}
			]},
			{"type":"function","name":"get_goal","description":"Get the current goal","parameters":{"type":"object"},"strict":true},
			{"type":"function","name":"create_goal","description":"Create a goal","parameters":{"type":"object"},"strict":true},
			{"type":"function","name":"update_goal","description":"Update the goal","parameters":{"type":"object"},"strict":true},
			{"type":"web_search","external_web_access":true}
		]
	}`, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if parallelToolCalls, ok := capturedBody["parallel_tool_calls"].(bool); !ok || parallelToolCalls {
		t.Fatalf("forwarded parallel_tool_calls=%v want false", capturedBody["parallel_tool_calls"])
	}
	if _, ok := capturedBody["include"]; ok {
		t.Fatalf("forwarded Responses include control: %v", capturedBody["include"])
	}
	if _, ok := capturedBody["reasoning"]; ok {
		t.Fatalf("forwarded Responses reasoning control: %v", capturedBody["reasoning"])
	}
	tools := capturedBody["tools"].([]any)
	wantNames := []string{
		"exec_command",
		"write_stdin",
		"update_plan",
		"request_user_input",
		"view_image",
		"close_agent",
		"resume_agent",
		"send_input",
		"spawn_agent",
		"wait_agent",
		"get_goal",
		"create_goal",
		"update_goal",
	}
	if len(tools) != len(wantNames) {
		t.Fatalf("forwarded tool count=%d want %d tools=%v", len(tools), len(wantNames), tools)
	}
	gotNames := make(map[string]bool, len(tools))
	for _, raw := range tools {
		tool := raw.(map[string]any)
		if tool["type"] != "function" {
			t.Fatalf("forwarded non-function tool: %v", tool)
		}
		fn := tool["function"].(map[string]any)
		name := fn["name"].(string)
		if name == "multi_agent_v1" || name == "web_search" {
			t.Fatalf("forwarded dropped tool %q in %v", name, tools)
		}
		if fn["parameters"].(map[string]any)["type"] != "object" {
			t.Fatalf("tool parameters not preserved for %q: %v", name, fn)
		}
		gotNames[name] = true
	}
	for _, name := range wantNames {
		if !gotNames[name] {
			t.Fatalf("missing forwarded tool %q in %v", name, tools)
		}
	}
}

func TestResponsesUnknownHostedToolTypeIsAcceptedAndDropped(t *testing.T) {
	var capturedBody map[string]any
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if err := json.NewDecoder(r.Body).Decode(&capturedBody); err != nil {
			t.Fatalf("decode upstream request: %v", err)
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_unknown_hosted_tool",
			"object":"chat.completion",
			"created":1782864000,
			"model":"llama",
			"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_unknown_hosted_tool")

	resp := postResponses(t, h, key, `{
		"model":"llama",
		"input":"hi",
		"store":false,
		"tools":[{"type":"future_hosted_tool","name":"future_search"}]
	}`, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if _, ok := capturedBody["tools"]; ok {
		t.Fatalf("forwarded tools for dropped hosted tool: %v", capturedBody["tools"])
	}
}

func TestResponsesNonStreamingLengthFinishReasonIsIncomplete(t *testing.T) {
	adapter := newResponsesAdapter(httptest.NewRecorder(), "23232323-2323-4232-8232-232323232323", nil)
	adapter.model = "llama"

	body, err := adapter.translateNonStreamingResponse([]byte(`{
		"id":"chatcmpl_incomplete",
		"created":1782864000,
		"model":"llama",
		"usage":{"prompt_tokens":5,"completion_tokens":20,"total_tokens":25},
		"choices":[{"message":{"role":"assistant","content":"partial"},"finish_reason":"length"}]
	}`))
	if err != nil {
		t.Fatalf("translate response: %v", err)
	}
	var resp map[string]any
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("responses json: %v", err)
	}
	if resp["status"] != "incomplete" {
		t.Fatalf("status=%v want incomplete body=%s", resp["status"], string(body))
	}
	details := resp["incomplete_details"].(map[string]any)
	if details["reason"] != "max_output_tokens" {
		t.Fatalf("incomplete_details=%v want max_output_tokens", details)
	}
}

func TestResponsesRejectsUnsupportedStateBeforeReservation(t *testing.T) {
	tests := []struct {
		name string
		body string
		code string
	}{
		{name: "store_true", body: `{"model":"llama","input":"hi","store":true}`, code: "unsupported_parameter"},
		{name: "previous_response_id", body: `{"model":"llama","input":"hi","store":false,"previous_response_id":"resp_123"}`, code: "unsupported_parameter"},
		{name: "multimodal_content", body: `{"model":"llama","input":[{"role":"user","content":[{"type":"input_image","image_url":"https://example.invalid/a.png"}]}],"store":false}`, code: "invalid_request"},
		{name: "legacy_response_format", body: `{"model":"llama","input":"hi","store":false,"response_format":{"type":"json_object"}}`, code: "unsupported_parameter"},
		{name: "conversation", body: `{"model":"llama","input":"hi","store":false,"conversation":{"id":"conv_123"}}`, code: "unsupported_parameter"},
		{name: "background", body: `{"model":"llama","input":"hi","store":false,"background":true}`, code: "unsupported_parameter"},
		{name: "truncation_auto", body: `{"model":"llama","input":"hi","store":false,"truncation":"auto"}`, code: "unsupported_parameter"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			called := false
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				called = true
				return responseWithBody(http.StatusOK, nil, `{}`), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
			acct := "acct_responses_reject_" + tc.name
			key := createAccountAndKey(t, store, cfg, acct)

			resp := postResponses(t, h, key, tc.body, nil)

			if resp.Code != http.StatusBadRequest {
				t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), tc.code)
			if called {
				t.Fatalf("coordinator was called for rejected request")
			}
			gotSettlement := gatewaySettlementSnapshot(t, dbPath, acct)
			if gotSettlement.usageRows != 0 || gotSettlement.activeRows != 0 || gotSettlement.settledRows != 0 {
				t.Fatalf("settlement after rejected request=%+v want empty", gotSettlement)
			}
		})
	}
}

func TestResponsesStreamingPostTranslationValidationErrorIsForwarded(t *testing.T) {
	called := false
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		called = true
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_stream_validation")

	resp := postResponses(t, h, key, `{"model":"llama","input":"hi","stream":true,"max_output_tokens":999999999,"store":false}`, nil)

	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "max_tokens_exceeded")
	if called {
		t.Fatalf("coordinator was called for max-token rejected request")
	}
	gotSettlement := gatewaySettlementSnapshot(t, dbPath, "acct_responses_stream_validation")
	if gotSettlement.usageRows != 0 || gotSettlement.activeRows != 0 || gotSettlement.settledRows != 0 {
		t.Fatalf("settlement after rejected request=%+v want empty", gotSettlement)
	}
}

func TestResponsesTextFormatTranslatesToChatResponseFormat(t *testing.T) {
	var capturedBody map[string]any
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if err := json.NewDecoder(r.Body).Decode(&capturedBody); err != nil {
			t.Fatalf("decode upstream request: %v", err)
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_structured",
			"created":1782864000,
			"model":"llama",
			"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8},
			"choices":[{"message":{"role":"assistant","content":"{\"answer\":\"hi\"}"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_text_format")

	resp := postResponses(t, h, key, `{
		"model":"llama",
		"input":"hi",
		"store":false,
		"text":{"format":{"type":"json_schema","name":"answer_schema","strict":true,"schema":{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}}}
	}`, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	responseFormat := capturedBody["response_format"].(map[string]any)
	if responseFormat["type"] != "json_schema" {
		t.Fatalf("chat response_format=%v want json_schema", responseFormat)
	}
	jsonSchema := responseFormat["json_schema"].(map[string]any)
	if jsonSchema["name"] != "answer_schema" || jsonSchema["strict"] != true {
		t.Fatalf("chat json_schema not translated: %v", jsonSchema)
	}
	var body map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("responses json: %v", err)
	}
	text := body["text"].(map[string]any)
	format := text["format"].(map[string]any)
	if format["type"] != "json_schema" || format["name"] != "answer_schema" {
		t.Fatalf("response text.format=%v want echoed json_schema", format)
	}
}

func TestResponsesStreamingUpstreamNonOKErrorIsForwarded(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusBadGateway, http.Header{"Content-Type": []string{"application/json"}}, `{"error":{"message":"bad upstream","type":"api_error","code":"provider_error"}}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_stream_upstream_non_ok")

	resp := postResponses(t, h, key, `{"model":"llama","input":"hi","stream":true,"max_output_tokens":20,"store":false}`, map[string]string{"X-Request-ID": "57575757-5757-4757-8757-575757575757"})

	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d want 502 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "upstream_provider_error")
	outcome, source := usageEventOutcome(t, dbPath, "acct_responses_stream_upstream_non_ok")
	if outcome != "upstream_error" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source=%s/%s want upstream_error/gateway_estimated", outcome, source)
	}
}

func TestResponsesNonStreamingInvalidProviderResponseDoesNotSettleOK(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `not-json`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_invalid_provider_response")

	resp := postResponses(t, h, key, `{"model":"llama","input":"hi","max_output_tokens":20,"store":false}`, map[string]string{"X-Request-ID": "68686868-6868-4686-8686-686868686868"})

	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d want 502 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "invalid_provider_response")
	outcome, source, completion, _ := usageEventOutcomeAndTokens(t, dbPath, "acct_responses_invalid_provider_response")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" || completion != 0 {
		t.Fatalf("usage outcome/source/completion=%s/%s/%d want invalid_provider_response/gateway_estimated/0", outcome, source, completion)
	}
}

func TestResponsesInputFunctionCallUsesCallIDForChatToolID(t *testing.T) {
	adapter := newResponsesAdapter(httptest.NewRecorder(), "56565656-5656-4656-8656-565656565656", nil)

	body, err := adapter.translateRequest([]byte(`{
		"model":"llama",
		"input":[
			{"role":"user","content":"hi"},
			{"type":"function_call","id":"fc_lookup","call_id":"call_lookup","name":"lookup","arguments":"{\"q\":\"hi\"}"},
			{"type":"function_call_output","call_id":"call_lookup","output":"ok"}
		],
		"store":false
	}`))
	if err != nil {
		t.Fatalf("translate request: %v", err)
	}
	var chat map[string]any
	if err := json.Unmarshal(body, &chat); err != nil {
		t.Fatalf("chat json: %v", err)
	}
	messages := chat["messages"].([]any)
	assistant := messages[1].(map[string]any)
	toolCall := assistant["tool_calls"].([]any)[0].(map[string]any)
	if toolCall["id"] != "call_lookup" {
		t.Fatalf("chat tool_call id=%v want call_lookup", toolCall["id"])
	}
	tool := messages[2].(map[string]any)
	if tool["tool_call_id"] != "call_lookup" {
		t.Fatalf("tool_call_id=%v want call_lookup", tool["tool_call_id"])
	}
}

func TestResponsesStreamingTextAndToolEvents(t *testing.T) {
	stream := strings.Join([]string{
		`data: {"id":"chatcmpl_stream_resp","model":"llama","choices":[{"delta":{"content":"hel"}}]}`,
		`data: {"id":"chatcmpl_stream_resp","model":"llama","choices":[{"delta":{"content":"lo"}}]}`,
		`data: {"id":"chatcmpl_stream_resp","model":"llama","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_lookup","type":"function","function":{"name":"lookup","arguments":"{\"q\""}}]}}]}`,
		`data: {"id":"chatcmpl_stream_resp","model":"llama","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\"hi\"}"}}]}}]}`,
		`data: {"id":"chatcmpl_stream_resp","model":"llama","usage":{"prompt_tokens":4,"completion_tokens":5,"total_tokens":9},"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
		`data: [DONE]`,
		``,
	}, "\n\n")
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_stream")

	resp := postResponses(t, h, key, `{
		"model":"llama",
		"input":"hi",
		"stream":true,
		"max_output_tokens":20,
		"store":false,
		"tools":[{"type":"function","name":"lookup","parameters":{"type":"object"}}]
	}`, map[string]string{"X-Request-ID": "34343434-3434-4434-8434-343434343434"})

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	for _, want := range []string{
		"event: response.created",
		"event: response.output_text.delta",
		`"status":"in_progress"`,
		`"delta":"hel"`,
		"event: response.function_call_arguments.delta",
		"event: response.function_call_arguments.done",
		`"name":"lookup"`,
		"event: response.completed",
		`"status":"completed"`,
		`"input_tokens":4`,
		`"reasoning_tokens":0`,
		"data: [DONE]",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("stream missing %q:\n%s", want, body)
		}
	}
	gotSettlement := gatewaySettlementSnapshot(t, dbPath, "acct_responses_stream")
	if gotSettlement.usageRows != 1 || gotSettlement.settledRows != 1 || gotSettlement.activeRows != 0 {
		t.Fatalf("settlement=%+v want one settled usage row", gotSettlement)
	}
}

func TestResponsesStreamingChatErrorBecomesFailedTerminal(t *testing.T) {
	rec := httptest.NewRecorder()
	adapter := newResponsesAdapter(rec, "67676767-6767-4676-8676-676767676767", nil)
	adapter.stream = true
	adapter.model = "llama"
	adapter.WriteHeader(http.StatusOK)

	adapter.handleChatStreamLine(`data: {"error":{"message":"Provider timed out during streaming","type":"api_error","code":"provider_timeout","retryable":true}}`)
	adapter.handleChatStreamLine(`data: [DONE]`)

	body := rec.Body.String()
	for _, want := range []string{
		"event: response.failed",
		`"status":"failed"`,
		`"code":"provider_timeout"`,
		"data: [DONE]",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("failed stream missing %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, "event: response.completed") {
		t.Fatalf("failed stream emitted completed:\n%s", body)
	}
}

func TestResponsesStreamingSplitThinkAndReasoningContentAreHidden(t *testing.T) {
	rec := httptest.NewRecorder()
	adapter := newResponsesAdapter(rec, "89898989-8989-4898-8898-898989898989", nil)
	adapter.stream = true
	adapter.model = "llama"
	adapter.WriteHeader(http.StatusOK)

	adapter.handleChatStreamLine(`data: {"id":"chatcmpl_think","model":"llama","choices":[{"delta":{"content":"<thi"}}]}`)
	adapter.handleChatStreamLine(`data: {"id":"chatcmpl_think","model":"llama","choices":[{"delta":{"content":"nk>hidden"}}]}`)
	adapter.handleChatStreamLine(`data: {"id":"chatcmpl_think","model":"llama","choices":[{"delta":{"reasoning_content":"also hidden","content":"</think> visible"}}]}`)
	adapter.handleChatStreamLine(`data: [DONE]`)

	body := rec.Body.String()
	if strings.Contains(body, "hidden") || strings.Contains(body, "<think") || strings.Contains(body, "reasoning_content") {
		t.Fatalf("stream leaked hidden reasoning:\n%s", body)
	}
	if !strings.Contains(body, `"delta":" visible"`) || !strings.Contains(body, "event: response.completed") {
		t.Fatalf("stream missing visible completion:\n%s", body)
	}
}

func TestResponsesStreamingLengthFinishReasonIsIncomplete(t *testing.T) {
	rec := httptest.NewRecorder()
	adapter := newResponsesAdapter(rec, "90909090-9090-4090-8090-909090909090", nil)
	adapter.stream = true
	adapter.model = "llama"
	adapter.WriteHeader(http.StatusOK)

	adapter.handleChatStreamLine(`data: {"id":"chatcmpl_incomplete_stream","model":"llama","usage":{"prompt_tokens":3,"completion_tokens":7,"total_tokens":10},"choices":[{"delta":{"content":"partial"},"finish_reason":"length"}]}`)
	adapter.handleChatStreamLine(`data: [DONE]`)

	body := rec.Body.String()
	for _, want := range []string{
		"event: response.incomplete",
		`"status":"incomplete"`,
		`"reason":"max_output_tokens"`,
		`"input_tokens":3`,
		"data: [DONE]",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("incomplete stream missing %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, "event: response.completed") {
		t.Fatalf("incomplete stream emitted completed:\n%s", body)
	}
}

func TestResponsesStreamingToolOnlyStartsAtOutputIndexZero(t *testing.T) {
	rec := httptest.NewRecorder()
	adapter := newResponsesAdapter(rec, "78787878-7878-4878-8878-787878787878", nil)
	adapter.stream = true
	adapter.model = "llama"
	adapter.WriteHeader(http.StatusOK)

	adapter.handleChatStreamLine(`data: {"id":"chatcmpl_tool_only","model":"llama","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_lookup","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"hi\"}"}}]}}]}`)
	adapter.handleChatStreamLine(`data: [DONE]`)

	body := rec.Body.String()
	for _, want := range []string{
		"event: response.function_call_arguments.delta",
		`"output_index":0`,
		"event: response.completed",
		"data: [DONE]",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("tool-only stream missing %q:\n%s", want, body)
		}
	}
}

func TestResponsesDisclosureIncludesEndpointOnlyWhenEnabled(t *testing.T) {
	defaultDisclosure := (&Server{}).makeTier1Disclosure()
	if !reflectDeepEqualStrings(defaultDisclosure.VerifiedModelSettlement.IncludedPaidEntrypoints, []string{"POST /v1/chat/completions"}) {
		t.Fatalf("default included entrypoints=%v", defaultDisclosure.VerifiedModelSettlement.IncludedPaidEntrypoints)
	}
	cfg := config.Default()
	cfg.Features.ResponsesAPIEnabled = true
	enabledDisclosure := (&Server{cfg: cfg}).makeTier1Disclosure()
	if !reflectDeepEqualStrings(enabledDisclosure.VerifiedModelSettlement.IncludedPaidEntrypoints, []string{"POST /v1/chat/completions", "POST /v1/responses"}) {
		t.Fatalf("enabled included entrypoints=%v", enabledDisclosure.VerifiedModelSettlement.IncludedPaidEntrypoints)
	}
}

func enableResponsesWithCoordinator(cfg *config.Config) {
	cfg.Features.ResponsesAPIEnabled = true
	cfg.Coordinator.BuyerURL = "http://coordinator.test"
}

func postResponses(t *testing.T, h http.Handler, bearer, body string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+bearer)
	req.Header.Set("Content-Type", "application/json")
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	return resp
}

func reflectDeepEqualStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
