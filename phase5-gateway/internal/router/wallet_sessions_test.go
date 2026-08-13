package router

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

type walletSessionTestClient struct {
	AccountID  string
	SessionID  string
	Bearer     string
	SessionKey ed25519.PrivateKey
}

func TestWalletSessionsDisabledSharedRouteRejectsMPSBearer(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer mps_disabled")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusNotFound {
		t.Fatalf("status=%d want 404 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "wallet_sessions_disabled")
}

func TestWalletSessionRegistrationSelfServiceReplayAndModelFilter(t *testing.T) {
	h, store, dbPath, cfg := newWalletSessionHarness(t, walletModelsClient())
	apiKey := createAccountAndKey(t, store, cfg, "acct_wallet_route")
	client := registerWalletSessionViaAPI(t, h, cfg, apiKey, "acct_wallet_route", []string{"model-a"})
	if got := countAuditEvents(t, dbPath, "wallet_session_challenge_created"); got != 1 {
		t.Fatalf("challenge audit count=%d want 1", got)
	}
	if got := countAuditEvents(t, dbPath, "wallet_session_created"); got != 1 {
		t.Fatalf("session audit count=%d want 1", got)
	}

	statusReqID := "11111111-1111-4111-8111-111111111111"
	statusReq := signedWalletRequest(t, client, http.MethodGet, "/auth/wallet-sessions/"+client.SessionID, walletSessionRoute, statusReqID, nil)
	statusResp := httptest.NewRecorder()
	h.ServeHTTP(statusResp, statusReq)
	if statusResp.Code != http.StatusOK {
		t.Fatalf("status route status=%d want 200 body=%s", statusResp.Code, statusResp.Body.String())
	}
	if statusResp.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("status cache-control=%q want no-store", statusResp.Header().Get("Cache-Control"))
	}
	if !strings.Contains(statusResp.Body.String(), `"remaining_tokens":100`) || !strings.Contains(statusResp.Body.String(), `"usage"`) {
		t.Fatalf("status body missing usage summary: %s", statusResp.Body.String())
	}

	replayResp := httptest.NewRecorder()
	h.ServeHTTP(replayResp, signedWalletRequest(t, client, http.MethodGet, "/auth/wallet-sessions/"+client.SessionID, walletSessionRoute, statusReqID, nil))
	if replayResp.Code != http.StatusConflict {
		t.Fatalf("replay status=%d want 409 body=%s", replayResp.Code, replayResp.Body.String())
	}
	assertErrorCode(t, replayResp.Body.String(), "wallet_session_duplicate_request")
	if got := countAuditEvents(t, dbPath, "wallet_session_rejected"); got != 1 {
		t.Fatalf("replay rejection audit count=%d want 1", got)
	}

	usageReqID := "22222222-2222-4222-8222-222222222222"
	usageReq := signedWalletRequest(t, client, http.MethodGet, "/auth/wallet-sessions/"+client.SessionID+"/usage", walletSessionUsageRoute, usageReqID, nil)
	usageResp := httptest.NewRecorder()
	h.ServeHTTP(usageResp, usageReq)
	if usageResp.Code != http.StatusOK {
		t.Fatalf("usage route status=%d want 200 body=%s", usageResp.Code, usageResp.Body.String())
	}
	if strings.Contains(usageResp.Body.String(), `"data"`) {
		t.Fatalf("signed self-usage must be summary-only body=%s", usageResp.Body.String())
	}

	if _, err := store.AdmitWalletSessionInference(context.Background(), storage.WalletSessionAdmissionRequest{
		SessionID:       client.SessionID,
		AccountID:       client.AccountID,
		RequestID:       "req_wallet_detail",
		Method:          http.MethodPost,
		CanonicalRoute:  "/v1/chat/completions",
		ModelID:         "model-a",
		WindowDate:      "2026-05-29",
		RequestedTokens: 20,
		DailyQuota:      100000,
		Replay: storage.WalletSessionReplayMaterial{
			SessionID:           client.SessionID,
			RequestID:           "req_wallet_detail",
			Method:              http.MethodPost,
			CanonicalRoute:      "/v1/chat/completions",
			SemanticHeadersHash: []byte("headers"),
			RawBodyHash:         []byte("body"),
			BodyBytes:           12,
		},
		CreatedAt: fixedNow(),
		ExpiresAt: fixedNow().Add(time.Hour),
	}); err != nil {
		t.Fatalf("AdmitWalletSessionInference detail fixture: %v", err)
	}
	if err := store.FinalizeWalletSessionReservation(context.Background(), storage.WalletSessionReservationSettlement{
		AccountID:        client.AccountID,
		SessionID:        client.SessionID,
		RequestID:        "req_wallet_detail",
		PromptTokens:     3,
		CompletionTokens: 4,
		TotalTokens:      7,
		MaxTotalTokens:   20,
		TokenSource:      "provider_reported",
		Outcome:          "ok",
		SettledAt:        fixedNow().Add(time.Second),
	}); err != nil {
		t.Fatalf("FinalizeWalletSessionReservation detail fixture: %v", err)
	}
	accountUsageReq := httptest.NewRequest(http.MethodGet, "/auth/wallet-sessions/"+client.SessionID+"/usage?limit=10", nil)
	accountUsageReq.Header.Set("Authorization", "Bearer "+apiKey)
	accountUsageResp := httptest.NewRecorder()
	h.ServeHTTP(accountUsageResp, accountUsageReq)
	if accountUsageResp.Code != http.StatusOK {
		t.Fatalf("account usage status=%d want 200 body=%s", accountUsageResp.Code, accountUsageResp.Body.String())
	}
	if !strings.Contains(accountUsageResp.Body.String(), `"data"`) || !strings.Contains(accountUsageResp.Body.String(), `"req_wallet_detail"`) ||
		!strings.Contains(accountUsageResp.Body.String(), `"reconciliation_status":"matched"`) {
		t.Fatalf("account usage body missing detail rows: %s", accountUsageResp.Body.String())
	}

	modelReqID := "33333333-3333-4333-8333-333333333333"
	modelReq := signedWalletRequest(t, client, http.MethodGet, "/v1/models", "/v1/models", modelReqID, nil)
	modelResp := httptest.NewRecorder()
	h.ServeHTTP(modelResp, modelReq)
	if modelResp.Code != http.StatusOK {
		t.Fatalf("models status=%d want 200 body=%s", modelResp.Code, modelResp.Body.String())
	}
	if strings.Contains(modelResp.Body.String(), "model-b") || strings.Contains(modelResp.Body.String(), "model-c") ||
		!strings.Contains(modelResp.Body.String(), "model-a") {
		t.Fatalf("filtered models body=%s", modelResp.Body.String())
	}
	if strings.Contains(modelResp.Body.String(), "default_model") || strings.Contains(modelResp.Body.String(), "alias_of") ||
		strings.Contains(modelResp.Body.String(), "fallback") || strings.Contains(modelResp.Body.String(), "recommended") ||
		strings.Contains(modelResp.Body.String(), "routing_target") {
		t.Fatalf("filtered model scalar leak body=%s", modelResp.Body.String())
	}

	revokeReqID := "44444444-4444-4444-8444-444444444444"
	revokeReq := signedWalletRequest(t, client, http.MethodDelete, "/auth/wallet-sessions/"+client.SessionID, walletSessionRoute, revokeReqID, nil)
	revokeResp := httptest.NewRecorder()
	h.ServeHTTP(revokeResp, revokeReq)
	if revokeResp.Code != http.StatusOK {
		t.Fatalf("revoke status=%d want 200 body=%s", revokeResp.Code, revokeResp.Body.String())
	}
	if got := countAuditEvents(t, dbPath, "wallet_session_revoked"); got != 1 {
		t.Fatalf("revocation audit count=%d want 1", got)
	}

	afterRevokeReqID := "55555555-5555-4555-8555-555555555555"
	afterRevokeReq := signedWalletRequest(t, client, http.MethodGet, "/v1/models", "/v1/models", afterRevokeReqID, nil)
	afterRevokeResp := httptest.NewRecorder()
	h.ServeHTTP(afterRevokeResp, afterRevokeReq)
	if afterRevokeResp.Code != http.StatusUnauthorized {
		t.Fatalf("after revoke status=%d want 401 body=%s", afterRevokeResp.Code, afterRevokeResp.Body.String())
	}
	assertErrorCode(t, afterRevokeResp.Body.String(), "wallet_session_revoked")
}

