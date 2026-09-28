package router

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

func TestSettlementReleaseHoldsDryRunApplyScopeAndIdempotency(t *testing.T) {
	now := fixedNow()
	accountID := "acct_drain"
	otherAccountID := "acct_drain_other"
	finalities := map[string]map[string]any{
		"req_settle":  drainFinality("req_settle", "verified", "valid", true, 3, 2),
		"req_refund":  drainFinality("req_refund", "quarantined", "invalid", true, 0, 0),
		"req_release": drainFinality("req_release", "pending", "inconclusive", false, 0, 0),
	}
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, ok := finalities[r.URL.Query().Get("request_id")]
		if !ok {
			writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Settlement finality not found")
			return
		}
		body["required_internal_request_id"] = "internal_" + r.URL.Query().Get("request_id")
		writeJSON(w, http.StatusOK, body)
	}))
	defer coordinator.Close()
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
	}, WithHTTPClient(coordinator.Client()))
	for i, requestID := range []string{"req_settle", "req_refund", "req_release"} {
		createdAt := now.Add(time.Duration(-4+i) * time.Hour)
		seedDrainReservation(t, store, cfg, accountID, requestID, createdAt, 20, "")
	}
	seedDrainReservation(t, store, cfg, accountID, "req_at_cutoff", now.Add(-time.Hour), 20, "")
	seedDrainReservation(t, store, cfg, accountID, "req_after_cutoff_same_second", now.Add(-time.Hour+500*time.Millisecond), 20, "")
	seedDrainReservation(t, store, cfg, otherAccountID, "req_other", now.Add(-5*time.Hour), 20, "")

	path := "/admin/settlement/release-holds?account_id=" + url.QueryEscape(accountID) +
		"&created_before=" + url.QueryEscape(now.Add(-time.Hour).Format(time.RFC3339)) + "&limit=3"
	dry := performDrainRequest(t, h, path, "operator-key")
	if dry.Scanned != 3 || dry.Apply || dry.Counts.Settle != 1 || dry.Counts.Refund != 1 || dry.Counts.Release != 1 {
		t.Fatalf("dry response=%+v", dry)
	}
	for _, row := range dry.Rows {
		if row.Applied {
			t.Fatalf("dry row applied: %+v", row)
		}
	}
	got := gatewaySettlementSnapshot(t, dbPath, accountID)
	if got.activeRows != 5 || got.activeReserved != 100 || got.usageRows != 0 {
		t.Fatalf("dry run mutated account: %+v", got)
	}
	if got := settlementAttemptCount(t, dbPath, accountID); got != 0 {
		t.Fatalf("dry run wrote %d reconcile attempts", got)
	}

	applied := performDrainRequest(t, h, path+"&apply=true", "operator-key")
	if applied.Scanned != 3 || !applied.Apply || applied.Counts.Settle != 1 || applied.Counts.Refund != 1 || applied.Counts.Release != 1 {
		t.Fatalf("apply response=%+v", applied)
	}
	for _, row := range applied.Rows {
		if !row.Applied || row.Error != "" {
			t.Fatalf("apply row=%+v", row)
		}
	}
	got = gatewaySettlementSnapshot(t, dbPath, accountID)
	if got.settledRows != 1 || got.refundedRows != 2 || got.activeRows != 2 || got.activeReserved != 40 || got.usageRows != 1 {
		t.Fatalf("apply state=%+v", got)
	}
	other := gatewaySettlementSnapshot(t, dbPath, otherAccountID)
	if other.activeRows != 1 || other.heldRows != 1 {
		t.Fatalf("other account changed: %+v", other)
	}
	assertDrainAttemptResults(t, dbPath, accountID, map[string]string{
		"req_settle": "operator_drain_settle", "req_refund": "operator_drain_refund", "req_release": "operator_drain_release",
	})

	again := performDrainRequest(t, h, path+"&apply=true", "operator-key")
	if again.Scanned != 0 || len(again.Rows) != 0 {
		t.Fatalf("idempotent rerun=%+v", again)
	}
}

