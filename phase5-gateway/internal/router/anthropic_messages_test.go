package router

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func TestAnthropicMessagesRouteIsFeatureFlaggedOff(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{})

	resp := postAnthropicMessages(t, h, "", `{"model":"claude","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusNotFound {
		t.Fatalf("status=%d want 404 body=%s", resp.Code, resp.Body.String())
	}
}

func TestAnthropicMessagesNonStreamingTranslatesThroughBilledChatPath(t *testing.T) {
	var upstreamHits int
	var upstreamBody map[string]any
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits++
		if r.URL.Path != "/v1/chat/completions" {
			t.Fatalf("upstream path=%s want /v1/chat/completions", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&upstreamBody); err != nil {
			t.Fatalf("decode upstream request: %v", err)
		}
		body := `{"id":"chatcmpl_123","object":"chat.completion","created":1,"model":"claude-3-5-sonnet-latest","service_tier":"default",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"done","tool_calls":[{"id":"toolu_lookup","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"mac\"}"}}]},"finish_reason":"tool_calls"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_nonstream")

	reqBody := `{
		"model":"claude-3-5-sonnet-latest",
		"max_tokens":32,
		"system":[{"type":"text","text":"system prompt"}],
		"messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}],
		"tools":[{"type":"custom","name":"lookup","description":"Lookup things","input_schema":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}}],
		"tool_choice":{"type":"tool","name":"lookup","disable_parallel_tool_use":true},
		"metadata":{"user_id":"u"},
		"stop_sequences":["STOP"],
		"temperature":0.2
	}`
	resp := postAnthropicMessages(t, h, "", reqBody, map[string]string{"X-Api-Key": key})
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if upstreamHits != 1 {
		t.Fatalf("upstream hits=%d want 1", upstreamHits)
	}
	assertChatRequestField(t, upstreamBody, "model", "claude-3-5-sonnet-latest")
	assertChatRequestField(t, upstreamBody, "max_tokens", float64(32))
	assertChatRequestField(t, upstreamBody, "stream", false)
	assertChatRequestField(t, upstreamBody, "temperature", float64(0.2))
	if stop, _ := upstreamBody["stop"].([]any); len(stop) != 1 || stop[0] != "STOP" {
		t.Fatalf("translated stop=%v want [STOP]", upstreamBody["stop"])
	}
	messages, _ := upstreamBody["messages"].([]any)
	if len(messages) != 2 {
		t.Fatalf("messages=%v want system+user", upstreamBody["messages"])
	}
	if messages[0].(map[string]any)["role"] != "system" || messages[0].(map[string]any)["content"] != "system prompt" {
		t.Fatalf("system message not translated: %v", messages[0])
	}
	tools, _ := upstreamBody["tools"].([]any)
	if len(tools) != 1 || tools[0].(map[string]any)["type"] != "function" {
		t.Fatalf("tools not translated: %v", upstreamBody["tools"])
	}
	choice := upstreamBody["tool_choice"].(map[string]any)
	if choice["type"] != "function" || choice["function"].(map[string]any)["name"] != "lookup" {
		t.Fatalf("tool_choice not translated: %v", choice)
	}
	assertChatRequestField(t, upstreamBody, "parallel_tool_calls", false)
	if _, ok := upstreamBody["metadata"]; ok {
		t.Fatalf("metadata was forwarded to chat request: %v", upstreamBody["metadata"])
	}

	var anth map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &anth); err != nil {
		t.Fatalf("anthropic response json: %v body=%s", err, resp.Body.String())
	}
	if anth["type"] != "message" || anth["role"] != "assistant" || anth["stop_reason"] != "tool_use" {
		t.Fatalf("unexpected Anthropic response envelope: %v", anth)
	}
	content, _ := anth["content"].([]any)
	if len(content) != 2 || content[0].(map[string]any)["type"] != "text" || content[1].(map[string]any)["type"] != "tool_use" {
		t.Fatalf("unexpected Anthropic content blocks: %v", anth["content"])
	}
	usage := anth["usage"].(map[string]any)
	if usage["input_tokens"] != float64(5) || usage["output_tokens"] != float64(7) {
		t.Fatalf("usage=%v want 5/7", usage)
	}
	snap := gatewaySettlementSnapshot(t, dbPath, "acct_anthropic_nonstream")
	if snap.usageRows != 1 || snap.settledRows != 1 || snap.activeRows != 0 {
		t.Fatalf("settlement snapshot=%+v want one settled usage row", snap)
	}
}

func TestAnthropicMessagesNonStreamingIncludesMatchedStopSequence(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_stopseq","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"done"},"finish_reason":"stop_sequence","stop_sequence":"STOP"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_nonstream_stop_sequence")

	resp := postAnthropicMessages(t, h, "", `{"model":"claude","max_tokens":8,"stop_sequences":["STOP"],"messages":[{"role":"user","content":"hi"}]}`, map[string]string{"X-Api-Key": key})
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var anth map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &anth); err != nil {
		t.Fatalf("anthropic response json: %v body=%s", err, resp.Body.String())
	}
	if anth["stop_reason"] != "stop_sequence" || anth["stop_sequence"] != "STOP" {
		t.Fatalf("stop reason/sequence=%v/%v want stop_sequence/STOP body=%s", anth["stop_reason"], anth["stop_sequence"], resp.Body.String())
	}
}

func TestAnthropicMessagesNonStreamingInfersStopSequenceFromStopSuffix(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_stopseq_suffix","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"doneSTOP"},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_nonstream_stop_suffix")

	resp := postAnthropicMessages(t, h, "", `{"model":"claude","max_tokens":8,"stop_sequences":["STOP"],"messages":[{"role":"user","content":"hi"}]}`, map[string]string{"X-Api-Key": key})
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var anth map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &anth); err != nil {
		t.Fatalf("anthropic response json: %v body=%s", err, resp.Body.String())
	}
	if anth["stop_reason"] != "stop_sequence" || anth["stop_sequence"] != "STOP" {
		t.Fatalf("stop reason/sequence=%v/%v want stop_sequence/STOP body=%s", anth["stop_reason"], anth["stop_sequence"], resp.Body.String())
	}
	content, _ := anth["content"].([]any)
	if len(content) != 1 || content[0].(map[string]any)["text"] != "done" {
		t.Fatalf("content=%v want text without stop sequence", anth["content"])
	}
}

