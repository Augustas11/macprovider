package router

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// #2107 D9: Responses `custom` tools are served as a function with one string
// argument, their history items round-trip, hosted tools are named in a
// header, and local_shell is refused.
func TestResponsesCustomToolRoundTrip(t *testing.T) {
	var capturedBody map[string]any
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if err := json.NewDecoder(r.Body).Decode(&capturedBody); err != nil {
			t.Fatalf("decode upstream request: %v", err)
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_custom","object":"chat.completion","created":1782864000,"model":"glm",
			"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8},
			"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
				{"id":"call_0123456789abcdef","type":"function","function":{"name":"apply_patch","arguments":"{\"input\":\"*** Begin Patch\\n*** End Patch\"}"}}
			]},"finish_reason":"tool_calls"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_custom_tool")

	resp := postResponses(t, h, key, `{
		"model":"glm","store":false,"reasoning":{"effort":"low"},
		"tools":[
			{"type":"custom","name":"apply_patch","description":"Apply a patch","format":{"type":"grammar","syntax":"lark","definition":"start: \"*** Begin Patch\""}},
			{"type":"web_search"}
		],
		"input":[
			{"type":"message","role":"user","content":"patch it"},
			{"type":"custom_tool_call","call_id":"call_aaaaaaaaaaaaaaaa","name":"apply_patch","input":"*** Begin Patch\n*** End Patch"},
			{"type":"custom_tool_call_output","call_id":"call_aaaaaaaaaaaaaaaa","output":"Done"},
			{"type":"reasoning","summary":[]}
		]
	}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := resp.Header().Get("X-Malibu-Unserved-Tools"); got != "web_search" {
		t.Fatalf("X-Malibu-Unserved-Tools=%q want web_search", got)
	}
	if capturedBody["reasoning_effort"] != "low" {
		t.Fatalf("reasoning.effort not forwarded: %v", capturedBody["reasoning_effort"])
	}
	tools := capturedBody["tools"].([]any)
	if len(tools) != 1 {
		t.Fatalf("tools=%v want only apply_patch", tools)
	}
	fn := tools[0].(map[string]any)["function"].(map[string]any)
	params := fn["parameters"].(map[string]any)
	input := params["properties"].(map[string]any)["input"].(map[string]any)
	if fn["name"] != "apply_patch" || input["type"] != "string" || !strings.Contains(fn["description"].(string), "lark grammar") {
		t.Fatalf("custom tool not served as a string-input function: %v", fn)
	}
	messages := capturedBody["messages"].([]any)
	if len(messages) != 3 {
		t.Fatalf("messages=%v want user, assistant call, tool result", messages)
	}
	call := messages[1].(map[string]any)["tool_calls"].([]any)[0].(map[string]any)["function"].(map[string]any)
	if call["name"] != "apply_patch" || call["arguments"] != `{"input":"*** Begin Patch\n*** End Patch"}` {
		t.Fatalf("custom_tool_call history=%v", call)
	}
	if tool := messages[2].(map[string]any); tool["role"] != "tool" || tool["content"] != "Done" {
		t.Fatalf("custom_tool_call_output history=%v", tool)
	}
	var out struct {
		Output []map[string]any `json:"output"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out.Output) != 1 || out.Output[0]["type"] != "custom_tool_call" || out.Output[0]["input"] != "*** Begin Patch\n*** End Patch" {
		t.Fatalf("output=%v want one custom_tool_call", out.Output)
	}
}

func TestResponsesStreamedCustomToolCallIsEmittedWhole(t *testing.T) {
	stream := `data: {"id":"chatcmpl_c","model":"glm","choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}` + "\n\n" +
		`data: {"id":"chatcmpl_c","model":"glm","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"apply_patch","arguments":""}}]},"finish_reason":null}]}` + "\n\n" +
		`data: {"id":"chatcmpl_c","model":"glm","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"input\":\"x\"}"}}]},"finish_reason":"tool_calls"}]}` + "\n\n" +
		`data: {"id":"chatcmpl_c","model":"glm","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}` + "\n\n" +
		"data: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_custom_stream")
	resp := postResponses(t, h, key, `{"model":"glm","store":false,"stream":true,"tools":[{"type":"custom","name":"apply_patch"}],"input":"patch"}`, nil)
	body := resp.Body.String()
	if resp.Code != http.StatusOK || !strings.Contains(body, `"type":"custom_tool_call"`) || !strings.Contains(body, `"input":"x"`) ||
		strings.Contains(body, "response.function_call_arguments.delta") {
		t.Fatalf("custom call stream:\n%s", body)
	}
}

func TestResponsesRefusesLocalShellTool(t *testing.T) {
	upstream := 0
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstream++
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_local_shell")
	resp := postResponses(t, h, key, `{"model":"glm","store":false,"tools":[{"type":"local_shell"}],"input":"ls"}`, nil)
	if resp.Code != http.StatusBadRequest || !strings.Contains(resp.Body.String(), `"code":"unsupported_tool_type"`) || upstream != 0 {
		t.Fatalf("local_shell must be refused before dispatch: %d %s (upstream=%d)", resp.Code, resp.Body.String(), upstream)
	}
}
