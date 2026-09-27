package router

import (
	"database/sql"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// #1690 VM e2e F-1: a negotiating coordinator records a 200 after its body
// write, so it can count the attempt as delivered and credit the provider
// while the hop to the gateway breaks after the body, before the declared
// trailers arrive. The gateway must not refund locally: it holds, and the
// reconciler settles the buyer to the coordinator's finality, pin on or off.
// The buyer got a 502 and none of the completion, so the debit is bounded
// by what the gateway delivered (SPEC-022 R-5.6): the coordinator's prompt,
// 0 completion. Observe mode settles the gateway's own tuple, also 0
// completion.
func TestDropAfterBodySettlesToCoordinatorFinality(t *testing.T) {
	for _, tc := range []struct {
		name    string
		stream  bool
		pin     bool
		mode    string
		outcome string
	}{
		{name: "nonstream pin off verified", mode: "enforce", outcome: "verified"},
		{name: "nonstream pin on verified", pin: true, mode: "enforce", outcome: "verified"},
		{name: "nonstream pin off quarantined", mode: "enforce", outcome: "quarantined"},
		{name: "nonstream pin on quarantined", pin: true, mode: "enforce", outcome: "quarantined"},
		{name: "nonstream pin off observe", mode: "observe", outcome: "verified"},
		{name: "stream pin off verified", stream: true, mode: "enforce", outcome: "verified"},
		{name: "stream pin on verified", stream: true, pin: true, mode: "enforce", outcome: "verified"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			coordinator := httptest.NewServer(dropAfterBodyCoordinator(t, tc.stream, func(w http.ResponseWriter, r *http.Request) {
				result := "valid"
				if tc.outcome != "verified" {
					result = "invalid"
				}
				writeJSON(w, http.StatusOK, map[string]any{
					"required_internal_request_id": r.URL.Query().Get("required_internal_request_id"),
					"request_id":                   r.URL.Query().Get("request_id"),
					"policy_version":               settlementPolicyVersion, "mode": tc.mode, "mode_scope_complete": true,
					"outcome": tc.outcome, "receipt_result": result, "closed": true, "reason": "drop_after_body",
					"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7,
					"token_source": "coordinator_observed", "verified_attempts": 1,
					"pending_deadline_unix_ms": fixedNow().Add(5 * time.Minute).UnixMilli(),
				})
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
			resp := postChat(t, h, fullKey, dropAfterBodyChatBody(tc.stream), nil)
			if !tc.stream && resp.Code != http.StatusBadGateway {
				t.Fatalf("status=%d body=%s, want 502", resp.Code, resp.Body.String())
			}
			snap := gatewaySettlementSnapshot(t, dbPath, accountID)
			if snap.refundedRows != 0 || snap.usageRows != 0 || snap.heldRows != 1 {
				t.Fatalf("after the dropped hop: %+v, want a held reservation, no refund and no debit", snap)
			}
			reconcileSettlementHolds(t, h)
			snap = gatewaySettlementSnapshot(t, dbPath, accountID)
			if tc.outcome != "verified" {
				wantRefunded(t, snap)
				return
			}
			if snap.usageRows != 1 || snap.settledRows != 1 || snap.activeRows != 0 {
				t.Fatalf("after reconcile: %+v, want one bounded debit", snap)
			}
			_, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID)
			switch {
			case tc.stream:
				// The stream body was forwarded to the buyer before the hop
				// broke: the delivered completion is billable.
				if source != "coordinator_observed" || prompt != 3 || completion != 4 {
					t.Fatalf("stream debit=%s/%d/%d, want the coordinator finality 3/4", source, prompt, completion)
				}
			case tc.mode == "observe":
				if source != "gateway_estimated" || completion != 0 {
					t.Fatalf("observe debit=%s/%d/%d, want the gateway tuple with 0 completion", source, prompt, completion)
				}
			default:
				if source != "coordinator_observed" || prompt != 3 || completion != 0 {
					t.Fatalf("debit=%s/%d/%d, want the coordinator prompt 3 and 0 completion: the buyer got a 502 and none of the completion", source, prompt, completion)
				}
			}
		})
	}
}

// A body_read_failed hold whose coordinator never recorded the attempt (it
// crashed between the write and the record) gets the coordinator's own
// "Settlement finality not found" forever. Under the #1763 model it moves to
// operator review, still active and held with no debit and no refund, once
// such answers span settlementCoordinator404OperatorReviewAge from the FIRST
// one: not from the reservation's creation. A generic 404 (a proxy, a wrong
// operator URL, an unavailable billing store) never starts that clock.
func TestDropAfterBodyCoordinator404HoldMovesToOperatorReview(t *testing.T) {
	authoritative := func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"code": "not_found", "message": "Settlement finality not found"}})
	}
	for _, tc := range []struct {
		name   string
		lookup http.HandlerFunc
		review bool
	}{
		{name: "authoritative not found", lookup: authoritative, review: true},
		{name: "generic 404", lookup: func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) }},
		{name: "billing store unavailable", lookup: func(w http.ResponseWriter, r *http.Request) {
			writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"code": "not_found", "message": "Settlement finality is unavailable"}})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var clock atomic.Value
			clock.Store(fixedNow())
			now := func() time.Time { return clock.Load().(time.Time) }
			coordinator := httptest.NewServer(dropAfterBodyCoordinator(t, false, tc.lookup))
			defer coordinator.Close()
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = coordinator.URL
				cfg.Coordinator.OperatorURL = coordinator.URL
				cfg.Coordinator.ServiceToken = testKey
				cfg.Coordinator.RequireSettlementTrailers = true
				// No background nudge: only the explicit reconciles below
				// observe 404s, at the clock times the test sets.
				cfg.Settlement.ReconcileEnabled = false
			}, WithHTTPClient(coordinator.Client()), WithNow(now))
			accountID := "acct_drop_404_" + strings.ReplaceAll(tc.name, " ", "_")
			fullKey := createAccountAndKey(t, store, cfg, accountID)
			if resp := postChat(t, h, fullKey, dropAfterBodyChatBody(false), nil); resp.Code != http.StatusBadGateway {
				t.Fatalf("status=%d body=%s, want 502", resp.Code, resp.Body.String())
			}
			heldNoMoney := func(when string) {
				t.Helper()
				if snap := gatewaySettlementSnapshot(t, dbPath, accountID); snap.heldRows != 1 || snap.staleHeldRows != 0 || snap.refundedRows != 0 || snap.usageRows != 0 {
					t.Fatalf("%s: %+v, want the hold kept with no debit or refund", when, snap)
				}
			}
			// The first 404 arrives on an already old reservation: that
			// alone must not move it to review.
			firstLookup := fixedNow().Add(2 * time.Hour)
			clock.Store(firstLookup)
			reconcileSettlementHolds(t, h)
			heldNoMoney("first 404 on a 2 h old reservation")
			if dropAfterBodyOperatorReview(t, dbPath, accountID) {
				t.Fatal("first 404 moved the hold to operator review")
			}
			// Past the review age and past every backoff window.
			clock.Store(firstLookup.Add(settlementCoordinator404OperatorReviewAge + 3*time.Hour))
			reconcileSettlementHolds(t, h)
			heldNoMoney("404s spanning the review age")
			if got := dropAfterBodyOperatorReview(t, dbPath, accountID); got != tc.review {
				t.Fatalf("operator_review=%v, want %v", got, tc.review)
			}
		})
	}
}

