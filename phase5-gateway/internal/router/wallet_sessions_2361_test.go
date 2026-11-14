package router

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

// #2361: an exhausted wallet-session cap on /v1/responses answers HTTP 400
// error.code budget_reached, the shape Codex stops on without retrying. The
// chat path keeps 402 wallet_session_exhausted (test above).
func TestWalletSessionExhaustionOnResponsesIsBudgetReached(t *testing.T) {
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Public.BaseURL = "https://api.malibu.test"
		cfg.Auth.WalletSessions.Enabled = true
		cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
		cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
		cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
		cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
		enableResponsesWithCoordinator(cfg)
	}, WithHTTPClient(walletInferenceClient()))
	apiKey := createAccountAndKey(t, store, cfg, "acct_wallet_exhausted_responses")
	client := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, "acct_wallet_exhausted_responses", []string{"model-a"}, 4000, 4000)
	if _, err := store.AdmitWalletSessionInference(context.Background(), storage.WalletSessionAdmissionRequest{
		SessionID:       client.SessionID,
		AccountID:       client.AccountID,
		RequestID:       "req_wallet_seed_exhaustion",
		Method:          http.MethodPost,
		CanonicalRoute:  "/v1/chat/completions",
		ModelID:         "model-a",
		WindowDate:      "2026-05-29",
		RequestedTokens: 3995,
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
	rawBody := []byte(`{"model":"model-a","max_output_tokens":10,"store":false,"input":"hi"}`)
	req := signedWalletRequest(t, client, http.MethodPost, "/v1/responses", "/v1/responses", "78787878-7878-4878-8878-787878787879", rawBody)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "budget_reached")
	assertBodyRetryable(t, resp.Body.String(), false)
	if !strings.Contains(resp.Body.String(), "wallet_session_exhausted") {
		t.Fatalf("body does not name the SPEC-040 condition: %s", resp.Body.String())
	}
	if got := countAuditEvents(t, dbPath, "wallet_session_rejected"); got != 1 {
		t.Fatalf("cap rejection audit count=%d want 1", got)
	}
}
