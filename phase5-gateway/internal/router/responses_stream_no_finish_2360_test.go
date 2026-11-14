package router

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
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

// #2360 audit: through the full handler, a truncated stream is failed before
// settlement, so it is not cached for id-less replay: an identical retry is
// dispatched again instead of replaying the failure.
func TestResponsesTruncatedStreamIsNotReplayedByIdlessDedupe(t *testing.T) {
	var hits atomic.Int32
	stream := strings.Join([]string{
		`data: {"id":"chatcmpl_trunc_dedupe","model":"llama","choices":[{"delta":{"content":"partial"}}]}`,
		``,
	}, "\n\n")
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		hits.Add(1)
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_trunc_dedupe")
	body := `{"model":"llama","input":"hi","stream":true,"max_output_tokens":20,"store":false}`

	first := postResponses(t, h, key, body, nil)
	second := postResponses(t, h, key, body, nil)

	for i, resp := range []*httptest.ResponseRecorder{first, second} {
		got := resp.Body.String()
		if !strings.Contains(got, "event: response.failed") || !strings.Contains(got, `"code":"invalid_provider_response"`) ||
			strings.Contains(got, "event: response.completed") {
			t.Fatalf("attempt %d: want response.failed only:\n%s", i+1, got)
		}
		if strings.Count(got, "event: response.failed") != 1 {
			t.Fatalf("attempt %d: response.failed emitted %d times:\n%s", i+1, strings.Count(got, "event: response.failed"), got)
		}
	}
	if got := second.Header().Get(idlessDedupeHeader); got == idlessDedupeHeaderValue {
		t.Fatalf("truncated stream was replayed from the dedupe cache")
	}
	if got := hits.Load(); got != 2 {
		t.Fatalf("upstream dispatches=%d want 2 (no replay of a failed stream)", got)
	}
}