func TestWalletSessionListPaginates(t *testing.T) {
	h, store, _, cfg := newWalletSessionHarness(t, walletModelsClient())
	apiKey := createAccountAndKey(t, store, cfg, "acct_wallet_list")
	for i := 0; i < 3; i++ {
		registerWalletSessionViaAPI(t, h, cfg, apiKey, "acct_wallet_list", []string{"model-a"})
	}
	req := httptest.NewRequest(http.MethodGet, "/auth/wallet-sessions?limit=1", nil)
	req.Header.Set("Authorization", "Bearer "+apiKey)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("first page status=%d want 200 body=%s", resp.Code, resp.Body.String())
	}
	var first struct {
		Data       []map[string]any `json:"data"`
		HasMore    bool             `json:"has_more"`
		NextCursor string           `json:"next_cursor"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &first); err != nil {
		t.Fatalf("first page json: %v", err)
	}
	if len(first.Data) != 1 || !first.HasMore || first.NextCursor == "" {
		t.Fatalf("first page=%+v want one row and cursor", first)
	}
	req = httptest.NewRequest(http.MethodGet, "/auth/wallet-sessions?limit=1&cursor="+first.NextCursor, nil)
	req.Header.Set("Authorization", "Bearer "+apiKey)
	resp = httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("second page status=%d want 200 body=%s", resp.Code, resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), first.NextCursor) {
		t.Fatalf("second page repeated cursor/session body=%s", resp.Body.String())
	}
}

func TestWalletSessionManagementRejectsAmbiguousCredentials(t *testing.T) {
	h, store, _, cfg := newWalletSessionHarness(t, walletModelsClient())
	apiKey := createAccountAndKey(t, store, cfg, "acct_wallet_mgmt_ambiguous")
	client := registerWalletSessionViaAPI(t, h, cfg, apiKey, "acct_wallet_mgmt_ambiguous", []string{"model-a"})
	req := httptest.NewRequest(http.MethodGet, "/auth/wallet-sessions/"+client.SessionID+"/usage", nil)
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("X-Api-Key", client.Bearer)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "ambiguous_credentials")
}

func TestWalletSessionExpiredBearerWritesAudit(t *testing.T) {
	current := fixedNow()
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Public.BaseURL = "https://api.streamvc.test"
		cfg.Auth.WalletSessions.Enabled = true
		cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
		cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
		cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
		cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
	}, WithNow(func() time.Time { return current }), WithHTTPClient(walletModelsClient()))
	apiKey := createAccountAndKey(t, store, cfg, "acct_wallet_expired_audit")
	client := registerWalletSessionViaAPI(t, h, cfg, apiKey, "acct_wallet_expired_audit", []string{"model-a"})
	current = fixedNow().Add(11 * time.Minute)
	req := signedWalletRequest(t, client, http.MethodGet, "/v1/models", "/v1/models", "66666666-6666-4666-8666-666666666666", nil)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d want 401 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "wallet_session_expired")
	if got := countAuditEvents(t, dbPath, "wallet_session_expired"); got != 1 {
		t.Fatalf("expiry audit count=%d want 1", got)
	}
}

func TestWalletSessionExhaustionReturnsPaymentRequired(t *testing.T) {
	h, store, dbPath, cfg := newWalletSessionHarness(t, walletInferenceClient())
	apiKey := createAccountAndKey(t, store, cfg, "acct_wallet_exhausted")
	client := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, "acct_wallet_exhausted", []string{"model-a"}, 100, 100)
	if _, err := store.AdmitWalletSessionInference(context.Background(), storage.WalletSessionAdmissionRequest{
		SessionID:       client.SessionID,
		AccountID:       client.AccountID,
		RequestID:       "req_wallet_seed_exhaustion",
		Method:          http.MethodPost,
		CanonicalRoute:  "/v1/chat/completions",
		ModelID:         "model-a",
		WindowDate:      "2026-05-29",
		RequestedTokens: 95,
		DailyQuota:      100000,
		Replay: storage.WalletSessionReplayMaterial{
			SessionID:           client.SessionID,
			RequestID:           "req_wallet_seed_exhaustion",
			Method:              http.MethodPost,
			CanonicalRoute:      "/v1/chat/completions",
			SemanticHeadersHash: []byte("headers"),
			RawBodyHash:         []byte("body"),
			BodyBytes:           12,
		},
		CreatedAt: fixedNow(),
		ExpiresAt: fixedNow().Add(time.Hour),
	}); err != nil {
		t.Fatalf("seed wallet exposure: %v", err)
	}
	rawBody := []byte(`{"model":"model-a","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}`)
	req := signedWalletRequest(t, client, http.MethodPost, "/v1/chat/completions", "/v1/chat/completions", "77777777-7777-4777-8777-777777777777", rawBody)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusPaymentRequired {
		t.Fatalf("status=%d want 402 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "wallet_session_exhausted")
	if got := countAuditEvents(t, dbPath, "wallet_session_rejected"); got != 1 {
		t.Fatalf("cap rejection audit count=%d want 1", got)
	}
}

func TestWalletSessionRegistrationActiveCapReturnsConflict(t *testing.T) {
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Public.BaseURL = "https://api.streamvc.test"
		cfg.Auth.WalletSessions.Enabled = true
		cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
		cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
		cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
		cfg.Auth.WalletSessions.MaxActiveSessionsPerAccount = 1
		cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
	}, WithHTTPClient(walletInferenceClient()))
	apiKey := createAccountAndKey(t, store, cfg, "acct_wallet_active_cap")
	_ = registerWalletSessionViaAPI(t, h, cfg, apiKey, "acct_wallet_active_cap", []string{"model-a"})
	resp := registerWalletSessionFailureViaAPI(t, h, cfg, apiKey, "acct_wallet_active_cap", []string{"model-a"})
	if resp.Code != http.StatusConflict {
		t.Fatalf("status=%d want 409 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "wallet_session_active_cap_exceeded")
}

func TestWalletSessionSettlementReconcileClosesWalletHeldReservations(t *testing.T) {
	cases := []struct {
		name             string
		requestID        string
		coordinatorCode  int
		finality         map[string]any
		expireBeforeRun  bool
		wantSummary      func(settlementReconcileSummary) bool
		wantUsage        func(storage.WalletSessionUsage) bool
		wantFailureAudit bool
	}{
		{
			name:            "verified_debit",
			requestID:       "req_wallet_reconcile_verified",
			coordinatorCode: http.StatusOK,
			finality: map[string]any{
				"policy_version": settlementPolicyVersion,
				"mode":           "enforce", "outcome": "verified", "receipt_result": "valid", "closed": true,
				"prompt_tokens": 5, "completion_tokens": 7, "total_tokens": 12, "token_source": "coordinator_observed",
			},
			wantSummary: func(s settlementReconcileSummary) bool { return s.Scanned == 1 && s.Verified == 1 && s.Errors == 0 },
			wantUsage: func(u storage.WalletSessionUsage) bool {
				return u.SettledTokens == 12 && u.HeldTokens == 0 && u.RemainingTokens == 88
			},
		},
		{
			name:            "refund",
			requestID:       "req_wallet_reconcile_refund",
			coordinatorCode: http.StatusOK,
			finality: map[string]any{
				"policy_version": settlementPolicyVersion,
				"mode":           "enforce", "outcome": "zero_settled", "receipt_result": "valid", "closed": true,
				"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0, "token_source": "coordinator_observed",
			},
			wantSummary: func(s settlementReconcileSummary) bool { return s.Scanned == 1 && s.Refunded == 1 && s.Errors == 0 },
			wantUsage: func(u storage.WalletSessionUsage) bool {
				return u.SettledTokens == 0 && u.HeldTokens == 0 && u.RemainingTokens == 100
			},
		},
		{
			name:            "expired_404_stale_held",
			requestID:       "req_wallet_reconcile_404",
			coordinatorCode: http.StatusNotFound,
			expireBeforeRun: true,
			wantSummary: func(s settlementReconcileSummary) bool {
				return s.Scanned == 1 && s.Coordinator404 == 1 && s.StaleHeld == 1 && s.Errors == 0
			},
			wantUsage: func(u storage.WalletSessionUsage) bool {
				return u.SettledTokens == 0 && u.HeldTokens == 20 && u.RemainingTokens == 80
			},
		},
		{
			name:            "malformed_finality_audited",
			requestID:       "req_wallet_reconcile_malformed",
			coordinatorCode: http.StatusOK,
			finality: map[string]any{
				"policy_version": settlementPolicyVersion,
				"mode":           "enforce", "outcome": "verified", "receipt_result": "valid", "closed": true,
				"prompt_tokens": 5, "completion_tokens": 7, "total_tokens": 12,
			},
			wantSummary: func(s settlementReconcileSummary) bool { return s.Scanned == 1 && s.Errors == 1 },
			wantUsage: func(u storage.WalletSessionUsage) bool {
				return u.SettledTokens == 0 && u.HeldTokens == 20 && u.RemainingTokens == 80
			},
			wantFailureAudit: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			accountID := "acct_" + tc.name
			var sessionID string
			coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.HasSuffix(r.URL.Path, "/poolz") {
					writeJSON(w, http.StatusOK, map[string]any{
						"pool": []map[string]any{{
							"model_id": "model-a", "state": "ready", "slots_free": 1, "slots_total": 1,
							"max_context_tokens": 4096, "auth_state": "bearer_validated",
						}},
					})
					return
				}
				if got := r.URL.Query().Get("request_id"); got != tc.requestID {
					t.Fatalf("request_id query=%q want %q", got, tc.requestID)
				}
				if got := r.URL.Query().Get("account_id"); got != accountID {
					t.Fatalf("account_id query=%q want %q", got, accountID)
				}
				if tc.coordinatorCode == http.StatusNotFound {
					w.WriteHeader(http.StatusNotFound)
					return
				}
				body := map[string]any{"request_id": tc.requestID}
				for k, v := range tc.finality {
					body[k] = v
				}
				writeJSON(w, tc.coordinatorCode, body)
			}))
			defer coordinator.Close()
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Public.BaseURL = "https://api.streamvc.test"
				cfg.Auth.WalletSessions.Enabled = true
				cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
				cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
				cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
				cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
				cfg.Coordinator.BuyerURL = coordinator.URL
				cfg.Coordinator.OperatorURL = coordinator.URL
				cfg.Coordinator.OperatorKey = "operator-key"
				cfg.Coordinator.ServiceToken = "service-token"
			}, WithHTTPClient(coordinator.Client()))
			apiKey := createAccountAndKey(t, store, cfg, accountID)
			client := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, accountID, []string{"model-a"}, 100, 100)
			sessionID = client.SessionID
			if _, err := store.AdmitWalletSessionInference(context.Background(), storage.WalletSessionAdmissionRequest{
				SessionID:       sessionID,
				AccountID:       accountID,
				RequestID:       tc.requestID,
				Method:          http.MethodPost,
				CanonicalRoute:  "/v1/chat/completions",
				ModelID:         "model-a",
				WindowDate:      "2026-05-29",
				RequestedTokens: 20,
				DailyQuota:      100000,
				Replay: storage.WalletSessionReplayMaterial{
					SessionID:           sessionID,
					RequestID:           tc.requestID,
					Method:              http.MethodPost,
					CanonicalRoute:      "/v1/chat/completions",
					SemanticHeadersHash: []byte("headers"),
					RawBodyHash:         []byte("body"),
					BodyBytes:           12,
				},
				CreatedAt: fixedNow(),
				ExpiresAt: fixedNow().Add(time.Hour),
			}); err != nil {
				t.Fatalf("AdmitWalletSessionInference: %v", err)
			}
			if err := store.HoldWalletSessionReservation(context.Background(), accountID, sessionID, tc.requestID, fixedNow().Add(time.Minute)); err != nil {
				t.Fatalf("HoldWalletSessionReservation: %v", err)
			}
			if tc.expireBeforeRun {
				if err := store.ClampReservationExpiry(context.Background(), accountID, tc.requestID, fixedNow().Add(-time.Minute)); err != nil {
					t.Fatalf("ClampReservationExpiry: %v", err)
				}
			}
			req := httptest.NewRequest(http.MethodPost, "/admin/settlement/reconcile?limit=10", nil)
			req.Header.Set("Authorization", "Bearer operator-key")
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d want 200 body=%s", resp.Code, resp.Body.String())
			}
			var summary settlementReconcileSummary
			if err := json.Unmarshal(resp.Body.Bytes(), &summary); err != nil {
				t.Fatalf("summary json: %v", err)
			}
			if !tc.wantSummary(summary) {
				t.Fatalf("summary=%+v", summary)
			}
			usage, err := store.WalletSessionUsage(context.Background(), accountID, sessionID)
			if err != nil {
				t.Fatalf("WalletSessionUsage: %v", err)
			}
			if !tc.wantUsage(usage) {
				t.Fatalf("usage=%+v", usage)
			}
			if tc.wantFailureAudit {
				if got := countAuditEvents(t, dbPath, "wallet_session_settlement_reconcile_failed"); got != 1 {
					t.Fatalf("settlement failure audit count=%d want 1", got)
				}
			}
		})
	}
}

