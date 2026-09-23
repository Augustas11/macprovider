package router

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

func TestObserveFallbackRecoverySurvivesOutageAndRestart(t *testing.T) {
	for _, demo := range []bool{false, true} {
		t.Run(strconv.FormatBool(demo), func(t *testing.T) {
			ctx := context.Background()
			created := fixedNow()
			var status atomic.Int32
			status.Store(http.StatusServiceUnavailable)
			coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/internal/settlement/finality" || r.Header.Get("Authorization") != "Bearer service-token" ||
					r.URL.Query().Get("account_id") != "acct_observe" || r.URL.Query().Get("request_id") != "req_observe" ||
					r.URL.Query().Get("required_internal_request_id") != "internal_req_observe" ||
					r.URL.Query().Get("reservation_created_at_unix_ms") != strconv.FormatInt(created.UnixMilli(), 10) {
					t.Error("finality lookup missing authenticated reservation scope")
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				if code := int(status.Load()); code != http.StatusOK {
					w.WriteHeader(code)
					return
				}
				_ = json.NewEncoder(w).Encode(coordinatorRequestSettlementFinality{
					RequestID: "req_observe", Mode: "observe", ModeScopeComplete: true, PolicyVersion: settlementPolicyVersion,
					RequiredInternalRequestID: "internal_req_observe",
					Outcome:                   "verified", ReceiptResult: "valid", Reason: "verified_settlement", Closed: true,
					PromptTokens: 40, CompletionTokens: 50, TotalTokens: 90, TokenSource: "coordinator_observed", VerifiedAttempts: 1,
				})
			}))
			defer coordinator.Close()
			cfg := baselineValidConfig(t)
			cfg.Coordinator.OperatorURL = coordinator.URL
			cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
			store, err := sqlite.Open(ctx, cfg.Storage.DBPath)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = store.Close() }()
			if err := store.CreateAccount(ctx, storage.Account{
				AccountID: "acct_observe", Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: created,
			}); err != nil {
				t.Fatal(err)
			}
			window := created.Format("2006-01-02")
			if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
				AccountID: "acct_observe", RequestID: "req_observe", WindowDate: window,
				RequestedTokens: 10, DailyQuota: 100, CreatedAt: created, ExpiresAt: created.Add(time.Minute),
			}); err != nil {
				t.Fatal(err)
			}
			candidate := storage.SettlementFallbackCandidate{
				AccountID: "acct_observe", RequestID: "req_observe", ReservationCreatedAt: created,
				RequiredInternalRequestID: "internal_req_observe",
				WindowDate:                window, PromptTokens: 2, CompletionTokens: 3, MaxTotalTokens: 10,
				TokenSource: "gateway_estimated", Outcome: "unverified_streaming",
			}
			if demo {
				candidate.DemoIdentity, candidate.DemoTokenHash = "192.0.2.10", "synthetic-demo-hash"
			}
			if err := store.SaveSettlementFallbackCandidate(ctx, candidate); err != nil {
				t.Fatal(err)
			}
			// Reconcile after the fallback TTL; neither an outage nor a 404
			// may make a delivered local tuple permanently undiscoverable.
			now := created.Add(24 * time.Hour)
			server := New(cfg, store, fakeOAuth{}, WithNow(func() time.Time { return now }))
			if summary, err := server.ReconcileSettlementHolds(ctx, 10); err != nil || summary.Errors != 1 || summary.StaleHeld != 0 {
				t.Fatalf("outage summary=%+v err=%v", summary, err)
			}
			status.Store(http.StatusNotFound)
			if summary, err := server.ReconcileSettlementHolds(ctx, 10); err != nil || summary.Held != 1 || summary.Coordinator404 != 1 || summary.StaleHeld != 0 {
				t.Fatalf("missing summary=%+v err=%v", summary, err)
			}
			if n, err := store.ReapExpiredReservations(ctx, now); err != nil || n != 0 {
				t.Fatalf("reaped=%d err=%v", n, err)
			}
			if err := store.Close(); err != nil {
				t.Fatal(err)
			}
			store, err = sqlite.Open(ctx, cfg.Storage.DBPath)
			if err != nil {
				t.Fatal(err)
			}
			server = New(cfg, store, fakeOAuth{}, WithNow(func() time.Time { return now }))
			status.Store(http.StatusOK)
			if summary, err := server.ReconcileSettlementHolds(ctx, 10); err != nil || summary.Observed != 1 || summary.Verified != 0 {
				t.Fatalf("recovered summary=%+v err=%v", summary, err)
			}
			if summary, err := server.ReconcileSettlementHolds(ctx, 10); err != nil || summary.Scanned != 0 {
				t.Fatalf("repeat summary=%+v err=%v", summary, err)
			}
			used, reserved, err := store.DailyUsage(ctx, candidate.AccountID, window)
			if err != nil || used != 5 || reserved != 0 {
				t.Fatalf("used=%d reserved=%d err=%v", used, reserved, err)
			}
			db, err := sql.Open("sqlite", cfg.Storage.DBPath)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			var count, prompt, completion int64
			var source, outcome, gotWindow string
			if err := db.QueryRow(`SELECT COUNT(*), prompt_tokens, completion_tokens, token_source, outcome, window_date FROM usage_events`).Scan(
				&count, &prompt, &completion, &source, &outcome, &gotWindow); err != nil || count != 1 || prompt != 2 || completion != 3 ||
				source != candidate.TokenSource || outcome != candidate.Outcome || gotWindow != window {
				t.Fatalf("local usage count=%d tokens=%d/%d source=%q outcome=%q window=%q err=%v", count, prompt, completion, source, outcome, gotWindow, err)
			}
			if demo {
				var total int64
				if err := db.QueryRow(`SELECT COUNT(*), total_tokens FROM demo_usage_events WHERE demo_token_hash = ?`, candidate.DemoTokenHash).Scan(&count, &total); err != nil || count != 1 || total != 5 {
					t.Fatalf("demo usage count=%d total=%d err=%v", count, total, err)
				}
			}
		})
	}
}

func TestSettlementReconcileWithoutCurrentAttemptBindingRejectsPriorFinality(t *testing.T) {
	for _, outcome := range []string{"verified", "quarantined"} {
		t.Run(outcome, func(t *testing.T) {
			var coordinatorCalls atomic.Int32
			coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				coordinatorCalls.Add(1)
				_ = json.NewEncoder(w).Encode(coordinatorRequestSettlementFinality{
					RequestID:                 "req_unbound_current_attempt",
					RequiredInternalRequestID: "internal_prior_attempt",
					Mode:                      "enforce",
					PolicyVersion:             settlementPolicyVersion,
					Outcome:                   outcome,
					ReceiptResult:             "valid",
					Reason:                    "prior_attempt_finality",
					Closed:                    true,
					PromptTokens:              4,
					CompletionTokens:          5,
					TotalTokens:               9,
					TokenSource:               "coordinator_observed",
					VerifiedAttempts:          1,
				})
			}))
			defer coordinator.Close()

			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.OperatorURL = coordinator.URL
				cfg.Coordinator.OperatorKey = "operator-key"
				cfg.Coordinator.ServiceToken = "service-token"
			}, WithHTTPClient(coordinator.Client()))
			createdAt := fixedNow()
			if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
				AccountID:       "acct_unbound_current_attempt",
				RequestID:       "req_unbound_current_attempt",
				WindowDate:      createdAt.UTC().Format("2006-01-02"),
				RequestedTokens: 10,
				DailyQuota:      cfg.Quotas.AccountDailyTokens,
				CreatedAt:       createdAt,
				ExpiresAt:       createdAt.Add(time.Minute),
			}); err != nil {
				t.Fatal(err)
			}
			if err := store.MarkReservationSettlementHold(context.Background(), "acct_unbound_current_attempt", "req_unbound_current_attempt"); err != nil {
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
			if summary.Scanned != 1 || summary.Held != 1 || summary.Verified != 0 || summary.Refunded != 0 || summary.Errors != 0 {
				t.Fatalf("summary=%+v, want unbound reservation held without finality", summary)
			}
			if calls := coordinatorCalls.Load(); calls != 0 {
				t.Fatalf("coordinator calls=%d want 0 for unbound current attempt", calls)
			}
			state := gatewaySettlementSnapshot(t, dbPath, "acct_unbound_current_attempt")
			if state.activeRows != 1 || state.heldRows != 1 || state.usageRows != 0 || state.settledRows != 0 || state.refundedRows != 0 {
				t.Fatalf("settlement state=%+v, want current reservation quarantined", state)
			}
		})
	}
}

