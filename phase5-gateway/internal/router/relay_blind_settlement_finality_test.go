package router

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

func relayBlindFinalityHeaders(outcome, receiptResult string, closed bool) http.Header {
	h := http.Header{}
	h.Set(settlementModeHeader, "enforce")
	h.Set(settlementPolicyVersionHeader, settlementPolicyVersion)
	h.Set(settlementOutcomeHeader, outcome)
	h.Set(settlementReceiptResultHeader, receiptResult)
	h.Set(settlementReasonHeader, "relay_blind_settlement")
	h.Set(settlementClosedHeader, strconv.FormatBool(closed))
	return h
}

// SPEC-022 R-8.1: relay_blind_settled final-debits only a request admitted
// as a relay-blind execution; every other request that reports it refunds.
// R-10.7: a relay-blind execution is never debited on a verified tuple.
func TestRelayBlindSettledFinalityDebitsOnlyRelayBlindExecutions(t *testing.T) {
	cases := []struct {
		name       string
		header     http.Header
		relayBlind bool
		want       settlementFinalityAction
	}{
		{"relay-blind closed valid", relayBlindFinalityHeaders("relay_blind_settled", "valid", true), true, settlementFinalityDebit},
		{"plaintext reporting relay_blind_settled", relayBlindFinalityHeaders("relay_blind_settled", "valid", true), false, settlementFinalityRefund},
		{"relay-blind not closed", relayBlindFinalityHeaders("relay_blind_settled", "valid", false), true, settlementFinalityHold},
		{"relay-blind invalid receipt", relayBlindFinalityHeaders("relay_blind_settled", "invalid", true), true, settlementFinalityHold},
		{"plaintext not closed", relayBlindFinalityHeaders("relay_blind_settled", "valid", false), false, settlementFinalityHold},
		{"relay-blind reporting verified", relayBlindFinalityHeaders("verified", "valid", true), true, settlementFinalityHold},
		{"plaintext verified unchanged", relayBlindFinalityHeaders("verified", "valid", true), false, settlementFinalityDebit},
		{"relay-blind quarantined refunds", relayBlindFinalityHeaders("quarantined", "invalid", true), true, settlementFinalityRefund},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := coordinatorSettlementFinalityForRequest(tc.header, tc.relayBlind)
			if got.Action != tc.want {
				t.Fatalf("action=%v want %v (%+v)", got.Action, tc.want, got)
			}
			// The request-agnostic reader never debits the relay-blind outcome.
			if plain := coordinatorSettlementFinalityFromHeaders(tc.header); plain.Outcome == relayBlindSettledOutcome && plain.Action == settlementFinalityDebit {
				t.Fatal("request-agnostic finality debited relay_blind_settled")
			}
			// The signed-trailer readers carry the same request binding.
			resp := &http.Response{Header: http.Header{}, Trailer: tc.header}
			b := settlementFinalityBinding{relayBlind: tc.relayBlind}
			if got := coordinatorStreamingSettlementFinality(resp, b); got.Action != tc.want {
				t.Fatalf("streaming trailer action=%v want %v", got.Action, tc.want)
			}
		})
	}
}

type relayBlindReconcileCase struct {
	name     string
	finality map[string]any
	// dispatch is what the coordinator chat response proved: "enforce"
	// (internal request id present, the default), "observe" (absent), or
	// "lost" (no response reached the gateway).
	dispatch string
	// finalityAnswer overrides the finality endpoint: "not_found" (the
	// coordinator's authoritative answer) or "error" (HTTP 500).
	finalityAnswer string
	// noFinalityLookup asserts the reconciler never asked for finality.
	noFinalityLookup bool
	wantUsed         int64
	wantHeld         int64
	wantResult       func(SettlementReconcileSummary) bool
}