func TestWalletSessionAnthropicMessagesAcceptsXAPIKeyBearer(t *testing.T) {
	clientHTTP := walletInferenceClient()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Public.BaseURL = "https://api.streamvc.test"
		cfg.Auth.WalletSessions.Enabled = true
		cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
		cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
		cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
		cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(clientHTTP))
	apiKey := createAccountAndKey(t, store, cfg, "acct_wallet_anthropic")
	client := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, "acct_wallet_anthropic", []string{"model-a"}, 100, 100)
	rawBody := []byte(`{"model":"model-a","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`)
	req := signedWalletRequest(t, client, http.MethodPost, "/v1/messages", "/v1/messages", "88888888-8888-4888-8888-888888888888", rawBody)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Del("Authorization")
	req.Header.Set("X-Api-Key", client.Bearer)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d want 200 body=%s", resp.Code, resp.Body.String())
	}
}

func TestWalletSessionChallengeRejectsUnknownModel(t *testing.T) {
	h, store, _, cfg := newWalletSessionHarness(t, walletModelsClient())
	apiKey := createAccountAndKey(t, store, cfg, "acct_wallet_unknown_model")
	walletPub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("Generate wallet key: %v", err)
	}
	sessionPub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("Generate session key: %v", err)
	}
	rawChallenge, _ := json.Marshal(map[string]any{
		"wallet_namespace":      auth.WalletNamespaceEd25519,
		"wallet_public_key":     base64.RawURLEncoding.EncodeToString(walletPub),
		"session_public_key":    base64.RawURLEncoding.EncodeToString(sessionPub),
		"expires_at_unix":       fixedNow().Add(10 * time.Minute).Unix(),
		"per_request_token_cap": int64(50),
		"total_token_cap":       int64(100),
		"model_allowlist":       []string{"made-up-model"},
	})
	req := httptest.NewRequest(http.MethodPost, "/auth/wallet-sessions/challenges", bytes.NewReader(rawChallenge))
	req.Header.Set("Authorization", "Bearer "+apiKey)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusForbidden {
		t.Fatalf("status=%d want 403 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "wallet_session_model_not_allowed")
}

func TestWalletSessionModelsRejectsChunkedBody(t *testing.T) {
	h, store, _, cfg := newWalletSessionHarness(t, walletModelsClient())
	apiKey := createAccountAndKey(t, store, cfg, "acct_wallet_chunked_models")
	client := registerWalletSessionViaAPI(t, h, cfg, apiKey, "acct_wallet_chunked_models", []string{"model-a"})
	req := signedWalletRequest(t, client, http.MethodGet, "/v1/models", "/v1/models", "66666666-6666-4666-8666-666666666666", []byte("x"))
	req.Body = io.NopCloser(strings.NewReader("x"))
	req.ContentLength = -1
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "wallet_session_body_forbidden")
}