func TestSettlementReconcileVerifiedDemoWritesDemoAuditRow(t *testing.T) {
	const (
		accountID         = "demo:192.0.2.25"
		requestID         = "req_demo_verified_reconcile"
		internalRequestID = "internal_demo_verified_reconcile"
		demoIdentity      = "192.0.2.25"
		demoTokenHash     = "demo-token-hash-verified"
	)
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("required_internal_request_id"); got != internalRequestID {
			t.Fatalf("required_internal_request_id=%q want %q", got, internalRequestID)
		}
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
			TokenSource:               "coordinator_observed",
			VerifiedAttempts:          1,
		})
	}))
	defer coordinator.Close()

	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
		cfg.Coordinator.OperatorKey = "operator-key"
		cfg.Coordinator.ServiceToken = "service-token"
	}, WithHTTPClient(coordinator.Client()))
	createdAt := fixedNow()
	window := createdAt.UTC().Format("2006-01-02")
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID,
		RequestID:       requestID,
		WindowDate:      window,
		RequestedTokens: 10,
		DailyQuota:      cfg.Quotas.DemoDailyTokensPerIP,
		CreatedAt:       createdAt,
		ExpiresAt:       createdAt.Add(time.Minute),
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveSettlementFallbackCandidate(context.Background(), storage.SettlementFallbackCandidate{
		AccountID:                 accountID,
		RequestID:                 requestID,
		RequiredInternalRequestID: internalRequestID,
		ReservationCreatedAt:      createdAt,
		DemoIdentity:              demoIdentity,
		DemoTokenHash:             demoTokenHash,
		WindowDate:                window,
		PromptTokens:              2,
		CompletionTokens:          3,
		MaxTotalTokens:            10,
		TokenSource:               "gateway_estimated",
		Outcome:                   "unverified_streaming",
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
		t.Fatalf("summary=%+v want one verified demo reconciliation", summary)
	}
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var count, total int64
	if err := db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(total_tokens), 0) FROM demo_usage_events WHERE request_id = ? AND demo_token_hash = ?`, requestID, demoTokenHash).Scan(&count, &total); err != nil {
		t.Fatal(err)
	}
	if count != 1 || total != 9 {
		t.Fatalf("demo audit rows=%d total=%d want 1/9", count, total)
	}
}

func TestObserveFallbackAuthorityIsCompleteAndClosed(t *testing.T) {
	base := coordinatorRequestSettlementFinality{
		RequestID: "req", Mode: "observe", ModeScopeComplete: true, PolicyVersion: settlementPolicyVersion,
		RequiredInternalRequestID: "internal_req",
		Outcome:                   "verified", ReceiptResult: "valid", Closed: true,
	}
	for _, tc := range []struct {
		name string
		edit func(*coordinatorRequestSettlementFinality)
		want bool
	}{
		{"verified", func(*coordinatorRequestSettlementFinality) {}, true},
		{"old_coordinator", func(f *coordinatorRequestSettlementFinality) { f.ModeScopeComplete = false }, false},
		{"missing_request", func(f *coordinatorRequestSettlementFinality) { f.RequestID = "" }, false},
		{"missing_internal_request", func(f *coordinatorRequestSettlementFinality) { f.RequiredInternalRequestID = "" }, false},
		{"enforce", func(f *coordinatorRequestSettlementFinality) { f.Mode = "enforce" }, false},
		{"unknown_policy", func(f *coordinatorRequestSettlementFinality) { f.PolicyVersion = "unknown" }, false},
		{"mixed", func(f *coordinatorRequestSettlementFinality) { f.Reason = "mixed_settlement_policy_snapshot" }, false},
		{"missing_scope", func(f *coordinatorRequestSettlementFinality) { f.Reason = "missing_current_settlement_finality" }, false},
		{"incomplete", func(f *coordinatorRequestSettlementFinality) { f.Closed = false }, false},
		{"invalid_receipt", func(f *coordinatorRequestSettlementFinality) { f.ReceiptResult = "invalid" }, false},
		{"unknown_outcome", func(f *coordinatorRequestSettlementFinality) { f.Outcome = "other" }, false},
		{"pending", func(f *coordinatorRequestSettlementFinality) {
			f.Outcome, f.ReceiptResult, f.Reason, f.Closed, f.PendingAttempts = "pending", "inconclusive", "receipt_verdict_pending", false, 1
		}, true},
		{"unknown_pending", func(f *coordinatorRequestSettlementFinality) {
			f.Outcome, f.ReceiptResult, f.Reason, f.Closed, f.PendingAttempts = "pending", "inconclusive", "other", false, 1
		}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			finality := base
			tc.edit(&finality)
			if got := coordinatorObserveFallbackAllowed(finality); got != tc.want {
				t.Fatalf("allowed=%t want=%t", got, tc.want)
			}
		})
	}
}

func TestObserveFallbackSavedCandidateCannotOverrideAuthority(t *testing.T) {
	for _, tc := range []struct {
		name           string
		edit           func(*coordinatorRequestSettlementFinality)
		used, reserved int64
	}{
		{"observe", func(*coordinatorRequestSettlementFinality) {}, 5, 0},
		{"enforce_verified", func(f *coordinatorRequestSettlementFinality) { f.Mode = "enforce" }, 9, 0},
		{"enforce_refund", func(f *coordinatorRequestSettlementFinality) {
			f.Mode = "enforce"
			f.Outcome = "quarantined"
			f.ReceiptResult = "invalid"
		}, 0, 0},
		{"old_coordinator", func(f *coordinatorRequestSettlementFinality) { f.ModeScopeComplete = false }, 0, 10},
		{"missing_internal_echo", func(f *coordinatorRequestSettlementFinality) { f.RequiredInternalRequestID = "" }, 0, 10},
		{"wrong_internal_echo", func(f *coordinatorRequestSettlementFinality) { f.RequiredInternalRequestID = "other_attempt" }, 0, 10},
		{"enforce_missing_internal_echo", func(f *coordinatorRequestSettlementFinality) {
			f.Mode, f.RequiredInternalRequestID = "enforce", ""
		}, 0, 10},
		{"refund_wrong_internal_echo", func(f *coordinatorRequestSettlementFinality) {
			f.Mode, f.Outcome, f.ReceiptResult, f.RequiredInternalRequestID = "enforce", "quarantined", "invalid", "other_attempt"
		}, 0, 10},
		{"unknown_policy", func(f *coordinatorRequestSettlementFinality) { f.PolicyVersion = "unknown" }, 0, 10},
		{"mixed_scope", func(f *coordinatorRequestSettlementFinality) { f.Reason = "mixed_settlement_policy_snapshot" }, 0, 10},
		{"missing_scope", func(f *coordinatorRequestSettlementFinality) { f.Reason = "missing_current_settlement_finality" }, 0, 10},
		{"wrong_request", func(f *coordinatorRequestSettlementFinality) { f.RequestID = "another" }, 0, 10},
	} {
		t.Run(tc.name, func(t *testing.T) {
			finality := coordinatorRequestSettlementFinality{
				RequestID: "req_candidate", Mode: "observe", ModeScopeComplete: true, PolicyVersion: settlementPolicyVersion,
				RequiredInternalRequestID: "internal_req_candidate",
				Outcome:                   "verified", ReceiptResult: "valid", Closed: true, PromptTokens: 4, CompletionTokens: 5,
				TotalTokens: 9, TokenSource: "coordinator_observed", VerifiedAttempts: 1,
			}
			tc.edit(&finality)
			coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _ = json.NewEncoder(w).Encode(finality) }))
			defer coordinator.Close()
			_, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) { cfg.Coordinator.OperatorURL = coordinator.URL })
			candidate := reserveObserveRecoveryFixture(t, store)
			if err := store.SaveSettlementFallbackCandidate(context.Background(), candidate); err != nil {
				t.Fatal(err)
			}
			server := New(cfg, store, fakeOAuth{}, WithNow(fixedNow))
			if _, err := server.ReconcileSettlementHolds(context.Background(), 10); err != nil {
				t.Fatal(err)
			}
			used, reserved, err := store.DailyUsage(context.Background(), candidate.AccountID, candidate.WindowDate)
			if err != nil || used != tc.used || reserved != tc.reserved {
				t.Fatalf("used=%d reserved=%d want=%d/%d err=%v", used, reserved, tc.used, tc.reserved, err)
			}
		})
	}
}

func TestObserveFallbackDemoOverCapFailsWithoutDebit(t *testing.T) {
	_, store, path, cfg := newTestHarnessConfig(t, fakeOAuth{}, nil)
	candidate := reserveObserveRecoveryFixture(t, store)
	candidate.PromptTokens = 11
	candidate.DemoIdentity, candidate.DemoTokenHash = "192.0.2.12", "synthetic-demo-hash"
	if err := store.SaveSettlementFallbackCandidate(context.Background(), candidate); err == nil {
		t.Fatal("over-cap demo candidate persisted")
	}
	server := New(cfg, store, fakeOAuth{}, WithNow(fixedNow))
	if err := server.settleObserveFallbackCandidate(context.Background(), candidate); err == nil {
		t.Fatal("over-cap demo candidate settled")
	}
	used, reserved, err := store.DailyUsage(context.Background(), candidate.AccountID, candidate.WindowDate)
	if err != nil || used != 0 || reserved != 10 {
		t.Fatalf("used=%d reserved=%d err=%v", used, reserved, err)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM demo_usage_events`).Scan(&count); err != nil || count != 0 {
		t.Fatalf("demo events=%d err=%v", count, err)
	}
}

