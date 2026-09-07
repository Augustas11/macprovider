package router

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func TestRelayBlindPrecheckRejectionsAuditBoundedMetadata(t *testing.T) {
	for _, family := range []string{"chat_completions", "responses", "messages"} {
		for _, enabled := range []bool{false, true} {
			for _, rejection := range []string{"malformed", "schema", "cap", "stale", "oversized identifier"} {
				t.Run(fmt.Sprintf("%s/enabled=%t/%s", family, enabled, rejection), func(t *testing.T) {
					dispatchCalls := 0
					h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
						cfg.Features.RelayBlindRequests.Enabled = enabled
						cfg.Features.ResponsesAPIEnabled = enabled
						cfg.Features.AnthropicMessagesEnabled = enabled
						cfg.Features.RelayBlindRequests.MetadataRequestsPerMinute = 1
						cfg.Limits.MaxTokensPerRequest = 20
					}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
						dispatchCalls++
						return responseWithBody(http.StatusOK, nil, `{}`), nil
					})}))
					accountID := "acct_rejection_audit"
					key := createAccountAndKey(t, store, cfg, accountID)
					overrides := map[string]any{"endpoint_family": family}
					switch rejection {
					case "schema":
						overrides["private-prompt-sentinel"] = "private-plaintext-sentinel"
					case "cap":
						overrides["max_output_tokens"] = 21
						overrides["reservation_token_cap"] = 29
					case "stale":
						overrides["issued_at_unix"] = fixedNow().Add(-2 * time.Minute).Unix()
					case "oversized identifier":
						overrides["kid"] = strings.Repeat("private-identifier-sentinel", 100)
					}
					body := validRelayBlindRequestEnvelope(t, overrides)
					if rejection == "malformed" {
						body = `{"version":"relay-blind-request-v1","mode":"required","private-prompt-sentinel":`
					}
					path := "/v1/" + family
					if family == "chat_completions" {
						path = "/v1/chat/completions"
					}
					unauthenticated := httptest.NewRecorder()
					h.ServeHTTP(unauthenticated, httptest.NewRequest(http.MethodPost, path, strings.NewReader(body)))
					if unauthenticated.Code != http.StatusUnauthorized {
						t.Fatalf("unauthenticated status=%d want 401", unauthenticated.Code)
					}
					if got := countAuditEvents(t, dbPath, "relay_blind_required_rejected"); got != 0 {
						t.Fatalf("unauthenticated audits=%d want 0", got)
					}
					for attempt, wantStatus := range []int{http.StatusBadRequest, http.StatusTooManyRequests} {
						req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
						req.Header.Set("Authorization", "Bearer "+key)
						resp := httptest.NewRecorder()
						h.ServeHTTP(resp, req)
						if resp.Code != wantStatus {
							t.Fatalf("attempt=%d status=%d want %d body=%s", attempt, resp.Code, wantStatus, resp.Body.String())
						}
						code := "relay_blind_envelope_invalid"
						if attempt > 0 {
							code = "relay_blind_metadata_rate_limited"
						}
						if family == "messages" {
							assertAnthropicErrorCode(t, resp.Body.String(), code)
						} else {
							assertErrorCode(t, resp.Body.String(), code)
						}
						if got := countAuditEvents(t, dbPath, "relay_blind_required_rejected"); got != 1 {
							t.Fatalf("attempt=%d rejection audits=%d want 1", attempt, got)
						}
					}
					payload := relayBlindAuditPayload(t, dbPath, "relay_blind_required_rejected")
					var fields map[string]any
					if err := json.Unmarshal([]byte(payload), &fields); err != nil {
						t.Fatal(err)
					}
					digest := sha256.Sum256([]byte(body))
					want := map[string]any{
						"endpoint_family": family, "mode_class": "unvalidated",
						"requested_privacy_mode": "relay_blind_required", "effective_outcome": "relay_blind_unavailable",
						"wallet_session_id": "", "envelope_digest": hex.EncodeToString(digest[:]),
						"reason_code": "relay_blind_envelope_invalid",
					}
					if len(fields) != len(want) {
						t.Fatalf("unexpected audit fields: %s", payload)
					}
					for key, value := range want {
						if fields[key] != value {
							t.Fatalf("audit[%s]=%v want %v", key, fields[key], value)
						}
					}
					if dispatchCalls != 0 {
						t.Fatalf("dispatches=%d want 0", dispatchCalls)
					}
					assertNoDailyUsage(t, store, accountID)
				})
			}
		}
	}
}

