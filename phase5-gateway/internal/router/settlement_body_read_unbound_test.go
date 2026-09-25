package router

import (
	"database/sql"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// #1690 codex R2 CODE HIGH: a body_read_failed hold is only resolvable when
// its reconcile candidate is persisted with the coordinator's internal
// request id. Without one the reconciler would keep the hold forever and
// the age-out never runs, so the gateway falls back to the refund instead.
func TestBodyReadFailureWithoutResolvableCandidateRefunds(t *testing.T) {
	for _, tc := range []struct {
		name       string
		internalID string
		breakStore bool
	}{
		{name: "no coordinator internal request id"},
		{name: "candidate persistence fails", internalID: testInternal, breakStore: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/v1/chat/completions" {
					w.WriteHeader(http.StatusNotFound)
					return
				}
				if tc.internalID != "" {
					w.Header().Set(coordinatorInternalRequestIDHeader, tc.internalID)
				}
				w.Header().Set("Trailer", strings.Join(settlementFinalityHeaderNamesForTest(), ", "))
				w.Header().Add("Trailer", settlementFinalityMACHeader)
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusOK)
				_, _ = io.WriteString(w, trailerTestCompletion)
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
				cfg.Settlement.ReconcileEnabled = false
			}, WithHTTPClient(coordinator.Client()))
			accountID := "acct_body_read_unbound_" + strings.ReplaceAll(tc.name, " ", "_")
			fullKey := createAccountAndKey(t, store, cfg, accountID)
			if tc.breakStore {
				db, err := sql.Open("sqlite", dbPath)
				if err != nil {
					t.Fatal(err)
				}
				if _, err := db.Exec(`DROP TABLE settlement_fallback_candidates`); err != nil {
					t.Fatal(err)
				}
				_ = db.Close()
			}
			if resp := postChat(t, h, fullKey, dropAfterBodyChatBody(false), nil); resp.Code != http.StatusBadGateway {
				t.Fatalf("status=%d body=%s, want 502", resp.Code, resp.Body.String())
			}
			snap := gatewaySettlementSnapshot(t, dbPath, accountID)
			if snap.heldRows != 0 || snap.activeRows != 0 || snap.refundedRows != 1 || snap.usageRows != 0 {
				t.Fatalf("snapshot=%+v, want the refund and no unresolvable hold", snap)
			}
		})
	}
}