func TestObserveFallbackMissingCurrentHeaderQuarantinesBeforeLookup(t *testing.T) {
	var lookups atomic.Int32
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lookups.Add(1)
		_ = json.NewEncoder(w).Encode(coordinatorRequestSettlementFinality{
			RequestID: "req_candidate", Mode: "enforce", ModeScopeComplete: true, PolicyVersion: settlementPolicyVersion,
			Outcome: "verified", ReceiptResult: "valid", Closed: true, PromptTokens: 4, CompletionTokens: 5,
			TotalTokens: 9, TokenSource: "coordinator_observed", VerifiedAttempts: 1,
		})
	}))
	defer coordinator.Close()
	_, store, path, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) { cfg.Coordinator.OperatorURL = coordinator.URL })
	candidate := reserveObserveRecoveryFixture(t, store)
	candidate.RequiredInternalRequestID = ""
	if err := store.SaveSettlementFallbackCandidate(context.Background(), candidate); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err := sqlite.Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	server := New(cfg, store, fakeOAuth{}, WithNow(func() time.Time { return fixedNow().Add(24 * time.Hour) }))
	for pass := 0; pass < 2; pass++ {
		if summary, err := server.ReconcileSettlementHolds(context.Background(), 10); err != nil || summary.Held != 1 || summary.Errors != 0 {
			t.Fatalf("pass=%d summary=%+v err=%v", pass, summary, err)
		}
	}
	if lookups.Load() != 0 {
		t.Fatalf("unbound coordinator lookup attempted %d times", lookups.Load())
	}
	if err := server.settleObserveFallbackCandidate(context.Background(), candidate); err == nil {
		t.Fatal("quarantined candidate directly settled")
	}
	used, reserved, err := store.DailyUsage(context.Background(), candidate.AccountID, candidate.WindowDate)
	if err != nil || used != 0 || reserved != 10 {
		t.Fatalf("used=%d reserved=%d err=%v", used, reserved, err)
	}
}

func reserveObserveRecoveryFixture(t *testing.T, store *sqlite.Store) storage.SettlementFallbackCandidate {
	t.Helper()
	ctx := context.Background()
	created := fixedNow()
	if err := store.CreateAccount(ctx, storage.Account{
		AccountID: "acct_candidate", Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: created,
	}); err != nil {
		t.Fatal(err)
	}
	window := created.Format("2006-01-02")
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_candidate", RequestID: "req_candidate", WindowDate: window,
		RequestedTokens: 10, DailyQuota: 100, CreatedAt: created, ExpiresAt: created.Add(time.Minute),
	}); err != nil {
		t.Fatal(err)
	}
	return storage.SettlementFallbackCandidate{
		AccountID: "acct_candidate", RequestID: "req_candidate", ReservationCreatedAt: created,
		RequiredInternalRequestID: "internal_req_candidate",
		WindowDate:                window, PromptTokens: 2, CompletionTokens: 3, MaxTotalTokens: 10,
		TokenSource: "gateway_estimated", Outcome: "unverified_streaming",
	}
}

