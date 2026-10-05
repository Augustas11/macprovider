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
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
	"github.com/augstar/macprovider-gateway/internal/storage"
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
	name string
	// finality is merged over the coordinator's default answer, which echoes
	// the lookup's request_id and required_internal_request_id. A case sets
	// relay_blind_settlement_coverage itself; without it the answer carries
	// no coverage (an older coordinator).
	finality map[string]any
	// dispatch is what the coordinator chat response carried: "marker" (the
	// generic internal request id plus the R-13 coverage marker, the
	// default), "generic" (only the generic internal request id every
	// coordinator response carries), "stripped" (neither header), or "lost"
	// (no response reached the gateway).
	dispatch string
	// statusInternalID overrides the status row's internal request id.
	statusInternalID string
	// finalityAnswer overrides the finality endpoint: "not_found" (the
	// coordinator's authoritative answer) or "error" (HTTP 500).
	finalityAnswer string
	// candidate seeds a durable buyer-delivery candidate before recovery.
	candidate  *relayBlindReconcileCandidate
	wantUsed   int64
	wantHeld   int64
	wantResult func(SettlementReconcileSummary) bool
}

type relayBlindReconcileCandidate struct {
	outcome            string
	completion         int64
	requiredInternalID string
}

func relayBlindSettledFinality(prompt, completion int64) map[string]any {
	return map[string]any{"relay_blind_settlement_coverage": "enforce", "mode": "enforce", "policy_version": settlementPolicyVersion,
		"outcome": "relay_blind_settled", "receipt_result": "valid", "reason": "relay_blind_settlement", "closed": true,
		"prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion,
		"token_source": "coordinator_observed", "relay_blind_settled_attempts": 1, "mode_scope_complete": true}
}

func withFinality(base map[string]any, overrides map[string]any) map[string]any {
	out := map[string]any{}
	for k, v := range base {
		out[k] = v
	}
	for k, v := range overrides {
		out[k] = v
	}
	return out
}

func relayBlindObserveDeclaration() map[string]any {
	return map[string]any{"relay_blind_settlement_coverage": "observe"}
}

