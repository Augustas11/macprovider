package router

import (
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// #1570: a coordinator post-commit terminal error frame (no choices) reaches
// the buyer as its SPEC-006 code instead of stream_malformed. The upstream
// message text is not forwarded, and settlement is unchanged (a SPEC-006
// §17.7.1 named mapping).
func TestStreamingCoordinatorTerminalErrorKeepsCode(t *testing.T) {
	for _, tc := range []struct{ code, wantCode, wantType string }{
		{"provider_error", "upstream_provider_error", "api_error"},
		{"provider_disconnected", "provider_disconnected", "server_error"},
	} {
		code := tc.code
		t.Run(code, func(t *testing.T) {
			body := `{"model":"llama","stream":true,"max_tokens":100,"messages":[{"role":"user","content":"long prompt"}]}`
			accountID := "acct_stream_terminal_" + code
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				payload := strings.Join([]string{
					`data: {"id":"chatcmpl","choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}`,
					`data: {"error":{"message":"upstream secret detail","type":"api_error","code":"` + code + `"}}`,
					`data: [DONE]`,
					``,
				}, "\n\n")
				return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			fullKey := createAccountAndKey(t, store, cfg, accountID)

			resp := postChat(t, h, fullKey, body, nil)
			got := resp.Body.String()
			if !strings.Contains(got, `"code":"`+tc.wantCode+`"`) || !strings.Contains(got, `"type":"`+tc.wantType+`"`) || strings.Contains(got, "stream_malformed") {
				t.Fatalf("terminal %s: want code %s type %s: %s", code, tc.wantCode, tc.wantType, got)
			}
			if !strings.Contains(got, `"retryable":true`) {
				t.Fatalf("terminal %s must stay retryable: %s", code, got)
			}
			if strings.Contains(got, "upstream secret detail") {
				t.Fatalf("upstream message text forwarded: %s", got)
			}
			if !strings.HasSuffix(got, "data: [DONE]\n\n") {
				t.Fatalf("missing DONE terminator: %s", got)
			}
			outcome, source := usageEventOutcome(t, dbPath, accountID)
			if outcome != "stream_malformed" || source != "gateway_estimated" {
				t.Fatalf("usage outcome/source = %s/%s, want unchanged stream_malformed/gateway_estimated", outcome, source)
			}
		})
	}
}

// An unknown upstream error code is still reported as stream_malformed.
func TestStreamingUnknownTerminalErrorStaysMalformed(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":100,"messages":[{"role":"user","content":"x"}]}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data: {"error":{"message":"x","type":"api_error","code":"something_else"}}`,
			`data: [DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_stream_terminal_unknown")
	resp := postChat(t, h, fullKey, body, nil)
	if got := resp.Body.String(); !strings.Contains(got, "stream_malformed") || strings.Contains(got, "something_else") {
		t.Fatalf("unknown upstream code should map to stream_malformed: %s", got)
	}
}