func TestObserveFallbackWalletReconciliationUsesLocalUsage(t *testing.T) {
	modelsClient := walletModelsClient()
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/internal/settlement/finality" {
			if r.URL.Query().Get("required_internal_request_id") != "internal_req_wallet_candidate" {
				t.Error("wallet recovery lookup missing current internal request fence")
			}
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": {"application/json"}},
				`{"request_id":"req_wallet_candidate","required_internal_request_id":"internal_req_wallet_candidate","mode":"observe","mode_scope_complete":true,"policy_version":"`+settlementPolicyVersion+`","outcome":"pending","receipt_result":"inconclusive","reason":"receipt_verdict_pending","pending_attempts":1,"closed":false}`), nil
		}
		return modelsClient.Do(r)
	})}
	h, store, _, cfg := newWalletSessionHarness(t, client)
	const accountID = "acct_wallet_candidate"
	key := createAccountAndKey(t, store, cfg, accountID)
	wallet := registerWalletSessionViaAPIWithCaps(t, h, cfg, key, accountID, []string{"model-a"}, 100, 10)
	created := fixedNow()
	window := created.Format("2006-01-02")
	if _, err := store.AdmitWalletSessionInference(context.Background(), storage.WalletSessionAdmissionRequest{
		SessionID: wallet.SessionID, AccountID: accountID, RequestID: "req_wallet_candidate", ModelID: "model-a",
		Method: http.MethodPost, CanonicalRoute: "/v1/chat/completions", WindowDate: window,
		RequestedTokens: 10, DailyQuota: 100, CreatedAt: created, ExpiresAt: created.Add(time.Minute),
		Replay: storage.WalletSessionReplayMaterial{SemanticHeadersHash: []byte("headers"), RawBodyHash: []byte("body")},
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveSettlementFallbackCandidate(context.Background(), storage.SettlementFallbackCandidate{
		AccountID: accountID, RequestID: "req_wallet_candidate", WalletSessionID: wallet.SessionID,
		RequiredInternalRequestID: "internal_req_wallet_candidate",
		ReservationCreatedAt:      created, WindowDate: window, PromptTokens: 2, CompletionTokens: 3, MaxTotalTokens: 10,
		TokenSource: "gateway_estimated", Outcome: "unverified_streaming",
	}); err != nil {
		t.Fatal(err)
	}
	server := New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(client))
	if summary, err := server.ReconcileSettlementHolds(context.Background(), 10); err != nil || summary.Observed != 1 {
		t.Fatalf("summary=%+v err=%v", summary, err)
	}
	if summary, err := server.ReconcileSettlementHolds(context.Background(), 10); err != nil || summary.Scanned != 0 {
		t.Fatalf("repeat summary=%+v err=%v", summary, err)
	}
	usage, err := store.WalletSessionUsage(context.Background(), accountID, wallet.SessionID)
	if err != nil || usage.SettledTokens != 5 || usage.ReservedTokens != 0 || usage.HeldTokens != 0 {
		t.Fatalf("wallet usage=%+v err=%v", usage, err)
	}
	used, reserved, err := store.DailyUsage(context.Background(), accountID, window)
	if err != nil || used != 5 || reserved != 0 {
		t.Fatalf("account used=%d reserved=%d err=%v", used, reserved, err)
	}
}

func TestObserveFallbackReconciliationRotatesPastBatchLimitAcrossRestarts(t *testing.T) {
	ctx := context.Background()
	const limit = 100
	const blocked = limit + 1
	const accountID = "acct_retry_fairness"
	created := fixedNow()
	window := created.Format("2006-01-02")
	var mu sync.Mutex
	attempts := make(map[string]int)
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestID := r.URL.Query().Get("request_id")
		mu.Lock()
		attempts[requestID]++
		mu.Unlock()
		if requestID != "recover_observe" && requestID != "recover_enforce" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		mode := "observe"
		if requestID == "recover_enforce" {
			mode = "enforce"
		}
		_ = json.NewEncoder(w).Encode(coordinatorRequestSettlementFinality{
			RequestID: requestID, Mode: mode, ModeScopeComplete: true, PolicyVersion: settlementPolicyVersion,
			RequiredInternalRequestID: r.URL.Query().Get("required_internal_request_id"),
			Outcome:                   "verified", ReceiptResult: "valid", Closed: true, PromptTokens: 4, CompletionTokens: 5,
			TotalTokens: 9, TokenSource: "coordinator_observed", VerifiedAttempts: 1,
		})
	}))
	defer coordinator.Close()
	cfg := baselineValidConfig(t)
	cfg.Coordinator.OperatorURL = coordinator.URL
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	store, err := sqlite.Open(ctx, cfg.Storage.DBPath)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store.Close() }()
	if err := store.CreateAccount(ctx, storage.Account{
		AccountID: accountID, Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: created,
	}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < blocked+2; i++ {
		requestID := "orphan_" + strconv.Itoa(i)
		if i == blocked {
			requestID = "recover_observe"
		} else if i == blocked+1 {
			requestID = "recover_enforce"
		}
		reservationCreated := created.Add(time.Duration(i) * time.Second)
		if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
			AccountID: accountID, RequestID: requestID, WindowDate: window, RequestedTokens: 10,
			DailyQuota: 10000, CreatedAt: reservationCreated, ExpiresAt: reservationCreated.Add(time.Minute),
		}); err != nil {
			t.Fatal(err)
		}
		if err := store.SaveSettlementFallbackCandidate(ctx, storage.SettlementFallbackCandidate{
			AccountID: accountID, RequestID: requestID, ReservationCreatedAt: reservationCreated,
			RequiredInternalRequestID: "internal_" + requestID,
			WindowDate:                window, PromptTokens: 2, CompletionTokens: 3, MaxTotalTokens: 10,
			TokenSource: "gateway_estimated", Outcome: "unverified_streaming",
		}); err != nil {
			t.Fatal(err)
		}
	}
	// Keep the clock fixed across all three processes. Expired, unanswered
	// candidates stay held, but cannot monopolize the next bounded batch.
	now := created.Add(24 * time.Hour)
	for pass := 0; pass < 3; pass++ {
		if pass > 0 {
			if err := store.Close(); err != nil {
				t.Fatal(err)
			}
			store, err = sqlite.Open(ctx, cfg.Storage.DBPath)
			if err != nil {
				t.Fatal(err)
			}
		}
		server := New(cfg, store, fakeOAuth{}, WithNow(func() time.Time { return now }))
		summary, err := server.ReconcileSettlementHolds(ctx, limit)
		if err != nil || summary.Scanned != limit || summary.Errors != 0 || summary.StaleHeld != 0 {
			t.Fatalf("pass=%d summary=%+v err=%v", pass, summary, err)
		}
		wantObserved, wantVerified := 0, 0
		if pass == 1 {
			wantObserved, wantVerified = 1, 1
		}
		if summary.Observed != wantObserved || summary.Verified != wantVerified || summary.Held != limit-wantObserved-wantVerified {
			t.Fatalf("pass=%d summary=%+v", pass, summary)
		}
	}
	used, reserved, err := store.DailyUsage(ctx, accountID, window)
	if err != nil || used != 14 || reserved != blocked*10 {
		t.Fatalf("used=%d reserved=%d err=%v", used, reserved, err)
	}
	if n, err := store.ReapExpiredReservations(ctx, now); err != nil || n != 0 {
		t.Fatalf("candidate holds reaped=%d err=%v", n, err)
	}
	mu.Lock()
	defer mu.Unlock()
	for i := 0; i < blocked; i++ {
		if n := attempts["orphan_"+strconv.Itoa(i)]; n < 2 {
			t.Fatalf("orphan=%d attempts=%d: retry did not rotate across restarts", i, n)
		}
	}
	if attempts["recover_observe"] != 1 || attempts["recover_enforce"] != 1 {
		t.Fatalf("terminal requests retried: observe=%d enforce=%d", attempts["recover_observe"], attempts["recover_enforce"])
	}
}

