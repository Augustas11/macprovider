package router

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func TestRelayBlindMetadataRefillsPerMinute(t *testing.T) {
	for _, family := range []string{"chat_completions", "responses", "messages"} {
		for _, enabled := range []bool{false, true} {
			for _, mode := range []string{"required", "opportunistic"} {
				for _, limit := range []int{1, 2} {
					t.Run(fmt.Sprintf("%s/enabled=%t/%s/limit=%d", family, enabled, mode, limit), func(t *testing.T) {
						start := fixedNow()
						now := start
						dispatches := 0
						h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
							cfg.Features.RelayBlindRequests.Enabled = enabled
							cfg.Features.ResponsesAPIEnabled = enabled
							cfg.Features.AnthropicMessagesEnabled = enabled
							cfg.Features.RelayBlindRequests.MetadataRequestsPerMinute = limit
						}, WithNow(func() time.Time { return now }), WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
							dispatches++
							return responseWithBody(http.StatusOK, nil, `{}`), nil
						})}))
						accountID := "acct_relay_minute"
						key := createAccountAndKey(t, store, cfg, accountID)
						otherKey := createAccountAndKey(t, store, cfg, "acct_relay_minute_other")
						path := "/v1/" + family
						if family == "chat_completions" {
							path = "/v1/chat/completions"
						}
						acceptedStatus, acceptedCode := http.StatusBadRequest, "relay_blind_downgrade_rejected"
						auditType := "relay_blind_downgrade_rejected"
						if mode == "required" {
							auditType = "relay_blind_required_rejected"
							acceptedStatus, acceptedCode = http.StatusBadRequest, "relay_blind_endpoint_unsupported"
							if !enabled {
								acceptedStatus, acceptedCode = http.StatusServiceUnavailable, "relay_blind_disabled"
							} else if family == "chat_completions" {
								acceptedStatus, acceptedCode = http.StatusServiceUnavailable, "relay_blind_required_unavailable"
							}
						}
						sequence := 0
						body := func() string {
							sequence++
							return validRelayBlindRequestEnvelope(t, map[string]any{
								"endpoint_family": family, "mode": mode, "issued_at_unix": now.Unix(),
								"request_id": fmt.Sprintf("req-%d", sequence), "request_replay_nonce": fmt.Sprintf("nonce-%d", sequence),
								"buyer_ephemeral_public_key": fmt.Sprintf("key-%d", sequence), "ciphertext": fmt.Sprintf("ciphertext-%d", sequence),
							})
						}
						send := func(key, body string, status int, code string, retryAfter int) {
							t.Helper()
							req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
							req.Header.Set("Authorization", "Bearer "+key)
							resp := httptest.NewRecorder()
							h.ServeHTTP(resp, req)
							if resp.Code != status {
								t.Fatalf("at %s status=%d want %d body=%s", now.Sub(start), resp.Code, status, resp.Body.String())
							}
							if family == "messages" {
								assertAnthropicErrorCode(t, resp.Body.String(), code)
							} else {
								assertErrorCode(t, resp.Body.String(), code)
							}
							if retryAfter > 0 {
								assertBodyRetryable(t, resp.Body.String(), true)
								if got := resp.Header().Get("Retry-After"); got != strconv.Itoa(retryAfter) {
									t.Errorf("Retry-After=%q want %d", got, retryAfter)
								}
							}
						}
						first := body()
						send(key, first, acceptedStatus, acceptedCode, 0)
						for i := 1; i < limit; i++ {
							send(key, body(), acceptedStatus, acceptedCode, 0)
						}
						interval := time.Minute / time.Duration(limit)
						send(key, body(), http.StatusTooManyRequests, "relay_blind_metadata_rate_limited", int(interval.Seconds()))
						now = start.Add(time.Second)
						if mode == "required" {
							send(key, first, http.StatusConflict, "relay_blind_replay", 0)
						}
						send(key, body(), http.StatusTooManyRequests, "relay_blind_metadata_rate_limited", int(interval.Seconds())-1)
						send(otherKey, body(), acceptedStatus, acceptedCode, 0)
						now = start.Add(interval - time.Millisecond)
						send(key, body(), http.StatusTooManyRequests, "relay_blind_metadata_rate_limited", 1)
						now = start.Add(interval)
						send(key, body(), acceptedStatus, acceptedCode, 0)
						send(key, body(), http.StatusTooManyRequests, "relay_blind_metadata_rate_limited", int(interval.Seconds()))
						now = start.Add(3 * time.Minute)
						for i := 0; i < limit; i++ {
							send(key, body(), acceptedStatus, acceptedCode, 0)
						}
						send(key, body(), http.StatusTooManyRequests, "relay_blind_metadata_rate_limited", int(interval.Seconds()))
						if got, want := countAuditEvents(t, dbPath, auditType), 2*limit+2; got != want {
							t.Fatalf("audit rows=%d want %d", got, want)
						}
						if dispatches != 0 {
							t.Fatalf("dispatches=%d want 0", dispatches)
						}
						assertNoDailyUsage(t, store, accountID)
						assertNoDailyUsage(t, store, "acct_relay_minute_other")
					})
				}
			}
		}
	}
}
