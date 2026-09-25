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

// #1690 VM e2e F-1: a negotiating coordinator records a 200 after its body
// write, so it can count the attempt as delivered and credit the provider
// while the hop to the gateway breaks after the body, before the declared
// trailers arrive. The gateway must not refund locally: it holds, and the
// reconciler settles the buyer to the coordinator's finality, pin on or off.
func TestDropAfterBodySettlesToCoordinatorFinality(t *testing.T) {
	for _, tc := range []struct {
		name    string
		stream  bool
		pin     bool
		outcome string
	}{
		{name: "nonstream pin off verified", outcome: "verified"},
		{name: "nonstream pin on verified", pin: true, outcome: "verified"},
		{name: "nonstream pin off quarantined", outcome: "quarantined"},
		{name: "nonstream pin on quarantined", pin: true, outcome: "quarantined"},
		{name: "stream pin off verified", stream: true, outcome: "verified"},
		{name: "stream pin on verified", stream: true, pin: true, outcome: "verified"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/internal/settlement/finality" {
					result := "valid"
					if tc.outcome != "verified" {
						result = "invalid"
					}
					writeJSON(w, http.StatusOK, map[string]any{
						"required_internal_request_id": r.URL.Query().Get("required_internal_request_id"),
						"request_id":                   r.URL.Query().Get("request_id"),
						"policy_version":               settlementPolicyVersion, "mode": "enforce", "mode_scope_complete": true,
						"outcome": tc.outcome, "receipt_result": result, "closed": true, "reason": "drop_after_body",
						"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7,
						"token_source": "coordinator_observed", "verified_attempts": 1,
						"pending_deadline_unix_ms": fixedNow().Add(5 * time.Minute).UnixMilli(),
					})
					return
				}
				if r.URL.Path != "/v1/chat/completions" {
					w.WriteHeader(http.StatusNotFound)
					return
				}
				w.Header().Set(coordinatorInternalRequestIDHeader, testInternal)
				w.Header().Set("Trailer", strings.Join(settlementFinalityHeaderNamesForTest(), ", "))
				w.Header().Add("Trailer", settlementFinalityMACHeader)
				if tc.stream {
					w.Header().Set("Content-Type", "text/event-stream")
					w.WriteHeader(http.StatusOK)
					_, _ = io.WriteString(w, trailerTestSSE)
				} else {
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusOK)
					_, _ = io.WriteString(w, trailerTestCompletion)
				}
				w.(http.Flusher).Flush()
				// Break the hop after the body, before the chunked terminator
				// and the trailers.
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
				cfg.Coordinator.RequireSettlementTrailers = tc.pin
			}, WithHTTPClient(coordinator.Client()))
			accountID := "acct_drop_" + strings.ReplaceAll(tc.name, " ", "_")
			fullKey := createAccountAndKey(t, store, cfg, accountID)
			body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
			if tc.stream {
				body = `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
			}
			resp := postChat(t, h, fullKey, body, nil)
			if !tc.stream && resp.Code != http.StatusBadGateway {
				t.Fatalf("status=%d body=%s, want 502", resp.Code, resp.Body.String())
			}
			snap := gatewaySettlementSnapshot(t, dbPath, accountID)
			if snap.refundedRows != 0 || snap.usageRows != 0 || snap.heldRows != 1 {
				t.Fatalf("after the dropped hop: %+v, want a held reservation, no refund and no debit", snap)
			}
			reconcile := httptest.NewRequest(http.MethodPost, "/admin/settlement/reconcile?limit=10", nil)
			reconcile.Header.Set("Authorization", "Bearer operator-key")
			reconciled := httptest.NewRecorder()
			h.ServeHTTP(reconciled, reconcile)
			if reconciled.Code != http.StatusOK {
				t.Fatalf("reconcile=%d %s", reconciled.Code, reconciled.Body.String())
			}
			snap = gatewaySettlementSnapshot(t, dbPath, accountID)
			if tc.outcome == "verified" {
				if snap.usageRows != 1 || snap.settledRows != 1 || snap.activeRows != 0 {
					t.Fatalf("after reconcile: %+v, want the coordinator-verified debit", snap)
				}
				_, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID)
				if source != "coordinator_observed" || prompt != 3 || completion != 4 {
					t.Fatalf("debit=%s/%d/%d, want the coordinator finality 3/4", source, prompt, completion)
				}
				return
			}
			wantRefunded(t, snap)
		})
	}
}