func TestSettlementReleaseHoldsRestoresReleasedQuota(t *testing.T) {
	now := fixedNow()
	accountID := "acct_drain_quota"
	requestID := "req_drain_quota"
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body := drainFinality(requestID, "pending", "inconclusive", false, 0, 0)
		body["required_internal_request_id"] = "internal_" + requestID
		writeJSON(w, http.StatusOK, body)
	}))
	defer coordinator.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
	}, WithHTTPClient(coordinator.Client()))
	before, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID: accountID, RequestID: "probe_before", WindowDate: now.Format("2006-01-02"),
		RequestedTokens: 1, DailyQuota: cfg.Quotas.AccountDailyTokens, CreatedAt: now.Add(-3 * time.Hour), ExpiresAt: now.Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.RefundReservation(context.Background(), accountID, "probe_before", now.Unix()); err != nil {
		t.Fatal(err)
	}
	seedDrainReservation(t, store, cfg, accountID, requestID, now.Add(-2*time.Hour), 37, "")
	performDrainRequest(t, h, "/admin/settlement/release-holds?account_id="+accountID+"&created_before="+url.QueryEscape(now.Format(time.RFC3339))+"&apply=true", "operator-key")
	after, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID: accountID, RequestID: "probe_after", WindowDate: now.Format("2006-01-02"),
		RequestedTokens: 1, DailyQuota: cfg.Quotas.AccountDailyTokens, CreatedAt: now, ExpiresAt: now.Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	if after.RemainingTokens != before.RemainingTokens {
		t.Fatalf("remaining quota after release=%d before reservation=%d", after.RemainingTokens, before.RemainingTokens)
	}
}

func TestSettlementReleaseHoldsValidationAndAuthorization(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{})
	cutoff := url.QueryEscape(fixedNow().Format(time.RFC3339))
	unauthorized := httptest.NewRequest(http.MethodPost, "/admin/settlement/release-holds?account_id=acct&created_before="+cutoff, nil)
	unauthorizedResp := httptest.NewRecorder()
	h.ServeHTTP(unauthorizedResp, unauthorized)
	if unauthorizedResp.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status=%d", unauthorizedResp.Code)
	}
	for _, path := range []string{
		"/admin/settlement/release-holds?created_before=" + cutoff,
		"/admin/settlement/release-holds?account_id=acct",
		"/admin/settlement/release-holds?account_id=acct&created_before=bad",
		"/admin/settlement/release-holds?account_id=acct&created_before=" + cutoff + "&limit=1001",
	} {
		req := httptest.NewRequest(http.MethodPost, path, nil)
		req.Header.Set("Authorization", "Bearer operator-key")
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		if resp.Code != http.StatusBadRequest {
			t.Fatalf("path=%s status=%d body=%s", path, resp.Code, resp.Body.String())
		}
	}
	bodyReq := httptest.NewRequest(http.MethodPost, "/admin/settlement/release-holds", strings.NewReader(`{"account_id":"acct","created_before":"2026-09-28T12:00:00Z","limit":1}`))
	bodyReq.Header.Set("Authorization", "Bearer operator-key")
	bodyReq.Header.Set("Content-Type", "application/json")
	bodyResp := httptest.NewRecorder()
	h.ServeHTTP(bodyResp, bodyReq)
	if bodyResp.Code != http.StatusOK {
		t.Fatalf("body parameters status=%d body=%s", bodyResp.Code, bodyResp.Body.String())
	}
}

