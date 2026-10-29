package router

import (
	"encoding/json"
	"fmt"
	"github.com/augstar/macprovider-gateway/internal/config"
	"net/http"
	"strings"
	"testing"
)

func TestContextOverflowClientCompatibility(t *testing.T) {
	for _, stream := range []bool{false, true} {
		for _, message := range []string{"This model's maximum context length is 8192 tokens.", "Request exceeds provider context capacity"} {
			t.Run(fmt.Sprintf("stream_%t/%s", stream, message), func(t *testing.T) {
				body, _ := json.Marshal(map[string]any{"error": map[string]any{"code": "context_exceeds_capacity", "type": "invalid_request_error", "message": message}})
				client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
					return responseWithBody(413, http.Header{"Content-Type": []string{"application/json"}}, string(body)), nil
				})}
				h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) { cfg.Coordinator.BuyerURL = "http://coordinator.test" }, WithHTTPClient(client))
				key := createAccountAndKey(t, store, cfg, "context_compat")
				request := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
				if stream {
					request = strings.Replace(request, `"model":`, `"stream":true,"model":`, 1)
				}
				resp := postChat(t, h, key, request, nil)
				if resp.Code != 400 {
					t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
				}
				assertErrorCode(t, resp.Body.String(), "context_length_exceeded")
				var envelope struct {
					Error struct{ Type, Message string }
				}
				if err := json.Unmarshal(resp.Body.Bytes(), &envelope); err != nil {
					t.Fatal(err)
				}
				if envelope.Error.Type != "invalid_request_error" {
					t.Fatal(envelope.Error.Type)
				}
				if strings.Contains(message, "8192") && !strings.Contains(envelope.Error.Message, "maximum context length is 8192 tokens") {
					t.Fatal(envelope.Error.Message)
				}
			})
		}
	}
}

func TestContextOverflowDoesNotRemapOtherErrorsOrLeakDetails(t *testing.T) {
	for _, tc := range []struct {
		status int
		body   string
	}{
		{413, `{"error":{"code":"request_too_large","message":"body limit"}}`},
		{502, `{"error":{"code":"context_exceeds_capacity"}}`},
		{413, `not json`},
	} {
		status, body := clientContextOverflow(tc.status, []byte(tc.body))
		if status != tc.status || string(body) != tc.body {
			t.Fatalf("unrelated error remapped: %d %s", status, body)
		}
	}
	_, body := clientContextOverflow(413, []byte(`{"error":{"code":"context_exceeds_capacity","message":"secret prompt; This model's maximum context length is 9999 tokens.","retryable":true,"internal":"secret"}}`))
	if strings.Contains(string(body), "secret") || strings.Contains(string(body), "9999") || !strings.Contains(string(body), `"retryable":false`) {
		t.Fatalf("untrusted fields propagated: %s", body)
	}
}

func TestResponsesContextOverflowCompatibility(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(fmt.Sprint(stream), func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return responseWithBody(413, http.Header{"Content-Type": []string{"application/json"}}, `{"error":{"code":"context_exceeds_capacity","message":"This model's maximum context length is 4096 tokens."}}`), nil
			})}
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
			key := createAccountAndKey(t, store, cfg, "responses_context")
			resp := postResponses(t, h, key, fmt.Sprintf(`{"model":"llama","input":"hi","store":false,"stream":%t}`, stream), nil)
			if resp.Code != 400 || !strings.Contains(resp.Body.String(), "maximum context length is 4096 tokens") {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "context_length_exceeded")
		})
	}
}

func TestStreamingContextOverflowAfterCommit(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(200, http.Header{"Content-Type": []string{"text/event-stream"}}, "data: {\"id\":\"a\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"}}]}\n\ndata: {\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"This model's maximum context length is 8192 tokens.\",\"retryable\":true}}\n\ndata: [DONE]\n\n"), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) { cfg.Coordinator.BuyerURL = "http://coordinator.test" }, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "context_committed")
	resp := postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != 200 || !strings.Contains(resp.Body.String(), `"code":"context_length_exceeded"`) || !strings.Contains(resp.Body.String(), "maximum context length is 8192 tokens") || !strings.Contains(resp.Body.String(), `"retryable":false`) {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
}