func TestSettlementReconcileNudgeCoalescesConcurrentRequests(t *testing.T) {
	const (
		accountID          = "acct_nudge_coalesce"
		requestID          = "req_nudge_coalesce"
		internalRequestID  = "internal_nudge_coalesce"
		accountID2         = "acct_nudge_distinct"
		requestID2         = "req_nudge_distinct"
		internalRequestID2 = "internal_nudge_distinct"
	)
	createdAt := fixedNow()
	createdAt2 := createdAt.Add(time.Millisecond)
	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	var calls atomic.Int32
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		select {
		case entered <- struct{}{}:
		default:
		}
		<-release
		request := r.URL.Query().Get("request_id")
		expectedAccount := map[string]string{requestID: accountID, requestID2: accountID2}[request]
		expectedInternal := map[string]string{requestID: internalRequestID, requestID2: internalRequestID2}[request]
		expectedCreatedAt := map[string]time.Time{requestID: createdAt, requestID2: createdAt2}[request]
		if r.URL.Path != "/internal/settlement/finality" || r.Header.Get("Authorization") != "Bearer service-token" ||
			expectedAccount == "" || r.URL.Query().Get("account_id") != expectedAccount ||
			r.URL.Query().Get("required_internal_request_id") != expectedInternal ||
			r.URL.Query().Get("reservation_created_at_unix_ms") != strconv.FormatInt(expectedCreatedAt.UnixMilli(), 10) {
			t.Errorf("finality lookup missing authenticated current-attempt scope: %s", r.URL.RawQuery)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(coordinatorRequestSettlementFinality{
			RequestID:                 request,
			RequiredInternalRequestID: expectedInternal,
			Mode:                      "enforce",
			ModeScopeComplete:         true,
			PolicyVersion:             settlementPolicyVersion,
			Outcome:                   "verified",
			ReceiptResult:             "valid",
			Reason:                    "verified_settlement",
			Closed:                    true,
			PromptTokens:              7,
			CompletionTokens:          5,
			TotalTokens:               12,
			TokenSource:               "coordinator_observed",
			VerifiedAttempts:          1,
		})
	}))
	defer coordinator.Close()

	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Coordinator.OperatorURL = coordinator.URL
	cfg.Coordinator.ServiceToken = "service-token"
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	cfg.Settlement.ReconcileEnabled = true
	cfg.Settlement.ReconcileBatchLimit = 1
	cfg.Settlement.ReconcileRequestTimeoutSeconds = 5
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer store.Close()
	oldCreatedAt := createdAt.Add(-time.Hour)
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       "acct_nudge_backlog",
		RequestID:       "req_nudge_backlog",
		WindowDate:      oldCreatedAt.UTC().Format("2006-01-02"),
		RequestedTokens: 32,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       oldCreatedAt,
		ExpiresAt:       oldCreatedAt.Add(time.Minute),
	}); err != nil {
		t.Fatalf("ReserveQuota backlog: %v", err)
	}
	if err := store.MarkReservationSettlementHold(context.Background(), "acct_nudge_backlog", "req_nudge_backlog"); err != nil {
		t.Fatalf("MarkReservationSettlementHold backlog: %v", err)
	}
	seedBoundSettlementCandidate(t, store, "acct_nudge_backlog", "req_nudge_backlog", "internal_nudge_backlog", oldCreatedAt, 32, "")
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID,
		RequestID:       requestID,
		WindowDate:      createdAt.UTC().Format("2006-01-02"),
		RequestedTokens: 32,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       createdAt,
		ExpiresAt:       createdAt.Add(time.Minute),
	}); err != nil {
		t.Fatalf("ReserveQuota: %v", err)
	}
	if err := store.MarkReservationSettlementHold(context.Background(), accountID, requestID); err != nil {
		t.Fatalf("MarkReservationSettlementHold: %v", err)
	}
	seedBoundSettlementCandidate(t, store, accountID, requestID, internalRequestID, createdAt, 32, "")
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID2,
		RequestID:       requestID2,
		WindowDate:      createdAt2.UTC().Format("2006-01-02"),
		RequestedTokens: 32,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       createdAt2,
		ExpiresAt:       createdAt2.Add(time.Minute),
	}); err != nil {
		t.Fatalf("ReserveQuota distinct: %v", err)
	}
	if err := store.MarkReservationSettlementHold(context.Background(), accountID2, requestID2); err != nil {
		t.Fatalf("MarkReservationSettlementHold distinct: %v", err)
	}
	seedBoundSettlementCandidate(t, store, accountID2, requestID2, internalRequestID2, createdAt2, 32, "")
	server := New(cfg, store, fakeOAuth{}, WithHTTPClient(coordinator.Client()), WithNow(func() time.Time { return createdAt }))
	reservation := storage.ActiveReservation{
		AccountID:      accountID,
		RequestID:      requestID,
		WindowDate:     createdAt.UTC().Format("2006-01-02"),
		ReservedTokens: 32,
		CreatedAt:      createdAt,
	}
	reservation2 := storage.ActiveReservation{
		AccountID:      accountID2,
		RequestID:      requestID2,
		WindowDate:     createdAt2.UTC().Format("2006-01-02"),
		ReservedTokens: 32,
		CreatedAt:      createdAt2,
	}

	server.nudgeSettlementReconciler(reservation)
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("first nudge did not start coordinator lookup")
	}
	for i := 0; i < 5; i++ {
		server.nudgeSettlementReconciler(reservation)
	}
	server.nudgeSettlementReconciler(reservation2)
	time.Sleep(150 * time.Millisecond)
	if got := calls.Load(); got != 2 {
		t.Fatalf("coordinator calls while first nudge in flight=%d want 2 distinct in-flight nudges", got)
	}
	close(release)
	deadline := time.After(2 * time.Second)
	for {
		state := gatewaySettlementSnapshot(t, cfg.Storage.DBPath, accountID)
		state2 := gatewaySettlementSnapshot(t, cfg.Storage.DBPath, accountID2)
		if state.usageRows == 1 && state.settledRows == 1 && state.activeRows == 0 && state.heldRows == 0 &&
			state2.usageRows == 1 && state2.settledRows == 1 && state2.activeRows == 0 && state2.heldRows == 0 {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("nudge did not settle reservations; state=%+v state2=%+v", state, state2)
		case <-time.After(20 * time.Millisecond):
		}
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("coordinator calls after coalesced distinct nudges=%d want 2", got)
	}
	if hold := quotaReservationSettlementHold(t, cfg.Storage.DBPath, accountID, requestID); hold != 0 {
		t.Fatalf("settled quota settlement_hold=%d want 0", hold)
	}
	if hold := quotaReservationSettlementHold(t, cfg.Storage.DBPath, accountID2, requestID2); hold != 0 {
		t.Fatalf("settled distinct quota settlement_hold=%d want 0", hold)
	}
}