// SPEC-022 R-13.6 / R-8.1 in the reconciler: under enforce a relay-blind
// hold settles from coordinator finality, never from the status row. A
// relay_blind_settled tuple debits the coordinator's usage under its own
// label; a refund tuple refunds; anything else holds.
func TestRelayBlindReconcileFollowsEnforceFinality(t *testing.T) {
	cases := []relayBlindReconcileCase{
		{
			name: "relay_blind_settled debits coordinator usage",
			finality: map[string]any{"mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "relay_blind_settled", "receipt_result": "valid",
				"reason": "relay_blind_settlement", "closed": true, "prompt_tokens": 3, "completion_tokens": 5, "total_tokens": 8,
				"token_source": "coordinator_observed", "relay_blind_settled_attempts": 1, "mode_scope_complete": true},
			wantUsed: 8, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.RelayBlindSettled == 1 && s.Verified == 0 },
		},
		{
			name: "quarantined refunds",
			finality: map[string]any{"mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "quarantined", "receipt_result": "invalid",
				"reason": "usage_mismatch", "closed": true, "quarantined_attempts": 1, "mode_scope_complete": true},
			wantUsed: 0, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Refunded == 1 },
		},
		{
			name: "pending holds",
			finality: map[string]any{"mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "pending", "receipt_result": "inconclusive",
				"reason": "receipt_verdict_pending", "closed": false, "pending_attempts": 1, "mode_scope_complete": true},
			wantUsed: 0, wantHeld: 24,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Held == 1 },
		},
		{
			name: "verified on a relay-blind execution holds",
			finality: map[string]any{"mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "verified", "receipt_result": "valid",
				"reason": "verified_settlement", "closed": true, "prompt_tokens": 3, "completion_tokens": 5, "total_tokens": 8,
				"token_source": "coordinator_observed", "verified_attempts": 1, "mode_scope_complete": true},
			wantUsed: 0, wantHeld: 24,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Held == 1 && s.Verified == 0 },
		},
		{
			name:           "enforce dispatch with coordinator not-found holds, never debits",
			finalityAnswer: "not_found", wantUsed: 0, wantHeld: 24,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Coordinator404 == 1 && s.Held == 1 },
		},
		{
			name:           "enforce dispatch with finality fetch error holds",
			finalityAnswer: "error", wantUsed: 0, wantHeld: 24,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Errors == 0 && s.Held == 1 },
		},
		{
			name: "enforce unrecorded attempt refunds",
			finality: map[string]any{"mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "quarantined", "receipt_result": "inconclusive",
				"reason": "relay_blind_attempt_unrecorded", "closed": true, "quarantined_attempts": 1, "mode_scope_complete": true},
			wantUsed: 0, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Refunded == 1 },
		},
		{
			name:     "observe dispatch keeps status recovery without a finality lookup",
			dispatch: "observe", noFinalityLookup: true,
			finality: map[string]any{"mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "quarantined", "receipt_result": "invalid",
				"reason": "usage_mismatch", "closed": true, "quarantined_attempts": 1, "mode_scope_complete": true},
			wantUsed: 4, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Observed == 1 },
		},
		{
			name:     "lost dispatch with authoritative not-found keeps status recovery",
			dispatch: "lost", finalityAnswer: "not_found", wantUsed: 4, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Observed == 1 },
		},
		{
			name:     "lost dispatch with finality fetch error holds",
			dispatch: "lost", finalityAnswer: "error", wantUsed: 0, wantHeld: 24,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Held == 1 },
		},
		{
			name:     "lost dispatch with enforce finality follows it",
			dispatch: "lost",
			finality: map[string]any{"mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "pending", "receipt_result": "inconclusive",
				"reason": "relay_blind_attempt_pending", "closed": false, "pending_attempts": 1, "mode_scope_complete": true},
			wantUsed: 0, wantHeld: 24,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Held == 1 },
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res, _ := pilotReservationFixture(t, false)
			raw := pilotEnvelopeFixture(t, res)
			digest := sha256.Sum256(raw)
			digestText := base64.RawURLEncoding.EncodeToString(digest[:])
			var finalityLookups atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/v1/relay-blind/consume":
					json.NewEncoder(w).Encode(relayblind.ConsumeResponse{Version: relayblind.ConsumeVersion, ProviderBinding: res.ProviderBinding, BuyerBinding: res.BuyerBinding, EnvelopeDigest: digestText, ExecutionAuthorization: "internal-execution-authorization", ConsumedAtUnix: fixedNow().Unix(), ExpiresAtUnix: res.ExpiresAtUnix})
				case "/v1/chat/completions":
					switch tc.dispatch {
					case "lost":
						panic(http.ErrAbortHandler)
					case "observe":
					default:
						w.Header().Set(coordinatorInternalRequestIDHeader, "internal-1")
					}
					io.WriteString(w, `{}`)
				case "/v1/relay-blind/status":
					json.NewEncoder(w).Encode(map[string]any{"version": "relay-blind-status-v1", "state": "terminal", "internal_request_id": "internal-1", "validated": true, "input_tokens": 4, "completion_tokens": 8, "effective_privacy_outcome": "relay_blind_satisfied", "retry_action": "do_not_resubmit"})
				case "/internal/settlement/finality":
					finalityLookups.Add(1)
					switch tc.finalityAnswer {
					case "not_found":
						w.WriteHeader(http.StatusNotFound)
						json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"code": "not_found", "message": coordinatorFinalityNotFoundMessage}})
						return
					case "error":
						w.WriteHeader(http.StatusInternalServerError)
						return
					}
					if r.URL.Query().Get("required_internal_request_id") != "internal-1" {
						t.Errorf("finality lookup not bound to the status internal request id: %s", r.URL.RawQuery)
					}
					body := map[string]any{"request_id": r.URL.Query().Get("request_id"), "required_internal_request_id": "internal-1"}
					for k, v := range tc.finality {
						body[k] = v
					}
					json.NewEncoder(w).Encode(body)
				default:
					w.WriteHeader(http.StatusNotFound)
				}
			}))
			defer upstream.Close()
			h, store, path, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				c.Features.RelayBlindRequests.Enabled = true
				c.Coordinator.BuyerURL = upstream.URL
				c.Coordinator.OperatorURL = upstream.URL
			})
			key := createAccountAndKey(t, store, cfg, "relay-blind-enforce")
			request := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewReader(raw))
			request.Header.Set("Authorization", "Bearer "+key)
			request.Header.Set("X-Request-ID", "123e4567-e89b-42d3-a456-426614174088")
			w := httptest.NewRecorder()
			h.ServeHTTP(w, request)
			if w.Code != 500 || !strings.Contains(w.Body.String(), "do_not_resubmit") {
				t.Fatalf("unexpected response %d %s", w.Code, w.Body.String())
			}
			recovered := New(cfg, store, fakeOAuth{}, WithNow(fixedNow))
			summary, err := recovered.ReconcileSettlementHolds(context.Background(), 100)
			if err != nil {
				t.Fatal(err)
			}
			if tc.noFinalityLookup && finalityLookups.Load() != 0 {
				t.Fatalf("observe dispatch consulted coordinator finality %d times", finalityLookups.Load())
			}
			if !tc.wantResult(summary) {
				t.Fatalf("summary=%+v", summary)
			}
			used, held, err := store.DailyUsage(context.Background(), "relay-blind-enforce", fixedNow().Format("2006-01-02"))
			if err != nil || used != tc.wantUsed || held != tc.wantHeld {
				t.Fatalf("used=%d held=%d err=%v, want used=%d held=%d", used, held, err, tc.wantUsed, tc.wantHeld)
			}
			if tc.wantUsed > 0 {
				db, err := sql.Open("sqlite", path)
				if err != nil {
					t.Fatal(err)
				}
				defer db.Close()
				var outcome string
				want := "relay_blind_recovered"
				if summary.RelayBlindSettled == 1 {
					want = "spec022_relay_blind_settled"
				}
				if err := db.QueryRow(`SELECT outcome FROM usage_events WHERE account_id = 'relay-blind-enforce'`).Scan(&outcome); err != nil || outcome != want {
					t.Fatalf("usage outcome=%q err=%v, want %s", outcome, err, want)
				}
			}
		})
	}
}

// SPEC-022 R-10.7: buyer disclosure names relay_blind_settled as its own
// charged lane, never as verified, and the SPEC-041-R001 label stays.
func TestRelayBlindSettlementDisclosureNeverClaimsVerified(t *testing.T) {
	outcomes := makeVerifiedModelSettlementDisclosure(false, false).Outcomes
	if !strings.Contains(outcomes.RelayBlindSettled, "relay-blind settlement lane") ||
		!strings.Contains(outcomes.RelayBlindSettled, "provider-signed and capped by the buyer's declared bounds") ||
		!strings.Contains(outcomes.RelayBlindSettled, "never reported as verified") {
		t.Fatalf("relay_blind_settled disclosure=%q", outcomes.RelayBlindSettled)
	}
	if got := relayBlindDisclosureUnavailable().Settlement.VerifiedModelSettlement; got != "unavailable_for_relay_blind_request" {
		t.Fatalf("relay-blind verified_model_settlement=%q", got)
	}
}