func TestAnthropicMessagesRejectsUnsupportedFeaturesBeforeReservation(t *testing.T) {
	var upstreamHits int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits++
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_reject")

	for name, tc := range map[string]struct {
		body string
		want string
	}{
		"image":             {`{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"abc"}}]}]}`, "image content is not supported"},
		"unknown top-level": {`{"model":"claude","max_tokens":8,"container":"c","messages":[{"role":"user","content":"hi"}]}`, "container is not supported"},
		"empty thinking":    {`{"model":"claude","max_tokens":8,"thinking":{},"messages":[{"role":"user","content":"hi"}]}`, "Anthropic beta features are not supported"},
		"top_k":             {`{"model":"claude","max_tokens":8,"top_k":5,"messages":[{"role":"user","content":"hi"}]}`, "top_k is not supported"},
		"tool_choice scalar": {`{"model":"claude","max_tokens":8,"tool_choice":"auto","messages":[{"role":"user","content":"hi"}]}`,
			"tool_choice must be an object"},
		"bad user text": {`{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":[{"type":"text","text":7}]}]}`, "text must be a string"},
		"bad assistant text": {`{"model":"claude","max_tokens":8,"messages":[{"role":"assistant","content":[{"type":"text","text":7},{"type":"tool_use","id":"toolu_a","name":"lookup","input":{}}]}]}`,
			"text must be a string"},
		"bad system text": {`{"model":"claude","max_tokens":8,"system":[{"type":"text","text":7}],"messages":[{"role":"user","content":"hi"}]}`, "text must be a string"},
		"scalar tool input": {`{"model":"claude","max_tokens":8,"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"toolu_a","name":"lookup","input":7}]}]}`,
			"input must be an object"},
		"array tool input": {`{"model":"claude","max_tokens":8,"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"toolu_a","name":"lookup","input":[]}]}]}`,
			"input must be an object"},
		"hosted tool type": {`{"model":"claude","max_tokens":8,"tools":[{"type":"web_search_20250305","name":"web_search","input_schema":{"type":"object"}}],"messages":[{"role":"user","content":"hi"}]}`,
			"web_search_20250305"},
		"numeric model": {`{"model":7,"max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`,
			"model must be a string"},
		"string max tokens": {`{"model":"claude","max_tokens":"8","messages":[{"role":"user","content":"hi"}]}`,
			"max_tokens must be an integer"},
		"fractional max tokens": {`{"model":"claude","max_tokens":8.5,"messages":[{"role":"user","content":"hi"}]}`,
			"max_tokens must be an integer"},
		"string stream": {`{"model":"claude","max_tokens":8,"stream":"true","messages":[{"role":"user","content":"hi"}]}`,
			"stream must be a boolean"},
		"string temperature": {`{"model":"claude","max_tokens":8,"temperature":"0.2","messages":[{"role":"user","content":"hi"}]}`,
			"temperature must be a number"},
		"string top_p": {`{"model":"claude","max_tokens":8,"top_p":"0.9","messages":[{"role":"user","content":"hi"}]}`,
			"top_p must be a number"},
		"scalar stop sequences": {`{"model":"claude","max_tokens":8,"stop_sequences":"STOP","messages":[{"role":"user","content":"hi"}]}`,
			"stop_sequences must be an array of strings"},
		"numeric stop sequence": {`{"model":"claude","max_tokens":8,"stop_sequences":[7],"messages":[{"role":"user","content":"hi"}]}`,
			"stop_sequences[0] must be a string"},
		"numeric tool choice type": {`{"model":"claude","max_tokens":8,"tool_choice":{"type":7},"messages":[{"role":"user","content":"hi"}]}`,
			"tool_choice.type must be a string"},
		"numeric tool choice name": {`{"model":"claude","max_tokens":8,"tool_choice":{"type":"tool","name":7},"messages":[{"role":"user","content":"hi"}]}`,
			"tool_choice.name must be a string"},
		"numeric tool description": {`{"model":"claude","max_tokens":8,"tools":[{"name":"lookup","description":7,"input_schema":{"type":"object"}}],"messages":[{"role":"user","content":"hi"}]}`,
			"tools[0].description must be a string"},
		"scalar tool schema": {`{"model":"claude","max_tokens":8,"tools":[{"name":"lookup","input_schema":"object"}],"messages":[{"role":"user","content":"hi"}]}`,
			"tools[0].input_schema must be an object"},
		"string tool_result is_error": {`{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","is_error":"true","content":"failed"}]}]}`,
			"messages[0].content[0].is_error must be a boolean"},
	} {
		t.Run(name, func(t *testing.T) {
			resp := postAnthropicMessages(t, h, key, tc.body, nil)
			if resp.Code != http.StatusBadRequest {
				t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			if !strings.Contains(resp.Body.String(), `"type":"error"`) || !strings.Contains(resp.Body.String(), tc.want) {
				t.Fatalf("unexpected Anthropic error body=%s want %q", resp.Body.String(), tc.want)
			}
			if !strings.Contains(resp.Body.String(), `"code":"unsupported_content_shape"`) || !strings.Contains(resp.Body.String(), `"retryable":false`) {
				t.Fatalf("error missing code/retryable metadata: %s", resp.Body.String())
			}
		})
	}
	if upstreamHits != 0 {
		t.Fatalf("unsupported request reached upstream %d times", upstreamHits)
	}
	snap := gatewaySettlementSnapshot(t, dbPath, "acct_anthropic_reject")
	if snap.usageRows != 0 || snap.settledRows != 0 || snap.activeRows != 0 {
		t.Fatalf("unsupported request touched settlement state: %+v", snap)
	}
}

func TestAnthropicMessagesAcceptsTextCacheControlAndZeroMaxTokens(t *testing.T) {
	var capturedBody map[string]any
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if err := json.NewDecoder(r.Body).Decode(&capturedBody); err != nil {
			t.Fatalf("decode upstream request: %v", err)
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_cache_control_zero",
			"object":"chat.completion",
			"created":1,
			"model":"claude",
			"usage":{"prompt_tokens":5,"completion_tokens":0,"total_tokens":5},
			"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_cache_control_zero")

	body := `{"model":"claude","max_tokens":0,"service_tier":"standard_only","tools":[{"name":"lookup","input_schema":{"type":"object"},"cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"hi","cache_control":{"type":"ephemeral"}}]}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := capturedBody["max_tokens"]; got != float64(0) {
		t.Fatalf("translated max_tokens=%v want 0", got)
	}
	if _, ok := capturedBody["service_tier"]; ok {
		t.Fatalf("translated request unexpectedly preserved Anthropic service_tier: %v", capturedBody)
	}
	tools := capturedBody["tools"].([]any)
	fn := tools[0].(map[string]any)["function"].(map[string]any)
	if fn["name"] != "lookup" {
		t.Fatalf("translated tool=%v want lookup", tools[0])
	}
	messages := capturedBody["messages"].([]any)
	if got := messages[0].(map[string]any)["content"]; got != "hi" {
		t.Fatalf("translated message content=%v want cache_control ignored and text preserved", got)
	}
}

func TestAnthropicMessagesRejectsMalformedToolResultBeforeReservation(t *testing.T) {
	var upstreamHits int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits++
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_bad_tool_result")

	for name, body := range map[string]string{
		"non-object array entry": `{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","content":["dropped"]}]}]}`,
		"missing text string":    `{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","content":[{"type":"text","text":7}]}]}]}`,
		"object content":         `{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","content":{"x":1}}]}]}`,
		"number content":         `{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","content":7}]}]}`,
		"bool content":           `{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","content":true}]}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			resp := postAnthropicMessages(t, h, key, body, nil)
			if resp.Code != http.StatusBadRequest {
				t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			if !strings.Contains(resp.Body.String(), `"code":"unsupported_content_shape"`) || !strings.Contains(resp.Body.String(), `"retryable":false`) {
				t.Fatalf("unexpected error body=%s", resp.Body.String())
			}
		})
	}
	if upstreamHits != 0 {
		t.Fatalf("malformed tool_result reached upstream %d times", upstreamHits)
	}
	snap := gatewaySettlementSnapshot(t, dbPath, "acct_anthropic_bad_tool_result")
	if snap.usageRows != 0 || snap.settledRows != 0 || snap.activeRows != 0 {
		t.Fatalf("malformed tool_result touched settlement state: %+v", snap)
	}
}

func TestAnthropicMessagesNonStreamingInvalidProviderResponseSettlesParsedUsage(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_bad_tool_args","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"toolu_bad","type":"function","function":{"name":"lookup","arguments":"[1,2]"}}]},"finish_reason":"tool_calls"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_bad_provider")

	body := `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d want 502 body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"type":"error"`) || !strings.Contains(resp.Body.String(), "invalid response") {
		t.Fatalf("unexpected error body=%s", resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"code":"invalid_provider_response"`) || !strings.Contains(resp.Body.String(), `"retryable":true`) {
		t.Fatalf("error missing provider retry metadata: %s", resp.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_bad_provider")
	if outcome != "invalid_provider_response" || source != "provider_reported" || completion != 7 || prompt != 5 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want invalid_provider_response/provider_reported/7/5", outcome, source, completion, prompt)
	}
}

func TestAnthropicMessagesNonStreamingRejectsToolFinishWithoutToolCalls(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_tool_finish_empty","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"done"},"finish_reason":"tool_calls"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_tool_finish_empty")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d want 502 body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"code":"invalid_provider_response"`) {
		t.Fatalf("unexpected error body=%s", resp.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_tool_finish_empty")
	if outcome != "invalid_provider_response" || source != "provider_reported" || completion != 7 || prompt != 5 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want invalid_provider_response/provider_reported/7/5", outcome, source, completion, prompt)
	}
}

func TestAnthropicMessagesNonStreamingToolArgumentsNullBecomesEmptyInput(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_null_args","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"toolu_null","type":"function","function":{"name":"lookup","arguments":"null"}}]},"finish_reason":"tool_calls"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_null_args")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var anth map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &anth); err != nil {
		t.Fatalf("anthropic response json: %v body=%s", err, resp.Body.String())
	}
	content := anth["content"].([]any)
	toolUse := content[0].(map[string]any)
	input, ok := toolUse["input"].(map[string]any)
	if !ok || input == nil || len(input) != 0 {
		t.Fatalf("tool_use input=%#v want empty object", toolUse["input"])
	}
}