func TestWalletSessionRejectsAmbiguousCredentials(t *testing.T) {
	h, store, _, cfg := newWalletSessionHarness(t, walletModelsClient())
	apiKey := createAccountAndKey(t, store, cfg, "acct_wallet_ambiguous")
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("X-Api-Key", "mps_not_a_second_key")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "ambiguous_credentials")
}

func newWalletSessionHarness(t *testing.T, client *http.Client) (http.Handler, *sqlite.Store, string, config.Config) {
	t.Helper()
	return newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Public.BaseURL = "https://api.streamvc.test"
		cfg.Auth.WalletSessions.Enabled = true
		cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
		cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
		cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
		cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
	}, WithHTTPClient(client))
}

func walletModelsClient() *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if strings.HasSuffix(r.URL.Path, "/poolz") {
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
				"pool":[
					{"model_id":"model-a","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":"bearer_validated"},
					{"model_id":"model-b","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":"bearer_validated"}
				]
			}`), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"object":"list",
			"data":[{"id":"model-a"},{"id":"model-b"}],
			"default_model":"model-b",
			"fallback":"model-b",
			"recommended":"model-b",
			"nested":{"models":["model-a","model-b"],"supported_models":["model-a","model-c"],"alias_of":"model-b","routing_target":"model-b"},
			"catalog":{"model-a":{"display_name":"Model A"},"model-c":{"display_name":"Model C"}},
			"metadata":{"model-a":{"latency":"fast"},"model-b":{"latency":"slow"}},
			"routing":{"model-c":{"fallback":"model-c"}}
		}`), nil
	})}
}

