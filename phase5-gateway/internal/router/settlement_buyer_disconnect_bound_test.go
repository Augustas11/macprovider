package router

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

// E2E-F4 (SPEC-022 R-5.6): a fast engine finished the whole generation
// before the gateway saw the buyer disconnect. The coordinator's verified
// finality counts the 700 tokens delivered to the gateway; the gateway held
// the reservation as client_disconnect with the 4 tokens it delivered to the
// buyer. The reconciler debits the buyer the smaller completion, keeping the
// coordinator's prompt. Before the fix it debited all 700.
func TestSettlementReconcileBoundsVerifiedCompletionByBuyerDelivery(t *testing.T) {
	for _, tc := range []struct {
		name           string
		outcome        string
		candidate      int64
		wantCompletion int64
	}{
		{name: "client-disconnect", outcome: "client_disconnect", candidate: 4, wantCompletion: 4},
		{name: "client-disconnect-candidate-above-finality", outcome: "client_disconnect", candidate: 750, wantCompletion: 700},
		{name: "completed-stream", outcome: "unverified_streaming", candidate: 4, wantCompletion: 700},
	} {
		t.Run(tc.name, func(t *testing.T) {
			accountID := "acct_f4_" + tc.outcome
			requestID := "req_f4_" + tc.name
			internalRequestID := "internal_f4_" + tc.name
			coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_ = json.NewEncoder(w).Encode(coordinatorRequestSettlementFinality{
					RequestID:                 requestID,
					RequiredInternalRequestID: internalRequestID,
					Mode:                      "enforce",
					PolicyVersion:             settlementPolicyVersion,
					Outcome:                   "verified",
					ReceiptResult:             "valid",
					Reason:                    "verified_settlement",
					Closed:                    true,
					ModeScopeComplete:         true,
					PromptTokens:              30,
					CompletionTokens:          700,
					TotalTokens:               730,
					TokenSource:               "coordinator_observed",
					VerifiedAttempts:          1,
				})
			}))
			defer coordinator.Close()
			h, store, dbPath, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.OperatorURL = coordinator.URL
				cfg.Coordinator.OperatorKey = "operator-key"
				cfg.Coordinator.ServiceToken = "service-token"
			}, WithHTTPClient(coordinator.Client()))
			ctx := context.Background()
			createdAt := fixedNow()
			if err := store.CreateAccount(ctx, storage.Account{
				AccountID: accountID, Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: createdAt,
			}); err != nil {
				t.Fatal(err)
			}
			window := createdAt.UTC().Format("2006-01-02")
			if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
				AccountID: accountID, RequestID: requestID, WindowDate: window,
				RequestedTokens: 800, DailyQuota: 10000, CreatedAt: createdAt, ExpiresAt: createdAt.Add(time.Minute),
			}); err != nil {
				t.Fatal(err)
			}
			if err := store.MarkReservationSettlementHold(ctx, accountID, requestID); err != nil {
				t.Fatal(err)
			}
			if err := store.SaveSettlementFallbackCandidate(ctx, storage.SettlementFallbackCandidate{
				AccountID: accountID, RequestID: requestID, RequiredInternalRequestID: internalRequestID,
				ReservationCreatedAt: createdAt, WindowDate: window, PromptTokens: 12, CompletionTokens: tc.candidate,
				MaxTotalTokens: 800, TokenSource: "gateway_estimated", Outcome: tc.outcome,
			}); err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodPost, "/admin/settlement/reconcile?limit=10", nil)
			req.Header.Set("Authorization", "Bearer operator-key")
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			db, err := sql.Open("sqlite", dbPath)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			var prompt, completion, total int64
			var source string
			if err := db.QueryRow(`SELECT prompt_tokens, completion_tokens, total_tokens, token_source FROM usage_events WHERE account_id = ? AND request_id = ?`, accountID, requestID).
				Scan(&prompt, &completion, &total, &source); err != nil {
				t.Fatal(err)
			}
			if prompt != 30 || completion != tc.wantCompletion || total != 30+tc.wantCompletion || source != "coordinator_observed" {
				t.Fatalf("usage row prompt=%d completion=%d total=%d source=%q, want 30/%d/%d/coordinator_observed",
					prompt, completion, total, source, tc.wantCompletion, 30+tc.wantCompletion)
			}
		})
	}
}