func TestSettlementReconcileNudgeRetriesTransientCoordinatorFailure(t *testing.T) {
	const (
		accountID         = "acct_nudge_retry"
		requestID         = "req_nudge_retry"
		internalRequestID = "internal_nudge_retry"
	)
	createdAt := fixedNow()
	var calls atomic.Int32
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := calls.Add(1)
		if r.URL.Path != "/internal/settlement/finality" || r.Header.Get("Authorization") != "Bearer service-token" ||
			r.URL.Query().Get("account_id") != accountID || r.URL.Query().Get("request_id") != requestID ||
			r.URL.Query().Get("required_internal_request_id") != internalRequestID ||
			r.URL.Query().Get("reservation_created_at_unix_ms") != strconv.FormatInt(createdAt.UnixMilli(), 10) {
			t.Errorf("finality lookup missing authenticated current-attempt scope: %s", r.URL.RawQuery)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if call == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		_ = json.NewEncoder(w).Encode(coordinatorRequestSettlementFinality{
			RequestID:                 requestID,
			RequiredInternalRequestID: internalRequestID,
			Mode:                      "enforce",
			ModeScopeComplete:         true,
			PolicyVersion:             settlementPolicyVersion,
			Outcome:                   "verified",
			ReceiptResult:             "valid",
			Reason:                    "verified_settlement",
			Closed:                    true,
			PromptTokens:              7,
			CompletionTokens:          5,
			TotalTokens:               12,
			TokenSource:               "coordinator_observed",
			VerifiedAttempts:          1,
		})
	}))
	defer coordinator.Close()

	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Coordinator.OperatorURL = coordinator.URL
	cfg.Coordinator.ServiceToken = "service-token"
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	cfg.Settlement.ReconcileEnabled = true
	cfg.Settlement.ReconcileRequestTimeoutSeconds = 1
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer store.Close()
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID,
		RequestID:       requestID,
		WindowDate:      createdAt.UTC().Format("2006-01-02"),
		RequestedTokens: 32,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       createdAt,
		ExpiresAt:       createdAt.Add(time.Minute),
	}); err != nil {
		t.Fatalf("ReserveQuota: %v", err)
	}
	if err := store.MarkReservationSettlementHold(context.Background(), accountID, requestID); err != nil {
		t.Fatalf("MarkReservationSettlementHold: %v", err)
	}
	seedBoundSettlementCandidate(t, store, accountID, requestID, internalRequestID, createdAt, 32, "")
	server := New(cfg, store, fakeOAuth{}, WithHTTPClient(coordinator.Client()), WithNow(func() time.Time { return createdAt }))
	server.nudgeSettlementReconciler(storage.ActiveReservation{
		AccountID:      accountID,
		RequestID:      requestID,
		WindowDate:     createdAt.UTC().Format("2006-01-02"),
		ReservedTokens: 32,
		CreatedAt:      createdAt,
	})

	deadline := time.After(3 * time.Second)
	for {
		state := gatewaySettlementSnapshot(t, cfg.Storage.DBPath, accountID)
		if state.usageRows == 1 && state.settledRows == 1 && state.activeRows == 0 && state.heldRows == 0 {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("transient nudge failure did not recover; state=%+v calls=%d", state, calls.Load())
		case <-time.After(20 * time.Millisecond):
		}
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("coordinator calls=%d want one failure and one retry", got)
	}
}

func TestSettlementReconcileNudgeRetriesPendingCoordinatorFinality(t *testing.T) {
	const (
		accountID         = "acct_nudge_pending"
		requestID         = "req_nudge_pending"
		internalRequestID = "internal_nudge_pending"
	)
	createdAt := fixedNow()
	var calls atomic.Int32
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := calls.Add(1)
		finality := coordinatorRequestSettlementFinality{
			RequestID:                 requestID,
			RequiredInternalRequestID: internalRequestID,
			Mode:                      "enforce",
			ModeScopeComplete:         true,
			PolicyVersion:             settlementPolicyVersion,
		}
		if call == 1 {
			finality.Outcome = "pending"
			finality.ReceiptResult = "inconclusive"
			finality.Reason = "receipt_verdict_pending"
			finality.PendingAttempts = 1
		} else {
			finality.Outcome = "verified"
			finality.ReceiptResult = "valid"
			finality.Reason = "verified_settlement"
			finality.Closed = true
			finality.PromptTokens = 7
			finality.CompletionTokens = 5
			finality.TotalTokens = 12
			finality.TokenSource = "coordinator_observed"
			finality.VerifiedAttempts = 1
		}
		_ = json.NewEncoder(w).Encode(finality)
	}))
	defer coordinator.Close()

	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Coordinator.OperatorURL = coordinator.URL
	cfg.Coordinator.ServiceToken = "service-token"
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	cfg.Settlement.ReconcileEnabled = true
	cfg.Settlement.ReconcileRequestTimeoutSeconds = 1
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer store.Close()
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID,
		RequestID:       requestID,
		WindowDate:      createdAt.UTC().Format("2006-01-02"),
		RequestedTokens: 32,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       createdAt,
		ExpiresAt:       createdAt.Add(time.Minute),
	}); err != nil {
		t.Fatalf("ReserveQuota: %v", err)
	}
	if err := store.MarkReservationSettlementHold(context.Background(), accountID, requestID); err != nil {
		t.Fatalf("MarkReservationSettlementHold: %v", err)
	}
	seedBoundSettlementCandidate(t, store, accountID, requestID, internalRequestID, createdAt, 32, "")
	server := New(cfg, store, fakeOAuth{}, WithHTTPClient(coordinator.Client()), WithNow(func() time.Time { return createdAt }))
	server.nudgeSettlementReconciler(storage.ActiveReservation{
		AccountID: accountID, RequestID: requestID, WindowDate: createdAt.UTC().Format("2006-01-02"), ReservedTokens: 32, CreatedAt: createdAt,
	})

	deadline := time.After(3 * time.Second)
	for {
		state := gatewaySettlementSnapshot(t, cfg.Storage.DBPath, accountID)
		if state.usageRows == 1 && state.settledRows == 1 && state.activeRows == 0 && state.heldRows == 0 {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("pending nudge finality did not recover; state=%+v calls=%d", state, calls.Load())
		case <-time.After(20 * time.Millisecond):
		}
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("coordinator calls=%d want one pending lookup and one final retry", got)
	}
}

func TestSettlementReconcileNudgeDoesNotRetryPermanentCoordinatorFailure(t *testing.T) {
	const (
		accountID         = "acct_nudge_permanent"
		requestID         = "req_nudge_permanent"
		internalRequestID = "internal_nudge_permanent"
	)
	createdAt := fixedNow()
	var calls atomic.Int32
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusBadRequest)
	}))
	defer coordinator.Close()

	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Coordinator.OperatorURL = coordinator.URL
	cfg.Coordinator.ServiceToken = "service-token"
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	cfg.Settlement.ReconcileEnabled = true
	cfg.Settlement.ReconcileRequestTimeoutSeconds = 1
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer store.Close()
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID,
		RequestID:       requestID,
		WindowDate:      createdAt.UTC().Format("2006-01-02"),
		RequestedTokens: 32,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       createdAt,
		ExpiresAt:       createdAt.Add(time.Minute),
	}); err != nil {
		t.Fatalf("ReserveQuota: %v", err)
	}
	if err := store.MarkReservationSettlementHold(context.Background(), accountID, requestID); err != nil {
		t.Fatalf("MarkReservationSettlementHold: %v", err)
	}
	seedBoundSettlementCandidate(t, store, accountID, requestID, internalRequestID, createdAt, 32, "")
	server := New(cfg, store, fakeOAuth{}, WithHTTPClient(coordinator.Client()), WithNow(func() time.Time { return createdAt }))
	server.nudgeSettlementReconciler(storage.ActiveReservation{
		AccountID: accountID, RequestID: requestID, WindowDate: createdAt.UTC().Format("2006-01-02"), ReservedTokens: 32, CreatedAt: createdAt,
	})

	time.Sleep(750 * time.Millisecond)
	if got := calls.Load(); got != 1 {
		t.Fatalf("permanent coordinator failure calls=%d want 1", got)
	}
	state := gatewaySettlementSnapshot(t, cfg.Storage.DBPath, accountID)
	if state.usageRows != 0 || state.settledRows != 0 || state.activeRows != 1 || state.heldRows != 1 {
		t.Fatalf("permanent failure state=%+v, want held reservation without debit", state)
	}
}

func quotaReservationSettlementHold(t *testing.T, dbPath, accountID, requestID string) int64 {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	var hold int64
	if err := db.QueryRow(`SELECT settlement_hold FROM quota_reservations WHERE account_id = ? AND request_id = ?`, accountID, requestID).Scan(&hold); err != nil {
		t.Fatalf("query settlement_hold: %v", err)
	}
	return hold
}