func TestSettlementReleaseHoldsApplySkipsNewLookupError(t *testing.T) {
	now := fixedNow()
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = "http://coordinator.invalid"
	}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("lookup unavailable")
	})}))
	accountID := "acct_lookup_error"
	seedDrainReservation(t, store, cfg, accountID, "req_lookup_error", now.Add(-2*time.Hour), 20, "")
	seedDrainReservation(t, store, cfg, accountID, "req_reviewed_error", now.Add(-time.Hour), 20, "")
	reviewed := storage.ActiveReservation{AccountID: accountID, RequestID: "req_reviewed_error", CreatedAt: now.Add(-time.Hour)}
	if err := store.MarkSettlementReconcileAttempt(context.Background(), reviewed); err != nil {
		t.Fatal(err)
	}
	if err := store.MarkSettlementHoldOperatorReview(context.Background(), reviewed, "coordinator_finality_not_found", now); err != nil {
		t.Fatal(err)
	}
	response := performDrainRequest(t, h, "/admin/settlement/release-holds?account_id=acct_lookup_error&created_before="+url.QueryEscape(now.Format(time.RFC3339))+"&apply=true", "operator-key")
	if response.Counts.SkipLookupError != 1 || response.Counts.Release != 1 || response.Rows[0].Applied || !response.Rows[1].Applied {
		t.Fatalf("response=%+v", response)
	}
	state := gatewaySettlementSnapshot(t, dbPath, "acct_lookup_error")
	if state.activeRows != 1 || state.heldRows != 1 || state.refundedRows != 1 || state.activeReserved != 20 {
		t.Fatalf("lookup error mutated reservation: %+v", state)
	}
}

type settlementDrainPathSpy struct {
	*sqlite.Store
	accountRefunds int
	demoRefunds    int
	walletRefunds  int
}

func (s *settlementDrainPathSpy) RefundReservationForDrain(ctx context.Context, reservation storage.ActiveReservation, refundedAt time.Time, reconcileResult string) error {
	s.accountRefunds++
	return s.Store.RefundReservationForDrain(ctx, reservation, refundedAt, reconcileResult)
}

func (s *settlementDrainPathSpy) RefundDemoReservationForDrain(ctx context.Context, reservation storage.ActiveReservation, refundedAt time.Time, reconcileResult string) error {
	s.demoRefunds++
	return s.Store.RefundDemoReservationForDrain(ctx, reservation, refundedAt, reconcileResult)
}

func (s *settlementDrainPathSpy) RefundWalletSessionReservationForDrain(ctx context.Context, reservation storage.ActiveReservation, refundedAt time.Time, reconcileResult string) error {
	s.walletRefunds++
	return s.Store.RefundWalletSessionReservationForDrain(ctx, reservation, refundedAt, reconcileResult)
}