func registerWalletSessionViaAPI(t *testing.T, h http.Handler, cfg config.Config, apiKey, accountID string, models []string) walletSessionTestClient {
	return registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, accountID, models, 100, 50)
}

func registerWalletSessionViaAPIWithCaps(t *testing.T, h http.Handler, cfg config.Config, apiKey, accountID string, models []string, totalCap, perRequestCap int64) walletSessionTestClient {
	t.Helper()
	walletPub, walletPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("Generate wallet key: %v", err)
	}
	sessionPub, sessionPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("Generate session key: %v", err)
	}
	expiresAt := fixedNow().Add(10 * time.Minute).Unix()
	challengeReq := map[string]any{
		"wallet_namespace":      auth.WalletNamespaceEd25519,
		"wallet_public_key":     base64.RawURLEncoding.EncodeToString(walletPub),
		"session_public_key":    base64.RawURLEncoding.EncodeToString(sessionPub),
		"expires_at_unix":       expiresAt,
		"per_request_token_cap": perRequestCap,
		"total_token_cap":       totalCap,
		"model_allowlist":       models,
	}
	rawChallenge, _ := json.Marshal(challengeReq)
	challengeHTTPReq := httptest.NewRequest(http.MethodPost, "/auth/wallet-sessions/challenges", bytes.NewReader(rawChallenge))
	challengeHTTPReq.Header.Set("Authorization", "Bearer "+apiKey)
	challengeResp := httptest.NewRecorder()
	h.ServeHTTP(challengeResp, challengeHTTPReq)
	if challengeResp.Code != http.StatusOK {
		t.Fatalf("challenge status=%d want 200 body=%s", challengeResp.Code, challengeResp.Body.String())
	}
	var challengeBody struct {
		ChallengeID            string   `json:"challenge_id"`
		Audience               string   `json:"aud"`
		AccountID              string   `json:"account_id"`
		Nonce                  string   `json:"nonce"`
		ExpiresAtUnix          int64    `json:"expires_at_unix"`
		ChallengeExpiresAtUnix int64    `json:"challenge_expires_at_unix"`
		ProofVersion           string   `json:"proof_version"`
		ModelAllowlist         []string `json:"model_allowlist"`
	}
	if err := json.Unmarshal(challengeResp.Body.Bytes(), &challengeBody); err != nil {
		t.Fatalf("challenge json: %v", err)
	}
	if !strings.HasPrefix(challengeBody.ChallengeID, "wch_") || challengeBody.Nonce == "" || challengeBody.Audience != cfg.Public.BaseURL ||
		challengeBody.AccountID != accountID || challengeBody.ProofVersion != auth.WalletProofVersion || challengeBody.ExpiresAtUnix != expiresAt ||
		challengeBody.ChallengeExpiresAtUnix <= fixedNow().Unix() {
		t.Fatalf("unexpected flat challenge body=%s", challengeResp.Body.String())
	}
	proof := auth.WalletProof{
		Version:            auth.WalletProofVersion,
		ChallengeID:        challengeBody.ChallengeID,
		Audience:           cfg.Public.BaseURL,
		AccountID:          accountID,
		WalletNamespace:    auth.WalletNamespaceEd25519,
		WalletPublicKey:    base64.RawURLEncoding.EncodeToString(walletPub),
		SessionPublicKey:   base64.RawURLEncoding.EncodeToString(sessionPub),
		Nonce:              challengeBody.Nonce,
		ExpiresAtUnix:      expiresAt,
		PerRequestTokenCap: perRequestCap,
		TotalTokenCap:      totalCap,
		ModelAllowlist:     models,
	}
	canonicalProof, err := auth.CanonicalWalletProofBytes(proof)
	if err != nil {
		t.Fatalf("CanonicalWalletProofBytes: %v", err)
	}
	registrationReq := map[string]any{
		"proof": map[string]any{
			"version":               proof.Version,
			"challenge_id":          proof.ChallengeID,
			"aud":                   proof.Audience,
			"account_id":            proof.AccountID,
			"wallet_namespace":      proof.WalletNamespace,
			"wallet_public_key":     proof.WalletPublicKey,
			"session_public_key":    proof.SessionPublicKey,
			"nonce":                 proof.Nonce,
			"expires_at_unix":       proof.ExpiresAtUnix,
			"per_request_token_cap": proof.PerRequestTokenCap,
			"total_token_cap":       proof.TotalTokenCap,
			"model_allowlist":       proof.ModelAllowlist,
		},
		"wallet_signature": base64.RawURLEncoding.EncodeToString(ed25519.Sign(walletPriv, canonicalProof)),
	}
	rawRegistration, _ := json.Marshal(registrationReq)
	registrationHTTPReq := httptest.NewRequest(http.MethodPost, "/auth/wallet-sessions", bytes.NewReader(rawRegistration))
	registrationHTTPReq.Header.Set("Authorization", "Bearer "+apiKey)
	registrationResp := httptest.NewRecorder()
	h.ServeHTTP(registrationResp, registrationHTTPReq)
	if registrationResp.Code != http.StatusCreated {
		t.Fatalf("registration status=%d want 201 body=%s", registrationResp.Code, registrationResp.Body.String())
	}
	var registrationBody struct {
		SessionID     string `json:"session_id"`
		SessionBearer string `json:"session_bearer"`
		ExpiresAtUnix int64  `json:"expires_at_unix"`
	}
	if err := json.Unmarshal(registrationResp.Body.Bytes(), &registrationBody); err != nil {
		t.Fatalf("registration json: %v", err)
	}
	if !strings.HasPrefix(registrationBody.SessionBearer, "mps_") || registrationBody.SessionID == "" || registrationBody.ExpiresAtUnix != expiresAt {
		t.Fatalf("registration body=%s", registrationResp.Body.String())
	}
	return walletSessionTestClient{
		AccountID:  accountID,
		SessionID:  registrationBody.SessionID,
		Bearer:     registrationBody.SessionBearer,
		SessionKey: sessionPriv,
	}
}