func TestAnthropicMessagesNonStreamingLengthTakesPrecedenceOverToolUse(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_tool_length","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"toolu_len","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"mac\"}"}}]},"finish_reason":"length"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_tool_length")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var anth map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &anth); err != nil {
		t.Fatalf("anthropic response json: %v body=%s", err, resp.Body.String())
	}
	if anth["stop_reason"] != "max_tokens" {
		t.Fatalf("stop_reason=%v want max_tokens body=%s", anth["stop_reason"], resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"type":"tool_use"`) {
		t.Fatalf("tool_use block missing body=%s", resp.Body.String())
	}
}

func TestAnthropicMessagesNonStreamingContentFilterMapsToRefusal(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_content_filter","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":null,"refusal":"cannot comply"},"finish_reason":"content_filter"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_content_filter")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var anth map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &anth); err != nil {
		t.Fatalf("anthropic response json: %v body=%s", err, resp.Body.String())
	}
	if anth["stop_reason"] != "refusal" {
		t.Fatalf("stop_reason=%v want refusal body=%s", anth["stop_reason"], resp.Body.String())
	}
	content := anth["content"].([]any)
	text := content[0].(map[string]any)["text"]
	if text != "cannot comply" {
		t.Fatalf("refusal text=%v want visible refusal body=%s", text, resp.Body.String())
	}
}

func TestAnthropicMessagesNonStreamingInvalidProviderResponseIgnoresVerifiedFinalityDebit(t *testing.T) {
	finality := settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "verified", "valid", "true", "receipt_verified")
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_bad_verified","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"","unsupported_output":"hidden"},"finish_reason":"stop"}]}`
		h := http.Header{"Content-Type": []string{"application/json"}}
		for key, values := range finality {
			h[key] = values
		}
		return responseWithBody(http.StatusOK, h, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_bad_verified_finality")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d want 502 body=%s", resp.Code, resp.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_bad_verified_finality")
	if outcome != "invalid_provider_response" || source != "provider_reported" || completion != 7 || prompt != 5 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want invalid_provider_response/provider_reported/7/5", outcome, source, completion, prompt)
	}
	snap := gatewaySettlementSnapshot(t, dbPath, "acct_anthropic_bad_verified_finality")
	if snap.heldRows != 0 || snap.activeRows != 0 || snap.settledRows != 1 {
		t.Fatalf("settlement snapshot=%+v want settled invalid-provider row with no finality hold", snap)
	}
}

func TestAnthropicMessagesNonStreamingRejectsChoiceLessProviderError(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_error_200","model":"claude","usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"error":{"message":"provider failed","type":"api_error","code":"upstream_provider_error"}}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_200_error")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d want 502 body=%s", resp.Code, resp.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_200_error")
	if outcome != "invalid_provider_response" || source != "provider_reported" || completion != 7 || prompt != 5 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want invalid_provider_response/provider_reported/7/5", outcome, source, completion, prompt)
	}
}

func TestAnthropicMessagesNonStreamingDuplicateProviderKeysSettleParsedUsage(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_dup","object":"chat.completion","object":"chat.completion.chunk","model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"ambiguous"},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_dup_provider")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d want 502 body=%s", resp.Code, resp.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_dup_provider")
	if outcome != "invalid_provider_response" || source != "provider_reported" || completion != 7 || prompt != 5 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want invalid_provider_response/provider_reported/7/5", outcome, source, completion, prompt)
	}
}

func TestAnthropicMessagesNonStreamingProviderRefusalMapsToText(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_refusal","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":null,"refusal":"no"},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_refusal_provider")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var anth map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &anth); err != nil {
		t.Fatalf("anthropic response json: %v body=%s", err, resp.Body.String())
	}
	if anth["stop_reason"] != "refusal" {
		t.Fatalf("stop_reason=%v want refusal body=%s", anth["stop_reason"], resp.Body.String())
	}
	content := anth["content"].([]any)
	text := content[0].(map[string]any)["text"]
	if text != "no" {
		t.Fatalf("refusal text=%v want visible refusal body=%s", text, resp.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_refusal_provider")
	if outcome != "ok" || source != "provider_reported" || completion != 7 || prompt != 5 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want ok/provider_reported/7/5", outcome, source, completion, prompt)
	}
}

func TestAnthropicMessagesNonStreamingRejectsToolCallWithoutName(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_bad_tool_name","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"toolu_bad","type":"function","function":{"arguments":"{\"q\":\"mac\"}"}}]},"finish_reason":"tool_calls"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_bad_tool_name")

	body := `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d want 502 body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"code":"invalid_provider_response"`) || !strings.Contains(resp.Body.String(), `"retryable":true`) {
		t.Fatalf("unexpected error body=%s", resp.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_bad_tool_name")
	if outcome != "invalid_provider_response" || source != "provider_reported" || completion != 7 || prompt != 5 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want invalid_provider_response/provider_reported/7/5", outcome, source, completion, prompt)
	}
}

func TestAnthropicMessagesNonStreamingRejectsMissingOrDuplicateToolCallID(t *testing.T) {
	for name, providerBody := range map[string]string{
		"missing id": `{"id":"chatcmpl_bad_tool_id","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"type":"function","function":{"name":"lookup","arguments":"{\"q\":\"mac\"}"}}]},"finish_reason":"tool_calls"}]}`,
		"duplicate id": `{"id":"chatcmpl_dup_tool_id","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"toolu_dup","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"mac\"}"}},{"id":"toolu_dup","type":"function","function":{"name":"write","arguments":"{\"path\":\"/tmp/a\"}"}}]},"finish_reason":"tool_calls"}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, providerBody), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
				cfg.Features.AnthropicMessagesEnabled = true
			}, WithHTTPClient(client))
			accountID := "acct_anthropic_bad_tool_id_" + strings.ReplaceAll(name, " ", "_")
			key := createAccountAndKey(t, store, cfg, accountID)

			resp := postAnthropicMessages(t, h, key, `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, nil)
			if resp.Code != http.StatusBadGateway {
				t.Fatalf("status=%d want 502 body=%s", resp.Code, resp.Body.String())
			}
			outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID)
			if outcome != "invalid_provider_response" || source != "provider_reported" || completion != 7 || prompt != 5 {
				t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want invalid_provider_response/provider_reported/7/5", outcome, source, completion, prompt)
			}
		})
	}
}

func TestAnthropicMessagesToolResultErrorFlagReachesUpstreamAsText(t *testing.T) {
	var upstreamBody map[string]any
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if err := json.NewDecoder(r.Body).Decode(&upstreamBody); err != nil {
			t.Fatalf("decode upstream request: %v", err)
		}
		body := `{"id":"chatcmpl_tool_error","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_tool_error")

	body := `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","is_error":true,"content":"failed"}]}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	messages, _ := upstreamBody["messages"].([]any)
	if len(messages) != 1 || messages[0].(map[string]any)["role"] != "tool" || !strings.Contains(messages[0].(map[string]any)["content"].(string), "Tool error: failed") {
		t.Fatalf("tool_result is_error not preserved in upstream text: %v", upstreamBody["messages"])
	}
}