func TestRelayBlindWalletPrecheckAuditPreservesAdmission(t *testing.T) {
	for _, family := range []string{"chat_completions", "responses", "messages"} {
		for _, enabled := range []bool{false, true} {
			for _, rejection := range []string{"malformed", "schema", "model", "cap", "stale"} {
				t.Run(fmt.Sprintf("%s/enabled=%t/%s", family, enabled, rejection), func(t *testing.T) {
					h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
						cfg.Public.BaseURL = "https://api.malibu.test"
						cfg.Auth.WalletSessions.Enabled = true
						cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
						cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
						cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
						cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 1
						cfg.Features.RelayBlindRequests.Enabled = enabled
						cfg.Features.ResponsesAPIEnabled = enabled
						cfg.Features.AnthropicMessagesEnabled = enabled
					}, WithHTTPClient(walletModelsClient()))
					accountID := "acct_wallet_precheck_audit"
					key := createAccountAndKey(t, store, cfg, accountID)
					wallet := registerWalletSessionViaAPIWithCaps(t, h, cfg, key, accountID, []string{"model-a"}, 100, 50)
					overrides := map[string]any{"endpoint_family": family}
					status, code := http.StatusBadRequest, "relay_blind_envelope_invalid"
					switch rejection {
					case "schema":
						overrides["private-prompt-sentinel"] = "private-plaintext-sentinel"
					case "model":
						overrides["model"] = "model-b"
						status, code = http.StatusForbidden, "wallet_session_model_not_allowed"
					case "cap":
						overrides["reservation_token_cap"] = 51
						code = "wallet_session_request_cap_exceeded"
					case "stale":
						overrides["issued_at_unix"] = fixedNow().Add(-2 * time.Minute).Unix()
					}
					body := []byte(validRelayBlindRequestEnvelope(t, overrides))
					if rejection == "malformed" {
						body = []byte(`{"mode":"required"}`)
					}
					path := "/v1/" + family
					if family == "chat_completions" {
						path = "/v1/chat/completions"
					}
					outerID := "018f7b7b-7c35-4cf0-8d4e-3f0ab1c50928"
					for _, attempt := range []struct {
						id     string
						status int
						code   string
					}{
						{outerID, status, code},
						{outerID, http.StatusConflict, "wallet_session_duplicate_request"},
						{"018f7b7b-7c35-4cf0-8d4e-3f0ab1c50929", http.StatusTooManyRequests, "wallet_session_rate_limited"},
					} {
						resp := httptest.NewRecorder()
						h.ServeHTTP(resp, signedWalletRequest(t, wallet, http.MethodPost, path, path, attempt.id, body))
						if resp.Code != attempt.status {
							t.Fatalf("status=%d want %d body=%s", resp.Code, attempt.status, resp.Body.String())
						}
						if family == "messages" {
							assertAnthropicErrorCode(t, resp.Body.String(), attempt.code)
						} else {
							assertErrorCode(t, resp.Body.String(), attempt.code)
						}
						if got := countAuditEvents(t, dbPath, "relay_blind_required_rejected"); got != 1 {
							t.Fatalf("audits=%d want 1", got)
						}
					}
					var payload map[string]any
					if err := json.Unmarshal([]byte(relayBlindAuditPayload(t, dbPath, "relay_blind_required_rejected")), &payload); err != nil {
						t.Fatal(err)
					}
					if payload["wallet_session_id"] != wallet.SessionID || payload["reason_code"] != code {
						t.Fatalf("audit correlation/reason=%v", payload)
					}
					assertNoDailyUsage(t, store, accountID)
				})
			}
		}
	}
}

func TestRelayBlindPrecheckAuditFailureFailsClosed(t *testing.T) {
	for _, path := range []string{"/v1/chat/completions", "/v1/responses", "/v1/messages"} {
		t.Run(path, func(t *testing.T) {
			_, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(noopClient()))
			key := createAccountAndKey(t, store, cfg, "acct_precheck_audit_failure")
			h := New(cfg, relayBlindAuditFailStore{Store: store}, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()
			req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(`{"mode":"required"}`))
			req.Header.Set("Authorization", "Bearer "+key)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != http.StatusInternalServerError {
				t.Fatalf("status=%d want 500 body=%s", resp.Code, resp.Body.String())
			}
			if path == "/v1/messages" {
				assertAnthropicErrorCode(t, resp.Body.String(), "internal_error")
			} else {
				assertErrorCode(t, resp.Body.String(), "internal_error")
			}
			assertNoDailyUsage(t, store, "acct_precheck_audit_failure")
		})
	}
}
