package router

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

// API fixtures for the documented client transports: Codex uses Responses;
// OpenCode/Goose/Crush use Chat Completions. Messages remains an explicitly
// enabled alternate API. Cursor's wire protocol requires installed-client
// verification and is not claimed by this fixture. Model qualification and
// actual client-version compatibility are separate acceptance gates.
func TestConnectedAppsAPIContractPreservesToolsAndTrustedIdentity(t *testing.T) {
	for _, family := range []string{"chat", "responses", "messages"} {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%v", family, stream), func(t *testing.T) {
				var captured map[string]any
				calls := 0
				client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
					calls++
					if r.URL.Path != "/v1/chat/completions" {
						t.Fatalf("unexpected upstream %s", r.URL.Path)
					}
					if r.Header.Get(routingGitHubIDsHeader) != "7,8" || r.Header.Get("X-MacProvider-Account") != "connected-account" {
						t.Fatalf("untrusted routing identity: %v", r.Header)
					}
					if err := json.NewDecoder(r.Body).Decode(&captured); err != nil {
						t.Fatal(err)
					}
					if stream {
						frames := []string{
							`data: {"id":"chatcmpl_connected","model":"llama","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_next","type":"function","function":{"name":"lookup","arguments":""}}]}}]}`,
							`data: {"id":"chatcmpl_connected","model":"llama","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"q\":\"next\"}"}}]}}]}`,
							`data: {"id":"chatcmpl_connected","model":"llama","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":4,"completion_tokens":5,"total_tokens":9}}`,
							`data: [DONE]`, "",
						}
						return responseWithBody(200, http.Header{"Content-Type": []string{"text/event-stream"}}, strings.Join(frames, "\n\n")), nil
					}
					return responseWithBody(200, http.Header{"Content-Type": []string{"application/json"}}, `{"id":"chatcmpl_connected","object":"chat.completion","model":"llama","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_next","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"next\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":4,"completion_tokens":5,"total_tokens":9}}`), nil
				})}
				h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
					enableResponsesWithCoordinator(cfg)
					cfg.Features.AnthropicMessagesEnabled = true
				}, WithHTTPClient(client))
				key := createAccountAndKey(t, store, cfg, "connected-account")
				for _, id := range []string{"7", "8"} {
					if err := store.AddAccountIdentity(context.Background(), storage.AccountIdentity{AccountID: "connected-account", Provider: "github", ProviderUserID: id, CreatedAt: fixedNow()}); err != nil {
						t.Fatal(err)
					}
				}
				var path, body string
				switch family {
				case "chat":
					path = "/v1/chat/completions"
					body = `{"model":"llama","max_tokens":32,"messages":[{"role":"user","content":"lookup"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_previous","type":"function","function":{"name":"lookup","arguments":"{}"}}]},{"role":"tool","tool_call_id":"call_previous","content":"result"}],"tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","properties":{"q":{"type":"string"}}}}}]}`
				case "responses":
					path = "/v1/responses"
					body = `{"model":"llama","max_output_tokens":32,"store":false,"input":[{"role":"user","content":"lookup"},{"type":"function_call","call_id":"call_previous","name":"lookup","arguments":"{}"},{"type":"function_call_output","call_id":"call_previous","output":"result"}],"tools":[{"type":"function","name":"lookup","parameters":{"type":"object","properties":{"q":{"type":"string"}}}}]}`
				case "messages":
					path = "/v1/messages"
					body = `{"model":"llama","max_tokens":32,"messages":[{"role":"user","content":"lookup"},{"role":"assistant","content":[{"type":"tool_use","id":"call_previous","name":"lookup","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_previous","content":"result"}]}],"tools":[{"name":"lookup","input_schema":{"type":"object","properties":{"q":{"type":"string"}}}}]}`
				}
				body = strings.TrimSuffix(body, "}") + fmt.Sprintf(`,"stream":%v}`, stream)
				req := httptest.NewRequest("POST", path, strings.NewReader(body))
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("Authorization", "Bearer "+key)
				req.Header.Set(routingGitHubIDsHeader, "999")
				req.Header.Set("X-MacProvider-Account", "forged")
				rr := httptest.NewRecorder()
				h.ServeHTTP(rr, req)
				if rr.Code != 200 || calls != 1 {
					t.Fatalf("status=%d calls=%d body=%s", rr.Code, calls, rr.Body.String())
				}
				messages, ok := captured["messages"].([]any)
				if !ok || len(messages) != 3 {
					t.Fatalf("tool history missing: %v", captured)
				}
				tool := messages[2].(map[string]any)
				assistantCall := messages[1].(map[string]any)["tool_calls"].([]any)[0].(map[string]any)
				if tool["role"] != "tool" || tool["tool_call_id"] == "" || tool["tool_call_id"] != assistantCall["id"] {
					t.Fatalf("tool result identity lost: %v", tool)
				}
				if captured["stream"] != stream || len(captured["tools"].([]any)) != 1 {
					t.Fatalf("stream/tools lost: %v", captured)
				}
				if !strings.Contains(rr.Body.String(), "lookup") {
					t.Fatalf("tool call output missing: %s", rr.Body.String())
				}
				if stream {
					terminal := map[string]string{"chat": "[DONE]", "responses": "response.completed", "messages": "message_stop"}[family]
					if !strings.Contains(rr.Body.String(), terminal) {
						t.Fatalf("terminal %q missing: %s", terminal, rr.Body.String())
					}
				}
			})
		}
	}
}