func TestSettlementReconcileNudgeOverflowRequestsCatchup(t *testing.T) {
	const (
		accountID         = "acct_nudge_overflow"
		requestID         = "req_nudge_overflow"
		internalRequestID = "internal_nudge_overflow"
	)
	createdAt := fixedNow()
	var calls atomic.Int32
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/internal/settlement/finality" || r.Header.Get("Authorization") != "Bearer service-token" ||
			r.URL.Query().Get("account_id") != accountID || r.URL.Query().Get("request_id") != requestID ||
			r.URL.Query().Get("required_internal_request_id") != internalRequestID ||
			r.URL.Query().Get("reservation_created_at_unix_ms") != strconv.FormatInt(createdAt.UnixMilli(), 10) {
			t.Errorf("catch-up finality lookup missing authenticated current-attempt scope: %s", r.URL.RawQuery)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(coordinatorRequestSettlementFinality{
			RequestID:                 requestID,
			RequiredInternalRequestID: internalRequestID,
			Mode:                      "enforce",
			ModeScopeComplete:         true,
			PolicyVersion:             settlementPolicyVersion,
			Outcome:                   "verified",
			ReceiptResult:             "valid",
			Reason:                    "verified_settlement",
			Closed:                    true,
			PromptTokens:              7,
			CompletionTokens:          5,
			TotalTokens:               12,
			TokenSource:               "coordinator_observed",
			VerifiedAttempts:          1,
		})
	}))
	defer coordinator.Close()

	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Coordinator.OperatorURL = coordinator.URL
	cfg.Coordinator.ServiceToken = "service-token"
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	cfg.Settlement.ReconcileEnabled = true
	cfg.Settlement.ReconcileBatchLimit = 1
	cfg.Settlement.ReconcileRequestTimeoutSeconds = 5
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer store.Close()
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID,
		RequestID:       requestID,
		WindowDate:      createdAt.UTC().Format("2006-01-02"),
		RequestedTokens: 32,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       createdAt,
		ExpiresAt:       createdAt.Add(time.Minute),
	}); err != nil {
		t.Fatalf("ReserveQuota: %v", err)
	}
	if err := store.MarkReservationSettlementHold(context.Background(), accountID, requestID); err != nil {
		t.Fatalf("MarkReservationSettlementHold: %v", err)
	}
	seedBoundSettlementCandidate(t, store, accountID, requestID, internalRequestID, createdAt, 32, "")
	server := New(cfg, store, fakeOAuth{}, WithHTTPClient(coordinator.Client()), WithNow(func() time.Time { return createdAt }))
	server.settlementReconcileNudgeKeys = make(map[string]struct{}, maxSettlementReconcileNudgeQueue)
	server.settlementReconcileNudgePending = make([]settlementReconcileNudge, maxSettlementReconcileNudgeQueue)
	for i := 0; i < maxSettlementReconcileNudgeQueue; i++ {
		dummy := storage.ActiveReservation{AccountID: "acct_full", RequestID: "req_full_" + strconv.Itoa(i), CreatedAt: createdAt.Add(time.Duration(i) * time.Nanosecond)}
		server.settlementReconcileNudgePending[i] = settlementReconcileNudge{reservation: dummy, attempt: 1}
		server.settlementReconcileNudgeKeys[settlementReconcileNudgeKey(dummy)] = struct{}{}
	}

	server.nudgeSettlementReconciler(storage.ActiveReservation{
		AccountID:      accountID,
		RequestID:      requestID,
		WindowDate:     createdAt.UTC().Format("2006-01-02"),
		ReservedTokens: 32,
		CreatedAt:      createdAt,
	})

	deadline := time.After(2 * time.Second)
	for {
		state := gatewaySettlementSnapshot(t, cfg.Storage.DBPath, accountID)
		if state.usageRows == 1 && state.settledRows == 1 && state.activeRows == 0 && state.heldRows == 0 {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("overflow catch-up did not settle reservation; state=%+v calls=%d", state, calls.Load())
		case <-time.After(20 * time.Millisecond):
		}
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("coordinator calls after overflow catch-up=%d want 1", got)
	}
	if hold := quotaReservationSettlementHold(t, cfg.Storage.DBPath, accountID, requestID); hold != 0 {
		t.Fatalf("overflow settled quota settlement_hold=%d want 0", hold)
	}
}

func TestSettlementReconcileOverflowCatchupUsesPerReservationTimeout(t *testing.T) {
	const (
		slowAccountID     = "acct_nudge_slow"
		slowRequestID     = "req_nudge_slow"
		slowInternalID    = "internal_nudge_slow"
		accountID         = "acct_nudge_overflow_after_slow"
		requestID         = "req_nudge_overflow_after_slow"
		internalRequestID = "internal_nudge_overflow_after_slow"
	)
	createdAt := fixedNow()
	slowCreatedAt := createdAt.Add(-time.Hour)
	var targetCalls atomic.Int32
	var slowCalls atomic.Int32
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		request := r.URL.Query().Get("request_id")
		switch request {
		case slowRequestID:
			slowCalls.Add(1)
			if r.URL.Query().Get("account_id") != slowAccountID || r.URL.Query().Get("required_internal_request_id") != slowInternalID {
				t.Errorf("slow finality lookup missing scope: %s", r.URL.RawQuery)
			}
			<-r.Context().Done()
			return
		case requestID:
			targetCalls.Add(1)
			if r.URL.Path != "/internal/settlement/finality" || r.Header.Get("Authorization") != "Bearer service-token" ||
				r.URL.Query().Get("account_id") != accountID || r.URL.Query().Get("required_internal_request_id") != internalRequestID ||
				r.URL.Query().Get("reservation_created_at_unix_ms") != strconv.FormatInt(createdAt.UnixMilli(), 10) {
				t.Errorf("target finality lookup missing authenticated current-attempt scope: %s", r.URL.RawQuery)
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			_ = json.NewEncoder(w).Encode(coordinatorRequestSettlementFinality{
				RequestID:                 requestID,
				RequiredInternalRequestID: internalRequestID,
				Mode:                      "enforce",
				ModeScopeComplete:         true,
				PolicyVersion:             settlementPolicyVersion,
				Outcome:                   "verified",
				ReceiptResult:             "valid",
				Reason:                    "verified_settlement",
				Closed:                    true,
				PromptTokens:              7,
				CompletionTokens:          5,
				TotalTokens:               12,
				TokenSource:               "coordinator_observed",
				VerifiedAttempts:          1,
			})
		default:
			t.Errorf("unexpected finality request: %s", r.URL.RawQuery)
			w.WriteHeader(http.StatusBadRequest)
		}
	}))
	defer coordinator.Close()

	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Coordinator.OperatorURL = coordinator.URL
	cfg.Coordinator.ServiceToken = "service-token"
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	cfg.Settlement.ReconcileEnabled = true
	cfg.Settlement.ReconcileRequestTimeoutSeconds = 1
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer store.Close()
	for _, row := range []struct {
		accountID string
		requestID string
		internal  string
		createdAt time.Time
	}{
		{slowAccountID, slowRequestID, slowInternalID, slowCreatedAt},
		{accountID, requestID, internalRequestID, createdAt},
	} {
		if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
			AccountID:       row.accountID,
			RequestID:       row.requestID,
			WindowDate:      row.createdAt.UTC().Format("2006-01-02"),
			RequestedTokens: 32,
			DailyQuota:      cfg.Quotas.AccountDailyTokens,
			CreatedAt:       row.createdAt,
			ExpiresAt:       row.createdAt.Add(time.Minute),
		}); err != nil {
			t.Fatalf("ReserveQuota %s: %v", row.requestID, err)
		}
		if err := store.MarkReservationSettlementHold(context.Background(), row.accountID, row.requestID); err != nil {
			t.Fatalf("MarkReservationSettlementHold %s: %v", row.requestID, err)
		}
		seedBoundSettlementCandidate(t, store, row.accountID, row.requestID, row.internal, row.createdAt, 32, "")
	}
	server := New(cfg, store, fakeOAuth{}, WithHTTPClient(coordinator.Client()), WithNow(func() time.Time { return createdAt }))
	server.settlementReconcileNudgeKeys = make(map[string]struct{}, maxSettlementReconcileNudgeQueue)
	server.settlementReconcileNudgePending = make([]settlementReconcileNudge, maxSettlementReconcileNudgeQueue)
	for i := 0; i < maxSettlementReconcileNudgeQueue; i++ {
		dummy := storage.ActiveReservation{AccountID: "acct_full_slow", RequestID: "req_full_slow_" + strconv.Itoa(i), CreatedAt: createdAt.Add(time.Duration(i) * time.Nanosecond)}
		server.settlementReconcileNudgePending[i] = settlementReconcileNudge{reservation: dummy, attempt: 1}
		server.settlementReconcileNudgeKeys[settlementReconcileNudgeKey(dummy)] = struct{}{}
	}

	server.nudgeSettlementReconciler(storage.ActiveReservation{
		AccountID:      accountID,
		RequestID:      requestID,
		WindowDate:     createdAt.UTC().Format("2006-01-02"),
		ReservedTokens: 32,
		CreatedAt:      createdAt,
	})

	deadline := time.After(3 * time.Second)
	for {
		state := gatewaySettlementSnapshot(t, cfg.Storage.DBPath, accountID)
		if state.usageRows == 1 && state.settledRows == 1 && state.activeRows == 0 && state.heldRows == 0 {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("overflow catch-up target starved behind slow hold; state=%+v slow_calls=%d target_calls=%d", state, slowCalls.Load(), targetCalls.Load())
		case <-time.After(20 * time.Millisecond):
		}
	}
	if slowCalls.Load() == 0 || targetCalls.Load() != 1 {
		t.Fatalf("catch-up calls slow=%d target=%d, want slow>=1 target=1", slowCalls.Load(), targetCalls.Load())
	}
	if hold := quotaReservationSettlementHold(t, cfg.Storage.DBPath, accountID, requestID); hold != 0 {
		t.Fatalf("overflow target settlement_hold=%d want 0", hold)
	}
}

