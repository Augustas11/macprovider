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

// SPEC-022 R-12.6a (#1690): #1728 hold recovery settles a verified Trusted
// Pool request whose finality reports pool_operator_attested, and records it
// under that source, never as coordinator_observed.
func TestSettlementReconcileSettlesPoolOperatorAttestedFinality(t *testing.T) {
	const (
		accountID         = "acct_pool_finality"
		requestID         = "req_pool_finality"
		internalRequestID = "internal_pool_finality"
	)
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
			PromptTokens:              4,
			CompletionTokens:          5,
			TotalTokens:               9,
			TokenSource:               "pool_operator_attested",
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
		RequestedTokens: 10, DailyQuota: 100, CreatedAt: createdAt, ExpiresAt: createdAt.Add(time.Minute),
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveSettlementFallbackCandidate(ctx, storage.SettlementFallbackCandidate{
		AccountID: accountID, RequestID: requestID, RequiredInternalRequestID: internalRequestID,
		ReservationCreatedAt: createdAt, WindowDate: window, PromptTokens: 2, CompletionTokens: 3,
		MaxTotalTokens: 10, TokenSource: "gateway_estimated", Outcome: "unverified_streaming",
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
	var summary settlementReconcileSummary
	if err := json.Unmarshal(resp.Body.Bytes(), &summary); err != nil {
		t.Fatal(err)
	}
	if summary.Verified != 1 || summary.Errors != 0 {
		t.Fatalf("summary=%+v want one verified pool reconciliation", summary)
	}
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var source string
	var total int64
	if err := db.QueryRow(`SELECT token_source, total_tokens FROM usage_events WHERE account_id = ? AND request_id = ?`, accountID, requestID).Scan(&source, &total); err != nil {
		t.Fatal(err)
	}
	if source != "pool_operator_attested" || total != 9 {
		t.Fatalf("usage row source=%q total=%d, want pool_operator_attested/9", source, total)
	}
}

func TestFinalityTokenTotalsSettlementCapableSources(t *testing.T) {
	for source, ok := range map[string]bool{
		"coordinator_observed":   true,
		"pool_operator_attested": true,
		"provider_reported":      false,
		"byte_estimated":         false,
		"":                       false,
	} {
		_, _, _, err := finalityTokenTotals(coordinatorRequestSettlementFinality{PromptTokens: 1, CompletionTokens: 2, TokenSource: source})
		if (err == nil) != ok {
			t.Fatalf("token_source %q err=%v, want settlement-capable=%v", source, err, ok)
		}
	}
}