func TestAnthropicMessagesNonStreamingPreservesWhitespaceOnlyText(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_whitespace","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":" \n "},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_whitespace")

	body := `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var anth struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &anth); err != nil {
		t.Fatalf("decode response: %v body=%s", err, resp.Body.String())
	}
	if len(anth.Content) != 1 || anth.Content[0].Type != "text" || anth.Content[0].Text != " \n " {
		t.Fatalf("content=%+v want one preserved whitespace text block", anth.Content)
	}
}

func TestAnthropicMessagesNonStreamingStripsThinkBlocks(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_think","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"<think>hidden</think> visible <think>unterminated"},"finish_reason":"length"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_nonstream_think")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if strings.Contains(body, "hidden") || strings.Contains(body, "unterminated") || strings.Contains(body, "<think") {
		t.Fatalf("think block leaked into Anthropic response:\n%s", body)
	}
	if !strings.Contains(body, "visible") || !strings.Contains(body, `"stop_reason":"max_tokens"`) {
		t.Fatalf("visible answer or max_tokens terminal missing:\n%s", body)
	}
}

func TestAnthropicMessagesNonStreamingRejectsReasoningContentArray(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"id":"chatcmpl_reasoning_array","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":[{"type":"reasoning","text":"hidden chain of thought"},{"type":"text","text":"visible"}]},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_reasoning_array")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d want 502 body=%s", resp.Code, resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), "hidden chain of thought") || !strings.Contains(resp.Body.String(), `"code":"invalid_provider_response"`) {
		t.Fatalf("reasoning array content leaked or wrong error:\n%s", resp.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_reasoning_array")
	if outcome != "invalid_provider_response" || source != "provider_reported" || completion != 7 || prompt != 5 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want invalid_provider_response/provider_reported/7/5", outcome, source, completion, prompt)
	}
}

func TestAnthropicMessagesRejectsDemoTokenBeforeSharedChatAuth(t *testing.T) {
	var upstreamHits int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits++
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_demo_reject")

	body := `{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`
	for name, headers := range map[string]map[string]string{
		"demo only":        {"X-Demo-Token": "demo-token"},
		"bearer and demo":  {"X-Demo-Token": "demo-token", "Authorization": "Bearer " + key},
		"x-api-key demo":   {"X-Demo-Token": "demo-token", "X-Api-Key": key},
		"lowercase header": {"x-demo-token": "demo-token"},
	} {
		t.Run(name, func(t *testing.T) {
			resp := postAnthropicMessages(t, h, "", body, headers)
			if resp.Code != http.StatusUnauthorized {
				t.Fatalf("status=%d want 401 body=%s", resp.Code, resp.Body.String())
			}
			if !strings.Contains(resp.Body.String(), "X-Demo-Token is not supported") {
				t.Fatalf("unexpected body=%s", resp.Body.String())
			}
		})
	}
	if upstreamHits != 0 {
		t.Fatalf("demo-token requests reached upstream %d times", upstreamHits)
	}
	snap := gatewaySettlementSnapshot(t, dbPath, "acct_anthropic_demo_reject")
	if snap.usageRows != 0 || snap.settledRows != 0 || snap.activeRows != 0 {
		t.Fatalf("demo-token requests touched settlement state: %+v", snap)
	}
}

func TestAnthropicMessagesKillSwitchUsesAnthropicErrorShape(t *testing.T) {
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.KillSwitch.AllPublicAPI = true
		cfg.Features.AnthropicMessagesEnabled = true
	})

	resp := postAnthropicMessages(t, h, "", `{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503 body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"type":"error"`) || !strings.Contains(resp.Body.String(), `"code":"public_api_paused"`) || !strings.Contains(resp.Body.String(), `"retryable":true`) {
		t.Fatalf("unexpected Anthropic pause body=%s", resp.Body.String())
	}
}

func TestAnthropicMessagesStreamingEOFCompletesAnthropicMessage(t *testing.T) {
	stream := `data: {"id":"chatcmpl_eof","model":"claude-stream","choices":[{"delta":{"content":"done"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_eof","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_eof")

	body := `{"model":"claude-stream","max_tokens":128,"stream":true,"messages":[{"role":"user","content":"hi"}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	got := resp.Body.String()
	if strings.Count(got, "event: message_stop") != 1 {
		t.Fatalf("message_stop count=%d want 1\n%s", strings.Count(got, "event: message_stop"), got)
	}
	if !strings.Contains(got, `"stop_reason":"end_turn"`) || !strings.Contains(got, `"output_tokens":4`) {
		t.Fatalf("stream did not emit final message_delta with usage:\n%s", got)
	}
	start := anthropicStreamPayloadForEvent(t, got, "message_start")
	msg, _ := start["message"].(map[string]any)
	usage, _ := msg["usage"].(map[string]any)
	if usage["input_tokens"] == nil || usage["input_tokens"] == float64(0) {
		t.Fatalf("message_start usage=%v want nonzero input_tokens estimate\n%s", usage, got)
	}
}

func TestAnthropicMessagesStreamingIncludesMatchedStopSequence(t *testing.T) {
	stream := `data: {"id":"chatcmpl_stream_stopseq","model":"claude-stream","choices":[{"delta":{"content":"done"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_stream_stopseq","choices":[{"delta":{},"finish_reason":"stop_sequence","stop_sequence":"STOP"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_stop_sequence")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":16,"stream":true,"stop_sequences":["STOP"],"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	got := resp.Body.String()
	delta := anthropicStreamPayloadForEvent(t, got, "message_delta")
	payload, _ := delta["delta"].(map[string]any)
	if payload["stop_reason"] != "stop_sequence" || payload["stop_sequence"] != "STOP" {
		t.Fatalf("stream stop reason/sequence=%v/%v want stop_sequence/STOP\n%s", payload["stop_reason"], payload["stop_sequence"], got)
	}
}

func TestAnthropicMessagesStreamingInfersStopSequenceFromStopSuffix(t *testing.T) {
	stream := `data: {"id":"chatcmpl_stream_stop_suffix","model":"claude-stream","choices":[{"delta":{"content":"do"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_stream_stop_suffix","choices":[{"delta":{"content":"neST"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_stream_stop_suffix","choices":[{"delta":{"content":"OP"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_stop_suffix")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":16,"stream":true,"stop_sequences":["STOP"],"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	got := resp.Body.String()
	delta := anthropicStreamPayloadForEvent(t, got, "message_delta")
	payload, _ := delta["delta"].(map[string]any)
	if payload["stop_reason"] != "stop_sequence" || payload["stop_sequence"] != "STOP" {
		t.Fatalf("stream stop reason/sequence=%v/%v want stop_sequence/STOP\n%s", payload["stop_reason"], payload["stop_sequence"], got)
	}
	if text := strings.Join(anthropicTextDeltas(t, got), ""); text != "done" {
		t.Fatalf("stream text=%q want done\n%s", text, got)
	}
}

func TestAnthropicMessagesStreamingWithoutUsageReportsFallbackSettlementUsage(t *testing.T) {
	stream := `data: {"id":"chatcmpl_no_usage","model":"claude-stream","choices":[{"delta":{"content":"done"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_no_usage","choices":[{"delta":{},"finish_reason":"stop"}]}`
	stream += "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_no_usage")

	body := `{"model":"claude-stream","max_tokens":128,"stream":true,"messages":[{"role":"user","content":"hi"}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	got := resp.Body.String()
	delta := anthropicStreamPayloadForEvent(t, got, "message_delta")
	usage, _ := delta["usage"].(map[string]any)
	if usage["input_tokens"] == nil || usage["input_tokens"] == float64(0) || usage["output_tokens"] == nil || usage["output_tokens"] == float64(0) {
		t.Fatalf("message_delta usage=%v want nonzero fallback usage\n%s", usage, got)
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_no_usage")
	if outcome != "unverified_streaming" || source != "gateway_estimated" || completion <= 0 || prompt <= 0 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want unverified_streaming/gateway_estimated/nonzero", outcome, source, completion, prompt)
	}
	if usage["input_tokens"] != float64(prompt) || usage["output_tokens"] != float64(completion) {
		t.Fatalf("visible usage=%v settlement prompt/completion=%d/%d", usage, prompt, completion)
	}
}

func TestAnthropicMessagesStreamingDoneWithoutUsageReportsVisibleFallbackUsage(t *testing.T) {
	stream := `data: {"id":"chatcmpl_done_no_usage","model":"claude-stream","choices":[{"delta":{"content":"done"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_done_no_usage","choices":[{"delta":{},"finish_reason":"stop"}]}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_done_no_usage")

	body := `{"model":"claude-stream","max_tokens":128,"stream":true,"messages":[{"role":"user","content":"hi"}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	got := resp.Body.String()
	delta := anthropicStreamPayloadForEvent(t, got, "message_delta")
	usage, _ := delta["usage"].(map[string]any)
	if usage["input_tokens"] == nil || usage["input_tokens"] == float64(0) || usage["output_tokens"] == nil || usage["output_tokens"] == float64(0) {
		t.Fatalf("message_delta usage=%v want nonzero fallback usage before [DONE] stop\n%s", usage, got)
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_done_no_usage")
	if outcome != "unverified_streaming" || source != "gateway_estimated" || completion <= 0 || prompt <= 0 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want unverified_streaming/gateway_estimated/nonzero", outcome, source, completion, prompt)
	}
	if usage["input_tokens"] != float64(prompt) || usage["output_tokens"] != float64(completion) {
		t.Fatalf("visible usage=%v settlement prompt/completion=%d/%d", usage, prompt, completion)
	}
}

func TestAnthropicMessagesStreamingStripsThinkBlocks(t *testing.T) {
	stream := `data: {"id":"chatcmpl_stream_think","model":"claude-stream","choices":[{"delta":{"content":"<thi"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_stream_think","choices":[{"delta":{"content":"nk>hidden"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_stream_think","choices":[{"delta":{"content":"</think> visible <think>trailing"},"finish_reason":"length"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_think")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if strings.Contains(body, "hidden") || strings.Contains(body, "trailing") || strings.Contains(body, "<think") {
		t.Fatalf("think block leaked into Anthropic stream:\n%s", body)
	}
	if !strings.Contains(body, `"text":" visible "`) || !strings.Contains(body, `"stop_reason":"max_tokens"`) || !strings.Contains(body, "event: message_stop") {
		t.Fatalf("visible stream delta or max_tokens terminal missing:\n%s", body)
	}
}

func TestAnthropicMessagesStreamingTerminalOutputExceededEmitsMessageStop(t *testing.T) {
	stream := `data: {"id":"chatcmpl_stream_cap","model":"claude-stream","choices":[{"delta":{"content":"partial"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"error":{"message":"cap hit","type":"api_error","code":"stream_output_exceeded","retryable":true}}`
	stream += "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_output_exceeded_terminal")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":8,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if strings.Contains(body, "event: error") || strings.Contains(body, `"code":"stream_output_exceeded"`) {
		t.Fatalf("terminal output-exceeded frame emitted Anthropic error:\n%s", body)
	}
	if !strings.Contains(body, `"stop_reason":"max_tokens"`) || !strings.Contains(body, "event: message_stop") {
		t.Fatalf("terminal output-exceeded frame did not close as max_tokens:\n%s", body)
	}
	delta := anthropicStreamPayloadForEvent(t, body, "message_delta")
	usage, _ := delta["usage"].(map[string]any)
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_output_exceeded_terminal")
	if outcome != "stream_output_exceeded" || source != "gateway_estimated" || completion <= 0 || prompt <= 0 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want stream_output_exceeded/gateway_estimated/nonzero", outcome, source, completion, prompt)
	}
	if usage["input_tokens"] != float64(prompt) || usage["output_tokens"] != float64(completion) {
		t.Fatalf("visible usage=%v settlement prompt/completion=%d/%d", usage, prompt, completion)
	}
}

func TestAnthropicMessagesStreamingTerminalResponseByteCapExceededRetryReplays(t *testing.T) {
	var upstreamHits int
	stream := `data: {"id":"chatcmpl_stream_response_byte_cap","model":"claude-stream","choices":[{"delta":{"content":"partial"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"error":{"message":"cap hit","type":"api_error","code":"response_byte_cap_exceeded","retryable":true}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits++
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_response_byte_cap_replay")

	body := `{"model":"claude-stream","max_tokens":8,"stream":true,"messages":[{"role":"user","content":"hi"}]}`
	first := postAnthropicMessages(t, h, key, body, nil)
	second := postAnthropicMessages(t, h, key, body, nil)
	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("codes first=%d second=%d bodies:\n%s\n%s", first.Code, second.Code, first.Body.String(), second.Body.String())
	}
	if second.Header().Get(idlessDedupeHeader) != idlessDedupeHeaderValue {
		t.Fatalf("second response did not replay; header=%q body=%s", second.Header().Get(idlessDedupeHeader), second.Body.String())
	}
	if upstreamHits != 1 {
		t.Fatalf("upstream hits=%d want 1", upstreamHits)
	}
	if first.Body.String() != second.Body.String() {
		t.Fatalf("replayed byte-cap stream differs:\nfirst=%s\nsecond=%s", first.Body.String(), second.Body.String())
	}
	if strings.Contains(second.Body.String(), "event: error") || strings.Contains(second.Body.String(), `"code":"response_byte_cap_exceeded"`) ||
		!strings.Contains(second.Body.String(), `"stop_reason":"max_tokens"`) || !strings.Contains(second.Body.String(), "event: message_stop") {
		t.Fatalf("replayed byte-cap stream was not a clean max_tokens terminal:\n%s", second.Body.String())
	}
	snap := gatewaySettlementSnapshot(t, dbPath, "acct_anthropic_response_byte_cap_replay")
	if snap.usageRows != 1 || snap.settledRows != 1 || snap.refundedRows != 0 || snap.activeRows != 0 {
		t.Fatalf("settlement snapshot=%+v want one settled usage row and no refund", snap)
	}
}

func TestAnthropicMessagesStreamingTerminalTruncatedEmitsError(t *testing.T) {
	stream := `data: {"id":"chatcmpl_stream_truncated_terminal","model":"claude-stream","choices":[{"delta":{"content":"partial"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"error":{"message":"line too large","type":"api_error","code":"stream_truncated","retryable":true}}`
	stream += "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_truncated_terminal")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":8,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"stream_truncated"`) || !strings.Contains(body, "event: message_stop") {
		t.Fatalf("stream_truncated terminal did not emit Anthropic error + close:\n%s", body)
	}
	if strings.Contains(body, `"stop_reason":"max_tokens"`) {
		t.Fatalf("stream_truncated terminal was misclassified as max_tokens:\n%s", body)
	}
	outcome, source, _, _ := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_truncated_terminal")
	if outcome != "stream_truncated" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source=%s/%s want stream_truncated/gateway_estimated", outcome, source)
	}
}

func TestAnthropicMessagesStreamingGatewayOutputExceededRetryReplays(t *testing.T) {
	var upstreamHits int
	stream := `data: {"id":"chatcmpl_gateway_cap","model":"claude-stream","choices":[{"delta":{"content":"visible "},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_gateway_cap","choices":[{"delta":{"content":"overflow"},"finish_reason":null}]}`
	stream += "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits++
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_gateway_cap_replay")

	body := `{"model":"claude-stream","max_tokens":1,"stream":true,"messages":[{"role":"user","content":"hi"}]}`
	first := postAnthropicMessages(t, h, key, body, nil)
	second := postAnthropicMessages(t, h, key, body, nil)
	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("codes first=%d second=%d bodies:\n%s\n%s", first.Code, second.Code, first.Body.String(), second.Body.String())
	}
	if second.Header().Get("X-MacProvider-Dedupe") != "replay" {
		t.Fatalf("second response did not replay; header=%q body=%s", second.Header().Get("X-MacProvider-Dedupe"), second.Body.String())
	}
	if upstreamHits != 1 {
		t.Fatalf("upstream hits=%d want 1", upstreamHits)
	}
	if first.Body.String() != second.Body.String() {
		t.Fatalf("replayed cap stream differs:\nfirst=%s\nsecond=%s", first.Body.String(), second.Body.String())
	}
	if strings.Contains(second.Body.String(), "event: error") || !strings.Contains(second.Body.String(), `"stop_reason":"max_tokens"`) || !strings.Contains(second.Body.String(), "event: message_stop") {
		t.Fatalf("replayed cap stream was not a clean max_tokens terminal:\n%s", second.Body.String())
	}
	delta := anthropicStreamPayloadForEvent(t, second.Body.String(), "message_delta")
	usage, _ := delta["usage"].(map[string]any)
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_gateway_cap_replay")
	if outcome != "stream_output_exceeded" || source != "gateway_estimated" || completion <= 0 || prompt <= 0 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want stream_output_exceeded/gateway_estimated/nonzero", outcome, source, completion, prompt)
	}
	if usage["output_tokens"] != float64(completion) || usage["output_tokens"] == float64(0) {
		t.Fatalf("visible usage=%v settlement completion=%d want nonzero match", usage, completion)
	}
	snap := gatewaySettlementSnapshot(t, dbPath, "acct_anthropic_gateway_cap_replay")
	if snap.usageRows != 1 || snap.settledRows != 1 || snap.activeRows != 0 {
		t.Fatalf("settlement snapshot=%+v want one settled usage row", snap)
	}
}

func TestAnthropicMessagesStreamingContentFilterMapsToRefusal(t *testing.T) {
	stream := `data: {"id":"chatcmpl_stream_content_filter","model":"claude-stream","choices":[{"delta":{"content":"cannot comply"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_stream_content_filter","choices":[{"delta":{},"finish_reason":"content_filter"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_content_filter")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":8,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if strings.Contains(body, "event: error") || !strings.Contains(body, `"stop_reason":"refusal"`) || !strings.Contains(body, "event: message_stop") {
		t.Fatalf("content_filter stream did not close as refusal:\n%s", body)
	}
}

func TestAnthropicMessagesStreamingUnknownTerminalErrorSettlesInvalidProviderResponse(t *testing.T) {
	stream := `data: {"id":"chatcmpl_unknown_terminal","model":"claude-stream","choices":[{"delta":{"content":"partial"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"error":{"message":"provider failed","type":"api_error","code":"upstream_provider_error","retryable":true}}`
	stream += "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_unknown_terminal")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":8,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"upstream_provider_error"`) || !strings.Contains(body, `"stop_reason":"end_turn"`) || !strings.Contains(body, "event: message_stop") {
		t.Fatalf("unknown terminal error did not close Anthropic stream:\n%s", body)
	}
	outcome, source, _, _ := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_unknown_terminal")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source=%s/%s want invalid_provider_response/gateway_estimated", outcome, source)
	}
}

func TestAnthropicMessagesStreamingEOFWithoutFinishReasonFailsClosedWithMessageStop(t *testing.T) {
	stream := `data: {"id":"chatcmpl_truncated","model":"claude-stream","choices":[{"delta":{"content":"partial"},"finish_reason":null}]}`
	stream += "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_truncated")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"invalid_provider_response"`) || !strings.Contains(body, "event: message_stop") {
		t.Fatalf("truncated stream did not emit Anthropic error terminal:\n%s", body)
	}
	outcome, source, _, _ := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_truncated")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source=%s/%s want invalid_provider_response/gateway_estimated", outcome, source)
	}
}

func TestAnthropicMessagesStreamingEOFIdlessReplayReturnsCompleteAnthropicBody(t *testing.T) {
	var upstreamHits int
	stream := `data: {"id":"chatcmpl_eof_replay","model":"claude-stream","choices":[{"delta":{"content":"done"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_eof_replay","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits++
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_eof_replay")

	body := `{"model":"claude-stream","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"hi"}]}`
	first := postAnthropicMessages(t, h, key, body, nil)
	second := postAnthropicMessages(t, h, key, body, nil)
	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("codes first=%d second=%d bodies:\n%s\n%s", first.Code, second.Code, first.Body.String(), second.Body.String())
	}
	if second.Header().Get("X-MacProvider-Dedupe") != "replay" {
		t.Fatalf("second response did not replay; header=%q", second.Header().Get("X-MacProvider-Dedupe"))
	}
	if upstreamHits != 1 {
		t.Fatalf("upstream hits=%d want 1", upstreamHits)
	}
	if first.Body.String() != second.Body.String() {
		t.Fatalf("replayed EOF stream differs:\nfirst=%s\nsecond=%s", first.Body.String(), second.Body.String())
	}
	if !strings.Contains(second.Body.String(), "event: message_stop") || !strings.Contains(second.Body.String(), `"type":"message_delta"`) {
		t.Fatalf("replay did not include synthesized terminal Anthropic events:\n%s", second.Body.String())
	}
}

func TestAnthropicMessagesStreamingTranslatesEventsAndSettles(t *testing.T) {
	stream := `data: {"id":"chatcmpl_stream","model":"claude-stream","choices":[{"delta":{"content":"hi"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"toolu_1","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"mac\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			t.Fatalf("upstream path=%s want chat completions", r.URL.Path)
		}
		var upstream map[string]any
		if err := json.NewDecoder(r.Body).Decode(&upstream); err != nil {
			t.Fatalf("decode upstream request: %v", err)
		}
		if upstream["stream"] != true {
			t.Fatalf("translated stream=%v want true", upstream["stream"])
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream")

	body := `{"model":"claude-stream","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"hi"}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	got := resp.Body.String()
	for _, want := range []string{
		"event: message_start",
		"event: content_block_start",
		`"type":"text_delta"`,
		`"text":"hi"`,
		`"type":"input_json_delta"`,
		`"partial_json":"{\"q\":\"mac\"}"`,
		`"stop_reason":"tool_use"`,
		"event: message_stop",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("stream missing %q\n%s", want, got)
		}
	}
	snap := gatewaySettlementSnapshot(t, dbPath, "acct_anthropic_stream")
	if snap.usageRows != 1 || snap.settledRows != 1 {
		t.Fatalf("settlement snapshot=%+v want one settled usage row", snap)
	}
}

func TestAnthropicMessagesStreamingLengthTakesPrecedenceOverToolUse(t *testing.T) {
	stream := `data: {"id":"chatcmpl_stream_tool_length","model":"claude-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"toolu_len","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"mac\"}"}}]},"finish_reason":"length"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_tool_length")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if !strings.Contains(body, `"stop_reason":"max_tokens"`) || strings.Contains(body, `"stop_reason":"tool_use"`) {
		t.Fatalf("length finish did not take precedence over tool_use:\n%s", body)
	}
	if !strings.Contains(body, `"type":"tool_use"`) || !strings.Contains(body, "event: message_stop") {
		t.Fatalf("tool_use block or terminal missing:\n%s", body)
	}
}

func TestAnthropicMessagesStreamingAllowsEmptyInitialToolArguments(t *testing.T) {
	stream := `data: {"id":"chatcmpl_empty_args","model":"claude-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"toolu_empty","type":"function","function":{"name":"lookup","arguments":""}}]},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_empty_args","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"q\":\"mac\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_empty_initial_tool_args")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if strings.Contains(body, "event: error") || strings.Contains(body, `"code":"invalid_provider_response"`) {
		t.Fatalf("empty initial tool arguments were rejected:\n%s", body)
	}
	if !strings.Contains(body, `"type":"tool_use"`) || !strings.Contains(body, `"partial_json":"{\"q\":\"mac\"}"`) || !strings.Contains(body, `"stop_reason":"tool_use"`) {
		t.Fatalf("tool stream missing expected Anthropic events:\n%s", body)
	}
}

func TestAnthropicMessagesStreamingKeepsStableIndexesForMultipleToolCalls(t *testing.T) {
	stream := `data: {"id":"chatcmpl_multi_tools","model":"claude-stream","choices":[{"delta":{"tool_calls":[` +
		`{"index":0,"id":"toolu_a","type":"function","function":{"name":"lookup"}},` +
		`{"index":1,"id":"toolu_b","type":"function","function":{"name":"write"}}]},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_multi_tools","choices":[{"delta":{"tool_calls":[` +
		`{"index":0,"function":{"arguments":"{\"q\":\"mac\"}"}},` +
		`{"index":1,"function":{"arguments":"{\"path\":\"/tmp/a\"}"}}]},"finish_reason":"tool_calls"}],` +
		`"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_multi_tool_stream")

	body := `{"model":"claude-stream","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"hi"}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	deltas := anthropicInputJSONDeltasByPartial(t, resp.Body.String())
	if deltas[`{"q":"mac"}`] != 0 {
		t.Fatalf("first tool delta index=%d want 0\n%s", deltas[`{"q":"mac"}`], resp.Body.String())
	}
	if deltas[`{"path":"/tmp/a"}`] != 1 {
		t.Fatalf("second tool delta index=%d want 1\n%s", deltas[`{"path":"/tmp/a"}`], resp.Body.String())
	}
}

func TestAnthropicMessagesStreamingBuffersToolCallUntilNameArrives(t *testing.T) {
	stream := `data: {"id":"chatcmpl_split_tool","model":"claude-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"toolu_split","type":"function"}]},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_split_tool","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"q\":"}}]},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_split_tool","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"lookup"}}]},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_split_tool","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"mac\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_split_tool_stream")

	body := `{"model":"claude-stream","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"hi"}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	got := resp.Body.String()
	if strings.Contains(got, `"name":""`) {
		t.Fatalf("tool block opened before name arrived:\n%s", got)
	}
	if !strings.Contains(got, `"name":"lookup"`) || !strings.Contains(got, `"partial_json":"{\"q\":"`) || !strings.Contains(got, `"partial_json":"\"mac\"}"`) {
		t.Fatalf("split tool call did not flush named block and buffered arguments:\n%s", got)
	}
}

func TestAnthropicMessagesStreamingRejectsLegacyFunctionCallDelta(t *testing.T) {
	stream := `data: {"id":"chatcmpl_function_call","model":"claude-stream","choices":[{"delta":{"function_call":{"name":"lookup","arguments":"{\"q\":\"mac\"}"}},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_function_call")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"invalid_provider_response"`) {
		t.Fatalf("legacy function_call stream did not fail closed:\n%s", body)
	}
	outcome, source, _, _ := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_function_call")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source=%s/%s want invalid_provider_response/gateway_estimated", outcome, source)
	}
}

func TestAnthropicMessagesStreamingRejectsToolFinishWithoutToolCalls(t *testing.T) {
	stream := `data: {"id":"chatcmpl_stream_tool_finish_empty","model":"claude-stream","choices":[{"delta":{"content":"done"},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_tool_finish_empty")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"invalid_provider_response"`) {
		t.Fatalf("tool_calls finish without tool calls did not fail closed:\n%s", body)
	}
	outcome, source, _, _ := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_tool_finish_empty")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source=%s/%s want invalid_provider_response/gateway_estimated", outcome, source)
	}
}

func TestAnthropicMessagesStreamingRejectsIncompleteToolCall(t *testing.T) {
	stream := `data: {"id":"chatcmpl_incomplete_tool","model":"claude-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"toolu_incomplete","type":"function","function":{"arguments":"{\"q\":\"mac\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_incomplete_tool")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"invalid_provider_response"`) {
		t.Fatalf("incomplete tool stream did not fail closed:\n%s", body)
	}
	outcome, source, _, _ := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_incomplete_tool")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source=%s/%s want invalid_provider_response/gateway_estimated", outcome, source)
	}
}

func TestAnthropicMessagesStreamingRejectsInvalidToolArguments(t *testing.T) {
	stream := `data: {"id":"chatcmpl_bad_tool_json","model":"claude-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"toolu_bad_json","type":"function","function":{"name":"lookup","arguments":"[1,2]"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_bad_tool_json")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"invalid_provider_response"`) {
		t.Fatalf("invalid tool JSON stream did not fail closed:\n%s", body)
	}
	outcome, source, _, _ := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_bad_tool_json")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source=%s/%s want invalid_provider_response/gateway_estimated", outcome, source)
	}
}

func TestAnthropicMessagesStreamingRejectsMissingDuplicateOrChangedToolID(t *testing.T) {
	for name, stream := range map[string]string{
		"missing id":   `data: {"id":"chatcmpl_missing_stream_id","model":"claude-stream","choices":[{"delta":{"tool_calls":[{"index":0,"type":"function","function":{"name":"lookup","arguments":"{\"q\":\"mac\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}` + "\n\ndata: [DONE]\n\n",
		"duplicate id": `data: {"id":"chatcmpl_dup_stream_id","model":"claude-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"toolu_dup","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"mac\"}"}},{"index":1,"id":"toolu_dup","type":"function","function":{"name":"write","arguments":"{\"path\":\"/tmp/a\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}` + "\n\ndata: [DONE]\n\n",
		"changed id before open": `data: {"id":"chatcmpl_change_stream_id","model":"claude-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"toolu_a","type":"function","function":{"arguments":"{\"q\":"}}]},"finish_reason":null}]}` +
			"\n\n" + `data: {"id":"chatcmpl_change_stream_id","choices":[{"delta":{"tool_calls":[{"index":0,"id":"toolu_b","function":{"name":"lookup","arguments":"\"mac\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}` +
			"\n\ndata: [DONE]\n\n",
	} {
		t.Run(name, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
				cfg.Features.AnthropicMessagesEnabled = true
			}, WithHTTPClient(client))
			accountID := "acct_anthropic_stream_tool_id_" + strings.ReplaceAll(name, " ", "_")
			key := createAccountAndKey(t, store, cfg, accountID)

			resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
			body := resp.Body.String()
			if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"invalid_provider_response"`) {
				t.Fatalf("tool id stream did not fail closed:\n%s", body)
			}
			outcome, source, _, _ := usageEventOutcomeAndTokens(t, dbPath, accountID)
			if outcome != "invalid_provider_response" || source != "gateway_estimated" {
				t.Fatalf("usage outcome/source=%s/%s want invalid_provider_response/gateway_estimated", outcome, source)
			}
		})
	}
}

func TestAnthropicMessagesStreamingTerminalErrorRefundsInsteadOfSettling(t *testing.T) {
	stream := `data: {"error":{"message":"timeout","type":"api_error","code":"provider_timeout","retryable":true}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_terminal_error")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"provider_timeout"`) {
		t.Fatalf("terminal error not translated:\n%s", body)
	}
	if !strings.Contains(body, "event: message_stop") {
		t.Fatalf("terminal error did not close Anthropic stream:\n%s", body)
	}
	snap := gatewaySettlementSnapshot(t, dbPath, "acct_anthropic_stream_terminal_error")
	if snap.usageRows != 0 || snap.settledRows != 0 || snap.activeRows != 0 {
		t.Fatalf("terminal stream error touched settlement state: %+v", snap)
	}
}

func TestAnthropicMessagesStreamingRefusalMapsToText(t *testing.T) {
	stream := `data: {"id":"chatcmpl_refusal","model":"claude-stream","choices":[{"delta":{"refusal":"no"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_refusal")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, body)
	}
	if strings.Contains(body, "event: error") || !strings.Contains(body, `"text":"no"`) || !strings.Contains(body, `"stop_reason":"refusal"`) || !strings.Contains(body, "event: message_stop") {
		t.Fatalf("refusal stream did not translate to visible refusal terminal:\n%s", body)
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_refusal")
	if outcome != "unverified_streaming" || source != "provider_reported" || completion != 4 || prompt != 3 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want unverified_streaming/provider_reported/4/3", outcome, source, completion, prompt)
	}
}

func TestAnthropicMessagesStreamingInvalidProviderResponseIgnoresVerifiedFinalityDebit(t *testing.T) {
	stream := `data: {"id":"chatcmpl_refusal_verified","model":"claude-stream","choices":[{"delta":{"unsupported_output":"no"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		h := http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}
		h.Set("Trailer", strings.Join(settlementFinalityHeaderNamesForTest(), ", "))
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     h,
			Body:       io.NopCloser(strings.NewReader(stream)),
			Trailer:    settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "verified", "valid", "true", "receipt_verified"),
		}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_bad_verified_finality")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "event: error") || !strings.Contains(resp.Body.String(), `"code":"invalid_provider_response"`) {
		t.Fatalf("stream did not fail closed:\n%s", resp.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_bad_verified_finality")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" || completion != 0 || prompt <= 0 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want invalid_provider_response/gateway_estimated/0/nonzero", outcome, source, completion, prompt)
	}
	snap := gatewaySettlementSnapshot(t, dbPath, "acct_anthropic_stream_bad_verified_finality")
	if snap.heldRows != 0 || snap.activeRows != 0 || snap.settledRows != 1 {
		t.Fatalf("settlement snapshot=%+v want settled invalid-provider row with no finality hold", snap)
	}
}

func TestAnthropicMessagesStreamingRejectsContentAfterFinishReason(t *testing.T) {
	stream := `data: {"id":"chatcmpl_after_finish","model":"claude-stream","choices":[{"delta":{},"finish_reason":"stop"}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_after_finish","choices":[{"delta":{"content":"late"},"finish_reason":null}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_after_finish")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"invalid_provider_response"`) {
		t.Fatalf("post-finish content stream did not fail closed:\n%s", body)
	}
	outcome, source, _, _ := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_after_finish")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source=%s/%s want invalid_provider_response/gateway_estimated", outcome, source)
	}
}

func TestAnthropicMessagesStreamingRejectsDuplicateKeyChunk(t *testing.T) {
	stream := `data: {"id":"chatcmpl_dup_stream","model":"claude-stream","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}],"choices":[{"delta":{"content":"hidden"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_dup_key")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"invalid_provider_response"`) {
		t.Fatalf("duplicate-key stream did not fail closed:\n%s", body)
	}
	outcome, source, _, _ := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_dup_key")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source=%s/%s want invalid_provider_response/gateway_estimated", outcome, source)
	}
}

func TestAnthropicMessagesStreamingRejectsMultipleChoices(t *testing.T) {
	stream := `data: {"id":"chatcmpl_multi_choice","model":"claude-stream","choices":[{"delta":{"content":"visible"},"finish_reason":"stop"},{"delta":{"content":"hidden"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_multi_choice")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"invalid_provider_response"`) {
		t.Fatalf("multi-choice stream did not fail closed:\n%s", body)
	}
	outcome, source, _, _ := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_multi_choice")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source=%s/%s want invalid_provider_response/gateway_estimated", outcome, source)
	}
}

