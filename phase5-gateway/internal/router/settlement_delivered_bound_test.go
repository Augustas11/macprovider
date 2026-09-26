package router

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// verifiedFinalityLookup answers the reconciler's finality GET with a
// closed verified enforce tuple of prompt 3 and the given completion.
func verifiedFinalityLookup(completion int) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"required_internal_request_id": r.URL.Query().Get("required_internal_request_id"),
			"request_id":                   r.URL.Query().Get("request_id"),
			"policy_version":               settlementPolicyVersion, "mode": "enforce", "mode_scope_complete": true,
			"outcome": "verified", "receipt_result": "valid", "closed": true, "reason": "verified_settlement",
			"prompt_tokens": 3, "completion_tokens": completion, "total_tokens": 3 + completion,
			"token_source": "coordinator_observed", "verified_attempts": 1,
			"pending_deadline_unix_ms": fixedNow().Add(5 * time.Minute).UnixMilli(),
		})
	}
}

// #1690 review P-1 (pre-existing, the F-1 class on streams): the hop to the
// coordinator breaks mid-stream, so the gateway ends the stream
// stream_truncated after forwarding only part of it. The coordinator can
// still verify the provider's whole completion; the buyer's debit is
// bounded by what the gateway forwarded, as for client_disconnect.
func TestTruncatedStreamDebitIsBoundedByForwardedOutput(t *testing.T) {
	const verifiedCompletion = 400
	partial := "data: {\"id\":\"c\",\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n" +
		"data: {\"id\":\"c\",\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n"
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/internal/settlement/finality" {
			verifiedFinalityLookup(verifiedCompletion)(w, r)
			return
		}
		w.Header().Set(coordinatorInternalRequestIDHeader, testInternal)
		w.Header().Set("Trailer", strings.Join(settlementFinalityHeaderNamesForTest(), ", "))
		w.Header().Add("Trailer", settlementFinalityMACHeader)
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, partial)
		w.(http.Flusher).Flush()
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Errorf("hijack: %v", err)
			return
		}
		_ = conn.Close()
	}))
	defer coordinator.Close()
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = coordinator.URL
		cfg.Coordinator.OperatorURL = coordinator.URL
		cfg.Coordinator.ServiceToken = testKey
		cfg.Coordinator.RequireSettlementTrailers = true
	}, WithHTTPClient(coordinator.Client()))
	accountID := "acct_truncated_stream_bound"
	fullKey := createAccountAndKey(t, store, cfg, accountID)
	resp := postChat(t, h, fullKey, `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if !strings.Contains(resp.Body.String(), "provider_disconnected") {
		t.Fatalf("stream body=%q, want the provider_disconnected terminal", resp.Body.String())
	}
	reconcileSettlementHolds(t, h)
	snap := gatewaySettlementSnapshot(t, dbPath, accountID)
	if snap.usageRows != 1 || snap.settledRows != 1 {
		t.Fatalf("after reconcile: %+v, want one bounded debit", snap)
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID)
	if prompt != 3 || source != "coordinator_observed" {
		t.Fatalf("debit %s/%s prompt=%d, want the coordinator prompt 3", outcome, source, prompt)
	}
	if completion <= 0 || completion >= 100 {
		t.Fatalf("debit completion=%d, want the gateway estimate of the two forwarded frames, not the verified %d", completion, verifiedCompletion)
	}
}

// A coordinator 504 with verified header finality (the provider finished
// after the coordinator gave up on it): the buyer got a 504 and nothing
// else, so the debit is the prompt only.
func TestProviderTimeoutDebitIsBoundedByDeliveredOutput(t *testing.T) {
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/internal/settlement/finality" {
			verifiedFinalityLookup(4)(w, r)
			return
		}
		for name, values := range settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "verified", "valid", "true", "verified_settlement") {
			w.Header()[name] = values
		}
		w.Header().Set(coordinatorInternalRequestIDHeader, testInternal)
		writeJSON(w, http.StatusGatewayTimeout, map[string]any{"error": map[string]any{"code": "provider_timeout", "message": "Provider timed out"}})
	}))
	defer coordinator.Close()
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = coordinator.URL
		cfg.Coordinator.OperatorURL = coordinator.URL
		cfg.Coordinator.ServiceToken = testKey
	}, WithHTTPClient(coordinator.Client()))
	accountID := "acct_provider_timeout_bound"
	fullKey := createAccountAndKey(t, store, cfg, accountID)
	if resp := postChat(t, h, fullKey, dropAfterBodyChatBody(false), nil); resp.Code != http.StatusGatewayTimeout {
		t.Fatalf("status=%d body=%s, want 504", resp.Code, resp.Body.String())
	}
	reconcileSettlementHolds(t, h)
	snap := gatewaySettlementSnapshot(t, dbPath, accountID)
	if snap.activeRows != 0 || snap.usageRows != 1 {
		t.Fatalf("after reconcile: %+v, want one settled debit", snap)
	}
	if _, _, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID); completion != 0 || prompt != 3 {
		t.Fatalf("504 debit=%d/%d, want the prompt only", prompt, completion)
	}
}