func TestSettlementReleaseHoldsUsesDemoAndWalletReleasePaths(t *testing.T) {
	now := fixedNow()
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestID := r.URL.Query().Get("request_id")
		body := drainFinality(requestID, "pending", "inconclusive", false, 0, 0)
		body["required_internal_request_id"] = "internal_" + requestID
		writeJSON(w, http.StatusOK, body)
	}))
	defer coordinator.Close()
	baseHandler, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Public.BaseURL = "https://api.malibu.test"
		cfg.Auth.WalletSessions.Enabled = true
		cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
		cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
		cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
		cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
		cfg.Coordinator.OperatorURL = coordinator.URL
	}, WithHTTPClient(walletInferenceClient()))

	demoAccount := "demo:192.0.2.44"
	demoRequest := "req_demo_drain"
	createdAt := now.Add(-2 * time.Hour)
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID: demoAccount, RequestID: demoRequest, WindowDate: createdAt.Format("2006-01-02"), RequestedTokens: 20,
		DailyQuota: cfg.Quotas.DemoDailyTokensPerIP, CreatedAt: createdAt, ExpiresAt: now.Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveSettlementFallbackCandidate(context.Background(), storage.SettlementFallbackCandidate{
		AccountID: demoAccount, RequestID: demoRequest, RequiredInternalRequestID: "internal_" + demoRequest,
		ReservationCreatedAt: createdAt, DemoIdentity: "192.0.2.44", DemoTokenHash: "demo-hash", WindowDate: createdAt.Format("2006-01-02"),
		MaxTotalTokens: 20, TokenSource: "gateway_estimated", Outcome: "reconcile_test_hold",
	}); err != nil {
		t.Fatal(err)
	}

	walletAccount := "acct_wallet_drain"
	walletRequest := "req_wallet_drain"
	apiKey := createAccountAndKey(t, store, cfg, walletAccount)
	client := registerWalletSessionViaAPIWithCaps(t, baseHandler, cfg, apiKey, walletAccount, []string{"model-a"}, 100, 100)
	if _, err := store.AdmitWalletSessionInference(context.Background(), storage.WalletSessionAdmissionRequest{
		SessionID: client.SessionID, AccountID: walletAccount, RequestID: walletRequest, Method: http.MethodPost,
		CanonicalRoute: "/v1/chat/completions", ModelID: "model-a", WindowDate: createdAt.Format("2006-01-02"), RequestedTokens: 20,
		DailyQuota: cfg.Quotas.AccountDailyTokens, Replay: storage.WalletSessionReplayMaterial{
			SessionID: client.SessionID, RequestID: walletRequest, Method: http.MethodPost, CanonicalRoute: "/v1/chat/completions",
			SemanticHeadersHash: []byte("headers"), RawBodyHash: []byte("body"), BodyBytes: 12,
		}, CreatedAt: createdAt, ExpiresAt: now.Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.HoldWalletSessionReservation(context.Background(), walletAccount, client.SessionID, walletRequest, now); err != nil {
		t.Fatal(err)
	}
	seedBoundSettlementCandidate(t, store, walletAccount, walletRequest, "internal_"+walletRequest, createdAt, 20, client.SessionID)

	spy := &settlementDrainPathSpy{Store: store}
	h := New(cfg, spy, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(coordinator.Client())).Handler()
	for _, accountID := range []string{demoAccount, walletAccount} {
		response := performDrainRequest(t, h, "/admin/settlement/release-holds?account_id="+url.QueryEscape(accountID)+"&created_before="+url.QueryEscape(now.Format(time.RFC3339))+"&apply=true", "operator-key")
		if response.Counts.Release != 1 || !response.Rows[0].Applied {
			t.Fatalf("account=%s response=%+v", accountID, response)
		}
	}
	if spy.demoRefunds != 1 || spy.walletRefunds != 1 || spy.accountRefunds != 0 {
		t.Fatalf("release calls demo=%d wallet=%d account=%d", spy.demoRefunds, spy.walletRefunds, spy.accountRefunds)
	}
}

func TestSettlementReleaseHoldsSkipsVerifiedDemoWithoutDemoMetadata(t *testing.T) {
	now := fixedNow()
	accountID := "demo:192.0.2.55"
	requestID := "req_demo_missing_metadata"
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body := drainFinality(requestID, "verified", "valid", true, 3, 2)
		body["required_internal_request_id"] = "internal_" + requestID
		writeJSON(w, http.StatusOK, body)
	}))
	defer coordinator.Close()
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
	}, WithHTTPClient(coordinator.Client()))
	createdAt := now.Add(-time.Hour)
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID: accountID, RequestID: requestID, WindowDate: createdAt.Format("2006-01-02"), RequestedTokens: 20,
		DailyQuota: cfg.Quotas.DemoDailyTokensPerIP, CreatedAt: createdAt, ExpiresAt: now.Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	seedBoundSettlementCandidate(t, store, accountID, requestID, "internal_"+requestID, createdAt, 20, "")
	response := performDrainRequest(t, h, "/admin/settlement/release-holds?account_id="+url.QueryEscape(accountID)+"&created_before="+url.QueryEscape(now.Format(time.RFC3339))+"&apply=true", "operator-key")
	if response.Counts.SkipUnsupported != 1 || response.Rows[0].Applied {
		t.Fatalf("response=%+v", response)
	}
	state := gatewaySettlementSnapshot(t, dbPath, accountID)
	if state.activeRows != 1 || state.heldRows != 1 || state.usageRows != 0 {
		t.Fatalf("unsupported demo settle mutated state: %+v", state)
	}
}

