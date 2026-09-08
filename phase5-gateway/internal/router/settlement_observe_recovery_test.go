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
