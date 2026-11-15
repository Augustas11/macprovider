package router

import (
	"encoding/json"
	"net/http"
	"testing"
)

// #2363: `reasoning.effort: "max"` on /v1/responses reaches the provider as
// the chat `reasoning_effort: "max"` instead of being dropped.
func TestResponsesReasoningEffortMaxForwarded(t *testing.T) {
	var capturedBody map[string]any
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if err := json.NewDecoder(r.Body).Decode(&capturedBody); err != nil {
			t.Fatalf("decode upstream request: %v", err)
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_max","object":"chat.completion","created":1782864000,"model":"glm",
			"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_responses_effort_max")

	resp := postResponses(t, h, key, `{"model":"glm","store":false,"reasoning":{"effort":"max"},"input":"hi"}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if capturedBody["reasoning_effort"] != "max" {
		t.Fatalf("reasoning_effort=%v want max", capturedBody["reasoning_effort"])
	}
}

func TestResponsesReasoningEffortAcceptedSet(t *testing.T) {
	for _, effort := range []string{"none", "minimal", "low", "medium", "high", "xhigh", "max"} {
		if got := responsesReasoningEffort(map[string]any{"effort": effort}); got != effort {
			t.Fatalf("effort %q -> %q", effort, got)
		}
	}
}