func TestSettlementStartupCatchupUsesPerReservationTimeout(t *testing.T) {
	const (
		slowAccountID     = "acct_startup_slow"
		slowRequestID     = "req_startup_slow"
		slowInternalID    = "internal_startup_slow"
		accountID         = "acct_startup_target"
		requestID         = "req_startup_target"
		internalRequestID = "internal_startup_target"
	)
	createdAt := fixedNow()
	slowCreatedAt := createdAt.Add(-time.Hour)
	var targetCalls atomic.Int32
	var slowCalls atomic.Int32
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch request := r.URL.Query().Get("request_id"); request {
		case slowRequestID:
			slowCalls.Add(1)
			<-r.Context().Done()
		case requestID:
			targetCalls.Add(1)
			if r.URL.Query().Get("account_id") != accountID || r.URL.Query().Get("required_internal_request_id") != internalRequestID ||
				r.URL.Query().Get("reservation_created_at_unix_ms") != strconv.FormatInt(createdAt.UnixMilli(), 10) {
				t.Errorf("startup catch-up target lookup missing scope: %s", r.URL.RawQuery)
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			_ = json.NewEncoder(w).Encode(coordinatorRequestSettlementFinality{
				RequestID:                 requestID,
				RequiredInternalRequestID: internalRequestID,
				Mode:                      "enforce",
				ModeScopeComplete:         true,
				PolicyVersion:             settlementPolicyVersion,
				Outcome:                   "verified",
				ReceiptResult:             "valid",
				Reason:                    "verified_settlement",
				Closed:                    true,
				PromptTokens:              7,
				CompletionTokens:          5,
				TotalTokens:               12,
				TokenSource:               "coordinator_observed",
				VerifiedAttempts:          1,
			})
		default:
			t.Errorf("unexpected startup catch-up request: %s", r.URL.RawQuery)
			w.WriteHeader(http.StatusBadRequest)
		}
	}))
	defer coordinator.Close()

	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Coordinator.OperatorURL = coordinator.URL
	cfg.Coordinator.ServiceToken = "service-token"
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	cfg.Settlement.ReconcileEnabled = true
	cfg.Settlement.ReconcileBatchLimit = 1
	cfg.Settlement.ReconcileRequestTimeoutSeconds = 1
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer store.Close()
	for _, row := range []struct {
		accountID string
		requestID string
		internal  string
		createdAt time.Time
	}{
		{slowAccountID, slowRequestID, slowInternalID, slowCreatedAt},
		{accountID, requestID, internalRequestID, createdAt},
	} {
		if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
			AccountID:       row.accountID,
			RequestID:       row.requestID,
			WindowDate:      row.createdAt.UTC().Format("2006-01-02"),
			RequestedTokens: 32,
			DailyQuota:      cfg.Quotas.AccountDailyTokens,
			CreatedAt:       row.createdAt,
			ExpiresAt:       row.createdAt.Add(time.Minute),
		}); err != nil {
			t.Fatalf("ReserveQuota %s: %v", row.requestID, err)
		}
		if err := store.MarkReservationSettlementHold(context.Background(), row.accountID, row.requestID); err != nil {
			t.Fatalf("MarkReservationSettlementHold %s: %v", row.requestID, err)
		}
		seedBoundSettlementCandidate(t, store, row.accountID, row.requestID, row.internal, row.createdAt, 32, "")
	}
	server := New(cfg, store, fakeOAuth{}, WithHTTPClient(coordinator.Client()), WithNow(func() time.Time { return createdAt }))
	summary, err := server.CatchUpSettlementHolds(context.Background(), 500)
	if err != nil {
		t.Fatalf("CatchUpSettlementHolds: %v", err)
	}
	if summary.Scanned != 2 || summary.Errors != 1 || summary.Verified != 1 {
		t.Fatalf("startup catch-up summary=%+v, want scanned=2 errors=1 verified=1", summary)
	}
	state := gatewaySettlementSnapshot(t, cfg.Storage.DBPath, accountID)
	if state.usageRows != 1 || state.settledRows != 1 || state.activeRows != 0 || state.heldRows != 0 {
		t.Fatalf("startup catch-up target state=%+v, want settled without active hold", state)
	}
	slowState := gatewaySettlementSnapshot(t, cfg.Storage.DBPath, slowAccountID)
	if slowState.usageRows != 0 || slowState.settledRows != 0 || slowState.activeRows != 1 || slowState.heldRows != 1 {
		t.Fatalf("startup catch-up slow state=%+v, want still held after timeout", slowState)
	}
	if slowCalls.Load() == 0 || targetCalls.Load() != 1 {
		t.Fatalf("startup catch-up calls slow=%d target=%d, want slow>=1 target=1", slowCalls.Load(), targetCalls.Load())
	}
	if hold := quotaReservationSettlementHold(t, cfg.Storage.DBPath, accountID, requestID); hold != 0 {
		t.Fatalf("startup target settlement_hold=%d want 0", hold)
	}
}
