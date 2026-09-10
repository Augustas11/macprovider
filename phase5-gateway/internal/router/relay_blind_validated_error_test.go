package router

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

func TestRelayBlindValidatedErrorCommitsAndContradictoryNoDispatchNeverRefunds(t *testing.T) {
	for _, tc := range []struct {
		name                string
		validation          string
		inputTokens         string
		duplicateValidation bool
		duplicateInput      bool
		noPriorDispatch     bool
		wantStatus          int
		wantCode            string
		wantSatisfied       bool
		wantHeld            int64
		wantRetryAction     string
	}{
		{name: "validated error remains satisfied and held", validation: "valid", inputTokens: "0", wantStatus: 500, wantCode: "relay_blind_committed_failed", wantSatisfied: true, wantHeld: 24, wantRetryAction: "do_not_resubmit"},
		{name: "validated contradicts no prior dispatch", validation: "valid", inputTokens: "16", noPriorDispatch: true, wantStatus: 500, wantCode: "relay_blind_committed_failed", wantSatisfied: true, wantHeld: 24, wantRetryAction: "do_not_resubmit"},
		{name: "wrong nonempty validation cannot refund", validation: "wrong", noPriorDispatch: true, wantStatus: 500, wantCode: "relay_blind_committed_failed", wantHeld: 24, wantRetryAction: "do_not_resubmit"},
		{name: "noncanonical input cannot refund", validation: "valid", inputTokens: "01", noPriorDispatch: true, wantStatus: 500, wantCode: "relay_blind_committed_failed", wantHeld: 24, wantRetryAction: "do_not_resubmit"},
		{name: "input without validation cannot refund", inputTokens: "0", noPriorDispatch: true, wantStatus: 500, wantCode: "relay_blind_committed_failed", wantHeld: 24, wantRetryAction: "do_not_resubmit"},
		{name: "repeated validation cannot refund", validation: "valid", duplicateValidation: true, noPriorDispatch: true, wantStatus: 500, wantCode: "relay_blind_committed_failed", wantHeld: 24, wantRetryAction: "do_not_resubmit"},
		{name: "repeated input cannot refund", validation: "valid", inputTokens: "0", duplicateInput: true, noPriorDispatch: true, wantStatus: 500, wantCode: "relay_blind_committed_failed", wantHeld: 24, wantRetryAction: "do_not_resubmit"},
		{name: "true prevalidation rejection refunds", noPriorDispatch: true, wantStatus: 400, wantCode: "relay_blind_ciphertext_invalid", wantHeld: 0, wantRetryAction: "none"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reservation, _ := pilotReservationFixture(t, false)
			raw := pilotEnvelopeFixture(t, reservation)
			digest := sha256.Sum256(raw)
			digestText := base64.RawURLEncoding.EncodeToString(digest[:])
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/v1/relay-blind/consume":
					_ = json.NewEncoder(w).Encode(relayblind.ConsumeResponse{
						Version: relayblind.ConsumeVersion, ProviderBinding: reservation.ProviderBinding,
						BuyerBinding: reservation.BuyerBinding, EnvelopeDigest: digestText,
						ExecutionAuthorization: "internal-execution-authorization",
						ConsumedAtUnix:         fixedNow().Unix(), ExpiresAtUnix: reservation.ExpiresAtUnix,
					})
				case "/v1/chat/completions":
					if tc.validation == "valid" {
						w.Header().Set(relayBlindValidatedHeader, digestText)
						if tc.duplicateValidation {
							w.Header().Add(relayBlindValidatedHeader, digestText)
						}
					} else if tc.validation == "wrong" {
						w.Header().Set(relayBlindValidatedHeader, "wrong-digest")
					}
					if tc.inputTokens != "" {
						w.Header().Set("X-MacProvider-Relay-Blind-Input-Tokens", tc.inputTokens)
						if tc.duplicateInput {
							w.Header().Add("X-MacProvider-Relay-Blind-Input-Tokens", tc.inputTokens)
						}
					}
					if tc.noPriorDispatch {
						w.Header().Set(settlementNoPriorDispatchHeader, "1")
					}
					w.WriteHeader(http.StatusBadRequest)
					_, _ = w.Write([]byte(`{"error":{"code":"relay_blind_ciphertext_invalid"}}`))
				default:
					w.WriteHeader(http.StatusNotFound)
				}
			}))
			defer upstream.Close()

			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				c.Features.RelayBlindRequests.Enabled = true
				c.Coordinator.BuyerURL = upstream.URL
			})
			accountID := "acct_validated_error_" + strings.ReplaceAll(tc.name, " ", "_")
			key := createAccountAndKey(t, store, cfg, accountID)
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(raw))
			req.Header.Set("Authorization", "Bearer "+key)
			req.Header.Set("X-Request-ID", "123e4567-e89b-42d3-a456-426614174088")
			response := httptest.NewRecorder()
			h.ServeHTTP(response, req)

			if response.Code != tc.wantStatus {
				t.Fatalf("status=%d body=%s, want %d", response.Code, response.Body.String(), tc.wantStatus)
			}
			var body struct {
				Error struct {
					Code        string `json:"code"`
					MacProvider struct {
						RetryAction string `json:"retry_action"`
					} `json:"macprovider"`
				} `json:"error"`
			}
			if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if body.Error.Code != tc.wantCode || body.Error.MacProvider.RetryAction != tc.wantRetryAction {
				t.Fatalf("code/retry=%q/%q want %q/%q body=%s", body.Error.Code, body.Error.MacProvider.RetryAction, tc.wantCode, tc.wantRetryAction, response.Body.String())
			}
			wantOutcome := "relay_blind_unavailable"
			if tc.wantSatisfied {
				wantOutcome = "relay_blind_satisfied"
			}
			if got := response.Header().Get(relayBlindEffectiveHeader); got != wantOutcome {
				t.Fatalf("effective privacy outcome=%q want %q", got, wantOutcome)
			}
			used, held, err := store.DailyUsage(context.Background(), accountID, fixedNow().Format("2006-01-02"))
			if err != nil || used != 0 || held != tc.wantHeld {
				t.Fatalf("usage/held=%d/%d err=%v want 0/%d", used, held, err, tc.wantHeld)
			}
		})
	}
}