func registerWalletSessionFailureViaAPI(t *testing.T, h http.Handler, cfg config.Config, apiKey, accountID string, models []string) *httptest.ResponseRecorder {
	t.Helper()
	walletPub, walletPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("Generate wallet key: %v", err)
	}
	sessionPub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("Generate session key: %v", err)
	}
	expiresAt := fixedNow().Add(10 * time.Minute).Unix()
	challengeReq := map[string]any{
		"wallet_namespace":      auth.WalletNamespaceEd25519,
		"wallet_public_key":     base64.RawURLEncoding.EncodeToString(walletPub),
		"session_public_key":    base64.RawURLEncoding.EncodeToString(sessionPub),
		"expires_at_unix":       expiresAt,
		"per_request_token_cap": int64(50),
		"total_token_cap":       int64(100),
		"model_allowlist":       models,
	}
	rawChallenge, _ := json.Marshal(challengeReq)
	challengeHTTPReq := httptest.NewRequest(http.MethodPost, "/auth/wallet-sessions/challenges", bytes.NewReader(rawChallenge))
	challengeHTTPReq.Header.Set("Authorization", "Bearer "+apiKey)
	challengeResp := httptest.NewRecorder()
	h.ServeHTTP(challengeResp, challengeHTTPReq)
	if challengeResp.Code != http.StatusOK {
		t.Fatalf("challenge status=%d want 200 body=%s", challengeResp.Code, challengeResp.Body.String())
	}
	var challengeBody struct {
		ChallengeID string `json:"challenge_id"`
		Nonce       string `json:"nonce"`
	}
	if err := json.Unmarshal(challengeResp.Body.Bytes(), &challengeBody); err != nil {
		t.Fatalf("challenge json: %v", err)
	}
	proof := auth.WalletProof{
		Version:            auth.WalletProofVersion,
		ChallengeID:        challengeBody.ChallengeID,
		Audience:           cfg.Public.BaseURL,
		AccountID:          accountID,
		WalletNamespace:    auth.WalletNamespaceEd25519,
		WalletPublicKey:    base64.RawURLEncoding.EncodeToString(walletPub),
		SessionPublicKey:   base64.RawURLEncoding.EncodeToString(sessionPub),
		Nonce:              challengeBody.Nonce,
		ExpiresAtUnix:      expiresAt,
		PerRequestTokenCap: 50,
		TotalTokenCap:      100,
		ModelAllowlist:     models,
	}
	canonicalProof, err := auth.CanonicalWalletProofBytes(proof)
	if err != nil {
		t.Fatalf("CanonicalWalletProofBytes: %v", err)
	}
	registrationReq := map[string]any{
		"proof": map[string]any{
			"version":               proof.Version,
			"challenge_id":          proof.ChallengeID,
			"aud":                   proof.Audience,
			"account_id":            proof.AccountID,
			"wallet_namespace":      proof.WalletNamespace,
			"wallet_public_key":     proof.WalletPublicKey,
			"session_public_key":    proof.SessionPublicKey,
			"nonce":                 proof.Nonce,
			"expires_at_unix":       proof.ExpiresAtUnix,
			"per_request_token_cap": proof.PerRequestTokenCap,
			"total_token_cap":       proof.TotalTokenCap,
			"model_allowlist":       proof.ModelAllowlist,
		},
		"wallet_signature": base64.RawURLEncoding.EncodeToString(ed25519.Sign(walletPriv, canonicalProof)),
	}
	rawRegistration, _ := json.Marshal(registrationReq)
	registrationHTTPReq := httptest.NewRequest(http.MethodPost, "/auth/wallet-sessions", bytes.NewReader(rawRegistration))
	registrationHTTPReq.Header.Set("Authorization", "Bearer "+apiKey)
	registrationResp := httptest.NewRecorder()
	h.ServeHTTP(registrationResp, registrationHTTPReq)
	return registrationResp
}

