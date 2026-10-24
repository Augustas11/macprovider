package router

import (
	"net/http"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// SPEC-001-R012: when the coordinator refuses a request because its frame
// exceeds the selected provider's WebSocket message limit, the buyer sees the
// coordinator's 413 request_too_large, never a provider error or a 503.
func TestCoordinatorProviderFrameTooLargeReaches413(t *testing.T) {
	for _, stream := range []bool{false, true} {
		client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			return responseWithBody(http.StatusRequestEntityTooLarge, http.Header{"Content-Type": []string{"application/json"}},
				`{"error":{"message":"Request is too large for the selected provider's transport","type":"invalid_request_error","code":"request_too_large"}}`), nil
		})}
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
			cfg.Coordinator.BuyerURL = "http://coordinator.test"
		}, WithHTTPClient(client))
		fullKey := createAccountAndKey(t, store, cfg, "acct_frame_too_large")
		body := `{"model":"llama","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`
		if stream {
			body = `{"model":"llama","max_tokens":8,"stream":true,"messages":[{"role":"user","content":"hi"}]}`
		}
		resp := postChat(t, h, fullKey, body, nil)
		if resp.Code != http.StatusRequestEntityTooLarge {
			t.Fatalf("stream=%v status=%d body=%s", stream, resp.Code, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), "request_too_large")
	}
}
