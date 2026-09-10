package router

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

func TestRelayBlindWalletSignedReservationEnvelopeAndSettlement(t *testing.T) {
	for _, tc := range []struct {
		name             string
		perRequestCap    int64
		wrongBinding     bool
		revokeBeforeChat bool
		wantStatus       int
		wantCode         string
		wantConsume      int32
		wantDispatch     int32
	}{
		{name: "success_and_replay", perRequestCap: 24, wantStatus: http.StatusOK, wantConsume: 1, wantDispatch: 1},
		{name: "revoked_session", perRequestCap: 24, revokeBeforeChat: true, wantStatus: http.StatusUnauthorized, wantCode: "wallet_session_revoked"},
		{name: "wrong_consume_binding", perRequestCap: 24, wrongBinding: true, wantStatus: http.StatusServiceUnavailable, wantCode: "relay_blind_required_unavailable", wantConsume: 1},
		{name: "wallet_request_cap", perRequestCap: 20, wantStatus: http.StatusBadRequest, wantCode: "wallet_session_request_cap_exceeded"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reservation, _ := pilotReservationFixture(t, false)
			var consumed, dispatched atomic.Int32
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				switch r.URL.Path {
				case "/poolz":
					return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"pool":[{"model_id":"test-model","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":"bearer_validated"}]}`), nil
				case "/v1/relay-blind/route-reservations":
					if r.Header.Get("X-MacProvider-Wallet-Session") == "" {
						t.Error("wallet session was not forwarded with reservation")
					}
					body, _ := json.Marshal(reservation)
					return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, string(body)), nil
				case "/v1/relay-blind/consume":
					consumed.Add(1)
					raw, _ := io.ReadAll(r.Body)
					digest := sha256.Sum256(raw)
					providerBinding := reservation.ProviderBinding
					if tc.wrongBinding {
						providerBinding = "wrong-provider-binding"
					}
					body, _ := json.Marshal(relayblind.ConsumeResponse{
						Version: relayblind.ConsumeVersion, ProviderBinding: providerBinding, BuyerBinding: reservation.BuyerBinding,
						EnvelopeDigest: base64.RawURLEncoding.EncodeToString(digest[:]), ExecutionAuthorization: "wallet-execution-authorization",
						ConsumedAtUnix: fixedNow().Unix(), ExpiresAtUnix: reservation.ExpiresAtUnix,
					})
					return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, string(body)), nil
				case "/v1/chat/completions":
					dispatched.Add(1)
					raw, _ := io.ReadAll(r.Body)
					digest := sha256.Sum256(raw)
					headers := make(http.Header)
					headers.Set("Content-Type", "application/json")
					headers.Set(relayBlindValidatedHeader, base64.RawURLEncoding.EncodeToString(digest[:]))
					headers.Set(settlementModeHeader, "observe")
					headers.Set("X-MacProvider-Provider", "wallet-provider-secret")
					return responseWithBody(http.StatusOK, headers, `{"id":"wallet-completion","object":"chat.completion","model":"test-model","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop","index":0}],"usage":{"prompt_tokens":20,"completion_tokens":2,"total_tokens":22}}`), nil
				default:
					return responseWithBody(http.StatusNotFound, nil, `{}`), nil
				}
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				c.Public.BaseURL = "https://api.malibu.test"
				c.Auth.WalletSessions.Enabled = true
				c.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
				c.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
				c.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
				c.Auth.WalletSessions.MetadataRequestsPerMinute = 100
				c.Features.RelayBlindRequests.Enabled = true
			}, WithHTTPClient(client))
			accountID := "acct_wallet_relay_" + tc.name
			apiKey := createAccountAndKey(t, store, cfg, accountID)
			wallet := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, accountID, []string{"test-model"}, 100, tc.perRequestCap)

			// The successful boundary obtains the closed signed reservation over a
			// genuine wallet-signed request before constructing its envelope.
			if tc.perRequestCap >= reservation.ReservationTokenCap {
				routeBody, _ := json.Marshal(map[string]any{
					"endpoint_family": "chat_completions", "model": "test-model", "stream": false,
					"max_output_tokens": int64(8), "input_token_upper_bound": int64(16), "encrypted_request_bytes": int64(512),
				})
				routeReq := signedWalletRequest(t, wallet, http.MethodPost, "/v1/relay-blind/route-reservations", "/v1/relay-blind/route-reservations", "11111111-1111-4111-8111-111111111111", routeBody)
				routeResp := httptest.NewRecorder()
				h.ServeHTTP(routeResp, routeReq)
				if routeResp.Code != http.StatusOK {
					t.Fatalf("reservation status=%d body=%s", routeResp.Code, routeResp.Body.String())
				}
				if err := json.Unmarshal(routeResp.Body.Bytes(), &reservation); err != nil {
					t.Fatal(err)
				}
			}
			raw := pilotEnvelopeFixture(t, reservation)
			if tc.revokeBeforeChat {
				if err := store.RevokeWalletSession(context.Background(), accountID, wallet.SessionID, "test", "test", fixedNow()); err != nil {
					t.Fatal(err)
				}
			}
			chat := signedWalletRequest(t, wallet, http.MethodPost, "/v1/chat/completions", "/v1/chat/completions", "123e4567-e89b-42d3-a456-426614174088", raw)
			response := httptest.NewRecorder()
			h.ServeHTTP(response, chat)
			if response.Code != tc.wantStatus {
				t.Fatalf("chat status=%d want %d body=%s", response.Code, tc.wantStatus, response.Body.String())
			}
			if tc.wantCode != "" {
				assertErrorCode(t, response.Body.String(), tc.wantCode)
			}
			if consumed.Load() != tc.wantConsume || dispatched.Load() != tc.wantDispatch {
				t.Fatalf("consume/dispatch=%d/%d want %d/%d", consumed.Load(), dispatched.Load(), tc.wantConsume, tc.wantDispatch)
			}
			if tc.wantStatus != http.StatusOK {
				assertNoDailyUsage(t, store, accountID)
				return
			}
			if response.Header().Get(relayBlindEffectiveHeader) != "relay_blind_satisfied" || bytes.Contains(response.Body.Bytes(), []byte("wallet-provider-secret")) {
				t.Fatalf("unsafe success response headers=%v body=%s", response.Header(), response.Body.String())
			}
			usage, err := store.WalletSessionUsage(context.Background(), accountID, wallet.SessionID)
			if err != nil {
				t.Fatal(err)
			}
			if usage.SettledTokens != 18 || usage.ReservedTokens != 0 {
				t.Fatalf("wallet usage settled/reserved=%d/%d want 18/0", usage.SettledTokens, usage.ReservedTokens)
			}
			replay := httptest.NewRecorder()
			h.ServeHTTP(replay, signedWalletRequest(t, wallet, http.MethodPost, "/v1/chat/completions", "/v1/chat/completions", "123e4567-e89b-42d3-a456-426614174088", raw))
			if replay.Code != http.StatusConflict {
				t.Fatalf("replay status=%d body=%s", replay.Code, replay.Body.String())
			}
			assertErrorCode(t, replay.Body.String(), "relay_blind_replay")
			if consumed.Load() != 1 || dispatched.Load() != 1 {
				t.Fatalf("replay consume/dispatch=%d/%d want 1/1", consumed.Load(), dispatched.Load())
			}
			db, err := sql.Open("sqlite", dbPath)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			var usageRows int
			if err := db.QueryRow(`SELECT COUNT(*) FROM usage_events WHERE account_id = ? AND request_id = ?`, accountID, "123e4567-e89b-42d3-a456-426614174088").Scan(&usageRows); err != nil {
				t.Fatal(err)
			}
			if usageRows != 1 {
				t.Fatalf("usage events=%d want 1", usageRows)
			}
		})
	}
}