// SPEC-022 R-13.6 / R-8.1 in the reconciler: a relay-blind hold settles from
// the coordinator's answer for its attempt, never from a header the gateway
// saw. Enforce coverage follows R-13 finality (relay_blind_settled debits,
// bounded by buyer delivery; a refund tuple refunds; anything else holds).
// Only the coordinator's explicit observe declaration runs the status-row
// recovery; not-found, errors, unbound echoes, and contradictions hold.
func TestRelayBlindReconcileFollowsEnforceFinality(t *testing.T) {
	held := func(s SettlementReconcileSummary) bool {
		return s.Held == 1 && s.Observed == 0 && s.RelayBlindSettled == 0
	}
	cases := []relayBlindReconcileCase{
		{
			name:     "relay_blind_settled without delivery evidence debits the prompt only",
			finality: relayBlindSettledFinality(3, 5),
			wantUsed: 3, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.RelayBlindSettled == 1 && s.Verified == 0 },
		},
		{
			name:      "relay_blind_settled with a delivered candidate debits coordinator usage",
			finality:  relayBlindSettledFinality(3, 5),
			candidate: &relayBlindReconcileCandidate{outcome: "ok", completion: 5, requiredInternalID: "internal-1"},
			wantUsed:  8, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.RelayBlindSettled == 1 && s.Verified == 0 },
		},
		{
			name:      "relay_blind_settled is bounded by a client disconnect candidate",
			finality:  relayBlindSettledFinality(3, 5),
			candidate: &relayBlindReconcileCandidate{outcome: "client_disconnect", completion: 2, requiredInternalID: "internal-1"},
			wantUsed:  5, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.RelayBlindSettled == 1 },
		},
		{
			name:      "a candidate bound to another attempt is not delivery evidence",
			finality:  relayBlindSettledFinality(3, 5),
			candidate: &relayBlindReconcileCandidate{outcome: "ok", completion: 5, requiredInternalID: "internal-other"},
			wantUsed:  3, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.RelayBlindSettled == 1 },
		},
		{
			name:      "a candidate with no internal request id is not delivery evidence",
			finality:  relayBlindSettledFinality(3, 5),
			candidate: &relayBlindReconcileCandidate{outcome: "ok", completion: 5, requiredInternalID: ""},
			wantUsed:  3, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.RelayBlindSettled == 1 },
		},
		{
			name: "quarantined refunds",
			finality: map[string]any{"relay_blind_settlement_coverage": "enforce", "mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "quarantined", "receipt_result": "invalid",
				"reason": "usage_mismatch", "closed": true, "quarantined_attempts": 1, "mode_scope_complete": true},
			wantUsed: 0, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Refunded == 1 },
		},
		{
			name: "withheld receipt quarantined at the deadline refunds",
			finality: map[string]any{"relay_blind_settlement_coverage": "enforce", "mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "quarantined", "receipt_result": "inconclusive",
				"reason": "missing_receipt_deadline_elapsed", "closed": true, "quarantined_attempts": 1, "mode_scope_complete": true},
			wantUsed: 0, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Refunded == 1 },
		},
		{
			name: "pending holds",
			finality: map[string]any{"relay_blind_settlement_coverage": "enforce", "mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "pending", "receipt_result": "inconclusive",
				"reason": "receipt_verdict_pending", "closed": false, "pending_attempts": 1, "mode_scope_complete": true},
			wantUsed: 0, wantHeld: 24, wantResult: held,
		},
		{
			name: "verified on a relay-blind execution holds",
			finality: map[string]any{"relay_blind_settlement_coverage": "enforce", "mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "verified", "receipt_result": "valid",
				"reason": "verified_settlement", "closed": true, "prompt_tokens": 3, "completion_tokens": 5, "total_tokens": 8,
				"token_source": "coordinator_observed", "verified_attempts": 1, "mode_scope_complete": true},
			wantUsed: 0, wantHeld: 24,
			wantResult: func(s SettlementReconcileSummary) bool { return held(s) && s.Verified == 0 },
		},
		{
			name: "enforce unrecorded attempt refunds",
			finality: map[string]any{"relay_blind_settlement_coverage": "enforce", "mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "quarantined", "receipt_result": "inconclusive",
				"reason": "relay_blind_attempt_unrecorded", "closed": true, "quarantined_attempts": 1, "mode_scope_complete": true},
			wantUsed: 0, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Refunded == 1 },
		},
		{
			name:           "coordinator not-found holds, never debits",
			finalityAnswer: "not_found", wantUsed: 0, wantHeld: 24,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Coordinator404 == 1 && held(s) },
		},
		{
			name:           "coordinator 5xx holds",
			finalityAnswer: "error", wantUsed: 0, wantHeld: 24,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Errors == 0 && held(s) },
		},
		// The generic internal request id is on every coordinator response;
		// an observe-mode coordinator answers observe explicitly.
		{
			name:     "observe dispatch with the generic id recovers on the coordinator's observe answer",
			dispatch: "generic", finality: relayBlindObserveDeclaration(),
			wantUsed: 4, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Observed == 1 },
		},
		{
			name:     "observe dispatch with coordinator not-found holds",
			dispatch: "generic", finalityAnswer: "not_found", wantUsed: 0, wantHeld: 24,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Coordinator404 == 1 && held(s) },
		},
		{
			name:     "observe dispatch with coordinator 5xx holds",
			dispatch: "generic", finalityAnswer: "error", wantUsed: 0, wantHeld: 24, wantResult: held,
		},
		{
			name:     "stripped-header enforce dispatch holds on pending finality",
			dispatch: "stripped",
			finality: map[string]any{"relay_blind_settlement_coverage": "enforce", "mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "pending", "receipt_result": "inconclusive",
				"reason": "relay_blind_attempt_pending", "closed": false, "pending_attempts": 1, "mode_scope_complete": true},
			wantUsed: 0, wantHeld: 24, wantResult: held,
		},
		{
			name:     "stripped-header dispatch with coordinator not-found holds",
			dispatch: "stripped", finalityAnswer: "not_found", wantUsed: 0, wantHeld: 24,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Coordinator404 == 1 && held(s) },
		},
		{
			name:     "lost dispatch with coordinator not-found holds",
			dispatch: "lost", finalityAnswer: "not_found", wantUsed: 0, wantHeld: 24,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Coordinator404 == 1 && held(s) },
		},
		{
			name:     "lost dispatch with finality fetch error holds",
			dispatch: "lost", finalityAnswer: "error", wantUsed: 0, wantHeld: 24, wantResult: held,
		},
		{
			name:     "lost dispatch recovers on the coordinator's observe answer",
			dispatch: "lost", finality: relayBlindObserveDeclaration(),
			wantUsed: 4, wantHeld: 0,
			wantResult: func(s SettlementReconcileSummary) bool { return s.Observed == 1 },
		},
		{
			name:     "lost dispatch with enforce finality follows it",
			dispatch: "lost",
			finality: map[string]any{"relay_blind_settlement_coverage": "enforce", "mode": "enforce", "policy_version": settlementPolicyVersion, "outcome": "pending", "receipt_result": "inconclusive",
				"reason": "relay_blind_attempt_pending", "closed": false, "pending_attempts": 1, "mode_scope_complete": true},
			wantUsed: 0, wantHeld: 24, wantResult: held,
		},
		{
			name:     "an observe answer contradicting the coverage marker holds",
			finality: relayBlindObserveDeclaration(), wantUsed: 0, wantHeld: 24, wantResult: held,
		},
		{
			name:     "a settled tuple without a coverage answer holds",
			finality: withFinality(relayBlindSettledFinality(3, 5), map[string]any{"relay_blind_settlement_coverage": ""}),
			wantUsed: 0, wantHeld: 24, wantResult: held,
		},
		{
			name:     "an incomplete mode scope holds",
			finality: withFinality(relayBlindSettledFinality(3, 5), map[string]any{"mode_scope_complete": false}),
			wantUsed: 0, wantHeld: 24, wantResult: held,
		},
		{
			name:     "a blank request_id echo holds",
			finality: withFinality(relayBlindSettledFinality(3, 5), map[string]any{"request_id": ""}),
			wantUsed: 0, wantHeld: 24, wantResult: held,
		},
		{
			name:     "a blank required_internal_request_id echo holds",
			finality: withFinality(relayBlindSettledFinality(3, 5), map[string]any{"required_internal_request_id": ""}),
			wantUsed: 0, wantHeld: 24, wantResult: held,
		},
		{
			name:     "a cross-attempt required_internal_request_id echo holds",
			finality: withFinality(relayBlindSettledFinality(3, 5), map[string]any{"required_internal_request_id": "internal-2"}),
			wantUsed: 0, wantHeld: 24, wantResult: held,
		},
		{
			name:     "a blank echo never authorizes observe recovery",
			dispatch: "generic", finality: withFinality(relayBlindObserveDeclaration(), map[string]any{"required_internal_request_id": ""}),
			wantUsed: 0, wantHeld: 24, wantResult: held,
		},
		{
			name:             "a status row naming another attempt than the marker holds",
			statusInternalID: "internal-2", finality: relayBlindSettledFinality(3, 5),
			wantUsed: 0, wantHeld: 24, wantResult: held,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res, _ := pilotReservationFixture(t, false)
			raw := pilotEnvelopeFixture(t, res)
			digest := sha256.Sum256(raw)
			digestText := base64.RawURLEncoding.EncodeToString(digest[:])
			statusInternalID := tc.statusInternalID
			if statusInternalID == "" {
				statusInternalID = "internal-1"
			}
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/v1/relay-blind/consume":
					json.NewEncoder(w).Encode(relayblind.ConsumeResponse{Version: relayblind.ConsumeVersion, ProviderBinding: res.ProviderBinding, BuyerBinding: res.BuyerBinding, EnvelopeDigest: digestText, ExecutionAuthorization: "internal-execution-authorization", ConsumedAtUnix: fixedNow().Unix(), ExpiresAtUnix: res.ExpiresAtUnix})
				case "/v1/chat/completions":
					switch tc.dispatch {
					case "lost":
						panic(http.ErrAbortHandler)
					case "stripped":
					case "generic":
						w.Header().Set(coordinatorInternalRequestIDHeader, "internal-1")
					default:
						w.Header().Set(coordinatorInternalRequestIDHeader, "internal-1")
						w.Header().Set(relayBlindSettlementCoverageHeader, "enforce")
					}
					io.WriteString(w, `{}`)
				case "/v1/relay-blind/status":
					json.NewEncoder(w).Encode(map[string]any{"version": "relay-blind-status-v1", "state": "terminal", "internal_request_id": statusInternalID, "validated": true, "input_tokens": 4, "completion_tokens": 8, "effective_privacy_outcome": "relay_blind_satisfied", "retry_action": "do_not_resubmit"})
				case "/internal/settlement/finality":
					q := r.URL.Query()
					if q.Get("required_internal_request_id") == "" || q.Get("relay_blind_envelope_digest") != digestText || q.Get("relay_blind_provider_binding_digest") == "" {
						t.Errorf("finality lookup not bound to the relay-blind attempt: %s", r.URL.RawQuery)
					}
					switch tc.finalityAnswer {
					case "not_found":
						w.WriteHeader(http.StatusNotFound)
						json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"code": "not_found", "message": coordinatorFinalityNotFoundMessage}})
						return
					case "error":
						w.WriteHeader(http.StatusInternalServerError)
						return
					}
					body := map[string]any{"request_id": q.Get("request_id"), "required_internal_request_id": q.Get("required_internal_request_id")}
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
			const externalID = "123e4567-e89b-42d3-a456-426614174088"
			request := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewReader(raw))
			request.Header.Set("Authorization", "Bearer "+key)
			request.Header.Set("X-Request-ID", externalID)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, request)
			if w.Code != 500 || !strings.Contains(w.Body.String(), "do_not_resubmit") {
				t.Fatalf("unexpected response %d %s", w.Code, w.Body.String())
			}
			if tc.candidate != nil {
				holds, err := store.ListSettlementHeldReservations(context.Background(), 10)
				if err != nil || len(holds) != 1 {
					t.Fatalf("holds=%v err=%v", holds, err)
				}
				if err := store.SaveSettlementFallbackCandidate(context.Background(), storage.SettlementFallbackCandidate{
					AccountID: "relay-blind-enforce", RequestID: externalID, RequiredInternalRequestID: tc.candidate.requiredInternalID,
					ReservationCreatedAt: holds[0].CreatedAt, WindowDate: holds[0].WindowDate, PromptTokens: 3, CompletionTokens: tc.candidate.completion,
					MaxTotalTokens: holds[0].ReservedTokens, TokenSource: "gateway_estimated", Outcome: tc.candidate.outcome,
				}); err != nil {
					t.Fatal(err)
				}
			}
			recovered := New(cfg, store, fakeOAuth{}, WithNow(fixedNow))
			summary, err := recovered.ReconcileSettlementHolds(context.Background(), 100)
			if err != nil {
				t.Fatal(err)
			}
			if !tc.wantResult(summary) {
				t.Fatalf("summary=%+v", summary)
			}
			used, heldTokens, err := store.DailyUsage(context.Background(), "relay-blind-enforce", fixedNow().Format("2006-01-02"))
			if err != nil || used != tc.wantUsed || heldTokens != tc.wantHeld {
				t.Fatalf("used=%d held=%d err=%v, want used=%d held=%d", used, heldTokens, err, tc.wantUsed, tc.wantHeld)
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