func TestAnthropicMessagesStreamingRejectsLateToolDeltaAfterBlockStop(t *testing.T) {
	stream := `data: {"id":"chatcmpl_late_tool","model":"claude-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"toolu_late","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"mac\"}"}}]},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_late_tool","choices":[{"delta":{"content":"after tool"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_late_tool","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" "}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_late_tool")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if !strings.Contains(body, "event: error") || !strings.Contains(body, `"code":"invalid_provider_response"`) {
		t.Fatalf("late tool delta stream did not fail closed:\n%s", body)
	}
	outcome, source, _, _ := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_late_tool")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source=%s/%s want invalid_provider_response/gateway_estimated", outcome, source)
	}
}

func TestAnthropicMessagesStreamingDoneIgnoresPostTerminalFrames(t *testing.T) {
	stream := `data: {"id":"chatcmpl_done","model":"claude-stream","choices":[{"delta":{"content":"ok"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":"chatcmpl_done","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	stream += `data: {"id":"chatcmpl_done","choices":[{"delta":{"content":"hidden"},"finish_reason":"stop"}],"usage":{"prompt_tokens":30,"completion_tokens":40,"total_tokens":70}}`
	stream += "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_stream_done")

	resp := postAnthropicMessages(t, h, key, `{"model":"claude-stream","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if strings.Contains(body, "hidden") || !strings.Contains(body, "event: message_stop") {
		t.Fatalf("post-terminal frames affected Anthropic response:\n%s", body)
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_stream_done")
	if outcome != "unverified_streaming" || source != "provider_reported" || completion != 4 || prompt != 3 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want unverified_streaming/provider_reported/4/3", outcome, source, completion, prompt)
	}
}

func TestAnthropicMessagesStreamingRejectsMixedErrorFrame(t *testing.T) {
	stream := `data: {"id":123,"model":"claude-stream","error":{"message":"ignore mixed error","type":"api_error","code":"upstream_provider_error"},"choices":[{"delta":{"content":"ok"},"finish_reason":null}]}`
	stream += "\n\n" + `data: {"id":123,"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
	stream += "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_mixed_error")

	body := `{"model":"claude-stream","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"hi"}]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "event: error") || !strings.Contains(resp.Body.String(), `"code":"invalid_provider_response"`) {
		t.Fatalf("mixed error frame did not fail closed:\n%s", resp.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_anthropic_mixed_error")
	if outcome != "invalid_provider_response" || source != "gateway_estimated" || completion < 0 || prompt <= 0 {
		t.Fatalf("usage outcome/source/completion/prompt=%s/%s/%d/%d want invalid_provider_response/gateway_estimated/nonnegative/nonzero", outcome, source, completion, prompt)
	}
}

func TestAnthropicMessagesIdlessReplayReturnsAnthropicBody(t *testing.T) {
	var upstreamHits int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits++
		body := `{"id":"chatcmpl_replay","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"cached"},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_replay")

	body := `{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`
	first := postAnthropicMessages(t, h, key, body, nil)
	second := postAnthropicMessages(t, h, key, body, nil)
	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("codes first=%d second=%d bodies:\n%s\n%s", first.Code, second.Code, first.Body.String(), second.Body.String())
	}
	if second.Header().Get("X-MacProvider-Dedupe") != "replay" {
		t.Fatalf("second response did not replay; header=%q", second.Header().Get("X-MacProvider-Dedupe"))
	}
	if upstreamHits != 1 {
		t.Fatalf("upstream hits=%d want 1", upstreamHits)
	}
	if first.Body.String() != second.Body.String() {
		t.Fatalf("replayed transformed body differs:\nfirst=%s\nsecond=%s", first.Body.String(), second.Body.String())
	}
	if strings.Contains(second.Body.String(), "chat.completion") || !strings.Contains(second.Body.String(), `"type":"message"`) {
		t.Fatalf("replay cached OpenAI-shaped body instead of Anthropic body: %s", second.Body.String())
	}
}

func TestAnthropicMessagesIdlessDedupeUsesOriginalRequestBody(t *testing.T) {
	var upstreamHits int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits++
		body := `{"id":"chatcmpl_original_body","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_original_body_dedupe")

	firstBody := `{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","is_error":true,"content":"failed"}]}]}`
	secondBody := `{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","content":"Tool error: failed"}]}]}`
	first := postAnthropicMessages(t, h, key, firstBody, nil)
	second := postAnthropicMessages(t, h, key, secondBody, nil)
	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("codes first=%d second=%d bodies:\n%s\n%s", first.Code, second.Code, first.Body.String(), second.Body.String())
	}
	if second.Header().Get("X-MacProvider-Dedupe") == "replay" {
		t.Fatalf("second response replayed despite distinct original Anthropic request body")
	}
	if upstreamHits != 2 {
		t.Fatalf("upstream hits=%d want 2", upstreamHits)
	}
}

func TestAnthropicMessagesIdlessBodylessFallbackErrorIsAnthropicShaped(t *testing.T) {
	large := strings.Repeat("x", idlessDedupeMaxEntryBytes+1024)
	var upstreamHits int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits++
		body := `{"id":"chatcmpl_large_replay","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":` + strconv.Quote(large) + `},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_bodyless_replay")

	body := `{"model":"claude","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`
	first := postAnthropicMessages(t, h, key, body, nil)
	second := postAnthropicMessages(t, h, key, body, nil)
	if first.Code != http.StatusOK {
		firstBody := first.Body.String()
		if len(firstBody) > 256 {
			firstBody = firstBody[:256]
		}
		t.Fatalf("first status=%d body prefix=%q", first.Code, firstBody)
	}
	if second.Code != http.StatusConflict {
		t.Fatalf("second status=%d want 409 body=%s", second.Code, second.Body.String())
	}
	if !strings.Contains(second.Body.String(), `"type":"error"`) || !strings.Contains(second.Body.String(), `"code":"duplicate_request_id"`) {
		t.Fatalf("bodyless fallback did not use Anthropic error shape: %s", second.Body.String())
	}
	if upstreamHits != 1 {
		t.Fatalf("upstream hits=%d want 1", upstreamHits)
	}
}

func TestAnthropicMessagesSettlementDisclosureIsFlagScoped(t *testing.T) {
	base := makeVerifiedModelSettlementDisclosure(false, false)
	if containsString(base.IncludedPaidEntrypoints, "POST /v1/messages") {
		t.Fatalf("base disclosure unexpectedly includes /v1/messages: %+v", base.IncludedPaidEntrypoints)
	}
	enabled := makeVerifiedModelSettlementDisclosure(false, true)
	if !containsString(enabled.IncludedPaidEntrypoints, "POST /v1/messages") {
		t.Fatalf("enabled disclosure missing /v1/messages: %+v", enabled.IncludedPaidEntrypoints)
	}
}

func postAnthropicMessages(t *testing.T, h http.Handler, bearer, body string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/messages", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	return resp
}

func assertChatRequestField(t *testing.T, body map[string]any, field string, want any) {
	t.Helper()
	if got := body[field]; got != want {
		t.Fatalf("translated %s=%v want %v in body=%v", field, got, want, body)
	}
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func anthropicInputJSONDeltasByPartial(t *testing.T, stream string) map[string]int {
	t.Helper()
	out := map[string]int{}
	for _, line := range strings.Split(stream, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data: ") || !strings.Contains(line, `"input_json_delta"`) {
			continue
		}
		var payload struct {
			Index int `json:"index"`
			Delta struct {
				Type        string `json:"type"`
				PartialJSON string `json:"partial_json"`
			} `json:"delta"`
		}
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &payload); err != nil {
			t.Fatalf("decode delta payload %q: %v", line, err)
		}
		if payload.Delta.Type == "input_json_delta" {
			out[payload.Delta.PartialJSON] = payload.Index
		}
	}
	return out
}

func anthropicTextDeltas(t *testing.T, stream string) []string {
	t.Helper()
	var out []string
	for _, line := range strings.Split(stream, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data: ") || !strings.Contains(line, `"text_delta"`) {
			continue
		}
		var payload struct {
			Delta struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"delta"`
		}
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &payload); err != nil {
			t.Fatalf("decode text delta payload %q: %v", line, err)
		}
		if payload.Delta.Type == "text_delta" {
			out = append(out, payload.Delta.Text)
		}
	}
	return out
}

func anthropicStreamPayloadForEvent(t *testing.T, stream, event string) map[string]any {
	t.Helper()
	lines := strings.Split(stream, "\n")
	for i, line := range lines {
		if strings.TrimSpace(line) != "event: "+event {
			continue
		}
		if i+1 >= len(lines) || !strings.HasPrefix(strings.TrimSpace(lines[i+1]), "data: ") {
			t.Fatalf("event %q missing data line in stream:\n%s", event, stream)
		}
		var payload map[string]any
		raw := strings.TrimPrefix(strings.TrimSpace(lines[i+1]), "data: ")
		if err := json.Unmarshal([]byte(raw), &payload); err != nil {
			t.Fatalf("decode %q payload: %v raw=%s", event, err, raw)
		}
		return payload
	}
	t.Fatalf("event %q not found in stream:\n%s", event, stream)
	return nil
}

func TestAnthropicMessagesToolResultRequestTranslation(t *testing.T) {
	var upstreamBody map[string]any
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		raw, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read upstream body: %v", err)
		}
		if err := json.Unmarshal(raw, &upstreamBody); err != nil {
			t.Fatalf("decode upstream body: %v raw=%s", err, string(raw))
		}
		body := `{"id":"chatcmpl_tools","object":"chat.completion","created":1,"model":"claude",` +
			`"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6},` +
			`"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_anthropic_tools")

	body := `{"model":"claude","max_tokens":16,"messages":[
		{"role":"assistant","content":[{"type":"tool_use","id":"toolu_a","name":"lookup","input":{"q":"mac"}}]},
		{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","content":[{"type":"text","text":"result"}]}]}
	]}`
	resp := postAnthropicMessages(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	messages, _ := upstreamBody["messages"].([]any)
	if len(messages) != 2 {
		t.Fatalf("translated messages=%v want assistant+tool", upstreamBody["messages"])
	}
	assistant := messages[0].(map[string]any)
	toolCalls := assistant["tool_calls"].([]any)
	if assistant["role"] != "assistant" || toolCalls[0].(map[string]any)["id"] != "toolu_a" {
		t.Fatalf("assistant tool_use translation wrong: %v", assistant)
	}
	tool := messages[1].(map[string]any)
	if tool["role"] != "tool" || tool["tool_call_id"] != "toolu_a" || tool["content"] != "result" {
		t.Fatalf("tool_result translation wrong: %v", tool)
	}
}
