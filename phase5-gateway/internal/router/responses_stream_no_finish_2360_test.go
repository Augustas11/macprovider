package router

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// #2360: an upstream stream that ends without finish_reason is a truncated
// answer. The client gets response.failed with an error code, never
// response.completed, when the upstream closes without [DONE].
func TestResponsesStreamingEndWithoutFinishReasonIsFailed(t *testing.T) {
	for _, tc := range []struct {
		name string
		end  func(a *responsesAdapter)
	}{
		{"eof", func(a *responsesAdapter) { a.finish() }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			adapter := newResponsesAdapter(rec, "23602360-2360-4236-8236-236023602360", nil)
			adapter.stream = true
			adapter.model = "llama"
			adapter.WriteHeader(http.StatusOK)

			adapter.handleChatStreamLine(`data: {"id":"chatcmpl_trunc","model":"llama","choices":[{"delta":{"content":"partial"}}]}`)
			tc.end(adapter)

			body := rec.Body.String()
			for _, want := range []string{
				`"delta":"partial"`,
				"event: response.failed",
				`"status":"failed"`,
				`"code":"invalid_provider_response"`,
				"data: [DONE]",
			} {
				if !strings.Contains(body, want) {
					t.Fatalf("truncated stream missing %q:\n%s", want, body)
				}
			}
			if strings.Contains(body, "event: response.completed") || strings.Contains(body, "event: response.incomplete") {
				t.Fatalf("truncated stream reported a non-failed terminal:\n%s", body)
			}
		})
	}
}

// The other endings keep their terminal event.
func TestResponsesStreamingFinishReasonEndingsUnchanged(t *testing.T) {
	for reason, want := range map[string]string{
		"stop":       "event: response.completed",
		"tool_calls": "event: response.completed",
		"length":     "event: response.incomplete",
	} {
		rec := httptest.NewRecorder()
		adapter := newResponsesAdapter(rec, "23602360-2360-4236-8236-236023602361", nil)
		adapter.stream = true
		adapter.model = "llama"
		adapter.WriteHeader(http.StatusOK)
		adapter.handleChatStreamLine(`data: {"id":"chatcmpl_end","model":"llama","choices":[{"delta":{"content":"x"},"finish_reason":"` + reason + `"}]}`)
		adapter.finish()
		body := rec.Body.String()
		if !strings.Contains(body, want) || strings.Contains(body, "event: response.failed") {
			t.Fatalf("finish_reason %s: want %q, got:\n%s", reason, want, body)
		}
	}
}