func TestSettlementReleaseHoldsSkipsRelayBlind(t *testing.T) {
	server := &Server{}
	row := server.releaseSettlementHold(context.Background(), storage.ActiveReservation{
		AccountID: "acct_relay", RequestID: "req_relay", RelayBlind: &storage.RelayBlindMetadata{},
	}, true)
	if row.Disposition != "skip_unsupported" || row.Applied {
		t.Fatalf("row=%+v", row)
	}
}

func TestSettlementDrainMutationRollsBackWithoutAttemptRow(t *testing.T) {
	_, store, dbPath, cfg := newTestHarness(t, fakeOAuth{})
	now := fixedNow()
	reservation := storage.ActiveReservation{
		AccountID: "acct_atomic_drain", RequestID: "req_atomic_drain", CreatedAt: now.Add(-time.Hour),
	}
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID: reservation.AccountID, RequestID: reservation.RequestID, WindowDate: reservation.CreatedAt.Format("2006-01-02"),
		RequestedTokens: 20, DailyQuota: cfg.Quotas.AccountDailyTokens, CreatedAt: reservation.CreatedAt, ExpiresAt: now.Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.MarkReservationSettlementHold(context.Background(), reservation.AccountID, reservation.RequestID); err != nil {
		t.Fatal(err)
	}
	err := store.RefundReservationForDrain(context.Background(), reservation, now, "operator_drain_release")
	if !errors.Is(err, storage.ErrReservationNotFound) {
		t.Fatalf("err=%v want ErrReservationNotFound", err)
	}
	state := gatewaySettlementSnapshot(t, dbPath, reservation.AccountID)
	if state.activeRows != 1 || state.heldRows != 1 || state.refundedRows != 0 {
		t.Fatalf("failed atomic drain did not roll back: %+v", state)
	}
}

func drainFinality(requestID, outcome, receiptResult string, closed bool, prompt, completion int64) map[string]any {
	return map[string]any{
		"request_id": requestID, "policy_version": settlementPolicyVersion, "mode": "enforce",
		"outcome": outcome, "receipt_result": receiptResult, "reason": "test_" + outcome, "closed": closed,
		"prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion,
		"token_source": "coordinator_observed", "verified_attempts": 1,
	}
}

func seedDrainReservation(t *testing.T, store *sqlite.Store, cfg config.Config, accountID, requestID string, createdAt time.Time, tokens int64, walletSessionID string) {
	t.Helper()
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID: accountID, RequestID: requestID, WindowDate: createdAt.UTC().Format("2006-01-02"), RequestedTokens: tokens,
		DailyQuota: cfg.Quotas.AccountDailyTokens, CreatedAt: createdAt, ExpiresAt: fixedNow().Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	seedBoundSettlementCandidate(t, store, accountID, requestID, "internal_"+requestID, createdAt, tokens, walletSessionID)
}

func performDrainRequest(t *testing.T, h http.Handler, path, operatorKey string) settlementReleaseHoldsResponse {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, nil)
	if operatorKey != "" {
		req.Header.Set("Authorization", "Bearer "+operatorKey)
	}
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var body settlementReleaseHoldsResponse
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	return body
}

func settlementAttemptCount(t *testing.T, dbPath, accountID string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM settlement_reconcile_attempts WHERE account_id = ?`, accountID).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}

func assertDrainAttemptResults(t *testing.T, dbPath, accountID string, expected map[string]string) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for requestID, result := range expected {
		var got, next string
		if err := db.QueryRow(`SELECT last_result, next_attempt_after FROM settlement_reconcile_attempts WHERE account_id = ? AND request_id = ?`, accountID, requestID).Scan(&got, &next); err != nil {
			t.Fatal(err)
		}
		if got != result || next != "" {
			t.Fatalf("request=%s result/next=%q/%q want %q/empty", requestID, got, next, result)
		}
	}
}