func walletInferenceClient() *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if strings.HasSuffix(r.URL.Path, "/poolz") {
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
				"pool":[{"model_id":"model-a","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":"bearer_validated"}]
			}`), nil
		}
		if strings.HasSuffix(r.URL.Path, "/v1/models") {
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"object":"list","data":[{"id":"model-a"}]}`), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_wallet","object":"chat.completion",
			"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
}

func signedWalletRequest(t *testing.T, client walletSessionTestClient, method, path, canonicalRoute, requestID string, rawBody []byte) *http.Request {
	t.Helper()
	var body *bytes.Reader
	if rawBody == nil {
		body = bytes.NewReader(nil)
	} else {
		body = bytes.NewReader(rawBody)
	}
	req := httptest.NewRequest(method, path, body)
	req.Header.Set("Authorization", "Bearer "+client.Bearer)
	req.Header.Set("X-Request-ID", requestID)
	req.Header.Set("X-MacProvider-Session-Timestamp", timeFormatUnix(fixedNow()))
	obj, err := auth.NewWalletRequestSignatureObject(client.SessionID, method, canonicalRoute, requestID, rawBody, req.Header, fixedNow().Unix())
	if err != nil {
		t.Fatalf("NewWalletRequestSignatureObject: %v", err)
	}
	canonical, err := auth.CanonicalWalletRequestBytes(obj)
	if err != nil {
		t.Fatalf("CanonicalWalletRequestBytes: %v", err)
	}
	req.Header.Set("X-MacProvider-Session-Signature", base64.RawURLEncoding.EncodeToString(ed25519.Sign(client.SessionKey, canonical)))
	return req
}

func timeFormatUnix(t time.Time) string {
	return strconv.FormatInt(t.Unix(), 10)
}