func dropAfterBodyOperatorReview(t *testing.T, dbPath, accountID string) bool {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM settlement_reconcile_attempts WHERE account_id = ? AND operator_review = 1`, accountID).Scan(&n); err != nil {
		t.Fatalf("query operator review: %v", err)
	}
	return n > 0
}

// dropAfterBodyCoordinator answers chat with a negotiated 200 (declared
// finality trailers) and breaks the connection after the body, before the
// chunked terminator and the trailers; finality lookups go to lookup.
func dropAfterBodyCoordinator(t *testing.T, stream bool, lookup http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/internal/settlement/finality" {
			lookup(w, r)
			return
		}
		if r.URL.Path != "/v1/chat/completions" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set(coordinatorInternalRequestIDHeader, testInternal)
		w.Header().Set("Trailer", strings.Join(settlementFinalityHeaderNamesForTest(), ", "))
		w.Header().Add("Trailer", settlementFinalityMACHeader)
		if stream {
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			_, _ = io.WriteString(w, trailerTestSSE)
		} else {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = io.WriteString(w, trailerTestCompletion)
		}
		w.(http.Flusher).Flush()
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Errorf("hijack: %v", err)
			return
		}
		_ = conn.Close()
	}
}

func dropAfterBodyChatBody(stream bool) string {
	if stream {
		return `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	}
	return `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
}

func reconcileSettlementHolds(t *testing.T, h http.Handler) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/admin/settlement/reconcile?limit=10", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("reconcile=%d %s", rec.Code, rec.Body.String())
	}
}
