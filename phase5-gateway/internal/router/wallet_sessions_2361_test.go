package router

import (
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

// #2361: on /v1/responses a wallet-session cap that settled usage has spent
// answers HTTP 400 error.code budget_reached, the shape Codex stops on. A cap
// blocked only by an in-flight reservation keeps 402 wallet_session_exhausted,
// since budget returns when it settles. The chat path keeps 402 (see
// TestWalletSessionExhaustionReturnsPaymentRequired).
func TestWalletSessionExhaustionOnResponses(t *testing.T) {
	for _, tc := range []struct {
		name     string
		settled  bool
		stream   bool
		wantCode int
		wantErr  string
	}{
		{"settled_nonstream", true, false, http.StatusBadRequest, "budget_reached"},
		{"settled_stream", true, true, http.StatusBadRequest, "budget_reached"},
		{"in_flight_reservation", false, false, http.StatusPaymentRequired, "wallet_session_exhausted"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Public.BaseURL = "https://api.malibu.test"
				cfg.Auth.WalletSessions.Enabled = true
				cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
				cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
				cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
				cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
				enableResponsesWithCoordinator(cfg)
			}, WithHTTPClient(walletInferenceClient()))
			account := "acct_wallet_exhausted_" + tc.name
			apiKey := createAccountAndKey(t, store, cfg, account)
			client := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, account, []string{"model-a"}, 4000, 4000)
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
			if tc.settled {
				settleWalletSessionReservationsForTest(t, dbPath, client.SessionID)
			}
			body := `{"model":"model-a","max_output_tokens":10,"store":false,"input":"hi"}`
			if tc.stream {
				body = `{"model":"model-a","max_output_tokens":10,"store":false,"stream":true,"input":"hi"}`
			}
			req := signedWalletRequest(t, client, http.MethodPost, "/v1/responses", "/v1/responses", "78787878-7878-4878-8878-787878787879", []byte(body))
			req.Header.Set("Content-Type", "application/json")
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != tc.wantCode {
				t.Fatalf("status=%d want %d body=%s", resp.Code, tc.wantCode, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), tc.wantErr)
			assertBodyRetryable(t, resp.Body.String(), false)
			if !strings.Contains(resp.Body.String(), "wallet_session_exhausted") {
				t.Fatalf("body does not name the SPEC-040 condition: %s", resp.Body.String())
			}
			if got := countAuditEvents(t, dbPath, "wallet_session_rejected"); got != 1 {
				t.Fatalf("cap rejection audit count=%d want 1", got)
			}
		})
	}
}

func settleWalletSessionReservationsForTest(t *testing.T, dbPath, sessionID string) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("sql open: %v", err)
	}
	defer db.Close()
	res, err := db.Exec(`UPDATE wallet_session_reservations SET status = 'settled', settled_tokens = reserved_tokens WHERE session_id = ?`, sessionID)
	if err != nil {
		t.Fatalf("settle seed reservation: %v", err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		t.Fatalf("settled %d reservations, want 1", n)
	}
}
